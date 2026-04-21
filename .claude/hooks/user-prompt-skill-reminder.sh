#!/usr/bin/env bash
# user-prompt-skill-reminder.sh — UserPromptSubmit hook.
# Spec: docs/superpowers/specs/2026-04-20-skill-router-hook-design.md
# Plan: docs/superpowers/plans/2026-04-20-skill-router-hook-plan.md
# Stateless, fail-open. Drain stdin, emit fixed heredoc, exit 0.
set -u

cat >/dev/null 2>&1 || true

cat <<'EOF'
[skill-router] Choose the correct skill before acting. Each row below maps ONE user-intent to ONE next skill. Pick the EARLIEST applicable row. Rows are ordered SPECIFIC-TO-GENERIC so domain/context matches win over generic defaults.

# Domain/context-specific (highest priority)
  • UI / frontend code                                 → frontend-design:frontend-design
  • Session start / cross-session resume               → superpowers:using-superpowers
  • Explicit review request on existing spec/plan/PR   → codex:adversarial-review
    (NARROW: only when user says "run codex review on X" — NOT for new governance work)

# Specific triggers
  • Bug / test failure / unexpected behavior           → superpowers:systematic-debugging
  • Create / modify a skill                            → superpowers:writing-skills
  • Receive review feedback                            → superpowers:receiving-code-review
  • Self-review before merge                           → superpowers:requesting-code-review
  • Before claiming done / passing / commit / PR       → superpowers:verification-before-completion
  • Finishing a development branch                     → superpowers:finishing-a-development-branch
  • Multi-PR parallel / isolation needed               → superpowers:using-git-worktrees
  • 2+ independent investigations running in parallel  → superpowers:dispatching-parallel-agents

# Stage-specific (execute or extend existing plan)
  • Execute existing plan (independent subtasks)       → superpowers:subagent-driven-development
  • Execute existing plan (single-thread)              → superpowers:executing-plans
  • Have approved spec, need to write plan             → superpowers:writing-plans

# Generic code writing (assumes you already have an approved plan)
  • Write production code (feature / bugfix / refactor)→ superpowers:test-driven-development

# Governance class (MUST start with brainstorming, NOT codex review directly)
  • Governance / hooks / workflow rules / CLAUDE.md change → superpowers:brainstorming
    (after brainstorming + writing-plans: run codex-attest.sh for codex:adversarial-review)

# Generic brainstorming class (fallback for no-spec-yet work)
  • New feature / component / behavior change          → superpowers:brainstorming
  • No approved spec yet (general exploration)         → superpowers:brainstorming

# Exempts (most specific first)
  • Read-only query                                    → exempt(read-only-query)
  • Trivial one-step with no semantic change           → exempt(single-step-no-semantic-change)
  • Doc-only change with zero runtime effect           → exempt(behavior-neutral)
  • User explicitly told you to skip                   → exempt(user-explicit-skip)

First line of your response MUST be exactly:
  Skill gate: <skill-name>
OR:
  Skill gate: exempt(<whitelist-reason>)

Whitelist reasons (exhaustive): behavior-neutral | user-explicit-skip | read-only-query | single-step-no-semantic-change
EOF

exit 0
