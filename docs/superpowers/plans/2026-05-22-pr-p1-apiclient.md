# P1 APIClient Implementation Plan（Wave 1 顺位 2）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 P1 APIClient——对接 backend REST 的训练组 lease 预占-下载-确认客户端（3 方法，全部 `throws AppError`），并冻结 GET meta 的空/部分库存响应契约 + 建立 P1↔B3 共享 contract fixtures。

**Architecture:** 协议 `APIClient`（Contracts 层，3 个 async 方法）+ 生产实现 `actor DefaultAPIClient`（Persistence 层，担任 M0.5 §L682 "NetworkExecutor" 内部 actor 角色）。网络传输通过 `HTTPRequesting` 缝注入（`URLSession` 原生满足；测试注入 `FakeHTTPTransport`）。所有底层错误（`URLError` / 非 200 HTTP）在 actor 边界内翻译为 `AppError`（M0.4 trust-boundary gate）。Task 0 冻结 openapi.yaml 的库存不足响应为 partial-200 契约，并落 `tests/contract-fixtures/` 作 P1（Swift）/B3（Python，顺位 18）共享 frozen 契约层。

**Tech Stack:** Swift 6 / SwiftPM（`KlineTrainerContracts` + `KlineTrainerPersistence` targets）；XCTest（async）；Foundation `URLSession`；Python pytest + `openapi-spec-validator` + `pyyaml`（已有 `backend/tests/test_openapi.py`）。

**依赖:** 顺位 1c（required check 已生效，PR #58 merged）。无新 SwiftPM 依赖、无新 target、无新 Python 依赖。

---

## Task 0 — §15.3 评审策略前置

> 完成本 Task 0 才进 Task 1（per `docs/governance/wave1-plan-template.md`）。

- [x] **局部对抗性评审**（必）：本 plan 子模块 scope（P1 APIClient + Task 0 contract-freeze）内 `codex:adversarial-review`；4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot`）。
- [ ] **集成层评审**（不适用）：P1 非 C8 桥接 / E5 编排所在 PR。
- [ ] **性能评审**（不适用）：P1 非 Phase 5 磨光 PR。

**M0.4 trust-boundary gate（强制，per memory `project_m04_translation_gate`）**：P1 消费 `AppError`，本 PR 必须含
- **Gate 1**：public API 在所有失败路径只抛 `AppError`（runtime test）。
- **Gate 2**：grep 源码确认无私有错误类型（`URLError` / 自定义 `APIError`）跨模块边界泄露。

---

## File Structure

**新建（production）:**
- `ios/Contracts/Sources/KlineTrainerContracts/Network/APIClient.swift` — 协议 `APIClient`（3 async 方法，`throws AppError`，`Sendable`）。
- `ios/Contracts/Sources/KlineTrainerContracts/Network/HTTPRequesting.swift` — 传输缝协议 + `URLSession` 一致性。
- `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAPIClient.swift` — `actor DefaultAPIClient: APIClient` 生产实现。
- `ios/Contracts/Sources/KlineTrainerPersistence/Internal/APIErrorMapping.swift` — `URLError` → `AppError.network` 边界翻译（模块内部 `enum`，对齐 `CacheErrorMapping` 风格）。

**新建（contract / fixtures，repo root）:**
- `tests/contract-fixtures/README.md` — 共享 frozen 契约层说明（P1 Swift + B3 Python 必须读同一套）。
- `tests/contract-fixtures/lease_response_full.json`
- `tests/contract-fixtures/lease_response_partial.json`
- `tests/contract-fixtures/lease_response_empty.json`
- `tests/contract-fixtures/confirm_ok.json`
- `tests/contract-fixtures/error_lease_expired.json`
- `tests/contract-fixtures/error_not_found.json`

**新建（governance / Gate 2，codex R2）:**
- `scripts/check_p1_apperror_gate.sh` — Gate 2 静态核验脚本（同构 `check_p2/p5_apperror_gate.sh`）。
- `tests/scripts/test-check-p1-apperror-gate.sh` — Gate 2 脚本单测（clean PASS / dirty FAIL）。

**新建（test）:**
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/FakeHTTPTransport.swift` — `HTTPRequesting` 测试替身 + 请求捕获 + download 临时文件 URL 记录。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/ContractFixtures.swift` — repo-root `tests/contract-fixtures/` 加载 helper（`#filePath` 向上找 sentinel）。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/APIErrorMappingTests.swift`
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAPIClientTests.swift`

**修改:**
- `backend/openapi.yaml` — meta 库存不足响应描述（partial-200 contract-freeze；替换"deferred to B3"段）。
- `backend/tests/test_openapi.py` — 追加 freeze + 共享 fixture 校验测试。
- `docs/governance/m04-apperror-translation-gate.md` — stub → 权威 gate（删除全部 5 条 `TODO Plan 3 P1`；codex R2 high）。

**设计决策（预答 codex）:**
1. **单 actor 即 NetworkExecutor**：M0.5 §L682 `actor NetworkExecutor` 是 P1-内部 actor 的示意；以 `actor DefaultAPIClient` 单一类型同时提供"协议实现 + 后台可执行 + actor 隔离 + Sendable 边界"，不引入冗余的二级 wrapper（YAGNI / CLAUDE.md §2）。
2. **HTTP 状态码内联映射，无中间 `APIError` 类型**：spec L655 "APIError.httpStatus(N)" 是"HTTP 状态 N"的示意；直接在 actor 内把状态码翻译为 `AppError` 更简单且不泄露私有类型（满足 Gate 2）。`URLError` 翻译抽到 `APIErrorMapping`（对齐既有 `CacheErrorMapping` 风格）。
3. **download 返回临时文件 URL，不做 CRC/MD5**：完整性校验（CRC32 vs `content_hash`）是 P2 DownloadAcceptanceRunner（Wave 2）职责；openapi `Content-MD5` 头是"供客户端二次校验"的可选项，P1 不做（YAGNI，避免与 P2 重复）。P1 仅把 URLSession 自动删除的临时文件移到 P1 拥有的临时位置并返回 URL；后续移动/删除由调用方负责。
4. **empty/partial meta 不是错误，但 count 上界强制（codex R1）**：GET meta 库存不足返回 200 + `sets` 含 0..count 项；P1 原样解码返回，由调用方（P2）决定如何处理少于请求数的 sets。"fail-closed unknown handling" 指：非 200 状态、非 HTTP 响应、200 但 body 解码失败 → 抛错不静默继续。**count 契约双向卡死**：发请求前校验 `count ∈ 1...100`（openapi 上下界），解码后校验 `sets.count <= count`（overfull = 服务端契约违反 → fail-closed），均抛 `.internalError(module:"P1")`。
5. **confirm 200 必须校验 `{ok:true}`（codex R1）**：confirm 200 不等于成功——解码 `ConfirmResponse`，`ok==true` 才返回；解码失败 → `confirm_decode_failed`，`ok==false` → `confirm_not_ok`，均 `.internalError(module:"P1")`，防止把"未真正 sent"误报为确认成功导致下游误删本地状态。
6. **confirm leaseId UUID 校验（codex R2）**：`lease_id` openapi `format=uuid`；非 UUID（如 corrupt journal 行）发请求前 fail-closed → `.internalError(module:"P1", detail:"invalid_lease_id")`，不发出请求，避免 server 返回未文档化 4xx 被误映射为可重试 `serverError`。
7. **协作取消是 AppError-only 唯一例外（codex R2）**：`CancellationError` / `URLError.cancelled` 统一重抛 `CancellationError`（不映射为 AppError），让 P2 区分"主动取消" vs "失败"。已在 m04 gate doc 文档化为唯一例外。
8. **download 失败必清理临时文件（codex R2）**：拿到 `tempURL` 后任何 throw（status / move / 取消）经 `defer` 删除临时文件，防止降级响应撑爆临时存储。
9. **P1 闭合 M0.4 gate（codex R2）**：P1 是首个 public throws 消费 AppError 的 Swift 模块，本 PR 把 `m04-apperror-translation-gate.md` 从 stub 升级为权威 + 落地 Gate 2 脚本 + 删除全部 5 条 `TODO Plan 3 P1`（5 条决策见 Task 5 Step 5）。
10. **共享 fixtures 跨语言**：`tests/contract-fixtures/` 物理单副本；Swift 测试用 `#filePath` 向上找 `tests/contract-fixtures` sentinel 加载，Python 测试用 repo-relative 加载。任一方需偏离 fixture 须先 RFC（per outline §3.1）。

