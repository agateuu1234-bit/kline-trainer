# 划线 P1b-1b-ii PR-1（锁定 / 解锁）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让用户能锁定 / 解锁一条选中的划线 —— 底栏补 ②🔒，锁定后 🗑 与样式面板全灰、`locked` 随画线落盘；同时把「内容未变 = 零副作用」统一到写入 API 上（D80），为 PR-2 的撤销栈打地基。

**Architecture:** 新增引擎 API `setDrawingLocked(id:locked:)` 作为 `locked` 的**语义性写入唯一入口**（豁免 D60 的 locked 闸，否则锁上就解不开）；写入路由与可用性谓词加在既有 `DrawingEditRouter`（无 UIKit → host 可测），形状严格镜像已有的删除三件套；raw-preserving 由保存路径既有的 `mergeKnownFields` 免费提供，本 PR **不新建**合并机制，只写举证测试证明它成立。

**Tech Stack:** Swift 6 / swift-testing（`@Test` + `#expect`）· SwiftUI（`#if canImport(UIKit)` 门控）· SPM 包 `KlineTrainerContracts`

**Spec:** `docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md` §1（D68–D73 + D80），codex 对抗性评审 **R7 approve**（账本 `branch:drawing-tools-p1b-1b-ii@b8683c2ba9281104ab205acf59a68c7e18209cc1`）。

**基线（实测，2026-08-11）：** host `swift test` = **1803 tests passed**。分支 `drawing-tools-p1b-1b-ii`，base `origin/main` `567987b`。

---

## 评审收口记录（**codex 未 approve，user override —— 不得写成「已收敛」**）

**spec 阶段**：codex R1–R6 共 14 个 finding 全修 → **R7 自然 approve**，账本
`branch:drawing-tools-p1b-1b-ii@b8683c2ba9281104ab205acf59a68c7e18209cc1`（已 Read 文件核实 `head_sha` 与当时 HEAD 逐字一致，无 focus 窄化）。

**计划阶段**：P-R1–P-R5 共 11 个 finding，**前 10 个全真、全修**；**P-R5 仍是 `needs-attention`，账本未写**。
user 于 2026-08-11 拍板 **override 收口进实施**，理由三条：

1. **P-R5-F1 复述的是已接受残留**。它指的「高版本写的 `locked` 非水平线在本构建里既解不开也删不掉、且会让整局归不了档」，在 spec §4「残留②」（`:557-559`）**逐字记录在案**，连 `finalize` 会 throw 这个后果都写了 —— 而 **codex 自己在 spec 阶段 R7 approve 了含该残留的 spec**。本轮未提供任何新信息。按本仓既有判据，**重提已接受决策 = stop 信号**（1a-i R6 先例）。
2. **它开的药方超出 PR-1 边界**：「装渲染器 / 加版本门 / 加按 id 的管理通道」属 **P1c**。PR-1 是锁定切片（~140 行），拉进跨版本恢复会直接撑破「≤3 子项 ≤500 行」，并需重开一份已 approve 的 spec。
3. **可达性窄且自消解**：本构建**产不出**这种数据（只写 `.horizontal`），场景要求先存在一个更高版本；而那个更高版本即 P1c+，自带渲染器 → 选得中、解得开、删得掉，残留自然消失。App 未上架，不存在在野的 P1b 构建可供版本错位。

⚠️ **本 override 的边界**：仅覆盖「残留② 不在 PR-1 修」。**不覆盖**实施期新发现的任何缺陷 —— 实施中 codex / 内部 review 提出的新 finding 仍须照修。
⚠️ **PR 描述必须如实写明**：计划阶段收口时 codex verdict 为 `needs-attention`，非 approve。

---

## Global Constraints

以下每一条都是**所有 task 的隐含要求**，违反即判不合格。

### 硬性命名 / 形状约束（不照做守卫必红，实施者会误以为守卫坏了）

1. **`setDrawingLocked` 的第二个参数必须用 `newLocked` 作内部名**：
   `func setDrawingLocked(id: DrawingID, locked newLocked: Bool) -> Bool`
   **理由（非风格偏好）**：Task 4 的守卫判据是「`TrainingEngine.swift` 里形如 `locked: <非拷贝直传表达式>` 的位置恰好 1 处」，而拷贝直传排除名单含裸 `locked`。若参数内部名就叫 `locked`、构造时写 `locked: locked`，守卫会把它当拷贝直传**不计数** → 期望 1 实得 0 → **守卫在功能正确的情况下变红**。写 `locked: newLocked` 才能被数到。
2. **`setDrawingLocked` 内部必须就地构造 `DrawingObject`（18 个字段逐字段拷贝，只有 `locked` 取 `newLocked`），不得新增 `withLocked` 之类的 helper**。理由同上：helper 会把那处唯一的语义性写入挪出 `TrainingEngine.swift`，守卫的作用域与实现就对不上了。
3. **`setDrawingLocked` 必须是 `internal`**：不写 `public` / `package` / `open`，也不得放进 `public extension TrainingEngine`（成员会继承访问级别）。既有四个写入 API 全是 internal。
4. **禁止**用 `updateDrawingStyle` 改 `locked`（会被 D60 闸直接拒），也禁止在 `withStyle` 里碰 `locked`（该函数明写「本函数不碰 locked」）。

### 测试落位（写错位置会「找不到符号」，别以为是别的问题）

4b. 本 PR 复用的三组 helper **都是 `private`**，故新测试必须写进**同一个 suite 类型内**，不能新建文件：
   - `makeSelected(...)` / `mapper(...)` → `DrawingEditRouterTests.swift`（`:15` / `:30`）
   - `code(_:)` / `raw(_:)` → `DrawingInteractionUISourceGuardTests.swift`（`:14` / `:20`）
   - `CoordinatorTestHarness` → `CoordinatorReplayPersistenceTests.swift`（`:11`）
   反之，`SourceGuardScanner.swift` 与 `DrawingTestFixtures.swift` 里的是**顶层函数、不带 `private`**，跨文件可用 —— 新加的 helper 也**不得**加 `private`（Swift 顶层 `private` 是文件作用域，加了别的测试文件就调不到）。

### 判绿与验证纪律

5. **每条闸门命令必须同时打印 branch 与 HEAD**：
   `echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"`
6. **判绿读输出内容（`Test run with N tests ... passed` 那一行），不读管道后的退出码**。
7. **每条新测试都要做变异验证**：中和被测判据 → 看**那条具名测试**变红 → 复原。
   **复原一律用 `cp`**：`cp <file> /tmp/bak && ...改... && cp /tmp/bak <file>`。**绝不用 `git checkout <file>`**（会静默抹掉未提交改动）。
   变异验证由**控制者亲验**，不接受实施者自报「验过了」。
8. **写每一条测试时自问：「如果被测 API 换成空实现 / 恒返回 false，这条会红吗？」** 答不出「会」的，说明这条没有判别力，重写。
9. **一族全是「应该被拒绝」的断言必须配一条正向档**（健康输入必须被放行 + 断言取到的是哪个结果）—— 否则一个恒返回 `false` 的实现也会全绿。
10. **UIKit-gated 文件（`#if canImport(UIKit)`）在 host `swift test` 上根本不编译** → 涉及 `DrawingModeBar.swift` 的测试与其变异验证**必须上 Catalyst** `xcodebuild test`，不能只看 host 绿。

### 契约

11. `CONTRACT_VERSION` 保持 `"1.12"`、`user_version` 保持 `7`、**零迁移**。不新增字段、不扩展枚举值域。
12. **禁述**「1b-ii 已完成」——本 PR 只做锁定，撤销 / 前进属 PR-2。

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 修改 | 新增 `setDrawingLocked`；给 `updateDrawingStyle` 加 D80 的「内容未变」早退 |
| `Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift` | 修改 | 新增 `lockableIgnoringGeometry` / `canToggleLock` / `lockButtonEnabled` / `toggleLockSelected` |
| `Sources/KlineTrainerContracts/UI/DrawingModeBar.swift` | 修改 | 底栏插入 ②🔒（在①类型与③🗑 之间） |
| `Sources/KlineTrainerContracts/UI/TrainingView.swift:262-264` | 修改 | 给 `DrawingBottomBar` 传 `lockEnabled` / `lockIsOn` / `onToggleLock` |
| `Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift` | 修改 | 引擎门测试 + D80 + 信任边界守卫（镜像既有 N15） |
| `Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift` | 修改 | N14h 断言翻转 + raw-preserving 举证 |
| `Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift` | 修改 | 路由与谓词测试 |
| `Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift` | 修改 | 底栏 ②🔒 的源码守卫 |

**既有可复用资产（不要重写）**：`Tests/.../SourceGuardScanner.swift` 顶层函数 `expectEngineInternalOnly` / `callSiteCount` / `filesMentioning` / `expectIdentifierNeverVended` / `squeezedContains` / `squeezedSource`；`Tests/.../DrawingTestFixtures.swift` 的 `makeEngineWithLossy` / `lossyFromRaw` / `expectDrawingsUnchanged`。
⚠️ **不得**在别处另写一份扫描逻辑 —— 同族判据留两档正是本仓一路在修的毛病。

---

## Task 1: 引擎 API `setDrawingLocked` —— 门列表 + 幂等

