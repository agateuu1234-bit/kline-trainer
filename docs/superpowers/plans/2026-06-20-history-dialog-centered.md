# 历史记录改屏幕居中弹窗（RFC #2）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把首页「点历史记录 → 复盘/再来一次/取消」弹窗从 iPhone 底部 sheet 改为屏幕居中卡片 + 半透明遮罩，零业务/引擎/契约改动。

**Architecture:** 纯呈现层改造。把分流/谓词纯逻辑抽到 host 可测的 `HistoryDialogPresentation`（Task 1，红绿 TDD，覆盖 spec High-1 风险）；`HistoryActionSheet` body 重塑为 ZStack 遮罩+居中卡片（Task 2，inner 字面不变+外层 D9）；`AppRootView` 把 `.history` 从共享 `.sheet` 分流到 `.overlay`（Task 3，消费 Task 1 helper + 带 High-1 守卫 + `.animation(value:)` 驱动）；冻结 spec 呈现措辞 + 验收清单（Task 4）。`AppRouter`/`HistoryActionContent` 不改 → 现有 host 测试天然回归网。

**Tech Stack:** Swift 6 / SwiftUI（iOS 17+ / Mac Catalyst）/ Swift Testing（`@Suite`/`@Test`/`#expect`）/ Swift Package `KlineTrainerContracts`（`ios/Contracts`）。

## Global Constraints

逐条来自 spec `docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md`，每个 Task 隐含遵守：

- **不改名**：维持 `HistoryActionSheet`（文件/类型/init 签名 `(record:onReview:onReplay:onCancel:)` 全不变，D3）。全仓引用 `HistoryActionSheet` 的既有文件（13 处，**不含**本 RFC 新增的 spec/plan 文档自身）中，**仅** 2 个 swift call site —— `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` 与 `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift` —— 因本 RFC 改动（且类型名不变）；其余文件（历史交付凭证/sibling design）零触碰。
- **不改 `AppRouter`**：`selectRecord`/`review`/`replay`/`activeModal` 语义不动（D11）。`AppRouterTests` 必须保持全绿且零改动。
- **不改 `HistoryActionContent`**：纯值 title 逻辑不动（D4）。`HistoryActionContentTests` 零改动全绿。
- **不 bump CONTRACT_VERSION**（维持 "1.6"，D8）：无 Codable/DDL/模型触点。
- **范围外不碰**：`.settings`/`.settlement` 两个 modal 维持底部 sheet 呈现（spec §1.3）。
- **inner 卡片内容字面不变**（D10）：标题 Text + 三 `.bordered` 按钮 + 各自 frame/padding + 末 `.padding(24)` 字节级保留；外层新增 ZStack 遮罩 + `.frame(maxWidth:280)` + `.background(.regularMaterial,…)` + `.shadow(radius:20)`（D9）。
- **High-1 守卫**：分流 binding 的 `set` 在「当前态为 `.history`」时 no-op，防 sheet dismiss 回写误清 history（dialog 秒关）。
- **动效经 Bool 驱动**：`.animation(.easeInOut(duration:0.2), value: isHistoryPresented)`，覆盖 onCancel/遮罩/review/replay 全部清除路径，**不**在赋值点包 `withAnimation`（不碰 `AppRouter`，D13/High-2）。`Modal` 仅 `Identifiable` 无 `Equatable`，故必须用 Bool 投影驱动，不能 `value: activeModal`。
- **测试边界（D10）**：SwiftUI 视图层（HistoryActionSheet body / AppRootView 接线）不写 host 单测，靠 Mac Catalyst `build-for-testing` 编译闸 + iOS app build + 模拟器人工验收；唯一新增 host 单测 = Task 1 纯路由逻辑。
- **平台门控**：`HistoryActionSheet.swift` 维持 `import SwiftUI`（不加 `#if canImport(UIKit)`，host 可编译，D7）；`AppRootView.swift` 维持 `#if canImport(UIKit)`（不参与 host 编译）。

---

## File Structure

