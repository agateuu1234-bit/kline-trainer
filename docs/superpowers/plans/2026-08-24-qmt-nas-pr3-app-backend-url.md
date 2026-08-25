# QMT NAS 部署 · PR-3「App 后端地址可配（debug-only）」Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ⚠️ 本 plan 的分支从 PR-2 合并后的 `origin/main` 切出。与 PR-1 / PR-2 **零文件重叠**（本 PR 只碰 `ios/`），但按次序切分支可以避免任何 rebase 意外。

**Goal:** 让 Debug 构建的 App 能通过一个环境变量指定后端地址，从而在真机上连到 NAS；生产（Release）构建行为**完全不变**。

**Architecture:** 判定逻辑做成 `KlineTrainerPersistence` 包里的**纯函数**（收字典 + 回落地址，返回地址），组合根只剩一行调用并用 `#if DEBUG` 包住。之所以下沉到包里：`KlineTrainerApp.swift` 在 app target 里，**host 测试套件根本编译不到它**，逻辑写在那儿等于零测试覆盖、无法变异验证。

**Tech Stack:** Swift 6.0 · Swift Testing · SwiftPM（`ios/Contracts`）

**Spec:** `docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md` §6（契约表 + R1/R2/R3 判据）与 §4-D4（形状决策）、§13.0（措辞纪律）

---

## Global Constraints

1. **⛔ 措辞纪律（spec §13.0，硬要求）**：本 PR 的任何文档 / 提交信息 / PR 描述 / 代码注释**不得**出现「PR11-R1 已关闭」「生产后端地址已接通」「backendBaseURL 已可配置」（不带限定）。提到时**必须**带 **debug-only** 限定。理由：Release 构建仍然回落到硬编码的 `http://kline-trainer.local`，上架阻塞**依然存在**；把「Debug 演示能过」说成「生产阻塞已解」是本仓 Wave 3 点名过的 overclaim。
2. **本次不做 Release 配置通道**（Info.plist / xcconfig）——user 已定，属正式部署决定（spec §6.3）。
3. **不改** ATS、不改 `project.pbxproj`、不动 `DefaultAPIClient` 的任何逻辑（spec §6.3）。
4. **每条新测试必须变异验证**，控制者亲跑。Swift 侧变异同样用 `cp` 备份/复原，⛔ 不用 `git checkout <file>`。
5. **判别力要求（spec §6.2）**：R1-3…R1-8 是一整族「应该回落」的档，**必须**配 R1-1 / R1-2 两条正向档 —— 否则一个「无条件返回 fallback」的空实现会让整族全绿（`feedback_all_reject_suite_masks_always_throwing_guard` 同型）。变异时须逐条中和**对应的那一条**判据，并记录**红的是具名的哪一条**。
6. **源码守卫必须剥注释再判**（`feedback_source_guard_text_source_discipline`）：当前组合根那一行尾部有 `// TODO(NAS) PR11-R1：部署后替换` 注释，改完会删，但判据**不得**依赖注释的存在或消失。
7. **Catalyst 闸门**：本 PR 往 `KlineTrainerContractsTests` 新增 2 条测试。该门的总用例数基线是 `.github/scripts/catalyst-total-baseline.txt` = **1745**，容差 `DELTA=30`（实测）→ 1747 落在窗口内，**无需**改基线。新增测试**不是** UIKit-gated（不在 `#if canImport(UIKit)` 块里）→ `catalyst-uikit-baseline.txt`（75 行）**不需要**改。⚠️ 但仍须真跑一次 Catalyst 确认，别按推演判过。

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift` | 修改 | 新增一个 `public static` 纯函数 + 环境变量名常量。**不改** `AppConfig` 结构体既有的三个存储属性与 `init`。 |
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppConfigBackendURLTests.swift` | 新建 | R1 族：纯函数的 8 条契约档 + 2 条正向档 + 拼接形状锁。 |
| `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift` | 修改 | 组合根接线：`#if DEBUG` 下调用纯函数，非 DEBUG 走原字面量。删掉那条 TODO 注释。 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/AppCompositionRootSourceGuardTests.swift` | 新建 | R2 族：源码守卫。**刻意放在 ContractsTests 而不是 PersistenceTests** —— 因为剥注释/剥字面量的扫描器 `SourceGuardScanner.swift` 在那个 target 里，而 Swift 的 import 是**文件级**的，跨 target 用不了。重写一份词法器就是本仓一路在批评的「同一件事有两份能力不同的实现」。 |

---

## Task 1: `AppConfig` 的纯函数（spec §6.1 契约表 / R1 族）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppConfigBackendURLTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `AppConfig.backendBaseURLEnvironmentKey: String` == `"KLINE_BACKEND_BASE_URL"`
  - `AppConfig.resolveBackendBaseURL(environment: [String: String], fallback: URL) -> URL`
  - Task 2 的组合根调用这个函数；Task 2 的源码守卫按**这个函数名**扫。

- [ ] **Step 1: 先写失败测试**

新建 `ios/Contracts/Tests/KlineTrainerPersistenceTests/AppConfigBackendURLTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerPersistenceTests/AppConfigBackendURLTests.swift
// spec 2026-08-14 §6.1 契约表 / §6.2 R1 族。
//
// 为什么判定逻辑在包里而不在组合根（spec §4-D4）：KlineTrainerApp.swift 在 app target 里，
// host 测试套件**根本编译不到它** —— 逻辑写在那儿等于零测试覆盖、无法变异验证。
// 这里是纯函数：收字典 + 回落地址，返回地址；不读 ProcessInfo，故任何配置下都可测。
import Foundation
import Testing
@testable import KlineTrainerPersistence

