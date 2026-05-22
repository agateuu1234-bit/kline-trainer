# PR P1 APIClient 验收清单（中文非编码者可执行）

**PR 范围**：P1 APIClient（Wave 1 顺位 2）——新增/修改文件：
`backend/openapi.yaml`、`tests/contract-fixtures/`、
`ios/Contracts/Sources/KlineTrainerPersistence/Network/APIClient.swift`、
`ios/Contracts/Sources/KlineTrainerPersistence/Network/HTTPRequesting.swift`、
`ios/Contracts/Sources/KlineTrainerPersistence/DefaultAPIClient.swift`、
`ios/Contracts/Sources/KlineTrainerPersistence/Internal/APIErrorMapping.swift`、
`scripts/check_p1_apperror_gate.sh`、
`tests/scripts/test-check-p1-apperror-gate.sh`、
`docs/governance/m04-apperror-translation-gate.md`（升级）、各配套测试。

**branch-diff R1**：2 high（terminal URLError + 非预期 4xx 误报 recoverable）→ 全修（TLS/auth/cert + 400/401/403/422 → terminal internalError）

**Codex plan-stage 对抗 review 统计**：共 5 轮：
- R1：confirm-body 格式 + count 参数校验
- R2：leaseId UUID 校验 + 取消语义 + download 临时文件清理 + M0.4 gate 闭合
- R3：false-positive 测试 + gate bypass 漏洞 + pipefail 缺失
- R4：meta 字段校验（lease_id/expires_at/content_hash）+ gate inline-comment
- R5：raw-try gate 覆盖 + download-404 terminal 语义

**驳回 finding 记录**（reserve→POST 幂等性 × 2 次复述，见 plan §"已拒绝的 codex finding"）：
当前 openapi.yaml 使用 GET reserve 契约为已冻结残留（wave0-frozen-v1.4 约定内网单用户 TTL+B4 兜底），codex 再提该 finding 直接 pushback。

满 5 轮后 escalate → 用户选择"接受 plan 进实施"。

---

## 非编码者可执行验收步骤

> 执行环境要求：本地 clone、已安装 Xcode 命令行工具 + Python 3。
> 所有命令在项目根目录执行（除非 Action 中另有 `cd`）。

---

### A 契约冻结

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| A1 | 终端运行：`cd backend && python3 -m pytest tests/test_openapi.py -q 2>&1 \| tail -5` | 末行含 `19 passed`（11 原有 + 8 新增） | □ Pass / □ Fail |
| A2 | 用文本编辑器打开 `backend/openapi.yaml`，搜索 `description` 字段（文件顶层 info.description） | 含字符串 `partial fulfillment` | □ Pass / □ Fail |
| A3 | 在同一文件搜索 `/training-set/{id}/download` 路径下的 responses | 含 `'404'` response 定义 | □ Pass / □ Fail |

---

### B 网络客户端 happy path

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| B1 | 终端运行：`cd ios/Contracts && swift test --filter DefaultAPIClientTests 2>&1 \| tail -5` | 含 `Executed 31 tests, with 0 failures`（reserve / download / confirm 三方法全绿） | □ Pass / □ Fail |

---

### C Gate 1 错误翻译证据映射表

每行对应一个注入场景 → 测试函数 → 期望的 AppError。DefaultAPIClientTests 31 个用例、APIErrorMappingTests 7 个用例均含在内。

#### C1 reserveTrainingSets 失败场景

