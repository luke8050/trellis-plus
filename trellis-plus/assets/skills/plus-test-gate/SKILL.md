---
name: plus-test-gate
description: "Use in Trellis Phase 2 after trellis-check passes and before commit: verifies every modified Java Service/Controller has a real, changed JUnit5 unit test (Maven multi-module aware), runs those tests per module, and fixes gaps by dispatching trellis-implement. Also explains why tier S/M limits reject a task and what the git pre-commit hook checks."
---

# Plus Test Gate (step 2.4)

```bash
node ./.trellis/plus/gate.mjs test --task <TASK_DIR> --run
```

For every changed/added file matching `testGate.include` (default `*Controller.java`, `*Service.java`, `*ServiceImpl.java` under `src/main/java`):

- a test class exists at the mapped path **in the same Maven module** (`<module>/src/main/java/a/B.java` → `<module>/src/test/java/a/BTest.java` or `BTests.java`; `FooServiceImpl` also accepts `FooServiceTest`). The module is the nearest `pom.xml` directory above the file;
- that test file was added or modified in the same change, and contains `@Test` / `@ParameterizedTest`;
- Services: every changed non-private method name is referenced by the test class (approximation by name, `testGate.methodLevel`: warn by default). Controllers are checked by file only;
- `--run` executes the tests per module: `mvn -q -pl <module> -am test -Dtest=<classes> -Dsurefire.failIfNoSpecifiedTests=false` (root module: no `-pl`).

Pure interfaces are skipped. Exemptions only via `implement.md` → 测试豁免 (`path.java: reason`); they are printed for human sign-off.

## Tier limits

- **S**: a task marked S that changes a Service/Controller fails here. Raise it: `gate tier <task> M|L`, `gate seed`, write design.md / implement.md.
- **M**: at most 3 changed Service/Controller classes in one module; beyond that: `gate tier <task> L`.

## When it fails

1. Do not weaken tests or add empty `@Test` methods.
2. Dispatch `trellis-implement` (prompt starts with `Active task: <path>` and says it is already the implement sub-agent) with the failing paths and the 测试矩阵 of `implement.md`.
3. Re-run `trellis-check` (2.2), then this gate.
4. If a test is genuinely impossible, add a 测试豁免 line with a concrete reason and tell the user.

If the diff is already committed, pass `--base <branch>`.

## Git pre-commit hook

With `trellis-plus apply --git-hook` (part of `--all`) `git commit` runs `gate pre-commit --hook` on the STAGED files: the unit-test rules plus the OCR triage check. The task is chosen by `TRELLIS_PLUS_TASK`, else the only `in_progress` task; with several, the OCR check is skipped with a warning. Commits that stage no source files pass untouched. Bypass: `TRELLIS_PLUS_SKIP_GATE=1 git commit …` or `--no-verify` — tell the user.
