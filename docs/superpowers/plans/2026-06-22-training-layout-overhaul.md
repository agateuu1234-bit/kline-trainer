# RFC-B 训练界面布局总重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把训练界面布局对齐主流股票软件、最大化 K 线显示区，且不改任何交易/引擎行为。

**Architecture:** 纯 iOS 表现层重构（SwiftUI 壳 + UIKit 绘制薄层）。新增**只读访问器**（`currentPrice` 放开 public、coordinator `activeRecord` 留存已加载 record）零行为零新 I/O；顶栏/坐标轴/曲线/画线/交易控件分 7 个独立可测任务，每个保持 app 可编译。交易玩法/定价模型不动（留 RFC-A）。

**Tech Stack:** Swift 6 / SwiftUI / UIKit（`#if canImport(UIKit)` gated）/ Swift Testing（host）/ Mac Catalyst build gate。

**权威依据：** spec `docs/superpowers/specs/2026-06-22-training-layout-overhaul-design.md`（R4 APPROVE）；视觉基准 `docs/superpowers/mockups/rfc-b/training-layout-FINAL.html`；决策 `docs/superpowers/mockups/rfc-b/DECISIONS.md`。

## Global Constraints

- **零引擎行为改动**：`engine.buy/sell(panel:tier:)`、`holdOrObserve(panel:)`、`buyEnabled/sellEnabled`、`position.shares/.averageCost`、`forceCloseManually()`、`flow.canBuySell()/.canAdvance()/.mode`、`activateDrawingTool(.horizontal,panel:.upper)`/`cancelDrawing(panel:.upper)` 调用语义**字节级不变**（spec §3）。
- **不 bump `CONTRACT_VERSION`**（现 "1.6"，`Models.swift:7`）：0 DDL / 0 持久化 / 0 序列化 / 0 新磁盘 I/O（spec §11）。
- **定价不变**：买卖价仍 = 全局 `currentPrice`（`.m3` @ globalTick）；不做 per-period 价（spec §5，留 RFC-A）。
- **红涨绿跌**（A 股习惯，现有 `candleUp`=红 / `candleDown`=绿）。
- **UIKit gated**：触 SwiftUI/UIKit 的文件包在 `#if canImport(UIKit)`，host 不编译 → 靠 Catalyst build 闸门；纯值类型/几何放可 host 编译处。
- **线宽目标**（spec §4.4，§10#5 据此判定）：MA66 = `2/displayScale`、BOLL 三轨 = `1.6/displayScale`、MACD DIF/DEA = `1.8/displayScale`。
- **浮点等比 host 断言用容差**；负向 grep 断言用 `if/exit 1` 非 `! grep`。
- **每任务结束**：`swift test`（host）绿 + 提交；视图任务额外要求 Catalyst build 绿（subagent 跑或在任务尾声标注）。

---

### Task 1: 只读访问器（currentPrice public + coordinator.activeRecord）

