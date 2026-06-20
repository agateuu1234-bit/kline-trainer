# 丰富 DEBUG fixture：真实感 OHLCV + 真实 MA66/BOLL/MACD 指标 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 DEBUG seed fixture 用确定性种子游走生成真实感 OHLCV 并为全部 6 周期填入与后端算法一致的 MA66/BOLL/MACD，使运行时三指标可见（解 #7）且 K 线不再是正弦波（解 #4）。

**Architecture:** 新增两个独立 DEBUG 纯函数单元——`FixturePriceSeries`（对数空间均值回复种子游走 OHLCV）与 `FixtureIndicatorMath`（逐字复刻后端 `import_csv.py` 的指标公式）；`DebugFixtureData.make` 改用前者生成 m3、保留既有 `aggregate(span:)`、对每周期 close 调后者算指标并装入扩展后的 `CandleRow`；`DebugTrainingSetWriter` 把原本 hard-code 的 `NULL` 改为绑定真实值。`KLineCandle` 模型与 render 层早已支持全部指标——**零生产代码、零契约改动**。

**Tech Stack:** Swift 6 / Swift Package `KlineTrainerPersistence`（依赖 `KlineTrainerContracts`）；GRDB（SQLite 写）；Swift Testing（`@Suite`/`@Test`/`#expect`）；host `swift test`。

## Global Constraints

- **全部新代码与新测试包在 `#if DEBUG ... #endif` 内**；`DebugFixtureData`/`DebugTrainingSetWriter` 整文件已是 `#if DEBUG`。
- **零生产代码改动、零契约改动**：不改 `KLineCandle`、不改 render 层、**不 bump `CONTRACT_VERSION`（仍 "1.6"）**、不改 env-var 注入路径。
- **不改** 聚合 span（`1/5/20/40/80/120`）、`fullLoadM3Count = 9600`、`baseEpoch = 1_700_000_000`、`m3Step = 180`。
- **指标公式逐字复刻后端 `backend/import_csv.py:69-89`**：MA66 = SMA(close,66) min_periods 66（前 65 nil）；BOLL = SMA(close,20) ± 2·**总体 std（ddof=0，除以 N 不是 N-1）**（前 19 nil）；MACD = EMA12−EMA26 / EMA(dif,9) / **bar=(dif−dea)×2**，`ewm(adjust=False)` α=2/(span+1) 首值播种 `y[0]=x[0]`（**全程无暖机 nil**）；MA66/BOLL round **4dp**、MACD round **6dp**。
- **指标 golden 断言一律用容差**（4dp→`< 1e-4`，6dp→`< 1e-6`，镜像后端 `pytest.approx`），**禁 exact `==`** 比浮点指标值（`== nil` / `!= nil` / `== 0` 仍可）。
- **价格 = 对数空间均值回复游走**，确定性 **SplitMix64 + 固定种子**，**禁 `Date`/`arc4random`/`Double.random`/系统随机**。
- **退化守门**：full-load(9600) m3 序列**任意连续 20 根 close 总体 std > ε**（ε ≈ 窗口均值·`1e-3`）且**全序列无 close 触及 floor(2)/ceil(80)**。

**测试基线**：当前 main `bc31625` host `swift test` = **1127 tests / 158 suites / 0 fail**。本计划新增 **19 个 @Test**（7+8+3+1），完成后约 **1146 tests**（以 verification 实跑为准，不硬编码）。

**测试运行命令**（host，从仓库根）：
```bash
cd "ios/Contracts" && swift test 2>&1 | tail -20
```
单 Suite：`swift test --filter FixtureIndicatorMathTests`

---

### Task 1: FixtureIndicatorMath（新 DEBUG 纯单元 + 测试）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixtureIndicatorMath.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/FixtureIndicatorMathTests.swift`

**Interfaces:**
- Consumes: 无（纯函数，仅 `import Foundation`）。
- Produces（Task 3 依赖这些签名）：
  - `FixtureIndicatorMath.ma66(_ close: [Double]) -> [Double?]`
  - `FixtureIndicatorMath.boll(_ close: [Double]) -> (upper: [Double?], mid: [Double?], lower: [Double?])`
  - `FixtureIndicatorMath.macd(_ close: [Double]) -> (diff: [Double?], dea: [Double?], bar: [Double?])`
  - 三者返回数组长度均 == `close.count`。

