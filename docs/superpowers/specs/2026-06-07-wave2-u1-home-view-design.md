# U1 HomeView 设计（Wave 2 顺位 8 · view-only shell）

**日期**：2026-06-07
**Anchor**：Wave 2 顺位 8 = U1 HomeView（`docs/superpowers/specs/2026-06-02-wave2-outline-design.md` §二）
**前置依赖（均已 merged）**：E6a（#83）+ E6b（#86）+ P2（#82）；参考 shell 先例 U3（#70）/U4（#85）/U5（#71）/U6（#72）。
**baseline**：worktree 起于 origin/main `5463c32`，716 tests / 112 suites / 0 failures。

---

## 一、范围与边界

### 1.1 本 PR 范围（顺位 8）

实现 **U1 首页的展示层 shell**，严格 **view-only + 注入导航意图**：

1. `HomeContent`：平台无关纯值类型，把训练统计 / 历史记录 / 按钮态 / 缓存态格式化成显示字符串与语义标志。host swift test 全测。
2. `HomeView`：薄 SwiftUI shell，消费 `HomeContent` + 4 个**注入的导航意图闭包**，渲染首页四区（统计栏 / 开始·继续按钮 / 历史列表 / 齿轮）。由 Mac Catalyst build-for-testing 编译闸门守护，不 host 单测。
3. `HomeContentTests`：host 真断言覆盖全部格式化与边界。

### 1.2 明确不在本 PR（归顺位 11「生产组合根 + 路由 + 启动恢复」）

outline §二 顺位 8 字面：「**view only**…不在此接生产 root，避免在 U2/U4 落地前引入占位路由」。下列全部**不做**：

- 不构造 / 不 import / 不持有 `TrainingSessionCoordinator`（E6）、`SettingsStore`（P6）、`DownloadAcceptanceRunner`（P2）。
- 不调用 coordinator 的 `startNewNormalSession` / `resumePending` / `review` / `replay`（这些是注入闭包在顺位 11 的接线目标）。
- 不做实际导航 push、不替换 app entry、不接 `KlineTrainerApp.swift` / `ContentView.swift`。
- 不在本 PR 内 present U6 `HistoryActionSheet`、不路由 复盘/再来一次（见 §四 D6）。

### 1.3 与 modules spec L2026 的张力及裁决（D1）

modules spec `kline_trainer_modules_v1.4.md` §U1（L2026-2047）给出的是**接线式签名** `HomeView.init(coordinator:settings:acceptance:)`，注释示意 view 内部直接 `await coordinator.startNewNormalSession()` 并 `pushToTrainingView`。

**裁决（D1）**：本 PR 不实现该接线式 init。理由链：
- Wave 2 outline §二 顺位 8（v7，经 codex branch-diff R1-R6 评审收敛的 governance 文档）**显式把顺位 8 收窄为 view-only + 注入导航意图**，并把 coordinator 接线 + 路由 + app entry 替换**移到顺位 11**（v6 F3 拆分记录在 outline 变更日志）。outline 是比 modules §U1 示意代码更晚、更具体、且经对抗评审的执行权威。
- 不修改 modules spec 本身（尊重 PR #64 RFC 治理边界：改 spec 须独立设计文档）。modules §U1 的 `init(coordinator:settings:acceptance:)` 重新解读为**顺位 11 生产组合根处的装配形态**——即顺位 11 会从这三个依赖取数构造 `HomeContent`、把 4 个意图闭包接到 coordinator——而非顺位 8 的 view 壳签名。
- 此裁决与 Wave 1 U3/U5/U6 先例一致：那三个 shell 的 modules 签名本就是 callback 式（`init(record:onConfirm:)` 等），U1 在 modules 里是接线式仅因它历史上承担顶层装配；outline 已把该装配责任迁出顺位 8。

---

## 二、架构：Shell-mode 双层（沿用 U3/U4/U5/U6）

```
┌─────────────────────────────────────────────────────────────┐
│ 顺位 11 组合根（不在本 PR）                                    │
│   recordRepo.statistics() / .listRecords()                   │
│   pendingRepo.loadPending() != nil → hasPending              │
│   cache.listAvailable().isEmpty == false → hasCachedSets     │
│        │ 构造                          │ 接线 4 闭包          │
│        ▼                               ▼                      │
│   HomeContent(...) ───────────► HomeView(content:onStart:    │
│                                   onContinue:onSelectRecord:  │
│                                   onOpenSettings:)            │
└─────────────────────────────────────────────────────────────┘
            本 PR 交付 ↑（HomeContent 纯值 + HomeView 壳）
```

