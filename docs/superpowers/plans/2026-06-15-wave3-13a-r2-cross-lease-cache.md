# Wave 3 13a-R2 跨 lease cache 误删修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 `DownloadAcceptanceRunner` 在确认拒收时按 trainingSetId-only 删除 cache 文件、导致删掉另一存活 lease 重下文件的跨 lease data-loss（13a-R2），并把完成 ledger/gate 该缺陷推到 RESOLVED。

**Architecture:** 引入单一私有 helper `deleteCachedFileIfUnowned(trainingSetId:)`——删除前以 journal 的 lease-aware 行集（`{.stored,.confirmPending,.confirmed}` 任一含该 tid = 存活占有）作所有权真相，存活占有则跳过、journal 读失败则 fail-safe 跳过；`retryPendingConfirmations`（本体）与 `run()` reject 路径（defense-in-depth）均改调它。零契约/schema 改动。

**Tech Stack:** Swift 6 / Swift Testing（`@Test`/`@Suite`）/ SwiftPM 包 `ios/Contracts`；in-memory fakes `InMemoryCacheManager` + `InMemoryAcceptanceJournalDAO`（`#if DEBUG`）。

**Spec:** `docs/superpowers/specs/2026-06-15-wave3-13a-r2-cross-lease-cache-design.md`（v2，opus 4.8 xhigh 评审 APPROVE 0C/0H 收敛）。

**基线**：origin/main `ee5cc55`；`swift test` host 全绿 1009 tests / 144 suites（已核实）。

**测试命令约定**：
- 单测迭代：`cd ios/Contracts && swift test --filter <名>`（例 `swift test --filter retry_crossLease_doesNotDeleteNewerLeaseFile`）。
- 套件：`cd ios/Contracts && swift test --filter DownloadAcceptanceRunnerTests`。
- 全量验证：`cd ios/Contracts && swift test`。
- 注：`<PR>` = 本 PR 编号，创建 PR 后在 Task 6 收尾填入（gate 非 CI 强制，本地校验即可）。

---

## File Structure

| 文件 | 责任 | 动作 |
|------|------|------|
| `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift` | P2 编排：helper + 两删除点改调 | Modify |
| `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift` | 回归测试 + 1 throwing-journal test fake | Modify |
| `docs/governance/2026-06-14-wave3-completion.md` | 完成 ledger：机器块 + prose 翻 13a-R2 → RESOLVED | Modify |
| `scripts/governance/verify-wave3-completion.sh` | grep gate：13a-R2 断言 OPEN → CLOSED（与机器块逐字一致）+ 注释/echo | Modify |
| `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | live doc L87：13a-R2 移出 OPEN 关闭门 | Modify |
| `docs/acceptance/2026-06-15-wave3-13a-r2-cross-lease-cache.md` | 非-coder 验收清单 | Create |

---

### Task 1: RED — 核心跨 lease 回归测试（demonstrates the bug）

**Files:**
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift`（在 `// MARK: - Task 5: retryPendingConfirmations` 段内、`retry_emptyJournal_noCrash` 之后插入）

- [ ] **Step 1: 写失败测试**

