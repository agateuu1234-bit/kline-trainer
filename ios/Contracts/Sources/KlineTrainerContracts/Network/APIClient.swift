// P1 APIClient 契约 — 训练组 lease 预占-下载-确认（对接 backend/openapi.yaml）。
// M0.4 §L655：所有方法 throws AppError；M0.5 §L711：返回值 Sendable。

import Foundation

public protocol APIClient: Sendable {
    /// GET /training-sets/meta?count=N — 批量预占。
    /// 返回 LeaseResponse；sets 含 0..count 项（partial 是合法 200，不抛错——
    /// contract-freeze 见 backend/openapi.yaml + tests/contract-fixtures/）。
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse

    /// GET /training-set/{id}/download — 下载 zip 到本地临时文件，返回其 URL。
    /// CRC/MD5 完整性校验不在 P1 scope（P2 DownloadAcceptanceRunner 负责）。
    /// 调用方负责后续移动/删除返回的临时文件。
    func downloadTrainingSet(id: Int) async throws -> URL

    /// POST /training-set/{id}/confirm?lease_id=X — 确认下载；幂等（重复 200）。
    func confirmTrainingSet(id: Int, leaseId: String) async throws
}
