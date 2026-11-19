# Trellis-Plus Bugfix 工作流建议

> 状态：方案建议，尚未实施。
>
> 目标：把“缺陷修复”从“需求开发”的 6 道门禁流程中拆出来，在保证不引入回归的前提下缩短修复路径。

---

## 1. 原始问题

新建 task 完成需求开发后，如果恰好产生了 bug，后续又新建 task 进行 bugfix。在 bugfix 时被迫使用 L 级别任务，进行全流程门禁校验，流程太长，不利于快速修复。

初步想法：单独创建一个简单的 bugfix 工作流，与现有的 6 道门禁工作流区分。

同时需要回答：如何确保 bugfix 过程中不引入其他 bug？

---

## 2. 现状判断

### 2.1 当前代码并没有强制 bugfix 用 L

相关逻辑：

- `trellis-plus/assets/plus/gate.mjs:497` `cmdTier`：只在 S/M 超限时拒绝。
- `trellis-plus/assets/plus/gate.mjs:514`：M 允许 ≤3 个 Service/Controller、同一 Maven 模块。
- S 不允许修改 Service/Controller；M 仍要求 `prd.md + design.md + implement.md + lint-plan`。
- L 才要求 `research/code-map.md` 和独立设计评审。

因此“bugfix 被强制 L”通常来自两个原因：

1. M 仍要求完整的设计/实施文档，对修 bug 太重；
2. bug 触碰了 M 的硬限制（多模块、>3 个 Service/Controller、库表/对外契约/事务并发），这种情况确实应该升级，不能靠流程绕过。

### 2.2 现有流程是“需求中心”，不是“缺陷中心”

现有产物：

- `prd.md`：需求编号 R<n>、验收标准、决策记录、对齐状态
- `design.md`：完整方案、影响分析、覆盖矩阵
- `implement.md`：实施步骤、测试矩阵
- `research/code-map.md`：L 级勘探
- `reviews/design-review.md`：L 级独立评审

这些产物适合“从 0 到 1 开发需求”，但对“已知现象、已知根因、最小修复”的 bugfix 来说大量内容是不必要的。

### 2.3 可以复用的现有能力

- `gate.mjs:982 preStart`：`task.py start` 调用的硬门禁入口。
- `gate.mjs:997 cmdSeed`：按级别生成模板。
- `gate.mjs:1176 testGate`：Service/Controller 单测门禁。
- `gate.mjs:1408 ocrGate`：OCR 评审与分诊。
- `verifyAnchors`：校验 `文件:行#符号` 锚点。
- `trellis-plus.mjs:249`：`task.py start` 已挂载 `pre-start` 硬门禁。
- `plus-testing-guide.md:22`：已经写明“Bug fix → add the regression test that fails without the fix”。

---

## 3. 核心建议

**不要新增第 4 个 tier，也不要把所有 bugfix 一律定为 L。**

建议新增一个与 tier 正交的任务维度：

```json
{
  "meta": {
    "plus_flow": "bugfix",
    "plus_bug_source": "10-09-order-feature",
    "plus_risk": "auto"
  }
}
```

- `plus_flow`：`feature`（默认）或 `bugfix`
- `plus_bug_source`：产生该 bug 的原始任务/提交，用于注入原 PRD、design 作为上下文
- `plus_risk`：`auto`，由 gate 根据改动自动判定 M/L，不让人手工选 L

理由：

- **tier 表示风险/规模，flow 表示任务意图**，两者不应混在一起。
- 如果新增 tier B，会导致“大 bugfix 无法升级”或“所有 B 都被当成低风险”。
- 用 flow 维度更干净，也更容易兼容现有 S/M/L 逻辑。

---

## 4. 推荐的精简流程

```text
feature 流程：
1.0 定级 → 1.1 align → 1.6 design/implement → lint-plan
→ [L] code-map → [L] design-review → 1.4 start
→ 实现 → check → test → ocr → pre-commit

bugfix 流程：
0. 判断是否需要新建任务（已提交/已上线的缺陷才新建；未完成的需求直接在原任务修）
1. 写 bugfix.md → gate bug-plan
2. [仅高风险] targeted review，不做全量 design-review
3. 最小修复 + 回归测试
4. gate test --run（回归测试 + 受影响模块全量）
5. gate ocr（聚焦回归/未计划改动）
6. gate bug-verify（范围锁 + 红绿校验）→ pre-commit
```

### 4.1 保留

- `test` 门禁
- `ocr` 门禁
- `pre-commit` / git hook
- 根因锚点校验
- 风险自动升级

### 4.2 去掉或降级