```swift
@Test func retry_crossLease_doesNotDeleteNewerLeaseFile() async throws {
    // 13a-R2 核心回归：旧 lease 孤儿 confirm 被拒（lease 过期），不得删掉新 lease 占有的同 tid cache 文件。
    let journal = InMemoryAcceptanceJournalDAO()
    let cache = InMemoryCacheManager()
    // 当前 cache 中 id=42 的文件 = 新 lease 重下并已确认的有效文件
    _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/42.sqlite"), meta: makeMeta(id: 42))
    // 新 lease：推进到 confirmed（存活 owner，终态，不被重试扫到）
    try seedStored(journal, id: 42, leaseId: "leaseNew", path: "/tmp/42.sqlite")
    try journal.upsert(trainingSetId: 42, leaseId: "leaseNew", state: .confirmPending,
                       sqliteLocalPath: "/tmp/42.sqlite", contentHash: nil, lastError: nil)
    try journal.upsert(trainingSetId: 42, leaseId: "leaseNew", state: .confirmed,
                       sqliteLocalPath: "/tmp/42.sqlite", contentHash: nil, lastError: nil)
    // 旧 lease：停在 confirmPending（孤儿，会被重试）
    try seedStored(journal, id: 42, leaseId: "leaseOld", path: "/tmp/42.sqlite")
    try journal.upsert(trainingSetId: 42, leaseId: "leaseOld", state: .confirmPending,
                       sqliteLocalPath: "/tmp/42.sqlite", contentHash: nil, lastError: nil)
    // 重试：旧 lease confirm 因 lease 过期被服务端拒收
    let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseExpired)),
                            cache: cache, journal: journal)
    await runner.retryPendingConfirmations()
    // 旧 lease → rejected；新 lease 仍 confirmed；文件保留、未被删
    #expect(try journal.listByState(.rejected).count == 1)
    #expect(try journal.listByState(.confirmed).count == 1)
    #expect(cache.listAvailable().contains(where: { $0.id == 42 }))
    #expect(cache.deletedFilenames.isEmpty)
}
```

- [ ] **Step 2: 跑测试确认 RED**

Run: `cd ios/Contracts && swift test --filter retry_crossLease_doesNotDeleteNewerLeaseFile`
Expected: FAIL — 当前 id-only 逻辑会删掉 id=42 文件，`contains{ $0.id == 42 }` 与 `deletedFilenames.isEmpty` 断言不通过。

- [ ] **Step 3: Commit（红测先落）**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "test(13a-R2): 跨 lease 误删核心回归测试（RED，demonstrates data-loss）"
```

---

### Task 2: GREEN — ownership-guard helper + 接入 retryPendingConfirmations

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`（helper 新增于 `// MARK: - confirm 子状态机` 之前；改 `retryPendingConfirmations` 的 reject 分支 `:154-157`）

- [ ] **Step 1: 新增 helper**

在 `retryPendingConfirmations()` 与 `// MARK: - confirm 子状态机（run + retry 共用）` 之间插入：

```swift
    // MARK: - 13a-R2：lease-aware 删除（run + retry 共用单一删除决策点）

    /// 仅当无任何存活 lease 占有该 trainingSetId 的 cache 文件时，才删除其本地副本。
    /// 所有权真相 = journal 的 lease-aware 行集：tid 在 {.stored, .confirmPending, .confirmed}
    /// 任一状态有行 = 某存活 lease 仍占有该 tid 的 cache 文件（cache 仅按 id 键控、同 id 覆盖，
    /// 故跨 lease 共享同一文件）。fail-safe：任一 owning-state 读失败 → 不删（宁留有效文件不误删）。
    private func deleteCachedFileIfUnowned(trainingSetId: Int) {
        let owningStates: [P2JournalState] = [.stored, .confirmPending, .confirmed]
        for state in owningStates {
            guard let rows = try? journal.listByState(state) else {
                return   // journal 读失败 → fail-safe 不删
            }
            if rows.contains(where: { $0.trainingSetId == trainingSetId }) {
                return   // 该 tid 仍被某存活 lease 占有 → 跳过删除（跨 lease 保护，13a-R2）
            }
        }
        if let file = cache.listAvailable().first(where: { $0.id == trainingSetId }) {
            try? cache.delete(file)
        }
    }
```

- [ ] **Step 2: 改 `retryPendingConfirmations` reject 分支**

把：

```swift
            if case .rejected = outcome {        // 409/404 → 清本地 cache 副本
                if let file = cache.listAvailable().first(where: { $0.id == row.trainingSetId }) {
                    try? cache.delete(file)
                }
            }
```

改为：

```swift
            if case .rejected = outcome {        // 409/404 → 清孤儿 cache 副本（lease-aware，13a-R2）
                deleteCachedFileIfUnowned(trainingSetId: row.trainingSetId)
            }
```

