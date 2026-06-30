# tap-anywhere 退光标 + RFC-E 设置 popover 设计（2026-06-30）

> 打包一轮做的两件小事，零交集、都属纯 view 层。一份 spec 两节 → 一份 plan → 一次 Codex whole-branch → subagent-driven → 一次真机验收 → 一个 PR。
> 来源：`docs/superpowers/2026-06-21-trade-ui-overhaul-roadmap.md` §RFC-C follow-up + 顺位 5 RFC-E；memory `project_trade_ui_backlog_2026_06_21.md` §RESUME。
> 基线：main `c371a91`（RFC-C #134 merged）。评审通道 = 真 Codex（`codex:adversarial-review` via `.claude/scripts/codex-attest.sh`）。

## 0. 目标与范围

**目标**
- **F1 tap-anywhere 退光标**：十字光标显示时，轻点**任一图表 panel 的任意位置**（上图或下图，含成交量/MACD 子区）即清掉当前光标并解冻——不再要求「只点持有光标那个 panel 的主图区」。两图互点也能退。
- **F2 RFC-E 设置 popover**：首页设置齿轮点开 = **锚定齿轮的小 popover**，取代当前的底部大 sheet。5 个设置项内容不变。

**范围裁定（用户已拍 2026-06-30）**
- tap-anywhere 覆盖范围 = **两图表区域内任一处**（不加全屏 tap 捕获层）。顶栏、交易条、画线浮动钮、齿轮等 chrome 区域保持各自行为、不被吞。理由：覆盖屏幕约 90%、与主流股票软件一致（光标活在图上、点图退出）、零按钮冲突风险、改动最小最稳。

**非目标（Non-Goals）**
- 不加全屏 / chrome 区域 tap 捕获层（已裁定）。
- 不改光标的视觉、吸附、进入（长按）、单指竖滑切周期等 RFC-C 既有行为。
- 不改设置项的内容、佣金/重置/下载/显示模式等任何业务逻辑，仅换呈现容器。
- 零引擎 / 持久层 / 契约改动，**不 bump CONTRACT_VERSION（保持 1.7）**。

## 1. 现状（已核实，含 file:line）

### 1.1 十字光标退出现状

- 共享 view-state：`crosshairOwner: PanelId?` 是 `TrainingView` 的 `@State`（`TrainingView.swift:39`），经 `$crosshairOwner` 传给两个 panel 的 `ChartContainerView`（`TrainingView.swift:264`），**不进 engine**（RFC-C §4.2 原则）。
- 每个 panel 各持一套 `ChartGestureArbiter` + `Coordinator`，arbiter 的 `crosshairMode` 是**本 panel 局部标志**（`ChartGestureArbiter.swift:47`）。
- tap 识别器挂在**整个 KLineView**（整 panel，非仅主图区）：`ChartGestureArbiter.swift:96,101`。
- tap 处理器 `handleTap`（`ChartGestureArbiter.swift:209-215`）：
  ```swift
  @objc private func handleTap(_ g: UITapGestureRecognizer) {
      guard g.state == .ended else { return }
      if crosshairMode { onCrosshairExit?(); return }   // 仅本 panel 持光标时退
      guard drawingMode else { return }                  // 仅 Drawing 模式确定锚点
      onTap?(g.location(in: g.view))
  }
  ```
- `onCrosshairExit`（`ChartGestureArbiter.swift:38`）→ Coordinator 接 `exitCrosshair()`（`ChartContainerView.swift:147-149`，默认 `releaseOwnership:true`）。
- `exitCrosshair(releaseOwnership:)`（`ChartContainerView.swift:232-241`）：清 `crosshairActive=false`、`arbiter.crosshairMode=false`（解冻）、`lastSnappedIndex=nil`、`setCrosshair(nil)`；`releaseOwnership` 时 `setCrosshairOwner?(nil)`。
- 跨面板互斥 / 接管退出在 `sync()`（`ChartContainerView.swift:78-103`）：
  ```swift
  if let owner = crosshairOwner, owner != panel, crosshairActive {
      exitCrosshair(releaseOwnership: false)            // 另一面板接管 → 本面板退（不释放共享态）
  }
  ```
- 写共享态的 setter：`setCrosshairOwner`（`ChartContainerView.swift:69-70`），由 `updateUIView` 每帧传入（`ChartContainerView.swift:41-44`，闭包 `{ crosshairOwner = $0 }`）；**仅手势回调 / 延后调用时改 @State，不在 view-update 期同步改**。

