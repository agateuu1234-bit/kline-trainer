import Testing
@testable import KlineTrainerContracts

@Suite struct GestureRoutingTests {
    @Test("两指上滑 → toLarger（较大/较粗周期）")
    func upToLarger() { #expect(periodDirection(for: .up) == .toLarger) }

    @Test("两指下滑 → toSmaller（较小/较细周期）")
    func downToSmaller() { #expect(periodDirection(for: .down) == .toSmaller) }
}
