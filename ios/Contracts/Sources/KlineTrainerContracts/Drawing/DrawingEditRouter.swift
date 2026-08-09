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

    // MARK: 可用性谓词（D65）—— **必须与引擎门逐条对齐**

    // ⚠️ `uniqueSelected` 已在 Task 2 Step 4 随本文件建好（`selectionGeometryVisible` 依赖它），**本 Task 不要重复定义**。

    /// 与引擎写入门**同作用域**的 id 唯一性（`TrainingEngine.updateDrawingStyle:1159` /
    /// `deleteDrawing(id:):1112` 都在**整个** `drawings` 上数）。
    /// ⚠️ 必须与 `uniqueSelected` 的**可见域**唯一性分开（整支 codex R1）：后者服务 D49 回显
    /// （面板仍显示那条看得见的线），前者服务可用性谓词（控件置灰）。两者合起来 = 「看得见、改不动」，
    /// 与 locked / 未来数据线同一套待遇。若谓词沿用可见域判据，一份可见 + 一份隐藏的重复 id 会让
    /// 控件亮着、点了却被引擎拒 → 正是 PR-2 交接② 点名的「控件亮着、点了没反应」。
    private static func idIsGloballyUnique(engine: TrainingEngine, id: DrawingID) -> Bool {
        engine.drawings.filter { $0.id == id }.count == 1
    }

    /// 「改样式可用」的**非几何分量**（review / 唯一 / `locked` / 工具已实现 / 未来数据）。
    /// ⚠️ **判据以引擎门为准，不是以 spec D65 的字面为准**（PR-2 交接②）：`updateDrawingStyle`
    /// 比 D65 写的三分量多**三道**——`flow.mode != .review`（D34 纵深）、`isEditableToolType`
    /// （本构建懂不懂这个工具的样式语义）、`hasKnownFutureFields`（未来顶层字段）。
    /// 少一道 = 控件亮着、点了没反应；多一道 = 过度置灰。两边都是缺陷。
    /// （引擎第 ④ 道 `withStyle` 语义闸**不在**本谓词里：它依赖**具体要写的样式**，
    ///   不是「这条线能不能改」的属性，由 `applyStyle` 逐次传播失败。）
    /// **抽出来是为了让「现算」与「读提示」两条路径只在几何这一点上不同**（PD2）——
    /// 若各写一份，早晚有一天两边的非几何分量会漂移。
    private static func editableIgnoringGeometry(engine: TrainingEngine) -> Bool {
        guard engine.flow.mode != .review else { return false }
        guard let d = uniqueSelected(engine: engine) else { return false }
        guard idIsGloballyUnique(engine: engine, id: d.id) else { return false }
        guard !d.locked else { return false }
        guard DrawingStyleAvailability.isEditableToolType(d.toolType) else { return false }
        return !engine.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [d.id])
            && !engine.loadedDrawingsLossy.hasKnownFutureFields(liveIds: [d.id])
    }

    /// 「删除可用」的**非几何分量** —— 与上者共享 review / 唯一 / `locked` 三个分量，
    /// **不含**未来数据与工具两个分量：删整条不产生"部分抹除"（raw 随之整体移除），
    /// 且它是这类线唯一的用户侧处置通道（D61）。与引擎 `deleteDrawing(id:)` 的三道门逐条对齐。
    private static func deletableIgnoringGeometry(engine: TrainingEngine) -> Bool {
        guard engine.flow.mode != .review else { return false }
        guard let d = uniqueSelected(engine: engine) else { return false }
        guard idIsGloballyUnique(engine: engine, id: d.id) else { return false }
        return !d.locked
    }

    // MARK: 两个读法（PD2）—— 几何**现算**给写入路由，几何**读 observable 提示**给 UI 置灰

    /// **路由用**（唯一的门）：几何现算。
    static func canEditStyle(engine: TrainingEngine) -> Bool {
        editableIgnoringGeometry(engine: engine) && selectionGeometryVisible(engine: engine)
    }

    /// **路由用**（唯一的门）：几何现算。
    static func canDelete(engine: TrainingEngine) -> Bool {
        deletableIgnoringGeometry(engine: engine) && selectionGeometryVisible(engine: engine)
    }

    /// **UI 用**：5 组样式控件是否可用。
    /// ⚠️ 两处刻意与上面不同，**都不是笔误**（codex plan-R1-F1/F2）：
    ///   ① **无选中 → 恒可用**：此刻面板在改「下一条线的默认」，与任何线的状态无关。
    ///      写成 `canEditStyle` 会让无选中时控件全灰 —— 那是 1a-iii 就有的能力，会被直接回归掉
    ///      （验收 #13：取消选中后改默认、再画一条新线）。
    ///   ② 几何读 **observable** 的 `selectionGeometryVisible`，**不是**现算：
    ///      mapper 是 `@ObservationIgnored`，UI 若走现算，SwiftUI 建立不了依赖 →
    ///      平移到线看不见时**不重绘** → 控件停在旧状态（验收 #18c 失效）。
    ///      提示陈旧最坏只是晚一帧，写入仍会被 `canEditStyle` 那道现算的门拦住。
    static func styleControlsEnabled(engine: TrainingEngine) -> Bool {
        guard engine.drawingSession.selectedDrawingID != nil else { return true }   // ①
        return editableIgnoringGeometry(engine: engine)
            && engine.drawingSession.selectionGeometryVisible                        // ②
    }

    /// **UI 用**：🗑 是否可用。与 `styleControlsEnabled` **刻意不对称**——无选中时 🗑 没有操作对象，
    /// 恒灰（spec §1.1 #1 原文：「无选中时灰」）。几何同样读 observable 提示（理由同上）。
    static func deleteButtonEnabled(engine: TrainingEngine) -> Bool {
        deletableIgnoringGeometry(engine: engine) && engine.drawingSession.selectionGeometryVisible
    }

    // MARK: D49 面板派生样式（**唯一**一处从 DrawingObject 取 5 个样式字段）

    /// 常驻面板此刻该显示的样式：有选中 → 那条线的当前样式；无选中 → 「下一条线的默认」。
    /// **是每次求值现算的派生值，不是拷贝进某个 @State 的副本**（D49：常驻面板长期存活，
    /// 任何第二份样式状态都会与 `engine.drawings` 里的真值漂移）。
    static func panelStyle(engine: TrainingEngine) -> DrawingDefaultStyle {
        guard let d = uniqueSelected(engine: engine) else { return engine.drawingSession.defaultStyle }
        var s = DrawingDefaultStyle()
        s.lineSubType = d.lineSubType
        s.lineStyle = d.lineStyle
        s.thickness = d.thickness
        s.colorToken = d.colorToken
        s.labelMode = d.labelMode
        return s
    }

    // MARK: 两条写入路由（`Sources/` 里 updateDrawingStyle / deleteDrawing(id:) 的**唯一**调用点）

    /// D54 clause 3 + D64：写入之后（无论成败、无论有没有真的调过引擎）按**状态**同步选中。
    /// **绝不读任何 API 的返回值**：失败原因有五类，其中三类必须保留选中，一个 Bool 表达不了
    /// （spec D64 的全部理由）。
    ///
    /// 判据 = D64 原文那个析取式「清空 ⟺（**结构性**不含 **或** 存在性缺失）」，而
    /// `visibleDrawings(for: selectedPanel)` **不含该 id** 已经把两项一并覆盖（线被删了就哪个集合都不在）
    /// → 一个谓词表达完整语义，没有第二处可以写漏（codex plan-R5-F1）。
    /// ⚠️ **绝不能改用带 mapper 的几何判据**：`visibleDrawings` 无 mapper、**只判结构**，
    /// 几何性不可见的线仍在集合里 → 不会把 D63 退化成「一次惯性平移就把选中抖掉」（那正是
    /// D63 明确拒绝 codex 原处方的理由）。
    /// ⚠️ **不复用 `uniqueSelected`**：它额外要求「唯一」（`matches.count == 1`），而 D64 的判据
    /// 里没有这一项——「两条同 id」是坏状态（D66 引擎侧会 fail），不该被本函数顺手当成「不存在」
    /// 从而夺走用户的选中（spec N17 表格「id 非唯一」一行明写：选中原样保留）。故直接判 **membership**。
    private static func syncSelectionByState(engine: TrainingEngine) {
        guard let id = engine.drawingSession.selectedDrawingID,
              let panel = engine.drawingSession.selectedPanel else { return }
        let visible = RenderStateBuilder.visibleDrawings(
            engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
        if !visible.contains(where: { $0.id == id }) { engine.drawingSession.clearSelection() }
    }

    /// 改选中线的样式。执行顺序（D65 明写，不得调换）：
    ///   ① D65 当前几何门（**在写入这一刻现算**）→ ② 仅当 `lineSubType` 真的变了才跑 D58 候选预检
    ///   → ③ 才调引擎（引擎自己再把 viewport 无关的六道门跑一遍）。
    @discardableResult
    static func applyStyle(_ style: DrawingDefaultStyle, engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        guard let id = engine.drawingSession.selectedDrawingID,
              let panel = engine.drawingSession.selectedPanel,
              let old = uniqueSelected(engine: engine) else { return false }
        guard canEditStyle(engine: engine) else { return false }                       // ①
        if style.lineSubType != old.lineSubType {                                      // ②
            // 候选对象**必须**用 `withStyle` 造（语义单点 D59），不许自己拼一个 DrawingObject。
            guard let candidate = old.withStyle(style),
                  let mapper = engine.drawingSession.viewportMapper(for: panel),
                  HorizontalLineTool.visibleGeometry(for: candidate, mapper: mapper) != nil
            else { return false }
        }
        return engine.updateDrawingStyle(id: id, style: style)                         // ③
    }

    // MARK: 变更意图路由（codex 整支 R3：本 PR 引入的回归修复）
    //
    // `DrawingStyleParams` 原来的写入路径从**视图渲染时捕获的快照**（`style` 参数）出发：
    //   `var next = style; mutate(&next); onChange(next)`。若两个控件在 SwiftUI 完成重渲染之前
    //   先后触发，第二次动作仍从**同一份旧快照**出发 → 把第一次的改动 revert 掉；选中线路径还会
    //   `drawingsRevision += 1` → 被 autosave 持久化，回退是真实丢数据。
    // `origin/main` 上的旧实现本来就是「动作发生那一刻，从活的单一真相现取 `session.defaultStyle`」，
    // PR-4 把派生值算好传进视图时，把「现取」这个性质丢了。这两个函数把它还回来：
    // `DrawingStyleParams` 只把**变更意图**（mutation 闭包）传上去，「现取 + 合并」在这里（host 可测）完成。

    /// 把一次样式变更**合并进动作发生那一刻的当前真值**再写入选中线。
    /// ⚠️ **绝不能改成接收调用方传入的快照**——那正是本函数要修的回归本身。
    @discardableResult
    static func applyStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                   engine: TrainingEngine) -> Bool {
        var next = panelStyle(engine: engine)      // ← 现取（动作发生这一刻的真值，不是渲染时的快照）
        mutate(&next)
        return applyStyle(next, engine: engine)
    }

    /// 无选中时：同样「现取 + 合并」，写「下一条线的默认」。
    static func applyDefaultStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                          engine: TrainingEngine) {
        var next = engine.drawingSession.defaultStyle   // ← 现取
        mutate(&next)
        engine.drawingSession.setDefaultStyle(next)
    }

    /// 删除选中线。**唯一合法调用点是确认框「删除」按钮的 action**——几何必须在**确认那一刻**
    /// 重算（`canDelete` 内部现算），只在点 🗑 那一刻判是时序 bug（D65 R13-F1 / N19e）。
    @discardableResult
    static func deleteSelected(engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        guard let id = engine.drawingSession.selectedDrawingID else { return false }
        guard canDelete(engine: engine) else { return false }
        return engine.deleteDrawing(id: id)
    }
}