### 1.2 根因（为何点别处退不掉）

1. 非持有 panel 的 `crosshairMode==false`，`handleTap` 第一分支不触发 → 落到 `guard drawingMode else { return }`；非 drawing 即 **no-op**，退不掉「另一图持有的光标」。
2. **且不能简单地把 `crosshairOwner` 置 nil 就完事**：`sync()` 的跨面板退出条件是 `owner != panel && crosshairActive`。若只把 owner 置 nil，持有 panel 在 sync 里 `if let owner = crosshairOwner` 解包失败 → 走不到退出 → 光标残留、图仍冻结。**这是本设计必须新增「owner==nil 对称退出路径」的原因。**

### 1.3 设置 sheet 现状

- 齿轮：`HomeView.swift:60-63` `Button(action: onOpenSettings) { Image(systemName: "gearshape") }`，`onOpenSettings` 由 init 注入（`HomeView.swift:21,29`）。
- 点击链路：齿轮 → `router.openSettings()`（AppRouter）→ `activeModal = .settings` → `AppRootView` 的 `.sheet(item: sheetModalBinding)`（`AppRootView.swift:58-71`）渲染 `SettingsPanel(settings:api:cache:acceptance:onConfirmReset:)`。
- `sheetModalBinding`（`AppRootView.swift:25-33`）经纯谓词 `HistoryDialogPresentation.sheetItem(for:)` 过滤（当前滤掉 `.history`，放行 `.settings` / `.settlement`）。
- `SettingsPanel`（`SettingsPanel.swift`）内容 5 项：佣金费率、最低 5 元佣金 toggle、重置资金、离线缓存下载、显示模式 segmented picker；外加 `loadError != nil` 时的恢复段。底部 sheet 全屏模态、`VStack` + `padding(24)` + 顶部居中标题「设置」+ `.toastOverlay`（下载状态）。
- 全仓**无 `.popover()` 先例**；居中卡片先例 = `HistoryActionSheet`（ZStack 遮罩 + 居中卡 `maxWidth 280` + `.regularMaterial` + 圆角 16）。

## 2. 设计 · F1 tap-anywhere 退光标

### 2.1 机制（两处改动 + 两个纯函数）

**改动 A — `handleTap` 加「空 tap」分支（`ChartGestureArbiter.swift`）**
重构为三分支（前两分支语义与现状逐字等价，仅新增第三分支）：
```swift
@objc private func handleTap(_ g: UITapGestureRecognizer) {
    guard g.state == .ended else { return }
    if crosshairMode { onCrosshairExit?(); return }       // 本 panel 持光标 → 退（不变）
    if drawingMode { onTap?(g.location(in: g.view)); return }  // Drawing 锚点（不变）
    onTapIdle?()                                          // 新增：空 tap → Coordinator 决策跨面板退出
}
```
- 新增回调 `var onTapIdle: (() -> Void)?`（`ChartGestureArbiter`）。arbiter 仍**不知道** `crosshairOwner`（保持其只懂局部态的边界），由 Coordinator 决策。

**改动 B — Coordinator 接 `onTapIdle` + 记录上次同步的 owner（`ChartContainerView.swift`）**
- Coordinator 新增成员 `private var lastSyncedOwner: PanelId?`，在 `sync()` **末尾**刷新（`self.lastSyncedOwner = crosshairOwner`），即「上一次同步时观察到的共享 owner」。`updateUIView` 在每次 `@State` 变化时都会跑 → owner 任何变化都会刷新它。
- 接线：
  ```swift
  arbiter.onTapIdle = { [weak self] in
      guard let self else { return }
      // 另一面板持有光标 → 任一图区 tap 请求全局退出（tap-anywhere）
      if self.lastSyncedOwner != nil {
          self.setCrosshairOwner?(nil)     // 置 nil → 持有面板 sync 见「self→nil 跃迁」自退（改动 C）
      }
      // owner==nil（无人持光标）→ 维持现状 no-op，不改变普通态点击行为
  }
  ```
- 到达 `onTapIdle` 时本 panel 必非持有者（持有者 `crosshairMode==true` 已在改动 A 第一分支 return）。故 `lastSyncedOwner != nil` 必指向**另一** panel。
- standalone（`.constant(nil)` 默认 binding）下 `lastSyncedOwner` 恒 nil（写 constant 无效）→ `onTapIdle` 永不请求清，本地光标退出仍走改动 A 第一分支。

