# 设计文档：历史记录改屏幕居中弹窗（UI 改版 RFC #2）

> **状态**：设计已与用户确认（D1=自定义居中卡片，D2=点遮罩=取消）。本文档为冻结 spec 的修订 RFC，需经 Opus 4.8 xhigh 对抗性 review 收敛后转 writing-plans。
> **日期**：2026-06-20
> **前序**：UI 改版 4 子项 —— #3 坐标轴（PR #124 merged）、#1 买卖小操作栏（PR #125 merged）已落地；本 RFC = #2。
> **来源**：运行时验证 2026-06-17 第 #6-orig 项「训练历史记录点击后改屏幕中间小弹窗」（见 `project_runtime_verification_findings_2026_06_17`）。

---

## 1. 目标与范围

### 1.1 一句话目标
把「点首页一条训练历史 → 弹出『复盘 / 再来一次 / 取消』」这个 modal 的呈现方式，从 iPhone 上的**底部 sheet**改为**屏幕正中卡片 + 半透明遮罩**。

### 1.2 范围内（in scope）
- 仅改 `.history` 这一个 modal 的呈现容器（bottom sheet → 居中 overlay）。
- 重塑 `HistoryActionSheet` 的 body 为「半透明遮罩 + 居中卡片」（**类型名/init 签名不变**，见 D3）；inner 卡片内容（标题 + 三个 `.bordered` 按钮 + 三回调）字面不变。
- 相应修订冻结 spec **呈现措辞**（modules §U6 / plan §6.1.3），**不改组件名**。
- 新增本 RFC 的验收清单。

### 1.3 范围外（out of scope，明确不碰）
- `.settings`（设置面板）与 `.settlement`（结算窗）两个 modal —— **维持现有底部 sheet 呈现，一字不改**。
- `AppRouter` 的导航状态机逻辑（`selectRecord` / `review` / `replay` / `activeModal` 语义）—— **不改**。
- `HistoryActionContent`（纯值标题）—— **不改**。
- **任何组件改名** —— 经 spec 对抗性 review 评估改名波及面（13 文件含历史交付凭证），维持 `HistoryActionSheet`（见 D3）。
- 任何业务/引擎/持久化/契约（CONTRACT_VERSION）改动。
- 历史行本身的展示（plan §6.1.3 「每行记录展示内容」表）—— 不碰。

---

## 2. 现状（待改造的代码事实）

精确锚点（写 spec 时实测，下游 plan 须按当时实际行号复核）：

- **`ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`**
  - L9-20：`public enum Modal: Identifiable { case settings; case history(TrainingRecord); case settlement(TrainingRecord); var id … }`。
  - L36：`public var activeModal: Modal?`。
  - L91-93：`selectRecord(id:)` 命中记录后置 `activeModal = .history(r)`。
  - L95-109：`review(id:)` / `replay(id:)` 进入前各自先 `activeModal = nil` 再起训练。
  - L161-163：`presentReplaySettlement(record:)` 置 `activeModal = .settlement(record)`（replay 结束的结算窗，**同样走 sheet**，故 settlement 必须留在 sheet）。

- **`ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift`**
  - L41-53：单一 `.sheet(item: $router.activeModal) { modal in switch modal { case .settings: …; case .history(let r): HistoryActionSheet(record:onReview:onReplay:onCancel:); case .settlement(let r): … } }`。三个 case 都经这一个 sheet，iPhone 上都是底部滑出。
  - 整文件 `#if canImport(UIKit)` 门控（不参与 macOS host 编译，故无 host 单测）。

- **`ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionSheet.swift`**
  - `public struct HistoryActionSheet: View`，init `(record: TrainingRecord, onReview: @escaping () -> Void, onReplay: @escaping () -> Void, onCancel: @escaping () -> Void)`。
  - body：`VStack(alignment:.leading, spacing:16)` = `Text(content.title).font(.headline)` 居中 + 三个 `.bordered` 按钮（复盘 / 再来一次 / 取消）+ `.padding(24)`。
  - `import SwiftUI`（非 UIKit 门控，host 可编译但 D10 不 host 测）。
  - 文件内 `#if DEBUG` 区有 `fileprivate extension TrainingRecord.preview()` + `#Preview`。

