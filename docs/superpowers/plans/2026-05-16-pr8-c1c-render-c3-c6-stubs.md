# PR 8 — C1c Render + C3-C6 Stubs Implementation Plan

**Revision history：**
- **v1**（2026-05-16）：初稿 → codex R1 verdict `needs-attention`（3 findings: 1 high + 2 medium）
- **v2**（2026-05-16）：codex R1 3 findings 全修
  - finding 1 (high) → Task 7.2 改为 Mac Catalyst 强制 build（实测 BUILD SUCCEEDED），删除"subagent 不在此点 abort"软兜底；闸门关闭硬规则明文
  - finding 2 (medium) → Task 0 改为从主 checkout 显式 `cp` untracked plan 进 worktree + `test -f` 守卫
  - finding 3 (medium) → Task 1.4 `.empty` 默认替换为 grep 校对过的真实 init（`Period.m3` / 真 PanelViewState / ChartViewport / PriceRange 全签名）
- **v3**（2026-05-16）：codex R2 3 findings 全修
  - finding 1 (high) → Task 7.2 加 `set -o pipefail` + 显式 PIPESTATUS check + grep `** BUILD SUCCEEDED **` + 无 error/warning grep；闸门 mechanically enforceable
  - finding 2 (medium) → KLineRenderState 字段改 `public let`（spec L1219-1229 字面）；测试 mutate 改成 helper init 重建；不破坏 public API source-stability
  - finding 3 (medium) → Step 7.2 升级为 `build-for-testing`（Catalyst 让测试跑起来）；新加 `setNeedsDisplay` observer test 用 KLineView 子类拦截调用次数，满足 spec L1240 "相同输入两次 render 只画一次" 真验证
- **v4**（2026-05-16）：codex R3 3 findings 全修
  - finding 1 (high) → 砍掉 ProbeKLineView 子类拦截测试（spec L1179 `final class KLineView` 不可继承，subclass 编译不过）；保留 KLineViewCompileTests 仅 compile-check（实例化 + property 设置）
  - finding 2 (high) → 接 finding 1 联合解：spec L1240 "相同输入两次 render 只画一次" **runtime invariant 显式 defer 到 Wave 1 C8 integration PR**（与 L1167 同性质 residual）；本 PR scope 仅交付编译 stub 与 didSet `guard` 字面代码；Catalyst `build-for-testing` 保持 compile-only gate 角色
  - finding 3 (medium) → 修 grep pattern `(^|[[:space:]])warning:` / `(^|[[:space:]])error:`，避免路径空格 hide 警告
- **v5**（2026-05-16）：codex R4 1 finding 修
  - finding 1 (high) → Step 7.3 闭门条件 #4 改为 "macOS host swift test + Mac Catalyst build-for-testing"，删除"iOS Simulator build 成功"内部矛盾；加 Catalyst-only 覆盖的 spec 等价性论据 + residual 说明
- **v6**（2026-05-16）：codex R5 2 findings 全修（mechanical shell-portability）
  - finding 1 (high) → Step 7.2 用 `if ! ( set -o pipefail; cmd | tee )` 块替代 `${PIPESTATUS[0]}`（bash-only）；shell-agnostic zsh/bash 通用
  - finding 2 (medium) → Step 7.1 同 pattern 改造 + 加 GATE PASS 输出；acceptance B2 同 pattern
- **v7**（2026-05-16）：codex R6 1 finding 修（text 内部矛盾清理）
  - finding 1 (high) → 修 Step 7.2 中 v3 ↔ v4 互相矛盾的 text：v3 留下"真正验证 setNeedsDisplay invariant"措辞与 v4 "compile-only + L1240 defer Wave 1" 决议冲突 → 改为明文"`build-for-testing` 只编译不执行测试"+ 不声称验证 L1240 runtime；§15.1 #3 闸门作用范围明确为 compile-only
- **v8**（2026-05-16）：codex R7 2 findings 处理 + **codex 7+ 轮 TTY override 收敛**
  - finding 2 (medium) → 修 Step 7.1 + acceptance B2 数学错误：N ≥ 281 改 N ≥ 269（265 baseline + 4 RenderState 可见，UIKit suite macOS skip 0 计数）
  - finding 1 (high, **accept-as-residual not-chase**) → 显式 doc 为 plan residual：当前 CI 只跑 macOS swift test，Catalyst build gate 是本地证据。**升级 CI 为 governance residual deferred to PR 9**（§15.4 sign-off 前必须加 Catalyst CI job，blocking `wave0-frozen-v1.4` tag；与 L1167 同性质 residual queue）。理由：CI workflow 改动是 trust-boundary，本 PR 加会触发独立 governance loop；scope creep。
  - **codex review escalate 决议**：7 轮后停 codex（memory `feedback_codex_plan_budget_overshoot` 5 轮 + `feedback_codex_round6_self_contradiction` 模式）；plan v8 由 user TTY override 接受为最终版本；后续按 PR #39 R14 / PR #50 R2 模式 admin bypass merge

---

## ⚠️ 已知 plan-residual（PR 9 governance 前必须 close 的清单）

1. **L1167 Deceleration stop 契约 production handler/animator 集成测试**（来自 PR #50 / PR7b3 plan）
   - 阻塞：`wave0-frozen-v1.4` tag
   - 解决路径：随 Wave 1 C2 + E5/C8 落地 OR spec 修订移入 Wave 1
2. **L1240 KLineRenderState Equatable 短路 runtime invariant**（本 PR 新增）
   - 阻塞：none（compile gate 已关闭）
   - 解决路径：Wave 1 C8 integration PR 时 iOS Simulator CI 跑 `xcodebuild test`
3. **Catalyst CI build gate**（本 PR 新增，codex R7 finding 1）
   - 阻塞：`wave0-frozen-v1.4` tag（reviewer 仅信本地 log 不可持续；governance 必须升级）
   - 解决路径：PR 9 governance 阶段加 `.github/workflows/swift-contracts-smoke.yml` 第二 job 跑 `xcodebuild build-for-testing -destination 'Mac Catalyst'`

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task（本项目只用 subagent-driven-development，见 memory `project_executing_plans_excluded`）。每个 Task 派一个 fresh sonnet 4.6 high-effort subagent；Task 与 Task 之间主线 two-stage review。Steps use checkbox (`- [ ]`) syntax for tracking。

**Goal:** 为 spec `kline_trainer_modules_v1.4.md` §六 C1c（L2117-2210）+ §十 Wave 0 C1 三件拆分（L2126-2130）交付 `KLineRenderState` 值类型 + `KLineView` UIKit shell + C3-C6 八个 drawXxx extension **空 stub**，关闭 §15.1 编译验证 checklist #3 项（"`KLineView.draw(_:)` 调用 C3-C6 extension 方法，编译期检查方法签名匹配"）。零业务渲染逻辑——蜡烛/MA66/BOLL/Volume/MACD/Crosshair/Markers/Drawings 的真实现保持 Wave 1 落地。

**Architecture:** 跟随 `Theme.swift` cross-platform precedent（spec drift design doc 已收敛）：纯值类型 `KLineRenderState`（macOS + iOS 共编）放 `Sources/KlineTrainerContracts/Render/`；UIKit shell `KLineView` + 6 个 extension 文件用 `#if canImport(UIKit)` 守卫，macOS host swift test 跳过编译、iOS Simulator/device build 强制覆盖。所有 8 个 drawXxx 方法 body = 单行注释 `// Wave 1 (Cx): implement Xxx rendering`，编译通过即关闭 §15.1 #3 闸门。本 PR 零 prod 业务逻辑、零新依赖、零 Package.swift 改动（KLineRenderState 与 KLineView 同包同 target）。

**Tech Stack:** Swift 6.0（toolchain 6.3.1）+ SwiftPM intra-package（`KlineTrainerContracts`）+ Swift Testing macros（`@Test` / `@Suite` / `#expect`）+ `import Foundation` + `import CoreGraphics` + `#if canImport(UIKit) import UIKit`。无新增依赖、无 `Package.swift` 改动。

