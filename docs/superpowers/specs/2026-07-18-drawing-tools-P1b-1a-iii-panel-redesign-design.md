# 划线 P1b-1a-iii（修订）：样式面板重构 + 自适应线色 + 布局不变量 — 设计文档

> **状态**：brainstorming 定稿，待 user 复核 → writing-plans。
> **日期**：2026-07-18。
> **承接**：母 spec `2026-07-04-drawing-tools-expansion-design.md` §2/§3/§3.1；范围权威 `2026-07-10-drawing-tools-P1b-split-addendum.md` §4（本文**修订**其 §4.1.2/§4.1.4，并重写 §4.3/§4.4 的相关条目）；外壳原设计 `2026-07-17-drawing-tools-P1b-1a-iii-shell-interaction.md`。
> **可视化对齐草图**（设计已锁定）：https://claude.ai/code/artifact/672eb0e0-af45-4d25-b4af-3124d6dd27a9

## 0. 为什么改

当前 1a-iii 分支（已 impl-complete + codex-approve、**未合并**）在真机验收前经 user 逐条比对，挖出 **4 类设计缺口**——正是「纯 UI 期交互验收不可跳过」的价值。落地策略（user 拍板）：**并入当前分支重做，暂不 push**；走完 plan→实施→三绿→codex 整体评审后再合；PR 切片在 plan 阶段按「小切片」守则拆。旧交互（长按卡片 / 禁色 / 底栏布局）属于**要被替换**的，先合等于 ship 一版立刻返工的 UI。

4 类缺口 →本文 4 块修订：
1. **触发 + 生命周期**：样式设置不该是「长按弹临时卡片」，而是**常驻面板**，画线全程可随时改样式再接着画。
2. **图标化**：线型 / 线样式 / 粗细不写文字，**画出真实样子**。
3. **自适应线色**：黑 / 白合并成**一个「线色」**，随昼夜自动反色（日纯黑、夜纯白），根治「黑线到夜间看不见」。
4. **布局不变量**：进画线后 K 线区域**尺寸恒定**（面板 overlay 遮挡、不挤压）；画线底栏与原训练底栏**等高**。

## 1. 范围

### 1.1 改（本期做）
- 样式面板：触发方式、常驻生命周期、上下摆放（镜像）、图标化控件、自适应线色。
- 布局不变量：底栏等高、K 线区尺寸恒定、面板 overlay。
- 删除：`DrawingStyleAvailability.colorEnabled` 禁色逻辑；颜色面板中独立的黑 / 白色格；`DrawingColorResolver` 中黑 / 白的「糊色 fallback」（由 legacy 处理接手，见 §4）。

### 1.2 不改（维持既有，测试须全绿）
- **D45「下单即隐式退出画线」**不变量（`buy/sell` 末尾 `endDrawingSessionIfActive()`，~10 测试）；**交易边界只在 UI 层 enforce**，不动引擎。
- 1a-i（D29/D35）、1a-ii（D39/D42/连续画线）前作行为。
- 画线落盘走 `appendDrawing` → `drawings.count` 变 → `autosave(immediate:true)`；样式**原子构造**（`commitPending` 先建完整 `DrawingObject` 再 append）。
- 副图（成交量/MACD）不可画；只画 K 线主图区（上下面板皆可，D42）。

### 1.3 明确不属本期
- 画线模式内平移 / 切周期 / 缩放 → **1a-iv**（本期画线模式内手势仍是今天语义：单指 pan 被绘线截获，**非回归**）。
- 选中 / 删除 / 锁定 / 撤销（1b-i/1b-ii）；节点 / 多锚 / 四个新工具（P1c）；复盘专属（P5，复盘仍浮动钮）；主页全局默认设置（P6，本期默认样式仍**内存整局、不落盘**）。

---

## 2. 交互设计：常驻样式面板

### 2.1 触发与生命周期
- 面板 = **「类型行 + 参数」一个整体**，由底栏 **①「类型」键**统一开 / 合。
- 进入画线模式：底栏升起（含「类型」键）；面板**默认展开**（直接可设样式，无需二次点击）。
- 点「类型」键 → 整块**收起**（overlay 隐藏，**K 线容器 frame 不变、不 reflow**——见 §2.4）；再点 → **展开并回到上次所用工具**及其参数（记住上次选择）。**收 / 展只切 overlay 可见性，不增删任何预留布局高度**。
- 面板**画线全程常驻**：连续画多条时，随时切颜色 / 粗细 / 线型 / 线样式，**改动即作用于「下一条要画的线」**；已画的线不受影响（默认值语义，§3）。
- 切换画线类型（本期仅水平线；P1c 多工具）：参数**保持展开**、只换成新类型对应项，无需重新展开。