- [ ] **Step 3: 跑核心测试确认 GREEN**

Run: `cd ios/Contracts && swift test --filter retry_crossLease_doesNotDeleteNewerLeaseFile`
Expected: PASS。

- [ ] **Step 4: 跑既有 retry 删除测试确认无回归**

Run: `cd ios/Contracts && swift test --filter retry_confirm409_rejectsAndDeletesCacheFile`
Expected: PASS（单孤儿无其它 owning 行 → 仍删，行为保持）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift
git commit -m "fix(13a-R2): lease-aware ownership-guard 删除 helper + 接入 retryPendingConfirmations"
```

---

### Task 3: 接入 run() reject 路径（defense-in-depth）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`（`run()` 的 `case .rejected` 分支 `:103-105`）

- [ ] **Step 1: 改 run() reject 删除**

把：

```swift
            case .rejected(let e):                // 409/404 → 删本地 cache 副本
                try? cache.delete(file)
                return .rejected(e)
```

改为：

```swift
            case .rejected(let e):                // 409/404 → 清本 lease cache 副本（lease-aware，13a-R2 defense-in-depth）
                deleteCachedFileIfUnowned(trainingSetId: meta.id)
                return .rejected(e)
```

- [ ] **Step 2: 跑 run() 删除测试确认无回归**

Run: `cd ios/Contracts && swift test --filter "run_confirm409_rejected_deletesLocalFile"`
然后：`cd ios/Contracts && swift test --filter "run_confirm404_rejected_deletesLocalFile"`
Expected: 均 PASS（单 lease reject 后该 tid 无其它 owning 行 → 仍删，行为保持）。

- [ ] **Step 3: 跑整套 P2 套件**

Run: `cd ios/Contracts && swift test --filter DownloadAcceptanceRunnerTests`
Expected: 全 PASS（含 networkUncertain/5xx 保留、confirmSuccess 保留等既有用例）。

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift
git commit -m "fix(13a-R2): run() reject 路径同走 ownership-guard helper（defense-in-depth，behavior-neutral）"
```

---

### Task 4: 其余回归测试（收敛性 + stored 占有 + fail-safe）

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift`（新增 1 个 test-local fake `ThrowOnStateJournal` 于文件顶部 fakes 段 `FakeAPIClient` 之后；新增 3 个测试于 Task 5 retry 段）

- [ ] **Step 1: 新增 throwing-journal test fake**

在 `private final class FakeAPIClient` 类定义之后插入：

```swift
/// 包装 InMemory，仅对指定 state 的 listByState 抛错——测 ownership-guard 的 fail-safe 分支
/// （重试列表建立读 .stored/.confirmPending 仍走 inner，故能跑到删除决策；helper 查 throwState 时抛）。
private final class ThrowOnStateJournal: AcceptanceJournalDAO, @unchecked Sendable {
    let inner = InMemoryAcceptanceJournalDAO()
    private let throwState: P2JournalState
    init(throwOn: P2JournalState) { throwState = throwOn }
    func upsert(trainingSetId: Int, leaseId: String, state: P2JournalState,
                sqliteLocalPath: String?, contentHash: String?, lastError: String?) throws {
        try inner.upsert(trainingSetId: trainingSetId, leaseId: leaseId, state: state,
                         sqliteLocalPath: sqliteLocalPath, contentHash: contentHash, lastError: lastError)
    }
    func listByState(_ state: P2JournalState) throws -> [AcceptanceJournalRow] {
        if state == throwState { throw AppError.persistence(.dbCorrupted) }
        return try inner.listByState(state)
    }
    func deleteByIdLease(trainingSetId: Int, leaseId: String) throws {
        try inner.deleteByIdLease(trainingSetId: trainingSetId, leaseId: leaseId)
    }
}
```

- [ ] **Step 2: 新增 3 个测试**（紧接 Task 1 的核心测试之后）

