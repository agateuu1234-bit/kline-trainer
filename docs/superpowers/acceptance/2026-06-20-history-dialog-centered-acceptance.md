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
- plan：R1 APPROVE（探针文件实证编译可行性全过：ViewBuilder `let _ = assertionFailure` / `AppRouter.Modal` 非 actor 隔离 / `== nil` 不需 Equatable / `.overlay`+`.animation`；7 测真 killer；High-1 守卫作用域精确；行号 provenance 对账无杜撰）+ 3 Low 修（取消注释字面对齐 / D5·D12 编号 / 引用计数措辞）。commits 295e211 / e2eda36。
- 实现期（subagent-driven，4 task 各两阶段 spec+quality）：Task1 spec✅/Approved（7 host @Test killer，1113 全绿）；Task2 spec✅/Approved（inner 字节级不变，host 0 fail + Catalyst SUCCEEDED）；Task3 spec✅/Approved（High-1 守卫逐字实证 + Catalyst+app SUCCEEDED）；Task4 spec✅/Approved（零改名泄漏 + 7/1113）。commits 96137ec / 9d542ec / a2bf62c / 139636c。
- verification（最终 HEAD 139636c 亲跑）：host swift test **1113 tests / 156 suites / 0 failures** + Catalyst **TEST BUILD SUCCEEDED** + iOS app **BUILD SUCCEEDED**。
- branch-diff（整体 whole-branch，opus 4.8 xhigh）：**APPROVE**（0 Critical/High/Medium；2 Low：plan 过程文档 stale「8」已修→7 / AppRootView dead 分支注释措辞略松，功能无影响）。分流 binding 状态机安全性逐路径推理 + 实测确认；AppRouter/HistoryActionContent/AppRouterTests 三者 git diff 皆空。
