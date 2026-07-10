# 划线工具扩充 · P1b 拆分补充 spec（1a-i / 1a-ii / 1a-iii / 1a-iv / 1b-i / 1b-ii）

> **母 spec**：`docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（下称「母 spec」）。
> 本文件**只覆盖母 spec §15 中 P1 行的交付粒度**，不改任何母 spec 的设计决策（D1…D22 全部继续生效）。
> **基线**：`96d2ac4`（P1a 契约地基已 merge，PR #140）。
> **日期**：2026-07-10。
> **状态**：经 codex 对抗 review R1–R17。D28 举证 / D29–D42 / 六段可交付序列均为 review 结论。原「P1c」降级为后续 epic **P1c**（§7）：本 spec 不拆它——它尚未设计，切一个不存在的 PR 是空想；**其 spec / plan 阶段必须先拆**。

---

## 0. 为什么要拆

母 spec 的 P1 是一个阶段，实际含 7 大子项（外壳 §2 / 设置面板 §3 / 节点 §6 / 选中·删除·锁定·撤销 §7 / 多锚泛化 §5.0 / 周期绑定 §10 / 手势消歧 §14）+ 5 个工具，估算 2500–3500 行生产代码。

P1a（纯契约 + 持久层，零 UI）已作为 PR #140 独立 merge。**剩余部分即本文件所称 P1b**，仍然过大：

- 违反 `CLAUDE.md` 治理约束「每 PR ≤3 子项、≤500 行」（P1a 已是超额特批）。
- P1a 的实证：单个大 PR 在本地 codex 对抗 review 走了 21 轮 29 finding 仍未自然 approve。体量越大越不收敛。

故 P1b 的**可交付 PR 序列 = 六个**：**1a-i → 1a-ii → 1a-iii → 1a-iv → 1b-i → 1b-ii**。原「P1c」（多锚 + 节点 + 四工具）**降级为后续 epic「P1c」，不属于本序列、不是已授权的 PR 边界**（§7）。

> **切分历程（留档，两次都由 codex 对抗 review 逼出、经用户显式决断）**：
> - 初稿两段（P1b-1 / P1c）。**R3-high**：P1b-1 仍含七个互相独立的风险面，"批准此 spec 等于放行又一个大 PR"。核实属实 → 沿「能不能画得漂亮」与「能不能选中改」的缝切成 1a / 1b / 2。
> - **R9-high**：1a 仍横跨九个面（外壳 / 底栏 / 设置面板 / `DrawingTool` API 迁移 / 样式渲染 / 水平线几何与标签 / 手势 / 跨模式周期绑定 / 同 period 取消）。核实属实 → 再切成 1a-i / 1a-ii / 1a-iii。
>
> - **R10-high**：把 D29 周期绑定留到 1a-iii，会让 1a-ii 成为一个「画线更显眼、却仍会把线渲染在错周期面板上」的可发布版本。核实后发现该缺陷**今天 main 上就存在**（退出画线模式即可竖滑切周期，渲染却按 `panelPosition` 过滤），且依赖方向是 **D32 依赖 D29、而非互相依赖** → D29 前移至 **1a-i**。
>
> - **R15 / R16**：为修「选择态被 `updateUIView` 冲掉」「训练里两个画线入口」「选中态没有渲染契约」「画线模式按面板互斥与单顶栏钮不相容」，把 D26 / D39 / D41 / D42 塞进了原 1a-ii。
> - **R17-high**：原 1a-ii 因此横跨 UI / 状态归属 / 跨面板路由 / 旧入口退役四个面。沿「**改不改 UI**」切开为 **1a-ii（只搬状态，入口不变）** / **1a-iii（动 UI）**，原手势 PR 顺延为 **1a-iv**。<br>　*注：codex 建议「先退役浮动钮 + 搬状态，再上底栏」——照做会让中间那个 PR 的训练模式**一个画线入口都没有**。退役必须与新入口同期，故 D26 锁死在 1a-iii。*
>
> **顺序不可乱**：1a-iii 的设置面板改的样式，要靠 1a-i 的渲染迁移才画得出来，也要靠 1a-ii 的连续画线才有意义；1a-iii 单独 ship 时画线模式仍会吞掉平移（**这就是今天浮动钮的行为，不算回归**），由 1a-iv 解开——而 1a-iv 让画线模式首次能切周期，其正确性依赖 1a-i 已经就位的周期绑定判据。
>
> - **R12-high**：1b（~600 行）与 P1c（~1400 行）仍超「≤3 子项 / ≤500 行」。1b 沿「有没有**原地改线**」的缝再切：删除会改数组长度（现有 count 触发够用），改样式 / 锁定 / 撤销都是原地改线（必须带 D30）→ **1b-i**（选中 + 删除 + 改选中线样式 + D30）/ **1b-ii**（锁定 + 撤销 / 前进）。**P1c 不在本 spec 拆**（见 §8）。
>
> **1a-i 在模拟器里几乎没有可见变化**：默认色映射到现有橙色、线宽不变；**唯一可见的行为改变是修好了「线留在错周期面板」这个既有 bug**。「能设样式」与「能画出样式」是一对，拆开必有一半不可见——这是切分的必然代价，已向用户说明并获决断。

---

## 1. 拆分结论（决策表）

| 决策 | 结论 | 理由 |
|---|---|---|
| **D23 六段切分线** | **1a-i　渲染层正确性**（~350 行）= D35 `DrawingTool` API 迁移 + `HorizontalLineTool` 消费样式 + 射线 / 价格标注几何 §5.1 + D36 色彩解析 + **D29 周期绑定渲染（含同周期 fail-safe）**。<br>**1a-ii　状态与会话**（~250 行）= D39 共享状态容器（删 Coordinator 自动 re-arm）+ D42 全局画线会话（退役按面板互斥）+ 连续画线。**入口仍是浮动钮，不引入任何新 UI 控件。**<br>**1a-iii　外壳与设置**（~400 行）= 画线模式外壳 §2 + 两行底栏骨架（D24）+ 长按设置面板 §3 + **同期**退役训练 / replay 的浮动钮（D26）。<br>**1a-iv　手势**（~200 行）= D32 手势最小改动（§14 除节点拖动分支）+ D31 同 period 钩子。<br>**1b-i　选中与删改**（~400 行）= 底栏 ③🗑 + D38 画线态 / 选择态 + D41 选中态共享并进渲染 + 选中（D33 / D34 / D37 / D40）+ 删除 + 设置面板作用于选中线 + D30 内容级 dirty 信号。<br>**1b-ii　锁定与撤销**（~250 行）= 底栏 ②🔒④↩⑤↪ + 锁定 / 解锁 + 撤销 / 前进（D25）。<br>**（后续 epic「P1c」不列入本序列）**：多锚泛化 §5.0 + 节点模型与拖节点 §6 + §14 剩余的节点拖动分支 + 四个工具。~1400 行 / 五个风险面，**不是一个已授权的 PR 边界**；进入其 plan 阶段前必须先按同样方法拆分（见 §8）。 | **i↔ii 的缝**：i 只改**渲染 / 命中层**（让样式抵达渲染层、让渲染判据正确），不碰任何状态归属；ii 只改**状态归属与会话模型**，不引入任何新 UI 控件。两者的失败面完全不交叠。<br>**D29 为何落 i（codex R10-high）**：「线留在错周期的面板上」是**今天 main 上就存在的缺陷**——退出画线模式后仍可竖滑切周期，而 `RenderStateBuilder` 按 `panelPosition` 过滤。它不是后续 PR 引入的回归，但只要新入口让画线更显眼，就不该再拖。依赖方向也支持前移：**D32 依赖 D29，D29 不依赖 D32**。<br>**ii↔iii 的缝（codex R17-high）**：R15 / R16 把 D26（退役浮动钮）、D39 / D41（状态搬家）、D42（全局会话）都塞进了原 1a-ii，使它横跨 UI / 状态归属 / 跨面板路由 / 旧入口退役四个面。沿「**改不改 UI**」切开：ii 只搬状态（入口不变），iii 才动 UI。<br>**退役浮动钮为何必须与新入口同期**：codex 建议「先退役 + 搬状态，再上底栏」，照做会让中间那个 PR 的训练模式**一个画线入口都没有** = 功能回归。故 D26 的退役锁死在 iii。<br>**iii↔iv 的缝**：iii ship 后画线模式仍会吞掉平移与切周期——**这正是今天浮动钮模式的行为**，不是回归。iv 才解开。<br>**iv 两条为何捆一起（R3 / R4-high）**：D32 让画线模式**首次能切周期**，而多锚采集期一旦能切周期就必须 fail-closed 取消 pending（D31）；D31 的钩子在 D32 之前无从触发。<br>**iv↔1b-i 的缝**：iv 之前不存在**原地修改已有线**的能力，新画线走 append、数组长度变，现有 count 触发即正确。1b-i 引入「选中 + 改选中线的样式」——第一次原地改线，故 D30 与它同期。<br>**1b-i↔1b-ii 的缝（codex R12-high）**：1b-i 的删除会改数组长度，现有触发本就够用；1b-ii 的锁定 / 撤销全是原地改线，直接复用 1b-i 已建立的 `drawingsRevision` 通道。两者验收面完全不交叠。 |
| **D24 底栏骨架一次定型，控件按期填充**（骨架落 1a-iii） | **1a-iii**（不是 1a-ii）按母 spec §2 建**两行常驻栏**（高度 / 图标尺寸 / 升起落下动画一次定型）。**但每一期只渲染该期已落地的控件**：<br>• **1a-iii / 1a-iv**：上行类型行只有水平线 1 个图标；下行**只有 ①类型键**（收 / 展类型行）。<br>• **1b-i**：下行补 ③删除。<br>• **1b-ii**：下行补齐 ②锁定 ④撤销 ⑤前进，成为母 spec §2 的 5 键。<br>• **P1c**：类型行填满 5 个图标。<br>• **P5**：复盘补第 ⑥ 隐藏键。 | 母 spec **D19 / D22**：不得 ship 死控件 / 死图标。若 1a 就画出 5 键而 ②–⑤ 恒灰（因为「选中」尚未实现，连判据都不存在），那是四个**未接线**的按钮——正是 D19 禁止的东西。「只显示已落地控件」是 D22 对类型行图标的既有做法，此处**对称套用到底栏键位**。骨架（两行、高度、动画）一次定型，故布局不会二次返工。 |
| **D25 撤销语义**（1b-ii） | 撤销栈**深度 1**（母 spec §7 已定「各仅一步」）。**入栈动作 = 画线 / 删线 / 改样式 / 锁定·解锁**。做了新动作 → 前进（↪）置灰。**进画线模式时建栈，退出画线模式时清空**。 | 画线模式是一个有界的编辑会话，退出即提交。跨模式保留会让用户在交易了几十个 tick 之后意外撤销掉一条线；且跨模式保留会立刻牵出「撤销栈要不要随 autosave 落盘 / 断点续局后 ↩ 是否还灵」的新决策面，与本阶段无关。 |
| **D26 复盘过渡（限定于 UI 外壳）+ 训练 / replay 退役浮动钮**（退役落 1a-iii，**必须与新入口同期**） | 新两行底栏**只在训练 / 再次训练（replay）出现**。**复盘模式的画线「入口与控件」完全不动**，继续使用现有 `DrawingToolFloatingView` 浮动铅笔钮，交互一字不改。P5 时复盘切到 6 键新底栏，届时删除 `DrawingToolFloatingView`。<br>**1a-iii 起，`DrawingToolFloatingView` 只在复盘渲染（codex R15-medium）**：`TrainingView.swift:69` 现为 `showsDrawingTools = showsTradeButtons || engine.flow.mode == .review`，训练 / replay **今天就显示浮动钮**。否则会 ship 出两个画线入口，老入口绕过新的底栏 / 设置面板语义，还保留着「画一条就退出」的旧行为（D38 正要消灭它）。<br>**但绝不能直接把 `showsDrawingTools` 改成 `flow.mode == .review`（codex R22-high，交易安全）**：该谓词被**复用**在两处——`:186` 的浮动钮，与 **`:423-425` 的 activePanel 红色高亮边框**。而买 / 卖 / 持有全部按 `activePanel` 下单。直接改会在训练 / replay 里**连带抹掉「当前对哪个面板下单」的唯一视觉提示**，显著提高下错面板的风险（且 autosave 后不可逆）。<br>**必须拆成两个谓词**：<br>　• `showsFloatingDrawingTool` = `engine.flow.mode == .review` —— 只管 `DrawingToolFloatingView`。<br>　• `showsActivePanelHighlight`（保留原语义 `showsTradeButtons || engine.flow.mode == .review`）—— 只管 activePanel 高亮。<br>**回归测试**：训练 / replay **不再渲染 `DrawingToolFloatingView`，但 activePanel 高亮边框仍在**；复盘两者都在。<br>**边界澄清（codex spec-R2-medium / R4-high）**：D26 只管**画线模式的入口与控件**。**渲染（D29）与手势编排（D32）都是全局引擎行为，在复盘的浮动钮画线模式下同样生效**。 | 母 spec D19：复盘专属控件（隐藏键、复盘删除、hiddenIds 持久化、clear-saved）全在 P5。若让浮动钮退役而复盘又不上新底栏 → 复盘失去画线入口 = **功能回归**。若复盘上 5 键新底栏 → 其中 🔒/🗑 在复盘必须置灰（复盘删除属 P5、原训练线按母 spec §7 只可隐藏/显示）= **死控件**，两者都不可接受。 |
| **D27 选中态视觉**（1b-i） | 选中态 = **线渲染为选中蓝 + 底栏 🗑/🔒 由灰变亮**，**不显节点圆**。P1c 补上两端 / 各转折点的实心圆节点。 | mockup「选中态」屏（`2026-07-03-drawing-tools-expansion.html`）画的是「线变蓝 + 带蓝外圈实心圆节点 + 🗑高亮」。D23 把节点推后，故本期 = 该视觉去掉圆点。选中反馈仍然完整可见（线变色 + 底栏键活化）。 |
| **D28 契约不动 + `CONTRACT_VERSION` 语义澄清** | **六个 PR（1a-i / 1a-ii / 1a-iii / 1a-iv / 1b-i / 1b-ii）与后续 epic P1c 均为纯 UI / 渲染层：零迁移、不 bump `CONTRACT_VERSION`（保持 `1.11`）、`user_version` 保持 `7`。**<br>**`CONTRACT_VERSION` 只覆盖持久化契约**（DB schema + 落盘 JSON 序列化形状），**不覆盖 Swift 源码 API 面**。故 D35 对 `DrawingTool` 协议的源码级破坏性修改**不触发 bump**。 | 见 §1.1 逐形状持久化举证。<br>**`CONTRACT_VERSION` 语义（codex spec-R9-medium 追问，此前从未写下）**：`Models.swift:6` 指向 `docs/contracts/contract-version-matrix.md`，但**该文件在仓库里不存在**（`git ls-files` 无匹配，悬空引用；本 spec 不修，仅记录）。按实际证据定性：每次 bump 都伴随 schema 迁移（P1a 的 1.10→1.11 配 migration 0009），版本号的用途是**检测跨版本数据错位**。<br>`DrawingTool` 是**进程内渲染 / 命中协议**：不参与任何持久化、不跨进程、不上网络、不进 JSON；`KlineTrainerContracts` 也**没有仓外消费者**（仅本仓 SPM 内部依赖）。改它**不产生任何版本错位风险**，且 Swift 编译器会强制所有 conformer / mock / 调用方同 PR 更新（源码破坏 = 编译失败，不存在"测试通过但下游行为错"的静默路径）。<br>**要求**：D35 的迁移必须在**同一个 PR 内**更新全部 conformer 与测试替身，**不留兼容 shim、不留旧签名重载**（留 shim 才会制造 codex 担心的"编译过但走错分支"）。<br>**零迁移的核心依据**：**`DrawingObject.anchors` 是变长数组 `[DrawingAnchor]`**，`drawings` 表以单列 `anchors TEXT NOT NULL` 存整个锚数组的 JSON，任意锚数都能无损往返；其余 18 字段（`id` / `period` / `lineSubType` / `lineStyle` / `thickness` / `colorToken` / `labelMode` / `locked` / `text` / `fontSize` / `textColorToken` / `textForm` / `tailAnchor`）已由 P1a 全部落地，迁移 0009 已随 1.11 ship。 |
| **D29 周期绑定全局生效（含复盘）+ 同周期双面板 fail-safe**（**1a-i**，且不得晚于 D32） | `RenderStateBuilder` 的过滤判据改为 `drawing.period == 该面板当前显示的周期`，**对训练 / replay / 复盘三种模式一视同仁**，复盘的两层（只读原训练线 `engine.drawings` + 复盘新画线 `engine.reviewDrawings`）都按新判据过滤。叠加现有 `drawing.revealTick <= tick` 渐显规则不变。<br>**fail-safe 平局规则（codex R14-high，不可省）**：当 **`upperPanel.period == lowerPanel.period`** 且二者都等于 `drawing.period` 时，**退回用 `panelPosition` 定归属**（`panelPosition == 0` → 上面板，`== 1` → 下面板），保证**一条画线在任何状态下都只渲染在一个面板**。正常状态下两面板周期必不相同，该分支不触发。<br>除此之外 `panelPosition` **不参与渲染判据**（仍记录当时面板，作兼容 / 派生）。 | codex spec-R2-medium 指出 `RenderStateBuilder.swift:67` 是三模式共用的**单条过滤**。备选「复盘继续走 `panelPosition` 直到 P5」会造成：同一条线在训练里跟周期走、进复盘又跳回按面板位置 = 用户可见的错位，且需要一条模式条件渲染分支（更多代码、更多 bug 面）。母 spec **D1** 已定「画线绑定 period 非 panelPosition」——这是画线的**渲染属性**，不是模式特性。<br>**老数据安全性举证**：finalized 记录里的 legacy 行（0009 回填、`style_json IS NULL`）走 `DrawingStyle.legacyFallback(isExtended:period: anchors.first?.period ?? .m3)`（`RecordRepositoryImpl.swift:213`）；`DrawingObject.init` 的 `period` 默认取 `anchors.first?.period ?? .daily`（`Models.swift:269`）。故**历史画线一律带正确 period**，周期绑定对老记录成立。<br>**fail-safe 的必要性（codex R14-high，已核实为真）**：`TrainingEngine.periodCombos`（`:370-372`）的五个组合上下周期都不同，`switchPeriodCombo` 只从该表取值，故**正常运行时 `upper != lower`**。但该函数自己的注释写着「当前组合不在序列（**损坏 resume 数据**）→ no-op」——作者已承认 `upper == lower` 是可达的持久化状态；引擎构造器也不拒绝相等的 `initialUpperPeriod / initialLowerPeriod`。今天按 `panelPosition` 过滤时，即使 `upper == lower`，一条线也只画在一个面板；改成**纯 `period` 过滤后同一条线会同时渲染在上下两个面板**，随后的选中 / 删除会作用在一个**没有面板归属的重影**上。本 App 可能公开上架，跨版本数据错位真会发生，故必须 fail-safe。<br>**为何用 `panelPosition` 兜底而非「构造 / resume 时拒绝相等周期」**：后者要动构造器与 resume 规范化路径，是独立的决策面（拒绝？归一化？走 `.dbCorrupted` 恢复？），且会波及既有测试（现有测试确实构造过 `initialUpperPeriod == initialLowerPeriod` 的引擎）。兜底规则只落在 `RenderStateBuilder` 一处、纯函数可测、不改任何持久化行为。<br>**归属**：D29 落 **1a-i**。「线留在错周期面板」是 main 上的既有缺陷（退出画线模式后即可竖滑切周期，渲染却按 `panelPosition` 过滤），非本 RFC 引入；但它是可见的错误几何，且 D29 只改一处判据，不应拖到第三个 PR。依赖方向：D32 依赖 D29，反之不然。 |
| **D30 内容级 dirty 信号（两处，缺一不可）**（1b-i） | **① 视图触发**：把 `TrainingView` 的存盘触发从 `.onChange(of: engine.drawings.count)` 改为 `.onChange(of: engine.drawingsRevision)`。`TrainingEngine` 新增单调计数器 `public private(set) var drawingsRevision: Int`，**任何**改动 `drawings` 的引擎 API（append / delete / **原地替换（改样式、锁定）** / undo / redo）都 `+1`。<br>**② replay clean-skip 判据**：`TrainingSessionCoordinator.replayBaseline` 元组（现为 `(tick, ops, drawings: Int, upper, lower)`，`:56`）**追加 `drawingsRevision: Int`**，在 `:581` / `:934` 快照 count 的同一处一并快照；`saveProgress` 的 clean-skip 判据（`:607-610`）**追加 `base.drawingsRevision == engine.drawingsRevision`**。 | codex spec-R2-high + **R4-high**（两条均**已核实为真**）。<br>**① 的必要性**：现触发是 `TrainingView.swift:273` 的 `.onChange(of: engine.drawings.count)`。1a-iii 及之前画线只有增 / 删两种操作，按 count 触发正确；**1b-i 首次引入原地改一条线**（改选中线的样式），**数组长度不变 → 不触发 autosave**。<br>**② 的必要性（只改 ① 不够）**：`saveProgress` 对**尚未拥有槽的 fresh replay 会话**做 clean-skip（`replayHasPersisted == false` 时，`:603-610`），判据是 tick / ops / **drawings 条数** / 上下周期全等于基线。在一局新开的 replay 里选中一条已有的线只改颜色 → 四项全等 → **`saveProgress` 提前 return、不写盘** → 杀进程后改动丢失。onChange 照常触发了 autosave，写盘却被跳过。<br>**不得**改用 `.onChange(of: engine.drawings)` 或数组值比较：`DrawingObject.==` 刻意**排除 `id`**（P1a 决策，id 是身份非内容）。单调计数器是唯一无歧义的信号。<br>**基线快照时机**：必须在引擎完成画线种子注入**之后**取 `drawingsRevision`，与现有 count 快照同点同时。<br>`reviewDrawings` 的 `.count` 触发**保持不变**（P1b 不引入复盘内的原地编辑；P5 引入隐藏 / 删除时同法处理）。 |
| **D32 画线模式手势最小改动**（1a-iv） | 母 spec §14 中，**除"起手落在选中线节点上 → 节点拖动"这一分支外**的全部内容落 **1a-iv**：画线模式下 ①单指横滑=平移、②单指竖滑=切周期、③双指=缩放、④单击=落锚，四者共存不互吞。`panPolicyInDrawingMode` / `singlePanStep` 的 `drawingTakesOver` 早退路径必须改写。<br>**节点拖动分支**（起手命中节点 → 进入节点拖动）留 **P1c**，与节点模型同期。<br>**边界澄清**：D26 只管**画线模式的入口与控件**；手势编排（D32）与渲染（D29）一样是**全局引擎行为**，在复盘的浮动钮画线模式下同样生效。 | codex spec-R4-high（**已核实为真**）：`GestureClassifiers.swift:62` 的 `panPolicyInDrawingMode(drawingMode:)` 恒返回 `.drawingTakesOver`；`:113-122` 的早退分支直接 `return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)`——**平移与竖滑切周期一并被吞掉**。<br>故「1a 保证画线模式内平移 / 切周期可用」与「§14 全部推给 P1c」**自相矛盾**：实现者照 spec 推迟 §14，必然过不了 1a 的手势负向测试与验收条目，最终 ship 出一个**画线时无法平移图表**的模式。<br>**连锁结论**：今天画线模式根本切不了周期，故 **D31 的取消钩子在 arbiter 改动落地前无从触发**——D31 与 D32 必须同期落 1a-iv（D29 已在 1a-i 先行）。<br>备选「从 1a 移除该 UX 保证、记为临时回归」被否：画线模式下不能平移图表，用户无法把线画到屏幕外的位置，是不可接受的可用性缺陷。 |
| **D31 单条画线的所有锚必须同 period**（钩子落 1a-iv，与 D32 同期；混周期测试到 P1c） | **不变量**：一条 `DrawingObject` 的 `anchors` 数组里，**每个 `DrawingAnchor.period` 必须相同**，且等于 `DrawingObject.period`。<br>**执行（只在真的变了之后取消，codex R7-medium）**：`manager.pendingAnchors` 非空时，**仅当上 / 下面板周期组合发生了实际变化，或落锚面板发生了实际变化**，才**只丢弃 pending 锚**。<br>**必须用「只清锚、保留工具」的 API（codex R20-high）**：现有 `DrawingToolManager.cancel()`（`:76-80`）会**同时**清掉 `activeTool` 与 `pendingAnchors`。照字面调它，一次切周期 / 切面板就会把工具也熄掉——连续画线断掉、1b-i 的画线态被误置为选择态；且 1a-ii 已删除自动 re-arm，工具会一直停在 nil。故必须新增 `discardPendingAnchors()`（保留 `activeTool`），或显式改写并审计 `cancel()` 的语义。<br>**判据必须是"变化后 ≠ 变化前"，而不是"用户做了切周期手势"**：`switchPeriodCombo` 在边界（已是最高 / 最低周期）、当前组合非法、目标周期无数据时都会 **no-op 且不返回是否成功**。实现方式二选一：① 让 `switchPeriodCombo` 返回 `Bool`（是否真的换了）；② 调用方在调用前后比较 `(upperPeriod, lowerPeriod)`。**禁止在手势回调处无条件 cancel。**<br>**兜底**：`commit` 前断言全锚同 period，不同则拒绝提交并 `discardPendingAnchors()`。<br>**1a-iv 即落地**该取消钩子与断言（水平线单锚触发不到，但钩子与测试先就位，**含 no-op 边界不误杀 pending 的测试**，以及**取消后 `activeDrawingTool` 仍非 nil** 的测试）；**P1c 的 trend / channel / polyline 必须带混周期尝试的测试**。 | codex spec-R3-high（**已核实为真**）。母 spec §2 要求画线模式内保留单指竖滑切周期；P1c 的多锚工具要点好几下才成一条。若第 1 锚落在 60 分、竖滑后第 2 锚落在 15 分，两锚的 `candleIndex` 属于**不同坐标系**，而 `DrawingObject.period` 只取 `anchors.first?.period`（`Models.swift:269`）→ 存下来的线几何上是错的，且经 autosave / finalize 固化后不可修复。<br>取消（而非"把后续锚换算到首锚周期"）的理由：换算需要跨周期 K 线索引映射，是 P4 吸附级别的复杂度，且用户意图本就不明；丢弃 pending 锚是唯一 fail-closed 且可解释的行为。 |
| **D33 命中平局规则：最上层优先（逆序遍历）**（1b-i） | **适用范围**：选中**只在训练 / replay 的画线模式内启用**；**复盘模式下 tap 恒不做 hitTest**（复盘仍是旧浮动钮模式，无选中 UI，D26）。故 1b-i 的命中集合 = `engine.drawings`（此时 `engine.reviewDrawings` 恒为空）。<br>**规则**：按渲染数组**逆序遍历**，**第一个 `hitTest` 命中的即为选中项**，立即返回其 `id`，不再继续遍历。<br>**语义**：数组靠后 = 后绘制 = 盖在上面 = 用户看见的那一条 = 被选中的那一条。**新画的线恒在最上层**（append 到尾部）。<br>**1b-i 不做**选中循环（连点同一处轮换命中项）：1b 只有单层同类线，被完全覆盖的线在视觉上本就不可见；删掉上层那条后下层即可命中。**记为 1b-i 的已知限制**（几何在容差内但视觉上可区分的两条线，只能选中上面那条）。<br>**P5 必须做选中循环 + `(层, id)`**：见 D34 / §9。 | codex spec-R5-high（**已核实为真**）。原文只写「遍历所有可见画线逐个 `hitTest` 命中」而未定遍历方向与平局规则，却在验收里要求「两条价格完全一样的水平线，选中其中一条改颜色 → 只有被点中的那一条变色」——**这是一道无解题**：几何完全重合时 `hitTest` 无法区分意图，正序遍历会命中数组里靠前那条，而用户看见的是靠后那条盖在上面。改样式 / 锁定 / 删除会作用到**错误的线**，而 UI 只显示一条被选中。<br>逆序遍历使「选中 = 视觉上最上面那条」成为可判定且与渲染一致的规则。`KLineView+Drawing.swift:16-26` 按数组顺序绘制，后绘制者覆盖先绘制者，故逆序 = 自顶向下。 |
| **D34 复盘选中留 P5，且 1b-i 必须显式门控**（1b-i 负向要求） | **1b-i 不得让复盘获得选中能力。** `ChartContainerView` 的 tap 处理是三模式共用的；1b-i 在其中加入「命中优先于落锚」时，**必须以 `engine.flow.mode != .review` 门控 hitTest 分支**，并加负向测试断言：复盘模式下单击一条原训练线**不产生选中、不改样式、不删除**。<br>**P5 落地复盘选中时，选中态必须扩展为 `(layer, id)` 二元组**（`layer ∈ {original, review}`），并按层门控操作：`original` 层只可隐藏 / 显示，`review` 层才可改样式 / 锁定 / 删除（母 spec §7 逐字）。届时 D33 的逆序遍历作用在 `engine.drawings + engine.reviewDrawings` 拼接数组上，天然使复盘新线优先于原训练线。 | codex spec-R7-high（**已核实为真**，且比其描述更根本）。母 spec §7 明写命中「返回 (层, id)」，因为复盘下原训练线与 `reviewDrawings` **权限不同**：原训练线只读 / 可隐藏，复盘新线可编辑 / 可删。<br>但 1b-i 的复盘**根本没有选中 UI**（D26：复盘仍是浮动钮）。真正的风险是：`ChartContainerView` 的 tap 路径三模式共用，若 1b-i 在此加 hitTest 而不门控，**复盘会意外获得选中能力且无层门控** → 用户可能改样式 / 删除掉**已归档记录里的原训练线**。这是 trust-boundary 级别的缺陷（写入 committed record）。<br>故：1b-i 用 id-only 选中是安全的**当且仅当**复盘被显式门控在外；`(layer, id)` 与层权限门控随复盘选中一并落 P5。 |
| **D35 `DrawingTool` 渲染 / 命中 API 迁移**（**1a-i**，全链先决） | 现协议只传锚点：<br>`func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])`<br>`func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool`<br>（`Drawing/DrawingTool.swift:18-19`）<br>**1a-i 必须迁移为传入整个 `DrawingObject` + 主题**，例如：<br>`func render(ctx:mapper:drawing:theme:)` / `func hitTest(point:mapper:drawing:) -> Bool`<br>并同步改 `KLineView+Drawing.swift:16-26` 的 dispatch 循环、`KLineView.drawingTools` 工具表、以及全部 mock / 测试替身。<br>**必须有一条 dispatch 测试**：两条样式不同的画线经 dispatch 后，renderer 收到的样式入参**各不相同**（证明样式真的抵达渲染层，而不是被 dispatch 丢弃）。 | codex spec-R8-high（**已核实为真**）。1a-i 要求 `HorizontalLineTool.render` 消费 `colorToken / lineStyle / thickness / labelMode / lineSubType`，但生产 dispatch 只把 `anchors` 递进去。不改协议的话，实现者可以把样式**成功持久化**、渲染却依然是写死的橙色 1.5pt，或被迫用全局可变状态传样式（更糟）。<br>**连带缺陷（本轮自查发现，codex 未提）**：`hitTest` 同样只收 `anchors`。**射线**只从落点向右延伸，而 `|point.y - lineY| ≤ 容差` 的判据会让**落点左侧的整条横线也命中**。故 `hitTest` 必须一并迁移为接收 `DrawingObject`（至少要读 `lineSubType` 与 `anchors[0].candleIndex`），否则 1b-i 的选中在射线上就是错的。<br>这是**全链先决改动**：1a-i 的样式渲染与水平线射线几何都依赖它。 |
| **D36 `colorToken` 主题解析的不变量**（1a-i） | **7 个彩色 token（赤 / 橙 / 黄 / 绿 / 青 / 蓝 / 紫）的 RGBA 与主题无关**，昼夜解析结果相同。其中 **`.orange`（默认色）在昼夜两套主题下都必须解析为 legacy RGBA `(0.82, 0.40, 0.0)`**。<br>**只有 `.black` / `.white` 两个 token 是主题相关的**：白天的 `.white` 与夜间的 `.black` 会与背景同色不可读，解析器必须给出可读的替代色。<br>**测试分工**：视觉零变化断言（默认色 == legacy 橙、线宽 == 1.5pt）**在昼夜两套主题下都要跑**；「昼夜解析出不同 RGBA」的断言**只施加于 `.black` / `.white`**。 | codex spec-R10-medium（**我自己写的自相矛盾**）。原文既要求 1a-i「默认样式渲染结果等于迁移前常量、视觉零变化」，又要求「同一 `colorToken` 在昼 / 夜下解析出不同 RGBA」。现有水平线颜色是**主题无关**的常量，两条不可能同时成立：把默认橙做成主题相关会让某一套主题下的既有画线变色（破坏零变化这一安全网），保持相同则过不了后一条测试。<br>母 spec §4.2 所说「昼夜可读性由主题解析」，真实约束只落在**与背景同色的黑 / 白**上；彩色 token 在昼夜两套背景下都可读，无需变色。UI 层的「白天禁白、夜间禁黑」是**禁选**（1a-ii），解析器仍须能渲染历史数据里已存下的黑 / 白。 |
| **D38 画线态 / 选择态由 `activeDrawingTool` 决定（类型行图标是 toggle）**（1b-i 引入） | **`activeTool != nil`（类型行图标亮着，浅蓝框）→ 画线态**：画线模式内单击**一律落锚**，**不做 hitTest**。可以在任意位置画线，**包括与已有线完全重合的位置**。<br>**`activeTool == nil`（图标熄灭）→ 选择态**：单击**做 hitTest 选中**（D33 逆序遍历），未命中则清空选中。<br>**类型行图标是 toggle**：点亮 = 进画线态；再点一次熄灭 = 进选择态。<br>**1a-iii 阶段**：尚无选中可做，故图标**恒亮不做 toggle**；toggle 在 **1b-i** 随选中一并引入。<br>**连续画线**：提交一条线后 `activeTool` **保持不变**（不再置 nil、不再退出画线模式），以支持母 spec §3「用当前 / 默认设置连续画」。 | codex spec-R13-medium（**已核实为真，且是本 spec 的自相矛盾**）。原文规定 1b-i「单击先 hitTest，未命中才落锚，命中优先于落锚」。于是**一条水平线存在后，在同一价位再单击只会选中它，永远画不出第二条重合的线**——而 1b-i 的验收第 11 条恰恰要求用户「先画绿线、再在完全一样的价位画黄线」，该验收在真实 UI 路径上**不可能通过**。真实用户也确实需要在命中容差内叠画第二条线。<br>母 spec §2 把「单击 = 落锚 / 选中」写成一件事，本就有歧义。以 `activeTool` 分态是文华财经 / TradingView 的通行做法，无需引入修饰手势或长按路径，且与类型行已有的「选中态浅蓝框」视觉天然对应。<br>**连带修正（现存代码）**：`DrawingToolManager.commit()` 现会 `activeTool = nil`，`ChartContainerView` 随后调 `engine.commitDrawing(panel:)` 退出画线模式——即今天「画一条就退出」。连续画线在 **1a-ii** 改掉这两处。<br>**D37 因此简化**：画线态下压根没有选中，「落锚顺手改到选中线」的歧义从结构上消失。 |
| **D37 选中态的转移与生命期**（1b-i） | **画线态**（`activeTool != nil`）：单击恒落锚，**不产生也不清除选中**（画线态下选中恒为空）。<br>**选择态**（`activeTool == nil`）：单击命中 → 选中它（替换原选中）；单击**未命中 → 清空选中**。<br>**新提交的线不自动选中**。<br>其余清空时机：退出画线模式、从选择态切回画线态、选中线因切周期 / 切面板而不可见、选中线被删除。每次清空后 🗑 回灰。 | codex spec-R10-medium（**已核实为真**）。原文只列了「退出 / 不可见 / 删除」三种清空时机，又规定「未命中 → 落锚」且「有选中时设置面板作用于选中线」。于是：选中 A → 点空白处画出 B → **A 仍处于选中态** → 用户接着改样式 / 删除，作用的是 **A 而不是刚画的 B**，且屏幕上 A 仍是蓝的，极易误操作。<br>D38 引入画线态 / 选择态之后本条进一步简化：两态互斥，画线态下根本不存在选中。 |
| **D39 画线 / 选择状态的单一真相，且退役 Coordinator 的自动 re-arm**（1a-ii） | **`activeDrawingTool: DrawingToolType?` 必须是底栏与 `ChartContainerView.Coordinator` **共同消费**的单一真相**（落在 `TrainingEngine` 或一个共享的画线 view-model 上），**不得**继续留在 Coordinator 私有的 `DrawingToolManager` 里。<br>**必须删除** `ChartContainerView.swift:107` 的自动 re-arm：`if manager.activeTool == nil { manager.toggle(.horizontal) }`。`sync()` 改为**单向从真相同步到 manager**（manager 退化为纯 pending-anchor 暂存）。<br>**测试要求**：`activeTool == nil`（选择态）必须**熬过一次完整的 SwiftUI render / update pass** 后仍为 nil，然后那一次 tap 才做 hitTest。**不得**只在测试里直接给 manager 赋值——那样测不出 update-cycle 回归。 | codex spec-R15-high（**已核实为真，且后果严重**）。`ChartContainerView.swift:59` 的 `private let manager = DrawingToolManager(enabledTools: [.horizontal])` 是 **Coordinator 私有**的；`:98-109` 的 `sync()`（每次 `updateUIView` 都会调）写着 `if manager.activeTool == nil { manager.toggle(.horizontal) }`——只要引擎面板处于 drawing 模式，`activeTool` 就会被**重新点亮**。<br>于是 D38 的「点熄类型行图标 → 进选择态」在**下一次 SwiftUI 刷新时被自动撤销**：用户想选中的那一下 tap 变成「又画一条重合的线」。这是用户可见的严重错误（选中 / 删除 / 改样式全部失效），且**在测试里直接给 manager 赋状态根本复现不出来**——必须有一条跨 update pass 的端到端测试。<br>底栏在 `TrainingView` 里，`manager` 在 Coordinator 里，两者之间今天没有任何通路：底栏既观察不到也设置不了 `activeTool`。故 D38 若不改状态归属就无法实现。 |
| **D40 命中集合 ≡ 渲染可见集合（含 D29 fail-safe）**（1b-i） | 选中的 `hitTest` **必须消费与 `RenderStateBuilder` 完全相同的「该面板可见画线集合」**——同一个判据、同一个 fail-safe、同一个 `revealTick` 过滤。**必须抽成一个共享的纯函数**（如 `visibleDrawings(for:panel:engine:tick:)`），渲染与命中**都调用它**，不得各写一遍。<br>**顺序契约（codex R20-medium）**：该函数**返回渲染序**（数组靠后 = 后绘制 = 盖在上面）。**渲染原样消费**；**命中方自己 `.reversed()` 遍历**（D33 最上层优先）。**函数本身绝不返回逆序**——否则渲染会把老线画在上面，或让 D33 的「同一逆序顺序」变成假命题。<br>**测试要求**：① 在 `upperPanel.period == lowerPanel.period` 的损坏态下，`panelPosition == 0` 与 `== 1` 各测一次——**点击某个面板只能选中 / 删除渲染在该面板上的那条线**，绝不能命中另一面板的同周期线。② **z-order 一致性**：两条重合线，断言**后画的那条渲染在上面**（dispatch 顺序靠后）**且**正是被选中 / 被编辑的那一条。 | codex spec-R15-medium（**已核实为真**）。D29 为 `upper.period == lower.period` 的损坏 / 版本错位态加了 `panelPosition` fail-safe，保证一条线只**渲染**在一个面板；但 1b-i 原文只说「对该面板当前周期所有可见画线做 hitTest」，**没有要求复用同一判据**。<br>后果：在同周期双面板态下，纯 `period` 的命中判据会让用户点击上面板时**选中并删除一条只渲染在下面板的线**——一条他在这个面板上根本看不见的线。fail-safe 就退化成「只糊在渲染层的补丁」，而编辑操作仍作用在隐藏的重影上。<br>把可见性判据抽成单一纯函数，是让「所见 == 可选」这条不变量**在结构上成立**而非靠两处代码巧合一致。 |
| **D41 画线共享状态容器（`activeDrawingTool` + `selectedDrawingID` 同源）**（容器落 1a-ii；`selectedDrawingID` 落 1b-i） | D39 引入的单一真相**扩为一个容器**（落 `TrainingEngine` 或共享画线 view-model），至少含：<br>• `drawingModeActive: Bool`（D42）<br>• `activeDrawingTool: DrawingToolType?`（D38 / D39，1a-ii）<br>• `selectedDrawingID: DrawingID?` + `selectedPanel: PanelId?`（1b-i）<br>**`selectedDrawingID` 必须流进渲染**：`RenderStateBuilder` 把它带进 `KLineRenderState`，`KLineView+Drawing` 的 dispatch 据此对那一条走**选中蓝**覆盖色（`DrawingTool.render` 的 D35 入参里加一个 `isSelected: Bool`，或渲染上下文携带 selected id）。<br>底栏（`TrainingView`）与 tap 处理（`ChartContainerView.Coordinator`）**读写同一个容器**，任何一方都不得私存一份。<br>**测试要求**：选中一条线 → **强制走一次 `updateUIView`** → 断言渲染出的仍是同一个 id 的选中态，且 🗑 / 设置面板作用的**也是同一个 id**。 | codex spec-R16-high（**已核实为真**）。`KLineRenderState`（`Render/KLineRenderState.swift`）里**根本没有 selected 概念**；而 1b-i 要求「命中后线渲染为选中蓝 + 🗑 变亮 + 设置面板 / 删除作用于选中线」。<br>tap 处理在 `ChartContainerView.Coordinator`，底栏与设置面板在 `TrainingView` —— 这正是 D39 里让 `activeDrawingTool` 被 `updateUIView` 冲掉的同一条裂缝。选中态若只存在其中一侧，就会出现「图表高亮着 A、底栏 🗑 删掉 B」或「刷新一次选中就没了」。<br>故 `selectedDrawingID` 必须与 `activeDrawingTool` 同源、且**必须进渲染状态**（否则渲染层无从知道哪条要画成蓝色）。 |
| **D42 画线会话是全局的，锚点归属由「被点击的面板」决定**（1a-ii） | 顶栏「画图」钮切换的是**全局** `drawingModeActive`，**不属于任何单一面板**。<br>**落锚时**由**被点击的那个面板**提供 `panel` 与 `period`（母 spec §2「上下两面板都能画」、§10「归属所画面板当前显示的周期」）。<br>**pending 锚归属首个落锚的面板**；在 pending 非空时点到另一个面板 → 按 **D31** `cancel()` 丢弃 pending（面板实际改变）。<br>**必须退役 / 重写「每一条」按 activePanel 作用域的画线取消路径**（codex R18-high）：<br>　• `TrainingEngine.toggleDrawingExclusive(on:)`（`:1078`：激活一个面板会 `cancelDrawingAllPanels()`）——它与「一个全局会话 + 两面板都能画」不相容。<br>　• **`TrainingView.swift:234-240` 的 `.onChange(of: activePanel) { … engine.cancelDrawingAllPanels() }`**——用户切一下**下单目标面板**就会把整个画线会话拆掉。<br>**切 activePanel 时的正确语义**：`drawingModeActive` 与 `activeDrawingTool` **保持不变**；**只有当 pending 锚非空且落锚面板实际改变时**才按 **D31** **只丢弃 pending 锚**（用 `discardPendingAnchors()`，**不是** `cancel()`——后者会连 `activeTool` 一起清掉，见 D31），**不得**拆掉整个会话。<br>**测试要求**：① 进入画线模式后在上面板画一条、在下面板画一条，两条都成功提交且各自带**所在面板当时的 period**；② **无 pending 锚时切 activePanel** → 画线模式与 `activeDrawingTool` **仍然存活**；③ **有 pending 锚时切 activePanel** → 只丢 pending 锚（D31），会话不倒。 | codex spec-R16-medium（**已核实为真**）。`toggleDrawingExclusive(on: panel)` 今天是**按面板互斥**的：激活一个面板会取消另一个。它服务的是旧的浮动钮模型（钮属于 activePanel）。<br>新外壳（1a-iii）只有**一个**顶栏「画图」钮，而母 spec §2 明确「上下两面板都能画」。二者今天对不上：实现者要么只激活 `activePanel`（点另一面板毫无反应），要么两个面板都激活（pending 锚该归谁、pan 手势该听谁的，全是含糊的）。<br>「全局会话 + 落锚时取被点击面板的 panel/period」是唯一与 §2 / §10 / D31 同时自洽的模型：D31 已经规定「pending 非空时落锚面板实际改变 → cancel」，正好覆盖跨面板落锚的歧义。<br>**codex R18-high 补充（已核实为真）**：只退役 `toggleDrawingExclusive` 不够。`TrainingView.swift:234-240` 的 `.onChange(of: activePanel)` 也会 `cancelDrawingAllPanels()`——该 observer 原本服务的是「切下单目标面板 → 取消未确认下单」（RFC-B），顺手把画线也取消了。全局会话下这会让用户**切一下下单目标就丢掉整个画线会话 / 正在收的锚**。而原测试只要求「在两个面板各画一条」，**不强制发生 activePanel 迁移**，故该回归能过测。 |

### 1.1 D28 举证：P1b 每个形状如何落进现有 1.11 契约

> **codex spec-review R1-high 专门质疑此点**（「通道线第三锚 / 折线任意顶点在 1.11 里没有对应的持久字段，声称零迁移站不住」）。以下为实证反驳，**任何后续 review 请先读此表再判**。

**契约事实（`96d2ac4` 树上可核）：**

| 事实 | 位置 |
|---|---|
| `public let anchors: [DrawingAnchor]` —— **变长数组**，非定长元组、非 `(a1, a2)` 两字段 | `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:238` |
| `DrawingAnchor = { period, candleIndex, price }` | `Models/Models.swift:201-203` |
| `drawings` 表列 `anchors TEXT NOT NULL` = 锚数组整体 JSON | `Persistence/Internal/AppDBMigrations.swift:54`（0009 重建后 `:225`） |
| 写：`let anchorsJSON = try jsonEncode(dr.anchors)` → 存入 `anchors` 列 | `Persistence/Internal/RecordRepositoryImpl.swift:62, 87-91` |
| 读：`try jsonDecode(anchorsJSON, as: [LossyAnchor].self)` → 还原任意长度 | `Persistence/Internal/RecordRepositoryImpl.swift:205` |
| `tailAnchor: DrawingAnchor?` 是**标注(text) 气泡尾巴尖专用的额外字段**，与几何锚数**无关**，其它工具恒为 `nil` | `Models/Models.swift:250`；母 spec §4.2 / D11 |

**逐形状映射：**

| 工具 | 几何锚数 | 存进 `anchors` 数组 | 需要新字段？ | 落在哪一期 |
|---|---|---|---|---|
| 水平线 horizontal | 1 | `[a0]` | 否 | 1a-i（几何升级） |
| 趋势线 trend | 2 | `[a0, a1]` | 否 | P1c |
| 通道线 channel | 3 | `[a0, a1, a2]`（a0/a1 定主线，a2 定平行线） | **否**——第三锚就是 `anchors[2]` | P1c |
| 箱体 rect | 2 | `[a0, a1]`（矩形对角） | 否 | P1c |
| 折线 polyline | N（不定） | `[a0, a1, …, a_{N-1}]` | **否**——数组本就不定长 | P1c |

**结论**：P1b 三期均不需要任何新列、新字段、新迁移；`anchors` 数组 + `toolType` 已足以无歧义地表达全部五个形状。`lineSubType / lineStyle / thickness / colorToken / labelMode / locked` 已在 `style_json` 列（0009 新增）里往返。**D28 成立。**

---

## 2. P1b-1a-i 交付范围：「渲染层正确性」（除周期绑定修复外无可见变化）

### 2.1 做

1. **D35 `DrawingTool` 渲染 / 命中 API 迁移（全链先决）**
   - 现协议只传锚点（`Drawing/DrawingTool.swift:18-19`）：
     `func render(ctx: CGContext, mapper: CoordinateMapper, anchors: [DrawingAnchor])`
     `func hitTest(point: CGPoint, mapper: CoordinateMapper, anchors: [DrawingAnchor]) -> Bool`
   - 迁移为传入整个 `DrawingObject` + 主题，如 `render(ctx:mapper:drawing:theme:)` / `hitTest(point:mapper:drawing:)`。
   - 同步改 `KLineView+Drawing.swift:16-26` 的 dispatch 循环、`KLineView.drawingTools` 工具表、以及**全部 mock 与测试替身**。
   - **不留兼容 shim、不留旧签名重载**（D28）。Swift 编译器强制所有 conformer 同 PR 更新。

2. **`HorizontalLineTool` 消费样式字段**
   - 现写死 `strokeRGBA = (0.82, 0.40, 0.0)` + `ctx.setLineWidth(1.5)`（`Drawing/HorizontalLineTool.swift:31-42`）。
   - 改为读 `DrawingObject` 的 `colorToken` / `lineStyle` / `thickness` / `labelMode` / `lineSubType`。
   - **默认值必须映射到今天的橙色 + 1.5pt**，使本 PR 在模拟器里**视觉零变化**（这是本 PR 的一条硬约束，也是它的安全网）。

3. **`colorToken` 主题解析（D36）**
   - **7 个彩色 token（赤 / 橙 / 黄 / 绿 / 青 / 蓝 / 紫）主题无关**，昼夜解析出同一 RGBA；其中 `.orange`（默认色）昼夜都必须是 legacy `(0.82, 0.40, 0.0)`。
   - **只有 `.black` / `.white` 主题相关**：白天的 `.white`、夜间的 `.black` 与背景同色不可读，解析器给出可读替代色。UI 层的「白天禁白、夜间禁黑」是**禁选**（1a-ii），解析器仍须能渲染历史数据里已存的黑 / 白。
   - 解析必须是 **host 可测的纯函数**（非 `View`、非 `@MainActor` 隔离）。

4. **水平线几何升级（母 spec §5.1）**
   - **直线**：全宽横线。**射线**：自落点向右到主图右缘。**无线段**。
   - **价格标注**：隐藏 / 左 / 右。标签**紧贴线上方、不压线**；射线时靠右缘，**防贵股 4 位整数价溢出**（裁剪或右对齐至主图右缘内）。
   - `hitTest` 必须按 `lineSubType` 分支：射线只在落点**右侧**命中。
   - 几何 helper 为 host 可测纯函数，沿现有 `CoordinateMapper` 风格。

5. **D29 周期绑定渲染（三模式一视同仁）**
   - `RenderStateBuilder.swift:65-68` 现按 `drawing.panelPosition == (panel == .upper ? 0 : 1)` 过滤 → **改为按 `drawing.period == 该面板当前显示的周期` 过滤**。
   - 该过滤是训练 / replay / 复盘**共用的同一行**（`engine.drawings + (mode == .review ? engine.reviewDrawings : [])`）。**新判据在复盘同样生效，不做模式门控**。
   - 叠加现有 `drawing.revealTick <= tick` 渐显规则**不变**。
   - 某周期不在上下任一面板显示 → 其画线暂不渲染，切回再现。
   - **fail-safe（D29，不可省）**：当 `upperPanel.period == lowerPanel.period` 且二者都等于 `drawing.period` 时，**退回用 `panelPosition` 定归属**（0 → 上，1 → 下），保证**一条画线在任何状态下都只渲染在一个面板**。正常状态下两面板周期必不相同（`periodCombos` 五个组合上下皆异），该分支不触发；但 `switchPeriodCombo` 自己的注释已承认「损坏 resume 数据」可让当前组合落在表外，构造器也不拒绝相等周期。
   - 除该 fail-safe 外，`panelPosition` **不参与渲染判据**（仍记当时面板，作兼容 / 派生）。
   - **这是本 PR 唯一可见的行为改变，且是修复既有缺陷**：今天退出画线模式后即可竖滑切周期，而渲染仍按 `panelPosition` 过滤 → 60 分画的线会留在已切成 15 分的面板上，坐标系已换、位置是错的。D32（1a-iii）依赖本条，反之不然。

### 2.2 P1b-1a-i 不做

画线状态搬家 / 全局会话 / 连续画线（1a-ii）；任何 UI（顶栏「画图」钮 / 两行底栏 / 设置面板、退役浮动钮，全在 1a-iii）；手势改动 / 同 period 钩子（1a-iv）；选中 / 编辑（1b-i / 1b-ii）。**除 D29 修复的错周期渲染外，本 PR 不改变任何用户可见行为。**

### 2.3 P1b-1a-i 必须存在的负向测试

1. **视觉零变化（昼夜两套主题都要跑，D36）**：用**默认样式**构造的 `DrawingObject`，在**白天主题**与**夜间主题**下渲染出的描边色与线宽**都等于迁移前的常量**（橙色 `(0.82, 0.40, 0.0)`、1.5pt）。
2. **D35 dispatch 举证**：两条**样式不同**的画线经 dispatch 后，renderer 收到的样式入参**各不相同**（证明样式真的抵达渲染层，未被 dispatch 丢弃或被写死值覆盖）。
3. **射线 hitTest 方向性**：一条 `.ray` 水平线，落点**右侧**同一 y 上的点**命中**，落点**左侧**同一 y 上的点**不命中**；同几何的 `.straight` 线两侧都命中。
4. **线宽 / 线型映射**：`thickness` 五档各自产出不同 `lineWidth`；`lineStyle` 的 `.solid` 无虚线 pattern、`.dash1…dash4` 四种 pattern 互不相同。
5. **昼夜色解析（D36，分工明确）**：`.black` / `.white` 在昼 / 夜下解析出**不同** RGBA，且白天的 `.white`、夜间的 `.black` 解析结果**可读**（不等于背景色）；**7 个彩色 token 在昼 / 夜下解析出相同 RGBA**。
6. **标注位置**：`.left` / `.right` 标签矩形不与线段矩形相交（不压线）；`.right` + 四位整数价时标签右边界 **≤ 主图右缘**。
7. **`.hidden` 标注**：不产出任何标签绘制调用。
8. **周期绑定（D29，含复盘）**：某周期不在任一面板显示时其画线不进 `RenderStateBuilder` 输出；切回后出现；`revealTick > tick` 的线仍不渲染；`panelPosition` **不再影响输出**（造一条 `panelPosition` 与 `period` 冲突的线，断言按 `period` 落到面板）。**必须同时覆盖复盘模式的两层**（`engine.drawings` + `engine.reviewDrawings`），并覆盖 `style_json IS NULL` 的 legacy 行（period 由 `anchors.first.period` 兜底）。
8b. **同周期双面板 fail-safe（D29，codex R14-high 专项）**：构造一个 `upperPanel.period == lowerPanel.period` 的引擎（损坏 / 版本错位 resume 的模拟），放一条该 period 的画线 → 断言它**只出现在一个面板的 `RenderStateBuilder` 输出里**（由 `panelPosition` 决定是哪个），**不得两个面板都渲染**。`panelPosition == 0` 与 `== 1` 两种情况各测一次。

### 2.4 P1b-1a-i 非程序员验收清单

> 本 PR 的设计目标是**除了修好一个既有 bug 之外看不出变化**。验收方式是"确认什么都没坏 + 那个 bug 修好了"。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进入训练，用现有的浮动铅笔钮画一条水平线 | 线的颜色、粗细**跟改造前一模一样**（橙色细线） | |
| 2 | 切到夜间模式再看这条线 | 颜色、粗细**仍跟白天一样**（默认橙色不随主题变） | |
| 3 | 退出 App 重进、续上这一局 | 线还在，样子没变 | |
| 4 | **【修复项】在上半面板（假设 60 分）画一条线，退出画线模式，竖滑切周期让 60 分挪到下半面板** | 那条线**跟着 60 分跑到下半面板**（改造前它会错误地留在上半面板） | |
| 5 | 继续切周期，让 60 分完全不显示 | 那条线暂时消失（改造前它会留在面板上、位置是错的） | |
| 6 | 切回来让 60 分重新显示 | 那条线重新出现，位置不变 | |
| 7 | 结束一局进复盘，在复盘里竖滑切周期 | 原训练线同样跟着周期走 | |
| 8 | 找一局改造前就存在的老记录，进它的复盘 | 老画线正常显示，位置不错乱 | |
| 9 | 在复盘里用浮动钮画线 | 行为跟改造前一样 | |
| 10 | 顶栏、底栏、图表 | **没有任何新按钮出现** | |
| 11 | 正常玩几局，反复切周期 | **上下两个面板永远不会同时显示同一条线** | |

---

## 3. P1b-1a-ii 交付范围：「画线状态搬家 + 全局画线会话」（入口不变）

> **入口仍是现有的浮动铅笔钮**（训练 / replay / 复盘三处都还在）。本 PR 不引入任何新 UI 控件。
> 可见变化只有两处，且都是修既有别扭：**不再「画一条就退出」**、**上下两个面板都能画**。

### 3.1 做

1. **画线共享状态容器（D39 / D41 的基座，先决）**
   - 建立底栏（未来）与 `ChartContainerView.Coordinator` **共同消费**的共享容器（落 `TrainingEngine` 或共享画线 view-model），本期含 `drawingModeActive: Bool` + `activeDrawingTool: DrawingToolType?`。`selectedDrawingID` / `selectedPanel` 在 1b-i 加入**同一容器**。
   - **删除** `ChartContainerView.swift:107` 的自动 re-arm（`if manager.activeTool == nil { manager.toggle(.horizontal) }`）；`sync()` 改为**单向从真相同步到 manager**，`DrawingToolManager` 退化为纯 pending-anchor 暂存。
   - 不搬家，1b-i 的类型行 toggle 会被每一次 `updateUIView` 撤销（codex R15-high）。

2. **画线会话全局化（D42）**
   - `drawingModeActive` 是**全局**状态，不属于任何单一面板。浮动钮本期改为切换它。
   - **落锚时由被点击的那个面板**提供 `panel` 与 `period`；上下两面板都能画（母 spec §2 / §10）。
   - pending 锚归属首个落锚的面板；pending 非空时点到另一面板 → 按 D31 **只丢弃 pending 锚**（`discardPendingAnchors()`，保留 `activeDrawingTool`）。**不得调 `cancel()`**（`DrawingToolManager.swift:76-80` 会连 `activeTool` 一起清掉）。
   - **退役 / 重写「每一条」按 activePanel 作用域的画线取消路径**：
     - `TrainingEngine.toggleDrawingExclusive(on:)`（`:1078` 会 `cancelDrawingAllPanels()`）——服务的是「钮属于 activePanel」的旧模型。
     - **`TrainingView.swift:234-240` 的 `.onChange(of: activePanel) { … engine.cancelDrawingAllPanels() }`**——它原本只为「切下单目标面板 → 取消未确认下单」（RFC-B）而存在，顺手把画线也取消了。
   - **切 activePanel 的正确语义**：`drawingModeActive` / `activeDrawingTool` **保持不变**；**仅当 pending 锚非空且落锚面板实际改变**时按 D31 只丢弃 pending 锚，**绝不拆掉整个会话**。

3. **连续画线（D38 连带修正）**
   - `DrawingToolManager.commit()` 现会把 `activeTool` 置 nil；`ChartContainerView` 随后调 `engine.commitDrawing(panel:)` **退出画线模式** —— 即今天「画一条就退出」。
   - 改为：提交一条线后 **`activeDrawingTool` 保持不变、`drawingModeActive` 不变**，支持母 spec §3「用当前 / 默认设置连续画」。

### 3.2 P1b-1a-ii 不做

任何新 UI 控件（顶栏「画图」钮 / 两行底栏 / 设置面板全在 1a-iii）；退役浮动钮（**必须与新入口同期**，1a-iii）；手势改动 / 同 period 钩子（1a-iv）；选中 / 编辑（1b-i / 1b-ii）。

**前置（已做）**：D29 周期绑定与 D35 API 迁移已在 1a-i 落地，本期不得回退。

### 3.3 P1b-1a-ii 必须存在的负向测试

1. **D39 状态单一真相**：连续触发多次 `updateUIView` / `sync()` 后，`activeDrawingTool` **不被自动改写**；`ChartContainerView` 里**不存在** `manager.toggle(.horizontal)` 这类 re-arm 调用。
2. **D42 双面板可画**：进入画线模式后，**在上面板画一条、在下面板画一条**，两条都成功提交，且各自的 `DrawingObject.period` 等于**所在面板当时显示的周期**。
3. **D42 跨面板 pending 取消**：上面板落一个 pending 锚（人造多锚工具场景）后点到下面板 → **pending 被清空，而 `activeDrawingTool` / `drawingModeActive` 存活**（走 `discardPendingAnchors()`，不是 `cancel()`）。
4. **D42 互斥模型已退役**：激活画线模式**不再**调用 `cancelDrawingAllPanels()`；两面板可同时接受落锚。
4b. **切 activePanel 不拆会话（codex R18-high 专项，两个方向都要测）**：
   - **无 pending 锚时**切 activePanel → `drawingModeActive` 与 `activeDrawingTool` **仍然存活**（会话不倒）。
   - **有 pending 锚时**切 activePanel（落锚面板实际改变）→ **只丢 pending 锚**（D31），会话仍在。
   - 断言 `TrainingView` 的 `.onChange(of: activePanel)` **不再**调用 `cancelDrawingAllPanels()`。
   - **丢 pending 后 `activeDrawingTool` 仍非 nil**（codex R20-high）：断言走的是 `discardPendingAnchors()` 而非 `DrawingToolManager.cancel()`。
4c. **1a-ii 不引入任何新 UI（D23 / D24）**：视图树里**不含**顶栏「画图」钮、不含两行底栏、不含设置面板。
5. **连续画线**：连续单击三次 → 画出**三条**线；每次提交后 `drawingModeActive` 仍为 true、`activeDrawingTool` 仍非 nil。
6. **入口未变**：训练 / replay / 复盘三处**仍然**渲染 `DrawingToolFloatingView`（退役在 1a-iii，本期不动）。
7. **D29 / D35 回归保护**：1a-i 的周期绑定（含同周期 fail-safe）与射线 hitTest 测试仍全绿。

### 3.4 P1b-1a-ii 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进入训练，看界面 | 还是原来那个浮动铅笔钮，**没有任何新按钮** | |
| 2 | 点浮动钮进画线模式，在图表上点一下 | 画出一条线 | |
| 3 | **接着再点两下** | **又画出两条线**（改造前：画完一条就自动退出画线模式了） | |
| 4 | 还在画线模式里，**在下半面板**点一下 | 下半面板也画出一条线（改造前：另一个面板点了没反应） | |
| 5 | 看下半面板那条线，切周期让它的周期挪走 | 它跟着自己的周期走（1a-i 的周期绑定仍生效） | |
| 6 | 再点一次浮动钮 | 退出画线模式，点图表不再画线 | |
| 7 | 退出 App 重进、续上这一局 | 画的线全都还在 | |
| 8 | 进复盘 | 浮动钮还在，行为与改造前一致（除了连续画线、两面板都能画这两点改善） | |

---

## 4. P1b-1a-iii 交付范围：「能设样式、能画出漂亮的线」

### 4.1 做

1. **画线模式外壳（母 spec §2，仅训练 / replay）**
   - 顶栏「结束」**左侧**加固定「画图」图标钮，与「结束」留明显间距（防误点）。点它切换 1a-ii 建立的全局 `drawingModeActive`。
   - 点「画图」→ 底部升起两行常驻栏；顶栏「结束」→「退出」。
   - 点「退出」→ 两行栏落下、恢复训练底栏、「退出」→「结束」。
   - **退出后所有画线惰性**：不可点选 / 不可拖动 / 不可删除。
   - 画布约束：画线只落在 **K 线主图区**（成交量 / MACD 副图不可画）；上下两面板都能画（D42 已就位）。
   - **本期画线模式内的手势仍是今天的语义**：单指 pan 被绘线截获（平移与切周期都被吞掉）。**这不是回归**——今天的浮动钮画线模式就是如此。1a-iv 解开。

2. **两行底栏骨架（D24）**
   - 上行 = **类型行**：本期只渲染水平线 1 个图标；选中态浅蓝框 + 浅蓝字。
   - 下行 = **只有 ①类型键**（收 / 展类型行）。②–⑤ 键**本期不渲染**（1b-i 补 ③🗑，1b-ii 补 ②🔒④↩⑤↪）。
   - 骨架（两行高度、图标尺寸、升起 / 落下动画、同训练底栏高度、图标 only 无文字）**一次定型**。
   - 类型行收起后：只能用上次所选工具继续画；展开才能换（本期只有一个工具，收起 = 让出一行图表高度）。
   - **类型行图标本期恒亮、不做 toggle**（D38）：本期无选中可做。toggle 在 1b-i 随选中一并引入。

3. **退役训练 / replay 的浮动铅笔钮（D26，必须与新入口同期）**
   - **必须先把 `TrainingView.swift:69` 的 `showsDrawingTools` 拆成两个谓词**（codex R22-high，交易安全）：它现在同时门控 `:186` 的浮动钮**和** `:423-425` 的 **activePanel 红色高亮边框**，而买 / 卖 / 持有都按 `activePanel` 下单。
     - `showsFloatingDrawingTool` = `engine.flow.mode == .review` → 只管 `DrawingToolFloatingView`。
     - `showsActivePanelHighlight` = `showsTradeButtons || engine.flow.mode == .review`（**保留原语义**）→ 只管 activePanel 高亮。
   - **直接把 `showsDrawingTools` 改成 review-only 是错的**：会在训练 / replay 里连带抹掉「当前对哪个面板下单」的唯一视觉提示，显著提高下错面板的风险（autosave 后不可逆）。
   - 训练 / replay 从此**只有**「画图」钮 + 两行底栏这一个画线入口；复盘仍是浮动钮（P5 再换）。
   - **不得早于本 PR 退役**：新入口不存在时撤掉旧入口 = 训练模式完全画不了线。

4. **统一长按设置面板（母 spec §3）**
   - **长按**类型行里的工具图标 → 类型行上方弹出浮层卡片（普通卡片，**无气泡尾巴**）。短按只选工具。
   - 四组控件：线型子类 `[直线][射线][线段]` / 线样式 `[实线][虚线1..4]` / 粗细 5 档 / 颜色 9 色 / 标注 `[隐藏][显示][左][右]`。
   - 不可用项**只灰掉，不写任何「不适用」说明字**。
   - **昼夜禁色**：白天禁「白」、夜间禁「黑」，自动灰。
   - **水平线的可选矩阵**（母 spec §3.1）：直线 ✅ / 射线 ✅ / **线段 灰**；标注 隐藏 / 左 / 右可选，**「显示」灰**，**选射线时「左」再灰**。
   - **本期面板的唯一作用对象** = 「该工具下一条要画的线」的默认值（本期无选中，故无歧义）。该默认值存在**内存、整局有效、不落盘**（持久化的全局默认属 P6 §13）。

### 4.2 P1b-1a-iii 不做

底栏 ②–⑤ 键、选中、删除、锁定、撤销 / 前进（1b-i / 1b-ii）；手势改动 / 同 period 钩子（1a-iv）；节点 / 多锚 / 四个新工具（P1c）；复盘专属一切（P5）；主页全局默认设置（P6）。

**前置（已做）**：D29 / D35（1a-i）、D39 / D42 / 连续画线（1a-ii）。本期不得回退，其测试须全绿。

**新画线的落盘**：走 `appendDrawing` → 数组长度变 → 现有 `.onChange(of: engine.drawings.count)` 触发 `autosave(immediate: true)`。**本期不需要 D30**（本期不存在原地改线）。

### 4.3 P1b-1a-iii 必须存在的负向测试

1. **复盘模式下新两行底栏不存在**；`DrawingToolFloatingView` 仍存在且行为不变（D26 / 母 spec D19）。
2. **训练 / replay 不再有浮动钮（D26，防双入口）**：`engine.flow.mode` 为 normal / replay 时，视图树里**不含 `DrawingToolFloatingView`**，且其 legacy 提交路径不可达。
2b. **activePanel 高亮未被连带抹掉（codex R22-high，交易安全回归）**：训练 / replay 下 **activePanel 红色高亮边框仍然渲染**（`showsActivePanelHighlight` 与 `showsFloatingDrawingTool` 已拆开）；复盘下两者都在。
3. **类型行只含 1 个图标**（水平线）；不渲染任何其它 `DrawingToolType` 图标（母 spec D22）。
4. **下行只含 ①类型键**；②锁定 / ③删除 / ④撤销 / ⑤前进 **不在视图树里**（D24 / D19，不 ship 未接线控件）。
5. **退出画线模式后**，单击图表不落锚。
6. **副图不可画**：在成交量 / MACD 区域单击不落锚。
7. **面板灰态矩阵**：水平线面板里「线段」恒灰、「标注-显示」恒灰；选「射线」后「标注-左」变灰；白天「白」灰、夜间「黑」灰。**灰掉的控件点击无副作用**。
8. **面板文案洁净**：面板视图树里**不含任何「不适用」类解释文案**（母 spec §3 逐字要求）。
9. **样式往返**：设了红色 / 虚线2 / 3 档粗细 / 标注靠右后画的线，`autosave` 后重新加载，五个样式字段逐一相等。
10. **`routeDrawingCommit` 全字段存活**：提交后 `id` / `period` / 五个样式字段 / `locked` 不丢（P1a 已加，本期回归保护）。
11. **默认值只作用于新线**：改了面板默认后，**已画的线逐字段不变**。
12. **前作回归保护**：1a-i 的 D29 / D35 与 1a-ii 的 D39 / D42 / 连续画线测试仍全绿。

### 4.4 P1b-1a-iii 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进入训练，看顶栏 | 「结束」左边出现「画图」图标钮，两者之间有明显间距 | |
| 2 | 看图表上原来那个浮动铅笔钮 | **不见了**（训练里只剩「画图」这一个入口） | |
| 2b | 看当前要下单的那个面板 | **红色高亮边框还在**（没被连带删掉）；切一下下单目标面板，高亮跟着走 | |
| 3 | 点「画图」 | 底部升起两行栏：上行 1 个水平线图标，下行 1 个「类型」键；顶栏「结束」变成「退出」 | |
| 4 | 看下行 | **只有「类型」一个键**，没有别的灰按钮 | |
| 5 | 在 K 线主图区点一下 | 落下一条水平线 | |
| 6 | 接着再点两下不同位置 | **又落下两条线**（连续画） | |
| 7 | **在下半面板**点一下 | 下半面板也落下一条线，底栏没有收起 | |
| 8 | 在成交量 / MACD 副图区点一下 | **不落线** | |
| 9 | 长按类型行的水平线图标 | 类型行上方弹出设置卡片，含 线型子类 / 线样式 / 粗细 / 颜色 / 标注 五组 | |
| 10 | 看卡片里的「线段」和「标注-显示」 | 两者是灰的、点不动，且**卡片上没有任何解释文字** | |
| 11 | 选「射线」 | 「标注-左」也变灰 | |
| 12 | 白天模式下看颜色行 | 「白」是灰的、点不动 | |
| 13 | 切到夜间模式再看颜色行 | 「黑」是灰的、点不动 | |
| 14 | 设成 红色 + 虚线 + 3 档粗细 + 标注靠右，关掉卡片，再画一条线 | 新线是红色虚线、比默认粗、右侧贴着价格标签，标签不压在线上 | |
| 15 | 看**之前画的那些**线 | **一点没变**（改默认只影响新线） | |
| 16 | 选「射线」再画一条 | 线只从落点向右延伸到图表右缘，不向左 | |
| 17 | 找一只四位数价格的高价股，射线 + 标注靠右 | 价格标签完整显示、不超出图表右边界 | |
| 18 | 点底栏「类型」键 | 类型行收起，图表多出一行高度；再点展开 | |
| 19 | 点「退出」 | 两行栏落下、恢复训练底栏、「退出」变回「结束」 | |
| 20 | 退出画线模式后单击图表 | **不落线**（画线惰性） | |
| 21 | 画线模式内单指横向拖 | 图表**不平移**（仍被绘线截获）——**这是本期的已知状态**（等于今天浮动钮的行为），1a-iv 修 | |
| 22 | 退出画线模式后竖滑切周期 | 画的线跟着周期走（1a-i 已修好） | |
| 23 | 画几条不同颜色的线，退出 App 重进、续上这一局 | 所有线连同颜色 / 线型 / 粗细 / 标注全部还在 | |
| 24 | 进复盘 | 复盘里**还是**那个可拖动的浮动铅笔钮，**没有**两行底栏 | |
| 25 | 再次训练（replay）模式 | 同样有「画图」钮和两行底栏、**没有**浮动钮，行为与训练一致 | |

---

## 5. P1b-1a-iv 交付范围：「画线时也能平移、切周期、缩放」

### 5.1 做

1. **D32 画线模式手势最小改动（§14 除节点拖动分支外的全部）**
   - 现状：`GestureClassifiers.swift:62` 的 `panPolicyInDrawingMode(drawingMode:)` 恒返回 `.drawingTakesOver`；`singlePanStep` 的 `drawingTakesOver` 早退分支（`:113-122`）直接返回空 emissions 且 `periodSwipe: nil` → **画线模式下平移与竖滑切周期一起被吞掉**。
   - 改写：画线模式下**单指 pan 不再被无条件截获**——水平分量走平移、竖直甩动走 `switchPeriodCombo`、双指缩放不受影响、单击落锚。
   - 沿 C7 的**纯函数 step + host 测**风格：判据全部落在 `GestureClassifiers` 的纯函数里，`ChartGestureArbiter` 只做分发。
   - **节点拖动分支**（起手命中节点 → 节点拖动）**不做**，留 P1c。
   - 该改动是**全局引擎行为**，在复盘的浮动钮画线模式下同样生效（D26 边界澄清）。

2. **D31 同 period 钩子**
   - `pendingAnchors` 非空时，**仅当周期组合或落锚面板发生了实际变化**才 **只丢弃 pending 锚**：调 `discardPendingAnchors()`（保留 `activeDrawingTool`），**绝不调 `manager.cancel()`**——后者会连 `activeTool` 一起清掉（`DrawingToolManager.swift:77-80`），而 1a-ii 已删除自动 re-arm，工具会一直停在 nil，连续画线断掉、1b-i 的 tap 会误入选择态。
   - 判据是「变化后 ≠ 变化前」，**不是**「用户做了切周期手势」——`switchPeriodCombo` 在边界 / 非法组合 / 目标无数据时会 no-op。
   - 实现二选一：① 让 `switchPeriodCombo` 返回 `Bool`（是否真的换了）；② 调用方在调用前后比较 `(upperPeriod, lowerPeriod)`。**禁止在手势回调处无条件 cancel。**
   - `commit` 前断言全锚同 period，不同则**拒绝提交并 `discardPendingAnchors()`**（同样不得清 `activeDrawingTool`）。
   - 本期水平线单锚、落锚即提交，实际触发不到；**钩子与断言仍须落地并可测**，供 P1c 复用。

### 5.2 P1b-1a-iv 不做

选中 / 删除 / 锁定 / 撤销 / 前进 / D30（1b-i / 1b-ii）；节点拖动分支 / 多锚 / 四个新工具（P1c）；复盘专属一切（P5）。

**前置（已做）**：D29 周期绑定（1a-i）、D39 / D42 / 连续画线（1a-ii）、外壳与底栏（1a-iii）。本 PR 让画线模式**首次能切周期**，正确性依赖 1a-i 那条已就位的判据。

### 5.3 P1b-1a-iv 必须存在的负向测试

1. **D32 手势（纯函数 host 测）**：`drawingMode == true` 时 —— 水平 pan 产生位移 emissions（**不再是空数组**）；竖直甩动产生非 `nil` 的 `periodSwipe`；双指缩放不受影响；单击落锚。**必须有一条直接断言 `panPolicyInDrawingMode` / `singlePanStep` 新行为的测试**（旧行为 `.drawingTakesOver` 早退返回空 emissions + `periodSwipe: nil`，是本期要推翻的对象）。
2. **D32 与 D29 的联合不变量**：**画线模式内**竖滑切周期后，原周期的线**不再渲染在该面板**（D29 在 1a-i 已测非画线模式路径；本条测新开的画线模式路径）。
3. **D31 钩子，两面都要测**：
   - **真变化 → 只丢 pending**：`pendingAnchors` 非空时周期组合**实际改变** → pending 被清空、不产生画线，**且 `activeDrawingTool` 仍非 nil、`drawingModeActive` 仍为 true**（codex R21-high）。
   - **no-op → 不取消**：`pendingAnchors` 非空时在**边界**（已是最高 / 最低周期）或**目标周期无数据**处触发切周期手势，周期未变 → **pending 锚原样保留**（不得误杀）。
   - `commit` 前的全锚同 period 断言存在且被测试覆盖（可用人造多锚输入直接测 manager 层），**且拒绝提交后 `activeDrawingTool` 仍非 nil**。
   - **断言这些路径调的是 `discardPendingAnchors()` 而非 `DrawingToolManager.cancel()`**。
4. **复盘手势同步改善不算回归**：复盘浮动钮画线模式下，pan / 竖滑 / 缩放同样可用（D32 全局生效）；复盘的**入口与控件**仍是浮动钮（D26）。

### 5.4 P1b-1a-iv 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，单指横向拖 | 图表左右平移（**这是相对 1a-iii 的改善**） | |
| 2 | 画线模式内单指竖向甩 | 周期正常切换 | |
| 3 | 画线模式内双指捏合 | 图表缩放正常 | |
| 4 | 画线模式内单击 | 仍然落线（手势没打架） | |
| 5 | **在画线模式里**（不退出）于上半面板（假设 60 分）画一条线，接着竖滑切周期让 60 分挪到下半面板 | 那条线**跟着 60 分跑到下半面板**（周期绑定 1a-i 已修，本条验它在画线模式内也成立） | |
| 6 | 继续切周期，让 60 分完全不显示 | 那条线暂时消失；切回来又出现，位置不变 | |
| 7 | 在**已经是最高周期**时再往上甩一次 | 周期不变，图表不乱（边界 no-op），**正在画的锚点不丢**（D31 不误杀） | |
| 8 | 在复盘里用浮动钮进画线模式，单指横滑 | 图表能平移（D32 全局生效） | |
| 9 | 进复盘看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 10 | 再次训练（replay）模式 | 手势行为与训练一致 | |

---

## 6. P1b-1b-i 交付范围：「能选中、能改、能删」

### 6.1 做

1. **底栏补 ③🗑 删除键**（D24）：与 1a-ii 的 ①类型键并列。②🔒 / ④↩ / ⑤↪ **本期仍不渲染**（属 1b-ii）。骨架不动。

2. **画线态 / 选择态（D38 + D39，先决）**
   - **类型行的工具图标改为 toggle**：点亮 → `activeDrawingTool` 非 nil → **画线态**；再点熄灭 → `== nil` → **选择态**。
   - **画线态**：单击**一律落锚**，**不做 hitTest**。因此可以在与已有线**完全重合**的位置叠画第二条线。
   - **选择态**：单击**做 hitTest**。
   - 没有这一分态，「命中优先于落锚」会让用户**永远画不出重合的第二条线**（codex R13-medium）。
   - **前置（D39，1a-ii 已搬家）**：`activeDrawingTool` 是底栏与 Coordinator 共享的单一真相，`ChartContainerView.swift:107` 的自动 re-arm 已删除。**若这条没做，toggle 会被每一次 `updateUIView` 撤销**，用户想选中的那一下会变成又画一条线（codex R15-high）。本期必须有**跨 render / update pass** 的端到端测试。

3. **选中状态进共享容器并流进渲染（D41，先决）**
   - `selectedDrawingID: DrawingID?` + `selectedPanel: PanelId?` 加入 1a-ii 建立的**同一个共享容器**（与 `activeDrawingTool` 同源）。底栏、设置面板、tap 处理**读写同一份**。
   - `RenderStateBuilder` 把 `selectedDrawingID` 带进 `KLineRenderState`（现在**没有** selected 概念）；`KLineView+Drawing` 的 dispatch 据此对该条走**选中蓝**（`DrawingTool.render` 的 D35 入参加 `isSelected: Bool`，或渲染上下文携带 selected id）。
   - **端到端测试**：选中一条线 → 强制走一次 `updateUIView` → 渲染出的仍是同一 id 的选中态，且 🗑 / 设置面板作用的**也是同一 id**。

4. **选中（母 spec §7，去节点；仅选择态）**
   - 选择态下单击 → 对**该面板的「可见画线集合」**做 `hitTest`，**逆序遍历、第一个命中即选中**（D33：最上层优先），返回其 `DrawingObject.id`（**不用数组下标**）。
   - **可见集合必须与 `RenderStateBuilder` 完全一致（D40）**：同一判据、同一 `revealTick` 过滤、同一 D29 fail-safe。**抽成共享纯函数**（如 `visibleDrawings(for:panel:engine:tick:)`），**返回渲染序**；渲染原样消费，**命中方自己 `.reversed()`**（D33）。不得各写一遍。否则在 `upper.period == lower.period` 的损坏态下，点击一个面板会选中 / 删除**渲染在另一个面板上**的线。
   - 命中后线渲染为**选中蓝**，底栏 🗑 由灰变亮（D27；🔒 本期不存在）。
   - 注：`hitTest` 在 1a-i 迁移了签名，但**仍从未被生产代码调用**。本期是它第一次接线。
   - 选择态下单击**未命中** → **清空选中**（D37）。
   - **复盘门控（D34，不可省）**：`ChartContainerView` 的 tap 路径三模式共用。加入「命中优先于落锚」时**必须以 `engine.flow.mode != .review` 门控 hitTest 分支**，否则复盘会意外获得无层门控的选中能力，可改写已归档记录里的原训练线。复盘的选中 + `(layer, id)` 层权限门控留 P5。

5. **设置面板作用对象消歧**
   - **有选中线**（只可能在选择态） → 面板改的是那条线（按 `id` 定位，**原地替换**）。
   - **无选中线** → 改的是「该工具下一条要画的线」的默认值（1a-ii 的行为）。

6. **删除**：点 🗑 → 弹确认 `确定删除划线？[删除][取消]`。（本期没有锁定，故 🗑 只在「无选中」时灰。）

7. **选中态的转移与生命期（D37）**
   - **画线态**：单击恒落锚，选中恒为空。
   - **选择态**：命中 → 选中它（替换原选中）；未命中 → 清空选中。
   - **新提交的线不自动选中。**
   - 退出画线模式、从选择态切回画线态、选中线因切周期 / 切面板不可见、选中线被删除 → 均清空选中。
   - 每次清空后 🗑 回到灰态。

8. **D30 内容级 dirty 信号（两处，缺一不可）**
   > 本期首次引入**原地改线**（第 5 条：改选中线的样式），故 D30 必须与它同期。删除会改数组长度，现有 count 触发本就够用；**改样式不会**。
   - **引擎**：`TrainingEngine` 新增 `public private(set) var drawingsRevision: Int`（单调递增，初值 0）。**每一个**改动 `drawings` 的引擎 API 都必须 `drawingsRevision += 1`：`appendDrawing` / `deleteDrawing(at:)` / 新增的原地替换 API（改样式）。
   - **① 视图触发**：`TrainingView.swift:273` 的 `.onChange(of: engine.drawings.count)` → `.onChange(of: engine.drawingsRevision)`，动作仍是 `lifecycle.autosave(immediate: true)`。
   - **② replay clean-skip 判据**：`TrainingSessionCoordinator.replayBaseline`（`:56`，现为 `(tick, ops, drawings: Int, upper, lower)`）**追加 `drawingsRevision: Int`**；在 `:581`（fresh 会话建基线）与 `:934`（续局建基线）快照 count 的**同一处、同一时刻**一并快照（必须在画线种子注入之后）；`saveProgress` 的 clean-skip 判据（`:607-610`）**追加 `base.drawingsRevision == engine.drawingsRevision`**。
     > **只改 ① 不够**：`saveProgress` 对尚未拥有槽的 fresh replay 会话做 clean-skip（`replayHasPersisted == false`）。改样式不改 tick / ops / 条数 / 周期 → 四项全等 → 提前 return、不写盘。onChange 照常触发了 autosave，写盘却被跳过。
   - **禁止**改用 `.onChange(of: engine.drawings)` 或任何数组值比较：`DrawingObject.==` 排除 `id`。
   - `reviewDrawings` 的 `.count` 触发本期不动。

### 6.1b P1b-1b-i 已知限制（明写，非缺陷）

- **不做选中循环**：两条几何落在同一命中容差内的线，单击恒选中**最上层**那条（D33）。若用户想操作下层那条，只能先删掉上层。完全重合时下层本就不可见，无实际影响；容差内但视觉可区分时，这是一个可接受的取舍。**P5 引入跨层选中时必须补上循环**（见 §9），因为那时"选不中下层"会直接导致原训练线无法隐藏。

### 6.2 P1b-1b-i 不做

锁定 / 解锁、撤销 / 前进、底栏 ②🔒④↩⑤↪（1b-ii）；节点 / 多锚 / 四个新工具（P1c）；复盘选中与复盘专属一切（P5）；主页全局默认设置（P6）。

### 6.3 P1b-1b-i 必须存在的负向测试

0. **内容级 dirty 信号（D30，最高优先，两条测试）**
   - **0a 训练路径**：改一条已有线的样式 → `drawingsRevision` 递增 → 触发 `autosave(immediate:)` → 重新加载后样式仍在。必须是「**不经过数组增删、只改内容**」的落盘往返。
   - **0b replay clean-skip 路径**（codex R4-high 专项）：**fresh replay 会话**（`replayHasPersisted == false`）里，**不推 tick、不交易、不增删画线、不切周期**，只改一条已有线的样式 → `saveProgress` **必须真的写盘**，不得 clean-skip；重新加载后改动仍在。
1. **退出画线模式后**单击不选中任何画线、🗑 不可达。
1b. **D38 分态**：`activeDrawingTool != nil` 时单击 → **落锚、不调用 `hitTest`**（即使点在已有线上）；`== nil` 时单击 → **调用 `hitTest`、不落锚**。
1b2. **D39 选择态熬过刷新（端到端，不得直接给 manager 赋值）**：熄灭图标进入选择态 → **触发一次完整的 SwiftUI render / update pass**（`updateUIView` → `sync()`）→ `activeDrawingTool` **仍为 nil** → 此时 tap 走 hitTest 而非落锚。
1b4. **D41 选中态熬过刷新且渲染一致（端到端）**：选中一条线 → 强制走一次 `updateUIView` → 渲染状态里**仍是同一个 `selectedDrawingID`**、该条渲染为选中蓝；随后 🗑 / 设置面板作用的**也是同一 id**。
1b3. **D40 命中集合 ≡ 渲染集合**：在 `upperPanel.period == lowerPanel.period` 的损坏态下，`panelPosition == 0` 与 `== 1` 各测一次——点击某面板**只能选中 / 删除渲染在该面板上的那条线**，绝不命中另一面板的同周期线。
1b5. **D40 z-order 一致性**：两条重合线，断言 `visibleDrawings(...)` 返回**渲染序**、后画的那条 dispatch 靠后（画在上面），**且**它正是逆序命中选中的那一条。
1c. **重合线可画（D38，走真实 UI 路径）**：画线态下在**同一价位**连续单击两次 → `engine.drawings` **有两条**几何重合、id 不同的线（**不得靠测试 fixture 直接塞两条**，必须走 tap → commit 路径）。
2. **选中按 id + 平局规则（D33）**：接 1c 的两条重合线，**切到选择态**后单击该价位，断言选中的是**数组靠后（最上层、后画）那条**的 `id`；随后的改样式 / 删除均作用于该 id，靠前那条**逐字段不变**。
3. **复盘不得获得选中能力（D34，trust-boundary 门控）**：`engine.flow.mode == .review` 时单击一条原训练线 → **不选中、不改样式、不删除**；`engine.drawings` 逐字段不变。此测试直接保护 committed record 不被未接线的复盘选中路径改写。
4. **D37 选中转移**：选择态下选中 A → 单击空白处（未命中） → **A 被取消选中**、🗑 回灰、**不落锚**；此时改样式**只改「下一条线的默认」**，A **逐字段不变**。另测：选中 A 后点亮工具图标切回画线态 → 选中被清空。
5. **切周期清选中**：选中一条线后切走其周期 → 选中被清空，🗑 回灰。
6. **底栏仍无 ②🔒④↩⑤↪**：三个键**不在视图树里**（D24 / D19，不 ship 未接线控件）。
7. **复盘外壳仍不变**：复盘无新底栏、浮动钮行为不变（D26 回归保护）。
8. **D29 / D35 回归保护**：1a-i 的周期绑定与射线 hitTest 测试在本 PR 仍全绿（选中依赖射线 hitTest 的方向性）。
9. **D26 回归保护**：训练 / replay 仍不含 `DrawingToolFloatingView`（1a-ii 已退役）。

### 6.4 P1b-1b-i 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看下行 | 现在是 2 个键：类型 / 🗑（**还没有** 🔒 / ↩ / ↪） | |
| 2 | 看类型行的水平线图标 | 是**亮着**的（浅蓝框）= 画线态 | |
| 3 | 在图表上连点三下 | 画出**三条**线（画线态下单击一律画线） | |
| 4 | 在**已有一条线的同一价位**再点一下 | **又叠画一条重合的线**（不是选中原来那条）——这是画线态 | |
| 5 | 点一下类型行的水平线图标（熄灭它） | 图标变暗 = 进入**选择态**，并且**一直保持暗着**（不会自己亮回来） | |
| 5b | 在选择态下等几秒、或让图表自己刷新一下（比如推进一根 K 线），再看图标 | **仍然是暗的**（选择态没被刷新冲掉） | |
| 6 | 选择态下单击图表空白处 | **什么都不画**（选择态不落锚），🗑 保持灰 | |
| 7 | 选择态下单击一条已有的线 | 线变蓝；🗑 从灰变亮 | |
| 8 | 接第 4 条：在那两条重合线的位置单击 | 选中的是**后画的那条**（最上面那条）；先画的那条**不受影响**（D33） | |
| 9 | 选中一条线，长按工具图标弹面板，改成绿色 | **那条选中的线**变绿（不是下一条） | |
| 10 | 选中一条线后单击空白处 | **取消选中**（线不再是蓝的）、🗑 回灰、**不画新线** | |
| 11 | 什么都没选中时改成蓝色，点亮工具图标回到画线态，再画一条 | 新线是蓝的，之前的线都不变 | |
| 12 | 选中一条线，点 🗑 | 弹出「确定删除划线？[删除][取消]」 | |
| 13 | 点「删除」 | 线消失，🗑 回灰 | |
| 14 | 选中一条线，然后点亮工具图标切回画线态 | **选中被取消**（线不再是蓝的），🗑 回灰 | |
| 15 | 点「退出」再单击一条线 | **没有任何反应**（不变蓝、🗑 不出现、也不画线） | |
| 16 | **改样式后立刻杀掉 App**（不点退出、直接从后台划掉），重开续这一局 | 改过的颜色 / 线型 / 粗细 / 标注**全部还在** | |
| 17 | **进「再次训练」新开一局**，什么都不做（不下单、不推进、不加线、不切周期），只把一条已有线改成紫色，**立刻杀掉 App**，重开续这一局 | 那条线是紫色的（专门验 replay 的 clean-skip 没吞掉改动） | |
| 18 | 选中一条 60 分的线（🗑 变亮），竖滑切周期让 60 分不再显示 | 线消失，**选中自动取消**，🗑 变回灰 | |
| 19 | 进复盘，用浮动钮进画线模式，单击一条训练时画的线 | **不选中**（线不变蓝、什么也没发生），只会落一条新线；原训练线的颜色 / 粗细一点没变（D34 门控） | |
| 20 | 进复盘看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 21 | 再次训练（replay）模式 | 行为与训练一致 | |

---

## 7. P1b-1b-ii 交付范围：「能锁定、能撤销」

### 7.1 做

1. **底栏补齐 ②🔒 ④↩ ⑤↪**（D24）：与 ①类型、③🗑 凑成母 spec §2 的 5 键。骨架不动。

2. **锁定 / 解锁**
   - 短按 🔒 锁定选中线（🔓→🔒 图标态）。
   - **锁定线仍可被选中**（否则无法解锁），但 🗑 灰、设置面板全灰、不可改样式。
   - **不在线旁画小锁图标**（仅底栏图标态体现）。
   - `locked` 随画线一起落盘；走 1b-i 已建立的原地替换 API，故 `drawingsRevision` 自动递增（D30 已就位）。

3. **撤销 / 前进（D25）**
   - 撤销栈**深度 1**。**入栈动作 = 画线 / 删线 / 改样式 / 锁定·解锁**。
   - 做了新动作 → 前进（↪）置灰。
   - **进画线模式时建栈，退出画线模式时清空**。
   - 撤销 / 前进都经引擎 API，`drawingsRevision` 递增 → 照常落盘。

### 7.2 P1b-1b-ii 不做

节点 / 多锚 / 四个新工具（P1c）；复盘选中与复盘专属一切（P5）；主页全局默认设置（P6）。

### 7.3 P1b-1b-ii 必须存在的负向测试

1. **锁定线**：🗑 灰、设置面板全灰、样式改不动；但**仍可被选中并解锁**。
2. **锁定态落盘**：锁定一条线 → `drawingsRevision` 递增 → autosave → 重新加载后仍是锁定态。
3. **锁定态 replay clean-skip**：fresh replay 会话里只锁定一条线（不推 tick / 不交易 / 不增删 / 不切周期）→ `saveProgress` 真的写盘（D30② 回归保护）。
4. **撤销栈深度 1**：连点两次 ↩ 只回退一步；↪ 只前进一步，第二次点无反应。
5. **撤销栈生命期**：退出画线模式再进入 → ↩ / ↪ 均为灰（栈已清空）。做新动作后 ↪ 置灰。
6. **四类动作都可撤销**：画线 / 删线 / 改样式 / 锁定，各写一条「做 → ↩ 复原 → ↪ 重做」的往返测试。
7. **撤销后落盘**：↩ 之后 `drawingsRevision` 递增、autosave 被触发（撤销也是一次改动）。
8. **前作回归保护**：1b-i 的 D33 / D34 / D37 测试与 1a-i 的 D29 / D35 测试在本 PR 仍全绿。

### 7.4 P1b-1b-ii 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看下行 | 现在是 5 个键：类型 / 🔒 / 🗑 / ↩ / ↪ | |
| 2 | 什么都没选中时看 🔒 和 🗑 | 两者都是灰的 | |
| 3 | 熄灭类型行图标进入**选择态**，单击一条已有的线 | 线变蓝；🗑 和 🔒 都从灰变亮 | |
| 4 | 选中一条线，点 🔒 | 图标变成已锁状态；🗑 变灰；长按工具图标弹出的卡片整片是灰的 | |
| 5 | 再点 🔒 | 解锁，🗑 恢复可用 | |
| 6 | 锁定一条线后**立刻杀掉 App**，重开续这一局 | 那条线仍是锁定态（🗑 灰） | |
| 7 | **进「再次训练」新开一局**，只锁定一条已有线，**立刻杀掉 App**，重开续这一局 | 那条线仍是锁定态 | |
| 8 | 画一条线，点 ↩ | 线消失 | |
| 9 | 点 ↪ | 线回来了 | |
| 10 | 删一条线，点 ↩ | 线回来了；再点 ↪ | 线又没了 | |
| 11 | 改一条线的颜色，点 ↩ | 颜色变回改之前 | |
| 12 | 锁定一条线，点 ↩ | 变回未锁定 | |
| 13 | 连点两次 ↩ | 只回退一步（深度只有一步） | |
| 14 | 点 ↪ 两次 | 只前进一步，第二次没反应 | |
| 15 | 撤销之后再画一条新线，看 ↪ | ↪ 置灰（新动作让"前进"失效） | |
| 16 | 点「退出」再进画线模式，看 ↩ / ↪ | 两个都是灰的（撤销栈不跨会话） | |
| 17 | 进复盘看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 18 | 再次训练（replay）模式 | 5 键齐全，行为与训练一致 | |

---

## 8. P1c（后续 epic —— **不属于 P1b 的可交付 PR 序列**）

多锚落点泛化 §5.0（`handleDrawingTap` 改用 `manager.activeTool` + `requiredAnchors` 收锚，折线不定锚数特例）；节点模型 §6（纯黑 / 纯白实心圆、仅选中态显示、拖节点几何实时跟随、仅折线可删单节点）；**§14 剩余的节点拖动分支**（起手落在选中线的节点上 → 节点拖动；其余方向分流已由 D32 在 1a-iii 落地）；四个工具 §5.2 / §5.3 / §5.4 / §5.11（含折线画制中临时 4 键 `[取消划线][完成划线][回退][前进]`）。类型行届时填满 5 个图标。

**P1c 不是一个已授权的 PR 边界（codex R12/R13-high）**：~1400 行 / 五个风险面（多锚泛化 · 节点模型 · 节点拖动手势 · 四个工具几何 · 折线临时 4 键），**明确超出「≤3 子项 / ≤500 行」**。本 spec **不拆它**——它尚未设计，切一个不存在的 PR 是空想。

**硬性要求**：进入 P1c 的 spec / plan 阶段前，**必须先按同样方法把它拆成若干各自可 ship、各带负向测试与验收清单的顺序 PR**。建议的缝：①多锚泛化 + 趋势线 ②通道线 + 箱体 ③折线 + 画制中临时 4 键 ④节点模型 + 拖节点 + §14 节点拖动分支。**任何实现者都不得把 P1c 当作一个 PR 来做。**

**P1c 必须携带的两组举证测试（无论怎么拆，都不得丢）**：
1. **零迁移举证**（见 §1.1）：channel(3 锚) / rect(2 锚) / polyline(N=2,3,7 锚) 的关系表 + pending JSON blob 存→读→深度相等往返，锚数与每个锚的 `period / candleIndex / price` 逐一断言。
2. **同 period 不变量（D31）**：trend / channel / polyline 各写一条「落第 1 锚 → 竖滑切周期 → pending 被丢弃、不产生混周期画线」的测试；以及 `commit` 前断言对人造混周期输入拒绝提交。

---

## 9. P5 必做项（本轮 review 沉淀，勿丢）

- **复盘选中必须是 `(layer, id)` 二元组**（`layer ∈ {original, review}`），按层门控：`original` 层只可隐藏 / 显示，`review` 层才可改样式 / 锁定 / 删除（母 spec §7 逐字）。1b-i 的 id-only 选中之所以安全，**仅仅因为复盘被 D34 显式门控在选中之外**；P5 解除门控的同时必须补上层身份，否则会改写已归档记录里的原训练线（trust-boundary）。
- **P5 必须引入「选中循环」，否则被复盘新线覆盖的原训练线永远选不中、也就永远无法隐藏**（codex spec-R8-medium，**已核实为真**）。母 spec §12 规定隐藏流程是「单击选中一条**原训练线** → 点隐藏」，依赖选中；而 D33 的逆序遍历恒让 `reviewDrawings` 里的线先命中。**P5 规则定为**：同一位置（落点位移 ≤ 命中容差）的**连续单击在命中集合内循环**，顺序即逆序遍历序（最上层 → 最下层 → 回到最上层）；落点移出容差、或选中被清空 → 循环重置。P5 必须加「原训练线与复盘新线重合 → 第二次单击选中原训练线 → 可隐藏」的回归测试。
- **P5 解除 D34 门控时**，层权限门控不可省：`original` 层只可隐藏 / 显示，`review` 层才可改样式 / 锁定 / 删除。
- **`reviewDrawings` 的 dirty 信号**：P5 引入复盘内的隐藏 / 删除（原地改内容）时，`reviewDrawings` 的 `.count` 触发同样会漏判，须比照 **D30** 加内容级 revision。
- 母 spec 既有 P5 项：复盘 6 键栏（含隐藏）、复盘删除、`hiddenIds` 写入行为与 committed baseline、「删空清已复盘」。
- P1a 沉淀：`ReviewNetChange.fullKey` 的分隔符 `|` `:` `;` 需在 P3（文本标注）前转义。

---

## 10. 契约 / 验收指针

- `CONTRACT_VERSION` 保持 `"1.11"`；**六个 PR 与后续 P1c 均无 schema 迁移**；`user_version` 保持 `7`。
- 每个 PR 的三绿门（作者亲核，clean build）：host `swift test` 全绿 + Mac Catalyst `build-for-testing` SUCCEEDED + iOS build。
- 每个 PR 的流程：plan → codex 对抗 review 收敛 → `superpowers:subagent-driven-development` → 三绿 → `superpowers:requesting-code-review` + whole-branch codex → PR。
