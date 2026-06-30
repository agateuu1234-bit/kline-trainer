# tap-anywhere 退光标 + RFC-E 设置 popover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让十字光标显示时轻点任一图表区域即退光标（含两图互点、drawing 图），并把首页设置齿轮从底部 sheet 改为锚定齿轮的 popover。

**Architecture:** 两件纯 view/手势层小事。F1 抽一个平台无关纯函数 `CrosshairTapResolver`（tap 归属 + sync 退出决策），UIKit 手势壳（`ChartGestureArbiter`）与 Coordinator（`ChartContainerView`）调它；复用 RFC-C 已 merged 的共享 `crosshairOwner`。F2 把 `HomeView` 齿轮挂原生 `.popover`（保 `HomeView` 非泛型 concrete + `AnyView` 类型擦除注入内容），`AppRootView` 桥接 `router.activeModal` 的 settings 态（经 `isSettings` 谓词）为 popover binding，`HistoryDialogPresentation` 滤 `.settings` 出共享 sheet。

**Tech Stack:** Swift 6 / SwiftUI + UIKit（`#if canImport(UIKit)`）/ Swift Testing（host）/ Mac Catalyst build-for-testing + iOS Simulator build（壳层闸门）。Spec：`docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md`。

## Global Constraints

- 零引擎 / 持久层 / 契约改动；**不 bump CONTRACT_VERSION（保持 1.7）**。
- **保 public API 源 + 行为 + 类型标识兼容**：不删任何现有 public 符号（`ChartGestureArbiter.onTap`/`onCrosshairExit` 保留且 drawing 锚点仍 fire `onTap`）；不给现有 init 加必填参；`HomeView` 保持 `public struct HomeView: View` **非泛型 concrete**，新内容走 `AnyView` 类型擦除 + 新泛型 init；F1 仅**新增** optional 谓词 `onShouldExitRemoteCrosshair`。
- **纯函数平台无关** → host swift test 全测；UIKit/SwiftUI 壳层 → Catalyst 编译闸门 + 真机验收。
- tap-anywhere 覆盖范围 = **两图表区域内任一处**（**不加**全屏 tap 捕获层）。
- **popover 布局契约（强制）**：内容包 `ScrollView` + `maxHeight` 有界 + 下载/恢复/reset 状态可见不裁剪 + 最坏机型（`loadError`+下载状态同现）全部可滚动可达。
- **reset 成功后清 `router.activeModal`** 收 popover；失败不清、保留供重试。
- `AppRouter.Modal` 仅 `Identifiable` **非 Equatable** → 一律用 `if case .settings = …` 谓词，**不可** `== .settings`。
- 负向 grep 断言用 `if/exit 1` 非 `! grep`。
- 验收/acceptance 文档用中文 + action/expected/pass-fail（非 coder 可执行）。

---

