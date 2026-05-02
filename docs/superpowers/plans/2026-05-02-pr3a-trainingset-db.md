# PR 3a: P3a Factory + P3b Reader 真实现 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 SwiftPM 中落地 P3a `DefaultTrainingSetDBFactory` 与 P3b `DefaultTrainingSetReader` 的 GRDB production 实现，使训练组 SQLite 文件能被打开并按 spec §M0.1 / §P3a / §P3b 的契约行为读取（schema_version 校验、meta 加载、按 Period 分组读 candles、close 释放）。

**Architecture:** 在 `ios/Contracts/Package.swift` 新建独立 target `KlineTrainerPersistence`（依赖 `KlineTrainerContracts` + `GRDB.swift` 7.x）—— GRDB 不进纯类型契约层 `KlineTrainerContracts`。Factory 无状态：每次 `openAndVerify` 创建独立 read-only `DatabaseQueue`，**只在闭包内做 IO（read PRAGMA + meta row），校验逻辑全部移到闭包外**（避免 GRDB 闭包错误透传歧义）；通过则返回 `DefaultTrainingSetReader` 实例，已 cache meta。Reader 持有 `var queue: DatabaseQueue?` + cached meta；`close` 设 nil 触发 ARC 释放 queue + flag isClosed；后续 read 抛 `AppError.internalError(module: "P3b", detail: "reader closed")`。

**Tech Stack:** Swift 6.0 / SwiftPM / GRDB.swift 7.x（最新稳定，Swift 6 strict concurrency 兼容） / XCTest / `KlineTrainerContracts`（已 merged 的 protocols + AppError + Models）

**Round 2 修订标记**：本 plan 经 opus 4.7 xhigh adversarial review round 1（28 findings），全部 5 CRITICAL + 13 实质 MAJOR + 9 MINOR 已应用修订；residual 见末尾 Self-Review。

---

## Design Decisions（review 必读 12 条）

下面 12 条是 spec 没显式定义、本 plan 自行选择的边界。每条都需 reviewer 单独评估：

1. **Package 分层**：在 `ios/Contracts/Package.swift` 新增独立 target `KlineTrainerPersistence`，使 GRDB **不污染** `KlineTrainerContracts` 纯类型契约。Contracts 仍为零三方依赖。
2. **GRDB read-only**：`Configuration.readonly = true` —— 训练组 sqlite 是 zip 解出的只读文件，禁止写。读 `PRAGMA` / `SELECT` 在 read-only 下可用。
3. **meta 表行数语义**：spec / schema 未声明唯一性。落地：`SELECT ... LIMIT 1`，0 行 → `AppError.trainingSet(.emptyData)`；≥1 行取第一行（spec gap，按 Postel 宽容；不抛 `.dbCorrupted` 以避开"多行 ≠ 损坏"误判）。
4. **klines 表为空**：openAndVerify **不**校验 klines 表数据；该阶段只 fail-fast meta。klines 空属于 `loadAllCandles` 返回空字典的合法情形，调用方 E6 / TrainingEngine 自行处理（spec §11.3 fixture 路径也允许返回空）。
5. **close 后再调用**：spec 未规定。落地：内部 `var queue: DatabaseQueue?` + `isClosed` flag；close 设 queue=nil + isClosed=true 触发 ARC 释放 queue（spec L1848 "释放 DatabaseQueue" 字面落地）；close 幂等；close 后再调 `loadMeta` / `loadAllCandles` 抛 `AppError.internalError(module: "P3b", detail: "reader closed")`（**不**用 `.persistence(.ioError)`：caller 误用属编程错误，不是 IO 故障；`.internalError` 的 `shouldShowToast=false` 走内部日志，不向用户显示"读写失败请重试"误导文案）。
6. **Period parsing**：klines.period 列存 raw value（`"3m" / "15m" / "60m" / "daily" / "weekly" / "monthly"`，与 `Period` enum rawValue 一致）。未知 raw value → 抛 `AppError.persistence(.dbCorrupted)`（不静默丢弃，违反 trainingSet 数据完整性假设）。
7. **GRDB 错误翻译**：所有 `DatabaseError` / `IOError` 在 `KlineTrainerPersistence` 模块边界处显式转 `AppError`（per `docs/governance/m04-apperror-translation-gate.md` Gate 1）。映射：
   - `SQLITE_CANTOPEN` 且文件不存在 → `.trainingSet(.fileNotFound)`
   - `SQLITE_CANTOPEN` 其它原因（权限等）→ `.persistence(.ioError("sqlite_cantopen"))`
   - `SQLITE_NOTADB` / `SQLITE_CORRUPT` → `.persistence(.dbCorrupted)`
   - `SQLITE_ERROR`（如 "no such table"）→ `.persistence(.ioError("sqlite_error"))`
   - 其它 GRDB DatabaseError → `.persistence(.ioError("sqlite_error_<code>"))`
   - decoding error（列类型 / Period rawValue）→ `.persistence(.dbCorrupted)`
   - **`ioError` 关联值字串使用脱敏 token**（如 `"sqlite_error_<code>"`），**不**直接放 `dbErr.message`——dbErr.message 含底层路径 / 环境信息，AppError.swift 已有 codex finding 禁止泄漏（line 72-73 已落地 userMessage 隐藏 detail；本 plan 进一步禁止把 raw msg 写入 associated value）。
8. **schemaMismatch vs versionMismatch 区分**：训练组 SQLite 版本失配走 `AppError.trainingSet(.versionMismatch(expected:got:))`（per m01 governance "P3a runtime 拒收 owner"）；**不要** 误用 `PersistenceReason.schemaMismatch(expected:got:)`——后者是 P4 AppDB GRDB migration 用的 reason（per m01 §"Plan 3 P4 AppDB"），两个 reason 在 AppError 枚举中并存但 owner 不同。
9. **GRDB 7 API 锚点**：本 plan 假定 GRDB 7.x 提供以下 API（落地若编译失败按编译器提示修，并在 PR 描述 `Known surprise` 段记录差异）：
   - `Configuration` 是值类型 struct，含 `var readonly: Bool` 属性
   - `DatabaseQueue.init(path: String, configuration: Configuration)` 构造
   - `DatabaseQueue.read(_:)` / `.write(_:)` 接受 throwing closure，**闭包内抛 Swift 错误（含自定义 AppError）原样 rethrow**
   - `DatabaseError.resultCode: ResultCode` —— **`ResultCode` 是 struct**（含 static let `.SQLITE_CANTOPEN` / `.SQLITE_NOTADB` / `.SQLITE_CORRUPT` / `.SQLITE_ERROR` 等 SQLite 原生 code）；switch 不能用 `case .SQLITE_CANTOPEN:` enum-style，只能用 `if dbErr.resultCode == .SQLITE_CANTOPEN { ... }` 或 `case let c where c == .SQLITE_CANTOPEN`。本 plan 全部用 if-比较风格。
   - `Int.fetchOne(_:sql:)` / `Row.fetchOne(_:sql:)` / `Row.fetchAll(_:sql:)` 在 read closure 中可用
   - `Row` 下标 `row["col_name"] as Int64` / `as Double` / `as String` 走 `DatabaseValueConvertible`；nullable 列用 `as Int64?`
