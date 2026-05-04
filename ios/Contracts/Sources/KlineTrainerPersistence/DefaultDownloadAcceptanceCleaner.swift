import Foundation
import os.log
import KlineTrainerContracts

public struct DefaultDownloadAcceptanceCleaner: DownloadAcceptanceCleaning {
    private static let log = OSLog(
        subsystem: "com.klinetrainer.persistence",
        category: "DownloadAcceptanceCleaner"
    )

    private let tempRootPath: String

    public init() {
        // R3：path containment guard 用 NSTemporaryDirectory 子树作 owned root
        // resolvingSymlinksInPath 防 /tmp → /private/tmp 这类 macOS symlink 绕过
        self.tempRootPath = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    public func cleanup(tempURLs: [URL]) {
        let fm = FileManager.default
        for url in tempURLs {
            let resolved = url.resolvingSymlinksInPath()
                .standardizedFileURL.path
            // R3 codex finding 1 + R4 codex finding 2：strict descendant，不允许 == tempRoot 本身
            // （否则 caller bug 传 tempRoot URL 会清空整个临时目录，影响其它 PR/系统组件）
            guard resolved.hasPrefix(tempRootPath + "/"), resolved != tempRootPath else {
                os_log(
                    "cleanup rejected non-temp-descendant path: %{public}@",
                    log: Self.log, type: .error, resolved
                )
                continue
            }
            do {
                try fm.removeItem(at: url)
            } catch {
                let nsErr = error as NSError
                if nsErr.domain == NSCocoaErrorDomain &&
                   (nsErr.code == NSFileNoSuchFileError ||
                    nsErr.code == NSFileReadNoSuchFileError) {
                    continue                           // 不存在路径不视为错误
                }
                os_log(
                    "cleanup failed: %{public}@ code=%{public}d",
                    log: Self.log, type: .error,
                    String(describing: url.lastPathComponent), nsErr.code
                )
            }
        }
    }
}
