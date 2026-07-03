# 复盘重设计 · 真机整改增补 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** 修复复盘重设计真机实测暴露的 4 处问题：④画线按"创建时刻"渐显、③划线可画双面板、②快进按钮样式统一、①DEBUG fixture 一致性。

**Architecture:** 给 `DrawingObject` 加 `revealTick`（创建时全局 tick），渐显改为 `revealTick <= tick`，提交在 `routeDrawingCommit` 盖戳；划线钮改用 `activePanel`；`ReviewControlBar` 按钮统一样式；`DebugFixtureData` 的 pending/交易挪进复盘窗口内。

**Tech Stack:** Swift 6 / SwiftUI / GRDB；平台无关核心 host `swift test` + `#if canImport(UIKit)` SwiftUI 薄壳走 Mac Catalyst `build-for-testing`。

**权威 spec:** `docs/superpowers/specs/2026-07-02-review-redesign-refinements-design.md`

## Global Constraints
- `CONTRACT_VERSION` `"1.9" → "1.10"`（`Models.swift`；纯标记，不持久化、不与 DB 门控）。
- **迁移 0008**：`drawings` 表加 `reveal_tick INTEGER NOT NULL DEFAULT 0`，`PRAGMA user_version = 6`（规范化的训练记录画线路径必需，见 Task 2）。JSON-blob 路径（review_archive/pending/pending_replay）由 Codable 向后兼容覆盖、无需迁移。迁移只 additive、不动 v1.4 冻结基线。
- `DrawingObject.revealTick: Int` = 提交画线时 `engine.tick.globalTickIndex`；对缺失该键的旧 blob/列解码默认 `0`。
- 渐显判据 = `drawing.revealTick <= tick`（全局 tick）；`panelPosition` 面板过滤保持不变。
- 复盘入口终局等式 / `ReviewLedger` / 交易账目**不受 `revealTick` 影响**。
- fixture 改动仅 `#if DEBUG`；真实生产训练/复盘逻辑不动。
- 每个纯核心 task 结束跑全量 `cd ios/Contracts && swift test` 绿；薄壳 task 跑 Mac Catalyst `build-for-testing` 绿。若 `swift test` 段错误，先 `rm -rf ios/Contracts/.build` 再跑（已知工具链对新增存储属性的陈旧 .build 崩溃）。

---

### Task 1: `DrawingObject.revealTick` 契约（模型 + 向后兼容 Codable + CONTRACT_VERSION）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift`（`DrawingObject` 约 209-223；`CONTRACT_VERSION` 第 7 行）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift:59-72`（`commit` 构造 `DrawingObject` 补 `revealTick`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift`

**Interfaces:**
- Produces: `DrawingObject(toolType:anchors:isExtended:panelPosition:revealTick:)`（`revealTick` 末位、memberwise init 默认 `= 0`）；`DrawingObject.revealTick: Int`；`CONTRACT_VERSION == "1.10"`。

- [ ] **Step 1: 写失败测试**（`ModelsTests.swift` 末尾追加）

