# 划线工具扩充 · P1b 设计 spec：画完线自动选中 + 改样式的两套语义

**日期**：2026-08-12

**上游 spec**（继续全部生效；本文件只在 §1 明确列出的几条上推翻 / 修订，其余一字不动）：

- 母 spec `docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（D1–D22）
- 拆分补充 spec `docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md`（D23–D48）
- 1b-i 设计 spec `docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（D49–D67）
- 1b-ii 设计 spec `docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md`（D68–D80）

**基线**：`origin/main` `20f615a`（1b-i 四片 #153/#154/#156/#159 + 1b-ii PR-1 #163 全部合入）。
分支 `feat/drawing-p1b-autoselect`，worktree `.dev/worktree/drawing-autoselect`。
基线闸门实测（本 spec 撰写时于该 worktree 实跑，非引用他处数字；命令同时打印 branch/HEAD = `feat/drawing-p1b-autoselect` / `20f615a`）：
host `swift test` = **`Test run with 1831 tests in 215 suites passed`**。

本 spec 新增决策编号从 **D81** 起（D68–D80 属 1b-ii）。

---

## 0. 范围与由来

### 0.1 用户诉求（逐字）

> 「我画完了这条线，**它就是一个选中的状态**，所以可以进行锁定操作，**包括也可以立马把它删除**。」

现状要走「点熄类型行图标 → 进选择态 → 点中那条线 → 才能锁 / 删」，三步才够得着刚画完的那条线。

配套的第二条诉求（用户 2026-08-12 亲自设计，逐字）：

> 「我在连续画线的过程中，我现在画的刚画完的这条线，我如果给它改颜色、线型什么的话，那同步也是改到**这一局的默认设置**……都是相当于**只作用于这一局**。」

### 0.2 本 spec 交付两个子项，一个 PR

| 子项 | 内容 | 生产代码估算 |
|---|---|---|
| **① 画完自动选中** | 提交成功 → 那条线立刻选中；仍留在画线态可接着画；🔒 / 🗑 / 样式面板立刻作用于它 | ~40 行 |
| **② 改样式的两套语义** | 画线态改 = 本局默认 + 顺带套到刚画那条；选择态改旧线 = 只改那一条 | ~40 行 |

合计 ~60–90 行生产代码，**一个 PR**。

### 0.3 D81　本片**不含**任何持久化改动 —— 全局默认属 §P6，用户已裁决

交接文档原本把「默认落盘持久化（settings 表五个标量 key）」列为本片的子项 ③，理由是「把 P6 的一小块提前拿出来做」。

**用户 2026-08-12 裁决推翻了这个安排**（逐字）：

> 「整个 APP 的默认的设置，就是线型、线色、线号，这些是在**小齿轮那边设置**。我们进来训练的时候，肯定是首先先用 APP 全局小齿轮那边设置的线色、线号这些来作为初始值。……我们在这个训练过程中……改这一局的默认的设置……**都是相当于只作用于这一局**。」

这与母 spec §13 逐字一致，**故 §13 不需要推翻、不需要修订**：

> §13（`2026-07-04-drawing-tools-expansion-design.md:303-310`）：「这些是**全局默认值**（持久化，`SettingsStore`/设置层）；每局训练/复盘按此**初始化**新画线的样式；用户局内再改则在该记录/复盘**局部覆盖**（**不回写全局**）。」

**结论**：本片**零持久化改动**。不新增 settings key、不改 `AppSettings` / `SettingsDAO` / `AppDBMigrations`、不改 `CONTRACT_VERSION`。
「全局默认落盘」连同齿轮「画线设置」界面整块留给 **P6**（母 spec §13），到时一并做。

**为什么不先把「读」那一半做了**：今天没有任何东西会去写那五个 key，读出来恒为出厂值 —— 那是没有真实验收场景的投机代码（CLAUDE.md §2）。P6 做界面时读写一起落地，代价更低、验收面完整。

### 0.4 本片与 P1b 六片序列、与 1b-ii PR-2（撤销）的关系

- 本片**不属于** split addendum **D23** 的六段切分，是六片序列之外、由用户新诉求驱动的追加片。
- 本片与 **1b-ii PR-2（撤销 / 前进）互不依赖，次序可换**；已定为本片先做、PR-2 后做。
- 1b-ii spec `:408`「undo『删线』（线回来）→ **不自动选中**」这一条 **继续原样成立**，见 D83 的边界条款。

### 0.5 本 spec 不做

节点圆点显示 / 拖节点 / 多锚 / 四个新工具（P1c）；局部放大镜与吸附（§9 = P4）；复盘选中与复盘专属一切（P5）；主页齿轮「画线设置」界面与全局默认持久化（§13 = P6）。

---

## 1. 既有决策的推翻与修订（**边界必须写准**）

| 决策 | 原文 | 处置 | 边界 |
|---|---|---|---|
| **D37** | 「新提交的线不自动选中」 | **推翻** | 只推翻「**用户在画线态新画、且成功落库**的线」这一种情形。D37 的**保护目的**（选中绝不指向一条陈旧的线）不但保留，而且**被强化**：本设计里选中始终跟着最新那条，且**提交被拒时清空**（D83 分支 2）。**undo 恢复回来的线不自动选中**（1b-ii `:408` 原样成立）。 |
| **D38** | 「画线态 / 选择态两态互斥，**画线态下不存在选中**」 | **推翻其中一条语义** | 只推翻「画线态下不存在选中」。D38 其余语义**全部保留**：两个态存在、切换入口是类型行工具图标 toggle、**画线态单击恒落锚不做 hitTest**、**选择态单击恒 hitTest 不落锚**、提交后不退出画线态（连续画线）。 |
| **D49** | 「选中即回显；有选中 → 面板作用于那条线；改选中线的样式**不回写默认**」 | **部分修订** | 分流判据由「有没有选中」改为「哪个态」（D86）。**「选择态下改旧线不回写默认」这一半原样保留** —— 这是 D49 的核心价值。**「面板显示的样式是每次求值现算的派生值、绝不拷成第二份 `@State`」这条纪律完全不动**（1a-iii 消灭过一次的漂移，不得重新引入）。 |
| **D54** | 清空选中的四条 clause + 「画线态选中恒为空」 | **推翻一条句子，四条 clause 全留** | 推翻的只有「画线态：选中恒为空」这一句。**clause 1（退出画线模式清空）/ clause 2（任何一次态切换清空）/ clause 3（结构性不可见清空）/ clause 4（存在性缺失清空）四条全部原样保留**。clause 2 保留是用户 2026-08-12 明确确认的（「画完线 → 点熄画线图标进选择态 → 选中不保留，从空白开始」）。 |
| **D57** | 选择态是显式 `mode`，不用 `activeDrawingTool == nil` 编码 | **不动**，且本设计**依赖**它 | D86 的全部分流判据就是 `session.mode`。没有 D57 就没有一个可靠的判据可用。 |
| **D63 / D64 / D65 / D66 / D34 / D40 / D55** | | **一字不动** | 本片不新增任何门、不放宽任何既有门。 |

---

## 2. D82　画线态的选中**只能**从「刚提交成功」这一条路产生 —— 用两个互斥入口表达，不是放宽守卫

### 2.1 今天的形状

`DrawingSession.setSelection(id:panel:)`（`Drawing/DrawingSession.swift:97-102`）：

```swift
func setSelection(id: DrawingID, panel: PanelId) {
    guard drawingModeActive, mode == .select, !id.isEmpty else { return }
    ...
}
```

`mode == .select` 这道 fail-closed 守卫让「画线态里挂着一个选中」**不可表达**（不是靠每个调用点自觉先 `setMode`）。

### 2.2 错误的改法（**明令禁止**）

把守卫放宽成 `mode == .select || mode == .draw`（或干脆删掉）。

那等于把一道**结构性**保护换成「每个调用点自己小心」：`handleDrawingTap` 的 `.select` 分支里那次 `hitTest` → `setSelection` 从此在画线态也能落地，只剩「`.draw` 分支恰好没写 hitTest」这一条**巧合**在挡着。D38 的核心语义（画线态恒不做命中判定）就没有任何机制在保证了。

### 2.3 正确的改法：两个入口，各自 fail-closed 到自己的 mode

