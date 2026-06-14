# Wave 3 顺位 10b 持久化集成 验收清单（中文非-coder 可执行）

**PR 范围**：周期 autosave（§4.6）+ 终态 fence（§4.7d）+ discard 持久终态（§4.7e）+ provenance-aware 恢复（§4.7f）+ 跨 feature 故障注入集成测试。不含 10c 项：全 app fixture provisioning / 生产路径 E2E smoke / 边界错误 Toast 层 / cache touch-on-use。

**实施依据**：`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.6 / §4.7(d)(e)(f) + `kline_trainer_modules_v1.4.md` L1747/1752/1753 + plan `docs/superpowers/plans/2026-06-14-wave3-pr10b-persistence-integration.md`。

---

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR 的 Files changed，查看新增文件列表 | 见以下新增文件：`TrainingSessionAutosaveTests.swift`、`TrainingSessionFenceTests.swift`、`TrainingSessionProvenanceTests.swift`、`TrainingSessionCrossFeatureTests.swift`、`PersistenceIntegrationFixtures.swift`、本验收文档 `docs/acceptance/2026-06-14-wave3-pr10b-persistence-integration.md` | □ Pass / □ Fail |
| 2 | 在 `TrainingSessionCoordinator.swift` diff 中搜索 `AUTOSAVE_TICK_INTERVAL` | 文件顶层出现常量声明 `public let AUTOSAVE_TICK_INTERVAL = 1`，同时搜索 `AUTOSAVE_MAX_INTERVAL` 出现 `public let AUTOSAVE_MAX_INTERVAL = 5` | □ Pass / □ Fail |
| 3 | 在 `TrainingSessionCoordinator.swift` diff 中搜索 `requestAutosave` | 出现 `public func requestAutosave(engine: TrainingEngine, immediate: Bool)` 方法体，内含 `guard !terminating` 条件判断 | □ Pass / □ Fail |
| 4 | 在同一文件 diff 中搜索 `fenceAndDrainAutosaves` | 出现 `private func fenceAndDrainAutosaves()` 方法体，内含 `terminating = true` 和 `await autosaveTask?.value` | □ Pass / □ Fail |
| 5 | 在同一文件 diff 中搜索 `discardSession` | 出现 `public func discardSession() async throws` 方法体，调用顺序为 `fenceAndDrainAutosaves` → `pendingRepo.clearPending()` → `endSession()` | □ Pass / □ Fail |
| 6 | 在同一文件 diff 中搜索 `isCorruptTrainingSet` | 出现 `private func isCorruptTrainingSet(_ error: Error) -> Bool` 方法，case 列表含 `.persistence(.dbCorrupted)` / `.trainingSet(.emptyData)` / `.trainingSet(.versionMismatch)` / `.trainingSet(.crcFailed)` / `.trainingSet(.unzipFailed)` | □ Pass / □ Fail |
| 7 | 打开本 PR 的 Checks 页，等所有 CI job 完成 | 以下三个 required check 全部显示绿色 ✔：`Mac Catalyst build-for-testing on macos-15`（catalyst-build.yml）、`iOS app build-for-running on macos-15`（app-build.yml）、`swift test on macos-15`（swift-contracts-smoke.yml） | □ Pass / □ Fail |
| 8 | 在 CI `swift test on macos-15` job 日志末尾搜索 `Test run with` | 显示 `✔ Test run with 962 tests in 135 suites passed` 且 0 failures | □ Pass / □ Fail |
| 9 | 在同一 CI 日志中搜索 `TrainingSession autosave` | 出现 Suite 名称「TrainingSession autosave（周期落盘 + coalescing + 失败可见，RFC §4.6）」，以下测试名全部 ✔ passed：「requestAutosave(immediate): Normal 活跃局 → 落 pending 含当前状态」、「coalescing: 同 runloop 多次 request → 合并为 1 次 savePending（latest-wins，不排队）」、「N-cadence: 非 immediate 按 AUTOSAVE_TICK_INTERVAL 节流（N=3 → 每 3 次脏存 1 次）」、「失败可见: savePending 抛 → lastAutosaveError 置位 + session 不 teardown（§4.6）」、「review/replay 非 Normal: requestAutosave no-op（无 pending 语义）」 | □ Pass / □ Fail |
| 10 | 在同一 CI 日志中搜索 `TrainingSession 终态 fence` | 出现 Suite 名称「TrainingSession 终态 fence（finalize 前排空 autosave，RFC §4.7d）」，以下测试名全部 ✔ passed：「save-before-finalize: 在飞 autosave 被 fence drain，finalize 后 pending 清且 record 1 条」、「save-after-finalize-start: finalize 后 requestAutosave 被拒（terminating），pending 不复活」、「crash-after-commit relaunch: finalize 成功后无 pending → resume 返 nil（不二次 finalize）」、「新 session 重置栅栏: finalize 后开新局 → autosave 恢复工作（terminating 重置）」、「discard durable: fence → 清 pending → endSession；resume 返 nil（无复活）§4.7e」、「discard 后迟到 autosave 被拒（terminating）→ 不重建 pending」、「discard clearPending 失败: 保留 active session（不 teardown）供 retry §4.7e」 | □ Pass / □ Fail |
| 11 | 在同一 CI 日志中搜索 `provenance 恢复` | 出现 Suite 名称「TrainingSession provenance 恢复（source-based 路由，RFC §4.7f）」，以下测试名全部 ✔ passed：「训练组损坏: startNew 先选损坏文件（确定性）→ 删该文件 + 用好文件成功开局」、「全部损坏: 删尽 → throw .trainingSet(.fileNotFound)（caller 走重下路径）」、「app.sqlite 损坏 fail-closed: loadPending 抛 .dbCorrupted → 透传 + 零 cache.delete（安全红线）」、「非损坏错误不删: diskFull 透传，不误删训练组文件」 | □ Pass / □ Fail |
| 12 | 在同一 CI 日志中搜索 `跨 feature 持久化加固` | 出现 Suite 名称「TrainingSession 跨 feature 持久化加固（drawing/trade/replay × autosave/fence，10b）」，以下测试名全部 ✔ passed：「交易成功后 autosave → resume 含该笔交易（buy 推 tick，§4.6 覆盖交易脏写）」、「画线 commit 后 autosave → resume 含该画线（engine.drawings 单一真相，#103×10b）」、「replay 非持久不变量在 autosave 下成立：requestAutosave 不写 records/pending（§4.4e×§4.6）」、「discard 画线局 → resume 无复活（drawing checkpoint 被 durable 清）」 | □ Pass / □ Fail |

---

## 本地复核命令

以下命令可在项目根目录 `ios/Contracts` 下执行，确认实际结果与预期完全一致：

**1. 仅跑跨 feature 集成测试**

```bash
cd ios/Contracts && swift test --filter TrainingSessionCrossFeatureTests 2>&1 | tail -8
```

期望末行：

```
✔ Test run with 4 tests in 1 suite passed after 0.001 seconds.
```

**2. Swift 测试套件全量（主验收）**

```bash
cd ios/Contracts && swift test 2>&1 | tail -3
```

期望末行（逐字符一致）：

```
✔ Test run with 962 tests in 135 suites passed after 22.386 seconds.
```

**3. Mac Catalyst 构建验证**

```bash
cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3
```

期望末行：

```
** TEST BUILD SUCCEEDED **
```

---

## 范围外（10c）

以下项目属于顺位 10c，本 PR 不交付：全 app fixture provisioning（debug seed 经 `AppContainer`）、生产路径 fixture E2E smoke（真实 `DownloadAcceptanceRunner`）、边界错误统一 Toast 层（下载中断/磁盘满网络可见性）、cache touch-on-use（E6a-R3）。这些归 10c 须先于顺位 13 收尾完成。