---

## Task 1：Task 0 契约冻结（openapi 空/部分 meta + 共享 contract fixtures）

**Files:**
- Create: `tests/contract-fixtures/lease_response_full.json`
- Create: `tests/contract-fixtures/lease_response_partial.json`
- Create: `tests/contract-fixtures/lease_response_empty.json`
- Create: `tests/contract-fixtures/confirm_ok.json`
- Create: `tests/contract-fixtures/error_lease_expired.json`
- Create: `tests/contract-fixtures/error_not_found.json`
- Create: `tests/contract-fixtures/README.md`
- Modify: `backend/openapi.yaml`（meta `description`）
- Modify: `backend/tests/test_openapi.py`（追加测试）

- [ ] **Step 1: 写共享 fixture JSON（contract 单一真相）**

`tests/contract-fixtures/lease_response_full.json`:
```json
{
  "lease_id": "6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d",
  "expires_at": "2026-05-22T12:34:56Z",
  "sets": [
    {
      "id": 101,
      "stock_code": "600519",
      "stock_name": "贵州茅台",
      "filename": "600519_202001.zip",
      "schema_version": 1,
      "content_hash": "deadbeef"
    },
    {
      "id": 102,
      "stock_code": "000001",
      "stock_name": "平安银行",
      "filename": "000001_202103.zip",
      "schema_version": 1,
      "content_hash": "a0b1c2d3"
    }
  ]
}
```

`tests/contract-fixtures/lease_response_partial.json`（请求 count>1 但库存只够 1）:
```json
{
  "lease_id": "11111111-2222-4333-8444-555566667777",
  "expires_at": "2026-05-22T12:40:00Z",
  "sets": [
    {
      "id": 201,
      "stock_code": "600519",
      "stock_name": "贵州茅台",
      "filename": "600519_201805.zip",
      "schema_version": 1,
      "content_hash": "0f1e2d3c"
    }
  ]
}
```

`tests/contract-fixtures/lease_response_empty.json`（库存为空——partial 边界）:
```json
{
  "lease_id": "00000000-0000-4000-8000-000000000000",
  "expires_at": "2026-05-22T12:45:00Z",
  "sets": []
}
```

`tests/contract-fixtures/confirm_ok.json`:
```json
{ "ok": true }
```

`tests/contract-fixtures/error_lease_expired.json`:
```json
{ "error": "lease_expired" }
```

`tests/contract-fixtures/error_not_found.json`:
```json
{ "error": "not_found" }
```

`tests/contract-fixtures/README.md`:
```markdown
# Contract fixtures（P1 / B3 共享 frozen 契约层）

这些 JSON 是 `backend/openapi.yaml` 契约的 canonical 实例，作 Wave 1 跨语言契约
drift 缓解（per Wave 1 outline §3.1）：

- **P1 APIClient**（Swift，顺位 2）：`DefaultAPIClientTests` 解码这些 fixture 进 M0.3 DTO。
- **B3 FastAPI lease**（Python，顺位 18）：`test_openapi.py` / B3 实现测试断言这些 fixture。

任一方不得 fork 本地 mock / schema；需偏离 fixture 必须先开独立 governance RFC PR 修
fixture（per outline §3.1）。

## contract-freeze：GET /training-sets/meta 库存不足行为

unsent < count 时服务端返回 **200 LeaseResponse**，`sets` 含 0..count 项（partial
fulfillment，从不为库存不足返回错误码）。`lease_response_empty.json` / `_partial.json`
是该冻结的 canonical 实例。
```

- [ ] **Step 2: 写 Python 失败测试（先红）**

追加到 `backend/tests/test_openapi.py` 末尾：
```python
import json
import re

CONTRACT_FIXTURES_DIR = (
    Path(__file__).parent.parent.parent / "tests" / "contract-fixtures"
)


def _load_fixture(name: str) -> dict:
    with (CONTRACT_FIXTURES_DIR / f"{name}.json").open("r", encoding="utf-8") as f:
        return json.load(f)


def _assert_matches_lease_response(spec: dict, instance: dict) -> None:
    lr = spec["components"]["schemas"]["LeaseResponse"]
    for req in lr["required"]:
        assert req in instance, f"LeaseResponse missing required field {req}"
    item = spec["components"]["schemas"]["TrainingSetMetaItem"]
    pattern = item["properties"]["content_hash"]["pattern"]
    assert isinstance(instance["sets"], list)
    for s in instance["sets"]:
        for req in item["required"]:
            assert req in s, f"TrainingSetMetaItem missing required field {req}"
        assert re.fullmatch(pattern, s["content_hash"]), s["content_hash"]


def test_meta_sets_allows_empty_array():
    """contract-freeze: LeaseResponse.sets 无 minItems → 空数组合法（partial-200）。"""
    spec = _load_spec()
    sets_schema = spec["components"]["schemas"]["LeaseResponse"]["properties"]["sets"]
    assert "minItems" not in sets_schema


def test_meta_description_freezes_partial_behavior():
    """meta description 必须冻结库存不足 = partial-200（不再 defer 到 B3）。"""
    spec = _load_spec()
    desc = spec["paths"]["/training-sets/meta"]["get"]["description"]
    assert "partial" in desc.lower()
    assert "未在本契约冻结" not in desc


def test_full_lease_fixture_matches_schema():
    _assert_matches_lease_response(_load_spec(), _load_fixture("lease_response_full"))


def test_partial_lease_fixture_matches_schema():
    inst = _load_fixture("lease_response_partial")
    assert len(inst["sets"]) >= 1
    _assert_matches_lease_response(_load_spec(), inst)


def test_empty_lease_fixture_matches_schema():
    inst = _load_fixture("lease_response_empty")
    assert inst["sets"] == []
    _assert_matches_lease_response(_load_spec(), inst)


def test_error_fixtures_match_error_enum():
    spec = _load_spec()
    allowed = set(spec["components"]["schemas"]["ErrorResponse"]["properties"]["error"]["enum"])
    assert _load_fixture("error_lease_expired")["error"] in allowed
    assert _load_fixture("error_not_found")["error"] in allowed


def test_confirm_ok_fixture_shape():
    assert _load_fixture("confirm_ok") == {"ok": True}


def test_download_documents_404_not_found():
    """codex R5：download 404（id 不存在/journal 损坏）须在契约文档化（P1 映射 terminal fileNotFound）。"""
    spec = _load_spec()
    responses = spec["paths"]["/training-set/{id}/download"]["get"]["responses"]
    assert "404" in responses
```

- [ ] **Step 3: 运行测试确认失败**

Run: `cd backend && python -m pytest tests/test_openapi.py -q`
Expected: `test_meta_description_freezes_partial_behavior` FAIL（当前 description 含"未在本契约冻结"且无 "partial"）。其余 fixture 测试 PASS（fixtures 已建、schema 兼容）。

- [ ] **Step 4: 修改 openapi.yaml meta description（冻结 partial-200）**

在 `backend/openapi.yaml` 把 `/training-sets/meta` 的 `get.description` 中"库存不足行为未在本契约冻结..."整段（现 L29-33）替换为：
```yaml
        **库存不足行为（contract-freeze，Wave 1 顺位 2 Task 0）**：unsent 行数 < count
        时，服务端返回 **200 LeaseResponse**，sets 含 0..count 项（partial fulfillment，
        从不为库存不足返回错误码）。count 是上界而非保证；客户端 P1 按返回的实际 sets 数
        处理，空 sets（[]）是合法响应。B4 调度器每日 05:00 补足 unsent 至 100 使 partial
        触发概率极低。B3 FastAPI（顺位 18）实现必须遵循本冻结契约，与
        tests/contract-fixtures/lease_response_{empty,partial,full}.json 一致。
```
（保留该 `description` 块前面"已知 REST 非幂等"等既有段落不变；仅替换"库存不足"那一段。）

