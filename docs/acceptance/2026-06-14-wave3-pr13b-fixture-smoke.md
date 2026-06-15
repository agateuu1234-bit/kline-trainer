# PR Wave 3 13b 验收清单（中文非-coder 可执行）

**PR 范围**：§C debug-only 全 app fixture provisioning（经 AppContainer seed 缓存+pending+history，使运行时矩阵可在真 app 跑）+ §D 生产路径 E2E smoke（真实 DownloadAcceptanceRunner 下游可消费）。改 `ios/**/*.swift` + app target；新增 host 测；0 schema/CI workflow 改动（app-build 既有）。

**source-of-truth**：spec `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §C/§D；plan `docs/superpowers/plans/2026-06-14-wave3-pr13b-fixture-smoke.md`。

**评审通道（trust-boundary）**：改 `ios/**/*.swift` + app target → 须经 `codex:adversarial-review`（配额耗尽 fallback opus 4.8 xhigh）+ Catalyst + app-build required check。

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 `DebugFixtures/` 3 新文件（`#if DEBUG`）+ `KlineTrainerApp.swift` 改 + 4 测试文件 + 本 acceptance | □ Pass / □ Fail |
| 2 | 看 `DebugFixtureData.swift` | 整文件 `#if DEBUG` 包裹；确定性（无随机，仅 sin+整数运算）；m3 0 基递增 global==end + 有效 OHLC + MA66 rolling | □ Pass / □ Fail |
| 3 | 看 `DebugFixtureDataTests.swift` | 含 5 测试：m3 不变量 / daily end<=max / MA66 / 确定性 / 描述自洽 | □ Pass / □ Fail |
| 4 | 看 `DebugTrainingSetWriter.swift` | `#if DEBUG`；schema 对齐（user_version=1 + meta + klines + 索引），与 `TrainingSetSQLiteFixture` 同口径 | □ Pass / □ Fail |
| 5 | 看 `DebugTrainingSetWriterTests.swift` | 写出的 sqlite 经真 `DefaultTrainingSetDBFactory.openAndVerify` + `loadAllCandles` 240 m3 + daily | □ Pass / □ Fail |
| 6 | 看 `AppContainer.swift` + `AppContainer+DebugSeed.swift` | seed 在 `AppContainer.init(debugSeedFixtures:)` 内、**SettingsStore 构造前**调（codex-13b-R3：settings 不 stale）；`static seedDebugFixtures(db:cache:)` `#if DEBUG`；**全空 guard**（cache + history + pending 全空才 seed，codex-13b-R1：iOS 清 Caches 但留 app.sqlite → 不破坏真实数据）；cache 最后写（codex-13b-R2 缓解） | □ Pass / □ Fail |
| 7 | 看 `AppContainerDebugSeedTests.swift` | 含 6 测试：seed 填 cache/history/pending + loadHome + **settings 反映 fixture（非 stale 0）** / 未 seed settings=0 对照 / 幂等不叠加 / pending 可 resume / **cache 空但 db 有真实 history → 拒绝** / **cache 空但有真实 pending/settings → 拒绝不覆盖** | □ Pass / □ Fail |
| 8 | 看 `KlineTrainerApp.swift` diff | `#if DEBUG` 内读 `env KLINE_SEED_FIXTURE=="1"` → 传 `AppContainer(config:, debugSeedFixtures:)`；默认关；Release `seedFixtures=false` + AppContainer 内 seed 块 `#if DEBUG` 剔除 | □ Pass / □ Fail |
| 9 | 看 `DownloadAcceptanceRunnerIntegrationTests.swift` diff | 新增 `run_realPipeline_storedSetIsDownstreamConsumable`：真栈 download→confirm→**重开 cache 副本 + loadAllCandles**（非输入 fixture） | □ Pass / □ Fail |
| 10 | 看 CI 「swift test on macos-15」 | 绿（全量 1002 tests in 144 suites pass，新增 §C 9 + §D 1 = 10 测试无失败） | □ Pass / □ Fail |
| 11 | 看 CI 「Mac Catalyst build-for-testing」+「app-build」 | 均绿（含 app target Debug 编译——本地无 iOS platform，靠 app-build CI 验证） | □ Pass / □ Fail |
| 12 | 看 codex 对抗 review verdict | APPROVE（或 codex 配额耗尽→opus 4.8 xhigh fallback APPROVE / accept residual + override） | □ Pass / □ Fail |

