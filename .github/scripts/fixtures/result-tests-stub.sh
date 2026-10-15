#!/usr/bin/env bash
# 测试桩：替代 catalyst-result-tests.sh，给 fixture 日志找配对的结构化结果样本。
# 由 catalyst-gate.test.sh 经 CATALYST_RESULT_TESTS_SCRIPT 注入。⛔ 生产不用它。
#
# 配对规则（spec/plan 定）：
#   <name>.log  →  <name>.tests.json      （该档位要测结构化判据，必须有专属样本）
#   找不到      →  all-passed.tests.json  （该档位测的是别的判据，用共享样本）
#
# ⚠️ 这条回退规则有个陷阱，已由测试台的元测试钉住：
#   凡断言「UIKit-gated 测试未执行」的负向档位，共享样本会把本该缺失的节点**补回来**
#   ⇒ 正确实现反而让它通过。所以那些档位**必须**有专属 .tests.json。
#   （codex plan-R1 指出，见 plan 的 File Structure 一节。）
set -euo pipefail

LOG="${1:?usage: result-tests-stub.sh <log-path>}"
DIR="$(cd "$(dirname "$0")" && pwd)"

PAIRED="$DIR/$(basename "$LOG" .log).tests.json"
if [ -f "$PAIRED" ]; then
    exec cat "$PAIRED"
fi
exec cat "$DIR/all-passed.tests.json"
