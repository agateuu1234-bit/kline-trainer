# U4 SettingsPanel + SettingsStore loadError 两层恢复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 Wave 2 顺位 10：`SettingsStore` 两层 loadError 恢复 API（`retryReload()` 非破坏 + `forceResetAndReload(confirmation:)` 破坏性，严格按顺位 1 RFC §四 + 11 验收场景）+ `AppSettings.default` + `SettingsResetConfirmation` 类型 + `SettingsPanel` SwiftUI 壳（§6.4 五控件，离线缓存薄接线）。

**Architecture:** 沿用既有「纯值 `*Content`（host 全测）+ SwiftUI `*View` 壳（不单测，靠 Catalyst build-for-testing 闸门，D10 先例）」分层。恢复状态机是本锚**真正重测试的交付**——全部逻辑落在 `SettingsStore`（@MainActor @Observable），磁盘 I/O 沿用既有 `update`/`resetCapital` 的 `Task.detached` 纪律，状态变更在 MainActor。`SettingsPanel` 是薄壳：5 控件接线 `settings.update`/`resetCapital`/`retryReload`/`forceResetAndReload` + 离线缓存接 `api.reserveTrainingSets` → `acceptance.runBatch`。

**Tech Stack:** Swift 6 / Swift Testing（`@Test`/`@Suite`/`#expect`）/ SwiftUI / `@Observable` / `@MainActor`。包 `KlineTrainerContracts`，目录 `ios/Contracts`。

**权威契约源：**
- 恢复契约：`docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md` §四（11 场景钉死）
- 镜像在 `kline_trainer_modules_v1.4.md` §P6 L2020 + 签名 L2002-2003
- SettingsPanel 冻结签名：`kline_trainer_modules_v1.4.md` §U4 L2081-2084
- SettingsPanel 五控件：`kline_trainer_plan_v1.5.md` §6.4 L1013-1025
- commission UI 边界换算：`kline_trainer_modules_v1.4.md` L2009/L2013

---

## 关键决策（实施前钉死，供 plan-stage 评审）

- **D1（恢复 API 归属）**：两个新方法加在 `SettingsStore`，**不改** Wave 0 冻结的 `SettingsDAO` 协议（RFC §四明确「恢复是 Store 状态机职责非 DAO 存储职责」；现有 3 方法 `loadSettings`/`saveSettings`/`resetCapital` 足够拼出语义）。
- **D2（`AppSettings.default` 取值）**：`commissionRate: 0.0001`（§6.4 佣金初始值 1 万分之一）、`totalCapital: 100_000`（§6.4 重置资金→10 万）、`displayMode: .system`、`minCommissionEnabled: false`（§6.4 未规定 免5 初始值；取 `false`=免5 开启=无最低限制，对新手最简；与既有 `zeroDefault` 的 bool 一致）。**关键约束**：`commissionRate` 与 `totalCapital` 均 **非 0**——RFC 验收场景 2 要求 `forceReset` 后 `snapshotFeesIfReady()` 返回 **非零** default fee。
- **D3（`SettingsResetConfirmation`）**：`public struct` + **`internal init()`**。public 类型让它能出现在 public `forceResetAndReload(confirmation:)` 签名上；internal init 使**包外模块（如顺位 11 app target）无法构造**，仅 `KlineTrainerContracts` 内（= SettingsPanel 恢复 UX）可构造 → 落实 RFC「deliberate-intent 信号 + UI-owned recovery service 边界」「非抗 determined caller 安全边界」。
- **D4（磁盘 I/O 线程）**：恢复方法内的 `loadSettings`/`saveSettings` 调用全部包 `Task.detached(priority: .userInitiated)`，结果在 MainActor 上赋值——与既有 `update`/`resetCapital`（SettingsStore.swift L59/L75）一致，不阻塞主线程。恢复方法**不参与** `pendingMutations` 链：loadError 态下所有写已被阻塞，无并发写需串行化。
- **D5（`_retryReloadFailed` 可见性）**：`private`（与 `_loadError` 同级私有）。11 场景全部通过**行为**验证（throws / settings / saveCallCount / 公开 `loadError`），无需测试直接读该 flag——场景 4「未先试 retryReload」靠「init 后不调 retryReload，flag 默认 false」自然构造。
- **D6（离线缓存深度，user 2026-06-07 选「薄接线」）**：5 控件全在场。离线缓存按钮 = 数量校验 1~20（纯函数 host 测）+ `api.reserveTrainingSets(count:)` → `acceptance.runBatch(lease:)` + 基础进度/结果展示；取消/重试/逐项错误恢复 UX **不在本锚**。
- **D7（错误类型分类）**：corruption-class **仅** `.persistence(.dbCorrupted)`。`.persistence(.diskFull)`/`.persistence(.ioError)`/`.persistence(.schemaMismatch)` 及其它一律 transient（不允许破坏）——RFC §四 + modules L2020 字面。
- **D8（View 不单测）**：`SettingsPanel.swift`（SwiftUI 壳）不写单测，靠 `Mac Catalyst build-for-testing on macos-15` required check（D10 先例，per `project_pr70_u3_merged`）。纯逻辑全抽到 `SettingsPanelContent`（host 测）。
- **D9（恢复并发为 non-goal；plan-stage review M1）**：`retryReload()`/`forceResetAndReload()` **不**走 `pendingMutations` 串行链，故并发双触发理论上可 clobber 状态。RFC §四 11 场景全是顺序单发，无并发场景；恢复是**手动单发**用户动作。故**不在本锚硬化恢复并发**（YAGNI + 不超 RFC scope）；缓解 = SettingsPanel 壳层操作期 `isRecovering` 禁用按钮（Task 6）。若 Wave 3 需要严格并发安全，另起 residual。

---

## File Structure

