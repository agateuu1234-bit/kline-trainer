// ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift
// Kline Trainer Swift Contracts — 下载批量结果反馈纯值（Wave 3 PR 13a §B.3）
//
// 平台无关纯值（host 全测）：把 DownloadAcceptanceRunner.runBatch 的 [AcceptanceResult] 决策成
// (a) 进度/汇总标签 statusSummary（区分 成功 / 待确认 / 失败）+ (b) per-item **终态失败**原因 toast。
// 沿用 TradeFeedback 范式（纯值，AppError.userMessage 单一文案源）。
//
// codex-13a-R3：`.pendingConfirmation`（本地已缓存、仅服务端确认网络不确定，可经启动重试自愈）**不**计失败——
// 否则误报「失败」诱导用户重复下载、掩盖恢复态。仅 `.rejected`（终态失败）进失败计数与 toast。

import Foundation

public struct DownloadBatchFeedback: Equatable, Sendable {
    /// 服务端确认 + 本地可用的数量。
    public let confirmedCount: Int
    /// 本地已缓存、待服务端确认（启动重试自愈）的数量——**非失败**。
    public let pendingCount: Int
    /// 终态失败数量（下载/校验/落盘失败，或 409/404 拒收）。
    public let failedCount: Int
    /// 进度/汇总标签（取代旧「完成：ok/total 成功」，诚实区分三态）。
    public let statusSummary: String
    /// 需展示的**终态失败**原因 toast 文案；nil = 无终态失败（不打扰）。
    public let toastMessage: String?

    /// - Parameter maxReasons: 最多列出的 distinct 失败原因数（超出以「等」收尾），防文案过长。
    public init(results: [AcceptanceResult], maxReasons: Int = 3) {
        var confirmed = 0
        var pending = 0
        var failures: [AppError] = []
        for r in results {
            switch r {
            case .confirmed: confirmed += 1
            case .pendingConfirmation: pending += 1
            case .rejected(let e): failures.append(e)
            }
        }
        self.confirmedCount = confirmed
        self.pendingCount = pending
        self.failedCount = failures.count

        var parts = ["\(confirmed) 成功"]
        if pending > 0 { parts.append("\(pending) 待确认") }
        if !failures.isEmpty { parts.append("\(failures.count) 失败") }
        self.statusSummary = "完成：" + parts.joined(separator: "，")

        if failures.isEmpty {
            self.toastMessage = nil
        } else {
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
}
