# 划线工具扩充 · P1b-1b-i 设计 spec：「能选中、能改、能删」

- **日期**：2026-07-23
- **分支**：`drawing-tools-p1b-1b-i`（worktree `.claude/worktrees/drawing-tools-p1b-1b-i`）
- **base**：`d2754df`（= main，含 1a-iv PR #151）
- **host 基线（本机亲跑）**：`swift test` **1661 passed / exit 0**
- **母 spec**：`2026-07-04-drawing-tools-expansion-design.md`（D1–D22 继续生效）
- **拆分 spec**：`2026-07-10-drawing-tools-P1b-split-addendum.md` §6（本 spec 的**上游范围定义**；下面 §0 逐条声明哪些被取代）
- **前作 spec**：`2026-07-18-drawing-tools-P1b-1a-iii-panel-redesign-design.md`（常驻面板重设计）
- **决策编号**：本 spec 从 **D49** 起（D1–D48 已被前作占用）

---

## 0. 本 spec 的地位：§6 有一部分已被 1a-iii 作废

拆分 spec §6 写于 **2026-07-10**，那时 1a-ii / 1a-iii / 1a-iv 都尚未落地。1a-iii 把「长按工具图标弹设置卡片」整个换成了**常驻样式面板**，因此 §6 中若干条款的**前提已不成立**。

本 spec 的第一职责是**逐条声明取代关系**，避免实施时照抄一份已过时的文档（[[feedback_plan_embedded_facts_unreliable]]：计划内嵌的"事实"必须逐条实测）。

下表每一行的「现状」列都是对 `d2754df` **源码实测**的结论，不是从 spec 推断的。

| §6 条款 | §6 原文前提 | `d2754df` 实测现状 | 本 spec 处置 |
|---|---|---|---|
| §6.1 #1 底栏 🗑 | 「与 1a-ii 的①类型键并列」 | `DrawingBottomBar` 是**单行**，只有「类型」键 + `Spacer`（`UI/DrawingModeBar.swift:14-25`） | **继续有效**，🗑 与「类型」键并列（D24 五键骨架不变，②🔒④↩⑤↪ 仍留 1b-ii） |
| §6.1 #2 工具图标 toggle | 「类型行的工具图标改为 toggle」 | 图标**恒亮、短按 no-op**，注释写死「本期无选中、不做 toggle」（`UI/DrawingTypeOverlay.swift:22-31`） | **继续有效**，本期就是接它 |
| §6.1 #5 设置面板消歧 | 「**长按**工具图标弹面板」 | ❌ **前提已废**：面板是常驻的（`UI/DrawingStylePanel.swift`），长按手势已删（`DrawingTypeOverlay.swift:5-8` 注释明载） | **由 D49 取代**（见 §2） |
| §6.4 验收 #9 | 「长按工具图标弹面板，改成绿色」 | ❌ 同上，做不出这个动作 | **由 §7 重写的验收清单取代** |
| §6 全文 | （未考虑命中盾） | 1a-iii 引入 `DrawingSession.PanelShield` 三态双层盾（`Drawing/DrawingSession.swift:51-86`） | **由 D53 补齐**（§6 对选择态只字未提） |
| §6 全文 | （未考虑 1a-iv 交接） | 1a-iv 交接两条硬要求（append 拒绝信号上溯 / init-decode 校验重估） | **由 D50 / D52 处置** |
| D38 的**编码方式** | 「工具非 nil = 画线态 / 工具 nil = 选择态」 | ❌ **实测有坏状态**：`restoreDrawingSessionAfterPeriodChange`（`TrainingEngine.swift:422`）在工具为 nil 时早退，而此前两面板已被切回 `.autoTracking` → 裂脑 | **由 D57 取代编码方式**；D38 的**语义**全部保留 |

**§6 中继续原样生效、本 spec 不重复展开的部分**：D30 / D33 / D34 / D37 / D39 / D40 / D41 全部决策语义 + **D38 的语义（编码方式除外，见 D57）**，以及 §6.3 的负向测试 0 / 0b / 0c / 1 / 1b（按 `mode` 重述，断言内容不变）/ 1b2 / 1b3 / 1b4 / 1b5 / 1c / 2 / 3 / 4 / 5 / 5b / 6 / 7 / 8 / 9（§6 中一条都不删；本 spec §6 只**追加**）。

---

## 1. 交付范围

### 1.1 做

1. **底栏补 🗑 删除键**，与「类型」键并列。无选中时灰、有选中时亮。
2. **画线态 / 选择态分态**（D38）：类型行的水平线图标改为 toggle。
3. **选中**：选择态下单击 → 对该面板的可见画线集合做 `hitTest`，逆序取第一个命中（D33）；命中者渲染为选中高亮，🗑 转亮。
4. **改**：常驻面板的 5 组样式控件，有选中时作用于选中线（**选中即回显**，D49），无选中时改「下一条线的默认」。
5. **删**：点 🗑 → 确认框「确定删除划线？[删除][取消]」→ 确认才删。
6. **内容级 dirty 信号**（D30）：新增 `drawingsRevision`，autosave 触发器从 `drawings.count` 换成它。
7. **命中集合 ≡ 渲染集合**（D40）：抽共享纯函数，两边同源。
8. **复盘门控**（D34）：`flow.mode == .review` 时不给选中能力。

### 1.2 不做

- 锁定 / 解锁**动作与 UI**（🔒 键、面板灰态）、撤销 / 前进、底栏 ②🔒④↩⑤↪ → **1b-ii**
  ⚠️ **但 `locked` 的写入边界闸门属于本期**（D60）：本期新建的 `updateDrawingStyle` / `deleteDrawing(id:)` 必须拒动 `locked == true` 的对象。「**能锁定**」（1b-ii）与「**不许改已锁定的**」（本期）不是同一件事——后者是本期正在开的那两个写入面自己该带的闸。
- 节点 / 多锚 / 四个新工具 → **P1c**
- 复盘的选中与复盘专属一切 → **P5**
- 主页全局默认设置 → **P6**
- **不删** `DrawingToolManager` 死代码（1a-iv 残留①）：本期新增 id 寻址的删除 API，但不动它的 index 版本（CLAUDE.md §3：无关死代码提出来、不删）。
- **不动** `reviewDrawings` 的 `.count` 触发器（D56）。

---

## 2. 决策 D49–D63

