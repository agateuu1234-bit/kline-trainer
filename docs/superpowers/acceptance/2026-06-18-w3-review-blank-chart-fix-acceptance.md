# W3 修复 · 复盘(Review)模式 K 线图空白 — 非-coder 验收清单

> **本交付性质**：bug 修复。复盘(Review)模式进入后图表区**完全无 K 线**（空白）。根因：`ChartContainerView`（UIViewRepresentable）只在 `updateUIView`（`@Bindable engine` observation 变化）时用 `view.bounds` 重算 `renderState`，而 `KLineView` 无 `layoutSubviews` 自重算；静态 engine（Review：tick 冻结 / `canAdvance()==false` / 无交易）首帧 bounds 为 `.zero` 时算出 `.empty`，之后再无 observation 触发重算 → 永久空白（Replay/Normal 因 tick 推进不断重触发故有图）。
> **修复**：给 `KLineView` 加 `onBoundsChange` 回调 + `layoutSubviews`（bounds 真正变化时回调）；`ChartContainerView.Coordinator.attach` 接线该回调到 `rebuildRenderState`（用当前 engine + 真实 bounds 调 `RenderStateBuilder.make` 重算）。改 2 生产 Swift + 1 测试 Swift + 本验收 doc。
>
> 验收判据 = **范围 gate + 新回归测试红→绿（模拟器 UIKit）+ host 全量 + Catalyst build 零回归 + §5 模拟器 runbook（复盘出图，用户实测）+ codex APPROVE 落账**。
>
> **如何用**：你（非编码者）逐条把「操作命令」粘进终端回车，把屏幕输出对照「预期输出」，吻合勾 ✅，不吻合勾 ❌。每条二元判定，无需读代码。
>
> **运行前置**（终端先进工作树根，含空格须带引号）：
> ```bash
> cd "/Users/maziming/Coding/Prj_Kline trainer"
> ```

---

## 第 1 条 · 范围 gate（改动文件白名单 fail-closed）

**目的**：确认本交付只动 2 生产 Swift + 1 测试 Swift + 本验收 doc，没有碰其它模块。

**操作命令**（整段粘贴回车）：
```bash
set -euo pipefail
ALLOW='docs/superpowers/acceptance/2026-06-18-w3-review-blank-chart-fix-acceptance.md
ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift
ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift
ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewLayoutTests.swift'
changed=$(git diff --name-only origin/main...HEAD)
extra=$(comm -23 <(echo "$changed" | sort -u) <(echo "$ALLOW" | sort -u))
if [ -z "$extra" ]; then echo "GATE-PASS：仅白名单文件改动"; else echo "GATE-FAIL：越界文件："; echo "$extra"; fi
```

**预期输出**：单行 `GATE-PASS：仅白名单文件改动`。

**判定**：打印 `GATE-PASS` → ✅；出现 `GATE-FAIL` 及任意文件名 → ❌。

---

## 第 2 条 · 新回归测试红→绿（模拟器 UIKit）

**目的**：确认新测试 `renderStateRecomputedOnLayoutForStaticEngine` 在模拟器上通过——静态 engine 下，view 布局到有效尺寸后 `renderState.visibleCandles` 由空变非空（即复盘能出图）。该测试在 host `swift test` 上被 `#if canImport(UIKit)` 排除，须在模拟器跑。

**前置**：已 boot 一台 iPhone 模拟器（`xcrun simctl list devices booted` 有条目）；下方 `id=` 换成你的 booted 设备 UDID。

**操作命令**：
```bash
cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=iOS Simulator,id=DE0BA39D-C749-459D-A407-4418599B61CA' \
  -only-testing:KlineTrainerContractsTests/ChartContainerViewLayoutTests 2>&1 \
  | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"; cd - >/dev/null
```

**预期输出**：含 `Test run with 1 test in 1 suite passed` 与 `** TEST SUCCEEDED **`。

**判定**：两行均出现且无 `FAILED` → ✅；出现 `TEST FAILED` 或测试数为 0 → ❌。

---

## 第 3 条 · host 全量 + Mac Catalyst build 零回归

**目的**：确认全包 host 单测全绿（平台无关逻辑无回归）+ Mac Catalyst 测试 build 成功（治理闸门；本修复改的 UIKit 代码在此编译）。

