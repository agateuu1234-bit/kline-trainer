// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingToolManager.swift
// Spec: kline_trainer_modules_v1.4.md §C6 L1330-1343 + design doc §2.3 §3.1 §四
// Wave 1 PR C6: pure in-memory state container. NO ChartReducer coupling.
// Reducer integration (.activateDrawing / .drawingCommitted / .drawingCancelled
// ChartAction dispatch) is Wave 3 UI 层 responsibility per design §3.3.
//
// 跨平台：@MainActor + @Observable + Observation framework 在 iOS 17+/macOS 14+ 都支持。
// 仅依赖 Models.swift 跨平台值类型；无 UIKit 依赖。

import Observation

@MainActor
@Observable
public final class DrawingToolManager {
    // public private(set): trust-boundary 强化 — 外部 readonly + 仅 5 方法可 mutate；
    // 防 caller 直接 mutate pendingAnchors/completedDrawings 绕过 toggle/commit guards。
    // var 保留（spec §2.3 字面 + @Observable 要求）。
    public private(set) var activeTool: DrawingToolType?
    public private(set) var enabledTools: Set<DrawingToolType>
    public private(set) var pendingAnchors: [DrawingAnchor]
    public private(set) var completedDrawings: [DrawingObject]

    public init(enabledTools: Set<DrawingToolType> = []) {
        self.activeTool = nil
        self.enabledTools = enabledTools
        self.pendingAnchors = []
        self.completedDrawings = []
    }

    /// Spec §3.1 toggle: 互斥语义 + 切工具时清空 pendingAnchors.
    /// - 同 tool 再 toggle = 关闭 (activeTool=nil, pendingAnchors=[])
    /// - 切到新 tool = 覆写 activeTool + 清 pending（隐含取消上一个 tool）
    /// - 不在 enabledTools 内 = no-op return
    public func toggle(_ t: DrawingToolType) {
        guard enabledTools.contains(t) else { return }
        if activeTool == t {
            activeTool = nil
            pendingAnchors = []
        } else {
            activeTool = t
            pendingAnchors = []
        }
    }

    /// Spec §3.1 addAnchor: append-only.
    /// - invariant: activeTool != nil (caller must toggle first)
    public func addAnchor(_ a: DrawingAnchor) {
        // invariant: activeTool != nil
        precondition(activeTool != nil, "addAnchor requires activeTool != nil (caller must toggle first)")
        pendingAnchors.append(a)
    }

    /// Spec §3.1 commit: move pending → completedDrawings + reset.
    /// - invariant: activeTool != nil && !pendingAnchors.isEmpty
    /// - anchor 数量上下界由 caller (DrawingInputController.shouldCommit) gate, NOT manager.
    public func commit() {
        // invariant: activeTool != nil
        precondition(activeTool != nil, "commit requires activeTool != nil")
        // invariant: !pendingAnchors.isEmpty
        precondition(!pendingAnchors.isEmpty, "commit requires non-empty pendingAnchors (shouldCommit gate)")
        let drawing = DrawingObject(
            toolType: activeTool!,
            anchors: pendingAnchors,
            isExtended: false,
            panelPosition: 0
        )
        completedDrawings.append(drawing)
        activeTool = nil
        pendingAnchors = []
    }

    /// Spec §3.1 cancel: idempotent no-op when activeTool == nil.
    public func cancel() {
        guard activeTool != nil else { return }
        activeTool = nil
        pendingAnchors = []
    }

    /// Spec §3.1 deleteDrawing.
    /// - invariant: completedDrawings.indices.contains(index)
    public func deleteDrawing(at index: Int) {
        // invariant: completedDrawings.indices.contains(index)
        precondition(completedDrawings.indices.contains(index), "deleteDrawing index out of bounds")
        completedDrawings.remove(at: index)
    }
}
