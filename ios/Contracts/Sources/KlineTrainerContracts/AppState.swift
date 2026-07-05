// Kline Trainer Swift Contracts — M0.3 Application State
// Spec: kline_trainer_modules_v1.4.md §M0.3
//
// Codable key 命名契约（Plan 1c round 1 codex finding #2 回应）：
// 本文件内所有 struct **不含**显式 CodingKeys，遵循 spec M0.3。
// 模型层 JSON 默认输出 camelCase（`positionTier` 非 `position_tier`）。
// snake_case DB 列 ↔ camelCase Swift 属性的映射归 **Plan 3 P4 AppDB** 配置
// `ColumnDecodingStrategy.convertFromSnakeCase` + `ColumnEncodingStrategy.convertToSnakeCase`
// 在 GRDB `DatabaseMigrator` 层完成。若 P4 owner 发现某字段此规则不够（需显式
// 映射），bump Plan 1c 加 CodingKeys 再做。
// 参考：KLineCandle（Models.swift）和 RESTDTOs（RESTDTOs.swift）**有**显式
// CodingKeys 是特例（KLineCandle 防御性 spec 显式；RESTDTOs 走 JSONDecoder
// 非 GRDB，必须 struct 层桥接）。

import Foundation

// MARK: - Training Record

public struct TrainingRecord: Codable, Equatable, Sendable {
    public let id: Int64?
    public let trainingSetFilename: String
    public let createdAt: Int64
    public let stockCode: String
    public let stockName: String
    public let startYear: Int
    public let startMonth: Int
    public let totalCapital: Double
    public let profit: Double
    public let returnRate: Double
    public let maxDrawdown: Double
    public let buyCount: Int
    public let sellCount: Int
    public let feeSnapshot: FeeSnapshot
    public let finalTick: Int

    public init(
        id: Int64?, trainingSetFilename: String, createdAt: Int64,
        stockCode: String, stockName: String,
        startYear: Int, startMonth: Int,
        totalCapital: Double, profit: Double, returnRate: Double, maxDrawdown: Double,
        buyCount: Int, sellCount: Int,
        feeSnapshot: FeeSnapshot, finalTick: Int
    ) {
        self.id = id
        self.trainingSetFilename = trainingSetFilename
        self.createdAt = createdAt
        self.stockCode = stockCode
        self.stockName = stockName
        self.startYear = startYear
        self.startMonth = startMonth
        self.totalCapital = totalCapital
        self.profit = profit
        self.returnRate = returnRate
        self.maxDrawdown = maxDrawdown
        self.buyCount = buyCount
        self.sellCount = sellCount
        self.feeSnapshot = feeSnapshot
        self.finalTick = finalTick
    }
}

// MARK: - Drawdown Accumulator（v1.3 新增）

public struct DrawdownAccumulator: Codable, Equatable, Sendable {
    public var peakCapital: Double
    public var maxDrawdown: Double

    public init(peakCapital: Double, maxDrawdown: Double) {
        self.peakCapital = peakCapital
        self.maxDrawdown = maxDrawdown
    }

    /// 每 tick 或每次交易后调用。peakCapital 单调上升；maxDrawdown 单调上升（候选 = peak - current）。
    public mutating func update(currentCapital: Double) {
        if currentCapital > peakCapital { peakCapital = currentCapital }
        let dd = peakCapital - currentCapital
        if dd > maxDrawdown { maxDrawdown = dd }
    }

    public static let initial = DrawdownAccumulator(peakCapital: 0, maxDrawdown: 0)
}

// MARK: - Pending Training（含 cashBalance + drawdown；v1.3 denormalize）
// v1.6（Wave 3 10a）：+sessionKey（durable session key，RFC §4.7c）

