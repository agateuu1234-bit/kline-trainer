import XCTest
import KlineTrainerContracts
@testable import KlineTrainerPersistence

final class DefaultSettingsDAOTests: XCTestCase {

    private var dbURL: URL!
    private var db: DefaultAppDB!

    override func setUp() async throws {
        dbURL = try AppDBFixture.makeFreshDB()
        db = try DefaultAppDB(dbPath: dbURL)
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())
    }

    // 用例 1：fresh DB loadSettings 返回默认（资金默认=初始 10 万 #6；其它字段 zero-value）
    func test_loadSettings_on_fresh_db_returns_defaults() throws {
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0)
        XCTAssertEqual(s.minCommissionEnabled, false)
        XCTAssertEqual(s.totalCapital, 100_000)   // #6：缺键默认 10 万（非 0），开局可交易
        XCTAssertEqual(s.displayMode, .system)
    }

    // 用例 2：saveSettings → loadSettings roundtrip
    func test_saveSettings_then_load_roundtrip() throws {
        let s = AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                            totalCapital: 50_000, displayMode: .dark)
        try db.saveSettings(s)
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.minCommissionEnabled, true)
        XCTAssertEqual(loaded.totalCapital, 50_000)
        XCTAssertEqual(loaded.displayMode, .dark)
    }

    // 用例 3：saveSettings 二次覆盖
    func test_saveSettings_overwrites_existing() throws {
        try db.saveSettings(AppSettings(commissionRate: 0.0001, minCommissionEnabled: false,
                                        totalCapital: 10_000, displayMode: .light))
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 30_000, displayMode: .dark))
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.totalCapital, 30_000)
        XCTAssertEqual(loaded.displayMode, .dark)

        // 物理验证：表恰好 4 行（4 个 key）
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let count: Int = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM settings") ?? -1
        }
        XCTAssertEqual(count, 4)
    }

    // 用例 4：resetCapital 把 total_capital 写回默认 10 万，其它字段保留
    func test_resetCapital_sets_default_capital_other_fields_intact() throws {
        try db.saveSettings(AppSettings(commissionRate: 0.0003, minCommissionEnabled: true,
                                        totalCapital: 50_000, displayMode: .dark))
        try db.resetCapital()
        let loaded = try db.loadSettings()
        XCTAssertEqual(loaded.totalCapital, 100_000)   // 去地雷：写默认 10 万（非 0）
        XCTAssertEqual(loaded.commissionRate, 0.0003, accuracy: 1e-9)
        XCTAssertEqual(loaded.minCommissionEnabled, true)
        XCTAssertEqual(loaded.displayMode, .dark)
    }

    // 用例 5：resetCapital fresh DB 创建 total_capital=默认 10 万 行
    func test_resetCapital_on_fresh_db_creates_default_capital_row() throws {
        try db.resetCapital()
        let queue = try AppDBFixture.openRaw(at: dbURL)
        let val: String? = try queue.read { db in
            try String.fetchOne(db, sql:
                "SELECT value FROM settings WHERE key = 'total_capital'")
        }
        XCTAssertEqual(val, "100000.0")
    }

    // 用例 6：DisplayMode 三个 case 均可 roundtrip
    func test_displayMode_all_three_cases_roundtrip() throws {
        for mode: DisplayMode in [.light, .dark, .system] {
            try db.saveSettings(AppSettings(commissionRate: 0, minCommissionEnabled: false,
                                            totalCapital: 0, displayMode: mode))
            XCTAssertEqual(try db.loadSettings().displayMode, mode)
        }
    }

    // 用例 7（R1 新增 codex high-2）：commission_rate 列含 garbage → .dbCorrupted（不静默回 0）
    func test_loadSettings_malformed_commission_rate_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "garbage_not_a_number"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 8（R1 新增）：display_mode 列含未知 enum case → .dbCorrupted
    func test_loadSettings_unknown_displayMode_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["display_mode", "purple"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 9（R1 新增）：min_commission_enabled 列含非 bool 串 → .dbCorrupted
    func test_loadSettings_malformed_bool_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["min_commission_enabled", "yes"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted)，实际 \(err)")
            }
        }
    }

    // 用例 10（R1 新增）：partial keys（仅 commission_rate）→ 缺失 key 走默认（capital 缺→10 万 #6）
    func test_loadSettings_partial_keys_missing_uses_default() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "0.0005"])
        }
        let s = try db.loadSettings()
        XCTAssertEqual(s.commissionRate, 0.0005, accuracy: 1e-9)
        XCTAssertEqual(s.minCommissionEnabled, false)
        XCTAssertEqual(s.totalCapital, 100_000)   // #6
        XCTAssertEqual(s.displayMode, .system)
    }

    // 用例 11（R2 新增 codex med-3）：commission_rate 列含 "NaN" → .dbCorrupted
    func test_loadSettings_NaN_value_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["commission_rate", "NaN"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted) on NaN，实际 \(err)")
            }
        }
    }

    // 用例 12（R2 新增 codex med-3）：total_capital 列含 "Infinity" → .dbCorrupted
    func test_loadSettings_infinity_value_throws_dbCorrupted() throws {
        let queue = try AppDBFixture.openRaw(at: dbURL)
        try queue.write { db in
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: ["total_capital", "Infinity"])
        }
        XCTAssertThrowsError(try db.loadSettings()) { err in
            guard let appErr = err as? AppError,
                  case .persistence(.dbCorrupted) = appErr else {
                return XCTFail("期望 .persistence(.dbCorrupted) on Infinity，实际 \(err)")
            }
        }
    }

    // 用例 13（R2 新增 codex med-3）：saveSettings 入参 NaN commissionRate → 拒绝（internalError）
    func test_saveSettings_with_NaN_commission_throws_internalError() throws {
        let bad = AppSettings(commissionRate: .nan, minCommissionEnabled: false,
                              totalCapital: 10_000, displayMode: .system)
        XCTAssertThrowsError(try db.saveSettings(bad)) { err in
            guard let appErr = err as? AppError,
                  case .internalError(let module, _) = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
            XCTAssertTrue(module.contains("SettingsDAO"))
        }
    }

    // 用例 14（R2 新增 codex med-3）：saveSettings 入参 inf totalCapital → 拒绝
    func test_saveSettings_with_inf_capital_throws_internalError() throws {
        let bad = AppSettings(commissionRate: 0.0003, minCommissionEnabled: false,
                              totalCapital: .infinity, displayMode: .system)
        XCTAssertThrowsError(try db.saveSettings(bad)) { err in
            guard let appErr = err as? AppError,
                  case .internalError = appErr else {
                return XCTFail("期望 .internalError，实际 \(err)")
            }
        }
    }
}
