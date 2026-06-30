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
