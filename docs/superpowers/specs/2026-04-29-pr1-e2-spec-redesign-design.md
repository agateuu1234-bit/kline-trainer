# PR1-E2 Spec Redesign — Design [ABORTED]

> **Status**：**aborted 2026-04-29**。第三轮 Opus 4.7 xhigh adversarial review (16 Critical + 24 Important + 13 Minor) 抓出基础事实错配（§M0.1 / §M0.3 / §M0.4 / `CONTRACT_VERSION` 全错挂在 plan_v1.5.md，真实在 modules_v1.4.md L125/395/588）+ scope packaging 违反 memory `feedback_planner_packaging_bias` 硬规则（12 个独立子项硬塞 3 sub-task）+ governance circular dependency 未解（spec authority vs m01 reference 同 PR 自循环）+ filename / contract semver 命名碰撞 latent bug（`plan_v1.5.md` doc semver vs CONTRACT_VERSION `1.5`）。Reviewer verdict：reject + abort + 重 brainstorming。
>
> **保留作 audit trail**。前两轮 brainstorming 在错误前提下"收敛"的草稿不再可信；新 design doc 路径见 `docs/superpowers/specs/2026-04-29-pr1-e2-spec-redesign-v2-design.md`（待重 brainstorming）。
>
> **教训**：见 memory `feedback_brainstorming_grep_first.md` —— brainstorming 第一步必须 grep 验证文档归属。
>
> **起因**：PR #36 (PositionManager 实现) 卡 codex 8 轮 needs-attn；R7-1 反复要求 `buy/sell` 改 `throws`，但项目走 **B 方向 = 守 precondition + spec §4.2 加 design rationale block**，由 spec 论证而非代码迁就 codex。
>
> **关键转折**：R2 adversarial review 推翻初版 "CONTRACT_VERSION 不 bump" 的 A 路线 —— PR #36 改 PositionManager Codable conformance 从 auto-synth → throwing custom init 是 caller-visible 行为变化，命中 m01 §Bump 策略 A 类 "改既有语义"。**最终决策：M0.3 `1.3` → `1.4`，联动顶层 `CONTRACT_VERSION` `1.4` → `1.5`**。

## 范围

落地 PR #36 卡死的 spec 层论证缺口：

1. `kline_trainer_plan_v1.5.md` §4.2 PositionManager 代码块同步 PR #36 impl + 加 §4.2.1–§4.2.7 7 节 design rationale block
2. 同 spec §M0.4 加 `invariantsHold` contract 节（B 方向硬前提，否则 §4.2.1 引用悬空）
3. `docs/governance/m01-schema-versioning-contract.md` 矩阵 cell bump（M0.3 + 顶层）+ §Bump 策略 A 类 bullet 1 扩描述 + §未来强制点 升级 backlog
4. `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` 6 行矩阵断言 cell 值同步
5. `kline_trainer_modules_v1.4.md` §E2 加 cross-ref 指向 plan §4.2 rationale

## 不在范围

- ❌ `PositionManager.swift` 实现改动 → 保留 PR #36 现有 5 层 precondition 防御
- ❌ PR #36 测试改动 → 保留现有 14 个测试（含 6 个 decoder reject）
- ❌ E5 TrainingEngine 调用点改动 → 不引入 try/catch
- ❌ 新建 `enum PositionError` / `Result<_, _>` API → B 方向不需要
- ❌ §17 Test Plan 修改 → spec 内无 "100% branch coverage" 硬性要求，本 PR 不需要触及
- ❌ AppDB GRDB 新 migration → Wave 0 无遗留 invariant-violating 数据基线，登记 m01 backlog
- ❌ CI assert（CONTRACT_VERSION 常量与 m01 矩阵同步）落地 → 延后到 Plan 2 B3 同 PR
- ❌ PR #36 codex 复审若仍卡的 root cause → 单独 diagnose

## 架构 / 子项拆分

