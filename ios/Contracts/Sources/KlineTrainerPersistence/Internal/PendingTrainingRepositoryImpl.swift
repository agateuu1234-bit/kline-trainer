import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// PendingTrainingRepository 静态方法实现。
/// pending_training 表 schema CHECK(id = 1)：永远 0 或 1 行。
enum PendingTrainingRepositoryImpl {

    static func savePending(_ db: Database, pending p: PendingTraining) throws {
        let positionB64 = p.positionData.base64EncodedString()
        let feeJSON = try RecordRepositoryImpl.jsonEncode(p.feeSnapshot)
        let opsJSON = try RecordRepositoryImpl.jsonEncode(p.tradeOperations)
        // 保真+保序：直接重发 p.lossy（有序 known+unknown）——**不重排、不把 unknown append 到 known 后面**
        // （codex R5-high）。load 得到的 p.lossy 已含原有序未识别条；未编辑的 load→save 逐字节+保序无损。
        let drawingsJSON = String(decoding: try p.lossy.encoded(), as: UTF8.self)
        let drawdownJSON = try RecordRepositoryImpl.jsonEncode(p.drawdown)

        try db.execute(sql: """
            INSERT OR REPLACE INTO pending_training
              (id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown, session_key)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                p.trainingSetFilename, p.globalTickIndex,
                p.upperPeriod.rawValue, p.lowerPeriod.rawValue,
                positionB64, feeJSON, opsJSON, drawingsJSON,
                p.startedAt, p.accumulatedCapital, p.cashBalance, drawdownJSON,
                p.sessionKey
            ])
    }

    static func loadPending(_ db: Database) throws -> PendingTraining? {
        guard let row = try Row.fetchOne(db, sql:
            "SELECT * FROM pending_training WHERE id = 1") else { return nil }
        let positionB64: String = row["position_data"]
        guard let positionData = Data(base64Encoded: positionB64) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let feeJSON: String = row["fee_snapshot"]
        let opsJSON: String = row["trade_operations"]
        let drawingsJSON: String = row["drawings"]
        let drawdownJSON: String = row["drawdown"]
        let upperRaw: String = row["upper_period"]
        let lowerRaw: String = row["lower_period"]
        guard let upper = Period(rawValue: upperRaw),
              let lower = Period(rawValue: lowerRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let fee: FeeSnapshot = try RecordRepositoryImpl.jsonDecode(feeJSON, as: FeeSnapshot.self)
            .sanitizedForLegacyCorruption()  // WB-1：清除 legacy 负/非有限 commissionRate
        let ops: [TradeOperation] = try RecordRepositoryImpl.jsonDecode(opsJSON,
                                                                       as: [TradeOperation].self)
        // 有损解码（P1a Task 11）：单条未知/未来 toolType 只跳过、不整组失败；整体数组结构性损坏
        // （非法 JSON/非顶层数组）仍 → .dbCorrupted（LossyDrawingArray.decode 内部保持该语义）。
        let lossy = try LossyDrawingArray.decode(Data(drawingsJSON.utf8))
        let drawdown: DrawdownAccumulator = try RecordRepositoryImpl.jsonDecode(drawdownJSON,
                                                                                as: DrawdownAccumulator.self)
        // 完整 migrator 路径下（0004 回填 + savePending 恒写）理论不可达；防御性守卫 raw-SQL/未来 fixture 漏写
        let keyOpt: String? = row["session_key"]
        guard let key = keyOpt else { throw AppError.persistence(.dbCorrupted) }
        return PendingTraining(
            trainingSetFilename: row["training_set_filename"],
            globalTickIndex: row["global_tick_index"],
            upperPeriod: upper, lowerPeriod: lower,
            positionData: positionData,
            cashBalance: row["cash_balance"],
            feeSnapshot: fee,
            tradeOperations: ops, lossy: lossy,
            startedAt: row["started_at"],
            accumulatedCapital: row["accumulated_capital"],
            drawdown: drawdown,
            sessionKey: key
        )
    }

    static func clearPending(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_training WHERE id = 1")
    }
}
