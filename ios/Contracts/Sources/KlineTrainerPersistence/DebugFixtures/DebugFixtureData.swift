// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift
// Kline Trainer — debug-only fixture 数据生成（Wave 3 PR 13b §C）
//
// #if DEBUG only：确定性（无随机）生成 rich 训练组蜡烛 + records/pending/settings 描述，供
// AppContainer 全 app fixture provisioning。Release 编译期剔除（整文件 #if DEBUG）。
// 蜡烛满足 DefaultTrainingSetReader 不变量（0 基严格递增 global==end / 有效 OHLC / volume>=0 /
// daily end<=max m3 end）。指标：MA66 rolling mean；BOLL/MACD 留 NULL（nullable；交互矩阵不需指标精度）。

#if DEBUG
import Foundation
import KlineTrainerContracts

public enum DebugFixtureData {

    public struct CandleRow: Equatable, Sendable {
        public let datetime: Int64
        public let open: Double, high: Double, low: Double, close: Double
        public let volume: Int
        public let ma66: Double?
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

    private static let baseEpoch: Int64 = 1_700_000_000
    private static let m3Step: Int64 = 180
    private static let dailySpan = 80

    public static func make(m3Count: Int = 240) -> Seed {
        let filename = "debug-fixture-600001.sqlite"
        var m3Rows: [CandleRow] = []
        var closes: [Double] = []
        for i in 0..<m3Count {
            let close = 10.0 + 2.0 * sin(Double(i) * 0.15)
            let open = 10.0 + 2.0 * sin(Double(max(0, i - 1)) * 0.15)
            let high = max(open, close) + 0.3
            let low = min(open, close) - 0.3
            closes.append(close)
            let ma66: Double? = i >= 65
                ? closes[(i - 65)...i].reduce(0, +) / 66.0
                : nil
            m3Rows.append(CandleRow(
                datetime: baseEpoch + Int64(i) * m3Step,
                open: open, high: high, low: low, close: close,
                volume: 1000 + i * 10, ma66: ma66,
                globalIndex: i, endGlobalIndex: i))
        }
        var dailyRows: [CandleRow] = []
        var start = 0
        while start < m3Count {
            let end = min(start + dailySpan - 1, m3Count - 1)
            let slice = m3Rows[start...end]
            let o = slice.first!.open, c = slice.last!.close
            let hi = slice.map(\.high).max()!, lo = slice.map(\.low).min()!
            dailyRows.append(CandleRow(
                datetime: m3Rows[start].datetime,
                open: o, high: hi, low: lo, close: c,
                volume: slice.map(\.volume).reduce(0, +), ma66: nil,
                globalIndex: nil, endGlobalIndex: end))
            start += dailySpan
        }
        let candles = [PeriodCandles(period: .m3, rows: m3Rows),
                       PeriodCandles(period: .daily, rows: dailyRows)]

        let meta = TrainingSetMeta(
            stockCode: "600001", stockName: "示例训练股",
            startDatetime: m3Rows.first!.datetime, endDatetime: m3Rows.last!.datetime)

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
