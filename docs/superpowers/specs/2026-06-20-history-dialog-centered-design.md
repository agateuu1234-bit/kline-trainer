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
- 卡片**内容**（标题 + 三个 `.bordered` 动作按钮 + 三个回调）保持字面不变。
- 把组件名 `HistoryActionSheet` 改为 `HistoryActionDialog`（init 签名不变）。
- 相应修订冻结 spec 文字（modules §U6 / plan §6.1.3）。
- 新增本 RFC 的验收清单。

### 1.3 范围外（out of scope，明确不碰）
- `.settings`（设置面板）与 `.settlement`（结算窗）两个 modal —— **维持现有底部 sheet 呈现，一字不改**。
- `AppRouter` 的导航状态机逻辑（`selectRecord` / `review` / `replay` / `activeModal` 语义）—— **不改**。
- `HistoryActionContent`（纯值标题）—— **不改**（名字已是通用的 `Content`，非 `Sheet`，无需改名）。
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

> iPhone 上 `.sheet(item:)` 默认为底部卡片（large detent）；iPad/Mac 上已是居中卡片。本 RFC 主要改变 iPhone 体感（统一为居中）。iOS 17 部署目标无原生「居中 sheet」API，故自定义 overlay 是实现居中卡片的标准做法。

---

## 3. 设计决策表

| # | 决策 | 选择 | 理由 |
|---|------|------|------|
| **D1** | 居中弹窗的渲染机制 | **自定义居中卡片**（遮罩 + 居中 ZStack），**不用**系统 `.alert` | 保留用户在 U6 已批准的卡片视觉（标题 headline + 三 `.bordered` 按钮）；外科式复用现有 body；与 #1 TradeBar 的 overlay 范式一致。`.alert` 虽最省代码但按钮=系统样式、丢卡片观感，被否。用户经可视化 mockup 二选一明确选此项。 |
| **D2** | 点半透明遮罩（卡片外暗区）的行为 | **等同「取消」**（调 `onCancel`） | iOS 自定义弹窗常见友好行为；卡片内仍保留显式「取消」按钮（无障碍 + 冗余安全）。用户确认。 |
| **D3** | 组件改名 | `HistoryActionSheet` → **`HistoryActionDialog`**（文件 + 类型；**init 签名字面不变** `(record:onReview:onReplay:onCancel:)`） | 居中弹窗再叫「Sheet」会误导每个读冻结 spec 的人（#1 的 C1 provenance 教训）。签名不变 → 低风险改名。与 #1 PositionPicker→TradeBar 的范式改名一致。 |
| **D4** | `HistoryActionContent` 是否改名/改逻辑 | **都不**（保留 `HistoryActionContent`） | 名字已通用（非 `Sheet`）；标题格式化逻辑无变化 → host 测试零改动，作回归网。 |
| **D5** | 呈现 API | **`.overlay`**（挂在 `NavigationStack` 上），**不用** `.fullScreenCover` / `.sheet` | iOS 17 无原生居中 sheet；overlay 最轻、可自控居中 + 遮罩 + 安全区。`.fullScreenCover` 过重。 |
| **D6** | `.history` 如何从共享 sheet 分流 | `.sheet(item:)` 的 item binding 派生为「滤掉 `.history` → 返回 nil」；`.settings`/`.settlement` 不受影响 | binding 永不对 `.history` 返非 nil → sheet 不会以 `.history` 触发（**杜绝闪空白底卡**）。switch 仍须穷尽，`.history` 分支留 `EmptyView()`（dead，因 binding 已滤）。 |
| **D7** | `HistoryActionDialog` 平台门控 | 维持 `import SwiftUI`（**不**加 `#if canImport(UIKit)`），跨 iOS/macOS/Catalyst | 与现 `HistoryActionSheet` 一致；host 可编译但 D10 不写 host 单测；overlay 接线在 UIKit 门控的 `AppRootView`。 |
| **D8** | CONTRACT_VERSION | **不 bump**（维持 "1.6"） | 无模型 / Codable / DDL 改动（同 #1）。 |
| **D9** | 遮罩与卡片样式 | 遮罩 `Color.black.opacity(0.4)` + `.ignoresSafeArea()`；卡片 = 现有 VStack 包 `.background(.regularMaterial, in: RoundedRectangle(cornerRadius:16))` + 阴影 + `maxWidth ≈ 280`，按钮维持 `.bordered` | 还原「屏幕中央小卡片」观感；`.regularMaterial` 与本仓 UI 壳（#1 TradeBar `.thinMaterial`）一致、自适应明暗；具体数值由 plan 钉死，可在人工验收微调。 |
| **D10** | 卡片内容（标题 + 三按钮 + 回调路由） | **字节级不变**（从现 `HistoryActionSheet` body 原样搬入） | 复盘→`onReview`、再来一次→`onReplay`、取消→`onCancel` 全不变；零功能改动。 |
| **D11** | `AppRouter` 逻辑 | **不改** | `selectRecord` 仍置 `.history`、`review`/`replay` 仍清 `activeModal`；状态机 host 测试（`AppRouterTests`）天然回归绿。 |
| **D12** | DEBUG 预览 | `#Preview` 渲染**含遮罩的 dialog**整体；保留 `fileprivate extension TrainingRecord.preview()`（机制同 U3/U5/U6） | 预览即所见；fileprivate 防跨模块污染。 |
| **D13** | 出现/消失动效 | 简单淡入淡出 `.transition(.opacity)` + 呈现/取消时 `withAnimation` | 居中弹窗硬切显突兀；淡入是标准低风险润色；非新功能、不引入交互复杂度。 |

