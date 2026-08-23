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
| **PR-1　锁定** | 底栏 **②🔒** + `setDrawingLocked` 引擎 API + 路由与可用性谓词 + 锁定线的置灰传播 + D80「内容未变 = 零副作用」 | ~140 行 |
| **PR-2　撤销** | 底栏 **④↩ ⑤↪** + 撤销栈（深度 1）+ 四类动作的 undo / redo + D79 的双层陈旧栈防护 | ~220 行 |

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

新增引擎 API。

> ⚠️ **不变量的作用域必须写准**（codex R1-F1，high，**已核实为真**）。
> 原稿写的是「`Sources/` 里**唯一**被允许改 `locked` 的入口」，而 §2.3 的 D76 又要求 undo / redo 用
> `drawings[index] = before/after` 恢复快照——快照里**含 `locked`**。两句话不可能同时成立：
> 严格执行前者会让 PR-2 的「撤销锁定」无法实现；而把 undo 改成去调 `setDrawingLocked`，
> 又会踩到**入栈重入**（撤销这个动作本身又入一次栈）和 D69 的幂等零递增路径。
>
> **修正后的不变量（PR-1 / PR-2 共同遵守）**：
> 1. **用户发起的**锁定切换，唯一入口是 `setDrawingLocked`；
> 2. `undoDrawing` / `redoDrawing` 是**仅有的第二个**能改 `locked` 的入口，且受三条硬约束限制
>    （见 D79）：只从**内部快照**恢复、**不接受任何外部参数**、**不入栈**；
> 3. **`locked` 与 `drawings` 是两个不同大小的写入面，必须分开陈述**（codex R6-F1，**已核实为真**）：
>    - **能改变 `locked` 值的函数恰好两个**：`setDrawingLocked`（语义性写入）与 `applyUndoEntry`（整对象快照恢复，`undoDrawing` / `redoDrawing` 共用它这一个私有单点）。除这两个外，`Sources/` 中零处改 `locked`。
>    - **`drawings` 数组的写入面是另一个更大的集合**（`appendDrawing` / `deleteDrawing(id:)` / `deleteDrawing(at:)` / `updateDrawingStyle` / `setDrawingLocked` / `applyUndoEntry` / `init` / `injectDrawingsForTesting`）。
>
> ⚠️ 原稿第 3 条写成「除这三个函数外零处直接改 `drawings` 数组」，**这句话是假的** —— 四个既有写入 API 都改 `drawings`，本 spec 后面又把它们列进白名单，等于自相矛盾。照它去写守卫，只会得到一条在合法代码上就红、然后被临时放宽的守卫 —— 正是本 spec 要防的那种漂移。
>
> **唯一权威清单 = D79 第一层那张表**（§2.3b）。PR-1 的 N-B 与 PR-2 的 D79 守卫**都从那一张表派生，不各自另立一份**。

```swift
// 访问级别必须是 internal —— 不写 public，且这一条要被守卫钉住（见 §1.6 N-G）
@discardableResult
func setDrawingLocked(id: DrawingID, locked: Bool) -> Bool
```

⚠️ **`internal` 是 trust boundary 的一部分，不是风格偏好**（codex R5-F1，high，**已核实为真**）。
既有四个写入 API（`deleteDrawing(at:):1089` / `deleteDrawing(id:):1109` / `appendDrawing:1129` / `updateDrawingStyle:1156`）**全是 internal**，本 API 沿用同一形状。但原稿只把它写在签名里、没写成**受测的不变量**，而 N-G 只数调用点 —— **一个 `public setDrawingLocked` 完全能通过调用点守卫**，同时让 App 层任何调用方按 id 直接改任意线的 `locked`：不需要选中、不需要几何可见、绕过 D71 的全部路由门，然后被 autosave 固化。那正是 D51/D62 当初替删除 / 改样式关掉的同一类洞。

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
**并加源码守卫（按 D69 修正后的第 3 条不变量写，不是按「唯一入口」那句写）**：

守卫是**结构计数**，不是禁词黑名单（`feedback_source_guard_text_source_discipline`）。

⚠️ **作用域必须先收窄，否则守卫在现有合法代码上就是红的**（codex R3-F3，medium，**已核实为真**）。全 `Sources/` 的文本计数会撞上三类合法存在：
- `DrawingObject.withStyle` 里的 `locked: locked`（**拷贝直传**，该函数明写「不碰 locked」）；
- `routeDrawingCommit` 里的 `locked: drawing.locked`（同样是拷贝直传）；
- `PreviewFakes/InMemoryFakes.swift:88` 的 `drawings[id] = drawingsIn` 与 `Render/KLineRenderState.swift:48` 的 `self.drawings = drawings` —— **同名但完全无关**的另一个 `drawings`。

守卫若在这些上面变红，实施者只会临时放宽它，那它就再也保护不了任何东西。

判据两条，缺一不可：

1. **`locked` 的**语义性**写入**：作用域限 **`TrainingEngine.swift`**，判据 = 形如 `locked: <表达式>` 且该表达式**不是**从同一对象拷贝直传（`locked` / `old.locked` / `d.locked` / `drawing.locked` 这一族）的位置 —— 全文件**恰好 1 处**，在 `setDrawingLocked` 里。
   **拷贝直传形态必须显式列成白名单并各配一条自检**（断言它们**不**触发守卫），否则守卫会在 `withStyle` / `routeDrawingCommit` 上误红。
