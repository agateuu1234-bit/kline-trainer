# Wave 3 13c-R2 — 帧预算满载 perf fixture（DebugFixtureData 代码增强）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 根治残留 **13c-R2（帧预算 fixture 欠载）**——增强 `DebugFixtureData`，使 §C 调试 seed 的每个可被剖析（profiled）周期达到满载渲染负载，从而帧预算 runbook 测的是满载图表而非欠载图表。

**Architecture:** 单点数据改动。§C seed 当前以 `DebugFixtureData.make(m3Count: 240)` 生成，按既有聚合 span（1/5/20/40/80/120）派生 6 周期 → `.m60`=12 / `.daily`=6 等远低于渲染负载。本 PR **不改聚合 span、不改 `make` 签名**，仅引入命名常量 `fullLoadM3Count = 9600` 并把 `AppContainer.seedDebugFixtures` 的 seed 调用点改用该常量。9600 是同时满足「每周期 ≥ `defaultVisibleCount`(80)」与「make 默认面板 `.m60`/`.daily` ≥ `maxVisibleCount`(240)」的最小 m3 根数（推导见下）。配套：1 个纯函数满载回归测试 + 1 个端到端「实际 seeded 缓存 fixture 满载」测试 + 关闭 13c-R2 residual 的 doc 更新。

**Tech Stack:** Swift 6 / Swift Package Manager（`ios/Contracts`）/ Swift Testing / GRDB（SQLite 写入）/ `#if DEBUG`-only fixture 代码。

---

## 背景与精确问题陈述

### 残留来源（已 merged 入 main）
- **`docs/acceptance/2026-06-14-wave3-pr13c-completion.md`** Residual 表：
  > **13c-R2：帧预算 fixture 欠载** —— §C seed `.m60`=12/`.daily`=6 < `RenderStateBuilder` 80-visible 渲染负载 → 经 §C fixture 测的是欠载图表 | codex R8-H2 | **accept residual**：根治 = 13b `DebugFixtureData` **代码增强**（各 profiled 周期 ≥80 蜡烛），超 13c doc-only scope → fast-follow perf-fixture PR
- **`docs/acceptance/2026-06-14-wave3-runtime-matrix.md`** R8-H2 caveat：要求满载测量需「各 profiled 周期 ≥80 蜡烛的 perf fixture（13b `DebugFixtureData` 代码增强）」；并要求回填帧预算时记录所测周期 + 实际渲染蜡烛数，蜡烛数 < 80 标「欠载（非满载达标）」。

**本 PR 即该 fast-follow perf-fixture PR。**

### 渲染负载常量（source-of-truth，勿在本 PR 改）
- `RenderStateBuilder.defaultVisibleCount = 80`（`ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift:13`）—— seed/fallback 单一来源，帧预算 runbook caveat 引用的「80-visible 渲染负载」即此。
- `PinchZoomModel.maxVisibleCount = 240`（`ios/Contracts/Sources/KlineTrainerContracts/Render/PinchZoomModel.swift:10`）—— pinch 缩放最远档（zoom-out）可见根数；`minVisibleCount = 20`。
- `RenderStateBuilder` 实际渲染根数 = `min(target, count)`（`RenderStateBuilder.swift:65`），其中 `count` = 该周期蜡烛数组长度。故当周期蜡烛数 < target 时，图表只能渲染全部蜡烛（欠载）。

### 哪些周期是 "profiled"
周期组合序列（`TrainingEngine.swift:302-304`，plan v1.5 L782）：`(.m3,.m15) ←→ (.m15,.m60) ←→ (.m60,.daily) ←→ (.daily,.weekly) ←→ (.weekly,.monthly)`。**全部 6 周期都可作为面板被显示/剖析**；`TrainingEngine.make` 默认上区 `.m60`、下区 `.daily`（`AppContainerDebugSeedTests.seed_freshStartSucceeds` 锁定）。帧预算 runbook（顺位 12）的 pinch 场景（#2）会从默认 80 缩放到「更大/更小范围」——最远档即 `maxVisibleCount`(240)。

### 目标与 m3Count 推导
**目标：** seed fixture 满足
1. **每周期蜡烛数 ≥ `defaultVisibleCount`(80)** —— 没有任何可显示周期被标「欠载」；
2. **make 默认面板 `.m60`/`.daily` 蜡烛数 ≥ `maxVisibleCount`(240)** —— 默认剖析面板在 pinch 最远档仍满载（不欠载）。

