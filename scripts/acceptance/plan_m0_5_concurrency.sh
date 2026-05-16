#!/usr/bin/env bash
# Plan M0.5 聚合验收：Concurrency Contract
# 设计原则（继承 Plan 1f R6）：
# - 每 anchor 独立断言，删任一 anchor 能独立 FAIL
# - 不 nested 其他 plan 的 acceptance 脚本（避免 transient TODO state 干扰）
# - 不验证生产代码 conformance（由各模块 contract test 自带）
# - 不修改任何 Swift / Python / SQL 文件，纯 doc grep
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

DOC=docs/governance/m05-concurrency-contract.md
M01=docs/governance/m01-schema-versioning-contract.md
M04=docs/governance/m04-apperror-translation-gate.md

# ---- 文件存在性（3 项）----
run "file: m05 contract doc"        test -s "$DOC"
run "file: m01 sibling doc"         test -s "$M01"
run "file: m04 sibling doc"         test -s "$M04"

# ---- H2 章节完整性（12 个 ## 顶级标题）----
run "structure: 12 H2 sections"     bash -c "grep -c '^## ' $DOC | grep -q '^12$'"

# ---- @MainActor 必须清单：5 类 + 3 SwiftUI/UIKit 默认 + 1 UIView overlay（9 项）----
# R5 fix：所有 anchor 收紧为 row-scoped (table row 起始 | 模块 |) 或 same-line rule，避免删行后名字在 Status 块 / scope 表余 mention 误 pass
run "mainactor: E5 TrainingEngine row"          grep -qE '^\| E5 \|.*TrainingEngine' "$DOC"
run "mainactor: E6 TrainingSessionCoordinator row" grep -qE '^\| E6 \|.*TrainingSessionCoordinator' "$DOC"
run "mainactor: F2 ThemeController row"         grep -qE '^\| F2 \|.*ThemeController' "$DOC"
run "mainactor: P6 SettingsStore row"           grep -qE '^\| P6 \|.*SettingsStore' "$DOC"
run "mainactor: C6 DrawingToolManager row"      grep -qE '^\| C6 \|.*DrawingToolManager' "$DOC"
run "mainactor: SwiftUI.View default"           grep -qE 'SwiftUI\.View.*默认.*@MainActor' "$DOC"
run "mainactor: UIViewRepresentable default"    grep -qE 'UIViewRepresentable.*默认.*@MainActor' "$DOC"
run "mainactor: UIGestureRecognizerDelegate"    grep -qE 'UIGestureRecognizerDelegate.*默认.*@MainActor' "$DOC"
run "mainactor: UIView overlay (C1c)"           grep -qE 'UIView.*子类.*UIKit overlay.*@MainActor|UIView.*子类.*@MainActor.*UIKit overlay' "$DOC"

# ---- actor 与后台执行（3 项，R3 fix：P3/P4 拆为独立 anchor，编辑只删 P4 一半也能独立 FAIL）----
run "actor: NetworkExecutor only"   grep -q 'actor NetworkExecutor' "$DOC"
# P3/P4 各独立 anchor：要求"含 P3" 与 "含 不使用 actor" 在同一行；§应用范围里的 P3a/P3b 行不含 "不使用 actor"，不会误命中
run "actor: P3 not actor"           bash -c "grep 'P3' \"$DOC\" | grep -q '不使用 actor'"
run "actor: P4 not actor"           bash -c "grep 'P4' \"$DOC\" | grep -q '不使用 actor'"

# ---- 返回主线程合法写法（1 项）----
run "return-to-main: MainActor.run" grep -q 'MainActor.run' "$DOC"

