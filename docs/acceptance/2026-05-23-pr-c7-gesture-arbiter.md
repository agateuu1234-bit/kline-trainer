# PR C7 ChartGestureArbiter —— 验收清单

> 语言：中文。判定二元可决。证据：命令输出贴 PR comment。

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| 1 | 运行 `swift test --package-path ios/Contracts --filter ClassifyTwoFingerGestureTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 2 | 运行 `swift test --package-path ios/Contracts --filter ClassifySingleFingerPanTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 3 | 运行 `swift test --package-path ios/Contracts --filter PanPolicyInDrawingModeTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 4 | 运行 `swift test --package-path ios/Contracts --filter PanIncrementTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 5 | 运行 `swift test --package-path ios/Contracts --filter SinglePanStepTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 6 | 运行 `swift test --package-path ios/Contracts --filter TwoFingerStepTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 7 | 运行 `swift test --package-path ios/Contracts --filter GestureValueTypeTests` | 终端输出含 `0 failures` | failures = 0 → 通过；否则不通过 |
| 8 | 运行 `swift test --package-path ios/Contracts`（全量） | 终端输出含 `377 tests in 72 suites passed`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 9 | 运行 `swift build --package-path ios/Contracts` | 输出 `Build complete!` | 出现该串且无 error → 通过；否则不通过 |
| 10 | 在 `ios/Contracts` 运行 `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/c7-catalyst` | 输出含 `** TEST BUILD SUCCEEDED **`，无 `error:` | 出现该串且无 error → 通过（编译 UIKit arbiter Catalyst 路径）；否则不通过 |
| 11 | 运行 `grep -n "AppError" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 无任何匹配行 | 0 匹配（C7 不跨 AppError 信任边界）→ 通过；有匹配 → 不通过 |
| 12 | 运行 `grep -n "#if canImport(UIKit)" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 1 行匹配 | ≥1 匹配（arbiter 整体 UIKit 门控存在）→ 通过；0 匹配 → 不通过 |
| 13 | 运行 `grep -n "singlePanStep" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 1 行匹配（在 handleSinglePan 内） | ≥1 匹配（单指生命周期纯函数接线存在，防 R1 finding-1 + R2 回归）→ 通过；0 匹配 → 不通过 |
| 14 | 运行 `grep -n "velocity(in:" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 1 行匹配（在 handleSinglePan 内） | ≥1 匹配（释放速度路径存在，防 R1 finding-2 回归）→ 通过；0 匹配 → 不通过 |
| 15 | 运行 `grep -n "twoFingerStep" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 2 行匹配（handleTwoFingerPan + handlePinch 各 1 处） | ≥2 匹配（两指生命周期状态机在 pan 与 pinch 两处均接线，防 R1 finding-3 + R3 回归）→ 通过；少于 2 匹配 → 不通过 |
| 16 | 运行 `grep -n "supersedeSinglePanForMultitouch" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 2 行匹配（handleTwoFingerPan + handlePinch 各 1 处调用） | ≥2 匹配（确定性两指接管在 pan 与 pinch 两处均接线，防 R10 finding-1 回归）→ 通过；少于 2 匹配 → 不通过 |
| 17 | 运行 `grep -n "singlePanSupersede" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 1 行匹配（在 supersedeSinglePanForMultitouch 方法内） | ≥1 匹配（同步关闭不依赖回调投递，防 R11 finding 回归）→ 通过；0 匹配 → 不通过 |
| 18 | 运行 `grep -n "attachedView === view" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 1 行匹配（在 attach 方法内） | ≥1 匹配（attach 幂等守卫存在，防 R6 finding-2 回归）→ 通过；0 匹配 → 不通过 |
| 19 | 运行 `grep -n "hasSinglePan && hasTwoFingerPan" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift` | 至少 1 行匹配（在委托方法内） | ≥1 匹配（单指+两指Pan 放行同时识别，防 R15 finding-1 回归）→ 通过；0 匹配 → 不通过 |
| 20 | 运行 `grep -n "verticalRejected\|lastPinchScale" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/GestureClassifiers.swift` | 至少 1 行含 `verticalRejected`（latch 态定义）且至少 1 行含 `lastPinchScale` | 两词均有匹配（垂直 latch 态 + pinch scale 记忆存在，防 R9 finding-1 + R10 finding-2 回归）→ 通过；任一词 0 匹配 → 不通过 |
| 21 | 全量测试中：`PanIncrementTests::multiFrameNetMovement` 通过 | 净位移 == 增量和（增量 [10,10,10]，和 == 30） | 该测试 passed → 通过；否则不通过（单测证 R1 finding-1：累积不得当增量） |
| 22 | 全量测试中：`SinglePanStepTests::verticalNeverEmits` 通过 | 垂直手势全程 emissions 为空 | 该测试 passed → 通过；否则不通过（单测证 R2 finding：垂直/ambiguous 不得触碰 reducer pan 状态） |
| 23 | 全量测试中：`TwoFingerStepTests::pinchLockSuppressesSwipe` 通过 | pinch 锁定后末帧回落不触发切周期 | 该测试 passed → 通过；否则不通过（单测证 R3 finding：两指意图须锁定不可跨回调重分类） |
| 24 | 全量测试中：`SinglePanStepTests::drawingTakeoverCancelsActive` 通过 | drawing 截获活跃 pan → 残量 `.changed` + `.cancelled` + reset | 该测试 passed → 通过；否则不通过（单测证 R4 + R5 finding-1：截获须关闭生命周期） |
| 25 | 全量测试中：`TwoFingerStepTests::lateRecognizerNoLeak` 通过 | 双识别器顺序无关、滞后回调不泄漏切周期 | 该测试 passed → 通过；否则不通过（单测证 R5 finding-2：两识别器生命周期顺序无关） |
| 26 | 全量测试中：`SinglePanStepTests::supersedeActiveNoResidual` 通过 | 多指接管同步关闭恰一个 `.cancelled` | 该测试 passed → 通过；否则不通过（单测证 R11 finding：同步关闭不依赖回调投递） |
| 27 | 全量测试中：`SinglePanStepTests::zeroDeltaChangedSuppressed` 通过 | horizontalActive 下 x 不变时不发 `.changed` | 该测试 passed → 通过；否则不通过（单测证 R13 finding-1：零 delta 不空 bump revision） |
| 28 | （真机/Catalyst 验收残留）对同一 UIView 连续调用 `arbiter.attach(to:)` 两次，检查 `view.gestureRecognizers?.count` | 与首次 attach 后 count 相同（不新增识别器） | count 不增 → 通过；count 增加 → 不通过（R6 finding-2 幂等契约） |
| 29 | （真机/Catalyst 验收残留）正常单指慢速水平拖动 → 观察 `onPan` 回调时机 | 拖动过程中即收到 `.began`/`.changed`，不需等松手 | 拖动中即有回调 → 通过；需松手才有回调 → 不通过（R9 finding-2：单指响应性不受两指优先级策略影响） |
| 30 | （真机/Catalyst 验收残留）交错两指起手（先 1 指水平微动再落第 2 指）→ 上下滑动松手 | 单指 pan 被取消，`onTwoFingerSwipe` 触发一次 | 单指取消 + 切周期触发各一次 → 通过；单指持续或切周期不触发 → 不通过（R10 finding-1 确定性接管） |
| 31 | （真机/Catalyst 验收残留）在 drawingMode=false 时单指点击 | `onTap` 不触发 | onTap 无回调 → 通过；有回调 → 不通过（spec：点击仅 drawing 模式确定锚点） |