- `/grill-me` 全量澄清
- `research/code-map.md`
- 完整 `design.md` + `implement.md`
- 全量 `align` 需求编号/覆盖矩阵
- 独立 `design-review`（仅高风险时做 targeted review）
- 大而全的测试矩阵

---

## 5. `bugfix.md` 契约

```markdown
# Bugfix: <标题>

关联任务: 10-09-order-feature
严重级别: P1
影响版本: ...

## 1 现象与影响
<用户看到什么、影响范围>

## 2 复现
| 前置条件/输入 | 期望 | 实际 |
| --- | --- | --- |

## 3 根因
必须写代码锚点：`OrderService.java:42#create`

## 4 影响面与允许改动
| 文件/符号 | 引用数 | 处置 |
| --- | --- | --- |

允许改动文件:
- `src/main/java/.../OrderService.java`
- `src/test/java/.../OrderServiceTest.java`

## 5 修复方案（最小改动）
<只写这次怎么修，不写重构计划>

## 6 回归测试
| 测试类#方法 | 修复前 | 修复后 |
| --- | --- | --- |

## 7 非目标
- 不顺手重构
- 不升级依赖
- 不改无关接口

## 8 风险与回滚
```

### 5.1 `gate bug-plan` 检查项

- 章节完整、无占位符
- 根因锚点真实存在（复用 `verifyAnchors`）
- 允许改动文件存在
- 回归测试字段非空
- 关联任务存在
- 风险关键字扫描：`schema / migration / 事务 / 并发 / 幂等 / 鉴权 / 对外接口 / pom.xml`
- 改动文件数/模块数超过阈值 → 自动升级为高风险

---

## 6. 如何确保 bugfix 不引入其他 bug

建议做成三道锁，不要只靠 OCR。

### 锁 1：锁范围（最有效，成本最低）

`bugfix.md` 中声明“允许改动文件”，gate 校验：

```text
本次 changed files ⊆ 允许改动文件 + 测试文件 + bugfix.md/reviews/spec
```

超出范围直接失败，并提示：

```text
src/main/java/.../OtherService.java 不在允许改动清单里。
如果确实需要改，请先更新 bugfix.md 的影响面并说明原因。
```

这能挡住“修 A 顺手改 B”“重构式修复”“升级依赖”等最常见的新 bug 来源。

建议同时限制 diff 规模：

- >5 个文件或 >200 行：告警
- >10 个文件或 >500 行：要求升级并人工确认

### 锁 2：锁行为（回归测试必须红→绿）

`plus-testing-guide.md:22` 已经写了“Bug fix → add the regression test that fails without the fix”，但当前没有强制验证。

**MVP：**

- gate 要求回归测试文件本次被修改，且测试方法名出现在 `bugfix.md`
- `bugfix.md` 记录“修复前失败”的命令和失败摘要
- 提交前跑一次受影响模块的全量测试，而不只是指定测试类

现有 `gate test --run` 只跑 `-Dtest=<classes>`（`gate.mjs:1236`）。bugfix 建议新增：

```bash
mvn -q -pl <module> -am test
```

即“模块全量回归”，在 pre-commit 或 CI 跑一次。

**进阶（强推荐，可作为第二阶段）：**

新增 `gate bug-verify --red-green <TestClass#method>`：

1. 用 `git worktree` 在 `HEAD` 建临时工作区；
2. 只把回归测试的改动应用过去；
3. 跑测试，必须失败；
4. 回到当前工作区，跑同一测试，必须通过。

注意：如果回归测试依赖修复新增的方法/签名，base 上无法编译，这时应要求测试只调用已有公开 API，或降级为人工确认并在 `bugfix.md` 记录原因。

### 锁 3：锁根因与上下文

- 根因必须是代码锚点，不是“某处逻辑有问题”
- 自动把原始任务的 `prd.md` / `design.md` 注入 `implement.jsonl` / `check.jsonl`，让子 agent 知道原需求边界
- `check` 阶段明确要求检查：是否改变原需求语义、是否影响同类调用方
- OCR 背景文件加入：根因、非目标、允许改动文件，并要求重点检查“未计划改动”和“相似代码路径是否也需要修”

### 锁 4：测试与评审的针对性

bugfix 的 OCR 不需要全量架构评审，但要有固定检查项：

- 事务边界是否因修复改变
- 并发/幂等是否引入新竞态
- 异常分支是否吞异常或改变错误码
- 空值/边界是否覆盖
- 是否只修了症状，没有修根因
- 是否有未声明改动

critical/high 仍然不可 defer，保持现有规则。

### 锁 5：spec 防复发

