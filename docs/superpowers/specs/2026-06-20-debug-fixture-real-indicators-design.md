# 丰富 DEBUG fixture：真实感 OHLCV + 真实 MA66/BOLL/MACD 指标 — 设计文档

> 来源：运行时验证 `project_runtime_verification_findings_2026_06_17` 的 **#3c 周期比例 / #4 正弦波 / #7 指标看不到**（同一根因：DEBUG seed fixture 只填正弦 close + 部分 MA66，从不填 BOLL/MACD）。
> 状态：设计已与用户确认（价格真实度选项 = **真实感 OHLC 种子游走**）。
> 评审通道：Opus 4.8 xhigh 对抗性 review（代 codex，与 PR #122–127 一致）。

---

## 1. 背景与问题

DEBUG-only 的 seed fixture（`KLINE_SEED_FIXTURE=1` 注入）当前由 `DebugFixtureData.make` 生成：

- `close = 10.0 + 2.0 * sin(Double(i) * 0.15)` —— 平滑正弦波，振幅 2、均匀小实体（`high=max(o,c)+0.3`/`low=min(o,c)-0.3`，固定 0.3 影线）。
- 仅 **m3** 周期算 MA66（`closes[(i-65)...i].reduce/66`，未舍入）；5 个聚合周期 `ma66: nil`。
- `CandleRow` 结构 **没有 BOLL/MACD 字段**；`DebugTrainingSetWriter` 的 INSERT 把 `boll_*`/`macd_*` 列 **hard-code 成 `NULL`**。

后果（运行时实测）：
- **#7 指标看不到**：render 层 `MainChartLayout.bollPolylines` / `SubChartLayout.macdLines/macdBars` 在每个 `nil` 处断线/跳过 bar → BOLL/MACD 在所有面板**完全不可见**；MA66 在默认 `.m60/.daily` 面板也不可见（聚合周期 nil）。
- **#4 正弦波**：K 线是平滑正弦，不像真股票数据，实体/影线均匀。
- **#3c 周期比例**：各周期只是同一正弦的粗采样，缺乏真实结构。

**关键事实**：`KLineCandle` 模型（`Models.swift:59-113`，`CONTRACT_VERSION = "1.6"`）**早已有全部指标字段**（`ma66`/`bollUpper`/`bollMid`/`bollLower`/`macdDiff`/`macdDea`/`macdBar`，均 `Double?`），render 层早已读取。瓶颈纯粹在 fixture 生成器与写库器——**从来没人填**。因此本次**零生产代码改动、零契约改动、不 bump CONTRACT_VERSION**。

---

## 2. 目标

1. DEBUG fixture 用**确定性种子游走**生成真实感 OHLCV，替换正弦 close（解 #4）。
2. 为**全部 6 个周期**各自的 close 序列计算 MA66/BOLL/MACD，**逐字复刻后端 `import_csv.py` 公式**，写入 DB 真实值替代 NULL（解 #7）。
3. 默认 `.m60/.daily` 双面板及任意 combo 切换后，三指标在满载 fixture 下均可见且数值与后端算法一致。
4. 全程**确定性**（固定种子，无 `Date`/`arc4random`/`random`）→ fixture 与测试可复现。

## 3. 非目标（YAGNI）

- **不**接入真实数据 / NAS（W1-R2 另立 OPEN）。
- **不**在训练引擎里实时重算指标（app 只读 B1 预计算值，本次不改这一架构）。
- **不**改 6 周期聚合 span（保持 1/5/20/40/80/120）、不改 `fullLoadM3Count = 9600`、不改 baseEpoch/m3Step。
- **不**改 `KLineCandle` 模型、render 代码、env-var 注入路径、UI / Y 轴。
- **不**新增生产（非 DEBUG）指标计算模块——全部 `#if DEBUG`，仅服务 fixture。

---

## 4. 架构

把 `DebugFixtureData` 从「正弦 + 仅 m3 MA66」升级为「**种子游走 OHLCV → 每周期各自复刻后端公式算三指标**」。新增**两个独立 DEBUG 纯函数单元**（各自单一职责、可独立 host 测试），改两处既有调用点。**全部 `#if DEBUG`**（host `swift test` 在 debug 配置编译 → 完整受测）。

