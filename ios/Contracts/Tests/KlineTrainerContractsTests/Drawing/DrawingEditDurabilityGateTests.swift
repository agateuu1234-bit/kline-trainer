// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift
// Spec: 2026-07-23-...-1b-i-select-edit-delete-design.md D60（locked）/ D61（未来未知枚举值）。
// 两道门都是**跨版本耐久性**保护：本构建产不出 locked=true、也产不出未来枚举值，
// 它们只可能从**高版本写的磁盘数据**解码进来 —— 编辑它们会不可逆地抹掉原始字节。
import Foundation
import Testing
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
    /// ⚠️⚠️ **交接给 1b-ii**：落地 `setDrawingLocked(id:locked:)` 时，这条线一旦被解锁，
    /// `deleteDrawing(id:)` 就该对它放行（未来数据那道门本就不归删除面管）——**本测试「delete == false」
    /// 那半条断言必须翻转成 true**，否则说明 `setDrawingLocked` 没把 `locked` 门在下游落到实处。
    @Test("N14h 已知死角（不修，钉现状）: locked + 未来数据的线 —— 今天既改不动也删不掉，finalize 门仍会命中")
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
    }
}
