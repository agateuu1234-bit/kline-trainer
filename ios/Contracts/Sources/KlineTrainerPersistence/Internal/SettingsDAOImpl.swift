import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// SettingsDAO 静态方法实现。
/// settings 表是 key-value：4 个固定 key（commission_rate / min_commission_enabled / total_capital / display_mode）。
enum SettingsDAOImpl {

    private static let keyCommissionRate = "commission_rate"
    private static let keyMinCommissionEnabled = "min_commission_enabled"
    private static let keyTotalCapital = "total_capital"
    private static let keyDisplayMode = "display_mode"

    static func loadSettings(_ db: Database) throws -> AppSettings {
        // R1 修订（codex high-2）：分 missing vs malformed 两路。
        // missing = 首次启动 → 默认（capital=10 万 #6，其它 zero-value）
        // malformed = key 存在但 value 不可解析 → AppError.persistence(.dbCorrupted)
        //             静默回退会把损坏的 commission/capital 重置 0，影响财务计算
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
        var dict: [String: String] = [:]
        for row in rows {
            dict[row["key"] as String] = (row["value"] as String)
        }

        let commissionRate = try parseDouble(dict[keyCommissionRate], default: 0)
        let minCommissionEnabled = try parseBool(dict[keyMinCommissionEnabled], default: false)
        let totalCapital = try parseDouble(dict[keyTotalCapital], default: AppSettings.defaultTotalCapital)
        let displayMode = try parseDisplayMode(dict[keyDisplayMode], default: .system)

        return AppSettings(commissionRate: commissionRate,
                           minCommissionEnabled: minCommissionEnabled,
                           totalCapital: totalCapital,
                           displayMode: displayMode)
    }

    private static func parseDouble(_ raw: String?, default def: Double) throws -> Double {
        guard let raw = raw else { return def }       // missing → default
        guard let v = Double(raw), v.isFinite else {  // present but malformed / NaN / inf → corrupt
            // R2 修订（codex med-3）：拒 NaN / +inf / -inf —— 这些值会污染 commission/capital 计算
            throw AppError.persistence(.dbCorrupted)
        }
        return v
    }

    private static func parseBool(_ raw: String?, default def: Bool) throws -> Bool {
        guard let raw = raw else { return def }
        switch raw {
        case "true": return true
        case "false": return false
        default: throw AppError.persistence(.dbCorrupted)
        }
    }

    private static func parseDisplayMode(_ raw: String?, default def: DisplayMode) throws -> DisplayMode {
        guard let raw = raw else { return def }
        guard let m = DisplayMode(rawValue: raw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return m
    }

    static func saveSettings(_ db: Database, settings s: AppSettings) throws {
        // R2 修订（codex med-3）：拒入参为 NaN / inf 的 commission/capital，避免毒入 DB
        guard s.commissionRate.isFinite else {
            throw AppError.internalError(
                module: "P4-SettingsDAO",
                detail: "saveSettings refused: commissionRate not finite (\(s.commissionRate))")
        }
        guard s.totalCapital.isFinite else {
            throw AppError.internalError(
                module: "P4-SettingsDAO",
                detail: "saveSettings refused: totalCapital not finite (\(s.totalCapital))")
        }
        let pairs: [(String, String)] = [
            (keyCommissionRate, String(s.commissionRate)),
            (keyMinCommissionEnabled, s.minCommissionEnabled ? "true" : "false"),
            (keyTotalCapital, String(s.totalCapital)),
            (keyDisplayMode, s.displayMode.rawValue),
        ]
        for (k, v) in pairs {
            try db.execute(sql:
                "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
                arguments: [k, v])
        }
    }

    /// 遗留 capital-only 重置（协议兼容；当前 UI 改用 TrainingResetPort 全量重置）。
    /// 运行时 #1：写值由 "0.0" 改为默认 10 万，避免「未用方法写错值」地雷（与 §6.4 一致）。
    static func resetCapital(_ db: Database) throws {
        try db.execute(sql:
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
            arguments: [keyTotalCapital, String(AppSettings.defaultTotalCapital)])
    }

    /// 参数化写 total_capital（供 TrainingResetPort 原子事务复用；不改其它 key）。
    static func setTotalCapital(_ db: Database, _ value: Double) throws {
        try db.execute(sql:
            "INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)",
            arguments: [keyTotalCapital, String(value)])
    }
}
