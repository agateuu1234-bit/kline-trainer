import Testing
import Foundation
@testable import KlineTrainerPersistence
import KlineTrainerContracts

#if DEBUG
@Suite("DebugTrainingSetWriter：生成 sqlite 经真 factory 可 open + 读全蜡烛（§C）")
struct DebugTrainingSetWriterTests {

    @Test("写出的训练组 sqlite：openAndVerify 成功 + loadAllCandles 含 m3/daily")
    func writtenSqlite_isDownstreamConsumable() throws {
        let seed = DebugFixtureData.make(m3Count: 240)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugWriter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(seed.trainingSetFilename)

        try DebugTrainingSetWriter.write(seed: seed, to: url)

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: url, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let meta = try reader.loadMeta()
        #expect(meta.stockCode == "600001")
        let candles = try reader.loadAllCandles()
        #expect((candles[.m3]?.count ?? 0) == 240)
        #expect((candles[.daily]?.isEmpty == false))
        #expect(candles[.m3]?.first?.globalIndex == 0)
    }

    // 监 NULL hard-code 回归 + reader typeof() 存储类亲和门（绑定值须 Double?→REAL/NULL 才过 loadAllCandles）
    @Test("往返保真：m3 周期 boll/macd 列读出非 NULL 且与 seed CandleRow 一致")
    func roundTrip_indicatorsNonNull() throws {
        let seed = DebugFixtureData.make(m3Count: 240)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugWriterRT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(seed.trainingSetFilename)

        try DebugTrainingSetWriter.write(seed: seed, to: url)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: url, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let read = try reader.loadAllCandles()[.m3]!
        let seedM3 = seed.candles.first(where: { $0.period == .m3 })!.rows

        // m3 240 根：BOLL 从 idx19、MACD 从 idx0 非 nil
        #expect(read[19].bollUpper != nil && read[19].bollMid != nil && read[19].bollLower != nil)
        #expect(read[0].macdDiff != nil && read[0].macdDea != nil && read[0].macdBar != nil)
        #expect(read[100].macdBar != nil)
        // 往返一致（容差 1e-9，REAL 精度足够）
        #expect(abs((read[19].bollUpper ?? -1) - (seedM3[19].bollUpper ?? -2)) < 1e-9)
        #expect(abs((read[0].macdBar ?? -1) - (seedM3[0].macdBar ?? -2)) < 1e-9)
        #expect(abs((read[19].bollMid ?? -1) - (seedM3[19].bollMid ?? -2)) < 1e-9)
        #expect(abs((read[19].bollLower ?? -1) - (seedM3[19].bollLower ?? -2)) < 1e-9)
        #expect(abs((read[0].macdDiff ?? -1) - (seedM3[0].macdDiff ?? -2)) < 1e-9)
        #expect(abs((read[0].macdDea ?? -1) - (seedM3[0].macdDea ?? -2)) < 1e-9)
    }
}
#endif