---

## 4. 架构

### 4.1 呈现分流（核心改造，全在 `AppRootView`）
现状一个 `.sheet` 承载三 modal。改造后：

```
NavigationStack { HomeView … .navigationDestination(…) }
  .sheet(item: <派生：滤掉 .history 的 activeModal binding>) { modal in
      switch modal {
      case .settings:          SettingsPanel(…)            // 不变
      case .settlement(let r): SettlementView(…)           // 不变
      case .history:           EmptyView()                 // dead（binding 已滤），仅为 switch 穷尽
      }
  }
  .overlay {                                               // 新增
      if case .history(let r) = router.activeModal {
          HistoryActionDialog(record: r,
                              onReview: { Task { await router.review(id: r.id ?? -1) } },
                              onReplay: { Task { await router.replay(id: r.id ?? -1) } },
                              onCancel: { router.activeModal = nil })
              .transition(.opacity)                        // D13
      }
  }
  .alert(…) .task(…) .preferredColorScheme(…)              // 不变
```

派生 binding（概念，精确代码由 plan 钉死）：
```swift
private var sheetModalBinding: Binding<AppRouter.Modal?> {
    Binding(
        get: { if case .history = router.activeModal { return nil }; return router.activeModal },
        set: { router.activeModal = $0 }   // sheet 仅在 dismiss 时回写 nil；其余路径由 router 方法置位
    )
}
```
回调与现状字面一致（取自 AppRootView L47-49 现有闭包）：`onReview`/`onReplay` 走 `router.review/replay`（内部已清 modal），`onCancel` 置 `activeModal = nil`。

### 4.2 `HistoryActionDialog`（由 `HistoryActionSheet` 改名 + 重塑 body）
```
public struct HistoryActionDialog: View {
    init(record:onReview:onReplay:onCancel:)   // 签名字面不变（D3）

    body = ZStack {
        Color.black.opacity(0.4).ignoresSafeArea()
            .onTapGesture { onCancel() }                 // D2：点遮罩=取消
        VStack(spacing:16) {                             // = 现有卡片内容（D10），标题+三 .bordered 按钮
            Text(content.title).font(.headline) …
            Button("复盘", action: onReview).buttonStyle(.bordered) …
            Button("再来一次", action: onReplay).buttonStyle(.bordered) …
            Button("取消", action: onCancel).buttonStyle(.bordered) …
        }
        .padding(24)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius:16))
        .shadow(radius: 20)
    }
}
```
- `content = HistoryActionContent(record:)`（不变）。
- 按钮 tap 仅 fire callback，不自 dismiss（caller/router 负责 presentation；同现 D13 原则）。
- `#if DEBUG` 区保留 `fileprivate extension TrainingRecord.preview()` + 渲染整体 dialog 的 `#Preview`。

### 4.3 数据流
`HomeView` 点历史行 → `router.selectRecord(id)` → `activeModal = .history(r)` →
`AppRootView.overlay` 命中 `.history(r)` → 渲染 `HistoryActionDialog` →
点「复盘」→ `router.review(id)`（清 modal + 起 Review）；点「再来一次」→ `router.replay(id)`；
点「取消」或**点遮罩** → `activeModal = nil`（overlay 条件 `if case .history` 失配 → 移除）。

### 4.4 错误处理
无新增错误路径。`review`/`replay` 的失败仍由 `AppRouter.setError` → `.alert("出错了")` 既有路径处理（不变）。

---

## 5. 冻结 spec 修订点

