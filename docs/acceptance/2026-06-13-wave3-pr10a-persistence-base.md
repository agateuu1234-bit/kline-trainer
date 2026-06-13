# Wave 3 顺位 10a 持久化基础 验收清单（中文非-coder 可执行）

**PR 范围**：原子 finalize port + finalize 失败保留 session + session-key schema 迁移（RFC §4.7 a/b/c）。25 个文件 / +652/-68 行（含测试与本文档）；不含 10b（autosave / 终态 fence / discard 持久终态 / provenance 恢复）。

**实施依据**：`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.7(a)(b)(c) + `kline_trainer_modules_v1.4.md` L1749-1751 + plan `docs/superpowers/plans/2026-06-13-wave3-pr10a-persistence-base.md`。

---

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR 的 Files changed，查看新增文件列表 | 见新文件 `SessionFinalizationPort.swift`、`SessionFinalizationPortTests.swift`、本验收文档 `docs/acceptance/2026-06-13-wave3-pr10a-persistence-base.md` | □ Pass / □ Fail |
| 2 | 在 `AppDBMigrations.swift` diff 中搜索 `0004_v1.6_session_key` | migration 块含四类语句：`ALTER TABLE pending_training ADD COLUMN session_key`、`ALTER TABLE training_records ADD COLUMN session_key`、`CREATE UNIQUE INDEX`（名 `idx_training_records_session_key`）、`PRAGMA user_version = 2` | □ Pass / □ Fail |
| 3 | 在 `Models/Models.swift` diff 中搜索 `CONTRACT_VERSION` | 值由 `"1.5"` 改为 `"1.6"` | □ Pass / □ Fail |
| 4 | 在 `TrainingView.swift` diff 中搜索 `onSessionEnded(nil)` | 失败 catch 路径中不再直接调用该方法（仅注释提及）；新增 alert 含「重试」「放弃」两个按钮 | □ Pass / □ Fail |
| 5 | 在 `DefaultAppDB.swift` diff 中查看 `finalizeSession` 方法体 | 单个 `dbQueue.write` 闭包内先执行 `insertRecord`（带 sessionKey）后执行 `clearPending`，两步在同一事务内 | □ Pass / □ Fail |
| 6 | 打开本 PR 的 Checks 页，等所有 CI job 完成 | 以下三个 required check 全部显示绿色 ✔：`Mac Catalyst build-for-testing on macos-15`（catalyst-build.yml）、`iOS app build-for-running on macos-15`（app-build.yml）、`swift test on macos-15`（swift-contracts-smoke.yml） | □ Pass / □ Fail |
| 7 | 在 CI `swift test on macos-15` job 日志末尾搜索 `Test run with` | 显示 `✔ Test run with 876 tests in 124 suites passed` 且 0 failures | □ Pass / □ Fail |
| 8 | 在同一 CI 日志中搜索 `SessionFinalizationPort` | 出现以下测试名且全部显示 ✔ passed：「成功路径：record+ops+drawings 入库且 pending 清（单事务两效果）」、「retry 幂等：同 sessionKey 第二次 finalize → 返同 id，不重插 record/ops」、「crash-after-commit：finalize 成功后重开 DB（模拟 relaunch）→ pending 无、record 恰 1 条」、「原子性：事务内 INSERT 失败（SQLITE_FULL 注入）→ record 0 条 + pending 原样保留」、「retry 幂等 + 残留 pending：幂等命中路径仍清 pending（§4.7c retry 完整语义）」 | □ Pass / □ Fail |
| 9 | 在同一 CI 日志中搜索 `0004` | 出现以下测试名且全部显示 ✔ passed：`test_full_migrator_sets_user_version_2`、`test_0004_fresh_install_has_session_key_columns_and_unique_index`、`test_0004_upgrade_backfills_pending_key_and_leaves_record_keys_null`、`test_0004_unique_index_allows_multiple_null_session_keys` | □ Pass / □ Fail |
| 10 | 在同一 CI 日志中搜索 `TrainingSessionPersistenceTests` | 出现「finalize 失败：port 注入错误 → session 保持活跃（RFC §4.7a：失败不拆 session）」以及「finalize 幂等：同 sessionKey 重试 → 返相同 id（RFC §4.7c 幂等锚）」两个测试名，且均 ✔ passed | □ Pass / □ Fail |

---

## 本地复核命令

以下三条命令可在本机 `ios/Contracts` 目录下执行，用于在本地确认实际结果与预期完全一致：

**1. Swift 测试套件（主验收）**

```bash
cd ios/Contracts && swift test 2>&1 | tail -3
```

期望末行（逐字符一致）：

```
✔ Test run with 876 tests in 124 suites passed after 22.424 seconds.
```

**2. Schema 漂移检查**

```bash
bash scripts/check_app_schema_drift.sh
```

期望输出：

```
OK: AppDBMigrations.swift schema 与 ios/sql/app_schema_v1.sql 一致
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

## 范围外（10b）

以下项目属于 10b，本 PR 不交付：autosave（草稿定期写盘）、终态 fence（completed / discarded 状态守卫）、discard 持久终态写库、provenance 恢复（重启后从 DB 还原局面）。