- [ ] **Step 1: 写失败测试**（`FixtureIndicatorMathTests.swift`，全文）

```swift
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
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter FixtureIndicatorMathTests 2>&1 | tail -15`
Expected: 编译失败 `cannot find 'FixtureIndicatorMath' in scope`（实现未建）。

- [ ] **Step 3: 写实现**（`FixtureIndicatorMath.swift`，全文）

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixtureIndicatorMath.swift
// Kline Trainer — DEBUG fixture 指标计算（逐字复刻后端 backend/import_csv.py:69-89）
//
// #if DEBUG only：纯函数，把 close 序列算成 MA66/BOLL/MACD，供 DebugFixtureData 逐周期填值。
// 公式与舍入与后端一致（跨语言契约），使 fixture 忠实预览真实预计算数据。

#if DEBUG
import Foundation

enum FixtureIndicatorMath {
    private static func round4(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }
    private static func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }

    /// SMA(close, 66)，min_periods 66 → 前 65 根 nil，round 4dp。(import_csv.py:74)
    static func ma66(_ close: [Double]) -> [Double?] {
        let window = 66
        return close.indices.map { i in
            guard i >= window - 1 else { return nil }
            let sum = close[(i - window + 1)...i].reduce(0, +)
            return round4(sum / Double(window))
        }
    }

    /// BOLL：window 20，min_periods 20，mid=SMA，±2·总体 std(ddof=0)，round 4dp。(import_csv.py:76-80)
    static func boll(_ close: [Double]) -> (upper: [Double?], mid: [Double?], lower: [Double?]) {
        let window = 20
        var upper = [Double?](repeating: nil, count: close.count)
        var mid = [Double?](repeating: nil, count: close.count)
        var lower = [Double?](repeating: nil, count: close.count)
        for i in close.indices where i >= window - 1 {
            let w = close[(i - window + 1)...i]
            let m = w.reduce(0, +) / Double(window)
            let variance = w.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(window) // ddof=0 总体
            let std = variance.squareRoot()
            mid[i] = round4(m)
            upper[i] = round4(m + 2 * std)
            lower[i] = round4(m - 2 * std)
        }
        return (upper, mid, lower)
    }

    /// MACD：EMA12−EMA26 / EMA(dif,9) / bar=(dif−dea)×2；ewm(adjust=False) 首值播种；round 6dp；无暖机 nil。(import_csv.py:82-88)
    static func macd(_ close: [Double]) -> (diff: [Double?], dea: [Double?], bar: [Double?]) {
        guard !close.isEmpty else { return ([], [], []) }
        func ewm(_ x: [Double], span: Int) -> [Double] {
            let alpha = 2.0 / (Double(span) + 1.0)
            var out = [Double](repeating: 0, count: x.count)
            out[0] = x[0]                                   // adjust=False 首值播种 y[0]=x[0]
            for i in 1..<x.count { out[i] = alpha * x[i] + (1 - alpha) * out[i - 1] }
            return out
        }
        let ema12 = ewm(close, span: 12)
        let ema26 = ewm(close, span: 26)
        let dif = zip(ema12, ema26).map { $0 - $1 }
        let dea = ewm(dif, span: 9)
        let diffOut = dif.map { Optional(round6($0)) }
        let deaOut = dea.map { Optional(round6($0)) }
        let barOut = zip(dif, dea).map { Optional(round6(($0 - $1) * 2)) }
        return (diffOut, deaOut, barOut)
    }
}
#endif
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "ios/Contracts" && swift test --filter FixtureIndicatorMathTests 2>&1 | tail -15`
Expected: `Test run with 7 tests ... passed`（7 @Test 全绿）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixtureIndicatorMath.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/FixtureIndicatorMathTests.swift
git commit -m "feat(debug-fixture): FixtureIndicatorMath 逐字复刻后端 MA66/BOLL/MACD（7 host @Test 后端 golden）"
```

---

### Task 2: FixturePriceSeries（新 DEBUG 纯单元 + 测试）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixturePriceSeries.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/FixturePriceSeriesTests.swift`

**Interfaces:**
- Consumes: 无（纯函数，仅 `import Foundation`）。
- Produces（Task 3 依赖）：
  - `FixturePriceSeries.OHLCV`（`struct { let open, high, low, close: Double; let volume: Int }`，`Equatable`）
  - `FixturePriceSeries.generate(count: Int) -> [OHLCV]`，长度 == count，确定性。

