# trellis-plus v2 开发记录（实施结果）

> 本文只记录**已实现并测过**的内容、与方案的偏离、实测数字、以及**未验证**项。方案本身见《trellis-plus v2 工作流优化方案》。v1.1 的旧文档在 `docs/archive/`。

## 1. 结果概览

| 项 | v1.1 | v2（实测） |
|---|---|---|
| 回归 | 45 / 54 通过（9 条是夹具过时，另有 2 条"假通过"） | **421 / 421 通过**，其中 **112 条反向对照**（临时破坏门禁逻辑，断言必须失败）；连跑两次逐行一致，约 48 秒 |
| 每轮面包屑（[plus] 行以外的原生内容不计） | planning 块 1634 字符、in_progress 块 1397 字符 | planning **819**、in_progress **1196**（BASE 分别 449 / 871；[plus] 行分别 369 / 324 字符，断言 ≤ 400） |
| workflow 三块文本 | 9511 字节 | **6505** 字节（回归线 ≤ 7000） |
| skills + agents + 指南随包文本 | 40446 字节 | 31870 字节（含新增 command 与样例） |
| `gate.mjs` | 1108 行 | **1343 行**：删了 align 与 ID 链，但新增 tier / status / usage / matrix / 方法级检查 / 多模块，总量反而增加；"瘦身"目标只在文本与面包屑上达成，代码行数没有 |
| `trellis-plus.mjs` | 517 行 | 550 行（过期文件清理、command 支持、doctor 增项） |

## 2. 方案落地与偏离

按方案做减法：删 alignment 门禁、三个 reviewer、REQ/DES/IMP/TEST 的 ID 链、hash 绑定、`lightweight` 以外的分阶段 seed；保留 hook、agent 补丁、单测门禁、OCR 分诊。需求链只剩一级：PRD 的 `R<n>`。

与方案文字不同、且已在对话里说明的选择：

1. **tier 存 `task.json` 的 `meta.plus_tier`**（Trellis 原生 `task.py set-meta` 同一位置，实测 start/set-branch/finish 后保留），而非 `.plus-tier` 文件；兼容读 v1.1 的 `.plus-lightweight`（视为 S）。无 tier 的任务：带 v1.1 痕迹（`alignment.md`、三镜头评审报告、`DES-n`）的视为"legacy L"，格式类发现降为告警；其余必须先定级。
2. **步骤编号**：只有 1.6（起草）、1.7（评审），没有 1.8；定级、澄清写在 index 块与面包屑里。
3. **OCR 重跑**：`ocr.maxRerun=2`（首次不计），仅在上一轮有 critical/high 时允许，`--force` 可越过（技能要求告知用户）。方案里 `maxRounds=1/2` 的几处写法不一致，按此解释。
4. **`design-review.md` 覆盖写**，第 2 轮前主会话把旧版另存为 `.r1.md`；resolution 每行 `- #<编号> 采纳|驳回 — …`；报告头 `阻塞：N` 必须与表格里"阻塞"行数一致（方案之外新增的机械核对）。
5. `--tune-context` 不再属于 `--all`：v2 文档合计 ≤ 60 KB，落在默认注入上限内。
6. 新增 `status` / `usage` / `matrix` / `anchors` 四个零 token 辅助命令，和 `/plus-grill-design`（方案里的可选项）。

## 3. 门禁规则一览（均有正例、反例、反向对照）