### Task 1: `CrosshairTapResolver` 平台无关纯函数 + host 测

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/CrosshairTapResolver.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/CrosshairTapResolverTests.swift`

**Interfaces:**
- Consumes: `PanelId`（`Models/Models.swift`，`public enum PanelId: Equatable, Sendable { case upper, lower }`）。
- Produces（Task 2 依赖）：
  - `CrosshairTapResolver.resolve(localCrosshairMode: Bool, drawingMode: Bool, remoteOwnerPresent: Bool) -> CrosshairTapOutcome`
  - `CrosshairTapResolver.resolveSyncExit(incomingOwner: PanelId?, previousOwner: PanelId?, panel: PanelId, crosshairActive: Bool) -> CrosshairSyncExit`
  - `enum CrosshairTapOutcome: Equatable { case exitLocal, requestGlobalExit, drawingAnchor, noop }`
  - `enum CrosshairSyncExit: Equatable { case none, exitTakenOver, exitOwnerCleared }`

- [ ] **Step 1: 写失败测试**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/CrosshairTapResolverTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/CrosshairTapResolverTests.swift
// Spec: docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md §2.1 纯函数 + §4
// 平台无关纯函数红绿覆盖：tap 归属真值表 + sync 退出决策（含 standalone 持久性回归守门）。
import Testing
@testable import KlineTrainerContracts

@Suite("CrosshairTapResolver decisions")
struct CrosshairTapResolverTests {

    // MARK: - resolve（tap 归属，顺序：exitLocal > requestGlobalExit > drawingAnchor > noop）

    @Test("localCrosshairMode=true → exitLocal（无视 drawing/remote）")
    func localOwnerExitsLocal() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: true, drawingMode: true, remoteOwnerPresent: true) == .exitLocal)
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: true, drawingMode: false, remoteOwnerPresent: false) == .exitLocal)
    }

    @Test("remoteOwnerPresent=true（非本地）→ requestGlobalExit（先于 drawing，spec-R3-M1）")
    func remoteOwnerExitsGlobalBeforeDrawing() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: true, remoteOwnerPresent: true) == .requestGlobalExit)
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: false, remoteOwnerPresent: true) == .requestGlobalExit)
    }

    @Test("无远端光标 + drawing → drawingAnchor（onTap 行为接线，spec-R5-H1）")
    func drawingNoRemoteAnchors() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: true, remoteOwnerPresent: false) == .drawingAnchor)
    }

    @Test("普通态（全 false）→ noop")
    func idleNoop() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: false, remoteOwnerPresent: false) == .noop)
    }

    // MARK: - resolveSyncExit（sync 退出决策）

    @Test("被另一面板接管 → exitTakenOver")
    func takenOver() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: .upper, previousOwner: .lower, panel: .lower, crosshairActive: true) == .exitTakenOver)
    }

    @Test("self→nil 跃迁 → exitOwnerCleared（tap-anywhere）")
    func ownerCleared() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: nil, previousOwner: .upper, panel: .upper, crosshairActive: true) == .exitOwnerCleared)
    }

    @Test("standalone 恒 nil → none（黏滞光标持久性回归守门，spec-R2-M1）")
    func standalonePersists() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: nil, previousOwner: nil, panel: .upper, crosshairActive: true) == .none)
    }

    @Test("crosshairActive=false → none（无活动光标不退）")
    func inactiveNone() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: .upper, previousOwner: .lower, panel: .lower, crosshairActive: false) == .none)
    }
}
```

- [ ] **Step 2: 运行测试确认失败（未定义）**

Run: `swift test --package-path ios/Contracts --filter CrosshairTapResolverTests`
Expected: 编译失败 / FAIL — `cannot find 'CrosshairTapResolver' in scope`。

- [ ] **Step 3: 写最小实现**

创建 `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/CrosshairTapResolver.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/CrosshairTapResolver.swift
// Spec: docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md §2.1
// 平台无关纯决策（host 全测）：tap 归属 + sync 退出。无 UIKit 依赖——ChartGestureArbiter（UIKit 壳）/
// ChartContainerView（Coordinator）调它（沿 GestureClassifiers 纯函数 + UIKit 壳一贯模式）。
import Foundation

/// 一次 tap 的归属（顺序即优先级：本地退 > 退远端光标 > drawing 锚点 > 无操作）。
public enum CrosshairTapOutcome: Equatable {
    case exitLocal          // 本 panel 持光标 → onCrosshairExit
    case requestGlobalExit  // 别的面板持光标 → 退之（onCrosshairExit 清 owner → 持有面板 self→nil 自退）
    case drawingAnchor      // 无光标 + 本 panel drawing → onTap 落锚点
    case noop               // 普通态 → 无操作
}

/// sync 时本 panel 是否应退出黏滞光标。
public enum CrosshairSyncExit: Equatable {
    case none
    case exitTakenOver      // 被另一面板接管
    case exitOwnerCleared   // 本面板曾持有、owner 被清（tap-anywhere）
}

public enum CrosshairTapResolver {

    /// tap 归属。`remoteOwnerPresent` = 本面板视角「有别的面板持光标」（arbiter 经注入谓词得到；
    /// 直接消费者未注入谓词 → 传 false → 退化旧真值表逐格等价）。
    public static func resolve(localCrosshairMode: Bool, drawingMode: Bool, remoteOwnerPresent: Bool) -> CrosshairTapOutcome {
        if localCrosshairMode { return .exitLocal }
        if remoteOwnerPresent { return .requestGlobalExit }  // **先于** drawing（spec-R3-M1）
        if drawingMode { return .drawingAnchor }
        return .noop
    }

    /// sync 退出决策。owner==nil 退出**门控在 self→nil 跃迁**（`previousOwner==panel`）——
    /// standalone（`crosshairOwner=.constant(nil)`）下 owner/previousOwner 恒 nil → 永不退、黏滞光标保留（spec-R2-M1）。
    public static func resolveSyncExit(incomingOwner: PanelId?, previousOwner: PanelId?,
                                       panel: PanelId, crosshairActive: Bool) -> CrosshairSyncExit {
        guard crosshairActive else { return .none }
        if let owner = incomingOwner, owner != panel { return .exitTakenOver }
        if incomingOwner == nil, previousOwner == panel { return .exitOwnerCleared }
        return .none
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `swift test --package-path ios/Contracts --filter CrosshairTapResolverTests`
Expected: PASS（8 测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/CrosshairTapResolver.swift ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/CrosshairTapResolverTests.swift
git commit -m "feat(crosshair): CrosshairTapResolver 纯函数 + host 测（tap 归属 + sync 退出）"
```

