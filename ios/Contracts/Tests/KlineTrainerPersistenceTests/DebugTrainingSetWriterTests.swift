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
}
#endif