| 文件 | 责任 | Task |
|------|------|------|
| `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift` | **新建**。纯路由谓词（`sheetItem` 滤 history / `isHistoryPresented` / `sheetDismissMayApply` 守卫），仅 `import Foundation`，host 全测 | 1 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift` | **新建**。Task 1 红绿测试 | 1 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` | **改 body**（ZStack 遮罩+居中卡片）+ 更新头注释 + #Preview（类型名/init 不变） | 2 |
| `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift` | **改呈现**：`.history` 从 `.sheet` 分流到 `.overlay`，加 `sheetModalBinding`/`isHistoryPresented` 计算属性 + `.animation` + dead 分支 assertion | 3 |
| `kline_trainer_modules_v1.4.md` / `kline_trainer_plan_v1.5.md` | 改呈现措辞（不改名） | 4 |
| `docs/superpowers/acceptance/2026-06-20-history-dialog-centered-acceptance.md` | **新建**验收清单 | 4 |

---

## Task 1: HistoryDialogPresentation 纯路由谓词（host TDD）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift`

**Interfaces:**
- Consumes: `AppRouter.Modal`（已存在，`public enum Modal: Identifiable { case settings; case history(TrainingRecord); case settlement(TrainingRecord); var id: String }`，定义于 `App/AppRouter.swift`）。
- Produces（Task 3 消费）：
  - `HistoryDialogPresentation.sheetItem(for: AppRouter.Modal?) -> AppRouter.Modal?` — `.history` → `nil`，其余原样。
  - `HistoryDialogPresentation.isHistoryPresented(_ : AppRouter.Modal?) -> Bool` — 仅 `.history` 为 `true`。
  - `HistoryDialogPresentation.sheetDismissMayApply(current: AppRouter.Modal?) -> Bool` — `.history` → `false`（High-1 守卫），其余 `true`。

- [ ] **Step 1: Write the failing tests**

创建 `ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift
// Spec: docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md D6/High-1/D13
// 平台无关：只 import Foundation（host swift test 直跑）。纯路由谓词的红绿覆盖。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HistoryDialogPresentation routing")
struct HistoryDialogPresentationTests {

    private func makeRecord() -> TrainingRecord {
        TrainingRecord(
            id: 1, trainingSetFilename: "t.sqlite", createdAt: 1_700_000_000,
            stockCode: "600519", stockName: "贵州茅台", startYear: 2021, startMonth: 8,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }

    // MARK: - sheetItem：滤掉 .history（分流契约 / D6）

    @Test("sheetItem 对 .history 返 nil（不经共享 sheet）")
    func sheetItemFiltersHistory() {
        #expect(HistoryDialogPresentation.sheetItem(for: .history(makeRecord())) == nil)
    }

    @Test("sheetItem 对 .settings 原样透传")
    func sheetItemPassesSettings() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settings)?.id == "settings")
    }

    @Test("sheetItem 对 .settlement 原样透传")
    func sheetItemPassesSettlement() {
        #expect(HistoryDialogPresentation.sheetItem(for: .settlement(makeRecord()))?.id == "settlement-1")
    }

    @Test("sheetItem 对 nil 返 nil")
    func sheetItemNil() {
        #expect(HistoryDialogPresentation.sheetItem(for: nil) == nil)
    }

    // MARK: - isHistoryPresented：仅 .history 为 true（动画驱动值 / D13）

    @Test("isHistoryPresented 仅 .history → true")
    func isHistoryTrueOnlyForHistory() {
        #expect(HistoryDialogPresentation.isHistoryPresented(.history(makeRecord())) == true)
        #expect(HistoryDialogPresentation.isHistoryPresented(.settings) == false)
        #expect(HistoryDialogPresentation.isHistoryPresented(.settlement(makeRecord())) == false)
        #expect(HistoryDialogPresentation.isHistoryPresented(nil) == false)
    }

    // MARK: - sheetDismissMayApply：High-1 守卫（history 态下 set no-op）

    @Test("sheetDismissMayApply 对 .history 返 false（守卫防 dialog 秒关）")
    func dismissGuardBlocksHistory() {
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .history(makeRecord())) == false)
    }

    @Test("sheetDismissMayApply 对 settings/settlement/nil 返 true（正常 dismiss）")
    func dismissGuardAllowsOthers() {
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .settings) == true)
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: .settlement(makeRecord())) == true)
        #expect(HistoryDialogPresentation.sheetDismissMayApply(current: nil) == true)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/Contracts && swift test --filter HistoryDialogPresentationTests`
