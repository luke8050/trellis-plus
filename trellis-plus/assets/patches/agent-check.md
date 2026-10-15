## Plus: extra checks (trellis-plus)

1. Run `node ./.trellis/plus/gate.mjs test --task <TASK_DIR>` (static check; `<TASK_DIR>` = the `Active task:` path in your prompt); any failure is a blocking finding. Do not run `--run` here: step 2.4 of the main session runs the tests once.
2. Compare the diff with `design.md` and `implement.md`: files changed that no 实施步骤 mentions = scope creep; planned steps with no diff = not implemented; behaviour that differs from design.md 详细设计 / 异常与边界 or from a `prd.md` 决策记录 row = defect.
3. OCR is out of scope for you: step 2.5 is owned by the main session.
