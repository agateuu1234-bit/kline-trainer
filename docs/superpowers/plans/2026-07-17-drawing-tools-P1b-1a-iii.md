# 划线工具扩充 P1b · 1a-iii「外壳与设置」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给训练/replay 加「画图」入口 + 两行画线底栏 + 长按设置卡片，退役旧浮动铅笔钮；让用户能设样式并画出带样式的水平线（存内存整局有效、不落盘）。

**Architecture:** 纯 UI/渲染层，零契约变更（`CONTRACT_VERSION` 保持 1.11、`user_version` 保持 7）。默认样式落 1a-ii 的 `DrawingSession` 单一真相，提交路径 `commitPending` 原子读取并构造完整 `DrawingObject`（append 前灌满，count 触发一次落盘）。进画线是交易边界转换（作废未确认买卖框）。

**Tech Stack:** Swift 6 / SwiftUI（视图 `#if canImport(UIKit)` 门控）/ swift-testing（`import Testing`）/ SwiftPM 包 `KlineTrainerContracts`。

## Global Constraints

- 契约冻结：不 bump `CONTRACT_VERSION`（1.11）、不动 `user_version`（7）、零迁移。本期只写 `.horizontal` 一种 toolType。
- 范围权威 = `docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md` §4；交互设计 = `docs/superpowers/specs/2026-07-17-drawing-tools-P1b-1a-iii-shell-interaction.md`（codex approve @ `299f567`）。
- `DrawingSession` 访问级：状态 `public private(set)`、**所有 mutator `internal`**（1a-ii plan-R5-high，包外不得绕过会话入口）。新增 setter 一律 internal。
- UI 文案中文；「不可用项只灰、不写任何『不适用』解释字」（母 spec §3 逐字）。
- 昼夜禁色：白天禁「白」、夜间禁「黑」，自动灰（禁选，非改渲染色）。
- 底栏 ②–⑤ 键、类型行图标 toggle、选中/删改/锁定/撤销、手势改动、节点/多锚/新工具、复盘专属、主页全局默认——**均不在本期**（D19：不 ship 未接线控件/死图标）。
- 三绿门（作者亲核，见交互设计 §5 的逐字 CI 等价命令块）；模拟器验收不可跳过。

---

## 文件结构

| 文件 | 责任 | 门控 |
|---|---|---|
| `Sources/KlineTrainerContracts/Models/DrawingEnums.swift`（改） | 新增 `DrawingDefaultStyle` 值类型（5 样式字段） | 非门控（host 可测） |
| `Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`（改） | 加 `defaultStyle` + internal setter；`commitPending` 原子读 `defaultStyle` 构造完整线 | 非门控 |
| `Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift`（新） | 水平线设置面板的灰态判据（纯函数：线型子类/标注/颜色可用性） | 非门控（host 可测） |
| `Sources/KlineTrainerContracts/UI/DrawingModeBar.swift`（新） | 两行底栏骨架：类型行(1 水平线图标) + 下行(①类型键)；长按类型图标回调 | `#if canImport(UIKit)` |
| `Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift`（新） | 长按设置卡片：4 组控件 + 遮罩；写 `DrawingSession.defaultStyle` | `#if canImport(UIKit)` |
| `Sources/KlineTrainerContracts/UI/TrainingView.swift`（改） | 画图入口钮 + 结束↔退出 + 底栏切换 + 谓词拆分退役浮动钮 + 交易边界 + 呈现卡片 | `#if canImport(UIKit)` |

**任务顺序**：先无 UI 的逻辑地基（Task 1、2）→ 两个独立视图（Task 3、4）→ 最后 TrainingView 集成把三者接线并退役浮动钮（Task 5），保证任何单任务后训练页都不处于「有旧入口没新入口」或反之的破态。

---

### Task 1: `DrawingDefaultStyle` + `DrawingSession.defaultStyle` + 原子 `commitPending`

**Files:**
- Modify: `Sources/KlineTrainerContracts/Models/DrawingEnums.swift`（追加 `DrawingDefaultStyle`）
- Modify: `Sources/KlineTrainerContracts/Drawing/DrawingSession.swift:87-99`（`commitPending` 改签名 + 读 `defaultStyle`；加 `defaultStyle` 存储 + setter）
- Test: `Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`（改 `:115/:122` 两处旧调用 + 新增默认样式测试）
- Test: `Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift`（追加带样式画线 commit→saveProgress→读回往返集成测试）
- Test: `Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift`（追加原子构造结构守卫）
- Test: `Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift`（追加 replay 带样式画线**端到端** save→读回）

**Interfaces:**
- Produces:
  - `struct DrawingDefaultStyle: Equatable, Sendable { var lineSubType: LineSubType; var lineStyle: LineStyle; var thickness: Int; var colorToken: DrawingColorToken; var labelMode: LabelMode; init() }`（全默认值 = `.straight/.solid/1/.orange/.hidden`）
  - `DrawingSession.defaultStyle: DrawingDefaultStyle`（`public private(set)`）
  - `DrawingSession.setDefaultStyle(_:)`（**internal**）
  - `DrawingSession.commitPending(panelPosition: Int) -> DrawingObject?`（**去掉 `lineSubType` 参数**；5 样式字段全部从 `defaultStyle` 读，append 前原子构造）
- Consumes: 无（地基任务）

- [ ] **Step 1: 写失败测试（默认样式流进提交 + 原子 + 只影响新线 + isExtended 派生）**

在 `DrawingSessionTests.swift` 末尾（`}` 前）追加，并把已有 `:115/:122` 两处 `commitPending(lineSubType: …, panelPosition:)` 改为「先 `setDefaultStyle` 再 `commitPending(panelPosition:)`」：

```swift
    // ── Task 1（1a-iii）：默认样式原子流进提交 ──
    @Test("默认样式全 5 字段原子流进提交的线 + 标签色=线色")
    func defaultStyleFlowsIntoCommit() throws {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        var style = DrawingDefaultStyle()
        style.lineSubType = .ray; style.lineStyle = .dash2
        style.thickness = 3; style.colorToken = .red; style.labelMode = .right
        s.setDefaultStyle(style)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = try #require(s.commitPending(panelPosition: 0))
        #expect(obj.lineSubType == .ray)
        #expect(obj.lineStyle == .dash2)
        #expect(obj.thickness == 3)
        #expect(obj.colorToken == .red)
        #expect(obj.labelMode == .right)
        #expect(obj.textColorToken == .red)       // codex plan-R7：标签色跟线色（否则标签渲染成默认橙）
        #expect(obj.isExtended == true)           // isExtended 由 lineSubType==.ray 派生（不变量保留）
        // 标签**渲染路径**真拿到线色（labelContent.colorToken 来自 textColorToken，codex plan-R7）
        let label = try #require(DrawingLabelLayout.labelContent(for: obj, lineVisible: true))
        #expect(label.colorToken == .red)
    }

    @Test("改默认只影响下一条：先画一条、改默认、再画一条 —— 第一条不变")
    func defaultChangeAffectsOnlyNextLine() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        let first = s.commitPending(panelPosition: 0)          // 默认橙/实线/1/直线/隐藏
        var style = DrawingDefaultStyle(); style.colorToken = .green
        s.setDefaultStyle(style)
        s.addAnchor(anchor(20), panel: .upper)
        let second = s.commitPending(panelPosition: 0)
        #expect(first?.colorToken == .orange)                  // 第一条不被回改
        #expect(second?.colorToken == .green)
    }

    @Test("straight 默认 → isExtended==false（派生不变量）")
    func straightDerivesNotExtended() {
        let s = DrawingSession(); s.activate(tool: .horizontal)
        s.addAnchor(anchor(10), panel: .upper)
        #expect(s.commitPending(panelPosition: 1)?.isExtended == false)
    }
```

把原有这两处（约 `:113-123`）：

```swift
        let straight = s.commitPending(lineSubType: .straight, panelPosition: 1)
        …
        let ray = s.commitPending(lineSubType: .ray, panelPosition: 1)
```

改为：

```swift
        // 1a-iii：lineSubType 不再是 commitPending 入参，改经 defaultStyle 单一真相
        s.setDefaultStyle({ var st = DrawingDefaultStyle(); st.lineSubType = .straight; return st }())
        let straight = s.commitPending(panelPosition: 1)
        …
        s.setDefaultStyle({ var st = DrawingDefaultStyle(); st.lineSubType = .ray; return st }())
        let ray = s.commitPending(panelPosition: 1)
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingSessionTests`
Expected: FAIL —— `DrawingDefaultStyle` / `setDefaultStyle` / `defaultStyle` 未定义，`commitPending(panelPosition:)` 无匹配。

