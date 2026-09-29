# 划线工具扩充 · P1c 第 3 片 spec：拖节点 + §14 手势分支

- **上游母 spec**：`docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（D1–D22；§6 节点模型、§14 手势编排）
- **上游 P1b 拆分补充**：`docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md`（D23–D43；D32 单指分流）
- **上游 P1c 拆分补充**：`docs/superpowers/specs/2026-08-25-drawing-tools-P1c-split-addendum.md`（D104–D111；本片范围在 §4）
- **上游 P1c 第 1 片 spec**：`docs/superpowers/specs/2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md`（D112–D120）
- **直接前序 · 第 2 片 spec**：`docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md`（D121–D133）
- **本 spec 新增决策编号：D134 起。**

**基线**：`origin/main` @ `25ad1c2a`（2026-09-28，PR #199 合入后）。本文件所有「实测」陈述均在该 commit 上核实，逐条给出 `文件:行`。

> ⚠️ **行号纪律**：第 2 片 spec 的基线是 `b504d630`，此后 main 又走过 `aa5acf3b` / `1e017aa5` / `0f03f796` / `0c9dd75e` / `25ad1c2a`。本 spec 引用的一律是 **`25ad1c2a` 上重新核过的行号**，⛔ 不得回头照抄上游或第 2 片的行号。

---

## 0. 本片是什么

**一句话**：让选中线的节点真的能拖，并把母 spec §14 剩下的那一条手势分支补完。

**本片是 P1c 六片里唯一一片有能力打破 1a-iv 核心成果的**（上游 §4.3-N1 逐字）：1a-iv 花了一整片把「画线模式吞掉平移 / 切周期 / 缩放」这条通路**原子删除**，本片要在同一个手势入口上再开一条分支。因此本 spec 的**核心义务**是 §8-N1：证明「没有可拖节点时，单指 / 双指行为与今天逐字相同」，且这条证明**必须自带判别力**（见 N1 的反假绿自检）。

---

## 1. 决策（D134–D144，含 D134b / D134c / D134d / D140b / D140c）

### D134　分叉发生在手指按下那一刻，判据是「这一点有没有可拖的节点」；⛔ 起手路径上不问线（Q19 的答案）

**顺序定为：只问节点，根本不问线。**

- 单指手势 `.began` 时，仲裁器调用一个**注入的探针闭包**问一句：「这一屏幕点下面有没有一个可拖的节点？」
- 回答「有」→ 本次手势整体路由到**节点拖动**，`.changed / .ended / .cancelled` 全部转发给节点拖动回调；
- 回答「没有」→ **一字不变**走今天的路径（横滑平移 / 竖甩切周期 / 双指缩放，D32）。

**为什么必须在 `.began` 分叉**（实测，`GestureClassifiers.swift:95` `singlePanStep`）：现有方向分类器一旦把手势判成竖直，就 **latch** 成 `.verticalRejected`（`:72`），后续即便累积满足水平分类也不再发平移，且抬手时按 `verticalSwitchThreshold = 40`（`:9`）发切周期。而拖节点主要就是上下拖 ⇒ **等方向分类器判完，节点已经拖不动了**。

**为什么「只问节点、不问线」**（Q19 的实体）：节点在几何上**必然**落在它那条线上（水平线的节点 y ≡ 线的 y）。任何形如「先解析这一点下面最上层是什么」的写法，只要线参与了这次解析，线就恒赢 ⇒ 节点**永远拖不动**，而第 2 片的任何测试都不会变红（Q19 原文）。

**探针必须逐条满足的前置条件**（任一不满足即回答「没有」，fail-closed）：

1. 会话存在且 `mode == .select`（`DrawingSession.swift:41-42`）—— 画线态下点图表是落锚、恒不做命中判定（D38），节点也不存在；
2. **本面板就是 `selectedPanel`** —— 选中是 `(selectedPanel, selectedDrawingID)` **二元组**（D41）。上下两个面板各有一套仲裁器；选中在上面板时，**下面板的探针必须回答「没有」**，否则在下面板按住同一屏幕位置也会拖动上面板的线；
3. **该点没被面板盖住**：`session.shield` 三态按 `handleDrawingTap`（`ChartContainerView.swift:341-345`，三支在 `:342` / `:343` / `:344`）**逐字同判据** —— `.pending` 一律拒、`.rect` 区内拒。⛔ 不得省略：常驻样式面板盖着的地方不该拖得动线，而 `.pending` 那个「面板已挂载、几何未收敛」的窗口期正是 fail-closed 存在的理由；
4. **`DrawingEditRouter.editableIgnoringGeometry(engine:)` 为真**（`DrawingEditRouter.swift:76-84`）；
5. `DrawingNodeGeometry.hitTestNode` 在该点返回非 nil（几何性可见 + 在命中半径内）。

### D134c　`.began` **不是**手指按下那一刻：路由用**重建出来的起手点**，位移用 `translation`

**第 3 轮评审 R1-high 逼出，已在仓内核实为真。**

`UIPanGestureRecognizer` 只有在手指**移动够了**才会 `.began`（UIKit 的 deadzone / slop，是**未公开**的实现细节，量级约 10pt）。⇒ `.began` 回调里的 `location(in:)` **已经不是手指按下的那一点**。

**仓内的直接证据**（不是查文档得来的）：

- `GestureClassifiers.swift:116` 逐字：「R14 finding：UIKit `.began` **可能已带过阈值 translation**」；
- `:101` 逐字：`.began` 锁定水平时「基线设当前累积（**deadzone 不计入**）」—— 既有实现**刻意把这段位移丢掉**，正说明它确实存在且非零。

**为什么这条是 high 而不是边角**：节点命中半径 **11pt**（`DrawingNodeGeometry.swift:19`），deadzone 约 10pt —— **同一个数量级**。⇒ 两个方向都会错：

- 手指**按在节点上**，`.began` 时已滑出 11pt → 探针答「没有」⇒ 用户明明按住了黑点，图表却开始平移（或抬手切了周期）。**这是本片的主功能直接失效**；
- 手指**按在节点外**，`.began` 时滑进 11pt → 探针答「有」⇒ 用户想平移图表，却把线拖走了。

**两条规则，都与 deadzone 的具体数值无关**（⛔ 绝不依赖那个未公开常数）：

| 用途 | 取值 | 为什么 |
|---|---|---|
| ~~**路由**（问探针的那一点）~~ | ~~重建的起手点 = `location - translation`~~ | ⚠️ **本行已被 D140b 取代（第 5 轮评审 R1）**，⛔ 不得再照此实现。重建出来的是**手指按下的屏幕坐标**没错，但把它拿去查**刹车之后**的视口是错的配对：按下到 `.began` 之间惯性仍在移动视口，`settleDeceleration` 本身还会夹回 overscroll 并 propagate 联动（`TrainingEngine.swift:872-876`）⇒ 节点早已不在那个坐标上。⇒ 正确解法是**在真正按下的那一刻就把候选节点捕获下来**，见 D140b |
| **拖动位移** | **`translation(in:)`**，且**直接换算成锚点的增量**（见 D134d），⛔ 不经过任何屏幕投影 | ⛔ **不得**把 `location` 直接当成节点的目标位置。那会在 `.began` 把节点**瞬间吸到手指底下**（丢掉抓取偏移，最大可跳 11pt），而且跳多远取决于 deadzone ⇒ 行为挂在 Apple 的内部常数上 |

⇒ **节点位移 ≡ 手指位移**，起手时用户握住黑点的相对关系全程保持；deadzone 在两条规则里**都被消掉**。

⚠️ 「原锚点」全程就在 `engine.drawings` 里原样不动（D135 的直接好处）⇒ 增量**每帧从当前 mapper 现算**，不需要额外存任何东西。视口在拖动中变化时的交互见 §10-Q26。

### D134d　位移换算**直接在锚点的量纲里做**，⛔ 绝不经过屏幕投影往返

**第 4 轮评审 R1-medium 逼出，已实跑验证。它是 D134c 那条修复带出来的二阶缺陷。**

D134c 上一稿写的是「目标屏幕点 = 原锚点的**投影** + `translation`，再反算回锚点」。**这条走不通**：

- `priceToY` 把结果**对齐到整像素**（`Geometry/Geometry.swift:143-148`），而 `yToPrice`（`:165`）是**不带舍入的线性反算** ⇒ **往返不是恒等**；
- **实跑验证**（⛔ 不推理）：`displayScale = 3`、主图高 401pt、价格区间 `10 … 23.7`，取 200 个合法价位逐个做「投影 → 反算」，**最大偏差 0.0057**（约半个像素对应的价位）；单点例子 `15.123456 → 15.124688…`，**`==` 为 false**。

⇒ 按上一稿实现会有两个静默后果：

1. **纯横拖会悄悄改掉价位**（`translation.y == 0` 也不恒等）；
2. **拖出去再拖回原处不恢复原值** ⇒ D136 的门 ⑥（内容未变 → 零副作用）**永远触发不了** ⇒ 每一次「拖走又拖回」都写一次盘，并把**深度 1** 的撤销栈里那条真编辑**挤掉**。

**改为：两个轴都直接算锚点的增量，全程不碰屏幕投影。**

| 轴 | 公式 | 零位移时 |
|---|---|---|
| 价位 | `priceDelta = -translation.y × (priceRange.max - priceRange.min) / mainChartFrame.height`；`newPrice = old.price + priceDelta` | `translation.y == 0` ⇒ `priceDelta == 0` ⇒ `newPrice == old.price`，**逐位相等** |
| K 线下标 | `indexDelta = Int((translation.x / geometry.candleStep).rounded(.toNearestOrAwayFromZero))`；`newIndex = old.candleIndex + indexDelta` | `translation.x == 0` ⇒ `indexDelta == 0` ⇒ `newIndex == old.candleIndex`，**恒等** |

**逐条注意**：

- **符号**：`priceToY` 里 `y` 随价位**递减**（`raw = maxY - ratio × height`）⇒ `priceDelta` 前面那个负号是**必须的**，⛔ 写掉它会让线朝反方向跑；
- **`candleStep > 0` 守卫**：`candleStep == 0`（空图表）会让除法产出 `inf/NaN`，`Int(NaN)` 直接**崩**。既有的 `handleDrawingTap` 已有同款守卫（`ChartContainerView.swift:337`，另有 `:279` / `:295` 两处同款），本片照抄；
- **`newIndex` 用 `addingReportingOverflow`**：`candleIndex` 从磁盘解码时**零范围校验**，`Int.min` 的锚点是能存在的（第 2 片 `DrawingNodeGeometry.swift:56-63` 就为此加过溢出保护）。溢出 ⇒ 直接夹到可见窗口边界（fail-closed），⛔ 不得让它 trap；
- **`candleIndex` 是整数、量化到整根 K 线是固有的** —— 「节点位移 ≡ 手指位移」这条性质在纵轴上精确成立，在横轴上按整根 K 线量化。⛔ 这**不是**缺陷，是 `DrawingAnchor` 的数据形状决定的；
- 夹取（D137）在这两个增量**算完之后**施加，顺序不得调换。

### D134b　探针的非几何前置条件 ≡ 引擎新接口的非几何门，且**靠复用同一个函数**保证，⛔ 不靠两处同步

**这是第 2 轮评审 R1-medium 逼出的修正，而且它与 D139 是同一族缺陷 —— 我在 D139 里替 `locked` 一条禁掉了「能拖、松手被拒」，却没有按判据本身穷尽整族。**

**症状**（评审原文核实为真）：一条带**未来顶层字段**的水平线、或一条**全局 id 重复**（一条可见一条隐藏）的线，在上一稿的探针下**会进入拖动并实时跟手**，而松手时必被引擎的门 ①/③ 拒 ⇒ 瞬时覆盖一清，**线当场弹回原处、用户的调整全部丢失**。这与 D139 明令禁止的坏体验**逐字相同**。

**修法不是把漏掉的几条补进探针的清单** —— 那只是把「两份清单」从差 4 项变成差 0 项，下一次仍会漂。**改为复用引擎侧那份唯一真相**：

`DrawingEditRouter.editableIgnoringGeometry(engine:)`（`:76-84`）的七个分量与 D136 的门 **⓪①②②b③ 逐条相等**：

| 该函数的分量 | 对应 D136 的门 |
|---|---|
| `flow.mode != .review` | ⓪ |
| `uniqueSelected != nil`（**可见域**唯一 + 结构性可见） | 选中生命期前提 |
| `idIsGloballyUnique` | ①（**全局**唯一，与上一行**刻意分开**，见该文件 `:64-70` 头注） |
| `!locked` | ② |
| `isEditableToolType` | ②b |
| `!hasKnownFutureEnumValues` + `!hasKnownFutureFields` | ③ |

⇒ **探针直接调它**，`private` 改 `internal` 即可（⛔ 不改它的函数体、不加参数）。该函数被抽出来的理由（`DrawingEditRouter.swift:72-74` 头注逐字）就是「让两条路径**只在几何这一点上不同**；若各写一份，早晚有一天两边的非几何分量会漂移」—— 本片是第**三**条消费它的路径，理由原样适用。

**引擎侧剩下的三道门为什么可以不进探针**（逐条给理由，⛔ 不笼统说「兜底」）：

| 门 | 为什么探针不问 |
|---|---|
| ④ `anchorIndex` 在范围内 | **构造保证**：探针的返回值就是 `hitTestNode` 给的原下标，它来自 `marks()` 对 `anchors` 的 `enumerated()`（`DrawingNodeGeometry.swift:39-41`）⇒ 恒在范围内。引擎侧保留它是**防越界 trap**（Swift 数组越界是进程崩、`do/catch` 接不住），不是防用户 |
| ⑤ `anchor.period == old.period` | **构造保证 + 事件兜底**：夹取函数拿的就是本面板当前周期；周期一变就整个作废（D138）。引擎侧保留它是防「构造保证日后被改坏」 |
| ⑥ 内容未变 | **不是拒收门**，是零副作用短路。拖回原处是合法操作，探针当然要放行 |

⇒ **不变量**：「探针放行 ⇒ 引擎的**非几何**门必然全过」。⛔ 唯一允许的松手失败是**几何**原因（那一类由 D137 的夹取在结构上消灭）。
⇒ 违反它的症状恒为「拖得动、松手弹回」，而 §8-N6 那一族测试就是照这条不变量写的。

**拖动全程与结束后选中都保持不变** —— 拖动不改变选中，用户抬手后仍可直接点 ↩ / 🔒 / 🗑。

⇒ **不变量（可机械验证）**：**单指 pan 的起手路径上不得出现 `DrawingHitTester`**。探针实现所在的函数体内不得引用该类型 —— 这是一条源码守卫（§8-G2），它把「顺序写反」这件事变成**结构上不可表达**，而不是靠实施者记得顺序。

### D135　拖动过程中**不碰** `engine.drawings`；几何走一份瞬时覆盖

**实测理由（这是一条 load-bearing 的事实，不是偏好）**：`engine.drawingsRevision` 每 `+1` 就触发一次 `lifecycle.autosave(immediate: true)`（`UI/TrainingView.swift:49-50`）。拖动逐帧写正式数组 ⇒ **每秒约 60 次立即写盘**。

改为：

1. `DrawingSession` 新增一份**瞬时拖动态** `nodeDrag`（与既有 `pendingAnchors`（`Drawing/DrawingSession.swift:148`）同族：瞬时、**绝不落盘**、退出画线即清）；
2. 渲染与命中的**唯一真相** `RenderStateBuilder.visibleDrawings`（`Render/RenderStateBuilder.swift:84`）在产出列表时，把正在被拖的那一条**替换成拖动中的样子**（返回值里的副本，⛔ 不改 `engine.drawings`）。落在这一处而不是只落渲染路径，是为了让 D40「命中集合 ≡ 渲染集合」在拖动的**每一个瞬间**都字面成立；
3. **抬手 / 被接管**时才调新写入接口**一次**。

⇒ **「一次拖动 = 一条撤销记录」由构造保证**（全程只写了一次），而不是靠收尾函数记得入栈。

**`nodeDrag` 必须 `@ObservationIgnored`**，理由与 `DrawingSession.swift:57-59` 的 `viewportMappers` 逐字相同：拖动期间每帧都写，若参与 observation 会造成「写 → SwiftUI 失效 → 再 `updateUIView` → 再写」的循环。重绘改由拖动回调**每帧显式重建渲染态**（`ChartContainerView.Coordinator.rebuildRenderState`，`:174`）——这条 Coordinator 直连路径是本仓既有范式（落锚就是这么做的，`:325` 起）。

**`nodeDrag` 的字段只有四个**：`drawingID` / `panel` / `anchorIndex` / `current`（当前拖到的、**已夹取**的锚点）。
⛔ **不存「拖动前的原锚点」** —— 它就在 `engine.drawings` 里原样不动（D135 第 1 条的直接后果）。多存一份等于给自己造一个会漂移的副本。

### D136　引擎第 5 个 `drawings` 写入面：`updateDrawingAnchor(id:anchorIndex:anchor:)`

```
@discardableResult
func updateDrawingAnchor(id: DrawingID, anchorIndex: Int, anchor: DrawingAnchor) -> Bool
```

**门列表**（逐条对照既有写入面重新论证，⛔ 不照抄）：

| # | 门 | 取自 | 为什么本接口要（或不要） |
|---|---|---|---|
| ⓪ | `flow.mode != .review` | D34 纵深，同 `updateDrawingStyle:1183` / `deleteDrawing(id:):1133` | 复盘里 `drawings` 是已归档 record 的原训练线，拖它不可逆 |
| ① | `!id.isEmpty` + 全局**恰好**一条 | D66 | 同上两接口；≥2 条是坏状态，绝不「改第一条碰到的」 |
| ② | `!old.locked` | D60 | N6。⚠️ 这是**第二层**，第一层在探针（D139） |
| ②b | `DrawingStyleAvailability.isEditableToolType` | `updateDrawingStyle` 的 ②b | **要**。本构建不懂其样式语义的工具，同样不懂它的锚点语义（几个锚、哪个锚承重）——高版本写的 `.trend` 解码后一切「正常」，没这道门会被按横线假设改锚 |
| ③ | `!hasKnownFutureEnumValues` + `!hasKnownFutureFields` | D61 | **要**。改锚点是「部分改写」，与删整条性质不同（删除面不查这两道门正是因为它不产生部分抹除） |
| ④ | `drawings[i].anchors.indices.contains(anchorIndex)` | **本接口新增** | Swift 数组越界是 trap（进程崩），`do/catch` 接不住。⚠️ 同时是 Q24 的**部分**兜底（见 §11） |
| ⑤ | `anchor.period == old.period` | D29 周期绑定 + N8 | 引擎侧兜底。混周期锚点 = 后续所有 `candleIndex` 被按错误周期解释的坏数据 |
| ⑥ | **内容未变**（`updated == old`）→ 返 `true` 且**零副作用**（不写数组、不入栈、`drawingsRevision` **不**递增）。⚠️ **内容变了则必须走完整的写入路径**，⛔ 不得短路 | D80 | 拖回原处再松手不得触发一次无谓写盘，更不得把撤销栈里那条真编辑挤掉 |

**⛔ 本接口不含、也不声称含几何门。** 引擎没有 `mapper`（`deleteDrawing(id:)` 的头注逐字：「引擎判不了几何、也不声称挡几何」）。夹回边界（D137）发生在界面层，本接口只守它守得住的那几道。

> ⚠️ **门 ⑥ 的条件方向**（本 spec 第 1 轮评审 R1-medium 修正）：生产范式是 `guard updated != old else { return true }`（`TrainingEngine.swift:1212`）—— 即**短路的条件是「相等」**。写反成「不相等就短路」会**恰好覆盖所有真正改变锚点的拖动**：松手报告成功却什么都没写，瞬时覆盖一清，线**当场弹回原处**；而真正该短路的「拖回原处」反倒去写了一次。⛔ 这条方向必须由 §8-**T7b** 的**两档**分别钉死，不得只测一档。

**成功路径**照四个既有写入面的范式：`drawings[i] = updated` → `recordDrawingUndoDelta(.replaced(before:after:at:))`（`TrainingEngine.swift:1554`）→ `drawingsRevision += 1`。
**构造 `updated` 时逐字段拷贝**，只换 `anchors`。⚠️ `isExtended` 由 `lineSubType` 派生、**不由锚点派生**（`Models.swift:260` / `:320-322`），故拷贝即可；`period` 显式传 `old.period`（⛔ 不让 `init` 从 `anchors.first` 现取——那会让门 ⑤ 变成摆设）。

⚠️ **相邻守卫必须复跑**：`setDrawingLocked` 那条「非拷贝直传的 `locked:` 写入恰好 1 处」的 L12 守卫。本接口写的是 `locked: old.locked`（拷贝直传），**预期不计入**——但这是**预期，不是事实**，plan 必须实跑确认。

### D137　Q3 的答案：**夹回边界**（拒绝的是「拖出去」，不是「这次拖动」）

- **上下**：价位夹进当前视口的 `priceRange`；
- **左右**：`candleIndex` 夹进当前可见窗口 `[startIndex, startIndex + visibleCount - 1]`。

**为什么不是「松手作废回弹」**（user 2026-09-28 拍板）：夹取让「拖出一条 `visibleGeometry == nil` 的幽灵线」**结构上不可能**，而不是靠又一道守卫去拦；拖动全程线一直看得见、连续可预测；且不需要维护第二条「作废回弹」的状态路径（本仓纪律：新增一层状态自带三个新失效点）。

**代价**：想把线放到比当前屏幕更高的价位，得先缩放 / 平移把那个价位转进屏幕。⚠️ 这与今天「点一下落锚」只能落在图内**完全一致**，不是新限制。

**⛔⛔ 夹取的判据是「夹完之后 `visibleGeometry != nil`」这个**后置条件**，⛔ 不是「落进可见窗口」**（第 1 轮评审探索轨迹逼出，本 spec 自核确认）：

`.ray` 的右缘是**严格 fail-closed** 的 —— `anchorX >= frame.maxX` 即整条线返回 nil（`HorizontalLineTool.swift:57-58`，注释逐字：「落点在右缘【上或外】→ 零长度/不可见段」）。
而 `indexToX(startIndex + visibleCount - 1)`（可见窗口的**最后一根** K 线）**完全可能恰好落在 `frame.maxX` 上或之外** —— 它等于 `(visibleCount - 1) × candleStep + pixelShift`，与 `mainChartFrame.maxX` 之间**没有任何不变量保证**大小关系。

⇒ 「把 `candleIndex` 夹进 `[startIndex, startIndex + visibleCount - 1]`」这条朴素写法，对 `.ray` **会造出恰恰要禁止的幽灵线**：节点贴着右边框、线却整条消失、随后既看不见也选不中。

**因此本 spec 钉死的是后置条件，不是公式**：

1. 夹取函数的**后置条件**是「对**该条线的实际子类型**，`HorizontalLineTool.visibleGeometry(for:mapper:) != nil`」；
2. 实现必须**逐子类型**验证该后置条件（`.straight` / `.ray` 各一档；`.segment` 恒不可渲染 ⇒ 在探针层就该被 `isVisible` 挡住，根本进不来拖动）；
3. ⛔ **不得**假设「夹进可见窗口」就够了 —— 这正是本条要禁止的那个朴素写法。

⚠️ §8-N7 的判据（真调一次 `visibleGeometry` 断言非 nil）与本条是**同一件事的两面**：本条规定实现的义务，N7 规定证据的形状。**两者必须都在**，缺任何一个这条都会静默失守。

**⛔ 夹取是界面层的一个独立纯函数**（与 `DrawingNodeGeometry` 并排，仅依赖 CoreGraphics ⇒ host `swift test` 全覆盖），签名形如
`clampedAnchor(at point: CGPoint, mapper: CoordinateMapper, period: Period) -> DrawingAnchor`。

**⚠️ 边界上的四舍五入是本片最容易静默失败的一处**：`priceToY`（`Geometry/Geometry.swift:143`）与 `indexToX`（`:138`）都把结果**对齐到整像素**。把价位夹到 `priceRange` 端点之后再映回屏幕，可能差半个像素落到 `mainChartFrame` 之外 ⇒ 线又整条不可见。
⇒ **判据必须是「真的调一次 `HorizontalLineTool.visibleGeometry` 断言它非 nil」**，⛔ 不得写成「断言价位落在区间内」——后者在四舍五入发生**之前**，证明不了任何事。

### D138　拖到一半被打断，按「打断源」三分

| 打断源 | 处置 | 为什么 |
|---|---|---|
| **第二根手指落下**（要缩放 / 两指平移） | **就地定住**：走与抬手**同一条**收尾路径，写一次、记一条撤销 | user 2026-09-28 拍板。不丢用户刚调好的位置；不满意还能点 ↩。且「抬手」与「被接管」共用一条收尾路径 ⇒ 少一条可能出错的路 |
| **周期变了** | **作废**：丢弃 `nodeDrag`，`drawings` 一个字节不改，撤销栈无新记录 | 与上一条**刻意不同**。就地定住在这里**不安全**：新周期下写进去的锚点周期与线对不上，正是 N8 禁止的混周期坏数据。落点复用既有的周期善后单点 `restoreDrawingSessionAfterPeriodChange`（`TrainingEngine.swift:447`），⛔ 不另写一份取消语义（D31 同款纪律） |
| **转屏 / 视口变了但周期没变** | **继续拖**，用**新**视口重算（夹取边界也用新的） | 视口变化不产生坏数据；打断它反而会让用户在转屏后莫名其妙丢掉一次拖动 |

**⚠️ 作废之后本次手势的余下部分怎么走**：仲裁器的路由 latch **保持在「节点拖动」不变**，后续 `.changed / .ended` 一律被界面层忽略（因为 `nodeDrag` 已是 nil）。⛔ **不得**回落成图表平移 —— 那会让「周期刚切完、手指还没抬」变成一次用户没要的平移。

### D139　锁定的线：**照常显示节点**，但探针对它回答「没有可拖节点」

- 节点是**「我选中了这条」**的视觉反馈（D108 取消变蓝之后它是唯一的图内反馈），不是「我能拖」的反馈 ⇒ 锁定的线选中后节点照画（`DrawingNodeGeometry.marks` 不看 `locked`，`:39-41`，本片**不改**）；
- 但探针对锁定的线返回「没有」⇒ 按住它照常平移图表。

**⛔ 不得做成「能进拖动、松手被引擎拒」**：那样用户会看到线跟着手指走、一松手又弹回原处——比「拖不动」糟得多。D136 的门 ② 是**第二层**兜底，不是第一层。

⚠️ **本条只是 D134b 那条不变量的一个实例**（第 2 轮评审 R1 的教训）：`locked` 不特殊，**引擎所有不需要 mapper 就能判的拒收门**都必须在探针里先答「没有」。⛔ 不得再按单条补 —— 按 D134b 复用同一个函数。

### D140　路由到拖动之后才「刹车」，顺序与落锚逐字相同

单指 `.began` **若已路由到节点拖动**，界面层必须按 **① `settleDeceleration` → ② `rebuildRenderState` → ③ 读 viewport → ④ 建 `CoordinateMapper`** 的顺序走，与 `handleDrawingTap`（`Render/ChartContainerView.swift:325` 起，`:333` 是 settle）**逐字相同**。这一步是为**拖动本身**准备一个稳定视口。

**为什么**：图表可能正在惯性滑动。在滑动中拖节点，视口会在手指底下继续移动 ⇒ 每帧换算出来的增量会漂。这与 1a-iv 修 `handleDrawingTap` 时的理由是同一条（那里已有源码顺序守卫 `drawingTapSettlesBeforeMapping`，`DrawingGestureSourceGuardTests.swift:62-63`）。本片给拖节点配一条同款（§8-G3）。

⛔ **探针不在这里跑**（上一稿写反了，第 5 轮评审 R1）——见 D140b。

### D140b　候选节点在**手指真正按下那一刻**捕获，⛔ 不在 `.began` 用刹车后的视口现查

**第 5 轮评审 R1-medium 逼出。它是 D134c 那条修复的二阶缺口：起手**坐标**重建对了，配对的**视口**却是错的那一帧。**

**已核实的两条视口移动**（按下 → `.began` 之间都会发生）：

1. **惯性仍在跑**：`beginPan` 才「先停本面板进行中的减速」（`TrainingEngine.swift:890` 注释逐字「标准惯性滚动语义：手指落下即截住惯性」），而它挂在 `.began` 上 —— **`.began` 比手指落下晚一个 deadzone**（D134c）；
2. **刹车本身会再移一次**：`settleDeceleration`（`:872-876`）对**两个**面板 `interruptDeceleration`（夹回 overscroll），再 `propagateLinkage`。函数头注自陈它会「把上面板的 offset 改掉 —— 图当场跳一下」。

⇒ 「按下时的屏幕坐标」× 「刹车后的视口」是**错配**：用户按住的节点可能早已移出 11pt，或者另一个节点刚好移进来。

**改为：在真正的触摸按下那一刻捕获候选。**

| 时刻 | 做什么 | 硬约束 |
|---|---|---|
| **`touchesBegan`（单指、且此刻没有在途候选）** | 用 **`view.renderState.viewport`**（= 屏幕上**正在显示**的那一帧，就是用户看着按下去的那一帧）建 mapper → 跑探针 → 记下候选 `(drawingID, anchorIndex)` + 按下点 | ⛔⛔ **零 engine 写入**：不 `settleDeceleration`、不 `rebuildRenderState`、不改任何状态，**纯只读**。理由见下 |
| **pan `.began`** | 路由**完全由候选决定**，⛔ **不重新做任何几何命中**。路由到拖动后才走 D140 的四步 | 路由前对候选做一次 **fail-closed 复核**：那条线仍在、`editableIgnoringGeometry` 仍为真。⛔ **复核不含几何命中**（那正是本决策要避免的重查） |
| **新的单指 `touchesBegan`** | **直接覆盖**旧候选（重新捕获） | 见 D140c |
| **`touchesBegan` 时同时有 ≥2 个触摸** | 清候选 | fail-closed |
| **拖动手势走到终止相位**（`.ended` / `.cancelled`），或 `.began` 路由完毕 | 候选被消费 / 清掉 | — |

**⛔ 为什么 `touchesBegan` 里绝不能顺手刹车**（这条是 load-bearing 的）：今天惯性要到 `.began` 才被 `beginPan` 截住。在 `touchesBegan` 里刹车会让**每一次触摸**（包括纯平移、纯点击）都提前截停惯性 —— 那是对 D32 既有行为的**改动**，直接违反 N1「没有可拖节点时行为逐字不变」。本片**只读**那一帧，不碰它。

**落点**：`KLineView` 新增一个回调钩子（与既有的 `onBoundsChange`（`Render/KLineView.swift:31`）**同一范式**），由 `touchesBegan` 在**单点**触摸时触发。⚠️ 手势识别器与视图**并行**收触摸，`touchesBegan` 照常被调用（`delaysTouchesBegan` 默认 false）。

**⚠️ 仍然存在、且本 spec 明确接受的误差**：`view.renderState` 是**上一帧**渲染的结果，惯性快速滑动时它与手指落下那一瞬的画面最多差**一帧**。⛔ 不得声称「精确」。这是 UIKit 触摸模型下的下界（我们拿不到「正在显示的这一帧」之外的东西），且它替代的是一个**最多差一个 deadzone + 一次 overscroll 夹取**的误差 —— 数量级小一到两个档。**如实登记，不粉饰。**

### D140c　⛔ 「视图收到触摸被取消」**不等于**「手指抬起了」：候选的清除时机只有三个，且都不含它

**第 6 轮评审 R1-high 逼出。三条前提已在仓内逐条核实为真。**

上一稿写「`touchesEnded` / `touchesCancelled` → 清候选」。**这条前提本身是错的。**

**核实到的三件事**：

1. 仓内**一处都没有**设过 `cancelsTouchesInView`（全仓 grep 为空）⇒ `attach` 装的五个识别器全取 UIKit 默认值 **`true`**；
2. 长按识别器照常创建（`ChartGestureArbiter.swift:96`），且委托明确**允许它与 pan 同时识别**（`:231` + `if hasLongPress && hasPan { return true }`）；
3. 画线模式下长按的**业务回调**确实早退（`Render/ChartContainerView.swift:140`），但**识别器照常识别** —— 而「取消视图触摸」是识别器**识别时**由 UIKit 发出的，与业务回调走不走**无关**。

⇒ 用户**按住黑点、停半秒、再拖**（这恰恰是拖节点最自然的手法）：长按识别 → 视图先收到 `touchesCancelled` → 候选被清 → pan `.began` 无候选 ⇒ **图表开始平移，线纹丝不动**。**主功能缺口，按上一稿实现必然触发。**

**⚠️ 而且比评审报的更宽**（本 spec 自核补充）：**pan 识别器自己**的 `cancelsTouchesInView` 同样是 `true` ⇒ 即便快速按下就拖、长按根本没识别，pan 识别成功时**照样**会给视图发 `touchesCancelled`，且它与 `.began` 的先后**没有保证**。
⇒ 问题**不是**「长按这一种情况要特判」，而是**「把视图的触摸取消当成手指抬起」这个前提整体不成立**。⛔ 任何形如「除了长按之外都算结束」的补丁都是错的。

**改为：候选的清除时机只有上表那三个，一律不看 `touchesEnded` / `touchesCancelled`。**

**为什么这样就够**（不留陈旧候选）：**每一次新的单指按下都重新捕获并覆盖**。⇒ 一个没被消费的候选，最晚在下一次触摸按下时就被换掉，**结构上泄不到下一个手势里**。这不是「记得清」，是「不可能不清」。

**⛔ 明确不采用的两条路**（各给理由）：

- **把识别器的 `cancelsTouchesInView` 改成 `false`** —— 那会改变**所有**既有手势对视图触摸的影响面，直接撞 N1「没有可拖节点时行为逐字不变」；
- **给拖节点单挂一个识别器** —— 本仓有实测记录证明给单指拖动加识别器优先级关系会**毁掉图表主交互的滚动响应性**（`ChartGestureArbiter.swift:104-107` 注释逐字记录的 R9 finding-2），且现有五个识别器的仲裁已经很精细。**user 2026-09-29 拍板：继续修现方案。**

### D141　撤销粒度：不动 `performDrawingAction`

既有的一次动作作用域 `performDrawingAction`（`TrainingEngine.swift:1515`）**不适用**且**不改**：

- 它规定作用域内只允许**一次** `drawings` 改动，第二次到达即 fail-closed 作废（`:1559`）；
- 它是**同步**的 `{ body }`，而拖动跨多次异步回调，语法上也套不进去。

D135 已经让拖动全程只写一次 ⇒ 撤销记录天然是一条，**不需要任何新机制**。
⛔ **不得**为了本片去放宽那条 fail-closed —— 那是 D102 刻意设的。

### D142　母 spec §14 的「触发放大镜 / 吸附」这半句**明确推迟到 P4**

母 spec §14 原文：「单指拖在节点上：移节点（新增；起手命中某选中线的节点 → 进入节点拖动，**触发放大镜/吸附，§9**）」。上游 §4.2 已把「局部放大镜与吸附」划归 P4。
⇒ 本片**只做进入节点拖动**，括号里那半句**不做**。在此显式登记，防止评审把它当成漏实现。

### D143　交互稿 SVG 的蓝外圈节点（Q23）：本片自查通过，照文字规格

交互稿 `.anchorSel` 类仍画着蓝外圈（第 2 片 Q23）。本片一切节点外观**沿用第 2 片已落地的实现**（纯黑实心圆 / 夜间纯白，`visualDiameter = 7`，`DrawingNodeGeometry.swift:15`），⛔ 不照图、不新增任何节点外观。本片**不碰**节点渲染。

### D144　本片**不 bump** `CONTRACT_VERSION`

不新增 `DrawingObject` 字段、不扩展任何枚举值域、不改任何已有 key 的含义。改锚点写的是**既有的** `anchors` 数组列，形态与画线时落进去的完全一致。依据同上游 §11.1 表中「1B、2–6 片不变」一行。

---

## 2. 本 spec 核实过的事实（`25ad1c2a`，逐条 `文件:行`）

### 2.1 手势侧

| 事实 | 位置 |
|---|---|
| 单指方向分流全在纯函数 `singlePanStep` | `ChartEngine/GestureClassifiers.swift:95` |
| 竖直一旦判定即 **latch** `.verticalRejected`，后续不再发平移 | `:72` + `:95` 的头注 |
| 竖滑切周期阈值 40pt，且**只在 `.ended` 且未被 cancel 时**发 | `:9` / `:146` |
| 仲裁器单指 handler | `ChartEngine/ChartGestureArbiter.swift:157` |
| 两指起手会确定性接管并同步关闭单指（`singlePanSupersede`） | `:123` + `GestureClassifiers.swift:158` |
| **既有守卫**：`handleSinglePan` 函数体内**不得出现 `drawingMode`** | `Tests/.../ChartEngine/DrawingGestureSourceGuardTests.swift:46-47` |
| **既有守卫**：`GestureClassifiers` 里不得出现 `drawingTakesOver` / `DrawingModePanPolicy` / `panPolicyInDrawingMode` | 同上 `:37-38` |

⇒ **D134 的探针形状受这两条守卫约束**：探针闭包**不认识**「画线模式」这个概念，只回答「这一点有没有可拖节点」。没有会话 / 没有选中时它必然回答「没有」⇒ 两条守卫继续绿，且**仍有判别力**（它们钉的是「不得按模式无条件截获」，本片没有引入这种通路）。

### 2.2 数据与撤销侧

| 事实 | 位置 |
|---|---|
| `drawings` 的四个既有写入面 | `TrainingEngine.swift:1133` / `:1155` / `:1183` / `:1230`（另有 `:1110` 的下标删除、`:1713` 的测试换血口） |
| 入栈单点，必须紧贴 `drawingsRevision += 1` | `:1554` |
| 撤销栈**深度 1** | `:1554-1568` |
| U-G4 穷尽性守卫的权威表，合计**钉死 10** | `Tests/.../Drawing/DrawingUndoSourceGuardTests.swift:288-316`（总数断言在 `:315`） |
| `drawingsRevision += 1` ⇒ **立即写盘** | `UI/TrainingView.swift:49-50` |
| 周期善后单点 | `TrainingEngine.swift:447`（既有守卫钉死它只用 `discardPendingAnchors()`，`DrawingGestureSourceGuardTests.swift:84`） |

### 2.3 几何侧

| 事实 | 位置 |
|---|---|
| 逆映射现成：`yToPrice` / `xToIndex` | `Geometry/Geometry.swift:165` / `:153` |
| 正映射**对齐整像素** | `:138`（`indexToX`）/ `:143`（`priceToY`） |
| 线的可见判据（render / hitTest / isVisible 三者共用） | `Drawing/HorizontalLineTool.swift:72`（`visibleGeometry`）/ `:103` / `:109` |
| 线容差 8pt、节点命中半径 11pt、节点视觉直径 7pt | `HorizontalLineTool.swift:24` / `DrawingNodeGeometry.swift:19` / `:15` |
| 节点命中返回**原 anchors 下标** | `DrawingNodeGeometry.swift:98-107` |
| 渲染 / 命中的唯一真相 | `Render/RenderStateBuilder.swift:84` |
| 水平线 `requiredAnchors == 1...1` | `HorizontalLineTool.swift:13` |

### 2.4 ⭐ 本 spec 挖清的新事实：Q25 的下标语义（第 2 片未核实，交接本片）

第 2 片 Q25 的**阻塞前提**是：`MarkersLayout.findCandleIndex` 用的是**切片内下标**还是**全局下标**？若是切片内下标，它与锚点的全局 `candleIndex` 就不在同一个坐标空间，「标记盖住节点」的像素证据无从构造。

**核实结果：是全局下标，两者同一个坐标空间。** 三步举证：

1. 喂给标记布局的那段 K 线是 `candles[viewport.startIndex ..< startIndex + visibleCount]`（`Render/RenderStateBuilder.swift:36`），源码注释自陈 `slice.startIndex == viewport.startIndex`（`:34`）——即**保留原数组下标**的 `ArraySlice`；
2. `findCandleIndex`（`Render/MarkersLayout.swift:23`）用的 `partitioningIndex`（`Models/BinarySearch.swift:12`）在实现上从 `startIndex` 二分到 `endIndex`，返回的就是**该集合自己的 Index**；
3. **实跑验证**（⛔ 不靠推理，本仓纪律）：`swift` 直接跑一段最小样本——`Array(0..<100)` 切出 `[80..<90]`，`slice.startIndex == 80`，查「首个 ≥ 85」返回 **85**（不是 5）。

⇒ `mapper.indexToX(idx)`（`MarkersLayout.swift:39`）与节点的 `mapper.indexToX(anchor.candleIndex)` **同一个 x**。
⇒ 成交标记（实心圆，**半径 5**、直径 10pt，`Render/KLineView+Markers.swift:30`）比节点（直径 **7pt**）大，**盖得住**。第 2 片 T13 的源码顺序守卫守的是真问题，且**像素证据在本片构造得出来**（§8-T5）。

---

## 3. 本片做什么

1. **§14 的节点拖动分支**（D134）：单指 `.began` 落在选中线的某个节点上 → 进入节点拖动；否则一字不变走 D32 的方向分流。
2. **拖动实时跟随**（D135）：拖动中该线几何实时更新，**不碰** `engine.drawings`、**不写盘**。
3. **锚点双轴跟随**（user 2026-09-28 拍板）：价位与 `candleIndex` 都跟手指走，与第 4 片起的多锚工具**同一套语义**。
4. **引擎第 5 个写入面**（D136）+ U-G4 穷尽性守卫同步 10 → 11（N5）。
4c. **`KLineView` 新增一个触摸按下的回调钩子**（D140b）——与既有 `onBoundsChange`（`KLineView.swift:31`）同一范式；⛔ 钩子里**零 engine 写入**。
4b. **`DrawingEditRouter.editableIgnoringGeometry` 的访问级别 `private` → `internal`**（D134b）——⛔ **只改访问级别，不改函数体、不加参数、不改任何分量**。这是本片对 `DrawingEditRouter.swift` 的**唯一**改动，理由见 D134b。
5. **夹回边界**（D137）：一个 host 可测的纯函数 + 「夹完必须仍可见」的硬断言。
6. **一次拖动 = 一条撤销记录**（D141，构造保证）。
7. **Q25 的像素证据**（§2.4 + §8-T5）：补第 2 片欠下的那一条。

---

## 4. 本片不做

局部放大镜与吸附（母 spec §9，属 P4；D142 显式登记）；折线删单节点（第 6 片）；四个新工具；**节点选中态**（「某一个节点 vs 其它节点」的区分，第 6 片，且不得复活 `selectionRGBA`，第 2 片 Q20）；拖**线本身**（按住线平移整条——上游 §4.1 没有这一项，⛔ 不得顺手加）；节点外观的任何改动（D143）；`CONTRACT_VERSION` bump（D144）。

---

## 5. 上游 Q3 的答案（索引）

**夹回边界。** 见 **D137**（含「为什么不是作废回弹」与四舍五入陷阱）与 **§8-N7**（判据必须真调 `visibleGeometry`）。

## 6. 第 2 片 Q19 的答案（索引）

**只问节点，起手路径上根本不问线。** 见 **D134**（含结构不变量）与 **§8-T1 / §8-G2**（判别力只能靠变异 + 源码守卫证明）。

---

## 7. 契约 / 闸门 / 交付

### 7.1 契约

`CONTRACT_VERSION` **不变**，`user_version` **不变（8）**，**无迁移**。依据见 D144。

### 7.2 三绿门（作者亲核，clean build）

本片**必然含 UIKit-guarded 测试**（T5 像素证据 + 手势接线）⇒ 按上游 §11.2：**Catalyst 必须 `xcodebuild test`（真执行）**，不是 `build-for-testing`。

- host：`swift test`（⚠️ 数编译错误前先剥 ANSI 颜色码：`sed 's/\x1b\[[0-9;]*m//g'`，否则「有错误」会被数成 0）；
- Catalyst：scheme **`KlineTrainerContracts-Package`**，在 **`ios/Contracts`** 目录下跑（CI 同款）；
- `catalyst-gate.sh`。

**⚠️ 新增 UIKit-gated 用例必须同步四处**（漏一份 = 本地全绿、CI 才红）：
① `.github/scripts/catalyst-uikit-baseline.txt`（现 **80 行**，⛔ 必须用 `.github/scripts/uikit-expected-tests.py` 重新生成，不得手打）；
② 重裁 `.github/scripts/fixtures/pass-main-current.log`（**本轮真冷构建**日志，macabi 证据行须含 **`macabi`** 字样，不是路径里的 `maccatalyst`）；
③ `catalyst-gate.test.sh` 里**硬编码的回显数字**；
④ `docs/superpowers/acceptance/2026-09-01-finalize-alert-truthful-exit.md` 里硬写的 Catalyst 总数（现 **1935**）。

取数用 CI 同款 `-only-testing:KlineTrainerContractsTests`，日志**必须冷构建**（`mktemp -d` 专属 `-derivedDataPath`；⛔ 绝不删全局 DerivedData——本仓有 20+ worktree）。
**净增用例数由 plan 实测填写，⛔ 不得估算。**

### 7.3 交付方式

独立 worktree `.dev/worktree/drawing-p1c-3`，分支 `drawing/p1c-3-node-drag`，base = `origin/main` @ `25ad1c2a`。逐片合入 main，⛔ 不叠罗汉、⛔ 不与任何其它片合并成一个 PR。

评审命令固定：`.claude/scripts/codex-attest.sh --scope branch-diff --head drawing/p1c-3-node-drag --base origin/main`。⛔ 不得传任何未知参数（含 `--help`——兜底分支会把它当 focus 目标，产出假 approve + 脏账本）。

本片另带 `docs/superpowers/acceptance/2026-09-28-drawing-p1c-3-node-drag.md`（§9 的清单补齐细节后落地）。

---

## 8. 必须存在的测试

> **写每条断言前先自问**（上游 §11.4）：**「如果被测的那件事根本没发生，这条断言还会通过吗？」** 已知七种撞法：撞 no-op 守卫 / 撞出厂默认值 / 撞空栈 / 撞三元写法 / 撞终态相同 / 撞大小写 / 自检本身空转。
>
> ⛔ **没有「反假绿自检」一栏的断言不得进 plan。**

### 8.1 上游 §4.3 点名的 N1–N8（一条不得丢）

| # | 断言 | 层 | 反假绿自检 |
|---|---|---|---|
| **N1** | **D32 不得回退**：探针回答「没有」时，单指横滑仍平移、单指竖甩仍切周期、双指仍缩放，**与今天逐字相同** | host + 源码守卫 | ⭐ **必须配反向对照**：探针回答「有」时行为**确实不同**（不发任何 pan emission、不发 periodSwipe）。⚠️ 只有「没有」那一半时，「行为没变」会因为**分叉压根没接上**而恒真。⛔ 切周期那一档必须用 `TrainingEngineInteractionTests.engineMultiPeriod()` + `.toSmaller`（`TrainingEngineInteractionTests.swift:189`）——`preview()` 只有 `.m3/.m60/.daily`，两个方向都撞「目标周期无数据 → no-op」恒绿 |
| **N2** | **选中了但没落在节点上**：有选中线，起手落在**离节点很远**处 → 走方向分流，不是节点拖动 | host | 正向对照：同一条线、同一视口，起手改到节点处 → 进入拖动 |
| **N3** | **落在未选中线的节点位置上**：另一条**未选中**的线恰好在起手点有个锚点 → 不进入拖动 | host | ⚠️ 必须配对照：把那条线改成**选中** → 同一点进入拖动。没有它，「不进入」可能只是探针恒返「没有」 |
| **N4** | **一次拖动 = 一条撤销记录**：`.began` → `.changed` × N（N ≥ 3）→ `.ended` 后，撤销栈深度**恰好 1**；点 ↩ 一次，锚点**整个**回到拖动前的值 | host | ⭐ 上游明令**同时断言深度和回滚后坐标**（只断深度会撞空栈假绿）。⚠️ 再加一条：断言拖动后的锚点**确实 ≠** 拖动前（否则「撤销后等于拖前」会因为压根没改而恒真）。另断言 `drawingsRevision` 相对基线恰好 **+1** |
| **N5** | **引擎写入点穷尽性守卫同步**：`DrawingUndoSourceGuardTests` 的 U-G4 表 **10 → 11**，新接口在表里**有自己的一行**；L12b 总数同步 | host | 该守卫已有双向自检（`test_uG4_scanner_is_not_vacuous`：合成「写入被挪进表外私有 helper」的样本必须被判出来）。本片**确认它覆盖新接口的形状**并实跑，⛔ 不重复造一份自检 |
| **N6** | **「拖得动、松手弹回」这一族恒不存在**（D134b 的不变量；上游 N6 的「锁定的线拖不动」是其中一档）。逐档：① `locked`；② 携带**未来顶层字段**；③ 携带**未来枚举值**；④ **全局 id 重复**（一条可见 + 一条隐藏，⚠️ 必须这么造——可见域唯一而全局不唯一，正是 `DrawingEditRouter.swift:64-70` 区分两种唯一性的理由）；⑤ **不可编辑的工具类型**；⑥ `flow.mode == .review` | host | ⭐ **每档都要两层 + 一个正向对照**：**探针层**答「没有」**且手势照常走图表平移**（⛔ 只断言「没进拖动」不够——要证明它真的去平移了，否则「什么都没发生」也全绿）；**引擎层**直接调新接口返 `false` 且 `drawings` / `drawingsRevision` 零改动；**正向对照**把该档的成因去掉后两层都放行。⚠️ ⑥ 复盘档的正向对照要换 `flow.mode`，⛔ 不要顺手改别的分量 |
| **N7** | **拖出可见范围**：拖到主图外任意远 → 锚点被夹回，且**不产生** `visibleGeometry == nil` 的幽灵线 | host | ⭐ 判据必须**真的调一次 `HorizontalLineTool.visibleGeometry` 断言非 nil**，⛔ 不得断言「价位落在 priceRange 内」（四舍五入在那之后，D137）。四个方向（上/下/左/右）各一档 + **恰好压在边界上**一档。⭐ **`.straight` 与 `.ray` 必须各跑一遍全部档位** —— `.ray` 的右缘是严格 fail-closed（D137），朴素的「夹进可见窗口」写法**只在 `.ray` 上失守**，只测 `.straight` 会全绿。⚠️ **另配一档「框内不夹」**：拖在框内时锚点一个字节不改——否则「恒夹到边界」的实现也会全绿 |
| **N8** | **拖动中切周期**：拖到一半周期变了 → 拖动作废，`drawings` 一个字节没变、撤销栈无新记录 | host | ⛔ 必须用 `engineMultiPeriod()` + `.toSmaller`（理由同 N1）。⚠️ 正向对照：**不**切周期时同一串回调**确实**写入了一条。另一档：**转屏（视口变、周期不变）→ 拖动继续**，且夹取用**新**视口的边界 |

### 8.2 本片新增的 T 系列

| # | 断言 | 层 | 反假绿自检 |
|---|---|---|---|
| **T1** | **Q19 的分支顺序**：起手点同时落在节点上**和**线上（水平线必然如此）→ 进入节点拖动 | host | ⭐ **本条自身证明不了自己有判别力**（「先问线」的实现下它照样命中线）⇒ 判别力**只能靠变异**：把探针改成「先问线、线命中就返回没有」⇒ 本条**必须变红**。不红 = Q19 全程无人看守 |
| **T2** | **双轴跟随**：横向拖动后 `candleIndex` **真的变了**，且等于夹取后 x 反算出的下标 | host | 正向对照：横向不动（只上下拖）时 `candleIndex` **不变** |
| **T3** | **实时跟随**：拖动每一帧，`visibleDrawings` 里那条线的几何 == 当前拖动锚点的投影 | host | ⚠️ 必须先断言**帧与帧之间几何确实变了**（差值非 0），否则「两边取同一个常数」恒真 |
| **T4** | **第二根手指落下 → 就地定住**（D138）：走与抬手同一条收尾路径，1 条撤销记录 | host | 断言定住的锚点 **≠** 拖动起点的锚点 |
| **T5** | **Q25 的像素证据**：同一根 K 线、同一个价位上既有成交标记又有选中节点 → 节点中心那一点是**节点的颜色**（日间纯黑 / 夜间纯白） | Catalyst | ⭐ 正向对照：**移走标记**后同一点仍是节点颜色（证明不是恒真）。⚠️ 变异「把 `drawSelectionNodes` 挪到 `drawMarkers` 之前」必须让**本条**变红，且必须与第 2 片 T13（源码顺序，`Tests/.../Render/SelectionNodeDrawOrderGuardTests.swift:36`）**分别确认红的是哪一条** |
| **T6** | **拖动中一次盘都不写**（D135）：`.began` 到最后一个 `.changed` 期间 `drawingsRevision` **一次都没变** | host | ⭐ 正向对照：`.ended` 之后它 **+1**。这条直接守住「每秒 60 次写盘」那个缺陷 |
| **T7** | **新写入面的门逐条**（D136 的 ⓪①②②b③④⑤ 共 7 道拒收门） | host | ⭐ **每档都配一个「把这道门拿掉就会放行」的对照**，⛔ 不得只断言「返回 false」——恒返 false 的实现会全绿 |
| **T7b** | **门 ⑥ 的方向，两档分别钉死**：① **相等档**（新锚点 == 原锚点）→ 返 `true`、`drawingsRevision` **不变**、撤销栈**不变**；② **不相等档**（真的拖动过）→ 返 `true`、`drawings` 里那条**确实变成了新锚点**、`drawingsRevision` **+1**、撤销栈**恰好多一条** | host | ⭐ **必须两档都写**。只写相等档 ⇒ 条件写反时全绿（第 1 轮评审 R1 实证的正是这个方向）；只写不相等档 ⇒ 无条件写入的实现也全绿。⛔ 不相等档**不得只断言返回值** —— 返 `true` 不等于真的写了 |
| **T9** | **起手点的重建**（D134c），四档：① 按下**在**节点半径内、`.began` 时 `translation` 已把当前点带**出**半径 → **必须进拖动**（⇒ 路由不看 `.began` 的当前点）；② 按下**在**半径外、`.began` 时当前点已落**进**半径 → **必须不进拖动**、且照常走图表手势；③ `translation == .zero` 的退化档 → 与今天行为一致；④ **锚点增量 ≡ `translation` 的换算值**（D134d 的两个公式）：给定一串 `translation`，锚点的价位增量逐帧等于 `-translation.y × span / height`、下标增量等于 `translation.x / candleStep` 取整 | host | ⭐ ①② 是**互为对照**的一对，⛔ 缺一不可：只写 ① ⇒ 「探针恒答有」全绿；只写 ② ⇒ 「探针恒答没有」全绿。④ 必须断言增量**非零**且**不等于** `location` 直接当目标时的值（两者只在 `translation != .zero` 时才分得开 ⇒ 该档的 `.began` translation **必须非零**，⛔ 不得用 0） |
| **T12** | **「按住再拖」必须能拖动**（D140c），五档：① 按在节点上 → **让长按识别器真的走到 recognized** → 再拖 → **必须拖节点**，且**不产生**任何平移 emission、**不产生** `periodSwipe`；② 同 ① 但按在**节点外** → 必须照常平移；③ **快速按下即拖**（长按未识别）→ 也必须拖节点（证明两条路都通）；④ 视图收到 `touchesCancelled` **之后**候选**仍在**（直接断言状态）；⑤ **陈旧候选不泄漏**：在节点上按下后**抬手不拖**，再到**离节点很远**处按下并拖 → **必须平移** | 见右栏 | ⭐ ① **必须断言长按识别器确实识别了**（读它的 `state`），⛔ 不能只是「等了 0.5 秒」—— 否则该档退化成 ③ 的复制品，而缺陷原样存在。①② 互为对照。⚠️ **本族要真识别器 ⇒ 落 Catalyst**；但「用测试驱动真实 `UILongPressGestureRecognizer` 走到 recognized」在本仓**尚无先例**，plan **必须先实跑确认做不做得到**：做得到 → 落 Catalyst 并同步四处基线；**做不到 → ⛔ 不得静默降级**，须①把候选生命周期的规则抽成 host 可测纯函数覆盖 ①③④⑤ 的**规则层**，②把「真识别器那一环」逐条写进真机验收清单并在本 spec §10 登记为具名残留（⛔ 不许只写个数量） |
| **T11** | **视口在「按下 → `.began`」之间移动**（D140b），四档：① 按下时节点在指下、之后**惯性把节点移出** 11pt → **仍必须进拖动**；② 按下时指下**没有**节点、惯性把某节点**移进**指下 → **必须不进拖动**且照常走图表手势；③ `settleDeceleration` **夹回 overscroll** 致投影移动 → 同 ①；④ 候选在按下与 `.began` 之间**失效**（线被删 / 选中被清 / 被锁 / 进复盘）→ fail-closed **不进拖动** | host | ⭐ ①② **互为对照，缺一不可**：只写 ① ⇒「候选恒有效」全绿；只写 ② ⇒「恒不进拖动」全绿。⚠️ ③ **必须断言 overscroll 确实被夹过**（构造一个真的 overscroll 的面板并在前后比对 offset），否则该档退化成 ① 的复制品。⚠️ ④ 的四个成因**各跑一档**，⛔ 不得只测其中一个就宣称覆盖 |
| **T13** | **面板盖住的地方拖不动**（探针前置条件 3）：`shield` 为 `.pending` → 探针答「没有」；`.rect` 且按下点**在区内** → 答「没有」；`.rect` 但按下点**在区外** → 答「有」 | host | ⭐ 三档缺一不可：少了「区外答有」这一档，「恒答没有」会全绿。⚠️ 判据必须与 `handleDrawingTap`（`:342-344`）**逐字同形**，plan 需并排贴出两处代码举证 |
| **T10** | **零位移恒等 + 纯横拖不改价位**（D134d），三档：① `translation == .zero` → 新锚点**逐字段 `==`** 原锚点（`price` 用 `==`，⛔ 不用近似比较）；② **纯横拖**（`translation.y == 0`、x 非零）→ `price` **逐位不变**，只有 `candleIndex` 变；③ **拖走再拖回**（translation 回到 `.zero`）→ 走门 ⑥ ⇒ 返 `true`、`drawingsRevision` **不变**、撤销栈里那条**原有记录还在** | host | ⭐ **必须用投影落在非整像素上的价位**（如 `displayScale=3`、主图高 401pt、价区 `10…23.7` 下的 `15.123456`）—— 用恰好落在整像素的价位，投影往返**碰巧**恒等 ⇒ 三档全绿而缺陷原样存在。⚠️ ③ 的「原有记录还在」必须断言**记录内容**，⛔ 不是只断言栈非空（撞空栈那一族） |
| **T8** | **作废之后手势不回落成平移**（D138 末段）：周期变化作废后，同一手势的后续 `.changed / .ended` **不产生任何 pan emission、不产生 periodSwipe** | host | 正向对照：**没有**进入过节点拖动的同一串回调**确实**产生 pan emission |

### 8.3 源码守卫（G 系列）

| # | 守卫 | 反假绿自检 |
|---|---|---|
| **G1** | 既有两条手势守卫**继续绿**：`handleSinglePan` 体内无 `drawingMode`；`GestureClassifiers` 里无 `drawingTakesOver` / `DrawingModePanPolicy` / `panPolicyInDrawingMode` | 既有守卫自带「防切片为空」的正向断言（`#expect(body.contains("singlePanStep("))`）。本片**只需确认它们仍绿**，⛔ 不得因为「挡路」去改它们 |
| **G2** | **起手路径上不得出现 `DrawingHitTester`**（D134 的结构不变量）：探针实现所在函数体内不引用该类型 | ⚠️ 切片锚点找不到时必须 `Issue.record` 当场红（⛔ 不得静默通过）；且必须配**防切片为空**的正向断言（体内确实含 `hitTestNode(`）。⚠️ 判据的**文本来源是判据的一部分**：读仓内源文件本体、先剥注释 |
| **G3** | **两条时序契约**（D140 / D140b）：① 触摸按下的处理函数体内**不得出现** `settleDeceleration` / `rebuildRenderState` / 任何 engine mutator —— 它必须是**纯只读**的（D140b 的 load-bearing 约束）；② pan `.began` 路由到拖动的那一支里，`settleDeceleration` → `rebuildRenderState` → 读 viewport → `CoordinateMapper` 四者顺序 | 与既有 `drawingTapSettlesBeforeMapping`（`DrawingGestureSourceGuardTests.swift:62`）同款写法。⚠️ 五个锚点**缺任何一个都要显式报错**，⛔ 不得当作通过 |