private let fallback = URL(string: "http://kline-trainer.local")!
private let key = AppConfig.backendBaseURLEnvironmentKey

private func resolve(_ value: String?) -> URL {
    AppConfig.resolveBackendBaseURL(
        environment: value.map { [key: $0] } ?? [:],
        fallback: fallback)
}

// MARK: 正向档（R1-1 / R1-2）——没有这两条，整个「应该回落」族会被空实现全绿放过

@Test("R1-1 合法 https 地址被采用")
func adoptsValidHTTPSURL() {
    #expect(resolve("https://fnos.tail9dc815.ts.net")
            == URL(string: "https://fnos.tail9dc815.ts.net")!)
}

@Test("R1-2 合法 http 地址被采用")
func adoptsValidHTTPURL() {
    #expect(resolve("http://192.168.5.229:8010")
            == URL(string: "http://192.168.5.229:8010")!)
}

// MARK: 回落族（R1-3 … R1-8）

@Test("R1-3 键缺失 → 回落")
func fallsBackWhenKeyMissing() {
    #expect(resolve(nil) == fallback)
}

@Test("R1-4 空串 → 回落")
func fallsBackOnEmptyString() {
    #expect(resolve("") == fallback)
}

@Test("R1-5 全空白 → 回落")
func fallsBackOnWhitespaceOnly() {
    #expect(resolve("   \t\n ") == fallback)
}

@Test("R1-6 不成形的文本 → 回落")
func fallsBackOnMalformedText() {
    // ⚠️ 别把这条写成「URL(string:) 返回 nil」——实测（2026-08-24）现代 Foundation 里
    //    URL(string: "not a url") **不返回 nil**，它会把空格百分号编码掉。
    //    真正挡住它的是下面 R1-7 那条 scheme 判据（这里 scheme 为 nil）。
    #expect(resolve("not a url") == fallback)
    #expect(resolve("hello") == fallback)
}

@Test("R1-7 scheme 不在 {http, https} → 回落")
func fallsBackOnForeignScheme() {
    #expect(resolve("file:///tmp/x") == fallback)
    #expect(resolve("ftp://example.com") == fallback)
}

@Test("R1-8 无 host → 回落")
func fallsBackWhenHostMissing() {
    // 实测：URL(string: "https:///path") 的 scheme 是 https 而 host 是 nil —— 只有
    // host 判据拦得住它。少了这条，App 会拿着一个连不上的地址去请求。
    #expect(resolve("https:///path") == fallback)
}

