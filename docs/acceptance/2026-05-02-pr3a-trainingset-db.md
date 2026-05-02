# PR 3a 验收清单（P3a Factory + P3b Reader 真实现）

> 用户在 macOS Terminal cd 到 `/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts` 后逐条执行。

## 动作 / 预期输出 / 是否通过

| # | 动作 | 预期输出 | 通过判定 |
|---|---|---|---|
| 1 | 执行 `swift build` | 终端最末行出现 `Build complete!`；无 error / warning | 末行字串包含 `Build complete!` 即通过 |
| 2 | 执行 `swift test --filter TrainingSetSQLiteFixtureTests` | 末行 `Test Suite 'Selected tests' passed`；3 tests 全 pass | 末行无 `failed` 字串 |
| 3 | 执行 `swift test --filter DefaultTrainingSetDBFactoryTests` | 6 tests 全 pass | 末行无 `failed` 字串 |
| 4 | 执行 `swift test --filter DefaultTrainingSetReaderTests` | 5 tests 全 pass | 末行无 `failed` 字串 |
| 5 | 执行 `swift test --filter HappyPathIntegrationTests` | 1 test pass | 末行无 `failed` 字串 |
| 6 | 执行 `swift test` 跑全仓 | 全部 tests pass（含 KlineTrainerContractsTests 历史项 + 15 个新 Persistence tests） | 末行 `Test Suite 'All tests' passed` |
| 7 | 执行 `grep -rn "import GRDB" Sources/KlineTrainerContracts/` | **无任何输出** | 输出为空（契约层无 GRDB import；注释里出现 "GRDB" 字串属正常说明性引用，不算污染） |
| 8 | 执行 `find Sources/KlineTrainerPersistence -name '*.swift' -exec grep -l 'import GRDB' {} \; \| wc -l` | 数字 ≥ 3 | 输出数字 ≥ 3（Factory + Reader + ErrorMapping 三文件含 GRDB import） |
| 9 | 执行 `grep -nE "^[[:space:]]*throw[[:space:]]" Sources/KlineTrainerPersistence/DefaultTrainingSetDBFactory.swift` | 出现 4 行：1 处 `throw DatabaseError(...)`（PRAGMA 异常通道）+ 2 处 `throw AppError.trainingSet(...)`（versionMismatch + emptyData）+ 1 处 `throw PersistenceErrorMapping.translate(...)`（外层 catch 重抛，translate 返回 AppError），**无** `throw nsErr` / `throw error` 等裸 raw 抛 | grep 输出 4 行，每行 throw 对象前缀只能是 `AppError.` / `DatabaseError(` / `PersistenceErrorMapping.translate(` 三者之一 |

## 失败兜底

- 若第 1 步 `swift build` 因 GRDB 拉包失败：检查网络；GRDB 7.x 包大小 ~3MB 需要短暂等待
- 若第 1 步 `swift build` 报 `'readonly' has been renamed to 'readOnly'`：按编译器提示替换 `config.readonly` → `config.readOnly`
- 若第 1 步报 Sendable warning 数量 > 0：把 `import GRDB` 改为 `@preconcurrency import GRDB`
- 若第 7 步 `grep -rn "import GRDB"` 返回非空：违反 Design Decision §1，立即停止合并