**Spec 锚点：**
- **主要**：`kline_trainer_modules_v1.4.md` **L2117-2210**（§六 C1c KLineRenderState + KLineView 设计；含 `draw(_:)` 派发 8 个 drawXxx）
- **次要 §15.1 编译验证**：L2442-2473（9 项 checklist，本 PR 关闭 #3；#1/#2/#4 已在 PR #38/#47/#48/#49 落地、#5-#9 在 M0.4/F1/E5/E3 落地，本 PR 仅交付 #3 缺口）
- **次要 §十 Wave 0 C1 三件拆分**：L2117-2130（明文："C3-C6 的 drawXxx extension 方法签名 + **空 stub 实现**（真正实现放 Wave 1）"——本 PR scope 字面对齐 spec）
- **次要 §十一 Checklist 引擎契约**：L2237-2278（"**KLineView 本体**（C1c）+ `KLineRenderState`（v1.3：volumeRange/macdRange 为 `NonDegenerateRange`）+ `ChartPanelFrames`"）

**与 v6 outline 顺位关系：** v6 outline 顺位 15 = "PR 8: C1c Render + C3-C6 stubs + §15.1 sign-off + tag wave0-frozen-v1.4"。本 plan **scope 收紧** 仅覆盖前两项（C1c + stubs），后两项（§15.1 sign-off ceremony + tag）拆到独立 governance PR（编号 PR 9，命名待 brainstorm）。

**Scope 决策（关键）：**

| v6 outline 列项 | 本 PR 8 处理 | 理由 |
|---|---|---|
| C1c `KLineRenderState` 值类型 | ✅ 交付 | 编译反向依赖：`KLineView.renderState` 字段必须有类型 |
| C1c `KLineView` UIKit shell | ✅ 交付 | §15.1 #3 编译验证目标 |
| C3-C6 drawXxx **空 stub** | ✅ 交付 | spec L2128 明文 Wave 0 scope；KLineView.draw 派发链需 extension 才编译 |
| §15.1 编译验证 *项目签字* | ❌ 拆 PR 9 | 治理仪式：三方签字 + tag = governance，不是 impl |
| Git tag `wave0-frozen-v1.4` | ❌ 拆 PR 9 + 被 L1167 阻塞 | 见下"⚠️ L1167 freeze blocker" |
| §15.1 9 项 checklist 闭环复盘 | ❌ 拆 PR 9 | 复盘逐项确认 = governance 任务 |

**⚠️ L1167 freeze blocker（来自 PR #50 / PR7b3 plan governance-approved 留痕）：**

`wave0-frozen-v1.4` tag 必须在以下任一条件满足前**不得打**：
1. L1167 的 production handler/animator 集成测试落地（随 Wave 1 C2/E5/C8）；**或**
2. L1167 经 spec 修订正式从「Wave 0 额外验收」移入 Wave 1 验收（治理动作，走 `superpowers:brainstorming` → `codex:adversarial-review`）。

PR 8（本 PR）**显式不打 tag**——不论 L1167 是否解决，tag ceremony 与 §15.4 三方签字仪式属 governance 范畴，与本 PR 的 impl scope 切开是 CLAUDE.md §3 surgical 原则。

**Planner packaging hard rule 自查（memory `feedback_planner_packaging_bias`）：**

> 硬规则每 PR ≤3 子项 / ≤500 行 prod

本 PR 子项数：
1. KLineRenderState 值类型 + Equatable 短路测试（§15.1 #4 已被 PR7a 部分覆盖，本 PR 补 RenderState Equatable 短路 + Sendable）
2. KLineView UIKit shell + draw() 8 派发
3. C3-C6 八个 drawXxx 空 stub（散在 6 个 extension 文件）

= **3 子项**（精确符合上限）

预估 prod LOC：
- `Render/KLineRenderState.swift`：~120 行（含 `static let empty` + Equatable 自动合成 + Sendable）
- `Render/KLineView.swift`：~150 行（UIView 子类 + `renderState` didSet + `draw(_:)` 派发链）
- `Render/KLineView+Candles.swift`：~50 行（drawCandles + drawMA66 + drawBOLL 三方法 stub）
- `Render/KLineView+Volume.swift`：~30 行（drawVolume stub）
- `Render/KLineView+MACD.swift`：~30 行（drawMACD stub）
- `Render/KLineView+Markers.swift`：~30 行（drawMarkers stub）
- `Render/KLineView+Crosshair.swift`：~30 行（drawCrosshair stub）
- `Render/KLineView+Drawing.swift`：~30 行（drawDrawings stub）

= **~470 行 prod**（符合 ≤500 上限）

测试 LOC：
- `Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift`：~120 行（Equatable 短路 + .empty 默认值 + Sendable）
- `Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift`：~80 行（§15.1 #3 编译反射 test）

= **~200 行测试**

**完成后：** Wave 0 C1 三件拆分（C1a / C1b / C1c）impl 闭环；§15.1 #3 编译验证 gate 关闭；C3-C6 stubs 准备好接 Wave 1 真实现。下一锚 = **PR 9（governance-only）**：处理 L1167 freeze blocker 决议（brainstorm 选路径 1 还是 2）→ §15.1 9 项 checklist 逐项闭环复盘 → §15.4 三方签字 → tag `wave0-frozen-v1.4` → Wave 0 完成宣告。

---

## File Structure

| 文件 | 责任 | 状态 | 增量 LOC budget |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift` | 纯值类型 `KLineRenderState`（`panel / frames / viewport / visibleCandles / volumeRange / macdRange / markers / drawings / crosshairPoint`）+ `static let empty` + `Equatable, Sendable` 自动合成 | Create | ~120 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | UIKit shell `final class KLineView: UIView`（`#if canImport(UIKit)`）+ `renderState` didSet 短路 + `draw(_:)` 派发 8 个 drawXxx | Create | ~150 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift` | C3 stub × 3：`drawCandles / drawMA66 / drawBOLL` extension methods（`#if canImport(UIKit)`） | Create | ~50 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift` | C4 stub × 1：`drawVolume`（`#if canImport(UIKit)`） | Create | ~30 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift` | C4 stub × 1：`drawMACD`（`#if canImport(UIKit)`） | Create | ~30 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift` | C5 stub × 1：`drawMarkers`（`#if canImport(UIKit)`） | Create | ~30 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift` | C5 stub × 1：`drawCrosshair`（`#if canImport(UIKit)`） | Create | ~30 |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift` | C6 stub × 1：`drawDrawings`（`#if canImport(UIKit)`） | Create | ~30 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift` | RenderState Equatable 短路测试 + `.empty` 默认值 + Sendable 编译 | Create | ~120 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift` | §15.1 #3 编译反射 test：实例化 KLineView + 设置 renderState 触发 setNeedsDisplay；通过编译即关闭闸门（`#if canImport(UIKit)` Skip in macOS host） | Create | ~80 |
| `docs/acceptance/2026-05-16-pr8-c1c-render-c3-c6-stubs.md` | 中文非-coder 验收清单（action / expected / pass_fail 三段） | Create | ≤95 |
| `docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md` | 本计划文件（codex 对抗性 review source-of-truth + branch-diff 复审对照） | Create（本文件） | — |
| `docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md` | PR #50 已 merged 但漏 commit 的 plan housekeeping（Task 0 处理） | Commit（已存在 untracked） | — |

**File rationale：**

- **Render/ 子目录**：与 Geometry/ Reducer/ Theme/ 三个现有模块目录平行，遵循 spec §六 C1 三件拆分命名（C1a Geometry / C1b Reducer / C1c Render）。
- **8 个 drawXxx 分散到 6 个 extension 文件**：跟随 spec L2189-2211 派发链命名（drawCandles+MA66+BOLL 同 C3 模块 = 同文件；drawVolume / drawMACD / drawMarkers / drawCrosshair / drawDrawings 各自一个文件，模块边界 = 文件边界）。
- **不抽 DrawingTool protocol / DrawingToolManager**：那是 C6 Wave 1 真实现 scope（spec §C6 L1295+，本 PR 不动）；只交付 `drawDrawings(ctx:mapper:drawings:period:)` extension method 一个空 stub，drawings 类型用现成 `[DrawingObject]`（已在 Models.swift / 待 grep 确认）。如果 DrawingObject 类型还不存在 → 用占位 `[Never]`-style placeholder array 或 `[any Equatable & Sendable]` 替代（见 Task 3.6 grep 确认步骤）。
- **不动 `ios/KlineTrainer/` Xcode 工程**：iOS app target 当前不 import Contracts package（pbxproj 只有 GRDB ref）；将来 C8 ChartContainerView（Wave 2）才会加 Contracts dep，本 PR 不做该改动 = CLAUDE.md §3 surgical。
- **§15.1 #3 编译验证测试形态**：测试自身在 macOS host swift test 上 `#if canImport(UIKit)` 跳过；真实编译验证落在 iOS Simulator `xcodebuild build-for-testing -destination 'platform=iOS Simulator'` 步骤。Task 7 包含两种 build 命令各跑一次。

