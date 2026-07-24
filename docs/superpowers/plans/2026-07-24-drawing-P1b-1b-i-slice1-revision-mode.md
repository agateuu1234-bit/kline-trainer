# 划线 P1b-1b-i 切片1（引擎状态地基：drawingsRevision + replay 净状态签名 + 选择态 mode）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 1b-i「选中/编辑/删除」铺三块引擎/会话状态地基——内容级 dirty 计数器 `drawingsRevision`、replay clean-skip 改用净状态语义签名、选择态显式 `mode`——全部零 UI、host `swift test` 全覆盖。

**Architecture:** 三块彼此独立、都落在既有 `TrainingEngine` / `TrainingSessionCoordinator` / `DrawingSession` 上。`drawingsRevision` 是单调计数器驱动 autosave；replay clean-skip 从「drawing 计数相等」升级为「drawing 规范语义签名相等」；`DrawingSession.mode` 用 `.draw|.select` 显式区分两态，取代母 spec 用 `activeDrawingTool == nil` 的编码。后续切片（PR-2 写入边界 API / PR-3 命中渲染 / PR-4 交互 UI）都建在这三块之上。

**Tech Stack:** Swift 5.9 / `@Observable` / SwiftPM（`ios/Contracts`）；测试 `swift test`（host，macOS）；跨平台纯逻辑（无 UIKit）。

## Global Constraints