10. **Swift 6 + GRDB 7 import 策略**：所有 `KlineTrainerPersistence` 文件用 `@preconcurrency import GRDB`，避免 strict-concurrency 误报"Type from module GRDB may not conform to Sendable"。GRDB 7 主要 protocol 已标 Sendable，但部分 transitive 类型可能 still pre-Sendable，`@preconcurrency` 是保守 fallback，落地若 build 0 warning 可移除。
11. **fixture 生成**：测试 fixture 不复用 `backend/sql/training_set_schema_v1.sql`；测试侧自包含写 inline DDL 生成器（避免 SwiftPM 测试依赖 Python backend / 路径硬编码）。fixture 生成的 sqlite 文件用 **per-test UUID 子目录**（不共享单一 tmp dir），避免 `XCTest` 并行执行下多 test class race delete 互相文件。
12. **子项计数**：本 PR 核心子项 = P3a Factory + P3b Reader = **2 个**（fixture / mapping helper / 验收 doc 是配套，不算独立子项）；符合 `feedback_planner_packaging_bias.md` ≤3 子项硬规则。

---

## File Structure

**Create:**
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetDBFactory.swift`（factory 实现，~60 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift`（reader 实现，~80 行）
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift`（GRDB 错误 → AppError 翻译，~50 行）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixture.swift`（测试 fixture 生成器，仅 test target 用，~120 行）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixtureTests.swift`（fixture 自检 tests，~80 行 / 3 tests；由 Task 2 中 Placeholder.swift `git mv` 而来）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetDBFactoryTests.swift`（~150 行 / 6 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift`（~150 行 / 5 tests）
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/HappyPathIntegrationTests.swift`（~80 行 / 1 test）

**Modify:**
- `ios/Contracts/Package.swift`（整文件重写，27 行 → ~55 行）

**总量预估**：prod ~190 行（< 500 硬规则），test ~500 行（不计入硬规则）。**核心子项 = 2**（P3a Factory + P3b Reader）。

---

## Task 1: SwiftPM 配置 — 加 GRDB 依赖 + KlineTrainerPersistence target

**Files:**
- Modify: `ios/Contracts/Package.swift`（整文件重写）

**为什么先做这步：** 后续所有 task 都依赖 Persistence target 存在；先把骨架搭好，每个后续 task 才能跑 `swift test --filter ...`。

- [ ] **Step 1.0: 创建 feature branch（防污染 main）**

当前 git status: branch=main。先开 feature branch 再做后续 commit：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer"
git status
# 期望: On branch main, working tree clean
git checkout -b pr3a-trainingset-db
git status
# 期望: On branch pr3a-trainingset-db
```

- [ ] **Step 1.1: 把 GRDB.swift 7 加为 package dependency**

修改 `ios/Contracts/Package.swift`，把整个文件替换为：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlineTrainerContracts",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(
            name: "KlineTrainerContracts",
            targets: ["KlineTrainerContracts"]
        ),
        .library(
            name: "KlineTrainerPersistence",
            targets: ["KlineTrainerPersistence"]
        ),
    ],
    dependencies: [
        // GRDB 7.x：Swift 6 strict concurrency 兼容；read-only DatabaseQueue / PRAGMA 支持。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "KlineTrainerContracts",
            path: "Sources/KlineTrainerContracts"
        ),
        .target(
            name: "KlineTrainerPersistence",
            dependencies: [
                "KlineTrainerContracts",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/KlineTrainerPersistence"
        ),
        .testTarget(
            name: "KlineTrainerContractsTests",
            dependencies: ["KlineTrainerContracts"],
            path: "Tests/KlineTrainerContractsTests",
            resources: [
                .copy("fixtures")
            ]
        ),
        .testTarget(
            name: "KlineTrainerPersistenceTests",
            dependencies: [
                "KlineTrainerPersistence",
                // 显式声明 GRDB（即使 transitive 可达）：fixture 直接 import GRDB 写测试 sqlite。
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/KlineTrainerPersistenceTests"
        ),
    ]
)
```

- [ ] **Step 1.2: 创建 placeholder 源文件让 SwiftPM build 通过**

```bash
mkdir -p "ios/Contracts/Sources/KlineTrainerPersistence/Internal"
mkdir -p "ios/Contracts/Tests/KlineTrainerPersistenceTests"
```

写文件 `ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift`：

```swift
// Placeholder：保证 KlineTrainerPersistence target 在 Task 1 阶段可 build。
// Task 3 落 DefaultTrainingSetDBFactory.swift 后此文件被 git rm 删除。
```

写文件 `ios/Contracts/Tests/KlineTrainerPersistenceTests/Placeholder.swift`：

```swift
import XCTest

final class PersistencePlaceholderTests: XCTestCase {
    func testTargetCompiles() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 1.3: 跑 `swift build` 验证 GRDB 解析成功**

在 `/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts/` 目录下：

```bash
swift build
```

Expected: 无错误，产生 `.build/` 目录，GRDB 7.x 拉下来。如果首次拉包慢可能需要 30s。

**Fallback（如果 build 报错）：**
- 若编译器提示 `'readonly' has been renamed to 'readOnly'`：按提示把所有 `config.readonly = true` 改成 `config.readOnly = true`（GRDB 主版本有可能微调命名，以编译器提示为准）。
- 若编译器对 GRDB 类型报 Sendable warning：在 Task 3 / 4 落地的源文件 `import GRDB` 改为 `@preconcurrency import GRDB`。
- 若 swift-tools-version 报错：核对 `swift --version` ≥ 6.0；项目配置见 `kline_trainer_modules_v1.4.md` §M0.5。

- [ ] **Step 1.4: 跑 placeholder test 验证 test target 工作**

```bash
swift test --filter PersistencePlaceholderTests
```

Expected: 1 test PASS。

- [ ] **Step 1.5: Commit**

```bash
git add ios/Contracts/Package.swift ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/Placeholder.swift
git commit -m "feat(P3): add KlineTrainerPersistence target + GRDB 7.x dependency"
```

---

## Task 2: TrainingSet SQLite 测试 Fixture 生成器

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixture.swift`

**为什么这步必要：** Task 3-5 全部测试需要"按需生成不同条件的训练组 sqlite 文件"（不同 user_version、空 meta、多种 Period 组合等）。集中写一个 fixture helper，避免每个 test 重复 GRDB 写代码。helper 用 GRDB 直接构造 sqlite，与 production 使用同一 GRDB 版本，保证 schema 真实性。

**Fixture 字段说明（与 `backend/sql/training_set_schema_v1.sql` 完全一致）：**
- `meta`（stock_code TEXT NOT NULL, stock_name TEXT NOT NULL, start_datetime INTEGER NOT NULL, end_datetime INTEGER NOT NULL）
- `klines`（id PK AUTOINCREMENT, period TEXT NOT NULL, datetime INTEGER NOT NULL, open/high/low/close REAL NOT NULL, volume INTEGER NOT NULL, amount REAL NULL, ma66 REAL NULL, boll_upper/mid/lower REAL NULL, macd_diff/dea/bar REAL NULL, global_index INTEGER NULL, end_global_index INTEGER NOT NULL）
- 索引：idx_period_endidx(period, end_global_index), idx_period_datetime(period, datetime)