- **数据流单向**：`(统计 tuple, [TrainingRecord], hasPending, hasCachedSets)` → `HomeContent`（一次性快照计算）→ `HomeView` 只读渲染。
- **意图流单向**：用户交互 → `HomeView` 调注入闭包 → caller（顺位 11）路由。`HomeView` 不知道闭包背后是 coordinator 还是别的。
- **平台守卫**：`HomeContent` 仅 `import Foundation`（host 全测）；`HomeView` `import SwiftUI`（Catalyst 编译守护，跨 iOS17/macOS14/Catalyst 原生，不加 `#if canImport(UIKit)`，沿用 U6 D1）。

---

## 三、契约

### 3.1 `HomeContent`（纯值，`import Foundation`）

```swift
public struct HomeContent: Equatable, Sendable {
    // 统计栏 §6.1.1
    public let totalSessions: String   // "N 局"
    public let winRate: String         // "67%"；totalCount==0 → "—"
    public let totalCapital: String    // "¥ 102,345.67"；totalCount==0 → 显示 configuredCapital（D13）
    // 开始/继续按钮 §6.1.2
    public let primaryActionLabel: String  // hasPending ? "继续训练" : "开始训练"
    public let isResuming: Bool             // == hasPending；view 据此选 onContinue / onStart 分支
    public let hasCachedSets: Bool          // 空缓存提示判定（false → 点开始训练弹提示）
    // 历史列表 §6.1.3
    public let rows: [HomeHistoryRow]       // 已按 createdAt 从新到旧（tie-break id desc）
    public let isHistoryEmpty: Bool         // rows.isEmpty

    public init(statistics: (totalCount: Int, winCount: Int, currentCapital: Double),
                configuredCapital: Double,          // D13：settings.totalCapital，零局回退显示
                records: [TrainingRecord],
                hasPending: Bool,
                hasCachedSets: Bool,
                timeZone: TimeZone = .current)
}

public struct HomeHistoryRow: Identifiable, Equatable, Sendable {
    public let id: Int64          // == record.id（已解包，非 nil；见 D12）。SwiftUI 身份 + onSelectRecord 回传
    public let dateTime: String   // "2024-03-15 14:32"（createdAt 按 timeZone 格式化）
    public let stock: String      // "贵州茅台（600519）"
    public let startMonth: String // "2021年08月"
    public let totalCapital: String // "¥ 102,345.67"
    public let profitAndRate: String // "+¥ 2,345.67（+2.34%）"
    public let sign: ProfitSign   // 据 profit 定 红/绿/默认 色（view 映射，Content 不含颜色）
}

public enum ProfitSign: Equatable, Sendable { case positive, negative, zero }
```

**`HomeHistoryRow.id` 可选性（D12）**：`TrainingRecord.id` 是 `Int64?`（`AppState.swift:20`，未落库时 `nil`）。历史列表语义上**只含已落库记录**（`RecordRepository.listRecords` 返回的是已 insert 行，id 非 nil 是其契约不变量）。`HomeContent.init` 用 `records.compactMap { record in record.id.map { (id, record) } }` 跳过任何 `id==nil` 记录（纵深防御：未落库记录不是合法历史项），再在解包后的非可选 id 上做 tie-break 排序与 `HomeHistoryRow.id` 赋值。`isHistoryEmpty` 基于 compactMap 后的 `rows`。禁止 `record.id!` 强解包。

#### 格式化规则（全部自包含，不复用 SettlementContent —— 沿用 U6 D4「避免 sibling UI content 耦合」）