```
KLINE_SEED_FIXTURE=1
  → AppContainer.seedDebugFixtures
    → DebugFixtureData.make(m3Count: 9600)
        1. FixturePriceSeries.generate(count:)  ──► [OHLCV]   (m3 原始，种子游走)
        2. aggregate(span:) ×5                  ──► 各周期 OHLCV (复用既有逻辑)
        3. 对每个周期的 close[] 调
           FixtureIndicatorMath.{ma66,boll,macd} ──► 指标数组
        4. zip 进 CandleRow（含新 boll/macd 字段）
    → DebugTrainingSetWriter.write  (绑定真实指标值替代 NULL)
  → cache.store  → 训练时 KLineRow→KLineCandle 读出 → render 画线/画 bar
```

## 5. 组件与接口

### 5.1 `FixturePriceSeries`（新，DEBUG）
`ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixturePriceSeries.swift`

职责：确定性种子游走生成真实感 OHLCV。纯函数，单一职责。

```swift
enum FixturePriceSeries {
    struct OHLCV: Equatable { let open, high, low, close: Double; let volume: Int }
    static func generate(count: Int) -> [OHLCV]
}
```

设计要点（精确值留给 plan，本节钉死**不变量与模型**）：
- **PRNG = SplitMix64**，由**固定种子常量**播种（不读时钟/系统随机）。`next() -> UInt64`；`unit() -> Double in [0,1)` 取高 53 位。
- **价格模型 = 对数空间均值回复游走（mean-reverting，杜绝钳位退化）**：
  `logClose[i] = logClose[i-1] + drift_k + κ·(logCenter - logClose[i-1]) + vol_k·(unit·2 - 1)`，`close[i] = exp(logClose[i])`。
  - **κ > 0 均值回复**把价格拉回中枢（`logCenter = ln(~10)`）→ 过程**有界且永不贴边**，杜绝持续 pin 到 floor/ceil 的长平台（**直接根治对抗 review High：钳位退化平台会局部重现 #7**）。
  - **drift_k（趋势段）周期性翻转符号** → MA66 跟随趋势、MACD 真实穿零；幅度受 κ 回复约束，单段不能走穿整带。
  - **vol_k（波动率段）按 PRNG 在低/高档切换**，但 **`vol_k ≥ vol_min > 0` 恒成立** → 每根 close 严格变动 → **任意 20 窗口总体 std > 0**（杜绝 BOLL 三线重合）。
  - `close[0]` 固定起点（≈10，即 `logClose[0]=logCenter`）；**首根 `r_0 := 0`**（`open[0]=close[0]`，spread/volume 用 vol_0 与 r=0 推定，确定性）。
  - 保留一对**远离操作带的硬 floor/ceil（约 `[2, 80]`）仅作有限性安全网**——均值回复保证操作上永不触及（由不变量⑥实测守门），不参与造型、不产生平台。
- **OHLC 构造**：`open[i] = close[i-1]`（首根 = close[0]）；`high = max(open,close) + spread_i`、`low = min(open,close) - spread_i`，`spread_i = vol_k 标定`（>0）→ 必满足 `high ≥ max(o,c) ≥ min(o,c) ≥ low`；`low > 0` 由价格近中枢 + 小 spread 保证（远高于 floor）。
- **volume** `= base + round(k · |r_i|)` ∝ 当根波动（`r_0:=0` → `volume[0]=base`）→ 取代现状单调递增的 `1000+i*10`。

