# PR 7b2 — C1b Stale Drift Tests + Helper Extract + Cosmetic 验收清单

> **目标读者：** 不写代码的复审人（按 §动作 步骤跑命令、对照 §预期 / §通过判定 勾选）。
> **前置条件：** 已 checkout PR7b2 worktree branch；macOS 终端打开；`xcrun --find swift` 命令存在。
> **工作目录：** `<worktree>/`（运行 swift 命令前 `cd` 进去；命令内带 `--package-path ios/Contracts` 不需要进子目录）。

## §1. 编译通过

**动作：**

```bash
swift build --package-path ios/Contracts
swift build --package-path ios/Contracts -c release
```

**预期：** debug + release 两次都打印「Build complete!」无 warning 无 error。

**通过判定：** 两次 stdout 均含 `Build complete!`。任何 `error:` / `warning:` 行 → 不通过。

## §2. 全部测试通过 265/265 in 58 suites（baseline 258/57 + 7 新测试 + 1 新 Suite）

**动作：**

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

**预期：** 输出末尾 `Test run with 265 tests in 58 suites passed`。

**通过判定（R5 medium-1 + R6 medium-1 修订：双轨判定，绝对 + 相对）：**
- **绝对：** 数字 = 265 tests in 58 suites（baseline 258 in 57 suites + 5 stale + 2 distinguishing 新测试 + 1 新 Suite `ReduceStaleDrawingSnapshotTests`）；`0 failures` 且 `0 warnings`
- **相对：** = Step 1.1 baseline + 7 tests + 1 suite（若 baseline 漂移而 plan 已 patch baseline 数字，相对差不变）
- 若 baseline 在实施期间漂（Step 1.1 实测 != 258/57），则 plan 内 265/58 同步 +漂移量，相对差仍为 +7/+1

## §3. 新 Suite `ReduceStaleDrawingSnapshotTests` 5/5 + distinguishing 2/2 = 7/7 PASS

**动作（R4 medium-1 修订：filter 必须包含 2 distinguishing test 函数名，不能只过滤 Suite——distinguishing tests 在 `ReduceDrawingCommittedTests` / `ReduceDrawingCancelledTests` 既有 Suite 内）：**

```bash
swift test --package-path ios/Contracts \
    --filter "ReduceStaleDrawingSnapshotTests|drawingCommittedReadsSnapshotNotRevision|drawingCancelledReadsSnapshotNotRevision" 2>&1 | tail -10
```

**预期：** 7/7 PASS（5 stale：tradeDrift / tradeDriftNonZeroBaseline / periodComboDrift / offsetAppliedDrift / freeScrollingOffsetAppliedDrift；2 distinguishing：drawingCommittedReadsSnapshotNotRevision / drawingCancelledReadsSnapshotNotRevision）。

**通过判定：** 末尾 `Test run with 7 tests passed` 且无 fail 行。**严格要求 7 不允许 5 / 6**——任何小于 7 = filter 未匹配全部 distinguishing tests / nonzero baseline test 缺失 = mutation-killing 覆盖未跑。

## §4. Helper 抽出完成 — 13 处 inline copy 已删，2 个 file-level helper 已加

**动作：**

```bash
# 旧 inline helper 应全删（应返回 0）
grep -cE 'private func (make|drawingMode)\(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# 新 file-level helper 应存在（应返回 2）
grep -cE 'private func (makePanel|makeDrawingMode)\(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# callsite rename 完成（旧名 0；新名 ≥13）
grep -c 'makePanel(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
grep -c 'makeDrawingMode(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
```

**预期：**
- 第 1 条：`0`
- 第 2 条：`2`
- 第 3 条：`≥9`（每处原 make callsite 替换；不计 helper 定义本身的 1 行）
- 第 4 条：`≥4`（每处原 drawingMode callsite 替换；不计 helper 定义本身的 1 行）

**通过判定：** 4 条 grep 数值符合上述。任何偏差 → 不通过。

## §5. Prod inline comment 字面对齐 spec L1056 / L1072 / L1082

**动作：**

