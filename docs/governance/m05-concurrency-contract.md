# M0.5 Concurrency Contract（contract，frozen by Plan M0.5）

> **Status**：frozen 2026-05-16（Plan M0.5 PR）。
>
> **权威来源**（spec `kline_trainer_modules_v1.4.md`）：
> - 主体条款 §M0.5：L655-702（v1.2 GRDB 修正 + v1.3 Sendable 清单 + v1.3 跨 actor 捕获禁止）
> - Sendable 约定（§三 M0.3 内）：L397
> - @MainActor 实例落点：L820 (F2 ThemeController) / L1315 (C6 DrawingToolManager) / L1571 (E5 TrainingEngine) / L1625 (E6 TrainingSessionCoordinator，v1.3 新增) / L1973 (P6 SettingsStore)
> - @MainActor 合并清单（spec 自带）：L2187（"E5/E6/P6/F2/C6 DrawingToolManager"）
> - 跨 actor 协议返回值 Sendable 实例：L1893 (AcceptanceJournalDAO)
> - 未知 state fail-safe 忽略策略：L289-293（与 m01 doc 共享，本 doc 仅反向引用）
> - Wave 0 交付项：L2101
> - 风险登记：L2260 (R21 @MainActor 漏标) / L2272 (R33 GRDB Queue/Pool 矛盾)
> - 历史决议：L2356 (R1-Codex P1-7) / L2378 (R2-Codex P1-6) / L2403 (R3-补齐 Sendable)
> - iOS 代表验收准入：L2513
>
> 任何修改本文档需走 spec 更新 → 本文档同步 → codex:adversarial-review → CODEOWNERS approve（`.claude/workflow-rules.json` `trust_boundary_globs` + `codeowners_required_globs`）。

## 用途

本文件是 M0.5 并发规则在 repo 内的**权威落地锚点**。

- spec `kline_trainer_modules_v1.4.md` §M0.5 + 散落于 §三 M0.3 / §六 C1 族 / §八 iOS 服务模块 的 concurrency 规则为规范文本来源
- 本文件是 Plan 3 所有 iOS 模块 PR（E5/E6/F2/C6 + P1/P2/P3a/P3b/P4/P5/P6 + C1c）的强制引用对象
- 任何涉及 `@MainActor` / `actor` / `Sendable` / GRDB `DatabaseQueue` 用法 / 文件系统原子写 / 跨 actor 捕获的 PR 必须在描述里点名引用本文件相应章节
- 与 `docs/governance/m01-schema-versioning-contract.md` / `m04-apperror-translation-gate.md` 形成 governance doc 三件套：m01 管 schema 版本边界，m04 管错误传播边界，m05 管线程并发边界

## @MainActor 必须清单

以下 5 个引用类型**必须**标 `@MainActor`（spec 多处明示，已合并 PR #39/#40/#42/#44/#51 中均符合此约束）：

| 模块 | 类型 | spec 行 | 已落地 PR |
|---|---|---|---|
| E5 | `TrainingEngine` (`@MainActor @Observable final class`) | L1571 | 待 Wave 1 真模块；契约 stub 见 PR #40 |
| E6 | `TrainingSessionCoordinator` (`@MainActor @Observable final class`，v1.3 新增) | L1625 | PR #40 契约落地 |
| F2 | `ThemeController` (`@MainActor @Observable final class`) | L820 | PR #39 |
| P6 | `SettingsStore` (`@MainActor @Observable final class`) | L1973 | PR #44 |
| C6 | `DrawingToolManager` (`@MainActor @Observable final class`) | L1315 | 待 Wave 1 真模块；C1c stub 见 PR #51 |

**SwiftUI / UIKit 默认 `@MainActor`**（spec L668 + UIKit overlay 内建）：
- 所有 `SwiftUI.View` 默认 `@MainActor`（Swift 5.5+ 内建）
- 所有 `UIViewRepresentable` 默认 `@MainActor`
- 所有 `UIGestureRecognizerDelegate` 实现默认 `@MainActor`
- `UIView` 子类通过 **UIKit overlay 继承 `@MainActor`**（iOS 13+ / Swift 5.5+）—— C1c `public final class KLineView: UIView`（PR #51 已落地，`ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:15`）由此规则覆盖，无需显式标 `@MainActor`

## actor 与后台执行

**仅一个 actor**（spec L671）：

