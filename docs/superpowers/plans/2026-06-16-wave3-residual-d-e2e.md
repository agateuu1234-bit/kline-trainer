# Wave 3 residual-D 闭合实施计划（生产路径 E2E smoke 接真 verifier）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `residual-D-e2e-smoke` 从 PARTIAL 闭合为 CLOSED——新增正/反向 E2E 测试，用**真 `DefaultTrainingSetDataVerifier`** 跑真 `DownloadAcceptanceRunner` 全管线，覆盖此前唯一未 smoke 的「runner ↔ 真 verifier」接线；并同步治理账本 + grep gate。

**Architecture:** 零生产代码改动。新增测试内 `private` helper 生成 verifier-valid candles（6 周期共享 datetime 网格 `startDT−30+e`，使非 m3 的 `partitioningIndex s == endgidx` 满足 reader 校验 2；m3 `globalIndex==endgidx==e` 连续从 0），喂给既有 `TrainingSetSQLiteFixture.make`。正向 = 真 verifier 放行 → `.confirmed` + 下游可消费；反向 = daily 减至 29-before → 真 verifier 拒 → runner 传播 `.rejected(.trainingSet(.emptyData))`。治理 doc + gate 把 D 标 CLOSED。

**Tech Stack:** Swift Testing（`@Test`/`#expect`/`#require`）、SwiftPM（`ios/Contracts`）、GRDB、Bash grep gate。

**source spec（已 opus 4.8 xhigh 对抗 review 2 轮收敛 APPROVE）:** `docs/superpowers/specs/2026-06-16-wave3-residual-d-e2e-design.md`

**phase_delivery:** true（feature + governance 混合；acceptance = 测试机制验证 + 治理一致性，见末节中文非-coder 清单）

---

## 文件结构

| 文件 | 动作 | 职责 |
|---|---|---|
| `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift` | Modify | +1 `private static` helper + 2 测试（正/反向真 verifier E2E） |
| `docs/governance/2026-06-14-wave3-completion.md` | Modify | WAVE3-STATUS 块 D → CLOSED；§三 行 D → CLOSED + 删「不现实」半句；§六 `D PARTIAL`→`D CLOSED` |
| `scripts/governance/verify-wave3-completion.sh` | Modify | 谓词 L47 + 注释 L5/L43 + echo L73 全部 PARTIAL→CLOSED |
| `docs/acceptance/2026-06-16-wave3-residual-d-e2e.md` | Create | 中文非-coder 验收清单（action/expected/pass-fail） |

**约束依据（worktree base c7feea8 真实代码，已逐条核实 + opus xhigh R2 独立 Python 验算）：**
- 真 verifier `DefaultTrainingSetDataVerifier.swift:27-42`：每周期 `before(datetime<startDT)>=30` + `after(>=startDT)>=(monthly?8:1)`，**逐周期独立、不查物理聚合**。
- reader `DefaultTrainingSetReader.swift`：m3 轴 `g==endgidx==i`（L153-160）+ 校验 1 m3 datetime 严格递增（L161-168）+ 非 m3 `endgidx<=m3Max`（L170-175）+ **校验 2** 每非 m3 `partitioningIndex{m3.dt>=c.dt} <= c.endgidx`（L177-187）。
- runner `DownloadAcceptanceRunner.swift`：verifier 在 L85（Step 4+5）；抛错走 L109-115 catch → `.rejected` + 写 journal `.rejected` + cleaner；`cache.store` 在 L91（verifier 之后）。

---

