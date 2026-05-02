// Kline Trainer Swift Contracts — P4 PendingTrainingRepository
// Spec: kline_trainer_modules_v1.4.md §P4 (line 1863-1937，protocol 体 1879-1883)

public protocol PendingTrainingRepository: Sendable {
    func savePending(_: PendingTraining) throws
    func loadPending() throws -> PendingTraining?
    func clearPending() throws
}
