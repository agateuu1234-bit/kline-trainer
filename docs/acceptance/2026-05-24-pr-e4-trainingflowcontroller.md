# PR E4 TrainingFlowController —— 验收清单

> 语言：中文。判定二元可决。证据：命令输出贴 PR comment。
> 模块 E4 `TrainingFlowController` 是纯值类型模块：1 个协议 + 3 个实现（`NormalFlow` / `ReviewFlow` / `ReplayFlow`），把训练三模式的"能力矩阵"（可买卖 / 可步进 / 是否存档 / 是否累加资金 / 是否结算 / 是否触觉）编码为纯查询，返回 `Bool`/`Int`/`ClosedRange<Int>`，从不抛 AppError（M0.4 豁免）。
> 全部测试在 macOS `swift test` 跑（无 UIKit 门控）；另过 Mac Catalyst build-for-testing required CI 闸门。

## 一、自动闸门（命令可机器核验）

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| 1 | `swift test --package-path ios/Contracts --filter NormalFlowTests` | 终端含 `0 failures`（NormalFlow 3 测试） | failures = 0 → 通过；否则不通过 |
| 2 | `swift test --package-path ios/Contracts --filter ReviewFlowTests` | 终端含 `0 failures`（ReviewFlow 3 测试） | failures = 0 → 通过；否则不通过 |
| 3 | `swift test --package-path ios/Contracts --filter ReplayFlowTests` | 终端含 `0 failures`（ReplayFlow 3 测试） | failures = 0 → 通过；否则不通过 |
| 4 | `swift test --package-path ios/Contracts --filter TrainingFlowMatrixTests` | 终端含 `0 failures`（能力矩阵逐列 sweep 4 测试） | failures = 0 → 通过；否则不通过 |
| 5 | `swift test --package-path ios/Contracts --filter TrainingFlowBoundaryTests` | 终端含 `0 failures`（边界 maxTick==0 / finalTick==0 共 3 测试） | failures = 0 → 通过；否则不通过 |
| 6 | `swift test --package-path ios/Contracts`（全量） | 终端含 `415 tests in 80 suites passed`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 7 | `swift build --package-path ios/Contracts` | 输出 `Build complete!`，无 `error:` | 出现该串且无 error → 通过；否则不通过 |
| 8 | 在 `ios/Contracts` 运行 `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/e4-catalyst` | 输出含 `** TEST BUILD SUCCEEDED **`，无 `error:` | 出现该串且无 error → 通过（Catalyst required CI 闸门）；否则不通过 |
| 9 | `grep -c "throw " ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift` | 输出 `0`（无任何真 `throw` 语句） | = 0 → 通过（M0.4 豁免：无 throwing 表面）；否则不通过 |
| 10 | `grep -c "Sendable\|extension TrainingFlowController" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingFlowController.swift` | 输出 `0`（无 Sendable 标注、无 protocol extension 默认实现） | = 0 → 通过（设计决策 D2/D4：每 struct 显式实现、不引入默认）；否则不通过 |
| 11 | `git diff --stat main..HEAD -- ios/Contracts/Sources ios/Contracts/Tests` | 仅 `TrainingFlowController.swift`（+97）与 `TrainingFlowControllerTests.swift` 两个源/测试文件 | 恰好 2 个源/测试文件且冻结契约 `Models.swift`/`AppState.swift`/`AppError.swift`/`Package.swift` 未改 → 通过；否则不通过 |

## 二、业务规则验收（每条映射一个全量测试，确认 passed）

权威行为表 = `kline_trainer_plan_v1.5.md` §5.0 Capability Matrix；协议形状 = `kline_trainer_modules_v1.4.md` §E4。

| # | 业务规则 | 对应测试 | 判定 |
|---|---|---|---|
| 12 | Normal：启动后 `tick == 0`、`canAdvance == true`（spec modules §E4 验收第 1 条） | `NormalFlowTests::acceptance` passed | passed → 通过；否则不通过 |
| 13 | Normal 能力列全开（买卖/步进/存档/累加资金/结算/触觉 全 ✅） | `NormalFlowTests::capabilities` + `TrainingFlowMatrixTests::normalColumn` passed | 两测试均 passed → 通过；否则不通过 |
| 14 | Normal 属性：`mode==.normal`、`feeSnapshot==注入 fees`、`initialTick==0`、`allowedTickRange==0...maxTick` | `NormalFlowTests::properties` passed | passed → 通过；否则不通过 |
| 15 | Review：启动后 `tick == record.finalTick`（**不是 maxTick**，v1.1→v1.2 验收文字修正点）、`canAdvance == false` | `ReviewFlowTests::initialTickIsFinalTickNotMaxTick` passed | passed → 通过；否则不通过 |
| 16 | Review 能力列全关（隐藏买卖/不可步进/不存档/不累加/不结算/无触觉 全 ❌） | `ReviewFlowTests::capabilities` + `TrainingFlowMatrixTests::reviewColumn` passed | 两测试均 passed → 通过；否则不通过 |
| 17 | Review 属性：`mode==.review`、`feeSnapshot==原局 record.feeSnapshot`、`allowedTickRange==finalTick...finalTick`（单点） | `ReviewFlowTests::properties` passed | passed → 通过；否则不通过 |
| 18 | Replay：从头开始（`tick == 0`）、使用原局 `feeSnapshot`、结束不保存（`shouldSaveRecord == false`）（spec modules §E4 验收第 3 条） | `ReplayFlowTests::acceptance` passed | passed → 通过；否则不通过 |
| 19 | Replay 能力列 = 可买卖 ✅ / 可步进 ✅ / 不存档 ❌ / 不累加资金 ❌ / 显示结算 ✅ / 触觉 ✅ | `ReplayFlowTests::capabilities` + `TrainingFlowMatrixTests::replayColumn` passed | 两测试均 passed → 通过；否则不通过 |
| 20 | Replay 属性：`mode==.replay`、`feeSnapshot==feeSnapshotFromOriginal`、`initialTick==0`、`allowedTickRange==0...maxTick` | `ReplayFlowTests::properties` passed | passed → 通过；否则不通过 |
| 21 | 三模式能力列两两不同（防三列被复制粘贴成同一列的回归） | `TrainingFlowMatrixTests::columnsAreDistinct` passed | passed → 通过；否则不通过 |
| 22 | 边界：`maxTick==0`（precondition 最小合法值）时 `allowedTickRange==0...0`；Review `finalTick==0` 时 `0...0` | `TrainingFlowBoundaryTests::normalMinMaxTick` + `replayMinMaxTick` + `reviewZeroFinalTick` passed | 三测试均 passed → 通过；否则不通过 |
| 23 | M0.4 注册：gate 应用范围表含 E4 行标记"否"（豁免） | `grep "E4 TrainingFlowController" docs/governance/m04-apperror-translation-gate.md` 命中且含"否" | 命中且含"否" → 通过；否则不通过 |

