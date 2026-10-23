# trellis-plus

给已经 `trellis init` 的项目（OpenCode 平台，Trellis 0.6.17）加一层 **确定性门禁 + S/M/L 分级流程** 的 Node 脚本。零依赖，Node >= 18。目标环境：Java 8 + Maven 多模块 + JUnit5 + Mockito。

当前版本：**2.1.0**（安装后写入 `.trellis/plus/plus.config.json` 的 `version`）。

## 它做什么

Trellis 负责“任务—计划—实现—检查—提交”的骨架；trellis-plus 在骨架上补四件事，并尽量不增加 token 开销：

| 能力 | 说明 |
|---|---|
| 分级流程 | AI 读代码后建议 S / M / L，**由你选择**；S 只要 prd，M 加 design + implement，L 再加 code-map 与独立设计评审 |
| 计划门禁 | `align`（需求对齐）、`lint-plan`（design/implement 真实性：锚点、占位符、需求覆盖、测试矩阵）、`design-review`（L 级评审报告每个阻塞项都有回应）。全是脚本检查，0 token |
| 单测门禁 | 每个被改的 Service / Controller 必须有同模块、本次改过的 JUnit5 单测；正式运行 `test --run` 只在 2.4 做一次 |
| OCR 分诊 | 调用 alibaba/open-code-review（不可用时降级为委托模式），按严重级别强制分诊；critical/high 不能搁置 |

另有 git pre-commit hook（提交时兜底）、`trellis-implement` / `trellis-check` agent 补丁（单测规则）、可选 `/plus-grill-design` 命令。

## 前置条件

- 项目已 `trellis init`（含 `.trellis/` 与 `.opencode/`），Node >= 18，python3，git。
- 可选：`ocr`（open-code-review）、Maven、`/grill-me` + `grilling` 技能（澄清助手，**没装就跳过**，安装时不检查）。

## 安装

```bash
node trellis-plus/trellis-plus.mjs apply  <project> --all      # 硬门禁 + plugin 补丁 + agent 补丁 + git hook
node trellis-plus/trellis-plus.mjs apply  <project> --dry-run  # 先看会改什么
node trellis-plus/trellis-plus.mjs doctor <project> [--fix]    # 每次 `trellis update` 之后跑一次
node trellis-plus/trellis-plus.mjs revert <project> [--purge]
```

`apply` 幂等；`plus.config.json` 是项目所有文件，升级时只会改写其中的 `version` 一个键。装完重启 OpenCode 会话，让它重新读取 workflow / agents / skills。

## 日常流程（L 级）

```
1.0 创建任务 + 定级（AI 建议 → 你选择）
1.2 勘探，写 code-map（澄清和起草都复用，不重复读代码）
1.1 澄清：建议输入 /grill-me（没装可跳过）；结论记入 prd.md 决策记录，gate align
1.6 [新会话] 起草 design + implement，gate lint-plan
1.7 [新会话] 设计评审（最多 2 轮）：先列问题与修改方案，你确认后才改
1.3 配置上下文 → 1.4 task.py start（复查各门禁）
2.1 实现 → 2.2 check → 2.4 单测门禁 → 2.5 OCR（先列 finding 与建议，你确认后才改；修完更新分诊即可，无需重跑）
3.3 更新 spec → 3.4 提交（hook 检查单测与 OCR 分诊）
```

详细命令、配置、排错见 [`docs/使用说明.md`](docs/使用说明.md)；设计取舍见 [`docs/方案介绍.md`](docs/方案介绍.md)。

## 门禁开关

每个门禁都有 `error`（阻断）/ `warn` / `off`，用 `profile`（`strict` / `standard` 默认 / `light`）选一组预设，`gates.<名称>` 覆盖单项；`node .trellis/plus/gate.mjs gates` 查看当前生效值。standard 下 `designReview` 为告警、`manifests` 关闭，其余阻断。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `trellis-plus/` | 工具本体：`trellis-plus.mjs`（安装器）、`assets/`（gate.mjs、模板、skills、agents、workflow 块）、`test-harness/`（回归） |
| `trellis-opencode/` | 一个 `trellis init --opencode` 出来的样例项目，**仅作回归的 BASE**，不是交付物 |
| `docs/` | 方案介绍、使用说明、优化进度、HANDOFF（交接记录）、ocr 命令输出样本 |

## 测试

```bash
cd trellis-plus
TRELLIS_DEVELOPER=<任意名字> BASE=../trellis-opencode bash test-harness/run-regression.sh
```

- 必须用 bash；退出码 = 失败断言数。`TRELLIS_DEVELOPER` 不设时脚本默认用 `regression`（BASE 里没有被 gitignore 的 `.trellis/.developer`）。
- 全程使用假 ocr / 假 mvn / 夹具，不联网；每条门禁规则都有正例、反例和“临时破坏逻辑后断言必须失败”的反向对照。
- 最近一次结果（v2.2）：**628 通过 / 0 失败 / 1 跳过**（跳过的是 v1.1 → v2 升级用例，需要 `V11_TOOL`）。

## 尚未验证

真实 ocr 的失败退出码与 critical 级报告、真实 Maven 与父 pom 的 surefire 配置、CodeGraph、真实 OpenCode 里 skills / agents / `/grill-me` 的加载与触发行为、真实 token 用量。这些只能在内网环境验证，详见 `docs/HANDOFF.md`。