// P1a Task 11：不再 Codable（`lossy: LossyDrawingArray` 非 Codable，见 ReviewWorking 同款先例）；
// 生产/测试均不依赖本结构体整体的 JSONEncoder/JSONDecoder 往返（repo 边界的 JSON 编解码走各字段独立
// jsonEncode/jsonDecode + LossyDrawingArray，不经本结构体的 Codable）。
public struct PendingTraining: Equatable, Sendable {
    public let trainingSetFilename: String
    public let globalTickIndex: Int
    public let upperPeriod: Period
    public let lowerPeriod: Period
    public let positionData: Data
    public let cashBalance: Double
    public let feeSnapshot: FeeSnapshot
    public let tradeOperations: [TradeOperation]
    public let lossy: LossyDrawingArray                        // 携带有序 known+unknown → repo 往返无损（P1a Task 11）
    public let startedAt: Int64
    public let accumulatedCapital: Double
    public let drawdown: DrawdownAccumulator
    public let sessionKey: String

    public var drawings: [DrawingObject] { lossy.drawings }    // 计算属性（下游消费不变）

    public init(
        trainingSetFilename: String,
        globalTickIndex: Int,
        upperPeriod: Period,
        lowerPeriod: Period,
        positionData: Data,
        cashBalance: Double,
        feeSnapshot: FeeSnapshot,
        tradeOperations: [TradeOperation],
        lossy: LossyDrawingArray,
        startedAt: Int64,
        accumulatedCapital: Double,
        drawdown: DrawdownAccumulator,
        sessionKey: String
    ) {
        self.trainingSetFilename = trainingSetFilename
        self.globalTickIndex = globalTickIndex
        self.upperPeriod = upperPeriod
        self.lowerPeriod = lowerPeriod
        self.positionData = positionData
        self.cashBalance = cashBalance
        self.feeSnapshot = feeSnapshot
        self.tradeOperations = tradeOperations
        self.lossy = lossy
        self.startedAt = startedAt
        self.accumulatedCapital = accumulatedCapital
        self.drawdown = drawdown
        self.sessionKey = sessionKey
    }

    /// 便捷 init：coordinator fresh save 用（纯已知；活编辑保住 unknown = P1b 引擎携带 lossy，§Y）。
    public init(
        trainingSetFilename: String,
        globalTickIndex: Int,
        upperPeriod: Period,
        lowerPeriod: Period,
        positionData: Data,
        cashBalance: Double,
        feeSnapshot: FeeSnapshot,
        tradeOperations: [TradeOperation],
        drawings: [DrawingObject],
        startedAt: Int64,
        accumulatedCapital: Double,
        drawdown: DrawdownAccumulator,
        sessionKey: String
    ) {
        self.init(
            trainingSetFilename: trainingSetFilename,
            globalTickIndex: globalTickIndex,
            upperPeriod: upperPeriod,
            lowerPeriod: lowerPeriod,
            positionData: positionData,
            cashBalance: cashBalance,
            feeSnapshot: feeSnapshot,
            tradeOperations: tradeOperations,
            lossy: LossyDrawingArray(drawings: drawings),
            startedAt: startedAt,
            accumulatedCapital: accumulatedCapital,
            drawdown: drawdown,
            sessionKey: sessionKey
        )
    }
}

// MARK: - Pending Replay（新需求10 replay 续局；镜像 PendingTraining，去 sessionKey，加 recordId）

// P1a Task 11：不再 Codable（同 PendingTraining 上方注释，`lossy: LossyDrawingArray` 非 Codable）。
public struct PendingReplay: Equatable, Sendable {
    public let recordId: Int64
    public let trainingSetFilename: String
    public let globalTickIndex: Int
    public let upperPeriod: Period
    public let lowerPeriod: Period
    public let positionData: Data
    public let cashBalance: Double
    public let feeSnapshot: FeeSnapshot
    public let tradeOperations: [TradeOperation]
    public let lossy: LossyDrawingArray                        // 携带有序 known+unknown → repo 往返无损（P1a Task 11）
    public let startedAt: Int64
    public let accumulatedCapital: Double
    public let drawdown: DrawdownAccumulator

    public var drawings: [DrawingObject] { lossy.drawings }    // 计算属性（下游消费不变）

