---
name: plus-draft
description: "Use ONLY in the drafting session of a Trellis M/L task (step 1.6), after `gate align` passed: fills design.md and implement.md from prd.md and research/code-map.md at a granularity a human reviewer can check in about 20 minutes, self-checks them, and runs `gate lint-plan`. Do not load it in any other session."
---

# Plus Draft (step 1.6, drafting session)

Input is already on disk: `prd.md` (requirements R<n>, decision log), `research/code-map.md` (L tier). Do not re-explore what the code map already states and do not ask the user what the code answers. Read `.trellis/spec/guides/plus-doc-samples/{prd,design}.md` once for the form (fictional content: copy the shape, never the text).

## 1. Seed

`node ./.trellis/plus/gate.mjs seed <TASK_DIR>` (tier must be set) creates design.md / implement.md. Fill every `【填写：…】` slot; `gate lint-plan` fails while one is left.

## 2. design.md — write for the human reviewer

Sections 0–12 as in the template. Conclusion first: section 0 is the one page a reviewer reads before anything else. M tier may omit sections 2 and 9 (keep the heading, write `省略：<原因>`).

- Every table has a 对应R column; every PRD requirement R<n> appears in 模块拆分 and in 覆盖矩阵.
- Code references are `path:line#Symbol` (the gate checks file, line range and symbol).
- 影响分析: one row per symbol you change, `命令 → 命中数`, and a disposition. 5 or more references = write 高风险 and the compatibility / regression handling.
- Section 5 数据库变更: ALL database changes of this requirement in one place (table, change type, DDL essentials, existing-data handling and rollback, 对应R); none = `无变更：原因`.
- Section 6 per module: interface table; 关键逻辑 as a tree-style pseudo-code block (entry → called methods → IF/ELSE branches, `// comments` for transaction boundary / idempotency / state change; no full main flow); a 字段与口径 table with ONLY the fields this change adds or modifies.
- Section 7 异常与边界: every row names the test that proves it.
- Behaviour the PRD never asked for is a question for the user (add it to prd.md 待确认问题 and stop), not a design decision.

## 3. implement.md

implement.md is an execution checklist for the AI, not a review document (nobody reviews it): keep it short. One `### 步骤 n` per class or cohesive method group with only 文件 (backticked path) and 改什么 (signature or one-two lines). No per-step test prose, verification commands or rollback notes; the 测试矩阵 carries the tests. Order so each step compiles on its own. Mark new files with 新增. 测试矩阵: every changed Service/Controller class gets a 正常, a 边界 and a 异常 row, each under an R. See `.trellis/spec/guides/plus-testing-guide.md`.

## 4. Self-check before the gate (what reviewers keep finding)

- Interfaces: inherited fields and validation of shared forms/DTOs; null vs empty collection vs missing field; field–interface applicability.
- Data flow: expansion/mapping chain complete; when filtering happens; intermediate vs report tables consistent; batch size and failure strategy.
- Implementation: reuse of an existing method vs a new one; type consistency across DTO/entity/DB; backward compatibility of every changed DTO/Form user.
- Tests: assertion points written as Given-When-Then; full-compat case (new parameter absent = old behaviour); empty-collection case; manual checks for what unit tests cannot cover.

## 5. Gate and hand-over

1. `node ./.trellis/plus/gate.mjs lint-plan <TASK_DIR>` must exit 0; `gate matrix <TASK_DIR>` prints the R → module → test table for section 11.
2. Size limits (prd 10 KB, design M 12 KB / L 30 KB, implement 20 KB, all three 60 KB): over the limit = split into parent/child tasks.
3. `gate usage <TASK_DIR> --phase draft --tokens <n>` (read the number from the session UI).
4. M tier: done, ask the user to approve the plan. L tier: finish this session; the review (step 1.7) runs in a fresh one.