**Files:**
- Modify: `Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（插在 `updateDrawingStyle` 之后，约 `:1182` 后）
- Modify: `Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift`（新增 `makeHorizontalDrawing`，见 Step 2）
- Test: `Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`

**Interfaces:**
- Consumes: `flow.mode`、`drawings`、`drawingsRevision`（均为引擎既有成员）
- Produces: `setDrawingLocked(id:locked:) -> Bool` —— Task 5/6 的唯一 `locked` 写入面

- [ ] **Step 1: 写失败测试（门列表逐条 + 正向档）**

加到 `TrainingEngineDrawingSessionTests.swift`：

```swift
// MARK: 1b-ii PR-1 Task 1（D69）：setDrawingLocked 门列表

/// 正向档（Global Constraint #9 要求）：健康输入**必须被放行**，且真的改了 locked。
/// 少了这一条，一个恒 `return false` 的实现会让下面四条负向断言全绿。
@Test("L1 正向: 训练模式 + id 唯一非空 + 未锁 → 上锁成功、locked 变 true、revision +1")
@MainActor func setLockedHappyPath() throws {
    let e = TrainingEngine.preview()
    let d = makeHorizontalDrawing(id: "L1")
    #expect(e.appendDrawing(d))
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "L1", locked: true) == true)
    #expect(e.drawings.first(where: { $0.id == "L1" })?.locked == true)
    #expect(e.drawingsRevision == rev + 1)
}

/// 解锁必须走得通 —— 这是本 API 存在的全部理由（D69 门② 被刻意豁免）。
@Test("L2 解锁: 已锁的线能解开（updateDrawingStyle 的 locked 门在此不适用）")
@MainActor func setLockedCanUnlock() throws {
    let e = TrainingEngine.preview()
    #expect(e.appendDrawing(makeHorizontalDrawing(id: "L2")))
    #expect(e.setDrawingLocked(id: "L2", locked: true))
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "L2", locked: false) == true)
    #expect(e.drawings.first(where: { $0.id == "L2" })?.locked == false)
    #expect(e.drawingsRevision == rev + 1)
}

@Test("L3 门⓪: 复盘模式恒拒，drawings 与 revision 都不动")
@MainActor func setLockedRejectedInReview() throws {
    let e = TrainingEngine.preview(mode: .review)   // 既有形态，同 :893 / :1066
    #expect(e.appendDrawing(makeHorizontalDrawing(id: "L3")))
    let before = e.drawings
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "L3", locked: true) == false)
    expectDrawingsUnchanged(e, before, revisionBefore: rev)
}

@Test("L4 门①: 空 id → false，什么都不动")
@MainActor func setLockedRejectsEmptyID() throws {
    let e = TrainingEngine.preview()
    #expect(e.appendDrawing(makeHorizontalDrawing(id: "L4")))
    let before = e.drawings
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "", locked: true) == false)
    expectDrawingsUnchanged(e, before, revisionBefore: rev)
}

/// 重复 id：**两条都不许被改**（不是「改第一条」）。
@Test("L5 门①: 重复 id → false，且两条同 id 的线都没被改")
@MainActor func setLockedRejectsDuplicateID() throws {
    let e = TrainingEngine.preview()
    e.injectDrawingsForTesting([makeHorizontalDrawing(id: "DUP"),
                                makeHorizontalDrawing(id: "DUP", price: 11.0)])
    let before = e.drawings
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "DUP", locked: true) == false)
    #expect(e.drawings.allSatisfy { $0.locked == false })
    expectDrawingsUnchanged(e, before, revisionBefore: rev)
}
```

- [ ] **Step 2: 补 fixture helper `makeHorizontalDrawing`**

**已实测**（2026-08-11）：`makeHorizontalDrawing` 在仓里**不存在**，必须新建；
`TrainingEngine.preview(mode:)` 与 `injectDrawingsForTesting` **已存在**，直接用。
造复盘态引擎的既有写法是 `TrainingEngine.preview(mode: .review)`（见 `TrainingEngineDrawingSessionTests.swift:893` / `:1066`）—— **没有** `previewReview()` 这种东西。

加到 `Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift`（顶层函数，**不加 `private`**：Swift 顶层 `private` 是文件作用域，加了别的测试文件调不到）：

```swift
/// 一条默认样式的水平线（period 固定 .m3，与 TrainingEngine.preview() 的上面板一致）。
func makeHorizontalDrawing(id: String, price: Double = 10.0, locked: Bool = false) -> DrawingObject {
    DrawingObject(
        id: id, toolType: .horizontal,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: price)],
        isExtended: false, panelPosition: 0, revealTick: 0, period: .m3,
        lineSubType: .straight, lineStyle: .solid, thickness: 1, colorToken: .orange,
        labelMode: .hidden, locked: locked, text: "", fontSize: 14,
        textColorToken: .orange, textForm: .plain, tailAnchor: nil)
}
```

- [ ] **Step 3: 跑测试确认失败**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -20
```
预期：编译失败，`value of type 'TrainingEngine' has no member 'setDrawingLocked'`。

- [ ] **Step 4: 实现（就地构造，18 字段逐字段拷贝）**

插在 `TrainingEngine.swift` 的 `updateDrawingStyle` 之后：

```swift
    /// D69（1b-ii PR-1）：`locked` 的**语义性写入唯一入口**。
    /// 门列表刻意与 `updateDrawingStyle` 不同，逐条理由见 spec §1.1 的对照表：
    ///   ⓪ review 门（D34 纵深）、① id 非空 + 全局唯一（D66）—— **保留**；
    ///   ② locked 门（D60）—— **豁免**。带上它就永远解不开锁，这是本 API 存在的全部理由；
    ///   ②b 工具门、③ D61 raw-aware 两道门 —— **不带**。锁定不解释任何样式语义，只翻一个布尔；
    ///      原始字节由保存路径既有的 `mergeKnownFields` 逐 key 保全（D70，Task 2 举证）。
    ///   ④ `withStyle` 语义闸 —— **不经过**（该函数明写「本函数不碰 locked」）。
    /// **内容未变 = 零副作用**（D80）：返回 `true`，但 `drawingsRevision` 不递增、不触发 autosave。
    /// ⚠️ 参数内部名必须是 `newLocked` 而不是 `locked`，且必须就地构造、不抽 helper ——
    ///    否则 Task 4 的守卫（`TrainingEngine.swift` 里非拷贝直传的 `locked:` 恰好 1 处）会误判。
    @discardableResult
    func setDrawingLocked(id: DrawingID, locked newLocked: Bool) -> Bool {
        guard flow.mode != .review else { return false }                       // ⓪（D34）
        guard !id.isEmpty else { return false }                                // ①（D66 非空）
        let matches = drawings.indices.filter { drawings[$0].id == id }
        guard matches.count == 1, let i = matches.first else { return false }  // ①（D66 唯一）
        let old = drawings[i]
        guard old.locked != newLocked else { return true }                     // D80：内容未变 → 零副作用
        drawings[i] = DrawingObject(
            id: old.id, toolType: old.toolType, anchors: old.anchors,
            isExtended: old.isExtended, panelPosition: old.panelPosition,
            revealTick: old.revealTick, period: old.period,
            lineSubType: old.lineSubType, lineStyle: old.lineStyle,
            thickness: old.thickness, colorToken: old.colorToken,
            labelMode: old.labelMode,
            locked: newLocked,                                                 // ← 唯一真正改动的字段
            text: old.text, fontSize: old.fontSize,
            textColorToken: old.textColorToken, textForm: old.textForm,
            tailAnchor: old.tailAnchor)
        drawingsRevision += 1
        return true
    }
```

- [ ] **Step 5: 跑测试确认通过**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5
```
预期：`Test run with 1808 tests ... passed`（1803 + 本 task 新增 5 条）。

- [ ] **Step 6: 变异验证（控制者亲验，5 条各验一次）**

| 中和什么 | 应变红的具名测试 |
|---|---|
| 删掉 `guard flow.mode != .review` | L3 |
| 删掉 `guard !id.isEmpty` | L4 |
| 把 `matches.count == 1` 改成 `matches.count >= 1` | L5 |
| 把整个函数体换成 `return false` | **L1、L2**（负向四条仍绿 → 正是正向档的价值） |
| 删掉 `drawingsRevision += 1` | L1、L2 |

复原用 `cp`，禁用 `git checkout`。

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift
git commit -m "feat(1b-ii PR-1): setDrawingLocked 引擎 API —— 豁免 D60 locked 闸的唯一语义写入面（D69）"
```

---

## Task 2: D70 raw-preserving 举证 —— 证明「机制已存在」这条设计假设