2. **`drawings` 数组的结构性改动**：作用域限 **`TrainingEngine.swift` 里 `TrainingEngine` 自己那个 `drawings` 存储属性**（不是全 `Sources/` 的任意同名变量 —— 见上面第三类误报）。
   判据 = `drawings[` 下标赋值 / `drawings.remove` / `drawings.insert` / `drawings.append` 的出现总数**恰好等于**白名单函数里的出现数。**多一处即红。**
   ⛔ **PR-1 这条判据里不含整体赋值 `drawings = `**（codex R4-F3，medium，**已核实为真**）：现树上 `init:178` 的 `self.drawings = seededLossy.drawings` 与 `injectDrawingsForTesting:1452` 的 `drawings = ds` 都是合法的整体赋值，而它们要到 PR-2 的 D79 表里才被分类。把整体赋值放进 PR-1 的判据，**守卫在功能还没写之前就是红的** —— 实施者只会顺手放宽它，那它就再也保护不了 locked 写入边界。
   整体赋值统一由 **PR-2 的 D79 穷尽性判据**接管（那张表把 `init` 与 `injectDrawingsForTesting` 都显式分类了），两条判据**互不重叠**。
   - **PR-1 的白名单从 D79 那张唯一权威表派生，不另立一份**（codex R6-F1）= 表中做「下标 / 增删」的那些行：`appendDrawing` / `deleteDrawing(at:)` / `deleteDrawing(id:)` / `updateDrawingStyle` / `setDrawingLocked`（`init` 与 `injectDrawingsForTesting` 是整体赋值，按下一段不在 PR-1 判据内）。
   - **PR-2 落地时把本条升级为 D79 第一层那张表的穷尽性判据**（覆盖面从「下标 / 增删」扩到**全部** `drawings` 写入点，含整体赋值与 `injectDrawingsForTesting`），并把 `applyUndoEntry` 加进白名单。⚠️ **两条守卫必须合并成一条，不许并存** —— 同一族判据留两份、迟早漂移（`feedback_fix_the_whole_predicate_family_not_the_reported_site`）。⚠️ 白名单是**具名函数**，不许用 `*Drawing*` 之类通配（通配会让下一个新写入口静默溜过，`feedback_parallel_session_branch_contamination` 的 G6 教训）。

⚠️ 第 2 条是 codex R1-F1 逼出来的：只写第 1 条的话，`drawings[index] = before`（整对象赋值，字面上不含 `locked:`）会**从守卫底下溜过去**，而它恰恰是改 `locked` 的第二条路径 —— 守卫比它声称的不变量弱，正是本仓反复踩的判据漂移。

守卫必须**剥注释剥字面量**后再断言，并各配一条**反向自检**（分别故意加一处 `locked:` 写入、一处 `drawings[i] =` 赋值 → 对应那条守卫必须变红）。

**N-C　门列表逐条**
⓪ 复盘模式下 `setDrawingLocked` 恒 `false`、`drawings` 与 `drawingsRevision` 均不动；
① 空 id → `false`；重复 id → `false`（两条线同 id，断言**两条都没被改**）；
**并配一条正向档**：健康输入（训练模式、id 唯一非空、未锁）→ **必须返回 `true` 且 `locked` 真的变了**。
⚠️ 这条正向档不可省 —— 一族全是「应该被拒绝」的断言，配上一个恒返回 `false` 的实现也会全绿（`feedback_all_reject_suite_masks_always_throwing_guard`，本仓真栽过）。

**N-D　置灰分量首次真执行**
`editableIgnoringGeometry` / `deletableIgnoringGeometry` 的 `!d.locked` 分量此前从未被执行过（本构建产不出 `locked == true`）。
各写一条：锁定选中线 → `styleControlsEnabled == false` 且 `deleteButtonEnabled == false`；解锁 → 两者恢复 `true`。
**变异验证**：分别删掉那两处 `!d.locked` → 对应那条必须变红。

**N-E　幂等不触发 autosave（D80，四个 API 各一条 —— 不是只测锁定）**
- 已锁的线再调 `setDrawingLocked(locked: true)` → 返回 `true`、`drawingsRevision` **不变**、`drawings` 逐字段不变。
- **同样式再调 `updateDrawingStyle`**（把当前正在用的那套样式原样传回去）→ 返回 `true`、`drawingsRevision` **不变**、不触发 autosave。
  ⚠️ 这是对已合并 API 的**有意行为改动**（D80），本条即其回归声明。
  **变异验证**：把 `before == after` 那道判据去掉 → 本条必须变红。
- 并复核 1b-i 的 N2（`TrainingEngineDrawingSessionTests.swift:812`）在改动后仍绿；若它其实传的是同样式，则它此前就是恒真的，须一并修。

**N-F　落盘往返（接 1b-i 的 D56 那一组）**
`setDrawingLocked` 各写一条「调用 → `drawingsRevision` **严格递增 1** → autosave 被触发 → 重新加载后仍是锁定态」。
**并含续局 replay 那条**（split addendum §7.3 #3）：`resumePendingReplay` 续局后**只**锁定一条线（不推 tick / 不交易 / 不增删 / 不切周期）→ `saveProgress` 真的写盘。

