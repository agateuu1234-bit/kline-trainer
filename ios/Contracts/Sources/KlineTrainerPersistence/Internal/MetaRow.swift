import Foundation
@preconcurrency import GRDB

/// 内部 row 类型，仅供 DefaultTrainingSetDBFactory.openAndVerify 使用。
/// FetchableRecord + Decodable 让 GRDB 走 internal throwing decode 路径：
/// 列类型 mismatch / NULL 出现在 NOT NULL 列 → 抛 RowDecodingError，
/// 由 Factory 外层 catch 翻译为 AppError.persistence(.dbCorrupted)。
///
/// 不让 TrainingSetMeta 在 Contracts 包内 conform FetchableRecord，
/// 否则 KlineTrainerContracts 必须 import GRDB —— 违反 Design Decision §1。
struct MetaRow: FetchableRecord, Decodable {
    let stockCode: String
    let stockName: String
    let startDatetime: Int64
    let endDatetime: Int64

    enum CodingKeys: String, CodingKey {
        case stockCode = "stock_code"
        case stockName = "stock_name"
        case startDatetime = "start_datetime"
        case endDatetime = "end_datetime"
    }
}