- **`ios/Contracts/Sources/KlineTrainerContracts/UI/HistoryActionContent.swift`**
  - `public struct HistoryActionContent: Equatable, Sendable { let title: String; init(record:) }`，仅 `import Foundation`。**不改。**

- **`ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift`** —— host 测试，**不改**（回归网）。

> iPhone 上 `.sheet(item:)` 默认为底部卡片（large detent）；iPad/Mac 上已是居中卡片。本 RFC 主要改变 iPhone 体感（统一为居中）。iOS 17 部署目标无原生「居中 sheet」API（`.presentationDetents` 仅支持底部高度档，不支持居中），故自定义 overlay 是实现居中卡片的标准做法。

---

## 3. 设计决策表

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| **D1** | 居中弹窗的渲染机制 | **自定义居中卡片**（遮罩 + 居中 ZStack），**不用**系统 `.alert` | 保留用户在 U6 已批准的卡片视觉（标题 headline + 三 `.bordered` 按钮）；外科式复用现有 body；与 #1 TradeBar 的 overlay 范式一致。`.alert` 虽最省代码但按钮=系统样式、丢卡片观感，被否。用户经可视化 mockup 二选一明确选此项。 |
| **D2** | 点半透明遮罩（卡片外暗区）的行为 | **等同「取消」**（调 `onCancel`） | iOS 自定义弹窗常见友好行为；卡片内仍保留显式「取消」按钮（无障碍 + 冗余安全）。用户确认。 |
| **D3** | 组件是否改名 | **维持 `HistoryActionSheet`（不改名，文件/类型/init 签名全不变）** | 初稿曾拟改名 `HistoryActionDialog`；spec 对抗性 review 揭示改名波及全仓 **13 文件**（含 PR #72 历史交付凭证 acceptance/plan、composition-root plan、多份 sibling design、未接 CI 的验收脚本），与「最小改动」相悖且徒增 provenance 风险。`ActionSheet` = iOS「动作选择器」语义，本不绑定底部呈现；以文件 doc 注释澄清「自 RFC #2 起居中呈现」即可。**与 #1 PositionPicker→TradeBar 的区别**：#1 是交互范式整体替换（模态→内联条）且旧组件被删，本 RFC 仅改一个 modal 的呈现位置、组件职责不变，不构成改名理由。 |
| **D4** | `HistoryActionContent` 是否改名/改逻辑 | **都不**（保留 `HistoryActionContent`） | 名字已通用（非 `Sheet`）；标题格式化逻辑无变化 → host 测试零改动，作回归网。 |
| **D5** | 呈现 API | **`.overlay`**（挂在 `NavigationStack` 上），**不用** `.fullScreenCover` / `.sheet` | iOS 17 无原生居中 sheet；overlay 最轻、可自控居中 + 遮罩 + 安全区。`.fullScreenCover` 过重。 |
| **D6** | `.history` 如何从共享 sheet 分流 | `.sheet(item:)` 的 item binding 派生为「滤掉 `.history` → 返回 nil」，且 `set` **带守卫**不清 history 态（High-1 修）；`.settings`/`.settlement` 不受影响 | binding 永不对 `.history` 返非 nil → sheet 不会以 `.history` 触发（**杜绝闪空白底卡**）。switch 仍须穷尽，`.history` 分支留 `EmptyView()`（dead，因 binding 已滤）+ **DEBUG `assertionFailure`**（若真到达即暴露分流失效，把静默陷阱变可观测）。 |
| **D7** | `HistoryActionSheet` 平台门控 | 维持 `import SwiftUI`（**不**加 `#if canImport(UIKit)`），跨 iOS/macOS/Catalyst | 与现状一致；新 body 用 `Color`/`RoundedRectangle`/`.regularMaterial` 均 SwiftUI 跨平台 API，host(macOS14) 可编译；D10 不写 host 单测；overlay 接线在 UIKit 门控的 `AppRootView`。 |
| **D8** | CONTRACT_VERSION | **不 bump**（维持 "1.6"） | 无模型 / Codable / DDL 改动（同 #1）。 |
| **D9** | 遮罩与卡片样式 | 遮罩 `Color.black.opacity(0.4)` + `.ignoresSafeArea()`；卡片 = 现有 VStack 包 `.background(.regularMaterial, in: RoundedRectangle(cornerRadius:16))` + 阴影 + `maxWidth ≈ 280`，按钮维持 `.bordered` | 还原「屏幕中央小卡片」观感；`.regularMaterial` 与本仓 UI 壳（#1 TradeBar `.thinMaterial`）一致、自适应明暗；具体数值由 plan 钉死，可在人工验收微调。 |
| **D10** | inner 卡片内容 vs 外层结构 | **inner（标题 Text + 三 `.bordered` 按钮 + 各自 frame/padding + 末 `.padding(24)`）字面不变**；**外层新增** ZStack 遮罩 + `.frame(maxWidth:280)` + `.background(.regularMaterial,…)` + `.shadow`（D9） | 复盘→`onReview`、再来一次→`onReplay`、取消→`onCancel` 路由与按钮文案全不变；body 外层必然重塑（现 body 无遮罩/背景/maxWidth），故表述为「inner 不变 + 外层重塑」而非笼统「字节级不变」（修 Medium-3 D9/D10 矛盾）。 |
| **D11** | `AppRouter` 逻辑 | **不改** | `selectRecord` 仍置 `.history`、`review`/`replay` 仍清 `activeModal`；状态机 host 测试（`AppRouterTests`）天然回归绿。 |
| **D12** | DEBUG 预览 | `#Preview` 渲染**含遮罩的整体弹窗**；保留 `fileprivate extension TrainingRecord.preview()`（机制同 U3/U5/U6） | 预览即所见；fileprivate 防跨模块污染。 |
| **D13** | 出现/消失动效 | overlay 条件视图挂 `.transition(.opacity)`，由 `AppRootView` 链上 `.animation(.easeInOut(0.2), value: isHistoryPresented)`（`isHistoryPresented:Bool` 计算属性）驱动 | 居中弹窗硬切突兀，淡入是标准润色。**关键（修 High-2）**：`.animation(_:value:)` 按观测值变化驱动，覆盖 onCancel/遮罩/`review`/`replay` **全部**清除路径——包括 `review`/`replay` 在 `AppRouter` 内部清 `activeModal`（D11 不改）的路径，**无需在赋值点包 `withAnimation` → 不触碰 `AppRouter`**。Bool 驱动值天然 `Equatable`（`Modal` 未声明 Equatable，故不能直接用 `value: activeModal`）。 |

