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
        // D86（自动选中 spec §6.1 第二张表）：分流判据是 `session.mode`，不再是「有没有选中」。
        // 画线态**恒可用** —— 面板此刻改的是「本局默认」（必然写得进去），与任何线的状态无关；
        // 锁定的线只该让**附带的** `applyStyle` 被拒（§6.3 #2：灰只降饱和、绝不写解释文案），
        // 不该把面板整个灰掉。
        guard engine.drawingSession.mode == .select else { return true }
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
        // D86（自动选中 spec §6.1 第一张表）：分流判据是 `session.mode`，不再是「有没有选中」。
        // 画线态恒显示**本局默认**（=「接下来要画的样式」）。这条规则的自洽性来源是 D38：
        // 画线态下点图表是落锚、**不做 hitTest** → 画线态下被选中的必然是刚画的那一条；
        // 提交那一刻两者相等（`commitPending` 就是用 `defaultStyle` 造的线），只在「那条线改不动、
        // 默认继续改」之后才分叉 —— 而画线态的语义本来就是「我下一笔要画成什么样」。
        // 这是对 D49 的**有意修订**（§6.5 #3），不是回归。
        guard engine.drawingSession.mode == .select,
              let d = uniqueSelected(engine: engine) else { return engine.drawingSession.defaultStyle }
        return styleFields(of: d)
    }

    /// 从一条线上取 5 个样式字段。**`Sources/` 里唯一一处从 `DrawingObject` 取样式**（D49）。
    /// ⚠️ 它服务两个**不同的问题**：`panelStyle` 的选择态分支问「面板显示什么」，
    ///    Task 6 的 `selectedLineStyle` 问「改线时从哪儿起算」。两者在画线态**刻意不同**
    ///    （前者取默认、后者取线）—— 合并成一个函数正是 codex spec-R9 那条 high 的来源
    ///    （§6.4：「单一真相」是对同一个问题只留一个答案，不是对两个问题共用一个函数）。
    private static func styleFields(of d: DrawingObject) -> DrawingDefaultStyle {
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

    /// §6.4 base ②：选中线**当前**的 5 个样式字段（无选中 / 不唯一 / 结构性不可见 → nil）。
    /// 与 `panelStyle` 的选择态分支**同源取值**（都经 `uniqueSelected` + `styleFields`），
    /// 但**语义不同**：那个回答「面板显示什么」，这个回答「改线时从哪儿起算」。
    /// 两者在画线态**刻意不同** —— 前者取默认、后者取线。
    private static func selectedLineStyle(engine: TrainingEngine) -> DrawingDefaultStyle? {
        guard let d = uniqueSelected(engine: engine) else { return nil }
        return styleFields(of: d)
    }

    /// D86：常驻面板的**唯一**写入入口。取代 applyStyleMutation / applyDefaultStyleMutation。
    /// ⚠️ **不是**三个分支都与被取代的旧函数逐字等价：
    ///    - 分支 ②（选择态+有选中）/ 分支 ③（选择态+无选中）与旧的 `applyStyleMutation` /
    ///      `applyDefaultStyleMutation` **逐字等价** —— 这是「可以安全删掉旧函数」这一结论的证据；
    ///    - 分支 ①（画线态）是 **D86 的新语义**，与旧行为**有意不同**：旧函数从未覆盖过画线态，
    ///      本分支把「改样式」在画线态下的含义从「只改选中线」改成「改本局默认 + best-effort
    ///      顺带套到线上」，且**必须**用两个独立的 base（见下方反例）——那两个旧函数成为孤儿是
    ///      因为分支 ②③ 吸收了它们，不是因为分支 ① 把它们泛化了。
    ///    ⚠️ **不得**把分支 ① 的 base 改回 `panelStyle(engine:)`：画线态下它 ≡ `defaultStyle`，
    ///       改回去就是把整份默认快照套到线上（§6.3 #0 的缺陷），
    ///       `lockedDivergenceIsNeverRetroactivelyApplied`（M15）那条五步档会红。
    ///
    /// ⚠️ **画线态把同一个 mutation 分别套到两个 base 上**（spec §6.3 #0），**不是**套一份默认快照。
    ///    反例（上一稿会真的发生）：画线 A（橙、粗细 1，自动选中）→ 锁定 A → 改颜色为紫
    ///    （默认变紫；`applyStyle` 被 `!d.locked` 拒 → A 仍是橙 ⇒ **默认与 A 已分叉**）→ 解锁 A
    ///    → 只改**粗细**为 3。若此刻把「默认的整份快照 {紫, 3}」套上去 ⇒ **A 的颜色被静默从橙改成紫**，
    ///    并经 `drawingsRevision` → autosave **落盘**。用户只碰了粗细，被改掉的却是他刚刚特意
    ///    锁起来保护过的颜色。
    ///    ⚠️ `applyStyle` 的入参是**完整的** `DrawingDefaultStyle`（D50 的 API 形状，本片不改），
    ///       所以「只改一项」**只能靠选对 base 来表达**。**base 选错就是这条缺陷本身。**
    ///
    /// ⚠️ 两个 base 都**现取**（动作发生这一刻的真值，不是视图渲染时的快照）——
    ///    **绝不能改成接收调用方传入的快照**，那正是 1b-i PR-4 整支 R3 修过的那个真丢数据回归
    ///    （两个控件在 SwiftUI 重渲染之前先后触发，第二次拿旧快照把第一次 revert 掉，
    ///    选中线路径还会经 `drawingsRevision` 被 autosave 持久化）。
    static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                        engine: TrainingEngine) {
        let session = engine.drawingSession
        if session.mode == .draw {
            // **顺序 load-bearing**：先写默认（主语义、必须成功），**再** best-effort 改线
            // （附带、可能被锁定 / 滑出屏幕 / 未来数据 / 工具未实现四类门拒）。反过来写会让
            // 「线改失败」在实现上很容易被顺手写成「整个操作失败」，而用户点了一下颜色却什么都没变。
            var d = session.defaultStyle                        // base ①：默认自己
            mutate(&d)
            session.setDefaultStyle(d)
            if let cur = selectedLineStyle(engine: engine) {    // base ②：那条线自己当前的 5 个样式字段
                var l = cur
                mutate(&l)
                // ⚠️ 返回值**刻意丢弃**且**不得**据它决定选中生命期（D64 原样成立：失败原因有五类，
                //    其中三类必须保留选中，一个 Bool 表达不了）。失败也**不回滚默认、不给任何反馈**
                //    （母 spec §3 逐字：灰只降饱和、绝不写任何解释文案）。
                _ = applyStyle(l, engine: engine)
            }
        } else if session.selectedDrawingID != nil {
            // 选择态 + 有选中：只改那一条，**不回写默认**（D49 的核心价值，原样保留）。
            // base 取 `panelStyle` —— 选择态下它与 `selectedLineStyle` 同源，且这一支与被本函数
            // 取代的 `applyStyleMutation` **逐字等价**（严格泛化的证据）。
            var l = panelStyle(engine: engine)
            mutate(&l)
            _ = applyStyle(l, engine: engine)
        } else {
            // 选择态 + 无选中：改「下一条线的默认」。与被取代的 `applyDefaultStyleMutation` 逐字等价。
            var d = session.defaultStyle
            mutate(&d)
            session.setDefaultStyle(d)
        }
    }

    // MARK: D83 / D84 / D85 提交路由（自动选中 spec §3 / §4 / §5）

    /// **外层 = 生产入口**：从 pending 锚提交一条新线，并按状态决定选中处置。
    ///
    /// 覆盖 D83 分支 1 与分支 2 的**全部六条出口**（spec §3.1 那张表）—— 这就是它必须从
    /// `commitPending` 开始、而不是从 `routeDrawingCommit` 开始的全部理由（spec §3.4）：
    /// 出口 a / b / c 在改动前是 `ChartContainerView` 里的 `return`，在 `routeDrawingCommit`
    /// **之前**就退出了，于是最主要的两条被拒路径**永远不会清空选中**，D37 那个陷阱原样复现。
    /// ⚠️ **错误的修法（明令禁止，spec §3.4）**：在 `ChartContainerView` 的两处 `guard … else { return }`
    ///    里各补一句 `clearSelection()` —— 那会把分支 2 的判据散进三个地方，其中两处在 UIKit-gated
    ///    文件里（host 上根本不编译），且「三处保持一致」没有任何机制保证。
    ///
    /// `commitPending` 与 `routeDrawingCommit` 在 `Sources/` 里的**唯一**调用点（源码守卫 G1 / G1b）。
    static func commitPendingAndSelect(panel: PanelId, mapper: CoordinateMapper, engine: TrainingEngine) {
        let session = engine.drawingSession

        // ① 出口 a（多锚 period 不一致）/ 出口 b（`withStyle` 语义闸拒，如水平线的 `.segment`）。
        //    判据与顺序**一字承接**改动前 `ChartContainerView` 的那道门 —— 本片只是给它补一句
        //    `clearSelection()` 并搬了位置，**不新增、不放宽、不重排任何落库门**（spec §5.1 约束 3）。
        guard let committed = session.commitPending(panelPosition: panel == .upper ? 0 : 1) else {
            session.clearSelection()                       // 变异 M13 守这一句
            return
        }

        // ② 出口 c（射线锚点越主图右缘 → `lineXRange` 返 nil）。承接改动前那道「不可见画线不落库」的门。
        //    ⚠️ 用的是**调用方传进来的 `mapper`**，**不是** `session.viewportMapper(for: panel)`
        //       （spec §5.1 约束 2）：改动前那道门用的就是本次 tap 现算的 mapper；换成 session 里
        //       发布的那一份会在「本面板无 candles」时变成 fail-closed —— 那是对**既有落库门**的
        //       行为改动，不属本片范围。**不得顺手"改进"**。
        guard HorizontalLineTool.visibleGeometry(for: committed, mapper: mapper) != nil else {
            session.clearSelection()                       // 变异 M14 守这一句（= codex spec-R1 那条 high）
            return
        }

        // ⚠️ ① / ② 的 `clearSelection()` 在 D84 复盘门（内层第 ⑤ 步）**之前**，这是有意的
        //    （spec §5.1 约束 1）：那道门管的是复盘**不得获得**选中能力，而「清空」从不授予任何能力
        //    —— 无论哪个模式，一次被拒的提交都不该留下陈旧选中。**不得**把第 ⑤ 步提前去包住 ① / ②。
        routeAndSelect(committed, panel: panel, engine: engine)
    }

    /// **内层**：落库与选中处置（六步流程的 ③④⑤⑥）。**接收一个已经造好的 `DrawingObject`**。
    ///
    /// 这个缝不是为测试硬开的口子，它就是「造对象」与「落库 + 定选中」两件事的自然分界；
    /// 但它顺带让四条变异**可构造**（spec §5.1）—— 外层的 `commitPending` 内部经
    /// `DrawingObject.init` 生成**全新 UUID**，测试无从预知 id，经外层根本写不出 id 碰撞档。
    ///
    /// ⚠️ **六步顺序是 load-bearing 的，一步都不许换位**（每一步的换位后果见各自行内注）。
    /// ⚠️ 生产路径上**只有外层 `commitPendingAndSelect` 一个调用点**（源码守卫 G6）——
    ///    拆内外两层**不得**变成两个生产入口。
    static func routeAndSelect(_ committed: DrawingObject, panel: PanelId, engine: TrainingEngine) {
        // ③ 提交**前**的存在性快照。**必须在 ④ 之前求值**：挪到 ④ 之后恒为 true
        //    → 第 ⑥ 步的合取项 ① 恒假 → 自动选中整体失效（变异 M5c）。
        let wasPresent = engine.drawings.contains { $0.id == committed.id }

        // ④ **无条件**落库：复盘照常落线（浮动铅笔钮，1a-iii 起的既有功能，D26 明写复盘继续用它）。
        engine.routeDrawingCommit(committed)

        // ⑤ D84 复盘门。**只包住「授予选中」这一步**（spec §4.2）：
        //    挪到 ④ 之前 = 复盘的**落线**功能整个回归掉（变异 M2），与 1b-ii 那道 `.segment` 门
        //    误管所有工具是同一类错误 —— fail-closed 的门必须限定到它真适用的那一类。
        //    删掉它 = 复盘获得选中能力，于是能对**已归档 record 里的原训练线**做 🗑 / 🔒 / 改样式
        //    （D34 trust boundary，带 (层, id) 权限门控的复盘选中是 P5，变异 M1）。
        guard engine.flow.mode != .review else { return }

        // ⑥ D83 的判据 = **提交前后两次状态快照的合取**，**绝不读任何返回值**（D64：
        //    `routeDrawingCommit` 返回 `Void`、吞掉 `appendDrawing` 的返回值；而失败原因有五类，
        //    一个 Bool 表达不了）。
        //    合取项 ①（提交前不存在）单独挡 id 碰撞——少了它会选中那条**陈旧的老线**（D37 的陷阱）；
        //    合取项 ②（提交后在**本面板**的可见集合里）单独挡周期不一致 / 几何 nil / revealTick 未到 /
        //    归属判到了另一个面板。
        //    ⚠️ ② 用 **membership**，不用 `count == 1`：与 `syncSelectionByState` 的判据纪律逐字一致
        //    （见其头注「不复用 uniqueSelected」），有了 ① 之后「同 id 出现两条」在本路径上不可达。
        let visible = RenderStateBuilder.visibleDrawings(
            engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
        if !wasPresent && visible.contains(where: { $0.id == committed.id }) {
            engine.drawingSession.setCommittedSelection(id: committed.id, panel: panel)
        } else {
            engine.drawingSession.clearSelection()          // 出口 d / e / f
        }
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

    // MARK: 锁定（1b-ii PR-1，D71）—— 形状镜像上面的删除三件套

    /// 「锁定可用」的**非几何分量**。
    /// ⚠️ 与 `deletableIgnoringGeometry` 只差一处：**没有** `!d.locked` 分量。
    /// 这不是笔误 —— 锁定线**必须仍能被选中并解锁**（spec §7.1 逐字），带上那道门就永远解不开。
    private static func lockableIgnoringGeometry(engine: TrainingEngine) -> Bool {
        guard engine.flow.mode != .review else { return false }
        guard let d = uniqueSelected(engine: engine) else { return false }
        return idIsGloballyUnique(engine: engine, id: d.id)
    }

    /// **路由用**（唯一的门）：几何现算。
    static func canToggleLock(engine: TrainingEngine) -> Bool {
        lockableIgnoringGeometry(engine: engine) && selectionGeometryVisible(engine: engine)
    }

    /// **UI 用**：🔒 是否可用。几何读 observable 提示（理由同 `deleteButtonEnabled`）。
    static func lockButtonEnabled(engine: TrainingEngine) -> Bool {
        lockableIgnoringGeometry(engine: engine) && engine.drawingSession.selectionGeometryVisible
    }

    /// **UI 用**：🔒 图标该显示闭锁还是开锁 —— 只反映选中线的 `locked`，无选中取开锁（中性态）。
    static func lockIsOn(engine: TrainingEngine) -> Bool {
        uniqueSelected(engine: engine)?.locked ?? false
    }

    /// 切换选中线的锁定态。`setDrawingLocked` 在 `Sources/` 里的**唯一**调用点。
    @discardableResult
    static func toggleLockSelected(engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        guard let id = engine.drawingSession.selectedDrawingID,
              let current = uniqueSelected(engine: engine) else { return false }
        guard canToggleLock(engine: engine) else { return false }
        return engine.setDrawingLocked(id: id, locked: !current.locked)
    }
}