**N-G　唯一调用点 + 访问级别（两条判据，缺一即漏）**
1. **唯一调用点**：`Sources/` 中 `setDrawingLocked(` 的调用点**恰好 1 处**，且在 `DrawingEditRouter.swift`（同 D62 对另两个 API 的既有守卫，扩进同一族）。
2. **非 public**（codex R5-F1）：`setDrawingLocked` 的声明**不得**带 `public` / `open`。守卫在 `TrainingEngine.swift` 上断言其声明行匹配 internal 形态，配反向自检（给它加上 `public` → 守卫必须变红）。
⚠️ 只有第 1 条**挡不住**这个洞：`public` 声明的调用点数照样是 1，守卫全绿，但包外调用方已经能绕过整条路由。

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

### 2.1 D74　撤销栈存放在 `TrainingEngine`，生命周期也由引擎的 D45 收口点驱动

**存储在引擎**（不是 `DrawingSession`）。

理由：
1. 撤销必须在 `drawings` 数组上**按精确下标**操作（D25：数组序 = z-order），那是引擎的私有存储。
2. **入栈点必须与写入点同处**。四个写入 API 全在引擎里；把入栈放在引擎，「做了写入却忘了入栈」在结构上不可能发生。放 UI 层则每个调用点都要记得入栈 —— 1b-i 的 D56 教训（「每一个改 `drawings` 的 API 都要 `drawingsRevision += 1`，忘一个就静默丢 autosave，且没有任何编译期保护」）已经证明「靠调用方记得」是错的。

**生命周期也在引擎，不经过 UI**（codex R3-F1，high，**已核实为真**）。

⚠️ 原稿写的是「生命周期由 UI 显式驱动：由画线模式的进入 / 退出各调一次 `clearDrawingUndoStack()`」。**这条是错的**，实测：

- 画线模式的开 / 关本来就是引擎的事，`beginDrawingSession`（`TrainingEngine.swift:1351`）/ `endDrawingSessionIfActive`（`:1370`）是代码里明写的 **D45 单一收口点**；
- 而 `endDrawingSessionIfActive` 被**引擎内部六处**调用：`:442`（半武装 fail-closed 回滚）、`:468`、`:532`（**`advanceAndAccount` = 下单成交**）、`:1276`（`commitDrawing`）、`:1284`（`cancelDrawing`）、`:1331`（`toggleDrawingMode`）。
  ⚠️ **只核实"有六个调用点"不够，必须逐个核实语义** —— 本 spec 在 R3 就栽在这里：当时把 `.periodComboSwitched` 也当成了退出路径，R4 才查出 `switchPeriodCombo` 末尾是 `restoreDrawingSessionAfterPeriodChange()`、**刻意保留**会话（详见本节末的 ⛔ 段）。

⇒ **画线模式完全可以在 UI 一无所知的情况下结束。** 靠 UI 调清栈，等于把「撤销栈不跨会话」这条 D25 契约挂在一条随时会被绕过的路径上：下单一次 → 会话已结束 → 但栈还在 → 若 `drawings` 恰好没变，D79 第二层的身份校验**全都通过** → 用户在下一个会话里点 ↩，撤掉的是**上一个会话早已提交的动作**，还会被 autosave 固化。

**修正后的规则**：清栈挂在**会话状态真的翻转**的那一刻，而不是挂在某几个函数名上。

实测 `drawingSession.activate(` / `drawingSession.deactivate(` 在 `Sources/` 中恰好 **4 处、分布在 3 个函数**里：

| 位置 | 函数 | 性质 |
|---|---|---|
| `TrainingEngine.swift:1362` `activate` | `beginDrawingSession` | 开会话 |
| `:1359` `deactivate` | `beginDrawingSession` 的 fail-closed 回滚 | 开失败 → 等于没开 |
| `:1378` `deactivate` | `endDrawingSessionIfActive` | 正常结束 |
| `:1321` `deactivate` | **`cancelDrawingAllPanels`** | **真实拆除路径**（public，既有测试用它退出画线模式）|

⚠️ **`cancelDrawingAllPanels` 是第三个函数，原稿漏了它**（codex R4-F2，high，**已核实为真**）：只在 begin / end 清栈会让它退出后残留一个陈旧栈；而原稿那条「activate/deactivate 只准出现在 begin/end 内」的守卫会直接在 `:1321` 这行**既有合法代码**上误红。

**规则**：清栈必须绑在 **`drawingModeActive` 真的翻转**的那一刻（`false→true` 或 `true→false`），**不是**绑在"进了某个函数"。

⚠️ **「函数里有 activate/deactivate 就得有 clearDrawingUndoStack」这条共处判据不够**（codex R6-F2，**已核实为真**）：`beginDrawingSession`（`:1351`）第一行就是 `guard DrawingToolType.implemented.contains(tool) else { return }` —— 一条**没有任何状态翻转**的早退；它还是 `public`，会话已经开着时再调一次也不构成翻转。实施者只要把 `clearDrawingUndoStack()` 放在函数入口，就能满足共处判据，却在这两种情况下**悄悄抹掉一条有效的撤销记录**——用户什么都没做，↩ 就灰了。

**落地形态**：清栈与 `drawingSession.activate(` / `deactivate(` **同一条语句序列、同一个分支**内（即：真的调了 activate/deactivate 才清），而不是函数入口。

**守卫两条并用**（单靠任一条都能被绕过）：
1. **共处**：凡含 `drawingSession.activate(` 或 `drawingSession.deactivate(` 的函数，必定含 `clearDrawingUndoStack()` —— 保证将来第四条翻转路径不会漏掉清栈。当前应命中 `beginDrawingSession` / `endDrawingSessionIfActive` / `cancelDrawingAllPanels` 三个函数。
2. **行为**（比守卫更硬，见 N-Q4/N-Q5）：被拒的 begin 与冗余的 begin-while-active **必须保留栈** —— 这条把「入口清栈」那种实现直接测红。

