# HANDOFF — trellis-plus v2 编码进度交接

> 生成于 2026-10-12，基于上一会话的全部上下文与**实际读取/执行过**的文件。未读取、未执行、未验证的内容均已标注。
> 旧版 HANDOFF（含 v1.1 时代的任务定义）已被本文件取代；v1.1 的历史文档在 `trellis-plus/docs/archive/`。

## 0. 30 秒摘要

- **做什么**：`trellis-plus` 是给已 `trellis init`（Trellis 0.6.17，OpenCode 平台）的项目加一层确定性门禁 + S/M/L 分级流程的 Node 脚本；目标项目是 **Java 8 + Maven 多模块 + JUnit5 + Mockito**（不用 JaCoCo）。本轮是 v1.1 → **v2 优化编码**。
- **状态**：计划内任务 **T0–T11 全部编码完成**；回归 **421 通过 / 0 失败**（假 ocr、假 mvn、夹具；两次运行逐行一致，约 48 秒；从全新解压副本再跑也是 421/0）。
- **没验证的**：ocr 真实 JSON 输出与退出码、真实 Maven、CodeGraph、`/grill-me` 与评审 agent 在真实 OpenCode 中的表现、真实 token 用量。**这些只能在内网/真实环境验证。**
- **没有 Git**：项目目录不是 git 仓库（`git rev-parse` 报 not a git repository）。工作区 = 沙箱目录 `/home/claude/work/trellis-plus`，**沙箱可能不会在新会话保留**；可靠的源头是交付物 `trellis-plus-v2.zip`（见 §2.7）。
- **不要重复实现任何已完成内容**。剩余工作是验证与校准（§4），不是新功能。

## 1. 项目背景

### 1.1 目标与需求
- 降 token：规划阶段文档与每轮面包屑变小；只有 L 级走完整流程。
- 提质：与用户的澄清记录进 `prd.md`；设计文档可被人在约 20 分钟内评审；一个独立评审员；代码锚点必须真实。
- 保障：每个被改的 Java Service/Controller 必须有同模块、本次改过、含 `@Test` 的单测；OCR（alibaba/open-code-review）严重级别分诊；git pre-commit hook 兜底。
- 方案文档（用户提供，已导出为 md）：《trellis-plus v2 工作流优化方案（降 token · 可评审 · 集成 drill-me）》。**方案是"做减法"**：删 alignment 门禁、三 reviewer、REQ/DES/IMP/TEST ID 链、hash 绑定；保留已验证的 hook、agent 补丁、单测门禁、OCR 分诊。

### 1.2 技术栈与环境
- 代码：Node ≥ 18（零依赖，ESM `.mjs`）；依赖项目里的 `python3 .trellis/scripts/task.py`；bash 脚本做回归。
- 目标项目：Java 8、Maven 多模块、JUnit5、Mockito（具体版本与模块结构：**待确认**）。
- 外部工具：`ocr`（alibaba open-code-review，要求 ≥ 1.9.0，git ≥ 2.41）；用户在内网使用 OpenCode。
- 沙箱（本会话）：node 22、python 3.12、java 21；**无 mvn、无 ocr、无 sudo**；`/bin/sh` 是 dash，**所有脚本必须用 bash**。

### 1.3 用户的硬性要求（来自最初指令，新会话须继续遵守）
1. 先读 HANDOFF 与项目源码，**以最新实际代码和用户明确需求为准**；HANDOFF 与代码不一致先分析差异并告知用户，再动手。
2. 遵循方案决策；认为方案有问题，先说明原因和影响，再提建议，**等用户确认**。
3. **每个新增/修改的门禁规则必须有正例、反例，并做"临时破坏逻辑确认断言会失败"的反向对照**；对修改过的 service/controller 类按项目测试规范补/更新单测（Java 8 + Maven 多模块 + JUnit5 + Mockito，不用 JaCoCo）。
4. 所有 shell 脚本用 bash；多处替换的补丁脚本**先全部断言再统一写出**，写后用特征串计数确认。
5. 如实报告测试与构建结果；无法验证的（内网、ocr 真实输出、CodeGraph）明确标"未验证"。
6. 每完成一个任务更新本文件进度记录，保证可再次交接。
7. 用户明确说过："golden sample 脱敏后与具体需求无关"（已按此做成虚构通用样例）；"我在内网维护的是 Java 项目，要求改 service/controller 要补 Java 单测"（由单测门禁在用户的 Java 项目里强制）。

### 1.4 关键目录与文件（`trellis-plus/`）
| 路径 | 职责 | 行数 |
|---|---|---|
| `trellis-plus.mjs` | 安装器：`apply` / `doctor` / `revert` | 550 |
| `assets/plus/gate.mjs` | 门禁脚本（安装到项目 `.trellis/plus/gate.mjs`，随项目提交） | 1343 |
| `assets/plus/plus.config.json` | 项目所有配置（apply 不覆盖） | 51 |
| `assets/plus/templates/{prd,design,implement,code-map}.md` | `gate seed` 用的模板（占位符 `【填写：…】`） | 32/117/37/31 |
| `assets/spec/plus-doc-samples/{prd,design}.md` | 虚构通用样例（订单防重复提交），**兼作 lint-plan 正例夹具** | 34/128 |
| `assets/spec/plus-testing-guide.md` | Java 8 + JUnit5 + Mockito 测试规范（v1.1 起保留） | 80 |
| `assets/agents/plus-design-reviewer.md` | 唯一评审 agent（用户评审提示词 + 报告头 + 第 2 轮增量） | 90 |
| `assets/skills/{plus-draft,plus-test-gate,plus-ocr-review}/SKILL.md` | 三个 skill | 41/37/48 |
| `assets/commands/plus-grill-design.md` | 可选命令 `/plus-grill-design` | 10 |
| `assets/workflow/{index,phase1,phase2}.md` | 注入 workflow.md 的块（共 6505 字节） | 24/30/21 |
| `assets/patches/agent-{implement,check}.md` | 注入两个原生 agent 的补丁 | 8/5 |
| `test-harness/run-regression.sh` | 回归（A–M 共 13 组） | 1092 |
| `test-harness/{fake-ocr/ocr,fake-mvn/mvn,mkjava.sh,smoke_load.mjs,fixtures/}` | 假 ocr、假 mvn、Java 场景构造、plugin 加载冒烟、夹具 | — |
| `README.md`、`test-harness/README.md`、`docs/FINAL-DEV-PLAN.md` | 文档（FINAL-DEV-PLAN 含实测数字与未验证清单） | 73/30/66 |

