# 画线工具扩充（文华财经风格）+ 画线模式整体重做 — 设计规格

- **日期**：2026-07-04
- **状态**：Draft（待 codex 对抗评审 + 用户确认）
- **交付形态**：**一份总 spec，分 6 个 PR 阶段交付（P1…P6）**。每阶段独立 plan + codex branch-diff + 三绿 + PR。
- **基线**：origin/main `b016bac`（#139 复盘重设计 + replay 主界面标记已落地；`CONTRACT_VERSION=1.10`；迁移到 `0008`/`user_version=6`）。worktree `drawing-tools-expansion`。
- **关联**：memory `project_drawing_tools_expansion_rfc_2026_07_03`（需求源 + 全决策）、`project_post_overhaul_backlog_2026_06_30`（backlog 优先级①）、`project_review_redesign_rfc_2026_07_01`（本 RFC 承接其 §8 延后的复盘画线删除 UI）。
- **UI mockup（已浏览器逐屏确认锁定，权威留底）**：`docs/superpowers/mockups/2026-07-03-drawing-tools-expansion.html`（52 屏，5 大区；commit `f865b39`）。**像素/布局细节以此 mockup 为准，本 spec 不复述像素。**

---

## 0. 范围界定

### 本 RFC 做（分 6 阶段，合计一整套画线子系统）
1. **画线模式整体重做**：取代现有浮动 ✎ 圆钮，改为顶栏固定「画图」入口 + 底部两行常驻（类型行 + 图标底栏）+「结束↔退出」态切换 + 退出后画线惰性。
2. **文华财经风格 11 个画线工具**：水平线（升级）、趋势线、通道线、折线、黄金率、波浪尺、周期线、斐波那契、时间尺、标注（文字）、箱体。
3. **线型/样式/颜色/标注系统**：直线/射线/线段子类、实线+4 虚线、粗细 5 档、颜色 9 色（昼夜禁用）、标注（原「价格标注」）显示模式；长按类型图标弹统一设置面板。
4. **选中 / 节点编辑 / 删除 / 锁定 / 撤销·前进**。
5. **局部放大镜 + 吸附**（拖节点/周期线拖线时）。
6. **画线绑定「周期」而非面板**（切周期后画线跟随其周期）。
7. **复盘集成**：复盘中可画线（已有基础）+ **接线复盘画线删除**（`removeReviewDrawing`）+ 隐藏原训练线 + 复盘存档持久化 + 「删空清『已复盘』」收口。
8. **主页「画线设置」（全局默认）**：齿轮项 → 每工具默认设置 + 全局吸附开关 → 每局按默认初始化。

### 本 RFC 不做（各自独立 RFC / 明确剔除）
- **价差尺**：本 RFC 不做（用户明确剔除）。
- **垂直线**：不做（射线/线段/直线已下沉为「线型子类」，不再是独立工具）。
- **训练界面周期/指标可配、iPad 适配、主页齿轮其它 UI 调整**：各自独立 RFC（见 backlog）。
- **江恩线/阻速线/回归通道/百分比线** 等文华其它工具：不在本 RFC。

---

## 1. 背景与现状锚点（改造起点，文件:行以 `b016bac` 为准）

| 关注点 | 位置 | 现状 | 本 RFC |
|---|---|---|---|
| `DrawingToolType` | `Models.swift:37-39` | `ray, trend, horizontal, golden, wave, cycle, time` 7 例，**仅 `.horizontal` 有真实现** | 扩为 11 工具（§5.0） |
| `DrawingObject` | `Models.swift:209-248` | `toolType / anchors[DrawingAnchor(period,candleIndex,price)] / isExtended / panelPosition / revealTick`；自定义 Codable（`revealTick` `decodeIfPresent`） | 大改，新增样式/文本/period 字段（§11） |
| 唯一具体工具 | `HorizontalLineTool.swift` | `render` 全宽横线 + `hitTest`（容差 8pt，无生产 caller）；`requiredAnchors=1...1` | 新增 10 个 `DrawingTool` 实现 |
| `DrawingTool` 协议 | `DrawingTool.swift:14-20` | `@MainActor`；`type / requiredAnchors / render(ctx:mapper:anchors:) / hitTest(point:mapper:anchors:)->Bool` | 复用；hitTest 接进选中（§7） |
| 输入控制器 | `DefaultDrawingInputController.swift:21-31` | `minAnchors`：仅 `.horizontal→1`，其余 6 个 `Int.max`（永不 commit 占位）；`shouldCommit=count>=minAnchors` | 各工具给真锚数（§5） |
| 落锚→提交 | `ChartContainerView.swift:260-276 (handleDrawingTap)` | **写死 `tool: .horizontal`**，单击落 1 锚即 commit + 退出 drawing | 泛化为 `manager.activeTool` + 多锚（§5.1、§14） |
| 渲染注册表 | `KLineView.swift:44` | `drawingTools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]` | 注册全部工具 |
| 渲染分发 | `KLineView+Drawing.swift:16-26` | 通用 for-loop 查 `tools[toolType]` 调 `render`；缺失即跳过 | 复用 |
| 渲染过滤 | `RenderStateBuilder.swift:67-69` | `drawings(+review reviewDrawings).filter{ panelPosition==(panel==.upper ?0:1) && revealTick<=tick }` | **改按 period 绑定**（§10） |
| 引擎画线态 | `TrainingEngine.swift:25,31` | `drawings`（记录真相）/ `reviewDrawings`（复盘工作层，`public private(set)`） | 复用 + 加删除/隐藏/样式编辑面 |
| 复盘删除（未接线） | `TrainingEngine.swift:984-987 (removeReviewDrawing)` | 存在但**无生产 caller**（§8 延后至本 RFC） | 接线到选中删除（§12/P5） |
| 复盘提交路由 | `TrainingEngine.swift:996-1005 (routeDrawingCommit)` | review→`reviewDrawings`，否则→`drawings`；提交盖 `revealTick`，但**现只从 toolType/anchors/isExtended/panelPosition/revealTick 重建**（会丢新字段） | **改 copy-with-revealTick、保留全字段**（§5.0、D15） |
| 复盘净改动 | `ReviewArchiveRepository.swift:35-45 (ReviewNetChange.changed)` | 比较 key `toolType\|panelPosition\|isExtended\|revealTick\|anchors` 排序集 | **key 补新字段**（§11.4） |
| 复盘 autosave | `TrainingSessionCoordinator`（`persistReviewWorkingIfChanged`/`autosaveReview`/单写者 fence）；`TrainingView` `.onChange(reviewDrawings.count)` | 已有单写者 fence + 后台 flush | 触发面扩到样式/隐藏变更（§12） |
| 首页标记 | `ReviewArchiveRepositoryImpl.loadMarkers`；`saved_drawings IS NOT NULL→已复盘`；`working_step_tick IS NOT NULL→复盘中` | 已有 | 「删空清已复盘」特判（§12.4） |
| 手势仲裁 | `ChartGestureArbiter.swift`：`onPan/onPinch/onLongPress/onTap/onVerticalSwipe/onTwoFingerSwipe`；`drawingMode`（true 时单指 Pan 被绘线截获、单击 fire onTap）；`crosshairMode` | RFC-C 单指竖滑切周期在此 | 画线模式手势消歧扩展（§14） |
| 划线钮门控 | `TrainingView.swift:69 (showsDrawingTools = showsTradeButtons \|\| flow.mode==.review)`；FAB 在 `.overlay(.topLeading) L185-189` | 现浮动 FAB，训练/复盘都显 | 改固定顶栏入口 + 底部两行（§3） |
| 底栏 | `TradeActionBar`（训练 3 键）/ `ReviewControlBar`（复盘 2 键 + [上图\|下图] 分段器 + 下单价） | 已有 | 画线模式底部换画线工具栏（§3） |
| 迁移/契约 | `AppDBMigrations.swift`：baseline `drawings(id,record_id,tool_type,panel_position,is_extended,anchors)` + `0008` 加 `reveal_tick`；到 `user_version=6`；`Models.swift CONTRACT_VERSION="1.10"` | 已有 | `0009`+ / `1.10→1.11` / `user_version 6→7`（§11.3） |

