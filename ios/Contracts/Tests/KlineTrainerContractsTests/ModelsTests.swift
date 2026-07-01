import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("Contract version")
struct ContractVersionTests {
    @Test func contractVersionIs1_7() {
        #expect(CONTRACT_VERSION == "1.8")
    }
}

@Suite("Enum Codable round-trip")
struct EnumRoundTripTests {
    @Test func period_encodesToRawString() throws {
        let data = try JSONEncoder().encode(Period.m60)
        let str = String(data: data, encoding: .utf8)!
        #expect(str == "\"60m\"")
    }

    @Test func period_decodesFromRawString() throws {
        let data = "\"3m\"".data(using: .utf8)!
        let p = try JSONDecoder().decode(Period.self, from: data)
        #expect(p == .m3)
    }

    @Test func tradeDirection_roundTrip() throws {
        let encoded = try JSONEncoder().encode(TradeDirection.buy)
        let decoded = try JSONDecoder().decode(TradeDirection.self, from: encoded)
        #expect(decoded == .buy)
    }

    @Test func positionTier_rawValuesAreFractions() {
        #expect(PositionTier.tier1.rawValue == "1/5")
        #expect(PositionTier.tier5.rawValue == "5/5")
    }

    @Test func displayMode_allCasesCodable() throws {
        for mode in [DisplayMode.light, .dark, .system] {
            let d = try JSONEncoder().encode(mode)
            let r = try JSONDecoder().decode(DisplayMode.self, from: d)
            #expect(r == mode)
        }
    }

    @Test func drawingToolType_allSevenCases() {
        let all: [DrawingToolType] = [.ray, .trend, .horizontal, .golden, .wave, .cycle, .time]
        #expect(all.count == 7)
        for t in all {
            #expect(DrawingToolType(rawValue: t.rawValue) == t)
        }
    }
}

@Suite("TrainingSetMeta Codable")
struct TrainingSetMetaTests {
    /// snake_case CodingKeys 对齐 training-set SQLite meta 表（plan v1.5 §3.2）。
    /// 与 KLineCandle 同为 P3b TrainingSetReader 边界契约（codex round 4）。
    @Test func snakeCaseCodingKeys_matchMetaTableColumns() throws {
        let meta = TrainingSetMeta(
            stockCode: "600519",
            stockName: "贵州茅台",
            startDatetime: 1_700_000_000,
            endDatetime: 1_710_000_000
        )
        let data = try JSONEncoder().encode(meta)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"stock_code\":\"600519\""))
        #expect(json.contains("\"stock_name\":\"贵州茅台\""))
        #expect(json.contains("\"start_datetime\":1700000000"))
        #expect(json.contains("\"end_datetime\":1710000000"))
    }

    @Test func decodesFromSnakeCaseJSON() throws {
        let json = """
        {"stock_code":"AAPL","stock_name":"Apple","start_datetime":1700000000,"end_datetime":1710000000}
        """.data(using: .utf8)!
        let meta = try JSONDecoder().decode(TrainingSetMeta.self, from: json)
        #expect(meta.stockCode == "AAPL")
        #expect(meta.startDatetime == 1_700_000_000)
    }
}

@Suite("KLineCandle Codable")
struct KLineCandleTests {
    @Test func snakeCaseCodingKeys_forBollAndMacdAndIndex() throws {
        let candle = KLineCandle(
            period: .daily,
            datetime: 1_700_000_000,
            open: 10.0, high: 11.0, low: 9.5, close: 10.5,
            volume: 1_000_000,
            amount: 10_500_000.5,
            ma66: 10.3,
            bollUpper: 11.2, bollMid: 10.4, bollLower: 9.6,
            macdDiff: 0.12, macdDea: 0.08, macdBar: 0.04,
            globalIndex: 42,
            endGlobalIndex: 42
        )
        let data = try JSONEncoder().encode(candle)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"boll_upper\":11.2"))
        #expect(json.contains("\"boll_mid\":10.4"))
        #expect(json.contains("\"boll_lower\":9.6"))
        #expect(json.contains("\"macd_diff\":0.12"))
        #expect(json.contains("\"macd_dea\":0.08"))
        #expect(json.contains("\"macd_bar\":0.04"))
        #expect(json.contains("\"global_index\":42"))
        #expect(json.contains("\"end_global_index\":42"))
    }

    @Test func roundTrip_withOptionalNils() throws {
        let candle = KLineCandle(
            period: .monthly,
            datetime: 1_700_000_000,
            open: 1, high: 1, low: 1, close: 1,
            volume: 0,
            amount: nil,
            ma66: nil,
            bollUpper: nil, bollMid: nil, bollLower: nil,
            macdDiff: nil, macdDea: nil, macdBar: nil,
            globalIndex: nil,
            endGlobalIndex: 0
        )
        let data = try JSONEncoder().encode(candle)
        let decoded = try JSONDecoder().decode(KLineCandle.self, from: data)
        #expect(decoded == candle)
    }
}

