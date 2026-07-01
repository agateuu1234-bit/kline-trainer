# Task A5 Report: resumePendingReplay + hasResumableReplay + AppRouter replay branch

## Status
COMPLETE — all 8 new tests pass, 0 regressions across 1266 tests.

## Files Modified
- `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
  — Added `hasResumableReplay(recordId:) -> Bool` (display-only, uses lightweight `loadReplaySlotInfo`)
  — Added `resumePendingReplay(recordId:) async throws -> TrainingEngine?` (full error discipline per brief)
- `ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift`
  — Updated `replay(id:)` to be resume-first (try `resumePendingReplay` first, fall back to fresh `replay`)
- `ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift`
  — Added 8 new `@Test` methods covering all error paths + `makeSlot` helper

## Test Summary
8 new tests in `CoordinatorReplayPersistence` suite, all pass:
- `resumePendingReplay_restoresState` — happy path: save+resume restores tick and mode
- `resumePendingReplay_recordIdMismatch_returnsNil_noClear` — non-matching slot not cleared
- `resumePendingReplay_corruptSlot_nonMatchingRecord_notBlocked` — corrupt A slot doesn't block B
- `resumePendingReplay_corruptSlot_matchingRecord_clearsAndFallsBack` — corrupt own slot: clear+nil
- `resumePendingReplay_corruptPositionJSON_clearsAndFallsBack` — bad positionData: clear+nil
- `resumePendingReplay_corruptSlot_clearFails_propagatesKeepsSlot` — clearReplay failure propagates
- `resumePendingReplay_filenameMismatch_clearsAndReturnsNil` — filename mismatch: clear+nil
- `resumePendingReplay_transientLoadFailure_propagates_keepsSlot` — transient loadReplay: propagate, keep slot

Full suite: 1266 tests in 174 suites, 0 failures.

## Key Implementation Notes
- `hasResumableReplay` uses `loadReplaySlotInfo` (not `loadReplay`) — no payload decode, corrupt payload doesn't affect advisory display
- `resumePendingReplay` error discipline exactly mirrors brief: `.dbCorrupted` (both loadReplay and decodePosition) → durable `clearReplay` (not `try?`) + nil; transient → propagate
- `decodePosition` placed inside the same `do/catch .dbCorrupted` block as `loadReplay` (both are slot-payload errors per codex plan-R18-F1)
- `replayHasPersisted = true` set on resume — resumed session always owns its slot, so autosave never clean-skips (codex plan-R6-F1)
- `replayBaseline` set to resumed engine's current state (not fresh-start baseline)
- AppRouter `replay(id:)` now: try resumePendingReplay → if nil → fresh replay; throw → setError (slot preserved)
- AppRouter tests not added (UIKit-gated routing; coordinator-level tests provide full coverage of the path logic)

## Concerns
None. AppRouter routing is gated on @MainActor + UIKit dependencies that cannot run as host tests; coordinator-level coverage is sufficient per brief's note.

---

## Post-merge fix: codex whole-branch R1 HIGH — corrupt scalar slot bricks record

**Commit:** `015492d` — fix(A5): pre-classify corrupt scalar slot in resumePendingReplay to prevent record brick

**Bug:** `resumePendingReplay` passed `pending.globalTickIndex` / `cashBalance` / `accumulatedCapital` / `drawdown` directly to `TrainingEngine.make`. If those scalars were out-of-range or non-finite/negative, `make` threw `.trainingSet(.emptyData)`; the outer `catch` called `reader.close()` and rethrew — without clearing the slot. Because `AppRouter.replay` is resume-first, every subsequent replay tap on that record hit the same corrupt slot and bricked the record forever.

**Fix** (`TrainingSessionCoordinator.swift`, `resumePendingReplay`): Restructured the single `do/catch` block into three segments:
1. `do { allCandles / mt } catch { reader.close(); throw }` — load candles, close on I/O error.
2. Scalar pre-classification guard (matches `make`'s L220/L236-240 guards exactly): `(0...mt).contains(pending.globalTickIndex)`, `cashBalance.isFinite >= 0`, `accumulatedCapital.isFinite >= 0`, `drawdown.peakCapital.isFinite >= 0`, `drawdown.maxDrawdown.isFinite >= 0`. On failure: `reader.close()` then `try pendingReplayRepo.clearReplay()` (durable — propagates on failure) then `return nil`.
3. `do { make; set state } catch { reader.close(); throw }` — engine construction.

`reader.close()` is guaranteed to fire exactly once on every failure path; the happy path stores `reader` in `activeReader`.

**Tests added** (`CoordinatorReplayPersistenceTests.swift`, 2 new `@Test`):
- `resumePendingReplay_tickBeyondMaxTick_clearsAndReturnsNil`: seeds slot with `globalTickIndex = seededRecordFinalTick + 1` (8 > maxTick 7); asserts returns nil and slot cleared.
- `resumePendingReplay_nonFiniteMoney_clearsAndReturnsNil`: seeds slot with `cashBalance = .infinity`; asserts returns nil and slot cleared.

**Test results:** 1286 tests in 177 suites, 0 failures (Swift Testing + XCTest).

---

## Post-merge fix: codex whole-branch R2 — 1 HIGH + 1 MEDIUM

### R2-F1 HIGH — saved Period absent from candle map bricks replay resume

**Files changed:** `TrainingSessionCoordinator.swift` (guard extended), `CoordinatorReplayPersistenceTests.swift` (1 new test)

**Bug:** `resumePendingReplay` validated scalar fields (tick/cash/capital/drawdown) before calling `TrainingEngine.make`, but did NOT validate that `pending.upperPeriod`/`pending.lowerPeriod` existed in the loaded `allCandles` map. If the saved period was absent (stale/corrupt slot), `make` threw `.trainingSet(.emptyData)` via its `final-R6-F1` guard (L244-245); the `catch` rethrew without clearing the slot → AppRouter resume-first → permanent brick identical to the scalar bug fixed in R1.

**Fix:** Extended the existing WB-R1-F1 scalar guard to also check both periods at its top, mirroring `make` L244-245:
```swift
guard !(allCandles[pending.upperPeriod] ?? []).isEmpty,
      !(allCandles[pending.lowerPeriod] ?? []).isEmpty,
      (0...mt).contains(pending.globalTickIndex),
      ... (existing scalar checks unchanged) ...