> **D57–D63 全部是 codex 对抗性评审的产物**（均已对源码 / 上游 spec 原文实测证实，未采信转述）：
>
> | 轮 | 级别 | 决策 | 它推翻了什么 | 我的处置 |
> |---|---|---|---|---|
> | R1 | high | **D57** | 母 spec D38 的「用 `activeDrawingTool == nil` 表示选择态」编码——切周期善后函数会在 nil 时早退 → 裂脑 | 全采纳 |
> | R2 | high | **D58** | 编辑路径缺了新建路径已有的 `visibleGeometry` 门——同一不变量两条写入路径强制程度不一致 | 采纳；**严重性下修一档**（`.segment` 面板走不到；`.ray` 不可见是 viewport 相关、可恢复，非永久丢失） |
> | R3 | medium | **D59** | **本 spec 上一稿 D58 内部的自相矛盾**：subtype 可用性下沉引擎，labelMode 归一化却「信任面板」 | 全采纳 |
> | R3 | high | **D60** | 编辑 / 删除无视已持久化的 `locked` → 可静默摧毁一个跨版本的耐久性保护 | 全采纳 |
> | R4 | high | **D61** | **本 spec 上一稿 D59 自身的破坏性**：`textColorToken` 无条件派生会抹掉高版本导入的独立字色 | 全采纳 |
> | R4 | high | **D62** | `updateDrawingStyle` 是 `public` → 包外可绕过 D58 那道只能放在 UI 层的 viewport 门 | 全采纳（降 internal + 源码守卫） |
> | R4 | medium | **D63** | 选中在「几何不可见」后仍存活 → 🗑 可删一个用户看不见的对象 | **部分采纳**：问题成立、危害照堵；但**不采纳它「清空选中」的处方**（与 1a-iv 的平移惯性冲突，会抖掉选中）→ 改为结构性/几何性分流 |
>
> 共同形状：**我写的东西"符合上游 spec"，但没人问过"坏数据会怎样 / 直接调用者会怎样 / 高版本写的数据会怎样"**（[[feedback_internal_review_misses_bad_data]]）。
> 收敛方向也一致：**把不变量钉在写入边界上，让坏状态不可表达**，而不是逐个补调用点或依赖 UI 自觉。
> **其中 D59 与 D61 是我修上一轮 finding 时自己引入的新问题**——印证 [[feedback_internal_review_misses_bad_data]]「修 symptom 会挪动失败面」。

### D49 选中即回显；面板显示的样式是**派生值**，不存第二份状态

**用户裁决（2026-07-23）**：选中一条线时，常驻面板的控件立刻显示**那条线的当前样式**；改动只作用于那条线；取消选中后面板恢复显示默认样式。改选中线的样式**不回写**「下一条线的默认」。

**形状（load-bearing）**：面板显示的样式是**每次求值现算的派生值**，不是拷贝进某个 `@State` 的副本。

```
面板显示的 style =
    有选中 → engine.drawings.first { $0.id == selectedID } 的 5 个样式字段
    无选中 → session.defaultStyle

面板控件写入 =
    有选中 → engine.updateDrawingStyle(id: selectedID, style: 新值)
    无选中 → session.setDefaultStyle(新值)
```

**为什么必须派生、不许拷贝**：常驻面板长期存活（不像旧的长按卡片改完即关），任何拷贝出来的第二份样式状态都会与 `engine.drawings` 里的真值漂移——这正是 1a-iii 当初把 `DrawingStyleParams` 改成直读 `session.defaultStyle` 的理由（`UI/DrawingStyleParams.swift:4` 注释：「两份状态必然漂移」）。本期把同一条纪律扩到选中线上。

**依赖方向约束**：`DrawingSession` **不得**反向依赖 `TrainingEngine`（今天 `engine.drawingSession` 是 `public let`，反向依赖即循环）。因此上面的「派生 + 路由」两段逻辑**放在 UI 调用方**（同时持有 engine 与 session 的那一层），`DrawingStyleParams` 改为接收
- `style: DrawingDefaultStyle`（调用方算好的派生值）
- `onChange: (DrawingDefaultStyle) -> Void`（调用方路由）

**这不新增任何状态**：传的是派生值而非拷贝的状态，故不重新引入 1a-iii 消灭掉的漂移。

### D50 编辑 API = `updateDrawingStyle(id:style:) -> Bool`，**不是**通用替换，更不是「先删后加」

```swift
// ⚠️ internal，不是 public —— 见 D62（viewport 门只能在 UI 层，就不给包外绕过它的口子）
@discardableResult
func updateDrawingStyle(id: DrawingID, style: DrawingDefaultStyle) -> Bool
```

- **只改 5 个样式字段** + 派生的 `isExtended` 与 `textColorToken`；`id` / `anchors` / `period` / `panelPosition` / `revealTick` / `locked` / `text` / `fontSize` / `textForm` / `tailAnchor` **一律逐字段不动**。
- 成功 → `drawingsRevision += 1`，返 `true`。
- `id` 不在 `drawings` 里 → **零改动**、`drawingsRevision` **不递增**、返 `false`。

**这条如何收口 1a-iv 交接①**（原文：「编辑路径 append 返 false 时绝不能已删原线 + 给 UI 反馈」）：

1. **「已删原线」不可表达**——本 API 是原地替换单个数组元素，流程里**根本没有"删"那一步**，也不经过 `appendDrawing`。这是「让矛盾状态不可表达」而非「小心翼翼地按正确顺序操作」（[[feedback_internal_review_misses_bad_data]]：修 root cause 不修 symptom）。
2. **UI 反馈路径可达且必须接**：返 `false` 的唯一情形 = 选中的线已不在 `drawings` 中。UI 消费方式 = **清空选中 + 🗑 回灰**（与 D54 的四种清空情形合流，不是新语义）。

**派生 / 语义闸的单点约束 → 见 D59**（共享的 failable `withStyle`）。**locked 保护 → 见 D60**。

### D58 编辑路径必须与提交路径**同门**：不得靠改样式造出「渲染不出」的线

> **来源：codex 对抗性评审 R2 唯一 high finding，已对源码实测证实。**

**实测事实**（`Drawing/HorizontalLineTool.swift:50-75`）：

- `lineXRange` 对两种情形返回 nil → `visibleGeometry` 随之 nil → 该线**既画不出、也命不中**（render / hitTest / 标注三者共用同一判据，D40）：
  1. **`.segment`**：水平线无线段语义，**恒 nil**、**与 viewport 无关**；
  2. **`.ray` 且 `anchorX >= mainChartFrame.maxX`**（锚点位于/越过右缘）：**与 viewport 相关**。
- **新建路径已有这道门**：`ChartContainerView.handleDrawingTap:303`
  `guard HorizontalLineTool.visibleGeometry(for: committed, mapper: mapper) != nil else { return }`，注释原文写明目的是「拒绝**不可见**画线再落库……幽灵线」。
- **而 D50 的 `updateDrawingStyle` 会改 `lineSubType`，走的是另一扇门、没有这道闸** → 同一类坏对象换个入口照样造得出来，并且按 D56 立刻 autosave。

**严重性如实校准（不过度宣称，codex 的表述在这一点上偏重）**：

- `.segment` 那一支**面板走不到**——它在设置面板里是**灰的**（`Drawing/DrawingStyleAvailability.swift:6-11`：`.straight`/`.ray` 可选，`.segment` 返 false）。
- 可达的是 **`.straight → .ray` 且锚点在右缘之外**。而 `.ray` 的不可见是 **viewport 相关**的：推进 K 线或平移让锚点重新落回图内后，该线会**恢复可见、可选、可删**。因此**不是**「永久不可恢复的数据丢失」，codex 原文的 `cannot be recovered` 说过头了。
- 但它仍然是「用户按一下线就没了、且当下选不中删不掉」的坏交互；更要命的是**两条写入路径对同一不变量强制程度不一致**——这本身就是缺陷，与触发频率无关。

**修法 = 两层同门，均 fail-closed**：

