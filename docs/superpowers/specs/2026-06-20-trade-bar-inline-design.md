# 设计文档：买卖小操作栏（内联展开 + 全仓/清仓快捷）（UI 改版 #1）

- 日期：2026-06-20
- 类型：UI 交互改版（改已冻结 spec §U5 / plan §6.2.4，走完整 RFC）
- 来源：2026-06-17 模拟器运行时验证 #5（买卖需点按钮 → 弹模态 5 档 sheet，步骤重、模态碍事；要求改「按钮旁小操作栏 + 全仓/清仓快捷」）。见 `project_runtime_verification_findings_2026_06_17`。
- 评审通道：**Opus 4.8 xhigh 对抗性 review 到收敛**（代 codex，user explicit；codex 周配额耗尽，与本项目所有 opus-fallback PR 一致）。
- 范围说明：这是「UI 改版 4 子项」拆分后的第 2 个独立 RFC（继 #3 坐标轴 PR #124 后）。其余 2 项（#2 历史中间弹窗 / #4 两图 pan 联动）各自独立 RFC，后续单独排。

---

## 1. 背景与问题

当前买卖交互链路（`TrainingView.swift`）：每个 K 线面板（上/下）右侧窄列渲染纵向三按钮 `买入 / 卖出 / 持有·观察`（`tradeButtons(_:)` L197-211）。点「买入/卖出」**不直接交易**，而是置位 `@State pickerRequest`（L199/L201）→ `.sheet(item:)`（L107-115）弹出**模态** `PositionPickerView`——横排 5 档（`1/5…5/5`）的 sheet（`PositionPickerView.swift`）。用户单 tap 某档 → `onPick(tier)` 同步调 `performTrade`（L214-230）→ `engine.buy/sell(panel:tier:)`。

运行时验证 #5：这条「点按钮 → 弹模态 → 选档 → 模态消失」链路步骤重、模态遮挡图表、打断盯盘节奏。要求改成**按钮旁内联小操作栏**（无模态）+ **全仓/清仓快捷**。

**关键发现（引擎侧零改动）**：「全仓/清仓」无需新引擎方法——`PositionTier.tier5`(5/5) 在引擎里**已经**就是全仓/清仓语义：
- `buy(panel:, tier:.tier5)` → `TradeCalculator.quoteBuy` 用 `ratio=1.0`（目标金额=全部总资金，受现金+佣金自然封顶）= 全仓买入。
- `sell(panel:, tier:.tier5)` → `quoteSell` 走 `sellShares = holding` 全平分支（不取整、允许零股，`TradeCalculator.swift:73-74`）= 清仓。
- `buyEnabled`（`TrainingEngine.swift:299`）/ `sellEnabled`（L312）计算属性**已就绪**，可直接复用做小条启用门。

## 2. 目标与范围

### 目标
把买卖交互从「点按钮 → 模态 5 档 sheet」改为「点买/卖 → 按钮旁悬浮内联小条直接选档成交」，并把全仓/清仓做成小条内的强调色快捷档（= tier5）。

### In scope
- 新增纯值类型 `TradeBarContent`（host 全测）：把 `action: .buy/.sell` 翻译成有序 5 chip（tier1–4 = `1/5…4/5`；tier5 = `全仓`(买)/`清仓`(卖)，标 `isShortcut`）。
- 新增 SwiftUI 薄壳 `TradeBarView`：横向渲染 chips + 取消(✕)，`onPick(tier)` / `onCancel`。
- 改 `TrainingView`：买入/卖出按钮改为置位内联小条状态（不再弹 sheet）；以 `.overlay` 在被点面板悬浮渲染 `TradeBarView`；删 `.sheet(item:$pickerRequest)`。
- **删除被替换的旧组件** `PositionPickerView.swift` + `PositionPickerContent.swift` + `PositionPickerContentTests.swift`（本改动使其成孤儿——唯一 caller 即被替换的 sheet 链路）。
- 改冻结 spec：modules §U5（模态 PositionPicker → 内联 TradeBar）+ plan §6.2.4（ASCII 布局）+ 新验收清单。

