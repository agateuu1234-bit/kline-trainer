# Wave 3 13a-R2 — 跨 lease cache 误删（已知 data-loss）修复设计（v1）

**类型**：bug-fix 设计 + 局部 P2-confirm cache 所有权 RFC（聚焦 13a-R2，非完整 P2-confirm-reliability RFC）
**来源**：`docs/governance/2026-06-14-wave3-completion.md` 顶层 ledger `known-defect-13a-R2-cross-lease-cache-deletion: OPEN`（codex 13a review R6 提出，R3-High 提升进顶层 ledger）
**前置基线**：origin/main `ee5cc55`（Wave 3 顺位 13c merged，#110）
**关闭目标**：把 ledger 中 13a-R2 从 `OPEN` 推到 `RESOLVED/CLOSED`（功能门之一；W3-11-R1 + 运行时矩阵仍为其余正式关闭前提，本 PR 不动）

---

## 〇、问题陈述（事实，2026-06-15 在 `ee5cc55` 核实）

`DownloadAcceptanceRunner.retryPendingConfirmations()`（`ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift:147-161`）在重试孤儿确认时，若 confirm 返回服务端拒收（409 `leaseExpired` / 404 `leaseNotFound`），按如下逻辑清理本地 cache 副本：

```swift
if case .rejected = outcome {        // 409/404 → 清本地 cache 副本
    if let file = cache.listAvailable().first(where: { $0.id == row.trainingSetId }) {
        try? cache.delete(file)
    }
}
```

**根因 = 两套作用域不一致：**

| 层 | 键控粒度 | 证据 |
|----|---------|------|
| journal（`download_acceptance_journal`） | `(trainingSetId, leaseId)` | `AcceptanceJournalRow.leaseId`（`AcceptanceJournalDAO.swift:25`）+ `deleteByIdLease(trainingSetId:leaseId:)`（:62）+ InMemory key `"\(tid)::\(lease)"` |
| cache（P5 `CacheManager`） | **仅 `trainingSetId`** | cache 文件名 `<id>__<filename>`（`DefaultFileSystemCacheManager.swift:48/242`）；同 id `store` 覆盖（`store_sameIdOverwritesOldFile` 测试坐实）；`TrainingSetFile` 无 `leaseId`/`contentHash` 字段（`AppState.swift:134-141`） |

reject 清理用 `first(where: { $0.id == row.trainingSetId })`——**仅按 trainingSetId 选 cache 文件**，无视 lease 归属。

**data-loss 触发序列（跨 lease）：**
1. 旧 lease `L1` 下载训练组 `tid=42`，存 cache 文件 `42__….sqlite`，journal 行 `(42, L1, confirmPending)`。confirm 未完成即进程退出 → 孤儿行残留。
2. 进程重启。新 lease `L2` 重下同一 `tid=42`，**覆盖**同路径 cache 文件（同 id），journal 行 `(42, L2, confirmed)`。**这是用户当前持有的有效文件。**
3. `retryPendingConfirmations()` 处理旧孤儿 `(42, L1, confirmPending)` → confirm 因 `L1` 已过期返回 409 `leaseExpired` → `.rejected` → 清理按 `id==42` 选中 **L2 的文件并删除**。
4. → 用户刚重下并确认的有效训练组被误删。**跨 lease 数据丢失。**

注：该 bug **pre-existing**（P2 基线既有，非 Wave 3 引入；13a PR #108 未触碰此代码，codex review R6 确认）。

---

## 一、范围（严格聚焦 13a-R2）

**In scope：**
- 修复 `retryPendingConfirmations()` reject 清理的跨 lease 误删（13a-R2 本体）。
- 把同类删除决策点收敛为单一 ownership-aware helper，并应用于 `run()` 的 reject 清理路径（`:103-104`，defense-in-depth；见 §四.4）。
- 回归测试（ledger 路由明确要求"+ 回归测试"）。
- 完成 ledger（`docs/governance/2026-06-14-wave3-completion.md`）+ grep gate（`scripts/governance/verify-wave3-completion.sh`）把 13a-R2 从 `OPEN` 推到 `RESOLVED`。

