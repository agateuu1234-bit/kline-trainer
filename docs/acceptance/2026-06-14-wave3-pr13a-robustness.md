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
| 10 | 看 `DownloadBatchFeedbackTests.swift` | 含 4 测试：全成功无 toast / 部分失败列 distinct 原因 / 去重 / 超 max 截断（等） | □ Pass / □ Fail |
| 11 | 看 `SettingsPanel.swift` diff | 保留 `downloadStatus` 进度标签（"下载中…"/"完成：…"/"下载失败：…"）；新增失败原因 toast（`DownloadBatchFeedback` + `.toastOverlay`） | □ Pass / □ Fail |
| 12 | 看 CI 「Mac Catalyst build-for-testing on macos-15」 | 绿（TEST BUILD SUCCEEDED） | □ Pass / □ Fail |
| 13 | 看 CI 「swift test on macos-15」 | 绿（全量 988 tests in 141 suites pass，新增 16 测试无失败） | □ Pass / □ Fail |
| 14 | 看 codex 对抗 review verdict | APPROVE（或 codex 配额耗尽→opus 4.8 xhigh fallback APPROVE） | □ Pass / □ Fail |

## 范围守卫（blocking 错误不被改造）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 15 | 看 `TrainingView.swift` finalize/back 失败处理 | 仍为 blocking alert（`finalizeFailed`/`backFailed`，retry/放弃），**未**被改成 toast | □ Pass / □ Fail |
| 16 | 看 `AppRouter.errorMessage` / app.sqlite fail-closed（§P6） | 未被本 PR 触碰（保留 blocking alert + §4.7f 安全红线） | □ Pass / □ Fail |
| 17 | 看 `lastAutosaveError`（10b 内部机制字段） | 仍 `@ObservationIgnored` + 语义不变（新 `autosaveBannerError` 与之解耦并行，不破 autosave coalescing/fence） | □ Pass / □ Fail |