PR scope 8 改动点重新打包成 3 个逻辑子项以满足 ≤3 硬上限（per memory `feedback_planner_packaging_bias`）：

**Sub-task 1：spec doc 改动**（≈260 行）
- spec §4.2 代码块同步 PR #36 impl（precondition + throwing custom init + Sendable/Equatable）
- spec §4.2.1–§4.2.7 design rationale block（trust-boundary / stdlib 一致性 / 数量级表 / 溢出语义 / alternatives / acceptance / migration note）
- spec §M0.4 `invariantsHold` contract 加节（4 字段 + O(1) 复杂度）
- spec 内 `CONTRACT_VERSION = 1.4` 字串同步（spec §M0.1 / §M0.3）
- modules §E2 加 cross-ref

**Sub-task 2：m01 contract bump**（≈70 行）
- m01 矩阵 row 1 cell `"1.4"` → `"1.5"`
- m01 矩阵 row 5 cell `"1.3"` → `"1.4"`
- m01 §Bump 策略 A 类 bullet 1 扩描述（加 Codable conformance 行为变化为显式触发例）
- m01 §未来强制点 第 1 项升级（CI assert 优先级 → Plan 2 B3 同 PR 落地）+ 加第 6 项（acceptance script 同 PR 更新规则）

**Sub-task 3：acceptance script 同步**（≈10 行）
- `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` 6 行矩阵断言 cell 值更新

**总量**：~330-340 行 doc + ~10 行 shell = **0 行 prod 代码**，远低于 ≤500 行硬上限。

## spec §4.2.1–§4.2.7 design rationale block（最终草稿）

> **位置**：`kline_trainer_plan_v1.5.md` §4.2 PositionManager 代码块（line 630-661）正下方。

````markdown
**§4.2 PositionManager — API contract & rationale**

`PositionManager.buy / sell` 在违约输入上 `precondition` trap，不 `throws`，不返回 `Result`。下面 4 条 codify API 不变量与处置策略；3 条 considered alternatives 列入末尾。

**§4.2.1 Trust-boundary 定位**

PositionManager 有两条 ingress：

```
Ingress 1 (in-process mutation):
  UI → E3 TradeCalculator.quoteBuy → Result<BuyQuote, TradeReason>
       ├─ .failure → UI Toast，链路终止
       └─ .success(quote) → E5 TrainingEngine → position.buy/sell

Ingress 2 (persistence load):
  SQLite position_data (TEXT) → JSONDecoder → Position.init
       └─ DecodingError throws / invariantsHold == false → load 失败，链路终止
```

E3 用 `Result<_, TradeReason>` 暴露所有 caller-side recoverable error（资金不足、tier 非法、价格非法、佣金溢出）。Decoder 用 `throws DecodingError` + `invariantsHold` 守门 persistence ingress。**buy/sell 的违约输入在两条 ingress 守门后均不可达**；其触发 ⟺ caller 侧 programmer error。

PositionManager.buy/sell 的 contract 不绑定具体 caller 身份；当前 caller 仅 E5，未来新增 caller 须满足同一 quote-验证前置条件。

**Bump 决策（钉死 codex 攻击面）**：

本节确立 PositionManager Codable 行为从 auto-synth 升级为 throwing custom init，新增 caller 可见 invariant `invariantsHold(shares, averageCost, totalInvested)`。命中 m01 §Bump 策略 A 类"改既有语义"触发条件 → M0.3 Swift 模型版本 `1.3` → `1.4`，联动顶层 `CONTRACT_VERSION` `1.4` → `1.5`。

wire format schema-level 守恒（三键不变 `{shares, averageCost, totalInvested}`），semantics-level 升级（新 decoder 拒收 invariant-violating 行）。Wave 0 项目首次模块 PR 无遗留 invariant-violating 数据基线，不引入新 GRDB migration；Wave 1+ 启用真用户数据前，登记 m01 backlog "invariant-validation migration `0004_vX_validate_position_data`"。