**操作命令**（两步，逐条回车；第二步约 30–60 秒）：
```bash
cd ios/Contracts && swift test 2>&1 | grep -E "Test run with"; cd - >/dev/null
cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -1; cd - >/dev/null
```

**预期输出**：第一行 `Test run with 1085 tests in 149 suites passed`（数字 ≥ 1085，0 failures）；第二行 `** TEST BUILD SUCCEEDED **`。

**判定**：第一行含 `passed`（无 `failed`）且第二行含 `TEST BUILD SUCCEEDED` → ✅；任一含 `failed`/`FAILED`/`error` → ❌。

---

## 第 4 条 · 与既有模式零行为变化（Normal / Replay 仍正常）

**目的**：确认修复只补"静态界面布局后重算"这一路径，不改 Normal/Replay 的既有渲染（这两模式 tick 推进，本就经 `updateUIView` 重算）。靠既有 UIKit 渲染套件零回归佐证。

**操作命令**：
```bash
cd ios/Contracts && xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=iOS Simulator,id=DE0BA39D-C749-459D-A407-4418599B61CA' \
  -only-testing:KlineTrainerContractsTests/ChartContainerViewCompileTests \
  -only-testing:KlineTrainerContractsTests/KLineViewCompileTests \
  -only-testing:KlineTrainerContractsTests/RenderStateBuilderTests 2>&1 \
  | grep -E "Test run with|TEST (SUCCEEDED|FAILED)"; cd - >/dev/null
```

**预期输出**：含 `Test run with` 且 `passed`（≥ 64 tests）+ `** TEST SUCCEEDED **`（含 `coordinatorAttachesRecognizers` 识别器计数仍 5，即接线未破坏既有手势装配）。

**判定**：`passed` 且 `TEST SUCCEEDED` → ✅；任一 `FAILED` → ❌。

---

## 第 5 条 · 模拟器 runbook（复盘出图，用户实测回填）

> 本节为运行时观感验收（host 不可复现）。用户在已 seed（`KLINE_SEED_FIXTURE=1`）的模拟器逐项操作并打勾。每项 action/expected/pass-fail。

| # | 操作（action） | 预期（expected） | 判定（pass/fail） |
|---|---|---|---|
| 5.1 | 首页点任意一条历史记录 → 弹框点「复盘」 | 进入训练页，**上下两个图表区均显示 K 线蜡烛**（非空白） | ☐ |
| 5.2 | 复盘页观察按钮区 | **无**买入/卖出/结束本局按钮（Review 只读，by design 不变） | ☐ |
| 5.3 | 首页点「继续训练」进入 Normal | 图表正常显示 + 可推进 tick（既有行为不变） | ☐ |
| 5.4 | 首页历史记录 → 「再来一次」进入 Replay | 上下两图正常显示 K 线（既有行为不变） | ☐ |

---

## 第 6 条 · codex 对抗性 review APPROVE 落账（ledger）

**目的**：确认本分支 head 的 `codex:adversarial-review` 已 `approve` 并写入 ledger（治理强制 review channel）。

**操作命令**：
```bash
grep -F "w3-review-blank-chart@$(git rev-parse HEAD)" .claude/state/codex-attest-ledger.jsonl 2>/dev/null | grep -o '"verdict":"[a-z-]*"' | tail -1
```

**预期输出**：`"verdict":"approve"`。

**判定**：打印 `"verdict":"approve"` → ✅；空输出或非 approve → ❌。
（注：head 在「加入本验收 doc」后重跑 codex 落账，故 `$(git rev-parse HEAD)` 与 ledger approve 条目一致；若 ledger 路径不同，以 `codex-attest` 运行时打印的 `ledger updated` + 同一 head SHA 为准。）

---

## 残留（移交，非本交付义务）

- **#2 衍生观察（两图 pan 不联动）**：经 spec 核实属 **by design**（`plan v1.5 L109-110/204/544`：PanelViewState × 2 各自独立 offset，仅 `TickEngine.globalTickIndex` 全局同步）。"拖一个图另一个跟着滚"属 spec 未规定的新需求 → 归 UI 改版 RFC，非本 bug 修复义务。
- **fixture 指标缺失（MACD/BOLL/MA66 看不到）**：debug seed 不填指标列，属 fixture 特性（真实数据由后端预计算）→ 归"丰富 fixture"或"换真实数据"track，非本修复范围。
