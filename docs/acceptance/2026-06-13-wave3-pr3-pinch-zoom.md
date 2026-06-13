# 验收清单 — Wave 3 顺位 3：Pinch 缩放（§4.4d engine-owned zoom）

**交付物：** `PinchZoomModel`（clamp 20/240 + focus 数学）+ `ChartAction.zoomApplied`（3 mode 矩阵，autoTracking 右锚显式置 0 = user 2026-06-13 裁决 A）+ `engine.applyPinch`（pinchBase 归一 + guard）+ `makeViewport` 去硬编码 80 + `ChartContainerView` onPinch 接线 + 四 doc amendment（zoom 6→3 重指派 + focus 裁决落档）。设计经 opus 4.8 xhigh 5 轮对抗评审收敛 APPROVE。

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `896 tests in 126 suites passed`，`0 failures`（864 baseline + 32 新增） | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/` 逐行核对 | 改动 Swift 文件集 ⊆ {PinchZoomModel.swift(新), RenderStateBuilder.swift, Reducer.swift, TrainingEngine.swift, ChartContainerView.swift} + 4 测试文件；无 .sql/schema/CONTRACT_VERSION/workflow 改动 | ☐ |
| 3 | `git diff origin/main...HEAD -- ios/ \| grep -E "func (saveProgress\|finalize)" ; echo rc=$?` | `rc=1`（零命中 = saveProgress/finalize 方法体零改动，ephemeral 不变量；RFC §4.4d） | ☐ |
| 4 | `bash scripts/governance/verify-wave3-pr1-rfc.sh` | `(a)(b)(c)(d)(e)(g) PASS`；仅 `(f) FAIL`（实施分支改 .swift 属预期，scope 谓词为顺位 1 PR 专属） | ☐ |
| 5 | `grep -c "user 2026-06-13 裁决" kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` | 三文件计数分别 ≥1（focus 裁决 A 落档在位） | ☐ |
| 6 | `grep -cF "pinch/zoom panel-state mutation" kline_trainer_modules_v1.4.md` | ≥1（机器锚未被 amendment 破坏） | ☐ |
| 7 | Mac Catalyst CI：PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS（onPinch 接线 UIKit 面真编译） | ☐ |
| 8 | app-target CI：PR checks 页查顺位 2 设立的 app build required check | SUCCESS | ☐ |

## 运行时 runbook 条目（user device/sim 执行；outline §三.3 顺位 3 义务）

| # | Action（iPad mini 7 或 Catalyst） | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练中（autoTracking）两指张开 | K 线变宽（根数变少），最新 K 线始终钉在最右；时间流不中断 | ☐ |
| R2 | 单指左滑进入浏览（freeScrolling）后，把手指中点对准某根特征 K 线两指张开/捏拢 | 该 K 线在屏幕上基本不动（焦点锚定）；无跳变 | ☐ |
| R3 | 连续张开到极限 | 缩到 20 根后不再变宽，无崩溃/抖动 | ☐ |
| R4 | 连续捏拢到极限 | 缩到 240 根后不再变密 | ☐ |
| R5 | 两指竖直滑动（不捏合） | 切换周期组合触发，**不**发生缩放（C7 仲裁不串扰） | ☐ |
| R6 | 上面板缩放后看下面板 | 下面板根数不变（per-panel 隔离） | ☐ |
| R7 | 浏览历史滚到最左边缘后在边缘附近捏合 | 视图贴边不裂口（边缘饱和优先于焦点锚定，预期行为） | ☐ |

## Residuals

- **W3-11-R1**（bounce live 接线）：维持 OPEN，**顺位 3 后 fast-follow 独立 PR**（设计 D8；本 PR 未碰边缘饱和规则）。
- **outline 残差 `:194` partial-closure**：visibleCount=80 硬编码部分**闭合**；candleWidthRatio=0.7 部分以「已是命名常量、无任何 spec/输入驱动其可变」close（设计 R1-M2，非静默收窄）。
- **顺位 4 forward-note**（设计 R1-M3）：接线 `drawingCommitted/drawingCancelled` 时必须同步 `resetOffsetAfterAutoTracking`，否则 autoTracking+offset≠0 破坏右锚前提（reducer zoomApplied 显式置 0 仅第二道防御）。
- **clamp/灵敏度常量**（20/240/恒等映射）：runbook 实测手感不适 → `PinchZoomModel` 一行改（设计 D4）。
