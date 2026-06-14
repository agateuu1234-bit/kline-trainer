# Wave 3 顺位 1 RFC — spec-gap 治理（tier 公式 / 显示语义 / 夜间调色板 / E5·E6 engine 扩展 / replay 结算 / 中断持久化 / finalize 原子性）

**性质**：纯文档 governance RFC（**0 业务代码**）。沿用 E2 RFC（`project_pr64_e2rfc_merged`）+ Wave 2 顺位 1 RFC（`project_pr79_wave2_pr1_merged`）先例：改 spec 本身 = governance，走单独设计文档 + 自有 codex/opus 对抗评审闭环。

**前置**：Wave 3 outline（`docs/superpowers/specs/2026-06-09-wave3-outline-design.md`）§三.1 已批准本锚 scope（user 2026-06-09 选「前置一个治理 RFC 锁住」）。本设计把 outline §三.1 的 8 项契约钉死为权威定义 + 设计理由块，作为顺位 3/4/6/7/8/9/10 的实施输入；实施锚不得现编未治理公共面。

**关键 grep-first 校正（核实 2026-06-10，沿用 `feedback_brainstorming_grep_first`）**：outline §三.1 把 8 项一律描述为「未定 / 拒臆造 / dispute」。**实测冻结 spec + 现有代码后，多数其实已显式定义**——本 RFC 对这些只做 **reconcile + 引用 + grep-gate 残留措辞**，仅对真正空白的派生/参数/API 面做新契约。每项 §4.x 首行标注 spec 现状（explicit / silent / ambiguous）+ 证据行号，防止评审在已定项上反复下钻。

---

## 一、目标

七类契约经单一 RFC 钉死（outline §一「所有 spec gap 集中顺位 1 RFC」原则），避免散落实施锚被 codex 拿未定 spec 字面无限挑战（per `feedback_codex_distributed_reliability_drilldown`）：

- **(A) tier 显示公式**（§4.1）：U2-R3「顶栏仓位 X/5」。**buy/sell action tier 已 explicit**（plan L602-610），缺的是**当前持仓档位 X 的派生公式**（如何从 shares/price/capital 算 0..5）。RFC 定派生公式 + 边界。
- **(B) 结束 vs 当前总资金 显示语义**（§4.2，E6b-R1）：**spec 已 explicit**（plan L914 顶栏实时 / L997 结算冻结）。RFC 只 reconcile + 引用 + 杀「dispute / 未定」措辞，**不新增契约**。
- **(C) 夜间调色板 + display_mode**（§4.3）：**解析 + 持久化 + DisplayMode 枚举已 explicit**（Theme.swift / modules L406 / plan L472）；现有 13 token 已是 dark 取向。缺的是 **light 变体 + per-scheme token 选取接线** 的契约。
- **(D) E5/E6 engine 契约扩展**（§4.4，全 Wave 3 engine 变更集中顺位 6，serial neck，outline R8-F1）：5 子项（手动强平 on-demand / tier accessor / 画线 commit append / pinch zoom panel-state / replay-settlement payload）的 engine API 面。**行为多已 spec'd，缺 API surface**。（zoom 除外，见 §4.4 总纲注记）
- **(E) Replay 结算契约**（§4.5，PR11-R2）：replay 结束触发结算窗的数据来源（消费 §4.4e payload）；顺位 8 = UI/routing-only。
- **(F) 中断持久化参数化**（§4.6，outline item 6）：`saveProgress`「每 N tick 自动调用」**契约已存在**（modules:1676）但 **N + coalescing + background flush + 失败处理 未定**。RFC 参数化（不决策「是否做」——spec 已定要做）。
- **(G) finalize 原子性 + 失败保留 + 单事务 port + 幂等 + schema 迁移 + 终态 fence + discard 终态 + provenance 恢复**（§4.7，outline item 7 + R11-F3）：最重契约。现状有真实数据丢失 / 重复 record / pending 复活 / 误删 app.sqlite 风险。

**0 业务代码改动**（仅 spec/governance/RFC 文档 + acceptance + 1 验证 shell）。

---

## 二、编辑范围边界（核心纪律）

只 reconcile / amend **live 权威源**；**冻结的历史 plan/spec point-in-time 文档一律不改写**（沿用 Wave 2 顺位 1 RFC §二）。

| 类别 | 文件 | 处理 |
|---|---|---|
| **live 权威 spec（governed amendment）** | `kline_trainer_modules_v1.4.md`（E5/E6/Theme/saveProgress 契约面）、`kline_trainer_plan_v1.5.md`（tier 显示 / 结算显示 / 夜间 / 手动结束）| ✅ amend（加契约块 + changelog 行 + 本 RFC 引用） |
| **live 规划输入** | `docs/superpowers/specs/2026-06-09-wave3-outline-design.md`（Wave 3 outline §三.1）| ✅ supersede banner：标记「未定 / 拒臆造 / dispute」措辞已被本 RFC 取代，**不删历史描述**，加 marker 使后续 planner 先撞标记（谓词守护） |
| **冻结历史 plan/spec** | `docs/superpowers/plans/2026-05-*`、`docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md` 等 point-in-time | ❌ 不改写 |
| **业务代码 / schema / CI** | `ios/**`、`*.swift`、`*.py`、`*.sql`、`.github/**`、`*.xcodeproj` | ❌ 0 改动（实施归各下游锚） |

**freeze 说明**：`kline_trainer_modules_v1.4.md` / `kline_trainer_plan_v1.5.md` 虽在 `wave0-frozen-v1.4` tag 的 point-in-time 快照内，但 **live 文件持续接受 governed RFC amendment**（E2 RFC 改 §4.2、Wave 2 顺位 1 RFC 改 modules §P6/§Wave2 均为先例）。freeze tag = 参考点，非文件写锁；amendment 经 changelog + RFC 引用追溯。