---

### Task 2: F1 tap-anywhere 手势接线（arbiter + Coordinator）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift`（新增 `onShouldExitRemoteCrosshair` public var ~第 40 行；重写 `handleTap` ~第 209-215 行）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`（新增 `lastSyncedOwner` 成员 ~第 70 行；`sync()` 跨面板退出改用 `resolveSyncExit` ~第 86-89 行 + 末尾刷新；`attach()` 注入谓词 ~第 149 行后）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/PublicGestureSurfaceTests.swift`（追加 UIKit-gated 公共面编译守卫）

**Interfaces:**
- Consumes: `CrosshairTapResolver.resolve` / `resolveSyncExit`（Task 1）；既有 `onCrosshairExit`/`onTap`/`crosshairMode`/`drawingMode`（arbiter）、`crosshairActive`/`setCrosshairOwner`/`exitCrosshair`/`isDrawing`（Coordinator）。
- Produces: arbiter 新 public 符号 `var onShouldExitRemoteCrosshair: (() -> Bool)?`。

- [ ] **Step 1: arbiter 新增 `onShouldExitRemoteCrosshair` public 声明**

在 `ChartGestureArbiter.swift` 现有回调声明区（`onCrosshairExit` 之后，约第 39 行后）插入：

```swift
    /// RFC-E follow-up（tap-anywhere）：本面板**非持有**光标时，是否有「别的面板」持光标。
    /// Coordinator 注入（读共享 crosshairOwner）。未注入（直接消费者）→ 视为 false → 退化旧 tap 行为（源/行为兼容）。
    public var onShouldExitRemoteCrosshair: (() -> Bool)?
```

- [ ] **Step 2: 重写 `handleTap` 用 resolver（onTap 仍为 drawing 锚点 fire）**

把 `ChartGestureArbiter.swift` 现有 `handleTap`（约第 209-215 行）：

```swift
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        if crosshairMode { onCrosshairExit?(); return }   // RFC-C：光标模式点击退出
        guard drawingMode else { return }                  // 仅 Drawing 模式确定锚点
        onTap?(g.location(in: g.view))
    }
```

替换为：

```swift
    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        // tap-anywhere：远端光标存在时优先退（先于 drawing，spec-R3-M1）；onTap 仍为 drawing 锚点回调（spec-R5-H1）。
        switch CrosshairTapResolver.resolve(localCrosshairMode: crosshairMode,
                                            drawingMode: drawingMode,
                                            remoteOwnerPresent: onShouldExitRemoteCrosshair?() ?? false) {
        case .exitLocal, .requestGlobalExit: onCrosshairExit?()              // 本地退 / 退远端：均经 onCrosshairExit
        case .drawingAnchor:                 onTap?(g.location(in: g.view))  // drawing 锚点：行为不变
        case .noop:                          break
        }
    }
```

- [ ] **Step 3: Coordinator 新增 `lastSyncedOwner` 成员**

在 `ChartContainerView.swift` Coordinator 成员区（`setCrosshairOwner` 之后，约第 70 行后）插入：

```swift
        /// RFC-E follow-up（tap-anywhere）：上一次 sync 观察到的共享 owner（供 self→nil 跃迁判定 + 谓词读）。
        private var lastSyncedOwner: PanelId?
```

- [ ] **Step 4: `sync()` 跨面板退出改用 `resolveSyncExit` + 末尾刷新 `lastSyncedOwner`**