Expected: 编译失败 / FAIL —— `cannot find 'HistoryDialogPresentation' in scope`（类型尚未创建）。

- [ ] **Step 3: Write minimal implementation**

创建 `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift
// Spec: docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md（RFC #2）
//
// 平台无关纯路由谓词：把 AppRouter.Modal? 翻译成「共享 sheet 该呈现什么 / 是否该弹居中 history 弹窗 /
// sheet 的 dismiss 回写是否可生效」。仅 import Foundation —— host swift test 全测（D10 例外：这是纯逻辑）。
//
// 决议来源：
// - D6：.history 经 .overlay 居中呈现，不进共享 .sheet → sheetItem 把它滤成 nil。
// - High-1：sheet 自身 dismiss 的 set(nil) 不得清掉刚置位的 .history（dialog 秒关）→ sheetDismissMayApply 守卫。
// - D13：.animation(_:value:) 需 Equatable 驱动值；Modal 仅 Identifiable 无 Equatable → 用 Bool 投影 isHistoryPresented。

import Foundation

public enum HistoryDialogPresentation {

    /// 共享 `.sheet(item:)` 的 item 过滤：`.history` 走居中 overlay，不进 sheet → 返 nil；
    /// `.settings` / `.settlement` 原样透传。
    public static func sheetItem(for modal: AppRouter.Modal?) -> AppRouter.Modal? {
        if case .history = modal { return nil }
        return modal
    }

    /// 是否应呈现居中 history 弹窗（驱动 overlay 条件 + `.animation(value:)`）。
    public static func isHistoryPresented(_ modal: AppRouter.Modal?) -> Bool {
        if case .history = modal { return true }
        return false
    }

    /// High-1 守卫：共享 sheet 的 dismiss 回写是否可生效。
    /// 当前态为 `.history` 时返 false（history 本不由 sheet 驱动，其 set(nil) 回写须被拦），其余 true。
    public static func sheetDismissMayApply(current: AppRouter.Modal?) -> Bool {
        if case .history = current { return false }
        return true
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/Contracts && swift test --filter HistoryDialogPresentationTests`
Expected: PASS —— 7 个 `@Test` 全绿，0 failures（`isHistoryTrueOnlyForHistory` 含 4 个 `#expect` 但计为 1 个 `@Test`）。

- [ ] **Step 5: Run full host suite (regression net)**

Run: `cd ios/Contracts && swift test`
Expected: 全量 0 failures（新增 7 测试 → 1113；`HistoryActionContentTests` / `AppRouterTests` 等未改全绿）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryDialogPresentation.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryDialogPresentationTests.swift
git commit -m "feat(RFC#2): HistoryDialogPresentation 纯路由谓词 + host 测试（High-1 守卫覆盖）"
```

---

## Task 2: 重塑 HistoryActionSheet body 为居中弹窗

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift`

**Interfaces:**
- Consumes: `HistoryActionContent`（不变）、`TrainingRecord`（不变）。
- Produces: `HistoryActionSheet`（类型名/init 签名不变；body 现为全屏 ZStack 遮罩+居中卡片，由 Task 3 装进 `.overlay`）。

> 本 Task **无 host 单测**（D10：SwiftUI 视图层不 host 测）。验证 = host `swift test` 仍全绿（编译通过 + 无回归）+ Mac Catalyst `build-for-testing` 编译闸。Xcode `#Preview` 供视觉自查（非自动化）。

- [ ] **Step 1: 改写 body + 头注释 + #Preview**