**可直接复用（无需重造）**：`DrawingTool` 协议（render+hitTest 两槽齐备）、渲染分发 loop、`DrawingToolManager` 多锚收集 FSM、`routeDrawingCommit`（复盘不污染原记录）、`removeReviewDrawing`、复盘 autosave 单写者 fence、`CoordinateMapper`（priceToY/yToPrice/xToIndex/indexToX）、ChartGestureArbiter 单指竖滑切周期。

---

## 2. 画线模式外壳 UX（§P1）

权威布局见 mockup 区①。要点：

- **入口**：训练/复盘顶栏「结束」**左侧**加固定「画图」图标钮，与「结束」**留明显间距**（防误点）。取代现有浮动 ✎ 圆钮（`DrawingToolFloatingView` 退役；其拖动「闪现」问题一并消除）。
- **进入画线模式**：点「画图」→ 底部升起**两行常驻**（同训练底栏高度、图标 only 无文字）：
  - **上行 = 类型行**：11 工具图标横排（挤则 2 行），选中态浅蓝框 + 浅蓝字；可被底栏①键收/展（收起后仅能画上次所选工具，展开可换）。
  - **下行 = 底栏图标键**：训练/再次训练 **5 键**＝①类型（收展类型行）②锁定 ③删除 ④撤销 ⑤前进；复盘 **6 键**＝再加⑥隐藏。
  - 顶栏「结束」→ 变「退出」。
- **退出画线模式**：点「退出」→ 两行落下、恢复训练/复盘底栏、「退出」→「结束」。**退出后所有画线惰性**（不可点选/拖动/删除）；仅画线模式内可选中编辑。
- **画布约束**：画线只落在 **K 线主图区**（成交量/MACD 副图不可画）；**上下两面板都能画**（归属所画面板当前显示的周期，见 §10）。
- **画线模式保留图表操作**：单指横滑=平移、单指竖滑=切周期（复用 RFC-C）、双指=缩放、单击=落锚/选中、拖节点=移节点（§14 手势消歧）。
- **阶段边界（codex R7-medium，见 §15/D19）**：**P1 只交付训练/replay 的画线模式（5 键底栏、各控件全可用）**；**复盘 6 键栏（含隐藏）+ 复盘删除 + 隐藏 + 复盘持久化/clear-saved 全属 P5**。P5 落地前，**P1 在复盘模式下隐藏/禁用一切复盘专属控件**（不 ship 死控件/未接线动作），并加测试证之。

---

## 3. 统一长按设置面板模板（§P1）

**交互**：类型行里**长按**某工具图标 → 在类型行上方弹出该工具的设置面板（普通浮层卡片，**无气泡尾巴**）。平时短按只选工具、用当前/默认设置连续画。面板即时反映该工具**可选项**，不可用项**只灰掉、不写任何「不适用」说明字**。

**除「标注(文字)」外 10 个工具共用同一模板**，含四组控件：

| 控件 | 选项 |
|---|---|
| 线型子类 | `[直线] [射线] [线段]`（常显，按工具灰不可用项） |
| 线样式 | `[实线] [虚线1..4]`（1 实 + 4 虚，共 5） |
| 粗细 | 5 档 |
| 颜色 | 9 色（赤橙黄绿青蓝紫黑白；**白天禁「白」、夜间禁「黑」**，自动灰） |
| 标注 | `[隐藏] [显示] [左] [右]`（常显，按工具灰不可用项；**由原「价格标注」改名「标注」**——周期/斐波那契标的是根数/序号非价格，故不叫价格标注） |

**「标注(文字)」工具面板单独**（不套上表）：`字号(滑块 小→大) + 字色(9 色) + 文字形式(3 选 1)`。不含「标注」行。

### 3.1 每工具「线型子类 / 标注」可选矩阵

| 工具 | 直线 | 射线 | 线段 | 标注可选值 |
|---|:-:|:-:|:-:|---|
| 水平线 | ✅ | ✅ | 灰 | 隐藏/左/右（选射线时「左」再灰） |
| 趋势线 | ✅ | ✅ | ✅ | 整块灰 |
| 通道线 | ✅ | ✅ | ✅ | 整块灰 |
| 折线 | 灰 | 灰 | 灰 | 整块灰 |
| 黄金率 | 灰 | ✅ | ✅ | 隐藏/左/右（「显示」灰） |
| 波浪尺 | 灰 | ✅ | ✅ | 隐藏/左/右（「显示」灰） |
| 周期线 | 灰 | 灰 | 灰 | 隐藏/显示（左/右灰） |
| 斐波那契 | 灰 | 灰 | 灰 | 隐藏/显示（左/右灰） |
| 时间尺 | 灰 | 灰 | 灰 | 整块灰 |
| 箱体 | 灰 | 灰 | 灰 | 整块灰 |
| 标注(文字) | — 独立面板 — | | | —（不显此行） |

---

## 4. 数据模型总览（先看模型，再看各工具）（§P1，§11 详解契约）

### 4.1 `DrawingToolType`（扩为 11）
目标集：`horizontal, trend, channel, polyline, golden, wave, cycle, fib, timeRuler, text, rect`。
- 现有 `horizontal/trend/golden/wave/cycle` 直接映射对应工具。
- 新增 `channel(通道线)/polyline(折线)/fib(斐波那契)/timeRuler(时间尺)/text(标注)/rect(箱体)`。
- **legacy 处理**：现有 `ray`、`time` 两个 case——`射线` 已下沉为线型子类（不再是工具），`time` 语义歧义。生产已落地数据仅 `.horizontal`。P1 决定：`ray`/`time` 作为**已废弃 case 保留以容忍历史解码**（映射为忽略/迁移），或以 `fib`/`timeRuler` 取代；`DrawingToolType` 解码需 tolerant（未知→跳过，不 crash）。**该细节 P1 定，spec 钉死"不得因未知/废弃 toolType 崩溃"**。

