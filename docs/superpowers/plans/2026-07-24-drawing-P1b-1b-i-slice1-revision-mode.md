# 划线 P1b-1b-i 切片1（引擎状态地基：drawingsRevision + replay 净状态签名 + 选择态 mode + append 信任边界）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 1b-i「选中/编辑/删除」铺四块引擎/会话状态地基——内容级 dirty 计数器 `drawingsRevision`、replay clean-skip 改用净状态语义签名、选择态显式 `mode`、append 家族信任边界（关 public bypass）——全部零 UI、host `swift test` 全覆盖。

**Architecture:** 四块都落在既有 `TrainingEngine` / `TrainingSessionCoordinator` / `DrawingSession` 上。`drawingsRevision` 是单调计数器驱动 autosave；replay clean-skip 从「drawing 计数相等」升级为「drawing 规范语义签名相等」；`DrawingSession.mode` 用 `.draw|.select` 显式区分两态，取代母 spec 用 `activeDrawingTool == nil` 的编码；append 家族（`appendDrawing`/`appendReviewDrawing`/`routeDrawingCommit`/`deleteDrawing(at:)`/`removeReviewDrawing(at:)`）降 `internal` + 源码守卫 + 引擎层 `.segment` 门，与后续 PR 的 `updateDrawingStyle`/`deleteDrawing(id:)` 同属信任边界模式——**本切片就关闭 public bypass，不留中间态暴露窗口**（codex plan-R3-F1）。后续切片（PR-2 写入边界 API / PR-3 命中渲染 / PR-4 交互 UI）都建在这四块之上。

**Tech Stack:** Swift 5.9 / `@Observable` / SwiftPM（`ios/Contracts`）；测试 `swift test`（host，macOS）；跨平台纯逻辑（无 UIKit）。

## Global Constraints

- `CONTRACT_VERSION` 保持 **1.12**，`user_version` 保持 **7**，**零迁移**（本切片不新增/不改任何持久化字段；`drawingsRevision` 是运行时计数器、`mode` 是运行时状态，都不进存储）。
- **完整 spec**：`docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（决策 D49–D67，本切片落 **D56 / D57 / D67**）。
- **访问级别纪律**：`DrawingSession` 的所有 mutator 一律 `internal`，不加 `public`（顶部 `:21-28` 大注释写明理由）。新增 `setMode` 遵守。
- **测试基线**：本机 `swift test` 全绿基线 = **1661 passed**（base `d2754df`）。每个 Task 结束时全绿。
- **禁止**改用 `.onChange(of: engine.drawings)` 或任何数组值比较：`DrawingObject.==` 排除 `id`（D56）。

---

## 测试 fixture（本切片各测试共用，codex plan-R2-F2）

`DrawingObject.init` **要求** `isExtended: Bool` 与 `panelPosition: Int`（`Models/Models.swift:265-274`，**无默认值**）。为免每处测试重复这两个参数、也免片段编译失败，本切片所有测试用统一 fixture 造水平线。

⚠️ **放在单一共享文件 `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift`，只声明一次**（codex plan-R4-F1）——**不得**在每个测试文件顶部各放一份：`makeHLine` 是 non-private 顶层函数，同一 test module（`KlineTrainerContractsTests`）内多文件重复声明同名符号会**重复定义编译失败**。该文件与其它测试同属一个 target、自动编译进 `swift test`，各测试文件直接调 `makeHLine(...)` 即可（同 module 无需 import）。

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift
// ⚠️ Swift import 是文件级的（codex plan-R6-F1）：别的测试文件的 import 不让符号在这里可见，本文件必须自带。
@testable import KlineTrainerContracts

// 造一条水平线 DrawingObject，只传关心的字段，其余取默认/固定（isExtended:false, panelPosition:0）。
func makeHLine(id: String = "hl", candleIndex: Int = 3, price: Double = 10,
               period: Period = .daily, thickness: Int = 1, text: String = "") -> DrawingObject {
    DrawingObject(id: id, toolType: .horizontal,
                  anchors: [DrawingAnchor(period: period, candleIndex: candleIndex, price: price)],
                  isExtended: false, panelPosition: 0, period: period, thickness: thickness, text: text)
}
```

