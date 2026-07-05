import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("Drawing P1a — 支撑枚举")
struct DrawingEnumsTests {
    @Test("五枚举 rawValue 稳定 + CaseIterable 计数")
    func rawValuesStable() {
        #expect(LineSubType.allCases.map(\.rawValue) == ["straight", "ray", "segment"])
        #expect(LineStyle.allCases.map(\.rawValue) == ["solid", "dash1", "dash2", "dash3", "dash4"])
        #expect(DrawingColorToken.allCases.map(\.rawValue)
            == ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "black", "white"])
        #expect(LabelMode.allCases.map(\.rawValue) == ["hidden", "show", "left", "right"])
        #expect(TextForm.allCases.map(\.rawValue) == ["borderTransparent", "borderFilled", "plain"])
    }

    @Test("DrawingID 是 String 别名")
    func drawingIdIsString() {
        let id: DrawingID = "gen-abc"
        #expect(id == "gen-abc")
    }
}

@Suite("Drawing P1a — DrawingToolType 11 工具")
struct DrawingToolTypeExpansionTests {
    @Test("新增 6 工具 case + 保留 legacy ray/time 可解码")
    func elevenPlusLegacy() throws {
        // 11 目标工具都能从 rawValue 构造
        for raw in ["horizontal", "trend", "channel", "polyline", "golden",
                    "wave", "cycle", "fib", "timeRuler", "text", "rect"] {
            #expect(DrawingToolType(rawValue: raw) != nil, "缺工具 \(raw)")
        }
        // legacy 两 case 仍可解码（历史 blob 兼容）
        #expect(DrawingToolType(rawValue: "ray") == .ray)
        #expect(DrawingToolType(rawValue: "time") == .time)
    }
}

@Suite("Drawing P1a — DrawingObject 全字段 Codable")
struct DrawingObjectCodableTests {
    private func sampleAnchor() -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.5)
    }

    @Test("全字段编码→解码往返一致")
    func fullRoundTrip() throws {
        let d = DrawingObject(
            id: "gen-1", toolType: .trend, anchors: [sampleAnchor(), sampleAnchor()],
            isExtended: true, panelPosition: 1, revealTick: 42,
            period: .m60, lineSubType: .segment, lineStyle: .dash2, thickness: 4,
            colorToken: .blue, labelMode: .right, locked: true,
            text: "颈线", fontSize: 20, textColorToken: .red, textForm: .borderFilled,
            tailAnchor: sampleAnchor())
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(back == d)
    }

    @Test("tailAnchor 为 nil 时全字段往返一致（encodeIfPresent 不写 key，decodeIfPresent 读回 nil）")
    func roundTripTailAnchorNil() throws {
        let d = DrawingObject(
            id: "gen-2", toolType: .horizontal, anchors: [sampleAnchor()],
            isExtended: false, panelPosition: 0, revealTick: 5,
            period: .m60, lineSubType: .straight, lineStyle: .solid, thickness: 2,
            colorToken: .green, labelMode: .show, locked: false,
            text: "", fontSize: 14, textColorToken: .orange, textForm: .plain,
            tailAnchor: nil)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(back == d)
        #expect(back.tailAnchor == nil)
    }

    @Test("旧 blob（仅 5 字段）解码 → 新字段取语义默认")
    func legacyBlobDefaults() throws {
        // 模拟 #139 时代的 DrawingObject JSON（无新字段）
        let legacy = """
        {"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":2,"price":9.9}],
         "isExtended":true,"panelPosition":0,"revealTick":7}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(DrawingObject.self, from: legacy)
        #expect(d.lineSubType == .ray)          // isExtended:true → .ray（迁移映射）
        #expect(d.lineStyle == .solid)
        #expect(d.thickness == 1)
        #expect(d.colorToken == .orange)
        #expect(d.labelMode == .hidden)
        #expect(d.locked == false)
        #expect(d.text == "")
        #expect(d.tailAnchor == nil)
        #expect(d.period == .m3)                // 取 anchors.first.period
        #expect(d.id.isEmpty == true)            // 无 id → 解码为空串（Task 5 数组层按位回填 legacy-idx-<N>）
    }
}
