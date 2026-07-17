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
    @Test("默认样式全 5 字段原子流进提交的线")
    func defaultStyleFlowsIntoCommit() {
        let s = DrawingSession()
        s.activate(tool: .horizontal)
        var style = DrawingDefaultStyle()
        style.lineSubType = .ray; style.lineStyle = .dash2
        style.thickness = 3; style.colorToken = .red; style.labelMode = .right
        s.setDefaultStyle(style)
        s.addAnchor(anchor(10), panel: .upper)
        let obj = s.commitPending(panelPosition: 0)
        #expect(obj?.lineSubType == .ray)
        #expect(obj?.lineStyle == .dash2)
        #expect(obj?.thickness == 3)
        #expect(obj?.colorToken == .red)
        #expect(obj?.labelMode == .right)
        #expect(obj?.isExtended == true)          // isExtended 由 lineSubType==.ray 派生（不变量保留）
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
            labelMode: s.labelMode)
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

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift
git commit -m "1a-iii Task1：DrawingSession.defaultStyle 单一真相 + commitPending 原子构造完整线"
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
            group("颜色") {
                seg(DrawingColorToken.allCases, current: style.colorToken,
                    enabled: { DrawingStyleAvailability.colorEnabled($0, scheme: scheme) },
                    title: { colorLabel($0) }) { picked in commit { $0.colorToken = picked } }
            }
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

    // 通用「一排分段选项」：灰态由 enabled 决定；灰掉的点击无副作用（.disabled）。
    private func seg<T: Hashable>(_ items: [T], current: T, enabled: (T) -> Bool,
                                  title: (T) -> String, pick: @escaping (T) -> Void) -> some View {
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
                .foregroundStyle(on ? .primary : .secondary)      // 灰＝只降饱和，无解释字
                .opacity(on ? 1 : 0.4)
            }
        }
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
  - `Tests/KlineTrainerContractsTests/Render/TradeBoundaryTests.swift`（UIKit-gated：进画线不改持仓引擎不变量兜底）

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

    @Test("谓词拆成两个：floating=review-only，activePanel 高亮保原语义")
    func predicateSplit() throws {
        let code = try source(tv)
        #expect(code.contains("showsFloatingDrawingTool"))
        #expect(code.contains("showsActivePanelHighlight"))
        // activePanel 高亮谓词保留 showsTradeButtons（否则训练下丢下单目标高亮）
        #expect(code.contains("showsActivePanelHighlight") && code.contains("showsTradeButtons || engine.flow.mode == .review"))
    }

    @Test("浮动钮只受 showsFloatingDrawingTool 门控；DrawingModeBar 进树")
    func floatingRetiredBarWired() throws {
        let code = try source(tv)
        #expect(code.contains("if showsFloatingDrawingTool"))     // 浮动钮 gated review-only
        #expect(code.contains("DrawingModeBar("))                 // 新底栏接入
        #expect(code.contains("画图"))                            // 入口钮 label
    }

    @Test("交易边界：清 tradeStrip + overlay 门控 + onConfirm 经 TradeConfirmGuard")
    func tradeBoundary() throws {
        let code = try source(tv)
        #expect(code.contains("onChange(of: engine.drawingSession.drawingModeActive)"))
        // TradeBox overlay 挂载条件带 !drawingModeActive 纵深门控
        #expect(code.contains("!engine.drawingSession.drawingModeActive"))
        // onConfirm 提交路径经纯判据（不只挡挂载，防框已挂后 drawingMode 翻转仍成交，codex plan-R1-high）
        #expect(code.contains("TradeConfirmGuard.allowsConfirm"))
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter TrainingViewShellSourceGuardTests`
Expected: FAIL —— 新谓词/字样尚不存在。

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
        // codex branch-R3-high（交易安全）：进画线是交易边界转换——作废任何未确认买卖框，
        // 防「开着买/卖框 → 点画图 → 确认 → engine.buy/sell 不可逆入账」。
        .onChange(of: engine.drawingSession.drawingModeActive) { _, active in
            if active { tradeStrip = nil }
        }
```

- [ ] **Step 8b: 新增 `TradeConfirmGuard` 纯判据 + 测试（confirm 路径守卫，codex plan-R1-high）**

> 只挡 overlay 挂载不够——若 `drawingModeActive` 在框已挂载后翻转，`onConfirm` 闭包仍会 `performTrade`。把「能否成交」抽成 host 可测纯函数，`onConfirm` 与它同源。

先写失败测试：

```swift
// Tests/KlineTrainerContractsTests/Render/TradeConfirmGuardTests.swift
// Spec: split-addendum §4.1 交易边界（codex branch-R3-high / plan-R1-high）：画线模式下确认一律拒绝。
import Testing
@testable import KlineTrainerContracts

@Suite("TradeConfirmGuard：画线模式下买卖确认一律拒绝")
struct TradeConfirmGuardTests {
    @Test("画线中即使 period/tick 有效也拒绝确认")
    func blockedWhileDrawing() {
        #expect(!TradeConfirmGuard.allowsConfirm(drawingModeActive: true, periodTickStillValid: true))
    }
    @Test("非画线：有效→放行，失效→拒绝")
    func normalPaths() {
        #expect(TradeConfirmGuard.allowsConfirm(drawingModeActive: false, periodTickStillValid: true))
        #expect(!TradeConfirmGuard.allowsConfirm(drawingModeActive: false, periodTickStillValid: false))
    }
}
```

Run: `cd ios/Contracts && swift test --filter TradeConfirmGuardTests` → FAIL（未定义）。再实现：

```swift
// Sources/KlineTrainerContracts/UI/TradeConfirmGuard.swift
// 买卖确认准入纯判据（host 可测，非 View）。交易边界：画线模式下一律不成交（codex plan-R1-high）——
// 即便 TradeBox 因时序仍挂着，onConfirm 也必须走这条判据拒绝，防不可逆成交 + autosave。
public enum TradeConfirmGuard {
    public static func allowsConfirm(drawingModeActive: Bool, periodTickStillValid: Bool) -> Bool {
        !drawingModeActive && periodTickStillValid
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

② `onConfirm` 闭包（`:406-415`）改为经 `TradeConfirmGuard` 判据（把原 `tradeStripStillValid` 结果作为 `periodTickStillValid` 传入）：

```swift
                        onConfirm: { shares in
                            // codex plan-R1-high：进画线是交易边界——即便框仍挂着，确认也必须拒绝。
                            let ok = TradeConfirmGuard.allowsConfirm(
                                drawingModeActive: engine.drawingSession.drawingModeActive,
                                periodTickStillValid: tradeStripStillValid(capturedPeriod: strip.period,
                                                                           currentPeriod: currentPeriod(of: id),
                                                                           capturedTick: strip.tick,
                                                                           currentTick: engine.tick.globalTickIndex))
                            guard ok else { tradeStrip = nil; return }
                            performTrade(strip.action, panel: id, shares: shares)
                            tradeStrip = nil
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

- [ ] **Step 11: 写交易边界行为测试（UIKit-gated）**

```swift
// Tests/KlineTrainerContractsTests/Render/TradeBoundaryTests.swift
// Spec: split-addendum §4.1 交易边界（codex branch-R3-high）：进画线作废买卖框、engine.buy/sell 零调用。
#if canImport(UIKit)
import Testing
@testable import KlineTrainerContracts

@Suite("交易边界：进画线作废未确认买卖框")
@MainActor
struct TradeBoundaryTests {
    @Test("进画线前后 shares 不因残留买卖框而变（进画线=交易边界）")
    func enterDrawingIsTradeBoundary() {
        let engine = TrainingEngine.preview()
        let before = engine.position.shares
        // 模拟「已进画线」：drawingModeActive=true 后，任何买卖确认路径都应被门控挡住。
        engine.toggleDrawingMode()
        #expect(engine.drawingSession.drawingModeActive)
        // 画线模式下引擎买卖门控：canBuySell 仍可能 true（交易未结束），但 UI overlay 已被
        // !drawingModeActive 挡住 + tradeStrip 已清 → 无提交路径。此处以引擎不变量兜底：
        #expect(engine.position.shares == before)   // 未经确认路径，持仓不动
    }
}
```

> 说明：confirm 成交路径的**真正判据覆盖**在 Step 8b 的 `TradeConfirmGuardTests`（纯函数，`drawingModeActive=true → 拒绝`）；本 `TradeBoundaryTests` 是引擎侧不变量兜底（进画线不改持仓）。`tradeStrip` 清空与 overlay/onConfirm 接线属 View 层，由 Step 1 结构守卫（含 `TradeConfirmGuard.allowsConfirm` 被消费）+ 模拟器人工验收共同覆盖（见收尾）。

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
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/TradeBoundaryTests.swift
git commit -m "1a-iii Task5：TrainingView 集成——画图入口+底栏切换+退役浮动钮(谓词拆分)+交易边界(overlay+onConfirm双门控)+设置卡片"
```

---

## 收尾（Task 5 后，作者亲核）

- [ ] 跑交互设计 §5 的**三绿门全序列**（host swift test / catalyst-gate.test.sh / Catalyst test+gate.sh / iOS Simulator build+日志门），逐条见绿。
- [ ] **模拟器验收**（不可跳过，1a-ii 血泪）：`xcrun simctl` 装 Debug 构建 + `SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`，按 split-addendum §4.4 的 25 条清单逐条手点，`simctl io <udid> screenshot` 留证。重点盯：进画线底栏升起/结束→退出、双面板画线、副图不落线、长按弹卡、灰态、昼夜禁色、样式往返、退 App 续局样式还在、复盘仍浮动钮。
- [ ] 交易边界人工验收：开买/卖框 → 点画图 → 确认框应消失且点不了。
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
| 9 | 样式往返（autosave 重载五字段相等） | ✅ Task1 `defaultStyleFlowsIntoCommit`（提交产出带样式）+ 🔁 `DrawingModelP1aTests:45`（全字段 Codable 往返）+ `TrainingEngineDrawingCommitTests`（提交路径落盘） |
| 10 | `routeDrawingCommit` 全字段存活 | 🔁 既有 P1a + `TrainingEngineDrawingCommitTests`（回归保护） |
| 11 | 默认值只作用新线 | ✅ Task1 `defaultChangeAffectsOnlyNextLine` |
| 12 | 前作回归（1a-i/1a-ii 全绿） | 🔁 Task5 后 `swift test` 全绿 + 三绿门 |

**本 design 额外新增负向测试**（超出 §4.3 原 12 条，codex design/plan review 逼出）：
- 原子样式落盘（Task1 `defaultStyleFlowsIntoCommit`：样式原子构造、append 前灌满）。
- 交易边界（Task5 `TradeConfirmGuardTests` 纯判据「画线中拒绝确认」+ `TrainingViewShellSourceGuardTests.tradeBoundary` 结构守卫「overlay+onConfirm 双门控」+ `TradeBoundaryTests` 引擎不变量 + 模拟器人工验收）。
- 依赖字段规整（Task2 `normalizeLabelOnSubtypeChange`：选『左』后切『射线』→ labelMode 回落 hidden，矛盾组合进不来）。

**§4.4 的 25 条非程序员验收清单**随实现 PR 交付。