### Out of scope（非目标，明确排除）
- ❌ 引擎 / `TradeCalculator` / `TradeFeedback` / 触觉 / Toast / autosave 逻辑（零改动）。
- ❌ `PositionTier` 枚举本身（5 档语义不变；仅 UI 把 tier5 按上下文重标 `全仓`/`清仓`）。
- ❌ 逐档启用态灰置（沿用现状：buyEnabled/sellEnabled 门控小条能否打开，chip 全可点，失败走既有 toast；YAGNI，与现 D9 行为一致）。
- ❌ 顶栏「仓位 X/5」、「结束本局」底栏、画线按钮、能力矩阵（Normal/Replay 可见、Review 隐藏）—— 全不变。
- ❌ 图表几何 / 渲染管线 / RFC #3 坐标轴（零改动）。
- ❌ #2/#4 两个子项（各自独立 RFC）。

## 3. 已锁定决策（brainstorming Q&A 结果）

| # | 决策 | 取值 |
|---|---|---|
| D1 | 交互模型 | **A 内联展开**：点买/卖 → 就地悬浮小条（无模态弹窗），点 chip 立即成交并收起 |
| D2 | 折叠态布局 | 保持现状窄右列三按钮 `买入/卖出/持有·观察`（双面板紧凑，不加常驻按钮） |
| D3 | 展开态布局 | 悬浮横条（从按钮旁滑出、叠在图表上），**不挤压图表、不触发 renderState 重算、不碰 RFC #3 轴几何** |
| D4 | chip 集合 | 5 chip 映射 `PositionTier.tier1…tier5`；tier1–4 = `1/5…4/5`，tier5 = `全仓`(买)/`清仓`(卖) |
| D5 | 全仓/清仓 | **A 折入小条**：= 小条最右 tier5 chip，强调色（`isShortcut`）；非独立常驻按钮（避免双面板按钮膨胀） |
| D6 | 启用态 | 沿用现状：buyEnabled/sellEnabled 门控小条打开；chip 全可点，失败走既有 TradeFeedback toast |
| D7 | 成交反馈 | 不变（成功 autosave + `.heavy` 触觉；失败 toast；均复用既有 `performTrade`） |
| D8 | 旧组件 | 删除 PositionPickerView + PositionPickerContent + 其测试（本改动造成孤儿） |

## 4. 架构

### 4.1 沿用 UI 壳三件套（纯值 Content + 薄 View 壳 + host 测试）

与既有 `PositionPickerContent`+`PositionPickerView`、`SettlementContent`+`SettlementView`、`HistoryActionContent`+`HistoryActionSheet` 同构：**平台无关纯值类型 host 全测，SwiftUI 壳靠 Catalyst `build-for-testing` 编译闸 + 模拟器 runbook**（壳不写单测，沿用 PR #71 D10）。

### 4.2 新增纯值类型 `TradeBarContent`

新文件 `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarContent.swift`（仅 `import Foundation`，不 import SwiftUI/UIKit）：

```
public enum TradeAction: Equatable, Sendable { case buy, sell }

public struct TradeBarContent: Equatable, Sendable {
    public struct Chip: Equatable, Sendable {
        public let tier: PositionTier   // tier1…tier5
        public let label: String        // "1/5".."4/5" | "全仓"(buy) | "清仓"(sell)
        public let isShortcut: Bool      // tier5 == true（全仓/清仓，强调色）
    }
    public let action: TradeAction
    public let chips: [Chip]            // 恒 5 元素，tier1→tier5 升序
    public init(action: TradeAction)
}
```

构造规则（纯函数，host 真断言）：
- 迭代 `PositionTier.allCases`（enum 源码顺序 = tier1…tier5，杜绝 Set 迭代不确定性，同 `PositionPickerContent` D4）。
- tier1–tier4：`label = tier.rawValue`（`"1/5".."4/5"`），`isShortcut = false`。
- tier5：`label = (action == .buy) ? "全仓" : "清仓"`，`isShortcut = true`。
- `chips` 恒 5 元素、有序。

