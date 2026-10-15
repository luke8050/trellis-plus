/**
 * trellis-plus gate — deterministic checks for the Trellis planning/execution workflow (v2).
 *
 * Installed by `trellis-plus.mjs apply` into `.trellis/plus/gate.mjs`. Zero dependencies, Node >= 18.
 * Commit this file with the project so teammates can run the gates without the installer.
 *
 * Usage: node .trellis/plus/gate.mjs <command> [task-dir] [options]
 *
 *   tier <task> [S|M|L] [--reason "<why>"]   show / set the task tier (stored in task.json meta.plus_tier); S/M need a reason
 *   seed <task>            create the templates for the tier (prd.md; M/L: design.md, implement.md; L: research/code-map.md)
 *   align <task>           prd.md: "对齐状态：已对齐", no open questions, decision log (M/L), every requirement numbered R<n>
 *   anchors <task>         verify every `path:line#Symbol` anchor in design / implement / research/code-map.md
 *   lint-plan <task>       size limits, placeholders, anchors, sections, R coverage, impact table, test matrix
 *   design-review <task>   L tier: reviews/design-review.md header + every blocker answered in design-review-resolution.md
 *   matrix <task>          print the R -> module -> test coverage matrix (paste into design.md section 11)
 *   status <task>          tier, file sizes, gate results and the next step (0 tokens)
 *   usage <task> [--phase <name> --tokens <n> [--note <text>]]   record / sum the tokens spent per phase
 *   pre-start <task>       tier-aware gate behind `task.py start`
 *   test [--task <t>] [--base <ref>] [--staged] [--run]   every changed Service/Controller needs a unit test (Maven multi-module)
 *   ocr  [--task <t>] [--run] [--inspect] [--force]       run / verify alibaba open-code-review + severity-aware triage
 *   pre-commit [--task <t>] [--run] [--hook]   test + ocr (--hook = git pre-commit mode: staged files only)
 *   gates                  list every gate, its switch (profile / gates.* in plus.config.json) and what it checks (0 tokens)
 *   lightweight <task> --reason "<why>"   deprecated alias of `tier <task> S`
 *
 * Exit code: 0 = pass, 1 = gate failed, 2 = usage / environment error.
 * Bypass (deliberate, e.g. in a git hook): TRELLIS_PLUS_SKIP_GATE=1
 * Hook task selection: --task, then TRELLIS_PLUS_TASK, then the session task, then the ONLY in_progress task.
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, copyFileSync, appendFileSync } from "node:fs"
import { join, resolve, dirname, relative, basename, sep } from "node:path"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const HERE = dirname(fileURLToPath(import.meta.url))
const ROOT = resolve(HERE, "..", "..")
const PLUS_DIR = HERE

// ───────────────────────── config ─────────────────────────

const DEFAULT_CONFIG = {
  tiers: {
    budget: { S: 60000, M: 150000, L: 320000 }, // token targets (upper bounds, not measured); OCR is not counted
    maxClassesM: 3, // tier M: at most this many changed Service/Controller classes, one Maven module
  },
  limits: { prd: 10240, designM: 12288, designL: 30720, implement: 20480, codeMap: 20480, total: 61440 }, // bytes; total = prd+design+implement (sub-agents get all three injected)
  planning: {
    anchorSymbolWindow: 15,
    highRiskRefs: 5, // a symbol with >= this many references must be marked 高风险 in design.md section 8
  },
  review: { maxRounds: 2 },
  profile: "standard", // preset of the gate switches: "standard" (v2 default) | "strict" | "light"; `gates.<name>` overrides single gates
  gates: {}, // { align | lintPlan | designReview | manifests | test | ocr | hook : "error" | "warn" | "off" }
  hook: { runTests: false }, // git pre-commit hook: also run the unit tests (slow); default = static checks only
  testGate: {
    include: [
      "**/src/main/java/**/*Controller.java",
      "**/src/main/java/**/*Service.java",
      "**/src/main/java/**/*ServiceImpl.java",
    ],
    exclude: ["**/src/test/**", "**/target/**"],
    testPathMap: [
      { from: "^(.*)src/main/java/(.*)/([A-Za-z0-9_$]+)\\.java$", to: "$1src/test/java/$2/$3Test.java" },
      { from: "^(.*)src/main/java/(.*)/([A-Za-z0-9_$]+)\\.java$", to: "$1src/test/java/$2/$3Tests.java" },
    ],
    stripSuffixes: ["Impl"],
    skipInterfaces: true,
    requireTestChanged: true,
    requireTestAnnotation: true,
    testAnnotationPattern: "@(?:[\\w.]+\\.)?(Test|ParameterizedTest|RepeatedTest|TestFactory)\\b",
    methodLevel: "warn", // changed Service methods must be referenced by the test class: "warn" | "error" | "off" (approximate, name based)
    // Maven multi-module: the module is the nearest pom.xml directory above the changed file; tests must live in the same module.
    runCommand: "mvn -q -pl {module} -am test -Dtest={classes} -Dsurefire.failIfNoSpecifiedTests=false",
    runCommandRoot: "mvn -q test -Dtest={classes} -Dsurefire.failIfNoSpecifiedTests=false", // module == project root
  },
  ocr: {
    enabled: true,
    required: true,
    command: "ocr",
    extraArgs: [],
    maxRerun: 2, // first run is free; a rerun is allowed only after critical/high findings, at most this many times
    mode: "auto", // "auto": `ocr llm test` first, ocr when it works, otherwise delegation mode (the coding agent reviews the code itself) | "cli": ocr only (failure = error) | "delegate": never call ocr
    sourceGlobs: ["**/*.java", "**/*.kt", "**/*.groovy", "**/*.xml", "**/*.sql", "**/*.properties", "**/*.yml", "**/*.yaml"],
    sourceExclude: ["**/target/**", "**/.trellis/**", "**/.opencode/**", "**/node_modules/**"],
    blockingSeverities: ["critical", "high"], // may not be deferred; false-positive needs a code anchor
    background: true, // pass a short task summary to ocr via --background-file
    backgroundMaxChars: 3000,
  },
}

function deepMerge(a, b) {
  if (Array.isArray(a) || Array.isArray(b) || typeof a !== "object" || typeof b !== "object" || !a || !b) {
    return b === undefined ? a : b
  }
  const out = { ...a }
  for (const k of Object.keys(b)) out[k] = deepMerge(a[k], b[k])
  return out
}

function loadConfig() {
  const p = join(PLUS_DIR, "plus.config.json")
  let cfg = DEFAULT_CONFIG
  if (existsSync(p)) {
    try { cfg = deepMerge(DEFAULT_CONFIG, JSON.parse(readFileSync(p, "utf8"))) } catch (e) { fail2(`plus.config.json is not valid JSON: ${e.message}`) }
  }
  checkGates(cfg)
  return cfg
}

// ───────────────────────── gate switches ─────────────────────────
// Every blocking check can be switched: "error" (blocks, exit 1) | "warn" (printed, never blocks) | "off" (not run at all).
// `profile` presets the switches, `gates.<name>` overrides one of them. Default = standard. Use "strict" for the stricter variants (ocr.onIncomplete + methodLevel error).

const GATES = {
  align: "prd.md: 对齐状态：已对齐, 待确认问题 empty, 决策记录 (M/L), every requirement numbered R<n>, placeholders, size",
  lintPlan: "M/L design.md + implement.md: placeholders, real anchors, sections, R coverage, impact table, test matrix, size, tier M limits",
  designReview: "L: reviews/design-review.md header + every blocker answered in design-review-resolution.md",
  manifests: "task.py start: implement.jsonl / check.jsonl carry real spec entries besides the [plus] guides (step 1.3)",
  test: "every changed Service/Controller has a changed JUnit5 unit test (same Maven module); tier S/M limits",
  ocr: "ocr review (or delegation mode) report exists, is fresh, every finding triaged by severity",
  hook: "git pre-commit hook (tests + OCR triage on the staged files)",
}
const PROFILES = {
  strict: {},
  standard: { designReview: "warn", manifests: "warn" },
  light: { lintPlan: "warn", designReview: "off", manifests: "off", ocr: "warn" },
}
const GATE_MODES = ["error", "warn", "off"]

function checkGates(cfg) {
  if (!PROFILES[cfg.profile]) fail2(`plus.config.json: profile "${cfg.profile}" is unknown (use ${Object.keys(PROFILES).join(" | ")})`)
  for (const [k, v] of Object.entries(cfg.gates ?? {})) {
    if (!GATES[k]) fail2(`plus.config.json: gates.${k} is unknown (gates: ${Object.keys(GATES).join(", ")})`)
    if (!GATE_MODES.includes(v)) fail2(`plus.config.json: gates.${k} = ${JSON.stringify(v)} is invalid (use ${GATE_MODES.join(" | ")})`)
  }
}

/** Effective mode of a gate and where it comes from. */
function gateInfo(cfg, name) {
  if (cfg.gates && cfg.gates[name]) return { mode: cfg.gates[name], from: `gates.${name}` }
  if (PROFILES[cfg.profile][name]) return { mode: PROFILES[cfg.profile][name], from: `profile ${cfg.profile}` }
  return { mode: "error", from: cfg.profile === "strict" ? "default (strict)" : `profile ${cfg.profile}` }
}
const gateMode = (cfg, name) => gateInfo(cfg, name).mode

/** warn: failures are shown as warnings and never block. */
function applyMode(rep, cfg, name) {
  if (gateMode(cfg, name) === "warn" && rep.errors.length) {
    rep.warnings.push(...rep.errors.map((e) => `(gates.${name}=warn, would block otherwise) ${e}`))
    rep.errors = []
  }
  return rep
}
function skippedReport(title, name) {
  const r = new Report(title)
  r.note(`skipped: ${name} is off (${gateInfo(CFG, name).from})`)
  return r
}
/** Run a gate under its switch: off = not executed at all (no side effects, e.g. no ocr call). */
function runGate(name, cfg, title, fn) {
  if (gateMode(cfg, name) === "off") return skippedReport(title, name)
  return applyMode(fn(), cfg, name)
}
let CFG = DEFAULT_CONFIG

function cmdGates(cfg) {
  console.log(`== gates  (profile: ${cfg.profile}) ==`)
  for (const k of Object.keys(GATES)) {
    const g = gateInfo(cfg, k)
    console.log(`  ${k.padEnd(13)} ${g.mode.padEnd(5)} [${g.from}]  ${GATES[k]}`)
  }
  console.log("  Always on, not switchable: the tier decision before seed/start (task.py start needs a tier), exit-code contract, TRELLIS_PLUS_SKIP_GATE.")
  console.log('  Change: plus.config.json  "profile": "strict|standard|light"  and/or  "gates": { "<name>": "error|warn|off" }')
  return 0
}

// ───────────────────────── helpers ─────────────────────────

class Report {
  constructor(title) {
    this.title = title
    this.errors = []
    this.warnings = []
    this.notes = []
  }
  error(m) { this.errors.push(m) }
  warn(m) { this.warnings.push(m) }
  note(m) { this.notes.push(m) }
  get ok() { return this.errors.length === 0 }
  print() {
    console.log(`\n== ${this.title} ==`)
    for (const n of this.notes) console.log(`  · ${n}`)
    for (const w of this.warnings) console.log(`  ! WARN  ${w}`)
    for (const e of this.errors) console.log(`  ✗ FAIL  ${e}`)
    console.log(this.ok ? `  ✓ PASS${this.warnings.length ? ` (${this.warnings.length} warning(s))` : ""}` : `  ✗ ${this.errors.length} problem(s) — gate failed`)
  }
}

function fail2(msg) {
  console.error(`trellis-plus gate: ${msg}`)
  process.exit(2)
}

function parseArgs(argv) {
  const pos = []
  const opts = {}
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a.startsWith("--")) {
      const key = a.slice(2)
      const next = argv[i + 1]
      if (next !== undefined && !next.startsWith("--")) { opts[key] = next; i++ } else opts[key] = true
    } else pos.push(a)
  }
  return { pos, opts }
}