> **`DrawingAnchor.init` 的 label 顺序是 `(period:candleIndex:price:)`**（`Models/Models.swift:214` 实测，codex plan-R2-F2/R3-F2）——**不是** `(candleIndex:price:period:)`，全文片段一律按此（上方 fixture 已按此写）。所有下文测试片段里的 `makeHLine(...)` 都指本 fixture；**不再出现裸 `DrawingObject(...)`**（避免漏 `isExtended`/`panelPosition` 编译失败）。

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
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（`replayBaseline` 类型 `:56` + 三处赋值 `:581`/`:934`/`:974` + clean-skip 判据 `:606-614` + `#if DEBUG` 区 `:176-200` 加 `recaptureReplayBaselineForTesting`）
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift`（规范签名纯函数）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift`（共享 `makeHLine`，单一声明，见「测试 fixture」节）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift`（既有 replay 持久化测试文件，追加签名 + clean-skip 测试）

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

**前提搭建须用测试 hook，不能只靠生产 API（codex plan-R4-F2 纠正我上一版）**：两条都要 `!replayHasPersisted` 的 replay 会话、`engine.drawings` **有一条已有线** `A` 作 baseline。但 fresh `replay(recordId:)` **不种画线**（母 spec §6.3 0b，`engine.drawings` 恒空 → baseline 恒 `sig([])`）；若在 `replay` 之后再 `appendDrawing(A)`，baseline 早已 capture 了「空」，① 的 `[A]→[B]` 就退化成「空 vs [B]」（count 0≠1），连 count 实现也写盘 → ① 失去判别力（codex 精确指出）。故**必须用测试 hook 让 baseline 真的含 A**：

> **Task 3 顺带加一个 `#if DEBUG` 测试 hook**（`TrainingSessionCoordinator` 已有此范式：`:176-200` 的 `drainAutosaveForTesting`/`setActiveRecordNilForTesting`/`setReviewSessionForTesting`）：
> ```swift
> #if DEBUG
> /// 测试专用：把 replay baseline 重新捕获为 engine 当前净状态（供「baseline 含 A」的 clean-skip 回归；
> /// fresh replay 不种画线，生产路径构造不出 baseline-有线态）。镜像既有 xxxForTesting 范式。
> func recaptureReplayBaselineForTesting(_ engine: TrainingEngine) {
>     replayBaseline = (engine.tick.globalTickIndex, engine.tradeOperations.count,
>                       canonicalDrawingsSignature(engine.drawings),
>                       engine.upperPanel.period, engine.lowerPanel.period)
> }
> #endif
> ```
> `makeReplaySessionWithBaselineA()` 因此这样搭：`replay(recordId:)` 建完整会话（active 上下文齐、`replayHasPersisted=false`）→ `appendDrawing(A)` 使 `drawings=[A]` → `recaptureReplayBaselineForTesting(engine)` 使 baseline=`sig([A])` → 返回 `(coord, engine)`。**先断言 baseline 已含 A**（下方每条测试起手可加 `#expect` 校验 setup 正确，再动作）。`debugReplaySlotWritten` 用 fake 存储的 replay-slot 写入计数（`saveProgress` 后 >0 即写）。

```swift
// ① 同 count 但内容变 → 必须写盘。★对当前 count 实现「先红」——count 回 baseline→skip→没写盘→本断言失败。
@Test("replay clean-skip ①: 同count内容变(A→B)→签名变→写盘（钉死 count 漏改内容）")
@MainActor func replayCleanSkip_sameCountContentChangeWrites() async throws {
    let (coord, engine, replayRepo) = try await makeReplaySessionWithBaselineA()   // !replayHasPersisted，drawings=[A]
    let c0 = replayRepo.saveCount
    let B = makeHLine(id: "B", candleIndex: 9, price: 8)
    _ = engine.appendDrawing(B)                                  // [A,B]
    engine.deleteDrawing(at: 0)                                  // [B]：count 回 1==baseline，但内容 A→B
    try await coord.saveProgress(engine: engine)
    #expect(replayRepo.saveCount == c0 + 1)                      // 签名变→不 skip→真的 saveReplay 一次
}

// ② append+delete 回 baseline（净状态==baseline）→ 必须 skip。对 revision 实现红（revision+2≠baseline 误写）。
@Test("replay clean-skip ②: append+delete 同一条回 baseline→签名==baseline→skip（钉死 revision 单调）")
@MainActor func replayCleanSkip_appendDeleteSameSkips() async throws {
    let (coord, engine, replayRepo) = try await makeReplaySessionWithBaselineA()   // drawings=[A]
    let c0 = replayRepo.saveCount
    let B = makeHLine(id: "B", candleIndex: 9, price: 8)
    _ = engine.appendDrawing(B)                                  // [A,B]
    engine.deleteDrawing(at: engine.drawings.count - 1)          // 删掉刚 append 的 B → 回 [A]==baseline，但 revision+2
    try await coord.saveProgress(engine: engine)
    #expect(replayRepo.saveCount == c0)                         // 签名==baseline→skip→无 saveReplay（不覆盖别的记录）
}
```