沙箱里的其他目录（**非交付物**）：`/home/claude/work/base`（用户上传的 `trellis-opencode.zip` 解压，BASE，未改动）、`snapshot`（会话开始时的 v1.1 `trellis-plus` 原样快照，用作 `V11_TOOL`）、`evidence/`（T0 与最终回归日志）、`build/`（编写 gate 时的临时分段文件，**已过期，勿用**）。

### 1.5 已确认的决策及原因
| 决策 | 原因 |
|---|---|
| tier 由**人**决定，存 `task.json` 的 `meta.plus_tier`（+`plus_tier_reason`） | 与 Trellis 原生 `set-meta` 同位置，实测 start/set-branch/finish 后保留；兼容读 v1.1 `.plus-lightweight`（视为 S） |
| S：只 prd，**不得改 Service/Controller**；M：≤3 个 Service/Controller、同一模块；L：其余 | 方案 §2；规则由 `tier`、`lint-plan`、`test` 三处强制 |
| 步骤只有 **1.6 起草、1.7 评审**，无 1.8；定级与澄清写在 index 块与面包屑 | 1.5 是 Trellis 原生步骤；少一个步骤号少一条面包屑 |
| 澄清用用户手动输入 `/grill-me`（AI 不能加载） | 该 skill 带 `disable-model-invocation`（来自旧会话抓取摘要，**未在 OpenCode 实测**） |
| OCR：首次不计，仅 critical/high 修复后可重跑，**最多重跑 2 次**（`ocr.maxRerun`），`--force` 越过 | 方案里 `maxRounds=1/2` 几处写法不一致，按此解释（**用户未逐字确认**） |
| `design-review.md` 覆盖写；第 2 轮前主会话把旧版另存为 `design-review.r1.md` | 保持 reviewer 的输出路径固定 |
| 报告头 `阻塞：N` 必须与表格里"阻塞"行数一致 | 方案之外新增的机械核对，防头部被写错 |
| `--tune-context` 不再属于 `--all` | v2 文档合计 ≤ 60 KB，落在默认注入上限（32768/65536/131072 字节）内 |
| 只做一级追溯：PRD 的 `R<n>` → design 模块拆分/覆盖矩阵 → implement 测试矩阵 | 方案"砍 ID 链" |

### 1.6 与方案/旧交接文字不一致之处（已按 §1.5 处理）
- 方案 §9 写"`apply --drill-me <path>` 复制 skill、≤40 行兜底协议"，但 §4/§11 明确不复制不兜底 → **按后者**（只检测 `grill-me`/`grilling` 是否存在，缺失告警）。
- 旧 HANDOFF 说 golden sample 是独立文件；实际在 `design-review-grilling.md` 内且未脱敏 → 已改做虚构通用样例。

## 2. 开发进度

### 2.1 状态总表
| 编号 | 内容 | 状态 |
|---|---|---|
| T0 | 复跑基线（BASE=用户 zip）：45 通过 / 9 失败（9 条全是夹具过时；另有 2 条"假通过"） | **已完成且已验证** |
| T1 | 模板 + 样例 | 已完成且已验证（C 组、E 组、M 组断言） |
| T2 | 评审 agent | 已完成且已验证**文件内容与安装**；**真实评审效果未验证** |
| T3 | workflow 块 / 面包屑 / skills | 已完成且已验证（A、M 组）；**真实 OpenCode 里的行为未验证** |
| T4 | gate：tier/seed/align/anchors/lint-plan/design-review/matrix/status/usage/pre-start | 已完成且已验证（B–H 组） |
| T5 | 多模块 + 方法级单测门禁 | 已完成且已验证（I、J 组，假 mvn）；**真实 Maven 未验证** |
| T6 | hook 任务回退 | 已完成且已验证（L 组） |
| T7 | OCR 调整 | 已完成且已验证（K 组，假 ocr）；**真实 ocr 输出/退出码/`--background-file` 未验证** |
| T8 | 安装器 | 已完成且已验证（A 组，含 v1.1→v2 升级、doctor、幂等、revert 字节还原） |
| T9 | 回归迁移 | 已完成且已验证（421/0） |
| T10 | 文档 | 已完成 |
| T11 | `/plus-grill-design` | 已完成且已验证**安装/卸载**；真实 OpenCode 里未试 |
| 正在实施 | 无 | — |