@Suite("TradeOperation Codable")
struct TradeOperationTests {
    @Test func positionTier_encodesAsRawValue() throws {
        let op = TradeOperation(
            globalTick: 100, period: .m15, direction: .buy,
            price: 12.34, shares: 200, positionTier: .tier3,
            commission: 1.23, stampDuty: 0.5, totalCost: 2470.73,
            createdAt: 1_700_000_000
        )
        let decoded = try JSONDecoder().decode(TradeOperation.self, from: JSONEncoder().encode(op))
        #expect(decoded.positionTier == .tier3)
        #expect(decoded.positionTier.rawValue == "3/5")
    }

    /// 契约约定：模型层 JSON 默认 camelCase；snake_case DB 列映射由 Plan 3 P4
    /// GRDB `.convertFromSnakeCase` 策略在 DAO 层完成。本测试锁定此契约边界，
    /// 让 P4 owner 看到预期。
    @Test func defaultEncoding_isCamelCase_notSnakeCase() throws {
        let op = TradeOperation(
            globalTick: 100, period: .m15, direction: .buy,
            price: 12.34, shares: 200, positionTier: .tier3,
            commission: 1.23, stampDuty: 0.5, totalCost: 2470.73,
            createdAt: 1_700_000_000
        )
        let json = String(data: try JSONEncoder().encode(op), encoding: .utf8)!
        // Positive: camelCase 字段出现
        #expect(json.contains("\"globalTick\":100"))
        #expect(json.contains("\"stampDuty\":0.5"))
        #expect(json.contains("\"totalCost\":2470.73"))
        #expect(json.contains("\"createdAt\":1700000000"))
        // Negative: snake_case 字段不出现（P4 DAO 层才做转换）
        #expect(!json.contains("\"global_tick\""))
        #expect(!json.contains("\"stamp_duty\""))
        #expect(!json.contains("\"total_cost\""))
        #expect(!json.contains("\"created_at\""))
    }
}

/// codex R1+R2+R4+R5+R7 findings 修：F1 PR scope narrow 到 Models.swift 内 11 个 Codable 类型
/// （codex R7 finding 1：AppState.swift 内 3 个 M0.3 Codable struct 在 H3 residual queue，未来 PR 闭环）。
/// 本 PR Models.swift inventory 的 ModelsTests 留下 8 个 gap：3 个 struct
/// (FeeSnapshot/DrawingAnchor/DrawingObject) 零覆盖 + 2 个 enum (PositionTier/DrawingToolType) 只检
/// rawValue + 3 个现有 gap (Period 分离 encode/decode 测试无完整链 / TrainingSetMeta 无 full equality /
/// TradeOperation 无 full equality)。本 Suite 把这 8 个 gap 闭环（characterization，非 TDD red→green；
/// M0.3 已实现 Codable）。
@Suite("Additional Codable round-trip (F1 verification gap closure)")
struct AdditionalCodableRoundTripTests {
    // —— 3 Struct round-trip（codex R1 finding 1）——

