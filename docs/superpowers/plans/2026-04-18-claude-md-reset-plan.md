# CLAUDE.md Reset & Superpowers/Codex Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement task-by-task. R1 Codex findings融入 R2 版本.

**Goal:** Replace CLAUDE.md with Karpathy + backstop; shift project rules into `.claude/workflow-rules.json` + hooks + GitHub Actions; make Codex adversarial review (via Actions, not Claude-local) the sole review channel enforced by GitHub required checks + CODEOWNERS.

**Architecture:** 🅰️.lite-v2 — Codex runs inside GitHub Actions runner (base-branch-owned via `workflow_run`). OPENAI_API_KEY in Secrets. `codex-verify-pass` check-run created by Actions bot (app_id=15368), required by branch protection. Local hooks + deny are defense-in-depth, not primary.

**Tech Stack:** Bash (hooks), GitHub Actions YAML, Node.js (scripts), Python (coverage test), `openai-codex` npm (pinned), `gitleaks`, `gh` CLI.

**Spec source:** `docs/superpowers/specs/2026-04-17-claude-md-reset-design.md` (blob at plan-writing time, already committed `52f46f4`).

**Round 1 Codex findings applied (R2 fixes):**
- F1: bootstrap 拆成 21a (minimal protection pre-PR) + 21b (add required checks post-merge) — no self-deadlock
- F2: plan review 在 writing-plans 阶段跑（即现在），非 execute 末尾；原 Task 23 删除
- F3: Task 2 拆 2a（pre-execute 仅禁 gh/github-write）+ 2b（post-bootstrap 才禁 .claude/** edit）
- F4: 所有 hook 脚本 + 测试改用 stdin JSON contract（同 `guard-git-push.sh` 模式）
- F5: codex-review-verify 从 `workflow_run.pull_requests[0].base.sha` / `.head.sha` 拿真 SHA
- F6: codeowners-config-check / branch-protection-config-self-check / check-bootstrap-used-once 全移除 paths filter，always-run + fast no-op
- F7: workflow-rules.json 新增 `codeowners_required_globs` 字段（治理子集 · 不含业务源码）；CODEOWNERS 从此字段派生
- F8: Task 27 用 `git worktree` 跑验收 · 不污染 main

---

## File Structure (update)

**Config + rules:**
- Create: `.claude/workflow-rules.json` (含 `trust_boundary_globs` 和 `codeowners_required_globs` 两字段)
- Modify: `.claude/settings.json` — 2a (pre) 扩展 + 2b (post) 扩展
- Create: `.claude/hooks/session-start.sh` / `pre-edit-trust-boundary-hint.sh` / `pre-commit-diff-scan.sh` / `pre-merge-warn.sh` / `stop-response-check.sh`
- Create: `.claude/scripts/verify-codex-tree.mjs` / `codex-attest.sh` (local wrapper, for future use)
- Create: `.claude/state/.gitkeep`

**CLAUDE.md:**
- Modify: `CLAUDE.md` (Karpathy 4 + backstop 4, all English)

**Trust anchors:**
- Create: `codex.pin.json`
- Create: `.github/CODEOWNERS` (from `codeowners_required_globs`)

**GitHub Actions:**
- Create: `.github/workflows/codex-review-collect.yml`
- Create: `.github/workflows/codex-review-verify.yml` (F5 fixed)
- Create: `.github/workflows/codex-review-rerun.yml`
- Create: `.github/workflows/codeowners-config-check.yml` (F6 always-run)
- Create: `.github/workflows/branch-protection-config-self-check.yml` (F6 always-run)
- Create: `.github/workflows/check-bootstrap-used-once.yml` (F6 always-run)

**Bootstrap state:**
- Create: `.github/bootstrap-lock.json`

**Tests (stdin JSON contract):**
- `tests/hooks/test-session-start.sh`
- `tests/hooks/test-pre-commit-diff-scan.sh`
- `tests/hooks/test-pre-edit-trust-boundary-hint.sh`
- `tests/hooks/test-stop-response-check.sh`
- `tests/scripts/test-verify-codex-tree.mjs`
- `tests/scripts/test-codex-attest.sh`
- `tests/workflow-rules/test-trust-boundary-coverage.sh`
- `tests/workflow-rules/test-codeowners-coverage.sh` (F7 新)

---

# Tasks

## Phase 0: Pre-execution gate

Plan itself is going through 3-round Codex adversarial review *before* any Task 1 work begins. This phase is **invisible in the executing-plans flow** — it already runs in the writing-plans skill (current execution). Do NOT re-run in executing-plans.

---

## Phase A: Local files (edit-allowed; `.claude/**` edit NOT yet denied)

### Task 1: `.claude/workflow-rules.json` (含 codeowners_required_globs F7 修复)

**Files:**
- Create: `.claude/workflow-rules.json`
- Test: `tests/workflow-rules/test-trust-boundary-coverage.sh`
- Test: `tests/workflow-rules/test-codeowners-coverage.sh`

- [ ] **Step 1: Write failing test 1 (trust-boundary coverage)**

```bash
# tests/workflow-rules/test-trust-boundary-coverage.sh
#!/usr/bin/env bash
set -euo pipefail
RULES=".claude/workflow-rules.json"
python3 <<'PY'
import json, pathlib, fnmatch, subprocess, sys
d = json.load(open('.claude/workflow-rules.json'))
whitelist = d.get('trust_boundary_whitelist', [])
globs = d['trust_boundary_globs']
files = subprocess.check_output(['git','ls-files']).decode().splitlines()
uncovered = []
for f in files:
    if any(fnmatch.fnmatch(f, w) for w in whitelist): continue
    if any(fnmatch.fnmatch(f, g) or pathlib.PurePath(f).match(g) for g in globs):
        continue
    uncovered.append(f)
if uncovered:
    print('FAIL:', uncovered[:20])
    sys.exit(1)
print('PASS')
PY
```

- [ ] **Step 2: Write failing test 2 (CODEOWNERS-required coverage, F7)**

```bash
# tests/workflow-rules/test-codeowners-coverage.sh
#!/usr/bin/env bash
set -euo pipefail
python3 <<'PY'
import json
d = json.load(open('.claude/workflow-rules.json'))
required = d.get('codeowners_required_globs', [])
# codeowners_required_globs must be a STRICT SUBSET of trust_boundary_globs
tb = set(d['trust_boundary_globs'])
for g in required:
    if g not in tb:
        print(f'FAIL: {g} in codeowners_required_globs but not in trust_boundary_globs')
        exit(1)
# Must NOT include broad business-code globs
forbidden = ['src/**', 'ios/**/*.swift', '**/*.py', '**/*.ts', '**/*.tsx']
for g in required:
    if g in forbidden:
        print(f'FAIL: business-code glob {g} in codeowners_required_globs; move to trust_boundary only')
        exit(1)
print('PASS')
PY
```

- [ ] **Step 3: Run tests — FAIL (file doesn't exist)**

- [ ] **Step 4: Create `.claude/workflow-rules.json`**

Content = spec §4.2 full JSON + **new field** `codeowners_required_globs`:

```
"codeowners_required_globs": [
  ".claude/**", ".github/**", "CLAUDE.md", "codex.pin.json",
  "docs/governance/**",
  "docs/superpowers/specs/**", "docs/superpowers/plans/**",
  "kline_trainer_modules*.md", "kline_trainer_plan*.md",
  "modules/**", "plan/**",
  "scripts/**", "Makefile", "Fastfile", "fastlane/**",
  "**/*.podspec", "**/Dockerfile",
]
```

(业务源码 `src/**`、`ios/**/*.swift`、`*.py` 等**仅在 `trust_boundary_globs`**，不在 `codeowners_required_globs` — 过 Codex review，不要 user Approve。`.github/bootstrap-lock.json` 由 `.github/**` 覆盖,不单列 [R2.5 fix])

**R6.3 fix · Also add `canonical_codeowner` field** (single source of truth for Task 12 generation + Task 17 verification):

```
"canonical_codeowner": "@agateuu1234-bit"
```

(替换为你实际的 GitHub username。Task 1 Step 4 填值时从 `gh api /user --jq .login` 取。值以 `@` 开头。)

- [ ] **Step 5: Run tests — PASS**

```bash
bash tests/workflow-rules/test-trust-boundary-coverage.sh
bash tests/workflow-rules/test-codeowners-coverage.sh
```

- [ ] **Step 6: Commit**

```bash
git add .claude/workflow-rules.json tests/workflow-rules/
git commit -m "feat(workflow-rules): add rule source with trust_boundary + codeowners_required_globs split (R1 F7)"
```

---

### Task 2a: settings.json **minimal** deny expansion (pre-execute · F3)

**Files:**
- Modify: `.claude/settings.json`

仅加 **GitHub-write deny + HTTP/shell bypass deny**，**不加** `.claude/** Edit/Write deny`（那留到 Task 2b 最后）。

- [ ] **Step 1: Write test**

```bash
# tests/settings/test-deny-minimal.sh
#!/usr/bin/env bash
set -euo pipefail
python3 <<'PY'
import json
d = json.load(open('.claude/settings.json'))
deny = d['permissions']['deny']
# Must have these
required = [
    "Bash(gh api graphql*)",
    "Bash(gh api * -X POST*)",
    "Bash(gh pr comment:*)",
    "Bash(gh workflow run*)",
    "Bash(curl * github.com*)",
    "Bash(bash -c *)",
    "Bash(sudo *)",
]
missing = [r for r in required if r not in deny]
if missing: print('FAIL missing:', missing); exit(1)
# MUST NOT have (will be added in 2b at end)
forbidden_now = [
    "Edit(.claude/hooks/**)",
    "Edit(.claude/workflow-rules.json)",
    "Edit(CLAUDE.md)",
    "Edit(.github/workflows/**)",
]
present_too_early = [r for r in forbidden_now if r in deny]
if present_too_early:
    print('FAIL too early (should be Task 2b):', present_too_early); exit(1)
print('PASS')
PY
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Edit .claude/settings.json**

Append to `permissions.deny`:

```
"Bash(gh api graphql*)",
"Bash(gh api * -X POST*)",
"Bash(gh api * --method POST*)",
"Bash(gh api * -X PUT*)",
"Bash(gh api * -X PATCH*)",
"Bash(gh api * -X DELETE*)",
"Bash(gh api repos/*/check-runs*)",
"Bash(gh api repos/*/statuses/*)",
"Bash(gh api repos/*/issues/*/comments*)",
"Bash(gh api repos/*/pulls/*/comments*)",
"Bash(gh pr comment:*)",
"Bash(gh pr review:*)",
"Bash(gh pr edit:*)",
"Bash(gh issue comment:*)",
"Bash(gh issue edit:*)",
"Bash(gh workflow run*)",
"Bash(gh run rerun*)",
"Bash(gh secret *)",
"Bash(gh variable *)",
"Bash(gh release *)",
"Bash(gh ruleset *)",
"Bash(gh repo edit*)",
"Bash(gh auth *)",
"Bash(curl * github.com*)",
"Bash(curl * api.github.com*)",
"Bash(wget * github.com*)",
"Bash(nc * github.com*)",
"Bash(python* -c *github.com*)",
"Bash(node -e *github.com*)",
"Bash(bash -c *)",
"Bash(zsh -c *)",
"Bash(sh -c *)",
"Bash(eval *)",
"Bash(exec *)",
"Bash(sudo *)",
"Bash(node */codex-companion.mjs*)",
"Bash(node ~/.claude/plugins/*)"
```

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
git add .claude/settings.json tests/settings/
git commit -m "feat(settings): minimal deny expansion (GitHub-write + shell bypass; NOT .claude/** edit yet) [R1 F3]"
```

