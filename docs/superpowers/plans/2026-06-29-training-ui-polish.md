# 训练界面验收回归微调（顶栏空间 + 指标加粗）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` checkbox。

**Goal:** 顶栏数字去小数 + 浮动盈亏两行（盈红亏绿）+ 标签简化/收窄/齐头居中对齐；技术指标线再加粗。

**Architecture:** 纯展示层微调。`TrainingTopBarContent`（平台无关纯值，host 全测）改格式 helper + 拆 `holdingPnL` 为两字段；`TrainingView.topBar`（UIKit 守卫，build 闸门）改 metricCell 标签/宽度 + 浮动盈亏两行渲染 + 对齐 + 颜色；`KLineView+Candles`/`+MACD` 改线宽常量。零引擎/资金/持久层改动。

**Tech Stack:** Swift / SwiftUI（iOS 17 / Catalyst）；Swift Testing（Contracts host：`@Suite`/`@Test`/`#expect`）。

## Global Constraints

- 基准 = **现网代码**（main `8b7a6c2`），非 mockup。spec 权威：`docs/superpowers/specs/2026-06-29-training-ui-polish-design.md`。
- **颜色 = 红涨绿跌**：浮动盈亏 盈=**红**(`.red`) / 亏=**绿**(`.green`) / 平·空仓=中性(`.secondary`)。**绝不**西式绿盈。
- **去小数**：总资金、浮动盈亏金额、股数 = 0 位小数；**成本/股 + 浮动盈亏% = 2 位小数**。
- signed-zero 归一：`-0.0` → `+`（沿用现 `percent`/`signedCurrency` 的 `(x==0) ? 0.0 : x`）。
- FP/字符串 host 断言：选值用精确二进制浮点（整数 + .50 之类），字符串等值即可。
- **不 bump** CONTRACT_VERSION（codex plan-R5 复核）：m01 只 gate 跨系统/破坏性持久化/schema；`TrainingTopBarContent` 是 UI 纯展示值、grep 证实唯一消费者=`TrainingView` 同模块（app target/Persistence 无引用），拆字段=in-module 源级重构、零持久化影响 → 不在 gate 范围。详见 spec §6。
- **验证命令 fail-closed（codex plan-R4）**：piped 命令加 `set -o pipefail` + 检 `${PIPESTATUS[0]}`，**绝不让 `tail`/`grep` 掩盖** build/test 的非零退出；build 显式 `grep -q "BUILD SUCCEEDED" || exit 1`；测试负向断言用 `if grep 失败串; then exit 1; fi`（非 `! grep`，[[feedback_acceptance_grep_anchoring]]）。
- **本批不含** fixture（#5 已移出，见 spec §9）。提交只 add 本任务文件，**绝不** `git add -A`/`.`（工作树可能有无关 untracked）。
- 分支 `feat/training-ui-polish`（已在）。

---

## File Structure

- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift` — 格式 helper（加 `currencyInt`/`signedCurrencyInt`）+ 字段（`totalCapital` 无小数、`sharesText` 去「股」、拆 `holdingPnL`→`holdingPnLAmount`/`holdingPnLPercent`/`holdingPnLSign`）。Task 1。
- `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift` — 更新/新增断言。Task 1。
- `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` — `topBar` 的 `metricCell` 标签/宽度 + 浮动盈亏两行格 + 对齐 + 颜色。Task 2。
- `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`（MA66/BOLL）+ `KLineView+MACD.swift`（MACD）— 线宽常量。Task 3。

**依赖序**：1（纯值 + 字段，Task 2 消费）→ 2（View 接线）→ 3（线宽，独立）→ 4（验收）。

---

### Task 1: TrainingTopBarContent 格式 + 拆 holdingPnL（纯值，host 测）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift`

**Interfaces:**
- Produces（Task 2 消费）：`totalCapital`（"¥99,999,999" 无小数）、`holdingCostPerShare`（**"1,683.50" 无 ¥、2 位**，codex plan-R1 省宽防截断）、`sharesText`（"9,999,999" 无「股」后缀）、`positionShort`（"5/5" 不变）、`holdingPnLAmount`（"+¥12,345,678" 无小数带符号）、`holdingPnLPercent`（"+4,900.00%" 2 位 signed-zero）、`holdingPnLSign`（`Int`：+1 盈 / -1 亏 / 0 平·空仓）。删除旧 `holdingPnL` 单串字段。

- [ ] **Step 1: 写失败测试**

`TrainingTopBarContentTests.swift` —— 用现有 init（`TrainingTopBarContent(totalCapital:averageCost:shares:returnRate:positionTier:stockName:stockCode:currentPrice:)`）：

