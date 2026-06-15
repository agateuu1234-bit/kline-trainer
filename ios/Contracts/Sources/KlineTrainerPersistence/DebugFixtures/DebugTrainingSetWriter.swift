// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift
// Kline Trainer — debug fixture 训练组 sqlite 写入（Wave 3 PR 13b §C）
//
// #if DEBUG only：把 DebugFixtureData.Seed 的蜡烛 + meta 写成符合训练组 schema（user_version=1 +
// meta + klines）的 sqlite，供 cache.store 直注。schema 对齐 TrainingSetSQLiteFixture / DefaultTrainingSetDBFactory。

#if DEBUG
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

public enum DebugTrainingSetWriter {

    public static func write(seed: DebugFixtureData.Seed, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(TRAINING_SET_SCHEMA_VERSION)")
            try db.execute(sql: """
            CREATE TABLE meta (
                stock_code TEXT NOT NULL, stock_name TEXT NOT NULL,
                start_datetime INTEGER NOT NULL, end_datetime INTEGER NOT NULL)
            """)
            try db.execute(sql: """
            INSERT INTO meta (stock_code, stock_name, start_datetime, end_datetime) VALUES (?, ?, ?, ?)
            """, arguments: [seed.meta.stockCode, seed.meta.stockName,
                             seed.meta.startDatetime, seed.meta.endDatetime])
            try db.execute(sql: """
            CREATE TABLE klines (
                id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT NOT NULL, datetime INTEGER NOT NULL,
                open REAL NOT NULL, high REAL NOT NULL, low REAL NOT NULL, close REAL NOT NULL,
                volume INTEGER NOT NULL, amount REAL, ma66 REAL,
                boll_upper REAL, boll_mid REAL, boll_lower REAL,
                macd_diff REAL, macd_dea REAL, macd_bar REAL,
                global_index INTEGER, end_global_index INTEGER NOT NULL)
            """)
            try db.execute(sql: "CREATE INDEX idx_period_endidx ON klines(period, end_global_index)")
            try db.execute(sql: "CREATE INDEX idx_period_datetime ON klines(period, datetime)")
            for pc in seed.candles {
                for r in pc.rows {
                    try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, amount, ma66,
                        boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar,
                        global_index, end_global_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?)
                    """, arguments: [pc.period.rawValue, r.datetime, r.open, r.high, r.low, r.close,
                                     r.volume, r.ma66, r.globalIndex, r.endGlobalIndex])
                }
            }
        }
    }
}
#endif
