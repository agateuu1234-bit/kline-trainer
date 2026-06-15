# Wave 3 13a-R2 跨 lease cache 误删修复 — 非 coder 验收清单

**日期**：2026-06-15
**Anchor**：Wave 3 13a-R2（跨 lease cache 误删，已知 data-loss 缺陷）
**类型**：bug-fix
**Spec**：`docs/superpowers/specs/2026-06-15-wave3-13a-r2-cross-lease-cache-design.md`（v2，opus 4.8 xhigh 评审 APPROVE 0C/0H）
**Plan**：`docs/superpowers/plans/2026-06-15-wave3-13a-r2-cross-lease-cache.md`
**关闭目标**：`docs/governance/2026-06-14-wave3-completion.md` 顶层 ledger `known-defect-13a-R2-cross-lease-cache-deletion` OPEN → CLOSED

---

## 验收表（action / 期望 / □Pass / □Fail）

| # | 操作 | 期望 | 结果 |
|---|------|------|------|
| 1 | 打开 `ios/Contracts/Sources/KlineTrainerContracts/DownloadAcceptance/DownloadAcceptanceRunner.swift`，查看 diff | 新增私有方法 `deleteCachedFileIfUnowned(trainingSetId:)`；`retryPendingConfirmations` 的 reject 分支改调该 helper；`run()` 的 reject 分支同样改调该 helper；两处均不再裸 `id`-only 删除 | □ Pass / □ Fail |
| 2 | 继续查看 `deleteCachedFileIfUnowned` 的方法体 | 循环查询 `{stored, confirmPending, confirmed}` 三个状态，任一含有该 `trainingSetId` 的行 → 立即 return 不删；`listByState` 读失败（`try?` 返回 nil）→ 立即 return 不删；全部查完均无占有行时，才执行 `cache.delete` | □ Pass / □ Fail |
| 3 | 在终端进入 `ios/Contracts` 目录，运行 `swift test` | 全绿，0 failure；含新增 5 类回归测试（核心跨 lease 保护、两孤儿收敛删除、stored 占有保护、fail-safe 读失败不删、既有单孤儿仍删）+ 既有全部 P2 run/retry 测试 | □ Pass / □ Fail |
| 4 | 在测试输出中找到 `retry_crossLease_doesNotDeleteNewerLeaseFile` | 该测试通过；含义：旧 lease 孤儿孤被拒后，新 lease 占有的 id=42 文件**保留**（`cache.listAvailable` 仍含 id=42；`cache.deletedFilenames` 为空） | □ Pass / □ Fail |
| 5 | 临时把 helper 体改为无 guard 的直接删除（id-only 回退），运行 `swift test --filter retry_crossLease_doesNotDeleteNewerLeaseFile` | 核心回归测试 **FAIL**（mutation 证其为 killer 测试，非 vacuous）；还原后重跑确认 PASS | □ Pass / □ Fail |
| 6 | 打开 `docs/governance/2026-06-14-wave3-completion.md`，查看机器块（`<!-- WAVE3-STATUS` 至 `-->` 之间）第 18 行，以及 `scripts/governance/verify-wave3-completion.sh` 第 51 行 | 机器块该行 = `known-defect-13a-R2-cross-lease-cache-deletion: CLOSED 13a-R2 #<PR>`；gate 第 51 行 `require_kv` 期望值 = `CLOSED 13a-R2 #<PR>`（与机器块**逐字一致**）；runtime-matrix L87 同步显示 13a-R2 已解，W3-11-R1 仍为 OPEN 功能门；store-ready/formal-closure/feature-completeness 未改（W3-11-R1 与运行时矩阵仍 OPEN） | □ Pass / □ Fail |
| 7 | 在仓库根目录运行 `bash scripts/governance/verify-wave3-completion.sh` | 输出含 `[verify-wave3-completion] PASS` | □ Pass / □ Fail |
| 8 | 在终端运行 `grep -rnF 'listAvailable().first(where: { $0.id ==' ios/Contracts/Sources/` | 恰好 1 处，在 `DownloadAcceptanceRunner.swift` 的 `deleteCachedFileIfUnowned` helper 内；`retryPendingConfirmations` 与 `run()` 不再直接裸用此模式（`TrainingSessionCoordinator` 的损坏删除属另一类，不在本范围） | □ Pass / □ Fail |
