#!/usr/bin/env bash
# run-all.sh — 1b 全部脚本测试单命令入口（pytest builder + 两个 bash 测试脚本）。
# Usage: bash tests/scripts/governance/run-all.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
rc=0
echo "### pytest: build-protection-put-payload"
python3 -m pytest tests/scripts/governance/test_build_payload.py -q || rc=1
echo "### bash: verify-required-checks"
bash tests/scripts/governance/test-verify-required-checks.sh || rc=1
echo "### bash: admin-runbook"
bash tests/scripts/governance/test-admin-runbook.sh || rc=1
if [ "$rc" -eq 0 ]; then echo "ALL GREEN"; else echo "SOME FAILED"; fi
exit $rc
