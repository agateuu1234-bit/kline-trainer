// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift
// Kline Trainer — debug-only 全 app fixture provisioning（Wave 3 PR 13b §C）
//
// #if DEBUG only：经组合根的真 db/cache/settings 落库一份确定性 fixture（缓存训练组 + 历史 + pending + 设置），
// 使运行时矩阵可在真 app 跑。幂等（仅 cache 空时 seed）。触发由 KlineTrainerApp（#if DEBUG + env）控制。

#if DEBUG
import Foundation
import KlineTrainerContracts

extension AppContainer {

    /// 幂等 seed：仅当缓存为空时写入 fixture。已有数据 → no-op。
    public func seedDebugFixturesIfEmpty() throws {
        guard cache.listAvailable().isEmpty else { return }

        let seed = DebugFixtureData.make(m3Count: 240)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugSeed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sqliteURL = tmpDir.appendingPathComponent(seed.trainingSetFilename)
        try DebugTrainingSetWriter.write(seed: seed, to: sqliteURL)
        let meta = TrainingSetMetaItem(
            id: 1, stockCode: seed.meta.stockCode, stockName: seed.meta.stockName,
            filename: seed.trainingSetFilename, schemaVersion: TRAINING_SET_SCHEMA_VERSION,
            contentHash: "00000000")
        _ = try cache.store(downloadedZip: sqliteURL, meta: meta)

        try db.saveSettings(seed.settings)

        for rec in seed.records {
            _ = try db.insertRecord(rec, ops: [], drawings: [])
        }

        if let pending = seed.pending {
            try db.savePending(pending)
        }
    }
}
#endif