- `CONTRACT_VERSION` 保持 **1.12**，`user_version` 保持 **7**，**零迁移**（本切片不新增/不改任何持久化字段；`drawingsRevision` 是运行时计数器、`mode` 是运行时状态，都不进存储）。
- **完整 spec**：`docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（决策 D49–D67，本切片落 **D56 / D57**）。
- **访问级别纪律**：`DrawingSession` 的所有 mutator 一律 `internal`，不加 `public`（顶部 `:21-28` 大注释写明理由）。新增 `setMode` 遵守。
- **测试基线**：本机 `swift test` 全绿基线 = **1661 passed**（base `d2754df`）。每个 Task 结束时全绿。
- **禁止**改用 `.onChange(of: engine.drawings)` 或任何数组值比较：`DrawingObject.==` 排除 `id`（D56）。

---

## 测试 fixture（本切片各测试共用，codex plan-R2-F2）

`DrawingObject.init` **要求** `isExtended: Bool` 与 `panelPosition: Int`（`Models/Models.swift:265-274`，**无默认值**）。为免每处测试重复这两个参数、也免片段编译失败，本切片所有测试用统一 fixture 造水平线。**在每个用到它的测试文件顶部各放一份**（或抽到共享 `Tests/.../DrawingTestFixtures.swift` 由各文件 import）：

```swift
// 造一条水平线 DrawingObject，只传关心的字段，其余取默认/固定（isExtended:false, panelPosition:0）。
func makeHLine(id: String = "hl", candleIndex: Int = 3, price: Double = 10,
               period: Period = .daily, thickness: Int = 1, text: String = "") -> DrawingObject {
    DrawingObject(id: id, toolType: .horizontal,
                  anchors: [DrawingAnchor(candleIndex: candleIndex, price: price, period: period)],
                  isExtended: false, panelPosition: 0, period: period, thickness: thickness, text: text)
}
```

> `DrawingAnchor` 的初值参数（`candleIndex`/`price`/`period`）以本仓既有测试对它的构造方式为准（同文件 grep 一处 `DrawingAnchor(` 用法对齐）。所有下文测试片段里的 `makeHLine(...)` 都指本 fixture；**不再出现裸 `DrawingObject(...)`**（避免漏 `isExtended`/`panelPosition` 编译失败）。

---

### Task 1: `drawingsRevision` 计数器 + 现有改-drawings API 各 `+= 1`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（加字段 + `appendDrawing:1088`/`deleteDrawing(at:):1074` 各 +=1）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（同文件追加）

**Interfaces:**
- Produces: `TrainingEngine.drawingsRevision: Int`（`public private(set)`，初值 0，单调递增）；`appendDrawing`/`deleteDrawing(at:)` 成功即 `+= 1`。
- 约束（D56）：`drawingsRevision` **只覆盖 `drawings`**，`appendReviewDrawing`/`removeReviewDrawing`（写 `reviewDrawings`）**不动它**。

- [ ] **Step 1: 写失败测试**

在 `TrainingEngineDrawingSessionTests.swift` 追加（`@testable import KlineTrainerContracts` 已在文件头）：

```swift
@Test("drawingsRevision: appendDrawing 成功严格 +1，appendReviewDrawing 不动它")
@MainActor func drawingsRevisionCoversDrawingsNotReview() throws {
    let engine = TrainingEngine.makeForTesting()          // 既有测试工厂（同文件其它测试在用）
    #expect(engine.drawingsRevision == 0)
    #expect(engine.appendDrawing(makeHLine(candleIndex: 3, price: 10)) == true)
    #expect(engine.drawingsRevision == 1)                 // 严格 +1
    // review 侧不动 drawingsRevision（D56）
    #expect(engine.appendReviewDrawing(makeHLine(candleIndex: 4, price: 11)) == true)
    #expect(engine.drawingsRevision == 1)                 // 仍是 1
}

@Test("drawingsRevision: deleteDrawing(at:) 严格 +1")
@MainActor func drawingsRevisionOnDelete() throws {
    let engine = TrainingEngine.makeForTesting()
    _ = engine.appendDrawing(makeHLine(candleIndex: 3, price: 10))
    let before = engine.drawingsRevision
    engine.deleteDrawing(at: 0)
    #expect(engine.drawingsRevision == before + 1)
}
```

> 若 `TrainingEngine.makeForTesting()` 签名与本文件其它测试不符，以本文件既有用法为准（同文件 grep 一条现存测试对齐）。`makeHLine` 见「测试 fixture」节。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter drawingsRevision 2>&1 | tail -20`
Expected: 编译失败 `value of type 'TrainingEngine' has no member 'drawingsRevision'`。

- [ ] **Step 3: 加字段 + 两处 +=1**

在 `TrainingEngine.swift` 类体加字段（紧邻 `drawings`/`reviewDrawings` 声明附近，约 `:28` 区）：

```swift
    /// D56（1b-i）：内容级 dirty 计数器。**每一个**改动 `drawings` 的引擎 API 都 `+= 1`（append/delete(at:)/
    /// 后续 update/delete(id:)）。TrainingView 的 autosave 触发器盯它（换掉 `drawings.count`，
    /// 否则原地改样式不改长度→永不落盘）。**只覆盖 `drawings`，不覆盖 `reviewDrawings`**（复盘本期不改样式）。
    /// 运行时计数器，不进存储（初值 0，每次装载从 0 起算，绝对值无语义）。
    public private(set) var drawingsRevision: Int = 0
```

`deleteDrawing(at:)`（`:1074-1077`）改为：

```swift
    public func deleteDrawing(at index: Int) {
        precondition(drawings.indices.contains(index), "deleteDrawing index out of bounds")
        drawings.remove(at: index)
        drawingsRevision += 1
    }
```

`appendDrawing`（`:1088-1092`）在 `drawings.append` 后加 `+= 1`：

```swift
    @discardableResult
    public func appendDrawing(_ drawing: DrawingObject) -> Bool {
        guard isPeriodConsistent(drawing) else { return false }
        drawings.append(drawing)
        drawingsRevision += 1
        return true
    }
```

`appendReviewDrawing`/`removeReviewDrawing` **不加**（D56：只覆盖 drawings）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter drawingsRevision 2>&1 | tail -20`
Expected: 2 tests PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
git commit -m "划线 1b-i 切片1 Task1：drawingsRevision 计数器 + append/delete(at:) 各 +=1（D56，只覆盖 drawings）"
```

---

### Task 2: TrainingView autosave 触发器 `drawings.count` → `drawingsRevision`

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift:355`（`.onChange`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift`（源码守卫，UIKit-gated → 见步骤说明）

**Interfaces:**
- Consumes: `TrainingEngine.drawingsRevision`（Task 1）。
- Produces: 训练/replay 的 autosave 由 `drawingsRevision` 变化驱动；`reviewDrawings.count` 触发器（`:358`）**保持不动**。

- [ ] **Step 1: 写源码守卫失败测试**

`TrainingView` 在 host `swift test` 不编译（UIKit），故用**源码文本守卫**（同 `TrainingViewShellSourceGuardTests` 既有做法：读源码字符串断言）。追加：

```swift
@Test("autosave 触发器盯 drawingsRevision，不再盯 drawings.count（D56）")
func autosaveTriggerUsesRevision() throws {
    let src = try String(contentsOfFile: trainingViewPath, encoding: .utf8)   // 既有 helper 路径常量
    #expect(src.contains(".onChange(of: engine.drawingsRevision)"))
    #expect(!src.contains(".onChange(of: engine.drawings.count)"))            // 旧触发器必须消失（防两个并存）
    #expect(src.contains(".onChange(of: engine.reviewDrawings.count)"))      // review 侧不动
}
```

> `trainingViewPath` 常量若不存在，用本文件既有源码守卫测试读取路径的同一方式（grep 同文件一条 `String(contentsOfFile:` 用法对齐）。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter autosaveTriggerUsesRevision 2>&1 | tail -20`
Expected: FAIL（`src.contains(".onChange(of: engine.drawingsRevision)")` 为假）。

- [ ] **Step 3: 换触发器**

`TrainingView.swift:355`：

```swift
        .onChange(of: engine.drawingsRevision) { _, _ in
            lifecycle.autosave(immediate: true)                 // §4.6：画线/改样式/删除即存（不推 tick，D9）
        }
```

（`:358` 的 `.onChange(of: engine.reviewDrawings.count)` 一字不动。）

- [ ] **Step 4: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter autosaveTriggerUsesRevision 2>&1 | tail -20`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift ios/Contracts/Tests/KlineTrainerContractsTests/Render/TrainingViewShellSourceGuardTests.swift
git commit -m "划线 1b-i 切片1 Task2：autosave 触发器 drawings.count→drawingsRevision（D56，review 侧不动）"
```

---

### Task 3: replay clean-skip 改用 drawing 规范语义签名（净状态相等）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`replayBaseline` 类型 `:56` + 三处赋值 `:581`/`:934`/`:974` + clean-skip 判据 `:606-614`）
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift`（规范签名纯函数）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift`（既有 replay 持久化测试文件，追加）

**Interfaces:**
- Produces: `canonicalDrawingsSignature(_ drawings: [DrawingObject]) -> String`（规范语义签名，与 raw 字节格式无关）。
- 修改 `replayBaseline` 元组第三分量：`drawings: Int`（count）→ `drawingsSig: String`（签名）。

- [ ] **Step 1: 写失败测试**

```swift
@Test("canonicalDrawingsSignature: 语义相等→签名相等，字段变→签名变")
func canonicalSignatureSemantics() throws {
    let a     = makeHLine(id: "x", candleIndex: 3, price: 10, thickness: 1)   // fixture 见「测试 fixture」节
    let aSame = makeHLine(id: "x", candleIndex: 3, price: 10, thickness: 1)
    let aThick = makeHLine(id: "x", candleIndex: 3, price: 10, thickness: 3)
    #expect(canonicalDrawingsSignature([a]) == canonicalDrawingsSignature([aSame]))  // 语义相等→签名相等
    #expect(canonicalDrawingsSignature([a]) != canonicalDrawingsSignature([aThick])) // 改 thickness→签名变
    #expect(canonicalDrawingsSignature([]) != canonicalDrawingsSignature([a]))       // 空 vs 一条
}

@Test("canonicalDrawingsSignature: id/text 含分隔符也不碰撞（codex plan-R2-F1，单射）")
func canonicalSignatureInjectiveWithSeparators() throws {
    // 裸分隔符 join 会让这两个语义不同的数组产出相同签名；长度前缀编码不会。
    let x = makeHLine(id: "a\u{1F}b", text: "c")      // id 里塞了旧设计的字段分隔符 0x1F
    let y = makeHLine(id: "a", text: "b\u{1F}c")      // 挪到 text 里——裸 join 下与 x 拼出同串
    #expect(canonicalDrawingsSignature([x]) != canonicalDrawingsSignature([y]))
    // 条分隔符同理：两条 vs 一条含 0x1E 的 text
    let p = [makeHLine(id: "p"), makeHLine(id: "q")]
    let r = [makeHLine(id: "p", text: "\u{1E}q")]
    #expect(canonicalDrawingsSignature(p) != canonicalDrawingsSignature(r))
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter canonicalSignatureSemantics 2>&1 | tail -20`
Expected: 编译失败 `cannot find 'canonicalDrawingsSignature' in scope`。

- [ ] **Step 3: 写签名纯函数**

`DrawingSignature.swift`（新建）：

```swift
// Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift
// D56（1b-i）：replay clean-skip 的净状态判据 = drawing 规范语义签名。
// ⚠️ 不用 loadedDrawingsLossy.encoded() 的原始字节（codex R12-F2）：lossy 对编辑过的 known 行重序列化成
//   sorted-key JSON，edit+revert 后语义==baseline 但字节≠原始 raw → 字节相等误判脏 → 写净空槽覆盖别的记录。
//   必须先规范化：把每条 DrawingObject 的【全部字段】按固定顺序拼进签名（含 id），与 raw 字节格式无关。
// 与母 spec §6.3 D6 ReviewNetChange 的 per-drawing 全字段 key 同精神。
import Foundation

/// drawings 的规范语义签名：语义相等 ⟺ 签名相等，与磁盘 raw 的 key 顺序/格式无关。
/// 含 `id` + 全部已知字段（`DrawingObject.==` 排除 id，故不能直接用它）。顺序敏感（数组序 = z-order）。
/// ⚠️ **必须单射（codex plan-R2-F1）**：`id`/`text` 是普通 `String`，导入/损坏/未来数据可含任意字节
///   （含分隔符/控制字符）。用**长度前缀**编码每个字段（`"<utf8字节数>:<内容>"`），长度让边界无歧义 →
///   任意内容都不会碰撞；**不得**用裸分隔符 join（那样 `text` 里塞个分隔符就能伪造出等签名的不同 drawings，
///   导致 clean-skip 误判相等、丢编辑）。
public func canonicalDrawingsSignature(_ drawings: [DrawingObject]) -> String {
    // 长度前缀编码：任意 String s → "<s 的 utf8 字节数>:s"。拼接后按长度切回，无歧义（单射）。
    func lp(_ s: String) -> String { "\(s.utf8.count):\(s)" }
    return drawings.map { d -> String in
        // 每条：把所有字段都转成 String 后逐个 lp() 拼接。变长的 anchors 先放个数再逐字段。
        var fields: [String] = [d.id, d.toolType.rawValue, String(d.anchors.count)]
        for a in d.anchors {
            fields.append(String(a.candleIndex)); fields.append(String(a.price)); fields.append(a.period.rawValue)
        }
        fields.append(contentsOf: [
            d.period.rawValue, d.lineSubType.rawValue, d.lineStyle.rawValue, String(d.thickness),
            d.colorToken.rawValue, d.labelMode.rawValue, String(d.locked),
            d.text, String(d.fontSize), d.textColorToken.rawValue, d.textForm.rawValue,
            String(d.tailAnchor != nil),                       // 区分 tailAnchor==nil 与「有但字段恰好空」
            d.tailAnchor.map { "\($0.candleIndex),\($0.price),\($0.period.rawValue)" } ?? "",
            String(d.isExtended), String(d.panelPosition), String(d.revealTick),
        ])
        return fields.map(lp).joined()
    }.map(lp).joined()                                          // 每条再 lp()：条边界也无歧义
}
```

> **未来 unknown 元素身份**（spec D56 提「+ unknown 元素身份」）：本切片 replay 路径的 baseline 取自 `engine.drawings`（已解码），unknown 条不在 `engine.drawings` 里（它们在 `loadedDrawingsLossy` 的 `.unknownRaw`，replay clean-skip 只比较 `engine.drawings` 的净状态）。unknown 条在 replay 会话内不可编辑/不可增删（无 UI 通道），故其身份在 baseline 与当前之间恒等、不影响签名比较——本切片不纳入签名。**若 PR-2 之后出现能动 unknown 条的路径，须回补**（列 PR-2 交接）。

- [ ] **Step 4: 运行签名测试确认通过**

Run: `cd ios/Contracts && swift test --filter canonicalSignatureSemantics 2>&1 | tail -20`
Expected: PASS。

- [ ] **Step 5: 写 clean-skip 失败测试（两条本切片 + 一条交接 PR-2，codex plan-R1-F1）**

> ⚠️ **codex plan-R1-F1 抓到我上一版的两处实问题**：(1) 只写了 append+delete 一条，漏了主 bug（count 漏改样式）的反例；(2) 用了不存在的测试 helper（`replaceDrawingsForTesting`/`withThicknessForTesting`）。修正：**用现有 API 制造判别力**，本切片落**两条**（①钉 count、②钉 revision），第三条（非规范 raw edit+revert 钉字节）**依赖 PR-2 的 lossy merge 路径**（本切片没有原地编辑→loadedDrawingsLossy 重序列化的通道，制造不出「字节≠但语义==」的状态），**交接 PR-2**（见 Task 5 交接注记）。

**关键技巧（用现有 API 制造「同 count 但内容变」）**：`baseline = [A]` → `appendDrawing(B)` → `[A,B]` → `deleteDrawing(at: 0)` → **`[B]`**。count 从 1 回到 1（==baseline count），但**内容从 [A] 变成 [B]**（签名变）。这对 count-only 实现「先红」，无需任何测试专用 helper。

前提搭建：两条都需要 `!replayHasPersisted` 的 replay 会话、`engine.drawings` **有一条已有线** `A` 作 baseline。fresh `replay(recordId:)` 不种画线（母 spec §6.3 0b），故 baseline-有线态**须注入构造**——按本文件既有 replay 持久化测试的搭建方式：构造 coord + fake 存储，用 `appendDrawing` 把 `A` 放进去后**重置 baseline 快照**（模拟「加载时 A 已在、且 A 即 baseline」），再置 `replayHasPersisted = false`。`debugReplaySlotWritten` 若无现成探针，用 fake 存储的写入计数等价断言（`saveProgress` 后 fake 的 replay-slot 写入次数）。

```swift
// ① 同 count 但内容变 → 必须写盘。★对当前 count 实现「先红」——count 回 baseline→skip→没写盘→本断言失败。
@Test("replay clean-skip ①: 同count内容变(A→B)→签名变→写盘（钉死 count 漏改内容）")
@MainActor func replayCleanSkip_sameCountContentChangeWrites() async throws {
    let (coord, engine) = try makeReplaySessionWithBaselineA()   // !replayHasPersisted，drawings=[A]，baseline 快照=当前
    let B = makeHLine(id: "B", candleIndex: 9, price: 8)
    _ = engine.appendDrawing(B)                                  // [A,B]
    engine.deleteDrawing(at: 0)                                  // [B]：count 回 1==baseline，但内容 A→B
    try await coord.saveProgress(engine: engine)
    #expect(coord.debugReplaySlotWritten == true)               // 签名变→不 skip→写盘
}

// ② append+delete 回 baseline（净状态==baseline）→ 必须 skip。对 revision 实现红（revision+2≠baseline 误写）。
@Test("replay clean-skip ②: append+delete 同一条回 baseline→签名==baseline→skip（钉死 revision 单调）")
@MainActor func replayCleanSkip_appendDeleteSameSkips() async throws {
    let (coord, engine) = try makeReplaySessionWithBaselineA()   // drawings=[A]
    let B = makeHLine(id: "B", candleIndex: 9, price: 8)
    _ = engine.appendDrawing(B)                                  // [A,B]
    engine.deleteDrawing(at: engine.drawings.count - 1)          // 删掉刚 append 的 B → 回 [A]==baseline，但 revision+2
    try await coord.saveProgress(engine: engine)
    #expect(coord.debugReplaySlotWritten == false)              // 签名==baseline→skip（不覆盖别的记录）
}
```

> `makeReplaySessionWithBaselineA` / `debugReplaySlotWritten`：本文件若无对应 helper，按既有 replay 持久化测试的搭建 + fake 存储写入计数实现等价物。**只用生产 API**（`appendDrawing`/`deleteDrawing(at:)`），不引入测试专用 mutator。

- [ ] **Step 6: 运行确认①先红**

Run: `cd ios/Contracts && swift test --filter "replayCleanSkip_sameCountContentChangeWrites" 2>&1 | tail -30`
Expected: **FAIL**（当前 clean-skip 按 count：`[A]`→`[B]` 后 count 仍 1==baseline → clean-skip 跳过 → 未写盘 → `debugReplaySlotWritten == true` 断言失败）。**这一条先红证明测试真能抓 count 漏改内容的 bug**。② 此刻已绿（count 实现对 append+delete 恰好也 skip），其判别力在换签名后对 revision 实现才显现——两条都保留，Step 8 后全绿锁死正解。

- [ ] **Step 7: 换 `replayBaseline` 类型 + clean-skip 判据**

`:56` 类型：

```swift
    @ObservationIgnored private var replayBaseline: (tick: Int, ops: Int, drawingsSig: String, upper: Period, lower: Period)?
```

三处赋值（`:581` fresh、`:934` resume）第三分量 `engine.drawings.count` → `canonicalDrawingsSignature(engine.drawings)`：

```swift
            replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count,
                              canonicalDrawingsSignature(engine.drawings),
                              engine.upperPanel.period, engine.lowerPanel.period)
```

clean-skip 判据（`:606-614`）第三行 `base.drawings == engine.drawings.count` →

```swift
               base.drawingsSig == canonicalDrawingsSignature(engine.drawings),
```

（`:974` 的 `replayBaseline = nil` reset 不变。）

- [ ] **Step 8: 运行全部相关测试确认通过（①②换签名后都绿）**

Run: `cd ios/Contracts && swift test --filter "replayCleanSkip|canonicalSignature|Replay|replay" 2>&1 | tail -30`
Expected: 全 PASS——①（同 count 内容变→写盘）与②（append+delete 回 baseline→skip）**都绿**，且既有 replay 持久化测试全绿（若某条钉了 `replayBaseline` 元组形状/count 语义，同步更新为签名语义）。

- [ ] **Step 9: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift
git commit -m "划线 1b-i 切片1 Task3：replay clean-skip 改净状态语义签名（D56，非 count/非 revision/非 raw 字节）"
```

---

### Task 4: 选择态显式 `mode`（`DrawingSession`）+ 现有消费点守卫

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`（加 `mode`/`setMode` + `activate`/`addAnchor`/`commitPending`/`deactivate` 守卫）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`（追加）

**Interfaces:**
- Produces: `DrawingSession.mode: DrawingSessionMode`（`public private(set)`，初值 `.draw`）；`DrawingSessionMode { case draw, select }`（public enum）；`setMode(_:)`（internal mutator）。
- 不变量（D57）：会话存活期间 `activeDrawingTool` 恒非 nil；`addAnchor`/`commitPending` 仅在 `mode == .draw` 生效；`deactivate` 复位 `mode = .draw`。
- 交接 PR-3：`restoreDrawingSessionAfterPeriodChange` 的 guard 现在恒成立（不早退），本切片不动它；选中清空留 PR-3。

- [ ] **Step 1: 写失败测试（N10 三清语义差分）**

```swift
@Test("N10: setMode(.select)/discardPendingAnchors/deactivate 三清语义互不混用")
@MainActor func modeMutatorsAreDistinct() {
    let s = DrawingSession()
    s.activate(tool: .horizontal)
    s.addAnchor(DrawingAnchor(candleIndex: 1, price: 5, period: .daily), panel: .upper)
    // setMode(.select)：mode→.select，drawingModeActive 不变(true)，activeDrawingTool 不变(非nil)，pending 清
    s.setMode(.select)
    #expect(s.mode == .select)
    #expect(s.drawingModeActive == true)
    #expect(s.activeDrawingTool == .horizontal)
    #expect(s.pendingAnchors.isEmpty)
    // 选择态不落锚（D57）：addAnchor no-op
    s.addAnchor(DrawingAnchor(candleIndex: 2, price: 6, period: .daily), panel: .upper)
    #expect(s.pendingAnchors.isEmpty)
    // deactivate：mode 复位 .draw，drawingModeActive→false，activeDrawingTool→nil
    s.deactivate()
    #expect(s.mode == .draw)
    #expect(s.drawingModeActive == false)
    #expect(s.activeDrawingTool == nil)
}

@Test("D57: 选择态下再点亮同一工具 → 切回 .draw（mode 赋值在幂等 guard 之前）")
@MainActor func reArmSameToolReturnsToDraw() {
    let s = DrawingSession()
    s.activate(tool: .horizontal)
    s.setMode(.select)
    s.activate(tool: .horizontal)      // 同工具：幂等 guard 会 early-return，但 mode 必须已切回 .draw
    #expect(s.mode == .draw)
    #expect(s.activeDrawingTool == .horizontal)
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter "modeMutatorsAreDistinct|reArmSameTool" 2>&1 | tail -20`
Expected: 编译失败 `has no member 'mode'` / `'setMode'`。

- [ ] **Step 3: 加 `mode`/`setMode` + 改四个 mutator**

`DrawingSession.swift` 加类型与字段（紧邻 `activeDrawingTool` 声明）：

```swift
    /// D57（1b-i）：画线态/选择态显式区分。取代母 spec 用 `activeDrawingTool == nil` 编码——
    /// nil 编码会让 `restoreDrawingSessionAfterPeriodChange` 的 guard 在选择态早退→裂脑（codex R1）。
    /// 会话存活期间 `activeDrawingTool` 恒非 nil；nil 重回唯一含义「没有会话」。
    public enum DrawingSessionMode: Equatable, Sendable { case draw, select }
    public private(set) var mode: DrawingSessionMode = .draw

    /// D57：切换画线/选择态。切 `.select` 保留 activeDrawingTool、丢 pending（半成品多锚线不跨态存活）。
    /// internal（同容器 mutator 纪律）。
    func setMode(_ m: DrawingSessionMode) {
        mode = m
        discardPendingAnchors()
    }
```

`activate`（`:92-97`）——**`mode = .draw` 必须在幂等 guard 之前**（否则选择态下再点亮同工具会被吞、态切不回）：

```swift
    func activate(tool: DrawingToolType) {
        drawingModeActive = true
        mode = .draw                              // ← 在幂等 guard 之前（D57，否则选择态点回同工具态切不回）
        guard activeDrawingTool != tool else { return }
        activeDrawingTool = tool
        discardPendingAnchors()
    }
```

`addAnchor`（`:118-125`）追加 `mode == .draw`：

```swift
    func addAnchor(_ anchor: DrawingAnchor, panel: PanelId) {
        guard drawingModeActive, activeDrawingTool != nil, mode == .draw else { return }   // 选择态恒不落锚
        if let owner = pendingAnchorPanel, owner != panel { discardPendingAnchors() }
        pendingAnchors.append(anchor)
        pendingAnchorPanel = panel
    }
```

`commitPending`（`:135-136`）guard 追加 `mode == .draw`：

```swift
    func commitPending(panelPosition: Int) -> DrawingObject? {
        guard mode == .draw, let tool = activeDrawingTool, !pendingAnchors.isEmpty else { return nil }
        // ...（其余不变）
```

`deactivate`（`:101-106`）追加 `mode = .draw` 复位：

```swift
    func deactivate() {
        drawingModeActive = false
        activeDrawingTool = nil
        mode = .draw                              // 复位，防下次开会话继承旧态
        discardPendingAnchors()
        clearAllShields()
    }
```

- [ ] **Step 4: 运行确认通过**

Run: `cd ios/Contracts && swift test --filter "modeMutatorsAreDistinct|reArmSameTool" 2>&1 | tail -20`
Expected: 2 tests PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift
git commit -m "划线 1b-i 切片1 Task4：DrawingSession 选择态显式 mode + 四 mutator 守卫（D57）"
```

---

### Task 5: 切片全绿 + 交接记录

- [ ] **Step 1: 全量 host 测试**

Run: `cd ios/Contracts && echo "BRANCH=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5`
Expected: `Test run with <N> tests ... passed`，N ≥ 1661 + 本切片新增测试数，0 failures。

- [ ] **Step 2: 交接注记（写入 PR body 草稿）**

在 `.superpowers/sdd/PR-body-1b-i-slice1.md` 记本切片交付 + 交接 PR-2 的三条：
1. **`drawingsRevision` 的「每 API +=1」还差 update/delete(id:)**（PR-2 建它们时同步 +=1，并补 N20b/N21 的 revision 断言）。
2. **replay 签名的 unknown 元素身份**：本切片未纳入（replay 会话内 unknown 条不可动）；PR-2 若引入能动 unknown 条的路径须回补。
2b. **replay clean-skip 测试③（非规范 raw edit+revert → skip，spec N22b2）留 PR-2**：本切片没有「原地编辑→`loadedDrawingsLossy` 重序列化」的通道，制造不出「字节≠但语义==」的状态；PR-2 建 `updateDrawingStyle` + lossy merge 后补这条，钉死「clean-skip 别退回用 `encoded()` 字节」（codex plan-R1-F1 明列）。
3. **选中清空**（D57 附「切周期善后追加清空选中」）留 PR-3（本切片无 selectedDrawingID）。

- [ ] **Step 3: 提交**

```bash
git add .superpowers/sdd/PR-body-1b-i-slice1.md
git commit -m "划线 1b-i 切片1 收尾：全绿 + PR-2/3 交接注记"
```

---

## Self-Review

**1. Spec coverage（本切片范围 = D56 + D57）：**
- D56 `drawingsRevision` 字段 → Task 1 ✓；autosave 触发器 → Task 2 ✓；replay clean-skip 净状态签名（非 count/revision/raw 字节）→ Task 3 ✓；「只覆盖 drawings 不覆盖 reviewDrawings」→ Task 1 测试 ✓。
- D57 显式 mode + 四 mutator 守卫 + `activate` 的 mode 赋值在幂等 guard 前 → Task 4 ✓；N10 三清语义 → Task 4 测试 ✓。
- **本切片不做**（留后续，已在交接注记）：update/delete(id:) 的 +=1（PR-2）；selectedDrawingID/选中清空（PR-3）；handleDrawingTap 分态派发（PR-3/4）；`restoreDrawingSessionAfterPeriodChange` 追加清空选中（PR-3）。

**2. Placeholder scan：** 无 TBD/TODO。测试里对「既有 helper（`makeForTesting`/`makeReplaySessionWithBaselineA`/`trainingViewPath`/`debugReplaySlotWritten`）签名不确定」处，已显式标注「以本文件既有用法为准」并给对齐方式——非占位，是对既有测试设施的显式对接约束（`makeReplaySessionWithBaselineA` 只用生产 API 搭建，不引入测试专用 mutator）。

**3. Type consistency：** `drawingsRevision: Int`（Task1 定义→Task3 replay 测试引用一致）；`DrawingSessionMode`/`mode`/`setMode`（Task4 定义，PR-3/4 消费）；`canonicalDrawingsSignature(_:) -> String`（Task3 定义→replayBaseline 第三分量 `drawingsSig: String` 一致）；`replayBaseline` 元组三分量由 `Int` 改 `String` 三处赋值 + 一处比较全部同步（Task3 Step7）。
