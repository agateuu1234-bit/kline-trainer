# PR F1 验收清单 — Models 薄 wrapper（BinarySearch + 目录整理 + §15.1 #6 sign-off）

> 这份清单给非-coder 用户用：复制每一行"action"到 Claude Code 或 Terminal，对照"expected"判断 pass / fail。

## A. 文件落地

| # | action | expected | pass_fail |
|---|---|---|---|
| A1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Models/` | 看到 2 个文件：Models.swift / BinarySearch.swift | ☑ |
| A2 | `ls ios/Contracts/Sources/KlineTrainerContracts/Models.swift 2>&1` | 输出含 `No such file or directory`（旧路径已被 git mv 删除） | ☑ |
| A3 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/Models/` | 看到 1 个文件：BinarySearchTests.swift | ☑ |
| A4 | `wc -l ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | ≈ 222（M0.3 内容字面保留 + 2 行 header 更新） | ☑ |

## B. 编译验证

| # | action | expected | pass_fail |
|---|---|---|---|
| B1 | `cd ios/Contracts && swift build` | 输出 `Build complete!`，无 error 无 warning | ☑ |
| B2 | `cd ios/Contracts && if ! ( set -o pipefail; swift test 2>&1 \| tee /tmp/pr-f1-b2.log ); then echo FAIL; else tail -5 /tmp/pr-f1-b2.log; fi` | 末尾出现 `Test run with N tests in M suites passed`，**N = 297**（274 baseline + 15 BinarySearch + 8 Codable round-trip = 23 新增）、**M = 63**（60 + 3 新 Suite：`PartitioningIndexTests` + `ComparableBoundTests` + `AdditionalCodableRoundTripTests`）；**未** 出现 `FAIL` 字样 | ☑ |
| B3 | `cd ios/Contracts && swift build -Xswiftc -strict-concurrency=complete 2>&1 \| grep -c "warning:"` | 输出 `0`（严格并发检查无警告） | ☑ |

## C. 单元测试覆盖（共 23 个新 @Test：BinarySearch 15 + Codable round-trip 8）

| # | action | expected | pass_fail |
|---|---|---|---|
| C1 | `swift test --filter PartitioningIndexTests 2>&1 \| grep "passed\|failed" \| tail -3` | 显示 `PartitioningIndexTests` **7 个** @Test（含 `arraySlice_nonZeroStartIndex_returnsAbsoluteIndex`）全部 passed | ☑ |
| C2 | `swift test --filter ComparableBoundTests 2>&1 \| grep "passed\|failed" \| tail -3` | 显示 `ComparableBoundTests` **8 个** @Test（含三插入点 below-min/between/above-max）全部 passed | ☑ |
| C3 | `swift test --filter AdditionalCodableRoundTripTests 2>&1 \| grep "passed\|failed" \| tail -3` | 显示 `AdditionalCodableRoundTripTests` **8 个** @Test（3 struct + 2 enum + 3 现有 gap full equality：Period / TrainingSetMeta / TradeOperation）全部 passed | ☑ |

## D. §15.1 #6 sign-off ledger（F1 名下 §15.1 闸门项，**scope narrow 到 Models.swift only**，codex R7 修订）

| # | spec 闸门 | F1 名下交付物 | 验证证据 | 闸门状态 |
|---|---|---|---|---|
| D1 | §15.1 #6 "M0.3 KLineCandle Codable round-trip：snake_case JSON ↔ camelCase struct" | `Models/Models.swift` KLineCandle 显式 snake_case CodingKeys + `ModelsTests.swift` `KLineCandleTests` 2 @Test | M0.3 PR (历史) + 本 PR baseline swift test GREEN | ✅ **闭合** |
| D2 | F1 验收 "所有类型 Equatable" | Models.swift 全 16 类型（9 enum + 7 struct）`Equatable` 自动合成（M0.3 已落地） | grep `Equatable` 行数 ≥ 16 | ✅ **闭合** |
| D3 | F1 验收 "Reason 枚举 Error conformance 编译通过" | `AppError.swift` 全 Reason 枚举 `: Error, Sendable`（M0.4 PR #15 落地） | M0.4 PR 验收文档 + 当前编译 GREEN | ✅ **闭合**（M0.4 名下交付，F1 引用） |
| D4 | F1 验收 "Codable round-trip 测试" — **scope narrow 到 Models.swift 内的 Codable 实体**（codex R7+R8） | **Models.swift 11 个 Codable 类型**：6 struct + 5 enum；M0.3 既有 3/11 真 round-trip（TradeDirection / DisplayMode / KLineCandle）+ 本 PR `AdditionalCodableRoundTripTests` 补 8 @Test（feeSnapshot / drawingAnchor / drawingObject / positionTier / drawingToolType / period / trainingSetMeta / tradeOperation） | swift test GREEN（Models.swift 11/11 闭环） | ✅ **闭合（Models.swift scope）** |

## E. Scope 边界（不应做的事）

| # | action | expected | pass_fail |
|---|---|---|---|
| E1 | `git diff main -- ios/Contracts/Package.swift` | 输出为空（不动 Package.swift） | ☑ |
| E2 | `git diff main -- ios/Contracts/Sources/KlineTrainerContracts/AppError.swift` | 输出为空（不动 M0.4 AppError） | ☑ |
| E3 | `git diff main -- ios/KlineTrainer/` | 输出为空（不动 Xcode app 工程） | ☑ |

## F. CI（GitHub Actions）

| # | action | expected | pass_fail |
|---|---|---|---|
| F1 | `gh pr checks <pr_number>` | 6/6 checks SUCCESS（或 OpenAI quota fail 走 admin bypass，按 memory `feedback_openai_quota_ci_pattern`） | ☐ 待 PR 打开后 gh pr checks 验 |

## G. 文档

| # | action | expected | pass_fail |
|---|---|---|---|
| G1 | `ls docs/superpowers/plans/2026-05-16-pr-f1-models-wrapper.md` | 文件存在 | ☑ |
| G2 | `ls docs/acceptance/2026-05-16-pr-f1-models-wrapper.md` | 文件存在（本文件） | ☑ |

## H. 已知 plan-residual（**不阻塞本 PR merge**）

| # | residual | 阻塞 | 解决路径 |
|---|---|---|---|
| H1 | BinarySearch 实际消费方（C5 trade marker）未落地 | none | Wave 1 C5 PR 时按 `KLineView+Markers.swift:15` hook 点接入 |
| H2 | §15.4 三方签字 + tag `wave0-frozen-v1.4` | none | PR 9 governance scope |
| H3 | M0.3 spec scope 跨多文件（codex R7+R8）；以下文件中的 M0.3 Codable 实体未在本 PR ledger 闭环：(a) `AppState.swift` 3 struct: TrainingRecord / DrawdownAccumulator / PendingTraining；(b) `RESTDTOs.swift` 2 struct: LeaseResponse / TrainingSetMetaItem | none（F1 scope narrow 到 Models.swift only） | future PR 补 round-trip @Test；spec §F1 "M0.3 所有类型" multi-file split over-claim 由 PR 9 governance §15.4 sign-off 阶段澄清 |