**Files:**
- Test: `Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `setDrawingLocked`；既有 `makeEngineWithLossy` / `lossyFromRaw`；`LossyDrawingArray.reconciled(currentKnown:)` / `.encoded()`
- Produces: 无新 API —— 本 task 纯举证

> ⚠️ **本 task 是 PR-1 的地基。** spec D70 断言「raw-preserving 单字段 merge 在 P1a 就已存在」（`reconciled` → `mergeKnownFields` 只覆盖真变化的 key，而 `DrawingObject.==` 含 `locked`）。**这是读代码推演出来的假设，不是已验证事实。**
> **若 Step 3 的变异验证发现测试仍绿，整条设计假设作废** —— 立即停止，把结论报给控制者，PR-1 需回到「自己实现单字段 merge」的方案。

- [ ] **Step 0: 给 `DrawingEditDurabilityGateTests.swift` 补 `import CoreGraphics`**

该文件当前只有 `import Foundation` / `import Testing` / `@testable import KlineTrainerContracts`（**已实测**），
而下面 L8 用到 `CGRect` / `CGPoint` —— 本包**不会**替你 re-export 这两个符号，不补 import 直接编译失败
（codex P-R5-F2）。同目录的 `DrawingEditRouterTests.swift` 就是明确写了 `import CoreGraphics` 的先例。

```swift
import Foundation
import Testing
import CoreGraphics        // ← 新增：L8 的 CGRect / CGPoint
@testable import KlineTrainerContracts
```

- [ ] **Step 1: 写举证测试（两个分量：未来顶层字段 + 未来枚举值）**

```swift
/// D70 举证（1b-ii PR-1 Task 2）：只改 `locked` 时，其余原始字节必须逐字保留。
/// 机制来自 P1a：`reconciled` 见 `cur != old` → 走 `mergeKnownFields` → 只覆盖**真变化**的 key。
@Test("L6 raw-preserving: 锁定带未来顶层字段的线 → futureX 仍在、locked 已变 true")
@MainActor func lockPreservesFutureTopLevelField() throws {
    let raw = #"{"id":"P1","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureX":9}"#
    let e = makeEngineWithLossy(try lossyFromRaw(raw))
    #expect(e.setDrawingLocked(id: "P1", locked: true))
    let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
    let out = String(decoding: try merged.encoded(), as: UTF8.self)
    #expect(out.contains("\"futureX\":9"), "未来顶层字段被抹掉了：\(out)")
    #expect(out.contains("\"locked\":true"), "locked 没写进去：\(out)")
}

@Test("L7 raw-preserving: 锁定带未来枚举值的线 → futureNeon 仍在、locked 已变 true")
@MainActor func lockPreservesFutureEnumValue() throws {
    let raw = #"{"id":"P2","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
    let e = makeEngineWithLossy(try lossyFromRaw(raw))
    #expect(e.setDrawingLocked(id: "P2", locked: true))
    let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
    let out = String(decoding: try merged.encoded(), as: UTF8.self)
    #expect(out.contains("\"colorToken\":\"futureNeon\""), "未来枚举值被 fallback 覆盖了：\(out)")
    #expect(out.contains("\"locked\":true"), "locked 没写进去：\(out)")
}

/// 契约举证（spec §3 第 3 条第 ① 分量）：非水平线在本构建**选不中** ⇒ 路由够不着 ⇒ 用户锁不了它。
@Test("L8 契约: .trend 线不出现在命中结果里（无渲染器 ⇒ 选不中）")
@MainActor func futureToolTypeIsNotHittable() throws {
    let trend = DrawingObject(
        id: "T1", toolType: .trend,
        anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: 10.0),
                  DrawingAnchor(period: .m3, candleIndex: 5, price: 12.0)],
        isExtended: false, panelPosition: 0, revealTick: 0, period: .m3,
        lineSubType: .straight, lineStyle: .solid, thickness: 1, colorToken: .orange,
        labelMode: .hidden, locked: false, text: "", fontSize: 14,
        textColorToken: .orange, textForm: .plain, tailAnchor: nil)
    // mapper：主图 y ∈ [0,100]、价格区间 [0,100]（与 DrawingEditRouterTests:15-22 同款，已实测可编译）
    let mapper = CoordinateMapper(
        viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                priceRange: PriceRange(min: 0, max: 100),
                                mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
        displayScale: 2)
    // ⚠️ **注册表显式传入，不用 `KLineView.drawingTools`** —— `KLineView` 是 UIKit-gated，
    //    host `swift test` 上根本不编译（codex P-R4-F1）。本条证明的是判据本身：
    //    「注册表里没有的工具 ⇒ 不命中」。「生产注册表里确实没有 `.trend`」由 L8c 在 Catalyst 上证。
    let hit = DrawingHitTester.firstHit(
        in: [trend], point: CGPoint(x: 10, y: 10),
        mapper: mapper, tools: [.horizontal: HorizontalLineTool()])
    #expect(hit == nil, "注册表里没有 .trend 的渲染器，却命中了 —— 契约论点 ① 不成立")
    // 同一判据的正向档：同样的点、同样的注册表，一条**水平线**必须命中
    // （否则「返回 nil」可能只是因为几何/点位不对，与注册表无关 → 本测试就没有判别力）
    let hline = makeHorizontalDrawing(id: "H1", price: 50)
    #expect(DrawingHitTester.firstHit(in: [hline], point: CGPoint(x: 10, y: 50),
                                      mapper: mapper,
                                      tools: [.horizontal: HorizontalLineTool()]) != nil,
            "正向档失败 —— 说明 nil 不是因为「注册表里没有」，本测试无判别力")
}
```

⚠️ **正向档不可省**：只断言 `.trend` 返回 nil，无法区分「因为注册表里没它」还是「因为点位/几何根本不对」。
一个恒返回 nil 的 `firstHit` 也能让前半条全绿 —— 正向档才把判别力钉住。

```swift
/// L8b 契约分量②（codex P-R1-F3）：**即便绕过路由直调引擎**，保存后 `toolType` 与全部未来字节
/// 逐字不变、**只有 `locked` 变了**。
/// L8 只证明了「UI 够不着」，本条证明「够着了也无损」—— spec §3 第 3 条要求**两条都有**，
/// 只写一条等于把结论建在没测过的那一半上。
@Test("L8b 契约: .trend + 未来字段的线直调 setDrawingLocked → toolType 与未来字节逐字不变")
@MainActor func lockOnFutureToolPreservesEverythingElse() throws {
    let raw = #"{"id":"T2","toolType":"trend","anchors":[{"period":"3m","candleIndex":1,"price":9.0},{"period":"3m","candleIndex":5,"price":12.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureY":42}"#
    let e = makeEngineWithLossy(try lossyFromRaw(raw))
    #expect(e.drawings.first?.toolType == .trend, "`.trend` 是已声明 case，应解码成 .known")
    #expect(e.setDrawingLocked(id: "T2", locked: true) == true,
            "引擎侧不带工具门（D69 ②b）—— 这里就是要证明它够得着也无损")
    let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
    let out = String(decoding: try merged.encoded(), as: UTF8.self)
    #expect(out.contains("\"toolType\":\"trend\""), "toolType 被改写了：\(out)")
    #expect(out.contains("\"futureY\":42"), "未来字段被抹掉了：\(out)")
    #expect(out.contains("\"locked\":true"), "locked 没写进去：\(out)")
    // ★「**只有** locked 变了」必须是真判据，不能靠几条 contains 凑：
    //   把两边的 `locked` 都摘掉再逐字节比 —— 剩下的必须完全相同。
    func strippingLocked(_ json: String) throws -> Data {
        var d = try #require(
            (try JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
        d.removeValue(forKey: "locked")
        return try JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])
    }
    let elem = try #require(JSONTopLevelArray.rawElementStrings(try merged.encoded())?.first)
    #expect(try strippingLocked(elem) == (try strippingLocked(raw)),
            "除 locked 外还有字段被改动了。产物：\(elem)")
}
```

⚠️ 最后那条是本测试的**主判据**：前面几条 `contains` 只能证明「某几个字段还在」，证明不了
「**没有别的字段被悄悄改掉**」。少了它，一个把 `thickness` 顺手归一化掉的实现照样全绿。

> ⚠️ **两条已实测的接口事实**（别照直觉写）：
> - `.trend` 是合法 case，但它在 `Models.swift:39` 的**逗号列表**里声明（`case horizontal, trend, channel, …`），`grep "case trend"` 找不到 —— 不要因此以为它不存在。
> - `DrawingToolType.implemented` 实测 = `[.horizontal]`（`Models.swift:50`），故 `.trend` 既进不了 `beginDrawingSession`，也不在 `KLineView.drawingTools` 注册表里。

- [ ] **Step 2: 跑测试确认通过（全部 host 可跑，无 UIKit 依赖）**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5
```
L6 / L7 / L8 / L8b **四条都在 host 上跑**：`DrawingHitTester`、`HorizontalLineTool`、`CoordinateMapper` 全是纯 CoreGraphics，**没有一处碰 `KLineView`**。

> **契约论点 ① 的另一半 = L8c，归 Task 7**，落在 **`Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift`**。
> ⚠️ **不能**放进 `DrawingInteractionUISourceGuardTests.swift` —— 那个文件**刻意不是 UIKit-gated**
> （它读源码文本、跑 host，见其文件头注），`KLineView` 在那儿根本不可见。
> `KLineViewCompileTests.swift` 是 `#if canImport(UIKit)` 门控的，Catalyst 上真跑。
> （已实测：`KLineView.drawingTools` 是 `KLineView.swift:47` 的 `static let`，当前值恰为 `[.horizontal: HorizontalLineTool()]`。）
> ```swift
> @Test("L8c 契约: 生产渲染注册表里确实没有 .trend（L8 的另一半，必须在 Catalyst 上跑）")
> func productionRegistryHasNoTrend() {
>     #expect(KLineView.drawingTools[.trend] == nil,
>             "生产注册表里出现了 .trend 渲染器 —— L8 的前提失效，契约理由需重写")
>     #expect(KLineView.drawingTools[.horizontal] != nil, "正向档：水平线必须在注册表里")
> }
> ```
> **两半缺一不可**：L8 证明「注册表里没有 ⇒ 不命中」这条判据成立，L8c 证明「生产注册表里真的没有 `.trend`」。
> 只有 L8 = 判据对但前提没验；只有 L8c = 前提对但判据没验。

- [ ] **Step 3: 变异验证（本 task 的核心，控制者亲验）**

