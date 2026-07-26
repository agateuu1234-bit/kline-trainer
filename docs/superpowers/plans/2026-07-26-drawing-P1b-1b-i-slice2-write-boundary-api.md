# 划线 P1b-1b-i 切片2（写入边界 API：withStyle + updateDrawingStyle + deleteDrawing(id:)）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 PR-1 已建好的引擎地基上，落成 1b-i 的两个**编辑/删除写入面**——`DrawingObject.withStyle`（failable 语义闸单点）、`TrainingEngine.updateDrawingStyle(id:style:)`、`TrainingEngine.deleteDrawing(id:)`——各自带齐 **viewport 无关**的引擎层门（`withStyle` 语义 / `locked` / 未来未知枚举值 / id 唯一非空），全部 `internal` + 源码守卫，零 UI、host `swift test` 全覆盖。

**Architecture:** 三层单点。① `DrawingStyleAvailability` 收编「该 toolType 下这个 lineSubType 恒可渲染吗」判据（PR-1 已在 `TrainingEngine` 私有实现过一份，本切片提为共享单点，append 家族改为委托）；② 新增纯函数 `DrawingObject.withStyle(_:) -> DrawingObject?` 承载 D59 四条语义（派生① `isExtended`、派生② `textColorToken` **条件**派生、`labelMode` 归一化、`lineSubType` 可用性），**两个写入点共用**（`DrawingSession.commitPending` 与新的 `updateDrawingStyle`）；③ 引擎两个新 API 只 enforce viewport 无关的不变量，几何门按 D65/D51 留在 UI 路由（PR-4），本切片用「Sources/ 中调用点恰好 0 处」的源码守卫把口子焊死，PR-4 接线时该守卫必须同步改成「恰好 1 处且在已先验 `visibleGeometry` 的 UI 路由」。

**Tech Stack:** Swift 5.9 / `@Observable` / SwiftPM（`ios/Contracts`）；测试 `swift test`（host，macOS）+ fresh Catalyst `xcodebuild test`（总数闸）；本切片纯逻辑、无 UIKit。

## Global Constraints

- **完整 spec**：`docs/superpowers/specs/2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md`（决策 D49–D67）。本切片落 **D50 / D51（引擎侧）/ D58（引擎支）/ D59 / D60 / D61 / D62 / D66**。
- ⚠️ **对 spec 的一处显式偏离（user 2026-07-26 裁决，codex plan-R14-F1 触发）——D61 编辑门从「看来源」改为「看结果」**：
  spec D61 原文 = 「对携带未来未知枚举值的线**一律**拒绝改样式」。落地改为：**先算候选、与加载快照归并，只有归并结果仍带本构建不支持的未来数据才拒**。
  - **动机**：一律拒会让这条线只能**整条删掉**才能结束存档（finalize 门本就 fail-closed），删整条的数据损失严格大于「用户显式换掉一个本版本表示不了的色号」。
  - **保护未削弱（两道门）**：③a **可覆盖性预检**——未来值必须全部落在「用户能显式改到」的 key 内（`userCoverableFutureKeys`，**不含 `textColorToken`**：本构建无字色控件，它只会被派生② 隐式改写，codex plan-R19-F2；也不含 `anchors[].period`/`tailAnchor.period`/未来顶层字段），否则一律拒；③b **结果检**——改 thickness 这类没真覆盖到未来值的编辑，归并后仍带 → 拒。两道都过才算「用户显式覆盖」。
  - **已知代价**：一次换线色会把「本来跟随线色」的未来字色一并覆盖（两个未来值解码后都是 `.orange`，派生② 分辨不了）——已用测试钉死并写明是取舍而非缺陷。
  - **判据与 finalize 门同源**（`TrainingSessionCoordinator:729-736` 也是 reconcile 后查同两个门），**但作用域不同**（codex plan-R17-F2）：编辑门只看**被改的那条 id**，finalize 门看**全部存活线 + `unknownRaw`** → 「编辑通过」只意味着**这条线**不再是阻塞项，**不代表整局能存档**（别的未来线 / unknownRaw 仍会拦）。
  - **spec 正文已同步修订**（codex plan-R15-F1：不改 spec 的话，PR-4 照 D65 旧规则把控件灰掉 → 这条修复路径**用户根本点不到**，引擎测试却因直调 API 全绿）：spec 的 D61 加了修订注记、D65 的「未来枚举」置灰分量已删除并写明新 UI 规则 + PR-4 必须补的路由级测试。
- `CONTRACT_VERSION` 保持 **1.12**，`user_version` 保持 **7**，**零迁移**（`DrawingObject` 不新增/不改任何持久化字段；本切片只加运行时 API）。
- **访问级别纪律**：本切片新增的两个写入 API 一律 `internal`，**不得** `public`（D62/D51）。`withStyle` 同为 `internal`。测试经 `@testable import` 照常可调。
- **拒绝 = 零改动 + `drawingsRevision` 不递增 + 返 `false`**：四道门任意一道不过，`drawings` 必须逐字段不变，计数器绝不动（D50/D60/D61/D66 逐条写死）。
- **判据禁止另写第二份**：`lineSubType` 可用性只许来自 `DrawingStyleAvailability`；未来枚举值只许用 `LossyDrawingArray.hasKnownFutureEnumValues(liveIds:)`（**带 `!entries.isEmpty` 语义**，绝不可写成 `knownFutureEnumPayloads()` 的 id-membership，见 D61 ⚠️ / N14f）。
- **几何（`visibleGeometry`）不属于本切片**：引擎没有 mapper，判不了几何（D65 R13-F1 纠正）。本切片**不得**给两个新 API 加任何 geometry 参数或声称挡 geometry。
- **测试基线**：本机 host `swift test` 全绿基线 = **1676 passed / 209 suites**（base `f3f67da` = PR-1 merge 后的 main；**控制者已于本 worktree 亲跑实测**，非引自 memory）。每个 Task 结束时全绿。
- **fresh 非增量 Catalyst 对基线**：本切片新增测试会推高 Catalyst 总数。收尾三绿门必须跑 fresh Catalyst，若总数漂出 `.github/scripts/catalyst-total-baseline.txt`（当前 **1574**）的 ±30 带，按闸门维护规则同步基线三文件，且 `pass-main-current.log` **必须用真 fresh Catalyst 日志重裁**（禁手打伪造行）。
- **CLAUDE.md §3 外科手术**：不删 `DrawingToolManager` 死代码（spec §1.2 明令）、不改无关注释与格式。

---

## 本切片覆盖 vs 交接（防「漏覆盖」误判，评审请先读这张表）

spec §6 的负向测试清单是**整个 1b-i**（4 个 PR）的并集。本切片是**引擎写入边界**，没有选中态、没有 UI 路由、没有 mapper，故只可能覆盖其中的引擎侧断言。

| spec 测试 | 本切片 | 说明 |
|---|---|---|
| N2 `updateDrawingStyle` 只动样式 | ✅ Task 3 | 逐字段不变断言 |
| N3 update 对不存在 id | ✅ Task 3（引擎侧三条断言）；选中清空 → PR-4 | 「UI 侧选中被清空」需选中态 |
| N4 delete 对不存在 id | ✅ Task 5（引擎侧） | 同上 |
| N5 派生规则单点 + 行为 | ✅ Task 1（源码守卫 + `.ray`/`.straight` 行为） | |
| N12a 引擎层 `.segment` 恒开门 | ✅ Task 3 | |
| N12b/c UI viewport 预检 + 反向对照 | ❌ → **PR-4** | 需 mapper 与 UI 路由 |
| N12d 归一化对称（直调传未归一化 style） | ✅ Task 3 | 正是「绕开面板直调」的写法 |
| N13a/b/c `locked` fail-closed + 反向对照 | ✅ Task 4（a/c）、Task 5（b） | |
| N13d `locked` 线仍可被选中 | ❌ → **PR-3**（hitTest）/ PR-4 | |
| N14a/b/e/f/g 未来枚举值门 + 字节保真 + 三条反向对照 | ✅ Task 4 | |
| N14c 删除仍允许（经 UI 删除路由） | ⚠️ **引擎版**在 Task 5（直调引擎 delete + reconcile 后该条已移除）；**路由版** → PR-4 | 分层，两条都要 |
| N14d UI 灰置分岔 | ❌ → **PR-4** | 需控件 |
| N15 update 调用点 + 非 public | ✅ Task 3（本切片语义 = **恰好 0 处**，见 SD-3） | |
| N19a/d 源码守卫（id 版 / index 版） | ✅ Task 5（a 本切片语义）；d **PR-1 已落**（`deleteDrawing(at:` 零调用点，本切片确认不回归） | |
| N19b 引擎层 locked 仍拒 | ✅ Task 5 | |
| N19c/e 路由几何门 / 确认框时间窗 | ❌ → **PR-4** | |
| N21a/b append 拒空/重复 id | **PR-1 已落**（`appendRejectsEmptyAndDuplicateId`） | 本切片不重复 |
| N21c update/delete 匹配非唯一即 fail | ✅ Task 3（update）、Task 5（delete） | |
| N21d 正常路径三条 id 互异 | **PR-1 已落**（`commitPending` UUID） | |
| N1 / N6 / N7 / N8 / N10 / N11 / N16 / N17 / N18 / N20 / N22 / N23 | PR-1 已落（N10/N11/N20/N22/N23）或 → PR-3/PR-4（N1/N6/N7/N8/N16/N17/N18） | |
| （超 spec）D34 复盘门下沉引擎 + normal 反向对照 | ✅ Task 3 / Task 5 | SD-7 纵深防御，spec 只把门放在 UI tap 路径 |

---

## 本切片的子决策（控制者已裁决，实施照做）

- **SD-1 `withStyle` 落新文件** `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift`：它是「四条语义的唯一出处」，独立文件让 N5 源码守卫锚点稳定，也避免把编辑语义塞进 `Models.swift`（那里是纯持久化值类型）。
- **SD-2 两条横线规则都提为 tool-aware 共享单点**：新增 `DrawingStyleAvailability.isRenderableSubType(_:toolType:)` 与 `normalizedLabelMode(current:lineSubType:toolType:)`；`TrainingEngine` 现有私有 helper `isRenderableSubType(_ d:)` 改为**委托**它（保留原大段注释与调用点，append 家族行为逐字不变）；`withStyle` 两者都走 tool-aware 版本。**禁止**在 `withStyle` 里另写 `toolType == .horizontal` 判断，也**禁止**它直接调二参（横线专用）版本。
  > 为什么两条都要（codex plan-R2-F2）：只把 subType 判据做成 tool-aware、却让 labelMode 归一化无条件套横线规则，等于把 PR-1 那个 over-reject bug **只修了一半**——一条 `.trend` 线经这个「工具无关」的写入边界编辑一次，`.show`/`.left` 就被横线规则静默改写成 `.hidden`。规则的适用范围要么全都限定，要么就不叫单点。
- **SD-2b「判据单点」= 规则实现单点，不是调用点单点**（沿用 D65 R13-F1 对 `visibleGeometry` 的同一澄清：「单点约束指函数实现只有一份，不是说四处传同样的入参」）。因此本切片**不动** `UI/DrawingStyleParams.swift`：面板里的 `normalizedLabelMode` 是**控件即时显示规整**、`horizontalLineSubTypeEnabled` 是**控件灰态**，二者都消费同一份规则实现，不是第二份规则。改动它属 UI 层、且会动 1a-iii 的面板行为与既有守卫，超出本切片范围（CLAUDE.md §3）。N5 守卫据此改钉**更有意义的性质**：两个**写入边界**（`withStyle` / append 家族）**不得直接套横规则**，必须经共享单点 `isRenderableSubType` —— 这正是 PR-1 那个 over-reject 真 bug 的根因形状（把只对水平线成立的规则套到所有 toolType）。
- **SD-3 调用点守卫在本切片 = 恰好 0 处**：`updateDrawingStyle(` / `deleteDrawing(id:` 在 `Sources/` 中**零调用点**（唯一合法调用者是 PR-4 的 UI 路由，本切片还没有）。守卫写死 0，并在测试注释里写明：**PR-4 接线时必须把断言改成「恰好 1 处 + 该文件是 UI 路由 + 路由在写入瞬刻先验 `visibleGeometry`」**。这样任何人在没补几何门的情况下新增调用点，测试当场红（fail-closed forcing function）。
- **SD-4 引擎四门顺序**：① id 非空 + 恰好匹配一条（D66）→ ② `locked`（D60）→ ③ 未来未知枚举值（D61，仅 update）→ ④ `withStyle` 语义（D59/D58 引擎支）。四门的可观察行为一致（`false` + 零改动 + 不递增），固定顺序只为可读与测试稳定。
- **SD-5 两个新 API 只作用于 `drawings`**：`reviewDrawings` 不在其内（D34 复盘本期不获得编辑能力；D56 revision 只覆盖 `drawings`）。id 只存在于 `reviewDrawings` 时按「匹配 0 条」返 `false`。
- **SD-6 `@discardableResult`** 按 spec D50 原文保留（返回值供测试与调用方即时判断；**但按 D64，选中生命期绝不看返回值**——那是 PR-4 的事）。
- **SD-7 两个新 API 追加引擎层 `flow.mode != .review` 门（D34 纵深防御，超 spec 字面一行）**：spec D34 把复盘门控定在 `ChartContainerView` 的 tap 路径（UI 层）。但这两个新 API 改的是 `engine.drawings` —— **复盘模式下那正是已归档 record 的原训练线**，改/删它不可逆（本期无 undo），是 spec §4 自己点名的 trust-boundary 危害。UI 门是唯一防线时，PR-4 漏一个分支就直捅归档数据。故引擎自己也 fail-closed（与 D60/D61/D66 同一条纪律：不变量在写入边界强制，UI 门是纵深而非唯一防线）。
  **不会 over-reject**：复盘新画线走 `appendReviewDrawing`→`reviewDrawings`（另一条路），复盘侧删除走 `removeReviewDrawing(at:)`；本期复盘**不获得**任何编辑 `drawings` 的能力（D34），P5 给复盘编辑能力时也是操作 `reviewDrawings` + 层权限门，不经这两个 API。今天两个 API 零调用点 → 零行为变化。

---

## 测试 fixture（本切片新增，追加进既有共享文件）

既有 `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift` 已有 `makeHLine`。本切片**追加两个** helper（同文件，避免同 module 重复声明冲突）：

```swift
// 追加到 DrawingTestFixtures.swift 末尾
import Foundation   // Data（lossy blob 解码）

/// 造一条带完整样式字段的水平线（用于「只动样式」逐字段断言）。
/// ⚠️ `DrawingAnchor.init` 的 label 顺序是 `(period:candleIndex:price:)`（`Models/Models.swift:214` 实测）。
func makeStyledHLine(id: String,
                     lineSubType: LineSubType = .straight, lineStyle: LineStyle = .solid,
                     thickness: Int = 1, colorToken: DrawingColorToken = .orange,
                     labelMode: LabelMode = .hidden, locked: Bool = false,
                     textColorToken: DrawingColorToken = .orange,
                     text: String = "hi", fontSize: Int = 14,
                     period: Period = .daily, candleIndex: Int = 3, price: Double = 10) -> DrawingObject {
    DrawingObject(id: id, toolType: .horizontal,
                  anchors: [DrawingAnchor(period: period, candleIndex: candleIndex, price: price)],
                  isExtended: lineSubType == .ray, panelPosition: 0, revealTick: 7,
                  period: period, lineSubType: lineSubType, lineStyle: lineStyle,
                  thickness: thickness, colorToken: colorToken, labelMode: labelMode,
                  locked: locked, text: text, fontSize: fontSize,
                  textColorToken: textColorToken, textForm: .plain, tailAnchor: nil)
}

/// 造一个携带指定 lossy 集的引擎（D61 未来枚举值门需要 `loadedDrawingsLossy` 非空）。
/// 结构照抄既有 `TrainingEngineInteractionTests.engineWithDrawings`（`:174-186`）：内部 `init` 可
/// 从测试直调（`@testable`），`.m3` 必须覆盖 maxTick（`init` 有 precondition R6-F2）。
@MainActor
func makeEngineWithLossy(_ lossy: LossyDrawingArray) -> TrainingEngine {
    TrainingEngine(
        flow: NormalFlow(fees: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true), maxTick: 99),
        allCandles: TrainingEngineActionsTests.m3Candles(Array(repeating: 10, count: 100)),
        maxTick: 99, initialCapital: 100_000, initialCashBalance: 100_000,
        initialDrawingsLossy: lossy,                       // init 用它派生 drawings（`:176-178`）
        initialUpperPeriod: .m3, initialLowerPeriod: .m3)
}

/// 从一条 raw JSON 造 lossy 集（未来枚举值 fixture 用）。raw 必须是**单条** drawing 的 JSON 对象。
func lossyFromRaw(_ raw: String) throws -> LossyDrawingArray {
    try LossyDrawingArray.decode(Data("[\(raw)]".utf8))
}

/// 「拒绝 = 零改动」的**统一**断言（codex plan-R4-F2）。
/// ⚠️ `DrawingObject.==` **排除 `id`**（`Models.swift` 的 Equatable 实测）→ 只写 `e.drawings == before`
///   的话，一次「把 id 改写了、其它字段都相同」的坏写入会从**所有** no-op 测试底下溜过去，
///   而 id 恰是本切片 select/update/delete 的身份键、也是 lossy 归并的锚。故必须**同时**比 id 序列。
///   每一处「被拒后不变」都用本助手，不要各写各的（判据单点，也免得漏写 id 那半条）。
@MainActor
func expectDrawingsUnchanged(_ e: TrainingEngine, _ before: [DrawingObject], revisionBefore: Int,
                             sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(e.drawings == before, sourceLocation: sourceLocation)
    #expect(e.drawings.map(\.id) == before.map(\.id), "id 序列被改写了", sourceLocation: sourceLocation)
    #expect(e.drawingsRevision == revisionBefore, "拒绝路径不得递增 revision", sourceLocation: sourceLocation)
}
```