```swift
@Test func drawingObject_revealTick_roundTrips() throws {
    let d = DrawingObject(toolType: .horizontal,
                          anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 10)],
                          isExtended: false, panelPosition: 1, revealTick: 12345)
    let data = try JSONEncoder().encode(d)
    let back = try JSONDecoder().decode(DrawingObject.self, from: data)
    #expect(back == d)
    #expect(back.revealTick == 12345)
}

@Test func drawingObject_legacyBlobWithoutRevealTick_decodesToZero() throws {
    // 旧 blob 从真实编码删掉 revealTick 键构造（不硬编码 Period rawValue——Period.m3 rawValue 是 "3m" 非 "m3"，
    // 硬编码会先在 period 解码失败，证不到 revealTick 兼容路径；codex plan R-med）：
    let full = DrawingObject(toolType: .horizontal,
                             anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 10)],
                             isExtended: false, panelPosition: 0, revealTick: 999)
    var dict = try JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as! [String: Any]
    dict.removeValue(forKey: "revealTick")   // 模拟旧格式：无此键
    let legacyData = try JSONSerialization.data(withJSONObject: dict)
    let back = try JSONDecoder().decode(DrawingObject.self, from: legacyData)
    #expect(back.revealTick == 0)
}

// CONTRACT_VERSION：**改现有测试，不新增**。`ModelsTests.swift:7-8` 现有
// `contractVersionIs1_9() { #expect(CONTRACT_VERSION == "1.9") }` → 改断言为 "1.10"
// 并重命名 `contractVersionIs1_10`（若追加第二个矛盾测试，旧的会红，gate 过不了——codex plan R-high-1）：
@Test func contractVersionIs1_10() {
    #expect(CONTRACT_VERSION == "1.10")
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter drawingObject_revealTick_roundTrips`
Expected: 编译失败（`DrawingObject` 无 `revealTick`）。

- [ ] **Step 3: 实现**

`Models.swift` 第 7 行：`public let CONTRACT_VERSION = "1.10"`。

`DrawingObject` 改为（保留 `toolType/anchors/isExtended/panelPosition`，加 `revealTick` + 自定义 Codable）：

```swift
public struct DrawingObject: Codable, Equatable, Sendable {
    public let toolType: DrawingToolType
    public let anchors: [DrawingAnchor]
    public let isExtended: Bool
    public let panelPosition: Int
    /// review-redesign 整改④：提交这条画线时会话所处的全局 tick（= 渐显时机；锚点仅定位几何，不再决定渐显）。
    public let revealTick: Int

    public init(toolType: DrawingToolType, anchors: [DrawingAnchor],
                isExtended: Bool, panelPosition: Int, revealTick: Int = 0) {
        self.toolType = toolType
        self.anchors = anchors
        self.isExtended = isExtended
        self.panelPosition = panelPosition
        self.revealTick = revealTick
    }

    private enum CodingKeys: String, CodingKey {
        case toolType, anchors, isExtended, panelPosition, revealTick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolType = try c.decode(DrawingToolType.self, forKey: .toolType)
        self.anchors = try c.decode([DrawingAnchor].self, forKey: .anchors)
        self.isExtended = try c.decode(Bool.self, forKey: .isExtended)
        self.panelPosition = try c.decode(Int.self, forKey: .panelPosition)
        // 向后兼容：旧 blob 无 revealTick → 0（从起点起可见）。
        self.revealTick = try c.decodeIfPresent(Int.self, forKey: .revealTick) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolType, forKey: .toolType)
        try c.encode(anchors, forKey: .anchors)
        try c.encode(isExtended, forKey: .isExtended)
        try c.encode(panelPosition, forKey: .panelPosition)
        try c.encode(revealTick, forKey: .revealTick)
    }
}
```

`DrawingToolManager.swift` 的 `commit`（59-72）构造补 `revealTick: 0`（占位；`routeDrawingCommit` 提交时覆盖成真实 tick，见 Task 2）：

```swift
let drawing = DrawingObject(
    toolType: activeTool!,
    anchors: pendingAnchors,
    isExtended: isExtended,
    panelPosition: panelPosition,
    revealTick: 0
)
```

- [ ] **Step 4: 跑测试确认通过 + 全量**

Run: `cd ios/Contracts && swift test --filter DrawingObject` 然后 `swift test`
Expected: 新 3 测试 PASS；全量绿（旧 DrawingObject 相关测试因 `revealTick` 默认 0 + 向后兼容解码仍通过）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift
git commit -m "feat(review): DrawingObject.revealTick + 向后兼容 Codable + CONTRACT_VERSION 1.10 (整改④契约)"
```

---

### Task 2: `drawings` 表 `reveal_tick` 迁移 + `RecordRepositoryImpl` 读写（训练记录画线持久化）

> **为何必需**：训练记录画线存在**规范化 `drawings` 表**（按列，非 JSON blob），reload 按列重建 `DrawingObject`。若不持久化 `revealTick`，历史记录画线 reload 后恒为 0 → 复盘里一进就全显，毁掉整改④对训练画线的核心行为（codex plan review R-high）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift`（`makeMigrator()` 末尾 `return migrator` 前注册 0008）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift`（insert 约 53-59；`drawingFromRow` 约 171-172）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/RecordRepositoryRevealTickTests.swift`（新建）

**Interfaces:**
- Consumes: `DrawingObject.revealTick`（Task 1）；既有 AppDB 组合根 + `insertRecord(_:ops:drawings:)` + 记录/画线 load 公有 API（复盘取 `engine.drawings` 同一路径）。
- Produces: `drawings.reveal_tick` 列（default 0）；训练记录画线的 `revealTick` 经 finalize→load 存活。

- [ ] **Step 1: 写失败测试**（新建 `RecordRepositoryRevealTickTests.swift`；用既有 `AppDBFixture` 建库）

```swift
import Testing
@testable import KlineTrainerPersistence
import KlineTrainerContracts

struct RecordRepositoryRevealTickTests {
    @Test func recordDrawing_revealTick_survivesFinalizeAndLoad() throws {
        let db = try AppDBFixture.makeInMemory()   // 用本套件既有 in-memory AppDB helper（若名字不同，用真实 helper）
        let rec = TrainingRecord(id: nil, trainingSetFilename: "x.sqlite", createdAt: 0,
                                 stockCode: "600001", stockName: "示例", startYear: 2023, startMonth: 11,
                                 totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                                 buyCount: 0, sellCount: 0,
                                 feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                                 finalTick: 100)
        let drawing = DrawingObject(toolType: .horizontal,
                                    anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 10)],
                                    isExtended: false, panelPosition: 0, revealTick: 777)
        let id = try db.insertRecord(rec, ops: [], drawings: [drawing])
        let loaded = try db.loadDrawings(recordId: id)   // 用真实的记录画线 load API（复盘 engine.drawings 来源）
        #expect(loaded.count == 1)
        #expect(loaded.first?.revealTick == 777)
    }
}
```
> 实现前先 `grep -n "func insertRecord\|loadDrawings\|func load.*[Dd]rawing\|drawings" ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift` 与 AppDB 协议，确认建库 helper 名 + 记录画线 load 的真实公有方法名，按真实签名写测试（断言不变：非零 `revealTick` 存活）。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter recordDrawing_revealTick_survivesFinalizeAndLoad`
Expected: FAIL（当前 `drawings` 表无 `reveal_tick` 列 / 重建默认 0，断言 777 失败）。