| 中和什么 | 应变红 |
|---|---|
| 把 `Models.swift:370` 的 `&& lhs.locked == rhs.locked` 删掉 | **L6、L7** —— 证明它们真的走到了 merge 路径 |
| 把 `mergeKnownFields` 里 `if let ov, jsonValueEqual(cv, ov) { continue }` 改成无条件 `dict[k] = cv` | **L7**（未来枚举值会被 fallback 覆盖） |
| 把 `DrawingHitTester.firstHit:26` 的 `guard let tool = ... else { return false }` 改成 `else { return true }` | L8（`.trend` 会命中） |
| 把 `firstHit` 换成恒 `return nil` | **L8 的正向档**（前半仍绿 → 正是正向档的价值） |
| 往 `KLineView.drawingTools` 里加一条 `.trend` 项 | **L8c**（Catalyst，Task 7） |

> ⛔ **第一条变异若 L6/L7 仍绿 → 立即停止本 PR，报告控制者。** 说明 D70 的设计假设没被证明，raw-preserving 需要自己实现。

- [ ] **Step 4: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift
git commit -m "test(1b-ii PR-1): D70 raw-preserving 举证 + .trend 选不中的契约举证"
```

---

## Task 3: D80 —— 四个写入 API 统一「内容未变 = 零副作用」

**Files:**
- Modify: `Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:1178-1181`（`updateDrawingStyle` 尾部）
- Test: `Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `setDrawingLocked`（其幂等路径已就位）
- Produces: 「`drawingsRevision` 递增 ⟺ `drawings` 内容真的变了」这条不变量 —— PR-2 的入栈条件直接等于它

> ⚠️ **这是对已合并 API 的有意行为改动**，不是回归。动机见 spec §2.2b：样式控件在**当前值**上仍可点，重复点同一个颜色会产生 `before == after` 的 no-op；PR-2 若把入栈挂在成功路径上，这个 no-op 会把深度 1 栈里唯一那条真编辑挤掉、不可恢复。

- [ ] **Step 1: 写失败测试**

```swift
@Test("L9 D80: 同样式再调 updateDrawingStyle → 返回 true 但 revision 不动、内容不变")
@MainActor func updateStyleNoOpHasNoSideEffect() throws {
    let e = TrainingEngine.preview()
    #expect(e.appendDrawing(makeHorizontalDrawing(id: "N1")))
    var s = DrawingDefaultStyle()
    s.thickness = 3; s.colorToken = .green
    #expect(e.updateDrawingStyle(id: "N1", style: s))          // 第一次：真改动
    let before = e.drawings
    let rev = e.drawingsRevision
    #expect(e.updateDrawingStyle(id: "N1", style: s) == true)   // 第二次：同样式 no-op
    expectDrawingsUnchanged(e, before, revisionBefore: rev)
}

@Test("L10 D80: 已锁的线再上锁 → 返回 true 但 revision 不动")
@MainActor func setLockedIdempotentHasNoSideEffect() throws {
    let e = TrainingEngine.preview()
    #expect(e.appendDrawing(makeHorizontalDrawing(id: "N2")))
    #expect(e.setDrawingLocked(id: "N2", locked: true))
    let before = e.drawings
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "N2", locked: true) == true)
    expectDrawingsUnchanged(e, before, revisionBefore: rev)
}
```

- [ ] **Step 2: 跑测试确认 L9 失败、L10 通过**

```bash
cd "ios/Contracts" && swift test 2>&1 | grep -E "L9|L10|Test run with"
```
预期：L9 FAIL（`updateDrawingStyle` 目前无条件递增），L10 PASS（Task 1 已实现幂等）。

- [ ] **Step 3: 实现 —— 在 `updateDrawingStyle` 的 `drawings[i] = updated` 之前加早退**

把 `TrainingEngine.swift:1178-1181` 改成：

```swift
        guard let updated = old.withStyle(style) else { return false }             // ④（D59/D58 引擎支）
        // D80（1b-ii PR-1）：**内容未变 = 零副作用**。样式控件在「当前值」上仍可点，
        // 重复点同一个颜色会走到这里且 `updated == old`。原先无条件 `drawingsRevision += 1`，
        // 会让这个 no-op 触发一次无谓 autosave；更严重的是 PR-2 把入栈挂在本成功路径上时，
        // 它会把深度 1 撤销栈里唯一那条**真编辑**挤掉、不可恢复（codex R3-F2）。
        // 判据用 `DrawingObject.==`（含除 id 外全部内容分量，`locked` 也在内，Models.swift:366-372）。
        // 统一之后「`drawingsRevision` 递增 ⟺ 内容真的变了」成为不变量，PR-2 的入栈条件恰好等于它。
        guard updated != old else { return true }
        drawings[i] = updated
        drawingsRevision += 1
        return true
```

- [ ] **Step 4: 跑测试确认通过 + 复核既有 N2 未被破坏**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5
```
预期：全绿。
**并单独复核既有 N2**（`TrainingEngineDrawingSessionTests.swift:812`「updateDrawingStyle 只动 5 样式字段 + 两个派生，其余逐字段不变；revision +1」）：
读它的测试体，确认它传的是**与原值不同**的样式。**若发现它传的其实是同样式，那它此前就是一条恒真测试** —— 修正它并在提交信息里如实记录。

- [ ] **Step 5: 变异验证**

| 中和什么 | 应变红 |
|---|---|
| 删掉 `guard updated != old else { return true }` | L9 |
| 删掉 Task 1 里的 `guard old.locked != newLocked else { return true }` | L10 |

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
git commit -m "feat(1b-ii PR-1): D80 内容未变=零副作用 —— updateDrawingStyle 加早退（对已合并 API 的有意改动）"
```

---

## Task 4: 信任边界三层守卫（镜像既有 N15）

**Files:**
- Modify: `Tests/KlineTrainerContractsTests/SourceGuardScanner.swift`（新增 `engineDrawingsStructuralWrites`）
- Test: `Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`

**Interfaces:**
- Consumes: `SourceGuardScanner.swift` 的 `expectEngineInternalOnly` / `callSiteCount` / `filesMentioning` / `expectIdentifierNeverVended` / `squeezedContains` / `squeezedSource` / `contractsDirForGuards`
- Produces: `engineDrawingsStructuralWrites(_ squeezedCode: String) -> Int`（顶层函数，**不加 `private`** —— Swift 顶层 `private` 是文件作用域，加了别的测试文件调不到）

> ⚠️ 本 task 依赖 Task 6 的路由 —— **调用点守卫要到 Task 6 落地后才会绿**。
> 实施顺序两选一：① 先做 Task 6 再回来做本 task；② 本 task 先只写「非 public + 不得 vend」两层，调用点那层随 Task 6 一起提交。**推荐 ①**（一次写全，避免守卫半成品）。

- [ ] **Step 1: 写守卫测试（逐字镜像既有 N15 的形状）**

```swift
@Test("L11: setDrawingLocked 非 public + Sources/ 中恰好 1 处调用（路由在调用前先验几何）")
@MainActor func setDrawingLockedTrustBoundary() throws {
    // 第一层：存在 + 非 public/package/open（含 public extension，D69 约束 3）
    try expectEngineInternalOnly("setDrawingLocked(id:")

    // 第二层：`Sources/` 里恰好 1 处调用，且在那条已先验几何的 UI 路由里
    let sites = try callSiteCount("setDrawingLocked(")
    #expect(sites.count == 1, "setDrawingLocked 的调用文件数应为 1，实际：\(sites)")
    #expect(sites.first?.count == 1, "同一文件内也只许 1 处，实际：\(sites)")
    #expect(sites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift") == true,
            "唯一调用点必须是 UI 编辑路由，实际：\(sites)")

    // 几何判据必须排在调用之前（只钉"调用点唯一"不够，唯一那处若不验几何同样失守）
    let router = contractsDirForGuards
        .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path
    let code = try squeezedSource(router)
    let geoIdx = try #require(code.range(of: squeeze("HorizontalLineTool.visibleGeometry("))).lowerBound
    let callIdx = try #require(code.range(of: squeeze("engine.setDrawingLocked("))).lowerBound
    #expect(geoIdx < callIdx, "几何判据必须排在 setDrawingLocked 调用之前")

    // 第三层：方法引用（`let f = engine.setDrawingLocked`）不出现调用 pattern，只数调用会放过它
    let mentions = try filesMentioning("setDrawingLocked")
    #expect(!mentions.isEmpty, "扫描器返回空 —— 守卫已失效")
    #expect(mentions.allSatisfy {
        $0.hasSuffix("/TrainingEngine/TrainingEngine.swift")
            || $0.hasSuffix("/Drawing/DrawingEditRouter.swift")
    }, "setDrawingLocked 被引擎与唯一路由以外的文件提到（含方法引用）：\(mentions)")
    try expectIdentifierNeverVended("setDrawingLocked", inFiles: mentions)
}

/// N-B 第 1 条（spec §1.6）：`TrainingEngine.swift` 里**语义性** locked 写入恰好 1 处。
/// 拷贝直传（`locked: locked` / `old.locked` / `d.locked` / `drawing.locked`）不算。
@Test("L12: TrainingEngine 里非拷贝直传的 locked 写入恰好 1 处（在 setDrawingLocked 里）")
@MainActor func semanticLockedWriteIsSingleSite() throws {
    let code = try squeezedSource(trainingEnginePath)
    let total = code.components(separatedBy: "locked:").count - 1
    var passthrough = 0
    for form in ["locked:locked", "locked:old.locked", "locked:d.locked", "locked:drawing.locked"] {
        passthrough += code.components(separatedBy: form).count - 1
    }
    #expect(total - passthrough == 1,
            "语义性 locked 写入应恰好 1 处，实际 total=\(total) passthrough=\(passthrough)")
    #expect(code.contains(squeeze("locked: newLocked")),
            "那一处必须是 setDrawingLocked 里的 `locked: newLocked`（见 Global Constraint #1）")
}

/// N-B 第 2 条（spec §1.6）—— **不可省，与 L12 是两条不同的判据**（codex P-R1-F1）。
/// L12 只数 `locked:` 字样；而**整对象赋值** `drawings[i] = <locked 不同的对象>` 字面上**不含**
/// `locked:`，会从 L12 底下整个溜过去 —— 它恰恰是绕过路由/几何/唯一性信任边界的第二条路。
/// 故本条按**结构性写入点**穷尽计数。
///
/// ⚠️ 必须排除 `reviewDrawings`：它以**子串**形式包含 `drawings`，朴素计数会把复盘侧写入
///    算进来（假阳性）；而为了迁就它去放宽判据，又会让真正的新写入面溜过去。
///    故判据 = 「`drawings` 紧邻的前一个字符不是标识符字符」，与 `bareIdentifierReferences` 同款边界法。
@Test("L12b: TrainingEngine 里 drawings 的结构性写入点恰好 5 处（穷尽性，多一处即红）")
@MainActor func engineDrawingsWriteSurfaceIsExhaustive() throws {
    let code = try squeezedSource(trainingEnginePath)
    let n = engineDrawingsStructuralWrites(code)
    // PR-1 后的构成（每一处都必须能对上号）：
    //   drawings.remove(at:) ×2  → deleteDrawing(at:) / deleteDrawing(id:)
    //   drawings.append(     ×1  → appendDrawing
    //   drawings[x] =        ×2  → updateDrawingStyle / setDrawingLocked
    //   drawings.insert(     ×0  → PR-2 才引入（届时期望值改为 6）
    #expect(n == 5, """
        drawings 结构性写入点应为 5，实际 \(n)。
        多了 = 出现了未经分类的新写入面（可能绕过路由/几何/唯一性三道门）；
        少了 = 判据坏了或某个写入面被挪走。两种都必须查清再改期望值，不许直接改数字。
        """)
}
```