```swift
/// 选择态命中判定专用。守卫一字不改。
func setSelection(id: DrawingID, panel: PanelId) {
    guard drawingModeActive, mode == .select, !id.isEmpty else { return }   // ← 原样
    ...
}

/// D82（本 spec）：**提交路径专用**。画线态下能产生选中的**唯一**入口。
/// 守卫与 setSelection **互斥**：那边只认 .select，这边只认 .draw。
/// 于是「画线态靠 hitTest 挂上一个选中」这条路**结构上不存在**，
/// `.draw` 分支里不需要写任何防御性代码。
func setCommittedSelection(id: DrawingID, panel: PanelId) {
    guard drawingModeActive, mode == .draw, !id.isEmpty else { return }
    ...
}
```

**两个入口的守卫互斥，并集恰好等于允许的全集。**

`!id.isEmpty` 两边都要有，理由与 1b-i PR-3 那次 whole-branch fix 逐字相同：resume 路径（`TrainingEngine.swift:178` 整体赋值）不经 `appendDrawing` 的 `!id.isEmpty` 门，磁盘上一条坏 id 的线可解码进 `drawings`；放行会让渲染 dispatch 把**所有**空 id 的线一起高亮。

**两个入口的函数体应当一致**（写 id / 写 panel / 置 `selectionGeometryVisible = true`）。实施时**不得**为了消重把两者合并成一个带 mode 参数的函数 —— 那会让「哪个 mode 允许」重新变成调用点的责任。若要消重，只允许抽一个 `private` 的赋值 helper，**两个入口各自保留自己的守卫**。

`setCommittedSelection` 与容器内其余 mutator 一样是 **`internal`，不加 `public`**（`DrawingSession.swift:21-28` 顶部大注释写明理由：mutator 一旦 public，包外就能绕过 `beginDrawingSession` / `endDrawingSessionIfActive` 这两个唯一收口点）。

### 2.4 `setCommittedSelection` 也置 `selectionGeometryVisible = true`

与 `setSelection` 同理由：能走到这一步，**同一次调用**里已经对这条线跑过 `HorizontalLineTool.visibleGeometry != nil`（D85 §5.1 第 ② 步的落库门，即今天 `ChartContainerView.swift:362` 那道门搬家后的位置）——过了那道门即证明此刻几何可见。

---

## 3. D83　提交后的选中处置：三分支，判据是**状态谓词**，不看任何返回值

### 3.1 三分支

`handleDrawingTap` 的 `.draw` 分支一旦走到「**尝试提交**」（即 `inputController.shouldCommit(...)` 返 true），就必须收敛到三选一：

| # | 情形 | 选中 |
|---|---|---|
| **1** | 这条线**因这次提交而新出现**在 `selectedPanel` 的可见集合里（判据见 §3.3） | **选中它**（`setCommittedSelection`） |
| **2** | 尝试了但被拒（全部**六**条出口见下表） | **清空选中**（`clearSelection`） |
| **3** | **没有发起提交** —— `tapToAnchor` 返 nil（点在主图外 / 映射出越界 candle），或 `shouldCommit` 为 false（多锚采集中途，P1c 才有） | **不动选中** |

**分支 3 为什么不清空**（codex spec-R2 high 连带澄清）：这两条路径**连锚都没产生**，谈不上「尝试提交」。此时选中仍指向「用户最后一次真正画出来的那条线」——与用户心智一致；清空反而会让一次误触（比如点到成交量区）夺走选中，而画线态**无法重新选中**（D38：画线态不做命中判定）。
⚠️ 这条边界与 §3.2 的结论是一套的：既然出口 c 恒不可达，就不存在「射线点右缘」这种看似分支 2、实为分支 3 的场景。

**分支 2 的六条出口必须逐条列全，并逐条标注本期可达性**（codex spec-R1 high 要求列全、spec-R2 high + medium 要求核可达性，**两轮都已对源码核实为真**）：

| 出口 | 触发 | 六步流程里死在哪一步 | **本期经真实 tap 可达？** |
|---|---|---|---|
| a | `commitPending` 返 nil —— 多锚 period 不一致 | ① | **否**：本期只有水平线，单锚落锚即提交，凑不出两个锚。**P1c 多锚工具会让它真正可达** |
| b | `commitPending` 返 nil —— `withStyle` 语义闸拒（水平线的 `.segment`） | ① | **否**：`.segment` 在面板里恒灰（`DrawingStyleAvailability.horizontalLineSubTypeEnabled` 返 false），而本片零持久化 → `session.defaultStyle` 只可能来自出厂值或面板写入，两者都产不出 `.segment` |
| c | `visibleGeometry` 预检为 nil（射线锚点越主图右缘） | ② | **否，且可证明恒不可达** —— 见下方 §3.2 的证明 |
| d | `appendDrawing` 返 false —— `isPeriodConsistent` / `isRenderableSubType` / id 空 | ⑥ | **否**：三道门分别已被 `commitPending` 的同 period 校验（`TrainingEngine.swift:1246-1249` 只比对象自身的锚与 period）、出口 b 的同一判据、`DrawingObject.init` 的 UUID 前置满足 |
| e | id 与既有线碰撞（`appendDrawing` 的 `!drawings.contains(id)` 门） | ③ 判 `wasPresent == true` → ⑥ 拒 | **否**：id 是新生成的 UUID |
| **f** | 落库**成功**，但该线**不属于本面板**（`belongsToPanel` 判 period 不匹配 / 同周期 fail-safe 下 `panelPosition` 破平局失败） | ⑥ 的合取项 ② 为 false | **否**（锚的 period 取自被点面板，`DefaultDrawingInputController.swift:33`）；但**它是合取项 ② 唯一能被单元测试构造到的档**（codex R2-medium，见 M5b） |

### 3.2 分支 2 在本期是**纵深不变量**，不是用户可见行为（codex spec-R2 high 纠正）

> **上一稿在这里错得很具体**：我写「可达性不是假想的」，举的例子是「本局默认线型改成射线 → 点主图最右缘 → 出口 c」，并据此写了一条**阻塞级真机验收 #21**。
> codex R2 指出这条路走不通，我核实**它是对的，而且结论比它说的更强 —— 出口 c 恒不可达，可证明**。

**证明**（三条源码事实，均已逐行核实）：

| # | 事实 | 出处 |
|---|---|---|
| 1 | `tapToAnchor` 要求 `mapper.viewport.mainChartFrame.contains(point)`；`CGRect.contains` 对 x 是**半开区间** ⇒ `point.x < mainChartFrame.maxX` | `DefaultDrawingInputController.swift:17` |
| 2 | `xToIndex` 是 verify-and-correct 形状，后置条件 **`indexToX(返回值) <= x`**（三个分支：`approx+1` 分支的条件就是 `indexToX(approx+1) <= x`；默认分支因第二个 `if` 未触发而有 `indexToX(approx) <= x`） | `Geometry.swift:153-163` |
| 3 | `indexToX` 与 `mainChartFrame` **同一坐标空间**：`mainChart = CGRect(x: rect.minX, …)` 且 `rect` = view.bounds ⇒ `minX == 0`；`indexToX` 亦从 0 起算 | `Geometry.swift:38` / `Geometry.swift:138-141` |

合起来：`anchorX = indexToX(candleIndex) <= point.x < mainChartFrame.maxX` ⇒ **`anchorX >= frame.maxX` 恒为假** ⇒ `.ray` 的右缘门（`HorizontalLineTool.swift:53`）对**任何由 `tapToAnchor` 产出的锚**都不触发。

⚠️ **这条证明只覆盖「提交那一刻」**。线**落库之后**随平移 / 推进 K 线变得几何不可见，是 D63 管的另一回事（选中保留、控件置灰），与本决策无关。

**因此本片的定位必须诚实**：

- 六条出口**本期经真实 tap 全部不可达** → 分支 2 是**纵深不变量**（fail-closed 后置条件），**不是**本期用户能观察到的行为。
- **不得**为它写真机验收项（上一稿的 #21 / #22 已删除）。
- 它的判据只能靠**单元级构造**来锁（§7.3），这正是 [[feedback_mutation_must_target_the_exact_predicate]] 说的：判据在被测路径上根本不求值时，正解是写成**不变量锁测试**，而不是假装它有行为覆盖。

**那为什么还要保留它**（而不是按 CLAUDE.md §2 删掉）：

