# Wave 3 顺位 9 — 夜间模式（白天/夜间/跟随系统）运行时验收 runbook

**性质**：device/simulator **手动**验收（CI 仅 Catalyst 编译守护 + UIKit 桥/选取链断言执行，不验运行时 `preferredColorScheme` 注入 + 像素重渲染 + 真 WCAG AA 亮度对比）。
执行者：user（操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：在 iPhone/iPad 启动 `KlineTrainer` app target；需有已缓存训练组（首页可进一局训练以观察图表）。
> 进设置面板路径：首页右上「设置」→ 见「显示模式」分段选择器（白天模式 / 夜间模式 / 跟随系统）。

**头注（token 作用域，避免误判）**：
- (a) 图表画布为透明（`KLineView.backgroundColor = .clear`）；图表大面积底色来自 SwiftUI 系统窗口背景，随 `colorScheme` 适配。13-token 中的 `background` token **仅**染十字光标价签/时签框，不染图表大底色。
- (b) SwiftUI 盈亏色（首页历史记录涨跌）= 系统 `.red/.green`，与图表 K 线红涨绿跌是**独立两条色轨**：仅验「红涨绿跌」**方向**一致，不验与图表 token 逐字同深浅。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | 设置面板「显示模式」选「白天模式」 | 全 UI（首页/设置/训练页）+ 图表**即时**变白底深字；K 线红涨绿跌仍清晰可辨；**观察首帧无明显闪白/闪暗** | □ pass / □ fail |
| 2 | 进一局训练，观察主图 + 副图（light 模式） | K 线（红涨绿跌）/ MA66（紫）/ BOLL（金虚线）/ MACD（DIF 深线 + DEA 琥珀 + 红绿柱）/ 长按十字光标价签框（白底深字）**均清晰可读**（白底对比足够，真 WCAG AA 目测或取色确认） | □ pass / □ fail |
| 3 | 设置面板选「夜间模式」 | 全 UI + 图表**即时**变近黑底浅字（= F2 PR #39 原观感）；token 取值 = 现有 dark 集 | □ pass / □ fail |
| 4 | 设置面板选「跟随系统」+ 系统当前为浅色 | app 外观与系统一致（浅色） | □ pass / □ fail |
| 5 | 保持 app 在「跟随系统」，下拉控制中心切系统为深色（不回前台手动操作 app） | app（含正在显示的图表）**自动跟随**变深色重渲染（验 `KLineView.registerForTraitChanges` + `AppRootView.preferredColorScheme(nil)`） | □ pass / □ fail |
| 6 | 在某模式（如白天）下杀掉 app → 重启 | 重启后仍为该模式（验 `display_mode` 经 `AppSettings` 落 settings 表持久化跨重启） | □ pass / □ fail |
| 7 | 打开任一 sheet 模态（设置面板 / 结算窗 / 历史动作表）于白天模式 | 模态内容同样为白天外观（验 `preferredColorScheme` 覆盖 `.sheet` 呈现） | □ pass / □ fail |

**回填**：执行后逐行填 pass/fail + 设备型号 / iOS 版本。本 runbook 作 Wave 3 新交互运行时矩阵一项，是顺位 13 收尾阻塞依赖之一（spec §三.3）。
核心运行时断言 = 三模式即时切换（step 1/3/4）+ 跟随系统自动重渲染（step 5）+ 持久化跨重启（step 6）+ light 图表可读（step 2）+ 模态覆盖（step 7）。

**设备 / 版本记录**：____________（型号 / iOS 版本 / 日期）