```swift
@Test func retry_twoOrphanLeasesSameTid_bothRejected_fileDeleted() async throws {
    // 收敛性：两孤儿 lease 同 tid 都被拒 → 最后一个被拒时已无 owning 行 → 文件应被删（guard 不永久泄漏）。
    let journal = InMemoryAcceptanceJournalDAO()
    let cache = InMemoryCacheManager()
    _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/42.sqlite"), meta: makeMeta(id: 42))
    try seedStored(journal, id: 42, leaseId: "L1", path: "/tmp/42.sqlite")
    try journal.upsert(trainingSetId: 42, leaseId: "L1", state: .confirmPending,
                       sqliteLocalPath: "/tmp/42.sqlite", contentHash: nil, lastError: nil)
    try seedStored(journal, id: 42, leaseId: "L2", path: "/tmp/42.sqlite")
    try journal.upsert(trainingSetId: 42, leaseId: "L2", state: .confirmPending,
                       sqliteLocalPath: "/tmp/42.sqlite", contentHash: nil, lastError: nil)
    let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseExpired)),
                            cache: cache, journal: journal)
    await runner.retryPendingConfirmations()
    #expect(try journal.listByState(.rejected).count == 2)
    #expect(cache.listAvailable().contains(where: { $0.id == 42 }) == false)
}

@Test func retry_competingStoredClaim_blocksDeletion() async throws {
    // 新 lease 的 stored 行（尚未 confirmed）也算存活占有 → 旧 lease 拒收时保护该文件。
    let journal = InMemoryAcceptanceJournalDAO()
    let cache = InMemoryCacheManager()
    _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/42.sqlite"), meta: makeMeta(id: 42))
    // 新 lease：stored（重试先处理 stored 行，confirm 成功 → confirmed）
    try seedStored(journal, id: 42, leaseId: "leaseNew", path: "/tmp/42.sqlite")
    // 旧 lease：confirmPending（后处理，confirm 拒收）
    try seedStored(journal, id: 42, leaseId: "leaseOld", path: "/tmp/42.sqlite")
    try journal.upsert(trainingSetId: 42, leaseId: "leaseOld", state: .confirmPending,
                       sqliteLocalPath: "/tmp/42.sqlite", contentHash: nil, lastError: nil)
    // confirm 调用序：#1 = 新 lease(stored，先处理) 成功；#2 = 旧 lease(confirmPending) 拒收
    let runner = makeRunner(
        api: FakeAPIClient(confirmSequence: [nil, .network(.leaseExpired)]),
        cache: cache, journal: journal)
    await runner.retryPendingConfirmations()
    #expect(try journal.listByState(.confirmed).count == 1)   // 新 lease confirmed
    #expect(try journal.listByState(.rejected).count == 1)     // 旧 lease rejected
    #expect(cache.listAvailable().contains(where: { $0.id == 42 }))  // 文件保留
}

@Test func retry_journalReadFails_failSafe_doesNotDelete() async throws {
    // fail-safe：所有权查询读失败 → 保守不删（对比单孤儿正常会删；若 helper 用 ?? [] 则会误删 → 本测试为 fail-safe killer）。
    let journal = ThrowOnStateJournal(throwOn: .confirmed)   // 重试列表读 .stored/.confirmPending 不抛；helper 查 .confirmed 时抛
    let cache = InMemoryCacheManager()
    _ = try cache.store(downloadedZip: URL(fileURLWithPath: "/tmp/9.sqlite"), meta: makeMeta(id: 9))
    try seedStored(journal, id: 9, leaseId: "L9", path: "/tmp/9.sqlite")
    let runner = makeRunner(api: FakeAPIClient(confirmError: .network(.leaseNotFound)),
                            cache: cache, journal: journal)
    await runner.retryPendingConfirmations()
    #expect(cache.listAvailable().contains(where: { $0.id == 9 }))   // 读失败 → 未删
    #expect(cache.deletedFilenames.isEmpty)
}
```

- [ ] **Step 3: 跑新增 3 测试 + 全 P2 套件**