@Test("R1-7b scheme 大小写不敏感")
func acceptsUppercaseScheme() {
    #expect(resolve("HTTPS://fnos.tail9dc815.ts.net")
            == URL(string: "HTTPS://fnos.tail9dc815.ts.net")!)
}

// MARK: 形状锁（R1-9）

@Test("R1-9 base 带不带结尾斜杠，拼出的请求地址一致且正确")
func trailingSlashDoesNotChangeRequestURL() {
    // DefaultAPIClient 用 baseURL.appending(path:) 拼（实测 DefaultAPIClient.swift:32/49/68）。
    let withoutSlash = resolve("https://fnos.tail9dc815.ts.net")
    let withSlash = resolve("https://fnos.tail9dc815.ts.net/")
    #expect(withoutSlash.appending(path: "training-sets/meta")
            == withSlash.appending(path: "training-sets/meta"))
    #expect(withoutSlash.appending(path: "training-sets/meta").absoluteString
            == "https://fnos.tail9dc815.ts.net/training-sets/meta")
}

@Test("环境变量名就是 spec 定的那个（与 KLINE_SEED_FIXTURE 同前缀）")
func environmentKeyIsStable() {
    #expect(AppConfig.backendBaseURLEnvironmentKey == "KLINE_BACKEND_BASE_URL")
}
```

- [ ] **Step 2: 跑测试确认红（编译不过）**

```bash
cd "<worktree>/ios/Contracts" && swift test 2>&1 | tail -25
```

预期：**编译失败**，报 `AppConfig` 没有 `backendBaseURLEnvironmentKey` / `resolveBackendBaseURL` 成员。这就是 TDD 的先红。

- [ ] **Step 3: 实现纯函数**

在 `ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift` 末尾追加：

```swift
public extension AppConfig {
    /// Debug 构建下用来覆盖后端地址的环境变量名（与既有 `KLINE_SEED_FIXTURE` 同前缀）。
    static var backendBaseURLEnvironmentKey: String { "KLINE_BACKEND_BASE_URL" }