---

## 4. 架构

### 4.1 呈现分流（核心改造，全在 `AppRootView`）
现状一个 `.sheet` 承载三 modal。改造后（`HistoryActionSheet` 类型名不变，见 D3）：

```
NavigationStack { HomeView … .navigationDestination(…) }
  .sheet(item: sheetModalBinding) { modal in                 // 派生 binding：滤掉 .history
      switch modal {
      case .settings:          SettingsPanel(…)              // 不变
      case .settlement(let r): SettlementView(…)             // 不变
      case .history:           EmptyView()                   // dead：binding 已滤 .history，永不到达；
                                                             //   plan 须加 DEBUG assertionFailure（到达=分流失效）
      }
  }
  .overlay {                                                 // 新增：居中 history 弹窗
      if case .history(let r) = router.activeModal {
          HistoryActionSheet(record: r,
                             onReview: { Task { await router.review(id: r.id ?? -1) } },
                             onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                             onCancel: { router.activeModal = nil })
              .transition(.opacity)                          // D13（由下方 .animation(value:) 驱动）
      }
  }
  .animation(.easeInOut(duration: 0.2), value: isHistoryPresented)   // D13：驱动 overlay 插入/移除淡入淡出
  .alert(…) .task(…) .preferredColorScheme(…)                // 不变
```

派生 binding + 动画驱动值（带 High-1 守卫；精确落点由 plan 钉死）：
```swift
private var sheetModalBinding: Binding<AppRouter.Modal?> {
    Binding(
        get: { if case .history = router.activeModal { return nil }; return router.activeModal },
        set: { newValue in
            // High-1 守卫：history 永不经 sheet 呈现；sheet 自身 dismiss 的 set(nil) 不得清掉 history 态
            if case .history = router.activeModal { return }
            router.activeModal = newValue
        }
    )
}
private var isHistoryPresented: Bool {            // D13 动画驱动值（Equatable），覆盖所有清除路径
    if case .history = router.activeModal { return true }; return false
}
```
回调与现状字面一致（取自 AppRootView L47-49 现有闭包）：`onReview`/`onReplay` 走 `router.review/replay`（**内部各自先清 `activeModal=nil`**），`onCancel` 置 `activeModal=nil`。**动效经 `.animation(_:value: isHistoryPresented)` 驱动，覆盖 onCancel/遮罩/review/replay 全部清除路径——无需在赋值点包 `withAnimation`，故不触碰 `AppRouter`（D11 安全，修 High-2）。**