- [ ] **Step 3: 加 `DrawingDefaultStyle`（DrawingEnums.swift 末尾）**

```swift
/// 「下一条要画的线」的默认样式（1a-iii）。整局内存有效、不落盘（持久化全局默认属 P6）。
/// 是 DrawingSession 上的单一真相，提交路径 commitPending 原子消费它构造完整 DrawingObject。
public struct DrawingDefaultStyle: Equatable, Sendable {
    public var lineSubType: LineSubType = .straight
    public var lineStyle: LineStyle = .solid
    public var thickness: Int = 1                 // 1…5
    public var colorToken: DrawingColorToken = .orange
    public var labelMode: LabelMode = .hidden
    public init() {}
}
```

- [ ] **Step 4: DrawingSession 加 `defaultStyle` + setter，改 `commitPending`**

在 `DrawingSession` 里 `pendingAnchorPanel` 声明后加：

```swift
    /// 1a-iii：设置卡片写入的「下一条线」默认样式（单一真相，提交路径读它）。
    public private(set) var defaultStyle = DrawingDefaultStyle()

    /// 1a-iii：设置卡片（DrawingStyleCard，同包 UI 层）经此写默认样式。internal——包外不得直改。
    func setDefaultStyle(_ style: DrawingDefaultStyle) { defaultStyle = style }
```

把现有 `commitPending`（`:87-99`）整体替换为：

```swift
    /// pending → DrawingObject。**DrawingObject 的唯一写入点**：isExtended 从 lineSubType 派生
    /// （不变量 isExtended == (lineSubType == .ray)；矛盾数据不可表达）。
    /// **1a-iii：5 样式字段全部从 defaultStyle 原子读取**——在 append 之前就灌满，
    /// 让 routeDrawingCommit 的 append 成为 drawings 的唯一改动（count 触发一次即完整落盘，
    /// 杜绝「先 append 默认样式、再原地改样式」的提交后套用不落盘缺陷，codex branch-R1/R2）。
    /// period 不传 → 由 DrawingObject.init 取 anchors.first.period（D29 周期绑定，不得回退）。
    /// revealTick 由 engine.routeDrawingCommit 盖真值。
    /// **D38：提交后只清 pending —— 工具与会话保持不变（连续画线）**。
    func commitPending(panelPosition: Int) -> DrawingObject? {
        guard let tool = activeDrawingTool, !pendingAnchors.isEmpty else { return nil }
        let s = defaultStyle
        let drawing = DrawingObject(
            toolType: tool,
            anchors: pendingAnchors,
            isExtended: s.lineSubType == .ray,
            panelPosition: panelPosition,
            revealTick: 0,
            lineSubType: s.lineSubType,
            lineStyle: s.lineStyle,
            thickness: s.thickness,
            colorToken: s.colorToken,
            labelMode: s.labelMode,
            // codex plan-R7-medium：价格标签渲染用 textColorToken（DrawingLabelLayout.labelContent:75），
            // 本期卡片只有一个「颜色」控件（线色）→ 标签跟线同色，否则蓝线配橙标签。
            // （独立「字色」是 P3 的标注文字工具，本期不引入。）
            textColorToken: s.colorToken)
        discardPendingAnchors()
        return drawing
    }
```

（`ChartContainerView.swift:284` 的调用 `session.commitPending(panelPosition:)` 无需改——签名兼容。）

- [ ] **Step 4b: 修 ChartContainerView 陈旧注释（本任务改了语义 → 注释失真，surgical 清理自己的 mess）**

`ChartContainerView.swift:283` 现注释 `// 本期无线型选择器（→1a-iii），新线一律 .straight` 已不成立（新线样式现从 `defaultStyle` 来）。改为：

```swift
            // 1a-iii：样式（含 lineSubType）由 session.defaultStyle 单一真相决定，commitPending 原子读取。
```

- [ ] **Step 5: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingSessionTests`
Expected: PASS（含新 3 条 + 改写的 2 条）。

- [ ] **Step 5b: 持久化往返集成测试（commit→saveProgress→读回，codex plan-R3-high）**

> 单看 `commitPending` 返回对象不够——必须证明「样式经真实提交链 → autosave 落盘 → 读回」五字段 + revealTick 全保真。加进 `TrainingSessionPersistenceTests.swift`（复用其 `makeCoordinator`/`validCandles` 私有 helper；`activate`/`setDefaultStyle`/`commitPending` 经 `@testable` 可调）：

```swift
    @Test("1a-iii：带样式的画线 commit→saveProgress→读回 pending —— 5 样式字段 + revealTick 保真")
    func styledDrawingSurvivesSaveProgress() async throws {
        let (coord, _, pending, _) = Self.makeCoordinator(candles: Self.validCandles())
        let engine = try await coord.startNewNormalSession()
        // 走真实提交链：defaultStyle → commitPending（原子灌满）→ routeDrawingCommit（盖 revealTick + append）
        let s = engine.drawingSession
        s.activate(tool: .horizontal)
        var style = DrawingDefaultStyle()
        style.lineSubType = .ray; style.lineStyle = .dash3; style.thickness = 4
        style.colorToken = .blue; style.labelMode = .right
        s.setDefaultStyle(style)
        s.addAnchor(DrawingAnchor(period: engine.upperPanel.period, candleIndex: 0, price: 100), panel: .upper)
        let committed = try #require(s.commitPending(panelPosition: 0))
        engine.routeDrawingCommit(committed)
        let appended = try #require(engine.drawings.first)
        // 原子性核心（codex plan-R4-high）：**append 那一刻**对象就已带全部 5 样式。
        // count 触发的 autosave 恰在 drawings.count 变化（=append）时读 engine.drawings —— 即读到此刻的 appended。
        // 若实现是「先 append 默认橙/隐藏、再原地改样式」，此刻 appended 会是默认值 → 本断言当场红
        // （正是 crash/切后台在 count 触发点会存到的不完整值）。故断言 append 时即完整 = 断言无「后补样式」。
        #expect(appended.lineSubType == .ray && appended.lineStyle == .dash3 && appended.thickness == 4)
        #expect(appended.colorToken == .blue && appended.labelMode == .right)
        #expect(appended.textColorToken == .blue)          // codex plan-R7：标签色=线色，落盘也须保真
        // 落盘 + 读回：证明整条链（含 count 触发的真实 autosave 载荷）保真
        try await coord.saveProgress(engine: engine)
        let p = try #require(try pending.loadPending())
        let d = try #require(p.drawings.first)
        #expect(d.lineSubType == .ray)
        #expect(d.lineStyle == .dash3)
        #expect(d.thickness == 4)
        #expect(d.colorToken == .blue)
        #expect(d.labelMode == .right)
        #expect(d.textColorToken == .blue)                 // codex plan-R7：标签色=线色，往返保真
        #expect(d.revealTick == appended.revealTick)       // routeDrawingCommit 盖的 revealTick 也保真
        #expect(d.colorToken == appended.colorToken && d.labelMode == appended.labelMode)  // 落盘值 == append 时值
    }
