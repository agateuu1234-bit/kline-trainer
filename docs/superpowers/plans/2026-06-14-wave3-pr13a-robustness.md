# Wave 3 PR 13a — 运行期健壮性（cache touch-on-use + 边界错误统一 Toast）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 闭合 Wave 3 10b-deferred 的两项运行期健壮性残留：§A cache touch-on-use（E6a-R3）+ §B 边界错误统一 Toast 层（RFC §4.6 item5 autosave 失败可见 + 下载 per-item 失败可见）。

**Architecture:** 纯逻辑下放 host-testable 值类型（`ToastState` latest-wins 调度核 / `DownloadBatchFeedback` 下载失败文案 / coordinator 新增 observable `autosaveBannerError` 信号字段）；SwiftUI 壳（`ToastOverlay` 复用 modifier + TrainingView/SettingsPanel 接线）仅 Catalyst 编译闸门守护。touch-on-use 在 coordinator 四处 `openReader` 成功点 additive 调 `cache.touch(file)`。

**Tech Stack:** Swift 6 / Swift Testing（`@Test`/`@Suite`）/ SwiftUI / Observation；`ios/Contracts` SwiftPM 包；`swift test` host + Mac Catalyst build-for-testing CI。

**Source-of-truth spec:** `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §A/§B（含错误类→处置映射表）。

**评审通道（trust-boundary）:** 本 PR 改 `ios/**/*.swift` → 须经 `codex:adversarial-review`（codex 配额耗尽方 fallback opus 4.8 xhigh）+ `Mac Catalyst build-for-testing on macos-15` required check。

**关键既有事实（已 grep 核实，2026-06-14 worktree `bcf32b1`）:**
- `CacheManager.touch(_:)` 协议存在（`Persistence/CacheManager.swift:10`）；`DefaultFileSystemCacheManager.touch` 实现 setAttributes mtime（`:82-89`）；read 路径四处 `openReader` 成功点 `:146`/`:183`/`:231`/`:268` **无** touch；损坏分支 `cache.delete` 在 `:148`/`:185`/`:233`/`:270`。
- `lastAutosaveError: AppError?` 是 `@ObservationIgnored`（`TrainingSessionCoordinator.swift:61`），set in autosave catch `:86-87`，cleared at `endSession`(:405) / `resetAutosaveState`(:510)。
- `TrainingView` 持值类型 `let lifecycle: TrainingSessionLifecycle`（struct，`:23`）；已经经 `.onChange(of: engine.tick.globalTickIndex)`（`:77`）观察 `@Observable` engine 穿过值类型 wrapper → 观察 `@Observable` coordinator 新字段同理可行。
- 现有 toast：`@State toastMessage`/`toastToken`（TrainingView `:33-34`），`presentToast`（`:230-238`，token latest-wins + 2s），`.overlay(.top)` regularMaterial Capsule（`:141-151`）。
- `SettingsPanel.startDownload`（`:136-154`）：`results` 仅数成功（`:148-149`），`.rejected(AppError)` reason 丢弃。
- `AppError.userMessage` / `shouldShowToast` 就绪（`AppError.swift:53-127`）。`AppError: Equatable`。
- 纯值反馈范式：`TradeFeedback`（`UI/TradeFeedback.swift`，`init<Success>(result:)`）；host 测见 `TradeFeedbackTests`。
- 测试构造：`PIFixtures.makeCoordinator()` → `(coord, records, pending, port)`；`PIFixtures.makeProvenanceCoordinator(files:corrupt:openError:)` → `(coord, factory, cache, pending)`（返回 `InMemoryCacheManager`）。`InMemoryCacheManager` 有 `deletedFilenames` spy（`InMemoryFakes.swift:426-430`），`touch`（`:464-474`），`_seedForTesting`，`pickOverride`。

**Baseline:** `swift test`（`ios/Contracts`）= 972 tests / 137 suites / 0 failures。

---

## File Structure

- **Modify** `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift` — §A：4 处 `openReader` 成功点加 `cache.touch(file)`；§B.2：加 observable `autosaveBannerError` 字段 + autosave catch 置位 + endSession/resetAutosaveState 清零。
- **Modify** `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift` — §A 测试基础设施：`InMemoryCacheManager` 加 `touchedFilenames` spy（mirror `deletedFilenames`）。
- **Create** `ios/Contracts/Sources/KlineTrainerContracts/UI/ToastState.swift` — §B.1 host-testable latest-wins 调度核（纯值 struct）。
- **Create** `ios/Contracts/Sources/KlineTrainerContracts/UI/ToastOverlay.swift` — §B.1 content-agnostic SwiftUI 复用 modifier（Catalyst-gated）。
- **Create** `ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift` — §B.3 下载批量失败文案纯值（host 测）。
- **Modify** `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` — §B.1 迁移 trade toast 到 `ToastState`+`ToastOverlay`；§B.2 `.onChange` 观察 `autosaveBannerError` → 弹 toast。
- **Modify** `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift` — §B.3 download `.rejected` reason 经 `DownloadBatchFeedback` + `ToastOverlay` 呈现。
- **Create** tests:
  - `ios/Contracts/Tests/KlineTrainerContractsTests/CacheTouchOnUseTests.swift` — §A
  - `ios/Contracts/Tests/KlineTrainerContractsTests/ToastStateTests.swift` — §B.1
  - `ios/Contracts/Tests/KlineTrainerContractsTests/AutosaveBannerTests.swift` — §B.2（coordinator 信号字段）
  - `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadBatchFeedbackTests.swift` — §B.3
- **Create** `docs/acceptance/2026-06-14-wave3-pr13a-robustness.md` — 非-coder 验收清单。

---

## Task 1: §A — InMemoryCacheManager `touchedFilenames` spy（测试基础设施）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift:426-430`（spy 字段）+ `:464-474`（touch 记录）