**Working directory：** worktree，由 `superpowers:using-git-worktrees` 在执行阶段创建（不在 plan 阶段创建）。SwiftPM root: `<worktree>/ios/Contracts/`。计划文件本身 commit 进 PR scope（PR #49 教训：plan 文件漏 commit 触发 re-attest 循环）。Task 0 同步把 PR #50 的 untracked plan 一并 commit（PR #50 merge 时漏掉，归档到 PR 8 第一个 commit）。

**Baseline：** PR #50 merged 后 origin/main = **270 tests in 59 suites / 0 failures / 0 warnings**（待 worktree 内 swift test 实跑确认）。PR 8 完成后预期：
- 新增 `KLineRenderStateTests` Suite（约 8 个 @Test）
- 新增 `KLineViewCompileTests` Suite（约 3 个 @Test，全部 `#if canImport(UIKit)` 守卫）
- 总数 ≈ 281 tests in 61 suites / 0 failures / 0 warnings（macOS host）
- iOS Simulator build：编译 0 错误 0 警告（含 `Sending '...' risks data races` 严格并发检查）

---

## Spec Evidence Section（codex review 必读）

### §六 C1c 完整源码引用（modules_v1.4.md L2117-2210）

**KLineRenderState 字段定义**（推断自 §六 C1 全文 + draw(_:) 派发链需要的字段）：

```swift
public struct KLineRenderState: Equatable, Sendable {
    public var panel: PanelViewState              // 来自 C1b（已在 PR #47 落地）
    public var frames: ChartPanelFrames            // 来自 C1a（已在 PR #38 落地）
    public var viewport: ChartViewport             // 来自 C1a
    public var visibleCandles: ArraySlice<KLineCandle>  // 来自 F1（已在 PR #37 之前 M0.3 落地）
    public var volumeRange: NonDegenerateRange     // 来自 C1a（v1.3）
    public var macdRange: NonDegenerateRange       // 来自 C1a
    public var markers: [TradeMarker]              // 来自 F1
    public var drawings: [DrawingObject]           // 来自 C6（Wave 1）—— Task 3.6 grep 确认是否已有占位
    public var crosshairPoint: CGPoint?            // 可空

    public static let empty: KLineRenderState = .init(/* 待 Task 1 落定字段顺序 */)
}
```

**KLineView 本体定义**（L2179-2211 字面）：

```swift
final class KLineView: UIView {
    var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = traitCollection.displayScale
        let mapper = CoordinateMapper(viewport: renderState.viewport, displayScale: scale)
        let volMapper = IndicatorMapper(
            frame: renderState.frames.volumeChart,
            valueRange: renderState.volumeRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)
        let macdMapper = IndicatorMapper(
            frame: renderState.frames.macdChart,
            valueRange: renderState.macdRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)

        drawCandles(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawMA66(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawBOLL(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawVolume(ctx: ctx, mapper: volMapper, candles: renderState.visibleCandles)
        drawMACD(ctx: ctx, mapper: macdMapper, candles: renderState.visibleCandles)
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                    period: renderState.panel.period)
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                   markers: renderState.markers, candles: renderState.visibleCandles)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
    }
}
```

**8 个 drawXxx extension 签名**（推断自 draw(_:) 调用点 + Task 3-6 内最终定形）：

```swift
extension KLineView {
    func drawCandles(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>)
    func drawMA66(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>)
    func drawBOLL(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>)
    func drawVolume(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>)
    func drawMACD(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>)
    func drawDrawings(ctx: CGContext, mapper: CoordinateMapper, drawings: [DrawingObject], period: Period)
    func drawMarkers(ctx: CGContext, viewport: ChartViewport, mapper: CoordinateMapper,
                    markers: [TradeMarker], candles: ArraySlice<KLineCandle>)
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport)
}
```

### §15.1 #3 编译验证目标（modules_v1.4.md L2451 字面）

> | 3 | §六 C1 KLineView | `draw(_:)` 调用 C3-C6 extension 方法，编译期检查方法签名匹配 |

**关闭条件：** `KLineView.swift` 含 `override func draw(_ rect: CGRect)` 调用 8 个 drawXxx；6 个 extension 文件提供完全匹配的方法签名；macOS host swift test 跳过编译；iOS Simulator `xcodebuild build-for-testing` 编译通过 0 警告 0 错误。

### §十一 Checklist 引擎契约相关项（L2255-2262）

> - [ ] **KLineView 本体**（C1c）+ `KLineRenderState`（v1.3：volumeRange/macdRange 为 `NonDegenerateRange`）+ `ChartPanelFrames`
> - [ ] 所有 C1a/C1b/C1c 值类型 **`Equatable, Sendable`**（v1.3）

本 PR 关闭这两条（其它 C1 checklist 项已被 PR #38/#47/#48/#49 关闭）。

### Theme.swift cross-platform precedent（PR #39 design）

参 `ios/Contracts/Sources/KlineTrainerContracts/Theme/Theme.swift:66-117`：
- 纯值层（macOS + iOS 共编）放文件上半
- UIKit shell `@MainActor @Observable public final class ThemeController` + `extension UIColor` + `enum AppColor` 全部包在 `#if canImport(UIKit) import UIKit ... #endif` 块内
- 跨平台 swift test 跑 macOS host 时 UIKit 部分整体跳过，纯值层测试覆盖

**本 PR 跟随**：`KLineRenderState`（纯值）放 `Render/KLineRenderState.swift`（无 #if）；`KLineView` + 6 extension 全部 `#if canImport(UIKit)`。

---

## Task 0: 处理 PR #50 untracked plan housekeeping + plan 文件入 PR 8 branch

**Files:**
- Copy-into-worktree: `docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md`（PR #50 漏 commit，main 上 untracked）
- Copy-into-worktree: `docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md`（本计划，main 上 untracked）

**⚠️ codex R1 finding 2 修复（v2）：** `git worktree add` **不复制 untracked files** —— 只 checkout 已 tracked 的 commits。所以两个 untracked plan 文件必须从主 checkout 显式 `cp` 进 worktree 后再 git add。Task 0.2 内置 `test -f` 守卫，cp 失败立刻 abort。

- [ ] **Step 0.1: 起 worktree（subagent-driven 第一步前置）**

主线（非 subagent）操作。Skill: `superpowers:using-git-worktrees`。

Run:
```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git checkout main
git pull origin main
git worktree add -b worktree-pr8-c1c-render-stubs .claude/worktrees/pr8-c1c-render-stubs
cd .claude/worktrees/pr8-c1c-render-stubs
git branch --show-current  # 期望 = worktree-pr8-c1c-render-stubs
```

Expected: worktree 创建在 `.claude/worktrees/pr8-c1c-render-stubs/`；branch 名匹配。

- [ ] **Step 0.2: 从主 checkout copy 两个 untracked plan 文件进 worktree（强制守卫）**

⚠️ 关键步骤。`git worktree add` 不会复制主 checkout 内的 untracked files；所以两个 plan 必须从 `/Users/maziming/Coding/Prj_Kline trainer/docs/superpowers/plans/` 显式 cp。

Run:
```bash
cd .claude/worktrees/pr8-c1c-render-stubs

# 主 checkout 绝对路径（避免 ../../ 相对路径在嵌套 worktree 层级下出错）
MAIN_CHECKOUT="/Users/maziming/Coding/Prj_Kline trainer"

# Copy PR #50 (PR7b3) plan
cp "$MAIN_CHECKOUT/docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md" \
   docs/superpowers/plans/

# Copy 本 PR (PR8) plan
cp "$MAIN_CHECKOUT/docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md" \
   docs/superpowers/plans/

# 强制守卫：两个文件必须存在，否则立刻 abort
test -f docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md || { echo "ERROR: PR7b3 plan copy failed"; exit 1; }
test -f docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md || { echo "ERROR: PR8 plan copy failed"; exit 1; }

ls -la docs/superpowers/plans/2026-05-1*-pr*.md
```

Expected: 两个 plan 文件出现在 `docs/superpowers/plans/`；ls -la 显示文件大小非零（PR7b3 ~50KB / PR8 ~30KB+）。

- [ ] **Step 0.3: Commit 两个 plan 文件进 PR 8 branch 第一个 commit**