---

## 三、Scope 七项 + 精确编辑目标

| # | 契约 | 主编辑目标（live 权威源） | 动作 | 实施锚 |
|---|---|---|---|---|
| 1 | tier 显示公式 | `kline_trainer_plan_v1.5.md` §6.2 顶栏（L916 区块）| 加「当前持仓档位 X 派生公式」契约块（§4.1）| 6 accessor + 7 显示 |
| 2 | 结束 vs 当前总资金 | `kline_trainer_plan_v1.5.md` L914/L997 区块 | reconcile 措辞 + 引用本 RFC §4.2；杀「dispute/未定」| 7 |
| 3 | 夜间调色板 + display_mode | `kline_trainer_modules_v1.4.md` §F2 Theme（L834 区块）+ `kline_trainer_plan_v1.5.md` §Phase 5 / L472 | 加「light/dark 双 token 集 + per-scheme 选取 + 持久化」契约块（§4.3）| 9 |
| 4 | E5/E6 engine 扩展 | `kline_trainer_modules_v1.4.md` §E5/§E6（saveProgress L1676 区块 + engine 契约段）| 加 5 子项 engine API 契约块（§4.4）| 6 实现，3/4/7/8 消费（zoom 除外，见 §4.4 总纲注记） |
| 5 | Replay 结算契约 | `kline_trainer_modules_v1.4.md` §E6 finalize 区块 | 加 replay-settlement payload 来源契约（§4.5）| 6 payload + 8 UI |
| 6 | 中断持久化参数化 | `kline_trainer_modules_v1.4.md` §E6 saveProgress（L1676 区块）| 加 N/coalescing/background-flush/失败 契约块（§4.6）| 10 |
| 7 | finalize 原子性 + 恢复 | `kline_trainer_modules_v1.4.md` §E6 finalize/endSession 区块 | 加 失败保留 + 单事务 port + 幂等 + schema 迁移 + fence + discard + provenance 契约块（§4.7）| 10a/10b |
| — | grep gate | 本 RFC §五 + acceptance + `scripts/governance/verify-wave3-pr1-rfc.sh` | 见 §五 | 本 PR |

> 具体插入行号由实施锚（subagent-driven）按 heading/anchor 定位；本表给 §/区块归属，遵守 outline「契约归属非代码行内联」抽象纪律。

---

## 四、契约定义（权威 + 设计理由块）

> 每项首行：**spec 现状 + 证据**。深度按真实空白比例缩放——已 explicit 项短（reconcile），真空白项长（新契约 + 理由 + acceptance + 实施归属）。

### 4.1 tier 显示公式（仓位 X/5 派生）

**spec 现状：action tier explicit（plan L602-610 买入「总资金 × 1/5..5/5」、L640 卖出「持仓股数 × 比例」；modules L403 `PositionTier` "1/5".."5/5"）；顶栏「当前持仓档位 X/5」(plan L916) 的派生公式 silent。** 代码：`TrainingEngine.currentTotalCapital`（`TrainingEngine.swift:235`）+ `cashBalance` 在；**无 `currentPositionTier` accessor**（`buyEnabled` L257 仅探测 `PositionTier.allCases` 可买性，不算当前档位）。

**契约（顺位 6 加 accessor，顺位 7 显示）**：

```
engine.currentPositionTier: Int   // 0...5，read-only computed
  令 holdingValue = position.shares × currentPrice          // 持仓市值（与顶栏「总资金=现金+持仓市值」同口径）
     total        = currentTotalCapital                      // = cashBalance + holdingValue
  total <= 0  → 0
  否则         → clamp( Int( (holdingValue / total × 5).rounded(.toNearestOrAwayFromZero) ), 0, 5 )
```

**设计理由**：
1. **基准 = 持仓市值 / 当前总资金**，与顶栏「总资金 = 现金 + 持仓市值」(plan L914) 同口径；不用成本基准（会与用户看到的实时总资金漂移）。buy action 也以「总资金 × 比例」为基准（plan L602），故「持仓占总资金的几分之一」即派生档位，语义自洽。
2. **round（四舍五入）非 floor**：100 股整手取整（plan L605「买入股数 = floor(原始股数/100)×100」）使实际买入 ≤ 目标金额，市值略低于 N/5；floor 会把买 2/5 显示成 1/5（低报）。round 反映用户意图档位。boundary 0.5/5 罕见且仅 ±1 视觉档差，无功能影响。
3. **空仓 = 0/5**（shares==0 → holdingValue==0 → 0）。本 app 不允许做空 + buy 要求现金足够（资金不足取消），故 `cashBalance ≥ 0`、`holdingValue ≥ 0`、`total ≥ holdingValue`，ratio ∈ [0,1]，clamp 仅作 FP 边界兜底。`total<=0`（全零）守为 0/5。
4. **派生非状态**：无持久化「当前 tier」字段（buy 以总资金、sell 以持仓为基准，二者无单一持久 tier）。accessor 每次从 live 状态算，与现有 `currentTotalCapital`/`returnRate` computed 一致。

**acceptance（顺位 6/7 验收）**：空仓 → 0/5；买 3/5 后立即 → 3/5（容 round）；满仓 5/5；`total<=0` → 0/5 不崩；**锁基准数值向量（opus R1-L5，防顺位 6/7 误用成本基准仍「通过」prose）**：买 4/5 → 价 ×2（持仓市值涨至 ~89% 总资金）→ 卖「持仓的 2/5」→ 期望 **3/5（非 4/5）**——钉死「市值/当前总资金基准 + round」，成本基准会得 4/5。

