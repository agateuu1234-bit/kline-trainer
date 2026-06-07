# 验收清单 — E6a TrainingSessionCoordinator 会话构造（Wave 2 顺位 4）

**性质**：iOS Contracts 层业务模块（无 UI）。验收以「运行指定命令 → 比对确切输出 → 二元判定」方式，非编码者可独立执行。

**前置环境**：
- 已 clone 仓库并切到本 PR 分支（`worktree-wave2-e6a-session-coordinator`）。
- 已装 Xcode + Swift 工具链（`swift --version` 能输出版本号）。
- 终端进入 SwiftPM 根目录：`cd "<仓库>/ios/Contracts"`。

> 判定规则：每项「判定」列为二元（PASS / FAIL）。出现任一 FAIL = 本项不通过。

---

## 一、整体闸门

| # | 操作（在 `ios/Contracts` 下运行） | 预期输出 | 判定 |
|---|---|---|---|
| 1 | `swift test 2>&1 \| tail -1` | 末行包含 `627 tests` 且包含 `passed`，不含 `failed` | 末行同时满足「出现 627 tests」「出现 passed」「不出现 failed」=PASS；否则 FAIL |
| 2 | `swift build --build-tests 2>&1 \| grep -ci warning` | 输出 `0` | 输出恰为 `0`=PASS；非 0=FAIL |
| 3 | `swift test --filter "TrainingSessionCoordinatorConstruction" 2>&1 \| tail -1` | 末行包含 `17 tests` 且 `passed` | 同时满足「出现 17 tests」「出现 passed」=PASS；否则 FAIL |
| 4 | iOS-17 模拟器类型检查：`swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios17.0-simulator $(find Sources/KlineTrainerContracts -name "*.swift")` ；随后运行 `echo $?` | `echo $?` 输出 `0` | 输出恰为 `0`=PASS；非 0=FAIL |

---

## 二、业务行为验收（逐方法）

> 运行方式：每项执行 `swift test --filter "<测试名>"`，读末行测试结果。

### 2.1 开始新训练 `startNewNormalSession`

| # | 操作 | 预期 | 判定 |
|---|---|---|---|
| 5 | `swift test --filter "startNew_noRecords_usesSettingsCapital"` | 末行 `1 test`...`passed`。语义：无历史记录时，新局起始资金取「设置里的本金」，新引擎处于可交易的 Normal 模式、tick 从 0 开始 | 出现 `passed` 且不含 `failed`=PASS；否则 FAIL |
| 6 | `swift test --filter "startNew_withRecords_usesAccumulatedCapital"` | 末行 `passed`。语义：有历史记录时，新局起始资金取「上一局结束资金（累计）」而非设置本金 | 同上 |
| 7 | `swift test --filter "startNew_loadError_throwsNoActive"` | 末行 `passed`。语义：设置读取失败（loadError）时，开始新训练被拒绝（抛错），且不打开训练组文件、不留下活跃会话状态（费用前置守门 = 失败即停） | 同上 |
| 8 | `swift test --filter "startNew_noCache_throwsFileNotFound"` | 末行 `passed`。语义：本地无可用训练组时，开始新训练抛「文件不存在」 | 同上 |
| 9 | `swift test --filter "startNew_loadCandlesFails_closesReader"` | 末行 `passed`。语义：打开训练组后读取数据失败时，已打开的训练组被关闭、不留活跃会话状态（无资源泄漏） | 同上 |

### 2.2 继续中断训练 `resumePending`

| # | 操作 | 预期 | 判定 |
|---|---|---|---|
| 10 | `swift test --filter "resume_noPending_returnsNil"` | 末行 `passed`。语义：无中断进度时返回「无」（不抛错、不留活跃状态） | 出现 `passed` 且不含 `failed`=PASS；否则 FAIL |
| 11 | `swift test --filter "resume_happy_rebuildsState"` | 末行 `passed`。语义：有中断进度时，按保存的 tick / 持仓 / 现金 / 回撤 / 周期组合精确恢复引擎 | 同上 |
| 12 | `swift test --filter "resume_corruptPosition_throwsDbCorrupted"` | 末行 `passed`。语义：保存的持仓数据被损坏/篡改时，抛「本地数据损坏」并关闭训练组、不留活跃状态 | 同上 |
| 13 | `swift test --filter "resume_staleTick_throwsEmptyDataClosesReader"` | 末行 `passed`。语义：保存的进度位置超出当前训练组范围（训练组被替换）时，抛错并关闭训练组、不留活跃状态 | 同上 |

### 2.3 复盘 `review` / 再来一次 `replay`