- [ ] **Step 3: 实现**

`AppDBMigrations.swift` 在 `return migrator` 前注册（0007 之后）：
```swift
// 0008：整改④ 训练记录画线 revealTick 持久化（v1.10）。additive：drawings 表加 reveal_tick 列。
// 只走 migration，不动 v1_4_baselineDDL/app_schema_v1.sql（v1.4 冻结基线，drift-checked）。
migrator.registerMigration("0008_v1.10_drawing_reveal_tick") { db in
    try db.execute(sql: "ALTER TABLE drawings ADD COLUMN reveal_tick INTEGER NOT NULL DEFAULT 0")
    try db.execute(sql: "PRAGMA user_version = 6")
}
```

`RecordRepositoryImpl.swift` insert 补 `reveal_tick`：
```swift
try db.execute(sql: """
    INSERT INTO drawings
      (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick)
    VALUES (?, ?, ?, ?, ?, ?)
    """, arguments: [
        recordId, dr.toolType.rawValue, dr.panelPosition,
        dr.isExtended ? 1 : 0, anchorsJSON, dr.revealTick
    ])
```

`drawingFromRow` 补 `revealTick`：
```swift
return DrawingObject(toolType: tool, anchors: anchors,
                     isExtended: isExt != 0, panelPosition: row["panel_position"],
                     revealTick: row["reveal_tick"])
```

- [ ] **Step 3.5: 更新既有"全量 migrator 终态 user_version" 断言 5 → 6（必做，否则 gate 红——codex plan R-high-2）**