> **写入探针用既有 fake 的 `saveCount`，不编造 `debugReplaySlotWritten`（codex plan-R7-F2）**：`InMemoryPendingReplayRepository`（`Sources/.../PreviewFakes/InMemoryFakes.swift:180`）已有 `public var saveCount`（`:200`），`saveReplay(_:)`（`:204`）每次 `_saveCount += 1`；既有测试 `CoordinatorReplayPersistenceTests.saveProgress_replay_writesPendingReplay` 已在用这套。故 `makeReplaySessionWithBaselineA()` **返回三元组 `(coord, engine, replayRepo: InMemoryPendingReplayRepository)`**（该 repo 就是搭 coord 时注入的那个 fake），测试比较 `saveProgress` 前后的 `saveCount` delta（+1=写盘，不变=skip）。
> `makeReplaySessionWithBaselineA`：`replay(recordId:)` 建完整会话（active 上下文齐、`replayHasPersisted=false`）→ `appendDrawing(A)` 使 `drawings=[A]` → `recaptureReplayBaselineForTesting(engine)` 使 baseline=`sig([A])` → 返回 `(coord, engine, replayRepo)`。动作步骤（append B / delete）用生产 API；**baseline 构造须用 DEBUG hook**——fresh replay 不种画线的必然，不是可省纪律（codex plan-R4-F2）。

- [ ] **Step 6: 运行确认①先红**

Run: `cd ios/Contracts && swift test --filter "replayCleanSkip_sameCountContentChangeWrites" 2>&1 | tail -30`
Expected: **FAIL**（当前 clean-skip 按 count：`[A]`→`[B]` 后 count 仍 1==baseline → clean-skip 跳过 → 未 `saveReplay` → `saveCount` 不增 → `saveCount == c0 + 1` 断言失败）。**这一条先红证明测试真能抓 count 漏改内容的 bug**。② 此刻已绿（count 实现对 append+delete 恰好也 skip），其判别力在换签名后对 revision 实现才显现——两条都保留，Step 8 后全绿锁死正解。

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
    s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 1, price: 5), panel: .upper)
    // setMode(.select)：mode→.select，drawingModeActive 不变(true)，activeDrawingTool 不变(非nil)，pending 清
    s.setMode(.select)
    #expect(s.mode == .select)
    #expect(s.drawingModeActive == true)
    #expect(s.activeDrawingTool == .horizontal)
    #expect(s.pendingAnchors.isEmpty)
    // 选择态不落锚（D57）：addAnchor no-op
    s.addAnchor(DrawingAnchor(period: .daily, candleIndex: 2, price: 6), panel: .upper)
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

### Task 5: append 家族信任边界（D67 + D66 append 部分）——降 internal + 源码守卫（调用图）+ 引擎层 `.segment` + id 门

> **codex plan-R3-F1**：Task 1 让 `appendDrawing`/`deleteDrawing(at:)` 成为新 revision/autosave 路径，但它们仍 `public`。若本切片单独 merge，就 ship 了 spec D67 要关闭的 public 破坏性入口（包外可绕过 geometry/locked/id/future-enum 门落幽灵线）。D67 是「引擎写入边界地基」，与 revision 同属本切片，**在此关闭**（不留到 PR-2 的中间态暴露窗口）。

#### 完整 mutation-surface 审计（codex plan-R5→R8 逐个补了我漏的成员，这里一次列全，防再漏）

对 `TrainingEngine` **全部会写 `drawings`/`reviewDrawings` 的 `public` 方法**做过 `grep public func`（本切片开工亲核），共 **7 个** public 写入面，按「编辑单条」vs「整体装载」分类——两类处置不同：