**并把计数 helper 加到 `Tests/KlineTrainerContractsTests/SourceGuardScanner.swift`**（与其他扫描器同处，**不得**在测试文件里另写一份）：

```swift
/// `TrainingEngine.swift` 里对**引擎自己那个 `drawings`** 的结构性写入点计数（1b-ii PR-1，N-B 第 2 条）。
/// 排除 `reviewDrawings`（子串包含 `drawings`）：判据 = 紧邻前一个字符不是标识符字符。
/// 只数**写**：`drawings[$0].id` 这种下标**读**不算（`]` 后面跟的是 `.` 不是 `=`）。
func engineDrawingsStructuralWrites(_ squeezedCode: String) -> Int {
    let chars = Array(squeezedCode)
    func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    func startsBare(at i: Int, _ needle: [Character]) -> Bool {
        guard i + needle.count <= chars.count, Array(chars[i ..< i + needle.count]) == needle else { return false }
        if i > 0, isIdentChar(chars[i - 1]) { return false }      // reviewDrawings → 排除
        return true
    }
    var count = 0
    for needle in ["drawings.remove(", "drawings.insert(", "drawings.append("].map(Array.init) {
        for i in chars.indices where startsBare(at: i, needle) { count += 1 }
    }
    let sub = Array("drawings[")
    for i in chars.indices where startsBare(at: i, sub) {
        var j = i + sub.count
        while j < chars.count, chars[j] != "]" { j += 1 }         // 跳过下标表达式
        guard j + 1 < chars.count, chars[j] == "]", chars[j + 1] == "=" else { continue }
        if j + 2 < chars.count, chars[j + 2] == "=" { continue }  // `==` 是比较不是赋值
        count += 1
    }
    return count
}
```

