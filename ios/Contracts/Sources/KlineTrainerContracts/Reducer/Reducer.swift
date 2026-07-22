// Kline Trainer C1b — 状态值类型 + 部分 Reducer
// Spec: kline_trainer_modules_v1.4.md §C1b L957-1131 + L1136-1144
// Plan: docs/superpowers/plans/2026-05-05-pr7a-c1b-values-revision.md
//
// PR7a scope（本文件本 PR 落地）：
//   - 6 值类型 declaration + Equatable + Sendable
//   - PanelViewState.freeze() 扩展
//   - PanelViewState.reduce(_:) 内 5 个非-drawing case 真实现
//     (panStarted / panEnded / tradeTriggered / periodComboSwitched / offsetApplied)
//   - 4 个 drawing case 占位返回 .none（PR7b1 替换为真实现）
//
// PR7b1 scope（不在本 PR 范围）：activateDrawing / setDrawingSnapshot /
//   drawingCommitted / drawingCancelled 真实现 + 27 格矩阵测试 + 拆 catch-all
// PR7b2 scope: 3 漂移 + cross-session guard
// PR7b3 scope: DecelerationAnimator 集成

import Foundation
import CoreGraphics

// MARK: - 状态类型

/// modules L957-973 字面：面板视图状态（reducer 单一真值）。
/// `revision` 由 reducer/effect 单调递增，外部只读（spec L962）。
public struct PanelViewState: Equatable, Sendable {
    public var period: Period
    public var interactionMode: ChartInteractionMode
    public var visibleCount: Int
    public var offset: CGFloat
    /// `private(set)`: 编译期强制「外部只读」（spec L962 「revision 只由 reducer/effect 递增」）。
    /// reducer extension 在同文件，可 mutate；外部模块不能写。
    public private(set) var revision: UInt64

    public init(period: Period, interactionMode: ChartInteractionMode,
                visibleCount: Int, offset: CGFloat, revision: UInt64) {
        self.period = period
        self.interactionMode = interactionMode
        self.visibleCount = visibleCount
        self.offset = offset
        self.revision = revision
    }
}

/// modules L965-967 字面：3 个交互模式。
public enum ChartInteractionMode: Equatable, Sendable {
    case autoTracking
    case freeScrolling
    case drawing(snapshot: DrawingSnapshot)
}

/// modules L976-983 字面：非递归冻结快照（v1.2 拆 + v1.3 baseRevision）。
public struct FrozenPanelState: Equatable, Sendable {
    public let period: Period
    public let visibleCount: Int
    public let offset: CGFloat
    public let candleRange: Range<Int>
    public let baseRevision: UInt64

    public init(period: Period, visibleCount: Int, offset: CGFloat,
                candleRange: Range<Int>, baseRevision: UInt64) {
        self.period = period
        self.visibleCount = visibleCount
        self.offset = offset
        self.candleRange = candleRange
        self.baseRevision = baseRevision
    }
}

/// modules L985-987 字面：drawing 模式的不可变快照容器。
public struct DrawingSnapshot: Equatable, Sendable {
    public let frozen: FrozenPanelState

    public init(frozen: FrozenPanelState) {
        self.frozen = frozen
    }
}

// MARK: - freeze 扩展（modules L989-994 字面）

extension PanelViewState {
    /// modules L989-994 字面：冻结当前面板，记录当前 revision 作为 baseRevision。
    public func freeze(candleRange: Range<Int>) -> FrozenPanelState {
        FrozenPanelState(period: period, visibleCount: visibleCount,
                         offset: offset, candleRange: candleRange,
                         baseRevision: revision)
    }
}

// MARK: - 动作 (modules L1136-1144)

/// modules L1136-1144 字面：v1.3 加 setDrawingSnapshot / offsetApplied，
/// activateDrawing 不再直接切 mode（只触发 effect）。
public enum ChartAction: Equatable, Sendable {
    case panStarted
    case panEnded(velocity: CGFloat)
    case activateDrawing(DrawingToolType)
    case setDrawingSnapshot(tool: DrawingToolType, baseRevision: UInt64, candleRange: Range<Int>)
    case drawingCommitted(baseRevision: UInt64)
    case drawingCancelled(baseRevision: UInt64)
    case tradeTriggered
    case periodComboSwitched
    case offsetApplied(deltaPixels: CGFloat)
    /// 顺位 3 §4.4d pinch 缩放：几何在 engine 侧算好（PinchZoomModel），reducer 只收最终值。
    case zoomApplied(visibleCount: Int, offset: CGFloat)
}

// MARK: - 副作用 (modules L1009-1023)

/// modules L1009-1023 字面：v1.3 effect 拆 stale + activateDrawing handler 合约。
public enum ChartReduceEffect: Equatable, Sendable {
    case none
    case startDeceleration(velocity: CGFloat)
    case clearPendingDrawing
    /// activateDrawing 返回此 effect。Handler 合约（必须按序）：
    ///   1. 立即调用 DecelerationAnimator.stop()（防 stale 漂移，闸门 #2 F2）
    ///   2. 基于当前 viewport 计算 candleRange
    ///   3. 派发 ChartAction.setDrawingSnapshot(tool, baseRevision, candleRange)
    case requestDrawingSnapshotAfterStoppingAnimator(tool: DrawingToolType, baseRevision: UInt64)
    /// setDrawingSnapshot 回推时发现 revision 已漂移 → snapshot 无效；mode 保持 autoTracking。
    case staleDrawingSnapshot(expected: UInt64, actual: UInt64)
}

