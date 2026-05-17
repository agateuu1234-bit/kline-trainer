# PR F1 — Models 模块薄 wrapper（BinarySearch utility + 目录整理 + §15.1 #6 sign-off）Implementation Plan

**Revision history：**
- **v1**（2026-05-16）：初稿 → codex R1 verdict `needs-attention`（3 findings：1 high + 2 medium）
- **v2**（2026-05-16）：codex R1 3 findings 全修
  - finding 1 (high) → D4 ledger 越权（M0.3 ModelsTests 未覆盖 FeeSnapshot / DrawingAnchor / DrawingObject Codable round-trip）→ 本 PR scope 新增 3 个 struct round-trip @Test，把 F1 验收"所有 Codable 类型 round-trip"真闭环；D4 ledger wording 改成具体类型清单（不再 over-claim）
  - finding 2 (medium) → Models.swift 实际 9 enum + 7 struct = 16 类型（不是我错算的 17）→ Step 1.1 grep -c 期望改 16；D2 ledger threshold 改 ≥ 16；File rationale 类型计数同步
  - finding 3 (medium) → BinarySearch tests 只测 `Array<Int>` exact match → 补 ArraySlice 非零起始 partitioning + lowerBound 三插入点（below-min / between / above-max）+ upperBound 三插入点；总 @Test 从 8 增到 15
- **v3**（2026-05-16）：codex R2 2 findings 全修
  - finding 1 (medium) → D4 over-claim "6 个 Codable enum" 错（实际 **5** Codable enum：Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode；TrainingMode / PanelId / SwipeDirection / PeriodDirection 非 Codable）+ "11 @Test" 错（实际 ModelsTests 13 @Test）+ PositionTier/DrawingToolType 现有 test 只检 rawValue 不是真 JSON round-trip → Step 2.7 扩到 **5 个 @Test**（3 struct + 2 enum 真 JSON round-trip 补 PositionTier/DrawingToolType gap）；Suite 改名 `AdditionalCodableRoundTripTests`；D4 ledger 列 11 个 Codable 类型清单 + 每个类型对应的具体 @Test
  - finding 2 (medium) → Acceptance B2 + Self-Review 多处 v1 残留 "8 @Test" / "6 enum + 8 struct" 数学 → 全文 grep 校对清零；总新增 = 15 BinarySearch + 5 Codable = **20 @Test**；最终 274 baseline + 20 = **294 tests in 63 suites**
- **v4**（2026-05-16）：codex R3 1 finding 修（v3 grep sweep 不彻底）
  - finding 1 (medium) → v3 声称"全文 grep 校对清零"但 Step 2.8 标题还残留 "18 个新 @Test"、acceptance section C 标题还残留 "BinarySearch 8 个 @Test" → Step 2.8 标题改 "20 个新 @Test (15 BinarySearch + 5 Codable round-trip)"；section C 标题改 "共 20 个新 @Test：BinarySearch 15 + Codable round-trip 5"
- **v5**（2026-05-16）：codex R4 1 finding 修（v5-time 历史数字；v6 进一步修订）
  - finding 1 (medium) → D4 inflated 现有 13 ModelsTests 全算 round-trip 闭环；v5-time 算 4 个 type 真 round-trip（Period / TradeDirection / DisplayMode / KLineCandle —— v5 误将 Period 计入，v6 R5 抓出）；Step 2.7 v5-time 扩到 7 @Test（v5-time 总新增 22，final 296）；D4 v5-time ledger = 4 现有 + 7 新增 = 11（v6 修正为 3 + 8）
- **v6**（2026-05-16）：codex R5 2 findings 修（user explicit 选项 A 必要修复 / 打破 5 轮预算）
  - finding 1 (medium) → R4 误算 Period 真 round-trip；实际现有 `period_encodesToRawString` (encode .m60 → string) 和 `period_decodesFromRawString` (decode separate string → .m3) 是**分离两个测试**，没有 feed encoder output back into decoder + equality 完整链 → Step 2.7 扩到 **8 @Test**（v5 7 个 + 1 新 `period_jsonRoundTrip_allCases` 用 for loop 跑 Period.allCases）；D4 精确改 **3 现有真 round-trip + 8 新增 = 11 全闭环**（TradeDirection / DisplayMode / KLineCandle 是真 round-trip，Period 移到 gap 8 之一）；总新增 = 15 + 8 = **23 @Test**；最终 274 + 23 = **297 tests in 63 suites**
  - finding 2 (low) → Step 2.7 prose / Suite comment / commit message 还有 v3 残留 "5 个" / "5 gap" 措辞（v5 加了 2 个但 prose 没刷彻底）→ 全文 grep 清零 "5 个" / "5 gap"，统一改 8
- **v7**（2026-05-16）：codex R6 2 findings 修（user explicit 选项 A 继续扩 budget）
  - finding 1 (medium) → v6 stale wording 没刷干净；Step 2.7 code comment / Step 2.8 / acceptance section C 标题 / Step 2.7 NOT-TDD note 还有 "5 个 gap" / "这 5 个" / "22 个新" / "Codable round-trip 7" → 全部改 8 个 gap / 这 8 个 / 23 个新 / Codable round-trip 8
  - finding 2 (medium) → PositionTier / DrawingToolType / Period 3 个 JSON round-trip @Test 用了 `#expect(json == "\"raw\"")` 字节比较；PositionTier rawValue 含 `/`，JSONEncoder 默认 `outputFormatting` escape 为 `\/`，会 brittle 失败 → 改为 `decodedRaw = try JSONDecoder().decode(String.self, from: data); #expect(decodedRaw == raw)` semantic 比较（不依赖字节 formatting；同时同模式应用到 Period + DrawingToolType 保持风格一致）
- **v8**（2026-05-16）：codex R7 1 finding 修（user explicit 选项 A — narrow F1 scope）
  - finding 1 (medium) → F1 D4 ledger 声称 "11/11 Codable 全闭环" 但 AppState.swift 里 3 个 M0.3 Codable struct (TrainingRecord / DrawdownAccumulator / PendingTraining) 不在 inventory；spec §F1 字面 "Models/ 承载 M0.3 所有类型" 但 M0.3 实际跨 `Models.swift` + `AppState.swift` 两个文件 → 决议 (user explicit) **narrow F1 PR scope to Models.swift only**；F1 D4 ledger wording 改成 "Models.swift 11 Codable 实体闭环"；AppState.swift 3 个 M0.3 Codable struct 进 plan-residual queue（H3 新增），future PR 闭环；spec §F1 字面 "M0.3 所有类型" 与 M0.3 实际多文件 split 之间的 over-claim 由 PR 9 governance §15.4 sign-off 阶段澄清（不在本 PR scope）；plan goal / spec 引用 / D4 wording 同步 narrowing
- **v9**（2026-05-16）：codex R8 1 finding 修
  - finding 1 (medium) → v8 H3 residual 不完整；M0.3 实际跨**三**文件不是两个：(a) `Models.swift`（本 PR scope）+ (b) `AppState.swift` 3 struct (TrainingRecord/DrawdownAccumulator/PendingTraining) + (c) `RESTDTOs.swift` 2 struct (LeaseResponse / TrainingSetMetaItem) → H3 residual 扩展明文列入这 5 个其它文件的 M0.3 Codable 实体；Goal section 同步 narrow wording 加 RESTDTOs.swift；spec drift over-claim 仍归 PR 9 governance

---

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task（本项目只用 subagent-driven-development，见 memory `project_executing_plans_excluded`）。每个 Task 派一个 fresh sonnet 4.6 high-effort subagent；Task 与 Task 之间主线 two-stage review。Steps use checkbox (`- [ ]`) syntax for tracking。

