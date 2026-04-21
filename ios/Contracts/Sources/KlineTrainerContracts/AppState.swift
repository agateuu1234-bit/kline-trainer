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

public struct PendingTraining: Codable, Equatable, Sendable {
    public let trainingSetFilename: String
    public let globalTickIndex: Int
    public let upperPeriod: Period
    public let lowerPeriod: Period
    public let positionData: Data
    public let cashBalance: Double
    public let feeSnapshot: FeeSnapshot
    public let tradeOperations: [TradeOperation]
    public let drawings: [DrawingObject]
    public let startedAt: Int64
    public let accumulatedCapital: Double
    public let drawdown: DrawdownAccumulator

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
        drawdown: DrawdownAccumulator
    ) {
        self.trainingSetFilename = trainingSetFilename
        self.globalTickIndex = globalTickIndex
        self.upperPeriod = upperPeriod
        self.lowerPeriod = lowerPeriod
        self.positionData = positionData
        self.cashBalance = cashBalance
        self.feeSnapshot = feeSnapshot
        self.tradeOperations = tradeOperations
        self.drawings = drawings
        self.startedAt = startedAt
        self.accumulatedCapital = accumulatedCapital
        self.drawdown = drawdown
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
