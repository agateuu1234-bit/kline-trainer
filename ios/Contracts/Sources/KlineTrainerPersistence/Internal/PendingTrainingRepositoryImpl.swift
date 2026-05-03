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
        let drawingsJSON = try RecordRepositoryImpl.jsonEncode(p.drawings)
        let drawdownJSON = try RecordRepositoryImpl.jsonEncode(p.drawdown)

        try db.execute(sql: """
            INSERT OR REPLACE INTO pending_training
              (id, training_set_filename, global_tick_index, upper_period, lower_period,
               position_data, fee_snapshot, trade_operations, drawings,
               started_at, accumulated_capital, cash_balance, drawdown)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                p.trainingSetFilename, p.globalTickIndex,
                p.upperPeriod.rawValue, p.lowerPeriod.rawValue,
                positionB64, feeJSON, opsJSON, drawingsJSON,
                p.startedAt, p.accumulatedCapital, p.cashBalance, drawdownJSON
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
        let ops: [TradeOperation] = try RecordRepositoryImpl.jsonDecode(opsJSON,
                                                                       as: [TradeOperation].self)
        let drawings: [DrawingObject] = try RecordRepositoryImpl.jsonDecode(drawingsJSON,
                                                                            as: [DrawingObject].self)
        let drawdown: DrawdownAccumulator = try RecordRepositoryImpl.jsonDecode(drawdownJSON,
                                                                                as: DrawdownAccumulator.self)
        return PendingTraining(
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

    static func clearPending(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM pending_training WHERE id = 1")
    }
}
