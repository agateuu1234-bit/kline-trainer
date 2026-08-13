# 划线工具扩充 · P1b 设计 spec：画完线自动选中 + 改样式的两套语义

**日期**：2026-08-12

**上游 spec**（继续全部生效；本文件只在 §1 明确列出的几条上推翻 / 修订，其余一字不动）：

- 母 spec `docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（D1–D22）
- 拆分补充 spec `docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md`（D23–D48）
- 1b-i 设计 spec `docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（D49–D67）
- 1b-ii 设计 spec `docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md`（D68–D80）

**基线**：`origin/main` `20f615a`（1b-i 四片 #153/#154/#156/#159 + 1b-ii 锁定 PR #163 全部合入）。
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

### 0.2 交付拆分：本 spec 设计的是**自动选中 PR**

| PR | 子项 | 内容 | 生产代码估算 |
|---|---|---|---|
| **自动选中 PR** | **① 画完自动选中** | 提交成功 → 那条线立刻选中；仍留在画线态可接着画；🔒 / 🗑 / 样式面板立刻作用于它 | ~40 行 |
| **自动选中 PR** | **② 改样式的两套语义** | 画线态改 = 本局默认 + 顺带套到刚画那条；选择态改旧线 = 只改那一条 | ~40 行 |
| **持久化 PR** | **③ 本局默认随存档续训继承** | **本 spec 不设计它** —— 它是一整块持久化 / 迁移切片（新增列 ×2 表 + migration + `user_version` + repo 读写 + schema-drift 闸门 + **replay clean-skip 判据** + autosave 触发 + 容错解码 + sanitize + 两条 resume 种子），**另开一份 spec**（D88 / §6.7） | 另行估算 |

**本 spec 的设计范围 = 自动选中 PR**。持久化 PR 的**需求**由 D87 定死（用户 2026-08-13 裁决），
它的**设计**另开 spec（D88 / §6.7：codex R6 的 critical 已经证明，塞进本文件一节只会产出一份接不到盘上的方案）。

**次序见 §0.4 的全局次序图**：**持久化 PR → 自动选中 PR**（D89 / §6.8：先落地持久化，自动选中 PR 才不会制造「线已落盘、默认没落盘」的半持久化坏状态）。

⚠️ **自动选中 PR 不得先于持久化 PR 合入**（D89 / §6.8，codex R8 推翻了我原先的「零增量」论据）：
自动选中 PR 的画线态改样式会把**线**写进存档（经 `drawingsRevision` → autosave），而本局默认在持久化 PR 之前**不落盘**
⇒ 续训后「线是新样式、默认回落出厂」的**半持久化**坏状态，main 上并不存在，是自动选中 PR 制造的。
调整次序之后这个中间态**结构上不会出现**。

### 0.3 D81　本片**不含**任何持久化改动 —— 全局默认属 §P6，用户已裁决

交接文档原本把「默认落盘持久化（settings 表五个标量 key）」列为本片的子项 ③，理由是「把 P6 的一小块提前拿出来做」。

**用户 2026-08-12 裁决推翻了这个安排**（逐字）：

> 「整个 APP 的默认的设置，就是线型、线色、线号，这些是在**小齿轮那边设置**。我们进来训练的时候，肯定是首先先用 APP 全局小齿轮那边设置的线色、线号这些来作为初始值。……我们在这个训练过程中……改这一局的默认的设置……**都是相当于只作用于这一局**。」

这与母 spec §13 逐字一致，**故 §13 不需要推翻、不需要修订**：

> §13（`2026-07-04-drawing-tools-expansion-design.md:303-310`）：「这些是**全局默认值**（持久化，`SettingsStore`/设置层）；每局训练/复盘按此**初始化**新画线的样式；用户局内再改则在该记录/复盘**局部覆盖**（**不回写全局**）。」

**结论**：本片**不碰全局默认**。不新增 settings key、不改 `AppSettings` / `SettingsDAO` / `AppDBMigrations`。
「**全局**默认落盘」连同齿轮「画线设置」界面整块留给 **P6**（母 spec §13），到时一并做。

⚠️ **这一条只管「全局默认」，与「本局默认」无关**。用户 2026-08-13 另有裁决：**本局默认必须跨断点续训继承**
（D87 / §6.6），那是 **持久化 PR** 的范围，动的是 `pending_training` / `pending_replay` 两张**表**的物理 schema，
**不是** settings 表、**不是**全局默认。两件事别混。

**为什么不先把「读」那一半做了**：今天没有任何东西会去写那五个 key，读出来恒为出厂值 —— 那是没有真实验收场景的投机代码（CLAUDE.md §2）。P6 做界面时读写一起落地，代价更低、验收面完整。

### 0.4 PR 命名与**全局次序**（codex spec-R11 high：本文件曾有两个「PR-2」）

> **来源：codex spec-R11 唯一 high。** 本文件原先把「本局默认持久化」和 1b-ii 的「撤销 / 前进」都叫 **PR-2**，
> 于是 §0.4 那句「本片先做、PR-2 后做」（本意指撤销）看起来像在批准「本片先于持久化做」——
> 而那正是 D89 明令禁止的。**编号已全部废除，改用不会撞车的名字。**

| 名字 | 内容 | 设计写在哪 |
|---|---|---|
| **持久化 PR** | 本局默认随存档续训继承（`pending_training` / `pending_replay` 两张表） | **另开 spec**（D88 / §6.7） |
| **自动选中 PR** | ① 画完自动选中 ② 改样式两套语义 —— **本 spec 设计的就是它** | 本文件 |
| **1b-ii 锁定 PR** | 底栏 🔒（**已 MERGED #163**，是本片的基线） | 1b-ii spec |
| **1b-ii 撤销 PR** | 底栏 ↩ ↪ 撤销 / 前进 | 1b-ii spec |

**全局次序（不可颠倒的只有第一条）**：

```
持久化 PR  →  自动选中 PR  →  1b-ii 撤销 PR
   ↑ 强制（D89 §6.8）        ↑ 互不依赖，次序可换
```

- **「持久化 PR → 自动选中 PR」是强制的**（D89 / §6.8）：自动选中 PR 会新增一条落盘的 `applyStyle` 写入，
  若本局默认尚未持久化，就会产生「线已落盘、默认没落盘」的半持久化坏状态。
- **「自动选中 PR ↔ 1b-ii 撤销 PR」互不依赖、次序可换**，已定为自动选中 PR 先做。
  ⚠️ 这一条**不给持久化 PR 的次序开任何口子**。
- 本片**不属于** split addendum **D23** 的六段切分，是六片序列之外、由用户新诉求驱动的追加片。
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
| e | id 与既有线碰撞（`appendDrawing` 的 `!drawings.contains(id)` 门） | ③ 判 `wasPresent == true` → ⑥ 拒 | **否，且结构上不可能**：`commitPending` 内部经 `DrawingObject.init` 生成**全新 UUID**，外部无参数可控。⚠️ 正因如此，合取项 ① 是**纯纵深不变量**，且它的变异档（M5a）**只能经内层 `routeAndSelect` 构造**——这是 D85 拆内外两层的直接理由（codex spec-R5 medium） |
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

**undo / redo 恢复回来的线不适用本决策**，一律不自动选中（1b-ii spec `:408` 原样成立）。理由：那条线不是用户此刻「画」出来的，它可能落在屏幕外、可能属于另一个面板，把选中硬塞给它反而重新制造 D37 的陈旧选中。持久化 PR 实施时**不得**复用 `commitPendingAndSelect`。

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

这与 1b-i PR-3 在 `.select` 分支里那道门的写法逐字同构（`ChartContainerView.swift:369-371` 的注释原文：「门**只包这一支**……fail-closed 的门必须限定到它真适用的那一类」），也与 1b-ii 锁定 PR 那道 `.segment` 门误管所有工具是同一类错误。

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

**拆成内外两层**（codex spec-R5 medium：**每条要求的变异都必须能真的写出来**）：