### 4.2 结束总资金 vs 当前总资金 显示语义（reconcile，无新契约）

**spec 现状：explicit。** 顶栏 = `currentCapital`（plan L914「总资金：本局实时总资金（现金 + 持仓市值）」= `TrainingEngine.currentTotalCapital`）；结算窗 = `total_capital`（plan L997「总资金：¥102,345.67」= 本局结束冻结值；plan L416/L885「本局结束时的总资金」——该描述性注释在 plan 非 modules，modules 同字段 `TrainingRecord.totalCapital` L497 无注释，opus R1-L1 citation 修正）。结算时已强平、无持仓，故该刻 `currentCapital == total_capital`，无矛盾。

**契约（仅 reconcile）**：
- **训练中顶栏**：显示 `engine.currentTotalCapital`（实时，含浮盈）。所有 flow（Normal/Review/Replay）一致。
- **结算窗**：显示 `total_capital`（冻结）。Normal = 持久化 `TrainingRecord.total_capital`（finalize 写库）；Review = 读历史 record 的 `total_capital`；Replay = §4.5 in-memory payload 的 `total_capital`（不持久化）。
- **E6b-R1「dispute」消解**：二者是两个不同字段用于两个 UI 场景，非冲突。本 RFC 钉死该结论，杀全仓「显示语义 dispute / 未定」残留措辞（grep gate (b)）。

**实施**：顺位 7（顶栏 + 结算接线，已有 accessor，无 engine 改动）。

### 4.3 夜间调色板 + display_mode

**spec 现状：枚举 + 解析 + 持久化 explicit；light token 变体 silent。** `DisplayMode {light, dark, system}`（modules L406 / Models.swift）；`AppColorScheme {light, dark}` + `resolveColorScheme(displayMode:traitIsDark:)`（`Theme.swift:10-19`：system→trait, light→light, dark→dark）+ `ThemeController.resolve(trait:)`（:79）已在；`AppSettings.displayMode` 已 Codable 持久化（settings key `display_mode`，plan L472）。**但现有 13 个 `AppColorRGBA` 默认 token（`Theme.swift:47-63`，background `0.10,0.10,0.12` 近黑）是单一 dark 取向集——无 light 变体，render 层不按 scheme 选取。**

**契约（顺位 9 实现）**：
1. **双 token 集**：13 token 须有 **light 与 dark 两套** `AppColorRGBA`。**现有 token 集 = dark/夜间集**（背景近黑，已是「夜间」外观）。
2. **light/白天 集 = 派生**：由对应 dark token 经白天适配——背景反相至近白、文本至近黑、语义色（candleUp 红 / candleDown 绿 / profit / loss）**保持红涨绿跌色相**、辅助线（grid/ma66/boll/macd）按白底降明度保对比。**具体 RGBA 由顺位 9 plan 依 WCAG AA 对比度在设备实测确定**（遵守 outline「不内联 RGBA」抽象纪律）。
3. **per-scheme 选取接线**：render 层读 token 时按 `themeController.resolve(trait:)` 返回的 `AppColorScheme` 选 light/dark 集（机制归顺位 9 plan：token 参数化 `token(scheme:)` 或双 static 集，二选一由 plan 定）。
4. **「跟随系统」语义**：`displayMode == .system` → `resolveColorScheme` 按 `UITraitCollection.userInterfaceStyle` 取；**trait 变化须重解析重渲染**（系统切暗/亮时跟随）。
5. **持久化**：`display_mode` ∈ {light,dark,system} 经 `AppSettings.displayMode` 落 settings 表（已有路径，无 schema 改动）。

**设计理由**：现有 dark token 已 ship（PR #39 F2），复用为 dark 集零破坏；只新增 light 集 + scheme 选取，最小面。不内联 RGBA：避免本 RFC 在颜色取值上被 codex 无止境调色，且设备实测对比度是顺位 9 运行时验收项（outline §三.3 运行时矩阵）。

**acceptance（顺位 9 验收）**：三模式切换即时生效 + 持久化跨重启；system 模式跟随系统切换重渲染；light 集 13 token 齐全且语义色保持红涨绿跌。

### 4.4 E5/E6 engine 契约扩展（全 Wave 3 engine 变更集中顺位 6，serial neck，outline R8-F1）（zoom + 画线-FSM-退出 handler 除外，见总纲注记）

**总纲**：`TrainingEngine` 跨「轨 G 图表」与「轨 T 交易」共享（drawings / panelState / trade 状态）。outline 采序列化策略：**所有 engine 契约变更集中顺位 6**，先于全部消费锚（3/4/7/8）；消费锚只用冻结 API、不改 engine 契约。本节钉死该 5 子项 API 面。
> 【neck-doctrine zoom 例外注记（user 2026-06-12 裁决；顺位 3 PR 落档）：§4.4d zoom 经裁决移顺位 3 同 PR 实施（顺位 3 新增 `ChartAction.zoomApplied` + `engine.applyPinch` + pinch 手势态）；本总纲「所有 engine 契约变更集中顺位 6 / 消费锚不改 engine 契约」对 zoom 部分 superseded，对其余 §4.1/§4.4a-c/§4.4e 仍成立。本注记适用 RFC 全文同款表述（§一(D)、§三 概览表「6 实现，3/4/7/8 消费」行、§4.4 标题）。】
> 【neck-doctrine 画线-FSM-退出 handler 家族例外注记（user 2026-06-13 裁决；顺位 4 PR 落档）：**画线激活-FSM 编排 handler 家族**（`activateDrawingTool`〔C8b #87 落〕→ 顺位 4 新增 `engine.commitDrawing`/`cancelDrawing`〔reducer `.drawing` 态**唯一**退出口，dispatch 已 ship 的 `.drawingCommitted`/`.drawingCancelled`，封装 baseRevision 细节〕）认定为 **C8b 起 / 顺位 4 收**的独立 handler 家族，与顺位-6 冻结的业务 API 面（§4.1/§4.4a-c/§4.4e）**正交**；本总纲对该家族 superseded，对其余仍成立。**事实依据**：`activateDrawingTool` 仅 C8b #87 加，6a #95 / 6b #97 均未碰它（6b 顺位-6 交付是 §4.4c `appendDrawing`）；serial-neck 防的并发-改-engine 风险已消解（3/6a/6b/10a/11 全 merged、无 open PR、顺位 4 唯一活跃）。详见 `docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md` §D-ENGINE。】

