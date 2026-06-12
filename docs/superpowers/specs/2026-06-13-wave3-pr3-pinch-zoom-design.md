# Wave 3 顺位 3：Pinch 缩放（§4.4d engine-owned zoom + 去硬编码 80 + onPinch 接线）设计文档

**日期**：2026-06-13
**锚**：Wave 3 outline §二 顺位 3（`docs/superpowers/specs/2026-06-09-wave3-outline-design.md`）
**权威契约**：RFC §4.4d（`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` L140-152）+ modules `kline_trainer_modules_v1.4.md:1743`（机器锚 `pinch/zoom panel-state mutation`）+ plan v1.5 L223（mode×手势表）/ L1037（捏合焦点为中心）
**scope 重指派依据**：user 2026-06-12 裁决（PR #97 6b plan `docs/superpowers/plans/2026-06-12-wave3-pr6b-engine-drawing-replay.md` L17-23）——**§4.4d zoom 整条（mutation + focus + 去硬编码 80 + pinch 手势）移入顺位 3**，不再按 RFC 原文「顺位 6 加 mutation / 顺位 3 消费」拆分。

---

## 〇、背景与现状（核实于 worktree `worktree-wave3-pr3-pinch-zoom`，base = main `ddc96ea`）

1. **`RenderStateBuilder.makeViewport` 硬编码**（`RenderStateBuilder.swift:14-15/63/66`）：`defaultVisibleCount = 80` 同时充当「可见根数上限」与「candleStep 分母」；`candleWidthRatio = 0.7`。**完全忽略 `panelState.visibleCount`**（engine init 恒为 0，`TrainingEngine.swift:124-126`）。
2. **C7 仲裁已完备**（PR #61）：`ChartGestureArbiter.onPinch((scale, focus, phase))` 已存在；`twoFingerStep` 状态机已做 pinch vs 两指切周期确定性仲裁（`GestureClassifiers.swift:217-273`：`classifyTwoFingerGesture` 阈值 `|scale-1|>0.02` 锁定 intent；锁定后保证相位序 `.began → .changed* → .ended/.cancelled`，终止以 `lastPinchScale` 结算）。**本锚的「C7 仲裁集成」= 接线 `onPinch` 回调，不是新建仲裁。**
3. **`ChartContainerView.Coordinator.attach`**（`ChartContainerView.swift:90`）显式注记「onPinch（缩放改 visibleCount）属 Wave 3」——本锚闭合此口。
4. **reducer 纪律**：`PanelViewState.revision` 为 `private(set)`，只由 reducer 递增（spec L962）；offset 只经 reducer（spec L1153，`offsetApplied`）。pan 路径先例：engine 方法（`beginPan/applyPanOffset/endPan/cancelPan`）→ `reduce(action, on: panel)`。
5. **CoordinateMapper x 映射**（`Geometry.swift`）：`indexToX(i) = (i - startIndex)·candleStep + pixelShift`（再像素取整）。`makeViewport` 在 `startIndex` 落位 0 或 upperBound 时强制 `pixelShift = 0`（边缘饱和）。
6. **per-panel 独立**：上下两面板各自持 `ChartContainerView`（各自 Coordinator + arbiter + KLineView）；pan 已是 per-panel（`beginPan(panel:)`）。
7. **engine bounds 缓存**：`recordRenderBounds(_:panel:)` 每次 `updateUIView` 刷新，`activateDrawingTool` 已用此机制算 range（C8b D1 先例）。
8. **W3-11-R1**（PR #96 bounce residual）：live 可见接线 + stop() caller-intent + cancelPan + 全几何 bounds 失效 + bounce device/sim runbook，「折入顺位 3 **或** 3 后 fast-follow」（两种处置均被 sanction）。
9. baseline：`swift test` 864 tests / 123 suites 全绿（本 worktree 实测 2026-06-13）。

---

## 一、Scope

### In
1. **§4.4d engine-owned zoom mutation**：`panelState.visibleCount` 经 reducer 突变，clamp `[MIN_VISIBLE, MAX_VISIBLE]`，focus 不变量（freeScrolling），ephemeral 不持久。
2. **makeViewport 去硬编码**：`visibleCount`/candleStep 分母改读 `panelState.visibleCount`（0 → fallback 80 兼容既有构造）；engine init 改 seed 80。
3. **onPinch 接线**：`ChartContainerView.Coordinator` → `engine.applyPinch(...)`。
4. **clamp + 灵敏度常量**（D4）+ 纯函数 focus 数学（D3，host 全测）。
5. **运行时 runbook 条目**（pinch 聚焦 / clamp / autoTracking 右锚 / 与切周期仲裁手感）。
6. **RFC / outline / modules / plan 四 doc 注记与 amendment**（D9：impl-anchor 重指派 6→3 落档 + focus 语义裁决 A 落档）。