**改动 C — `sync()` 加 owner==nil 对称退出路径，门控 self→nil 跃迁（`ChartContainerView.swift`）**
⚠️ **不能简单地「owner==nil && crosshairActive 就退」**（codex spec-R2-M1）：`ChartContainerView` 有 public 2-arg `init(panel:engine:)`，`crosshairOwner` 默认 `.constant(nil)`（无跨面板协调的调用方/测试用）。该模式下 `enterCrosshair` 的 `setCrosshairOwner(panel)` 写 constant binding = no-op → owner 恒 nil；若无门控，进光标后**下次 sync 立即自退** → standalone 黏滞光标失效（回归）。

故退出**门控在「本面板上次同步时正是 owner、本次变 nil」的 self→nil 跃迁**：
```swift
let previousOwner = lastSyncedOwner                      // 改动 B 维护，sync 末尾才更新
if let owner = crosshairOwner, owner != panel, crosshairActive {
    exitCrosshair(releaseOwnership: false)               // 既有：被另一面板接管
} else if crosshairOwner == nil, previousOwner == panel, crosshairActive {
    exitCrosshair(releaseOwnership: false)               // 新增：本面板曾持有、owner 被清（tap-anywhere）→ 自退解冻
}
// …（drawing 逻辑） …
self.lastSyncedOwner = crosshairOwner                    // sync 末尾刷新
```
- standalone：owner 恒 nil → `previousOwner` 恒 nil ≠ panel → 新分支**永不触发**，黏滞光标保留。
- 协调态（TrainingView）：upper 持光标时 upper.`lastSyncedOwner==.upper`；lower tap 置 owner=nil → upper sync 见 `previousOwner(.upper)==panel(.upper) && owner==nil` → 退。lower 的 `previousOwner==.upper≠.lower` 且其 `crosshairActive==false` → no-op。
- 持有 panel 经此退出 `releaseOwnership:false`（owner 已 nil，无需重复写）。

**两个纯函数（host 可测，沿用本仓「平台无关纯函数 + 薄 UIKit 层」一贯模式）**
把 tap 路由 + sync 退出两处决策抽成纯函数，便于 host 单测且让 codex 逐格核（尤其 standalone 持久性回归）：
```swift
// ① tap 归属
enum CrosshairTapOutcome: Equatable { case exitLocal, requestGlobalExit, drawingAnchor, noop }
enum CrosshairTapResolver {
    static func resolve(localCrosshairMode: Bool, drawingMode: Bool, owner: PanelId?) -> CrosshairTapOutcome {
        if localCrosshairMode { return .exitLocal }      // 本 panel 持光标 → 退本地
        if drawingMode { return .drawingAnchor }         // Drawing → 落锚点
        if owner != nil { return .requestGlobalExit }    // 另一面板持光标 → 请求全局退出
        return .noop                                     // 普通态 → 无操作
    }
}

// ② sync 退出决策（含 standalone 持久性门控）
enum CrosshairSyncExit: Equatable { case none, exitTakenOver, exitOwnerCleared }
extension CrosshairTapResolver {
    static func resolveSyncExit(incomingOwner: PanelId?, previousOwner: PanelId?,
                                panel: PanelId, crosshairActive: Bool) -> CrosshairSyncExit {
        guard crosshairActive else { return .none }
        if let owner = incomingOwner, owner != panel { return .exitTakenOver }   // 被接管
        if incomingOwner == nil, previousOwner == panel { return .exitOwnerCleared }  // self→nil（tap-anywhere）
        return .none                                                             // 含 standalone 恒 nil → 不退
    }
}
```
**决策真值表必须有 host 测**，含 standalone 关键格：`resolveSyncExit(incomingOwner:nil, previousOwner:nil, panel:.upper, crosshairActive:true) == .none`（黏滞光标持久性回归守门，codex spec-R2-M1）。plan 决定 `handleTap`/`sync` 是内联还是直接调纯函数 switch。

### 2.2 状态流（两图互点退出，举例）

1. 长按上图 → 上图 `crosshairMode=true` + `setCrosshairOwner(.upper)`；下图 sync 见 `owner=.upper≠.lower && active` → 本地退（若它曾持光标）。共享 `crosshairOwner=.upper`。
2. **轻点下图任意处** → 下图 `handleTap`：`crosshairMode==false`、非 drawing → `onTapIdle` → `lastSyncedOwner==.upper≠nil` → `setCrosshairOwner(nil)`。
3. owner 变 nil → SwiftUI 刷新两图 `updateUIView` → 两图 sync：
   - 上图（持光标）：`previousOwner(.upper)==panel(.upper) && owner==nil && crosshairActive` → `exitCrosshair(releaseOwnership:false)` → 清光标、解冻。
   - 下图：`previousOwner(.upper)≠panel(.lower)` 且 `crosshairActive==false` → no-op。
