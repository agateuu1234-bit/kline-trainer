// ios/Contracts/Tests/KlineTrainerPersistenceTests/CacheFixture.swift
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
import KlineTrainerContracts

enum CacheFixture {
    /// 创建唯一 cache root in temp，调用方负责 teardown
    static func makeTempCacheRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 写一个最小有效 sqlite（含 PRAGMA user_version=schemaVersion）到 temp，返回 URL
    static func makeValidSqlite(schemaVersion: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sqlite-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(schemaVersion)")
        }
        // 显式 close（drop queue 触发 close）
        return url
    }

    static func meta(id: Int, filename: String) -> TrainingSetMetaItem {
        TrainingSetMetaItem(
            id: id, stockCode: "sh.000001", stockName: "Test",
            filename: filename, schemaVersion: 1,
            contentHash: "deadbeef")
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