---

## 三、流程合规与偏差（如实记录，2026-05-24）

本 PR 按用户指定的 Superpowers 6 段流程执行，每段调用真实 skill，未以 raw Agent 替代既定 skill：
**writing-plans → plan-stage 对抗性 review → subagent-driven-development → verification-before-completion → requesting-code-review → branch-diff 对抗性 review**。

**1. 评审工具：** 用户 session 开头明示用另一个 Claude opus 4.7 xhigh effort 做对抗性评审（非 codex）。这是 session 契约（per memory `feedback_review_tool_switch_must_ask`），两道闸门（plan-stage + branch-diff）均由 opus 4.7 xhigh 执行。

**2. plan-stage 对抗性 review：1 轮收敛。** opus 4.7 xhigh 给 `VERDICT: APPROVE`（0 Critical / 0 High）。评审者实际把 plan 的生产代码与测试代码编译过真包（Swift 6 strict-concurrency complete）确认无误。2 个 Low 均为信息性 / 措辞（m04 备注 wording、"399 基线"为非硬断言注记），评审者明示"no action required"。

**3. 核心设计决策（D1-D5，plan 内详述）：**
- **D1：两份 spec 协议不自洽** —— `kline_trainer_modules_v1.4.md` §E4 的三个 struct 示例只列"差异化 override"，与 `kline_trainer_plan_v1.5.md` §5.0 Capability Matrix 不自洽（矩阵要求 Review 全 ❌、Replay 的 `shouldAccumulateCapital` ❌，但 spec 示例 struct 未 override 这些）。以 **Capability Matrix 为行为权威**，协议形状取 modules v1.4 §E4 的 10 成员超集。
- **D2：每个 struct 显式实现全部 6 个布尔方法，不引入 protocol extension 默认实现。** 这是对 spec 示例 struct 的有意偏离——spec 示例的空 `NormalFlow` 仅在"假设有全 true 默认"下可编译，而那个假设默认正是令 Review/Replay 落错值的根因。显式实现使每个 (mode × 能力) 格在唯一一处可见、是矩阵的 1:1 转写。
- **D3：`0...maxTick` 不做防御性 clamp**（caller precondition `maxTick >= 0`，文档化）。
- **D4：不加 Sendable**（与 E3 `TradeCalculator` 先例一致；本 PR 无 actor 跨界）。
- **D5：M0.4 豁免**（纯查询不 throws），并在 gate 注册表补 E4 = 否 行保持可审。

**4. subagent-driven-development：4 个 implementer 任务（每个 fresh subagent）。** Task 1 协议 + NormalFlow / Task 2 ReviewFlow / Task 3 ReplayFlow / Task 4 矩阵 sweep + M0.4 注册。每任务走 TDD（RED 编译失败 → GREEN）。两阶段 review：
- Task 1 spec compliance ✅ + code quality APPROVED。
- Task 2-4 合并 spec compliance ✅（评审者独立重算矩阵三列）+ code quality APPROVED。
- code-quality 抓 3 Minor：#1 `acceptance` 测试重复（裁定保留——三个 `acceptance` 测试刻意 1:1 映射 spec 三条验收文字，traceability 即目的）；#2 `fees` 命名（裁定保留——`let fees` 是 spec 字面）；#3 缺 `maxTick==0` 边界测试（**采纳**——Task 1 与全模块两位评审独立指出，已补 `TrainingFlowBoundaryTests` 3 测试）。裁决依据 `superpowers:receiving-code-review`（技术判断而非盲从）。

**5. verification-before-completion：新鲜证据（2026-05-24）。**
- 全量 `swift test`：`415 tests in 80 suites passed`，`0 failures`。
- `swift build`：`Build complete!`。
- Catalyst `build-for-testing`：`** TEST BUILD SUCCEEDED **`（required CI 闸门，真实通过，不绕过）。
- 设计 grep：`throw` 0 处、`Sendable`/protocol-ext default 0 处。
- branch diff：源/测试仅 2 文件（`TrainingFlowController.swift` +97 / 测试 +167），冻结契约未改；另 m04 注册 +1 行、plan 文档。

**6. branch-diff 对抗性 review：** opus 4.7 xhigh 收口结论见 PR 描述（如未 APPROVE，按 memory `feedback_codex_convergence_honest_reporting` 如实记录轮数 + escalate + 接受残留 + override，不包装成"收敛"）。

**7. 合并方式：** 待用户确认（remote 写入需 explicit 授权）。
