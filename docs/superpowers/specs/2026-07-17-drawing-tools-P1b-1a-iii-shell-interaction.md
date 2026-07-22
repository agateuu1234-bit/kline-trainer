# 划线工具扩充 P1b · 1a-iii「外壳与设置」交互设计（薄增量）

> **权威范围 = `2026-07-10-drawing-tools-P1b-split-addendum.md` §4**（§4.1 做 / §4.2 不做 / §4.3 的 12 条负向测试 / §4.4 的 25 条验收），已经 codex spec review R1–R33 收敛。**本文件不改任何范围**，只做三件 writing-plans 需要的薄增量：
> 1. 锁定 spec 留给实现的 **2 处 UX 微决策**（brainstorming 2026-07-17 与 user 对齐）；
> 2. 重新核实并记录 **1a-i / 1a-ii merge 后的真实代码锚点**（spec 行号基于 `96d2ac4` 基线，已漂移）；
> 3. 记录本期新增/改动的 **组件结构**。
>
> **母 spec**：`2026-07-04-drawing-tools-expansion-design.md` §2（外壳）/ §3（设置面板）。
> **基线**：main `8bec593`（1a-ii MERGED，实测全绿）。**日期**：2026-07-17。

---

## 1. 已被 spec + 代码链锁定（不重议，仅登记）

| 面 | 结论 | 依据 |
|---|---|---|
| 入口 | 顶栏「结束」**左侧**加「画图」钮，留明显间距防误点；仅训练/replay（`showsTradeButtons`）显示 | spec §4.1.1 |
| 进入 | 点画图 → 两行栏**顶掉** `TradeActionBar`；顶栏「结束」→「退出」；画线期间**不下单** | spec §4.1.1；engine 已预埋此终局（见 §2） |
| 退出 | 点「退出」→ 栏落下、恢复 `TradeActionBar`、「退出」→「结束」；所有画线惰性 | spec §4.1.1 |
| 两行骨架 D24 | 上行=类型行（本期**只** 1 个水平线图标、**恒亮不 toggle**）；下行=**只** ①类型键（收/展类型行）。②–⑤ **不进视图树** | spec §4.1.2 / §4.3-3,4 |
| 退役浮动钮 D26 | 拆 `showsDrawingTools` 为两个谓词（见 §2），训练/replay 只剩「画图」入口；复盘仍浮动钮 | spec §4.1.3；codex R22-high |
| 设置面板 | 长按类型行图标 → 类型行上方弹浮层卡片（无气泡尾）；4 组控件；不可用项**只灰不写字**；昼夜禁色；默认值只作用「下一条线」、存内存整局有效**不落盘** | spec §4.1.4；母 spec §3 |

**关键交互模型锚**：1a-ii 作者已在 `TrainingEngine.swift:1179` 预写下本期终局——
> 「母 spec 终局是画线模式下底栏换成画线工具栏（1a-iii）→ 那时买卖钮不存在，本路径自然不可达」。
故「两行栏顶掉 `TradeActionBar`、画线期间不下单」不是新决策，是 merged 引擎已预埋的收敛方向。

---

## 2. 本期定稿的 2 处 UX 微决策（2026-07-17 与 user 对齐）

1. **「画图」钮外观 = SF Symbol 铅笔图标**（非文字）。呼应 spec「图标钮」与母 spec「取代浮动 ✎ 圆钮」。
   `accessibilityLabel = "画图"`（负向/验收测试按此 label 定位）。图标建议 `pencil.tip.crop.circle`（实现期可微调，label 不变）。
2. **设置卡片关闭 = 点卡外半透明遮罩即收起**。卡内每次选择实时生效、**无独立「完成」钮**。对齐验收 14「设好…关掉卡片，再画一条线」，手势最轻。

---

## 3. 核实后的真实代码锚点（main `8bec593`，UI 全在 `ios/Contracts/Sources/KlineTrainerContracts/`）

> spec §4 引用的行号基于 `96d2ac4`；1a-i/1a-ii merge 后 UI 迁入 Contracts 包且行号漂移。以下为**当前树实测**。