1. **它让 `commitPendingAndSelect` 的后置条件是全的**——「一次提交尝试之后，要么选中的是这次新画的线，要么没有选中」。少了它，后置条件里就有一块「取决于之前是什么」的空洞，而这块空洞正是 D37 那个陷阱的形状。成本是 3 行。
2. **P1c 会让出口 a 真正可达**（多锚工具的 period 不一致取消）。届时补的是测试，不是重新设计。
3. 它是 D37 保护目的的延续：D37 防的是「用户以为选中的是刚画的 B、实际是旧的 A」。分支 2 保证的是这条不变量的**另一半**——没画出 B 时，也不会留下一个「看起来像是刚画的那条」的选中。

### 3.3 判据 = **提交前后两次状态快照**的合取，绝不读返回值

```
选中 ⟺ ① 提交前：engine.drawings 中不存在该 id
      ∧ ② 提交后：visibleDrawings(engine:panel:tick:) 含该 id
```

**为什么必须是状态谓词**（D64 的直接沿用）：`routeDrawingCommit` 今天**吞掉** `appendDrawing` 的返回值（`TrainingEngine.swift:1289-1303`，返回类型 `Void`）。要看返回值就得改它的签名，而 D64 的全部论点就是「能从状态算出来的，就不要靠返回值 / 事件传递」。

**两个合取项各自不可省，缺一即有真实的坏结果**：

| 项 | 它单独挡住的东西 | 少了它会怎样 |
|---|---|---|
| **①**（提交前不存在） | **id 碰撞** —— `appendDrawing` 的 `!drawings.contains(id)` 门（`TrainingEngine.swift:1132`）会拒收本次新线，而**那条既有的同 id 老线本来就在可见集合里** | 只判 ② 会**选中那条陈旧的老线**（用户以为选的是刚画的），🗑 一按删掉的是别的东西 —— 正是 D37 要防的陷阱原样复现 |
| **②**（提交后在可见集合里） | 周期不一致被拒、`withStyle` 返 nil、`visibleGeometry` 为 nil、`revealTick` 未到、周期归属判到了**另一个**面板（`belongsToPanel`） | 只判 ① 会在这些被拒路径上照样选中一个**根本不存在 / 不在本面板**的 id |

**② 用 membership，不用 `count == 1`**。这与 `syncSelectionByState` 已有的判据纪律逐字一致（`DrawingEditRouter.swift:157-159` 原文：「**不复用 `uniqueSelected`**：它额外要求『唯一』，而 D64 的判据里没有这一项……故直接判 **membership**」）。有了 ①，「提交后同 id 出现两条」在本路径上不可达，写成 `count == 1` 只会多一条零判别力的判据。

**必须取的是提交前的快照，不是提交后再回头判**：实施时必须在调 `routeDrawingCommit` **之前**求值 ①（存成一个局部 `Bool`），提交之后再求 ②。把 ① 挪到提交之后求值 = 恒为 false = 自动选中整体失效。

### 3.4 分支 2 的收口位置（codex spec-R1 high，**上一稿在这里是错的**）

> **来源：codex 对抗性评审 R1 唯一 high finding，已对源码逐行核实为真。**
>
> **上一稿的错**：D83 把「被拒 → 清空选中」写全了，D85 却只要求把 `ChartContainerView.swift:363` 的
> `engine.routeDrawingCommit(committed)` 换成一个只从**已提交对象**出发的路由。而出口 **a / b / c 是 `return`**，
> 在那一行**之前**就退出了 —— 于是最主要的两条被拒路径**永远不会清空选中**。
>
> **这不是理论洞**：§3.2 我自己举的可达性例子（射线锚点越右缘）走的正是出口 **c**。
> 后果就是 D37 那个陷阱原样复现：一次失败的画线之后，🔒 / 🗑 / 样式仍作用于**上一条**线。

**错误的修法（明令禁止）**：在 `ChartContainerView` 的两处 `guard … else { return }` 里各补一句
`session.clearSelection()`。那会把分支 2 的判据散进**三个**地方，其中两处在 UIKit-gated 文件里
（host 上不编译）—— 正是 D85 要消灭的东西，且「三处保持一致」没有任何机制保证。

**正确的修法**：把**整段「尝试提交」**从 `ChartContainerView` 搬进路由。分界线定在
`inputController.shouldCommit(...)` **之后** —— 它是「分支 3（还没到提交）」与「分支 1/2（已尝试提交）」
的天然分水岭，且 `shouldCommit` 需要 `tool` 与 `inputController`，留在原处最省。

搬完之后：**分支 1 与分支 2 的全部六条出口都在同一个函数体内**，一处写完，没有第二处可以写漏。
具体函数形状见 D85 §5.1。

### 3.5 边界：本决策只管「用户在画线态新画的线」

**undo / redo 恢复回来的线不适用本决策**，一律不自动选中（1b-ii spec `:408` 原样成立）。理由：那条线不是用户此刻「画」出来的，它可能落在屏幕外、可能属于另一个面板，把选中硬塞给它反而重新制造 D37 的陈旧选中。PR-2 实施时**不得**复用 `commitPendingAndSelect`。

---

## 4. D84　复盘门必须**显式**，且**只包住自动选中这一步**

### 4.1 为什么 D83 的谓词单独挡不住复盘

`RenderStateBuilder.visibleDrawings`（`Render/RenderStateBuilder.swift:84-90`）：

```swift
(engine.drawings + (engine.flow.mode == .review ? engine.reviewDrawings : [])).filter { ... }
```

复盘下它**把 `reviewDrawings` 并进来**。复盘里刚落的线**会**满足 D83 分支 1 的谓词 → 复盘将获得选中能力。

而 D34 / 1b-i §4 是 **trust boundary**：复盘的选中要带 `(层, id)` 权限门控（那是 P5）；本期若放行，复盘就能对**已归档 record 里的原训练线**做选中 → 后续 🗑 / 🔒 / 改样式。

故必须显式：`guard engine.flow.mode != .review`。

### 4.2 门的位置：**在 `commitPendingAndSelect` 内部、`routeDrawingCommit` 之后**（第 ⑤ 步）

⚠️ 这道门**只能包住「选中」那一步**。**绝不能**放到 `routeDrawingCommit` 之前、也不能提到 `ChartContainerView` 的 `.draw` 分支之外 —— 那会把**复盘的落线能力整个回归掉**（浮动铅笔钮，1a-iii 起的既有功能，D26 明写复盘继续用它）。

**位置钉死在 `DrawingEditRouter.commitPendingAndSelect` 的第 ⑤ 步**（而不是在 `ChartContainerView` 里 `if !review { ... }`）。这不只是风格问题：门放在路由里 ⇒ **「把门挪错位置」这个变异在 host `swift test` 上就能验**（M2）；放在 UIKit-gated 的 `ChartContainerView` 里就只能赌 Catalyst。

**这道门只管「授予选中」，不管「清空选中」**（D85 §5.1 约束 1）：第 ① / ② 步的 `clearSelection()` 在门**之前**、不受它管辖。清空从不授予任何能力，而一次被拒的提交在任何模式下都不该留下陈旧选中。

这与 1b-i PR-3 在 `.select` 分支里那道门的写法逐字同构（`ChartContainerView.swift:369-371` 的注释原文：「门**只包这一支**……fail-closed 的门必须限定到它真适用的那一类」），也与 1b-ii PR-1 那道 `.segment` 门误管所有工具是同一类错误。

**必须有一条测试专门钉死这个边界**：复盘下走一次提交 → `reviewDrawings.count` **递增**（落线不回归）**且** `selectedDrawingID == nil`（选中不越界）。**两个断言缺一不可** —— 只断言后者，把门错误地提到 `routeDrawingCommit` 之前也照样绿。

---

## 5. D85　提交路径收口进 `DrawingEditRouter`（无 UIKit，host 可测）

### 5.1 形状

```swift
// Drawing/DrawingEditRouter.swift
/// D83 / D84：**从 pending 锚提交一条新线，并按状态决定选中处置。**
/// 覆盖 D83 分支 1 与分支 2 的**全部六条出口**（§3.1 表）—— 这是它必须从
/// `commitPending` 开始、而不是从 `routeDrawingCommit` 开始的全部理由（§3.4）。
/// `commitPending` 与 `routeDrawingCommit` 在 `Sources/` 里的**唯一**调用点。
static func commitPendingAndSelect(panel: PanelId,
                                   mapper: CoordinateMapper,
                                   engine: TrainingEngine)
```

`ChartContainerView` 的 `.draw` 分支相应**缩短**为：