**Goal:** 为 spec `kline_trainer_modules_v1.4.md` §五 F1（L811-815）+ §十一 Checklist（L2184）+ §十三（L2286）+ §15.1 #6（L2453）落地 F1 数据模型模块**薄 wrapper**：把 `Models.swift` 物理放进 `Models/` 子目录（spec §F1 路径字面对齐），新增 `Models/BinarySearch.swift` 通用工具（§十三 明文 "BinarySearch 扩展 归 F1 通用工具区"），并把 `Models.swift` 内 11 个 Codable 类型的 round-trip / Equatable / Sendable 锁定到 F1 §15.1 #6 sign-off 验收 ledger 里。零 spec drift、零业务行为改动、零 Package.swift 改动。**Scope narrow（codex R7 + R8）**：本 PR 仅覆盖 `Models.swift` 内的 M0.3 类型；M0.3 实际跨 `AppState.swift`（3 个 Codable struct: TrainingRecord / DrawdownAccumulator / PendingTraining）+ `RESTDTOs.swift`（2 个 Codable struct: LeaseResponse / TrainingSetMetaItem）多文件 split → 这 5 个其它 M0.3 Codable 实体进 residual H3，future PR 闭环；spec §F1 字面 "M0.3 所有类型" 的 multi-file split over-claim 由 PR 9 governance §15.4 sign-off 阶段澄清。

**Architecture:** F1 作为 Wave 0 第二次模块化整理（与 C1 三件拆分类似的"模块边界"动作）落到 `KlineTrainerContracts` target 内的 `Models/` 子目录。Models.swift 整体下移（不拆分内容、不动 Codable / Equatable / Sendable / CodingKeys 字面），新增 `Models/BinarySearch.swift` 提供一个最小 `partitioningIndex(where:)` 泛型扩展（`RandomAccessCollection`），由 Wave 1 C5 trade marker / Wave 1+ 任意 sorted-array 索引查找消费（spec §C5 / `KLineView+Markers.swift:15` 注释已留 hook 点："Wave 1 (C5): implement trade marker rendering with binary search index lookup"）。BinarySearch API 只交付**一个泛型方法 + Comparable 二合便利**，不引入 Swift Algorithms 三方依赖，保持 Wave 0 §15.2 依赖锁定边界。

**Tech Stack:** Swift 6.0（toolchain 6.3.1）+ SwiftPM intra-package（`KlineTrainerContracts` target，path `Sources/KlineTrainerContracts`，无需 Package.swift 改动—— SwiftPM 自动递归收集 `Sources/KlineTrainerContracts/**` 下所有 `.swift`）+ Swift Testing macros（`@Test` / `@Suite` / `#expect`）+ `import Foundation`。无新增依赖、无 `Package.swift` 改动、无新 SwiftPM target。

**Spec 锚点：**
- **主要 §五 F1**：`kline_trainer_modules_v1.4.md` **L811-815**（F1 数据模型模块 `Models/`；职责：承载 M0.3 所有类型；依赖：M0.3、M0.4；验收：Codable round-trip / Equatable / Reason 枚举 Error conformance）
- **次要 §十一 Wave 0 Checklist**：**L2184**（"`Models/` 所有类型 + 完整 CodingKeys + Codable round-trip 测试 + Sendable"——M0.3 已实现内容，本 PR 仅做物理路径整理与 sign-off ledger）
- **次要 §十三 不单独成模块决策**：**L2286**（"BinarySearch 扩展 ｜ 归 F1 通用工具区"——本 PR 落地此 utility）
- **次要 §15.1 编译验证 #6**：**L2453**（"§三 M0.3 KLineCandle `Codable` round-trip：snake_case JSON ↔ camelCase struct"——M0.3 ModelsTests 已覆盖，本 PR 在 acceptance 文档中显式 ledger #6 闸门关闭）

**v6 outline 对照：**
- **顺位 17 / "F1 薄 wrapper re-export 0.5d Wave 0 末尾，Wave 1 才用"**：scope 字面对齐，物理 wrapper 在 file path 层面（不是 SwiftPM target 层面：M0.3 类型已在 `KlineTrainerContracts` target；新增独立 target 仅 re-export 是 YAGNI 抽象，违反 CLAUDE.md §2 simplicity）。

**Scope 决策（关键）：**

| 候选项 | 本 PR F1 处理 | 理由 |
|---|---|---|
| Models.swift 物理迁移到 `Models/Models.swift` | ✅ 交付 | spec §F1 字面路径 `Models/`；与 Geometry/ Reducer/ Render/ Theme/ Persistence/ DownloadAcceptance/ PreviewFakes/ Settings/ TrainingEngine/ 现有 8 个子目录命名一致 |
| `Models/BinarySearch.swift` 通用工具 | ✅ 交付 | spec §十三 L2286 字面归属 F1；Wave 1 C5 已留 hook 点 |
| `Models.swift` 内部拆分（按类型分文件） | ❌ 不做 | "薄 wrapper" + planner packaging 硬规则；拆分 = 增项目；rationale 见下 |
| 新建独立 SwiftPM target `KlineTrainerModels` re-export | ❌ 不做 | YAGNI（所有 consumer 已 `import KlineTrainerContracts`）；违反 CLAUDE.md §2；Package.swift 改动是 trust-boundary（codeowners 守卫，触发额外 governance loop） |
| 改 Reason 枚举 Error conformance | ❌ 不做 | 已在 M0.4 落地（PR #15 之前）；本 PR 在 acceptance ledger 引用，不动代码 |
| 改 Sendable 标注 | ❌ 不做 | M0.3 字面全部已 `Sendable`（grep Models.swift 9 enum + 6 struct 全标 `Sendable`）；本 PR ledger 引用 |
| §15.1 #6 sign-off 仪式 | ✅ 验收文档 ledger | F1 名下唯一 §15.1 闸门项（#3 PR #51 闭、#1 PR #47、#2 PR #48、#4 PR #51）；本 PR 只交付**ledger**，三方签字 ceremony 留 PR 9 governance |
| Git tag `wave0-frozen-v1.4` | ❌ PR 9 governance scope | 不在本 PR；与 PR 8 同样的拆分逻辑 |

**Planner packaging hard rule 自查（memory `feedback_planner_packaging_bias`）：**

> 硬规则每 PR ≤3 子项 / ≤500 行 prod

本 PR 子项数（v2 post-codex-R1）：
1. **F1 模块物理迁移**：`Models.swift` → `Models/Models.swift`（0 行 prod content 改动——纯 `git mv` + 2 行 header 注释；SwiftPM 自动 pick up）
2. **BinarySearch 通用 utility**：`Models/BinarySearch.swift` impl + `Models/BinarySearchTests.swift` 15 @Test 跨 2 Suite（含 ArraySlice 非零起始 + 三插入点，codex R1 finding 3）
3. **F1 §15.1 #6 sign-off ledger + 验收 gap closure**：`ModelsTests.swift` 追加 `AdditionalCodableRoundTripTests` Suite **8 @Test**（3 struct: FeeSnapshot/DrawingAnchor/DrawingObject + 2 enum: PositionTier/DrawingToolType + 3 现有 ModelsTests gap 补齐: Period full round-trip / TrainingSetMeta full equality / TradeOperation full equality；codex R1 finding 1 + R2 finding 1 + R4 finding 1 + R5 finding 1）+ `docs/acceptance/2026-05-16-pr-f1-models-wrapper.md` 中文验收清单 + §15.1 #6 + §五 F1 4 条 ledger

= **3 子项**（精确符合上限；codex R1 finding 1 增量"Codable characterization"是 F1 验收 gap closure 范畴，与子项 3 合并不是新增第 4 子项）

预估 prod LOC（仅 BinarySearch.swift 是真新增；Models.swift 是 git mv 历史保留）：
- `Models/Models.swift`：223 行（M0.3 现有内容物理迁移，0 行 net 改动；含原 222 行 + 1 行 module header comment 调整）
- `Models/BinarySearch.swift`：~50 行（`partitioningIndex(where:)` ~15 行 + 2 个 Comparable 便利 ~25 行 + 文件 header / doc comment ~10 行）

= **~273 行 prod**（其中 ~250 行是物理迁移的已存在代码；**实际新增 ~50 行**——符合 ≤500 上限，远在 0.5d 工作量范围）

测试 LOC：
- `Tests/KlineTrainerContractsTests/Models/BinarySearchTests.swift`：~250 行（15 @Test 跨 2 Suite：PartitioningIndex 7 @Test 含 ArraySlice 非零起始 + ComparableBound 8 @Test 含 lowerBound/upperBound 三插入点 below-min/between/above-max；codex R1 finding 3 修订）
- `Tests/KlineTrainerContractsTests/ModelsTests.swift` **追加** `AdditionalCodableRoundTripTests` Suite ~140 行（8 @Test：3 struct (FeeSnapshot/DrawingAnchor/DrawingObject) + 2 enum (PositionTier/DrawingToolType) + 2 现有 gap 补齐 (TrainingSetMeta/TradeOperation full equality)；codex R1 finding 1 + R2 finding 1 + R4 finding 1 修：关闭 F1 验收 gap）