支撑顶栏标的名（D5）与 T2 下单价（D10）；纯只读、零行为、零新 I/O。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:256`（`currentPrice` 放开 public）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（加 `activeRecord` 存储 + 4 处 start 路径赋值）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift`（透出 `activeRecord`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/`（coordinator 测试套，复用既有 review/replay/normal 测试 harness）

**Interfaces:**
- Produces: `engine.currentPrice: Double`（public 只读）；`coordinator.activeRecord: TrainingRecord?`（public private(set)）；`lifecycle.activeRecord: TrainingRecord?`（computed 透出）。Task 2/6/7 消费。

- [ ] **Step 1: 放开 `currentPrice` 访问级**

`TrainingEngine.swift:256`，把：
```swift
    private var currentPrice: Double {
```
改为：
```swift
    public var currentPrice: Double {
```
（仅访问级；computed 体不变 → 零行为。）

- [ ] **Step 2: coordinator 加 `activeRecord` 存储**

`TrainingSessionCoordinator.swift`，在现有 `public private(set) var activeEngine`/`activeReader` 旁（约 :30-31）加：
```swift
    /// RFC-B D5：review/replay 留存「已 loadRecordBundle 到内存」的 record（零新 I/O），供顶栏标的名。
    /// normal/resume 路径置 nil（盲测占位）。
    public private(set) var activeRecord: TrainingRecord?
```

- [ ] **Step 3: 4 处 start 路径赋值 activeRecord**

`review(recordId:)` 成功块（约 :267-272，与 `activeReader = reader` 同处）加：
```swift
            activeRecord = record            // RFC-B D5：复用已加载 record（:245）
```
`replay(recordId:)` 成功块（约 :304-305，与 `activeReader = reader` 同处）加：
```swift
            activeRecord = record            // RFC-B D5：复用已加载 record（:283），原本被丢弃
```
`startNewNormalSession(...)` 与 `resumePending(...)` 的成功块（各自设 `activeEngine` 处）加：
```swift
            activeRecord = nil               // RFC-B D5：盲测训练隐藏标的名
```

- [ ] **Step 4: lifecycle 透出 activeRecord**

`TrainingSessionLifecycle.swift`，在 `coordinator` 属性下加 computed：
```swift
    /// RFC-B D5：当前局的 record（review/replay 非 nil；normal/resume 为 nil → 盲测占位）。只读。
    public var activeRecord: TrainingRecord? { coordinator.activeRecord }
```

- [ ] **Step 5: 写失败测试（activeRecord 赋值）**

在 coordinator 测试套新增（复用该套已有 review/normal 用例的 fake repo / reader 构造；参照同文件既有 `review(recordId:)` 成功用例的 setup）：
```swift
@Test func activeRecord_setAfterReview_nilAfterNormal() async throws {
    // GIVEN：复用既有 review 成功用例的 coordinator + 一个已知 stockName 的 record fixture
    let coordinator = makeCoordinatorWithReviewableRecord(stockName: "测试股", stockCode: "600000")  // 见同套既有 helper
    _ = try await coordinator.review(recordId: knownRecordId)
    #expect(coordinator.activeRecord?.stockName == "测试股")
    #expect(coordinator.activeRecord?.stockCode == "600000")
    // 切正常训练 → 置 nil
    _ = try await coordinator.startNewNormalSession(/* 既有用例参数 */)
    #expect(coordinator.activeRecord == nil)
}
```
> 注：本测试**复用同套既有 review/normal 用例的 fixture helper**（subagent 先读该测试文件顶部 helper 与既有 `review`/`startNewNormalSession` 用例，按相同 setup 构造）。若 helper 名不同，沿用真实名。

- [ ] **Step 6: 跑测试看失败**

Run: `swift test --filter activeRecord_setAfterReview`
Expected: FAIL（`activeRecord` 未定义 / 编译前红 → 实现后转 PASS）

- [ ] **Step 7: 跑全 host 测试**

Run: `swift test`
Expected: PASS（新用例 + 既有套全绿；currentPrice 放开 public 不破坏既有断言）

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingSessionLifecycle.swift ios/Contracts/Tests/KlineTrainerContractsTests/
git commit -m "feat(rfc-b): currentPrice 放开 public + coordinator.activeRecord 只读留存（零行为零新 I/O）"
```

---

### Task 2: 顶栏内容值类型扩展（每股成本 + 股数 + 标的名隐显）

`TrainingTopBarContent` 是平台无关纯值（host 全测）。本任务只改值类型 + 测试，不动视图（视图在 Task 6）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingTopBarContentTests.swift`（既有；扩用例）

**Interfaces:**
- Consumes: Task 1 `lifecycle.activeRecord`（视图层在 Task 6 传入 name/code）。
- Produces: `TrainingTopBarContent(totalCapital:averageCost:shares:returnRate:positionTier:stockName:stockCode:)` → 字段 `totalCapital`/`holdingCostPerShare`/`sharesText`/`position`/`returnRate`/`stockNameDisplay`。Task 6 消费。

- [ ] **Step 1: 写失败测试**

`TrainingTopBarContentTests.swift` 追加（Swift Testing）：
```swift
@Test func perShareCost_usesAverageCost_notTotal() {
    let c = TrainingTopBarContent(totalCapital: 12_840_650, averageCost: 1_683.50,
                                  shares: 200, returnRate: 0.0234, positionTier: 2,
                                  stockName: nil, stockCode: nil)
    #expect(c.holdingCostPerShare == "¥ 1,683.50")   // 每股价位级，非总额
}
@Test func sharesText_grouped_with_unit() {
    let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 9_999_999,
                                  returnRate: 0, positionTier: 5, stockName: nil, stockCode: nil)
    #expect(c.sharesText == "9,999,999 股")           // 7 位千分位 + 单位
}
@Test func sharesZero_costZero() {
    let c = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                  returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
    #expect(c.sharesText == "0 股")
    #expect(c.holdingCostPerShare == "¥ 0.00")
}
@Test func stockName_hiddenWhenNil_shownWhenPresent() {
    let blind = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
    #expect(blind.stockNameDisplay == "训练标的 · 盲测")
    let named = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                      returnRate: 0, positionTier: 0, stockName: "贵州茅台", stockCode: "600519")
    #expect(named.stockNameDisplay == "贵州茅台（600519）")   // 全角括号
}
@Test func totalCapital_8digit_noTruncation() {
    let c = TrainingTopBarContent(totalCapital: 99_999_999, averageCost: 0, shares: 0,
                                  returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil)
    #expect(c.totalCapital == "¥ 99,999,999.00")    // 8 位整数位完整千分位
}
```

- [ ] **Step 2: 跑测试看失败**

Run: `swift test --filter TrainingTopBarContent`
Expected: FAIL（新 init 签名/字段未定义）

- [ ] **Step 3: 改实现**

`TrainingTopBarContent.swift` 替换 struct 体为（保留既有 `currency`/`percent`，新增 `stockNameDisplay`/`sharesText`/`holdingCostPerShare`）：
```swift
public struct TrainingTopBarContent: Equatable, Sendable {
    public let totalCapital: String        // "¥ 99,999,999.00"
    public let holdingCostPerShare: String // 每股成本 "¥ 1,683.50"（RFC-B D4 语义纠正：非总额）
    public let sharesText: String          // "9,999,999 股"
    public let position: String            // "仓位 3/5"
    public let returnRate: String          // "+2.34%"
    public let stockNameDisplay: String    // "贵州茅台（600519）" 或 "训练标的 · 盲测"