- [ ] **Step 1: 加 `touchedFilenames` spy 字段（mirror `deletedFilenames`）**

在 `InMemoryCacheManager` 的 `deletedFilenames` spy 之后（`:430` 之后）插入：

```swift
    /// Wave 3 PR 13a §A spy：touch 调用文件名记录（touch-on-use 断言）。lock 保护读。
    private var _touchedFilenames: [String] = []
    public var touchedFilenames: [String] {
        lock.lock(); defer { lock.unlock() }; return _touchedFilenames
    }
```

- [ ] **Step 2: `touch(_:)` 记录文件名（仅命中已存在文件时）**

把 `touch(_:)`（`:464-474`）改为在成功更新 mtime 后追加 spy 记录：

```swift
    public func touch(_ file: TrainingSetFile) {
        lock.lock(); defer { lock.unlock() }
        guard let existing = self.store[file.id] else { return }   // best-effort silent no-op
        let now = Int64(Date().timeIntervalSince1970)
        self.store[file.id] = TrainingSetFile(
            id: existing.id, filename: existing.filename, localURL: existing.localURL,
            schemaVersion: existing.schemaVersion,
            lastAccessedAt: now,
            downloadedAt: existing.downloadedAt
        )
        _touchedFilenames.append(existing.filename)
    }
```

- [ ] **Step 3: 编译确认（spy 不破现有）**

Run: `cd ios/Contracts && swift build --target KlineTrainerContracts`
Expected: build 成功（无新 warning/error）。

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift
git commit -m "test(13a): InMemoryCacheManager 加 touchedFilenames spy（§A touch-on-use 断言用）"
```

---

## Task 2: §A — cache touch-on-use 测试（先失败）

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/CacheTouchOnUseTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("cache touch-on-use（E6a-R3）：read 路径成功打开后刷新 LRU mtime")
@MainActor
struct CacheTouchOnUseTests {

    @Test("startNewNormalSession 成功打开 → touch 该训练组")
    func startNewNormal_touchesOpenedFile() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        _ = try await coord.startNewNormalSession()
        #expect(cache.touchedFilenames == ["a.sqlite"])
    }

    @Test("resumePending 成功打开 → touch 该训练组")
    func resumePending_touchesOpenedFile() async throws {
        let (coord, _, cache, pending) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        try await coord.saveProgress(engine: engine)
        await coord.endSession()
        let resumed = try await coord.resumePending()
        #expect(resumed != nil)
        #expect(cache.touchedFilenames.contains("a.sqlite"))
        _ = pending
    }

    @Test("review 成功打开 → touch 该训练组")
    func review_touchesOpenedFile() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: engine)
        await coord.endSession()
        _ = try await coord.review(recordId: id!)
        #expect(cache.touchedFilenames.contains("a.sqlite"))
    }

    @Test("replay 成功打开 → touch 该训练组")
    func replay_touchesOpenedFile() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: engine)
        await coord.endSession()
        _ = try await coord.replay(recordId: id!)
        #expect(cache.touchedFilenames.contains("a.sqlite"))
    }

    @Test("损坏训练组被删除而非 touch（startNewNormal 跳损坏选下一个）")
    func corruptFile_isDeletedNotTouched() async throws {
        // bad.sqlite 损坏 → 删除 + 重试；good.sqlite 成功 → touch。pickOverride 按 filename 升序，bad 先选。
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["bad.sqlite", "good.sqlite"], corrupt: ["bad.sqlite"])
        _ = try await coord.startNewNormalSession()
        #expect(cache.deletedFilenames.contains("bad.sqlite"))
        #expect(!cache.touchedFilenames.contains("bad.sqlite"), "损坏文件不应被 touch（已删）")
        #expect(cache.touchedFilenames == ["good.sqlite"], "仅成功打开的 good 被 touch")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter CacheTouchOnUseTests`
