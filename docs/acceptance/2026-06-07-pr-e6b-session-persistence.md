# 验收清单 — E6b TrainingSessionCoordinator 进度保存/正式结束/会话清理（Wave 2 顺位 5）

**性质**：iOS Contracts 层业务模块（无 UI）。验收以「运行指定命令 → 比对确切输出 → 二元判定」方式，非编码者可独立执行。

**前置环境**：
- 已 clone 仓库并切到本 PR 分支（`worktree-wave2-e6b-session-persistence`）。
- 已装 Xcode + Swift 工具链（`swift --version` 能输出版本号）。
- 终端进入 SwiftPM 根目录：`cd "<仓库>/ios/Contracts"`。

> 判定规则：每项「判定」列为二元（PASS / FAIL）。出现任一 FAIL = 本项不通过。

---

## 一、整体闸门

| # | 操作（在 `ios/Contracts` 下运行） | 预期输出 | 判定 |
|---|---|---|---|
| 1 | `swift test 2>&1 \| tail -1` | 末行包含 `693 tests` 且包含 `passed`，不含 `failed` | 末行同时满足「出现 693 tests」「出现 passed」「不出现 failed」=PASS；否则 FAIL |
| 2 | `swift build --build-tests 2>&1 \| grep -ci warning` | 输出 `0` | 输出恰为 `0`=PASS；非 0=FAIL |
| 3 | `swift test --filter "TrainingSessionPersistence" 2>&1 \| tail -1` | 末行包含 `19 tests` 且 `passed` | 同时满足「出现 19 tests」「出现 passed」=PASS；否则 FAIL |
| 4 | iOS-17 模拟器类型检查：`swiftc -typecheck -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios17.0-simulator $(find Sources/KlineTrainerContracts -name "*.swift")` ；随后运行 `echo $?` | `echo $?` 输出 `0` | 输出恰为 `0`=PASS；非 0=FAIL |
| 5 | 确认 3 个收尾方法不再是占位：`grep -c 'fatalError' Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` | 输出 `0`（`fatalError` 仅余文件头注释，命令统计正文行——若仅命中第 3 行注释也算 0 正文，见下注） | 输出 `0` 或仅命中文件头第 3 行注释（无任何方法体 `fatalError`）=PASS；否则 FAIL |

> 第 5 项补充：用 `grep -n 'fatalError' …` 人工核对——命中行若只有第 3 行（`// Wave 0 范围：… fatalError 体 …` 注释），即正文方法体无 `fatalError`，PASS。

---

## 二、业务行为验收（逐方法）

> 运行方式：每项执行 `swift test --filter "<测试名>"`，读末行测试结果。判定通用规则：出现 `passed` 且不含 `failed` = PASS；否则 FAIL。

### 2.1 会话清理 `endSession`

| # | 操作 | 预期（含语义） | 判定 |
|---|---|---|---|
| 6 | `swift test --filter "endSession_closesReaderClearsActive"` | `passed`。语义：结束会话后，活跃引擎与活跃训练组引用均被清空 | 通用规则 |
| 7 | `swift test --filter "endSession_neverStarted_noop"` | `passed`。语义：从未开始会话即调用 endSession，安全无崩溃 | 通用规则 |
| 8 | `swift test --filter "endSession_closesInjectedReader"` | `passed`。语义：endSession 真正调用训练组文件的 close（释放文件句柄，无资源泄漏） | 通用规则 |

### 2.2 进度保存 `saveProgress`

| # | 操作 | 预期（含语义） | 判定 |
|---|---|---|---|
| 9 | `swift test --filter "saveProgress_normal_persistsAllFields"` | `passed`。语义：正常训练局保存进度，写入的「继续训练」存档 12 个字段全部正确（文件名、当前 K 线位置、上下周期、现金、起始资金、起始时间、交易流水、绘线、费率、回撤累计、空仓数据）| 通用规则 |
| 10 | `swift test --filter "saveProgress_review_noop"` | `passed`。语义：复盘（只读）模式调用保存进度 = 空操作，不写存档 | 通用规则 |
| 11 | `swift test --filter "saveProgress_replay_noop"` | `passed`。语义：再来一次（不入账）模式调用保存进度 = 空操作，不写存档 | 通用规则 |
| 12 | `swift test --filter "saveProgress_noActiveContext_throws"` | `passed`。语义：无活跃会话时保存进度 = 抛内部错误（拒绝在无会话上下文下写存档）| 通用规则 |
| 13 | `swift test --filter "saveProgress_thenResume_roundTrips"` | `passed`。语义：保存进度→结束会话→继续训练，恢复出的引擎状态（K 线位置/现金/起始资金/持仓/周期组合）与保存前一致（存档往返不丢失）| 通用规则 |