把 `ChartContainerView.swift` `sync()` 内现有跨面板互斥块（约第 86-89 行）：

```swift
            // RFC-C 跨面板互斥：另一面板持有光标 → 退出本面板（不释放共享态，对方仍持有）。
            if let owner = crosshairOwner, owner != panel, crosshairActive {
                exitCrosshair(releaseOwnership: false)
            }
```

替换为：

```swift
            // RFC-C 跨面板互斥 + RFC-E tap-anywhere 对称退出（纯函数决策，含 standalone 黏滞持久性门控）。
            switch CrosshairTapResolver.resolveSyncExit(incomingOwner: crosshairOwner,
                                                        previousOwner: lastSyncedOwner,
                                                        panel: panel, crosshairActive: crosshairActive) {
            case .exitTakenOver, .exitOwnerCleared:
                exitCrosshair(releaseOwnership: false)   // owner 已是对方/nil，本面板仅清自身不重写共享态
            case .none:
                break
            }
            lastSyncedOwner = crosshairOwner             // 末尾刷新：下次 sync 的 previousOwner
```

> 注：保留 `sync()` 内既有 `if drawing && crosshairActive { … }`（约第 92-96 行）不动——同 panel drawing×crosshair 互斥仍走该块；本 switch 在其之前执行，若已退则后续 `crosshairActive==false` 不重复触发。`lastSyncedOwner` 刷新放在 switch 之后、drawing 块之前或之后均可（owner 值同帧不变），按上文置于 switch 后。

- [ ] **Step 5: `attach()` 注入谓词**

在 `ChartContainerView.swift` `attach()` 内 `arbiter.onCrosshairExit = { … }`（约第 147-149 行）之后插入：

```swift
            arbiter.onShouldExitRemoteCrosshair = { [weak self] in
                self?.lastSyncedOwner != nil          // 本面板非持有时（handleTap 已先排除持有），nil≠ = 别人持光标
            }
```

> `onTap`（约第 154 行 `arbiter.onTap = { handleDrawingTap }`）与 `onCrosshairExit` 接线**保持不变**（行为兼容）。

- [ ] **Step 6: 追加 UIKit-gated 公共面编译守卫**

在 `ios/Contracts/Tests/KlineTrainerContractsTests/PublicGestureSurfaceTests.swift` 末尾追加（证 `onTap`/`onCrosshairExit`/`onShouldExitRemoteCrosshair` 均 public 可设；非-@testable import 已在该文件头）：

```swift

#if canImport(UIKit)
// RFC-E follow-up（tap-anywhere）：arbiter tap 公共面回归保障——
// onTap（drawing 锚点）/onCrosshairExit（退出）保留，新增 onShouldExitRemoteCrosshair（纯加法）。
// 存在即证 public 面完整（codex spec-R4-H1/R5-H1）；Catalyst 编译闸门覆盖。
@MainActor
func crosshairTapPublicSurfaceCompileCheck() {
    let arbiter = ChartGestureArbiter()
    arbiter.onTap = { _ in }
    arbiter.onCrosshairExit = { }
    arbiter.onShouldExitRemoteCrosshair = { false }
}
#endif
```

- [ ] **Step 7: host 编译 + 全量回归（无新可跑壳逻辑，证不破坏）**

Run: `swift test --package-path ios/Contracts`
Expected: 全绿（Swift Testing「末行 0 failures」+ XCTest「All tests passed」），含 Task 1 的 8 测试；无回归。
（注：arbiter/Coordinator 为 UIKit-only，macOS host 编译为空；其手势行为由 Task 1 resolver 测 + 真机验收覆盖，公共面由 Step 6 Catalyst 编译守卫覆盖。）

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift ios/Contracts/Tests/KlineTrainerContractsTests/PublicGestureSurfaceTests.swift
git commit -m "feat(crosshair): tap-anywhere 退光标接线（arbiter handleTap via resolver + Coordinator self→nil 退出 + 谓词注入）"
```

---

### Task 3: `HistoryDialogPresentation` 滤 `.settings` 出 sheet + `isSettings` 谓词

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift`（改 1 既有断言 + 加新断言）