// MARK: - 部分 Reducer (PR7a：5 非-drawing case 真实现 + 4 drawing case 占位)

extension PanelViewState {
    /// PR7a scope: 5 个非-drawing action 真实现（panStarted / panEnded / tradeTriggered /
    /// periodComboSwitched / offsetApplied）；4 个 drawing action 占位返回 .none，
    /// PR7b1 替换占位为真实现（modules L1003-1131 完整体）。
    public mutating func reduce(_ action: ChartAction) -> ChartReduceEffect {
        switch (interactionMode, action) {
        // —— panStarted ——
        case (.autoTracking, .panStarted):
            interactionMode = .freeScrolling
            revision &+= 1
            return .none
        case (.freeScrolling, .panStarted), (.drawing, .panStarted):
            return .none

        // —— panEnded ——
        case (.autoTracking, .panEnded):
            return .none
        // 1a-iv：.drawing 与 .freeScrolling 同 —— 画线时松手同样要走减速/回弹结算，
        // 否则 applyPanOffset 允许的 damped overscroll 松手后弹不回来，图表永久挂着越界间隙。
        case (.freeScrolling, .panEnded(let v)), (.drawing, .panEnded(let v)):
            revision &+= 1
            return .startDeceleration(velocity: v)

        // —— tradeTriggered（任意状态硬切 autoTracking + bump）——
        case (_, .tradeTriggered):
            interactionMode = .autoTracking
            revision &+= 1
            return .none

        // —— periodComboSwitched（同 trade，并 clearPendingDrawing）——
        case (_, .periodComboSwitched):
            interactionMode = .autoTracking
            revision &+= 1
            return .clearPendingDrawing

        // —— offsetApplied（三态均 += delta + bump）——
        // 1a-iv 视口解冻：.drawing 不再吞没。`.drawing` 仍是独立 mode（tap 落锚语义 / baseRevision 跨会话闸门
        // 不变），但**不再冻结视口** —— 画线模式下平移、切周期归一、resize 归一都必须真的作用到 offset。
        case (.autoTracking, .offsetApplied(let d)),
             (.freeScrolling, .offsetApplied(let d)),
             (.drawing, .offsetApplied(let d)):
            offset += d
            revision &+= 1
            return .none

        // —— zoomApplied（顺位 3 §4.4d：autoTracking 右锚置 0；freeScrolling/drawing focus offset）——
        case (.autoTracking, .zoomApplied(let v, _)):
            visibleCount = v
            offset = 0      // user 2026-06-13 裁决 A 右锚：显式置 0（防未来 drawingCommitted 残留 offset，R1-M3/L5）
            revision &+= 1
            return .none
        // 1a-iv：.drawing 与 .freeScrolling 同 —— 画线时捏合若走右锚会把视口跳回最新、抹掉用户刚平移到的历史位置。
        case (.freeScrolling, .zoomApplied(let v, let o)), (.drawing, .zoomApplied(let v, let o)):
            visibleCount = v
            offset = o
            revision &+= 1
            return .none

        // —— activateDrawing（spec L1052-1056；不直接进 drawing，只发 effect）——
        case (.autoTracking, .activateDrawing(let tool)),
             (.freeScrolling, .activateDrawing(let tool)):
            return .requestDrawingSnapshotAfterStoppingAnimator(tool: tool, baseRevision: revision)
        case (.drawing, .activateDrawing):
            return .none  // 切换工具由 DrawingToolManager 处理

        // —— setDrawingSnapshot（spec L1058-1072；外部回推 candleRange；matched 进 drawing；stale 留 effect）——
        case (.autoTracking, .setDrawingSnapshot(let tool, let baseRev, let range)),
             (.freeScrolling, .setDrawingSnapshot(let tool, let baseRev, let range)):
            guard baseRev == revision else {
                return .staleDrawingSnapshot(expected: baseRev, actual: revision)
            }
            _ = tool  // 由 DrawingToolManager 处理 tool 切换；reducer 只管面板 mode
            let frozen = FrozenPanelState(period: period, visibleCount: visibleCount,
                                          offset: offset, candleRange: range,
                                          baseRevision: revision)
            interactionMode = .drawing(snapshot: DrawingSnapshot(frozen: frozen))
            return .none
        case (.drawing, .setDrawingSnapshot):
            return .none  // drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing

        // —— drawingCommitted / drawingCancelled（spec L1074-1097 闸门 #5：cross-session guard）——
        case (.drawing(let snap), .drawingCommitted(let base)):
            guard base == snap.frozen.baseRevision else {
                // 来自上一轮 session 的延迟 action，忽略
                return .none
            }
            interactionMode = .autoTracking
            return .none
        case (.drawing(let snap), .drawingCancelled(let base)):
            guard base == snap.frozen.baseRevision else {
                return .none
            }
            interactionMode = .autoTracking
            return .none
        case (.autoTracking, .drawingCommitted), (.freeScrolling, .drawingCommitted),
             (.autoTracking, .drawingCancelled), (.freeScrolling, .drawingCancelled):
            assertionFailure("非法转换：\(interactionMode) → \(action)")
            return .none
        }
    }
}
