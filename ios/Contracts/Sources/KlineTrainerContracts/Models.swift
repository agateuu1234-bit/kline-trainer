// Kline Trainer Swift Contracts — M0.3
// Spec: kline_trainer_modules_v1.4.md §M0.3

import Foundation

/// 顶层契约版本号。bump 策略见 docs/contracts/contract-version-matrix.md（Plan 1f 落地）。
public let CONTRACT_VERSION = "1.4"

// MARK: - Enums

public enum Period: String, Codable, Equatable, Sendable, CaseIterable {
    case m3 = "3m"
    case m15 = "15m"
    case m60 = "60m"
    case daily
    case weekly
    case monthly
}

public enum TradeDirection: String, Codable, Equatable, Sendable {
    case buy
    case sell
}

public enum PositionTier: String, Codable, Equatable, Sendable, CaseIterable {
    case tier1 = "1/5"
    case tier2 = "2/5"
    case tier3 = "3/5"
    case tier4 = "4/5"
    case tier5 = "5/5"
}

public enum TrainingMode: Equatable, Sendable {
    case normal, review, replay
}

public enum DrawingToolType: String, Codable, Equatable, Sendable {
    case ray, trend, horizontal, golden, wave, cycle, time
}

public enum DisplayMode: String, Codable, Equatable, Sendable {
    case light, dark, system
}

public enum PanelId: Equatable, Sendable {
    case upper, lower
}

public enum SwipeDirection: Equatable, Sendable {
    case up, down
}

public enum PeriodDirection: Equatable, Sendable {
    case toLarger, toSmaller
}

// MARK: - K Line

public struct KLineCandle: Codable, Equatable, Sendable {
    public let period: Period
    public let datetime: Int64
    public let open, high, low, close: Double
    public let volume: Int64
    public let amount: Double?
    public let ma66: Double?
    public let bollUpper: Double?
    public let bollMid: Double?
    public let bollLower: Double?
    public let macdDiff: Double?
    public let macdDea: Double?
    public let macdBar: Double?
    public let globalIndex: Int?
    public let endGlobalIndex: Int

    public init(
        period: Period, datetime: Int64,
        open: Double, high: Double, low: Double, close: Double,
        volume: Int64, amount: Double?,
        ma66: Double?,
        bollUpper: Double?, bollMid: Double?, bollLower: Double?,
        macdDiff: Double?, macdDea: Double?, macdBar: Double?,
        globalIndex: Int?, endGlobalIndex: Int
    ) {
        self.period = period
        self.datetime = datetime
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.volume = volume
        self.amount = amount
        self.ma66 = ma66
        self.bollUpper = bollUpper
        self.bollMid = bollMid
        self.bollLower = bollLower
        self.macdDiff = macdDiff
        self.macdDea = macdDea
        self.macdBar = macdBar
        self.globalIndex = globalIndex
        self.endGlobalIndex = endGlobalIndex
    }

    enum CodingKeys: String, CodingKey {
        case period, datetime, open, high, low, close, volume, amount, ma66
        case bollUpper = "boll_upper"
        case bollMid = "boll_mid"
        case bollLower = "boll_lower"
        case macdDiff = "macd_diff"
        case macdDea = "macd_dea"
        case macdBar = "macd_bar"
        case globalIndex = "global_index"
        case endGlobalIndex = "end_global_index"
    }
}

public struct TrainingSetMeta: Codable, Equatable, Sendable {
    public let stockCode: String
    public let stockName: String
    public let startDatetime: Int64
    public let endDatetime: Int64

    public init(stockCode: String, stockName: String, startDatetime: Int64, endDatetime: Int64) {
        self.stockCode = stockCode
        self.stockName = stockName
        self.startDatetime = startDatetime
        self.endDatetime = endDatetime
    }

    // 显式 CodingKeys（codex round 4 finding）：TrainingSetMeta 从 training-set
    // SQLite 的 meta 表读出（plan v1.5 §3.2 列名 stock_code/stock_name/
    // start_datetime/end_datetime）。与 KLineCandle 同一 P3b TrainingSetReader
    // 边界；两者对称地显式声明，避免依赖 P3 GRDB convertFromSnakeCase 配置。
    enum CodingKeys: String, CodingKey {
        case stockCode = "stock_code"
        case stockName = "stock_name"
        case startDatetime = "start_datetime"
        case endDatetime = "end_datetime"
    }
}

// MARK: - Fees / Trades

public struct FeeSnapshot: Codable, Equatable, Sendable {
    public let commissionRate: Double
    public let minCommissionEnabled: Bool

    public init(commissionRate: Double, minCommissionEnabled: Bool) {
        self.commissionRate = commissionRate
        self.minCommissionEnabled = minCommissionEnabled
    }
}

public struct TradeOperation: Codable, Equatable, Sendable {
    public let globalTick: Int
    public let period: Period
    public let direction: TradeDirection
    public let price: Double
    public let shares: Int
    public let positionTier: PositionTier
    public let commission: Double
    public let stampDuty: Double
    public let totalCost: Double
    public let createdAt: Int64

    public init(
        globalTick: Int, period: Period, direction: TradeDirection,
        price: Double, shares: Int, positionTier: PositionTier,
        commission: Double, stampDuty: Double, totalCost: Double,
        createdAt: Int64
    ) {
        self.globalTick = globalTick
        self.period = period
        self.direction = direction
        self.price = price
        self.shares = shares
        self.positionTier = positionTier
        self.commission = commission
        self.stampDuty = stampDuty
        self.totalCost = totalCost
        self.createdAt = createdAt
    }
}

public struct DrawingAnchor: Codable, Equatable, Sendable {
    public let period: Period
    public let candleIndex: Int
    public let price: Double

    public init(period: Period, candleIndex: Int, price: Double) {
        self.period = period
        self.candleIndex = candleIndex
        self.price = price
    }
}

public struct DrawingObject: Codable, Equatable, Sendable {
    public let toolType: DrawingToolType
    public let anchors: [DrawingAnchor]
    public let isExtended: Bool
    public let panelPosition: Int

    public init(toolType: DrawingToolType, anchors: [DrawingAnchor], isExtended: Bool, panelPosition: Int) {
        self.toolType = toolType
        self.anchors = anchors
        self.isExtended = isExtended
        self.panelPosition = panelPosition
    }
}

public struct TradeMarker: Equatable, Sendable {
    public let globalTick: Int
    public let price: Double
    public let direction: TradeDirection

    public init(globalTick: Int, price: Double, direction: TradeDirection) {
        self.globalTick = globalTick
        self.price = price
        self.direction = direction
    }
}