**Interfaces:**
- Consumes: `AppRouter.Modal`（`Identifiable` 非 Equatable）。
- Produces（Task 5 依赖）：`HistoryDialogPresentation.isSettings(_ modal: AppRouter.Modal?) -> Bool`；`sheetItem`/`sheetDismissMayApply` 对 `.settings` 新行为。

- [ ] **Step 1: 改既有测试断言为新契约（红）**

在 `HistoryDialogPresentationTests.swift` 把既有：

```swift
    @Test("sheetItem 对 .settings 原样透传")
    func sheetItemPassesSettings() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settings)?.id == "settings")
    }
```

改为（settings 改由 popover 驱动，滤出 sheet）+ 在其后追加新测试：

```swift
    @Test("sheetItem 对 .settings 返 nil（RFC-E：改由 popover 驱动，滤出共享 sheet）")
    func sheetItemFiltersSettings() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settings) == nil)
    }

    @Test("isSettings 仅对 .settings 为 true")
    func isSettingsPredicate() {
        #expect(HistoryDialogPresentation.isSettings(.settings) == true)
        #expect(HistoryDialogPresentation.isSettings(.history(makeRecord())) == false)
        #expect(HistoryDialogPresentation.isSettings(.settlement(makeRecord())) == false)
        #expect(HistoryDialogPresentation.isSettings(nil) == false)
    }

    @Test("sheetDismissMayApply 对 .settings 返 false（RFC-E：settings 由 popover 驱动，sheet dismiss 回写须拦）")
    func sheetDismissBlocksSettings() {
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .settings) == false)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `swift test --package-path ios/Contracts --filter HistoryDialogPresentationTests`
Expected: FAIL（`sheetItem(.settings)` 仍返非 nil；`isSettings` 未定义）。

- [ ] **Step 3: 改实现**

把 `HistoryDialogPresentation.swift` 的 `sheetItem` 与 `sheetDismissMayApply` 改为，并新增 `isSettings`：

```swift
    /// 共享 `.sheet(item:)` 的 item 过滤：`.history`（居中 overlay）/ `.settings`（RFC-E popover）走 sheet 之外 → 返 nil；
    /// `.settlement` 原样透传。
    public static func sheetItem(for modal: AppRouter.Modal?) -> AppRouter.Modal? {
        if case .history = modal { return nil }
        if case .settings = modal { return nil }   // RFC-E：settings 改由锚齿轮 popover 驱动，滤出共享 sheet 防双弹
        return modal
    }

    /// RFC-E：当前态是否为设置（驱动锚齿轮 popover 呈现 + dismiss 守卫）。
    public static func isSettings(_ modal: AppRouter.Modal?) -> Bool {
        if case .settings = modal { return true }
        return false
    }

    /// High-1 守卫：共享 sheet 的 dismiss 回写是否可生效。
    /// `.history`（居中 overlay）/ `.settings`（RFC-E popover）当前态返 false（二者非 sheet 驱动，其 set(nil) 回写须拦）。
    public static func sheetDismissMayApply(current: AppRouter.Modal?) -> Bool {
        if case .history = current { return false }
        if case .settings = current { return false }   // RFC-E
        return true
    }
```

> `isHistoryPresented` 不变。

- [ ] **Step 4: 运行确认通过**

Run: `swift test --package-path ios/Contracts --filter HistoryDialogPresentationTests`
Expected: PASS（含改后 `sheetItemFiltersSettings` + 新 `isSettingsPredicate` / `sheetDismissBlocksSettings`）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift
git commit -m "feat(settings): HistoryDialogPresentation 滤 .settings 出共享 sheet + isSettings 谓词（RFC-E popover 驱动）"
```

---

### Task 4: `HomeView` 齿轮 popover 锚点（非泛型 concrete + AnyView 擦除 + 新泛型 init）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift`（新建：bare 类型标识守卫）

**Interfaces:**
- Consumes: `HomeContent`（`public init(statistics:(totalCount:Int,winCount:Int,currentCapital:Double), configuredCapital:Double, records:[TrainingRecord], hasPending:Bool, hasCachedSets:Bool, timeZone:TimeZone)`）。
- Produces（Task 5 依赖）：`HomeView` 新增泛型 init `init<SettingsContent: View>(content:onStartTraining:onContinueTraining:onSelectRecord:onOpenSettings:isSettingsPresented:settingsContent:)`；**保留**旧 5 参 init；`HomeView` 仍为非泛型 concrete 类型。