### 4.2 `DrawingObject` 新增字段（附加式，Codable `decodeIfPresent` 兜底，沿 `revealTick` 先例）
- **`id: DrawingID`——持久稳定、跨层防碰撞的身份（codex R2/R3-high）**。用于选中命中→定位、`hiddenOriginalIds`、net-change 保留重数（防两条重复几何——同价水平线/重复标注——歧义）。**`DrawingID` 必须在 原训练线 / pending / reviewDrawings 全层唯一、不碰撞**：复盘渲染/选中把 原训练线 + `reviewDrawings` **合并**，若新线用「进程内单调」或旧 blob「裸下标回填」，其小整数会与原训练线 `drawings` 表小整数 PK **撞号** → 选错/隐藏错/net-change 折叠（codex R3-high）。**方案**：`DrawingID = UUID 字符串`——新画线（normal/replay/review）提交时 `UUID()`；**原训练线**用持久化的 `draw_uuid`（0009 新列，legacy 行迁移期确定性回填 `legacy-<record_id>-<rowid>` 唯一串，§11.3）。**禁进程内单调、禁裸数组下标**。旧 JSON blob 无 `id` → 解码回填一确定性唯一 id 并于下次保存持久化。
- `period: Period`——**画线绑定的周期**（§10 渲染据此）。取 `anchors.first.period`；显式落一份增强健壮性。
- `lineSubType: LineSubType`——`.straight/.ray/.segment`（**取代 `isExtended` 语义**；旧 `isExtended` 迁移：true→ray、false→straight）。
- `lineStyle: LineStyle`——`.solid/.dash1..dash4`。
- `thickness: Int`（1…5）。
- `colorToken: DrawingColorToken`（9 色枚举，语义 token；实际渲染色 + 昼夜可读性由主题解析）。
- `labelMode: LabelMode`——`.hidden/.show/.left/.right`。
- `locked: Bool`。
- **标注(text)专属**：`text: String`、`fontSize`、`textColorToken`、`textForm`（`.borderTransparent/.borderFilled/.plain`）气泡锚 = `anchors[0]`（落点，唯一必有锚）；**尾巴尖 = 独立可空字段 `tailAnchor: DrawingAnchor?`**（仅带框两形式 ①② 有值、`.plain` 为 `nil`；创建时给确定性默认偏移、可拖 360° 调整）。**渲染 / hitTest / net-change 一律经 `tailAnchor` 判空，绝不索引 `anchors[1]`**（防形式切换 / 旧 blob / 新建时锚数歧义崩溃或丢尾巴）。`decodeIfPresent` 兜底。
- `revealTick: Int`（现有，保留）。
- `panelPosition: Int`（现有，保留但**退化为派生/兼容字段**；渲染不再用它绑定，见 §10）。

> 具体是拆多列还是并入 JSON、枚举 rawValue 命名，属 P1 实现细节；spec 要求：**附加式、旧 blob 可解、`ReviewNetChange` key 补齐（§11.4）**。

---

## 5. 11 个工具逐一定义（几何 / 锚 / 渲染 / hitTest / 标签）

**通用**：所有工具用 `DrawingTool` 协议实现（纯 CoreGraphics + `CoordinateMapper`，host 可测几何 helper + 薄 render）。锚点经 `CoordinateMapper.xToIndex/yToPrice` 逆映射落 `DrawingAnchor`。图上标签**字号偏小、不喧宾夺主**。

### 5.0 多锚落点泛化（§P1，先决）
`ChartContainerView.handleDrawingTap` 现写死 `.horizontal` 单锚即提交。改为：用 `manager.activeTool`，每次单击 `addAnchor`，`shouldCommit(current:tool:)` 达到该工具 `requiredAnchors` 才 `commit + routeDrawingCommit + commitDrawing(退出)`；未达则留在 drawing 态继续收锚。折线特殊（不定锚数，§5.4）。
- **`routeDrawingCommit` 必须改为 copy-with-revealTick、保留 `DrawingObject` 全部字段**（id / lineSubType / lineStyle / thickness / colorToken / labelMode / locked / text / fontSize / textColorToken / textForm / tailAnchor / period）——现版本只从 5 个字段重建、会在**每次落锚提交时丢掉全部新字段**（stable-id / 文本 / 样式 / net-change / 按 id 选隐立刻崩，codex R3-high）。P1 加 normal + review 提交测试证 id/样式/锁定/文本/tailAnchor 存活（§1、D15）。

### 5.1 水平线（horizontal，1 锚，升级）
- 线型：直线（全宽横线）/ 射线（自落点向右到主图右缘）。**无线段**。
- 标注：隐藏/左/右（价格）；选射线时「左」灰（否则出屏外）。价格标签**紧贴线上方、不压线**；射线时靠右缘、防贵股 4 位价溢出。
- hitTest：`|point.y - lineY| ≤ 容差`（复用现 `HorizontalLineTool`）。

### 5.2 趋势线（trend，2 锚）
- 线型：直线（过两点无限延伸斜线）/ 射线（p1 过 p2 到右缘）/ 线段（p1-p2）。无标注。
- hitTest：点到线段/延长线的垂距 ≤ 容差。

### 5.3 通道线（channel，3 锚）
- p1、p2 定主线（按线型子类延伸）；过 **p3** 画一条**与主线平行**的第二线；两线之间**淡色半透明填充**（同线色，昼薄白/夜薄黑或所选色）。
- 射线时：过 p3 的平行线**沿其自身方向向 p3 左侧再延一小段**（更自然）。无标注。
- hitTest：命中任一条线或填充带内。

### 5.4 折线（polyline，N 锚）
- 逐点单击连成多段折线；**无线型子类**（默认线段串）；无标注。
- **画中底栏临时换 4 键**：`[取消划线] [完成划线] [回退] [前进]`（等宽）。「完成划线」收尾（因不定锚数）；回退撤销刚落的点（可连点）、前进恢复。
- 选中显每转折点为实心圆节点；**唯一支持删单节点**的工具（§7）。
- hitTest：命中任一段。

### 5.5 黄金率（golden，2 锚）
- 线型：射线 / 线段（**无直线**）。
- **7 条水平线**，比例自**第一锚=0**基准起：`0（第一锚价）/ 0.191 / 0.382 / 0.5 / 0.618 / 0.809 / 1.0（第二锚价）`。**不管第二锚在第一锚上方或下方，第一锚永远是 0**。
- 宽度：线段=横线只跨两锚 x；射线=各横线延到主图右缘。
- 标注（隐藏/左/右）：内容 = 比例 + 股价，**两列各自对齐**（比例列、股价列各有对齐基准，位数不同也整齐）。**比例离线最近**：标注在线右→整体左对齐（内侧比例、外侧股价）；在线左→整体右对齐（内侧比例、外侧股价）。**线段模式标签与横线同高**（不压线上方）；射线模式标签在右缘、贴线上方。
- hitTest：命中任一横线。

