# WB-R4 兼容收口 + DateFormatter 缓存 — 验收清单

> 锚：`docs/superpowers/specs/2026-07-01-residuals-compat-datefmt-design.md` §5。基线 origin/main `d2eb431`。
> 设备：iPhone 15 Pro Max（udid `26B6E21A-8CA6-5045-8593-39D1D4082A88`）真机 / iPhone 17 Pro 模拟器。DEBUG fixture（`SIMCTL_CHILD_/DEVICECTL_CHILD_KLINE_SEED_FIXTURE=1`）。
> 本轮为**纯结构/性能改进 + 公共谓词行为回退**——**无用户可见变化**，验收本质 = **无回归**（三处功能与改前逐像素/逐字一致）。证据：每条附截图。

## A · 人工真机/模拟器（无回归验收）

| # | 操作（action） | 预期（expected） | 通过判定（pass/fail） |
|---|---|---|---|
| A1 | 首页点右上角设置齿轮 → 打开 popover → 点外部/下滑关闭 → 再开 → 点「重置资金」确认 | 锚齿轮小 popover 弹出含 5 项（佣金费率/最低5元佣金/重置资金/离线缓存下载/显示模式）；**非底部大 sheet**；点外部/下滑正常关闭、**不残留、不同时弹底部 sheet（无双弹）**；reset 成功后 popover 自动关、资金回 ¥100,000、记录保留 | 与 #135 行为逐条一致 = pass；出现双弹/关不掉/reset 后 popover 残留 = fail |
| A2 | 训练界面长按出十字光标 → 拖动（日内 60分图 + 日/周/月图各试） | 底部时间标签正确显示吸附 K 线日期时间（日内 `yyyy-MM-dd HH:mm`）；悬浮信息栏日期/时间正确（日内显时分、日/周/月只显日期）；拖动流畅 | 文本与缓存前一致、无错格/空白、流畅 = pass；文本变化/卡顿/串格 = fail |
| A3 | 平移/缩放图表（各周期） | 底部时间轴 4 个标签按周期正确格式化：日内 `MM-dd HH:mm`、日/周 `yyyy-MM-dd`、月 `yyyy-MM` | 各周期格式正确且与改前一致 = pass；格式错/串周期 = fail |

## B · 自动闸门（CI/host，记录佐证）

| 项 | 命令/检查 | 通过判定 |
|---|---|---|
| host swift test | `swift test --package-path ios/Contracts` | Swift Testing 末行 0 failures + XCTest「All tests passed」+ 新 `DateFormatterCacheConcurrencyTests`（并发压测）绿 = pass |
| Mac Catalyst 编译 | `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst'` | `** TEST BUILD SUCCEEDED **` + CI-gate `grep -cE "(error\|warning):"` == 0（**验纯 static let 零 warning、无 nonisolated(unsafe) "unnecessary"**）= pass |
| iOS Simulator app build | `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator'` | `** BUILD SUCCEEDED **` = pass |
| `== .settings` 守卫 | `grep -rn "== *\.settings" ios/Contracts/Sources`（应空） | 空 = pass |
| 契约版本 | `CONTRACT_VERSION` 未改（仍 `1.8`） | 未变 = pass |
| formatter 输出不变 | 现有 `CrosshairLayoutTests`/`CrosshairSidebarContentTests`/`AxisGridLayoutTests` 时间/日期文本断言不变仍过 | 全过 = pass |

> 本轮自动闸门已在 HEAD `9bed51b` 全绿（host Swift Testing 1300/0 + XCTest 255/0；Catalyst TEST BUILD SUCCEEDED CI-gate=0；iOS BUILD SUCCEEDED；grep 守卫空；CONTRACT_VERSION 1.8 未动）。**Codex**：spec R1-R4 APPROVE `@2eba044`；whole-branch codex 见 PR。A1-A3 为人工无回归验收，附截图佐证后判定。