```swift
case .draw:
    let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
    guard let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper) else { return }
    session.addAnchor(anchor, panel: panel)
    guard inputController.shouldCommit(current: session.pendingAnchors, tool: tool) else { return }  // ← 分支 3 的边界
    DrawingEditRouter.commitPendingAndSelect(panel: panel, mapper: mapper, engine: engine)
    rebuildRenderState(bounds: view.bounds)      // §5.3
```

四道 guard 变一次调用：UIKit-gated 文件里的判据**净减少两条**。

**函数体的六步顺序是 load-bearing 的，一步都不许换位**：

| 步 | 做什么 | 换位 / 省略的后果 |
|---|---|---|
| **①** | `guard let committed = engine.drawingSession.commitPending(panelPosition: panel == .upper ? 0 : 1) else { clearSelection(); return }` | 省掉 `clearSelection` → 出口 a / b 留下陈旧选中（M13） |
| **②** | `guard HorizontalLineTool.visibleGeometry(for: committed, mapper: mapper) != nil else { clearSelection(); return }` | 省掉 `clearSelection` → 出口 c 留下陈旧选中（M14，= codex R1 的原始 finding） |
| **③** | `let wasPresent = engine.drawings.contains { $0.id == committed.id }` | 挪到 ④ 之后 → 恒 true → 自动选中整体失效（M5c） |
| **④** | `engine.routeDrawingCommit(committed)` —— **无条件**，复盘照常落线 | —— |
| **⑤** | `guard engine.flow.mode != .review else { return }` —— 复盘到此为止（D84） | 挪到 ④ 之前 → 复盘落线功能回归（M2） |
| **⑥** | `!wasPresent && visibleDrawings(…, panel: panel, …).contains { $0.id == committed.id }` → `setCommittedSelection`；否则 → `clearSelection`（出口 d / e） | 见 M5a / M5b / M6 |

**三条实施约束**：

1. **① / ② 的 `clearSelection` 不受 D84 复盘门管辖**（门在 ⑤，在它们之后）。这是有意的：D84 管的是复盘**不得获得**选中能力，而「清空」从不授予任何能力 —— 无论哪个模式，一次被拒的提交都不该留下陈旧选中。**不得**把 ⑤ 提前去包住 ① / ②。
2. **② 用的是调用方传进来的 `mapper`，不是 `session.viewportMapper(for: panel)`**。今天 `ChartContainerView.swift:362` 那道落库门用的就是本次 tap 现算的 mapper；换成 session 里发布的那一份会在「本面板无 candles」时变成 fail-closed —— 那是对**既有落库门**的行为改动，不属本片范围。**不得顺手"改进"**。
3. **① / ② 的判据与顺序一字不改地承接今天的 `ChartContainerView.swift:357/362`**（同一个 `commitPending`、同一个 `visibleGeometry`）。本片只是给它们各补一句 `clearSelection()` 并搬了位置，**不新增、不放宽、不重排任何落库门**。

### 5.2 为什么要挪

1. **判别力**：D83 / D84 是本片最危险的两条判据，留在 `ChartContainerView`（`#if canImport(UIKit)` 包裹，**host `swift test` 上根本不编译**）就只能赌 Catalyst 才有证据。挪进 `DrawingEditRouter`（该文件顶部注释已写明「无 UIKit ⇒ host `swift test` 就能跑」）后，两条判据连同全部变异验证都在 host 上完成。
2. **写入面收口**：`commitPending` 与 `routeDrawingCommit` 从此在 `Sources/` 里各恰好一个调用点，可上源码守卫 —— 与 `updateDrawingStyle` / `deleteDrawing(id:)` / `setDrawingLocked` 同待遇（D62 / D51 / D71 建立的模式）。
3. **分支 2 的六条出口收进同一个函数体**（§3.4）—— 这是 codex spec-R1 那条 high finding 的正面修复，也是把边界定在 `shouldCommit` 之后而不是 `routeDrawingCommit` 之前的**决定性**理由。

### 5.3 `.draw` 分支必须补一次 `rebuildRenderState`

`.select` 分支已有这一句（`ChartContainerView.swift:390`），注释里的理由逐字适用于本片：

> 选中态变了必须**立刻**重建渲染态：本函数开头的 `rebuildRenderState` 发生在选中改变**之前**，而高亮渲染读的是 `KLineRenderState.selectedDrawingID` → 不补这一次重建，本帧画出来的还是旧选中。

`.draw` 分支现在也会改选中，**同样要补**。不得改成依赖 SwiftUI observation 顺带刷新 —— Coordinator 这条直连路径不经 `updateUIView`，那样等于没有证据。

---

## 6. D86　面板的**显示 / 置灰 / 写入**三件事统一按 `mode` 分流，UI 层不得再自己判

### 6.1 三张表

| | `.draw`（画线图标亮着） | `.select`（图标熄灭） |
|---|---|---|
| **`panelStyle`**（面板显示什么） | 恒 `session.defaultStyle`（= 本局默认 = 「接下来要画的样式」） | 有选中 → 那条线的 5 个样式字段；无选中 → `session.defaultStyle` |
| **`styleControlsEnabled`**（灰不灰） | **恒 `true`** | 无选中 → `true`；有选中 → `editableIgnoringGeometry && selectionGeometryVisible`（现有五分量谓词，一字不改） |
| **写入** | `setDefaultStyle(next)`，**然后** best-effort `applyStyle(next)` | 有选中 → 只 `applyStyle(next)`；无选中 → 只 `setDefaultStyle(next)` |

**判据全部是 `session.mode`**，不再是「有没有选中」。

**这条规则能成立的自洽性来源**：画线态下点图表是落锚、**不做 hitTest**（D38 保留的语义）→ **画线态下被选中的必然是刚画的那一条**。没有 D38 这条语义，「画线态改样式连默认一起改」就会误伤用户手动挑的旧线。

### 6.2 单一入口

```swift
/// D86：常驻面板的**唯一**写入入口。取代 applyStyleMutation / applyDefaultStyleMutation。
static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                    engine: TrainingEngine)
```

- `TrainingView.swift:517-527` 那个 `if engine.drawingSession.selectedDrawingID != nil { applyStyleMutation } else { applyDefaultStyleMutation }` 分流**必须删掉**，改为无条件调 `applyPanelStyleMutation`。留着就是**第二份判据**，早晚与 `panelStyle` / `styleControlsEnabled` 漂移。
- `applyStyleMutation` / `applyDefaultStyleMutation`（`DrawingEditRouter.swift:200-214`）被 `applyPanelStyleMutation` **严格泛化**（三个分支的 base 与写入与它们逐一等价），成为本次改动制造的孤儿 → **一并删除**（CLAUDE.md §3：清理自己造成的孤儿）。`applyStyle`（真正的写入路由）**保留不动**。

### 6.3 画线态写入的三条硬约束

1. **顺序 load-bearing：先写默认，再 best-effort 改线。**
   默认是主语义、必须成功；线是附带、可能被门拒（锁定 / 滑出屏幕 / 未来数据 / 工具未实现）。反过来写会让「线改失败」在实现上很容易被顺手写成「整个操作失败」，而用户点了一下颜色却什么都没变。
2. **`applyStyle` 失败不回滚默认、不给任何反馈。** 母 spec §3 逐字：灰只降饱和、**绝不写任何解释文案**。
3. **`applyStyle` 的返回值在画线态被刻意丢弃**（`_ =`），且**不得**据它决定选中生命期 —— D64 原样成立（失败原因有五类，三类必须保留选中，一个 Bool 表达不了）。

### 6.4 「现取」纪律保持 + base 必须与显示同源

```swift
var next = panelStyle(engine: engine)   // ← 现取：动作发生这一刻的真值，不是视图渲染时的快照
mutate(&next)
```

这是 1b-i PR-4 codex 整支 R3 修过的那个**真丢数据**的回归（两个控件在 SwiftUI 重渲染之前先后触发，第二次拿旧快照把第一次 revert 掉，选中线路径还会经 `drawingsRevision` 被 autosave 持久化）。**绝不能改成接收调用方传入的快照。**

**新增的一条不变量**：base **必须与面板此刻显示的东西同源**。`panelStyle` 已按 mode 分流（画线态取默认、选择态取线），`applyPanelStyleMutation` 直接复用它 → 这条一致性由**共用同一个函数**保证，不是靠两处各写一遍。

### 6.5 副作用与已接受残留

