## Plus: mandatory unit tests (trellis-plus)

Every Service/Controller you add or modify (`*Controller`, `*Service`, `*ServiceImpl`) needs a unit test added or updated in the SAME change.

1. Read `.trellis/spec/guides/plus-testing-guide.md` first (Java 8 + JUnit 5 + Mockito 4.x; MockMvc standalone for controllers).
2. If the task has `implement.md`, implement its steps in order and write the cases of its 测试矩阵 (正常 / 边界 / 异常 per class) together with the code. Decisions in `prd.md` 决策记录 are binding.
3. Never weaken tests, add empty `@Test` methods or `@Disabled` to satisfy a gate.
4. Before reporting done run `node ./.trellis/plus/gate.mjs test --task <TASK_DIR>` (static check, no Maven; `<TASK_DIR>` = the `Active task:` path in your prompt) and fix every failure; run the tests you wrote once with Maven. The formal `--run` happens once, in step 2.4 of the main session.