= **~390 行测试**（23 @Test 新增）

**完成后：** Wave 0 F1 模块化整理闭环；F1 §15.1 #6 sign-off ledger 落地，PR 9 governance §15.4 三方签字可在此 ledger 上勾票；Wave 1 C5 trade marker 真实现 + 任意 sorted-array index lookup 消费方有 BinarySearch utility 可用。下一锚 = **PR M0.5 doc**（v6 outline 顺位 16，doc-only）或 **PR 9 governance**（freeze ceremony + tag）—— 顺序由 user 选定。

---

## File Structure

| 文件 | 责任 | 状态 | 增量 LOC budget |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Models.swift` | M0.3 数据模型（9 enum + 7 struct = 16 类型） | **Delete (git mv)** | -222（净 0，整体迁移） |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 同上，物理路径整理到 `Models/` 子目录 | **Create (git mv)** | +223（内容字面不变；module header comment 单行更新引用 `§五 F1`） |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/BinarySearch.swift` | `RandomAccessCollection.partitioningIndex(where:)` 泛型扩展 + `Comparable.lowerBound(of:)` / `upperBound(of:)` 便利方法 | Create | ~50 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Models/BinarySearchTests.swift` | BinarySearch 15 @Test 跨 2 Suite（含 ArraySlice 非零起始 + 三插入点 below-min/between/above-max；codex R1 finding 3） | Create | ~250 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` | **追加** `AdditionalCodableRoundTripTests` Suite 8 @Test（3 struct + 2 enum + 3 现有 gap (Period/TrainingSetMeta/TradeOperation full equality)；codex R1 finding 1 + R2 finding 1 + R4 finding 1 + R5 finding 1 修：关闭 F1 验收 gap） | Modify (append only) | +~160 |
| `docs/acceptance/2026-05-16-pr-f1-models-wrapper.md` | 中文非-coder 验收清单（A 文件落地 / B 编译 / C 单元测试 / D §15.1 #6 sign-off ledger / E CI / F 文档） | Create | ≤95 |
| `docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md` | 本计划文件（codex 对抗性 review source-of-truth） | Create（本文件） | — |

**File rationale：**

- **`Models/` 子目录平行 8 个现有子目录**：grep 现状已确认 `Geometry/` `Reducer/` `Render/` `Theme/` `Persistence/` `DownloadAcceptance/` `PreviewFakes/` `Settings/` `TrainingEngine/` 都是子目录形式；`Models.swift` 是唯一仍在 Sources root 的扁平文件，物理迁移让 F1 与其他模块命名一致。
- **Tests/Models/ 子目录新建**：测试侧也对应 `Models/` 子目录布局；与 `Tests/.../Render/` `Tests/.../Settings/`（grep 已确认存在）平行。
- **不拆 Models.swift**：保留 222 行单文件结构是 spec §五 F1 的"一个模块一个文件"风格；拆分会扩大本 PR scope、动 git blame、增加 codex review 表面。
- **BinarySearch.swift 不放 Models.swift 内**：utility 与数据模型职责不同（§十三 也用"扩展"措辞），分文件让 grep / 模块组织更清晰。
- **不动 `Package.swift`**：SwiftPM target.path = `"Sources/KlineTrainerContracts"` 自动递归 collect 所有 `.swift`，新加子目录无需声明；测试同理（target.path = `"Tests/KlineTrainerContractsTests"`）。**关键：Package.swift 在 codeowners_required_globs 守卫范围内，不动 = 不触发额外 governance loop**。

**Working directory：** worktree，由 `superpowers:using-git-worktrees` 在执行阶段创建（不在 plan 阶段创建）。worktree path = `.worktrees/pr-f1-models-wrapper`（与现有 `.worktrees/pr7b3-deceleration-stop-integration/` 平行）。SwiftPM root: `<worktree>/ios/Contracts/`。计划文件本身 commit 进 PR scope（PR #49 教训：plan 文件漏 commit 触发 re-attest 循环）。

**Baseline：** PR #51 merged 后 origin/main = **274 tests in 60 suites / 0 failures / 0 warnings**（待 worktree 内 swift test 实跑确认）。PR F1 完成后预期：
- 新增 3 个 Suite：`PartitioningIndexTests`（7 @Test 含 ArraySlice）+ `ComparableBoundTests`（8 @Test 含 lowerBound/upperBound 三插入点）+ `AdditionalCodableRoundTripTests`（8 @Test：3 struct + 2 enum JSON round-trip + 3 现有 gap full equality (Period/TrainingSetMeta/TradeOperation)）
- 总数 ≈ 297 tests in 63 suites / 0 failures / 0 warnings（macOS host）
- `swift build` + macOS host `swift test` 全 GREEN
- iOS Catalyst build 不变（本 PR 不影响 UIKit shell）

---

## Spec Evidence Section（codex review 必读）

### §五 F1（modules_v1.4.md L811-815）

```
### F1 数据模型模块 `Models/`

- **职责**：承载 M0.3 所有类型（含 `Equatable / Codable / CodingKeys`）
- **依赖**：M0.3、M0.4（AppError）
- **验收**：Codable round-trip 测试（snake_case JSON ↔ camelCase struct）；
  所有类型 `Equatable`；Reason 枚举 `Error` conformance 编译通过
```

### §十一 Wave 0 Checklist 引用（modules_v1.4.md L2184）

```
- [ ] `Models/` 所有类型 + **完整 CodingKeys** + Codable round-trip 测试 + **Sendable**（v1.3）
```

### §十三 不单独成模块决策（modules_v1.4.md L2286）

```
| BinarySearch 扩展 | 归 F1 通用工具区 |
```

### §15.1 #6 编译验证（modules_v1.4.md L2453）

```
| 6 | §三 M0.3 KLineCandle | `Codable` round-trip：`snake_case` JSON ↔ `camelCase` struct |
```

### Wave 1 C5 hook 点引用（`KLineView+Markers.swift:15`）

```swift
// Wave 1 (C5): implement trade marker rendering with binary search index lookup
```

### 现状 grep 证据（worktree 创建后由 Task 1 复核）

- `Models.swift` 现有 222 行：9 enum（Period / TradeDirection / PositionTier / TrainingMode / DrawingToolType / DisplayMode / PanelId / SwipeDirection / PeriodDirection）+ **7 struct**（KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject / TradeMarker）= **共 16 类型**；全部标 `Sendable`；KLineCandle / TrainingSetMeta 有显式 snake_case CodingKeys；6 个 struct Codable（TradeMarker per spec M0.3 NOT Codable，运行期 UI overlay 专用）。
- `ModelsTests.swift` 现有 165 行 / 5 Suite / **13 @Test**（codex R2 grep 确认）：ContractVersion(1) + EnumRoundTrip(6) + TrainingSetMetaCodable(2) + KLineCandleCodable(2) + TradeOperationCodable(2)，§15.1 #6 KLineCandle snake_case round-trip 实质已通过；PositionTier/DrawingToolType 只检 rawValue 不是 JSON 路径（Task 2.7 补齐）。
- `KlineTrainerContracts` target.path = `"Sources/KlineTrainerContracts"`（Package.swift L18）→ SwiftPM 自动 pick up `Models/` 子目录。

---

## Tasks

### Task 0: Worktree 设置 + baseline 测试

**Files:**
- Create: `.worktrees/pr-f1-models-wrapper/`（git worktree）

- [ ] **Step 0.1: 用 using-git-worktrees skill 创建 worktree**

```bash
git worktree add -b pr-f1-models-wrapper .worktrees/pr-f1-models-wrapper main
cd .worktrees/pr-f1-models-wrapper
```

Expected: 新分支 `pr-f1-models-wrapper` 基于 main 创建；worktree 目录就位。

- [ ] **Step 0.2: 从主 checkout cp plan 文件进 worktree（PR #49 教训：避免 untracked 漏 commit）**

