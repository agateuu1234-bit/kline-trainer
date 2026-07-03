// ios/Contracts/Tests/KlineTrainerContractsTests/UI/ReviewMarkersContentTests.swift
// review-redesign Task 11：HomeHistoryRow 的 replayInProgress / reviewMarker 正交组合。
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HomeContent review markers (Task 11)")
struct ReviewMarkersContentTests {

    private func makeRecord(id: Int64) -> TrainingRecord {
        TrainingRecord(
            id: id, trainingSetFilename: "f.sqlite", createdAt: 1_000 + id,
            stockCode: "600519", stockName: "贵州茅台", startYear: 2021, startMonth: 8,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: -0.05,
            buyCount: 1, sellCount: 1,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 100)
    }

    @Test("replayInProgress 与 reviewMarker 正交并存/独立取值（含 1 号行两者皆真）")
    func orthogonalMarkers() {
        let records = [1, 2, 3, 4].map { makeRecord(id: Int64($0)) }
        let content = HomeContent(
            statistics: (totalCount: 4, winCount: 0, currentCapital: 100_000),
            configuredCapital: 100_000, records: records,
            hasPending: false, hasCachedSets: true,
            replaySlotRecordId: 1,
            reviewMarkers: [2: .inProgress, 3: .saved, 1: .inProgress])

        func row(_ id: Int64) -> HomeHistoryRow {
            content.rows.first { $0.id == id }!
        }

        #expect(row(1).replayInProgress == true)
        #expect(row(1).reviewMarker == .inProgress)

        #expect(row(2).replayInProgress == false)
        #expect(row(2).reviewMarker == .inProgress)

        #expect(row(3).replayInProgress == false)
        #expect(row(3).reviewMarker == .saved)

        #expect(row(4).replayInProgress == false)
        #expect(row(4).reviewMarker == .none)
    }
}