### 2.2 相对 v1.1 快照的文件变更与目的
- **新增**：`templates/{prd,code-map}.md`（v2 结构）、`assets/spec/plus-doc-samples/`、`assets/agents/plus-design-reviewer.md`、`assets/skills/plus-draft/`、`assets/commands/plus-grill-design.md`、`test-harness/fake-mvn/mvn`、`fixtures/lint/code-map.md`、`docs/archive/`。
- **重写**：`assets/plus/gate.mjs`（1108→1343 行）、`trellis-plus.mjs`（517→550）、`templates/{design,implement}.md`、`assets/workflow/*.md`（9511→6505 字节）、`plus.config.json`、两个 agent 补丁、`plus-test-gate`/`plus-ocr-review` skill、`run-regression.sh`、三份 README/FINAL-DEV-PLAN、`fixtures/lint/implement.md`。
- **删除**：三个旧 reviewer（`plus-design-accuracy/req-coverage/impact-analysis.md`）、`plus-align`、`plus-planning-depth`、`plus-design-review-rubric.md`、`templates/alignment.md`、`fixtures/lint/{alignment,prd,design}.md`、`docs/wip/`；旧文档移入 `docs/archive/`。
- 小改：`mkjava.sh` 的提交加了 `--no-verify`。

### 2.3 已执行的测试与验证（实际结果）
| 命令 | 结果 |
|---|---|
| `BASE=<unzipped trellis-opencode> bash test-harness/run-regression.sh`（v1.1 源码，T0） | 45 通过 / 9 失败，连跑两次一致；对照实验证实 9 条原因（夹具缺 alignment、hook 拦夹具提交、会话回退语义变化） |
| `BASE=… V11_TOOL=<v1.1 快照> bash test-harness/run-regression.sh`（v2，最终） | **421 通过 / 0 失败 / 0 跳过**；分组 A30 B29 C20 D27 E60 F25 G29 H22 I45 J21 K55 L35 M23；其中 112 条为反向对照；约 48 秒 |
| 同上，不带 `V11_TOOL` | 仅 1 条 v1.1→v2 升级用例显示 `SKIPPED`，其余照常（不会静默通过） |
| 在全新目录解压 `trellis-plus-v2.zip` 后跑 `help` 与完整回归 | 421/0 |
| `node --check trellis-plus.mjs`、`node --check assets/plus/gate.mjs` | 通过 |
| 实测体积 | planning 面包屑 1634→**819** 字符，in_progress 1397→**1196**（BASE 449/871；[plus] 行 369/324，≤400）；skills+agents+指南随包文本 40446→31870 字节 |

证据日志在 `evidence/`（`t0-run1/2.log`、`t0-diag.log`、`final-regression.log`、sha256 清单）。
未做：任何真实 Maven、真实 ocr、真实 OpenCode、Windows、Java 8 编译（Java 夹具只是被扫描的文本，不编译）。

### 2.4 已发现并解决的问题
1. v1.1 基线有 2 条"假通过"（`inventory file without a step fails`、`untraced PRD id fails`，被别的失败顶掉）→ 所有断言现在同时检查期望文案。
2. `task.py create` 生成带 `TBD` 的 prd 骨架 → `seed` 识别并替换，否则 `align` 永远过不了。
3. Trellis 自带 `00-bootstrap-guidelines` 恒为 `in_progress` → 任务回退候选必须排除 `^00-bootstrap`。
4. 重写 pre-commit 时丢了"hook 下无任务则跳过 OCR"（会拦所有非任务提交）→ 已恢复，L 组覆盖。
5. OCR 背景里任务标题无上限（会截掉末尾评审指令）→ 截 120 字符。
6. 带状态的反向对照会污染自己（重复 `--run` 触发重跑上限）→ 检查函数一律用新任务。
7. `revert --purge` 会留空的 `templates/` 目录 → 加了 `pruneEmptyDirs`。
8. T0 里"no_task 面包屑 4091→6290"是测量误差（正则吞了 Phase Index），真实 no_task 块没变。

### 2.5 尚未解决 / 已知缺陷 / 风险
- **ocr JSON 格式未知**：`extractFindings` 靠"含 文件+行+消息 键的对象"猜（`FINDING_KEYS`），仅对 5 种推测夹具验证。真实报告可能让它漏报（漏报=放行，**高风险**）。
- **真实 Maven 行为未知**：`mvn -q -pl <module> -am test -Dtest=<classes> -Dsurefire.failIfNoSpecifiedTests=false` 是否符合内网父 pom/surefire 配置。
- 方法级检查按方法名近似（默认只告警）；`javaMethods`/`isPureInterface` 是正则近似；Controller 只按文件检查。
- 部分暂存（`git add -p`）时 hook 读工作区内容而非暂存内容（v1.1 已知限制，未改）。
- `gate.mjs` 变大（1108→1343 行），"瘦身"只在文本/面包屑上达成。
- 回归的**反向对照依赖 `gate.mjs` 中的精确字符串**（见 §3.6）：重构 gate 会让这些对照报"锚点找不到"。
- 评审 agent、`/grill-me`、`/plus-grill-design`、skills 在真实 OpenCode 中是否按预期加载/触发：**未验证**。
- S/M/L token 目标（60k/150k/320k）只是上限，未实测。

### 2.6 当前任务与中断前最后操作
没有进行中的任务。最后完成的操作：打包 `trellis-plus-v2.zip`、从解压副本重跑回归得 421/0、交付给用户；随后生成本交接文档（不改代码）。

### 2.7 交付物与 Git
- 交付物：`/mnt/user-data/outputs/trellis-plus-v2.zip`（含 `trellis-plus/`、`HANDOFF.md`、`evidence/`；zip 本身大小会随 HANDOFF 更新而变，**以下方源码文件的 sha256 为准校验**）与 `/mnt/user-data/outputs/HANDOFF.md`。
- Git：**无仓库**；分支/未提交修改均不适用；用户是否把 `trellis-plus/` 放进自己的仓库：**待确认**。
- 完整性校验（前 16 位 sha256）：`gate.mjs` 0f2b8722e97ddd2e、`trellis-plus.mjs` 27c914b9b9062962、`run-regression.sh` d0a62894f3dcef87。