再在 `backend/openapi.yaml` 的 `/training-set/{id}/download` `get.responses` 下，于 `'200'` 之后补 `'404'`（codex R5：id 不存在/journal 损坏 → terminal，P1 映射 `.trainingSet(.fileNotFound)`）：
```yaml
        '404':
          description: training set 不存在（terminal，客户端不应重试该 id）
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/ErrorResponse'
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd backend && python -m pytest tests/test_openapi.py -q`
Expected: 全部 PASS（含既有 11 测试 + 新增 8 测试）。

- [ ] **Step 6: 提交**

```bash
git add tests/contract-fixtures backend/openapi.yaml backend/tests/test_openapi.py
git commit -m "feat(p1): Task 0 contract-freeze — meta partial-200 + 共享 contract fixtures"
```

---

## Task 2：网络传输缝 `HTTPRequesting` + 协议 `APIClient`

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Network/HTTPRequesting.swift`
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Network/APIClient.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/FakeHTTPTransport.swift`

- [ ] **Step 1: 写 `HTTPRequesting` 协议 + `URLSession` 一致性**

`Network/HTTPRequesting.swift`:
```swift
// P1 网络传输缝：抽象 URLSession 的 data/download，测试可注入 fake。
// URLSession 原生满足（iOS 15+ / macOS 12+），空 extension 即可。

import Foundation

public protocol HTTPRequesting: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension URLSession: HTTPRequesting {}
```

- [ ] **Step 2: 写协议 `APIClient`**

`Network/APIClient.swift`:
```swift
// P1 APIClient 契约 — 训练组 lease 预占-下载-确认（对接 backend/openapi.yaml）。
// M0.4 §L655：所有方法 throws AppError；M0.5 §L711：返回值 Sendable。

import Foundation

public protocol APIClient: Sendable {
    /// GET /training-sets/meta?count=N — 批量预占。
    /// 返回 LeaseResponse；sets 含 0..count 项（partial 是合法 200，不抛错——
    /// contract-freeze 见 backend/openapi.yaml + tests/contract-fixtures/）。
    func reserveTrainingSets(count: Int) async throws -> LeaseResponse

    /// GET /training-set/{id}/download — 下载 zip 到本地临时文件，返回其 URL。
    /// CRC/MD5 完整性校验不在 P1 scope（P2 DownloadAcceptanceRunner 负责）。
    /// 调用方负责后续移动/删除返回的临时文件。
    func downloadTrainingSet(id: Int) async throws -> URL

    /// POST /training-set/{id}/confirm?lease_id=X — 确认下载；幂等（重复 200）。
    func confirmTrainingSet(id: Int, leaseId: String) async throws
}
```

- [ ] **Step 3: 写 `FakeHTTPTransport` 测试替身**

`Tests/KlineTrainerPersistenceTests/FakeHTTPTransport.swift`:
```swift
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
        lock.lock(); defer { lock.unlock() }; return _captured
    }
    /// download 最近一次创建的临时文件 URL（测试断言失败路径已清理）。
    var lastDownloadTempURL: URL? {
        lock.lock(); defer { lock.unlock() }; return _lastDownloadTempURL
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
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "fake-dl-\(UUID().uuidString).zip")
        try (stub.downloadFileContents ?? Data()).write(to: tmp)
        lock.lock(); _lastDownloadTempURL = tmp; lock.unlock()
        return (tmp, response(for: request.url!))
    }

    private func record(_ r: URLRequest) {
        lock.lock(); defer { lock.unlock() }; _captured.append(r)
    }

    private func response(for url: URL) -> URLResponse {
        if stub.returnNonHTTPResponse {
            return URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        }
        return HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: nil, headerFields: nil)!
    }
}
```

- [ ] **Step 4: 运行 build 确认编译**

Run: `cd ios/Contracts && swift build 2>&1 | tail -5`
Expected: `Build complete!`，0 error 0 warning（协议无行为、`FakeHTTPTransport` 仅供测试 target）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Network ios/Contracts/Tests/KlineTrainerPersistenceTests/FakeHTTPTransport.swift
git commit -m "feat(p1): HTTPRequesting 传输缝 + APIClient 协议 + FakeHTTPTransport 替身"
```

---

## Task 3：`APIErrorMapping`（URLError → AppError 边界翻译）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/APIErrorMapping.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/APIErrorMappingTests.swift`

- [ ] **Step 1: 写失败测试（先红）**

`APIErrorMappingTests.swift`:
```swift
import XCTest
@testable import KlineTrainerPersistence
import KlineTrainerContracts

final class APIErrorMappingTests: XCTestCase {
    func test_timeout_maps_to_network_timeout() {
        let err = APIErrorMapping.translate(URLError(.timedOut))
        XCTAssertEqual(err, .network(.timeout))
    }

    func test_not_connected_maps_to_offline() {
        XCTAssertEqual(APIErrorMapping.translate(URLError(.notConnectedToInternet)), .network(.offline))
        XCTAssertEqual(APIErrorMapping.translate(URLError(.networkConnectionLost)), .network(.offline))
        XCTAssertEqual(APIErrorMapping.translate(URLError(.cannotConnectToHost)), .network(.offline))
    }

    func test_other_urlerror_maps_to_offline_conservative() {
        // NetworkReason 词汇内无 "unknown"；其它传输层 URLError 归 offline（可重试）。
        XCTAssertEqual(APIErrorMapping.translate(URLError(.badServerResponse)), .network(.offline))
    }

    func test_passthrough_existing_apperror() {
        let original = AppError.network(.leaseExpired)
        XCTAssertEqual(APIErrorMapping.translate(original), original)
    }

    func test_non_urlerror_maps_to_internalError_p1() {
        struct Weird: Error {}
        let err = APIErrorMapping.translate(Weird())
        guard case .internalError(let module, _) = err else {
            return XCTFail("expected internalError, got \(err)")
        }
        XCTAssertEqual(module, "P1")
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter APIErrorMappingTests 2>&1 | tail -5`
Expected: 编译失败（`APIErrorMapping` 未定义）。

- [ ] **Step 3: 实现 `APIErrorMapping`**

`Internal/APIErrorMapping.swift`:
```swift
import Foundation
import KlineTrainerContracts

/// URLError → AppError.network 边界翻译（仅 KlineTrainerPersistence 模块内部使用；
/// 对齐 CacheErrorMapping 风格）。HTTP 状态码映射在 DefaultAPIClient 内联
/// （依赖具体 endpoint 语义，见各方法）。
enum APIErrorMapping {
    static func translate(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .timedOut:
                return .network(.timeout)
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dataNotAllowed, .internationalRoamingOff:
                return .network(.offline)
            default:
                // NetworkReason 词汇内无 unknown 类目（M0.4 L655）；其它传输层
                // URLError（badServerResponse / cannotParseResponse 等）保守归
                // offline（传输失败、isRecoverable=true，可重试）。
                return .network(.offline)
            }
        }
        // 非 URLError 的传输层异常（罕见）→ fail-closed 标 P1。
        return .internalError(module: "P1", detail: "transport_error")
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter APIErrorMappingTests 2>&1 | tail -5`
Expected: 5 测试全 PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/APIErrorMapping.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/APIErrorMappingTests.swift
git commit -m "feat(p1): APIErrorMapping URLError→AppError 边界翻译 + 5 tests"
```

---

## Task 4：`DefaultAPIClient` actor 实现 + 综合测试（含 Gate 1 + 共享 fixture）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/DefaultAPIClient.swift`
- Create: `ios/Contracts/Tests/KlineTrainerPersistenceTests/ContractFixtures.swift`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAPIClientTests.swift`

- [ ] **Step 1: 写 contract-fixture 加载 helper**

`ContractFixtures.swift`:
```swift
import Foundation

