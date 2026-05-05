# PR5b 验收清单 — Wave 0 顺位 10 端口域 Fixture

> 本清单面向**非 coder**：每条「动作」可在终端复制粘贴执行；「期望」是看到的输出关键字；「通过条件」二选一非常明确。

**PR 范围：**
- 升级 `InMemoryCacheManager` 从 stub 到真状态 fake（spec §11.3 #6）
- 新增 4 个 P2 内部端口 fake（spec §11.3 #7–#10）
- **不含** `FakeAPIClient`（spec §11.3 #11，已 defer 到 Wave 1，理由见本清单 §5）

---

## 1. 仓库构建编译验证

**动作：**
```
cd ios/Contracts && swift build 2>&1 | tail -10
```

**期望：** 输出末尾包含 `Build complete!`（不含 `error:`）

**通过条件：** 通过 = 看到 `Build complete!`；不通过 = 看到 `error:` 任意一行

---

## 2. PR5b 新增测试全部通过

> R2-H1 修订：filter 用 Swift class/struct 名（不带 target prefix）。

**动作：**
```
cd ios/Contracts && swift test --filter InMemoryCacheManagerTests 2>&1 | tail -5
cd ios/Contracts && swift test --filter P2FakesTests 2>&1 | tail -5
```

**期望：** 两次输出末尾都看到 `with 0 failures` 或 `Test run with N tests in ... passed`，**没有 `failed` 字样**。

**通过条件：** 通过 = 两个 suite 全 `passed`；不通过 = 任一 `failed`

---

## 3. PR #40 既有 InMemoryFakes 测试不破

> R2-H1 修订：`swift test --filter` 用 Swift struct 名（`InMemoryFakesTests`，含 Tests 后缀），不是 `@Suite` 显示名 "InMemoryFakes" 也不是文件名。实测命中 5 测试。

**动作：**
```
cd ios/Contracts && swift test --filter InMemoryFakesTests 2>&1 | tail -5
```

**期望：** 输出含 `Test run with 5 tests in 1 suite passed`，特别确认有 `InMemoryCacheManager.listAvailable 返回空 / pickRandom 返回 nil`（fresh fake 仍成立）

**通过条件：** 通过 = `passed`；不通过 = `failed` 字样

---

## 4. PR5a 既有测试不破

**动作：**
```
cd ios/Contracts && swift test --filter InMemoryDBFakesTests 2>&1 | tail -3
cd ios/Contracts && swift test --filter PreviewTrainingSetReaderTests 2>&1 | tail -3
```

**期望：** 两次输出末尾都含 `with 0 failures` 或 `passed`

**通过条件：** 通过 = 两个 suite 全 `passed`；不通过 = 任一 `failed`

---

## 5. spec §11.3 #11 FakeAPIClient defer 验证

**动作：**
```
grep -rn "protocol APIClient" ios/Contracts/Sources/ 2>&1 | head -3
```

**期望：** **没有命中**（grep 输出为空）。这证明 P1 APIClient Swift protocol 在代码层不存在。FakeAPIClient 无 protocol 可 fake，按 memory rule "B1-B4 backend：推到 Wave 1（与 P1 APIClient 联调一起做）" defer 到 Wave 1 P1 plan。

**通过条件：** 通过 = grep 0 命中；不通过 = grep 命中（说明 P1 已落地，本 PR 应补 FakeAPIClient 不能 defer）

---

## 6. M0.4 AppError 边界 grep（fake 抛 AppError 不泄露内部错误）

**动作：**
```
grep -nE "^[[:space:]]*throw " ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/P2Fakes.swift | grep -v "AppError" 2>&1
```

**期望：** **没有命中**（grep 第一段列所有 throw 语句，第二段排除合法的 `AppError`；剩下的命中即非法私有错误抛出）。fake 应只抛 `AppError.*` 子 case 或 caller 注入的 `AppError`。

**通过条件：** 通过 = 最终 grep 输出为空；不通过 = 命中任一行（即出现非 AppError 的 throw）

---

## 7. 总测试数 baseline

**动作：**
```
cd ios/Contracts && swift test 2>&1 | grep -E "Test Suite '.*' (passed|failed)" | tail -1
```

**期望：** 末行是顶层 `Test Suite 'All tests' passed at ...`，无 failed

**通过条件：** 通过 = `passed`；不通过 = `failed`