    public init(totalCapital: Double, averageCost: Double, shares: Int,
                returnRate: Double, positionTier: Int,
                stockName: String?, stockCode: String?) {
        self.totalCapital = Self.currency(totalCapital)
        self.holdingCostPerShare = Self.currency(averageCost)
        self.sharesText = "\(Self.grouped(shares)) 股"
        self.position = "仓位 \(positionTier)/5"
        self.returnRate = Self.percent(returnRate)
        if let name = stockName, let code = stockCode {
            self.stockNameDisplay = "\(name)（\(code)）"   // 全角括号，同 formatStock 口径
        } else {
            self.stockNameDisplay = "训练标的 · 盲测"
        }
    }

    /// 整数千分位（POSIX，跨 locale 稳定）。
    private static func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // currency / percent 保持原样（见下，未改）
    private static func currency(_ value: Double) -> String { /* 原实现不变 */ }
    private static func percent(_ rate: Double) -> String { /* 原实现不变 */ }
}
```
> `currency`/`percent` 体保持文件现有实现（仅把 `currency` 复用给每股成本与总资金；不改其 `¥ ` + 千分位 + 2 位口径）。

- [ ] **Step 4: 跑测试看通过**

Run: `swift test --filter TrainingTopBarContent`
Expected: PASS（5 新用例 + 既有套；若既有用例用旧 init 签名，同步更新为新签名）

- [ ] **Step 5: 跑全 host 测试**

Run: `swift test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingTopBarContentTests.swift
git commit -m "feat(rfc-b): 顶栏值类型扩展（每股成本/7位股数/标的名隐显，host 测）"
```

---

### Task 3: 指标曲线加粗加深（MA66/BOLL/MACD）

孤立改 3 个绘制薄层 + Theme dark token；不触 TrainingView。draw 层 UIKit-gated → 验证靠 Catalyst build + 人工 §10#5（无 host 测，如实记录）。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift:36`（MA66）`:54`（BOLL）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift:27`（DIF/DEA）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift:50`（dark `ma66` 提饱和）

- [ ] **Step 1: MA66 线宽 → 2/displayScale**

`KLineView+Candles.swift:36`：`ctx.setLineWidth(1 / mapper.displayScale)` → `ctx.setLineWidth(2 / mapper.displayScale)`

- [ ] **Step 2: BOLL 线宽 → 1.6/displayScale**

`KLineView+Candles.swift:54`：`ctx.setLineWidth(1 / mapper.displayScale)` → `ctx.setLineWidth(1.6 / mapper.displayScale)`

- [ ] **Step 3: MACD DIF/DEA 线宽 → 1.8/displayScale**

`KLineView+MACD.swift:27`：`ctx.setLineWidth(1 / mapper.displayScale)` → `ctx.setLineWidth(1.8 / mapper.displayScale)`

- [ ] **Step 4: dark ma66 提饱和（加深）**

`Theme.swift:50`：
```swift
    public static let ma66            = AppColorRGBA(red: 0.55, green: 0.40, blue: 0.85)
```
→
```swift
    public static let ma66            = AppColorRGBA(red: 0.60, green: 0.42, blue: 0.95)  // RFC-B D7：提饱和
```
> 仅改 dark token（`AppColorTokens`/`AppPalette.dark`）；**light palette 不动**（其前景 token 受 `lightForegroundContrastWCAG` 测约束，改动须重过 WCAG ≥3:1 → 本任务不碰，避免连带）。BOLL/MACD 颜色已足够醒目，仅加粗不改色。

- [ ] **Step 5: 跑全 host 测试（确认无回归）**

Run: `swift test`
Expected: PASS（含 `lightForegroundContrastWCAG` 仍绿，因未动 light token）