### 5.6 波浪尺（wave，3 锚）
- 线型：射线 / 线段（无直线）。
- **第三锚永远 = 0 基准**。竖线自 p3 出发，**方向 = 第一浪(p1→p2)方向**（p1→p2 向上→竖线朝上；向下→朝下）。沿竖线依次 `0（p3）/ 0.382 / 0.5 / 0.618 / 1.0 / 1.382 / 1.5 / 1.618 / 2.0`（8 比例 + 第 0 根），各带比例+股价（对齐同 §5.5）。
- **线段模式**：竖线**可见**，各比例位 = 以竖线为中心**左右对称的鱼骨短横线**。
- **射线模式**：竖线**不显示**，各比例位横线自 p3 x 向右射到主图右缘。
- **恒定默认虚线**（不受线样式设置影响）：p1-p2 连接线、p2-p3 连接线、**第 0 根（p3 那根）**。其余比例位线 + 竖线（线段模式）= 按波浪尺设置的线样式。
- hitTest：命中任一比例位线/竖线。

### 5.7 周期线（cycle，2 锚，无节点）
- **无线型子类**（默认竖线）；有实线/4 虚线 + 粗细 + 颜色。标注：隐藏/显示。
- 两锚点**横向吸附 K 线中心竖线**；以两点水平间距为一个周期，画**一组等间隔竖线**，**贯穿整个 K 线区顶到底**，向右重复到主图右缘（p2 在 p1 左则向左）。
- 标注（显示）：每条竖线**底部、贴 K 线区最底边、竖线右侧**标「第几根 K 线」（最左=0，向右 1、2、3…）。
- **无节点**：交互靠拖线——拖**第二根竖线**改间距（其余联动）、拖其它线整体左右平移（§7、§9）。
- hitTest：命中任一竖线。

### 5.8 斐波那契（fib，1 锚，无节点）
- **无线型子类**；有实线/4 虚线 + 粗细 + 颜色。标注：隐藏/显示。
- 单锚**横向吸附 K 线中心**；自锚点向右在第 `0,1,2,3,5,8,13,21,34,55,89…` 根 K 线各画一条竖线（**贯穿顶到底**）到主图右缘。标注同周期线（底部贴线右侧标序号）。
- **间距固定不可调**；只能整体左右平移（拖动整体）。**斐波那契不触发局部放大镜**（§9）。
- hitTest：命中任一竖线。

### 5.9 时间尺（timeRuler，2 锚，无线型子类）
- **无线型子类、无标注选项**（标注整块灰）；线样式（实/虚）看设置是否可选（默认）。
- 两端点**横向吸附 K 线中心竖线，纵向自由**（可落蜡烛上/下/空白）；连成一条平行测量线（两端小竖标，像数学线段度量）。上方文字标「**N 根 ≈ M 天**」（N=两端间 K 线根数；M=按当前周期换算的日历天数，**无小数**；不同周期同根数天数不同，需计算）。
- 拖动实时重算根数/天数。hitTest：命中测量线。

### 5.10 标注（text，文字，独立面板）
- 选「标注」→ 在 K 线**点落点**（= 气泡位置）→ 输入流程见 §8。
- 3 种文字形式（每种配所选颜色）：①同色字 + 同色边框 + 透明底 ②同色边框 + 同色填充 + 白字 ③无框纯色字。字号可调、字色 9 色（昼夜禁用同线色）。
- **带框两形式（①②）有可拖小尾巴**（尖 = 可空字段 `tailAnchor`；创建时默认落在气泡锚右下一确定性偏移处、可拖 360° 指向某 K 线/指标/线）；形式③（无框）`tailAnchor = nil`、无尾巴。**切换形式**：切到③保留数据但不渲染尾巴、切回 ①② 复用原 `tailAnchor`（无则重置默认）。渲染 / hitTest 判空、不索引 `anchors[1]`。
- 节点 = 气泡尾巴尖（§6）。hitTest：命中气泡框/尾巴。

### 5.11 箱体（rect，2 锚）
- **无线型子类**；有实线/4 虚线 + 粗细 + 颜色。无标注。
- 两锚 = 矩形对角；可极淡填充。两锚为节点（§6）。hitTest：命中边框/内部。

---

## 6. 节点模型（§P1）

- **有节点**（选中时显节点、可拖实时调整）：水平线、趋势线、通道线、折线、黄金率、波浪尺、时间尺、箱体、**标注（节点 = 气泡尾巴尖）**。
- **无节点**：**周期线、斐波那契**（靠拖线本身交互，§7/§9）。
- **节点样式**：**纯黑实心小圆、与线连成一体**（无白圈、无断裂）；夜间模式=纯白实心圆。仅选中态显示；非选中不显（折线亦然）。
- 拖节点 → 该线几何实时跟随。**仅折线**支持删单节点（其它线拖节点即可达成全部调整，删除=删整条）。

---

## 7. 选中 / 删除 / 锁定 / 撤销·前进（§P1）

- **选中（命中两层、返回 (层, id)）**：画线模式内单击，遍历该面板当前周期**所有可见画线**逐个 `hitTest` 命中——**复盘下原训练线 `drawings` 层 + `reviewDrawings` 层都要 hit-test**（不能只扫 review，否则原训练线永不可选、§12 隐藏无对象）。命中解析出 **(层, `id`)**：层 ∈ {original, review/own}，`id` = `DrawingObject.id`（§4.2；不用数组下标/字段派生 key，只有稳定 `id` 能在多层拼接 + 重复几何下无歧义定位一条）。
- **选中 ≠ 可变（按层门控操作）**：**复盘原训练线**（original 层）只可**隐藏/显示**、不可编辑/删除/拖节点；**复盘新画线 + 训练/replay 自有画线**（review/own 层）可**改样式/拖节点/锁定/删除**。选中后显节点（仅可编辑的线）、令设置面板/锁定/删除/隐藏按层作用于该 `id` 对应的线。
- **删除**（底栏🗑）：选中线被锁 → 🗑灰。否则点🗑弹确认：
  - 多数工具：`确定删除划线？[删除][取消]`。
  - **折线**且选中了某节点：`[删除选中节点] [删除整条划线] [取消]`（删节点后折线自动重连；可用⑥前进撤销此步）。
- **锁定/解锁**（底栏🔒）：短按锁定选中线（🔓→🔒图标态），锁定后该线不可改；**不在线旁画小锁图标**（仅底栏图标态体现）。锁定状态**持久化**（存记录/复盘存档）。
- **撤销/前进**（底栏↩/↪）：撤销**上一步任意操作**（画线/删除/删节点/拖动/改样式），**各仅一步**；前进恢复该步。
- （折线**画制中**另有 §5.4 的临时 4 键取消/完成/回退/前进，与底栏撤销/前进不同层：前者管当前折线的锚点，后者管已完成动作。）

---