    /// 从环境变量字典解析后端地址；**任何**不可用的取值一律回落到 `fallback`（spec §6.1 契约表）。
    ///
    /// 刻意收字典而不是直接读 `ProcessInfo`：组合根在 app target 里，host 测试套件编译不到，
    /// 逻辑写在那儿等于零覆盖。这里是纯函数，任何配置下都可测、可变异验证（spec §4-D4）。
    ///
    /// 判据次序（每一条都有对应的测试档，少一条就会放一个连不上的地址进 App）：
    ///   1. 键缺失 / 空串 / 全空白 → 回落；
    ///   2. `URL(string:)` 失败 → 回落。⚠️ 别指望这一条拦住"不成形的文本"——实测现代
    ///      Foundation 会把 `"not a url"` 的空格编码掉并返回一个 URL，真正拦住它的是第 3 条；
    ///   3. scheme 不在 {http, https}（大小写不敏感）→ 回落；
    ///   4. 无 host（如 `https:///path`，scheme 合法但 host 为 nil）→ 回落。
    static func resolveBackendBaseURL(environment: [String: String], fallback: URL) -> URL {
        guard let raw = environment[backendBaseURLEnvironmentKey] else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard let url = URL(string: trimmed) else { return fallback }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return fallback
        }
        guard let host = url.host(), !host.isEmpty else { return fallback }
        return url
    }
}
```

- [ ] **Step 4: 跑测试确认全绿**

```bash
cd "<worktree>/ios/Contracts" && swift test 2>&1 | tail -15
```

⚠️ 若出现 `@Observable` / 增量构建相关的 SIGSEGV，先 `rm -rf .build/arm64-apple-macosx` 再判断（`feedback_swiftpm_stale_build_sigsegv`）。

- [ ] **Step 5: 变异验证 —— 逐条中和判据，记录红的具名测试**

| 编号 | 变异（改 `resolveBackendBaseURL`） | 应变红的具名测试 |
|---|---|---|
| M-空实现 | 整个函数体改成 `return fallback` | `adoptsValidHTTPSURL` + `adoptsValidHTTPURL` + `acceptsUppercaseScheme` + `trailingSlashDoesNotChangeRequestURL` |
| M-恒采纳 | 删掉全部 guard，改成 `return URL(string: environment[backendBaseURLEnvironmentKey] ?? "") ?? fallback` | 回落族的多条（把实际具名清单抄下来） |
| R1-4/5 | 删掉 `guard !trimmed.isEmpty` 那一行 | `fallsBackOnEmptyString` + `fallsBackOnWhitespaceOnly` |
| R1-7 | 删掉 scheme 判据整条 guard | `fallsBackOnForeignScheme` **和** `fallsBackOnMalformedText`（后者证明"不成形文本"其实是被 scheme 判据拦住的，不是被 `URL(string:)`） |
| R1-8 | 删掉 host 判据整条 guard | `fallsBackWhenHostMissing` |
| R1-7b | `url.scheme?.lowercased()` → `url.scheme` | `acceptsUppercaseScheme` |
| R1-3 | 首行 guard 改成 `let raw = environment[...] ?? ""` 后继续 | 应仍全绿（等价变异）—— **识别并登记为等价变异**，别硬凑一条测试（`feedback_mutation_false_negatives_two_shapes`） |

⚠️ 「R1-7 那一档同时打红两条」是**有意的**：它证明 `fallsBackOnMalformedText` 的归因是 scheme 判据而不是 `URL(string:)`。**结论对不代表归因对**，归因要单独核。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppConfigBackendURLTests.swift
git commit -m "feat(ios): AppConfig 新增后端地址解析纯函数（debug 通道用）

判定逻辑下沉到 KlineTrainerPersistence 包：组合根在 app target 里，host 测试套件
根本编译不到它，逻辑写在那儿等于零覆盖、无法变异验证。

四道判据各配一档测试：缺失/空串/全空白、URL 解析失败、scheme 不在 {http,https}、
无 host。⚠️ 实测现代 Foundation 的 URL(string:) 不会对 \"not a url\" 返回 nil
（空格会被编码），真正拦住不成形文本的是 scheme 判据 —— 注释里写明了归因。

回落族配两条正向档，否则一个无条件回落的空实现会让整族全绿。"
```

---

## Task 2: 组合根接线 + 源码守卫（spec §6.1 组合根 / R2 / R3）

**Files:**
- Modify: `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift:16`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/AppCompositionRootSourceGuardTests.swift`

**Interfaces:**
- Consumes: `AppConfig.resolveBackendBaseURL(environment:fallback:)`（Task 1）
- Produces: Debug 构建下可经 `KLINE_BACKEND_BASE_URL` 指定后端地址。runbook 的 P13 依赖这一点。

- [ ] **Step 1: 先写失败的源码守卫**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/AppCompositionRootSourceGuardTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/AppCompositionRootSourceGuardTests.swift
// spec 2026-08-14 §6.2 R2 族：组合根源码守卫。
//
// 为什么放在 ContractsTests 而不是 PersistenceTests：剥注释/剥字符串字面量的词法扫描器
// (SourceGuardScanner.swift) 在这个 target 里，而 Swift 的 import 是**文件级**的，跨
// target 用不了。重写一份词法器就是本仓一路在批评的「同一件事有两份能力不同的实现」。
//
// 为什么必须剥注释再判（feedback_source_guard_text_source_discipline）：改动前那一行
// 尾部带 `// TODO(NAS) PR11-R1：部署后替换` 注释，改完会删；判据**不得**依赖注释的
// 存在或消失，否则它测的是注释不是代码。
import Foundation
import Testing

