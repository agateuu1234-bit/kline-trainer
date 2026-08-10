# 划线工具扩充 · P1b-1b-ii 设计 spec：锁定 / 解锁 + 撤销 / 前进

**日期**：2026-08-11
**上游 spec**（继续全部生效，本文件只补充与澄清，不推翻）：
- 母 spec `docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`（D1–D22）
- 拆分补充 spec `docs/superpowers/specs/2026-07-10-drawing-tools-P1b-split-addendum.md`（D23–D43，**§7 = 1b-ii 交付范围**）
- 1b-i 设计 spec `docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（D49–D67，**§9 = 交接给 1b-ii 的三条**）

**基线**：`origin/main` `567987b`（1b-i 四片全部合入：#153 / #154 / #156 / #159）。
分支 `drawing-tools-p1b-1b-ii`，worktree `.claude/worktrees/drawing-p1b-1b-ii`。
基线闸门实测：host `swift test` = **1803 tests passed**。

本 spec 新增决策编号从 **D68** 起（D49–D67 属 1b-i）。

---

## 0. 范围与切分

### 0.1 1b-ii 是 P1b 六片序列的**最后一片**

合并后 P1b 全部完成。P1c（多锚 / 节点 / 四工具）**不是已授权的 PR 边界**，不在本 spec 范围内。

### 0.2 D68　1b-ii 切成两个顺序 PR（不是一个）

| 片 | 交付 | 生产代码估算 |
|---|---|---|
| **PR-1　锁定** | 底栏 **②🔒** + `setDrawingLocked` 引擎 API + 路由与可用性谓词 + 锁定线的置灰传播 | ~120 行 |
| **PR-2　撤销** | 底栏 **④↩ ⑤↪** + 撤销栈（深度 1）+ 四类动作的 undo / redo | ~180 行 |

**次序不可乱：PR-1 → PR-2。**

**为什么切（split addendum §7 原本估 ~250 行、按一个 PR 打包）**：
1. **两个风险面完全不同**。锁定是**权限门控**——问题形态是「门列表和 UI 谓词漂移」（少一道 = 控件亮着点了没反应，多一道 = 过度置灰）。撤销是**状态机 + 数组下标保真**——问题形态是「撤销之后 z-order 乱了、再点选中的不是原来那条」。把两者塞进一个评审面，历史上必不收敛（见 1b-i：原估 400 行，实际切成四个 PR 才把 codex 评审收住）。
2. **依赖方向单向且干净**。PR-2 的四类入栈动作里有一类就是「锁定 / 解锁」；PR-1 先落地，PR-2 才有真东西可测，不必造替身。反向不成立。
3. PR-1 落地后底栏是 4 键（①类型 ②🔒 ③🗑），PR-2 才补齐成母 spec §2 的 5 键。这**不违反 D24 / D19**（不 ship 未接线控件）——D24 原文即「骨架一次定型、控件按期填充」，每一期只渲染该期已落地的控件。

### 0.3 本 spec 不做

节点 / 多锚 / 四个新工具（P1c）；复盘选中与复盘专属一切（P5）；主页全局默认设置（P6）；跨会话保留撤销栈（D25 明确否定）。

---

## 1. PR-1：锁定 / 解锁

### 1.1 D69　`setDrawingLocked(id:locked:)` 的门列表

新增引擎 API，**是 `Sources/` 里唯一被允许改 `locked` 的入口**：

```swift
@discardableResult
func setDrawingLocked(id: DrawingID, locked: Bool) -> Bool
```

门列表（**逐条与 `updateDrawingStyle:1156-1182` 对照给出取舍，不许照抄、也不许凭直觉增删**）：

| # | 门 | `updateDrawingStyle` | `setDrawingLocked` | 理由 |
|---|---|---|---|---|
| ⓪ | `flow.mode != .review` | 有 | **有** | D34 纵深防御。复盘的原训练线属已归档记录，锁定同样是写入，不得让复盘获得该能力（trust-boundary）。 |
| ① | `id` 非空 + 在 `drawings` 里**全局唯一** | 有 | **有** | D66。重复 id 下「改哪一条」不可判定，fail-closed。 |
| ② | `!old.locked` | 有（D60） | **无** ⛔ | **这是本 API 存在的全部理由**。带这道门 = 锁上就永远解不开。1b-i spec §9 逐字：「豁免 D60 的 locked 闸」。 |
| ②b | `isEditableToolType(toolType)` | 有 | **无** | 该门问的是「本构建懂不懂这个工具的**样式语义**」。锁定不解释任何样式，只翻一个布尔。带上它会造出「P1c 写的 `.trend` 线在本构建里锁不上也解不开」的新死角——与 N14h 同族的错误。 |
| ③ | D61 raw-aware 两道门（未来字段 / 未来枚举值） | 有 | **无** | **这是 N14h 死角的解药**（见 §1.2）。`updateDrawingStyle` 拒它们是因为改样式必然要重写那些 key；锁定只动 `locked` 一个 key，原始字节由 §1.2 的机制原样保留。 |
| ④ | `withStyle` 语义闸（D59） | 有 | **无** | `withStyle` 明写「本函数不碰 `locked`」（`DrawingObjectStyleEdit.swift:44`）。锁定不经过它。 |

**幂等**：`locked` 已经等于请求值 → **返回 `true`，且 `drawingsRevision` 不递增**。
理由：`drawingsRevision` 是「内容真的变了」的信号，内容没变就不该触发 autosave（D30 / D56）。返回 `true` 表达的是「调用后 `locked` 处于你请求的状态」，UI 是 toggle、请求值恒与当前相反，这条路径用户不可达，只有直接调用者够得到。

**成功路径**：`drawings[i]` 换成只改了 `locked` 的新对象 → `drawingsRevision += 1` → 返回 `true`。
**不得**用 `withStyle` 造那个新对象；`DrawingObject` 的 18 个字段里除 `locked` 外**逐字段原样拷贝**。

### 1.2 D70　raw-preserving 单字段 merge —— **机制已存在，PR-1 不新建**

1b-i spec §9 的交接原文要求 1b-ii「真正做 raw-preserving 的单字段 merge」，读起来像要新写一套合并机制。**实测代码后结论是：这套机制在 P1a 就已经建好了，PR-1 只需要不破坏它。**

依据（三条，逐条可复核）：

1. `LossyDrawingArray.reconciled(currentKnown:)`（`Persistence/LossyDrawingArray.swift:327`）是保存路径的归并入口。对每个 `.known` 元素：`cur == old` → **原样保留 raw 字节**；不等 → 走 `mergeKnownFields`。
2. `LossyDrawingArray.mergeKnownFields(into:from:old:)`（同文件 `:295`）**逐 key 比较 `cur` / `old`，只覆盖真变化的 key**，未变化的 key 保留 `dict` 里的原始字节。这正是 codex whole-branch R17 为了防止「改 thickness 时把 colorToken 的未来值 `futureNeon` 抹掉」而加的修复。
3. `DrawingObject.==`（`Models/Models.swift:370`）**包含 `locked`**。

三条合起来：只改 `locked` 的对象与旧对象 `!=` → 进 `mergeKnownFields` → 只有 `locked` 这一个 key 被覆盖 → 其余全部原始字节（含未来顶层字段与未来枚举值）逐字保留。**这就是所要的单字段 merge。**

⚠️ **这是设计假设，不是已验证事实。** 上面是读代码推演出来的，本仓的纪律明确：读代码发现不了恒真断言（`feedback_mutation_testing_beats_reading`）。故：

> **PR-1 的第一条 TDD 测试必须是这条假设的举证测试**（N-A，见 §1.6），且必须做变异验证——把 `Models.swift:370` 的 `lhs.locked == rhs.locked` 分量删掉，该条测试必须变红。若变异后仍绿，说明测试根本没测到 merge 路径，整条设计假设作废，PR-1 需回到「自己实现单字段 merge」的方案。

### 1.3 D71　路由与可用性谓词

写入路由与谓词一律加在 `Drawing/DrawingEditRouter.swift`（D62 / D51：引擎写入 API 在 `Sources/` 里**恰好一个**调用点；该文件无 UIKit，host 可测）。

新增三个成员，形状**严格对称于已有的删除三件套**（`deletableIgnoringGeometry` / `deleteButtonEnabled` / `deleteSelected`）：

| 成员 | 用途 | 几何读法 |
|---|---|---|
| `lockableIgnoringGeometry(engine:)` | 非几何分量 | — |
| `canToggleLock(engine:)` | **路由用**（唯一的门） | 几何**现算** |
| `lockButtonEnabled(engine:)` | **UI 用**（🔒 置灰） | 几何读 **observable 提示** |
| `toggleLockSelected(engine:)` | `setDrawingLocked` 的**唯一**调用点 | — |

`lockableIgnoringGeometry` 的分量 = **引擎门列表 ⓪① 逐条对齐**，即：

```
flow.mode != .review  &&  uniqueSelected != nil  &&  idIsGloballyUnique
```

**注意它比 `deletableIgnoringGeometry` 少一个 `!d.locked` 分量** —— 这不是笔误，是 D69 门② 的镜像：锁定线**必须仍能被选中并解锁**（split addendum §7.1 逐字）。

**几何门照收**（与 🗑 同待遇）：判据 = `selectionGeometryVisible`。
理由：底栏键的可用性对用户是一个统一心智模型「选中的线看得见 → 这些键能用」；且 PR-4 已把 `selectionGeometryVisible` 确立为共享判据，另立一套必然漂移。锁定虽然可逆（不像删除不可逆），但可逆性只是"万一放宽也安全"，不构成现在就放宽的理由（YAGNI）。

`toggleLockSelected` 的执行顺序（与 `deleteSelected` 同形）：
```
defer { syncSelectionByState(engine:) }
取 selectedDrawingID → guard canToggleLock（几何现算）→ engine.setDrawingLocked(id:, locked: !current)
```

### 1.4 D72　UI：底栏 ②🔒 与置灰传播

**底栏**（`UI/DrawingModeBar.swift`，现 44 行）补第 ② 键，位置按 D24 排在 ①类型 与 ③🗑 之间。
与 ③🗑 同款：视图**自己不判任何东西**，可用性由 `DrawingModeBar` 的入参传入（现有 `deleteEnabled` 的同款 `lockEnabled`），判据全在 router。

**图标形态**：

| 状态 | 图标 | 可用性 |
|---|---|---|
| 无选中 | `lock.open`（开锁） | 灰 |
| 选中且未锁 | `lock.open`（开锁） | 亮 |
| 选中且已锁 | `lock`（闭锁） | 亮 |

即：图标形态**只反映选中线的 `locked`**，无选中时取「开锁」作为中性态。**不在线旁画小锁图标**（split addendum §7.1 逐字）。

**置灰传播**：选中线 `locked == true` 时，🗑 与 5 组样式控件全灰。
**这一条 PR-1 零新增代码** —— `deletableIgnoringGeometry:93` 与 `editableIgnoringGeometry:80` 都已经带 `!d.locked` 分量。PR-1 只需**加测试锁住它**（此前 `locked` 在本构建里产不出来，这两条分量从未被真正执行过 —— 正是「全是拒了的套件」那族假绿的温床，见 §1.6 N-D）。

### 1.5 D73　N14h 断言翻转（1b-i 明确交接的必做项）

`Tests/.../Drawing/DrawingEditDurabilityGateTests.swift:178` 的 `lockedFutureDataLineIsCurrentlyUnrecoverable` 钉的是「locked + 未来数据的线今天既改不动也删不掉」这条已接受残留。其头注逐字交接：

> 落地 `setDrawingLocked(id:locked:)` 时，这条线一旦被解锁，`deleteDrawing(id:)` 就该对它放行 —— **本测试「delete == false」那半条断言必须翻转成 true**，否则说明 `setDrawingLocked` 没把 `locked` 门在下游落到实处。

PR-1 必须改这个测试：保留「锁着时改不动、删不掉」两条断言，**追加**「调 `setDrawingLocked(id:, locked: false)` → 再 `deleteDrawing(id:)` == **true** → 线真的没了 → `drawingsRevision` 递增」。
测试名与头注同步改写，不再自称「已知死角（不修）」。

⚠️ 但 **N14h 的另一半仍是残留、PR-1 不假装修好了**：解锁后这条线**仍然改不动样式**（D61 门还在 `updateDrawingStyle` 上）。用户对这类线的处置通道是「整条删掉」，不是「改它」。这是 D61 的**保护**而非缺陷（1b-i spec §8 #6 原文），PR-1 不动它。

### 1.6 PR-1 必须存在的负向 / 举证测试

**N-A　raw-preserving 举证（本 PR 的地基，必须第一条写）**
构造一条带**未来顶层字段**（`futureX`）与一条带**未来枚举值**（`colorToken:"futureNeon"`）的 `.known` 线 → `setDrawingLocked(locked: true)` → 走完整保存路径（`reconciled` → `encoded()`）→ 断言产物字节里 **`futureX` 仍在、`futureNeon` 仍在，且 `locked` 已变成 `true`**。
**变异验证**：删掉 `Models.swift:370` 的 `lhs.locked == rhs.locked` 分量 → 本条必须变红（证明它真的走到了 merge 路径，而不是碰巧过）。

**N-B　解锁是唯一通路**
`updateDrawingStyle` 对 locked 线恒返回 `false` 且不改 `drawingsRevision`（回归保护 D60）；解锁只能经 `setDrawingLocked`。
**并加源码守卫**：`Sources/` 中除 `setDrawingLocked` 外**零处**写 `locked:` 为非拷贝值。守卫必须**剥注释剥字面量**后再断言（`feedback_source_guard_text_source_discipline`），并配一条反向自检（故意加一处写入 → 守卫必须变红）。

**N-C　门列表逐条**
⓪ 复盘模式下 `setDrawingLocked` 恒 `false`、`drawings` 与 `drawingsRevision` 均不动；
① 空 id → `false`；重复 id → `false`（两条线同 id，断言**两条都没被改**）；
**并配一条正向档**：健康输入（训练模式、id 唯一非空、未锁）→ **必须返回 `true` 且 `locked` 真的变了**。
⚠️ 这条正向档不可省 —— 一族全是「应该被拒绝」的断言，配上一个恒返回 `false` 的实现也会全绿（`feedback_all_reject_suite_masks_always_throwing_guard`，本仓真栽过）。

**N-D　置灰分量首次真执行**
`editableIgnoringGeometry` / `deletableIgnoringGeometry` 的 `!d.locked` 分量此前从未被执行过（本构建产不出 `locked == true`）。
各写一条：锁定选中线 → `styleControlsEnabled == false` 且 `deleteButtonEnabled == false`；解锁 → 两者恢复 `true`。
**变异验证**：分别删掉那两处 `!d.locked` → 对应那条必须变红。

**N-E　幂等不触发 autosave**
已锁的线再调 `setDrawingLocked(locked: true)` → 返回 `true`、`drawingsRevision` **不变**、`drawings` 逐字段不变。

**N-F　落盘往返（接 1b-i 的 D56 那一组）**
`setDrawingLocked` 各写一条「调用 → `drawingsRevision` **严格递增 1** → autosave 被触发 → 重新加载后仍是锁定态」。
**并含续局 replay 那条**（split addendum §7.3 #3）：`resumePendingReplay` 续局后**只**锁定一条线（不推 tick / 不交易 / 不增删 / 不切周期）→ `saveProgress` 真的写盘。

**N-G　唯一调用点**
源码守卫：`Sources/` 中 `setDrawingLocked(` 的调用点**恰好 1 处**，且在 `DrawingEditRouter.swift`（同 D62 对另两个 API 的既有守卫，扩进同一族）。

**N-H　前作回归**
1b-i 的 D33 / D34 / D37 / D49 / D63 / D64 / D65 测试与 1a-i 的 D29 / D35 测试在本 PR 仍全绿。

### 1.7 PR-1 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看下面那行按钮 | 一共 **3 个**：类型键、🔓 锁、🗑 垃圾桶。（↩ 和 ↪ **这一版还没有**，看不到是对的） | |
| 2 | 什么都没选中时，看 🔓 和 🗑 | 两个都是灰的，点了没反应 | |
| 3 | 把类型行的图标点熄灭（进入选择态），单击一条已经画好的线 | 线变蓝（选中）；🔓 和 🗑 都从灰变亮 | |
| 4 | 选中一条线，点 🔓 | 图标变成**闭着的锁** 🔒；🗑 变灰 | |
| 5 | 接上一条：点底栏①「类型」键把常驻样式面板展开（若已展开就直接看） | 面板里所有样式控件都是灰的，改不动<br>⚠️ 这里**不是**长按弹卡片——长按卡片在 1a-iii 已被常驻面板取代，面板由①键开/合 | |
| 6 | 接上一条：再点一次 🔒 | 图标变回**开着的锁** 🔓；🗑 恢复可用；样式面板恢复可改 | |
| 7 | 锁定一条线之后，直接**杀掉 App**（上滑关掉），重新打开、续这一局 | 那条线仍然是锁定状态（选中它，🗑 是灰的） | |
| 8 | 进「再次训练」，画**一条线**，退出这一局；从历史弹窗**续这一局**，只把那条线锁上，**立刻杀掉 App**，再续这一局 | 那条线仍然是锁定状态<br>注：全新开的一局里没有任何已有线可锁，必须先画一条、退出、再续局 | |
| 9 | 锁定一条线，然后平移图表让这条线滑出屏幕（这个价位离开可见价格区间） | 🔒 和 🗑 都变灰 | |
| 10 | 进复盘模式看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 11 | 「再次训练」（replay）模式下重做第 3～6 条 | 行为与训练模式完全一致 | |

---

## 2. PR-2：撤销 / 前进

### 2.1 D74　撤销栈存放在 `TrainingEngine`，生命周期由 UI 驱动

**存储在引擎**（不是 `DrawingSession`）。

理由：
1. 撤销必须在 `drawings` 数组上**按精确下标**操作（D25：数组序 = z-order），那是引擎的私有存储。
2. **入栈点必须与写入点同处**。四个写入 API 全在引擎里；把入栈放在引擎，「做了写入却忘了入栈」在结构上不可能发生。放 UI 层则每个调用点都要记得入栈 —— 1b-i 的 D56 教训（「每一个改 `drawings` 的 API 都要 `drawingsRevision += 1`，忘一个就静默丢 autosave，且没有任何编译期保护」）已经证明「靠调用方记得」是错的。

**生命周期由 UI 显式驱动**（D25：进画线模式建栈、退出清空）：引擎另出 `clearDrawingUndoStack()`，由画线模式的进入 / 退出各调一次。存储在引擎、生命周期在 UI，两者不矛盾。

### 2.2 D75　入栈点 = 四个引擎写入 API 各自的成功路径

| 动作 | 触发 API | before | after | index |
|---|---|---|---|---|
| 画线 | `appendDrawing` | `nil` | 新线 | 追加后的下标 |
| 删线 | `deleteDrawing(id:)` | 旧线 | `nil` | 删除前的下标 |
| 改样式 | `updateDrawingStyle` | 旧对象 | 新对象 | 该线下标 |
| 锁定 / 解锁 | `setDrawingLocked` | 旧对象 | 新对象 | 该线下标 |

**只有真的改了 `drawings` 才入栈** —— 与 `drawingsRevision += 1` **同一个位置、同一个条件**。D69 的幂等路径（`locked` 未变）既不递增 revision 也**不入栈**。

栈深度 1：新动作直接**覆盖**栈顶，并把 redo 位清空（D25：做了新动作 → ↪ 置灰）。

### 2.3 D76　undo / redo 的执行 = 专用引擎入口，不复用四个写入 API

`undoDrawing() -> Bool` / `redoDrawing() -> Bool`，按 D25 的模板在**同一个 index** 上操作：

| 动作 | undo | redo |
|---|---|---|
| 画线 | `remove(at: index)` | `insert(after, at: index)` |
| 删线 | `insert(before, at: index)` | `remove(at: index)` |
| 改样式 | `drawings[index] = before` | `drawings[index] = after` |
| 锁定 | `drawings[index] = before` | `drawings[index] = after` |

**为什么不复用四个写入 API**（这是本 PR 最容易做错的一处）：
- `insert(at:)` 根本不存在 —— `appendDrawing` 只能 append，用它撤销删除会把线放到数组末尾 = **z-order 变了**，之后在同一位置单击选中的不再是原来那条（D25 / D33 / D40 逐字点名的正是这个错误）。
- `updateDrawingStyle` 会被 D60 的 locked 门与 D61 的 raw-aware 门挡住 → 「撤销一条带未来数据线的锁定」直接走不通。

**那些门为什么可以不走**：它们防的是**外部传进来的坏数据**；而 `before` / `after` 是引擎自己刚才吐出来的、**已经过完整门列表**的快照。`undoDrawing` / `redoDrawing` **只接受来自撤销栈的快照，不接受任何外部参数** —— 这个签名本身就是它的信任边界。

两者都 `drawingsRevision += 1` 并照常落盘。
**redo 恒用 `after` 快照，绝不从当前默认样式 / 当前选中态重算**（D25 / split addendum §7.3 #6c）。

### 2.4 D77　undo / redo 之后的选中态

| 情形 | 选中态 |
|---|---|
| undo「画线」（线消失） | 若消失的正是选中线 → **清空选中**；否则不变 |
| undo「删线」（线回来） | **不自动选中**（与 D37「新提交的线不自动选中」一致） |
| undo / redo「改样式」「锁定」 | **不变**（对象还在原下标，身份没变） |
| redo 各情形 | 与上表对称 |

实现上**不新写一套判据**：`undoDrawing` / `redoDrawing` 返回后由路由调用已有的 `syncSelectionByState`（`DrawingEditRouter.swift:160`）——它的判据「选中 id 不在 `visibleDrawings` 里就清空」已经把上表四行全覆盖，没有第二处可以写漏（D64）。

### 2.5 D78　④↩ ⑤↪ 的置灰判据

| 键 | 亮的条件 |
|---|---|
| ④↩ | 撤销栈**非空**（栈顶未被撤销） |
| ⑤↪ | 存在一个**已被撤销**的栈顶（可前进） |

**与选中态无关**、**与几何无关** —— 撤销是会话级操作，不需要选中任何线，也不需要那条线此刻看得见。
这是本 PR 里唯一**不**共享 `selectionGeometryVisible` 的底栏键，属刻意不对称，需在实现处留注释说明，防后人"顺手统一"。

### 2.6 PR-2 必须存在的负向测试

**N-I　保序（D25 / codex R25-high 专项，不可省）**
同一价位依次画三条重合的线 A→B→C（数组序 `[A,B,C]`）→ 删**中间的 B** → ↩ → 断言两件事：① `drawings` 恰为 `[A,B,C]`（B 回到**下标 1**）；② 在该价位单击，选中的仍是 **C**。再 ↪ → 数组恰为 `[A,C]`。
**不得**只断言「B 回来了 / 条数是 3」—— 那样 `append` 实现也能过。

**N-J　redo 不漂移（codex R29-high 专项，改样式 + 锁定各一条）**
改样式：把一条线改成**红色** → ↩ → **在样式面板把默认色改成绿色、并另选中别的线** → ↪ → 断言那条线是**红色**（`after` 快照），不是绿色也不是原色。
锁定：锁定一条线 → ↩ → 中途改动别处 → ↪ → 断言回到**锁定**态。
**不得**只测「↩ 后 ↪ 能回来」—— 那在「redo 从当前态重算」的错误实现下也会过。

**N-K　栈深度 1**
连点两次 ↩ 只回退一步；↪ 只前进一步，第二次无效果（`drawings` 与 `drawingsRevision` 都不动）。

**N-L　栈生命期**
退出画线模式再进入 → ↩ / ↪ 均不可用（栈已清空）；做新动作后 ↪ 不可用。

**N-M　四类动作往返 + dirty 信号（接 D56 那一组）**
画线 / 删线 / 改样式 / 锁定各一条「做 → ↩ 复原 → ↪ 重做」；且 `undoDrawing` 与 `redoDrawing` **各**写一条「调用 → `drawingsRevision` 严格递增 1 → autosave 被触发 → 重新加载后结果正确（redo 落盘的是 `after`）」。
⚠️ 1b-i 之后已经没有 `.count` 兜底，四类一个都不能漏（D30 / codex R28-high）。

**N-N　幂等 / 空栈不产生副作用**
空栈时调 `undoDrawing` / `redoDrawing` → 返回 `false`、`drawings` 与 `drawingsRevision` 均不动、**不触发 autosave**。
**并配正向档**：非空栈调用必须返回 `true` 且 `drawings` 真的变了（同 N-C 的理由）。

**N-O　撤销不绕过 review 门**
复盘模式下 `undoDrawing` / `redoDrawing` 恒 `false`（D34 纵深防御；栈本就不该在复盘里建起来，但引擎侧仍要有门）。

**N-P　前作回归**
PR-1 的 N-A～N-H 与 1b-i / 1a-i 的既有测试在本 PR 仍全绿。

### 2.7 PR-2 非程序员验收清单

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看下面那行按钮 | 现在是 **5 个**：类型键、🔒、🗑、↩、↪ | |
| 2 | 刚进画线模式，什么都还没做，看 ↩ 和 ↪ | 两个都是灰的 | |
| 3 | 画一条线，看 ↩ | ↩ 变亮 | |
| 4 | 点 ↩ | 刚画的线消失了；↪ 变亮 | |
| 5 | 点 ↪ | 线又回来了 | |
| 6 | 删掉一条线，点 ↩ | 线回来了 | |
| 7 | 接上一条：再点 ↪ | 线又没了 | |
| 8 | 改一条线的颜色，点 ↩ | 颜色变回改之前 | |
| 9 | 锁定一条线，点 ↩ | 变回没锁定（🗑 恢复可用） | |
| 10 | 在**同一个价位**从上往下依次画三条重合的线（叫它们 A、B、C），把**中间那条 B** 删掉，再点 ↩ | B 回来了 | |
| 11 | 接上一条：切到选择态，在那个价位单击一下 | 选中的是**最后画的 C**，和删 B 之前一模一样——不是刚撤销回来的 B | |
| 12 | 连点两次 ↩ | 只回退一步（第二次没反应） | |
| 13 | 连点两次 ↪ | 只前进一步（第二次没反应） | |
| 14 | 撤销之后再画一条新线，看 ↪ | ↪ 变灰（做了新动作，"前进"就失效了） | |
| 15 | 改一条线的颜色 → 点 ↩ → 在样式面板把默认颜色改成**绿色** → 再点 ↪ | 那条线回到**你之前改的那个颜色**，**不是**绿色 | |
| 16 | 点「退出」离开画线模式，再进来，看 ↩ / ↪ | 两个都是灰的（撤销记录不跨会话保留） | |
| 17 | 撤销一条线之后**杀掉 App**，续这一局 | 撤销的结果被保留了（那条线确实不在）；↩ / ↪ 都是灰的 | |
| 18 | 进复盘模式看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 19 | 「再次训练」（replay）模式下重做第 3～9 条 | 行为与训练模式完全一致 | |

---

## 3. 契约

**两个 PR 均为纯 UI / 引擎层：`CONTRACT_VERSION` 保持 `1.12`、`user_version` 保持 `7`、零迁移。**

依据：`locked` 字段自 P1a 的迁移 0009 起就已在 `style_json` 列里往返（`LossyDrawingArray.knownDiskKeys` 含 `"locked"`），本 spec 不新增任何字段、不扩展任何枚举值域、只写入 `.horizontal`。撤销栈**不落盘**（D25：退出画线模式即清空），不进契约。

---

## 4. 交接（P1c / P5 / P6）

- **P1c**：`undoDrawing` / `redoDrawing` 目前假设一次动作只影响**一条**线。P1c 的折线画制中临时 4 键（`[回退][前进]` 作用于**锚点**而非整条线）是另一套语义，**不得**复用本 spec 的撤销栈。
- **P5**：复盘获得编辑能力时，`reviewDrawings` 需要等价的 revision 触发器（D56）与等价的撤销栈；且选中必须扩展为 `(layer, id)` 二元组并按层门控（D34 / split addendum §9）。
- **P6**：`defaultStyle` 持久层零引用（不落盘），杀 App 重开后「下一条线的默认」回出厂值。**是已知的 P6 范围，不是本 spec 的回归。**
- **残留（本 spec 不修，明确记录）**：带未来数据的线解锁后仍**改不动样式**（D61 门保留在 `updateDrawingStyle` 上）。用户对这类线的处置通道是整条删除。P3 / 未来版本认识那些值后自然解禁。
