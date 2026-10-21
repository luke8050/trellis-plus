#!/usr/bin/env node
/**
 * trellis-plus v2 — enhance a `trellis init`-ed project (OpenCode platform) with:
 *   0. tiers S/M/L chosen by a human: small tasks stay cheap, only L gets the full flow
 *   1. clarification with the user (optional `/grill-me`) recorded in prd.md + a code-grounded design.md / implement.md at reviewable granularity
 *   2. mandatory unit tests for every changed Java Service/Controller (JUnit5 + Mockito, Maven multi-module)
 *   3. ONE independent design reviewer (L tier) with a mechanical blocker/resolution check
 *   4. alibaba/open-code-review step with severity-aware triage before commit
 *   5. git pre-commit hook as the last deterministic line of defence
 *
 * Usage (the tool can live anywhere — pass the Trellis project path; no need to copy it into the project):
 *   node trellis-plus.mjs apply  <project> [--dry-run] [--hard-gate] [--patch-plugin] [--tune-context]
 *                                          [--patch-agents] [--git-hook] [--all] [--force]
 *   node trellis-plus.mjs doctor <project> [--fix]
 *   node trellis-plus.mjs revert <project> [--purge]
 *
 * <project> = the directory that contains .trellis/ and .opencode/ (defaults to the current directory;
 * `--root <project>` is accepted as an alias). Run it after `trellis init` / `trellis update`.
 * `--all` = hard gate + plugin patch + agent patch + git hook (it rewrites .git/hooks/pre-commit and two agent files).
 *
 * apply is idempotent. Re-run it (or `doctor --fix`) after every `trellis update`, because update may
 * replace workflow.md / task.py / plugin files / agent files that this tool patches.
 *
 * Zero dependencies, Node >= 18.
 */
import {
  existsSync, readFileSync, writeFileSync, mkdirSync, readdirSync, statSync, copyFileSync, rmSync, chmodSync, realpathSync,
} from "node:fs"
import { join, resolve, dirname, relative, sep } from "node:path"
import { createHash } from "node:crypto"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"

const TOOL_VERSION = "2.1.0"
const HERE = dirname(fileURLToPath(import.meta.url))
const ASSETS = join(HERE, "assets")

// ───────────── args ─────────────

const argv = process.argv.slice(2)
const command = argv[0] && !argv[0].startsWith("--") ? argv[0] : "help"
const flag = (n) => argv.includes(`--${n}`)
const opt = (n) => { const i = argv.indexOf(`--${n}`); return i >= 0 && argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[i + 1] : null }
// positional project path: first non-flag token after the command that is not the value of --root
const positional = argv.slice(1).filter((a, i, arr) => !a.startsWith("--") && arr[i - 1] !== "--root")
const rootArg = opt("root") ?? positional[0] ?? process.cwd()
const ROOT = resolve(rootArg)
const DRY = flag("dry-run")
const FORCE = flag("force")
const ALL = flag("all")

const P = {
  workflow: ".trellis/workflow.md",
  config: ".trellis/config.yaml",
  taskpy: ".trellis/scripts/task.py",
  ctxjs: ".opencode/lib/trellis-context.js",
  plusDir: ".trellis/plus",
  manifest: ".trellis/plus/manifest.json",
  backup: ".trellis/plus/backup",
}

// ───────────── tiny fs layer (dry-run aware) ─────────────

const log = { ok: (m) => console.log(`  ✓ ${m}`), info: (m) => console.log(`  · ${m}`), warn: (m) => console.log(`  ! ${m}`), err: (m) => console.log(`  ✗ ${m}`) }
const abs = (rel) => join(ROOT, rel)
const exists = (rel) => existsSync(abs(rel))
const readRel = (rel) => (exists(rel) ? readFileSync(abs(rel), "utf8") : null)
const sha = (s) => createHash("sha256").update(s).digest("hex")
const stamp = new Date().toISOString().replace(/[:.]/g, "-")
const backedUp = new Set()

function writeRel(rel, content) {
  if (DRY) return
  mkdirSync(dirname(abs(rel)), { recursive: true })
  writeFileSync(abs(rel), content)
}
function backup(rel) {
  if (DRY || backedUp.has(rel) || !exists(rel)) return
  const dst = join(abs(P.backup), stamp, rel)
  mkdirSync(dirname(dst), { recursive: true })
  copyFileSync(abs(rel), dst)
  backedUp.add(rel)
}
function walk(dir, base = dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = join(dir, d.name)
    return d.isDirectory() ? walk(p, base) : [relative(base, p).split("\\").join("/")]
  })
}

