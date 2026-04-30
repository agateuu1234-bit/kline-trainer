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

    @Test("advance default steps=1 increments by 1")
    func advanceDefault() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance()
        #expect(result == true)
        #expect(t.globalTickIndex == 51)
    }

    @Test("advance multi-step clamps at maxTick")
    func advanceMultiStep() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance(steps: 60)
        #expect(result == true)
        #expect(t.globalTickIndex == 100)
    }

    @Test("advance at maxTick returns false, no mutation")
    func advanceAtMaxTick() {
        var t = TickEngine(maxTick: 100, initialTick: 100)
        let result = t.advance()
        #expect(result == false)
        #expect(t.globalTickIndex == 100)
    }

    @Test("advance steps=0 returns true, no mutation (spec body 字面行为)")
    func advanceZeroSteps() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance(steps: 0)
        #expect(result == true)
        #expect(t.globalTickIndex == 50)
    }

    @Test("advance steps=-1 returns true, decrements (spec body 字面行为; residual 见 design doc)")
    func advanceNegativeStep() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        let result = t.advance(steps: -1)
        #expect(result == true)
        #expect(t.globalTickIndex == 49)
    }

    @Test("reset to negative clamps to 0")
    func resetNegative() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        t.reset(to: -5)
        #expect(t.globalTickIndex == 0)
    }

    @Test("reset to > maxTick clamps to maxTick")
    func resetOverMax() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        t.reset(to: 200)
        #expect(t.globalTickIndex == 100)
    }

    @Test("reset to mid-range exact")
    func resetMidRange() {
        var t = TickEngine(maxTick: 100, initialTick: 50)
        t.reset(to: 75)
        #expect(t.globalTickIndex == 75)
    }

    @Test("Equatable: identical state ==, different state !=, different maxTick !=")
    func equatable() {
        let a = TickEngine(maxTick: 100, initialTick: 50)
        let b = TickEngine(maxTick: 100, initialTick: 50)
        #expect(a == b)

        var c = TickEngine(maxTick: 100, initialTick: 50)
        _ = c.advance(steps: 5)
        #expect(a != c)

        let d = TickEngine(maxTick: 200, initialTick: 50)
        #expect(a != d)
    }

    @Test("advance large negative steps breaks lower-bound invariant (spec body 字面; residual #1)")
    func advanceLargeNegativeStep() {
        var t = TickEngine(maxTick: 100, initialTick: 5)
        let result = t.advance(steps: -1000)
        #expect(result == true)
        #expect(t.globalTickIndex == -995)
    }

    @Test("advance steps=0 at maxTick returns false (guard fires before clamp)")
    func advanceZeroAtMaxTick() {
        var t = TickEngine(maxTick: 100, initialTick: 100)
        let result = t.advance(steps: 0)
        #expect(result == false)
        #expect(t.globalTickIndex == 100)
    }
}
