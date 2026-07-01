# WB-R4 兼容收口（功能退路）+ DateFormatter 每帧分配缓存 设计（2026-07-01）

> 两个非阻塞残留打包一 PR 收口。一份 spec 两节 → Codex spec review 收敛 → plan → Codex plan review 收敛 → subagent-driven → 三绿 → requesting-code-review → whole-branch Codex → PR。
> 来源：`docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md` §8（WB-R4 残留）+ RFC-C DateFormatter 每帧分配残留。基线：origin/main `d2eb431`（含 #135 tap-anywhere/popover + #136 replay续局 + #137 CI 修）。评审通道=真 Codex（`codex-attest.sh --scope branch-diff`）。

## 0. 目标 / 范围 / 约束

**目标**
- **I1 · WB-R4 兼容收口（功能退路 A，user 拍板）**：把 #135 遗留的「旧 HomeView 5 参 init + `sheetItem` 全局滤 `.settings`」造成的公共-API 兼容争议收口到 codex 能收敛的干净终态——公共路由谓词 `HistoryDialogPresentation` 恢复通用契约，settings 专属过滤下沉到用 popover 的 `AppRootView`，旧 init 成为**可用的 legacy sheet 路由**（非 deprecated-noop）。
- **I2 · DateFormatter 每帧分配缓存（含 AxisGridLayout，user 拍板）**：crosshair 拖动 + 坐标轴每帧重绘的热路径上，`DateFormatter()` 每次调用重分配 → 改 `nonisolated(unsafe) static let` 缓存。

**范围**
- I1：`HistoryDialogPresentation.swift`（+ 其 host 测）、`HomeView.swift`、`AppRootView.swift`。
- I2：`CrosshairLayout.swift`、`CrosshairSidebarContent.swift`、`AxisGridLayout.swift`（三处 per-frame 分配）。

**非目标 / Non-Goals**
- 不改任何**用户可见行为**——I1 后 app 内设置仍经 popover 呈现（与 #135 逐像素一致）；I2 缓存**输出逐字不变**（同 tz/locale/format 的同一字符串）。二者均为纯结构/性能改进。
- `HomeContent.swift:110` 的 `DateFormatter()` **不动**（首页加载一次，非 per-frame 热路径）。
- 零引擎 / 持久层 / 契约改动；**不 bump CONTRACT_VERSION（保持 1.7）**。

**约束**
- `AppRouter.Modal` 仅 `Identifiable` **非 Equatable** → 一律 `if case`/`isSettings` 谓词，**禁 `== .settings`**（沿 #135）。
- **Swift 6 严格并发**：`static let DateFormatter`（DateFormatter 非 Sendable）会触发数据竞争检查 → 用 `nonisolated(unsafe) static let`（断言仅主线程/渲染调用）。⚠️ **本地工具链比 CI macos-15 宽松**（[[feedback_swift_local_ci_toolchain_strictness]]）→ Catalyst build-for-testing 必须亲验通过、零 warning。
- 负向 grep 断言用 `if/exit 1` 非 `! grep`。

## 1. 现状（基线 d2eb431，已核实）

### 1.1 I1 · #135 遗留态
- `HistoryDialogPresentation.sheetItem`（`:18-22`）滤 **`.history` 且 `.settings`** → nil；`sheetDismissMayApply`（`:38-42`）对 **`.history` 且 `.settings`** 返 false；`isSettings`（`:31-34`）新增。
- `HomeView`（`:27-45`）：旧 5 参 init 标 `@available(*, deprecated)` 委托主泛型 init 传 `.constant(false)`+`EmptyView`（不接线 popover）；主泛型 init（`:47`）接 `isSettingsPresented`/`settingsContent`。
- `AppRootView.sheetModalBinding`（`:25-33`）：get=`sheetItem(...)`、set 守 `sheetDismissMayApply`；`settingsPopoverBinding`（`:38-47`）=`isSettings` 驱动 popover。
- **WB-R4 争议**：旧 init 不接 popover + `sheetItem` 全局滤 `.settings` → 用旧 init 的（假想外部）调用方既无 popover 也无 sheet = 静默丢设置 UI。codex R1(移除)↔R2(恢复)↔R4(deprecated 不够)振荡。**本仓单 app 内部模块、唯一消费者 AppRootView 已迁主 init，无真实影响；本次做干净收口。**