**Out of scope（显式不纳入，避免范围蔓延 / 被审查拖入无关下钻）：**
- **13a-R1**（精确 confirm-state 下载反馈三态 + 模糊 confirm 幂等安全策略）——独立 UX/可靠性项，与本 cache 所有权 bug 正交；按用户显式命名仅做 13a-R2。
- **13a-R3**（touch-on-use vs 并发 store 的 TOCTOU + P5 cache pinning API）——独立 P5-cache-pinning RFC。
- **CacheManager / TrainingSetFile / journal DAO 协议面变更**——本修复零契约改动（见 §四 为何不需要）。
- **P4 schema / DDL 变更**——零 schema 改动。
- **Wave 3 正式关闭 / freeze tag**——13a-R2 仅是关闭前提之一；W3-11-R1 + 运行时矩阵仍 OPEN，本 PR 不 claim 正式关闭。

---

## 二、设计目标（成功判据）

1. **不再发生跨 lease 误删**：当某 tid 的 cache 文件被另一个仍存活 lease 占有时，旧 lease 孤儿行的 reject 重试**不得**删除该文件。
2. **保留原有清理意图**：真正的孤儿（无其它存活 lease 占有同 tid）reject 后**仍**删除其 cache 文件（不退化为"永不清理 → 泄漏"）。
3. **fail-safe 偏向保数据**：当无法判定所有权（journal 读失败）时，**倾向不删除**（宁可暂留一个有效文件，绝不误删）。
4. **零契约 / 零 schema 改动**：复用既有 `journal.listByState` 作为所有权真相源。
5. **既有行为不回归**：现有 16 条 P2 run/retry 测试（含 `run_confirm409_rejected_deletesLocalFile`、`retry_confirm409_rejectsAndDeletesCacheFile`）全部继续通过。

---

## 三、方案比较

### 方案 A（推荐）— 删除点 ownership-guard（journal 驱动，零契约改动）

在 reject 后删除 cache 文件**前**，查询 journal：若该 tid 仍有任何行处于 owning 状态 `{stored, confirmPending, confirmed}`，则该文件被某存活 lease 占有 → **跳过删除**；否则（无存活占有）才删除。

journal 本身即 lease-aware 的所有权账本（`(tid, lease)` 键控 + lease 字段）——"cache 所有权改 lease/version-aware"（ledger 路由原话）在本方案中即落实为"删除决策以 journal 的 lease-aware 行集为准"。

- **优点**：最小、surgical；零 `CacheManager`/`TrainingSetFile`/schema 变更；所有权真相单一来源（journal）；保留孤儿清理；天然 fail-safe。重试是启动期低频路径，多 3 次 `listByState` 可忽略。
- **缺点**：所有权由 journal 推断而非物化在 cache 文件上（与现有架构一致——cache 元数据本就 filesystem-derived，无 sidecar）。

### 方案 B — lease/version-tagged cache 文件（契约变更）

cache 文件名/sidecar 纳入 `leaseId`，使 `delete` 可按 `(tid, lease)` 精确定位。

- **优点**：cache 真正 lease-aware，删除精确。
- **缺点**：**重型**——动 `CacheManager` 协议（`store` 需 `leaseId`）、`DefaultFileSystemCacheManager` 文件名方案 + `listAvailable` 解析、`TrainingSetFile` 加字段、全部消费者；破坏"每 tid 一文件、同 id 覆盖"的 LRU 模型（同 tid 多 lease 版本 → cache 膨胀 + 驱逐复杂化）。**对一个"确认孤儿清理"bug 属过度工程**——播放只需每训练组一份已校验文件，不需要保留多 lease 版本。**拒绝。**

### 方案 C — 重试路径完全不删（最简）

reject 重试仅更新 journal 为 rejected，**永不**从重试路径删 cache 文件（靠下次下载覆盖 / LRU 驱逐回收）。