```swift
@Test("总资金/股数无小数；成本/股保留2位")
func intFormats() {
    let c = TrainingTopBarContent(totalCapital: 10_000_000, averageCost: 1_683.5, shares: 9_999_999,
                                  returnRate: 0, positionTier: 5, stockName: "x", stockCode: "1",
                                  currentPrice: 1_683.5)
    #expect(c.totalCapital == "¥10,000,000")        // 无小数
    #expect(c.sharesText == "9,999,999")            // 无「股」后缀
    #expect(c.holdingCostPerShare == "1,683.50")    // 2 位、去 ¥（codex plan-R1 省宽）
    #expect(c.positionShort == "5/5")
}
@Test("浮动盈亏拆两字段：盈（金额无小数 + 百分比2位）+ sign")
func pnlProfit() {
    // 现价 1683.5、成本 1.0、股数 9,999,999 → 金额≈(1682.5)×9999999、% 巨大；用可控值：
    let c = TrainingTopBarContent(totalCapital: 0, averageCost: 10, shares: 100,
                                  returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil,
                                  currentPrice: 12)   // 盈 (12-10)×100=+200；%=(2/10)=+20%
    #expect(c.holdingPnLAmount == "+¥200")           // 无小数
    #expect(c.holdingPnLPercent == "+20.00%")        // 2 位
    #expect(c.holdingPnLSign == 1)                   // 盈
}
@Test("浮动盈亏：亏（绿）+ 空仓（平·归零）")
func pnlLossAndFlat() {
    let loss = TrainingTopBarContent(totalCapital: 0, averageCost: 10, shares: 100,
                                     returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil,
                                     currentPrice: 9)    // 亏 (9-10)×100=-100；%=-10%
    #expect(loss.holdingPnLAmount == "-¥100")
    #expect(loss.holdingPnLPercent == "-10.00%")
    #expect(loss.holdingPnLSign == -1)
    let flat = TrainingTopBarContent(totalCapital: 0, averageCost: 0, shares: 0,
                                     returnRate: 0, positionTier: 0, stockName: nil, stockCode: nil,
                                     currentPrice: 0)    // 空仓
    #expect(flat.holdingPnLAmount == "+¥0")            // signed-zero 归一 +
    #expect(flat.holdingPnLPercent == "+0.00%")
    #expect(flat.holdingPnLSign == 0)                 // 平
}
```

（删/改任何引用旧 `holdingPnL` 单串字段的既有断言。）

- [ ] **Step 2: 跑确认失败**

Run: `cd "$(git rev-parse --show-toplevel)/ios/Contracts" && swift test --filter TrainingTopBarContent`
Expected: 编译失败（`holdingPnLAmount`/`holdingPnLPercent`/`holdingPnLSign` 不存在）。

- [ ] **Step 3: 实现**

> **删 `holdingPnL` 干净、不留兼容字段（codex plan-R5/R6 复核）**：`KlineTrainerContracts` 是**本地 path 依赖包**（`@ local`，非发布/分发库），monorepo = 完整消费集，grep 证唯一消费者 = `TrainingView` 同模块、无外部/跨 target 消费者。且若保留 `holdingPnL` 兼容字段，其值会随新 helper 变成**新格式**（无小数）→ 对假想外部消费者是**误导性兼容**（语义已变），比删除更糟。故干净删除。