| 字段 | 规则 | 决策 |
|---|---|---|
| `totalSessions` | `"\(totalCount) 局"` | — |
| `winRate` | `totalCount==0` → `"—"`（U+2014）；否则 `winCount/totalCount×100` 四舍五入到整数 + `"%"`（如 `"67%"`） | D2 / D7 |
| `totalCapital`（统计栏） | `totalCount==0` → 格式化 `configuredCapital`；否则格式化 `statistics.currentCapital`。格式 = `formatCapital`（下行） | D13 |
| `formatCapital`（统计栏 + row totalCapital + row 盈亏额共用） | `"¥ "` + POSIX(`en_US_POSIX`) 千分位 + 强制 2 位小数（沿用 U3 `formatCapital` 字面规则，本地副本）。**¥ 后恒一个空格，全 PR 一致** | D3 |
| `primaryActionLabel` | `hasPending ? "继续训练" : "开始训练"` | — |
| row `dateTime` | `createdAt`（epoch 秒）→ `DateFormatter("yyyy-MM-dd HH:mm")`，locale `en_US_POSIX`，`timeZone` 注入（默认 `.current`；**测试必须显式传固定 TimeZone**，见 §五） | D5 |
| row `stock` | `"\(name)（\(code)）"`（全角括号 U+FF08/U+FF09） | D4 |
| row `startMonth` | `"\(year)年" + String(format:"%02d",month) + "月"` | — |
| row `profitAndRate` | `符号 + "¥ " + 千分位(\|profit\|, 2 位) + "（" + 符号 + (returnRate×100, 2 位) + "%）"`；签名零归一化（`==0` → 取 `+`，含 `-0.0`，沿用 U3 D5）。例：`"+¥ 2,345.67（+2.34%）"` / `"-¥ 1,234.56（-1.23%）"` / `"+¥ 0.00（+0.00%）"` | D8 |
| row `sign` | `profit > 0` → `.positive`；`profit < 0` → `.negative`；`profit == 0`（含 `-0.0`）→ `.zero` | D9 |

**spec §6.1.3 L880 行示例为 illustrative（D8/D3 统一声明）**：spec 历史行示例 `¥102,345  +¥2,345（+2.3%）` 同时**省略角分、省略 ¥ 后空格、收益率只 1 位小数**——三处都是示意松写。权威格式以本设计为准：所有金额 = `"¥ "`（带空格，对齐统计栏 plan §6.1.1 L855 `¥ XXX,XXX` 字面 + U3 结算屏先例）+ 2 位小数；收益率 2 位小数（对齐 U3 `formatSignedRate` + 结算屏 §6.3 L998 `+2.34%`）。此声明消除「同行内两个 ¥ 字段间距不一致」与「精度偏离 L880」两条挑战路径。

#### 排序（D10）

`HomeContent.init` 内部对 `records` 按 `createdAt` **降序**排序（从新到旧），`createdAt` 相等时按 `id` 降序兜底（确定性，防 host 测试不稳定）。**不依赖** caller 传入顺序（`RecordRepository.listRecords` 协议未约定顺序）。

### 3.2 `HomeView`（薄 SwiftUI shell，`import SwiftUI`）

```swift
public struct HomeView: View {
    public init(content: HomeContent,
                onStartTraining: @escaping () -> Void,
                onContinueTraining: @escaping () -> Void,
                onSelectRecord: @escaping (Int64) -> Void,
                onOpenSettings: @escaping () -> Void)
}
```

`body` 行为（无业务逻辑，只装配 + 触发意图）：

1. **顶栏**：统计栏（`totalSessions` / `winRate` / `totalCapital` 三 `Text`）+ 右上角齿轮 `Button(action: onOpenSettings){ Image(systemName:"gearshape") }`（§6.1.4）。
2. **主按钮**：`Button` 文案 `content.primaryActionLabel`；点击分流（§6.1.2）：
   - `content.isResuming` → `onContinueTraining()`
   - 否则 `content.hasCachedSets` → `onStartTraining()`
   - 否则 → 置 `@State showEmptyCacheAlert = true`，`.alert` 弹「暂无可用训练数据，请先在设置中下载离线缓存」（D11）
3. **历史列表**：`content.isHistoryEmpty` → `Text("暂无训练记录")`（§6.1.3）；否则 `List`/`ForEach(content.rows)`，每行展示 6 字段，`profitAndRate` 按 `row.sign` 着色（`.positive`→`.red`、`.negative`→`.green`、`.zero`→`.primary`，**A 股红涨绿跌**，§6.1.3）；点击行 → `onSelectRecord(row.id)`（D6）。
4. `#if DEBUG #Preview`：`fileprivate` 构造一个 `HomeContent` fixture（不污染 PreviewFakes，沿用 U3/U6 D11 文件作用域 fixture 机制）。

---

## 四、关键决策汇总

