# tap-anywhere 退光标 + RFC-E 设置 popover — 验收清单

> 锚：`docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md` §5。
> 设备：模拟器 iPhone 17 Pro（udid `DE0BA39D-C749-459D-A407-4418599B61CA`）；popover 最坏态用可用最小屏机型再核一次。
> DEBUG fixture（`SIMCTL_CHILD_KLINE_SEED_FIXTURE=1`）。改 fixture 后须 `simctl uninstall` 再装（全空守卫 `AppContainer+DebugSeed.swift` 挡重灌）。
> 证据：每条附截图；popover 最坏态附截图。红涨绿跌。

## A · tap-anywhere 退十字光标

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| A1 | 长按**上图**主图出十字光标 → 轻点**下图**任意处（含下图成交量/MACD 区） | 上图十字光标消失 + 上图侧栏收起 + 两图恢复可平移/缩放/单指竖滑切周期 | 点下图后上图光标消失且交互恢复 = pass；光标残留或图仍冻结 = fail |
| A2 | 长按**上图**主图出光标 → 轻点**上图**任意处（含上图成交量/MACD 区） | 上图光标消失 + 解冻恢复交互 | 点上图任一处都退 = pass；仅主图蜡烛区能退、子图区点不退 = fail |
| A3 | 长按**下图**主图出光标 → 轻点**上图**任意处 | 下图光标消失 + 解冻恢复交互 | 点上图退下图光标 = pass；不退 = fail |
| A4 | 无任何光标时轻点图表（普通态） | 无异常：不进入光标、不冻结、不误触发画线锚点；图仍可平移/缩放/竖滑切周期 | 普通态点图无副作用 = pass；误进光标/误落锚点/卡死 = fail |
| A_drawing_remote_exit | 点画线浮动钮（✎）使**上图**进画线模式 → 长按**下图**主图出光标 → 轻点**上图**（画线图）一次 | 下图光标消失（**第一点先退光标**），上图**不新增**水平画线锚点；再点上图一次才落画线锚点 | 第一点退下图光标且不落线、再点才落线 = pass；第一点就在上图落了线/下图光标没退 = fail |

## B · RFC-E 设置 popover

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| A5 | 首页点右上角设置齿轮 | 弹出**锚定齿轮的小 popover**（非从屏幕底部升起的大 sheet），内含全部 5 项：佣金费率、最低 5 元佣金开关、重置资金、离线缓存下载、显示模式选择 | 锚齿轮小 popover + 5 项齐 = pass；底部大 sheet 或缺项 = fail |
| A6 | popover 打开时，点 popover 外部空白处 / 下滑关闭 | popover 关闭；不残留遮罩；不出现底部 sheet 同时弹出（无双弹） | 关闭干净且无双弹 = pass；关不掉/残留/同时弹 sheet = fail |
| A7 | popover 内：切换显示模式（白天/夜间/跟随系统）各一次；点离线缓存下载并填数量触发一次下载 | 显示模式即时生效；下载状态文字在 popover 内**可见不被裁剪**；行为与原 sheet 一致 | 模式切换生效 + 下载状态可读 = pass；模式不变/下载状态看不到 = fail |
| A_reset_dismiss | popover 内点「重置资金」→ 确认对话框点确认 | reset 成功后 **popover 自动关闭**，回到首页：总资金显示 ¥100,000，历史记录仍保留 | reset 后 popover 自动关 + 资金回 10 万 + 记录在 = pass；popover 残留在重置后首页上 = fail |
| A_worst_reachable | 构造 `loadError != nil`（恢复段出现，可断网后触发设置加载失败）+ 触发一次下载使下载状态文字同时出现 → 在**可用最小屏机型**打开设置 popover | popover 内：5 项 + 恢复段 + 下载状态文字**全部可滚动可达**；宽度不撑满全屏（≤ ~320pt）；reset/重试按钮可点击 | 全部内容可滚动可达且宽度受限 = pass；控件被裁剪点不到/popover 撑满 = fail |

## C · 自动闸门（CI/host，非人工，记录佐证）

| 项 | 命令/检查 | 通过判定 |
|---|---|---|
| host swift test | `swift test --package-path ios/Contracts` | Swift Testing 末行「passed」+ XCTest「All tests passed, 0 failures」= pass |
| Mac Catalyst 编译 | `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` | `** TEST BUILD SUCCEEDED **` + 无 error/warning = pass |
| iOS Simulator app build | `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` = pass |
| 源/行为/类型兼容 | `arbiter.onTap`/`onCrosshairExit` 仍 public 且 onTap 仍 fire（drawing 锚点）；`HomeView` 仍非泛型 concrete（bare 类型守卫测）；无 `== .settings`（`grep -rn "== *\.settings" ios/Contracts/Sources` 空） | 全满足 = pass |
| 契约版本 | CONTRACT_VERSION 未改（仍 1.7） | 未变 = pass |

> 本轮自动闸门已在 HEAD `c32730f` 全绿（host 1242/0 + 255/0；Catalyst TEST BUILD SUCCEEDED ci-gate=0；iOS BUILD SUCCEEDED；`== .settings` grep 守卫空；CONTRACT_VERSION 1.7 未动）。
> **Codex whole-branch**：spec/plan 阶段全收敛；whole-branch R1–R4 未取 approve——R3 真 bug 已修，剩 R1↔R2↔R4 在「为不存在的外部消费者保兼容」上振荡（详见 spec §8）。**user 拍板选项 C：判为理论性残留、走 override 旁路合并**（单 app 内部模块、唯一消费者已迁，功能正确）。
> A1–A7/A_drawing_remote_exit/A_reset_dismiss/A_worst_reachable 为人工真机/模拟器验收，附截图佐证后逐条判定。

## 运行/部署命令（参考）

**模拟器**（iPhone 17 Pro）：
```
xcodebuild -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'platform=iOS Simulator,id=DE0BA39D-C749-459D-A407-4418599B61CA' build
xcrun simctl uninstall booted com.agateuu1234.KlineTrainer
xcrun simctl install booted <Debug-iphonesimulator/KlineTrainer.app>
SIMCTL_CHILD_KLINE_SEED_FIXTURE=1 xcrun simctl launch booted com.agateuu1234.KlineTrainer
```
