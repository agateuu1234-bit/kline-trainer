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
        /// review-redesign Task 6：与 `records`（同下标）配对的交易流水。`review()` 新增的入口终局
        /// 等式校验会重折叠 ops 到 `record.finalTick` 并与 `record.profit`/`returnRate` 比对——旧版本
        /// `records` 声明 profit/returnRate 但配 `ops: []`（无交易），一致性不再成立，故须配真实 ops。
        public let recordOps: [[TradeOperation]]
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
        // 整改①：pending/交易须落在复盘窗口内（(beforeM3Count, m3Count-1)），否则续训完打复盘报
        // 「训练组数据为空」。复盘窗口须容纳 4 个内部交易 tick + pending（所有真实调用 W≥100；
        // full-load 7200——不破坏任何调用；codex plan R-med）。
        precondition(m3Count - beforeM3Count >= 6,
                     "DebugFixtureData: 复盘窗口 m3Count-beforeM3Count 须 ≥6（容纳 fixture 4 内部交易 tick + pending）")
        // 4 个严格内部 tick（beforeM3Count < t < m3Count-1）+ pending，均匀分布，稳健于任意 W≥6（含窄尾窗口）。
        let interiorFirst = beforeM3Count + 1
        let interiorLast  = m3Count - 2                 // = finalTick - 1，严格 < finalTick
        let span = interiorLast - interiorFirst         // >= 3（precondition 保证）
        let tB1 = interiorFirst
        let tS1 = interiorFirst + span / 3
        let tB2 = interiorFirst + span * 2 / 3
        let tS2 = interiorLast                          // 严格 < finalTick
        let pendingTick = interiorFirst + span / 2      // 严格内部 ∈ (beforeM3Count, m3Count-1)
        func closeAt(_ t: Int) -> Double { m3Rows[min(max(t, 0), m3Count - 1)].close }
        // 可负担整百手（占用 ~40% 本金；价必 > 0）
        func lots(_ price: Double, capital: Double) -> Int { max(100, Int((capital * 0.4 / price) / 100) * 100) }

        let pB1 = closeAt(tB1), pS1 = closeAt(tS1)
        let sh1 = lots(pB1, capital: 100_000)
        let record1Ops = [
            TradeOperation(globalTick: tB1, period: .m3, direction: .buy,  price: pB1, shares: sh1,
                           positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh1) * pB1,
                           createdAt: baseEpoch),
            TradeOperation(globalTick: tS1, period: .m3, direction: .sell, price: pS1, shares: sh1,
                           positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh1) * pS1,
                           createdAt: baseEpoch),
        ]
        let record1Profit = Double(sh1) * (pS1 - pB1)   // fold 同表达式（zero fee → 现金净变 = shares×(卖−买)）
        // record2 起始本金 = record1 结束本金（累计本金链，与生产 RFC-A 累计模型一致；codex plan R-med）
        let record2StartingCapital = 100_000.0 + record1Profit
        let pB2 = closeAt(tB2), pS2 = closeAt(tS2)
        let sh2 = lots(pB2, capital: record2StartingCapital)
        let record2Ops = [
            TradeOperation(globalTick: tB2, period: .m3, direction: .buy,  price: pB2, shares: sh2,
                           positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh2) * pB2,
                           createdAt: baseEpoch + 86_400),
            TradeOperation(globalTick: tS2, period: .m3, direction: .sell, price: pS2, shares: sh2,
                           positionTier: .tier5, commission: 0, stampDuty: 0, totalCost: Double(sh2) * pS2,
                           createdAt: baseEpoch + 86_400),
        ]
        let record2Profit = Double(sh2) * (pS2 - pB2)   // record1Profit 已上移（record2 起始本金依赖它）
        let records = [
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: baseEpoch,
                           stockCode: "600001", stockName: "示例训练股", startYear: 2023, startMonth: 11,
                           totalCapital: 100_000, profit: record1Profit, returnRate: record1Profit / 100_000,
                           maxDrawdown: -0.05,
                           buyCount: 1, sellCount: 1, feeSnapshot: fees, finalTick: m3Count - 1),
            TrainingRecord(id: nil, trainingSetFilename: filename, createdAt: baseEpoch + 86_400,
                           stockCode: "600001", stockName: "示例训练股", startYear: 2023, startMonth: 11,
                           totalCapital: record2StartingCapital, profit: record2Profit,
                           returnRate: record2Profit / record2StartingCapital,
                           maxDrawdown: -0.08,
                           buyCount: 1, sellCount: 1, feeSnapshot: fees, finalTick: m3Count - 1),
        ]
        let recordOps = [record1Ops, record2Ops]

        let emptyPosition = try! JSONEncoder().encode(PositionManager())
        let pending = PendingTraining(
            trainingSetFilename: filename, globalTickIndex: pendingTick,
            upperPeriod: .m60, lowerPeriod: .daily,   // 必须是 periodCombos 阶梯里相邻一档（(m3,daily) 非法→switchPeriodCombo no-op）；默认 60分/日线（路线图 P1）
            positionData: emptyPosition, cashBalance: 100_000, feeSnapshot: fees,
            tradeOperations: [], drawings: [], startedAt: baseEpoch + 172_800,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0),
            sessionKey: "debug-fixture-pending")

        return Seed(trainingSetFilename: filename, meta: meta, candles: candles,
                    records: records, recordOps: recordOps, pending: pending, settings: .default)
    }
}
#endif