#### 4.4a 手动强平（on-demand force-close）

**spec 现状：行为 explicit（plan L922-927 底部「结束本局」→ 有持仓按最后收盘价强平 → 结算；L960-965 自动 maxTick 同语义；L751 强平定义；**modules L342「手动结束 = 用户点击结束时的值」= 手动强平按当前 tick 价、非 maxTick 末根的权威，opus R1-L4**）；on-demand API silent。** 代码：`forceCloseIfEnded()`（`TrainingEngine.swift:417`）**仅** `guard tick.globalTickIndex >= tick.maxTick` 触发——无用户主动提前结束的入口。

**契约（顺位 6）**：engine 暴露 **on-demand 强平方法**（语义等同 `forceCloseIfEnded` 体，但去掉 `>= maxTick` 门）：
- 前置：`flow.canBuySell()`（Normal ✅ / Review ❌ / Replay ✅，对齐 plan L841「结束按钮」行——Review 无主动结束）。**注（opus R1-L4）**：`canBuySell()` 此处是「结束按钮」capability 行的 **intentional load-bearing proxy**，恰与「买卖按钮」行同值；若未来某 flow 使两行分叉，顺位 6/7 须改用专门 manual-end capability 谓词，不可沿用本 proxy。
- 语义：若 `position.shares > 0` → 按 `currentPrice`（当前 tick 收盘，非 maxTick 末根；用户此刻结束即按此刻价）走 `TradeCalculator.forceCloseOnEnd` → append forced sell `TradeOperation`/`TradeMarker`（`positionTier: .tier5`，佣金+印花税）→ `position.shares == 0`、`drawdown.update`。
- **幂等**：第二次调用 shares==0 短路 no-op（与 `forceCloseIfEnded` 幂等不变量一致）。
- **复用**：auto（maxTick）与 manual 共用同一 force-close 体，仅触发门不同，杜绝两套强平逻辑漂移。

**实施**：顺位 6 加方法；顺位 7 接「结束本局」按钮（确认弹窗 → 调用 → 路由结算）。**ended UI 态 / 结算路由归顺位 7/8**，非 engine 契约。

#### 4.4b tier accessor

`engine.currentPositionTier: Int`（§4.1 公式）。read-only computed。顺位 7 顶栏显示。

#### 4.4c 画线 commit append（投影单一真相）

**spec 现状：C6（PR #69）显式 defer 投影到 Wave 3。** 代码：`engine.drawings` 是 `public private(set)`（`TrainingEngine.swift:25`，setter 文件作用域）；`deleteDrawing(at:)`（:578）已在；**resume/review 还原已支持**——`make()`/`init` 已收 `initialDrawings`（:67/:160/:222）。`DrawingToolManager.completedDrawings`（`Drawing/DrawingToolManager.swift:21`）与 `engine.drawings` **无投影路径**（manager 是本地态）。`RenderStateBuilder.swift:42` 渲染 `engine.drawings`；`TrainingSessionCoordinator` 持久化 `engine.drawings`（finalize :230 / pending）。

**契约（顺位 6）**：engine 暴露 **commit append**：
- `engine.appendDrawing(_ drawing: DrawingObject)` —— 把一条 committed 画线追加进 `engine.drawings`（更新 revision 触发重渲染 + 进入 finalize/pending 持久化路径）。
- **缺口仅此一个**：restore（`initialDrawings`）+ delete（`deleteDrawing`）已在；本子项只补 live commit 投影。顺位 4 的 `DrawingInputController` 在 `manager.commit()` 后调 `engine.appendDrawing`，使 manager.completedDrawings → engine.drawings 单一真相。
- **不变量**：`engine.drawings` 是唯一渲染 + 持久化真相；manager 仅作输入暂存；append 后 manager pending 清空（顺位 4 接线，非 engine 契约）。

#### 4.4d pinch/zoom panel-state mutation（engine-owned，非 render-only）

**spec 现状：C8a 视口硬编码 `visibleCount=80`（outline §四 residual）；pinch zoom API silent。** 代码：`PanelViewState.visibleCount` 由 `engine.upperPanel/lowerPanel` 持有（`TrainingEngine.swift:124-126`）；render 视口几何（C8a `RenderStateBuilder.makeViewport`）派生自 panelState。

**决策 D1：zoom = engine-owned panel-state mutation，非 render-layer-only。**
**理由**：crosshair 吸附（顺位 5）与画线 anchor（顺位 4）均消费「post-pinch 视口几何」（index↔x 映射）。若 zoom 只存 render 层 overlay，engine 的 panelState.visibleCount 与实际渲染缩放脱钩 → crosshair/drawing 的 candleIndex↔x 基于 engine 视口算 → 与屏幕错位。**单一真相要求 zoom 写回 engine panelState**。outline R9-F3 给的 engine-free 备选被否（会引入双视口真相）。

