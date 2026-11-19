## Plus: mandatory unit tests (trellis-plus)

Every Service/Controller you add or modify (`*Controller`, `*Service`, `*ServiceImpl`) needs a unit test added or updated in the SAME change.

1. Read `.trellis/spec/guides/plus-testing-guide.md` first (Java 8 + JUnit 5 + Mockito 4.x; MockMvc standalone for controllers).
2. If the task has `implement.md`, implement its steps in order and write the cases of its 测试矩阵 (正常 / 边界 / 异常 per class) together with the code. Decisions in `prd.md` 决策记录 are binding. If the task has `bugfix.md` (flow bugfix): follow its 修复方案 with minimal changes, stay within 允许改动文件 (if another file is needed, stop and report so the main session asks the user), write the 回归测试 method first and confirm it fails before fixing (recording the failure in section 5), and preserve original requirements in any linked source `prd.md`.
3. Never weaken tests, add empty `@Test` methods or `@Disabled` to satisfy a gate.
4. Before reporting done run `node ./.trellis/plus/gate.mjs test --task <TASK_DIR>` (static check, no Maven; `<TASK_DIR>` = the `Active task:` path in your prompt) and fix every failure; run the tests you wrote once with Maven. The formal `--run` happens once, in step 2.4 of the main session.