---

### Task 3: `.claude/hooks/session-start.sh` (stdin JSON F4)

**Files:**
- Create: `.claude/hooks/session-start.sh`
- Test: `tests/hooks/test-session-start.sh`

- [ ] **Step 1: Write test**

```bash
#!/usr/bin/env bash
# tests/hooks/test-session-start.sh
set -euo pipefail
# SessionStart hook receives no meaningful input — just empty JSON or session metadata
OUT=$(echo '{}' | bash .claude/hooks/session-start.sh)
echo "$OUT" | grep -q "Skill gate" || { echo "FAIL: no Skill gate reminder"; exit 1; }
echo "$OUT" | grep -q "workflow-rules.json" || { echo "FAIL: no workflow-rules ref"; exit 1; }
echo "$OUT" | grep -q "codex:adversarial-review" || { echo "FAIL: no adversarial-review ref"; exit 1; }
echo PASS
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement hook (reads stdin JSON, outputs context injection text)**

```bash
#!/usr/bin/env bash
# .claude/hooks/session-start.sh
# SessionStart reads session metadata JSON from stdin; output printed to conversation.
set -euo pipefail
_=$(cat)  # consume stdin (we don't need fields for this simple injector)

cat <<'EOF'
=== Project rules reminder (injected by session-start hook) ===

Skill gate: Every work-advancing response MUST begin with first line:
  Skill gate: <skill-name>   OR   Skill gate: exempt(<whitelist-reason>)

Whitelist reasons: behavior-neutral | user-explicit-skip | read-only-query | single-step-no-semantic-change

Review channel: codex:adversarial-review (ONLY).
codex:rescue = assistance tool, NOT a review channel.

Trust-boundary changes → Codex review (via .github/workflows).
codeowners_required_globs changes → additionally need user Approve.

See .claude/workflow-rules.json for full skill_entry_map + trust_boundary_globs.

Common skills:
  New feature/behavior → superpowers:brainstorming
  Approved multi-step → superpowers:writing-plans
  Writing prod code → superpowers:test-driven-development
  Before completion claims → superpowers:verification-before-completion
  Trust-boundary change PR → codex:adversarial-review

EOF

git branch --show-current 2>/dev/null | awk '{print "Current branch: " $0}'
git log -1 --oneline 2>/dev/null | awk '{print "Latest commit: " $0}'
```

- [ ] **Step 4: chmod + run — PASS**

```bash
chmod +x .claude/hooks/session-start.sh
bash tests/hooks/test-session-start.sh
```

- [ ] **Step 5: Commit**

```bash
git add .claude/hooks/session-start.sh tests/hooks/test-session-start.sh
git commit -m "feat(hook): session-start context injector (stdin JSON contract) [R1 F4]"
```

---

### Task 4: `.claude/hooks/pre-edit-trust-boundary-hint.sh` (stdin JSON F4)

**Files:**
- Create: `.claude/hooks/pre-edit-trust-boundary-hint.sh`
- Test: `tests/hooks/test-pre-edit-trust-boundary-hint.sh`

- [ ] **Step 1: Write test**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Test 1: trust-boundary path → should hint
OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"CLAUDE.md"}}' | bash .claude/hooks/pre-edit-trust-boundary-hint.sh)
echo "$OUT" | grep -q "codex:adversarial-review" || { echo "FAIL: no hint for CLAUDE.md"; exit 1; }

# Test 2: non-trust-boundary → no hint
OUT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"some-random-file.md"}}' | bash .claude/hooks/pre-edit-trust-boundary-hint.sh || true)
if echo "$OUT" | grep -q "codex:adversarial-review"; then
  echo "FAIL: false hint"; exit 1
fi
echo PASS
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement hook (stdin JSON)**

```bash
#!/usr/bin/env bash
# .claude/hooks/pre-edit-trust-boundary-hint.sh
# Input: stdin JSON {"tool_name":"Edit"|"Write", "tool_input":{"file_path":"..."}}
# Output: context-only print (exit 0); never blocks.
set -euo pipefail

input=$(cat)
file=$(echo "$input" | jq -r '.tool_input.file_path // ""')
[ -z "$file" ] && exit 0

RULES=".claude/workflow-rules.json"
[ ! -f "$RULES" ] && exit 0