> `expectDrawingsUnchanged` 用到 `#expect` / `SourceLocation` → `DrawingTestFixtures.swift` 需 `import Testing`（Swift 的 import 是**文件级**的，别指望别的测试文件的 import）。

> `TrainingEngineActionsTests.m3Candles(_:)` 是同 test module 内的既有 `static func`（`TrainingEngineActionsTests.swift:36`），可直接调用，无需 import。

---

### Task 1: `withStyle` failable 纯函数 + 可用性判据提为共享单点（D59 / D58 引擎支）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift`（追加 `isRenderableSubType(_:toolType:)`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:1136-1139`（私有 helper 改为委托）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift`（**追加**「测试 fixture」节的三个 helper：`makeStyledHLine` / `makeEngineWithLossy` / `lossyFromRaw`——本 Task 的测试就要用 `makeStyledHLine`，故在此一次加齐）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingObjectStyleEditTests.swift`

**Interfaces:**
- Produces:
  - `DrawingStyleAvailability.isRenderableSubType(_ sub: LineSubType, toolType: DrawingToolType) -> Bool`（`public static`，与既有两个 helper 同级）
  - `DrawingStyleAvailability.normalizedLabelMode(current: LabelMode, lineSubType: LineSubType, toolType: DrawingToolType) -> LabelMode`（`public static`，**tool-aware 重载**；非水平工具原样返回，横线委托既有二参版本）
  - `DrawingObject.withStyle(_ s: DrawingDefaultStyle) -> DrawingObject?`（**internal**；`nil` 有两种原因：① 该样式的 `lineSubType` 对本对象 `toolType` 恒不可渲染；② `thickness` 越出 1…5 **且**不等于本对象当前值）
- Consumes: 既有 `DrawingStyleAvailability.horizontalLineSubTypeEnabled` / `normalizedLabelMode`、`DrawingDefaultStyle`（5 字段：`lineSubType`/`lineStyle`/`thickness`/`colorToken`/`labelMode`，`Models/DrawingEnums.swift:28-35`）。

- [ ] **Step 1: 写失败测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingObjectStyleEditTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingObjectStyleEditTests.swift
// Spec: 2026-07-23-drawing-tools-P1b-1b-i-select-edit-delete-design.md D59（四条语义单点）+ D58 引擎支。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("D59 withStyle：四条语义的唯一出处")
struct DrawingObjectStyleEditTests {

    private func style(_ sub: LineSubType = .straight, _ ls: LineStyle = .solid, _ th: Int = 1,
                       _ c: DrawingColorToken = .orange, _ lm: LabelMode = .hidden) -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = sub; s.lineStyle = ls; s.thickness = th; s.colorToken = c; s.labelMode = lm
        return s
    }

    @Test("派生①：isExtended 恒 ==(lineSubType == .ray)")
    func derivesIsExtendedFromSubType() throws {
        let base = makeStyledHLine(id: "a", lineSubType: .straight)
        let ray = try #require(base.withStyle(style(.ray)))
        #expect(ray.isExtended == true)
        let back = try #require(ray.withStyle(style(.straight)))
        #expect(back.isExtended == false)
    }

    @Test("派生②条件派生：字色本来跟线色相同 → 跟随；已是独立字色 → 保留")
    func textColorTokenConditionalDerivation() throws {
        // 跟随：old.textColorToken == old.colorToken
        let follow = makeStyledHLine(id: "a", colorToken: .orange, textColorToken: .orange)
        let f = try #require(follow.withStyle(style(.straight, .solid, 1, .green)))
        #expect(f.textColorToken == .green)
        // 保留：old.textColorToken(.blue) != old.colorToken(.orange)（known 独立字色，D61 raw-aware 拦不住它）
        let independent = makeStyledHLine(id: "b", colorToken: .orange, textColorToken: .blue)
        let g = try #require(independent.withStyle(style(.straight, .solid, 1, .green)))
        #expect(g.textColorToken == .blue)
        #expect(g.colorToken == .green)
    }

    @Test("归一化：(ray, .left) 不可表达 → labelMode 落 .hidden；(ray, .right) 原样")
    func normalizesLabelMode() throws {
        let base = makeStyledHLine(id: "a")
        let r = try #require(base.withStyle(style(.ray, .solid, 1, .orange, .left)))
        #expect(r.labelMode == .hidden)
        let r2 = try #require(base.withStyle(style(.ray, .solid, 1, .orange, .right)))
        #expect(r2.labelMode == .right)
    }

    @Test("可用性：水平线 .segment 恒不可渲染 → nil（合法子类型放行做反向对照）")
    func rejectsUnrenderableSubTypeForHorizontal() throws {
        let h = makeStyledHLine(id: "a")
        #expect(h.withStyle(style(.segment)) == nil)
        #expect(h.withStyle(style(.straight)) != nil)
        #expect(h.withStyle(style(.ray)) != nil)
    }

    @Test("工具门（codex plan-R11-F1）：本构建未实现的**已知**工具 → 整条不可编辑（改写保守）")
    func rejectsEditingUnimplementedKnownToolTypes() throws {
        // `.trend` 是**已知**枚举 case（`Models.swift:39`）→ 高版本写的这类线解码后一切"正常"，
        // D61 的 raw-aware 门看不见它；不设工具门的话，本构建会拿水平线的样式假设不可逆地改写它。
        let trend = DrawingObject(id: "t", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                  isExtended: false, panelPosition: 0, period: .daily)
        // ⚠️ `withStyle` **不含**工具门（R15-F2：它也服务新建路径）→ 这里必须**放行**；
        //    「未实现工具不可编辑」由 `updateDrawingStyle` 落实（Task 4 的引擎级测试钉死）。
        #expect(trend.withStyle(style(.straight)) != nil)
        #expect(trend.withStyle(style(.segment)) != nil)       // 横规则也不适用于它
        #expect(DrawingStyleAvailability.isEditableToolType(.trend) == false)
        #expect(DrawingStyleAvailability.isEditableToolType(.horizontal) == true)
        // 判据 = 既有单一真相 `DrawingToolType.implemented`（能不能画，codex plan-R12-F2：不另立登记表）
        //        **∧** `toolsWithStyleMatrix`（本构建懂不懂它的样式语义，codex plan-R13-F2）
        typealias A = DrawingStyleAvailability
        for t: DrawingToolType in [.horizontal, .trend, .text, .ray, .fib, .rect] {
            #expect(A.isEditableToolType(t) ==
                    (DrawingToolType.implemented.contains(t) && A.toolsWithStyleMatrix.contains(t)),
                    "\(t) 的可编辑性必须 = 已实现 ∧ 有样式矩阵")
        }
        // 漂移告警（fail-closed 方向）：今天两集合恰好相等；P1c 若只把新工具加进 implemented
        // 而没写样式矩阵，本断言当场红 —— 提醒补矩阵，而不是让它悄悄变成可编辑。
        #expect(DrawingToolType.implemented == A.toolsWithStyleMatrix,
                "有工具能画却没有样式矩阵（或反之）：implemented=\(DrawingToolType.implemented) matrix=\(A.toolsWithStyleMatrix)")
        // ⚠️ 与 append 侧**刻意不对称**：同一条 `.trend`+`.segment` 线经 `appendDrawing` 仍必须被接收
        //    （PR-1 的 `nonHorizontalSegmentAccepted` 钉死，本切片不得回归）——进来宽松、改写保守。
    }

    @Test("值域闸（codex plan-R4-F1）：越域 thickness 写不进来，但对象已有的越域值可原样带回")
    func thicknessDomainGateIsConditional() throws {
        let d = makeStyledHLine(id: "a", thickness: 2)
        // 合法域内：放行
        #expect(d.withStyle(style(.straight, .solid, 5))?.thickness == 5)
        #expect(d.withStyle(style(.straight, .solid, 1))?.thickness == 1)
        // 越域**新值**：拒（0 / 负 / 极大）——直接调用者塞不进坏数据
        #expect(d.withStyle(style(.straight, .solid, 0)) == nil)
        #expect(d.withStyle(style(.straight, .solid, -3)) == nil)
        #expect(d.withStyle(style(.straight, .solid, 999_999)) == nil)
        // 反向对照（防过度拒绝）：一条**已经**带越域值的线（模拟高版本 thickness=8 解码进来），
        // 只改颜色、thickness 原样带回 → **必须放行**，且 thickness 逐字保留
        let future = makeStyledHLine(id: "f", thickness: 8)
        let edited = try #require(future.withStyle(style(.straight, .solid, 8, .green)))
        #expect(edited.thickness == 8)
        #expect(edited.colorToken == .green)
        // 但对同一条线写入**另一个**越域值 → 仍拒（不是"这条线从此免检"）
        #expect(future.withStyle(style(.straight, .solid, 9)) == nil)
    }

    @Test("归一化 tool-aware（codex plan-R2-F2）：横规则只对横工具成立")
    func labelModeNormalizationIsToolAware() throws {
        typealias A = DrawingStyleAvailability
        // 直调重载本身：`withStyle` 现在被工具门挡在更前面（R11-F1），非水平走不到归一化那一步，
        // 故这条规则要在这里单测——它是「P1c 把新工具加进 `DrawingToolType.implemented` 时不会重蹈 R2-F2」的保险。
        #expect(A.normalizedLabelMode(current: .left, lineSubType: .ray, toolType: .horizontal) == .hidden)
        #expect(A.normalizedLabelMode(current: .right, lineSubType: .ray, toolType: .horizontal) == .right)
        #expect(A.normalizedLabelMode(current: .show, lineSubType: .straight, toolType: .horizontal) == .hidden)
        #expect(A.normalizedLabelMode(current: .left, lineSubType: .ray, toolType: .trend) == .left)
        #expect(A.normalizedLabelMode(current: .show, lineSubType: .straight, toolType: .trend) == .show)
        // 横线经 withStyle 的实际行为（两道门叠加后）
        let h = makeStyledHLine(id: "h")
        #expect(h.withStyle(style(.ray, .solid, 1, .orange, .left))?.labelMode == .hidden)
        #expect(h.withStyle(style(.straight, .solid, 1, .orange, .show))?.labelMode == .hidden)
    }

    @Test("只动 5 样式字段 + 两个派生：其余字段逐字段原样拷贝")
    func copiesEveryOtherFieldVerbatim() throws {
        let old = makeStyledHLine(id: "a", thickness: 2, locked: true, text: "hello", fontSize: 21)
        let new = try #require(old.withStyle(style(.straight, .dash1, 4, .green, .right)))
        #expect(new.id == old.id)
        #expect(new.toolType == old.toolType)
        #expect(new.anchors == old.anchors)
        #expect(new.period == old.period)
        #expect(new.panelPosition == old.panelPosition)
        #expect(new.revealTick == old.revealTick)
        #expect(new.locked == old.locked)                    // withStyle 不碰 locked（改不改得动由引擎门决定）
        #expect(new.text == old.text)
        #expect(new.fontSize == old.fontSize)
        #expect(new.textForm == old.textForm)
        #expect(new.tailAnchor == old.tailAnchor)
        // 5 样式字段确实换了
        #expect(new.lineStyle == .dash1)
        #expect(new.thickness == 4)
        #expect(new.colorToken == .green)
        #expect(new.labelMode == .right)
    }

    // ⚠️ N5 源码守卫（四条语义单点）**不在本 Task**，在 Task 2（codex plan-R1-F2）：
    //    本 Task 结束时 `DrawingSession.commitPending` 里那份 `isExtended: s.lineSubType == .ray` 还在
    //    （它到 Task 2 才被 withStyle 取代）→ 守卫此刻必红，破坏「每 task 各自绿再 commit」的节奏。
    //    守卫必须跟着「最后一份重复语义被消灭」的那个 Task 落地。
}
```

（下面这段 N5 守卫代码是 **Task 2 Step 4** 要加的，放在此处仅供对照阅读，实施时按 Task 2 的指示写入同一个测试文件：）

```swift
    @Test("N5 源码守卫：D59 四条语义单点 + 写入边界不得直接套横规则")
    func fourSemanticsSingleSource() throws {
        let contracts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // ios/Contracts
        // 扫**全部 target**（codex plan-R8-F1）：本包有 KlineTrainerContracts / KlineTrainerPersistence 两个，
        // 只扫前者会漏掉跨 target 的第二份语义。实测后者不含这四条语义的任何表达式，故计数不变。
        let root = contracts.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)                                  // 先证明真的扫到文件（防路径写错→恒过）
        /// **复用 Task 2 建的共享扫描器**（codex plan-R13-F3）：逐行 substring 会漏掉
        /// `lineSubType ==\n .ray` / `textColorToken ==\n colorToken` 这种普通换行写法 →
        /// 第二份实现可以静默存在而守卫仍绿。squeeze 后匹配与排版无关，且注释/字符串已被剥掉。
        /// 返回 `[(文件名, 出现次数)]`，只列出现过的文件。
        func hits(_ needle: String, excluding excluded: Set<String> = []) throws -> [(file: String, count: Int)] {
            try files.filter { !excluded.contains($0.lastPathComponent) }.compactMap { f in
                let s = try squeezedText(String(contentsOf: f, encoding: .utf8))
                let n = s.components(separatedBy: squeeze(needle)).count - 1
                return n > 0 ? (f.lastPathComponent, n) : nil
            }
        }
        func total(_ needle: String, excluding excluded: Set<String> = []) throws -> Int {
            try hits(needle, excluding: excluded).map(\.count).reduce(0, +)
        }
        // ⚠️ `DrawingToolManager.swift` 是 1a-iv 交接①记录在案的**死代码**（spec §1.2 明令本期不动、
        //    §8 #5 列为已知限制），它里面那份 `isExtended: lineSubType == .ray` 不参与任何活路径 →
        //    从计数中排除，并在此写明理由（不排除的话本守卫会因「不许改的代码」永远红）。
        let dead: Set<String> = ["DrawingToolManager.swift"]
        // 派生①②：活代码里各恰好一处，且都在 withStyle 所在文件
        let ray = try hits("lineSubType == .ray", excluding: dead)
        #expect(try total("lineSubType == .ray", excluding: dead) == 1, "派生① 不止一处：\(ray)")
        #expect(ray.allSatisfy { $0.file == "DrawingObjectStyleEdit.swift" })
        let txt = try hits("textColorToken == colorToken", excluding: dead)
        #expect(try total("textColorToken == colorToken", excluding: dead) == 1, "派生② 不止一处：\(txt)")
        #expect(txt.allSatisfy { $0.file == "DrawingObjectStyleEdit.swift" })
        // 归一化 / 可用性：**规则实现**单点（横线规则体只有一份，且都在 DrawingStyleAvailability.swift），
        // 调用点允许多处（面板灰态/即时规整是同一份规则的消费者，非第二份规则——SD-2b）。
        #expect(try total("func horizontalLabelModeEnabled(") == 1)          // 横线 labelMode 规则体
        #expect(try hits("func horizontalLabelModeEnabled(").allSatisfy { $0.file == "DrawingStyleAvailability.swift" })
        #expect(try total("func horizontalLineSubTypeEnabled(") == 1)        // 横线 subType 规则体
        #expect(try hits("func horizontalLineSubTypeEnabled(").allSatisfy { $0.file == "DrawingStyleAvailability.swift" })
        // 归一化的两个重载（横线版 + tool-aware 版）都只许住在 DrawingStyleAvailability.swift
        #expect(try total("func normalizedLabelMode(") == 2)
        #expect(try hits("func normalizedLabelMode(").allSatisfy { $0.file == "DrawingStyleAvailability.swift" })
        // 写入边界确实归一化了，且**走 tool-aware 那个重载**（codex plan-R2-F2：无条件套横规则会改写 .trend 的 labelMode）
        #expect(try hits("normalizedLabelMode(current:").contains { $0.file == "DrawingObjectStyleEdit.swift" })
        #expect(try hits("toolType: toolType").contains { $0.file == "DrawingObjectStyleEdit.swift" })
        // **核心**（PR-1 over-reject 真 bug 的根因形状）：两个写入边界**不得直接套横规则**，
        // 必须经共享单点 `isRenderableSubType(_:toolType:)`——横规则只对水平工具成立，直接套会对
        // 非水平工具（P1c 的 .trend 线段）静默拒掉合法数据。
        let rawHorizontalRule = try hits("horizontalLineSubTypeEnabled(")
        #expect(!rawHorizontalRule.contains { $0.file == "TrainingEngine.swift" },
                "append 家族必须走 isRenderableSubType 共享单点：\(rawHorizontalRule)")
        #expect(!rawHorizontalRule.contains { $0.file == "DrawingObjectStyleEdit.swift" },
                "withStyle 必须走 isRenderableSubType 共享单点：\(rawHorizontalRule)")
        // labelMode 侧同理（codex plan-R2-F2）：写入边界不得直接套横线 labelMode 规则
        let rawLabelRule = try hits("horizontalLabelModeEnabled(")
        #expect(!rawLabelRule.contains { $0.file == "DrawingObjectStyleEdit.swift" },
                "withStyle 必须走 tool-aware 归一化，不得直接套横线 labelMode 规则：\(rawLabelRule)")
        let shared = try hits("isRenderableSubType(")
        #expect(shared.contains { $0.file == "TrainingEngine.swift" })
        #expect(shared.contains { $0.file == "DrawingObjectStyleEdit.swift" })
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter DrawingObjectStyleEditTests 2>&1 | tail -20`
Expected: 编译失败 `value of type 'DrawingObject' has no member 'withStyle'`。

- [ ] **Step 3: 实现（四处改动）**

**① 新建** `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift`：

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift
// D59（1b-i 切片2）：`DrawingObject` 的**样式语义闸单点**。四条语义在源码中各只出现这一次：
//   派生① isExtended == (lineSubType == .ray)
//   派生② textColorToken **条件**派生（本来跟线同色的才继续跟随；已是独立字色则保留）
//   归一化 labelMode 必须过 DrawingStyleAvailability.normalizedLabelMode（挡 (ray,.left)）
//   可用性 lineSubType 必须是该 toolType 恒可渲染的值（水平线的 .segment 恒不可渲染 → nil）
// 两个写入点共用（DrawingSession.commitPending / TrainingEngine.updateDrawingStyle），各自传播失败——
// 不许任何调用方"自己派生一遍"或"信任面板会归一化"（D59：public/internal 写入面必须自己把关）。
extension DrawingObject {
    /// nil = 该样式对本对象语义上不成立（① 该 `toolType` 下 `lineSubType` 恒不可渲染，如水平线的 `.segment`；
    /// ② `thickness` 越出本构建的 1…5 值域**且**与本对象当前值不同，见下）。
    /// 非 nil 时：只换 5 个样式字段 + 两个派生字段，其余字段逐字段原样拷贝。
    func withStyle(_ s: DrawingDefaultStyle) -> DrawingObject? {
        // ⚠️ **工具门不在这里**（codex plan-R15-F2）：`withStyle` 同时服务**新建**（`commitPending`）与
        //   **编辑**（`updateDrawingStyle`）。把「只有已写出样式矩阵的工具才准动」塞进这里，会让 P1c
        //   新工具「能激活却提交失败、静默丢锚不出线」。编辑门属于编辑面 → 放在 `updateDrawingStyle`。
        guard DrawingStyleAvailability.isRenderableSubType(s.lineSubType, toolType: toolType) else { return nil }
        // 值域闸（codex plan-R4-F1）：`DrawingDefaultStyle.thickness` 是裸 `Int`、文档域 1…5
        // （`DrawingEnums.swift:31`），面板控件只产 1…5，但**直接调用者**能塞 0 / 负数 / 极大值，
        // 经 updateDrawingStyle 落库并 autosave；渲染器那层 clamp 只会**掩盖**坏数据不会阻止它
        // （同 P1a「持久化 fontSize 可为负」那族，[[feedback_internal_review_misses_bad_data]]）。
        // ⚠️ **条件式，不是一律拒**（否则过度拒绝，重犯 PR-1 的 over-reject）：`thickness` 是 Int 不是枚举，
        //    D61 的 raw-aware 判据**看不见**高版本写的 thickness=8 这类值。若无条件要求 1…5，
        //    PR-4 按 D49 派生回显把 8 原样传回来时，这条线连改颜色都会被拒死。
        //    故：**写入一个新的越域值 → 拒**；**原样带回本对象已有的越域值 → 放行**（不代高版本决定它的粗细，
        //    与 D52「装载不加闸」、D61「不认识的就别改」同一条纪律）。
        guard (1...5).contains(s.thickness) || s.thickness == thickness else { return nil }
        return DrawingObject(
            id: id, toolType: toolType, anchors: anchors,
            isExtended: s.lineSubType == .ray,                     // 派生①
            panelPosition: panelPosition, revealTick: revealTick,
            period: period,
            lineSubType: s.lineSubType, lineStyle: s.lineStyle,
            thickness: s.thickness, colorToken: s.colorToken,
            // 归一化必须 **tool-aware**（codex plan-R2-F2）：横线规则只对 .horizontal 成立，
            // 无条件套会把 .trend 等工具的 .show/.left 静默改写成 .hidden（与 .segment over-reject 同族）。
            labelMode: DrawingStyleAvailability.normalizedLabelMode(current: s.labelMode,
                                                                    lineSubType: s.lineSubType,
                                                                    toolType: toolType),
            locked: locked,                                        // 本函数不碰 locked（能不能改由引擎门 D60 判）
            text: text, fontSize: fontSize,
            // 派生②（条件，codex R11-F1）：known 独立字色（如 orange 线 + blue 标签）必须保住；
            // 无条件 `= s.colorToken` 会把它抹成线色。unknown 枚举那一类由 D61 整条拒编辑兜住。
            textColorToken: textColorToken == colorToken ? s.colorToken : textColorToken,
            textForm: textForm, tailAnchor: tailAnchor)
    }
}
```

