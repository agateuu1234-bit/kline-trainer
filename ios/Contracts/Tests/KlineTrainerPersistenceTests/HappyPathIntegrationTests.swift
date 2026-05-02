import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class HappyPathIntegrationTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    func test_fullPath_factoryOpenLoadMetaLoadCandlesClose() throws {
        // arrange: 6 个 Period 全覆盖（spec §M0.3 Period.allCases；含 m3/m15/m60/daily/weekly/monthly）
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 1, 1), (1_360, 2, 2)]),
            (.m15, [(1_000, nil, 2)]),
            (.m60, [(1_000, nil, 2)]),
            (.daily, [(1_000, nil, 2)]),
            (.weekly, [(1_000, nil, 2)]),
            (.monthly, [(1_000, nil, 2)]),
        ]
        opts.meta = TrainingSetMeta(
            stockCode: "688001",
            stockName: "全周期股",
            startDatetime: 1_000,
            endDatetime: 1_360
        )
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        // act
        let factory = DefaultTrainingSetDBFactory()
        let reader = try factory.openAndVerify(file: url, expectedSchemaVersion: 1)
        let meta = try reader.loadMeta()
        let candles = try reader.loadAllCandles()
        reader.close()

        // assert: meta
        XCTAssertEqual(meta.stockCode, "688001")
        XCTAssertEqual(meta.stockName, "全周期股")

        // assert: 6 个 Period 全有数据
        XCTAssertEqual(Set(candles.keys), Set(Period.allCases))
        XCTAssertEqual(candles[.m3]?.count, 3)
        XCTAssertEqual(candles[.m15]?.count, 1)
        XCTAssertEqual(candles[.m60]?.count, 1)
        XCTAssertEqual(candles[.daily]?.count, 1)
        XCTAssertEqual(candles[.weekly]?.count, 1)
        XCTAssertEqual(candles[.monthly]?.count, 1)

        // assert: m3 按 endGlobalIndex 单调递增（ORDER BY 验证）
        let m3 = candles[.m3]!
        XCTAssertEqual(m3.map(\.endGlobalIndex), [0, 1, 2])
    }
}