bump 后全量 migrator 终态 = 6。**枚举更新**下列终态/全量断言（把 `== 5` 改 `6`、含终值的测试函数名 `_5`→`_6`）：
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift`：`test_full_migrator_sets_user_version_5`（约 52、断言约 58）→ 断言 6 + 重命名 `..._6`；注释"0007 起终态 = 5"→"0008 终态 = 6"。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDB0005MigrationTests.swift`：`test_fresh_install_full_migrator_user_version_5`（约 18、断言约 40 与 72 的 `== 5`）→ 全改 6 + 重命名 `..._6`。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/ReviewArchiveMigrationTests.swift`：约 14 与 34 两处 `== 5`（跑全 migrator 的终态）→ 6；注释"升级到 v5"→"v6"。
- **保持不变**的中间落点断言：`AppDB0005MigrationTests` 约 29 的 `== 2`（pre-0005）、`ReviewArchiveMigrationTests` 约 25 的 `== 4`（0006 落点）——这些是特定迁移的中间落点、非全量终态，不改。
- 兜底：`grep -rn 'user_version' ios/Contracts/Tests/KlineTrainerPersistenceTests/` 复核，凡"跑完整 migrator 后断言终值"的都要 5→6。

- [ ] **Step 4: 跑测试确认通过 + 全量**

Run: `cd ios/Contracts && swift test`（若段错误 → `rm -rf .build` 重跑）
Expected: 新 round-trip PASS；上列 user_version 终态断言更新为 6 后全量绿（ALTER 不动冻结基线，schema-drift 不受影响）。

- [ ] **Step 5: 提交**（须含被改的既有测试文件）

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/RecordRepositoryRevealTickTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDBMigrationsTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDB0005MigrationTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/ReviewArchiveMigrationTests.swift
git commit -m "feat(review): drawings 表 reveal_tick 迁移0008 + RecordRepositoryImpl 读写 + user_version 终态断言5→6 (整改④持久化)"
```

---

### Task 3: 渐显改按 `revealTick` + 提交盖戳

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift`（`make` 的 `drawings:` filter，约 66-72）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`routeDrawingCommit`，约 993-999）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift`（新增 revealTick 渐显；迁移旧锚点渐显断言）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`（新增盖戳）

**Interfaces:**
- Consumes: `DrawingObject.revealTick`（Task 1）；`engine.tick.globalTickIndex`。
- Produces: 渲染 `drawings` 过滤 = `panelPosition 匹配 && revealTick <= tick`；`routeDrawingCommit` 盖戳后画线 `revealTick == 提交时 tick.globalTickIndex`。

- [ ] **Step 1: 写失败测试**

`TrainingEngineDrawingCommitTests.swift` 追加（复用该文件既有 `make` 引擎 helper 的建法——先读文件顶部 helper 名，用同款构造 review 与 normal 引擎并步进到已知 tick）：

```swift
@Test func routeDrawingCommit_stampsRevealTick_normalMode() {
    let engine = Self.makeNormalEngineAtTick(50)   // 用本文件既有 helper 建 normal 引擎并步进到 tick 50
    let d = DrawingObject(toolType: .horizontal,
                          anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 10)],
                          isExtended: false, panelPosition: 0)   // revealTick 默认 0
    engine.routeDrawingCommit(d)
    #expect(engine.drawings.last?.revealTick == engine.tick.globalTickIndex)
    #expect(engine.drawings.last?.revealTick == 50)
}

@Test func routeDrawingCommit_stampsRevealTick_reviewMode() {
    let engine = Self.makeReviewEngineAtTick(60)   // review 引擎步进到 tick 60
    let d = DrawingObject(toolType: .horizontal,
                          anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 10)],
                          isExtended: false, panelPosition: 0)
    engine.routeDrawingCommit(d)
    #expect(engine.reviewDrawings.last?.revealTick == 60)
    #expect(engine.drawings.isEmpty)   // review commit 不污染训练层
}
```

`RenderStateBuilderTests.swift` 追加（用该文件既有引擎 helper；渐显只依赖 `revealTick <= tick`，与锚点 candleIndex 无关）：

```swift
@Test func drawingReveal_byRevealTick_hiddenBeforeCreationTick() {
    let engine = Self.makeEngineWithDrawing(revealTick: 100, panelPosition: 0, anchorCandleIndex: 0)
    Self.step(engine, toTick: 99)
    let s99 = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
    #expect(s99.drawings.isEmpty)              // revealTick 100 > 99：隐藏（即便锚 candleIndex=0）
    Self.step(engine, toTick: 100)
    let s100 = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
    #expect(s100.drawings.count == 1)          // revealTick 100 <= 100：显现
}