`TrainingTopBarContent.swift` 字段区：删 `public let holdingPnL: String`，加：
```swift
    public let holdingPnLAmount: String   // "+¥12,345,678"（无小数带符号）
    public let holdingPnLPercent: String  // "+4,900.00%"（2 位 signed-zero）
    public let holdingPnLSign: Int        // +1 盈 / -1 亏 / 0 平·空仓
```
`totalCapital` 改用新整数 helper：
```swift
        self.totalCapital = Self.currencyInt(totalCapital)     // 原 Self.currency(totalCapital)
```
`sharesText` 去「股」后缀：
```swift
        self.sharesText = Self.grouped(shares)                 // 原 "\(Self.grouped(shares)) 股"
```
`positionShort`、`returnRate`、`stockNameDisplay` **不变**。`holdingCostPerShare` 改用新 `decimal2`（去 ¥、2 位）：
```swift
        self.holdingCostPerShare = Self.decimal2(averageCost)   // 原 Self.currency(averageCost)；去 ¥
```
init 里 `holdingPnL` 那段改为：
```swift
        if shares > 0 && averageCost > 0 {
            let amount = (currentPrice - averageCost) * Double(shares)
            let pct = (currentPrice - averageCost) / averageCost
            self.holdingPnLAmount = Self.signedCurrencyInt(amount)
            self.holdingPnLPercent = Self.percent(pct)
            self.holdingPnLSign = amount > 0 ? 1 : (amount < 0 ? -1 : 0)
        } else {
            self.holdingPnLAmount = Self.signedCurrencyInt(0)
            self.holdingPnLPercent = Self.percent(0)
            self.holdingPnLSign = 0
        }
```
helper 区加两个**无小数**版（仿现有 `currency`/`signedCurrency`，`maximum/minimumFractionDigits = 0`，¥ 后**无空格**）：
```swift
    /// `¥` + 千分位 + 0 位小数（无空格）。总资金用。
    private static func currencyInt(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        let body = f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
        return "¥\(body)"
    }
    /// 带符号 `+¥12,345,678` / `-¥12,345,678`（±0 归一 `+`），0 位小数无空格。浮动盈亏金额用。
    private static func signedCurrencyInt(_ value: Double) -> String {
        let v = (value == 0) ? 0.0 : value
        let sign = v >= 0 ? "+" : "-"
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.maximumFractionDigits = 0; f.minimumFractionDigits = 0
        let body = f.string(from: NSNumber(value: abs(v))) ?? String(format: "%.0f", abs(v))
        return "\(sign)¥\(body)"
    }
    /// 千分位 + 2 位小数，**无 ¥**（成本/股用，省宽防截断）。
    private static func decimal2(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.numberStyle = .decimal
        f.usesGroupingSeparator = true; f.groupingSeparator = ","
        f.decimalSeparator = "."; f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
```
（改造后 `currency`/`signedCurrency`（旧 2 位 ¥ 版）均不再被引用 → grep 确认后删除；新增 `currencyInt`/`signedCurrencyInt`/`decimal2`。）

- [ ] **Step 4: 跑确认通过**

Run: `cd "$(git rev-parse --show-toplevel)/ios/Contracts" && swift test`
Expected: 全 PASS（两框架），含上面 3 个新测试。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingTopBarContent.swift ios/Contracts/Tests/KlineTrainerContractsTests/UI/TrainingTopBarContentTests.swift
git commit -m "feat(ui): 顶栏数字去小数 + 拆 holdingPnL 为金额/百分比/sign 三字段"
```

---

### Task 2: TrainingView.topBar 接线（标签/宽度 + 浮动盈亏两行 + 对齐 + 颜色）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（`topBar` + `metricCell`，UIKit 守卫，host 不编译）

**Interfaces:**
- Consumes（Task 1）：`bar.totalCapital`/`holdingCostPerShare`/`sharesText`/`positionShort`/`holdingPnLAmount`/`holdingPnLPercent`/`holdingPnLSign`。

- [ ] **Step 1: 改 topBar 指标行**（现 `HStack(spacing: 0)` 5 个 metricCell）

把现 `topBar` 里第二行 `HStack(spacing: 0) { metricCell(...×5) }` 改为：标签简化、`alignment: .top`（标签齐头）、**方案 A 横向均匀分布**（每格 worst-case 定宽 + 格间等距 `Spacer` 摊匀剩余，PnL 不再独吞）、浮动盈亏独立两行格：
```swift
            HStack(alignment: .top, spacing: 0) {
                metricCell("总资金", bar.totalCapital, width: 80)
                Spacer(minLength: 4)
                metricCell("成本/股", bar.holdingCostPerShare, width: 56)
                Spacer(minLength: 4)
                metricCell("股数", bar.sharesText, width: 64)
                Spacer(minLength: 4)
                metricCell("仓位", bar.positionShort, width: 28)
                Spacer(minLength: 4)
                pnlCell(amount: bar.holdingPnLAmount, percent: bar.holdingPnLPercent, sign: bar.holdingPnLSign)
            }