1. **画线态下 🔒 / 🗑 会亮** —— 这正是需求 ①。`lockButtonEnabled` / `deleteButtonEnabled` / `canToggleLock` / `canDelete` **不含 mode 分量，全部不改**。
   ⚠️ **「会亮」不等于「无条件亮」**（codex spec-R3 high）：`deletableIgnoringGeometry` 末行是 `return !d.locked`（`DrawingEditRouter.swift:93`）——**锁定的线在画线态同样删不掉，🗑 照样灰**。自动选中**不得**成为放宽这道门的理由：那是一条不可逆销毁的信任边界。`lockableIgnoringGeometry` 刻意**没有** `!d.locked` 分量（锁定线必须仍能被解锁），这个不对称是 D71 的原样保留，本片不碰。
2. **「无选中」在画线态变得难以达到**。交接文档原本把它列为需要替代入口的副作用（「熄灭画线图标 → 改默认 → 再点亮」）。D86 把画线态的面板改成**恒显示默认、恒可用、恒写默认**之后，**这个副作用不再有代价**，那条替代入口不再需要。
3. **画线态下 `panelStyle` 不回显选中线**。提交那一刻两者相等（`commitPending` 就是用 `defaultStyle` 造的线），只在「那条线改不动、默认继续改」之后才分叉 —— 而画线态的语义本来就是「我下一笔要画成什么样」，分叉后显示默认是正确的。这是对 D49 的**有意修订**，不是回归。
4. `applyStyle` 的 `defer { syncSelectionByState(engine:) }` 在画线态照跑，语义正确（只在线不在可见集合时清空，与 mode 无关）。
5. **复盘不受 D86 影响**：常驻样式面板在复盘根本不出现（`TrainingView.swift:116` `stylePanelWillBeVisible = showsTradeButtons && …`，而 `showsTradeButtons = engine.flow.canBuySell()` 在复盘为 false）。

### 6.6 D87　「本局默认」的生命期 = **引擎实例**，明确**不跨 resume**（已接受残留）

> **来源：codex spec-R4 唯一 high finding。事实成立、归因有一半不成立，逐条核实如下。**

**成立的部分（本 spec 的真缺口）**：本片把「本局默认」提升成了一等用户语义（子项 ②），却**从头到尾没有定义它的生命期**。§0.3 那句「零持久化改动」读起来像「持久化不在本片范围内」，而不是「这个东西是**有意瞬态**的、用户会观察到什么后果」。**必须补上定义。**

**不成立的部分（归因）**：codex 写「本片**制造**了 session-local default style state」。**核实为否**——

| 核查项 | 实测 |
|---|---|
| `defaultStyle` 在持久化模块 `KlineTrainerPersistence/` 的出现次数 | **0**（今天就不持久化） |
| 引擎对会话生命期的既有陈述 | `TrainingEngine.swift:54` 逐字：「会话是**局内瞬态**，不持久化；每局 `TrainingEngine.make` 新建」 |
| **`setDefaultStyle` 的写入频率是否被本片改变** | **否**。main 上画线态**恒无选中**（D54 原文），故 `TrainingView` 的 `if selectedDrawingID != nil` 分流在画线态**恒走 else 支**＝`applyDefaultStyleMutation`＝`setDefaultStyle`。本片改的是「同时也套到刚画那条线」，**没有新增任何一次 `setDefaultStyle` 调用** |

**结论：这是 main 上的既有行为，本片既不引入也不加重。** 但既然本片给它起了名字，就必须把它写清楚。

**D87 决策**：

- 「本局默认」的生命期 **= `TrainingEngine` 实例的生命期**。退出训练回主页再续训、或 App 被杀后续训 → **新引擎、新 `DrawingSession`** → 本局默认**回落到出厂值**（P6 之后回落到全局默认）。
- **本片不修**。修它意味着把 `DrawingDefaultStyle` 塞进 pending / replay / review 三条存档的契约、加向后兼容解码、再为「只改了默认没改线」这种不 bump `drawingsRevision` 的变更单独设计 autosave 触发 —— 那是一整块持久化契约改动，远超本片 60–90 行的边界，且与 P6 高度重叠（P6 引入全局默认落盘之后，resume 会从全局默认种下，真正丢的只剩「本局覆盖量」这一个 delta）。
- **必须有一条真机验收把它记录成既定行为**（验收 #23），否则将来有人碰到会当成回归去查。

**顺带纠正 codex 的一条子论断**：它提到「选中线被锁定导致 `applyStyle` 被拒时可能不触发 autosave」。这是**正确行为不是缺陷**——那种情形下 `drawings` 根本没有变化，没有任何东西需要存盘；autosave 由 `drawingsRevision` 驱动本就只覆盖 `drawings`（D56 原样成立）。

---

---

## 7. 测试与判别力

> 纪律来源：[[feedback_mutation_must_target_the_exact_predicate]] / [[feedback_all_reject_suite_masks_always_throwing_guard]] / [[feedback_plan_code_blocks_cause_vacuous_tests]]。
> 每条判据必须能回答「**红的是哪一条**」，而不是「有测试变红」。

### 7.1 必配的**正向档**（防「全是拒了的套件掩盖恒抛守卫」）

本片新增判据全是「拒了」形状（复盘拒、态不对拒、提交被拒清空）。若只有拒绝档，一个恒不选中的实现（或恒抛的守卫）会让整套看起来在工作。**故每一族必须配一条健康输入被放行的正向档，且断言取到的是哪一个值**：

| 正向档 | 断言 |
|---|---|
| **P1** 训练态 + 画线态 + 健康锚点 → 提交 | `selectedDrawingID == committed.id`（**断言等于新那条的 id**，不是「非 nil」）、`selectedPanel == 落锚的那个面板`、`drawings.count` 递增 1 |
| **P2** 连画两条 | 选中**转移**到第二条（`== id2` 且 `!= id1`），`drawings.count == 2` |
| **P3** 画线态 + 有选中 + 改样式 | 那条线的该字段变了 **且** `session.defaultStyle` 的该字段也变了（**逐字段断言**） |
| **P4** 选择态 + 选中旧线 + 改样式 | 那条线变了 **且** `session.defaultStyle` **逐字段未变**（D49 保留的那一半，判别力就在这条） |
| **P5** 画线态 + 无选中（刚进会话还没画） + 改样式 | `session.defaultStyle` 变了、`drawings` 全部未变 |
| **P6** 画线态 + 自动选中的线**已锁定**（codex spec-R3 high 要求的回归档） | `deleteButtonEnabled == false` **且** `canDelete == false`（自动选中**不得**让锁定线变得可删）；同时 `lockButtonEnabled == true`（🔒 仍可用于解锁，否则永远解不开）。**两个断言缺一不可**——只断言前者，一个「锁定线连 🔒 也灰掉」的实现照样绿 |

### 7.2 变异清单（每条注明**只有它够得到**的档）

| # | 变异 | 必须且只应变红 |
|---|---|---|
| M1 | 删掉 D84 的 `flow.mode != .review` 门 | 复盘档（选中越界）红；训练档 P1/P2 **不得**红 |
| M2 | 把 D84 的门（第 ⑤ 步）挪到第 ④ 步 `routeDrawingCommit` **之前** | 复盘**落线**档红（`reviewDrawings.count` 不再递增）；这一条证明 §4.2 的双断言不是空转 |
| M3 | 把 `setCommittedSelection` 的守卫改成 `mode == .select` | P1 红（自动选中整体失效） |
| M4 | 把 `setSelection` 的守卫放宽成 `mode != nil` / 删掉 | 「画线态调 `setSelection` 必须被拒」的不变量锁测试红 |
| M5a | 删掉 D83 谓词的合取项 **①**（提交前不存在该 id） | **只有** id 碰撞档红（预置一条与 committed 同 id 的既有线 → 断言选中**保持为 nil**，不得变成那条老线） |
| M5b | 把 D83 谓词的合取项 **②** 改成恒 true | **只有出口 f 档**红（codex spec-R2 medium 重定向）。⚠️ **原先举的两个例子（周期不一致 / 射线越右缘）对 ② 零判别力** —— 六步流程下它们分别死在第 ① / ② 步，**根本到不了第 ⑥ 步**。正确造法：单元级构造一个「锚的 period ≠ 被点面板当前 period」的 pending 锚（`addAnchor` 不校验二者一致），使 ①②③④ 全过、`appendDrawing` 也成功（`isPeriodConsistent` 只比对象自身的锚与 period，`TrainingEngine.swift:1246-1249`），但 `belongsToPanel` 判它不属于本面板 → 合取项 ② 为 false → 断言**不授予选中** |
| M5c | 把合取项 ① 的求值挪到 `routeDrawingCommit` **之后** | P1 红（自动选中整体失效）—— 这条证明「快照顺序」不是纸面约定 |
| M6 | 删掉 D83 分支 2 的 `clearSelection()` | **只有**「先选中一条、再让下一次提交被拒」的档红 |
| M7 | 把 `panelStyle` 的 `.draw` 分支改回「有选中取那条线」 | 「画线态 + 选中线已锁定 + 改样式 → 面板显示新默认」的档红 |
| M8 | 把 `styleControlsEnabled` 的 `.draw` 分支改回现有谓词 | **只有**「画线态 + 选中线已锁定 → 控件仍可用」的档红（= 用户 Q2 选择的判别力所在） |
| M9 | 把 D86 画线态的 `setDefaultStyle` 删掉（只改线） | P3 的 `defaultStyle` 断言红、线的断言不红 |
| M10 | 把 D86 选择态改成也写 `setDefaultStyle` | **只有** P4 红 |
| M11 | 把 `applyPanelStyleMutation` 的 base 改成调用方传入的快照 | 「两次连续改动不互相 revert」的档红（PR-4 R3 那条回归的守门测试） |
| M12 | 删掉 `.draw` 分支新增的 `rebuildRenderState` | 渲染态档红（`KLineRenderState.selectedDrawingID` 本帧仍是旧值） |
| **M13** | 删掉第 **①** 步（`commitPending` 返 nil）的 `clearSelection()` | **只有**「已有选中 → 下一次提交因 `commitPending` 返 nil 被拒」的档红（出口 a / b） |
| **M14** | 删掉第 **②** 步（几何预检失败）的 `clearSelection()` | **只有**「已有选中 → 下一次提交因射线越右缘被拒」的档红（出口 c，= **codex spec-R1 那条 high finding 的守门测试**） |