- `actor NetworkExecutor { ... }`：P1 APIClient 内部专用，承担 URLSession 异步调用 + 重试 / 退避调度

**P3 / P4 不使用 actor**（spec L672）：
- GRDB `DatabaseQueue` 内建串行化锁，actor 包装会形成嵌套 lock，违反 v1.2 §M0.5 修正方向
- P3 TrainingSetDB / P4 AppDB 直接以 `DatabaseQueue` 作内部同步原语

**禁止再引入新 actor**：任何新增 `actor X { ... }` 的 PR 必须在描述里点明理由 + 引用本文件 + codex:adversarial-review 单独评审。

## 返回主线程的合法写法

跨 actor 边界异步返回后写 `@Observable` 字段，**唯一合法形态**（spec L675-678）：

```swift
let result = try await backgroundTask()
await MainActor.run {
    engine.update(result)   // 唯一合法的写 @Observable 方式
}
```

非法替代（属 §禁止清单 第 1 条）：
- 后台线程 / actor 上下文直接 `engine.update(...)`
- 通过 `DispatchQueue.main.async` 写 `@Observable` 字段（旧 UIKit 风格，不与 Swift Concurrency 契约对齐）

## Sendable 清单

spec L397 + L697-701 + L1893：

### 1. M0.3 全部值类型 `Sendable`

所有 `struct` / `enum`（spec L401-628）默认 `Sendable`：
- 枚举：`Period` / `TradeDirection` / `PositionTier` / `TrainingMode` / `DrawingToolType` / `DisplayMode` / `PanelId` / `SwipeDirection` / `PeriodDirection`
- DTO：`KLineCandle` / `TrainingSetMeta` / `FeeSnapshot` / `TradeOperation` / `DrawingAnchor` / `DrawingObject` / `TradeMarker` / `TrainingRecord` / `DrawdownAccumulator` / `PendingTraining` / `LeaseResponse` / `TrainingSetMetaItem` / `TrainingSetFile` / `AppSettings`
- C1a 几何：`ChartGeometry` / `ChartPanelFrames` / `PriceRange` / `ChartViewport` / `CoordinateMapper` / `IndicatorMapper` / `NonDegenerateRange`
- C1b reducer 输入/输出：`PanelViewState` / `FrozenPanelState` / `DrawingSnapshot` / `ChartInteractionMode` / `ChartAction` / `ChartReduceEffect`
- C1c 渲染：`KLineRenderState`

### 2. `AppError` + 全部 `Reason` `Sendable`

spec L594-628（M0.4 落地于 PR #26）：

- `AppError: Error, Equatable, Sendable`
- `NetworkReason: Error, Equatable, Sendable`
- `PersistenceReason: Error, Equatable, Sendable`
- `TradeReason: Error, Equatable, Sendable`
- `TrainingSetReason: Error, Equatable, Sendable`

### 3. 跨 actor 协议返回值必须 `Sendable`

以下 6 类协议的返回值跨 actor 传递，**必须** `Sendable`（spec L700）：

| 协议 | 模块 | spec 行 |
|---|---|---|
| `APIClient` | P1 | §八 P1 |
| `TrainingSetReader` (`AnyObject + Sendable`) | P3b | L1843 |
| `RecordRepository` | P4 | L1870 |
| `PendingTrainingRepository` | P4 | L1879 |
| `SettingsDAO` | P4 | L1885 |
| `AcceptanceJournalDAO` | P4 | L1893 |
| P2 4 内部端口（`ZipIntegrityVerifying` / `ZipExtracting` / `TrainingSetDataVerifying` / `DownloadAcceptanceCleaning`）返回类型 | P2 | L1751-1786 |

### 4. `@Observable final class` 非 Sendable

spec L701：`@Observable final class` 默认**非** `Sendable`。**必须在 `@MainActor` 上下文内使用**——即 §@MainActor 必须清单 5 类（E5/E6/F2/P6/C6）已通过 `@MainActor` 隔离满足这一约束。

## GRDB DatabaseQueue 约定

spec L681-685（v1.2 修正）：

**v1 全部使用 `DatabaseQueue`**。v1.1 P4 描述中"读操作可并发（GRDB pool）"的表述与 §M0.5 矛盾，v1.2 已统一删除。