```swift
/// 外层 = 生产入口。只做「从 pending 锚造出候选对象」这两道门（①②），随后交给内层。
static func commitPendingAndSelect(panel: PanelId, mapper: CoordinateMapper, engine: TrainingEngine)

/// 内层 = 落库与选中处置（③④⑤⑥）。**接收一个已经造好的 `DrawingObject`**。
/// 这个缝不是为测试硬开的口子，它就是「造对象」与「落库+定选中」两件事的自然分界；
/// 但它顺带让 M5a / M5b / M5c / M2 四条变异**可构造**——外层的 `commitPending` 内部生成全新 UUID，
/// 测试无从预知 id，也就造不出 id 碰撞档（`DrawingObject.init` 的 id 无参数可控）。
static func routeAndSelect(_ committed: DrawingObject, panel: PanelId, engine: TrainingEngine)
```

⚠️ **拆层不得削弱 R1 的收口**：六条出口仍然全部落在这两个函数里、同一个文件里；
`commitPending` 与 `routeDrawingCommit` 在 `Sources/` 里仍各只有一个调用点（G1 / G1b 不变）；
生产路径上 `routeAndSelect` **只有外层一个调用点**（新增守卫 **G6**）。

**六步顺序是 load-bearing 的，一步都不许换位**：

| 步 | 层 | 做什么 | 换位 / 省略的后果 |
|---|---|---|---|
| **①** | 外 | `guard let committed = engine.drawingSession.commitPending(panelPosition: panel == .upper ? 0 : 1) else { clearSelection(); return }` | 省掉 `clearSelection` → 出口 a / b 留下陈旧选中（M13） |
| **②** | 外 | `guard HorizontalLineTool.visibleGeometry(for: committed, mapper: mapper) != nil else { clearSelection(); return }` | 省掉 `clearSelection` → 出口 c 留下陈旧选中（M14，= codex R1 的原始 finding） |
| **③** | 内 | `let wasPresent = engine.drawings.contains { $0.id == committed.id }` | 挪到 ④ 之后 → 恒 true → 自动选中整体失效（M5c） |
| **④** | 内 | `engine.routeDrawingCommit(committed)` —— **无条件**，复盘照常落线 | —— |
| **⑤** | 内 | `guard engine.flow.mode != .review else { return }` —— 复盘到此为止（D84） | 挪到 ④ 之前 → 复盘落线功能回归（M2） |
| **⑥** | 内 | `!wasPresent && visibleDrawings(…, panel: panel, …).contains { $0.id == committed.id }` → `setCommittedSelection`；否则 → `clearSelection`（出口 d / e） | 见 M5a / M5b / M6 |

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
/// ⚠️ 画线态**把同一个 mutation 分别套到两个 base 上**（§6.3 #0），不是套一份默认快照。
static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                    engine: TrainingEngine)

