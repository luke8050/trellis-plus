# trellis-plus v2

给已经 `trellis init` 的项目（OpenCode 平台，Trellis 0.6.17）加一层**确定性门禁 + 分级流程**的 Node 脚本。零依赖，Node >= 18，Java 8 + Maven 多模块 + JUnit5 + Mockito 项目为目标环境。

v2 相对 v1.1 做减法：删掉 alignment 门禁、三个 reviewer、REQ/DES/IMP/TEST 的 ID 链和 hash 绑定；保留 hook、agent 补丁、单测门禁、OCR 分诊；新增 **S/M/L 分级**（AI 建议 + 用户选择）、**与用户的澄清记录**、**单个独立设计评审员**、**多模块单测门禁**。

> 文档：`docs/方案介绍.md`（为什么这样做、改了什么、验证到什么程度）· `docs/使用说明.md`（安装、日常流程、配置、排错）。

## 使用

```bash
node trellis-plus.mjs apply  <project> --all      # 硬门禁 + plugin 补丁 + agent 补丁 + git hook
node trellis-plus.mjs apply  <project> --dry-run  # 先看会改什么
node trellis-plus.mjs doctor <project> [--fix]    # 每次 `trellis update` 之后跑一次
node trellis-plus.mjs revert <project> [--purge]
```

`<project>` 是含 `.trellis/` 与 `.opencode/` 的目录，工具本身放哪都行。`apply` 幂等；升级自 v1.1 时会清理 v1.1 装过而 v2 不再提供的文件（本地改过的保留并告警）。需要 `/grill-me`、`grilling` 两个 skill（你自己装，缺失只告警）。

## 新流程

1.0 之后 AI 先根据代码给出 S/M/L 建议与理由，请你选择；选定后再执行 `gate tier <task> S|M|L --reason "<理由；用户选 X>"`（存在 `task.json` 的 `meta.plus_tier`）。

| 级别 | 适用 | 规划产物 | 门禁 |
|---|---|---|---|
| S | 文档、注释、配置文案、纯测试、不改行为的重命名；**不得改 Service/Controller** | prd.md | align · 单测门禁 · hook |
| M | ≤ 3 个 Service/Controller、同一 Maven 模块、不涉及库表/对外契约/事务并发 | prd + design + implement | + lint-plan |
| L | 其余 | + research/code-map.md + 独立设计评审 | 全部 |

```
Phase 1  按下列顺序执行（编号是 Trellis 的步骤 id，不是先后序号）：
         1.0 创建任务 + 定级（AI 建议 → 用户选 → gate tier） → [L] 1.2 勘探(code-map) → 1.1 用户输入 /grill-me 澄清，结论记入 prd.md 决策记录，gate align
         → [新会话] 1.6 起草 design/implement，gate lint-plan → [L，新会话] 1.7 评审(≤2 轮)，gate design-review
         → 1.3 配置上下文 → 1.4 start（硬门禁复查）
Phase 2  2.1 实现 → 2.2 check → 2.4 单测门禁 → 2.5 OCR（critical/high 修复后才重跑，最多 2 次）
Phase 3  gate pre-commit → 提交（git hook 再查一遍已暂存文件）
```

阶段间靠文件交接，建议每个阶段新开会话。`gate status <task>` 随时打印下一步。

## 门禁命令（`.trellis/plus/gate.mjs`，随仓库提交，队友无需安装本工具）

退出码：0 通过 / 1 门禁失败 / 2 用法或环境错误。

| 命令 | 作用 |
|---|---|
| `tier <task> [S\|M\|L] [--reason]` | 查看/设置级别；S 与 M 必须写原因；工作区已改了 Service/Controller 时拒绝 S，超限拒绝 M |
| `seed <task>` | 按级别生成模板（替换 Trellis 自带的 `TBD` prd 骨架） |
| `align <task>` | prd.md：`对齐状态：已对齐`、待确认问题清零、决策记录非空（M/L）、每条需求有 `R<n>` |
| `anchors <task>` | 核对 design/implement/code-map 里的 `文件:行#符号` 锚点 |
| `lint-plan <task>` | 体积上限、占位符、锚点、章节、需求→模块/覆盖矩阵、影响分析（≥5 处引用须标高风险）、测试矩阵（每个被改 Service/Controller 要有 正常/边界/异常） |
| `design-review <task>` | L 级：报告头 `阻塞：N` 与表格一致；每个阻塞在 `design-review-resolution.md` 有 采纳/驳回（驳回要证据） |
| `gates` | 列出每个门禁的开关（profile / `gates.*`）、当前生效值和检查内容（0 token） |
| `matrix` / `usage` / `status` | 覆盖矩阵、按阶段记 token、状态与下一步（均不耗 token） |
| `test [--run] [--base] [--staged]` | 每个被改 Service/Controller 要有同模块、本次改过、含 `@Test` 的单测；Service 方法名近似检查；`--run` 按模块执行 mvn |
| `ocr [--run] [--inspect] [--force]` | 先 `ocr llm test`，可用则跑 alibaba/open-code-review，否则降级为委托模式（agent 自己审并写同格式报告）；按严重级别分诊（同文件同行的多条 finding 需逐条分诊）；报告过期、`summary.comments` 与条数不符即失败；`status: partial` 告警并点名未审文件；不校验 ocr/git 版本 |
| `pre-commit [--hook]` | test + ocr；`--hook` 只看已暂存文件 |