**不变量（验收锚点）**：① 同种子两次 `generate(n)` 字节相等；② 全部 `open/high/low/close > 0 && isFinite`；③ `high ≥ max(open,close)`、`low ≤ min(open,close)`、`high ≥ low`；④ **非退化变动**——相邻 close 不恒等，整序列 return 标准差 > 0，且 **full-load(9600) m3 序列任意连续 20 根 close 的总体 std > ε**（**ε = visible-band 阈，价格相对约 `close·1e-3`，非仅 `>0` 排除精确重合** → BOLL 带肉眼可辨、永不三线重叠，直接守 #7 不局部复发；实测 vol_min~1% 下 20 窗口 std≈0.26 ≫ ε≈0.01）；⑤ `generate(n).count == n`；⑥ **永不贴边**——全序列无任何 close 触及 floor/ceil（硬安全网从不操作性触发，安全网 tripwire 非主守门）。

### 5.2 `FixtureIndicatorMath`（新，DEBUG）
`ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/FixtureIndicatorMath.swift`

职责：`[Double]` close 序列 → 指标数组，**逐字复刻后端 `backend/import_csv.py:69-89`**。纯函数。

```swift
enum FixtureIndicatorMath {
    static func ma66(_ close: [Double]) -> [Double?]                                   // 长度 == close.count
    static func boll(_ close: [Double]) -> (upper: [Double?], mid: [Double?], lower: [Double?])
    static func macd(_ close: [Double]) -> (diff: [Double?], dea: [Double?], bar: [Double?])
}
```

**公式（与后端逐条对齐，含舍入）**：
- **MA66**：`ma66[i] = i >= 65 ? round(mean(close[i-65...i]), 4) : nil`（window 66，min_periods 66，前 65 根 nil，round 4dp）。
- **BOLL**：window 20，min_periods 20，前 19 根 nil。`mid = mean(w)`；`std = sqrt(Σ(x-mid)²/20)`（**总体 std，ddof=0**，非样本）；`mid=round(mid,4)`、`upper=round(mid+2·std,4)`、`lower=round(mid-2·std,4)`。
- **MACD**：`ewm(adjust=False)` 递推 `y[0]=x[0]; y[t]=α·x[t]+(1-α)·y[t-1]`，`α=2/(span+1)`。`ema12(α=2/13)`、`ema26(α=2/27)`、`dif=ema12-ema26`、`dea=ewm(dif,span=9,α=0.2)`、**`bar=(dif-dea)*2`**。三者 round **6dp**，**从 t=0 起全非 nil**（无暖机 nil）。

**跨语言契约（验收锚点，断言用容差，镜像后端 `pytest.approx(abs=1e-4)`，非 exact `==`）**：对后端测试同款 ramp `close[i]=10.0+i*0.10`：
- `ma66(ramp(66))`：`[0..<65]` 全 nil；`|[65] - 13.25| < 1e-4`。
- `boll(ramp(25))`：`mid[..<19]` 全 nil；`|mid[19]-10.95| < 1e-4`、`|upper[19]-12.1033| < 1e-4`、`|lower[19]-9.7967| < 1e-4`。
- `macd(ramp(40))`：`diff/dea/bar` 全程非 nil。
  - **外部手算 golden（杜绝循环：不只比同文件参考递推）**：`diff[0]==0 && dea[0]==0 && bar[0]==0`；
    `diff[1] = 130.2/13 - 270.2/27 ≈ 0.007977`、`dea[1] = 0.2·diff[1] ≈ 0.001595`、`bar[1] = 2·(diff[1]-dea[1]) ≈ 0.012764`（容差 `< 1e-6`）。
    推导：`ema12[1]=(2/13)·10.1+(11/13)·10.0=130.2/13`；`ema26[1]=(2/27)·10.1+(25/27)·10.0=270.2/27`；`ema*[0]=10.0`。
  - **无暖机 nil 契约**：`macd(ramp(1))`（count==1）⇒ `diff[0]/dea[0]/bar[0]` 全非 nil 且 ==0（坐实 `ewm(adjust=False)` 首值播种、`dea` 二次 ewm 同样 t=0 有值）。
  - 末根另与同文件独立参考递推一致（结构 cross-check，非唯一 golden）。