### 1.2 I2 · 三处 per-frame DateFormatter 分配
均固定 `timeZone=UTC+8(secondsFromGMT:8*3600)` + `locale=en_US_POSIX`：
- `CrosshairLayout.swift:95`：固定 `dateFormat="yyyy-MM-dd HH:mm"`（十字光标拖动每帧）。
- `CrosshairSidebarContent.swift:128`：`"yyyy-MM-dd"` 后条件改 `"HH:mm"`（悬浮栏每次移动）。
- `AxisGridLayout.swift:96`：`dateFormat=dateFormat(for:period)`（**随周期变**；坐标轴每帧重绘）。

## 2. 设计 · I1 功能退路（A）

**核心**：公共 `HistoryDialogPresentation` 谓词恢复通用契约（只滤 `.history`），**settings 专属的「滤出 sheet」逻辑下沉到唯一用 popover 的 `AppRootView`**（本地排除），旧 init 恢复为可用 legacy 路由。同时满足 codex R1（无静默丢——旧式经 sheet 仍出设置）+ R2（无源破坏——旧 init 保留）+ R4（functional fallback）。

### 2.1 `HistoryDialogPresentation`（恢复通用契约）
- `sheetItem`：**移除 `.settings` 分支**，只滤 `.history`：
  ```swift
  public static func sheetItem(for modal: AppRouter.Modal?) -> AppRouter.Modal? {
      if case .history = modal { return nil }
      return modal   // .settings 透传（legacy sheet 路由；popover 专属过滤下沉 AppRootView）
  }
  ```
- `sheetDismissMayApply`：**移除 `.settings` 分支**，只对 `.history` 返 false：
  ```swift
  public static func sheetDismissMayApply(current: AppRouter.Modal?) -> Bool {
      if case .history = current { return false }
      return true
  }
  ```
- `isSettings`：**保留不变**（AppRootView popover binding + 本地排除仍用）。
- 注释同步：`sheetItem`/`sheetDismissMayApply` 文档去掉「/ `.settings`」，说明 settings 过滤下沉 AppRootView。

### 2.2 `AppRootView`（settings 专属过滤本地化）
`sheetModalBinding` 改为**本地把 settings 排除出自己的 sheet**（因本 view 用 popover 呈现 settings，防双弹）+ **本地 clobber 守卫**：
```swift
private var sheetModalBinding: Binding<AppRouter.Modal?> {
    Binding(
        get: {
            // 本 view 用 popover 呈现 settings → 本地排除出自己的 sheet（防双弹）；公共 sheetItem 保持通用。
            if HistoryDialogPresentation.isSettings(router.activeModal) { return nil }
            return HistoryDialogPresentation.sheetItem(for: router.activeModal)
        },
        set: { newValue in
            // history 由 sheetDismissMayApply 拦；settings 由本地 !isSettings 拦——
            // settlement→settings 跃迁时本 sheet 收起触发 set(nil)，不可清掉 popover 驱动的 settings。
            guard HistoryDialogPresentation.sheetDismissMayApply(current: router.activeModal),
                  !HistoryDialogPresentation.isSettings(router.activeModal) else { return }
            router.activeModal = newValue
        }
    )
}
```
- `settingsPopoverBinding`、HomeView 构造（主 init + popover）、`.sheet` switch（`.settlement` + 穷尽 `.settings/.history` 死分支）**不变**。