- [ ] **Step 1: 写失败测试**（`FixturePriceSeriesTests.swift`，全文）

```swift
import Testing
import Foundation
@testable import KlineTrainerPersistence

#if DEBUG
@Suite("FixturePriceSeries：确定性对数均值回复 OHLCV 种子游走（host 全测）")
struct FixturePriceSeriesTests {

    @Test("确定性：同种子两次生成完全相同（无随机/无时钟）")
    func deterministic() {
        #expect(FixturePriceSeries.generate(count: 500) == FixturePriceSeries.generate(count: 500))
    }

    @Test("正值且有限；volume≥0")
    func positiveFinite() {
        for c in FixturePriceSeries.generate(count: 1000) {
            #expect(c.open > 0 && c.high > 0 && c.low > 0 && c.close > 0)
            #expect(c.open.isFinite && c.high.isFinite && c.low.isFinite && c.close.isFinite)
            #expect(c.volume >= 0)
        }
    }

    @Test("OHLC 不变量：high≥max(o,c)、low≤min(o,c)、high≥low")
    func ohlcInvariants() {
        for c in FixturePriceSeries.generate(count: 1000) {
            #expect(c.high >= max(c.open, c.close))
            #expect(c.low <= min(c.open, c.close))
            #expect(c.high >= c.low)
        }
    }

    @Test("首根 r_0:=0：open[0] == close[0]")
    func firstBarFlat() {
        let s = FixturePriceSeries.generate(count: 10)
        #expect(s[0].open == s[0].close)
    }

    @Test("计数 == n；空输入 == []；count==1 == 1")
    func countMatches() {
        #expect(FixturePriceSeries.generate(count: 0).isEmpty)
        #expect(FixturePriceSeries.generate(count: 1).count == 1)
        #expect(FixturePriceSeries.generate(count: 9600).count == 9600)
    }

    // D10 退化守门：full-load 9600 任意连续 20 close 总体 std > ε(≈窗口均值·1e-3) → BOLL 永不三线重叠（守 #7 不局部复发）
    @Test("非退化守门：full-load 任意 20 窗口 close 总体 std > ε(≈mean·1e-3)")
    func noDegenerate20Window() {
        let closes = FixturePriceSeries.generate(count: 9600).map(\.close)
        for start in 0...(closes.count - 20) {
            let w = closes[start..<start + 20]
            let mean = w.reduce(0, +) / 20
            let variance = w.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 20
            let std = variance.squareRoot()
            #expect(std > mean * 1e-3, "窗口[\(start)] std=\(std) 退化（≤ \(mean * 1e-3)）")
        }
    }

    // 安全网 tripwire：均值回复保证操作上永不触及硬 floor/ceil
    @Test("永不贴边：全序列无 close 触及 floor(2)/ceil(80)")
    func neverTouchesBounds() {
        for c in FixturePriceSeries.generate(count: 9600) { #expect(c.close > 2.0 && c.close < 80.0) }
    }

    @Test("整序列 return 标准差 > 0（真实波动非常量）")
    func returnsVary() {
        let closes = FixturePriceSeries.generate(count: 1000).map(\.close)
        let rets = (1..<closes.count).map { closes[$0] - closes[$0 - 1] }
        let mean = rets.reduce(0, +) / Double(rets.count)
        let varr = rets.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(rets.count)
        #expect(varr.squareRoot() > 0)
    }
}
#endif
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter FixturePriceSeriesTests 2>&1 | tail -15`
Expected: 编译失败 `cannot find 'FixturePriceSeries' in scope`。

- [ ] **Step 3: 写实现**（`FixturePriceSeries.swift`，全文）

