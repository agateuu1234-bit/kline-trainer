// Kline Trainer Swift Contracts — P5 CacheManager
// Spec: kline_trainer_modules_v1.4.md §P5 (line 1950-1968，protocol 体 1953-1959)

import Foundation

public protocol CacheManager: Sendable {
    func listAvailable() -> [TrainingSetFile]
    func pickRandom() -> TrainingSetFile?
    func store(downloadedZip: URL, meta: TrainingSetMetaItem) throws -> TrainingSetFile
    func touch(_: TrainingSetFile)
    func delete(_: TrainingSetFile) throws
}