- **align**：状态行、待确认问题清零、决策记录（M/L）、需求编号 `R<n>` 唯一；占位符与体积。
- **lint-plan**（真实性类 = error）：占位符、锚点（文件/行范围/符号）、章节存在且非空（M 可省 2、8）、每个 R 有模块与覆盖矩阵行、未知 R 引用、影响分析（有处置；≥5 处引用须标"高风险"）、implement 中的路径存在（新增须标注）、每个被改 Service/Controller 在测试矩阵里有 正常/边界/异常、体积上限、M 级 ≤ 3 类/单模块。风格类（备选方案 < 2、异常场景无测试、开放问题未清）= warn。
- **design-review**（L）：头部、表格一致、每个阻塞有回应、驳回须有存在的 `path:line` 或 prd.md 出处；轮次 > 2 与评审后改文档只告警。
- **test**：同模块、本次改过、含 `@Test`；`--base`、`--staged`、git 根在项目上层；Service 方法名近似检查（`warn|error|off`，私有方法不要求，Controller 只按文件）；S 改 Service/Controller 拒绝，M 超限拒绝；`--run` 按模块拼 `mvn -pl <module> -am …`。
- **ocr**：严重级别分诊（critical/high 不可 deferred、误报要代码证据）、报告过期、重跑预算、背景 ≤ 3000 字符（超限按丢条目收缩，标题截 120 字符）、版本/缺失检测。
- **hook**：只看已暂存文件；无任务时跳过 OCR；多任务时 OCR 降为告警。

## 4. 实施中发现并修复的问题（旧文档没有）

1. v1.1 基线有 **2 条假通过**（被别的失败顶掉），所以所有断言现在同时检查期望文案。
2. `task.py create` 会生成带 `TBD` 的 prd 骨架；`seed` 必须识别并替换，否则 align 永远过不了。
3. 每个新项目都带 `00-bootstrap-guidelines`（`in_progress`）：不排除它，"唯一的 in_progress 任务"永远不成立。已排除。
4. 重写 pre-commit 时一度丢了"hook 下无任务则跳过 OCR"，会拦住所有非任务提交；回归 L 组发现并修复。
5. OCR 背景里任务标题无上限，会把末尾的评审指令截掉；已加 120 字符上限。
6. 带状态的反向对照会污染自己（重复 `--run` 触发重跑上限）；检查函数一律用新任务。
7. T0 里"面包屑 no_task 4091→6290"是测量脚本的误差（正则吞了 Phase Index），真实的 no_task 块未变；planning/in_progress 的数字有效。

## 5. 未验证 / 已知限制

- **ocr 的真实输出格式未验证**（沙箱无 ocr）。`extractFindings` 对 5 种夹具形状通过，真实报告到手后用 `gate ocr --inspect` 核对，并按需调整 `FINDING_KEYS`。`ocr` 退出码语义、`--background-file` 在真实版本上是否存在也未验证（后者有"不认识则重试"兜底，只用假 ocr 测过）。
- **真实 Maven 未验证**：沙箱没有 mvn，只验证了命令拼装、按模块分组、嵌套模块、根模块、失败传递和"静态检查失败则不运行"。surefire 是否按预期过滤、`-am` 下跨模块行为需在内网实测。
- **CodeGraph 未验证**；勘探只写了"工具无关"的 code-map 模板与清单。
- **`/grill-me` 与 `grilling` skill 未提供也未在 OpenCode 里实测**：流程要求用户手动输入 `/grill-me`；缺失时 `apply` / `doctor` 只告警。`/plus-grill-design` 同样未在真实 OpenCode 里试过。
- **评审 agent 的真实效果未验证**：只检查了文件内容与安装；评审质量、第 2 轮增量行为需要真实任务试跑。
- **token 目标**（S 60k / M 150k / L 320k）是上限而非实测，`gate usage` 靠人工记录。
- 方法级检查按名字近似；`isPureInterface`、`javaMethods` 是正则近似，非完整 Java 解析。
- 沙箱里没跑过 Windows / Java 8 真实编译；Java 夹具只是被扫描的文本，不被编译。

## 6. 升级与回退

- v1.1 → v2：`node trellis-plus.mjs apply <project> --all`（`V11_TOOL` 升级用例实测：删除 7 个过期文件、本地改过的保留、plugin 补丁升级、doctor 通过）。`plus.config.json` 不会被覆盖，v1.x 键被忽略，`doctor` 会点名。进行中的 v1.1 任务不需要迁移：按 legacy 处理。
- `revert --purge` 实测使 workflow.md / task.py / plugin / config.yaml / 两个 agent 文件以及整个项目树（除 `.trellis/plus/` 下的 config 与 backup）与 BASE 字节一致。

## 7. 回归怎么跑

见 `test-harness/README.md`。`BASE` 需用 `trellis init --opencode` 生成（本次用 0.6.17）。
