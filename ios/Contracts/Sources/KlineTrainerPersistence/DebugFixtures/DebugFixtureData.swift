// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift
// Kline Trainer — debug-only fixture 数据生成（Wave 3 PR 13b §C）
//
// #if DEBUG only：确定性（无随机）生成 rich 训练组蜡烛 + records/pending/settings 描述，供
// AppContainer 全 app fixture provisioning。Release 编译期剔除（整文件 #if DEBUG）。
// 蜡烛满足 DefaultTrainingSetReader 不变量（0 基严格递增 global==end / 有效 OHLC / volume>=0 /
// daily end<=max m3 end）。指标：每周期经 FixtureIndicatorMath 复刻后端公式算 MA66/BOLL/MACD（真实值，非 NULL）。

#if DEBUG
import Foundation
import KlineTrainerContracts

public enum DebugFixtureData {

    public struct CandleRow: Equatable, Sendable {
        public let datetime: Int64
        public let open: Double, high: Double, low: Double, close: Double
        public let volume: Int
        public let ma66: Double?
        public let bollUpper: Double?
        public let bollMid: Double?
        public let bollLower: Double?
        public let macdDiff: Double?
        public let macdDea: Double?
        public let macdBar: Double?
        public let globalIndex: Int?
        public let endGlobalIndex: Int
    }

    public struct PeriodCandles: Equatable, Sendable {
        public let period: Period
        public let rows: [CandleRow]
    }

    public struct Seed {
        public let trainingSetFilename: String
        public let meta: TrainingSetMeta
        public let candles: [PeriodCandles]
        public let records: [TrainingRecord]
        public let pending: PendingTraining?
        public let settings: AppSettings
    }

    /// 帧预算满载 fixture 根数。新 span（5/20/80/160/240）下，约束「monthly span=240 行数 ≥80」
    /// 与「daily span=80 行数 ≥240(maxVisibleCount)」最小公共解 = 80×240 = 240×80 = 19,200。
    public static let fullLoadM3Count = 19_200
    /// 满载 before-candle 根数（起始点前历史）；须为 lcm(spans)=480 倍数（12000=480×25），
    /// 使各周期 before/after 边界皆落在该周期 candle 边界。daily before=150（对齐 spec §8.3）。
    public static let fullLoadBeforeM3Count = 12_000

    private static let baseEpoch: Int64 = 1_700_000_000
    private static let m3Step: Int64 = 180

    public static func make(m3Count: Int = 240, beforeM3Count: Int = 0) -> Seed {
        precondition(beforeM3Count >= 0 && beforeM3Count < m3Count,
                     "beforeM3Count 须在 [0, m3Count)（防 m3Rows[beforeM3Count] 越界）")
        let filename = "debug-fixture-600001.sqlite"

        // m3 原始 OHLCV 由确定性均值回复种子游走生成（替换旧正弦）；先建无指标骨架。
        let ohlcv = FixturePriceSeries.generate(count: m3Count)
        var m3Rows: [CandleRow] = []
        for i in 0..<m3Count {
            let c = ohlcv[i]
            m3Rows.append(CandleRow(
                datetime: baseEpoch + Int64(i) * m3Step,
                open: c.open, high: c.high, low: c.low, close: c.close, volume: c.volume,
                ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: i, endGlobalIndex: i))
        }
        // 其余 5 周期按 span 聚合（与既有逻辑同：global_index=nil、end=组末 m3 index）；指标稍后逐周期填。
        func aggregate(span: Int) -> [CandleRow] {
            var rows: [CandleRow] = []
            var start = 0
            while start < m3Count {
                let end = min(start + span - 1, m3Count - 1)
                let slice = m3Rows[start...end]
                rows.append(CandleRow(
                    datetime: m3Rows[start].datetime,
                    open: slice.first!.open, high: slice.map(\.high).max()!,
                    low: slice.map(\.low).min()!, close: slice.last!.close,
                    volume: slice.map(\.volume).reduce(0, +),
                    ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: nil, endGlobalIndex: end))
                start += span
            }
            return rows
        }
        // 逐周期：对该周期 close 序列复刻后端公式算 MA66/BOLL/MACD，装回新 CandleRow（修 D4：聚合周期亦填 ma66）。
        func withIndicators(_ rows: [CandleRow]) -> [CandleRow] {
            let closes = rows.map(\.close)
            let ma = FixtureIndicatorMath.ma66(closes)
            let bo = FixtureIndicatorMath.boll(closes)
            let mc = FixtureIndicatorMath.macd(closes)
            return rows.indices.map { i in
                CandleRow(
                    datetime: rows[i].datetime, open: rows[i].open, high: rows[i].high,
                    low: rows[i].low, close: rows[i].close, volume: rows[i].volume,
                    ma66: ma[i], bollUpper: bo.upper[i], bollMid: bo.mid[i], bollLower: bo.lower[i],
                    macdDiff: mc.diff[i], macdDea: mc.dea[i], macdBar: mc.bar[i],
                    globalIndex: rows[i].globalIndex, endGlobalIndex: rows[i].endGlobalIndex)
            }
        }
        let candles = [
            PeriodCandles(period: .m3, rows: withIndicators(m3Rows)),
            PeriodCandles(period: .m15, rows: withIndicators(aggregate(span: 5))),
            PeriodCandles(period: .m60, rows: withIndicators(aggregate(span: 20))),
            PeriodCandles(period: .daily, rows: withIndicators(aggregate(span: 80))),
            PeriodCandles(period: .weekly, rows: withIndicators(aggregate(span: 160))),
            PeriodCandles(period: .monthly, rows: withIndicators(aggregate(span: 240))),
        ]

        let meta = TrainingSetMeta(
            stockCode: "600001", stockName: "示例训练股",
            startDatetime: m3Rows[beforeM3Count].datetime, endDatetime: m3Rows.last!.datetime)

        let fees = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: false)
        let records = [
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: baseEpoch,
                           stockCode: "600001", stockName: "示例训练股", startYear: 2023, startMonth: 11,
                           totalCapital: 100_000, profit: 8_900, returnRate: 0.089, maxDrawdown: -0.05,
                           buyCount: 3, sellCount: 2, feeSnapshot: fees, finalTick: m3Count - 1),
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: baseEpoch + 86_400,
                           stockCode: "600001", stockName: "示例训练股", startYear: 2023, startMonth: 11,
                           totalCapital: 108_900, profit: -2_100, returnRate: -0.019, maxDrawdown: -0.08,
                           buyCount: 1, sellCount: 1, feeSnapshot: fees, finalTick: m3Count - 1),
        ]

        let emptyPosition = try! JSONEncoder().encode(PositionManager())
        let pending = PendingTraining(
            trainingSetFilename: filename, globalTickIndex: m3Count / 2,
            upperPeriod: .m3, lowerPeriod: .daily,
            positionData: emptyPosition, cashBalance: 100_000, feeSnapshot: fees,
            tradeOperations: [], drawings: [], startedAt: baseEpoch + 172_800,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0),
            sessionKey: "debug-fixture-pending")

        return Seed(trainingSetFilename: filename, meta: meta, candles: candles,
                    records: records, pending: pending, settings: .default)
    }
}
#endif