@Test func drawingReveal_lowerPanel_crossPeriod_byGlobalRevealTick() {
    let engine = Self.makeEngineWithDrawing(revealTick: 100, panelPosition: 1, anchorCandleIndex: 0)  // 下栏
    Self.step(engine, toTick: 100)
    let up = RenderStateBuilder.make(engine: engine, panel: .upper, bounds: Self.bounds)
    let low = RenderStateBuilder.make(engine: engine, panel: .lower, bounds: Self.bounds)
    #expect(up.drawings.isEmpty)               // panelPosition=1 不进上栏
    #expect(low.drawings.count == 1)           // 进下栏，按全局 revealTick 显现
}
```

> 注：本文件既有的"锚点渐显"测试（codex R4-F1 引入、断言 `anchor.candleIndex <= currentCandleIndex`）语义已被 `revealTick` 取代——**须迁移**：把这些断言改成用 `revealTick` 驱动隐藏/显现（构造画线时显式给 `revealTick`），而非删除；保留"未来隐藏/到点显现/两层叠加/panelPosition 过滤"的覆盖，只是判据换成 revealTick。实现前先 `grep -n "revealTick\|candleIndex <= \|R4-F1\|allSatisfy" RenderStateBuilderTests.swift` 找到它们逐条迁移。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter drawingReveal_byRevealTick_hiddenBeforeCreationTick`
Expected: FAIL（当前仍按锚点 candleIndex；锚 0 会立即显现，s99 非空）。

- [ ] **Step 3: 实现**

`RenderStateBuilder.swift` 的 `drawings:` filter 改为：

```swift
drawings: (engine.drawings + (engine.flow.mode == .review ? engine.reviewDrawings : [])).filter { drawing in
    drawing.panelPosition == (panel == .upper ? 0 : 1)
        && drawing.revealTick <= tick
},
```
（同时把上方那段"锚点全部 ≤ currentCandleIndex"的注释更新为"按 revealTick（创建时全局 tick）渐显；训练/复盘两层统一"。）

`TrainingEngine.swift` 的 `routeDrawingCommit`：

```swift
public func routeDrawingCommit(_ drawing: DrawingObject) {
    let stamped = DrawingObject(toolType: drawing.toolType, anchors: drawing.anchors,
                                isExtended: drawing.isExtended, panelPosition: drawing.panelPosition,
                                revealTick: tick.globalTickIndex)
    if flow.mode == .review {
        appendReviewDrawing(stamped)
    } else {
        appendDrawing(stamped)
    }
}
```

- [ ] **Step 4: 跑测试确认通过 + 全量**