### 2.8 进度记录：N0（2026-10-13，接手会话）
- 上传包实为 `Archive.zip`（含 `trellis-plus-v2/{trellis-plus,evidence}`、`trellis-opencode/`（即 BASE）、`HANDOFF.md`、`用户已确认问题和待优化点.md`）。已解压到 `/home/claude/work/{trellis-plus,evidence,base}`，快照 `snapshot-20261013`。
- sha256 前 16 位：gate.mjs 0f2b8722e97ddd2e、trellis-plus.mjs 27c914b9b9062962、run-regression.sh d0a62894f3dcef87 —— **三者全部与 §2.7 一致**。
- bash 复跑回归（BASE=base，无 V11_TOOL）：**413 通过 / 0 失败 / 1 跳过**，约 63 秒（日志 `evidence/n0-run1.log`）。与 421 的差 8 条＝v1.1→v2 升级用例（需 `V11_TOOL`，包内没有 v1.1 目录；`docs/archive/` 只有文档）。除这 8 条外与 `final-regression.log` 逐行一致。代码未改，`diff -rq` 无差异。
- 环境与 HANDOFF 不同：本会话有 mvn 3.9.11（但 Maven Central/npm 出口被代理拒绝，真实依赖无法下载）、python 3.13、node 22、java 21；无 ocr。
- 用户已在 `用户已确认问题和待优化点.md` 回答 §6 的 1–7 项并提出 5 条待优化点；N1 仍缺"带 finding 的真实 JSON"。

### 2.9 进度记录：用户确认的 5 条优化（2026-10-14，F0–F6）
**来源与差异**：2026-10-13 19:59–20:02（N0 之后、本轮之前）`trellis-plus/` 被不明来源改过 8 个文件（OCR：`ocr llm test`、委托模式、`ocr.mode`、`comments[]` 为唯一来源、partial 警告、stdout 兜底、删版本校验、`fixtures/ocr/real-*.json`）。快照 `snapshot-20261013`（N0 原始）与 `snapshot-20261014-pre-F`（接手本轮时状态）都在 `/home/claude/work`。当时回归 427/4 失败（4 条是已被删逻辑的旧用例）。本轮把它当作"已写完待验证"，补测试，未重写。

**用户决定**：优化 1–4 按我的建议；prd 按功能 `###` 分组；单测/Maven 相关**保持现状（N2 不做）**。

| 编号 | 内容 | 关键改动 | 验证 |
|---|---|---|---|
| F5 OCR | 校准真实 v1.9.8 结构；`ocr llm test` 失败→委托模式；去版本/git 校验 | 新增：`summary.comments` 与提取条数对账（不符=error）；用 3 个 `ocr.mode`（auto/cli/delegate）补正反例；4 条过期用例替换 | K 组 91 条；每条规则有反向对照 |
| F1 prd | 需求按 `### 功能` 分组，每组一张表 | `sectionItems` 改读所有表（之前第二张表头会被当无编号需求）；无分组/空分组仅告警；note 含 `N function group(s)`；背景文件读全部分组 | D 组 38 条 |
| F2 design | 新增 `## 6 数据库变更`；5 节去"数据结构""主流程"，关键逻辑改树形伪代码，字段与口径只写改动字段 | 后续章节顺延：7 异常与边界 / 8 影响分析 / 9 非功能(M 可省，同 2) / 10 依赖 / 11 覆盖矩阵 / 12 开放问题；`DESIGN_ALWAYS` 新增数据库变更（M/L 都必需，"无变更：原因"合法）；样例、reviewer、plus-draft 同步 | E、M 组 |
| F3 implement | 精简：只留 文件 / 改什么 + 测试矩阵(对应R/类/用例/类型) + 测试豁免 | 删 单测/验证命令/回滚点/手工验证清单/提交前验证 与"预期"列；体积上限 20480 **未改**（用户未要求） | M 组（模板≤1500 字节） |
| F4 workflow | Phase 1 流程图按执行顺序一步一行 | 编号不是笔误而是原生 1.1–1.4 与新增 1.6/1.7 顺序不一致；加"ids are NOT a sequence"；1.6/1.7 编号未改 | M 组 |
| F6 开关 | `profile`(strict/standard/light) + `gates.{align,lintPlan,designReview,manifests,test,ocr,hook}`=error/warn/off；`gate gates` 清单；`doctor` 校验 | 非法名/值 exit 2；去重：正式 `test --run` 只在 2.4，两个子 agent 补丁与 pre-commit 只做静态检查；1.7 不再手工重跑 lint-plan | N 组 46 条 + A 组 doctor |

**与我先前口头方案的偏离（请用户知悉）**：我曾说"`pre-start` 不再重跑 lint-plan"。实际**保留**了 pre-start 对计划类门禁的复查（它是 `task.py start` 的唯一权威检查；去掉会放过 lint-plan 之后改过的文档），改为删除工作流里手工重复的 `lint-plan`，并提供开关。需要更激进可设 `profile: light`/`gates.lintPlan: off`。