## Task 1：verifier-valid helper + 正向 E2E（真 verifier → confirmed + 下游可消费）

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift`（在 `struct DownloadAcceptanceRunnerIntegrationTests` 内、既有两个 `@Test` 之后追加）

- [ ] **Step 1：写 helper + 正向失败测试**

在 `FakeAPIClient` 之后、`@Suite` struct 内追加 helper 与测试。helper：

```swift
    /// 生成 verifier-valid candles：6 周期共享同一 datetime 网格（datetime = startDT − 30 + e，
    /// e = end_global_index），使非 m3 的 reader 校验 2 `partitioningIndex{m3.dt>=c.dt}=e <= endgidx=e` 临界成立；
    /// m3 globalIndex = endGlobalIndex = e 连续从 0。
    /// - dailyBeforeStart: 0 = 正向（daily e∈0…37 → 30 before + 8 after）；
    ///   1 = 反向（daily 丢 e=0 → e∈1…37 → 29 before + 8 after，仍保网格对齐过 reader 校验2）。
    private static func verifierValidCandles(
        startDT: Int64,
        dailyBeforeStart: Int = 0
    ) -> [(Period, [(datetime: Int64, gIdx: Int?, endGIdx: Int)])] {
        Period.allCases.map { period in
            let eStart = (period == .daily) ? dailyBeforeStart : 0
            let rows: [(datetime: Int64, gIdx: Int?, endGIdx: Int)] = (eStart...37).map { e in
                (datetime: startDT - 30 + Int64(e),
                 gIdx: period == .m3 ? e : nil,
                 endGIdx: e)
            }
            return (period, rows)
        }
    }
```

正向测试：

```swift
    @Test func run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable() async throws {
        let startDT: Int64 = 1_700_000_000   // == ConfigOptions 默认 meta.startDatetime
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = Self.verifierValidCandles(startDT: startDT)
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make(opts)
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2RealV-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }
        let journal = InMemoryAcceptanceJournalDAO()
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(download: .success(zipURL), confirmError: nil),
            cache: DefaultFileSystemCacheManager(cacheRoot: cacheRoot),
            dbFactory: DefaultTrainingSetDBFactory(),
            journal: journal,
            integrity: DefaultZipIntegrityVerifier(),
            extractor: DefaultZipExtractor(),
            dataVerifier: DefaultTrainingSetDataVerifier(),   // 真 verifier（非 fake）
            cleaner: DefaultDownloadAcceptanceCleaner())
        let meta = TrainingSetMetaItem(
            id: 88, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "33333333-3333-3333-3333-333333333333")
        guard case .confirmed(let file) = result else {
            Issue.record("expected .confirmed via real verifier pipeline, got \(result)"); return
        }
        #expect(file.id == 88)
        #expect(file.schemaVersion == TRAINING_SET_SCHEMA_VERSION)
        #expect(try journal.listByState(.confirmed).count == 1)

        // 下游可消费 + 复述真 verifier 通过条件（钉死真 verifier 真跑过：每周期 before≥30 / after 足）
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(
            file: file.localURL, expectedSchemaVersion: TRAINING_SET_SCHEMA_VERSION)
        defer { reader.close() }
        let loaded = try reader.loadAllCandles()
        for period in Period.allCases {
            let arr = try #require(loaded[period], "周期 \(period) 应非空")
            let before = arr.filter { $0.datetime < startDT }.count
            let after = arr.filter { $0.datetime >= startDT }.count
            #expect(before >= 30, "\(period) before=\(before) 应 ≥30")
            #expect(after >= (period == .monthly ? 8 : 1), "\(period) after=\(after) 不足")
        }
        #expect(loaded[.m3]?.first?.globalIndex == 0)
    }
```

- [ ] **Step 2：跑测试，确认通过（若 red 则 fixture 违反约束，进 systematic-debugging）**

Run: `cd ios/Contracts && swift test --filter "run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable" 2>&1 | tail -30`
Expected: PASS（`.confirmed`，6 周期 before≥30/after 足，m3.first.globalIndex==0）。
若得 `.rejected(.persistence(.dbCorrupted))` = fixture 违反 reader 不变量（最可能是 datetime↔endgidx 网格未对齐破坏校验 2）→ 对照 spec §三/§四逐条核 helper，**不要**改 fixture 数字以外的东西。

- [ ] **Step 3：commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift
git commit -m "test(residual-D): 正向 E2E 真 verifier 跑通真 runner 管线 → confirmed + 下游可消费"
```

---

## Task 2：反向 E2E（真 verifier 拒 29-before → runner 传播 .rejected(.emptyData)）+ mutation-kill 验证

**Files:**
- Modify: 同上文件（追加 1 测试）

- [ ] **Step 1：写反向测试**