- [ ] **Step 1: 写 bare 类型标识守卫测试（绿基线 = 防泛型化回归）**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift
// Spec: docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md §0/§3.1/§4（codex spec-R6-H1）
// 源兼容守卫：HomeView 必须保持非泛型 concrete 类型 + 旧 5 参 init 可调。
// `let _: HomeView`（bare 类型标识）—— 一旦泛型化为 HomeView<...> 本文件即编译失败。
import SwiftUI
import Testing
@testable import KlineTrainerContracts

@Suite("HomeView source compatibility")
struct HomeViewSourceCompatTests {

    private func makeContent() -> HomeContent {
        HomeContent(statistics: (totalCount: 0, winCount: 0, currentCapital: 100_000),
                    configuredCapital: 100_000, records: [],
                    hasPending: false, hasCachedSets: true, timeZone: .current)
    }

    @Test("HomeView 为 bare concrete 类型 + 旧 5 参 init 可调（codex spec-R6-H1）")
    @MainActor func bareConcreteTypeAndOldInit() {
        let _: HomeView = HomeView(content: makeContent(),
                                   onStartTraining: {}, onContinueTraining: {},
                                   onSelectRecord: { _ in }, onOpenSettings: {})
    }
}
```

- [ ] **Step 2: 运行确认通过（守卫绿基线）**

Run: `swift test --package-path ios/Contracts --filter HomeViewSourceCompatTests`
Expected: PASS（旧 5 参 init + bare 类型今已成立）。

- [ ] **Step 3: HomeView 加类型擦除存储 + 两个 init（保非泛型）**

在 `HomeView.swift` 的存储属性区（`onOpenSettings` 之后，约第 21 行后）加：

```swift
    private let isSettingsPresented: Binding<Bool>
    private let settingsContent: () -> AnyView
```

把现有 5 参 `public init(...)`（约第 25-35 行）**替换**为「旧 5 参委托 + 新泛型」两个 init：

```swift
    /// 源兼容：旧 5 参 init 保留 → 委托泛型 init，不显 popover（codex spec-R4-H1/R6-H1）。
    public init(content: HomeContent,
                onStartTraining: @escaping () -> Void,
                onContinueTraining: @escaping () -> Void,
                onSelectRecord: @escaping (Int64) -> Void,
                onOpenSettings: @escaping () -> Void) {
        self.init(content: content,
                  onStartTraining: onStartTraining, onContinueTraining: onContinueTraining,
                  onSelectRecord: onSelectRecord, onOpenSettings: onOpenSettings,
                  isSettingsPresented: .constant(false), settingsContent: { EmptyView() })
    }

    /// RFC-E：新泛型 init —— 类型擦除 settingsContent → AnyView（仅设置 popover，非热路径）。
    /// HomeView 本体保持非泛型 concrete（类型标识不变）。保 view-only D1：不 import settings/acceptance。
    public init<SettingsContent: View>(content: HomeContent,
                onStartTraining: @escaping () -> Void,
                onContinueTraining: @escaping () -> Void,
                onSelectRecord: @escaping (Int64) -> Void,
                onOpenSettings: @escaping () -> Void,
                isSettingsPresented: Binding<Bool>,
                @ViewBuilder settingsContent: @escaping () -> SettingsContent) {
        self.content = content
        self.onStartTraining = onStartTraining
        self.onContinueTraining = onContinueTraining
        self.onSelectRecord = onSelectRecord
        self.onOpenSettings = onOpenSettings
        self.isSettingsPresented = isSettingsPresented
        self.settingsContent = { AnyView(settingsContent()) }
    }
```

- [ ] **Step 4: 齿轮 Button 挂 popover（含 §3.4 布局契约）**

把 `HomeView.swift` `statsBar` 内齿轮 Button（约第 60-63 行）：

```swift
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.title2)
            }
            .accessibilityLabel("设置")