function resolveTask(input) {
  if (!input) fail2("task directory required (e.g. .trellis/tasks/10-09-my-task)")
  const cands = [
    resolve(process.cwd(), input),
    resolve(ROOT, input),
    resolve(ROOT, ".trellis", "tasks", input),
  ]
  for (const c of cands) if (existsSync(c) && statSync(c).isDirectory()) return c
  const tasksDir = join(ROOT, ".trellis", "tasks")
  if (existsSync(tasksDir)) {
    const hit = readdirSync(tasksDir).filter((d) => d === input || d.endsWith("-" + input))
    if (hit.length === 1) return join(tasksDir, hit[0])
  }
  fail2(`task directory not found: ${input}`)
}

/**
 * All tasks whose task.json says status=in_progress — except Trellis's own onboarding task (`00-bootstrap-*`): every
 * freshly initialised project carries it as in_progress, and it would make "the only in_progress task" never true.
 */
function inProgressTasks() {
  const tasksDir = join(ROOT, ".trellis", "tasks")
  if (!existsSync(tasksDir)) return []
  const out = []
  for (const d of readdirSync(tasksDir)) {
    if (/^00-bootstrap/.test(d)) continue
    const tj = join(tasksDir, d, "task.json")
    if (!existsSync(tj)) continue
    try { if (JSON.parse(readFileSync(tj, "utf8")).status === "in_progress") out.push(join(tasksDir, d)) } catch { /* ignore broken task.json */ }
  }
  return out
}

/** Set by taskFromOpts when several tasks are in_progress and nothing says which one is meant. */
let TASK_AMBIGUOUS = null

/**
 * Task selection: --task > TRELLIS_PLUS_TASK > the session task (`task.py current`) > the ONLY in_progress task.
 * With several in_progress tasks and no hint the result is null and TASK_AMBIGUOUS lists the candidates (never "newest wins").
 */
function taskFromOpts(opts) {
  TASK_AMBIGUOUS = null
  if (opts.task && opts.task !== true) return resolveTask(opts.task)
  const env = process.env.TRELLIS_PLUS_TASK
  if (env && env.trim()) return resolveTask(env.trim())
  const r = spawnSync("python3", [join(ROOT, ".trellis", "scripts", "task.py"), "current", "--json"], { cwd: ROOT, encoding: "utf8" })
  if (r.status === 0 && r.stdout) {
    try {
      const j = JSON.parse(r.stdout)
      // 0.6.x: {"current_task": {"dir": ".trellis/tasks/<name>", "id": ..., "status": ...}, "source": ...}
      const ct = j.current_task
      const p = (ct && typeof ct === "object" ? ct.dir : ct) || j.task_path || j.path || j.task
      if (typeof p === "string" && p) return resolveTask(p)
    } catch { /* fall through */ }
  }
  const all = inProgressTasks()
  if (all.length === 1) {
    console.log(`  · no session task context; using the only in_progress task: ${relative(ROOT, all[0])}`)
    return all[0]
  }
  if (all.length > 1) TASK_AMBIGUOUS = all.map((d) => relative(ROOT, d))
  return null
}

const read = (p) => (existsSync(p) ? readFileSync(p, "utf8").replace(/\r\n/g, "\n") : null)
const bytesOf = (s) => Buffer.byteLength(s ?? "")

function git(args) {
  const r = spawnSync("git", args, { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
  return { ok: r.status === 0, out: (r.stdout || "").trim(), err: (r.stderr || "").trim() }
}

function globToRegex(glob) {
  let re = ""
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i]
    if (c === "*") {
      if (glob[i + 1] === "*") {
        if (glob[i + 2] === "/") { re += "(?:.*/)?"; i += 2 } else { re += ".*"; i += 1 }
      } else re += "[^/]*"
    } else if (c === "?") re += "[^/]"
    else if ("\\^$+.()|{}[]".includes(c)) re += "\\" + c
    else re += c
  }
  return new RegExp("^" + re + "$")
}
const matchAny = (globs, path) => globs.some((g) => globToRegex(g).test(path))
const toPosix = (p) => p.split(sep).join("/")

/** Split markdown into sections keyed by H2 heading text (fenced code ignored). */
function sectionsOf(md) {
  const out = []
  let cur = null
  let inFence = false
  for (const line of md.split("\n")) {
    if (/^```/.test(line)) inFence = !inFence
    const m = !inFence && line.match(/^##\s+(.*)$/)
    if (m) { cur = { heading: m[1].trim(), body: [] }; out.push(cur); continue }
    if (cur) cur.body.push(line)
  }
  return out.map((s) => ({ heading: s.heading, body: s.body.join("\n") }))
}
const findSection = (secs, key) => secs.find((s) => s.heading.toLowerCase().includes(key.toLowerCase()))

function parseTable(body) {
  const rows = []
  for (const line of body.split("\n")) {
    if (!/^\s*\|/.test(line)) continue
    const cells = line.trim().replace(/^\||\|$/g, "").split("|").map((c) => c.trim())
    if (cells.every((c) => /^:?-{2,}:?$/.test(c))) continue
    rows.push(cells)
  }
  if (rows.length < 2) return []
  const head = rows[0].map((h) => h.toLowerCase())
  return rows.slice(1).map((r) => Object.fromEntries(head.map((h, i) => [h, (r[i] ?? "").replace(/`/g, "").trim()])))
}
/** value of the first column whose header contains one of `keys` */
const col = (row, keys) => { const k = Object.keys(row).find((h) => keys.some((x) => h.includes(x))); return k === undefined ? "" : row[k] }

/** Remove HTML comments but keep line numbers stable. */
const stripComments = (t) => t.replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ""))
const refs = (t, re) => [...new Set([...(t ?? "").matchAll(re)].map((m) => m[0]))]
const R_RE = /\bR\d+\b/g

// A template slot looks like 【填写：…】, so unfilled templates fail; instruction text in templates must not use these words.
const PLACEHOLDER_RE = /(\bTBD\b|\bTODO\b|\bXXX\b|待补充|待定|<填写[^>]*>|【填写[^】]*】|\{\{[^}]*\}\})/
const ANCHOR_RE = /`?([A-Za-z0-9_@.\-/\\[\]]+\.[A-Za-z0-9]+):(\d+)(?:-(\d+))?#([A-Za-z_$][\w$.<>]*)`?/g

function placeholders(name, txt, rep, max = 5) {
  let n = 0
  txt.split("\n").forEach((line, i) => {
    if (!PLACEHOLDER_RE.test(line)) return
    if (++n <= max) rep.error(`${name}:${i + 1} unresolved placeholder: ${line.trim().slice(0, 80)}`)
  })
  if (n > max) rep.error(`${name}: … and ${n - max} more unresolved placeholder(s)`)
}

/** Changed files relative to ROOT. staged=true → index only (git hook); otherwise working tree + untracked vs base. */
function changedFiles(base, staged = false) {
  const files = new Set()
  const args = staged
    ? ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "--relative"]
    : ["diff", "--name-only", "--diff-filter=ACMR", "--relative", base]
  const d = git(args)
  if (!d.ok) fail2(`git diff failed: ${d.err}`)
  d.out.split("\n").filter(Boolean).forEach((f) => files.add(f))
  if (!staged) {
    const u = git(["ls-files", "--others", "--exclude-standard"])
    if (u.ok) u.out.split("\n").filter(Boolean).forEach((f) => files.add(f))
  }
  return [...files].map(toPosix)
}

const isSource = (f, oc) => matchAny(oc.sourceGlobs, f) && !matchAny(oc.sourceExclude, f)

function readJsonl(p) {
  return (read(p) ?? "").split("\n").map((l) => l.trim()).filter(Boolean).flatMap((l) => {
    try { const o = JSON.parse(l); return o && typeof o === "object" && o.file ? [o] : [] } catch { return [] }
  })
}

// ───────────────────────── tier ─────────────────────────

const TIERS = ["S", "M", "L"]

function readTaskJson(taskDir) {
  const p = join(taskDir, "task.json")
  try { return { path: p, raw: readFileSync(p, "utf8"), data: JSON.parse(readFileSync(p, "utf8")) } } catch { return null }
}

/**
 * Tier resolution. Stored in task.json `meta.plus_tier` (same place `task.py set-meta` writes).
 * A v1.x `.plus-lightweight` marker counts as S. No tier: `legacy` = the task carries v1.x artifacts (alignment.md,
 * design-r*-*.md reviews, DES-n ids) and is judged as L with format findings downgraded to warnings;
 * anything else is "unset" and has to get a tier first.
 */
function taskTier(taskDir) {
  const tj = readTaskJson(taskDir)
  const m = tj?.data?.meta
  const t = typeof m?.plus_tier === "string" ? m.plus_tier.trim().toUpperCase() : ""
  if (TIERS.includes(t)) return { tier: t, reason: String(m.plus_tier_reason ?? ""), legacy: false, unset: false }
  if (existsSync(join(taskDir, ".plus-lightweight"))) return { tier: "S", reason: (read(join(taskDir, ".plus-lightweight")) ?? "").trim(), legacy: true, unset: false }
  const rdir = join(taskDir, "reviews")
  const oldReview = existsSync(rdir) && readdirSync(rdir).some((f) => /^design-r\d+-(accuracy|coverage|impact)\.md$/.test(f))
  const oldDesign = /\bDES-\d+\b/.test(read(join(taskDir, "design.md")) ?? "")
  if (existsSync(join(taskDir, "alignment.md")) || oldReview || oldDesign) return { tier: "L", reason: "", legacy: true, unset: false }
  return { tier: null, reason: "", legacy: false, unset: true }
}

function needTier(rep, ti) {
  if (!ti.unset) return false
  rep.error("task has no tier. You propose S/M/L with the reasons, ASK the user to choose in the conversation, then record their choice: `node .trellis/plus/gate.mjs tier <task> S|M|L --reason \"<reasons + user confirmed>\"`")
  return true
}

function writeTier(taskDir, tier, reason) {
  const tj = readTaskJson(taskDir)
  if (!tj) fail2(`task.json not found / not valid JSON in ${relative(ROOT, taskDir)}`)
  const meta = tj.data.meta && typeof tj.data.meta === "object" ? tj.data.meta : {}
  meta.plus_tier = tier
  if (reason) meta.plus_tier_reason = reason; else delete meta.plus_tier_reason
  tj.data.meta = meta
  writeFileSync(tj.path, JSON.stringify(tj.data, null, 2) + (tj.raw.endsWith("\n") ? "\n" : ""))
}

/** Concrete (non-interface) Service/Controller sources among `files`, with their Maven module. */
function svcCtlChanges(files, cfg) {
  const tg = cfg.testGate
  return files
    .filter((f) => matchAny(tg.include, f) && !matchAny(tg.exclude, f) && existsSync(resolve(ROOT, f)))
    .filter((f) => !(tg.skipInterfaces && isPureInterface(read(resolve(ROOT, f)) ?? "")))
}

function cmdTier(taskDir, value, opts, cfg) {
  const ti = taskTier(taskDir)
  if (!value) {
    console.log(ti.unset ? `tier: (not set)` : `tier: ${ti.tier}${ti.legacy ? " (legacy task: no meta.plus_tier)" : ""}${ti.reason ? ` — ${ti.reason}` : ""}`)
    return 0
  }
  const t = String(value).toUpperCase()
  if (!TIERS.includes(t)) fail2("tier must be S, M or L")
  const reason = typeof opts.reason === "string" ? opts.reason.trim() : ""
  if (t !== "L" && reason.length < 6) fail2(`tier ${t} needs --reason "<why this task is small>" (>= 6 chars): the human decision is the audit trail`)
  // The tier is a human call, but the cheap facts are checked: S/M cannot cover Service/Controller work beyond their limit.
  const changed = (() => { const r = git(["diff", "--name-only", "--diff-filter=ACMR", "--relative", "HEAD"]); const u = git(["ls-files", "--others", "--exclude-standard"]); return [...new Set([...(r.ok ? r.out.split("\n") : []), ...(u.ok ? u.out.split("\n") : [])].filter(Boolean))].map(toPosix) })()
  const sc = svcCtlChanges(changed, cfg)
  if (t === "S" && sc.length) {
    console.error(`trellis-plus gate: tier S refused — ${sc.length} Service/Controller file(s) are already changed (${sc.slice(0, 3).join(", ")}${sc.length > 3 ? ", …" : ""}). Use M or L.`)
    return 1
  }
  if (t === "M") {
    const mods = new Set(sc.map(moduleOf))
    if (sc.length > cfg.tiers.maxClassesM || mods.size > 1) {
      console.error(`trellis-plus gate: tier M refused — ${sc.length} Service/Controller file(s) in ${mods.size} module(s) (limit ${cfg.tiers.maxClassesM} files, 1 module). Use L.`)
      return 1
    }
  }
  writeTier(taskDir, t, reason)
  console.log(`tier ${t} set for ${relative(ROOT, taskDir)}${reason ? ` — ${reason}` : ""}\n  ${t === "S" ? "S: prd.md only; unit-test gate and pre-commit hook still apply (a Service/Controller change is refused)." : t === "M" ? `M: prd.md + design.md + implement.md, no independent review; max ${cfg.tiers.maxClassesM} Service/Controller classes in one module.` : "L: full flow with independent design review."}`)
  return 0
}

