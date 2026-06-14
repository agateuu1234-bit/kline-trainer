# PR Wave 3 13a 验收清单（中文非-coder 可执行）

**PR 范围**：§A cache touch-on-use（E6a-R3）+ §B 边界错误统一 Toast 层（autosave 失败可见 + 下载 per-item 失败可见）。改 `ios/**/*.swift`（trust-boundary → codex review）+ 新增 host 测；0 schema/DDL/CI 改动。

**source-of-truth**：spec `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §A/§B；plan `docs/superpowers/plans/2026-06-14-wave3-pr13a-robustness.md`。

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 6 个 `.swift` 改/增（TrainingSessionCoordinator / TrainingView / SettingsPanel / InMemoryFakes + 新 ToastState / ToastOverlay / DownloadBatchFeedback）+ 4 个测试文件 + 本 acceptance | □ Pass / □ Fail |
| 2 | 看 `TrainingSessionCoordinator.swift` diff | 4 处 read 路径（startNewNormalSession/resumePending/review/replay）成功打开后均新增 `cache.touch(file)` | □ Pass / □ Fail |
| 3 | 看 `CacheTouchOnUseTests.swift` | 含 5 测试：4 read 路径 touch（resume/review/replay 用 count-delta 非 vacuous）+ 损坏文件不 touch（被删） | □ Pass / □ Fail |
| 4 | 看 `ToastState.swift` | 纯值 struct（仅 import Foundation），`present` 返单调 token、`expire(token:)` 仅清最新 token（latest-wins） | □ Pass / □ Fail |
| 5 | 看 `ToastStateTests.swift` | 含 3 测试：present 设值 / 旧 token 过期不清当前 / 当前 token 过期清空 | □ Pass / □ Fail |
| 6 | 看 `ToastOverlay.swift` | content-agnostic SwiftUI modifier，**无** `#if canImport(UIKit)` 闸门（host + Catalyst 双可编译） | □ Pass / □ Fail |
| 7 | 看 `TrainingSessionCoordinator.swift` 的 `autosaveBannerError` | observable（无 `@ObservationIgnored`）；autosave catch 置位、endSession/resetAutosaveState 清零 | □ Pass / □ Fail |
| 8 | 看 `AutosaveBannerTests.swift` | 含 4 测试：失败置位+不 teardown / 成功保持 nil / endSession 清零 / end→新 session 整链无 stale | □ Pass / □ Fail |
| 9 | 看 `TrainingView.swift` diff | toast 迁移到 `toast = ToastState()` + `.toastOverlay(toast.message)`；新增 `.onChange(of: lifecycle.coordinator.autosaveBannerError)` 弹 toast（guard shouldShowToast） | □ Pass / □ Fail |
| 10 | 看 `DownloadBatchFeedbackTests.swift` | 含 4 测试：全成功无 toast / 部分未完成列 distinct 原因 / 去重 / 超 max 截断（等） | □ Pass / □ Fail |
| 11 | 看 `SettingsPanel.swift` diff | `downloadStatus` 用 `feedback.statusSummary`（"完成：N 成功[，M 未完成]"，中性「未完成」不误称待确认为失败）；新增未完成原因 toast（`DownloadBatchFeedback` + `.toastOverlay`）；P2 `DownloadAcceptanceRunner`/`AcceptanceResult` **未改**（保持冻结基线） | □ Pass / □ Fail |
| 12 | 看 CI 「Mac Catalyst build-for-testing on macos-15」 | 绿（TEST BUILD SUCCEEDED） | □ Pass / □ Fail |
| 13 | 看 CI 「swift test on macos-15」 | 绿（全量 988 tests in 141 suites pass，新增 16 测试无失败） | □ Pass / □ Fail |
| 14 | 看 codex 对抗 review verdict | APPROVE（或 codex 配额耗尽→opus 4.8 xhigh fallback APPROVE） | □ Pass / □ Fail |

## 范围守卫（blocking 错误不被改造）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 15 | 看 `TrainingView.swift` finalize/back 失败处理 | 仍为 blocking alert（`finalizeFailed`/`backFailed`，retry/放弃），**未**被改成 toast | □ Pass / □ Fail |
| 16 | 看 `AppRouter.errorMessage` / app.sqlite fail-closed（§P6） | 未被本 PR 触碰（保留 blocking alert + §4.7f 安全红线） | □ Pass / □ Fail |
| 17 | 看 `lastAutosaveError`（10b 内部机制字段） | 仍 `@ObservationIgnored` + 语义不变（新 `autosaveBannerError` 与之解耦并行，不破 autosave coalescing/fence） | □ Pass / □ Fail |

## Residual（codex review 暴露、明确 OUT of 13a scope，记待独立处理）

| Residual | 来源 | 处理 |
|---|---|---|
| **13a-R1：精确 confirm-state 下载反馈**——`AcceptanceResult` 仅 `.confirmed`/`.rejected`（P2 plan 决策5：网络不确定 confirm = 文件已缓存待重试，但归 `.rejected`）；反馈层无 journal 访问无法区分「终态失败」vs「已缓存待确认」→ 本 PR 用中性「未完成」如实表述（不误称失败）。精确三态（成功/待确认/失败）+ 模糊 confirm 的幂等安全策略（confirm side-effecting，服务端可能已提交，删文件不安全）需重做 P2 confirm 状态机 | codex 13a review R3-R6（confirm-state-machine reliability drilldown；R4↔R5 自相矛盾）| **OUT of 13a scope**（13a=touch + 边界 toast）→ 独立 **P2-confirm-reliability RFC**（含 §下条 cross-lease cache 所有权） |
| **13a-R2：`retryPendingConfirmations` 跨 lease cache 误删**——journal 按 `(trainingSetId, leaseId)` 作用域，但 reject 清理仅按 `trainingSetId` 选 cache 项 → 旧 lease 行 409 重试会删掉**新** lease 重下的 cache 项 | codex 13a review R6（**pre-existing 基线 bug，13a 未触碰该代码**）| **OUT of 13a scope**（基线既有，非本 PR 引入）→ 并入上条 P2-confirm RFC |
