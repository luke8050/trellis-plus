#### 2.4 Test gate `[required · repeatable]`

Runs after 2.2 passes. Every added/modified Service/Controller (`*Controller.java`, `*Service.java`, `*ServiceImpl.java`) needs a unit test added or updated in the same change, in the same Maven module. Tier S cannot contain such a change; tier M at most 3 classes in one module.

```bash
node ./.trellis/plus/gate.mjs test --task {TASK_DIR} --run
```

Load the `plus-test-gate` skill. On failure dispatch `trellis-implement` to write the missing tests per the 测试矩阵 of `implement.md` and `.trellis/spec/guides/plus-testing-guide.md` (Java 8 + JUnit5 + Mockito), then repeat 2.2 and 2.4. Exemptions only via `implement.md` → 测试豁免 with a reason, and tell the user.

#### 2.5 OCR review `[required · repeatable]`

Runs after 2.4 passes. Load the `plus-ocr-review` skill.

```bash
node ./.trellis/plus/gate.mjs ocr --task {TASK_DIR} --run
```

List the findings to the user with a proposed fix each and edit code only after they confirm (medium/low: no change unless they pick it). Triage every finding into `{TASK_DIR}/reviews/ocr-triage.md`: `fixed`, `false-positive` or `deferred`. **critical / high cannot be deferred**; a false-positive on them must cite code evidence (`path:line`). Fixing, then updating the triage, is enough: no rerun. Rerun (after 2.2 → 2.4) only to verify critical/high fixes, at most 2; `--force` needs `--reason` and the user's approval. Verify with `node ./.trellis/plus/gate.mjs ocr --task {TASK_DIR}`. Show the user any `deferred` item before commit.

At 3.4 the git hook checks tests + OCR triage (no hook: run `gate.mjs pre-commit --task {TASK_DIR}` first).