> **设计要点**：tier5 的 `label` 是 UI 表层按 `action` 重标（买入语境=全仓、卖出语境=清仓），**底层仍是 `PositionTier.tier5`**——交给 `engine.buy/sell(panel:tier:.tier5)` 即现有全仓/清仓引擎路径，零引擎改动、`PositionTier.rawValue`（`"5/5"`，持久化用）不变。

### 4.3 新增 SwiftUI 薄壳 `TradeBarView`

新文件 `ios/Contracts/Sources/KlineTrainerContracts/UI/TradeBarView.swift`（平台无关 SwiftUI，**不加 `#if canImport(UIKit)`**——同 `PositionPickerView` 跨 iOS17/macOS14/Catalyst 原生支持，host 编译但不单测）：

```
public struct TradeBarView: View {
    public init(action: TradeAction,
                onPick: @escaping (PositionTier) -> Void,
                onCancel: @escaping () -> Void)
    // body: HStack { ForEach(content.chips) { Button(chip.label){ onPick(chip.tier) }
    //                  .buttonStyle(chip.isShortcut ? .borderedProminent : .bordered) }
    //                Button(action: onCancel){ Image(systemName:"xmark") }.buttonStyle(.bordered) }
}
```

决议：
- 单 tap 直接 fire `onPick(tier)`，无二次确认（同 PositionPickerView D8）。
- View 不调 `dismiss`，收起由 caller（`TrainingView`）负责（同 PositionPickerView D15）。
- `onPick`/`onCancel` `@escaping`（Swift 编译强制）。
- 全仓/清仓 chip（`isShortcut`）用 `.borderedProminent` 强调，其余 `.bordered`（D5 强调色）。
- DEBUG `#Preview`：买/卖两态各一，`fileprivate` 隔离（同既有壳 D9）。

### 4.4 `TrainingView` 集成

改动点（`TrainingView.swift`）：
1. `@State private var pickerRequest: PickerRequest?` → `@State private var tradeStrip: TradeStripRequest?`（`{ panel: PanelId, action: TradeAction }`，`Identifiable`；同时只开一个小条）。
2. `tradeButtons(_:)`：买入按钮 `{ tradeStrip = TradeStripRequest(panel:id, action:.buy) }`、卖出 `{ … .sell }`（替换原 `pickerRequest = …`）；`.disabled(!buyEnabled/!sellEnabled)` 不变；持有/观察不变。
3. 删 `.sheet(item: $pickerRequest){ PositionPickerView(...) }`（L107-115）。
4. `panel(_:)` 改为 `.overlay(alignment: .bottom)` 条件渲染 `TradeBarView`，**渲染条件 = `showsTradeButtons && tradeStrip?.panel == id`**（conjoint guard，非仅 panel 匹配；修 review-L3：防 Normal 置位的 `tradeStrip` 在模式翻转至 Review / 会话结束后残留致小条悬空）。`onPick`/`onCancel` 闭包 = 把现 `.sheet` 的 onPick 闭包逻辑（`TrainingView.swift:110-113`，`performTrade(req.action,…); pickerRequest = nil`）原样搬入（`performTrade(action, panel:id, tier:tier); tradeStrip = nil`）—— 这与 `performTrade` **函数体**（L214，唯一改动是形参类型 `PickerRequest.Action → TradeAction`）是**两处不同改点**（修 review-H2）。
5. `performTrade(_ action: TradeAction, panel:tier:)`：签名形参类型从私有 `PickerRequest.Action` 改为顶层 `TradeAction`（其余体内逻辑——buy/sell 分派、autosave、触觉、toast——**字节不变**）。
6. 私有 `PickerRequest`（含其嵌套 `enum Action`）→ 改名 `TradeStripRequest`，`action` 字段类型改用顶层 `TradeAction`（`PickerRequest.Action` 随之移除）。**决议：改名 + 换类型，非删除重建**（§4.6）。

