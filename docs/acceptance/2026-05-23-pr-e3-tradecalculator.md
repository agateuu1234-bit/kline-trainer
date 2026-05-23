# PR E3 TradeCalculator —— 验收清单

> 语言：中文。判定二元可决。证据：命令输出贴 PR comment。
> 模块 E3 `TradeCalculator` 是纯函数交易计算器（买入/卖出报价 + 局终清仓），返回 `Result<_, TradeReason>`，不抛 AppError（M0.4 豁免）。
> 全部测试在 macOS `swift test` 跑（无 UIKit 门控，无平台残留项）。

## 一、自动闸门（命令可机器核验）

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| 1 | 运行 `swift test --package-path ios/Contracts --filter TradeCalculatorBuyTests` | 终端输出含 `0 failures`（买入 8 测试） | failures = 0 → 通过；否则不通过 |
| 2 | 运行 `swift test --package-path ios/Contracts --filter TradeCalculatorSellTests` | 终端输出含 `0 failures`（卖出 8 测试） | failures = 0 → 通过；否则不通过 |
| 3 | 运行 `swift test --package-path ios/Contracts --filter TradeCalculatorForceCloseTests` | 终端输出含 `0 failures`（局终清仓 6 测试） | failures = 0 → 通过；否则不通过 |
| 4 | 运行 `swift test --package-path ios/Contracts`（全量） | 终端输出含 `399 tests in 75 suites passed`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 5 | 运行 `swift build --package-path ios/Contracts` | 输出 `Build complete!`，无 `error:` | 出现该串且无 error → 通过；否则不通过 |
| 6 | 在 `ios/Contracts` 运行 `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/e3-catalyst` | 输出含 `** TEST BUILD SUCCEEDED **`，无 `error:` | 出现该串且无 error → 通过（Catalyst required CI 闸门）；否则不通过 |
| 7 | 运行 `grep -c "Result<.*TradeReason>" ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift` | 输出 ≥ 2（quoteBuy + quoteSell 返回类型） | ≥2 → 通过（E3 以 Result 暴露错误，不 throws）；否则不通过 |
| 8 | 运行 `grep -n "throw " ios/Contracts/Sources/KlineTrainerContracts/TradeCalculator.swift` | 无任何匹配行（`throw` 仅出现在文件头注释，非真抛错代码） | 0 匹配 → 通过（M0.4 豁免：无 throwing 表面）；有真 `throw` 语句 → 不通过 |
| 9 | 运行 `git diff --stat main..feat/e3-tradecalculator` | 仅 `TradeCalculator.swift` 与 `TradeCalculatorTests.swift` 两个文件 | 恰好 2 文件且未含 Models/AppError/Package → 通过（未碰冻结类型）；否则不通过 |

## 二、业务规则验收（每条映射一个全量测试，确认 passed）

| # | 业务规则（spec plan v1.5 §4.2 / modules §E3） | 对应测试 | 判定 |
|---|---|---|---|
| 10 | 买入：目标金额=总资金×仓位比例，按价格取整、再向下取整到 100 股整数倍；佣金=金额×费率；总成本=金额+佣金 | `TradeCalculatorBuyTests::happy` passed | 该测试 passed → 通过；否则不通过 |
| 11 | 买入：原始股数非整百时向下取整到 100 倍（如 606→600） | `TradeCalculatorBuyTests::lotRounding` passed | 该测试 passed → 通过；否则不通过 |
| 12 | 买入：取整后股数为 0 → 资金不足（`.insufficientCash`），交易取消 | `TradeCalculatorBuyTests::roundsToZero` passed | 该测试 passed → 通过；否则不通过 |
| 13 | 买入：总成本超过可用现金 → 资金不足（`.insufficientCash`） | `TradeCalculatorBuyTests::costExceedsCash` passed | 该测试 passed → 通过；否则不通过 |
| 14 | 免5开启且佣金 < 5 元时按 5 元收（买入侧） | `TradeCalculatorBuyTests::minCommission` passed | 该测试 passed → 通过；否则不通过 |
| 15 | 价格 ≤ 0 或总资金/现金为负 → 非法输入（`.invalidShareCount`） | `TradeCalculatorBuyTests::invalidPrice` + `invalidNegative` passed | 两测试均 passed → 通过；否则不通过 |
| 16 | 卖出：仓位相对当前持仓换算、向下取整到 100 倍；佣金 + 印花税(金额×0.0005) + 实际到手=金额−佣金−印花税 | `TradeCalculatorSellTests::happy` passed | 该测试 passed → 通过；否则不通过 |
| 17 | 卖出 5/5 清仓：全部持仓不取整，允许奇数股 / 不足 100 股全卖 | `TradeCalculatorSellTests::clearOddLot` + `clearSubLot` passed | 两测试均 passed → 通过；否则不通过 |
| 18 | 卖出：非清仓且取整后股数为 0 → 持仓不足（`.insufficientHolding`） | `TradeCalculatorSellTests::roundsToZero` passed | 该测试 passed → 通过；否则不通过 |
| 19 | 卖出：空仓（持仓=0）点卖出 → 不可操作（`.disabled`），即使点 5/5 清仓亦然 | `TradeCalculatorSellTests::emptyHolding` passed | 该测试 passed → 通过；否则不通过 |
| 20 | 局终强制清仓：全量卖出按卖出费用规则计佣金+印花税 | `TradeCalculatorForceCloseTests::happy` + `oddLot` passed | 两测试均 passed → 通过；否则不通过 |
| 21 | 局终清仓：持仓=0 或持仓<0 或价格≤0 → 全零报价（无交易、无费用、不误收 5 元最低佣金） | `TradeCalculatorForceCloseTests::zeroHolding` + `negativeHolding` + `invalidPrice` passed | 三测试均 passed → 通过；否则不通过 |
| 22 | 浮点不掉股：价格非二进制精确（如 0.07）时，`1001/0.07` 真值 14300，朴素 floor 会掉到 14200；模块用 verify-and-correct 取回 14300 | `TradeCalculatorBuyTests::fpRobustFloor` passed | 该测试 passed → 通过；否则不通过（朴素 floor 下此测试会 FAIL，已实证） |