| # | 决策 | 选择 | 理由 |
|---|---|---|---|
| **D1** | view surface | view-only shell（不接 coordinator） | §1.3：outline 顺位 8 权威收窄；不改 modules spec；与 U3/U5/U6 一致 |
| **D2** | 胜率@0 局 | `"—"` | 零样本不杜撰 0%，避免 0/0 误导（user 批准） |
| **D3** | 货币格式 | `¥ `（带空格）+ POSIX 千分位 + 2 位小数，**全 PR 一致**（统计栏 + 行总资金 + 行盈亏额共用） | 与 U3 `SettlementContent.formatCapital` + plan §6.1.1 L855 `¥ XXX,XXX` 一致；Locale 中性防设备差异；L880 无空格示例为 illustrative |
| **D4** | 股票名格式 | `name（code）` 全角括号 | spec §6.1.3 L880 字面；自包含不复用 sibling |
| **D5** | 日期格式 | `yyyy-MM-dd HH:mm` + 注入 `timeZone`（默认 `.current`，**测试禁用默认必传固定时区**） | host 测试钉死时区保证确定性；POSIX locale 防格式漂移 |
| **D6** | 点击历史行 | 只 fire `onSelectRecord(id)`；U6 sheet + 复盘/再来一次 路由归顺位 11 | 保持 view-only，避免 HomeView 反向耦合 U6 + 原始 records；review/replay 的 coordinator 调用本归顺位 11（user 批准推荐）。**承接缝隙见 §七 R2 须登记** |
| **D7** | 胜率精度 | 整数百分比四舍五入 | spec §6.1.1 字面 "X%" 无小数 |
| **D8** | 盈亏格式 | `±¥ 金额（±rate%）` 2 位小数 + 签名零归一化 | spec §6.1.3 L880 示例（illustrative）；沿用 U3 D5 signed-zero + 2 位精度 |
| **D9** | `ProfitSign` 来源 | 据 `profit` 定（非 returnRate） | spec §6.1.3「颜色：正数红色，负数绿色」修饰盈亏额 |
| **D10** | 历史排序 | Content 内部 `createdAt` desc + `id` desc 兜底 | 不依赖 caller；确定性防测试 flaky |
| **D11** | 空缓存提示 | 注入 `hasCachedSets`，view inline `.alert` | spec §6.1.2 把提示归 HomeView；只 alert 不路由仍属 view-only（user 批准） |
| **D12** | `HomeHistoryRow.id` 可选性 | `compactMap` 跳过 `id==nil` 记录，禁强解包 | `TrainingRecord.id: Int64?`（AppState.swift:20）；listRecords 契约保证已落库 id 非 nil，compactMap 为纵深防御 + 解包后排序/回传 |
| **D13** | 零局总资金 | 增 `configuredCapital` 参数；`totalCount==0` 显示它而非 `currentCapital`(=0) | `statistics().currentCapital` 无记录时返 0（impl `?? 0`），直接显示违反 plan §6.1.1 L861「初始 10 万」；镜像 coordinator `startingCapital()` 规则 |

---

## 五、测试策略

**`HomeContentTests`（host 真断言，Swift Testing）** —— 覆盖矩阵：

- 统计栏：`totalSessions` 计数；`winRate` 正常（如 2/3→"67%"、四舍五入边界如 1/2→"50%"）、**totalCount==0→"—"**、全胜 "100%"；`totalCapital` 千分位 + 2 位小数 + POSIX + **精确串含 `"¥ "` 带空格**。
- **零局总资金（D13）**：`totalCount==0` + `configuredCapital=100000` → `totalCapital=="¥ 100,000.00"`（不是 "¥ 0.00"）；`totalCount>0` 时显示 `currentCapital` 而非 configuredCapital。
- 按钮：`hasPending=true`→`primaryActionLabel="继续训练"` & `isResuming=true`；`false`→"开始训练" & `isResuming=false`。
- `hasCachedSets` 透传 true/false。
- 历史 rows：**排序** createdAt desc（含乱序输入 + createdAt 相等用 id desc 兜底）；逐字段格式（dateTime、stock 全角括号、startMonth 零填充、totalCapital 含 `"¥ "`）；`profitAndRate` 三签名精确串（正 `"+¥ 2,345.67（+2.34%）"`/负 `"-¥ 1,234.56（-1.23%）"`/零 `"+¥ 0.00（+0.00%）"`）；signed-zero（`profit=-0.0`、`returnRate=-0.0` → 取 `+`）；`sign` 正确（正/负/零，含 `-0.0`→`.zero`）。
- **id 可选性（D12）**：输入含一条 `id==nil` 记录 → 被 `compactMap` 跳过，不出现在 rows、不 trap；其余正常记录保留。
- **dateTime 时区（D5，硬规则）**：所有 dateTime 断言**必须显式传 `TimeZone(identifier:)`，禁用默认 `.current`**；至少一条跨时区边界用例（同一 `createdAt` 在 `UTC` vs `Asia/Shanghai` 落不同日期/小时，验证 timeZone 真生效）。
- 空历史：`records=[]` → `isHistoryEmpty=true` & `rows=[]`。