```swift
    @Test func run_realPipeline_withRealVerifier_rejectsWhenPeriodUnderThirtyBefore() async throws {
        let startDT: Int64 = 1_700_000_000
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        // daily 丢 e=0 → 29 before（仍保 datetime=startDT−30+e 网格对齐，过 reader 校验2）；其余周期 38 根
        opts.candles = Self.verifierValidCandles(startDT: startDT, dailyBeforeStart: 1)
        let (sqliteFixtureURL, cleanupSqlite) = try TrainingSetSQLiteFixture.make(opts)
        defer { cleanupSqlite() }
        let sqliteBytes = try Data(contentsOf: sqliteFixtureURL)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("P2RealVNeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let (zipURL, crcHex) = try ZipFixture.makeMinimalSqliteZip(
            in: workDir, sqliteFileName: "training.sqlite", sqlitePayload: sqliteBytes)

        let cacheRoot = CacheFixture.makeTempCacheRoot()
        defer { CacheFixture.cleanup(cacheRoot) }
        let journal = InMemoryAcceptanceJournalDAO()
        let cache = DefaultFileSystemCacheManager(cacheRoot: cacheRoot)
        let runner = DownloadAcceptanceRunner(
            api: FakeAPIClient(download: .success(zipURL), confirmError: nil),
            cache: cache,
            dbFactory: DefaultTrainingSetDBFactory(),
            journal: journal,
            integrity: DefaultZipIntegrityVerifier(),
            extractor: DefaultZipExtractor(),
            dataVerifier: DefaultTrainingSetDataVerifier(),   // 真 verifier
            cleaner: DefaultDownloadAcceptanceCleaner())
        let meta = TrainingSetMetaItem(
            id: 99, stockCode: "600001", stockName: "测试股票",
            filename: "training.zip", schemaVersion: 1, contentHash: crcHex)

        let result = await runner.run(meta: meta, leaseId: "44444444-4444-4444-4444-444444444444")
        guard case .rejected(let err) = result else {
            Issue.record("expected .rejected via real verifier (daily 29-before), got \(result)"); return
        }
        // 拒绝码精确 = verifier 的 trainingSet(.emptyData)（区分 reader 的 .persistence(.dbCorrupted) / confirm 的 .network*）
        #expect(err == .trainingSet(.emptyData), "真 verifier 拒绝码应为 trainingSet(.emptyData)，实得 \(err)")
        // verifier 在 cache.store 前抛错 → cache 无该组 + 无 confirmed journal
        #expect(cache.listAvailable().contains(where: { $0.id == 99 }) == false)
        #expect(try journal.listByState(.confirmed).isEmpty)
    }
```

- [ ] **Step 2：跑反向测试，确认通过**

Run: `cd ios/Contracts && swift test --filter "run_realPipeline_withRealVerifier_rejectsWhenPeriodUnderThirtyBefore" 2>&1 | tail -30`
Expected: PASS（`.rejected`，err == `.trainingSet(.emptyData)`，cache 无 id=99，无 confirmed）。

- [ ] **Step 3：mutation-kill 验证（临时改、跑、还原——不 commit）**

证明反向测试真依赖「真 verifier 的拒绝穿过 runner」，而非 vacuous：把反向测试里 `dataVerifier: DefaultTrainingSetDataVerifier()` **临时**改成 `FakeTrainingSetDataVerifier()`。
Run: `cd ios/Contracts && swift test --filter "run_realPipeline_withRealVerifier_rejectsWhenPeriodUnderThirtyBefore" 2>&1 | tail -20`
Expected: **FAIL**（fake 放行 → runner 走到 confirm → `.confirmed` → `guard case .rejected` 触发 `Issue.record`）。
观察到 FAIL 后**立即还原**为 `DefaultTrainingSetDataVerifier()`，重跑 Step 2 确认回到 PASS。此步**不 commit**（仅证明测试有效）。