任务选择（hook/OCR）：`--task` > `TRELLIS_PLUS_TASK` > 会话任务 > **唯一**的 in_progress 任务（Trellis 自带的 `00-bootstrap-*` 不计）；多个且无提示时不猜：hook 里 OCR 降为告警，命令行报错。绕过：`TRELLIS_PLUS_SKIP_GATE=1`。

## 硬性门禁与开关

每个会阻断流程的检查都有开关：`"error"`（阻断，默认）· `"warn"`（只告警）· `"off"`（不运行）。`profile` 给一组预设，`gates.<名称>` 覆盖单项；`node .trellis/plus/gate.mjs gates` 打印当前生效值。非法名称或取值时所有 gate 命令退出 2（不会静默放行）。

| 开关 | 何时触发 | 检查什么 | strict | standard | light |
|---|---|---|---|---|---|
| `align` | 1.1 后、`task.py start` | prd：已对齐、待确认清零、决策记录(M/L)、R<n> 编号、占位符、体积 | error | error | error |
| `lintPlan` | 1.6 后、`task.py start` | design/implement 真实性（锚点、章节、R 覆盖、影响分析、测试矩阵）、体积、M 级限制 | error | error | warn |
| `designReview` | 1.7 后、`task.py start`（L） | 评审报告头与表格一致、每个阻塞有回应 | error | warn | off |
| `manifests` | `task.py start` | implement/check.jsonl 有真实 spec 条目 | error | warn | off |
| `test` | 2.4、pre-commit、hook | 每个被改 Service/Controller 有同模块、本次改过的 JUnit5 单测；S/M 级限制 | error | error | error |
| `ocr` | 2.5、pre-commit、hook | OCR 报告存在、未过期、每条 finding 已分诊 | error | error | warn |
| `hook` | `git commit` | 整个 git pre-commit hook | error | error | error |

始终开启、不可关：`task.py start` 前必须已定级；退出码约定；`TRELLIS_PLUS_SKIP_GATE=1` 是唯一的整体绕过。

**减少重复校验**：`task.py start` 是计划类门禁的唯一权威复查；工作流不再要求手工重复 `lint-plan`。单测的**正式运行（`test --run`）只在 2.4 做一次**，implement / check 子 agent 只做静态检查（不跑 Maven），`pre-commit` 也只做静态检查。

## 配置 `.trellis/plus/plus.config.json`（项目所有，apply 不会覆盖）

只写要覆盖的键。关键项：`limits`（prd 10 KB / design M 12 KB、L 30 KB / implement 20 KB / 三者合计 60 KB）、`tiers.maxClassesM`、`testGate.methodLevel`（`warn` | `error` | `off`）、`testGate.runCommand` / `runCommandRoot`、`ocr.mode`（`auto` 先 `ocr llm test`，失败转委托模式 | `cli` 仅 ocr | `delegate` 不调 ocr）、`ocr.maxRerun`、`ocr.blockingSeverities`、`hook.runTests`、`profile`、`gates`。v1.x 的键（`alignment`、`planning.idMode`、`ocr.minVersion` 等）被忽略，`doctor` 会提示。

## 落地的文件

`.trellis/plus/{gate.mjs,plus.config.json,templates/}`、`.trellis/spec/guides/{plus-testing-guide.md,plus-doc-samples/}`、`.opencode/agents/plus-design-reviewer.md`、`.opencode/skills/{plus-draft,plus-test-gate,plus-ocr-review}/`、`.opencode/commands/plus-grill-design.md`；补丁：`workflow.md`（块级）、`task.py`（硬门禁）、`trellis-context.js`、两个 agent 文件、`.git/hooks/pre-commit`。

## 已知限制 / 未验证（详见 docs/FINAL-DEV-PLAN.md §5）

- **ocr 报告结构已按 v1.9.8 的一份真实输出校准**（`comments[]`：path/content/start_line/severity…）；命令行参数已按 `ocr review --help` 校准（真实 ocr **没有 `--output`**，报告走 stdout，由 gate 存成 `ocr-r<N>.json`；`--audience agent`、`--format json`、`-B/--background-file` 均存在）、`ocr llm test` 的成功输出已见过；失败时的退出码与 ocr 在真实运行中的退出码语义仍**未验证**，样例只含 medium/high/low，未见过 critical。
- **真实 Maven 未验证**：运行命令只用假 mvn 验证了拼装、分组与退出码（本次按用户决定不处理单测优化，保持现状）。
- **CodeGraph 未验证**；`/grill-me` 的触发是人手动输入。
- 方法级单测检查按方法名近似，Controller 只按文件检查。

## 开发与交接

回归：`BASE=<trellis init 出来的项目> [V11_TOOL=<v1.1 目录>] bash test-harness/run-regression.sh`，说明见 `test-harness/README.md`。交接记录见上级目录的 `HANDOFF.md` §7。