- [ ] **Step 6: Catalyst build 验证编译**

Run: `xcodebuild -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift
git commit -m "feat(rfc-b): MA66/BOLL/MACD 曲线加粗(2/1.6/1.8) + dark ma66 提饱和"
```

---

### Task 4: 坐标轴透明无框 + 价轴移左

`AxisGridLayout`（纯值，host 测）改标签矩形坐标；`drawLabelBox`（UIKit 薄层）去底框加阴影。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift`（价/量/MACD 标签 x → 左缘；周期标 → 右上）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift:38-50`（`drawLabelBox` 去底框 + 阴影）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/AxisGridLayoutTests.swift`（既有；扩用例）

- [ ] **Step 1: 写失败测试（标签靠左 / 周期靠右）**

`AxisGridLayoutTests.swift` 追加：
```swift
@Test func priceLabels_anchoredLeft() {
    let mapper = makeMapper(/* 复用既有 priceTicks 用例的 mapper 构造 */)
    let (labels, _) = AxisGridLayout.priceTicks(mapper: mapper)
    let frame = mapper.viewport.mainChartFrame
    #expect(!labels.isEmpty)
    for l in labels { #expect(abs(l.rect.minX - frame.minX) < 0.5) }   // 贴左缘（容差）
}
@Test func periodLabel_anchoredTopRight() {
    let frames = makeFrames(/* 复用既有 periodLabel 用例 */)
    let l = AxisGridLayout.periodLabel(period: .m60, frames: frames)
    #expect(abs(l.rect.maxX - (frames.mainChart.maxX - 4)) < 0.5)      // 贴右缘（pad=4，容差）
}
```
> 复用 `AxisGridLayoutTests.swift` 既有 `priceTicks`/`periodLabel` 用例的 mapper/frames 构造 helper。

- [ ] **Step 2: 跑测试看失败**

Run: `swift test --filter AxisGridLayout`
Expected: FAIL（现价标在右缘 `frame.maxX - labelW`、周期标在左上）

- [ ] **Step 3: 价/量/MACD 标签矩形 → 左缘**

`AxisGridLayout.swift` 三处右缘改左缘：
- `priceTicks` :53 `CGRect(x: frame.maxX - labelW, ...)` → `CGRect(x: frame.minX, y: y - labelH / 2, width: labelW, height: labelH)`
- `volumeAxis` :134 `CGRect(x: frame.maxX - labelW, ...)` → `CGRect(x: frame.minX, y: y, width: labelW, height: labelH)`
- `macdZero` :153 `CGRect(x: frame.maxX - labelW, ...)` → `CGRect(x: frame.minX, y: y - labelH / 2, width: labelW, height: labelH)`

- [ ] **Step 4: 周期标 → 右上**

`AxisGridLayout.swift` `periodLabel` :169：
```swift
        let rect = CGRect(x: frames.mainChart.minX + pad, y: frames.mainChart.minY + pad, width: w, height: h)
```
→
```swift
        let rect = CGRect(x: frames.mainChart.maxX - pad - w, y: frames.mainChart.minY + pad, width: w, height: h)
```

- [ ] **Step 5: 跑测试看通过**

Run: `swift test --filter AxisGridLayout`
Expected: PASS（2 新用例 + 既有 priceTicks/timeTicks/period 用例若断言旧坐标须同步更新）

- [ ] **Step 6: `drawLabelBox` 去底框 + 阴影（透明可读）**

`KLineView+Crosshair.swift:38-50` 替换 `drawLabelBox` 体为：
```swift
    /// RFC-B D1：透明文字、无底框（同花顺式）。去掉 background 实心填充，
    /// 加细阴影防糊在 K 线上不可读。10pt 系统字体，居中。轴标 + crosshair 标共用。
    func drawLabelBox(ctx: CGContext, rect: CGRect, text: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: currentPalette.text,
        ]
        let str = text as NSString
        let size = str.size(withAttributes: attrs)
        let drawX = rect.midX - size.width / 2
        let drawY = rect.midY - size.height / 2
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setShadow(offset: .zero, blur: 2.5, color: currentPalette.background.cgColor)  // 描边式阴影
        str.draw(at: CGPoint(x: drawX, y: drawY), withAttributes: attrs)
    }
```
> 注：`currentPalette.background.cgColor` —— 若 `AppColor` 暴露 `.uiColor`/`.cgColor` 名不同，沿用真实属性（subagent 读 `Theme.swift` 的 UIKit 取色入口）。阴影色用背景色 → 深色主题深背景描边、浅色主题浅背景描边，两主题都增可读对比。

- [ ] **Step 7: Catalyst build**

Run: `xcodebuild -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 8: 跑全 host 测试**