### 2.2 结构
```
类型行： [类型标签] [水平线●] [趋势线※] [黄金分割※] ……            [⇅]
参数：   线型   [直线●][射线][线段灰]
        线样式  [实线●][虚线1][虚线2][虚线3][虚线4]
        粗细    [1●][2][3][4][5]           ← 图标，非数字
        颜色    [红][橙●][黄][绿][青][蓝][紫] [线色]   ← 7彩 + 1自适应
        标注    [隐藏●][显示灰][左][右]
```
- `●`=示例选中态（浅蓝框+浅蓝字）；`※`=P1c 示意（本期不渲染，仅 mock 里示意通用模型）；`灰`=不可用（只灰、无文字说明）。
- 本期类型行**只渲染水平线 1 个图标**（母 spec D22 / split-addendum §4.3-3 不变）。

### 2.3 上下摆放与镜像（手动，不自动避让）
- 面板整体**要么在下半区、要么在上半区**，靠类型行右端 **⇅ 按钮**手动切（**不做自动避让**——user 明确否决）。用途：在上半 K 线画就把面板搁下半，在下半 K 线画就搁上半。
- **下半区（默认）**：整块贴在底栏上方一点点。视觉从上到下 = `参数 → 类型行 → 底栏`（类型行贴着底栏）。
- **上半区（镜像）**：整块上移，**类型行顶边与「上半 K 线区」顶边对齐**（再往上会挡顶栏按钮）。镜像 = `类型行 → 参数`（类型行在上、参数在下）。
- **镜像范围**：只翻转「类型行 ↔ 参数」两大块；**参数内部 5 组顺序两态相同、不翻**（user 确认）。

### 2.4 布局不变量（关键，当前是 bug）
- **进入画线模式，K 线区域及以上尺寸恒定**：面板是**盖在 K 线上的 overlay（遮挡）**，**不挤压 / 不 reflow** K 线。从进入训练 → 进画线 → 展开 / 收起面板 → 切上下，K 线区几何尺寸自始至终不变。
  - **本条明确取代 split-addendum §4.1.2「收起 = 让出一行图表高度」**：原设计是 reflow（收起把图表高度让出来），本期按 user 2026-07-18 反馈改为 **overlay 恒定**（图表尺寸永不因面板开合而变）。这是本期修订的核心之一，非笔误。
- **画线底栏高度 == 原训练底栏高度**：进画线后替换训练底栏的那条常驻栏（含「类型」键），高度与训练界面「周期切换 + 买/观/卖」那栏**一致**，不得更高把 K 线顶起（当前实现更高 = 要修）。
- 面板 overlay 半透明底 + 圆角 + 阴影，浮在 K 线之上；收起时仅剩底栏。
- **可验证性（codex R1-medium）**：K 线容器 frame 在「进画线 / 展开 / 收起 / 上下切」四态**逐一相等**，须由**自动化几何断言**证明（hosted 布局测量测试测容器 frame 相等；若 harness 不可行则 Catalyst/模拟器门加截图 diff）——**不得只靠 source-guard + 人工**。此即针对「当前底栏顶起 K 线」bug 的机器可查判据。
- **命中屏蔽（codex R4-medium，误画 / 交易安全）**：面板 overlay 是**全 bounds 的 hit-test 盾**——面板 frame 内的触摸（含按钮 / 空隙 / 背景）被面板吃掉，**不得穿透到 K 线画线输入**。否则点面板空隙会在下方 K 线**误落一条线并 autosave**（既有画线逻辑：任何映射进主图的 tap 都提交）。须有自动化测试（点面板背景 / 空隙 / 按钮 → 断言 `engine.drawings.count` 不变、无 anchor/commit，仅面板内样式操作生效）。

---

## 3. 参数控件（图标化）

统一原则：**面板内不写文字**（除标注组），把样式「画出来」。灰态项只灰、无「不适用」说明字（母 spec §3 逐字要求）。