```bash
# 在 worktree 内执行
cp "/Users/maziming/Coding/Prj_Kline trainer/docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md" \
   docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md
test -f docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md && echo "PLAN FILE COPIED OK"
```

Expected: 输出 `PLAN FILE COPIED OK`。

- [ ] **Step 0.3: 跑 baseline swift test 锁基线**

```bash
cd ios/Contracts
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr-f1-baseline.log ); then
  echo "BASELINE FAIL — abort plan execution"
  exit 1
fi
tail -3 /tmp/pr-f1-baseline.log
```

Expected: 末尾出现 `Test run with 274 tests in 60 suites passed`（与 PR #51 baseline 一致；若实跑数不符以实跑为准并在 Task 4 acceptance 更新）。

- [ ] **Step 0.4: Commit Task 0 housekeeping**

```bash
cd ../..  # 回 worktree root
git add docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md
git commit -m "docs(PR F1): 计划文件（superpowers writing-plans）"
```

Expected: 1 file changed（本 plan 文件）。

---

### Task 1: Models.swift 物理迁移到 Models/Models.swift

**Files:**
- Delete: `ios/Contracts/Sources/KlineTrainerContracts/Models.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`

- [ ] **Step 1.1: grep 现状二次复核**

```bash
cd ios/Contracts
wc -l Sources/KlineTrainerContracts/Models.swift
grep -c "^public enum" Sources/KlineTrainerContracts/Models.swift
grep -c "^public struct" Sources/KlineTrainerContracts/Models.swift
ls Sources/KlineTrainerContracts/
```

Expected:
- `wc -l` ≈ `222 Sources/KlineTrainerContracts/Models.swift`
- `grep -c "^public enum"` = `9`（9 个 enum：Period / TradeDirection / PositionTier / TrainingMode / DrawingToolType / DisplayMode / PanelId / SwipeDirection / PeriodDirection）
- `grep -c "^public struct"` = `7`（7 个 struct：KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject / TradeMarker）
- 合计 16 类型（codex R1 finding 2 修订：之前 v1 错算成 17）
- `ls` 输出含 `Models.swift`（无 `Models/` 子目录）

- [ ] **Step 1.2: git mv 物理迁移**

```bash
mkdir -p Sources/KlineTrainerContracts/Models
git mv Sources/KlineTrainerContracts/Models.swift Sources/KlineTrainerContracts/Models/Models.swift
ls Sources/KlineTrainerContracts/Models/
```

Expected: `ls` 输出 `Models.swift`；git status 显示 `renamed: Sources/KlineTrainerContracts/Models.swift -> Sources/KlineTrainerContracts/Models/Models.swift`。

- [ ] **Step 1.3: 更新文件顶部 module header 注释（单行）**

`old_string`（Models/Models.swift 行 1-2）：

```swift
// Kline Trainer Swift Contracts — M0.3
// Spec: kline_trainer_modules_v1.4.md §M0.3
```

`new_string`：

```swift
// Kline Trainer Swift Contracts — F1 Models 模块（承载 M0.3 数据模型）
// Spec: kline_trainer_modules_v1.4.md §五 F1（L811-815） + §三 M0.3
```

注：除此 2 行 header 外，文件其余内容**字面不变**（每一行内容、每一个 enum case、每一个 struct field、每一个 CodingKey 保持 PR #51 main 字面一致）。

- [ ] **Step 1.4: 跑 swift build 验证 SwiftPM 自动 pick up 新子目录**

```bash
if ! ( set -o pipefail; swift build 2>&1 | tee /tmp/pr-f1-step1.4.log ); then
  echo "BUILD FAIL — abort"
  exit 1
fi
grep -c "error:" /tmp/pr-f1-step1.4.log
grep -c "warning:" /tmp/pr-f1-step1.4.log
tail -3 /tmp/pr-f1-step1.4.log
```

Expected:
- 末尾输出 `Build complete!`
- error 计数 = 0
- warning 计数 = 0

- [ ] **Step 1.5: 跑 baseline swift test 验证零行为漂移**

```bash
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr-f1-step1.5.log ); then
  echo "TEST FAIL — abort"
  exit 1
fi
tail -3 /tmp/pr-f1-step1.5.log
```

Expected: `Test run with 274 tests in 60 suites passed`（与 Task 0.3 baseline 数字一致）。

- [ ] **Step 1.6: Commit Task 1**

```bash
cd ../..  # 回 worktree root
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift
git status  # 应显示 rename
git commit -m "refactor(PR F1): Models.swift 迁移到 Models/ 子目录（spec §五 F1 路径）"
```

Expected: 1 file renamed，0 行 net content 改动（除 header 2 行字面更新）。

---

### Task 2: BinarySearch utility（TDD）

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Models/BinarySearchTests.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Models/BinarySearch.swift`

- [ ] **Step 2.1: 写失败测试 — BinarySearchTests.swift（全部 15 个 @Test，覆盖 codex R1 finding 3 修订）**

Create `ios/Contracts/Tests/KlineTrainerContractsTests/Models/BinarySearchTests.swift`：

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("BinarySearch.partitioningIndex generic")
struct PartitioningIndexTests {
    @Test func emptyCollection_returnsEndIndex() {
        let arr: [Int] = []
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == arr.endIndex)
        #expect(idx == 0)
    }

    @Test func singleElement_predicateAlwaysTrue_returnsStart() {
        let arr = [10]
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == 0)
    }

    @Test func singleElement_predicateAlwaysFalse_returnsEnd() {
        let arr = [10]
        let idx = arr.partitioningIndex { $0 >= 100 }
        #expect(idx == 1)
        #expect(idx == arr.endIndex)
    }

    @Test func multipleElements_partitionInMiddle() {
        // 升序：[1, 3, 5, 7, 9]；predicate "≥ 5" 在 index 2 翻转
        let arr = [1, 3, 5, 7, 9]
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == 2)
    }

    @Test func multipleElements_allTrue_returnsStart() {
        let arr = [10, 20, 30]
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == 0)
    }

    @Test func multipleElements_allFalse_returnsEnd() {
        let arr = [1, 2, 3]
        let idx = arr.partitioningIndex { $0 >= 100 }
        #expect(idx == 3)
    }

    /// codex R1 finding 3 修：消费方 C5 marker lookup 是 ArraySlice<KLineCandle>（非零起始）；
    /// 如果实现假设零起始 offset，本测试在 zero-based ArraySlice impl 上 fail。
    @Test func arraySlice_nonZeroStartIndex_returnsAbsoluteIndex() {
        let arr = [1, 3, 5, 7, 9, 11, 13]
        let slice = arr[2...5]  // [5, 7, 9, 11]，startIndex = 2，endIndex = 6
        // 在 slice 内找首个 ≥ 9 → absolute index = 4（arr[4] = 9）
        let idx = slice.partitioningIndex { $0 >= 9 }
        #expect(idx == 4)
        #expect(slice.startIndex == 2)
        // 全 false：absolute endIndex = 6
        let endIdx = slice.partitioningIndex { $0 >= 100 }
        #expect(endIdx == slice.endIndex)
        #expect(endIdx == 6)
    }
}

@Suite("BinarySearch.lowerBound / upperBound for Comparable")
struct ComparableBoundTests {
    @Test func lowerBound_exactMatch_returnsFirstOccurrence() {
        // 含重复：[1, 3, 5, 5, 5, 7]；lowerBound(5) = index 2（第一个 5）
        let arr = [1, 3, 5, 5, 5, 7]
        #expect(arr.lowerBound(of: 5) == 2)
    }

    @Test func upperBound_exactMatch_returnsAfterLastOccurrence() {
        // 同上数组；upperBound(5) = index 5（第一个 > 5 的位置）
        let arr = [1, 3, 5, 5, 5, 7]
        #expect(arr.upperBound(of: 5) == 5)
    }

    /// codex R1 finding 3：lowerBound 三个插入点 case（below-min / between / above-max）。
    @Test func lowerBound_belowMin_returnsStartIndex() {
        let arr = [10, 20, 30]
        #expect(arr.lowerBound(of: 5) == 0)
    }

    @Test func lowerBound_betweenValues_returnsInsertionPoint() {
        // [10, 20, 30]，找 15 的插入点 = index 1（首个 ≥ 15）
        let arr = [10, 20, 30]
        #expect(arr.lowerBound(of: 15) == 1)
    }

    @Test func lowerBound_aboveMax_returnsEndIndex() {
        let arr = [10, 20, 30]
        #expect(arr.lowerBound(of: 100) == 3)
        #expect(arr.lowerBound(of: 100) == arr.endIndex)
    }

    /// codex R1 finding 3：upperBound 三个插入点 case 对称覆盖。
    @Test func upperBound_belowMin_returnsStartIndex() {
        let arr = [10, 20, 30]
        #expect(arr.upperBound(of: 5) == 0)
    }

    @Test func upperBound_betweenValues_returnsInsertionPoint() {
        let arr = [10, 20, 30]
        // upperBound(15) = 首个 > 15 = index 1（20）
        #expect(arr.upperBound(of: 15) == 1)
    }

    @Test func upperBound_aboveMax_returnsEndIndex() {
        let arr = [10, 20, 30]
        #expect(arr.upperBound(of: 100) == 3)
        #expect(arr.upperBound(of: 100) == arr.endIndex)
    }
}
```