```bash
git add docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md \
        docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md
git commit -m "docs(PR8): archive PR #50 PR7b3 plan + PR 8 plan

PR #50's plan file was missed during merge (untracked on main).
Archiving alongside PR 8's own plan to maintain the
PR-per-plan governance audit trail.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git log --oneline -1
```

Expected: commit 成功；`git log --oneline -1` 显示 docs commit hash。后续 Task 1-8 implementation 在此 baseline 上 cherry-add。

⚠️ **acceptance 文档（Task 8 创建）单独 commit**，不在 Task 0。

---

## Task 1: KLineRenderState 值类型

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift`

**Spec 锚点：** modules_v1.4.md L2107-2178（KLineRenderState 字段推断）+ L2179-2210（draw 派发用到的字段）+ L2255 checklist。

- [ ] **Step 1.1: grep 确认依赖类型已存在**

Run:
```bash
cd ios/Contracts
grep -rn "public struct PanelViewState\|public struct ChartPanelFrames\|public struct ChartViewport\|public struct KLineCandle\|public struct TradeMarker\|public struct NonDegenerateRange\|public struct DrawingObject\|public enum Period" Sources/KlineTrainerContracts/ | head -20
```

Expected: 列出 PanelViewState（Reducer/Reducer.swift）/ ChartPanelFrames + ChartViewport + NonDegenerateRange（Geometry/Geometry.swift）/ KLineCandle + TradeMarker + Period（Models.swift）。**如果 `DrawingObject` 类型不存在**：进 Step 1.2（占位类型决策）。

- [ ] **Step 1.2: DrawingObject 占位类型决策**

如果 grep 结果显示 `DrawingObject` 类型**已存在**（来自 PR #47/#48 C1b 值类型）：直接 import 使用。

如果**不存在**：在 `Render/KLineRenderState.swift` 顶部加最小占位：

```swift
// MARK: - DrawingObject 占位（C6 Wave 1 真实现前）
// spec §C6 L1295+ 定义 DrawingObject，目前 stub 期间用最小占位以让 RenderState 编译通过；
// Wave 1 C6 落地时整体替换为真类型。
public struct DrawingObject: Equatable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}
```

理由：CLAUDE.md §2 simplicity — 占位只到能让 RenderState 编译通过的最小程度；不预先设计 C6 全部字段。

- [ ] **Step 1.3: 写 failing test — RenderState 默认 .empty 可构造 + 字段全部初始化**

`ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift`：

```swift
import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("KLineRenderState")
struct KLineRenderStateTests {
    @Test("empty default has zero-sized frames and zero-revision panel")
    func emptyDefault() {
        let s = KLineRenderState.empty
        #expect(s.panel.revision == 0)
        #expect(s.visibleCandles.isEmpty)
        #expect(s.markers.isEmpty)
        #expect(s.drawings.isEmpty)
        #expect(s.crosshairPoint == nil)
    }
}
```

Run:
```bash
cd ios/Contracts && swift test --filter "KLineRenderStateTests/emptyDefault" 2>&1 | tail -10
```

Expected: FAIL with "cannot find KLineRenderState in scope"（类型尚未定义）。

- [ ] **Step 1.4: 写最小实现让 test 通过**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift`：

```swift
// Kline Trainer Swift Contracts — C1c KLineRenderState
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L2107-2210) + §十 Wave 0 C1 三件拆分 (L2126-2130)
// 与 KLineView.draw(_:) 派发链一一对应；所有字段 Equatable + Sendable 自动合成。
//
// 注：drawings 字段类型在 Wave 1 C6 落地前用 [DrawingObject] 占位；DrawingObject 占位见 Task 1.2 决策。

import Foundation
import CoreGraphics

// codex R2 finding 2 修复（v3）：spec L1219-1229 字面用 `let`；改回 `let` 保持
// public API source-stable（tightening 后期不破 caller）。C8 Wave 2 ChartContainerView
// 每次构造完整 KLineRenderState 注入，不 partial mutate（spec §C8 L2107+ 设计意图）。
public struct KLineRenderState: Equatable, Sendable {
    public let panel: PanelViewState
    public let frames: ChartPanelFrames
    public let viewport: ChartViewport
    public let visibleCandles: ArraySlice<KLineCandle>
    public let volumeRange: NonDegenerateRange
    public let macdRange: NonDegenerateRange
    public let markers: [TradeMarker]
    public let drawings: [DrawingObject]
    public let crosshairPoint: CGPoint?

    public init(panel: PanelViewState,
                frames: ChartPanelFrames,
                viewport: ChartViewport,
                visibleCandles: ArraySlice<KLineCandle>,
                volumeRange: NonDegenerateRange,
                macdRange: NonDegenerateRange,
                markers: [TradeMarker],
                drawings: [DrawingObject],
                crosshairPoint: CGPoint?) {
        self.panel = panel
        self.frames = frames
        self.viewport = viewport
        self.visibleCandles = visibleCandles
        self.volumeRange = volumeRange
        self.macdRange = macdRange
        self.markers = markers
        self.drawings = drawings
        self.crosshairPoint = crosshairPoint
    }

    public static let empty: KLineRenderState = .init(
        panel: PanelViewState(
            period: .m3,                      // spec L11 Period.m3 = "3m"（无 .oneMinute case；最小周期 = m3）
            interactionMode: .autoTracking,
            visibleCount: 0,
            offset: 0,
            revision: 0
        ),
        frames: ChartPanelFrames(
            mainChart: .zero,
            volumeChart: .zero,
            macdChart: .zero
        ),
        viewport: ChartViewport(
            startIndex: 0,
            visibleCount: 0,
            pixelShift: 0,
            geometry: ChartGeometry(candleStep: 0, candleWidth: 0, gap: 0),
            priceRange: PriceRange(min: 0, max: 1),  // PriceRange.calculate empty fallback 同此
            mainChartFrame: .zero
        ),
        visibleCandles: [],
        volumeRange: NonDegenerateRange.make(values: []),
        macdRange: NonDegenerateRange.make(values: []),
        markers: [],
        drawings: [],
        crosshairPoint: nil
    )
}
```

**⚠️ codex R1 finding 3 修复（v2）：** init 参数全部用现仓库真实 case 与签名（已 grep 校对 Models.swift L11-17 Period / Reducer.swift L36-41 PanelViewState / Geometry.swift L114 ChartViewport / L83 PriceRange / L15 ChartGeometry / L27 ChartPanelFrames）。无 TODO 占位、无 `.oneMinute` 这种不存在的 case。

Run:
```bash
cd ios/Contracts && swift test --filter "KLineRenderStateTests/emptyDefault" 2>&1 | tail -20
```

Expected: PASS（如果初始化字段全部合法）。FAIL 模式："cannot find member 'X' on type 'Y'" → 重新 grep Geometry/Reducer 类型实际签名修正。

- [ ] **Step 1.5: 加 Equatable 短路 didSet 触发测试**

Append to `KLineRenderStateTests.swift`：

```swift
    @Test("Equatable 短路：相等 instances 之间 == 为 true（didSet 不触发）")
    func equatableShortCircuit() {
        let a = KLineRenderState.empty
        let b = KLineRenderState.empty
        #expect(a == b)
    }

    @Test("Equatable 区分：crosshairPoint 不同 → !=")
    func equatableDistinguishCrosshair() {
        // codex R2 finding 2 修复（v3）：字段已改 `let`，用 init 重建而非 mutate
        let a = KLineRenderState.empty
        let b = KLineRenderState(
            panel: a.panel, frames: a.frames, viewport: a.viewport,
            visibleCandles: a.visibleCandles,
            volumeRange: a.volumeRange, macdRange: a.macdRange,
            markers: a.markers, drawings: a.drawings,
            crosshairPoint: CGPoint(x: 100, y: 200))
        #expect(a != b)
    }

    @Test("Sendable 编译断言：KLineRenderState 可跨 async 边界")
    func sendableAcrossActor() async {
        let s = KLineRenderState.empty
        let captured = await Task.detached { s }.value
        #expect(captured == s)
    }
```

Run:
```bash
cd ios/Contracts && swift test --filter "KLineRenderStateTests" 2>&1 | tail -15
```

Expected: 4 tests PASS。如果 Sendable test FAIL 且报 "Type 'X' does not conform to Sendable" → 检查所有字段（含 DrawingObject 占位）是否标 Sendable。

