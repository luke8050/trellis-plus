---
description: Resolve the "需人工确认" items of the design review with the human (one question at a time), then record the answers in prd.md / design.md
---

Use only after step 1.7 when `reviews/design-review.md` has 3 or more items under 需人工确认 (header line `需人工确认：M`). Task: $ARGUMENTS (default: the current task from `python3 ./.trellis/scripts/task.py current --source`).

1. Read `<task>/reviews/design-review.md` (需人工确认 and 假设清单 parts), `<task>/prd.md` 决策记录 and the matching part of `<task>/design.md`. Answer from the code first (`git grep -n`); ask the human only what the code cannot answer.
2. Ask ONE question at a time. For each: the question, why it matters (cite the review item number), your recommended answer with the reason, then wait.
3. After each answer: add a row `D<n> | question | conclusion | 用户（<date>） | R<n>` to prd.md 决策记录, and change the affected design.md section. Never touch code.
4. When all items are settled: run `node ./.trellis/plus/gate.mjs lint-plan <task>` and `gate.mjs design-review <task>`, then tell the human what changed. Do not start a new review round yourself.