- [ ] **Step 2: 跑测试确认通过**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | grep -E "L11|L12|Test run with"
```

- [ ] **Step 3: 反向自检（每条守卫各一次，控制者亲验）**

| 临时改动 | 应变红 |
|---|---|
| 给 `setDrawingLocked` 加 `public` | L11 第一层 |
| 在 `TrainingView.swift` 里加一句 `_ = engine.setDrawingLocked(id: "x", locked: true)` | L11 第二层 |
| 在路由里加 `let f = engine.setDrawingLocked`（不调用） | L11 第三层（vend） |
| 把路由里几何门挪到调用**之后** | L11 的 `geoIdx < callIdx` |
| 在 `TrainingEngine.swift` 里另加一处 `locked: true` | L12 |
| 把 `locked: newLocked` 改成 `locked: locked`（并把参数名改回去） | L12 —— **这条证明 Global Constraint #1 不是空话** |
| 在 `TrainingEngine.swift` 里另加一处 `drawings[0] = someObj`（**不含 `locked:` 字样**） | **L12b**（L12 抓不到 —— 这正是 codex P-R1-F1 指出的缺口） |
| 把 `reviewDrawings.append(` 也算进计数（即去掉边界排除） | L12b（会变成 6 ≠ 5，证明排除逻辑真的在起作用） |

- [ ] **Step 4: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
git commit -m "test(1b-ii PR-1): setDrawingLocked 三层信任边界守卫 + locked/drawings 两条写入面守卫"
git status --porcelain   # 必须为空 —— 漏 stage 的 helper 会让分支编译不过（codex P-R2-F2）
```

---

## Task 5: N14h 断言翻转 + 落盘往返

**Files:**
- Modify: `Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift:178`（`lockedFutureDataLineIsCurrentlyUnrecoverable` 翻转 + 新增 L13a）
- Modify: `Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift`（**新增 L13b —— N-F 的主证据，harness 在这个文件里**）

**Interfaces:**
- Consumes: Task 1 的 `setDrawingLocked`

> 1b-i 在该测试头注里**逐字交接**：「这条线一旦被解锁，`deleteDrawing(id:)` 就该对它放行 —— 本测试「delete == false」那半条断言**必须翻转成 true**，否则说明 `setDrawingLocked` 没把 `locked` 门在下游落到实处。」

- [ ] **Step 1: 改测试名与头注**

把 `@Test("N14h 已知死角（不修，钉现状）: ...")` 改成：

```swift
/// N14h（1b-ii PR-1 已解开一半）：locked + 未来数据的线。
/// **锁着时**仍然既改不动（门②）也删不掉（门②）——这部分不变。
/// **但 `setDrawingLocked` 落地后它可以被解锁**，解锁之后 `deleteDrawing(id:)` 必须放行
/// （未来数据那道门本就不归删除面管）→ 用户对这类线的处置通道从此存在。
/// ⚠️ **仍然残留**：解锁后它依旧**改不动样式**（D61 门保留在 `updateDrawingStyle` 上）。
///    这是保护而非缺陷，P3/未来版本认识那些枚举值后自然解禁。
@Test("N14h: locked + 未来数据的线 —— 锁着时改不动删不掉，解锁后可删除")
```

- [ ] **Step 2: 在两个分量（LA / LB）末尾各追加解锁 → 删除放行的断言**

在分量一 `eA` 现有断言之后追加：

```swift
    // 1b-ii PR-1：解锁 → 删除必须放行（1b-i 头注逐字交接的翻转点）
    #expect(eA.setDrawingLocked(id: "LA", locked: false) == true)
    #expect(eA.drawings.first(where: { $0.id == "LA" })?.locked == false)
    let revAfterUnlockA = eA.drawingsRevision
    #expect(eA.deleteDrawing(id: "LA") == true)                    // ← 由 false 翻转为 true
    #expect(!eA.drawings.contains { $0.id == "LA" })               // 线真的没了
    #expect(eA.drawingsRevision == revAfterUnlockA + 1)
    // 残留仍在：解锁不解禁样式编辑（D61 门还在 updateDrawingStyle 上）
```

分量二 `eB` 同法追加（把 `LA` 换成 `LB`、`eA` 换成 `eB`）。
⚠️ 「解锁后仍改不动样式」这条要在**删除之前**断言（删了就没得改了）：

```swift
    #expect(eB.setDrawingLocked(id: "LB", locked: false) == true)
    #expect(eB.updateDrawingStyle(id: "LB", style: style()) == false)   // 残留：D61 门仍拒
    #expect(eB.deleteDrawing(id: "LB") == true)
    #expect(!eB.drawings.contains { $0.id == "LB" })
```

- [ ] **Step 3: 新增落盘测试（N-F）—— 必须走**真实存盘路径**，不许只在内存里 reconcile**

> ⚠️ **本 step 初稿只在内存里 `reconciled` + `decode`，被 codex P-R1-F2 判为不合格**：那样根本没碰
> `drawingsRevision` 触发的 autosave、`TrainingSessionCoordinator.saveProgress`、以及活动会话的
> clean-skip 判据。**「锁定改动没真写盘」这个回归会让内存版测试全绿，却让验收清单第 7/8 条真机失败。**
> 故改为经 `CoordinatorTestHarness` 走**真实 save → endSession → resume** 全链路。
> 文件改到 `Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift`（harness 在那儿）。

L13a 保留内存版作为**快速判据**（它仍有价值：证明 merge 层不丢 locked），留在
`DrawingEditDurabilityGateTests.swift`：

```swift
@Test("L13a 落盘(内存层): 锁定 → revision +1 → merge/encode/decode 往返后仍是锁定态")
@MainActor func lockedSurvivesLossyRoundTrip() throws {
    let e = TrainingEngine.preview()
    #expect(e.appendDrawing(makeHorizontalDrawing(id: "S1")))
    let rev = e.drawingsRevision
    #expect(e.setDrawingLocked(id: "S1", locked: true))
    #expect(e.drawingsRevision == rev + 1)
    let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
    let reloaded = try LossyDrawingArray.decode(try merged.encoded())
    #expect(reloaded.drawings.first(where: { $0.id == "S1" })?.locked == true)
}
```

**但不能只有它** —— 它证明不了「锁定这个改动会真的触发写盘」：

```swift
/// L13b（N-F 主证据）：训练局里**只锁定一条线**（不推 tick / 不交易 / 不增删）
/// → 走真实 saveProgress → endSession → 重新载入后仍是锁定态。
@Test func lockOnlyChange_persistsAcrossSaveAndReload() async throws {
    let h = try CoordinatorTestHarness.make()
    let e1 = try await h.coordinator.replay(recordId: h.seededRecordId)
    // fresh replay 不带任何已有线（见 D30②）→ 必须先画一条、存盘、续局，才有线可锁
    #expect(e1.appendDrawing(makeHorizontalDrawing(id: "K1")))
    try await h.coordinator.saveProgress(engine: e1)
    await h.coordinator.endSession()

    let e2 = try #require(try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId))
    #expect(e2.drawings.first(where: { $0.id == "K1" })?.locked == false)
    let rev = e2.drawingsRevision
    // ★ 本局**唯一**的改动就是锁定（split addendum §7.3 #3 / 验收 #8 的等价自动化）
    #expect(e2.setDrawingLocked(id: "K1", locked: true) == true)
    #expect(e2.drawingsRevision == rev + 1)        // 严格 +1 —— autosave 的触发信号
    try await h.coordinator.saveProgress(engine: e2)
    await h.coordinator.endSession()

    let e3 = try #require(try await h.coordinator.resumePendingReplay(recordId: h.seededRecordId))
    #expect(e3.drawings.first(where: { $0.id == "K1" })?.locked == true,
            "只锁定、别的什么都没改 → 存盘被 clean-skip 吞掉了（D30① 回归）")
}
```

⚠️ **实施者必须先读 `CoordinatorReplayPersistenceTests.swift:11-40`**（`CoordinatorTestHarness` 的
`make()` / `seededRecordId`）与 `:229-243`（`replay → saveProgress → endSession → resumePendingReplay`
的既有写法），**照搬那套 harness**，不要另造。

⚠️ **不得**把「只锁定」换成「锁定 + 推一根 tick」之类 —— 那样 tick 变化本身就会让存盘发生，
**测不出**「锁定这个改动有没有独立触发落盘」，正是 D30① 要防的那条。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5
```

- [ ] **Step 5: 变异验证**

| 中和什么 | 应变红 |
|---|---|
| 把 `deleteDrawing(id:)` 的 `guard !drawings[i].locked` 改成恒真 | N14h 的「锁着时删不掉」那半 |
| 让 `setDrawingLocked` 恒 `return false` | N14h 新增那半 + L13a + **L13b** |
| 删掉 `drawingsRevision += 1` | L13a + **L13b**（L13b 是「锁定真的触发写盘」的唯一证据） |
| 把 `saveProgress` 的 clean-skip 判据改成无条件跳过 | **L13b**（L13a 恒绿 —— 这正是 codex P-R1-F2 指出的缺口） |

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorReplayPersistenceTests.swift
git commit -m "test(1b-ii PR-1): N14h 断言翻转（解锁后可删除）+ 锁定态真实存盘往返（L13b）"
git status --porcelain   # 必须为空 —— 漏 stage L13b 等于把 N-F 的唯一主证据丢在工作区（codex P-R2-F1）
```

---

## Task 6: 路由与可用性谓词（D71）

**Files:**
- Modify: `Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`
- Test: `Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `setDrawingLocked`；既有 `uniqueSelected` / `idIsGloballyUnique` / `selectionGeometryVisible` / `syncSelectionByState`
- Produces: `DrawingEditRouter.lockButtonEnabled(engine:) -> Bool`、`lockIsOn(engine:) -> Bool`、`toggleLockSelected(engine:) -> Bool` —— Task 7 的 UI 消费这三个

- [ ] **Step 1: 写失败测试**

> **实施前置**：本文件已有私有 helper `makeSelected(price:id:lineSubType:candleIndex:)`（`:30-42`）
> 与 `mapper(priceMin:priceMax:)`（`:15-22`），造的是「会话已开 + 选择态 + 上面板选中一条价格 50 的
> 水平线 + mapper 已发布」。下面五条**直接用它们**，不要另造。

```swift
// MARK: 1b-ii PR-1 Task 6（D71）：锁定谓词与路由

@Test("L14 谓词: 无选中 → 🔒 恒灰（与 🗑 同规则，与样式控件刻意不对称）")
@MainActor func lockButtonDisabledWithoutSelection() {
    let e = makeSelected()
    e.drawingSession.clearSelection()
    #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == false)
}

@Test("L15 谓词: 选中且几何可见 → 🔒 亮；**锁定之后仍亮**（否则永远解不开锁）")
@MainActor func lockButtonStaysEnabledWhenLocked() {
    let e = makeSelected(id: "A")
    #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == true)
    #expect(e.setDrawingLocked(id: "A", locked: true) == true)
    #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == true,
            "锁定线必须仍能被选中并解锁 —— 谓词里带 !d.locked 就是这条挂掉")
}

@Test("L15b 谓词: 选中但线滑出可见价格区间 → 🔒 灰（几何门与 🗑 同待遇）")
@MainActor func lockButtonDisabledWhenOffscreen() {
    let e = makeSelected(price: 50)
    #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == true)
    e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
    #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == false)
}

@Test("L16 谓词: 锁定线 → 🗑 灰、样式控件灰（既有 !d.locked 分量首次真执行）")
@MainActor func lockedLineDisablesDeleteAndStyle() {
    let e = makeSelected(id: "A")
    #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == true)
    #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true)
    #expect(e.setDrawingLocked(id: "A", locked: true) == true)
    #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == false)
    #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == false)
    #expect(e.setDrawingLocked(id: "A", locked: false) == true)      // 解锁后恢复
    #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == true)
    #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true)
}

@Test("L17 图标态: 无选中→开锁；选中未锁→开锁；选中已锁→闭锁")
@MainActor func lockIconReflectsSelectedLine() {
    let e = makeSelected(id: "A")
    #expect(DrawingEditRouter.lockIsOn(engine: e) == false)          // 选中未锁
    #expect(e.setDrawingLocked(id: "A", locked: true) == true)
    #expect(DrawingEditRouter.lockIsOn(engine: e) == true)           // 选中已锁
    e.drawingSession.clearSelection()
    #expect(DrawingEditRouter.lockIsOn(engine: e) == false)          // 无选中取中性态（开锁）
}

@Test("L18 路由: 几何不可见时 toggleLockSelected 恒 false 且 locked 一个字都不改")
@MainActor func toggleLockFailsClosedWithoutGeometry() {
    let e = makeSelected(id: "A")
    e.drawingSession.setViewportMapper(mapper(priceMin: 200, priceMax: 300), panel: .upper)
    let rev = e.drawingsRevision
    #expect(DrawingEditRouter.toggleLockSelected(engine: e) == false)
    #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false)
    #expect(e.drawingsRevision == rev, "被几何门拒了却动了 revision = 白触发一次 autosave")
}