4. 结果：光标消失、图恢复可平移/缩放/切周期。**轻点上图自身**仍走改动 A 第一分支（`crosshairMode==true → onCrosshairExit`），路径不变。

### 2.3 边界与不变量（codex 核查清单）

- **持有 panel 自身 tap（含 volume/MACD 区）**：tap 识别器覆盖整 KLineView，`crosshairMode==true` → 第一分支退出，行为**不变**。
- **普通态（无光标、非 drawing）panel tap**：`owner==nil` → `noop`，**不改变现状**（现状即 no-op）。
- **Drawing 模式 tap**：第二分支落锚点，**不变**。drawing 与 crosshair 互斥（单一浮动画线钮 + `sync()` 行 92 进 drawing 即退光标）→ 二者不共存，故 `onTapIdle` 路径下 owner 必为 drawing 之外的态；防御性地，即使共存，drawing panel 的 tap 也优先落锚点（第二分支先 return）。
- **standalone 黏滞光标持久性（codex spec-R2-M1 回归守门）**：`init(panel:engine:)` 默认 `crosshairOwner=.constant(nil)`，进光标后 owner 恒 nil；新 owner==nil 退出门控在 `previousOwner==panel`，standalone 下 `previousOwner` 恒 nil ≠ panel → **永不自退**，黏滞光标保留。`onTapIdle` 同理（`lastSyncedOwner` 恒 nil → 不请求清）。纯函数 `resolveSyncExit(incomingOwner:nil, previousOwner:nil, panel:.upper, active:true)==.none` host 测守门。
- **幂等**：`exitCrosshair` 反复调用安全（置 false/nil）；`setCrosshairOwner(nil)` 重复写安全。
- **@State 修改时机**：`setCrosshairOwner(nil)` 在手势回调 `onTapIdle` 内调用（非 view-update 期），符合 `ChartContainerView.swift:69` 既定约束。
- **owner 成员新鲜度**：`lastSyncedOwner` 在 sync 末尾刷新；owner 任何变化都触发 `updateUIView`→sync，故 tap 回调读到的值与当前 @State 一致。
- **零引擎触达**：三处改动均在 view/手势层；crosshair pan/zoom/切周期抑制语义不变（仍由 `crosshairMode` 控制）。`init(panel:engine:)` 公共签名**不变**（不破坏源兼容，沿 RFC-C WB-high 教训）。

## 3. 设计 · F2 RFC-E 设置 popover

### 3.1 机制

齿轮在 HomeView、设置依赖（`settings/api/cache/acceptance/onConfirmReset`）在 AppRootView。原生 `.popover` 必须挂在锚点视图（齿轮）上，故把呈现下沉进 HomeView，但保持 HomeView 的 **view-only（D1）** 边界——HomeView 不 import settings/acceptance，只渲染注入的内容视图。

**改动 1 — HomeView 加 popover 锚点（`HomeView.swift`）**
- init 新增两参（泛型保 view-only）：
  - `isSettingsPresented: Binding<Bool>`
  - `@ViewBuilder settingsContent: () -> SettingsContent`（`HomeView<SettingsContent: View>`）
- 齿轮 Button 挂：
  ```swift
  Button(action: onOpenSettings) { Image(systemName: "gearshape").font(.title2) }
      .accessibilityLabel("设置")
      .popover(isPresented: isSettingsPresented) {
          ScrollView {                                        // 强制：内容可滚动，最坏情况全部可达（见 §3.4 布局契约）
              settingsContent()
          }
          .frame(minWidth: 280, idealWidth: 300, maxHeight: 480)   // 约束宽 + 限高，避免铺满/溢出裁剪
          .presentationCompactAdaptation(.popover)            // iPhone 强制 popover 样式（iOS16.4+；项目 iOS17 满足）
      }
  ```
- `onOpenSettings` 保留：仍 `router.openSettings()` 置 `activeModal=.settings`，作为单一真相；popover 由下方 binding 驱动。
- **强制 §3.4 popover 布局契约**：见下，非 plan-time 可选项。