| 层 | 判据 | 为什么放这一层 |
|---|---|---|
| **引擎**（viewport 无关，恒开） | 拒绝把 `lineSubType` 改成「该 `toolType` **恒**不可渲染」的值（水平线的 `.segment`）→ 返 `false`、**零改动**、`drawingsRevision` **不递增**。**具体由 D59 的 failable `withStyle` 统一承担**（本条只是它的一个 case，不另写实现） | 引擎层没有 mapper，只判得了 viewport 无关那一支；而那一支恰是**恒 nil**，也是「解码坏数据 / 将来 UI 放开 `.segment`」的兜底。判据复用 `DrawingStyleAvailability`（与面板灰态同一真相，**禁止另写一份**） |
| **UI**（viewport 相关） | 应用 `lineSubType` 改动**之前**，用 **`selectedPanel` 的 mapper** 对**候选对象**跑 `HorizontalLineTool.visibleGeometry`；为 nil → **不应用、不写库**、给反馈（选中**保留**，🗑 仍亮） | 与新建路径的门**同一个函数、同一层**（`handleDrawingTap:303` 也在 UI 层）→ 两条写入路径对称。路由细节由实施计划定，**约束是判据必须复用 `visibleGeometry` 且取 `selectedPanel` 的 mapper**，不得另写一份几何判断 |

**只有 `lineSubType` 需要 viewport 预检**：`lineStyle` / `thickness` / `colorToken` / `labelMode` 都不参与 `lineXRange` / `visibleGeometry` 的判据，改它们**不可能**把可见变不可见。实施时**不得**给这 4 项加预检（无谓地引入 viewport 依赖，还会让常见路径变脆）。

**`labelMode` 归一化必须同样对称**：面板在用户改 `lineSubType` 时会跑 `DrawingStyleAvailability.normalizedLabelMode`（`UI/DrawingStyleParams.swift:33-35`），使 `(ray, .left)` 这类无效组合不可表达。D49 已规定面板经**单一路由**写出一个完整的 `DrawingDefaultStyle`，故编辑路径天然继承这条归一化——**实施时不得绕过面板另开一条编辑入口**，否则 `(ray, .left)` 会变成只在编辑路径上可达的坏组合。

### D59 语义闸下沉到**写入边界**：共享的 **failable** `withStyle`（不是"信任面板会归一化"）

> **来源：codex 对抗性评审 R3 medium finding。它抓到的是本 spec 上一稿 D58 内部的自相矛盾**——同一个决策里，`lineSubType` 可用性我下沉到了引擎，`labelMode` 归一化却写成「编辑路径天然继承面板的归一化」。同一条推理线两个待遇：前者认「公共写入面必须自己把关」，后者认「信任唯一的 UI 路由」。**后者是错的**，理由与 D58 逐字相同：`updateDrawingStyle` 是 `public` 的，任何直接调用者（或将来一个非面板的编辑入口）都能落一个 `(ray, .left)` 这种面板永远产不出的组合。

`DrawingObject` 有四条语义必须在**源码中只出现一次**，且必须在**写入边界**上强制，不能靠调用方自觉：

| 语义 | 内容 |
|---|---|
| 派生 ① | `isExtended == (lineSubType == .ray)` |
| 派生 ② | `textColorToken` **仅当它本来就等于 `colorToken` 时**才跟随线色；已是独立字色则原样保留 —— **完整规则见 D61**（codex R4 修正了本条的原始写法，原写法会抹掉高版本导入的独立字色） |
| 归一化 | `labelMode` 必须经 `DrawingStyleAvailability.normalizedLabelMode(current:lineSubType:)`（挡 `(ray, .left)`） |
| 可用性 | `lineSubType` 必须是该 `toolType` **可渲染**的值（水平线的 `.segment` 恒不可渲染 → 拒） |

**形状**：抽一个**failable** 纯函数

```swift
extension DrawingObject {
    /// nil = 该样式对本对象的 toolType 语义上不成立（当前唯一情形：水平线的 .segment）
    func withStyle(_ s: DrawingDefaultStyle) -> DrawingObject?
}
```

- 返 nil 的判据**必须复用 `DrawingStyleAvailability`**（与设置面板灰态**同一真相**，禁止另写一份）。
- 非 nil 时：归一化 `labelMode` + 派生 ①② + 其余字段**逐字段原样拷贝**。
- **两个写入点共用它，各自传播失败**：
  - `DrawingSession.commitPending`（已经是 `-> DrawingObject?`）→ nil 即不提交；
  - `TrainingEngine.updateDrawingStyle` → nil 即返 `false`、零改动、`drawingsRevision` 不递增。
- **源码守卫测试**钉死：上表四条语义的表达式在 `Sources/` 中**各只出现一次**。

**与 D58 的分工（codex 的建议我照采）**：语义闸（viewport 无关）**全部**在引擎/共享层；UI 层**只**保留 viewport 相关的那一项（`visibleGeometry` 预检）。这样「哪层管什么」有一条干净的判据，不再是个案裁量。

### D60 `locked` 在编辑 / 删除的写入边界上 fail-closed（现在就设闸，不等 1b-ii）

> **来源：codex 对抗性评审 R3 high finding。已核实上游 spec 的原文（未采信 codex 转述）：**
> - 母 spec `2026-07-04-drawing-tools-expansion-design.md:225`：「短按锁定选中线（🔓→🔒图标态），**锁定后该线不可改**；……锁定状态**持久化**（存记录 / 复盘存档）。」
> - 拆分 spec §7.2：「**锁定线仍可被选中**（否则无法解锁），但 🗑 灰、设置面板全灰、**不可改样式**。」

**实测的可达性**：`locked` 是**已持久化字段**（`Models/Models.swift:254`，`init` 默认 `false` `:271`），`routeDrawingCommit` 一直原样保留它（`TrainingEngine.swift:1139`）；但**本构建没有任何代码把它写成 true**（`GestureClassifiers` 里那个 `locked` 是手势仲裁的同名局部变量，无关）。因此 `locked == true` 的对象只能**从解码进来**——而这恰恰是 P1a 建立 lossy 字节保真前向兼容所针对的场景，且 [[project_app_public_release_intent]] 把「版本错位真会发生」定为全项目约束。

**风险**：1b-ii（或更高版本）锁上的线，在本构建里能被改样式、能被删除，然后 autosave 落盘 → **一个耐久性保护被静默摧毁，且不可逆**（本期无 undo，那是 1b-ii）。

**决策**：`updateDrawingStyle` 与 `deleteDrawing(id:)` 都**先判 `locked`**——目标 `locked == true` → 返 `false`、**零改动**、`drawingsRevision` **不递增**。

**为什么这不算侵入 1b-ii 的范围**：1b-ii 交付的是「**能锁定**」（🔒 键、锁定 / 解锁动作、UI 灰态）。本条只是在 1b-i **正在新建的那两个写入面**上，拒绝改动一个已经标记为锁定的对象。二者不是同一件事。而且：

- **今天零行为变化**：本构建产不出 `locked == true` 的对象 → 这道闸在所有现有路径上**永不触发**；
- **成本极低**（两个 guard + 两条测试），**收益是不可逆数据保护**；
- 与 D58 / D59 同一条纪律：**不变量在写入边界强制，UI 灰态是纵深防御而非唯一防线**。1b-ii 的面板灰态照做，但那时它是第二道，不是第一道。

**交接 1b-ii（必须，否则解锁功能会被本闸卡死）**：解锁动作**不得**走 `updateDrawingStyle`（它改的是 5 个样式字段，`locked` 不在其中，且被本闸拒绝）。1b-ii 必须新增一个**独立**的 `setDrawingLocked(id:locked:) -> Bool`，该 API **豁免**本闸（它就是唯一被允许改 `locked` 的入口），并同样 `drawingsRevision += 1`。已写入 §9。

