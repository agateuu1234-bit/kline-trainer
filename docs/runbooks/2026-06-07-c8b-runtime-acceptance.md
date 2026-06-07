# C8b 运行时验收 runbook（C2 CADisplayLink 减速 + C8 draw 帧预算）

**性质**：device/simulator **手动**验收（CLI/CI 仅编译，不跑 UIKit 运行时；per outline §四 L121/L149）。
执行者：user（按步骤操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：在 U2 TrainingView（顺位 9）落地后，或用一个最小 SwiftUI 宿主把 `ChartContainerView(panel:.upper, engine:.preview())`
> 放进 Mac Catalyst / iPad 运行。两指/单指手势仲裁运行时证据归顺位 9 U2（本 runbook 只验 C2 减速 + C8 帧预算）。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | iPad/Catalyst 上单指水平快滑 K 线后松手 | 图表惯性滚动后平滑减速停下（CADisplayLink 驱动，非瞬停/非卡顿） | pass = 有可见惯性衰减且自然停 |
| 2 | 减速过程中点「买入/持有」 | 滚动立即中断、硬切锁定最新 K 线（无平滑过渡，spec L235）；其后无回弹漂移 | pass = 立即锁定且无后续漂移 |
| 3 | Instruments Time Profiler / Core Animation 录制滚动 + 减速 | `KLineView.draw(_:)` 单帧 < 4ms（120Hz 预算，spec L1467）；记录实测峰值 ms | pass = 峰值单帧 < 4ms（填实测值：____ ms） |
| 4 | 长按 K 线拖动 | 出现十字光标随手指移动；松手消失 | pass = 十字光标显示/跟随/消失正常 |
| 5 | 减速运行中切到后台再回前台 | 无 dt 爆炸跳帧（onSceneActivated→resetOnSceneActive，C2） | pass = 回前台无跳帧/无残留滚动 |

**回填**：执行后把 #3 实测 ms 填入；本 runbook 链接进收尾 completion doc 作 C2/C8 运行时 artifact。