把 `ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift` 整文件替换为：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift
// Spec: kline_trainer_modules_v1.4.md §U6 字面 init 签名 +
//       kline_trainer_plan_v1.5.md §6.1.3 历史记录点击弹窗 +
//       docs/superpowers/specs/2026-06-20-history-dialog-centered-design.md（RFC #2：改屏幕居中弹窗）
//
// 命名沿用 iOS action-sheet（动作选择器）语义；**自 RFC #2 起呈现为屏幕居中弹窗（非底部 sheet）**：
// body 为全屏 ZStack = 半透明遮罩（点击=取消）+ 居中卡片；由 AppRootView 经 .overlay 装载（非 .sheet）。
//
// 决议（D1/D2/D6-D13，RFC #2 修订）：
// - D1 自定义居中卡片（遮罩 + 居中 ZStack），不用系统 .alert；跨 iOS17/macOS14/Catalyst 原生 SwiftUI
// - D2 点半透明遮罩 = 取消（onCancel）；卡片内仍保留显式「取消」按钮
// - D7 维持 import SwiftUI（不加 #if canImport(UIKit)）；Color/RoundedRectangle/.regularMaterial 均跨平台
// - D9 遮罩 Color.black.opacity(0.4).ignoresSafeArea()；卡片 .frame(maxWidth:280) + .regularMaterial 圆角16 + 阴影
// - D10 inner（标题 + 三 .bordered 按钮 + 各 frame/padding + 末 .padding(24)）字面不变；外层 ZStack/frame/background/shadow 新增
// - D13（原文件）Button tap 仅 fire callback，不调 dismiss（presentation 由 caller/router 负责）
// - 文件不引业务运行时类型；onReview/onReplay/onCancel @escaping（Swift 编译强制）

import SwiftUI

public struct HistoryActionSheet: View {
    private let content: HistoryActionContent
    private let onReview: () -> Void
    private let onReplay: () -> Void
    private let onCancel: () -> Void

    public init(record: TrainingRecord,
                onReview: @escaping () -> Void,
                onReplay: @escaping () -> Void,
                onCancel: @escaping () -> Void) {
        self.content = HistoryActionContent(record: record)
        self.onReview = onReview
        self.onReplay = onReplay
        self.onCancel = onCancel
    }

    public var body: some View {
        ZStack {
            // D2: 半透明遮罩，点击=取消
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onCancel() }

            // 居中卡片：以下 VStack….padding(24) = 原 body 字面不变（D10 inner）；
            //          .frame/.background/.shadow = RFC #2 外层新增（D9）
            VStack(alignment: .leading, spacing: 16) {
                // D3: 标题 = 股票名（代码），识别本条记录
                Text(content.title)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)

                // D6: 复盘 → onReview
                Button(action: onReview) {
                    Text("复盘")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                // D6: 再来一次 → onReplay
                Button(action: onReplay) {
                    Text("再来一次")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.bordered)

                Spacer().frame(height: 8)

                // D6: 取消置底 → onCancel（补满 modules §U6 init 字面要求）
                Button(action: onCancel) {
                    Text("取消")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 280)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
        }
    }
}

// MARK: - DEBUG-only preview fixture (fileprivate extension 防跨模块污染，机制同 U3/U5)

#if DEBUG
fileprivate extension TrainingRecord {
    /// Preview fixture。**fileprivate** 文件作用域，与同名 fixture 不冲突；不抽 PreviewFakes。
    static func preview() -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "preview.sqlite",
            createdAt: 1_700_000_000,
            stockCode: "600519",
            stockName: "贵州茅台",
            startYear: 2021,
            startMonth: 8,
            totalCapital: 102_345.67,
            profit: 2_345.67,
            returnRate: 0.0234,
            maxDrawdown: -0.0832,
            buyCount: 4,
            sellCount: 3,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }
}