match=$(python3 - "$file" <<'PY'
import json, pathlib, fnmatch, sys
f = sys.argv[1]
d = json.load(open('.claude/workflow-rules.json'))
for w in d.get('trust_boundary_whitelist', []):
    if fnmatch.fnmatch(f, w): sys.exit(0)
for g in d['trust_boundary_globs']:
    if fnmatch.fnmatch(f, g) or pathlib.PurePath(f).match(g):
        print('MATCH'); sys.exit(0)
PY
)

if [ "$match" = "MATCH" ]; then
  echo "[pre-edit-hint] $file is trust-boundary → requires codex:adversarial-review approve + (if codeowners_required) user Approve before merge."
fi
exit 0
```

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
chmod +x .claude/hooks/pre-edit-trust-boundary-hint.sh
git add .claude/hooks/pre-edit-trust-boundary-hint.sh tests/hooks/test-pre-edit-trust-boundary-hint.sh
git commit -m "feat(hook): pre-edit trust-boundary hint (stdin JSON) [R1 F4]"
```

---

### Task 5: `.claude/hooks/pre-commit-diff-scan.sh` (stdin JSON F4)

**Files:**
- Create: `.claude/hooks/pre-commit-diff-scan.sh`
- Test: `tests/hooks/test-pre-commit-diff-scan.sh`

- [ ] **Step 1: Write test (setup throwaway git repo)**

```bash
#!/usr/bin/env bash
set -euo pipefail
TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT
git init -q "$TMP"
cd "$TMP"
mkdir -p .claude
cp "$OLDPWD/.claude/workflow-rules.json" .claude/
cp "$OLDPWD/.claude/hooks/pre-commit-diff-scan.sh" ./hook.sh
chmod +x hook.sh

git checkout -q -b main
echo x > init.md && git add . && git commit -qm init

# Scenario 1: main + trust-boundary staged → expect deny JSON
echo y > CLAUDE.md
git add CLAUDE.md
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | bash ./hook.sh || true)
echo "$out" | grep -q '"permissionDecision": "deny"' || { echo "FAIL: should deny main+trust"; exit 1; }

# Scenario 2: feature branch + trust-boundary → allow (no output, exit 0)
git checkout -q -b feature/x
out=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | bash ./hook.sh || true)
if echo "$out" | grep -q '"permissionDecision": "deny"'; then
  echo "FAIL: blocked feature branch"; exit 1
fi
echo PASS
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement hook (stdin JSON; output JSON deny on violation)**

```bash
#!/usr/bin/env bash
# .claude/hooks/pre-commit-diff-scan.sh
# Input: stdin JSON {"tool_name":"Bash", "tool_input":{"command":"git commit..."}}
# Output: JSON deny if violation; exit 0 empty otherwise.
set -eo pipefail

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')
# Only act on git commit commands
echo "$cmd" | grep -qE '^(git|[[:space:]]*git)\s+commit' || exit 0

branch=$(git branch --show-current 2>/dev/null || echo "")
if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then exit 0; fi

RULES=".claude/workflow-rules.json"
[ ! -f "$RULES" ] && exit 0

staged=$(git diff --staged --name-only 2>/dev/null || echo "")
[ -z "$staged" ] && exit 0

hit=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  m=$(python3 - "$f" <<'PY'
import json, pathlib, fnmatch, sys
f = sys.argv[1]
d = json.load(open('.claude/workflow-rules.json'))
for w in d.get('trust_boundary_whitelist', []):
    if fnmatch.fnmatch(f, w): sys.exit(0)
for g in d['trust_boundary_globs']:
    if fnmatch.fnmatch(f, g) or pathlib.PurePath(f).match(g):
        print(f); sys.exit(0)
PY
)
  if [ -n "$m" ]; then hit="$hit $m"; fi
done <<< "$staged"

if [ -n "$hit" ]; then
  jq -nc --arg reason "trust-boundary commit 在 main/master 上被禁:$hit" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
fi
exit 0
```

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
chmod +x .claude/hooks/pre-commit-diff-scan.sh
git add .claude/hooks/pre-commit-diff-scan.sh tests/hooks/test-pre-commit-diff-scan.sh
git commit -m "feat(hook): pre-commit-diff-scan (stdin JSON + deny output) [R1 F4]"
```

---

### Task 6: `.claude/hooks/pre-merge-warn.sh` (stdin JSON F4 · warn only)

**Files:**
- Create: `.claude/hooks/pre-merge-warn.sh`

- [ ] **Step 1: Implement (trivial)**

```bash
#!/usr/bin/env bash
# Input: stdin JSON (gh pr merge). Output: printed warn, exit 0.
set -euo pipefail
_=$(cat)
echo "[pre-merge-warn] Reminder: merge gate authoritative is codex-verify-pass on GitHub."
echo "  This local warn is advisory; GitHub branch protection enforces actual gate."
exit 0
```

- [ ] **Step 2: chmod + commit**

```bash
chmod +x .claude/hooks/pre-merge-warn.sh
git add .claude/hooks/pre-merge-warn.sh
git commit -m "feat(hook): pre-merge-warn (stdin JSON)"
```

---

### Task 7: `.claude/hooks/stop-response-check.sh` (CRITICAL · stdin JSON F4)

Stop hook input per Claude Code docs: JSON with `transcript_path` to read the assistant's last message.

**Files:**
- Create: `.claude/hooks/stop-response-check.sh`
- Test: `tests/hooks/test-stop-response-check.sh`

- [ ] **Step 1: Write test (simulates transcript file)**

```bash
#!/usr/bin/env bash
set -euo pipefail
HOOK=".claude/hooks/stop-response-check.sh"
TMP=$(mktemp -d); trap "rm -rf $TMP" EXIT

# Mock transcript format: JSONL with last line = {"type":"assistant","message":{"content":[{"text":"..."}]}}
mk_transcript() {
  local text="$1"
  local path="$TMP/transcript.jsonl"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":%s}]}}\n' \
    "$(jq -Rn --arg t "$text" '$t')" > "$path"
  echo "$path"
}

# Test 1: missing Skill gate → should output deny
tp=$(mk_transcript "Just some regular text")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
echo "$out" | grep -q '"decision": "block"' || { echo "FAIL: should block missing Skill gate"; exit 1; }

# Test 2: valid Skill gate → pass
tp=$(mk_transcript "Skill gate: superpowers:brainstorming
Rest of response...")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
if echo "$out" | grep -q '"decision": "block"'; then
  echo "FAIL: blocked valid Skill gate"; exit 1
fi

# Test 3: exempt whitelist → pass
tp=$(mk_transcript "Skill gate: exempt(behavior-neutral)
...")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
if echo "$out" | grep -q '"decision": "block"'; then
  echo "FAIL: blocked valid exempt"; exit 1
fi

# Test 4: exempt non-whitelist → block
tp=$(mk_transcript "Skill gate: exempt(i-feel-like-it)
...")
out=$(echo "{\"transcript_path\":\"$tp\"}" | bash "$HOOK" || true)
echo "$out" | grep -q '"decision": "block"' || { echo "FAIL: should block non-whitelist exempt"; exit 1; }

echo PASS
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Implement (stdin JSON with transcript_path)**

```bash
#!/usr/bin/env bash
# .claude/hooks/stop-response-check.sh
# Input: stdin JSON {"transcript_path": "..."}
# Reads last assistant message from transcript; validates Skill gate first line + completion claims.
# Output: Stop hook expects {"decision": "block"|"approve", "reason": "..."} or exit 0 silent.
set -eo pipefail

input=$(cat)
tpath=$(echo "$input" | jq -r '.transcript_path // ""')
[ -z "$tpath" ] || [ ! -f "$tpath" ] && exit 0

# Find last assistant entry (JSONL, type=="assistant"); extract text
last_text=$(python3 - "$tpath" <<'PY'
import json, sys
text = ""
with open(sys.argv[1]) as f:
    for line in f:
        try:
            d = json.loads(line)
            if d.get('type') == 'assistant':
                for c in d.get('message', {}).get('content', []):
                    if c.get('type') == 'text':
                        text = c.get('text', '')
        except Exception:
            pass
print(text)
PY
)