| **G4** | **探针不得自己重写那份非几何清单**（D134b 的结构保证）：探针实现所在函数体内**不出现** `locked` / `hasKnownFuture` / `isEditableToolType` / `flow.mode` 任一字面量，且**确实调用了** `editableIgnoringGeometry(` | ⚠️ 两个方向都要：只写「不出现」⇒ 探针整个不查也全绿（撞空转）；只写「调用了」⇒ 又调又自己抄一份也全绿。⚠️ 切片锚点找不到必须 `Issue.record` 当场红；先剥注释再匹配（注释里必然提到这些词） |
| **G6** | **`.began` 路由不得重做几何命中**（D140b）：pan `.began` 的路由分支体内**不出现** `hitTestNode(` / `marks(`；而触摸按下的处理函数体内**必须出现** `hitTestNode(` | ⚠️ 两个方向缺一不可：只写「`.began` 里没有」⇒ 探针整个没接也全绿；只写「按下里有」⇒ 两处都查也全绿。⚠️ 切片锚点失配必须 `Issue.record` 当场红 |
| **G7** | **触摸钩子只在单点触摸时发**（D140b）：`touchesBegan` 的实现体内出现「触摸数 == 1」这一判据 | ⚠️ 必须配行为测试：喂两点触摸 ⇒ 不产生候选。⛔ 只做源码守卫不够——判据写成 `>= 1` 源码上照样「出现」 |
| **G8** | **候选的清除点恰好三处，且都不在触摸结束/取消里**（D140c）：`touchesCancelled` / `touchesEnded` 的实现体内**不出现**清除候选的调用；清除调用点总数**恰好等于** D140b 表里那三行 | ⚠️ 两个方向缺一不可：只数总数 ⇒ 把一处清除从「第二根手指」挪进 `touchesCancelled` 总数不变、全绿；只查「取消里没有」⇒ 一处都不清也全绿。⚠️ 必须配**防切片为空**的正向断言（`touchesCancelled` 的实现体确实被切到了）。⚠️ 切片锚点失配必须 `Issue.record` 当场红 |
| **G5** | **`editableIgnoringGeometry` 的函数体未被本片改动**（只许改访问级别）：取该函数体的**归一化文本**（逐行剥行尾注释 → 压连续空白 → 去首尾空格 → 丢空行 → 以 `\|` 连接），**整串相等**于下面这个期望值（`private` 一词由本片改成 `internal`，⇒ 期望串的首行相应为 `internal static func …`）：<br><br>`internal static func editableIgnoringGeometry(engine: TrainingEngine) -> Bool {` \| `guard engine.flow.mode != .review else { return false }` \| `guard let d = uniqueSelected(engine: engine) else { return false }` \| `guard idIsGloballyUnique(engine: engine, id: d.id) else { return false }` \| `guard !d.locked else { return false }` \| `guard DrawingStyleAvailability.isEditableToolType(d.toolType) else { return false }` \| `return !engine.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: [d.id])` \| `&& !engine.loadedDrawingsLossy.hasKnownFutureFields(liveIds: [d.id])` \| `}` | ⛔ **必须整串相等，不得只数分量个数**（改一个分量名个数不变，撞「存在性检查表达不了穷尽性」那一族）。⚠️ 期望串写死在测试里 ⇒ 本片**故意**让「日后有人动这个函数」变成当场红；真要动它的人必须同时解释为什么本片这三条消费路径不受影响。⚠️ 归一化函数自身要配双向自检（喂一段改了分量的样本必须**不**相等） |