**生产代码（`ios/Contracts/Sources/KlineTrainerContracts/`）：**
- Modify `AppState.swift`：追加 `public extension AppSettings { static let default }`（D2）。
- Create `Settings/SettingsResetConfirmation.swift`：`SettingsResetConfirmation`（D3）。
- Modify `Settings/SettingsStore.swift`：加 `_retryReloadFailed` 私有状态 + `retryReload()` + `forceResetAndReload(confirmation:)` + `isDBCorrupted` 私有 helper。
- Create `UI/SettingsPanelContent.swift`：纯值 helper（commission 换算/格式、下载数量校验、displayMode label）。
- Create `UI/SettingsPanel.swift`：SwiftUI 壳（5 控件 + 恢复 UX）+ `#if DEBUG #Preview`。

**测试（`ios/Contracts/Tests/KlineTrainerContractsTests/`）：**
- Create `RecoverySettingsDAO.swift`：可编程 DAO 测试替身（脚本化 load + 写反映 + saveCallCount）。
- Create `SettingsStoreRecoveryTests.swift`：11 RFC 场景 + retryReload 单元。
- Create `UI/SettingsPanelContentTests.swift`：纯 helper host 测。
- Create `AppSettingsDefaultTests.swift`：`AppSettings.default` 值断言。

**验收/治理：**
- Create `docs/acceptance/2026-06-07-pr-u4-settings-panel.md`：非 coder 可执行验收清单（中文）。

---

## Task 0: 评审策略（per outline §五 + RFC §七）

- **plan-stage**：另一 Claude **opus 4.8 xhigh** 对抗性 review 到收敛（user 2026-06-07 explicit 指定 opus 4.8 xhigh 作评审通道，非 codex；满足 `feedback_subagent_quota_fallback_must_ask` 的「先问」——user 已显式选定）。
- **branch-diff（整体）**：实施 + verification + requesting-code-review 后，再跑一次 opus 4.8 xhigh 整体对抗性 review 到收敛。
- 收敛判据：读评审最终 **Verdict 行**（防占位 approve 陷阱，per `project_pr61_c7_merged` 教训）；真 finding 全修；剩余仅 cosmetic/residual 且记录。
- iOS PR：触 `Mac Catalyst build-for-testing on macos-15` required check（有 `.swift` 改动）。本地 swift test 绿 ≠ CI 绿（per `feedback_swift_local_toolchain_blindspot`）。

---

## Task 1: 基础类型 `AppSettings.default` + `SettingsResetConfirmation`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift`（在 `AppSettings` struct 后追加 extension）
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsResetConfirmation.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/AppSettingsDefaultTests.swift`

- [ ] **Step 1: 写失败测试 `AppSettingsDefaultTests.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/AppSettingsDefaultTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("AppSettings.default")
struct AppSettingsDefaultTests {

    @Test("default：佣金万一 / 资本 10 万 / 跟随系统 / 免5 关闭")
    func defaultValues() {
        let d = AppSettings.default
        #expect(d.commissionRate == 0.0001)
        #expect(d.totalCapital == 100_000)
        #expect(d.displayMode == .system)
        #expect(d.minCommissionEnabled == false)
    }

