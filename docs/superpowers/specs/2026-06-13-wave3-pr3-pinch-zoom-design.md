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
6. **RFC/outline 注记**（D9，user 裁决的 impl-anchor 重指派 6→3 落档）。

### Out（显式排除）
- **W3-11-R1 bounce live 接线**：fast-follow 独立 PR（D8，理由见下）。
- `candleWidthRatio = 0.7` 改动：保持 0.7 不动（outline residual 原文虽并列提及，RFC §4.4d 只治理 visibleCount；ratio 无任何 spec/用户需求要求可变，YAGNI）。去硬编码仅指**分母与可见根数**改读 panelState。
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
| `.autoTracking` | `visibleCount = v`；**offset 不动（恒 0）**；`revision &+= 1`；`.none` | D2 右锚缩放 |
| `.freeScrolling` | `visibleCount = v`；`offset = o`；`revision &+= 1`；`.none` | focus 不变量 |
| `.drawing` | **吞没**（状态零改动，`.none`） | 视口已定格（plan L225 Drawing 行「已定格」），同 `offsetApplied` 吞没先例 |

**不切换 interactionMode**：plan L223 字面「Auto-Tracking：Pan = 切到 Free，Pinch = 缩放」——pinch 不引发 mode 转换（状态转换表 L228-231 中 pinch 不出现）。

### D2：autoTracking = 右锚缩放（offset 恒 0），focus 不变量只在 freeScrolling 生效

**决策**：autoTracking 下 pinch 只改 visibleCount，offset 保持 0——视口仍「锁定最新 K 线」（当前 candle 钉最右绘制 slot），缩放以**最新 candle 为锚**。freeScrolling 下执行 RFC focus 不变量（pinch 中点下 candle x 不动，重算 offset）。

**与 RFC §4.4d「保持 focus」字面的关系**：RFC 把「C7 仲裁集成 + clamp/灵敏度数值」显式归顺位 3 plan，mode 交互语义未内联；plan v1.5 L223 mode 表是更具体的在位权威——autoTracking 的视图控制权属「系统（锁定最新）」，若 pinch 重算出非零 offset，将与 D8 既有纪律（autoTracking 下 offset 归零，`TrainingEngine.swift resetOffsetAfterAutoTracking`）和「锁定最新」语义直接冲突，且下一 tick 到来时焦点 candle 本就会移动（autoTracking 时间在走），「focus 不动」在该 mode 物理上不可维持。
**备选：pinch 在 autoTracking 下切 freeScrolling 再保 focus**：**否**——状态转换表 L228-231 只允许 Pan/绘线激活离开 autoTracking；pinch 切 mode 会让训练中的缩放动作意外停跟踪，违 spec 字面。
**数学一致性**：focus 公式在「focusX = 右缘、offset = 0」时解出 offset′ = 0（见 D3 校验），即右锚缩放 = focus 不变量在右缘焦点的特例——两 mode 行为在右缘连续，无断裂。

### D3：focus 数学 = 纯函数，以实际渲染视口为 before 快照

**连续坐标模型**：`u(x) = startIndex + (x − pixelShift) / candleStep`（candle 连续索引，与 `indexToX` 互逆，不含 mainFrame.minX——`ChartPanelFrames.split` 的 mainChart x 起点为 0）。

**不变量**：pinch 中点 `fx` 下连续索引缩放前后相等：`u′(fx) = u(fx)`。

**before 快照取实际渲染视口**（`makeViewport` 输出的 `startIndex/pixelShift/candleStep`，含 clamp 与边缘饱和**之后**的值），而非由存量 offset 反推的理想连续值。理由：边缘饱和态（startIndex 落位 0/upperBound、pixelShift 被强制 0）下，存量 offset 与屏上所见脱钩；用户看到什么就锚什么，否则边缘 pinch 起手即跳。