## 8. 文字标注输入流程（§P3，键盘遮挡定案）

1. 选「标注」工具 → 先在 K 线点落点（= 气泡/标注生成位置，就在点击处）。
2. 弹系统键盘；**紧贴键盘上方**出一个近全宽文本输入框（可见、可粘贴）；输入的字实时进该框，同时同步进落点气泡（气泡可能被键盘挡，但输入框恒可见）。
3. 键盘按**「换行」→ 收起键盘**；输入框随之**下落到底栏上方、紧贴底栏**，文字仍在框内。
4. 要改 → 点该文本框 → 再弹键盘。**最终确认 = 点屏幕其它任意处**（框消失、气泡定稿）。
5. 之后再改 → 点那个气泡 → 底栏上方又出现文本框 → 点它 → 弹键盘。

> 落点先粗放、后可拖尾巴/气泡精调（带框形式尾巴 360° 指向）。此流程即键盘遮挡的最终方案（不采用"图上移/顶部固定条"等其它候选）。

---

## 9. 局部放大镜 + 吸附（§P4）

- **触发**：**有节点工具拖节点** + **周期线拖线调整**（调间距/平移）时；**斐波那契不触发**（间距固定、无需精确）。
- **放大镜**：中心 = 手指触点/被拖节点（节点在放大区**正中**，上下左右居中）；位置 = **对面板、离画线那栏最远的那半**——在**上面板**画→放大镜占**下面板底半（贴屏底）**；在**下面板**画→占**上面板顶半（贴顶）**；**宽 = K 线显示区全宽、高 ≈ 半面板**。内含放大的 K 线 + 其它画线 + 被拖节点。
- **网格量化**：拖动**始终按网格一格格走**（快、跟手、不卡，但可感知走格）→ 即使没开吸附也能较精确落到网格点（K 线高/低点等）。
- **吸附**（默认开）：额外**吸附就近 K 线最高/最低点**（手一动即离开、再靠近再吸）。
- **吸附开关**：底栏**「锁定」键长按** → 弹一个**左右滑动小滑块 toggle**（标「吸附」，开=绿色）。（此为局内开关；全局默认在 §13 主页画线设置。）

---

## 10. 画线绑定「周期」而非面板（§P1 关键）

- 每条画线绑定它**被画时所在面板的周期**（`DrawingObject.period`，§4.2）。
- **渲染改判据**：现 `RenderStateBuilder.swift:67-69` 按 `panelPosition==(panel==.upper ?0:1)` 过滤 → **改为按「该面板当前显示的周期 == drawing.period」过滤**（叠加现有 `revealTick <= tick` 渐显规则不变）。某周期不在任一面板显示 → 其画线暂不渲染，切回再现。
- **场景**：上=60 分、下=日线，两图各画了线；单指竖滑后上=15 分、下=60 分 → 原 60 分的线跟到下半面板显示、日线的线暂隐、15 分空白可画、60 分线仍可选改。
- 画线模式下**单指竖滑切周期仍可用**（复用 RFC-C `onVerticalSwipe`→`switchPeriodCombo`）。
- `panelPosition` 字段保留但**不再作渲染绑定**（提交时仍可记当时面板，作兼容/派生）。

---

## 11. 数据模型大改 + 契约（§P1 起，跨阶段）

### 11.1 `DrawingObject` 字段扩充
见 §4.2。附加式、`decodeIfPresent` 兜底（旧 blob 无新字段→取语义默认：`isExtended`→`lineSubType`、其余取「实线/1 档/默认色/隐藏标注/未锁/period=anchors.first.period/`tailAnchor`=nil」）。

### 11.2 pending / review JSON 持久形状（P1 定死，防版本错位，codex R2-high）
- `pending_training.drawings`、`pending_replay.drawings`：整体 JSON blob 存 `[DrawingObject]`——经 Codable **自动携带新字段（含 `id`）**，无需改列。
- **`review_archive.working_drawings/saved_drawings`：形状在 P1 就固定为容错 wrapper**。**canonical 磁盘 JSON schema（P1 钉死、全阶段唯一）** = `{ "drawings": [DrawingObject], "hiddenIds": [DrawingID] }`——**on-disk key 就叫 `drawings` / `hiddenIds`**，对应 in-memory `ReviewWorking`/`ReviewArchive` 的 `reviewDrawings` / `hiddenOriginalIds`，用**显式 `CodingKeys` 映射**（禁任何阶段改 key 名/换形状）。**解码器容错**：既解旧的裸 `[DrawingObject]` 数组（→ `hiddenIds=[]`）、也解 wrapper 对象（`try 数组 else wrapper`）。随 P1 的 `1.11`/`user_version 7` ship；**hide/show UI 虽 P5 才落地，但形状 P1 定死，P5 不改形状/key、不迁移**（否则只认数组的 P1–P4 构建读 P5 wrapper 解不出、复盘存档不可读/autosave 失败）。**P1 加兼容 fixtures 往返测**：①裸数组 ②空 wrapper `{drawings:[],hiddenIds:[]}` ③drawings-only ④hidden-only 四态（codex R7-high）。

### 11.3 finalized `drawings` 关系表 + 迁移
`drawings` 表现为分列（`tool_type/panel_position/is_extended/anchors(JSON)/reveal_tick`）。新样式/文本/period 字段需落库：
- **方案（推荐）**：迁移 **`0009_v1.11_drawing_style`** 给 `drawings` 加**两列**——① **`style_json TEXT`**（可空，承载样式/文本/tailAnchor 等新字段束，`RecordRepository` 编解码进出；旧行 NULL→取默认）；② **`draw_uuid TEXT`**（原训练线的跨层防碰撞身份，§4.2/D16；legacy 行迁移期确定性回填 `legacy-<record_id>-<rowid>` 唯一串）。（备选：样式逐字段加列，沿 `reveal_tick` 先例；列数多，spec 倾向单 JSON 列，P1 定。）
- `PRAGMA user_version = 7`；`CONTRACT_VERSION "1.10" → "1.11"`（m01 §A 类"改既有语义"；连带 CODEOWNERS approve 门）。
- **只走 migration，不动 `v1_4_baselineDDL` / `app_schema_v1.sql`**（v1.4 冻结基线，drift-checked——沿 0006/0007/0008 先例）。
- **原训练线身份 = `draw_uuid`（canonical 唯一字段，不用整数 PK）**：`RecordRepository` 读记录画线时把该行的 `draw_uuid`（0009 列、legacy 回填）带进 `DrawingObject.id`。`hiddenOriginalIds` / 选中命中 / `ReviewNetChange` **一律引用同一个 `draw_uuid` 串**，**绝不混用 `drawings` 表整数 PK**（否则 P1 写 UUID、P5 按 PK 命中会失配 → 隐藏/选中/净改动错，codex R4-high）。整数 PK 仅作表行主键、不进 `DrawingObject.id`。

