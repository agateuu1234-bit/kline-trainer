# PR 8 验收清单 — C1c Render + C3-C6 Stubs

> 这份清单给非-coder 用户用：复制每一行"action"到 Claude Code 或 Terminal，对照"expected"判断 pass / fail。

## A. 文件落地

| # | action | expected | pass_fail |
|---|---|---|---|
| A1 | `ls ios/Contracts/Sources/KlineTrainerContracts/Render/` | 看到 8 个文件：KLineRenderState.swift / KLineView.swift / KLineView+Candles.swift / +Volume.swift / +MACD.swift / +Markers.swift / +Crosshair.swift / +Drawing.swift | ☐ |
| A2 | `ls ios/Contracts/Tests/KlineTrainerContractsTests/Render/` | 看到 2 个测试文件：KLineRenderStateTests.swift / KLineViewCompileTests.swift | ☐ |

## B. 编译验证（§15.1 #3 闸门）

| # | action | expected | pass_fail |
|---|---|---|---|
| B1 | `cd ios/Contracts && swift build` | 输出 `Build complete!`，无 error 无 warning | ☐ |
| B2 | `cd ios/Contracts && if ! ( set -o pipefail; swift test 2>&1 \| tee /tmp/pr8-b2.log ); then echo FAIL; else tail -5 /tmp/pr8-b2.log; fi` | 末尾出现 `Test run with N tests in M suites passed`，**N ≥ 274**（270 baseline + 4 RenderState 可见，macOS host skip UIKit suite）、M ≥ 60；**未** 出现 `FAIL` 字样（codex R5 finding 2：pipefail + tee 避免 tail 吞失败状态） | ☐ |
| B3 | UIKit 编译路径（**§15.1 #3 闸门**）：跑 plan Task 7.2 整段（set -o pipefail + xcodebuild build-for-testing Catalyst + 4 项 grep gate check）；查 `/tmp/pr8-step7.2.log` | 末尾输出 `GATE PASS: §15.1 #3 闸门关闭`；`/tmp/pr8-step7.2.log` 含 `** TEST BUILD SUCCEEDED **`、无 `error:` / `warning:` 行 | ☐ |

## C. Scope 边界（不应做的事）

| # | action | expected | pass_fail |
|---|---|---|---|
| C1 | `grep -rn "fillRect\|setStrokeColor\|moveTo\|addLine" ios/Contracts/Sources/KlineTrainerContracts/Render/` | 输出为空（C3-C6 stubs 不含任何实际绘图调用） | ☐ |
| C2 | 在 `docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md` 搜 "tag" / "sign-off" / "wave0-frozen" 在 Scope 决策表中 | 这些项明确标 ❌ 拆 PR 9，不在本 PR 范围 | ☐ |
| C3 | `git diff main -- ios/KlineTrainer/` | 输出为空（不动 Xcode app 工程） | ☐ |

## D. Cross-platform 守卫

| # | action | expected | pass_fail |
|---|---|---|---|
| D1 | `grep -c "#if canImport(UIKit)" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView*.swift` | 7（KLineView + 6 个 extension 文件） | ☐ |
| D2 | `grep -c "#if canImport(UIKit)" ios/Contracts/Sources/KlineTrainerContracts/Render/KLineRenderState.swift` | 0（纯值类型不守卫） | ☐ |

## E. CI（GitHub Actions）

| # | action | expected | pass_fail |
|---|---|---|---|
| E1 | `gh pr checks <pr_number>` | 6/6 checks SUCCESS（或 OpenAI quota fail 走 admin bypass，按 memory feedback_openai_quota_ci_pattern） | ☐ |

## F. 文档

| # | action | expected | pass_fail |
|---|---|---|---|
| F1 | `ls docs/superpowers/plans/2026-05-16-pr8-c1c-render-c3-c6-stubs.md` | 文件存在 | ☐ |
| F2 | 本验收清单本身 ls 存在 | 文件存在 | ☐ |

## G. 已知 plan-residual（**不阻塞本 PR merge**，PR 9 governance 前需 close）

| # | residual | 阻塞 | 解决路径 |
|---|---|---|---|
| G1 | L1167 Deceleration stop production handler/animator 集成测试 | `wave0-frozen-v1.4` tag | Wave 1 C2 + E5/C8 落地 OR spec 修订移入 Wave 1 |
| G2 | L1240 KLineRenderState Equatable 短路 runtime invariant | none（compile gate 已关闭） | Wave 1 C8 integration PR 时 iOS Simulator CI 跑 `xcodebuild test` |
| G3 | Catalyst CI build gate（codex R7 finding） | `wave0-frozen-v1.4` tag | PR 9 governance 加 `.github/workflows/swift-contracts-smoke.yml` 第二 job 跑 Catalyst build-for-testing |

## 验收规则

- A / B / C / D / F 全项必须 ✓ pass_fail = ☑
- E1 6/6 success（或 quota fail admin bypass）
- G 项不计入本 PR 验收（明文 residual queue）
- 任一 A-F 项 ☒（fail）→ 不合并；回 plan 阶段修
- B1/B2/B3 全过 = §15.1 #3 闸门关闭（PR 9 治理 PR 后续打 tag 用）
