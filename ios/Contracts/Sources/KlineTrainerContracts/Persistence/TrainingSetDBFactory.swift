// Kline Trainer Swift Contracts — P3a
// Spec: kline_trainer_modules_v1.4.md §P3a (line 1822-1838，protocol 体 1827-1832)

import Foundation

public protocol TrainingSetDBFactory: Sendable {
    /// 打开训练组 sqlite 文件并校验 schema_version / 基本元数据。
    /// - 失败时 throw AppError.trainingSet(.versionMismatch / .fileNotFound / .emptyData)
    /// - 每次调用产生新 reader 实例（绑定独立 DatabaseQueue）
    func openAndVerify(file: URL, expectedSchemaVersion: Int) throws -> TrainingSetReader
}