### 5.3 `DebugFixtureData`（改）
- `CandleRow` 新增 6 字段：`bollUpper/bollMid/bollLower/macdDiff/macdDea/macdBar: Double?`。
- `make`：m3 OHLCV 改由 `FixturePriceSeries.generate(count: m3Count)`；保留 `aggregate(span:)`（先只产 OHLCV，不再就地塞 `ma66`/`nil`）；新增「对每个周期的 `rows.map(\.close)` 调 `FixtureIndicatorMath` 三函数，zip 回各 `CandleRow`」一步 → **每周期都填 MA66+BOLL+MACD**（修掉聚合周期 ma66=nil 的隐性 gap）。
- 更新文件头注释（现状写「BOLL/MACD 留 NULL」已过时）。

### 5.4 `DebugTrainingSetWriter`（改）
INSERT 把 `boll_upper/boll_mid/boll_lower/macd_diff/macd_dea/macd_bar` 从 `NULL` 改为绑定 `r.bollUpper` 等（`?` 占位 + `arguments` 追加）。schema DDL 不变（列早已存在）。

## 6. 数据流与往返保真

写库 `CandleRow.bollUpper?` → SQLite `boll_upper REAL`（nil→NULL）→ 读 `KLineRow`（既有映射）→ `KLineCandle.bollUpper: Double?` → render。暖机 nil 全程透传为 NULL（与后端 `_float_or_none` 同义）。

## 7. 决策表

| # | 决策 | 取舍 |
|---|---|---|
| D1 | 用确定性种子游走 OHLCV 替换正弦（用户选项） | 解 #4 正弦波；固定种子保可复现 |
| D2 | 两个新 DEBUG 纯单元（PriceSeries + IndicatorMath），单一职责，独立 host 测 | 隔离/可测；vs 内联在 make（不可独立测，驳回） |
| D3 | 指标公式**逐字复刻后端** import_csv.py：MA66 SMA66/min66；BOLL SMA20±2·**总体std(ddof=0)**；MACD 12/26/9 ewm(adjust=False)、**bar=(dif-dea)×2**；暖机→nil；round 4/4/6 | 跨语言契约；fixture 忠实预览真实数据；测试断言后端同款 ground truth |
| D4 | **逐周期**算指标（每周期自己的 close） | 修现状「聚合周期 ma66=nil」隐性 bug；默认 .m60/.daily MA66 终可见 |
| D5 | 确定性 SplitMix64 + 固定种子；禁 Date/arc4random/random | fixture+测试可复现；deterministic 测试可断字节相等 |
| D6 | 价格模型 = **对数空间均值回复游走**(κ>0)+趋势段(drift 翻转)+波动率段(`vol_k≥vol_min>0`)；硬 floor/ceil 仅远离带安全网 | 均值回复**杜绝钳位退化平台**（根治 review High）；vol_min>0 保每根变动；产生可见 BOLL 收张/MACD 穿零/MA66 跟随 |
| D7 | round 4/4/6 dp（同后端 DB DECIMAL(10,4)/(10,6)） | 忠实镜像真实 DB；让 isolated 测试断言后端精确数值；**连带更新现有 `ma66_rollingMean` 测试**（现断未舍入值） |
| D8 | 零外溢：不改模型/不 bump CONTRACT_VERSION/不碰 render/env，全 #if DEBUG | fixture-only，生产零风险 |
| D9 | 「每周期指标可见」断言用 `fullLoadM3Count`（9600） | 仅满载下 monthly(80)≥66、weekly(120)≥66 才有 MA66；240 下高周期暖机全 nil（非 bug） |
| D10 | 退化守门：full-load m3 序列**任意 20 窗口总体 std>ε（visible-band≈close·1e-3，非仅 >0）** + **永不贴边** 两条不变量 + host 测试 | 直接守 #7 不局部复发（BOLL 三线重合/重叠=局部重现 invisible 症状）；review High by-construction(D6) + by-test 双保险；ε 阈守「肉眼可辨」非仅「不精确重合」（review N1） |
| D11 | 指标 golden 断言用**容差**（4dp→1e-4 / 6dp→1e-6，镜像后端 approx）；MACD 加**外部手算 golden**（`diff[1]≈0.007977…`）非仅循环参考；绑定值保持 `Double?→REAL/NULL` 过 reader 亲和门 | 避开 FP exact `==` 脆性（review M2）；杜绝 MACD 同源转写 bug 双过（review M1）；记录 reader `typeof()` 隐式约束（review L2） |