```
（方案 A：各格 worst-case 定宽留够极限值，4 个 `Spacer` 把剩余横向空间**均匀**摊到格间隙、自适应屏宽；浮动盈亏格也定宽 `92`、**不再 `maxWidth: .infinity`**（见 Step 2）。`Spacer(minLength: 4)` 保证窄屏最小间隙、Σ定宽320+间隙 ≤ 375pt 内容宽。）

- [ ] **Step 2: 改 `metricCell`/`pnlCell` 为「标签顶 + 数值居中 + 固定有界行高」**

**关键（codex plan-R2）**：顶栏与两个 `maxHeight:.infinity` 图表 panel 同级，指标格**绝不能用 `.frame(maxHeight: .infinity)`**（会让顶栏行变贪婪、跟图表抢竖向空间）。改用**固定有界高度** `metricRowH`（够两行 PnL），格内 value 上下居中。`metricRowH` 经 build/截图验证够放「标签 9pt + 金额 12pt + 百分比 11pt」两行（约 44pt，不够则调大；这是顶栏比现状增高的来源，有界）。

在 `TrainingView` 加常量 + 两个 helper：
```swift
    private static let metricRowH: CGFloat = 44   // 顶栏指标行固定高（容标签+浮动盈亏两行）；有界=不与图表抢空间

    /// 单值指标格：标签顶部齐头 + 数值在固定行高内上下居中；各格同 metricRowH → 等高、标签齐平。
    private func metricCell(_ label: String, _ value: String, width: CGFloat?) -> some View {
        VStack(spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12).weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(width: width, height: Self.metricRowH, alignment: .top)   // 固定有界高，label 顶 / value 居中
    }

    /// 浮动盈亏格（弹性末格）：标签顶 + 金额一行 / 百分比一行；盈红亏绿平中性（红涨绿跌）。同 metricRowH 固定高。
    private func pnlCell(amount: String, percent: String, sign: Int) -> some View {
        let color: Color = sign > 0 ? .red : (sign < 0 ? .green : .secondary)
        return VStack(spacing: 1) {
            Text("浮动盈亏").font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(amount).font(.system(size: 12).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            Text(percent).font(.system(size: 11).weight(.semibold)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .frame(width: 92, height: Self.metricRowH, alignment: .top)   // 方案A：定宽留够 worst-case「+¥12,345,678」，不再 maxWidth:.infinity 吃光剩余
    }
```
（删旧 `metricCell` 的 `.frame(width:alignment:.center)` + `.frame(maxWidth: width == nil ? .infinity : nil)` 实现，用上面新版；旧弹性末格 `metricCell("浮动盈亏", bar.holdingPnL, width: nil)` 调用删除，由 `pnlCell` 取代。Step 1 的 `HStack(alignment: .top, spacing: 0)` 因各格 height 固定相同，`.top` 仍正确。）

- [ ] **Step 3: build 验证（fail-closed；host 不编译此 UIKit 文件）**

```bash
ROOT="$(git rev-parse --show-toplevel)"; PROJ="$ROOT/ios/KlineTrainer/KlineTrainer.xcodeproj"; set -o pipefail
SIM=$(xcrun simctl list devices available | grep -oE 'iPhone[^(]*\(([0-9A-F-]+)\)' | grep -oE '[0-9A-F-]{36}' | head -1)
xcodebuild build -project "$PROJ" -scheme KlineTrainer -destination "platform=iOS Simulator,id=$SIM" 2>&1 | tee /tmp/polish_t2.log | tail -5; rc=${PIPESTATUS[0]}
{ [ "$rc" -eq 0 ] && grep -q "BUILD SUCCEEDED" /tmp/polish_t2.log; } || { echo "iOS build FAILED (rc=$rc)"; exit 1; }
echo "BUILD SUCCEEDED ✅"
```
host `swift test` 仍全绿（Task 1 纯值未回归）：`cd "$ROOT/ios/Contracts" && swift test`（退出码 0）。

- [ ] **Step 4: 提交**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(ui): 顶栏标签简化/收窄 + 浮动盈亏两行(盈红亏绿) + 标签齐头数字居中对齐"
```

---

### Task 3: 技术指标线加粗

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift`（MA66:36 / BOLL:54）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift`（:27）

- [ ] **Step 1: 改线宽**

`KLineView+Candles.swift` `drawMA66`：`ctx.setLineWidth(2 / mapper.displayScale)` → `ctx.setLineWidth(3 / mapper.displayScale)`。
`KLineView+Candles.swift` `drawBOLL`：`ctx.setLineWidth(1.6 / mapper.displayScale)` → `ctx.setLineWidth(2.2 / mapper.displayScale)`。
`KLineView+MACD.swift`：`ctx.setLineWidth(1.8 / mapper.displayScale)` → `ctx.setLineWidth(2.4 / mapper.displayScale)`。
（蜡烛 `:17` 的 `1`、AxisGrid、Crosshair 线宽**不动**；BOLL dash 不动。）

- [ ] **Step 2: build 验证**

Run: 同 Task 2 Step 3 的 iOS Simulator build → `** BUILD SUCCEEDED **`。host `swift test` 全绿（线宽不影响 host 测）。

- [ ] **Step 3: 提交**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+MACD.swift
git commit -m "feat(render): 指标线加粗 MA66 2→3 / BOLL 1.6→2.2 / MACD 1.8→2.4"
```

---

### Task 4: 验收（三绿）+ 整体 review 准备

**Files:** 无生产改动（验证）。

- [ ] **Step 1: host 两框架全绿（fail-closed）**

Run（**保留原命令退出码** + 显式断言两框架全过 + 拒失败串；codex plan-R4）：
```bash
ROOT="$(git rev-parse --show-toplevel)"; set -o pipefail
cd "$ROOT/ios/Contracts" && swift test 2>&1 | tee /tmp/polish_test.log; rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "swift test 退出码 $rc ≠0"; exit 1; }
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/polish_test.log || { echo "Swift Testing 未全过"; exit 1; }
grep -q "Test Suite 'All tests' passed" /tmp/polish_test.log || { echo "XCTest 未全过"; exit 1; }
if grep -qE "with [1-9][0-9]* failure" /tmp/polish_test.log; then echo "有测试失败"; exit 1; fi
echo "两框架全绿 ✅"
```

- [ ] **Step 2: iOS Simulator build + Mac Catalyst build（fail-closed）**

```bash
ROOT="$(git rev-parse --show-toplevel)"; PROJ="$ROOT/ios/KlineTrainer/KlineTrainer.xcodeproj"; set -o pipefail
SIM=$(xcrun simctl list devices available | grep -oE 'iPhone[^(]*\(([0-9A-F-]+)\)' | grep -oE '[0-9A-F-]{36}' | head -1)
xcodebuild build -project "$PROJ" -scheme KlineTrainer -destination "platform=iOS Simulator,id=$SIM" 2>&1 | tee /tmp/polish_ios.log | tail -5; rc=${PIPESTATUS[0]}
{ [ "$rc" -eq 0 ] && grep -q "BUILD SUCCEEDED" /tmp/polish_ios.log; } || { echo "iOS build FAILED (rc=$rc)"; exit 1; }
echo "iOS BUILD SUCCEEDED ✅"
# Mac Catalyst（fail-closed：区分「destination 本机不可用=合法跳过须 CI」vs「destination 在但编译失败=真回归 exit 1」）
xcodebuild build-for-testing -project "$PROJ" -scheme KlineTrainer -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tee /tmp/polish_cat.log | tail -8
if grep -q "TEST BUILD SUCCEEDED" /tmp/polish_cat.log; then
  echo "Catalyst ✅"
elif grep -qiE "Unable to find a destination|no destinations are available|not currently available|requested but .*not available|Available destinations" /tmp/polish_cat.log; then
  echo "⚠️ Catalyst destination 本机不可用 → 本地跳过；**三绿须** CI job 'Mac Catalyst build-for-testing on macos-15' 绿（PR 阶段确认，非本地失败）"
else
  echo "❌ Catalyst destination 在但编译失败（真回归）"; exit 1
fi
```

- [ ] **Step 3: 整体 whole-branch Codex review**

Run: `.claude/scripts/codex-attest.sh --scope branch-diff --head feat/training-ui-polish --base main` → 收敛 approve。

- [ ] **Step 4: 真机/模拟器人工验收**

按 spec §8 的 5 条（顶栏去小数 / 浮动盈亏两行盈红亏绿 / 标签齐头数字居中 / 两图等高 / 指标更粗）逐条对照（真机部署见 backlog memory 命令）。**§8#1 用最坏值（总资金 1000万、股数千万、浮动盈亏千万+几十倍、成本/股 ¥9,999.99）必须附截图，证明各固定宽格无省略号截断**（minimumScaleFactor 兜底）。

---

## Self-Review

- **spec §3.1 数字格式**：Task 1（currencyInt/signedCurrencyInt + 字段）✓
- **spec §3.2 浮动盈亏两字段两行盈红亏绿**：Task 1（拆字段 + sign）+ Task 2（pnlCell 两行 + color）✓
- **spec §3.3 标签简化/收窄/对齐**：Task 2（metricCell + HStack .top + 撑满居中）✓
- **spec §3.4 高度/两图等高**：Task 2（pnlCell 撑起行高，两图 maxHeight:.infinity 自动均分，无需改 panel）✓
- **spec §4 (Part 2) 指标加粗**：Task 3 ✓
- **不 bump CONTRACT_VERSION**：无 Models 改动 ✓
- **不含 fixture**：无 DebugFixtureData 改动 ✓
- 占位扫描：无 TBD/TODO；代码完整。
- 类型一致：Task 1 产出字段名（holdingPnLAmount/Percent/Sign）与 Task 2 消费一致 ✓。