#Preview {
    // D12: 渲染整体居中弹窗（含遮罩）
    HistoryActionSheet(
        record: .preview(),
        onReview: {},
        onReplay: {},
        onCancel: {}
    )
}
#endif
```

> 注意：inner `VStack(alignment:.leading, spacing:16){…}.padding(24)` 与改造前**逐字符相同**（标题 Text 修饰、三 Button 的 `.frame(maxWidth:.infinity)`/`.padding(.vertical:)`/`.buttonStyle(.bordered)`、`Spacer().frame(height:8)`）。仅在其外包 `ZStack{ 遮罩; <inner>.frame(maxWidth:280).background(...).shadow(...) }`。

- [ ] **Step 2: Run full host suite (编译 + 回归)**

Run: `cd ios/Contracts && swift test`
Expected: 全量 0 failures（`HistoryActionSheet.swift` 在 host 编译通过；`HistoryActionContentTests` / Task1 测试全绿；无测试数变化 vs Task 1 末）。

- [ ] **Step 3: Mac Catalyst build-for-testing 编译闸**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
Expected: `** TEST BUILD SUCCEEDED **`。

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift
git commit -m "feat(RFC#2): HistoryActionSheet body 重塑为居中弹窗（遮罩+卡片，inner 字面不变）"
```

---

## Task 3: AppRootView 呈现分流（sheet → overlay）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`

**Interfaces:**
- Consumes: Task 1 `HistoryDialogPresentation.{sheetItem,isHistoryPresented,sheetDismissMayApply}`；Task 2 `HistoryActionSheet(record:onReview:onReplay:onCancel:)`（init 不变）；既有 `AppRouter.{activeModal,review,replay}`、`SettingsPanel`、`SettlementView`。
- Produces: 集成后的居中 history 弹窗呈现（终态，供模拟器人工验收）。

> 本 Task **无 host 单测**（`AppRootView.swift` 是 `#if canImport(UIKit)` 门控，不参与 host 编译）。验证 = Mac Catalyst `build-for-testing` 编译闸 + iOS app build。

- [ ] **Step 1: 改 `.sheet` 分支 + 加 `.overlay` + `.animation` + 两个计算属性**

打开 `ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`。

**(a)** 把现有单一 `.sheet(item: $router.activeModal) { … }`（约 L41-53）替换为分流后的 `.sheet` + 新增 `.overlay` + `.animation`：

替换前（现状）：
```swift
        .sheet(item: $router.activeModal) { modal in
            switch modal {
            case .settings:
                SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance)
            case .history(let r):
                HistoryActionSheet(record: r,
                                   onReview: { Task { await router.review(id: r.id ?? -1) } },
                                   onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                                   onCancel: { router.activeModal = nil })
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            }
        }
```

替换后：
```swift
        // RFC #2：.history 经下方 .overlay 居中呈现；.settings/.settlement 仍走底部 sheet。
        .sheet(item: sheetModalBinding) { modal in
            switch modal {
            case .settings:
                SettingsPanel(settings: settings, api: api, cache: cache, acceptance: acceptance)
            case .settlement(let r):
                SettlementView(record: r, onConfirm: { Task { await router.confirmSettlement() } })
            case .history:
                // sheetModalBinding 已把 .history 滤成 nil → 此分支永不到达，仅为 switch 穷尽。
                // 到达即分流 binding 失效（assertionFailure 在 release 为 no-op，DEBUG 下暴露）。
                let _ = assertionFailure("sheetModalBinding 必须把 .history 滤到居中 overlay")
                EmptyView()
            }
        }
        // RFC #2 / D5：.history 经 .overlay 居中呈现（半透明遮罩内含居中卡片，由 HistoryActionSheet body 自绘）
        .overlay {
            if case .history(let r) = router.activeModal {
                HistoryActionSheet(record: r,
                                   onReview: { Task { await router.review(id: r.id ?? -1) } },
                                   onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                                   onCancel: { router.activeModal = nil })
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHistoryPresented)
```

**(b)** 在 `AppRootView` struct 内（`body` 之外，建议紧挨现有 `trainingBinding` 计算属性之后，约 L19-22 区域）新增两个 `private` 计算属性：

```swift
    // RFC #2：共享 sheet 的 item binding —— 滤掉 .history（走居中 overlay）+ High-1 守卫（dismiss 回写不清 history）
    private var sheetModalBinding: Binding<AppRouter.Modal?> {
        Binding(
            get: { HistoryDialogPresentation.sheetItem(for: router.activeModal) },
            set: { newValue in
                guard HistoryDialogPresentation.sheetDismissMayApply(current: router.activeModal) else { return }
                router.activeModal = newValue
            }
        )
    }

    // RFC #2：驱动 .history 居中弹窗淡入淡出的 Equatable 值（覆盖 onCancel/遮罩/review/replay 全部清除路径）
    private var isHistoryPresented: Bool {
        HistoryDialogPresentation.isHistoryPresented(router.activeModal)
    }
```