Run: `cd ios/Contracts && swift test --filter DownloadAcceptanceRunnerTests`
Expected: 全 PASS（含 3 新增 + 既有）。

- [ ] **Step 4: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/DownloadAcceptanceRunnerTests.swift
git commit -m "test(13a-R2): 收敛性 + stored 占有保护 + fail-safe 回归（含 ThrowOnStateJournal fake）"
```

---

### Task 5: Mutation / killer 校验（不提交，仅验证测试有效性）

**目的**：证明核心回归测试是真 killer（非 vacuous），并证明 fail-safe 测试真区分 `guard-return` vs `?? []`。

- [ ] **Step 1: 临时回退 helper 为 id-only（mutation 1）**

临时把 `deleteCachedFileIfUnowned` 体替换为无 guard 的直接删除：
```swift
    private func deleteCachedFileIfUnowned(trainingSetId: Int) {
        if let file = cache.listAvailable().first(where: { $0.id == trainingSetId }) {
            try? cache.delete(file)
        }
    }
```
Run: `cd ios/Contracts && swift test --filter "retry_crossLease_doesNotDeleteNewerLeaseFile"`
Expected: **FAIL**（证核心测试为 killer）。再 `--filter retry_competingStoredClaim_blocksDeletion` Expected: **FAIL**。

- [ ] **Step 2: 临时把 guard 改 `?? []`（mutation 2，fail-safe 失效）**

临时把 helper 的 `guard let rows = try? journal.listByState(state) else { return }` 改为 `let rows = (try? journal.listByState(state)) ?? []`：
Run: `cd ios/Contracts && swift test --filter retry_journalReadFails_failSafe_doesNotDelete`
Expected: **FAIL**（证 fail-safe 测试真区分；`?? []` → 读失败当无 owner → 误删）。

- [ ] **Step 3: 还原 helper 至 Task 2 正确版本，跑套件确认全绿**

Run: `cd ios/Contracts && swift test --filter DownloadAcceptanceRunnerTests`
Expected: 全 PASS。**本任务不产生 commit**（仅验证；工作树须回到 Task 4 末状态，`git status` 干净）。

---

### Task 6: 完成 ledger + grep gate + runtime-matrix 翻转（13a-R2 → RESOLVED）

**Files:**
- Modify: `docs/governance/2026-06-14-wave3-completion.md`
- Modify: `scripts/governance/verify-wave3-completion.sh`
- Modify: `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`

> `<PR>` 处暂写字面 `#<PR>`（机器块与 gate 同写 `#<PR>` → 彼此逐字匹配，gate 本地可过）；创建 PR 后在 finalize 步用真编号替换两处（见末尾 Finalize）。

- [ ] **Step 1: 完成 ledger 机器块 L18**

把 `known-defect-13a-R2-cross-lease-cache-deletion: OPEN`
改为 `known-defect-13a-R2-cross-lease-cache-deletion: CLOSED 13a-R2 #<PR>`
（沿用 L13 `residual-A-...: CLOSED 13a #108` 同型；PR-号 only，无 SHA。）

- [ ] **Step 2: 完成 ledger 表行（13a-R2 行，状态列 + 处理列）**

把该行状态列 `**OPEN（已知缺陷，正式关闭前提）**` → `**RESOLVED（本 PR #<PR>，2026-06-15）**`；
处理列尾部 `路由 **P2-confirm-reliability RFC**（cache 所有权改 lease/version-aware + 回归测试）。…正式关闭前须经 P2 RFC 解决`
改为：`已由本 PR 修复：journal-driven lease-aware ownership-guard（删除前查 {stored,confirmPending,confirmed} 行集，存活占有则跳过、读失败 fail-safe）+ 5 类回归测试；设计见 docs/superpowers/specs/2026-06-15-wave3-13a-r2-cross-lease-cache-design.md。`

- [ ] **Step 3: 完成 ledger prose（正式关闭前提 + 后续 + 脚注）**

