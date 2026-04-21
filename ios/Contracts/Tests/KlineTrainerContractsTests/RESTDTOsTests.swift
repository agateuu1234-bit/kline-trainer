import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("REST DTO decoding")
struct RESTDTOsTests {
    @Test func leaseResponse_decodesFixture() throws {
        let url = Bundle.module.url(forResource: "lease_response", withExtension: "json", subdirectory: "fixtures")
        let data = try Data(contentsOf: #require(url))
        let resp = try JSONDecoder().decode(LeaseResponse.self, from: data)

        #expect(resp.leaseId == "6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d")
        #expect(resp.expiresAt == "2026-04-21T12:34:56Z")
        #expect(resp.sets.count == 2)

        let first = resp.sets[0]
        #expect(first.id == 101)
        #expect(first.stockCode == "600519")
        #expect(first.stockName == "贵州茅台")
        #expect(first.filename == "600519_202001.zip")
        #expect(first.schemaVersion == 1)
        #expect(first.contentHash == "deadbeef")
        #expect(first.contentHash.count == 8)
    }

    @Test func trainingSetMetaItem_snakeCaseKeys() throws {
        let json = """
        {
            "id": 1, "stock_code": "TEST", "stock_name": "N",
            "filename": "f.zip", "schema_version": 1, "content_hash": "00112233"
        }
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(TrainingSetMetaItem.self, from: json)
        #expect(item.contentHash == "00112233")
    }

    @Test func trainingSetMetaItem_roundTripPreservesSnakeCase() throws {
        let item = TrainingSetMetaItem(
            id: 9, stockCode: "X", stockName: "Y",
            filename: "z.zip", schemaVersion: 1, contentHash: "abcdef01"
        )
        let encoded = try JSONEncoder().encode(item)
        let json = String(data: encoded, encoding: .utf8)!
        #expect(json.contains("\"stock_code\":\"X\""))
        #expect(json.contains("\"schema_version\":1"))
        #expect(json.contains("\"content_hash\":\"abcdef01\""))
    }

    /// content_hash 格式跨契约对齐（Plan 1 PG CHECK + Plan 1b OpenAPI pattern + Plan 1c Swift 这里）
    @Test func contentHash_fixtureValuesMatchCRC32LowercaseHex() throws {
        let pattern = #/^[0-9a-f]{8}$/#
        for hash in ["deadbeef", "a0b1c2d3", "00112233", "abcdef01"] {
            #expect(hash.wholeMatch(of: pattern) != nil, "hash '\(hash)' should match ^[0-9a-f]{8}$")
        }
    }
}