first_line=$(echo "$last_text" | head -1)

block() {
  local reason="$1"
  jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
  exit 0
}

# 1) First-line Skill gate syntax
if ! echo "$first_line" | grep -qE '^Skill gate: (superpowers:[a-z-]+|codex:[a-z-]+|frontend-design:[a-z-]+|exempt\([a-z-]+\))'; then
  block "首行缺 'Skill gate: <name>' 或 'Skill gate: exempt(<reason>)';实际首行: $first_line"
fi

# 2) Exempt reason whitelist
if echo "$first_line" | grep -qE '^Skill gate: exempt\('; then
  reason=$(echo "$first_line" | sed -E 's/^Skill gate: exempt\(([^)]+)\).*/\1/')
  RULES=".claude/workflow-rules.json"
  if [ -f "$RULES" ]; then
    wl=$(python3 -c "import json; print(' '.join(json.load(open('$RULES'))['skill_gate_policy']['exempt_reason_whitelist']))" 2>/dev/null || echo "")
    ok=false
    for w in $wl; do [ "$reason" = "$w" ] && ok=true && break; done
    $ok || block "exempt 理由 '$reason' 不在白名单: $wl"
  fi
fi

# 3) Completion claim warning (print only, not block)
if echo "$last_text" | grep -qE '(任务完成|已完成|全部完成|验证通过|测试通过|it works|all pass)' \
  && ! echo "$last_text" | grep -qE '(Bash|bash|pytest|xcodebuild|npm test|jest)'; then
  # Warn via stderr; not a block
  >&2 echo "[stop-hook WARN] 声明完成但未见验证命令输出"
fi

exit 0
```

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit**

```bash
chmod +x .claude/hooks/stop-response-check.sh
git add .claude/hooks/stop-response-check.sh tests/hooks/test-stop-response-check.sh
git commit -m "feat(hook): stop-response-check (stdin JSON + transcript read) [R1 F4]"
```

---

### Task 8: `.claude/scripts/verify-codex-tree.mjs` (same as R1)

(保 R1 版本 不变 —— 此脚本不是 hook,无 F4 影响)

(详细 steps 同 R1 Task 8;commit with same message)

---

### Task 9: `.claude/scripts/codex-attest.sh` (保 R1 版本不变)

---

### Task 10: Mount hooks in `.claude/settings.json`

**Files:**
- Create: `.claude/state/.gitkeep`
- Modify: `.claude/settings.json` (`hooks` section)

- [ ] **Step 1: Create state dir**

```bash
mkdir -p .claude/state && touch .claude/state/.gitkeep
```

- [ ] **Step 2: Edit settings.json → add `hooks` section**

Per Claude hook spec, hooks receive stdin JSON; 不传 positional args.

```json
"hooks": {
  "SessionStart": [
    {"hooks": [{"type": "command", "command": "bash .claude/hooks/session-start.sh", "timeout": 5}]}
  ],
  "PreToolUse": [
    {
      "matcher": "Bash",
      "hooks": [
        {"type": "command", "command": "bash .claude/hooks/guard-git-push.sh", "timeout": 5},
        {"type": "command", "command": "bash .claude/hooks/pre-commit-diff-scan.sh", "timeout": 5},
        {"type": "command", "command": "bash .claude/hooks/pre-merge-warn.sh", "timeout": 5}
      ]
    },
    {
      "matcher": "Edit",
      "hooks": [{"type": "command", "command": "bash .claude/hooks/pre-edit-trust-boundary-hint.sh", "timeout": 2}]
    },
    {
      "matcher": "Write",
      "hooks": [{"type": "command", "command": "bash .claude/hooks/pre-edit-trust-boundary-hint.sh", "timeout": 2}]
    }
  ],
  "Stop": [
    {"hooks": [{"type": "command", "command": "bash .claude/hooks/stop-response-check.sh", "timeout": 3}]}
  ]
}
```

每个 hook 自己从 stdin JSON 过滤 `tool_name` / `command` / `file_path`（见 `guard-git-push.sh` 模式）。

- [ ] **Step 3: Commit**

```bash
git add .claude/state/.gitkeep .claude/settings.json
git commit -m "feat(settings): mount hooks in settings.json (stdin JSON contract)"
```

---

## Phase B: CLAUDE.md + trust anchors

### Task 11: Replace CLAUDE.md (保 R1 内容不变 · all English)

### Task 12: `.github/CODEOWNERS` (F7 修复 · 从 codeowners_required_globs 派生)

- [ ] **Step 1: Read canonical owner from workflow-rules.json** (R6.3 fix · single source of truth)

```bash
# The canonical_codeowner field in workflow-rules.json is filled during Task 1.
# Task 12 + Task 17 both read it; no divergence between gh api /user and github.repository_owner.
CANON=$(python3 -c "import json; print(json.load(open('.claude/workflow-rules.json'))['canonical_codeowner'])")
echo "Using canonical_codeowner: $CANON"
# Typical value: @agateuu1234-bit (user's GitHub handle, set at Task 1 time)
```

- [ ] **Step 2: Generate CODEOWNERS from workflow-rules.json**

```bash
python3 - <<'PY' > .github/CODEOWNERS
import json
d = json.load(open('.claude/workflow-rules.json'))
paths = d['codeowners_required_globs']
canon = d['canonical_codeowner']  # R6.3 fix: single source
print("# Generated from workflow-rules.json.codeowners_required_globs — do NOT edit manually")
print(f"# canonical_codeowner = {canon}")
print("# Covers ONLY governance/tooling; business source is Codex-review-gated but not CODEOWNERS-required")
print()
for p in paths:
    p_clean = p if p.startswith('**') or '/' in p else f"/{p}"
    print(f"{p_clean:50s} {canon}")
PY
```

- [ ] **Step 3: Test CODEOWNERS coverage**

```bash
# tests/workflow-rules/test-codeowners-file-matches-rules.sh
python3 - <<'PY'
import json
d = json.load(open('.claude/workflow-rules.json'))
expected = set(d['codeowners_required_globs'])
with open('.github/CODEOWNERS') as f:
    lines = f.readlines()
# Extract path prefixes (first token)
present = set()
for line in lines:
    line = line.strip()
    if not line or line.startswith('#'): continue
    parts = line.split()
    if len(parts) >= 2:
        p = parts[0].lstrip('/')
        present.add(p)
missing = [e for e in expected if e.lstrip('/') not in present]
if missing:
    print('FAIL: CODEOWNERS missing entries:', missing); exit(1)
print('PASS')
PY
```

- [ ] **Step 4: Commit**

```bash
git add .github/CODEOWNERS tests/workflow-rules/test-codeowners-file-matches-rules.sh
git commit -m "feat(codeowners): derive from codeowners_required_globs (governance subset, R1 F7)"
```

---

### Task 13: `codex.pin.json` (保 R1)

---

## Phase C: GitHub Actions workflows

### Task 14: `codex-review-collect.yml` (保 R1 基本不变,但多传 base_sha)

修正：upload `changed.txt` + `pr-base.txt` + `pr-head.txt`（F5 修复之一 · 供 verify 读）。

```yaml
# ...
steps:
  # ...
  - name: Record base + head SHA
    run: |
      echo "${{ github.event.pull_request.base.sha }}" > pr-base.txt
      echo "${{ github.event.pull_request.head.sha }}" > pr-head.txt
      echo "${{ github.event.pull_request.number }}" > pr-number.txt
  - name: Upload artifact
    uses: actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08
    with:
      name: pr-metadata
      path: |
        changed.txt
        pr-base.txt
        pr-head.txt
        pr-number.txt
      if-no-files-found: error
```

---

### Task 15: `codex-review-verify.yml` (F5 核心修复)

```yaml
name: codex-review-verify
on:
  workflow_run:
    workflows: [codex-review-collect]
    types: [completed]