- 「正式关闭 = …**解 W3-11-R1 与 13a-R2**（功能门 + 已知 data-loss 缺陷，§三）后」→ 「…**解 W3-11-R1**（13a-R2 已由本 PR #<PR> 解决，2026-06-15）后」。
- §「后续」第 ③ 项「13a-R2（跨 lease cache data-loss）经 P2-confirm RFC 解决后」→ 「13a-R2 已由本 PR #<PR> 解决（lease-aware ownership-guard）」。
- 脚注「**13a-R2（跨 lease cache data-loss）已提升进上方顶层 ledger 作 OPEN**」→ 「**13a-R2（跨 lease cache data-loss）已由本 PR #<PR> 解决（RESOLVED，见上方顶层 ledger）**」。
- §六 评审通道说明行（L124，grep gate 断言描述）：把 `W3-11-R1/**13a-R2**/PR11-R1/W1-R2 OPEN` 改为 `W3-11-R1/PR11-R1/W1-R2 OPEN + **13a-R2 RESOLVED（本 PR）**`——使 §六 对 gate 断言的散文描述与翻转后的机器块/gate 一致（避免 machine-block↔prose 自相矛盾，per `feedback_codex_round6_self_contradiction`）。

- [ ] **Step 4: 改 gate L51 + 注释 + echo**

- L51：`require_kv "known-defect-13a-R2-cross-lease-cache-deletion" "OPEN"` → `require_kv "known-defect-13a-R2-cross-lease-cache-deletion" "CLOSED 13a-R2 #<PR>"`（与机器块逐字一致）。
- L6 注释「+ 已知 data-loss 缺陷 13a-R2 + ship 门 PR11-R1 / W1-R2 标 OPEN」→ 把 13a-R2 移出该句、注明已 RESOLVED。
- L49 注释「谓词 2：W3-11-R1 + 已知 data-loss 缺陷 13a-R2 + ship 门 = OPEN」→ 「谓词 2：W3-11-R1 + ship 门 PR11-R1/W1-R2 = OPEN；13a-R2 = RESOLVED（本 PR）」。
- L73 echo 内 `W3-11-R1/13a-R2/PR11-R1/W1-R2 OPEN` → `W3-11-R1/PR11-R1/W1-R2 OPEN + 13a-R2 RESOLVED`。

- [ ] **Step 5: 改 runtime-matrix L87（live doc）**

把 `- W3-11-R1（bounce live 接线）+ 13a-R2（跨 lease cache data-loss）+ PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本数据）= OPEN，不在本矩阵 device 验收范围（见 completion doc §三/§四）；其中 W3-11-R1 + 13a-R2 是关闭前须解的功能/缺陷门。`
改为 `- W3-11-R1（bounce live 接线）+ PR11-R1（生产 backendBaseURL）+ W1-R2（真实样本数据）= OPEN，不在本矩阵 device 验收范围（见 completion doc §三/§四）；其中 W3-11-R1 是关闭前须解的功能门。**13a-R2（跨 lease cache data-loss）已由 PR #<PR> 解决（2026-06-15，lease-aware ownership-guard），不再是关闭前缺陷门。**`

- [ ] **Step 6: 本地跑 gate 确认 PASS**

Run: `bash scripts/governance/verify-wave3-completion.sh`
Expected: `[verify-wave3-completion] PASS…`（机器块与 gate 逐字一致；其余 require_kv 不变仍满足）。

- [ ] **Step 7: Commit**

```bash
git add docs/governance/2026-06-14-wave3-completion.md scripts/governance/verify-wave3-completion.sh docs/acceptance/2026-06-14-wave3-runtime-matrix.md
git commit -m "docs(13a-R2): 完成 ledger + gate + runtime-matrix 翻 13a-R2 → RESOLVED（保留 W3-11-R1/矩阵 OPEN）"
```

---

### Task 7: 非-coder 验收清单

**Files:**
- Create: `docs/acceptance/2026-06-15-wave3-13a-r2-cross-lease-cache.md`