**契约（顺位 6）**：engine 暴露 **panel-state zoom mutation**：
- 语义：改 `panelState.visibleCount` 于 clamp `[MIN_VISIBLE, MAX_VISIBLE]` 内 + 保持 focus（pinch 中点下的 candle x 不动，重算 offset）。
> 【focus 语义裁决注记（user 2026-06-13 裁决，顺位 3 设计 R1-H1 上浮）：focus 不变量限定 freeScrolling；autoTracking = 右锚缩放（offset 恒 0，「锁定最新」优先）。理由与被否选项见 `docs/superpowers/specs/2026-06-13-wave3-pr3-pinch-zoom-design.md` D2。】
- **ephemeral 非持久**：`visibleCount` 不在 `pending_training`（核实 `ios/sql/app_schema_v1.sql` pending 现有 13 列均无 visibleCount，opus R1-M2 count 修正）→ zoom 是内存视图态，不跨 session 持久、不进 finalize。
- **clamp 边界 + pinch→count 映射数值 + 与 C7 仲裁器集成 归顺位 3 plan**（本 RFC 只钉「engine 拥有 visibleCount mutation + clamp 契约 + focus 不变量 + ephemeral」，不内联 MIN/MAX/灵敏度常量，遵守 outline 抽象纪律）。

**实施**：顺位 6 加 mutation；顺位 3 消费（去硬编码 80 + pinch 手势接线）。
> 【impl-anchor 重指派注记（user 2026-06-12 裁决，PR #97 6b plan §Scope；顺位 3 PR 落档）：§4.4d 整条（mutation + focus + 去硬编码 + pinch 手势）移顺位 3 同 PR 实施，上行「顺位 6 加 mutation / 顺位 3 消费」拆分 superseded。】

#### 4.4e replay-settlement payload 支持

**spec 现状：replay 不保存 explicit（plan L824「结束后不保存/不计入统计，使用原局 FeeSnapshot」；L841-842「结算弹窗 ✅（显示但不保存）」）；payload 来源 silent。** 代码：`coordinator.finalize` 对 Review/Replay 返 `nil`（`TrainingSessionCoordinator.swift:202` 区块，`shouldSaveRecord()==false`）→ **无 `TrainingRecord` 喂 SettlementView**；`coordinator.replay`（:150）仅继承 fees。

**契约（顺位 6）**：提供 **non-persisting replay-settlement payload**：
- replay 结束（手动 §4.4a 或 auto maxTick）强平后，由 engine/coordinator 构造 **in-memory `TrainingRecord`**（或等价 settlement payload）——用**原局 FeeSnapshot**（replay 构造时继承）+ 强平后终态（total_capital / 收益率 / 最大回撤 / trade ops）。
- **不持久化不变量**：**不**写 `training_records`、**不**触 `pending_training`、`finalize` 对 replay 仍返 nil（持久化路径不变）；payload 经**独立显示路径**提供。replay 结束后 DB 完全不变（acceptance 断言）。
- **shape（复用 `TrainingRecord` 值 vs 新 view struct）由顺位 6 plan 定**；本 RFC 钉「来源 + non-persisting 不变量 + 原局 FeeSnapshot」。

**实施**：顺位 6 产 payload；顺位 8 = UI/routing-only（消费 payload → SettlementView，无 engine 改动）。

### 4.5 Replay 结算契约（顺位 8 UI/routing-only）

**spec 现状：explicit（同 §4.4e 引用）。** 本节钉死顺位 8 的消费契约（依赖 §4.4e payload）：
- replay 结束 → §4.4a 强平 → §4.4e in-memory payload → SettlementView 呈现（显示 `total_capital`/收益率/回撤，§4.2 结算口径）→ 确认后路由回首页。
- **FeeSnapshot = 原局**（replay 构造时继承，plan L842）；**不保存 record、不计入统计、pending 不动**。
- 顺位 8 **不自改 E5/E6 契约**（payload 来自顺位 6）；仅 SettlementView 接线 + 路由。

### 4.6 中断持久化参数化（saveProgress 周期保存）

**spec 现状：周期保存契约已存在但参数 silent（modules:1676「`saveProgress` U2 退出时 / **每 N tick 自动调用**」；N + 写语义 + background flush 未定）。** 代码：`coordinator.saveProgress` 仅 Normal 持久（`TrainingSessionCoordinator.swift:176`）；**当前仅 Back 触发**（`lifecycle.back()`）——周期/后台保存未实现 = baseline 合规 gap（outline §〇）。scenePhase 链（modules L2055-2065）是纯动画（`onSceneActivated` on `.active`），**与周期保存正交、不取消该义务**。

**契约（顺位 10 实现；RFC 参数化，不决策「是否做」——spec 已定要做，「save-on-Back only」不可接受，outline R5-F1）**：