| 组 | 呈现 | 灰态矩阵（水平线，§3.1 不变） |
|---|---|---|
| 线型 | 直线=一段实线；射线=起点圆点+朝右箭头；线段=两端带端点 | 直线✅ 射线✅ **线段灰** |
| 线样式 | 实线 + 虚线1~4，各画一小段真实 dash | 全可选 |
| 粗细 | 5 档，各画**真实粗细**的线（1→5 递增），非数字 | 全可选 |
| 颜色 | 7 彩色板 + **1「线色」**（自适应，§4） | **删除禁色灰态**（无灰色） |
| 标注 | **维持现状**：文字「隐藏/显示/左/右」+ 灰态 | 显示恒灰；选射线后「左」再灰 |

- 线型切换仍走 `normalizedLabelMode`（切射线后旧 labelMode=左 回落隐藏），规则单一真相不重复。

---

## 4. 自适应「线色」— 渲染改造（**不新增持久化值域**）

### 4.1 行为（user 定稿）
- 颜色面板 = **7 彩 + 1 个「线色」**。删除独立的「黑」「白」两格、删除昼夜禁色灰态。
- 「线色」= 随手机昼夜自动反色：**日间纯黑、夜间纯白**，永远与背景反着来、不会消失。根治「日间画黑线 → 系统切夜间 → 看不见」。

### 4.2 实现（**复用既有 `.black`，不新增枚举值** — codex R4-high）
> 关键决策（R4）：**不引入新的 `.adaptive` raw 值**（否则老端 finalize fail-closed，见 §4.3）。因本期本就把 `.black`/`.white` 的**渲染**改成自适应，`.black` 天然就是「新端自适应 ink」——故「线色」**直接复用既有 `.black`** raw 值。
- **枚举不变**：`DrawingColorToken` 保持 red…purple / black / white，**无新增值域**。
- **渲染改造**：`DrawingColorResolver.resolve` 把 `.black` 与 `.white` **都**解析成纯 ink——`.light`→近黑、`.dark`→近白（对比度拉满，**删掉糊色 fallback**）。→ 新端 `.black` 与 `.white` 成「自适应 ink」同义值。
- **UI**：「线色」色板项选中 → 落 `colorToken = .black`（canonical）；无独立黑 / 白格。`.white` 仅 legacy 可解码（新 UI 不再产出），渲染同样自适应。
- **禁色逻辑删除**：移除 `DrawingStyleAvailability.colorEnabled`（及其测试）——`.black`/`.white` 现恒可读，无需灰态。
- **默认样式**：`DrawingDefaultStyle.colorToken` 仍 `.orange`，本期不改默认；仍内存整局、不落盘。

### 4.3 前向 / 后向兼容（复用既有值域 → **无跨版本数据风险** + 一处**已记录的渲染语义变更** — codex R1→R5）
> 修正史：R2/R3 曾按「新增 `.adaptive` raw 值」推演出 load→finalize 跨版本难题（老端 finalize fail-closed brick）；**R4 采纳更优解——根本不新增 raw 值，风险随之消失**。
- **不新增值域**：`colorToken` 值集与既有 1.11 **完全相同**（仅 `.black`/`.white` 的**渲染函数**变、存储值域不变）。
- **老客户端**：`.black` / `.white` 都是**既有已知值** → load / **finalize / 复盘全部正常**（不触 `knownFutureEnumPayloads` 未来枚举门，`LossyDrawingArray:230`）、**无 brick、无数据丢失**。老端渲染 `.black`=黑(日)/浅灰(夜)、`.white`=深灰(日)/白(夜)——可读、可 finalize（与今日行为一致）。
- **新客户端**：`.black`/`.white` 渲染成纯黑 / 纯白自适应。
- **契约**：**不 bump `CONTRACT_VERSION`**（现 1.11）、不动 DB schema、无迁移、**与 QMT 无版本撞车**——因为**没有任何新持久化值 / 键 / schema**，只有一处**渲染函数**行为变更（纯 UI 侧、不进 blob）。
- **已记录的契约例外——渲染语义变更（codex R5-medium）**：本期**故意**把既有 `.black`/`.white` 的**渲染语义**从「固定黑 / 白（老端糊灰兜底）」改成「自适应纯 ink」。这对**已持久化**的 `.black`/`.white` 记录是一处**用户可见的跨版本渲染漂移**（新端纯黑白 / 老端黑或糊灰）——但**这正是 user 要的「黑白合一自适应」、非缺陷**；数据层零风险（不丢 / 不 brick / 可 finalize / 字节一致），仅**显示语义**变。**须加渲染 fixture**（§7-9）把该漂移显式钉住——byte / finalize 测试测不到渲染层。

