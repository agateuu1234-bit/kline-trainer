#!/usr/bin/env bash
# 取数：把 xcodebuild 的结构化结果包转成 JSON 吐到 stdout。**只取数，不做任何判断。**
#
# 为什么要单独一个脚本而不是写在闸门里（2026-10-06 spec §3）：
#   闸门的单元测试需要喂**构造的**结果数据，而真 .xcresult 是二进制目录、不能签进 git。
#   把取数独立出来，测试就能用 CATALYST_RESULT_TESTS_SCRIPT 换掉它、喂 fixture JSON。
#   这是本仓既有的注入模式（见 catalyst-gate.sh 的 UIKIT_EXPECTED_TESTS_SCRIPT）。
#
# 契约（闸门与测试桩都依赖它，改之前先看 catalyst-gate.test.sh）：
#   用法:   catalyst-result-tests.sh <log-path>
#   stdout: 结构化结果 JSON（形如 {"testNodes":[...]}，Test Case 节点带 name/result）
#   退出码: 0 = 取到；非 0 = 取不到（闸门据此 fail-closed，⛔ 不许吞掉）
#   ⚠️ <log-path> 本脚本**不使用** —— 它在契约里是给测试桩用的（桩据此找配对 fixture）。
#      这里保留参数位是为了让两者可互换；⛔ 别因为"没用到"就把它删掉。
set -euo pipefail

BUNDLE="${CATALYST_RESULT_BUNDLE:-/tmp/catalyst.xcresult}"

if [ ! -d "$BUNDLE" ]; then
    echo "结果包不存在: $BUNDLE" >&2
    exit 1
fi

# ⛔ 不检查 xcresulttool 的版本号：CI（Xcode 16.4）报 "format version 3.53"、
# 本机（Xcode 27）报 "schema version 0.4.0" —— 两边格式本就不同，任何
# 「版本 >= X」的写法都会在某一侧失效。2026-10-07 CI 探针实测两边**输出结构逐项相同**
# （顶层键 / 7 个字段名 / 中文名完好），所以只依赖**字段是否存在**，由闸门去判。
exec xcrun xcresulttool get test-results tests --path "$BUNDLE" --format json