```

Run: `cd ios/Contracts && swift test --filter TrainingSessionPersistenceTests` → PASS。

**再补 replay 侧端到端覆盖（codex plan-R14-high 纠正）**：replay 的 `saveProgress` **并非 no-op**——它写 `PendingReplay`、含 **clean-skip 判脏 + `loadedDrawingsLossy` 与 `drawings` 调和**。只做 `PendingReplay` 序列化往返会**绕过**这条真实路径（clean-skip 吞掉首条 / lossy 调和丢样式都测不到）。故必须**端到端**：起 replay → 设 defaultStyle → `commitPending`/`routeDrawingCommit`（replay 非 review，写 `drawings`、变脏）→ `coordinator.saveProgress` → 从 `pendingReplayRepo` 读回。加进 `Tests/.../CoordinatorReplayPersistenceTests.swift`（复用 `CoordinatorTestHarness`）：

```swift
@Test func replayStyledDrawing_survivesSaveAndResume() async throws {
    let h = try CoordinatorTestHarness.make()
    let engine = try await h.coordinator.replay(recordId: h.seededRecordId)
    // 真实提交链：replay 模式 routeDrawingCommit 写 engine.drawings（脏 → 不被 clean-skip 跳过）
    let s = engine.drawingSession
    s.activate(tool: .horizontal)
    var style = DrawingDefaultStyle()
    style.lineSubType = .ray; style.lineStyle = .dash3; style.thickness = 4
    style.colorToken = .blue; style.labelMode = .right
    s.setDefaultStyle(style)
    s.addAnchor(DrawingAnchor(period: engine.upperPanel.period, candleIndex: 0, price: 100), panel: .upper)
    let committed = try #require(s.commitPending(panelPosition: 0))
    engine.routeDrawingCommit(committed)
    let inMem = try #require(engine.drawings.first)
    try await h.coordinator.saveProgress(engine: engine)          // 真写 PendingReplay（clean-skip + lossy 调和）
    let saved = try #require(try h.pendingReplayRepo.loadReplay())
    let d = try #require(saved.drawings.first)
    #expect(d.lineSubType == .ray && d.lineStyle == .dash3 && d.thickness == 4)
    #expect(d.colorToken == .blue && d.labelMode == .right && d.textColorToken == .blue)   // 标签色也保真
    #expect(d.revealTick == inMem.revealTick)
}
```

Run: `cd ios/Contracts && swift test --filter replayStyledDrawing` → PASS。

- [ ] **Step 5c: 原子性结构守卫（「append 默认再补丁」结构上不可能，codex plan-R5-high）**

> R5 的关切是 behavior 测试看不到「同一次调用里 append 默认、再改 `drawings[last]`」的中间态。终极答复是**结构性**的、不靠 behavior 断言：
> ① **`DrawingObject` 全部字段是 `let`**（`public let colorToken` 等，见 `Models.swift`）→ `drawings[i].colorToken = x` **编译不过**，字段级「后补丁」在类型层就不可表达。
> ② `commitPending` 在**单个** `DrawingObject(...)` 初始化里从 `defaultStyle` 灌满 5 字段（唯一构造点）。
> ③ `routeDrawingCommit`（`TrainingEngine.swift:1066`）把 5 字段**整体透传**进 `stamped`（只覆盖 `revealTick`）再 `append` 一次。
> 唯一残余的「整元素替换」`drawings[i] = DrawingObject(...)` 仍须先构造一个**完整**对象——无处产生「不完整线」。加结构守卫钉死 ②③（① 由编译器保证）：

加进 `DrawingSessionSourceGuardTests.swift`（已有 `source(_:)`/`engine` helper；补 `drawingSession` 路径）：

```swift
    private let drawingSession = "Sources/KlineTrainerContracts/Drawing/DrawingSession.swift"

    @Test("原子性：commitPending 5 字段从 defaultStyle 原子构造 + routeDrawingCommit 整体透传（codex plan-R5）")
    func atomicStyleConstruction() throws {
        let s = try source(drawingSession)
        #expect(s.contains("func commitPending("))       // 先证真读到文件（防路径错→空→假绿）
        for f in ["lineSubType: s.lineSubType", "lineStyle: s.lineStyle", "thickness: s.thickness",
                  "colorToken: s.colorToken", "labelMode: s.labelMode"] {
            #expect(s.contains(f))                        // commitPending 单初始化原子灌满
        }
        let e = try source(engine)
        for f in ["lineSubType: drawing.lineSubType", "lineStyle: drawing.lineStyle",
                  "thickness: drawing.thickness", "colorToken: drawing.colorToken", "labelMode: drawing.labelMode"] {
            #expect(e.contains(f))                        // routeDrawingCommit 整体透传 5 字段，无逐字段丢弃/默认化
        }
        // 提取 routeDrawingCommit 函数体，钉死「无 append-then-replace」（codex plan-R6-high）：
        // let 字段防不了「append(默认) 后 drawings[last] = 完整」的整元素替换 → 直接禁下标写、且只消费 stamped。
        let rcStart = try #require(e.range(of: "public func routeDrawingCommit"), "找不到 routeDrawingCommit（结构漂移）")
        let afterRC = String(e[rcStart.upperBound...])
        let rcEnd = try #require(afterRC.range(of: "\n    public func"), "找不到 routeDrawingCommit 结尾")
        let rc = String(afterRC[..<rcEnd.lowerBound])
        // 两个都要显式断言（codex plan-R10-medium）：Swift 大小写敏感，"reviewDrawings[" 不含 "drawings["
        // （前者是大写 D）→ 只查小写会漏掉 review 分支的 append-then-replace。
        #expect(!rc.contains("drawings["))               // normal/replay 分支无元素替换
        #expect(!rc.contains("reviewDrawings["))         // review 分支无元素替换（大写 D，须单独查）
        #expect(rc.contains("appendDrawing(stamped)"))   // 消费的是 stamped（全 5 样式字段，只盖 revealTick）
        #expect(rc.contains("appendReviewDrawing(stamped)"))
    }
```

Run: `cd ios/Contracts && swift test --filter DrawingSessionSourceGuardTests` → PASS。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionPersistenceTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift
git commit -m "1a-iii Task1：DrawingSession.defaultStyle 单一真相 + commitPending 原子构造完整线 + 持久化往返(normal pending + replay 端到端)集成测试 + 原子性结构守卫"
```

---

### Task 2: `DrawingStyleAvailability` 灰态判据（纯函数）

**Files:**
- Create: `Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift`
- Test: `Tests/KlineTrainerContractsTests/Drawing/DrawingStyleAvailabilityTests.swift`

**Interfaces:**
- Produces（本期只覆盖水平线；其余工具属 P1c，本函数不实现，故不取 `tool` 参数——YAGNI）：
  - `DrawingStyleAvailability.horizontalLineSubTypeEnabled(_ sub: LineSubType) -> Bool`
  - `DrawingStyleAvailability.horizontalLabelModeEnabled(_ mode: LabelMode, lineSubType: LineSubType) -> Bool`
  - `DrawingStyleAvailability.colorEnabled(_ token: DrawingColorToken, scheme: AppColorScheme) -> Bool`
  - `DrawingStyleAvailability.normalizedLabelMode(current: LabelMode, lineSubType: LineSubType) -> LabelMode`（**依赖字段规整，codex plan-R1-medium**：切线型子类后旧 `labelMode` 可能变不可用——若 `horizontalLabelModeEnabled(current, lineSubType)==false` 则回落 `.hidden`，否则原样。**复用同一 `horizontalLabelModeEnabled` 判据，单一真相不重复规则**。设置卡片切线型时调它，杜绝「显示为灰、却仍作默认被提交」的矛盾组合。）
- Consumes: `LineSubType` / `LabelMode` / `DrawingColorToken` / `AppColorScheme`（均已存在）

- [ ] **Step 1: 写失败测试（母 spec §3.1 水平线行逐格）**

```swift
// Tests/KlineTrainerContractsTests/Drawing/DrawingStyleAvailabilityTests.swift
// Spec: 母 spec §3.1 水平线可选矩阵 + §4.1.4 昼夜禁色。
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingStyleAvailability：水平线设置面板灰态判据（母 spec §3.1）")
struct DrawingStyleAvailabilityTests {
    typealias A = DrawingStyleAvailability

    @Test("线型子类：直线✅ 射线✅ 线段灰")
    func lineSubType() {
        #expect(A.horizontalLineSubTypeEnabled(.straight))
        #expect(A.horizontalLineSubTypeEnabled(.ray))
        #expect(!A.horizontalLineSubTypeEnabled(.segment))
    }

    @Test("标注：隐藏/左/右可选、显示恒灰；选射线时『左』再灰")
    func labelMode() {
        // 直线：隐藏/左/右可选，显示灰
        #expect(A.horizontalLabelModeEnabled(.hidden, lineSubType: .straight))
        #expect(A.horizontalLabelModeEnabled(.left,   lineSubType: .straight))
        #expect(A.horizontalLabelModeEnabled(.right,  lineSubType: .straight))
        #expect(!A.horizontalLabelModeEnabled(.show,  lineSubType: .straight))
        // 射线：左再灰
        #expect(!A.horizontalLabelModeEnabled(.left,  lineSubType: .ray))
        #expect(A.horizontalLabelModeEnabled(.right,  lineSubType: .ray))
        #expect(A.horizontalLabelModeEnabled(.hidden, lineSubType: .ray))
    }

    @Test("颜色：白天禁白、夜间禁黑，7 彩色恒可选")
    func color() {
        #expect(!A.colorEnabled(.white, scheme: .light))
        #expect(A.colorEnabled(.white, scheme: .dark))
        #expect(!A.colorEnabled(.black, scheme: .dark))
        #expect(A.colorEnabled(.black, scheme: .light))
        for c in [DrawingColorToken.red, .orange, .yellow, .green, .cyan, .blue, .purple] {
            #expect(A.colorEnabled(c, scheme: .light))
            #expect(A.colorEnabled(c, scheme: .dark))
        }
    }

    @Test("依赖字段规整：选『左』后切『射线』→ labelMode 回落 hidden（不留矛盾组合，codex plan-R1）")
    func normalizeLabelOnSubtypeChange() {
        // 直线下『左』合法 → 保留
        #expect(A.normalizedLabelMode(current: .left, lineSubType: .straight) == .left)
        // 切射线后『左』不可用 → 回落 hidden
        #expect(A.normalizedLabelMode(current: .left, lineSubType: .ray) == .hidden)
        // 合法值不动
        #expect(A.normalizedLabelMode(current: .right, lineSubType: .ray) == .right)
        #expect(A.normalizedLabelMode(current: .hidden, lineSubType: .ray) == .hidden)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingStyleAvailabilityTests`
