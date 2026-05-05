# PR 7b1 — C1b Reducer Drawing FSM 验收清单

> **目标读者：** 不写代码的复审人（按 §动作 步骤跑命令、对照 §预期 / §通过判定 勾选）。
> **前置条件：** 已 checkout PR7b1 worktree branch；macOS 终端打开；`xcrun --find swift` 命令存在。
> **工作目录：** `<worktree>/ios/Contracts/`（运行 swift 命令前 `cd` 进去）。

## §1. 编译通过

**动作：**

```bash
swift build --package-path ios/Contracts
swift build --package-path ios/Contracts -c release
```

**预期：** debug + release 两次都打印「Build complete!」无 warning 无 error。

**通过判定：** 两次 stdout 均含 `Build complete!`。任何 `error:` / `warning:` 行 → 不通过。

## §2. 全部测试通过 258/258

**动作：**

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

**预期：** 输出末尾包含「Test run with 258 tests passed」或 `0 tests failed`。

**通过判定：** 数字 = 258（baseline 260 − 删 12 占位 + 加 10 新测试 = 8 happy + 2 cross-session unmatched）；`0 failures` 且 `0 warnings`。

## §3. 4 个新 Suite 单跑通过 10/10

**动作：**

```bash
swift test --package-path ios/Contracts \
    --filter "ReduceActivateDrawingTests|ReduceSetDrawingSnapshotTests|ReduceDrawingCommittedTests|ReduceDrawingCancelledTests" 2>&1 | tail -10
```

**预期：** 10/10 PASS（activateDrawing 3 + setDrawingSnapshot 3 + drawingCommitted 2 + drawingCancelled 2）。

**通过判定：** 末尾 `Test run with 10 tests passed` 且无 fail 行。

## §4. 占位 Suite 已删除

**动作：**

```bash
grep -c "ReduceDrawingPlaceholderTests" \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
```

**预期：** 输出 `0`。

**通过判定：** 数字 = 0。任何 ≥1 → 不通过（说明 PR7a 占位 Suite 未删干净）。

## §5. Reducer prod 不再含 PR7b1 占位 catch-all

**动作：**

```bash
grep -nE 'PR7b1 scope.*drawing-action 占位|case \(_, \.activateDrawing\),' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

**预期：** 输出为空（无任何匹配行）。

**通过判定：** 命令退出码 = 1（grep 无匹配）。任何匹配 → 不通过。

## §6. Reducer prod 含 spec 字面 4 drawing case + assertion 字符串（R1 M-3 修订：grep 强制 4-cell 全在）

**动作（依次跑 6 条 grep）：**

```bash
# §6.1 activateDrawing — 2 + 1 = 3 case 分支
grep -nE 'case \(\.autoTracking, \.activateDrawing\(let tool\)\)' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

grep -nE 'case \(\.drawing, \.activateDrawing\)' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.2 setDrawingSnapshot stale guard
grep -nE '\.staleDrawingSnapshot\(expected: baseRev, actual: revision\)' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.3 drawingCommitted/Cancelled cross-session guard
grep -nE 'guard base == snap\.frozen\.baseRevision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.4 assertion case 头强制 4 cell 全在（committed: auto+free 同一行；cancelled: auto+free 同一行）
grep -nE 'case \(\.autoTracking, \.drawingCommitted\), \(\.freeScrolling, \.drawingCommitted\),' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

grep -nE '\(\.autoTracking, \.drawingCancelled\), \(\.freeScrolling, \.drawingCancelled\):' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.5 assertion 非法转换字符串
grep -nE 'assertionFailure\("非法转换：' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

**预期：**
- §6.1 第 1 条：命中 1 行
- §6.1 第 2 条：命中 1 行
- §6.2：命中 1 行
- §6.3：命中 2 行（commit + cancel 各 1）
- §6.4 第 1 条（commit auto+free case 头）：命中 1 行
- §6.4 第 2 条（cancel auto+free case 头）：命中 1 行
- §6.5：命中 1 行

**通过判定：** 7 条 grep 全部命中且行数符合上述。任何缺漏 → 不通过。**§6.4 双 grep 强制 4 个 illegal-transition cells 全部在 prod 字面落地（不是任意一个 cell 命中即 PASS）。**

## §7. 5 个 PR7a 既有 case 行为零回归

**动作：**

```bash
swift test --package-path ios/Contracts \
    --filter "ReducePanStartedTests|ReducePanEndedTests|ReduceTradeTriggeredTests|ReducePeriodComboTests|ReduceOffsetAppliedTests|RevisionWrapTests" 2>&1 | tail -10
```

**预期：** 全部 PASS（≥16 tests）。

**通过判定：** 末尾 PASS 总数 ≥ 16，无 fail。

## §8. PR7b1 scope-out 项目（已留下一锚点，不在本 PR 验收）

不验证以下行为（PR 7b2 / PR 7b3 scope）：
1. `staleDrawingSnapshot` 3 条漂移路径单元测试（trade / period / offsetApplied 漂移）→ PR 7b2
2. `requestDrawingSnapshotAfterStoppingAnimator` effect dispatch 集成测试 → PR 7b2 / 7b3
3. `assertionFailure` 非法转换路径直接单元测试（DEBUG trap 阻断；§2 决议）→ 不补；由 §6 grep 守住
4. `DecelerationAnimator.stop()` handler 合约 + integration test → PR 7b3

## §9. 总结

- 新增 10 个测试（8 happy-path 覆盖 12 cells 中 8 cells；2 cross-session unmatched 覆盖 spec L1163-1166 验收 #4；4 assertion cells 由 §6 双 grep 守住）
- prod LOC 净增 ~+43
- 0 新依赖、0 新文件 prod、0 新 SwiftPM target
- spec L1003-1121 字面 reducer 完整落地（PR7b2 仅加 stale 测试 + 部分 effect 集成测试，不动 prod）