> 说明：`router` 为 `@State private var router: AppRouter`（`@Observable` 引用类型）；闭包内 `router.activeModal` 读写同一实例，`set` 写回触发观察刷新。`AppRouter.Modal` 为 `public`。`assertionFailure` 在 ViewBuilder switch case 中以 `let _ = assertionFailure(...)` 形式书写（声明语句，ViewBuilder 合法），随后产出 `EmptyView()`。

- [ ] **Step 2: Mac Catalyst build-for-testing 编译闸**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
Expected: `** TEST BUILD SUCCEEDED **`（`AppRootView` 在 Catalyst 编译通过：`sheetModalBinding`/`isHistoryPresented`/`.overlay`/`.animation` 接线无误）。

- [ ] **Step 3: iOS app build（集成编译）**

Run: `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`
（若报 SwiftPM 包依赖未解析，改 `-workspace ios/KlineTrainer/KlineTrainer.xcodeproj/project.xcworkspace`）
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: host suite 不回归（AppRootView 不参与 host 编译，但确认整体仍绿）**

Run: `cd ios/Contracts && swift test`
Expected: 全量 0 failures（与 Task 2 末同；本 Task 不改 host 编译单元）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift
git commit -m "feat(RFC#2): AppRootView 把 .history 从共享 sheet 分流到居中 overlay（High-1 守卫 + 动效）"
```

---

## Task 4: 冻结 spec 呈现措辞 + 验收清单

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§U6 标题/正文 + L108 目录注释；**不改名**）
- Modify: `kline_trainer_plan_v1.5.md`（§6.1.3 核对 + L275 注释，可选补「居中弹窗」；**不改名**）
- Create: `docs/superpowers/acceptance/2026-06-20-history-dialog-centered-acceptance.md`

> 纯文档。验证 = grep 确认「`HistoryActionSheet` 名零改动 + 呈现措辞已更新」+ 验收 doc 与 spec §8 一致。

- [ ] **Step 1: 改 modules §U6 呈现措辞（不改名）**

在 `kline_trainer_modules_v1.4.md`：
- 把 §U6 标题行 `### U6 历史动作表 \`HistoryActionSheet.swift\``（L2136 一带）改为 `### U6 历史动作弹窗（屏幕居中） \`HistoryActionSheet.swift\``。
- 若 §U6 正文有「底部」「动作表呈现」等措辞，改为「屏幕居中弹窗 + 半透明遮罩」。
- **不动** L2139 的 `struct HistoryActionSheet: View {` init 块、**不动** L2210 验收清单 `- [ ] U6 HistoryActionSheet` 条目（名不变）。
- L108 目录注释 `U5 Picker / U6 History`：若含「Sheet/底部」字样则核对，否则不动。

- [ ] **Step 2: 核对 plan §6.1.3（不改名）**

在 `kline_trainer_plan_v1.5.md`：
- §6.1.3「点击一条历史记录 → 弹出**提示框**」措辞已契合居中弹窗，**确认无「底部/sheet/动作表」残留**（实测 §6.1.3 原文为「弹出提示框：」，无需改；若发现残留底部描述则改「居中弹窗」）。
- L275 源码树注释 `│   │   └── HistoryActionSheet.swift # 历史记录点击→复盘/再来一次`：**文件名不动**，注释文字可选补为 `# 历史记录点击→复盘/再来一次（居中弹窗）`。

- [ ] **Step 3: 创建验收清单**

创建 `docs/superpowers/acceptance/2026-06-20-history-dialog-centered-acceptance.md`：