注意：
- 测试**必须**在 `Models/` 子目录创建（与 prod 平行）；Tests target.path = `"Tests/KlineTrainerContractsTests"` 自动 pick up（SwiftPM）。
- **API 返回 collection index（不是 relative offset）**——`partitioningIndex` 对 ArraySlice 返回 absolute index（即 `slice.startIndex + relativeOffset`），由 `Index = Self.Index` 保证。codex R1 finding 3 显式覆盖此契约。
- 总 @Test：`PartitioningIndexTests` 7 + `ComparableBoundTests` 8 = **15 个 BinarySearch**；新增 Codable round-trip 8 个（见 Step 2.7：3 struct + 2 enum + 3 现有 gap (Period/TrainingSetMeta/TradeOperation)）→ 本 PR 总新增 = **23 @Test**。

- [ ] **Step 2.2: 跑测试验证 FAIL（无 impl）**

```bash
cd ios/Contracts
if ( set -o pipefail; swift test 2>&1 | tee /tmp/pr-f1-step2.2.log ); then
  echo "UNEXPECTED PASS — abort (TDD red phase expected)"
  exit 1
fi
grep -c "value of type.*has no member.*partitioningIndex" /tmp/pr-f1-step2.2.log
grep -c "value of type.*has no member.*lowerBound\|value of type.*has no member.*upperBound" /tmp/pr-f1-step2.2.log
```

Expected:
- swift test 编译失败（exit non-zero）
- grep 命中 `partitioningIndex` 不存在错误 ≥ 1
- grep 命中 `lowerBound` / `upperBound` 不存在错误 ≥ 1

（理由：standard library 没有 `partitioningIndex` 公开方法；`Array.lowerBound(of:)` 不存在；编译期 fail）

- [ ] **Step 2.3: 写最小实现 — BinarySearch.swift**

Create `ios/Contracts/Sources/KlineTrainerContracts/Models/BinarySearch.swift`：

```swift
// Kline Trainer Swift Contracts — F1 Models 通用工具区
// Spec: kline_trainer_modules_v1.4.md §十三（L2286）"BinarySearch 扩展 归 F1 通用工具区"
// 消费方：Wave 1 C5 trade marker index lookup（KLineView+Markers.swift:15 hook 点）

import Foundation

extension RandomAccessCollection {
    /// 二分查找分区点：返回首个使 `predicate` 为 `true` 的 index；若无则返回 `endIndex`。
    ///
    /// **前置约束**：`predicate` 必须在 self 上 **monotonic**（所有 false 在所有 true 之前）；
    /// 否则结果未定义。调用方负责传入单调谓词（典型：`{ $0 >= target }`）。
    ///
    /// 复杂度：O(log n)。
    public func partitioningIndex(
        where predicate: (Element) throws -> Bool
    ) rethrows -> Index {
        var lo = startIndex
        var hi = endIndex
        while lo < hi {
            let mid = index(lo, offsetBy: distance(from: lo, to: hi) / 2)
            if try predicate(self[mid]) {
                hi = mid
            } else {
                lo = index(after: mid)
            }
        }
        return lo
    }
}

extension RandomAccessCollection where Element: Comparable {
    /// 首个使 `self[i] >= value` 的 index；若全 `< value` 返回 `endIndex`。
    /// 复杂度：O(log n)。要求 self 升序。
    public func lowerBound(of value: Element) -> Index {
        partitioningIndex { $0 >= value }
    }

    /// 首个使 `self[i] > value` 的 index；若全 `≤ value` 返回 `endIndex`。
    /// 复杂度：O(log n)。要求 self 升序。
    public func upperBound(of value: Element) -> Index {
        partitioningIndex { $0 > value }
    }
}
```

- [ ] **Step 2.4: 跑测试验证 GREEN**

```bash
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr-f1-step2.4.log ); then
  echo "TEST FAIL"
  exit 1
fi
tail -3 /tmp/pr-f1-step2.4.log
grep "PartitioningIndexTests\|ComparableBoundTests" /tmp/pr-f1-step2.4.log | head -10
```

Expected:
- 末尾 `Test run with 289 tests in 62 suites passed`（274 baseline + 15 BinarySearch @Test 跨 2 Suite；Codable Suite 在 Step 2.7 才加）
- grep `PartitioningIndexTests` + `ComparableBoundTests` 两 Suite 名都出现

- [ ] **Step 2.5: 检查 Sendable / 并发警告**

```bash
if ! ( set -o pipefail; swift build -Xswiftc -strict-concurrency=complete 2>&1 | tee /tmp/pr-f1-step2.5.log ); then
  echo "STRICT CONCURRENCY FAIL"
  exit 1
fi
grep "warning:" /tmp/pr-f1-step2.5.log | wc -l
```

Expected: warning 计数 = 0（`partitioningIndex` 是 generic 扩展无状态；不引入 Sendable 漂移）。

- [ ] **Step 2.6: Commit Task 2a (BinarySearch utility + tests)**

```bash
cd ../..
git add ios/Contracts/Sources/KlineTrainerContracts/Models/BinarySearch.swift
git add ios/Contracts/Tests/KlineTrainerContractsTests/Models/BinarySearchTests.swift
git commit -m "feat(PR F1): BinarySearch.partitioningIndex / lowerBound / upperBound（§十三 F1 通用工具区）"
```

Expected: 2 file changed，+~250 行（impl ~50 + tests ~200，含 codex R1 finding 3 修订新增 7 @Test）。

---

- [ ] **Step 2.7: 补 8 个 Codable round-trip @Test（codex R1 finding 1 + R2 finding 1 + R4 finding 1 + R5 finding 1 修：F1 验收 gap 真闭环）**

**F1 Codable 类型 inventory（grep 已确认；codex R5 finding 1 修订）：**
- **6 Codable struct**：KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject（TradeMarker per spec M0.3 NOT Codable，运行期 UI overlay）
- **5 Codable enum**：Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode（TrainingMode / PanelId / SwipeDirection / PeriodDirection 非 Codable）
- **现有 ModelsTests "真 round-trip + equality" 覆盖（3/11 闭环）**：TradeDirection（`tradeDirection_roundTrip` 同测试 encode→decode→equality）、DisplayMode（`displayMode_allCasesCodable` for-loop encode→decode→equality）、KLineCandle（`roundTrip_withOptionalNils` 完整 equality）
- **gap（8/11 未闭环，本 Step 全补）**：
  1. Period — 现有 `period_encodesToRawString` 只 encode .m60 检字符串；`period_decodesFromRawString` 只 decode "3m" 检 .m3；**两个测试分离，无 feed encoder→decoder + equality 完整链**（codex R5 finding 1）
  2. TrainingSetMeta — 现有 `snakeCaseCodingKeys` 只 encode 检字段名；`decodesFromSnakeCaseJSON` 只 decode 检 stockCode/startDatetime 两字段，**无 full equality**
  3. TradeOperation — 现有 `positionTier_encodesAsRawValue` 只 decode 后检 positionTier 一字段；`defaultEncoding_isCamelCase_notSnakeCase` 只 encode 检字段名，**无 full equality**
  4. FeeSnapshot — 零 JSON round-trip
  5. DrawingAnchor — 零 JSON round-trip
  6. DrawingObject — 零 JSON round-trip
  7. PositionTier — 只检 rawValue（`positionTier_rawValuesAreFractions`），非 JSON 路径
  8. DrawingToolType — 只检 init(rawValue:)（`drawingToolType_allSevenCases`），非 JSON 路径