**回归**：`BASE=base bash test-harness/run-regression.sh` → **547 通过 / 0 失败 / 1 跳过**（跳过=v1.1 升级用例，缺 `V11_TOOL`），日志 `evidence/f-full-4.log`（`f-full-2.log` 的 538 是修正 `--output` 之前的版本）。反向对照共 147 条出现。源码 sha256 前 16 位（最终）：gate.mjs f434c12e5f6efc41、trellis-plus.mjs bd3b56ed60589195、run-regression.sh 674a4aeb04a9d718。

**未验证**：真实 `ocr` 的 `--output`/`--audience`/`--background-file`/退出码、`ocr llm test` 的真实退出码语义（假设 0=可用）、委托模式在真实 OpenCode 里的执行效果、critical 级别的真实报告形状、真实 Maven（按用户决定未处理）、CodeGraph、reviewer 对新 design 结构的真实评审效果、`profile` 预设（standard/light）取值是我的建议，用户未逐项确认。
**注意**：`real-partial.json` 是脱敏/改写后的 6 条合成样例，不是原始输出；原始输出（13 条、含公司路径）未放进交付物。

### 2.10 进度记录：真实 `ocr review --help` / `ocr llm test`（2026-10-14）
- **发现并修复**：真实 ocr **没有 `--output` 参数**（`ocr review --help`），之前版本传 `--output` 会直接失败。现在 `ocr review --audience agent --format json [-B <背景>]`，报告取自 stdout，gate 存成 `reviews/ocr-r<N>.json`，不回显到对话；stdout 没有 JSON=error；非零退出但有 JSON=告警；`jsonFromText` 接受以 `{`/`[` 开头的文档（忽略 `[ocr] …` 日志行）。
- 新增：`manifest.coverage` 中所选文件一个都没审完（`selected>0` 且 `completed=0`）=error，避免空 `comments` 被当作“无问题”。
- `fake-ocr` 改为与真实 ocr 一致：拒绝 `--output`，报告走 stdout（原 `FAKE_OCR_STDOUT_ONLY` 已删，新增 `FAKE_OCR_NO_JSON`、`FAKE_OCR_EXIT`）。
- `ocr llm test` 成功输出已见（`√ Connection test successful`），按退出码 0 判定可用；**失败时的退出码仍未验证**。
- 用户确认：profile 取值不调整。新增交付文档 `trellis-plus/docs/方案介绍.md`、`使用说明.md`，包根目录有 `优化进度.md`。

## 3. 代码实现细节

### 3.1 总体调用链
`trellis-plus.mjs apply <project> --all` → 复制资产到项目（`.trellis/plus/{gate.mjs,plus.config.json,templates/}`、`.trellis/spec/guides/{plus-testing-guide.md,plus-doc-samples/}`、`.opencode/{agents,skills,commands}/…`）→ 打补丁：`workflow.md`（块级替换 + `BREADCRUMBS`）、`task.py`（硬门禁：start 前调 `gate.mjs pre-start`）、`.opencode/lib/trellis-context.js`（让 reviewer 走 pull 式上下文）、两个原生 agent 文件、`.git/hooks/pre-commit`（`gate.mjs pre-commit --hook`，块标记 `# >>> trellis-plus >>>`）。manifest 在 `.trellis/plus/` 下记录文件 sha 以便 `revert`/升级清理。

### 3.2 `trellis-plus.mjs` 关键点
- `managedFiles()` 列出随包文件（含新增的 `assets/commands/`）；`pruneObsolete(manifest)` 清理 v1.1 遗留（sha 未变才删，本地改过的保留并告警）；`pruneEmptyDirs`。
- `patchPlugin`：`CTX_ORIG`（原文）、`CTX_V11`、`CTX_NEW`（`plus-design-reviewer`）三态，升级时 v1.1 → v2 改写；`unpatchPlugin` 两种都能还原。
- `warnSkills()`：仅检测 `grill-me`/`grilling` 是否存在，缺失告警；`--align-skill` 只提示已移除。
- `doctor` 额外检查：`get_context --step 1.6/1.7/2.4/2.5` 可解析；`plus.config.json` 里 v1.x 键（`alignment`、`planning.idMode`、`planning.minAnchors`、`planning.minSectionChars`、`planning.maxReviewRounds`、`ocr.maxRounds`）只告警。
- 选项：`--dry-run --hard-gate --patch-plugin --tune-context --patch-agents --git-hook --all --force`；`--all` 会改写 `.git/hooks/pre-commit` 与两个 agent 文件。
- `trellis update` 可能覆盖这些补丁 → 需 `doctor --fix`（沿用 v1.1 约定）。

### 3.3 `gate.mjs` 主要函数
配置 `DEFAULT_CONFIG`/`loadConfig`；辅助 `Report`、`parseArgs`、`resolveTask`、`inProgressTasks`、`taskFromOpts`、`sectionsOf`、`parseTable`、`stripComments`、`placeholders`；
tier：`taskTier`（含 legacy 判定）、`writeTier`、`cmdTier`、`needTier`、`moduleOf`；
文档类：`verifyAnchors`、`anchorsGate`、`alignGate`、`lintPlan`、`cmdMatrix`、`designReview`、`manifestsCheck`、`preStart`、`cmdSeed`、`cmdUsage`、`cmdStatus`；
单测：`testGate`、`testCandidates`、`javaMethods`、`changedMethodNames`、`runTests`；
OCR：`ocrGate`、`extractFindings`、`parseTriage`、`matchEntry`、`hasCodeEvidence`、`latestOcr`、`hasBlocking`、`buildBackground`；入口 `main()`。