### D61 跨版本字段保真：派生**只作用于"本来就是派生的"对象**（`textColorToken`）

> **来源：codex 对抗性评审 R4 high finding。采纳。**

D59 把 `textColorToken == colorToken` 列为写入边界不变量。**但它对"从高版本解码进来的对象"是破坏性的**：`textColorToken` 是**已持久化字段**（`Models/Models.swift:257`），而独立字色是 **P3 标注文字工具**的范围（`Drawing/DrawingSession.swift:158-160` 注释明载「独立『字色』是 P3 的标注文字工具，本期不引入」）。于是：

> 一条从高版本导入、`textColorToken != colorToken`（用户特意设过独立字色）的线，在本构建里**只要改一下粗细或线型**，`withStyle` 就会把字色静默抹成线色，并按 D56 立刻 autosave → **不可逆的跨版本数据丢失，而且触发动作与字色毫无关系**。

**这条与 D60 是同一条推理**（解码自高版本的数据真实存在，见 [[project_app_public_release_intent]]）。既然对 `locked` 认这套推理，就不能对 `textColorToken` 不认。

**修正后的派生规则**（写进 D59 的四条语义里，取代原派生 ②）：

```
新 textColorToken =
    old.textColorToken == old.colorToken  →  style.colorToken   // 本来就是派生的：继续跟随线色
    否则                                   →  old.textColorToken // 已是独立字色：原样保留，绝不覆盖
```

- 本构建**新建**的线恒满足 `textColorToken == colorToken`（`commitPending` 就是这么造的）→ 对本版本产生的所有线，行为与修正前**逐字一致**。
- 只有「本构建管不了、但确实存在」的独立字色会被保住。**本期不提供任何设置独立字色的入口**（那是 P3），我们只是不去破坏它。

### D62 `updateDrawingStyle` 降为 **internal** + 源码守卫（viewport 门无法下沉，就不给绕过它的口子）

> **来源：codex 对抗性评审 R4 high finding。采纳，采用它给的第一个方案。**

D58 把 `lineSubType` 的 viewport 预检放在 UI 层——这是**原理性**的：引擎层没有、也不该有 mapper。但若 `updateDrawingStyle` 是 `public`，任何包外调用者都能绕开那道门、落一条 `visibleGeometry == nil` 的射线并被 autosave。**这与 R3-F2 是同一个信任边界问题**（codex 原话：`This repeats the same trust-boundary problem D59 fixes`）。

**决策**：`updateDrawingStyle(id:style:)` 的访问级别是 **`internal`**，不是 `public`。

- 唯一合法调用者 = 包内那条持有 `selectedPanel` mapper 的 UI 路由；
- **加源码守卫测试**钉死 `Sources/` 中只有那一个调用点（新增调用点必须同时补 viewport 预检，测试会当场红）；
- **这不是新发明**：`DrawingSession` 的全部 mutator 早就是 internal + 源码守卫（`Drawing/DrawingSession.swift:21-28` 大注释写明理由——public mutator 会让包外绕过唯一正确入口）。本条只是把同一条纪律套到新开的写入面上。
- 测试经 `@testable import` 照常可调，N12 / N13 不受影响。
- **`deleteDrawing(id:)` 保持 `public`**：删除不产生坏数据，其唯一不变量（`locked`）已由 D60 在引擎层 fail-closed，不依赖 viewport。

### D63 「结构性不可见」清空选中，「几何性不可见」只禁用破坏性操作

> **来源：codex 对抗性评审 R4 medium finding。问题成立，但**⚠️**本决策刻意偏离 codex 给的处方，理由如下。**

**codex 指出的真问题**：D54 清空选中的判据是 `visibleDrawings(for: selectedPanel)`，而 §3 定义的这个共享函数只管**面板归属 + `revealTick`**（无 mapper 入参）；真实渲染 / 命中路径**还有第二道** `visibleGeometry`（价格越出主图纵向范围、射线锚点越过右缘 → nil）。于是选中可以在线已经看不见之后继续存活，🗑 仍亮 → **用户可以删掉一个自己看不见的东西**。这个危害是真的。

**codex 的处方（clear selection when visibleGeometry fails）我不采纳**，因为它与 1a-iv 已交付的行为冲突：

- 1a-iv 放开了画线模式内的**平移与惯性减速**；
- `.straight` 线的几何可见性**随平移连续变化**（价格是否落在当前纵向范围内）；
- 于是「一次滑动的余速把选中悄悄抖掉、滑回来发现选中没了」会成为常态。**这比留一个陈旧选中更糟**，且不可预测。

**本决策：按"不可见的性质"分流，而不是一刀切**——

| 性质 | 判据 | 例子 | 处置 |
|---|---|---|---|
| **结构性**：线根本不属于这个面板 / 还没出现 | `visibleDrawings(for: selectedPanel)` 不含该 id（§3，无 mapper） | 切周期、线迁到另一面板、`revealTick` 未到 | **清空选中**（D54 clause 3 原样保留）。这些都是**离散的、用户主动触发的**变化，不会抖 |
| **几何性**：线在这个面板上，只是此刻滑出可视区 | 该对象在 `selectedPanel` 当前 mapper 下 `visibleGeometry == nil` | 价格滑出纵向范围、射线锚点越过右缘 | **保留选中**，但**🗑 置灰、删除动作拒绝执行**（fail-closed）。滑回来即自动恢复可用 |

**为什么这样就够**：codex 指名的危害是「🗑 对一个用户看不见的对象仍可点」。把 **🗑 的可用性**绑到几何可见性上，这个危害被直接消掉；而选中态本身不抖，用户也不会因为一次惯性丢掉操作对象。**看不见的东西不许删**，但**看不见不等于失去它**。

- 样式编辑**不禁**（改一条当前看不见的线的颜色是无害且非破坏性的；且 D58 的 subtype 预检本就在同一处求值，天然拒绝把它变得更不可见）。
- 🗑 置灰的判据与 D58 的预检**必须复用同一个** `visibleGeometry` 求值（同一函数、同一 mapper、同一 `selectedPanel`），不得另写一份。

### D51 删除 API = `deleteDrawing(id:) -> Bool`（id 寻址，不用下标）

```swift
@discardableResult
public func deleteDrawing(id: DrawingID) -> Bool
```

- 选中态存的是 `id`，而数组下标会因任何增删而漂移；用下标删 = 竞态下删错线。
- 成功 → 移除该条 + `drawingsRevision += 1` + 返 `true`；`id` 不存在 → 零改动、不递增、返 `false`（UI 同 D50 清空选中）。
- **现有 `deleteDrawing(at index:)` 保留不动**：已实测其在 `Sources/` 中**零生产调用点**（只有定义与注释），且有测试钉着；删它属于「清理无关代码」，不在本期范围（CLAUDE.md §3）。

### D52 1a-iv 交接②（`init` / `decode` 层 period 校验）重估结论 = **仍不加闸**

1a-iv 把 period 自洽校验加在了新增写入面（`appendDrawing` / `appendReviewDrawing` / `commitPending`），**刻意不加**在 `init` 的 `self.drawings = …` 与复盘装载的整体赋值上，理由是「resume 路径 fail-closed 会静默吞掉用户已画的线」。1a-iv 要求 1b-i 重估。