判据钉在**状态翻转**上，而不是钉在一份会过期的函数名单上（`feedback_fix_the_whole_predicate_family_not_the_reported_site`）。

**并加测试**（N-Q，见 §2.6）：`.tradeTriggered`（下单成交）与 `cancelDrawingAllPanels` 两条**非 UI 触发**的退出路径各一条，断言栈被清空。

> ⛔ **切周期 `.periodComboSwitched` 不属于退出路径 —— 原稿把它列进来是错的**（codex R4-F1，high，**已核实为真**）。
> `switchPeriodCombo`（`TrainingEngine.swift:391`）末尾调的是 `restoreDrawingSessionAfterPeriodChange()`（`:416`），其文档 `:419-421` 逐字写着：「**只丢 pending 锚**…保留 `activeDrawingTool` 与 `drawingModeActive` —— **绝不**调 `deactivate()`」。既有测试 `realPeriodChangeDiscardsOnlyPendingAnchors` 也断言切周期后会话与两面板**仍在**画线模式。
> 照原稿实现只有两个结果：要么把 1a-iv 刚放开的「画线模式内切周期」焊死（功能回归），要么在用户**还在同一个会话里**时静默丢掉一条有效的撤销记录。
> **正确语义：切周期后撤销栈原样保留**（同一个会话没结束）。这一条要写成**正向**测试，见 N-Q3。

### 2.2 D75　入栈点 = 四个引擎写入 API 各自的成功路径

| 动作 | 触发 API | before | after | index |
|---|---|---|---|---|
| 画线 | `appendDrawing` | `nil` | 新线 | 追加后的下标 |
| 删线 | `deleteDrawing(id:)` | 旧线 | `nil` | 删除前的下标 |
| 改样式 | `updateDrawingStyle` | 旧对象 | 新对象 | 该线下标 |
| 锁定 / 解锁 | `setDrawingLocked` | 旧对象 | 新对象 | 该线下标 |

**只有真的改了 `drawings` 才入栈** —— 与 `drawingsRevision += 1` **同一个位置、同一个条件**。

### 2.2b D80　四个写入 API 统一「内容未变 = 零副作用」（codex R3-F2，high，**已核实为真**）

> ⚠️ **本决策虽写在 PR-2 章节（因为它的动机来自撤销栈），但落地在 PR-1** —— PR-2 的入栈条件依赖它。
> PR-1 的举证在 §1.6 N-E，PR-2 的下游断言在 §2.6 N-R。

**缺陷**：`updateDrawingStyle`（`TrainingEngine.swift:1178-1180`）在 `withStyle` 成功后**无条件** `drawingsRevision += 1`，**没有** `updated != old` 检查。而常驻样式面板的控件在「当前值」上**仍然可点**（1a-iii 的既有形态）。于是：

> 用户改了一条线的颜色（栈里存着这次真编辑）→ 手指顺手又点了一下**已经选中的那个颜色**
> → `withStyle` 成功、`before == after` → 若 PR-2 把入栈挂在这条成功路径上，
> **唯一那条有用的撤销记录被一个 no-op 冲掉，之前那次真编辑再也撤不回来。**

深度 1 的栈让这个后果不可逆 —— 这不是"多存一条废记录"，是**用户真编辑的丢失**。

**修正（统一到四个 API，不是只补 `updateDrawingStyle`）**：

> **`before == after` ⇒ 返回 `true`、`drawingsRevision` 不递增、不入栈、不触发 autosave。**

判据用 `DrawingObject.==`（它含全部 18 个字段中除 `id` 外的内容分量，`locked` 也在内，见 `Models.swift:366-375`）。

**为什么统一而不是只挡入栈**：
1. D69 已经给 `setDrawingLocked` 定了幂等零递增。只补 `updateDrawingStyle` 的入栈、不管它的 revision，会留下「锁定幂等不递增、样式幂等递增」的不对称 —— 同族判据留两套形状，本仓的漂移历史说明它一定会咬人。
2. 统一之后 **`drawingsRevision` 递增 ⟺ `drawings` 内容真的变了** 成为一条干净的不变量，而入栈条件就**恰好等于**它。两者同条件同位置 ⇒ 「入栈与 revision 不同步」这个坏状态**不可表达**，而不是靠实施者两处都记得写。

⚠️ **这是对已合并 API（`updateDrawingStyle`）的有意行为改动**，PR-1 就要落地（PR-2 的入栈依赖它）。必须配一条**回归测试**声明该改动，并复核 1b-i 的 N2（`TrainingEngineDrawingSessionTests.swift:812`「revision +1」）—— 它断言的是**真改样式**的场景，不受影响；若实测发现它其实传的是同样式，则该测试本身此前就是恒真的，须一并修。

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

### 2.3b D79　陈旧下标是**崩溃级**缺陷 —— 双层防护（根因 + 兜底），不是只加校验

codex R1-F2（high，**已核实为真**）：原稿的 D76 直接在存下来的 `index` 上做 `remove(at:)` / `insert(at:)` / 下标赋值，**一处边界与身份校验都没有**。而 D74 把栈的生命周期交给了 UI 驱动 —— 只要有一条路径漏了清栈（模式切换、续局重载、任何把 `drawings` 整体换掉的加载路径），栈里就留着一条对不上号的记录。