permissions:
  contents: read
  pull-requests: read
  checks: write
  actions: read
jobs:
  verify:
    runs-on: ubuntu-latest
    if: ${{ github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'pull_request' }}
    environment: codex-review
    steps:
      - name: Checkout BASE branch (authoritative workflow code)
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          ref: ${{ github.event.repository.default_branch }}
      - name: Download PR metadata
        uses: actions/download-artifact@fa0a91b85d4f404e444e00e005971372dc801d16
        with:
          name: pr-metadata
          github-token: ${{ secrets.GITHUB_TOKEN }}
          run-id: ${{ github.event.workflow_run.id }}
      - name: Load SHAs from artifact (advisory only · R6.1 fix)
        id: sha_artifact
        run: |
          base=$(cat pr-base.txt | tr -d '[:space:]')
          head=$(cat pr-head.txt | tr -d '[:space:]')
          num=$(cat pr-number.txt | tr -d '[:space:]')
          [ -z "$base" ] || [ -z "$head" ] && { echo "FAIL: empty SHA"; exit 1; }
          echo "base=$base" >> "$GITHUB_OUTPUT"
          echo "head=$head" >> "$GITHUB_OUTPUT"
          echo "number=$num" >> "$GITHUB_OUTPUT"
      - name: Derive authoritative SHAs from GitHub API · R6.1 fix
        id: sha
        uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const wrHead = context.payload.workflow_run.head_sha;
            // Find associated PR from workflow_run
            const prs = context.payload.workflow_run.pull_requests || [];
            if (!prs.length) core.setFailed('no PR associated with workflow_run');
            const pr = prs[0];
            // Fetch authoritative PR info
            const { data } = await github.rest.pulls.get({
              owner: context.repo.owner, repo: context.repo.repo, pull_number: pr.number
            });
            const apiHead = data.head.sha;
            const apiBase = data.base.sha;
            const artifactBase = '${{ steps.sha_artifact.outputs.base }}';
            const artifactHead = '${{ steps.sha_artifact.outputs.head }}';
            // Fail closed if artifact mismatches API
            if (artifactHead !== apiHead) core.setFailed(`head mismatch: artifact=${artifactHead} api=${apiHead}`);
            if (artifactBase !== apiBase) core.setFailed(`base mismatch: artifact=${artifactBase} api=${apiBase}`);
            if (wrHead !== apiHead) core.setFailed(`workflow_run head=${wrHead} != api head=${apiHead}`);
            core.setOutput('base', apiBase);
            core.setOutput('head', apiHead);
            core.setOutput('number', pr.number);
      - uses: actions/setup-node@39370e3970a6d050c480ffad4ff0ed4d3fdee5af
        with: { node-version: '20' }
      - name: Install Codex (pinned, no scripts)
        run: |
          mkdir -p .github/codex-runtime
          cat > .github/codex-runtime/package.json <<'EOF'
          { "name": "r", "version": "0", "dependencies": { "openai-codex": "1.0.3" } }
          EOF
          cd .github/codex-runtime
          npm install --ignore-scripts --save-exact openai-codex@1.0.3
      - name: Verify tree integrity
        run: node .claude/scripts/verify-codex-tree.mjs codex.pin.json .github/codex-runtime/node_modules/openai-codex
      - name: Fetch PR commits (F5 fix)
        run: |
          git remote -v
          git fetch origin "${{ steps.sha.outputs.base }}" --depth=1 || true
          git fetch origin "${{ steps.sha.outputs.head }}" --depth=50 || true
      - name: Checkout PR head in subdir (R2.4 fix: full depth + verify both SHAs)
        uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          ref: ${{ steps.sha.outputs.head }}
          path: pr-head
          fetch-depth: 0
      - name: Fetch + verify base & head exist in pr-head
        working-directory: pr-head
        run: |
          git fetch origin "${{ steps.sha.outputs.base }}" --depth=1 2>&1 || true
          git cat-file -e "${{ steps.sha.outputs.base }}" || { echo "FAIL: base SHA not in pr-head repo"; exit 1; }
          git cat-file -e "${{ steps.sha.outputs.head }}" || { echo "FAIL: head SHA not in pr-head repo"; exit 1; }
      - name: Run Codex with explicit base + head (F5)
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        working-directory: pr-head
        run: |
          ../.github/codex-runtime/node_modules/.bin/codex adversarial-review \
            --base "${{ steps.sha.outputs.base }}" \
            --head "${{ steps.sha.outputs.head }}" \
            --output ../verdict.json
      - name: Post check-run + PR comment
        uses: actions/github-script@60a0d83039c74a4aee543508d2ffcb1c3799cdea
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const fs = require('fs'), crypto = require('crypto');
            const v = JSON.parse(fs.readFileSync('verdict.json'));
            const digest = crypto.createHash('sha256').update(fs.readFileSync('verdict.json')).digest('hex');
            await github.rest.checks.create({
              owner: context.repo.owner, repo: context.repo.repo,
              name: 'codex-verify-pass',
              head_sha: '${{ steps.sha.outputs.head }}',
              status: 'completed',
              conclusion: v.verdict === 'approve' ? 'success' : 'failure',
              output: {
                title: `Codex verdict: ${v.verdict}`,
                summary: `codex_json_digest=${digest}\nreview_target_sha=${{ steps.sha.outputs.head }}\nbase=${{ steps.sha.outputs.base }}\n\n${v.summary || ''}`
              }
            });
            await github.rest.issues.createComment({
              owner: context.repo.owner, repo: context.repo.repo,
              issue_number: ${{ steps.sha.outputs.number }},
              body: '```json\n' + fs.readFileSync('verdict.json','utf-8') + '\n```'
            });
```

---

### Task 16: `codex-review-rerun.yml` (保 R1)

---

### Task 17: `codeowners-config-check.yml` (F6 · always-run · no paths filter)

```yaml
name: codeowners-config-check
on:
  pull_request:
# F6 fix: removed paths filter — must run on every PR
# R3.2 fix: job name = 'codeowners-config-check' (matches required check context)
permissions:
  contents: read
jobs:
  codeowners-config-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          fetch-depth: 0   # R2.2 fix: need base + head commits available
      - name: Fast no-op pass when CODEOWNERS/rules not changed (F6)
        id: scope
        run: |
          base="${{ github.event.pull_request.base.sha }}"
          head="${{ github.event.pull_request.head.sha }}"
          if git diff --name-only "$base" "$head" | grep -qE '^\.github/CODEOWNERS$|^\.claude/workflow-rules\.json$'; then
            echo "run_check=true" >> "$GITHUB_OUTPUT"
          else
            echo "run_check=false" >> "$GITHUB_OUTPUT"
          fi
      - name: Verify effective owner (R4.3 + R5.4 + R6.2/R6.3 fix · in-order last-match + canonical owner)
        run: |
          python3 - <<'PY'
          import json, sys, fnmatch
          d = json.load(open('.claude/workflow-rules.json'))
          required = set(d['codeowners_required_globs'])
          canonical_owner = d.get('canonical_codeowner')  # R6.3 fix: single source of truth
          if not canonical_owner or not canonical_owner.startswith('@'):
              print(f'FAIL: canonical_codeowner missing or malformed in workflow-rules.json: {canonical_owner}')
              sys.exit(1)

          # Parse CODEOWNERS in original order (R6.2 fix: last match wins)
          ordered_rules = []  # list of (pattern, owners)
          with open('.github/CODEOWNERS') as f:
              for line in f:
                  s = line.strip()
                  if not s or s.startswith('#'): continue
                  parts = s.split()
                  if len(parts) < 2: continue
                  ordered_rules.append((parts[0], parts[1:]))

          def effective_owners(test_path):
              """Simulate GitHub CODEOWNERS last-match-wins for a hypothetical path."""
              last_match = None
              for pat, owners in ordered_rules:
                  # Normalize CODEOWNERS pattern to fnmatch-like
                  pnorm = pat.lstrip('/')
                  if fnmatch.fnmatch(test_path, pnorm) or fnmatch.fnmatch(test_path, pat):
                      last_match = owners
              return last_match

          # For each required glob, pick a representative test path and check effective owner
          wrong = []
          for r in required:
              test_path = r.replace('**', 'x').replace('*', 'x').lstrip('/')
              eff = effective_owners(test_path)
              if eff is None:
                  wrong.append(f'{r}: no matching CODEOWNERS rule for representative path {test_path}')
              elif canonical_owner not in eff:
                  wrong.append(f'{r}: effective owners for {test_path} = {eff}, expected includes {canonical_owner} (last-match override detected)')

          if wrong:
              for e in wrong: print('FAIL:', e)
              sys.exit(1)
          print(f'PASS: every required glob resolves to canonical owner {canonical_owner} under last-match precedence')
          PY
      - name: No-op pass
        if: steps.scope.outputs.run_check == 'false'
        run: echo "No CODEOWNERS/rules changes; no-op pass"