```markdown
# 验收清单：历史记录改屏幕居中弹窗（RFC #2）

## 1. host 单测（机器执行）
- [ ] 动作：`cd ios/Contracts && swift test --filter HistoryDialogPresentationTests`
      预期：`HistoryDialogPresentation routing` 7 个全绿。
- [ ] 动作：`cd ios/Contracts && swift test`
      预期：全量 0 failures；相对基线净 = +HistoryDialogPresentation(7) → 1113，`HistoryActionContentTests`/`AppRouterTests` 零改动全绿。

## 2. Mac Catalyst 编译（机器执行）
- [ ] 动作：`cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
      预期：`** TEST BUILD SUCCEEDED **`。

## 3. iOS app build（机器执行）
- [ ] 动作：`xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`
      预期：`** BUILD SUCCEEDED **`。

## 4. 模拟器人工验收（iPhone 17 Pro + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 首页点一条历史记录 | 屏幕**正中**弹出卡片（标题=股票名（代码）+ 复盘/再来一次/取消），背景半透明变暗，**非底部滑出**；弹窗**稳定显示不秒关**（验 High-1 守卫） | ☐ |
| 2 | 点「复盘」 | 进入 Review 模式训练页，弹窗消失（淡出） | ☐ |
| 3 | 点「再来一次」 | 进入 Replay 模式训练页，弹窗消失（淡出） | ☐ |
| 4 | 点「取消」 | 弹窗消失，停留首页，不进训练 | ☐ |
| 5 | 点卡片外的半透明遮罩 | 弹窗消失（等同取消），停留首页 | ☐ |
| 6 | 弹窗视觉 | 居中小卡片 + 圆角 + 阴影 + 变暗遮罩；淡入淡出 | ☐ |
| 7 | 点齿轮进设置 | 设置面板仍从**底部**滑出（未受影响） | ☐ |
| 8 | 跑完一局正常结束 | 结算窗仍从**底部**滑出（未受影响） | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 复盘/再来一次后返回首页 | 导航/teardown 一切如常（AppRouter 逻辑未变） | ☐ |
| 2 | review/replay 失败（如缺数据） | 「出错了」alert 仍正常弹出（弹窗先消失再弹 alert，不叠） | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（2C/2H/3M/3L）→ 全修（撤销改名等）→ R2 APPROVE。commits 25d8a34 / 9b27cd3 / d90b668。
- plan：<填 plan-stage review 结论>。
- 实现期（subagent-driven，4 task 两阶段）：<填>。
- verification：<填 host/Catalyst/app 三项实跑>。
- branch-diff：<填整体对抗性 review 结论>。
```

- [ ] **Step 4: 验证「零改名 + 措辞已改」**

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
# 4a：确认无任何文件把 HistoryActionSheet 改成了 HistoryActionDialog（应 0）
grep -rn "HistoryActionDialog" kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md ios/Contracts/Sources || echo "OK: 无 HistoryActionDialog（未改名）"
# 4b：确认 modules §U6 仍含 HistoryActionSheet 名 + 已含「居中」措辞
grep -n "HistoryActionSheet" kline_trainer_modules_v1.4.md
grep -n "居中" kline_trainer_modules_v1.4.md | grep -i "U6\|弹窗"
```
Expected：4a 输出 `OK: 无 HistoryActionDialog（未改名）`；4b 显示 `HistoryActionSheet` 名仍在且 §U6 标题含「居中」。

- [ ] **Step 5: Commit**

```bash
git add kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md \
        docs/superpowers/acceptance/2026-06-20-history-dialog-centered-acceptance.md
git commit -m "docs(RFC#2): modules §U6/plan §6.1.3 呈现措辞改居中弹窗（不改名）+ 验收清单"
```

---

## 实现完成后（subagent-driven 收尾）

1. **verification-before-completion**（亲跑三绿）：
   - `cd ios/Contracts && swift test`（全量 0 failures）
   - `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`（TEST BUILD SUCCEEDED）
   - `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`（BUILD SUCCEEDED）
2. **requesting-code-review / 整体 branch-diff**：Opus 4.8 xhigh 对抗性 review（whole-branch，merge-base `55a677f` → HEAD）到收敛。
3. **finishing-a-development-branch → PR + merge**：`--admin` 旁路缺失 codex-verify-pass（opus 通道无 codex ledger），CI 三项须绿。回填验收 §6 ledger。