**后果比"结果不对"严重**：Swift 数组越界是 **trap（进程直接崩）**，`do/catch` 接不住；不越界但身份对不上时，则是**删掉 / 改写了另一条线**，然后 `drawingsRevision += 1` 让这个坏状态**被 autosave 固化**。

按本仓纪律「修 symptom 会挪动失败面 → 必须让坏状态不可表达」（`feedback_internal_review_misses_bad_data`），**两层都要，不许只做兜底那层**：

**第一层（根因）：把 `drawings` 的写入面穷尽分类，每一类都必须对栈表态。**

⚠️ 本层的原稿要求「`drawings` 被整体替换时清栈」，并用 `resumePendingReplay` 举证 —— **两处都错**（codex R2-F1，high，**已核实为真**）：
`resumePendingReplay`（`TrainingSessionCoordinator.swift:851`）走的是 `TrainingEngine.make(...)`（`:919`），**造的是一个全新引擎**，新引擎的栈本来就是空的 → 那条测试恒过、证明不了任何事。而「所有 `drawings = ` 赋值都要在清栈函数里」守的也是错的不变量：唯一的整体赋值是**构造函数**，要求构造走清栈函数没有意义。

**实测（`grep` 全 `Sources/`）：`drawings` 的写入面恰好六处，且没有任何一处是生产期的原地整体替换。**

| # | 位置 | 性质 | PR-2 必须让它对栈做什么 |
|---|---|---|---|
| 1 | `TrainingEngine.swift:178` `self.drawings = seededLossy.drawings` | **构造**（不是替换） | 无需动作 —— 新引擎的栈按定义为空 |
| 2 | `:1115` `deleteDrawing(id:)` | 四写入 API | **入栈**（D75） |
| 3 | `:1133` `appendDrawing` | 四写入 API | **入栈**（D75） |
| 4 | `:1179` `updateDrawingStyle` | 四写入 API | **入栈**（D75） |
| 5 | `:1091` `deleteDrawing(at:)` | **零生产调用点**，但会移位下标 | **作废整个栈** |
| 6 | `:1452` `injectDrawingsForTesting` | 仅测试可达 | **作废整个栈** |
| 7 | `setDrawingLocked`（PR-1 新增） | 四写入 API | **入栈**（D75） |
| 8 | `applyUndoEntry`（PR-2 新增） | 撤销执行单点 | **既不入栈也不作废**（D79 第三条） |

**为什么 5 和 6 要作废而不是入栈**：两者都绕过栈直接改数组、且会让已存的下标失准，但它们都不是「用户动作」，入栈没有语义（用户撤销不了一次测试注入）。作废是唯一正确的表态。
**6 尤其不能省** —— 不作废的话，任何「先种一个非空栈、再注入一批线」的测试都会造出一个**下标必然错位**的引擎却全绿，正是本仓的假绿套路。

**守卫改为穷尽性判据**（不是原稿那条）：断言 **`TrainingEngine.swift` 里 `TrainingEngine.drawings` 的写入点集合**（作用域同 §1.6 N-B 第 2 条，**不是**全 `Sources/` 的同名变量）**恰好等于**上表的具名函数集合。新增任何一处写入面 → 守卫变红，直到实施者把它归入上表某一类。这样判据是按**判据本身**穷尽的，不是按这次报告到的点位改（`feedback_fix_the_whole_predicate_family_not_the_reported_site`）。

**第二层（兜底）：`applyUndoEntry` 的前置条件，逐 case 写死。**
undo / redo 共用一个私有单点 `applyUndoEntry`，进它先过下面这组门，**任一不成立 → 返回 `false`、`drawings` 不动、`drawingsRevision` 不递增、并把整个撤销栈作废**（fail-closed，不留半吊子状态）：

| 目标操作 | 前置条件 |
|---|---|
| `remove(at: index)` | `drawings.indices.contains(index)` **且** `drawings[index].id == 快照 id` |
| `insert(obj, at: index)` | `0...drawings.count` 含 `index` **且** `obj.id` 在 `drawings` 中**不存在**（防 D66 的重复 id） |
| `drawings[index] = obj` | `drawings.indices.contains(index)` **且** `drawings[index].id == obj.id` |

**第三条硬约束（防重入）：`applyUndoEntry` 自身绝不入栈。**
撤销栈是深度 1 的 before/after 对，undo 只是把栈顶标记成「已撤销」、redo 标回去；**两者都不产生新栈项**。这正是 D69 修正后的不变量第 2 条所要求的——否则「撤销一次锁定」会把这次撤销本身又推进栈里，第二次点 ↩ 的行为无法定义。

### 2.4 D77　undo / redo 之后的选中态

| 情形 | 选中态 |
|---|---|
| undo「画线」（线消失） | 若消失的正是选中线 → **清空选中**；否则不变 |
| undo「删线」（线回来） | **不自动选中**（与 D37「新提交的线不自动选中」一致） |
| undo / redo「改样式」「锁定」 | **不变**（对象还在原下标，身份没变） |
| redo 各情形 | 与上表对称 |

实现上**不新写一套判据**：`undoDrawing` / `redoDrawing` 返回后由路由调用已有的 `syncSelectionByState`（`DrawingEditRouter.swift:160`）——它的判据「选中 id 不在 `visibleDrawings` 里就清空」已经把上表四行全覆盖，没有第二处可以写漏（D64）。