| # | 操作 | 预期 | 判定 |
|---|---|---|---|
| 14 | `swift test --filter "review_happy_restoresEndState"` | 末行 `passed`。语义：复盘进入只读模式（不可买卖），定位到原局结束位置，还原全部交易标记，收益率与记录一致 | 出现 `passed` 且不含 `failed`=PASS；否则 FAIL |
| 15 | `swift test --filter "review_usesRecordFees"` | 末行 `passed`。语义：复盘使用「原局费率」，而非当前设置费率 | 同上 |
| 16 | `swift test --filter "replay_happy_freshFromOriginalFees"` | 末行 `passed`。语义：再来一次从头（tick 0）开始、可交易、不入账、不还原标记，使用原局费率与原局起始资金 | 同上 |
| 17 | `swift test --filter "replay_unknownRecord_propagates"` | 末行 `passed`。语义：记录不存在时抛错、不留活跃状态 | 同上 |
| 18 | `swift test --filter "review_loadCandlesFails_closesReader"`（复盘）与 `swift test --filter "replay_loadCandlesFails_closesReader"`（再来一次）各运行一次 | 两次末行均 `passed`。语义：复盘/再来一次在打开训练组后读取失败时，均关闭训练组、不留活跃状态 | 两次均出现 `passed` 且均不含 `failed`=PASS；任一含 `failed`=FAIL |

---

## 三、M0.4 错误边界静态自检

| # | 操作（在 `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine` 下） | 预期 | 判定 |
|---|---|---|---|
| 19 | `grep -nE "^[[:space:]]*throw " TrainingSessionCoordinator.swift \| grep -v "AppError" && echo FAIL \|\| echo PASS` | 输出 `PASS`（每条 throw 语句都含 `AppError`，私有错误不外泄） | 输出末尾为 `PASS`=PASS；为 `FAIL`=FAIL |
| 20 | `grep -nE "\.decode\(\|JSONDecoder" TrainingSessionCoordinator.swift` | 仅 1 处命中，位于 `decodePosition` 私有方法内（public 方法体内无裸解码） | 命中恰为 1 处且行属 `decodePosition`=PASS；否则 FAIL |

### M0.4 public throwing 方法 → 失败注入测试映射

| public 方法 | 文档化失败模式 | 失败注入测试 | 断言要点 |
|---|---|---|---|
| `startNewNormalSession` | 设置 loadError | `startNew_loadError_throwsNoActive` | 抛 `.persistence(.dbCorrupted)`；reader 未开；active 全 nil |
| `startNewNormalSession` | 无缓存训练组 | `startNew_noCache_throwsFileNotFound` | 抛 `.trainingSet(.fileNotFound)` |
| `startNewNormalSession` | openAndVerify 版本不匹配 | `startNew_openThrows_propagatesNoActive` | 抛 `.trainingSet(.versionMismatch)`；active 全 nil |
| `startNewNormalSession` | 读 candle 失败（open 后） | `startNew_loadCandlesFails_closesReader` | 抛原错；reader 关闭；active 全 nil |
| `resumePending` | 持仓数据损坏 | `resume_corruptPosition_throwsDbCorrupted` | 抛 `.persistence(.dbCorrupted)`；reader 关闭 |
| `resumePending` | 训练组文件缺失 | `resume_fileMissing_throwsFileNotFound` | 抛 `.trainingSet(.fileNotFound)` |
| `resumePending` | 进度位置超范围 | `resume_staleTick_throwsEmptyDataClosesReader` | 抛 `.trainingSet(.emptyData)`；reader 关闭 |
| `review` | 读 candle 失败（open 后） | `review_loadCandlesFails_closesReader` | 抛原错；reader 关闭；active 全 nil |
| `replay` | 记录不存在 | `replay_unknownRecord_propagates` | 抛 `.persistence(.dbCorrupted)`；active 全 nil |
| `replay` | 读 candle 失败（open 后） | `replay_loadCandlesFails_closesReader` | 抛原错；reader 关闭；active 全 nil |

---

## 四、本 PR 未交付（明确边界，非缺陷）

| 项 | 状态 | 归属 |
|---|---|---|
| `saveProgress` / `finalize` / `endSession` | 仍为 `fatalError`（保留 Wave 0 壳） | 顺位 5 E6b |
| E6a-R1：`TRAINING_SET_SCHEMA_VERSION` 共享常量 | E6a 硬编码 `1`（含 M0.1 注释） | 单一 owner = 顺位 6 P2 PR；先 merge 方定义、另一方复用 |
| E6a-R2：启动新 session 前既存 `activeReader` 清理 | 由 `endSession()`/caller 负责（方法 doc 已标前置条件） | 顺位 5 E6b + 顺位 11 组合根 |
| E6a-R3：cache `touch`-on-use（LRU 命中刷新） | 未做 | 顺位 5 E6b / 顺位 11 评估 |

> 运行时验收说明：Catalyst CI 仅做 build-for-testing（编译 + 链接），不执行运行时；本模块为纯逻辑层（无 CADisplayLink / 手势 / 渲染），上述 `swift test` 主机运行即为其完整运行时验收。