**解 offset′**（after 端用连续模型，N′ = 新 visibleCount，W = mainChart 宽，cIdx = currentIdx 同 makeViewport 谓词）：
```
u_before = startIndex_rendered + (fx − pixelShift_rendered) / (W/N)
u′(fx)   = cIdx − (N′−1) + (fx − offset′) / (W/N′)
u′(fx) = u_before  ⇒  offset′ = fx − (u_before − cIdx + N′ − 1) · W / N′
```
**校验向量（手算锚点）**：`fx = W`、offset = 0、非饱和（startIndex = cIdx−N+1，pixelShift = 0）：u_before = (cIdx−N+1) + W/(W/N) = cIdx+1；offset′ = W − (cIdx+1 − cIdx + N′−1)·W/N′ = W − N′·W/N′ = **0** —— 右缘焦点缩放不产生平移（与 D2 右锚行为连续）。
**post-zoom 仍可能被 makeViewport 饱和**：offset′ 不在纯函数内做二次 clamp，沿用 pan 先例（offset 无界存储、渲染端饱和）；饱和时 focus 不变量让位于边界钉死（acceptance 显式写明此优先级）。

**落点**：新纯函数文件 `Render/PinchZoomModel.swift`（enum + static func，平台无关，host 全测）：
- `targetVisibleCount(base: Int, scale: CGFloat) -> Int`（clamp + 非有限/≤0 scale 防御 → 返回 base）
- `rezoomOffset(viewport: ChartViewport, currentIdx: Int, focusX: CGFloat, newCount: Int, mainWidth: CGFloat) -> CGFloat`

### D4：clamp 与灵敏度常量

- `MIN_VISIBLE = 20`，`MAX_VISIBLE = 240`，默认 80 居中偏左。依据：mainChart 宽约 700-744pt（iPad mini 7 竖屏）：N=240 → candleStep≈3pt（candleWidth≈2pt，密集但可辨）；N=20 → step≈37pt（粗看单根形态）；240 = 3×默认，20 = 默认/4，覆盖「看形态 ↔ 看趋势」全程。数值是**本 plan 自由度**（RFC 显式授权顺位 3 定），实测手感差经 runbook 回填调整。
- **映射**：`target = clamp(round(base / scale), MIN, MAX)`。scale 取识别器 per-gesture 累积值（>1 张开 → 根数变少 → 放大），base = 手势 `.began` 时刻的 visibleCount。**灵敏度 = 恒等映射**（无指数/系数）：物理直觉「手指张开 2 倍 ≈ candle 宽 2 倍」；不引入可调参数（YAGNI，runbook 实测不适再调）。
- 常量落 `PinchZoomModel`；`RenderStateBuilder.defaultVisibleCount = 80` 保留作 seed/fallback 单一来源。

### D5：makeViewport 去硬编码（向后兼容）

```
let target = panelState.visibleCount > 0 ? panelState.visibleCount : defaultVisibleCount
let visibleCount = min(target, count)
let candleStep = mainFrame.width / CGFloat(target)        // 分母 = target（原：恒 80）
```
- `target ≤ 0` fallback 80：兼容全部既有测试/调用方（现网 PanelViewState 大量以 `visibleCount: 0` 构造）；**engine `make()`/init 同步改 seed 80**（`RenderStateBuilder.defaultVisibleCount`），新代码不再依赖 fallback。
- 分母 = target（非 count-clamped visibleCount）：保留「数据不足 80 根时左对齐填充、candle 宽度稳定」既有行为（target=80 时与现行为**逐位一致**——回归安全声明，测试矩阵含 parity 用例）。
- 边缘饱和（pixelShift 置 0）逻辑零改动（W3-11-R1 bounce 接线将来才碰它，D8）。

### D6：engine 编排 `applyPinch(scale:focusX:phase:panel:)`

```
.began  → animator(for: panel).stop()           // 同 beginPan 先例：手势起手截住惯性
          pinchBase[panel] = 有效 visibleCount（0 → 80）
.changed→ guard base（nil 则自愈：以当前值补 seed——防御 twoFingerStep 之外的调用序）
          target = PinchZoomModel.targetVisibleCount(base, scale)
          mode 分派：autoTracking → reduce(.zoomApplied(target, 0)) [offset 参数被 reducer 忽略]
                     freeScrolling → 用 makeViewport(当前状态) 取 before 快照 →
                                     offset′ = PinchZoomModel.rezoomOffset(...) →
                                     reduce(.zoomApplied(target, offset′))
                     drawing → reduce 吞没（engine 不预判，统一进 reducer）
.ended/.cancelled → pinchBase[panel] = nil       // 无结算动作；最后一次 .changed 即终态
```
- bounds 来源：`lastRenderedBounds`（C8b D1 既有机制）；bounds 为 zero（未渲染过）→ no-op 防御。
- scale 非有限/≤0：`targetVisibleCount` 返回 base（值不变，但**仍会派发 action**？——否：target == 当前 visibleCount 时 engine 直接跳过派发，避免无意义 revision bump；见测试矩阵）。
- per-panel：`pinchBase` 按 panel 分槽；两面板可同时处于不同 zoom（pan 先例一致）。
- **接线**（`ChartContainerView.Coordinator.attach`）：`arbiter.onPinch = { engine.applyPinch(scale:$0, focusX:$1.x, phase:$2, panel:panel) }`（weak-self 模式同 onPan）。

