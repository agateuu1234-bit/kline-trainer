# Wave 3 顺位 2 — 竖屏锁 + iPad 全屏窗口 运行时验收 runbook

**性质**：device/simulator **手动**验收（CI 仅编译守护「能 build」，不验运行时方向/窗口行为）。
执行者：user（操作 + 记录），非编码者可执行。每项 action / expected / pass-fail。

> 前置：在 iPhone + iPad（含支持多任务的 iPad，如 iPad Pro，iPadOS 16+ 有 Stage Manager）真机或 simulator
> 运行 `KlineTrainer` app target（任意可启动页面即可——本 runbook 验全局 orientation/window 策略，与具体页面无关）。
> 锁定机制 = pbxproj build settings：`UISupportedInterfaceOrientations_*` 仅 Portrait + `UIRequiresFullScreen = YES`。

| # | action | expected | pass/fail |
|---|---|---|---|
| 1 | iPhone：启动 app，物理旋转设备到横向 | UI **保持竖屏**，不旋转到横向 | pass = 旋转设备 UI 不转横 |
| 2 | iPhone：旋转到倒置（upside-down） | UI 保持正立竖屏，不倒置 | pass = 不进入倒置方向 |
| 3 | iPad：启动 app，物理旋转到横向 | UI 保持竖屏，不旋转 | pass = iPad 旋转 UI 不转横 |
| 4 | iPad（iPadOS 16+）：从 Dock 拖另一 app 尝试进 Split View / Slide Over 与本 app 并排 | 本 app **拒绝**分屏共享（保持全屏占满），`UIRequiresFullScreen` 生效 | pass = 无法与本 app 并排分屏 |
| 5 | iPad（支持 Stage Manager 机型）：开启 Stage Manager，尝试把本 app 窗口缩小/拖成浮动窗 | 本 app 保持全屏、不可缩放为浮动窗 | pass = 窗口不可缩放/浮动 |
| 6 | 残留观测（codex R3-F3）：记录所用 iPadOS 版本号；若 step 4/5 在该版本出现**任何**窗口/方向泄漏 | 记录泄漏现象 + 版本号（用于判断是否需下游更深的运行时 scene/orientation delegate 锁） | pass = 已记录（无泄漏则记「无」） |

**回填**：执行后逐行填 pass/fail + step 6 的 iPadOS 版本与泄漏观测。本 runbook 作 Wave 3 新交互运行时矩阵的一项，是顺位 13 收尾的阻塞依赖之一（spec §三.B2 / §三.3）。
若 step 4/5/6 显示最新 iPadOS Stage Manager 下仍有窗口泄漏，则更深的运行时锁（scene/orientation delegate override）作下游 follow-up，**不**在本顺位 2 范围。
