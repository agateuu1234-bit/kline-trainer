// Kline Trainer Swift Contracts — M0.3 REST DTOs
// 字段命名对齐 backend/openapi.yaml（Plan 1b M0.2）

import Foundation

public struct LeaseResponse: Codable, Sendable {
    public let leaseId: String
    public let expiresAt: String
    public let sets: [TrainingSetMetaItem]

    public init(leaseId: String, expiresAt: String, sets: [TrainingSetMetaItem]) {
        self.leaseId = leaseId
        self.expiresAt = expiresAt
        self.sets = sets
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case expiresAt = "expires_at"
        case sets
    }
}

public struct TrainingSetMetaItem: Codable, Sendable {
    public let id: Int
    public let stockCode: String
    public let stockName: String
    public let filename: String
    public let schemaVersion: Int
    /// zip CRC32 十六进制，精确 8 字符小写（与 Plan 1 `ck_content_hash_crc32_lowercase` 对齐；Plan 1b OpenAPI pattern `^[0-9a-f]{8}$`）
    public let contentHash: String

    public init(
        id: Int, stockCode: String, stockName: String,
        filename: String, schemaVersion: Int, contentHash: String
    ) {
        self.id = id
        self.stockCode = stockCode
        self.stockName = stockName
        self.filename = filename
        self.schemaVersion = schemaVersion
        self.contentHash = contentHash
    }

    enum CodingKeys: String, CodingKey {
        case id
        case stockCode = "stock_code"
        case stockName = "stock_name"
        case filename
        case schemaVersion = "schema_version"
        case contentHash = "content_hash"
    }
}