```swift
// ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixturePriceSeries.swift
// Kline Trainer — DEBUG fixture 价格序列（确定性对数空间均值回复种子游走）
//
// #if DEBUG only：SplitMix64 固定种子驱动的 OHLCV 生成器，替换旧正弦 close。
// 均值回复(κ>0)+vol_min>0 杜绝钳位退化平台（守 #7 不局部复发）；硬 floor/ceil 仅有限性安全网。

#if DEBUG
import Foundation

enum FixturePriceSeries {
    struct OHLCV: Equatable {
        let open: Double, high: Double, low: Double, close: Double
        let volume: Int
    }

    /// 确定性 PRNG（整数运算，bit-identical）。
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// [0,1) 取高 53 位尾数。
        mutating func unit() -> Double { Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) }
    }

    static let priceSeed: UInt64 = 0x9E37_79B9_7F4A_7C15
    private static let logCenter = log(10.0)
    private static let kappa = 0.02            // 均值回复强度
    private static let floorPrice = 2.0        // 硬安全网（操作上永不触及）
    private static let ceilPrice = 80.0
    private static let trendSegLen = 200       // 趋势段长（m3 根）
    private static let driftMag = 0.0012       // 每根趋势漂移（log）
    private static let volSegLen = 150         // 波动率段长
    private static let volMin = 0.012          // 波动率下限 > 0（保每根变动）
    private static let volHigh = 0.024
    private static let spreadFactor = 0.5      // 影线 = close·vol·factor
    private static let volumeBase = 1000
    private static let volumeScale = 60_000.0

    static func generate(count: Int) -> [OHLCV] {
        guard count > 0 else { return [] }
        var rng = SplitMix64(seed: priceSeed)
        var result: [OHLCV] = []
        result.reserveCapacity(count)

        // i=0：r_0 := 0，close = 中枢 = 10，open == close
        var logPrice = logCenter
        var prevClose = exp(logPrice)
        let spread0 = prevClose * volMin * spreadFactor
        result.append(OHLCV(open: prevClose, high: prevClose + spread0,
                            low: prevClose - spread0, close: prevClose, volume: volumeBase))

        var drift = driftMag
        var vol = volMin
        for i in 1..<count {
            if i % trendSegLen == 0 { drift = rng.unit() < 0.5 ? -driftMag : driftMag }
            if i % volSegLen == 0 { vol = rng.unit() < 0.5 ? volMin : volHigh }
            let noise = rng.unit() * 2 - 1                                  // [-1,1]
            logPrice = logPrice + drift + kappa * (logCenter - logPrice) + vol * noise
            var close = exp(logPrice)
            close = min(max(close, floorPrice), ceilPrice)                  // 安全网（不操作性触发）
            let open = prevClose
            let spread = close * vol * spreadFactor
            let high = max(open, close) + spread
            let low = min(open, close) - spread
            let volume = volumeBase + Int((volumeScale * abs(vol * noise)).rounded())
            result.append(OHLCV(open: open, high: high, low: low, close: close, volume: volume))
            prevClose = close
        }
        return result
    }
}
#endif
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd "ios/Contracts" && swift test --filter FixturePriceSeriesTests 2>&1 | tail -15`
Expected: `Test run with 8 tests ... passed`。
**实现者注**：若 `noDegenerate20Window` 报某窗口退化（极不可能——vol_min=0.012 每根注入运动，实测 20 窗口 std≈0.26 ≫ ε≈0.01），按 spec D6 的 by-construction 守门，把 `volMin` 以 0.003 增量上调并重跑直至绿；这是 plan 赋予的退化根治旋钮，不是占位。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixturePriceSeries.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/FixturePriceSeriesTests.swift
git commit -m "feat(debug-fixture): FixturePriceSeries 确定性对数均值回复 OHLCV 游走（8 host @Test 含退化守门）"
```

---

### Task 3: DebugFixtureData 接线（CandleRow 扩 6 字段 + 逐周期算指标）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`（`CandleRow` 结构 15-22；`make` 体 48-93；文件头注释 7）
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift`（更新 `ma66_rollingMean` + 新增 3 @Test）

**Interfaces:**
- Consumes：`FixturePriceSeries.generate(count:) -> [OHLCV]`（Task 2）；`FixtureIndicatorMath.{ma66,boll,macd}`（Task 1）。
- Produces（Task 4 依赖）：`CandleRow` 新增 `bollUpper/bollMid/bollLower/macdDiff/macdDea/macdBar: Double?` 六字段（内部 memberwise init 参数顺序见下）。

- [ ] **Step 1: 更新既有 `ma66_rollingMean` 测试为容差（D7 舍入后断言）**

在 `DebugFixtureDataTests.swift` 把现有 `ma66_rollingMean` 的最后一行
`#expect(abs((m3[65].ma66 ?? -1) - expected65) < 1e-9)`
改为容差吸收 4dp 舍入：
```swift
        #expect(abs((m3[65].ma66 ?? -1) - expected65) < 1e-4)   // D7：ma66 现 round 4dp
```