- **优点**：平凡安全（重试路径无任何删除 → 不可能跨 lease 误删）。
- **缺点**：改变清理契约——被服务端拒收的孤儿文件不再清理 → 泄漏直到 LRU 驱逐；且语义上"服务端拒收的 set 仍可被用户选中播放"。**退化目标 2。次选但不如 A 精确。**

**结论：方案 A。** 它精确满足全部目标（既修跨 lease 误删，又保留孤儿清理），零契约改动，最 surgical。

---

## 四、选定设计（方案 A 细化）

### 4.1 所有权判据

定义 tid 的 **live-owner**：journal 中存在任一行 `trainingSetId == tid` 且 `state ∈ {stored, confirmPending, confirmed}`。

理由：
- `.stored` / `.confirmPending` / `.confirmed`：cache 中有该 tid 的文件且被某 lease 存活占有（待确认 / 确认中 / 已确认）。
- `.rejected`：文件应被删（或已删），非占有。
- 更早状态（`downloaded`/`crcOK`/`unzipped`/`dbVerified`）：尚未入 cache（`stored` 前 `sqliteLocalPath` 为 nil），与 cache 删除无关。

**关键不变量**：进入删除决策时，被拒的行 `(tid, thisLease)` 已被 `attemptConfirm` 置为 `.rejected`（`:182`，run + retry 两路一致）。故对该 tid 在 owning 状态查到的任何行**必然是其它 lease 的存活占有**——无需显式比较 leaseId。

### 4.2 helper（`DownloadAcceptanceRunner` 私有，无契约改动）

```swift
/// 13a-R2 修复：仅当无任何存活 lease 占有该 trainingSetId 的 cache 文件时才删除。
/// 所有权真相 = journal 的 lease-aware 行集（{stored, confirmPending, confirmed}）。
/// fail-safe：journal 读失败时不删除（宁留有效文件不误删）。
private func deleteCachedFileIfUnowned(trainingSetId: Int) {
    let owningStates: [P2JournalState] = [.stored, .confirmPending, .confirmed]
    for s in owningStates {
        guard let rows = try? journal.listByState(s) else {
            return   // 读失败 → fail-safe 不删
        }
        if rows.contains(where: { $0.trainingSetId == trainingSetId }) {
            return   // 存活占有 → 跳过删除（跨 lease 保护）
        }
    }
    // 无存活占有 → 安全删除孤儿文件
    if let file = cache.listAvailable().first(where: { $0.id == trainingSetId }) {
        try? cache.delete(file)
    }
}
```

注 fail-safe 语义：`try?` 在本 helper 中**不可**降级为 `?? []`——若读失败默认空集会得出"无占有 → 删除"的**不安全**方向。必须区分"读成功且无占有"（删）与"读失败"（跳过）。helper 用 `guard let … else { return }` 实现：读失败立即 return（不删）。

### 4.3 应用点 1（本体修复）— `retryPendingConfirmations`

```swift
if case .rejected = outcome {
    deleteCachedFileIfUnowned(trainingSetId: row.trainingSetId)   // 替换原 id-only 删除
}
```

### 4.4 应用点 2（defense-in-depth）— `run()` reject 清理

```swift
case .rejected(let e):
    deleteCachedFileIfUnowned(trainingSetId: meta.id)   // 替换 try? cache.delete(file)
    return .rejected(e)
```

**为何也改 `run()`**：同一"按 id-only 删 cache"缺陷模式在 `run()` 的 reject 路径（`:103-104`）同样存在。`run()` 的 `file` 由本 lease 刚 `store`，跨 lease 误删需"另一 lease 的并发 runBatch 对同 tid 在本 run 的 store→confirm-reject 之间完成 store"——app 正常下载流程**不**对同一训练组并发跑双 lease，故 `run()` 的跨 lease 风险**理论性**。但：(a) 收敛为单一删除决策点消除整个 bug 类而非单点；(b) 对 `run()` 常见的 sole-owner 场景**行为完全保持**（reject 后该 tid 无其它存活行 → 仍删，现有 `run_confirm409/404` 测试坐实）；(c) 边际成本仅 409/404 罕见 reject 时多 3 次 journal 读。故纳入。

