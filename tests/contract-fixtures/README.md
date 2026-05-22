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