- [ ] **Step 4：commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DownloadAcceptanceRunnerIntegrationTests.swift
git commit -m "test(residual-D): 反向 E2E 真 verifier 拒 29-before → runner 传播 .rejected(.emptyData)（mutation-kill 已验证）"
```

---

## Task 3：治理完成 doc 标 residual-D CLOSED（删「不现实」半句）

**Files:**
- Modify: `docs/governance/2026-06-14-wave3-completion.md`

- [ ] **Step 1：WAVE3-STATUS 机器块 D → CLOSED**

把（约 L16）：
```
residual-D-e2e-smoke: PARTIAL 13b #109
```
改为：
```
residual-D-e2e-smoke: CLOSED residual-D 2026-06-16
```

- [ ] **Step 2：§三 行 D 改 CLOSED + 删「不现实」半句**

把 §三 表的行 D（以 `| **D. 生产路径 E2E smoke** |` 开头那一整行）替换为：
```
| **D. 生产路径 E2E smoke** | §107 deferred / spec §D | **CLOSED**（residual-D 2026-06-16） | 13b PR #109 `fc46fef` 已 smoke runner 管线（download/crc/unzip/db-open/store/confirm/journal/下游 open），但注入 `FakeTrainingSetDataVerifier`（13b-R2）→ runner ↔ 真 `DefaultTrainingSetDataVerifier` 接线未覆盖。**本 PR（residual-D）闭合该接线**：新增正/反向 E2E（`DownloadAcceptanceRunnerIntegrationTests.run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable` + `…_rejectsWhenPeriodUnderThirtyBefore`）用**真 verifier** 跑全真管线——verifier-valid fixture（6 周期各 30 before+8 after、非 m3 datetime 与 m3 网格对齐过 reader 校验 1/2）→ `.confirmed` + 下游可消费；daily 减至 29-before → runner 传播 `.rejected(.trainingSet(.emptyData))`。**13b-R2「满足真 verifier 的 fixture 不现实」评估据此证伪并解决**（真 verifier 逐周期独立计数、不要求物理聚合/多年跨度，~228 根即足；设计见 `docs/superpowers/specs/2026-06-16-wave3-residual-d-e2e-design.md`）。PR# merge 后回填 |
```
（**关键：原行末「满足真 verifier 的 ≥30-全周期-含-monthly fixture 不现实（13b accept residual），但 D 终态如实 PARTIAL 不掩盖」整句已删除/替换**——否则 CLOSED 与「不现实」同行自相矛盾。）

- [ ] **Step 3：§六 评审通道说明 D PARTIAL → CLOSED**

在 §六（约 L124）把 `A/B/C CLOSED + **D PARTIAL** +` 改为 `A/B/C CLOSED + **D CLOSED（residual-D 2026-06-16）** +`。**只改这一处 `D PARTIAL`**，不动同段「13a-R2 RESOLVED（本 PR）」（那个「本 PR」指 13c，非本 residual-D PR）。

- [ ] **Step 4：commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add docs/governance/2026-06-14-wave3-completion.md
git commit -m "gov(residual-D): 完成 doc 标 residual-D CLOSED + 删行D 不现实半句"
```

---

## Task 4：grep gate 谓词 + 全部注释同步 PARTIAL → CLOSED

**Files:**
- Modify: `scripts/governance/verify-wave3-completion.sh`

- [ ] **Step 1：功能谓词 L47**

把：
```
require_kv "residual-D-e2e-smoke" "PARTIAL 13b #109"
```
改为：
```
require_kv "residual-D-e2e-smoke" "CLOSED residual-D 2026-06-16"
```
（须与 Task 3 Step 1 的 doc 块行**逐字一致**：`residual-D-e2e-smoke: CLOSED residual-D 2026-06-16`。）

- [ ] **Step 2：头注释 L5**

把：
```
# 谓词 1：residual A/B/C 标 CLOSED + D 标 PARTIAL（块内全行；D=PARTIAL per R4-Med fake verifier）
```
改为：
```
# 谓词 1：residual A/B/C/D 标 CLOSED（块内全行；D=CLOSED residual-D 2026-06-16：本 PR 接真 verifier，runner↔真 verifier 经正/反向 E2E 覆盖）
```

- [ ] **Step 3：谓词 1 inline 注释 L43**

把：
```
# 谓词 1：residual A/B/C = CLOSED；D = PARTIAL（codex R4-Med：§D smoke 用 fake verifier，runner↔真 verifier 接线未 smoke 覆盖）
```
改为：
```
# 谓词 1：residual A/B/C = CLOSED；D = CLOSED（residual-D 2026-06-16：§D smoke 接真 DefaultTrainingSetDataVerifier，runner↔真 verifier 经正/反向 E2E 覆盖）
```

