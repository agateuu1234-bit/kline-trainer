# 验收清单 — Wave 2 顺位 6：P2 DownloadAcceptanceRunner

**PR 性质**：业务模块（iOS 持久化层）。新增纯编排类 `DownloadAcceptanceRunner`（`run` / `runBatch` / `retryPendingConfirmations`），接线已 Wave 0 落地的 4 内部端口 + P1/P3a/P4-journal/P5。
**改动文件**：3 个 `.swift`（1 生产 + 2 测试）+ 1 plan + 1 本验收文档。无既有文件改动。
**执行方式**：以下每项给出「操作 / 期望 / 判定」。非编码人员逐项照命令执行、对照期望勾选 ☐。所有 `swift` 命令在 `ios/Contracts` 目录下运行。

---

## 一、总闸门：全套件测试

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift build 2>&1 \| tail -2` | 末行 `Build complete!`（编译退出码 0，无报错） | ☐ |
| 2 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | 末行形如 `Test run with 600 tests in 105 suites passed`，且出现 `0 failures`（无任一失败） | ☐ |
| 3 | `grep -n "fatalError\|TODO\|FIXME" ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift; echo "exit=$?"` | 无任何行输出，`exit=1`（生产文件无占位 `fatalError`/`TODO`/`FIXME`） | ☐ |

---

## 二、核心行为逐项（按测试名定向运行）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 4 | `cd ios/Contracts && swift test --filter run_happyPath_returnsConfirmed_walksFullStateMachine 2>&1 \| tail -3` | 该测试 `passed`。它断言 `run()` 走完整 7 步状态序列 `downloaded→crcOK→unzipped→dbVerified→stored→confirmPending→confirmed` 且返回 `.confirmed` | ☐ |
| 5 | （状态机硬约束）在测试 `run_happyPath_returnsConfirmed_walksFullStateMachine` 内目视确认含断言 `journal.listByState(.confirmed).count == 1` 与 `journal.listByState(.stored).isEmpty` | 两条「落库态」断言在位。它们查 production 实际落库状态——`stored` 不能直跳 `confirmed`（状态机会静默拒绝非法转换），故此断言为该约束的判定依据 | ☐ |
| 6 | `cd ios/Contracts && swift test --filter run_confirm409_rejected_deletesLocalFile 2>&1 \| tail -3` 与 `swift test --filter run_confirm404_rejected_deletesLocalFile 2>&1 \| tail -3` | 两测试均 `passed`（confirm 收 409/404 → journal 转 `rejected` + 本地 cache 文件被删除） | ☐ |
| 7 | `cd ios/Contracts && swift test --filter run_confirmNetworkUncertain_rejected_butKeepsFileAndPending 2>&1 \| tail -3` 与 `swift test --filter run_confirmServerError5xx_keepsFileAndPending 2>&1 \| tail -3` | 两测试均 `passed`（confirm 网络不确定/5xx → journal 停 `confirmPending` + 本地文件保留，不删） | ☐ |
| 8 | `cd ios/Contracts && swift test --filter run_cancellationError_mappedToInternalP2 2>&1 \| tail -3` | 该测试 `passed`（`CancellationError` 经 `asAppError` 映射为 `.internalError(module:"P2", detail:"cancelled")`） | ☐ |

---

## 三、启动孤儿确认恢复（retry）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 9 | `cd ios/Contracts && swift test --filter retry_scansBothStoredAndConfirmPending 2>&1 \| tail -3` | 该测试 `passed`（`retryPendingConfirmations` 同时扫 `stored` 与 `confirmPending` 两类行，各推进到 `confirmed`） | ☐ |
| 10 | `cd ios/Contracts && swift test --filter retry_confirm409_rejectsAndDeletesCacheFile 2>&1 \| tail -3` 与 `swift test --filter retry_confirmNetworkUncertain_staysPending_keepsFile 2>&1 \| tail -3` | 两测试均 `passed`（retry 收 409 → rejected + 删 cache 文件；网络不确定 → 停 confirmPending + 保留文件） | ☐ |

---

## 四、批量并发 runBatch（保序）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 11 | `cd ios/Contracts && swift test --filter runBatch_resultsOrderedByInputNotCompletion 2>&1 \| tail -3` | 该测试 `passed`。它让低 id 完成最晚（若按完成序返回会得 `[3,2,1]`），断言结果为输入序 `[1,2,3]`——证明结果按**输入序**而非完成序 | ☐ |
| 12 | `cd ios/Contracts && swift test --filter runBatch_concurrency2_allProcessed_orderPreserved 2>&1 \| tail -3` | 该测试 `passed`（含 `journal.listByState(.confirmed).count == 5`：并发写各 id 独立落库不互相污染） | ☐ |
| 13 | `cd ios/Contracts && swift test --filter runBatch_zeroConcurrency_treatedAsOne 2>&1 \| tail -3` 与 `swift test --filter runBatch_empty_returnsEmpty 2>&1 \| tail -3` | 两测试均 `passed`（concurrency≤0 视同 1 不卡死；空 sets 返回 `[]`） | ☐ |

---

## 五、真实管道集成（真文件 IO，抓 fake 掩盖的 bug）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 14 | `cd ios/Contracts && swift test --filter run_realPipeline_happyPath_storesAndConfirms 2>&1 \| tail -3` | 该测试 `passed`。它用**真实** `DefaultFileSystemCacheManager`/`DefaultZipIntegrityVerifier`/`DefaultZipExtractor`/`DefaultTrainingSetDBFactory` + 真 sqlite/zip fixture 跑 happy-path：真 store 打开落盘文件读 PRAGMA、`file.schemaVersion == 1`。若 runner 误把 zip（而非解压 sqlite）传给 store，此测试转红 | ☐ |

---

## 六、范围与边界（无越界）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 15 | `git diff --name-only "$(git merge-base origin/main HEAD)" HEAD` | 仅 5 个文件：`ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`、`ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift`、`ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`、`docs/superpowers/plans/2026-06-06-wave2-p2-download-acceptance-runner.md`、`docs/acceptance/2026-06-06-wave2-p2-download-acceptance-runner.md`。无既有源文件改动、无 `.sql`/`.yml`/`.py` | ☐ |
| 16 | `grep -rn "TRAINING_SET_SCHEMA_VERSION = " ios/Contracts/Sources` | 仅 1 处定义（在 `DownloadAcceptanceRunner.swift`），无重复定义 | ☐ |

---

## 七、CI 必过闸门

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 17 | 打开 PR 页面，查看 required status check `Mac Catalyst build-for-testing on macos-15` | 状态为 ✅（绿）。注：Catalyst 只验证编译 + 链接，运行时行为由本地 `swift test`（项 1–14）覆盖；P2 是纯逻辑模块，无 C2/C7/C8 类运行时 gate | ☐ |