@Test("L18b 路由正向: 几何可见时 toggleLockSelected 真的翻转 locked 且 revision +1")
@MainActor func toggleLockTogglesWhenVisible() {
    let e = makeSelected(id: "A")
    let rev = e.drawingsRevision
    #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true)
    #expect(e.drawings.first(where: { $0.id == "A" })?.locked == true)
    #expect(e.drawingsRevision == rev + 1)
    #expect(DrawingEditRouter.toggleLockSelected(engine: e) == true)  // 再点一次 → 解锁
    #expect(e.drawings.first(where: { $0.id == "A" })?.locked == false)
}
```

> ⚠️ **初稿这五条的函数体只有注释**，被 codex P-R3-F1 判为 high：那样的测试**编译得过、也恒绿**，
> 哪怕 `lockButtonEnabled` 恒 false、`toggleLockSelected` 是空实现、几何门整个删掉。
> 这正是本仓已记的「**计划的代码块本身是恒真测试的根因**」—— 我当时的理由（「照搬既有 setup 更稳」）
> 只适用于**搭台那一行**，不该把**断言**也留白。现在断言全部写死，只有 setup 复用既有 helper。

- [ ] **Step 2: 跑测试确认失败**（`no member 'lockButtonEnabled'`）

- [ ] **Step 3: 实现（加在 `deleteSelected` 之后，形状严格镜像删除三件套）**

```swift
    // MARK: 锁定（1b-ii PR-1，D71）—— 形状镜像上面的删除三件套

    /// 「锁定可用」的**非几何分量**。
    /// ⚠️ 与 `deletableIgnoringGeometry` 只差一处：**没有** `!d.locked` 分量。
    /// 这不是笔误 —— 锁定线**必须仍能被选中并解锁**（spec §7.1 逐字），带上那道门就永远解不开。
    private static func lockableIgnoringGeometry(engine: TrainingEngine) -> Bool {
        guard engine.flow.mode != .review else { return false }
        guard let d = uniqueSelected(engine: engine) else { return false }
        return idIsGloballyUnique(engine: engine, id: d.id)
    }

    /// **路由用**（唯一的门）：几何现算。
    static func canToggleLock(engine: TrainingEngine) -> Bool {
        lockableIgnoringGeometry(engine: engine) && selectionGeometryVisible(engine: engine)
    }

    /// **UI 用**：🔒 是否可用。几何读 observable 提示（理由同 `deleteButtonEnabled`）。
    static func lockButtonEnabled(engine: TrainingEngine) -> Bool {
        lockableIgnoringGeometry(engine: engine) && engine.drawingSession.selectionGeometryVisible
    }

    /// **UI 用**：🔒 图标该显示闭锁还是开锁 —— 只反映选中线的 `locked`，无选中取开锁（中性态）。
    static func lockIsOn(engine: TrainingEngine) -> Bool {
        uniqueSelected(engine: engine)?.locked ?? false
    }

    /// 切换选中线的锁定态。`setDrawingLocked` 在 `Sources/` 里的**唯一**调用点。
    @discardableResult
    static func toggleLockSelected(engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        guard let id = engine.drawingSession.selectedDrawingID,
              let current = uniqueSelected(engine: engine) else { return false }
        guard canToggleLock(engine: engine) else { return false }
        return engine.setDrawingLocked(id: id, locked: !current.locked)
    }
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5
```

- [ ] **Step 5: 变异验证**

| 中和什么 | 应变红 |
|---|---|
| 给 `lockableIgnoringGeometry` 加回 `guard !d.locked` | L15（锁定后 🔒 变灰 → 解不开锁） |
| 删掉 `editableIgnoringGeometry` 里的 `!d.locked` | L16 的样式那半 |
| 删掉 `deletableIgnoringGeometry` 里的 `!d.locked` | L16 的 🗑 那半 |
| `canToggleLock` 去掉几何分量 | L18 |
| `lockButtonEnabled` 去掉几何分量 | L15b |
| `lockIsOn` 恒返回 `false` | L17 |
| `toggleLockSelected` 换成空实现 `return false` | **L18b**（L18 仍绿 → 正是正向档的价值） |
| `lockButtonEnabled` 恒返回 `true` | L14 |

- [ ] **Step 6: 提交 + 回头补 Task 4 的调用点守卫**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditRouterTests.swift
git commit -m "feat(1b-ii PR-1): 锁定路由与可用性谓词（D71）—— setDrawingLocked 的唯一调用点"
```
提交后**回到 Task 4 Step 2** 跑 L11，确认调用点守卫此刻转绿。

---

## Task 7: 底栏 ②🔒 与置灰传播（D72）

**Files:**
- Modify: `Sources/KlineTrainerContracts/UI/DrawingModeBar.swift`
- Modify: `Sources/KlineTrainerContracts/UI/TrainingView.swift:262-264`
- Modify: `Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift:101-119`（`bottomBarHasExactlyTwoKeys` → 三键版，见 Step 3）
- Modify: `Tests/KlineTrainerContractsTests/Render/DrawingBottomBarHeightTests.swift:42`（**加参数后既有构造会编译不过**，见 Step 3b）
- Modify: `Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift`（新增 **L8c** —— 契约论点 ① 的 Catalyst 那一半，UIKit-gated 文件，见 Task 2 Step 2 的说明）

> ⚠️ **两处既有测试会被本 task 的签名改动打穿，必须同期改**（codex P-R2-F4，已实测）：
> - `DrawingBottomBarHeightTests.swift:42` = `DrawingBottomBar(typeRowExpanded: .constant(false), deleteEnabled: false, onDelete: {})` —— 加三个必填参数后**编译失败**；
> - `DrawingInteractionUISourceGuardTests.swift:102` `bottomBarHasExactlyTwoKeys` 断言**恰好 2 个 Button** 且 🔒 不渲染 —— 本 task 会让它变红。
>
> **不改它们的后果不是「少测一条」，而是实施者为了让树变绿去削弱这两条守卫本身。**

**Interfaces:**
- Consumes: Task 6 的 `lockButtonEnabled` / `lockIsOn` / `toggleLockSelected`
- Produces: 无（终端 UI）

> ⚠️ **`DrawingModeBar.swift` 是 `#if canImport(UIKit)` 门控的，host `swift test` 上根本不编译。**
> 本 task 的测试与其**变异验证必须上 Catalyst**（Global Constraint #10）。只看 host 绿 = 假绿。

- [ ] **Step 1: 改 `DrawingBottomBar`（插在①类型与③🗑 之间）**

头注改为：
```swift
/// 画线底栏（单行）：①「类型」键 + **②🔒 锁定（1b-ii PR-1）** + ③🗑 删除。
/// ④↩⑤↪ 属 1b-ii PR-2，本期**一个占位都不渲染**（母 spec D19 / D24：不 ship 恒灰的未接线按钮）。
```

新增两个入参（放在 `deleteEnabled` 之前，与 ②在③之前的视觉顺序一致）：
```swift
    /// D71「锁定可用」谓词的结果。**本视图自己不判任何东西**——判据全在 `DrawingEditRouter`。
    let lockEnabled: Bool
    /// 选中线当前是否锁定 —— 只决定图标形态（闭锁 / 开锁），不参与可用性。
    let lockIsOn: Bool
    let onToggleLock: () -> Void
```

在①类型 Button 与③🗑 Button 之间插入：
```swift
            Button(action: onToggleLock) {
                Image(systemName: lockIsOn ? "lock" : "lock.open")
            }
                .accessibilityLabel(lockIsOn ? "解锁" : "锁定")
                .disabled(!lockEnabled)
```

- [ ] **Step 2: 改 `TrainingView.swift:262-264` 的调用点**

```swift
                    DrawingBottomBar(typeRowExpanded: $typeRowExpanded,
                                     lockEnabled: DrawingEditRouter.lockButtonEnabled(engine: engine),
                                     lockIsOn: DrawingEditRouter.lockIsOn(engine: engine),
                                     onToggleLock: { DrawingEditRouter.toggleLockSelected(engine: engine) },
                                     deleteEnabled: DrawingEditRouter.deleteButtonEnabled(engine: engine),
                                     onDelete: { confirmingDeleteDrawing = true })
```

- [ ] **Step 3: 写源码守卫（底栏形状 + 判据来源）**

加到 `DrawingInteractionUISourceGuardTests.swift`：

> ⚠️ **不要新写 L19/L20 —— 改既有的 `bottomBarHasExactlyTwoKeys`**（`DrawingInteractionUISourceGuardTests.swift:101-119`）。
> 它已经在用正确形态：**结构计数读 `code(...)`（squeezed）、用户可见文案与 SF Symbol 名读 `raw(...)`（原始文本）**。
> 我初稿让 L19 用 `squeezedSource` 去断言 `"lock"` 字面量 —— **`squeezedSource` 会丢弃字符串字面量内容**
> （`consumeStringLiteral` 明写「字面文本：丢弃」），所以那条正向断言在**正确实现**上反而会失败，
> 而对 `arrow.uturn.*` 的否定断言则是**恒真的废断言**。这违反了本仓已记的
> 「用户可见文案读原始文本、否定/结构断言剥注释剥字面量」那条守则（codex P-R2-F3）。

**改法：把既有测试从「恰好 2 个按钮」升级为「恰好 3 个」，并补 🔒 的两类断言。**

```swift
@Test("spec §1.1 / D24：底栏**恰好 3 个按钮**（类型 + ②🔒 + ③🗑），④↩⑤↪ 属 PR-2 一个都不渲染")
func bottomBarHasExactlyThreeKeys() throws {
    let bar = try code("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
    // 结构计数（PD7：不是「禁止图标名」黑名单）—— 1b-ii PR-1 把 2 改成 3
    #expect(bar.components(separatedBy: "Button").count - 1 == 3,
            "底栏按钮数不是 3 —— 多了就是把 PR-2 的 ↩↪ 提前 ship 了，少了就是 🔒 或 🗑 没接进来")
    #expect(bar.contains("deleteEnabled"), "🗑 必须由传入谓词置灰，不得自己判")
    #expect(bar.contains(squeeze(".disabled(!deleteEnabled)")))
    #expect(bar.contains("lockEnabled"), "🔒 必须由传入谓词置灰，不得自己判")
    #expect(bar.contains(squeeze(".disabled(!lockEnabled)")))
    // 底栏不得自己读 locked —— 判据必须在路由里（结构断言，读 squeezed 正确）
    #expect(!bar.contains(squeeze("drawing.locked")), "底栏不得自己读 DrawingObject.locked")
    #expect(bar.contains("BottomBarMetrics.height"))
    // ★ 用户可见文案 / SF Symbol 名是**字符串字面量** → 必须读原始文本，且带完整调用语法做锚
    let barRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
    #expect(barRaw.contains("Text(\"类型\")"))
    #expect(barRaw.contains("Image(systemName: \"trash\")"), "③🗑 未接入")
    #expect(barRaw.contains(".accessibilityLabel(\"删除\")"))
    #expect(barRaw.contains("Image(systemName: lockIsOn ? \"lock\" : \"lock.open\")"),
            "🔒 图标没接 lockIsOn —— 图标态不会反映选中线的锁定状态")
    #expect(barRaw.contains(".accessibilityLabel(lockIsOn ? \"解锁\" : \"锁定\")"))
    // ④↩⑤↪ 属 PR-2：本期一个占位都不许渲染（读原始文本才数得到字面量）
    for undoIcon in ["arrow.uturn.backward", "arrow.uturn.forward"] {
        #expect(!barRaw.contains(undoIcon), "\(undoIcon) 属 PR-2，本期不得渲染")
    }
}
```

