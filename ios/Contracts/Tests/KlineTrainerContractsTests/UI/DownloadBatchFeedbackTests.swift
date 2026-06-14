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

    @Test("全成功 → toastMessage nil（无失败不打扰）")
    func allConfirmed_noToast() {
        let fb = DownloadBatchFeedback(results: [.confirmed(file(1)), .confirmed(file(2))])
        #expect(fb.toastMessage == nil)
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
