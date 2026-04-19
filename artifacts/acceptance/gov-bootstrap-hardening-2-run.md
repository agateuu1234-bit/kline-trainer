# gov-bootstrap-hardening-2 acceptance run (2026-04-19)

## Unit test suite

`python3 -m pytest tests/hooks/ -q` → **77 passed** (16 new over baseline 61)

Breakdown (new H2 classes):
- `TestFirstLineCompliant` / `TestFirstLineMissing` / `TestExemptBadReasonStillBlocks` (test_stop_response_check.py) — 5 tests
- `TestVerdictParserFirstLineH22` — 3 tests
- `TestShellOpsFilterH24` — 2 tests
- `TestEnvExampleExemptionH25` — 6 tests

Total new: 16. Zero regressions on prior 61 tests.

## Acceptance script

`./scripts/acceptance/plan_0a_toolchain.sh` → **PLAN 0A PASS** (25 passed, 0 failed, 1 SKIP for NAS preflight per Plan 0a v3 opt-in default).

## Spec §8 manual verification

1. **H2-1 drift log**: During this session, any response that skips first-line `Skill gate:` now appends an entry to `.claude/state/skill-gate-drift.jsonl` (gitignored) with `time_utc` / `first_line` / `inferred_skill` / `response_sha`. stop-hook exit 0 (no block). Before H2-1 the stop-hook was blocking with error, observed 29 times across hardening + Plan 0a v3 + hardening-2 sessions.

2. **H2-2 parser hardening**: `test_parser_rejects_spoofed_approve_in_body` covers the spoofing attack (header verdict = needs-attention + body text contains a fake approve line). Pre-patch: old parser took LAST line -> approve -> ledger wrongly updated. Post-patch: parser collects all matches -> ambiguous -> exit 7 -> ledger NOT updated.

3. **H2-4 refspec shell-op filter**: pushing a branch with `2>&1` tail is now correctly parsed as the branch name; pre-patch would misread the redirect token as src-branch and fail with a `cannot compute diff origin/main..` error referencing the token.

4. **H2-5 env.example exemption**: `Read backend/.env.example` now flows through catch-all Read allow (no ask/deny). `Read backend/.env.production` still deny. Blanket `**/.env.*` removed.

## Commits on branch `gov-bootstrap-hardening-2`

```
0507719 fix(settings): env deny enumeration exempts .env.example/.sample/.template (H2-5)
d575132 fix(guard-attest-ledger): refspec parser skips shell operators (H2-4)
c7b86ab fix(codex-attest): parser take-first + fail-closed duplicates (H2-2)
5d1b704 fix(stop-hook): drift-log instead of block on missing Skill gate (H2-1)
a2f9a30 plan(gov-bootstrap-hardening-2): 6-task TDD plan for H2-1/2/4/5
081af18 spec(gov-bootstrap-hardening-2): H2-1 skill gate auto-inject + H2-2/4/5
```

## New hardening-3 backlog observed this session

11. **Hook BLOCK_UNPARSEABLE false positive on heredoc content** — when a Bash command has a long heredoc body that merely mentions `git push` / `gh pr create` / `gh pr merge` as text (e.g., writing acceptance docs), the hook's conservative substring fallback fires and blocks the whole command. Fix: scope the substring check to only the outer command tokens, not the heredoc body; or skip the fallback when a heredoc is detected.

## Out of scope (deferred to hardening-3)

- H2-3 branch-diff worktree-based review (codex-companion `--focus` is ignored; reviews current checkout)
- G3 skill pipeline ordering / task-log.jsonl
- subagent-driven enforcement
- CI attest-override reject
- integration tests with real codex-companion
- allowlist generalization
- hardening-2 observed #11: hook false-positive on heredoc with protected command names