⚠️ **但「由路由调用」必须被守卫钉住，否则这一节等于没写**（codex R5-F2，medium，**已核实为真**）：
底栏的 ↩ / ↪ 如果被直接接到 `engine.undoDrawing()` 上，**引擎侧的往返测试（N-M）照样全绿**，可选中态永远不同步 —— 撤销掉的正好是选中那条线时，`selectedDrawingID` 变成一个指向已不存在的线的死值：高亮没了、🔒 / 🗑 灰着、要等用户再点一下别处才恢复。

**故 PR-2 必须**：
1. 在 `DrawingEditRouter` 加 `undo(engine:)` / `redo(engine:)` 两个方法，形状同 `deleteSelected`（`defer { syncSelectionByState(engine:) }` + 调引擎）；
2. **守卫**（并入 N-G 同族）：`Sources/` 中 `undoDrawing(` / `redoDrawing(` 的调用点**各恰好 1 处**、都在 `DrawingEditRouter.swift`，且两者同样是 **internal**；
3. **测试 N-T**：撤销 / 重做把**当前选中的那条线**移除时，断言 `selectedDrawingID` 被清空、🔒 与 🗑 回灰；而撤销「改样式 / 锁定」时断言选中态**不变**（对应 D77 表格四行）。

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

**N-N2　陈旧栈项 —— 三个 case 各一条（D79 第二层，codex R1-F2）**
直接给引擎种一条**对不上号**的栈项，断言 fail-closed：
① **下标越界**（index 大于 `drawings.count`）→ `undoDrawing()` 返回 `false`、**不崩**、`drawings` 与 `drawingsRevision` 均不动；
② **下标在界内但 id 对不上**（那个位置换成了别的线）→ 同样 `false`、**那条无辜的线逐字段不变**；
③ **insert 时 id 已存在**（重复 id）→ `false`，`drawings` 条数不变。
三条都必须再断言**撤销栈已被作废**（随后 ↩ / ↪ 均不可用）。
⚠️ ① 是**崩溃回归测试**：没有它，越界 trap 在测试里表现为整个 xctest 进程挂掉而不是一条红断言，容易被误读成环境问题。

**N-N3　绕过栈的写入面必作废栈（D79 第一层，根因）—— 必须是**同一个引擎**，不许换新引擎**
⚠️ 本条原稿用 `resumePendingReplay` 举证，**恒过且证明不了任何事**（那条路径造的是新引擎，栈本来就空）。改为**在同一个引擎实例上**做：

- **N-N3a**：在一个已有引擎上画一条线（栈非空）→ 调 `injectDrawingsForTesting(...)` 换一批线 → 断言撤销栈**已作废**（↩ / ↪ 均不可用），且此时 `undoDrawing()` 返回 `false`、`drawings` 与 `drawingsRevision` 都不动。
- **N-N3b**：同上，但改用 `deleteDrawing(at:)`（零生产调用点、但会移位下标）→ 同样断言栈已作废。

**并加源码守卫**：`Sources/` 中 `drawings` 的写入点集合**恰好等于** D79 第一层那张表里的具名函数集合（穷尽性判据），配反向自检 —— 故意新增一处 `drawings.append` → 守卫必须变红。

**N-N4　undo / redo 不入栈（D79 第三条）**
锁定一条线 → ↩ → 断言撤销栈**深度仍是 1 且栈顶还是那次锁定**（不是"撤销锁定"这个新动作）→ 再点 ↩ 无效果（N-K 已覆盖行为，本条覆盖**栈内容**）。
**不得**只断言「第二次点没反应」—— 那在「入栈了但恰好被深度 1 挤掉」的错误实现下也会过。

**N-Q　会话生命周期与撤销栈 —— 两条要清、一条**不能**清（D74 修正，codex R3-F1 + R4-F1/F2）**
- **N-Q1 下单成交（非 UI 触发）**：进画线模式 → 画一条线（栈非空）→ 走 `advanceAndAccount`（内部 `.tradeTriggered` + `endDrawingSessionIfActive`，`TrainingEngine.swift:532`）→ 断言撤销栈**已空**、↩ / ↪ 均不可用、`undoDrawing()` 返回 `false` 且不动数据。
- **N-Q2 `cancelDrawingAllPanels`（第三条拆除路径，原稿漏了）**：同上，改用 `cancelDrawingAllPanels()` 结束会话 → 同样断言栈已清空。
- **N-Q3 切周期必须**保留**栈（正向测试，防我们把它误当退出路径）**：画一条线 → `switchPeriodCombo(...)` 真的换了组合 → 断言 ① `drawingModeActive` **仍为 true**（与既有 `realPeriodChangeDiscardsOnlyPendingAnchors` 一致）；② 撤销栈**仍非空**、↩ **仍可用**；③ 点 ↩ 能正确撤掉切周期之前画的那条线。

- **N-Q4 被拒的 begin 必须保留栈（codex R6-F2）**：画一条线（栈非空）→ 调 `beginDrawingSession(tool:)` 传一个**未实现**的工具（走 `:1352` 那条 `guard ... implemented` 早退，无任何状态翻转）→ 断言撤销栈**仍非空**、↩ 仍可用、点 ↩ 仍能正确撤销。
- **N-Q5 冗余的 begin-while-active 必须保留栈**：会话已开 → 画一条线（栈非空）→ 再调一次 `beginDrawingSession(tool: .horizontal)` → 断言栈**仍非空**且内容不变。

⚠️ N-Q4 / N-Q5 是把「清栈放在函数入口」那种实现**直接测红**的两条 —— 光靠 N-S 的共处守卫拦不住它。
⚠️ N-Q1 / N-Q2 **不得**用「点退出按钮」那条 UI 路径代替 —— 那条恰恰是本来就会清的，用它测等于什么都没测（同 N-N3 原稿那个恒过测试的错误）。