**改动 2 — AppRootView 桥接 binding + content（`AppRootView.swift`）**
- 新增 `settingsPopoverBinding: Binding<Bool>`：
  ```swift
  Binding(
      get: { router.activeModal == .settings },
      set: { newValue in
          if !newValue && router.activeModal == .settings { router.activeModal = nil }   // 仅当前是 settings 才清，防误清其它模态
      }
  )
  ```
  （守卫沿用 `sheetModalBinding` 的「dismiss 回写不误清」精神。）
- 构造 HomeView 时传入 binding + `settingsContent`，**`onConfirmReset` 必须在 reset 成功后显式收 popover**（codex spec-R1-M1：`resetAllProgressAndReload()` 当前只 `settings.resetAllProgress()`+`loadHome()`、**不清 `activeModal`**，否则破坏性 reset 完成后 popover 残留在重置后的首页上）：
  ```swift
  settingsContent: {
      SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance,
                    onConfirmReset: {
                        try await router.resetAllProgressAndReload()
                        router.activeModal = nil               // 强制：reset 成功 → 收 popover（A6/A_reset_dismiss）
                    })
  }
  ```
  （仅成功后清；`resetAllProgressAndReload` 抛错则不清，错误经既有 `router.errorMessage` alert 呈现、popover 保留供重试。）
- 从 `.sheet` 移除 `.settings` 分支（`.sheet` 只剩 `.settlement`；`.history` 仍走 overlay）。

**改动 3 — `HistoryDialogPresentation` 谓词扩展（纯函数，已有 host 测）**
- `sheetItem(for:)` 把 `.settings` 一并滤成 nil（防 sheet 与 popover 双弹）。新增/更新对应 host 测：`.settings → sheet=nil`、`.settlement → 放行`、`.history → nil`。

### 3.2 设置项 = 原样保留

5 项（佣金费率 / 最低 5 元佣金 / 重置资金 / 离线缓存下载 / 显示模式）+ loadError 恢复段，内容与**业务**逻辑**逐字不变**，仅换呈现容器（sheet→popover）+ 套布局契约（§3.4）+ reset 成功后收 popover（§3.1 改动 2）。`onConfirmReset` 走 `router.resetAllProgressAndReload()` 后清 `activeModal`。

### 3.4 popover 布局契约（强制 · 非 plan-time 可选，codex spec-R1-M2）

小 popover 容器装得下 `SettingsPanel` 的最坏内容是**硬要求**——`SettingsPanel` 为 padded `VStack`，叠加 loadError 恢复段 + 下载状态文字 + reset 错误文字 + segmented picker + toast 时，无 ScrollView/限高会在小机型上溢出裁剪、使恢复/设置操作**不可达**。故落地必须满足：
1. **可滚动**：popover 内容包在 `ScrollView`（或等效）里，纵向可滚，保证所有控件可达。
2. **有界尺寸**：宽 ~300pt、`maxHeight` 受限（≤ 可用 popover 高度，建议 ≤480pt 或屏高减锚区），不铺满、不溢出。
3. **状态可见**：下载状态 / reset 错误 / loadError 恢复段**不被裁剪**——toast/status 若被 ScrollView 裁剪则移到 popover 外或固定在容器内可读位置。
4. **最坏情况验收**：在**最小支持机型**上，构造 `loadError != nil`（恢复段出现）+ 下载状态文字同现，核实全部可滚动可达、reset/重试按钮可点。

### 3.5 边界与不变量（codex 核查清单）

- **无双弹**：`.settings` 必须同时（a）驱动 popover、（b）被 `sheetItem` 滤出 sheet。两者缺一即 bug（要么不显、要么 sheet+popover 同弹）。host 测覆盖谓词；真机验收覆盖呈现。
- **dismiss 回写**：popover 外部点击 / 下滑关闭 → `set(false)` → 仅当 `activeModal==.settings` 时清为 nil（守卫防把已切换到 `.settlement`/`.history` 的模态误清）。
- **重置资金后（强制收口，codex spec-R1-M1）**：`onConfirmReset` 成功 → 显式 `router.activeModal = nil` 收 popover（§3.1 改动 2）。**不可**依赖 `resetAllProgressAndReload()` 自身清——它当前只 `settings.resetAllProgress()`+`loadHome()`（AppRouter.swift:168-171），不碰 `activeModal`。失败则不清、popover 保留供重试。验收 A_reset_dismiss 覆盖。
- **下载 toast / 状态可见**：见 §3.4 契约 3——下载状态必须在 popover 内可读不裁剪。
- **平台**：iPad 原生 popover 带箭头锚齿轮；iPhone 经 `presentationCompactAdaptation(.popover)` 强制锚定 popover 不退化 sheet。`.presentationCompactAdaptation` 需 iOS 16.4+，项目 iOS17 满足（`HomeView.swift:12` 注明跨 iOS17）。