## 8. 测试策略

1. **`FixtureIndicatorMathTests`**（新）：后端 ground-truth **用容差**（`|ma66@65-13.25|<1e-4` / BOLL@19 三值 `<1e-4` / **MACD 外部手算 golden `diff[1]≈0.007977`、`dea[1]≈0.001595`、`bar[1]≈0.012764`（`<1e-6`）+ `diff[0]/dea[0]/bar[0]==0` + 末根 vs 内联参考递推**）；**无暖机 nil**（`macd(ramp(1))` 三数组 `[0]` 非 nil）；暖机 nil 边界（ma66[64]=nil/[65]≠nil；boll[18]=nil/[19]≠nil）；空/短序列（count<window 全 nil）。
2. **`FixturePriceSeriesTests`**（新）：确定性（同种子字节相等）；正值&有限；OHLC 不变量（high≥max(o,c)、low≤min(o,c)、high≥low）；**非退化守门（D10）**——full-load(9600) m3 序列**任意连续 20 根 close 总体 std > ε（≈close·1e-3 visible-band 阈，非仅 >0）**（守 #7 不局部复发）+ **永不贴边**（无 close 触 floor/ceil）+ 整序列 return std>0；首根 `r_0:=0`（`open[0]==close[0]`）；计数 == n。
3. **`DebugFixtureDataTests`**（更新+新增）：
   - **更新** `ma66_rollingMean`：改断 `round(expected,4)`（D7）。
   - **新增**：满载下**每周期** ma66/boll/macd 在暖机后非 nil（监 #7 回归）；m3 与聚合周期 MA66 均非 nil（监 D4）；指标全 `isFinite`。
   - 既有不变量测试（OHLC/单调/确定性/满载根数）继续绿（walk 满足）。
4. **`DebugTrainingSetWriterTests`**（更新+新增）：既有 downstream-consumable 测试（m3Count=240 跑**完整 reader gauntlet** `openAndVerify`→`loadAllCandles`：OHLC 序 / endGlobalIndex 严格递增 / datetime 单调 / 指标有限 / 聚合 open 落窗）是**承重回归闸**——walk 须全绿。新增：取 **m3 周期**（默认 240 根即有 ≥20 bar，boll 从 idx19、macd 从 idx0 非 nil）写库→读回，断 `boll_*`/`macd_*` 读出**非 NULL** 且 `|读出 - seed CandleRow 值| < 1e-9`（往返保真，监 NULL hard-code 回归 + 监 reader `typeof()` 存储类亲和门：绑定值须 `Double?→REAL/NULL` 才过）。

## 9. 验收清单（§见独立 acceptance 文件）

人工模拟器验收（运行时观感，自动化测不到）：seed 启动后默认 `.m60/.daily` 双面板均见 MA66 线 + BOLL 三轨（收张可辨）+ 下区 MACD 柱（红绿穿零）+ DIF/DEA 双线；切换 combo 各周期均有指标；K 线呈真实感（实体/影线不均匀，非平滑正弦）。

## 10. 风险与回滚

- **风险（review High，已根治）**：种子游走若钳位会出现长平台 → BOLL std→0 三线重合 / MA 平 / MACD→0，**局部重现 #7**。缓解：① by-construction 均值回复(κ>0)+`vol_min>0` 使过程有界且每根变动、永不贴边；② by-test D10「任意 20 窗口总体 std>0」+「永不贴边」在**实测 full-load 序列**上守门。硬 floor/ceil 仅有限性安全网，操作上不触发。
- **风险**：Swift 浮点与 pandas ewm 长序列累积误差 → 缓解：isolated 测试用短 ramp 对后端 golden（含外部手算 MACD literal，容差 1e-4/1e-6）；fixture 测试只断「非 nil + 有限 + 非退化」不断绝对值。
- **回滚**：全 `#if DEBUG`、单 PR、零生产/契约改动 → revert 即复原，无迁移。
