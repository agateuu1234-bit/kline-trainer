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