Run: `swift test`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/AxisGridLayout.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift ios/Contracts/Tests/KlineTrainerContractsTests/AxisGridLayoutTests.swift
git commit -m "feat(rfc-b): 价/量/MACD 标签移左缘 + 周期标移右上 + 标签去底框透明加阴影"
```

---

### Task 5: 画线浮动控件（可拖动 + 折叠展开）

新增浮动控件 + 纯 clamp 逻辑（host 测）；TrainingView 移除顶栏画线钮、挂浮动 overlay。行为保留：仍调 `activateDrawingTool(.horizontal,panel:.upper)`/`cancelDrawing(panel:.upper)`。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingToolFloatingView.swift`（视图 + 纯 `DrawingFloatLayout.clampedOffset`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（移除顶栏画线钮 :165-168；挂浮动 overlay）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingFloatLayoutTests.swift`（新建）

**Interfaces:**
- Consumes: `engine.activateDrawingTool/cancelDrawing`、`isDrawingActive`/`toggleDrawing`（TrainingView 既有）。
- Produces: `DrawingToolFloatingView`、`DrawingFloatLayout.clampedOffset(proposed:bounds:size:) -> CGPoint`。

- [ ] **Step 1: 写 clamp 失败测试**

`DrawingFloatLayoutTests.swift`（新建，平台无关，host 可编译——纯几何，**不**包 `#if canImport(UIKit)`，用 CoreGraphics 类型）：
```swift
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Test func clamp_keepsWithinBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
    let size = CGSize(width: 44, height: 44)
    // 拖出右下角 → 回拉到边界内
    let p = DrawingFloatLayout.clampedOffset(proposed: CGPoint(x: 500, y: 900), bounds: bounds, size: size)
    #expect(p.x <= bounds.maxX - size.width)
    #expect(p.y <= bounds.maxY - size.height)
    #expect(p.x >= bounds.minX)
    #expect(p.y >= bounds.minY)
}
@Test func clamp_passesThroughWhenInside() {
    let bounds = CGRect(x: 0, y: 0, width: 390, height: 800)
    let size = CGSize(width: 44, height: 44)
    let p = DrawingFloatLayout.clampedOffset(proposed: CGPoint(x: 100, y: 100), bounds: bounds, size: size)
    #expect(p == CGPoint(x: 100, y: 100))
}
```

- [ ] **Step 2: 跑测试看失败**

Run: `swift test --filter DrawingFloatLayout`
Expected: FAIL（`DrawingFloatLayout` 未定义）

- [ ] **Step 3: 实现纯 clamp + 浮动视图**

`DrawingToolFloatingView.swift`（新建）：
```swift
import CoreGraphics

/// 平台无关纯几何：把拖动后的 proposed 左上角钳制在 bounds 内（控件尺寸 size）。host 可测。
public enum DrawingFloatLayout {
    public static func clampedOffset(proposed: CGPoint, bounds: CGRect, size: CGSize) -> CGPoint {
        let maxX = max(bounds.minX, bounds.maxX - size.width)
        let maxY = max(bounds.minY, bounds.maxY - size.height)
        return CGPoint(x: min(max(proposed.x, bounds.minX), maxX),
                       y: min(max(proposed.y, bounds.minY), maxY))
    }
}

#if canImport(UIKit)
import SwiftUI

/// RFC-B D2：浮动可拖动画线控件。折叠=圆按钮(✎)；点开=工具条（水平线 + 收起）；
/// 拖动整体；仅手动点收起图标才折叠（不自动收）。仅 showsTradeButtons 时由 TrainingView 渲染。
struct DrawingToolFloatingView: View {
    let isDrawingActive: Bool
    let onToggleTool: () -> Void      // 激活/取消水平线（= TrainingView.toggleDrawing）
    @State private var expanded = false
    @State private var offset = CGSize(width: 12, height: 80)
    @State private var dragBase = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            content
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            let proposed = CGPoint(x: dragBase.width + v.translation.width,
                                                   y: dragBase.height + v.translation.height)
                            let clamped = DrawingFloatLayout.clampedOffset(
                                proposed: proposed,
                                bounds: CGRect(origin: .zero, size: geo.size),
                                size: CGSize(width: 160, height: 44))
                            offset = CGSize(width: clamped.x, height: clamped.y)
                        }
                        .onEnded { _ in dragBase = offset }
                )
                .onAppear { dragBase = offset }
        }
    }

    @ViewBuilder private var content: some View {
        if expanded {
            HStack(spacing: 6) {
                Button(isDrawingActive ? "结束画线" : "水平线") { onToggleTool() }
                    .tint(isDrawingActive ? .orange : nil)
                    .accessibilityLabel("水平线")
                Button { expanded = false } label: { Image(systemName: "chevron.left.circle") }
                    .accessibilityLabel("收起画线工具")
            }
            .buttonStyle(.bordered)
            .padding(6)
            .background(.thinMaterial, in: Capsule())
        } else {
            Button { expanded = true } label: { Image(systemName: "pencil.tip.crop.circle") }
                .buttonStyle(.bordered)
                .clipShape(Circle())
                .accessibilityLabel("画线工具")
        }
    }
}
#endif
```

