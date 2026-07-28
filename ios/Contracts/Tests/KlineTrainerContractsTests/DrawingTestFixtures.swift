// ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift
@testable import KlineTrainerContracts

// 造一条水平线 DrawingObject,只传关心的字段,其余取默认/固定(isExtended:false, panelPosition:0)。
func makeHLine(id: String = "hl", candleIndex: Int = 3, price: Double = 10,
               period: Period = .daily, thickness: Int = 1, text: String = "") -> DrawingObject {
    DrawingObject(id: id, toolType: .horizontal,
                  anchors: [DrawingAnchor(period: period, candleIndex: candleIndex, price: price)],
                  isExtended: false, panelPosition: 0, period: period, thickness: thickness, text: text)
}

// 追加到 DrawingTestFixtures.swift 末尾
// ⚠️ Swift import 是**文件级**的：本文件现只有 `@testable import KlineTrainerContracts`，
//    `Data` 需要 Foundation、`#expect`/`SourceLocation`/`#_sourceLocation` 需要 Testing → 两行都要加。
import Foundation
import Testing

/// 造一条带完整样式字段的水平线（用于「只动样式」逐字段断言）。
/// ⚠️ `DrawingAnchor.init` 的 label 顺序是 `(period:candleIndex:price:)`（`Models/Models.swift:214` 实测）。
func makeStyledHLine(id: String,
                     lineSubType: LineSubType = .straight, lineStyle: LineStyle = .solid,
                     thickness: Int = 1, colorToken: DrawingColorToken = .orange,
                     labelMode: LabelMode = .hidden, locked: Bool = false,
                     textColorToken: DrawingColorToken = .orange,
                     text: String = "hi", fontSize: Int = 14,
                     period: Period = .daily, candleIndex: Int = 3, price: Double = 10) -> DrawingObject {
    DrawingObject(id: id, toolType: .horizontal,
                  anchors: [DrawingAnchor(period: period, candleIndex: candleIndex, price: price)],
                  isExtended: lineSubType == .ray, panelPosition: 0, revealTick: 7,
                  period: period, lineSubType: lineSubType, lineStyle: lineStyle,
                  thickness: thickness, colorToken: colorToken, labelMode: labelMode,
                  locked: locked, text: text, fontSize: fontSize,
                  textColorToken: textColorToken, textForm: .plain, tailAnchor: nil)
}

/// 造一个携带指定 lossy 集的引擎（D61 未来枚举值门需要 `loadedDrawingsLossy` 非空）。
/// 结构照抄既有 `TrainingEngineInteractionTests.engineWithDrawings`（`:174-186`）：内部 `init` 可
/// 从测试直调（`@testable`），`.m3` 必须覆盖 maxTick（`init` 有 precondition R6-F2）。
@MainActor
func makeEngineWithLossy(_ lossy: LossyDrawingArray) -> TrainingEngine {
    TrainingEngine(
        flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 99),
        allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 100)),
        maxTick: 99, initialCapital: 100_000, initialCashBalance: 100_000,
        initialDrawingsLossy: lossy,                       // init 用它派生 drawings（`:176-178`）
        initialUpperPeriod: .m3, initialLowerPeriod: .m3)
}

/// 从一条 raw JSON 造 lossy 集（未来枚举值 fixture 用）。raw 必须是**单条** drawing 的 JSON 对象。
func lossyFromRaw(_ raw: String) throws -> LossyDrawingArray {
    try LossyDrawingArray.decode(Data("[\(raw)]".utf8))
}

/// 「拒绝 = 零改动」的**统一**断言（codex plan-R4-F2）。
/// ⚠️ `DrawingObject.==` **排除 `id`**（`Models.swift` 的 Equatable 实测）→ 只写 `e.drawings == before`
///   的话，一次「把 id 改写了、其它字段都相同」的坏写入会从**所有** no-op 测试底下溜过去，
///   而 id 恰是本切片 select/update/delete 的身份键、也是 lossy 归并的锚。故必须**同时**比 id 序列。
///   每一处「被拒后不变」都用本助手，不要各写各的（判据单点，也免得漏写 id 那半条）。
@MainActor
func expectDrawingsUnchanged(_ e: TrainingEngine, _ before: [DrawingObject], revisionBefore: Int,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(e.drawings == before, sourceLocation: sourceLocation)
    #expect(e.drawings.map(\.id) == before.map(\.id), "id 序列被改写了", sourceLocation: sourceLocation)
    #expect(e.drawingsRevision == revisionBefore, "拒绝路径不得递增 revision", sourceLocation: sourceLocation)
}