**并发安全设计**：fixture make() 每次返回一个 **per-call UUID 子目录**下的文件路径，避免多 test class 共享路径互删；`make()` 内 DatabaseQueue 用 `do { ... }` 块作用域强制 ARC 提前释放，避免文件句柄竞争。

- [ ] **Step 2.1: 写 fixture helper**

写文件 `ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixture.swift`：

```swift
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
import KlineTrainerContracts

/// 构造测试用训练组 sqlite 文件。
/// - schema 与 backend/sql/training_set_schema_v1.sql 一致；helper 自包含不依赖 backend 路径
/// - 每次调用生成独立 UUID 子目录，避免并行测试 race
/// - 写入完成后 DatabaseQueue 显式作用域结束，触发 ARC 释放 + 文件句柄释放
enum TrainingSetSQLiteFixture {
    struct ConfigOptions {
        var userVersion: Int = 1
        var meta: TrainingSetMeta? = TrainingSetMeta(
            stockCode: "600001",
            stockName: "测试股票",
            startDatetime: 1_700_000_000,
            endDatetime: 1_700_086_400
        )
        var candles: [(Period, [(datetime: Int64, gIdx: Int?, endGIdx: Int)])] = [
            (.m3, [(1_700_000_000, 0, 0), (1_700_000_180, 1, 1)]),
            (.daily, [(1_700_000_000, nil, 1)]),
        ]
        var skipKlinesTable: Bool = false  // 用于 corrupt 测试
        var skipMetaTable: Bool = false    // 用于 corrupt 测试
    }

    /// 在 tmp 目录创建 sqlite 文件，返回 (URL, cleanupClosure)。
    /// 调用方在 tearDown 调 cleanup() 删除该文件所属的 per-call UUID 目录。
    static func make(_ options: ConfigOptions = ConfigOptions()) throws -> (url: URL, cleanup: () -> Void) {
        let perCallDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kline_trainer_persistence_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: perCallDir, withIntermediateDirectories: true)
        let fileURL = perCallDir.appendingPathComponent("training_set.sqlite")

        // 写入 sqlite，作用域结束 ARC 释放 queue
        do {
            let queue = try DatabaseQueue(path: fileURL.path)
            try queue.write { db in
                try db.execute(sql: "PRAGMA user_version = \(options.userVersion)")

                if !options.skipMetaTable {
                    try db.execute(sql: """
                    CREATE TABLE meta (
                        stock_code TEXT NOT NULL,
                        stock_name TEXT NOT NULL,
                        start_datetime INTEGER NOT NULL,
                        end_datetime INTEGER NOT NULL
                    )
                    """)
                    if let m = options.meta {
                        try db.execute(sql: """
                        INSERT INTO meta (stock_code, stock_name, start_datetime, end_datetime)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [m.stockCode, m.stockName, m.startDatetime, m.endDatetime])
                    }
                }

                if !options.skipKlinesTable {
                    try db.execute(sql: """
                    CREATE TABLE klines (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        period TEXT NOT NULL,
                        datetime INTEGER NOT NULL,
                        open REAL NOT NULL,
                        high REAL NOT NULL,
                        low REAL NOT NULL,
                        close REAL NOT NULL,
                        volume INTEGER NOT NULL,
                        amount REAL,
                        ma66 REAL,
                        boll_upper REAL,
                        boll_mid REAL,
                        boll_lower REAL,
                        macd_diff REAL,
                        macd_dea REAL,
                        macd_bar REAL,
                        global_index INTEGER,
                        end_global_index INTEGER NOT NULL
                    )
                    """)
                    try db.execute(sql: "CREATE INDEX idx_period_endidx ON klines(period, end_global_index)")
                    try db.execute(sql: "CREATE INDEX idx_period_datetime ON klines(period, datetime)")

                    for (period, rows) in options.candles {
                        for row in rows {
                            try db.execute(sql: """
                            INSERT INTO klines (period, datetime, open, high, low, close, volume,
                                amount, ma66, boll_upper, boll_mid, boll_lower,
                                macd_diff, macd_dea, macd_bar, global_index, end_global_index)
                            VALUES (?, ?, 1.0, 2.0, 0.5, 1.5, 100, NULL, NULL, NULL, NULL, NULL,
                                    NULL, NULL, NULL, ?, ?)
                            """, arguments: [period.rawValue, row.datetime, row.gIdx, row.endGIdx])
                        }
                    }
                }
            }
        }  // queue 出作用域，ARC 释放

        let cleanup = { try? FileManager.default.removeItem(at: perCallDir) }
        return (fileURL, cleanup)
    }
}
```

- [ ] **Step 2.2: 写 fixture 自检 test**

替换 `ios/Contracts/Tests/KlineTrainerPersistenceTests/Placeholder.swift` 全部内容为：

```swift
import XCTest
@preconcurrency import GRDB
@testable import KlineTrainerPersistence

final class TrainingSetSQLiteFixtureTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    func test_makeDefault_producesReadableSQLite() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)

        var config = Configuration()
        config.readonly = true
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        try queue.read { db in
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            XCTAssertEqual(userVersion, 1)
            let metaCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta") ?? -1
            XCTAssertEqual(metaCount, 1)
            let klineCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM klines") ?? -1
            XCTAssertEqual(klineCount, 3)  // 2 m3 + 1 daily
        }
    }

    func test_makeWithCustomVersion_appliedCorrectly() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.userVersion = 99
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? -1
            XCTAssertEqual(userVersion, 99)
        }
    }

    func test_makeSkipMetaTable_omitsTable() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipMetaTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let queue = try DatabaseQueue(path: url.path)
        try queue.read { db in
            // 用 Int 不用 Bool，避免 GRDB BoolfromSQLite-INT 转换 edge case。
            let count = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='meta'") ?? -1
            XCTAssertEqual(count, 0)
        }
    }
}
```

并把 `ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift` 内容替换为单行注释（保留文件让 target 在 Task 3 之前不报"target has no source"；Task 3.13 用 `git rm` 删除）：

```swift
// Placeholder：Task 3 用 git rm 删除此文件并落 DefaultTrainingSetDBFactory.swift。
```

- [ ] **Step 2.3: 跑 fixture 测试**

```bash
swift test --filter TrainingSetSQLiteFixtureTests
```

Expected: 3 tests PASS。

- [ ] **Step 2.4: 把 test 侧 Placeholder.swift 改名为对应 class 名（避免 file 名 / class 名分裂）**

```bash
git mv ios/Contracts/Tests/KlineTrainerPersistenceTests/Placeholder.swift \
       ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixtureTests.swift
```