- [ ] **Step 4: 跑 clamp 测试看通过**

Run: `swift test --filter DrawingFloatLayout`
Expected: PASS

- [ ] **Step 5: TrainingView 移除顶栏画线钮 + 挂浮动 overlay**

`TrainingView.swift` topBar 内删除 :165-168 的画线 `if showsTradeButtons { Button(...) }` 块（画线移至浮动控件）。在 `body` 的 root `VStack` 外层加浮动 overlay（gated by showsTradeButtons）：
```swift
        .overlay(alignment: .topLeading) {
            if showsTradeButtons {
                DrawingToolFloatingView(isDrawingActive: isDrawingActive, onToggleTool: toggleDrawing)
            }
        }
```
> 加在 `.toastOverlay(...)`（:145）之后同级链式 modifier。`isDrawingActive`/`toggleDrawing` 既有不动。

- [ ] **Step 6: Catalyst build**

Run: `xcodebuild -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: 全 host 测试**

Run: `swift test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingToolFloatingView.swift ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift ios/Contracts/Tests/KlineTrainerContractsTests/DrawingFloatLayoutTests.swift
git commit -m "feat(rfc-b): 画线改浮动可拖动控件（折叠展开+clamp host 测），移除顶栏画线钮"
```

---

### Task 6: 顶栏视图重构 + 结束本局上移顶栏

TrainingView.topBar 改新 header（返回/标的名/结束药丸 + 5 居中指标格）；删 bottomBar。消费 Task 1 activeRecord + Task 2 content。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（topBar 重构 :148-178；删 bottomBar :298-306 + body :73 引用）

- [ ] **Step 1: 重构 topBar**

`TrainingView.swift` 替换 `topBar`（:148-178）为：
```swift
    private var topBar: some View {
        let rec = lifecycle.activeRecord
        let bar = TrainingTopBarContent(totalCapital: engine.currentTotalCapital,
                                        averageCost: engine.position.averageCost,
                                        shares: engine.position.shares,
                                        returnRate: engine.returnRate,
                                        positionTier: engine.currentPositionTier,
                                        stockName: rec?.stockName, stockCode: rec?.stockCode)
        return VStack(spacing: 6) {
            HStack {
                Button("返回") {
                    guard !exitInFlight else { return }
                    exitInFlight = true
                    Task {
                        defer { exitInFlight = false }
                        do { try await lifecycle.back(); onExit() }
                        catch { backFailed = true }
                    }
                }
                Spacer()
                Text(bar.stockNameDisplay).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if showsTradeButtons {
                    Button("结束") { confirmingEnd = true }
                        .font(.callout).tint(.red)
                        .accessibilityLabel("结束本局")
                } else {
                    // review 模式无结束：占位保持三段对称
                    Color.clear.frame(width: 36, height: 1)
                }
            }
            HStack(spacing: 0) {
                metricCell("总资金", bar.totalCapital, width: 96)
                metricCell("持仓成本/股", bar.holdingCostPerShare, width: 72)
                metricCell("持仓股数", bar.sharesText, width: 86)
                metricCell("仓位", bar.position.replacingOccurrences(of: "仓位 ", with: ""), width: 40)
                metricCell("浮动盈亏", bar.returnRate, width: nil)   // 末格弹性
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// 单个指标格：标签上 / 数值下，居中对称（RFC-B D4）。width=nil → 弹性末格。
    private func metricCell(_ label: String, _ value: String, width: CGFloat?) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12).weight(.semibold)).lineLimit(1)
        }
        .frame(width: width, alignment: .center)
        .frame(maxWidth: width == nil ? .infinity : nil)
    }
```

- [ ] **Step 2: 删 bottomBar + body 引用**

`TrainingView.swift` body（:73）删 `if showsTradeButtons { bottomBar }` 整行（结束已上移顶栏）。删除 `bottomBar`（:298-306）整个 computed property。

- [ ] **Step 3: Catalyst build**

Run: `xcodebuild -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: 全 host 测试**

Run: `swift test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(rfc-b): 顶栏重构（返回/标的名/结束药丸 + 5 居中指标格），结束上移、删 bottomBar"
```

---

### Task 7: T2 底部交易薄条 + active-panel 分段钮