```bash
# §5.1: spec L1056 inline comment
grep -nF '// 切换工具由 DrawingToolManager 处理' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §5.2: spec L1072 inline comment
grep -nF '// drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §5.3: spec L1082 cross-session guard 注释字面
grep -nF '// 来自上一轮 session 的延迟 action，忽略' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §5.4: 旧 PR7b1 wording 已删
grep -cF '// 旧 session 遗留 action，丢弃保持当前 drawing' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

**预期：**
- §5.1 命中 1 行
- §5.2 命中 1 行
- §5.3 命中 1 行
- §5.4 返回 `0`

**通过判定：** 3 条 grep 命中 1 行 + 1 条 grep 返回 0。任何偏差 → 不通过。

## §6. Stale guard + cross-session guard 字面守住 — mutation belt+suspenders

**动作：**

```bash
# §6.1: stale guard 字面
grep -nE 'guard baseRev == revision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.2: stale return literal
grep -nF '.staleDrawingSnapshot(expected: baseRev, actual: revision)' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.3: cross-session guard 字面（R2 medium-2：守第 3 L cosmetic mutation 盲区——
#        unmatched unit test 使用 snap.baseRev == state.revision，wrong-source mutation
#        `guard base == revision` 不被 unit test 抓；grep 守 prod 字面 `base == snap.frozen.baseRevision`
#        在 commit + cancel 两处都未误改）
grep -cE 'guard base == snap\.frozen\.baseRevision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

**预期：**
- §6.1 命中 1 行
- §6.2 命中 1 行
- §6.3 返回 `2`（drawingCommitted + drawingCancelled 各 1 行；不允许 0 / 1 / 3+）

**通过判定：** §6.1 + §6.2 命中 1 行 + §6.3 返回 2。任意偏差 → 不通过（说明 PR7b1 已落的 stale guard 或 cross-session guard 被本 PR 误改）。

## §7. PR7a / PR7b1 既有 Suite 行为零回归

**动作：**

```bash
swift test --package-path ios/Contracts \
    --filter "ReducePanStartedTests|ReducePanEndedTests|ReduceTradeTriggeredTests|ReducePeriodComboTests|ReduceOffsetAppliedTests|ReduceActivateDrawingTests|ReduceSetDrawingSnapshotTests|ReduceDrawingCommittedTests|ReduceDrawingCancelledTests|RevisionWrapTests" 2>&1 | tail -10
```

**预期：** 全部 PASS（≥26 tests = PR7a 15 + PR7b1 10 + revision wrap 1）。

**通过判定：** 末尾 PASS 总数 ≥ 26，无 fail。

## §8. PR7b2 scope-out 项目（不在本 PR 验收，已留下一锚点）

不验证以下行为（PR 7b3 scope）：
1. `requestDrawingSnapshotAfterStoppingAnimator` effect handler **真派发**集成测试（含 animator.stop() 必须在 candleRange 计算前 → PR 7b3）
2. `DecelerationAnimator.stop()` handler 合约 + integration test → PR 7b3
3. 第 3 L cosmetic「unmatched test 不能区分 guard 读 wrong source mutation」→ R3 high-1 修订后由本 PR 2 个 distinguishing tests（`drawingCommittedReadsSnapshotNotRevision` + `drawingCancelledReadsSnapshotNotRevision`）+ §6.3 grep 三轨守备落地，不再 scope-out

## §9. 总结

- 新增 5 个 stale 漂移 tests（spec L1159-1162 验收 #3 三条 auto path 完整覆盖 + R2 medium-1 freeScrolling + R6 medium-1 trade nonzero baseline：tradeDrift / tradeDriftNonZeroBaseline / periodComboDrift / offsetAppliedDrift / freeScrollingOffsetAppliedDrift）
- 新增 2 个 distinguishing wrong-source mutation-killing tests（R3 high-1：drawingCommittedReadsSnapshotNotRevision / drawingCancelledReadsSnapshotNotRevision；distinguishing fixture state.rev != snap.baseRev 覆盖 prod cross-session guard 读取源）
- 抽出 13 处 inline test helper copy → 2 个 file-level `private func`（PR7b1 plan §4 R1 M-4 技术债结算）
- prod 3 处 inline comment 字面对齐 spec L1056 / L1072 / L1082；零行为变
- 0 新依赖、0 新文件 prod、0 新 SwiftPM target
- 265 tests in 58 suites / 0 failures / 0 warnings；PR7a + PR7b1 既有 Suite 零回归