# ---- Sendable 清单（17 项 row-scoped anchor，R5 fix：所有 anchor 收紧到 same-line / row 起始模式）----
run "sendable: M0.3 值类型"          grep -qE 'M0\.3 全部值类型.*Sendable|M0\.3 全值类型.*Sendable' "$DOC"
# AppError + 4 Reason：anchor 到 §Sendable #2 bullet 行 "- `XxxReason: Error, Equatable, Sendable`"
run "sendable: AppError row"         grep -qE '^- \`AppError: Error, Equatable, Sendable\`' "$DOC"
run "sendable: NetworkReason row"    grep -qE '^- \`NetworkReason: Error, Equatable, Sendable\`' "$DOC"
run "sendable: PersistenceReason row" grep -qE '^- \`PersistenceReason: Error, Equatable, Sendable\`' "$DOC"
run "sendable: TradeReason row"      grep -qE '^- \`TradeReason: Error, Equatable, Sendable\`' "$DOC"
run "sendable: TrainingSetReason row" grep -qE '^- \`TrainingSetReason: Error, Equatable, Sendable\`' "$DOC"
# 6 个跨 actor 协议：anchor 到 §Sendable #3 table 行起始 "| `Proto` |" — 删该行（contract regress）必然 fail
run "sendable: APIClient row"                  grep -qE '^\| \`APIClient\` \|' "$DOC"
run "sendable: TrainingSetReader row"          grep -qE '^\| \`TrainingSetReader\`' "$DOC"
run "sendable: RecordRepository row"           grep -qE '^\| \`RecordRepository\` \|' "$DOC"
run "sendable: PendingTrainingRepository row"  grep -qE '^\| \`PendingTrainingRepository\` \|' "$DOC"
run "sendable: SettingsDAO row"                grep -qE '^\| \`SettingsDAO\` \|' "$DOC"
run "sendable: AcceptanceJournalDAO row"       grep -qE '^\| \`AcceptanceJournalDAO\` \|' "$DOC"
# 4 个 P2 内部端口：同一行 enumerate 在 P2 row，anchor 要求 P2 4 内部端口 + 端口名共现
run "sendable: P2 ZipIntegrityVerifying row"      grep -qE 'P2 4 内部端口.*ZipIntegrityVerifying' "$DOC"
run "sendable: P2 ZipExtracting row"              grep -qE 'P2 4 内部端口.*ZipExtracting' "$DOC"
run "sendable: P2 TrainingSetDataVerifying row"   grep -qE 'P2 4 内部端口.*TrainingSetDataVerifying' "$DOC"
run "sendable: P2 DownloadAcceptanceCleaning row" grep -qE 'P2 4 内部端口.*DownloadAcceptanceCleaning' "$DOC"
# @Observable 非 Sendable：anchor 到 §Sendable #4 single-line rule
run "sendable: @Observable final class 非 Sendable" grep -qE '@Observable final class.*默认.*非.*Sendable|@Observable final class.*非 Sendable' "$DOC"

# ---- GRDB DatabaseQueue 约定（3 项 row-scoped，R5 fix：所有断言 same-line 同 row 锚）----
# P3 row: "| P3 TrainingSetDB | 每个训练组 \`.zip\` 对应一个独立 \`DatabaseQueue\`..."
run "grdb: P3 per-zip queue row"    grep -qE '^\| P3 TrainingSetDB \|.*每个训练组.*DatabaseQueue' "$DOC"
# P4 row: "| P4 AppDB | 单一 \`DatabaseQueue\` for \`app.sqlite\`..."
run "grdb: P4 single queue row"     grep -qE '^\| P4 AppDB \|.*单一.*DatabaseQueue' "$DOC"
# Pool 已删除规则 same-line：要求 "pool" + ("删除"|"过早优化") 共现
run "grdb: pool deleted same-line"  bash -c "grep -E 'pool' \"$DOC\" | grep -qE '删除|过早优化'"

# ---- 文件系统原子写（1 项 same-line）----
# P5 atomic rule same-line: "**P5 \`CacheManager.store()\`**：采用**临时文件 + rename** 原子化..."
run "fs: P5 atomic rename same-line" grep -qE 'P5.*CacheManager\.store.*临时文件.*rename|P5.*临时文件.*rename.*CacheManager' "$DOC"

# ---- 禁止清单（6 项独立断言，R4 fix：anchor 到 `^N. ❌` 编号列表项，避免 #3/#5 兜底在 §文件系统 / §交叉引用 处过）----
run "ban #1: 后台改 @Observable"     grep -qE '^1\. ❌.*后台.*@Observable' "$DOC"
run "ban #2: 并发写同 SQLite"        grep -qE '^2\. ❌.*Task.*并发.*SQLite|^2\. ❌.*并发.*Task.*SQLite' "$DOC"
run "ban #3: 并发 store 同路径"      grep -qE '^3\. ❌.*CacheManager.*同一目标路径' "$DOC"
run "ban #4: CADisplayLink 重活"     grep -qE '^4\. ❌.*CADisplayLink.*重量级' "$DOC"
run "ban #5: 私有错误类型跨模块"     grep -qE '^5\. ❌.*跨模块.*私有错误类型|^5\. ❌.*私有错误类型' "$DOC"
run "ban #6: 跨 actor 捕获非 Sendable" grep -qE '^6\. ❌.*跨 actor 捕获.*非 Sendable' "$DOC"