    @Test("default：fee 非零（RFC 场景 2：forceReset 后 snapshotFeesIfReady 返非零费率）")
    func defaultFeeNonZero() {
        #expect(AppSettings.default.commissionRate != 0)
        #expect(AppSettings.default.totalCapital != 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter AppSettingsDefaultTests`
Expected: 编译失败 `type 'AppSettings' has no member 'default'`

- [ ] **Step 3: 实现 `AppSettings.default`（AppState.swift 末尾追加）**

```swift
// MARK: - Named default (Wave 2 顺位 10 引入；P6 forceResetAndReload reset 目标值)
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四：
// 含合理起始本金（非 0 资本）的命名默认值；不复用 capital 0 的 SettingsStore.zeroDefault。
public extension AppSettings {
    static let `default` = AppSettings(
        commissionRate: 0.0001,      // §6.4 佣金初始值 1（万分之一）
        minCommissionEnabled: false, // §6.4 未规定 免5 初始值；false=免5（无最低 5 元）
        totalCapital: 100_000,       // §6.4 重置资金 → 10 万元
        displayMode: .system)
}
```

- [ ] **Step 4: 创建 `SettingsResetConfirmation.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsResetConfirmation.swift
// Kline Trainer — Wave 2 顺位 10：P6 破坏性恢复的 deliberate-intent 信号
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四：
// public 类型（出现在 public forceResetAndReload(confirmation:) 签名）+ internal init
// → 包外（顺位 11 app target）无法构造，仅 KlineTrainerContracts 内（SettingsPanel 恢复 UX）可构造。
// 非抗 determined caller 的安全边界（同模块谁都能构造）；真正数据安全靠 SettingsStore 内的
// 错误类型门 + runtime 守卫 + 破坏前最后非破坏 reload。
public struct SettingsResetConfirmation: Sendable {
    internal init() {}
}
```

- [ ] **Step 5: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter AppSettingsDefaultTests`
Expected: PASS（2 tests）

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/AppState.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsResetConfirmation.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/AppSettingsDefaultTests.swift
git commit -m "feat(U4): AppSettings.default + SettingsResetConfirmation 类型"
```

---

## Task 2: 恢复测试替身 `RecoverySettingsDAO`

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/RecoverySettingsDAO.swift`

设计：脚本化 `loadSettings` 结果（FIFO 消费，对应 init→retry→forceReset 各次 load）；脚本耗尽后**反映 `stored`**（让破坏路径 `saveSettings(.default)` 后的 reload 真返回已写值，realistic）；`saveSettings` 计数 + 可注入失败。

- [ ] **Step 1: 创建 `RecoverySettingsDAO.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/RecoverySettingsDAO.swift
// 恢复状态机测试替身：脚本化 load 失败序列 + 写反映 + saveSettings 计数。
import Foundation
@testable import KlineTrainerContracts

final class RecoverySettingsDAO: SettingsDAO, @unchecked Sendable {
    private let lock = NSLock()
    /// 脚本化 loadSettings 结果，FIFO 消费一次一项；耗尽后返回 `stored`（反映写）。
    private var loadScript: [Result<AppSettings, Error>]
    private var idx = 0
    /// 「DB 里」的值；saveSettings 更新它，脚本耗尽后的 load 返回它。
    private var stored: AppSettings
    private(set) var saveCallCount = 0
    private(set) var lastSaved: AppSettings?
    /// 若设，saveSettings 抛此错误（计数前抛，模拟写失败）。
    var saveError: Error?

    init(loadScript: [Result<AppSettings, Error>], stored: AppSettings = .zero) {
        self.loadScript = loadScript
        self.stored = stored
    }

    func loadSettings() throws -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        if idx < loadScript.count {
            let r = loadScript[idx]; idx += 1
            switch r {
            case .success(let s): return s
            case .failure(let e): throw e
            }
        }
        return stored  // 脚本耗尽 → 反映写
    }

    func saveSettings(_ s: AppSettings) throws {
        lock.lock(); defer { lock.unlock() }
        if let e = saveError { throw e }   // 写失败：计数前抛
        saveCallCount += 1
        lastSaved = s
        stored = s
    }

    func resetCapital() throws {
        lock.lock(); defer { lock.unlock() }
        stored.totalCapital = 0
    }
}
```

- [ ] **Step 2: 编译确认（无独立测试，随 Task 3 编译）**

Run: `cd ios/Contracts && swift build --build-tests`
Expected: 编译通过（`RecoverySettingsDAO` 满足 `SettingsDAO`）。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/RecoverySettingsDAO.swift
git commit -m "test(U4): RecoverySettingsDAO 测试替身（脚本化 load + 计数）"
```

---

## Task 3: `SettingsStore.retryReload()`（非破坏 transient 恢复）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreRecoveryTests.swift`（本 Task 建文件 + retryReload 段）

- [ ] **Step 1: 写失败测试（retryReload 段）`SettingsStoreRecoveryTests.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreRecoveryTests.swift
// RFC docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md §四 11 场景。
import Foundation
import Testing
@testable import KlineTrainerContracts

@MainActor
@Suite("SettingsStore 两层恢复")
struct SettingsStoreRecoveryTests {

    private static let userSettings = AppSettings(
        commissionRate: 0.0007, minCommissionEnabled: true,
        totalCapital: 88_888, displayMode: .dark)

    // ── 场景 1：transient loadError → retryReload 救回真实设置，零破坏 ──
    @Test("场景1 transient：retryReload 恢复原用户设置 + 解阻 + 未调 saveSettings")
    func s1_transientRetrySucceeds() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.ioError("transient"))),  // init 失败
            .success(Self.userSettings),                            // retryReload 成功
        ])
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.loadError != nil)

        try await store.retryReload()

        #expect(store.settings == Self.userSettings)   // 原用户设置，非 default
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 0)                 // 零破坏
        // 解阻：update 不再抛
        try await store.update { $0.totalCapital = 99_999 }
        #expect(store.settings.totalCapital == 99_999)
    }

    // ── 场景 3a：健康态 retryReload throws 不动 ──
    @Test("场景3a 健康态：retryReload throws + settings 不变")
    func s3a_healthyRetryThrows() async throws {
        let dao = RecoverySettingsDAO(loadScript: [.success(Self.userSettings)])
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.loadError == nil)

        await #expect(throws: (any Error).self) { try await store.retryReload() }
        #expect(store.settings == Self.userSettings)
        #expect(dao.saveCallCount == 0)
    }

    // ── retryReload 失败 → loadError 更新为最新错误（场景 10/11 前置；公开可观测）──
    @Test("retryReload 失败：loadError 更新为最新 retry 错误（非 stale init 错误）")
    func retryFailUpdatesLoadError() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.ioError("init"))),   // init transient
            .failure(AppError.persistence(.dbCorrupted)),       // retry 暴露 dbCorrupted
        ])
        let store = SettingsStore(settingsDAO: dao)
        #expect(store.loadError == .persistence(.ioError("init")))

        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            try await store.retryReload()
        }
        #expect(store.loadError == .persistence(.dbCorrupted))  // 更新为最新，非 stale
        #expect(dao.saveCallCount == 0)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter SettingsStoreRecoveryTests`
Expected: 编译失败 `value of type 'SettingsStore' has no member 'retryReload'`

- [ ] **Step 3: 实现 `retryReload()` + 私有状态 + helper（SettingsStore.swift）**

在 `private var _loadError: AppError?` 之后追加私有 flag：

```swift
    /// Wave 2 顺位 1 RFC §四：retryReload() 失败后置位；forceResetAndReload 强制「先试 retryReload」顺序。
    private var _retryReloadFailed = false
```

在 `snapshotFeesIfReady()` 之后（类内、`}` 前）追加：

```swift
    // MARK: - Wave 2 顺位 1 RFC §四：loadError 两层恢复

    /// 仅 `.persistence(.dbCorrupted)` 是 corruption-class（数据真不可解，破坏才有意义）；
    /// diskFull/ioError/schemaMismatch 等一律 transient（不允许破坏）。
    private static func isDBCorrupted(_ error: AppError) -> Bool {
        if case .persistence(.dbCorrupted) = error { return true }
        return false
    }

    /// 非破坏性 transient 恢复（首选）。要求 loadError != nil；纯重读不写库。
    /// 成功 → MainActor 先 settings=loaded 再清 loadError+flag（保留 DB 真实用户设置）。
    /// 失败 → 置 _retryReloadFailed + 更新 _loadError 为本次最新错误（不留 stale init 错误）+ throws。
    public func retryReload() async throws {
        guard _loadError != nil else {
            throw AppError.internalError(module: "P6", detail: "retryReload 仅在 loadError 态可用")
        }
        let dao = self.settingsDAO
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try dao.loadSettings()
            }.value
            self.settings = loaded          // R2-high 不变量：先刷新 settings
            self._loadError = nil           // 再清错误位
            self._retryReloadFailed = false
        } catch {
            let appErr = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            self._retryReloadFailed = true
            self._loadError = appErr        // FR7：更新为最新错误，不留 stale
            throw appErr
        }
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter SettingsStoreRecoveryTests`
Expected: PASS（3 tests）

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreRecoveryTests.swift
git commit -m "feat(U4): SettingsStore.retryReload() 非破坏 transient 恢复"
```

---

## Task 4: `SettingsStore.forceResetAndReload(confirmation:)`（破坏性 last-resort）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreRecoveryTests.swift`（追加 forceReset 段）

- [ ] **Step 1: 追加失败测试（forceReset 段，加到 `SettingsStoreRecoveryTests` struct 内）**

```swift
    // ── 场景 2：persistent malformed → retry throws → forceReset → default + 非零 fee ──
    @Test("场景2 persistent：retry 失败后 forceReset 重置为 default + snapshotFeesIfReady 非零")
    func s2_persistentForceReset() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry throws
            .failure(AppError.persistence(.dbCorrupted)),  // forceReset 破坏前最后 reload
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())

        #expect(store.settings == .default)
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 1)
        let fees = try store.snapshotFeesIfReady()
        #expect(fees.commissionRate == 0.0001)   // 非零 default fee
    }

    // ── 场景 3b：健康态 forceReset throws 不动 ──
    @Test("场景3b 健康态：forceReset throws + settings 不变 + 未调 saveSettings")
    func s3b_healthyForceThrows() async throws {
        let dao = RecoverySettingsDAO(loadScript: [.success(Self.userSettings)])
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: (any Error).self) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(store.settings == Self.userSettings)
        #expect(dao.saveCallCount == 0)
    }

    // ── 场景 4：未先试 retryReload → forceReset throws + 零破坏 ──
    @Test("场景4 顺序守卫：未 retryReload 直接 forceReset throws + 未调 saveSettings")
    func s4_orderGuard() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init（_retryReloadFailed 仍 false）
        ])
        let store = SettingsStore(settingsDAO: dao)

        await #expect(throws: (any Error).self) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(dao.saveCallCount == 0)
    }

    // ── 场景 5：入口 dbCorrupted 但破坏前 reload 自愈 → 保留真实值，零破坏 ──
    @Test("场景5 破坏前自愈：forceReset 最后 reload 成功 → settings=DB 真实值 + 未调 saveSettings")
    func s5_selfHealBeforeDestroy() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry throws（_loadError 仍 dbCorrupted）
            .success(Self.userSettings),                   // forceReset 破坏前 reload 自愈
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())

        #expect(store.settings == Self.userSettings)  // 真实值，非 default
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 0)               // 零破坏
    }

    // ── 场景 6：transient 未恢复 → 错误类型门 throws + 零破坏 ──
    @Test("场景6 transient 未恢复：forceReset 错误类型门 throws + 未调 saveSettings")
    func s6_transientGate() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.diskFull)),  // init transient
            .failure(AppError.persistence(.diskFull)),  // retry 仍 transient（_loadError=diskFull）
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        await #expect(throws: AppError.persistence(.diskFull)) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(dao.saveCallCount == 0)   // 非 dbCorrupted 不破坏
    }

    // ── 场景 7：persistent corruption → 破坏路径 reset 成功 ──
    @Test("场景7 corruption：retry dbCorrupted → forceReset 写 default reset 成功 + 解阻")
    func s7_persistentCorruption() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry
            .failure(AppError.persistence(.dbCorrupted)),  // forceReset 破坏前最后 reload
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())

        #expect(store.settings == .default)
        #expect(store.loadError == nil)
        #expect(dao.saveCallCount == 1)
        try await store.update { $0.displayMode = .light }  // 解阻
        #expect(store.settings.displayMode == .light)
    }

    // ── 场景 8：混合错误（入口 dbCorrupted 但破坏前变 transient）→ throws + 零破坏 ──
    @Test("场景8 混合：入口 dbCorrupted 破坏前变 diskFull → loadError=diskFull + throws + 未调 saveSettings")
    func s8_mixedError() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry（_loadError=dbCorrupted）
            .failure(AppError.persistence(.diskFull)),     // forceReset 破坏前 reload 变 transient
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        await #expect(throws: AppError.persistence(.diskFull)) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(store.loadError == .persistence(.diskFull))  // 更新为 transient
        #expect(dao.saveCallCount == 0)                      // 不破坏
    }

    // ── 场景 9：破坏路径 saveSettings 失败 → loadError 保留 + throws ──
    @Test("场景9 破坏写失败：saveSettings throws → loadError 保留 dbCorrupted + throws")
    func s9_destroyWriteFails() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),  // init
            .failure(AppError.persistence(.dbCorrupted)),  // retry
            .failure(AppError.persistence(.dbCorrupted)),  // forceReset 破坏前最后 reload
        ])
        dao.saveError = AppError.persistence(.diskFull)    // 写库失败
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }

        await #expect(throws: (any Error).self) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(store.loadError == .persistence(.dbCorrupted))  // 保留
    }

    // ── 场景 10：init transient → retry 暴露 dbCorrupted → forceReset 过门 reset 成功 ──
    @Test("场景10 init-transient→retry-dbCorrupted：forceReset 按最新错误过门 reset 成功")
    func s10_initTransientRetryCorrupted() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.ioError("init"))),  // init transient
            .failure(AppError.persistence(.dbCorrupted)),      // retry 暴露 dbCorrupted
            .failure(AppError.persistence(.dbCorrupted)),      // forceReset 破坏前最后 reload
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }
        #expect(store.loadError == .persistence(.dbCorrupted))  // 已更新为最新

        try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        #expect(store.settings == .default)
        #expect(dao.saveCallCount == 1)
    }

    // ── 场景 11：init dbCorrupted → retry 变 transient → forceReset 拒绝破坏 ──
    @Test("场景11 init-dbCorrupted→retry-transient：forceReset 按最新 transient 拒绝 + 未调 saveSettings")
    func s11_initCorruptedRetryTransient() async throws {
        let dao = RecoverySettingsDAO(loadScript: [
            .failure(AppError.persistence(.dbCorrupted)),       // init
            .failure(AppError.persistence(.ioError("later"))),  // retry 变 transient
        ])
        let store = SettingsStore(settingsDAO: dao)
        await #expect(throws: (any Error).self) { try await store.retryReload() }
        #expect(store.loadError == .persistence(.ioError("later")))

        await #expect(throws: AppError.persistence(.ioError("later"))) {
            try await store.forceResetAndReload(confirmation: SettingsResetConfirmation())
        }
        #expect(dao.saveCallCount == 0)
    }
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter SettingsStoreRecoveryTests`
Expected: 编译失败 `no member 'forceResetAndReload'`

- [ ] **Step 3: 实现 `forceResetAndReload(confirmation:)`（SettingsStore.swift，紧接 `retryReload()` 之后）**

```swift
    /// 破坏性 last-resort（仅持久损坏）。守卫编码进 state（非 prose 约定）：
    /// ① loadError != nil ② _retryReloadFailed == true（已先试 retryReload 且失败）
    /// ③ loadError 是 corruption-class .persistence(.dbCorrupted)。
    /// 任一不满足 → throws 且不调 saveSettings（零破坏；transient 走 retry-only）。
    /// 过门后破坏前最后非破坏 reload：成功（transient 已恢复）→ 保留真实设置不写库；
    /// 失败且 final error 也是 dbCorrupted → saveSettings(.default) → reload；
    /// 失败但 final 是 transient → 更新 loadError + throws + 不破坏（FR3 混合错误）。
    public func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws {
        _ = confirmation  // deliberate-intent 信号（构造即意图）；真正数据安全靠下方守卫
        guard let entryError = _loadError else {
            throw AppError.internalError(module: "P6", detail: "forceReset 仅在 loadError 态可用")
        }
        guard _retryReloadFailed else {
            throw AppError.internalError(module: "P6", detail: "forceReset 须先失败的 retryReload")
        }
        guard Self.isDBCorrupted(entryError) else {
            throw entryError   // 非 dbCorrupted（transient）→ retry-only，零破坏
        }
        let dao = self.settingsDAO
        do {
            // 破坏前最后非破坏 reload
            let loaded = try await Task.detached(priority: .userInitiated) {
                try dao.loadSettings()
            }.value
            self.settings = loaded          // transient 已恢复：保留真实设置
            self._loadError = nil
            self._retryReloadFailed = false
            return                          // 零破坏（不 saveSettings）
        } catch {
            let finalError = (error as? AppError)
                ?? .internalError(module: "P6", detail: String(describing: error))
            guard Self.isDBCorrupted(finalError) else {
                self._loadError = finalError  // 混合错误：更新为 transient
                throw finalError              // 不破坏
            }
            // 确认持久损坏 → 破坏性 reset
            try await Task.detached(priority: .userInitiated) {
                try dao.saveSettings(AppSettings.default)
            }.value                           // 写失败则抛出，_loadError 保留 dbCorrupted
            let reloaded = try await Task.detached(priority: .userInitiated) {
                try dao.loadSettings()
            }.value
            self.settings = reloaded
            self._loadError = nil
            self._retryReloadFailed = false
        }
    }
```

- [ ] **Step 4: 运行确认通过（全 11 场景）**

Run: `cd ios/Contracts && swift test --filter SettingsStoreRecoveryTests`
Expected: PASS（13 tests：场景 1/3a/retryFail + 2/3b/4/5/6/7/8/9/10/11）

- [ ] **Step 5: Mutation-verify 一处关键守卫（per `feedback_e3_fp_demonstrator`：守卫须 mutation 实证非空洞）**

临时把 Step 3 错误类型门 `guard Self.isDBCorrupted(entryError)` 改成 `guard true`（放行 transient），重跑场景 6 / 8 / 11：
Run: `cd ios/Contracts && swift test --filter SettingsStoreRecoveryTests`
Expected: 场景 6/8/11 **失败**（证明错误类型门是 killer，非空洞）→ 改回 `guard Self.isDBCorrupted(entryError)` 重跑全绿。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreRecoveryTests.swift
git commit -m "feat(U4): SettingsStore.forceResetAndReload(confirmation:) 破坏性恢复（11 场景）"
```

---

## Task 5: `SettingsPanelContent`（纯值 helper，host 全测）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettingsPanelContentTests.swift`

- [ ] **Step 1: 写失败测试 `SettingsPanelContentTests.swift`**

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettingsPanelContentTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("SettingsPanelContent")
struct SettingsPanelContentTests {

