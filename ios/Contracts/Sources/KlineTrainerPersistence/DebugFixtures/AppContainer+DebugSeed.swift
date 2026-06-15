// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift
// Kline Trainer — debug-only 全 app fixture provisioning（Wave 3 PR 13b §C）
//
// #if DEBUG only：经组合根的真 db/cache 落库一份确定性 fixture（缓存训练组 + 历史 + pending + 设置），
// 使运行时矩阵可在真 app 跑。由 AppContainer.init（debugSeedFixtures:true）在 SettingsStore 构造前调，
// 故 SettingsStore eager-load 到 seeded settings（codex-13b-R3 stale 修）。Release 二进制零本代码。

#if DEBUG
import Foundation
import KlineTrainerContracts

extension AppContainer {

    /// 全 app fixture provisioning（static：在 init 中、self 构造完成前、SettingsStore 构造前调用）。
    /// **安全 + 幂等**：仅当 cache + history + pending **全空**（= 全新安装）才 seed。
    /// 理由（codex-13b-R1）：iOS 可单独清 Caches 目录但保留 app.sqlite，故「cache 空」≠ fresh install；
    /// 全空 guard 防 seed 覆盖/混入开发者真实 settings/history/pending。
    /// partial-failure（codex-13b-R2 缓解）：db 写在前、cache 最后——db 写失败 → cache 仍空 → 下次全空 guard
    /// 重 seed；极端 partial（db 写到一半）→ 删 app 重置（DEBUG-only，记 residual 13b-R1）。
    static func seedDebugFixtures(db: any AppDB, cache: any CacheManager) throws {
        guard cache.listAvailable().isEmpty,
              try db.statistics().totalCount == 0,
              try db.loadPending() == nil
        else { return }

        let seed = DebugFixtureData.make(m3Count: 240)

        // db 写在前（settings → records → pending）
        try db.saveSettings(seed.settings)
        for rec in seed.records {
            _ = try db.insertRecord(rec, ops: [], drawings: [])
        }
        if let pending = seed.pending {
            try db.savePending(pending)
        }

        // cache 最后（partial 缓解：db 写若失败则 cache 仍空 → 下次全空 guard 可重 seed）
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
    }
}
#endif
