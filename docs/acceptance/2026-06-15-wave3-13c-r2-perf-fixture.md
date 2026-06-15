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
| 7 | 运行 `grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 所有命中行（residual 行 + 收敛说明行）均含 `accept residual`、且均**不**含 `RESOLVED`（13c-R1 采样≠帧相关 未被本 PR 关闭） | ☐ Pass / ☐ Fail |

## 四、device 帧预算（可选，非本 PR 关闭门）

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 8 | 按 `docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md`：Debug 包 `KLINE_SEED_FIXTURE=1` 启动一次 seed → 不删 app → Release Profile（⌘I）；进一局默认面板（.m60/.daily） | 默认面板渲染蜡烛数 ≥ 240（满载，非欠载）；帧预算回填表记录所测周期 + 渲染蜡烛数 | ☐ Pass / ☐ Fail / ☐ 未测（device 职责） |

> 说明：item 8 是 device 实测，属运行时矩阵 ③ 范畴；本 PR 仅交付「满载 fixture 代码 + 测试 + residual 关闭」，item 8 由 user 在 device 回填，不阻塞本 PR 合入。
