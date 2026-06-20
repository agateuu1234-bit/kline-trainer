# 验收清单：历史记录改屏幕居中弹窗（RFC #2）

## 1. host 单测（机器执行）
- [ ] 动作：`cd ios/Contracts && swift test --filter HistoryDialogPresentationTests`
      预期：`HistoryDialogPresentation routing` 7 个全绿。
- [ ] 动作：`cd ios/Contracts && swift test`
      预期：全量 0 failures；相对基线净 = +HistoryDialogPresentation(7)，全量 host 测试 1113；`HistoryActionContentTests`/`AppRouterTests` 零改动全绿。

## 2. Mac Catalyst 编译（机器执行）
- [ ] 动作：`cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'`
      预期：`** TEST BUILD SUCCEEDED **`。

## 3. iOS app build（机器执行）
- [ ] 动作：`xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO`
      预期：`** BUILD SUCCEEDED **`。

## 4. 模拟器人工验收（iPhone 17 Pro + seed fixture）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 首页点一条历史记录 | 屏幕**正中**弹出卡片（标题=股票名（代码）+ 复盘/再来一次/取消），背景半透明变暗，**非底部滑出**；弹窗**稳定显示不秒关**（验 High-1 守卫） | ☐ |
| 2 | 点「复盘」 | 进入 Review 模式训练页，弹窗消失（淡出） | ☐ |
| 3 | 点「再来一次」 | 进入 Replay 模式训练页，弹窗消失（淡出） | ☐ |
| 4 | 点「取消」 | 弹窗消失，停留首页，不进训练 | ☐ |
| 5 | 点卡片外的半透明遮罩 | 弹窗消失（等同取消），停留首页 | ☐ |
| 6 | 弹窗视觉 | 居中小卡片 + 圆角 + 阴影 + 变暗遮罩；淡入淡出 | ☐ |
| 7 | 点齿轮进设置 | 设置面板仍从**底部**滑出（未受影响） | ☐ |
| 8 | 跑完一局正常结束 | 结算窗仍从**底部**滑出（未受影响） | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 复盘/再来一次后返回首页 | 导航/teardown 一切如常（AppRouter 逻辑未变） | ☐ |
| 2 | review/replay 失败（如缺数据） | 「出错了」alert 仍正常弹出（弹窗先消失再弹 alert，不叠） | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（2C/2H/3M/3L）→ 全修（撤销改名等）→ R2 APPROVE。commits 25d8a34 / 9b27cd3 / d90b668。
- plan：<填 plan-stage review 结论>。
- 实现期（subagent-driven，4 task 两阶段）：<填>。
- verification：<填 host/Catalyst/app 三项实跑>。
- branch-diff：<填整体对抗性 review 结论>。
