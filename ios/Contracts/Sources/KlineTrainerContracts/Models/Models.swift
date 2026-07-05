// Kline Trainer Swift Contracts — F1 Models 模块（承载 M0.3 数据模型）
// Spec: kline_trainer_modules_v1.4.md §五 F1（L811-815） + §三 M0.3

import Foundation

/// 顶层契约版本号。bump 策略见 docs/contracts/contract-version-matrix.md（Plan 1f 落地）。
public let CONTRACT_VERSION = "1.11"

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
    // 目标 11 工具
    case horizontal, trend, channel, polyline, golden, wave, cycle, fib, timeRuler, rect, text
    // legacy（历史 blob 容忍解码；ray 已下沉为线型子类、time 语义歧义——见 spec §4.1/D2）
    case ray, time
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

    /// 持久化解码边界守卫：清除 legacy 负 / 非有限 commissionRate（老 app 存入前无非负约束）。
    /// 腐坏值替换为 AppSettings.default.commissionRate；其余字段原样保留。
    /// 合法值原样返回（无拷贝开销：struct 值语义 + 编译器 copy-elision）。
    public func sanitizedForLegacyCorruption() -> FeeSnapshot {
        guard commissionRate >= 0, commissionRate.isFinite else {
            return FeeSnapshot(
                commissionRate: AppSettings.default.commissionRate,
                minCommissionEnabled: minCommissionEnabled
            )
        }
        return self
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
    public let id: DrawingID                 // 跨层防碰撞身份（§4.2/D13/D16）
    public let toolType: DrawingToolType
    public let anchors: [DrawingAnchor]
    public let period: Period                // 渲染绑定周期（§10）
    public let lineSubType: LineSubType
    public let lineStyle: LineStyle
    public let thickness: Int                // 1…5
    public let colorToken: DrawingColorToken
    public let labelMode: LabelMode
    public let locked: Bool
    public let text: String
    public let fontSize: Int
    public let textColorToken: DrawingColorToken
    public let textForm: TextForm
    public let tailAnchor: DrawingAnchor?    // 标注气泡尾巴尖；仅带框两形式有值（§5.10/D11）
    public let isExtended: Bool              // 保留（兼容/派生）
    public let panelPosition: Int            // 保留但不再作渲染绑定（§10）
    /// review-redesign 整改④：提交这条画线时会话所处的全局 tick（= 渐显时机；锚点仅定位几何，不再决定渐显）。
    public let revealTick: Int

    public init(id: DrawingID = UUID().uuidString,
                toolType: DrawingToolType, anchors: [DrawingAnchor],
                isExtended: Bool, panelPosition: Int, revealTick: Int = 0,
                period: Period? = nil,
                lineSubType: LineSubType = .straight, lineStyle: LineStyle = .solid,
                thickness: Int = 1, colorToken: DrawingColorToken = .orange,
                labelMode: LabelMode = .hidden, locked: Bool = false,
                text: String = "", fontSize: Int = 14,
                textColorToken: DrawingColorToken = .orange, textForm: TextForm = .plain,
                tailAnchor: DrawingAnchor? = nil) {
        self.id = id
        self.toolType = toolType
        self.anchors = anchors
        self.period = period ?? anchors.first?.period ?? .daily
        self.lineSubType = lineSubType
        self.lineStyle = lineStyle
        self.thickness = thickness
        self.colorToken = colorToken
        self.labelMode = labelMode
        self.locked = locked
        self.text = text
        self.fontSize = fontSize
        self.textColorToken = textColorToken
        self.textForm = textForm
        self.tailAnchor = tailAnchor
        self.isExtended = isExtended
        self.panelPosition = panelPosition
        self.revealTick = revealTick
    }

    private enum CodingKeys: String, CodingKey {
        case id, toolType, anchors, period, lineSubType, lineStyle, thickness
        case colorToken, labelMode, locked, text, fontSize, textColorToken, textForm, tailAnchor
        case isExtended, panelPosition, revealTick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolType = try c.decode(DrawingToolType.self, forKey: .toolType)
        self.anchors = try c.decode([DrawingAnchor].self, forKey: .anchors)
        self.isExtended = try c.decode(Bool.self, forKey: .isExtended)
        self.panelPosition = try c.decode(Int.self, forKey: .panelPosition)
        // 向后兼容：旧 blob 无 revealTick → 0（从起点起可见）。
        self.revealTick = try c.decodeIfPresent(Int.self, forKey: .revealTick) ?? 0
        // 新字段：旧 blob 无 → 语义默认（沿 revealTick 先例）
        // 无 id → 解码为空串（非随机 UUID）：数组层（Task 5）按位回填 legacy-idx-<N>，
        // 若这里生成随机 UUID 会让"无 id"不可侦测。
        self.id = try c.decodeIfPresent(DrawingID.self, forKey: .id) ?? ""
        self.period = try c.decodeIfPresent(Period.self, forKey: .period)
            ?? self.anchors.first?.period ?? .daily
        // isExtended:true → .ray；false → .straight（旧语义迁移，§4.2）
        self.lineSubType = try c.decodeIfPresent(LineSubType.self, forKey: .lineSubType)
            ?? (self.isExtended ? .ray : .straight)
        self.lineStyle = try c.decodeIfPresent(LineStyle.self, forKey: .lineStyle) ?? .solid
        self.thickness = try c.decodeIfPresent(Int.self, forKey: .thickness) ?? 1
        self.colorToken = try c.decodeIfPresent(DrawingColorToken.self, forKey: .colorToken) ?? .orange
        self.labelMode = try c.decodeIfPresent(LabelMode.self, forKey: .labelMode) ?? .hidden
        self.locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 14
        self.textColorToken = try c.decodeIfPresent(DrawingColorToken.self, forKey: .textColorToken) ?? .orange
        self.textForm = try c.decodeIfPresent(TextForm.self, forKey: .textForm) ?? .plain
        self.tailAnchor = try c.decodeIfPresent(DrawingAnchor.self, forKey: .tailAnchor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(toolType, forKey: .toolType)
        try c.encode(anchors, forKey: .anchors)
        try c.encode(period, forKey: .period)
        try c.encode(lineSubType, forKey: .lineSubType)
        try c.encode(lineStyle, forKey: .lineStyle)
        try c.encode(thickness, forKey: .thickness)
        try c.encode(colorToken, forKey: .colorToken)
        try c.encode(labelMode, forKey: .labelMode)
        try c.encode(locked, forKey: .locked)
        try c.encode(text, forKey: .text)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(textColorToken, forKey: .textColorToken)
        try c.encode(textForm, forKey: .textForm)
        try c.encodeIfPresent(tailAnchor, forKey: .tailAnchor)
        try c.encode(isExtended, forKey: .isExtended)
        try c.encode(panelPosition, forKey: .panelPosition)
        try c.encode(revealTick, forKey: .revealTick)
    }

    // 自定义 `==`：故意不比较 `id`。`id` 是跨层身份/去重键（供 Task 5+ 按 id 精确匹配），
    // 默认 init 每次生成新随机 UUID——若纳入 Equatable，既有测试里两次独立调用同一
    // 5 参 helper（内容相同、id 各自随机）构造的"预期值"与"实际值"会被判不等，
    // 误伤 27 个既有测试（内容语义相同，只是 id 巧合不同）。
    public static func == (lhs: DrawingObject, rhs: DrawingObject) -> Bool {
        lhs.toolType == rhs.toolType && lhs.anchors == rhs.anchors && lhs.period == rhs.period
            && lhs.lineSubType == rhs.lineSubType && lhs.lineStyle == rhs.lineStyle
            && lhs.thickness == rhs.thickness && lhs.colorToken == rhs.colorToken
            && lhs.labelMode == rhs.labelMode && lhs.locked == rhs.locked
            && lhs.text == rhs.text && lhs.fontSize == rhs.fontSize
            && lhs.textColorToken == rhs.textColorToken && lhs.textForm == rhs.textForm
            && lhs.tailAnchor == rhs.tailAnchor && lhs.isExtended == rhs.isExtended
            && lhs.panelPosition == rhs.panelPosition && lhs.revealTick == rhs.revealTick
    }
}

// MARK: - Trade Marker (UI overlay; NOT Codable per spec M0.3 — runtime only)

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
