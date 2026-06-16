# Wave 3 13c-R1 验收清单（os_signpost 帧相关 instrumentation）

**日期**：2026-06-16
**性质**：非编码者可执行；action / expected / pass-fail 三列。host/CI 可验项 + device-only 标注项。
**Spec**：`docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md`（opus 4.8 对抗性 review R1→R2→R3 APPROVE）

> **13c-R1 facet 边界**：本 PR 交付**机制 facet**（os_signpost 帧相关测量）；**device facet**（最坏帧 <4ms 实测）仍 OPEN，归 runtime-matrix ③。本清单不 claim 帧预算达标。

## host / CI 可验项

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift` | 文件存在 | ☐ Pass / ☐ Fail |
| 2 | `grep -c "make-upper\|make-lower\|make-crosshair-upper\|make-crosshair-lower\|draw-upper\|draw-lower" ios/Contracts/Sources/KlineTrainerContracts/Render/RenderSignposter.swift` | ≥ 6（6 个 per-panel×op 区间名） | ☐ Pass / ☐ Fail |
| 3 | `grep -c "RenderSignposter.begin" ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift; grep -c "RenderSignposter.begin" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift`（`grep -c` 按文件分别计数，故分两条） | ChartContainerView 输出 `2`（beginMake + beginMakeCrosshair）、KLineView 输出 `1`（beginDraw）= 合计 3 调用点接线 | ☐ Pass / ☐ Fail |
| 4 | `grep -c "var panel: PanelId" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift` | 1（KLineView.panel 归属属性） | ☐ Pass / ☐ Fail |
| 5 | `cd ios/Contracts && swift test 2>&1 \| tail -1` | `Test run with 1067 tests ... passed`（0 failures；含命名契约 + smoke） | ☐ Pass / ☐ Fail |
| 6 | Mac Catalyst（同 CI `.github/workflows/catalyst-build.yml`）：`cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived 2>&1 \| tail -1` | `** TEST BUILD SUCCEEDED **` | ☐ Pass / ☐ Fail |
| 7 | `grep -c "最坏完整帧\|os_signpost" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` | ≥ 2（runbook 已改帧归并法） | ☐ Pass / ☐ Fail |
| 8 | `grep -n "13c-R1" docs/acceptance/2026-06-14-wave3-pr13c-completion.md` | 每命中行均含 `accept residual`、均不含 `RESOLVED`（保全 #112 item-7 grep 不变量） | ☐ Pass / ☐ Fail |
| 9 | `bash scripts/governance/verify-wave3-completion.sh` | `[verify-wave3-completion] PASS…`（gate 未被账本 flip 破坏） | ☐ Pass / ☐ Fail |
| 10 | `git diff --stat origin/main -- ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift` | 空（RenderStateBuilder 数学零改，行为中性） | ☐ Pass / ☐ Fail |

## device-only 项（runtime-matrix ③ 回填时核，非 host 可验）

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| D1 | 真机 Release Profile，os_signpost instrument 按 `com.klinetrainer.render` 过滤 | 见 6 个具名 lane（make-upper/lower、draw-upper/lower、make-crosshair-upper/lower） | ☐ Pass / ☐ Fail（device pending） |
| D2 | 按 runbook「最坏完整帧判读法」取各场景最坏帧合并 ms | 全场景 < 4ms（或触发 Bitmap Cache 决议门） | ☐ Pass / ☐ Fail（device pending，runtime-matrix ③） |

## supersedes-note

#112 `docs/acceptance/2026-06-15-wave3-13c-r2-perf-fixture.md` item 7（断言 `grep 13c-R1 pr13c-completion.md` 均 accept residual / 无 RESOLVED）是 point-in-time 记录。本 PR 经 Task 4 Step 3 策略（13c-R1 行只追加含 `accept residual`、不含 `RESOLVED` 的前向指针子句）使该 item-7 grep 不变量**逐字仍 PASS**——故**不回改** #112 历史清单。

实现说明：实现用嵌套 RenderSignposter.Token（≡ spec §D6 命名 RenderSignpost，等价；code-quality reviewer 认为嵌套更清晰，accept）