Run: `cd ios/Contracts && swift test`（若段错误 → `rm -rf .build` 重跑）
Expected: 新测试 + 迁移后的旧渐显测试全 PASS；全量绿。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift
git commit -m "feat(review): 画线渐显改按 revealTick + routeDrawingCommit 盖戳 (整改④)"
```

---

### Task 4: 双面板划线（host-可测互斥核心 + 薄壳接线）+ 快进按钮样式

> ③的互斥/面板路由**核心逻辑落在平台无关引擎**（host 可测），薄壳只转调——避免 codex plan R-med："只 Catalyst 编译 + 人工"会让路由错面板仍过 gate。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（新增 3 个 host 方法）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`isDrawingActive`/`toggleDrawing`/onChange 转调引擎，传 `activePanel`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewControlBar.swift`（`ForEach` 按钮样式）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`（互斥/面板路由 host 测试）

**Interfaces:**
- Consumes: 既有 `engine.activateDrawingTool(_:panel:)` / `engine.cancelDrawing(panel:)` / `engine.panelState(_:)`（平台无关，host 可测）；`TrainingView` 既有 `@State activePanel`。
- Produces: `TrainingEngine.toggleDrawingExclusive(on:)`、`cancelDrawingAllPanels()`、`isDrawingActive(on:) -> Bool`。

- [ ] **Step 1: 写失败测试（host，互斥/面板路由）**

`TrainingEngineDrawingCommitTests.swift` 追加（用本文件既有 engine helper）：
```swift
@Test func toggleDrawingExclusive_activatesSelectedPanelOnly() {
    let engine = Self.makeNormalEngineAtTick(10)   // 用本文件既有 helper
    engine.toggleDrawingExclusive(on: .lower)
    #expect(engine.isDrawingActive(on: .lower))
    #expect(!engine.isDrawingActive(on: .upper))
}
@Test func toggleDrawingExclusive_switchingPanels_cancelsOther() {
    let engine = Self.makeNormalEngineAtTick(10)
    engine.toggleDrawingExclusive(on: .upper)      // 上栏进画线
    engine.toggleDrawingExclusive(on: .lower)      // 切下栏
    #expect(!engine.isDrawingActive(on: .upper))   // 上栏被取消（互斥）
    #expect(engine.isDrawingActive(on: .lower))
}
@Test func toggleDrawingExclusive_secondTapSamePanel_togglesOff() {
    let engine = Self.makeNormalEngineAtTick(10)
    engine.toggleDrawingExclusive(on: .lower)
    engine.toggleDrawingExclusive(on: .lower)
    #expect(!engine.isDrawingActive(on: .lower))
}
@Test func cancelDrawingAllPanels_clearsBoth() {
    let engine = Self.makeNormalEngineAtTick(10)
    engine.toggleDrawingExclusive(on: .upper)
    engine.cancelDrawingAllPanels()
    #expect(!engine.isDrawingActive(on: .upper))
    #expect(!engine.isDrawingActive(on: .lower))
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter toggleDrawingExclusive`
Expected: 编译失败（引擎无这些方法）。

- [ ] **Step 3: 实现 host 核心 + 薄壳接线 + 按钮样式**

`TrainingEngine.swift` 新增（复用既有 activate/cancel/panelState；先 `grep -n "func activateDrawingTool\|func cancelDrawing\|func panelState" TrainingEngine.swift` 确认签名）：
```swift
public func isDrawingActive(on panel: PanelId) -> Bool {
    if case .drawing = panelState(panel).interactionMode { return true }
    return false
}
public func cancelDrawingAllPanels() {
    cancelDrawing(panel: .upper)   // 非 .drawing 态 no-op
    cancelDrawing(panel: .lower)
}
/// 选中面板画线互斥：该面板已在画线→取消（toggle off）；否则取消两面板残留后激活选中面板。
public func toggleDrawingExclusive(on panel: PanelId) {
    if isDrawingActive(on: panel) {
        cancelDrawing(panel: panel)
    } else {
        cancelDrawingAllPanels()
        activateDrawingTool(.horizontal, panel: panel)
    }
}
```

`TrainingView.swift` 薄壳转调（传 `activePanel`）：
```swift
private var isDrawingActive: Bool { engine.isDrawingActive(on: activePanel) }
private func toggleDrawing() { engine.toggleDrawingExclusive(on: activePanel) }
```
并在既有 `.onChange(of: activePanel)`（当前仅清 `tradeStrip`）闭包内追加 `engine.cancelDrawingAllPanels()`（切面板退出画线态）；若无该 `.onChange`，在承载分段器的 `body` 处补 `.onChange(of: activePanel) { engine.cancelDrawingAllPanels() }`。

`ReviewControlBar.swift`（②按钮一行 + 统一浅蓝；标签 `lineLimit(1)` 防折行、`minimumScaleFactor` 防窄宽裁切）：
```swift
ForEach(content.buttons, id: \.action) { btn in
    Button { onAction(btn.action) } label: {
        Text(btn.title).lineLimit(1).minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
    .tint(.blue)
}
```

- [ ] **Step 4: 跑测试通过（host 互斥）+ Catalyst + 全量**

Run: `cd ios/Contracts && swift test --filter toggleDrawingExclusive`（PASS）→ `swift test`（全量绿）→ `xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3`（`** TEST BUILD SUCCEEDED **`）。
人工验收（附加，非唯一 gate）：spec §7 case 4（双面板划线互不串）/ case 5（按钮样式）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewControlBar.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift
git commit -m "feat(review): 双面板划线互斥(host核心+薄壳) + 快进按钮一行浅蓝 (整改③②)"
```

---

### Task 5: ① DEBUG fixture 一致性（pending/交易挪进复盘窗口内）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`（`make` 内 `record1Ops/record2Ops`/`record*Profit`/`pending` 约 122-165）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift`

**Interfaces:**
- Consumes: `m3Rows[i].close`（该 tick 收盘价）；`beforeM3Count`（= metaStartTick）；`m3Count`（finalTick = m3Count-1）；`ReviewLedger.state(atTick:ops:initialCapital:markPriceAtTick:)`（fold 校验）。
- 约束：所有交易 `globalTick ∈ (beforeM3Count, m3Count-1)`；`pending.globalTickIndex ∈ (beforeM3Count, m3Count)`；`fold(ops) == record.profit`。

- [ ] **Step 1: 写失败测试**（`DebugFixtureDataTests.swift` 追加；用 fullLoad 参数）

```swift
@Test func fixtureRecords_tradesWithinReviewWindow_and_pendingWithin() {
    let seed = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count,
                                     beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
    let start = DebugFixtureData.fullLoadBeforeM3Count      // metaStartTick
    let finalTick = DebugFixtureData.fullLoadM3Count - 1
    for ops in seed.recordOps {
        for op in ops { #expect(op.globalTick > start && op.globalTick < finalTick) }
    }
    #expect(seed.pending!.globalTickIndex > start && seed.pending!.globalTickIndex < DebugFixtureData.fullLoadM3Count)
}

@Test func fixtureRecords_foldEqualsStoredProfit() {
    let seed = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count,
                                     beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
    let m3 = seed.candles.first { $0.period == .m3 }!.rows
    for (rec, ops) in zip(seed.records, seed.recordOps) {
        let st = try! ReviewLedger.state(atTick: rec.finalTick, ops: ops,
                                         initialCapital: rec.totalCapital,
                                         markPriceAtTick: { t in m3[min(max(t,0), m3.count-1)].close })
        #expect(abs((st.totalCapital - rec.totalCapital) - rec.profit) < 1e-4)
    }
}

@Test func fixtureRecords_capitalChainsAcrossRecords() {
    // 累计本金链：record[i+1] 起始本金 == record[i] 结束本金（totalCapital + profit）——codex plan R-med
    let seed = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count,
                                     beforeM3Count: DebugFixtureData.fullLoadBeforeM3Count)
    for i in 0..<(seed.records.count - 1) {
        #expect(abs(seed.records[i + 1].totalCapital
                    - (seed.records[i].totalCapital + seed.records[i].profit)) < 1e-4)
    }
}

@Test func fixture_narrowAndTailWindows_tradesAndPendingStrictlyInterior() {
    // 边界：窄尾窗口 W=m3Count-before=6（before 靠近 m3Count），交易/pending 仍严格内部——codex plan R-med
    for (m3, before) in [(100, 94), (240, 234), (50, 44)] {
        let seed = DebugFixtureData.make(m3Count: m3, beforeM3Count: before)
        let finalTick = m3 - 1
        for ops in seed.recordOps { for op in ops {
            #expect(op.globalTick > before && op.globalTick < finalTick)
        }}
        #expect(seed.pending!.globalTickIndex > before && seed.pending!.globalTickIndex < m3)
    }
}
```
> 实现前先 `grep -n "state(atTick\|markPriceAtTick\|func state" ReviewLedger.swift` 校准 `ReviewLedger.state` 精确签名（若参数名/闭包签名不同，按真实签名调用；markPrice 用 m3 收盘、越界 clamp）。若 `PeriodCandles.rows` 元素访问 close 的属性名不同，用真实属性名。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ios/Contracts && swift test --filter fixtureRecords_tradesWithinReviewWindow`
Expected: FAIL（当前交易在 tick 1/2、pending 在 9600，全 < metaStartTick 12000）。

- [ ] **Step 3: 实现**（`make` 内，替换 record ops / profit / pending）

选窗口内 tick 与该 tick 收盘价作成交价；zero fee 保证 fold 精确；shares 取可负担的整百手；profit = shares×(卖价−买价)：

```swift
// 复盘窗口须容纳 4 个内部交易 tick + pending（所有真实调用 W≥100；full-load 7200——不破坏任何调用；codex plan R-med）。
precondition(m3Count - beforeM3Count >= 6,
             "DebugFixtureData: 复盘窗口 m3Count-beforeM3Count 须 ≥6（容纳 fixture 4 内部交易 tick + pending）")
// 4 个严格内部 tick（beforeM3Count < t < m3Count-1）+ pending，均匀分布，稳健于任意 W≥6（含窄尾窗口）。
let interiorFirst = beforeM3Count + 1
let interiorLast  = m3Count - 2                 // = finalTick - 1，严格 < finalTick
let span = interiorLast - interiorFirst         // >= 3（precondition 保证）
let tB1 = interiorFirst
let tS1 = interiorFirst + span / 3
let tB2 = interiorFirst + span * 2 / 3
let tS2 = interiorLast                          // 严格 < finalTick
let pendingTick = interiorFirst + span / 2      // 严格内部 ∈ (beforeM3Count, m3Count-1)
func closeAt(_ t: Int) -> Double { m3Rows[min(max(t, 0), m3Count - 1)].close }
// 可负担整百手（占用 ~40% 本金；价必 > 0）
func lots(_ price: Double, capital: Double) -> Int { max(100, Int((capital * 0.4 / price) / 100) * 100) }

let pB1 = closeAt(tB1), pS1 = closeAt(tS1)
let sh1 = lots(pB1, capital: 100_000)
let record1Ops = [
    TradeOperation(globalTick: tB1, period: .m3, direction: .buy,  price: pB1, shares: sh1,
                   positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh1) * pB1,
                   createdAt: baseEpoch),
    TradeOperation(globalTick: tS1, period: .m3, direction: .sell, price: pS1, shares: sh1,
                   positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh1) * pS1,
                   createdAt: baseEpoch),
]
let record1Profit = Double(sh1) * (pS1 - pB1)   // fold 同表达式（zero fee → 现金净变 = shares×(卖−买)）
// record2 起始本金 = record1 结束本金（累计本金链，与生产 RFC-A 累计模型一致；codex plan R-med）
let record2StartingCapital = 100_000.0 + record1Profit
let pB2 = closeAt(tB2), pS2 = closeAt(tS2)
let sh2 = lots(pB2, capital: record2StartingCapital)
let record2Ops = [
    TradeOperation(globalTick: tB2, period: .m3, direction: .buy,  price: pB2, shares: sh2,
                   positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh2) * pB2,
                   createdAt: baseEpoch + 86_400),
    TradeOperation(globalTick: tS2, period: .m3, direction: .sell, price: pS2, shares: sh2,
                   positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh2) * pS2,
                   createdAt: baseEpoch + 86_400),
]
let record2Profit = Double(sh2) * (pS2 - pB2)   // record1Profit 已上移（record2 起始本金依赖它）
```
`records`：record1 `totalCapital: 100_000, profit: record1Profit, returnRate: record1Profit/100_000`；record2 `totalCapital: record2StartingCapital, profit: record2Profit, returnRate: record2Profit / record2StartingCapital`（**用累计起始本金，不再硬编码 108_900**）；两者 `finalTick: m3Count - 1` 不变。

`pending` 的 `globalTickIndex` 从 `m3Count / 2` 改为窗口内：

```swift
globalTickIndex: pendingTick,
```
（其余 pending 字段不变。）

- [ ] **Step 4: 跑测试确认通过 + 全量**

Run: `cd ios/Contracts && swift test`
Expected: 新 2 测试 PASS；全量绿（既有 `DebugFixtureDataTests`/`AppContainerDebugSeedTests` 若断言旧 tick 1/2 或旧 profit 字面，一并迁移到新窗口内值/新 profit）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift
git commit -m "fix(review): DEBUG fixture pending/交易挪进复盘窗口内，使续训完可复盘+逐tick盈亏可见 (整改①)"
```

---

## 收尾（subagent-driven 全部 task 后）
- 全量 `cd ios/Contracts && swift test` 绿 + Mac Catalyst `build-for-testing` 绿（verification-before-completion）。
- requesting-code-review（whole-branch）→ codex 对抗性 review 到收敛。
- 真机重装（`simctl uninstall` 清旧数据 + 带 `KLINE_SEED_FIXTURE=1` 重种）人工走 spec §7 验收 1-6。
- push（PR #139 自动更新）。
