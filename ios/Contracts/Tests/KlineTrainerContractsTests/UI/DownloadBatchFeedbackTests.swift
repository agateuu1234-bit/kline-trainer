import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("DownloadBatchFeedback：下载批量 per-item 未完成原因文案（§B.3，host 全测）")
struct DownloadBatchFeedbackTests {

    private func file(_ id: Int) -> TrainingSetFile {
        TrainingSetFile(id: id, filename: "f\(id).sqlite",
                        localURL: URL(fileURLWithPath: "/tmp/f\(id).sqlite"),
                        schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)
    }

    @Test("全成功 → toastMessage nil（不打扰）+ statusSummary 仅成功")
    func allConfirmed_noToast() {
        let fb = DownloadBatchFeedback(results: [.confirmed(file(1)), .confirmed(file(2))])
        #expect(fb.toastMessage == nil)
        #expect(fb.confirmedCount == 2)
        #expect(fb.notCompletedCount == 0)
        #expect(fb.statusSummary == "完成：2 成功")
    }

    @Test("部分未完成 → 文案含未完成数 + distinct userMessage + statusSummary 两段")
    func partialNotCompleted_listsDistinctReasons() {
        let fb = DownloadBatchFeedback(results: [
            .confirmed(file(1)),
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.network(.timeout))
        ])
        #expect(fb.confirmedCount == 1)
        #expect(fb.notCompletedCount == 2)
        #expect(fb.statusSummary == "完成：1 成功，2 未完成")
        #expect(fb.toastMessage == "2 个未完成：训练组文件校验失败 / 网络超时，请稍后重试")
    }

    @Test("重复原因去重（保序）")
    func duplicateReasons_deduped() {
        let fb = DownloadBatchFeedback(results: [
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.trainingSet(.crcFailed))
        ])
        #expect(fb.toastMessage == "2 个未完成：训练组文件校验失败")
        #expect(fb.statusSummary == "完成：0 成功，2 未完成")
    }

    @Test("超过 maxReasons 截断（仅列前 N 个 distinct，以「等」收尾）")
    func reasonsTruncatedToMax() {
        let fb = DownloadBatchFeedback(results: [
            .rejected(.trainingSet(.crcFailed)),
            .rejected(.trainingSet(.unzipFailed)),
            .rejected(.network(.offline)),
            .rejected(.persistence(.diskFull))
        ], maxReasons: 2)
        #expect(fb.toastMessage == "4 个未完成：训练组文件校验失败 / 训练组解压失败 等")
    }
}
