---
name: plus-ocr-review
description: "Use in Trellis Phase 2 (step 2.5) after tests pass and before commit: runs alibaba/open-code-review (ocr) on the working tree, triages every finding with its severity (fixed / false-positive with code evidence / deferred) in reviews/ocr-triage.md, and reruns only after critical/high fixes."
---

# Plus OCR Review (step 2.5)

OCR uses its own model: it does not count against the opencode token budget. The gate first runs `ocr llm test`; if the LLM is configured and reachable it uses ocr, otherwise it switches to **delegation mode** (you review the code yourself, see below). No version or git checks, nothing to install.

## Run

```bash
node ./.trellis/plus/gate.mjs ocr --task <TASK_DIR> --run
```

Executes `ocr review --audience agent --format json --background-file <TASK_DIR>/reviews/ocr-background.md` (background <= 3000 chars: requirements, decisions, planned files). The real ocr has no `--output` flag: the JSON report arrives on stdout and the gate saves it as `<TASK_DIR>/reviews/ocr-r<N>.json` (it is not echoed into the conversation). Unknown `--background-file` → the gate retries without it. A run in which no selected file was reviewed is an error, not a clean review. Report shape (ocr v1.9.8): `{status, comments:[{path, start_line, end_line, severity, category, content}], manifest}`; `status: partial` = some files were NOT reviewed (the gate names them): review those yourself. `gate ocr --task <TASK_DIR> --inspect` shows what was extracted.

## Triage (mandatory)

Create/overwrite `<TASK_DIR>/reviews/ocr-triage.md`, ONE line per finding:

```markdown
Report: ocr-r<N>.json
Round: <N>

- [fixed] path/File.java:42 — [high] NPE on dto — added null check in create()
- [false-positive] path/File.java:88 — [critical] SQL injection — query is parameterized: src/main/resources/mapper/OrderMapper.xml:31
- [deferred] path/File.java:12 — [low] naming — non-blocking; needs user decision
```

| Finding severity | fixed | false-positive | deferred |
|---|---|---|---|
| critical / high | ok | note cites an existing `path:line` that disproves it | **not allowed** |
| medium / low / unknown | ok | reason >= 10 chars | ok, shown to the user before commit |

Every finding needs a line; nothing may stay `[pending]`. Fix the code where the behaviour lives; never suppress warnings.

## Rerun rule

The first run is always allowed. A rerun is allowed only when the previous report had critical/high findings, after you fixed them (and re-ran 2.2 and 2.4), at most `ocr.maxRerun` (2) times. Medium/low findings are only triaged, never rerun. Verify with `node ./.trellis/plus/gate.mjs ocr --task <TASK_DIR>` (report newer than the last source change, every finding triaged). `--force` overrides the rerun rule: tell the user.

## Delegation mode (no working ocr / LLM)

`gate ocr --run` prints `DELEGATION MODE` when `ocr llm test` fails (or `ocr` is missing, or `ocr.mode` is `delegate`). Then YOU are the reviewer: read the changed source files (`git diff HEAD` plus untracked files) against `prd.md` and `reviews/ocr-background.md`, and write `reviews/ocr-r<N>.json` (the file name is printed) as `{"status":"complete","comments":[{"path":"…","start_line":N,"end_line":N,"severity":"high","category":"bug","content":"what is wrong and the fix"}]}`. Triage, the rerun rule and the staleness check are identical. An empty `comments` list is only legitimate after really reading every changed file. `ocr.mode`: `auto` (default) | `cli` (ocr only, failure = error) | `delegate` (never call ocr).

## Before commit (3.4)

`node ./.trellis/plus/gate.mjs pre-commit --task <TASK_DIR>` (static: tests were already run in 2.4, the OCR triage is checked); the git hook runs the same checks on the staged files.