### 2.3 正式结束 `finalize`

| # | 操作 | 预期（含语义） | 判定 |
|---|---|---|---|
| 14 | `swift test --filter "finalize_normal_insertsRecordCorrectly"` | `passed`。语义：正常训练结束生成历史记录，15 字段正确——其中「总资金」存【本局起始资金】（方案 A，与累计统计自洽，非结束总资金）、盈亏=结束总资金−起始、最大回撤为负比率、买卖次数、起始年月（按北京时 UTC+8）、结束时间、清掉「继续训练」存档 | 通用规则 |
| 15 | `swift test --filter "finalize_review_returnsNil"` | `passed`。语义：复盘模式正式结束 = 返回空（不生成历史记录、不动存档）| 通用规则 |
| 16 | `swift test --filter "finalize_replay_returnsNil"` | `passed`。语义：再来一次模式正式结束 = 返回空（不入账）| 通用规则 |
| 17 | `swift test --filter "finalize_noActiveContext_throws"` | `passed`。语义：无活跃会话时正式结束 = 抛内部错误 | 通用规则 |
| 18 | `swift test --filter "finalize_forceCloseSell_countedInSellCount"` | `passed`。语义：局终持仓被自动强平产生的卖出，计入历史记录的「卖出次数」 | 通用规则 |

### 2.4 纯换算函数（最大回撤比率 + 起始年月时区）

| # | 操作 | 预期（含语义） | 判定 |
|---|---|---|---|
| 19 | `swift test --filter "drawdownRatio"` | 3 个 `passed`。语义：回撤额(元)→负比率换算正确（峰值≤0 时返 0，否则 −回撤额/峰值）| 通用规则 |
| 20 | `swift test --filter "startYearMonth"` | 3 个 `passed`。语义：训练组起始时间→年/月按北京时 UTC+8（跨月、跨年边界 case 验证用的是北京时而非 UTC）| 通用规则 |

---

## 三、M0.4 错误处理证据表（public throwing 方法 → 失败注入测试）

| public throwing 方法 | 失败模式 | 对应测试（`@Test`）/ 处置 |
|---|---|---|
| `saveProgress(engine:)` | 无活跃会话上下文 | `saveProgress_noActiveContext_throws`（抛 `.internalError(module:"E6b")`）|
| `finalize(engine:)` | 无活跃会话上下文 | `finalize_noActiveContext_throws`（抛 `.internalError(module:"E6b")`）|
| `saveProgress(engine:)` | `positionData` 编码失败 | 防御性/不可达：PositionManager 不变量保证字段 finite，`JSONEncoder().encode` 无法真失败 → 无对应 `@Test`（catch 分支为纵深防御，翻译为 `.internalError`）|

M0.4 静态自检（在 `Sources/KlineTrainerContracts/TrainingEngine` 下）：
- `grep -nE "^[[:space:]]*throw " TrainingSessionCoordinator.swift | grep -v "AppError"` → 无输出（每条 `throw` 均含 `AppError`）。
- `grep -nE "JSONEncoder|JSONDecoder|\.encode\(|\.decode\(" TrainingSessionCoordinator.swift` → 仅命中 `encodePosition`（encode）与 `decodePosition`（decode）两个 private helper 内各一处；public 方法体内无裸 encode/decode。

---

## 四、本 PR 不交付 / 已登记 residual

- **E6b-R1**（方案 A 后续）：U3 结算窗 + 历史列表「总资金」当前直显 `total_capital`（=本局起始资金），须在 U1/U2 接线（顺位 8/9）改显 `total_capital + profit`（结束总资金）；并修 stale 的 DB 注释 + plan 文案。
- **E6b-R2**：最大回撤比率以「最终 peakCapital」为基准换算，与原 plan 逐时刻比率在「峰值后置」时数值不同；如需精确逐时刻比率须扩 `DrawdownAccumulator`（spec 变更）。
- **E6b-R3**（承接 E6a-R3）：cache touch-on-use LRU 仍延后（顺位 11 评估）。
- **E6b-R4**：`saveProgress` 对复盘/再来一次为静默 no-op（非抛错）。