- [ ] **Step 2.5: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixture.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingSetSQLiteFixtureTests.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift
git commit -m "test(P3): TrainingSetSQLiteFixture helper + self-check tests"
```

---

## Task 3: DefaultTrainingSetDBFactory 实现 + 全 throw 路径 TDD

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetDBFactory.swift`
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetDBFactoryTests.swift`
- Delete: `ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift`

**Spec 锚点：**
- `kline_trainer_modules_v1.4.md` L1822-1838（P3a protocol 体）
- `docs/governance/m01-schema-versioning-contract.md` 第 86 行（"M0.1 策略 / P3a Factory 执行 runtime 拒收"）
- `docs/governance/m04-apperror-translation-gate.md` Gate 1（边界 throws AppError）

**Round 1 修订要点（C-1 / C-4 / C-5 / M-7 / M-8 / M-10 反映）：**
- Factory.openAndVerify 把校验逻辑（version + meta）**移到 read closure 之外**——闭包内只做 IO 拿值，闭包外抛 AppError。避免 GRDB 闭包错误透传歧义。
- `row[...]` 全部 **显式 typed**（`as Int64` / `as Double` / `as String`），避免类型推导误选 Int 32-bit。
- PersistenceErrorMapping 用 **`if dbErr.resultCode == .SQLITE_X`** 比较，**不**用 `case .SQLITE_X:`（ResultCode 是 struct）。
- ioError 关联值字串脱敏（不放 dbErr.message）。
- 测试 assert 精确 reason（不接受松绑 `case AppError.persistence, AppError.trainingSet`）。
- 加 SQLITE_NOTADB（plain text file）路径测试。

- [ ] **Step 3.1: 写 versionMismatch 失败测试**

写文件 `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetDBFactoryTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultTrainingSetDBFactoryTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    // MARK: - versionMismatch

    func test_openAndVerify_userVersionMismatch_throwsVersionMismatch() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.userVersion = 2
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            guard case AppError.trainingSet(.versionMismatch(expected: 1, got: 2)) = err else {
                return XCTFail("Expected .trainingSet(.versionMismatch(1, 2)), got \(err)")
            }
        }
    }
}
```

- [ ] **Step 3.2: 跑 test 验证它 fail（编译失败也算 fail）**

```bash
swift test --filter DefaultTrainingSetDBFactoryTests/test_openAndVerify_userVersionMismatch_throwsVersionMismatch
```

Expected: 编译错误 "Cannot find 'DefaultTrainingSetDBFactory' in scope"。

- [ ] **Step 3.3: 实现 PersistenceErrorMapping helper**

写文件 `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift`：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// GRDB / Foundation IO 错误到 AppError 的边界翻译（per docs/governance/m04-apperror-translation-gate.md）。
/// 仅 KlineTrainerPersistence 模块内部使用；不暴露 GRDB 类型给 contracts 消费者。
///
/// 设计要点（per plan Design Decision §7）：
/// - ResultCode 是 struct（GRDB 6+），用 == 比较不能用 enum-style switch case
/// - ioError 关联值脱敏（不放 dbErr.message，避免泄漏路径 / 环境信息到崩溃上报）
enum PersistenceErrorMapping {
    /// 把任意 swift Error 转为 AppError。GRDB DatabaseError 按 result code 细分；其它走 .ioError。
    static func translate(_ error: Error, fileURL: URL? = nil) -> AppError {
        if let app = error as? AppError {
            return app  // 已是 AppError 直通（防双重翻译）
        }
        if let dbErr = error as? DatabaseError {
            // ResultCode 是 struct，用 == 比较
            if dbErr.resultCode == .SQLITE_CANTOPEN {
                if let url = fileURL,
                   !FileManager.default.fileExists(atPath: url.path) {
                    return .trainingSet(.fileNotFound)
                }
                return .persistence(.ioError("sqlite_cantopen"))
            }
            if dbErr.resultCode == .SQLITE_NOTADB || dbErr.resultCode == .SQLITE_CORRUPT {
                return .persistence(.dbCorrupted)
            }
            // 兜底：脱敏 token，不放 dbErr.message（含路径 / 环境信息）
            return .persistence(.ioError("sqlite_error_\(dbErr.resultCode.rawValue)"))
        }
        let nsErr = error as NSError
        if nsErr.domain == NSCocoaErrorDomain &&
           (nsErr.code == NSFileNoSuchFileError || nsErr.code == NSFileReadNoSuchFileError) {
            return .trainingSet(.fileNotFound)
        }
        return .persistence(.ioError("io_error"))
    }
}
```

- [ ] **Step 3.4: 实现 DefaultTrainingSetDBFactory**

删除文件 `ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift`（Task 3.13 用 `git rm`）。

写文件 `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetDBFactory.swift`：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P3a Factory 默认实现。每次 openAndVerify 创建独立 read-only DatabaseQueue。
/// 校验顺序（fail-fast）：
/// 1. 文件存在性（GRDB SQLITE_CANTOPEN 翻译）
/// 2. PRAGMA user_version 与 expectedSchemaVersion 一致
/// 3. meta 表至少 1 行（取首行）
/// 通过则返回 DefaultTrainingSetReader，已加载并 cache meta。
///
/// 设计：read closure 内只做 IO 取值（不抛 domain error）；校验逻辑全部在闭包外。
public struct DefaultTrainingSetDBFactory: TrainingSetDBFactory {
    public init() {}

    public func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader {
        do {
            var config = Configuration()
            config.readonly = true
            let queue = try DatabaseQueue(path: file.path, configuration: config)

            // 闭包内只取值，不抛 AppError，避免 GRDB transaction 行为对自定义 error 的处理歧义。
            let (userVersion, meta) = try queue.read { db -> (Int, TrainingSetMeta?) in
                guard let v = try Int.fetchOne(db, sql: "PRAGMA user_version") else {
                    // PRAGMA 永远返回 1 行；nil 表示 db 严重异常。Throw GRDB-level 错误，由外层 catch 翻译。
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "pragma user_version returned nil")
                }
                let row = try Row.fetchOne(db, sql: """
                    SELECT stock_code, stock_name, start_datetime, end_datetime
                    FROM meta LIMIT 1
                    """)
                guard let row else { return (v, nil) }
                let m = TrainingSetMeta(
                    stockCode: row["stock_code"] as String,
                    stockName: row["stock_name"] as String,
                    startDatetime: row["start_datetime"] as Int64,
                    endDatetime: row["end_datetime"] as Int64
                )
                return (v, m)
            }

            // 闭包外做 domain 校验，明确语义
            if userVersion != expectedSchemaVersion {
                throw AppError.trainingSet(.versionMismatch(expected: expectedSchemaVersion, got: userVersion))
            }
            guard let cachedMeta = meta else {
                throw AppError.trainingSet(.emptyData)
            }
            return DefaultTrainingSetReader(queue: queue, cachedMeta: cachedMeta)
        } catch {
            throw PersistenceErrorMapping.translate(error, fileURL: file)
        }
    }
}
```

写文件 `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift`（占位空壳，使 factory 编译；完整实现在 Task 4）：

```swift
import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// P3b Reader 默认实现。
/// - 持有 var queue: DatabaseQueue?；close 设 nil 触发 ARC 释放（per spec L1848 "释放 DatabaseQueue"）
/// - cached meta 在 init 时已加载，loadMeta O(1)
/// - close 后 read 抛 AppError.internalError（caller 误用，不是 IO 故障）
public final class DefaultTrainingSetReader: TrainingSetReader, @unchecked Sendable {
    private var queue: DatabaseQueue?
    private let cachedMeta: TrainingSetMeta
    private var isClosed: Bool = false
    private let lock = NSLock()