| 失败场景 | 注入方式 | 测试函数 | 期望 AppError |
|---|---|---|---|
| count = 0 / -1 / 101（无效参数） | 直接传入非法 count | `test_reserve_invalid_count_throws_without_issuing_request` | `.internalError("P1", _)`，且**不发出** HTTP 请求 |
| 服务端返回条目数 > 请求数（overfull） | HTTP 200 body 含 2 条但 count=1 | `test_reserve_overfull_response_throws_internalError` | `.internalError("P1", _)` |
| 响应 body 格式非 JSON | HTTP 200 + `{not json` | `test_reserve_malformed_body_throws_internalError_p1` | `.internalError("P1", _)` |
| HTTP 500 | statusCode=500 | `test_reserve_http_500_throws_serverError` | `.network(.serverError(code: 500))`（5xx → recoverable） |
| 非预期 4xx（如 400） | statusCode=400 | `test_reserve_http_400_throws_terminal_internalError` | `.internalError("P1", "http_400")`（terminal/不可重试） |
| 网络超时（URLError.timedOut） | error=URLError(.timedOut) | `test_reserve_timeout_throws_network_timeout` | `.network(.timeout)` |
| 无网络（URLError.notConnectedToInternet，属连通性 URLError） | error=URLError(.notConnectedToInternet) | `test_reserve_offline_throws_network_offline` | `.network(.offline)`（仅瞬断连通性代码 → recoverable） |
| 响应非 HTTPURLResponse | returnNonHTTPResponse=true | `test_reserve_non_http_response_throws_internalError` | `.internalError("P1", _)` |
| meta.lease_id 非 UUID 格式 | body 中 lease_id="not-a-uuid" | `test_reserve_invalid_lease_id_in_meta_throws` | `.internalError("P1", "meta_invalid_lease_id")` |
| meta.expires_at 非 ISO8601 | body 中 expires_at="not-a-date" | `test_reserve_invalid_expires_at_throws` | `.internalError("P1", "meta_invalid_expires_at")` |
| meta.sets[].content_hash 非 hex | body 中 content_hash="ZZZZ" | `test_reserve_invalid_content_hash_throws` | `.internalError("P1", "meta_invalid_content_hash")` |

#### C2 downloadTrainingSet 失败场景

| 失败场景 | 注入方式 | 测试函数 | 期望 AppError |
|---|---|---|---|
| HTTP 404（文件不存在） | statusCode=404 | `test_download_404_throws_fileNotFound_terminal` | `.trainingSet(.fileNotFound)`，`isRecoverable == false` |
| HTTP 500 | statusCode=500 | `test_download_500_throws_serverError` | `.network(.serverError(code: 500))`（5xx → recoverable） |
| 网络断开（URLError.networkConnectionLost，属连通性 URLError） | error=URLError(.networkConnectionLost) | `test_download_offline_throws_network_offline` | `.network(.offline)`（仅瞬断连通性代码 → recoverable） |
| TLS / 证书错误（URLError.secureConnectionFailed） | error=URLError(.secureConnectionFailed) | `test_tls_error_maps_to_terminal_internalError` | `.internalError("P1", "url_error_…")`（terminal/不可重试） |
| HTTP Auth 要求（URLError.userAuthenticationRequired） | error=URLError(.userAuthenticationRequired) | `test_auth_required_maps_to_terminal_internalError` | `.internalError("P1", "url_error_…")`（terminal） |
| 服务端响应异常（URLError.badServerResponse） | error=URLError(.badServerResponse) | `test_bad_server_response_maps_to_terminal_internalError` | `.internalError("P1", "url_error_…")`（terminal） |

#### C3 confirmTrainingSet 失败场景

| 失败场景 | 注入方式 | 测试函数 | 期望 AppError |
|---|---|---|---|
| leaseId 非 UUID 格式（无效参数） | leaseId="not-a-uuid" | `test_confirm_invalid_lease_id_throws_without_request` | `.internalError("P1", _)`，且**不发出** HTTP 请求 |
| HTTP 200 但 body 格式非 JSON | HTTP 200 + `{not json` | `test_confirm_200_malformed_body_throws_decode_failed` | `.internalError("P1", "confirm_decode_failed")` |
| HTTP 200 且 `{"ok":false}` | HTTP 200 + `{"ok":false}` | `test_confirm_200_ok_false_throws_not_ok` | `.internalError("P1", "confirm_not_ok")` |
| HTTP 409（lease 已过期） | statusCode=409 | `test_confirm_409_throws_leaseExpired` | `.network(.leaseExpired)` |
| HTTP 404（lease 不存在） | statusCode=404 | `test_confirm_404_throws_leaseNotFound` | `.network(.leaseNotFound)` |
| HTTP 500 | statusCode=500 | `test_confirm_500_throws_serverError` | `.network(.serverError(code: 500))`（5xx → recoverable） |
| 非预期 4xx（如 403） | statusCode=403 | `test_confirm_403_throws_terminal_internalError` | `.internalError("P1", "http_403")`（terminal/不可重试） |

#### C4 取消语义（CancellationError 不封装为 AppError）

