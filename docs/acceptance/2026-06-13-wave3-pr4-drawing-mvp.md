# Wave 3 顺位 4 — 水平线绘线 MVP 验收清单（中文非-coder 可执行）

**PR 范围**：水平线绘线 MVP + 画线 source-of-truth 全链路。2 新 prod 文件（`HorizontalLineTool` / `DefaultDrawingInputController`）+ 5 改 prod 文件（engine commit/cancelDrawing、RenderStateBuilder panelPosition 过滤、KLineView tool 注册、ChartContainerView onTap 接线、TrainingView toggle 按钮）+ 5 新/扩 test + 2 spec/RFC doc。

**契约依据**：`docs/superpowers/specs/2026-06-13-wave3-pr4-drawing-mvp-design.md`（经 opus 4.8 xhigh 对抗性 review R2 APPROVE）；engine commit/cancelDrawing 经 **user 2026-06-13 裁决** supersede neck-doctrine（RFC §4.4 总纲注记 + spec §D-ENGINE）。

---

## 一、静态验收（命令可跑，二元判定）

| Step | Action（在 PR 分支 worktree 根目录跑） | Expected | Pass / Fail |
|---|---|---|---|
| S1 | 浏览器打开本 PR 文件列表 | 含新文件 `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift` 与 `.../Drawing/DefaultDrawingInputController.swift` | □ Pass / □ Fail |
| S2 | `grep -Fn 'tools: [:]' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift; if [ $? -eq 0 ]; then echo FAIL; else echo PASS; fi` | 输出 `PASS`（`KLineView` 已不再含硬编码空 `tools: [:]`，改为注册 `Self.drawingTools`） | □ Pass / □ Fail |
| S3 | `grep -Fn 'Self.drawingTools' ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 命中 1 行（`drawDrawings(... tools: Self.drawingTools)`） | □ Pass / □ Fail |
| S4 | `grep -Fn 'func commitDrawing' ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift; grep -Fn 'func cancelDrawing' ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 两条均命中各 1 行 | □ Pass / □ Fail |
| S5 | `grep -Fn '画线-FSM-退出 handler 家族例外注记' ios/Contracts/../docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`（或在仓库根跑 `grep -Fn '画线-FSM-退出 handler 家族例外注记' docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`） | 命中（RFC §4.4 总纲含 user 2026-06-13 裁决注记） | □ Pass / □ Fail |
| S6 | `grep -Fn 'panelPosition == (panel == .upper ? 0 : 1)' ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | 命中 1 行（drawings 按 panelPosition 过滤） | □ Pass / □ Fail |

> grep 反向断言用 `grep -F` 字面 + 显式 `if`/退出码判定（不用裸 `! grep`，防 `set -e` 死闸门，per `feedback_acceptance_grep_anchoring`）。

---

## 二、自动化测试验收（命令输出为证据）

| Step | Action（在 `ios/Contracts/` 目录跑） | Expected（二元） | Pass / Fail |
|---|---|---|---|
| T1 | `swift test 2>&1 \| tail -1` | 末行含 `... tests in ... suites passed`（**0 failures**）；总数 = 当前 origin/main 基线 + 本 PR 净增 **18** 测试（总数随并行 anchor merge 增长，故判据锚定「0 failures + 新增 18 存在」而非固定总数） | □ Pass / □ Fail |
| T2 | `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 \| tail -3` | 含 `** TEST BUILD SUCCEEDED **` | □ Pass / □ Fail |

**本 PR 净增 18 测试**：HorizontalLineTool 6 / DefaultDrawingInputController 4 / engine commit-cancel 5 / panelPosition 过滤 2〔上栏+下栏〕/ drawing E2E save-resume 1。
**已采集证据（实测，rebase 至 origin/main `d61cbe1`〔含顺位 5 #101 + 顺位 7 #100 + 顺位 8 #102〕后，2026-06-14）**：`swift test` 全绿 0 failures；`xcodebuild ... Mac Catalyst` → `** TEST BUILD SUCCEEDED **`。
- T2：`** TEST BUILD SUCCEEDED **`（Mac Catalyst，Swift 6，arm64-apple-ios17.0-macabi）

---

## 三、运行时 runbook 条目：水平线绘制 + 跨缩放/平移还原（outline §三.3 要求）

> 运行时行为（手势/绘制/视觉）Catalyst build-for-testing **不执行**——须 device/simulator 手动跑。本节是顺位 4 交付的 runbook **条目**（步骤定义）；其 device/sim 实测**完成**是顺位 13 收尾的阻塞依赖（运行时实测为 user device 职责）。

| Step | Action（device/sim，Normal 训练局） | Expected（可观测，二元判定） | Pass / Fail |
|---|---|---|---|
| R1 | 进入一个 **Normal** 训练局，看顶栏 | 顶栏出现"水平线"按钮（在"返回"右侧） | □ Pass / □ Fail |
| R2 | 进入一个 **Review**（历史复盘）局，看顶栏 | 顶栏**无**"水平线"按钮（绘线按钮经 canBuySell 门，Review 隐藏） | □ Pass / □ Fail |
| R3 | （Normal 局）点"水平线"按钮 | 按钮文案变为"结束画线"（橙色 tint）；此时单指左右拖动图表**不**再平移 K 线（被绘线截获） | □ Pass / □ Fail |
| R4 | 单指点击主图某一价位 | 该价位出现一条横线；按钮文案自动复位为"水平线"（提交后自动退出绘线模式） | □ Pass / □ Fail |
| R5 | 两指 pinch 缩放图表 | 横线**仍钉在原价位**（不随缩放偏移；price 周期无关） | □ Pass / □ Fail |
| R6 | 单指左右平移图表 | 横线仍在原价位（平移不改价位映射） | □ Pass / □ Fail |
| R7 | 两指上下滑动切换周期 | 横线仍在原价位（跨周期还原） | □ Pass / □ Fail |
| R8 | 观察主图与下方量/MACD 副图 | 横线只出现在主图（上栏），**不**出现在量/MACD 副图（panelPosition 过滤） | □ Pass / □ Fail |
| R9 | 点"返回"存档退出 → 从首页重新进入该局（继续训练） | 之前画的横线**还原**显示在原价位（经 saveProgress→resume 持久化往返） | □ Pass / □ Fail |
| R10 | （Normal 局）点"水平线"进入绘线模式后，再点一次"结束画线"（不落锚） | 退出绘线模式（按钮复位"水平线"），无新横线产生（cancelDrawing 路径） | □ Pass / □ Fail |

**证据采集**：R1-R10 由 user 在真机/模拟器自跑，关键步骤（R4 落线、R5 缩放维持、R9 还原）截图，附 PR 评论。

---

## 四、merge 后

- memory 落地：写 `project_pr<N>_wave3_pr4_drawing_mvp_merged.md` + 更新 `MEMORY.md` index。
- residual（spec §八）：6 种其余画线工具 / hit-test 选中删除 / 下栏画线 / review 瞬态绘线 → Phase 4 或后续；周期 autosave 触发画线 commit → 顺位 10b。
- 运行时矩阵 R1-R10 的 device/sim 实测结果 → 顺位 13 收尾阻塞依赖回填。