### Out（显式排除）
- **W3-11-R1 bounce live 接线**：fast-follow 独立 PR（D8，理由见下）。
- `candleWidthRatio = 0.7` 改动：保持 0.7 不动。**这是对 outline 残差 `:194`（「C8a 视口硬编码 visibleCount=80 / candleWidthRatio=0.7 → 顺位 3」）的显式 partial-closure（R1-M2），非静默收窄**：ratio 已是命名常量（`RenderStateBuilder.swift:15`），无任何 spec/输入驱动其可变（RFC §4.4d 只治理 visibleCount），「去硬编码」对它 vacuous。acceptance 残差注记写明「visibleCount 部分闭合；ratio 部分以『已是常量、无可变驱动』close」，供评审确认。
- 两指切周期行为、长按十字光标、画线（顺位 4/5 已落或另锚）。
- visibleCount 持久化（RFC 钉死 ephemeral）；`saveProgress`/`finalize`/schema 零改动。

---

## 二、设计决策

### D1：mutation 经 reducer（新 `ChartAction.zoomApplied`），engine 方法编排

**决策**：新增 reducer action `case zoomApplied(visibleCount: Int, offset: CGFloat)`；engine 新增唯一公共入口 `applyPinch(scale:focusX:phase:panel:)` 负责编排（停 animator、捕获 base、调纯函数算目标、派发 action）。

**备选 (a) engine 直改 `panelState.visibleCount`**（字段是 `public var`，技术可行）：**否**。revision 不 bump → 渲染依赖 `@Observable` 结构突变虽可触发，但破坏「视图状态变更只经 reducer + revision 单调」既有纪律（spec L962/L1153 + PR #47 revision 单调性测试基建），且 drawing 模式吞没逻辑会散落 engine。
**备选 (b) 把 focus 数学塞进 reducer**：**否**。reducer 是平台无关纯状态机，不应依赖视口几何（bounds/candles/tick）；遵循 `offsetApplied(deltaPixels:)` 先例——几何在外算好，reducer 只收最终值。

**reducer 语义（mode 矩阵）**：

| 当前 mode | `.zoomApplied(v, o)` | 理由 |
|---|---|---|
| `.autoTracking` | `visibleCount = v`；**offset 显式置 0（非 leave-unchanged，R1-L5/M3 防御）**；`revision &+= 1`；`.none` | D2 右锚缩放 |
| `.freeScrolling` | `visibleCount = v`；`offset = o`；`revision &+= 1`；`.none` | focus 不变量 |
| `.drawing` | **吞没**（状态零改动，`.none`） | 视口已定格（plan L225 Drawing 行「已定格」），同 `offsetApplied` 吞没先例 |

**不切换 interactionMode**：plan L223 字面「Auto-Tracking：Pan = 切到 Free，Pinch = 缩放」——pinch 不引发 mode 转换（状态转换表 L229-233 中 pinch 不出现（R4-L1 精确化：全三行 Auto-Tracking/Free-Scrolling/Drawing 的触发列均无 pinch））。

### D2：autoTracking = 右锚缩放（offset 显式置 0），focus 不变量只在 freeScrolling 生效【user 2026-06-13 裁决 A】

**spec 自相矛盾（R1-H1 上浮，已裁决）**：三处权威文字无条件要求 focus-preserve——RFC §4.4d L148「保持 focus（pinch 中点下的 candle x 不动，重算 offset）」、plan v1.5 **L1037「两指捏合/张开 | K 线缩放（以捏合焦点为中心）」**、modules:1743 机器锚「+ 保持 focus（pinch 中点 candle x 不动，重算 offset）」。但 plan L223「Auto-Tracking | 谁控制视图 = 系统（**锁定最新 K 线**）」与之在 autoTracking 下**物理不可同时满足**：保持焦点必须产生非零 offset，即不再锁定最新（`makeViewport` mode-agnostic，offset≠0 即偏移视口；且 `resetOffsetAfterAutoTracking` 纪律要求 autoTracking 下 offset==0）。