在 `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift` **文件末尾**追加新 Suite（不动现有 5 个 Suite）：

```swift
/// codex R1+R2+R4+R5+R7 findings 修：F1 PR scope narrow 到 Models.swift 内 11 个 Codable 类型
/// （codex R7 finding 1：AppState.swift 内 3 个 M0.3 Codable struct 在 H3 residual queue，未来 PR 闭环）。
/// 本 PR Models.swift inventory 的 ModelsTests 留下 8 个 gap：3 个 struct
/// (FeeSnapshot/DrawingAnchor/DrawingObject) 零覆盖 + 2 个 enum (PositionTier/DrawingToolType) 只检
/// rawValue + 3 个现有 gap (Period 分离 encode/decode 测试无完整链 / TrainingSetMeta 无 full equality /
/// TradeOperation 无 full equality)。本 Suite 把这 8 个 gap 闭环（characterization，非 TDD red→green；
/// M0.3 已实现 Codable）。
@Suite("Additional Codable round-trip (F1 verification gap closure)")
struct AdditionalCodableRoundTripTests {
    // —— 3 Struct round-trip（codex R1 finding 1）——

    @Test func feeSnapshot_roundTrip() throws {
        let original = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeeSnapshot.self, from: data)
        #expect(decoded == original)
        // 默认 Codable：camelCase 字段
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"commissionRate\":0.0001"))
        #expect(json.contains("\"minCommissionEnabled\":true"))
    }

    @Test func drawingAnchor_roundTrip() throws {
        let original = DrawingAnchor(period: .daily, candleIndex: 42, price: 123.45)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DrawingAnchor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.period == .daily)
        #expect(decoded.candleIndex == 42)
        #expect(decoded.price == 123.45)
    }

    @Test func drawingObject_roundTripWithMultipleAnchors() throws {
        let original = DrawingObject(
            toolType: .trend,
            anchors: [
                DrawingAnchor(period: .m15, candleIndex: 0, price: 10.0),
                DrawingAnchor(period: .m15, candleIndex: 5, price: 12.5)
            ],
            isExtended: true,
            panelPosition: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(decoded == original)
        #expect(decoded.toolType == .trend)
        #expect(decoded.anchors.count == 2)
        #expect(decoded.isExtended == true)
        #expect(decoded.panelPosition == 1)
    }

    // —— 2 Enum 真 JSON round-trip（codex R2 finding 1）——
    // 现有 ModelsTests.PositionTierTests 只检 rawValue，DrawingToolTypeTests 只检 init(rawValue:)；
    // 都不是 JSONEncoder/Decoder 路径。本 2 @Test 把 JSON round-trip 真覆盖关闭。

    @Test func positionTier_jsonRoundTrip_encodesAsRawValueString() throws {
        for tier in PositionTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(PositionTier.self, from: data)
            #expect(decoded == tier)
            // codex R6 finding 2 修：用 semantic decode-string 比较（不依赖 JSON 字节
            // formatting；JSONEncoder 默认对 `/` escape 为 `\/`，PositionTier rawValue
            // "1/5"-"5/5" 含 `/` 字符）
            let decodedRaw = try JSONDecoder().decode(String.self, from: data)
            #expect(decodedRaw == tier.rawValue)  // 如 "3/5"
        }
    }

    @Test func drawingToolType_jsonRoundTrip_allSevenCases() throws {
        let all: [DrawingToolType] = [.ray, .trend, .horizontal, .golden, .wave, .cycle, .time]
        for tool in all {
            let data = try JSONEncoder().encode(tool)
            let decoded = try JSONDecoder().decode(DrawingToolType.self, from: data)
            #expect(decoded == tool)
            // codex R6 finding 2 同模式：semantic decode-string（DrawingToolType raw 不含
            // `/`，但保持 inventory 一致风格 + 防御 future raw value 改动）
            let decodedRaw = try JSONDecoder().decode(String.self, from: data)
            #expect(decodedRaw == tool.rawValue)
        }
    }

    // —— 3 现有 ModelsTests gap 闭环（codex R4 finding 1 + R5 finding 1）——
    // 现有 EnumRoundTripTests.period_* / TrainingSetMetaTests / TradeOperationTests 缺真 round-trip
    // 完整链；本 3 @Test 加 full JSONEncoder→JSONDecoder + equality，把 F1 验收"所有 Codable 类型
    // round-trip"真闭环。

    @Test func period_jsonRoundTrip_allCases() throws {
        // codex R5 finding 1：现有 period_encodesToRawString / period_decodesFromRawString
        // 是分离两个测试（encode .m60 → "60m" / decode "3m" → .m3），无完整 round-trip + equality 链。
        for period in Period.allCases {
            let data = try JSONEncoder().encode(period)
            let decoded = try JSONDecoder().decode(Period.self, from: data)
            #expect(decoded == period)
            // codex R6 finding 2 同模式：semantic decode-string（Period raw 不含 `/`，但风格
            // 一致 + 防御 future raw value 改动）
            let decodedRaw = try JSONDecoder().decode(String.self, from: data)
            #expect(decodedRaw == period.rawValue)
        }
    }

    @Test func trainingSetMeta_fullRoundTrip_equality() throws {
        let original = TrainingSetMeta(
            stockCode: "600519",
            stockName: "贵州茅台",
            startDatetime: 1_700_000_000,
            endDatetime: 1_710_000_000
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrainingSetMeta.self, from: data)
        #expect(decoded == original)
        // 防呆：每个字段都得对得上（不只是 == 自动合成漏字段就 false-positive）
        #expect(decoded.stockCode == "600519")
        #expect(decoded.stockName == "贵州茅台")
        #expect(decoded.startDatetime == 1_700_000_000)
        #expect(decoded.endDatetime == 1_710_000_000)
    }

    @Test func tradeOperation_fullRoundTrip_equality() throws {
        let original = TradeOperation(
            globalTick: 100,
            period: .m15,
            direction: .buy,
            price: 12.34,
            shares: 200,
            positionTier: .tier3,
            commission: 1.23,
            stampDuty: 0.5,
            totalCost: 2470.73,
            createdAt: 1_700_000_000
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TradeOperation.self, from: data)
        #expect(decoded == original)
        // 防呆：10 个字段全检
        #expect(decoded.globalTick == 100)
        #expect(decoded.period == .m15)
        #expect(decoded.direction == .buy)
        #expect(decoded.price == 12.34)
        #expect(decoded.shares == 200)
        #expect(decoded.positionTier == .tier3)
        #expect(decoded.commission == 1.23)
        #expect(decoded.stampDuty == 0.5)
        #expect(decoded.totalCost == 2470.73)
        #expect(decoded.createdAt == 1_700_000_000)
    }
}
```

注意：
- 不动 `ModelsTests.swift` 现有 5 Suite（surgical）；只追加 1 个 Suite + **8 @Test**。
- **不是 TDD red→green**：这 8 个类型 M0.3 已实现 Codable，本 Step 是 characterization 关闭 F1 验收 gap。如果 round-trip 失败 → M0.3 reopen（不在本 PR scope，但本 PR 把 gap 暴露给 reviewer）。
- TradeMarker 不在本 Suite：spec M0.3 明文 "TradeMarker: UI overlay; NOT Codable per spec M0.3 — runtime only"（Models.swift L210 注释也字面对齐）；Codable round-trip 不适用。
- 非 Codable enum (TrainingMode / PanelId / SwipeDirection / PeriodDirection) 不在 round-trip 范围：它们 spec 不要求 Codable conformance。

- [ ] **Step 2.8: 跑全包 swift test 验证 23 个新 @Test 全 GREEN**（15 BinarySearch + 8 Codable round-trip）

```bash
cd ios/Contracts
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr-f1-step2.8.log ); then
  echo "TEST FAIL"
  exit 1
fi
tail -5 /tmp/pr-f1-step2.8.log
grep "AdditionalCodableRoundTripTests\|PartitioningIndexTests\|ComparableBoundTests" /tmp/pr-f1-step2.8.log | head -10
```