    init(queue: DatabaseQueue, cachedMeta: TrainingSetMeta) {
        self.queue = queue
        self.cachedMeta = cachedMeta
    }

    public func loadMeta() throws -> TrainingSetMeta {
        try ensureOpen()
        return cachedMeta
    }

    public func loadAllCandles() throws -> [Period: [KLineCandle]] {
        // Task 4 实现
        _ = try ensureOpen()
        return [:]
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        queue = nil  // ARC 释放 GRDB DatabaseQueue
        isClosed = true
    }

    private func ensureOpen() throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        guard let q = queue, !isClosed else {
            throw AppError.internalError(module: "P3b", detail: "reader closed")
        }
        return q
    }
}
```

- [ ] **Step 3.5: 跑 versionMismatch 测试验证 PASS**

```bash
swift test --filter DefaultTrainingSetDBFactoryTests/test_openAndVerify_userVersionMismatch_throwsVersionMismatch
```

Expected: 1 test PASS。

- [ ] **Step 3.6: 加 fileNotFound 测试**

在 `DefaultTrainingSetDBFactoryTests.swift` 的 class body 末尾追加：

```swift
    // MARK: - fileNotFound

    func test_openAndVerify_missingFile_throwsFileNotFound() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).sqlite")

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: nonexistent, expectedSchemaVersion: 1)) { err in
            guard case AppError.trainingSet(.fileNotFound) = err else {
                return XCTFail("Expected .trainingSet(.fileNotFound), got \(err)")
            }
        }
    }
```

- [ ] **Step 3.7: 跑 fileNotFound 测试**

```bash
swift test --filter DefaultTrainingSetDBFactoryTests/test_openAndVerify_missingFile_throwsFileNotFound
```

Expected: PASS（PersistenceErrorMapping.translate 已处理 SQLITE_CANTOPEN + 不存在路径）。

- [ ] **Step 3.8: 加 emptyData 测试**

追加：

```swift
    // MARK: - emptyData

    func test_openAndVerify_emptyMetaTable_throwsEmptyData() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.meta = nil  // meta 表存在但 0 行
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            guard case AppError.trainingSet(.emptyData) = err else {
                return XCTFail("Expected .trainingSet(.emptyData), got \(err)")
            }
        }
    }
```

- [ ] **Step 3.9: 跑 emptyData 测试**

```bash
swift test --filter DefaultTrainingSetDBFactoryTests/test_openAndVerify_emptyMetaTable_throwsEmptyData
```

Expected: PASS。

- [ ] **Step 3.10: 加 happy path 测试**

追加：

```swift
    // MARK: - happy path

    func test_openAndVerify_validFile_returnsReaderWithMeta() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let factory = DefaultTrainingSetDBFactory()

        let reader = try factory.openAndVerify(file: url, expectedSchemaVersion: 1)
        let meta = try reader.loadMeta()

        XCTAssertEqual(meta.stockCode, "600001")
        XCTAssertEqual(meta.stockName, "测试股票")
        XCTAssertEqual(meta.startDatetime, 1_700_000_000)
        XCTAssertEqual(meta.endDatetime, 1_700_086_400)

        reader.close()
    }
```

- [ ] **Step 3.11: 加 missing meta table 测试（dbCorrupted 或 ioError 精确）**

追加：

```swift
    // MARK: - corrupt

    func test_openAndVerify_missingMetaTable_throwsIoError() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.skipMetaTable = true
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            // SQLite "no such table: meta" → DatabaseError.SQLITE_ERROR → .persistence(.ioError("sqlite_error_<code>"))
            // 精确 assert（不松绑 case AppError.persistence | .trainingSet）
            guard case AppError.persistence(.ioError(let token)) = err else {
                return XCTFail("Expected .persistence(.ioError), got \(err)")
            }
            XCTAssertTrue(token.hasPrefix("sqlite_error_"),
                          "Expected sanitized token sqlite_error_<code>, got \(token)")
        }
    }
```

- [ ] **Step 3.12: 加 SQLITE_NOTADB 测试（plain text file 当 sqlite 喂）**

追加：

```swift
    func test_openAndVerify_notSqliteFile_throwsDbCorrupted() throws {
        let perCallDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kline_trainer_persistence_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: perCallDir, withIntermediateDirectories: true)
        let url = perCallDir.appendingPathComponent("not_sqlite.sqlite")
        try "this is not sqlite".data(using: .utf8)!.write(to: url)
        cleanups.append { try? FileManager.default.removeItem(at: perCallDir) }

        let factory = DefaultTrainingSetDBFactory()

        XCTAssertThrowsError(try factory.openAndVerify(file: url, expectedSchemaVersion: 1)) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
    }
```

- [ ] **Step 3.13: 跑全部 factory tests + commit**

```bash
swift test --filter DefaultTrainingSetDBFactoryTests
```

Expected: 6 tests PASS（versionMismatch / fileNotFound / emptyData / happy / missingMetaTable / notSqliteFile）。

```bash
git rm ios/Contracts/Sources/KlineTrainerPersistence/Placeholder.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetDBFactory.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/PersistenceErrorMapping.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetDBFactoryTests.swift
git commit -m "feat(P3a): DefaultTrainingSetDBFactory + 6 throw-path tests"
```

---

## Task 4: DefaultTrainingSetReader.loadAllCandles + close TDD

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift`（替换 loadAllCandles stub）
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift`

**Spec 锚点：**
- `kline_trainer_modules_v1.4.md` L1840-1855（P3b protocol 体）
- `kline_trainer_plan_v1.5.md` §3.2（klines 表完整 schema）

**Round 1 修订要点：**
- KLineCandle init 全部 `row[...]` **显式 typed**
- close-then-read 抛 `AppError.internalError(module: "P3b", detail: "reader closed")`，不再用 `.ioError`
- close 真释放 queue（var queue + nil）—— 已在 Task 3.4 reader 占位实现
- Task 4.5 注入坏 row 用 `do { ... }` 块作用域释放 write queue

- [ ] **Step 4.1: 写 loadAllCandles happy path 测试**

写文件 `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift`：

```swift
import XCTest
@preconcurrency import GRDB
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultTrainingSetReaderTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    // MARK: - loadAllCandles

    func test_loadAllCandles_groupsByPeriod() throws {
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 1, 1), (1_360, 2, 2)]),
            (.daily, [(1_000, nil, 2)]),
        ]
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        let candles = try reader.loadAllCandles()

        XCTAssertEqual(candles.keys.count, 2)
        XCTAssertEqual(candles[.m3]?.count, 3)
        XCTAssertEqual(candles[.daily]?.count, 1)
        XCTAssertEqual(candles[.m3]?[0].datetime, 1_000)
        XCTAssertEqual(candles[.m3]?[0].globalIndex, 0)
        XCTAssertEqual(candles[.m3]?[0].endGlobalIndex, 0)
        XCTAssertEqual(candles[.daily]?[0].globalIndex, nil)
        XCTAssertEqual(candles[.daily]?[0].endGlobalIndex, 2)

        reader.close()
    }
}
```

- [ ] **Step 4.2: 跑 test 验证 fail**

```bash
swift test --filter DefaultTrainingSetReaderTests/test_loadAllCandles_groupsByPeriod
```

Expected: FAIL — 当前 stub 返回空字典；assert keys.count == 2 失败。

- [ ] **Step 4.3: 实现 loadAllCandles（显式 typed row 取值）**

替换 `DefaultTrainingSetReader.swift` 中的 `loadAllCandles` 方法体：

```swift
    public func loadAllCandles() throws -> [Period: [KLineCandle]] {
        let q = try ensureOpen()
        do {
            let rows = try q.read { db in
                try Row.fetchAll(db, sql: """
                SELECT period, datetime, open, high, low, close, volume,
                       amount, ma66, boll_upper, boll_mid, boll_lower,
                       macd_diff, macd_dea, macd_bar, global_index, end_global_index
                FROM klines
                ORDER BY period, end_global_index
                """)
            }
            var result: [Period: [KLineCandle]] = [:]
            for row in rows {
                let rawPeriod: String = row["period"]
                guard let period = Period(rawValue: rawPeriod) else {
                    throw AppError.persistence(.dbCorrupted)
                }
                let candle = KLineCandle(
                    period: period,
                    datetime: row["datetime"] as Int64,
                    open: row["open"] as Double,
                    high: row["high"] as Double,
                    low: row["low"] as Double,
                    close: row["close"] as Double,
                    volume: row["volume"] as Int64,
                    amount: row["amount"] as Double?,
                    ma66: row["ma66"] as Double?,
                    bollUpper: row["boll_upper"] as Double?,
                    bollMid: row["boll_mid"] as Double?,
                    bollLower: row["boll_lower"] as Double?,
                    macdDiff: row["macd_diff"] as Double?,
                    macdDea: row["macd_dea"] as Double?,
                    macdBar: row["macd_bar"] as Double?,
                    globalIndex: row["global_index"] as Int?,
                    endGlobalIndex: row["end_global_index"] as Int
                )
                result[period, default: []].append(candle)
            }
            return result
        } catch {
            throw PersistenceErrorMapping.translate(error)
        }
    }