Expected: FAIL —— 5 个测试均 fail（`touchedFilenames` 为空，因生产代码尚未调 `cache.touch`）。

- [ ] **Step 3: Commit（红）**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/CacheTouchOnUseTests.swift
git commit -m "test(13a): cache touch-on-use 失败测试（4 read 路径 touch + 损坏不 touch）"
```

---

## Task 3: §A — 实现 touch-on-use（4 处 openReader 成功点）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`

- [ ] **Step 1: `startNewNormalSession` — opened 成功后 touch**

把 `:145-149` 的 do/catch 改为在成功赋值后 touch（在 while 循环内、仅成功分支）：

```swift
            do {
                let reader = try openReader(for: file)
                cache.touch(file)                          // §A touch-on-use（E6a-R3）：成功打开即刷 LRU mtime
                opened = (reader, file)
            } catch where isCorruptTrainingSet(error) {
                try? cache.delete(file)   // best-effort 删损坏训练组（可弃）：.fileNotFound=已删 / .diskFull=留待下次；均不阻重试
            }
```

- [ ] **Step 2: `resumePending` — openReader 成功后 touch**

在 `:183` `reader = try openReader(for: file)` 成功后（do/catch 结束、进入第二个 do 之前，约 `:188` 之后）加。具体：把 `:181-188` 的 reader 打开块改为：

```swift
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 同上（best-effort 可弃）：训练组损坏，孤儿 pending 不可恢复
            try pendingRepo.clearPending()                   // durable 清（app.sqlite 写，非删）
            return nil                                       // 首页降级到新局
        }
        cache.touch(file)                                    // §A touch-on-use：成功打开即刷 LRU mtime
```

- [ ] **Step 3: `review` — openReader 成功后 touch**

把 `:229-235` 的 reader 打开块改为，在成功 catch 块后加 touch：

```swift
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 同上（best-effort 可弃）：训练组损坏；record 仍在 app.sqlite（不删）
            throw AppError.persistence(.dbCorrupted)         // 无法替代，surface
        }
        cache.touch(file)                                    // §A touch-on-use：成功打开即刷 LRU mtime
```

- [ ] **Step 4: `replay` — openReader 成功后 touch**

把 `:266-272` 的 reader 打开块改为，在成功 catch 块后加 touch：

```swift
        let reader: any TrainingSetReader
        do {
            reader = try openReader(for: file)
        } catch where isCorruptTrainingSet(error) {
            try? cache.delete(file)                          // 同上（best-effort 可弃）：训练组损坏；record 仍在 app.sqlite（不删）
            throw AppError.persistence(.dbCorrupted)         // 无法替代，surface
        }
        cache.touch(file)                                    // §A touch-on-use：成功打开即刷 LRU mtime
```

- [ ] **Step 5: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter CacheTouchOnUseTests`
Expected: PASS（5/5）。

- [ ] **Step 6: 全量回归（不破既有）**

Run: `cd ios/Contracts && swift test`
Expected: PASS，总数 = baseline 972 + 5（新增）= 977，0 failures。

- [ ] **Step 7: Commit（绿）**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift
git commit -m "feat(13a): cache touch-on-use（E6a-R3）—— 4 read 路径成功打开后刷 LRU mtime"
```

---

## Task 4: §B.1 — `ToastState` host-testable 调度核 + 测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/ToastState.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/ToastStateTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("ToastState：latest-wins token 调度核（host-testable，§B.1）")
struct ToastStateTests {

    @Test("present 设置 message 并返回单调 token")
    func present_setsMessageAndToken() {
        var s = ToastState()
        let t1 = s.present("A")
        #expect(s.message == "A")
        let t2 = s.present("B")
        #expect(s.message == "B")
        #expect(t2 > t1)
    }

    @Test("过期旧 token 不清当前（latest-wins）")
    func expireStaleToken_keepsCurrent() {
        var s = ToastState()
        let t1 = s.present("A")
        _ = s.present("B")
        s.expire(token: t1)            // 旧 token 过期
        #expect(s.message == "B")      // 当前不被清
    }