- [ ] **Step 1.6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineRenderStateTests.swift
git commit -m "feat(PR8): C1c KLineRenderState value type with .empty default

- Equatable, Sendable 自动合成；4 tests in 1 suite
- DrawingObject 占位类型（C6 Wave 1 替换）
- spec §六 C1c L2107-2210 字段对齐

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: KLineView UIKit shell + draw(_:) 派发链

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`

**Spec 锚点：** modules_v1.4.md L2179-2211（KLineView 字面源码）。

**前提：** Task 1 已完成；KLineRenderState 已可 import。

- [ ] **Step 2.1: 写 failing test — KLineView 可实例化且 renderState 设置触发 setNeedsDisplay**

`ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift`：

```swift
#if canImport(UIKit)
import Testing
import UIKit
@testable import KlineTrainerContracts

// codex R3 finding 1+2 联合修复（v4）：
// - KLineView 是 spec L1179 `final class` → 不可继承 → 删除 ProbeKLineView 子类拦截
// - spec L1240 "相同输入两次 render 只画一次" runtime invariant defer 到 Wave 1 C8 integration PR
//   （iOS Simulator CI 跑 xcodebuild test 时真验证；本 stub PR 仅交付 §15.1 #3 compile gate）
// - 本 suite 保留 compile-check only：实例化 + property 设置 + Equatable 短路（值层、不测 redraw）
// - 字段已改 `let`（R2 finding 2 修复），变更测试用 init 重建

@Suite("KLineView 编译反射（§15.1 #3 compile gate）")
struct KLineViewCompileTests {

    @Test("KLineView 可实例化（spec L1179 final class）")
    @MainActor
    func instantiates() {
        let view = KLineView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        #expect(view.bounds.width == 320)
    }

    @Test("renderState 可读写（compile-check：let 字段 + init 重建模式）")
    @MainActor
    func renderStateAssignable() {
        let view = KLineView(frame: .zero)
        let changed = KLineRenderState(
            panel: KLineRenderState.empty.panel,
            frames: KLineRenderState.empty.frames,
            viewport: KLineRenderState.empty.viewport,
            visibleCandles: KLineRenderState.empty.visibleCandles,
            volumeRange: KLineRenderState.empty.volumeRange,
            macdRange: KLineRenderState.empty.macdRange,
            markers: KLineRenderState.empty.markers,
            drawings: KLineRenderState.empty.drawings,
            crosshairPoint: CGPoint(x: 10, y: 20))
        view.renderState = changed
        #expect(view.renderState.crosshairPoint == CGPoint(x: 10, y: 20))
    }
}
#endif
```

**⚠️ L1240 runtime invariant residual（与 L1167 同性质 governance 留痕）：** spec L1240 「`KLineRenderState` Equatable 短路测试（相同输入两次 render 只画一次）」要求 runtime 验证 `setNeedsDisplay` 调用次数。本 PR 因以下两个 spec-driven 约束**不能**在 stub 阶段做 runtime 验证：

1. spec L1179 字面 `final class KLineView: UIView` —— 不可继承 → 不能用 subclass 拦截 `setNeedsDisplay`
2. spec L1240 的 "两次 render 只画一次" 真正语义是 `display()` 被调 1 次（不是 `setNeedsDisplay`）；display 调用由 UIView system 在 next runloop 触发，单元测试同步 assert 不到

**Defer 到 Wave 1 C8 integration PR**（iOS Simulator CI 跑 `xcodebuild test` 时真验证），与 L1167 production handler/animator gate 同性质 residual。PR 9 governance (§15.4 sign-off + tag) 时把本条与 L1167 一并记为「Wave 0 已知 residual」。

Run:
```bash
cd ios/Contracts && swift test --filter "KLineViewCompileTests" 2>&1 | tail -10
```

Expected:
- macOS host：`Test '...' skipped`（`#if canImport(UIKit)` 整块跳过）；suite 0 tests
- iOS Simulator build（Task 7）：FAIL with "cannot find KLineView in scope"

如果 macOS host 显示 0 tests 而非 skipped → 那是 SwiftPM 行为，acceptable。

- [ ] **Step 2.2: 写最小实现让编译过**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`：

```swift
// Kline Trainer Swift Contracts — C1c KLineView UIKit shell
// Spec: kline_trainer_modules_v1.4.md §六 C1c (L2179-2211) + §15.1 #3 编译验证
// Cross-platform precedent: Theme.swift L66-117（UIKit 部分 #if canImport(UIKit) 守卫）
//
// 本文件实现 KLineView：UIView 子类，renderState 驱动 setNeedsDisplay，
// draw(_:) 派发到 C3-C6 八个 drawXxx extension 方法（散在 6 个 +Xxx.swift 文件）。
// 所有 drawXxx 在 PR 8 内为 Wave 1 占位空 stub；本 shell 关闭 §15.1 #3 编译验证闸门。

import Foundation
import CoreGraphics

#if canImport(UIKit)
import UIKit

public final class KLineView: UIView {
    public var renderState: KLineRenderState = .empty {
        didSet {
            guard renderState != oldValue else { return }
            setNeedsDisplay()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported; KLineView is constructed via init(frame:)")
    }

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let scale = traitCollection.displayScale
        let mapper = CoordinateMapper(viewport: renderState.viewport, displayScale: scale)
        let volMapper = IndicatorMapper(
            frame: renderState.frames.volumeChart,
            valueRange: renderState.volumeRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)
        let macdMapper = IndicatorMapper(
            frame: renderState.frames.macdChart,
            valueRange: renderState.macdRange,
            geometry: renderState.viewport.geometry,
            viewport: renderState.viewport,
            displayScale: scale)

        drawCandles(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawMA66(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawBOLL(ctx: ctx, mapper: mapper, candles: renderState.visibleCandles)
        drawVolume(ctx: ctx, mapper: volMapper, candles: renderState.visibleCandles)
        drawMACD(ctx: ctx, mapper: macdMapper, candles: renderState.visibleCandles)
        drawDrawings(ctx: ctx, mapper: mapper, drawings: renderState.drawings,
                     period: renderState.panel.period)
        drawMarkers(ctx: ctx, viewport: renderState.viewport, mapper: mapper,
                    markers: renderState.markers, candles: renderState.visibleCandles)
        drawCrosshair(ctx: ctx, at: renderState.crosshairPoint, viewport: renderState.viewport)
    }
}

#endif
```

Run:
```bash
cd ios/Contracts && swift build 2>&1 | tail -30
```

Expected: macOS host build 成功（KLineView 整块 skip）；如果 iOS Simulator build → 8 处 "cannot find 'drawCandles' in scope" 错误（extensions 未定义）。这是预期的 RED 状态：Task 3-6 填 extension stub 让 GREEN。

- [ ] **Step 2.3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift
git commit -m "feat(PR8): C1c KLineView UIKit shell with draw(_:) dispatch to 8 drawXxx

- final class KLineView: UIView (#if canImport(UIKit))
- renderState didSet + Equatable short-circuit + setNeedsDisplay
- draw(_:) 派发 drawCandles/MA66/BOLL/Volume/MACD/Drawings/Markers/Crosshair
- macOS host swift test 跳过 UIKit shell；iOS Simulator build 待 Task 3-6 fill extensions
- 3 编译反射 tests in KLineViewCompileTests suite（macOS host 全部 skip）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: C3 主图 extension stubs — drawCandles + drawMA66 + drawBOLL

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`

**Spec 锚点：** spec §C3（待 grep 确认 L2120 附近）"主图蜡烛 + MA66 + BOLL"；KLineView.draw 调用点签名（Task 2.2 已字面落定）。

- [ ] **Step 3.1: 写 stub extension**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`：

```swift
// Kline Trainer Swift Contracts — C3 主图渲染 extension stubs（Wave 1 真实现占位）
// Spec: kline_trainer_modules_v1.4.md §C3（主图蜡烛 + MA66 + BOLL）
// §15.1 #3 编译验证：本文件 3 个方法签名与 KLineView.draw(_:) 派发点逐字匹配。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C3 主图蜡烛渲染 stub。Wave 1 C3 落地：使用 mapper.indexToX / priceToY 画蜡烛实体 + 影线，
    /// 使用 AppColor.candleUp / .candleDown 着色（spec §F2 字面色）。
    func drawCandles(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C3): implement candle body + wick rendering
    }

