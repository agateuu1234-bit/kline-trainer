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
  bypass + 行内注释 + public 方法 raw-try 泄漏 FAIL）。
- **规则2 防 raw-try 泄漏**：public 方法体内禁 raw 危险 try（transport/decoder/JSONDecoder/
  FileManager/.decode/.write）——IO/解码全推 private helper，否则 `try foo.decode(...)` 这类无
  显式 throw 行也会让私有错误逃逸。
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