### 3.4 文档格式契约（gate 靠它们解析，改格式=改 gate+模板+样例+回归）
- **prd.md**：`对齐状态：已对齐|未对齐`（独占一行，HTML 注释内不算）；`## …需求…` 表/列表，每项以 `R<n>` 开头且唯一；`## …决策记录…` 表（首列 `D<n>`，列含 结论/来源/影响）；`## …待确认问题…` 为空或"无/None"。
- **design.md**（L 全部、M 可省 2、9；v2.1 起新增 6 数据库变更并顺延，见 §2.9）：`## 0 评审导读`、`1 背景与目标…`、`2 术语…`、`3 整体方案`（表 ≥2 行告警）、`4 模块拆分`（列 模块/职责/对应R/依赖）、`5 详细设计`、`6 异常与边界`（列含"对应测试"）、`7 影响分析`（列 符号/引用数/处置；引用数写 `命令 → 命中数`，≥ `highRiskRefs`(5) 须含"高风险"）、`8 非功能`、`9 依赖…`、`10 覆盖矩阵…`、`11 开放问题`。
- **implement.md**：`## 1 实施步骤`（`### 步骤 n：…`，路径用反引号；新增文件在步骤里写"新增"）、`## 2 测试矩阵`（列 对应R/类/用例/类型，类型只用 正常/边界/异常）、`## 3 测试豁免`（`- path.java: 原因(≥8 字)`，无则写"无"）。
- **code-map.md**：锚点 `文件:行#符号`；找不到写 `NOT-FOUND: … — 搜索：\`命令\``。
- **占位符**：`TBD|TODO|XXX|待补充|待定|<填写…>|【填写…】|{{…}}`；模板说明文字不得含这些词（HTML 注释会被剥离，但仍避免）。
- **design-review.md**：前 15 行含 `轮次：N`、`阻塞：N`、`需人工确认：M`；问题清单表含列"严重程度"（值 阻塞/建议）。**resolution**：`- #<编号> 采纳|驳回 — 说明`；驳回须含存在的 `path:line` 或 `prd.md`/`需求原文`。
- **ocr-triage.md**：首部 `Report: ocr-r<N>.json`；每个 finding 一行 `- [fixed|false-positive|deferred|pending] 文件(:行) — 说明`。
- 调用 ocr：`ocr review --audience agent --format json --output <task>/reviews/ocr-r<N>.json [--background-file <task>/reviews/ocr-background.md] <extraArgs>`。

### 3.5 关键业务规则
- **tier**：S/M 需 `--reason`(≥6 字)；`tier S` 在工作区已改 Service/Controller 时拒绝；`tier M` 超过 3 个类或跨模块拒绝；无 tier：带 v1.1 痕迹（`alignment.md`、`design-r*-(accuracy|coverage|impact).md`、`DES-n`）= legacy L（格式类降为告警，锚点/占位符仍 error），否则报错要求先定级。`gate lightweight` = 过时别名 → `tier S`。
- **pre-start**：S = align+manifests；M = +lint-plan；L = +design-review。`manifests` 要求 implement/check.jsonl 在 `[plus]` 之外还有真实条目。`TRELLIS_PLUS_SKIP_GATE=1` 绕过。
- **lint-plan 的 error（真实性类）**：占位符、锚点（文件/行范围/符号窗口 ±15）、必需章节缺失/为空、PRD 的 R 在模块拆分/覆盖矩阵缺失或引用了不存在的 R、影响分析无处置或高引用数未标高风险、implement 路径不存在且步骤未标新增、被改 Service/Controller 在测试矩阵缺类或缺 正常/边界/异常、体积（prd 10240、design M 12288/L 30720、implement 20480、code-map 20480、合计 61440 字节）、M 级 >3 类或跨模块。warn：备选方案不足 2、异常场景无测试、开放问题未勾选、R 无测试行。
- **单测门禁**：命中 `testGate.include`（`*Controller|*Service|*ServiceImpl.java`）→ 测试路径由 `testPathMap` 把 `src/main/java` 换成 `src/test/java`（保留模块前缀）+ `Test`/`Tests`；`Impl` 后缀可去；测试文件须本次改过且含 `@Test|@ParameterizedTest|@RepeatedTest|@TestFactory`；纯接口跳过；`--staged`（只看 index）/`--base <ref>`；`methodLevel` 默认 `warn`；`--run` 按模块（最近的 `pom.xml` 目录）分组执行 `runCommand`，根模块用 `runCommandRoot`；静态检查失败则不运行 mvn。
- **OCR**：critical/high 不可 deferred、误报须引用存在的 `path:line`；medium/low 误报理由 ≥10 字；缺 severity 视为 medium；报告早于任何已改源文件 >1s 即 STALE（只改 `.opencode/` 不算）；第 N 次重跑要求上一份报告含 critical/high，且 N ≤ 1+`maxRerun`；背景 ≤ `backgroundMaxChars`(3000 字符)，按"丢豁免→文件→决策→需求"收缩。`--inspect` 打印提取到的 findings 与所用键。
- **任务选择**：`--task` > `TRELLIS_PLUS_TASK`（无效值=用法错误 exit 2）> `task.py current --json` 的会话任务 > **唯一** in_progress 任务（排除 `00-bootstrap-*`）；多个且无提示 → 不猜：hook 里 OCR 降为告警，命令行报错；hook 下无任务 → OCR 跳过并提示。
- **hook**：`pre-commit --hook` 只看已暂存文件；暂存里没有源码文件直接放行；`hook.runTests`（默认 false）才在 hook 里跑 mvn。

