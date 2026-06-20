import Testing
import Foundation
@testable import KlineTrainerPersistence

#if DEBUG
@Suite("FixtureIndicatorMath：逐字复刻后端 import_csv.py 指标公式（host 全测）")
struct FixtureIndicatorMathTests {
    // 后端 ramp：close[i] = 10.0 + i*0.10（与 backend/tests/test_import_csv.py 的 _synthetic 同款）
    static func ramp(_ n: Int) -> [Double] { (0..<n).map { 10.0 + Double($0) * 0.10 } }

    @Test("MA66：前 65 根 nil，第 66 根 = 13.25（后端 ground-truth，容差 1e-4）")
    func ma66_groundTruth() {
        let m = FixtureIndicatorMath.ma66(Self.ramp(66))
        for i in 0..<65 { #expect(m[i] == nil) }
        #expect(m[65] != nil)
        #expect(abs((m[65] ?? -1) - 13.25) < 1e-4)
    }

    @Test("BOLL：前 19 根 nil，第 20 根 mid=10.95/upper≈12.1033/lower≈9.7967（ddof=0 总体 std，容差 1e-4）")
    func boll_groundTruth() {
        let b = FixtureIndicatorMath.boll(Self.ramp(25))
        for i in 0..<19 {
            #expect(b.mid[i] == nil); #expect(b.upper[i] == nil); #expect(b.lower[i] == nil)
        }
        #expect(abs((b.mid[19] ?? -1) - 10.95) < 1e-4)
        #expect(abs((b.upper[19] ?? -1) - 12.1033) < 1e-4)
        #expect(abs((b.lower[19] ?? -1) - 9.7967) < 1e-4)
    }

    @Test("MACD：t=0 全 0；diff[1]≈0.007977/dea[1]≈0.001595/bar[1]≈0.012764（外部手算 golden，容差 1e-6）")
    func macd_externalGolden() {
        let m = FixtureIndicatorMath.macd(Self.ramp(40))
        #expect(m.diff[0] == 0); #expect(m.dea[0] == 0); #expect(m.bar[0] == 0)
        #expect(abs((m.diff[1] ?? -1) - 0.007977) < 1e-6)
        #expect(abs((m.dea[1] ?? -1) - 0.001595) < 1e-6)
        #expect(abs((m.bar[1] ?? -1) - 0.012764) < 1e-6)
    }

    @Test("MACD：全程非 nil（adjust=False 无暖机），含 count==1 边界")
    func macd_noWarmupNil() {
        let m1 = FixtureIndicatorMath.macd(Self.ramp(1))
        #expect(m1.diff[0] != nil); #expect(m1.dea[0] != nil); #expect(m1.bar[0] != nil)
        let m = FixtureIndicatorMath.macd(Self.ramp(40))
        #expect(m.diff.allSatisfy { $0 != nil })
        #expect(m.dea.allSatisfy { $0 != nil })
        #expect(m.bar.allSatisfy { $0 != nil })
    }

    @Test("MACD：末根与同文件独立参考递推一致（结构 cross-check，非唯一 golden）")
    func macd_referenceRecurrence() {
        let close = Self.ramp(40)
        func ewm(_ x: [Double], _ span: Int) -> [Double] {
            let a = 2.0 / (Double(span) + 1.0); var o = [x[0]]
            for i in 1..<x.count { o.append(a * x[i] + (1 - a) * o[i - 1]) }
            return o
        }
        let e12 = ewm(close, 12), e26 = ewm(close, 26)
        let dif = zip(e12, e26).map { $0 - $1 }
        let dea = ewm(dif, 9)
        let bar = zip(dif, dea).map { ($0 - $1) * 2 }
        let m = FixtureIndicatorMath.macd(close)
        let last = close.count - 1
        #expect(abs((m.diff[last] ?? 0) - dif[last]) < 1e-6)
        #expect(abs((m.dea[last] ?? 0) - dea[last]) < 1e-6)
        #expect(abs((m.bar[last] ?? 0) - bar[last]) < 1e-6)
    }

    @Test("暖机 nil 边界：ma66[64]=nil/[65]≠nil；boll[18]=nil/[19]≠nil")
    func warmupBoundaries() {
        let m = FixtureIndicatorMath.ma66(Self.ramp(70))
        #expect(m[64] == nil); #expect(m[65] != nil)
        let b = FixtureIndicatorMath.boll(Self.ramp(25))
        #expect(b.mid[18] == nil); #expect(b.mid[19] != nil)
    }

    @Test("短/空序列：count<window 时全 nil；empty 不崩")
    func shortAndEmptySeries() {
        #expect(FixtureIndicatorMath.ma66(Self.ramp(10)).allSatisfy { $0 == nil })
        #expect(FixtureIndicatorMath.boll(Self.ramp(10)).mid.allSatisfy { $0 == nil })
        let e = FixtureIndicatorMath.macd([])
        #expect(e.diff.isEmpty && e.dea.isEmpty && e.bar.isEmpty)
    }
}
#endif