Expected: FAIL —— `DrawingStyleAvailability` 未定义。

- [ ] **Step 3: 实现纯函数**

```swift
// Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift
// 设置面板灰态判据（host 可测，非 View）。本期只实现水平线（母 spec §3.1 水平线行）；
// 其余工具的矩阵属 P1c，届时再泛化——本期不写不存在工具的分支（YAGNI）。
public enum DrawingStyleAvailability {
    /// 线型子类：水平线 直线✅/射线✅/线段灰。
    public static func horizontalLineSubTypeEnabled(_ sub: LineSubType) -> Bool {
        switch sub {
        case .straight, .ray: return true
        case .segment:        return false
        }
    }

    /// 标注：水平线 隐藏/左/右可选、显示恒灰；选射线时『左』再灰（母 spec §3.1）。
    public static func horizontalLabelModeEnabled(_ mode: LabelMode, lineSubType: LineSubType) -> Bool {
        switch mode {
        case .show:   return false
        case .hidden, .right: return true
        case .left:   return lineSubType != .ray
        }
    }

    /// 颜色：白天禁白、夜间禁黑（与背景同色不可读）；7 彩色恒可选（§4.1.4）。
    public static func colorEnabled(_ token: DrawingColorToken, scheme: AppColorScheme) -> Bool {
        switch token {
        case .white: return scheme != .light
        case .black: return scheme != .dark
        default:     return true
        }
    }

    /// 依赖字段规整：切线型子类后，若旧 labelMode 在新子类下不可用（如直线选『左』后切射线），
    /// 回落 .hidden；否则原样。**复用 horizontalLabelModeEnabled，规则单一真相不重复。**
    /// 设置卡片切线型时调它 → 矛盾组合（灰项却被当默认提交）从结构上进不来（codex plan-R1-medium）。
    public static func normalizedLabelMode(current: LabelMode, lineSubType: LineSubType) -> LabelMode {
        horizontalLabelModeEnabled(current, lineSubType: lineSubType) ? current : .hidden
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingStyleAvailabilityTests`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingStyleAvailabilityTests.swift
git commit -m "1a-iii Task2：DrawingStyleAvailability 水平线灰态判据纯函数（母 spec §3.1）"
```

---

### Task 3: `DrawingModeBar` 两行底栏骨架

**Files:**
- Create: `Sources/KlineTrainerContracts/UI/DrawingModeBar.swift`
- Test: `Tests/KlineTrainerContractsTests/Render/DrawingModeBarSourceGuardTests.swift`

**Interfaces:**
- Produces（`#if canImport(UIKit)`）：
  - `struct DrawingModeBar: View`，init 参数：`typeRowExpanded: Binding<Bool>`、`onLongPressType: () -> Void`（长按水平线图标→呈现设置卡片，由 Task 5 接线）。
  - 类型行：本期**只 1 个**水平线图标（`Image(systemName:"minus")`，恒亮浅蓝框，`accessibilityLabel("水平线")`），短按 no-op（本期无 toggle，D38）、长按触发 `onLongPressType`。
  - 下行：**只 1 个**「类型」键（`accessibilityLabel("类型")`），点它翻转 `typeRowExpanded`。②–⑤ 不渲染。
- Consumes: 无引擎依赖（纯骨架 + 两个回调/绑定）

- [ ] **Step 1: 写结构守卫测试（视图树只含既定控件 / 无 ②–⑤）**

> 视图控件的「存在/不存在」在 host swift test 测不到；用**源码结构守卫**（读源码、剥注释、断言字面），并 mutation 验证（改坏即红）。

```swift
// Tests/KlineTrainerContractsTests/Render/DrawingModeBarSourceGuardTests.swift
// Spec: split-addendum §4.1.2 / §4.3-3,4（D24/D19：类型行只 1 图标、下行只①类型键、②–⑤不渲染）。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingModeBar 结构守卫：类型行 1 图标 / 下行只①类型键 / 无 ②–⑤")
struct DrawingModeBarSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let bar = "Sources/KlineTrainerContracts/UI/DrawingModeBar.swift"

    @Test("类型行恒亮的水平线图标存在、①类型键存在")
    func hasExpectedControls() throws {
        let code = try source(bar)
        #expect(code.contains("accessibilityLabel(\"水平线\")"))
        #expect(code.contains("accessibilityLabel(\"类型\")"))
        #expect(code.contains("onLongPressType"))
    }

    @Test("②锁定/③删除/④撤销/⑤前进 图标本期不渲染（D19）")
    func noUnwiredKeys() throws {
        let code = try source(bar)
        for banned in ["accessibilityLabel(\"锁定\")", "accessibilityLabel(\"删除\")",
                       "accessibilityLabel(\"撤销\")", "accessibilityLabel(\"前进\")"] {
            #expect(!code.contains(banned))
        }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingModeBarSourceGuardTests`
Expected: FAIL —— 文件不存在，`hasExpectedControls` 读到空/报错。

- [ ] **Step 3: 实现 DrawingModeBar**

```swift
// Sources/KlineTrainerContracts/UI/DrawingModeBar.swift
// 两行画线底栏骨架（1a-iii，D24 一次定型）。上行=类型行（本期只水平线 1 图标、恒亮、无 toggle）；
// 下行=只①类型键（收/展类型行）。②–⑤ 本期不渲染（D19：不 ship 未接线控件）。仅训练/replay 出现。
#if canImport(UIKit)
import SwiftUI

struct DrawingModeBar: View {
    @Binding var typeRowExpanded: Bool
    let onLongPressType: () -> Void          // 长按水平线图标 → 呈现设置卡片（Task 5 接线）

    var body: some View {
        VStack(spacing: 6) {
            if typeRowExpanded {
                typeRow
            }
            bottomRow
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.thinMaterial)
    }

    // 类型行：本期只 1 个水平线图标，恒亮浅蓝框（D38：本期无选中、不做 toggle）。
    private var typeRow: some View {
        HStack(spacing: 12) {
            Button { /* 本期短按 no-op：只有一个工具、已恒选中 */ } label: {
                Image(systemName: "minus")
                    .frame(width: 40, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityLabel("水平线")
            .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in onLongPressType() })
            Spacer()
        }
        .padding(.horizontal, 12)
    }

    // 下行：只①类型键（收/展类型行）。②–⑤ 不渲染。
    private var bottomRow: some View {
        HStack(spacing: 12) {
            Button { typeRowExpanded.toggle() } label: {
                Image(systemName: "list.bullet").frame(width: 40, height: 32)
            }
            .accessibilityLabel("类型")
            Spacer()
        }
        .padding(.horizontal, 12)
    }
}
#endif
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingModeBarSourceGuardTests`
Expected: PASS

- [ ] **Step 5: mutation 验证守卫有效（改坏即红）**

临时把 `accessibilityLabel("类型")` 改成 `accessibilityLabel("锁定")`，跑上面测试 → 应变红（`hasExpectedControls` 失「类型」+ `noUnwiredKeys` 失「锁定」）。确认后改回。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingModeBar.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingModeBarSourceGuardTests.swift
git commit -m "1a-iii Task3：DrawingModeBar 两行底栏骨架（类型行1图标+①类型键，②–⑤不渲染）"
```

---

### Task 4: `DrawingStyleCard` 长按设置卡片

**Files:**
- Create: `Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift`
- Test: `Tests/KlineTrainerContractsTests/Render/DrawingStyleCardSourceGuardTests.swift`

**Interfaces:**
- Produces（`#if canImport(UIKit)`）：
  - `struct DrawingStyleCard: View`，init：`session: DrawingSession`（写 `defaultStyle`）、`scheme: AppColorScheme`（灰态昼夜）、`onDismiss: () -> Void`（点遮罩关）。
  - 4 组控件：线型子类 `[直线][射线][线段]` / 线样式 `[实线][虚线1..4]` / 粗细 5 档 / 颜色 9 色 / 标注 `[隐藏][显示][左][右]`；灰态经 Task 2 判据；每次选择即 `session.setDefaultStyle(...)`。
  - 遮罩：半透明背景 `onTapGesture { onDismiss() }`；卡片本身 `contentShape` 拦截点击不穿透。
- Consumes: `DrawingSession.setDefaultStyle` / `.defaultStyle`（Task 1）；`DrawingStyleAvailability`（Task 2）。

