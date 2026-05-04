// Kline Trainer Swift Contracts — P2 port 4
// Spec: kline_trainer_modules_v1.4.md §P2 line 1771-1775

import Foundation

public protocol DownloadAcceptanceCleaning: Sendable {
    /// 清理一组临时 URL（典型为解压目录、下载 zip）。
    /// **非致命**：单个 URL 删除失败仅打日志，不抛、不返回错误。
    /// 不存在的路径不视为错误（同样仅 debug log）。
    func cleanup(tempURLs: [URL])
}
