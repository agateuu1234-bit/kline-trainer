#!/usr/bin/env bash
# session-start.sh — injected into every Claude session
# Input: stdin JSON session metadata (not used)
# Output: context injection text printed to conversation
set -euo pipefail
_=$(cat)  # consume stdin (session metadata not needed for static reminder)

cat <<'EOF'
=== Project rules reminder (injected by session-start hook) ===

Skill gate: Every work-advancing response MUST begin with first line:
  Skill gate: <skill-name>   OR   Skill gate: exempt(<whitelist-reason>)

Whitelist reasons: behavior-neutral | user-explicit-skip | read-only-query | single-step-no-semantic-change

Review channel: codex:adversarial-review (ONLY).
codex:rescue = assistance tool, NOT a review channel.

Trust-boundary changes -> Codex review (via .github/workflows).
codeowners_required_globs changes -> additionally need user Approve.

See .claude/workflow-rules.json for full skill_entry_map + trust_boundary_globs.

Common skills:
  New feature/behavior -> superpowers:brainstorming
  Approved multi-step -> superpowers:writing-plans
  Writing prod code -> superpowers:test-driven-development
  Before completion claims -> superpowers:verification-before-completion
  Trust-boundary change PR -> codex:adversarial-review

EOF

git branch --show-current 2>/dev/null | awk '{print "Current branch: " $0}'
git log -1 --oneline 2>/dev/null | awk '{print "Latest commit: " $0}'
