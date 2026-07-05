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
}
