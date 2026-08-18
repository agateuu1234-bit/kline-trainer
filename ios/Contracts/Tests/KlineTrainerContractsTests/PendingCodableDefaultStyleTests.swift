import Testing
import Foundation
@testable import KlineTrainerContracts

/// 最小 PendingTraining 工厂（值复用 AppStateTests.swift 里的既有样例）。
private enum PendingTrainingFixture {
    static func make(drawingDefaultStyle: DrawingDefaultStyle?) throws -> PendingTraining {
        try PendingTraining(
            trainingSetFilename: "foo.zip",
            globalTickIndex: 10,
            upperPeriod: .daily,
            lowerPeriod: .m60,
            positionData: Data([1, 2, 3]),
            cashBalance: 9000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [],
            drawings: [],
            startedAt: 1_700_000_000,
            accumulatedCapital: 10_000,
            drawdown: DrawdownAccumulator(peakCapital: 10_000, maxDrawdown: 500),
            sessionKey: "SK-test",
            drawingDefaultStyle: drawingDefaultStyle
        )
    }
}

/// 最小 PendingReplay 工厂（值复用 CoordinatorReplayPersistenceTests.swift 里的 `makeSlot`）。
private enum PendingReplayFixture {
    static func make(drawingDefaultStyle: DrawingDefaultStyle?) throws -> PendingReplay {
        try PendingReplay(
            recordId: 1,
            trainingSetFilename: "rec.sqlite",
            globalTickIndex: 1,
            upperPeriod: .m60,
            lowerPeriod: .daily,
            positionData: Data(),
            cashBalance: 100_000,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            tradeOperations: [],
            drawings: [],
            startedAt: 1,
            accumulatedCapital: 100_000,
            drawdown: DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0),
            drawingDefaultStyle: drawingDefaultStyle
        )
    }
}

@Suite("Pending* 的 Codable 契约：drawingDefaultStyle")
struct PendingCodableDefaultStyleTests {

    private func nonDefaultStyle() -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash3; s.thickness = 4
        s.colorToken = .cyan; s.labelMode = .right
        return s
    }

    /// T17：PendingTraining 的 Codable 往返 —— DB 路径不走 Codable，
    /// 漏掉 encodeIfPresent 时所有 DB 边界测试仍全绿，故这条不可省。
    @Test func pendingTraining_codable_roundtrip_preserves_style() throws {
        let s = nonDefaultStyle()
        let p = try PendingTrainingFixture.make(drawingDefaultStyle: s)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PendingTraining.self, from: data)
        #expect(back.drawingDefaultStyle == s)
    }

    /// T17b：PendingReplay 同上
    @Test func pendingReplay_codable_roundtrip_preserves_style() throws {
        let s = nonDefaultStyle()
        let p = try PendingReplayFixture.make(drawingDefaultStyle: s)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PendingReplay.self, from: data)
        #expect(back.drawingDefaultStyle == s)
    }

    /// T18：旧载荷（无该 key）→ 解码成功且为 nil，其余字段照常。**两个模型各一条**。
    /// ⚠️ `PendingTraining` 与 `PendingReplay` 各有**自己的**显式 `init(from:)`
    ///    ⇒ 只测一个，另一个可以照样写成 `decode` 而把旧 replay 载荷 brick 掉
    ///    （codex plan-P-R5 medium②；与 D100「N 条独立路径就要 N 份测试」同一条纪律）。
    @Test func old_pendingTraining_payload_without_key_decodes_to_nil() throws {
        let p = try PendingTrainingFixture.make(drawingDefaultStyle: nil)
        var obj = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(p)) as! [String: Any]
        obj.removeValue(forKey: "drawingDefaultStyle")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(PendingTraining.self, from: data)
        #expect(back.drawingDefaultStyle == nil)
        #expect(back.globalTickIndex == p.globalTickIndex)   // 其余字段未受影响
    }

    @Test func old_pendingReplay_payload_without_key_decodes_to_nil() throws {
        let p = try PendingReplayFixture.make(drawingDefaultStyle: nil)
        var obj = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(p)) as! [String: Any]
        obj.removeValue(forKey: "drawingDefaultStyle")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(PendingReplay.self, from: data)
        #expect(back.drawingDefaultStyle == nil)
        #expect(back.recordId == p.recordId)                 // 其余字段未受影响
    }
}
