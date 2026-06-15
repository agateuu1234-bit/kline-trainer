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

    /// 帧预算满载 fixture 根数（Wave 3 13c-R2 根治）。
    /// 按既有聚合 span（1/5/20/40/80/120），9600 根 m3 使**每周期 ≥ RenderStateBuilder.defaultVisibleCount(80)**
    /// 且 **make 默认面板 .m60(=480)/.daily(=240) ≥ PinchZoomModel.maxVisibleCount(240)**（pinch 缩放最远档可见根数），
    /// 故经 §C seed 的帧预算 runbook 测的是满载图表（非欠载）。
    /// 推导：约束「monthly span=120 行数 ≥80」与「daily span=40 行数 ≥240」最小公共解 = 80×120 = 240×40 = 9600。
    public static let fullLoadM3Count = 9600

    private static let baseEpoch: Int64 = 1_700_000_000
    private static let m3Step: Int64 = 180

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
        // 全 6 周期（codex-13b-R2-F1）：m3 原始 + 其余按 span 聚合。`TrainingEngine.make` 默认上区 .m60/下区
        // .daily 且校验两 panel 周期非空；周期切换 combo 覆盖全 6 周期——故 fresh start/review/replay + 切换需全周期。
        // 聚合 candle：global_index=nil、end_global_index=该组末 m3 index（组内单调、<= max m3 end，满足 reader 不变量）。
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
                    volume: slice.map(\.volume).reduce(0, +), ma66: nil,
                    globalIndex: nil, endGlobalIndex: end))
                start += span
            }
            return rows
        }
        let candles = [
            PeriodCandles(period: .m3, rows: m3Rows),                  // span 1：240 根
            PeriodCandles(period: .m15, rows: aggregate(span: 5)),     // 48 根
            PeriodCandles(period: .m60, rows: aggregate(span: 20)),    // 12 根（make 默认上区）
            PeriodCandles(period: .daily, rows: aggregate(span: 40)),  // 6 根（make 默认下区）
            PeriodCandles(period: .weekly, rows: aggregate(span: 80)), // 3 根
            PeriodCandles(period: .monthly, rows: aggregate(span: 120)), // 2 根
        ]

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
