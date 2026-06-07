# C8a ChartContainerView 渲染路径 — 验收 checklist（Wave 2 顺位 7 上半）

非编码者可执行。每项 action / expected / pass-fail；pass 标准二值可判。

| # | 操作（action） | 预期（expected） | pass / fail |
|---|---|---|---|
| 1 | 终端 `cd ios/Contracts && swift test --filter RenderStateBuilder` | 末行打印 `Test run with 20 tests in 1 suite passed`，failures 计数为 0 | pass = 末行含 `20 tests` 且 `passed` 且 0 failures；否则 fail |
| 2 | 同上命令输出里找 `[C8a perf smoke]` 行 | 打印一行形如 `[C8a perf smoke] makeViewport avg = <数字> ms (non-authoritative; not the spec frame budget)` | pass = 该行存在且 `<数字>` 为有限毫秒数；否则 fail。〔注：此为装配开销 smoke，**非** spec「120Hz 单帧 <4ms」帧预算；后者归 C8b/顺位 9 device 验收〕 |
| 3 | 终端 `cd ios/Contracts && swift test` （全量） | 末行打印 `Test run with 630 tests in 105 suites passed`，0 failures | pass = 0 failures 且总数 ≥ 610（C8a 新增 20）；否则 fail |
| 4 | 终端 `grep -c "NonDegenerateRange.make" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | 输出 `2`（volumeRange + macdRange 各一处） | pass = 输出恰为 `2`；否则 fail |
| 5 | 终端 `cd ios/Contracts && swift build` | 末行 `Build complete!`，无 error | pass = 出现 `Build complete!` 且无 `error:`；否则 fail |
| 6 | CI：PR 页面看 `Mac Catalyst build-for-testing on macos-15` required check | 该 check 状态为绿色 success（编译 + 链接 `ChartContainerView` + 编译反射测试通过） | pass = 该 required check 为 success；否则 fail。〔本地已跑同命令 `xcodebuild build-for-testing -destination 'platform=macOS,variant=Mac Catalyst'` 得 `** TEST BUILD SUCCEEDED **` 无 error/warning〕 |
| 7 | 打开 `git diff --stat ea23fbd..HEAD -- ios/` | 仅 4 个新文件（RenderStateBuilder.swift / ChartContainerView.swift / RenderStateBuilderTests.swift / ChartContainerViewCompileTests.swift），无既有文件被改 | pass = 恰 4 文件且全为新增（无既有 ios 文件出现在 stat 内）；否则 fail |

## 范围边界（本 PR 不含 → C8b / 顺位 9）

以下项**不在 C8a 验收范围**，由 C8b（顺位 7 下半）或顺位 9 关闭，见设计 doc §1.4 traceability：
- C7 手势 arbiter 生产接线、生产 handler（`animator.stop()→range→setDrawingSnapshot`）、`activateDrawingTool`/`deleteDrawing`、**H1 production handler 集成测试** → C8b。
- spec「120Hz 单帧 <4ms」device/sim 帧预算、C2/C7 运行时 artifact → C8b / 顺位 9。
