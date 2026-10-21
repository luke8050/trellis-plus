# test-harness

```bash
BASE=/path/to/a/trellis-initialized/project  bash test-harness/run-regression.sh
# 可选: V11_TOOL=<v1.1 的 trellis-plus 目录>  启用 v1.1 → v2 升级用例
# 可选: ONLY=D,E                              只跑指定分组
```

退出码 = 失败的断言数。必须用 bash。BASE 用 `trellis init --opencode` 生成（Trellis 0.6.17）；脚本会复制它，不会改它。

| 组 | 内容 |
|---|---|
| A | 安装 / 幂等 / doctor / 步骤解析 / 面包屑体积 / plugin / v1.1 升级 / revert 字节级还原 |
| B C | tier（存储、原因、拒绝、legacy 兼容）、seed |
| D | align 四项检查 |
| E | lint-plan（真实性类 error、风格类 warn、legacy 宽容、体积、M/S 级别） |
| F G | anchors / matrix / status / usage；design-review 头部与阻塞回应 |
| H | `task.py start` 硬门禁按级别 |
| I J | 单测门禁（单模块、方法级、tier 限制、--staged、--base、git 子目录）；Maven 多模块（假 mvn） |
| K | OCR 分诊、重跑预算、背景文件、版本检测（假 ocr） |
| L | git hook 与任务选择 |
| M | 随包资产（reviewer agent、workflow 体积回归线、样例、无旧名称残留） |

## 约定

- 每条门禁规则都有 **正例、反例、反向对照**：`reverse` 对已安装的 `gate.mjs` 做精确字符串变异（锚点必须恰好出现 N 次，否则本身算失败），同一检查此时必须失败；随后还原并复验。
- 错误文案断言必须带期望文案，不能只看退出码（v1.1 有两条"通过"其实是因别的原因失败）。
- 随包样例 `assets/spec/plus-doc-samples/{prd,design}.md` 就是 lint-plan 的正例夹具：样例改坏，回归会失败。
- 不连真实 ocr / mvn / 网络：`fake-ocr/ocr`（`FAKE_OCR_FINDINGS_FILE`、`FAKE_OCR_VERSION`、`FAKE_OCR_REJECT_BACKGROUND`）、`fake-mvn/mvn`（`FAKE_MVN_LOG`、`FAKE_MVN_FAIL`）。
- `mkjava.sh` 造单模块 Java 场景；`fixtures/ocr/` 是各种形状的 OCR 报告；`fixtures/lint/` 是 implement / code-map 与 Java 源。

## 注意（v2.1）

- 直接用 `BASE=<GitHub 上的 trellis-opencode>` 运行时，BASE 里没有被 gitignore 的 `.trellis/.developer`；脚本默认导出 `TRELLIS_DEVELOPER=regression`，也可自行设置。
- `fake-ocr/ocr`、`fake-mvn/mvn`、`mkjava.sh` 需要可执行位（经 GitHub 网页上传会丢失，需 `chmod +x` 或用 git 提交模式变更）。
- `reverse_file` 可对安装器或 assets 做同样的“临时破坏后断言必须失败”对照。