| 模块 | DatabaseQueue 形态 | 备注 |
|---|---|---|
| P3 TrainingSetDB | 每个训练组 `.zip` 对应**一个独立** `DatabaseQueue`（只读，进程内串行） | 不同训练组并行；同一训练组所有读串行 |
| P4 AppDB | **单一** `DatabaseQueue` for `app.sqlite`（读写均串行化） | GRDB 内置 |

**追求读并发是过早优化**（spec L685）：v1 场景（单用户 + 本地小库）`DatabaseQueue` 足够。任何 PR 提"换 DatabaseQueuePool"的需求必须先经独立 spec 升级 PR。

## 文件系统原子写

spec L687：

- **P5 `CacheManager.store()`**：采用**临时文件 + rename** 原子化（POSIX `rename(2)` 跨 inode 同卷原子保证）
- 非法形态：直接 open + write 目标路径；崩溃恢复时可能留半文件

PR #44 P5 生产实现已遵守。

## 禁止清单

spec L689-695：以下 6 条**禁止**形态，任何 PR 出现需 codex:adversarial-review 拦截：

1. ❌ **后台线程直接修改 `@Observable` 字段**（破坏 §返回主线程合法写法）
2. ❌ **多个 `Task` 并发写同一 SQLite 文件**（破坏 §GRDB 约定单 `DatabaseQueue`）
3. ❌ **并发多次 `CacheManager.store()` 写同一目标路径**（破坏 §文件系统原子写）
4. ❌ **`CADisplayLink` 回调中执行重量级计算**（C1c render 路径强约束）
5. ❌ **跨模块传递私有错误类型**（v1.2 新增；由 `docs/governance/m04-apperror-translation-gate.md` 主管，本条仅反向引用）
6. ❌ **跨 actor 捕获非 Sendable 引用类型**（v1.3 新增）：闭包中若需捕获 `@MainActor` 引用，闭包本身必须标 `@MainActor` 或通过 `MainActor.assumeIsolated` 安全进入（见下章）

## 跨 actor 捕获 + `MainActor.assumeIsolated`

spec L695：

跨 actor 边界的闭包要捕获 `@MainActor` 隔离的引用类型时，**只有两条合法路径**：

### A. 闭包本身标 `@MainActor`

```swift
let onCommit: @MainActor () -> Void = { coordinator.commit() }
```

### B. 通过 `MainActor.assumeIsolated` 安全进入

```swift
// 仅在已知调用栈处于 main 线程但 Swift 编译器无法静态证明时使用
MainActor.assumeIsolated {
    coordinator.commit()
}
```

**`assumeIsolated` 前置条件**（合规使用 checklist）：
- 调用点 runtime 必在 main thread（否则 Swift 6 会 trap）
- 上层调用者契约文档化说明（spec / 本 doc / 代码 inline 注释三选一）

**非法形态**：
- 直接在 `actor` / `Task.detached` 闭包中读写 `@MainActor` 引用而不通过上述两条路径

## 应用范围

哪个模块 PR **必须**在描述里引用本文件：