    @Test func feeSnapshot_roundTrip() throws {
        let original = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FeeSnapshot.self, from: data)
        #expect(decoded == original)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"commissionRate\":0.0001"))
        #expect(json.contains("\"minCommissionEnabled\":true"))
    }

    @Test func drawingAnchor_roundTrip() throws {
        let original = DrawingAnchor(period: .daily, candleIndex: 42, price: 123.45)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DrawingAnchor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.period == .daily)
        #expect(decoded.candleIndex == 42)
        #expect(decoded.price == 123.45)
    }

    @Test func drawingObject_roundTripWithMultipleAnchors() throws {
        let original = DrawingObject(
            toolType: .trend,
            anchors: [
                DrawingAnchor(period: .m15, candleIndex: 0, price: 10.0),
                DrawingAnchor(period: .m15, candleIndex: 5, price: 12.5)
            ],
            isExtended: true,
            panelPosition: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(decoded == original)
        #expect(decoded.toolType == .trend)
        #expect(decoded.anchors.count == 2)
        #expect(decoded.isExtended == true)
        #expect(decoded.panelPosition == 1)
    }

    // —— 2 Enum 真 JSON round-trip（codex R2 finding 1）——
    // codex R6 finding 2 修：用 semantic decode-string 比较（不依赖 JSON 字节 formatting；
    // PositionTier rawValue "1/5"-"5/5" 含 `/`，JSONEncoder 默认 escape 为 `\/`）。

    @Test func positionTier_jsonRoundTrip_encodesAsRawValueString() throws {
        for tier in PositionTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(PositionTier.self, from: data)
            #expect(decoded == tier)
            let decodedRaw = try JSONDecoder().decode(String.self, from: data)
            #expect(decodedRaw == tier.rawValue)  // 如 "3/5"
        }
    }

    @Test func drawingToolType_jsonRoundTrip_allSevenCases() throws {
        let all: [DrawingToolType] = [.ray, .trend, .horizontal, .golden, .wave, .cycle, .time]
        for tool in all {
            let data = try JSONEncoder().encode(tool)
            let decoded = try JSONDecoder().decode(DrawingToolType.self, from: data)
            #expect(decoded == tool)
            let decodedRaw = try JSONDecoder().decode(String.self, from: data)
            #expect(decodedRaw == tool.rawValue)
        }
    }

    // —— 3 现有 ModelsTests gap 闭环（codex R4 finding 1 + R5 finding 1）——

    @Test func period_jsonRoundTrip_allCases() throws {
        // codex R5 finding 1：现有 period_encodesToRawString / period_decodesFromRawString
        // 是分离两个测试（encode .m60 → "60m" / decode "3m" → .m3），无完整 round-trip + equality 链。
        for period in Period.allCases {
            let data = try JSONEncoder().encode(period)
            let decoded = try JSONDecoder().decode(Period.self, from: data)
            #expect(decoded == period)
            let decodedRaw = try JSONDecoder().decode(String.self, from: data)
            #expect(decodedRaw == period.rawValue)
        }
    }

    @Test func trainingSetMeta_fullRoundTrip_equality() throws {
        let original = TrainingSetMeta(
            stockCode: "600519",
            stockName: "贵州茅台",
            startDatetime: 1_700_000_000,
            endDatetime: 1_710_000_000
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrainingSetMeta.self, from: data)
        #expect(decoded == original)
        #expect(decoded.stockCode == "600519")
        #expect(decoded.stockName == "贵州茅台")
        #expect(decoded.startDatetime == 1_700_000_000)
        #expect(decoded.endDatetime == 1_710_000_000)
    }

    @Test func tradeOperation_fullRoundTrip_equality() throws {
        let original = TradeOperation(
            globalTick: 100,
            period: .m15,
            direction: .buy,
            price: 12.34,
            shares: 200,
            positionTier: .tier3,
            commission: 1.23,
            stampDuty: 0.5,
            totalCost: 2470.73,
            createdAt: 1_700_000_000
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TradeOperation.self, from: data)
        #expect(decoded == original)
        #expect(decoded.globalTick == 100)
        #expect(decoded.period == .m15)
        #expect(decoded.direction == .buy)
        #expect(decoded.price == 12.34)
        #expect(decoded.shares == 200)
        #expect(decoded.positionTier == .tier3)
        #expect(decoded.commission == 1.23)
        #expect(decoded.stampDuty == 0.5)
        #expect(decoded.totalCost == 2470.73)
        #expect(decoded.createdAt == 1_700_000_000)
    }
}