```

替换为：

```swift
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").font(.title2)
            }
            .accessibilityLabel("设置")
            .popover(isPresented: isSettingsPresented) {
                ScrollView {                                          // 强制布局契约：内容可滚动，最坏情况全部可达（spec §3.4）
                    settingsContent()
                }
                .frame(minWidth: 280, idealWidth: 300, maxWidth: 320, maxHeight: 480)   // **上限宽 320 + 限高 480**：防长标签撑宽（idealWidth 非上限，codex plan-R1-M1）
                .presentationCompactAdaptation(.popover)              // iPhone 强制 popover 样式（iOS16.4+；项目 iOS17 满足）
            }
```

- [ ] **Step 5: 运行 host 测确认守卫仍绿 + 编译通过**

Run: `swift test --package-path ios/Contracts --filter HomeViewSourceCompatTests`
Expected: PASS（HomeView 仍非泛型 concrete、旧 init 仍可调；popover 编译通过）。

- [ ] **Step 6: 全量 host 回归**

Run: `swift test --package-path ios/Contracts`
Expected: 全绿，无回归（2 个 `#Preview` 旧 init 仍编译）。

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/HomeViewSourceCompatTests.swift
git commit -m "feat(settings): HomeView 齿轮挂 popover（非泛型 concrete + AnyView 擦除 + 新泛型 init + 布局契约）"
```

---

### Task 5: `AppRootView` 桥接 popover binding + content（drop `.settings` from sheet）+ reset 收口

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`

**Interfaces:**
- Consumes: `HistoryDialogPresentation.isSettings`（Task 3）；`HomeView` 新泛型 init（Task 4）；`SettingsPanel(settings:api:cache:acceptance:onConfirmReset:)`；`router.resetAllProgressAndReload()` / `router.activeModal`。
- Produces: 设置经锚齿轮 popover 呈现；`.sheet` 仅剩 `.settlement`。

- [ ] **Step 1: 新增 `settingsPopoverBinding`**

在 `AppRootView.swift` 的 `sheetModalBinding`（约第 25-33 行）之后插入：

```swift
    // RFC-E：锚齿轮 popover 的 Bool binding —— 由 HistoryDialogPresentation.isSettings(router.activeModal) 判定（单一真相）。
    // dismiss 回写仅当当前是 settings 才清（守卫防误清已切换到 .settlement/.history 的模态）。
    // 注：Modal 非 Equatable，必须用 isSettings 谓词（禁 == 比较，见全局约束 + Step 4 grep 守卫）。
    private var settingsPopoverBinding: Binding<Bool> {
        Binding(
            get: { HistoryDialogPresentation.isSettings(router.activeModal) },
            set: { newValue in
                if !newValue && HistoryDialogPresentation.isSettings(router.activeModal) {
                    router.activeModal = nil
                }
            }
        )
    }
```

- [ ] **Step 2: HomeView 构造改用新泛型 init（注入 binding + SettingsPanel content + reset 收口）**

把 `AppRootView.swift` body 内 `HomeView(...)`（约第 42-46 行）替换为：

```swift
            HomeView(content: router.homeContent,
                     onStartTraining: { Task { await router.startTraining() } },
                     onContinueTraining: { Task { await router.continueTraining() } },
                     onSelectRecord: { id in router.selectRecord(id: id) },
                     onOpenSettings: { router.openSettings() },
                     isSettingsPresented: settingsPopoverBinding,
                     settingsContent: {
                        SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance,
                                      onConfirmReset: {
                                          try await router.resetAllProgressAndReload()
                                          router.activeModal = nil   // RFC-E：reset 成功 → 收 popover（spec-R1-M1 / A_reset_dismiss）
                                      })
                     })
```

- [ ] **Step 3: `.sheet` 去掉 `.settings` 分支（仅剩 `.settlement`）**

把 `AppRootView.swift` 的 `.sheet(item: sheetModalBinding)`（约第 58-71 行）替换为：

```swift
        // RFC #2 / RFC-E：.history 居中 overlay、.settings 锚齿轮 popover；共享 sheet 仅剩 .settlement。
        .sheet(item: sheetModalBinding) { modal in
            switch modal {
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            case .settings, .history:
                // sheetModalBinding 已把 .settings/.history 滤成 nil → 此分支永不到达，仅为 switch 穷尽。
                let _ = assertionFailure("sheetModalBinding 必须把 .settings/.history 滤出共享 sheet")
                EmptyView()
            }
        }
```

- [ ] **Step 4: `== .settings` 负向 grep 守卫（Modal 非 Equatable，codex plan-R1-H1）**