### 11.4 `ReviewNetChange.changed` key 补齐（关键，防漏判）
现 per-drawing key = `toolType|panelPosition|isExtended|revealTick|anchors`（**排序字段 key 集**——会把重复几何折叠，codex R2-high）。本 RFC 改为**按 `id` 归组、保留重数**比较：每条按其 `id` 比对全字段（补 `period/lineSubType/lineStyle/thickness/colorToken/labelMode/locked/text/fontSize/textColorToken/textForm/tailAnchor`），否则复盘中仅改样式/文本/锁定而几何不变时净改动**静默漏判**（沿 revealTick 整改④先例），且重复几何各自独立比对不折叠。**此外，复盘净改动在 review-state 层还须比较 `hiddenOriginalIds` 集（§11.5）**——仅隐藏 / 仅显示原训练线的编辑也须判脏，否则不触发 autosave、标记错乱（codex R1-high）。

### 11.5 复盘「隐藏原训练线」存储（形状 P1 定死 / hide-show UI §P5）
**复盘工作态/存档态 = 一个原子整体** `{ reviewDrawings: [DrawingObject], hiddenOriginalIds: [DrawingID]（被隐藏原训练线的 id 集，用其 `draw_uuid` = 与渲染 `DrawingObject.id` **同一字段**，唯一无歧义） }`。`hiddenOriginalIds` **必须与 `reviewDrawings` 同存、同取、同判净改动与标记**（**不是**旁路独立列/独立写路径——否则 hide/show-only 编辑不脏、不 autosave、与 `working_step_tick`/`working_drawings` 失步，隐藏线返回后重现或标记错乱，codex R1-high）：
- `ReviewArchiveRepository` 的 `ReviewWorking`/`ReviewArchive` 结构**扩承 `hiddenOriginalIds`**；`saveWorking`/`commitSaved` 在**同一 UPSERT 事务原子写**二者。
- `ReviewNetChange.changed(working:committed:)` **同时按 id 比较 drawings（保留重数）+ `hiddenOriginalIds` 集**——仅隐藏/仅显示也判净改动（脏）→ 触发 autosave、参与「删空清已复盘」。
- autosave 触发面：`engine` 暴露 `hiddenOriginalIds`（`@Observable`），`TrainingView` 除 `.onChange(reviewDrawings.count)` 外**也 onChange 隐藏集**（或统一一个 review revision）→ 隐藏/显示即时 autosave。
- **唯一持久隐藏态 = `hiddenOriginalIds`**（仅 per-line「隐藏」/「显示」增删它）。**`全部显示/全部隐藏` 是非持久 UI-only 视图覆盖**——**不进 wrapper、不进 `ReviewNetChange`、不触发 autosave、每次进复盘重置为「按 `hiddenOriginalIds` 隐藏」**（codex R5-high，D17）。
- **落库 = §11.2 的 canonical 容错 wrapper**：on-disk key = `drawings`/`hiddenIds`（映射 in-memory `reviewDrawings`/`hiddenOriginalIds`，显式 CodingKeys），解码容错裸数组；**形状 P1 定死随 `1.11` ship，P5 不改形状/key、不迁移**（消除版本错位，codex R2/R7-high）。P5 只加写 `hiddenIds` 的 UI/逻辑。**契约由本 spec 钉死：隐藏态是复盘原子状态的一部分**。

---

## 12. 复盘集成（§P5，承接 #139 §8 延后项）

- **复盘中画线**：已有（`showsDrawingTools` 含 review、`routeDrawingCommit` 写 `reviewDrawings`）。本 RFC 令复盘也走同一画线模式外壳（底栏 6 键）。
- **复盘画线删除（接线 `removeReviewDrawing`）**：选中命中**层=review** 的一条画线（§7 返回 (层,id)）→ 🗑删除 → 按 `id` 解析 `reviewDrawings` 索引 → 调 `removeReviewDrawing(at:)` → 触发复盘 autosave。命中**层=original** 的原训练线时 🗑 不可用（只读、仅可隐藏，§7 层门控）。
- **隐藏原训练线**：复盘底栏第 6 键「隐藏」——单击选中一条**原训练线**（只读）→ 点「隐藏」→ 该线转虚影/隐藏（存 `hiddenOriginalIds` 集，用该线 `draw_uuid` = 渲染 `DrawingObject.id` **同一字段**，唯一无歧义，§11.5）。**长按「隐藏」键**弹小菜单 `[全部显示] [全部隐藏]`——这是**非持久的 UI 视图覆盖**（**不改 `hiddenOriginalIds`、不进 `ReviewNetChange`、不触发 autosave、每次进复盘重置**）：全部显示=临时把已隐藏线显出便于操作、全部隐藏=再临时收起；菜单贴近隐藏键、小巧。全部显示态下选中一条已隐藏线 → 底栏该键显示为「显示」→ 点它 = **从 `hiddenOriginalIds` 移除该 id**（**持久 un-hide**，此后不受全部显示/隐藏影响）。
- **净改动 / 标记**（沿 #139）：复盘 autosave 经 `persistReviewWorkingIfChanged`（净改动 = **原子态** `{reviewDrawings, hiddenOriginalIds}` vs committed 基线，§11.5）；画线/删除/改样式/**隐藏/显示**都经 §11.4 的 **id 归组比对 + `hiddenOriginalIds` 集**参与净改动判定（隐藏/显示编辑亦判脏、亦 autosave）；**删+显示回到 committed 基线 → clearWorking → 清「复盘中」**（现有机制自动成立，前提是每类编辑都触发 autosave）。
- **§12.4 「删空清已复盘」收口**：现 `commitSaved([])` 写 `"[]"`（非 NULL）→「已复盘」不清。**特判须对整个原子态判空**（codex R6-high）：仅当 **`reviewDrawings.isEmpty && hiddenOriginalIds.isEmpty`**（或整个 `{reviewDrawings, hiddenOriginalIds}` == 空 committed 基线）时走 `clearSaved`；**hide-only（`reviewDrawings==[]` 但 `hiddenOriginalIds` 非空）必须正常 `commitSaved` 保存**、不可当空存档清掉（否则丢隐藏态 + 错清标记）。加 hide-only saved / hide-only working 验收测试。（此即 #139 codex whole-branch 标过、override 延后至本 RFC 的那条。）

---

## 13. 主页「画线设置」（全局默认）（§P6）

- 主页右上角齿轮 → 设置菜单加「**画线设置**」项。
- 点「画线设置」→ **不弹窗**，界面同训练画线布局：**底栏只有一个「吸附」滑块（全局默认吸附开关）** + **紧贴底栏上方一行 11 工具图标**；点某工具 → 其**默认设置面板**弹在类型行上方（同 §3 模板；标注工具弹字号/字色/形式）。
- 这些是**全局默认值**（持久化，`SettingsStore`/设置层）；每局训练/复盘按此**初始化**新画线的样式；用户局内再改则在该记录/复盘**局部覆盖**（不回写全局）。
- 全局吸附默认亦在此设。

---

## 14. 手势编排（接 `ChartGestureArbiter` C7）（§P1，§P4）

