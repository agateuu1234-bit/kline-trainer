# U4 Code Review R1 (overall, post-implementation) — MAXIMUM rigor

Verdict: NEEDS-ATTENTION

Scope reviewed: AppState.swift (`AppSettings.default`), Settings/SettingsResetConfirmation.swift, Settings/SettingsStore.swift (`retryReload`/`forceResetAndReload`), UI/SettingsPanelContent.swift, UI/SettingsPanel.swift, Tests (RecoverySettingsDAO, SettingsStoreRecoveryTests, SettingsPanelContentTests, AppSettingsDefaultTests). Verified against RFC §四 (11 scenarios), plan, frozen modules §U4/§P6. Full suite run locally: **658 tests / 109 suites, 0 failures**.

The single NEEDS-ATTENTION driver is a **branch-integration / stale-evidence** process issue (Important #1), not a code-logic defect. All 11 recovery scenarios, concurrency, visibility, defaults, and shell wiring are correct. If the integration step is performed and re-verified, this is an APPROVE-grade implementation.

---

## Critical
None.

The recovery state machine matches RFC §四 for all 11 scenarios (traced line-by-line below). No data race, no isolation violation, no vacuous test, no frozen-contract breakage.

---

## Important

### I1. Branch is 2 merged PRs behind `origin/main`; `git diff origin/main..HEAD` is misleading and local verification predates integration
- Evidence: `git merge-base origin/main HEAD` = `57fce77` (顺位 6 P2). `origin/main` HEAD = `22c88de` (C8a #84) with `feb3d3e` (E6a #83) also in `HEAD..origin/main`. Consequently `git diff origin/main..HEAD` reports E6a/C8a files as **deleted** (`D ChartContainerView.swift`, `D RenderStateBuilder.swift`, `D *Tests`) and `M TrainingSessionCoordinator.swift` — these are **stale-branch artifacts, not U4 changes**. The true U4 diff (`git diff 57fce77..HEAD`) touches only AppState.swift + Settings/* + UI/* + the 4 new test files.
- Risk: (a) any reviewer or merge tooling that treats `origin/main..HEAD` as authoritative would read this as reverting E6a/C8a; (b) the acceptance doc's "658 tests / 109 suites" and Catalyst `TEST BUILD SUCCEEDED` were captured on the **pre-integration** tree — E6a (#83) and C8a (#84, +20 render tests) are NOT compiled/tested together with U4. The merged-tree count and Catalyst gate are unverified.
- Mitigating facts (verified): U4 and E6a/C8a have **zero file overlap** — E6a/C8a touch only `Render/*` + `TrainingSessionCoordinator.swift` + their tests; U4's only `M` files are `AppState.swift` and `SettingsStore.swift`, neither touched by E6a/C8a. A 3-way merge / rebase is guaranteed conflict-free.
- Fix: rebase the branch onto current `origin/main` (or merge main in), then re-run `swift test` (expect ≥658 + E6a/C8a counts) and the Catalyst build-for-testing on the integrated tree; update the acceptance doc's count/output. Do NOT merge with a strategy that could resurrect the apparent deletions.

---

## Minor

### M1. `forceResetAndReload` post-reset reload-failure path is correct but untested
- Evidence: SettingsStore.swift L172-181. After `saveSettings(.default)` succeeds, if the reload at L175 throws, the error propagates and `_loadError` retains the entry `dbCorrupted` (never cleared) — matches RFC §四 L75 "仍失败 → throws + loadError 保留". But no scenario exercises "save succeeds, reload-after-reset fails". s9 (`s9_destroyWriteFails`) covers save-fails; nothing covers reload-after-save-fails.
- Impact: a future regression that clears `_loadError` before the post-reset reload completes would go undetected.
- Fix (optional): add one scenario — loadScript `[dbC, dbC, dbC]` with a DAO that throws on the 4th (post-save) load; assert `loadError == dbCorrupted` and the call throws.

### M2. Runtime re-corruption is unrecoverable by design (no `nil→non-nil` loadError transition at runtime)
- Evidence: `_loadError` is only set in `init` and in the failure branches of `retryReload`/`forceReset` (both of which require `loadError != nil` to enter). Once healthy, the store never re-detects corruption from a failing `update`/`resetCapital` save (those `try await ... dao.saveSettings` errors propagate to the caller but do not set `_loadError`).
- Impact: matches RFC scope (recovery targets init-time loadError only) — not a defect, but worth an explicit note so a later caller doesn't assume post-recovery writes self-heal.
- Fix: none required; documentation-only if desired.

### M3. `_ = confirmation` is dead-store-ish self-documentation (already noted in plan-review L2)
- Evidence: SettingsStore.swift L144 `_ = confirmation`. Swift does not warn on unused function parameters, so the line is non-functional; the comment correctly frames it as a deliberate-intent marker. Harmless; flagging only for completeness.

---

## Detailed verification (basis for the verdict)

### 1. RFC §四 — 11 scenarios, traced impl vs contract
Impl call model: `init`=1 load; `retryReload`=1 load; `forceReset` pre-destroy reload=1 load; on dbCorrupted-final → `saveSettings`+1 reload. RecoverySettingsDAO FIFO-consumes loadScript then returns `stored` (which `saveSettings` updates). All loadScript lengths/indices align with call counts (no off-by-one).

| RFC | Test | Trace | Verdict |
|---|---|---|---|
| 1 transient retry success | s1 | `[ioError, user]`: init#1 fail→loadError; retry#2→user, settings=user, loadError=nil, save=0; update unblocks | ✅ settings-before-clear-error + zero-destroy |
| 2 persistent malformed | s2 | `[dbC,dbC,dbC]`: retry#2 throws; force pre-reload#3 dbC→save(.default)=1→reload returns stored(.default); fee 0.0001 | ✅ |
| 3a/3b healthy guard | s3a/s3b | `[user]`: loadError==nil → both throw, settings unchanged, save=0 | ✅ healthy guard |
| FR7 retry updates error | retryFailUpdatesLoadError | `[ioError,dbC]`: loadError flips init-ioError→dbC (latest, not stale) | ✅ |
| 4 order guard | s4 | `[dbC]` no retry: `_retryReloadFailed==false` → throws guard②, save=0 | ✅ |
| 5 self-heal pre-destroy | s5 | `[dbC,dbC,user]`: force pre-reload#3 succeeds→settings=user, loadError=nil, save=0 | ✅ destroy avoided |
| 6 transient gate (FR2) | s6 | `[diskFull,diskFull]`: loadError=diskFull, force guard③ (not dbC) throws diskFull, save=0 | ✅ |
| 7 persistent corruption | s7 | `[dbC,dbC,dbC]`: save=1, settings=.default, unblock | ✅ |
| 8 mixed error (FR3) | s8 | `[dbC,dbC,diskFull]`: enter dbC, pre-reload#3 diskFull → loadError=diskFull, throws, save=0 | ✅ |
| 9 destroy write fails | s9 | `[dbC,dbC,dbC]`+saveError: save throws → loadError stays dbC, throws | ✅ |
| 10 init-transient→retry-dbC (FR7) | s10 | `[ioError,dbC,dbC]`: retry flips to dbC; force passes gate on latest → save=1, .default | ✅ |
| 11 init-dbC→retry-transient (FR7) | s11 | `[dbC,ioError]`: retry flips to ioError; force gate③ rejects → throws ioError, save=0 | ✅ |

All RFC sub-contracts satisfied: settings-before-clear-error (L124, L160, L178); FR7 latest-error (L131); dbCorrupted-only gate (L107-110, L151-153, L167); FR3 mixed-error catch-gate (L165-170); order guard (L148-150); healthy guard (L116, L145).

### 2. Swift 6 concurrency — clean
- `@MainActor @Observable final class`; all mutations of `settings`/`_loadError`/`_retryReloadFailed` happen on MainActor (after `await Task.detached{...}.value` resumes back on the actor). `Task.detached` bodies only call DAO methods on captured `let dao` (SettingsDAO is `Sendable`); `AppSettings`/`AppError` are `Sendable`. No cross-actor mutable capture. Same pattern as existing `update`/`resetCapital`.
- Recovery methods do NOT join the `pendingMutations` chain — acceptable because `update`/`resetCapital` throw immediately while `loadError != nil`, so no in-flight mutation can race recovery in the gated state. Concurrent double-trigger of recovery itself is a known non-goal (plan M1), mitigated in the shell via `isRecovering` disable (SettingsPanel.swift L23, L110, L117, L122, L129). Not a data race (all on MainActor); worst case is logical clobber, prevented by the UI gate.

### 3. Tests genuine, not vacuous
- RecoverySettingsDAO faithfully models init/retry/force load counts (FIFO + post-exhaustion `stored` reflects writes). `saveCallCount`/`lastSaved`/`saveError` enable real destroy-vs-no-destroy assertions. Acceptance doc §1.3 records a real mutation check (flipping the error-type gate to always-pass → s6 & s11 fail), proving the gate is load-bearing. Distinguishing assertions (`settings == userSettings` vs `== .default`, `saveCallCount == 0` vs `== 1`, `loadError ==` specific case) prevent a wrong impl from passing. No vacuous test found.

### 4. SettingsResetConfirmation visibility — legal and correct
- `public struct ... { internal init() {} }` (SettingsResetConfirmation.swift L8-9). Used as a parameter of `public func forceResetAndReload(confirmation:)` (SettingsStore.swift L143), so `public` on the type is required and justified. `internal init` blocks out-of-module (顺位 11 app target) construction while allowing in-module `SettingsPanel` to construct it (SettingsPanel.swift L125). `Sendable` conformance trivially holds. Matches RFC's "deliberate-intent signal, not a hard security boundary".

### 5. AppSettings.default — correct, non-zero
- AppState.swift L171-175: commissionRate 0.0001, minCommissionEnabled false, totalCapital 100_000, displayMode .system. Non-zero fee+capital satisfy RFC scenario 2. Distinct from private `zeroDefault` (capital 0). Tests assert exact values + non-zero (AppSettingsDefaultTests).

### 6. SettingsPanel shell — 5 controls correct
- (1) 佣金费率 button: edit via `parseCommissionUIInput` (L82) and `formatCommissionUIInput` (L44-45) — spec L2009/L2013 conversion. (2) 免5 toggle inversion: `get: !minCommissionEnabled` / `set: minCommissionEnabled = !newValue` (L50-54) — **correct**: spec §6.4 "关闭=免5"; 免5-on ⟺ minCommissionEnabled==false. (3) resetCapital via destructive alert (L88-92). (4) 离线缓存: `validateDownloadCount` (1~20) → `reserveTrainingSets(count:)` → `runBatch(lease:)` → counts `.confirmed` (L134-152) — signatures verified against APIClient/DownloadAcceptanceRunner; `.confirmed` is a valid AcceptanceResult case. (5) displayMode segmented Picker via `update{ $0.displayMode = }` (L67-74). All recovery errors mapped via `AppError.userMessage` (exists, L55). No logic bug in shell. (Shell is not unit-tested by design — D8/D10 — covered by Catalyst compile gate + #Preview.)

### 7. Frozen contracts untouched
- SettingsDAO protocol: zero diff (only new test fake `RecoverySettingsDAO` conforms). SettingsPanel init signature matches modules §U4 L2081-2084 (`any APIClient`/`any CacheManager` is the Swift 6 existential spelling; semantically identical). retryReload/forceResetAndReload signatures match modules §P6 L2002-2003 verbatim, including `confirmation:` marker. modules §P6 predicate-(d) anchors all present (verified in modules_v1.4.md L2002-2003 + L2020 block). No modification to existing tests; existing 13 SettingsStoreProductionTests behavior preserved.

### 8. Other
- No debug leftovers / TODO / print in any new source file. No dead code beyond M3's intentional marker. Naming consistent with codebase. Acceptance doc grep contracts (§3.1–3.4) are sound (note: §3.1 uses `grep -c -E` count ≥5 over an OR-pattern; acceptable here).

---

## Assessment
Code logic is correct and well-tested: all 11 RFC recovery scenarios trace true, concurrency is sound under MainActor, visibility/defaults/shell-wiring are right, and frozen contracts are intact. NEEDS-ATTENTION is driven solely by I1 — the branch trails `origin/main` by E6a (#83) and C8a (#84), so the misleading `origin/main..HEAD` deletions and the pre-integration test/Catalyst evidence must be resolved by rebasing and re-verifying on the merged tree (conflict-free; zero file overlap confirmed) before merge.
