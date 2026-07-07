import Testing
import Foundation
@testable import KlineTrainerContracts

// codex whole-branch Finding 1 修复：PendingReplay 恢复 Codable（public 契约类型，Task 11 因加
// `lossy: LossyDrawingArray`（非 Codable）误丢——source-compat 破坏）。恢复走显式
// init(from:)/encode(to:)（非 synthesized），CodingKeys 对齐 Task 11 之前的旧字段集（旧快照仍可解
// 码），`drawings` 走计算属性投影往返、decode 侧用 `LossyDrawingArray(drawings:)` 重建已知条
// （纯已知——本路径只是 compat surface；真正字节级保真持久化走 repo 的 `p.lossy.encoded()` 列路径，不受影响）。
@Test func pendingReplay_codableRoundTrip() throws {
    let p = try PendingReplay(
        recordId: 42,
        trainingSetFilename: "a.sqlite", globalTickIndex: 7,
        upperPeriod: .m60, lowerPeriod: .daily,
        positionData: Data([1, 2, 3]), cashBalance: 99_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [DrawingObject(id: "d1", toolType: .horizontal, anchors: [],
                                                       isExtended: false, panelPosition: 0)],
        startedAt: 1_700_000_000, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    let data = try JSONEncoder().encode(p)
    let back = try JSONDecoder().decode(PendingReplay.self, from: data)
    // 逐字段比对（不用整体 `==`：那会连带比较 `lossy` 内部 `raw` 原始字节，那是内部实现细节，
    // JSONEncoder 对同结构体两次独立 encode 不保证 key 顺序一致，非本 compat surface 的契约）。
    #expect(back.recordId == p.recordId)
    #expect(back.trainingSetFilename == p.trainingSetFilename)
    #expect(back.globalTickIndex == p.globalTickIndex)
    #expect(back.positionData == p.positionData)
    #expect(back.cashBalance == p.cashBalance)
    #expect(back.accumulatedCapital == p.accumulatedCapital)
    #expect(back.drawings == p.drawings)                // 内容保留（DrawingObject 自定义 == 不比 id）
    #expect(back.drawings.map(\.id) == ["d1"])           // id 也保留
}

// codex whole-branch R13-medium 修复：整体 `JSONEncoder`/`JSONDecoder` 往返此前只编码计算属性
// `drawings`（已知投影），`.unknownRaw` 未来画线被静默丢弃。新增 `lossyRaw` 顶层 key（`lossy.encoded()`
// 完整字节文本，含 known+unknownRaw、保序）使该往返无损。
@Test func pendingReplay_codableRoundTrip_preservesUnknownRawDrawings() throws {
    let json = Data(#"[{"id":"d1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0},{"toolType":"__future_tool__","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}]"#.utf8)
    let lossy = try LossyDrawingArray.decode(json)
    #expect(lossy.drawings.count == 1)
    #expect(lossy.unknownRaw.count == 1)

    let p = PendingReplay(
        recordId: 42,
        trainingSetFilename: "a.sqlite", globalTickIndex: 7,
        upperPeriod: .m60, lowerPeriod: .daily,
        positionData: Data([1, 2, 3]), cashBalance: 99_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], lossy: lossy,
        startedAt: 1_700_000_000, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    let data = try JSONEncoder().encode(p)
    let decoded = try JSONDecoder().decode(PendingReplay.self, from: data)
    #expect(decoded.drawings.count == 1)                          // 已知条仍在（legacy 投影仍可用）
    #expect(decoded.drawings[0].id == "d1")
    #expect(decoded.lossy.unknownRaw.count == 1)                  // 未来条无损存活（此前会被丢弃）
    #expect(decoded.lossy.unknownRaw[0].contains("__future_tool__"))
}

// 旧快照（Task 11 之前 / 本 fix 之前）只有 `drawings`、无 `lossyRaw` key → 仍可解码，
// 退化为纯已知重建（不 crash，不丢已知条）。
@Test func pendingReplay_codableDecode_oldSnapshotWithoutLossyRaw_fallsBackToKnownOnly() throws {
    let p = try PendingReplay(
        recordId: 42,
        trainingSetFilename: "a.sqlite", globalTickIndex: 7,
        upperPeriod: .m60, lowerPeriod: .daily,
        positionData: Data([1, 2, 3]), cashBalance: 99_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [DrawingObject(id: "d1", toolType: .horizontal, anchors: [],
                                                       isExtended: false, panelPosition: 0)],
        startedAt: 1_700_000_000, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    let data = try JSONEncoder().encode(p)
    var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    obj.removeValue(forKey: "lossyRaw")                           // 模拟旧快照：无此 key
    let oldJSON = try JSONSerialization.data(withJSONObject: obj)
    let decoded = try JSONDecoder().decode(PendingReplay.self, from: oldJSON)
    #expect(decoded.drawings.count == 1)
    #expect(decoded.drawings[0].id == "d1")
    #expect(decoded.lossy.unknownRaw.isEmpty)
}

@Test func inMemoryPendingReplay_saveLoadClear() throws {
    let repo = InMemoryPendingReplayRepository()
    #expect(try repo.loadReplay() == nil)
    let p = try PendingReplay(recordId: 5, trainingSetFilename: "b.sqlite", globalTickIndex: 1,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    #expect(try repo.loadReplay() == p)
    #expect(repo.saveCount == 1)
    try repo.clearReplay()
    #expect(try repo.loadReplay() == nil)
}

// MARK: - A2 coverage: novel methods

@Test func inMemoryPendingReplay_loadSlotInfo_doesNotConsumeFailNextLoadReplay() throws {
    let repo = InMemoryPendingReplayRepository()
    let p = try PendingReplay(recordId: 99, trainingSetFilename: "c.sqlite", globalTickIndex: 3,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    repo.failNextLoadReplay = .persistence(.dbCorrupted)
    // loadReplaySlotInfo must NOT consume failNextLoadReplay and must succeed
    let slot = try repo.loadReplaySlotInfo()
    #expect(slot?.recordId == 99)
    #expect(slot?.trainingSetFilename == "c.sqlite")
    // failNextLoadReplay is still armed — loadReplay must throw
    #expect(throws: AppError.self) { try repo.loadReplay() }
}

@Test func inMemoryPendingReplay_clearReplayIfRecordId_matching_clears() throws {
    let repo = InMemoryPendingReplayRepository()
    let p = try PendingReplay(recordId: 7, trainingSetFilename: "d.sqlite", globalTickIndex: 0,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    try repo.clearReplay(ifRecordId: 7)
    #expect(try repo.loadReplay() == nil)
}

@Test func inMemoryPendingReplay_clearReplayIfRecordId_nonMatching_keeps() throws {
    let repo = InMemoryPendingReplayRepository()
    let p = try PendingReplay(recordId: 7, trainingSetFilename: "d.sqlite", globalTickIndex: 0,
        upperPeriod: .m60, lowerPeriod: .daily, positionData: Data(), cashBalance: 100_000,
        feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
        tradeOperations: [], drawings: [], startedAt: 1, accumulatedCapital: 100_000,
        drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0))
    try repo.saveReplay(p)
    try repo.clearReplay(ifRecordId: 999)   // mismatched recordId — slot must be retained
    #expect(try repo.loadReplaySlotInfo()?.recordId == 7)
}