- [ ] **Step 1: 写结构守卫测试（4 组控件在树里 / 无「不适用」文案 / 灰态判据被消费）**

```swift
// Tests/KlineTrainerContractsTests/Render/DrawingStyleCardSourceGuardTests.swift
// Spec: 母 spec §3 / split-addendum §4.1.4 / §4.3-7,8（灰态矩阵 + 面板文案洁净：无「不适用」字）。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingStyleCard 结构守卫：4 组控件 / 灰态判据消费 / 无解释文案")
struct DrawingStyleCardSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let card = "Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift"

    @Test("四组控件标签齐 + 消费灰态判据 + 写 setDefaultStyle")
    func hasGroupsAndWiring() throws {
        let code = try source(card)
        for label in ["线型", "线样式", "粗细", "颜色", "标注"] { #expect(code.contains(label)) }
        #expect(code.contains("DrawingStyleAvailability"))         // 灰态真被消费
        #expect(code.contains("normalizedLabelMode"))              // 切线型真规整 labelMode（codex plan-R1）
        #expect(code.contains("session.setDefaultStyle"))          // 选择真写单一真相
        #expect(code.contains("onDismiss"))                        // 遮罩关闭
    }

    @Test("面板文案洁净：无「不适用」类解释字（母 spec §3 逐字）")
    func noNotApplicableCopy() throws {
        let code = try source(card)
        for banned in ["不适用", "不可用", "N/A", "暂不支持"] { #expect(!code.contains(banned)) }
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingStyleCardSourceGuardTests`
Expected: FAIL —— 文件不存在。

- [ ] **Step 3: 实现 DrawingStyleCard**

```swift
// Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift
// 长按水平线图标弹出的统一设置卡片（1a-iii，母 spec §3）。4 组控件；不可用项只灰、不写任何解释字；
// 昼夜禁色。每次选择即写 DrawingSession.defaultStyle 单一真相（提交路径原子消费，Task 1）。
// 关闭 = 点卡外半透明遮罩（无「完成」钮）。作用对象 = 下一条要画的线（本期无选中，故无歧义）。
#if canImport(UIKit)
import SwiftUI

struct DrawingStyleCard: View {
    let session: DrawingSession
    let scheme: AppColorScheme
    let onDismiss: () -> Void

    // 本地镜像 defaultStyle，改动即回写 session（单一真相）。
    @State private var style: DrawingDefaultStyle

    init(session: DrawingSession, scheme: AppColorScheme, onDismiss: @escaping () -> Void) {
        self.session = session; self.scheme = scheme; self.onDismiss = onDismiss
        _style = State(initialValue: session.defaultStyle)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { onDismiss() }                     // 点遮罩即关
            card
                .contentShape(Rectangle())                       // 卡内点击不穿透到遮罩
                .padding(.horizontal, 12)
        }
    }

    private func commit(_ mutate: (inout DrawingDefaultStyle) -> Void) {
        mutate(&style); session.setDefaultStyle(style)           // 每次选择即写单一真相
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            group("线型") {
                seg(LineSubType.allCases, current: style.lineSubType,
                    enabled: { DrawingStyleAvailability.horizontalLineSubTypeEnabled($0) },
                    title: { subLabel($0) }) { picked in
                        // codex plan-R1-medium：切线型即规整依赖的 labelMode（如直线选『左』后切射线 → 回落 hidden），
                        // 杜绝「显示为灰却仍作默认被提交」的矛盾组合。card 是 setDefaultStyle 唯一写入者 → 规整在此即闭合。
                        commit {
                            $0.lineSubType = picked
                            $0.labelMode = DrawingStyleAvailability.normalizedLabelMode(current: $0.labelMode, lineSubType: picked)
                        }
                    }
            }
            group("线样式") {
                seg(LineStyle.allCases, current: style.lineStyle,
                    enabled: { _ in true }, title: { styleLabel($0) }) { picked in commit { $0.lineStyle = picked } }
            }
            group("粗细") {
                seg(Array(1...5), current: style.thickness,
                    enabled: { _ in true }, title: { "\($0)" }) { picked in commit { $0.thickness = picked } }
            }
            group("颜色") { colorRow }              // codex plan-R3-medium：9 色用色板网格，窄屏自动换行不溢出
            group("标注") {
                seg(LabelMode.allCases, current: style.labelMode,
                    enabled: { DrawingStyleAvailability.horizontalLabelModeEnabled($0, lineSubType: style.lineSubType) },
                    title: { labelLabel($0) }) { picked in commit { $0.labelMode = picked } }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // 一组：标题 + 一排可选项。标题只标组名，绝不写「不适用」。
    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }

    // 通用「一排分段选项」：横向 ScrollView 兜底，窄屏（375pt）任何一档都不会被裁掉/够不到（codex plan-R3-medium）。
    // 灰态由 enabled 决定；灰掉的点击无副作用（.disabled）。
    // enabled/title **必须 @escaping**（codex plan-R8-high）：它们被 ForEach 的**逃逸** ViewBuilder 闭包捕获，
    // 非逃逸参数在此会让 Catalyst/iOS 编译报错（host swift test 不编 #if canImport(UIKit) 体，只有真机门才炸）。
    private func seg<T: Hashable>(_ items: [T], current: T, enabled: @escaping (T) -> Bool,
                                  title: @escaping (T) -> String, pick: @escaping (T) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { item in
                    let on = enabled(item)
                    Button { pick(item) } label: {
                        Text(title(item)).font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(item == current ? Color.accentColor.opacity(0.2) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .disabled(!on)
                    .foregroundStyle(on ? .primary : .secondary)  // 灰＝只降饱和，无解释字
                    .opacity(on ? 1 : 0.4)
                }
            }
        }
    }

    // 颜色行：9 色实心圆板放**自适应网格**，窄屏自动换行到多行、每色都可见可点（不挤在一 HStack 溢出）。
    // 昼夜禁色（白天禁白/夜间禁黑）→ 灰 + .disabled，仍显示色板（不写解释字）。
    private var colorRow: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 8)], spacing: 8) {
            ForEach(DrawingColorToken.allCases, id: \.self) { token in
                let on = DrawingStyleAvailability.colorEnabled(token, scheme: scheme)
                Button { commit { $0.colorToken = token } } label: {
                    Circle().fill(swatchColor(token))
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.accentColor,
                                                 lineWidth: token == style.colorToken ? 3 : 0))
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .disabled(!on)
                .opacity(on ? 1 : 0.3)
                .accessibilityLabel(colorLabel(token))
            }
        }
    }

    // token → SwiftUI Color（复用渲染层同一解析，昼夜一致）。
    private func swatchColor(_ token: DrawingColorToken) -> Color {
        let c = DrawingColorResolver.resolve(token, scheme: scheme)
        return Color(red: c.red, green: c.green, blue: c.blue)
    }

    private func subLabel(_ s: LineSubType) -> String { ["straight":"直线","ray":"射线","segment":"线段"][s.rawValue] ?? s.rawValue }
    private func styleLabel(_ s: LineStyle) -> String { s == .solid ? "实线" : "虚线" + String(s.rawValue.dropFirst(4)) }
    private func labelLabel(_ m: LabelMode) -> String { ["hidden":"隐藏","show":"显示","left":"左","right":"右"][m.rawValue] ?? m.rawValue }
    private func colorLabel(_ c: DrawingColorToken) -> String {
        ["red":"赤","orange":"橙","yellow":"黄","green":"绿","cyan":"青","blue":"蓝","purple":"紫","black":"黑","white":"白"][c.rawValue] ?? c.rawValue
    }
}
#endif
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DrawingStyleCardSourceGuardTests`
Expected: PASS