- [ ] **Step 2: 新增 3 个 @Test**（追加到 `DebugFixtureDataTests` 内 `}` 之前）

```swift
    // 监 #7 指标看不到回归：满载下每周期暖机后 MA66/BOLL/MACD 均非 nil（每周期满载根数：m3=9600..monthly=80，均 ≥66/≥20）
    @Test("满载：每周期暖机后 MA66@65 / BOLL@19 三轨 / MACD@0 均非 nil（监 #7）")
    func fullLoad_everyPeriodHasIndicators() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        for period in Period.allCases {
            let rows = data.candles.first(where: { $0.period == period })!.rows
            #expect(rows.count >= 66, "周期 \(period) 满载根数应 ≥66")
            #expect(rows[65].ma66 != nil, "周期 \(period) MA66@65 应非 nil")
            #expect(rows[19].bollUpper != nil && rows[19].bollMid != nil && rows[19].bollLower != nil,
                    "周期 \(period) BOLL@19 三轨应非 nil")
            #expect(rows[0].macdDiff != nil && rows[0].macdDea != nil && rows[0].macdBar != nil,
                    "周期 \(period) MACD@0 应非 nil（无暖机）")
        }
    }

    @Test("满载：所有非 nil 指标值均有限")
    func fullLoad_indicatorsFinite() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        for pc in data.candles {
            for c in pc.rows {
                for v in [c.ma66, c.bollUpper, c.bollMid, c.bollLower, c.macdDiff, c.macdDea, c.macdBar] {
                    if let v { #expect(v.isFinite) }
                }
            }
        }
    }

    // 监 D4：旧版聚合周期 ma66=nil；现逐周期算 → 聚合周期 MA66 亦非 nil
    @Test("MA66 在 m3 与聚合周期(daily)均非 nil（监 D4 旧版聚合 nil 缺陷）")
    func ma66_presentOnAggregatedPeriods() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        let m3 = data.candles.first(where: { $0.period == .m3 })!.rows
        let daily = data.candles.first(where: { $0.period == .daily })!.rows
        #expect(m3[65].ma66 != nil)
        #expect(daily[65].ma66 != nil, "聚合周期 daily 的 MA66 现应非 nil（旧版为 nil）")
    }
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter DebugFixtureDataTests 2>&1 | tail -20`
Expected: 编译失败 `value of type 'DebugFixtureData.CandleRow' has no member 'bollUpper'`（字段未加）。

- [ ] **Step 4: 扩展 `CandleRow` 结构**（替换 `DebugFixtureData.swift:15-22`）

```swift
    public struct CandleRow: Equatable, Sendable {
        public let datetime: Int64
        public let open: Double, high: Double, low: Double, close: Double
        public let volume: Int
        public let ma66: Double?
        public let bollUpper: Double?
        public let bollMid: Double?
        public let bollLower: Double?
        public let macdDiff: Double?
        public let macdDea: Double?
        public let macdBar: Double?
        public let globalIndex: Int?
        public let endGlobalIndex: Int
    }
```
（合成 memberwise init 参数顺序：`datetime, open, high, low, close, volume, ma66, bollUpper, bollMid, bollLower, macdDiff, macdDea, macdBar, globalIndex, endGlobalIndex`。）

- [ ] **Step 5: 重写 `make` 体的蜡烛生成**（替换 `DebugFixtureData.swift:48-93`，即从 `public static func make` 起到 `let candles = [...]` 块结束）