---

## 5. 交易边界（不变）

维持既有 UI 层双门控：画线时底栏无买卖钮 + 进 / 出画线**无条件**清 `tradeStrip` + TradeBox overlay 挂载门控 + `onConfirm` 经 `TradeConfirmGuard.apply`。**不动引擎 `buy/sell`**，D45 不变量保持。1a-iv 才在画线模式内放开平移 / 切周期（仍不能买卖）。

## 6. 数据流 / 落盘（沿用）

新画线：`commitPending`（读 `DrawingSession.defaultStyle` 原子构造完整 `DrawingObject`）→ `routeDrawingCommit` append → `drawings.count` 变 → `autosave(immediate:true)`。样式往返（normal `saveProgress→pending` + replay 端到端）测试沿用并扩「线色」用例。不可见边射线 fail-closed（`handleDrawingTap` 的 `visibleGeometry!=nil`）保留。

---

## 7. 测试策略（更新 split-addendum §4.3 负向测试）

**删除 / 改写**：
- 原「白天『白』灰、夜间『黑』灰」→ 改为「颜色组**无灰态**、**无独立黑/白格**、`colorEnabled` 已删」。

**新增**：
1. **线色渲染**：`resolve(.black, .light)`=近黑、`resolve(.black, .dark)`=近白；`.white` 同；一条 `.black`「线色」线在日 / 夜都可读（对比度阈值）。
2. **颜色兼容（§4.2/§4.3，复用既有 `.black`、无新增值域 → 无跨版本风险；须对齐既有 `DrawingModelP1aTests`/`DefaultRecordRepositoryTests` 不冲突）**：①「线色」选中 → `colorToken==.black`；②既有 `.black`/`.white`/finalize/复盘/legacy 测试**全绿、断言不改**——**无新增枚举值 → 不引入任何未来枚举 / unknownRaw / `CONTRACT_VERSION` bump 类新断言**；③`colorEnabled` 相关测试随删。
3. **面板生命周期**：进画线默认展开；「类型」键 toggle 开 / 合；收起后底栏「类型」键仍在视图树；再展开回上次工具。
4. **上下摆放 / 镜像**：⇅ 切 top/bottom；下半 = 参数在上·类型行贴底栏，上半 = 类型行在上·参数在下；参数内部 5 组顺序两态一致（source-guard / 快照）。
5. **布局不变量（自动化几何断言，codex R1-medium）**：K 线容器 frame 在「进画线 / 展开 / 收起 / 上下切」四态**逐一相等**（hosted 布局测量测试；fallback Catalyst/模拟器截图 diff）；画线底栏高度 == 训练底栏高度常量。**不得只用 source-guard + 人工**；人工 §4.4 仅补充。
6. **图标化 source-guard**：线型 / 线样式 / 粗细面板内**无文字标签**、每档渲染对应 Path/Shape；标注组仍为文字。
7. **前作回归**：1a-i D29/D35、1a-ii D39/D42/连续画线全绿；D45 交易边界回归全绿。
8. **面板 overlay 命中屏蔽（codex R4-medium）**：点面板全 bounds（背景 / 空隙 / 按钮）→ `engine.drawings.count` 不变、无 anchor/commit（面板吃触摸、不穿透 K 线画线输入）；仅面板内样式操作生效。
9. **既有 `.black`/`.white` 记录渲染 fixture（codex R5-medium，钉住渲染语义漂移）**：加载既有 `.black`/`.white` drawing 记录 × {日, 夜} × {normal, replay, 复盘}，断言渲染成**新自适应语义**（纯黑 / 纯白）——覆盖 byte / finalize 测试测不到的渲染层。

（布局不变量本期**要求自动化几何断言**（§7-5），不再只靠人工；仅**手势的真实表现**无法纯静态断言 → 三绿门 + §4.4 人工验收兜底，1a-ii 血泪。）

---

## 8. 落地策略与 PR 切片（初步，细化在 plan）