/** Maven module of a project-relative file: directory of the nearest pom.xml above it ("" = the project root). */
function moduleOf(file) {
  let d = dirname(file)
  while (true) {
    if (existsSync(resolve(ROOT, d, "pom.xml"))) return d === "." ? "" : d
    if (d === "." || d === "" || d === "/") return ""
    d = dirname(d)
  }
}


// ───────────────────────── anchors ─────────────────────────

/** Verify every `path:line#Symbol` anchor in `text` against the working tree. Returns the number of NEW distinct anchors. */
function verifyAnchors(text, name, rep, pl, seen = new Set()) {
  let n = 0
  for (const m of text.matchAll(ANCHOR_RE)) {
    const [, file, l1, l2, sym] = m
    const key = `${file}:${l1}:${l2 ?? ""}#${sym}`
    if (seen.has(key)) continue
    seen.add(key)
    n++
    const abs = resolve(ROOT, file)
    if (!abs.startsWith(ROOT) || !existsSync(abs)) { rep.error(`${name}: anchor ${file}:${l1}#${sym} — file does not exist`); continue }
    const lines = (read(abs) ?? "").split("\n")
    const a = Number(l1), b = Number(l2 ?? l1)
    if (a < 1 || b > lines.length || a > b) { rep.error(`${name}: anchor ${file}:${l1}${l2 ? "-" + l2 : ""}#${sym} — line out of range (file has ${lines.length} lines)`); continue }
    const w = pl.anchorSymbolWindow
    const slice = lines.slice(Math.max(0, a - 1 - w), Math.min(lines.length, b + w)).join("\n")
    const bare = sym.split(/[.<]/).filter(Boolean).pop()
    if (!slice.includes(bare)) rep.error(`${name}: anchor ${file}:${l1}${l2 ? "-" + l2 : ""}#${sym} — symbol "${bare}" not found within ±${w} lines`)
  }
  return n
}

function anchorsGate(taskDir, cfg) {
  const rep = new Report(`anchors  ${relative(ROOT, taskDir)}`)
  const seen = new Set()
  let n = 0
  for (const [name, f] of [["design.md", "design.md"], ["implement.md", "implement.md"], ["research/code-map.md", "research/code-map.md"]]) {
    const txt = read(join(taskDir, f))
    if (txt === null) { rep.note(`${name} not present — skipped`); continue }
    const clean = stripComments(txt)
    n += verifyAnchors(clean, name, rep, cfg.planning, seen)
    if (f.endsWith("code-map.md")) {
      clean.split("\n").forEach((line, i) => {
        if (/NOT-FOUND/.test(line) && !/`[^`]+`/.test(line)) rep.warn(`${name}:${i + 1} NOT-FOUND without the search command (write: NOT-FOUND: <what> — 搜索：\`git grep -n "…"\`)`)
      })
    }
  }
  rep.note(`${n} distinct anchor(s) verified`)
  return rep
}

// ───────────────────────── align (prd.md) ─────────────────────────

const NONE_RE = /^(无|无。|none\.?|—|-)$/i

/** Items of a section: table rows (first cell) and list lines. */
function sectionItems(body) {
  const items = []
  for (const t of tablesOf(body)) for (const row of t) items.push({ head: String(Object.values(row)[0] ?? ""), text: Object.values(row).join(" | ") }) // every table counts: requirements may be grouped under ### headings, one table each
  for (const line of body.split("\n")) {
    const m = line.match(/^\s*(?:[-*]|\d+[.)])\s+(.*)$/)
    if (m) items.push({ head: m[1], text: m[1] })
  }
  return items
}

/**
 * Four mechanical checks on prd.md (the human conversation itself cannot be verified; the decision log is the audit trail):
 *  1 "对齐状态：已对齐"  2 "待确认问题" is empty  3 "决策记录" has entries (M/L)  4 every requirement carries an id R<n>.
 */
