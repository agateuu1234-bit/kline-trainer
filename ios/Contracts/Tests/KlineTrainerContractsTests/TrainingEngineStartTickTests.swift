import Testing
@testable import KlineTrainerContracts

struct TrainingEngineStartTickTests {
    /// 造 m3 轴：datetime = base + i*180，globalIndex==endGlobalIndex==i（满足轴不变量）。
    static func m3(_ count: Int, base: Int64) -> [Period: [KLineCandle]] {
        let rows = (0..<count).map { i in
            KLineCandle(period: .m3, datetime: base + Int64(i) * 180, open: 10, high: 11, low: 9,
                        close: 10, volume: 1, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: i, endGlobalIndex: i)
        }
        return [.m3: rows]
    }

    @Test("起始点在序列中部：返回该下标")
    func midSequence() {
        // m3 datetime = [0,180,360,540,720]；start=360 → 首个 >= 360 = index 2
        #expect(TrainingEngine.startTick(forStartDatetime: 360, in: Self.m3(5, base: 0)) == 2)
    }

    @Test("start <= m3[0].datetime → 0（不变量）")
    func atOrBeforeFirst() {
        // m3[0].datetime = 100；start=100 → 0；start=50(<100) → 0
        #expect(TrainingEngine.startTick(forStartDatetime: 100, in: Self.m3(5, base: 100)) == 0)
        #expect(TrainingEngine.startTick(forStartDatetime: 50, in: Self.m3(5, base: 100)) == 0)
    }

    @Test("start 落在两根之间：取首个 >=")
    func betweenCandles() {
        // m3 datetime = [0,180,360]；start=200（180<200<360）→ 首个 >= 200 = index 2
        #expect(TrainingEngine.startTick(forStartDatetime: 200, in: Self.m3(3, base: 0)) == 2)
    }

    @Test("degenerate：start 超所有 m3 → 钳到 maxTick（非 0）")
    func degenerateClampsToMax() {
        // m3 datetime = [0,180,360,540]（count=4, maxTick=3）；start=999999 → 钳到 3
        #expect(TrainingEngine.startTick(forStartDatetime: 999_999, in: Self.m3(4, base: 0)) == 3)
    }

    @Test("空 m3 → 0（make 已先验非空，纵深防御）")
    func emptyM3() {
        #expect(TrainingEngine.startTick(forStartDatetime: 100, in: [:]) == 0)
    }
}
