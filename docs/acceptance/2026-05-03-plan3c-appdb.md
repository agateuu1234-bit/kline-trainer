# PR 3c P4 AppDB 验收清单（plan3c-appdb 分支 / Wave 0 顺位 6）

## 范围
- P4 AppDB composition root（DefaultAppDB + 单一 DatabaseQueue）
- 4 个 protocol 生产实现（RecordRepository / PendingTrainingRepository / SettingsDAO / AcceptanceJournalDAO）
- typealias AppDB = 4-protocol 复合
- DatabaseMigrator 注册 0001_v1.4_baseline + 0003_v1.4_purge_leased
- AcceptanceJournalDAO contract（protocol + P2JournalState + AcceptanceJournalRow + InMemory fake）

## 动作 / 预期输出 / 是否通过

| 动作 | 命令 | 预期 | 通过 |
|---|---|---|---|
| swift build | `cd ios/Contracts && swift build` | Build complete! 无 error 无 warning | □ |
| 全套 contracts 测试 | `swift test --filter KlineTrainerContractsTests` | 所有 test pass，含 4 个 AcceptanceJournalDAOContract | □ |
| 全套 persistence 测试 | `swift test --filter KlineTrainerPersistenceTests` | 所有 test pass（PR #41 33 个 + 本 PR 55 个 = 88 个） | □ |
| schema drift | `bash scripts/check_app_schema_drift.sh` | "OK: AppDBMigrations.swift schema 与 ios/sql/app_schema_v1.sql 一致" | □ |
| typealias AppDB 编译 | 见 AcceptanceJournalDAOContractTests.test_typealias_AppDB_composes_four_protocols | XCTAssertNil pass | □ |
| migration 注册 | 见 AppDBMigrationsTests | 7 tests pass：tables/version/purge_leased/idempotent/legacy/CANTOPEN/.persistence | □ |
| 端到端 happy path | 见 AppDBHappyPathIntegrationTests | 1 test pass：save settings → pending → record → journal lifecycle | □ |
| AppError 翻译 gate | grep "throw.*GRDB.DatabaseError\|throw.*DecodingError" ios/Contracts/Sources/KlineTrainerPersistence/ | 无命中（GRDB error 全部经 PersistenceErrorMapping） | □ |

## 失败兜底
- 任意命令 fail → 修复后重跑；不 push PR
- schema drift 失败 → 同步两边（修 SQL 文件或 Swift 字串都可，确保完全一致）
- AppError 翻译 gate 失败 → 加 try/catch 边界，禁止裸 throw GRDB / Decoding 错误

## Spec 锚点
- §M0.1 line 131-156（app.sqlite migration owner = P4）
- §M0.1 line 230-289（download_acceptance_journal 表 + v1.4 删 leased + 0003 migration）
- §M0.5 line 684（单一 DatabaseQueue）
- §P4 line 1863-1948（4 protocol + typealias + DefaultAppDB）

## 不在本 PR 范围
- E6 TrainingSessionCoordinator 实际 wire P4（属 PR 5 Fixture/Mock 后续）
- P2 DownloadAcceptanceRunner 实际调用 AcceptanceJournalDAO（属 PR 4a/4b）
- P6 SettingsStore 包装 SettingsDAO（属 PR 4b）
- 跨 device iCloud 同步（Wave 2+）

## Round N 对抗性 review

详见 plan 文件 `docs/superpowers/plans/2026-05-03-plan3c-appdb.md` §Round N 章节：5 轮 codex review，13 findings（11 ACCEPT + 2 REJECT），R5 后 user 选 Option A accept current plan + 走 subagent-driven 实施。