**重估结论：维持不加闸。** 理由：

1. 加闸的代价是**静默丢弃用户画过的线**——装载期拒绝一条线，用户没有任何补救手段，且不可逆。这类数据丢失比「留一条渲染不出的坏线」严重得多（[[project_app_public_release_intent]]：按公开发布标准，跨版本数据保真优先）。
2. 1b-i 之后，`drawings` 里的线**多了一条用户侧处置通道**（选中 → 删除），处置权交给用户优于程序静默吞。

**但不得过度宣称**（这是本条最容易写错的地方）：并非所有 period 不自洽的历史线都变得「用户可删」。一条线若因几何原因**渲染不出**（`visibleGeometry == nil`），它同样**命不中**（`hitTest` 与渲染同源，D40），因此**选不中、也就删不掉**——这类线本期的可达性与 1a-iv 之前**逐字一致**，本 spec 不改善也不宣称改善。列入 §8 已知限制。

### D53 常驻面板的命中盾对**选择态同样生效**，盾语义一字不改

`ChartContainerView.handleDrawingTap`（`Render/ChartContainerView.swift:287-291`）现有三态盾判定：

| 盾态 | 含义 | 本期行为 |
|---|---|---|
| `.unshielded` | 无面板覆盖 | 正常（画线态落锚 / 选择态 hitTest） |
| `.pending` | 面板已挂载、几何未收敛 | **拒收一切 tap**（fail-closed） |
| `.rect(r)` | 已知覆盖区 | 区内拒收、区外正常 |

**约束：盾判定必须位于「画线态 / 选择态」分叉之前**。落在面板上的点击**既不落锚、也不选中**。

代价与 1a-iii 已接受的一致：面板刚展开的 `.pending` 极短瞬间少响应一次点击。收益不变：永远不会因盾未就位而落出幽灵线并 autosave（不可逆）。

### D54 选中态的生命期与清空判据

- **画线态**：单击**恒落锚**、**不调用 `hitTest`**；选中恒为空。
- **选择态**：单击调用 `hitTest`、**不落锚**；命中 → 选中它（替换原选中）；未命中 → 清空选中（D37）。
- **新提交的线不自动选中。**
- **选中 = `(selectedPanel, selectedDrawingID)` 二元组**，存进 1a-ii 建立的共享容器 `DrawingSession`（与 `activeDrawingTool` 同源）。渲染与操作**都按二元组**，不是 id-only。
- **清空选中的全部情形**（每次清空后 🗑 回灰）：
  1. 退出画线模式；
  2. 从选择态切回画线态（点亮工具图标）；
  3. `visibleDrawings(for: selectedPanel)` 不再含 `selectedDrawingID`（切周期、或该线改由另一面板显示）——判据**按 `selectedPanel`**，哪怕同 id 在**另一个**面板可见也照样清空；
  4. 选中线被删除；
  5. `updateDrawingStyle` / `deleteDrawing(id:)` 返 `false`（D50 / D51）。
- **面板收起（`typeRowExpanded == false`）不改变画线 / 选择态，也不清空选中**：收起期间选择态仍可选中 / 取消，🗑 仍可删。但工具图标随面板一起不可见，故**收起期间无法切回画线态**——要画线需再点一次底栏「类型」键展开面板。这是交互约束，**不是缺陷**，列入 §8。

### D57 选择态是**显式状态**，不用 `activeDrawingTool == nil` 编码（取代 D38 的编码方式，保留 D38 的语义）

> **来源：codex 对抗性评审 R1 唯一 high finding，已对源码实测证实。** 母 spec D38 把两个态编码成「工具非 nil = 画线态 / 工具 nil = 选择态」。这个编码是**错的**，理由不是风格问题而是一个可复现的坏状态：

**实测的裂脑路径**（`TrainingEngine.swift:386-428`）：

```
用户在选择态（按 D38 编码：activeDrawingTool == nil）竖滑切周期
  → switchPeriodCombo 走到 :407-408
      _ = upperPanel.reduce(.periodComboSwitched)   // 两面板被硬切回 .autoTracking
      _ = lowerPanel.reduce(.periodComboSwitched)
  → :411 restoreDrawingSessionAfterPeriodChange()
  → :422 guard drawingModeActive, let tool = activeDrawingTool else { return }
                                   ^^^^^^^^^^^^^^^^^^^^^^^^ nil → 整个善后早退
  ⇒ drawingModeActive == true，但两面板都不在 .drawing
  ⇒ 正是 1a-iv 花力气消灭的不变量「会话开 ⇔ 两面板 .drawing」被破坏
```

后果：切周期后选择态的点击不再进 `handleDrawingTap`（面板已回 `.autoTracking`，tap 被路由去十字光标），**验收 #18 走的正是这条路**。
（1a-iv 的作者在 `:416-417` 注释里已经预判到 1b-i 会有选择态，但只防了「别误入选择态」，没防「选择态使这个 guard 失效」。）

**根因**：`activeDrawingTool == nil` 同时承载了两个互不相同的含义——「没有会话 / 没在画线」与「有会话、只是这一刻不落锚」。现有代码有 **6 处** `activeDrawingTool` 消费点（已逐一实测），其中 3 处 `guard let tool = …` 按前一个含义早退。用 nil 编码，就是让这两个含义**不可区分**。

**修法（让裂脑态不可表达，而不是逐个补调用点）**：

```swift
// DrawingSession 新增
public enum DrawingSessionMode: Equatable, Sendable { case draw, select }
public private(set) var mode: DrawingSessionMode = .draw
```

- **会话存活期间 `activeDrawingTool` 恒非 nil**（选择态"记住"当前工具，与 1a-iii「记住工具」一致）；nil 重新回到唯一含义 =「没有会话」。
- 于是 `restoreDrawingSessionAfterPeriodChange` 的 guard **在两个态下都成立**，善后照常跑、两面板照常重新武装 —— **上面那条裂脑路径结构上不存在**，不需要在它里面加任何分支。

**随之而来的必须改动（缺一即回归）**：

| 位置 | 现状 | 改成 |
|---|---|---|
| `DrawingSession.activate(tool:)` `:92-97` | `drawingModeActive = true` → `guard activeDrawingTool != tool else { return }` | **`mode = .draw` 必须写在幂等 guard 之前**。否则「选择态下再点亮同一个工具」会被幂等 guard 吞掉、态切不回去（本条极易漏，是本次修法自带的新陷阱） |
| `DrawingSession.addAnchor` `:118-119` | `guard drawingModeActive, activeDrawingTool != nil` | 追加 `mode == .draw`（选择态恒不落锚，fail-closed） |
| `DrawingSession.commitPending` `:136` | `guard let tool = activeDrawingTool, …` | 追加 `mode == .draw` |
| `DrawingSession.deactivate()` `:101-106` | 清工具 | 追加 `mode = .draw`（复位，防下次开会话继承旧态） |
| `ChartContainerView.handleDrawingTap` `:274` | `guard drawingModeActive, let tool = …` | guard **原样保留**；其后先走盾（D53），**再** `switch session.mode` 分派落锚 / hitTest |
| `TrainingEngine.restoreDrawingSessionAfterPeriodChange` `:421` | guard 会在选择态早退 | **guard 一字不改**（现在恒成立）；但**必须追加清空选中**——锚绑旧周期坐标系，选中的线换周期后不该继续被选中。fail-closed 分支 `endDrawingSessionIfActive()` 同样要清空选中并复位 `mode` |

