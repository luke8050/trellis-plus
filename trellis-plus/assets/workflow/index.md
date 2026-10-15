### Plus Enhancements (project-local, installed by trellis-plus)

`GATE` = `node ./.trellis/plus/gate.mjs`. Right after 1.0 YOU judge the tier from the table below (check the code: how many Service/Controller classes, how many Maven modules, any schema / external-contract / transaction change), state the reasons, then ASK the user to choose S, M or L in the conversation (mark your recommendation; use the platform's question tool if it has one). Only after their answer run `GATE tier <TASK_DIR> S|M|L --reason "<reasons; user chose X>"`. Never choose for them. `GATE status <TASK_DIR>` prints the next step (0 tokens).

| Tier | Use when | Planning files | Gates |
|---|---|---|---|
| S | docs, comments, config wording, test-only, typo, behaviour-neutral rename; NO Service/Controller change | prd.md | align · test gate · hook |
| M | <= 3 Service/Controller classes, one Maven module, no schema / external contract / transaction-concurrency change | prd + design + implement | + lint-plan |
| L | everything else | + research/code-map.md | + independent design review |

```
Phase 1 (M/L), in this order — the numbers are Trellis's step ids, NOT a sequence:
  1.0 create task + tier (AI proposes, user chooses)
  1.2 [L] code map: trellis-research -> research/code-map.md
  1.1 clarify: tell the user to type `/grill-me` (you cannot load it); record conclusions in prd.md 决策记录; `GATE align`
  1.6 [new session] plan documents: design.md + implement.md; `GATE lint-plan`
  1.7 [L, new session] design review; `GATE design-review`
  1.3 configure context, then 1.4 `task.py start` (re-checks the tier's gates)
Phase 2: 2.1 implement → 2.2 check → 2.4 Test gate → 2.5 OCR review (rerun only after critical/high fixes, max 2)
Phase 3: 3.3 spec update → `GATE pre-commit` → 3.4 commit   (the git pre-commit hook re-checks tests + OCR triage)
```

- Phases hand over through files (prd.md, research/code-map.md, design.md, implement.md, reviews/). Start a fresh session per stage so each one loads only what it needs; record the tokens: `GATE usage <TASK_DIR> --phase <name> --tokens <n>`.
- 1.6 `[required · once]` Plan documents (M/L): code-grounded `design.md` / `implement.md`, `GATE lint-plan` passes
- 1.7 `[required · repeatable]` Design review (L): one `plus-design-reviewer`, max 2 rounds, every blocker answered, `GATE design-review` passes
- 2.4 `[required · repeatable]` Test gate: every changed Service/Controller has a changed JUnit5 unit test
- 2.5 `[required · repeatable]` OCR review: alibaba/open-code-review + severity-aware triage
- Do NOT run `task.py start` before the tier's gates pass. Do NOT commit (3.4) before `GATE pre-commit` passes.