| spec 引用 | 当前真实位置 |
|---|---|
| `TrainingView.swift:69` `showsDrawingTools` | `UI/TrainingView.swift:69` `showsDrawingTools = showsTradeButtons \|\| engine.flow.mode == .review` |
| 浮动钮渲染（spec `:186`） | `UI/TrainingView.swift:186-188`（`.overlay(alignment:.topLeading)` 内 `DrawingToolFloatingView`） |
| activePanel 红框（spec `:423-425`） | `UI/TrainingView.swift:424-425`（`.overlay` 内 `if showsDrawingTools && id == activePanel`）|
| 顶栏「结束」钮（spec 加画图钮处） | `UI/TrainingView.swift:328-346`（`showsTradeButtons` 分支 `Button("结束")`）|
| 训练底栏 `TradeActionBar`（被两行栏顶掉处） | `UI/TrainingView.swift:199-210`（`if showsTradeButtons` 分支）|
| 共享状态容器（1a-ii） | `Drawing/DrawingSession.swift`（`drawingModeActive` / `activeDrawingTool` / pending，mutator 全 internal）|
| 画线开关 API | `TrainingEngine.swift:1139` `toggleDrawingMode()` → `beginDrawingSession(tool:.horizontal)` / `endDrawingSessionIfActive()` |
| 新线落盘触发 | `UI/TrainingView.swift:274` `.onChange(of: engine.drawings.count)`（本期 append 即触发，**不需 D30**）|

**谓词拆分（D26 / codex R22-high，交易安全）**：
- `showsFloatingDrawingTool = engine.flow.mode == .review`　→ 只门控 `:186` 的 `DrawingToolFloatingView`。
- `showsActivePanelHighlight = showsTradeButtons || engine.flow.mode == .review`（**保留 `showsDrawingTools` 现有语义**）→ 只门控 `:425` 的 activePanel 红框。
- 拆完后 `:69` 的 `showsDrawingTools` 原名可退役或改指 `showsFloatingDrawingTool`；**绝不可把 `:425` 也改成 review-only**（会抹掉「当前对哪个面板下单」的唯一提示 → 下错面板不可逆）。

---

## 4. 组件结构（本期新增/改动）

- **`DrawingModeBar`（新）**：两行常驻栏骨架（D24 一次定型）。上行类型行（本期 1 个水平线图标，恒亮）；下行 ①类型键。读 `engine.drawingSession`。类型行收/展由本地 `@State` 或容器字段控制（收起=让出一行图表高度）。②–⑤ 键不渲染。
- **`DrawingStyleCard`（新）**：长按弹出的设置卡片。4 组控件（线型子类/线样式/粗细/颜色/标注）+ 遮罩。灰态矩阵按母 spec §3.1 水平线行 + 昼夜禁色。写入本期新增的**内存默认样式**（见下）。
- **画图入口钮（改）**：`TrainingView` 顶栏 `:328` 分支左侧插入 SF 铅笔图标钮（`showsTradeButtons` 时显示），点它 `engine.toggleDrawingMode()`；进画线态时「结束」文案切「退出」。
- **底栏切换（改）**：`trainingContent` 的 `if showsTradeButtons` 分支——`drawingModeActive` 时渲染 `DrawingModeBar`，否则 `TradeActionBar`。
- **进画线 = 交易边界转换（codex branch-R3-high，交易安全，不可省）**：只换底栏**不够**。已弹开的**买卖档位框** `TradeBoxView`（`TrainingView.swift:401` 的 `.overlay`）**只受 `showsTradeButtons` 门控、不受 `drawingModeActive` 影响**，且它贴底悬浮、**不遮顶栏**——用户可「点买(置 `tradeStrip`) → 点顶栏画图(进画线) → 框还挂着 → 点确认 → `performTrade` → `engine.buy/sell` 不可逆入账+autosave」。`tradeStripStillValid` 只校验 period，进画线不改 period，校验会放行。故进画线必须像既有的 activePanel/period/tick 变化一样（`:238/245/248` 已 `tradeStrip = nil`）作废未确认买卖框：
  - **主（无条件，两个方向都清，codex plan-R9/R12-high）**：`.onChange(of: engine.drawingSession.drawingModeActive) { _, _ in tradeStrip = nil }`——**进画线与退出画线都清**。只清「进画线」不够：一个跨 round-trip 幸存的陈旧 `tradeStrip` 会在退出后（`!drawingModeActive`）remount，同 tick/period 下被放行成交。清 nil 恒安全（本就不该跨画线切换留买卖框）。覆盖一切切换路径（不止画图钮）。
  - **纵深**：`TradeBoxView` overlay 的挂载条件（`:401`）与 `onConfirm` 提交路径（`:406-415`，经 `TradeConfirmGuard.apply`）加 `!engine.drawingSession.drawingModeActive`——即使 `tradeStrip` 残留也不挂载/不成交。
  - **不在引擎层加 refuse 守卫（codex plan-R13↔R15 自相矛盾，revert R13）**：引擎既有 D45 不变量是**「下单即隐式退出画线」**（`buy/sell` 末尾 `endDrawingSessionIfActive()`，`:438/:502`，~10 个测试钉住 `drawingModeActive==false`）。在 `buy/sell` 顶部加 `guard !drawingModeActive → .disabled` 会**改掉这条 load-bearing 已测不变量**、并波及 `forceCloseManually`——非 surgical。本期「画线期间不下单」由 **UI 层完整enforce**：画线时底栏是 `DrawingModeBar`（无买卖钮）、`tradeStrip` 进/出都清、overlay+onConfirm 门控。直接引擎调用即便发生也走 D45 干净退出画线并成交（是显式交易，安全）。D45 保持不变。
  - **负向验收**：开着买/卖框 → 进画线 → **不动 tick/周期直接退出** → 旧框不得重现、不得成交（证明是「清掉」而非「隐藏」）。
  - **负向测试**：开着买/卖框点「画图」→ 框消失且**不可提交**，`engine.buy/sell` **零调用**（trade-safety 回归）。
