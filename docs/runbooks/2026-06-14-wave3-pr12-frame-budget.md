# 帧预算验收 Runbook — Wave 3 顺位 12（Wave 3 新交互覆盖）

**日期**：2026-06-14
**性质**：device / simulator 手动执行；CLI/CI 仅编译 UIKit 不运行，帧预算测量无法自动化
**执行者**：user（非编码者可执行；Xcode + Instruments 即可，无需读懂 Swift 代码）
**覆盖范围**：Wave 3 新交互（pinch 缩放 / 绘线 / 十字光标 HUD）帧预算，补充既有 c8b runbook item #3

---

## 权威判据

**单帧 `buildRenderState(make) + KLineView.draw(_:)` < 4ms @ 120Hz**

出处：
- modules v1.4 **L1471**：「验收：Instruments 120Hz 单帧 <4ms；Equatable 短路生效」
- plan v1.5 L1264：「渲染性能｜Instruments 验证 120Hz 无卡顿，Phase 1 纯 draw 单帧 <4ms」

> **行号勘误**：既有 `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` item #3 引用「spec L1467」为陈旧行号（modules L1467 实为代码块行），权威帧预算验收 = modules v1.4 **L1471**。本 runbook 引用 L1471，不沿袭 L1467。c8b runbook item #3 保持原文不改（历史完整性）；本 runbook 为顺位 12 自有、覆盖 Wave 3 新交互的帧预算条目。

---

## 前置准备

1. 在真机（推荐 A17 Pro / ProMotion 屏）或 Retina iPhone Simulator 上构建 **Release（优化）包**（Xcode ⌘I Profile 默认 Release；**勿用 Debug**——未优化构建会虚高单帧耗时，可能误触 Bitmap Cache 引入）
2. Xcode → Product → Profile（⌘I）→ 选 **Time Profiler** 模板（或 **Core Animation** 模板）
3. 每场景独立录制 30 秒，取帧渲染耗时峰值（非平均值）

---

## 帧预算验收表

> **权威判据（codex review R5-High 修正）**：单帧 pass = **`RenderStateBuilder.make` + `KLineView.draw(_:)` 合并峰值 < 4ms**（顺位 12 perf review L14 / modules v1.4 L1471）。`make` 在 `ChartContainerView.updateUIView` 中**单独**跑、`draw(_:)` 在绘制周期跑——**仅测 `draw(_:)` 漏掉 `make`**：两个各 < 4ms 的相却可能合并 > 4ms 而假 PASS。故下表各场景须在 Time Profiler 中**同时过滤 `RenderStateBuilder.make` 与 `KLineView.draw(_:)` 两符号，取同帧合并耗时（或两峰值保守相加）作判据**，二者合并 < 4ms 方为通过。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | Instruments Time Profiler / Core Animation 录制：**纯水平滚动 + 惯性减速**（快速拖动后释放，观察 DecelerationAnimator CADisplayLink 帧序列）；在 Time Profiler 中按 `KLineView.draw(_:)` 过滤，取峰值单帧耗时 | 单帧 make+draw 合并峰值 < 4ms；实测峰值 ms：**____**（回填） | make+draw 合并 < 4ms = 通过 |
| 2 | Instruments Time Profiler 录制：**pinch 缩放**（双指开合 3-5 次，含 defaultVisibleCount 从 80 变到更大/更小范围）；取 `KLineView.draw(_:)` 峰值单帧耗时 | 单帧 make+draw 合并峰值 < 4ms；实测峰值 ms：**____**（回填） | make+draw 合并 < 4ms = 通过 |
| 3 | Instruments Time Profiler 录制：**水平线绘制 + 跨缩放/平移后验证还原**（按实际 shipped 手势：点顶栏「水平线」按钮激活绘线 → **单指点击主图某一价位**落锚 → **确认横线可见**后再 pinch 缩放 + pan，确认线随视口正确变换；**codex review R4-Med 修正**：原文「长按起始→拖到终点」非实际手势〔实际 = 激活 + 单击落锚，见顺位 4 acceptance R3/R4〕，须先确认线渲染可见再采集计时，防测到 no-op/无关手势假 PASS）；取峰值单帧耗时（前置：顺位 4 #103 已注册 `HorizontalLineTool` 并 merged，`drawDrawings` 实际描画——线可见） | 单帧 make+draw 合并峰值 < 4ms **且横线确实渲染可见**；实测峰值 ms：**____**（回填） | make+draw 合并 < 4ms **且线可见** = 通过 |
| 4 | Instruments Time Profiler 录制：**长按十字光标拖动**（长按激活 crosshair snap，缓慢横扫全屏蜡烛区域）；取 `KLineView.draw(_:)` 峰值单帧耗时 | 单帧 make+draw 合并峰值 < 4ms；实测峰值 ms：**____**（回填） | make+draw 合并 < 4ms = 通过 |
| 5 | **Equatable 短路验证**：在 Instruments Core Animation 模板中，保持 engine 状态不变（不滚动、不缩放），连续 updateUIView 多次；观察 Core Animation commit 帧数量，确认无冗余重绘 | `KLineView.draw(_:)` 不被重复调用（Core Animation 无多余 layer commit）；Instruments frame timeline 稳定无多余峰值 | 无冗余重绘 = 通过 |

---

## 回填信息

| 项目 | 回填值 |
|---|---|
| Device 型号 | **____** |
| iOS / iPadOS 版本 | **____** |
| 场景 1 峰值单帧 ms | **____** |
| 场景 2 峰值单帧 ms | **____** |
| 场景 3 峰值单帧 ms | **____** |
| 场景 4 峰值单帧 ms | **____** |
| 场景 5 Equatable 短路 | 通过 / 未通过 |
| 实测日期 | **____** |

> **实测数值是 user device 职责 + 顺位 13 收尾阻塞依赖。** 本 runbook 在顺位 13 completion doc 中被引用；顺位 13 以「全场景已回填 + 全 pass」为收尾前置条件。

---

## Bitmap Cache 决议门

**以上场景峰值 ms 全部 < 4ms**
→ Phase 1 纯 draw 充分；Bitmap Cache **no-op**（outline L173）；本子项已关闭

**任一场景峰值 ms ≥ 4ms**
→ 触发 `docs/governance/2026-06-14-wave3-pr12-performance-review.md` §四 决议门，按其中设计草图引入 Bitmap Cache（独立后续 anchor），引入后须重测全场景回落 < 4ms 才可关闭