> **悬浮落位**：`TradeBarView` 横条需横向空间（5 chip + ✕），而买卖按钮在图表右侧窄列。决议用 `.overlay(alignment: .bottom)` 把小条悬浮在被点面板**底部**（横向占满面板宽、叠在图表下沿之上），而非塞进窄右列。这避免改面板 `HStack` 结构。**几何不变性（修 review-M1，诚实表述）**：`.overlay` 不改变 underlying `KLineView` 的 `frame`/`bounds`（SwiftUI overlay 按 underlying 尺寸绘制于其上、不动其 layout）→ 故 `onBoundsChange`/`layoutSubviews` 的几何重算**不触发**；`updateUIView` 仍可能因 SwiftUI body 重评估而重跑，但 `recordRenderBounds` 的 `previous != bounds` 守卫（`ChartContainerView.swift:130`）+ 零尺寸早返（L127）使其为 **no-op**、renderState 重建为**同值** → 零几何变化、不碰 RFC #3 轴几何 / PR #122 时序修复。小条短暂遮挡图表下沿（含 RFC #3 时间轴）属可接受（用户此刻聚焦交易决策，收起即恢复）。

### 4.5 删除旧组件

本改动使 `PositionPickerView` 成孤儿（grep `*.swift` 确认唯一 Swift caller = `TrainingView` 的 `.sheet`，本 RFC 删除该 sheet；`performTrade`/`PickerRequest`/`pickerRequest` 全部局限于 `TrainingView.swift`、零外部引用——review 已核验）。按 CLAUDE.md「Remove … that YOUR changes made unused」，删除：
- `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerView.swift`
- `ios/Contracts/Sources/KlineTrainerContracts/UI/PositionPickerContent.swift`
- `ios/Contracts/Tests/KlineTrainerContractsTests/UI/PositionPickerContentTests.swift`（10 个 `@Test`）
- **关联验收脚本 `scripts/acceptance/plan_u5_position_picker_view.sh` 一并删除**（修 review-H1/L1）：它在 `set -euo pipefail` 下对被删文件 `test -f` 会硬失败，是本改动造成的孤儿；review 已核验它**未接入任何 CI workflow**（CI 唯一验收闸是 `hardening_6_gate.yml`），故删除**不会 red-CI**。

**文本引用同步（= §7 的 spec amendment 清单，非遗漏）**：对 `PositionPickerView` 的文字引用集中在 `modules §U5`（L2124-2131 init 块）+ `plan §6.2.4`（L950-960 HUD ASCII）+ `plan 目录树注释 L274`——这三处正是 §7 要 amend 的冻结 spec 段落。PR #71 的两份历史 plan/acceptance doc（`docs/.../2026-05-28-pr-u5-*`）**保留不改**（已 shipped 的过去交付凭证）。

`PositionTier` 枚举（`Models.swift:25-31`）**保留**——引擎 `buy/sell` API + 持久化 record 用，非孤儿。`swift test` 无 `--filter`（`swift-contracts-smoke.yml:39`）→ 删 10 个 `@Test` 后总数自然下调、非硬编码、不 red-CI。

### 4.6 排除的备选
- **常驻操作栏（B）/快捷优先（C）**：双面板各一份 → 垂直占位翻倍 / 语义改动大（brainstorming 已排除）。
- **全仓/清仓独立常驻按钮**：右列 ×2 面板多 4 个按钮，拥挤（D5 排除）。
- **小条塞进窄右列纵向展开**：5 chip 纵向堆叠违背「操作栏（横向 bar）」语义、过高（§4.4 排除）。
- **小条挤压图表（push 布局而非 overlay）**：触发图表 bounds re-layout → renderState 重算 + 与 RFC #3 轴几何/PR #122 时序交互，风险高（§4.4 排除）。
- **复用 `PickerRequest` 名不改**：`Picker` 名在删除 PositionPicker 后误导；改名 `TradeStripRequest` + 顶层 `TradeAction`（§4.4 决议）。

## 5. 元素规格（精确规则）

### 5.1 TradeBarContent（纯值）
- `init(action:)` 一次性算 `chips`（值快照，不持引用观察，同 `PositionPickerContent` D13）。
- `chips.count == 5`，顺序 tier1→tier5。
- buy 态：`["1/5","2/5","3/5","4/5","全仓"]`，仅末档 `isShortcut`。
- sell 态：`["1/5","2/5","3/5","4/5","清仓"]`，仅末档 `isShortcut`。
- `tier` 字段恒为对应 `PositionTier`（tier5 chip → `.tier5`）。

