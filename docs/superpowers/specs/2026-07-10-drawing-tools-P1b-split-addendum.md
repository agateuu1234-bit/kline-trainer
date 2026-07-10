# 划线工具扩充 · P1b 拆分补充 spec（P1b-1a / P1b-1b / P1b-2）

> **母 spec**：`docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（下称「母 spec」）。
> 本文件**只覆盖母 spec §15 中 P1 行的交付粒度**，不改任何母 spec 的设计决策（D1…D22 全部继续生效）。
> **基线**：`96d2ac4`（P1a 契约地基已 merge，PR #140）。
> **日期**：2026-07-10。
> **状态**：经 codex 对抗 review R1–R3 收敛（D28 举证 / D29 / D30 / D31 / 三段切分均为 review 结论）。

---

## 0. 为什么要拆

母 spec 的 P1 是一个阶段，实际含 7 大子项（外壳 §2 / 设置面板 §3 / 节点 §6 / 选中·删除·锁定·撤销 §7 / 多锚泛化 §5.0 / 周期绑定 §10 / 手势消歧 §14）+ 5 个工具，估算 2500–3500 行生产代码。

P1a（纯契约 + 持久层，零 UI）已作为 PR #140 独立 merge。**剩余部分即本文件所称 P1b**，仍然过大：

- 违反 `CLAUDE.md` 治理约束「每 PR ≤3 子项、≤500 行」（P1a 已是超额特批）。
- P1a 的实证：单个大 PR 在本地 codex 对抗 review 走了 21 轮 29 finding 仍未自然 approve。体量越大越不收敛。

故 P1b 拆为**三个顺序 PR**：**P1b-1a → P1b-1b → P1b-2**。

> **切分历程（留档）**：初稿为两段（P1b-1 / P1b-2）。codex spec-review R3-high 指出 P1b-1 仍含七个互相独立的风险面（外壳 / 底栏 / 设置面板 / 样式渲染 / 选中编辑 / autosave 语义 / 跨模式渲染），"批准此 spec 等于放行又一个大 PR，正是本文档自称要避免的"。核实属实，遂沿"**能不能画得漂亮**"与"**能不能选中改**"的天然缝再切一刀。

---

## 1. 拆分结论（决策表）

| 决策 | 结论 | 理由 |
|---|---|---|
| **D23 三段切分线** | **P1b-1a** = 画线模式外壳 §2 + 两行底栏骨架 + 长按设置面板 §3 + 样式系统接入渲染 + 水平线升级 §5.1 + **§14 手势最小改动（D32，不含节点拖动分支）** + D31 同 period 钩子。<br>**P1b-1b** = 选中 · 删除 · 锁定 · 撤销/前进 §7（**不含节点**）+ D30 内容级 dirty 信号 + D29 周期绑定渲染 §10。<br>**P1b-2** = 多锚泛化 §5.0 + 节点模型与拖节点 §6 + §14 剩余的节点拖动分支 + 趋势线 §5.2 / 通道线 §5.3 / 箱体 §5.11 / 折线 §5.4。 | **1a↔1b 的缝**：1a 只让用户「画出一条漂亮的线」，不引入任何**原地修改已有线**的能力，因而不需要选中、不需要内容级 autosave（新画线走 append，数组长度变，现有 count 触发即正确）。1b 一次性引入「原地改线」及其全部后果（选中 / 改样式 / 锁定 / 撤销 / 内容级存盘）。D30 与它服务的能力同期落地，逻辑自洽。<br>**1b↔2 的缝**：节点必须与「拖节点」同期落地，否则会 ship 出**拖不动的死节点**（母 spec D19 禁止）。周期绑定 §10 与工具无关（只改渲染过滤判据），单靠水平线即可完整演示与测试。 |
| **D24 底栏骨架一次定型，控件按期填充** | P1b-1a 即按母 spec §2 建**两行常驻栏**（高度 / 图标尺寸 / 升起落下动画一次定型）。**但每一期只渲染该期已落地的控件**：<br>• **1a**：上行类型行只有水平线 1 个图标；下行**只有 ①类型键**（收 / 展类型行）。<br>• **1b**：下行补齐 ②锁定 ③删除 ④撤销 ⑤前进，成为母 spec §2 的 5 键。<br>• **P1b-2**：类型行填满 5 个图标。<br>• **P5**：复盘补第 ⑥ 隐藏键。 | 母 spec **D19 / D22**：不得 ship 死控件 / 死图标。若 1a 就画出 5 键而 ②–⑤ 恒灰（因为「选中」尚未实现，连判据都不存在），那是四个**未接线**的按钮——正是 D19 禁止的东西。「只显示已落地控件」是 D22 对类型行图标的既有做法，此处**对称套用到底栏键位**。骨架（两行、高度、动画）一次定型，故布局不会二次返工。 |
| **D25 撤销语义**（P1b-1b） | 撤销栈**深度 1**（母 spec §7 已定「各仅一步」）。**入栈动作 = 画线 / 删线 / 改样式 / 锁定·解锁**。做了新动作 → 前进（↪）置灰。**进画线模式时建栈，退出画线模式时清空**。 | 画线模式是一个有界的编辑会话，退出即提交。跨模式保留会让用户在交易了几十个 tick 之后意外撤销掉一条线；且跨模式保留会立刻牵出「撤销栈要不要随 autosave 落盘 / 断点续局后 ↩ 是否还灵」的新决策面，与本阶段无关。 |
| **D26 复盘过渡（限定于 UI 外壳）** | P1b-1a / 1b 的新两行底栏**只在训练 / 再次训练（replay）出现**。**复盘模式的画线「入口与控件」完全不动**，继续使用现有 `DrawingToolFloatingView` 浮动铅笔钮，交互一字不改。P5 时复盘切到 6 键新底栏，届时删除 `DrawingToolFloatingView`。<br>**边界澄清（codex spec-R2-medium / R4-high）**：D26 只管**画线模式的入口与控件**。**渲染（D29）与手势编排（D32）都是全局引擎行为，在复盘的浮动钮画线模式下同样生效**。 | 母 spec D19：复盘专属控件（隐藏键、复盘删除、hiddenIds 持久化、clear-saved）全在 P5。若让浮动钮退役而复盘又不上新底栏 → 复盘失去画线入口 = **功能回归**。若复盘上 5 键新底栏 → 其中 🔒/🗑 在复盘必须置灰（复盘删除属 P5、原训练线按母 spec §7 只可隐藏/显示）= **死控件**，两者都不可接受。 |
| **D27 选中态视觉**（P1b-1b） | 选中态 = **线渲染为选中蓝 + 底栏 🗑/🔒 由灰变亮**，**不显节点圆**。P1b-2 补上两端 / 各转折点的实心圆节点。 | mockup「选中态」屏（`2026-07-03-drawing-tools-expansion.html`）画的是「线变蓝 + 带蓝外圈实心圆节点 + 🗑高亮」。D23 把节点推后，故本期 = 该视觉去掉圆点。选中反馈仍然完整可见（线变色 + 底栏键活化）。 |
| **D28 契约不动** | **P1b-1a / P1b-1b / P1b-2 均为纯 UI / 渲染层 PR：零迁移、不 bump `CONTRACT_VERSION`（保持 `1.11`）、`user_version` 保持 `7`。** | 见 §1.1 逐形状持久化举证。核心：**`DrawingObject.anchors` 是变长数组 `[DrawingAnchor]`**，`drawings` 表以单列 `anchors TEXT NOT NULL` 存整个锚数组的 JSON，任意锚数都能无损往返；其余 18 字段（`id` / `period` / `lineSubType` / `lineStyle` / `thickness` / `colorToken` / `labelMode` / `locked` / `text` / `fontSize` / `textColorToken` / `textForm` / `tailAnchor`）已由 P1a 全部落地，迁移 0009 已随 1.11 ship。 |
| **D29 周期绑定全局生效（含复盘）**（P1b-1b） | `RenderStateBuilder` 的过滤判据改为 `drawing.period == 该面板当前显示的周期`，**对训练 / replay / 复盘三种模式一视同仁**，复盘的两层（只读原训练线 `engine.drawings` + 复盘新画线 `engine.reviewDrawings`）都按新判据过滤。**不做模式门控、不保留 `panelPosition` 老路径。** 必须补复盘渲染回归测试。 | codex spec-R2-medium 指出 `RenderStateBuilder.swift:67` 是三模式共用的**单条过滤**。备选「复盘继续走 `panelPosition` 直到 P5」会造成：同一条线在训练里跟周期走、进复盘又跳回按面板位置 = 用户可见的错位，且需要一条模式条件渲染分支（更多代码、更多 bug 面）。母 spec **D1** 已定「画线绑定 period 非 panelPosition」——这是画线的**渲染属性**，不是模式特性。<br>**老数据安全性举证**：finalized 记录里的 legacy 行（0009 回填、`style_json IS NULL`）走 `DrawingStyle.legacyFallback(isExtended:period: anchors.first?.period ?? .m3)`（`RecordRepositoryImpl.swift:213`）；`DrawingObject.init` 的 `period` 默认取 `anchors.first?.period ?? .daily`（`Models.swift:269`）。故**历史画线一律带正确 period**，周期绑定对老记录成立。 |
| **D30 内容级 dirty 信号（两处，缺一不可）**（P1b-1b） | **① 视图触发**：把 `TrainingView` 的存盘触发从 `.onChange(of: engine.drawings.count)` 改为 `.onChange(of: engine.drawingsRevision)`。`TrainingEngine` 新增单调计数器 `public private(set) var drawingsRevision: Int`，**任何**改动 `drawings` 的引擎 API（append / delete / **原地替换（改样式、锁定）** / undo / redo）都 `+1`。<br>**② replay clean-skip 判据**：`TrainingSessionCoordinator.replayBaseline` 元组（现为 `(tick, ops, drawings: Int, upper, lower)`，`:56`）**追加 `drawingsRevision: Int`**，在 `:581` / `:934` 快照 count 的同一处一并快照；`saveProgress` 的 clean-skip 判据（`:607-610`）**追加 `base.drawingsRevision == engine.drawingsRevision`**。 | codex spec-R2-high + **R4-high**（两条均**已核实为真**）。<br>**① 的必要性**：现触发是 `TrainingView.swift:273` 的 `.onChange(of: engine.drawings.count)`。P1b-1a 及之前画线只有增 / 删两种操作，按 count 触发正确；**P1b-1b 首次引入原地改一条线**（改样式 / 锁定 / 撤销一次改样式），**数组长度不变 → 不触发 autosave**。<br>**② 的必要性（只改 ① 不够）**：`saveProgress` 对**尚未拥有槽的 fresh replay 会话**做 clean-skip（`replayHasPersisted == false` 时，`:603-610`），判据是 tick / ops / **drawings 条数** / 上下周期全等于基线。在一局新开的 replay 里选中一条已有的线只改颜色 → 四项全等 → **`saveProgress` 提前 return、不写盘** → 杀进程后改动丢失。onChange 照常触发了 autosave，写盘却被跳过。<br>**不得**改用 `.onChange(of: engine.drawings)` 或数组值比较：`DrawingObject.==` 刻意**排除 `id`**（P1a 决策，id 是身份非内容）。单调计数器是唯一无歧义的信号。<br>**基线快照时机**：必须在引擎完成画线种子注入**之后**取 `drawingsRevision`，与现有 count 快照同点同时。<br>`reviewDrawings` 的 `.count` 触发**本期保持不变**（P1b 不引入复盘内的原地编辑；P5 引入隐藏 / 删除时同法处理）。 |
| **D32 画线模式手势最小改动落 P1b-1a** | 母 spec §14 中，**除"起手落在选中线节点上 → 节点拖动"这一分支外**的全部内容落 **P1b-1a**：画线模式下 ①单指横滑=平移、②单指竖滑=切周期、③双指=缩放、④单击=落锚，四者共存不互吞。`panPolicyInDrawingMode` / `singlePanStep` 的 `drawingTakesOver` 早退路径必须改写。<br>**节点拖动分支**（起手命中节点 → 进入节点拖动）留 **P1b-2**，与节点模型同期。<br>**边界澄清**：D26 只管**画线模式的入口与控件**；手势编排（D32）与渲染（D29）一样是**全局引擎行为**，在复盘的浮动钮画线模式下同样生效。 | codex spec-R4-high（**已核实为真**）：`GestureClassifiers.swift:62` 的 `panPolicyInDrawingMode(drawingMode:)` 恒返回 `.drawingTakesOver`；`:113-122` 的早退分支直接 `return SinglePanStep(emissions: [], lifecycle: .idle, lastTranslationX: 0, periodSwipe: nil)`——**平移与竖滑切周期一并被吞掉**。<br>故「P1b-1a 保证画线模式内平移 / 切周期可用」与「§14 全部推给 P1b-2」**自相矛盾**：实现者照 spec 推迟 §14，必然过不了 P1b-1a 的负向测试 5 与验收第 15 / 16 条，最终 ship 出一个**画线时无法平移图表**的模式。<br>**连锁结论**：今天画线模式根本切不了周期，故 **D31 的取消钩子在 arbiter 改动落地前无从触发**——D31 与 D32 必须同期落 P1b-1a。<br>备选「从 1a 移除该 UX 保证、记为临时回归」被否：画线模式下不能平移图表，用户无法把线画到屏幕外的位置，是不可接受的可用性缺陷。 |
| **D31 单条画线的所有锚必须同 period**（钩子落 P1b-1a，测试到 P1b-2） | **不变量**：一条 `DrawingObject` 的 `anchors` 数组里，**每个 `DrawingAnchor.period` 必须相同**，且等于 `DrawingObject.period`。<br>**执行**：画线模式内，只要 `manager.pendingAnchors` 非空，发生 ①单指竖滑切周期（`switchPeriodCombo`）或 ②落锚面板改变 → **立即 `manager.cancel()` 丢弃 pending 锚**（不提交半成品、不静默混锚）。<br>**兜底**：`commit` 前断言全锚同 period，不同则拒绝提交并 `cancel()`。<br>**P1b-1a 即落地**该取消钩子与断言（水平线单锚触发不到，但钩子与测试先就位）；**P1b-2 的 trend / channel / polyline 必须带混周期尝试的测试**。 | codex spec-R3-high（**已核实为真**）。母 spec §2 要求画线模式内保留单指竖滑切周期；P1b-2 的多锚工具要点好几下才成一条。若第 1 锚落在 60 分、竖滑后第 2 锚落在 15 分，两锚的 `candleIndex` 属于**不同坐标系**，而 `DrawingObject.period` 只取 `anchors.first?.period`（`Models.swift:269`）→ 存下来的线几何上是错的，且经 autosave / finalize 固化后不可修复。<br>取消（而非"把后续锚换算到首锚周期"）的理由：换算需要跨周期 K 线索引映射，是 P4 吸附级别的复杂度，且用户意图本就不明；丢弃 pending 锚是唯一 fail-closed 且可解释的行为。 |

| **D33 命中平局规则：最上层优先（逆序遍历）**（P1b-1b） | 选中的命中检测**按渲染数组的逆序遍历**，**第一个 `hitTest` 命中的即为选中项**，立即返回其 `id`，不再继续遍历。<br>渲染数组即 `RenderStateBuilder` 交给 `KLineView` 的那一个（复盘下为 `engine.drawings + engine.reviewDrawings` 的拼接结果，经周期 / `revealTick` 过滤后）。<br>**语义**：数组靠后 = 后绘制 = 盖在上面 = 用户看见的那一条 = 被选中的那一条。**新画的线恒在最上层**（append 到尾部）。**复盘中新画线恒优先于原训练线**（拼接顺序使然），与母 spec §7「原训练线只可隐藏 / 显示、复盘新线可编辑」的意图一致。<br>**不做**选中循环（连点同一处轮换命中项）——母 spec 未要求，YAGNI。 | codex spec-R5-high（**已核实为真**）。原文只写「遍历所有可见画线逐个 `hitTest` 命中」而未定遍历方向与平局规则，却在验收里要求「两条价格完全一样的水平线，选中其中一条改颜色 → 只有被点中的那一条变色」——**这是一道无解题**：几何完全重合时 `hitTest` 无法区分意图，正序遍历会命中数组里靠前那条，而用户看见的是靠后那条盖在上面。改样式 / 锁定 / 删除会作用到**错误的线**，而 UI 只显示一条被选中。<br>逆序遍历使「选中 = 视觉上最上面那条」成为可判定且与渲染一致的规则。`KLineView+Drawing.swift:16-26` 按数组顺序绘制，后绘制者覆盖先绘制者，故逆序 = 自顶向下。 |

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
| 水平线 horizontal | 1 | `[a0]` | 否 | P1b-1a（升级） |
| 趋势线 trend | 2 | `[a0, a1]` | 否 | P1b-2 |
| 通道线 channel | 3 | `[a0, a1, a2]`（a0/a1 定主线，a2 定平行线） | **否**——第三锚就是 `anchors[2]` | P1b-2 |
| 箱体 rect | 2 | `[a0, a1]`（矩形对角） | 否 | P1b-2 |
| 折线 polyline | N（不定） | `[a0, a1, …, a_{N-1}]` | **否**——数组本就不定长 | P1b-2 |

**结论**：P1b 三期均不需要任何新列、新字段、新迁移；`anchors` 数组 + `toolType` 已足以无歧义地表达全部五个形状。`lineSubType / lineStyle / thickness / colorToken / labelMode / locked` 已在 `style_json` 列（0009 新增）里往返。**D28 成立。**

---

## 2. P1b-1a 交付范围：「能画出一条漂亮的线」

### 2.1 做

1. **画线模式外壳（母 spec §2，仅训练 / replay）**
   - 顶栏「结束」**左侧**加固定「画图」图标钮，与「结束」留明显间距（防误点）。
   - 点「画图」→ 底部升起两行常驻栏；顶栏「结束」→「退出」。
   - 点「退出」→ 两行栏落下、恢复训练底栏、「退出」→「结束」。
   - **退出后所有画线惰性**：不可点选 / 不可拖动 / 不可删除。
   - 画布约束：画线只落在 **K 线主图区**（成交量 / MACD 副图不可画）；上下两面板都能画。
   - 画线模式内保留图表操作：单指横滑=平移、单指竖滑=切周期、双指=缩放、单击=落锚。**这需要真改 arbiter，见下方第 6 条（D32）。**
     （**注**：本期不引入选中，故单击恒为「落锚」；本期不引入节点，故不存在「起手是否落在节点上」的分支——该分支属 P1b-2。）

2. **两行底栏骨架（D24）**
   - 上行 = **类型行**：本期只渲染水平线 1 个图标；选中态浅蓝框 + 浅蓝字。
   - 下行 = **只有 ①类型键**（收 / 展类型行）。②–⑤ 键**本期不渲染**（属 P1b-1b）。
   - 骨架（两行高度、图标尺寸、升起 / 落下动画、同训练底栏高度、图标 only 无文字）**一次定型**。
   - 类型行收起后：只能用上次所选工具继续画；展开才能换（本期只有一个工具，收起 = 让出一行图表高度）。

3. **统一长按设置面板（母 spec §3）**
   - **长按**类型行里的工具图标 → 类型行上方弹出浮层卡片（普通卡片，**无气泡尾巴**）。短按只选工具。
   - 四组控件：线型子类 `[直线][射线][线段]` / 线样式 `[实线][虚线1..4]` / 粗细 5 档 / 颜色 9 色 / 标注 `[隐藏][显示][左][右]`。
   - 不可用项**只灰掉，不写任何「不适用」说明字**。
   - **昼夜禁色**：白天禁「白」、夜间禁「黑」，自动灰。
   - **水平线的可选矩阵**（母 spec §3.1）：直线 ✅ / 射线 ✅ / **线段 灰**；标注 隐藏 / 左 / 右可选，**「显示」灰**，**选射线时「左」再灰**。
   - **本期面板的唯一作用对象** = 「该工具下一条要画的线」的默认值（本期无选中，故无歧义）。该默认值存在**内存、整局有效、不落盘**（持久化的全局默认属 P6 §13）。

4. **样式系统真正接入渲染**
   - `HorizontalLineTool.render` 现写死 `strokeRGBA = (0.82, 0.40, 0.0)` + `ctx.setLineWidth(1.5)`（`Drawing/HorizontalLineTool.swift:31-42`），**改为消费 `DrawingObject` 的 `colorToken` / `lineStyle` / `thickness` / `labelMode` / `lineSubType`**。
   - `colorToken` → 实际 RGBA 由**主题解析**（昼 / 夜两套），保证可读性。
   - 渲染 helper 必须是 **host 可测的纯函数**（非 `View`、非 `@MainActor` 隔离），沿现有 `CoordinateMapper` 风格。

5. **水平线升级（母 spec §5.1）**
   - 线型：**直线**（全宽横线）/ **射线**（自落点向右到主图右缘）。**无线段**。
   - 标注：隐藏 / 左 / 右（价格）。价格标签**紧贴线上方、不压线**；射线时靠右缘，**防贵股 4 位整数价溢出**（须裁剪或右对齐至主图右缘内）。

6. **画线模式手势最小改动（D32，§14 除节点拖动分支外的全部）**
   - 现状：`GestureClassifiers.swift:62` 的 `panPolicyInDrawingMode(drawingMode:)` 恒返回 `.drawingTakesOver`；`singlePanStep` 的 `drawingTakesOver` 早退分支（`:113-122`）直接返回空 emissions 且 `periodSwipe: nil` → **画线模式下平移与竖滑切周期一起被吞掉**。
   - 本期改写：画线模式下**单指 pan 不再被无条件截获**——水平分量走平移、竖直甩动走 `switchPeriodCombo`、双指缩放不受影响、单击落锚。
   - 沿 C7 的**纯函数 step + host 测**风格：判据全部落在 `GestureClassifiers` 的纯函数里，`ChartGestureArbiter` 只做分发。
   - **节点拖动分支**（起手命中节点 → 节点拖动）**不做**，留 P1b-2。
   - 该改动是**全局引擎行为**，在复盘的浮动钮画线模式下同样生效（D26 边界澄清）。

7. **D31 同 period 钩子**
   - `pendingAnchors` 非空时，切周期（`switchPeriodCombo`）或落锚面板改变 → `manager.cancel()`。
   - `commit` 前断言全锚同 period，不同则拒绝提交并 `cancel()`。
   - 本期水平线单锚、落锚即提交，实际触发不到；**钩子与断言仍须落地并可测**，供 P1b-2 复用。
   - **必须与 D32 同期**：D32 落地前画线模式压根切不了周期，取消钩子无从触发。

### 2.2 P1b-1a 不做

底栏 ②–⑤ 键、选中、删除、锁定、撤销 / 前进、D29 周期绑定、D30 内容级 dirty 信号（全在 P1b-1b）；节点 / 拖节点 / §14 的节点拖动分支 / 多锚 / 四个新工具（P1b-2）；复盘专属一切（P5）；主页全局默认设置（P6）。

**新画线的落盘**：走 `appendDrawing` → 数组长度变 → 现有 `.onChange(of: engine.drawings.count)` 触发 `autosave(immediate: true)`。**本期不需要 D30**（本期不存在原地改线）。

### 2.3 P1b-1a 必须存在的负向测试

1. **复盘模式下新两行底栏不存在**；`DrawingToolFloatingView` 仍存在且行为不变（D26 / 母 spec D19）。
2. **类型行只含 1 个图标**（水平线）；不渲染任何其它 `DrawingToolType` 图标（母 spec D22）。
3. **下行只含 ①类型键**；②锁定 / ③删除 / ④撤销 / ⑤前进 **不在视图树里**（D24 / D19，不 ship 未接线控件）。
4. **退出画线模式后**，单击图表不落锚、不选中任何画线。
5. **画线模式手势（D32，纯函数 host 测）**：`drawingMode == true` 时 —— 水平 pan 产生位移 emissions（不再是空数组）；竖直甩动产生非 `nil` 的 `periodSwipe`；双指缩放不受影响；单击落锚。**必须有一条直接断言 `panPolicyInDrawingMode` / `singlePanStep` 新行为的测试**（旧行为 `.drawingTakesOver` 早退返回空 emissions + `periodSwipe: nil`，是本期要推翻的对象）。
6. **样式往返**：设了红色 / 虚线2 / 3 档粗细 / 标注靠右后画的线，`autosave` 后重新加载，五个样式字段逐一相等。
7. **`routeDrawingCommit` 全字段存活**：提交后 `id` / `period` / 五个样式字段 / `locked` 不丢（P1a 已加，本期回归保护）。
8. **D31 钩子**：`pendingAnchors` 非空时触发 `switchPeriodCombo` → pending 被清空、不产生画线；`commit` 前的全锚同 period 断言存在且被测试覆盖（可用人造多锚输入直接测 manager 层）。
9. **副图不可画**：在成交量 / MACD 区域单击不落锚。
10. **复盘手势同步改善不算回归**：复盘浮动钮画线模式下，pan / 竖滑 / 缩放同样可用（D32 全局生效）；复盘的**入口与控件**仍是浮动钮（D26）。

### 2.4 P1b-1a 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进入训练，看顶栏 | 「结束」左边出现「画图」图标钮，两者之间有明显间距 | |
| 2 | 点「画图」 | 底部升起两行栏：上行 1 个水平线图标，下行 1 个「类型」键；顶栏「结束」变成「退出」 | |
| 3 | 看下行 | **只有「类型」一个键**，没有别的灰按钮 | |
| 4 | 在 K 线主图区点一下 | 落下一条水平线 | |
| 5 | 在成交量 / MACD 副图区点一下 | **不落线** | |
| 6 | 长按类型行的水平线图标 | 类型行上方弹出设置卡片，含 线型子类 / 线样式 / 粗细 / 颜色 / 标注 五组 | |
| 7 | 看卡片里的「线段」和「标注-显示」 | 两者是灰的、点不动，且**卡片上没有任何解释文字** | |
| 8 | 选「射线」 | 「标注-左」也变灰 | |
| 9 | 白天模式下看颜色行 | 「白」是灰的、点不动 | |
| 10 | 切到夜间模式再看颜色行 | 「黑」是灰的、点不动 | |
| 11 | 设成 红色 + 虚线 + 3 档粗细 + 标注靠右，关掉卡片，再画一条线 | 新线是红色虚线、比默认粗、右侧贴着价格标签，标签不压在线上 | |
| 12 | 选「射线」再画一条 | 线只从落点向右延伸到图表右缘，不向左 | |
| 13 | 找一只高价股（四位数价格），射线 + 标注靠右 | 价格标签完整显示、不超出图表右边界 | |
| 14 | 点底栏「类型」键 | 类型行收起，图表多出一行高度；再点展开 | |
| 15 | 画线模式内单指横向拖 | 图表左右平移（没被画线吞掉） | |
| 16 | 画线模式内单指竖向甩 | 周期正常切换 | |
| 17 | 画线模式内双指捏合 | 图表缩放正常 | |
| 18 | 点「退出」 | 两行栏落下、恢复训练底栏、「退出」变回「结束」 | |
| 19 | 退出画线模式后单击图表 | **不落线**（画线惰性） | |
| 20 | 画几条不同颜色的线，退出 App 重进、续上这一局 | 所有线连同颜色 / 线型 / 粗细 / 标注全部还在 | |
| 21 | 进复盘 | 复盘里还是原来那个**可拖动的浮动铅笔钮**，**没有**两行底栏 | |
| 22 | 在复盘里用浮动钮进画线模式，单指横滑 | 图表能平移（**这是相对改造前的改善**：以前画线模式下平移被吞掉；D32 全局生效） | |
| 23 | 在复盘里用浮动钮画线 | 除上一条外，落线行为跟改造前一致 | |
| 24 | 再次训练（replay）模式 | 同样有「画图」钮和两行底栏，行为与训练一致 | |

---

## 3. P1b-1b 交付范围：「能选中、能改、能撤销」

### 3.1 做

1. **底栏补齐 ②–⑤ 键**（D24）：②锁定 ③删除 ④撤销 ⑤前进，与 1a 的 ①类型键凑成母 spec §2 的 5 键。骨架不动。

2. **选中（母 spec §7，去节点）**
   - 画线模式内单击 → 对**该面板当前周期所有可见画线**做 `hitTest`，**按渲染数组逆序遍历，第一个命中即选中**（D33：最上层优先），返回其 `DrawingObject.id`（**不用数组下标**）。
   - 命中后线渲染为**选中蓝**，底栏 🗑 / 🔒 由灰变亮（D27）。
   - 注：`hitTest` 在 P1a 之后仍是**从未被生产代码调用**的协议方法（仅测试用）。本期是它第一次接线。
   - 单击**未命中**任何线 → 落锚（继续画）。命中优先于落锚。

3. **设置面板作用对象消歧**
   - **有选中线** → 面板改的是那条线（按 `id` 定位，原地替换）。
   - **无选中线** → 改的是「该工具下一条要画的线」的默认值（1a 的行为）。

4. **删除**：点 🗑 → 弹确认 `确定删除划线？[删除][取消]`。选中线被锁 → 🗑 灰。

5. **锁定 / 解锁**：短按 🔒 锁定选中线（🔓→🔒 图标态）。**锁定线仍可被选中**（否则无法解锁），但 🗑 灰、设置面板全灰、不可改样式。**不在线旁画小锁图标**。`locked` 随画线一起落盘。

6. **撤销 / 前进**：见 D25。

7. **D30 内容级 dirty 信号（两处，缺一不可）**
   - **引擎**：`TrainingEngine` 新增 `public private(set) var drawingsRevision: Int`（单调递增，初值 0）。**每一个**改动 `drawings` 的引擎 API 都必须 `drawingsRevision += 1`：`appendDrawing` / `deleteDrawing(at:)` / 新增的原地替换 API（改样式、锁定 / 解锁）/ 撤销 / 前进。
   - **① 视图触发**：`TrainingView.swift:273` 的 `.onChange(of: engine.drawings.count)` → `.onChange(of: engine.drawingsRevision)`，动作仍是 `lifecycle.autosave(immediate: true)`。
   - **② replay clean-skip 判据**：`TrainingSessionCoordinator.replayBaseline`（`:56`，现为 `(tick, ops, drawings: Int, upper, lower)`）**追加 `drawingsRevision: Int`**；在 `:581`（fresh 会话建基线）与 `:934`（续局建基线）快照 count 的**同一处、同一时刻**一并快照（必须在画线种子注入之后）；`saveProgress` 的 clean-skip 判据（`:607-610`）**追加 `base.drawingsRevision == engine.drawingsRevision`**。
     > **只改 ① 不够**：`saveProgress` 对尚未拥有槽的 fresh replay 会话做 clean-skip（`replayHasPersisted == false`）。改样式不改 tick / ops / 条数 / 周期 → 四项全等 → 提前 return、不写盘。onChange 照常触发了 autosave，写盘却被跳过。
   - **禁止**改用 `.onChange(of: engine.drawings)` 或任何数组值比较：`DrawingObject.==` 排除 `id`。
   - `reviewDrawings` 的 `.count` 触发本期不动。

8. **D29 周期绑定渲染（三模式一视同仁）**
   - `RenderStateBuilder.swift:65-68` 现按 `drawing.panelPosition == (panel == .upper ? 0 : 1)` 过滤 → **改为按 `drawing.period == 该面板当前显示的周期` 过滤**。
   - 该过滤是训练 / replay / 复盘**共用的同一行**（`engine.drawings + (mode == .review ? engine.reviewDrawings : [])`）。**新判据在复盘同样生效，不做模式门控**。
   - 叠加现有 `drawing.revealTick <= tick` 渐显规则**不变**。
   - 某周期不在上下任一面板显示 → 其画线暂不渲染，切回再现。
   - `panelPosition` 仍记当时面板，但**不再参与渲染判据**。

### 3.2 P1b-1b 不做

节点 / 拖节点 / 手势消歧 / 多锚 / 四个新工具（P1b-2）；复盘专属一切（P5）；主页全局默认设置（P6）。

### 3.3 P1b-1b 必须存在的负向测试

0. **内容级 dirty 信号（D30，最高优先，两条测试）**
   - **0a 训练路径**：改样式 / 锁定 / 解锁 / 撤销一次改样式 → `drawingsRevision` 递增 → 触发 `autosave(immediate:)` → 重新加载后样式与锁定态仍在。必须是「**不经过数组增删、只改内容**」的落盘往返。
   - **0b replay clean-skip 路径**（codex R4-high 专项）：**fresh replay 会话**（`replayHasPersisted == false`）里，**不推 tick、不交易、不增删画线、不切周期**，只改一条已有线的样式（或只锁定）→ `saveProgress` **必须真的写盘**，不得 clean-skip；重新加载后改动仍在。
1. **退出画线模式后**单击不选中任何画线、🗑 / 🔒 / ↩ / ↪ 不可达。
2. **锁定线**：🗑 灰、设置面板全灰；但仍可被选中并解锁。
3. **撤销栈生命期**：退出画线模式再进入 → ↩ / ↪ 均为灰（栈已清空）。做新动作后 ↪ 置灰。
4. **选中按 id + 平局规则（D33）**：造两条**同周期、同价格、几何完全重合但 id / 样式不同**的水平线，断言单击选中的是**数组靠后（最上层、后画）那条**的 `id`；随后的改样式 / 锁定 / 删除均作用于该 id，靠前那条**逐字段不变**。另测复盘拼接场景：`engine.drawings` 里的原训练线与 `engine.reviewDrawings` 里的新线重合时，选中的是**复盘新线**。
5. **周期绑定（含复盘，D29）**：某周期不在任一面板显示时其画线不进 `RenderStateBuilder` 输出；切回后出现；`revealTick > tick` 的线仍不渲染。**必须同时覆盖复盘模式的两层**（`engine.drawings` + `engine.reviewDrawings`），并覆盖 `style_json IS NULL` 的 legacy 行（period 由 `anchors.first.period` 兜底）。
6. **复盘外壳仍不变**：复盘无新底栏、浮动钮行为不变（D26 回归保护）。

### 3.4 P1b-1b 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看下行 | 现在是 5 个键：类型 / 🔒 / 🗑 / ↩ / ↪ | |
| 2 | 什么都没选中时看 🔒 和 🗑 | 两者都是灰的 | |
| 3 | 单击一条已有的线 | 线变蓝；🗑 和 🔒 从灰变亮 | |
| 4 | 单击图表空白处 | 落下一条新线（未命中就是落锚） | |
| 5 | 选中一条线，长按工具图标弹面板，改成绿色 | **那条选中的线**变绿（不是下一条） | |
| 6 | 不选中任何线，改成蓝色，再画一条 | 新线是蓝的，之前那条绿线不变 | |
| 7 | 选中一条线，点 🗑 | 弹出「确定删除划线？[删除][取消]」 | |
| 8 | 点「删除」 | 线消失 | |
| 9 | 点 ↩（撤销） | 线回来了 | |
| 10 | 点 ↪（前进） | 线又没了 | |
| 11 | 再点 ↪ | 没反应（↪ 已置灰，深度只有一步） | |
| 12 | 改一条线的颜色，然后点 ↩ | 颜色变回改之前 | |
| 13 | 选中一条线，点 🔒 | 图标变成已锁状态；🗑 变灰；长按工具图标弹出的卡片整片是灰的 | |
| 14 | 再点 🔒 | 解锁，🗑 恢复可用 | |
| 15 | 先画一条绿线，再在**完全一样的价格**上画一条黄线（两条重合），然后单击这个位置、改成紫色 | 变紫的是**后画的那条黄线**（最上面那条）；先画的绿线**仍是绿的**（D33：看得见的那条就是被选中的那条） | |
| 16 | 点「退出」再单击一条线 | **没有任何反应**（不变蓝、🗑 不出现） | |
| 17 | 再进画线模式，看 ↩ / ↪ | 两个都是灰的（撤销栈不跨会话） | |
| 18 | **改样式后立刻杀掉 App**（不点退出、直接从后台划掉），重开续这一局 | 改过的颜色 / 线型 / 粗细 / 标注**全部还在** | |
| 19 | **锁定一条线后立刻杀掉 App**，重开续这一局 | 那条线仍是锁定态（🗑 灰） | |
| 19b | **进「再次训练」新开一局**，什么都不做（不下单、不推进、不加线、不切周期），只把一条已有线改成紫色，**立刻杀掉 App**，重开续这一局 | 那条线是紫色的（这一条专门验 replay 的 clean-skip 没有把改动吞掉） | |
| 20 | 在上半面板（假设显示 60 分）画一条线，单指竖滑切周期让 60 分挪到下半面板 | 那条线**跟着 60 分跑到下半面板**显示 | |
| 21 | 继续切周期，让 60 分完全不显示 | 那条线暂时消失 | |
| 22 | 切回来让 60 分重新显示 | 那条线重新出现，位置不变 | |
| 23 | 结束这一局进复盘，在复盘里单指竖滑切周期 | 训练时画的线**也跟着周期走**（同第 20–22 条规律） | |
| 24 | 找一局**改造前就存在的老记录**，进它的复盘 | 老画线正常显示，位置不错乱 | |
| 25 | 进复盘看画线入口 | 还是浮动铅笔钮，**没有**两行底栏（外壳仍未动） | |
| 26 | 再次训练（replay）模式 | 5 键齐全，行为与训练一致 | |

---

## 4. P1b-2 交付范围（备忘，不在本次 plan 内）

多锚落点泛化 §5.0（`handleDrawingTap` 改用 `manager.activeTool` + `requiredAnchors` 收锚，折线不定锚数特例）；节点模型 §6（纯黑 / 纯白实心圆、仅选中态显示、拖节点几何实时跟随、仅折线可删单节点）；**§14 剩余的节点拖动分支**（起手落在选中线的节点上 → 节点拖动；其余方向分流已由 D32 在 P1b-1a 落地）；四个工具 §5.2 / §5.3 / §5.4 / §5.11（含折线画制中临时 4 键 `[取消划线][完成划线][回退][前进]`）。类型行届时填满 5 个图标。

**P1b-2 必须携带的两组举证测试**：
1. **零迁移举证**（见 §1.1）：channel(3 锚) / rect(2 锚) / polyline(N=2,3,7 锚) 的关系表 + pending JSON blob 存→读→深度相等往返，锚数与每个锚的 `period / candleIndex / price` 逐一断言。
2. **同 period 不变量（D31）**：trend / channel / polyline 各写一条「落第 1 锚 → 竖滑切周期 → pending 被丢弃、不产生混周期画线」的测试；以及 `commit` 前断言对人造混周期输入拒绝提交。

---

## 5. 契约 / 验收指针

- `CONTRACT_VERSION` 保持 `"1.11"`；**三期均无 schema 迁移**；`user_version` 保持 `7`。
- 每期三绿门（作者亲核，clean build）：host `swift test` 全绿 + Mac Catalyst `build-for-testing` SUCCEEDED + iOS build。
- 每期流程：plan → codex 对抗 review 收敛 → `superpowers:subagent-driven-development` → 三绿 → `superpowers:requesting-code-review` + whole-branch codex → PR。
