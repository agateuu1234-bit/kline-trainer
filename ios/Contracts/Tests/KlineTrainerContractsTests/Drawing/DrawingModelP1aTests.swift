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