### 8.4 变异验证纪律

- **先提交实现、再跑变异**；复原一律 `cp` 往返，⛔ **禁止 `git checkout <file>`**；
- 每条变异必须回答「**红的是哪一条测试名**」——「有测试变红」是假信号；
- ⚠️ **每条期望一律实跑验证，⛔ 不得推理**。第 2 片在这上面栽了两次（spec 写「拿掉 y 守卫 ⇒ T1 变红」实测**不红**；写「拿掉锚数截断 ⇒ 两档都红」实测**第二档不红**）——**变异期望写错会逼着人去改判据凑红**。
- ⚠️ **跑变异 / 跑构建时不得改动工作树**（第 2 片实证：Catalyst 后台构建期间做变异，它读到变异中的源码、报了 3 条假失败）。
- ⚠️ `@Observable` 类新增存储属性会改实例内存布局；增量产物没全重建时 `swift test` 会在**随机的、与改动无关的位置** SIGSEGV ⇒ **本片给 `DrawingSession` 加了 `nodeDrag`，属于这一类** ⇒ 下结论前先 `rm -rf ios/Contracts/.build`。

**本片必须做的变异（plan 可加不可减，逐条实跑填「红的是哪条」）**：

| 变异 | 期望变红 |
|---|---|
| 探针改成「先问线，线命中就返回没有」 | **T1** ⭐（不红 = Q19 无人看守） |
| 位移改回「原锚点投影 + `translation` 再反算」 | **T10** 的 ①②③ 三档 ⭐ 第 4 轮评审抓到的那条。⚠️ 必须用非整像素价位造样本，否则全绿 |
| `priceDelta` 的负号写掉 | **T9** 的 ④ 档（价位增量符号反了）。⚠️ **T10 的 ② 档预期不红** —— 纯横拖 `translation.y == 0`，负号乘 0 没有差别；**若 ② 也红说明测试串了，要查**。⛔ 两条预期都由 plan 实跑确认，不得推理 |
| **把「触摸取消 / 触摸结束」加回候选的清除时机** | **T12** 的 ①④ 档 ⭐ 第 6 轮评审抓到的那条 |
| 去掉「新按下覆盖旧候选」（只在消费时清） | **T12** 的 ⑤ 档 |
| 探针里的盾判据拿掉 | **T13** 的 `.pending` 与「区内」两档（⚠️「区外」档预期**不红**） |
| **探针改到 `.began` 才跑**（用刹车后的视口现查） | **T11** 的 ①②③ 三档 ⭐ 第 5 轮评审抓到的那条 |
| 在触摸按下的钩子里加 `settleDeceleration` | **G3** 的 ① 分支 + **N1** 的「惯性期间行为不变」档（⚠️ 后者 plan 须先确认自己写得出这一档，写不出就如实登记只有 G3 接得住） |
| 候选的 fail-closed 复核拿掉 | **T11** 的 ④ 档（四个成因各自应红） |
| 路由改用 `.began` 的 `location`（不减 `translation`） | **T9** 的 ①② 两档 ⭐ 第 3 轮评审抓到的那条 |
| 节点目标位置改用 `location` 直接当目标（丢掉抓取偏移） | **T9** 的 ④ 档 |
| 探针改成只查 `locked`（即第 2 轮评审报的那一稿：不调 `editableIgnoringGeometry`） | **N6** 的 ②③④⑤⑥ 五档的**探针层** ⭐ 第 2 轮评审抓到的那条。⚠️ ① `locked` 档**预期不红**（它本来就查）——若它也红说明测试串了 |
| 探针整个不查非几何门（连 `locked` 也不查） | **N6** 全部六档的探针层 |
| 夹取整个拿掉（锚点原样写出） | **N7** 的四个方向档 |
| 夹取改成「恒夹到边界」 | **N7** 的「框内不夹」档 |
| 夹取改成朴素的「把 `candleIndex` 夹进可见窗口」（不看后置条件） | **N7** 的 **`.ray` 右缘**档 ⭐ ⚠️ `.straight` 档**预期不红**（它横贯全图、不看锚点 x）—— 若 `.straight` 也红，说明测试串了，要查 |
| 拖动中直接改 `engine.drawings` | **T6** |
| 收尾改成每帧入一条记录 | **N4** 的深度档 |
| 周期变化时不作废、照常写入 | **N8** |
| 作废后回落成图表平移 | **T8** |
| `drawSelectionNodes` 挪到 `drawMarkers` 之前 | **T5**（像素）+ 第 2 片 **T13**（源码顺序），**各自确认** |
| 双轴改成只改价位 | **T2** |
| 「就地定住」改成「作废回弹」 | **T4** |
| 新接口的 `anchorIndex` 范围门拿掉 | **T7** 的 ④ 档（⚠️ 越界是 trap，该档会**崩**而不是失败——如实登记预期形态） |
| 新接口的 `period` 门拿掉 | **T7** 的 ⑤ 档 |
| **门 ⑥ 的短路条件写反**（改成 `updated != old` 时短路） | **T7b** 的不相等档 + **N4**（压根没写进去 ⇒ 撤销栈是空的）⭐ 第 1 轮评审抓到的那条，必须有测试接得住 |
| 门 ⑥ 整个拿掉（内容没变也照写） | **T7b** 的相等档 |
| 把 G2 守卫的切片锚点改名 | **G2 自身**（必须 `Issue.record` 红，⛔ 不得静默绿） |