PositionManager 持久化范围限于 app.sqlite，不参与 REST/PostgreSQL 跨系统传输；本 bump 仅影响 iOS 内部存储一致性，不要求 backend 同步。

**§4.2.2 Swift stdlib 处置一致性**

Swift stdlib 处置策略二分：
- **programmer error / contract violation → trap**：`Array.subscript(i)`、`Dictionary.subscript!`、`Int.+(_:_:)`、`String.UnicodeScalar.init(_:)`。
- **I/O / parse / external-input error → throws**：`JSONDecoder.decode`、`String(contentsOf:)`、`FileHandle.read`。

`buy(shares:totalCost:)` 的违约输入在 §4.2.1 两条 ingress 守门后只剩 caller-side programmer error 一类，归 trap 处置。

**§4.2.3 Threat model（in-process 输入域 vs 类型上界）**

| 量 | 真实上界（量级） | 类型上界（量级） | gap |
|---|---|---|---|
| `averageCost` (Double, 元/股) | ~10⁴ | ~10³⁰⁸ | ~304 |
| `shares` (Int64, 股) | ~10⁶–10⁷ | ~10¹⁹ | ~12–13 |
| `totalInvested` (Double, 元) | ~10¹⁰ | ~10³⁰⁸ | ~298 |

数字为粗量级估算（参 §E1 PriceFeed `[0.01, 9999.99]` 元/股 + §0 scope 单用户日内 ≤10⁴ 笔），仅用于说明 in-process 输入域与类型上界 gap，**不**作 contract 上界。

合成 `+inf` / Int 溢出需输入接近 Double.max / Int64.max，唯一构造路径是 SQLite 文件被外部进程篡改（root 已陷落，sandbox 已破）。Decoder ingress 已守 `isFinite` + `invariantsHold`，in-process ingress 由 E3 守。**buy/sell mutating 路径的二次守门 ROI 为负**。

**§4.2.4 数值溢出语义**

- **Int 路径** (`self.shares + shares`)：Swift 默认 trap on overflow。
- **Double 路径** (`self.totalInvested + totalCost`)：IEEE 754 saturating 至 ±inf，**不** trap。

实现要求（详 §M0.4 `invariantsHold`）：
1. mutation 前用 `addingReportingOverflow` / `isFinite` 预检合成结果，违约即 precondition trap（带违约参数 + 当前 state 进 trap message）；
2. 预检通过后写入 self.shares / self.totalInvested；
3. debug build end-of-function `assert(invariantsHold)` 兜底，不作主守门。

`invariantsHold: Bool` 由 §M0.4 定义，复杂度 O(1)，校验：`shares ≥ 0` ∧ `totalInvested ≥ 0` ∧ `totalInvested.isFinite` ∧ `(shares == 0) ⟺ (totalInvested == 0)`。

**§4.2.5 Considered alternatives**

| 提案 | 处置 | 理由 |
|---|---|---|
| buy/sell public API throws | 拒 | caller 在 §4.2.1 守门后的 dead branch 上被强制写 try!/try?，徒增噪声；internal-helper-throws 版本与 precondition 等价但多一层 indirection。 |
| 改 `Result<_, TradeReason>` 与 E3 风格统一 | 拒 | 不同 error class：E3 处理 caller-recoverable error；§4.2 处理 invariant violation。统一为 false symmetry。 |
| buy/sell 提供 in-process defense-in-depth | 拒 | defense-in-depth 在跨进程/跨网络/跨用户 trust boundary 适用；§4.2 scope 在 in-process 同一 MainActor 内，二次 throws 守门 ROI 为负。 |

**§4.2.6 Acceptance 与 testability**