    @Test("过期当前 token 清空 message")
    func expireCurrentToken_clears() {
        var s = ToastState()
        let t = s.present("A")
        s.expire(token: t)
        #expect(s.message == nil)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter ToastStateTests`
Expected: FAIL（`ToastState` 未定义）。

- [ ] **Step 3: 实现 `ToastState`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/ToastState.swift
// Kline Trainer Swift Contracts — 统一 Toast latest-wins 调度核（Wave 3 PR 13a §B.1）
//
// 平台无关纯值（host 全测）：把「latest-wins token + 何时清空」逻辑从 SwiftUI 壳抽出，使其可在
// swift test 确定性断言（壳层的 Task.sleep 计时留在 ToastOverlay/视图，调本结构的 expire）。
// 取代 Wave 3 顺位 7 内联于 TrainingView 的 toastToken/toastMessage（无 host 测）。

import Foundation

public struct ToastState: Equatable, Sendable {
    /// 当前展示的文案；nil = 无 toast。
    public private(set) var message: String?
    /// 单调递增 token：每次 present 递增，用于 latest-wins（晚来的覆盖早来的过期清空）。
    public private(set) var token: Int = 0

    public init() {}

    /// 展示新文案，返回本次 token。调用方据返回 token 安排过期回调。
    public mutating func present(_ message: String) -> Int {
        token += 1
        self.message = message
        return token
    }

    /// 过期指定 token：仅当它仍是最新 token 时清空 message（latest-wins，旧 token 过期 no-op）。
    public mutating func expire(token expiredToken: Int) {
        if token == expiredToken { message = nil }
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter ToastStateTests`
Expected: PASS（3/3）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/ToastState.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ToastStateTests.swift
git commit -m "feat(13a): ToastState latest-wins 调度核（§B.1 host-testable，3 tests）"
```

---

## Task 5: §B.1 — `ToastOverlay` 复用 SwiftUI modifier（Catalyst-gated）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/ToastOverlay.swift`

- [ ] **Step 1: 实现 content-agnostic toast overlay modifier**

把 TrainingView 内联的 `.overlay(.top)` 呈现（`:141-151` + `.animation` `:151`）抽为复用 modifier，行为字节对齐（top / regularMaterial Capsule / move+opacity transition / easeInOut 0.2）：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/ToastOverlay.swift
// Kline Trainer Swift Contracts — 统一非阻塞 Toast 呈现壳（Wave 3 PR 13a §B.1）
//
// content-agnostic SwiftUI 复用 modifier：行为字节对齐 Wave 3 顺位 7 TrainingView 内联 toast
// （顶部 / regularMaterial Capsule / move+opacity / easeInOut 0.2）。latest-wins/计时由调用方
// 持 ToastState 驱动（本壳只渲染传入 message）。薄 UI 壳，不 host 测；Catalyst 编译闸门守护。

#if canImport(UIKit)
import SwiftUI

public struct ToastOverlay: ViewModifier {
    let message: String?

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
    }
}

public extension View {
    /// 顶部非阻塞 toast。`message` 非 nil 时展示，nil 时隐去（带过渡动画）。
    func toastOverlay(_ message: String?) -> some View {
        modifier(ToastOverlay(message: message))
    }
}
#endif
```

- [ ] **Step 2: 编译确认（Catalyst，UIKit-gated）**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived-13a 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`（无 error/warning）。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/ToastOverlay.swift
git commit -m "feat(13a): ToastOverlay 复用 SwiftUI modifier（§B.1 呈现壳，Catalyst-gated）"
```

---

## Task 6: §B.1 — TrainingView 迁移 trade toast 到 ToastState + ToastOverlay

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift:33-34`（state）/ `:141-151`（overlay）/ `:230-238`（presentToast）

- [ ] **Step 1: 替换 toast `@State`（`:33-34`）**

把：

```swift
    @State private var toastMessage: String?
    @State private var toastToken = 0
```

改为：

```swift
    @State private var toast = ToastState()      // §B.1：latest-wins 调度核（host-tested）
```

- [ ] **Step 2: 替换 overlay（`:141-151`）为复用 modifier**

把 body 末尾的 `.overlay(alignment: .top) { ... }` + `.animation(... value: toastMessage)` 整段（`:141-151`）替换为：

```swift
        .toastOverlay(toast.message)             // §B.1 复用呈现壳（消费 ToastState.message）
```

- [ ] **Step 3: 替换 `presentToast`（`:230-238`）驱动 ToastState**

把：

```swift
    // latest-wins 自动消失 Toast（壳层 UX，不 host 测）。
    private func presentToast(_ message: String) {
        toastToken += 1
        let token = toastToken
        toastMessage = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toastToken == token { toastMessage = nil }
        }
    }
```

改为：

```swift
    // latest-wins 自动消失 Toast（驱动 host-tested ToastState；计时留壳层，不 host 测）。
    private func presentToast(_ message: String) {
        let token = toast.present(message)
        Task {
            try? await Task.sleep(for: .seconds(2))
            toast.expire(token: token)
        }
    }
```

- [ ] **Step 4: Catalyst 编译确认（行为对齐，trade toast 仍工作）**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived-13a 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`（无 error/warning）。`toastMessage`/`toastToken` 已无引用残留。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "refactor(13a): TrainingView trade toast 迁移到 ToastState+ToastOverlay（§B.1 行为不变）"
```

---

## Task 7: §B.2 — coordinator `autosaveBannerError` observable 信号字段 + 测试

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/AutosaveBannerTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("autosaveBannerError：autosave 失败的 UI 信号字段（§B.2，与 lastAutosaveError 解耦）")
@MainActor
struct AutosaveBannerTests {

    @Test("autosave 失败 → autosaveBannerError 置位（含 userMessage 可读错误）+ session 不 teardown")
    func failure_setsBanner_andDoesNotTeardown() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError == .persistence(.diskFull))
        #expect(coord.autosaveBannerError?.userMessage == "存储空间不足")
        #expect(coord.activeEngine === engine)               // 不 teardown
        #expect(coord.activeReader != nil)
    }

    @Test("autosave 成功 → autosaveBannerError 保持 nil")
    func success_keepsBannerNil() async throws {
        let (coord, _, _, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError == nil)
    }

    @Test("endSession 后 autosaveBannerError 清零（防 stale toast 跨局复活）")
    func endSession_clearsBanner() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let engine = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: engine, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError != nil)
        await coord.endSession()
        #expect(coord.autosaveBannerError == nil)
    }

    @Test("新 session 启动（resetAutosaveState）清零 banner")
    func newSession_clearsBanner() async throws {
        let (coord, _, pending, _) = PIFixtures.makeCoordinator()
        let e1 = try await coord.startNewNormalSession()
        pending.failNextSavePending = .persistence(.diskFull)
        coord.requestAutosave(engine: e1, immediate: true)
        await coord.drainAutosaveForTesting()
        #expect(coord.autosaveBannerError != nil)
        await coord.endSession()
        _ = try await coord.startNewNormalSession()           // resetAutosaveState 路径
        #expect(coord.autosaveBannerError == nil)
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter AutosaveBannerTests`
Expected: FAIL（`autosaveBannerError` 未定义）。

- [ ] **Step 3: 加 observable 字段（`:61` lastAutosaveError 之后）**

注意：**不**加 `@ObservationIgnored`（须可观察，供 SwiftUI re-render）。在 `lastAutosaveError`（`:61`）声明之后插入：

```swift
    /// §B.2（PR 13a）user-facing autosave 失败信号（observable，供 TrainingView toast）。
    /// 与内部 `lastAutosaveError`（@ObservationIgnored 机制状态）解耦：本字段仅作 UI re-render 信号，
    /// 不参与 autosave coalescing/fence 状态机。置位/清零与 `lastAutosaveError` 同步（catch / endSession / reset）。
    public private(set) var autosaveBannerError: AppError?
```

- [ ] **Step 4: autosave catch 同步置位（`:84-88`）**

把 autosave Task 内的 success/catch（`:82-88`）改为同步更新两字段：

```swift
                do {
                    try await self.saveProgress(engine: engine)
                    self.lastAutosaveError = nil
                    self.autosaveBannerError = nil                  // §B.2：成功清 UI 信号
                } catch {
                    let appError = (error as? AppError)
                        ?? .internalError(module: "E6b", detail: "autosave: \(error)")
                    self.lastAutosaveError = appError
                    self.autosaveBannerError = appError             // §B.2：失败置 UI 信号（observable → toast）
                }
```

- [ ] **Step 5: endSession 清零（`:405` lastAutosaveError = nil 之后）**

在 `endSession` 的 `lastAutosaveError = nil`（`:405`）之后插入：

```swift
        autosaveBannerError = nil                    // §B.2：清 UI 信号防跨局 stale toast
```

- [ ] **Step 6: resetAutosaveState 清零（`:510` lastAutosaveError = nil 之后）**

在 `resetAutosaveState` 的 `lastAutosaveError = nil`（`:510`）之后插入：

```swift
        autosaveBannerError = nil                    // §B.2：新 session 清 UI 信号
```

- [ ] **Step 7: 运行确认通过 + 全量回归**

Run: `cd ios/Contracts && swift test --filter AutosaveBannerTests`
Expected: PASS（4/4）。
Run: `cd ios/Contracts && swift test`
Expected: PASS（972 + 5 + 3 + 4 = 984），0 failures。**特别确认既有 `TrainingSessionAutosaveTests` 全过（lastAutosaveError 机制未被破坏）。**

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/AutosaveBannerTests.swift
git commit -m "feat(13a): coordinator autosaveBannerError observable 信号（§B.2，与 lastAutosaveError 解耦，4 tests）"
```

---

## Task 8: §B.2 — TrainingView 观察 autosaveBannerError → 弹 toast（Catalyst-gated）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift`（body `.onChange` 链）

- [ ] **Step 1: 加 `.onChange` 观察 coordinator 信号字段**

在 body 的 `.onChange(of: engine.drawings.count)`（`:91-93`）之后、`.sheet`（`:94`）之前，插入观察 coordinator 的 `autosaveBannerError`（穿过值类型 lifecycle wrapper，同 `engine.tick` 观察范式 `:77`）：

```swift
        .onChange(of: lifecycle.coordinator.autosaveBannerError) { _, newError in
            // §B.2：autosave 失败非阻塞 surface（不 teardown；与 finalize 失败 blocking alert 区分）。
            // shouldShowToast 过滤 .internalError 等不适合 toast 的错误。
            if let e = newError, e.shouldShowToast { presentToast(e.userMessage) }
        }
```

- [ ] **Step 2: Catalyst 编译确认**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived-13a 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`（无 error/warning）。

- [ ] **Step 3: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift
git commit -m "feat(13a): TrainingView 观察 autosaveBannerError → 非阻塞 toast（§B.2，RFC §4.6 item5）"
```

---

## Task 9: §B.3 — `DownloadBatchFeedback` 纯值 + 测试

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift`
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadBatchFeedbackTests.swift`

- [ ] **Step 1: 写失败测试**

```swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("DownloadBatchFeedback：下载批量 per-item 失败原因文案（§B.3，host 全测）")
struct DownloadBatchFeedbackTests {

    private func file(_ id: Int) -> TrainingSetFile {
        TrainingSetFile(id: id, filename: "f\(id).sqlite",
                        localURL: URL(fileURLWithPath: "/tmp/f\(id).sqlite"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    @Test("全成功 → toastMessage nil（无失败不打扰）")
    func allConfirmed_noToast() {
        let fb = DownloadBatchFeedback(results: [.confirmed(file(1)), .confirmed(file(2))])
        #expect(fb.toastMessage == nil)
    }

    @Test("部分失败 → 文案含失败数 + distinct userMessage")
    func partialFailure_listsDistinctReasons() {
        let fb = DownloadBatchFeedback(results: [
            .confirmed(file(1)),
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.network(.timeout))
        ])
        #expect(fb.toastMessage == "2 个失败：训练组文件校验失败 / 网络超时，请稍后重试")
    }

    @Test("重复原因去重（保序）")
    func duplicateReasons_deduped() {
        let fb = DownloadBatchFeedback(results: [
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.trainingSet(.crcFailed))
        ])
        #expect(fb.toastMessage == "2 个失败：训练组文件校验失败")
    }

    @Test("超过 maxReasons 截断（仅列前 N 个 distinct）")
    func reasonsTruncatedToMax() {
        let fb = DownloadBatchFeedback(results: [
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.trainingSet(.unzipFailed)),
            .rejected(.network(.offline)),
            .rejected(.persistence(.diskFull))
        ], maxReasons: 2)
        #expect(fb.toastMessage == "4 个失败：训练组文件校验失败 / 训练组解压失败 等")
    }
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter DownloadBatchFeedbackTests`
Expected: FAIL（`DownloadBatchFeedback` 未定义）。

- [ ] **Step 3: 实现 `DownloadBatchFeedback`**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift
// Kline Trainer Swift Contracts — 下载批量结果反馈纯值（Wave 3 PR 13a §B.3）
//
// 平台无关纯值（host 全测）：把 DownloadAcceptanceRunner.runBatch 的 [AcceptanceResult] 决策成
// 一条非阻塞 toast 文案——列出 per-item 失败的 distinct userMessage（此前 SettingsPanel 仅数成功、
// 丢弃失败原因）。沿用 TradeFeedback 范式（纯值，AppError.userMessage 单一文案源）。

import Foundation

public struct DownloadBatchFeedback: Equatable, Sendable {
    /// 需展示的失败 toast 文案；nil = 无失败（全成功，不打扰）。
    public let toastMessage: String?

    /// - Parameter maxReasons: 最多列出的 distinct 原因数（超出以「等」收尾），防文案过长。
    public init(results: [AcceptanceResult], maxReasons: Int = 3) {
        let failures: [AppError] = results.compactMap {
            if case .rejected(let e) = $0 { return e }
            return nil
        }
        guard !failures.isEmpty else { self.toastMessage = nil; return }

        // distinct userMessage 保序去重
        var seen = Set<String>()
        var distinct: [String] = []
        for e in failures {
            let msg = e.userMessage
            if seen.insert(msg).inserted { distinct.append(msg) }
        }

        let shown = distinct.prefix(maxReasons).joined(separator: " / ")
        let suffix = distinct.count > maxReasons ? " 等" : ""
        self.toastMessage = "\(failures.count) 个失败：\(shown)\(suffix)"
    }
}
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter DownloadBatchFeedbackTests`
Expected: PASS（4/4）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DownloadBatchFeedbackTests.swift
git commit -m "feat(13a): DownloadBatchFeedback 下载失败文案纯值（§B.3，4 tests）"
```

---

## Task 10: §B.3 — SettingsPanel 接线下载失败 toast（Catalyst-gated）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift:20-23`（state）/ `:33`（body 根）/ `:147-149`（startDownload 结果处理）

- [ ] **Step 1: 加 `toast` ToastState（`:23` isRecovering 之后）**

```swift
    @State private var toast = ToastState()   // §B.3：下载 per-item 失败原因非阻塞 toast
```

- [ ] **Step 2: body 根 VStack 加 `.toastOverlay`**

把 body 的 `.padding(24)`（`:78`）之后追加（在 `.alert` 链之前或之后均可，置于 `.padding(24)` 之后）：

```swift
        .toastOverlay(toast.message)
```

具体：在 `.padding(24)`（`:78`）这一行之后插入上面一行。

- [ ] **Step 3: startDownload 成功分支补失败原因 toast（`:147-149`）**

把：

```swift
                let lease = try await api.reserveTrainingSets(count: count)
                let results = await acceptance.runBatch(lease: lease)
                let ok = results.filter { if case .confirmed = $0 { return true }; return false }.count
                downloadStatus = "完成：\(ok)/\(results.count) 成功"
```

改为：

```swift
                let lease = try await api.reserveTrainingSets(count: count)
                let results = await acceptance.runBatch(lease: lease)
                let ok = results.filter { if case .confirmed = $0 { return true }; return false }.count
                downloadStatus = "完成：\(ok)/\(results.count) 成功"
                // §B.3：per-item 失败原因非阻塞 toast（此前丢弃）；进度/aggregate 仍由 downloadStatus 标签呈现。
                if let message = DownloadBatchFeedback(results: results).toastMessage {
                    presentDownloadToast(message)
                }
```

- [ ] **Step 4: 加 `presentDownloadToast` helper（startDownload 之后）**

在 `startDownload()` 方法（`:154` 闭合 `}`）之后插入：

```swift
    // latest-wins 自动消失 Toast（驱动 host-tested ToastState；计时留壳层）。
    private func presentDownloadToast(_ message: String) {
        let token = toast.present(message)
        Task {
            try? await Task.sleep(for: .seconds(2))
            toast.expire(token: token)
        }
    }
```

- [ ] **Step 5: Catalyst 编译确认**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived-13a 2>&1 | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`（无 error/warning）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift
git commit -m "feat(13a): SettingsPanel 下载 per-item 失败原因 toast（§B.3，复用 ToastState+ToastOverlay）"
```

---

## Task 11: 非-coder 验收清单 + 全量验证

**Files:**
- Create: `docs/acceptance/2026-06-14-wave3-pr13a-robustness.md`

- [ ] **Step 1: 写验收清单**

```markdown
# PR Wave 3 13a 验收清单（中文非-coder 可执行）

**PR 范围**：§A cache touch-on-use（E6a-R3）+ §B 边界错误统一 Toast 层（autosave 失败可见 + 下载 per-item 失败可见）。改 `ios/**/*.swift`（trust-boundary → codex review）+ 新增 host 测；0 schema/DDL/CI 改动。

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 6 个 `.swift` 改/增 + 4 个测试文件 + 本 acceptance | □ Pass / □ Fail |
| 2 | 看 `TrainingSessionCoordinator.swift` diff | 4 处 read 路径（startNewNormalSession/resumePending/review/replay）成功打开后均新增 `cache.touch(file)` | □ Pass / □ Fail |
| 3 | 看 `CacheTouchOnUseTests.swift` | 含 5 测试：4 read 路径 touch + 损坏文件不 touch（被删） | □ Pass / □ Fail |
| 4 | 看 `ToastState.swift` | 纯值 struct，`present` 返单调 token、`expire(token:)` 仅清最新 token（latest-wins） | □ Pass / □ Fail |
| 5 | 看 `ToastStateTests.swift` | 含 3 测试：present 设值 / 旧 token 过期不清当前 / 当前 token 过期清空 | □ Pass / □ Fail |
| 6 | 看 `TrainingSessionCoordinator.swift` 的 `autosaveBannerError` | observable（无 `@ObservationIgnored`）；autosave catch 置位、endSession/resetAutosaveState 清零 | □ Pass / □ Fail |
| 7 | 看 `AutosaveBannerTests.swift` | 含 4 测试：失败置位+不 teardown / 成功保持 nil / endSession 清零 / 新 session 清零 | □ Pass / □ Fail |
| 8 | 看 `TrainingView.swift` diff | toast 迁移到 `toast = ToastState()` + `.toastOverlay(toast.message)`；新增 `.onChange(of: lifecycle.coordinator.autosaveBannerError)` 弹 toast | □ Pass / □ Fail |
| 9 | 看 `DownloadBatchFeedbackTests.swift` | 含 4 测试：全成功无 toast / 部分失败列 distinct 原因 / 去重 / 超 max 截断 | □ Pass / □ Fail |
| 10 | 看 `SettingsPanel.swift` diff | 保留 `downloadStatus` 进度标签；新增失败原因 toast（`DownloadBatchFeedback` + `.toastOverlay`） | □ Pass / □ Fail |
| 11 | 看 CI 「Mac Catalyst build-for-testing on macos-15」 | 绿（TEST BUILD SUCCEEDED） | □ Pass / □ Fail |
| 12 | 看 CI 「swift test on macos-15」 | 绿（全量 test pass，新增 16 测试无失败） | □ Pass / □ Fail |
| 13 | 看 codex 对抗 review verdict | APPROVE（或 codex 配额耗尽→opus 4.8 xhigh fallback APPROVE） | □ Pass / □ Fail |

## 范围守卫（blocking 错误不被改造）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 14 | 看 `TrainingView.swift` finalize/back 失败处理 | 仍为 blocking alert（`finalizeFailed`/`backFailed`，retry/放弃），**未**被改成 toast | □ Pass / □ Fail |
| 15 | 看 `AppRouter.errorMessage` / app.sqlite fail-closed | 未被本 PR 触碰（保留 blocking alert + §4.7f 安全红线） | □ Pass / □ Fail |
```

- [ ] **Step 2: 全量 host 测**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: `Test run with 988 tests in N suites passed`（baseline 972 + §A 5 + §B.1 3 + §B.2 4 + §B.3 4 = 988），0 failures。

- [ ] **Step 3: Catalyst 全量编译闸门**

Run: `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived-13a 2>&1 | grep -E "TEST BUILD SUCCEEDED|error:|warning:" | tail -5`
Expected: `** TEST BUILD SUCCEEDED **`，无 error/warning。

- [ ] **Step 4: Commit**

```bash
git add docs/acceptance/2026-06-14-wave3-pr13a-robustness.md
git commit -m "docs(13a): 非-coder 验收清单（cache touch-on-use + 统一 Toast）"
```

---

## Self-Review（写计划后核对 spec §A/§B）

- **spec §A 覆盖**：4 read 路径 touch（Task 3）+ 损坏不 touch + listAvailable 不 touch（listAvailable 未被改，符合「存在性检查不 touch」§A 不变量）。✓
- **spec §B.1 覆盖**：host-testable 调度核 `ToastState`（Task 4）+ 复用呈现壳 `ToastOverlay`（Task 5）+ TrainingView 迁移（Task 6）。✓ 取代空头 snapshot 守护。
- **spec §B.2 覆盖**：observable 信号字段（Task 7）+ Observation 路径（穿值类型 lifecycle，复用 `:77` 范式，Task 8）+ clear-on-teardown（endSession/resetAutosaveState，Task 7 Step 5/6 + 测试覆盖）。✓ 两个 load-bearing 点均坐实。
- **spec §B.3 覆盖**：`DownloadBatchFeedback`（Task 9）+ SettingsPanel 接线保留 status 标签（Task 10）。✓
- **spec §B 处置表覆盖**：autosave→新 toast（§B.2）、下载 per-item→新 toast（§B.3）、blocking alert 保留（acceptance Step 14/15 守卫）。✓
- **类型一致性**：`ToastState.present→Int token`、`expire(token:)`、`toastOverlay(_:)`、`autosaveBannerError: AppError?`、`DownloadBatchFeedback(results:maxReasons:).toastMessage` 全文一致。✓
- **placeholder 扫描**：无 TBD/TODO；每步含完整代码或确切命令 + 预期。✓

---

## Execution Handoff

执行用 **superpowers:subagent-driven-development**（fresh subagent per task + 两道 review）。Task 间串行（多任务改同文件 coordinator/TrainingView，须顺序）。