---

## 9. 非程序员验收清单（骨架，本片 plan 补齐细节）

> **治理要求**（`.claude/workflow-rules.json`）：中文；三栏 = 动作 / 预期 / 通过-不通过；⛔ 禁用短语「验证通过即可」「看起来正常」「应该没问题」「should work」「looks fine」。
>
> **⚠️ 第 2 片末尾发现的三条纪律，本片逐条遵守**：
> ① **术语翻译成动作**——⛔ 不得直接抄 spec 的开发者说法（例：「点熄水平线图标」→「把横线图标**点成灰框**」；蓝框 = 画线态、灰框 = 选择态，点它切换）；
> ② **每条都要自查「真机上做不做得到」**——第 2 片有一条沿用两片的条目要求「同价位画三条重合的线，把中间那条 B 删掉」，而 `DrawingHitTester.swift:17` 的已知限制是「容差内的两条线，单击**恒**选中最上层那条」⇒ **B 根本选不中**，那一步做不到。根因是它原本是自动化测试、被抄成真机步骤后前提就没了；
> ③ **已知设计限制写进清单开头**，否则验收者会把「先画的那条选不中」当成 bug。

**清单开头必须写明的已知限制**（plan 补全措辞）：
- 几条线重合时，点一下**只能**选中最上面（最后画的）那条；
- 想把线放到比屏幕上现在显示的价格更高 / 更低的位置，**做不到** —— 得先把图缩小或上下调，让那个价位出现在屏幕里（D137 的直接后果，**不是 bug**）；
- 锁上的线**选得中、看得见黑点，但拖不动**（D139）。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 1 | 画一条横线，把横线图标**点成灰框**，点一下那条线选中它，然后**按住那个黑点上下拖** | 线跟着手指上下移动，线旁边的价位数字实时跟着变 | ☐ 通过 ☐ 不通过 |
| 2 | 松手后点底栏 ↩ | 线**一次性**回到拖之前的位置（不是一点一点退回去） | ☐ 通过 ☐ 不通过 |
| 3 | **不选中任何线**，在图上横向拖 | 图表照常左右平移 | ☐ 通过 ☐ 不通过 |
| 4 | **不选中任何线**，在图上竖直甩一下 | 照常切换周期 | ☐ 通过 ☐ 不通过 |
| 5 | 选中一条线，在**离黑点很远**的地方横向拖 | 图表照常平移（不是拖线） | ☐ 通过 ☐ 不通过 |
| 6 | 选中一条线，在离黑点很远的地方**竖直甩** | 照常切换周期 | ☐ 通过 ☐ 不通过 |
| 7 | 选中一条线，点底栏 🔒 锁上，再按住黑点拖 | **线纹丝不动**，而且图表跟着手指平移了 | ☐ 通过 ☐ 不通过 |
| 8 | 两指缩放 | 照常缩放 | ☐ 通过 ☐ 不通过 |
| 9 | 按住黑点**一直往上拖到图的顶边以外**，然后松手 | 黑点**贴着图的上边**停住，线还在、还看得见；⛔ 线不会消失 | ☐ 通过 ☐ 不通过 |
| 10 | 按住黑点**横着**拖一段距离，松手 | 黑点横向移动了；**直线**那种横线本身看上去位置不变（它本来就横贯全图），这是对的 | ☐ 通过 ☐ 不通过 |
| 11 | 拖黑点拖到一半，**再落下第二根手指**开始缩放 | 线**停在刚才拖到的位置**不再动，缩放正常；点 ↩ 能把它退回拖之前 | ☐ 通过 ☐ 不通过 |
| 12 | 在有**买卖标记**（图上那些带 B / S 的小圆点）的那根 K 线上，画一条横线让它的黑点正好落在标记上，选中它 | 黑点**看得见**，没有被买卖标记整个盖住 | ☐ 通过 ☐ 不通过 |