聚合 span 不变（1/5/20/40/80/120）。设 m3 根数 = `M`，则周期 `p` 的行数 ≈ `M / span_p`（9600 对全部 span 整除，无残组）。
- 约束 1 由最粗 span（monthly=120）决定：`M/120 ≥ 80 → M ≥ 9600`。
- 约束 2 由默认面板较粗 span（daily=40）决定：`M/40 ≥ 240 → M ≥ 9600`。

两约束最小公共解 **`M = 9600`**（注：`80 × 120 = 240 × 40 = 9600`，两条推导收敛同值）。

**`fullLoadM3Count = 9600` 各周期行数：**

| 周期 | span | 行数（9600 / span） | ≥80 | 备注 |
|---|---|---|---|---|
| `.m3` | 1 | 9600 | ✓ | |
| `.m15` | 5 | 1920 | ✓ | |
| `.m60` | 20 | 480 | ✓ | make 默认上区 ≥240 ✓ |
| `.daily` | 40 | 240 | ✓ | make 默认下区 =240 ✓ |
| `.weekly` | 80 | 120 | ✓ | |
| `.monthly` | 120 | 80 | ✓ | =80（约束 1 临界） |

总行数 ≈ 9600+1920+480+240+120+80 = **12,440 行**（单事务 SQLite 写入，DEBUG-only，一次性，耗时数十毫秒级）。

---

## 决策（Decisions）— 供 plan-review 对抗审查

- **D1（满载目标）：** 默认面板目标定 ≥`maxVisibleCount`(240) 而非仅 ≥`defaultVisibleCount`(80)。理由：帧预算 runbook 的 pinch 场景显式缩放到最远档（240 可见）；若仅 ≥80，pinch zoom-out 时默认面板仍欠载，等于在「满载」名义下保留新的欠载缺口。≥240 **严格满足**残留文本「≥80」并额外覆盖 pinch 最坏档。其余周期保 ≥80（残留字面 bar），原因见 D2。
- **D2（覆盖周期）：** 6 周期全部 ≥80。理由：周期组合序列使任一周期都可作面板被剖析；矩阵 caveat 要求「记录所测周期 + 渲染蜡烛数，<80 标欠载」——若任一周期 <80，回填时仍会出现「欠载」标记，残留未真正闭合。注：渲染耗时由可见蜡烛数（≤240）驱动、与周期标识无关，故默认面板（`.m60`/`.daily`）满载已代表全周期渲染成本；其余周期 ≥80 是为消除「欠载」标记 + 组合切换覆盖，不需 ≥240。
- **D3（实现方式 = 单 fixture，仅改 seed 调用点）：** 不新增独立 perf-seed 路径 / 不新增环境变量 / 不改聚合 span。§C seed 既是「全 app fixture provisioning」、帧预算 runbook 又复用同一 seeded app（Debug-seed → Release-profile 衔接），故把这唯一 fixture 升为满载即可，无需第二条 seeding 路径。代价：日常 DEBUG seed 由 240 → 9600 根 m3（12,440 总行），属 `#if DEBUG`、一次性、数十毫秒，可接受且对手动矩阵测试是"更丰富数据"的正向作用。
- **D4（不改 `make` 签名/默认值）：** `make(m3Count: Int = 240)` 签名与既有 `DebugFixtureDataTests`（显式传 240/100）不动——surgical。仅新增常量 `fullLoadM3Count` 并在 seed 调用点使用。
- **D5（doc 关闭范围）：** 仅关闭 **13c-R2**（fixture 欠载）。**13c-R1（采样≠帧相关，os_signpost 生产 instrumentation）保持 OPEN**——其根治是另一类生产代码改动，不在本 PR scope。

### 已考虑并否决的替代
- **A1：仅把默认面板（`.m60`/`.daily`）做到 ≥80（m3Count=3200）。** 否决：weekly/monthly 仍 <80 → 组合切换后回填仍现「欠载」；且默认面板 pinch zoom-out（240）欠载未解。
- **A2：缩小聚合 span（如 1/2/4/6/8/12）以更小 m3Count 达标。** 否决：改动既有 merged 13b fixture 的周期语义（非 surgical），收益仅"更小总行数"，而 9600 行的成本已可忽略。
- **A3：新增独立 perf-seed 路径 + 环境变量（`KLINE_SEED_FIXTURE=perf`）。** 否决：需改 `KlineTrainerApp` + `AppContainer` 接线，且帧预算 runbook 须改用新 env——更多代码 + 更多衔接面，违反 YAGNI；单 fixture 升满载已满足同一被剖析 app 的需求。

