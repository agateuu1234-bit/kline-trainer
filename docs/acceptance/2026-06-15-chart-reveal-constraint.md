# 验收清单 — 图表 reveal 约束（已揭示前缀窗口，改顺位 3 冻结视口几何 RFC）

**交付物：** `RenderStateBuilder.makeViewport` 两行改（`upperBound→max(0,baseStartIndex)` 禁前窥 + `sliceEnd→min(…,currentIdx+1)` slice 末根≤currentIdx）= 修未来泄漏 latent bug。设计经 opus 4.8 xhigh spec-review R1→R3 APPROVE 收敛；实施计划经 opus 4.8 xhigh 对抗评审收敛。

| # | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | `1021 tests in 144 suites passed`，`0 failures`（1016 baseline + 5 新增） | ☐ |
| 2 | `git diff origin/main...HEAD --stat -- ios/` 逐行核对 | 改动 Swift 文件集 ⊆ {RenderStateBuilder.swift, RenderStateBuilderTests.swift, TrainingEnginePinchTests.swift}；无 .sql/schema/CONTRACT_VERSION/workflow 改动 | ☐ |
| 3 | `git diff origin/main...HEAD -- ios/Contracts/Sources` 核对生产侧 | 仅 `makeViewport` 两行逻辑改 + reveal-RFC 注释；无 KLineView/PinchZoomModel/TrainingEngine 生产逻辑改动 | ☐ |
| 4 | `grep -n "max(0, baseStartIndex)" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift; echo rc=$?` | 命中（upperBound 收紧已落地）`rc=0` | ☐ |
| 5 | `grep -n "currentIdx + 1" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift; echo rc=$?` | 命中（sliceEnd 上限已落地）`rc=0` | ☐ |
| 6 | `cd ios/Contracts && swift test --filter revealedPrefixInvariantScan 2>&1 \| tail -2` | 该不变量扫描测试 PASS（跨 tick×offset 零前窥零空切片） | ☐ |
| 7 | Mac Catalyst CI：PR checks 页查 `Mac Catalyst build-for-testing on macos-15` | SUCCESS（平台无关几何，UIKit 面真编译） | ☐ |
| 8 | app-target CI：PR checks 页查顺位 2 设立的 app build required check | SUCCESS | ☐ |

## 运行时 runbook 条目（user device/sim 执行；spec §五.7 device 验收义务 + Wave 3 矩阵新增项）

| # | Action（iPad mini 7 或 Catalyst） | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练中（autoTracking）单指向左快滑（朝新方向 fling） | 最新一根 K 线钉在最右后**不再露出更新的（未来）K 线**；无空白未来区 | ☐ |
| R2 | 训练刚开局（前几根 tick）观察图表 | 只显示已走出的 K 线（左填充），右侧为空槽，**无未来 K 线**被画出 | ☐ |
| R3 | 向后（朝历史）拖拽到最左 | 可滚到第一根 K 线为止，贴左边缘不裂口 | ☐ |
| R4 | mid-history 处（已滚动浏览）两指对准某根特征 K 线捏合缩放 | 该 K 线基本不动（focus 锚定）；缩放后仍不露未来 | ☐ |
| R5 | autoTracking 处向后拖不足一根（sub-candle） | 首根有轻微吸附感（最新边 pin，spec §M2 注明的预期一致行为，非缺陷） | ☐ |

## Residuals

- **W3-11-R1**（bounce live 接线，parked 于分支 `wave3-w3-11-r1-bounce-wiring`）：本 RFC merge 后 rebase onto 含 reveal 修复的 main，按 spec D5 重做 `offsetBounds`（`minOffset=0` / `maxOffset=max(0,baseStartIndex)·candleStep`）。
- **device 运行时矩阵**：本 RFC 新增 R1-R5 device 验收项归 Wave 3 矩阵收尾 reconciliation 或本验收清单自记（spec §七 ledger-B：不碰 Wave 3 completion 治理块）。