| 文件 | 位置 | 改动 |
|------|------|------|
| `kline_trainer_modules_v1.4.md` | §U6（L2136-2144 一带） | 标题「U6 历史动作表 `HistoryActionSheet.swift`」→「U6 历史动作弹窗 `HistoryActionDialog.swift`」；init 块类型名 `HistoryActionSheet`→`HistoryActionDialog`（签名不变）；正文「动作表 / 底部」措辞改「屏幕居中弹窗」。L108 目录注释 `U6 History` 若有 Sheet 字样一并核对。 |
| `kline_trainer_modules_v1.4.md` | 验收清单 L2210 | `- [ ] U6 HistoryActionSheet` → `HistoryActionDialog`。 |
| `kline_trainer_plan_v1.5.md` | §6.1.3 | 「点击一条历史记录 → 弹出**提示框**」措辞核对（原文已是「提示框」，与居中弹窗契合）；清理任何残留「底部 / sheet / 动作表」描述使其与居中范式一致。 |
| `kline_trainer_plan_v1.5.md` | Wave 1 UI 壳清单 L2210 | `U6 HistoryActionSheet` → `HistoryActionDialog`（同 #1 在此处更新 U5 的先例）。 |

> 凡 plan 中 `HistoryActionSheet` 字样全量 grep 替换为 `HistoryActionDialog`，确保改名后零残留旧名（#1 Task5 教训：plan 残留旧组件名 = 对抗性 review Changes-Requested）。

---

## 6. 测试策略（诚实交代）

本 RFC 是**纯呈现层改造**，几乎无新增可 host 测试的纯逻辑。诚实分层：

1. **host 回归网（机器执行，必须全绿）**：
   - `HistoryActionContent` 现有 host 测试 —— 零改动，仍绿（标题格式化未变）。
   - `AppRouter` host 测试（`AppRouterTests`）—— 零改动，仍绿（状态机未变；`selectRecord→.history`、`review/replay` 清 modal 的行为在此层有覆盖）。
   - 全量 `swift test` —— 改名后引用更新，净改动 = 0 新增/0 删除测试，全绿。
2. **新呈现行为（SwiftUI shell，D10 不写 host 单测）**：
   - **Mac Catalyst `build-for-testing` 编译闸** —— 改名引用 + overlay 接线编译通过（捕获 R2 改名遗漏）。
   - **iOS app build** —— 集成编译通过。
   - **模拟器人工验收**（iPhone 17 Pro + seed fixture）—— 居中显示、点遮罩关闭、设置/结算仍底部、三按钮路由正确（运行时观感，自动化测不到，见 §8 验收清单）。

> 不为「居中/遮罩」臆造 host 单测（SwiftUI 视图层在本仓 D10 一贯不 host 测）。状态机层的真实覆盖来自不变的 `AppRouterTests`；视图呈现层靠编译闸 + 人工验收。这是本仓 UI 壳一贯的诚实测试边界，非偷工。

---

## 7. 风险

| # | 风险 | 缓解 |
|---|------|------|
| **R1** | 分流 binding 写错 → 设置/结算被误吞，或 `.history` 闪一下空白底 sheet | binding `get` 对 `.history` 返 nil + overlay 用 `if case .history` 独立判定；Catalyst 编译 + 人工验收场景 7/8（设置/结算仍底部、history 无空 sheet）覆盖。 |
| **R2** | 改名 `HistoryActionSheet`→`HistoryActionDialog` 遗漏某处引用 → 编译失败 | 全量 grep（含 plan 文档）；Catalyst + app build 编译闸即捕获。 |
| **R3** | overlay 遮罩盖不住安全区/导航栏，露白边 | 遮罩 `.ignoresSafeArea()`。 |
| **R4** | overlay 与 `.alert("出错了")` 同时出现层级打架（如 review 失败弹 alert） | `review/replay` 先清 `activeModal=nil`（overlay 随即移除）再可能 setError；时序上 dialog 先消失 alert 后现，不叠。人工验收回归 §8 回归项覆盖。 |
| **R5** | `.transition(.opacity)` 动效在 overlay 条件插入/移除时不触发（需 `withAnimation` 包裹状态变更或 `.animation` 修饰） | plan 钉死动效落点（在置/清 `activeModal` 处包 `withAnimation`，或对 overlay 加 `.animation(_:value:)`）；动效缺失不阻断功能（R5 为润色非硬伤）。 |

---

## 8. 验收清单（草案，正式版随 plan 落地为独立文件）

### 8.1 机器执行
- host：`cd ios/Contracts && swift test` 全量 0 failures；净测试数变化 = 0（仅引用改名）。
- Catalyst：`xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` → `TEST BUILD SUCCEEDED`。
- iOS app：`xcodebuild build … -scheme KlineTrainer …` → `BUILD SUCCEEDED`。

### 8.2 模拟器人工验收（iPhone 17 Pro + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 首页点一条历史记录 | 屏幕**正中**弹出卡片（标题=股票名（代码）+ 复盘/再来一次/取消），背景半透明变暗，**非底部滑出** | ☐ |
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