**M5b / M13 / M14 三条都是「不变量锁」级**（§3.2：对应出口本期经真实 tap 不可达）——档只能**单元级构造**：直接给 `DrawingSession` 塞 pending 锚、直接构造让判据成立的 `mapper`，不经 `handleDrawingTap`。这不是降低标准，而是 [[feedback_mutation_must_target_the_exact_predicate]] 明写的正解：判据在生产路径上不求值时，写成不变量锁测试，**而不是假装它有行为覆盖**。

**M13 / M14 的档必须造成「先有一个选中，再让下一次提交被拒」**——只造「无选中时提交被拒」是零判别力的（那种档在删掉 `clearSelection` 后照样绿）。

**实施要求**：M1–M14（含 M5a/b/c）**逐条关门看红**，并在 PR 描述里逐条记录「红的是**哪个测试名**」。实施者自报「验过了」不算数（[[feedback_mutation_testing_beats_reading]]）。
变异复原一律 `cp` 到 /tmp 再 `cp` 回，**禁止 `git checkout <file>`**（会静默抹掉未提交改动，[[feedback_git_checkout_destroys_uncommitted_work]]）。

### 7.3 不变量锁测试（对「不可达」的正确写法）

M4 对应的那条判据在生产路径上**根本不会被求值**（`.draw` 分支不调 hitTest、不调 `setSelection`）。按 [[feedback_mutation_must_target_the_exact_predicate]]，正解是把「不可达」写成**不变量锁测试**而不是假装它有行为覆盖：

- **N-lock-1**：`mode == .draw` 时直接调 `setSelection(id:panel:)` → 选中**保持为 nil**。
- **N-lock-2**：`mode == .select` 时直接调 `setCommittedSelection(id:panel:)` → 选中**保持为 nil**。

两条一起钉死「两个入口互斥」这个 D82 的全部价值。

**分支 2 的三条同样是不变量锁**（§3.2：六条出口本期经真实 tap 全部不可达）——直接调 `commitPendingAndSelect`、单元级构造入参，不经 `handleDrawingTap`：

- **N-lock-3**（出口 a/b，对应 M13）：先建立一个选中 → 塞一组 period 互不相同的 pending 锚（或让 `withStyle` 返 nil）→ 调用 → 断言 `selectedDrawingID == nil` 且 `drawings.count` 未变。
- **N-lock-4**（出口 c，对应 M14）：先建立一个选中 → 构造一个使 `indexToX(anchor) >= mainChartFrame.maxX` 的 `mapper`（**单元级直接造 viewport，不要试图从 tap 造 —— §3.2 已证明造不出来**）→ 断言 `selectedDrawingID == nil` 且未落库。
- **N-lock-5**（出口 f，对应 M5b）：塞一个「period ≠ 被点面板当前 period」的 pending 锚 → 调用 → 断言**落库成功**（`drawings.count` +1）**但不授予选中**（`selectedDrawingID == nil`）。这条是合取项 ② 唯一的判别力来源。

⚠️ 三条都必须**先建立一个选中**再触发（M13/M14）或**断言落库确实发生**（N-lock-5）——少了前置状态，删掉被测那一句照样绿。

### 7.4 平台覆盖

| 判据 | 跑在哪 | 变异 |
|---|---|---|
| D82（两入口互斥）、D83（六步顺序 + 六条出口 + 两个合取项）、D84（复盘门位置）、D86（三张表 + 写入顺序 + 现取） | **host `swift test`**（`DrawingSession` / `DrawingEditRouter` / `RenderStateBuilder` / `HorizontalLineTool` / `CoordinateMapper` 均无 UIKit） | M1 / M2 / M3 / M4 / M5a / M5b / M5c / M6 / M7 / M8 / M9 / M10 / M11 / **M13 / M14** |
| `ChartContainerView.draw` 分支换调用 + 补 `rebuildRenderState`；`TrainingView` 删 if 分流 | 源码守卫（host）+ **Catalyst 编译与测试门** | **M12（只有它必须上 Catalyst）** |

**D85 把「尝试提交」整段挪进 `DrawingEditRouter` 的直接收益就在这张表**：15 条变异里 14 条落在 host。
若按上一稿只挪 `routeDrawingCommit` 一句，M13 / M14 这两条（= codex R1 那条 high finding 的守门测试）就只能上 Catalyst。

⚠️ **UIKit-gated 文件在 host 上根本不编译** → M12（唯一一条）必须上 Catalyst 跑（[[feedback_uikit_gated_evidence_traps]]），且 Catalyst 必须用 `-scheme KlineTrainerContracts-Package` + `set -o pipefail`（[[feedback_catalyst_scheme_and_pipefail_double_trap]]）。判绿读**执行量**，不读 `TEST SUCCEEDED` 字样。

---

## 8. 源码守卫

| # | 守卫 | 形状 |
|---|---|---|
| **G1** | `routeDrawingCommit` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内 | 结构计数 |
| **G1b** | `commitPending` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内（D85 §5.1 第 ① 步）—— 防实施者「只搬一半」，把 `commitPending` 留在 `ChartContainerView` 里 | 结构计数 |
| **G2** | `setCommittedSelection` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内 | 结构计数 |
| **G3** | `applyStyleMutation` / `applyDefaultStyleMutation` 两个标识符在 `Sources/` 的**代码文本**里**恰好 0 次**出现（已删除） | 结构计数。⚠️ **必须剥注释后再数** —— D86 §6.2 要求给 `applyPanelStyleMutation` 写一句「取代 applyStyleMutation / applyDefaultStyleMutation」的承重注释，不剥注释 G3 会被这句注释自己打红，而「删掉那句注释」就成了合法绕过路径 |
| **G4** | `applyPanelStyleMutation` 在 `Sources/` 里**恰好 1 个**调用点，且在 `UI/TrainingView.swift` 内 | 结构计数 |
| **G4b** | `clearSelection` 在 `Drawing/DrawingEditRouter.swift` 里**至少 4 个**调用点（第 ① / ② / ⑥ 步 + 既有 `syncSelectionByState`）—— 少于 4 说明分支 2 的某条出口没接上 | 结构计数（**下界**，不是精确值：`applyStyle` / `deleteSelected` 等既有路径也可能增加，故用 ≥ 不用 ==） |
| **G5** | `setSelection`（不含 `setCommittedSelection`）在 `Sources/` 里**恰好 1 个**调用点，且在 `Render/ChartContainerView.swift` 内 | 结构计数（**匹配必须用完整调用语法锚**，`setSelection(` 会被 `setCommittedSelection(` 的子串误命中 → 需要边界锚） |

**纪律（缺一即失效）**：