/// `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift` 的绝对路径。
/// 由本文件路径回推：Tests/KlineTrainerContractsTests/<本文件> → 上溯 3 层到 ios/Contracts
/// → 再上溯 1 层到 ios/（既有守卫已实证这条路走得通，spec §2.1）。
private var compositionRootPath: String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // KlineTrainerContractsTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // ios/Contracts
        .deletingLastPathComponent()          // ios
        .appendingPathComponent("KlineTrainer/KlineTrainer/KlineTrainerApp.swift")
        .path
}

private let resolverCall = "AppConfig.resolveBackendBaseURL("

/// 剥注释与字符串字面量、删光空白后的组合根源码。
private func squeezedCompositionRoot() throws -> String {
    try squeezedSource(compositionRootPath)
}

/// squeezed 文本里「`#if DEBUG` 生效区」的片段集合。
/// squeeze 把空白全删了，所以 `#if DEBUG` 变成 `#ifDEBUG`；每段取到最近的
/// `#else` 或 `#endif` 为止（`#else` 之后是非 DEBUG 分支，不算生效区）。
private func debugActiveRegions(_ squeezed: String) -> [String] {
    squeezed.components(separatedBy: "#ifDEBUG").dropFirst().map { segment in
        let end = [segment.range(of: "#else"), segment.range(of: "#endif")]
            .compactMap { $0?.lowerBound }
            .min() ?? segment.endIndex
        return String(segment[segment.startIndex..<end])
    }
}

@Test("R2-0 守卫真的读到了组合根文件（防负向断言假绿）")
func compositionRootIsReadable() throws {
    let squeezed = try squeezedCompositionRoot()
    #expect(!squeezed.isEmpty, "读到的组合根源码是空的 —— 路径推导已失效，下面的断言会恒真")
    #expect(squeezed.contains("AppConfig("), "组合根里找不到 AppConfig( 构造 —— 路径可能指错了文件")
}

@Test("R2-1 组合根经解析函数取后端地址，不是直接写死一个字面量")
func compositionRootUsesResolver() throws {
    let squeezed = try squeezedCompositionRoot()
    let occurrences = squeezed.components(separatedBy: resolverCall).count - 1
    #expect(occurrences == 1, "期望恰好 1 处 \(resolverCall) 调用，实际 \(occurrences) 处")
    #expect(!squeezed.contains("backendBaseURL:URL(string:"),
            "backendBaseURL 实参仍是字面量 URL —— debug 通道没有接上")
}

@Test("R2-2 该调用被 #if DEBUG 包住（Release 二进制不读环境变量）")
func resolverCallIsDebugOnly() throws {
    let squeezed = try squeezedCompositionRoot()
    let total = squeezed.components(separatedBy: resolverCall).count - 1
    let insideDebug = debugActiveRegions(squeezed)
        .reduce(0) { $0 + ($1.components(separatedBy: resolverCall).count - 1) }
    #expect(total >= 1, "组合根里没有解析函数调用 —— 本条判据够不着（fail-closed）")
    #expect(insideDebug == total,
            "有 \(total - insideDebug) 处解析调用在 #if DEBUG 之外 —— Release 会读环境变量")
}
```

⚠️ `squeezedSource(_:)` 来自同 target 的 `SourceGuardScanner.swift`（它剥行注释 / 嵌套块注释 / 字符串字面量内容并删光空白），**不要**在本文件里另写一份。

- [ ] **Step 2: 跑测试确认红**

```bash
cd "<worktree>/ios/Contracts" && swift test --filter AppCompositionRoot 2>&1 | tail -20
```

预期：`compositionRootIsReadable` **绿**（证明路径推导正确），`compositionRootUsesResolver` 与 `resolverCallIsDebugOnly` **红**（组合根还没改）。

⚠️ 如果 `compositionRootIsReadable` 也红，先修路径推导，别往下走 —— 一条读不到文件的守卫会让另外两条恒真通过。

- [ ] **Step 3: 改组合根**

把 `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift` 的 `init()` 里那段改为：

```swift
            let fm = FileManager.default
            let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            // 生产（Release）仍然是这个硬编码占位地址 —— PR11-R1 依旧 OPEN，
            // Release 配置通道（Info.plist / xcconfig）不在本次范围内。
            let fallbackBackendBaseURL = URL(string: "http://kline-trainer.local")!
            // debug-only 通道：仅 Debug 构建读 KLINE_BACKEND_BASE_URL，用于真机连 NAS 验收。
            // 判定逻辑在 KlineTrainerPersistence 里的纯函数（本文件在 app target，测不到）。
            #if DEBUG
            let backendBaseURL = AppConfig.resolveBackendBaseURL(
                environment: ProcessInfo.processInfo.environment,
                fallback: fallbackBackendBaseURL)
            #else
            let backendBaseURL = fallbackBackendBaseURL
            #endif
            let cfg = AppConfig(dbPath: support.appendingPathComponent("app.sqlite"),
                                cacheRootDir: caches.appendingPathComponent("training-sets"),
                                backendBaseURL: backendBaseURL)
