// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift
// Spec: 2026-07-23-...-1b-i-select-edit-delete-design.md D60（locked）/ D61（未来未知枚举值）。
// 两道门都是**跨版本耐久性**保护：本构建产不出 locked=true、也产不出未来枚举值，
// 它们只可能从**高版本写的磁盘数据**解码进来 —— 编辑它们会不可逆地抹掉原始字节。
import Foundation
import Testing
import CoreGraphics        // ← 新增：L8 的 CGRect / CGPoint
@testable import KlineTrainerContracts

@Suite("1b-i 切片2：编辑写入面的耐久性门（locked / 未来未知枚举值）")
@MainActor
struct DrawingEditDurabilityGateTests {

    private func style(_ th: Int = 3, _ c: DrawingColorToken = .green) -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.thickness = th; s.colorToken = c
        return s
    }

    /// 一条**携带两个不同未来枚举值**的高版本线：colorToken/textColorToken 双双 fallback 成 .orange，
    /// 故「解码后 == 比较」区分不了它们 —— 这正是 D61 必须 raw-aware 的理由（codex R7-F2）。
    private let futureRaw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"futureCyan","textForm":"plain"}"#

    /// 一条**当前版本普通线**（所有枚举字段都是已知值 → knownFutureEnumPayloads 该条 entries 为空）。
    private let plainRaw = #"{"id":"K","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#

    // MARK: D60 locked

    @Test("N13a: locked 线改样式被拒 —— 逐字段不变、revision 不递增")
    func lockedRejectsStyleEdit() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "L", thickness: 1, locked: true)) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "L", style: style()) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N13c 反向对照: 同一条线 locked == false 时改样式成功、revision +1（防「一律拒绝」骗过 N13a）")
    func unlockedAcceptsStyleEdit() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "U", thickness: 1, locked: false)) == true)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "U", style: style(4, .green)) == true)
        #expect(e.drawings.first { $0.id == "U" }?.thickness == 4)
        #expect(e.drawingsRevision == rev + 1)
    }

    // MARK: D61 未来未知枚举值

    @Test("N14a: 携带未来未知枚举值的线 → **任一**样式改动都 fail-closed（逐字段不变、revision 不递增）")
    func futureEnumLineRejectsStyleEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(futureRaw))
        #expect(e.drawings.count == 1)
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["F"]) == true)   // 前提成立
        let before = e.drawings
        let rev = e.drawingsRevision
        // 改粗细 / 改线色 / 改线型 —— 一律拒（spec D61 原文语义）
        var th = DrawingDefaultStyle(); th.thickness = 5
        #expect(e.updateDrawingStyle(id: "F", style: th) == false)
        #expect(e.updateDrawingStyle(id: "F", style: style(1, .green)) == false)
        var ls = DrawingDefaultStyle(); ls.lineStyle = .dash1
        #expect(e.updateDrawingStyle(id: "F", style: ls) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N14b 核心: 编辑被拒后原始字节保真 —— futureNeon / futureCyan 逐字节仍在")
    func futureEnumRawBytesSurviveRejectedEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(futureRaw))
        #expect(e.updateDrawingStyle(id: "F", style: style(5, .green)) == false)
        // 走真实持久化路径（coordinator 存盘用的正是 reconciled(currentKnown:).encoded()）
        let data = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("futureNeon"))       // 线色的未来值没被 fallback(.orange) 覆盖
        #expect(text.contains("futureCyan"))       // 字色的未来值同样保住（两个不同 future 值不得被抹平）
    }

    @Test("N14e 反向对照: 本构建新建的线（无 unknown 枚举）改线色成功且字色跟随")
    func currentVersionLineStillEditable() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "N", colorToken: .orange, textColorToken: .orange)) == true)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "N", style: style(2, .green)) == true)
        let now = try #require(e.drawings.first { $0.id == "N" })
        #expect(now.colorToken == .green)
        #expect(now.textColorToken == .green)                 // 派生② 条件成立 → 跟随
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("未来**顶层字段**同样 fail-closed（codex plan-R13-F1）：它能改变已知 key 的含义")
    func futureTopLevelFieldRejectsStyleEdit() throws {
        // `futureIndependentTextColor` 是本构建不认识的顶层 key：`hasKnownFutureEnumValues` 看不见它
        //（所有枚举值都是当前 case），只有 `hasKnownFutureFields` 抓得到。
        // 若不并这道门：解码出的 textColorToken == colorToken → 派生② 判"跟随"→ 覆盖字色，
        // 而那个未来字段原样留着 → 落一份自相矛盾的高版本数据。
        let raw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureIndependentTextColor":true}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["X"]) == false)  // 枚举门看不见
        #expect(e.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == true)       // 字段门抓得到
        let before = e.drawings
        let rev = e.drawingsRevision
        // ⚠️ 与未来**枚举值**不同：未来**字段**是本构建根本不认识的 key，**没有任何样式控件能覆盖它**
        //    → 与未来枚举值同样命中 D61 的门 → 任何样式编辑都被拒；它只能靠删除解封。
        #expect(e.updateDrawingStyle(id: "X", style: style(4, .green)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        // 原始字节保真：未来字段仍在
        let data = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings).encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("futureIndependentTextColor"))
    }

    @Test("N14f 判据陷阱专项: 存盘→重载的**普通**线仍可编辑（漏 !entries.isEmpty 会全灰，当场红）")
    func reloadedPlainLineStillEditable() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(plainRaw))
        #expect(e.drawings.count == 1)
        // 前提：该条 payload 存在但 entries 为空 → 判据必须判「不命中」
        #expect(e.loadedDrawingsLossy.knownFutureEnumPayloads().contains { $0.id == "K" })
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["K"]) == false)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "K", style: style(4, .green)) == true)
        #expect(e.drawings.first { $0.id == "K" }?.thickness == 4)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("工具门端到端（codex plan-R11-F1）：未实现的已知工具线 —— 进得来、但改样式被拒")
    func unimplementedToolLineIsPreservedNotEditable() throws {
        let e = TrainingEngine.preview()
        // 一条 `.trend` 线（已知枚举、无未来枚举值 → D61 门不命中）；经 append 进来是**合法**的
        let trend = DrawingObject(id: "T", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                  isExtended: false, panelPosition: 0, period: .daily)
        #expect(e.appendDrawing(trend) == true)              // 进来宽松（PR-1 行为，不得回归）
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "T", style: style(4, .green)) == false)   // 改写保守
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        // ⚠️ 「仍可整条删」那半条在 **Task 5**（`deleteDrawing(id:)` 到那时才存在；本 Task 是纯测试
        //    Task，写在这里会编译不过 —— codex plan-R12-F1）。
    }

    @Test("N14g: known 独立字色不得被无条件派生抹掉（orange 线 + blue 标签）")
    func knownIndependentTextColorPreserved() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "I", thickness: 1,
                                                colorToken: .orange, textColorToken: .blue)) == true)
        // 只改 thickness → 字色仍 .blue
        var s = DrawingDefaultStyle(); s.thickness = 4; s.colorToken = .orange
        #expect(e.updateDrawingStyle(id: "I", style: s) == true)
        #expect(e.drawings.first { $0.id == "I" }?.textColorToken == .blue)
        // 改线色成 .green → 字色**仍** .blue（改线色也不夺 known 独立字色）
        #expect(e.updateDrawingStyle(id: "I", style: style(4, .green)) == true)
        let now = try #require(e.drawings.first { $0.id == "I" })
        #expect(now.colorToken == .green)
        #expect(now.textColorToken == .blue)
    }

    // MARK: 已知死角（不修，钉现状）—— locked + 未来数据 = 既改不动也删不掉

    /// ⚠️ 本测试钉的是**已知死角的当前行为**，不是期望的最终行为（user 2026-07-27 裁决）。
    ///
    /// 死角形状：一条线同时 `locked == true` 且携带本构建不认识的未来数据（未来顶层字段 / 已知 key
    /// 的未来枚举值）——`updateDrawingStyle` 因门②(locked) 拒它，`deleteDrawing(id:)` 同样因门②(locked)
    /// 拒它（删除面不查未来数据那道门，但 locked 门两边都查）。而 `TrainingSessionCoordinator` 的
    /// finalize 判据（`:733-736`）对存活线有未来字段/未来枚举值一律 `throw .dbCorrupted`。
    /// 合起来 = 这一局既清不掉这条线、也归不了档。
    ///
    /// 本 PR 不修，理由（精炼版，详见 PR 描述）：
    /// 1. 本构建**产不出** `locked == true`（`Sources/` 里没有任何地方写 `DrawingObject.locked = true`；
    ///    `GestureClassifiers` 的 `st.locked` 是双指手势状态机字段，与本模型无关）——只能从更高版本解码进来。
    /// 2. `updateDrawingStyle`/`deleteDrawing` 目前在 `Sources/` 中**零调用点**（UI 路由属 PR-4）——今天
    ///    用户不可达。
    /// 3. **不是本 PR 引入**：main（`f3f67da`）上只有零调用点的 `deleteDrawing(at:)`，那时这类线同样清不掉。
    /// 4. spec 已把解药派给 **1b-ii**：`setDrawingLocked(id:locked:)` 是唯一被允许改 `locked` 的入口
    ///    （spec `:757`），且必须做 **raw-preserving 单字段 merge**（只改 `locked` 一个 key、其余从旧 raw
    ///    逐字保留），不能照抄本期「整条拒绝」的形状。
    ///
    /// N14h（1b-ii PR-1 已解开一半）：locked + 未来数据的线。
    /// **锁着时**仍然既改不动（门②）也删不掉（门②）——这部分不变。
    /// **但 `setDrawingLocked` 落地后它可以被解锁**，解锁之后 `deleteDrawing(id:)` 必须放行
    /// （未来数据那道门本就不归删除面管）→ 用户对这类线的处置通道从此存在。
    /// ⚠️ **仍然残留**：解锁后它依旧**改不动样式**（D61 门保留在 `updateDrawingStyle` 上）。
    ///    这是保护而非缺陷，P3/未来版本认识那些枚举值后自然解禁。
    @Test("N14h: locked + 未来数据的线 —— 锁着时改不动删不掉，解锁后可删除")
    func lockedFutureDataLineIsCurrentlyUnrecoverable() throws {
        // 分量一：locked + 未来**顶层字段**（`futureX`，本构建不认识这个 key）
        let lockedFutureFieldRaw = #"{"id":"LA","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":true,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureX":9}"#
        let eA = makeEngineWithLossy(try lossyFromRaw(lockedFutureFieldRaw))
        #expect(eA.drawings.count == 1)
        let beforeA = eA.drawings
        let revA = eA.drawingsRevision
        #expect(eA.updateDrawingStyle(id: "LA", style: style()) == false)      // 门②(locked) 挡编辑
        expectDrawingsUnchanged(eA, beforeA, revisionBefore: revA)
        #expect(eA.deleteDrawing(id: "LA") == false)                          // 门②(locked) 同样挡删除
        #expect(eA.drawings.contains { $0.id == "LA" })                       // 线仍在
        #expect(eA.drawingsRevision == revA)                                  // revision 未动
        // finalize 判据仍会命中：这一局会被 finalize 门 fail-closed 拦下（`TrainingSessionCoordinator:733-736`）
        let reconciledA = try eA.loadedDrawingsLossy.reconciled(currentKnown: eA.drawings)
        #expect(reconciledA.hasKnownFutureFields(liveIds: Set(eA.drawings.map(\.id))) == true)
        // 1b-ii PR-1：解锁 → 删除必须放行（1b-i 头注逐字交接的翻转点）
        #expect(eA.setDrawingLocked(id: "LA", locked: false) == true)
        #expect(eA.drawings.first(where: { $0.id == "LA" })?.locked == false)
        let revAfterUnlockA = eA.drawingsRevision
        #expect(eA.deleteDrawing(id: "LA") == true)                    // ← 由 false 翻转为 true
        #expect(!eA.drawings.contains { $0.id == "LA" })               // 线真的没了
        #expect(eA.drawingsRevision == revAfterUnlockA + 1)
        // 残留仍在：解锁不解禁样式编辑（D61 门还在 updateDrawingStyle 上）

        // 分量二：locked + 已知 key 的未来**枚举值**（`colorToken:"futureNeon"`）
        let lockedFutureEnumRaw = #"{"id":"LB","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":true,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
        let eB = makeEngineWithLossy(try lossyFromRaw(lockedFutureEnumRaw))
        #expect(eB.drawings.count == 1)
        let beforeB = eB.drawings
        let revB = eB.drawingsRevision
        #expect(eB.updateDrawingStyle(id: "LB", style: style()) == false)      // 门②(locked) 挡编辑
        expectDrawingsUnchanged(eB, beforeB, revisionBefore: revB)
        #expect(eB.deleteDrawing(id: "LB") == false)                          // 门②(locked) 同样挡删除
        #expect(eB.drawings.contains { $0.id == "LB" })                       // 线仍在
        #expect(eB.drawingsRevision == revB)                                  // revision 未动
        let reconciledB = try eB.loadedDrawingsLossy.reconciled(currentKnown: eB.drawings)
        #expect(reconciledB.hasKnownFutureEnumValues(liveIds: Set(eB.drawings.map(\.id))) == true)
        // 1b-ii PR-1：解锁 → 删除必须放行（同上，分量二）
        #expect(eB.setDrawingLocked(id: "LB", locked: false) == true)
        // 残留：解锁后仍改不动样式（D61 门仍拒）—— 必须在删除之前断言，删了就没得改了
        #expect(eB.updateDrawingStyle(id: "LB", style: style()) == false)
        #expect(eB.deleteDrawing(id: "LB") == true)
        #expect(!eB.drawings.contains { $0.id == "LB" })
    }

    // MARK: D70 raw-preserving 举证（1b-ii PR-1 Task 2）——「机制已存在」这条设计假设的证据

    /// D70 举证（1b-ii PR-1 Task 2）：只改 `locked` 时，其余原始字节必须逐字保留。
    /// 机制来自 P1a：`reconciled` 见 `cur != old` → 走 `mergeKnownFields` → 只覆盖**真变化**的 key。
    @Test("L6 raw-preserving: 锁定带未来顶层字段的线 → futureX 仍在、locked 已变 true")
    @MainActor func lockPreservesFutureTopLevelField() throws {
        let raw = #"{"id":"P1","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureX":9}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.setDrawingLocked(id: "P1", locked: true))
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        let out = String(decoding: try merged.encoded(), as: UTF8.self)
        #expect(out.contains("\"futureX\":9"), "未来顶层字段被抹掉了：\(out)")
        #expect(out.contains("\"locked\":true"), "locked 没写进去：\(out)")
    }

    @Test("L7 raw-preserving: 锁定带未来枚举值的线 → futureNeon 仍在、locked 已变 true")
    @MainActor func lockPreservesFutureEnumValue() throws {
        let raw = #"{"id":"P2","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.setDrawingLocked(id: "P2", locked: true))
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        let out = String(decoding: try merged.encoded(), as: UTF8.self)
        #expect(out.contains("\"colorToken\":\"futureNeon\""), "未来枚举值被 fallback 覆盖了：\(out)")
        #expect(out.contains("\"locked\":true"), "locked 没写进去：\(out)")
    }

    @Test("L13a 落盘(内存层): 锁定 → revision +1 → merge/encode/decode 往返后仍是锁定态")
    @MainActor func lockedSurvivesLossyRoundTrip() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeHorizontalDrawing(id: "S1")))
        let rev = e.drawingsRevision
        #expect(e.setDrawingLocked(id: "S1", locked: true))
        #expect(e.drawingsRevision == rev + 1)
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        let reloaded = try LossyDrawingArray.decode(try merged.encoded())
        #expect(reloaded.drawings.first(where: { $0.id == "S1" })?.locked == true)
    }

    /// 契约举证（spec §3 第 3 条第 ① 分量）：非水平线在本构建**选不中** ⇒ 路由够不着 ⇒ 用户锁不了它。
    @Test("L8 契约: .trend 线不出现在命中结果里（无渲染器 ⇒ 选不中）")
    @MainActor func futureToolTypeIsNotHittable() throws {
        let trend = DrawingObject(
            id: "T1", toolType: .trend,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.0),
                      DrawingAnchor(period: .m3, candleIndex: 5, price: 12.0)],
            isExtended: false, panelPosition: 0, revealTick: 0, period: .m3,
            lineSubType: .straight, lineStyle: .solid, thickness: 1, colorToken: .orange,
            labelMode: .hidden, locked: false, text: "", fontSize: 14,
            textColorToken: .orange, textForm: .plain, tailAnchor: nil)
        // mapper：主图 y ∈ [0,100]、价格区间 [0,100]（与 DrawingEditRouterTests:15-22 同款，已实测可编译）
        let mapper = CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: 0, max: 100),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
        // ⚠️ **注册表显式传入，不用 `KLineView.drawingTools`** —— `KLineView` 是 UIKit-gated，
        //    host `swift test` 上根本不编译（codex P-R4-F1）。本条证明的是判据本身：
        //    「注册表里没有的工具 ⇒ 不命中」。「生产注册表里确实没有 `.trend`」由 L8c 在 Catalyst 上证。
        let hit = DrawingHitTester.firstHit(
            in: [trend], point: CGPoint(x: 10, y: 10),
            mapper: mapper, tools: [.horizontal: HorizontalLineTool()])
        #expect(hit == nil, "注册表里没有 .trend 的渲染器，却命中了 —— 契约论点 ① 不成立")
        // 同一判据的正向档：同样的点、同样的注册表，一条**水平线**必须命中
        // （否则「返回 nil」可能只是因为几何/点位不对，与注册表无关 → 本测试就没有判别力）
        let hline = makeHorizontalDrawing(id: "H1", price: 50)
        #expect(DrawingHitTester.firstHit(in: [hline], point: CGPoint(x: 10, y: 50),
                                          mapper: mapper,
                                          tools: [.horizontal: HorizontalLineTool()]) != nil,
                "正向档失败 —— 说明 nil 不是因为「注册表里没有」，本测试无判别力")
    }

    /// L8b 契约分量②（codex P-R1-F3）：**即便绕过路由直调引擎**，保存后 `toolType` 与全部未来字节
    /// 逐字不变、**只有 `locked` 变了**。
    /// L8 只证明了「UI 够不着」，本条证明「够着了也无损」—— spec §3 第 3 条要求**两条都有**，
    /// 只写一条等于把结论建在没测过的那一半上。
    @Test("L8b 契约: .trend + 未来字段的线直调 setDrawingLocked → toolType 与未来字节逐字不变")
    @MainActor func lockOnFutureToolPreservesEverythingElse() throws {
        let raw = #"{"id":"T2","toolType":"trend","anchors":[{"period":"3m","candleIndex":1,"price":9.0},{"period":"3m","candleIndex":5,"price":12.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureY":42}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.drawings.first?.toolType == .trend, "`.trend` 是已声明 case，应解码成 .known")
        #expect(e.setDrawingLocked(id: "T2", locked: true) == true,
                "引擎侧不带工具门（D69 ②b）—— 这里就是要证明它够得着也无损")
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        let out = String(decoding: try merged.encoded(), as: UTF8.self)
        #expect(out.contains("\"toolType\":\"trend\""), "toolType 被改写了：\(out)")
        #expect(out.contains("\"futureY\":42"), "未来字段被抹掉了：\(out)")
        #expect(out.contains("\"locked\":true"), "locked 没写进去：\(out)")
        // ★「**只有** locked 变了」必须是真判据，不能靠几条 contains 凑：
        //   把两边的 `locked` 都摘掉再逐字节比 —— 剩下的必须完全相同。
        func strippingLocked(_ json: String) throws -> Data {
            var d = try #require(
                (try JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
            d.removeValue(forKey: "locked")
            return try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
        }
        let elem = try #require(JSONTopLevelArray.rawElementStrings(try merged.encoded())?.first)
        #expect(try strippingLocked(elem) == (try strippingLocked(raw)),
                "除 locked 外还有字段被改动了。产物：\(elem)")
    }
}