---

## 三、流程合规与偏差（如实记录，2026-05-23）

本 PR 按用户指定的 Superpowers 6 段流程执行，每段调用真实 skill，未以 raw Agent 替代：
**writing-plans → plan-stage 对抗性 review → subagent-driven-development → verification-before-completion → requesting-code-review → branch-diff 对抗性 review**。

**1. 评审工具：用户明示用 Claude opus 4.7 xhigh effort 做对抗性评审（非 codex）。** 这是 session 开头契约，两道闸门（plan-stage + branch-diff）均由 opus 4.7 xhigh fallback 执行。

**2. plan-stage 对抗性 review：1 轮收敛。** opus 4.7 xhigh 给 VERDICT APPROVE（0 Critical / 0 High），并抓 3 Medium + 2 Low——全部为真 finding 并已修：
- FP demonstrator 原输入（`5000*0.6`、`500*0.6`）在 IEEE-754 下恰为精确整数，朴素 floor 与 robustFloor 结果相同→证明不了机制；改用经实证的真 undershoot 输入 `1001/0.07`（朴素→14200 FAIL，robustFloor→14300 PASS）。
- 删除原 FP 注释里的错误算术叙述。
- baseline test 计数（"377"）软化为"全绿 0 failure"闸门（parameterized run-count 不可直接相加）。
- sell 路径 robustFloor 标注为防御性对称（整数 holding×5 档比例不会 FP 下溢），不再宣称"修了 bug"。
- robustFloor 注释收紧适用前提（price 为 0.01 整数倍、capital/holding 近整数）。

**3. subagent-driven-development：4 个 implementer 任务，每个走 spec 合规 + code-quality 双阶段 review，全部通过。** Task 1 quoteBuy + 骨架（含 mutation 实验确认 FP demo 真覆盖 robustFloor）/ Task 2 quoteSell / Task 3 forceCloseOnEnd / Task 4 测试覆盖补全。Task 2/3 review 抓到的 Minor（averageCost 校验注释、tier5 下 insufficientHolding 不可达不变式注释、clearSubLot 金额断言、forceClose 守卫路径测试、stampDuty 断言）均折入后续同文件任务修复。

**4. verification-before-completion：新鲜证据。** `swift test` 全量 399/75 suites 0 failures；`swift build` Build complete!；Catalyst `build-for-testing` TEST BUILD SUCCEEDED；M0.4 设计 grep（返 Result、无真 throw）；branch diff 仅 2 文件。

**5. branch-diff 对抗性 review：1 轮收敛。** opus 4.7 xhigh 给 VERDICT APPROVE（0 Critical / 0 High）；含 10,030,000 输入 robustFloor 全域扫描（0 false round-up）+ 22/22 测试值独立复算 + FP demo 实证。唯一 Medium = 本验收文档缺失（已于本次创建消解）；2 Low 不可操作（quoteSell isFinite 非对称 by-design、sell 路径 robustFloor 防御性对称）。

**6. M0.4 豁免。** E3 返 `Result<_, TradeReason>` 不 throws AppError（`docs/governance/m04-apperror-translation-gate.md` 末行 E3 = 否）；调用方 E5 用 `.mapError { AppError.trade($0) }` 提升。无需 gate 脚本。

**7. 合并方式：** 待用户确认（remote 写入需 explicit 授权）。两道 opus xhigh 闸门均 APPROVE；Catalyst required CI 真实通过（不绕过）。