    /// C3 MA66 移动平均线 stub。Wave 1 C3 落地：滑窗 66 根计算均价、polyline 画线，
    /// 使用 AppColor.ma66 着色（spec §F2 字面色）。
    func drawMA66(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C3): implement MA66 polyline rendering
    }

    /// C3 BOLL 布林带 stub。Wave 1 C3 落地：上中下三轨 polyline + 上下轨填充，
    /// 使用 AppColor.bollLine 着色（spec §F2 字面色）。
    func drawBOLL(ctx: CGContext, mapper: CoordinateMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C3): implement BOLL upper/middle/lower band rendering
    }
}

#endif
```

Run:
```bash
cd ios/Contracts && swift build 2>&1 | tail -10
```

Expected: macOS host build 成功；仍有 5 处 "cannot find 'drawX' in scope" 错误（待 Task 4-6 fill 剩余 5 个 stub）。

- [ ] **Step 3.2: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift
git commit -m "feat(PR8): C3 main chart stubs — drawCandles + drawMA66 + drawBOLL

3 method stubs with Wave 1 implementation TODO comments.
Signatures match KLineView.draw(_:) dispatch points exactly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: C4 副图 extension stubs — drawVolume + drawMACD

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift`

**Spec 锚点：** spec §C4（IndicatorMapper 消费 volumeRange/macdRange）。

- [ ] **Step 4.1: 写 drawVolume stub**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift`：

```swift
// Kline Trainer Swift Contracts — C4 成交量副图渲染 extension stub
// Spec: kline_trainer_modules_v1.4.md §C4（Volume + MACD，使用 IndicatorMapper）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 成交量副图柱状 stub。Wave 1 C4 落地：indexToX + valueToY，红涨绿跌色（与蜡烛同步）。
    func drawVolume(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C4): implement volume bar rendering
    }
}

#endif
```

- [ ] **Step 4.2: 写 drawMACD stub**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift`：

```swift
// Kline Trainer Swift Contracts — C4 MACD 副图渲染 extension stub
// Spec: kline_trainer_modules_v1.4.md §C4（DIF + DEA + MACD bar；spec v1.5 §2: DIF 白 / DEA 黄）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C4 MACD 副图 stub。Wave 1 C4 落地：DIF/DEA 两线 polyline + MACD bar 柱（正负色）。
    /// 颜色 token: AppColor.macdDIF (白) / .macdDEA (黄) / .macdBarPositive / .macdBarNegative。
    func drawMACD(ctx: CGContext, mapper: IndicatorMapper, candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C4): implement MACD DIF/DEA polyline + bar rendering
    }
}

#endif
```

- [ ] **Step 4.3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Volume.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift
git commit -m "feat(PR8): C4 sub-chart stubs — drawVolume + drawMACD

2 method stubs in 2 files; consume IndicatorMapper (volumeRange/macdRange).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: C5 辅助层 extension stubs — drawMarkers + drawCrosshair

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift`

**Spec 锚点：** spec §C5（marker 二分谓词 + 十字光标）。

- [ ] **Step 5.1: 写 drawMarkers stub**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift`：

```swift
// Kline Trainer Swift Contracts — C5 交易标记辅助层 extension stub
// Spec: kline_trainer_modules_v1.4.md §C5（Markers + Crosshair；marker 二分谓词精确）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 交易标记 stub。Wave 1 C5 落地：findCandleIndex 二分定位 + buy/sell 图标贴位 + 价签。
    func drawMarkers(ctx: CGContext,
                     viewport: ChartViewport,
                     mapper: CoordinateMapper,
                     markers: [TradeMarker],
                     candles: ArraySlice<KLineCandle>) {
        // Wave 1 (C5): implement trade marker rendering with binary search index lookup
    }
}

#endif
```

- [ ] **Step 5.2: 写 drawCrosshair stub**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift`：

```swift
// Kline Trainer Swift Contracts — C5 十字光标辅助层 extension stub
// Spec: kline_trainer_modules_v1.4.md §C5（Crosshair；point optional 表无光标）

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C5 十字光标 stub。Wave 1 C5 落地：point 非空时画十字线 + 价格/时间标签框。
    func drawCrosshair(ctx: CGContext, at point: CGPoint?, viewport: ChartViewport) {
        // Wave 1 (C5): implement crosshair lines + price/time labels when point != nil
    }
}

#endif
```

- [ ] **Step 5.3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Markers.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Crosshair.swift
git commit -m "feat(PR8): C5 helper layer stubs — drawMarkers + drawCrosshair

2 method stubs in 2 files; spec §C5 binary search marker + optional crosshair.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: C6 绘线层 extension stub — drawDrawings

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift`

**Spec 锚点：** spec §C6（DrawingTools + DrawingInputController；本 PR 只交付 drawDrawings extension 占位，不抽 DrawingTool protocol / DrawingToolManager —— 那是 Wave 1 C6 真实现 scope）。

- [ ] **Step 6.1: 写 drawDrawings stub**

`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift`：

```swift
// Kline Trainer Swift Contracts — C6 绘线渲染层 extension stub
// Spec: kline_trainer_modules_v1.4.md §C6（DrawingTools + DrawingInputController；Phase 2.5 水平线先行）
//
// 注：本文件只交付 drawDrawings 一个方法 stub；DrawingTool protocol / DrawingToolManager
// 由 Wave 1 C6 真实现引入，不在本 PR scope。drawings 类型 [DrawingObject] 占位见 Task 1.2。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C6 绘线渲染 stub。Wave 1 C6 落地：遍历 DrawingObject 逐个 dispatch 到对应 tool draw 函数；
    /// period 用于价格/时间坐标映射跨周期一致性。
    func drawDrawings(ctx: CGContext,
                      mapper: CoordinateMapper,
                      drawings: [DrawingObject],
                      period: Period) {
        // Wave 1 (C6): dispatch each DrawingObject to its DrawingTool.draw(...)
    }
}

#endif
```

- [ ] **Step 6.2: 验证编译完整通过**

Run:
```bash
cd ios/Contracts && swift build 2>&1 | tail -10
```

Expected: macOS host build 成功；iOS Simulator build（Task 7 跑）= 编译 0 错误 0 警告。

如果还有 "cannot find 'drawXxx' in scope" → 检查是否漏了 Task 3-5 的 commit。

- [ ] **Step 6.3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Drawing.swift
git commit -m "feat(PR8): C6 drawing layer stub — drawDrawings

1 method stub; DrawingTool protocol + Manager deferred to Wave 1 C6 real impl.
This closes §15.1 #3 compile dispatch chain: KLineView.draw(_:) → 8 drawXxx methods.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: §15.1 #3 编译验证 — 跑两种 build + 严格并发

**Files:**
- 无新文件，仅 build/test 命令

**目标：** 关闭 §15.1 #3 闸门"`draw(_:)` 调用 C3-C6 extension 方法，编译期检查方法签名匹配"。

- [ ] **Step 7.1: macOS host swift test 跑全部 suite**

⚠️ **codex R5 finding 2 修复（v6）：** 加 `set -o pipefail` + 显式 exit-code 捕获，避免 tail 吞 swift test 失败状态。zsh/bash 都支持 `set -o pipefail`，shell-agnostic。

Run:
```bash
cd ios/Contracts
LOG=/tmp/pr8-step7.1.log
rm -f "$LOG"

# pipefail + if ! 块：shell-agnostic（zsh/bash 都生效），swift test 失败立刻 false
if ! ( set -o pipefail; swift test 2>&1 | tee "$LOG" ) ; then
  echo "GATE FAIL: swift test exited non-zero（macOS host）"; exit 1
fi

# 末尾 20 行人眼查（已 tee 到 LOG，不丢失上游错误）
tail -20 "$LOG"
echo "GATE PASS: macOS host swift test 全绿"
```

Expected: 末尾 `GATE PASS: macOS host swift test 全绿`；日志 `/tmp/pr8-step7.1.log` 末尾出现 `Test run with N tests in M suites passed`（**N ≥ 269** = 265 baseline + 4 KLineRenderState 可见 + 0 KLineViewCompile macOS skip；M ≥ 59 = 58 baseline + 1 RenderState suite，KLineView suite 在 macOS host 因 `#if canImport(UIKit)` 整块跳过不计 suite）。

⚠️ **codex R7 finding 2 修复（v8）：** 原 v6 写 "N ≥ 281" 是数学错误（265 + 4 + 3 但 3 个 KLineView test 在 macOS host 不出现 = 0 计数）。正确数字 N ≥ 269。