- precondition 语义 = fail-fast on programmer-contract violation，debug/release 均保留 trap，**不**视为正常控制流。
- buy/sell 违约输入路径**不在 test surface 上**（contract 假设上游已守门，违约路径无 caller-side 责任可测）。caller-recoverable error 的 test matrix 在 §E3 spec。
- Trap message 必须含违约参数 + 当前 Position state，便于 production crashlog 反查（具体 format 见 §M0.4.X）。

**§4.2.7 Migration note**

本 contract 假设 v1 sandbox 单用户、无外部数据 import 路径（v1 / v2 定义见 §0 scope）。若 v2 引入云同步、跨设备、外部 CSV import 等新 ingress，§4.2 contract 须重新评估，可能需将 buy/sell 升级为 throws / Result。
````

## spec §M0.4 invariantsHold contract 加节（最终草稿）

> **位置**：`kline_trainer_plan_v1.5.md` §M0.4 AppError 章节末尾追加新子节。

````markdown
**§M0.4.X PositionManager.invariantsHold Contract**

由 §4.2 PositionManager 引用。`invariantsHold` 函数本身是 PositionManager 内部 `private static` helper（不暴露公共 API），但其**校验语义构成 caller-visible invariant** —— 即 caller 可依赖"PositionManager 任何 public API 调用之后 invariantsHold(state) 恒为 true"。本节 codify 该语义契约供 §4.2.1 trust-boundary 引用。

**Signature**：
```swift
private static func invariantsHold(
    shares: Int,
    averageCost: Double,
    totalInvested: Double
) -> Bool
```

**Contract**：

1. **复杂度** O(1) —— 仅校验 4 个字段，不做循环/递归/外部调用。
2. **校验项**：
   - `shares ≥ 0`
   - `totalInvested ≥ 0` ∧ `totalInvested.isFinite`
   - `(shares == 0) ⟺ (totalInvested == 0)`
   - `shares > 0` ⟹ `averageCost > 0` ∧ `averageCost.isFinite` ∧ `averageCost * Double(shares)` 在 IEEE 754 容差内 == `totalInvested`
3. **使用点**：
   - `PositionManager.init(from:)` decode 时调用，false → `throw DecodingError.dataCorrupted`
   - `PositionManager.buy/sell` mutation 前 candidate-state 校验，false → `precondition` trap
   - Debug build `assert(invariantsHold(...))` 兜底
4. **Trap message 格式**：buy/sell precondition 失败时 trap message 必须遵循 `"<TypeName>.<method>: <reason> (param1=v1, param2=v2, state=...)"` 约定，含违约参数与当前 self.shares / self.totalInvested / self.averageCost，便于 production crashlog 反查。
5. **不变量**：本 contract 是 PositionManager 的 caller-visible invariant 来源。任何对此 contract 的修改 → 重新评估 §4.2 + m01 §Bump 策略触发。
````

## CONTRACT_VERSION bump 矩阵

| 维度 | 旧 | 新 | 说明 |
|---|---|---|---|
| 顶层 `CONTRACT_VERSION` | `"1.4"` | `"1.5"` | 联动 M0.3 |
| M0.3 Swift 模型版本 | `"1.3"` | `"1.4"` | PR #36 Codable conformance 行为变化触发 |
| PostgreSQL schema | `0003_v1.3` | 不动 | PR #36 不影响 backend |
| 训练组 SQLite `PRAGMA user_version` | `1` | 不动 | PR #36 不影响训练组 |
| app.sqlite GRDB migration | `0003_v1.4_purge_leased` | 不动 | Wave 0 无遗留数据，不引入新 migration |
| P2 journal states | `v2` | 不动 | 无关 |

## m01 §Bump 策略 A 类 bullet 1 扩描述（最终措辞）

````markdown
- 改既有语义（含：state raw-value 语义、Codable conformance 行为如 auto-synth → throwing custom init、stored property 不变但 invariant 收紧等持久化契约语义升级）
````

## m01 §未来强制点 改动

