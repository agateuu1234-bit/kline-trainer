# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

---

## Repository governance backstop (project-specific · non-overridable)

The four principles above are day-to-day coding guidelines. Even if every hook, skill, or config is broken or missing, the following project invariants still hold:

1. All PRs that touch the repository go through `codex:adversarial-review`, with the review verdict enforceable as a required GitHub status check (not self-attested).

2. Every module/phase delivery (default: 1 plan = 1 phase) MUST include a non-coder-executable acceptance checklist (action / expected / pass-fail; Chinese; forbidden phrases listed in `.claude/workflow-rules.json`).

3. Memory cleanup is destructive and REQUIRES explicit user checkpoint confirmation — never automatic.

4. Every work-advancing response from Claude MUST begin with its first line as `Skill gate: <skill-name>` or `Skill gate: exempt(<whitelist-reason>)`. Exemption reasons are restricted to the whitelist in `.claude/workflow-rules.json`. **Enforcement (since gov-bootstrap-hardening-2, 2026-04-19):** missing first line is **drift-logged** to `.claude/state/skill-gate-drift.jsonl` (not hard-blocked); out-of-whitelist exempt reason still blocks. Full hard-enforce policy is hardening-3 scope.

Governance / tooling / process changes are out of scope for the four principles above; they go through `superpowers:brainstorming` → `superpowers:writing-plans` → `codex:adversarial-review` → PR review. See `.claude/workflow-rules.json` and the SessionStart hook for the authoritative skill/trust-boundary mapping.

`codex:adversarial-review` is the ONLY Codex review channel. `codex:rescue` is an assistance tool (diagnosis / Q&A / auxiliary reasoning); it is NOT a review channel and must not be used as one.
