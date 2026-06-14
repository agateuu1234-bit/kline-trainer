import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("DownloadBatchFeedback：下载批量 per-item 失败原因文案（§B.3，host 全测）")
struct DownloadBatchFeedbackTests {

    private func file(_ id: Int) -> TrainingSetFile {
        TrainingSetFile(id: id, filename: "f\(id).sqlite",
                        localURL: URL(fileURLWithPath: "/tmp/f\(id).sqlite"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    @Test("全成功 → toastMessage nil（无失败不打扰）+ statusSummary 仅成功")
    func allConfirmed_noToast() {
        let fb = DownloadBatchFeedback(results: [.confirmed(file(1)), .confirmed(file(2))])
        #expect(fb.toastMessage == nil)
        #expect(fb.confirmedCount == 2)
        #expect(fb.failedCount == 0)
        #expect(fb.statusSummary == "完成：2 成功")
    }

    // codex-13a-R3：pendingConfirmation（本地已缓存待确认）**不**计失败、不弹失败 toast。
    @Test("pendingConfirmation 不计失败：toast nil + statusSummary 标待确认")
    func pendingConfirmation_notCountedAsFailure() {
        let fb = DownloadBatchFeedback(results: [
            .confirmed(file(1)),
            .pendingConfirmation(file(2)),
            .pendingConfirmation(file(3))
        ])
        #expect(fb.toastMessage == nil, "待确认不是失败，不弹失败 toast")
        #expect(fb.confirmedCount == 1)
        #expect(fb.pendingCount == 2)
        #expect(fb.failedCount == 0)
        #expect(fb.statusSummary == "完成：1 成功，2 待确认")
    }

    // codex-13a-R3：三态混合 → 计数精确 + statusSummary 三段 + toast 仅终态失败原因。
    @Test("混合 confirmed/pending/rejected：计数精确，toast 仅终态失败")
    func mixedThreeStates_countsAndToast() {
        let fb = DownloadBatchFeedback(results: [
            .confirmed(file(1)),
            .pendingConfirmation(file(2)),
            .rejected(.trainingSet(.crcFailed))
        ])
        #expect(fb.confirmedCount == 1)
        #expect(fb.pendingCount == 1)
        #expect(fb.failedCount == 1)
        #expect(fb.statusSummary == "完成：1 成功，1 待确认，1 失败")
        #expect(fb.toastMessage == "1 个失败：训练组文件校验失败")
    }

    @Test("部分失败 → 文案含失败数 + distinct userMessage")
    func partialFailure_listsDistinctReasons() {
        let fb = DownloadBatchFeedback(results: [
            .confirmed(file(1)),
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.network(.timeout))
        ])
        #expect(fb.toastMessage == "2 个失败：训练组文件校验失败 / 网络超时，请稍后重试")
    }

    @Test("重复原因去重（保序）")
    func duplicateReasons_deduped() {
        let fb = DownloadBatchFeedback(results: [
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.trainingSet(.crcFailed))
        ])
        #expect(fb.toastMessage == "2 个失败：训练组文件校验失败")
    }

    @Test("超过 maxReasons 截断（仅列前 N 个 distinct）")
    func reasonsTruncatedToMax() {
        let fb = DownloadBatchFeedback(results: [
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.trainingSet(.unzipFailed)),
            .rejected(.network(.offline)),
            .rejected(.persistence(.diskFull))
        ], maxReasons: 2)
        #expect(fb.toastMessage == "4 个失败：训练组文件校验失败 / 训练组解压失败 等")
    }
}