画线模式（`drawingMode=true`）需消歧共存以下单/双指手势：
- **单击**（`onTap`）：落锚（画制中）或选中（已有画线，命中 hitTest）。
- **单指横向拖**：平移图表（`onPan` 水平分量）。
- **单指竖向甩**：切周期（`onVerticalSwipe`→`switchPeriodCombo`，复用 RFC-C）。
- **单指拖在节点上**：移节点（新增；起手命中某选中线的节点 → 进入节点拖动，触发放大镜/吸附，§9）。
- **双指**：缩放（`onPinch`）。

现 `drawingMode` 语义是「单指 Pan 被绘线截获、单击 fire onTap」。本 RFC 需细化：**区分"起手是否落在选中线的节点上"**（是→节点拖动；否→按方向分平移/切周期），并保证与选中/落锚不打架。此为 arbiter 扩展（沿 C7 纯函数 step 风格 + host 测），P1/P4 落地；spec 钉死"画线模式不得吞掉平移/切周期/缩放"。

---

## 15. 分阶段交付 P1…P6（一份 spec，六个 PR）

每阶段：独立 worktree 分支或续用本分支的顺序 PR、独立 plan（含**中文非程序员验收清单**——治理要求）、真 codex branch-diff 收敛、三绿（host swift test + Mac Catalyst build-for-testing + iOS build）、requesting-code-review + whole-branch codex、PR。

| 阶段 | Scope | 契约/迁移 | 依赖 |
|---|---|---|---|
| **P1 地基 + 外壳 + 线型系统 + 选中编辑 + 基础几何工具** | 数据模型大改（§4/§11，**含持久 `id` 身份 + 复盘 JSON 容错 wrapper 形状定死 §11.2**）；画线模式外壳（§2）；统一设置面板 + 线型/样式/颜色/标注系统（§3）；节点模型 + 选中（按 id）/删除/锁定/撤销·前进（§6/§7）；多锚落点泛化（§5.0）；周期绑定渲染（§10）；手势消歧（§14）；**工具**：水平线（升级）、趋势线、通道线、箱体、折线 | **0009 / 1.10→1.11 / uv 6→7**（一次到位，含复盘 wrapper 形状） | 基线 #139 |
| **P2 比例/测量类工具** | 黄金率、波浪尺、周期线、斐波那契、时间尺（几何 + 计算标签 + 两列对齐 + K 线中心吸附） | 无（复用 P1 模型） | P1 |
| **P3 文字标注** | 标注(text) 工具 + 字号/字色/3 形式 + 气泡尾巴 + 输入流程（§8）（文本字段在 P1 模型已就位） | 无（P1 已含 text 字段）* | P1 |
| **P4 局部放大镜 + 吸附** | 放大镜 loupe（§9）+ 吸附 K 线高/低点 + 网格量化 + 吸附开关（局内 + 全局默认预留） | 无 | P1（工具越多越有用，故排 P2/P3 后） |
| **P5 复盘集成** | 复盘画线删除（接 `removeReviewDrawing`）+ 隐藏原训练线（全部显示/隐藏 + 单条永久显示）+ **复盘原子态 `{reviewDrawings, hiddenOriginalIds}` 持久化**（§11.5，形状 P1 已定）+ 「删空清已复盘」（§12） | **无迁移**（复盘 JSON 容错 wrapper 形状 P1 已定死，§11.2；P5 仅写 hiddenIds 逻辑） | P1（+ 各工具 hitTest，故排后） |
| **P6 主页画线默认设置（全局）** | 齿轮「画线设置」入口 + per 工具默认 + 全局吸附 + 每局初始化（§13） | 全局设置持久化（SettingsStore，非 DB schema 或轻迁移） | P1（消费各工具设置面板） |

> *P3 注：文本字段建议在 P1 一次性纳入 `DrawingObject`/迁移（避免二次 bump），P3 只做 text 工具的 UI/渲染/输入流程。若 P1 不纳入 text 字段，则 P3 自带一次迁移+bump——**P1 一次纳入更优**，spec 采此。
> 顺序可微调（用户已认可当前提案）：如需放大镜提前或主页设置延后皆可，由 writing-plans 定稿。
> **P1/P5 边界（codex R7-medium，D19）**：P1 画线模式仅面向**训练/replay**；**复盘专属（6 键栏含隐藏、复盘删除、隐藏持久化、clear-saved）全在 P5**。**P1 在复盘模式下隐藏/禁用这些入口**并加测试证不暴露任何未接线的复盘动作——避免 P1 ship 出死/无持久的复盘控件。（复盘 JSON wrapper 形状虽 P1 定死随 1.11 ship，但**写 `hiddenIds` 的行为逻辑与 UI 全在 P5**。）

---

## 16. 关键设计决策（钉死给 codex defense-in-depth）