- **浮动钮谓词拆分（改）**：`TrainingView.swift:69` + `:186` + `:425`（见 §3）。
- **内存默认样式（新，不落盘）**：本期新增「下一条要画的线」的默认样式（线型子类/线样式/粗细/颜色/标注），整局有效；持久化的全局默认属 P6 §13，本期**只内存**。
  - **必须落 `DrawingSession`（engine/session 单一 `@Observable` 真相，codex branch-R2-medium，不留 view-scope 选项）**：真正的提交路径是 `ChartContainerView.Coordinator → engine.drawingSession → commitPending → routeDrawingCommit`，它**读不到任何 `TrainingView` 的 view-scope 状态**。若默认样式放 view-scope 容器，`DrawingStyleCard` 改的是提交路径根本不读的 state → 用户设了样式、画线、append 触发 autosave，落盘的线仍是默认/错样式，且本期无后续 revision 纠正。上下两面板各自的 Coordinator 也会观察到分叉/陈旧默认。这与 1a-ii 的 **D39/R15-high** 完全同源：底栏（`DrawingStyleCard`，在 `TrainingView`）**写**、提交路径（Coordinator）**读**的状态，必须是 `DrawingSession` 上的同一份可观察真相，不得 view-私存。
  - **写入遵守 `DrawingSession` 访问级**（1a-ii plan-R5-high）：状态 `public private(set)`、setter `internal`；`DrawingStyleCard` 与引擎同属 `KlineTrainerContracts` 包，经 internal setter（直接在 session 上，或经 engine 转发）写入，包外无法绕过。
  - **原子构造不变量（codex branch-R1-medium，硬约束，不留选项）**：五个样式字段必须在 `routeDrawingCommit` **append 之前**就全部灌进 `DrawingObject`，让 append 成为 `drawings` 的**唯一**改动。**禁止**「先 append 默认样式的线、再原地改样式字段」的提交后套用路径——那是一次原地改线：`.onChange(of: engine.drawings.count)`（`TrainingView.swift:274`）append 时已触发一次、count 不再变，样式改动**不会**二次落盘，crash/切后台会存下**没样式**的线。此路径正是 spec §4.2「本期不存在原地改线 → 不需 D30」的前提所排除的；留着它就等于本期偷偷需要 D30。
  - **落地方式**（plan 定具体签名，但都必须满足上面的原子不变量）：把内存默认样式作为入参喂给 `commitPending`（现已收 `lineSubType`），或在 append 前的 builder 里一次性组装完整 `DrawingObject`。
  - **回归测试（§4.3-9 已覆盖 + 收紧）**：设了红/虚线2/3档粗细/标注靠右后画的线，`autosave` 重载后五字段逐一相等；并加一条**原子性锁**——断言从落锚到 append 之间 `drawings` 只被写一次（构造即完整），杜绝后人重新引入提交后套用。