---

## File Structure

| 文件 | 操作 | 责任 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift` | Modify | 新增 `public static let fullLoadM3Count = 9600`（含推导注释）；`make`/聚合逻辑不动 |
| `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift` | Modify | seed 调用点 `DebugFixtureData.make(m3Count: 240)` → `make(m3Count: DebugFixtureData.fullLoadM3Count)` |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift` | Modify | 新增纯函数满载回归测试（每周期 ≥80 + 默认面板 ≥240 + 满载下结构不变量仍成立） |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift` | Modify | 新增端到端测试：打开实际 seeded 缓存 fixture，`loadAllCandles()` 验每周期 ≥80 + 默认面板 ≥240 |
| `docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | Modify | Residual 表 13c-R2 → RESOLVED（保留原描述，附本 PR 解决说明）；13c-R1 保持 OPEN |
| `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | Modify | R8-H2 caveat：标注 perf-fixture 代码增强已 ship（本 PR），§C seed 现满载（≥80 全周期 / ≥240 默认面板）；保留「回填记录周期+蜡烛数」实践 |
| `docs/governance/2026-06-14-wave3-completion.md` | Modify | 运行时矩阵行：fixture 欠载（13c-R2）标 RESOLVED；采样≠帧相关（13c-R1）保持记录 |
| `docs/acceptance/2026-06-15-wave3-13c-r2-perf-fixture.md` | Create | 非编码者验收清单（action / expected / pass-fail；中文） |

---

## Task 1：满载常量 + 纯函数满载回归测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift`

- [ ] **Step 1: 写失败测试（RED——编译失败 + 行为断言）**

在 `DebugFixtureDataTests.swift` 的 `#if DEBUG ... struct DebugFixtureDataTests { ... }` 内新增（注意 import 已含 `import KlineTrainerContracts`，可直接引用 `RenderStateBuilder` / `PinchZoomModel`）：

```swift
    // 13c-R2 根治：满载 fixture——每周期 ≥ defaultVisibleCount(80)，默认面板 .m60/.daily ≥ maxVisibleCount(240)。
    // 断言用渲染常量（非循环），把 fixture 直接绑到真实渲染负载。
    @Test("满载常量 fullLoadM3Count：每周期 ≥ defaultVisibleCount(80)，默认面板 .m60/.daily ≥ maxVisibleCount(240)")
    func fullLoadFixture_everyPeriodMeetsRenderLoad() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        for period in Period.allCases {
            let count = data.candles.first(where: { $0.period == period })?.rows.count ?? 0
            #expect(count >= RenderStateBuilder.defaultVisibleCount,
                    "周期 \(period) 蜡烛数 \(count) 须 ≥ defaultVisibleCount(\(RenderStateBuilder.defaultVisibleCount))（非欠载）")
        }
        let m60 = data.candles.first(where: { $0.period == .m60 })?.rows.count ?? 0
        let daily = data.candles.first(where: { $0.period == .daily })?.rows.count ?? 0
        #expect(m60 >= PinchZoomModel.maxVisibleCount,
                "默认上区 .m60 蜡烛数 \(m60) 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))（pinch 最远档满载）")
        #expect(daily >= PinchZoomModel.maxVisibleCount,
                "默认下区 .daily 蜡烛数 \(daily) 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))（pinch 最远档满载）")
    }

    // 满载根数（9600）下，既有 reader 结构不变量仍成立（防大 count 触发聚合 off-by-one / end_global_index 越界）。
    @Test("满载下：全 6 周期 end_global_index 单调递增 + <= max m3 end + 末行 == max m3 end")
    func fullLoadFixture_invariantsStillHold() {
        let data = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
        let maxM3End = data.candles.first(where: { $0.period == .m3 })!.rows.map(\.endGlobalIndex).max()!
        for period in Period.allCases {
            let rows = data.candles.first(where: { $0.period == period })!.rows
            #expect(!rows.isEmpty)
            var prevEnd = -1
            for c in rows {
                #expect(c.endGlobalIndex <= maxM3End)
                #expect(c.endGlobalIndex > prevEnd)
                if period != .m3 { #expect(c.globalIndex == nil) }
                prevEnd = c.endGlobalIndex
            }
            #expect(rows.last!.endGlobalIndex == maxM3End, "周期 \(period) 末行 end 须覆盖到 max m3 end")
        }
    }
```

