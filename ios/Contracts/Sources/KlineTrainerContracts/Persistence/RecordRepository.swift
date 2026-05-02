// Kline Trainer Swift Contracts — P4 RecordRepository
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1870-1877)

public protocol RecordRepository: Sendable {
    func insertRecord(_: TrainingRecord,
                      ops: [TradeOperation],
                      drawings: [DrawingObject]) throws -> Int64
    func listRecords(limit: Int?) throws -> [TrainingRecord]
    func loadRecordBundle(id: Int64) throws -> (TrainingRecord, [TradeOperation], [DrawingObject])
    func statistics() throws -> (totalCount: Int, winCount: Int, currentCapital: Double)
}