| Plan | 模块 | 引用本文件 | 引用章节 |
|---|---|---|---|
| Plan 2 | B1 / B2 / B3 / B4 | 否 | Python 后端，不在 Swift 并发模型内 |
| Plan 3 | **F1 Models** | ✅ **强制**（Sendable conformance owner） | §Sendable 清单 #1（M0.3 全部值类型 `Sendable`）—— F1 是 M0.3 值类型的实施者，**新增 / 修改 Sendable conformance 必须引用本 doc**（codex R3 finding） |
| Plan 3 | F2 ThemeController | ✅ **强制** | §@MainActor 必须清单 |
| Plan 3 | **P1 APIClient** | ✅ **强制** | §actor 与后台执行（唯一 actor）+ §Sendable 跨 actor 返回值 |
| Plan 3 | P2 DownloadAcceptanceRunner | ✅ **强制** | §Sendable 跨 actor（4 内部端口返回类型）+ §禁止清单（不并发写 SQLite） |
| Plan 3 | P3a TrainingSetDBFactory | ✅ **强制** | §GRDB 约定（每 zip 独立 DatabaseQueue） |
| Plan 3 | P3b TrainingSetReader | ✅ **强制** | §Sendable 跨 actor + `AnyObject + Sendable` 约束 |
| Plan 3 | **P4 AppDB**（含 4 协议） | ✅ **强制** | §GRDB 约定（单一 DatabaseQueue）+ §Sendable 跨 actor（4 协议返回值） |
| Plan 3 | P5 CacheManager | ✅ **强制** | §文件系统原子写 + §禁止清单（不并发 store 同路径） |
| Plan 3 | P6 SettingsStore | ✅ **强制** | §@MainActor 必须清单 |
| Plan 3 | E1 TickEngine | 否 | 纯值类型 + sync 函数，PR #37 已落地无并发暴露 |
| Plan 3 | E5 TrainingEngine | ✅ **强制** | §@MainActor 必须清单 + §返回主线程合法写法 |
| Plan 3 | E6 TrainingSessionCoordinator | ✅ **强制** | §@MainActor 必须清单 + §返回主线程合法写法 |
| Plan 3 | C1a Geometry | 否 | 纯值类型，PR #38 已落地，由 §Sendable 清单覆盖 |
| Plan 3 | C1b Reducer | 否 | sync reducer，PR #47-#50 已落地，由 §Sendable 清单覆盖 |
| Plan 3 | C1c Render (`KLineView`) | ✅ **强制** | §@MainActor (UIView 子类 UIKit overlay 默认 `@MainActor`) + §禁止清单 #4 (CADisplayLink) |
| Plan 3 | C3-C6（含 C6 DrawingToolManager） | ✅ **强制**（C6） | §@MainActor 必须清单 |

## 未来强制点（Plan M0.5 不实施，登记 backlog）

以下增量在本 plan scope **之外**，但作为 spec 长期 governance 目标登记：

- [ ] **CI Threading Sanitizer**（spec L2260 R21）：iOS Simulator CI job 启用 Thread Sanitizer 跑契约 / 集成测试，自动捕获 `@MainActor` 漏标。**落地时机**：Wave 1 启动 PR；本 backlog 项等 Simulator CI 整体迁移（PR #51 G3 residual 已登记 Catalyst CI build gate）
- [ ] **Swift 6 strict-concurrency 全仓启用**：`SwiftSetting.enableExperimentalFeature("StrictConcurrency")` 切换。**落地时机**：Wave 1；当前各 contract test 已分散满足
- [ ] **跨 actor 协议返回值 Sendable conformance audit script**：grep 本 doc §Sendable 清单 #3 表格列出的 6 协议，确保各 prod 实现文件含 `Sendable` 标记。**落地时机**：Plan 3 P1/P2/P3a/P3b/P4 真生产代码 PR 后；当前 stub 已分散满足
- [ ] **`assumeIsolated` 调用点 lint**：grep 仓内 `assumeIsolated` 调用，要求 inline 注释指明 main-thread 调用栈保证。**落地时机**：当首次 prod 代码引入 `assumeIsolated` 时

## 交叉引用

- **spec 源**：`kline_trainer_modules_v1.4.md` §M0.5（L655-702）+ §三 M0.3 L397 + §五 F2 L820 + §六 C1c-C6 L1315 + §八 E5/E6/P2/P4/P6 L1571/L1625/L1751-1786/L1893/L1973 + §十 Wave 0 L2101 + §十二 R21/R33 L2260/L2272 + §十三 R1-R3 L2356/L2378/L2403
- **姊妹 governance doc**：
  - `docs/governance/m01-schema-versioning-contract.md`（M0.1 schema 版本，frozen by Plan 1f）—— 共享未知 state fail-safe 忽略策略
  - `docs/governance/m04-apperror-translation-gate.md`（M0.4 错误翻译，stub 待 Plan 3 P1 闭合）—— 共享禁止清单 #5（跨模块传递私有错误类型）
- **Plan 1e aborted 教训**：见 memory `project_plan1e_aborted.md`；本 plan 已修正路线（多源 grep 重构而非 L655-702 verbatim freeze）
- **Wave 0 已落地实例**：PR #37/#38/#39/#40/#41/#42/#43/#44/#45/#46/#47/#48/#49/#50/#51 — 各业务模块已通过 contract test 验证 Sendable / @MainActor / GRDB conformance；本 doc 是反向锚不重复验证
- **治理 PR 工作流**：`.claude/workflow-rules.json`（`trust_boundary_globs` + `codeowners_required_globs`）+ `CLAUDE.md` 治理 backstop §1（codex:adversarial-review 强制）
