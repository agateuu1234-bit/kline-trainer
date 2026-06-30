# RFC-C 长按十字光标 overlay + 单指竖滑切周期 — 验收清单

> 锚：`docs/superpowers/specs/2026-06-30-crosshair-sidebar-period-swipe-design.md` §8。
> 设备：模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`）+ 真机（haptic 必须真机）。
> DEBUG fixture（`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）。改 fixture 后须 `simctl uninstall` 再装（全空守卫 `AppContainer+DebugSeed.swift` 挡重灌）。
> 证据：每条附截图；haptic 条附真机说明。红涨绿跌。

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| 1 | 长按上图主图 | 细实线十字、竖线落最近 K 线中心、**竖线贯穿整周期图（主图+成交量+MACD）**、横线在手指 Y（仅主图）、**时间标在整图最底部（MACD 下方，非成交量上方）**、**整图冻结**（背景不平移/缩放） | 竖线贯穿三子图 + 时标在最底 + 图不动 = pass；竖线只到主图/时标在成交量上方/图动 = fail |
| 2 | 按住左右拖动 | 竖线逐根**跳变吸附**相邻 K 线；横线随手指 Y；图始终不动 | 逐根吸附且图不动 = pass；否则 fail |
| 3 | 按住拖动（**真机**） | 每跨到下一根 K 线**一次短震动**；停同一根不重复震 | 每根一次震动 = pass；不震或乱震 = fail |
| 4 | 长按出光标后**松手抬指** | 光标**保留**在原位、信息栏仍显示（不消失） | 松手后光标/栏保留 = pass；松手即消失 = fail |
| 5 | 光标显示时**点一下屏幕** | 光标消失 + 信息栏收起 + 图恢复可平移/缩放 | 点击退出且恢复交互 = pass；点击无效 = fail |
| 6 | 长按使光标在主图**中心偏右** | 悬浮信息栏停靠**左侧** | 偏右→栏左 = pass；否则 fail |
| 7 | 长按使光标在主图**中心或偏左** | 悬浮信息栏停靠**右侧** | 偏左→栏右 = pass；否则 fail |
| 8 | 看信息栏字段 | 栏顶居中实时价 + 日期·时间（同行）+ 开/高/低/收 + 涨跌 + 涨跌幅 + [均价] + 成交量 + [成交额]；日内（3/15/60分）显时分、日/周/月只显日期 | 字段齐全且周期对应 = pass；缺失/错周期 = fail |
| 9 | 看信息栏颜色（涨 K 线 vs 跌 K 线各一次） | 实时价/收/涨跌/涨跌幅：涨红/跌绿/平白（基准=前一根收盘）；日期时间/开/高/低/均价/量/额：黄色 | 两类颜色规则都符 = pass；任一错 = fail |
| 10 | 上下滑动横线（竖线停同一根不动） | 栏顶「实时价」随横线纵轴读数变化；其值是纵轴价位（不等于该根收盘也正常） | 实时价随横线变 = pass；不变或乱跳 = fail |
| 11 | 长按**下图**（日线）主图 | 信息栏显**日线**那根明细（非上图 60 分） | 显下图周期数据 = pass；显上图 = fail |
| 12 | 普通态（无光标）**单指竖直一甩** | 周期切换一档（上滑变大/下滑变小）；横滑仍平移 | 竖滑切一档且横滑平移 = pass；不切或乱切 = fail |
| 13 | 普通态**两指竖滑** | **不再切周期**（两指捏合仍能缩放） | 两指竖滑无切周期 + 捏合能缩放 = pass；两指仍切周期 = fail |
| 14 | 均价行（正常/异常） | 正常：显均价且落 [低,高]；异常（越界）：均价行隐藏（不显假值） | 落区间显/越界隐 = pass；显越界假值 = fail |
| 15 | 长按成交量/MACD/坐标轴区（非主图蜡烛区） | 不进入十字光标、图不冻结（仍可平移/缩放） | 子图区长按无反应 = pass；冻结或出隐形光标 = fail |
| 16 | 先向右滚动（更早历史移屏外）再长按**最左可见**那根 K 线 | 涨跌/涨跌幅显**真实值**（非「—」）、收/光标按真实前收上色 | 最左根显真实涨跌 = pass；显「—」/白 = fail |
| 17 | 十字光标**黏滞显示时**点画线浮动钮（✎）进入画线模式 | 光标消失、图恢复、之后点图落水平线锚点（非退光标） | 进画线退光标且点图落锚 = pass；点图退光标/落锚失败 = fail |
| 18 | 小幅横拖一点再按住进光标 → 松手 → 再正常拖图 | 后续平移正常（无残留 pan 状态卡死） | 平移正常 = pass；卡死/offset 异常 = fail |

---

## 运行/部署命令（参考）

**模拟器**（iPhone 17 Pro）：
```
xcodebuild -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'platform=iOS Simulator,id=DE0BA39D-C749-459D-A407-4418599B61CA' build
xcrun simctl uninstall booted com.agateuu1234.KlineTrainer   # 改 fixture 后必做
xcrun simctl install booted <Debug-iphonesimulator/KlineTrainer.app>
SIMCTL_CHILD_KLINE_SEED_FIXTURE=1 xcrun simctl launch booted com.agateuu1234.KlineTrainer
```

**真机**（haptic 验收，#3）：Xcode 开 `ios/KlineTrainer/KlineTrainer.xcodeproj` + 签名 + scheme 加 `KLINE_SEED_FIXTURE=1`，或命令行 `devicectl`（见 backlog memory 真机部署守则）。

## 验收记录（user 填）
- 模拟器逐条（截图）：待 user 驱动模拟器。
- 真机 #3 haptic + #1-2 手势手感：待 user 真机。