    // commission 边界换算（spec modules L2009/L2013）
    @Test("commissionRate(fromUIInputTenThousandth:)：UI 1 → 0.0001")
    func uiToRate() {
        // ×1 平凡乘（乘 1.0 位等价）→ 精确 ==；非平凡乘用容差（per feedback_swift_local_toolchain_blindspot）
        #expect(SettingsPanelContent.commissionRate(fromUIInputTenThousandth: 1) == 0.0001)
        #expect(abs(SettingsPanelContent.commissionRate(fromUIInputTenThousandth: 7) - 0.0007) < 1e-12)
    }

    @Test("uiDisplayTenThousandth(fromCommissionRate:)：0.0001 → 1（容差，FP）")
    func rateToUI() {
        let v = SettingsPanelContent.uiDisplayTenThousandth(fromCommissionRate: 0.0001)
        #expect(abs(v - 1.0) < 1e-9)
    }

    @Test("formatCommissionUIInput：0.0001 → \"1.000\"（§6.4 精确 3 位）")
    func formatCommission() {
        #expect(SettingsPanelContent.formatCommissionUIInput(0.0001) == "1.000")
        #expect(SettingsPanelContent.formatCommissionUIInput(0.00125) == "12.500")
    }

    // commission 输入解析（§6.4 不能为空）
    @Test("parseCommissionUIInput：合法→stored 小数率；空/非法→nil")
    func parseCommission() {
        #expect(SettingsPanelContent.parseCommissionUIInput("1") == 0.0001)        // ×1 精确
        let p = SettingsPanelContent.parseCommissionUIInput("  2.5 ")              // ×2.5 容差
        #expect(p != nil && abs(p! - 0.00025) < 1e-12)
        #expect(SettingsPanelContent.parseCommissionUIInput("") == nil)
        #expect(SettingsPanelContent.parseCommissionUIInput("abc") == nil)
    }