- [ ] **Step 2: 运行测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter DebugFixtureDataTests`
Expected: 编译失败 —— `type 'DebugFixtureData' has no member 'fullLoadM3Count'`。

- [ ] **Step 3: 加常量（最小实现）**

在 `DebugFixtureData.swift` 的 `public enum DebugFixtureData {` 之后、`public struct CandleRow` 之前（或紧邻 `baseEpoch`/`m3Step` 常量处）新增：

```swift
    /// 帧预算满载 fixture 根数（Wave 3 13c-R2 根治）。
    /// 按既有聚合 span（1/5/20/40/80/120），9600 根 m3 使**每周期 ≥ RenderStateBuilder.defaultVisibleCount(80)**
    /// 且 **make 默认面板 .m60(=480)/.daily(=240) ≥ PinchZoomModel.maxVisibleCount(240)**（pinch 缩放最远档可见根数），
    /// 故经 §C seed 的帧预算 runbook 测的是满载图表（非欠载）。
    /// 推导：约束「monthly span=120 行数 ≥80」与「daily span=40 行数 ≥240」最小公共解 = 80×120 = 240×40 = 9600。
    public static let fullLoadM3Count = 9600
```

- [ ] **Step 4: 运行测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter DebugFixtureDataTests`
Expected: PASS（含既有 6 个 + 新增 2 个测试全绿）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/DebugFixtureDataTests.swift
git commit -m "feat(13c-R2): DebugFixtureData.fullLoadM3Count=9600 满载常量 + 纯函数满载回归测试"
```

---

## Task 2：seed 调用点接满载常量 + 端到端 seeded-fixture 满载测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift:38`（`make(m3Count: 240)` 调用点）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift`

- [ ] **Step 1: 写失败测试（RED——seeded 缓存 fixture 仍欠载）**

在 `AppContainerDebugSeedTests.swift` 的 `#if DEBUG ... struct AppContainerDebugSeedTests { ... }` 内新增（`makeConfig()` helper 已存在，可复用）：

```swift
    // 13c-R2 根治端到端：实际 seeded + cached 的训练组（= 帧预算 runbook 真正剖析的那份）须满载。
    // 直接打开缓存 sqlite，loadAllCandles() 验每周期渲染负载——证 seed 调用点确用满载根数（非仅 make 能力）。
    @Test("seeded 缓存 fixture 满载：每周期 ≥ defaultVisibleCount(80)，默认面板 .m60/.daily ≥ maxVisibleCount(240)")
    func seededFixture_isFullLoad() async throws {
        let (cfg, dir) = try makeConfig()
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try AppContainer(config: cfg, debugSeedFixtures: true)
        let file = c.cache.listAvailable().first!
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let byPeriod = try reader.loadAllCandles()
        for period in Period.allCases {
            let count = byPeriod[period]?.count ?? 0
            #expect(count >= RenderStateBuilder.defaultVisibleCount,
                    "seeded 周期 \(period) 蜡烛数 \(count) 须 ≥ defaultVisibleCount(\(RenderStateBuilder.defaultVisibleCount))")
        }
        #expect((byPeriod[.m60]?.count ?? 0) >= PinchZoomModel.maxVisibleCount,
                "seeded .m60 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))")
        #expect((byPeriod[.daily]?.count ?? 0) >= PinchZoomModel.maxVisibleCount,
                "seeded .daily 须 ≥ maxVisibleCount(\(PinchZoomModel.maxVisibleCount))")
    }
```

- [ ] **Step 2: 运行测试确认失败（RED）**

Run: `cd ios/Contracts && swift test --filter AppContainerDebugSeedTests`
Expected: 新测试 FAIL —— seed 仍用 `make(m3Count: 240)`，`.m60`=12 / `.daily`=6 < 80，断言失败（既有 8 个测试仍 PASS）。

- [ ] **Step 3: 改 seed 调用点（最小实现）**

`AppContainer+DebugSeed.swift` 内：

```swift
        let seed = DebugFixtureData.make(m3Count: DebugFixtureData.fullLoadM3Count)
```

（替换原 `let seed = DebugFixtureData.make(m3Count: 240)`。）

- [ ] **Step 4: 运行测试确认通过（GREEN）**

Run: `cd ios/Contracts && swift test --filter AppContainerDebugSeedTests`
Expected: PASS（新测试 + 既有 8 个 seed 测试全绿；幂等/全空 guard/resume/review/replay 不受根数影响）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift
git commit -m "feat(13c-R2): seed 调用点接 fullLoadM3Count + 端到端 seeded-fixture 满载测试"
```

---

## Task 3：关闭 13c-R2 residual + 更新矩阵 caveat / completion 治理 doc

**Files:**
- Modify: `docs/acceptance/2026-06-14-wave3-pr13c-completion.md`（Residual 表）
- Modify: `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`（R8-H2 caveat）
- Modify: `docs/governance/2026-06-14-wave3-completion.md`（运行时矩阵行）

- [ ] **Step 1: completion doc Residual 表 —— 仅 13c-R2 → RESOLVED（13c-R1 行不动）**

> **实施者：编辑前先 `Read` 该文件确认当前精确文本（含 `**` 粗体标记），做精确 old→new 替换。只改 13c-R2 行的「处理」单元格，绝不触 13c-R1 行（保持其 `accept residual` 原状）。**

在 `docs/acceptance/2026-06-14-wave3-pr13c-completion.md` Residual 表中，把 **13c-R2 行的「处理」单元格**（当前为）：

```
**accept residual**：根治 = 13b `DebugFixtureData` **代码增强**（各 profiled 周期 ≥80 蜡烛），超 13c doc-only scope。doc-only 已做：矩阵 ③ caveat 要求记录周期+渲染蜡烛数，<80 标「欠载非满载 PASS」 → fast-follow perf-fixture PR
```

替换为：

```
**RESOLVED（Wave 3 13c-R2 fast-follow PR，2026-06-15）**：根治 = `DebugFixtureData` 新增 `fullLoadM3Count`=9600 并由 `AppContainer.seedDebugFixtures` 使用 → §C seed 现满载：每周期 ≥ `defaultVisibleCount`(80)、make 默认面板 `.m60`=480/`.daily`=240 ≥ `maxVisibleCount`(240，pinch 最远档)。回归测试 `DebugFixtureDataTests.fullLoadFixture_*` + `AppContainerDebugSeedTests.seededFixture_isFullLoad`（原 accept-residual 表述见 git 历史）
```

> 注：**不**在本单元格内写「13c-R1」字样——保持 `grep "13c-R1"` 仅命中 13c-R1 自身行（消除跨行 grep 歧义，见 Step 4 / Task 4 item 7）。13c-R1 行保持 `accept residual` 不变。

- [ ] **Step 2: runtime-matrix R8-H2 caveat 更新**

在 `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` 的 `R8-H2 fixture 欠载` caveat 段，在原描述后补 RESOLVED 说明（保留原"已知限制"历史叙述 + 标注已根治）：

```
> **【RESOLVED 2026-06-15，Wave 3 13c-R2 fast-follow】** perf-fixture 代码增强已 ship：`DebugFixtureData.fullLoadM3Count`(=9600) 经 `AppContainer.seedDebugFixtures` 使用 → §C seed 各周期 ≥ `defaultVisibleCount`(80)、make 默认面板 `.m60`(=480)/`.daily`(=240) ≥ `maxVisibleCount`(240)。**经 §C seed 剖析默认面板现为满载（非欠载）。** 回填仍须记录「所测周期 + 实际渲染蜡烛数」；若所测周期蜡烛数 ≥80 即满载达标，仅当人为切到行数 <80 的极端构造（非 §C 默认）才标欠载。
```

- [ ] **Step 3: governance completion doc 行更新（精确替换，含 `**` 粗体标记 + 尾部括号）**

> **实施者：先 `Read` 确认精确文本。该行 13c-R1 与 13c-R2 同句 bundle，须拆开——13c-R2 标 RESOLVED、13c-R1 保持 accept residual。**

在 `docs/governance/2026-06-14-wave3-completion.md` 运行时矩阵行中，把以下**精确子串**（注意 `**…**` 粗体与尾部括号）：

```
**帧预算 device 测量精度限制**（采样≠帧相关 / fixture 欠载）记 acceptance **13c-R1/R2**（codex R8，accept residual，根治 = fast-follow 性能代码 PR，超 doc-only scope；矩阵 ③ caveat 已如实标指示性上界 + 欠载）
```

替换为：

```
**帧预算 device 测量精度限制**：①采样≠帧相关（**13c-R1，accept residual / OPEN**，根治 = os_signpost 生产 instrumentation，超 doc-only scope）；②fixture 欠载（**13c-R2，RESOLVED 2026-06-15**：`DebugFixtureData.fullLoadM3Count`=9600 满载 perf fixture，§C seed 现 ≥80 全周期 / ≥240 默认面板）
```

- [ ] **Step 4: grep 验证 doc drift（散文↔状态一致）**

Run（验证 13c-R2 已 flip RESOLVED，且 13c-R1 在 completion 表**未被** flip——保持 `accept residual`）：
```bash
# 13c-R2 三处均带 RESOLVED
grep -n "13c-R2" docs/acceptance/2026-06-14-wave3-pr13c-completion.md \
                 docs/acceptance/2026-06-14-wave3-runtime-matrix.md \
                 docs/governance/2026-06-14-wave3-completion.md
# 13c-R1 在 completion residual 表仍为 accept residual（未误关闭）；且该行不含 RESOLVED
grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md
```
Expected:
- 每处 `13c-R2` 命中行均含 `RESOLVED`，且无与 RESOLVED 矛盾的「accept residual / 未来时 fast-follow」并存于同一 13c-R2 行；
- completion doc 的 `13c-R1` 命中**仅其自身 residual 行**（无跨行歧义，因 Step 1 已确保 13c-R2 单元格不含「13c-R1」字样），且该行仍含 `accept residual`、**不**含 `RESOLVED`（13c-R1 未被本 PR 关闭）。

- [ ] **Step 5: 提交**

```bash
git add docs/acceptance/2026-06-14-wave3-pr13c-completion.md \
        docs/acceptance/2026-06-14-wave3-runtime-matrix.md \
        docs/governance/2026-06-14-wave3-completion.md
git commit -m "docs(13c-R2): 关闭 fixture 欠载 residual（满载 perf fixture 已 ship）；13c-R1 保持 OPEN"
```

---

## Task 4：非编码者验收清单

**Files:**
- Create: `docs/acceptance/2026-06-15-wave3-13c-r2-perf-fixture.md`

- [ ] **Step 1: 写验收 doc（中文；action / expected / pass-fail；禁用 forbidden_phrases）**

forbidden_phrases（`.claude/workflow-rules.json`，禁止出现）：`验证通过即可` / `看起来正常` / `应该没问题` / `should work` / `looks fine`。

写入以下内容（每行 pass/fail 二元可判）：

```markdown
# Wave 3 13c-R2 验收清单 — 帧预算满载 perf fixture

**日期**：2026-06-15
**性质**：CLI 可执行（host 单测）；非编码者按步运行命令、对照输出判定
**执行者**：user（无需读 Swift 代码，仅运行命令并对照预期输出）

---

## 一、自动化测试（CLI）

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | 终端进 `ios/Contracts`，运行 `swift test --filter DebugFixtureDataTests` | 末行含 `Test run with N tests ... passed`，`0 failures`；含测试名 `fullLoadFixture_everyPeriodMeetsRenderLoad`、`fullLoadFixture_invariantsStillHold` 均 passed | ☐ Pass / ☐ Fail |
| 2 | 运行 `swift test --filter AppContainerDebugSeedTests` | 末行 `passed`，`0 failures`；含 `seededFixture_isFullLoad` passed | ☐ Pass / ☐ Fail |
| 3 | 运行整包 `swift test` | 末行 `Test run with N tests in M suites passed`（N ≥ 1015，= 基线 1013 + 本 PR 新增 3），`0 failures` | ☐ Pass / ☐ Fail |

## 二、满载常量核对（命令输出）

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 4 | 运行 `grep -n "fullLoadM3Count = 9600" ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift` | 命中 1 行（常量值 = 9600） | ☐ Pass / ☐ Fail |
| 5 | 运行 `grep -n "make(m3Count: DebugFixtureData.fullLoadM3Count)" ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift` | 命中 1 行（seed 调用点已接满载常量） | ☐ Pass / ☐ Fail |

## 三、residual 关闭核对

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 6 | 运行 `grep -n "13c-R2" docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 命中行含 `RESOLVED`；无「accept residual」与之并存的未关闭表述 | ☐ Pass / ☐ Fail |
| 7 | 运行 `grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 命中其 residual 行仍含 `accept residual`、且**不**含 `RESOLVED`（13c-R1 采样≠帧相关 未被本 PR 关闭） | ☐ Pass / ☐ Fail |

## 四、device 帧预算（可选，非本 PR 关闭门）

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 8 | 按 `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`：Debug 包 `KLINE_SEED_FIXTURE=1` 启动一次 seed → 不删 app → Release Profile（⌘I）；进一局默认面板（.m60/.daily） | 默认面板渲染蜡烛数 ≥ 240（满载，非欠载）；帧预算回填表记录所测周期 + 渲染蜡烛数 | ☐ Pass / ☐ Fail / ☐ 未测（device 职责） |

> 说明：item 8 是 device 实测，属运行时矩阵 ③ 范畴；本 PR 仅交付「满载 fixture 代码 + 测试 + residual 关闭」，item 8 由 user 在 device 回填，不阻塞本 PR 合入。
```

- [ ] **Step 2: 提交**

```bash
git add docs/acceptance/2026-06-15-wave3-13c-r2-perf-fixture.md
git commit -m "docs(13c-R2): 非编码者验收清单（满载 fixture host 测 + residual 关闭核对）"
```

---

## Self-Review（plan 作者自查）

**1. Spec/residual 覆盖：**
- 残留文本「各 profiled 周期 ≥80 蜡烛」→ Task 1/2 测试断言每周期 ≥80（D2）。✓
- 「13b `DebugFixtureData` 代码增强」→ Task 1 常量 + Task 2 seed 接线。✓
- 矩阵 caveat「回填记录周期+渲染蜡烛数 / <80 标欠载」→ Task 3 Step 2 保留该实践并标满载已 ship。✓
- 「fast-follow perf-fixture PR」→ 本 PR 即是；Task 3 关闭 residual。✓
- 13c-R1 不在 scope → D5 + Task 3 多处保持 OPEN。✓

**2. Placeholder 扫描：** 所有 step 含真实代码/命令/预期；无 TBD/TODO/"handle edge cases"。✓

**3. 类型一致性：**
- `fullLoadM3Count`（`public static let`，Int 9600）—— Task 1 定义、Task 2 测试 + seed 调用点引用，命名一致。✓
- `DebugFixtureData.make(m3Count:)` / `.candles` / `PeriodCandles.rows` / `CandleRow.endGlobalIndex`/`.globalIndex` —— 对齐既有源码（已读）。✓
- `RenderStateBuilder.defaultVisibleCount`(80) / `PinchZoomModel.maxVisibleCount`(240) —— `public static let`，测试目标 import `KlineTrainerContracts` 可见。✓
- `DefaultTrainingSetDBFactory().openAndVerify(file:expectedSchemaVersion:)` + `reader.loadAllCandles() -> [Period:[KLineCandle]]` + `c.cache.listAvailable().first!.localURL` —— 对齐既有 `AppContainerDebugSeedTests` 与 reader 协议。✓
- `Period.allCases` —— `Period` 是 `CaseIterable`（`Models.swift:11`）。✓

**4. 不变量复核：** 9600 对全部 span（1/5/20/40/80/120）整除 → 无残组、末行 end == max m3 end；MA66 滑窗 O(66·n) 非 O(n²)；pending tick=4800、record finalTick=9599 均在 [0,9599] 内（resume/review/replay 测试不受影响）。✓

---

## 验收命令（执行末态门）

```bash
cd ios/Contracts && swift test            # 全绿，N ≥ 1015，0 failures
# Catalyst build-for-testing（CI 等价；本地 de-risk）
xcodebuild build-for-testing -scheme <app-scheme> -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -5  # BUILD SUCCEEDED
```

## 风险 / 残留
- **R-本PR-1**：日常 DEBUG seed 由 240→9600 m3（12,440 行）；属 `#if DEBUG`、一次性、数十毫秒。seed 测试会多付数十毫秒，可接受。
- **13c-R1（采样≠帧相关）保持 OPEN**——非本 PR scope（os_signpost 生产 instrumentation）。
- 本 PR **不含** device 帧预算实测回填（运行时矩阵 ③，user/device 职责）；本 PR 只解「满载 fixture 不存在」这一阻塞，使 ③ 的满载测量成为可能。

## Trust-boundary 检查
本 PR 仅改 `#if DEBUG` fixture Swift + 测试 + docs；**不触** `.github/workflows/*`、`codeowners`、hooks、`workflow-rules.json` 等 trust-boundary。走常规对抗审查（user 指定 opus 4.8 xhigh），无需 codeowners Approve。
