---
name: plus-bugfix
description: "Use for a Trellis task that fixes a defect of an already committed / released feature (flow bugfix, no S/M/L tier, no prd.md): fills bugfix.md (symptom, root cause anchors, fix plan, allowed files, regression unit test), runs `gate bug-plan`, then fixes with a new or changed unit test. Do not use it for new requirements."
---

# Plus Bugfix (flow bugfix)

A bug fix is a task of its own kind: no tier, no `prd.md`, no `align`, no design / implement / code-map / design review. One document, `bugfix.md`, plus the gates that stay: unit test, OCR triage, git hook.

## 0. When (and when not)

- New task for a defect of something already committed or released: `node ./.trellis/plus/gate.mjs flow <TASK_DIR> bugfix --from <source task dir name>` (`--from` = the task the defect came from; `seed` injects `bugfix.md` and the source task's prd.md / design.md into the sub-agents).
- The feature task is not committed yet: fix it inside that task, no bugfix task.
- A fix that grows past the limits (more than 3 Service/Controller, or more than one Maven module): if it is a new requirement or refactor, switch to feature flow (`gate flow <TASK_DIR> feature`, then `gate tier <TASK_DIR> L`); if it is genuinely one complex defect, ask the user and record rollback/impact handling + `用户确认：<姓名/日期>` in section `7 高风险处置`.

## 1. Write bugfix.md (before any code change)

`gate seed <TASK_DIR>` creates `bugfix.md` (and registers it in `implement.jsonl` / `check.jsonl`). Read the source task's prd.md / design.md only for the intended behaviour. Fill every `【填写：…】`:

- 1 现象与复现: input, expected, actual. Reproduce it first; do not guess.
- 2 根因: at least one anchor `文件:行#符号` (`OrderService.java:42#create`) on the code that is wrong, and why. Not the symptom.
- 3 修复方案: the part people read. Which class / method changes, to what logic, why that removes the root cause, what stays unchanged. Minimal change, no refactoring, no dependency upgrade, no unrelated interface change.
- 4 允许改动文件: every non-test file the fix changes (existing test files may be left out; a new test class must be listed as 新增). `bug-plan` pre-checks scale/risk on this list; an unlisted changed file makes `gate test` / the hook block until the user confirms.
- 5 回归测试: `类#方法` of the new or changed unit test (for a Service/Controller fix, place it in the matching `*Test.java` so `testGate` also passes). Before `task.py start`, write `待先红验证` in the "修复前" column — do NOT edit code before start; after start, write the test first, run it, watch it fail, and fill the real `命令 → 失败行` before `gate test` (`bug-verify` checks it). See `.trellis/spec/guides/plus-testing-guide.md`.
- 6 影响面: `git grep` the changed symbols; callers with the same defect belong to this fix or to a follow-up task; 5+ references = 高风险 and how callers stay compatible.
- 7 高风险处置: required when `pom.xml` / SQL / migration files are planned or changed (rollback and compatibility), and with `用户确认：<姓名/日期>` when escalating a >3 class or cross-module defect; otherwise 无.

`node ./.trellis/plus/gate.mjs bug-plan <TASK_DIR>` must exit 0 before `task.py start`. It costs no tokens: fix exactly what it lists.

## 2. Fix

Write the regression test from section 5 first, run it to confirm it fails, record `命令 → 失败行` into section 5, then apply the minimal fix. Change only what section 4 lists. If the fix needs a file that is not listed, stop and ask the user (they confirm; record it in 8 范围确认 or add it to 4 — unconfirmed files block `gate test` / hook).

## 3. Self-check before 2.4 (what bug fixes usually break)

- Transaction boundary or isolation changed by the fix?
- New race, or idempotency lost? Cache / lock / async touched?
- Exception swallowed, error code changed, null / empty / boundary input uncovered?
- Only the symptom fixed? Similar code paths with the same defect?
- The original requirement still holds (source prd.md)?

## 4. Gates and hand-over

1. 2.4 `gate test --task <TASK_DIR> --run`: every changed Service/Controller has a changed unit test AND the regression tests of bugfix.md are in the diff (`bug-verify`: scope, regression test, risk signals); the regression test classes are run by Maven.
2. 2.5 `gate ocr --task <TASK_DIR> --run`, triage as usual (the OCR background carries the root cause and the fix plan).
3. Commit: the git hook re-checks. 3.3: if the defect class can come back, add one rule to `.trellis/spec/` (no gate).
