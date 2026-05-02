import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
import KlineTrainerContracts

/// 构造测试用训练组 sqlite 文件。
/// - schema 与 backend/sql/training_set_schema_v1.sql 一致；helper 自包含不依赖 backend 路径
/// - 每次调用生成独立 UUID 子目录，避免并行测试 race
/// - 写入完成后 DatabaseQueue 显式作用域结束，触发 ARC 释放 + 文件句柄释放
enum TrainingSetSQLiteFixture {
    struct ConfigOptions {
        var userVersion: Int = 1
        var meta: TrainingSetMeta? = TrainingSetMeta(
            stockCode: "600001",
            stockName: "测试股票",
            startDatetime: 1_700_000_000,
            endDatetime: 1_700_086_400
        )
        var candles: [(Period, [(datetime: Int64, gIdx: Int?, endGIdx: Int)])] = [
            (.m3, [(1_700_000_000, 0, 0), (1_700_000_180, 1, 1)]),
            (.daily, [(1_700_000_000, nil, 1)]),
        ]
        var skipKlinesTable: Bool = false  // 用于 corrupt 测试
        var skipMetaTable: Bool = false    // 用于 corrupt 测试
    }

    /// 在 tmp 目录创建 sqlite 文件，返回 (URL, cleanupClosure)。
    /// 调用方在 tearDown 调 cleanup() 删除该文件所属的 per-call UUID 目录。
    static func make(_ options: ConfigOptions = ConfigOptions()) throws -> (url: URL, cleanup: () -> Void) {
        let perCallDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kline_trainer_persistence_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: perCallDir, withIntermediateDirectories: true)
        let fileURL = perCallDir.appendingPathComponent("training_set.sqlite")

        // 写入 sqlite，作用域结束 ARC 释放 queue
        do {
            let queue = try DatabaseQueue(path: fileURL.path)
            try queue.write { db in
                try db.execute(sql: "PRAGMA user_version = \(options.userVersion)")

                if !options.skipMetaTable {
                    try db.execute(sql: """
                    CREATE TABLE meta (
                        stock_code TEXT NOT NULL,
                        stock_name TEXT NOT NULL,
                        start_datetime INTEGER NOT NULL,
                        end_datetime INTEGER NOT NULL
                    )
                    """)
                    if let m = options.meta {
                        try db.execute(sql: """
                        INSERT INTO meta (stock_code, stock_name, start_datetime, end_datetime)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [m.stockCode, m.stockName, m.startDatetime, m.endDatetime])
                    }
                }

                if !options.skipKlinesTable {
                    try db.execute(sql: """
                    CREATE TABLE klines (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        period TEXT NOT NULL,
                        datetime INTEGER NOT NULL,
                        open REAL NOT NULL,
                        high REAL NOT NULL,
                        low REAL NOT NULL,
                        close REAL NOT NULL,
                        volume INTEGER NOT NULL,
                        amount REAL,
                        ma66 REAL,
                        boll_upper REAL,
                        boll_mid REAL,
                        boll_lower REAL,
                        macd_diff REAL,
                        macd_dea REAL,
                        macd_bar REAL,
                        global_index INTEGER,
                        end_global_index INTEGER NOT NULL
                    )
                    """)
                    try db.execute(sql: "CREATE INDEX idx_period_endidx ON klines(period, end_global_index)")
                    try db.execute(sql: "CREATE INDEX idx_period_datetime ON klines(period, datetime)")

                    for (period, rows) in options.candles {
                        for row in rows {
                            try db.execute(sql: """
                            INSERT INTO klines (period, datetime, open, high, low, close, volume,
                                amount, ma66, boll_upper, boll_mid, boll_lower,
                                macd_diff, macd_dea, macd_bar, global_index, end_global_index)
                            VALUES (?, ?, 1.0, 2.0, 0.5, 1.5, 100, NULL, NULL, NULL, NULL, NULL,
                                    NULL, NULL, NULL, ?, ?)
                            """, arguments: [period.rawValue, row.datetime, row.gIdx, row.endGIdx])
                        }
                    }
                }
            }
        }  // queue 出作用域，ARC 释放

        let cleanup: () -> Void = { try? FileManager.default.removeItem(at: perCallDir) }
        return (fileURL, cleanup)
    }
}