# ---- 跨 actor 捕获 + assumeIsolated（2 项）----
run "assumeIsolated: 提及"           grep -q 'MainActor.assumeIsolated' "$DOC"
run "assumeIsolated: 前置条件 main-thread" bash -c "grep -q 'assumeIsolated' $DOC && grep -qE 'main.*thread|main 线程' $DOC"

# ---- 应用范围表（13 项 ✅ 强制行；R2 fix：原 5 项漏 P2/P3a/P3b/P5/P6/E6/C6 行；R3 fix：F1 Models 改为 ✅ 加入断言）----
# 设计（codex R1 fix）：原 awk '/^## 应用范围/,/^## /' 把起始模式当结束模式 → 立刻退出仅输出 header 行，
# 后续 grep 全 false-fail。改为"行内同时含模块标识 + ✅"——这 13 个模块标识在文档内只出现在应用范围 / 已落地表，
# 而那两表只有应用范围表带 ✅ 列，2 行 grep pipe 不需要章节切片。
run "scope: F1 ✅ required"          bash -c "grep 'F1 Models' \"$DOC\" | grep -q '✅'"
run "scope: F2 ✅ required"          bash -c "grep 'F2 ThemeController' \"$DOC\" | grep -q '✅'"
run "scope: P1 ✅ required"          bash -c "grep 'P1 APIClient' \"$DOC\" | grep -q '✅'"
run "scope: P2 ✅ required"          bash -c "grep 'P2 DownloadAcceptanceRunner' \"$DOC\" | grep -q '✅'"
run "scope: P3a ✅ required"         bash -c "grep 'P3a TrainingSetDBFactory' \"$DOC\" | grep -q '✅'"
run "scope: P3b ✅ required"         bash -c "grep 'P3b TrainingSetReader' \"$DOC\" | grep -q '✅'"
run "scope: P4 ✅ required"          bash -c "grep 'P4 AppDB' \"$DOC\" | grep -q '✅'"
run "scope: P5 ✅ required"          bash -c "grep 'P5 CacheManager' \"$DOC\" | grep -q '✅'"
run "scope: P6 ✅ required"          bash -c "grep 'P6 SettingsStore' \"$DOC\" | grep -q '✅'"
run "scope: E5 ✅ required"          bash -c "grep 'E5 TrainingEngine' \"$DOC\" | grep -q '✅'"
run "scope: E6 ✅ required"          bash -c "grep 'E6 TrainingSessionCoordinator' \"$DOC\" | grep -q '✅'"
run "scope: C1c ✅ required"         bash -c "grep 'C1c Render' \"$DOC\" | grep -q '✅'"
run "scope: C6 ✅ required"          bash -c "grep 'C6 DrawingToolManager' \"$DOC\" | grep -q '✅'"

# ---- spec 源行号 anchor（4 项）----
run "spec-anchor: §M0.5 L655-702"   grep -q 'L655-702' "$DOC"
run "spec-anchor: M0.3 Sendable L397" grep -q 'L397' "$DOC"
run "spec-anchor: @MainActor lines"  grep -qE 'L820|L1571|L1625|L1973|L1315' "$DOC"
run "spec-anchor: @MainActor consolidated L2187" grep -q 'L2187' "$DOC"
run "spec-anchor: Wave 0 L2101"      grep -q 'L2101' "$DOC"

# ---- 交叉引用（2 项）----
run "cross-ref: m01"                grep -q 'm01-schema-versioning-contract' "$DOC"
run "cross-ref: m04"                grep -q 'm04-apperror-translation-gate' "$DOC"

# ---- 未来强制点 backlog（3 项）----
run "backlog: CI Threading Sanitizer" grep -qE 'CI Threading.*Sanitizer|Thread Sanitizer' "$DOC"
run "backlog: Swift 6 strict"        grep -qE 'Swift 6.*strict|strict.*concurrency' "$DOC"
run "backlog: Sendable audit script" grep -qE 'Sendable.*audit|audit.*Sendable' "$DOC"

# ---- 汇总 ----
TOTAL=$((PASS + FAIL))
echo ""
echo "================================================================"
echo "Plan M0.5 acceptance: $PASS / $TOTAL pass, $FAIL fail"
if [ $FAIL -gt 0 ]; then
  echo "Failed:"
  for f in "${FAILED[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "================================================================"
exit 0
