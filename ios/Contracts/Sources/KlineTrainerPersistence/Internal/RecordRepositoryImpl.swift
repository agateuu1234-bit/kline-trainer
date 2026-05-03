import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// RecordRepository 静态方法实现。所有方法在 DefaultAppDB.dbQueue.read/write 闭包内调用。
/// 调用方负责 dbQueue.write 包事务 + GRDB 错误翻译。
enum RecordRepositoryImpl {

    static func insertRecord(_ db: Database, record: TrainingRecord,
                             ops: [TradeOperation],
                             drawings: [DrawingObject]) throws -> Int64 {
        let feeJSON = try jsonEncode(record.feeSnapshot)
        try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name,
               start_year, start_month, total_capital, profit, return_rate,
               max_drawdown, buy_count, sell_count, fee_snapshot, final_tick)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.trainingSetFilename, record.createdAt,
                record.stockCode, record.stockName,
                record.startYear, record.startMonth,
                record.totalCapital, record.profit, record.returnRate,
                record.maxDrawdown, record.buyCount, record.sellCount,
                feeJSON, record.finalTick
            ])
        let recordId = db.lastInsertedRowID

        for op in ops {
            try db.execute(sql: """
                INSERT INTO trade_operations
                  (record_id, global_tick, period, direction, price, shares,
                   position_tier, commission, stamp_duty, total_cost, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordId, op.globalTick, op.period.rawValue, op.direction.rawValue,
                    op.price, op.shares, op.positionTier.rawValue,
                    op.commission, op.stampDuty, op.totalCost, op.createdAt
                ])
        }

        for dr in drawings {
            let anchorsJSON = try jsonEncode(dr.anchors)
            try db.execute(sql: """
                INSERT INTO drawings
                  (record_id, tool_type, panel_position, is_extended, anchors)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    recordId, dr.toolType.rawValue, dr.panelPosition,
                    dr.isExtended ? 1 : 0, anchorsJSON
                ])
        }

        return recordId
    }

    static func listRecords(_ db: Database, limit: Int?) throws -> [TrainingRecord] {
        // R1 修订（codex med-1）：加 id DESC tiebreak 防同毫秒并列时 SQLite 任选不定序
        // code-review I-1：LIMIT 用 ? 占位符，与文件其它 SQL 站点参数化方式统一
        let baseSQL = "SELECT * FROM training_records ORDER BY created_at DESC, id DESC"
        let sql = limit != nil ? baseSQL + " LIMIT ?" : baseSQL
        let args: StatementArguments = limit.map { [$0] } ?? []
        let rows = try Row.fetchAll(db, sql: sql, arguments: args)
        return try rows.map { try recordFromRow($0) }
    }

    static func loadRecordBundle(_ db: Database, id: Int64) throws
        -> (TrainingRecord, [TradeOperation], [DrawingObject])
    {
        guard let recRow = try Row.fetchOne(db, sql:
            "SELECT * FROM training_records WHERE id = ?", arguments: [id])
        else {
            // record 不存在：caller 编程错误（id 应来自 insertRecord 返回 / listRecords）
            throw AppError.persistence(.dbCorrupted)
        }
        let record = try recordFromRow(recRow)

        let opRows = try Row.fetchAll(db, sql:
            "SELECT * FROM trade_operations WHERE record_id = ? ORDER BY id ASC", arguments: [id])
        let ops = try opRows.map { try opFromRow($0) }

        let drRows = try Row.fetchAll(db, sql:
            "SELECT * FROM drawings WHERE record_id = ? ORDER BY id ASC", arguments: [id])
        let drawings = try drRows.map { try drawingFromRow($0) }

        return (record, ops, drawings)
    }

    static func statistics(_ db: Database) throws
        -> (totalCount: Int, winCount: Int, currentCapital: Double)
    {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM training_records") ?? 0
        let wins = try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM training_records WHERE profit > 0") ?? 0
        // currentCapital：最后一条（按 created_at DESC, id DESC）的 total_capital + profit
        // R1 修订（codex med-1）：加 id DESC tiebreak 防同毫秒并列
        let cap: Double = try Row.fetchOne(db, sql: """
            SELECT total_capital, profit FROM training_records
            ORDER BY created_at DESC, id DESC LIMIT 1
            """).map { row in
            let tc: Double = row["total_capital"]
            let p: Double = row["profit"]
            return tc + p
        } ?? 0
        return (total, wins, cap)
    }

    // MARK: - Row → Model

    private static func recordFromRow(_ row: Row) throws -> TrainingRecord {
        let feeJSON: String = row["fee_snapshot"]
        let fee: FeeSnapshot = try jsonDecode(feeJSON, as: FeeSnapshot.self)
        return TrainingRecord(
            id: row["id"], trainingSetFilename: row["training_set_filename"],
            createdAt: row["created_at"],
            stockCode: row["stock_code"], stockName: row["stock_name"],
            startYear: row["start_year"], startMonth: row["start_month"],
            totalCapital: row["total_capital"], profit: row["profit"],
            returnRate: row["return_rate"], maxDrawdown: row["max_drawdown"],
            buyCount: row["buy_count"], sellCount: row["sell_count"],
            feeSnapshot: fee, finalTick: row["final_tick"]
        )
    }

    private static func opFromRow(_ row: Row) throws -> TradeOperation {
        let periodRaw: String = row["period"]
        guard let period = Period(rawValue: periodRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let dirRaw: String = row["direction"]
        guard let direction = TradeDirection(rawValue: dirRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let tierRaw: String = row["position_tier"]
        guard let tier = PositionTier(rawValue: tierRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return TradeOperation(
            globalTick: row["global_tick"], period: period, direction: direction,
            price: row["price"], shares: row["shares"], positionTier: tier,
            commission: row["commission"], stampDuty: row["stamp_duty"],
            totalCost: row["total_cost"], createdAt: row["created_at"]
        )
    }

    private static func drawingFromRow(_ row: Row) throws -> DrawingObject {
        let toolRaw: String = row["tool_type"]
        guard let tool = DrawingToolType(rawValue: toolRaw) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let anchorsJSON: String = row["anchors"]
        let anchors: [DrawingAnchor] = try jsonDecode(anchorsJSON, as: [DrawingAnchor].self)
        let isExt: Int = row["is_extended"]
        return DrawingObject(toolType: tool, anchors: anchors,
                             isExtended: isExt != 0, panelPosition: row["panel_position"])
    }

    // MARK: - JSON helpers（共享给其它 *Impl.swift）

    static func jsonEncode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return s
    }

    static func jsonDecode<T: Decodable>(_ string: String, as: T.Type) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw AppError.persistence(.dbCorrupted)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
