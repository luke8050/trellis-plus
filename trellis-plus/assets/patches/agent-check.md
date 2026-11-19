## Plus: extra checks (trellis-plus)

1. Run `node ./.trellis/plus/gate.mjs test --task <TASK_DIR>` (static check; `<TASK_DIR>` = the `Active task:` path in your prompt); any failure is a blocking finding. Do not run `--run` here: step 2.4 of the main session runs the tests once.
2. Compare the diff with `design.md` and `implement.md`: files changed that no 实施步骤 mentions = scope creep; planned steps with no diff = not implemented; behaviour that differs from design.md 详细设计 / 异常与边界 or from a `prd.md` 决策记录 row = defect. If the task has `bugfix.md` (flow bugfix): compare the diff against `bugfix.md` — files outside 允许改动文件 (unless confirmed in 8 范围确认) = scope creep (stop and ask the user); verify the root cause (not only the symptom) is fixed, the 回归测试 method is added/changed with before-fix failure recorded, similar callers/paths are checked, and any linked source `prd.md` semantics remain intact.
3. OCR is out of scope for you: step 2.5 is owned by the main session.