### 3.6 回归 harness 机制（`test-harness/run-regression.sh`）
- 环境变量：`BASE`（必需）、`TOOL`、`ONLY=D,E`、`V11_TOOL`。退出码=失败数。假 ocr：`FAKE_OCR_FINDINGS_FILE/VERSION/REJECT_BACKGROUND/LOG`；假 mvn：`FAKE_MVN_LOG/FAIL`。
- 辅助：`check`（退出码+文案）、`chk`（静默）、`reverse <label> <次数> <旧串> <新串> <chk 参数…>`（对**已安装**的 gate.mjs 做精确字符串变异；锚点次数不符本身算失败；变异后检查必须失败，还原后必须再通过）、`edit/editall/dropline/dropsection`、`mkproj/mkplan/fill/tri`。
- 注意：很多 `reverse` 的"旧串"是 `gate.mjs` 里的逐字源码。**改 gate.mjs 后先跑回归，会看到"anchor does not occur exactly N time(s)"，需同步更新对应变异串**，不要删掉对照。
- 回归依赖 BASE 里 `00-bootstrap-guidelines` 是 `in_progress`（L 组前置断言会检查）。

### 3.7 不能随意修改的地方
- §3.4 的格式契约与模板/样例：三者须一起改（样例是 lint 正例）。
- 面包屑：每块 [plus] 行合计 ≤400 字符、不得含 HTML 注释、`[required]` 步骤（1.6/1.7/2.4/2.5）在面包屑里须有对应行（A 组断言）。
- `CTX_ORIG/CTX_V11/CTX_NEW`、`TASKPY` 补丁标记、hook 块标记：改了会破坏升级/还原。
- 退出码语义（0/1/2）与 `TRELLIS_PLUS_SKIP_GATE`。
- `plus.config.json` 是项目所有文件，`apply` 不能覆盖。

### 3.8 被否决/未选的方案
- 三个 reviewer + 3 轮 → 改为 1 个 + 最多 2 轮（费 token 且 v1.1 没证据显示更准）。
- ID 链与 hash 强制过期 → 评审后改文档只告警（修复阻塞本就要改文档）。
- 复制/兜底 grill-me → 只检测存在性（方案 §4/§11）。
- tier 存 `.plus-tier` 文件 → 用 `meta`（原生）。
- 方法级检查默认 error → 默认 warn（按名字近似有误报）。

## 4. 下一步实施计划

编码已完成；剩余是**验证、校准与交付**，大多需要内网。不要新增功能，除非用户确认。

| 编号 | 目标 | 涉及文件 | 要求 | 前置 | 单测/回归 | 验收 | 状态 |
|---|---|---|---|---|---|---|---|
| N0（**先做**） | 重建工作区并确认基线 | zip、`base/`、`snapshot/` | 解压 `trellis-plus-v2.zip`；让用户重新提供 `trellis-opencode.zip` 作 BASE（及可选 v1.1 原目录作 `V11_TOOL`）；校验 §2.7 的 sha；用 bash 跑回归 | 无 | 全量回归 | 421/0 或如实记录差异 | **已完成（2026-10-13）**：见 §2.8 |
| N1（部分完成，见 §2.9） | 用真实 ocr 输出校准解析 | `assets/plus/gate.mjs`（`FINDING_KEYS`、`extractFindings`、`ocrGate`）、`test-harness/fixtures/ocr/`、K 组 | 请用户在内网贴 `ocr review --audience agent --format json` 的真实 JSON（脱敏）、退出码行为、`--background-file` 是否被接受；据此改解析并把真实样例加为夹具 | 用户提供真实输出 | 新增：真实形状的正例、漏键反例、反向对照（K 组） | `gate ocr --inspect` 对真实报告提取数与人工计数一致；K 组全绿 | **阻塞：待用户提供** |
| N2（用户决定：保持现状，不做） | 真实 Maven 验证 | `testGate.runCommand/runCommandRoot/testPathMap`、J 组 | 在内网多模块项目跑 `gate test --run`；确认 `-pl <module> -am -Dtest=… -Dsurefire.failIfNoSpecifiedTests=false`、模块判定、测试位置假设；不符则改配置默认值 | 用户反馈（模块结构：待确认） | J 组补对应形状（如独立测试模块）+ 反向对照 | 在用户的真实项目上命令成功且只跑目标类 | **阻塞：待用户** |
| N3 | 一次真实 L 级任务走通 | 整个流程 | 勘探→`/grill-me`→`gate align`→起草→`lint-plan`→评审→start→实现→`gate test --run`→`gate ocr --run`→`pre-commit`；每阶段 `gate usage` 记 token | N1、N2 | 发现的问题按"先复现→补回归→再修" | 流程无死锁；记录 token；回填 S/M/L 目标 | 尚未开始 |
| N4 | OpenCode 里的行为核对 | `plus-design-reviewer.md`、`plus-draft`、`/plus-grill-design`、`/grill-me` | 确认 skill/command/agent 能被加载与触发；reviewer 报告能通过 `gate design-review`；第 2 轮增量行为合理 | N3 | 报告格式偏差 → 补夹具与规则 | 用户确认评审可读（≈20 分钟目标，主观） | 尚未开始 |
| N5（可选，需用户先确认） | 降低 `gate.mjs` 体量或调整默认值 | `gate.mjs`、对应 `reverse` 变异串 | 例如 `methodLevel` 默认改 error、拆分文件。**未决定，不要擅自做** | 用户决定 | 任何改动先改回归 | — | 待确认 |
| N6 | 交付到用户仓库 | README | 若用户要放进 Git：确认放置位置与 `.gitignore`；`apply --all` 前先 `--dry-run` | 用户 | — | 用户项目 `doctor` 通过 | 待确认 |