> 明确：13a-R2 **本体**是 `retryPendingConfirmations`（§4.3）；`run()`（§4.4）是同类 defense-in-depth、behavior-neutral。若整体对抗评审认定 §4.4 属范围蔓延，可单独回退该一处而不影响本体修复（两处经同一 helper，回退即把 `run()` 改回直接 `cache.delete(file)`）。

### 4.5 行为保持论证

| 既有测试 | 场景 | 修复后路径 | 结论 |
|---------|------|-----------|------|
| `retry_confirm409_rejectsAndDeletesCacheFile`（id=9，单 lease L9） | 孤儿 409 → 删 | reject 后 (9,L9)=rejected，tid=9 无 owning 行 → 删 | **仍删，PASS** |
| `run_confirm409_rejected_deletesLocalFile`（id=3） | 单 lease 409 → 删 | 同上 | **仍删，PASS** |
| `run_confirm404_rejected_deletesLocalFile`（id=4） | 单 lease 404 → 删 | 同上 | **仍删，PASS** |
| `retry_confirmNetworkUncertain_staysPending_keepsFile`（id=8） | 网络不确定 → 保留 | outcome=.pending（非 .rejected）→ 不进删除分支 | **不删，PASS** |
| `run_confirmNetworkUncertain…` / `5xx` | 保留 | 同上（.pending） | **不删，PASS** |
| `retry_storedRow_confirmSuccess_confirmedAndFileRetained`（id=1） | 成功 → 保留 | outcome=.confirmed → 不进删除分支 | **不删，PASS** |

`InMemoryAcceptanceJournalDAO.listByState` 不抛 → fail-safe 分支在既有测试中不触发，无回归。

---

## 五、回归测试（新增，落 `DownloadAcceptanceRunnerTests.swift`）

1. **`retry_crossLease_doesNotDeleteNewerLeaseFile`（核心 13a-R2 回归）**
   - seed cache：id=42 一个文件（代表新 lease 当前文件）。
   - seed journal：`(42, "newLease")` 推进到 `.confirmed`（存活 owner，终态，不被重试扫到）；`(42, "oldLease")` 推进到 `.confirmPending`（孤儿，被重试扫到）。
   - api.confirm 全局抛 `.network(.leaseExpired)`（仅 oldLease 在重试列表 → 被拒）。
   - 断言：`cache.listAvailable().contains{ $0.id == 42 }` **为真（文件保留）**；`(oldLease)` → rejected；`(newLease)` 仍 confirmed；`cache.deletedFilenames` 不含 id=42 文件名。
   - **mutation 验证**：还原成 id-only 删除 → 此测试 fail（killer 测试）。

2. **`retry_soleOrphan_stillDeletesCacheFile`（保留孤儿清理意图）**
   - 即既有 `retry_confirm409_rejectsAndDeletesCacheFile` 的语义（单 lease 孤儿仍删）；保留既有测试即满足，额外显式重申可选。

3. **`retry_twoOrphanLeasesSameTid_bothRejected_fileDeleted`（不过度保留 / 收敛性）**
   - seed cache：id=42。journal：`(42,L1,confirmPending)` + `(42,L2,confirmPending)` 两孤儿。
   - api.confirm 全局 `.leaseExpired` → 两者依次被拒。
   - 断言：两者处理完后文件**已删**（最后一个被拒时已无任何 owning 行）；证 guard 不会因尚存"对方"而永久泄漏。

4. **`retry_competingStoredClaim_blocksDeletion`（lease-aware 替身，stored 占有也保护）**
   - 需按 lease 区分 confirm 结果的替身：`oldLease`→`.leaseExpired`、`newLease`→成功。
   - journal：`(42, newLease, stored)` + `(42, oldLease, confirmPending)`；cache：id=42。
   - 重试先处理 stored（newLease）→ confirm 成功 → confirmed；再处理 confirmPending（oldLease）→ 拒 → 查 owning 行命中 newLease=confirmed → 跳过删除。
   - 断言：文件保留。

