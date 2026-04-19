# gov-bootstrap-hardening-3 acceptance run (2026-04-19)

## Unit test suite

`python3 -m pytest tests/hooks/ -q` → **104 passed** (78 baseline hardening-2 + 26 new/migrated H3)

Breakdown (new H3 classes):
- `test_guard_env_read.py` — TestEnvDenyDefault (4) + TestEnvAllowList (4) + TestNonEnvPaths (2) + TestOtherTools (1) + TestMalformedInput (1) = 12
- `test_stop_response_check.py::TestDriftStderrFormatH32` — 2
- `test_ack_drift.py` — TestTTYRequirement + TestPPIDHeuristic + TestNothingToAck = 3
- `test_guard_attest_ledger.py::TestDriftCeilingH32` — 3
- `test_guard_attest_ledger.py::TestHeredocStrippingH33` — 2
- `test_settings_json_shape.py::TestH31SettingsCleanup` — 4

New total: 26. Migrated hardening-2 H2-5 enumeration tests to obsolete pass-through (3). Zero regressions on prior 78.

## Acceptance script

`./scripts/acceptance/plan_0a_toolchain.sh` → **PLAN 0A PASS** (25 passed + 1 SKIP for NAS opt-in).

## Spec §8 manual verification

1. **H3-1** `.env.production.local` (compound suffix): before = hardening-2 fall-through to allow; after = `guard-env-read.sh` deny-default on any `.env.*` not in `{example, sample, template, dist}`.
2. **H3-1** `.env.example`: allow-list pass. Unit tested; behavior unchanged from hardening-2.
3. **H3-1** `.env.custom_suffix_abc123` (未知后缀): deny — handled by catch-all hook logic (any `.env.*` basename → deny unless in allow-list).
4. **H3-2 a2** drift stderr: now multi-line boxed format with `Drift count (session log): N` + explicit "YOUR NEXT RESPONSE MUST START WITH". Unit tested.
5. **H3-2 a3** push ceiling: `wc -l skill-gate-drift.jsonl` minus cursor > 5 → `guard-attest-ledger.sh` blocks push with `ack-drift.sh` guidance. Unit tested (3 tests).
6. **H3-2 a3** `ack-drift.sh` ceremony: tty + PPID check + nonce-per-session, cursor advance + audit log append. Unit tested (3 tests).
7. **H3-3** heredoc body containing literal `git push`/`gh pr create` text: `strip-heredoc.py` helper strips body before `detect_scenario` regex scan → no false positive. Unit tested (2 tests).
8. `python3 -m pytest tests/hooks/ -q` — 104/104 passing.

## Commits on branch `gov-bootstrap-hardening-3`

```
2e08cea fix(settings): replace env enum with guard-env-read hook + ack-drift deny (H3-1)
5ab6df6 feat(guard-attest-ledger): strip heredoc body before push/pr detection (H3-3)
74cfe53 feat(guard-attest-ledger): block push when drift count exceeds threshold (H3-2 a3)
aa27d1d feat(ack-drift): tty ceremony script to advance skill-gate-drift cursor (H3-2 a3)
dc835b1 feat(stop-hook): multi-line drift stderr with count + instruction (H3-2 a2)
6bc48cb feat(guard-env-read): fail-closed env file deny with sample allow-list (H3-1)
b03875e plan(gov-bootstrap-hardening-3): 8-task TDD plan for H3-1/2/3
bd69792 spec(gov-bootstrap-hardening-3): H3-1 env-guard hook + H3-2 skill-gate enforcement + H3-3 heredoc fix
```

## Out of scope — deferred to hardening-4+

- H2-3 branch-diff worktree real-target review (codex-companion `--focus` ignored)
- G3 skill pipeline ordering + task-log.jsonl
- Plan subagent-driven default enforcement
- CI `attest-override.sh` / `ack-drift.sh` reject
- Homebrew Cellar allowlist generalization
- Integration tests with real codex-companion
- Session rollup CI report reading skill-gate-drift.jsonl
