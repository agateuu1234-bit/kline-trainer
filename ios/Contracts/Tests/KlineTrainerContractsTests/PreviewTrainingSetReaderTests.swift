// R5 修订：用 @testable import 拿 internal 访问（PreviewTrainingSetReader.init 改 internal 镜像 production）
import XCTest
import Foundation
@testable import KlineTrainerContracts

#if DEBUG
final class PreviewTrainingSetReaderTests: XCTestCase {

    func test_reader_loadMeta_returns_injected_meta() throws {
        // 注：直接构造 reader 不经过 factory；reader.loadMeta 自身不做 meta sanity，
        // 只在 factory.openAndVerify 处校验（mirror production：sanity 在 factory）
        let meta = TrainingSetMeta(stockCode: "600519", stockName: "贵州茅台",
                                   startDatetime: 1_700_000_000, endDatetime: 1_700_086_400)
        let reader = PreviewTrainingSetReader(meta: meta, candles: [:])
        XCTAssertEqual(try reader.loadMeta(), meta)
    }

    func test_reader_loadAllCandles_returns_injected_dict() throws {
        // R4 修订（codex round-4 high-2）：positive 测试必须满足 v4 加的 validateCandles
        // 不变量——非空 result 必有 m3，非 m3 endGlobalIndex 落在 m3 范围内
        let m3 = KLineCandle(period: .m3, datetime: 0,
                             open: 1, high: 2, low: 0.5, close: 1.5,
                             volume: 100, amount: nil, ma66: nil,
                             bollUpper: nil, bollMid: nil, bollLower: nil,
                             macdDiff: nil, macdDea: nil, macdBar: nil,
                             globalIndex: 0, endGlobalIndex: 0)
        let daily = KLineCandle(period: .daily, datetime: 0,
                                open: 1, high: 2, low: 0.5, close: 1.5,
                                volume: 100, amount: nil, ma66: nil,
                                bollUpper: nil, bollMid: nil, bollLower: nil,
                                macdDiff: nil, macdDea: nil, macdBar: nil,
                                globalIndex: nil, endGlobalIndex: 0)
        let dict: [Period: [KLineCandle]] = [.m3: [m3], .daily: [daily]]
        // R4 修订：meta 必须满足 production sanity（startDatetime > 0 + endDatetime >= startDatetime）
        let reader = PreviewTrainingSetReader(
            meta: TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 1, endDatetime: 1),
            candles: dict)
        let loaded = try reader.loadAllCandles()
        XCTAssertEqual(loaded[.m3]?.count, 1)
        XCTAssertEqual(loaded[.daily]?.count, 1)
        XCTAssertEqual(loaded[.daily]?.first?.close, 1.5)
    }

    /// R2 修订（codex round-2 high-1）：close 后 loadMeta / loadAllCandles 必须 throw（mirror production DefaultTrainingSetReader.ensureOpen）
    /// R5 修订：meta 用合法 sanity 值（startDatetime/endDatetime = 1）
    func test_reader_close_then_loadMeta_throws_internalError() {
        let reader = PreviewTrainingSetReader(
            meta: TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 1, endDatetime: 1),
            candles: [:])
        // close 前可读
        XCTAssertNoThrow(try reader.loadMeta())

        reader.close()

        // close 后 loadMeta 抛 internalError
        XCTAssertThrowsError(try reader.loadMeta()) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
        // close 后 loadAllCandles 也抛
        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.internalError = err else { XCTFail("expected internalError"); return }
        }
        // close 重复调用合法（mirror production NSLock 不抛）
        reader.close()
    }

    // MARK: - Factory

    func test_factory_default_init_returns_reader_with_placeholder_meta() throws {
        let factory = PreviewTrainingSetDBFactory()
        // file URL + expectedSchemaVersion 都被忽略；不抛
        let reader = try factory.openAndVerify(
            file: URL(fileURLWithPath: "/dev/null"),
            expectedSchemaVersion: 1)
        let meta = try reader.loadMeta()
        XCTAssertEqual(meta.stockCode, "PREVIEW") // §3 决策：占位 meta
    }

    func test_factory_value_injected_returns_reader_with_provided_meta() throws {
        let meta = TrainingSetMeta(stockCode: "300750", stockName: "宁德时代",
                                   startDatetime: 1, endDatetime: 2)
        let factory = PreviewTrainingSetDBFactory(meta: meta, candles: [:])
        let reader = try factory.openAndVerify(
            file: URL(fileURLWithPath: "/dev/null"),
            expectedSchemaVersion: 1)
        XCTAssertEqual(try reader.loadMeta().stockCode, "300750")
    }

    func test_factory_returns_independent_reader_per_call() throws {
        // spec L1830 注释：「每次调用产生新 reader 实例」——fake 也镜像
        let factory = PreviewTrainingSetDBFactory()
        let r1 = try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1)
        let r2 = try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1)
        XCTAssertFalse(r1 === r2)
    }

    // MARK: - R4 修订：factory meta sanity check（mirror production DefaultTrainingSetDBFactory line 65-68）

    func test_factory_rejects_empty_stockCode() throws {
        let bad = TrainingSetMeta(stockCode: "", stockName: "Y", startDatetime: 1, endDatetime: 1)
        let factory = PreviewTrainingSetDBFactory(meta: bad)
        XCTAssertThrowsError(try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1)) { err in
            guard case AppError.persistence(.dbCorrupted) = err else { XCTFail("expected dbCorrupted"); return }
        }
    }

    func test_factory_rejects_empty_stockName() throws {
        let bad = TrainingSetMeta(stockCode: "X", stockName: "", startDatetime: 1, endDatetime: 1)
        let factory = PreviewTrainingSetDBFactory(meta: bad)
        XCTAssertThrowsError(try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1))
    }

    func test_factory_rejects_zero_or_negative_startDatetime() throws {
        let bad0 = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 1)
        XCTAssertThrowsError(try PreviewTrainingSetDBFactory(meta: bad0)
            .openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1))
        let badNeg = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: -1, endDatetime: 1)
        XCTAssertThrowsError(try PreviewTrainingSetDBFactory(meta: badNeg)
            .openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1))
    }

    func test_factory_rejects_endDatetime_before_startDatetime() throws {
        let bad = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 100, endDatetime: 50)
        XCTAssertThrowsError(try PreviewTrainingSetDBFactory(meta: bad)
            .openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1))
    }

    func test_factory_default_placeholder_meta_passes_sanity() throws {
        // R4 修订：默认 placeholder（startDatetime/endDatetime = 1）必须通过 sanity
        let factory = PreviewTrainingSetDBFactory()
        XCTAssertNoThrow(try factory.openAndVerify(file: URL(fileURLWithPath: "/dev/null"), expectedSchemaVersion: 1))
    }

    // MARK: - R3 修订：数据校验（mirror production DefaultTrainingSetReader 全套 invariants）

    /// Helper: 构造一根有效 m3 candle (globalIndex == endGlobalIndex == idx)
    private func validM3(_ idx: Int, close: Double = 1.5) -> KLineCandle {
        KLineCandle(period: .m3, datetime: Int64(idx),
                    open: 1, high: 2, low: 0.5, close: close,
                    volume: 100, amount: nil, ma66: nil,
                    bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: idx, endGlobalIndex: idx)
    }
    /// Helper: 构造 valid 单根 daily candle (endGlobalIndex 落在指定值)
    private func validDaily(eg: Int, close: Double = 1.5) -> KLineCandle {
        KLineCandle(period: .daily, datetime: 0,
                    open: 1, high: 2, low: 0.5, close: close,
                    volume: 100, amount: nil, ma66: nil,
                    bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: nil, endGlobalIndex: eg)
    }

    func test_reader_validation_OHLC_must_be_finite_and_positive() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)

        // Open = NaN → corrupt
        let badNaN = KLineCandle(period: .m3, datetime: 0,
                                 open: .nan, high: 2, low: 0.5, close: 1,
                                 volume: 100, amount: nil, ma66: nil,
                                 bollUpper: nil, bollMid: nil, bollLower: nil,
                                 macdDiff: nil, macdDea: nil, macdBar: nil,
                                 globalIndex: 0, endGlobalIndex: 0)
        let r1 = PreviewTrainingSetReader(meta: meta, candles: [.m3: [badNaN]])
        XCTAssertThrowsError(try r1.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else { XCTFail("expected dbCorrupted"); return }
        }

        // Open = 0 → corrupt
        let bad0 = KLineCandle(period: .m3, datetime: 0,
                               open: 0, high: 2, low: 0.5, close: 1,
                               volume: 100, amount: nil, ma66: nil,
                               bollUpper: nil, bollMid: nil, bollLower: nil,
                               macdDiff: nil, macdDea: nil, macdBar: nil,
                               globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad0]]).loadAllCandles())
    }

    func test_reader_validation_OHLC_ordering_high_max_low_min() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // high < open (违反 high >= max(open, close, low))
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 5, high: 2, low: 0.5, close: 1,
                              volume: 100, amount: nil, ma66: nil,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())
    }

    func test_reader_validation_volume_nonnegative() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 1, high: 2, low: 0.5, close: 1,
                              volume: -1, amount: nil, ma66: nil,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())
    }

    func test_reader_validation_optional_indicators_must_be_finite_when_set() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // ma66 = inf
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 1, high: 2, low: 0.5, close: 1,
                              volume: 100, amount: nil, ma66: .infinity,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 0, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())
    }

    func test_reader_validation_endGlobalIndex_strictly_increasing_per_period() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // 同 period 两根 endGlobalIndex 相等 → 非严格递增
        let dup1 = validM3(0)
        let dup2 = KLineCandle(period: .m3, datetime: 1,
                               open: 1, high: 2, low: 0.5, close: 1,
                               volume: 100, amount: nil, ma66: nil,
                               bollUpper: nil, bollMid: nil, bollLower: nil,
                               macdDiff: nil, macdDea: nil, macdBar: nil,
                               globalIndex: 0, endGlobalIndex: 0)  // 重复 0
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [dup1, dup2]]).loadAllCandles())
    }

    func test_reader_validation_m3_globalIndex_must_equal_endGlobalIndex_and_array_index() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // m3[0] 但 globalIndex = 5（应等于 array idx = 0）
        let bad = KLineCandle(period: .m3, datetime: 0,
                              open: 1, high: 2, low: 0.5, close: 1,
                              volume: 100, amount: nil, ma66: nil,
                              bollUpper: nil, bollMid: nil, bollLower: nil,
                              macdDiff: nil, macdDea: nil, macdBar: nil,
                              globalIndex: 5, endGlobalIndex: 5)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [bad]]).loadAllCandles())

        // m3 globalIndex = nil 也违反（must non-nil + equal endGlobalIndex + array idx）
        let badNil = KLineCandle(period: .m3, datetime: 0,
                                 open: 1, high: 2, low: 0.5, close: 1,
                                 volume: 100, amount: nil, ma66: nil,
                                 bollUpper: nil, bollMid: nil, bollLower: nil,
                                 macdDiff: nil, macdDea: nil, macdBar: nil,
                                 globalIndex: nil, endGlobalIndex: 0)
        XCTAssertThrowsError(try PreviewTrainingSetReader(meta: meta, candles: [.m3: [badNil]]).loadAllCandles())
    }

    func test_reader_validation_non_m3_endGlobalIndex_must_be_nonneg_and_within_m3Max() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // m3 max endGlobalIndex = 2；daily 一根 endGlobalIndex = 5 → 越界
        let m3 = [validM3(0), validM3(1), validM3(2)]
        let dailyOob = validDaily(eg: 5)
        XCTAssertThrowsError(try PreviewTrainingSetReader(
            meta: meta, candles: [.m3: m3, .daily: [dailyOob]]
        ).loadAllCandles())

        // daily endGlobalIndex = -1（非负要求）
        let dailyNeg = validDaily(eg: -1)
        XCTAssertThrowsError(try PreviewTrainingSetReader(
            meta: meta, candles: [.m3: m3, .daily: [dailyNeg]]
        ).loadAllCandles())
    }

    func test_reader_validation_higher_period_without_m3_is_corrupt() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        // 只有 daily 没有 m3，且非空 → corrupt
        XCTAssertThrowsError(try PreviewTrainingSetReader(
            meta: meta, candles: [.daily: [validDaily(eg: 0)]]
        ).loadAllCandles())
    }

    func test_reader_validation_empty_dict_is_legal() throws {
        // 整库 result 全空 = 允许（mirror production line 169-172 else 分支不触发）
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 0, endDatetime: 0)
        let r = PreviewTrainingSetReader(meta: meta, candles: [:])
        XCTAssertEqual(try r.loadAllCandles().count, 0)
    }

    func test_reader_validation_valid_m3_plus_daily_passes() throws {
        // 直接构造 reader 不经过 factory；validateCandles 不要求 meta 通过 sanity（仅 candles 范畴）
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 1, endDatetime: 1)
        let m3 = [validM3(0), validM3(1), validM3(2)]
        let daily = [validDaily(eg: 2)]  // 落在 m3 范围内
        let r = PreviewTrainingSetReader(meta: meta, candles: [.m3: m3, .daily: daily])
        let loaded = try r.loadAllCandles()
        XCTAssertEqual(loaded[.m3]?.count, 3)
        XCTAssertEqual(loaded[.daily]?.count, 1)
    }

    /// R4 修订（codex round-4 med-1）：dict key 必须 == candle.period
    func test_reader_validation_period_key_value_consistency() throws {
        let meta = TrainingSetMeta(stockCode: "X", stockName: "Y", startDatetime: 1, endDatetime: 1)
        // 把一根 daily candle 塞进 .m3 key
        let bogus = KLineCandle(period: .daily, datetime: 0,  // ← daily
                                open: 1, high: 2, low: 0.5, close: 1,
                                volume: 100, amount: nil, ma66: nil,
                                bollUpper: nil, bollMid: nil, bollLower: nil,
                                macdDiff: nil, macdDea: nil, macdBar: nil,
                                globalIndex: 0, endGlobalIndex: 0)
        let r = PreviewTrainingSetReader(meta: meta, candles: [.m3: [bogus]])  // ← key 是 m3
        XCTAssertThrowsError(try r.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else { XCTFail("expected dbCorrupted"); return }
        }
    }
}
#endif