## 4. 测试策略

- **纯函数 host 测**（Swift Testing）：
  - `CrosshairTapResolver.resolve(...)` 决策真值表：4 类 outcome × 关键输入组合（localMode true/false × drawingMode × owner nil/.upper/.lower），含「持有自身=exitLocal」「另一面板=requestGlobalExit」「普通态=noop」「drawing=drawingAnchor」。
  - `CrosshairTapResolver.resolveSyncExit(...)` 真值表（codex spec-R2-M1 守门）：「被接管=exitTakenOver」（incomingOwner=另一 panel）、「self→nil=exitOwnerCleared」（incomingOwner=nil, previousOwner=panel）、**「standalone 恒 nil=none」**（incomingOwner=nil, previousOwner=nil, active=true）、「无 active=none」。
  - `HistoryDialogPresentation.sheetItem(for:)`：`.settings→nil`、`.settlement→放行`、`.history→nil`；以及 `isHistoryPresented` 等既有断言不回归。
- **壳层（UIKit/SwiftUI）**：tap-anywhere 的两图互点退出、popover 锚定 / dismiss / 双弹排除 → 走**真机验收**（本仓约定，UIKit 手势 + SwiftUI present 难单测）。
- **三绿**：host swift test（Swift Testing + XCTest 两框架都看「All tests passed / 末行 0 failures」）+ Mac Catalyst build-for-testing + iOS Simulator app build。
- 负向 grep 断言用 `if/exit 1` 非 `! grep`（[[feedback_acceptance_grep_anchoring]]）。

## 5. 验收（详表归 plan/acceptance 文档；高层）

- A1 长按上图出光标 → 轻点**下图**任意处 → 光标消失 + 图恢复交互。
- A2 长按上图出光标 → 轻点**上图**任意处（含成交量/MACD 区）→ 光标消失。
- A3 下图同理（长按下图 → 点上图退）。
- A4 无光标时轻点图表 → 无异常（不误触发任何模式）。
- A5 点齿轮 → 锚齿轮的 popover 弹出（非底部大 sheet），含全部 5 项。
- A6 popover 外部点击 / 下滑 → 关闭；不残留、不双弹。
- A7 popover 内改显示模式 / 下载 → 行为与原 sheet 一致；下载状态文字在 popover 内可见不裁剪。
- **A_reset_dismiss**（强制，codex spec-R1-M1）：popover 内重置资金 → 确认 → reset 成功后 **popover 自动关闭**、回到重置后的首页（资金 ¥100,000、记录保留）；不残留在重置后首页上。
- **A_worst_reachable**（强制，codex spec-R1-M2）：在最小支持机型构造 `loadError != nil`（恢复段出现）+ 下载状态同现 → popover 内全部控件可滚动可达、reset/重试按钮可点。

## 6. 风险与残留

- **R1**：`.presentationCompactAdaptation(.popover)` 若部署目标 < iOS 16.4 不可用 → plan 阶段核实 deployment target（预期满足）。
- **R2**：HomeView 泛型化（`HomeView<SettingsContent>`）可能影响既有 `#Preview` / 调用点 → plan 核实所有构造点并更新（含 DEBUG preview）。
- **R3（已升级为强制契约 §3.4，非残留）**：popover 内 `SettingsPanel` 的 toast / 恢复段 / 下载状态在小容器内必须可滚动可读 → 见 §3.4 + A_worst_reachable。
- **残留（post-merge，非阻塞，沿 RFC-C）**：`DateFormatter` 每帧分配（CrosshairLayout + CrosshairSidebarContent）→ static let 缓存，择机做，不在本轮范围。

## 7. 交付流程

brainstorming（本 spec）→ **Codex 对抗 review spec 到收敛** → writing-plans → **Codex review plan 到收敛** → subagent-driven（TDD）→ verification（三绿）→ requesting-code-review → **whole-branch Codex 对抗 review 到收敛** → PR（user 终端 push + `--admin` merge，guard 拦 Claude push）。Codex 配额耗尽则等额度恢复后第一时间续，不用 opus 代打。