```

- [ ] **Step 4.4: 跑 test 验证 PASS**

```bash
swift test --filter DefaultTrainingSetReaderTests/test_loadAllCandles_groupsByPeriod
```

Expected: PASS。

- [ ] **Step 4.5: 加 unknown period rawValue 测试（do-block 释放 write queue）**

在 `DefaultTrainingSetReaderTests.swift` 末尾追加：

```swift
    func test_loadAllCandles_unknownPeriodRawValue_throwsDbCorrupted() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)

        // 注入坏 row：用 do-block 强制 ARC 释放 write queue，再 factory open
        do {
            let writeQueue = try GRDB.DatabaseQueue(path: url.path)
            try writeQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO klines (period, datetime, open, high, low, close, volume, end_global_index)
                    VALUES ('not_a_period', 999, 1.0, 2.0, 0.5, 1.5, 100, 99)
                    """)
            }
        }  // writeQueue 出作用域，ARC 释放

        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.persistence(.dbCorrupted) = err else {
                return XCTFail("Expected .persistence(.dbCorrupted), got \(err)")
            }
        }
        reader.close()
    }
```

- [ ] **Step 4.6: 跑 unknown period 测试**

```bash
swift test --filter DefaultTrainingSetReaderTests/test_loadAllCandles_unknownPeriodRawValue_throwsDbCorrupted
```

Expected: PASS。

- [ ] **Step 4.7: 加 close + 再调用 throws 测试（internalError 而非 ioError）**

追加：

```swift
    func test_close_thenLoadMeta_throwsInternalError() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        reader.close()

        XCTAssertThrowsError(try reader.loadMeta()) { err in
            guard case AppError.internalError(let module, let detail) = err else {
                return XCTFail("Expected .internalError, got \(err)")
            }
            XCTAssertEqual(module, "P3b")
            XCTAssertEqual(detail, "reader closed")
        }
    }

    func test_close_isIdempotent() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        reader.close()
        reader.close()  // 再次 close 不抛
        XCTAssertTrue(true, "close() called twice without crash")
    }

    func test_close_thenLoadAllCandles_throwsInternalError() throws {
        let (url, cleanup) = try TrainingSetSQLiteFixture.make()
        cleanups.append(cleanup)
        let reader = try DefaultTrainingSetDBFactory().openAndVerify(file: url, expectedSchemaVersion: 1)
        reader.close()

        XCTAssertThrowsError(try reader.loadAllCandles()) { err in
            guard case AppError.internalError(let module, _) = err else {
                return XCTFail("Expected .internalError, got \(err)")
            }
            XCTAssertEqual(module, "P3b")
        }
    }
```

- [ ] **Step 4.8: 跑全部 reader tests**

```bash
swift test --filter DefaultTrainingSetReaderTests
```

Expected: 5 tests PASS。

- [ ] **Step 4.9: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultTrainingSetReaderTests.swift
git commit -m "feat(P3b): DefaultTrainingSetReader.loadAllCandles + close + 5 tests"
```

---

## Task 5: 端到端 Happy Path 集成测试

**Files:**
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/HappyPathIntegrationTests.swift`

**为什么单独有这步：** Task 3-4 都是单测（每方法一个 expectation）；本 task 模拟 E6 调用方真实链路（factory.openAndVerify → loadMeta → loadAllCandles → close），保证 6 个 Period（m3/m15/m60/daily/weekly/monthly）全程不丢数据，按 endGlobalIndex 排序正确。

- [ ] **Step 5.1: 写完整链路 test**

写文件 `ios/Contracts/Tests/KlineTrainerPersistenceTests/HappyPathIntegrationTests.swift`：

```swift
import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class HappyPathIntegrationTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    func test_fullPath_factoryOpenLoadMetaLoadCandlesClose() throws {
        // arrange: 6 个 Period 全覆盖（spec §M0.3 Period.allCases；含 m3/m15/m60/daily/weekly/monthly）
        var opts = TrainingSetSQLiteFixture.ConfigOptions()
        opts.candles = [
            (.m3, [(1_000, 0, 0), (1_180, 1, 1), (1_360, 2, 2)]),
            (.m15, [(1_000, nil, 2)]),
            (.m60, [(1_000, nil, 2)]),
            (.daily, [(1_000, nil, 2)]),
            (.weekly, [(1_000, nil, 2)]),
            (.monthly, [(1_000, nil, 2)]),
        ]
        opts.meta = TrainingSetMeta(
            stockCode: "688001",
            stockName: "全周期股",
            startDatetime: 1_000,
            endDatetime: 1_360
        )
        let (url, cleanup) = try TrainingSetSQLiteFixture.make(opts)
        cleanups.append(cleanup)

        // act
        let factory = DefaultTrainingSetDBFactory()
        let reader = try factory.openAndVerify(file: url, expectedSchemaVersion: 1)
        let meta = try reader.loadMeta()
        let candles = try reader.loadAllCandles()
        reader.close()

        // assert: meta
        XCTAssertEqual(meta.stockCode, "688001")
        XCTAssertEqual(meta.stockName, "全周期股")

        // assert: 6 个 Period 全有数据
        XCTAssertEqual(Set(candles.keys), Set(Period.allCases))
        XCTAssertEqual(candles[.m3]?.count, 3)
        XCTAssertEqual(candles[.m15]?.count, 1)
        XCTAssertEqual(candles[.m60]?.count, 1)
        XCTAssertEqual(candles[.daily]?.count, 1)
        XCTAssertEqual(candles[.weekly]?.count, 1)
        XCTAssertEqual(candles[.monthly]?.count, 1)

        // assert: m3 按 endGlobalIndex 单调递增（ORDER BY 验证）
        let m3 = candles[.m3]!
        XCTAssertEqual(m3.map(\.endGlobalIndex), [0, 1, 2])
    }
}
```

- [ ] **Step 5.2: 跑 integration test**

```bash
swift test --filter HappyPathIntegrationTests
```

Expected: 1 test PASS。

- [ ] **Step 5.3: 跑全 KlineTrainerPersistence test target 确认无回归**

```bash
swift test --filter KlineTrainerPersistenceTests
```

Expected: **15 tests PASS**（fixture 自检 3 + factory 6 + reader 5 + integration 1 = 15）。

- [ ] **Step 5.4: 跑全仓 test 确认无影响其它 target**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts" && swift test
```

Expected: 全部 PASS（含原 KlineTrainerContractsTests 全部历史 tests + 新 KlineTrainerPersistenceTests 15 项）。

**Fallback（如果历史 KlineTrainerContractsTests 有 fail）：** 从 fail 的错误信息 grep `KlineTrainerPersistence`：
- 若**不命中** → fail 与本 PR 改动无关（PR #40 已稳定 merged 历史，可能是环境抖动），可重跑一次确认；如重跑仍 fail 但 KlineTrainerPersistenceTests 全 pass，可在 PR body 中独立 ack 该历史不稳定项不阻塞本 PR
- 若**命中** → 本 PR 引入了跨 target 影响，回 Task 4 review concurrency / Sendable 假设

- [ ] **Step 5.5: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerPersistenceTests/HappyPathIntegrationTests.swift
git commit -m "test(P3): end-to-end happy path integration test"
```

---

## Task 6: 验收清单 + PR body

**为什么有这步：** CLAUDE.md backstop §2 要求每模块/阶段交付含**非 coder 可执行的中文验收清单**（action / expected / pass-fail；禁用语见 `.claude/workflow-rules.json`）。

**Files:**
- Create: `docs/acceptance/2026-05-02-pr3a-trainingset-db.md`

- [ ] **Step 6.1: 写中文验收清单**

写文件 `docs/acceptance/2026-05-02-pr3a-trainingset-db.md`：

```markdown
# PR 3a 验收清单（P3a Factory + P3b Reader 真实现）

> 用户在 macOS Terminal cd 到 `/Users/maziming/Coding/Prj_Kline trainer/ios/Contracts` 后逐条执行。

## 动作 / 预期输出 / 是否通过

| # | 动作 | 预期输出 | 通过判定 |
|---|---|---|---|
| 1 | 执行 `swift build` | 终端最末行出现 `Build complete!`；无 error / warning | 末行字串包含 `Build complete!` 即通过 |
| 2 | 执行 `swift test --filter TrainingSetSQLiteFixtureTests` | 末行 `Test Suite 'Selected tests' passed`；3 tests 全 pass | 末行无 `failed` 字串 |
| 3 | 执行 `swift test --filter DefaultTrainingSetDBFactoryTests` | 6 tests 全 pass | 末行无 `failed` 字串 |
| 4 | 执行 `swift test --filter DefaultTrainingSetReaderTests` | 5 tests 全 pass | 末行无 `failed` 字串 |
| 5 | 执行 `swift test --filter HappyPathIntegrationTests` | 1 test pass | 末行无 `failed` 字串 |
| 6 | 执行 `swift test` 跑全仓 | 全部 tests pass（含 KlineTrainerContractsTests 历史项 + 15 个新 Persistence tests） | 末行 `Test Suite 'All tests' passed` |
| 7 | 执行 `grep -rn "import GRDB" Sources/KlineTrainerContracts/` | **无任何输出** | 输出为空（契约层无 GRDB import；注释里出现 "GRDB" 字串属正常说明性引用，不算污染） |
| 8 | 执行 `find Sources/KlineTrainerPersistence -name '*.swift' -exec grep -l 'import GRDB' {} \; \| wc -l` | 数字 ≥ 3 | 输出数字 ≥ 3（Factory + Reader + ErrorMapping 三文件含 GRDB import） |
| 9 | 执行 `grep -nE "^[[:space:]]*throw[[:space:]]" Sources/KlineTrainerPersistence/DefaultTrainingSetDBFactory.swift` | 出现 4 行：1 处 `throw DatabaseError(...)`（PRAGMA 异常通道）+ 2 处 `throw AppError.trainingSet(...)`（versionMismatch + emptyData）+ 1 处 `throw PersistenceErrorMapping.translate(...)`（外层 catch 重抛，translate 返回 AppError），**无** `throw nsErr` / `throw error` 等裸 raw 抛 | grep 输出 4 行，每行 throw 对象前缀只能是 `AppError.` / `DatabaseError(` / `PersistenceErrorMapping.translate(` 三者之一 |

## 失败兜底

- 若第 1 步 `swift build` 因 GRDB 拉包失败：检查网络；GRDB 7.x 包大小 ~3MB 需要短暂等待
- 若第 1 步 `swift build` 报 `'readonly' has been renamed to 'readOnly'`：按编译器提示替换 `config.readonly` → `config.readOnly`
- 若第 1 步报 Sendable warning 数量 > 0：把 `import GRDB` 改为 `@preconcurrency import GRDB`
- 若第 7 步 `grep -rn "import GRDB"` 返回非空：违反 Design Decision §1，立即停止合并
```

- [ ] **Step 6.2: Commit 验收清单**

```bash
git add docs/acceptance/2026-05-02-pr3a-trainingset-db.md
git commit -m "docs(P3): PR 3a acceptance checklist (chinese, action/expected/pass-fail)"
```

- [ ] **Step 6.3: push + 开 PR（中文 body，per memory `feedback_pr_language_chinese.md`）**

```bash
git push -u origin pr3a-trainingset-db
gh pr create --title "feat(P3): P3a Factory + P3b Reader 真实现 + GRDB 集成" --body "$(cat <<'EOF'
## 范围

落地 P3a `DefaultTrainingSetDBFactory` 与 P3b `DefaultTrainingSetReader` 的 GRDB production 实现：

- 新建 SwiftPM target `KlineTrainerPersistence`（依赖 `KlineTrainerContracts` + `GRDB.swift` 7.x）—— GRDB 不进契约层
- `DefaultTrainingSetDBFactory.openAndVerify`：read-only 打开 → `PRAGMA user_version` 校验 → meta 单行非空校验 → 返回 reader（已 cache meta）；校验逻辑全部在 read closure **外**抛错
- `DefaultTrainingSetReader.loadAllCandles`：单 SELECT 全表，按 `Period` 分组，按 `end_global_index` 排序；row 取值显式 typed
- `close` 设 queue=nil 触发 ARC 释放（spec L1848 字面落地）；幂等；close 后 read 抛 `AppError.internalError(module: "P3b", detail: "reader closed")`
- GRDB error 边界翻译（PersistenceErrorMapping）：SQLITE_CANTOPEN+不存在文件 → `.trainingSet(.fileNotFound)`；SQLITE_NOTADB/CORRUPT → `.persistence(.dbCorrupted)`；其它 → `.persistence(.ioError("sqlite_error_<code>"))`（脱敏 token，不暴露 dbErr.message）

## Spec 锚点

- `kline_trainer_modules_v1.4.md` §P3a L1822-1838 / §P3b L1840-1855
- `docs/governance/m01-schema-versioning-contract.md`（P3a 是 schema_version runtime 拒收 owner；schemaMismatch≠versionMismatch 区分见 plan Design Decision §8）
- `docs/governance/m04-apperror-translation-gate.md`（边界翻译 Gate 1）

## 测试

- 15 tests 全 pass（fixture 3 + factory 6 + reader 5 + integration 1）
- 覆盖：versionMismatch / fileNotFound / emptyData / missingMetaTable / SQLITE_NOTADB / happy / unknown Period rawValue / close idempotency / close-then-loadMeta / close-then-loadAllCandles
- 测试 fixture 用 per-call UUID 子目录避免并行 race

## 验收清单

`docs/acceptance/2026-05-02-pr3a-trainingset-db.md`（9 条非 coder 可执行 action / expected / pass-fail）

## Round 1 对抗性 review

opus 4.7 xhigh 替代 codex 做 round 1 review，28 findings（5 CRITICAL + 13 实质 MAJOR + 9 MINOR）已应用修订；详见 plan doc `Round 2 修订标记` 段。

## 不在本 PR 范围

- P4 三 Repo 实现（PR 3b）
- AcceptanceJournalDAO + typealias AppDB（PR 3c）
- E6 ↔ P3a/P3b 联调（推迟到 P4 / E6 真实现 PR）

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review Checklist（writing-plans skill 要求 + Round 1 修订记录）

**1. Spec coverage:**
- ✅ P3a `openAndVerify` 签名 + 5 类 throws 路径全覆盖（versionMismatch / fileNotFound / emptyData / missingMetaTable→ioError / SQLITE_NOTADB→dbCorrupted）
- ✅ P3b `loadMeta` / `loadAllCandles` / `close` 三方法全覆盖；close 真释放 queue（var queue + nil）
- ✅ M0.1 governance "P3a runtime 拒收 versionMismatch" 行为落地（Task 3.1）；schemaMismatch≠versionMismatch 区分（Design Decision §8）
- ✅ M0.4 边界翻译 Gate 1（PersistenceErrorMapping helper，Task 3.3）；ioError detail 脱敏（不放 dbErr.message）
- ✅ Sendable 标记（Reader 用 `@unchecked Sendable` + NSLock 保护 isClosed/queue；Factory 是值类型自动 Sendable）
- ✅ Read-only DatabaseQueue（Design Decision §2）
- ✅ Swift 6 + GRDB 7 `@preconcurrency import GRDB` fallback（Design Decision §10）

**2. Placeholder scan:** 无 "TBD/TODO/implement later"；所有 step 含完整代码。

**3. Type consistency:**
- `DefaultTrainingSetDBFactory.openAndVerify` 返回 `TrainingSetReader`（contracts protocol，匹配 spec L1832）
- `DefaultTrainingSetReader` 实现 `TrainingSetReader` protocol（含 loadMeta / loadAllCandles / close 三方法签名一致）
- `PersistenceErrorMapping.translate` 输入 `Error`，输出 `AppError`，跨 Task 3-4 调用签名一致
- `TrainingSetSQLiteFixture.ConfigOptions.userVersion` 类型 `Int`（Round 1 N-7 修订：原 Int32 → Int），与 `expectedSchemaVersion: Int` 一致
- KLineCandle init 全部 `row[...]` 显式 typed（C-1 修订）；TrainingSetMeta 同
- ResultCode 用 `==` 比较不用 enum-style switch case（M-8 修订）

**4. Round 1 → Round 2 修订汇总（应用项）：**

CRITICAL（5 全应用）：
- C-1：row[...] 显式 typed（Factory + Reader 全部）
- C-2：Step 1.0 git checkout -b
- C-3：Period 注释错误改正（删 replay 错引用，5→6 一致）
- C-4：Factory 校验闭包外抛（避免 GRDB 闭包错误透传歧义）
- C-5：fixture write queue 用 do-block scope 释放

MAJOR / 实质 CRITICAL（13 应用）：
- M-1：Design Decision §8 加 schemaMismatch vs versionMismatch 区分
- M-2：close-then-read 改 .internalError（不再 .ioError 误导 UI）
- M-3：Design Decision §9 加 GRDB 7 API 锚点 + Step 1.3 fallback
- M-4：fixture per-call UUID 子目录（不再共享单一 tmp dir）
- M-5：PRAGMA nil → 抛 DatabaseError（外层翻译 dbCorrupted），不再 ?? -1 fallback
- M-6：fixture self-check 用 Int.fetchOne 不用 Bool.fetchOne
- M-7：PersistenceErrorMapping ioError detail 脱敏（用 `sqlite_error_<code>` token，不放 dbErr.message）
- M-8：ResultCode 用 == 比较（struct 不能 enum-style switch）
- M-9：加 SQLITE_NOTADB（plain text file）测试
- M-10：missing meta table 测试 assert 精确化（assert .ioError 而非松绑 case）
- M-11：Design Decision §10 加 @preconcurrency import GRDB
- M-12：验收清单 #8 用 find 数文件不数 grep 行
- N-8（实质 MAJOR）：close 真释放 queue（var queue: DatabaseQueue? + nil）

MINOR（9 应用）：
- N-1：File Structure 加子项计数（2 个核心子项）
- N-3：testTarget 显式声明 GRDB
- N-4：Step 5.3 改 15 tests（不再 13 vs 14 不一致）
- N-5：PR body 测试数联动改 15
- N-6：grep "throw " 加空格（不误中 throws）+ 改 -nE 正则
- N-7：fixture userVersion 改 Int
- N-11：Placeholder 描述统一（Step 1.2 + Step 2.2 + Step 3.4 + Step 3.13 一致）

**5. Round 1 → Round 2 不应用（PASS / 已 OK）：**
- N-2：File Structure 路径一致性（review PASS）
- N-9：plan 整体长度（保留完整性 > 简洁，inline 代码不抽出）
- N-10：forbidden_phrases（review PASS，验收清单合规）

**6. 已知 residual（plan 内 explicit）：**
- meta 多行不抛 dbCorrupted，按 Postel 取首行（Design Decision §3）
- klines 表为空不阻塞 openAndVerify（Design Decision §4）
- close 后 reader 实例本身仍存活直到 caller 放掉引用（queue 已通过 nil 触发 ARC 释放，但 reader 是 final class 由 caller 持有）—— 与 spec L1848 "释放 DatabaseQueue" 字面一致
