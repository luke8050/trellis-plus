### Plus Enhancements (project-local, installed by trellis-plus)

`GATE` = `node ./.trellis/plus/gate.mjs`. After 1.0 judge the tier from the table (check the code: Service/Controller count, Maven modules, schema / external-contract / transaction change), give reasons, ASK the user to choose S, M or L. Only after their answer run `GATE tier <TASK_DIR> S|M|L --reason "<reasons; user chose X>"`. `GATE status <TASK_DIR>` prints the next step (0 tokens).

| Tier | Use when | Planning files | Gates |
|---|---|---|---|
| S | docs, comments, config wording, test-only, typo, behaviour-neutral rename; NO Service/Controller change | prd.md | align · test gate · hook |
| M | <= 3 Service/Controller classes, one Maven module, no schema / external contract / transaction-concurrency change | prd + design + implement | + lint-plan |
| L | everything else | + research/code-map.md | + independent design review |

```
Phase 1 (M/L), in this order — the numbers are Trellis's step ids, NOT a sequence:
  1.0 create task + tier (AI proposes, user chooses)
  1.2 [L] code map: trellis-research -> research/code-map.md
  1.1 clarify: suggest `/grill-me` to the user (you cannot load it; if absent or declined, skip it and ask the key questions one at a time); record conclusions in prd.md 决策记录 (or one line `无：<原因>`); `GATE align`
  1.6 [new session] plan documents: design.md + implement.md; `GATE lint-plan`
  1.7 [L, new session] design review; `GATE design-review`
  1.3 configure context, then 1.4 `task.py start` (re-checks the tier's gates)
Phase 2: 2.1 implement → 2.2 check → 2.4 Test gate → 2.5 OCR review (rerun only after critical/high fixes, max 2)
Phase 3: 3.3 spec update → 3.4 commit   (the git hook checks tests + OCR triage; without a hook run `GATE pre-commit` first)
```

- Overrides `trellis-brainstorm`: in 1.1 do NOT write design.md / implement.md (1.6 does, new session); write prd.md once, after the clarification; read code only via research/code-map.md or a targeted `git grep`.
- Phases hand over through files; one fresh session per stage; `GATE usage <TASK_DIR> --phase <name> --tokens <n>` records tokens.
- 1.6 `[required · once]` Plan documents (M/L): code-grounded `design.md` / `implement.md`, `GATE lint-plan` passes
- 1.7 `[required · repeatable]` Design review (L): one `plus-design-reviewer`, max 2 rounds, every blocker answered, `GATE design-review` passes
- 2.4 `[required · repeatable]` Test gate: every changed Service/Controller has a changed JUnit5 unit test
- 2.5 `[required · repeatable]` OCR review: alibaba/open-code-review + severity-aware triage
- Do NOT run `task.py start` before the tier's gates pass. Do NOT commit (3.4) before 2.4 and 2.5 pass.