- [ ] **Step 1: 写验收 doc**（直接复用 spec §七 验收表 + 补 PR 元信息头），表项含：helper 存在/两删除点改调；helper fail-safe 体；`swift test` 全绿含 5 类回归；核心回归断言文件保留；mutation killer 已验证（Task 5）；ledger/gate/matrix 翻转 + 逐字一致；gate 本地 PASS；grep `ios/**` 无残留 id-only 删除模式（runner 两处经 helper；coordinator 4 处损坏删除属另一类不在范围）。

- [ ] **Step 2: Commit**

```bash
git add docs/acceptance/2026-06-15-wave3-13a-r2-cross-lease-cache.md
git commit -m "docs(13a-R2): 非-coder 验收清单"
```

---

### Task 8: 全量验证

- [ ] **Step 1: 全套 host 测试**

Run: `cd ios/Contracts && swift test`
Expected: 全 PASS，0 failures；总数 = 1009 + 4（新增测试：core + two-orphan + competing-stored + fail-safe）= 1013（±，以实际为准），suites +0 或 +0（同套件内）。

- [ ] **Step 2: grep 残留旧模式**

Run（**必须用 `-F` 固定串**——macOS BSD grep 下 `{ ` 会被当 BRE interval 致整模式 0 匹配 vacuous，见 `feedback_acceptance_grep_anchoring`）：
`cd ios/Contracts && grep -rnF 'listAvailable().first(where: { $0.id ==' Sources/`
Expected: 恰 1 处，且在 `deleteCachedFileIfUnowned` helper 内（`DownloadAcceptanceRunner.swift`）；`retryPendingConfirmations` / `run()` 不再裸用此模式。

---

## Finalize

> **执行期裁决（2026-06-15，supersedes 下方 `#<PR>` fill 步骤）**：为最小化用户 TTY attest 轮次（"尽可能不要找我"），live docs 的机器块/gate 值不采用 merge 前未知的 PR 号，而是**就地落定为稳定日期值** `CLOSED 13a-R2 2026-06-15`（机器块 L18 + gate L51 逐字一致；prose/matrix 用「本 PR」不带号）。如此 branch 一次成终态、无需 push 后补提交 → **单轮 attest**。PR 号由 PR 本身 + commit 历史 + 本 plan/spec 提供可追溯性。gate 已本地 PASS。
>
> 下方原 `#<PR>` fill 步骤因此**作废**（保留作设计记录）：
> 1. ~~`gh pr create` 得到编号 `N`。~~
> 2. ~~`#<PR>` → `#N` 全替换。~~
> 3. ~~重跑 gate。~~
> 4. ~~commit 填号 + push。~~

---

## Self-Review（against spec v2）

- **Spec coverage**：§四.2 helper（Task 2 S1）✓；§4.3 retry 接入（Task 2 S2）✓；§4.4 run() 接入（Task 3）✓；§五 5 类回归测试——核心(Task 1) / sole-orphan-still-deletes(既有 `retry_confirm409` 保留，Task 2 S4 核实) / two-orphan(Task 4) / competing-stored(Task 4) / fail-safe(Task 4) ✓；§六 ledger+gate+matrix(Task 6) ✓；§七 验收(Task 7) ✓；mutation killer(Task 5) ✓。
- **Placeholder scan**：`#<PR>` 为受控 fill-at-merge token（Finalize 步消除），非遗漏；无 TBD/TODO；所有测试/helper 均含完整代码。
- **Type 一致性**：helper 名 `deleteCachedFileIfUnowned(trainingSetId:)` 全程一致；`ThrowOnStateJournal` / `FakeAPIClient(confirmSequence:)` / `seedStored` / `makeMeta` / `deletedFilenames` 均经核实存在。
- **gate↔机器块逐字耦合**：Task 6 S1/S4 同值 `CLOSED 13a-R2 #<PR>`，Finalize 同步替换，gate 本地 PASS 校验（S6 + Finalize 3）。