并入当前分支重做，暂不 push。按「每 PR ≤3子项、大 PR codex 不收敛」守则，**初步**拟拆（plan 阶段定稿）：
- **切片 1｜布局不变量 + overlay 命中屏蔽（不可分，codex R5-high）**：底栏等高 + K 线区尺寸恒定 + 面板 overlay 化 + **overlay 全 bounds hit-test 盾 + §7-8 `drawings.count` 不变测试**。**引入 overlay-over-chart 的 PR 必须同带命中屏蔽守卫与测试——禁止 overlay-only 切片**（否则 overlay 先落地、误画防护后到，中间可不可逆误画 + autosave）。
- **切片 2｜常驻面板 + 图标化**：触发改造（类型键开合、常驻、记忆、镜像上下切）+ 线型/线样式/粗细图标化 + 替换长按卡片。
- **切片 3｜自适应线色（复用既有值域，无契约风险）**：`DrawingColorResolver` 改 `.black`/`.white` 自适应渲染 + 删糊色 + 删禁色 + 「线色」落 `.black`；**无新增枚举值 / 无 bump / 无迁移**。
（依赖：2、3 都改样式面板，可能合并或严格排序；由 plan 判定。）

## 9. 待 codex 对抗评审重点
- 契约（**R4 采纳「复用既有 `.black`」→ 无跨版本风险、无 bump**）：确认渲染改造不涉任何新持久化值 / 键 / schema；确认既有 `.black`/`.white`/finalize/复盘/legacy 测试不需改断言；确认「线色」落 `.black` 且新端 `.black`/`.white` 自适应渲染。
- 命中屏蔽（**§2.4/§7-8**）：验证面板 overlay 全 bounds 吃触摸、点面板不在下方误落线（`drawings.count` 不变）。
- 布局不变量（**判据已落 §2.4/§7-5 自动化几何断言**）：验证该断言能否真的锁死「四态 K 线 frame 相等」、fallback 截图 diff 的稳定性。
- 交易边界回归（面板重构后 `tradeStrip` 清理 / overlay 门控 / D45 不破）。
- 常驻面板与 D19（不 ship 未接线控件）/ D24（②–⑤ 不渲染）/ D38 的关系是否自洽。

## 10. 对现有实现的增量（供 plan 参考）
- **替换**：`DrawingStyleCard`（长按卡片 → 常驻可 reposition 面板）；`DrawingModeBar`（两行栏 → 含 overlay/等高/⇅/开合）。
- **改**：`DrawingColorResolver`（`.black`/`.white` 改自适应纯 ink、删糊色 fallback，**不加新 case**）；`TrainingView`（面板挂载 / overlay / 底栏等高 / **overlay 命中屏蔽**）；`DrawingStyleAvailability`（删 `colorEnabled`）；`DrawingStyleCard`「线色」项落 `.black`。
- **删**：颜色禁色相关测试；独立黑 / 白色板项。
- **加**：图标化控件（线型/线样式/粗细的 Shape/Path）；面板上下位置状态 + ⇅；面板展开 / 记忆状态；overlay hit-test 盾 + 测试。
- **不动**：`DrawingColorToken` 枚举值域、`CONTRACT_VERSION`、DB schema / 迁移。

## 11. §4.4 非程序员验收清单（重写要点，完整版随交付产出）
新增 / 改写要点（action → 预期 → 二元判定）：
- 进画线：底栏与训练底栏**等高**、K 线**不被顶**（进画线前后 K 线一样大）。
- 点「类型」键：面板整块升起（默认工具 + 参数一起展开）；再点收起；再点展开**回上次工具**。
- ⇅：面板在上 / 下半区切换；上半区时**类型行顶边贴上半 K 线顶边**；切换 / 开合时 **K 线尺寸不变**。
- 线型 / 线样式 / 粗细：都是**画出来的图标、无文字**。
- 颜色行：**7 彩 + 1「线色」**；**无**独立黑 / 白格；**无**禁色灰。
- 「线色」画一条：日间黑，**切夜间自动变白、始终看得见**（原黑线夜间消失问题解决）。
- 连续画时改颜色 / 粗细 / 样式**立即作用下一条**，旧线不变。
- 复盘仍浮动钮、**无**两行栏（不变）。

---

参见 [[project_drawing_p1b_1a_iii_design_plan_done]] [[project_drawing_tools_p1b_five_pr_split]] [[project_app_public_release_intent]] [[project_drawing_p1b_1a_ii_paused_codex_quota]] [[feedback_internal_review_misses_bad_data]]。
