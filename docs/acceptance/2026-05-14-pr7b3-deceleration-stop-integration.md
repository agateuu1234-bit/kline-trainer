# PR 7b3 — C1b Deceleration Stop 契约集成测试 验收清单

> 给非 coder 的你：每节照「操作」敲命令，把输出和「预期」对一对，再按「通过判定」打勾。
> 所有命令在仓库根目录执行。

## §1. 编译通过

- **操作：** `swift build --package-path ios/Contracts 2>&1 | tail -3`
- **预期：** 末尾出现 `Build complete!`，无 `error:`、无 `warning:`。
- **通过判定：** 看到 `Build complete!` 且全程无 `error:` / `warning:` → 通过；否则不通过。

## §2. 全部测试通过 270/270 in 59 suites（baseline 265/58 + 5 新测试 + 1 新 Suite）

- **操作：** `swift test --package-path ios/Contracts 2>&1 | tail -6`
- **预期：** 末尾出现 `Test run with 270 tests in 59 suites passed`，`0 failures`。
- **通过判定：** 数字正好是 `270 tests in 59 suites` 且 `passed` → 通过；任何 `failed:` / 数字不符 → 不通过。

## §3. 新 Suite `ReducerEffectIntegrationTests` 5/5 PASS

- **操作：** `swift test --package-path ios/Contracts --filter ReducerEffectIntegrationTests 2>&1 | tail -12`
- **预期：** 5 个测试全 `passed`：`panEndedStartsAnimator` / `activateDrawingStopsAnimatorAndEntersDrawing` / `handlerStopsAnimatorBeforeComputingRange` / `noResidualCallbackWhileDrawing` / `noResidualCallbackAfterDrawingExit`。
- **通过判定：** 5 个测试名全部出现且全 `passed`，`0 failures` → 通过；少一个或有 `failed:` → 不通过。

## §4. 零生产代码改动（本 PR 只动测试 + 文档）

- **操作：** `git diff --stat origin/main -- ios/Contracts/Sources/`
- **预期：** **零输出**（命令打印空行后直接结束）。
- **通过判定：** 完全无输出 → 通过；只要列出任何 `ios/Contracts/Sources/...` 文件 → 不通过。

## §5. 新文件落在测试 target、且只新增一个文件

- **操作：** `git diff --stat origin/main -- ios/Contracts/`
- **预期：** 只列出一个文件 `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift`，状态为新增。
- **通过判定：** 恰好一个新增文件、路径在 `Tests/` 下 → 通过；出现第二个文件或路径在 `Sources/` 下 → 不通过。

## §6. spec L1167 三项契约被测试字面守住

- **操作：**
  ```
  grep -c "animator.stop()" ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
  grep -n "animatorStopped" ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
  grep -n "func tick" ios/Contracts/Tests/KlineTrainerContractsTests/ReducerEffectIntegrationTests.swift
  ```
- **预期：** 第 1 条 ≥1（handler 真调 `animator.stop()`）；第 2 条至少出现在 `handle(_:)` 与 `handlerStopsAnimatorBeforeComputingRange` 两处（先 stop 再算 range 的顺序断言）；第 3 条命中 `SpyDecelerationAnimator.tick` 定义（被 `noResidualCallbackWhileDrawing` / `noResidualCallbackAfterDrawingExit` 用于验证 handler-stop 后 driver tick 静默）。
- **通过判定：** 三条 grep 都命中且行数符合上述 → 通过；任一条 0 命中 → 不通过。

## §7. PR7a / PR7b1 / PR7b2 既有 Suite 行为零回归

- **操作：** `swift test --package-path ios/Contracts --filter ReducerTests 2>&1 | tail -4` 再 `swift test --package-path ios/Contracts --filter "reduce " 2>&1 | tail -4`
- **预期：** 既有 reducer 相关 Suite 全 `passed`，无 `failed:`。
- **通过判定：** 全 `passed` → 通过；出现 `failed:` → 不通过。

## §8. PR7b3 之后 C1b 验收状态

- C1b 验收清单（spec L1156-1174）的 **reducer 侧 + effect 合约侧**至此全部落地：revision 单调性（PR7a）、requestDrawingSnapshot effect 覆盖（PR7b1）、staleDrawingSnapshot 三路径（PR7b2）、跨 session guard（PR7b1）、双分支 + 非法转换 assertion（PR7b1/7b2）、**Deceleration stop 契约的可执行 spec + reducer 侧验证（本 PR）**。
- **遗留（非缺陷，是 scope 边界）：** L1167 的 **production handler/animator 集成 gate** 保持 OPEN——本 PR 用测试内参考 handler 验证「reducer 的 effect 合约足以让正确 handler 存在」，但生产 effect handler（E5/C8）与生产 `DecelerationAnimator`（C2）属 Wave 1；尤其「in-flight 延迟回调被 production `stop()` 彻底挡住」这条不在本 PR 覆盖范围。该 gate 在 Wave 1 E5/C8/C2 落地时关闭，不由本 PR 关闭（详见计划「本 PR 不证明什么」+「spy 的回调模型 · 本模型不覆盖什么」）。
- **⚠️ 对 PR 8 的约束：** `wave0-frozen-v1.4` tag **不得**在「L1167 production 集成落地」或「L1167 经 spec 修订移入 Wave 1」之前打。PR 8 的 plan 须把此列为显式 blocking checklist item（详见计划「Wave 0 freeze blocker」）。
- 下一锚 = v6 outline 顺位 15 = PR 8（C1c Render + C3-C6 stubs + §15.1 sign-off + tag `wave0-frozen-v1.4`）。

## §9. 总结

- 本 PR 交付 spec L1167 的**可执行 handler 合约 spec + reducer 侧验证**（非 production 集成 gate 关闭），3 子项：测试替身 + 集成桥（Task 1）、handler 契约 + 5 集成测试（Task 2）、本验收清单（Task 3）。
- 生产代码净增 0 行；测试净增 1 文件 / 1 Suite / 5 测试。
- 全部 8 节验收命令可由非 coder 逐条复跑核对。