## Release 隔离守卫

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 13 | 看 `DebugFixtures/` 所有文件 + `KlineTrainerApp` seed 块 | 均 `#if DEBUG`（Release 编译期剔除整 seed 路径 + fixture 生成代码） | □ Pass / □ Fail |
| 14 | 看 `KlineTrainerApp` seed 调用 | `#if DEBUG` 内 + 运行期 env opt-in 默认关（正常 debug 启动不 seed） | □ Pass / □ Fail |

## 范围注 / 已知行为（plan 决策）

- **指标**：seed 计算 MA66（主叠加渲染）；BOLL/MACD 留 NULL（schema nullable；交互矩阵不需指标精度，full parity 归 backend `import_csv`）。
- **seed 周期面**：seed 写 `.m3` + `.daily` 两周期（运行时矩阵交互所需）。不满足下载验收 `verifyNonEmpty` 的全 6 周期×≥30 要求，但 seed 走 `cache.store` 直注**不经**验收路径；运行时矩阵的 start/resume/review/replay 均经 `openAndVerify`（不调 verifyNonEmpty），故 seed 组对全部会话路径可开。
- **reset**：app.sqlite singleton → 删 app 重置（DEBUG-only 可接受）。
- **运行时矩阵 device/sim 实测执行**归顺位 13c（runbook）+ 用户 device 职责。

## Residual（codex 13b review）

| Residual | 来源 | 处理 |
|---|---|---|
| **13b-R1：极端 partial-seed**——全空 guard + cache-last 已 cover 常见 partial（db 写失败 → cache 仍空 → 下次重 seed）；但 db 写**到一半**（如 record0 写了 record1 失败）后，全空 guard（history 非空）会跳过 → 留 partial。DEBUG-only、IO 失败罕见 → **删 app 重置** | codex-13b-R2-F3 + R3-F1（partial-failure 健壮性）| **accept residual**（debug-only 工具；2-state「seeding/done」durable marker + 单事务 retry 属过度工程）|
| **13b-R3：settings-row 零值歧义**——全空 guard 已检查 settings 须零值默认（保护非零 fees/capital）；但「用户在 fresh app 显式 `resetCapital→0` 且从没设 commission」与「settings 表缺 row」值上都是 0，无法区分 → 该极窄场景（+ 从没下载/玩〔cache/history/pending 空〕+ 带 seed flag + Caches 被清）会被 seed 覆盖（totalCapital 0→100_000，用户重设即可） | codex-13b-R3-F2 | **accept residual**：根治需扩 `SettingsDAO` 协议加 `settingsRowExists()`（trust-boundary + 改全 conformance）for 极罕见 DEBUG-only 边角，违 surgical 原则 |
| **13b-R2：§D smoke 用 fake `TrainingSetDataVerifier`**——§D 沿用既有 happy-path 约定（`FakeTrainingSetDataVerifier` 放行）。真 `DefaultTrainingSetDataVerifier` 要求**每周期 startDatetime 前 ≥30 warm-up**（含 monthly ≥30 = 数千根 m3 + 多年数据），对测试 fixture 不现实；verifier 规则由 `DefaultTrainingSetDataVerifierTests` 专测 | codex-13b-R2-F4 + R3-F3（§D verifier）| **accept residual**：§D 覆盖 runner 真实路径（download/crc/unzip/db-open/store/confirm/journal/下游 open），仅 verifier 一步用 fake（有独立专测）。满足真 verifier 的 ≥30-全周期-含-monthly fixture 不现实 |

## codex review 收敛说明（accept residual + override）

13b 的 §C/§D **实质 bug 已在 codex review R1/R2 全修**：R1-F1 cache-empty 不安全（iOS 清 Caches）→ 全空 guard；R1-F3 SettingsStore stale → seed 移 init 前；R2-F1 fixture 周期不够（make 默认 .m60）→ 全 6 周期 + fresh start/review/replay 集成测试；R2-F2 settings 非零被覆盖 → settings 零值 guard。**R3 三 finding 全为 R2 已 accept residual 的重提（partial / §D verifier）+ 1 精炼（settings-row 零值歧义）**——三者根治分别需「2-state durable marker + 单事务」「扩 SettingsDAO 协议」「≥30-全周期-含-monthly fixture」，均属 DEBUG-only 边角的过度工程 / trust-boundary 协议扩展 / 不现实。依 `feedback_codex_distributed_reliability_drilldown`（reliability 子case 无止境下钻 → accept+override）+ `feedback_big_pr_codex_noncovergence`（>5 轮 escalate；本 PR 3 轮即收口因 R3 纯重提）：**accept residual 13b-R1/R2/R3 + user TTY attest-override + admin merge**。整体 opus 4.8 xhigh review = APPROVE（1 Low partial，同 13b-R1）。1009 tests + Catalyst 绿。