如果有 "Type 'X' does not conform to Sendable" 警告 → Task 1.2 占位 DrawingObject 或 Task 1.4 字段未标 Sendable，回 Task 1 修复。

- [ ] **Step 7.2: UIKit 编译路径强制 build（§15.1 #3 闸门关闭的唯一硬门槛）**

**⚠️ codex R1 finding 1 修复（v2，blocking gate）：** R1 拒收了"subagent 不在此点 abort"的兜底；本步骤改为**必须跑过且必须 BUILD SUCCEEDED**，否则 PR 不得进入 Task 8 / 不得创建 GitHub PR。理由：本 PR 唯一交付的 production 价值就是 §15.1 #3 编译验证；如果 UIKit shell 从未跑过编译器，闸门未关闭、PR 没产出。

**优先级 1：Mac Catalyst build-for-testing（已在 plan 阶段实测 BUILD SUCCEEDED on user's host，2026-05-16；最可靠的 UIKit 路径）**

Mac Catalyst 是 UIKit 编译 target —— `#if canImport(UIKit)` 触发、`UIView` 类型可解析。Mac Catalyst 在用户机器（macOS 25.3 + Xcode 17F42）上是唯一**当前可用的 UIKit 编译路径**（iOS Simulator runtime 26.5 设备 SDK 未装）。

⚠️ **codex R2 finding 3 + R6 finding 1 修复（v3 → v7）：** 改为 `build-for-testing`（而非 `build`），让 KLineViewCompileTests 在 Catalyst 上**编译通过**。注意：**`build-for-testing` 只编译不执行测试** —— spec L1240 "相同输入两次 render 只画一次" runtime invariant **本 PR 显式 defer 到 Wave 1 C8 integration PR**（与 L1167 同性质 residual，原因：spec L1179 `final class` 不可继承 + UIView display() runloop 异步 → 单元测试同步 assert 不到）。本 step 7.2 闸门 = **§15.1 #3 compile-only**（draw 派发签名匹配）；不声称验证 L1240 runtime。

⚠️ **codex R2 finding 1 + R5 finding 1 修复（v3 → v6，mechanical gate shell-agnostic）：** 用 `if ! ( set -o pipefail; cmd | tee )` 块替代 `${PIPESTATUS[0]}`（bash-only，zsh 用 `$pipestatus[1]`）；闸门 zsh/bash 通用、mechanically enforceable、不依赖人眼看输出。

```bash
cd ios/Contracts

LOG=/tmp/pr8-step7.2.log
rm -f "$LOG"

# Gate check #1: xcodebuild 必须 exit 0（pipefail + if ! 块，shell-agnostic）
if ! ( set -o pipefail; xcodebuild build-for-testing \
        -scheme KlineTrainerContracts \
        -destination 'platform=macOS,variant=Mac Catalyst' \
        2>&1 | tee "$LOG" ) ; then
  echo "GATE FAIL: xcodebuild exited non-zero"; exit 1
fi

# Gate check #2: 日志必须含 "** BUILD SUCCEEDED **" 或 "** TEST BUILD SUCCEEDED **"
# (v9 修：build-for-testing 输出 TEST BUILD SUCCEEDED；plain build 输出 BUILD SUCCEEDED；都接受)
grep -qE '\*\* (TEST )?BUILD SUCCEEDED \*\*' "$LOG" || { echo "GATE FAIL: no BUILD SUCCEEDED in log"; exit 1; }

# Gate check #3: 日志不得有 "error:" 行（xcodebuild 错误行）
# ⚠️ codex R3 finding 3 修复（v4）：路径含空格（`/Users/maziming/Coding/Prj_Kline trainer/...`）
# 的诊断行原本 `^[^ ]+:` 匹配不到 → 改用 `(^|[[:space:]])error:` 兼容路径前缀含空格
if grep -E '(^|[[:space:]])error:' "$LOG"; then
  echo "GATE FAIL: error: 行在日志中"; exit 1
fi

# Gate check #4: 日志不得有 "warning:" 行（严格并发警告 + 弃用警告）
if grep -E '(^|[[:space:]])warning:' "$LOG"; then
  echo "GATE FAIL: warning: 行在日志中（spec L2454 strict concurrency）"; exit 1
fi

echo "GATE PASS: §15.1 #3 闸门关闭"
```

Expected: 末尾 `GATE PASS: §15.1 #3 闸门关闭`。日志保留在 `/tmp/pr8-step7.2.log` 作为闸门关闭证据（commit 前不删；可作 PR description 附件）。

**优先级 2：iOS Simulator build（若用户已装 iOS 26.x Simulator runtime 则跑此条；与优先级 1 互补）**

可选：如果 `xcrun simctl list runtimes 2>&1 | grep -i 'iOS'` 显示有 runtime 且 `xcodebuild -list` 中 KlineTrainerContracts 的 Available destinations 含 iOS Simulator 项，则跑：

```bash
cd ios/Contracts
DEVICE_NAME=$(xcrun simctl list devices available 2>&1 | grep -E 'iPhone [0-9]' | head -1 | sed -E 's/^[[:space:]]+([^(]+)[[:space:]]+\(.*$/\1/' | xargs)
xcodebuild build-for-testing \
  -scheme KlineTrainerContracts \
  -destination "platform=iOS Simulator,name=$DEVICE_NAME" \
  -derivedDataPath .build/xcodebuild \
  SWIFT_STRICT_CONCURRENCY=complete \
  2>&1 | tail -30
```

Expected: BUILD SUCCEEDED。**非强制项**（如果 iOS Simulator 不可用则 skip），因为优先级 1 Mac Catalyst 已等价覆盖 UIKit 编译路径。

**闸门关闭硬规则（codex R1 finding 1 修复）：**

- 优先级 1（Mac Catalyst）**MUST PASS**——否则 subagent 必须 abort 当前 Task 7、回 Task 1-6 修复 UIKit shell 编译错误。
- 优先级 2（iOS Simulator）opt-in，**不作为闸门通过的硬条件**。
- 不允许"skip 整个 Step 7.2"路径。如果 Mac Catalyst BUILD FAILED 而错误非本 PR 引入（例如 GRDB 6.29.3 + Catalyst 不兼容），subagent 必须先 RCA、不能直接 mark Task 7 done。

- [ ] **Step 7.3: §15.1 #3 闸门关闭确认**

**⚠️ codex R4 finding 1 修复（v5）：** 闭门条件与 Step 7.2 v4 政策严格一致 —— **Catalyst-only 覆盖即可**，不再含 iOS Simulator 强制项。理由记录在条件 #4 注释。

手动确认（无需 commit）：
1. `KLineView.swift` 含 `override func draw(_ rect: CGRect)` ✓
2. draw 内 8 个 drawXxx 调用点存在 ✓
3. 8 个 extension 文件提供 8 个对应 method 签名 ✓
4. macOS host `swift test` 成功（Step 7.1） **AND** Mac Catalyst `xcodebuild build-for-testing` 成功（Step 7.2 优先级 1，GATE PASS 输出）

四条全 ✓ = §15.1 #3 闸门关闭。

**Catalyst-only 覆盖的 spec 等价性论据**：spec §15.1 #3 要求"`draw(_:)` 调用 C3-C6 extension 方法，**编译期**检查方法签名匹配"——Mac Catalyst target 与 iOS 同走 UIKit Swift compiler，`#if canImport(UIKit)` 触发同一组 extension 编译，方法签名错配产生同一种 Swift compile error。**所以 Catalyst BUILD SUCCEEDED ⟺ iOS BUILD SUCCEEDED 在签名匹配维度上**。

**Catalyst 不覆盖的 residual**（**与本 PR scope 切开**，PR 9 governance 时复盘）：
- iOS-only SDK 差异（@available(iOS …, *) 类签名差异 / iOS 特有 API surface）—— 本 PR 8 个 stub 方法不调用任何 iOS-only API，签名只用 `CGContext / CoordinateMapper / IndicatorMapper / ArraySlice<KLineCandle> / [TradeMarker] / [DrawingObject] / CGPoint? / ChartViewport / Period`，全部 cross-iOS/Catalyst 共编。
- 优先级 2 iOS Simulator build 若用户机器装了 iOS 26.x runtime 则 opt-in 增强覆盖，**不作硬门槛**。

- [ ] **Step 7.4: 无 commit 步骤；本 task 是 verification gate**

---

## Task 8: 验收清单（非-coder 中文可执行）