> **High-1 风险与守卫**：若 `set` 裸写 `router.activeModal = $0`，则在 `.settings/.settlement` → `.history` 等切换、或 SwiftUI 对 item-binding 的 dismiss 回写时，`set(nil)` 可能误清刚置位的 `.history`，导致 dialog 秒关。守卫「当前若已是 `.history` 则 `set` 为 no-op」根除此路径（history 本就不该由 sheet 驱动）。plan 须实测「点 history → 弹窗稳定显示不秒关」（§8 场景 1）。

### 4.2 `HistoryActionSheet`（类型名不变，重塑 body 为居中弹窗）
现 body 仅是卡片 VStack；改造 = **外层包一层 ZStack（遮罩 + 居中卡片框）**，**inner VStack 内容字面不变**（D10）：
```
public struct HistoryActionSheet: View {        // 类型名/init 签名不变（D3）
    init(record:onReview:onReplay:onCancel:)

    body = ZStack {
        Color.black.opacity(0.4).ignoresSafeArea()
            .onTapGesture { onCancel() }                        // D2：点遮罩=取消
        VStack(alignment: .leading, spacing: 16) {              // ↓↓ inner = 现 body 字节不变 ↓↓
            Text(content.title).font(.headline).frame(maxWidth:.infinity, alignment:.center).padding(.bottom,8)
            Button(action: onReview){ Text("复盘")… }.buttonStyle(.bordered)
            Button(action: onReplay){ Text("再来一次")… }.buttonStyle(.bordered)
            Spacer().frame(height: 8)
            Button(action: onCancel){ Text("取消")… }.buttonStyle(.bordered)
        }
        .padding(24)                                            // ↑↑ 以上含 .padding(24) = 现 body 原样 ↑↑
        .frame(maxWidth: 280)                                   // ↓ 外层新增（D9） ↓
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 20)
    }
}
```
- `content = HistoryActionContent(record:)`（不变）。
- 文件顶 doc 注释新增一句澄清（D3）：「命名沿用 iOS action-sheet（动作选择器）语义；自 RFC #2 起呈现为**屏幕居中弹窗**（非底部 sheet）。」并更新原文件决议块（原 D1/D2/D13 等）以反映「ZStack 遮罩 + 居中」。
- 按钮 tap 仅 fire callback，不自行 dismiss（presentation 由 caller/router 控制；沿用原文件决议「D13 不调 dismiss」）。
- `#if DEBUG` 区保留 `fileprivate extension TrainingRecord.preview()` + 渲染**整体（含遮罩）**的 `#Preview`。

### 4.3 数据流
`HomeView` 点历史行 → `router.selectRecord(id)` → `activeModal = .history(r)` →
`AppRootView.overlay` 命中 `.history(r)` → 渲染 `HistoryActionSheet`（居中弹窗）→
点「复盘」→ `router.review(id)`（内部清 modal + 起 Review）；点「再来一次」→ `router.replay(id)`；
点「取消」或**点遮罩** → `activeModal = nil`。
**所有清除路径**（onCancel/遮罩/review/replay）均使 `activeModal` 离开 `.history` → overlay 条件 `if case .history` 失配 → 移除，且 `isHistoryPresented` 翻转触发 `.animation(value:)` 淡出（无需在各清除点包 `withAnimation`，故 review/replay 的 router 内部清除亦被覆盖，不违反 D11）。

### 4.4 错误处理
无新增错误路径。`review`/`replay` 的失败仍由 `AppRouter.setError` → `.alert("出错了")` 既有路径处理（不变）。

---

## 5. 冻结 spec 修订点

