import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// PendingReplayRepository 静态方法实现。pending_replay 表 CHECK(id = 1)：永远 0 或 1 行。
/// 镜像 PendingTrainingRepositoryImpl（去 session_key，加 record_id）。
enum PendingReplayRepositoryImpl {

    static func saveReplay(_ db: Database, replay p: PendingReplay) throws {
        let positionB64 = p.positionData.base64EncodedString()
        let feeJSON = try RecordRepositoryImpl.jsonEncode(p.feeSnapshot)
        let opsJSON = try RecordRepositoryImpl.jsonEncode(p.tradeOperations)
        let drawingsJSON = try RecordRepositoryImpl.jsonEncode(p.drawings)
        let drawdownJSON = try RecordRepositoryImpl.jsonEncode(p.drawdown)

        try db.execute(sql: """
            INSERT OR REPLACE INTO pending_replay
              (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                p.recordId, p.trainingSetFilename, p.globalTickIndex,
                p.upperPeriod.rawValue, p.lowerPeriod.rawValue,
                positionB64, feeJSON, opsJSON, drawingsJSON,
                p.startedAt, p.accumulatedCapital, p.cashBalance, drawdownJSON
            ])
    }

    static func loadReplay(_ db: Database) throws -> PendingReplay? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT * FROM pending_replay WHERE id = 1") else { return nil }
        let positionB64: String = row["position_data"]
        guard let positionData = Data(base64Encoded: positionB64) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let upperRaw: String = row["upper_period"]
        let lowerRaw: String = row["lower_period"]
        guard let upper = Period(rawValue: upperRaw),
              let lower = Period(rawValue: lowerRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let feeJSON: String = row["fee_snapshot"]
        let opsJSON: String = row["trade_operations"]
        let drawingsJSON: String = row["drawings"]
        let drawdownJSON: String = row["drawdown"]
        // codex plan-R11-F1：所有 payload JSON 解码失败统一映射 .dbCorrupted——
        // 确保 resumePendingReplay 能用"是否 .dbCorrupted"确定区分"已验证损坏槽"vs"瞬态错误"。
        let fee: FeeSnapshot
        let ops: [TradeOperation]
        let drawings: [DrawingObject]
        let drawdown: DrawdownAccumulator
        do {
            fee = try RecordRepositoryImpl.jsonDecode(feeJSON, as: FeeSnapshot.self)
                .sanitizedForLegacyCorruption()  // WB-1：清除 legacy 负/非有限 commissionRate
            ops = try RecordRepositoryImpl.jsonDecode(opsJSON, as: [TradeOperation].self)
            drawings = try RecordRepositoryImpl.jsonDecode(drawingsJSON, as: [DrawingObject].self)
            drawdown = try RecordRepositoryImpl.jsonDecode(drawdownJSON, as: DrawdownAccumulator.self)
        } catch let appErr as AppError {
            throw appErr
        } catch {
            throw AppError.persistence(.dbCorrupted)
        }
        return PendingReplay(
            recordId: row["record_id"],
            trainingSetFilename: row["training_set_filename"],
            globalTickIndex: row["global_tick_index"],
            upperPeriod: upper, lowerPeriod: lower,
            positionData: positionData,
            cashBalance: row["cash_balance"],
            feeSnapshot: fee,
            tradeOperations: ops, drawings: drawings,
            startedAt: row["started_at"],
            accumulatedCapital: row["accumulated_capital"],
            drawdown: drawdown
        )
    }

    static func clearReplay(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_replay WHERE id = 1")
    }

    // codex plan-R3-F1：条件清——仅当单槽属于该记录（终局/discard，防删别的记录的槽）。原子，无读写竞态。
    static func clearReplay(_ db: Database, ifRecordId recordId: Int64) throws {
        try db.execute(sql: "DELETE FROM pending_replay WHERE id = 1 AND record_id = ?",
                       arguments: [recordId])
    }

    // codex plan-R11-F1：轻量元数据——只读 record_id/training_set_filename（简单列，不解码 payload），
    // 故损坏 payload 不会让本方法抛。resume-first 用它先判槽归属，避免一条损坏槽阻塞所有记录的 replay。
    static func loadReplaySlotInfo(_ db: Database) throws -> ReplaySlotInfo? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT record_id, training_set_filename FROM pending_replay WHERE id = 1") else { return nil }
        return ReplaySlotInfo(recordId: row["record_id"], trainingSetFilename: row["training_set_filename"])
    }
}