Expected:
- 末尾 `Test run with 297 tests in 63 suites passed`（274 baseline + 15 BinarySearch + 8 Codable = 23 新增；60 baseline + 3 新 Suite = 63 suites）
- grep 命中三个 Suite 名（`PartitioningIndexTests` + `ComparableBoundTests` + `AdditionalCodableRoundTripTests`）

- [ ] **Step 2.9: Commit Task 2b (Codable characterization)**

```bash
cd ../..
git add ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
git commit -m "test(PR F1): FeeSnapshot/DrawingAnchor/DrawingObject Codable round-trip characterization（codex R1 finding 1 修：关闭 F1 验收 gap）"
```

Expected: 1 file changed, +~50 行 test。

---

### Task 3: 验收文档 + §15.1 #6 sign-off ledger

**Files:**
- Create: `docs/acceptance/2026-05-16-pr-f1-models-wrapper.md`

- [ ] **Step 3.1: 写验收清单**

Create `docs/acceptance/2026-05-16-pr-f1-models-wrapper.md`：

````markdown
# PR F1 验收清单 — Models 薄 wrapper（BinarySearch + 目录整理 + §15.1 #6 sign-off）

> 这份清单给非-coder 用户用：复制每一行"action"到 Claude Code 或 Terminal，对照"expected"判断 pass / fail。

## A. 文件落地

| # | action | expected | pass_fail |
|---|---|---|---|
| A1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Models/` | 看到 2 个文件：Models.swift / BinarySearch.swift | ☐ |
| A2 | `ls ios/Contracts/Sources/KlineTrainerContracts/Models.swift 2>&1` | 输出含 `No such file or directory`（旧路径已被 git mv 删除） | ☐ |
| A3 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/Models/` | 看到 1 个文件：BinarySearchTests.swift | ☐ |
| A4 | `wc -l ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | ≈ 223（M0.3 内容字面保留 + 2 行 header 更新） | ☐ |

## B. 编译验证

| # | action | expected | pass_fail |
|---|---|---|---|
| B1 | `cd ios/Contracts && swift build` | 输出 `Build complete!`，无 error 无 warning | ☐ |
| B2 | `cd ios/Contracts && if ! ( set -o pipefail; swift test 2>&1 \| tee /tmp/pr-f1-b2.log ); then echo FAIL; else tail -5 /tmp/pr-f1-b2.log; fi` | 末尾出现 `Test run with N tests in M suites passed`，**N = 297**（274 baseline + 15 BinarySearch + 8 Codable round-trip = 23 新增）、**M = 63**（60 + 3 新 Suite：`PartitioningIndexTests` + `ComparableBoundTests` + `AdditionalCodableRoundTripTests`）；**未** 出现 `FAIL` 字样 | ☐ |
| B3 | `cd ios/Contracts && swift build -Xswiftc -strict-concurrency=complete 2>&1 \| grep -c "warning:"` | 输出 `0`（严格并发检查无警告） | ☐ |

## C. 单元测试覆盖（共 23 个新 @Test：BinarySearch 15 + Codable round-trip 8）

| # | action | expected | pass_fail |
|---|---|---|---|
| C1 | `swift test --filter PartitioningIndexTests 2>&1 \| grep "passed\|failed" \| tail -3` | 显示 `PartitioningIndexTests` **7 个** @Test（含 `arraySlice_nonZeroStartIndex_returnsAbsoluteIndex`）全部 passed | ☐ |
| C2 | `swift test --filter ComparableBoundTests 2>&1 \| grep "passed\|failed" \| tail -3` | 显示 `ComparableBoundTests` **8 个** @Test（含 `lowerBound_betweenValues_returnsInsertionPoint` / `upperBound_aboveMax_returnsEndIndex` 等三插入点）全部 passed | ☐ |
| C3 | `swift test --filter AdditionalCodableRoundTripTests 2>&1 \| grep "passed\|failed" \| tail -3` | 显示 `AdditionalCodableRoundTripTests` **8 个** @Test（3 struct + 2 enum + 3 现有 gap full equality：Period / TrainingSetMeta / TradeOperation）全部 passed | ☐ |

## D. §15.1 #6 sign-off ledger（F1 名下唯一 §15.1 闸门项）

| # | spec 闸门 | F1 名下交付物 | 验证证据 | 闸门状态 |
|---|---|---|---|---|
| D1 | §15.1 #6 "M0.3 KLineCandle Codable round-trip：snake_case JSON ↔ camelCase struct" | `Models/Models.swift` KLineCandle 显式 snake_case CodingKeys + `ModelsTests.swift` `KLineCandleTests.snakeCaseCodingKeys_forBollAndMacdAndIndex` + `.roundTrip_withOptionalNils` | M0.3 PR (历史) ModelsTests GREEN + 本 PR baseline swift test GREEN | ✅ **闭合**（本 PR ledger，等待 PR 9 §15.4 三方签字） |
| D2 | F1 验收 "所有类型 Equatable" | Models.swift 全 16 类型（9 enum + 7 struct）`Equatable` 自动合成（M0.3 已落地） | grep `Equatable` 行数 ≥ 16（codex R1 finding 2 修订：之前 v1 错算 17） | ✅ **闭合** |
| D3 | F1 验收 "Reason 枚举 Error conformance 编译通过" | `AppError.swift` 全 Reason 枚举 `: Error, Sendable`（M0.4 PR #15 落地） | M0.4 PR 验收文档 + 当前编译 GREEN | ✅ **闭合**（M0.4 名下交付，F1 引用） |
| D4 | F1 验收 "Codable round-trip 测试（含 §15.1 #6 KLineCandle snake_case JSON↔camelCase struct）" — **scope narrow 到 Models.swift 内的 Codable 实体**（codex R7 finding 1 修订；AppState.swift 的 M0.3 Codable struct 进 residual H3） | **`Models.swift` 内 11 个 Codable 类型 inventory**：6 struct（KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject）+ 5 enum（Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode）。**M0.3 既有真 round-trip + equality 覆盖 3 / 11**：TradeDirection（`tradeDirection_roundTrip`）、DisplayMode（`displayMode_allCasesCodable`）、KLineCandle（`roundTrip_withOptionalNils`）。**8 / 11 既有部分覆盖但非真 round-trip**：Period（分离 encode/decode）、TrainingSetMeta（无 full equality）、TradeOperation（仅 positionTier 单字段）、PositionTier（仅 rawValue）、DrawingToolType（仅 init(rawValue:)）、FeeSnapshot / DrawingAnchor / DrawingObject（零覆盖）。**本 PR Task 2.7 新增 `AdditionalCodableRoundTripTests` 8 @Test 补 gap**（codex R1+R2+R4+R5+R6 累积修）：feeSnapshot_roundTrip / drawingAnchor_roundTrip / drawingObject_roundTripWithMultipleAnchors / positionTier_jsonRoundTrip_encodesAsRawValueString / drawingToolType_jsonRoundTrip_allSevenCases / period_jsonRoundTrip_allCases / trainingSetMeta_fullRoundTrip_equality / tradeOperation_fullRoundTrip_equality。TradeMarker per spec M0.3 NOT Codable，runtime UI overlay 不适用 | swift test GREEN（`Models.swift` 11/11 Codable 类型 真 JSONEncoder→JSONDecoder + equality round-trip 闭环：3 现有 + 8 新增） | ✅ **闭合（Models.swift scope）** |

**结论**：F1 模块 §15.1 #6 + §五 验收 4 条全部 ledger 闭合；本 PR 不重新交付 M0.3 / M0.4 的代码（surgical），只在 ledger 引用 + 路径整理 + 新增 BinarySearch utility。PR 9 governance §15.4 三方签字时，iOS 代表可在此 ledger 上勾票。

## E. Scope 边界（不应做的事）

| # | action | expected | pass_fail |
|---|---|---|---|
| E1 | `git diff main -- ios/Contracts/Package.swift` | 输出为空（不动 Package.swift） | ☐ |
| E2 | `git diff main -- ios/Contracts/Sources/KlineTrainerContracts/AppError.swift` | 输出为空（不动 M0.4 AppError） | ☐ |
| E3 | `git diff main -- ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` 净内容 | 只有 header 2 行更新（spec 引用从 §M0.3 改为 §五 F1 + §三 M0.3）；其他行字面与 PR #51 main `Models.swift` 一致 | ☐ |
| E4 | `git diff main -- ios/KlineTrainer/` | 输出为空（不动 Xcode app 工程） | ☐ |

## F. CI（GitHub Actions）

| # | action | expected | pass_fail |
|---|---|---|---|
| F1 | `gh pr checks <pr_number>` | 6/6 checks SUCCESS（或 OpenAI quota fail 走 admin bypass，按 memory `feedback_openai_quota_ci_pattern`） | ☐ |

## G. 文档

| # | action | expected | pass_fail |
|---|---|---|---|
| G1 | `ls docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md` | 文件存在 | ☐ |
| G2 | `ls docs/acceptance/2026-05-16-pr-f1-models-wrapper.md` | 文件存在（本文件） | ☐ |
| G3 | `grep -c "BinarySearch\|partitioningIndex" docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md` | ≥ 10（plan 文档充分引用 utility API） | ☐ |

## H. 已知 plan-residual（**不阻塞本 PR merge**，PR 9 governance 前不需 close）

| # | residual | 阻塞 | 解决路径 |
|---|---|---|---|
| H1 | BinarySearch 实际消费方（C5 trade marker）未落地 | none | Wave 1 C5 PR 时按 `KLineView+Markers.swift:15` hook 点接入 |
| H2 | §15.4 三方签字 + tag `wave0-frozen-v1.4` | none（不在本 PR scope） | PR 9 governance scope |
| H3 | **M0.3 spec scope 跨多文件、本 PR F1 只闭 Models.swift slice**（codex R7 + R8 累积）；以下文件中的 M0.3 Codable 实体未在本 PR ledger 闭环：(a) `AppState.swift` 3 struct: TrainingRecord / DrawdownAccumulator / PendingTraining（PR #47 落地 C1b 时引入，Codable Sendable Equatable）；(b) `RESTDTOs.swift` 2 struct: LeaseResponse / TrainingSetMetaItem（M0.3 REST 边界 DTO，Codable Sendable）；未来 grep 验全 M0.3 文件可能再发现 | none（F1 scope narrow 到 Models.swift only；spec §F1 字面 "M0.3 所有类型" 与 M0.3 实际跨 Models.swift + AppState.swift + RESTDTOs.swift 多文件之间的 over-claim 是 spec drift） | (1) future PR（C1b/REST owner）补 round-trip @Test for 各文件的 M0.3 Codable struct；(2) spec §F1 "Models/ 承载 M0.3 所有类型" 字面 vs 实际多文件 split 由 PR 9 governance §15.4 sign-off 阶段澄清（spec 修订 OR 接受 multi-file = M0.3 scope） |
````

- [ ] **Step 3.2: 跑 acceptance 文档自检**

```bash
wc -l docs/acceptance/2026-05-16-pr-f1-models-wrapper.md
grep -c "^| " docs/acceptance/2026-05-16-pr-f1-models-wrapper.md
grep -c "pass_fail\|闸门状态" docs/acceptance/2026-05-16-pr-f1-models-wrapper.md
```

Expected:
- `wc -l` ≤ 95（符合 acceptance 长度上限）
- table 行数 ≥ 15（A1-A4 + B1-B3 + C1-C2 + D1-D4 + E1-E4 + F1 + G1-G3 + H1-H2）
- 含 pass_fail / 闸门状态 标记

- [ ] **Step 3.3: Commit Task 3**

```bash
git add docs/acceptance/2026-05-16-pr-f1-models-wrapper.md
git commit -m "docs(PR F1): 中文非-coder 验收清单 + §15.1 #6 sign-off ledger"
```

Expected: 1 file changed。

---

### Task 4: Final verification + sign-off

**Files:** （无 code 改动，验证 + 签字）

- [ ] **Step 4.1: 整体回归测试**

```bash
cd ios/Contracts
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr-f1-final.log ); then
  echo "FINAL TEST FAIL"
  exit 1
