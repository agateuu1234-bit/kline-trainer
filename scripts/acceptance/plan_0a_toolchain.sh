#!/usr/bin/env bash
set -uo pipefail

cd "$(dirname "$0")/../.."
PASS=0
FAIL=0

check() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $name"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Plan 0a Acceptance Test ==="
echo ""

# 1. 目录结构
check "backend/app/__init__.py exists"     test -f backend/app/__init__.py
check "backend/requirements.txt exists"    test -f backend/requirements.txt
check "backend/docker-compose.yml exists"  test -f backend/docker-compose.yml
check "backend/.env.example exists"        test -f backend/.env.example
check "ios/ directory exists"              test -d ios
check "fixtures/golden/m0/ exists"         test -d fixtures/golden/m0/source
check "scripts/acceptance/ exists"         test -d scripts/acceptance
check "tools/fixtures/ exists"             test -d tools/fixtures

# 2. GitHub + 治理
check "CODEOWNERS exists"                        test -f .github/CODEOWNERS
check "PR template exists"                       test -f .github/PULL_REQUEST_TEMPLATE.md
check "Signing rules doc exists"                 test -f docs/governance/signing-rules.md
check "Adversarial-review template exists"       test -f docs/governance/adversarial-review-template.md
check "PR template has Backend hat"              grep -q "Backend hat" .github/PULL_REQUEST_TEMPLATE.md
check "PR template has iOS hat"                  grep -q "iOS hat" .github/PULL_REQUEST_TEMPLATE.md
check "PR template has Data hat"                 grep -q "Data hat" .github/PULL_REQUEST_TEMPLATE.md

check "enforce_admins enabled" bash -c '
    curl -sfH "Authorization: Bearer ${GITHUB_TOKEN:-$(gh auth token)}" \
         https://api.github.com/repos/agateuu1234-bit/kline-trainer/branches/main/protection \
    | python3 -c "import sys,json; d=json.load(sys.stdin); assert d[\"enforce_admins\"][\"enabled\"]"
'

# 3. Xcode 工程 + 依赖锁定
check "Xcode project exists" test -d ios/KlineTrainer/KlineTrainer.xcodeproj
check "Package.resolved committed" bash -c '
    git ls-files --error-unmatch ios/KlineTrainer/KlineTrainer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null
'

# 4. Claude hook 验活
check "guard-git-push hook exists" test -f .claude/hooks/guard-git-push.sh
check "guard-git-push hook is executable" test -x .claude/hooks/guard-git-push.sh
check "settings.json references hook" grep -q "guard-git-push" .claude/settings.json

# 5. settings.json 权限闭环（gov-bootstrap 版）
check "gh api NOT in allow (gov-bootstrap sensitive)" bash -c '
    python3 -c "import json; a=json.load(open(\".claude/settings.json\"))[\"permissions\"][\"allow\"]; assert not any(x.startswith(\"Bash(gh api\") for x in a)"
'
check "codex-companion pinned path in allow" bash -c '
    python3 -c "import json; a=json.load(open(\".claude/settings.json\"))[\"permissions\"][\"allow\"]; assert any(\"codex-companion.mjs\" in x for x in a)"
'
check "push-to-main in deny list" bash -c '
    python3 -c "import json; d=json.load(open(\".claude/settings.json\"))[\"permissions\"][\"deny\"]; assert any(\"origin main\" in x for x in d)"
'

# 6. FastAPI
check "FastAPI health test passes" bash -c '
    cd backend && python3 -m pytest tests/test_health.py -q 2>&1 | grep -q "1 passed"
'

# 7. NAS preflight — opt-in via ACCEPT_WITH_NAS=1
# Default skip: repo-local acceptance should not require private NAS infrastructure.
# Clean clones, CI, and reviewers don't have backend/.env or a reachable NAS.
# Real deployment verification is a separate concern from repo acceptance.
if [ "${ACCEPT_WITH_NAS:-0}" = "1" ]; then
    check "NAS preflight passes" bash scripts/nas-preflight.sh
else
    echo "SKIP  NAS preflight (set ACCEPT_WITH_NAS=1 to include; needs backend/.env + live NAS)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "PLAN 0A PASS"
    exit 0
else
    echo ""
    echo "PLAN 0A FAIL ($FAIL items)"
    exit 1
fi