- **D1 画线绑定 period 非 panelPosition**：用户要求切周期后线跟周期走（§10）。渲染判据改 period 匹配；`panelPosition` 退化兼容。**理由**：双面板 + 单指竖滑切周期是核心玩法，按面板位置绑定会导致切周期后线错位/串图。
- **D2 射线/线段/直线 = 线型子类，非独立工具**：文华里这三是"每种线的画法"，不是并列工具。`.ray` enum case 退役为子类。**理由**：与文华一致 + 统一设置模板。
- **D3 黄金率第一锚=0**：用户明确（离第一锚最近的内部线=0.191，第二锚=1）。**理由**：文华行为；不管方向第一锚恒 0。
- **D4 波浪尺竖线方向=第一浪方向、第三锚=0、连接线+第0根恒虚线**：用户逐字定义（§5.6）。**理由**：文华波浪尺=三点黄金测幅投射，非波浪计数。
- **D5 复盘原训练线只读、可隐藏不可删；复盘新画线可删**：删走 `removeReviewDrawing`（只动 `reviewDrawings`），隐藏走 `hiddenOriginalIds` 集（不改 `engine.drawings`）。**隐藏集 = 复盘原子工作/存档态的一部分**（与 `reviewDrawings` 同存、同判净改动，§11.5），**非旁路独立列**——防 hide/show-only 编辑丢失或标记错乱（**codex R1-high**）。**理由**：不污染原训练记录（沿 #139 committed 不可变原则）+ 原子持久化。
- **D6 `ReviewNetChange` 判定必补齐**：per-drawing key 补全部新字段（含 `tailAnchor`）；**review-state 层追加比较 `hiddenOriginalIds` 集**——否则改样式/文本/锁定/隐藏而几何不变 → 净改动漏判 → 复盘中/已复盘标记错。**理由**：#139 整改④补 revealTick 的同类教训。
- **D7 「删空清已复盘」= `clearSaved` 特判，判空须对整个原子态**：仅 `reviewDrawings.isEmpty && hiddenOriginalIds.isEmpty`（或 == 空 committed 基线）才 clearSaved；**hide-only（有隐藏无画线）须正常保存不可当空清**。**理由**：现写 `"[]"` 非 NULL 致标记不清（#139 whole-branch override 延后至本 RFC）；只按画线数组判空会误删 hide-only 存档（**codex R6-high**）。
- **D8 一次性纳入全部模型字段（含 text）+ 单次 bump（1.10→1.11）**：P1 就把 `DrawingObject` 扩全，后续阶段零契约。**理由**：避免多次 bump + 多次 CODEOWNERS 门 + 多次迁移链风险。
- **D9 DrawingToolType 解码 tolerant**：未知/废弃 toolType 不得 crash（跳过）。**理由**：跨版本 blob 前后兼容。
- **D10 画线模式不得吞平移/切周期/缩放**：arbiter 消歧须保留图表操作（§14）。**理由**：用户明确要求画线时仍可拖动缩放切周期。
- **D11 标注尾巴 = 独立可空 `tailAnchor` 字段，非 `anchors[1]`**：创建只落 1 锚（气泡锚）；尾巴按形式给默认/可空（`.plain` 为 nil）；渲染/hitTest/net-change **判空、绝不索引 `anchors[1]`**；三形式 + 形式切换 + 旧 blob 均有容错。**理由**：单锚创建 + `.plain` 无尾 → `anchors[1]` 歧义会崩或切换形式时丢尾巴（**codex R1-medium**）。
- **D12 复盘态是原子整体 `{reviewDrawings, hiddenOriginalIds}`**：同存、同取、同判净改动、同参与标记（§11.5）；并入 working/saved JSON wrapper（无新列、原子天然）。**理由**：隐藏是复盘编辑的一等操作，旁路存储会与 working 失步（**codex R1-high**）。
- **D13 每条画线有持久稳定 `id`；canonical = `draw_uuid`/UUID 串，全层同一字段**：原训练线用 `draw_uuid`、新线铸 UUID；选中命中 / `hiddenOriginalIds` / net-change / `RecordRepository` **全引用同一 `id` 字段**（保留重数），**不混用整数 PK**（PK 仅表行主键）。**理由**：无 id + 字段派生 key 会让重复几何隐藏错线、净改动折叠漏判（**codex R2-high**）；PK 与 UUID 混用会 P1/P5 命中失配（**codex R4-high**）。
- **D14 复盘 JSON 持久形状在 P1 就定死为 canonical 容错 wrapper**：on-disk key = `drawings`/`hiddenIds`（显式 CodingKeys 映射 in-memory `reviewDrawings`/`hiddenOriginalIds`，禁改 key/形状），解裸数组 | wrapper 双形，随 `1.11` ship；P5 不改形状/key/不迁移；P1 加 裸数组/空/drawings-only/hidden-only 四态 fixtures。**理由**：形状/key 延到 P5 改会造成 P1–P4 只认数组或另一 key 的构建读 P5 wrapper 解不出的版本错位（**codex R2/R7-high**）。
- **D15 `routeDrawingCommit` 改 copy-with-revealTick、保留全字段**：现只从 toolType/anchors/isExtended/panelPosition/revealTick 重建 → 每次落锚提交丢 id/样式/锁定/文本/tailAnchor，破坏 stable-id/文本/样式持久/net-change/按 id 选隐。P1 改为「盖 revealTick 但保留其余全字段」+ normal/review 提交测试证字段存活。**理由**：**codex R3-high**。
- **D16 `DrawingID` 跨层防碰撞（非仅数组内稳定）**：原训练线（`draw_uuid`）+ pending + reviewDrawings 合并后须全局唯一——用 UUID/唯一串，**禁进程内单调、禁裸下标回填**（会与原 PK 小整数撞号 → 选错/隐藏错/net-change 折叠）。**理由**：**codex R3-high**。
- **D17 `全部显示/全部隐藏` = 非持久 UI-only 视图覆盖**；唯一持久隐藏态 = `hiddenOriginalIds`（仅 per-line 隐藏/显示增删）。bulk 模式不进 wrapper/net-change/autosave、每次进复盘重置。**理由**：否则 bulk 与 per-line 语义纠缠、autosave/replay 恢复歧义（**codex R5-high**）。
- **D18 复盘选中命中两层、操作按层门控（选中 ≠ 可变）**：hit-test 原训练线 `drawings` + `reviewDrawings` 两层，返回 (层, id)；原训练线只可隐藏/显示，review/own 画线可编辑/删除。**理由**：若命中只扫 `reviewDrawings`，原训练线永不可选 → §12 隐藏动作无对象、隐藏功能不可达（**codex R6-high**）。
- **D19 复盘专属控件全属 P5，P1 不暴露**：P1 画线模式只面向训练/replay；复盘 6 键栏/隐藏/删除/隐藏持久化/clear-saved 全 P5，P1 前隐藏/禁用 + 测试证不暴露未接线动作。**理由**：否则 P1 独立 PR 会 ship 出死/无持久的复盘控件（**codex R7-medium**）。

---

## 17. 验收 / 契约指针

- 每阶段 plan 各带 `docs/superpowers/acceptance/2026-…-<phase>.md`（中文非程序员动作/预期/通过标准清单，治理要求）。
- 契约：`CONTRACT_VERSION 1.10→1.11`（P1）；迁移 `0009`（P1，`user_version 6→7`，含 `style_json` + `draw_uuid` 两列）；**P5 无复盘 JSON/schema 迁移**（复盘 wrapper 的解码器/写入/兼容测试由 **P1** owns，§11.2/D14）；`ios/sql/app_schema_v1.sql` 冻结基线不动。
- host 几何纯函数（各工具 lineY/points/hitTest/labels 对齐/根数天数换算）全 host `swift test` 断言；UIKit 薄层（render/放大镜/手势）走 Mac Catalyst build-for-testing 编译闸门。
- 评审通道：真 Codex `.claude/scripts/codex-attest.sh --scope branch-diff`（每阶段各自跑）。

---

## 附：留待 codex / writing-plans 阶段细化的点
1. `DrawingObject` 样式字段落库=单 `style_json` 列 vs 逐列（§11.3，倾向单列）；`draw_uuid` legacy 回填串确切格式（§4.2/§11.3/D16）。P1 定。
2. `.ray`/`.time` 两个 legacy enum case 的确切退役/迁移方式（§4.1）。
3. 命中定位、id 方案已**在正文钉死**（§4.2/§7/D13/D16）：新画线 UUID、原训练线 `draw_uuid`、legacy JSON blob 用**命名空间确定性唯一串**回填——**禁进程内单调、禁裸下标**。P1 只定回填串的确切编码格式 + 跨层合并去碰撞测试（**非重开方案选择**）。
4. 手势 arbiter 中"起手是否落在节点上"的判定阈值与纯函数 step 形态（§14）。
5. 放大镜的具体缩放倍率、网格粒度、渲染复用 `RenderStateBuilder` 几何的方式（§9）。
6. 各阶段是否续用同一分支顺序 PR vs 每阶段新 worktree（writing-plans/交付时定）。