1. **触发 = state-dirtying mutation，非仅 tick 推进**（**校正 spec 字面「每 N tick」**）：autosave 须在**任何脏状态动作**后触发——tick 推进（holdOrObserve）**＋ 交易（buy/sell，改 position/cash 但不推 tick）＋ 画线 commit/delete**。**理由**：buy 3/5 后未推 tick 即被杀 → 若只按 tick 周期保存则丢该笔交易。「每 N tick」是 spec 给的 cadence 下限，非穷举触发面；RFC 补全交易/画线触发，闭合 inter-tick 丢失洞。
2. **N（cadence floor）参数化**：`AUTOSAVE_TICK_INTERVAL = N`（命名契约常量）。**默认 N=1**（每脏即存，coalesced）；顺位 10 可在实测写延迟超帧预算时上调至 `N ≤ AUTOSAVE_MAX_INTERVAL`（有界，建议 ≤5），**不变量：未落盘进度丢失 ≤ N tick 等价的脏窗**。具体 N/MAX 数值由顺位 10 plan 依实测定。
3. **coalescing / serialization 写语义**：单写者串行——一次 in-flight `saveProgress`；写中又脏 → 置 dirty flag、写完再存一次（**latest-wins，不排队堆积**），防慢盘下 autosave 雪崩。
4. **background/inactive flush**：scenePhase → `.inactive`/`.background` → **立即 flush**（绕过 N，因 OS 可能杀进程）。**additive** 到现有 `.active → onSceneActivated` 动画链（modules L2055-2065），不替换它。
5. **失败可见**：autosave 失败须可见（非阻塞指示），**不 teardown session**；与 finalize 失败（§4.7a）区分处置。
6. **与终态 fence 关系**：autosave 须在 finalize/discard 前被 drain/拒绝（§4.7d），防终态脏写复活 pending。

**acceptance（顺位 10 验收）**：买入后未推 tick 即杀/relaunch → resume 含该笔交易；推 N tick 触发落盘；切后台立即 flush；慢盘下无 autosave 堆积；autosave 失败留局内不拆毁。

### 4.7 finalize 原子性 + 失败保留 + 单事务 port + 幂等 + schema 迁移 + 终态 fence + discard + provenance 恢复

**最重契约。** 现状证据（核实 2026-06-10）：
- `coordinator.finalize`（`TrainingSessionCoordinator.swift:230-231`）：`recordRepo.insertRecord(...)` 与 `pendingRepo.clearPending()` 是**分离两次 `dbQueue.write`**（`RecordRepositoryImpl` 内部单事务插 record+ops+drawings，但 clearPending 是独立事务）→ insert 成功 + clear 失败 → 重启再 finalize = **重复 record**。
- `TrainingView.swift:118-119`：finalize 任何失败 → `onSessionEnded(nil)` → AppRouter 关 reader + 清 `activeTraining` = **已完成局直接拆毁丢失**（pending stale/absent，retry 不可达）。
- `endSession()`（:236-242）：仅关 reader + 清 active context，**不清 `pending_training`** → 周期 autosave 后 discard 会留旧 checkpoint 被首页/重启复活。
- `pending_training` 是 singleton `CHECK (id = 1)`（`ios/sql/app_schema_v1.sql:50`）**无 session 身份列**；`training_records` `AUTOINCREMENT id` **无唯一约束** → 无幂等去重锚。
- app DB schema 经 GRDB `DatabaseMigrator`（`AppDBMigrations.swift` `0001_v1.4_baseline` / `0003_v1.4_purge_leased` + `PRAGMA user_version`）演进；`PersistenceReason` 有 `.dbCorrupted`/`.schemaMismatch`/`.diskFull`/`.ioError`。
- **provenance 未分流**：training-set DB 与 app.sqlite 损坏**均**映射 `.persistence(.dbCorrupted)`（`PersistenceErrorMapping`，含 `DecodingError`）——调用点 source 已知但错误类型不可区分。

**契约（顺位 10a 持久化基础早置 / 10b 集成晚置）**：

**(a) finalize 失败保留 session**：finalize 失败 → **保留 active session**（reader/activeTraining 不 teardown）+ 提供 retry/discard；**禁** `onSessionEnded(nil)` 拆毁路径。成功（含 retry 成功）才 teardown。

**(b) 单事务 session-finalization port**：治理**新 port**（如 `SessionFinalizationPort.finalize(record, ops, drawings) throws -> Int64`），把 `insertRecord` + `clearPending` 收进**单一 `DefaultAppDB` 事务**（原子：要么 record 入库且 pending 清，要么都不）。注入 coordinator，**禁 unsafe concrete downcast**（port 抽象，`DefaultAppDB` 提供事务实现）。**实施归顺位 10a**。

**(c) 幂等 + durable session key + P4 schema 迁移**：retry 仅记一次 record。
- **durable session key**：session 启动生成稳定 key，落 `pending_training`，finalize 时随 record 入库。
- **schema 迁移（additive，新 named migration）**：`pending_training` 加 session-key 列 + `training_records` 加 session-key 列 + 该列**唯一约束**（retry 同 key → `ON CONFLICT` no-op 返已存 id，幂等）。**existing-row 迁移语义**：升级时既有 pending/records 回填 key（或允许 legacy NULL）；**fresh-install/upgrade/crash-after-commit/retry 四态测试**使幂等 finalize 真不重复。
- **版本处置 MANDATORY**：迁移须随 model 改动**原子 ship**——加 named migration（如 `0004_*`）+ 相应 `user_version`/`CONTRACT_VERSION`（现 "1.5"）bump（沿用 E2 RFC MANDATORY-bump 门）。**目标版本号 + 列名/DDL 由顺位 10a plan 定**（outline「不内联 DDL」纪律）；RFC 钉「需迁移 + 唯一约束 + 四态语义 + bump MANDATORY」。**实施归顺位 10a。**

**(d) 终态 fence**：finalize/discard 前 **drain/cancel 排队 autosave** + finalization 启动后**拒绝新 autosave**。防终态 tick 的 autosave 在 finalize 后重建 `pending_training` → 重启重复 finalize / 重复 record。**测试**：save-before/after-finalize 双序 + 无 pending resurrection + 无 duplicate。**实施归顺位 10b。**