```

⚠️ 原来那条 `// TODO(NAS) PR11-R1：部署后替换` 注释删掉（它描述的动作已经做了一半），但**不要**在任何地方写「PR11-R1 已关闭」——Release 仍是占位地址。

- [ ] **Step 4: 跑测试确认三条全绿**

- [ ] **Step 5: 跑整包 `swift test`，确认 R3-1 回归**

```bash
cd "<worktree>/ios/Contracts" && swift test 2>&1 | tail -15
```

预期：全绿。特别核 `AppContainerTests` / `AppContainerDebugSeedTests` 仍绿 —— 它们**直接构造** `AppConfig`、不经解析函数（spec §2.1 实测），所以本改动不该影响它们。

- [ ] **Step 6: 变异验证**

| 编号 | 变异 | 应变红的具名测试 |
|---|---|---|
| R2-1a | 组合根改回 `backendBaseURL: URL(string: "http://kline-trainer.local")!`，删掉解析调用 | `compositionRootUsesResolver`（`occurrences == 0`）+ `resolverCallIsDebugOnly`（fail-closed 那条） |
| R2-1b | 保留解析调用，但把 `AppConfig(` 的 `backendBaseURL:` 实参换回 `URL(string:...)!` 字面量 | `compositionRootUsesResolver`（第二条断言） |
| R2-2 | 把 `#if DEBUG` / `#else` / `#endif` 三行删掉（解析调用裸露在外） | `resolverCallIsDebugOnly` |
| R2-0 | 把 `compositionRootPath` 少上溯一层（指到不存在的路径） | `compositionRootIsReadable`（应抛错或空串红） |
| 剥注释纪律 | 在解析调用那一行后面加一句 `// AppConfig.resolveBackendBaseURL(` 注释 | **三条都应保持绿**（证明判据读的是剥注释后的代码，注释里的同名文本不计数）。若 `compositionRootUsesResolver` 变红说明扫描器没剥注释 —— 那是真缺陷。 |

⚠️ 最后一档是**反向自检**：它证明守卫没有被注释文本污染。本仓的源码守卫纪律要求每加一种扫描能力就配**双向**自检。

- [ ] **Step 7: Commit**

```bash
git add ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/AppCompositionRootSourceGuardTests.swift
git commit -m "feat(ios): 组合根接上后端地址解析（debug-only 通道）

仅 Debug 构建读 KLINE_BACKEND_BASE_URL；Release 仍回落到硬编码占位地址
http://kline-trainer.local —— PR11-R1 依旧 OPEN，Release 配置通道（Info.plist /
xcconfig）不在本次范围内，上架阻塞依然存在。

源码守卫三条：解析调用恰好 1 处、backendBaseURL 实参不是字面量、调用全部落在
#if DEBUG 生效区内。判据读的是剥注释剥字面量后的代码，并配了一条反向自检
（在调用行后加同名注释，三条应保持绿）。"
```

---

## Task 3: 非程序员验收清单

**Files:**
- Create: `docs/superpowers/plans/2026-08-24-qmt-nas-pr3-acceptance.md`

- [ ] **Step 1: 写清单**

必须包含（三列：动作 / 预期 / 通过条件）：