**第 1 项升级**（原文）：
> [ ] **CI assert：`CONTRACT_VERSION` 常量与本文件矩阵同步**（spec L2232，v1.3 要求）：需先等 Plan 2 B3 在 Python 侧定义 `CONTRACT_VERSION = "1.4"` 常量...**落地形态待 Plan 2 B3 + Plan 3 F1 完成后另议**。

**改为**：
> [ ] **CI assert：`CONTRACT_VERSION` 常量与本文件矩阵同步**（spec L2232，v1.3 要求；**优先级升级 2026-04-29，本 PR bump 到 `"1.5"` 后**）：bump 后任何后续 PR 引用 CONTRACT_VERSION 必须用 `"1.5"`，没有 CI assert 意味着 drift 由 governance review 兜底。**Plan 2 B3 第一次 Python 侧定义 `CONTRACT_VERSION` 常量时，CI assert workflow 必须在同 PR 落地**（不再 defer）。落地形态：grep 本文件矩阵当前 cell 字串 vs 两侧（Python / Swift）常量。

**新增第 6 项**：
> [ ] **acceptance script 同 PR 更新规则**：本 PR (`2026-04-29 PR1-E2 spec redesign`) 已确立先例 —— 任何触发 m01 矩阵 cell bump 的 PR **必须同 PR** 更新 `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` 的对应行 cell 断言；不允许 spec doc 与 acceptance script 分批 PR。

## acceptance script 改动

`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` 6 行矩阵断言 cell 值同步：
- row 1 (顶层) `"1.4"` → `"1.5"`
- row 5 (M0.3) `"1.3"` → `"1.4"`
- 其他 4 行不动

## modules §E2 cross-ref

`kline_trainer_modules_v1.4.md` §E2 PositionManager 节追加：
````markdown
**API contract & rationale**：详 `kline_trainer_plan_v1.5.md` §4.2.1–§4.2.7（trust-boundary / stdlib 一致性 / 数量级表 / 溢出语义 / considered alternatives / acceptance / migration note）+ §M0.4.X `invariantsHold` contract。
````

## Rollout 路线

```
T0  spec PR open
    ↓ scope 显式列 8 改动点 + m01 frozen-doc 修改流程合规声明（引用 m01 L12）
T1  codex adversarial review（预期 3-4 轮收敛，超 5 轮 escalate）
T2  CODEOWNERS approve（单人项目 = user self-approve；branch protection 取舍权衡 per memory `feedback_branch_protection_single_dev`）
T3  spec PR merge
T4  PR #36 rebase 到 main（拿到新 spec rationale + bump CONTRACT_VERSION）
T5  PR #36 codex 复审（spec 已 codify B 方向 → 预期 1-2 轮闭嘴）
T6  PR #36 merge
```

## 8 行非 coder 验收清单（spec PR 用）

| # | 动作 | 期望 | 通过 |
|---|---|---|---|
| 1 | `git diff main...HEAD --stat` | 列出 4 文件改动：`kline_trainer_plan_v1.5.md`、`kline_trainer_modules_v1.4.md`、`docs/governance/m01-schema-versioning-contract.md`、`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | ☐ |
| 2 | grep `CONTRACT_VERSION.*1\.5` PR diff | 至少 3 处命中（m01 row 1 / spec §M0.1 / spec §M0.3） | ☐ |
| 3 | m01 矩阵 row 1 cell = `"1.5"`，row 5 cell = `"1.4"` | 两个 cell 都正确 bump | ☐ |
| 4 | `bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 退出码 0；6 行矩阵断言全过 | ☐ |
| 5 | spec §4.2 找到子节标题 §4.2.1–§4.2.7 | 7 节标题齐全 | ☐ |
| 6 | spec §M0.4 找到 `invariantsHold` contract 节（§M0.4.X） | 含 4 字段 + O(1) 复杂度声明 | ☐ |
| 7 | PR description 含 m01 frozen-doc 修改流程合规声明（引用 m01 L12） | 显式列出 spec→m01→codex→CODEOWNERS 4 步 | ☐ |
| 8 | PR `codex-verify-pass` GitHub status check | **绿灯** | ☐ |

