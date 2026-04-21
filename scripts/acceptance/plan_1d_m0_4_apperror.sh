#!/usr/bin/env bash
# Plan 1d 聚合验收：M0.4 AppError 契约
# 涵盖：AppError.swift + AppErrorTests.swift 存在 + swift test exit 0 + 5 keywords
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

PASS=0
FAIL=0
declare -a FAILED

run() {
  local label="$1"; shift
  echo ""
  echo "========== $label =========="
  if "$@"; then
    echo "OK: $label"
    PASS=$((PASS + 1))
  else
    echo "NG: $label"
    FAIL=$((FAIL + 1))
    FAILED+=("$label")
  fi
}

# ---- 文件存在性 ----
run "file: AppError.swift"        test -s ios/Contracts/Sources/KlineTrainerContracts/AppError.swift
run "file: AppErrorTests.swift"   test -s ios/Contracts/Tests/KlineTrainerContractsTests/AppErrorTests.swift

# ---- AppError.swift 包含 4 个 Reason + 1 个 AppError 定义 ----
run "grep: AppError enum definition" grep -q '^public enum AppError:' ios/Contracts/Sources/KlineTrainerContracts/AppError.swift
run "grep: 4 Reason enums"           bash -c "grep -c '^public enum \(Network\|Persistence\|Trade\|TrainingSet\)Reason:' ios/Contracts/Sources/KlineTrainerContracts/AppError.swift | grep -q '^4$'"
run "grep: 3 extension methods"      bash -c "grep -cE '(userMessage|isRecoverable|shouldShowToast):' ios/Contracts/Sources/KlineTrainerContracts/AppError.swift | grep -q '^3$'"

# ---- Swift 测试（exit code only 以容忍格式漂移——Plan 1c R5 教训）----
run "swift test: exit 0" \
    bash -c 'cd ios/Contracts && swift test'

# ---- 汇总 ----
echo ""
echo "============================================"
echo "Plan 1d (M0.4 AppError) acceptance: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed items:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  echo "PLAN 1d FAIL"
  exit 1
fi
echo "PLAN 1d PASS"