**`HomeView`**：不 host 单测（SwiftUI 壳）。由 `Mac Catalyst build-for-testing on macos-15` required check 守护编译 + 链接（§五 Catalyst CI 强制）。`#Preview` 提供视觉自检。

**运行时 residual**：本 PR 无 C2/C7/C8 类运行时 gate（U1 是静态展示 shell，无 CADisplayLink / 手势 / 渲染运行时行为）；outline §四 净 residual 责任表未给顺位 8 挂任何 residual。

---

## 六、acceptance（非 coder 可执行，详版在 plan）

中文 action/expected/pass-fail，覆盖：HomeContent 各格式化与边界由 host 测试输出佐证；HomeView 由 Catalyst build SUCCEEDED + `#Preview` 渲染佐证；grep 断言 HomeView 不 import coordinator/settings/acceptance（view-only 守卫）。详细清单在 plan 文档。

---

## 七、风险与 residual

- **R1（已裁决，非 residual）**：D1 view-only 与 modules §U1 接线式 init 的张力——由 §1.3 裁决消解，记入本设计 + plan，顺位 11 承接接线式装配。**reconcile 登记**：modules §U1 L2031-2033 仍字面写接线式 `init(coordinator:settings:acceptance:)`，本 PR 不改 spec（PR#64 边界），但 PR body 须显式登记「modules §U1 接线式 init = 顺位 11 装配形态，非 view 壳签名」，防未来 grep §U1 命中 stale 字面（同 fee-callsite reconcile 教训）。
- **R2（顺位 11 outline 承接缝隙，须 PR body 显式登记）**：spec §6.1.3「点击历史行→弹出提示框（复盘/再来一次）」的**弹窗呈现段**，本 PR D6 只交付 fire `onSelectRecord(id)`，把 U6 sheet 呈现 + 路由推给顺位 11；但 outline 顺位 11（L54）字面只写「接线 review/replay 路由」**未含 "present U6 sheet"**。须在 PR body 承接清单显式标注「outline 顺位 11 文本未含 U6 `HistoryActionSheet` 呈现，顺位 11 plan 须显式纳入 onSelectRecord → present U6 sheet → 复盘/再来一次」，避免顺位 11 照 outline 字面漏接，使历史点击链半成品化。
- **数据源 ≠ 注入目标（提示顺位 11）**：`TrainingSessionCoordinator` 的 `recordRepo`/`pendingRepo`/`cache`/`settings` 均 `private`（不暴露）。顺位 11 构造 `HomeContent` 须**直接持有** `RecordRepository`/`PendingTrainingRepository`/`CacheManager`/`SettingsStore` 取数（statistics/listRecords/loadPending/listAvailable/settings.totalCapital），coordinator 仅作 4 闭包里 start/continue 的调用目标。本 PR U1 不持有任何依赖，不受影响。
- **无新公共契约风险**：`HomeContent`/`HomeView`/`HomeHistoryRow`/`ProfitSign` 是本 PR 新增 UI 展示面，不改任何冻结契约、不动 Wave 0 frozen surface。
- **顺位 11 承接清单（写入 PR body 供顺位 11 grep）**：构造 HomeContent 取数源（含 `configuredCapital=settings.totalCapital`）、4 闭包接线目标、**onSelectRecord → present U6 sheet → review/replay（R2）**、onOpenSettings → SettingsPanel、modules §U1 接线式 init reconcile（R1）、app entry 替换、启动 `retryPendingConfirmations()`。

---

## 八、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-07 | v1 | 起草；shell-mode 双层；D1-D11 决策（user 批准 shell-mode / 胜率@0="—" / hasCachedSets 入 shell / D6 onSelectRecord） |
| 2026-06-07 | v2（spec opus 4.8 对抗评审 R1 修） | **[H]** D12 `HomeHistoryRow.id` 可选性：`TrainingRecord.id: Int64?`，compactMap 跳 nil 禁强解包 + 测试；**[M]** D13 零局总资金：增 `configuredCapital` 参数，`totalCount==0` 显示它而非 `currentCapital`(=0)，修 plan §6.1.1 L861「初始 10 万」冲突 + 测试；**[M]** ¥ 间距统一为 `"¥ "`（带空格）全 PR 一致 + L880 illustrative 声明；**[M]** 精度偏离 L880 显式声明 illustrative（金额/收益率均 2 位）；**[M]** R2 U6 sheet 呈现 outline 顺位 11 缝隙登记；**[L]** R1 modules §U1 接线式 init reconcile 登记；**[L]** D5 timeZone 测试硬规则（禁默认 + 跨时区用例） |