**(e) discard 持久终态**：discard（如 back-save 失败后用户选弃）= **fence autosaves → 清 `pending_training` → endSession → exit**（durable 终态，不复活）。清 pending 失败 → 保留 active session 供 retry（不 teardown）。**测试**：discard-with-existing-autosave + relaunch 无复活。**实施归顺位 10b。**

**(f) provenance-aware 恢复（按 source 分流，非按 error 类型；outline R11-F3）**：
- **training-set DB 损坏**（可弃，重下）：调用点已知是训练组只读 DB → 自动删 + 重新下载（DownloadAcceptanceRunner 路径）。
- **app.sqlite 损坏**（含 history/pending/settings 不可逆）：**fail-closed 非破坏恢复，禁自动删**——surface 给用户（settings 走 §P6 `forceResetAndReload(confirmation:)` 两层恢复；history/pending 无自动抹）。
- **分流锚 = source（哪个 DB），非 `.dbCorrupted` error 类型**（二者现同类型，调用点 source 已知）。**RFC 钉死该 source-based 分流原则 + app.sqlite 禁自动删的安全红线**；具体探测/恢复实现 + 故障注入测试归顺位 10b。**理由**：防顺位 10 据「都报 dbCorrupted」误对 app.sqlite 做训练组式 auto-delete → 抹掉用户不可逆 history/settings。

**总实施归属**：10a（早置，6 后 / 7·8 前）= (b) 单事务 port + (a) 失败保留 + (c) schema 迁移；10b（晚置，4·7·8 后）= (d) fence + (e) discard + (f) provenance + 跨 feature 故障注入。

---

## 五、grep gate 精确化（acceptance 项，fail-closed）

谓词全部**锚定具体短语 + 排除合法残留 + fail-closed**，防 codex 拿裸措辞无限挑战（per `feedback_acceptance_grep_anchoring` + `feedback_codex_distributed_reliability_drilldown`）。封装为 `scripts/governance/verify-wave3-pr1-rfc.sh`，acceptance 调它。

- **(a) 七契约权威锚在 modules/plan 在位**：modules 含 `currentPositionTier`（§4.1 accessor 名）+ `appendDrawing`（§4.4c）+ pinch/zoom panel-state mutation（§4.4d，opus 整体 review R1-L1 补机器锚）+ on-demand 强平契约 marker + `AUTOSAVE_TICK_INTERVAL`（§4.6）+ 单事务 finalization port marker + durable session key marker；plan 含 tier 派生公式 marker + 夜间 light/dark 双集 marker。pass = 全锚命中（code fence/精确短语，非裸名）。
- **(b) §4.2 结算显示 reconcile 文本在位（正向断言，取代易 vacuous 的负向搜索；opus R1-M1）**：opus R1 实测「未定/拒臆造/显示语义 dispute」措辞**本不在 modules/plan**（残留在 Wave 3 outline〔由 (c) supersede marker 守护〕+ `docs/governance/2026-06-09-wave2-completion.md`〔point-in-time 完成记录，§二不改写〕），故对 modules/plan 做负向搜索近乎空洞、恒 PASS。改**正向断言**：`kline_trainer_plan_v1.5.md` §6.2 顶栏/结算区须含 §4.2 钉死的两字段 reconcile 锚——顶栏「本局实时总资金 = 现金 + 持仓市值」（= `currentTotalCapital`）/ 结算「`total_capital`（本局结束冻结值）」并存且互不混用。pass = plan 命中该 reconcile 锚 ≥1（证 §4.2 已落地，非空搜）。
- **(c) Wave 3 outline supersede marker 位置在位**：marker `本节契约已由顺位 1 RFC 钉死` 须位于 outline `### 3.1` heading 之后、首个 stale 措辞之前（断言 heading 行 < marker 行 < 首个 stale 行）；防 planner 先读旧「未定」字面。
- **(d) provenance 安全红线在位**：modules §E6 含「app.sqlite 损坏禁自动删 / fail-closed」契约短语（§4.7f 安全红线，防顺位 10 误删）。pass = 命中 ≥1。
- **(e) replay non-persisting 不变量在位**：modules §E6 含「replay … 不写 training_records / 不触 pending_training」短语（§4.4e/§4.5）。pass = 命中 ≥1。
- **(f) scope allowlist fail-closed**：`git merge-base origin/main HEAD` 算 base → diff 改动文件须全在显式 allowlist（RFC spec + plan + acceptance + verify 脚本 + modules + plan_v1.5 + wave3-outline，共 7 文件）；任何 `ios/`/`.swift`/`.py`/`.sql`/`.yml`/`.xcodeproj`/冻结 doc → 硬 FAIL。
- **(g) 冻结历史 immutability**：断言 diff 无 `docs/superpowers/(plans|specs)/2026-05-*` 冻结 point-in-time 文档被动（按 `2026-05-` 路径前缀精确锚；**不**用 `*plan*.md` 黑名单——会误伤本 on-branch RFC plan doc `docs/superpowers/plans/2026-06-10-*`，opus plan R1-H1）。全 allowlist 由 (f) fail-closed 兜底。

