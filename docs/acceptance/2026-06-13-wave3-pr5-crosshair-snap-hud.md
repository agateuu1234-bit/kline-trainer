# Wave 3 顺位 5：十字光标吸附 + HUD 验收清单（中文非-coder 可执行）

**PR 范围**：纯渲染层。`CrosshairLayout.swift`（吸附核心 + resolve）+ `KLineView+Crosshair.swift`（薄层接线）+ `CrosshairLayoutTests.swift`（吸附/clamp/守卫/post-pinch 矩阵）+ 本验收文档。**0 engine / 0 Coordinator / 0 arbiter / 0 spec 改动**。

**spec**：`docs/superpowers/specs/2026-06-13-wave3-pr5-crosshair-snap-hud-design.md`（opus 4.8 xhigh 对抗 review R1-R4 收敛 APPROVE）。

## 静态 / host 验收

| Step | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 4 文件改动，无 engine/Coordinator/arbiter 文件 | □ Pass / □ Fail |
| 2 | `cd ios/Contracts && swift test --filter "SnappedIndexTests\|ResolveTests"` | `SnappedIndexTests`(5) + `ResolveTests`(7) 全 PASS | □ Pass / □ Fail |
| 3 | 查 `CrosshairLayout.swift` | 含 `snappedCandleIndex` + `resolve` + `CrosshairResolved`；**无** `lines`/`priceLabel`/`timeLabel` 旧函数 | □ Pass / □ Fail |
| 4 | `grep -rnE "CrosshairLayout\.(lines\|priceLabel\|timeLabel)" ios/Contracts` | 无匹配（旧 API 引用已清） | □ Pass / □ Fail |
| 5 | CI | `Mac Catalyst build-for-testing on macos-15` required check SUCCESS | □ Pass / □ Fail |

## 运行时 runbook（设备/模拟器手测，顺位 13 阻塞依赖，user device 职责）

| Step | Action | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 训练页长按主图任意位置 | 出现十字光标；**竖线落在最近蜡烛中心**（非手指原始 x）；底部时间 label 显示该蜡烛日期时间 | □ Pass / □ Fail |
| R2 | 长按后水平拖动手指 | 竖线在相邻蜡烛间**跳变吸附**（过中点跳邻居）；价格 label 随手指 Y **连续自由移动**（不锁蜡烛价） | □ Pass / □ Fail |
| R3 | 先 pinch 缩放（顺位 3）改变蜡烛密度，再长按 | 吸附仍落正确蜡烛中心（基于 post-pinch 几何，竖线对准缩放后的蜡烛） | □ Pass / □ Fail |
| R4 | 长按拖到主图区外 / 松手 | 区外无光标；松手光标消失 | □ Pass / □ Fail |