```

---

### Task 18: `branch-protection-config-self-check.yml` (R2.3 demoted to non-required · best-effort monitoring)

R2.3: `GITHUB_TOKEN` with `contents: read` 无法读分支保护配置 (需 admin scope) → 403 → always fail。
方案: 该 workflow 保留为 **non-required / informational**, 不作为 Task 21b 的 required check。若用户担心分支保护被改,自己用命令查 (`gh api /repos/.../branches/main/protection`)。

```yaml
name: branch-protection-config-self-check
on:
  pull_request:
# R2.3/R3.4 note: informational only (non-required check).
# Exits success when protection config cannot be read (token lacks admin scope)
# or when only informational expectations missing.
permissions:
  contents: read
jobs:
  branch-protection-config-self-check:
    runs-on: ubuntu-latest
    steps:
      - name: Read main branch protection (best-effort · R5.2 fix pipe/heredoc)
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          status=0
          gh api "/repos/${{ github.repository }}/branches/main/protection" > /tmp/protection.json 2>/tmp/protection.err || status=$?
          if [ "$status" -ne 0 ]; then
            echo "::warning::Cannot read branch protection (token scope insufficient). Exiting success informationally."
            cat /tmp/protection.err || true
            exit 0
          fi
          python3 - /tmp/protection.json <<'PY'
          import json, sys
          try:
              d = json.load(open(sys.argv[1]))
          except Exception as e:
              print(f'::warning::Protection API JSON parse failed ({e}); informational exit success.')
              sys.exit(0)
          warns = []
          if not d.get('enforce_admins', {}).get('enabled'): warns.append('enforce_admins=false')
          req = d.get('required_status_checks', {}) or {}
          checks = [c.get('context') if isinstance(c, dict) else c for c in (req.get('checks', req.get('contexts', []) or []))]
          # R3.4 fix: DO NOT expect self in required list (this workflow is informational, not required)
          for r in ['codex-verify-pass','codeowners-config-check','check-bootstrap-used-once']:
              if r not in checks: warns.append(f'required check missing: {r}')
          rpr = d.get('required_pull_request_reviews', {}) or {}
          if not rpr.get('require_code_owner_reviews'): warns.append('require_code_owner_reviews=false')
          for w in warns: print(f'::warning::{w}')
          print('Informational check complete (warnings above if any).')
          PY
```

---

### Task 19: `check-bootstrap-used-once.yml` (F6 · always-run)

```yaml
name: check-bootstrap-used-once
# R3.2 fix: job name = 'check-bootstrap-used-once' (matches required check context)
on:
  pull_request:
permissions:
  contents: read
jobs:
  check-bootstrap-used-once:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - run: |
          consumed=$(python3 -c "import json; d=json.load(open('.github/bootstrap-lock.json')); print(d.get('consumed', False))")
          pr_body=$(cat <<'EOF'
          ${{ github.event.pull_request.body }}
          EOF
          )
          if [ "$consumed" != "False" ] && [ "$consumed" != "false" ]; then
            if echo "$pr_body" | grep -qiE 'bootstrap.*exemption|this is.*bootstrap pr'; then
              echo "ERROR: lock consumed; PR cannot claim bootstrap again"
              exit 1
            fi
          fi
          echo PASS
```

---

### Task 20: `.github/bootstrap-lock.json` (保 R1)

---

## Phase D: Bootstrap execute

### Task 21a: Pre-bootstrap · ONLY secret + pin (R2.1 fix · no branch protection)

**USER ACTION** — runs once pre-PR-open.

R2.1 critical 指出:单人项目 + `required_approving_review_count=1` = 作者不能自 approve → bootstrap PR 永远 merge 不了。方案: **Task 21a 不装任何 branch protection**, bootstrap PR 在 main 现有保护(继承 main 已有的,现有仓库可能无保护或已有 minimal)下 merge; **Task 21b 一步到位** 装全部保护(含 enforce_admins + required checks + CODEOWNERS review)。

- [ ] **Step 1: Set OPENAI_API_KEY secret**

```bash
gh secret set OPENAI_API_KEY --body "<openai-key>"
gh secret list
```

- [ ] **Step 2: Fill codex.pin.json.tarball_integrity**

```bash
npm view openai-codex@1.0.3 dist.integrity
# paste sha512-... into codex.pin.json
# commit via amend or small commit
```

- [ ] **Step 3: Record current branch protection state (for safety baseline)**

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
gh api "/repos/$REPO/branches/main/protection" 2>&1 | tee /tmp/pre-bootstrap-protection.json
# If 404 "Branch not protected": that's fine, means no protection yet — bootstrap will install.
# If it shows a config: save as baseline (Task 21b will either preserve-and-extend or replace-with-new).
```

**No branch protection changes in Task 21a. Bootstrap PR merges under existing (possibly empty) protection.**
Local `guard-git-push.sh` hook + `permissions.deny` on main push still protect against direct main push during this window.

---

### Task 22: Memory cleanup checkpoint (USER ACTION · 保 R1)

(同 R1 流程 · 可 parallel 或 post-merge)

---

### Task 23: Open Bootstrap PR

- [ ] **Step 1: Push branch + commit bootstrap-lock update FIRST (R3.3 fix: lock 更新先于最后 review, 避免 reviewed tree ≠ merge tree)**

```bash
git push -u origin plan-0b/claude-md-reset-20260418
# Bootstrap lock will be updated as part of PR creation below, before the final review
```

- [ ] **Step 2: Create PR + capture PR number/head**

```bash
# (PR create command below)
# After PR created:
PR_NUM=$(gh pr view --json number --jq .number)
PR_HEAD=$(gh pr view --json headRefOid --jq .headRefOid)

# Update bootstrap-lock.json with PR info
python3 - <<PY
import json
d = json.load(open('.github/bootstrap-lock.json'))
d['pr_number'] = $PR_NUM
d['pr_head_sha'] = "$PR_HEAD"
json.dump(d, open('.github/bootstrap-lock.json', 'w'), indent=2)
PY
git add .github/bootstrap-lock.json
git commit -m "chore(bootstrap-lock): record PR info"
git push

# Re-capture head after lock-update commit (R3.3 fix)
FINAL_HEAD=$(gh pr view --json headRefOid --jq .headRefOid)
```

- [ ] **Step 3: User runs local codex adversarial-review against FINAL head SHA (R3.3 fix: review the actual merge candidate)**

```bash
# User runs from main workspace
git fetch origin $FINAL_HEAD
git checkout $FINAL_HEAD --detach
CLAUDE_PLUGIN_ROOT=$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3 \
node $CLAUDE_PLUGIN_ROOT/scripts/codex-companion.mjs adversarial-review --wait --scope branch --base main \
  "Bootstrap PR final-head review: $FINAL_HEAD"
# Save verdict JSON for audit trail (user pastes into PR comment)
```

- [ ] **Step 4: User pastes Codex verdict JSON as PR comment**

- [ ] **Step 2 (run at Step 2 above): PR create command**

