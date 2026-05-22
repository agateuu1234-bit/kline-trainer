import Foundation
import KlineTrainerContracts

/// P1 APIClient 生产实现。担任 M0.5 §L682 "NetworkExecutor" 内部 actor 角色：
/// 单一类型即提供协议实现 + 后台可执行 + actor 隔离 + Sendable 边界。
/// 所有失败在本 actor 边界内翻译为 AppError（M0.4 trust-boundary gate）。
public actor DefaultAPIClient: APIClient {
    private let baseURL: URL
    private let transport: HTTPRequesting
    private let decoder: JSONDecoder
    // ISO8601DateFormatter 不能同时接受有/无毫秒两种形式——设 .withFractionalSeconds 则拒绝无毫秒形式，
    // 反之亦然；因此保留两个 formatter，任一解析成功即视为合法。
    private let iso8601: ISO8601DateFormatter      // 无毫秒（如 2026-05-22T12:34:56Z）
    private let iso8601Frac: ISO8601DateFormatter  // 有毫秒（如 2026-05-22T12:34:56.123Z）

    public init(baseURL: URL, transport: HTTPRequesting = URLSession.shared) {
        self.baseURL = baseURL
        self.transport = transport
        self.decoder = JSONDecoder()
        self.iso8601 = ISO8601DateFormatter()
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso8601Frac = frac
    }

    public func reserveTrainingSets(count: Int) async throws -> LeaseResponse {
        // codex R1 medium：先于 side-effecting GET 按 openapi count 1...100 校验，
        // 避免用越界 count 发起预占（reserve 有副作用，会消耗库存）。
        guard (1...100).contains(count) else {
            throw AppError.internalError(module: "P1", detail: "invalid_count")
        }
        let url = baseURL
            .appending(path: "training-sets/meta")
            .appending(queryItems: [URLQueryItem(name: "count", value: String(count))])
        // codex R5 high：public 方法体零 raw 危险 try——IO/解码全走 private helper（对齐 P5 gate 规则 2）。
        let (data, response) = try await send(URLRequest(url: url))
        try requireStatus(response, 200)
        let lease = try decodeLease(data)
        // codex R1 medium：sets 是 0..count（partial-200 freeze）；超出 = 契约违反 → fail-closed。
        guard lease.sets.count <= count else {
            throw AppError.internalError(module: "P1", detail: "overfull_lease")
        }
        // codex R4 high：DTO 是 plain String，补回 openapi format/pattern。
        try validateMetaContract(lease)
        return lease
    }

    public func downloadTrainingSet(id: Int) async throws -> URL {
        let url = baseURL.appending(path: "training-set/\(id)/download")
        let (tempURL, response) = try await sendDownload(URLRequest(url: url))
        // sendDownload 在 tempURL 创建前 throw（传输错误）→ 无文件可清理；defer 仅覆盖拿到 tempURL 之后的路径。
        // codex R2 medium：拿到 tempURL 后任何 throw（status / move / 取消）都必须清理临时文件，
        // 否则降级响应反复打来会撑爆临时存储。moved=true 表示所有权已转移给 dest。
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: tempURL) } }
        try requireDownloadStatus(response)
        let dest = try moveToOwnedTemp(tempURL, id: id)
        moved = true
        return dest
    }

    public func confirmTrainingSet(id: Int, leaseId: String) async throws {
        // codex R2 high：lease_id openapi format=uuid；非 UUID（如 corrupt journal 行）必须
        // 在发请求前 fail-closed，避免 server 返回未文档化 4xx 被误映射为可重试 serverError。
        guard UUID(uuidString: leaseId) != nil else {
            throw AppError.internalError(module: "P1", detail: "invalid_lease_id")
        }
        let url = baseURL
            .appending(path: "training-set/\(id)/confirm")
            .appending(queryItems: [URLQueryItem(name: "lease_id", value: leaseId)])
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // codex R5 high：public 方法体零 raw 危险 try——IO/解码走 helper。
        let (data, response) = try await send(req)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.internalError(module: "P1", detail: "non_http_response")
        }
        switch http.statusCode {
        case 200:  try requireConfirmOk(data)         // 含幂等重复
        case 409:  throw AppError.network(.leaseExpired)
        case 404:  throw AppError.network(.leaseNotFound)
        default:   try failUnexpectedStatus(http.statusCode)
        }
    }

    /// confirm 200 响应体（openapi `{ ok: boolean }`）；仅内部解码用。
    private struct ConfirmResponse: Decodable { let ok: Bool }

    // MARK: - IO helpers（codex R5：raw 危险 try 全封在此区，public 方法体零 raw try——对齐 P5 gate 规则 2）

    /// transport.data + 错误翻译。
    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        try await perform { try await self.transport.data(for: req) }
    }

    /// transport.download + 错误翻译。
    private func sendDownload(_ req: URLRequest) async throws -> (URL, URLResponse) {
        try await perform { try await self.transport.download(for: req) }
    }

    /// LeaseResponse 解码；失败 fail-closed（200 但 body 不可解码 = 服务端契约违反）。
    private func decodeLease(_ data: Data) throws -> LeaseResponse {
        do { return try decoder.decode(LeaseResponse.self, from: data) }
        catch { throw AppError.internalError(module: "P1", detail: "meta_decode_failed") }
    }

    /// confirm 200 body {ok:true} 校验（codex R1 high）；解码失败 / ok==false fail-closed。
    private func requireConfirmOk(_ data: Data) throws {
        let ok: Bool
        do { ok = try decoder.decode(ConfirmResponse.self, from: data).ok }
        catch { throw AppError.internalError(module: "P1", detail: "confirm_decode_failed") }
        guard ok else { throw AppError.internalError(module: "P1", detail: "confirm_not_ok") }
    }

    /// URLSession 临时文件不会立即自动删除 → 移到 P1 拥有的临时位置。
    private func moveToOwnedTemp(_ src: URL, id: Int) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appending(path: "p1-download-\(id)-\(UUID().uuidString).zip")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: src, to: dest)
        } catch {
            throw AppError.persistence(.ioError("download_move_failed"))
        }
        return dest
    }

    // MARK: - error translation / status helpers

    /// codex branch-diff F2：非预期 HTTP 状态分类并抛出——5xx + 429 = transient 可重试 serverError；
    /// 其它非预期 4xx（400/401/403/422 等）= terminal（契约/权限/请求错误，重试无意义）。
    private func failUnexpectedStatus(_ code: Int) throws -> Never {
        if code >= 500 || code == 429 {
            throw AppError.network(.serverError(code: code))
        }
        throw AppError.internalError(module: "P1", detail: "http_\(code)")
    }

    /// 把传输层抛出的 URLError / 其它 error 翻译为 AppError；已是 AppError 则透传。
    /// codex R2：协作取消（CancellationError / URLError.cancelled）统一重抛 CancellationError
    /// （AppError-only gate 唯一例外），让调用方区分"主动取消" vs "失败"。
    /// codex R3：catch-all 用 `(error as? AppError) ?? translate(...)` 单表达式，无 bare-variable 旁路。
    // T: Sendable —— op 在 nonisolated 上下文执行，结果须跨回 actor 边界（CI macos-15 Swift 6.0
    // strict-concurrency 强制；本地较新 toolchain 靠 region-based isolation 推断未报）。
    private func perform<T: Sendable>(_ op: () async throws -> T) async throws -> T {
        do {
            return try await op()
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw CancellationError()
        } catch {
            throw (error as? AppError) ?? APIErrorMapping.translate(error)
        }
    }

    /// HTTP 状态校验（单一 expected status 的 endpoint，如 meta）：== expected 否则 fail-closed 抛 serverError；非 HTTP 抛 internalError。
    private func requireStatus(_ response: URLResponse, _ expected: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.internalError(module: "P1", detail: "non_http_response")
        }
        guard http.statusCode == expected else {
            try failUnexpectedStatus(http.statusCode)
        }
    }

    /// download 状态映射（codex R5 medium）：200 OK；404 = terminal `.trainingSet(.fileNotFound)`
    /// （id 不存在/journal 损坏，重试无意义，isRecoverable=false）；其它非 200 = serverError；
    /// 非 HTTP = internalError。
    private func requireDownloadStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.internalError(module: "P1", detail: "non_http_response")
        }
        switch http.statusCode {
        case 200:  return
        case 404:  throw AppError.trainingSet(.fileNotFound)
        default:   try failUnexpectedStatus(http.statusCode)
        }
    }

    /// codex R4 high：LeaseResponse DTO 是 plain String，补回 openapi format/pattern 契约。
    private func validateMetaContract(_ lease: LeaseResponse) throws {
        guard UUID(uuidString: lease.leaseId) != nil else {
            throw AppError.internalError(module: "P1", detail: "meta_invalid_lease_id")
        }
        guard iso8601.date(from: lease.expiresAt) != nil
                || iso8601Frac.date(from: lease.expiresAt) != nil else {
            throw AppError.internalError(module: "P1", detail: "meta_invalid_expires_at")
        }
        for s in lease.sets
        where s.contentHash.range(of: "^[0-9a-f]{8}$", options: .regularExpression) == nil {
            throw AppError.internalError(module: "P1", detail: "meta_invalid_content_hash")
        }
    }
}
