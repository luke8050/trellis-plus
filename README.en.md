# trellis-plus

[中文](./README.md) | **English**

**Deterministic gates for Trellis + OpenCode projects: scripts decide whether the work may move on, not the model's own judgement.**

[![npm](https://img.shields.io/npm/v/@luke8050/trellis-plus?color=blue)](https://www.npmjs.com/package/@luke8050/trellis-plus)
[![node](https://img.shields.io/badge/node-%3E%3D18-brightgreen)](https://nodejs.org)
[![license](https://img.shields.io/badge/license-MIT-blue)](#license)
[![tests](https://img.shields.io/badge/regression-819%20assertions-success)](./trellis-plus/test-harness)

**Trellis** (`trellis init`, OpenCode platform) owns the task → plan → implement → check → commit skeleton. trellis-plus adds four things on top of it, at almost no token cost — every check is a Node script running locally, no model call involved.

```bash
# one command: Trellis 0.6.17 (OpenCode) + trellis-plus
npx @luke8050/trellis-plus install <project> -u <your-name>
```

---

## Contents

- [What problem it solves](#what-problem-it-solves)
- [Features](#features)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Workflow tiers](#workflow-tiers)
- [Gate commands](#gate-commands)
- [Configuration](#configuration)
- [Repository layout](#repository-layout)
- [Development and tests](#development-and-tests)
- [Known limitations](#known-limitations)
- [License](#license)

## What problem it solves

When an AI writes plans, unit tests and code reviews, the usual failure is not "it cannot write" but **it writes without checking**: line numbers in `design.md` are invented, `implement.md` still carries `TBD`, a Service changed with no matching test, a review report claims "no blockers" without having read the code. All of that is catchable by mechanical rules — and mechanical rules should be executed by a script, not by another round of inference.

So trellis-plus does exactly two things:

1. **Turn decidable rules into scripts** (`gate.mjs`); the exit code is the verdict: `0` pass / `1` gate failed / `2` usage or environment error.
2. **Scale the process to the task**, so a small change does not pay the cost of a large one.

Target environment: **Java 8 + Maven multi-module + JUnit5 + Mockito**. Zero runtime dependencies.

## Features

| Capability | What it does |
|---|---|
| **Tiered workflow** | The AI reads the code and suggests S / M / L — **you decide**; S needs only `prd.md`, M adds `design.md` + `implement.md`, L adds `code-map.md` and an independent design review |
| **Plan gates** | `align` (requirement alignment), `lint-plan` (anchor validity, placeholders, requirement coverage, test matrix, size caps), `design-review` (every blocker must be answered) |
| **Unit-test gate** | Every changed Service / Controller must have a JUnit5 test in the same module, modified in this change; Maven actually runs once, at step 2.4 |
| **OCR triage** | Runs [alibaba/open-code-review](https://github.com/alibaba/open-code-review); when unavailable it degrades to "delegation mode" (the agent reviews the code itself and writes a report in the same format); critical / high findings cannot be deferred |
| **Commit safety net** | A git `pre-commit` hook re-runs the unit-test and OCR triage checks on staged files |
| **Switchable** | Every gate is `error` / `warn` / `off`, with `strict` / `standard` / `light` presets |

## Quick start

### Prerequisites

- The project has run `trellis init --opencode` (Trellis 0.6.17), is a git repository, and contains `.trellis/` and `.opencode/`
- Node ≥ 18, python3, git
- Optional: `ocr` (open-code-review), Maven, the `/grill-me` clarification skill (skipped when absent — the installer does not check for it)

### Install

**One command (v3+, recommended).** `install` runs: (1) preflight (Node ≥ 18, python3 ≥ 3.9, git) → (2) `trellis init --opencode -u <name> -y` with Trellis **pinned to 0.6.17** (skipped when `.trellis/` and `.opencode/` already exist) → (3) `apply --all` → (4) `doctor`. Idempotent: safe to re-run.

```bash
npx @luke8050/trellis-plus install <project> -u <your-name>
npx @luke8050/trellis-plus install <project> --dry-run     # print the plan only
```

| Option | Effect |
|---|---|
| `-u, --user <name>` | developer name for `trellis init`; defaults to `$TRELLIS_DEVELOPER`, then `git config user.name` |
| `--allow-version` | an existing project whose Trellis is not 0.6.17 is **refused** by default (patch anchors depend on upstream text); this forces an attempt |
| `--trellis-pkg <spec>` | intranet / offline: use a local tgz or private-registry package instead of `@mindfoldhq/trellis@0.6.17` (e.g. `./mindfoldhq-trellis-0.6.17.tgz`, made with `npm pack` on a connected machine) |
| `--git-init` | `git init` first if the directory is not a repo (otherwise the pre-commit hook is skipped, with a notice) |
| `--dry-run` | print the plan only |

A global `trellis` that is exactly 0.6.17 is used as-is; otherwise `npx -y -p @mindfoldhq/trellis@0.6.17 trellis`. The pinned version lives in `package.json` → `config.trellisVersion` (single source).

**Upgrade (`update`, v3+)**: once a project is installed, upgrading trellis-plus later is one command. `npx` caches old versions, so ask for `@latest`:

```bash
npx @luke8050/trellis-plus@latest update <project>
npx @luke8050/trellis-plus@latest update <project> --dry-run   # the plan plus trellis's own change preview
```

`update` runs: (1) preflight → (2) copy the protected files to `.trellis/plus/backup/<time>/protected/` → (3) the pinned `trellis update --force` (plus `--migrate` when the project's Trellis is older) → (4) verify the protected files, restore changed/deleted ones and remove added ones → (5) re-`apply` with your **previous options** (`--all` if none recorded) → (6) `doctor`.

| | What |
|---|---|
| **Kept byte for byte** | `.trellis/spec/`, `.trellis/tasks/`, `.trellis/workspace/`, `.trellis/.developer`, `.trellis/.current-task` (upstream protects these five itself); plus `.trellis/config.yaml` (`trellis update --force` rewrites it — verified against real 0.6.17 — so `update` checks and restores it) |
| **Overwritten** | the other Trellis-managed files (`.trellis/scripts/`, `agents/`, `workflow.md`, the agents / lib under `.opencode/`) and trellis-plus's own files (`.trellis/plus/gate.mjs`, templates, `plus-*` skills / agents). Files you added that Trellis does not manage are left alone |
| **Exception** | trellis-plus guides that live inside `.trellis/spec/` (`plus-testing-guide.md`, …): kept if you edited them, the new version goes to `*.plus-new` |
| **Backups** | `.trellis/plus/backup/<time>/` (files trellis-plus overwrote, and a full copy of the protected files; the 3 newest protected snapshots are kept and older backup directories are cleaned up), `.trellis/.backup-<time>/` (files Trellis overwrote) |

`.trellis/plus/plus.config.json` is kept too, but `apply` updates its `version` key to the current tool version (every other key and the layout are left as they are).

A project whose Trellis is newer than 0.6.17 is refused (`--allow-downgrade` moves it back). When Trellis itself changes version (upgrade, or downgrade with `--allow-downgrade`), its new `config.yaml` is saved as `.trellis/config.yaml.trellis-new` for you to merge. Options as for `install`: `--dry-run`, `--allow-version`, `--trellis-pkg <spec>`.

**Step by step** (project already initialised with `trellis init --opencode`):

```bash
# 1. straight from npm, no global install
npx @luke8050/trellis-plus apply <project> --all

# 2. global install
npm i -g @luke8050/trellis-plus
trellis-plus apply <project> --all

# 3. from source
git clone https://github.com/luke8050/trellis-plus.git
node trellis-plus/trellis-plus/trellis-plus.mjs apply <project> --all
```

`<project>` is the directory containing `.trellis/` and `.opencode/`; the tool itself can live anywhere. See what would change first:

```bash
npx @luke8050/trellis-plus apply <project> --dry-run
```

**Restart the OpenCode session** afterwards so it re-reads workflow / agents / skills.

### What gets installed

- New files: `.trellis/plus/{gate.mjs,plus.config.json,templates/}`, `.trellis/spec/guides/`, `.opencode/agents/plus-design-reviewer.md`, `.opencode/skills/plus-{draft,test-gate,ocr-review}/`, `.opencode/commands/plus-grill-design.md`
- Patched: `workflow.md` (block-level insertion), `task.py` (gate before `start`), `trellis-context.js`, `trellis-implement.md` / `trellis-check.md`, `.git/hooks/pre-commit`
- Commit the new files under `.trellis/plus/` and `.opencode/` — teammates do not need the tool, they just run `node .trellis/plus/gate.mjs …`

## Commands

| Command | What it does |
|---|---|
| `install [<project>] [-u <name>] [--dry-run] [--allow-version] [--trellis-pkg <spec>] [--git-init]` | **One command**: pinned Trellis 0.6.17 `init --opencode` + `apply --all` + `doctor` (see Install above) |
| `update [<project>] [--dry-run] [--allow-version] [--allow-downgrade] [--trellis-pkg <spec>]` | **Upgrade an installed project**: pinned `trellis update --force` + `apply` with your previous options + `doctor`; `spec/ tasks/ workspace/ .developer config.yaml` are kept byte for byte (see Upgrade above) |
| `apply <project> [--dry-run] [--all] [--force]` | Install / upgrade. Idempotent; on upgrade it removes files an older version installed that the current one no longer ships (locally edited files are kept with a warning) |
| `doctor <project> [--fix]` | Health check: files present, patches still intact after `trellis update`, config valid. **Run it after every `trellis update`** |
| `revert <project> [--purge]` | Revert every patch; `--purge` also deletes the files the tool installed |

`--all` = `--hard-gate --patch-plugin --patch-agents --git-hook --coding-rules` (this rewrites `.git/hooks/pre-commit` and two agent files, and appends a `trellis-plus:begin:rules` block of 6 coding rules to `AGENTS.md` — against over-defensive code, over-design and drive-by edits; `--no-coding-rules` skips or removes it; `install` writes it by default and `update` adds it).

`plus.config.json` belongs to the project: `apply` never overwrites it, it only stamps the tool version (read from the tool's own `package.json`) into the `version` key, and `doctor` verifies it.

## Workflow tiers

The AI first reads the code and proposes a tier with its reasoning; nothing proceeds until you pick one:

| Tier | Applies to | Planning artifacts | Extra gates |
|---|---|---|---|
| **S** | Docs, comments, config strings, tests only, behaviour-preserving renames; Service / Controller changes not suggested | `prd.md` | align · unit-test gate · hook |
| **M** | suggested ≤ 3 Services / Controllers, one Maven module, no schema / external contract / transaction-concurrency changes; **no independent design review (L only)** | + `design.md`, `implement.md` | + lint-plan |
| **L** | Everything else | + `research/code-map.md`, independent design review | all of them |

The spine of an L-tier task (the numbers are Trellis step ids, not an execution order):

```
1.0 create the task + pick the tier (AI suggests → you choose → gate tier)
1.2 [L] explore, write code-map (reused by clarification and drafting, no re-reading the code)
1.1 clarify: type /grill-me if you have it (optional), record conclusions in prd.md → gate align
1.6 [new session] draft design + implement → gate lint-plan
1.7 [L, new session] design review (≤ 2 rounds): list problems and proposed fixes first, change nothing until you confirm → gate design-review
1.3 configure context → 1.4 task.py start (re-runs all plan gates for the tier)
2.1 implement → 2.2 check → 2.4 unit-test gate (the only real Maven run) → 2.5 OCR triage
3.3 update the spec → 3.4 commit (the git hook checks once more)
```

Phases hand over through files, so start a new session per phase. `gate status <task>` prints the next step at any time.

## Gate commands

`gate.mjs` is committed with the repository, so teammates never install the tool:

```bash
node .trellis/plus/gate.mjs <command> [task]
```

| Command | What it does |
|---|---|
| `tier <task> [S\|M\|L] [--reason]` | Show / set the tier; S and M require a reason; **the human's choice is final**: a working tree beyond the suggested size only produces a warning, and the suggested tier is recorded in `meta.plus_tier_suggested` / `plus_tier_override` |
| `seed <task>` | Generate the document templates for the tier (replaces the `TBD` skeleton Trellis ships) |
| `align <task>` | `prd.md`: alignment status, no open questions, non-empty decision log, requirement ids `R<n>` |
| `anchors <task>` | Verify that every `file:line#symbol` anchor in `design.md` / `implement.md` / `code-map.md` really exists |
| `lint-plan <task>` | Size caps, placeholders, anchors, required sections, requirement coverage matrix, impact analysis (≥ 5 references must be flagged high-risk), test matrix |
| `design-review <task>` | L tier: the `阻塞：N` header must match the table, and every blocker needs an accept / reject entry in the resolution file (a reject needs evidence) |
| `test [--run] [--base] [--staged]` | Unit-test gate; `--run` executes Maven per module |
| `ocr [--run] [--inspect] [--force --reason]` | OCR and triage; staleness is measured against the newer of the report and its triage |
| `pre-commit [--hook]` | test + ocr; `--hook` only looks at staged files |
| `gates` / `matrix` / `usage` / `status` | Current switches, coverage matrix, token usage per phase, next step (all zero-token) |

**Progress record and viewer**: every gate writes its pass/fail into `task.json` `meta.plus_flow` (tier, all steps, done/todo per step, current step). View it with `node trellis-plus.mjs status [<project>] [--all] [--json]` — by default the `in_progress` tasks and the session task, with a progress bar and ✔ ▶ ○ per step; `--all` lists every task; `--json` is for scripts.

Task selection order: `--task` > `TRELLIS_PLUS_TASK` > session task > the only in-progress task; when several qualify and nothing disambiguates, it does not guess — the CLI errors out and the hook downgrades to a warning. Global bypass: `TRELLIS_PLUS_SKIP_GATE=1`.

## Configuration

`.trellis/plus/plus.config.json` belongs to the project; write only the keys you want to override:

| Key | Meaning |
|---|---|
| `profile` | `strict` / `standard` (default) / `light` |
| `gates.<name>` | Per-gate override: `error` blocks / `warn` warns / `off` disables; an invalid value makes every gate command exit 2 instead of silently passing |
| `limits` | Document size caps (prd 10 KB, design 12 KB for M / 30 KB for L, implement 20 KB, 60 KB combined) |
| `tiers.maxClassesM` | How many Services / Controllers an M-tier change may touch |
| `testGate.*` | `methodLevel` (`warn` / `error` / `off`), `runCommand` / `runCommandRoot`, include and exclude globs |
| `ocr.*` | `mode` (`auto` / `cli` / `delegate`), `maxRerun`, `blockingSeverities` |
| `hook.runTests` | Whether the hook really runs Maven (by default it is static checks only) |

Under `standard`, `designReview` and `hook` warn (the git hook only prints, it does not stop the commit) and `manifests` is off; everything else blocks. To make the hook block use `"gates": {"hook": "error"}` or `profile: strict`. `node .trellis/plus/gate.mjs gates` prints the effective values.

## Repository layout

| Path | Contents |
|---|---|
| `trellis-plus/` | The npm package itself: `trellis-plus.mjs` (installer), `assets/` (gate.mjs, templates, skills, agents, workflow blocks), `test-harness/` (regression suite) |
| `docs/` | Design notes, usage guide and handoff records (Chinese) |

## Development and tests

```bash
cd trellis-plus
TRELLIS_DEVELOPER=<any-name> BASE=../trellis-opencode bash test-harness/run-regression.sh
```

- bash is required; the exit code equals the number of failed assertions.
- The suite uses a fake `ocr`, a fake `mvn` and fixtures throughout — no network.
- Every gate rule has a positive case, a negative case and a **reverse control**: the rule's logic is temporarily broken and the very same assertion must fail. A rule that survives its own mutation means the test is fake.
- Result (Linux / GNU coreutils): **819 passed / 0 failed / 1 skipped** (the skipped one is the v1.1 → v2 upgrade case, which needs `V11_TOOL`).
- macOS/BSD works too (`sed -i` / `touch -d` were replaced with portable calls): **819 passed / 0 failed / 1 skipped** measured there.

To release a new version, change `version` in `package.json` and nothing else — the installer reads it from there and writes it into each project's `plus.config.json`; there is no second hard-coded version in the repository.

## Known limitations

- **OCR failure semantics are unverified**: report structure and CLI flags were calibrated against real `ocr` output, but failure exit codes and `critical`-level reports have no real sample yet.
- **Real Maven is unverified**: the run commands were only exercised with a fake `mvn` (assembly, grouping, exit codes).
- **CodeGraph, how skills / agents actually trigger inside real OpenCode, and real token usage** have not been validated in the target environment.
- Method-level test checks match method names approximately; Controllers are checked at file level only.

See [docs/HANDOFF.md](./docs/HANDOFF.md) for details (Chinese).

## License

MIT © trellis-plus contributors