| 失败场景 | 注入方式 | 测试函数 | 期望行为 |
|---|---|---|---|
| reserve 收到 CancellationError | error=CancellationError() | `test_reserve_cancellationError_rethrows_as_cancellation` | 抛出 `CancellationError`，**不是** AppError |
| download 收到 URLError.cancelled | error=URLError(.cancelled) | `test_download_urlerror_cancelled_rethrows_as_cancellation` | 抛出 `CancellationError`，**不是** AppError |

---

### D Gate 2 静态核验

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| D1 | 终端运行：`bash scripts/check_p1_apperror_gate.sh` | 输出 `OK: P1 边界全 throw 走 AppError + public 方法零 raw 危险 try`，exit code = 0 | □ Pass / □ Fail |
| D2 | 终端运行：`bash tests/scripts/test-check-p1-apperror-gate.sh` | 末行含 `ALL PASS`，共 6 个用例全绿 | □ Pass / □ Fail |

---

### E M0.4 gate 闭合核验

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| E1 | 终端运行：`bash -c "! grep -q 'TODO Plan 3 P1' docs/governance/m04-apperror-translation-gate.md" && echo OK` | 输出 `OK`（文件内不含旧占位 TODO） | □ Pass / □ Fail |
| E2 | 用文本编辑器打开 `docs/governance/m04-apperror-translation-gate.md`，查看文件开头 | 含字符串 `authoritative` | □ Pass / □ Fail |
| E3 | 在同一文件中找到应用范围表，定位 P1 行 | P1 行含 `✅` 且含 `首次消费` 且含 `2026-05-22` | □ Pass / □ Fail |

---

### F partial-200 + count 契约

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| F1 | 终端运行：`cd ios/Contracts && swift test --filter "test_reserve_empty\|test_reserve_partial" 2>&1 \| tail -5` | 含 `Executed 2 tests, with 0 failures`（空 sets 和部分返回均不抛错） | □ Pass / □ Fail |
| F2 | 终端运行：`cd ios/Contracts && swift test --filter "test_reserve_invalid_count\|test_reserve_overfull" 2>&1 \| tail -5` | 含 `Executed 2 tests, with 0 failures`（count 非法 + overfull 均 fail-closed） | □ Pass / □ Fail |

---

### G 取消语义

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| G1 | 终端运行：`cd ios/Contracts && swift test --filter "test_reserve_cancellationError\|test_download_urlerror_cancelled" 2>&1 \| tail -5` | 含 `Executed 2 tests, with 0 failures`（CancellationError / URLError.cancelled 均重抛为 CancellationError，不封装为 AppError） | □ Pass / □ Fail |

---

### H download 临时文件清理

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| H1 | 终端运行：`cd ios/Contracts && swift test --filter test_download_non200_cleans_temp_file 2>&1 \| tail -5` | 含 `Executed 1 test, with 0 failures`（非 200 下载时临时文件被删除） | □ Pass / □ Fail |

---

### I 全量回归 + 0 warning

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| I1 | 终端运行：`cd ios/Contracts && swift build 2>&1 \| tail -3` | 末行含 `Build complete!`，输出中**不含** `warning:` | □ Pass / □ Fail |
| I2 | 终端运行：`cd ios/Contracts && swift test 2>&1 \| tail -5` | 末行（或末几行）出现 `✔ Test run with 297 tests in 63 suites passed`（swift-testing 业务测试全绿）（注：该行只统计 swift-testing 套件；P1 的 XCTest 套件计数见 I2b） | □ Pass / □ Fail |
| I2b | 终端运行：`cd ios/Contracts && swift test 2>&1 \| grep -c "with 0 failures"` | 输出 ≥ 1（每个 XCTest 套件均 0 failures；P1 的 DefaultAPIClientTests / APIErrorMappingTests 含在内） | □ Pass / □ Fail |
| I3 | 终端运行：`cd backend && python3 -m pytest tests/ -q 2>&1 \| tail -3` | 末行含 `28 passed` | □ Pass / □ Fail |

---

## merge 后

- **M0.4 gate 闭合**：`docs/governance/m04-apperror-translation-gate.md` P1 行状态已标记 `✅（首次消费，已闭合本 gate 2026-05-22）`，无需额外 ledger 操作。
- **下一锚**：Wave 1 顺位 3 — **C2 DecelerationAnimator**（按 `docs/superpowers/specs/2026-05-19-wave1-outline-design.md` §二 顺位表）。