**本 RFC 不改任何组件名（D3）**，故全仓 `HistoryActionSheet` 引用**全部保持不变**——无 provenance 改名风险。仅修订以下「呈现描述」措辞（**类型名 / init 签名 / 文件名一律不动**）：

| 文件 | 位置（写 spec 时实测） | 改动 |
|------|------|------|
| `kline_trainer_modules_v1.4.md` | §U6 标题 L2136「U6 历史动作表 `HistoryActionSheet.swift`」+ L108 目录注释「U5 Picker / U6 History」 | 正文「历史动作**表** / 底部」等呈现措辞改「历史动作**弹窗**（屏幕居中）」；**`HistoryActionSheet` 名 + L2139 init 块 + L2210 验收条目一律不动**。 |
| `kline_trainer_plan_v1.5.md` | §6.1.3「点击一条历史记录 → 弹出**提示框**」+ L275 源码树注释 | §6.1.3 原文已是「提示框」与居中弹窗契合，仅核对清理任何残留「底部 / sheet / 动作表」描述；L275 `HistoryActionSheet.swift # 历史记录点击→…` **文件名不动**，注释文字可选补「（居中弹窗）」。 |

### 5.1 改名引用面核实（全仓 grep 实测，13 文件命中 `HistoryActionSheet`，均**不改名**）
- **本 RFC 触及（呈现改造，名不变）**：`ios/.../App/AppRootView.swift`（改 `.history` callsite 呈现：sheet→overlay 分流，类型名不变）、`ios/.../UI/HistoryActionSheet.swift`（重塑 body，类型名不变）。
- **frozen spec（仅改呈现措辞，名不变）**：`kline_trainer_modules_v1.4.md`(3 处)、`kline_trainer_plan_v1.5.md`(1 处注释)。
- **历史交付凭证（PR #72，按 shipped 保留不动）**：`docs/acceptance/2026-05-29-pr-u6-history-action-sheet.md`(24)、`docs/superpowers/plans/2026-05-29-pr-u6-history-action-sheet.md`(48)、`scripts/acceptance/plan_u6_history_action_sheet.sh`(3，**实测未接任何 CI workflow**——`.github/workflows` 仅 `hardening_6_gate.yml` 一个 acceptance job，故旧脚本不因本 RFC red)、`docs/governance/2026-06-01-wave1-completion.md`(1)、`docs/superpowers/specs/2026-05-19-wave1-outline-design.md`(1)。
- **sibling 已交付 design/plan（保留不动）**：`docs/superpowers/plans/2026-06-08-pr11-composition-root.md`(4)、`docs/superpowers/specs/2026-06-08-wave2-pr11-composition-root-design.md`(4)、`docs/superpowers/specs/2026-06-07-wave2-u1-home-view-design.md`(2)、`docs/superpowers/specs/2026-06-20-trade-bar-inline-design.md`(1)。

> 不改名 → 上述 11 个非本 RFC 文件零触碰，根除「改名遗漏 / 污染历史凭证」两类风险（修 Critical-1 虚构行号 + Critical-2 波及面）。

---

## 6. 测试策略（诚实交代）

本 RFC 是**纯呈现层改造**，几乎无新增可 host 测试的纯逻辑。诚实分层：

1. **host 回归网（机器执行，必须全绿）**：
   - `HistoryActionContent` 现有 host 测试 —— 零改动，仍绿（标题格式化未变）。
   - `AppRouter` host 测试（`AppRouterTests`）—— 零改动，仍绿（状态机未变；`selectRecord→.history`、`review/replay` 清 modal 的行为在此层有覆盖，实测 `AppRouterTests` 含相应断言）。
   - 全量 `swift test` —— **零引用改名**（D3 不改名），净测试改动 = 0 新增 / 0 删除，全绿。
2. **新呈现行为（SwiftUI shell，D10 不写 host 单测）**：
   - **Mac Catalyst `build-for-testing` 编译闸** —— overlay 分流接线 + body 重塑编译通过。
   - **iOS app build** —— 集成编译通过。
   - **模拟器人工验收**（iPhone 17 Pro + seed fixture）—— 居中显示、点遮罩关闭、设置/结算仍底部、三按钮路由正确（运行时观感，自动化测不到，见 §8 验收清单）。