**fail-closed 实现要求（沿用 Wave 2 顺位 1 RFC §五 + `verify-wave2-pr1-rfc.sh` 实证经验）**：(1) 源路径用**数组**（zsh 不 word-split 标量）；(2) 跑前 `-r` 断言每源可读，否则 `exit 2`；(3) grep helper 区分 rc 0/1/**>1（读错/坏正则 → exit 2）**，不用 `|| true` 吞错；(4) 过滤用纯 bash `case`，不用 `grep|grep -v` 链；(5) 负向断言用 `if grep ...; then exit 1`，**不用 `set -e` 下 `! grep` 死闸门**（per `feedback_acceptance_grep_anchoring`）；(6) 启动探针自检 line-filter 机制，坏则 exit 2；(7) 须实测：未编辑 repo → GATE FAIL exit 1；源不可读 → exit 2。

---

## 六、明确 OUT of scope

- **不写任何业务代码 / schema / CI**（0 `.swift`/`.py`/`.sql`/`.yml`/`.xcodeproj`）；全部实施归下游锚 3/4/6/7/8/9/10。
- **不执行 `CONTRACT_VERSION`/schema bump**（本 RFC docs-only；bump 随顺位 10a 迁移落地，本 RFC 仅钉「bump MANDATORY」门）。
- **不内联** 具体 RGBA 值（§4.3 顺位 9）、clamp/灵敏度常量（§4.4d 顺位 3）、N/MAX 数值（§4.6 顺位 10）、列名/DDL/目标版本号（§4.7c 顺位 10a）——遵守 outline 抽象纪律。
- **不改写冻结历史 plan/spec**（§二）。
- **不打 tag**（freeze tag 决策延至顺位 13，outline §三.3）。
- 锁竖屏 / app-target CI（顺位 2）、Toast+haptic（顺位 7，已 spec'd plan L735/955/841 无需 RFC 契约）、6 种完整画线工具（Phase 4 排除）—— 均不在本 RFC。

---

## 七、停止规则（永久偏见护栏）+ review 策略

**停止规则（沿用 E2 RFC §七 + `feedback_codex_round6_self_contradiction`）**：本 RFC 自身过 opus 4.8 xhigh 对抗评审到收敛。
- **§4.x 契约一旦写入即权威答案。** 判「permanent-bias 复述」须同时满足两条：①该 finding 要求的补救 = 已被显式否决的同一补救（如要求 zoom 改 render-free 已 §4.4d D1 否决；要求结算显示语义重定义已 §4.2 explicit）；②未引入任何 §4.x 尚未处理的新事实/新路径/新错误。
- **「指出某条已论证断言事实上是错的」永远不算复述**（如证明 §4.1 公式在某真实状态下崩、§4.7 迁移漏某升级态）。
- 命中两条 → 走 user TTY override + admin merge，不实施。

**review 策略（Task 0）**：
- 本 RFC 主走 **opus 4.8 xhigh 对抗评审**（user 2026-06-10 explicit：spec 出来后另一 opus 4.8 xhigh 对抗 review 到收敛）。plan-stage + branch-diff 双闸门各自到收敛。
- codex `codex:adversarial-review` 仍是治理 required channel；本 PR docs-only 不触 Catalyst（无 iOS 代码）；codex 周配额耗尽则 opus xhigh fallback（per `feedback_subagent_quota_fallback_must_ask`）。
- 超 5 轮或 permanent-bias → escalate user + attestation residual + admin merge（**不绕 required checks**；per `feedback_codex_plan_budget_overshoot` + `feedback_big_pr_codex_noncovergence`）。

---

## 八、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-10 | v1 | 起草；落 Wave 3 outline §三.1 八项为七契约权威定义 + 设计理由块；grep-first 校正（多数项 spec 已 explicit，RFC 多为 reconcile + 引用）；D1 zoom = engine-owned panel-state；§4.6 触发面校正（state-dirtying 非仅 tick）；§4.7 最重契约（单事务 port + 幂等 schema 迁移 + fence + discard + provenance 安全红线）；grep gate 七谓词 fail-closed |
| 2026-06-10 | v1.1 | opus 4.8 xhigh 对抗评审 R1 = **VERDICT: APPROVE**（0 Critical / 0 High；2 Medium + 4 Low，全为 premise-precision/gate-correctness，非设计缺陷）。应用 6 修正：§五(b) 易-vacuous 负搜 → 正向 reconcile 断言（R1-M1）；§4.4d pending 列数 12→13（R1-M2）；§4.2 citation modules→plan L416/L885（R1-L1）；§4.7 `CHECK(id=1)` 行 49→50（R1-L2）；§4.1 `buyEnabled` L259→L257（R1-L2）；§4.4a 加 modules L342 手动结束按当前价权威 + canBuySell() proxy load-bearing 注（R1-L4）；§4.1 acceptance 加市值基准数值锁向量 4/5→×2→卖2/5→3/5（R1-L5）。**plan L997 经实测裁决保留**（R1 误称 L996，grep 证 L997）。契约面零改动 |
| 2026-06-10 | v1.2 | plan-stage opus 4.8 xhigh 对抗评审 R1 反馈回灌 spec §五 2 处：(g) 冻结红线由 `*plan*.md` 黑名单（误伤 on-branch RFC plan doc）改 `2026-05-` 前缀精确锚（plan R1-H1）；(b) 措辞对齐 plan anchor `本局结束冻结值` + `本局实时总资金 = 现金 + 持仓市值`（plan R1-L2 drift）。契约面零改动；plan 自身 1C+3H+1M+2L 修正见 plan 文档 |
| 2026-06-10 | v1.3 | 整体 branch-diff opus 4.8 xhigh 对抗评审 R1 = **VERDICT: APPROVE**（0C/0H/0M；独立复跑 gate ALL PASS + 3 tamper fail-closed + 全 premise 核对 correct + RFC↔anchor faithfulness 全 7 契约 + fence 完整 + scope 守纪）。应用唯一 Low：§4.4d zoom 补机器锚 `pinch/zoom panel-state mutation` 进谓词 (a)（原仅 spec+acceptance visual 覆盖，今全 7 契约机器 gated）；gate 复跑 ALL PASS。subagent-driven 实施完成（7 文件 / 821 ins / 0 业务代码）|
