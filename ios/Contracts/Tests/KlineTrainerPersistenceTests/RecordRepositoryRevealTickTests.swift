import Testing
import Foundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

// 整改④持久化：训练记录画线的 revealTick 经 finalize（insertRecord）→ load（loadRecordBundle）
// 存活。规范化 drawings 表按列重建 DrawingObject，若 reveal_tick 列缺失/未读 → 恒为 0（见 Task 2 brief）。
struct RecordRepositoryRevealTickTests {
    @Test func recordDrawing_revealTick_survivesFinalizeAndLoad() throws {
        let dbURL = try AppDBFixture.makeFreshDB()
        defer { try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent()) }
        let db = try DefaultAppDB(dbPath: dbURL)

        let rec = TrainingRecord(id: nil, trainingSetFilename: "x.sqlite", createdAt: 0,
                                 stockCode: "600001", stockName: "示例", startYear: 2023, startMonth: 11,
                                 totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                                 buyCount: 0, sellCount: 0,
                                 feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                                 finalTick: 100)
        let drawing = DrawingObject(toolType: .horizontal,
                                    anchors: [DrawingAnchor(period: .m3, candleIndex: 3, price: 10)],
                                    isExtended: false, panelPosition: 0, revealTick: 777)

        let id = try db.insertRecord(rec, ops: [], drawings: [drawing])
        let loaded = try db.loadRecordBundle(id: id)

        #expect(loaded.2.count == 1)
        #expect(loaded.2.first?.revealTick == 777)
    }
}
