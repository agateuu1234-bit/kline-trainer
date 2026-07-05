import Foundation
@preconcurrency import GRDB
import KlineTrainerContracts

/// RecordRepository 静态方法实现。所有方法在 DefaultAppDB.dbQueue.read/write 闭包内调用。
/// 调用方负责 dbQueue.write 包事务 + GRDB 错误翻译。
enum RecordRepositoryImpl {

    static func insertRecord(_ db: Database, record: TrainingRecord,
                             ops: [TradeOperation],
                             drawings: [DrawingObject],
                             sessionKey: String? = nil) throws -> Int64 {
        // §4.7c 幂等锚：同 key 已入库（前次事务已 commit）→ no-op 返已存 id，不重插 ops/drawings。
        // 单写者 DatabaseQueue + 事务内查询无 race；UNIQUE index 兜底逻辑漏洞（漏判 → SQLITE_CONSTRAINT）。
        if let key = sessionKey,
           let existing = try Int64.fetchOne(db, sql:
               "SELECT id FROM training_records WHERE session_key = ?", arguments: [key]) {
            return existing
        }
        let feeJSON = try jsonEncode(record.feeSnapshot)
        try db.execute(sql: """
            INSERT INTO training_records
              (training_set_filename, created_at, stock_code, stock_name,
               start_year, start_month, total_capital, profit, return_rate,
               max_drawdown, buy_count, sell_count, fee_snapshot, final_tick, session_key)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                record.trainingSetFilename, record.createdAt,
                record.stockCode, record.stockName,
                record.startYear, record.startMonth,
                record.totalCapital, record.profit, record.returnRate,
                record.maxDrawdown, record.buyCount, record.sellCount,
                feeJSON, record.finalTick, sessionKey
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
            let styleJSON = try jsonEncode(DrawingStyle(from: dr))
            // draw_uuid：迁移 0009 加的 NOT NULL/CHECK/UNIQUE 列（跨层身份，D16/D20）；dr.id 已是稳定 UUID
            // （Models.swift DrawingObject.id 默认值，或 lossy 层 legacy-idx-N 回填——均非空，满足 CHECK<>''）。
            // style_json：除 id/toolType/anchors/isExtended/panelPosition/reveal_tick 外的样式/文本字段束。
            try db.execute(sql: """
                INSERT INTO drawings
                  (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    recordId, dr.toolType.rawValue, dr.panelPosition,
                    dr.isExtended ? 1 : 0, anchorsJSON, dr.revealTick, dr.id, styleJSON
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
        // 未知/未来 tool_type 的 finalized 行 → drawingFromRow 返回 nil，compactMap 跳过（不伪装成 .horizontal）。
        let drawings = try drRows.compactMap { try drawingFromRow($0) }

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

    /// 删除全部训练记录及其 FK 子行（drawings / trade_operations）。
    /// schema 无 ON DELETE CASCADE，故子表先删；调用方负责 dbQueue.write 事务包裹。
    static func deleteAll(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM drawings")
        try db.execute(sql: "DELETE FROM trade_operations")
        try db.execute(sql: "DELETE FROM training_records")
    }

    // MARK: - Row → Model

    private static func recordFromRow(_ row: Row) throws -> TrainingRecord {
        let feeJSON: String = row["fee_snapshot"]
        let fee: FeeSnapshot = try jsonDecode(feeJSON, as: FeeSnapshot.self)
            .sanitizedForLegacyCorruption()  // WB-1：清除 legacy 负/非有限 commissionRate
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

    /// 返回 nil = 未知/未来 `tool_type` 的 finalized 行 → **lossy 跳过**（不静默伪装成 `.horizontal`，codex R3-medium）。
    /// finalized 行只读、加载不重写，跳过非破坏性（DB 行保留、仅本次不呈现）。caller 用 compactMap 过滤 nil。
    private static func drawingFromRow(_ row: Row) throws -> DrawingObject? {
        let toolRaw: String = row["tool_type"]
        guard let tool = DrawingToolType(rawValue: toolRaw) else { return nil }   // 未知→跳过，不 coerce .horizontal
        let anchorsJSON: String = row["anchors"]
        let anchors: [DrawingAnchor] = try jsonDecode(anchorsJSON, as: [DrawingAnchor].self)
        let drawUuid: String = row["draw_uuid"]
        let isExt = (row["is_extended"] as Int) != 0
        // NULL style_json（旧行）→ **行感知兜底**：lineSubType 由 is_extended 派生（true→.ray/false→.straight）、
        // period 由锚点派生——不能用扁平 defaults（会把 is_extended=1 的旧线错读成 .straight，codex R3-high）。
        let style: DrawingStyle = try (row["style_json"] as String?)
            .map { try jsonDecode($0, as: DrawingStyle.self) }
            ?? DrawingStyle.legacyFallback(isExtended: isExt, period: anchors.first?.period ?? .m3)
        return DrawingObject(
            id: drawUuid, toolType: tool, anchors: anchors,
            isExtended: isExt, panelPosition: row["panel_position"],
            revealTick: row["reveal_tick"], period: style.period, lineSubType: style.lineSubType,
            lineStyle: style.lineStyle, thickness: style.thickness, colorToken: style.colorToken,
            labelMode: style.labelMode, locked: style.locked, text: style.text, fontSize: style.fontSize,
            textColorToken: style.textColorToken, textForm: style.textForm, tailAnchor: style.tailAnchor)
    }

    /// style_json 列的 payload 结构 = 除 id/toolType/anchors/isExtended/panelPosition/reveal_tick 外的
    /// 样式/文本字段束（这些已是独立列，不重复存）。
    private struct DrawingStyle: Codable {
        var period: Period; var lineSubType: LineSubType; var lineStyle: LineStyle
        var thickness: Int; var colorToken: DrawingColorToken; var labelMode: LabelMode
        var locked: Bool; var text: String; var fontSize: Int
        var textColorToken: DrawingColorToken; var textForm: TextForm; var tailAnchor: DrawingAnchor?
        init(from d: DrawingObject) {
            period = d.period; lineSubType = d.lineSubType; lineStyle = d.lineStyle
            thickness = d.thickness; colorToken = d.colorToken; labelMode = d.labelMode
            locked = d.locked; text = d.text; fontSize = d.fontSize
            textColorToken = d.textColorToken; textForm = d.textForm; tailAnchor = d.tailAnchor
        }
        static var defaults: DrawingStyle {
            DrawingStyle(from: DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0))
        }
        /// 旧行（NULL style_json）行感知兜底：lineSubType 由 is_extended 派生、period 由锚点派生（codex R3-high）。
        static func legacyFallback(isExtended: Bool, period: Period) -> DrawingStyle {
            var s = DrawingStyle.defaults
            s.period = period
            s.lineSubType = isExtended ? .ray : .straight   // spec §11.1/§4.2：旧 isExtended→lineSubType
            return s
        }
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