---

## 5. 三绿门 + 验收（作者亲核）

- 三绿门（缺一不可，**CI 等价、逐字可跑**；cwd 与 `set -o pipefail` 一处不能少，否则失败的 build 会被 `tee` 的 0 退出码假绿——codex branch-R4/R5-high）。以下均从**仓库根**起跑：

  ```bash
  # 1) host swift test（cwd=ios/Contracts）
  ( cd ios/Contracts && swift test )

  # 2) Catalyst 门自检（判据先过测再上岗，仓库根）
  bash .github/scripts/catalyst-gate.test.sh

  # 3) Catalyst 编译+执行（cwd=ios/Contracts + pipefail；-Package scheme 缺一即两头落空）
  ( cd ios/Contracts && set -o pipefail && \
    xcodebuild test \
      -scheme KlineTrainerContracts-Package \
      -destination 'platform=macOS,variant=Mac Catalyst' \
      -only-testing:KlineTrainerContractsTests \
      -derivedDataPath /tmp/derived 2>&1 | tee /tmp/catalyst-build.log )

  # 4) Catalyst 门证明（证 tests 真编译真跑、macabi、UIKit-gated 真执行、计数在范围）
  bash .github/scripts/catalyst-gate.sh /tmp/catalyst-build.log

  # 5) iOS Simulator 编译（免签名 + pipefail）
  set -o pipefail && \
  xcodebuild build \
    -project ios/KlineTrainer/KlineTrainer.xcodeproj \
    -scheme KlineTrainer \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath /tmp/app-derived \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/app-build.log

  # 6) app-build 日志门（缺它则失败 build 会被 tee 0 退出码假绿）
  grep -F "** BUILD SUCCEEDED **" /tmp/app-build.log || { echo "BUILD SUCCEEDED 缺失"; exit 1; }
  if grep -F "** BUILD FAILED **" /tmp/app-build.log; then echo "BUILD FAILED"; exit 1; fi
  if grep -E "(^|[[:space:]])error:" /tmp/app-build.log; then echo "编译/链接 error:"; exit 1; fi
  ```

  - 命令与 CI 逐行对齐：步 2-4 = `.github/workflows/catalyst-build.yml:51/62-69/76`（含 `working-directory: ios/Contracts` + `set -o pipefail`）；步 5-6 = `.github/workflows/app-build.yml:41-46/48-53`。**「作者亲核」= 步 4 与步 6 的门脚本/grep 对本地日志真绿**，不是肉眼看 `BUILD SUCCEEDED`。
- **退出准则（future exit criteria，非「已完成」，codex branch-R6-medium）**：本分支当前只含本设计文档、**零测试零代码**；下列全部是**实现 PR 必须满足**的准入条件，评审时须见真实测试 + 三绿门日志，方可视为满足——不得据本文档判定覆盖已就绪：
  - 实现 PR 须落地 spec §4.3 的 12 条负向测试；§4.4 的 25 条非程序员验收清单随实现 PR 交付。
  - 实现 PR 须**新增**下列负向测试（本轮 codex 逼出，超出 §4.3 原 12 条）：
    - **原子样式落盘**（R1）：设样式画线 → autosave 重载五字段相等 + 落锚到 append 间 `drawings` 只写一次。
    - **交易边界**（R3-high）：开着买/卖框点「画图」→ 框消失/不可提交、`engine.buy/sell` 零调用。
- **模拟器验收不可跳过**（1a-ii 血泪：CI 8/8 + 三绿门 + codex 5 轮全漏掉 3 个交互层回归）。SwiftUI @Observable 订阅 / 底栏切换 / 长按手势 / 遮罩点击这类只有真机/模拟器手点能发现。给这些行为加**源码守卫**（读源码文本断言 + mutation 验证）。