### 2.3 `HomeView`（旧 init 去 deprecated → 可用 legacy 路由）
旧 5 参 init **去掉 `@available(*, deprecated)`**（其余委托不变），更新文档说明它是可用 legacy 路由：
```swift
/// Legacy 源兼容 overload（WB-R4 功能退路）：本 init 构造的 HomeView **不接线设置 popover**（settingsContent=EmptyView）；
/// 呈现设置由调用方经共享 sheet（`HistoryDialogPresentation.sheetItem` 透传 `.settings`）+ 自己的 `.sheet` 完成。
/// AppRootView 用主 init（popover）；老式消费者用本 init + 自己的 sheet。二者都能出设置 → 无静默丢、无源破坏。
public init(content: HomeContent, onStartTraining: @escaping () -> Void,
            onContinueTraining: @escaping () -> Void, onSelectRecord: @escaping (Int64) -> Void,
            onOpenSettings: @escaping () -> Void) {
    self.init(content: content, onStartTraining: onStartTraining, onContinueTraining: onContinueTraining,
              onSelectRecord: onSelectRecord, onOpenSettings: onOpenSettings,
              isSettingsPresented: .constant(false), settingsContent: { EmptyView() })
}
```
- `HomeView` 仍非泛型 concrete（R6-H1 核心不变）；主泛型 init 不变。

### 2.4 边界与不变量（codex 核查清单）
- **AppRootView 无双弹**：`activeModal==.settings` → popover 显（`settingsPopoverBinding`），`sheetModalBinding.get` 本地 isSettings→nil → 自己的 sheet 不显 settings。✓
- **settlement→settings 不 clobber**：sheet 收起触发 `set(nil)`，本地 `!isSettings` 守卫拦下（`sheetDismissMayApply(.settings)` 现为 true，仅靠本地 `!isSettings` 拦）→ `activeModal` 保持 `.settings`。✓
- **legacy sheet 路由可用**：外部消费者用旧 init + 自己 `.sheet(item: sheetItem(...))` → `sheetItem(.settings)` 透传 `.settings` → 其 sheet 出设置；`sheetDismissMayApply(.settings)=true` → 其设置 sheet 可下滑清 `activeModal`。✓（满足 codex R1/R4）
- **无源/行为破坏**：旧 init 保留、去 deprecated（不再是 deprecated-noop 陷阱）；`sheetItem`/`sheetDismissMayApply` 恢复通用契约（对通用消费者行为回到「settings 走 sheet」原状）。✓（满足 codex R2）
- **零用户可见变化**：AppRootView 仍 popover 呈现 settings，与 #135 一致。`.history`/`.settlement` 路由不变。
- **零契约改动**：全 view 层；不 bump CONTRACT_VERSION。

## 3. 设计 · I2 DateFormatter 缓存（含 AxisGridLayout）

**核心**：三处 per-frame `DateFormatter()` 分配 → `nonisolated(unsafe) static let` 缓存（固定 tz/locale）。crosshair 两处 format 固定 → 缓存不可变 formatter；AxisGridLayout format 随周期变 → 缓存一个 formatter、循环前设一次 `dateFormat`（省掉分配大头）。**输出逐字不变**。

### 3.1 `CrosshairLayout`（1 个固定 formatter）
```swift
// 类型内 static（仅主线程/渲染调用，非 Sendable 用 nonisolated(unsafe)）
private nonisolated(unsafe) static let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()
```
`resolve` 内 `:95-98` 的 `let formatter = DateFormatter(); …` 删除，改用 `Self.timeFormatter.string(from: date)`。

### 3.2 `CrosshairSidebarContent`（2 个固定 formatter，消除 per-call 改 format）
```swift
private nonisolated(unsafe) static let dateFormatter: DateFormatter = { /* 同上，dateFormat="yyyy-MM-dd" */ }()
private nonisolated(unsafe) static let timeFormatter: DateFormatter = { /* 同上，dateFormat="HH:mm" */ }()
```
`formatDateTime` 内 `:128-135`：`dateText = Self.dateFormatter.string(from: date)`；`isIntraday` 时 `Self.timeFormatter.string(from: date)`。不再 per-call `df.dateFormat=…` 改写。

### 3.3 `AxisGridLayout`（1 个缓存 formatter，循环前设 format）
```swift
private nonisolated(unsafe) static let sharedFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    f.locale = Locale(identifier: "en_US_POSIX")
    return f   // dateFormat 每次按周期设
}()
```
`:96-99` 的 `let fmt = DateFormatter(); …` 删除；循环**前** `Self.sharedFormatter.dateFormat = dateFormat(for: period)`（一次），循环内 `Self.sharedFormatter.string(from: date)`。per-call 设 dateFormat 仅主线程渲染、`nonisolated(unsafe)` 断言安全（省掉分配大头）。