// ───────────── managed (new) files ─────────────

/** [assetRelPath, projectRelPath, createOnly] */
function managedFiles() {
  const out = []
  for (const f of walk(join(ASSETS, "agents"))) out.push([`agents/${f}`, `.opencode/agents/${f}`, false])
  for (const f of walk(join(ASSETS, "skills"))) out.push([`skills/${f}`, `.opencode/skills/${f}`, false])
  if (existsSync(join(ASSETS, "commands"))) for (const f of walk(join(ASSETS, "commands"))) out.push([`commands/${f}`, `.opencode/commands/${f}`, false])
  for (const f of walk(join(ASSETS, "spec"))) out.push([`spec/${f}`, `.trellis/spec/guides/${f}`, false])
  for (const f of walk(join(ASSETS, "plus"))) {
    out.push([`plus/${f}`, `.trellis/plus/${f}`, f === "plus.config.json"])
  }
  return out
}

function loadManifest() {
  try { return JSON.parse(readRel(P.manifest) ?? "null") ?? { files: {}, options: {} } } catch { return { files: {}, options: {} } }
}

function installFiles(manifest) {
  let created = 0, updated = 0, same = 0, kept = 0
  for (const [a, rel, createOnly] of managedFiles()) {
    const content = readFileSync(join(ASSETS, a), "utf8")
    const cur = readRel(rel)
    if (cur === null) { writeRel(rel, content); manifest.files[rel] = sha(content); created++; log.ok(`created ${rel}`); continue }
    if (cur === content) { manifest.files[rel] = sha(content); same++; continue }
    if (createOnly) { kept++; log.info(`kept ${rel} (project-owned config)`); continue }
    const ours = manifest.files[rel] === sha(cur)
    if (ours || FORCE) {
      backup(rel); writeRel(rel, content); manifest.files[rel] = sha(content); updated++
      log.ok(`updated ${rel}${FORCE && !ours ? " (--force over local edits)" : ""}`)
    } else {
      kept++
      writeRel(rel + ".plus-new", content)
      log.warn(`${rel} was edited locally — kept. New version written to ${rel}.plus-new (use --force to overwrite)`)
    }
  }
  pruneObsolete(manifest)
  if (!exists(`${P.plusDir}/.gitignore`)) writeRel(`${P.plusDir}/.gitignore`, "backup/\n*.plus-new\n")
  log.info(`managed files: ${created} created, ${updated} updated, ${same} unchanged, ${kept} kept`)
}

/** Files an older trellis-plus installed that this version no longer ships (v1.1: three reviewers, alignment skill, rubric, alignment template). */
function pruneObsolete(manifest) {
  const current = new Set(managedFiles().map(([, rel]) => rel))
  let removed = 0
  for (const rel of Object.keys(manifest.files)) {
    if (current.has(rel)) continue
    const cur = readRel(rel)
    if (cur === null) { delete manifest.files[rel]; continue }
    if (manifest.files[rel] === sha(cur) || FORCE) {
      backup(rel)
      if (!DRY) { rmSync(abs(rel)); pruneEmptyDirs(dirname(rel)) }
      delete manifest.files[rel]
      removed++
      log.ok(`removed obsolete ${rel}`)
    } else log.warn(`obsolete ${rel} was edited locally — kept (delete it by hand or use --force)`)
  }
  if (removed) log.info(`${removed} obsolete file(s) from an older trellis-plus removed (copies in ${P.backup}/${stamp}/)`)
}
function pruneEmptyDirs(relDir) {
  for (let d = relDir; d && d !== "." && ![".opencode", ".opencode/skills", ".opencode/agents", ".opencode/commands", ".trellis", ".trellis/plus", ".trellis/spec", ".trellis/spec/guides"].includes(d); d = dirname(d)) {
    try { if (readdirSync(abs(d)).length === 0) rmSync(abs(d), { recursive: true }); else break } catch { break }
  }
}

// ───────────── workflow.md patches ─────────────

const BEGIN = (n) => `<!-- trellis-plus:begin:${n} -->`
const END = (n) => `<!-- trellis-plus:end:${n} -->`
const blockRe = (n) => new RegExp(`${BEGIN(n)}[\\s\\S]*?${END(n)}\\n\\n`)

