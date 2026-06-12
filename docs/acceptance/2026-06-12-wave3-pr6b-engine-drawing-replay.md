# 验收清单 — Wave 3 顺位 6b：appendDrawing + replaySettlementPayload engine 契约

**交付物：** `engine.appendDrawing(_:)`（RFC §4.4c 画线投影单一真相，供顺位 4）+ `coordinator.replaySettlementPayload(engine:)`（RFC §4.4e 非持久化 replay 结算 payload，供顺位 8）。§4.4d zoom 经 user 2026-06-12 裁决移顺位 3，不在本 PR。纯逻辑层增量，无 UI/schema/render 文件改动；**未改 `finalize`**。

**前置：** 在 `ios/Contracts` 目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `swift test --filter appendDrawing` | `Test run with 3 tests ... 0 failures`；`appendDrawingAddsToDrawings`、`appendDrawingAccumulatesInOrder`、`appendDrawing_flowsIntoPendingPersistence` 均 ✔ | `3 tests` 且 `0 failures` 且 3 名 ✔ = 通过；否则不通过 |
| 2 | `swift test --filter replaySettlementPayload` | `Test run with 4 tests ... 0 failures`；含 `_returnsTerminalStateRecord`、`_doesNotPersist`（records 计数不变 + pending nil + finalize 仍返 nil）、`_throwsInNonReplayMode`、`_throwsWithoutActiveSession` | `4 tests` 且 `0 failures` 且 4 名 ✔ = 通过；否则不通过 |
| 3 | `swift test`（全量回归） | `Test run with N tests`，`N ≥ 828`（基线 821 + 新增 7），`0 failures` | `0 failures` = 通过；≥1 failure = 不通过 |
| 4 | 阅读 `git diff origin/main -- ios/Contracts/Sources` | 仅 `TrainingEngine.swift`（+`appendDrawing`）与 `TrainingSessionCoordinator.swift`（+`replaySettlementPayload`）被改；无 `.sql`/schema/`CONTRACT_VERSION` 改动；**`finalize` 方法体零改动**；无 `RenderStateBuilder`/`makeViewport`/`PanelViewState` 改动（zoom 在顺位 3） | 改动文件集 ⊆ {TrainingEngine.swift, TrainingSessionCoordinator.swift} 且 finalize 未改 且无 render/schema 改动 = 通过；否则不通过 |
| 5 | Mac Catalyst CI（PR 上 `Mac Catalyst build-for-testing on macos-15`） | required check 状态 = success | check = success = 通过；failure = 不通过 |