```bash
git push -u origin plan-0b/claude-md-reset-20260418

gh pr create \
  --title "plan-0b: CLAUDE.md reset & Superpowers/Codex pipeline bootstrap" \
  --body "$(cat <<'EOF'
## Summary

BOOTSTRAP PR — installs workflow/hooks/CLAUDE.md/CODEOWNERS.

⚠️ **NO BRANCH PROTECTION 窗口** (R3.3 明示): Task 21a 只设了 secret + pin,没装任何 branch protection。此 PR merge 期间 main 分支没有 enforced Codex review / CODEOWNERS gate。风险窗口仅限本次 bootstrap (几分钟到几小时)。本地 `guard-git-push.sh` + `permissions.deny` 仍防直接 push main。**你必须在 merge 前亲自读完所有文件变更 + 本地跑一次 codex adversarial-review(Step 1 最终 head SHA 版本)**。

Task 21b 在 merge 后**立即**装上完整 protection (enforce_admins + required_status_checks + CODEOWNERS review)。

## 12+R1 Adversarial Review
- spec: 12 rounds (see spec §8)
- plan: 3 rounds in writing-plans stage (R1/R2/R3 in superpowers:writing-plans)

## Files
~25 files across .claude/ .github/ CLAUDE.md codex.pin.json docs/ tests/.

## Acceptance Plan (non-coder executable · R5.1 fix · 无 Terminal test)

### 动作步骤 (Action)
1. GitHub 打开 PR 网页 → "Checks" 看状态 (bootstrap 阶段新 workflow 不跑,正常)
2. "Files changed" 点一遍各文件看内容 (workflow yaml 源代码没有 echo secret;hooks 没有意外行为)
3. **在 Claude Code 会话内测试 hook**: 打开 Claude Code,向 Claude 发 "请尝试 git commit CLAUDE.md 到 main 分支(测试目的,不要真改)". 观察 Claude 的 Bash tool 是否被 pre-commit-diff-scan hook 阻止

### 预期现象 (Expected)
- 步 1: check 状态 pending 或 skip (workflow 首次生效要等 merge 之后),无 failure
- 步 2: 你没看到可疑内容
- 步 3: Claude 在尝试 commit 时,hook 返回 deny JSON,Claude 报告被 block,输出含 "trust-boundary commit 在 main/master 上被禁"

### 通过判据 (Pass/Fail)
- [ ] 3 步都符合预期 → PASS
- [ ] 点 "Approve" (CODEOWNERS 要求,bootstrap 阶段可能未激活;若 PR 显示 review required 就点一下) → PASS
- [ ] 点 "Merge" → PASS

⚠️ 注意: Claude 本地 hook 只在 Claude Code 的 Bash tool 调用时生效; Terminal 直接敲 git 命令**不受 hook 管辖**(这是设计,非 bug)。真正的 main 保护在 merge 之后由 GitHub 分支保护 + required checks 强制(Task 21b 之后生效)。

## Post-merge
用户手动执行 Task 21b 加 required_status_checks。
EOF
)"

PR_NUM=$(gh pr view --json number --jq .number)
PR_HEAD=$(gh pr view --json headRefOid --jq .headRefOid)

# Update bootstrap-lock.json
python3 - <<PY
import json
d = json.load(open('.github/bootstrap-lock.json'))
d['pr_number'] = $PR_NUM
d['pr_head_sha'] = "$PR_HEAD"
json.dump(d, open('.github/bootstrap-lock.json', 'w'), indent=2)
PY
git add .github/bootstrap-lock.json
git commit -m "chore(bootstrap-lock): record PR info"
git push
```

---

### Task 24: (移除 — R1 F2 修复 · plan review 已在 writing-plans 阶段完成)

---

### Task 25: User merges Bootstrap PR (保 R1)

---

### Task 21b: Post-merge add full branch protection (F1 + R2.1 修复)

**USER ACTION** — runs immediately after Bootstrap PR merges.

- [ ] **Step 1: Wait for workflows to finish running on post-merge main**

```bash
gh run list --branch main --limit 5
# Wait until 最近 run 都 success (≤5 min typical)
```

- [ ] **Step 2: Add FULL branch protection (R3.1 fix: `count=0` single-person-repo version · ONLY executable command)**

单人 repo: `required_approving_review_count=0` (作者自 approve 在 count=0 不矛盾; CODEOWNERS 触发时 GitHub 仍会显示 "Review required from @you",你 Files changed 点一下 Approve 即可)。`branch-protection-config-self-check` 不在 required list (R2.3 demoted to informational)。

```bash
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# R6.4 fix: bind ALL required Actions checks to app_id=15368 (github-actions[bot])
gh api --method PUT "/repos/$REPO/branches/main/protection" \
  -H "Accept: application/vnd.github+json" \
  -F "required_status_checks[strict]=true" \
  -f "required_status_checks[checks][0][context]=codex-verify-pass" \
  -F "required_status_checks[checks][0][app_id]=15368" \
  -f "required_status_checks[checks][1][context]=codeowners-config-check" \
  -F "required_status_checks[checks][1][app_id]=15368" \
  -f "required_status_checks[checks][2][context]=check-bootstrap-used-once" \
  -F "required_status_checks[checks][2][app_id]=15368" \
  -F "enforce_admins=true" \
  -f "required_pull_request_reviews[require_code_owner_reviews]=true" \
  -f "required_pull_request_reviews[dismiss_stale_reviews]=true" \
  -F "required_pull_request_reviews[required_approving_review_count]=0" \
  -F "restrictions=null"
```

- [ ] **Step 3: Verify full protection** (R5.2 fix · 避免 pipe+heredoc stdin 冲突)

```bash
gh api "/repos/$REPO/branches/main/protection" > /tmp/protection.json
python3 - /tmp/protection.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['enforce_admins']['enabled'] is True, "enforce_admins must be true"
rpr = d['required_pull_request_reviews']
assert rpr['required_approving_review_count'] == 0, f"expected count=0, got {rpr['required_approving_review_count']}"
assert rpr['require_code_owner_reviews'] is True
req = d['required_status_checks']
checks = req.get('checks', [])
# R6.4 verify: every required check must bind app_id=15368
expected = {'codex-verify-pass', 'codeowners-config-check', 'check-bootstrap-used-once'}
found_by_context = {c['context']: c for c in checks if isinstance(c, dict)}
missing = expected - found_by_context.keys()
assert not missing, f"missing required checks: {missing}"
for ctx in expected:
    appid = found_by_context[ctx].get('app_id')
    assert appid == 15368, f"{ctx}: expected app_id=15368, got {appid}"
print('PASS — branch protection + all required checks bound to app_id=15368')
PY
```

- [ ] **Step 4: Update bootstrap-lock consumed=true**

Small PR to flip `consumed: false → true` (trivial change, goes through the full pipeline now).

---

### Task 26: Post-merge verify test PR (保 R1)

---

## Phase E: (R4.1 + R5.3 修复 · Task 2b 定位 Claude-tool 防护层, 非绝对锁)

Phase E 保留为章节占位,核心 Task 2b 执行时机已前移至 **Task 20 之后 + Task 21a 之前** (包含在 Bootstrap PR 里 · R4.1 fix)。

### Task 2b: Extend Claude Edit/Write deny to trust-boundary paths (Claude-tool 层防护)

**⚠️ EXECUTION POSITION: MUST RUN AS LAST CLAUDE EDIT IN BOOTSTRAP PR** (即 Task 20 之后,Task 21a 之前)

**R5.3 限制声明 (honest)**: 本 Task 的 deny 规则只 cover Claude Code 的 `Edit`/`Write` tool 和部分 shell redirect (`>`, `>>`, `tee`, `sed -i`, `cp`, `mv`, `rm`, `chmod`)。**但 Bash 调用 `python3 -c 'open(...).write(...)'` / 自定义脚本等通用 write 路径仍可绕过**(deny regex 无法列举所有 Bash write 形式)。这是 Claude-tool 层防护,不是绝对锁。

