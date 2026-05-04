import Testing
import Foundation
import KlineTrainerContracts
@testable import KlineTrainerPersistence

@Suite("DefaultTrainingSetDataVerifier")
struct DefaultTrainingSetDataVerifierTests {

    static let startDT: Int64 = 20240101_000000

    /// 测试用 reader：注入 meta + candles 字典；close 空实现。
    private final class FakeReader: TrainingSetReader, @unchecked Sendable {
        let meta: TrainingSetMeta
        let candles: [Period: [KLineCandle]]
        init(meta: TrainingSetMeta, candles: [Period: [KLineCandle]]) {
            self.meta = meta
            self.candles = candles
        }
        func loadMeta() throws -> TrainingSetMeta { meta }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { candles }
        func close() { }
    }

    /// loadAllCandles 抛错的 reader（模拟 sqlite 损坏）。loadMeta 走默认。
    private final class ThrowingCandlesReader: TrainingSetReader, @unchecked Sendable {
        let err: Error
        init(_ err: Error) { self.err = err }
        func loadMeta() throws -> TrainingSetMeta {
            TrainingSetMeta(
                stockCode: "000001", stockName: "X",
                startDatetime: startDT, endDatetime: startDT
            )
        }
        func loadAllCandles() throws -> [Period: [KLineCandle]] { throw err }
        func close() { }
    }

    private static let startDT_local: Int64 = startDT

    private static func candle(_ period: Period, dt: Int64) -> KLineCandle {
        KLineCandle(
            period: period, datetime: dt,
            open: 1, high: 1, low: 1, close: 1,
            volume: 0, amount: nil,
            ma66: nil,
            bollUpper: nil, bollMid: nil, bollLower: nil,
            macdDiff: nil, macdDea: nil, macdBar: nil,
            globalIndex: nil, endGlobalIndex: 0
        )
    }

    /// 生成合法的 candles：每周期 30 before + N after（monthly N=8，其它 N=1）。
    static func makeValidCandles() -> [Period: [KLineCandle]] {
        var dict: [Period: [KLineCandle]] = [:]
        for p in Period.allCases {
            var arr: [KLineCandle] = []
            for i in 1...30 {
                arr.append(candle(p, dt: startDT - Int64(i)))    // before
            }
            let afterCount = (p == .monthly) ? 8 : 1
            for i in 0..<afterCount {
                arr.append(candle(p, dt: startDT + Int64(i)))    // at-or-after
            }
            dict[p] = arr
        }
        return dict
    }

    private static func makeMeta() -> TrainingSetMeta {
        TrainingSetMeta(stockCode: "000001", stockName: "X",
                        startDatetime: startDT, endDatetime: startDT + 100)
    }

    // ── happy path ────────────────────────────────

    @Test func verifyNonEmpty_validShape_passes() throws {
        let v = DefaultTrainingSetDataVerifier()
        let r = FakeReader(meta: Self.makeMeta(), candles: Self.makeValidCandles())
        try v.verifyNonEmpty(reader: r)
    }

    // ── 缺周期 / 空字典 ────────────────────────────

    @Test func verifyNonEmpty_missingMonthly_throwsEmptyData() throws {
        var c = Self.makeValidCandles()
        c[.monthly] = nil
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try DefaultTrainingSetDataVerifier().verifyNonEmpty(
                reader: FakeReader(meta: Self.makeMeta(), candles: c)
            )
        }
    }

    @Test func verifyNonEmpty_emptyDict_throwsEmptyData() throws {
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try DefaultTrainingSetDataVerifier().verifyNonEmpty(
                reader: FakeReader(meta: Self.makeMeta(), candles: [:])
            )
        }
    }

    // ── R1 codex finding 1：单 candle trivial trash 必须拒 ────

    @Test func verifyNonEmpty_singleCandlePerPeriod_throwsEmptyData() throws {
        var c: [Period: [KLineCandle]] = [:]
        for p in Period.allCases {
            c[p] = [Self.candle(p, dt: Self.startDT_local)]
        }
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try DefaultTrainingSetDataVerifier().verifyNonEmpty(
                reader: FakeReader(meta: Self.makeMeta(), candles: c)
            )
        }
    }

    // ── spec L1062：每周期 startDatetime 前 ≥30 candles ───

    @Test func verifyNonEmpty_only29Before_throwsEmptyData() throws {
        var c = Self.makeValidCandles()
        // daily 周期减到 29 before
        var arr = (c[.daily] ?? []).filter { $0.datetime < Self.startDT_local }.dropLast()
        arr.append(contentsOf: (c[.daily] ?? []).filter { $0.datetime >= Self.startDT_local })
        c[.daily] = Array(arr)
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try DefaultTrainingSetDataVerifier().verifyNonEmpty(
                reader: FakeReader(meta: Self.makeMeta(), candles: c)
            )
        }
    }

    // ── spec L741：monthly startDatetime 后 ≥8 candles ───

    @Test func verifyNonEmpty_monthlyOnly7After_throwsEmptyData() throws {
        var c = Self.makeValidCandles()
        var arr = (c[.monthly] ?? []).filter { $0.datetime < Self.startDT_local }
        // 加 7 after（少 1）
        for i in 0..<7 {
            arr.append(Self.candle(.monthly, dt: Self.startDT_local + Int64(i)))
        }
        c[.monthly] = arr
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try DefaultTrainingSetDataVerifier().verifyNonEmpty(
                reader: FakeReader(meta: Self.makeMeta(), candles: c)
            )
        }
    }

    // ── 其它周期 startDatetime 后 ≥1（spec spirit） ─────

    @Test func verifyNonEmpty_dailyZeroAfter_throwsEmptyData() throws {
        var c = Self.makeValidCandles()
        c[.daily] = (c[.daily] ?? []).filter { $0.datetime < Self.startDT_local }
        #expect(throws: AppError.trainingSet(.emptyData)) {
            try DefaultTrainingSetDataVerifier().verifyNonEmpty(
                reader: FakeReader(meta: Self.makeMeta(), candles: c)
            )
        }
    }

    // ── reader 抛错传播 ──────────────────────────────

    @Test func verifyNonEmpty_readerThrows_propagatesAsAppError() throws {
        let v = DefaultTrainingSetDataVerifier()
        let appErr = AppError.persistence(.dbCorrupted)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            try v.verifyNonEmpty(reader: ThrowingCandlesReader(appErr))
        }
    }
}