新增 T2 薄条 + 纯内容值类型；TrainingView 删两侧 tradeButtons 列、加 activePanel + T2 条。买卖/持有走既有引擎调用，panel=activePanel。

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeActionBar.swift`（视图 + 纯 `TradeActionBarContent`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（加 `activePanel`、删 panel 内 tradeButtons 列、root 加 T2 条）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TradeActionBarContentTests.swift`（新建）

**Interfaces:**
- Consumes: `engine.currentPrice`（Task 1）、`engine.upperPanel.period`/`lowerPanel.period`、`engine.buyEnabled/sellEnabled`、`engine.position.shares`、既有 `performTrade`/`holdOrObserve`/`tradeStrip`。
- Produces: `TradeActionBar` 视图、`TradeActionBarContent(activePeriod:price:) -> {priceLabel, ...}`、`Period.shortLabel`。

- [ ] **Step 1: 写 content 失败测试**

`TradeActionBarContentTests.swift`（新建，平台无关纯值，host 可编译）：
```swift
import Testing
@testable import KlineTrainerContracts

@Test func priceLabel_neutral_notPerPeriodWording() {
    let c = TradeActionBarContent(price: 1680)
    #expect(c.priceLabel == "下单价 ¥ 1,680.00")   // 中性措辞，不写「日线下单价」
}
@Test func periodShortLabels() {
    #expect(Period.m60.shortLabel == "60分")
    #expect(Period.daily.shortLabel == "日线")
}
```

- [ ] **Step 2: 跑测试看失败**

Run: `swift test --filter TradeActionBarContent`
Expected: FAIL（未定义）

- [ ] **Step 3: 实现 content + Period.shortLabel + T2 视图**

`TradeActionBar.swift`（新建）：
```swift
import Foundation

extension Period {
    /// T2 分段钮短标签（RFC-B D10）。
    public var shortLabel: String {
        switch self {
        case .m3: return "3分"; case .m15: return "15分"; case .m60: return "60分"
        case .daily: return "日线"; case .weekly: return "周线"; case .monthly: return "月线"
        }
    }
}

/// 平台无关纯值：T2 薄条显示串。价 = 全局 currentPrice（中性措辞，非 per-period，RFC-B §5）。host 测。
public struct TradeActionBarContent: Equatable, Sendable {
    public let priceLabel: String
    public init(price: Double) {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal; f.usesGroupingSeparator = true
        f.groupingSeparator = ","; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        let body = f.string(from: NSNumber(value: price)) ?? String(format: "%.2f", price)
        self.priceLabel = "下单价 ¥ \(body)"
    }
}

#if canImport(UIKit)
import SwiftUI

/// RFC-B T2：底部固定薄条。周期分段钮(active 切换) + 中性下单价 + 买/卖/持有。
struct TradeActionBar: View {
    let content: TradeActionBarContent
    let upperPeriod: Period
    let lowerPeriod: Period
    @Binding var activePanel: PanelId
    let buyEnabled: Bool
    let sellEnabled: Bool
    let holdLabel: String           // "持有" / "观察"
    let onBuy: () -> Void
    let onSell: () -> Void
    let onHold: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Picker("下单周期", selection: $activePanel) {
                Text(upperPeriod.shortLabel).tag(PanelId.upper)
                Text(lowerPeriod.shortLabel).tag(PanelId.lower)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
            .accessibilityLabel("下单周期")
            Text(content.priceLabel).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Button("买入", action: onBuy).disabled(!buyEnabled).tint(.red).accessibilityLabel("买入")
            Button("卖出", action: onSell).disabled(!sellEnabled).tint(.green).accessibilityLabel("卖出")
            Button(holdLabel, action: onHold).accessibilityLabel("持有")
        }
        .buttonStyle(.bordered)
        .font(.system(size: 13).weight(.semibold))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.bar)
    }
}
#endif
```

- [ ] **Step 4: 跑 content 测试看通过**

Run: `swift test --filter TradeActionBarContent`
Expected: PASS

- [ ] **Step 5: TrainingView 加 activePanel + 删侧栏 + 挂 T2 条**