```swift
    public static func make(m3Count: Int = 240) -> Seed {
        let filename = "debug-fixture-600001.sqlite"

        // m3 原始 OHLCV 由确定性均值回复种子游走生成（替换旧正弦）；先建无指标骨架。
        let ohlcv = FixturePriceSeries.generate(count: m3Count)
        var m3Rows: [CandleRow] = []
        for i in 0..<m3Count {
            let c = ohlcv[i]
            m3Rows.append(CandleRow(
                datetime: baseEpoch + Int64(i) * m3Step,
                open: c.open, high: c.high, low: c.low, close: c.close, volume: c.volume,
                ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                macdDiff: nil, macdDea: nil, macdBar: nil,
                globalIndex: i, endGlobalIndex: i))
        }
        // 其余 5 周期按 span 聚合（与既有逻辑同：global_index=nil、end=组末 m3 index）；指标稍后逐周期填。
        func aggregate(span: Int) -> [CandleRow] {
            var rows: [CandleRow] = []
            var start = 0
            while start < m3Count {
                let end = min(start + span - 1, m3Count - 1)
                let slice = m3Rows[start...end]
                rows.append(CandleRow(
                    datetime: m3Rows[start].datetime,
                    open: slice.first!.open, high: slice.map(\.high).max()!,
                    low: slice.map(\.low).min()!, close: slice.last!.close,
                    volume: slice.map(\.volume).reduce(0, +),
                    ma66: nil, bollUpper: nil, bollMid: nil, bollLower: nil,
                    macdDiff: nil, macdDea: nil, macdBar: nil,
                    globalIndex: nil, endGlobalIndex: end))
                start += span
            }
            return rows
        }
        // 逐周期：对该周期 close 序列复刻后端公式算 MA66/BOLL/MACD，装回新 CandleRow（修 D4：聚合周期亦填 ma66）。
        func withIndicators(_ rows: [CandleRow]) -> [CandleRow] {
            let closes = rows.map(\.close)
            let ma = FixtureIndicatorMath.ma66(closes)
            let bo = FixtureIndicatorMath.boll(closes)
            let mc = FixtureIndicatorMath.macd(closes)
            return rows.indices.map { i in
                CandleRow(
                    datetime: rows[i].datetime, open: rows[i].open, high: rows[i].high,
                    low: rows[i].low, close: rows[i].close, volume: rows[i].volume,
                    ma66: ma[i], bollUpper: bo.upper[i], bollMid: bo.mid[i], bollLower: bo.lower[i],
                    macdDiff: mc.diff[i], macdDea: mc.dea[i], macdBar: mc.bar[i],
                    globalIndex: rows[i].globalIndex, endGlobalIndex: rows[i].endGlobalIndex)
            }
        }
        let candles = [
            PeriodCandles(period: .m3, rows: withIndicators(m3Rows)),
            PeriodCandles(period: .m15, rows: withIndicators(aggregate(span: 5))),
            PeriodCandles(period: .m60, rows: withIndicators(aggregate(span: 20))),
            PeriodCandles(period: .daily, rows: withIndicators(aggregate(span: 40))),
            PeriodCandles(period: .weekly, rows: withIndicators(aggregate(span: 80))),
            PeriodCandles(period: .monthly, rows: withIndicators(aggregate(span: 120))),
        ]
```
**注**：`make` 体此块之后的 `meta`/`fees`/`records`/`emptyPosition`/`pending`/`return Seed(...)` 全部**不动**（仍引用 `m3Rows.first!`/`m3Rows.last!`，可用）。

- [ ] **Step 6: 更新文件头注释**（`DebugFixtureData.swift:7` 那行过时描述）

把第 7 行
```swift
// daily end<=max m3 end）。指标：MA66 rolling mean；BOLL/MACD 留 NULL（nullable；交互矩阵不需指标精度）。
```
改为
```swift
// daily end<=max m3 end）。指标：每周期经 FixtureIndicatorMath 复刻后端公式算 MA66/BOLL/MACD（真实值，非 NULL）。
```

- [ ] **Step 7: 跑测试确认通过**