**② 追加**到 `DrawingStyleAvailability.swift`（放在 `horizontalLineSubTypeEnabled` 之后）：

```swift
    /// D59/D67 共享单点：该 `toolType` 下 `lineSubType` 是否**恒可渲染**（与 viewport 无关）。
    /// append 家族的引擎门、`DrawingObject.withStyle` 的可用性闸、设置面板的线型灰态**三处共用**它，
    /// 禁止各写一份（D59「与设置面板灰态同一真相」）。
    /// ⚠️ 横规则**只对水平工具成立**（`horizontalLineSubTypeEnabled` 的头注：本期只实现水平线）——
    /// 对非水平工具无条件套它，会把合法的 `.trend` 线段在共享写入边界静默拒掉（codex WB re-attest R1 实证）。
    public static func isRenderableSubType(_ sub: LineSubType, toolType: DrawingToolType) -> Bool {
        guard toolType == .horizontal else { return true }   // 非水平：横规则不适用（矩阵属 P1c）
        return horizontalLineSubTypeEnabled(sub)
    }

    /// 该工具的样式语义是否被本构建理解 → **能否编辑**（codex plan-R11-F1）。
    /// ⚠️ **复用既有单一真相 `DrawingToolType.implemented`**（`Models.swift:50`），**绝不另立第二份登记表**
    ///   （codex plan-R12-F2：我上一稿真的另写了一个 `implementedToolTypes`，那会在 P1c 打开新工具时漂移成
    ///   「画得出、样式控件却永远不生效」）。该集合已被激活门（`TrainingEngine:1259`）与落锚阈值
    ///   （`DefaultDrawingInputController:43`，其注释原文「单一真相派生」）消费 —— 编辑面跟着它走，
    ///   P1c 只要照常把新工具加进 `DrawingToolType.implemented`，可编辑性**自动**跟上，无需记住第二处。
    /// ⚠️ **与 `isRenderableSubType`（append 侧）刻意不对称，别"统一"掉**：
    ///   - **append = 数据进来**：拒绝 = 静默丢掉用户/高版本已有的线 → 必须宽松（PR-1 over-reject 的教训）；
    ///   - **编辑 = 改写已有数据**：`DrawingToolType` 把 `.trend`/`.text` 等目标工具**已声明为已知 case**，
    ///     故一条高版本 `.trend` 线解码后是 known 值、**D61 的 raw-aware 门看不见它** → 若放行编辑，
    ///     本构建就会拿**水平线的样式假设**改写一条自己根本渲染不出的线，且不可逆（本期无 undo）。
    ///   与 D61「高版本线：选得中、改不动样式、可整条删」逐字同构 —— 同一条纪律，只是判据从
    ///   「未知枚举值」扩到「已知但本构建未实现的工具」。
    /// 一次样式编辑中，**用户能显式改到**的持久化 key（codex plan-R19-F2）。
    /// 用途：判断一条高版本线携带的未来枚举值**能不能被用户主动覆盖掉**（→ 可修复），
    /// 还是只会被**隐式**改写 / 根本碰不到（→ 必须拒，字节保真）。
    /// ⚠️ **不含 `textColorToken`**：本构建没有字色控件（独立字色属 P3），它只由 D59 派生② 隐式跟随线色 →
    ///   把它算作"可覆盖"，等于允许"用户改线色 → 顺手抹掉一条看不见的高版本字色"。
    /// ⚠️ 不含 `anchors[].period` / `tailAnchor.period`（样式不碰锚点）、不含任何未来顶层字段（无控件可覆盖）。
    /// UI 的置灰谓词（D65）与本判据**必须共用它**，禁止各写一份 key 集合。
    public static let userCoverableFutureKeys: Set<String> =
        ["lineSubType", "lineStyle", "thickness", "colorToken", "labelMode", "isExtended"]

    /// 本构建**写得出样式矩阵**的工具集。与 `DrawingToolType.implemented`（= 画得出 / 提交得了）
    /// **是两件不同的事**（codex plan-R13-F2）：那个集合回答"能不能画"，本集合回答"本构建懂不懂它的
    /// 样式语义"。今天只有水平线有矩阵（`horizontalLineSubTypeEnabled` / `horizontalLabelModeEnabled`）。
    /// ⚠️ P1c 给新工具接线时：加进 `DrawingToolType.implemented` 之后它就能画了，但**样式仍改不动**，
    ///   直到你为它写出子类型/标注矩阵并加进本集合 —— 这个方向的漂移是 **fail-closed**（现象是
    ///   "新工具的样式控件不生效"，一眼可见、且不污染数据），比反过来 fail-open
    ///   （尚无矩阵就允许编辑 → 把不受支持的样式组合持久化）安全。
    static let toolsWithStyleMatrix: Set<DrawingToolType> = [.horizontal]

    public static func isEditableToolType(_ t: DrawingToolType) -> Bool {
        DrawingToolType.implemented.contains(t) && toolsWithStyleMatrix.contains(t)
    }

    /// D59 共享单点（tool-aware 版）：写入边界用的 `labelMode` 归一化。
    /// ⚠️ **与 `isRenderableSubType` 必须对称**（codex plan-R2-F1... 见 R2-F2）：`normalizedLabelMode(current:lineSubType:)`
    /// 里那条「射线不能配『左』」是**水平线的**规则（`horizontalLabelModeEnabled` 头注：母 spec §3.1 水平线行）。
    /// 若 `withStyle` 这种**工具无关**的写入边界无条件套它，一条 `.trend` 线的 `.show` / `.left` 会被按横线规则
    /// 静默改写成 `.hidden` —— 与 PR-1 那个 `.segment` over-reject **同族**（把只对某类型成立的规则套到所有类型）。
    /// 非水平工具：原样返回（它们的 labelMode 矩阵属 P1c，本期不替它们做决定）。
    public static func normalizedLabelMode(current: LabelMode, lineSubType: LineSubType,
                                           toolType: DrawingToolType) -> LabelMode {
        guard toolType == .horizontal else { return current }
        return normalizedLabelMode(current: current, lineSubType: lineSubType)
    }
```

**③ 改** `TrainingEngine.swift:1136-1139` 的私有 helper 为委托（**保留其上方整段注释一字不动**）：

```swift
    private func isRenderableSubType(_ d: DrawingObject) -> Bool {
        DrawingStyleAvailability.isRenderableSubType(d.lineSubType, toolType: d.toolType)
    }
```

**④ 追加测试 fixture**：把「测试 fixture」节的 `makeStyledHLine` / `makeEngineWithLossy` / `lossyFromRaw` 三个 helper 原样追加到 `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift` 末尾（本 Task 的测试用 `makeStyledHLine`，后两个供 Task 4 用；一次加齐避免同 module 重复声明冲突）。

> ⚠️ **本 Task 不动 `UI/DrawingStyleParams.swift`**（SD-2b）：面板里的 `normalizedLabelMode`（即时显示规整）与 `horizontalLineSubTypeEnabled`（控件灰态）都是**同一份规则实现的消费者**，不是第二份规则；改它属 UI 层、会动 1a-iii 已交付的面板行为和 `Render/DrawingStylePanelSourceGuardTests.swift:32` 既有守卫，超出本切片范围（CLAUDE.md §3）。N5 守卫钉的是**写入边界不得直接套横规则**（见 Step 1 的测试）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter "DrawingObjectStyleEditTests|DrawingStyleAvailability" 2>&1 | tail -20`
Expected: 全部 PASS。

- [ ] **Step 5: 全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: `Test run with N tests passed`（N = 基线 1676 + 本 Task 新增条数；无 failure）。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingObjectStyleEditTests.swift
git commit -m "划线 1b-i 切片2 Task1：withStyle 语义闸单点 + 可用性判据共享单点（D59/D58 引擎支）"
git status --porcelain   # 期望：空输出（codex plan-R14-F3：防新建文件漏 add）
```

---

### Task 2: `commitPending` 改走 `withStyle`（D59 两个写入点共用同一份语义）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift:146-176`（`commitPending`）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift:161-186`（`atomicStyleConstruction` 守卫改锚）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift`（**共享**源码守卫扫描器，顶层函数；含 `allSwiftFilesUnderSources()`，root = 整个 `Sources/`，覆盖全部 target）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScannerTests.swift`（扫描器自检 a–f）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（删掉 PR-1 的 `contractsDir` / `allSwiftFilesUnderSources()` / `trainingEnginePath` 三个 suite 私有版本，改用共享顶层函数；改完既有 `appendFamilyTrustBoundary` 必须仍绿）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`（追加）

**Interfaces:**
- Consumes: Task 1 的 `DrawingObject.withStyle(_:)`。
- Produces: `commitPending(panelPosition:)` 的返回对象**必然**满足 D59 四条语义；样式语义不成立时返 `nil`（不提交）。

- [ ] **Step 1: 写失败测试**

追加到 `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`：

```swift
    @Test("D59：commitPending 经 withStyle —— (ray,.left) 在提交那一刻被归一成 .hidden（不靠面板自觉）")
    @MainActor func commitNormalizesLabelModeAtWriteBoundary() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray
        s.labelMode = .left                                  // 面板产不出的非法组合，直接塞进会话默认样式
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        let d = e.drawingSession.commitPending(panelPosition: 0)
        #expect(d?.labelMode == .hidden)                     // 写入边界归一化
        #expect(d?.isExtended == true)                       // 派生① 仍成立
    }

    @Test("D59：commitPending 对语义不成立的样式返 nil（水平线 .segment）——不提交、不落库")
    @MainActor func commitRejectsUnrenderableSubType() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.lineSubType = .segment                             // 面板里恒灰，但直接设进会话是可达的
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.commitPending(panelPosition: 0) == nil)
        #expect(e.drawingSession.pendingAnchors.isEmpty)     // 拒交同样只丢 pending（保工具/保会话，D31）
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.activeDrawingTool == .horizontal)
    }

    @Test("D59 值域闸也覆盖新建路径（codex plan-R4-F1）：越域 thickness 的默认样式 → 不提交")
    @MainActor func commitRejectsOutOfDomainThickness() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.thickness = 0                                      // 面板产不出，但直接设进会话可达
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        #expect(e.drawingSession.commitPending(panelPosition: 0) == nil)
        #expect(e.drawings.isEmpty)                          // 没有坏数据落进 drawings
    }

    @Test("行为等价：正常样式提交后 5 字段 + textColorToken 跟随，与切片2 之前逐字一致")
    @MainActor func commitStillCarriesStyleAtomically() {
        let e = TrainingEngine.preview()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        var s = DrawingDefaultStyle()
        s.lineSubType = .straight; s.lineStyle = .dash1; s.thickness = 3
        s.colorToken = .green; s.labelMode = .right
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(DrawingAnchor(period: .m60, candleIndex: 1, price: 10), panel: .upper)
        let d = e.drawingSession.commitPending(panelPosition: 0)
        #expect(d?.lineSubType == .straight)
        #expect(d?.lineStyle == .dash1)
        #expect(d?.thickness == 3)
        #expect(d?.colorToken == .green)
        #expect(d?.labelMode == .right)
        #expect(d?.textColorToken == .green)                 // 新线恒「字色跟随线色」（派生② 条件成立）
        #expect(d?.isExtended == false)
    }
```

