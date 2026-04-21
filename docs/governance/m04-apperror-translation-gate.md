# M0.4 AppError Trust-Boundary Translation Gate

> **Source**: 本文档由 Plan 1d hotfix（2026-04-22）落地；对应 session-local memory `project_m04_translation_gate.md` 已指向此文件作为权威副本。Plan 2/3 消费 AppError 的 Swift 模块 PR 必须引用本文件两条 gate。

## 背景

Plan 1d（M0.4 AppError 契约冻结）scope 仅冻结 `AppError` + 4 Reason 类型层 + 3 UI extension computed vars。spec M0.4 的"翻译规则表"（P1 APIClient / P3 TrainingSetDB / P4 AppDB / E3 TradeCalculator / P2 DownloadAcceptance / UI 各模块如何把本模块私有错误转 AppError）属模块实现约束，归 Plan 2/3 落地。

Codex 对 Plan 1d 的 plan R1 + post-merge attest 均指出：若单拆 Plan 1d 不含翻译规则强制手段，Plan 2/3 模块可能悄悄跨模块传递私有错误（`DatabaseError` / `URLError` / `APIError` 等），违反 M0.4 "私有错误在本模块边界内转 AppError" 原则。

本文件把两条强制 gate 固化到 repo 内，Plan 2/3 每个消费 AppError 的模块 PR 前置 prereq。

## Gate 1：public API 只抛 AppError（权威 runtime 断言）

每个模块必须对每个 public `throws` 方法 × 每个**已文档化的失败模式** 提供 deterministic 失败注入 fixture + 断言只抛 `AppError`。测试 MUST 在期望失败模式下**没有抛错**时 fail——否则是空测（test 成功仅因为依赖默认值/mock 默认成功）。

示例（P1 APIClient · lease-expired 失败模式）：

```swift
@Test func fetchMeta_leaseExpired_throwsAppError() async {
    let client = APIClient(baseURL: fixtureServer.leaseExpiredURL)
    do {
        _ = try await client.fetchMeta(count: 1)
        Issue.record("expected AppError to be thrown, call succeeded")
    } catch let e as AppError {
        #expect(e == .network(.leaseExpired))
    } catch {
        Issue.record("non-AppError leaked: \(type(of: error))")
    }
}
```

**覆盖范围（强制）**：
- **方法维度**：模块 `Sources/<Module>/` 下所有 `public func ... async throws` / `public func ... throws` 方法全覆盖。
- **失败模式维度**：每个方法的每个文档化失败模式（timeout / offline / serverError / leaseExpired / leaseNotFound / ioError / ...）至少 1 个失败注入 fixture。
- **空测禁令**：test 在 "expected error but succeeded" 分支必须 `Issue.record` + fail。
- **catch-all 兜底（per-method 或 per-dependency-boundary）**：**每个 public throwing 方法**（或最小化工作量时：**每个 dependency 边界**——例如一个模块的 `URLSession` 共用 boundary、`GRDB.DatabaseQueue` 共用 boundary 分别 1 条即可）必须含至少 1 条 catch-all 测试，模拟依赖抛出**非建模**的 raw error（例如 `NSError`、未预期的 `URLError.Code`、未预期的 `DatabaseError` subtype），断言 public API **仍**只抛 `AppError`（典型映射：`.internalError`）。此条保证未预期的依赖错误类不会以 raw 形式跨边界泄露。
  - **禁止**：一个模块仅含单条 module-level catch-all（不同 public 方法可能走不同 boundary，单条 catch-all 无法覆盖其它）。

示例（catch-all 兜底）：

```swift
@Test func fetchMeta_unknownDependencyError_wrappedAsInternal() async {
    let client = APIClient(transport: MockTransport.throwing(NSError(domain: "UnexpectedDomain", code: -999)))
    do {
        _ = try await client.fetchMeta(count: 1)
        Issue.record("expected AppError, call succeeded")
    } catch let e as AppError {
        if case .internalError = e { /* ok */ } else {
            Issue.record("unknown dependency should map to .internalError, got \(e)")
        }
    } catch {
        Issue.record("raw non-AppError leaked on unknown-dep path: \(type(of: error))")
    }
}
```

**违反任一维度 = 模块 PR blocker**（acceptance 脚本应 grep 该模块 test 文件对 failure-mode fixture 数量 + catch-all 存在性的证据；具体 grep 形态在 Plan 3 P1 首次消费时定形——见下文 Gate 2 备注）。

## Gate 2：启发式 lint draft（**权威 enforcement 在 Gate 1**；Plan 3 P1 首次消费时具体化）

⚠️ **本节是 draft，不是权威 enforcement**——shell `grep` 无法可靠扫描 Swift 函数体（`throw URLError(.x)`）或 catch 重抛（`catch let e as DatabaseError { throw e }`），而这恰恰是私有错误跨边界的主要路径。本 hotfix 对应的 codex round 2 HIGH finding 已显式指出这一点。