`TrainingView.swift`：
1. 加状态：`@State private var activePanel: PanelId = .lower`（与 FINAL mock 高亮一致）。
2. `panel(_:)` 删除 `if showsTradeButtons { tradeButtons(id) }`（:184）；删 `tradeButtons(_:)`（:201-215）整个方法。把 `panel` 改为 active 高亮：
```swift
    private func panel(_ id: PanelId) -> some View {
        ChartContainerView(panel: id, engine: engine)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if showsTradeButtons, let strip = tradeStrip, strip.panel == id {
                    TradeBarView(action: strip.action,
                                 onPick: { tier in performTrade(strip.action, panel: id, tier: tier); tradeStrip = nil },
                                 onCancel: { tradeStrip = nil })
                }
            }
            .overlay {   // active panel 高亮（红描边 inset）
                if showsTradeButtons && id == activePanel {
                    Rectangle().strokeBorder(Color.red.opacity(0.45), lineWidth: 2).allowsHitTesting(false)
                }
            }
    }
```
3. body root（:67-74）末尾把 `if showsTradeButtons { bottomBar }`（已在 Task 6 删）替为 T2 条：
```swift
        VStack(spacing: 0) {
            topBar
            panel(.upper)
            Divider()
            panel(.lower)
            if showsTradeButtons {
                TradeActionBar(
                    content: TradeActionBarContent(price: engine.currentPrice),
                    upperPeriod: engine.upperPanel.period,
                    lowerPeriod: engine.lowerPanel.period,
                    activePanel: $activePanel,
                    buyEnabled: engine.buyEnabled,
                    sellEnabled: engine.sellEnabled,
                    holdLabel: engine.position.shares > 0 ? "持有" : "观察",
                    onBuy: { tradeStrip = TradeStripRequest(panel: activePanel, action: .buy) },
                    onSell: { tradeStrip = TradeStripRequest(panel: activePanel, action: .sell) },
                    onHold: { engine.holdOrObserve(panel: activePanel) })
            }
        }
```
> tradeStrip 悬浮条仍按 `strip.panel == id` 落在 active panel 底部（onBuy/onSell 传 `panel: activePanel`）。买卖/持有引擎调用与原 `performTrade`/`holdOrObserve` 字节一致，仅 `panel` 来源改为 `activePanel`。

- [ ] **Step 6: Catalyst build**

Run: `xcodebuild -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: 全 host 测试**

Run: `swift test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TradeActionBar.swift ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift ios/Contracts/Tests/KlineTrainerContractsTests/TradeActionBarContentTests.swift
git commit -m "feat(rfc-b): T2 底部交易薄条 + active-panel 分段钮（删两侧按钮列），买卖/持有引擎调用不变"
```

---

### Task 8: 整屏验收（模拟器人工 + 装机）

无代码改动任务：跑 spec §10 全 11 条验收（含两图等高、最坏值压测、双主题、画线模式点图仍落 anchor）。

- [ ] **Step 1: 装机**

```bash
xcodebuild -scheme KlineTrainer -destination 'platform=iOS Simulator,id=DE0BA39D-C749-459D-A407-4418599B61CA' build 2>&1 | tail -3
xcrun simctl uninstall DE0BA39D-C749-459D-A407-4418599B61CA com.agateuu1234.KlineTrainer
xcrun simctl install DE0BA39D-C749-459D-A407-4418599B61CA <app-path>
SIMCTL_CHILD_KLINE_SEED_FIXTURE=1 xcrun simctl launch DE0BA39D-C749-459D-A407-4418599B61CA com.agateuu1234.KlineTrainer
```
Expected: `BUILD SUCCEEDED` + app 起。

- [ ] **Step 2: 逐条跑 spec §10 验收清单（#1–#13），每条截图**

Expected: 11 条全 pass（二值判定见 spec §10 表）。任一 fail → 回对应 Task 修。

- [ ] **Step 3: 记录验收证据（截图 + pass/fail）到 PR body**

---

## Self-Review（plan↔spec 覆盖核对）

- spec §3.1.1 currentPrice → Task 1 ✓ / §3.1.2 activeRecord → Task 1 ✓
- §4.2 顶栏(每股成本/股数/名/居中/宽度) → Task 2(值) + Task 6(视图) ✓
- §4.3 轴透明无框+价轴左 → Task 4 ✓
- §4.4 曲线加粗加深 → Task 3 ✓
- §4.5 画线浮动 → Task 5 ✓
- §4.6 T2+active 分段钮 → Task 7 ✓ / §4.6 结束上移 → Task 6 ✓
- §4.1 两图等高/框架 → Task 6+7 root VStack（两 panel maxHeight:.infinity 平分，T2/header 在外）+ §10#2 验收 ✓
- §5 中性「下单价」措辞 → Task 7 content ✓
- §10 验收 → Task 8 ✓
- §11 不 bump → 全任务零持久化改动 ✓
- 已知非范围（per-period 价/含税费/画线 upper-only）→ 不实现，符 spec §9 ✓

**类型一致性核对：** `TrainingTopBarContent` 新 init（Task 2）↔ topBar 调用（Task 6）签名一致；`TradeActionBarContent(price:)` / `Period.shortLabel`（Task 7 定义）↔ TradeActionBar 调用一致；`DrawingFloatLayout.clampedOffset`（Task 5 定义）↔ 视图调用一致；`activePanel: PanelId`（Task 7）↔ TradeActionBar `@Binding` 一致。