**裁决（user 2026-06-13，对抗评审 R1-H1 上浮后二选一）= 选项 A：右锚缩放**：
- autoTracking 下 pinch 只改 visibleCount，**offset 显式置 0**——视口仍锁定最新（当前 candle 钉最右绘制 slot），缩放以**最新 candle 为锚**，训练时间继续走、mode 不切换（状态转换表 L229-233 字面：pinch 不在任何转换触发列）。
- freeScrolling 下执行完整 focus 不变量（pinch 中点下 candle x 不动，重算 offset）。
- **被否选项 B（pinch 切 freeScrolling 后保焦点）**：副作用过重——freeScrolling「谁控制时间 = 已定格」（plan L224），缩放动作会暂停训练时间流，且转换表只有交易/切周期能强制回 autoTracking，缩放一下即被永久踢出跟踪模式。
- **落档义务（R1-H2 + R2-H1）**：本裁决收窄**四处**权威文字的 focus 语义（无条件 → freeScrolling-only + autoTracking 右锚），须以 amendment 注记落 modules:1743、RFC §4.4d、**plan v1.5 L1037（§七 触控交互表）与 L1180（§Phase 9）**（见 D9），**不是**「零改动」。plan 是受治理权威源（RFC §二表明列 `kline_trainer_plan_v1.5.md` ✅ amend），且其 pinch focus 行无任何 gate 谓词守护——漏改即留 live 矛盾给顺位 4/5 planner。

**数学一致性**：focus 公式在「focusX = 右缘、offset = 0」时解出 offset′ = 0（见 D3 校验），即右锚缩放 = focus 不变量在右缘焦点的特例——两 mode 行为在右缘连续，无断裂。

**forward-note（R1-M3，跨锚依赖标记给顺位 4）**：reducer `drawingCommitted/drawingCancelled`（`Reducer.swift:187-199`）把 mode 切回 autoTracking 但**不归零 offset**，且 engine 侧接线延后顺位 4。顺位 3 范围内「autoTracking ⇒ offset==0」不变量成立（drawing 在顺位 3 **不可达**——入口 onTap/DrawingInputController 未接线，`ChartContainerView.swift:90` 显式注记，`activateDrawingTool` 生产侧无手势 caller，R2-L2 校正措辞）；**顺位 4 接线 drawing commit/cancel 时必须同步 `resetOffsetAfterAutoTracking`**（与 trade/periodSwitch 对齐），否则从 freeScrolling 激活 drawing 再 commit 会得到 autoTracking + offset≠0，破坏本锚右锚前提。reducer autoTracking `.zoomApplied` 分支显式置 0（D1 矩阵）作第二道防御。

### D3：focus 数学 = 纯函数，以实际渲染视口为 before 快照

**连续坐标模型**：`u(x) = startIndex + (x − pixelShift) / candleStep`（candle 连续索引，与 `indexToX` 互逆，不含 mainFrame.minX——`ChartPanelFrames.split` 的 mainChart x 起点为 0）。

**不变量**：pinch 中点 `fx` 下连续索引缩放前后相等：`u′(fx) = u(fx)`。

**before 快照取实际渲染视口**（`makeViewport` 输出的 `startIndex/pixelShift/candleStep`，含 clamp 与边缘饱和**之后**的值），而非由存量 offset 反推的理想连续值。理由：边缘饱和态（startIndex 落位 0/upperBound、pixelShift 被强制 0）下，存量 offset 与屏上所见脱钩；用户看到什么就锚什么，否则边缘 pinch 起手即跳。

**解 offset′**（after 端用连续模型，N′ = 新 visibleCount，W = mainChart 宽，cIdx = currentIdx）：
```
u_before = startIndex_rendered + (fx − pixelShift_rendered) / step_before
u′(fx)   = cIdx − (N′−1) + (fx − offset′) / (W/N′)
u′(fx) = u_before  ⇒  offset′ = fx − (u_before − cIdx + N′ − 1) · W / N′
```
- **step_before 必须取 `viewport.geometry.candleStep`（实际渲染值），不得手算 `W/visibleCount`**（R1-L2）：D5 后分母 = target，早期数据 `count < target` 时 `visibleCount(=count) ≠ target`，`W/visibleCount` 是错值。
- **cIdx 单一来源（R1-M1）**：`ChartViewport` 不暴露 currentIdx，而 offset′ 公式需要它。从 `makeViewport` 抽出共享纯谓词 `RenderStateBuilder.currentCandleIndex(candles:tick:) -> Int`（`partitioningIndex { $0.endGlobalIndex >= tick }` + `min(rawIdx, count-1)`，含「聚合面板在自身 period 序列定位」注释义务），makeViewport 与 engine `applyPinch` 路径都经它——禁止两处重复实现该谓词（漂移即 focus 算错）。不选「把 currentIdx 加进 ChartViewport」：那要改 public init 签名，churn 大于抽谓词。
**校验向量（手算锚点）**：`fx = W`、offset = 0、非饱和（startIndex = cIdx−N+1，pixelShift = 0）：u_before = (cIdx−N+1) + W/(W/N) = cIdx+1；offset′ = W − (cIdx+1 − cIdx + N′−1)·W/N′ = W − N′·W/N′ = **0** —— 右缘焦点缩放不产生平移（与 D2 右锚行为连续）。
**post-zoom 仍可能被 makeViewport 饱和**：offset′ 不在纯函数内做二次 clamp，沿用 pan 先例（offset 无界存储、渲染端饱和）；饱和时 focus 不变量让位于边界钉死（acceptance 显式写明此优先级）。

