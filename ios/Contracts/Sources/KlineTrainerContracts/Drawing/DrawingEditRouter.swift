// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift
// PR-4（1b-i 切片4）：选中对象的**唯一**写入路由 + D65 两个可用性谓词。
//
// 为什么单独一个类型而不是塞进 View：
//   ① D62/D51 要求 `updateDrawingStyle` / `deleteDrawing(id:)` 在 `Sources/` 里**恰好一个**调用点，
//      且那一处必须已先验 `visibleGeometry`；把它固定在一个无 UIKit 的类型里，源码守卫的白名单
//      就只需放行一个文件，SwiftUI 那边加多少控件都不会再开新的写入口。
//   ② 无 UIKit ⇒ host `swift test` 就能跑——几何门 / 确认框时间窗 / 失败原因 × 选中生命期
//      这些最危险的判据不必赌 Catalyst 才有证据。
// 本类型**不持有任何状态**：所有输入都从 engine / session 现读，所有判据都是纯函数。
import CoreGraphics

@MainActor
enum DrawingEditRouter {

    /// 选中线此刻在 `selectedPanel` 上几何可见吗（D63 的「几何性可见」维度）。
    /// 判据**复用** `HorizontalLineTool.visibleGeometry`（与渲染 / 命中 / 标注同一个实现，D40），
    /// 视口取 `session.viewportMapper(for: selectedPanel)` —— 即那个面板**真实渲染用过**的视口。
    /// 任何一环缺失（无选中 / 无视口 / 线已不在 `drawings`）一律 **false（fail-closed）**：
    /// 判不了就不许动，绝不乐观放行。
    /// 当前选中的那条线（不存在 / 不唯一 / **不在渲染可见集合里** → nil，D66：绝不"取第一条碰到的"）。
    ///
    /// ⚠️ **必须从 `RenderStateBuilder.visibleDrawings` 里取，不能从 `engine.drawings` 里取**
    /// （codex plan-R5-F1）：后者只是全局数组，**不含** D40 那三条判据——review 叠加层 /
    /// `belongsToPanel`（D29 周期归属 + 同周期 fail-safe）/ `revealTick <= tick` 渐显。
    /// 只按 id 从全局数组捞，等于把 D63 的**结构性**可见维度整个略过，只重算了几何那一半：
    /// 一条**渲染不出、也命不中**的线（迁到了另一面板 / 渐显未到），只要价位恰好映进
    /// `selectedPanel` 就能通过几何检查 → **可被改样式、可被不可逆删除**。
    /// 「结构性不可见时选中会被别处清掉」是靠**事件**（切周期善后）保证的，而 D64 的全部论点就是
    /// **能从状态算出来的就不要靠事件传递**——我对「存在性」维度守了这条纪律，这里必须一并守。
    /// `visibleDrawings` **没有 mapper**、只判结构 → 几何性不可见的线**仍在**集合里（D63 分流照旧：
    /// 保留选中、面板照常回显、只是控件灰），不会把 D63 退化成「一平移就丢选中」。
    private static func uniqueSelected(engine: TrainingEngine) -> DrawingObject? {
        guard let id = engine.drawingSession.selectedDrawingID, !id.isEmpty,
              let panel = engine.drawingSession.selectedPanel else { return nil }
        let visible = RenderStateBuilder.visibleDrawings(
            engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
        let matches = visible.filter { $0.id == id }
        return matches.count == 1 ? matches.first : nil
    }

    /// ⚠️ 目标对象**经 `uniqueSelected` 取**（见其头注，codex plan-R5-F1）—— 那里已经把
    /// 「结构性可见」（`visibleDrawings` 的三条判据）挡在前面；本函数只负责**几何**那一层。
    /// 两层叠起来才等于「屏幕上真的看得见这条线」。
    static func selectionGeometryVisible(engine: TrainingEngine) -> Bool {
        let session = engine.drawingSession
        guard let panel = session.selectedPanel,
              let mapper = session.viewportMapper(for: panel),
              let drawing = uniqueSelected(engine: engine) else { return false }
        return HorizontalLineTool.visibleGeometry(for: drawing, mapper: mapper) != nil
    }
}