/// 加载 repo-root tests/contract-fixtures/<name>.json（P1↔B3 共享契约层）。
/// 用 #filePath 向上找含 tests/contract-fixtures 的目录作 repo root，
/// 对目录重构鲁棒（不硬编码层级深度）。
enum ContractFixtures {
    static func data(_ name: String) throws -> Data {
        let url = repoRoot().appending(path: "tests/contract-fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private static func repoRoot() -> URL {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir.appending(path: "tests/contract-fixtures").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            precondition(parent != dir, "tests/contract-fixtures not found above \(#filePath)")
            dir = parent
        }
    }
}
```

- [ ] **Step 2: 写 `DefaultAPIClient` 失败测试（先红）**

`DefaultAPIClientTests.swift`:
```swift
import XCTest
@testable import KlineTrainerPersistence
import KlineTrainerContracts

final class DefaultAPIClientTests: XCTestCase {
    private let base = URL(string: "http://nas.local:8000")!
    private let validLease = "6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d"  // openapi format=uuid

    private func client(_ stub: FakeHTTPTransport.Stub) -> (DefaultAPIClient, FakeHTTPTransport) {
        let fake = FakeHTTPTransport(stub: stub)
        return (DefaultAPIClient(baseURL: base, transport: fake), fake)
    }

    // MARK: reserveTrainingSets

