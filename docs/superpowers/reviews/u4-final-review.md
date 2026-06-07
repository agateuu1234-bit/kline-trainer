# U4 SettingsPanel — Final Adversarial Review (opus 4.8 xhigh)

Verdict: APPROVE

Scope: `git diff origin/main..HEAD` = 13 files, U4-only (5 prod swift + 4 test + 4 docs). No
deletions, no Render/* or TrainingSessionCoordinator changes — rebase onto E6a #83 + C8a #84 is
clean, not regressed.

Empirical verification run:
- `swift test` full suite: **696 tests in 111 suites, 0 failures**.
- U4 suites (`SettingsStoreRecoveryTests` + `AppSettingsDefaultTests` + `SettingsPanelContentTests`):
  **22 tests pass**.
- Governance content predicates (verify-wave2-pr1-rfc.sh): (a)(b)(c)(d)(e)(g) PASS. See Minor #1 re (f).
- Mutation cross-check via static branch-distinguishing analysis (in-place source mutation declined
  per "do not modify code" — respected).

## 11 RFC scenarios + 9b re-traced through actual code (SettingsStore.swift L115-182)

All match RFC §四 exactly. Final settings / loadError / saveSettings-called / throws verified:

| # | Path | final settings | loadError | save? | throws? | code | RFC |
|---|------|---------------|-----------|-------|---------|------|-----|
| 1 | transient→retry ok | userSettings | nil | no | no | L121-126 | §83 ✓ |
| 2 | malformed→retry✗→force | .default | nil | 1× | no(force) | L172-180 | §84 ✓ |
| 3a/3b | healthy | unchanged | nil | no | yes | L116/L145 | §85 ✓ |
| 4 | skip-retry→force | unchanged | dbCorrupted | no | yes | L148 | §86 ✓ |
| 5 | entry dbCorrupted, pre-destroy reload ok | userSettings | nil | no | no | L157-163 | §87 ✓ |
| 6 | transient unrecovered→force | unchanged | diskFull | no | yes | L151-153 (entryError gate) | §88 ✓ |
| 7 | persistent corruption | .default | nil | 1× | no | L167-180 | §89 ✓ |
| 8 | entry dbCorrupted, pre-destroy reload→transient | unchanged | diskFull | no | yes | L167-169 | §90 ✓ |
| 9 | dbCorrupted + save✗ | unchanged | dbCorrupted | 0× (throw pre-count) | yes | L172-174 | §91 ✓ |
| 10 | init transient→retry dbCorrupted→force | .default | nil | 1× | no | L131(FR7)→L151 | §92 ✓ |
| 11 | init dbCorrupted→retry transient→force | unchanged | ioError | no | yes | L131(FR7)→L151-153 | §93 ✓ |
| 9b | dbCorrupted, save ok, post-save reload✗ | unchanged | dbCorrupted | 1× | yes | L175-177 | codereview M1 ✓ |

Key invariants confirmed: reload-before-clear (`self.settings = loaded` precedes `_loadError = nil`,
L124-125 / L160-161 / L178-179, R2-high); error-type gate uses **entryError** = latest retry error
(L151), so transient never reaches destruction (FR2); FR7 latest-error update on retry failure (L131);
mixed-error pre-destroy transient reclassifies + refuses destroy (L167-169, FR3).

## Critical
None.

## Important
None.

## Minor
1. **`verify-wave2-pr1-rfc.sh` predicate (f) FAILs on this branch — but it is NOT U4's gate.**
   That script (scripts/governance/verify-wave2-pr1-rfc.sh L21-31) ships from the 顺位 1 RFC PR (#79);
   its scope allowlist is hardcoded to that docs-only PR's 9 files. U4's own acceptance gate is
   `docs/acceptance/2026-06-07-pr-u4-settings-panel.md`, which is self-contained (test counts, grep
   contracts, Catalyst build, SettingsDAO-untouched) and does NOT invoke (f). The content predicates
   that matter for U4 — (d) modules §P6 contains both new signatures + invariants, (g) reconcile —
   PASS. No action required; do not "fix" (f) to include U4 files (that would corrupt PR #79's frozen
   gate). Flagging only so a reviewer running the script isn't misled by GATE FAIL.
2. **免5 toggle polarity is a deliberate relabel vs plan §6.4 literal.** plan_v1.5 §6.4 row reads
   "关闭=免5 / 开启=不免5" (toggle position describes the field). SettingsPanel.swift L50-54 relabels
   the control "免5（不收最低 5 元佣金）" and inverts the binding so ON = 免5 active (the intuitive
   reading). **Persisted `minCommissionEnabled` is correct in both interpretations** (true = charge
   minimum); only the visual on/off↔value mapping differs. Not a data-correctness bug; shell is
   Catalyst-gated, no test asserts polarity. The §6.4 row is itself counterintuitive; impl picked the
   sane UX. Acceptable; note for product sign-off.
3. **Recovery methods don't join the `pendingMutations` serialization chain** (L53/L72 vs L115/L143).
   In principle an in-flight `update()` could interleave with `retryReload` post-await. Practically
   harmless: recovery runs only while `loadError != nil` (writes blocked at L52/L71), and the UI
   gates with single-shot `isRecovering` (SettingsPanel L23/L110/L117/L121/L129). RFC does not require
   chain participation. No defect.

## Concurrency (Swift 6 strict)
Clean. `@MainActor @Observable final class`; all `Task.detached` blocks capture only Sendable `dao`
+ value-type snapshots (`AppSettings.default`, `copy`); every `self.settings`/`_loadError`/
`_retryReloadFailed` write occurs on MainActor after `await` (L124-126/160-162/168/178-180). Matches
frozen PR4b pattern. No data race or isolation defect.

## Other checks
- SettingsResetConfirmation: `public struct` + `internal init()` — legal; gates out-of-module
  construction (顺位 11 app target) while allowing in-module SettingsPanel L125 + tests. All 13
  construction sites are inside Contracts. ✓
- AppSettings.default (AppState.swift L170-176): commissionRate 0.0001 (non-zero, scenario 2 fee),
  totalCapital 100_000 (§6.4 10万), system, minCommissionEnabled false. Non-zero ✓; values per §6.4 ✓.
- SettingsPanel shell: 5 controls present & wired (佣金/免5/重置资金/离线缓存/显示模式); 免5 inversion
  internally consistent; 离线缓存 reserveTrainingSets→runBatch→filter .confirmed (signatures verified);
  recovery UX exposes destructive button only after retry fails (recoveryMessage non-empty, L119);
  isRecovering disables during op. No logic bug.
- Frozen SettingsDAO protocol: zero diff (untouched). Existing TrainingSessionCoordinator uses only
  init/snapshotFeesIfReady/settings — unaffected by additive recovery API. Existing 674 tests green.
- Tests genuine, not vacuous: loadScript arrays distinguish branches precisely (e.g. s5 vs s7 differ
  ONLY in 3rd entry yet assert opposite save behavior; s9 vs s9b differ ONLY by saveError yet assert
  saveCallCount 0 vs 1); post-save reload returns DAO `stored` reflecting the actual save, killing
  hardcoded-success mutants. Load-call counts per scenario verified against init(1)+retry(1)+force(1-2).
- No leftover debug/TODO/print/fatalError. modules §P6 contract carries both new signatures + invariants
  (predicate d PASS).

## Final assessment (2 lines)
U4 faithfully implements the RFC §四 two-layer recovery: all 11 scenarios + 9b trace exactly to code,
tests are mutation-resistant, concurrency is sound, frozen surfaces untouched, 696/696 green.
The single gate FAIL is an unrelated PR-1 script artifact; the two remaining notes are UX/design, not
correctness. Ship.