**并新增一条 `TrainingView` 接线守卫（codex P-R3-F2，high）：**

```swift
/// ⚠️ 只查 `DrawingModeBar.swift` **挡不住**「按钮长得对但根本没接上」：
///   `DrawingBottomBar(lockEnabled: true, lockIsOn: false, onToggleLock: {}, …)` 会让上面那条
///   三键守卫**全绿**，而屏幕上那个 🔒 恒亮、点了没反应。可用性与动作的**真相在路由里**，
///   故必须钉死 `TrainingView` 传进去的就是路由那三个函数。
@Test("底栏 🔒 的可用性/图标态/动作三者都必须接 DrawingEditRouter，不得传常量或空闭包")
func trainingViewWiresLockToRouter() throws {
    let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
    #expect(tv.contains(squeeze("lockEnabled: DrawingEditRouter.lockButtonEnabled(engine: engine)")),
            "🔒 的可用性没接路由 —— 可能传了常量")
    #expect(tv.contains(squeeze("lockIsOn: DrawingEditRouter.lockIsOn(engine: engine)")),
            "🔒 的图标态没接路由")
    #expect(tv.contains(squeeze("DrawingEditRouter.toggleLockSelected(engine: engine)")),
            "🔒 的动作没接路由 —— 可能是空闭包")
}
```

⚠️ **本条读 `code(...)`（squeezed）是对的** —— 断言的是**代码结构**（函数调用），不是字符串字面量；
排版/换行不影响匹配，正是 squeeze 的用途。与上一条读 `raw(...)` 的 SF Symbol 断言**刻意不同**。

- [ ] **Step 3b: 修既有 `DrawingBottomBarHeightTests.swift:42` 的构造**

```swift
        let bar = DrawingBottomBar(typeRowExpanded: .constant(false),
                                   lockEnabled: false, lockIsOn: false, onToggleLock: {},
                                   deleteEnabled: false, onDelete: {})
```
⚠️ 参数顺序必须与 `DrawingBottomBar` 的声明顺序一致（②🔒 在 ③🗑 之前）。

- [ ] **Step 4: host 跑一遍（确认没破坏既有）**

```bash
cd "ios/Contracts" && echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)" && swift test 2>&1 | tail -5
```

- [ ] **Step 5: Catalyst 真跑（本 task 的唯一有效证据）**

```bash
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
xcodebuild test -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -30
```
判绿读 `TEST SUCCEEDED` **且** 执行量与基线一致（Global Constraint #6：不看退出码）。
并跑 `.github/scripts/catalyst-gate.sh` 确认 `GATE PASS`，同步更新 `catalyst-total-baseline.txt` / `catalyst-uikit-baseline.txt`。

- [ ] **Step 6: 变异验证（必须在 Catalyst 上做）**

| 中和什么 | 应变红 |
|---|---|
| 把 `.disabled(!lockEnabled)` 删掉 | 三键守卫 |
| 把 `lockIsOn ? "lock" : "lock.open"` 改成固定 `"lock"` | 三键守卫（raw 那半） |
| 在底栏里加一个 `arrow.uturn.backward` 图标 | 三键守卫（按钮数 3→4 + raw 否定断言） |
| 在底栏里加一句读 `drawing.locked` 的判断 | 三键守卫（结构那半） |
| 把 `TrainingView` 的 `lockEnabled:` 改成常量 `true` | **接线守卫**（三键守卫仍绿 —— 正是 P-R3-F2 指出的缺口） |
| 把 `onToggleLock:` 改成空闭包 `{}` | **接线守卫** |
| 把 `lockIsOn:` 改成常量 `false` | **接线守卫** |

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingModeBar.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingBottomBarHeightTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/KLineViewCompileTests.swift \
        .github/scripts/catalyst-total-baseline.txt .github/scripts/catalyst-uikit-baseline.txt
git commit -m "feat(1b-ii PR-1): 底栏 ②🔒 + 置灰传播（D72）；既有两键守卫与高度测试同期升三键"
git status --porcelain   # 必须为空
```

---

## 收尾：三绿门（作者亲核，缺一不可）

- [ ] **host** `swift test` → 读 `Test run with N tests ... passed`
- [ ] **Catalyst** `xcodebuild test` → `TEST SUCCEEDED` + `catalyst-gate.sh` `GATE PASS` + 闸门自测
- [ ] **iOS app** `xcodebuild build` → `BUILD SUCCEEDED`
- [ ] 三条命令各自打印 branch / HEAD
- [ ] **`git status --porcelain` 必须为空**（codex P-R2-F1/F2）—— 在**脏工作区**里跑绿是假绿：漏 stage 的守卫 helper 会让分支编译不过，漏 stage 的 L13b 等于把 N-F 的唯一主证据丢在本地。
- [ ] **三绿必须在 `git status` 干净之后重跑一遍**，证明「已提交的那棵树」是绿的，而不是「工作区那棵树」是绿的。
- [ ] `git log 567987b..HEAD --oneline` + `git diff --stat 567987b..HEAD` 复核：提交与文件清单**只属本 PR**（防跨 PR 串味）

## 收尾：非程序员验收清单

按 spec §1.7 的 **11 条**执行（真机 iPhone，Debug 构建 + `KLINE_SEED_FIXTURE=1`）。
⚠️ 装机两坑（见 `project_device_testing_requires_seed_fixture`）：构建必须 user 在真终端跑（codesign 需钥匙串授权）；装完必须**先 terminate 再冷启动**，否则 `init()` 不重跑、seed 不生效。

---

## Self-Review（写完计划后自查，已执行）

**1. spec §1 覆盖**：D69 门列表 → Task 1（L1–L5）；D70 raw-preserving → Task 2（L6/L7）；D80 → Task 3（L9/L10）；**N-B 两条判据** → Task 4（L12 语义 `locked:` + **L12b 结构性 `drawings` 写入面**）；N-G 三层 → Task 4（L11）；D73 N14h 翻转 → Task 5；**N-F 落盘** → Task 5（L13a 内存层 + **L13b 真实 save/resume 全链路**）；D71 路由谓词 → Task 6；D72 UI + N-D 置灰 → Task 6(L16)/Task 7。**契约举证（§3 第 3 条两个分量）** → Task 2 的 **L8（选不中）+ L8b（直调也无损）**。

**1b. codex P-R1 补齐的三处**（初稿相对已 approve 的 spec **少交付**，非 spec 缺陷）：
- **F1** N-B 只写了第 1 条判据 → 补 **L12b**。整对象赋值 `drawings[i] = <locked 不同的对象>` 字面上不含 `locked:`，会从 L12 底下整个溜过去，而它正是绕过信任边界的第二条路。
- **F2** N-F 只在内存里 reconcile → 补 **L13b**，经 `CoordinatorTestHarness` 走真实 `saveProgress → endSession → resumePendingReplay`。「锁定改动没真写盘」这个回归会让内存版全绿、却让真机验收 #7/#8 失败。
- **F3** 契约举证只做了「选不中」那半 → 补 **L8b**，含「除 `locked` 外逐字节相同」的主判据（几条 `contains` 证明不了「没有别的字段被悄悄改掉」）。

**2. 占位符扫描**：两处**有意留白**，均已写明「先读哪个既有文件、复用它的哪套构造」——
① Task 6 Step 1 的五条测试体（选中 + 几何可见的 engine 搭法，读 `DrawingEditRouterTests.swift` 既有 `deleteButtonEnabled` 系列）；
② Task 2 L8 的 `CoordinateMapper` viewport（读 `GeometryTests.swift:255`）。
理由是照搬既有构造比我凭空写一份更不容易出错 —— 本仓「计划的**代码块**本身是恒真测试的根因」那条教训明确指向「别在计划里发明测试搭法」。其余步骤均含可直接执行的真代码。

**2b. 内嵌事实逐条实测**（本仓「计划内嵌事实不可靠」教训，2026-08-11 全部跑过）：
`TrainingEngine.preview(mode:)` ✅存在（**`previewReview()` 不存在，初稿写错已修**）· `injectDrawingsForTesting` ✅ · `DrawingHitTester.firstHit` ✅ · `KLineView.drawingTools` ✅ · `LossyDrawingArray.decode` ✅ · `DrawingAnchor` ✅ · `.trend` ✅（逗号列表声明）· `DrawingToolType.implemented == [.horizontal]` ✅ · `makeHorizontalDrawing` ❌需新建（计划已给定义）· `makeTestMapper` ❌不存在（已改为照既有写法自造）· `DrawingBottomBar` 现有入参 = `typeRowExpanded` / `deleteEnabled` / `onDelete` ✅ · 既有守卫模板 N15 在 `TrainingEngineDrawingSessionTests.swift:911-948` ✅

**3. 类型一致性**：`setDrawingLocked(id:locked:)` 在 Task 1 定义、Task 4/5/6 引用一致；`lockButtonEnabled` / `lockIsOn` / `toggleLockSelected` 在 Task 6 定义、Task 7 消费一致；`makeHorizontalDrawing(id:price:locked:)` 在 Task 1 Step 2 定义、Task 1/2/3/5 使用一致。
