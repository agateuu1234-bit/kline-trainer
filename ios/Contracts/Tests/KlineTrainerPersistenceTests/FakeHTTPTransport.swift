import Foundation
import KlineTrainerContracts

/// HTTPRequesting 测试替身：返回预设 (body, statusCode) 或抛任意 Error，并捕获请求 +
/// download 临时文件 URL（供 codex R2 download-cleanup 测试断言临时文件已清理）。
final class FakeHTTPTransport: HTTPRequesting, @unchecked Sendable {
    struct Stub {
        var body: Data = Data()
        var statusCode: Int = 200
        /// 任意 Error（URLError / CancellationError / 其它），codex R2 取消语义测试需要。
        var error: Error? = nil
        /// download 写入临时文件的内容；nil 时为空文件。
        var downloadFileContents: Data? = nil
        /// 返回非 HTTPURLResponse（测试 non-HTTP 分支）。
        var returnNonHTTPResponse: Bool = false
    }

    let stub: Stub
    private let lock = NSLock()
    private var _captured: [URLRequest] = []
    private var _lastDownloadTempURL: URL?
    var capturedRequests: [URLRequest] {
        lock.withLock { _captured }
    }
    /// download 最近一次创建的临时文件 URL（测试断言失败路径已清理）。
    var lastDownloadTempURL: URL? {
        lock.withLock { _lastDownloadTempURL }
    }

    init(stub: Stub) { self.stub = stub }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        if let e = stub.error { throw e }
        return (stub.body, response(for: request.url!))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        record(request)
        if let e = stub.error { throw e }
        // 模拟 URLSession.download：任何完成的 HTTP 事务都把 body 写入临时文件（含非 200 的 error body）——这正是 DefaultAPIClient defer 清理要覆盖的场景。
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "fake-dl-\(UUID().uuidString).zip")
        try (stub.downloadFileContents ?? Data()).write(to: tmp)
        lock.withLock { _lastDownloadTempURL = tmp }
        return (tmp, response(for: request.url!))
    }

    private func record(_ r: URLRequest) {
        lock.withLock { _captured.append(r) }
    }

    private func response(for url: URL) -> URLResponse {
        if stub.returnNonHTTPResponse {
            return URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        }
        return HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil)!
    }
}
