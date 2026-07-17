// Tests/KlineTrainerContractsTests/Drawing/DrawingStyleAvailabilityTests.swift
// Spec: 母 spec §3.1 水平线可选矩阵 + §4.1.4 昼夜禁色。
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingStyleAvailability：水平线设置面板灰态判据（母 spec §3.1）")
struct DrawingStyleAvailabilityTests {
    typealias A = DrawingStyleAvailability

    @Test("线型子类：直线✅ 射线✅ 线段灰")
    func lineSubType() {
        #expect(A.horizontalLineSubTypeEnabled(.straight))
        #expect(A.horizontalLineSubTypeEnabled(.ray))
        #expect(!A.horizontalLineSubTypeEnabled(.segment))
    }

    @Test("标注：隐藏/左/右可选、显示恒灰；选射线时『左』再灰")
    func labelMode() {
        // 直线：隐藏/左/右可选，显示灰
        #expect(A.horizontalLabelModeEnabled(.hidden, lineSubType: .straight))
        #expect(A.horizontalLabelModeEnabled(.left,   lineSubType: .straight))
        #expect(A.horizontalLabelModeEnabled(.right,  lineSubType: .straight))
        #expect(!A.horizontalLabelModeEnabled(.show,  lineSubType: .straight))
        // 射线：左再灰
        #expect(!A.horizontalLabelModeEnabled(.left,  lineSubType: .ray))
        #expect(A.horizontalLabelModeEnabled(.right,  lineSubType: .ray))
        #expect(A.horizontalLabelModeEnabled(.hidden, lineSubType: .ray))
    }

    @Test("颜色：白天禁白、夜间禁黑，7 彩色恒可选")
    func color() {
        #expect(!A.colorEnabled(.white, scheme: .light))
        #expect(A.colorEnabled(.white, scheme: .dark))
        #expect(!A.colorEnabled(.black, scheme: .dark))
        #expect(A.colorEnabled(.black, scheme: .light))
        for c in [DrawingColorToken.red, .orange, .yellow, .green, .cyan, .blue, .purple] {
            #expect(A.colorEnabled(c, scheme: .light))
            #expect(A.colorEnabled(c, scheme: .dark))
        }
    }

    @Test("依赖字段规整：选『左』后切『射线』→ labelMode 回落 hidden（不留矛盾组合，codex plan-R1）")
    func normalizeLabelOnSubtypeChange() {
        // 直线下『左』合法 → 保留
        #expect(A.normalizedLabelMode(current: .left, lineSubType: .straight) == .left)
        // 切射线后『左』不可用 → 回落 hidden
        #expect(A.normalizedLabelMode(current: .left, lineSubType: .ray) == .hidden)
        // 合法值不动
        #expect(A.normalizedLabelMode(current: .right, lineSubType: .ray) == .right)
        #expect(A.normalizedLabelMode(current: .hidden, lineSubType: .ray) == .hidden)
    }
}
