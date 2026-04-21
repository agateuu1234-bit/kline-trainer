import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("Contract version")
struct ContractVersionTests {
    @Test func contractVersionIs1_4() {
        #expect(CONTRACT_VERSION == "1.4")
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
        #expect(json.contains("\"macd_diff\":0.12"))
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