- **不得写成「禁词黑名单」**，一律用结构计数（[[feedback_source_guard_text_source_discipline]]）。
- 否定 / 结构断言必须**剥注释、剥字符串字面量**再匹配 —— 否则本 spec 引用的那些承重注释会把守卫自己打红，且「删注释」会变成合法绕过路径。
- **每个守卫必须配双向自检**：喂一段「本该命中」的样本必须命中、喂一段「本该不命中」的样本必须不命中。锚点失效必须**报错**，不得静默返回 0（[[feedback_mechanical_checker_parser_disabled]]）。
- ⚠️ **G1 / G1b / G2 / G3 / G4 / G4b 描述的是改动之后的状态，在当前树上是红的**（G1 与 G1b 今天的唯一调用点都在 `ChartContainerView`、不在 `DrawingEditRouter`；G2/G4 的符号今天还不存在；G3 今天恰好相反、两个标识符都还在；G4b 今天只有 1 个）。故它们**必须与对应的生产改动写在同一个 task 里**，不得作为「前置守卫」先行落库 —— 一条开局就红的守卫等于给实施者发放宽许可证（[[feedback_source_guard_must_be_green_on_current_tree]]）。每个 task 结束时它自己那几条守卫必须是绿的。
- **G5 今天已经是绿的**（`setSelection` 的唯一调用点已在 `ChartContainerView.swift:378`），它是**回归守卫**，可以先落库。

---

## 9. 验收清单（真机，非 coder 可执行）

前置：Debug 构建 + `KLINE_SEED_FIXTURE=1` 装机（[[project_device_testing_requires_seed_fixture]]；NAS 后端未部署，不带 seed 必报「训练组文件不存在」，那是环境缺口不是回归）。

| # | 动作 | 预期 | 通过/失败 |
|---|---|---|---|
| 1 | 进训练 → 点底栏「画图」进画线模式 → 点亮水平线图标 → 在下图点一下 | 画出一条水平线，**这条线立刻变蓝（选中）** | |
| 2 | 接着不做任何别的操作，在下图另一个价位再点一下 | 画出第二条线，**第二条变蓝、第一条恢复原色** | |
| 3 | 承接 #2，看底栏 | **🔒 和 🗑 都是亮的**（不是灰的） | |
| 4 | 承接 #3，点 🔒 | 第二条线变成锁定态（🔒 图标变闭锁），线仍选中；**同时 🗑 变灰**（锁定保护，D60/D71 原样生效） | |
| 5 | 承接 #4，点一下那个变灰的 🗑 | **没有任何反应，不弹确认框、线不消失**。⚠️ 若这一步弹出了确认框或删掉了线，说明锁定保护被削弱了，**立即停止验收并报回** | |
| 6 | 承接 #5，点 🔒 解锁（🗑 恢复变亮）→ 点 🗑 → 弹确认框 → 点「取消」→ 再点 🗑 →「删除」 | 解锁后 🗑 才可用；确认框先出现；取消后线还在；确认后线被删掉，蓝色高亮消失，🗑 回灰 | |
| 7 | 承接 #6（现在只剩第一条线，无选中），在下图再画一条 | 新线立刻变蓝选中 | |
| 8 | 承接 #7（画线态、新线选中），在样式面板点一个**新颜色** | **刚画那条线变新颜色**，面板色块跟着高亮到新颜色 | |
| 9 | 承接 #8，再在下图画一条新线 | 新画的这条**就是刚选的新颜色**（默认跟着改了） | |
| 10 | 承接 #9，看 **#1 画的那条**（屏幕上最早那条） | 它**颜色没变**、仍是出厂橙（改样式没有波及旧线） | |
| 11 | 承接 #10，点 🔒 锁定当前选中的线，然后再在样式面板点**另一个颜色** | **面板色块高亮到新颜色**（面板没有变灰、仍可点）；**被锁定的那条线颜色不变** | |
| 12 | 承接 #11，再画一条新线 | 新线是 #11 选的那个颜色 | |
| 13 | 点熄水平线图标（进选择态） | 蓝色高亮**消失**（选中被清空），🔒 🗑 回灰 | |
| 14 | 承接 #13，在选择态点中 **#1 画的那条**（出厂橙那条） | 它变蓝选中，**样式面板的颜色高亮跳回橙色**（= 显示那条线自己的样式，不是 #11 设的默认色） | |
| 15 | 承接 #14，给这条旧线改一个颜色 | **只有这条旧线变色** | |
| 16 | 承接 #15，点亮水平线图标回画线态，再画一条新线 | 新线用的是 **#11 那个默认颜色**，**不是** #15 给旧线设的颜色（选择态改旧线不回写默认） | |
| 17 | 退出画线模式，再重新进画线模式，画一条线 | 线还是 #11 那个默认颜色（本局默认在会话内保持） | |
| 18 | 返回主页，重新开一局新训练，进画线模式画一条线 | 线是**出厂默认色（橙）**，不是上一局改的颜色（本局默认**不跨局**、不写全局） | |
| 19 | 从主页进**复盘**（历史记录 → 复盘），用浮动铅笔钮画一条线 | 线**能画出来**（落线功能没坏）；线**不变蓝**、底栏无选中相关变化（复盘不获得选中能力） | |
| 20 | 重新进画线模式画一条线（它变蓝），然后**在图上竖滑切周期** | 蓝色高亮**消失**（选中被清空），🔒 🗑 回灰；画线模式**仍然开着**（可以接着画） | |

| 21 | 画一条线（它变蓝选中）→ 在样式面板把**线型**改成「**射线**」→ 再在图上点一下画一条新射线 | 画出一条射线并**变蓝选中**（射线与直线走同一条自动选中路径，没有被几何门误拒） | |

| 23 | 在画线态把颜色改成一个好认的色（比如紫）→ 点「返回」退出训练回主页 → 点「继续训练」续上同一局 → 进画线模式画一条线 | 新线是**出厂橙**，**不是**紫色。⚠️ 这是 **main 上就有的既定行为**（本局默认不跨 resume，D87），**不是本片引入的回归** —— 记录在此防将来误查 | |

**#18 / #19 是本片的两条硬边界**（不跨局 / 复盘不越界），任何一条不过都是阻塞级。
**#23 是「记录既有行为」项，不是阻塞项**——它的作用是让将来遇到这个现象的人一眼知道这是已知设计（D87），不必去查回归。

⚠️ **分支 2（提交被拒 → 清空选中）没有真机验收项，这是刻意的**：§3.2 已证明它的六条出口在本期经真实 tap **全部不可达**（出口 c 更是可证明恒不可达）。
上一稿曾为它写过一条阻塞级真机项（射线点最右缘），**codex spec-R2 high 指出那条路走不通、我核实属实并已删除** —— 一条用户根本走不到的验收步骤，只会让人在真机上反复试、试不出来，然后要么误判为回归、要么随手打勾。
它的判据改由 §7.3 的**不变量锁测试**（单元级构造）覆盖。

---

## 10. 交接与残留

### 10.1 交给 1b-ii PR-2（撤销 / 前进）

- **undo / redo 恢复回来的线不自动选中**（1b-ii `:408` 原样成立）。**不得复用 `commitPendingAndSelect`**（D83 §3.5）。
- undo 把一条线删掉时，若它正被选中 → 由 D54 clause 4（存在性谓词）自动清空，PR-2 **不需要**为此新增判据。
- PR-2 的入栈动作里包含「改样式」。D86 让**画线态**的一次改样式同时改了「线」和「本局默认」——**PR-2 必须决定 undo 是否一并回滚默认**，这是 PR-2 的 spec 范围，本片不预判。

### 10.2 交给 P6（母 spec §13）

齿轮「画线设置」界面 + 全局默认持久化（含 settings 表的 key 设计）整块留给 P6。届时：

- `DrawingSession.defaultStyle` 的**初始值**改为从全局默认种下（今天是 `DrawingDefaultStyle()` 出厂值）；
- 本片建立的「局内改只作用于本局」语义**不需要改动**（母 spec §13 逐字就是这个）。
- **D87 的残留一并在 P6 收敛**：全局默认落盘之后，resume 会从全局默认种下，真正会丢的只剩「本局覆盖量」这一个 delta。届时再决定要不要把 `DrawingDefaultStyle` 写进 pending / replay / review 三条存档的契约（需要向后兼容解码 + 为「只改默认不改线」这类不 bump `drawingsRevision` 的变更单独设计 autosave 触发）。

### 10.3 已接受残留