function alignGate(taskDir, cfg, ti = taskTier(taskDir)) {
  const rep = new Report(`align  ${relative(ROOT, taskDir)}`)
  const soft = (m) => (ti.legacy ? rep.warn(`legacy task: ${m}`) : rep.error(m))
  const raw = read(join(taskDir, "prd.md"))
  if (raw === null) { rep.error("prd.md missing"); return rep }
  if (needTier(rep, ti)) return rep
  const txt = stripComments(raw)
  placeholders("prd.md", txt, rep)
  if (bytesOf(raw) > cfg.limits.prd) soft(`prd.md is ${bytesOf(raw)} bytes (> ${cfg.limits.prd}); split the task into parent/child tasks`)

  const status = (txt.match(/^对齐状态[:：]\s*(已对齐|未对齐)\s*$/m) || [])[1]
  if (!status) soft('prd.md: missing the line "对齐状态：已对齐" (or "对齐状态：未对齐")')
  else if (status !== "已对齐") soft("prd.md: 对齐状态 is 未对齐 — finish the clarification, confirm the summary with the user, then set 对齐状态：已对齐")

  const secs = sectionsOf(txt)
  const open = findSection(secs, "待确认问题")
  if (!open) soft('prd.md: missing section "待确认问题" (write 无 when nothing is open)')
  else {
    const body = open.body.replace(/\s+/g, " ").trim()
    if (!NONE_RE.test(body)) soft(`prd.md: 待确认问题 is not empty (${Math.max(sectionItems(open.body).length, 1)} item(s)) — ask the user, move each answer to 决策记录, leave 无`)
  }

  const reqSec = findSection(secs, "需求")
  const reqIds = []
  let nGroups = 0
  if (!reqSec) soft('prd.md: missing section "需求" (a table or list; every requirement numbered R1, R2…)')
  else {
    for (const it of sectionItems(reqSec.body)) {
      const m = it.head.replace(/[*_`]/g, "").trim().match(/^R\d+\b/)
      if (!m) { soft(`prd.md 需求: item without a number R<n>: ${it.text.slice(0, 60)}`); continue }
      if (reqIds.includes(m[0])) soft(`prd.md 需求: duplicate ${m[0]}`)
      reqIds.push(m[0])
    }
    if (reqIds.length === 0) soft("prd.md 需求: no requirement R<n> found")
    // grouping by function: every `### <function>` heading carries its own requirement table (style finding: warning only)
    const groups = reqSec.body.split(/^###[ \t]+/m).slice(1).map((b) => ({ title: b.split("\n")[0].trim(), items: sectionItems(b.split("\n").slice(1).join("\n")) }))
    nGroups = groups.length
    if (reqIds.length && groups.length === 0) rep.warn('prd.md 需求: not grouped by function — put each function / requirement module under its own "### <name>" heading, with its requirements below it')
    for (const g of groups) if (!g.items.some((i) => /^R\d+\b/.test(i.head.replace(/[*_`]/g, "").trim()))) rep.warn(`prd.md 需求: group "${g.title}" has no requirement R<n>`)
  }

  const decSec = findSection(secs, "决策记录")
  const decs = decSec ? parseTable(decSec.body).filter((r) => /^D\d+$/.test(String(Object.values(r)[0] ?? "").trim())) : []
  if (ti.tier !== "S") {
    if (!decSec) soft('prd.md: missing section "决策记录" (M/L: one row per clarified conclusion: D<n> | 问题 | 结论 | 来源 | 影响)')
    else if (decs.length === 0) soft("prd.md: 决策记录 has no D<n> row — M/L tasks record what was clarified with the user")
  }
  for (const d of decs) {
    const id = Object.values(d)[0]
    if (!col(d, ["结论"]).trim() || !col(d, ["来源"]).trim()) rep.warn(`prd.md ${id}: needs both 结论 and 来源 (user + date, or file:line)`)
    for (const r of refs(col(d, ["影响"]), R_RE)) if (reqIds.length && !reqIds.includes(r)) rep.warn(`prd.md ${id}: 影响 cites ${r}, which prd.md does not define`)
  }
  rep.note(`tier ${ti.tier ?? "?"}${ti.legacy ? " (legacy)" : ""}: ${reqIds.length} requirement(s), ${decs.length} decision(s), status ${status ?? "?"}, ${nGroups} function group(s)`)
  return rep
}

// ───────────────────────── lint-plan ─────────────────────────

function parseExemptions(body) {
  const m = new Map()
  for (const line of body.split("\n")) {
    const x = line.match(/^\s*(?:[-*]\s+)?`?([^\s`:：]+\.java)`?\s*[:：]\s*(.{8,})$/)
    if (x) m.set(x[1], x[2].trim())
  }
  return m
}

/** Number of references in an impact-table cell: "`git grep -n x` → 7". null = no number found. */
function hitCount(cell) {
  const m = cell.match(/(?:→|=>|->)\s*(\d+)|(?:命中|hits?)[:：]?\s*(\d+)/i) || cell.match(/^\s*(\d+)\s*(?:处|个|hits?)?\s*$/i)
  return m ? Number(m[1] ?? m[2]) : null
}

const DESIGN_ALWAYS = [["评审导读", "0 评审导读"], ["背景与目标", "1 背景与目标、非目标"], ["整体方案", "3 整体方案"], ["模块拆分", "4 模块拆分"], ["数据库变更", "5 数据库变更"], ["详细设计", "6 详细设计"], ["异常与边界", "7 异常与边界"], ["影响分析", "8 影响分析"], ["依赖", "10 依赖、风险、兼容与回滚"], ["覆盖矩阵", "11 覆盖矩阵与上线检查"], ["开放问题", "12 开放问题"]]
const DESIGN_L_ONLY = [["术语", "2 术语与约定"], ["非功能", "9 非功能"]]
const IMPL_REQUIRED = [["实施步骤", "1 实施步骤"], ["测试矩阵", "2 测试矩阵"], ["测试豁免", "3 测试豁免"]]
const TYPE_RE = { 正常: /正常|normal/i, 边界: /边界|boundary/i, 异常: /异常|错误|error|exception/i }

/**
 * Truth-type findings (anchors that do not exist, files that do not exist, a PRD requirement nobody covers, a Service without
 * normal/boundary/error tests, a size limit) are errors. Legacy (v1.x) tasks get the format findings as warnings only.
 */
function lintPlan(taskDir, cfg, ti = taskTier(taskDir)) {
  const rep = new Report(`lint-plan  ${relative(ROOT, taskDir)}`)
  const soft = (m) => (ti.legacy ? rep.warn(`legacy task: ${m}`) : rep.error(m))
  const L = cfg.limits
  const prdRaw = read(join(taskDir, "prd.md"))
  if (!prdRaw) { rep.error("prd.md missing"); return rep }
  if (needTier(rep, ti)) return rep
  if (ti.tier === "S") { rep.note(`tier S${ti.reason ? ` (${ti.reason})` : ""}: only prd.md is required; design/implement are not checked`); return rep }

  const designRaw = read(join(taskDir, "design.md"))
  const implRaw = read(join(taskDir, "implement.md"))
  if (!designRaw) rep.error("design.md missing (run `gate seed <task>`, then draft it — skill plus-draft)")
  if (!implRaw) rep.error("implement.md missing (run `gate seed <task>`, then draft it — skill plus-draft)")
  if (!designRaw || !implRaw) return rep
  const mapRaw = read(join(taskDir, "research", "code-map.md"))
  const prd = stripComments(prdRaw), design = stripComments(designRaw), impl = stripComments(implRaw), cmap = stripComments(mapRaw ?? "")

  // ── size limits (sub-agents get prd+design+implement injected on every dispatch) ──
  const dLimit = ti.tier === "M" ? L.designM : L.designL
  const sizes = [["prd.md", bytesOf(prdRaw), L.prd], ["design.md", bytesOf(designRaw), dLimit], ["implement.md", bytesOf(implRaw), L.implement], ["research/code-map.md", bytesOf(mapRaw), L.codeMap]]
  for (const [n, b, max] of sizes) if (b > max) soft(`${n} is ${b} bytes (> ${max}). Split the task into parent/child tasks or tighten the document`)
  const total = bytesOf(prdRaw) + bytesOf(designRaw) + bytesOf(implRaw)
  if (total > L.total) soft(`prd+design+implement is ${total} bytes (> ${L.total}); every implement/check dispatch injects all three`)

  // ── truth: placeholders and anchors ──
  placeholders("design.md", design, rep)
  placeholders("implement.md", impl, rep)
  if (mapRaw !== null) placeholders("research/code-map.md", cmap, rep)
  const seen = new Set()
  let anchors = 0
  for (const [name, txt] of [["design.md", design], ["implement.md", impl], ["research/code-map.md", cmap]]) anchors += verifyAnchors(txt, name, rep, cfg.planning, seen)
  rep.note(`tier ${ti.tier}${ti.legacy ? " (legacy)" : ""}; ${anchors} distinct anchor(s) verified`)
  if (ti.tier === "L" && mapRaw === null) soft("research/code-map.md missing (L tier: the exploration result the design is grounded in)")

  // ── design.md structure ──
  const reqSec = findSection(sectionsOf(prd), "需求")
  const reqIds = refs(reqSec ? reqSec.body : prd, R_RE)
  if (!reqIds.length) rep.error("prd.md defines no requirement ids (R1, R2…): run `gate align`")
  const dSecs = sectionsOf(design)
  const need = ti.tier === "L" ? [...DESIGN_ALWAYS, ...DESIGN_L_ONLY] : DESIGN_ALWAYS
  for (const [key, label] of need) {
    const s = findSection(dSecs, key)
    if (!s) { soft(`design.md missing section "## ${label}"`); continue }
    if (s.body.replace(/\s+/g, " ").trim().length === 0) soft(`design.md section "${s.heading}" is empty (write 无 / 省略：<原因>)`)
  }
  const unknownR = (name, text) => { for (const r of refs(text, R_RE)) if (reqIds.length && !reqIds.includes(r)) rep.error(`${name} cites ${r}, which prd.md does not define`) }

  const mod = findSection(dSecs, "模块拆分")
  const modRows = mod ? parseTable(mod.body) : []
  if (mod && modRows.length === 0) soft("design.md 模块拆分 has no table rows (模块 | 职责 | 对应R | 依赖)")
  const covered = new Set()
  for (const r of modRows) {
    const rs = refs(col(r, ["对应r", "对应需求"]), R_RE)
    if (!rs.length) rep.warn(`design.md 模块拆分: module "${col(r, ["模块"])}" cites no R (scope creep?)`)
    rs.forEach((x) => covered.add(x))
    unknownR("design.md 模块拆分", col(r, ["对应r", "对应需求"]))
  }
  if (mod && modRows.length) for (const q of reqIds) if (!covered.has(q)) rep.error(`${q} has no module in design.md 模块拆分 (a requirement without a module is an omission)`)
  const cov = findSection(dSecs, "覆盖矩阵")
  if (cov) for (const q of reqIds) if (!new RegExp(`\\b${q}\\b`).test(cov.body)) soft(`${q} is missing from design.md 覆盖矩阵`)
  const alt = findSection(dSecs, "整体方案")
  if (alt && parseTable(alt.body).length < 2) rep.warn("design.md 整体方案: compare at least two options (采用 + one rejected)")
  const exc = findSection(dSecs, "异常与边界")
  if (exc) for (const r of parseTable(exc.body)) if (!col(r, ["对应测试", "测试"]).trim()) rep.warn(`design.md 异常与边界: scenario "${col(r, ["场景"])}" has no 对应测试`)

  // impact analysis: every symbol has a disposition; >= highRiskRefs references must be called out
  const imp = findSection(dSecs, "影响分析")
  if (imp) {
    const rows = parseTable(imp.body)
    if (rows.length === 0 && imp.body.replace(/\s+/g, " ").trim().length < 4) soft("design.md 影响分析 is empty: list the symbols with their reference counts, or write 无 and why")
    for (const r of rows) {
      const sym = col(r, ["符号"]) || "?"
      const disp = col(r, ["处置"])
      if (!disp.trim()) { rep.error(`design.md 影响分析: "${sym}" has no 处置`); continue }
      const hits = hitCount(col(r, ["引用"]))
      if (hits === null) rep.warn(`design.md 影响分析: "${sym}" — write the references as "命令 → 命中数"`)
      else if (hits >= cfg.planning.highRiskRefs && !/高风险|high[- ]?risk/i.test(Object.values(r).join(" "))) rep.error(`design.md 影响分析: "${sym}" has ${hits} references (>= ${cfg.planning.highRiskRefs}) — mark it 高风险 and state the compatibility / regression handling`)
    }
  }
  const open = findSection(dSecs, "开放问题")
  if (open) { const n = (open.body.match(/^\s*[-*]\s*\[ \]/gm) || []).length; if (n) rep.warn(`design.md 开放问题: ${n} unchecked item(s) — clear them or mark "带着风险推进" before the review`) }

  // ── implement.md ──
  const iSecs = sectionsOf(impl)
  for (const [key, label] of IMPL_REQUIRED) {
    const s = findSection(iSecs, key)
    if (!s) soft(`implement.md missing section "## ${label}"`)
    else if (s.body.replace(/\s+/g, " ").trim().length === 0) soft(`implement.md section "${s.heading}" is empty`)
  }
  const stepsSec = findSection(iSecs, "实施步骤")
  const blocks = stepsSec ? stepsSec.body.split(/^###\s+/m).slice(1) : []
  if (stepsSec && blocks.length === 0) soft("implement.md 实施步骤 has no `### 步骤 n：…` blocks")
  const exempt = parseExemptions(findSection(iSecs, "测试豁免")?.body ?? "")
  const tg = cfg.testGate
  const isSvcCtl = (f) => matchAny(tg.include, f) && !matchAny(tg.exclude, f)
  const needTest = new Map() // class -> file
  for (const b of blocks) {
    for (const m of b.matchAll(/`((?:[\w.\-]+\/)+[\w.\-]+\.[A-Za-z]{1,10})`/g)) {
      const f = m[1].replace(/^\.\//, "")
      const abs = resolve(ROOT, f)
      const isNew = /新增|新建|\badd\b|\bnew\b|\bcreate\b/i.test(b)
      if (!abs.startsWith(ROOT) || !existsSync(abs)) { if (!isNew) rep.error(`implement.md: \`${f}\` does not exist — fix the path, or write 新增 in the step if the file is new`); }
      if (!isSvcCtl(f) || exempt.has(f)) continue
      if (existsSync(abs) && tg.skipInterfaces && isPureInterface(read(abs) ?? "")) continue
      needTest.set(basename(f, ".java"), f)
    }
  }
  for (const [f, why] of exempt) rep.warn(`EXEMPT ${f} — ${why} (needs human sign-off)`)
  if (ti.tier === "M") {
    const mods = new Set([...needTest.values()].map(moduleOf))
    if (needTest.size > cfg.tiers.maxClassesM || mods.size > 1) rep.error(`tier M allows at most ${cfg.tiers.maxClassesM} Service/Controller classes in one module (this plan: ${needTest.size} in ${mods.size}) — raise the tier: \`gate tier <task> L\``)
  }
  const matrix = findSection(iSecs, "测试矩阵")
  const mrows = matrix ? parseTable(matrix.body) : []
  if (matrix && needTest.size && mrows.length === 0) rep.error("implement.md 测试矩阵 has no table rows (对应R | 类 | 用例 | 类型 | 预期)")
  for (const r of mrows) {
    const rs = refs(col(r, ["对应r", "对应需求"]), R_RE)
    if (!rs.length) rep.warn(`implement.md 测试矩阵: row "${col(r, ["用例"])}" has no 对应R`)
    unknownR("implement.md 测试矩阵", col(r, ["对应r", "对应需求"]))
  }
  for (const [cls] of needTest) {
    const rows = mrows.filter((r) => col(r, ["类", "class"]).includes(cls))
    if (rows.length === 0) { rep.error(`implement.md 测试矩阵 has no cases for ${cls} (Service/Controller) — add normal/boundary/error rows or list it under 测试豁免`); continue }
    for (const [type, re] of Object.entries(TYPE_RE)) if (!rows.some((r) => re.test(col(r, ["类型", "type"])))) rep.error(`implement.md 测试矩阵: ${cls} has no ${type} case`)
  }
  const tested = new Set(mrows.flatMap((r) => refs(col(r, ["对应r", "对应需求"]), R_RE)))
  for (const q of reqIds) if (mrows.length && !tested.has(q)) rep.warn(`${q} has no row in implement.md 测试矩阵 (fine only if no code behaviour changes)`)
  rep.note(`${reqIds.length} requirement(s); ${needTest.size} Service/Controller class(es) need tests; ${mrows.length} test-matrix row(s)`)
  return rep
}

// ───────────────────────── matrix ─────────────────────────

function cmdMatrix(taskDir, opts) {
  const prd = stripComments(read(join(taskDir, "prd.md")) ?? "")
  const design = stripComments(read(join(taskDir, "design.md")) ?? "")
  const impl = stripComments(read(join(taskDir, "implement.md")) ?? "")
  const reqSec = findSection(sectionsOf(prd), "需求")
  const reqIds = refs(reqSec ? reqSec.body : prd, R_RE)
  const mod = findSection(sectionsOf(design), "模块拆分")
  const mat = findSection(sectionsOf(impl), "测试矩阵")
  const modRows = mod ? parseTable(mod.body) : []
  const testRows = mat ? parseTable(mat.body) : []
  const gaps = []
  const lines = ["| 需求 | 模块 | 测试 |", "| --- | --- | --- |"]
  for (const q of reqIds) {
    const mods = modRows.filter((r) => refs(col(r, ["对应r", "对应需求"]), R_RE).includes(q)).map((r) => col(r, ["模块"]))
    const tests = testRows.filter((r) => refs(col(r, ["对应r", "对应需求"]), R_RE).includes(q)).map((r) => `${col(r, ["类"])}#${col(r, ["用例"])}`)
    if (!mods.length) gaps.push(`${q}: no module in design.md 模块拆分`)
    if (!tests.length) gaps.push(`${q}: no row in implement.md 测试矩阵`)
    lines.push(`| ${q} | ${mods.join("、") || "（无）"} | ${tests.join("、") || "（无）"} |`)
  }
  console.log(lines.join("\n"))
  for (const g of gaps) console.log(`  ! ${g}`)
  return opts.check && gaps.length ? 1 : 0
}


// ───────────────────────── design-review (L tier) ─────────────────────────

/** Contiguous markdown tables in `text`, each parsed with its own header row. */
function tablesOf(text) {
  const out = []
  let cur = []
  for (const line of text.split("\n")) {
    if (/^\s*\|/.test(line)) cur.push(line)
    else { if (cur.length) out.push(parseTable(cur.join("\n"))); cur = [] }
  }
  if (cur.length) out.push(parseTable(cur.join("\n")))
  return out
}

const RESOLUTION_RE = /^\s*[-*]\s*#(\d+)\s+(采纳|驳回)\s*[—–:：-]+\s*(.*)$/

function designReview(taskDir, cfg, ti = taskTier(taskDir)) {
  const rep = new Report(`design-review  ${relative(ROOT, taskDir)}`)
  if (needTier(rep, ti)) return rep
  if (ti.tier !== "L") { rep.note(`tier ${ti.tier}: independent design review is not required`); return rep }
  const rdir = join(taskDir, "reviews")
  const report = read(join(rdir, "design-review.md"))
  if (report === null) {
    const old = existsSync(rdir) && readdirSync(rdir).some((f) => /^design-r\d+-(accuracy|coverage|impact)\.md$/.test(f))
    if (ti.legacy && old) rep.note("legacy task: v1.x three-lens reports present — accepted without re-review")
    else rep.error("reviews/design-review.md missing — dispatch the plus-design-reviewer agent (step 1.7)")
    return rep
  }
  const head = report.split("\n").slice(0, 15).join("\n")
  const int = (re) => { const m = head.match(re); return m ? Number(m[1]) : null }
  const blockers = int(/^阻塞[:：]\s*(\d+)\s*$/m), confirm = int(/^需人工确认[:：]\s*(\d+)\s*$/m), round = int(/^轮次[:：]\s*(\d+)/m)
  if (blockers === null) rep.error('design-review.md: header line "阻塞：N" missing (first 15 lines)')
  if (confirm === null) rep.error('design-review.md: header line "需人工确认：M" missing (first 15 lines)')
  if (round !== null && round > cfg.review.maxRounds) rep.warn(`round ${round} exceeds review.maxRounds=${cfg.review.maxRounds}; stop and let the human decide`)
  for (const k of ["需求覆盖矩阵", "问题清单", "假设清单", "需人工确认", "已检查"]) if (!report.includes(k)) rep.warn(`design-review.md has no "${k}" part (the reviewer's output format)`)

  // the issue table: header must carry 严重程度; the number in the header must match the table
  const issues = tablesOf(report).filter((t) => t.length && Object.keys(t[0]).some((h) => h.includes("严重程度"))).flat()
  const blockRows = issues.filter((r) => col(r, ["严重程度"]).includes("阻塞"))
  const nums = blockRows.map((r) => Number(col(r, ["编号"])))
  if (blockers !== null && blockRows.length !== blockers) rep.error(`design-review.md header says 阻塞：${blockers} but the 问题清单 table has ${blockRows.length} blocker row(s) — fix the header or the table`)
  for (const r of blockRows) if (!col(r, ["证据"]).trim()) rep.warn(`blocker #${col(r, ["编号"])} has no evidence`)
  rep.note(`round ${round ?? "?"}: ${blockRows.length} blocker(s), ${issues.length - blockRows.length} suggestion(s), ${confirm ?? "?"} item(s) need a human`)
  if (confirm !== null && confirm >= 3) rep.note("3+ items need a human: consider /plus-grill-design to settle them")

  // every blocker needs a written reaction: 采纳 (what changed) or 驳回 (with evidence)
  const resText = read(join(rdir, "design-review-resolution.md"))
  const reacted = new Map()
  if (resText) {
    for (const line of resText.split("\n")) {
      const m = line.match(RESOLUTION_RE)
      if (!m) continue
      if (reacted.has(Number(m[1]))) rep.warn(`design-review-resolution.md: #${m[1]} answered twice (the last one counts)`)
      reacted.set(Number(m[1]), { kind: m[2], text: m[3].trim() })
    }
  }
  if (blockRows.length && !resText) rep.error("reviews/design-review-resolution.md missing — answer every blocker: `- #<编号> 采纳 — <改了什么>` or `- #<编号> 驳回 — <证据：文件:行 或 prd.md 原文>`")
  for (const n of nums) {
    const r = reacted.get(n)
    if (!resText) break
    if (!r) { rep.error(`blocker #${n} has no entry in design-review-resolution.md`); continue }
    if (r.kind === "采纳" && r.text.length < 4) rep.error(`#${n} 采纳: say what changed (section / sentence)`)
    if (r.kind === "驳回" && !(hasCodeEvidence(r.text) || /prd\.md|需求原文/.test(r.text))) rep.error(`#${n} 驳回 needs evidence: an existing \`path:line\` that disproves it, or a quote location in prd.md`)
  }
  for (const n of reacted.keys()) if (resText && !nums.includes(n) && issues.length && !issues.some((r) => Number(col(r, ["编号"])) === n)) rep.warn(`design-review-resolution.md answers #${n}, which is not in the report`)

  // documents edited after the review are expected (that is the fix); say so, do not force a re-review
  const ref = existsSync(join(rdir, "design-review-resolution.md")) ? join(rdir, "design-review-resolution.md") : join(rdir, "design-review.md")
  const refTime = statSync(ref).mtimeMs
  const later = ["prd.md", "design.md", "implement.md"].filter((f) => existsSync(join(taskDir, f)) && statSync(join(taskDir, f)).mtimeMs > refTime + 1000)
  if (later.length) rep.warn(`${later.join(", ")} changed after the review was written — fine for blocker fixes; if the change is substantive run round ${(round ?? 1) + 1}`)
  return rep
}

// ───────────────────────── pre-start ─────────────────────────

function manifestsCheck(taskDir) {
  const man = new Report("manifests")
  for (const kind of ["implement", "check"]) {
    const p = join(taskDir, `${kind}.jsonl`)
    if (!existsSync(p)) continue
    const real = readJsonl(p).filter((e) => !String(e.reason || "").startsWith("[plus]"))
    if (real.length === 0) man.error(`${kind}.jsonl has no project spec/research entries besides the [plus] guides (step 1.3)`)
  }
  return man
}

function preStart(taskDir, cfg) {
  const ti = taskTier(taskDir)
  const tr = new Report(`tier  ${relative(ROOT, taskDir)}`)
  if (needTier(tr, ti)) return [tr]
  const reps = [runGate("align", cfg, "align", () => alignGate(taskDir, cfg, ti))]
  if (ti.tier !== "S") reps.push(runGate("lintPlan", cfg, "lint-plan", () => lintPlan(taskDir, cfg, ti)))
  if (ti.tier === "L") reps.push(runGate("designReview", cfg, "design-review", () => designReview(taskDir, cfg, ti)))
  reps.push(runGate("manifests", cfg, "manifests", () => manifestsCheck(taskDir)))
  return reps
}

// ───────────────────────── seed ─────────────────────────

const PRD_SKELETON_RE = /##\s+Requirements\s+-\s+TBD/

function cmdSeed(taskDir, cfg) {
  const ti = taskTier(taskDir)
  const rep = new Report("seed")
  if (ti.unset) { rep.error("set the tier first (a human decides): node .trellis/plus/gate.mjs tier <task> S|M|L [--reason \"…\"]"); rep.print(); return 1 }
  const tplDir = join(PLUS_DIR, "templates")
  const put = (src, dstRel) => {
    const dst = join(taskDir, dstRel)
    mkdirSync(dirname(dst), { recursive: true })
    if (existsSync(dst)) { rep.note(`${dstRel} exists — kept`); return }
    copyFileSync(join(tplDir, src), dst)
    rep.note(`created ${relative(ROOT, dst)}`)
  }
  // `task.py create` writes a prd.md skeleton ("Requirements - TBD"); an untouched one is replaced by the v2 structure.
  const prdPath = join(taskDir, "prd.md")
  const cur = read(prdPath)
  if (cur !== null && PRD_SKELETON_RE.test(cur) && !/^对齐状态[:：]/m.test(cur) && cur.length < 800) {
    copyFileSync(join(tplDir, "prd.md"), prdPath)
    rep.note("replaced the untouched Trellis prd.md skeleton with the plus structure (需求 R<n>, 决策记录, 对齐状态)")
  } else {
    if (cur !== null && !/^对齐状态[:：]/m.test(cur)) rep.warn("prd.md exists without the plus structure — add 对齐状态 / 需求(R<n>) / 决策记录 / 待确认问题 (see .trellis/plus/templates/prd.md)")
    put("prd.md", "prd.md")
  }
  if (ti.tier !== "S") { put("design.md", "design.md"); put("implement.md", "implement.md") }
  if (ti.tier === "L") { put("code-map.md", "research/code-map.md"); mkdirSync(join(taskDir, "reviews"), { recursive: true }) }
  if (ti.tier !== "S") {
    const guide = [".trellis/spec/guides/plus-testing-guide.md", "[plus] unit-test rules for Java 8 + JUnit5 + Mockito"]
    for (const kind of ["implement", "check"]) {
      const p = join(taskDir, `${kind}.jsonl`)
      if (!existsSync(p)) continue
      if (readJsonl(p).some((e) => e.file === guide[0])) continue
      appendFileSync(p, (read(p)?.endsWith("\n") || !read(p) ? "" : "\n") + JSON.stringify({ file: guide[0], reason: guide[1] }) + "\n")
      rep.note(`${kind}.jsonl += ${guide[0]}`)
    }
  }
  rep.note(ti.tier === "S" ? "Next: fill prd.md → `gate align` → step 1.3 / start" : ti.tier === "M" ? "Next: /grill-me with the user → decisions into prd.md → `gate align`; then draft (skill plus-draft) → `gate lint-plan`" : "Next: code map (trellis-research) → /grill-me → `gate align`; new session: draft (skill plus-draft) → `gate lint-plan` → design review")
  rep.print()
  return 0
}

// ───────────────────────── usage / status ─────────────────────────

function cmdUsage(taskDir, opts, cfg) {
  const ti = taskTier(taskDir)
  const f = join(taskDir, "usage.md")
  if (opts.phase && opts.tokens) {
    const n = Number(String(opts.tokens).replace(/[,_]/g, ""))
    if (!Number.isFinite(n) || n < 0) fail2("--tokens must be a number")
    if (!existsSync(f)) writeFileSync(f, "# Token 记录\n\n<!-- 人工从 opencode 会话界面读取，每个阶段结束记一行。目标是上限，未实测。OCR 不计入。 -->\n\n| 日期 | 阶段 | token | 备注 |\n| --- | --- | --- | --- |\n")
    const note = typeof opts.note === "string" ? opts.note.replace(/\|/g, "/") : ""
    appendFileSync(f, `| ${new Date().toISOString().slice(0, 10)} | ${String(opts.phase).replace(/\|/g, "/")} | ${n} | ${note} |\n`)
    console.log(`recorded ${n} tokens for "${opts.phase}"`)
  }
  const rows = existsSync(f) ? parseTable(read(f) ?? "") : []
  let total = 0
  for (const r of rows) { total += Number(col(r, ["token"]).replace(/[,_]/g, "")) || 0 }
  const budget = ti.tier ? cfg.tiers.budget[ti.tier] : null
  console.log(`tokens: ${total}${budget ? ` / ${budget} (tier ${ti.tier} target, not measured)` : ""}`)
  for (const r of rows) console.log(`  · ${col(r, ["阶段"])}: ${col(r, ["token"])}${col(r, ["备注"]) ? ` — ${col(r, ["备注"])}` : ""}`)
  if (budget && total > budget) { console.log(`  ! over the tier ${ti.tier} target — consider splitting the task or a lower tier`); return opts.check ? 1 : 0 }
  return 0
}

function cmdStatus(taskDir, cfg) {
  const rel = relative(ROOT, taskDir)
  const ti = taskTier(taskDir)
  console.log(`== status  ${rel} ==`)
  console.log(`  tier: ${ti.unset ? "(not set — propose S/M/L with reasons, ask the user, then `gate tier <task> S|M|L --reason …`)" : `${ti.tier}${ti.legacy ? " (legacy)" : ""}${ti.reason ? ` — ${ti.reason}` : ""}`}`)
  const L = cfg.limits
  const lim = { "prd.md": L.prd, "design.md": ti.tier === "M" ? L.designM : L.designL, "implement.md": L.implement, "research/code-map.md": L.codeMap }
  for (const [f, max] of Object.entries(lim)) {
    const t = read(join(taskDir, f))
    console.log(`  ${t === null ? "–" : bytesOf(t) > max ? "✗" : "✓"} ${f}${t === null ? " (absent)" : ` ${bytesOf(t)}/${max} bytes`}`)
  }
  for (const f of ["reviews/design-review.md", "reviews/design-review-resolution.md", "usage.md"]) console.log(`  ${existsSync(join(taskDir, f)) ? "✓" : "–"} ${f}`)
  if (ti.unset) { console.log("  next: propose the tier with reasons, let the user choose, then `gate seed <task>`"); return 0 }
  const steps = [["align", () => runGate("align", cfg, "align", () => alignGate(taskDir, cfg, ti)), "step 1.6: clarify with the user (/grill-me for M/L), fill prd.md, set 对齐状态：已对齐"]]
  if (ti.tier !== "S") steps.push(["lint-plan", () => runGate("lintPlan", cfg, "lint-plan", () => lintPlan(taskDir, cfg, ti)), "step 1.6: draft design.md / implement.md (skill plus-draft), fix what lint-plan lists"])
  if (ti.tier === "L") steps.push(["design-review", () => runGate("designReview", cfg, "design-review", () => designReview(taskDir, cfg, ti)), "step 1.7: dispatch plus-design-reviewer, answer every blocker in design-review-resolution.md"])
  let next = null
  for (const [name, run, hint] of steps) {
    const r = run()
    console.log(`  ${r.ok ? "✓" : "✗"} ${name}${r.ok ? "" : ` — ${r.errors.length} problem(s), first: ${r.errors[0].slice(0, 110)}`}${r.ok && r.warnings.length ? ` (${r.warnings.length} warning(s))` : ""}`)
    if (!r.ok && !next) next = hint
  }
  console.log(`  next: ${next ?? "plan gates pass — step 1.3 manifests, then `task.py start`; after coding: `gate test --run`, `gate ocr --run`"}`)
  return 0
}


// ───────────────────────── test gate ─────────────────────────

function isPureInterface(src) {
  const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "")
  return /\binterface\s+\w+/.test(code) && !/\b(default|static)\s+[\w<>\[\], ?]+\s+\w+\s*\(/.test(code)
}

function testCandidates(file, tg) {
  const out = []
  for (const m of tg.testPathMap) {
    const re = new RegExp(m.from)
    if (re.test(file)) out.push(file.replace(re, m.to))
  }
  // Impl-suffix stripping: FooServiceImpl → FooServiceTest
  for (const suf of tg.stripSuffixes || []) {
    const name = basename(file, ".java")
    if (name.endsWith(suf) && name.length > suf.length) {
      const stripped = file.replace(new RegExp(`${name}\\.java$`), `${name.slice(0, -suf.length)}.java`)
      for (const m of tg.testPathMap) {
        const re = new RegExp(m.from)
        if (re.test(stripped)) out.push(stripped.replace(re, m.to))
      }
    }
  }
  return [...new Set(out)]
}

/** Methods of a Java source with their line spans (approximate: one level of parentheses in parameter lists, comments/strings blanked). */
function javaMethods(src) {
  const clean = src.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])'/g, (m) => m.replace(/[^\n]/g, " "))
  const re = /(^|\n)[ \t]*((?:(?:public|protected|private|static|final|synchronized|abstract|default|native)\s+)*)(?:<[^>\n]+>\s+)?([\w.<>\[\]?, ]+?)\s+(\w+)\s*\(((?:[^()]|\([^()]*\))*)\)\s*(?:throws\s+[\w., ]+)?\s*\{/g
  const CONTROL = new Set(["if", "for", "while", "switch", "catch", "synchronized", "try", "else", "return", "new", "throw"])
  const lineAt = (idx) => clean.slice(0, idx).split("\n").length
  const out = []
  let m
  while ((m = re.exec(clean))) {
    const [, , mods, type, name] = m
    if (CONTROL.has(name) || CONTROL.has(type.trim().split(/\s+/)[0])) continue
    const open = m.index + m[0].length - 1
    let depth = 0, end = open
    for (let i = open; i < clean.length; i++) {
      if (clean[i] === "{") depth++
      else if (clean[i] === "}") { depth--; if (depth === 0) { end = i; break } }
    }
    out.push({ name, priv: /\bprivate\b/.test(mods), start: lineAt(m.index + (m[1] ? 1 : 0)), end: lineAt(end) })
  }
  return out
}

/** Names of the non-private methods whose lines changed (all of them for a new file). */
function changedMethodNames(file, base, staged) {
  const abs = resolve(ROOT, file)
  const methods = javaMethods(read(abs) ?? "").filter((m) => !m.priv)
  const added = git(staged ? ["diff", "--cached", "--name-only", "--diff-filter=A", "--relative"] : ["diff", "--name-only", "--diff-filter=A", "--relative", base])
  const untracked = git(["ls-files", "--others", "--exclude-standard"])
  const isNew = (added.ok && added.out.split("\n").includes(file)) || (untracked.ok && untracked.out.split("\n").includes(file))
  if (isNew) return new Set(methods.map((m) => m.name))
  const d = git(["diff", "-U0", "--relative", ...(staged ? ["--cached"] : [base]), "--", file])
  const names = new Set()
  if (!d.ok) return names
  for (const h of d.out.matchAll(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/gm)) {
    const a = Number(h[1]), n = h[2] === undefined ? 1 : Number(h[2])
    const b = n === 0 ? a : a + n - 1
    for (const m of methods) if (m.start <= b && m.end >= a) names.add(m.name)
  }
  return names
}

/** opts: { base, staged }. staged=true looks at the git index only (pre-commit hook). Returns the report and the test classes grouped per Maven module. */
function testGate(taskDir, cfg, opts = {}) {
  const tg = cfg.testGate
  const rep = new Report("test-gate (every changed Service/Controller needs a unit test)")
  const staged = !!opts.staged
  const base = typeof opts.base === "string" ? opts.base : "HEAD"
  const changed = changedFiles(base, staged)
  const changedSet = new Set(changed)
  rep.note(staged ? `staged: ${changed.length} file(s)` : `base=${base}, ${changed.length} changed file(s)`)
  const groups = new Map() // module -> Set(test class)
  const targets = changed.filter((f) => matchAny(tg.include, f) && !matchAny(tg.exclude, f) && existsSync(resolve(ROOT, f)))
  const ti = taskDir ? taskTier(taskDir) : null
  if (targets.length === 0) {
    rep.note("no changed Service/Controller sources matched testGate.include" + (!staged && base === "HEAD" ? " (already committed? pass --base <branch>)" : ""))
    return { rep, groups }
  }
  const exempt = taskDir ? parseExemptions(findSection(sectionsOf(read(join(taskDir, "implement.md")) ?? ""), "测试豁免")?.body ?? "") : new Map()
  const concrete = []
  for (const f of targets) {
    const src = read(resolve(ROOT, f)) ?? ""
    if (tg.skipInterfaces && isPureInterface(src)) { rep.note(`skip (pure interface): ${f}`); continue }
    if (exempt.has(f)) { rep.warn(`EXEMPT ${f} — ${exempt.get(f)} (needs human sign-off)`); continue }
    concrete.push(f)
    const cands = testCandidates(f, tg)
    const existing = cands.filter((c) => existsSync(resolve(ROOT, c)))
    if (existing.length === 0) { rep.error(`${f}\n      no unit test found in module "${moduleOf(f) || "."}". Expected one of:\n        ${cands.join("\n        ")}`); continue }
    const t = existing[0]
    if (tg.requireTestChanged && !existing.some((c) => changedSet.has(c))) {
      rep.error(`${f}\n      test ${t} exists but was not added/modified in this change — update it to cover the new behavior`)
      continue
    }
    if (tg.requireTestAnnotation) {
      const re = new RegExp(tg.testAnnotationPattern)
      if (!existing.some((c) => re.test(read(resolve(ROOT, c)) ?? ""))) { rep.error(`${t} contains no JUnit test method (${tg.testAnnotationPattern})`); continue }
    }
    // approximate method-level check: every changed non-private Service method is referenced by the test class (Controllers are driven by path, not by name)
    if (tg.methodLevel !== "off" && !/Controller$/.test(basename(f, ".java"))) {
      const testText = existing.map((c) => read(resolve(ROOT, c)) ?? "").join("\n")
      const missing = [...changedMethodNames(f, base, staged)].filter((n) => !new RegExp(`\\b${n.replace(/\$/g, "\\$")}\\b`).test(testText))
      if (missing.length) {
        const msg = `${f}\n      changed method(s) never referenced by ${basename(t)}: ${missing.join(", ")} (name-based approximation; add a test that calls them)`
        if (tg.methodLevel === "error") { rep.error(msg); continue } else rep.warn(msg)
      }
    }
    rep.note(`ok  ${f}  ←  ${existing.join(", ")}`)
    const mod = moduleOf(f)
    if (!groups.has(mod)) groups.set(mod, new Set())
    for (const c of existing) groups.get(mod).add(basename(c, ".java"))
  }
  // Tier limits: S never changes Service/Controller code; M stays small (<= maxClassesM classes, one module).
  if (ti && !ti.unset && concrete.length > 0) {
    const label = ti.legacy && ti.tier === "S" ? "marked lightweight" : `tier ${ti.tier}`
    if (ti.tier === "S") rep.error(`task is ${label}${ti.reason ? ` (${ti.reason})` : ""} but changes ${concrete.length} Service/Controller file(s): ${concrete.slice(0, 3).join(", ")}${concrete.length > 3 ? ", …" : ""}.\n      Tier S is not allowed here — raise it: \`gate tier <task> M|L\`, then \`gate seed <task>\` and write design.md / implement.md`)
    else if (ti.tier === "M") {
      const mods = new Set(concrete.map(moduleOf))
      if (concrete.length > cfg.tiers.maxClassesM || mods.size > 1) rep.error(`tier M allows at most ${cfg.tiers.maxClassesM} Service/Controller classes in one module; this change has ${concrete.length} in ${mods.size} module(s) — raise the tier: \`gate tier <task> L\``)
    }
  }
  return { rep, groups }
}

function runTests(groups, cfg) {
  const rep = new Report("test run")
  if (groups.size === 0) { rep.note("nothing to run"); return rep }
  for (const [mod, classes] of groups) {
    const tpl = mod ? cfg.testGate.runCommand.replace("{module}", mod) : cfg.testGate.runCommandRoot
    const cmd = tpl.replace("{classes}", [...classes].join(","))
    rep.note(`$ ${cmd}`)
    const r = spawnSync(cmd, { cwd: ROOT, shell: true, stdio: "inherit" })
    if (r.status !== 0) rep.error(`test command for module "${mod || "."}" exited with ${r.status}`)
  }
  return rep
}

// ───────────────────────── ocr gate ─────────────────────────

const SEV_ORDER = ["critical", "high", "medium", "low"]
function normSeverity(s) {
  const v = String(s ?? "").toLowerCase().trim()
  if (/^(critical|blocker|fatal)$/.test(v)) return "critical"
  if (/^(high|major|error)$/.test(v)) return "high"
  if (/^(medium|moderate|warning|warn)$/.test(v)) return "medium"
  if (/^(low|minor|info|suggestion|nit)$/.test(v)) return "low"
  return "medium" // unknown / missing: still has to be triaged
}

const FINDING_KEYS = {
  file: ["file", "path", "filename", "file_path", "filePath"],
  line: ["line", "start_line", "startLine", "line_number", "lineNumber", "range", "position"],
  msg: ["comment", "message", "content", "description", "title", "issue", "body", "text"],
  sev: ["severity", "level", "priority", "risk"],
}
const toLine = (v) => {
  if (typeof v === "number") return v
  if (typeof v === "string" && /^\d+/.test(v)) return Number(v.match(/^\d+/)[0])
  if (Array.isArray(v)) return toLine(v[0])
  if (v && typeof v === "object") return toLine(v.start ?? v.line ?? v.startLine ?? v.begin)
  return null
}

/**
 * The OCR JSON schema is not pinned here (UNVERIFIED): any object that carries a file key, a line key AND a message key is a finding.
 * `gate ocr --inspect` shows what was extracted so the extraction can be tightened once a real report is available.
 */
function extractFindings(root) {
  const out = []
  const K = FINDING_KEYS
  // Verified shape (ocr v1.9.8, `--format json`): { status, message, summary, comments: [ { path, content, start_line, end_line, category, severity, existing_code, suggestion_code? } ], manifest }.
  // `comments` is the single source of truth. EVERY entry is a finding (a missing field never drops it: dropping = a silent pass); the rest of the document (manifest, summary) is not scanned.
  if (root && !Array.isArray(root) && typeof root === "object" && Array.isArray(root.comments)) {
    return root.comments.filter((c) => c && typeof c === "object").map((c) => {
      const keys = Object.keys(c)
      const fk = K.file.find((x) => keys.includes(x)), lk = K.line.find((x) => keys.includes(x)), mk = K.msg.find((x) => keys.includes(x)), sk = K.sev.find((x) => keys.includes(x))
      return { file: fk ? String(c[fk]) : "", line: lk ? toLine(c[lk]) : null, severity: normSeverity(sk ? c[sk] : undefined), message: mk ? String(c[mk]).replace(/\s+/g, " ") : JSON.stringify(c).slice(0, 120), keys: { file: fk ?? null, line: lk ?? null, msg: mk ?? null, sev: sk ?? null } }
    })
  }
  const walk = (v) => {
    if (Array.isArray(v)) return v.forEach(walk)
    if (v && typeof v === "object") {
      const keys = Object.keys(v)
      const fk = K.file.find((x) => keys.includes(x)), lk = K.line.find((x) => keys.includes(x)), mk = K.msg.find((x) => keys.includes(x))
      if (fk && lk && mk) {
        const sk = K.sev.find((x) => keys.includes(x))
        out.push({ file: String(v[fk]), line: toLine(v[lk]), severity: normSeverity(sk ? v[sk] : undefined), message: String(v[mk]).replace(/\s+/g, " "), keys: { file: fk, line: lk, msg: mk, sev: sk ?? null } })
      } else Object.values(v).forEach(walk)
    }
  }
  walk(root)
  return out
}

/** status / failed items of an ocr report (`status` is "complete" or "partial"; manifest.coverage.failed lists the files that were NOT reviewed). */
function reportMeta(root) {
  if (!root || Array.isArray(root) || typeof root !== "object") return null
  const failed = Array.isArray(root.manifest?.coverage?.failed) ? root.manifest.coverage.failed.map((f) => String(f?.path ?? "?")) : []
  const cov = root.manifest?.coverage
  const selected = Array.isArray(cov?.selected) ? cov.selected.length : null, completed = Array.isArray(cov?.completed) ? cov.completed.length : null
  return { status: typeof root.status === "string" ? root.status : null, message: typeof root.message === "string" ? root.message : "", failed, selected, completed }
}

/** The JSON document in a text that may also carry log lines: tries every line that starts an object / array and parses to the end. */
function jsonFromText(text) {
  const lines = String(text ?? "").split("\n")
  let pos = 0
  for (const l of lines) {
    if (/^[{[]/.test(l)) {
      try { const j = JSON.parse(text.slice(pos)); if (j && typeof j === "object") return j } catch { /* not the start of the report (e.g. a "[ocr] …" log line) */ }
    }
    pos += l.length + 1
  }
  return null
}

const TRIAGE_RE = /^\s*[-*]\s*\[(fixed|false-positive|deferred|pending)\]\s+(\S+?)(?::(\d+))?\s+[—–-]\s+(.*)$/i
const TRIAGE_LOOSE_RE = /^\s*[-*]\s*\[(fixed|false-positive|deferred|pending)\]/i
function parseTriage(txt) {
  const entries = []
  let loose = 0
  for (const l of txt.split("\n")) {
    if (TRIAGE_LOOSE_RE.test(l)) loose++
    const m = l.match(TRIAGE_RE)
    if (m) entries.push({ status: m[1].toLowerCase(), file: m[2].replace(/\\/g, "/"), line: m[3] ? Number(m[3]) : null, note: m[4].trim(), used: false })
  }
  return { entries, loose }
}

function matchEntry(f, entries) {
  const bn = basename(f.file.replace(/\\/g, "/"))
  // one triage line per finding: an entry already used by another finding is not reused (two findings on the same file:line need two lines)
  const c = entries.filter((e) => !e.used && basename(e.file) === bn && (e.line == null || f.line == null || e.line === f.line))
  return c.find((e) => e.line != null && e.line === f.line) ?? c[0] ?? null
}

/** A false-positive on a blocking finding must cite code: `path:line` pointing at a real file/line. */
function hasCodeEvidence(note) {
  for (const m of note.matchAll(/([\w./\\-]+\.\w+):(\d+)/g)) {
    const abs = resolve(ROOT, m[1])
    if (abs.startsWith(ROOT) && existsSync(abs) && Number(m[2]) >= 1 && Number(m[2]) <= (read(abs) ?? "").split("\n").length) return true
  }
  return false
}

function latestOcr(rdir) {
  const files = existsSync(rdir) ? readdirSync(rdir).map((f) => f.match(/^ocr-r(\d+)\.json$/)).filter(Boolean) : []
  if (!files.length) return null
  const n = Math.max(...files.map((m) => Number(m[1])))
  return { n, path: join(rdir, `ocr-r${n}.json`) }
}

/** Short task summary handed to ocr (--background-file): requirements, decisions, planned files. Never the whole plan. */
function buildBackground(taskDir, cfg) {
  const max = cfg.ocr.backgroundMaxChars
  let tj = {}
  try { tj = JSON.parse(read(join(taskDir, "task.json")) ?? "{}") } catch { /* ignore */ }
  const prd = stripComments(read(join(taskDir, "prd.md")) ?? "")
  const impl = stripComments(read(join(taskDir, "implement.md")) ?? "")
  const pSecs = sectionsOf(prd)
  const reqLines = sectionItems(findSection(pSecs, "需求")?.body ?? "").map((i) => i.text.replace(/\s+/g, " ").slice(0, 160)).slice(0, 15)
  const decLines = parseTable(findSection(pSecs, "决策记录")?.body ?? "").map((r) => Object.values(r).slice(0, 3).join(" | ").slice(0, 160)).slice(0, 8)
  const files = [...new Set([...(findSection(sectionsOf(impl), "实施步骤")?.body ?? "").matchAll(/`((?:[\w.\-]+\/)+[\w.\-]+\.[A-Za-z]{1,10})`/g)].map((m) => m[1]))].slice(0, 30)
  const ex = (findSection(sectionsOf(impl), "测试豁免")?.body ?? "").trim()
  let exLines = NONE_RE.test(ex.replace(/\s+/g, " ")) || !ex ? [] : ex.split("\n").map((l) => l.trim()).filter(Boolean)
  let truncated = false
  const render = () => [
    "# Review background (generated by trellis-plus)",
    "",
    `Task: ${String(tj.title ?? basename(taskDir)).replace(/\s+/g, " ").slice(0, 120)}${tj.description ? " — " + String(tj.description).replace(/\s+/g, " ").slice(0, 200) : ""}`,
    "",
    ...(reqLines.length ? ["## Requirements (prd.md)", ...reqLines, ""] : []),
    ...(decLines.length ? ["## Decisions", ...decLines, ""] : []),
    ...(files.length ? ["## Planned files (implement.md)", ...files.map((f) => `- ${f}`), ""] : []),
    ...(exLines.length ? ["## Test exemptions", ...exLines, ""] : []),
    "## Review instructions",
    "1. Check the implementation against the requirements and planned files above.",
    "2. Point out every change that is NOT planned.",
    "3. Pay special attention to transaction boundaries, concurrency / idempotency and exception handling.",
    ...(truncated ? ["", "(truncated)"] : []),
  ].join("\n") + "\n"
  let out = render()
  const shrink = (arr, keep) => { while (out.length > max && arr.length > keep) { arr.pop(); truncated = true; out = render() } }
  shrink(exLines, 0); shrink(files, 3); shrink(decLines, 0); shrink(reqLines, 3)
  if (out.length > max) { truncated = true; out = render().slice(0, max - 15) + "\n(truncated)\n" }
  const p = join(taskDir, "reviews", "ocr-background.md")
  mkdirSync(dirname(p), { recursive: true })
  writeFileSync(p, out)
  return p
}

/** Does this report contain at least one finding of a blocking severity? */
function hasBlocking(path, oc) {
  try { return extractFindings(JSON.parse(readFileSync(path, "utf8"))).some((f) => oc.blockingSeverities.includes(f.severity)) } catch { return true }
}

function ocrGate(taskDir, cfg, opts = {}) {
  const oc = cfg.ocr
  const rep = new Report("ocr-gate (alibaba/open-code-review)")
  if (!oc.enabled) { rep.note("ocr disabled in plus.config.json"); return rep }
  if (!taskDir) {
    if (TASK_AMBIGUOUS) {
      const m = `${TASK_AMBIGUOUS.length} tasks are in_progress (${TASK_AMBIGUOUS.join(", ")}) and nothing says which one this commit belongs to — set TRELLIS_PLUS_TASK=<task> or pass --task`
      if (opts.hook) rep.warn(`OCR check skipped: ${m}`); else rep.error(m)
    } else if (opts.hook) rep.note("no in_progress task — OCR check skipped (this commit is not part of a Trellis task)")
    else rep.error("active task not found; pass --task <dir> (or set TRELLIS_PLUS_TASK)")
    return rep
  }
  const rdir = join(taskDir, "reviews")
  mkdirSync(rdir, { recursive: true })
  const taskRel = relative(ROOT, taskDir)

  if (opts.run) {
    const cur0 = latestOcr(rdir)
    const n = (cur0?.n ?? 0) + 1
    // Budget rule: the first run is free; a rerun only makes sense after critical/high findings were fixed, and is capped.
    if (cur0 && !opts.force) {
      if (n > 1 + oc.maxRerun) { rep.error(`ocr round ${n} would be rerun #${n - 1} (> ocr.maxRerun=${oc.maxRerun}) — stop and let the human decide (override: --force)`); return rep }
      if (!hasBlocking(cur0.path, oc)) { rep.error(`ocr-r${cur0.n}.json has no ${oc.blockingSeverities.join("/")} finding, so no rerun is needed — triage the medium/low findings instead (override: --force)`); return rep }
    }
    // Availability = `ocr llm test` (is an LLM provider configured and reachable?). No version or git checks, no install hints.
    let why = ""
    if (oc.mode === "delegate") why = 'ocr.mode is "delegate"'
    else {
      const t = spawnSync(oc.command, ["llm", "test"], { cwd: ROOT, encoding: "utf8", timeout: 5 * 60 * 1000 })
      if (t.error || t.status !== 0) why = t.error ? `\`${oc.command}\` not found` : `\`${oc.command} llm test\` exited with ${t.status}${(t.stderr || "").trim() ? ` (${(t.stderr || "").trim().split("\n")[0].slice(0, 100)})` : ""}`
    }
    if (why) {
      if (oc.mode === "cli") { rep.error(`${why} — ocr.mode is "cli", so there is no fallback (fix \`ocr llm test\`, or set ocr.mode to "auto")`); return rep }
      const out = join(rdir, `ocr-r${n}.json`)
      const bgp = oc.background ? relative(ROOT, buildBackground(taskDir, cfg)) : null
      rep.warn(`OCR is not usable (${why}) → DELEGATION MODE: you review the code yourself`)
      rep.note(`1. Review the changed source files (\`git diff HEAD\` + untracked files) against prd.md${bgp ? ` and ${bgp}` : ""}: bugs, security, transaction/concurrency/idempotency, unplanned changes.`)
      rep.note(`2. Write ${relative(ROOT, out)} as: {"status":"complete","comments":[{"path":"<file>","start_line":<n>,"end_line":<n>,"severity":"critical|high|medium|low","category":"bug|security|maintainability","content":"<what is wrong and the fix>"}]}`)
      rep.note(`3. Triage every comment into ${relative(ROOT, taskDir)}/reviews/ocr-triage.md as usual, then verify: node .trellis/plus/gate.mjs ocr --task ${relative(ROOT, taskDir)}`)
      return rep
    }
    const out = join(rdir, `ocr-r${n}.json`)
    // Verified against `ocr review --help` (real ocr): there is NO --output flag. With --format json the report is printed on stdout
    // (progress lines go to stderr; --audience agent = summary only), so the gate captures stdout and saves it as ocr-r<N>.json.
    const base = ["review", "--audience", "agent", "--format", "json"]
    const bg = oc.background ? ["--background-file", buildBackground(taskDir, cfg)] : []
    const exec = (extra) => {
      rep.note(`$ ${oc.command} ${[...base, ...extra, ...oc.extraArgs].join(" ")}`)
      const r = spawnSync(oc.command, [...base, ...extra, ...oc.extraArgs], { cwd: ROOT, stdio: ["inherit", "pipe", "pipe"], encoding: "utf8", timeout: 20 * 60 * 1000, maxBuffer: 256 * 1024 * 1024 })
      if (r.stderr) process.stderr.write(r.stderr)
      return r
    }
    let r = exec(bg)
    if (r.status !== 0 && bg.length && /background/i.test(r.stderr || "") && /unknown (flag|shorthand)|flag provided but not defined|unrecognized/i.test(r.stderr || "")) {
      rep.warn("this ocr build does not know --background-file; retrying without the task background")
      r = exec([])
    }
    const j = r.stdout ? jsonFromText(r.stdout) : null
    if (!j) {
      if (r.stdout && r.stdout.trim()) process.stdout.write(r.stdout)
      rep.error(`ocr exited with ${r.status ?? r.error?.message} and printed no JSON report on stdout`)
      return rep
    }
    writeFileSync(out, JSON.stringify(j, null, 2) + "\n") // the full report stays on disk; it is not echoed into the conversation
    if (r.status !== 0) rep.warn(`ocr exited with ${r.status} (JSON report printed; exit code semantics not verified — check output)`)
    rep.note(`report: ${relative(ROOT, out)} — now triage every finding into ${taskRel}/reviews/ocr-triage.md (skill plus-ocr-review)`)
  }

  const cur = latestOcr(rdir)
  if (!cur) { rep.error(`no reviews/ocr-rN.json. Run: node .trellis/plus/gate.mjs ocr --task ${taskRel} --run`); return rep }
  rep.note(`latest report: ${relative(ROOT, cur.path)}`)

  let findings = []
  try {
    const doc = JSON.parse(readFileSync(cur.path, "utf8"))
    findings = extractFindings(doc)
    const meta = reportMeta(doc)
    const claimed = doc && typeof doc === "object" && !Array.isArray(doc) && typeof doc.summary?.comments === "number" ? doc.summary.comments : null
    if (claimed !== null && claimed !== findings.length) rep.error(`report says summary.comments=${claimed} but ${findings.length} comment(s) were extracted — the report is incomplete or its shape changed (a finding must never be dropped silently)`)
    if (meta && meta.selected > 0 && meta.completed === 0) rep.error(`ocr reviewed none of the ${meta.selected} selected file(s)${meta.message ? ` (${meta.message})` : ""} — an empty finding list here is NOT a clean review; re-run, or review in delegation mode`)
    if (meta && meta.status && meta.status !== "complete") rep.warn(`ocr report status is "${meta.status}"${meta.message ? ` (${meta.message})` : ""}${meta.failed.length ? `; NOT reviewed: ${meta.failed.slice(0, 5).map((f) => basename(f)).join(", ")}${meta.failed.length > 5 ? ", …" : ""}` : ""} — re-run, or review those files yourself before commit`)
  } catch (e) { rep.error(`${basename(cur.path)} is not valid JSON: ${e.message}`); return rep }

  if (opts.inspect) {
    rep.note(`${findings.length} finding(s) extracted (comments[] of the report; FINDING_KEYS only maps the field names):`)
    for (const f of findings) rep.note(`[${f.severity}] ${f.file}:${f.line ?? "?"}  ${f.message.slice(0, 70)}   (keys: file=${f.keys.file} line=${f.keys.line} msg=${f.keys.msg} severity=${f.keys.sev ?? "—"})`)
    return rep
  }

  // stale: any changed *source* file newer than the report
  const mtime = statSync(cur.path).mtimeMs
  const stale = changedFiles("HEAD").filter((f) => isSource(f, oc) && existsSync(resolve(ROOT, f)) && statSync(resolve(ROOT, f)).mtimeMs > mtime + 1000)
  if (stale.length) rep.error(`report is STALE — ${stale.length} file(s) changed after it (e.g. ${stale.slice(0, 3).join(", ")}). Re-run with --run`)

  const bySev = Object.fromEntries(SEV_ORDER.map((s) => [s, findings.filter((f) => f.severity === s).length]))
  rep.note(`findings: ${findings.length} (${SEV_ORDER.map((s) => `${s} ${bySev[s]}`).join(", ")})`)
  if (findings.length === 0) return rep

  const triage = read(join(rdir, "ocr-triage.md"))
  if (!triage) { rep.error(`${findings.length} finding(s) need triage but reviews/ocr-triage.md is missing`); return rep }
  const rn = (triage.match(/^Report:\s*ocr-r(\d+)\.json/mi) || [])[1]
  if (Number(rn) !== cur.n) rep.error(`ocr-triage.md refers to ocr-r${rn ?? "?"}.json but the latest report is ocr-r${cur.n}.json (header line "Report: ocr-r${cur.n}.json")`)
  const { entries, loose } = parseTriage(triage)
  const count = (s) => entries.filter((e) => e.status === s).length
  rep.note(`triage: ${loose} entr(ies) — fixed ${count("fixed")}, false-positive ${count("false-positive")}, deferred ${count("deferred")}, pending ${count("pending")}`)
  if (count("pending")) rep.error(`${count("pending")} finding(s) still [pending]`)

  let deferredNonBlocking = 0
  const withFile = findings.filter((f) => f.file && f.file !== "undefined")
  for (const f of withFile) {
    const where = `${basename(f.file)}:${f.line ?? "?"}`
    const e = matchEntry(f, entries)
    if (!e) { rep.error(`finding not triaged: [${f.severity}] ${where} ${f.message.slice(0, 60)}`); continue }
    e.used = true
    if (e.status === "pending") continue
    const blocking = oc.blockingSeverities.includes(f.severity)
    if (blocking && e.status === "deferred") rep.error(`[${f.severity}] ${where} was deferred — ${f.severity} findings must be fixed or proven false-positive`)
    else if (blocking && e.status === "false-positive" && !hasCodeEvidence(e.note)) rep.error(`[${f.severity}] ${where} marked false-positive without code evidence — cite an existing \`path:line\` that disproves it`)
    else if (!blocking && e.status === "false-positive" && e.note.length < 10) rep.error(`${where} false-positive needs a reason (>= 10 chars)`)
    else if (!blocking && e.status === "deferred") deferredNonBlocking++
  }
  // findings without a usable file name can only be checked by count
  const fileless = findings.length - withFile.length
  if (fileless > 0) {
    const spare = loose - entries.filter((e) => e.used).length
    if (spare < fileless) rep.error(`${fileless} finding(s) have no file name in the report; triage needs ${fileless} more entr(ies) (has ${Math.max(spare, 0)})`)
  }
  if (deferredNonBlocking) rep.warn(`${deferredNonBlocking} deferred finding(s) — need explicit user decision before commit`)
  return rep
}

// ───────────────────────── main ─────────────────────────

function usage() {
  const lines = readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n")
  console.log(lines.slice(0, lines.indexOf(" */") + 1).join("\n"))
}

function main() {
  const { pos, opts } = parseArgs(process.argv.slice(2))
  const cmd = pos[0]
  const cfg = loadConfig()
  CFG = cfg
  const taskArg = pos[1]
  let code = 0
  const reps = []

  switch (cmd) {
    case "tier": return process.exit(cmdTier(resolveTask(taskArg), pos[2], opts, cfg))
    case "lightweight": console.log("note: `lightweight` is deprecated — use `gate tier <task> S --reason \"…\"`"); return process.exit(cmdTier(resolveTask(taskArg), "S", opts, cfg))
    case "seed": return process.exit(cmdSeed(resolveTask(taskArg), cfg))
    case "status": return process.exit(cmdStatus(resolveTask(taskArg), cfg))
    case "usage": return process.exit(cmdUsage(resolveTask(taskArg), opts, cfg))
    case "matrix": return process.exit(cmdMatrix(resolveTask(taskArg), opts))
    case "hash": console.error("`hash` was removed in v2 (the review is no longer bound to a document hash)"); return process.exit(2)
    case "gates": return process.exit(cmdGates(cfg))
    case "align": reps.push(runGate("align", cfg, "align", () => alignGate(resolveTask(taskArg), cfg))); break
    case "anchors": reps.push(anchorsGate(resolveTask(taskArg), cfg)); break
    case "lint-plan": reps.push(runGate("lintPlan", cfg, "lint-plan", () => lintPlan(resolveTask(taskArg), cfg))); break
    case "design-review": reps.push(runGate("designReview", cfg, "design-review", () => designReview(resolveTask(taskArg), cfg))); break
    case "pre-start": reps.push(...preStart(resolveTask(taskArg), cfg)); break
    case "test": {
      const t = taskFromOpts(opts)
      if (gateMode(cfg, "test") === "off") { reps.push(skippedReport("test-gate", "test")); break }
      const { rep, groups } = testGate(t, cfg, { base: opts.base, staged: !!opts.staged })
      reps.push(applyMode(rep, cfg, "test"))
      if (opts.run && rep.ok) reps.push(runTests(groups, cfg))
      break
    }
    case "ocr": reps.push(runGate("ocr", cfg, "ocr-gate", () => ocrGate(taskFromOpts(opts), cfg, opts))); break
    case "pre-commit": {
      const hook = !!opts.hook
      if (hook && process.env.TRELLIS_PLUS_SKIP_GATE) { console.log("trellis-plus pre-commit: TRELLIS_PLUS_SKIP_GATE is set — skipped"); return process.exit(0) }
      if (hook && gateMode(cfg, "hook") === "off") { console.log(`trellis-plus pre-commit: the hook is off (${gateInfo(cfg, "hook").from}) — skipped`); return process.exit(0) }
      const staged = hook || !!opts.staged
      if (hook) {
        const sf = changedFiles("HEAD", true)
        if (!sf.some((f) => isSource(f, cfg.ocr) || matchAny(cfg.testGate.include, f))) {
          console.log("trellis-plus pre-commit: nothing to gate (no staged source files)")
          return process.exit(0)
        }
      }
      const t = taskFromOpts(opts)
      if (gateMode(cfg, "test") === "off") reps.push(skippedReport("test-gate", "test"))
      else {
        const { rep, groups } = testGate(t, cfg, { base: opts.base, staged })
        reps.push(applyMode(rep, cfg, "test"))
        if ((opts.run || (hook && cfg.hook.runTests)) && rep.ok) reps.push(runTests(groups, cfg))
      }
      if (cfg.ocr.enabled && cfg.ocr.required) reps.push(runGate("ocr", cfg, "ocr-gate", () => ocrGate(t, cfg, { ...opts, run: false, staged, hook })))
      for (const r of reps) { r.print(); if (!r.ok) code = 1 }
      if (code && hook && gateMode(cfg, "hook") === "warn") { console.log("\ntrellis-plus pre-commit: (gates.hook=warn) the checks above would block this commit; letting it through"); return process.exit(0) }
      if (code && hook) {
        console.error(`\ntrellis-plus: commit blocked by the pre-commit hook.${t ? `\n  OCR:  node .trellis/plus/gate.mjs ocr --task ${relative(ROOT, t)} --run   (then triage reviews/ocr-triage.md)` : ""}\n  Tests: node .trellis/plus/gate.mjs test${t ? ` --task ${relative(ROOT, t)}` : ""} --run\n  Deliberate bypass (sparingly): TRELLIS_PLUS_SKIP_GATE=1 git commit …   or   git commit --no-verify`)
      }
      return process.exit(code)
    }
    default:
      usage()
      return process.exit(cmd ? 2 : 0)
  }
  for (const r of reps) { r.print(); if (!r.ok) code = 1 }
  process.exit(code)
}

main()
