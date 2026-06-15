# 验收清单 — 图表 reveal 约束（已揭示前缀窗口，改顺位 3 冻结视口几何 RFC）

**交付物：** `RenderStateBuilder.makeViewport` 两行改（`upperBound→max(0,baseStartIndex)` 禁前窥 + `sliceEnd→min(…,currentIdx+1)` slice 末根≤currentIdx）= **修 m3 轴（驱动周期）窗口未来泄漏 latent bug**（原始 W3-11-R1 触发的前向滚动/早 tick 泄漏）。设计经 opus 4.8 xhigh spec-review R1→R3 APPROVE 收敛；实施计划经 opus 4.8 xhigh plan-review APPROVE；整体 opus 4.8 xhigh 对抗 review APPROVE（brute-force 9480 组合 0 违反）。

> **作用域诚实声明（codex R4 [HIGH]）：** 本 RFC **仅修 m3 轴窗口泄漏**，**不**解决聚合面板（默认 m60/日线）的「进行中聚合 K 线」未来泄漏 —— `currentIdx`（首个 endGlobalIndex≥tick）对聚合周期指向尚未走完的聚合 K 线，其 OHLC 已用未来 m3 tick 算好。已实证复现（m3 tick=1 时 m60 面板画出 endGlobalIndex=3 的 K 线，含未来 tick 2/3）。该泄漏**既有、非本 RFC 引入**（本修复未使其变差，是严格改进）。登记为 HIGH residual（见下），需独立「聚合感知 reveal」RFC（决定 hide vs 用已揭示 m3 实时合成 partial）。codex 因此正确维持 needs-attention；本 PR 经 user `attest-override` 接受该 documented residual 合入（非自我裁定推翻）。

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
| R2 | 训练刚开局（前几根 tick）观察 **m3（驱动周期）** 图表 | 只显示已走出的 K 线（左填充），右侧为空槽，**无未来 m3 K 线**被画出（聚合面板进行中 K 线泄漏属 HIGH residual，本 RFC 不覆盖） | ☐ |
| R3 | 向后（朝历史）拖拽到最左 | 可滚到第一根 K 线为止，贴左边缘不裂口 | ☐ |
| R4 | mid-history 处（已滚动浏览）两指对准某根特征 K 线捏合缩放 | 该 K 线基本不动（focus 锚定）；缩放后仍不露未来 | ☐ |
| R5 | autoTracking 处向后拖不足一根（sub-candle） | 首根有轻微吸附感（最新边 pin，spec §M2 注明的预期一致行为，非缺陷） | ☐ |

## Residuals

- **【HIGH · codex R4】聚合面板进行中 K 线未来泄漏**：`currentCandleIndex`（首个 `endGlobalIndex≥tick`）对聚合周期（m60/日线）指向尚未走完的聚合 K 线，其 finalized OHLC/volume/指标含未来 m3 tick。实证：sparse 聚合 ends `[3,7,11]`，m3 tick=1 → currentIdx=0、slice 末根 endGlobalIndex=3 > tick=1（画出含未来 tick 2/3 的 K 线）。本 RFC 的 `slice 末根≤currentIdx` 不变量满足，但 currentIdx 自身的聚合 K 线越界 —— 这是设计层 `currentCandleIndex 不改` 决策外的更深问题。**后续独立 RFC**「聚合感知 reveal」决策：(a) 锚定到最后一根已完成 K 线（endGlobalIndex≤tick，hide 进行中，需处理空前缀/开局空白）vs (b) 用已揭示 m3 实时合成 partial 聚合 K 线（产品最优，是真实 feature）。该 RFC 改 currentCandleIndex 语义（pinch/autoTracking 锚共享）须走完整 brainstorming→design→review→codex 收敛。
- **W3-11-R1**（bounce live 接线，parked 于分支 `wave3-w3-11-r1-bounce-wiring`）：本 RFC merge 后 rebase onto 含 reveal 修复的 main，按 spec D5 重做 `offsetBounds`（`minOffset=0` / `maxOffset=max(0,baseStartIndex)·candleStep`）。
- **device 运行时矩阵**：本 RFC 新增 R1-R5 device 验收项归 Wave 3 矩阵收尾 reconciliation 或本验收清单自记（spec §七 ledger-B：不碰 Wave 3 completion 治理块）。