**新增 mutator**：`setMode(_:)`，internal（沿用容器纪律：mutator 一律 internal，不加 `public`——`DrawingSession` 顶部大注释写明理由）。切到 `.select` 时**保留 `activeDrawingTool`、丢 pending 锚**（半成品多锚线不得跨态存活）；切回 `.draw` 时沿用记住的工具。

**不再需要 `disarmTool()`**（本 spec 上一稿的设计）——它的存在本身就是 nil 编码的产物。

**与母 spec D38 的关系**：D38 的**语义**（两个态、切换入口是类型行工具图标 toggle、画线态恒落锚不 hitTest、选择态恒 hitTest 不落锚）**全部保留**；只有「用 `activeDrawingTool` 是否为 nil 来表示」这一条**编码方式**被本决策取代。§6.3 的负向测试 1b 相应改为按 `mode` 断言（断言内容不变）。

### D55 选中高亮是**瞬时 UI 状态**，绝不落盘

- 选中线渲染为系统 `accentColor`（与类型行图标高亮框同源），**不占用** `DrawingColorToken` 值域。
- `RenderStateBuilder` **只在渲染 `selectedPanel` 那个面板时**把 `selectedDrawingID` 带进 `KLineRenderState`（该类型今天**没有** selected 概念）；`KLineView+Drawing` 的 dispatch 据此对该条走高亮。
- `DrawingTool.render` 增 `isSelected: Bool` 入参。这是**源码 API 面**的破坏，按 D28：`CONTRACT_VERSION` 只覆盖持久化契约、不覆盖 Swift API 面 → **不 bump、不留 shim**（`KlineTrainerContracts` 是仓内模块，无外部 conformer，同 PR 内迁完）。
- **持久化零改动**：`DrawingObject` 不新增字段，选中态不进任何存储路径。

### D56 `drawingsRevision` 只覆盖 `drawings`，不覆盖 `reviewDrawings`

- `TrainingEngine` 新增 `public private(set) var drawingsRevision: Int = 0`（单调递增）。**每一个**改动 `drawings` 的引擎 API 都必须 `+= 1`：本期为 `appendDrawing` / `deleteDrawing(at:)` / `deleteDrawing(id:)` / `updateDrawingStyle`。
- `TrainingView.swift:355` 的 `.onChange(of: engine.drawings.count)` → `.onChange(of: engine.drawingsRevision)`，动作仍是 `lifecycle.autosave(immediate: true)`。
- **`reviewDrawings` 的 `.count` 触发器（`TrainingView.swift:358`）一字不动**：复盘本期不获得改样式能力（D34），故 `reviewDrawings` 不存在「不改数组长度的内容变更」。
- **交接**：将来复盘获得改样式能力（P5）时，**必须同期**给 `reviewDrawings` 补等价的 revision 触发器，否则复盘改样式同样永不落盘。
- **禁止**改用 `.onChange(of: engine.drawings)` 或任何数组值比较：`DrawingObject.==` 排除 `id`。

---

## 3. 命中集合 ≡ 渲染集合（D40，实施约束）

抽一个共享纯函数（如 `visibleDrawings(engine:panel:tick:)`），**返回渲染序**：

- 渲染方（`RenderStateBuilder`）**原样消费**；
- 命中方自己 `.reversed()` 后取第一个命中（D33 最上层优先）。

同一判据、同一 `revealTick` 过滤、同一 D29 fail-safe（`upper.period == lower.period` 损坏态下退回 `panelPosition`）。**不得各写一遍**——否则在该损坏态下，点击一个面板会选中甚至删除**渲染在另一个面板上**的线。

---

## 4. 复盘门控（D34，trust-boundary）

`ChartContainerView` 的 tap 路径三模式共用。加入 hitTest 分支时**必须以 `engine.flow.mode != .review` 门控**，否则复盘会获得无层权限门控的选中能力，可改写**已归档 record 里的原训练线**。

复盘的选中 + `(layer, id)` 层权限门控留 **P5**。

---

## 5. 契约影响

- `CONTRACT_VERSION` 保持 **1.12**，`user_version` 保持 **7**，**零迁移**（依据：`DrawingObject` 不新增 / 不改任何持久化字段；选中态与 `drawingsRevision` 都是运行时状态）。
- `drawingsRevision` 是 `TrainingEngine` 的运行时计数器，**不进任何存储**（初值 0，每次装载从 0 起算——它只用于驱动 autosave 触发器，绝对值无语义）。

---

## 6. 必须存在的负向测试

**§6.3 的 0 / 0b / 0c / 1 / 1b / 1b2 / 1b3 / 1b4 / 1b5 / 1c / 2 / 3 / 4 / 5 / 5b / 6 / 7 / 8 / 9 全部原样保留**（一条不删）。以下是本 spec **追加**的：

- **N1 回显是派生的（D49）**：默认样式为 A、造一条样式为 B（逐字段不同）的线 → 选择态选中它 → 面板派生值 == B；改成 C → **那条线 == C**、`session.defaultStyle` **仍 == A（逐字段断言）**；取消选中 → 面板派生值回到 A。
- **N2 `updateDrawingStyle` 只动样式（D50）**：改样式后断言 `id` / `anchors` / `period` / `panelPosition` / `revealTick` / `locked` / `text` / `fontSize` / `textForm` / `tailAnchor` **逐字段不变**。
- **N3 `updateDrawingStyle` 对不存在 id（D50）**：返 `false`、`drawings` 逐字段不变、`drawingsRevision` **不递增**、UI 侧选中被清空且 🗑 回灰。
- **N4 `deleteDrawing(id:)` 对不存在 id（D51）**：返 `false`、同 N3 的三条断言。
- **N5 派生规则单点（D50）**：源码守卫断言 `isExtended == (lineSubType == .ray)` 与 `textColorToken = colorToken` 这两条派生表达式在 `Sources/` 中**各只出现一次**；并加一条行为测试：经 `updateDrawingStyle` 把 `lineSubType` 改成 `.ray` → 该线 `isExtended == true`；改回 `.straight` → `false`。
- **N6 盾对选择态生效（D53）**：`.rect` 内的 tap → **既不选中也不落锚**；`.pending` → 拒收一切。两种盾态 × 画线态 / 选择态共 4 组。
- **N7 选中态绝不落盘（D55）**：选中一条线 → 走完整持久化往返 → 重载后**无任何选中**，且 `DrawingObject` 逐字段与选中前一致；契约版本仍 1.12。
- **N8 面板收起不清选中（D54）**：选中一条线 → 收起面板 → 选中仍在、🗑 仍亮、可删；展开面板 → 面板派生值仍是那条线的样式。
- **N9 `drawingsRevision` 不覆盖 `reviewDrawings`（D56）**：`appendReviewDrawing` 后 `drawingsRevision` **不变**；`reviewDrawings.count` 触发器仍在（源码守卫）。
- **N10 三个"清"语义互不混用（D57）**：`setMode(.select)` / `discardPendingAnchors()` / `deactivate()` 各调一次，**逐字段差分断言** `mode` / `drawingModeActive` / `activeDrawingTool` / `pendingAnchors` / `pendingAnchorPanel` / `shield` 六项——

  | | `mode` | `drawingModeActive` | `activeDrawingTool` | pending | `shield` |
  |---|---|---|---|---|---|
  | `setMode(.select)` | → `.select` | **不变（true）** | **不变（非 nil）** | 清 | **不变** |
  | `discardPendingAnchors()` | **不变** | 不变 | **不变** | 清 | 不变 |
  | `deactivate()` | → `.draw`（复位） | → false | → nil | 清 | **清空** |

  这张表就是测试断言本身：任何一格被实现写成另一列的行为，本测试立刻红。