**落点**：新纯函数文件 `Render/PinchZoomModel.swift`（enum + static func，平台无关，host 全测）：
- `targetVisibleCount(base: Int, scale: CGFloat) -> Int`（clamp + round；**前置条件 = scale 有限且 >0，由 engine 守卫**）。**非有限/≤0 scale 防御上移 engine（R2-L1）**：engine `.changed` 分支先 `guard scale.isFinite, scale > 0`（含 scaleAtBegan）否则直接 return——真无操作（不派发、状态零改动）。不得让模型「返回 base」：gesture 中途当前 visibleCount 可能已 ≠ base，返回 base 会 snap-to-base 而非保持。
- `rezoomOffset(viewport: ChartViewport, currentIdx: Int, focusX: CGFloat, newCount: Int, mainWidth: CGFloat) -> CGFloat`

### D4：clamp 与灵敏度常量

- `MIN_VISIBLE = 20`，`MAX_VISIBLE = 240`，默认 80 居中偏左。依据：mainChart 宽约 700-744pt（iPad mini 7 竖屏）：N=240 → candleStep≈3pt（candleWidth≈2pt，密集但可辨）；N=20 → step≈37pt（粗看单根形态）；240 = 3×默认，20 = 默认/4，覆盖「看形态 ↔ 看趋势」全程。数值是**本 plan 自由度**（RFC 显式授权顺位 3 定），实测手感差经 runbook 回填调整。
- **映射**：`target = clamp(round(base / effectiveScale), MIN, MAX)`，`effectiveScale = scale / scaleAtBegan`（**锁定点归一，R1-L1**）：`.began` emission 发生在 `classifyTwoFingerGesture` 越过 ±0.02 阈值的锁定点，此刻识别器累积 scale 已偏离 1.0 约 2%；若直接用累积 scale，首个 `.changed` 会一次性吃掉锁定前 ~2%（base=80 时 ≈2 根台阶）。归一后 effectiveScale 从 ≈1.0 起步，无死区跳变。base 与 scaleAtBegan 均在 `.began` 时刻捕获（pinchBase 存二元组）。
- scale >1 张开 → 根数变少 → 放大。**灵敏度 = 恒等映射**（无指数/系数）：物理直觉「手指张开 2 倍 ≈ candle 宽 2 倍」；不引入可调参数（YAGNI，runbook 实测不适再调）。
- 常量落 `PinchZoomModel`；`RenderStateBuilder.defaultVisibleCount = 80` 保留作 seed/fallback 单一来源。

### D5：makeViewport 去硬编码（向后兼容）

```
let target = panelState.visibleCount > 0 ? panelState.visibleCount : defaultVisibleCount
let visibleCount = min(target, count)
let candleStep = mainFrame.width / CGFloat(target)        // 分母 = target（原：恒 80）
```
- `target ≤ 0` fallback 80：兼容全部既有测试/调用方（既有测试经 helper 以 `visibleCount: 0` 构造，R1 已核实）；**engine `make()`/init 同步改 seed 80**（`RenderStateBuilder.defaultVisibleCount`）。seed 与 fallback 与 pinchBase 0→80 自愈三重冗余是**有意的 defense-in-depth**（R1-L7）：seed 让「活跃值」显式可读（debug/测试可见真值而非魔法 0），fallback 保旧构造兼容，自愈保调用序防御——三者代价各一行。
- 分母 = target（非 count-clamped visibleCount）：保留「数据不足 80 根时左对齐填充、candle 宽度稳定」既有行为（target=80 时与现行为**逐位一致**）。**parity 测试防 tautology（R1-L3）**：期望值必须硬编码独立金值（`candleStep == W/80`、`visibleCount == min(80, count)` 等手算字面量），不得由新公式推导；并补 `visibleCount: 80` 显式入参用例（既有测试仅覆盖 0-fallback 路径）。
- 边缘饱和（pixelShift 置 0）逻辑零改动（W3-11-R1 bounce 接线将来才碰它，D8）。

### D6：engine 编排 `applyPinch(scale:focusX:phase:panel:)`

