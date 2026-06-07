# C8b 图表交互路径 + H1 闭环 — 验收 checklist（Wave 2 顺位 7 下半）

非编码者可执行。每项 action / expected / pass-fail；pass 标准二值可判。

| # | 操作（action） | 预期（expected） | pass / fail |
|---|---|---|---|
| 1 | 终端 `cd ios/Contracts && swift test --filter TrainingEngineDrawingHandlerH1Tests` | 末行 `Test run with 4 tests in 1 suite passed`，0 failures | pass = 4 tests 且 passed 且 0 failures |
| 2 | 终端 `cd ios/Contracts && swift test --filter TrainingEngineInteractionTests` | 末行 passed，0 failures（12 tests） | pass = 0 failures 且 ≥12 tests |
| 3 | 终端 `cd ios/Contracts && swift test` （全量） | 末行 `Test run with N tests in M suites passed`，0 failures。实测 **694 tests in 111 suites**（基线 commit 22c88de 674→C8b 新增 Interaction 12 + H1 4 + GestureRouting 2 + RenderStateBuilder 2 + ChartContainerViewCompile 2 = +20，合计 694） | pass = 0 failures 且 N ≥ 692 |
| 4 | 终端 `grep -n "animator(for: panel).stop()" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 命中 `activateDrawingTool` 内 stop 行（① 早于算 range）；实测：line 565 | pass = 恰 1 处命中且在 activateDrawingTool 体内 |
| 5 | 终端 `grep -n "decelerationDriverFactory" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 命中 init 参数 + 2 处 animators 构造复用；实测：lines 72/129/130（3 处） | pass = ≥2 处命中 |
| 6 | CI：PR 页 `Mac Catalyst build-for-testing on macos-15` required check | 绿色 success（ChartContainerView+Coordinator 编译链接通过） | pass = 该 required check success（本地 `xcodebuild build-for-testing -destination 'platform=macOS,variant=Mac Catalyst'` 得 `** TEST BUILD SUCCEEDED **` 无 error/warning；实测：CATALYST GATE PASS） |
| 7 | 打开 `docs/runbooks/2026-06-07-c8b-runtime-acceptance.md` | C2/C8 运行时手动验收 runbook 在位（5 项 action/expected/pass-fail） | pass = 文件存在且含 #3 帧预算 < 4ms 项 |
| 8 | 终端 `git diff --stat 22c88de..HEAD -- ios/` | 改 **5 既有文件**（Sources: TrainingEngine.swift / RenderStateBuilder.swift / ChartContainerView.swift；Tests: ChartContainerViewCompileTests.swift / RenderStateBuilderTests.swift）+ **4 新文件**（Sources: ChartEngine/GestureRouting.swift；Tests: ChartEngine/GestureRoutingTests.swift / TrainingEngineInteractionTests.swift / TrainingEngineDrawingHandlerH1Tests.swift）；无其他 ios 既有文件被改；实测：9 files changed, 590 insertions(+), 11 deletions(-) | pass = 恰 9 文件且为上述 5 改 + 4 新 |

## spec 偏离记录（须回填 Wave 2 收尾 completion doc 的 deviation ledger）
- **D2**：`activateDrawingTool(_:panel:)` 比 spec L1622 字面 `func activateDrawingTool(_: DrawingToolType)` **多 `panel: PanelId` 参数**——drawing 模式是 per-`PanelViewState`，须指明面板。依据 user 2026-06-07 裁决（本 plan §决策 D2）。`deleteDrawing(at:)` 与 spec L1623 一致（不加 panel）。

## 范围边界（本 PR 不含 → Wave 3 / 顺位 9）
- pinch 缩放改 visibleCount（onPinch）、画线锚点放置/提交（onTap + DrawingInputController + drawingCommitted/Cancelled 生产触发）→ Wave 3。
- 手势仲裁运行时证据（双识别器/斜向消歧）→ 顺位 9 U2（outline §四 L121/L125）。
- draw 帧预算 device 实测 ms 由 runbook #3 执行后回填。