| 动作 | 预期 | 通过条件 |
|---|---|---|
| 在 `ios/Contracts` 目录粘贴 `swift test` | 跑几分钟后打印统计 | 出现 `passed`，**不含** `failed` / `error` |
| 打开 `ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift` | 看到 App 启动代码 | 文件里能看到 `#if DEBUG` 这一行，**且** `AppConfig.resolveBackendBaseURL` 出现在它下面 |

以及**必须写明本 PR 没做到的事**（防误以为完成）：

- Release（正式）构建的后端地址**仍然是**写死的占位地址，上架阻塞**依然存在**；
- 本 PR **不涉及** NAS、不部署任何东西、手机此刻仍拉不到训练组；
- 环境变量只在 `devicectl` 那次启动的进程里有效，**从桌面图标点开 App 不带这个变量**，地址会回落到占位值 —— 这不影响已经下载到本地的训练组（离线可看可练）。

- [ ] **Step 2: Commit**

---

## 收尾：绿门（控制者亲跑）

- [ ] 门 1 · `cd ios/Contracts && swift test` 全绿（先打印 branch/HEAD）
- [ ] 门 2 · **真跑 Catalyst 门**（本地 `xcodebuild test` 对新增测试是否被编译**有判别力盲区**，且 library scheme 不编译 testTarget）：
  ```bash
  set -o pipefail
  cd "<worktree>/ios/Contracts"
  rm -rf /tmp/derived-pr3            # 冷构建：闸门自证项依赖构建日志，增量构建会缺行
  xcodebuild test \
    -scheme KlineTrainerContracts-Package \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -only-testing:KlineTrainerContractsTests \
    -derivedDataPath /tmp/derived-pr3 2>&1 | tee /tmp/catalyst-pr3.log
  bash "<仓库根>/.github/scripts/catalyst-gate.sh" /tmp/catalyst-pr3.log
  ```
  ⚠️ **必须**是 `KlineTrainerContracts-Package`（library scheme **不编译 testTarget**，该门曾因此报绿半年）；⚠️ **必须** `set -o pipefail`（`tee` 会吞退出码）；两坑叠加会出现「命令成功退出码 0 但零测试执行」。
- [ ] 门 3 · 从门 2 的日志里读**实际执行的用例数**，确认落在 `1745 ± 30` 内。若越界，须同步更新 `.github/scripts/catalyst-total-baseline.txt` 并在 PR 里说明（**不是**放宽 delta）。
- [ ] 门 4 · 变异账目齐全（Task 1 七行 + Task 2 五行，每行都有红的具名测试实测记录）
- [ ] 门 5 · `git status --porcelain` 零输出
- [ ] 门 6 · `git diff --stat origin/main...HEAD` 文件清单与 File Structure 一致
- [ ] 门 7 · **措辞自检**：`git log origin/main..HEAD` + PR 描述里搜「PR11-R1 已关闭」「生产后端地址已接通」「backendBaseURL 已可配置」，必须**零命中**

## 收尾：对抗性评审

命令与纪律同 PR-1。

---

## Self-Review

**1. spec 覆盖**：§6.1 契约表 8 行 → Task 1 的 R1-1..R1-8 逐条；组合根形状 → Task 2 Step 3；R1-9 → Task 1 的 `trailingSlashDoesNotChangeRequestURL`；R2-1 / R2-2 → Task 2 两条守卫；R3-1 → Task 2 Step 5；§6.3 明确不做（Release 通道 / ATS / pbxproj / DefaultAPIClient）→ Global Constraints 第 2、3 条；§13.0 措辞纪律 → Global Constraints 第 1 条 + 收尾门 7。
**2. 占位符扫描**：无 TBD / TODO（组合根里那条 TODO 注释是**被删掉**的对象，不是遗留）。
**3. 类型一致性**：`resolveBackendBaseURL(environment:fallback:)` 与 `backendBaseURLEnvironmentKey` 在 Task 1 定义、Task 2 组合根调用、Task 2 守卫的 `resolverCall` 常量三处同名；测试函数名在定义处与两张变异表逐条同名。