- **画线态下 `panelStyle` 不回显选中线**（§6.5 #3）。这是有意修订，验收 #11 是它的正面证据。
- **画线态下 `applyStyle` 失败无任何反馈**（§6.3 #2）。母 spec §3 逐字要求「绝不写解释文案」，用户看到的现象是「线没变、但下一笔会变」。
- **本局默认不跨 resume**（D87 §6.6）。**main 上的既有行为，本片不引入不加重**（`setDefaultStyle` 写入频率未变）；验收 #23 把它记录成既定行为，交 P6 收敛。
- **验收 #3（🔒/🗑 变亮）只有真机目视证据**，与 1b-i PR-4 的「🗑 置灰只有源码守卫无运行时证据」同类。属体验问题，非数据安全。

---

## 11. 契约影响

**零**。不新增 / 不修改任何持久化字段、不改 `CONTRACT_VERSION`、不加迁移、不改 settings 表。
`DrawingSession` 的选中态是**瞬时 UI 状态，绝不落盘**（D55 原样成立）。

---

## 12. codex 对抗性评审逐轮

| 轮 | 评审对象 | verdict | finding | 处置 |
|---|---|---|---|---|
| **R1** | `feat/drawing-p1b-autoselect` @ `725534a`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：D83 要求「提交被拒 → 清空选中」，但 D85 只让实施者替换 `routeDrawingCommit` 那一句；而 `commitPending` 返 nil 与几何预检失败这两条出口在今天的代码里是 `return`，**根本到不了那一句** → 分支 2 对最主要的两条被拒路径永不执行，D37 的陷阱原样复现 | **全采纳**。已对源码逐行核实为真，且**是本 spec 自身的矛盾**：§3.2 我自己举的可达性例子（射线越右缘）走的正是那条 `return`。修法**不是**在 `ChartContainerView` 补两句 `clearSelection`（会把判据散进三处、其中两处 host 测不到），而是把**整段「尝试提交」**搬进路由（D85 §5.1 六步），使分支 2 的各条出口收进同一个函数体（当时列了五条，R2 又补出出口 f）。连带产出：出口清单表（§3.1）、M13 / M14 两条守门变异、真机验收 #21（**该验收项已被 R2 推翻删除**） |

| **R2** | 同分支 @ `6967fa5`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：验收 #21（射线点最右缘 → 清空选中）走不通 —— `tapToAnchor` 有一道**更严**的门（`mainChartFrame.contains` + `candleIndex ∈ [startIndex, startIndex+visibleCount)`）会先拒，实际走分支 3（不动选中），与 #21 自己声明的预期相反，而我把它标成了阻塞级<br>**1 medium**：M5b 举的两个例子在六步流程下分别死在第 ① / ② 步，**到不了第 ⑥ 步**，对合取项 ② 零判别力 | **全采纳**。核实后结论比 codex 更强：**出口 c 可证明恒不可达**（`xToIndex` 的 round-trip 后置条件 + `CGRect.contains` 的半开区间 + `mainChartFrame.minX == 0`，三条源码事实见 §3.2）。顺着逐条算完六条出口 → **本期全部不可达** → 分支 2 重新定位为**纵深不变量**：删掉真机 #21/#22、改由 §7.3 的不变量锁测试覆盖；新增出口 **f** 并把 M5b 重定向到它；M5b/M13/M14 统一标为不变量锁级 |

| **R3** | 同分支 @ `f916ae4`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：验收 #4 先锁定选中线、#5 却要求点 🗑 弹确认框。而 `deletableIgnoringGeometry` 末行就是 `return !d.locked`（`DrawingEditRouter.swift:93`）→ 锁定线的 🗑 恒灰。这条清单**要么过不了，要么实施者为了让它过而拆掉锁定保护**（不可逆删除的信任边界） | **全采纳**。核实属实。#4 改为「🗑 同时变灰」、#5 改为「点灰 🗑 无任何反应，若弹框立即停止验收并报回」、#6 改为「先解锁再删」；§7.1 新增回归档 **P6**（画线态 + 锁定线 → `deleteButtonEnabled == false` **且** `lockButtonEnabled == true`，两个断言缺一不可）；§6.5 #1 补写「会亮 ≠ 无条件亮」的边界，明令自动选中不得成为放宽删除门的理由 |

| **R4** | 同分支 @ `4571adf`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：本片把「本局默认」立成一等语义，却没定义它的生命期；`DrawingSession.defaultStyle` 不在任何存档里 → 退出续训后回落出厂值，属用户可见的状态丢失 | **部分采纳（事实收、归因驳）**。**事实成立**：`defaultStyle` 在 `KlineTrainerPersistence/` 出现 **0 次**，退出训练再续训确实回落出厂值；而我的 spec 从头到尾**没定义过这个生命期**——真缺口，已补 **D87**（§6.6）。**归因不成立**：codex 称「本片**制造**了这个状态」，实测为否——`TrainingEngine.swift:54` 逐字写着「会话是局内瞬态，不持久化」，且 main 上画线态**恒无选中**（D54）→ 画线态改样式本来就走 `applyDefaultStyleMutation`，**本片没有新增任何一次 `setDefaultStyle` 调用**，写入频率完全未变。故定位为「既有行为 + 已接受残留 + 交 P6」，本片不修（修它 = 三条存档契约 + 向后兼容解码 + 为不 bump revision 的变更另设 autosave 触发，远超 60–90 行边界）。连带纠正其子论断：锁定线致 `applyStyle` 被拒时不触发 autosave 是**正确行为**（`drawings` 没变，没东西要存）。产出：D87 + 验收 #23（记录既定行为、非阻塞项）+ 残留与 P6 交接各一条 |

**R1 的形状**：我把「要做什么」写全了，却把「在哪做」写在了一个**那些路径到不了**的位置。
这与 [[feedback_internal_review_misses_bad_data]] 记录的形状一致 —— 判据本身没错，错在**没有对着真实控制流核一遍每条出口是否真的流经收口点**。
纪律沉淀：**凡是写「所有 X 都要走 Y」的 spec，必须先把 X 的出口逐条列出来，再逐条核它是否真的到得了 Y**（§3.1 那张出口表就是这条纪律的产物）。

**R2 的形状**：R1 让我把出口列全了，但我只核了「出口 → 收口点」这一段，**没核「用户 → 出口」那一段**。
于是六条出口本期一条都走不到，我却给其中一条写了阻塞级真机验收，还拿它当 §3.2 的可达性论据。
纪律沉淀（补齐 R1 那条的另一半）：**出口表必须带「本期可达性」一列，且逐条给出可达 / 不可达的源码依据**；**不可达的出口不得写成真机验收项**，只能写成不变量锁测试（[[feedback_mutation_must_target_the_exact_predicate]]）。
**R3 的形状**：验收清单里的每一步我都**没有对着既有的门逐步模拟一遍**——#4 锁定之后，下一步的 🗑 早已被 `!d.locked` 关掉了，而我照着「先锁再删」的直觉写了下去。

⚠️ **三轮的共同根因是同一个：我论证「这条路存在 / 这一步做得到」时，只看了路的一半。**
R1 = 只核了出口到收口点、没核收口点位置；R2 = 只核了出口到收口点、没核用户到出口；R3 = 只核了动作、没核动作此刻是否被门允许。
纪律沉淀（第三条）：**验收清单每一步都必须对着当前树上的可用性谓词逐步模拟**——上一步改变了什么状态、这一步的按钮此刻是亮是灰。凡是「先设一个保护、再执行被该保护禁止的动作」的相邻两步，一律是错的。
⚠️ 更要命的是这类错误的**方向**：它不是让验收失败，而是**诱导实施者去削弱一道安全门来让清单通过**。

**R4 的形状**（与 R1–R3 不同族）：不是「路只看了一半」，而是**给一个概念起了名字却没定义它的生命期**。「本局默认」在本片之前只是 `session.defaultStyle` 一个实现细节，本片把它写成用户语义（子项 ②）之后，「它活多久」就成了必须回答的问题，而我一个字没写。
纪律沉淀（第四条）：**spec 每引入或提升一个有状态的概念，必须同时写死它的三件事——谁能写、活多久、什么时候没**。
⚠️ 同时这一轮也提醒：**评审给的归因要单独核**（[[feedback_mutation_must_target_the_exact_predicate]]）。本轮 finding 的事实对、归因错（说本片制造了它），若不核就照单全收，会把一块 main 上的既有残留误算进本片的账、并可能因此把一整块持久化契约改动拉进这个 60–90 行的切片。