Run（`if/exit 1` 负向断言，非 `! grep`）:
```bash
if grep -rn "== *\.settings" ios/Contracts/Sources; then echo "FAIL: Modal 非 Equatable，禁止 == .settings，用 isSettings 谓词"; exit 1; else echo "OK: 无 == .settings"; fi
```
Expected: `OK: 无 == .settings`（退出码 0）。

- [ ] **Step 5: host 全量回归（编译 + 无回归）**

Run: `swift test --package-path ios/Contracts`
Expected: 全绿（含 Task 3 谓词测 + Task 4 守卫测）；`AppRootView` 为 UIKit-only，host 编译为空，其呈现由 Catalyst 闸门 + 真机验收覆盖。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift
git commit -m "feat(settings): AppRootView 设置改锚齿轮 popover + reset 成功收口 + .sheet 仅剩 settlement（RFC-E）"
```

---

## 验证（实现完成后，归 verification-before-completion）

三绿（亲核输出，不靠汇总掩盖）：
1. **host swift test**：`swift test --package-path ios/Contracts` —— Swift Testing 末行两侧 0 failures **且** XCTest「All tests passed」（两框架分开打印，必看全）。
2. **Mac Catalyst build-for-testing**：`xcodebuild build-for-testing -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst'`（覆盖 UIKit 壳 + Step 6 公共面编译守卫）→ `** TEST BUILD SUCCEEDED **`。
3. **iOS Simulator app build**：`xcodebuild -scheme KlineTrainer -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` → `** BUILD SUCCEEDED **`。

**popover 布局具体验证（非纯 prose，codex plan-R1-M2）**：在**最小支持机型模拟器**（如 iPhone SE，`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）启动 app → 点齿轮 → 截图 popover；再构造 `loadError != nil`（断网/注入）+ 触发下载使下载状态文字出现 → 截图最坏态。两张截图须显示：①popover 锚齿轮且宽 ≤320pt 不撑满；②5 项 + 恢复段 + 下载状态全部可滚动可见、reset/重试按钮可点。截图存 acceptance 文档佐证。

真机验收（人工，归 acceptance 文档 `docs/superpowers/acceptance/2026-06-30-tap-anywhere-settings-popover.md`）：A1–A4 + A_drawing_remote_exit + A5–A7 + A_reset_dismiss + A_worst_reachable（见 spec §5）。

---

## Self-Review（plan 对 spec 的覆盖核对）

- F1 改动 A（handleTap via resolver，onTap 行为接线）→ Task 2 Step 2 + Task 1 resolver。✅
- F1 改动 B（lastSyncedOwner + onShouldExitRemoteCrosshair 注入）→ Task 2 Step 3/5。✅
- F1 改动 C（sync owner==nil 退出门控 self→nil，standalone 持久性）→ Task 2 Step 4 + Task 1 resolveSyncExit + standalone 守门测。✅
- F1 两纯函数 host 真值表（含 spec-R3-M1/R5-H1/R2-M1 关键格）→ Task 1。✅
- F2 改动 1（HomeView popover + AnyView 擦除 + 非泛型 + 布局契约 + 源兼容守卫）→ Task 4。✅
- F2 改动 2（AppRootView binding + content + reset 收口 + drop .settings from sheet）→ Task 5。✅
- F2 改动 3（HistoryDialogPresentation 滤 .settings + isSettings）→ Task 3。✅
- 源兼容守卫（arbiter 公共面 / HomeView bare 类型）→ Task 2 Step 6 / Task 4 Step 1。✅
- spec-R1-M1 reset 收口 → Task 5 Step 2（A_reset_dismiss）。✅
- spec-R1-M2 popover 布局契约 → Task 4 Step 4（ScrollView+maxHeight）+ 验收 A_worst_reachable。✅
- 验收/acceptance（中文 action/expected/pass-fail）→ 验证段引 spec §5。✅
- 类型一致性：`resolve`/`resolveSyncExit`/`CrosshairTapOutcome`/`CrosshairSyncExit`/`onShouldExitRemoteCrosshair`/`isSettings`/`lastSyncedOwner` 在 Task 1 定义、Task 2/3/5 一致引用。✅
- 无契约/版本改动、不 bump CONTRACT_VERSION → 全 5 task 零触 engine/持久/契约。✅
