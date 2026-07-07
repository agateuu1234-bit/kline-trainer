import XCTest
import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

// 画线工具扩充 P1a Task 9：迁移 0009 给 drawings 加 style_json（可空）+ draw_uuid
// （NOT NULL + CHECK(<> '') + UNIQUE，D20 DB 边界强制）；表重建保留原列/PK/FK。
final class Migration0009Tests: XCTestCase {
    // 建一个迁移到 0008（user_version 6）、含 1 条 drawings 行的 DB，再跑全量迁移（到 0009）。
    // training_records 列清单照搬 AppDB0005MigrationTests.insertRecord（实际 schema，非 brief 占位列名）。
    private func migratedDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        let full = AppDBMigrations.makeMigrator()
        try full.migrate(dbq, upTo: "0008_v1.10_drawing_reveal_tick")
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO training_records
                  (id, training_set_filename, created_at, stock_code, stock_name, start_year,
                   start_month, total_capital, profit, return_rate, max_drawdown,
                   buy_count, sell_count, fee_snapshot, final_tick)
                VALUES (7, 'test.sqlite', 0, '600519', '贵州茅台', 2020, 1, 100000, 0, 0, 0, 0, 0, '{}', 0)
                """)
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick)
                VALUES (1, 7, 'horizontal', 0, 0, '[]', 0)
                """)
        }
        try full.migrate(dbq)   // 迁到最新（含 0009）
        return dbq
    }

    func testAddsColumnsAndBackfillsDrawUuid() throws {
        let dbq = try migratedDB()
        try dbq.read { db in
            let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(uv, 7)
            let row = try Row.fetchOne(db, sql: "SELECT draw_uuid, style_json FROM drawings WHERE id = 1")
            XCTAssertEqual(row?["draw_uuid"], "legacy-7-1")     // 回填格式
            XCTAssertNil(row?["style_json"] as String?)          // 旧行 style_json NULL
        }
    }

    func testDrawUuidUniqueIndexEnforced() throws {
        let dbq = try migratedDB()
        // 插重复 draw_uuid → UNIQUE 约束报错
        XCTAssertThrowsError(try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid)
                VALUES (2, 7, 'horizontal', 0, 0, '[]', 0, 'legacy-7-1')
                """)
        })
    }

    func testNullDrawUuidRejected() throws {
        let dbq = try migratedDB()
        // 不给 draw_uuid → NOT NULL 违约（DB 边界拦，D20）
        XCTAssertThrowsError(try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick)
                VALUES (3, 7, 'horizontal', 0, 0, '[]', 0)
                """)
        })
    }

    func testEmptyDrawUuidRejected() throws {
        let dbq = try migratedDB()
        // draw_uuid = '' → CHECK(draw_uuid <> '') 违约（DB 边界拦，D20）
        XCTAssertThrowsError(try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid)
                VALUES (4, 7, 'horizontal', 0, 0, '[]', 0, '')
                """)
        })
    }

    // MARK: - Task 10：RecordRepository 读写 draw_uuid + style_json

    // 真实入口：RecordRepositoryImpl.insertRecord（drawings 段）+ loadRecordBundle（返回 .2 = [DrawingObject]）。
    // brief 占位名 insertDrawings/loadDrawings 对齐到这两个既有 API（后者取全量 bundle 的第 3 个分量）。
    // 注：insertRecord 的 INSERT SQL 不写 id 列（自增 rowid）——record.id 参数被忽略，故下方均取
    // insertRecord 的返回值作为真实 recordId，不假设固定数字。
    private func minimalRecord() -> TrainingRecord {
        TrainingRecord(id: nil, trainingSetFilename: "test.sqlite", createdAt: 0,
                      stockCode: "600519", stockName: "贵州茅台", startYear: 2020, startMonth: 1,
                      totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: 0,
                      buyCount: 0, sellCount: 0,
                      feeSnapshot: FeeSnapshot(commissionRate: 0, minCommissionEnabled: false),
                      finalTick: 100)
    }

    func testDrawingFullFieldRoundTripThroughRecordRepo() throws {
        let dbq = try migratedDB()
        let anchor = DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.0)
        let d = DrawingObject(id: "gen-xyz", toolType: .trend, anchors: [anchor, anchor],
                              isExtended: true, panelPosition: 1, revealTick: 9,
                              period: .m60, lineSubType: .segment, lineStyle: .dash2, thickness: 4,
                              colorToken: .blue, labelMode: .right, locked: true,
                              text: "颈线", fontSize: 20, textColorToken: .red, textForm: .borderFilled,
                              tailAnchor: anchor)
        let recordId = try dbq.write { db in
            try RecordRepositoryImpl.insertRecord(db, record: minimalRecord(), ops: [], drawings: [d])
        }
        let loaded = try dbq.read { db in try RecordRepositoryImpl.loadRecordBundle(db, id: recordId) }.2
        let back = try XCTUnwrap(loaded.first { $0.id == "gen-xyz" })
        XCTAssertEqual(back.toolType, .trend)
        XCTAssertEqual(back.anchors, [anchor, anchor])
        XCTAssertEqual(back.isExtended, true)
        XCTAssertEqual(back.panelPosition, 1)
        XCTAssertEqual(back.revealTick, 9)
        XCTAssertEqual(back.period, .m60)
        XCTAssertEqual(back.lineSubType, .segment)
        XCTAssertEqual(back.lineStyle, .dash2)
        XCTAssertEqual(back.thickness, 4)
        XCTAssertEqual(back.colorToken, .blue)
        XCTAssertEqual(back.labelMode, .right)
        XCTAssertEqual(back.locked, true)
        XCTAssertEqual(back.text, "颈线")
        XCTAssertEqual(back.fontSize, 20)
        XCTAssertEqual(back.textColorToken, .red)
        XCTAssertEqual(back.textForm, .borderFilled)
        XCTAssertEqual(back.tailAnchor, anchor)
    }

    // 旧行（style_json NULL）+ is_extended=1 → 行感知兜底须读回 .ray（不能扁平默认成 .straight）；
    // period 由锚点派生。用独立 training_records 行避免与 migratedDB() 自带的 record 7/drawing 1 混杂。
    func testLegacyExtendedRowLoadsAsRay() throws {
        let dbq = try migratedDB()
        let recordId = try dbq.write { db -> Int64 in
            let rid = try RecordRepositoryImpl.insertRecord(db, record: minimalRecord(), ops: [], drawings: [])
            try db.execute(sql: """
                INSERT INTO drawings (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
                VALUES (?, 'horizontal', 0, 1, ?, 0, 'legacy-1-1', NULL)
                """, arguments: [rid, try RecordRepositoryImpl.jsonEncode([DrawingAnchor(period: .daily, candleIndex: 3, price: 10)])])
            return rid
        }
        let loaded = try dbq.read { db in try RecordRepositoryImpl.loadRecordBundle(db, id: recordId) }.2
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].lineSubType, .ray)        // 由 is_extended=1 派生，非扁平 .straight
        XCTAssertEqual(loaded[0].period, .daily)           // 由锚点派生
        XCTAssertEqual(loaded[0].id, "legacy-1-1")
    }

    // 未知/未来 tool_type 的 finalized 行 → 跳过（不伪装成 .horizontal）。同上用独立 record。
    func testUnknownToolTypeRowSkipped() throws {
        let dbq = try migratedDB()
        let recordId = try dbq.write { db -> Int64 in
            let rid = try RecordRepositoryImpl.insertRecord(db, record: minimalRecord(), ops: [], drawings: [])
            try db.execute(sql: """
                INSERT INTO drawings (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
                VALUES (?, 'future_tool_xyz', 0, 0, ?, 0, 'legacy-1-2', NULL)
                """, arguments: [rid, try RecordRepositoryImpl.jsonEncode([DrawingAnchor(period: .daily, candleIndex: 3, price: 10)])])
            return rid
        }
        let loaded = try dbq.read { db in try RecordRepositoryImpl.loadRecordBundle(db, id: recordId) }.2
        XCTAssertTrue(loaded.isEmpty)                      // 跳过，绝不出现一条 .horizontal
    }
}