> 若 `TrainingEngineDrawingCommitTests.swift` 缺 `import CoreGraphics`（`CGRect`）请按文件头既有 import 补齐；`setDefaultStyle` 是既有 internal mutator（`DrawingSession`）。

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter "commitNormalizesLabelModeAtWriteBoundary|commitRejectsUnrenderableSubType" 2>&1 | tail -20`
Expected: FAIL —— 现状 `commitPending` 直接取 `s.labelMode`（不归一化）、也不拒 `.segment`。

- [ ] **Step 3: 实现**

把 `DrawingSession.commitPending` 的构造段改为「先造裸对象，再过 `withStyle`」：

```swift
        let s = defaultStyle
        // D59（切片2）：样式语义闸**单点** —— 派生①②/归一化/可用性全部由 withStyle 承担，
        // 本函数不再自己派生任何字段（否则就有第二份语义，面板归一化一改就漂）。
        // 基对象只带「与样式无关」的部分：锚 / 工具 / 面板位 / period（由 init 从 anchors 取，D29）。
        let base = DrawingObject(
            toolType: tool,
            anchors: pendingAnchors,
            isExtended: false,          // 占位：随后由 withStyle 的派生① 覆盖
            panelPosition: panelPosition,
            revealTick: 0)              // 真值由 engine.routeDrawingCommit 盖
        discardPendingAnchors()
        return base.withStyle(s)        // nil = 该样式语义不成立（水平线 .segment）→ 不提交
```

> ⚠️ `discardPendingAnchors()` 必须在 `return` 之前（保持既有语义：**提交或拒交都只丢 pending**，工具与会话存活）。`base` 的 `colorToken`/`textColorToken` 取 `DrawingObject.init` 默认（都是 `.orange`）→ 相等 → 派生② 走「跟随」分支 → `textColorToken == s.colorToken`，与切片2 之前逐字一致。

- [ ] **Step 4: 改既有源码守卫锚点**

`DrawingSessionSourceGuardTests.swift:161-186` 的 `atomicStyleConstruction` 现在钉的是 `commitPending` 里的 5 行 `lineSubType: s.lineSubType` 字面量——它们已被 `withStyle` 取代。把该测试的 `DrawingSession` 那半段改为：

```swift
        let s = try source(drawingSession)
        #expect(s.contains("func commitPending("))       // 先证真读到文件（防路径错→空→假绿）
        // 切片2（D59）：5 样式字段不再在这里逐个抄，改为整体过 withStyle（语义闸单点）。
        #expect(s.contains("base.withStyle(s)"))
        for f in ["lineSubType: s.lineSubType", "colorToken: s.colorToken"] {
            #expect(!s.contains(f), "commitPending 不得再自行灌样式字段（第二份语义会漂）")
        }
```

`TrainingEngine` 那半段（`routeDrawingCommit` 整体透传 5 字段 + 无 append-then-replace）**一字不动**。

- [ ] **Step 5: 建源码守卫扫描器（共享文件）+ 自检测试（codex plan-R13-F3）**

⚠️ **为什么提成共享文件**：N5 语义单点守卫原本用「逐行 substring」，而 `lineSubType ==\n.ray` / `textColorToken ==\n colorToken` 这种**普通换行写法**会让第二份实现躲过计数（codex plan-R13-F3）→ 单点不变量可以静默回归。扫描器只能有**一份**，两个 suite 共用。

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift`（**同 test module 的顶层函数**，各 suite 直接调用，禁止再抄局部实现）：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift
// 源码守卫共享扫描器（codex plan R1/R2/R3/R7/R8/R9/R10/R13 逐轮收紧的产物）。
// ⚠️ Swift import 是**文件级**的，本文件必须自带。
// ⚠️ 这些函数**不得**加 `private`（codex plan-R14-F2）：顶层 `private` 在 Swift 里是**文件作用域**，
//    加了之后 SourceGuardScannerTests / TrainingEngineDrawingSessionTests 根本调不到 → 整个 Task 编译失败。
import Foundation
import Testing
@testable import KlineTrainerContracts

/// ios/Contracts 目录（由本文件路径回推：Tests/KlineTrainerContractsTests/<本文件> → 上溯 3 层）。
var contractsDirForGuards: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// `Sources/` 下**全部 target** 的 .swift 绝对路径（codex plan-R8-F1：跨 target 调用者也要覆盖）。
func allSwiftFilesUnderSources() throws -> [String] {
    let root = contractsDirForGuards.appendingPathComponent("Sources")
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map(\.path)
}

var trainingEnginePath: String {
    contractsDirForGuards.appendingPathComponent(
        "Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift").path
}

// MARK: 空白无关的调用点扫描（codex plan-R1-F1 → R2-F1 → R3-F1 → R7-F1 → R8-F1 逐轮收紧）

/// ⚠️ **本 Task 同时把扫描根从 `Sources/KlineTrainerContracts` 放宽到整个 `Sources/`**（codex plan-R8-F1）：
///   本包有两个 target（`KlineTrainerContracts` / `KlineTrainerPersistence`，`Package.swift` 实测），
///   只扫前者的话，一个**跨 target** 的调用者根本不在扫描范围内。改法 = 把 PR-1 既有 helper
///   `allSwiftFilesUnderSources()` 的 root 从 `Sources/KlineTrainerContracts` 改成 `Sources/`。
///   **实测过不会引入假阳性**：`KlineTrainerPersistence` 当前对 `appendDrawing` / `appendReviewDrawing` /
///   `routeDrawingCommit` / `deleteDrawing` / `updateDrawingStyle` 五个标识符**一次都没提**
///   （`grep -rln <id> Sources/ | grep -v KlineTrainerContracts/` 全空）→ 各 pattern 计数不变。
///   实施时先跑一遍既有 `appendFamilyTrustBoundary` 确认仍绿，再往下写新守卫。

/// 删掉**全部**空白字符（用于 needle 与源码两侧，使匹配彻底与排版无关）。
func squeeze(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace }).joined()
}

/// 一段源码文本 → **只剩代码**（剥行注释 / 嵌套块注释 / 字符串字面量内容）**且删光空白**。
/// ⚠️ 三次收紧的由来，别退回去（每一条都是 codex 用一段**合法 Swift** 打穿的）：
///   ① 逐行 substring 挡不住 `engine.deleteDrawing(\n id: x\n)`（R1-F1）；
///   ② 只折叠空白、只收紧 `"( "` 仍不够（R2-F1）：`engine.deleteDrawing\n(\n id: x\n)` 会留下
///      `deleteDrawing (id:`（左括号**前面**那个空格没人管）；`deleteDrawing/* c */(id:` 同理；
///   ③ **不跟踪字符串状态就会反向漏**（R7-F1）：`let u = "https://x"` 里的 `//` 会让「吃到行尾」
///      把**同一行后面的真实调用**当注释丢掉；`let s = "/*"` 更狠——块注释状态一开，能吞掉整片代码。
///      故这里是个**小词法器**：正确处理普通串 / 多行串 `"""` / 原始串 `#"…"#`（含 `\#` 转义），
///      并把字符串**内容整段丢弃**（字面量里的 `deleteDrawing(id:` 本来就不是调用，顺带免了假阳性）。
///   守卫漏掉一个调用点的后果不是"少测一条"，而是 PR-4 可以在**不补几何门**的情况下接上不可逆删除。
///   ④ **顶层与插值体各写一份循环 = 两档判据**（R10-F1）：插值那份不认注释 →
///      `"\(/* ) */ engine.deleteDrawing(id: id))"` 里**注释中的** `)` 被当成插值收尾，真调用反被
///      当字面文本丢掉。根因不是"再补一个 case"，是**同一件事有两份能力不同的实现**（本计划一路在
///      批评的同一个毛病）→ 现在**只有 `scanCode` 一个循环**，顶层与插值体走完全相同的注释/字符串
///      规则，唯一差别是"遇 `)` 是否收尾"。
func squeezedText(_ raw: String) -> String {
    var out = ""
    _ = scanCode(Array(raw), from: 0, parenDepth: nil, into: &out)
    return out
}

/// **唯一**的词法扫描循环。`parenDepth == nil` = 顶层（`)` 不收尾）；非 nil = 插值体（深度归零即返回，
/// 那个收尾 `)` 不写进 out）。注释 / 字符串 / 原始串 / 嵌套插值在两种模式下**判据完全一致**。
func scanCode(_ c: [Character], from start: Int, parenDepth: Int?, into out: inout String) -> Int {
    var i = start
    var depth = parenDepth ?? 0
    while i < c.count {
        if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" {       // 块注释（可嵌套）
            var d = 1; i += 2
            while i < c.count, d > 0 {
                if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" { d += 1; i += 2; continue }
                if c[i] == "*", i + 1 < c.count, c[i + 1] == "/" { d -= 1; i += 2; continue }
                i += 1
            }
            continue
        }
        if c[i] == "/", i + 1 < c.count, c[i + 1] == "/" {       // 行注释：吃到行尾
            while i < c.count, c[i] != "\n" { i += 1 }
            continue
        }
        if c[i] == "#" {                                         // 可能是原始串 #"…"# / ##"…"##
            var h = 0, j = i
            while j < c.count, c[j] == "#" { h += 1; j += 1 }
            if j < c.count, c[j] == "\"" { i = consumeStringLiteral(c, from: j, hashes: h, into: &out); continue }
            out.append(contentsOf: c[i..<j])                      // 不是原始串（如 #expect / #filePath）
            i = j; continue
        }
        if c[i] == "\"" { i = consumeStringLiteral(c, from: i, hashes: 0, into: &out); continue }
        if parenDepth != nil {                                   // 只有插值体在意括号深度
            if c[i] == "(" { depth += 1 }
            if c[i] == ")" {
                depth -= 1
                if depth == 0 { return i + 1 }                    // 插值收尾：这个 `)` 不写进 out
            }
        }
        if !c[i].isWhitespace { out.append(c[i]) }                // 空白一律丢弃
        i += 1
    }
    return c.count
}

/// 消费一个字符串字面量（`from` 指向首个 `"`），返回其后第一个下标。
/// **字面文本丢弃，但插值 `\(…)` 里的表达式当代码保留**（codex plan-R9-F1）——
/// ⚠️ 这条是我 R7 那次修复**自己引入**的失败面：为了不让串里的 `//` 吞代码，我把串内容整段丢了，
///   于是 `logger.debug("deleted \(engine.deleteDrawing(id: id))")` 这种**真的会执行**的调用
///   反而从守卫底下溜走。字面量里既有"不是代码的文本"也有"确实是代码的插值"，必须分开处理。
/// 支持多行 `"""…"""` 与原始串（`hashes` 个 `#`，其转义/插值前缀是 `\` + 同样数量的 `#`）。
func consumeStringLiteral(_ c: [Character], from: Int, hashes: Int, into out: inout String) -> Int {
    var i = from
    let isMultiline = (i + 2 < c.count) && c[i + 1] == "\"" && c[i + 2] == "\""
    let quoteLen = isMultiline ? 3 : 1
    i += quoteLen
    while i < c.count {
        if c[i] == "\\" {                                        // `\…` ：插值前缀或普通转义
            var j = i + 1, h = 0
            while j < c.count, c[j] == "#", h < hashes { h += 1; j += 1 }
            if h == hashes {
                if j < c.count, c[j] == "(" {                    // 插值 → 递归当**代码**扫
                    i = scanCode(c, from: j + 1, parenDepth: 1, into: &out); continue  // `(` 之后起扫
                }
                i = min(j + 1, c.count); continue                // 普通转义：连吃被转义的那个字符
            }
        }
        if c[i] == "\"" {                                        // 收尾：quoteLen 个 `"` + hashes 个 `#`
            var j = i, q = 0
            while j < c.count, c[j] == "\"", q < quoteLen { q += 1; j += 1 }
            if q == quoteLen {
                var h = 0
                while j < c.count, c[j] == "#", h < hashes { h += 1; j += 1 }
                if h == hashes { return j }
            }
        }
        i += 1                                                   // 字面文本：丢弃
    }
    return c.count                                               // 未闭合（坏源码）：吃到底，fail-safe
}

func squeezedSource(_ path: String) throws -> String {
    squeezedText(try String(contentsOfFile: path, encoding: .utf8))
}

/// 一段源码里 `pattern` 的**调用**次数 = 总出现数 − **定义**出现数。
/// ⚠️ 定义只按 `"func" + pattern` 扣，**绝不可**另传一个「更宽的 defPattern」（codex plan-R3-F1 实证的真 bug）：
///   `func deleteDrawing(at index: Int)` squeeze 后是 `funcdeleteDrawing(atindex:` ——
///   它**不含**调用 pattern `deleteDrawing(at:`（`at index:` ≠ `at:`），却会命中宽 defPattern
///   `funcdeleteDrawing(at` → 一次**真实的** `deleteDrawing(at: 0)` 调用被扣成 `1-1=0`，
///   守卫恒绿，正好放过它要挡的那条绕过 id 唯一/locked/几何三门的破坏性入口。
///   现在的形状里「扣掉的」必然也是「数进来的」，不可能扣多。
func callCount(inSqueezed s: String, pattern: String) -> Int {
    let p = squeeze(pattern)
    let total = s.components(separatedBy: p).count - 1
    let defs  = s.components(separatedBy: "func" + p).count - 1
    return total - defs
}

/// `Sources/` 里 `pattern` 的调用点（按文件），零调用的文件不出现。
func callSiteCount(_ pattern: String) throws -> [(file: String, count: Int)] {
    try allSwiftFilesUnderSources().compactMap { path in
        let n = callCount(inSqueezed: try squeezedSource(path), pattern: pattern)
        return n > 0 ? (path, n) : nil
    }
}

/// 某文件（squeeze 后）是否含某段文本——访问级别断言用，同样与排版无关。
func squeezedContains(_ path: String, _ needle: String) throws -> Bool {
    try squeezedSource(path).contains(squeeze(needle))
}

/// 断言某声明**存在**且**不是包外可见的**（`public` / `package` / `open` 一个都不行）。
/// ⚠️ 只查 `public` 不够（codex plan-R8-F1，已对 `Package.swift` 实测）：本包
///   `swift-tools-version: 6.0` → **`package` 访问级别可用**，`package func updateDrawingStyle`
///   能让**另一个 target**（`KlineTrainerPersistence`）直接调这两个写入面，而几何门只存在于
///   `KlineTrainerContracts` 里那条 UI 路由上 → 信任边界被绕开而守卫仍绿。
func expectEngineInternalOnly(_ decl: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(try squeezedContains(trainingEnginePath, "func " + decl),
            "\(decl) 不见了？（先证明真读到文件，防负向断言假绿）", sourceLocation: sourceLocation)
    for mod in ["public func ", "package func ", "open func "] {
        #expect(try !squeezedContains(trainingEnginePath, mod + decl),
                "\(decl) 不得是 \(mod)——包外/跨 target 可达即绕过几何门", sourceLocation: sourceLocation)
    }
}

/// `Sources/` 里**提到过**该标识符的文件（剥注释后按裸标识符找，不看后面跟不跟左括号）。
/// ⚠️ 为什么必须按「标识符」而不是「调用 pattern」（codex plan-R5-F1）：
///   `let f = engine.updateDrawingStyle` / `let g: (DrawingID, DrawingDefaultStyle) -> Bool = engine.updateDrawingStyle`
///   这类**方法引用**把调用挪到了别处，源码里根本不出现 `updateDrawingStyle(` —— 只数调用 pattern 的守卫
///   会放它过去，而这两个 API 的几何门**只**靠「唯一调用点在已验几何的 UI 路由」这条源码守卫成立。
///   按标识符扫，方法引用也必然让标识符出现在那个文件里 → 照样被抓。
func filesMentioning(_ identifier: String) throws -> [String] {
    try allSwiftFilesUnderSources().filter { try squeezedSource($0).contains(identifier) }
}