- [ ] **Step 5: mutation 验证**：临时把 `session.setDefaultStyle` 调用删一处 → `hasGroupsAndWiring` 变红；恢复。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingStyleCardSourceGuardTests.swift
git commit -m "1a-iii Task4：DrawingStyleCard 长按设置卡片（4组控件+灰态+昼夜禁色+遮罩关，写单一真相）"
```

---

### Task 5: TrainingView 集成（入口钮 + 底栏切换 + 退役浮动钮 + 交易边界 + 呈现卡片）

**Files:**
- Create: `Sources/KlineTrainerContracts/UI/TradeConfirmGuard.swift`（confirm 成交纯判据，交易边界）
- Modify: `Sources/KlineTrainerContracts/UI/TrainingView.swift`（谓词 `:69` / 浮动钮 `:186` / 底栏 `:199` / activePanel 高亮 `:425` / 顶栏 `:328` / tradeStrip overlay 挂载 `:401` + onConfirm `:406` / onChange 群 `:234`）
- Test:
  - `Tests/KlineTrainerContractsTests/Render/TradeConfirmGuardTests.swift`（host：画线中确认一律拒绝）
  - `Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift`（谓词拆分 + 退役 + 交易边界结构守卫）
  - `Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift`（**删** 1a-ii 的 `noNewDrawingUI` 守卫，其余守卫保留）

**Interfaces:**
- Consumes: `DrawingModeBar`（Task 3）、`DrawingStyleCard`（Task 4）、`DrawingSession.drawingModeActive`（1a-ii）、`engine.toggleDrawingMode()`（1a-ii）。
- Produces: `TradeConfirmGuard.allowsConfirm(drawingModeActive:periodTickStillValid:)`；新私有谓词 `showsFloatingDrawingTool` / `showsActivePanelHighlight`；`@State private var typeRowExpanded`、`@State private var showingStyleCard`。

- [ ] **Step 1: 写结构守卫测试（谓词拆分 + 浮动钮 review-only + activePanel 保原语义 + 进画线清 tradeStrip）**

```swift
// Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift
// Spec: split-addendum §4.1.1/§4.1.3 + §4.3-1,2,2b（D26/R22-high 交易安全谓词拆分 + 交易边界 R3-high）。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("TrainingView 外壳结构守卫：谓词拆分 / 浮动钮 review-only / 交易边界")
struct TrainingViewShellSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line); guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let tv = "Sources/KlineTrainerContracts/UI/TrainingView.swift"

    @Test("谓词拆成两个：floating=review-only（锚定 body），activePanel 高亮保原语义")
    func predicateSplit() throws {
        let code = try source(tv)
        // 必须锚定 **body 就是 review-only**（codex plan-R8-medium）——否则实现留个 showsTradeButtons||review
        // 的 floating 谓词也能过「名字存在」，训练/replay 浮动钮仍可达 = D26 双入口回归。
        #expect(code.contains("showsFloatingDrawingTool: Bool { engine.flow.mode == .review }"))
        // activePanel 高亮谓词保留 showsTradeButtons（否则训练下丢下单目标高亮）
        #expect(code.contains("showsActivePanelHighlight: Bool { showsTradeButtons || engine.flow.mode == .review }"))
    }

    @Test("浮动钮只受 showsFloatingDrawingTool 门控；DrawingModeBar 只在训练/replay 底栏")
    func floatingRetiredBarWired() throws {
        let code = try source(tv)
        #expect(code.contains("if showsFloatingDrawingTool"))     // 浮动钮 gated review-only
        #expect(code.contains("画图"))                            // 入口钮 label
        // DrawingModeBar 必须挂在「showsTradeButtons → isDrawingActive」分支内（复盘 showsTradeButtons==false
        // → 天然无两行栏，D26/§4.3-1）。锚定其紧邻上文是 isDrawingActive 分支，而非文件任意处（codex plan-R8-medium）。
        let dmb = try #require(code.range(of: "DrawingModeBar("), "DrawingModeBar 未接入")
        let before = String(code[..<dmb.lowerBound].suffix(120))
        #expect(before.contains("if isDrawingActive {"))
    }

    @Test("交易边界：清 tradeStrip + overlay 门控 + onConfirm 经 TradeConfirmGuard.apply（窄锚定）")
    func tradeBoundary() throws {
        let code = try source(tv)
        #expect(code.contains("onChange(of: engine.drawingSession.drawingModeActive)"))
        // onChange 必须**无条件清 tradeStrip**（codex plan-R6/R9-high）——两个方向都清，不能只 `if active`，
        // 否则陈旧 tradeStrip 跨 round-trip 幸存 → 退出后 remount，同 tick/period 下放行旧请求成交。
        // 要求**精确无条件签名** `{ _, _ in`（codex plan-R11-high）：既拒 `_, active in`，也拒
        // `{ _, _ in if engine.drawingSession.drawingModeActive { … } }` 这种换条件的「只进画线清」——
        // 提取闭包体到首个 `}`，断言**根本没有 `if`**（任一 `if` 都意味着条件清，即漏了退出方向）。
        let ocStart = try #require(code.range(of: "onChange(of: engine.drawingSession.drawingModeActive) { _, _ in"),
                                   "onChange 必须是无条件闭包 { _, _ in }（进/出画线都清 tradeStrip）")
        let ocTail = String(code[ocStart.upperBound...])
        let ocEnd = try #require(ocTail.range(of: "}"), "找不到 onChange 闭包结尾")
        let ocBody = String(ocTail[..<ocEnd.lowerBound])
        #expect(ocBody.contains("tradeStrip = nil"))
        #expect(!ocBody.contains("if "))                 // 闭包体无任何条件 → 两个方向都清（不止某个 if 分支）
        // TradeBox overlay 挂载条件带 !drawingModeActive 纵深门控——**锚定到真实挂载条件**
        // （紧跟 showsTradeButtons，即 TradeBoxView 分支），不是文件里某处出现（codex plan-R5-high）。
        #expect(code.contains("showsTradeButtons, !engine.drawingSession.drawingModeActive,"))
        // 窄锚定（codex plan-R3-high）：performTrade 必须包在 apply 的 onProceed 闭包里，
        // 不是「文件里某处出现 apply」——取 onConfirm 起到 performTrade 的片段，断言 apply 在其中且
        // performTrade 出现在 onProceed: 之后（真挂在转换的成交分支上，unused helper 满足不了）。
        // 取 onConfirm 闭包整体（onConfirm: 到它的闭合 `},`），在这个片段里做强断言。
        let confirmStart = try #require(code.range(of: "onConfirm: { shares in"), "找不到 onConfirm 闭包（结构漂移）")
        let after = String(code[confirmStart.upperBound...])
        let confirmEnd = try #require(after.range(of: "},"), "找不到 onConfirm 闭包结尾")
        let body = String(after[..<confirmEnd.lowerBound])
        #expect(body.contains("TradeConfirmGuard.apply("))
        // apply 必须收**真实**的 drawingModeActive（codex plan-R5-high）——防 `drawingModeActive: false`
        // 硬编码/陈旧值绕过：pure 测试与「恰一次」都拦不住这种，唯有断言实参本身。
        #expect(body.contains("drawingModeActive: engine.drawingSession.drawingModeActive"))
        // periodTickStillValid 必须来自**真实** tradeStripStillValid(...)（codex plan-R11-high）——
        // 防硬编码 `periodTickStillValid: true` 复活过期 tick/period 的确认。
        #expect(body.contains("periodTickStillValid: tradeStripStillValid(capturedPeriod: strip.period"))
        // 唯一性 + 位置（codex plan-R4-high）：performTrade 在 onConfirm 里**恰出现一次**，且**就在 onProceed 闭包内**——
        // 杜绝「apply(onProceed:{}) 空转后又无条件 performTrade」的绕过。
        #expect(body.components(separatedBy: "performTrade(").count - 1 == 1)   // 恰一次
        #expect(body.contains("onProceed: { performTrade(strip.action"))       // 那一次就在 onProceed 内
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingViewShellSourceGuardTests`
Expected: FAIL —— 新谓词/字样尚不存在。

- [ ] **Step 2b: 退役 1a-ii 的 `noNewDrawingUI` 守卫（否则全套 swift test 必红，codex plan-R11-high）**

`DrawingSessionSourceGuardTests.swift:127-134` 的 `noNewDrawingUI()` 是 1a-ii「本期不引入任何新 UI」的守卫，含 `#expect(!code.contains("画图"))`——本期 Step 7 加了顶栏「画图」钮，该断言必红。**删除整个 `noNewDrawingUI()` 测试**（它的角色由本期新建的 `TrainingViewShellSourceGuardTests` 全面接替：浮动钮 review-only + 底栏切换 + 交易边界）。

> 注意：删的是这**一个** 1a-ii「无新 UI」守卫；`DrawingSessionSourceGuardTests` 里其余守卫（re-arm 已删 / 切面板不取消画线 / mutator 访问级 / 真机回归守卫等）**全部保留**——它们与 1a-iii 无冲突，是前作回归保护（§4.3-12）。

- [ ] **Step 3: 改谓词（`:69` 附近）——拆成两个**

把 `:69`：

```swift
    private var showsDrawingTools: Bool { showsTradeButtons || engine.flow.mode == .review }
```

替换为：

```swift
    // D26/codex R22-high：原 showsDrawingTools 同时门控浮动钮与 activePanel 高亮 → 拆成两个谓词。
    // 浮动钮只在复盘（训练/replay 改用「画图」钮 + 两行底栏）。
    private var showsFloatingDrawingTool: Bool { engine.flow.mode == .review }
    // activePanel 红框**保留原语义**（showsTradeButtons || review）——绝不可改 review-only，
    // 否则训练/replay 丢掉「当前对哪个面板下单」的唯一提示（下错面板 autosave 不可逆）。
    private var showsActivePanelHighlight: Bool { showsTradeButtons || engine.flow.mode == .review }
```