**N-R　no-op 样式点击不冲掉撤销记录（D80 的 PR-2 侧，codex R3-F2）**
改一条线的颜色（栈里是这次真编辑）→ **把同一个颜色再点一次**（`before == after`）→ 断言撤销栈**栈顶仍是那次真编辑**（不是被 no-op 覆盖）→ 点 ↩ → 颜色回到**改之前**。
**不得**只断言「revision 没变」—— 那测不出栈被覆盖。

**N-S　会话翻转与清栈**共处**（D74 守卫之一 —— 单靠它不够，必须配 N-Q4/N-Q5）**
源码守卫：`Sources/` 中**凡是含 `drawingSession.activate(` 或 `drawingSession.deactivate(` 的函数，必定也含 `clearDrawingUndoStack()`**。当前应命中三个函数：`beginDrawingSession` / `endDrawingSessionIfActive` / `cancelDrawingAllPanels`。
配反向自检：造一个含 `deactivate(` 但不含清栈的函数 → 守卫必须变红。
⚠️ **本守卫拦不住「清栈写在函数入口」**（那样它照样共处、却会在早退与冗余调用上误清）—— 那条由**行为测试** N-Q4 / N-Q5 兜住。两者缺一不可。
⚠️ **不许**写成「只准出现在 begin/end 内」—— 那条在 `cancelDrawingAllPanels:1321` 这行**既有合法代码**上就是红的（codex R4-F2）。

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
| 16b | 画一条线（不点退出）→ 直接**下一单**（买或卖）→ 再进画线模式看 ↩ | ↩ 是灰的。<br>说明：下单会**隐式结束**画线会话，所以撤销记录跟着清掉——这是对的，不是 bug | |
| 16c | 画一条线（不点退出）→ **竖滑切一次周期** → 再看 ↩，然后点它 | ↩ **仍然是亮的**，点下去能把那条线撤掉。<br>⚠️ 与 16b 刻意相反：切周期**不会**结束画线会话（你还在画线模式里），所以撤销记录必须留着 | |
| 16d | 改一条线的颜色 → 把**同一个颜色再点一次** → 点 ↩ | 颜色回到**改之前**那个色。<br>（不是"没反应"——重复点同一个颜色不该把你上一次的真改动冲掉） | |
| 17 | 撤销一条线之后**杀掉 App**，续这一局 | 撤销的结果被保留了（那条线确实不在）；↩ / ↪ 都是灰的 | |
| 18 | 进复盘模式看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 19 | 「再次训练」（replay）模式下重做第 3～9 条 | 行为与训练模式完全一致 | |

---

## 3. 契约

**两个 PR 均为纯 UI / 引擎层：`CONTRACT_VERSION` 保持 `1.12`、`user_version` 保持 `7`、零迁移。**

依据（**逐条给出，不用「只写入 `.horizontal`」这种笼统说法**——codex R1-F3 指出原稿的理由站在假前提上）：

1. **不新增字段、不新建迁移**：`locked` 自 P1a 的迁移 0009 起就在 `style_json` 列里往返（`LossyDrawingArray.knownDiskKeys` 含 `"locked"`）。
2. **不扩展任何枚举值域**：本 spec 不产生任何新的 `toolType` / 样式枚举值。**新建**画线仍只产 `.horizontal`。
3. **对非 `.horizontal` 记录的"编辑"是否构成跨版本写入 —— 分两层回答**：
   - **UI 路径不可达**（已核实）：`DrawingHitTester.firstHit`（`Drawing/DrawingHitTester.swift:26`）对渲染注册表里没有的工具**直接返回 `false`**，而 P1b 的注册表只有 `.horizontal`。选不中 ⇒ 路由取不到目标 ⇒ `setDrawingLocked` 够不着。故**本构建的用户无法锁定 / 解锁任何非水平线**。
   - **即便够得着也不产生版本错位**：raw-preserving 单字段 merge（D70）保证除 `locked` 外的原始字节逐字不动，`toolType` 与所有未来字段原样保留。高版本读回去看到的是**它自己那条线，只有 `locked` 被翻转** —— 这正是用户请求的语义，不是数据损坏。
4. **撤销栈不落盘**（D25：退出画线模式即清空），不进契约。

**举证测试（不可省）**：给 N-A 增加**第三个分量** —— 一条 `toolType` 为 `.trend`（枚举已声明、本构建无渲染器）且带未来字段的线，断言 ① 它**不出现在命中结果里**（选不中）；② 若绕过路由直接调引擎 `setDrawingLocked`，保存后 `toolType` 与全部未来字节**逐字不变**、只有 `locked` 变了。
第 ① 条锁住"UI 不可达"这个论点，第 ② 条锁住"即便可达也无损"这个论点 —— **两条都要，只写一条都是把结论建在没测过的那半上。**

---

## 4. 交接（P1c / P5 / P6）

