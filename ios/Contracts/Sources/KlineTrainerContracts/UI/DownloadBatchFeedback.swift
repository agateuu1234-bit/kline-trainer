// ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift
// Kline Trainer Swift Contracts — 下载批量结果反馈纯值（Wave 3 PR 13a §B.3）
//
// 平台无关纯值（host 全测）：把 DownloadAcceptanceRunner.runBatch 的 [AcceptanceResult] 决策成
// 一条非阻塞 toast 文案——列出 per-item 失败的 distinct userMessage（此前 SettingsPanel 仅数成功、
// 丢弃失败原因）。沿用 TradeFeedback 范式（纯值，AppError.userMessage 单一文案源）。

import Foundation

public struct DownloadBatchFeedback: Equatable, Sendable {
    /// 需展示的失败 toast 文案；nil = 无失败（全成功，不打扰）。
    public let toastMessage: String?

    /// - Parameter maxReasons: 最多列出的 distinct 原因数（超出以「等」收尾），防文案过长。
    public init(results: [AcceptanceResult], maxReasons: Int = 3) {
        let failures: [AppError] = results.compactMap {
            if case .rejected(let e) = $0 { return e }
            return nil
        }
        guard !failures.isEmpty else { self.toastMessage = nil; return }

        // distinct userMessage 保序去重
        var seen = Set<String>()
        var distinct: [String] = []
        for e in failures {
            let msg = e.userMessage
            if seen.insert(msg).inserted { distinct.append(msg) }
        }

        let shown = distinct.prefix(maxReasons).joined(separator: " / ")
        let suffix = distinct.count > maxReasons ? " 等" : ""
        self.toastMessage = "\(failures.count) 个失败：\(shown)\(suffix)"
    }
}