```
.began  → animator(for: panel).stop()           // 同 beginPan 先例：手势起手截住惯性
          pinchBase[panel] = (有效 visibleCount（0 → 80）, scaleAtBegan)   // R1-L1 归一锚
.changed→ guard base（nil 则自愈：以当前值 + 当前 scale 补 seed——防御 twoFingerStep 之外的调用序）
          target = PinchZoomModel.targetVisibleCount(base, scale / scaleAtBegan)
          mode 分派：autoTracking → reduce(.zoomApplied(target, 0)) [reducer 该分支显式置 offset=0，入参不被读取]
                     freeScrolling → 用 makeViewport(当前状态) 取 before 快照 →
                                     offset′ = PinchZoomModel.rezoomOffset(...) →
                                     reduce(.zoomApplied(target, offset′))
                     drawing → reduce 吞没（engine 不预判，统一进 reducer）
.ended/.cancelled → pinchBase[panel] = nil       // 无结算动作；最后一次 .changed 即终态
```
- bounds 来源：`lastRenderedBounds`（C8b D1 既有机制）；bounds 为 zero（未渲染过）→ no-op 防御。
- **坐标系前提（R1-L6）**：`indexToX` 不含 minX、`g.location(in: view)` 为 view-local，二者一致当且仅当 `bounds.origin == .zero`（UIView bounds 实务恒成立）。plan 在 focus 路径加一行注记 + debug 断言（`assert(bounds.origin == .zero)`），防将来引入 inset 时静默错位。
- scale 非有限/≤0（含 scaleAtBegan 非法）：engine `.changed` 分支前置 guard 直接 return——不派发、状态零改动（R2-L1：防御在 engine，不在模型；模型「返回 base」会 snap-to-base）。另一独立短路：target == 当前 visibleCount → 跳过派发（N 不变则焦点本就不动，offset 无需重算；非饱和时公式亦给 offset′=offset），避免无意义 revision bump（见测试矩阵）。
- per-panel：`pinchBase` 按 panel 分槽；两面板可同时处于不同 zoom（pan 先例一致）。
- **接线**（`ChartContainerView.Coordinator.attach`）：`arbiter.onPinch = { engine.applyPinch(scale:$0, focusX:$1.x, phase:$2, panel:panel) }`（weak-self 模式同 onPan）。

### D7：ephemeral 不持久（RFC 钉死）

`visibleCount` 不入 `pending_training`（13 列无此字段）、不进 finalize、不跨 session（resume 重建 engine → seed 80）。**零 schema/`CONTRACT_VERSION`/`saveProgress`/`finalize` 改动**——acceptance 以 diff 范围 gate 守护（同 6b 先例：改动文件集 allowlist + `finalize` 方法体零改动断言）。

### D8：W3-11-R1 不折入，fast-follow 独立 PR

理由：①本 PR 已横跨 engine 契约 + reducer + render 几何 + 手势接线四个面，再叠 bounce live 接线（overscroll 渲染要改 makeViewport 边缘饱和规则、stop() caller-intent 拆分、cancelPan 语义、全几何 bounds 失效）会破 outline「~250-350 行」估算且混入独立风险面；②outline/bounce-plan 原文 sanction「折入顺位 3 **/ 3 后 fast-follow**」两路径；③顺位 3 先 merge 后 bounce 接线串行进行，避免两 PR 同改 makeViewport 冲突。residual 保持 OPEN，归属注记「3 后 fast-follow」。

### D9：RFC/outline/modules 注记（两项 user 裁决落档；6b plan L23 指派 + R1-H2 修正）

1. `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` 加三条注记：
   (a) §4.4d「实施」行后：【user 2026-06-12 裁决（PR #97 6b plan §Scope）：§4.4d 整条（mutation + focus + 去硬编码 + pinch 手势）移顺位 3 同 PR 实施，原「顺位 6 加 mutation / 顺位 3 消费」拆分 superseded】；
   (b) §4.4d「保持 focus」契约行后：【user 2026-06-13 裁决（顺位 3 设计 R1-H1 上浮）：focus 不变量限定 freeScrolling；autoTracking = 右锚缩放（offset 恒 0，锁定最新优先），理由与被否选项见顺位 3 设计文档 D2】；
   (c) **§4.4 总纲（L113）后加 canonical neck caveat（R4-H1）**：【§4.4d zoom 经 user 2026-06-12 裁决移顺位 3 同 PR 实施；本总纲「所有 engine 契约变更集中顺位 6 / 消费锚不改 engine 契约」对 zoom 部分 superseded（顺位 3 新增 `ChartAction.zoomApplied` + `engine.applyPinch` + pinch 手势态），对其余 §4.1/§4.4a-c/§4.4e 仍成立；本 caveat 适用 RFC 全文同款表述（§一(D) L18、概览表 L49「6 实现，3/4/7/8 消费」、§4.4 标题 L111）】——L18/L49/L111 各加「（zoom 除外，见 §4.4 总纲注记）」短标。
