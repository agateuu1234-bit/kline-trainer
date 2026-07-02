import Testing
import Foundation
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

// Test-only helpers（review-redesign Task 2）：DefaultAppDB 跑真 FK（PRAGMA foreign_keys = ON），
// review_archive.record_id REFERENCES training_records(id) ON DELETE CASCADE —— 测试须先插一条
// 最小合法 training_records 行才能写 review_archive。`rawWrite` 供注入损坏数据（独立解码测试）。
extension DefaultAppDB {
    func insertMinimalRecord(id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO training_records
                  (id, training_set_filename, created_at, stock_code, stock_name,
                   start_year, start_month, total_capital, profit, return_rate,
                   max_drawdown, buy_count, sell_count, fee_snapshot, final_tick)
                VALUES (?, 'test.sqlite', 0, 'SH000001', 'Test', 2024, 1, 100000, 0, 0, 0, 0, 0,
                        '{"commissionRate":0.0001,"minCommissionEnabled":true}', 0)
                """, arguments: [id])
        }
    }

    func rawWrite(_ sql: String) throws {
        try dbQueue.write { try $0.execute(sql: sql) }
    }
}

@Suite struct ReviewArchiveRepositoryTests {
    // final-review T2：返回 url 供调用方 defer 清理 tmp 目录（mirror CoordinatorCapitalIntegrationTests.makeFreshDB）。
    private func makeDB() throws -> (url: URL, db: DefaultAppDB) {
        let url = try AppDBFixture.makeFreshDB()
        let db = try DefaultAppDB(dbPath: url)
        try db.insertMinimalRecord(id: 1)
        return (url, db)
    }
    private func line(_ tick: Int) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: tick, price: 10)],
                      isExtended: false, panelPosition: 0)
    }

    @Test func emptyIsNone() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try db.loadArchive(recordId: 1) == nil)
        #expect(try db.reviewMarker(recordId: 1) == .none)
    }

    @Test func saveWorkingThenInProgress() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.saveWorking(recordId: 1, stepTick: 42, drawings: [line(5)])
        let a = try #require(try db.loadArchive(recordId: 1))
        #expect(a.workingStepTick == 42)
        #expect(a.workingDrawings == [line(5)])
        #expect(a.savedDrawings == nil)
        #expect(try db.reviewMarker(recordId: 1) == .inProgress)
    }

    @Test func commitSavedClearsWorkingAndMarksSaved() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.saveWorking(recordId: 1, stepTick: 42, drawings: [line(5)])
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        let a = try #require(try db.loadArchive(recordId: 1))
        #expect(a.savedDrawings == [line(5)])
        #expect(a.workingStepTick == nil)
        #expect(a.workingDrawings == nil)
        #expect(try db.reviewMarker(recordId: 1) == .saved)
    }

    @Test func clearWorkingKeepsSavedElseDeletesRow() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // 有 saved：清 working 回退 saved
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        try db.saveWorking(recordId: 1, stepTick: 9, drawings: [line(5), line(7)])
        try db.clearWorking(recordId: 1)
        #expect(try db.reviewMarker(recordId: 1) == .saved)
        // 无 saved：清 working 删行
        try db.insertMinimalRecord(id: 2)
        try db.saveWorking(recordId: 2, stepTick: 3, drawings: [line(3)])
        try db.clearWorking(recordId: 2)
        #expect(try db.loadArchive(recordId: 2) == nil)
        #expect(try db.reviewMarker(recordId: 2) == .none)
    }

    @Test func inProgressTakesMarkerPrecedenceOverSaved() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        try db.saveWorking(recordId: 1, stepTick: 9, drawings: [line(5), line(7)])
        #expect(try db.reviewMarker(recordId: 1) == .inProgress)   // working 非空优先
    }

    @Test func loadMarkersBatch() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.insertMinimalRecord(id: 2); try db.insertMinimalRecord(id: 3)
        try db.commitSaved(recordId: 1, drawings: [line(5)])       // saved
        try db.saveWorking(recordId: 2, stepTick: 1, drawings: [line(1)])  // inProgress
        // 3 无行
        let m = try db.loadMarkers()
        #expect(m[1] == .saved); #expect(m[2] == .inProgress); #expect(m[3] == nil)
    }

    @Test func clearSavedForCorruptRecovery() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.commitSaved(recordId: 1, drawings: [line(5)])
        try db.clearSaved(recordId: 1)
        #expect(try db.reviewMarker(recordId: 1) == .none)         // 无 working 亦无 saved → 删行
    }

    // codex plan-R1-high：saved 损坏不得害有效 working（独立解码）
    @Test func savedCorruptionDoesNotBreakLoadWorking() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.commitSaved(recordId: 1, drawings: [line(2)])       // 先有 saved
        try db.saveWorking(recordId: 1, stepTick: 7, drawings: [line(7)])  // 再有 working
        try db.rawWrite("UPDATE review_archive SET saved_drawings = 'not-json' WHERE record_id = 1")  // 注入坏 saved
        let w = try #require(try db.loadWorking(recordId: 1))
        #expect(w.stepTick == 7 && w.drawings == [line(7)])        // working 完好可读
        #expect(throws: AppError.self) { _ = try db.loadSaved(recordId: 1) }  // 仅 saved 报 dbCorrupted
    }

    // final-review T6：working 损坏不得害有效 saved（独立解码），对称于上一条 savedCorruptionDoesNotBreakLoadWorking。
    @Test func workingCorruptionDoesNotBreakLoadSaved() throws {
        let (url, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.commitSaved(recordId: 1, drawings: [line(2)])       // 先有 saved
        try db.saveWorking(recordId: 1, stepTick: 7, drawings: [line(7)])  // 再有 working
        try db.rawWrite("UPDATE review_archive SET working_drawings = 'not-json' WHERE record_id = 1")  // 注入坏 working
        #expect(throws: AppError.self) { _ = try db.loadWorking(recordId: 1) }  // 仅 working 报 dbCorrupted
        let saved = try #require(try db.loadSaved(recordId: 1))
        #expect(saved == [line(2)])                                // saved 完好可读
    }
}