> 不为「居中/遮罩」臆造 host 单测（SwiftUI 视图层在本仓 D10 一贯不 host 测）。状态机层的真实覆盖来自不变的 `AppRouterTests`；视图呈现层靠编译闸 + 人工验收。这是本仓 UI 壳一贯的诚实测试边界，非偷工。

---

## 7. 风险

| # | 风险 | 缓解 |
|---|------|------|
| **R1** | 分流 binding `get` 写错 → 设置/结算被误吞，或 `.history` 闪一下空白底 sheet | binding `get` 对 `.history` 返 nil + overlay 用 `if case .history` 独立判定 + dead 分支 DEBUG `assertionFailure`；Catalyst 编译 + 人工验收场景 7/8（设置/结算仍底部、history 无空 sheet）覆盖。 |
| **R2** | 分流 binding `set` 回写误清 history → dialog 秒关（High-1） | `set` 守卫「当前若 `.history` 则 no-op」（§4.1）；人工验收**场景 1 专项**（点 history → 弹窗稳定显示不秒关）。 |
| **R3** | overlay 遮罩盖不住安全区/导航栏，露白边 | 遮罩 `.ignoresSafeArea()`。 |
| **R4** | overlay 与 `.alert("出错了")` 同时出现层级打架（如 review 失败弹 alert） | `review/replay` 先清 `activeModal=nil`（overlay 随即移除）再可能 setError；时序上 dialog 先消失 alert 后现，不叠。人工验收回归 §8 回归项覆盖。 |
| **R5** | 动效不触发或某清除路径漏动画 | 用 `.animation(_:value: isHistoryPresented)`（Bool 计算属性）驱动，覆盖 onCancel/遮罩/review/replay 全部清除路径（含 router 内部清除，不碰 D11，修 High-2）；动效缺失为润色非硬伤，不阻断功能。 |

---

## 8. 验收清单（草案，正式版随 plan 落地为独立文件）

### 8.1 机器执行
- host：`cd ios/Contracts && swift test` 全量 0 failures；净测试数变化 = 0（D3 不改名，零引用改动）。
- Catalyst：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` → `TEST BUILD SUCCEEDED`。
- iOS app：`xcodebuild build … -scheme KlineTrainer …` → `BUILD SUCCEEDED`。

### 8.2 模拟器人工验收（iPhone 17 Pro + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 首页点一条历史记录 | 屏幕**正中**弹出卡片（标题=股票名（代码）+ 复盘/再来一次/取消），背景半透明变暗，**非底部滑出**；弹窗**稳定显示不秒关**（验 High-1 守卫） | ☐ |
| 2 | 点「复盘」 | 进入 Review 模式训练页，弹窗消失 | ☐ |
| 3 | 点「再来一次」 | 进入 Replay 模式训练页，弹窗消失 | ☐ |
| 4 | 点「取消」 | 弹窗消失，停留首页，不进训练 | ☐ |
| 5 | 点卡片外的半透明遮罩 | 弹窗消失（等同取消），停留首页 | ☐ |
| 6 | 弹窗视觉 | 居中小卡片 + 圆角 + 阴影 + 变暗遮罩；淡入淡出 | ☐ |
| 7 | 点齿轮进设置 | 设置面板仍从**底部**滑出（未受影响） | ☐ |
| 8 | 跑完一局正常结束 | 结算窗仍从**底部**滑出（未受影响） | ☐ |

### 8.3 回归
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 复盘/再来一次后返回首页 | 导航/teardown 一切如常（router 逻辑未变） | ☐ |
| 2 | review/replay 失败（如缺数据） | 「出错了」alert 仍正常弹出（弹窗先消失再弹 alert，不叠） | ☐ |

---

## 9. 流程与治理

- **评审通道**：Opus 4.8 xhigh 对抗性 review 代 codex（周配额耗尽；与 PR #123/#124/#125 一致），把守 **spec / plan / 整体 branch-diff** 三道闸门到收敛。
- **实现**：superpowers subagent-driven（fresh subagent per task + 两阶段 spec+quality review）。
- **不 bump CONTRACT_VERSION**（D8）。无 trust-boundary（`.github/workflows`）改动 → 不强制 codex CI 通道。
- **merge**：`--admin` 旁路缺失的 codex-verify-pass（opus 通道无 codex ledger），真实 CI 三项（host/Catalyst/app）须绿。