5. **`reject_journalReadFails_failSafe_doesNotDelete`（fail-safe）**
   - 注入 `listByState` 抛错的 journal 替身（含一条 stored 孤儿行的快照供重试列表）。
   - 断言：reject 时不删除 cache 文件（读失败 → 保守不删）。

测试只用 `#if DEBUG` in-memory fakes（`InMemoryCacheManager` / `InMemoryAcceptanceJournalDAO`）+ 局部 lease-aware / throwing 替身（test-local，不污染生产 fake 行为面）。

---

## 六、ledger + gate 关闭（把 13a-R2 推到 RESOLVED）

- `docs/governance/2026-06-14-wave3-completion.md`：
  - 机器块 L18 `known-defect-13a-R2-cross-lease-cache-deletion: OPEN` → `RESOLVED <PR#> <sha>`。
  - 顶层 ledger 表（L88）+ §三 关闭前提 prose（L68/L118）：13a-R2 标 RESOLVED + 指向本 PR；**保留** W3-11-R1 + 运行时矩阵作其余关闭前提（不 claim 正式关闭）。
- `scripts/governance/verify-wave3-completion.sh:51`：`require_kv "known-defect-13a-R2-cross-lease-cache-deletion" "OPEN"` → 改断言新值（与机器块逐字一致）；L73 echo 摘要同步。
- 诚实边界：本 PR 仅关 13a-R2 一项 data-loss 缺陷；不改 store-ready/formal-closure/feature-completeness/matrix/freeze 任何状态。

> ⚠️ `docs/governance/**` + `scripts/**` 属 `codeowners_required_globs` → 合并需用户 Approve；`ios/**/*.swift` + `docs/**` + `scripts/**` 属 `trust_boundary_globs` → 必经 `codex:adversarial-review`（codex 配额耗尽走 opus 4.8 xhigh fallback，documented）。

---

## 七、验收清单（非 coder 可执行，中文，action/expected/pass-fail）

| # | 操作 | 期望 | 结果 |
|---|------|------|------|
| 1 | 看 `DownloadAcceptanceRunner.swift` diff | 新增私有 `deleteCachedFileIfUnowned(trainingSetId:)`；`retryPendingConfirmations` 与 `run()` reject 路径均改调它，不再裸 `id`-only 删除 | □ Pass / □ Fail |
| 2 | 看 helper 体 | 查 `{stored,confirmPending,confirmed}` 三态任一含 tid → return 不删；`listByState` 读失败 → return 不删；均无后才 `cache.delete` | □ Pass / □ Fail |
| 3 | `swift test`（host） | 全绿，0 failure；含新增 5 类回归测试 + 既有 P2 run/retry 测试全过 | □ Pass / □ Fail |
| 4 | 看核心回归测试 `retry_crossLease_doesNotDeleteNewerLeaseFile` | 新 lease confirmed + 旧 lease 孤儿 reject 后，id=42 文件**保留**、不在 `deletedFilenames` | □ Pass / □ Fail |
| 5 | 临时还原 helper 为 id-only 删除跑测试 | 核心回归测试 **FAIL**（mutation 证其为 killer） | □ Pass / □ Fail |
| 6 | 看 `verify-wave3-completion.sh` + 完成 ledger | 13a-R2 = RESOLVED（机器块与 gate 逐字一致）；W3-11-R1 / 运行时矩阵仍 OPEN；store-ready/closure 未改 | □ Pass / □ Fail |
| 7 | 跑 `scripts/governance/verify-wave3-completion.sh` | PASS（断言与新机器块一致） | □ Pass / □ Fail |
| 8 | grep 全仓 `ios/**` | 无残留"按 trainingSetId 单独选 cache 项删除"的旧模式（两处均经 helper） | □ Pass / □ Fail |

---

## 八、变更日志

- v1（2026-06-15）：首版。方案 A（journal 驱动 ownership-guard，fail-safe）；应用 `retryPendingConfirmations`（本体）+ `run()`（defense-in-depth）；5 类回归测试；ledger + gate 关闭 13a-R2。待 opus 4.8 xhigh 对抗性评审收敛。