Run: `cd "ios/Contracts" && swift test --filter DebugFixtureDataTests 2>&1 | tail -20`
Expected: `Test run with 11 tests ... passed`（原 8 + 新 3；含更新后的 `ma66_rollingMean`）。

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift
git commit -m "feat(debug-fixture): DebugFixtureData 改种子游走 OHLCV + 逐周期填 MA66/BOLL/MACD（CandleRow 扩 6 字段，监 #7/D4）"
```

---

### Task 4: DebugTrainingSetWriter 绑定真实指标值（替 NULL）+ 往返测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift`（INSERT 41-48）
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugTrainingSetWriterTests.swift`（新增 1 往返 @Test）

**Interfaces:**
- Consumes：`CandleRow.{bollUpper,bollMid,bollLower,macdDiff,macdDea,macdBar}`（Task 3）；`DefaultTrainingSetDBFactory().openAndVerify(file:expectedSchemaVersion:)` → `TrainingSetReader`；`reader.loadAllCandles() -> [Period: [KLineCandle]]`（既有）。
- Produces：写出的 sqlite 中 `boll_*`/`macd_*` 列为真实 REAL（非 NULL）。

- [ ] **Step 1: 写失败的往返测试**（追加到 `DebugTrainingSetWriterTests` 内 `}` 之前）

```swift
    // 监 NULL hard-code 回归 + reader typeof() 存储类亲和门（绑定值须 Double?→REAL/NULL 才过 loadAllCandles）
    @Test("往返保真：m3 周期 boll/macd 列读出非 NULL 且与 seed CandleRow 一致")
    func roundTrip_indicatorsNonNull() throws {
        let seed = DebugFixtureData.make(m3Count: 240)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DebugWriterRT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(seed.trainingSetFilename)

        try DebugTrainingSetWriter.write(seed: seed, to: url)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: url, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let read = try reader.loadAllCandles()[.m3]!
        let seedM3 = seed.candles.first(where: { $0.period == .m3 })!.rows

        // m3 240 根：BOLL 从 idx19、MACD 从 idx0 非 nil
        #expect(read[19].bollUpper != nil && read[19].bollMid != nil && read[19].bollLower != nil)
        #expect(read[0].macdDiff != nil && read[0].macdDea != nil && read[0].macdBar != nil)
        #expect(read[100].macdBar != nil)
        // 往返一致（容差 1e-9，REAL 精度足够）
        #expect(abs((read[19].bollUpper ?? -1) - (seedM3[19].bollUpper ?? -2)) < 1e-9)
        #expect(abs((read[0].macdBar ?? -1) - (seedM3[0].macdBar ?? -2)) < 1e-9)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd "ios/Contracts" && swift test --filter DebugTrainingSetWriterTests 2>&1 | tail -15`
Expected: FAIL `Expectation failed: read[19].bollUpper != nil`（写库仍 hard-code NULL）。

- [ ] **Step 3: 改 INSERT 绑定真实值**（替换 `DebugTrainingSetWriter.swift:41-48`）

```swift
                    try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, amount, ma66,
                        boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar,
                        global_index, end_global_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [pc.period.rawValue, r.datetime, r.open, r.high, r.low, r.close,
                                     r.volume, r.ma66, r.bollUpper, r.bollMid, r.bollLower,
                                     r.macdDiff, r.macdDea, r.macdBar, r.globalIndex, r.endGlobalIndex])
```
（`amount` 仍 hard-code `NULL`（无 ? 占位）；其余 16 列各一 `?`，`Double?`→REAL/NULL。）

- [ ] **Step 4: 跑测试确认通过 + 既有承重 gauntlet 仍绿**

Run: `cd "ios/Contracts" && swift test --filter DebugTrainingSetWriterTests 2>&1 | tail -15`
Expected: `Test run with 2 tests ... passed`（既有 `writtenSqlite_isDownstreamConsumable` 完整 reader gauntlet + 新往返）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugTrainingSetWriter.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugTrainingSetWriterTests.swift
git commit -m "feat(debug-fixture): DebugTrainingSetWriter 绑定真实 BOLL/MACD 值替 NULL（往返保真 @Test）"
```

---

### Task 5: 验收清单文档（治理 backstop #2，非 coder 可执行）

**Files:**
- Create: `docs/superpowers/acceptance/2026-06-20-debug-fixture-real-indicators-acceptance.md`

**Interfaces:** 无代码。纯文档：动作/预期/通过-否决三列，中文，禁 `.claude/workflow-rules.json` 列的占位短语。

- [ ] **Step 1: 写验收清单**（全文）

```markdown
# 验收清单：丰富 DEBUG fixture（真实感 OHLCV + MA66/BOLL/MACD）

PR：丰富 debug fixture 真实指标 ·分支 `feat/debug-fixture-real-indicators`

## §1 自动化门（CI / host 已覆盖，此处复述结论）
| 动作 | 预期 | 通过/否决 |
|---|---|---|
| `cd ios/Contracts && swift test` | 约 1146 tests / 0 fail（含 FixtureIndicatorMath 7 + FixturePriceSeries 8 + DebugFixtureData 11 + Writer 2） | ☐ |
| Mac Catalyst `build-for-testing` | TEST BUILD SUCCEEDED | ☐ |
| iOS app build | BUILD SUCCEEDED | ☐ |

## §2 人工模拟器验收（运行时观感，自动化测不到）
前置：iPhone 模拟器装 iOS runtime，`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1 xcrun simctl launch ... <bundle-id>` 注入 seed，进入一局训练（默认上区 60 分 / 下区 日线）。

| # | 动作 | 预期 | 通过/否决 |
|---|---|---|---|
| 1 | 看上区主图（60 分） | 见 MA66 一条平滑均线 + BOLL 三轨（上/中/下带），带宽有收有张（非三线重叠、非缺线） | ☐ |
| 2 | 看下区主图（日线） | 同样见 MA66 + BOLL 三轨，与上区独立 | ☐ |
| 3 | 看任一区 MACD 副图 | 见红/绿 MACD 柱穿越零轴 + DIF/DEA 两条线（非空白、非全平） | ☐ |
| 4 | 看 K 线形态 | 实体/影线有真实变化（涨跌不一），非平滑等幅正弦波 | ☐ |
| 5 | 切换周期 combo（上区/下区周期换档） | 每个周期都有 MA66/BOLL/MACD（满载下 monthly 末段亦有 MA66） | ☐ |
| 6 | 横向拖动看历史段 | 指标随蜡烛连续，无突兀断线（暖机段 MA66/BOLL 前缀留空属正常） | ☐ |

## §3 回归（不应改变的行为）
| 动作 | 预期 | 通过/否决 |
|---|---|---|
| 买卖/结算/历史弹窗/pan 联动 | 与本 PR 前一致（本 PR 仅改 DEBUG fixture 数据，零生产代码） | ☐ |
| Release 构建 | fixture 代码整体 `#if DEBUG` 剔除，无体积/行为影响 | ☐ |
```

- [ ] **Step 2: 提交**

```bash
git add docs/superpowers/acceptance/2026-06-20-debug-fixture-real-indicators-acceptance.md
git commit -m "docs(debug-fixture): 验收清单（治理 backstop #2，自动化门 + 模拟器人工 6 场景 + 回归）"
```

---

## 自检（Self-Review）

**1. Spec coverage**（逐节对账）：
- §2 目标 1（种子游走替正弦）→ Task 2 + Task 3 Step 5。✓
- §2 目标 2（全周期复刻后端公式填值替 NULL）→ Task 1 + Task 3（逐周期 withIndicators）+ Task 4（绑定）。✓
- §2 目标 3（默认面板可见）→ Task 3 `fullLoad_everyPeriodHasIndicators` + Task 5 §2。✓
- §2 目标 4（确定性）→ Task 2 `deterministic` + SplitMix64 固定种子。✓
- §5.1 价格模型（均值回复/vol_min/r_0/安全网）→ Task 2 实现 + 8 测试。✓
- §5.2 公式 + golden（含 MACD 手算）→ Task 1 实现 + 7 测试。✓
- §5.3 CandleRow 扩 6 字段 + 逐周期 → Task 3。✓
- §5.4 writer 绑定 → Task 4。✓
- §8 测试策略四组 → Task 1/2/3/4 测试。✓
- §9 验收 → Task 5。✓
- D7 舍入连带更新 ma66 测试 → Task 3 Step 1。✓
- D10 退化守门（std>ε + 永不贴边）→ Task 2 `noDegenerate20Window`/`neverTouchesBounds`。✓
- D11 容差 + 手算 golden + reader 亲和门 → Task 1 测试容差 + Task 4 往返。✓

**2. Placeholder scan**：无 TBD/TODO；Task 2 Step 4 的「volMin 上调旋钮」是 by-construction 根治指令（具体增量 0.003），非占位。✓

**3. Type consistency**：`CandleRow` 15 参数 memberwise init 顺序在 Task 3 Step 4 定义、Task 3 Step 5 与 Task 4 调用一致；`FixtureIndicatorMath` 三函数签名 Task 1 Produces 与 Task 3 `withIndicators` 调用一致；`FixturePriceSeries.OHLCV` 字段与 Task 3 m3 骨架读取一致；`loadAllCandles() -> [Period:[KLineCandle]]` 与 Task 4 调用一致。✓
