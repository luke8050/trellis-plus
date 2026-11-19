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
| B C | tier（存储、原因、建议级别与 warn、legacy 兼容）、seed |
| D | align 四项检查 |
| E | lint-plan（真实性类 error、风格类 warn、legacy 宽容、体积、M/S 级别） |
| F G | anchors / matrix / status / usage；design-review 头部与阻塞回应 |
| H | `task.py start` 硬门禁按级别 |
| I J | 单测门禁（单模块、方法级、tier 限制、--staged、--base、git 子目录）；Maven 多模块（假 mvn） |
| K | OCR 分诊、重跑预算、背景文件、版本检测（假 ocr） |
| L | git hook 与任务选择 |
| Q | `install`：固定版本 init + apply --all + doctor（假 trellis / npx：干跑、缺名字、全局版本不符走 npx、`--trellis-pkg` 及缺 npx 提示、新项目/已有项目 `--git-init`、init 失败不打补丁、版本不符拒绝与 `--allow-version`、幂等） |
| R | `update`：固定版本 `trellis update --force` + 按上次选项 apply + doctor；受保护文件逐字节保留/还原/删除新增、`plus.config.json` 只更新 version、版本升降级、`config.yaml.trellis-new`、成功/失败/独立 apply 的备份上限（假 trellis） |
| S | 任务流程记录：`task.json` 的 `meta.plus_flow`（S/M/L 步骤表、门禁通过/失败、off 与 warn 不计为通过、换档保留进度） |
| T | AGENTS.md 编码规范（`apply --all` / `--coding-rules` / `--no-coding-rules`、幂等、revert、doctor、update 补默认） |
| U | `trellis-plus status`（默认/`--all`/`--json`、进度条、建议级别、完成态、坏 JSON） |
| V | bugfix 流程：`flow` 命令（清理旧 tier / `tier` 拒绝 bugfix）、`seed`（注入 `bugfix.md` 与原任务 prd/design、自动填关联任务、替换 TBD `prd.md`）、`anchors`、`bug-plan`（含 `待先红验证` 与规模/高风险前置检查）、`bug-verify`（范围锁 `confirm` 阻断至第 8 节确认 / `error` 仅认第 4 节 / `off`、回归测试与修复前实测证据、跨模块/超限与第 7 节升级确认、`--staged`）、并入 `test --run`（含失败阻断 mvn、`gates.test=off` 解耦、忽略旧 tier S）与 hook、OCR 背景与委托模式、agent 补丁/workflow/面包屑文案；每条规则均有反向对照（可单独 `ONLY=V`） |
| M | 随包资产（reviewer agent、workflow 体积回归线、样例、无旧名称残留） |

## 约定

- 每条门禁规则都有 **正例、反例、反向对照**：`reverse` 对已安装的 `gate.mjs` 做精确字符串变异（锚点必须恰好出现 N 次，否则本身算失败），同一检查此时必须失败；随后还原并复验。
- 错误文案断言必须带期望文案，不能只看退出码（v1.1 有两条"通过"其实是因别的原因失败）。
- 随包样例 `assets/spec/plus-doc-samples/{prd,design}.md` 就是 lint-plan 的正例夹具：样例改坏，回归会失败。
- 不连真实 ocr / mvn / trellis / 网络：`fake-trellis/{trellis,npx}`（`FAKE_TRELLIS_BASE`、`FAKE_TRELLIS_LOG`、`FAKE_TRELLIS_VERSION`、`FAKE_TRELLIS_FAIL`、`FAKE_TRELLIS_FAIL_UPDATE`、`FAKE_TRELLIS_TOUCH`、`FAKE_TRELLIS_DELETE`）；`fake-ocr/ocr`（`FAKE_OCR_FINDINGS_FILE`、`FAKE_OCR_VERSION`、`FAKE_OCR_REJECT_BACKGROUND`）、`fake-mvn/mvn`（`FAKE_MVN_LOG`、`FAKE_MVN_FAIL`）。
- `mkjava.sh` 造单模块 Java 场景；`fixtures/ocr/` 是各种形状的 OCR 报告；`fixtures/lint/` 是 implement / code-map 与 Java 源。

## 注意（v2.1）

- `BASE` 可以是相对路径（脚本会先转成绝对路径）。
- 回归基线先复现：用真实 `npx @mindfoldhq/trellis@0.6.17 init --opencode -u regression -y` 生成 BASE，并删掉 BASE 里的 `.git`（带 `.git` 会让 3 条依赖「无 git / git 根在上层」的用例误失败）。
- `fake-ocr/ocr`、`fake-mvn/mvn`、`mkjava.sh` 需要可执行位（经 GitHub 网页上传会丢失，需 `chmod +x` 或用 git 提交模式变更）。
- `reverse_file` 可对安装器或 assets 做同样的“临时破坏后断言必须失败”对照。
