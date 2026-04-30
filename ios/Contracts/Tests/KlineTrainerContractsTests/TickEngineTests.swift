import Testing
@testable import KlineTrainerContracts

@Suite("TickEngine")
struct TickEngineTests {

    @Test("init default initialTick = 0")
    func initDefault() {
        let t = TickEngine(maxTick: 100)
        #expect(t.globalTickIndex == 0)
        #expect(t.maxTick == 100)
    }

    @Test("init clamps negative initialTick to 0")
    func initClampNegative() {
        let t = TickEngine(maxTick: 100, initialTick: -5)
        #expect(t.globalTickIndex == 0)
    }

    @Test("init clamps initialTick > maxTick to maxTick")
    func initClampOverMax() {
        let t = TickEngine(maxTick: 100, initialTick: 200)
        #expect(t.globalTickIndex == 100)
    }

    @Test("init with maxTick=0 clamps initialTick to 0")
    func initZeroMaxTick() {
        let t = TickEngine(maxTick: 0, initialTick: 5)
        #expect(t.globalTickIndex == 0)
        #expect(t.maxTick == 0)
    }
}