- [ ] **Step 4：末行 echo L73**

把 PASS echo 里的 `D PARTIAL` 改为 `D CLOSED`（其余串不动）。

- [ ] **Step 5：跑 gate，确认 PASS**

Run: `bash scripts/governance/verify-wave3-completion.sh`
Expected: `[verify-wave3-completion] PASS：...A/B/C CLOSED + D CLOSED + ...`（exit 0）。
自查无残留：`grep -nE "PARTIAL|fake verifier|不现实" scripts/governance/verify-wave3-completion.sh` 应仅余 `runtime-matrix` 相关 PARTIAL（与 residual-D 无关，正当保留），无 residual-D 的 PARTIAL/fake/不现实 措辞。

- [ ] **Step 6：commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add scripts/governance/verify-wave3-completion.sh
git commit -m "gov(residual-D): grep gate 谓词+全注释同步 D=CLOSED（L5/L43/L47/L73）"
```

---

## Task 5：中文非-coder 验收清单（CLAUDE.md backstop #2）

**Files:**
- Create: `docs/acceptance/2026-06-16-wave3-residual-d-e2e.md`

- [ ] **Step 1：写验收清单**（内容见本计划末「验收清单」节，整段落盘）

- [ ] **Step 2：commit**

```bash
cd "$(git rev-parse --show-toplevel)"
git add docs/acceptance/2026-06-16-wave3-residual-d-e2e.md
git commit -m "docs(residual-D): 中文非-coder 验收清单"
```

---

## Task 6：完成前验证（verification-before-completion 阶段执行）

- [ ] **Step 1：跑 Persistence 全套件**

Run: `cd ios/Contracts && swift test --filter KlineTrainerPersistenceTests 2>&1 | tail -25`
Expected: 全绿，0 failures，含 2 新测试 + 既有 fake-verifier 测试不回归。

- [ ] **Step 2：跑全量 swift test**

Run: `cd ios/Contracts && swift test 2>&1 | tail -15`
Expected: 全绿 0 failures（记录 tests/suites 数作证据）。

- [ ] **Step 3：跑 gate**

Run: `bash scripts/governance/verify-wave3-completion.sh; echo "exit=$?"`
Expected: PASS + exit=0。

- [ ] **Step 4：grep 自查无残留**

Run: `grep -nE "residual-D-e2e-smoke" docs/governance/2026-06-14-wave3-completion.md scripts/governance/verify-wave3-completion.sh`
Expected: doc 块 + gate 谓词均 `CLOSED residual-D 2026-06-16`，无 `PARTIAL 13b #109` 残留。

> 注：Catalyst / swift-test / app-build CI 为第二层（本地 toolchain blindspot 历史教训）；本地全绿后仍以 CI 绿为准。

---

## 验收清单（落盘到 `docs/acceptance/2026-06-16-wave3-residual-d-e2e.md`）