- **N11 切周期不得在选择态下裂脑（D57，codex R1-F1 专项回归，不可省）**：置 `mode == .select`（`drawingModeActive == true`、`activeDrawingTool` 非 nil）并选中一条线 → 调 `switchPeriodCombo` 走一次**周期真的改变**的切换 → 断言：
  1. `drawingModeActive` **仍为 true**；
  2. **两个面板都仍在 `.drawing`**（`isDrawingActive(on: .upper) && isDrawingActive(on: .lower)`）——这一条直接钉住 1a-iv 的核心不变量；
  3. `mode` **仍为 `.select`**（切周期不改变用户所处的态）；
  4. 选中被**清空**、🗑 回灰；
  5. 紧接着在选择态单击一条线 → **仍能选中**（证明 tap 仍进 `handleDrawingTap`，没有被路由去十字光标）。

  **并加一条 fail-closed 对照**：构造重新武装失败的情形 → 断言整场退出（`drawingModeActive == false`）、`mode` 复位 `.draw`、选中清空，**绝不留半武装**。

  > 这条测试存在的意义：本 finding 是 codex 挖出来的，而它**在 nil 编码下不可能被 §6.3 既有任何一条测试抓到**（那些测试都不跨"选择态 + 切周期"这个组合）。

- **N12 编辑不得造出渲染不出的线（D58，codex R2-F1 专项，不可省）**：四条，缺一即漏——
  - **a 引擎层恒开门**：对一条 `.horizontal` 线调 `updateDrawingStyle` 把 `lineSubType` 改成 `.segment` → 返 `false`、该线**逐字段不变**、`drawingsRevision` **不递增**。（判据须来自 `DrawingStyleAvailability`，另加源码守卫断言没有第二份等价判断。）
  - **b UI 层 viewport 预检**：造一条锚点**位于右缘之外**的 `.straight` 线并选中 → 改成 `.ray`（候选对象 `visibleGeometry == nil`）→ 断言：该线**仍是 `.straight`** 且逐字段不变、`drawingsRevision` **不递增**、**选中仍在**（🗑 仍亮，用户没有因此失去对它的控制）。
  - **c 反向对照（防过度 fail-closed）**：**同一条线**在锚点**位于图内**时改成 `.ray` → **成功**、`isExtended == true`、`drawingsRevision` **+1**。没有这条，实现完全可以用「一律拒绝改 `lineSubType`」骗过 b。
  - **d 归一化对称**：编辑成 `.ray` 时若原 `labelMode == .left` → 结果为 `.hidden`，与新建路径逐字一致（`(ray, .left)` 不得成为只在编辑路径上可达的组合）。**必须绕开面板、直接调 `updateDrawingStyle` 传一个未归一化的 `DrawingDefaultStyle`**（D59：写入边界自己把关，不许靠面板）——从面板走的测试证明不了这一条。

- **N13 `locked` 写入边界 fail-closed（D60，codex R3-F1 专项，不可省）**：
  - **a 改样式被拒**：造一条 `locked == true` 的线（构造 / 解码，本构建无 UI 可锁）→ 选中 → `updateDrawingStyle` → 返 `false`、该线**逐字段不变**、`drawingsRevision` **不递增**、**无任何写盘**。
  - **b 删除被拒**：同一条线 → `deleteDrawing(id:)` → 返 `false`、仍在 `drawings` 里、`drawingsRevision` 不递增。
  - **c 反向对照（防过度 fail-closed）**：同一条线 `locked == false` 时，两个 API **都成功**、`drawingsRevision` 各 +1。没有这条，实现可以用「一律拒绝」骗过 a / b。
  - **d 选中不受影响**：`locked == true` 的线**仍可被选中**（上游 spec §7.2 明载：不能选就没法解锁）——断言 hitTest 照常命中、选中态照常建立，**只是**两个写入 API 拒动它。

- **N14 高版本独立字色不得被抹（D61，codex R4-F1 专项，不可省）**：
  - **a 保留**：造 / 解码一条 `textColorToken != colorToken` 的线（模拟高版本写入）→ 选中 → **只改 `thickness`**（与颜色无关）→ 断言 `textColorToken` **逐字节不变**、`colorToken` 也不变、只有 `thickness` 变了。另测只改 `lineStyle` 一遍。
  - **b 改线色也不夺**：同一条线 → 改 `colorToken` → 断言 `colorToken` 变了、`textColorToken` **仍是原来那个独立值**（本构建无权代用户决定字色）。
  - **c 本版本线不受影响（反向对照）**：一条本构建新建的线（`textColorToken == colorToken`）→ 改 `colorToken` → 断言 `textColorToken` **跟随变化**，与 D61 之前逐字一致。
  - **d 落盘往返**：a 的线走完整持久化往返 → 重载后 `textColorToken` 仍是那个独立值（证明没有在写盘环节被抹）。

- **N15 `updateDrawingStyle` 不得有第二个调用点（D62）**：**源码守卫**断言 `Sources/` 中 `updateDrawingStyle(` 的调用点**恰好 1 处**，且访问级别**不是** `public`（`grep` 断言按 [[feedback_acceptance_grep_anchoring]] 用 `^…$` / 前缀锚，不得被注释里的同名字符串命中）。

- **N16 结构性 / 几何性不可见的差别处置（D63，codex R4-F3 专项）**：
  - **a 结构性 → 清空**：选中一条线 → 切周期使其改由另一面板显示（或不再显示）→ 选中**被清空**、🗑 灰（= D54 clause 3，与 N11 断言一致）。
  - **b 几何性 → 保留选中但 🗑 灰**：选中一条线 → 平移使其价格滑出主图纵向范围（`visibleGeometry == nil`，但仍属该面板、`revealTick` 已到）→ 断言：**选中仍在**（`selectedDrawingID` 不变）、**🗑 变灰**、**调用删除被拒**（返 `false`、`drawings` 逐字段不变、`drawingsRevision` 不递增）。
  - **c 滑回来自动恢复**：接 b，平移回去使其重新可见 → 🗑 **自动变亮**、删除可执行。这条钉住「保留选中」的价值，也防实现把 b 做成"永久禁用"。
  - **d 判据同源**：源码守卫断言 🗑 置灰判据与 D58 的 subtype 预检**复用同一个** `visibleGeometry` 求值，不得各写一份。

---

## 7. 非程序员验收清单