| public 写入面 | 写什么 | 类别 | 处置 | 生产调用点 |
|---|---|---|---|---|
| `appendDrawing` | `drawings` 追加 | 编辑 | internal + `.segment` + id 门 | `routeDrawingCommit`（`:1144`） |
| `deleteDrawing(at:)` | `drawings` index 删 | 编辑 | internal | **零** |
| `appendReviewDrawing` | `reviewDrawings` 追加 | 编辑 | internal + `.segment` + id 门 | `routeDrawingCommit`（`:1142`） |
| `removeReviewDrawing(at:)` | `reviewDrawings` index 删 | 编辑 | internal | **零** |
| `routeDrawingCommit` | 路由 → append | 提交路由 | internal | `ChartContainerView.handleDrawingTap`（`:304`，geometry 门所在） |
| `setReviewLossy` | `reviewDrawings` **整体替换** | **装载** | internal，**不加门** | `TrainingSessionCoordinator`（`:538`，复盘装载） |
| `setReviewDrawings` | 调 `setReviewLossy` | **装载** | internal，**不加门** | **零**（Sources/ 内；测试经 `@testable` 调） |

- **编辑入口**（前 4 + 路由）：受数据门（`.segment`/id）+ 唯一调用点守卫。
- **装载入口**（`setReviewLossy`/`setReviewDrawings`）：**只降访问级别、不加门**——它们从存储整体装载复盘工作态，加 `.segment`/id 门会**拒掉合法历史数据**（同 D52/D61「装载 fail-closed 会静默吞用户画的线」）；codex R8 的点是**访问级别**（`public` → 包外可整体注入/擦除 `reviewDrawings`），降 internal 即封住，**app target 实测无调用**（`ios/KlineTrainer/` grep 零命中）。
- `self.drawings = …`（`:173` init 内部）不是 `public` 方法、不算 surface；`setReviewDrawingsForTesting`（`:1330`）已是 internal 测试专用。
- **N23a 覆盖全 7 个**（非 public + 各自的调用点约束），谁将来加个旁路调用点立即红——**这条调用图守卫是完备性的真正防线，不靠我手工列全**。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（**7 个 public 写入面全降 `internal`**：编辑入口 `appendDrawing`/`appendReviewDrawing`/`routeDrawingCommit`/`deleteDrawing(at:)`/`removeReviewDrawing(at:)` + 装载入口 `setReviewLossy`/`setReviewDrawings`；其中 `appendDrawing`/`appendReviewDrawing` 加 `.segment` + id 门，装载入口**不加门**）
- **Modify（既有测试，降 internal 会破坏它，codex plan-R6-F2）**：`ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift`（`atomicStyleConstruction` 的锚 `public func routeDrawingCommit` → `func routeDrawingCommit`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（N23a/b/d）

**Interfaces:**
- 实测生产链唯一（本切片开工前已核）：`ChartContainerView.handleDrawingTap:303`（有 `visibleGeometry` 门）→ `routeDrawingCommit:304` → `appendDrawing:1144`/`appendReviewDrawing:1142`；`deleteDrawing(at:)` 与 **`removeReviewDrawing(at:)`（`:1120`）均零生产调用点**。故这**五者**降 `internal` **零生产影响**；测试经 `@testable import` 照常可调。
- ⚠️ **`removeReviewDrawing(at:)` 也必须纳入（codex plan-R7-F1）**：它是对 `reviewDrawings` 的 index 破坏性删除，且 `TrainingView` autosave 盯 `reviewDrawings.count`——若留 `public`，包外可按 index 删复盘工作画线、绕过任何 id/geometry/ownership 门，造成不可逆复盘数据丢失。与 `drawings` 侧的 `deleteDrawing(at:)` 完全对称。（id-based 的复盘删除守卫 API 是 P5 复盘编辑的事，本切片只关这个 public 破坏性入口。）
- ⚠️ **既有源码守卫会因降 internal 而红**（codex plan-R6-F2）：`DrawingSessionSourceGuardTests.atomicStyleConstruction`（`:176`/`:178`）用 `public func routeDrawingCommit` 定位函数体做「无 append-then-replace」断言；降 internal 后 `:176` 的 `#require` 找不到 → 测试红（即使生产代码对）。**Step 3 必须同步更新这个锚**，否则 Step 6 全绿门挂在既有测试上。
- 引擎层 `.segment` 门：`appendDrawing`/`appendReviewDrawing` 拒「该 `toolType` 恒不可渲染」的 `lineSubType`（水平线的 `.segment`），判据**复用 `DrawingStyleAvailability.horizontalLineSubTypeEnabled`**（与面板灰态同一真相，禁另写）。viewport 相关的越界 ray 只有 UI 路由能判，由「唯一调用点在 `:303` 门之后」源码守卫保证。

