# 交易/仓位/资金 + 训练界面 UI 总体改造路线图（2026-06-21）

> 来源：PR #128 merge 后 user 真机/模拟器实测，提出一大批需求。**总目标：买入/卖出/仓位/资金 + 训练界面 UI 完全对齐主流股票软件（同花顺/东方财富等）。**
> 本文件 = 防丢的总路线图。每个 RFC 各自走完整 superpowers 流程（spec → opus 4.8 xhigh 对抗 review → writing-plans → review → subagent-driven → verification → review → PR），评审通道 = Opus 4.8 xhigh（代 codex）。

## 0. 当前状态 · 从这里继续（RESUME POINT，新会话/压缩后必读）

- **进度**：brainstorming 全部完成、决策全定（见下）。**已建分支 `feat/fixture-period-preload`**，已提交本路线图（commit `ea5eeb9`）。本文件即权威计划，无需重新调研已定项。
- **基线**：main `4be9c74`（= PR #128 fixture 真实指标 merged）。本路线图分支从 main 切出。
- **下一个具体动作 = 开始顺位 1（RFC-F），走完整 superpowers 流程**：
  1. **先做一个聚焦调查**把「开局预放 before-candles」机制查准（见 §F 的 ⚠️）——`RenderStateBuilder.currentCandleIndex` 的 tick→index 映射、`backend/generate_training_sets.py assign_global_indices` 的 before/after 结构、fixture 当前为何 tick=0 只显 1 根。**这是 F spec 唯一未钉死的点**；周期比例部分已钉死（见 §F 参数）。
  2. 写 F spec → Opus 4.8 xhigh 对抗 review 到收敛 → writing-plans → review → subagent-driven → verification（host swift test + Catalyst + app build 三绿）→ whole-branch review → PR（user 终端 `--admin` merge，guard 拦 Claude push）。
- **每个 RFC 都这样独立走一遍**，顺序 F→B→A→C→E。评审通道=Opus 4.8 xhigh 代 codex（codex 周配额耗尽；merge 走 `--admin` 旁路缺失的 codex-verify-pass，与 PR #122–128 一致）。
- **B 特别注意**：动手前**真开浏览器做布局 mock 给 user 看**再定稿（user 明确要求）。
- **运行/验证 app**：模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`），`xcodebuild ... -scheme KlineTrainer`，`xcrun simctl install` + `SIMCTL_CHILD_KLINE_SEED_FIXTURE=1 xcrun simctl launch ... com.agateuu1234.KlineTrainer`。**改 fixture 后必须 `simctl uninstall` 再装**（全空守卫 `AppContainer+DebugSeed.swift:27` 挡重灌，否则看不到新数据——这是 PR #128 漏看指标的根因）。真机测试走 Xcode 开 `ios/KlineTrainer/KlineTrainer.xcodeproj`+签名+scheme 加 `KLINE_SEED_FIXTURE=1`。

## 决策（user 已拍：全部「按我的建议」）
- **周期比例 = P1**：默认组合 60分/日线日历精确 + 铺满（daily span 40→80，m3≈19,200，日线 240 根 / 60分 960 根）；周/月近似不强求铺满。
- **打包 = 分开**：交易 RFC 与周期比例分开。
- **4 处偏离主流的处理**：
  - #8 双图上下滑切周期：**保持**（我们的训练特色，已实现 spec §4.4 两指上下滑；非新开发）。
  - #7 设置 popover：**做 popover**（iOS 按钮锚定 Menu/popover 也是标准）。
  - #3 划线工具：**可折叠工具条**（折中，非常驻一行也非纯隐藏）。
  - #4c 十字光标右偏：**保持**（防手指遮挡）。

## RFC 拆分与顺序（布局提前——画布先定，避免功能返工）

### 顺位 1 · F — fixture 修正（小）· 🟢 **下一个要做（NEXT）**
**做什么**：修 DEBUG fixture 的两个问题——周期比例错 + 开局空。全 `#if DEBUG`，零生产/契约改动，不 bump CONTRACT_VERSION。
- **F1 周期比例（参数已钉死）**：`DebugFixtureData` 聚合 span 改为 m15=5 / m60=20 / **daily=80（4×60分=A股一天4小时）** / weekly=160 / monthly=240；`fullLoadM3Count` 9600→**19,200**。结果根数：m3=19200/m15=3840/m60=960/daily=240/weekly=120/monthly=80，均 ≥80 可默认渲染，**60分/日线 4:1 精确且最大缩小 240 根铺满**（P1；周/月比例近似不强求）。同步更新 `DebugFixtureDataTests` 的 span/count 断言。
- **F2 开局预放 before-candles**：⚠️ **机制未钉死——F 第一步先做聚焦调查**：①`RenderStateBuilder.currentCandleIndex` 的 tick→index 映射；②`backend/generate_training_sets.py` 的 `assign_global_indices` before/after 结构；③fixture 当前为何 tick=0 只显 1 根。目标：fixture 新局（`NormalFlow.initialTick=0`）开局即显约 80 根历史 before-candle（非近空）。生产真实数据已对（spec §8.3 存 ~150 before），只需 fixture 复刻。
- spec 待写：`docs/superpowers/specs/2026-06-21-fixture-period-preload-design.md`。
- 文件：`ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/DebugFixtureData.swift`、`DebugTrainingSetWriter.swift`、`Tests/.../DebugFixtureDataTests.swift`。