> ⚠️ **本清单按 `d2754df` 的真实 UI 重新推导，不是从 §6.4 抄的**。§6.4 里「长按工具图标弹面板」等条目的前提已被 1a-iii 作废（[[feedback_plan_embedded_facts_unreliable]]；1a-iv 曾因照抄母 spec 写出一条做不出来的验收项）。
>
> 前置：训练模式；点顶栏「画图」进画线模式。此时**底栏没有买卖钮**（1a-iii 起画线模式整个隐藏它们），常驻样式面板默认是**展开**的。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看底栏 | 是 **2 个键：「类型」和 🗑**（**没有** 🔒 / ↩ / ↪） | |
| 2 | 看 🗑 | 是**灰**的（还没选中任何线） | |
| 3 | 看常驻面板的水平线图标 | **亮着**（浅蓝框）= 画线态 | |
| 4 | 在主图 K 线区连点三下 | 画出**三条**线 | |
| 5 | 在**已有一条线的同一价位**再点一下 | **又叠画一条重合的线**（不是选中原来那条）——这是画线态 | |
| 6 | 点一下水平线图标（熄灭它） | 图标变暗 = 进入**选择态**，并且**一直保持暗着**（不会自己亮回来） | |
| 7 | 选择态下等几秒、或推进一根 K 线让图表刷新，再看图标 | **仍然是暗的**（选择态没被刷新冲掉） | |
| 8 | 选择态下单击主图**空白处** | **什么都不画**，🗑 保持灰 | |
| 9 | 选择态下单击一条已有的线 | 线变成**高亮色**；🗑 从灰变亮 | |
| 10 | 接第 5 条：在那两条重合线的位置单击 | 选中的是**后画的那条**（最上面那条）；先画的那条**不受影响** | |
| 11 | **选中一条与默认样式不同的线**（比如先把默认改成橙实线粗1，画一条；再改默认为蓝虚线粗3，画第二条；然后选中**第一条**） | 面板的颜色 / 线型 / 粗细控件**立刻跳成第一条线的样子**（橙 / 实线 / 1） | |
| 12 | 接上：把颜色改成绿 | **那条选中的线变绿**；线型、粗细**没被顺手改掉** | |
| 13 | 接上：点空白处取消选中，再看面板 | 面板恢复显示**默认样式**（蓝 / 虚线 / 3）；然后点亮图标画一条新线 → 新线是**蓝虚线粗3**（改选中线**没有**污染默认） | |
| 14 | 选中一条线，点 🗑 | 弹出「确定删除划线？[删除][取消]」 | |
| 15 | 点「取消」（另测：点框外关掉） | 线**还在**、仍是高亮选中态、🗑 仍亮 | |
| 16 | 再点 🗑 → 点「删除」 | 线消失，🗑 回灰 | |
| 17 | 选中一条线，然后点亮工具图标切回画线态 | **选中被取消**（线不再高亮），🗑 回灰 | |
| 18 | 选中一条 60 分的线（🗑 亮），竖滑切周期让 60 分不再显示 | 线消失，**选中自动取消**，🗑 变回灰 | |
| 18b | **接上**：切完周期后，直接再单击另一条还看得见的线 | **仍然能选中**（线高亮、🗑 变亮）——切周期没把选择态弄坏（D57 专项，codex R1 挖出的裂脑路径） | |
| 18c | 选中一条线（🗑 亮），然后**左右平移图表**，直到那条线的价位滑出可见范围（线看不见了） | 线看不见时 **🗑 变灰、点不动**（看不见的东西不许删）；但**选中没丢**——把图**平移回来**，线重新出现且**仍是高亮选中**的，🗑 **自动变亮**又能删了（D63） | |
| 19 | 选中一条线，点底栏「类型」键**收起面板** | 线**仍然是选中的**、🗑 **仍然亮**、点 🗑 仍能删；但**图标看不见了、这时切不回画线态**（要画线得再点「类型」键展开面板）——这是设计如此 | |
| 20 | 画线模式下点击**常驻面板本身**（面板盖住 K 线的那块） | **什么都不发生**：不画线、也不选中（面板挡住了） | |
| 21 | **改样式后立刻杀掉 App**（不点退出、直接从后台划掉），重开续这一局 | 改过的颜色 / 线型 / 粗细 / 标注**全部还在** | |
| 22 | 点「退出」离开画线模式，再单击一条线 | **没有任何反应**（不高亮、🗑 不出现、也不画线） | |
| 23 | 进「再次训练」画**一条线**，退出；从历史弹窗**续这一局 replay**，什么都不做（不下单、不推进、不加线、不切周期），只把那条线改成紫色，**立刻杀掉 App**，再续这一局 | 那条线是紫色的（验续局 replay 里「只改样式」也会触发存盘）<br>注：全新一局 replay 里**本来就没有任何已有线**，只能先画一条、退出、续局才改得到 | |
| 24 | 进复盘，用**浮动铅笔钮**进画线模式，单击一条训练时画的线 | **不选中**（线不高亮、什么也没发生），只会落一条新线；原训练线的颜色 / 粗细一点没变 | |
| 25 | 进复盘看画线入口和底栏 | 还是浮动铅笔钮，**没有**画线底栏、**没有** 🗑 | |

---

## 8. 已知限制（明写，非缺陷）

1. **不做选中循环**：两条几何落在同一命中容差内的线，单击**恒选中最上层**那条（D33）。想操作下层只能先删上层。完全重合时下层本就不可见；容差内但视觉可区分时，这是可接受的取舍。**P5 引入跨层选中时必须补上循环**（那时「选不中下层」会直接导致原训练线无法隐藏）。
2. **渲染不出的线同样选不中、删不掉**（D52）：`hitTest` 与渲染同源（D40），故 `visibleGeometry == nil` 的线既画不出也命不中。对**历史既有**的这类线，本期**不改善也不宣称改善**，可达性与 1a-iv 之前逐字一致。
   **但本期不得新造这类线**（D58）：编辑路径已补上与新建路径同一道 `visibleGeometry` 门（两层 fail-closed）。「历史遗留的不去动」与「新入口不许再造」是两回事，不可混为一谈。
   另注：`.ray` 的不可见是 **viewport 相关**的（锚点越过右缘），平移 / 推进 K 线后会恢复可见可删，**不是永久数据丢失**；恒不可见的只有 `.segment`，而它在面板里是灰的。
3. **面板收起期间无法切回画线态**（D54）：工具图标随面板一起隐藏。要画线需先展开面板。
4. **面板 `.pending` 瞬间少响应一次点击**（D53）：与 1a-iii 已接受的代价一致。
5. **`DrawingToolManager` 仍是死代码**（1a-iv 残留①）：本期不删、不改注释；建议独立清理 PR 处置。

---

## 9. 交接（下一切片必须接手的）

- **1b-ii（三条，缺一即卡死或回归）**：
  1. **解锁必须走独立 API**：`setDrawingLocked(id:locked:) -> Bool`，**豁免** D60 的 locked 闸（它是唯一被允许改 `locked` 的入口），同样 `drawingsRevision += 1`。**不得**试图用 `updateDrawingStyle` 解锁——`locked` 不在它管的 5 个样式字段里，且会被 D60 直接拒绝。
  2. 落地 undo / redo / 锁定时，必须把它们的引擎 API **补进 `drawingsRevision` 的「每 API 各一条回归测试」那一组**（D56）。
  3. 撤销删除必须 `insert(at:)` 还原原下标，禁 `append`（D25）。
- **P5**：复盘获得改样式能力时，必须**同期**给 `reviewDrawings` 补等价 revision 触发器（D56），并补跨层选中循环（§8 #1）。
- **P1c**：多锚工具落地时，`commitPending` 的全锚同 period 闸门（1a-iv 已建）才第一次真正可达。
