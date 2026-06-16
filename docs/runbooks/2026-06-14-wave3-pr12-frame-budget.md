# 帧预算验收 Runbook — Wave 3 顺位 12（os_signpost 帧相关测量）

**日期**：2026-06-14（原）／**2026-06-16（13c-R1 重写：Time Profiler 峰值相加 → os_signpost 最坏完整帧归并）**
**性质**：device / simulator 手动执行；CLI/CI 仅编译 UIKit 不运行，帧预算测量无法自动化
**执行者**：user（非编码者可执行；Xcode + Instruments 即可，无需读懂 Swift 代码）
**覆盖范围**：Wave 3 新交互（pinch 缩放 / 绘线 / 十字光标 HUD）帧预算，补充既有 c8b runbook item #3

---

## 权威判据

**单帧 `RenderStateBuilder.make` + `KLineView.draw(_:)` 合并 < 4ms @ 120Hz**

出处：modules v1.4 **L1471**（「验收：Instruments 120Hz 单帧 <4ms；Equatable 短路生效」）/ plan v1.5 L1264。

> **行号勘误**：既有 c8b runbook item #3 引用「spec L1467」为陈旧行号，权威 = modules v1.4 **L1471**。c8b item #3 原文保留（历史完整性）。

---

## 测量方法（13c-R1：os_signpost 帧相关，替换「峰值相加」）

**为何不再用 Time Profiler 峰值相加（13c-R1 / codex R8-H1）**：Time Profiler 是采样器；分别过滤 `make` / `draw` 取峰值相加 ≠ 同一显示帧的真实合并耗时——屏上有**上/下两个图表实例**各自 make/draw，`make`（`updateUIView`）调度 `draw` 延后，一帧含最多 4 个未配对调用。峰值相加是**指示性上界**（可能高估或漏算），非严谨单帧合并。

**13c-R1 instrumentation（已 ship 2026-06-16）**：生产代码在渲染热路径加 `os_signpost` 区间（subsystem `com.klinetrainer.render`），按 panel × op 命名：

| 区间名 | 含义 |
|---|---|
| `make-upper` / `make-lower` | 上/下面板 update-pass 的 `RenderStateBuilder.make` 求值 |
| `draw-upper` / `draw-lower` | 上/下面板 `KLineView.draw(_:)` 全过程 |
| `make-crosshair-upper` / `make-crosshair-lower` | 上/下面板长按十字光标旁路 make（与 update-pass make 分离） |

区间携带精确 begin/end 时间戳（非采样），可在 Instruments 时间轴按 display frame 归并。

---

## 前置准备

1. 真机（推荐 A17 Pro / ProMotion 屏）或 Retina iPhone Simulator 构建 **Release（优化）包**（⌘I Profile 默认 Release；**勿用 Debug**——未优化虚高单帧耗时）。
2. Xcode → Product → Profile（⌘I）→ 选 **os_signpost**（Points of Interest）instrument；**并加 Core Animation / Animation Hitches** 以得 display frame 边界轴。
3. 录制前在 os_signpost detail 按 subsystem `com.klinetrainer.render` 过滤，确认上述 6 个具名 lane 可见。
4. 每场景独立录制 30 秒。

---

## 最坏完整帧判读法（每场景共用）

1. 在 Core Animation / Hitches 轨找该场景**最慢的一帧**（最长 commit / 有 hitch）。
2. 取该帧的 vsync 窗口（相邻两次 display 刷新之间）。
3. 在 os_signpost 轨读出落入该窗口的全部 `make-*` + `draw-*` 区间，**求和** = 该帧真实合并耗时：
   - 滚动 / 缩放 / 绘线场景：贡献者 = `make-upper`+`make-lower`+`draw-upper`+`draw-lower`。
   - 十字光标场景：update-pass make 通常不触发，贡献者 = 被拖动面板的 `make-crosshair-*` + `draw-*`。
4. 跨该场景所有帧取**最大合并值**作判据。

---

## 帧预算验收表

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | os_signpost 录制 **纯水平滚动 + 惯性减速**；按「最坏完整帧判读法」取最坏帧合并 | 最坏帧 make-upper+make-lower+draw-upper+draw-lower 合并 < 4ms | 合并 < 4ms = 通过 |
| 2 | os_signpost 录制 **pinch 缩放**（双指开合 3-5 次）；同上取最坏帧 | 最坏帧合并 < 4ms | 合并 < 4ms = 通过 |
| 3 | os_signpost 录制 **水平线绘制 + 跨缩放/平移还原**（顶栏「水平线」→ 单指点击落锚 → 确认横线可见 → pinch+pan）；同上取最坏帧 | 最坏帧合并 < 4ms **且横线渲染可见** | 合并 < 4ms 且线可见 = 通过 |
| 4 | os_signpost 录制 **长按十字光标拖动**（缓慢横扫）；贡献者取 make-crosshair-* + draw-* | 最坏帧合并 < 4ms | 合并 < 4ms = 通过 |
| 5 | **Equatable 短路验证**：保持 engine 状态不变连续 updateUIView；观察 os_signpost 轨 | 无新 `draw-*` 区间（短路使 setNeedsDisplay 不触发）；frame timeline 稳定 | 无冗余 draw 区间 = 通过 |

---

## 回填信息

| 项目 | 回填值 |
|---|---|
| Device 型号 | **____** |
| iOS / iPadOS 版本 | **____** |
| 所测周期 + 该帧实际渲染蜡烛数（≥80 视为满载，见 runtime-matrix R8-H2） | **____** |
| 场景1 最坏帧 make-upper/make-lower/draw-upper/draw-lower / 合并 ms | **__**/**__**/**__**/**__** / **__** |
| 场景2 最坏帧 各贡献者 / 合并 ms | **____** / **__** |
| 场景3 最坏帧 各贡献者 / 合并 ms | **____** / **__** |
| 场景4 最坏帧 make-crosshair-*/draw-* / 合并 ms | **____** / **__** |
| 场景5 Equatable 短路 | 通过 / 未通过 |
| 实测日期 | **____** |

> **实测数值是 user device 职责 + 顺位 13 收尾阻塞依赖（runtime-matrix ③）。**

---

## Bitmap Cache 决议门

**全部场景最坏帧合并 ms < 4ms** → Phase 1 纯 draw 充分；Bitmap Cache **no-op**（outline L173）；本子项已关闭。
**任一场景最坏帧合并 ms ≥ 4ms** → 触发 `docs/governance/2026-06-14-wave3-pr12-performance-review.md` §四 决议门，引入 Bitmap Cache（独立后续 anchor），引入后须重测全场景回落 < 4ms 才可关闭。

---

## 13c-R1 残留状态

- **机制 facet（os_signpost 帧相关测量）**：本 runbook + 生产 instrumentation 已交付（2026-06-16）。
- **device facet（最坏帧 <4ms 实测）**：仍 **OPEN**（本表回填 = runtime-matrix ③ 的 device 职责）。