**Files:**
- Create: `docs/acceptance/2026-05-16-pr8-c1c-render-c3-c6-stubs.md`

**目标：** 用户语音输入画像 + 无代码经验，需"action / expected / pass_fail"三段式可逐条执行的清单。参 `docs/acceptance/2026-05-13-pr7b2-stale-drift-tests-helpers-cosmetic.md` 风格。

- [ ] **Step 8.1: 写验收清单**

`docs/acceptance/2026-05-16-pr8-c1c-render-c3-c6-stubs.md`：

```markdown
# PR 8 验收清单 — C1c Render + C3-C6 Stubs

> 这份清单给非-coder 用户用：复制每一行"action"到 Claude Code 或 Terminal，对照"expected"判断 pass / fail。

## A. 文件落地

| # | action | expected | pass_fail |
|---|---|---|---|
| A1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Render/` | 看到 9 个文件：KLineRenderState.swift / KLineView.swift / KLineView+Candles.swift / +Volume.swift / +MACD.swift / +Markers.swift / +Crosshair.swift / +Drawing.swift | ☐ |
| A2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/Render/` | 看到 2 个测试文件：KLineRenderStateTests.swift / KLineViewCompileTests.swift | ☐ |

## B. 编译验证（§15.1 #3 闸门）

| # | action | expected | pass_fail |
|---|---|---|---|
| B1 | `cd ios/Contracts && swift build` | 输出 `Build complete!`，无 error 无 warning | ☐ |
| B2 | `cd ios/Contracts && if ! ( set -o pipefail; swift test 2>&1 \| tee /tmp/pr8-b2.log ); then echo FAIL; else tail -5 /tmp/pr8-b2.log; fi` | 末尾出现 `Test run with N tests in M suites passed`，**N ≥ 269**（codex R7 finding 2 修：265 baseline + 4 RenderState 可见，macOS host skip UIKit suite）、M ≥ 59；**未** 出现 `FAIL` 字样（codex R5 finding 2：pipefail + tee 避免 tail 吞失败状态） | ☐ |
| B3 | UIKit 编译路径（**§15.1 #3 闸门**）：跑 plan Task 7.2 整段（set -o pipefail + xcodebuild build-for-testing Catalyst + 4 项 grep gate check）；查 `/tmp/pr8-step7.2.log` | 末尾输出 `GATE PASS: §15.1 #3 闸门关闭`；`/tmp/pr8-step7.2.log` 含 `** BUILD SUCCEEDED **`、无 `error:` / `warning:` 行 | ☐ |

## C. Scope 边界（不应做的事）

| # | action | expected | pass_fail |
|---|---|---|---|
| C1 | `grep -rn "fillRect\|setStrokeColor\|moveTo\|addLine" ios/Contracts/Sources/KlineTrainerContracts/Render/` | 输出为空（C3-C6 stubs 不含任何实际绘图调用） | ☐ |
| C2 | 在 `docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md` 搜 "tag" / "sign-off" / "wave0-frozen" 在 Scope 决策表中 | 这些项明确标 ❌ 拆 PR 9，不在本 PR 范围 | ☐ |
| C3 | `git diff main -- ios/KlineTrainer/` | 输出为空（不动 Xcode app 工程） | ☐ |

## D. Cross-platform 守卫

| # | action | expected | pass_fail |
|---|---|---|---|
| D1 | `grep -c "#if canImport(UIKit)" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView*.swift` | 7（KLineView + 6 个 extension 文件） | ☐ |
| D2 | `grep -c "#if canImport(UIKit)" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift` | 0（纯值类型不守卫） | ☐ |

## E. CI（GitHub Actions）

| # | action | expected | pass_fail |
|---|---|---|---|
| E1 | `gh pr checks <pr_number>` | 6/6 checks SUCCESS（或 OpenAI quota fail 走 admin bypass，按 memory feedback_openai_quota_ci_pattern） | ☐ |

## F. 文档

| # | action | expected | pass_fail |
|---|---|---|---|
| F1 | `ls docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md` | 文件存在 | ☐ |
| F2 | `ls docs/superpowers/plans/2026-05-14-pr7b3-deceleration-stop-integration.md` | 文件存在（PR #50 漏 commit 已 Task 0 修复） | ☐ |
| F3 | 本验收清单本身 ls 存在 | 文件存在 | ☐ |

## 验收规则

- 所有项必须 ✓ pass_fail = ☑
- 任一项 ☒（fail）→ 不合并；回 plan 阶段修
- B1/B2/B3 全过 = §15.1 #3 闸门关闭（PR 9 治理 PR 后续打 tag 用）
```

- [ ] **Step 8.2: Commit**

```bash
git add docs/acceptance/2026-05-16-pr8-c1c-render-c3-c6-stubs.md
git commit -m "docs(PR8): acceptance checklist — C1c Render + C3-C6 stubs

Non-coder executable: 6 sections (A-F) × ~13 items.
B section (compile gate §15.1 #3) is the core acceptance criterion.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

实施全部完成后（Task 0-8 全 commit），本 plan 作者（subagent driver）做以下自检：

**1. Spec coverage：**

| spec 要求 | 实现位置 |
|---|---|
| L2107-2210 KLineRenderState 字段 + KLineView 本体 + draw 派发 | Task 1, 2 |
| L2128 C3-C6 drawXxx 空 stub | Task 3, 4, 5, 6 |
| L2255 §十一 Checklist "KLineView 本体（C1c）+ KLineRenderState + ChartPanelFrames" | Task 1, 2 |
| L2256 §十一 Checklist "C1a/C1b/C1c 值类型 Equatable, Sendable" | Task 1.5 |
| L2451 §15.1 #3 编译验证 | Task 7 |
| 不在 scope：§15.1 sign-off ceremony + tag wave0-frozen | Scope 决策表 ❌ 拆 PR 9 |

✓ 全覆盖。

**2. Placeholder scan：** 全 plan 搜 "TBD" / "TODO" / "fill in" / "implement later" → 期望 Task 1.4 内的 `/* TODO Task 1.4: 填默认 ... */` 是字段初始化占位（subagent 实施 Task 1 时落定），是 plan 步骤的预期行为不是 plan failure。其余 plan 文本无 placeholder。

✓ 通过（含 1 处合规 TODO）。

**3. Type consistency：**

- `KLineRenderState` 在 Task 1 定义 9 个字段 + `.empty` 默认；Task 2 `KLineView.renderState` 默认 = `.empty` ✓
- `drawCandles` / `drawMA66` / `drawBOLL` 在 Task 2 draw 调用点签名 `(ctx, mapper, candles)` 与 Task 3 extension 完全一致 ✓
- `drawVolume` / `drawMACD` 用 `IndicatorMapper`（Task 2 派发 volMapper/macdMapper）与 Task 4 一致 ✓
- `drawMarkers` 用 `(ctx, viewport, mapper, markers, candles)` Task 2 vs Task 5.1 一致 ✓
- `drawCrosshair` 用 `(ctx, at: point, viewport)` Task 2 vs Task 5.2 一致 ✓
- `drawDrawings` 用 `(ctx, mapper, drawings, period)` Task 2 vs Task 6.1 一致 ✓
- `DrawingObject` Task 1.2 占位若引入，Task 6 不重定义 ✓

✓ 全一致。

---

## Execution Handoff

**计划完成并 saved to `docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md`。**

下一步按项目 user-explicit-skip + memory `project_executing_plans_excluded` 走 **Subagent-Driven** 方案：

- **REQUIRED SUB-SKILL：** `superpowers:subagent-driven-development`
- Fresh sonnet 4.6 high-effort subagent per task；Task 与 Task 之间主线 two-stage review
- Plan APPROVE（codex 对抗 review 收敛）→ 起 worktree（Task 0.1）→ subagent 跑 Task 0.2-8

下一动作（主线）：
1. ✅ Plan 写完 = 现在
2. → run `codex:adversarial-review` 跑 plan 阶段对抗 review；收敛或 ≥5 轮 escalate
3. APPROVE 后 → `superpowers:using-git-worktrees` 起 worktree
4. → 按 Task 0-8 派 subagent 实施
5. 实施完 → `superpowers:verification-before-completion` + `superpowers:requesting-code-review`
6. → branch-diff `codex:adversarial-review` 收敛
7. → `superpowers:finishing-a-development-branch` 收尾（admin bypass merge per `feedback_openai_quota_ci_pattern`）