- **P1c**：`undoDrawing` / `redoDrawing` 目前假设一次动作只影响**一条**线。P1c 的折线画制中临时 4 键（`[回退][前进]` 作用于**锚点**而非整条线）是另一套语义，**不得**复用本 spec 的撤销栈。
- **P5**：复盘获得编辑能力时，`reviewDrawings` 需要等价的 revision 触发器（D56）与等价的撤销栈；且选中必须扩展为 `(layer, id)` 二元组并按层门控（D34 / split addendum §9）。
- **P6**：`defaultStyle` 持久层零引用（不落盘），杀 App 重开后「下一条线的默认」回出厂值。**是已知的 P6 范围，不是本 spec 的回归。**
- **残留①（本 spec 不修，明确记录）**：带未来数据的线解锁后仍**改不动样式**（D61 门保留在 `updateDrawingStyle` 上）。用户对这类线的处置通道是整条删除。P3 / 未来版本认识那些值后自然解禁。
- **残留②（codex R1-F3 顺出来的，本 spec 不修）**：高版本写的**非水平线**若带 `locked == true`，在本构建里**既解不开也删不掉**——因为它**选不中**（无渲染器 ⇒ 不命中），路由够不着，而 `deleteDrawing(id:)` 的 locked 门也会拒它，`finalize` 门则会因未来数据 `throw`。
  这是 **N14h 的同族**，且**与 D69 是否带工具门无关**：带了工具门同样锁不上也解不开，因为门在引擎、而卡点在"选不中"。真正的解药是 P1c 给这些工具**装上渲染器**（选得中 ⇒ 解得开 ⇒ 删得掉），届时本条自然消失。
  ⚠️ **P1c 必须接手**：它的三组举证测试第 3 组（「可解码但无渲染器」路径）要把这条一并覆盖 —— 不能只测"不渲染"，还要测**这类线不会把整局卡死在归不了档的状态里**。

---

## 5. 实施状态（2026-08-21）

**PR-1（锁定）** 已实施并合入 `origin/main`（#163）。
**PR-2（撤销）** 已实施完毕，分支 `feat/drawing-p1b-undo`，base = `feat/drawing-p1b-autoselect`。

**本 spec 写于 2026-08-11，早于「持久化片」与「自动选中片」。** PR-2 实施时补了三条本 spec 没有的决策
（记在实施计划 `docs/superpowers/plans/2026-08-21-drawing-p1b-undo.md` 的「本计划新增的三条决策」一节）：

- **D101** 入栈条件 = 「`drawings` 内容真的变了」；本局默认单独变化不入栈（含已接受残留）。
- **D102** 「一次动作」作用域 —— 把画线态改样式的两处写入合成一条撤销记录（自动选中 spec §10.1 的硬约束）。
- **D103** 清栈绑「`drawingModeActive` 真的翻转」，**修正本 spec §2.1「落地形态」那一句** ——
  它与本 spec 自己的 N-Q5 冲突（`DrawingSession.activate` 对 `drawingModeActive` 是幂等的，
  冗余的 begin 会走到 activate 却没有翻转，照原句实现会静默抹掉一条有效撤销记录）。

**本片实施中的四处实测更正**（均非 spec 原意的推翻，而是原稿预估/文字与实测/自身其它条目冲突后的订正，供后人核对）：

1. **§2.3b 的写入点预估**：`TrainingEngine.swift` 里 `drawings` 的结构性写入点，锁定 PR 后预估为 **6 处**，
   实施后实测为 **8 处** —— 撤销执行单点 `applyUndoEntry` 因 D76（不得复用四个写入 API）自带 **3 处**
   （`remove` / `insert` / 下标赋值），而不是预估里隐含的 1 处。守卫 L12b 与 U-G4 均按 **8** 钉死。
2. **§2.1「落地形态」与自身 N-Q5 的冲突**：见上面 D103 —— 清栈判据从「调了 activate/deactivate」
   收紧为「`drawingModeActive` **真的翻转**」，按 N-Q5 收敛，不按 §2.1 原句字面实现。
3. **§2.6 N-N2 的覆盖粒度**：原稿按 **case** 枚举了三条陈旧栈测试（`.removed` / `.inserted` / `.replaced`
   各一条），但撤销执行单点 `applyUndoEntry` 的三个 case **各含两道门**（越界门 + 身份/去重门），
   合计 **6 个判据点**，按 case 枚举只钉住其中 3 道，另 3 道（`.removed` 分支的身份门 /
   `.inserted` 分支的越界门 / `.replaced` 分支的越界门）是静默回归空档。实施时改按**判据点**
   枚举，补齐为 **N-N2①…⑥** 六条覆盖。
4. **N-Q3 的缺口**：原稿 N-Q3 只写了两条（① 切周期不清栈 / ② 判据前置断言），漏了第 **③** 条 ——
   「切周期后点 ↩ 能撤掉切换前画的那条线」。该条需要 `undoDrawing()`（PR-2 才有），已在实施时补齐。

**已接受残留（原 spec 未预见，PR-2 实施期间与用户对齐、2026-08-21 明确接受，写入 PR 描述）**：
画线态下若那条线被拒（锁定 / 滑出屏 / 带未来数据 / 工具未实现四类门之一），**或者那条线恰好是
no-op**（用户把默认改成线本来就有的值，D101 判定 `drawings` 内容没变），结果都是「只有本局默认变了」，
这次改动**撤不回来**；且它会把栈顶记录的默认分量清掉（那条线的编辑仍可撤销，但撤销时不再连带回滚默认——
因为默认已被一次**更晚的**用户操作改过，回滚它就是覆盖用户的新选择）。见实施计划 D101。
⚠️ 两种情况同属一类：**`drawings` 内容没真的变 ⇒ 不入栈**——被拒是「压根没写」，no-op 是「写了但值一样」，
后果对撤销栈来说完全等价，别按字面只理解成前一半（整支终审 Task 10）。