Phase 3 要求二选一：

- 在 `.trellis/spec/` 增加一条防复发规则；
- 或在 `bugfix.md` 写 `无：<原因>`。

例如：“Service 层对外方法必须对 null 入参做前置校验”。

### 锁 6：风险自动升级

不要让用户手工选 L，而是 gate 自动判断：

| 条件 | 处理 |
| --- | --- |
| 只改 1 个 Service 方法 + 测试 | 标准 bugfix |
| >3 个 Service/Controller 或跨模块 | 升级，要求 targeted review |
| 改库表/迁移脚本 | 升级，要求回滚方案 |
| 改对外接口/错误码/协议 | 升级，要求兼容性说明 |
| 事务/并发/幂等/安全相关 | 升级，要求专项检查 |
| 改 `pom.xml` / 依赖 | 升级 + 人工确认 |
| diff 超阈值 | 告警或升级 |

---

## 7. 对 `gate.mjs` 的改造点

MVP 可以很小：

| 位置 | 改动 |
| --- | --- |
| `gate.mjs:455 taskTier` | 增加 `taskFlow()`，读 `meta.plus_flow` |
| `gate.mjs:497 cmdTier` | 保留 feature 的 S/M/L；bugfix 用 `gate flow <task> bugfix --from <task>` |
| `gate.mjs:997 cmdSeed` | bugfix 只生成 `bugfix.md`，不生成 design/implement/code-map |
| `gate.mjs:982 preStart` | `flow=bugfix` 时走 `bugfixGate`，跳过 align/lint-plan/code-map/design-review |
| 新增 `cmdBugPlan` | 检查 `bugfix.md` 章节、根因锚点、允许改动、关联任务 |
| 新增 `cmdBugVerify` | 检查 scope lock、回归测试已改、diff 预算、模块全量测试 |
| `gate.mjs:1176 testGate` | bugfix 增加 `runModuleCommand` 全量模块测试 |
| `gate.mjs:1408 ocrGate` | 背景文件加根因/非目标/允许改动；提示重点查回归 |
| `trellis-plus.mjs:249` | `task.py start` 的 hard gate 已经调用 `pre-start`，无需新挂钩 |
| `workflow/index.md` | 增加 bugfix 分支说明和“什么时候不该新建 bugfix 任务” |

### 7.1 建议的命令形态

```bash
gate flow <task> bugfix --from <原任务>
gate seed <task>              # 生成 bugfix.md
gate bug-plan <task>         # start 前
gate test --task <task> --run --module-suite
gate ocr --task <task> --run
gate bug-verify <task>       # 提交前：范围锁 + 红绿校验
gate pre-commit --task <task>
```

---

## 8. 关键取舍

1. **不要用第 4 个 tier “B”**
   - tier 是风险/规模，B 是意图，混在一起会导致“大 bugfix 无法升级”或“所有 B 都被当成低风险”。
   - 用 `flow` 维度更干净，也更容易兼容现有 S/M/L 逻辑。

2. **不要自动跳过 test/ocr/hook**
   - 精简的是“规划文档”和“设计评审”，不是验证门禁。
   - bugfix 最容易引入回归，test + ocr + scope lock 反而应该加强。

3. **不要默认全量模块测试每次都跑**
   - 内循环只跑回归测试，提交前跑一次模块全量，避免拖慢修复。
   - 高风险 bugfix 才强制全量 + targeted review。

4. **未完成的需求不要新建 bugfix 任务**
   - 如果 feature 任务还没提交、没关闭，直接在原任务修，避免任务切换和上下文丢失。
   - 只有“已提交/已上线/跨迭代发现的缺陷”才新建 bugfix 任务，并关联原任务。

---

## 9. 预期效果

普通 bugfix 从“6 道门禁全流程”压缩为：

```text
bugfix.md → bug-plan → 修复 → 回归测试 + 模块全量 → OCR → scope lock → commit
```

同时通过：

- 范围锁
- 红绿回归测试
- 根因锚点
- 风险自动升级

把“修一个 bug 引入三个 bug”的概率压到最低。

---

## 10. 建议的落地顺序

1. **MVP**
   - 增加 `plus_flow`
   - `gate flow`
   - `bugfix.md` 模板
   - `gate bug-plan` / `gate bug-verify`
   - scope lock
   - bugfix 的 `preStart` 分支

2. **第二阶段**
   - 模块全量测试
   - `--red-green` 校验
   - 原始任务上下文自动注入
   - OCR 背景增强

3. **第三阶段**
   - 风险自动升级规则
   - spec 防复发检查
   - 与 CI / git hook 联动