fi
tail -5 /tmp/pr-f1-final.log
```

Expected: `Test run with 297 tests in 63 suites passed`。

- [ ] **Step 4.2: branch-diff 自审 — surgical 边界**

```bash
cd ../..
git diff main --stat
git log main..HEAD --oneline
```

Expected:
- 改动文件：6 个（rename Models.swift + BinarySearch.swift + BinarySearchTests.swift + ModelsTests.swift modify + plan.md + acceptance.md）
- commit 数：6 个（Task 0 plan / Task 1 mv / Task 2a BinarySearch / Task 2b Codable characterization / Task 3 acceptance / Task 4.3 acceptance ☑ ledger）

- [ ] **Step 4.3: 任务清单 ✓ 全勾**（acceptance §A-G 全 ☐ → ☑）

人工核对：把 `docs/acceptance/2026-05-16-pr-f1-models-wrapper.md` 的 A1-G3 跑一遍，每条 pass_fail 列改为 ☑。Commit 验收 ledger 落地：

```bash
git add docs/acceptance/2026-05-16-pr-f1-models-wrapper.md
git commit -m "docs(PR F1): 验收清单 A-G 全部 ☑（local 验证完成）"
```

- [ ] **Step 4.4: requesting-code-review skill 自审**

调用 `superpowers:requesting-code-review` 走一遍 final diff（branch vs main）。

预期输出：
- 0 critical / 0 high finding
- ≤ 3 medium/low（如 doc wording / commit message tweaks）

如果有 high+ finding → 回 Task 1-3 修。

- [ ] **Step 4.5: codex 对抗性 review（impl 阶段）**

走 `codex:adversarial-review` 对 branch diff（main..HEAD）。

收敛规则（memory `feedback_codex_round6_self_contradiction` + `feedback_codex_plan_budget_overshoot`）：
- 5 轮内必收敛 / 全修真 finding
- 第 6 轮自相矛盾或复述已 accept residual → user TTY override
- 第 ≥ 4 轮命中"复述同条 finding"模式 → 升 user 决议

---

## Self-Review（writing-plans skill 内置 checklist）

**1. Spec coverage**：

- ✅ §五 F1 验收 4 条 → Task 3 §D ledger 全覆盖
- ✅ §十一 L2184 "Models/ + 完整 CodingKeys + Codable round-trip + Sendable" → Task 1（路径）+ Task 3 §D（ledger）
- ✅ §十三 L2286 "BinarySearch 扩展 归 F1 通用工具区" → Task 2 新增 utility
- ✅ §15.1 #6 KLineCandle Codable round-trip → Task 3 §D1 ledger
- ✅ Wave 1 C5 hook 点 `KLineView+Markers.swift:15` → Task 2 文件 header 引用

**2. Placeholder scan**：

- 全文 grep "TBD\|TODO\|implement later\|fill in details\|Add appropriate\|Similar to Task" → 0 命中
- 每个 Step 含具体 bash / Swift 代码 ✓
- BinarySearch 完整实现代码在 Step 2.3 字面给出 ✓
- 测试 15 个 BinarySearch @Test 在 Step 2.1 + 8 个 Codable round-trip @Test 在 Step 2.7 字面给出（v6 codex R5 修订后） ✓

**3. Type consistency**：

- `partitioningIndex(where:)` 签名在 Step 2.1 测试调用与 Step 2.3 实现一致 ✓
- `lowerBound(of:)` / `upperBound(of:)` 签名一致 ✓
- Index 类型 = `Self.Index`（RandomAccessCollection），测试用 `Array<Int>` 即 `Int`，行为正确 ✓
- 文件路径 `Models/Models.swift` 在 Task 1 / Task 3 / Step 4.2 一致 ✓

✅ Self-review 通过。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md`.**

按 user 指定的 superpowers 流水线，下一步：

1. **Codex 对抗性 review plan**（codex:adversarial-review，本 plan 阶段）→ 收敛到 APPROVE
2. **subagent-driven-development 实施**（4 个 Task × fresh sonnet 4.6 high-effort subagent + 主线 two-stage review）
3. **verification-before-completion** + **requesting-code-review** + **codex:adversarial-review（impl 阶段）** → 全部 APPROVE
4. **Commit + push + PR**（commit-commands:commit-push-pr，中文 title/body + acceptance link）