⚠️ **第 12 条的可执行性自查**：要让黑点落在标记上，得在那根 K 线的**收盘价附近**点一下落锚。真机上这是做得到的（落锚点就是手指点的位置）。plan 需补一句「怎么确认它们确实重合了」的可观察判据。

---

## 10. 遗留问题（交接给后续片，⛔ 不得默默跳过）

> **纪律同第 1 / 2 片**：每条只负责三件事 —— ① 已核实的事实；② 为什么不能不管（尤其症状是否**静默**）；③ 必须存在的测试。**⛔ 本节不开药方。**

| # | 问题 | 归属 | 为什么不能拖 |
|---|---|---|---|
| **Q24**（原样有效） | **`hitTestNode` 返回的必须是原 `anchors` 下标**，在本片仍**无法被证伪**：水平线单锚（`HorizontalLineTool.swift:13`），构造不出「一个锚点出屏、另一个在屏内」的混合输入。本片写拖动时**按「它是对的」使用**；D136 的门 ④（下标范围）只是**部分**兜底——它挡得住越界，挡不住「下标在范围内但指错了锚」 | **第 4 片** | 症状**静默且危险**：拖动会**拖错锚点**（用户以为在调 A，实际改的是 B），而屏幕上看起来一切正常 |
| **Q26**（本片新增） | **夹取的边界值与「视口自己在变」的交互未被覆盖**：本片的夹取取的是**起手那一帧**建立的 mapper（D140）。训练推进 / 惯性 / 转屏会让视口在拖动中变化，而 D138 只规定了「周期变 → 作废、视口变 → 继续」，**没有规定 mapper 何时重取**。本片实现按「每帧重取当前 mapper」，但**没有一条测试钉死这件事** | **本片 plan 必须补一条**；若 plan 阶段判定测不了，则**升级为交接项**并写明理由 | 症状是**静默**的：夹取用了陈旧视口 ⇒ 边界算错 ⇒ 又可能产出看不见的线（正是 N7 要禁的） |
| **Q27**（本片新增） | **`.ray` 子类型横向拖动的用户可见后果未单独验收**：双轴跟随下，拖 `.ray` 的节点会**移动射线的起点**（`HorizontalLineTool.swift:50` 的 `lineXRange`、`.ray` 分支在 `:56-58`），这在屏幕上非常明显；而本片验收清单第 10 条只覆盖了 `.straight`（看上去不变）。⚠️ 实测：水平线三个子类型里 `.straight` / `.ray` **都可选**、只有 `.segment` 恒灰（`Drawing/DrawingStyleAvailability.swift:6-11`）⇒ `.ray` 是用户真选得到的 | **本片 plan 补一条验收**（不是交接） | 症状**不静默**（一眼看得见），但没人验 = 没有证据 |
| **Q28**（本片新增 · **条件性**） | **「用测试驱动真实 `UILongPressGestureRecognizer` 走到 recognized」在本仓尚无先例**（§8-T12 ①）。plan 必须**实跑**二选一并在本行写明采用了哪一支：**(a) 做得到** → 落 Catalyst、同步四处基线，本行改注「已闭合」；**(b) 做不到** → 规则层落 host 纯函数、真识别器那一环逐条进真机验收清单，本行保留为**具名**残留并列出**逐条**未被自动化覆盖的断言 | **本片 plan**（⛔ 不得交接给后续片） | 症状是**静默**的：规则层全绿，而真机上「按住再拖」照样拖不动。⛔ **不得只记数量**（「还有 1 条没覆盖」＝静默丢弃，本仓已有纪律） |
| **Q20 / Q21 / Q22 / Q23 / Q25** | 第 2 片 §11 的五条：Q20（第 6 片不得复活 `selectionRGBA`）/ Q21（第 4-6 片每加工具三件事）/ Q22（C 类 11 条 user 认领）/ Q23（交互稿蓝外圈，本片已自查，见 D143）/ **Q25 本片已挖清并给出像素证据**（§2.4 + T5） | 见第 2 片 §11 | Q22 ⛔ 后续评审不得当作被遗忘的残留重提 |
| **Q4 / Q5 / Q6** | 上游 §10 的三条原样有效（Q4 / Q5 → 第 6 片；Q6 → 第 5 片）。**Q3 由本片 D137 回答完毕** | 见上游 §10 | — |
| **Q8 / Q10 / Q11 / Q12 / Q13 / Q14–Q18** | 第 1 片 §8 交接的各条原样有效，本片一条都不碰 | 见第 1 片 §8 | Q11 / Q13 ⛔ 不得当作被遗忘的残留重提 |

---

## 11. 本 spec 不做

四个新工具各自的几何设计（各片自己的 spec）；任何实施细节（属 plan）；第 4–6 片的范围调整（上游 D109/D109b + 第 1 片 D112 原样有效）；P2 的五个工具；P3 标注；P4 放大镜与吸附（D142）；P5 复盘集成；P6 主页全局默认设置。

**⛔ 与上游 §12、第 1 片 §9、第 2 片 §12 同一条纪律：任何实现者都不得把 P1c 的任意两片合并成一个 PR**，除非重走一次拆分论证并拿到 user 同意。
