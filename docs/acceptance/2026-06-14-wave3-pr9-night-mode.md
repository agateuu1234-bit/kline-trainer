# Wave 3 顺位 9：夜间模式（白天/夜间/跟随系统）验收清单（中文非-coder 可执行）

**PR 范围**：① 纯值层 `Theme.swift` 新增 `AppPalette`（light/dark 双集 + `forScheme`）+ `displayModePrefersDark` + UIKit `UIChartPalette`（scheme-aware 桥）；② `KLineView` 加 `themeController`/`currentPalette` + `registerForTraitChanges` 重渲染；③ 5 个 render extension `AppColor.X`→`currentPalette.X`；④ `AppRootView.preferredColorScheme` 据 `display_mode` 驱动全窗；⑤ `ThemePaletteTests`（纯值 8 + UIKit 4）；⑥ spec amendment（modules §F2 / plan §Phase 5「顺位 9 已落地」）+ 运行时 runbook + 本验收。**0 schema 改动；`AppColorTokens`/`AppColor` 数值零改（F2 冻结复用为 dark 集）；SettingsPanel 三模式 Picker 既已接线，本 PR 不改。**

**plan**：`docs/superpowers/plans/2026-06-14-wave3-pr9-night-mode.md`（opus 4.8 xhigh 对抗 review R1-R2 收敛 APPROVE）。**契约**：RFC `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.3。

## 静态 / host 验收

| Step | Action | Expected | Pass/Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 `Theme.swift` / `KLineView.swift` + 5 render extension / `AppRootView.swift` / `ThemePaletteTests.swift` / modules+plan amendment / runbook + 本验收 改动 | □ Pass / □ Fail |
| 2 | `cd ios/Contracts && swift test --filter "AppPaletteTests\|DisplayModePrefersDarkTests"` | `AppPaletteTests`(7) + `DisplayModePrefersDarkTests`(1) 全 PASS | □ Pass / □ Fail |
| 3 | `cd ios/Contracts && swift test` | 全量 0 failures（host 基线 942 + 净增 8 = 950；UIKit 套件 host 不计入） | □ Pass / □ Fail |
| 4 | 查 `Theme.swift` `AppPalette.light` | 13 token 齐全；`candleUp` 红主导 / `candleDown` 绿主导（语义保红涨绿跌）；`macdBarPositive==candleUp`/`profitRed==candleUp` 等 D-3 alias 成立 | □ Pass / □ Fail |
| 5 | 查 `Theme.swift` `AppColorTokens` / `AppColor` | 13 个默认色数值与签名**未改**（F2 冻结；`AppPalette.dark` 逐字段复用之） | □ Pass / □ Fail |
| 6 | `grep -rn "AppColor\." ios/Contracts/Sources/KlineTrainerContracts/Render/ \| grep -v "///"` | render 代码路径无 `AppColor.`（全改 `currentPalette.`；仅注释引用且已更新为 `currentPalette`） | □ Pass / □ Fail |
| 7 | `bash scripts/governance/verify-wave3-pr1-rfc.sh` | (a)-(e)+(g) PASS（RFC 契约短语 `light/dark 双 token 集` 等仍在位 + 无冻结 doc 改动）。**注**：(f) 为顺位 1 RFC PR 的 docs-only 范围守卫，对本实现 PR（合法改 ios/swift）预期 FAIL，非回归；本脚本未接入任何 CI workflow | □ Pass / □ Fail |
| 8 | CI | `Mac Catalyst build-for-testing on macos-15` required check SUCCESS（UIKit 代码真编译：`UIChartPalette`/`currentPalette`/`registerForTraitChanges`/`AppRootView.preferredColorScheme`） | □ Pass / □ Fail |

> **Catalyst 本地实测记录**（本 PR 已跑）：`build-for-testing` = `TEST BUILD SUCCEEDED`；`test -only-testing UIChartPaletteTests + ThemeControllerTests + AppColorBridgeTests` = 10 tests PASS（含 `traitSelectsPalette` 跑 trait→scheme→palette 选取链、`darkBridge`/`lightBridge` 13 字段 UIColor 桥保真）。

## 运行时 runbook（设备/模拟器手测，顺位 13 阻塞依赖，user device 职责）

详见 `docs/runbooks/2026-06-14-wave3-pr9-night-mode-runtime-acceptance.md`，核心 7 项：

| Step | Action | Expected | Pass/Fail |
|---|---|---|---|
| R1 | 设置→显示模式→「白天模式」 | 全 UI + 图表即时变白底深字；红涨绿跌仍辨；首帧无明显闪白 | □ Pass / □ Fail |
| R2 | 进训练页看 light 图表 | K线/MA66/BOLL/MACD/十字光标价签均清晰可读 | □ Pass / □ Fail |
| R3 | 选「夜间模式」 | 即时变近黑底浅字（= F2 原观感） | □ Pass / □ Fail |
| R4 | 选「跟随系统」 | 与系统外观一致 | □ Pass / □ Fail |
| R5 | 「跟随系统」下系统切深色 | app 含图表自动跟随重渲染 | □ Pass / □ Fail |
| R6 | 某模式下杀 app 重启 | 模式持久化保留 | □ Pass / □ Fail |
| R7 | 白天模式下开 sheet 模态 | 模态同为白天外观 | □ Pass / □ Fail |

## merge 后
- memory 落地：写 `project_pr<N>_wave3_pr9_merged.md` + 更新 `MEMORY.md` index。
- 运行时 R1-R7 回填留 user device（顺位 13 收尾阻塞依赖）。