加两个 `@State`（在 `@State private var tradeStrip` 附近）：

```swift
    @State private var typeRowExpanded = true      // 画线类型行收/展
    @State private var showingStyleCard = false    // 长按设置卡片
```

- [ ] **Step 4: 浮动钮 `:186` 改谓词**

```swift
        .overlay(alignment: .topLeading) {
            if showsFloatingDrawingTool {          // 只复盘（训练/replay 用「画图」钮）
                DrawingToolFloatingView(isDrawingActive: isDrawingActive, onToggleTool: toggleDrawing)
            }
        }
```

- [ ] **Step 5: activePanel 高亮 `:425` 改谓词**

把 `if showsDrawingTools && id == activePanel {` 改为：

```swift
                if showsActivePanelHighlight && id == activePanel {
```

- [ ] **Step 6: 底栏切换 `:199`——drawingModeActive 时用 DrawingModeBar**

把 `if showsTradeButtons { TradeActionBar(...) }` 分支包一层：

```swift
            if showsTradeButtons {
                if isDrawingActive {
                    DrawingModeBar(typeRowExpanded: $typeRowExpanded,
                                   onLongPressType: { showingStyleCard = true })
                } else {
                    TradeActionBar(
                        content: TradeActionBarContent(price: engine.currentPrice),
                        upperPeriod: engine.upperPanel.period,
                        lowerPeriod: engine.lowerPanel.period,
                        activePanel: $activePanel,
                        buyEnabled: engine.buyEnabled,
                        sellEnabled: engine.sellEnabled,
                        holdLabel: engine.position.shares > 0 ? "持有" : "观察",
                        onBuy:  { tradeStrip = TradeStripRequest(panel: activePanel, action: .buy, period: currentPeriod(of: activePanel), tick: engine.tick.globalTickIndex) },
                        onSell: { tradeStrip = TradeStripRequest(panel: activePanel, action: .sell, period: currentPeriod(of: activePanel), tick: engine.tick.globalTickIndex) },
                        onHold: { engine.holdOrObserve(panel: activePanel) })
                }
            } else if showsReviewControls {
```

- [ ] **Step 7: 顶栏入口钮 + 结束↔退出（`:328` 分支）**

把 `if showsTradeButtons { Button("结束"){…} }` 三段分支改为（在 `Spacer()` 与右侧之间，先插「画图」钮，再按 drawingModeActive 决定 结束/退出）：

```swift
                if showsTradeButtons && !isDrawingActive {
                    Button { toggleDrawing() } label: { Image(systemName: "pencil.tip.crop.circle") }
                        .accessibilityLabel("画图")
                    Spacer().frame(width: 28)          // 与「结束」留明显间距，防误点
                }
                if showsTradeButtons {
                    if isDrawingActive {
                        Button("退出") { toggleDrawing() }      // 退出画线（非结束本局）
                            .font(.callout)
                            .accessibilityLabel("退出画线")
                    } else {
                        Button("结束") { confirmingEnd = true }
                            .font(.callout).tint(.red)
                            .accessibilityLabel("结束本局")
                    }
                } else if isReview {
                    Button("结束") {
                        if ReviewEndPrompt.shouldPrompt(netChanged: lifecycle.reviewNetChanged()) {
                            confirmingEndReview = true
                        } else { performReviewEnd(.discard) }
                    }
                    .font(.callout).tint(.red)
                    .accessibilityLabel("结束复盘")
                } else {
                    Color.clear.frame(width: 36, height: 1)
                }
```

> 决策（交互设计未硬性指定，本 plan 定）：**「画图」钮只在未进画线时显示**；进画线后「结束」变「退出」作为**唯一退出**，避免「画图 + 退出」两个出口并存造成困惑。

- [ ] **Step 8: 交易边界——进画线清 tradeStrip（`:234` onChange 群内加一条）**

在现有 `.onChange(of: engine.upperPanel.period)` 那批旁边加：

```swift
        // codex branch-R3-high / plan-R9-high（交易安全）：画线模式**任一方向切换**都作废未确认买卖框。
        // 不只清「进画线」——退出也清：否则一个跨 round-trip 幸存的陈旧 tradeStrip 会在退出后（!drawingModeActive）
        // remount，同 tick/period 下被 TradeConfirmGuard 放行成交。清 nil 恒安全（本就不该跨画线切换留着买卖框）。
        .onChange(of: engine.drawingSession.drawingModeActive) { _, _ in
            tradeStrip = nil
        }
```

- [ ] **Step 8b: 新增 `TradeConfirmGuard` 转换（spy 可测）+ 测试（codex plan-R1/R3-high）**

> 只挡 overlay 挂载不够——若 `drawingModeActive` 在框已挂载后翻转，`onConfirm` 仍会 `performTrade`。把**整个 confirm 转换**（判据 + 是否触发成交）抽成 host 可测函数，`onProceed`（= performTrade）用 spy 断言「画线中零调用」——不靠 source-contains（codex plan-R3-high）。

先写失败测试（**用 performTrade spy 证明画线中绝不成交**）：

```swift
// Tests/KlineTrainerContractsTests/Render/TradeConfirmGuardTests.swift
// Spec: split-addendum §4.1 交易边界（codex branch-R3-high / plan-R1,R3-high）：画线中确认转换绝不触发成交。
import Testing
@testable import KlineTrainerContracts

@Suite("TradeConfirmGuard：画线模式下确认转换绝不成交（performTrade spy）")
struct TradeConfirmGuardTests {
    @Test("apply：画线中即使 period/tick 有效，onProceed（performTrade）零调用")
    func applyBlocksWhileDrawing() {
        var traded = 0
        TradeConfirmGuard.apply(drawingModeActive: true, periodTickStillValid: true,
                                onProceed: { traded += 1 })
        #expect(traded == 0)                                   // 画线中绝不成交
    }
    @Test("apply：非画线+有效 → onProceed 触发一次；非画线+失效 → 不再触发")
    func applyNormalPaths() {
        var traded = 0
        TradeConfirmGuard.apply(drawingModeActive: false, periodTickStillValid: true,
                                onProceed: { traded += 1 })
        #expect(traded == 1)
        TradeConfirmGuard.apply(drawingModeActive: false, periodTickStillValid: false,
                                onProceed: { traded += 1 })
        #expect(traded == 1)                                   // 失效未再增
    }
    @Test("allowsConfirm 判据：画线→false，非画线+有效→true")
    func predicate() {
        #expect(!TradeConfirmGuard.allowsConfirm(drawingModeActive: true, periodTickStillValid: true))
        #expect(TradeConfirmGuard.allowsConfirm(drawingModeActive: false, periodTickStillValid: true))
    }
}
```

Run: `cd ios/Contracts && swift test --filter TradeConfirmGuardTests` → FAIL（未定义）。再实现：

```swift
// Sources/KlineTrainerContracts/UI/TradeConfirmGuard.swift
// 买卖确认转换（host 可测，非 View）。交易边界：画线模式下一律不成交（codex plan-R1/R3-high）——
// 即便 TradeBox 因时序仍挂着，onConfirm 也必须经 apply 拒绝，防不可逆成交 + autosave。
public enum TradeConfirmGuard {
    public static func allowsConfirm(drawingModeActive: Bool, periodTickStillValid: Bool) -> Bool {
        !drawingModeActive && periodTickStillValid
    }
    /// confirm 转换：**仅当** allowsConfirm 才调 onProceed（= performTrade）。
    /// onProceed 用 spy 即可执行断言「画线中零成交」，不必测 SwiftUI 闭包。
    public static func apply(drawingModeActive: Bool, periodTickStillValid: Bool, onProceed: () -> Void) {
        if allowsConfirm(drawingModeActive: drawingModeActive, periodTickStillValid: periodTickStillValid) {
            onProceed()
        }
    }
}
```

Run 同上 → PASS。

- [ ] **Step 9: 交易边界纵深——overlay 挂载 + onConfirm 双门控**

① TradeBox overlay 挂载条件（`:401`）加 `!drawingModeActive`：

```swift
                if showsTradeButtons, !engine.drawingSession.drawingModeActive,
                   let strip = tradeStrip, strip.panel == id {
```

② `onConfirm` 闭包（`:406-415`）改为经 `TradeConfirmGuard.apply`——`onProceed` = performTrade，仅在 allowsConfirm 时触发（`tradeStripStillValid` 结果作为 `periodTickStillValid`）：