### D7：ephemeral 不持久（RFC 钉死）

`visibleCount` 不入 `pending_training`（13 列无此字段）、不进 finalize、不跨 session（resume 重建 engine → seed 80）。**零 schema/`CONTRACT_VERSION`/`saveProgress`/`finalize` 改动**——acceptance 以 diff 范围 gate 守护（同 6b 先例：改动文件集 allowlist + `finalize` 方法体零改动断言）。

### D8：W3-11-R1 不折入，fast-follow 独立 PR

理由：①本 PR 已横跨 engine 契约 + reducer + render 几何 + 手势接线四个面，再叠 bounce live 接线（overscroll 渲染要改 makeViewport 边缘饱和规则、stop() caller-intent 拆分、cancelPan 语义、全几何 bounds 失效）会破 outline「~250-350 行」估算且混入独立风险面；②outline/bounce-plan 原文 sanction「折入顺位 3 **/ 3 后 fast-follow**」两路径；③顺位 3 先 merge 后 bounce 接线串行进行，避免两 PR 同改 makeViewport 冲突。residual 保持 OPEN，归属注记「3 后 fast-follow」。

### D9：RFC/outline 注记（user 裁决落档，6b plan L23 指派本 PR 完成）

1. `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.4d「实施」行后加注记：【user 2026-06-12 裁决（PR #97 6b plan §Scope）：§4.4d 整条（mutation + focus + 去硬编码 + pinch 手势）移顺位 3 同 PR 实施，原「顺位 6 加 mutation / 顺位 3 消费」拆分 superseded】。
2. `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §二 表后加同款 callout（顺位 3 行「消费 6 的 zoom/panel-state API」+ §二 R8-F1 段「engine 契约变更集中顺位 6」的 zoom 部分 superseded；**neck 目的不破**：仅顺位 3〔轨 G〕改 panelState.visibleCount/zoom 契约，轨 T 不碰，无并发冲突——6b plan 已论证）。
3. modules `kline_trainer_modules_v1.4.md:1743` 锚文字与本设计一致（「clamp/灵敏度数值 + C7 仲裁集成归顺位 3 plan」），**零改动**。

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
| RFC/outline 两 doc | D9 注记 |

---

## 四、测试策略（概要；矩阵细化归 plan）

1. **PinchZoomModel 纯函数**（host）：clamp 双端、round 单调、scale 非有限/≤0/0 附近防御、focus 公式手算向量（右缘 offset′=0 / 中点放大缩小双向 / offset≠0 起点 / N′=N 恒等 offset′=offset）、**端到端不变量**：构造 candles + makeViewport 前后断言 `u(fx)` 偏差 < 1e-9（连续域）且 fx 下 candle 索引不变（`xToIndex` 离散域，非饱和态）——按 [[feedback]] 先例须 mutation-verify（故意给错公式确认测试能杀）。
2. **Reducer**：3 mode × zoomApplied（应用/应用/吞没）、revision bump 规则（吞没不 bump）、drawing 快照零改动。
3. **makeViewport**：target 读取 + 0-fallback、分母变化、count<target 左对齐、80-parity 回归（同输入新旧输出逐字段相等）、边缘饱和不变。
4. **Engine**（host，fake FrameDriving 先例）：began 停 animator、base 捕获（含 0→80）、changed 派发与 mode 分派、target 不变跳过派发（revision 不 bump）、ended/cancelled 清 base、changed 自愈、bounds zero no-op、per-panel 隔离、autoTracking offset 恒 0、freeScrolling focus 端到端保持。
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

---

## 评审记录

| 日期 | 轮次 | 结果 |
|---|---|---|
| | | |