    public init(
        recordId: Int64,
        trainingSetFilename: String,
        globalTickIndex: Int,
        upperPeriod: Period,
        lowerPeriod: Period,
        positionData: Data,
        cashBalance: Double,
        feeSnapshot: FeeSnapshot,
        tradeOperations: [TradeOperation],
        lossy: LossyDrawingArray,
        startedAt: Int64,
        accumulatedCapital: Double,
        drawdown: DrawdownAccumulator
    ) {
        self.recordId = recordId
        self.trainingSetFilename = trainingSetFilename
        self.globalTickIndex = globalTickIndex
        self.upperPeriod = upperPeriod
        self.lowerPeriod = lowerPeriod
        self.positionData = positionData
        self.cashBalance = cashBalance
        self.feeSnapshot = feeSnapshot
        self.tradeOperations = tradeOperations
        self.lossy = lossy
        self.startedAt = startedAt
        self.accumulatedCapital = accumulatedCapital
        self.drawdown = drawdown
    }

    /// 便捷 init：coordinator fresh save 用（纯已知；活编辑保住 unknown = P1b 引擎携带 lossy，§Y）。
    public init(
        recordId: Int64,
        trainingSetFilename: String,
        globalTickIndex: Int,
        upperPeriod: Period,
        lowerPeriod: Period,
        positionData: Data,
        cashBalance: Double,
        feeSnapshot: FeeSnapshot,
        tradeOperations: [TradeOperation],
        drawings: [DrawingObject],
        startedAt: Int64,
        accumulatedCapital: Double,
        drawdown: DrawdownAccumulator
    ) {
        self.init(
            recordId: recordId,
            trainingSetFilename: trainingSetFilename,
            globalTickIndex: globalTickIndex,
            upperPeriod: upperPeriod,
            lowerPeriod: lowerPeriod,
            positionData: positionData,
            cashBalance: cashBalance,
            feeSnapshot: feeSnapshot,
            tradeOperations: tradeOperations,
            lossy: LossyDrawingArray(drawings: drawings),
            startedAt: startedAt,
            accumulatedCapital: accumulatedCapital,
            drawdown: drawdown
        )
    }
}

// MARK: - Training Set File (NOT Codable: localURL is runtime filesystem reference; P5 CacheManager scope)

public struct TrainingSetFile: Equatable, Sendable {
    public let id: Int
    public let filename: String
    public let localURL: URL
    public let schemaVersion: Int
    public let lastAccessedAt: Int64
    public let downloadedAt: Int64

    public init(
        id: Int, filename: String, localURL: URL,
        schemaVersion: Int, lastAccessedAt: Int64, downloadedAt: Int64
    ) {
        self.id = id
        self.filename = filename
        self.localURL = localURL
        self.schemaVersion = schemaVersion
        self.lastAccessedAt = lastAccessedAt
        self.downloadedAt = downloadedAt
    }
}

// MARK: - App Settings (NOT Codable: stored per-field in app.sqlite settings table; P6 SettingsStore scope)

public struct AppSettings: Equatable, Sendable {
    public var commissionRate: Double
    public var minCommissionEnabled: Bool
    public var totalCapital: Double
    public var displayMode: DisplayMode

    public init(commissionRate: Double, minCommissionEnabled: Bool, totalCapital: Double, displayMode: DisplayMode) {
        self.commissionRate = commissionRate
        self.minCommissionEnabled = minCommissionEnabled
        self.totalCapital = totalCapital
        self.displayMode = displayMode
    }
}

public extension AppSettings {
    /// 单一来源：初始/重置资金 10 万元（plan_v1.5 §6.4 + L861）。
    /// AppSettings.default、loadSettings 缺键默认、resetCapital、TrainingResetPort 重置目标 统一引用，杜绝魔法数漂移。
    static let defaultTotalCapital: Double = 100_000
}

// MARK: - Named default (Wave 2 顺位 10 引入；P6 forceResetAndReload reset 目标值)
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四：
// 含合理起始本金（非 0 资本）的命名默认值；不复用 capital 0 的 SettingsStore.zeroDefault。
public extension AppSettings {
    static let `default` = AppSettings(
        commissionRate: 0.0001,      // §6.4 佣金初始值 1（万分之一）
        minCommissionEnabled: false, // §6.4 未规定 免5 初始值；false=免5（无最低 5 元）
        totalCapital: AppSettings.defaultTotalCapital,   // §6.4 重置资金 → 10 万元
        displayMode: .system)
}