### 5.2 TradeBarView（壳）
- `HStack` 横排 5 chip Button + 末尾 ✕(取消) Button。
- chip Button tap → `onPick(chip.tier)`；✕ → `onCancel()`。
- `isShortcut` chip → `.borderedProminent`；其余 → `.bordered`。
- 不分盈亏色（同 PositionPickerView D16）。

### 5.3 TrainingView 行为
- 折叠态：右列 `买入/卖出/持有·观察`（不变）。买/卖 `.disabled` 同 buyEnabled/sellEnabled。
- 点买入（buyEnabled）→ `tradeStrip = (panel, .buy)` → 该面板底部悬浮 buy 小条。卖出同理。
- 小条内点某 chip → `performTrade(.buy/.sell, panel, tier)`（既有逻辑）→ 收起小条。
- 点 ✕ → 收起小条（不成交）。
- 点另一面板的买/卖或另一动作 → `tradeStrip` 改写（同时仅一个小条）。
- **小条 overlay 渲染条件 = `showsTradeButtons && tradeStrip?.panel == id`（conjoint，修 review-L3）**：非仅 panel 匹配，须并入 `showsTradeButtons`——防 Normal 置位的 `tradeStrip` 在模式翻转至 Review / 会话结束后残留致小条悬空。
- **零持仓清仓角落结构性排除（修 review-L2）**：sell 小条仅当 `sellEnabled == position.shares > 0`（`TrainingEngine.swift:312`）为真才可打开，故「零持仓点清仓」不可达（`quoteSell` 亦兜底返 `.disabled`）——review 已核验。
- Review 模式 `showsTradeButtons == false` → 右列与小条均不渲染（能力矩阵不变）。

## 6. 测试策略（TDD）

### 6.1 host 单测（`TradeBarContentTests`，平台无关真断言）
- buy 态：`chips.map(\.label) == ["1/5","2/5","3/5","4/5","全仓"]`；`chips.map(\.tier) == [.tier1,.tier2,.tier3,.tier4,.tier5]`；仅 `chips[4].isShortcut`。
- sell 态：末档 label `"清仓"`；其余同。
- **买卖区分硬断言**：buy 与 sell 仅末档 label 不同（`全仓` vs `清仓`），前 4 档相同——杜绝「label 写死一套」的错误源（吸取 `feedback_acceptance_grep_anchoring` 的「真双判别锚」教训）。
- **label↔tier↔shortcut 联合锁定（修 review-M2）**：同一断言内 `chips[4].tier == .tier5 && chips[4].isShortcut && chips[4].label == (action == .buy ? "全仓" : "清仓")`——防三者各自漂移（如 label 误标 `全仓` 但 tier 误设 `.tier4` 仅靠 label 断言仍通过）。
- `chips.count == 5` 恒等；顺序 = `PositionTier.allCases`。
- `tier5.rawValue == "5/5"` 不受 UI 重标影响（持久化契约不变佐证）。

### 6.2 SwiftUI 壳
- Catalyst `build-for-testing` 编译闸（`TradeBarView` + 改后 `TrainingView` 编译通过）。
- 模拟器人工验收（acceptance runbook）：点买/卖出悬浮小条、5 档成交、全仓/清仓强调色、✕ 收起、Review 隐藏、双面板各自小条、成交触觉/toast 不变。

## 7. 治理 / 冻结 spec 影响

- **改冻结 spec（反转 §U5 既有决策，RFC 授权）**：
  - `kline_trainer_modules_v1.4.md` §U5：`PositionPickerView`（模态 HUD）→ `TradeBarView`（内联小条）+ `TradeBarContent`。登记新 init 签名 + `TradeAction`。
  - `kline_trainer_plan_v1.5.md` §6.2.4：买卖交互 ASCII 从「弹模态 5 档」改为「悬浮内联小条 + 全仓/清仓强调档」；显式声明引擎/TradeCalculator/反馈链路不变。
  - 新验收清单 `docs/superpowers/acceptance/2026-06-20-trade-bar-inline-acceptance.md`。