// Per-turn text: each [plus] line is injected on EVERY turn, so keep the lines of one block under ~400 characters in total.
const BREADCRUMBS = {
  planning: [
    "[plus] Tier first (user chooses): `node ./.trellis/plus/gate.mjs tier <TASK_DIR> S|M|L --reason \"…\"`. Overrides trellis-brainstorm: no design.md/implement.md now (1.6 writes them, new session); read code via code-map/grep only. M/L: suggest /grill-me (skip if absent), record D<n> in prd.md (or `无：原因`), `gate.mjs align`. 1.6 draft → `lint-plan`; L: 1.7 review. `gate.mjs status <TASK_DIR>` = next.",
  ],
  in_progress: [
    "[plus] After trellis-check: 2.4 `node ./.trellis/plus/gate.mjs test --task <TASK_DIR> --run`, then 2.5 `gate.mjs ocr --task <TASK_DIR> --run`. List findings + proposed fixes, edit only after the user confirms; triage each (critical/high: fix, or false-positive with `path:line`); rerun only to verify critical/high fixes (max 2; no --force without the user). Commit: the git hook re-checks.",
  ],
}

function locateBefore(lines, headingRe) {
  const h = lines.findIndex((l) => headingRe.test(l))
  if (h < 0) return -1
  for (let i = h - 1; i >= 0 && i >= h - 6; i--) if (lines[i].trim() === "---") return i
  return -1
}

