# 验收清单：两图 pan 时间对齐联动（RFC #4）

## 1. host 单测（机器执行）
- [ ] `cd ios/Contracts && swift test --filter PanLinkageTests` → 7 个全绿。
- [ ] `cd ios/Contracts && swift test --filter TrainingEnginePanLinkageTests` → 7 个全绿。
- [ ] `cd ios/Contracts && swift test` → 全量 0 failures；净 = +14（PanLinkage 7 + 引擎接线 7），现有零回归；全量 host 测试数 = 1127。

## 2. Mac Catalyst 编译（机器执行）
- [ ] `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` → `TEST BUILD SUCCEEDED`。

## 3. iOS app build（机器执行）
- [ ] `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`。

## 4. 模拟器人工验收（iPhone + seed fixture，默认 upper=60m / lower=日线）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 拖上图（60m）向右回看历史 | 下图（日线）右缘同步滚到**同一时刻**（时间对齐，非同像素） | ☐ |
| 2 | 拖下图（日线）回看 | 上图（60m）同步跟随到同一时刻 | ☐ |
| 3 | 拖任一图后**松手**（带速度） | 两图惯性减速**逐帧同步**滚动至停，全程不脱节 | ☐ |
| 4 | 一直拖到最老边 | follower graceful clamp，无突兀跳变/越界 | ☐ |
| 5 | 不拖时 | 两图各自 autoTracking（offset=0），右缘都在当前 tick | ☐ |
| 6 | 在一图画线后拖另一图 | 画线图暂不跟（冻结），拖动图正常；退出画线/下次操作后复位 | ☐ |
| 7 | 买卖成交 / 两指切周期 | 两图一起 reset 到最新（lockstep），仍右缘对齐 | ☐ |
| 8 | 缩放（pinch）一图 | 仅该图缩放（pinch 不联动）；若恰在最老边 overscroll 中途起 pinch/画线，另一图右缘可瞬时不跟（D13/R8 已知边界），下次 pan/trade/combo 即复位 | ☐ |

## 5. 回归确认（非编码者执行）
| # | 动作 | 预期 | 通过? |
|---|------|------|------|
| 1 | 单图 pan 物理（rubber-band/惯性/reveal 禁前窥） | leader 行为一字未变（D12） | ☐ |
| 2 | 坐标轴/网格/markers/crosshair | RFC #3 轴 + markers 跨周期一切如常 | ☐ |

## 6. Opus 4.8 xhigh 对抗性 review ledger（代 codex，user explicit）
- spec：R1 NEEDS-ATTENTION（2H/3M/2L）→ 全修 → R2 APPROVE。commits 577f44c / eb314cc / fcec521。
- plan：<填 plan-stage review 结论>。
- 实现期（subagent-driven，3 task 两阶段）：<填>。
- verification：<填 host/Catalyst/app 三项实跑>。
- branch-diff：<填整体对抗性 review 结论>。