- **`CONTRACT_VERSION`**：当前 `1.6`（`Models.swift:7`）。权威 bump 策略 = `docs/governance/m01-schema-versioning-contract.md` 的 **A 类触发定义清单**（DDL / OpenAPI / 跨系统 / 持久化语义破坏——逐条判定，与文档顶层版本号无关）。本 RFC = UI 壳层改版（删/增 public **UI** 类型），`PositionTier` 枚举与其 `rawValue`(`"5/5"`)、record 持久格式、Codable、DDL **全不变** → 不命中任何 A 类触发 → **不 bump**。删除 public `PositionPickerView` 是 Swift API 表层变化，非 M0.1 数据契约变化。
  - ⚠️ **pre-existing 治理 drift（修 review-C1；非本 RFC 引入、非本 RFC 职责，登记 R6）**：(a) m01 文档顶层版本号仍标 `1.5`（代码已 `1.6`，PR #99 升级未回填 m01）；(b) `Models.swift:7` 注释指向的 `docs/contracts/contract-version-matrix.md` **不存在**（真权威是 m01）。本 RFC 的 no-bump 结论**只依赖 A 类触发清单的定义**（与 m01 陈旧版本号无关），故不受这两处 drift 影响；但 spec-freezing review 须显式声明而非静默依赖。
- **非信任边界变更**：不动 `.github/workflows`、codeowners、ruleset。
- 评审通道 = Opus 4.8 xhigh 对抗性 review（spec / plan / branch-diff 三道，各到收敛）。

## 8. 风险与残留

- **R1**：悬浮小条遮挡面板底沿（含 RFC #3 时间轴）。缓解：仅展开期短暂遮挡、收起恢复；贴底而非盖中部；user 已知（D3）。
- **R2**：`.overlay` 落位在双面板/上下分屏下的视觉对齐——壳层细节，靠 Catalyst 编译闸 + 模拟器 runbook 验证（不可 host 测）。
- **R3**：删除 frozen public `PositionPickerView` 的连带引用（验收脚本 / CI / 目录树注释 / 其他 grep 命中）——plan 阶段做完整 grep 引用图，逐一处理或登记残留。
- **R4**：`performTrade` 形参类型从 `PickerRequest.Action` 改 `TradeAction`——纯类型替换，体内逻辑字节不变；Catalyst 编译闸兜底。新增顶层 `TradeAction` 须先 grep 确认无命名碰撞（既有 `TradeOperation`/`TradeReason`/`TradeFeedback`/`TradeCalculator`，未见 `TradeAction`；plan 阶段硬核实）。
- **R5**：`.borderedProminent` 注释/语义与未来 RFC 潜在碰撞（吸取 PR #72 G6/§G.3 borderedProminent 注释碰撞教训）——plan/impl 阶段注释措辞谨慎。
- **R6**：pre-existing 治理 drift（修 review-C1；m01 版本号 1.5/1.6 滞后 + `Models.swift:7` 注释指向不存在的 `contract-version-matrix.md`）。非本 RFC 引入、非本 RFC 职责；plan 阶段可选做「`Models.swift:7` 注释指针一行外科修正 → 指向 m01」的 cleanup，或保留为登记残留交后续治理 PR。本 RFC no-bump 结论独立于此 drift（依赖 A 类触发清单定义）。

## 9. 成功标准

1. 点买/卖在对应面板悬浮内联小条（无模态）；5 档可成交；全仓/清仓为强调色末档（= tier5）；✕ 收起；Review 隐藏；双面板各自小条。
2. `TradeBarContent` host 单测全绿（买/卖标签、顺序、shortcut、买卖区分、tier5.rawValue 不变）。
3. host 全量 `swift test` 不回归（删 PositionPickerContentTests 后总数相应调整）+ Catalyst `build-for-testing` SUCCEEDED + iOS app build SUCCEEDED。
4. 引擎 / TradeCalculator / TradeFeedback / 触觉 / Toast / autosave / `PositionTier` 持久格式零改动；`CONTRACT_VERSION` 不 bump。
5. 三道 Opus 4.8 xhigh 对抗性 review 各收敛 APPROVE。