/// §6.4 base ②：选中线**当前**的 5 个样式字段（无选中 / 不唯一 / 结构性不可见 → nil）。
/// 与 `panelStyle` 的选择态分支同源取值，但**语义不同**：那个回答「面板显示什么」，
/// 这个回答「改线时从哪儿起算」。两者在画线态**刻意不同**（前者取默认、后者取线）。
private static func selectedLineStyle(engine: TrainingEngine) -> DrawingDefaultStyle?
```

- `TrainingView.swift:517-527` 那个 `if engine.drawingSession.selectedDrawingID != nil { applyStyleMutation } else { applyDefaultStyleMutation }` 分流**必须删掉**，改为无条件调 `applyPanelStyleMutation`。留着就是**第二份判据**，早晚与 `panelStyle` / `styleControlsEnabled` 漂移。
- `applyStyleMutation` / `applyDefaultStyleMutation`（`DrawingEditRouter.swift:200-214`）被 `applyPanelStyleMutation` **严格泛化**（三个分支的 base 与写入与它们逐一等价），成为本次改动制造的孤儿 → **一并删除**（CLAUDE.md §3：清理自己造成的孤儿）。`applyStyle`（真正的写入路由）**保留不动**。

### 6.3 画线态写入的四条硬约束

0. **套到线上的是「同一个字段级改动」，不是「默认的整份快照」**（codex spec-R9 high，**已实测推演证实**）。

   **反例（上一稿会真的发生）**：画线 A（橙、粗细 1，自动选中）→ **锁定 A** → 改颜色为紫
   （默认变紫；`applyStyle` 被 `!d.locked` 拒 → A 仍是橙 ⇒ **默认与 A 已分叉**）→ **解锁 A** → 只改**粗细**为 3。
   上一稿此刻 `next = 默认快照 {紫, 3}` **整份**套上去 ⇒ **A 的颜色被静默从橙改成紫**，
   并经 `drawingsRevision` → autosave **落盘**。用户只碰了粗细，被改掉的却是他刚刚特意锁起来保护过的颜色。

   **正解**：两处各自「现取 + 同一个 mutation」——

   ```swift
   var d = engine.drawingSession.defaultStyle          // base ①：默认自己
   mutate(&d); engine.drawingSession.setDefaultStyle(d)
   if let cur = selectedLineStyle(engine: engine) {    // base ②：**那条线自己当前的 5 个样式字段**
       var l = cur; mutate(&l); _ = applyStyle(l, engine: engine)
   }
   ```

   ⇒ 线上**只有用户真正点的那一项**会变；先前被门拒过的那一项**保持被保护的值**，
   不会在下一次无关操作里被"追认"。

   ⚠️ **`applyStyle` 的入参是完整的 `DrawingDefaultStyle`**（D50 的 API 形状，本片不改），
   所以「只改一项」**只能靠选对 base 来表达**，不能靠「只传变了的字段」。**base 选错就是这条缺陷本身。**

1. **顺序 load-bearing：先写默认，再 best-effort 改线。**
   默认是主语义、必须成功；线是附带、可能被门拒（锁定 / 滑出屏幕 / 未来数据 / 工具未实现）。反过来写会让「线改失败」在实现上很容易被顺手写成「整个操作失败」，而用户点了一下颜色却什么都没变。
2. **`applyStyle` 失败不回滚默认、不给任何反馈。** 母 spec §3 逐字：灰只降饱和、**绝不写任何解释文案**。
3. **`applyStyle` 的返回值在画线态被刻意丢弃**（`_ =`），且**不得**据它决定选中生命期 —— D64 原样成立（失败原因有五类，三类必须保留选中，一个 Bool 表达不了）。

### 6.4 「现取」纪律保持 + **两个 base 各自的选取规则**

```swift
var next = panelStyle(engine: engine)   // ← 现取：动作发生这一刻的真值，不是视图渲染时的快照
mutate(&next)
```

这是 1b-i PR-4 codex 整支 R3 修过的那个**真丢数据**的回归（两个控件在 SwiftUI 重渲染之前先后触发，第二次拿旧快照把第一次 revert 掉，选中线路径还会经 `drawingsRevision` 被 autosave 持久化）。**绝不能改成接收调用方传入的快照。**

**base 的选取规则**（codex spec-R9 high 之后修订）：

| 写入目标 | base | 理由 |
|---|---|---|
| **本局默认** | `session.defaultStyle` | 它就是「下一笔要画成什么样」的真值 |
| **选中的那条线** | **那条线自己当前的 5 个样式字段**（`selectedLineStyle`） | 只有这样，一次改动才只影响用户真正点的那一项（§6.3 #0） |

⚠️ **「面板显示什么」与「写线时用哪个 base」不是同一个问题**：画线态**显示**默认（§6.1 第一张表），
但**写线**的 base 是线自己。上一稿把两者合成一个 `panelStyle` 复用，正是 §6.3 #0 那条缺陷的来源。
**「现取」纪律对两个 base 同样成立**——都在动作发生那一刻取，绝不用视图渲染时的快照。

### 6.5 副作用与已接受残留

1. **画线态下 🔒 / 🗑 会亮** —— 这正是需求 ①。`lockButtonEnabled` / `deleteButtonEnabled` / `canToggleLock` / `canDelete` **不含 mode 分量，全部不改**。
   ⚠️ **「会亮」不等于「无条件亮」**（codex spec-R3 high）：`deletableIgnoringGeometry` 末行是 `return !d.locked`（`DrawingEditRouter.swift:93`）——**锁定的线在画线态同样删不掉，🗑 照样灰**。自动选中**不得**成为放宽这道门的理由：那是一条不可逆销毁的信任边界。`lockableIgnoringGeometry` 刻意**没有** `!d.locked` 分量（锁定线必须仍能被解锁），这个不对称是 D71 的原样保留，本片不碰。
2. **「无选中」在画线态变得难以达到**。交接文档原本把它列为需要替代入口的副作用（「熄灭画线图标 → 改默认 → 再点亮」）。D86 把画线态的面板改成**恒显示默认、恒可用、恒写默认**之后，**这个副作用不再有代价**，那条替代入口不再需要。
3. **画线态下 `panelStyle` 不回显选中线**。提交那一刻两者相等（`commitPending` 就是用 `defaultStyle` 造的线），只在「那条线改不动、默认继续改」之后才分叉 —— 而画线态的语义本来就是「我下一笔要画成什么样」，分叉后显示默认是正确的。这是对 D49 的**有意修订**，不是回归。
4. `applyStyle` 的 `defer { syncSelectionByState(engine:) }` 在画线态照跑，语义正确（只在线不在可见集合时清空，与 mode 无关）。
5. **复盘不受 D86 影响**：常驻样式面板在复盘根本不出现（`TrainingView.swift:116` `stylePanelWillBeVisible = showsTradeButtons && …`，而 `showsTradeButtons = engine.flow.canBuySell()` 在复盘为 false）。

### 6.6 D87　「本局默认」的生命期 = **本局训练存档**，必须跨断点续训继承（用户 2026-08-13 裁决）

> **来源：codex spec-R4 / R5 连提两轮的 high。R4 我把它定成了「引擎实例生命期 + 已接受残留」，
> 用户 2026-08-13 推翻了这个定位。**

**用户裁决（逐字）**：

> 「每一局训练，然后退出了再回来，其实相当于原来的训练**还没有完全结束**嘛，因为用户没有点结束按键，只是相当于返回了再继续进行训练。……相当于是个**断点**，我重新开始，那也要**继承之前我已经做的这些改动**……而不是重置回我们这个 APP 的默认设置。」

**D87 决策**：「本局默认」的生命期 **= 本局训练存档的生命期**。

| 事件 | 本局默认 |
|---|---|
| 局内改样式（画线态） | 更新（D86） |
| 点「返回」回主页 → 点「继续训练」续上**同一局** | **继承**（不回落） |
| App 被杀 / 切后台被系统回收 → 续训 | **继承** |
| 本局**结束**（点结束 / 自动结束）后**新开一局** | **不继承**，回落到全局默认（今天 = 出厂值，P6 之后 = 齿轮里设的那个） |
| 复盘 | **不适用** —— 见 §6.7 的排除证明 |

**这与母 spec §13 一致**：§13 原文是「用户局内再改则在**该记录 / 复盘局部覆盖**（不回写全局）」——
「该**记录**」本就意味着覆盖量绑在记录上，而不是绑在一次 App 前台会话上。我 R4 那版把它降级成「引擎实例」，
是对 §13 的**误读**，不是 §13 允许的取舍。

**R4 那版被推翻的部分与保留的部分**（写清楚，免得当成反复）：

- **推翻**：「引擎实例生命期 + 已接受残留 + 交 P6」这个定位，以及据此写的「验收 #23 = 记录既定行为、非阻塞」。
- **保留（仍然成立、已实测）**：**`setDefaultStyle` 这一条写入路径**上，本片确实零增量
  （`defaultStyle` 在 `KlineTrainerPersistence/` 出现 **0 次**；`TrainingEngine.swift:54` 逐字「会话是局内瞬态」；
  main 上画线态**恒无选中**（D54）→ 画线态改样式本来就走 `applyDefaultStyleMutation` → `setDefaultStyle`）。
- ⚠️ **但这条事实推不出「自动选中 PR 可以先合」**（codex R8 → R9 连续指出，**已实测证实**）：D86 给画线态**新增**了一条
  `applyStyle` 写入，它经 `updateDrawingStyle` → `drawingsRevision` → autosave **会落盘**。于是 自动选中 PR 单独上线会产生
  「线已落盘、默认没落盘」的**半持久化**坏状态 —— main 上并不存在。
  **故：自动选中 PR 不得先于 持久化 PR 合入**（D89 / §6.8）。本节**不再**为「自动选中 PR 先合」提供任何依据。

### 6.7 D88　持久化 PR（本局默认持久化）**另开一份 spec**，不在本文件内设计

> **来源：codex spec-R6 一条 critical + 一条 high，均已对源码实测证实。我上一稿的 D88 在物理层是错的。**

**上一稿错在哪（必须写清楚，这是本 spec 犯过的第三次同族错误）**：

我写「`PendingTraining` / `PendingReplay` 的 Codable 是显式的，新增 key 走 `decodeIfPresent` 附加式即可」。
**实测：那个 Codable 根本不是落盘边界。**

| 实测事实 | 出处 |
|---|---|
| `pending_training` 是**逐列建表**（`training_set_filename` / `global_tick_index` / … / `drawdown` / `session_key`） | `AppDBMigrations.swift:57-71` + `0004` |
| `pending_replay` 同构，**另建于 migration `0006`**，且该 migration 自己 `PRAGMA user_version = 4` | `AppDBMigrations.swift:164-184` |
| repo 写盘是 `INSERT OR REPLACE INTO pending_training (…14 个具名列…) VALUES (…)`，读盘按列名取 | `PendingTrainingRepositoryImpl.swift:18-45` |

⇒ 照上一稿实施，会得到**内存 round-trip 测试全绿、而值从来没进过数据库**——[[feedback_uikit_gated_evidence_traps]] 那一族的假绿。

**另一条实测（codex R6 high，同样属实）**：replay 的写盘有 **clean-skip**——
`replayBaseline = (tick, ops, drawingsSig, upper, lower)`（`TrainingSessionCoordinator.swift:56`），
在 `!replayHasPersisted` 时生效（`:611-615`）。
⇒ fresh replay 里**只改了默认**：四个分量一个没变 → **clean-skip 跳过、根本不写盘** → 续局必丢。
⚠️ `TrainingSessionCoordinator.swift:55` 的注释里记着**同一形状的旧 bug**（当初漏把 periods 纳入比较），我原地重踩了一次。

**决策：持久化 PR 另开 spec，走完整的 brainstorming → spec → codex 评审 → plan 流程。**

理由不是回避评审，恰恰相反——R6 的 critical 说的就是「持久化 PR 的持久化方案不完整」，
而补完它需要设计的东西已经是一整块持久化切片，与画线交互是**完全不同的风险面**：

物理形状（两个可空列 vs 一个版本化 JSON blob）· 新 migration 编号与 `user_version` · 两张表的 repo 读写 ·
内存假件与 debug fixture · **schema-drift 闸门覆盖**（`scripts/check_app_schema_drift.sh`）·
**replay clean-skip 判据与 baseline 元组扩展** · autosave 触发 · 容错解码 · 解码后 sanitize · 两条 resume 种子。

把它塞进本文件一节，产出的必然是一份「看起来完整、实施时才发现没接到盘上」的设计——
本轮 critical 已经演示过一次了。

**交给 持久化 PR spec 的既得事实（已实测，不必重查）**：上表三条 + clean-skip 那条 + 下列两条硬约束：

| 约束 | 不这么做会怎样 |
|---|---|
| **逐字段容错解码 + 未知枚举回落出厂，绝不 throw**（`LineSubType` / `LineStyle` / `DrawingColorToken` / `LabelMode` 都是 `String` 原始值枚举，合成解码遇未知值**会抛**） | 一个**装饰性偏好**的坏字节 → **整局训练存档不可解码** → 用户丢掉一整局进行中的训练 |
| **解码后必须 sanitize**（`lineSubType` 经 `DrawingStyleAvailability.isRenderableSubType`、`thickness` 夹回 `1…5`、`labelMode` 经 `normalizedLabelMode`，判据**复用既有单一真相**） | 磁盘上躺着 `.segment` → `commitPending` 的 `withStyle` **恒返回 nil** → 用户进画线模式**一条线都画不出来**，且无任何提示 |

**存档面 = `pending_training` + `pending_replay` 两张表；复盘 `review_archive` 可证明排除**：
常驻样式面板在复盘**根本不渲染**（`TrainingView.swift:116` `stylePanelWillBeVisible` 依赖 `showsTradeButtons`
= `engine.flow.canBuySell()`，复盘恒 false）⇒ 复盘里改不了本局默认 ⇒ 没有东西要存。
⚠️ **这条排除的依据是那个谓词**。**P5 若让复盘用上新底栏 / 常驻面板，排除立刻失效**，必须同期接上 `review_archive`。

### 6.8 D89　**次序倒过来：持久化 PR（持久化）先，自动选中 PR（交互语义）后**

> **来源：codex spec-R6 high → R7 high → R8 high 三轮同一处。R8 给出了一个新论据，**
> **它推翻了我 R7 写的「零增量」，我全部采纳。**

#### 6.8.1 我 R7 那版「零增量」错在哪（必须写清楚）

R7 那版的论据是：「自动选中 PR 新增 `setDefaultStyle` 调用 **0** 次，`defaultStyle` 在持久化层出现 **0** 次
⇒ 丢失路径的可达性 / 频率 / 后果完全相同」。

**这个测量只量了耦合的一边。** R8 指出的另一边：

| | main 今天 | 自动选中 PR 之后（D86） |
|---|---|---|
| 画线态改一次颜色 | 只 `setDefaultStyle(next)` ——**刚画的那条线不变色**（画线态恒无选中，D54） | `setDefaultStyle(next)` **＋** best-effort `applyStyle(next)` 套到自动选中的那条 |
| 有没有东西落盘 | **没有**（`drawingsRevision` 不动） | **有** —— `applyStyle` → `updateDrawingStyle` → `drawingsRevision += 1` → autosave（`TrainingView.swift:368`） |
| 返回 → 续训后看到什么 | 线是橙、默认是橙 —— **一致** | 线是**紫（已落盘）**、默认回落**橙（没落盘）**，再画一条又是橙 —— **半持久化、自相矛盾** |

⇒ **自动选中 PR 确实制造了一个 main 上不存在的坏状态**，并且它直接违反 D87 的用户裁决（续训必须继承）。
**R7 那版 D89 的结论作废**，§6.8.2 里那套「remedy 不成比例」的论证随之作废（前提没了）。

#### 6.8.2 修法：把两个 PR 的**次序倒过来**（比 codex 的两个处方都便宜）

**持久化 PR（本局默认持久化）→ 自动选中 PR（自动选中 + 两套语义）。**

**依赖方向实测支持倒序**：`session.defaultStyle` 在 **main 上已经存在、已经被 `applyDefaultStyleMutation` 写**
（画线态恒无选中 ⇒ 恒走该分支）。⇒ **持久化 PR 不依赖 自动选中 PR，今天就能单独实施**，它持久化的是一个**既有**的值。

| 时点 | 状态 |
|---|---|
| 持久化 PR 合入后 | 修掉 main 上**本来就有**的「续训丢默认」缺口。此时画线态改样式仍只写默认（不碰线）→ 存的和恢复的都是默认，**无耦合、无半持久化** |
| 自动选中 PR 合入后 | 默认**已经**会持久化 ⇒ 画线态一次改样式，线与默认**一起落盘、一起恢复** ⇒ **任何时刻都不存在半持久化状态** |

**因此不需要** codex 提的两个处方：不需要合并闸（倒序后 持久化 PR 单独合入即净收益），
不需要 feature flag（不会有任何中间态需要藏起来，也就不必引入死路径 / 违反 D19-D24 / 制造无闸门覆盖的构建配置）。

#### 6.8.3 交付闸（沿用本仓已有的发布机制）

- **本片在 自动选中 PR 与 持久化 PR 都合入之前不算交付完成**：不进任何 freeze tag、不宣布功能可用、
  进度 memory 标「交付未完成」而非 ✅、每个 PR 描述顶部带横幅并列明未完成项。
- **验收表里不设任何一条把「续训后回落出厂橙」写成正常的项**（原 #23 已删除）。
- **自动选中 PR 必须带一条「一致性」回归**（codex R8 明确要求，采纳）：
  画线态自动选中 → 改样式 → autosave → 续训 → 断言**线的样式与本局默认双双恢复且互相一致**。
  ⚠️ 这条测试**在 持久化 PR 之前必然红**——这正是次序不可颠倒的机械证据，**不得**为了让 自动选中 PR 单独绿而弱化它。

#### 6.8.4 §0.2 的次序表述随之更新

原「次序：自动选中 PR → 持久化 PR」**作废**，改为 **持久化 PR → 自动选中 PR**。
（自动选中 PR 的**设计**仍写在本 spec；持久化 PR 的设计另开 spec，见 D88 / §6.7。
 本 spec 的实施计划要等 持久化 PR 落地之后才启动。）

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
| **P7** 画线态 + 选中线未锁定 + 改**一项**样式 | 那条线**只有该项**变、其余 4 项**逐字段未变**；`session.defaultStyle` 该项也变。⚠️ 断言「其余 4 项未变」是 §6.3 #0 的正向证据，不能只断言变了的那一项 |
| **P6** 画线态 + 自动选中的线**已锁定**（codex spec-R3 high 要求的回归档） | `deleteButtonEnabled == false` **且** `canDelete == false`（自动选中**不得**让锁定线变得可删）；同时 `lockButtonEnabled == true`（🔒 仍可用于解锁，否则永远解不开）。**两个断言缺一不可**——只断言前者，一个「锁定线连 🔒 也灰掉」的实现照样绿 |

### 7.2 变异清单（每条注明**只有它够得到**的档）

| # | 变异 | 必须且只应变红 |
|---|---|---|
| M1 | 删掉 D84 的 `flow.mode != .review` 门 | 复盘档（选中越界）红；训练档 P1/P2 **不得**红 |
| M2 | 把 D84 的门（第 ⑤ 步）挪到第 ④ 步 `routeDrawingCommit` **之前** | 复盘**落线**档红（`reviewDrawings.count` 不再递增）；这一条证明 §4.2 的双断言不是空转 |
| M3 | 把 `setCommittedSelection` 的守卫改成 `mode == .select` | P1 红（自动选中整体失效） |
| M4 | 把 `setSelection` 的守卫放宽成 `mode != nil` / 删掉 | 「画线态调 `setSelection` 必须被拒」的不变量锁测试红 |
| M5a | 删掉 D83 谓词的合取项 **①**（提交前不存在该 id） | **只有** id 碰撞档红。⚠️ **必须经内层 `routeAndSelect` 构造**（codex spec-R5 medium）：外层的 `commitPending` 内部生成全新 UUID、测试无从预知，**经外层根本写不出这条档**。造法：自己构造一个 id 已知的 `DrawingObject`、先把同 id 的另一条线塞进 `engine.drawings`、再调内层 → 断言选中**保持为 nil**，不得变成那条老线 |
| M5b | 把 D83 谓词的合取项 **②** 改成恒 true | **只有出口 f 档**红（codex spec-R2 medium 重定向）。⚠️ **原先举的两个例子（周期不一致 / 射线越右缘）对 ② 零判别力** —— 六步流程下它们分别死在第 ① / ② 步，**根本到不了第 ⑥ 步**。正确造法：单元级构造一个「锚的 period ≠ 被点面板当前 period」的 pending 锚（`addAnchor` 不校验二者一致），使 ①②③④ 全过、`appendDrawing` 也成功（`isPeriodConsistent` 只比对象自身的锚与 period，`TrainingEngine.swift:1246-1249`），但 `belongsToPanel` 判它不属于本面板 → 合取项 ② 为 false → 断言**不授予选中** |
| M5c | 把第 ③ 步（`wasPresent` 快照）挪到第 ④ 步 `routeDrawingCommit` **之后** | P1 红（自动选中整体失效）—— 这条证明「快照顺序」不是纸面约定。经内层构造 |
| M6 | 删掉 D83 分支 2 的 `clearSelection()` | **只有**「先选中一条、再让下一次提交被拒」的档红 |
| M7 | 把 `panelStyle` 的 `.draw` 分支改回「有选中取那条线」 | 「画线态 + 选中线已锁定 + 改样式 → 面板显示新默认」的档红 |
| M8 | 把 `styleControlsEnabled` 的 `.draw` 分支改回现有谓词 | **只有**「画线态 + 选中线已锁定 → 控件仍可用」的档红（= 用户 Q2 选择的判别力所在） |
| M9 | 把 D86 画线态的 `setDefaultStyle` 删掉（只改线） | P3 的 `defaultStyle` 断言红、线的断言不红 |
| M10 | 把 D86 选择态改成也写 `setDefaultStyle` | **只有** P4 红 |
| M11 | 把 `applyPanelStyleMutation` 的 base 改成调用方传入的快照 | 「两次连续改动不互相 revert」的档红（1b-i PR-4 R3 那条回归的守门测试） |
| **M15** | 把画线态**写线**的 base 从 `selectedLineStyle` 改回 `session.defaultStyle`（= 上一稿的整份快照） | **只有「锁定分叉」档**红（§6.3 #0 的反例：画线 → 锁定 → 改色被拒 → 解锁 → 只改粗细 → 断言**颜色仍是原色**）。⚠️ 这条档**必须走完整五步**；少了「锁定 → 改色被拒」那一步，默认与线不会分叉，改回快照也照样绿 = 零判别力 |
| M12 | 删掉 `.draw` 分支新增的 `rebuildRenderState` | 渲染态档红（`KLineRenderState.selectedDrawingID` 本帧仍是旧值） |
| **M13** | 删掉第 **①** 步（`commitPending` 返 nil）的 `clearSelection()` | **只有**「已有选中 → 下一次提交因 `commitPending` 返 nil 被拒」的档红（出口 a / b） |
| **M14** | 删掉第 **②** 步（几何预检失败）的 `clearSelection()` | **只有**「已有选中 → 下一次提交因射线越右缘被拒」的档红（出口 c，= **codex spec-R1 那条 high finding 的守门测试**） |

**M5b / M13 / M14 三条都是「不变量锁」级**（§3.2：对应出口本期经真实 tap 不可达）——档只能**单元级构造**：直接给 `DrawingSession` 塞 pending 锚、直接构造让判据成立的 `mapper`，不经 `handleDrawingTap`。这不是降低标准，而是 [[feedback_mutation_must_target_the_exact_predicate]] 明写的正解：判据在生产路径上不求值时，写成不变量锁测试，**而不是假装它有行为覆盖**。

**M13 / M14 的档必须造成「先有一个选中，再让下一次提交被拒」**——只造「无选中时提交被拒」是零判别力的（那种档在删掉 `clearSelection` 后照样绿）。

**实施要求**：**§7.2 表格里的每一条 M（含 M5a / M5b / M5c 等所有带字母后缀的分条）全部逐条关门看红**——**清单以表格为准，本句刻意不枚举编号**（codex spec-R10 high 的根因就是我上一稿枚举成「M1–M14」、新增 M15 后忘了同步，于是强制清单与表格脱节；改成「表里全部」之后，**再加多少条都不会漏**）。
并在 PR 描述里逐条记录「红的是**哪个测试名**」，以及**恢复后重新变绿**的证据。实施者自报「验过了」不算数（[[feedback_mutation_testing_beats_reading]]）。

⚠️ **M15 是强制项，不是可选项**（codex spec-R10 high：我上一稿加了 M15，却把强制清单留在「M1–M14」，等于实施者可以**完整满足写明的变异要求、同时把 R9 那条最危险的回归完全不测**）。M15 另有两条附加要求：
- 必须有一条**具名 host 测试**覆盖**完整五步序列**（画线 → 锁定 → 改色被拒 → 解锁 → 只改粗细 → 断言颜色未变），测试名要在 PR 描述里写出来；
- **少任何一步都零判别力**：没有「锁定 → 改色被拒」，默认与线不会分叉，把 base 改回默认快照也照样绿。
变异复原一律 `cp` 到 /tmp 再 `cp` 回，**禁止 `git checkout <file>`**（会静默抹掉未提交改动，[[feedback_git_checkout_destroys_uncommitted_work]]）。

### 7.3 不变量锁测试（对「不可达」的正确写法）

M4 对应的那条判据在生产路径上**根本不会被求值**（`.draw` 分支不调 hitTest、不调 `setSelection`）。按 [[feedback_mutation_must_target_the_exact_predicate]]，正解是把「不可达」写成**不变量锁测试**而不是假装它有行为覆盖：

- **N-lock-1**：`mode == .draw` 时直接调 `setSelection(id:panel:)` → 选中**保持为 nil**。
- **N-lock-2**：`mode == .select` 时直接调 `setCommittedSelection(id:panel:)` → 选中**保持为 nil**。

两条一起钉死「两个入口互斥」这个 D82 的全部价值。

**分支 2 的三条同样是不变量锁**（§3.2：六条出口本期经真实 tap 全部不可达）——直接调 `commitPendingAndSelect`、单元级构造入参，不经 `handleDrawingTap`：

- **N-lock-3**（出口 a/b，对应 M13）：先建立一个选中 → 塞一组 period 互不相同的 pending 锚（或让 `withStyle` 返 nil）→ 调用 → 断言 `selectedDrawingID == nil` 且 `drawings.count` 未变。
- **N-lock-4**（出口 c，对应 M14）：先建立一个选中 → 构造一个使 `indexToX(anchor) >= mainChartFrame.maxX` 的 `mapper`（**单元级直接造 viewport，不要试图从 tap 造 —— §3.2 已证明造不出来**）→ 断言 `selectedDrawingID == nil` 且未落库。
- **N-lock-5**（出口 f，对应 M5b；**经内层 `routeAndSelect` 构造**）：造一个 period ≠ 被点面板当前 period 的 `DrawingObject` → 调内层 → 断言**落库成功**（`drawings.count` +1）**但不授予选中**（`selectedDrawingID == nil`）。这条是合取项 ② 唯一的判别力来源。

⚠️ 三条都必须**先建立一个选中**再触发（M13/M14）或**断言落库确实发生**（N-lock-5）——少了前置状态，删掉被测那一句照样绿。

### 7.4 平台覆盖

| 判据 | 跑在哪 | 变异 |
|---|---|---|
| D82（两入口互斥）、D83（六步顺序 + 六条出口 + 两个合取项）、D84（复盘门位置）、D86（三张表 + 写入顺序 + 现取） | **host `swift test`**（`DrawingSession` / `DrawingEditRouter` / `RenderStateBuilder` / `HorizontalLineTool` / `CoordinateMapper` 均无 UIKit） | M1 / M2 / M3 / M4 / M5a / M5b / M5c / M6 / M7 / M8 / M9 / M10 / M11 / **M13 / M14 / M15** |
| `ChartContainerView.draw` 分支换调用 + 补 `rebuildRenderState`；`TrainingView` 删 if 分流 | 源码守卫（host）+ **Catalyst 编译与测试门** | **M12（只有它必须上 Catalyst）** |

**M2 / M5a / M5b / M5c 四条经内层 `routeAndSelect` 构造，M13 / M14 经外层 `commitPendingAndSelect` 构造**（D85 §5.1 拆层的理由）。
**M15 经 `applyPanelStyleMutation` 构造**（画线态、五步序列），与 P7 一起构成 §6.3 #0 的正反两面证据。

**D85 把「尝试提交」整段挪进 `DrawingEditRouter` 的直接收益就在这张表**：16 条变异里 15 条落在 host。
若按上一稿只挪 `routeDrawingCommit` 一句，M13 / M14 这两条（= codex R1 那条 high finding 的守门测试）就只能上 Catalyst。

⚠️ **UIKit-gated 文件在 host 上根本不编译** → M12（唯一一条）必须上 Catalyst 跑（[[feedback_uikit_gated_evidence_traps]]），且 Catalyst 必须用 `-scheme KlineTrainerContracts-Package` + `set -o pipefail`（[[feedback_catalyst_scheme_and_pipefail_double_trap]]）。判绿读**执行量**，不读 `TEST SUCCEEDED` 字样。

---

## 8. 源码守卫

| # | 守卫 | 形状 |
|---|---|---|
| **G1** | `routeDrawingCommit` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内 | 结构计数 |
| **G1b** | `commitPending` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内（D85 §5.1 第 ① 步）—— 防实施者「只搬一半」，把 `commitPending` 留在 `ChartContainerView` 里 | 结构计数 |
| **G2** | `setCommittedSelection` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内 | 结构计数 |
| **G6** | `routeAndSelect` 在 `Sources/` 里**恰好 1 个**调用点，且在 `Drawing/DrawingEditRouter.swift` 内（= 外层 `commitPendingAndSelect`）——拆内外两层**不得**变成两个生产入口 | 结构计数 |
| **G3** | `applyStyleMutation` / `applyDefaultStyleMutation` 两个标识符在 `Sources/` 的**代码文本**里**恰好 0 次**出现（已删除） | 结构计数。⚠️ **必须剥注释后再数** —— D86 §6.2 要求给 `applyPanelStyleMutation` 写一句「取代 applyStyleMutation / applyDefaultStyleMutation」的承重注释，不剥注释 G3 会被这句注释自己打红，而「删掉那句注释」就成了合法绕过路径 |
| **G4** | `applyPanelStyleMutation` 在 `Sources/` 里**恰好 1 个**调用点，且在 `UI/TrainingView.swift` 内 | 结构计数 |
| **G4b** | `clearSelection` 在 `Drawing/DrawingEditRouter.swift` 里**至少 4 个**调用点（第 ① / ② / ⑥ 步 + 既有 `syncSelectionByState`）—— 少于 4 说明分支 2 的某条出口没接上 | 结构计数（**下界**，不是精确值：`applyStyle` / `deleteSelected` 等既有路径也可能增加，故用 ≥ 不用 ==） |
| **G5** | `setSelection`（不含 `setCommittedSelection`）在 `Sources/` 里**恰好 1 个**调用点，且在 `Render/ChartContainerView.swift` 内 | 结构计数（**匹配必须用完整调用语法锚**，`setSelection(` 会被 `setCommittedSelection(` 的子串误命中 → 需要边界锚） |

**纪律（缺一即失效）**：

- **不得写成「禁词黑名单」**，一律用结构计数（[[feedback_source_guard_text_source_discipline]]）。
- 否定 / 结构断言必须**剥注释、剥字符串字面量**再匹配 —— 否则本 spec 引用的那些承重注释会把守卫自己打红，且「删注释」会变成合法绕过路径。
- **每个守卫必须配双向自检**：喂一段「本该命中」的样本必须命中、喂一段「本该不命中」的样本必须不命中。锚点失效必须**报错**，不得静默返回 0（[[feedback_mechanical_checker_parser_disabled]]）。
- ⚠️ **G1 / G1b / G2 / G3 / G4 / G4b / G6 描述的是改动之后的状态，在当前树上是红的**（G1 与 G1b 今天的唯一调用点都在 `ChartContainerView`、不在 `DrawingEditRouter`；G2/G4 的符号今天还不存在；G3 今天恰好相反、两个标识符都还在；G4b 今天只有 1 个）。故它们**必须与对应的生产改动写在同一个 task 里**，不得作为「前置守卫」先行落库 —— 一条开局就红的守卫等于给实施者发放宽许可证（[[feedback_source_guard_must_be_green_on_current_tree]]）。每个 task 结束时它自己那几条守卫必须是绿的。
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
| 22 | 画一条线（自动选中）→ 点 🔒 锁定 → 在面板换一个**颜色**（线不会变色，锁着）→ 点 🔒 解锁 → 再只改**粗细** | 线的**粗细变了、颜色仍是原来那个**（没有被刚才那次没生效的换色悄悄追认）。⚠️ 若颜色跟着变了 = §6.3 #0 那条缺陷复现，**阻塞级** | |

**#18 / #19 / #22 是本片的三条硬边界**（不跨局 / 复盘不越界 / **被拒的改动不得被后续无关操作追认**），任何一条不过都是阻塞级。

⚠️ **本清单是 自动选中 PR 阶段验收，跑完不代表本片交付完成**（D89 / §6.8）——「本局默认跨断点续训继承」
（D87，用户 2026-08-13 裁决）由 持久化 PR 交付，它的验收项写在 持久化 PR 自己的 spec 里，**不在本表**。
**本表刻意不设任何一条把「续训后回落出厂橙」写成正常的项**：那是待修的缺口，不是已接受的行为。

⚠️ **分支 2（提交被拒 → 清空选中）没有真机验收项，这是刻意的**：§3.2 已证明它的六条出口在本期经真实 tap **全部不可达**（出口 c 更是可证明恒不可达）。
上一稿曾为它写过一条阻塞级真机项（射线点最右缘），**codex spec-R2 high 指出那条路走不通、我核实属实并已删除** —— 一条用户根本走不到的验收步骤，只会让人在真机上反复试、试不出来，然后要么误判为回归、要么随手打勾。
它的判据改由 §7.3 的**不变量锁测试**（单元级构造）覆盖。

---

## 10. 交接与残留

### 10.1 交给 1b-ii 撤销 PR（撤销 / 前进）

- **undo / redo 恢复回来的线不自动选中**（1b-ii `:408` 原样成立）。**不得复用 `commitPendingAndSelect`**（D83 §3.5）。
- undo 把一条线删掉时，若它正被选中 → 由 D54 clause 4（存在性谓词）自动清空，持久化 PR **不需要**为此新增判据。
- 持久化 PR 的入栈动作里包含「改样式」。D86 让**画线态**的一次改样式同时改了「线」和「本局默认」——**持久化 PR 必须决定 undo 是否一并回滚默认**，这是 持久化 PR 的 spec 范围，本片不预判。

### 10.2 交给 P6（母 spec §13）

齿轮「画线设置」界面 + 全局默认持久化（含 settings 表的 key 设计）整块留给 P6。届时：

- `DrawingSession.defaultStyle` 的**初始值**改为从全局默认种下（今天是 `DrawingDefaultStyle()` 出厂值）；
- 本片建立的「局内改只作用于本局」语义**不需要改动**（母 spec §13 逐字就是这个）。
- **持久化 PR（本局默认持久化）另开 spec**，D88 / §6.7 已把实测过的事实全部交接过去（两张表的物理 schema、
  repo 的具名列读写、`0006` migration 与 `user_version`、replay clean-skip 的 baseline 元组、
  容错解码与 sanitize 两条硬约束、复盘可证明排除及其失效条件）。**那份 spec 从这些事实起步，不必重查。**
- **P6 只需要接一件事**：把「新开一局时的初始值」从出厂值改成齿轮里设的全局默认。
  「本局覆盖量跨续训继承」由本片 持久化 PR 已经解决（D87 / D88），**P6 不要重做**。
- ⚠️ **P5 的联动**：D88 把复盘排除在存档面之外，依据是「常驻样式面板在复盘不渲染」这个谓词。
  **P5 若让复盘用上新底栏 / 常驻样式面板，这条排除立刻失效**，必须同期把 `ReviewArchiveWrapper` 一并接上，否则复盘会出现同样的丢失。

### 10.3 已接受残留

- **画线态下 `panelStyle` 不回显选中线**（§6.5 #3）。这是有意修订，验收 #11 是它的正面证据。
- **画线态下 `applyStyle` 失败无任何反馈**（§6.3 #2）。母 spec §3 逐字要求「绝不写解释文案」，用户看到的现象是「线没变、但下一笔会变」。
- ⚠️ **「本局默认不跨 resume」不是已接受残留，是 持久化 PR 的交付内容**（D87 §6.6）。且 **自动选中 PR 不得先于 持久化 PR 合入**（D89 §6.8）——自动选中 PR 会新增一条落盘的 `applyStyle` 写入，单独上线即产生「线已落盘、默认没落盘」的半持久化坏状态。**本条列在此处只为指路，不构成残留接受**。
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

| **R5** | 同分支 @ `d1f51f8`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：D87 把「本局默认」定成引擎实例生命期、验收 #23 还把「续训回落出厂值」标成正常非阻塞，等于用「本局默认」这个名字给一次用户可见的状态丢失背书；要么持久化，要么正名并**取得明确的产品裁决**<br>**1 medium**：M5a 要求预置一条与 committed 同 id 的线，但 `commitPending` 内部经 `DrawingObject.init` 生成**全新 UUID**、`commitPendingAndSelect` 签名里没有任何 id 缝 → **这条变异档根本写不出来**，合取项 ① 拿到的是一张空头保证书 | **medium 全采纳**：D85 拆成**内外两层**（外层 `commitPendingAndSelect` 管 ①②，内层 `routeAndSelect(_:panel:engine:)` 管 ③④⑤⑥），M2 / M5a / M5b / M5c 四条改经内层构造；出口 e 的可达性表述改为「结构上不可能」并把 ① 诚实标为纯纵深不变量；新增守卫 **G6**（`routeAndSelect` 恰好一个生产调用点，拆层不得变成两个入口）。**high 交产品裁决后全采纳**：codex 的处方本身就是 get explicit product acceptance。**用户 2026-08-13 裁决：返回 ≠ 结束，续训是断点续跑，本局默认必须继承**（逐字见 §6.6）。据此 **D87 整条重写**（生命期从「引擎实例」改为「本局训练存档」）、**新增 D88**（§6.7：存档面 / 容错解码 / sanitize / autosave 触发四条硬约束）、本片**改回两个 PR**（自动选中 PR 交互语义零持久化、持久化 PR 存档契约）、验收 #23 翻转并新增 #24–#26。⚠️ 我 R4 那版「引擎实例生命期 + 已接受残留」是对母 spec §13「该**记录**局部覆盖」的**误读**——「记录」本就意味着覆盖量绑在记录上。R4 里**保留成立**的只有一条事实：这是 main 上的既有缺口、自动选中 PR 不引入不加重。⚠️ **括号里当时那句「故 自动选中 PR 仍可先合」已被 R8 / R9 推翻**（D86 新增的 `applyStyle` 会落盘 → 半持久化），现行结论见 D89 §6.8 |

| **R6** | 同分支 @ `13d8a03`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 critical**：D88 按「给 `PendingTraining` 的 Codable 加可选 key」写持久化，但 pending 状态实际是 **SQL 具名列**，那个 Codable 根本不是落盘边界 → 照做会得到「内存往返全绿、值从没进过数据库」<br>**1 high**：replay 有 clean-skip（`replayBaseline = (tick, ops, drawingsSig, upper, lower)`，`!replayHasPersisted` 时生效），fresh replay 里只改默认 → 四个分量全没变 → 跳过不写盘 → 续局必丢<br>**1 high**：自动选中 PR 单独上线 + 验收 #23「新线是出厂橙」= 给用户可见的状态丢失盖章 | **三条全采纳，全部实测证实**（`AppDBMigrations.swift:57-71,164-184` / `PendingTrainingRepositoryImpl.swift:18-45` / `TrainingSessionCoordinator.swift:56,611-615`）。⚠️ clean-skip 那条尤其难堪：`TrainingSessionCoordinator.swift:55` 的注释里记着**同一形状的旧 bug**（当初漏把 periods 纳入比较），我原地重踩。处置：**D88 整节改写为「持久化 PR 另开 spec」**，并把 R6 挖出的全部实测事实交接过去（补完它需要的是列 / migration / `user_version` / schema-drift 闸门 / clean-skip 判据这一整块持久化切片，与画线交互是不同风险面，塞进本文件一节只会再产出一份接不到盘上的方案——本轮 critical 已演示过一次）；**新增 D89 发布闸**（自动选中 PR 可先合但本片在 持久化 PR 前不算交付完成）；**删掉验收 #23**，验收表加横幅 |

| **R7** | 同分支 @ `5581d94`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**（R6 第三条的窄化重提）：D89 只是散文闸，仍允许 自动选中 PR 先合；若 main 可发布，用户就能改默认→续训→丢掉。处方：把 自动选中 PR 卡在 持久化 PR 之后，或藏进 feature flag | **部分采纳**。**接受**：我上一稿只**断言**「自动选中 PR 可以先合是安全的」、**没写论据** —— 属实。D89 已整节重写，把「零增量」实测摆进去（main 上画线态**恒无选中** ⇒ 改样式本来就走 `setDefaultStyle`；自动选中 PR 新增调用 **0** 次；`defaultStyle` 在持久化层出现 **0** 次），散文闸换成本仓真实的发布机制（不进 freeze tag / 不宣布可用 / 进度 memory 标未完成 / PR 描述横幅）。**驳回**：两个处方都不成比例 —— 合并闸对**零增量**改动的安全收益为 0；feature flag 反而**增加**风险（死路径 + 违反 D19/D24 + 制造无闸门覆盖的构建配置）。§6.8.4 如实记录这处**判断分歧**（remedy 是否成比例），并写明 R7 陈述的**事实**我全部接受 |

| **R8** | 同分支 @ `12a92d7`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high（新论据，不是空重提）**：我 R7 的「零增量」只数了 `setDefaultStyle` 调用次数，**漏了 D86 新增的 `applyStyle`** —— 它经 `updateDrawingStyle` → `drawingsRevision` → autosave **会落盘**。于是 自动选中 PR 之后「线已落盘、默认没落盘」，续训回来线是新色、默认回落出厂、再画一条又是旧色 —— **main 上不存在的半持久化坏状态**，且直接违反 D87 的用户裁决 | **全采纳**，实测证实。R7 那版 D89 的结论及其「remedy 不成比例」的论证**一并作废**（前提没了）。但**没有采纳它给的两个处方**（合并闸 / feature flag），而是用**更便宜也更彻底**的解法：**把两个 PR 的次序倒过来**。依赖方向实测支持倒序 —— `session.defaultStyle` 在 main 上已存在、已被 `applyDefaultStyleMutation` 写，**持久化 PR 不依赖 自动选中 PR、今天就能单独实施**。倒序后：持久化 PR 先合＝净修既有缺口且无耦合；自动选中 PR 后合＝线与默认一起落盘一起恢复，**半持久化中间态结构上不会出现**。另采纳其要求的一致性回归（§6.8.3），并写明该测试**在 持久化 PR 之前必然红** —— 这就是次序不可颠倒的机械证据 |

| **R9** | 同分支 @ `b6b5823`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **high①**：§6.6 与 §10.3 里仍留着「自动选中 PR 不引入不加重 / 可以先合」的旧断言，与 R8 之后的 D89 直接打架，且那是**现行条文**不是评审历史，可被拿来单独 ship 自动选中 PR<br>**high②（新缺陷，我完全没想到）**：D86 画线态是「取默认快照 → 改一项 → **整份**套到线上」。于是：画线 A → 锁定 → 改色（默认变、线被拒 ⇒ 分叉）→ 解锁 → 只改粗细 ⇒ **A 的颜色被静默追认成紫**并落盘。用户只碰了粗细，被改的是他特意锁起来保护过的颜色 | **两条全采纳**。①：两处陈旧断言已改写，并给 §12 的 R5 行补了纠正尾注。②：D86 写入算法改为**同一个 mutation 分别套两个 base** —— 默认的 base 是默认自己，**线的 base 是那条线当前的 5 个样式字段**（新增 `selectedLineStyle`）；§6.4 明写「面板显示什么」与「写线用哪个 base」**不是同一个问题**（上一稿把两者合成一个 `panelStyle` 复用，正是缺陷来源）；新增变异 **M15** + 正向档 **P7** + 真机验收 **#22**（升为第三条硬边界），并写明 M15 的档**必须走完整五步**，少了「锁定→改色被拒」就不会分叉、零判别力 |

| **R10** | 同分支 @ `dd093d3`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：R9 新增的 **M15**（锁定分叉那条最危险的回归）**没被接进强制清单** —— §7.2 的实施要求仍写「M1–M14」、§7.4 平台表也没列它 ⇒ 实施者可以**完整满足写明的变异证据要求、同时把 R9 那条完全不测** | **全采纳**，属实，是我上一轮的漏改。修法**不止是补上编号**：强制清单改成「**§7.2 表格里的每一条 M**」、**刻意不再枚举编号** ⇒ 以后再加多少条都不会脱节（把「同步两处」这个人工动作从结构上消掉）。另加 M15 的两条附加要求（具名 host 测试覆盖完整五步 + 写明少任一步即零判别力）与平台表补列 |

| **R11** | 同分支 @ `eda12dd`（整支 branch-diff，零 focus 窄化） | `needs-attention` | **1 high**：本文件里 **「PR-2」有两个含义** —— 本片的持久化 PR、与 1b-ii 的撤销 PR。于是 §0.4 那句「本片先做、PR-2 后做」（本意指撤销）读起来像在批准「本片先于持久化做」，正是 D89 明令禁止的 | **全采纳**，属实。**编号全部废除**，改用不撞车的名字（持久化 PR / 自动选中 PR / 1b-ii 锁定 PR / 1b-ii 撤销 PR），§0.4 新增**命名表 + 全局次序图**，并标出哪一段次序是强制的、哪一段可换。⚠️ 机械替换时我一度把 §0.4 写成「本片先做、持久化 PR 后做」（次序说反），复核时抓到并手工改正 —— 这本身就是该 finding 为真的额外证据 |

| **自审**（R11 后，非 codex） | 同分支，全文交叉引用一致性机械扫描 | —— | **2 处真问题**：① 验收编号 **21 → 23 跳号**（#22 不存在，R2 删项与 R9 增项各留了一半）② **验收表被空行截断成三张表** —— #21 与 #22 各自渲染成没有表头的独立小表，而这是一张要照着在真机上执行的清单 | 两处已修（重新编号为 1–22 连续、表体接回一张）。⚠️ **这两条 codex 十一轮一次都没提**——机械可判的形态（编号连续性、表格结构完整性）**别指望评审去发现**，要自己写脚本扫 |

**R1 的形状**：我把「要做什么」写全了，却把「在哪做」写在了一个**那些路径到不了**的位置。
这与 [[feedback_internal_review_misses_bad_data]] 记录的形状一致 —— 判据本身没错，错在**没有对着真实控制流核一遍每条出口是否真的流经收口点**。
纪律沉淀：**凡是写「所有 X 都要走 Y」的 spec，必须先把 X 的出口逐条列出来，再逐条核它是否真的到得了 Y**（§3.1 那张出口表就是这条纪律的产物）。

**R2 的形状**：R1 让我把出口列全了，但我只核了「出口 → 收口点」这一段，**没核「用户 → 出口」那一段**。
于是六条出口本期一条都走不到，我却给其中一条写了阻塞级真机验收，还拿它当 §3.2 的可达性论据。
纪律沉淀（补齐 R1 那条的另一半）：**出口表必须带「本期可达性」一列，且逐条给出可达 / 不可达的源码依据**；**不可达的出口不得写成真机验收项**，只能写成不变量锁测试（[[feedback_mutation_must_target_the_exact_predicate]]）。
**R3 的形状**：验收清单里的每一步我都**没有对着既有的门逐步模拟一遍**——#4 锁定之后，下一步的 🗑 早已被 `!d.locked` 关掉了，而我照着「先锁再删」的直觉写了下去。

**R6 的形状 = 同一族的第三次，也是最贵的一次**：我核到**模型层**（`PendingTraining` 有显式 Codable、有 `lossyRaw` 先例）就停了，**没有一路核到真正落盘的那一层**（逐列 DDL + repo 的具名列 SQL）。模型能编码 ≠ 那份编码会被写进数据库。
纪律沉淀（第六条）：**凡涉及「存哪里」，必须一路核到 DDL 与真正执行的那条 SQL**；「这个类型是 Codable」对落盘而言是**零证据**。

**R7 的形状**：不是新缺陷，是**同一条 finding 因为我的修法只有断言、没有论据而被重提**。
**自审的形状**：R9→R10→R11 连着三轮，codex 挖的都是**我自己编辑造成的跨节不一致**。与其再赌一轮评审，不如把「机械可判的一致性」自己扫掉。
纪律沉淀（第十二条）：**长文档每次结构性改动后，跑一遍机械一致性扫描**（章节交叉引用 / 决策编号 / 变异编号 / 验收编号连续性 / 表格结构完整性）。这些形态**评审通常不报**，但会直接伤到照着清单干活的人。

**R11 的形状**：**同一个短名在一份文档里指两个东西**。单看每一句都对，合起来给出了一条相反的许可。
纪律沉淀（第十一条）：**跨切片文档里禁用「PR-1 / PR-2」这类相对编号**——一律用内容命名（「持久化 PR」「撤销 PR」），并在文档开头给一张命名表 + 一张次序图，**标明哪段次序是强制的**。

**R10 的形状**：**加了守卫，却没把它接进强制清单** —— 守卫存在但不生效，和没加一样。
根因是我用**枚举**（「M1–M14」）表达「全部」，于是每加一条都多一个必须手工同步的地方。
纪律沉淀（第十条）：**「全部」不要用枚举表达，要用指向（「表里每一条」）**；凡是「加一条就要记得改另一处」的写法，本身就是缺陷源。

**R9 high② 的形状**（本片第一条**纯设计**缺陷，与「只看了路的一半」不同族）：我为了守住「派生值单一真相」的纪律，让 `panelStyle` 一个函数同时承担了**两件不同的事**——「面板该显示什么」和「改动从哪个值起算」。这两件事在选择态恰好同源，**在画线态必须分开**。复用得太狠，就把一条正确的纪律用成了缺陷。
纪律沉淀（第九条）：**「单一真相」是对同一个问题只留一个答案，不是对两个问题共用一个函数**；合并前先问「这两处求的真的是同一个量吗」。

**R8 的形状 = 同一族的第四次**：这次不是「路只看了一半」，是**耦合只量了一边**。我数了「新增几次 `setDefaultStyle`」（0 次，属实），却没问「自动选中 PR 有没有新增**别的会落盘**的写入，而它和这个不落盘的值是一对」——有，就是 `applyStyle`。
纪律沉淀（第八条）：**证明「零增量」时，必须把新增的写入面整体列一遍，而不是只数被质疑的那一个符号**；两个语义上成对的值，**一个落盘一个不落盘，比两个都不落盘更糟**。

纪律沉淀（第七条）：**凡是在 spec 里写「X 是安全的 / 可以先做」，必须当场附上可核查的论据**（本例 = 「自动选中 PR 新增 `setDefaultStyle` 调用 0 次」这类实测数字）。只写结论不写论据，评审只能反复要它 —— 而每一轮重提**看起来都像没收敛**，实际是我一直没交出证据。

⚠️ **三轮的共同根因是同一个：我论证「这条路存在 / 这一步做得到」时，只看了路的一半。**
R1 = 只核了出口到收口点、没核收口点位置；R2 = 只核了出口到收口点、没核用户到出口；R3 = 只核了动作、没核动作此刻是否被门允许。
纪律沉淀（第三条）：**验收清单每一步都必须对着当前树上的可用性谓词逐步模拟**——上一步改变了什么状态、这一步的按钮此刻是亮是灰。凡是「先设一个保护、再执行被该保护禁止的动作」的相邻两步，一律是错的。
⚠️ 更要命的是这类错误的**方向**：它不是让验收失败，而是**诱导实施者去削弱一道安全门来让清单通过**。

**R4 的形状**（与 R1–R3 不同族）：不是「路只看了一半」，而是**给一个概念起了名字却没定义它的生命期**；补定义时我又**顺着「现状是什么」去定义，而不是顺着「这个名字该是什么」去定义**，于是把 §13 的「该**记录**局部覆盖」误读成了「引擎实例生命期」，还给它盖了「已接受残留」的章。**用现状反推规格，是把缺陷洗成设计的标准路径。**「本局默认」在本片之前只是 `session.defaultStyle` 一个实现细节，本片把它写成用户语义（子项 ②）之后，「它活多久」就成了必须回答的问题，而我一个字没写。
纪律沉淀（第四条）：**spec 每引入或提升一个有状态的概念，必须同时写死它的三件事——谁能写、活多久、什么时候没**。
**R5 medium 的形状**（与 R1–R3 同族的第四次变体）：这次不是「用户到不了那条路」，而是「**测试到不了那条判据**」。我给合取项 ① 配了变异档，却没验过那条档**用我自己提出的 API 能不能写出来**。
纪律沉淀（第五条）：**每条变异档都要当场回答「用哪个入口、拿什么入参构造」**；答不出来的，要么开一条自然的缝（内外分层，不是为测试注入工厂），要么删掉判据别假装它被覆盖了。

⚠️ 同时 R4 那一轮也提醒：**评审给的归因要单独核**（[[feedback_mutation_must_target_the_exact_predicate]]）。本轮 finding 的事实对、归因错（说本片制造了它），若不核就照单全收，会把一块 main 上的既有残留误算进本片的账、并可能因此把一整块持久化契约改动拉进这个 60–90 行的切片。