**权威 enforcement = Gate 1**（runtime `@Test` 断言：调用真实 public 方法，断言只抛 `AppError`）。Gate 1 是 runtime 行为检查，可靠。

**Gate 2 的最终形态在 Plan 3 P1 APIClient（首个消费 AppError 的 Swift 模块）落地时选定**，三选一：

1. **SwiftSyntax-based AST 扫描**：新建一个 Swift lint 工具，解析 `Sources/<Module>/` 所有 `public func` 的函数体 + catch 块，断言不出现私有错误类型字面量。需 `swift-syntax` 依赖。
2. **模块粒度的 tested shell guard**：对特定模块的文件结构做手工正则，配 positive/negative fixture（故意种一个 leak，确认 recipe 抓到；删除 fixture，确认通过）。
3. **取消 Gate 2，强化 Gate 1**：要求每个模块对每条 public throws 路径都有 `@Test` 覆盖（Gate 1 的 coverage 扩展）。

**现阶段（Plan 1d hotfix ~ Plan 3 P1 之间）的启发式线索**（仅供 Plan 2/3 模块作者自查，**不是**acceptance 门槛）：

```bash
# 启发式：扫 public .swift 文件中的 throw 字面量 + catch-as 模式
# 已知漏洞：不抓 let err = makeErr(); throw err 等间接抛
# 不能替代 Gate 1 runtime test
grep -rnE 'throw[[:space:]]+(DatabaseError|URLError|APIError)|catch[[:space:]]+let[[:space:]]+[a-zA-Z_]+[[:space:]]+as[[:space:]]+(DatabaseError|URLError|APIError)' Sources/<ModuleName>/ --include='*.swift' || echo 'no naive leaks found'
```

**Plan 3 P1 落地任务**：选定形态 1/2/3 并在 P1 PR 里更新本文档 + 迁移到权威 acceptance 检查。

## 应用范围

| Plan | 模块 | Gate 1 (权威) | Gate 2 (启发式 draft) | 备注 |
|---|---|---|---|---|
| Plan 2 | B1 import_csv | 否 | 否 | 不抛 error 到外；独立脚本 |
| Plan 2 | B2 generate_training_sets | 否 | 否 | 同上 |
| Plan 2 | B3 FastAPI routes | N/A | N/A | Python，不在 Swift AppError 覆盖范围 |
| Plan 2 | B4 scheduler | N/A | N/A | 同 B3 |
| Plan 3 | P1 APIClient | ✅ | 落地定形态 | **P1 PR 选定 Gate 2 最终形态**（SwiftSyntax / tested shell / 取消并扩展 Gate 1）|
| Plan 3 | P2 DownloadAcceptance | ✅ | 按 P1 选型 | |
| Plan 3 | P3a TrainingSetDBFactory / P3b TrainingSetReader | ✅ | 按 P1 选型 | |
| Plan 3 | P4 RecordRepo / PendingRepo / SettingsDAO / AcceptanceJournalDAO | ✅ | 按 P1 选型 | |
| Plan 3 | P5 CacheManager | ✅ | 按 P1 选型 | |
| Plan 3 | P6 SettingsStore | ✅ | 按 P1 选型 | |
| Plan 3 | E3 TradeCalculator | 否 | 否 | 返 `Result<Quote, TradeReason>`，不 throws；调用方 `mapError` 提升 |

## 使用方式

写 Plan 2/3 涉及模块 PR 时：

1. 在 plan 的 §"依赖（hard prereq）" 加一行：`per docs/governance/m04-apperror-translation-gate.md，本模块消费 AppError 故 Gate 1（权威 runtime 断言）强制`
2. 在模块 test 文件加对应测试（Gate 1：调用真实 public 方法，断言只抛 `AppError`）
3. 启发式 lint（Gate 2 draft）：可选运行，**发现 match 必须修**，但无 match 不等于无泄漏
4. 非 coder 验收清单里登记 "AppError trust-boundary Gate 1 test pass" 一项
5. **Gate 1 证据映射表**：模块 PR body 或 plan 的 Gate 1 证据段必须含一张 markdown 表，把每个 public throwing API 映射到：(a) 文档化失败模式 fixture 列表；(b) catch-all fixture（per-method 或共用 dependency boundary）。示例：

   | public API | 失败模式 fixtures | catch-all fixture |
   |---|---|---|
   | `fetchMeta(count:)` | `timeout`, `offline`, `serverError`, `leaseExpired` | `NSError domain=UnexpectedDomain` via `URLSession` boundary |
   | `reserveMeta(...)` | `leaseExpired`, `conflict409` | 复用 `URLSession` boundary catch-all |

**Plan 3 P1 特殊任务**：作为第一个消费 AppError 的 Swift 模块，P1 PR 必须在本文档基础上选定 Gate 2 最终形态（SwiftSyntax lint / tested shell fixture / 取消 Gate 2 + 扩展 Gate 1）并更新应用矩阵。

**若发现要传递私有错误类型**：在模块内部（`private` / `fileprivate`）做 mapping，边界外只抛 `AppError`。违反 Gate = PR blocker。