### 顺位 2 · B — 训练界面布局总重构（中，**用网页 mock 可视化定布局**）
- 坐标轴**不遮挡 K 线**（右侧固定价轴 gutter + 底部时间轴，留白；返工 #3 坐标轴 overlay 方案）。
- 顶部信息栏：**固定高度** + 名称在上/数值在下分行 + 加文字标签 + 金额留够宽（10万→1000万累计，缩字体不撑宽）。
- 划线工具 = **可折叠工具条**（点『画线』展开一行工具，预留后续更多工具）。
- 技术曲线（MA/BOLL/MACD DIF·DEA 黄白线）**加深 + 加粗**。
- **回收买卖/持有/结束本局按钮空间，最大化 K 线显示区**。
- ⚠️ 做 B 时**先用浏览器 mock 给 user 看布局**再定稿。

### 顺位 3 · A — 交易/仓位/资金对齐主流（大）
- 股数基准 + 一手 100 股（`shareLotSize=100` 已有）。买 k/5=floor(可用现金×k/5/价/100)×100（5/5=全仓）；卖 k/5=floor(持仓×k/5/100)×100（**5/5=清仓=全部持仓精确**）；卖≤持仓、买≤现金、0 持仓禁卖。语义纯主流（反复卖 1/5 靠清仓退）。
- 买卖框（主流两步）：可编辑「数量」框 + **+/− 按钮（每点 ±100 股）** + 手动输入（校验取整到手）；1/5..5/5 快捷键=填入数量框最接近合法手数，再点「买入/卖出」确认；框旁显「可买 X 股 / 可卖 X 股」。
- 训练/复盘显**当前持仓股数**（成本价/盈亏可选）；仓位% 非主元素。
- 资金：总资金**跨局复利接续**（新局从当前总资金起，存独立字段每局结束更新）；**重置资金 = 强制回 10万 + 保留历史记录**（推翻 #123 清记录）。改 `DefaultAppDB.resetAllTrainingProgress`（去 deleteAll）+ `TrainingSessionCoordinator.startingCapital`（读存储当前资金）。
- ⚠️ 动 E2 PositionManager / E3 TradeCalculator（Wave 1 冻结契约）→ RFC；预计不 bump CONTRACT_VERSION，spec 阶段核实。

### 顺位 4 · C — 长按十字光标交互对齐主流（大）
- 长按出十字标后再拖**整图不动**（不平移/缩放），只十字标动；横线跟手指 Y、竖线跟手指 X；竖线**离散吸附逐根 K 线**；光标**右偏一点不挡手**。
- **悬浮 overlay 侧栏**（浮在图上不占固定面积）显该十字标所在 K 线的 开/高/低/收 + 成交量 + 成交额（有则）+ 换手率（有则）；字体可调。
- **双面板**：点哪个 panel 显哪个 panel 的 K 线数据。**自适应左右**：十字标偏右→侧栏跳左防手挡，临近左侧→左消失右弹出。
- 点一下屏幕退出十字标 + 收侧栏。

### 顺位 5 · E — 设置 popover（小）
- 主页设置齿轮点开 = 齿轮旁小 popover 菜单（锚齿轮），非底部大 sheet。

## 已确认「无需开发」的项
- **#8 周期上下滑切换**：已实现（spec §4.4，两指上滑=周期变大/下滑=变小；模拟器 ⌥+竖直拖、真机两指）。
- **pinch 缩放**：已实现（每 panel 独立，两触点须同 panel 内；模拟器鼠标放 panel 正中再 ⌥+拖）。

## 主流对照（一致项，照 user 说的做）
坐标轴不遮 / 顶栏固定分行 / 十字光标冻结图·离散吸附·自适应侧栏·点击退出 / 曲线加深 / 开局预放 = 均与主流一致。