### 3.4 边界（codex 核查清单）
- **输出不变**：缓存 formatter 与原 per-call formatter 配置（tz/locale/format）逐字相同 → `.string(from:)` 输出相同 → 现有 host 测（断言 label/time 文本）即回归守卫。
- **Swift 6 Sendable**：`nonisolated(unsafe) static let` 是非 Sendable 全局常量的标准逃逸；⚠️ **本地 Swift6 宽松 ≠ CI macos-15**，Catalyst build-for-testing 必须亲验通过 + **零 warning**（CI gate `grep -E "(error|warning):"`）。
- **单线程假设**：三处均在主线程渲染路径调用（十字光标手势回调 / 坐标轴 layout）；AxisGridLayout 共享 formatter 的 per-call `dateFormat` 写入靠此保证无竞争。
- **平台无关**：三文件为 `Render/` 纯布局函数（无 `#if canImport(UIKit)`）→ host swift test 也编译它们，Swift6 检查 host + Catalyst 双覆盖。

## 4. 测试策略
- **host 纯函数测（Swift Testing）**：
  - `HistoryDialogPresentation`（I1）：**更新 #135 的两条断言**——`sheetItem(.settings)` 现**透传**（返 `.settings`，`.id=="settings"`，非 nil）；`sheetDismissMayApply(.settings)` 现 **true**；`isSettings` 断言不变；`.history` 断言不变（仍滤/仍 false）；`.settlement` 透传不变。
  - `HomeView`（I1）：源兼容守卫测改用**旧 5 参 init**（现已去 deprecated，无 warning）构造 `let _: HomeView = HomeView(content:…, onOpenSettings: {})` → 证 legacy 路由可用 + bare concrete 类型（一旦泛型化或重加 deprecated 即编译错/warning）。
  - `CrosshairLayout`/`CrosshairSidebarContent`/`AxisGridLayout`（I2）：**现有 label/time 文本断言即输出回归守卫**（缓存不改输出）；如现有覆盖不足，补 1 条「缓存前后同输入同输出」断言。
- **源兼容 grep 守卫（I1）**：`if grep -rn "== *\.settings" ios/Contracts/Sources; then exit 1; fi`（`if/exit 1` 非 `! grep`）。
- **三绿亲核**：host swift test（Swift Testing 末行 0 failures **且** XCTest「All tests passed」两框架分开看）+ Mac Catalyst `build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` → `** TEST BUILD SUCCEEDED **` **且** CI-gate `grep -E "(error|warning):"` count=0（**验 Swift6 `nonisolated(unsafe)` 通过 + 零 warning**）+ iOS Simulator app build `** BUILD SUCCEEDED **`。

## 5. 验收（人工，中文 action/expected/pass-fail）
- **A1（I1 无回归）**：首页点齿轮 → 锚齿轮 popover 弹出含 5 项（与 #135 一致）；popover 外点/下滑关闭、不双弹；重置资金后 popover 自动关。= pass。
- **A2（I2 无回归 · 十字光标）**：训练界面长按出十字光标、拖动 → 底部时间标签正确显示吸附 K 线的日期时间（日内 yyyy-MM-dd HH:mm）；悬浮信息栏日期/时间正确（日内显时分、日/周/月只显日期）。文本与缓存前一致、拖动流畅 = pass。
- **A3（I2 无回归 · 坐标轴）**：平移/缩放图表 → 底部时间轴 4 个标签按周期正确格式化（日内含时分、日线 yyyy-MM-dd、周/月 yyyy-MM）。= pass。
- 自动闸门（host/Catalyst/iOS 三绿 + grep 守卫）见 §4，记录佐证。

## 6. 交付流程
brainstorming（本 spec）→ **Codex spec review 收敛** → writing-plans → **Codex plan review 收敛** → subagent-driven（TDD）→ verification 三绿 → requesting-code-review → **whole-branch Codex review** → PR（user 终端 push + override/`--admin` merge，guard 拦 Claude push）。Codex 配额耗尽等恢复续，不用 opus 代打。
