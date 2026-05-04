# PR4b P5 CacheManager + P6 SettingsStore 验收清单

> 验收人：用户（非 coder 可执行）
> Spec 锚点：`kline_trainer_modules_v1.4.md` §P5 line 1950-1968 + §P6 line 1970-1983
> Plan：`docs/superpowers/plans/2026-05-04-pr4b-cache-settings.md`

## 一、SwiftPM 编译 + 全套测试

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 1 | 在终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings" && swift build --package-path ios/Contracts` | 输出含 `Build complete!`，无 error / warning | 看到 `Build complete!` 且无红字 = ✅ |
| 2 | 在终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings" && swift test --package-path ios/Contracts 2>&1 \| tail -3` | 末行：`Test run with N tests in M suites passed`，N ≥ 217 | 末行 `passed` 且 N ≥ 217 = ✅ |
| 3 | 在终端执行 `cd "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings" && bash scripts/check_p5_apperror_gate.sh` | 输出 `OK: P5 DefaultFileSystemCacheManager 全部 throw 走 AppError 边界 + public 方法零 raw try` | 看到 `OK:` 行 = ✅ |

## 二、文件结构存在

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 4 | 终端执行 `ls "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerPersistence/" \| grep -E "DefaultFileSystemCacheManager"` | 输出 `DefaultFileSystemCacheManager.swift` | 看到该文件 = ✅ |
| 5 | 终端执行 `ls "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerPersistence/Internal/" \| grep CacheErrorMapping` | 输出 `CacheErrorMapping.swift` | 看到该文件 = ✅ |

## 三、签名冻结（trust-boundary 不变）

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 6 | 终端执行 `grep -c "fatalError" "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift"` | 输出 `0`（生产实现替换全部 fatalError 类壳）| 输出 `0` = ✅ |
| 7 | 终端执行 `grep -E "public protocol CacheManager" "/Users/maziming/Coding/Prj_Kline trainer/.worktrees/pr4b-cache-settings/ios/Contracts/Sources/KlineTrainerContracts/Persistence/CacheManager.swift"` | 输出 1 行 `public protocol CacheManager: Sendable {` | 输出该行 = ✅（协议未改）|

## 失败兜底
- 任意命令 fail → 修复后重跑；不 push PR
- AppError gate 失败 → 加 try/catch 边界，禁止裸 throw NSError
- 测试数 < 217 → 检查是否有测试被跳过 / 编译失败导致测试集减少