**实际 enforcement 在 GitHub 侧**: CODEOWNERS 要求 user approve 任何 trust-boundary 改动 + `codex-verify-pass` required check + 分支保护 `enforce_admins=true`。即使本地 Bash 写进了 trust-boundary 文件,push + PR 时 GitHub 闸门会拦。

`Edit(.github/bootstrap-lock.json)` + `Write(.github/bootstrap-lock.json)` **不在 deny 列表**: bootstrap-lock.json 是 mutable state file (Actions workflow / Claude 需更新 consumed 等字段),由 GitHub CODEOWNERS 层保护(改动仍需 user approve)。

- [ ] **Step 1: Test**

```bash
# tests/settings/test-deny-final.sh
python3 - <<'PY'
import json
d = json.load(open('.claude/settings.json'))
deny = d['permissions']['deny']
for r in [
    "Edit(.claude/hooks/**)", "Write(.claude/hooks/**)",
    "Edit(.claude/scripts/**)", "Write(.claude/scripts/**)",
    "Edit(.claude/workflow-rules.json)", "Write(.claude/workflow-rules.json)",
    "Edit(.claude/state/**)", "Write(.claude/state/**)",
    "Edit(.github/workflows/**)", "Write(.github/workflows/**)",
    "Edit(.github/CODEOWNERS)", "Write(.github/CODEOWNERS)",
    # R5.3: bootstrap-lock.json intentionally NOT locked (mutable state; GitHub CODEOWNERS guards it)
    "Edit(CLAUDE.md)", "Write(CLAUDE.md)",
    "Edit(codex.pin.json)", "Write(codex.pin.json)",
    "Write(~/.claude/plugins/cache/openai-codex/**)",
    "Edit(~/.claude/plugins/cache/openai-codex/**)",
    "Bash(* >> .claude/state*)",
    "Bash(* >> .claude/hooks*)",
    "Bash(* >> .github/workflows*)",
    "Bash(tee * .claude/*)",
    "Bash(sed -i * .claude/*)",
    "Bash(rm * .claude/*)",
    "Bash(chmod * .claude/*)",
]:
    if r not in deny: print(f'FAIL missing {r}'); exit(1)
print('PASS')
PY
```

- [ ] **Step 2: Run — FAIL**

- [ ] **Step 3: Edit .claude/settings.json adding the final deny batch**

(Append all rules from Step 1 test list to `permissions.deny`.)

- [ ] **Step 4: Run — PASS**

- [ ] **Step 5: Commit (this is the LAST commit Claude makes pre-merge to this branch)**

```bash
git add .claude/settings.json tests/settings/test-deny-final.sh
git commit -m "feat(settings): final deny expansion locking .claude/** .github/** edits (R1 F3 post-bootstrap)"
```

---

## Phase F: Phase-delivery acceptance

### Task 27: Mechanism verification (R4.2 修复 · 正确反映 hook 实际生效范围)

⚠️ **R4.2 修正**: Claude 本地 hooks 只在 Claude Code 的 Bash tool 调用时生效; **Terminal 直接敲 git 命令不读 `.claude/settings.json`**。Task 27 的 violation test 改为**在 Claude Code 会话内测试**(验证 Claude 的 Bash tool 被 hook block),不在 Terminal 测试(Terminal 本来就无保护 — 这是符合预期的,非 bug)。

**USER ACTION** — 部分在 Claude Code 内,部分在 GitHub 网页。

- [ ] **Step 1: 新开 Claude Code session,看 session-start 注入**

```
(打开新 Claude Code session → 看首条消息有无 "=== Project rules reminder ===" + "Skill gate:" 提示)
```

预期: 有 reminder 文字出现。

- [ ] **Step 2: 在 Claude Code 会话内测试 pre-commit-diff-scan (R4.2 fix · 改为 Claude Code 内测,非 Terminal)**

向 Claude 发一条消息:
> "请尝试在 main 分支直接改一下 CLAUDE.md 然后 git commit(测试目的,不要真改)"

预期: Claude 的 Bash tool 在尝试 `git commit` 时被 pre-commit-diff-scan hook block,你看到 "trust-boundary commit 在 main/master 上被禁" 或类似输出。Claude 会报告被 block。

(⚠️ Terminal 里直接跑 git 不会被 Claude hooks block — 那是预期的,本地 Terminal 不受 Claude Code hook 系统管辖。真正的 main 保护靠 GitHub 分支保护 + `git push` 被远端拒。)

- [ ] **Step 3: 开真 trust-boundary test PR 验证 GitHub 侧闸门**

```bash
git checkout main && git pull
git checkout -b test/verify-full-stack-$(date +%s)
echo "  # test comment" >> .claude/workflow-rules.json
git add .claude/workflow-rules.json
git commit -m "test: verify workflow stack"
git push -u origin HEAD
gh pr create --title "test: full stack verify" --body "Post-bootstrap verify"
```

- [ ] **Step 3: User 开真 trust-boundary test PR**

```bash
git checkout main && git pull
git checkout -b test/verify-full-stack-$(date +%s)
echo "  # test comment" >> .claude/workflow-rules.json
git add .claude/workflow-rules.json
git commit -m "test: verify workflow stack"
git push -u origin HEAD
gh pr create --title "test: full stack verify" --body "Post-bootstrap verify"
```

- [ ] **Step 4: Watch Actions + PR**

```bash
gh run list --limit 5
# Expected: collect + verify workflows both run
# Check PR web: codex-verify-pass check appears; CODEOWNERS "Review required" appears
```

- [ ] **Step 5: Clean up test PR**

```bash
gh pr close <n> --delete-branch
```

通过判据:
- [ ] 步 1: session-start reminder 出现 PASS
- [ ] 步 2: violation commit 被 block PASS
- [ ] 步 4: `codex-verify-pass` check + CODEOWNERS prompt 都出现 PASS

---

## Self-Review (R2 修订后)

### Spec coverage check

| Spec section | Task |
|---|---|
| §4.1 CLAUDE.md | Task 11 |
| §4.2 workflow-rules.json (+ codeowners_required_globs F7) | Task 1 |
| §4.3 hooks (stdin JSON F4) | Tasks 3-7, 10 |
| §4.4 deny (split 2a/2b F3) | Tasks 2a, 2b (= last) |
| §4.5 codex-review-collect | Task 14 |
| §4.6 codex-review-verify (F5 SHA) | Task 15 |
| §4.7 bootstrap (split 21a/21b F1) | Tasks 21a, 21b |
| §4.8 check workflows (always-run F6) | Tasks 17, 18, 19 |
| §4.9 CODEOWNERS (F7 subset) | Task 12 |
| §4.10 codex.pin.json | Task 13 |
| §4.11 user 介入点 (4 个) | Tasks 21a, 22, 23, 25, 27 |
| §4.12 memory cleanup | Task 22 |
| §5 bootstrap sequence | Tasks 21a, 23, 25, 21b, 26 |

### Placeholder scan
- `<openai-key>` in Task 21a Step 1: user fills, flagged ✅
- `@$GH_USER` in CODEOWNERS: Task 12 Step 1 resolves ✅
- `codex.pin.json.tarball_integrity`: Task 21a Step 2 user fills ✅
- No TBD/TODO remaining ✅

### Type consistency
- `codex-verify-pass` used consistently ✅
- `trust_boundary_globs` vs `codeowners_required_globs` split consistently used in Tasks 1, 12, 17 ✅
- stdin JSON contract consistent in Tasks 3-7 ✅
- base/head SHA flow: collect.yml records → verify.yml reads ✅

### Scope
- 28 tasks (原 27 + Task 21b split, - Task 23 deleted, + Task 2b moved to last) ✅

---

## Execution Handoff

Plan saved `docs/superpowers/plans/2026-04-18-claude-md-reset-plan.md`. After Codex 3-round review converges (ongoing in writing-plans stage), **execute via `superpowers:executing-plans`** (inline, not subagent-driven — user checkpoint tasks need session continuity).