    // 下载数量校验（§6.4 整数 1~20）
    @Test("validateDownloadCount：1~20 valid；边界/非整数/越界/空")
    func validateCount() {
        #expect(SettingsPanelContent.validateDownloadCount("1") == .valid(1))
        #expect(SettingsPanelContent.validateDownloadCount("20") == .valid(20))
        #expect(SettingsPanelContent.validateDownloadCount(" 5 ") == .valid(5))
        #expect(SettingsPanelContent.validateDownloadCount("0") == .outOfRange)
        #expect(SettingsPanelContent.validateDownloadCount("21") == .outOfRange)
        #expect(SettingsPanelContent.validateDownloadCount("3.5") == .notInteger)
        #expect(SettingsPanelContent.validateDownloadCount("") == .empty)
    }

    // displayMode label
    @Test("displayModeLabel：三态中文")
    func displayLabels() {
        #expect(SettingsPanelContent.displayModeLabel(.light) == "白天模式")
        #expect(SettingsPanelContent.displayModeLabel(.dark) == "夜间模式")
        #expect(SettingsPanelContent.displayModeLabel(.system) == "跟随系统")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter SettingsPanelContentTests`
Expected: 编译失败 `cannot find 'SettingsPanelContent' in scope`

- [ ] **Step 3: 实现 `SettingsPanelContent.swift`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift
// 平台无关纯值 helper：commission 边界换算/格式 + 下载数量校验 + displayMode label。
// 仅 import Foundation（host swift test 全测）；SettingsPanel 壳调用，不重复逻辑。
// Spec: kline_trainer_modules_v1.4.md L2009/L2013（commission 换算）+ plan_v1.5 §6.4（5 控件）
import Foundation

public enum SettingsPanelContent {

    // MARK: - commission 边界换算（spec L2009/L2013：UI 万分之一 ↔ 存储小数率）
    public static func commissionRate(fromUIInputTenThousandth x: Double) -> Double { x * 0.0001 }
    public static func uiDisplayTenThousandth(fromCommissionRate r: Double) -> Double { r * 10000 }

    /// §6.4「精确到小数点后 3 位」：把存储小数率显示成 UI 万分之一字符串。
    public static func formatCommissionUIInput(_ rate: Double) -> String {
        String(format: "%.3f", uiDisplayTenThousandth(fromCommissionRate: rate))
    }

    /// §6.4「不能为空」：解析 UI 万分之一输入 → 存储小数率；空/非数字 → nil。
    public static func parseCommissionUIInput(_ input: String) -> Double? {
        let t = input.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let ui = Double(t) else { return nil }
        return commissionRate(fromUIInputTenThousandth: ui)
    }

    // MARK: - 下载数量校验（§6.4：整数 1~20）
    public enum DownloadCountValidation: Equatable, Sendable {
        case valid(Int)
        case empty
        case notInteger
        case outOfRange
    }

    public static func validateDownloadCount(_ input: String) -> DownloadCountValidation {
        let t = input.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return .empty }
        guard let n = Int(t) else { return .notInteger }
        guard (1...20).contains(n) else { return .outOfRange }
        return .valid(n)
    }

    // MARK: - 显示模式 label（§6.4：白天/夜间/跟随系统）
    public static func displayModeLabel(_ mode: DisplayMode) -> String {
        switch mode {
        case .light: return "白天模式"
        case .dark: return "夜间模式"
        case .system: return "跟随系统"
        }
    }
    public static let displayModeOrder: [DisplayMode] = [.light, .dark, .system]
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter SettingsPanelContentTests`
Expected: PASS（6 tests）

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettingsPanelContentTests.swift
git commit -m "feat(U4): SettingsPanelContent 纯值 helper（host 全测）"
```

---

## Task 6: `SettingsPanel` SwiftUI 壳 + `#Preview`

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift`

不写单测（D8/D10）；靠 Catalyst build-for-testing 闸门。壳实现 §6.4 五控件 + loadError 恢复 UX，复用 `SettingsPanelContent` + `SettingsStore` 恢复 API。

- [ ] **Step 1: 实现 `SettingsPanel.swift`（含 `#Preview`）**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift
// Spec: kline_trainer_modules_v1.4.md §U4 L2081-2084 字面 init 签名 + plan_v1.5 §6.4 五控件。
// 薄 SwiftUI 壳（D8/D10 不单测，靠 Catalyst 编译闸门）：纯逻辑全在 SettingsPanelContent / SettingsStore。
// 决策（D3/D6）：SettingsResetConfirmation() 在本模块内构造（落实 UI-owned 恢复边界）；
//               离线缓存薄接线 reserveTrainingSets → runBatch（取消/逐项错误恢复不在本锚）。
import SwiftUI

public struct SettingsPanel: View {
    private let settings: SettingsStore
    private let api: any APIClient
    private let cache: any CacheManager
    private let acceptance: DownloadAcceptanceRunner

    @State private var commissionInput = ""
    @State private var showCommissionEditor = false
    @State private var showResetConfirm = false
    @State private var downloadCountInput = ""
    @State private var showDownloadEditor = false
    @State private var downloadStatus = ""
    @State private var isDownloading = false
    @State private var recoveryMessage = ""
    @State private var isRecovering = false   // M1：禁用恢复按钮防并发双触发 clobber

    public init(settings: SettingsStore, api: any APIClient,
                cache: any CacheManager, acceptance: DownloadAcceptanceRunner) {
        self.settings = settings
        self.api = api
        self.cache = cache
        self.acceptance = acceptance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            if settings.loadError != nil {
                recoverySection
                Divider()
            }

            // 1. 佣金费率
            Button("佣金费率：\(SettingsPanelContent.formatCommissionUIInput(settings.settings.commissionRate))（万分之一）") {
                commissionInput = SettingsPanelContent.formatCommissionUIInput(settings.settings.commissionRate)
                showCommissionEditor = true
            }

            // 2. 免5 开关
            Toggle("免5（不收最低 5 元佣金）", isOn: Binding(
                get: { !settings.settings.minCommissionEnabled },
                set: { newValue in
                    Task { try? await settings.update { $0.minCommissionEnabled = !newValue } }
                }))

            // 3. 重置资金
            Button("重置资金（→ ¥100,000）") { showResetConfirm = true }

            // 4. 离线缓存
            Button(isDownloading ? "下载中…" : "离线缓存下载") { showDownloadEditor = true }
                .disabled(isDownloading)
            if !downloadStatus.isEmpty { Text(downloadStatus).font(.caption).foregroundStyle(.secondary) }

            // 5. 显示模式
            Picker("显示模式", selection: Binding(
                get: { settings.settings.displayMode },
                set: { newMode in Task { try? await settings.update { $0.displayMode = newMode } } })) {
                ForEach(SettingsPanelContent.displayModeOrder, id: \.self) { mode in
                    Text(SettingsPanelContent.displayModeLabel(mode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(24)
        // 佣金编辑
        .alert("佣金费率（万分之一）", isPresented: $showCommissionEditor) {
            TextField("如 1.000", text: $commissionInput)
            Button("取消", role: .cancel) {}
            Button("确定") {
                if let rate = SettingsPanelContent.parseCommissionUIInput(commissionInput) {
                    Task { try? await settings.update { $0.commissionRate = rate } }
                }
            }
        }
        // 重置资金二次确认
        .alert("确认重置资金为 ¥100,000？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                Task { try? await settings.resetCapital() }
            }
        }
        // 离线缓存数量输入
        .alert("下载数量（1~20）", isPresented: $showDownloadEditor) {
            TextField("如 5", text: $downloadCountInput)
            Button("取消", role: .cancel) {}
            Button("下载") { startDownload() }
        }
    }

    @ViewBuilder
    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⚠️ 设置加载失败").foregroundStyle(.red)
            if !recoveryMessage.isEmpty { Text(recoveryMessage).font(.caption).foregroundStyle(.secondary) }
            Button("重试") {
                isRecovering = true
                Task {
                    defer { isRecovering = false }
                    do { try await settings.retryReload(); recoveryMessage = "" }
                    catch { recoveryMessage = "重试失败，可尝试重置为默认设置" }
                }
            }
            .disabled(isRecovering)   // M1：防并发双触发 clobber（恢复是手动单发动作）
            // 仅在重试失败后暴露破坏性入口（recoveryMessage 非空）
            if !recoveryMessage.isEmpty {
                Button("重置为默认设置（清除本地设置）", role: .destructive) {
                    isRecovering = true
                    Task {
                        defer { isRecovering = false }
                        // SettingsResetConfirmation() 仅本模块可构造（D3）
                        do { try await settings.forceResetAndReload(confirmation: SettingsResetConfirmation()) }
                        catch { recoveryMessage = "重置失败：\((error as? AppError)?.userMessage ?? "未知错误")" }
                    }
                }
                .disabled(isRecovering)
            }
        }
    }

    private func startDownload() {
        guard case .valid(let count) = SettingsPanelContent.validateDownloadCount(downloadCountInput) else {
            downloadStatus = "请输入 1~20 的整数"
            return
        }
        isDownloading = true
        downloadStatus = "下载中…"
        Task {
            defer { isDownloading = false }
            do {
                let lease = try await api.reserveTrainingSets(count: count)
                let results = await acceptance.runBatch(lease: lease)
                let ok = results.filter { if case .confirmed = $0 { return true }; return false }.count
                downloadStatus = "完成：\(ok)/\(results.count) 成功"
            } catch {
                downloadStatus = "下载失败：\((error as? AppError)?.userMessage ?? "网络错误")"
            }
        }
    }
}

// MARK: - DEBUG-only #Preview（fileprivate APIClient stub + 现有 fakes）

#if DEBUG
private struct _PreviewSettingsAPIClient: APIClient {
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        LeaseResponse(leaseId: "preview", expiresAt: "2099-01-01T00:00:00Z", sets: [])
    }
    func downloadTrainingSet(id: Int) async throws -> URL { URL(fileURLWithPath: "/dev/null") }
    func confirmTrainingSet(id: Int, leaseId: String) async throws {}
}

@MainActor
private func _previewRunner() -> DownloadAcceptanceRunner {
    DownloadAcceptanceRunner(
        api: _PreviewSettingsAPIClient(), cache: InMemoryCacheManager(),
        dbFactory: PreviewTrainingSetDBFactory(), journal: InMemoryAcceptanceJournalDAO(),
        integrity: FakeZipIntegrityVerifier(), extractor: FakeZipExtractor(),
        dataVerifier: FakeTrainingSetDataVerifier(), cleaner: FakeDownloadAcceptanceCleaner())
}

#Preview {
    SettingsPanel(settings: .preview(), api: _PreviewSettingsAPIClient(),
                  cache: InMemoryCacheManager(), acceptance: _previewRunner())
}
#endif
```

- [ ] **Step 2: 复核 `AcceptanceResult` case 名（plan 阶段已核实）**

已核实（`Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift:19`）：
```swift
public enum AcceptanceResult: Equatable, Sendable {
    case confirmed(TrainingSetFile)
    case rejected(AppError)
}
```
故 `startDownload()` 内 `if case .confirmed = $0` 正确，无需改动。实施时 `grep -n "case confirmed" Sources/.../DownloadAcceptanceRunner.swift` 复核一次即可。

- [ ] **Step 3: 编译验证（host build + build-tests）**

Run: `cd ios/Contracts && swift build && swift build --build-tests`
Expected: 编译通过（SwiftUI 在 macOS host 可编译；`#Preview` 在 DEBUG 编译）。

- [ ] **Step 4: 全量测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -15`
Expected: 全绿，新增 21 tests（13 recovery + 6 content + 2 default），总数 = 610 + 21 = 631（以实际为准）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift
git commit -m "feat(U4): SettingsPanel SwiftUI 壳（5 控件 + loadError 恢复 UX + #Preview）"
```

---

## Task 7: 验收清单 + 完整验证

**Files:**
- Create: `docs/acceptance/2026-06-07-pr-u4-settings-panel.md`

- [ ] **Step 1: 写验收清单**（中文，action/expected/pass-fail；禁忌词见 `.claude/workflow-rules.json`）覆盖：
  - `AppSettings.default` 四字段值 + fee 非零。
  - 11 RFC 恢复场景逐条（场景号 ↔ 测试名 ↔ pass-fail）。
  - `SettingsPanelContent` 6 组纯函数。
  - SettingsPanel 壳 §6.4 五控件在场（grep 真实 Swift Testing 输出 / 源码锚定）。
  - `SettingsResetConfirmation` internal init（grep 断言：无 `public init`）。
  - 离线缓存薄接线（grep `reserveTrainingSets` + `runBatch`）。

- [ ] **Step 2: 全量 swift test 真实输出留证**

Run: `cd ios/Contracts && swift test 2>&1 | tail -20`
Expected: `Test run with N tests ... 0 failures`（贴真实数字进验收 doc）。

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-06-07-pr-u4-settings-panel.md
git commit -m "docs(U4): 非 coder 验收清单"
```

---

## Self-Review（plan 作者自查，写完即查）

**1. Spec 覆盖：**
- RFC §四 两层恢复 API → Task 3（retryReload）+ Task 4（forceReset）✅
- RFC §四 11 验收场景 → Task 3（1/3a/retryFail）+ Task 4（2/3b/4/5/6/7/8/9/10/11）✅ 全覆盖
- `AppSettings.default`（非零 fee/capital）→ Task 1 ✅
- `SettingsResetConfirmation`（internal init）→ Task 1（D3）✅
- modules §U4 L2081 冻结签名 `init(settings:api:cache:acceptance:)` → Task 6 字面匹配 ✅
- plan_v1.5 §6.4 五控件（佣金/免5/重置资金/离线缓存/显示模式）→ Task 6 ✅
- commission UI 边界换算 L2009/L2013 → Task 5 字面 ✅
- 离线缓存薄接线（D6 user 选择）→ Task 6 `startDownload()` ✅
- 不改 `SettingsDAO` 协议（D1）→ 全 Task 未触 SettingsDAO.swift ✅

**2. Placeholder 扫描：** 无 TBD/TODO；每 code step 含完整代码；唯一「按实际校准」= Task 6 Step 2 `AcceptanceResult` case 名（已给 grep 校验步 + fallback 指引，非 placeholder）。

**3. 类型一致性：**
- `SettingsPanelContent`（enum 命名空间，全 static）：Task 5 定义 ↔ Task 6 调用一致（`commissionRate(fromUIInputTenThousandth:)`/`uiDisplayTenThousandth(fromCommissionRate:)`/`formatCommissionUIInput`/`parseCommissionUIInput`/`validateDownloadCount`/`displayModeLabel`/`displayModeOrder`）✅
- `RecoverySettingsDAO`（Task 2）↔ 测试用法（Task 3/4）：`loadScript`/`saveCallCount`/`saveError`/`.zero` 默认 stored ✅
- `SettingsResetConfirmation()`（Task 1 internal init）↔ 测试 + 壳构造（同模块）✅
- `retryReload()`/`forceResetAndReload(confirmation:)`/`isDBCorrupted`/`_retryReloadFailed`：Task 3/4 自洽 ✅
- `AppSettings.default`（Task 1）↔ Task 4 forceReset reset 目标 + 场景断言 ✅

**风险点（交 plan-stage opus xhigh 评审重点）：**
- R-A：恢复方法用 `Task.detached` 是否与 `@MainActor @Observable` 的 Observation 追踪 + Swift 6 strict concurrency 冲突（AppSettings/dao 均 Sendable，应安全；评审核实）。
- R-B：`uiDisplayTenThousandth(0.0001)=0.0001*10000` 的 FP 结果是否恰好 1.0（测试用容差 1e-9 规避；`formatCommissionUIInput` 用 `%.3f` 字符串规避）。
- R-C：场景 9 `saveError` 设后 `saveCallCount` 不增——断言只查 `loadError 保留`，未误用 saveCallCount。
- R-D：`AcceptanceResult` 真实 case 名（Task 6 Step 2 校准）。