```
Updated the guard comment to cite both R1 and R2-F1. No other changes.

**Test added:** `resumePendingReplay_periodAbsentFromCandleMap_clearsAndReturnsNil` — seeds a slot with `upperPeriod: .monthly` (absent from the `.m3/.m60/.daily/.weekly` candle map), `globalTickIndex: 1` (valid). Asserts `resumePendingReplay` returns `nil` and `loadReplaySlotInfo() == nil`.

---

### R2-F2 MEDIUM — stepReviewForward picks exhausted panel when other can still advance

**Files changed:** `TrainingEngine.swift` (stepReviewForward rewritten), `TrainingEngineJumpToEndTests.swift` (2 new tests + sparse candle helper)

**Bug:** `stepReviewForward` used `stepsForPeriod(upperPanel.period) <= stepsForPeriod(lowerPanel.period) ? .upper : .lower`. `stepsForPeriod` returns 0 when a period is exhausted. With `<=`, an exhausted upper (0 steps) always "won" as finer even when lower had positive steps remaining → `holdOrObserve(.upper)` advanced by 0 → review stuck before maxTick.

**Fix:** Replaced one-liner with explicit three-way selection — smallest positive step wins; if one side is 0 the other wins; both 0 → `return` (no-op). Preserved the "finer = smaller positive step when both can advance" behavior.

**Tests added** (both use a custom sparse candle map: `.m60` egi=3, `.daily` egi=7, engine at tick 4):
- `stepReviewForward_finerPeriodExhausted_advancesViaCoarser`: `stepsForPeriod(.m60)==0`, `stepsForPeriod(.daily)==3`; asserts tick advances to 7 (was stuck at 4 before fix).
- `stepReviewForward_bothExhausted_noOp`: `jumpToEnd()` first, then `stepReviewForward()`; asserts tick stays at maxTick=7, no crash.

**Test results:** 1289 tests in 177 suites, 0 failures (Swift Testing); 255 XCTest tests, 0 failures.

---

## Post-merge fix: codex whole-branch R3 — 1 HIGH

### R3-F1 HIGH — replaySettlementFailed 「退出本局」丢失终态：onSessionEnded(nil) 不落盘

**Files changed:** `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` (alert button fix), `ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift` (1 new test)

**Bug:** When `replaySettlementPayload` threw (e.g. `reader.loadMeta()` or `clearReplay` failed), the 「结算失败」alert appeared. Its message promised "暂存进度保留，可在历史记录返回训练". But the 「退出本局」 button called `onSessionEnded(nil)`, which only navigates home (`endSession()` — no save). Crucially, `replaySettlementPayload` calls `fenceAndDrainAutosaves()` first, setting `terminating = true`. The autosave loop exits on `terminating` without writing. So after the fence, the slot held only an older pre-fence checkpoint; the terminal state was never persisted. User tapping 「退出本局」 → resumed later → stale checkpoint (not terminal state). Message promise broken.

**Fix (`TrainingView.swift`, `replaySettlementFailed` alert, ~L165-183):** Changed 「退出本局」 button from synchronous `onSessionEnded(nil)` to the same async durable-exit pattern used by `backFailed`/`finalizeFailed` alerts:
- Guard `exitInFlight` (reuses existing `@State` var).
- `Task { defer { exitInFlight = false }; do { try await lifecycle.back(); onExit() } catch { replaySettlementFailed = true } }`.
- `lifecycle.back()` = `coordinator.saveProgress(engine)` (explicit save, does NOT check `terminating`) + `coordinator.endSession()`. Writes current terminal state to slot before teardown.
- Save failure → re-shows `replaySettlementFailed` alert (retryable).
- Updated comment block above alert to document why `lifecycle.back()` is needed (not `onSessionEnded(nil)`).

**Note:** `jumpToEnd()` is a no-op for `ReplayFlow` (`canJumpToEnd()` returns `false`). The regression test uses `holdOrObserve` twice to establish two distinct checkpoints.

**Test added** (`replaySettlementFailure_durableExit_persistsTerminalTickResumable`): Coordinator-level test of the logic `lifecycle.back()` now invokes. Setup: replay → advance to T1 → `saveProgress` (checkpoint at T1) → advance to T2 → inject `failNextClearReplay` → `replaySettlementPayload` throws (fence kills autosave; slot stays at T1) → durable exit: `saveProgress` + `endSession` → assert `loadReplay()?.globalTickIndex == T2`. Non-vacuity: without `saveProgress`, fence prevents autosave from writing T2, so slot would stay at T1 — the `currentTick > firstTick` assert confirms the two ticks differ.

**Test results:** 1290 tests in 177 suites, 0 failures (Swift Testing); 255 XCTest tests, 0 failures. Catalyst: `** TEST BUILD SUCCEEDED **`.

---

## Post-merge fix: codex whole-branch R4 MEDIUM — review step-through leaks final outcome

**Commit:** `b4a120e` — fix(review): codex whole-branch R4-F1 — reveal drawings by tick + suppress P&L spoiler

### R4-F1A — drawings not revealed progressively by tick

**Files changed:** `RenderStateBuilder.swift`, `RenderStateBuilderTests.swift` (1 new test)

**Bug:** `RenderStateBuilder.make` filtered `engine.drawings` only by `panelPosition`. A drawing anchored to a future candleIndex was rendered from the start of review step-through, leaking visual information about when/where significant events occurred — undermining the "逐根复现" playback.

**Fix:** Extended the drawings filter with an `allSatisfy` predicate mirroring the markers reveal semantic: a drawing is kept only when all its anchors satisfy `anchor.candleIndex <= currentCandleIndex(candles: engine.allCandles[anchor.period] ?? [], tick: tick)`. Empty-anchor drawings pass `allSatisfy` trivially and are kept (harmless: they render nothing). normal/replay are unaffected because drawings there are always past-anchored.

**Test added** (`drawingsRevealByTick_futureAnchorHiddenUntilStepped`): NormalFlow engine at tick=5 with two upper-panel drawings (anchor candleIndex=3 past, anchor candleIndex=8 future). At tick=5: only past-anchored drawing in renderState. After 5× `holdOrObserve` (tick=10): both present.

### R4-F1B — review top bar shows final P&L from step-through start (spoiler)

**Files changed:** `TrainingTopBarContent.swift`, `TrainingView.swift`, `TrainingTopBarContentTests.swift` (8 new tests)

**Bug:** Review mode seeds `initialCashBalance` equal to the final result (D-B3), so `engine.returnRate` and `engine.currentTotalCapital` already reflect the final outcome at review start. The top bar displayed these real values immediately, spoiling the "逐根复现" experience before the user stepped through any candles.

**Fix:** Added two pure static helpers in a public extension on `TrainingTopBarContent`:
- `reviewAwareCapital(mode:isAtEnd:initialCapital:currentTotalCapital:)` → returns `initialCapital` when `mode == .review && !isAtEnd`, else `currentTotalCapital`.
- `reviewAwareReturnRate(mode:isAtEnd:actualReturnRate:)` → returns `0` when `mode == .review && !isAtEnd`, else `actualReturnRate`.

`TrainingView.topBar` now passes these through both the `totalCapital:` and `returnRate:` arguments, using `engine.flow.mode` and `lifecycle.isAtEnd`. Once `isAtEnd` (either stepped-to-maxTick or jump-to-end), real values appear.

**Tests added** (8 cases — full 2×4 matrix for both helpers): review+!isAtEnd / review+isAtEnd / normal+!isAtEnd / replay+!isAtEnd for each helper.

**Test results:** 1299 Swift Testing tests in 178 suites, 0 failures; 255 XCTest tests, 0 failures. Catalyst: `** TEST BUILD SUCCEEDED **`.
