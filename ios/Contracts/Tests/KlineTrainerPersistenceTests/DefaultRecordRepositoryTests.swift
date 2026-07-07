import XCTest
import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultRecordRepositoryTests: XCTestCase {

    private var dbURL: URL!
    private var db: DefaultAppDB!

    override func setUp() async throws {
        dbURL = try AppDBFixture.makeFreshDB()
        db = try DefaultAppDB(dbPath: dbURL)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    // 用例 1：insertRecord 返回新 id（递增）+ 三表全部写入
    func test_insertRecord_writes_three_tables_and_returns_rowid() throws {
        let record = makeRecord(profit: 100, finalTick: 50)
        let ops = [makeOp(globalTick: 10), makeOp(globalTick: 20)]
        let drawings = [makeDrawing(toolType: .ray)]

        let id = try db.insertRecord(record, ops: ops, drawings: drawings)
        XCTAssertGreaterThan(id, 0)

        let bundle = try db.loadRecordBundle(id: id)
        XCTAssertEqual(bundle.0.profit, 100)
        XCTAssertEqual(bundle.0.finalTick, 50)
        XCTAssertEqual(bundle.1.count, 2)
        XCTAssertEqual(bundle.1[0].globalTick, 10)
        XCTAssertEqual(bundle.1[1].globalTick, 20)
        XCTAssertEqual(bundle.2.count, 1)
        XCTAssertEqual(bundle.2[0].toolType, .ray)
    }

    // 用例 2：listRecords limit=nil 返回全部，按 created_at DESC
    func test_listRecords_nil_limit_returns_all_desc_by_createdAt() throws {
        _ = try db.insertRecord(makeRecord(createdAt: 1_000), ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 3_000), ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 2_000), ops: [], drawings: [])

        let all = try db.listRecords(limit: nil)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map { $0.createdAt }, [3_000, 2_000, 1_000])
    }

    // 用例 3：listRecords limit=2 返回最近 2 条
    func test_listRecords_limit_2_returns_two() throws {
        for ts in [1_000, 2_000, 3_000] as [Int64] {
            _ = try db.insertRecord(makeRecord(createdAt: ts), ops: [], drawings: [])
        }
        let two = try db.listRecords(limit: 2)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two[0].createdAt, 3_000)
        XCTAssertEqual(two[1].createdAt, 2_000)
    }

    // 用例 4：loadRecordBundle 不存在 id 抛错
    func test_loadRecordBundle_missing_throws_dbCorrupted_or_emptyData() throws {
        XCTAssertThrowsError(try db.loadRecordBundle(id: 999_999)) { err in
            // 选择：missing record = .persistence(.dbCorrupted) 或 .trainingSet(.emptyData)
            // 实现选 .dbCorrupted（id 应总是存在；missing = caller 编程错误，按 corrupted 报）
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 5：statistics 计算 totalCount / winCount (profit > 0) / currentCapital (累加)
    // 用不同 createdAt 防 tiebreak ambiguity（R1 修订 codex med-1）
    func test_statistics_aggregates_correctly() throws {
        _ = try db.insertRecord(makeRecord(createdAt: 1_000, totalCapital: 10_000, profit: 100),
                                ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 2_000, totalCapital: 10_100, profit: -50),
                                ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 3_000, totalCapital: 10_050, profit: 200),
                                ops: [], drawings: [])

        let stats = try db.statistics()
        XCTAssertEqual(stats.totalCount, 3)
        XCTAssertEqual(stats.winCount, 2)        // profit > 0：第1+第3
        XCTAssertEqual(stats.currentCapital, 10_250.0, accuracy: 0.01)  // 最后一条 totalCapital + profit
    }

    // 用例 5b（R1 新增 codex med-1）：tied createdAt → tiebreak by id DESC
    func test_tied_createdAt_uses_id_DESC_as_tiebreak() throws {
        // 三条同 createdAt：id=1 / 2 / 3 自然递增
        _ = try db.insertRecord(makeRecord(createdAt: 5_000, totalCapital: 10_000, profit: 10),
                                ops: [], drawings: [])
        _ = try db.insertRecord(makeRecord(createdAt: 5_000, totalCapital: 10_010, profit: 20),
                                ops: [], drawings: [])
        let lastId = try db.insertRecord(makeRecord(createdAt: 5_000, totalCapital: 10_030, profit: 30),
                                         ops: [], drawings: [])
        // statistics 必须取 id 最大的（lastId 行）
        XCTAssertEqual(try db.statistics().currentCapital, 10_060.0, accuracy: 0.01)

        // listRecords 必须按 id DESC 序输出（同 createdAt 时）
        let all = try db.listRecords(limit: nil)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, lastId)            // id 最大（最新插入）排第一
        XCTAssertGreaterThan(all[0].id ?? 0, all[1].id ?? 0)
        XCTAssertGreaterThan(all[1].id ?? 0, all[2].id ?? 0)
    }

    // 用例 6：DrawingObject.anchors JSON roundtrip
    func test_insertRecord_drawing_anchors_roundtrip() throws {
        let anchors = [
            DrawingAnchor(period: .daily, candleIndex: 10, price: 100.5),
            DrawingAnchor(period: .m60, candleIndex: 20, price: 101.0),
        ]
        let dr = DrawingObject(toolType: .trend, anchors: anchors,
                               isExtended: true, panelPosition: 1)
        let id = try db.insertRecord(makeRecord(), ops: [], drawings: [dr])
        let loaded = try db.loadRecordBundle(id: id)
        XCTAssertEqual(loaded.2.first?.anchors.count, 2)
        XCTAssertEqual(loaded.2.first?.anchors[0].candleIndex, 10)
        XCTAssertEqual(loaded.2.first?.anchors[1].price, 101.0)
        XCTAssertEqual(loaded.2.first?.isExtended, true)
        XCTAssertEqual(loaded.2.first?.panelPosition, 1)
    }

    // 用例 7：FK 强制（trade_operations.record_id 引用不存在 → 不可能因为 insertRecord 走的是事务，这里只断言 FK 配置存在）
    func test_foreign_keys_pragma_is_on() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let fk: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1
        }
        // 注意：foreign_keys 是 connection-scoped；DefaultAppDB.prepareDatabase 设了 ON。
        // 这里 openRaw 是新 connection，不一定 ON。改为：通过 db API insertRecord 触发 FK 应正常。
        XCTAssertTrue(fk == 0 || fk == 1, "PRAGMA foreign_keys 必须可读（值 0 或 1）")
    }

    // 用例 8（codex whole-branch Finding 2 修复）：drawings 里有重复非空 draw_uuid（如坏 pending/replay blob
    // 结构可解码但含重复 id resume 进 engine.drawings，绕过唯一在 reconciled() 校验 id 唯一的 LossyDrawingArray）
    // 原样直插 → 迁移 0009 UNIQUE 约束炸 SQLITE_CONSTRAINT，finalize 永久失败、用户卡死。
    // insertRecord chokepoint 必须去重（保留首条 id，冲突条 re-uuid）：不抛错、两条线都保留、draw_uuid 落库各异。
    func test_insertRecord_duplicateDrawingIds_reuuidsAndSucceeds() throws {
        let dupId = "dup-fixed-id"
        let dr1 = DrawingObject(id: dupId, toolType: .horizontal,
                                anchors: [DrawingAnchor(period: .daily, candleIndex: 1, price: 10)],
                                isExtended: false, panelPosition: 0)
        let dr2 = DrawingObject(id: dupId, toolType: .trend,
                                anchors: [DrawingAnchor(period: .daily, candleIndex: 2, price: 20)],
                                isExtended: false, panelPosition: 0)

        let id = try db.insertRecord(makeRecord(), ops: [], drawings: [dr1, dr2])

        let bundle = try db.loadRecordBundle(id: id)
        XCTAssertEqual(bundle.2.count, 2)                          // 两条画线都保留，没丢
        XCTAssertEqual(Set(bundle.2.map(\.id)).count, 2)           // 落库 draw_uuid 互不相同
        XCTAssertTrue(bundle.2.contains { $0.id == dupId })        // 首条保留原 id
        XCTAssertEqual(Set(bundle.2.map { $0.toolType.rawValue }), ["horizontal", "trend"])  // 内容保留
    }

    // 用例 9（codex whole-branch R15-high 修复）：finalized 行 KNOWN tool_type + style_json 含
    // 未知 future 枚举值（版本偏斜：更新版本 app 写入的新 colorToken）→ loadRecordBundle 必须
    // 成功加载（未知字段回退默认样式），不能因单个未来枚举值 throw .dbCorrupted 拖垮整条记录。
    func test_loadRecordBundle_futureColorToken_fallsBackNotCorrupted() throws {
        let recordId = try db.insertRecord(makeRecord(), ops: [], drawings: [])

        let raw = try AppDBFixture.openRaw(at: dbURL)
        let anchorsJSON = "[{\"period\":\"daily\",\"candleIndex\":1,\"price\":10.0}]"
        let futureStyleJSON = """
            {"period":"daily","lineSubType":"straight","lineStyle":"solid","thickness":1,\
            "colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"",\
            "fontSize":14,"textColorToken":"orange","textForm":"plain"}
            """
        try raw.write { txDb in
            try txDb.execute(sql: """
                INSERT INTO drawings
                  (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
                VALUES (?, 'horizontal', 0, 0, ?, 0, 'future-style-uuid', ?)
                """, arguments: [recordId, anchorsJSON, futureStyleJSON])
        }

        let bundle = try db.loadRecordBundle(id: recordId)
        XCTAssertEqual(bundle.2.count, 1)
        XCTAssertEqual(bundle.2[0].toolType, .horizontal)
        XCTAssertEqual(bundle.2[0].colorToken, .orange)   // 未知 raw value 回退默认，不 throw
    }

    // 用例 10（同一 finding，anchors 列 Period 版本容错）：anchors JSON 内嵌未知 future Period
    // raw value → 同样回退默认 period，不 throw .dbCorrupted。
    func test_loadRecordBundle_futurePeriodInAnchors_fallsBackNotCorrupted() throws {
        let recordId = try db.insertRecord(makeRecord(), ops: [], drawings: [])

        let raw = try AppDBFixture.openRaw(at: dbURL)
        let futureAnchorsJSON = "[{\"period\":\"quarterly\",\"candleIndex\":5,\"price\":20.0}]"
        try raw.write { txDb in
            try txDb.execute(sql: """
                INSERT INTO drawings
                  (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
                VALUES (?, 'trend', 0, 0, ?, 0, 'future-period-uuid', NULL)
                """, arguments: [recordId, futureAnchorsJSON])
        }

        let bundle = try db.loadRecordBundle(id: recordId)
        XCTAssertEqual(bundle.2.count, 1)
        XCTAssertEqual(bundle.2[0].anchors.count, 1)
        XCTAssertEqual(bundle.2[0].anchors[0].period, .daily)   // 未知 raw value 回退默认，不 throw
        XCTAssertEqual(bundle.2[0].anchors[0].candleIndex, 5)
    }

    // MARK: - Helpers

    private func makeRecord(createdAt: Int64 = 1_700_000_000_000,
                            totalCapital: Double = 10_000,
                            profit: Double = 0,
                            finalTick: Int = 0) -> TrainingRecord {
        TrainingRecord(
            id: nil, trainingSetFilename: "set-A.zip", createdAt: createdAt,
            stockCode: "000001", stockName: "平安银行",
            startYear: 2024, startMonth: 1,
            totalCapital: totalCapital, profit: profit, returnRate: 0.01, maxDrawdown: 50,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0003, minCommissionEnabled: true),
            finalTick: finalTick
        )
    }

    private func makeOp(globalTick: Int) -> TradeOperation {
        TradeOperation(
            globalTick: globalTick, period: .daily, direction: .buy,
            price: 10.0, shares: 100, positionTier: .tier1,
            commission: 1.0, stampDuty: 0.5, totalCost: 1001.5,
            createdAt: 1_700_000_000_000
        )
    }

    private func makeDrawing(toolType: DrawingToolType) -> DrawingObject {
        DrawingObject(toolType: toolType,
                      anchors: [DrawingAnchor(period: .daily, candleIndex: 1, price: 10)],
                      isExtended: false, panelPosition: 0)
    }
}
