// Wave 2 顺位 11 — 生产组合根配置（spec 2026-06-08 §4.1）。纯值。
import Foundation

public struct AppConfig: Sendable {
    public let dbPath: URL          // app.sqlite 绝对路径（生产 = App Support dir）
    public let cacheRootDir: URL    // 训练集缓存根（生产 = Caches dir）
    public let backendBaseURL: URL  // P1 API base（生产 = NAS 部署后填；本 PR placeholder）
    public init(dbPath: URL, cacheRootDir: URL, backendBaseURL: URL) {
        self.dbPath = dbPath
        self.cacheRootDir = cacheRootDir
        self.backendBaseURL = backendBaseURL
    }
}