2. `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §二 表后加 **document-scoped supersession callout（R4-M1）**：顺位 3 行「消费 6 的 zoom/panel-state API」+ 全文所有「engine 契约集中顺位 6 / 不改 engine 契约 / serial neck」表述的 zoom 部分 superseded——**枚举命中（2026-06-13 sweep 实证）**：§二 表 row 6（L61）、§三 DAG（L81「6 engine neck」/ L90「engine 写集中 6」）、§二 R8-F1 段（L107）、W1 波次（L111）、关键路径（L124）；版本历史 v10 行（L246）属历史 log 不 amend（历史保真）。callout 写明对全文生效 + 枚举行号，不逐行插注。**neck 目的不破**：仅顺位 3〔轨 G〕改 panelState.visibleCount/zoom 契约，轨 T 不碰，无并发冲突——6b plan 已论证。
3. **modules `kline_trainer_modules_v1.4.md:1743` amendment（R1-H2 修正，原「零改动」声明为事实误判）**：机器锚原文「保持 focus（pinch 中点 candle x 不动，重算 offset）」是无条件的，与裁决 A 相左，须 amendment 为 freeScrolling-only + autoTracking 右锚（user 2026-06-13 裁决注记）。**约束**：amendment 必须完整保留顺位 1 fail-closed gate 的机器锚短语 `pinch/zoom panel-state mutation`（gate 谓词 `grep -cF` 锁该短语，acceptance 2026-06-10-wave3-pr1 #2b）。**gate 复跑范围（R2-M1 校正）**：只复跑**内容锚谓词 (a)/(d)/(e)**（验证 amendment 后机器锚与红线仍命中）；(f) scope-allowlist / (g) immutability 谓词是顺位 1 RFC PR 专属（allowlist 仅 7 个 doc/脚本文件），本实施分支合法改 Swift 文件必致其 FAIL，**不纳入**本核验、不得以「全谓词 PASS」为门。
4. **plan `kline_trainer_plan_v1.5.md` amendment（R2-H1）**：L1037（§七 触控交互表「两指捏合/张开 | K 线缩放（以捏合焦点为中心）」）与 L1180（§Phase 9「UIPinchGestureRecognizer → 缩放（以焦点为中心）」）两处无条件 focus 文字加 mode 限定注记（focus 限 freeScrolling；autoTracking = 右锚，引用 user 2026-06-13 裁决 + 顺位 3 设计 D2），与 modules:1743 amendment 同款措辞。
5. **modules `kline_trainer_modules_v1.4.md:1738` E5 头部 neck 声明 amendment（R3-H1）**：头部原文「顺位 6 序列化实现，serial neck，所有 Wave 3 engine 契约变更集中此锚，消费锚 3/4/7/8 不改 engine 契约」在 zoom 移顺位 3 后两句为假（zoom 契约变更落顺位 3；顺位 3 改 engine 契约）。加同款 superseded 注记：zoom 部分（§4.4d）经 user 2026-06-12 裁决移顺位 3 同 PR 实施；neck 对其余 trade/tier/drawing/replay 契约（§4.1/§4.4a-c/§4.4e）仍成立。1738 头部无 gate 谓词依赖（机器锚在 1743 bullet），amend 不碰 gate。

**neck-doctrine 全量 sweep（R4-H1 修正——原「modules/plan 仅此一处」是把 RFC/outline 排除在扫描面外的虚假完备声明）**：2026-06-13 对**全部四份 amendment-target 权威文件**跑 `grep -nE "集中此锚|集中顺位 6|集中 6|不改 engine 契约|serial neck|engine 写集中|所有 Wave 3 engine"` + 评审员独立 sweep 交叉验证，完整命中清单 = **RFC 4 处**（L18 §一(D) / L49 概览表 / L111 §4.4 标题 / L113 §4.4 总纲 → D9.1(c)）+ **outline 6 处**（L61 / L81 / L90 / L107 / L111 / L124 → D9.2；L246 版本历史 log 不 amend）+ **modules 1 处**（:1738 → 本条）+ **plan 0 处**（plan 仅 focus 类命中 L1037/L1180 → D9.4）。D9.1-D9.5 合计覆盖全部命中，无遗漏。

### D10：既有行为零回归声明

- target=80 时 makeViewport 输出与现行为逐位一致（D5 parity 测试）。
- pan/deceleration/drawing/切周期/十字光标路径零改动（onPinch 是纯新增回调接线）。
- `ChartGestureArbiter`/`GestureClassifiers` 零改动（仲裁已完备）。
- 既有 864 tests 全绿维持。

---

## 三、组件与数据流

```
UIPinchGestureRecognizer + 两指Pan ──(C7 twoFingerStep 既有仲裁)──▶ arbiter.onPinch(scale, focus, phase)
  ──▶ Coordinator（接线，本 PR）──▶ engine.applyPinch(scale, focusX, phase, panel)   [本 PR 新增]
        ├─ .began: animator.stop() + pinchBase 捕获
        ├─ .changed: PinchZoomModel.targetVisibleCount ──┐
        │            （freeScrolling）makeViewport before 快照 → PinchZoomModel.rezoomOffset
        │                                                └──▶ reduce(.zoomApplied(v, o))  [reducer 新 case]
        └─ .ended/.cancelled: pinchBase 清空