---

## 流程合规与偏差（如实记录，2026-05-23）

本 PR 按用户指定的 Superpowers 6 段流程执行（writing-plans → plan-stage review → subagent-driven-development → verification-before-completion → requesting-code-review → branch-diff review），每段均调用真实 skill，未以 raw Agent 替代。以下偏差**如实记录，不粉饰**：

**1. plan-stage codex 审阅 R1–R15 全 needs-attention，从未 approve。** 15 轮每轮均为真 correctness bug（累积 delta 当增量 / 缺释放速度 / pinch 仲裁虚设 / 垂直 latch 缺失 / 两指生命周期顺序依赖 / drawing 截获残留 / attach 非幂等 / FP 边界误判 / 零 delta 空 bump / `.began`→`.ended` 漏 flick / 委托挡死两指 began / 快速 pinch 漏 pinch 等），全部修复；无复述、无自相矛盾。**R16 codex 周级配额耗尽（5 月 27 日才重置）→ 用户授权切换 opus 4.7 xhigh fallback → APPROVE**（逐条执行 40+ 断言 + 全链验证 + reducer 契约对齐，0 真 finding）。**codex 本身从未 approve；plan-stage 闸门靠 opus xhigh fallback 收口。** push 仪式走 attest-override 记录（不包装为"codex 收敛"）。

**2. arbiter 无 macOS 单测，是平台固有约束。** `ChartGestureArbiter` 整类 `#if canImport(UIKit)` 包裹：macOS `swift test` / `swift build` 编译为空；Catalyst `xcodebuild build-for-testing` 真实编译（required CI 闸门）；运行时手势触发 + `attach` 幂等行为 = 真机/Catalyst 验收残留（行 28–31）。所有非平凡决策逻辑沉淀在跨平台纯函数（`singlePanStep` / `twoFingerStep` / 3 分类函数），macOS `swift test` 全量覆盖。

**3. spec 唯一 verify-and-correct（R12 finding）：pinch 阈值 `abs(scale-1.0) > 0.02`。** IEEE 754 Double 下 `1.02 - 1.0` 舍入略大于 `0.02`，导致 scale==1.02 边界被误判为 pinch（codex `swift -e` 实证）。改为对称显式边界 `scale > 1.02 || scale < 0.98`，保"偏离 >2%" 的 spec 意图、消 FP 边界 wart。行 27 单测 `scaleAtBoundaryNotPinch` + `scaleAtLowerBoundaryNotPinch` 固定边界归属（C1a xToIndex verify-and-correct 同类先例）。

**4. Task 1–2 实施方式：subagent-driven-development 双阶段（Task 1 纯函数 + Task 2 UIKit 层）+ 各阶段 implementation-review。** Task 3（本文件）为验证闸门与验收清单，由 subagent 执行并提交。

**5. 合并方式：** 因偏差 1（codex 未 approve），走 attest-override（user TTY）+ Catalyst CI 必检真实通过（不绕过）+ admin squash。
