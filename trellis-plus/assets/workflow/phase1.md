#### 1.6 Plan documents `[required · M/L · once]`

Preconditions: tier M/L set, `GATE align {TASK_DIR}` passes (prd.md: 对齐状态：已对齐, no open question, 决策记录 filled, every requirement numbered R<n>); L: `research/code-map.md` exists and `GATE anchors {TASK_DIR}` passes. Best in a new session: everything it needs is on disk.

1. Load the `plus-draft` skill, run `GATE seed {TASK_DIR}`, fill `design.md` and `implement.md` (it also lists the self-check).
2. `GATE lint-plan {TASK_DIR}` must exit 0. It costs no tokens: fix exactly what it lists (placeholders, anchors that do not exist, a requirement without a module, a Service without normal/boundary/error tests, size limits).
3. M: show the user design.md section 0 and wait for approval, then 1.3. L: continue with 1.7.

#### 1.7 Design review `[required · L · repeatable, max 2 rounds]`

Runs after 1.6 passes, in a fresh session, BEFORE the final planning summary.

[Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi, Oh My Pi, ZCode, Snow, Reasonix, Trae, Grok, Kimi Code]

Dispatch ONE `plus-design-reviewer` (it inherits the session model; a different model is optional). The prompt MUST start with `Active task: <task path from task.py current>` followed by `Round: N`, and say it is already the reviewer and must not dispatch other agents. It writes `{TASK_DIR}/reviews/design-review.md`.

[/Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi, Oh My Pi, ZCode, Snow, Reasonix, Trae, Grok, Kimi Code]

[codex-inline, Kilo, Antigravity, Devin, DeepSeek Harness]

Perform the review yourself by following `.opencode/agents/plus-design-reviewer.md` and write the same report file.

[/codex-inline, Kilo, Antigravity, Devin, DeepSeek Harness]

Then, in the main session:

1. Read the report (header: `阻塞：N`, `需人工确认：M`). Fix every blocker in the documents and answer each in `{TASK_DIR}/reviews/design-review-resolution.md`, one line per blocker number: `- #3 采纳 — <what changed>` or `- #4 驳回 — <evidence: path:line or a prd.md quote>`. Rejecting without evidence fails the gate.
2. Round 2 only if blockers were fixed substantively: copy `design-review.md` to `design-review.r1.md`, dispatch again with `Round: 2` and `Changed sections: <list>` (the reviewer re-checks only those and the old blockers). Never a third round: show the user what is still open.
3. `GATE design-review {TASK_DIR}` must exit 0. A human decides: show the user the remaining 需人工确认 items and how the blockers were handled; if 3 or more need a human, offer `/plus-grill-design`. Never declare the design approved yourself. Editing documents after the review only produces a warning.
4. Do not repeat `GATE lint-plan` by hand: step 1.4 (`task.py start`) re-runs every gate of the tier once.