## 5. 新会话启动后的第一个任务与检查清单
**第一个任务：N0。** 执行前必须检查：
1. 沙箱里是否还有 `/home/claude/work/trellis-plus`；没有就解压用户上传的 `trellis-plus-v2.zip`。**不要假设旧会话的任何文件还在。**
2. 对比 §2.7 的 sha256；不一致说明用户改过文件或包不同，先列差异。
3. 没有 Git：改任何文件前先 `cp -a trellis-plus snapshot-<日期>`，改完用 `diff -rq` 对照，避免覆盖已有工作。
4. 需要用户重新上传 `trellis-opencode.zip`（BASE）；回归没有它跑不起来。
5. 确认 `bash`、node ≥ 18、python3 可用；`mvn`/`ocr` 在沙箱里没有属正常（用假脚本）。

## 6. 待确认事项（不要替用户决定）
1. ocr 真实 JSON 结构、退出码、`--background-file` 支持（阻塞 N1）。
2. Maven 多模块结构：测试是否总在同模块 `src/test/java`；有无纯聚合模块/独立测试模块；父 pom 的 surefire 配置；JDK/Mockito/JUnit5 具体版本。
3. CodeGraph 在内网 opencode 的调用形式（目前 code-map 与工具无关）。
4. `/grill-me`、`grilling` 的实际安装位置与触发方式；`grilling` 是否允许模型调用。
5. OCR 重跑次数的解释（`maxRerun=2`，首次不计）是否符合用户本意。
6. 是否把 `methodLevel` 默认升为 `error`；是否要瘦身 `gate.mjs`（N5）。
7. 是否将本项目纳入 Git、放在哪个仓库。

## 7. 新会话启动提示词（可直接复制）

```text
你接手 trellis-plus（Trellis 0.6.17 + opencode 的 Node 增强脚本）v2 的后续工作。编码已完成，剩余是验证与校准。请严格按以下要求：

1. 先完整阅读 HANDOFF.md，以及它指定的文件：trellis-plus/README.md、docs/FINAL-DEV-PLAN.md、assets/plus/gate.mjs、trellis-plus.mjs、assets/workflow、assets/skills、assets/agents、assets/plus/templates、test-harness/（尤其 run-regression.sh 与 README.md）。
2. 先确认工作区真实状态：不要假设旧会话的文件还在。该项目没有 Git 仓库；若 /home/claude/work/trellis-plus 不存在，请解压我上传的 trellis-plus-v2.zip，并按 HANDOFF §2.7 校验 sha256。改动前先 cp -a 做快照，改动后用 diff -rq 对照，避免覆盖或丢失已有工作。
3. 以最新的实际代码和我明确的需求为准；发现 HANDOFF 与代码/测试结果不一致时，先分析差异并告诉我，再动手。
4. 从 HANDOFF §4 的 N0 开始（解压、校验、用 bash 复跑回归得到真实基线，不改代码），再按依赖顺序推进；不要重复实现已完成的功能，不要新增 HANDOFF 之外的功能。N1/N2 需要我提供内网信息时请直接向我索取。
5. 遵循原有技术方案（做减法：删 alignment 门禁/三 reviewer/ID 链；保留 hook、agent 补丁、单测门禁、OCR 分诊）。如果你认为方案有问题，先说明原因和影响，再提出修改建议，等我确认。
6. 每个新增/修改的门禁规则必须有正例、反例，并做“临时破坏逻辑确认断言会失败”的反向对照（用 run-regression.sh 的 reverse 机制；改 gate.mjs 后同步更新其变异串，不要删对照）。对修改过的 Java service/controller 相关逻辑，按 Java 8 + Maven 多模块 + JUnit5 + Mockito（不用 JaCoCo）的项目测试规范补充或更新单元测试。
7. 所有 shell 脚本用 bash；多处替换的补丁脚本先全部断言再统一写出，写后用特征串计数确认。
8. 如实报告测试与构建结果；无法验证的（内网、ocr 真实输出、真实 Maven、CodeGraph、真实 OpenCode 行为）明确标注“未验证”。
9. 每完成一个任务，更新 HANDOFF.md 的进度记录并重新打包，保证可以再次交接。
先回复：你读到的工作区真实状态、N0 的执行计划，以及哪些待确认项会阻塞你。
```


## 8. 2026-10-14 追加修改（以 micro 为底，参考 chr）

用户确认三点修改：

1. **Design 章节顺序**：将「数据库变更」放在「详细设计」前面。
   - `assets/plus/gate.mjs` `DESIGN_ALWAYS`：`["数据库变更", "5 数据库变更"], ["详细设计", "6 详细设计"]`
   - 模板 `assets/plus/templates/design.md`、样例 `assets/spec/plus-doc-samples/design.md`
   - `assets/skills/plus-draft/SKILL.md` 章节引用
   - `test-harness/run-regression.sh` 中 dropsection / missing / empty / sample 断言全部改为 `## 5 数据库变更` / `## 6 详细设计`

2. **默认 profile**：`strict` → **`standard`**
   - `DEFAULT_CONFIG.profile`、`assets/plus/plus.config.json`、使用说明示例与表格

3. **tier 定级流程**：AI 先根据代码给出 S/M/L 建议与理由 → 用户在对话中选择 → 再执行 `gate tier … --reason "<理由；用户选 X>"`
   - `needTier` 报错文案、`cmdStatus` 提示、`assets/workflow/index.md`、README / 方案介绍 / 使用说明

**未改**：implement 上限仍 20 KB；OCR / 单测逻辑保持 micro 原样。

文档已同步：根目录与 `trellis-plus/docs/` 下的《方案介绍》《使用说明》、README、本 HANDOFF、优化进度。
