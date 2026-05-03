import Foundation
@preconcurrency import GRDB

/// 内部 row 类型，仅供 DefaultTrainingSetReader.loadAllCandles 使用。
/// FetchableRecord + Decodable 让 GRDB 走 internal throwing decode 路径：
/// 列类型 mismatch / NULL 出现在 NOT NULL 列 → 抛 RowDecodingError，
/// 由 Reader 外层 catch 翻译为 AppError.persistence(.dbCorrupted)。
///
/// 不直接让 KLineCandle 在 Contracts 包内 conform FetchableRecord，
/// 否则 KlineTrainerContracts 必须 import GRDB —— 违反 Design Decision §1。
struct KLineRow: FetchableRecord, Decodable {
    let period: String
    let datetime: Int64
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int64
    let amount: Double?
    let ma66: Double?
    let bollUpper: Double?
    let bollMid: Double?
    let bollLower: Double?
    let macdDiff: Double?
    let macdDea: Double?
    let macdBar: Double?
    let globalIndex: Int?
    let endGlobalIndex: Int

    enum CodingKeys: String, CodingKey {
        case period, datetime, open, high, low, close, volume, amount, ma66
        case bollUpper = "boll_upper"
        case bollMid = "boll_mid"
        case bollLower = "boll_lower"
        case macdDiff = "macd_diff"
        case macdDea = "macd_dea"
        case macdBar = "macd_bar"
        case globalIndex = "global_index"
        case endGlobalIndex = "end_global_index"
    }
}