    func test_reserve_full_decodes_lease_response() async throws {
        let body = try ContractFixtures.data("lease_response_full")
        let (api, fake) = client(.init(body: body, statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 2)
        XCTAssertEqual(lease.sets.count, 2)
        XCTAssertEqual(lease.sets[0].stockCode, "600519")
        XCTAssertEqual(lease.sets[0].contentHash, "deadbeef")
        // 请求 URL：GET /training-sets/meta?count=2
        let req = fake.capturedRequests.first!
        XCTAssertEqual(req.url?.path(), "/training-sets/meta")
        XCTAssertTrue(req.url?.query()?.contains("count=2") == true)
    }

    func test_reserve_empty_returns_empty_sets_no_throw() async throws {
        let body = try ContractFixtures.data("lease_response_empty")
        let (api, _) = client(.init(body: body, statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 5)
        XCTAssertEqual(lease.sets.count, 0)  // partial-200 contract-freeze
    }

    func test_reserve_partial_returns_fewer_than_requested() async throws {
        let body = try ContractFixtures.data("lease_response_partial")
        let (api, _) = client(.init(body: body, statusCode: 200))
        let lease = try await api.reserveTrainingSets(count: 3)
        XCTAssertEqual(lease.sets.count, 1)
    }

    // codex R1 medium：count 必须先于 side-effecting 请求按 openapi 1...100 校验。
    func test_reserve_invalid_count_throws_without_issuing_request() async {
        for bad in [0, -1, 101] {
            let (api, fake) = client(.init(body: Data(), statusCode: 200))
            do {
                _ = try await api.reserveTrainingSets(count: bad)
                XCTFail("count=\(bad) should throw")
            } catch let err as AppError {
                guard case .internalError(let module, _) = err else {
                    return XCTFail("count=\(bad): expected internalError, got \(err)")
                }
                XCTAssertEqual(module, "P1")
            } catch { XCTFail("count=\(bad): non-AppError: \(error)") }
            XCTAssertTrue(fake.capturedRequests.isEmpty, "count=\(bad) must not issue side-effecting reserve")
        }
    }

    // codex R1 medium：server 返回多于 count 的 sets（契约违反）→ fail-closed。
    func test_reserve_overfull_response_throws_internalError() async {
        let body = try! ContractFixtures.data("lease_response_full")  // 2 sets
        let (api, _) = client(.init(body: body, statusCode: 200))
        do {
            _ = try await api.reserveTrainingSets(count: 1)  // 请求 1，返回 2 → 违反
            XCTFail("overfull response should throw")
        } catch let err as AppError {
            guard case .internalError(let module, _) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
        } catch { XCTFail("non-AppError: \(error)") }
    }

    func test_reserve_malformed_body_throws_internalError_p1() async {
        let (api, _) = client(.init(body: Data("{not json".utf8), statusCode: 200))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("expected throw")
        } catch let err as AppError {
            guard case .internalError(let module, _) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
        } catch { XCTFail("non-AppError: \(error)") }
    }

    func test_reserve_http_500_throws_serverError() async {
        let (api, _) = client(.init(body: Data(), statusCode: 500))
        await assertThrowsAppError(.network(.serverError(code: 500))) {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_timeout_throws_network_timeout() async {
        let (api, _) = client(.init(error: URLError(.timedOut)))
        await assertThrowsAppError(.network(.timeout)) {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_offline_throws_network_offline() async {
        let (api, _) = client(.init(error: URLError(.notConnectedToInternet)))
        await assertThrowsAppError(.network(.offline)) {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_non_http_response_throws_internalError() async {
        let body = try! ContractFixtures.data("lease_response_full")
        let (api, _) = client(.init(body: body, statusCode: 200, returnNonHTTPResponse: true))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("expected throw")
        } catch let err as AppError {
            guard case .internalError = err else { return XCTFail("expected internalError, got \(err)") }
        } catch { XCTFail("non-AppError: \(error)") }
    }

    // MARK: confirmTrainingSet

    func test_confirm_200_succeeds_and_builds_url() async throws {
        let (api, fake) = client(.init(body: try ContractFixtures.data("confirm_ok"), statusCode: 200))
        try await api.confirmTrainingSet(id: 42, leaseId: validLease)
        let req = fake.capturedRequests.first!
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path(), "/training-set/42/confirm")
        XCTAssertTrue(req.url?.query()?.contains("lease_id=\(validLease)") == true)
    }

    func test_confirm_idempotent_repeat_200() async throws {
        let (api, _) = client(.init(body: try ContractFixtures.data("confirm_ok"), statusCode: 200))
        try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        try await api.confirmTrainingSet(id: 1, leaseId: validLease)  // 重复仍成功（body 均 {ok:true}）
    }

    // codex R2 high：非 UUID leaseId 必须在发请求前 fail-closed，不发出确认请求。
    func test_confirm_invalid_lease_id_throws_without_request() async {
        let (api, fake) = client(.init(body: Data(), statusCode: 200))
        do {
            try await api.confirmTrainingSet(id: 1, leaseId: "not-a-uuid")
            XCTFail("invalid leaseId should throw")
        } catch let err as AppError {
            guard case .internalError(let module, _) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
        } catch { XCTFail("non-AppError: \(error)") }
        XCTAssertTrue(fake.capturedRequests.isEmpty, "invalid leaseId must not issue confirm")
    }

    // codex R1 high：confirm 200 必须校验 body {ok:true}，否则 fail-closed。
    // codex R3 high：必须用 validLease，否则 UUID guard 在解码前短路 → 测错分支（false positive）。
    func test_confirm_200_malformed_body_throws_decode_failed() async {
        let (api, fake) = client(.init(body: Data("{not json".utf8), statusCode: 200))
        do {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
            XCTFail("malformed 200 body should throw")
        } catch let err as AppError {
            guard case .internalError(let module, let detail) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
            XCTAssertEqual(detail, "confirm_decode_failed")  // 证明走到了解码分支
        } catch { XCTFail("non-AppError: \(error)") }
        XCTAssertEqual(fake.capturedRequests.count, 1)  // 确实发了 POST（非 UUID-guard 短路）
    }

    func test_confirm_200_ok_false_throws_not_ok() async {
        let (api, fake) = client(.init(body: Data(#"{"ok":false}"#.utf8), statusCode: 200))
        do {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
            XCTFail("{ok:false} should throw")
        } catch let err as AppError {
            guard case .internalError(let module, let detail) = err else {
                return XCTFail("expected internalError, got \(err)")
            }
            XCTAssertEqual(module, "P1")
            XCTAssertEqual(detail, "confirm_not_ok")  // 证明走到了 ok==false 分支
        } catch { XCTFail("non-AppError: \(error)") }
        XCTAssertEqual(fake.capturedRequests.count, 1)
    }

    func test_confirm_409_throws_leaseExpired() async {
        let (api, _) = client(.init(body: try! ContractFixtures.data("error_lease_expired"), statusCode: 409))
        await assertThrowsAppError(.network(.leaseExpired)) {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    func test_confirm_404_throws_leaseNotFound() async {
        let (api, _) = client(.init(body: try! ContractFixtures.data("error_not_found"), statusCode: 404))
        await assertThrowsAppError(.network(.leaseNotFound)) {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    func test_confirm_500_throws_serverError() async {
        let (api, _) = client(.init(body: Data(), statusCode: 500))
        await assertThrowsAppError(.network(.serverError(code: 500))) {
            try await api.confirmTrainingSet(id: 1, leaseId: validLease)
        }
    }

    // MARK: downloadTrainingSet

    func test_download_200_returns_file_with_contents() async throws {
        let payload = Data("PK\u{03}\u{04}fakezip".utf8)
        let (api, fake) = client(.init(statusCode: 200, downloadFileContents: payload))
        let url = try await api.downloadTrainingSet(id: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(fake.capturedRequests.first?.url?.path(), "/training-set/7/download")
        try? FileManager.default.removeItem(at: url)
    }

    // codex R5 medium：download 404 = terminal（id 不存在/journal 损坏），不可重试。
    func test_download_404_throws_fileNotFound_terminal() async {
        let (api, _) = client(.init(statusCode: 404))
        await assertThrowsAppError(.trainingSet(.fileNotFound)) {
            _ = try await api.downloadTrainingSet(id: 7)
        }
        XCTAssertFalse(AppError.trainingSet(.fileNotFound).isRecoverable)  // terminal，不重试
    }

    func test_download_500_throws_serverError() async {
        let (api, _) = client(.init(statusCode: 500))
        await assertThrowsAppError(.network(.serverError(code: 500))) {
            _ = try await api.downloadTrainingSet(id: 7)
        }
    }

    func test_download_offline_throws_network_offline() async {
        let (api, _) = client(.init(error: URLError(.networkConnectionLost)))
        await assertThrowsAppError(.network(.offline)) {
            _ = try await api.downloadTrainingSet(id: 7)
        }
    }

    // codex R2 medium：非 200 下载已写入临时文件，throw 前必须清理（不泄露）。
    func test_download_non200_cleans_temp_file() async {
        let (api, fake) = client(.init(statusCode: 500, downloadFileContents: Data("garbage".utf8)))
        do {
            _ = try await api.downloadTrainingSet(id: 7)
            XCTFail("500 download should throw")
        } catch {}
        let temp = fake.lastDownloadTempURL
        XCTAssertNotNil(temp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp!.path), "temp file must be cleaned on failure")
    }

    // MARK: cancellation（codex R2：协作取消重抛 CancellationError，非 AppError）

    func test_reserve_cancellationError_rethrows_as_cancellation() async {
        let (api, _) = client(.init(error: CancellationError()))
        do {
            _ = try await api.reserveTrainingSets(count: 1)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // 期望路径
        } catch { XCTFail("expected CancellationError, got \(error)") }
    }

    func test_download_urlerror_cancelled_rethrows_as_cancellation() async {
        let (api, fake) = client(.init(error: URLError(.cancelled)))
        do {
            _ = try await api.downloadTrainingSet(id: 7)
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // 期望路径
        } catch { XCTFail("expected CancellationError, got \(error)") }
        XCTAssertNil(fake.lastDownloadTempURL, "cancel before file write → 无临时文件")
    }

    // MARK: meta 字段契约校验（codex R4：DTO 是 plain String，需在边界补回 openapi format/pattern）

    func test_reserve_invalid_lease_id_in_meta_throws() async {
        let bad = #"{"lease_id":"not-a-uuid","expires_at":"2026-05-22T12:00:00Z","sets":[]}"#
        let (api, _) = client(.init(body: Data(bad.utf8), statusCode: 200))
        await assertInternalErrorP1(detail: "meta_invalid_lease_id") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_invalid_expires_at_throws() async {
        let bad = #"{"lease_id":"6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d","expires_at":"not-a-date","sets":[]}"#
        let (api, _) = client(.init(body: Data(bad.utf8), statusCode: 200))
        await assertInternalErrorP1(detail: "meta_invalid_expires_at") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    func test_reserve_invalid_content_hash_throws() async {
        let bad = #"""
        {"lease_id":"6f8a9c1d-2b3e-4f50-8a12-7d9e0f1b2c3d","expires_at":"2026-05-22T12:00:00Z","sets":[{"id":1,"stock_code":"600519","stock_name":"x","filename":"a.zip","schema_version":1,"content_hash":"ZZZZ"}]}
        """#
        let (api, _) = client(.init(body: Data(bad.utf8), statusCode: 200))
        await assertInternalErrorP1(detail: "meta_invalid_content_hash") {
            _ = try await api.reserveTrainingSets(count: 1)
        }
    }

    // MARK: - helper（Gate 1：断言只抛指定 AppError）
    private func assertThrowsAppError(
        _ expected: AppError, _ op: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await op()
            XCTFail("expected throw \(expected)", file: file, line: line)
        } catch let err as AppError {
            XCTAssertEqual(err, expected, file: file, line: line)
        } catch {
            XCTFail("non-AppError thrown: \(error)", file: file, line: line)
        }
    }

    /// 断言抛 .internalError(module:"P1", detail:<expected>)。
    private func assertInternalErrorP1(
        detail expected: String, _ op: () async throws -> Void,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await op()
            XCTFail("expected internalError \(expected)", file: file, line: line)
        } catch let err as AppError {
            guard case .internalError(let module, let detail) = err else {
                return XCTFail("expected internalError, got \(err)", file: file, line: line)
            }
            XCTAssertEqual(module, "P1", file: file, line: line)
            XCTAssertEqual(detail, expected, file: file, line: line)
        } catch {
            XCTFail("non-AppError thrown: \(error)", file: file, line: line)
        }
    }
}
```

- [ ] **Step 3: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter DefaultAPIClientTests 2>&1 | tail -5`
Expected: 编译失败（`DefaultAPIClient` 未定义）。

- [ ] **Step 4: 实现 `DefaultAPIClient`**

`DefaultAPIClient.swift`:
```swift
import Foundation
import KlineTrainerContracts

/// P1 APIClient 生产实现。担任 M0.5 §L682 "NetworkExecutor" 内部 actor 角色：
/// 单一类型即提供协议实现 + 后台可执行 + actor 隔离 + Sendable 边界。
/// 所有失败在本 actor 边界内翻译为 AppError（M0.4 trust-boundary gate）。
public actor DefaultAPIClient: APIClient {
    private let baseURL: URL
    private let transport: HTTPRequesting
    private let decoder: JSONDecoder
    private let iso8601: ISO8601DateFormatter  // actor-isolated；Formatter 非线程安全，作实例属性

    public init(baseURL: URL, transport: HTTPRequesting = URLSession.shared) {
        self.baseURL = baseURL
        self.transport = transport
        self.decoder = JSONDecoder()
        self.iso8601 = ISO8601DateFormatter()
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
        default:   throw AppError.network(.serverError(code: http.statusCode))
        }
    }

    /// confirm 200 响应体（openapi `{ ok: boolean }`）；仅内部解码用。
    private struct ConfirmResponse: Decodable { let ok: Bool }

    // MARK: - IO helpers（codex R5：raw 危险 try 全封在此区，public 方法体零 raw try——对齐 P5 gate 规则 2）

    /// transport.data + 错误翻译。
    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        try await perform { try await transport.data(for: req) }
    }

    /// transport.download + 错误翻译。
    private func sendDownload(_ req: URLRequest) async throws -> (URL, URLResponse) {
        try await perform { try await transport.download(for: req) }
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

    /// 把传输层抛出的 URLError / 其它 error 翻译为 AppError；已是 AppError 则透传。
    /// codex R2：协作取消（CancellationError / URLError.cancelled）统一重抛 CancellationError
    /// （AppError-only gate 唯一例外），让调用方区分"主动取消" vs "失败"。
    /// codex R3：catch-all 用 `(error as? AppError) ?? translate(...)` 单表达式，无 bare-variable 旁路。
    private func perform<T>(_ op: () async throws -> T) async throws -> T {
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

    /// meta 状态校验：== expected 否则 fail-closed 抛 serverError；非 HTTP 抛 internalError。
    private func requireStatus(_ response: URLResponse, _ expected: Int) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppError.internalError(module: "P1", detail: "non_http_response")
        }
        guard http.statusCode == expected else {
            throw AppError.network(.serverError(code: http.statusCode))
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
        default:   throw AppError.network(.serverError(code: http.statusCode))
        }
    }

    /// codex R4 high：LeaseResponse DTO 是 plain String，补回 openapi format/pattern 契约。
    private func validateMetaContract(_ lease: LeaseResponse) throws {
        guard UUID(uuidString: lease.leaseId) != nil else {
            throw AppError.internalError(module: "P1", detail: "meta_invalid_lease_id")
        }
        guard iso8601.date(from: lease.expiresAt) != nil else {
            throw AppError.internalError(module: "P1", detail: "meta_invalid_expires_at")
        }
        for s in lease.sets
        where s.contentHash.range(of: "^[0-9a-f]{8}$", options: .regularExpression) == nil {
            throw AppError.internalError(module: "P1", detail: "meta_invalid_content_hash")
        }
    }
}
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter DefaultAPIClientTests 2>&1 | tail -5`
Expected: 28 测试全 PASS（14 reserve + 8 confirm + 6 download；含 codex R1 invalid-count/overfull/confirm-body + R2 invalid-leaseId/cancellation×2/download-cleanup + R4 meta-field 校验 + R5 download-404-terminal）。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/DefaultAPIClient.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/ContractFixtures.swift ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultAPIClientTests.swift
git commit -m "feat(p1): DefaultAPIClient actor（3 方法 lease 状态机）+ 28 tests（Gate 1 + 共享 fixture + count/leaseId/confirm-body/cancellation/download-cleanup/meta-field/404-terminal fail-closed）"
```

---

## Task 5：M0.4 trust-boundary gate 闭合 + Gate 2 脚本（codex R2 high）

> P1 是 spec 指定的"首个 public throws 消费 AppError 的 Swift 模块"，必须把
> `docs/governance/m04-apperror-translation-gate.md` 从 stub 升级为权威 gate（删除全部 5 条
> `TODO Plan 3 P1`），并落地 Gate 2 脚本（与既有 `check_p2/p5_apperror_gate.sh` 同构）。

**Files:**
- Create: `scripts/check_p1_apperror_gate.sh`
- Create: `tests/scripts/test-check-p1-apperror-gate.sh`
- Modify: `docs/governance/m04-apperror-translation-gate.md`

- [ ] **Step 1: 写 Gate 2 脚本单测（先红）**

`tests/scripts/test-check-p1-apperror-gate.sh`:
```bash
#!/usr/bin/env bash
# 单测 check_p1_apperror_gate.sh：clean 文件 PASS；含裸非-AppError throw 文件 FAIL。
set -euo pipefail
cd "$(dirname "$0")/../.."
GATE="scripts/check_p1_apperror_gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# case 1: 干净文件（AppError + CancellationError + *ErrorMapping.translate + 注释行 throw）→ PASS
cat > "$TMP/clean.swift" <<'EOF'
func a() throws { throw AppError.network(.timeout) }
func b() throws { throw CancellationError() }
func c() throws { throw APIErrorMapping.translate(err) }
// throw NSError() —— 注释行不算
EOF
if bash "$GATE" "$TMP/clean.swift" >/dev/null; then echo "PASS clean"; else echo "FAIL: clean 应 PASS"; exit 1; fi

# case 2: 含裸 throw URLError → FAIL
cat > "$TMP/dirty.swift" <<'EOF'
func d() throws { throw URLError(.timedOut) }
EOF
if bash "$GATE" "$TMP/dirty.swift" >/dev/null 2>&1; then echo "FAIL: dirty 应 FAIL"; exit 1; else echo "PASS dirty"; fi

# case 3（codex R3）: bare-variable 旁路——appErr 实为 URLError → 必须 FAIL
cat > "$TMP/bypass.swift" <<'EOF'
func e() throws {
    let appErr = URLError(.timedOut)
    throw appErr
}
EOF
if bash "$GATE" "$TMP/bypass.swift" >/dev/null 2>&1; then echo "FAIL: bare-variable 旁路应 FAIL"; exit 1; else echo "PASS bypass"; fi

# case 4（codex R4）: 行内注释旁路——throw error // AppError → 必须 FAIL
cat > "$TMP/inline.swift" <<'EOF'
func f() throws { throw error // AppError
}
EOF
if bash "$GATE" "$TMP/inline.swift" >/dev/null 2>&1; then echo "FAIL: 行内注释旁路应 FAIL"; exit 1; else echo "PASS inline"; fi

# case 5（codex R5）: public 方法体内 raw try 泄漏（无 throw 行也能漏 DecodingError）→ 必须 FAIL
cat > "$TMP/rawtry.swift" <<'EOF'
public func g() throws -> Int {
    return try JSONDecoder().decode(Int.self, from: Data())
}
EOF
if bash "$GATE" "$TMP/rawtry.swift" >/dev/null 2>&1; then echo "FAIL: raw-try 泄漏应 FAIL"; exit 1; else echo "PASS rawtry"; fi

echo "ALL PASS"
```

- [ ] **Step 2: 运行确认失败**

Run: `bash tests/scripts/test-check-p1-apperror-gate.sh`
Expected: 失败（`check_p1_apperror_gate.sh` 未创建）。

- [ ] **Step 3: 实现 Gate 2 脚本**

`scripts/check_p1_apperror_gate.sh`:
```bash
#!/usr/bin/env bash
# Plan 3 P1 边界翻译 Gate 2（per docs/governance/m04-apperror-translation-gate.md；对齐 check_p5_apperror_gate.sh 3 规则）。
# 规则1：所有 throw 走 AppError 边界（token：AppError / *ErrorMapping.translate / CancellationError；剥行内注释封 codex R4 旁路；无 bare-variable token 封 codex R3 旁路）。
# 规则2（codex R5）：public 方法体内禁 raw 危险 try（transport/decoder/JSONDecoder/FileManager/.decode/.write）——必须走 private helper，否则 raw try 让 DecodingError/URLError 无 throw 行直接逃逸。
# 规则3：含 raw 危险 try 的行 ±10 行内必有 perform / *ErrorMapping.translate / AppError（证明翻译就近发生）。
# 已知局限（同 P2/P5 grep gate）：多行 throw / 字符串内 `//` 不处理；本仓单行 throw 风格不触发。SwiftSyntax 当前 toolchain 无（YAGNI）。
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
    TARGETS=("$@")
else
    ROOT="ios/Contracts/Sources/KlineTrainerPersistence"
    TARGETS=("$ROOT/DefaultAPIClient.swift" "$ROOT/Internal/APIErrorMapping.swift")
fi

# 危险 raw try：调用会抛非-AppError（transport/decoder/JSONDecoder/FileManager/任意 .decode/.write）。
# 注意 `try?`（带 ?）不匹配——它不抛，安全。
DANGER='try (await )?(transport|decoder|JSONDecoder|FileManager)[.(]|try [A-Za-z0-9_.]+\.(decode|write)\('

FAIL=0
for f in "${TARGETS[@]}"; do
    if [[ ! -f "$f" ]]; then echo "MISS: $f"; FAIL=1; continue; fi

    # === 规则1：throw 走 AppError ===
    while IFS= read -r line; do
        code="${line%%//*}"   # 剥行内注释
        echo "$code" | grep -qE "(AppError|[A-Za-z]*ErrorMapping\.translate|CancellationError)" && continue
        echo "FAIL[规则1]: $f 非 AppError throw -> $line"; FAIL=1
    done < <(grep -vE "^[[:space:]]*//" "$f" | grep -nE "^[[:space:]]*throw[[:space:]]")

    # === 规则2：public 方法体内禁 raw 危险 try ===
    PUBLIC_BAD=$(awk -v danger="$DANGER" '
        /^[[:space:]]*public (func|init)/ { in_pub=1 }
        in_pub==1 {
            n=gsub(/{/,"{"); m=gsub(/}/,"}"); depth += n - m
            l=$0; sub(/\/\/.*/,"",l)
            if (l ~ danger) print FILENAME ":" NR ": " $0
            if (depth<=0 && (n>0 || m>0)) { in_pub=0; depth=0 }
        }
    ' "$f")
    if [[ -n "$PUBLIC_BAD" ]]; then
        echo "FAIL[规则2]: $f public 方法体内 raw 危险 try（应走 private helper）："; echo "$PUBLIC_BAD"; FAIL=1
    fi

    # === 规则3：raw 危险 try 行 ±10 行内有翻译 ===
    while IFS= read -r ln; do
        ln="${ln%%:*}"
        start=$(( ln>10 ? ln-10 : 1 )); end=$(( ln+10 ))
        if ! sed -n "${start},${end}p" "$f" | grep -qE "perform|[A-Za-z]*ErrorMapping\.translate|AppError"; then
            echo "FAIL[规则3]: $f 行 $ln raw try 附近 ±10 行无 AppError 翻译"; FAIL=1
        fi
    done < <(grep -vE "^[[:space:]]*//" "$f" | grep -nE "$DANGER")
done

if [[ $FAIL -eq 0 ]]; then
    echo "OK: P1 边界全 throw 走 AppError + public 方法零 raw 危险 try"
fi
exit $FAIL
```

- [ ] **Step 4: 运行测试确认通过**

Run: `chmod +x scripts/check_p1_apperror_gate.sh && bash tests/scripts/test-check-p1-apperror-gate.sh`
Expected: `ALL PASS`。

- [ ] **Step 5: 升级 m04 gate doc（stub → 权威，删除全部 TODO Plan 3 P1）**

把 `docs/governance/m04-apperror-translation-gate.md` 全文替换为以下权威版本（保留底部"应用范围"表原样）：
```markdown
# M0.4 AppError Trust-Boundary Translation Gate（权威；Plan 3 P1 闭合 2026-05-22）

> **Status**：authoritative。本 gate 由 Plan 3 P1 APIClient（首个 public throws 消费
> AppError 的 Swift 模块）落地真代码后从 stub 升级。后续消费 AppError 的 Swift 模块
> （P2/P3a/P3b/P4/P5/P6）继承本规则。

## 原则

spec M0.4 "私有错误在本模块边界内转 AppError，调用方只消费 AppError"。每个 public
throwing Swift 模块边界：内部错误（URLError / DatabaseError / Foundation / 第三方）在本
模块内翻译为 AppError；不得跨模块边界泄露私有错误类型。

## Gate 1（runtime 失败注入测试）

- **覆盖范围**：模块所有 `public`/`open` throwing 函数（含 protocol requirement 及其实现，
  含 `async throws`）。非抛错的 init / accessor / subscript 不在范围（无错误可泄露）；未来
  模块若新增 throwing init/accessor/subscript，同规则适用于任何 public throwing 表面。
- **强度**：每个 public throwing 方法 × 每个文档化失败模式，必须有一条失败注入测试，断言
  抛出的是预期 `AppError` case（`XCTAssertEqual(err as? AppError, .expected)` 或等价 guard）。
- **证据表**：public API → 失败注入测试映射表落 `docs/acceptance/<PR>.md`（非 PR body——
  acceptance doc 更持久且非编码者可核）。

## Gate 2（源码静态核验）

- **形态**：tested shell 脚本 `scripts/check_p<N>_apperror_gate.sh`（与既有
  `check_p2_apperror_gate.sh` / `check_p5_apperror_gate.sh` 同构）。剔除注释后，模块实现
  文件每条 `throw` 行必须含 allowlist token（类型名 `AppError`（大写 A）/ 模块内
  `*ErrorMapping.translate(...)` / `CancellationError`）；否则 FAIL。**不允许裸变量重抛**
  （`throw appErr` 这类变量名小写 a 不命中类型 token `AppError`——封死无法静态证明类型的旁路；
   要透传 AppError 用 `throw (error as? AppError) ?? ...Mapping.translate(error)` 单表达式）。
  脚本自带 `tests/scripts/test-check-p<N>-apperror-gate.sh` 单测（clean PASS / dirty + bare-variable
  bypass FAIL）。
- **不采用** SwiftSyntax lint（toolchain 无 SwiftSyntax，YAGNI）；**不采用**"取消 Gate 2 并入
  Gate 1"（静态核验能抓 Gate 1 runtime 漏测的方法）。

## catch-all 兜底形态

shared 翻译 adapter（如 `APIErrorMapping` 处理跨切面 URLError）与 per-method / inline 状态码
映射（依 endpoint 语义）**均允许**。约束不在"翻译写哪里"，而在边界结果：**无任何 public
throwing 方法让非 AppError 逃逸**（Gate 1 runtime + Gate 2 static 双重保证）。

## 协作取消例外（唯一非 AppError 允许）

`CancellationError` / `URLError.cancelled` 是 AppError-only gate 的**唯一例外**：模块统一
重抛 `CancellationError`，让调用方区分"主动取消" vs "失败"（不误判为可重试的 `.offline`）。
Gate 1 断言取消路径抛 `CancellationError`（非 AppError）；Gate 2 allowlist 含
`throw CancellationError()`。

## 应用范围

| Plan | 模块 | Gate 必需 | 备注 |
|---|---|---|---|
| Plan 2 | B1 import_csv | 否 | 不抛 error 到外 |
| Plan 2 | B2 generate_training_sets | 否 | 同上 |
| Plan 2 | B3/B4 | N/A | Python |
| Plan 3 | **P1 APIClient** | **✅（首次消费，已闭合本 gate 2026-05-22）** | `check_p1_apperror_gate.sh` |
| Plan 3 | P2 DownloadAcceptance | ✅（继承 P1 规则）| `check_p2_apperror_gate.sh` |
| Plan 3 | P3a/P3b / P4 / P5 / P6 | ✅（继承 P1 规则）| P5 = `check_p5_apperror_gate.sh` |
| Plan 3 | E3 TradeCalculator | 否 | 返 `Result`，不 throws |
```

- [ ] **Step 6: 验证 TODO 清零**

Run: `bash -c "! grep -q 'TODO Plan 3 P1' docs/governance/m04-apperror-translation-gate.md" && echo "GATE CLOSED"`
Expected: `GATE CLOSED`（grep 无命中 = 全部 TODO 删除 = stub 已升级权威）。

- [ ] **Step 7: 提交**

```bash
git add scripts/check_p1_apperror_gate.sh tests/scripts/test-check-p1-apperror-gate.sh docs/governance/m04-apperror-translation-gate.md
git commit -m "feat(p1): 闭合 M0.4 trust-boundary gate（stub→权威 + Gate 2 脚本 + 单测）"
```

---

## Task 6：全量验证 + 非编码者验收清单

**Files:**
- Create: `docs/acceptance/2026-05-22-pr-p1-apiclient.md`

- [ ] **Step 1: Gate 2 脚本核验（真 P1 文件）**

Run: `bash scripts/check_p1_apperror_gate.sh`
Expected: `OK: P1 边界所有 throw 走 AppError（或 CancellationError 例外）`，exit 0。

- [ ] **Step 2: M0.4 gate stub closed 断言**

Run: `bash -c "! grep -q 'TODO Plan 3 P1' docs/governance/m04-apperror-translation-gate.md" && echo OK`
Expected: `OK`。

- [ ] **Step 3: 全量 swift 测试 + 0-warning build**

> codex R4 medium：不靠 `| tail` 的退出码（恒 0）作证据——用 `pipefail` + `tee` 落日志 +
> 显式 grep 成功摘要 + 0-warning 断言。

Run:
```bash
cd ios/Contracts
set -o pipefail
swift build 2>&1 | tee /tmp/p1-build.log | tail -5
grep -q "Build complete!" /tmp/p1-build.log || { echo "FAIL: build"; exit 1; }
! grep -qiE "warning:" /tmp/p1-build.log || { echo "FAIL: 有 warning"; exit 1; }
swift test 2>&1 | tee /tmp/p1-test.log | tail -5
grep -qE "Test run with [0-9]+ tests in [0-9]+ suites passed" /tmp/p1-test.log || { echo "FAIL: tests"; exit 1; }
echo "SWIFT GREEN"
```
Expected: 末尾 `SWIFT GREEN`；测试总数 = 既有 baseline + 33（5 mapping + 28 client）。任一断言失败即 exit 1（不会误判通过）。

- [ ] **Step 4: 全量 Python 契约测试**

Run:
```bash
cd backend
set -o pipefail
python -m pytest tests/ -q 2>&1 | tee /tmp/p1-pytest.log | tail -5
grep -qE "[0-9]+ passed" /tmp/p1-pytest.log && ! grep -qE "[0-9]+ failed" /tmp/p1-pytest.log || { echo "FAIL: pytest"; exit 1; }
echo "PYTEST GREEN"
```
Expected: 末尾 `PYTEST GREEN`（既有 11 + 新增 8 openapi 契约测试全 PASS）。

- [ ] **Step 5: 写非编码者验收清单**

`docs/acceptance/2026-05-22-pr-p1-apiclient.md` — 中文，action / expected / pass-fail 三列；禁忌词见 `.claude/workflow-rules.json`。必须含：
  - **A 契约冻结**：openapi meta partial-200 + 共享 fixtures（pytest GREEN）
  - **B 网络客户端**：reserve/download/confirm 三方法 happy path（swift GREEN）
  - **C Gate 1 错误翻译**：timeout/offline/500/409/404/decode-fail 全抛对应 AppError —— **含 public API → 失败注入测试 证据映射表**（per m04 gate doc Gate 1 要求）
  - **D Gate 2**：`bash scripts/check_p1_apperror_gate.sh` OK
  - **E M0.4 gate 闭合**：`! grep -q 'TODO Plan 3 P1' docs/governance/m04-apperror-translation-gate.md`（per m04 gate doc 必含断言）
  - **F partial-200 + count 契约**：empty/partial 不抛错原样返回；count 越界 / overfull 不发请求或 fail-closed
  - **G 取消语义**：CancellationError / URLError.cancelled 重抛 CancellationError（非 AppError）
  - **H download 清理**：非 200 下载临时文件已清理
  - **I 全量回归**：swift test + pytest 全绿、0 warning

- [ ] **Step 6: 提交**

```bash
git add docs/acceptance/2026-05-22-pr-p1-apiclient.md
git commit -m "docs(p1): 非编码者验收清单（契约冻结 + 3 方法 + Gate 1/2 + M0.4 闭合 + 取消/清理）"
```

---

## Self-Review（writing-plans 自检，已执行）

**1. Spec coverage：**
- §8.1 三 endpoint（meta/download/confirm）→ Task 2 协议 + Task 4 实现 ✓
- §M0.4 L655 P1 throws AppError + URLError/HTTP 映射 → Task 3 + Task 4 + Gate 1 测试 ✓
- §M0.5 L682 内部 actor + L711 Sendable 返回 → Task 4 `actor DefaultAPIClient` + DTO 已 Sendable ✓
- openapi confirm 200/409/404 幂等 + `{ok:true}` body 校验（codex R1 high）→ Task 4 confirm 测试 ✓
- count 上界契约（codex R1 medium）：发请求前 1...100 校验 + 解码后 overfull guard → Task 4 reserve 测试 ✓
- leaseId UUID 校验（codex R2 high）→ Task 4 confirm invalid-leaseId 测试 ✓
- 协作取消语义（codex R2 medium）：重抛 CancellationError → Task 4 cancellation 测试 + m04 gate doc 文档化 ✓
- download 失败临时文件清理（codex R2 medium）→ Task 4 download-cleanup 测试 ✓
- M0.4 gate 闭合（codex R2 high）：stub→权威 + 删 5 TODO + Gate 2 脚本 + 单测 → Task 5 ✓
- meta 字段契约校验（codex R4 high）：解码后校验 lease_id/expires_at/content_hash 的 openapi format/pattern → Task 4 reserve meta 测试 ✓
- Gate 2 抗旁路（codex R3+R4+R5 high）：去 bare-variable 重抛 + 剥行内注释 + **P5-style 3 规则（public 方法零 raw 危险 try + raw-try 就近翻译）** + bypass/inline/raw-try dirty 测试 → Task 5 ✓
- public 方法零 raw 危险 try（codex R5 high）：IO/解码全推 private helper（send/sendDownload/decodeLease/requireConfirmOk/moveToOwnedTemp）→ Task 4 重构 ✓
- download 404 terminal（codex R5 medium）：404 → `.trainingSet(.fileNotFound)`（isRecoverable=false）+ openapi 文档化 404 → Task 1 + Task 4 download 测试 ✓
- outline §3.1 contract-freeze（empty/partial meta）+ 共享 fixtures → Task 1 ✓
- M0.4 trust-boundary gate（Gate 1 runtime + Gate 2 static script）→ Task 4 + Task 5 + Task 6 ✓
- 缺口：download `Content-MD5` 二次校验 → 故意 out-of-scope（设计决策 3，P2 负责完整性）。

**2. Placeholder scan：** 无 TBD / "add error handling" / "similar to Task N"；所有 step 含完整代码或精确命令 + expected。

**3. Type consistency：** `APIClient`（协议）/ `DefaultAPIClient`（impl）/ `HTTPRequesting`（缝）/ `FakeHTTPTransport`（替身）/ `APIErrorMapping`（翻译）/ `ContractFixtures`（fixture loader）/ `ConfirmResponse`（confirm 200 解码）跨 Task 命名一致；方法签名 `reserveTrainingSets(count:)` / `downloadTrainingSet(id:)` / `confirmTrainingSet(id:leaseId:)` 在协议、实现、测试中一致；`LeaseResponse`/`TrainingSetMetaItem`/`AppError`/`NetworkReason` 复用既有 M0.3/M0.4 类型，未重定义。

---

## 已拒绝的 codex finding（residual，spec-override pushback）

- **codex R3 high「reserve 改 POST + idempotency key」/ R5 high「reserve timeout 应 non-retryable」
  → 两次提，均拒绝**。两条是同一根因的换皮：`GET /training-sets/meta` 的非幂等副作用 +
  超时重试二次预占。这是 **spec v1.4 已冻结的已知 residual**（backend/openapi.yaml L6 + L20-23
  显式记录；memory `project_spec_v1.4_rest_design_residuals`）。codex 担心的"response 丢失/超时
  → retry 二次预占 → 库存饿死"正是该 residual，已由 **lease TTL=10 分钟自动回滚 + B4 APScheduler
  每日 05:00 把 `lease_expires_at ≤ now` 的 reserved 复位 + 内网单用户（无 CDN/prefetch/多客户端
  并发）** 三重兜底。
  - R5 建议「把 reserve 超时改成 non-retryable error」额外不可取：会**偏离 M0.4 §L655 明确的
    `URLError.timedOut → .network(.timeout)` 映射契约**；且重试治理属 P2/UI（Wave 2）状态机职责，
    不在 P1 边界 scope。
  - 改 POST + idempotency key 会**破坏 frozen openapi.yaml 契约**（需独立 RFC governance PR）。
  - memory 明示"codex 再提这 2 条直接 pushback，不 re-enter spec 讨论"。公网迁移时由 spec v1.5+
    收紧（meta→POST / download 加 lease_id），届时 Plan 1b openapi + B3 route + P1 调用方一起改。

---

## 流程后续（per Wave 1 outline §五）

writing-plans → **codex plan-stage adversarial review（4-5 轮收敛）** → subagent-driven-development → verification-before-completion → requesting-code-review → **codex branch-diff adversarial review（4-5 轮收敛）** → 非编码者验收 → admin merge → memory 落地。