```swift
                        onConfirm: { shares in
                            // codex plan-R1/R3-high：confirm transition 走可测 apply——画线中 onProceed(performTrade) 绝不触发。
                            TradeConfirmGuard.apply(
                                drawingModeActive: engine.drawingSession.drawingModeActive,
                                periodTickStillValid: tradeStripStillValid(capturedPeriod: strip.period,
                                                                           currentPeriod: currentPeriod(of: id),
                                                                           capturedTick: strip.tick,
                                                                           currentTick: engine.tick.globalTickIndex),
                                onProceed: { performTrade(strip.action, panel: id, shares: shares) })
                            tradeStrip = nil   // 两条路径都收起买卖框（成交与否都关框）
                        },
```

- [ ] **Step 10: 呈现设置卡片（body 尾部 overlay）**

在 body 的最外层 `.overlay(alignment: .topLeading){…浮动钮…}` 之后追加：

```swift
        .overlay {
            if showingStyleCard {
                DrawingStyleCard(session: engine.drawingSession,
                                 scheme: colorScheme == .dark ? .dark : .light,
                                 onDismiss: { showingStyleCard = false })
            }
        }
```

- [ ] **Step 11: confirm-boundary 覆盖说明（不写 vacuous 行为测试，codex plan-R2-high）**

> **不新增** 只 toggle 画线 + 断言 shares 不变的「行为测试」——它是 vacuous 的：进画线即便不清 `tradeStrip`、或 `onConfirm` 仍成交，它照样绿 → 假信心。宁可没有，也不留假测试。
>
> confirm 成交边界的**可执行判据覆盖** = Step 8b 的 `TradeConfirmGuardTests`（纯函数：`drawingModeActive=true` → 一律拒绝，即便 period/tick 有效；非画线才按有效性放行）——这正是 codex「把 confirm transition 抽成可测函数、别靠 source-contains」的要求，决策逻辑 100% 可执行断言。
>
> View 层接线（`onConfirm` 真调该判据、`guard-else` 清 `tradeStrip`、overlay 挂载门控、进画线 `onChange` 清 `tradeStrip`）是 SwiftUI 闭包，host 单测触不到，由 **Step 1 结构守卫**（断言 `TradeConfirmGuard.allowsConfirm` 与 `!engine.drawingSession.drawingModeActive` 真出现在 onConfirm/overlay）+ **模拟器人工验收**（开买/卖框 → 点「画图」→ 点确认 → 断言**不成交**，见收尾）共同覆盖。

- [ ] **Step 12: 跑全套 + 三绿门**

Run（host）：`cd ios/Contracts && swift test`
Expected: PASS（全绿）

再跑交互设计 §5 的完整三绿门（Catalyst gate.sh + iOS Simulator build + 日志门）。

- [ ] **Step 13: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/TradeConfirmGuard.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/TradeConfirmGuardTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift
git commit -m "1a-iii Task5：TrainingView 集成——画图入口+底栏切换+退役浮动钮(谓词拆分)+交易边界(UI层overlay+onConfirm双门控)+设置卡片+退役 noNewDrawingUI"
```

---

## 收尾（Task 5 后，作者亲核）

- [ ] 跑交互设计 §5 的**三绿门全序列**（host swift test / catalyst-gate.test.sh / Catalyst test+gate.sh / iOS Simulator build+日志门），逐条见绿。
- [ ] **模拟器验收**（不可跳过，1a-ii 血泪）：`xcrun simctl` 装 Debug 构建 + `SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`，按 split-addendum §4.4 的 25 条清单逐条手点，`simctl io <udid> screenshot` 留证。重点盯：进画线底栏升起/结束→退出、双面板画线、副图不落线、长按弹卡、灰态、昼夜禁色、样式往返、复盘仍浮动钮。
- [ ] **续局验收 = 只验「已画的线」的样式，不验默认样式（codex plan-R2-medium 澄清）**：§4.4-23「画几条不同颜色的线→退 App 续局→线连同颜色/线型/粗细/标注全在」验的是**已提交的 `DrawingObject`**（经 autosave 落盘，本就持久）。**「下一条要画的线」的默认样式是 in-memory-only、故意不落盘**（spec §4.1.4「整局有效不落盘」；持久化全局默认属 P6 §13）→ **进程被系统杀掉后回落 `DrawingDefaultStyle()` 是设计行为、不是缺陷**，不写「默认样式跨重启存活」这类验收项（本期无素材、也非需求）。
- [ ] **窄屏布局验收（codex plan-R3-medium）**：在**最窄支持机型**（iPhone SE / 375pt）模拟器上打开设置卡片 → 颜色行 9 个色板 `LazyVGrid` 自动换行、**全部可见可点**，无裁切/够不到；其余控件行横向可滚动不溢出。
- [ ] 交易边界人工验收（codex plan-R6-high）：① 开买/卖框 → 点画图 → 确认框消失且点不了；② 开买/卖框 → 进画线 → **不动 tick/周期直接退出画线** → 旧买卖框**不得自己重现、也不得成交**（证明进画线已把 `tradeStrip` 清掉，而非只是隐藏）。
- [ ] 非程序员验收清单（split-addendum §4.4 全 25 条）随 PR 交付。

## 验收准入（future exit criteria）

> 本分支目前只含设计文档 + 本计划、零实现代码。以下是**实现 PR 合并前**必须满足的准入条件，评审须见真实测试 + 三绿门日志方可判定满足。

**split-addendum §4.3 的 12 条负向测试逐条覆盖映射**（✅=本 plan 新落 / 🔁=既有测试回归保护）：

| # | §4.3 条目 | 覆盖 |
|---|---|---|
| 1 | 复盘无两行底栏、浮动钮仍在 | ✅ Task5 `floatingRetiredBarWired`（浮动钮 review-only）+ DrawingModeBar 嵌于 `showsTradeButtons` 分支（复盘 `showsTradeButtons==false` → 天然无） |
| 2 | 训练/replay 无浮动钮 | ✅ Task5 `floatingRetiredBarWired`（`if showsFloatingDrawingTool`） |
| 2b | activePanel 高亮未被抹 | ✅ Task5 `predicateSplit`（保 `showsTradeButtons \|\| review`） |
| 3 | 类型行只 1 图标 | ✅ Task3 `hasExpectedControls` |
| 4 | 下行只①类型键、②–⑤不在树 | ✅ Task3 `noUnwiredKeys` |
| 5 | 退出后单击不落锚 | 🔁 `handleDrawingTap:274` guard `drawingModeActive` + `DrawingSessionTests`「未激活→commitPending nil」+ `ChartContainerViewDrawingSessionTests` |
| 6 | 副图不可画 | 🔁 **既有** `DefaultDrawingInputControllerTests:50`（点 mainChartFrame 下方→nil）——不重复造 |
| 7 | 面板灰态矩阵 | ✅ Task2 `DrawingStyleAvailabilityTests`（判据逐格）+ Task4 `.disabled`（灰掉无副作用） |
| 8 | 面板文案洁净（无「不适用」） | ✅ Task4 `noNotApplicableCopy` |
| 9 | 样式往返（autosave 重载五字段相等，训练+replay） | ✅ Task1 `styledDrawingSurvivesSaveProgress`（训练**端到端**：defaultStyle→commitPending→routeDrawingCommit→saveProgress→读回 pending）+ `replayStyledDrawing_survivesSaveAndResume`（replay **端到端**：replay→提交→saveProgress→读回 PendingReplay，含 clean-skip+lossy 调和）+ `defaultStyleFlowsIntoCommit` + 🔁 `DrawingModelP1aTests:45` |
| 10 | `routeDrawingCommit` 全字段存活 | 🔁 既有 P1a + `TrainingEngineDrawingCommitTests`（回归保护） |
| 11 | 默认值只作用新线 | ✅ Task1 `defaultChangeAffectsOnlyNextLine` |
| 12 | 前作回归（1a-i/1a-ii 全绿） | 🔁 Task5 后 `swift test` 全绿 + 三绿门 |

**本 design 额外新增负向测试**（超出 §4.3 原 12 条，codex design/plan review 逼出）：
- 原子样式落盘（Task1 `defaultStyleFlowsIntoCommit`：样式原子构造、append 前灌满）。
- 交易边界（Task5 `TradeConfirmGuardTests` 纯判据「画线中拒绝确认」+ `TrainingViewShellSourceGuardTests.tradeBoundary` 结构守卫「overlay+onConfirm 双门控 + 进画线清 tradeStrip」+ 模拟器人工验收「开框→画图→确认→不成交」；**不写 vacuous 行为测试**，codex plan-R2）。
- 依赖字段规整（Task2 `normalizeLabelOnSubtypeChange`：选『左』后切『射线』→ labelMode 回落 hidden，矛盾组合进不来）。

**§4.4 的 25 条非程序员验收清单**随实现 PR 交付。