function patchWorkflow() {
  let text = readRel(P.workflow)
  if (text === null) { log.err(`${P.workflow} not found`); return false }
  const orig = text
  const blocks = [
    ["index", "index.md", (lines) => lines.findIndex((l) => l.startsWith("<!-- Per-turn breadcrumb: shown when there is no active task"))],
    ["phase1", "phase1.md", (lines) => locateBefore(lines, /^## Phase 2: Execute\s*$/)],
    ["phase2", "phase2.md", (lines) => locateBefore(lines, /^## Phase 3: Finish\s*$/)],
  ]
  for (const [name, file, locate] of blocks) {
    const body = readFileSync(join(ASSETS, "workflow", file), "utf8").trimEnd()
    const block = `${BEGIN(name)}\n${body}\n${END(name)}\n\n`
    if (blockRe(name).test(text)) { text = text.replace(blockRe(name), () => block); continue }
    const lines = text.split("\n")
    const idx = locate(lines)
    if (idx < 0) { log.err(`workflow.md anchor for block "${name}" not found — upstream structure changed; aborting workflow patch`); return false }
    const offset = lines.slice(0, idx).reduce((n, l) => n + l.length + 1, 0)
    text = text.slice(0, offset) + block + text.slice(offset)
  }
  for (const [status, lines] of Object.entries(BREADCRUMBS)) {
    const re = new RegExp(`(\\[workflow-state:${status}\\]\\n)([\\s\\S]*?)(\\n\\s*\\[/workflow-state:${status}\\])`)
    if (!re.test(text)) { log.err(`[workflow-state:${status}] block not found — cannot add breadcrumb`); return false }
    text = text.replace(re, (_m, open, body, close) => {
      const kept = body.split("\n").filter((l) => !l.startsWith("[plus] ")).join("\n")
      return `${open}${kept}\n${lines.join("\n")}${close}`
    })
  }
  if (text === orig) { log.info("workflow.md already up to date"); return true }
  backup(P.workflow); writeRel(P.workflow, text); log.ok("workflow.md patched (3 blocks + planning / in_progress breadcrumbs)")
  return true
}

function unpatchWorkflow() {
  let text = readRel(P.workflow)
  if (text === null) return
  const orig = text
  for (const n of ["index", "phase1", "phase2"]) text = text.replace(blockRe(n), "")
  text = text.replace(/\n\[plus\] [^\n]*/g, "")
  if (text !== orig) { backup(P.workflow); writeRel(P.workflow, text); log.ok("workflow.md restored") }
}

// ───────────── optional patches ─────────────

const TASKPY_BLOCK = `    # trellis-plus:begin hard-gate
    import os as _plus_os, shutil as _plus_shutil, subprocess as _plus_sp
    _plus_gate = repo_root / ".trellis" / "plus" / "gate.mjs"
    if _plus_gate.is_file() and not _plus_os.environ.get("TRELLIS_PLUS_SKIP_GATE"):
        _plus_node = _plus_shutil.which("node")
        if _plus_node is None:
            print(colored("Warning: trellis-plus pre-start gate skipped (node not found)", Colors.YELLOW))
        elif _plus_sp.run([_plus_node, str(_plus_gate), "pre-start", str(full_path)]).returncode != 0:
            print(colored("Error: trellis-plus pre-start gate failed (tier gates: align / lint-plan / design review).", Colors.RED))
            print("Fix the problems above. Deliberate bypass: TRELLIS_PLUS_SKIP_GATE=1 task.py start ...")
            return 1
    # trellis-plus:end hard-gate

`
const TASKPY_RE = /    # trellis-plus:begin hard-gate[\s\S]*?# trellis-plus:end hard-gate\n\n/
const TASKPY_ANCHOR = "    # Context-manifest gate (#573)"

function patchTaskPy() {
  const text = readRel(P.taskpy)
  if (text === null) { log.err(`${P.taskpy} not found`); return false }
  if (TASKPY_RE.test(text)) { writeIf(P.taskpy, text.replace(TASKPY_RE, () => TASKPY_BLOCK)); return true }
  const i = text.indexOf(TASKPY_ANCHOR)
  if (i < 0) { log.err("task.py anchor `# Context-manifest gate (#573)` not found — upstream changed; hard gate NOT installed"); return false }
  writeIf(P.taskpy, text.slice(0, i) + TASKPY_BLOCK + text.slice(i))
  log.ok("task.py: `start` now runs the pre-start gate (hard gate)")
  return true
}
const unpatchTaskPy = () => { const t = readRel(P.taskpy); if (t && TASKPY_RE.test(t)) { writeIf(P.taskpy, t.replace(TASKPY_RE, "")); log.ok("task.py restored") } }

const CTX_ORIG = "const TRELLIS_SUBAGENT_RE = /^trellis-(implement|check|research)$/"
const CTX_V11 = "const TRELLIS_SUBAGENT_RE = /^(?:trellis-(?:implement|check|research)|plus-(?:design-accuracy|req-coverage|impact-analysis))$/ // trellis-plus"
const CTX_NEW = "const TRELLIS_SUBAGENT_RE = /^(?:trellis-(?:implement|check|research)|plus-design-reviewer)$/ // trellis-plus"

function patchPlugin() {
  const t = readRel(P.ctxjs)
  if (t === null) { log.err(`${P.ctxjs} not found`); return false }
  if (t.includes(CTX_NEW)) return true
  if (t.includes(CTX_V11)) { writeIf(P.ctxjs, t.replace(CTX_V11, CTX_NEW)); log.ok("trellis-context.js: v1.1 reviewer pattern upgraded to plus-design-reviewer"); return true }
  if (!t.includes(CTX_ORIG)) { log.err("trellis-context.js: TRELLIS_SUBAGENT_RE line not found — upstream changed; plugin NOT patched"); return false }
  writeIf(P.ctxjs, t.replace(CTX_ORIG, CTX_NEW))
  log.ok("trellis-context.js: plus reviewers excluded from the per-turn breadcrumb")
  return true
}
const unpatchPlugin = () => { const t = readRel(P.ctxjs); if (t && (t.includes(CTX_NEW) || t.includes(CTX_V11))) { writeIf(P.ctxjs, t.replace(CTX_NEW, CTX_ORIG).replace(CTX_V11, CTX_ORIG)); log.ok("trellis-context.js restored") } }

const CFG_BLOCK = `# trellis-plus:begin context-injection
context_injection:
  max_file_bytes: 32768
  max_artifact_bytes: 131072   # detailed design.md / implement.md need more than the 64 KB default
  max_total_bytes: 262144
# trellis-plus:end context-injection
`
const CFG_RE = /\n# trellis-plus:begin context-injection[\s\S]*?# trellis-plus:end context-injection\n/

function patchConfig() {
  const t = readRel(P.config)
  if (t === null) { log.err(`${P.config} not found`); return false }
  if (CFG_RE.test(t)) { writeIf(P.config, t.replace(CFG_RE, () => "\n" + CFG_BLOCK)); return true }
  if (/^context_injection\s*:/m.test(t)) { log.warn("config.yaml already has an active context_injection section — left untouched"); return false }
  writeIf(P.config, (t.endsWith("\n") ? t : t + "\n") + "\n" + CFG_BLOCK)
  log.ok("config.yaml: context_injection limits raised")
  return true
}
const unpatchConfig = () => { const t = readRel(P.config); if (t && CFG_RE.test(t)) { writeIf(P.config, t.replace(CFG_RE, "")); log.ok("config.yaml restored") } }

function writeIf(rel, content) {
  if (readRel(rel) === content) return
  backup(rel); writeRel(rel, content)
}

// ───────────── agent prompts: mandatory-unit-test block (--patch-agents) ─────────────

const AGENT_FILES = { implement: ".opencode/agents/trellis-implement.md", check: ".opencode/agents/trellis-check.md" }
const AGENT_RE = new RegExp(`\\n${BEGIN("agent")}\\n[\\s\\S]*?\\n${END("agent")}\\n`)
const agentBlock = (kind) => `\n${BEGIN("agent")}\n${readFileSync(join(ASSETS, "patches", `agent-${kind}.md`), "utf8").trimEnd()}\n${END("agent")}\n`

/** Appends a managed block to the END of the agent file (frontmatter untouched), so revert is byte-exact. */
function patchAgents() {
  let good = true
  for (const [kind, rel] of Object.entries(AGENT_FILES)) {
    const t = readRel(rel)
    if (t === null) { log.err(`${rel} not found — agent patch skipped for it`); good = false; continue }
    if (!t.startsWith("---")) { log.err(`${rel} has no frontmatter — refusing to patch (upstream changed?)`); good = false; continue }
    const block = agentBlock(kind)
    if (AGENT_RE.test(t)) {
      const nt = t.replace(AGENT_RE, () => block)
      if (nt !== t) { writeIf(rel, nt); log.ok(`${rel}: plus block updated`) }
      continue
    }
    writeIf(rel, t + block)
    log.ok(`${rel}: plus block added`)
  }
  return good
}
const agentsPatched = () => Object.values(AGENT_FILES).every((rel) => AGENT_RE.test(readRel(rel) ?? ""))
function unpatchAgents() {
  for (const rel of Object.values(AGENT_FILES)) {
    const t = readRel(rel)
    if (t && AGENT_RE.test(t)) { writeIf(rel, t.replace(AGENT_RE, "")); log.ok(`${rel} restored`) }
  }
}

// ───────────── git pre-commit hook (--git-hook) ─────────────

const HOOK_BEGIN = "# >>> trellis-plus >>>"
const HOOK_END = "# <<< trellis-plus <<<"
const HOOK_RE = new RegExp(`${HOOK_BEGIN}[\\s\\S]*?${HOOK_END}\\n`)
const SH_SHEBANG = /^#!\s*(?:\/usr\/bin\/env\s+(?:-S\s+)?|\/(?:usr\/)?(?:local\/)?bin\/)(?:ba|da|z)?sh\b/
const shEsc = (v) => v.replace(/(["$`\\])/g, "\\$1")

function hookBlock(rel) {
  const gate = shEsc((rel ? rel + "/" : "") + ".trellis/plus/gate.mjs")
  return `${HOOK_BEGIN}
# Installed by trellis-plus. One-off bypass: TRELLIS_PLUS_SKIP_GATE=1 git commit …   (or git commit --no-verify)
if [ -z "$TRELLIS_PLUS_SKIP_GATE" ] && command -v node >/dev/null 2>&1 && [ -f "${gate}" ]; then
  node "${gate}" pre-commit --hook || exit 1
fi
${HOOK_END}
`
}

/** hooks dir (worktree / core.hooksPath aware) and the project's path relative to the repository top. null = not a git repo. */
function gitInfo() {
  const g = (...a) => spawnSync("git", ["-C", ROOT, ...a], { encoding: "utf8" })
  const top = g("rev-parse", "--show-toplevel")
  const hp = g("rev-parse", "--git-path", "hooks")
  if (top.error || top.status !== 0 || hp.status !== 0) return null
  const rel = relative(realpathSync(top.stdout.trim()), realpathSync(ROOT)).split(sep).join("/")
  return { hooksDir: resolve(ROOT, hp.stdout.trim()), rel }
}

function backupAbs(file, label) {
  if (DRY || !existsSync(file)) return
  const dst = join(abs(P.backup), stamp, label)
  mkdirSync(dirname(dst), { recursive: true })
  copyFileSync(file, dst)
}

/** Returns true unless something went wrong; "not a git repo" and "foreign hook language" are warnings, not failures. */
function installHook(manifest) {
  const gi = gitInfo()
  if (!gi) { log.warn("not a git repository — git hook skipped"); return true }
  const file = join(gi.hooksDir, "pre-commit")
  const block = hookBlock(gi.rel)
  const cur = existsSync(file) ? readFileSync(file, "utf8") : null
  const write = (content, created) => {
    if (DRY) return
    mkdirSync(gi.hooksDir, { recursive: true })
    writeFileSync(file, content)
    chmodSync(file, 0o755)
    if (created !== undefined) manifest.hookCreated = created
  }
  if (cur === null) { write(`#!/bin/sh\n${block}`, true); log.ok(`git hook created: ${file}`); return true }
  if (HOOK_RE.test(cur)) {
    const nt = cur.replace(HOOK_RE, () => block)
    if (nt !== cur) { backupAbs(file, ".git-hooks/pre-commit"); write(nt); log.ok("git hook updated") }
    return true
  }
  const first = cur.split("\n", 1)[0]
  if (first.startsWith("#!") && !SH_SHEBANG.test(first)) {
    log.warn(`existing pre-commit hook is not a shell script (${first}) — NOT modified. Call it yourself from that hook: node ${gi.rel ? gi.rel + "/" : ""}.trellis/plus/gate.mjs pre-commit --hook`)
    return true
  }
  backupAbs(file, ".git-hooks/pre-commit")
  let nt
  if (first.startsWith("#!")) { const i = cur.indexOf("\n"); nt = i < 0 ? `${cur}\n${block}` : cur.slice(0, i + 1) + block + cur.slice(i + 1) } // right after the shebang: a trailing `exit 0` would hide it
  else nt = block + cur
  write(nt, false)
  log.ok(`git hook: trellis-plus block added to the existing pre-commit hook (${file})`)
  return true
}

function uninstallHook(manifest) {
  const gi = gitInfo()
  if (!gi) return
  const file = join(gi.hooksDir, "pre-commit")
  const cur = existsSync(file) ? readFileSync(file, "utf8") : null
  if (cur === null || !HOOK_RE.test(cur)) return
  backupAbs(file, ".git-hooks/pre-commit")
  const nt = cur.replace(HOOK_RE, "")
  if (manifest.hookCreated && /^(?:#![^\n]*\n)?\s*$/.test(nt)) { if (!DRY) rmSync(file); log.ok("git hook removed (it was created by trellis-plus)") }
  else { if (!DRY) writeFileSync(file, nt); log.ok("git hook block removed") }
}

/** doctor: "ok" | "missing" | "foreign" (an existing non-shell hook we must not touch) | "norepo" */
function hookState() {
  const gi = gitInfo()
  if (!gi) return "norepo"
  const file = join(gi.hooksDir, "pre-commit")
  if (!existsSync(file)) return "missing"
  const cur = readFileSync(file, "utf8")
  if (HOOK_RE.test(cur)) return cur.includes(hookBlock(gi.rel)) && exists(".trellis/plus/gate.mjs") ? "ok" : "missing"
  const first = cur.split("\n", 1)[0]
  return first.startsWith("#!") && !SH_SHEBANG.test(first) ? "foreign" : "missing"
}

// ───────────── commands ─────────────

function preflight() {
  let ok = true
  if (!existsSync(ROOT) || !statSync(ROOT).isDirectory()) { log.err(`project path does not exist or is not a directory: ${ROOT}`); return false }
  if (Number(process.versions.node.split(".")[0]) < 18) { log.err(`Node ${process.versions.node} < 18`); ok = false }
  if (!exists(P.workflow) || !exists(".trellis/scripts/task.py")) { log.err(`${ROOT} is not a Trellis project (run \`trellis init\` first)`); ok = false }
  if (!exists(".opencode")) { log.err(".opencode/ not found — this tool targets the OpenCode platform (`trellis init --opencode`)"); ok = false }
  const ver = (readRel(".trellis/.version") ?? "").trim()
  log.info(`project: ${ROOT}  (trellis ${ver || "?"}, trellis-plus ${TOOL_VERSION})`)
  const ocr = spawnSync("ocr", ["--version"], { encoding: "utf8" })
  if (ocr.error) log.info("`ocr` not found — step 2.5 will use delegation mode (the coding agent reviews the code itself); with ocr installed the gate runs `ocr llm test` first")
  const git = spawnSync("git", ["--version"], { encoding: "utf8" })
  if (git.error) log.warn("git not found")
  return ok
}

/** plus.config.json is project-owned: apply only (re)writes its `version` key, text-level, so every other key and the layout stay as the user left them. */
function stampVersion() {
  const rel = `${P.plusDir}/plus.config.json`
  const cur = readRel(rel)
  if (cur === null) return
  let doc
  try { doc = JSON.parse(cur) } catch { log.warn(`${rel} is not valid JSON — version not stamped`); return }
  if (doc && doc.version === TOOL_VERSION) return
  let next = typeof doc?.version === "string" ? cur.replace(/("version"\s*:\s*)"[^"]*"/, (_, p) => `${p}"${TOOL_VERSION}"`) : cur.replace(/^\{/, `{\n  "version": "${TOOL_VERSION}",`)
  try { if (JSON.parse(next).version !== TOOL_VERSION) throw new Error("x") } catch { next = JSON.stringify({ version: TOOL_VERSION, ...doc }, null, 2) + "\n" }
  writeIf(rel, next)
  log.ok(`${rel}: version ${TOOL_VERSION}${doc?.version ? ` (was ${doc.version})` : ""}`)
}

function cmdApply() {
  console.log(`trellis-plus apply${DRY ? " (dry-run)" : ""}`)
  if (!preflight()) return 2
  const manifest = loadManifest()
  const prev = manifest.options ?? {}
  if (opt("align-skill")) log.warn("--align-skill is gone in v2: clarification uses /grill-me when you have it (optional, skipped if not installed); the option is ignored")
  const opts = {
    hardGate: ALL || flag("hard-gate") || !!prev.hardGate,
    patchPlugin: ALL || flag("patch-plugin") || !!prev.patchPlugin,
    tuneContext: flag("tune-context") || !!prev.tuneContext, // not part of --all: v2 documents (<= 60 KB together) fit the default injection limits
    patchAgents: ALL || flag("patch-agents") || !!prev.patchAgents,
    gitHook: ALL || flag("git-hook") || !!prev.gitHook,
  }
  installFiles(manifest)
  stampVersion()
  let good = patchWorkflow()
  if (opts.hardGate) good = patchTaskPy() && good; else if (exists(P.taskpy)) log.info("hard gate not enabled (add --hard-gate to make `task.py start` enforce the tier gates)")
  if (opts.patchPlugin) good = patchPlugin() && good
  if (opts.tuneContext) good = patchConfig() && good
  if (opts.patchAgents) good = patchAgents() && good; else log.info("agent prompts untouched (add --patch-agents so trellis-implement/trellis-check always get the unit-test rules)")
  if (opts.gitHook) good = installHook(manifest) && good; else log.info("git hook not installed (add --git-hook for the commit-time safety net)")
  manifest.version = TOOL_VERSION
  manifest.options = opts
  if (!DRY) writeRel(P.manifest, JSON.stringify(manifest, null, 2) + "\n")
  console.log(good ? "\nDone. Restart your OpenCode session so it re-reads workflow.md / agents / skills." : "\nFinished with problems (see above).")
  if (good && !DRY) console.log(`Verify:  node ${selfRel()} doctor ${shq(ROOT)}\nGates:   cd ${shq(ROOT)} && node .trellis/plus/gate.mjs --help`)
  return good ? 0 : 1
}

function cmdDoctor() {
  console.log("trellis-plus doctor")
  if (!preflight()) return 2
  const manifest = loadManifest()
  const problems = []
  for (const [a, rel, createOnly] of managedFiles()) {
    const cur = readRel(rel)
    if (cur === null) problems.push(`missing file ${rel}`)
    else if (!createOnly && cur !== readFileSync(join(ASSETS, a), "utf8")) problems.push(`file differs from this tool version: ${rel}`)
  }
  const wf = readRel(P.workflow) ?? ""
  for (const n of ["index", "phase1", "phase2"]) if (!blockRe(n).test(wf)) problems.push(`workflow.md block "${n}" missing (trellis update replaced it?)`)
  for (const s of Object.keys(BREADCRUMBS)) {
    const m = wf.match(new RegExp(`\\[workflow-state:${s}\\]\\n([\\s\\S]*?)\\n\\s*\\[/workflow-state:${s}\\]`))
    if (!m || !m[1].includes("[plus] ")) problems.push(`breadcrumb [workflow-state:${s}] has no [plus] lines`)
  }
  const o = manifest.options ?? {}
  if (o.hardGate && !TASKPY_RE.test(readRel(P.taskpy) ?? "")) problems.push("task.py hard gate missing")
  if (o.patchPlugin && !(readRel(P.ctxjs) ?? "").includes(CTX_NEW)) problems.push("trellis-context.js patch missing")
  if (o.tuneContext && !CFG_RE.test(readRel(P.config) ?? "")) problems.push("config.yaml context_injection block missing")
  if (o.patchAgents && !agentsPatched()) problems.push("trellis-implement / trellis-check plus block missing (trellis update replaced it?)")
  if (o.gitHook) {
    const st = hookState()
    if (st === "missing") problems.push("git pre-commit hook missing or outdated")
    else if (st === "foreign") log.warn("git pre-commit hook is not a shell script: add `node .trellis/plus/gate.mjs pre-commit --hook` to it manually (trellis-plus never edits it)")
  }
  try {
    const cfg = JSON.parse(readRel(`${P.plusDir}/plus.config.json`) ?? "{}")
    if (cfg.version !== TOOL_VERSION) problems.push(`plus.config.json version is ${cfg.version ? `"${cfg.version}"` : "missing"}, this tool is ${TOOL_VERSION} (apply stamps it)`)
    const old = [cfg.alignment && "alignment", cfg.planning?.idMode && "planning.idMode", cfg.planning?.minAnchors !== undefined && "planning.minAnchors", cfg.planning?.minSectionChars && "planning.minSectionChars", cfg.planning?.maxReviewRounds !== undefined && "planning.maxReviewRounds", cfg.ocr?.maxRounds !== undefined && "ocr.maxRounds", cfg.ocr?.minVersion !== undefined && "ocr.minVersion", cfg.ocr?.minGitVersion !== undefined && "ocr.minGitVersion"].filter(Boolean)
    if (old.length) log.warn(`plus.config.json still has v1.x key(s) that v2 ignores: ${old.join(", ")} (see the shipped plus.config.json for the v2 keys)`)
  } catch { log.warn("plus.config.json is not valid JSON") }
  // parser sanity: the python step extractor must still find the new steps
  const py = spawnSync("python3", ["-c", "import sys; sys.path.insert(0, '.trellis/scripts'); from common.workflow_phase import get_step; print(all(get_step(s) for s in ('1.6','1.7','2.4','2.5')))"], { cwd: ROOT, encoding: "utf8" })
  if (py.status === 0 && py.stdout.trim() !== "True") problems.push("get_context --mode phase --step 1.6/1.7/2.4/2.5 cannot find the new steps")
  if (exists(".trellis/plus/gate.mjs")) {
    const g = spawnSync(process.execPath, [abs(".trellis/plus/gate.mjs"), "gates"], { encoding: "utf8" })
    if (g.status === 2) log.warn(`plus.config.json: ${((g.stderr || "").trim().split("\n")[0] || "invalid profile / gates").replace(/^trellis-plus gate: /, "")} — every gate command exits 2 until this is fixed`)
    else if (g.status === 0) { const off = (g.stdout.match(/^  \w+ +(?:warn|off) .*$/gm) || []).map((l) => l.trim().split(/\s+/).slice(0, 2).join("="))
      if (off.length) log.info(`gate switches that are not "error": ${off.join(", ")} (node .trellis/plus/gate.mjs gates)`) }
  }
  const node = spawnSync(process.execPath, [abs(".trellis/plus/gate.mjs")], { encoding: "utf8" })
  if (node.status !== 0 && !exists(".trellis/plus/gate.mjs")) problems.push("gate.mjs not runnable")

  if (problems.length === 0) { log.ok("everything in place"); return 0 }
  problems.forEach((p) => log.err(p))
  if (flag("fix")) { console.log("\n--fix: re-applying"); return cmdApply() }
  console.log(`\nRun: node ${selfRel()} doctor ${shq(ROOT)} --fix   (or apply)`)
  return 1
}

function cmdRevert() {
  console.log("trellis-plus revert")
  const m0 = loadManifest()
  unpatchWorkflow(); unpatchTaskPy(); unpatchPlugin(); unpatchConfig(); unpatchAgents(); uninstallHook(m0)
  if (flag("purge")) {
    const m = loadManifest()
    for (const rel of Object.keys(m.files)) if (!rel.endsWith("plus.config.json") && exists(rel)) { if (!DRY) { rmSync(abs(rel)); pruneEmptyDirs(dirname(rel)) } log.ok(`removed ${rel}`) }
    if (!DRY) rmSync(abs(P.manifest), { force: true })
  } else log.info("new files (agents, skills, gate, templates, guides) kept; add --purge to delete them")
  return 0
}

const shq = (p) => (/\s/.test(p) ? JSON.stringify(p) : p)
const selfRel = () => {
  const self = fileURLToPath(import.meta.url)
  const rel = relative(process.cwd(), self)
  return shq(rel.startsWith("..") ? self : rel || "trellis-plus.mjs")
}

function help() {
  console.log(readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").slice(2, 17).join("\n").replace(/^ \* ?/gm, ""))
  return 0
}

const code = { apply: cmdApply, doctor: cmdDoctor, revert: cmdRevert, help }[command]?.() ?? (console.error(`unknown command: ${command}`), 2)
process.exit(code)