RenderStateBuilder.makeViewport（去硬编码，本 PR）──▶ 视口几何反映新 visibleCount → @Observable 重渲染
```

新增/改动文件（估 ~150 prod 行 + 测试）：
| 文件 | 改动 |
|---|---|
| `Render/PinchZoomModel.swift` | 新增：常量 + targetVisibleCount + rezoomOffset 纯函数 |
| `Reducer/Reducer.swift` | `ChartAction.zoomApplied` case + 3 mode 分支 |
| `TrainingEngine/TrainingEngine.swift` | `applyPinch` + `pinchBase` 状态 + init seed 80 |
| `Render/RenderStateBuilder.swift` | makeViewport 去硬编码（D5） |
| `Render/ChartContainerView.swift` | onPinch 接线（1 闭包） |
| RFC / outline / modules / plan 四 doc | D9 注记 + amendment：RFC §4.4d 两行 + §4.4 总纲/L18/L49/L111 neck caveat、outline document-scoped callout（6 处枚举）、modules:1743「保持 focus」+ :1738 neck 头部、plan L1037/L1180（gate 机器锚短语保留 + 复跑内容谓词 (a)/(d)/(e)） |

---

## 四、测试策略（概要；矩阵细化归 plan）

1. **PinchZoomModel 纯函数**（host）：clamp 双端、round 单调、0 附近小正 scale 的 clamp 行为（非有限/≤0 防御已上移 engine，模型层不测 precondition 违反，R3-L1）、focus 公式手算向量（右缘 offset′=0 / 中点放大缩小双向 / offset≠0 起点 / N′=N 恒等 offset′=offset——**恒等向量必须用非饱和视口构造**：饱和态公式重导出 canonical offset′≠存量 offset 属预期，R2-L3）、**端到端不变量**：构造 candles + makeViewport 前后断言 `u(fx)` 偏差 < 1e-9（连续域主锚）且 fx 下 candle 索引不变（`xToIndex` 离散域副锚；**fx 必须取某 candle 中心、远离边界**——边界处前后 ±1 漂移假阴、中心恒等才有判别力，R1-L4）——按本仓 FP demonstrator 教训须 mutation-verify（故意给错公式确认测试能杀）。
2. **Reducer**：3 mode × zoomApplied（应用/应用/吞没）、revision bump 规则（吞没不 bump）、drawing 快照零改动。
3. **makeViewport**：target 读取 + 0-fallback、分母变化、count<target 左对齐、80-parity 回归（同输入新旧输出逐字段相等）、边缘饱和不变。
4. **Engine**（host，fake FrameDriving 先例）：began 停 animator、base 捕获（含 0→80）、changed 派发与 mode 分派、target 不变跳过派发（revision 不 bump）、**非有限/≤0 scale 或 scaleAtBegan 非法 → guard return 真无操作（不派发、状态零改动，R2-L1/R3-L1）**、ended/cancelled 清 base、changed 自愈、bounds zero no-op、per-panel 隔离、autoTracking offset 恒 0、freeScrolling focus 端到端保持。
5. **Catalyst**：`ChartContainerView` 接线编译 + build-for-testing CI（app target required check 顺位 2 已设）。
6. **运行时 runbook**（acceptance 条目，user device 执行）：pinch 放大/缩小聚焦正确、clamp 到界手感、autoTracking 右锚、pinch vs 两指切周期不串扰、双面板独立缩放。

---

## 五、风险与开放项

| 风险 | 处置 |
|---|---|
| 灵敏度/clamp 数值手感不适 | 常量集中 `PinchZoomModel`，runbook 实测回填调整（一行改） |
| 边缘饱和态 focus 不严格成立 | 设计显式声明优先级（饱和 > focus），acceptance 写明，不算缺陷 |
| 并行 PR 改 `ChartContainerView`（顺位 4 画线若在飞） | 本 PR 仅加 1 闭包接线，冲突面最小；merge 序由先合者 rebase |
| twoFingerStep 终止相位 emission 携 `lastPinchScale` 触发末次 changed 之后的 ended | `.ended` 仅清 base，无值依赖，安全 |
| W3-11-R1 推迟 | D8 显式 residual 注记，fast-follow 锚 |
| **顺位 4 接 drawingCommitted/Cancelled 不归零 offset → autoTracking+offset≠0 破右锚前提（R1-M3）** | D2 forward-note 显式标记给顺位 4；reducer autoTracking `.zoomApplied` 显式置 0 作第二道防御；acceptance 残差注记 |
| modules amendment 碰 fail-closed gate | D9.3 约束：保留机器锚短语 `pinch/zoom panel-state mutation` + 改后复跑**内容谓词 (a)/(d)/(e)**；(f)/(g) 实施分支必 FAIL 不纳入（R3-M1 对齐 D9.3） |

---

## 评审记录

| 日期 | 轮次 | 结果 |
|---|---|---|
| 2026-06-13 | opus 4.8 xhigh 对抗评审 R1 | **NEEDS-ATTENTION**（0C / 2H / 3M / 7L）。R1-H1 autoTracking 右锚静默推翻三处无条件 focus-preserve → **上浮 user 裁决 = 选项 A 右锚**（D2 落档）；R1-H2 「modules:1743 零改动」事实误判 → D9.3 改 amendment 义务（gate 短语保留约束）；R1-M1 cIdx 谓词抽共享 `currentCandleIndex`；R1-M2 candleWidthRatio 显式 partial-closure；R1-M3 顺位 4 forward-note + reducer 显式置 0；R1-L1 scaleAtBegan 归一消死区；R1-L2 step_before 取 viewport 实际值；R1-L3 parity 独立金值 + visibleCount:80 显式用例；R1-L4 fx 取 candle 中心；R1-L5 显式置 0；R1-L6 bounds.origin 断言；R1-L7 三重冗余写明 defense-in-depth 理由。核心数学 D3 评审独立重推验算无误。 |
| 2026-06-13 | opus 4.8 xhigh 对抗评审 R2 | **NEEDS-ATTENTION**（0C / 1H / 1M / 3L）。R1 全 12 条修复核验「无敷衍式修复」，D2 裁决落档忠实、D3/D4 数学（含 scaleAtBegan 归一对称性）独立重推无误。R2-H1 裁决 A 漏改 plan v1.5 L1037/L1180 两处无条件 focus 文字（R1-H2 同缺陷类复发；plan 是 RFC §二表明列的受治理权威源）→ D9.4 新增 plan amendment；R2-M1 「复跑顺位 1 gate 全谓词」在实施分支不可行（(f) scope-allowlist 必 FAIL）→ 收窄为内容谓词 (a)/(d)/(e)；R2-L1 非有限 scale 守卫上移 engine（模型返回 base 会 snap-to-base）；R2-L2 forward-note 前提改「drawing 顺位 3 不可达」；R2-L3 N′=N 恒等向量须非饱和视口。 |
| 2026-06-13 | opus 4.8 xhigh 对抗评审 R3 | **NEEDS-ATTENTION**（0C / 1H / 1M / 1L）。R2 全 5 条修复核验真实完整；D3 通解与 currentCandleIndex 谓词、C7 锁定点恒发 `.began`（scaleAtBegan 捕获前提）、reducer 穷尽 switch 均独立实证。R3-H1 modules:1738 E5 头部 neck 声明（「engine 契约变更集中顺位 6 / 消费锚 3 不改 engine 契约」）未纳入 amendment——同缺陷类第三次复发 → D9.5 新增（sweep 实证仅此一处）；R3-M1 风险表 stale「全谓词」→ 对齐 D9.3 内容谓词；R3-L1 测试策略非有限 scale 用例从模型层移 engine 层 guard no-op 条目。 |
| 2026-06-13 | opus 4.8 xhigh 对抗评审 R4 | **NEEDS-ATTENTION**（0C / 1H / 1M / 1L）。R3 三条修复落点核验真实完整；D5 与 makeViewport 签名契合、focus 类 amendment 四处全覆盖（无第五处）独立实证。R4-H1 RFC 自身 neck 总纲四处（L18/L49/L111/L113）未 amend 且 D9.5 sweep 把 RFC 排除在扫描面外构成虚假完备——同缺陷类第四次复发、落在最权威源 → D9.1(c) canonical caveat + 短标，D9.5 sweep 修正为四文件全量枚举（RFC 4 + outline 6 + modules 1 + plan 0）；R4-M1 outline callout 改 document-scoped + 枚举 L61/L81/L90/L107/L111/L124（L246 历史 log 不改）；R4-L1 状态转换表行号 L228-231 → L229-233。 |