```markdown
# Wave 3 residual-D 闭合 验收清单（中文非-coder 可执行）

**PR 范围**：把 `residual-D-e2e-smoke` 从 PARTIAL 闭合为 CLOSED。新增正/反向 E2E 测试用**真** `DefaultTrainingSetDataVerifier` 跑真 `DownloadAcceptanceRunner` 全管线（此前 smoke 用 fake verifier，runner↔真 verifier 接线未覆盖）。0 生产代码改动；改测试 + 治理 doc + grep gate。

**source-of-truth**：spec `docs/superpowers/specs/2026-06-16-wave3-residual-d-e2e-design.md`；plan `docs/superpowers/plans/2026-06-16-wave3-residual-d-e2e.md`。

**评审通道（trust-boundary）**：改 `ios/**/*.swift` + `docs/governance/**` + `scripts/**` → 须 codex:adversarial-review（配额耗尽 fallback opus 4.8 xhigh）+ Catalyst + swift-test + app-build；`docs/governance/**`、`scripts/**`、`docs/superpowers/**` 在 codeowners_required_globs → 须 CODEOWNERS approve。

## 验收步骤

| Step | Action（操作） | Expected（预期可观察结果） | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR，看 `DownloadAcceptanceRunnerIntegrationTests.swift` diff | 新增 1 个 `verifierValidCandles` helper + 2 个 `@Test`：`run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable`（正向）/ `…_rejectsWhenPeriodUnderThirtyBefore`（反向），二者注入 `DefaultTrainingSetDataVerifier()`（非 fake） | □ Pass / □ Fail |
| 2 | 看正向测试断言 | 期望 `.confirmed` + `file.schemaVersion == TRAINING_SET_SCHEMA_VERSION` + 6 周期每个 before≥30/after 足 + `m3.first.globalIndex==0` | □ Pass / □ Fail |
| 3 | 看反向测试断言 | 期望 `.rejected` 且错误**精确**为 `.trainingSet(.emptyData)` + cache 无该组 + 无 confirmed journal | □ Pass / □ Fail |
| 4 | 看 CI「swift test on macos-15」 | 绿；含 2 新测试 + 既有测试不回归 | □ Pass / □ Fail |
| 5 | 看 CI「Mac Catalyst build-for-testing」+「app-build」 | 均绿 | □ Pass / □ Fail |
| 6 | 看 `docs/governance/2026-06-14-wave3-completion.md` diff | WAVE3-STATUS 块 `residual-D-e2e-smoke: CLOSED residual-D 2026-06-16`；§三 行 D 标 CLOSED 且**已删除「…fixture 不现实」半句**；§六 `D CLOSED` | □ Pass / □ Fail |
| 7 | 看 `scripts/governance/verify-wave3-completion.sh` diff | 谓词 + L5/L43 注释 + L73 echo 全部 `D=CLOSED`；无残留 residual-D 的 PARTIAL/fake-verifier/不现实 措辞 | □ Pass / □ Fail |
| 8 | 看 codex 对抗 review verdict（或配额耗尽 opus 4.8 xhigh fallback） | APPROVE | □ Pass / □ Fail |
| 9 | 看 CODEOWNERS approve | 仓库 owner 已 approve（governance/scripts 触发） | □ Pass / □ Fail |

## 范围注 / 已知边界

- **不动 device 运行时矩阵**：residual-D（host E2E 接线覆盖）与 `runtime-matrix: PARTIAL`（device 实测）正交；本 PR 不触 runtime-matrix / formal-closure / feature-completeness / freeze-tag / W3-11-R1 / ship 门。
- **不回写 13b 历史快照**：`docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md` 与完成 doc L92 13b 脚注是历史记录，保持不变。
- **0 生产代码改动**：runner/verifier/reader/fixture writer 均未改；仅新增测试覆盖。
```

---

## Self-Review

**1. Spec coverage**：
- spec §四 fixture → Task 1 helper（datetime 网格对齐 + m3 g==endgidx==i）✓
- spec §五.1 正向 → Task 1 ✓；§五.2 反向（daily 丢 e=0）→ Task 2 ✓；mutation-kill → Task 2 Step 3 ✓
- spec §七.1 测试改动 → Task 1/2 ✓；§七.2 doc flip + 删「不现实」→ Task 3 ✓；§七.3 gate L5/L43/L47/L73 → Task 4 ✓
- spec §九 验收 → Task 5 + Task 6 ✓

**2. Placeholder scan**：无 TBD/TODO；所有测试代码、doc/gate old→new 文本、命令均完整给出。PR# 在 doc 散文标「merge 后回填」是有意的（机器块/gate 用日期戳无占位符）。

**3. Type consistency**：helper 返回 `[(Period, [(datetime: Int64, gIdx: Int?, endGIdx: Int)])]` == `ConfigOptions.candles` 类型；测试用符号（`DefaultTrainingSetDataVerifier`/`FakeTrainingSetDataVerifier`/`TrainingSetSQLiteFixture.ConfigOptions`/`ZipFixture`/`CacheFixture`/`InMemoryAcceptanceJournalDAO`/`DefaultFileSystemCacheManager`/`TrainingSetMetaItem`/`TRAINING_SET_SCHEMA_VERSION`/`AcceptanceResult` cases）均为既有 API；`err == .trainingSet(.emptyData)` 依赖 `AppError: Equatable`（`AcceptanceResult: Equatable` 已蕴含）。gate 谓词字符串与 doc 块字符串逐字一致（`CLOSED residual-D 2026-06-16`）。
