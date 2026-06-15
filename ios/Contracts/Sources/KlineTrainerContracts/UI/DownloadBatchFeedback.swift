// ios/Contracts/Sources/KlineTrainerContracts/UI/DownloadBatchFeedback.swift
// Kline Trainer Swift Contracts — 下载批量结果反馈纯值（Wave 3 PR 13a §B.3）
//
// 平台无关纯值（host 全测）：把 DownloadAcceptanceRunner.runBatch 的 [AcceptanceResult] 决策成
// (a) 进度/汇总标签 statusSummary + (b) per-item 未完成原因 toast（此前 SettingsPanel 仅数成功、丢弃原因）。
// 沿用 TradeFeedback 范式（纯值，AppError.userMessage 单一文案源）。
//
// 措辞「未完成」（非「失败」）：`AcceptanceResult` 仅 `.confirmed`/`.rejected` 两态，runner 按 plan 决策 5 把
// 「网络不确定 confirm（文件已缓存、可经 retryPendingConfirmations 重试）」也归 `.rejected`。本反馈层无 journal 访问，
// 无法区分「终态失败」与「已缓存待确认」→ 故用中性「未完成」如实表述（不误称已可用的待确认项为「失败」）。
// 精确区分 confirmed/待确认/失败（及模糊 confirm 的幂等安全策略）是 P2 DownloadAcceptance confirm 状态机的
// reliability 课题，**OUT of 顺位 13a scope**（touch-on-use + 边界 toast），记 residual 13a-R1 待独立 P2-confirm RFC。

import Foundation

public struct DownloadBatchFeedback: Equatable, Sendable {
    /// 服务端确认 + 本地可用的数量。
    public let confirmedCount: Int
    /// 未完成（runner 返回 `.rejected`：下载/校验/落盘失败、服务端拒收、或网络不确定 confirm）的数量。
    public let notCompletedCount: Int
    /// 进度/汇总标签（取代旧「完成：ok/total 成功」）。
    public let statusSummary: String
    /// 需展示的未完成原因 toast 文案；nil = 全部成功（不打扰）。
    public let toastMessage: String?

    /// - Parameter maxReasons: 最多列出的 distinct 原因数（超出以「等」收尾），防文案过长。
    public init(results: [AcceptanceResult], maxReasons: Int = 3) {
        var confirmed = 0
        var reasons: [AppError] = []
        for r in results {
            switch r {
            case .confirmed: confirmed += 1
            case .rejected(let e): reasons.append(e)
            }
        }
        self.confirmedCount = confirmed
        self.notCompletedCount = reasons.count

        var parts = ["\(confirmed) 成功"]
        if !reasons.isEmpty { parts.append("\(reasons.count) 未完成") }
        self.statusSummary = "完成：" + parts.joined(separator: "，")

        if reasons.isEmpty {
            self.toastMessage = nil
        } else {
            // distinct userMessage 保序去重
            var seen = Set<String>()
            var distinct: [String] = []
            for e in reasons {
                let msg = e.userMessage
                if seen.insert(msg).inserted { distinct.append(msg) }
            }
            let shown = distinct.prefix(maxReasons).joined(separator: " / ")
            let suffix = distinct.count > maxReasons ? " 等" : ""
            self.toastMessage = "\(reasons.count) 个未完成：\(shown)\(suffix)"
        }
    }
}