- [ ] **Step 1: 写失败测试（N23）**

```swift
@Test("N23b: appendDrawing/appendReviewDrawing 拒 .segment（引擎层，direct-call），不动 revision")
@MainActor func appendRejectsSegment() {
    let engine = TrainingEngine.makeForTesting()
    let seg = DrawingObject(id: "s", toolType: .horizontal,
                            anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                            isExtended: false, panelPosition: 0, period: .daily, lineSubType: .segment)
    let before = engine.drawingsRevision
    #expect(engine.appendDrawing(seg) == false)          // .segment 恒不可渲染 → 拒
    #expect(engine.drawings.isEmpty)
    #expect(engine.drawingsRevision == before)           // 拒绝不动 revision
    #expect(engine.appendReviewDrawing(seg) == false)
    #expect(engine.reviewDrawings.isEmpty)
}

@Test("N23d: appendDrawing/appendReviewDrawing 拒空 id / 重复 id，拒绝不动 revision（D66 append 部分，codex plan-R5-F1）")
@MainActor func appendRejectsEmptyAndDuplicateId() {
    let engine = TrainingEngine.makeForTesting()
    // 空 id → 拒
    let empty = makeHLine(id: "", candleIndex: 3, price: 10)
    #expect(engine.appendDrawing(empty) == false)
    #expect(engine.drawings.isEmpty)
    #expect(engine.drawingsRevision == 0)
    // 正常一条
    #expect(engine.appendDrawing(makeHLine(id: "A", candleIndex: 3, price: 10)) == true)
    let after1 = engine.drawingsRevision
    // 重复 id → 拒、不动 revision
    #expect(engine.appendDrawing(makeHLine(id: "A", candleIndex: 4, price: 11)) == false)
    #expect(engine.drawings.count == 1)
    #expect(engine.drawingsRevision == after1)
    // review 侧独立判 reviewDrawings：同 id "A" 在 review 侧应可接受（不同数组）
    #expect(engine.appendReviewDrawing(makeHLine(id: "A", candleIndex: 5, price: 12)) == true)
    // review 侧再来一条同 id → 拒
    #expect(engine.appendReviewDrawing(makeHLine(id: "A", candleIndex: 6, price: 13)) == false)
    #expect(engine.reviewDrawings.count == 1)
}

@Test("N23a: append 家族非 public + 唯一调用点（源码守卫，调用图 D67，codex plan-R5-F2）")
func appendFamilyTrustBoundary() throws {
    // (1) 访问级别：7 个 public 写入面全非 public（编辑 5 + 装载 2）
    let engineSrc = try String(contentsOfFile: trainingEnginePath, encoding: .utf8)
    for decl in ["appendDrawing(", "appendReviewDrawing(", "routeDrawingCommit(", "deleteDrawing(at ",
                 "removeReviewDrawing(at ", "setReviewLossy(", "setReviewDrawings("] {
        #expect(!engineSrc.contains("public func " + decl))
        #expect(engineSrc.contains("func " + decl))                       // 仍存在（internal）
    }
    // (2) 唯一调用点（**核心**：仅非 public 不够——包内新调用者仍能绕过 handleDrawingTap 的 geometry 门）。
    //     扫整个 Sources/，统计匹配 callPattern 的「调用」行（排除 defExclude 定义行与注释行）。
    //     ⚠️ callPattern 必须匹配【真实调用语法】（codex plan-R6-F3）：
    //        无标签调用 `xxx(...)` 用 "xxx("；带标签调用 `deleteDrawing(at: 0)` 用 "deleteDrawing(at:"（冒号），
    //        不能用 "deleteDrawing(at(" —— 那样永远匹配不到、守卫恒空恒过（假绿）。
    func callSites(callPattern: String, defExclude: String) throws -> [(file: String, line: String)] {
        try allSwiftFilesUnderSources().flatMap { path -> [(String, String)] in
            try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { line in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    return t.contains(callPattern) && !t.contains(defExclude) && !t.hasPrefix("//") && !t.hasPrefix("///")
                }
                .map { (path, $0) }
        }
    }
    // appendDrawing/appendReviewDrawing 各恰好 1 处调用（`appendDrawing(stamped)`），都在 routeDrawingCommit
    #expect(try callSites(callPattern: "appendDrawing(", defExclude: "func appendDrawing(").count == 1)
    #expect(try callSites(callPattern: "appendReviewDrawing(", defExclude: "func appendReviewDrawing(").count == 1)
    // routeDrawingCommit 恰好 1 处调用（`engine.routeDrawingCommit(committed)`），在 ChartContainerView.handleDrawingTap
    let route = try callSites(callPattern: "routeDrawingCommit(", defExclude: "func routeDrawingCommit(")
    #expect(route.count == 1)
    #expect(route.allSatisfy { $0.file.contains("ChartContainerView") })
    // deleteDrawing(at:) / removeReviewDrawing(at:) 零生产调用点（D51/D67）——调用语法带标签冒号 `xxx(at: 0)`；
    //   定义是 `func xxx(at index:`（`at ` 后无冒号），故 pattern `xxx(at:` 只命中调用、不命中定义。
    #expect(try callSites(callPattern: "deleteDrawing(at:", defExclude: "func deleteDrawing(at").isEmpty)
    #expect(try callSites(callPattern: "removeReviewDrawing(at:", defExclude: "func removeReviewDrawing(at").isEmpty)
    // 装载入口：setReviewLossy 只在 TrainingSessionCoordinator（复盘装载 :538）与 TrainingEngine
    //   （setReviewDrawings :315 委托调它）——不强求 count（委托是合法内部调用），只断言不在别处新增旁路。
    let reviewLossy = try callSites(callPattern: "setReviewLossy(", defExclude: "func setReviewLossy(")
    #expect(!reviewLossy.isEmpty)
    #expect(reviewLossy.allSatisfy { $0.file.contains("TrainingSessionCoordinator") || $0.file.contains("TrainingEngine") })
    // setReviewDrawings 零 Sources/ 调用点（其定义 :315 委托 setReviewLossy，被 defExclude 排除；测试经 @testable 调、不在 Sources/）
    #expect(try callSites(callPattern: "setReviewDrawings(", defExclude: "func setReviewDrawings(").isEmpty)
}
```

> - `trainingEnginePath` / `allSwiftFilesUnderSources()`：前者用本仓既有源码守卫测试的读取方式（同 `TrainingViewShellSourceGuardTests` 的 `String(contentsOfFile:)`）；后者 = 递归列 `Sources/KlineTrainerContracts/**/*.swift` 的 helper（用 `#filePath` 定位仓根后拼 `Sources/…`，或既有源码守卫测试若已有目录遍历 helper 则复用）。
> - **只测非 public 不够**（codex plan-R5-F2）：geometry 门在 `handleDrawingTap`，唯一调用点守卫才能保证 append 家族的写入必经那道门；新增旁路调用点 → 本测试的 `count == 1` 立即红。
> - N23c（视口外 ray 经真实 `handleDrawingTap` 被 `:303` 门挡）依赖 UIKit → 留 PR-3/4 的 Catalyst 层。

- [ ] **Step 2: 运行确认失败**

Run: `cd ios/Contracts && swift test --filter "appendRejectsSegment|appendRejectsEmptyAndDuplicateId|appendFamilyTrustBoundary" 2>&1 | tail -20`
Expected: `appendRejectsSegment` FAIL（当前 appendDrawing 只查 period、不拒 .segment → 返 true）；appendRejectsEmptyAndDuplicateId FAIL（当前 append 不判 id 唯一非空）+ appendFamilyTrustBoundary FAIL（当前四者 public）。

- [ ] **Step 3: 降 internal + 加 `.segment` 门**

`TrainingEngine.swift`：把 **7 个**声明的 `public` 去掉（改 `internal`）——编辑入口 `appendDrawing`/`appendReviewDrawing`/`routeDrawingCommit`/`deleteDrawing(at:)`/`removeReviewDrawing(at:)` + 装载入口 `setReviewLossy`/`setReviewDrawings`（后两者**只降级、不加任何门**，见审计表）。

**同步更新既有源码守卫（codex plan-R6-F2，缺此 Step 6 全绿门会挂）**：`DrawingSessionSourceGuardTests.swift` 的 `atomicStyleConstruction`——
- `:176` `e.range(of: "public func routeDrawingCommit")` → `e.range(of: "func routeDrawingCommit")`（定位函数体独立于访问级别）；
- `:178` 结尾锚若是 `"\n    public func"`：确认 `routeDrawingCommit` 之后紧邻的下一个函数仍 `public`（`commitDrawing` 等在降级列表**之外**，仍 public）→ 锚可保留；**若实测该锚也漂**（下一个函数恰好也非 public），改成 `"\n    func "`（匹配任意访问级别的下一个函数）。
- 该测试的「非 public」保证已由 N23a 的 `!engineSrc.contains("public func routeDrawingCommit(")` 覆盖，故此处只需让函数体定位不依赖访问级别，不必在本测试里再断言非 public。

`appendDrawing`（`:1088`）在 period 门后加 **`.segment` 门（D67）+ id 唯一非空门（D66）**：

```swift
    @discardableResult
    func appendDrawing(_ drawing: DrawingObject) -> Bool {
        guard isPeriodConsistent(drawing) else { return false }
        guard DrawingStyleAvailability.horizontalLineSubTypeEnabled(drawing.lineSubType) else { return false }  // D67：.segment 等恒不可渲染值拒
        guard !drawing.id.isEmpty, !drawings.contains(where: { $0.id == drawing.id }) else { return false }     // D66：id 非空 + 与目标数组唯一
        drawings.append(drawing)
        drawingsRevision += 1
        return true
    }
```

`appendReviewDrawing`（`:1099`）同加两门，但 id 唯一检查针对 **`reviewDrawings`**：
```swift
        guard DrawingStyleAvailability.horizontalLineSubTypeEnabled(drawing.lineSubType) else { return false }  // D67
        guard !drawing.id.isEmpty, !reviewDrawings.contains(where: { $0.id == drawing.id }) else { return false } // D66（对 reviewDrawings）
```

> - `DrawingStyleAvailability.horizontalLineSubTypeEnabled(_:)` 现有签名（`Drawing/DrawingStyleAvailability.swift:6`）：`.straight`/`.ray` 返 true、`.segment` 返 false。本切片只有 `.horizontal`，直接用；P1c 多工具再泛化（YAGNI）。
> - id 唯一非空是 D66 的 **append 部分**（`update/delete(id:)` 部分随它们在 PR-2）——codex plan-R5-F1：`LossyDrawingArray.reconciled` 对重复/空 id 已 fail-close，append 坏 id 会让后续 autosave 抛，且 id-based update/delete 会打错对象，故 append 边界必须挡在源头。

- [ ] **Step 4: 运行确认通过 + 既有调用点仍编译**

Run: `cd ios/Contracts && swift build 2>&1 | tail -5 && swift test --filter "appendRejectsSegment|appendRejectsEmptyAndDuplicateId|appendFamilyTrustBoundary" 2>&1 | tail -20`
Expected: build 无 error（`handleDrawingTap`/`routeDrawingCommit` 等包内调用点在 internal 下照常编译）；2 tests PASS。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift
git commit -m "划线 1b-i 切片1 Task5：append 家族降 internal + 源码守卫(调用图) + .segment/id 门（D67+D66 append），同步既有守卫锚"
```

---

### Task 6: 切片全绿 + 交接记录

- [ ] **Step 1: 全量 host 测试**

Run: `cd ios/Contracts && echo "BRANCH=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5`
Expected: `Test run with <N> tests ... passed`，N ≥ 1661 + 本切片新增测试数，0 failures。

- [ ] **Step 2: 交接注记（写入 PR body 草稿）**

在 `.superpowers/sdd/PR-body-1b-i-slice1.md` 记本切片交付（D56/D57/D67）+ 交接：
1. **`drawingsRevision` 的「每 API +=1」还差 update/delete(id:)**（PR-2 建它们时同步 +=1，并补 N20b/N21 的 revision 断言）。
2. **replay 签名的 unknown 元素身份**：本切片未纳入（replay 会话内 unknown 条不可动）；PR-2 若引入能动 unknown 条的路径须回补。
2b. **replay clean-skip 测试③（非规范 raw edit+revert → skip，spec N22b2）留 PR-2**：本切片没有「原地编辑→`loadedDrawingsLossy` 重序列化」的通道，制造不出「字节≠但语义==」的状态；PR-2 建 `updateDrawingStyle` + lossy merge 后补这条，钉死「clean-skip 别退回用 `encoded()` 字节」（codex plan-R1-F1 明列）。
3. **选中清空**（D57 附「切周期善后追加清空选中」）留 PR-3（本切片无 selectedDrawingID）。
4. **N23c（视口外 ray 经真实 `handleDrawingTap` 被 `:303` 门挡）留 Catalyst 层**（PR-3/4）：本切片 host 测不到 UI 路由；D67 的 append 家族降 internal + 源码守卫 + `.segment` 门本切片已落，仅 viewport 相关的 ray 越界回归须到有 UI 的切片补。
5. **PR-2 建 `updateDrawingStyle`/`deleteDrawing(id:)` 时纳入同一信任边界**（internal + 源码守卫 + 引擎层 locked/未来枚举/id 门），与本切片 D67 的 append 家族对齐——三类写入面统一（spec D67 表）。
6. **D66（id 唯一非空）只做了 append 部分**（本切片 append 家族已挡空/重复 id，N23d）；`update/delete(id:)` 的「匹配非唯一即 fail」+ N3/N4（id 不存在→返 false/清空选中）随它们在 PR-2。

- [ ] **Step 3: 提交**

```bash
git add .superpowers/sdd/PR-body-1b-i-slice1.md
git commit -m "划线 1b-i 切片1 收尾：全绿 + PR-2/3 交接注记"
```

---

## Self-Review

**1. Spec coverage（本切片范围 = D56 + D57 + D67）：**
- D56 `drawingsRevision` 字段 → Task 1 ✓；autosave 触发器 → Task 2 ✓；replay clean-skip 净状态签名（非 count/revision/raw 字节；签名单射长度前缀 + 碰撞回归）→ Task 3 ✓；「只覆盖 drawings 不覆盖 reviewDrawings」→ Task 1 测试 ✓。
- D57 显式 mode + 四 mutator 守卫 + `activate` 的 mode 赋值在幂等 guard 前 → Task 4 ✓；N10 三清语义 → Task 4 测试 ✓。
- D67 append 家族（含 removeReviewDrawing(at:)）降 internal + 源码守卫**调用图**（N23a：7 个 public 写入面全非 public + 唯一/零调用点，非仅访问级别）+ 引擎层 `.segment` 门（N23b）→ Task 5 ✓；**D66 append 部分**（id 唯一非空门，N23d）→ Task 5 ✓；N23c（视口外 ray）交接 Catalyst 层（本切片 host 测不到 UI 路由）。
- **本切片不做**（留后续，已在交接注记）：update/delete(id:) 的 +=1 与信任边界（PR-2）；selectedDrawingID/选中清空（PR-3）；handleDrawingTap 分态派发（PR-3/4）；`restoreDrawingSessionAfterPeriodChange` 追加清空选中（PR-3）；replay 测试③非规范 raw（PR-2）。

**2. Placeholder scan：** 无 TBD/TODO。测试里对「既有 helper（`makeForTesting`/`trainingViewPath`/`allSwiftFilesUnderSources`）签名不确定」处，已显式标注「以本文件既有用法为准」并给对齐方式——非占位，是对既有测试设施的显式对接约束。replay 写入探针用既有 fake 的 `saveCount`（非编造探针，codex plan-R7-F2）；`makeReplaySessionWithBaselineA` 返回 `(coord, engine, replayRepo)`，baseline 构造用 DEBUG hook `recaptureReplayBaselineForTesting`（fresh replay 不种画线的必然，非可省纪律）。

**3. Type consistency：** `drawingsRevision: Int`（Task1 定义→Task3 replay 测试引用一致）；`DrawingSessionMode`/`mode`/`setMode`（Task4 定义，PR-3/4 消费）；`canonicalDrawingsSignature(_:) -> String`（Task3 定义→replayBaseline 第三分量 `drawingsSig: String` 一致）；`replayBaseline` 元组三分量由 `Int` 改 `String` 三处赋值 + 一处比较全部同步（Task3 Step7）。
