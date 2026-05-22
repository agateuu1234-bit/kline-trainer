// P1 网络传输缝：抽象 URLSession 的 data/download，测试可注入 fake。
// URLSession 原生满足（iOS 15+ / macOS 12+），空 extension 即可。

import Foundation

public protocol HTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension URLSession: HTTPRequesting {
    // macOS 15+ SDK renamed the no-delegate overload; bridge via delegate:nil.
    public func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await download(for: request, delegate: nil)
    }
}
