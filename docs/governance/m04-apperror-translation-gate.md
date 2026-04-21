# M0.4 AppError Trust-Boundary Translation Gate

> **Source**: 本文档由 Plan 1d hotfix（2026-04-22）落地；对应 session-local memory `project_m04_translation_gate.md` 已指向此文件作为权威副本。Plan 2/3 消费 AppError 的 Swift 模块 PR 必须引用本文件两条 gate。

## 背景

Plan 1d（M0.4 AppError 契约冻结）scope 仅冻结 `AppError` + 4 Reason 类型层 + 3 UI extension computed vars。spec M0.4 的"翻译规则表"（P1 APIClient / P3 TrainingSetDB / P4 AppDB / E3 TradeCalculator / P2 DownloadAcceptance / UI 各模块如何把本模块私有错误转 AppError）属模块实现约束，归 Plan 2/3 落地。

Codex 对 Plan 1d 的 plan R1 + post-merge attest 均指出：若单拆 Plan 1d 不含翻译规则强制手段，Plan 2/3 模块可能悄悄跨模块传递私有错误（`DatabaseError` / `URLError` / `APIError` 等），违反 M0.4 "私有错误在本模块边界内转 AppError" 原则。

本文件把两条强制 gate 固化到 repo 内，Plan 2/3 每个消费 AppError 的模块 PR 前置 prereq。

## Gate 1：public API 只抛 AppError

每个模块的 test suite 必须含类似 `testApiMethodsThrowAppErrorOnly()` 的断言。示例（P1 APIClient）：

```swift
@Test func api_public_methods_throw_only_AppError() async {
    do {
        _ = try await client.fetchMeta(count: 1)
    } catch let e as AppError {
        // 预期路径
    } catch {
        Issue.record("non-AppError leaked: \(type(of: error))")
    }
    // 对每个 public async throws 方法重复
}
```

**覆盖范围**：模块 `Sources/` 下所有 `public func ... async throws` / `public func ... throws` 方法。

## Gate 2：acceptance 脚本 grep 排查内部错误类型泄露

每个模块的 acceptance 脚本（`scripts/acceptance/plan_N_<module>.sh`）必须含一步：

```bash
# 排查内部错误类型是否泄露到 public API 作用域
# 允许在 private / fileprivate 中使用（内部 mapping）
# 禁止在 public 函数签名 / catch 块返回给调用方
run "grep: no internal-error-types leaked to public API" \
    bash -c '! grep -rE "public[[:space:]]+func[[:space:]]+[^(]+throws[^{]*(DatabaseError|URLError|APIError)" Sources/<ModuleName>/ --include="*.swift"'
```

返回空 = OK；有 match = FAIL（public API 声明里直接用了私有错误类型）。

## 应用范围

| Plan | 模块 | Gate 必需 | 备注 |
|---|---|---|---|
| Plan 2 | B1 import_csv | 否 | 不抛 error 到外；独立脚本 |
| Plan 2 | B2 generate_training_sets | 否 | 同上 |
| Plan 2 | B3 FastAPI routes | N/A | Python，不在 Swift AppError 覆盖范围 |
| Plan 2 | B4 scheduler | N/A | 同 B3 |
| Plan 3 | P1 APIClient | ✅ Gate 1 + Gate 2 | |
| Plan 3 | P2 DownloadAcceptance | ✅ Gate 1 + Gate 2 | |
| Plan 3 | P3a TrainingSetDBFactory / P3b TrainingSetReader | ✅ Gate 1 + Gate 2 | |
| Plan 3 | P4 RecordRepo / PendingRepo / SettingsDAO / AcceptanceJournalDAO | ✅ Gate 1 + Gate 2 | |
| Plan 3 | P5 CacheManager | ✅ Gate 1 + Gate 2 | |
| Plan 3 | P6 SettingsStore | ✅ Gate 1 + Gate 2 | |
| Plan 3 | E3 TradeCalculator | 否 | 返 `Result<Quote, TradeReason>`，不 throws；调用方 `mapError` 提升 |

## 使用方式

写 Plan 2/3 涉及模块 PR 时：

1. 在 plan 的 §"依赖（hard prereq）" 加一行：`per docs/governance/m04-apperror-translation-gate.md，本模块消费 AppError 故 Gate 1 + Gate 2 强制`
2. 在模块 test 文件加对应测试（Gate 1）
3. 在 acceptance 脚本加 grep 项（Gate 2，替换 `<ModuleName>` 为实际模块）
4. 非 coder 验收清单里登记 "AppError trust-boundary（Gate 1 test + Gate 2 grep）" 一项

**若发现要传递私有错误类型**：在模块内部（`private` / `fileprivate`）做 mapping，边界外只抛 `AppError`。违反 Gate = PR blocker。
