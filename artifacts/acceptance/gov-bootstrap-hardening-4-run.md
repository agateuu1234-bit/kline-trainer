# gov-bootstrap-hardening-4 acceptance run (2026-04-19)

## Unit test suite

`python3 -m pytest tests/hooks/ -q` → **109 passed** (105 hardening-3 baseline + 4 new H2-3)

New H2-3 tests in `TestWorktreeBranchReviewH23`:
- `test_branch_diff_reviews_target_sha_not_current_checkout` — core mechanism: codex sees target's tree, not cwd
- `test_worktree_cleaned_on_success` — trap cleanup on approve
- `test_worktree_cleaned_on_failure` — trap cleanup on needs-attention (exit 7)
- `test_ref_drift_during_review_aborts` — HEAD_BR advance mid-review → exit 13 + worktree cleanup

Migrated test: `TestBranchDiffPassesPatchToCodex::test_codex_receives_patch_file_path` — contract changed from `--focus <patch>` to `--cwd <worktree>`.

## Acceptance script

`./scripts/acceptance/plan_0a_toolchain.sh` → **PLAN 0A PASS** (25 passed + 1 SKIP).

## Spec §6 non-coder checklist

1. **In main, attest `--head gov-bootstrap-hardening-4`**: unit test `test_branch_diff_reviews_target_sha_not_current_checkout` exercises this exact scenario (marker file only in target branch; stub asserts --cwd dir contains marker). Passes.

2. **Worktree cleanup**: unit tests `test_worktree_cleaned_on_success` + `test_worktree_cleaned_on_failure` + trap covers success, failure, signal, exit. Both pass.

3. **Ref drift during review**: unit test `test_ref_drift_during_review_aborts` — stub mid-review advances target branch, script detects drift post-review, exits 13, ledger not written, worktree still cleaned. Passes.

4. **Full pytest**: 109/109 green, zero regressions on hardening-3 baseline.

5. **Next bootstrap PR (hardening-5 / business modules)**: expected behavior = branch-diff attest reaches real approve without override ceremony. Verification deferred to first such PR (this PR itself is still a bootstrap, needs override because H2-3 wasn't yet merged when its branch-diff attest runs against a pre-H2-3 main — expected).

## Commits on branch `gov-bootstrap-hardening-4`

```
65451a4 feat(codex-attest): branch-diff uses git worktree + --cwd for real target review (H2-3)
b159b06 plan(gov-bootstrap-hardening-4): 3-task TDD plan for H2-3 worktree branch-diff
cba6ef7 spec(gov-bootstrap-hardening-4): H2-3 branch-diff worktree real-target review
```

## Out of scope → hardening-5+

- H3-3 shell parser heredoc stripping (regex-too-brittle; needs tree-sitter-bash / AST)
- G3 skill pipeline ordering + task-log.jsonl
- subagent-driven enforcement
- CI skill-gate drift rollup required check
- CI attest-override/ack-drift reject
- Hook integration test framework
- Homebrew Cellar allowlist generalization