第 8 行红/黄灯 → 不得 merge（CLAUDE.md backstop §1）。

## 测试策略

- spec PR 是 doc-only，**不跑 SwiftPM 测试**。验收 = acceptance script + 8 行清单。
- PR #36 rebase 后：现有 63 tests 维持 pass（prod 代码不动）；spec §4.2.6 钉死 "trap path **不在 test surface**"，PR #36 不需要新增 trap-path 测试。

## Codex review 策略

- spec PR 预期 round 数：3-4 轮（scope 大 + frozen-doc 修改）
- PR #36 复审预期：1-2 轮（spec 已 codify）
- 超 5 轮 escalate（per memory `feedback_codex_plan_budget_overshoot`）
- PR description 必含 §4.2.1 "Bump 决策" 段落作钉死论证

## Accepted residuals（非 PR scope）

1. **CI assert**（m01 backlog 第 1 项）落地延后到 Plan 2 B3 同 PR；本 PR 仅升级 backlog 优先级 + commitment
2. **PR #36 复审若仍卡** → root cause 不在 spec baseline，需单独 diagnose
3. **Wave 1+ invariant-validation migration** → 登记 m01 backlog，启用真用户数据前落地

## Memory compliance check

- ✅ `feedback_planner_packaging_bias`：3 sub-task ≤ 硬上限；prod 0 行 ≤ 500 硬上限
- ✅ `feedback_codex_plan_budget_overshoot`：超 5 轮 escalate 已写入 codex review 策略
- ✅ `feedback_pr_language_chinese`：spec / m01 / acceptance 全中文
- ✅ `project_modules_v1.4_frozen`：spec PR 不拆模块，只 codify 现有行为 + bump
- ✅ `feedback_reviewer_verdict_not_authorization`：spec PR push / merge 前需 user explicit confirm
- ✅ `feedback_dep_graph_m05_overstated`：本 PR 不涉及 M0.5 concurrency
- ✅ `feedback_infra_readiness_unaudited`：spec doc 改动不依赖 toolchain readiness

## Brainstorming convergence trail

- Round 1（§4.2 rationale）：4 Critical（数量级表算错 / shares 单位混淆 / trust-boundary 漏 SQLite ingress / false dichotomy）+ 11 Important + 3 Minor → 收敛草稿 §4.2.1–§4.2.7
- Round 2-5（CONTRACT_VERSION 决策）：推翻 A 路线 "wire compat 守恒" 论证 → 切换到 B 路线（同 PR bump）
- 关键 catch：m01 矩阵 row 5 (M0.3) 触发文本字面只覆盖 "Codable 字段 / 枚举 case 变更"，不覆盖 conformance 行为 → m01 §Bump 策略 A 类 bullet 1 必须**同 PR 扩描述**
- 关键 catch：m01 contract 是 frozen 文档（L3-12），bump-trigger footnote 不能写 spec §4.2（authority drift）→ 必须直接改 m01

## Cross-references

- **PR #36**：https://github.com/agateuu1234-bit/kline-trainer/pull/36（PositionManager impl，待本 PR merge 后 rebase）
- **spec 源**：`kline_trainer_plan_v1.5.md` §4.2 + `kline_trainer_modules_v1.4.md` §E2
- **governance frozen doc**：`docs/governance/m01-schema-versioning-contract.md`（L3-12 frozen 状态 + L12 修改流程）
- **acceptance script**：`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`
- **CLAUDE.md backstop**：§1 codex-verify-pass / §2 非 coder 验收清单 / §4 skill gate
- **memory 引用**：`feedback_planner_packaging_bias` / `feedback_codex_plan_budget_overshoot` / `project_modules_v1.4_frozen` / `feedback_reviewer_verdict_not_authorization`