```

> ⚠️ PR-1 的 `TrainingEngineDrawingSessionTests` 里已有 `contractsDir` / `allSwiftFilesUnderSources()` / `trainingEnginePath`（`:22-47`）。搬进共享文件后**删掉那三个 suite 私有版本**（同 module 顶层同名函数会与私有方法共存但语义重复，属"两档判据"的温床）；`appendFamilyTrustBoundary` 改调顶层函数（Task 5 那步会一并处理）。

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScannerTests.swift`（自检 = 这套守卫**唯一**的判别力证明）：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScannerTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("源码守卫扫描器自检（a–f）")
struct SourceGuardScannerTests {
    @Test("守卫自检 a（codex plan-R1-F1 + R2-F1）：换行/括号前空白/块注释三种排版都逃不掉，注释里的不算")
    func scannerCatchesAwkwardFormatting() {
        let src = """
        func caller() {
            engine.deleteDrawing(
                id: a
            )
            engine.deleteDrawing
                (
                    id: b
                )
            engine.deleteDrawing/* 块注释 */(id: c)
            // engine.deleteDrawing(id: 行注释里的不算)
            /* engine.deleteDrawing(id: 块注释里的也不算) */
        }
        """
        let s = squeezedText(src)
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 3, "三种排版都该命中，实际 squeeze：\(s)")
        #expect(!s.contains("行注释里的不算"))
        #expect(!s.contains("块注释里的也不算"))
    }

    @Test("守卫自检 f（codex plan-R10-F1）：插值体里的注释按注释处理——注释中的 `)` 不算插值收尾")
    func scannerHandlesCommentsInsideInterpolation() {
        let src = ##"""
        func caller() {
            logger.debug("x \(/* ) */ engine.deleteDrawing(id: id))")
            let m = """
            y \(// ) 行注释里的右括号
            engine.updateDrawingStyle(id: i, style: st))
            """
        }
        """##
        let s = squeezedText(src)
        // 注释里的 `)` 若被当成插值收尾，真调用就会被当字面文本丢掉 → 计数变 0，本测试当场红
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 1, "实际 squeeze：\(s)")
    }

    @Test("守卫自检 e（codex plan-R9-F1）：插值 \\(…) 里的调用与方法引用**照样算数**（它们真的会执行）")
    func scannerCountsCallsInsideStringInterpolation() {
        // ⚠️ 外层用 `##"""`：本 fixture 内部要出现 `\(` **和** `\#(` 两种插值前缀的**字面文本**，
        //    若外层只用 `#"""`，`\#(…)` 会被 Swift 当成**本测试文件自己的**插值 → 编译错误。
        let src = ##"""
        func caller() {
            logger.debug("deleted \(engine.deleteDrawing(id: id))")
            let s = "\(engine.updateDrawingStyle(id: i, style: st))"
            let f = "\(engine.appendDrawing)"
            let plain = "deleteDrawing(id: 纯文本不算)"
            let raw = #"\#(engine.routeDrawingCommit(d))"#
        }
        """##
        let s = squeezedText(src)
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "routeDrawingCommit(") == 1, "原始串的插值前缀是 \\#(…)：\(s)")
        #expect(s.contains("appendDrawing"))          // 藏在插值里的**方法引用**，标识符扫描也看得见
        #expect(!s.contains("纯文本不算"))             // 纯文本仍不算数（不产生假阳性）
    }

    @Test("守卫自检 d（codex plan-R7-F1）：字符串里的注释定界符不得吞掉后面的真实调用；串内的调用不算数")
    func scannerHandlesStringLiteralsWithCommentDelimiters() {
        let src = #"""
        func caller() {
            let u = "https://example.com/a"; engine.deleteDrawing(id: x)
            let s = "/*"
            engine.updateDrawingStyle(id: y, style: st)
            let r = ##"deleteDrawing(id: 原始串里的不算)"##
            let m = """
            deleteDrawing(id: 多行串里的也不算)
            """
            let esc = "带转义的引号 \" 之后仍在串内：deleteDrawing(id: 不算)"
        }
        """#
        let s = squeezedText(src)
        // `"https://…"` 里的 `//` 没把同一行后面的真实调用吃掉；`"/*"` 没开启块注释吞掉下一行
        #expect(callCount(inSqueezed: s, pattern: "deleteDrawing(id:") == 1, "实际 squeeze：\(s)")
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 1, "实际 squeeze：\(s)")
        // 字符串内容整段丢弃 → 串里的调用字样不产生假阳性
        #expect(!s.contains("原始串里的不算"))
        #expect(!s.contains("多行串里的也不算"))
        #expect(!s.contains("不算"))
    }

    @Test("守卫自检 c（codex plan-R5-F1 + R6-F1）：方法引用不出现调用 pattern，但必被标识符扫描抓到")
    func scannerCatchesMethodReferences() {
        // 这三行都是**合法 Swift**，且都让调用点计数看不见（源码里没有 `xxx(` 这个形状）。
        let src = """
        func sneaky(engine: TrainingEngine) {
            let f = engine.appendDrawing
            let g: (DrawingID, DrawingDefaultStyle) -> Bool = engine.updateDrawingStyle
            let h = engine.routeDrawingCommit
            later(f, g, h)
        }
        """
        let s = squeezedText(src)
        // 调用点计数：全 0（这正是 R5/R6 指出的绕过）
        #expect(callCount(inSqueezed: s, pattern: "appendDrawing(") == 0)
        #expect(callCount(inSqueezed: s, pattern: "updateDrawingStyle(") == 0)
        #expect(callCount(inSqueezed: s, pattern: "routeDrawingCommit(") == 0)
        // 标识符扫描：三个都看得见 → `filesMentioning` 的白名单断言会把这种文件抓出来
        #expect(s.contains("appendDrawing"))
        #expect(s.contains("updateDrawingStyle"))
        #expect(s.contains("routeDrawingCommit"))
    }

    @Test("守卫自检 b（codex plan-R3-F1）：first-argument-label 的定义不得把真实调用扣成 0")
    func scannerCountsFirstArgumentLabelCallsExactly() {
        // `func deleteDrawing(at index: Int)` 与调用 `deleteDrawing(at: 0)` 形状不同：
        // 前者 squeeze 后是 `funcdeleteDrawing(atindex:`，**不含**调用 pattern。
        // 用「更宽的 defPattern」去扣就会把这次真实调用抹成 0（守卫恒绿 = 破坏性入口放行）。
        let src = """
        func deleteDrawing(at index: Int) {}
        func caller() { engine.deleteDrawing(at: 0) }
        """
        #expect(callCount(inSqueezed: squeezedText(src), pattern: "deleteDrawing(at:") == 1)
        // 对照：同名 id 版本的定义**确实**含调用 pattern（`func deleteDrawing(id: DrawingID)`）→ 必须被扣掉
        let src2 = """
        func deleteDrawing(id: DrawingID) -> Bool { true }
        """
        #expect(callCount(inSqueezed: squeezedText(src2), pattern: "deleteDrawing(id:") == 0)
        // 再对照：定义 + 一次真实调用 → 恰好 1
        let src3 = """
        func deleteDrawing(id: DrawingID) -> Bool { true }
        func caller() { _ = engine.deleteDrawing(id: "x") }
        """
        #expect(callCount(inSqueezed: squeezedText(src3), pattern: "deleteDrawing(id:") == 1)
    }
}
```

- [ ] **Step 5: 加 N5 源码守卫（四条语义单点）——本 Task 才加（codex plan-R1-F2）**

把 Task 1 Step 1 末尾那段 `fourSemanticsSingleSource`（连同 `hits(_:excluding:)` 局部 helper）**原样**追加进 `Drawing/DrawingObjectStyleEditTests.swift` 的 suite 里。

> **为什么必须等到这个 Task**：Task 1 结束时 `DrawingSession.commitPending` 里仍有第二份 `isExtended: s.lineSubType == .ray`（本 Task Step 3 才消灭它）→ 守卫在 Task 1 结束时**必红**，会逼实现者要么跳过「每 task 全绿再 commit」，要么手工放宽守卫（两者都是坏结果）。守卫跟着「最后一份重复语义被消灭」的 Task 落地，红→绿的因果才对得上。
>
> **先跑一次证明它有判别力**：本 Task Step 3 改完 `commitPending` **之前**先把守卫加进去跑一次 → 期望 `派生① 不止一处` FAIL（`DrawingSession.swift` 那份还在）；改完 Step 3 后再跑 → PASS。这就是这条守卫的红绿验。

- [ ] **Step 6: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter "DrawingSessionSourceGuard|TrainingEngineDrawingCommit|DrawingObjectStyleEditTests" 2>&1 | tail -20`
Expected: 全部 PASS。

- [ ] **Step 7: 全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿（累计计数 = 基线 + Task1/2 新增）。

- [ ] **Step 8: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScannerTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionSourceGuardTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingObjectStyleEditTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift
git commit -m "划线 1b-i 切片2 Task2：commitPending 接 withStyle + 共享源码守卫扫描器 + N5 四条语义单点守卫（D59）"
# ⚠️ 每个 Task commit 后都跑一次净检查（codex plan-R14-F3：新建文件未 add → 本地绿而分支/CI 缺文件）
git status --porcelain   # 期望：空输出
```

---

### Task 3: `updateDrawingStyle(id:style:)` —— internal 写入面 + id 唯一门 + withStyle 门 + revision（D50/D58 引擎支/D62/D66）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（在 `deleteDrawing(at:)`/`appendDrawing` 邻近新增方法）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（同文件追加；**直接调用 Task 2 建好的共享扫描器顶层函数**，不再声明任何本地扫描逻辑）

**Interfaces:**
- Consumes: Task 1 的 `DrawingObject.withStyle(_:)`；既有 `drawingsRevision`（PR-1）。
- Produces: `TrainingEngine.updateDrawingStyle(id: DrawingID, style: DrawingDefaultStyle) -> Bool`（**internal**、`@discardableResult`）。成功 → 原地替换 + `drawingsRevision += 1` + `true`；任一门不过 → 零改动 + 不递增 + `false`。

- [ ] **Step 1: 写失败测试**

追加到 `TrainingEngineDrawingSessionTests.swift`（文件已有 `allSwiftFilesUnderSources()` / `trainingEnginePath`；`callSites` 是 PR-1 `appendFamilyTrustBoundary` 内的局部函数，**不动它**，本 Task 另加跨行安全的扫描器）：

```swift
    // MARK: 切片2 Task 3（D50/D58 引擎支/D62/D66）：updateDrawingStyle

    private func styleFixture(_ sub: LineSubType = .straight, _ ls: LineStyle = .solid, _ th: Int = 1,
                              _ c: DrawingColorToken = .orange, _ lm: LabelMode = .hidden) -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = sub; s.lineStyle = ls; s.thickness = th; s.colorToken = c; s.labelMode = lm
        return s
    }

    @Test("N2: updateDrawingStyle 只动 5 样式字段 + 两个派生，其余逐字段不变；revision +1")
    @MainActor func updateTouchesOnlyStyleFields() throws {
        let e = TrainingEngine.preview()
        let old = makeStyledHLine(id: "A", thickness: 1, text: "note", fontSize: 21)
        #expect(e.appendDrawing(old) == true)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 4, .green, .right)) == true)
        let now = try #require(e.drawings.first { $0.id == "A" })
        #expect(e.drawingsRevision == rev + 1)
        // 变的
        #expect(now.lineStyle == .dash1); #expect(now.thickness == 4)
        #expect(now.colorToken == .green); #expect(now.labelMode == .right)
        // 不变的（逐字段）
        #expect(now.id == old.id); #expect(now.anchors == old.anchors); #expect(now.period == old.period)
        #expect(now.panelPosition == old.panelPosition); #expect(now.revealTick == old.revealTick)
        #expect(now.locked == old.locked); #expect(now.text == old.text); #expect(now.fontSize == old.fontSize)
        #expect(now.textForm == old.textForm); #expect(now.tailAnchor == old.tailAnchor)
    }

    @Test("N3: updateDrawingStyle 对不存在 id → false、drawings 逐字段不变、revision 不递增")
    @MainActor func updateUnknownIdIsNoop() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "ZZZ", style: styleFixture(.straight, .dash1, 4)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N12a: 引擎层恒开门——水平线改 .segment 被拒，该线逐字段不变、revision 不递增")
    @MainActor func updateRejectsUnrenderableSubType() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", lineSubType: .straight)) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.segment)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N5 行为 + N12d: 直调（绕开面板）传未归一化的 (ray,.left) → 结果 .hidden、isExtended 派生成立")
    @MainActor func updateNormalizesAndDerivesAtWriteBoundary() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", lineSubType: .straight, labelMode: .left)) == true)
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.ray, .solid, 1, .orange, .left)) == true)
        let now = try #require(e.drawings.first { $0.id == "A" })
        #expect(now.labelMode == .hidden)                    // (ray,.left) 不可表达
        #expect(now.isExtended == true)                      // 派生①
        // 改回 .straight → isExtended 回 false
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight)) == true)
        #expect(e.drawings.first { $0.id == "A" }?.isExtended == false)
    }

    @Test("N21c(update): id 匹配 ≥2 条 → fail，不改任何一条、revision 不递增（D66，绝不打第一条）")
    @MainActor func updateFailsOnAmbiguousId() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        // 绕过 append 的唯一性门，直接注入第二条同 id（模拟坏状态）
        e.injectDrawingsForTesting(e.drawings + [makeStyledHLine(id: "A", thickness: 2, candleIndex: 4)])
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 5)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("D66: 空 id 恒 fail（写入边界不变量：id 非空）")
    @MainActor func updateRejectsEmptyId() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "", style: styleFixture(.straight, .dash1)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("SD-7/D34 纵深防御: 复盘模式下 updateDrawingStyle 恒 fail（drawings = 已归档 record 的原训练线）")
    @MainActor func updateRefusedInReviewMode() throws {
        let e = TrainingEngine.preview(mode: .review)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)   // 造出「归档线」状态
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 5)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        // 反向对照：同样的调用在 normal 模式成功（防「一律拒绝」）
        let n = TrainingEngine.preview(mode: .normal)
        #expect(n.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        #expect(n.updateDrawingStyle(id: "A", style: styleFixture(.straight, .dash1, 5)) == true)
    }

    // MARK: 源码守卫扫描器 —— **Task 2 已建**（`Tests/.../SourceGuardScanner.swift` 的顶层函数），本文件直接调用：
    //   `squeeze` / `squeezedText` / `scanCode` / `consumeStringLiteral` / `squeezedSource` /
    //   `callCount(inSqueezed:pattern:)` / `callSiteCount(_:)` / `squeezedContains(_:_:)` /
    //   `filesMentioning(_:)` / `expectEngineInternalOnly(_:)`（同 test module 顶层函数，无需再声明）。
    //   ⚠️ **不得**在本文件另写一份扫描逻辑——同族判据留两档正是本计划一路在修的毛病。

    @Test("N15: updateDrawingStyle 非 public + Sources/ 中零调用点（切片2 语义；PR-4 接线时改成恰好 1 处）")
    func updateDrawingStyleTrustBoundary() throws {
        try expectEngineInternalOnly("updateDrawingStyle(id:")   // 存在 + 非 public/package/open（D62）
        // ⚠️ 本切片是引擎写入面，UI 编辑路由属 PR-4 → 现在**零调用点**。
        //    PR-4 接线时必须把本断言改成：恰好 1 处、且该文件是 UI 编辑路由、且路由在调用前先验
        //    HorizontalLineTool.visibleGeometry（D58 候选预检 + D65 当前门）。谁不补几何门就加调用点，
        //    这条当场红——这就是本守卫存在的意义（fail-closed forcing function）。
        let sites = try callSiteCount("updateDrawingStyle(")
        #expect(sites.isEmpty, "updateDrawingStyle 出现了非预期调用点：\(sites)")
        // **更强的一层（codex plan-R5-F1）**：连**方法引用**（`let f = engine.updateDrawingStyle`）都要挡——
        // 那种写法源码里不出现 `updateDrawingStyle(`，只数调用 pattern 会放过它，而几何门**只**靠
        // 「唯一调用点在已验几何的 UI 路由」这条守卫成立。故按**标识符的文件作用域**钉：
        // 本切片只许出现在引擎自身文件；PR-4 接线时把路由文件加进白名单（**只加那一个**）。
        let mentions = try filesMentioning("updateDrawingStyle")
        #expect(mentions.allSatisfy { $0.contains("TrainingEngine.swift") },
                "updateDrawingStyle 被引擎以外的文件提到（含方法引用）：\(mentions)")
    }

```

> **PR-1 的 `callSites` 局部函数（逐行 substring）在 Task 5 被整条替换掉**（codex plan-R2-F1 明确要求同一扫描器覆盖 append/route 守卫）。我一度argue「函数名+左括号的 pattern 不受跨行影响」——但 `engine.appendDrawing\n(x)` 在 Swift 里同样合法，而**判据强弱不一致本身就是缺陷**（同族信任边界守卫留一档弱的，读者会以为该性质已被钉死）。本 Task 只新增扫描器，Task 5 统一切换。

- [ ] **Step 2: 加测试专用注入口（DEBUG hook）并跑红**

`updateFailsOnAmbiguousId` 需要一个「两条同 id」的坏状态，而所有生产入口都拒它（D66）——这正是 spec N21c 说的「绕过 append 门，直接注入 `drawings`」。沿用 PR-1 已建立的 `xxxForTesting` DEBUG hook 范式，在 `TrainingEngine.swift` 加：

```swift
#if DEBUG
    /// 仅测试：直接置换 `drawings`，绕过全部写入门。用于构造生产入口**造不出**的坏状态
    /// （N21c：两条同 id → update/delete 必须 fail 而不是"打第一条"）。
    /// 不动 `drawingsRevision`（它只由真实写入面递增；测试自己记录基线）。
    func injectDrawingsForTesting(_ ds: [DrawingObject]) { drawings = ds }
#endif
```

Run: `cd ios/Contracts && swift test --filter "updateTouchesOnlyStyleFields|updateUnknownIdIsNoop|updateRejectsUnrenderableSubType" 2>&1 | tail -20`
Expected: 编译失败 `value of type 'TrainingEngine' has no member 'updateDrawingStyle'`。

- [ ] **Step 3: 实现 `updateDrawingStyle`**

在 `TrainingEngine.swift` 的 `appendDrawing` 之后（`:1101` 附近）插入：

```swift
    /// D50（1b-i）：**唯一**的画线样式编辑写入面。原地替换单个数组元素——流程里**没有"删"那一步**，
    /// 故 1a-iv 交接①「编辑路径 append 返 false 时绝不能已删原线」在本形状下不可表达（矛盾状态被消灭，
    /// 而不是靠调用者按正确顺序操作）。
    /// **访问级别 internal（D62）**：几何门（`visibleGeometry`）只能在持 mapper 的 UI 层，引擎判不了；
    /// 若本 API public，包外就能绕过那道门落一条渲染不出的线并被 autosave。唯一合法调用者 = 包内那条
    /// 已先验几何的 UI 编辑路由（PR-4）；源码守卫 N15 钉死调用点数量。
    /// **五道 viewport 无关的门，任意一道不过 → 零改动 + `drawingsRevision` 不递增 + 返 `false`**：
    ///   ⓪ 非复盘模式（D34 纵深防御，SD-7）：复盘里 `drawings` 就是已归档 record 的原训练线，
    ///      改它不可逆；复盘新画线走 `reviewDrawings`，本期复盘不获得编辑能力 → 这道门不 over-reject
    ///   ① id 非空且**恰好**匹配一条（D66；≥2 条是坏状态，绝不"改第一条碰到的"）
    ///   ② 目标 `locked == false`（D60；本构建产不出 locked=true，只挡高版本解码来的）
    ///   ③ **改完之后**不再带本构建不支持的未来数据（D61 修订版，user 2026-07-26 裁决）：
    ///      构造候选 → `loadedDrawingsLossy.reconciled(currentKnown:)` → 对该 id 查
    ///      `hasKnownFutureEnumValues` + `hasKnownFutureFields`（后者是 codex plan-R13-F1 补的：
    ///      未来**字段**能改变已知 key 的含义）。前者已含 `!entries.isEmpty`——**绝不可**写成
    ///      `knownFutureEnumPayloads()` 的 id-membership（会误灰所有已加载线）。归并抛错 = 坏数据 → 拒。
    ///      ⚠️ **这是对 spec D61 原文的显式修订**：原文是"携带未来枚举值 → 一律拒改样式"，
    ///      落地为"看**改完的结果**"。理由（user 裁决）：一律拒会让这条线只能**整条删掉**才能结束存档，
    ///      而删整条的损失严格大于"用户显式换掉一个本版本表示不了的色号"。得失见 §已知后果。
    ///   ④ `withStyle` 语义成立（D59：派生①②/归一化/可用性单点；水平线 `.segment` 恒不可渲染 → 拒）
    @discardableResult
    func updateDrawingStyle(id: DrawingID, style: DrawingDefaultStyle) -> Bool {
        guard flow.mode != .review else { return false }                           // ⓪（D34 纵深防御）
        guard !id.isEmpty else { return false }                                   // ①（D66 非空）
        let matches = drawings.indices.filter { drawings[$0].id == id }
        guard matches.count == 1, let i = matches.first else { return false }      // ①（D66 唯一）
        let old = drawings[i]
        guard !old.locked else { return false }                                    // ②（D60）
        // ②b 工具门（D61 同族，codex plan-R11-F1；位置由 R15-F2 从 withStyle 挪来）：本构建没写出样式
        //     矩阵的工具，我们不懂它的样式语义 → **只挡编辑，不挡新建/提交**。`.trend`/`.text` 是**已知**
        //     枚举 case，高版本写的这类线解码后一切"正常"、raw-aware 门看不见 → 没这道门就会被按横线假设改写。
        guard DrawingStyleAvailability.isEditableToolType(old.toolType) else { return false }
        guard let updated = old.withStyle(style) else { return false }             // ④（D59/D58 引擎支）
        // ③（D61，**user 2026-07-26 裁决改为"看结果"**——对 spec 原文的显式修订，见下方 ⚠️）**两道**：
        //
        // ③a **可覆盖性预检**（raw-aware，按 key 判；codex plan-R19-F2）：该线携带的未来枚举值，其 key 必须
        //     全部落在「**用户能显式改到**的样式 key」内；否则**一律拒**。
        //     ⚠️ 集合里**没有 `textColorToken`**：本构建**没有字色控件**（独立字色属 P3），它只会被 D59 派生②
        //       **隐式**改写 —— 用户只改线色，一条高版本的未来字色就被顺手抹掉、而且改完"看结果"的门已经
        //       查不到它了（第二道网也拦不住）。用户没碰过、也看不见的字段，不算"用户显式覆盖"。
        //     ⚠️ `anchors[].period` / `tailAnchor.period` 同理不在集合内（样式根本不碰锚点）。
        //     ⚠️ 未来**顶层字段**没有任何控件能覆盖 → 直接拒。
        let futureEntries = loadedDrawingsLossy.knownFutureEnumPayloads().first { $0.id == id }?.entries ?? []
        guard futureEntries.allSatisfy({ DrawingStyleAvailability.userCoverableFutureKeys.contains($0.key) }),
              !loadedDrawingsLossy.hasKnownFutureFields(liveIds: [id]) else { return false }
        //
        // ③b **结果检**（第二道网）：即便未来值落在用户改得到的 key 上，这**一次**改动也未必真覆盖到它
        //     （例：未来值在 `lineStyle`，用户只改 thickness → 字段级归并保住原 raw）→ 归并后仍带就拒。
        //     判据与 coordinator 的 finalize 门**同源**（`TrainingSessionCoordinator:729-736` 也是先 reconcile
        //     再查这两个），但**作用域不同**（codex plan-R17-F2）：这里只查**被改的那条 id**，finalize 查
        //     **全部存活线 + unknownRaw** → "编辑通过"只说明**这条线**不再阻塞，**不代表整局能存档**。
        var candidate = drawings
        candidate[i] = updated
        guard let merged = try? loadedDrawingsLossy.reconciled(currentKnown: candidate) else { return false }
        guard !merged.hasKnownFutureEnumValues(liveIds: [id]),
              !merged.hasKnownFutureFields(liveIds: [id]) else { return false }
        drawings[i] = updated
        drawingsRevision += 1
        return true
    }
```

> ⚠️ 门 ② ③ 的行为测试在 Task 4；本 Task 一次写全实现（三行 guard 不值得拆成两次改同一函数），Task 4 负责把它们**逐条钉死**（含反向对照，防「一律拒绝」骗过测试）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd ios/Contracts && swift test --filter "updateTouchesOnlyStyleFields|updateUnknownIdIsNoop|updateRejectsUnrenderableSubType|updateNormalizesAndDerivesAtWriteBoundary|updateFailsOnAmbiguousId|updateRejectsEmptyId|updateRefusedInReviewMode|updateDrawingStyleTrustBoundary" 2>&1 | tail -20`
Expected: 8 tests PASS。

再做一次 mutation 验证（证明复盘门有判别力）：临时注释掉 `guard flow.mode != .review` 那行 → 跑 `swift test --filter updateRefusedInReviewMode` → 期望 FAIL → 恢复。

- [ ] **Step 5: 全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿。

- [ ] **Step 6: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
git commit -m "划线 1b-i 切片2 Task3：updateDrawingStyle internal 写入面 + id 唯一门 + withStyle 门（D50/D62/D66）"
git status --porcelain   # 期望：空输出（codex plan-R14-F3：防新建文件漏 add）
```

---

### Task 4: `updateDrawingStyle` 的两道耐久性门钉死：`locked`（D60）+ 未来未知枚举值（D61）

**Files:**
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift`（新建）
- （三个 fixture helper 已在 Task 1 Step 3 ④ 加进 `DrawingTestFixtures.swift`，本 Task 直接用）

**Interfaces:**
- Consumes: Task 3 的 `updateDrawingStyle`；既有 `LossyDrawingArray.decode` / `hasKnownFutureEnumValues(liveIds:)` / `reconciled(currentKnown:)` / `encoded()`。
- Produces: 无新生产代码（本 Task 只钉行为）；若某条测试红，说明 Task 3 的门写错了，就地修 Task 3 的实现。

- [ ] **Step 1: 写失败测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift
// Spec: 2026-07-23-...-1b-i-select-edit-delete-design.md D60（locked）/ D61（未来未知枚举值）。
// 两道门都是**跨版本耐久性**保护：本构建产不出 locked=true、也产不出未来枚举值，
// 它们只可能从**高版本写的磁盘数据**解码进来 —— 编辑它们会不可逆地抹掉原始字节。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1b-i 切片2：编辑写入面的耐久性门（locked / 未来未知枚举值）")
@MainActor
struct DrawingEditDurabilityGateTests {

    private func style(_ th: Int = 3, _ c: DrawingColorToken = .green) -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.thickness = th; s.colorToken = c
        return s
    }

    /// 一条**携带两个不同未来枚举值**的高版本线：colorToken/textColorToken 双双 fallback 成 .orange，
    /// 故「解码后 == 比较」区分不了它们 —— 这正是 D61 必须 raw-aware 的理由（codex R7-F2）。
    private let futureRaw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"futureCyan","textForm":"plain"}"#

    /// 一条**当前版本普通线**（所有枚举字段都是已知值 → knownFutureEnumPayloads 该条 entries 为空）。
    private let plainRaw = #"{"id":"K","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#

    // MARK: D60 locked

    @Test("N13a: locked 线改样式被拒 —— 逐字段不变、revision 不递增")
    func lockedRejectsStyleEdit() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "L", thickness: 1, locked: true)) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "L", style: style()) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N13c 反向对照: 同一条线 locked == false 时改样式成功、revision +1（防「一律拒绝」骗过 N13a）")
    func unlockedAcceptsStyleEdit() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "U", thickness: 1, locked: false)) == true)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "U", style: style(4, .green)) == true)
        #expect(e.drawings.first { $0.id == "U" }?.thickness == 4)
        #expect(e.drawingsRevision == rev + 1)
    }

    // MARK: D61 未来未知枚举值

    @Test("N14a（D61 修订版）: 改**不涉及那个未来值**的字段（thickness）→ 仍 fail-closed，因为改完未来值还在")
    func futureEnumLineRejectsUnrelatedStyleEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(futureRaw))
        #expect(e.drawings.count == 1)
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["F"]) == true)   // 前提成立
        let before = e.drawings
        let rev = e.drawingsRevision
        // 只改 thickness：P1a 的字段级归并（`DrawingModelP1aTests:307` 钉死）会**保住** colorToken 原始
        // 未来值 → 归并结果仍带未来数据 → 拒（这一局仍解不了封，拒掉也没损失）
        var onlyThickness = DrawingDefaultStyle(); onlyThickness.thickness = 5
        #expect(e.updateDrawingStyle(id: "F", style: onlyThickness) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N14a2（D61 修订版，user 2026-07-26 裁决 B）: 换成本版本认识的颜色 → **允许**，且这一局随即可结束存档")
    func futureEnumLineRepairableByChangingColor() throws {
        // 单个未来值 fixture（colorToken 未来、**textColorToken 正常**）：未来值落在用户改得到的 key 上
        //（`colorToken` ∈ userCoverableFutureKeys）→ 过 ③a；换色真的覆盖掉它 → 过 ③b。
        // 用户显式换色 = 覆盖掉那个色号，
        // 归并结果不再带未来数据 → 放行；线**保住**（几何/粗细/标注都在），不必整条删。
        let raw = #"{"id":"R","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":2,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"hi","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["R"]) == true)   // 修复前：带未来值
        let rev = e.drawingsRevision
        var toGreen = DrawingDefaultStyle(); toGreen.thickness = 2; toGreen.colorToken = .green
        #expect(e.updateDrawingStyle(id: "R", style: toGreen) == true)                    // 允许
        #expect(e.drawingsRevision == rev + 1)
        #expect(e.drawings.first { $0.id == "R" }?.colorToken == .green)
        #expect(e.drawings.first { $0.id == "R" }?.text == "hi")                          // 线保住了
        // 修复后：归并结果不再带未来数据 → finalize 门（同一对判据）也不会再拦这一局
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        #expect(merged.hasKnownFutureEnumValues(liveIds: ["R"]) == false)
        #expect(merged.hasKnownFutureFields(liveIds: ["R"]) == false)
        #expect(!String(decoding: try merged.encoded(), as: UTF8.self).contains("futureNeon"))
    }

    @Test("codex plan-R19-F2: 未来**字色**不算"用户可覆盖" —— 只改线色**必须被拒**，futureCyan 字节保真")
    func lineColorEditMustNotEraseFutureTextColor() throws {
        // futureRaw 里 colorToken:"futureNeon" 与 textColorToken:"futureCyan" **解码后都是 .orange**
        //（两个不同的未来值双双 fallback）→ 派生② 会判"字色本来就跟着线色"，换线色时把字色一起改掉。
        // 但**本构建没有字色控件**：用户既看不见 futureCyan、也从没碰过它 → 那是**隐式**抹除，不是
        // "用户显式覆盖"。故 ③a 可覆盖性预检必须把这条线整条拒掉（`textColorToken` 不在可覆盖集合里）。
        let e = makeEngineWithLossy(try lossyFromRaw(futureRaw))
        let before = e.drawings
        let rev = e.drawingsRevision
        var toGreen = DrawingDefaultStyle(); toGreen.thickness = 1; toGreen.colorToken = .green
        #expect(e.updateDrawingStyle(id: "F", style: toGreen) == false)   // 拒
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        let text = String(decoding: try merged.encoded(), as: UTF8.self)
        #expect(text.contains("futureNeon"))
        #expect(text.contains("futureCyan"))           // **两个都字节保真**
    }

    @Test("N14b 核心: 编辑被拒后原始字节保真 —— futureNeon / futureCyan 逐字节仍在")
    func futureEnumRawBytesSurviveRejectedEdit() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(futureRaw))
        var onlyThickness = DrawingDefaultStyle(); onlyThickness.thickness = 5   // 不碰颜色 → 必被拒
        #expect(e.updateDrawingStyle(id: "F", style: onlyThickness) == false)
        // 走真实持久化路径（coordinator 存盘用的正是 reconciled(currentKnown:).encoded()）
        let data = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("futureNeon"))       // 线色的未来值没被 fallback(.orange) 覆盖
        #expect(text.contains("futureCyan"))       // 字色的未来值同样保住（两个不同 future 值不得被抹平）
    }

    @Test("N14e 反向对照: 本构建新建的线（无 unknown 枚举）改线色成功且字色跟随")
    func currentVersionLineStillEditable() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "N", colorToken: .orange, textColorToken: .orange)) == true)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "N", style: style(2, .green)) == true)
        let now = try #require(e.drawings.first { $0.id == "N" })
        #expect(now.colorToken == .green)
        #expect(now.textColorToken == .green)                 // 派生② 条件成立 → 跟随
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("未来**顶层字段**同样 fail-closed（codex plan-R13-F1）：它能改变已知 key 的含义")
    func futureTopLevelFieldRejectsStyleEdit() throws {
        // `futureIndependentTextColor` 是本构建不认识的顶层 key：`hasKnownFutureEnumValues` 看不见它
        //（所有枚举值都是当前 case），只有 `hasKnownFutureFields` 抓得到。
        // 若不并这道门：解码出的 textColorToken == colorToken → 派生② 判"跟随"→ 覆盖字色，
        // 而那个未来字段原样留着 → 落一份自相矛盾的高版本数据。
        let raw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureIndependentTextColor":true}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["X"]) == false)  // 枚举门看不见
        #expect(e.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == true)       // 字段门抓得到
        let before = e.drawings
        let rev = e.drawingsRevision
        // ⚠️ 与未来**枚举值**不同：未来**字段**是本构建根本不认识的 key，**没有任何样式控件能覆盖它**
        //    → 归并后它必然还在 → 任何样式编辑都被拒（D61 修订版对这一类的结论与原文一致）。
        #expect(e.updateDrawingStyle(id: "X", style: style(4, .green)) == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        // 原始字节保真：未来字段仍在
        let data = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings).encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("futureIndependentTextColor"))
    }

    @Test("N14f 判据陷阱专项: 存盘→重载的**普通**线仍可编辑（漏 !entries.isEmpty 会全灰，当场红）")
    func reloadedPlainLineStillEditable() throws {
        let e = makeEngineWithLossy(try lossyFromRaw(plainRaw))
        #expect(e.drawings.count == 1)
        // 前提：该条 payload 存在但 entries 为空 → 判据必须判「不命中」
        #expect(e.loadedDrawingsLossy.knownFutureEnumPayloads().contains { $0.id == "K" })
        #expect(e.loadedDrawingsLossy.hasKnownFutureEnumValues(liveIds: ["K"]) == false)
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "K", style: style(4, .green)) == true)
        #expect(e.drawings.first { $0.id == "K" }?.thickness == 4)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("工具门端到端（codex plan-R11-F1）：未实现的已知工具线 —— 进得来、但改样式被拒")
    func unimplementedToolLineIsPreservedNotEditable() throws {
        let e = TrainingEngine.preview()
        // 一条 `.trend` 线（已知枚举、无未来枚举值 → D61 门不命中）；经 append 进来是**合法**的
        let trend = DrawingObject(id: "T", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                  isExtended: false, panelPosition: 0, period: .daily)
        #expect(e.appendDrawing(trend) == true)              // 进来宽松（PR-1 行为，不得回归）
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "T", style: style(4, .green)) == false)   // 改写保守
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        // ⚠️ 「仍可整条删」那半条在 **Task 5**（`deleteDrawing(id:)` 到那时才存在；本 Task 是纯测试
        //    Task，写在这里会编译不过 —— codex plan-R12-F1）。
    }

    @Test("N14g: known 独立字色不得被无条件派生抹掉（orange 线 + blue 标签）")
    func knownIndependentTextColorPreserved() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "I", thickness: 1,
                                                colorToken: .orange, textColorToken: .blue)) == true)
        // 只改 thickness → 字色仍 .blue
        var s = DrawingDefaultStyle(); s.thickness = 4; s.colorToken = .orange
        #expect(e.updateDrawingStyle(id: "I", style: s) == true)
        #expect(e.drawings.first { $0.id == "I" }?.textColorToken == .blue)
        // 改线色成 .green → 字色**仍** .blue（改线色也不夺 known 独立字色）
        #expect(e.updateDrawingStyle(id: "I", style: style(4, .green)) == true)
        let now = try #require(e.drawings.first { $0.id == "I" })
        #expect(now.colorToken == .green)
        #expect(now.textColorToken == .blue)
    }
}
```

- [ ] **Step 2: 运行测试确认失败（先只加测试、不改实现）**

Run: `cd ios/Contracts && swift test --filter DrawingEditDurabilityGateTests 2>&1 | tail -30`
Expected: 全部编译通过并**全部 PASS**（Task 3 已把两道 guard 写进实现）。

> ⚠️ **这是本 Task 唯一允许「首跑即绿」的情形**，因为 Task 3 一次写全了四门。为保证这些测试**真有判别力**（不是 vacuous），必须做 Step 3 的红绿验证。

- [ ] **Step 3: 红绿验证（mutation check，不可省）**

依次临时注释掉实现里的两行 guard，确认对应测试**真的红**，然后恢复：

```bash
cd ios/Contracts
# ① 注释掉 locked 门（TrainingEngine.updateDrawingStyle 里 `guard !old.locked ...` 那行）
swift test --filter "lockedRejectsStyleEdit" 2>&1 | tail -5     # 期望：FAIL
# 恢复该行；再注释掉未来枚举门
swift test --filter "futureEnumLineRejectsStyleEdit|futureEnumRawBytesSurviveRejectedEdit" 2>&1 | tail -5   # 期望：两条 FAIL
# 恢复
# ③ 把派生② 改成无条件 `textColorToken: s.colorToken`（DrawingObjectStyleEdit.swift）
swift test --filter "knownIndependentTextColorPreserved" 2>&1 | tail -5    # 期望：FAIL
# 恢复
# ④ 把 D61 判据改成 id-membership（`knownFutureEnumPayloads().contains { $0.id == id }`）
swift test --filter "reloadedPlainLineStillEditable" 2>&1 | tail -5        # 期望：FAIL（陷阱被钉死）
# 恢复
```

把四次验证的实际输出记进 commit message（形如 `红绿验：locked✔ future✔ 派生②✔ 判据陷阱✔`）。

- [ ] **Step 4: 全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿（确认恢复后无残留改动）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingEditDurabilityGateTests.swift
git commit -m "划线 1b-i 切片2 Task4：钉死编辑面两道耐久性门（locked D60 / 未来未知枚举值 D61）+ 红绿验"
git status --porcelain   # 期望：空输出（codex plan-R14-F3：防新建文件漏 add）
```

---

### Task 5: `deleteDrawing(id:)` —— internal 删除写入面 + `locked`/id 唯一门（D51/D60/D66）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`deleteDrawing(at:)` 之后新增 id 版本）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift`（追加）

**Interfaces:**
- Consumes: 既有 `drawingsRevision`；Task 3 新增的 `squeezedSource` / `callSiteCount` / `squeezedContains`（空白无关扫描器）。
- Produces: `TrainingEngine.deleteDrawing(id: DrawingID) -> Bool`（**internal**、`@discardableResult`）。成功 → 移除 + `drawingsRevision += 1` + `true`；id 不存在/非唯一/空 或 `locked` → 零改动 + 不递增 + `false`。

- [ ] **Step 1: 写失败测试**

追加到 `TrainingEngineDrawingSessionTests.swift`：

```swift
    // MARK: 切片2 Task 5（D51/D60/D66）：deleteDrawing(id:)

    @Test("删除成功: 按 id 移除 + revision +1")
    @MainActor func deleteByIdRemovesAndBumps() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "A") == true)
        #expect(e.drawings.map(\.id) == ["B"])
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("N4: deleteDrawing(id:) 对不存在 id → false、逐字段不变、revision 不递增")
    @MainActor func deleteUnknownIdIsNoop() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "ZZZ") == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.deleteDrawing(id: "") == false)            // 空 id 同样拒（D66 非空）
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N13b/N19b: 引擎层删除对 locked 线 fail-closed（降 internal 后引擎门仍在）")
    @MainActor func deleteRejectsLocked() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "L", locked: true)) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "L") == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)   // 含「仍在」+ id 未被改写
    }

    @Test("N13c 反向对照（删除侧）: 同一条线未锁定时删除成功、revision +1")
    @MainActor func deleteAcceptsUnlocked() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "U", locked: false)) == true)
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "U") == true)
        #expect(e.drawings.isEmpty)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("N21c(delete): id 匹配 ≥2 条 → fail，不删任何一条、revision 不递增")
    @MainActor func deleteFailsOnAmbiguousId() throws {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        e.injectDrawingsForTesting(e.drawings + [makeStyledHLine(id: "A", candleIndex: 4)])
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "A") == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("工具门补完（codex plan-R11-F1 + R12-F1）：未实现的已知工具线改不动样式，但**可整条删**")
    @MainActor func unimplementedToolLineIsDeletable() throws {
        let e = TrainingEngine.preview()
        let trend = DrawingObject(id: "T", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                  isExtended: false, panelPosition: 0, period: .daily)
        #expect(e.appendDrawing(trend) == true)
        var st = DrawingDefaultStyle(); st.thickness = 4
        #expect(e.updateDrawingStyle(id: "T", style: st) == false)   // 改不动（Task 4 已钉，这里做前提复述）
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "T") == true)                    // 但删得掉（同 D61 高版本线的处置）
        #expect(e.drawings.isEmpty)
        #expect(e.drawingsRevision == rev + 1)
    }

    @Test("N14c2（codex plan-R17-F1）: 未来**字段**线也必须删得掉——否则既改不动又删不掉，这一局永久锁死")
    @MainActor func futureFieldLineCanBeDeleted() throws {
        // 未来顶层字段没有任何控件能覆盖 → 它永远改不动；删除是**唯一**保底解封手段，
        // 故 `deleteDrawing(id:)` **绝不能**检查未来数据（spec D65 的门对照表已写死）。
        let raw = #"{"id":"X","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","futureIndependentTextColor":true}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        #expect(e.loadedDrawingsLossy.hasKnownFutureFields(liveIds: ["X"]) == true)
        var st = DrawingDefaultStyle(); st.thickness = 3
        #expect(e.updateDrawingStyle(id: "X", style: st) == false)      // 改不动（没有控件能覆盖那个 key）
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "X") == true)                       // 但删得掉
        #expect(e.drawings.isEmpty)
        #expect(e.drawingsRevision == rev + 1)
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        #expect(!String(decoding: try merged.encoded(), as: UTF8.self).contains("futureIndependentTextColor"))
    }

    @Test("作用域澄清（codex plan-R17-F2）: 修好一条未来线**不解封整局**——别的未来线仍拦 finalize")
    @MainActor func repairingOneLineDoesNotClearOtherBlockers() throws {
        // 两条：F 带未来枚举值（可换色修复）、G 带未来字段（改不动、只能删）
        let rawF = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"futureNeon","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
        let rawG = #"{"id":"G","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":2,"price":11.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","futureSomething":7}"#
        let lossy = try LossyDrawingArray.decode(Data("[\(rawF),\(rawG)]".utf8))
        let e = makeEngineWithLossy(lossy)
        var toGreen = DrawingDefaultStyle(); toGreen.thickness = 1; toGreen.colorToken = .green
        #expect(e.updateDrawingStyle(id: "F", style: toGreen) == true)   // F 被修好
        let merged = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings)
        #expect(merged.hasKnownFutureEnumValues(liveIds: ["F"]) == false)   // 这条线不再阻塞
        // 但整局仍被 G 拦着（finalize 门看全部存活线）——「编辑通过 ⇒ 整局可存档」是错的
        let liveIds = Set(e.drawings.map(\.id))
        #expect(merged.hasKnownFutureFields(liveIds: liveIds) == true)
    }

    @Test("N14c(引擎版): 未来枚举值线**可以删**（D61 只挡改样式，不挡整条删除）")
    @MainActor func futureEnumLineCanBeDeleted() throws {
        let raw = #"{"id":"F","toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","colorToken":"futureNeon","textColorToken":"futureCyan"}"#
        let e = makeEngineWithLossy(try lossyFromRaw(raw))
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "F") == true)
        #expect(e.drawings.isEmpty)
        #expect(e.drawingsRevision == rev + 1)
        // 删整条不产生"部分抹除"：reconcile 后该条整体消失（不残留半截 raw）
        let data = try e.loadedDrawingsLossy.reconciled(currentKnown: e.drawings).encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("futureNeon"))
    }

    @Test("SD-7/D34 纵深防御: 复盘模式下 deleteDrawing(id:) 恒 fail + normal 模式反向对照")
    @MainActor func deleteRefusedInReviewMode() throws {
        let e = TrainingEngine.preview(mode: .review)
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let before = e.drawings
        let rev = e.drawingsRevision
        #expect(e.deleteDrawing(id: "A") == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)   // 归档线仍在、id 未被改写
        let n = TrainingEngine.preview(mode: .normal)
        #expect(n.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(n.deleteDrawing(id: "A") == true)            // 反向对照
    }

    @Test("N19a: deleteDrawing(id:) 非 public + Sources/ 中零调用点（切片2 语义；PR-4 接线时改成恰好 1 处）")
    func deleteByIdTrustBoundary() throws {
        try expectEngineInternalOnly("deleteDrawing(id:")        // 存在 + 非 public/package/open（D51）
        // PR-4 接线时改成：恰好 1 处、在 UI 删除路由、且路由在**确认框点「删除」之后**重算 visibleGeometry
        // （D65 R13-F1：确认框有时间窗，线可能滑走 → 只在点 🗑 那刻判几何是时序 bug）。
        let idSites = try callSiteCount("deleteDrawing(id:")
        #expect(idSites.isEmpty, "deleteDrawing(id:) 出现了非预期调用点：\(idSites)")
        // N19d 不回归确认：index 版本仍零调用点、仍非 public（PR-1 已落）。
        let atSites = try callSiteCount("deleteDrawing(at:")
        #expect(atSites.isEmpty, "deleteDrawing(at:) 应零调用点：\(atSites)")
        try expectEngineInternalOnly("deleteDrawing(at index:")  // index 版同样不得包外可达（D51 R7 修订）
        // 标识符作用域（codex plan-R5-F1，连方法引用一起挡）：`deleteDrawing` 本切片只许出现在
        // 引擎自身文件 + `DrawingToolManager.swift`（1a-iv 交接①在案的**死代码**，spec §1.2/§8#5 明令本期不动，
        // 它有自己的同名 `deleteDrawing(at:)`，与引擎写入面无关）。PR-4 接线时**只**把删除路由文件加进白名单。
        let mentions = try filesMentioning("deleteDrawing")
        #expect(mentions.allSatisfy { $0.contains("TrainingEngine.swift") || $0.contains("DrawingToolManager.swift") },
                "deleteDrawing 被白名单以外的文件提到（含方法引用）：\(mentions)")
    }
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd ios/Contracts && swift test --filter "deleteByIdRemovesAndBumps|deleteUnknownIdIsNoop|deleteRejectsLocked" 2>&1 | tail -20`
Expected: 编译失败 `incorrect argument label in call (have 'id:', expected 'at:')` 或 `no exact matches in call to instance method 'deleteDrawing'`。

- [ ] **Step 3: 实现**

在 `TrainingEngine.swift` 的 `deleteDrawing(at:)`（`:1079-1083`）之后插入：

```swift
    /// D51（1b-i）：**id 寻址**的删除写入面。选中态存的就是 id；下标会因任何增删漂移，竞态下删错线。
    /// **访问级别 internal + 源码守卫**（与 `updateDrawingStyle` D62 完全对称）：删除比改样式**更**危险
    /// （不可逆、本期无 undo），边界只能更严。几何门（离屏线不许删）在 UI 删除路由——引擎没有 mapper，
    /// **判不了几何、也不声称挡几何**（D65 R13-F1）；路由必须在**确认框点「删除」之后**重算再调本方法。
    /// 只 enforce viewport 无关的三项，任一不过 → 零改动 + `drawingsRevision` 不递增 + 返 `false`：
    ///   ⓪ 非复盘模式（D34 纵深防御，SD-7：复盘里 `drawings` = 已归档 record 的原训练线，删它不可逆；
    ///      复盘侧删除走 `removeReviewDrawing(at:)`，本期复盘不获得删原训练线的能力 → 不 over-reject）
    ///   ① id 非空且**恰好**匹配一条（D66）
    ///   ② 目标 `locked == false`（D60）
    /// ⚠️ **不含**未来未知枚举值分量（D61）：删整条不产生"部分抹除"（raw 随之整体移除），是用户主动处置，
    ///    与"顺手抹字节"性质不同 —— 高版本线选得中、改不动、但删得掉。
    @discardableResult
    func deleteDrawing(id: DrawingID) -> Bool {
        guard flow.mode != .review else { return false }   // ⓪（D34 纵深防御，SD-7）
        guard !id.isEmpty else { return false }
        let matches = drawings.indices.filter { drawings[$0].id == id }
        guard matches.count == 1, let i = matches.first else { return false }
        guard !drawings[i].locked else { return false }
        drawings.remove(at: i)
        drawingsRevision += 1
        return true
    }
```

- [ ] **Step 4: 运行测试确认通过 + 红绿验证 locked 门**

Run: `cd ios/Contracts && swift test --filter "deleteByIdRemovesAndBumps|deleteUnknownIdIsNoop|deleteRejectsLocked|deleteAcceptsUnlocked|deleteFailsOnAmbiguousId|futureEnumLineCanBeDeleted|deleteRefusedInReviewMode|deleteByIdTrustBoundary" 2>&1 | tail -20`
Expected: 8 tests PASS。

再做两次 mutation 验证（确认门有判别力）：
- 临时注释掉 `guard !drawings[i].locked` → `swift test --filter deleteRejectsLocked` → 期望 FAIL → 恢复；
- 临时注释掉 `guard flow.mode != .review` → `swift test --filter deleteRefusedInReviewMode` → 期望 FAIL → 恢复。

- [ ] **Step 5: 把 PR-1 的 `appendFamilyTrustBoundary` **整条**换成空白无关扫描（codex plan-R1-F1 + R2-F1）**

PR-1 那条守卫用的是**逐行** substring（局部函数 `callSites`）。**同一族信任边界守卫不该有强弱两档**——留一条弱的在那里，读者会以为该性质已被钉死。把它的局部 `callSites` 删掉，全部改用 Task 3 的 `callSiteCount` / `squeezedContains`：

```swift
    @Test("N23a: append 家族非 public + 唯一调用点（源码守卫，调用图 D67，codex plan-R5-F2；切片2 换空白无关扫描）")
    func appendFamilyTrustBoundary() throws {
        // (1) 访问级别：7 个写入面全非 public（编辑 5 + 装载 2）
        for decl in ["appendDrawing(", "appendReviewDrawing(", "routeDrawingCommit(", "deleteDrawing(at index:",
                     "removeReviewDrawing(at index:", "setReviewLossy(", "setReviewDrawings("] {
            try expectEngineInternalOnly(decl)      // 非 public **且非 package/open**（codex plan-R8-F1）
        }
        // (2) 唯一调用点（**核心**：仅非 public 不够——包内新调用者仍能绕过 handleDrawingTap 的 geometry 门）
        let appends = try callSiteCount("appendDrawing(")
        #expect(appends.map(\.count).reduce(0, +) == 1)
        #expect(appends.allSatisfy { $0.file.contains("TrainingEngine.swift") })    // = routeDrawingCommit 内
        let reviewAppends = try callSiteCount("appendReviewDrawing(")
        #expect(reviewAppends.map(\.count).reduce(0, +) == 1)
        let route = try callSiteCount("routeDrawingCommit(")
        #expect(route.map(\.count).reduce(0, +) == 1)
        #expect(route.allSatisfy { $0.file.contains("ChartContainerView") })        // 在 handleDrawingTap 的门之后
        // index 版删除：零生产调用点（D51/D67）
        #expect(try callSiteCount("deleteDrawing(at:").isEmpty)
        #expect(try callSiteCount("removeReviewDrawing(at:").isEmpty)
        // 装载入口：setReviewLossy 只在 Coordinator（复盘装载）与 TrainingEngine（setReviewDrawings 委托）
        let reviewLossy = try callSiteCount("setReviewLossy(")
        #expect(!reviewLossy.isEmpty)
        #expect(reviewLossy.allSatisfy { $0.file.contains("TrainingSessionCoordinator") || $0.file.contains("TrainingEngine") })
        // setReviewDrawings 零 Sources/ 调用点（其定义委托 setReviewLossy；定义本身按 "func"+pattern 扣掉）
        #expect(try callSiteCount("setReviewDrawings(").isEmpty)
        // (3) **标识符文件作用域**（codex plan-R6-F1）：只数调用 pattern 对 append 家族同样不够——
        //     `let f = engine.appendDrawing` / `engine.routeDrawingCommit` 这类**方法引用**能把调用挪到别处，
        //     绕过「唯一调用点在 handleDrawingTap 的 :303 visibleGeometry 门之后」这条**唯一**的几何保证。
        //     update/delete 已按标识符钉死（N15/N19a），append 家族必须同判据（不留强弱两档）。
        //     ⚠️ 白名单是对 `f3f67da` 源码**实测**的（`grep -rln` + 逐条确认是代码还是注释），不是推断：
        //       `appendDrawing`/`appendReviewDrawing` 仅 TrainingEngine.swift 有代码；
        //       `routeDrawingCommit` 在 TrainingEngine.swift（定义）与 ChartContainerView.swift:304（唯一路由）；
        //       其余文件（TrainingView/DrawingSession/LossyDrawingArray）里的同名字样**全是注释**，
        //       扫描器剥注释后不计入 —— 这条正是「必须剥注释」的实证理由，别把剥注释那步删了。
        #expect(try filesMentioning("appendDrawing").allSatisfy { $0.contains("TrainingEngine.swift") })
        #expect(try filesMentioning("appendReviewDrawing").allSatisfy { $0.contains("TrainingEngine.swift") })
        #expect(try filesMentioning("routeDrawingCommit").allSatisfy {
            $0.contains("TrainingEngine.swift") || $0.contains("ChartContainerView.swift")
        })
    }
```

> ⚠️ 必须核对真实源码再写死（[[feedback_plan_embedded_facts_unreliable]]：计划内嵌的**事实**必须实测）：
> - **访问级别断言里的参数名**（`deleteDrawing(at index:` / `removeReviewDrawing(at index:`）：squeeze 后要与真实签名同形才断得准，实施时先 `grep -n "func deleteDrawing(at\|func removeReviewDrawing(at" Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` 核实。
>   （**调用点计数**不再需要传 defPattern —— `callSiteCount` 内部固定按 `"func"+pattern` 扣，first-argument-label 的定义因形状不同而**本来就不会**被计入，见守卫自检 b。）
> - `appendDrawing(` 的**调用**计数：`routeDrawingCommit` 里那一处。若实测不等于 1，先查是不是有新调用点（那才是守卫要抓的），不要直接改数字。

- [ ] **Step 6: 全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift
git commit -m "划线 1b-i 切片2 Task5：deleteDrawing(id:) internal 删除写入面 + locked/id 唯一门（D51/D60/D66）"
git status --porcelain   # 期望：空输出（codex plan-R14-F3：防新建文件漏 add）
```

---

### Task 6: 接手 PR-1 的 Minor backlog（5 项）

> 来源：PR-1 whole-branch Opus 终审判为 backlog 的 3 项文档级 Minor + whole-branch triage 判 backlog 的 2 项。第 6 项「Catalyst 基线尾随」不在此 Task，属收尾三绿门（见文末）。
> ⚠️ triage 里的「`.segment` 门不 check toolType」**已在 PR-1 的 `42620f6` 修掉**（`isRenderableSubType` 已限 `.horizontal`），本 Task 不重复处理；本切片 Task 1 进一步把它提为共享单点。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`routeDrawingCommit` 注释 + append 纵深防御注释）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift:51`（注释「画线数」→「画线签名」）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift`（`tailAnchor` 子字段改长度前缀）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift`（`makeHLine` 的 `id` 去默认值）
- Modify: 3 处 `makeHLine(` 无 id 调用点（`grep -rn 'makeHLine(' Tests/ | grep -v 'makeHLine(id:'` 得到实际清单）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/DrawingSignatureTests.swift`（追加 tailAnchor 单射断言）

- [ ] **Step 1: Minor ① —— `routeDrawingCommit` 吞 append 返回值：写明为何安全 + 编辑路径禁扩**

`routeDrawingCommit`（`:1154-1168`）的两个分支 `appendReviewDrawing(stamped)` / `appendDrawing(stamped)` 丢弃了 `Bool`。在函数注释末尾追加（**不改代码行为**）：

```swift
    /// **为何这里吞掉 append 的返回值是安全的（PR-1 Opus 终审 Minor ①，1b-i 切片2 补记）**：
    /// 本路由是**纯 append** 语义——被拒 = no-op（一条线没进库），**不存在"已删原线"的中间态**，故丢弃
    /// 返回值不会造成静默数据丢失（最坏是这一次提交没生效，用户再点一次即可；其唯一调用点
    /// `handleDrawingTap` 已先验 `visibleGeometry`，真被引擎拒的只可能是坏数据）。
    /// ⚠️ **但编辑路径绝不可扩到这里**（1b-i 切片2 的 `updateDrawingStyle` 是**原地替换**、不经本路由）：
    /// 一旦有人把「删旧 + append 新」式编辑接进本函数，吞掉的 `false` 就变成**静默丢线**
    /// （codex WB R2-high 原始 finding 的形状）。要扩本路由，必须同时消费返回值并在失败时回滚。
```

- [ ] **Step 2: Minor ② —— append 边界「只 implemented 工具」纵深防御降级：记录决策（不加门）**

PR-1 把 `.segment` 横规则限定到 `.horizontal` 后，append 边界不再拦「本期尚未实现的工具」。**决策：不补这道门**，理由写进 `isRenderableSubType` 私有 helper 的注释末尾：

```swift
    /// **纵深防御降级的记录（PR-1 Opus 终审 Minor ②，1b-i 切片2 裁决：append 侧不补门）**：
    /// ⚠️ 别与**编辑面**的工具门（`isEditableToolType`，codex plan-R11-F1）混为一谈——那道门是"改写保守"，
    /// 这里是"进来宽松"，两者刻意不对称（拒绝进来 = 丢数据；放行改写 = 污染高版本数据）。本 helper 限定横规则后，
    /// append 边界不再顺带拦「本期未实现的工具」。这**今天不是洞**：会话/提交侧已 fail-close 到唯一实现的
    /// 水平线（`DrawingSession.activate` 只被顶栏画图钮以 `.horizontal` 调用），decode/resume 走整组赋值
    /// 不经 append。补一道「只许 implemented 工具」的门反而会**重犯 PR-1 那个 over-reject**
    /// （把只对某类型成立的规则套到所有类型 → 对 P1c 的合法数据静默拒），故按 YAGNI 不补，
    /// 留待 P1c 定义完整的 toolType × lineSubType 矩阵时一并处理。
```

- [ ] **Step 3: Minor ③ —— Coordinator 注释与实现对齐**

`TrainingSessionCoordinator.swift:51` 的 `// 新需求10：当前 replay 会话创建时的状态基线（tick/交易数/画线数/上下周期）。`
→ 把「画线数」改成「画线规范语义签名」（PR-1 已把 `drawings.count` 换成 `drawingsSig`，注释滞后）。

- [ ] **Step 4: Minor ④ —— `makeHLine` 默认 id 撞车（让坏状态不可表达）**

`DrawingTestFixtures.swift:5` 的 `id: String = "hl"` 默认值，会让「同一数组里造两条」默认撞 D66 的唯一 id 门。**去掉默认值**（`id: String`），强制每个调用点显式给 id：

```swift
func makeHLine(id: String, candleIndex: Int = 3, price: Double = 10,
               period: Period = .daily, thickness: Int = 1, text: String = "") -> DrawingObject {
```

然后修 3 处无 id 调用点（**已实测清单**，实施时用 `grep -rn 'makeHLine(' Tests/ | grep -v 'makeHLine(id:' | grep -v 'func makeHLine'` 复核，若前面几个 Task 又新增了无 id 调用点则一并补）：
- `TrainingEngineDrawingSessionTests.swift:646` → `makeHLine(id: "d1", candleIndex: 3, price: 10)`
- `TrainingEngineDrawingSessionTests.swift:649` → `makeHLine(id: "r1", candleIndex: 4, price: 11)`（review 侧，与上条不同数组但仍给不同 id 更清晰）
- `TrainingEngineDrawingSessionTests.swift:656` → `makeHLine(id: "d1", candleIndex: 3, price: 10)`

- [ ] **Step 5: Minor ⑤ —— `DrawingSignature` 的 `tailAnchor` 子字段改长度前缀**

`DrawingSignature.swift` 里 `tailAnchor` 那行用逗号拼接三个子字段，与本文件「所有字段一律长度前缀」的单射纪律不一致（今天不碰撞——三个子字段都是数字/枚举 raw；但纪律不该有例外）。改为逐子字段 `lp()`：

```swift
            String(d.tailAnchor != nil),                       // 区分 tailAnchor==nil 与「有但字段恰好空」
            d.tailAnchor.map { lp(String($0.candleIndex)) + lp(String($0.price)) + lp($0.period.rawValue) } ?? "",
```

追加断言到 `DrawingSignatureTests.swift`：

```swift
    @Test("canonicalDrawingsSignature: tailAnchor 子字段也走长度前缀（单射纪律无例外）")
    func tailAnchorSubfieldsAreLengthPrefixed() throws {
        func withTail(_ id: String, _ ci: Int, _ price: Double) -> DrawingObject {
            DrawingObject(id: id, toolType: .horizontal,
                          anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                          isExtended: false, panelPosition: 0, period: .daily,
                          tailAnchor: DrawingAnchor(period: .daily, candleIndex: ci, price: price))
        }
        // 两条只差 tailAnchor 内容 → 签名必须不同
        #expect(canonicalDrawingsSignature([withTail("t", 1, 2)]) != canonicalDrawingsSignature([withTail("t", 12, 0)]))
        // 有 tailAnchor vs 无 tailAnchor → 签名必须不同
        let noTail = makeHLine(id: "t")
        #expect(canonicalDrawingsSignature([withTail("t", 1, 2)]) != canonicalDrawingsSignature([noTail]))
    }
```

- [ ] **Step 6: 全量 host 测试**

Run: `cd ios/Contracts && swift test 2>&1 | tail -5`
Expected: 全绿。

- [ ] **Step 7: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Persistence/DrawingSignature.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DrawingTestFixtures.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/DrawingSignatureTests.swift
git add -u ios/Contracts/Tests/KlineTrainerContractsTests   # 3 处 makeHLine 调用点
git commit -m "划线 1b-i 切片2 Task6：接手 PR-1 的 5 项 Minor backlog（注释对齐 + fixture 唯一 id + 签名单射纪律）"
git status --porcelain   # 期望：空输出（codex plan-R14-F3：防新建文件漏 add）
```

---

## 收尾：三绿门（控制者亲跑，不得委托）

1. **host `swift test`**（fresh，非增量）：
   ```bash
   cd "<worktree>/ios/Contracts" && rm -rf .build/arm64-apple-macosx && \
   echo "BRANCH=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && \
   swift test 2>&1 | tail -5
   ```
   Expected：`Test run with N tests passed`（N = 1676 + 本切片新增；无 failure）。判绿**读输出内容**，不看 exit code（管道会吞退出码）。

2. **fresh 非增量 Catalyst**（本切片加了测试 → 必跑）：按 `.github/scripts/catalyst-gate.sh` 的既有命令跑真 `xcodebuild test`，取实测总数。
   - 落在 `catalyst-total-baseline.txt`（1574）±30 内 → 不动基线；
   - 漂出 → 按 G7 维护规则同步三文件（`catalyst-total-baseline.txt` / `pass-main-current.log` **用本次真 fresh 日志重裁** / `catalyst-gate.test.sh` 活基线回显），再跑闸门自测确认全过。

3. **iOS build**：`app-build.yml` 的等价命令（模拟器 + `CODE_SIGNING_ALLOWED=NO`，不碰钥匙串）。

4. **whole-branch 评审**：Opus 全支终审 → `codex:adversarial-review`（`codex-attest.sh`，**`--scope branch-diff` 无窄化**）。attest 后 **Read 账本文件**核 `head_sha == HEAD`；任何 HEAD 移动（哪怕只改 `.github`）都要**重新 attest**。

5. **PR**：`git push` 由控制者跑；`gh pr create` / `gh pr merge` 被 guard 拦 → user 真终端跑。合并后 `gh run watch` 盯 main 真绿。

**本切片无真机验收项**（引擎层，无 UI）——真机上手验收留到 PR-4。

---

## 交接（PR-3 / PR-4 必须接手）

0. **已接受的残留（本切片明写，别当没说）**：源码守卫是**文本级**的（调用点计数 + 标识符文件作用域），它挡得住「忘了补几何门就加调用点」和「用方法引用绕过调用 pattern」，但**挡不住**已在白名单文件里的代码把方法引用**传出去**。要彻底焊死只有两条路：SwiftSyntax 级扫描（为一条守卫引入编译器级依赖），或「只有几何校验过的路由能构造」的授权对象——后者在本仓落不了地：能构造它的类型得声明在 UI 路由文件，而那是 UIKit-only 文件（纯 macOS host 不编译），引擎引用它会直接炸掉 host 测试；把几何证明塞进引擎签名又违反 D65「引擎签名不含 geometry 参数」。**现状取舍**：本切片零调用点、危害为零；PR-4 接线时这条守卫是**唯一**的几何门 forcing function，届时若觉得不够，再单独评估上 SwiftSyntax。
1. **PR-4 的 UI 可用性必须按修订后的 D61/D65 落地**（codex plan-R15-F1 + R18-F2，spec 已同步）：置灰分量 = `locked` + 当前几何 + **「未来数据样式改得到吗」**——
   - 未来值落在样式写得到的 key（`{lineSubType, lineStyle, thickness, colorToken, labelMode, isExtended, textColorToken}`）→ 控件**可点**（用户换成本版本认识的值即完成修复），引擎按「看结果」最终裁决、被拒时给反馈并**保留选中**；
   - 未来值落在 `anchors[].period` / `tailAnchor.period` 这类**样式碰不到**的位置，或存在**未来顶层字段** → 样式控件**灰**、🗑 **亮**（没有控件能覆盖它，可点即必败；靠删除解封）；
   - **UI 谓词与引擎判据必须共用同一个 helper**（PR-4 抽出来，禁止 UI 自己写一份 key 集合，否则又是两档判据）。
   - **三条路由级测试**（引擎直调不算覆盖）：① 未来 `colorToken` → 控件可点、换色成功、改粗细被拒有反馈；② 未来顶层字段 → 控件灰、🗑 亮、删除成功；③ 未来 `anchors[0].period` → 控件灰、🗑 亮。
2. **PR-4 接线时必须同步改两条源码守卫**（本切片故意写成「零调用点」）：
   - `updateDrawingStyle(` → 恰好 1 处，且在 UI 编辑路由内，且路由**先过 D65 当前几何门 → 若改 `lineSubType` 再过 D58 候选预检 → 才调引擎**；
   - `deleteDrawing(id:` → 恰好 1 处，且在 UI 删除路由内，且路由在**确认框点「删除」之后**重算 `visibleGeometry`（D65 R13-F1 时序）。
3. **选中态相关的全部负向测试**（N1/N6/N7/N8/N13d/N14c 路由版/N14d/N16/N17/N18/N19c/N19e）归 PR-3/PR-4，本切片一条都没覆盖（见「覆盖 vs 交接」表）。
4. **D49 面板派生回显**（`DrawingStyleParams` 改收 `style` + `onChange`）归 PR-4。本切片**没有动面板**（SD-2b）：面板照旧自己规整显示态，写入边界另有一道独立归一化（`withStyle`）——两者消费同一份规则实现，PR-4 接线时面板只需把完整 `DrawingDefaultStyle` 交给路由，写入边界会再归一化一次（幂等）。
5. **P1c 落新工具 = 两步**（codex plan-R11-F1 / R12-F2 / R13-F2 / R15-F2）：① 照常加进既有的 `DrawingToolType.implemented`（`Models.swift:50`，**不另立登记表**）→ 能激活、能落锚、**能提交出线**（新建路径**不**受编辑门影响，R15-F2 已把工具门从 `withStyle` 挪进 `updateDrawingStyle`）；② 为它写出子类型/标注矩阵并加进 `DrawingStyleAvailability.toolsWithStyleMatrix` → 才可**改样式**。只做 ① 的话：画得出、但样式控件对它不生效（fail-closed、一眼可见、不污染数据），且漂移告警断言会当场红提醒补矩阵。这道门今天的作用是挡住**高版本写的已知但未实现工具**被本构建按水平线假设不可逆改写。
6. **1b-ii `setDrawingLocked(id:locked:)`**：必须是**独立** API 并豁免 D60 闸；且它会撞 D61 的坑（锁定一条未来枚举值线也会 re-merge 抹字节）→ 必须做 raw-preserving 单字段 merge，不能照抄本切片的「整条拒绝」（spec §9）。
