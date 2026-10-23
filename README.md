# trellis-plus

**中文** | [English](./README.en.md)

**给 Trellis + OpenCode 项目加一层确定性门禁：脚本判定"能不能往下走"，而不是靠模型自觉。**

[![npm](https://img.shields.io/npm/v/@luke8050/trellis-plus?color=blue)](https://www.npmjs.com/package/@luke8050/trellis-plus)
[![node](https://img.shields.io/badge/node-%3E%3D18-brightgreen)](https://nodejs.org)
[![license](https://img.shields.io/badge/license-MIT-blue)](#license)
[![tests](https://img.shields.io/badge/regression-628%20assertions-success)](./trellis-plus/test-harness)

**Trellis**（`trellis init`，OpenCode 平台）负责"任务 → 计划 → 实现 → 检查 → 提交"的骨架。trellis-plus 在这个骨架上补四件事，且几乎不增加 token 开销——所有检查都是 Node 脚本在本地跑，不调用模型。

```bash
npx @luke8050/trellis-plus apply <project> --all
```

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [特性](#特性)
- [快速开始](#快速开始)
- [命令](#命令)
- [工作流分级](#工作流分级)
- [门禁命令](#门禁命令)
- [配置](#配置)
- [仓库结构](#仓库结构)
- [开发与测试](#开发与测试)
- [已知限制](#已知限制)
- [License](#license)

## 它解决什么问题

AI 写计划、写单测、做代码评审时，最常见的失败不是"不会写"，而是**写了但不检查**：design.md 里的行号是编的、implement.md 里留着 `TBD`、Service 改了却没有对应单测、评审报告说"无阻塞"却没看过代码。这些都能被机械规则抓出来，而机械规则应该由脚本执行，不该再消耗一次推理。

trellis-plus 因此只做两件事：

1. **把可判定的规则写成脚本**（`gate.mjs`），退出码即结论：`0` 通过 / `1` 门禁失败 / `2` 用法或环境错误。
2. **按任务规模分级**，小改动不要付大改动的流程成本。

目标环境是 **Java 8 + Maven 多模块 + JUnit5 + Mockito**，零运行时依赖。

## 特性

| 能力 | 说明 |
|---|---|
| **分级流程** | AI 读代码后建议 S / M / L，**由你拍板**；S 只要 `prd.md`，M 加 `design.md` + `implement.md`，L 再加 `code-map.md` 与独立设计评审 |
| **计划门禁** | `align`（需求对齐）、`lint-plan`（锚点真实性、占位符、需求覆盖、测试矩阵、体积上限）、`design-review`（每个阻塞项都必须有回应） |
| **单测门禁** | 每个被改的 Service / Controller 必须有同模块、本次改过的 JUnit5 单测；Maven 只在 2.4 正式跑一次 |
| **OCR 分诊** | 调用 [alibaba/open-code-review](https://github.com/alibaba/open-code-review)，不可用时降级为"委托模式"（agent 自己审并写同格式报告）；critical / high 不允许搁置 |
| **提交兜底** | git `pre-commit` hook 对已暂存文件再跑一遍单测与 OCR 分诊 |
| **可关闭** | 每个门禁都有 `error` / `warn` / `off` 三档，配 `strict` / `standard` / `light` 预设 |

## 快速开始

### 前置条件

- 项目已执行 `trellis init --opencode`（Trellis 0.6.17），是 git 仓库，含 `.trellis/` 与 `.opencode/`
- Node ≥ 18、python3、git
- 可选：`ocr`（open-code-review）、Maven、`/grill-me` 澄清技能（没装就跳过，安装时不检查）

### 安装

```bash
# 方式一：直接用 npm 上的版本（无需全局安装）
npx @luke8050/trellis-plus apply <project> --all

# 方式二：全局安装
npm i -g @luke8050/trellis-plus
trellis-plus apply <project> --all

# 方式三：从源码
git clone https://github.com/luke8050/trellis-plus.git
node trellis-plus/trellis-plus/trellis-plus.mjs apply <project> --all
```

`<project>` 是包含 `.trellis/` 与 `.opencode/` 的目录，工具本身放哪都行。先看会改什么：

```bash
npx @luke8050/trellis-plus apply <project> --dry-run
```

装完**重启 OpenCode 会话**，让它重新读取 workflow / agents / skills。

### 装了什么

- 新增：`.trellis/plus/{gate.mjs,plus.config.json,templates/}`、`.trellis/spec/guides/`、`.opencode/agents/plus-design-reviewer.md`、`.opencode/skills/plus-{draft,test-gate,ocr-review}/`、`.opencode/commands/plus-grill-design.md`
- 打补丁：`workflow.md`（块级插入）、`task.py`（`start` 前置门禁）、`trellis-context.js`、`trellis-implement.md` / `trellis-check.md`、`.git/hooks/pre-commit`
- 把 `.trellis/plus/` 与 `.opencode/` 的新增文件提交进仓库，队友不用装工具，直接 `node .trellis/plus/gate.mjs …`

## 命令

| 命令 | 作用 |
|---|---|
| `apply <project> [--dry-run] [--all] [--force]` | 安装 / 升级。幂等；升级时清理旧版本装过而当前版本不再提供的文件（本地改过的保留并告警） |
| `doctor <project> [--fix]` | 体检：文件是否齐全、补丁是否被 `trellis update` 冲掉、配置是否合法。**每次 `trellis update` 之后跑一次** |
| `revert <project> [--purge]` | 还原所有补丁；`--purge` 连随包文件一起删 |

`--all` = `--hard-gate --patch-plugin --patch-agents --git-hook`（会改写 `.git/hooks/pre-commit` 与两个 agent 文件）。

`plus.config.json` 属于项目，`apply` 不会覆盖它，只会把工具版本号（读自工具自己的 `package.json`）写进 `version` 这一个键，`doctor` 会核对。

## 工作流分级

AI 先看代码给出级别建议与理由，你在对话里选定后才继续：

| 级别 | 适用 | 规划产物 | 额外门禁 |
|---|---|---|---|
| **S** | 文档、注释、配置文案、纯测试、不改行为的重命名；**不得动 Service / Controller** | `prd.md` | align · 单测门禁 · hook |
| **M** | ≤ 3 个 Service / Controller、同一 Maven 模块、不涉及库表 / 对外契约 / 事务并发 | + `design.md`、`implement.md` | + lint-plan |
| **L** | 其余 | + `research/code-map.md`、独立设计评审 | 全部 |

一次 L 级任务的主干（编号是 Trellis 的步骤 id，不是执行顺序）：

```
1.0 创建任务 + 定级（AI 建议 → 你选择 → gate tier）
1.2 [L] 勘探，写 code-map（澄清与起草复用，不重复读代码）
1.1 澄清：建议输入 /grill-me（没装可跳过），结论记入 prd.md 决策记录 → gate align
1.6 [新会话] 起草 design + implement → gate lint-plan
1.7 [L，新会话] 设计评审（≤ 2 轮）：先列问题与修改方案，你确认后才改 → gate design-review
1.3 配置上下文 → 1.4 task.py start（复查该级别的全部计划类门禁）
2.1 实现 → 2.2 check → 2.4 单测门禁（唯一一次真跑 Maven）→ 2.5 OCR 分诊
3.3 更新 spec → 3.4 提交（git hook 再查一遍）
```

阶段之间靠文件交接，建议每个阶段新开会话。`gate status <task>` 随时打印下一步。

## 门禁命令

`gate.mjs` 随仓库提交，队友无需安装本工具：

```bash
node .trellis/plus/gate.mjs <command> [task]
```

| 命令 | 作用 |
|---|---|
| `tier <task> [S\|M\|L] [--reason]` | 查看 / 设置级别；S 与 M 必须写原因；工作区已改 Service / Controller 时拒绝 S，超限拒绝 M |
| `seed <task>` | 按级别生成文档模板（替换 Trellis 自带的 `TBD` 骨架） |
| `align <task>` | `prd.md`：对齐状态、待确认问题清零、决策记录非空、需求编号 `R<n>` |
| `anchors <task>` | 核对 `design.md` / `implement.md` / `code-map.md` 里的 `文件:行#符号` 锚点是否真实存在 |
| `lint-plan <task>` | 体积上限、占位符、锚点、章节完整性、需求覆盖矩阵、影响分析（≥ 5 处引用须标高风险）、测试矩阵 |
| `design-review <task>` | L 级：报告头 `阻塞：N` 与表格一致，每个阻塞在 resolution 里都有采纳 / 驳回（驳回须给证据） |
| `test [--run] [--base] [--staged]` | 单测门禁；`--run` 按模块执行 Maven |
| `ocr [--run] [--inspect] [--force --reason]` | OCR 与分诊；报告过期判定以"报告与其分诊中较新者"为基准 |
| `pre-commit [--hook]` | test + ocr；`--hook` 只看已暂存文件 |
| `gates` / `matrix` / `usage` / `status` | 当前开关、覆盖矩阵、按阶段 token 统计、下一步（均 0 token） |

任务选择顺序：`--task` > `TRELLIS_PLUS_TASK` > 会话任务 > 唯一的 in_progress 任务；多个且无提示时不猜——命令行报错，hook 里降为告警。整体绕过：`TRELLIS_PLUS_SKIP_GATE=1`。

## 配置

`.trellis/plus/plus.config.json` 属于项目，只写要覆盖的键：

| 键 | 说明 |
|---|---|
| `profile` | `strict` / `standard`（默认）/ `light` |
| `gates.<name>` | 覆盖单项：`error` 阻断 / `warn` 告警 / `off` 关闭；非法值让所有 gate 命令退出 2，不会静默放行 |
| `limits` | 文档体积上限（prd 10 KB、design M 12 KB / L 30 KB、implement 20 KB、合计 60 KB） |
| `tiers.maxClassesM` | M 级允许改动的 Service / Controller 上限 |
| `testGate.*` | `methodLevel`（`warn` / `error` / `off`）、`runCommand` / `runCommandRoot`、包含与排除路径 |
| `ocr.*` | `mode`（`auto` / `cli` / `delegate`）、`maxRerun`、`blockingSeverities` |
| `hook.runTests` | hook 里是否真跑 Maven（默认只做静态检查） |

standard 档下 `designReview` 为告警、`manifests` 关闭，其余阻断。`node .trellis/plus/gate.mjs gates` 查看当前生效值。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `trellis-plus/` | npm 包本体：`trellis-plus.mjs`（安装器）、`assets/`（gate.mjs、模板、skills、agents、workflow 块）、`test-harness/`（回归套件） |
| `trellis-opencode/` | 一个 `trellis init --opencode` 出来的样例项目，**仅作回归的 BASE**，不是交付物 |
| `docs/` | [方案介绍](./docs/方案介绍.md)（为什么这样做、验证到什么程度）、[使用说明](./docs/使用说明.md)（安装、流程、排错）、[HANDOFF](./docs/HANDOFF.md)（交接记录） |

## 开发与测试

```bash
cd trellis-plus
TRELLIS_DEVELOPER=<任意名字> BASE=../trellis-opencode bash test-harness/run-regression.sh
```

- 必须用 bash；退出码 = 失败断言数。
- 全程使用假 `ocr` / 假 `mvn` / 夹具，不联网。
- 每条门禁规则都有正例、反例，以及**反向对照**：临时把规则逻辑改坏，同一条断言必须失败。规则在自身变异下仍然通过，说明测试是假的。
- 结果（Linux / GNU coreutils）：**628 通过 / 0 失败 / 1 跳过**（跳过的是 v1.1 → v2 升级用例，需 `V11_TOOL`）。
- macOS 上实测 626 / 3 / 1：失败项来自 BSD 工具差异（`touch -d 'now + 30 seconds'` 不被支持、mtime 精度不同导致 OCR 过期用例抖动），与门禁逻辑无关。

发布新版本只需改 `package.json` 的 `version` —— 安装器从那里读版本号并写进项目的 `plus.config.json`，仓库里没有第二处硬编码的版本。

## 已知限制

- **OCR 的失败语义未验证**：报告结构与命令行参数已按真实 `ocr` 输出校准，但失败退出码、`critical` 级报告没有真实样本。
- **真实 Maven 未验证**：运行命令只用假 `mvn` 验证了拼装、分组与退出码。
- **CodeGraph、真实 OpenCode 里 skills / agents 的触发行为、真实 token 用量**均未在内网环境验证。
- 方法级单测检查按方法名近似匹配；Controller 只按文件检查。

细节见 [docs/HANDOFF.md](./docs/HANDOFF.md)。

## License

MIT © trellis-plus contributors
