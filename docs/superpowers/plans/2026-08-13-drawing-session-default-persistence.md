# 划线「本局默认」持久化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让「本局默认画线样式」随训练 / replay 存档持久化，使断点续训能继承用户在本局改过的默认。

**Architecture:** `pending_training` / `pending_replay` 两张表各加一个**可空 TEXT 列**存样式 JSON（migration `0010`）；解码走**两个 repo 共用的一个容错函数**（绝不 throw、逐字段回落、解码即 sanitize）；写入在 `saveProgress` 两处、读回在两处 `resume`；`replayBaseline` 的 clean-skip 判据新增一个分量；`TrainingView` 新增一条 autosave 触发。

**Tech Stack:** Swift 6 / SwiftPM · GRDB 6.29.3 · swift-testing（Contracts）+ XCTest（Persistence）· Python pytest（backend 跨语言断言）

**Spec:** `docs/superpowers/specs/2026-08-13-drawing-session-default-persistence-design.md`（**D90–D100**，⚠️ **spec 经 user override 收口、未 approve**；override **只赦免文档写法，不赦免行为正确性**，见该 spec §12）

---

## Global Constraints

- **基线**：`origin/main` `20f615a`；分支 `feat/drawing-session-default-persistence`；worktree `.dev/worktree/drawing-default-persist`。
- **闸门基线（实测）**：host `swift test` = `Test run with 1831 tests in 215 suites passed`。**每个 task 收尾必须跑 host 全量并记录条数**。
- **Catalyst 门必须用** `-scheme KlineTrainerContracts-Package` **且** `set -o pipefail`（library scheme 不编译 testTarget；tee 吞退出码）。**判绿读执行量，不读 `TEST SUCCEEDED` 字样。**
- **变异复原一律 `cp` 到 `/tmp` 再 `cp` 回**，禁止 `git checkout <file>`（会静默抹掉未提交改动）。
- **每条变异必须逐条关门看红**，并在 PR 描述记录「红的是**哪个测试名**」+ 恢复后重新变绿。
- **禁止**让 `setDefaultStyle` 去 bump `drawingsRevision`（D56：该计数只覆盖 `drawings`）。
- **禁止**改 `v1_4_baselineDDL` / `ios/sql/app_schema_v1.sql`（v1.4 冻结基线，改了会真打红 drift 闸门）。
- **禁止**改 `backend/tests/test_qmt_pilot_db.py:770`（它动态读 Swift 文件比对，同步后自动绿；改它 = 把跨语言守卫弄瞎）。
- 源码守卫的结构计数**一律剥注释、剥字符串字面量**后再匹配；每条守卫**配双向自检**（该命中的命中、不该命中的不命中）；锚点失效必须**报错**不得静默返回 0。
- 新增 API 的访问级别：`DrawingSession` 的 mutator 一律 **internal**，不得加 `public`。
- ⭐ **每个 task 的三条命令必须由它的 `Files` 段与变异表「派生」，不得各写一份**（codex plan-P-R4：同一份计划里连栽三处）：
  1. **`git add` 的文件集 == 该 task `Files` 段列出的全部文件**（Create + Modify + Test，一个不少）。
     **唯一例外**：`Files` 段里标注「**不得修改**」的条目（如 Task 4 的 `backend/tests/test_qmt_pilot_db.py`）
     —— 它们列在那里是为了**提醒别碰**，**不进 `git add`**；

  2. **变异前的 `cp` 备份必须覆盖变异表里出现的每一个文件**（不只是"主"文件）；
  3. **`--filter` 必须覆盖该 task 改动过的每一个测试文件**。
- ⭐ **每个 task 收尾必须 `git status --short` 确认工作区干净**（输出为空）。
  非空 = 有改动没被 commit（脏树假绿）或变异没复原干净 —— **两者都必须当场查清再继续**。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift` | `DrawingDefaultStyle` 值类型 | 加 `thicknessRange` + `sanitized(for:)` |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift` | 常驻样式面板 | 粗细档改引用 `thicknessRange` |
| `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift` | `PendingTraining` / `PendingReplay` 模型 + 显式 Codable | 各加 `drawingDefaultStyle` |
| `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift` | GRDB 迁移链 | 加 `0010`，`user_version` 7→8 |
| `ios/Contracts/Sources/KlineTrainerPersistence/Internal/DrawingDefaultStyleColumn.swift` | **新建**：共用的容错解码 + 编码 | 两个 repo 各调一次 |
| `…/Internal/PendingTrainingRepositoryImpl.swift` · `…/PendingReplayRepositoryImpl.swift` | 两张表的读写 | 各加一列的读写 |
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` · `backend/qmt_pilot_db.py` | `CONTRACT_VERSION` **两份源** | 同步 `1.12`→`1.13` |
| `docs/governance/m01-schema-versioning-contract.md` | 版本矩阵 | 同步**三行** |
| `…/TrainingEngine/TrainingSessionCoordinator.swift` | 写入 ×2 / clean-skip / 种子 ×2 | 见 Task 6 |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | autosave 触发 | 加一条 `.onChange` |

---

## Task 1: 样式值域与 sanitizer 落 Contracts 平台中立层

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift:27-35`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift:58`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift:27`（**写入边界受理闸**）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift:33`（渲染 clamp）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingDefaultStyleSanitizeTests.swift`（新建）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingStylePanelSourceGuardTests.swift`（追加 G5）

**Interfaces:**
- Produces: `DrawingDefaultStyle.thicknessRange: ClosedRange<Int>` · `DrawingDefaultStyle.sanitized(for: DrawingToolType) -> DrawingDefaultStyle`

- [ ] **Step 1: 写失败测试**

```swift
// DrawingDefaultStyleSanitizeTests.swift
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingDefaultStyle.sanitized")
struct DrawingDefaultStyleSanitizeTests {

    /// T6：磁盘上躺着 .segment → 必须回落，否则 commitPending 的 withStyle 恒返回 nil、用户一条线都画不出来
    @Test func horizontal_segment_falls_back_to_straight() {
        var s = DrawingDefaultStyle(); s.lineSubType = .segment
        #expect(s.sanitized(for: .horizontal).lineSubType == .straight)
    }

    /// T7：越域粗细夹回值域两端
    @Test func thickness_is_clamped_to_range() {
        var hi = DrawingDefaultStyle(); hi.thickness = 99
        var lo = DrawingDefaultStyle(); lo.thickness = 0
        #expect(hi.sanitized(for: .horizontal).thickness == DrawingDefaultStyle.thicknessRange.upperBound)
        #expect(lo.sanitized(for: .horizontal).thickness == DrawingDefaultStyle.thicknessRange.lowerBound)
    }

    /// T7b：(ray, .left) 是水平线下的非法组合 → 归一化到 .hidden
    @Test func horizontal_ray_with_left_label_is_normalized() {
        var s = DrawingDefaultStyle(); s.lineSubType = .ray; s.labelMode = .left
        #expect(s.sanitized(for: .horizontal).labelMode == .hidden)
    }

    /// T15b（不变量锁）：非水平工具**不得**被套上水平线规则。
    /// 本片调用点恒 .horizontal，故只能单元级构造 —— 但 P1c 一旦加工具，这条就是生产路径。
    @Test func non_horizontal_tool_keeps_its_label_and_subtype() {
        var s = DrawingDefaultStyle(); s.lineSubType = .ray; s.labelMode = .left
        let out = s.sanitized(for: .trend)
        #expect(out.labelMode == .left)        // 横线的「射线不能配左」不得外溢
        #expect(out.lineSubType == .ray)
    }

    /// 正向档：健康值原样穿过（防「全是拒了的套件」掩盖恒回落的实现）
    @Test func healthy_style_passes_through_unchanged() {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash2; s.thickness = 3
        s.colorToken = .purple; s.labelMode = .right
        #expect(s.sanitized(for: .horizontal) == s)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "ios/Contracts" && swift test --filter DrawingDefaultStyleSanitizeTests 2>&1 | tail -20
```
Expected: 编译失败，`value of type 'DrawingDefaultStyle' has no member 'sanitized'`

- [ ] **Step 3: 实现（追加到 `DrawingEnums.swift` 的 `DrawingDefaultStyle` 之后）**

```swift
public extension DrawingDefaultStyle {
    /// 粗细值域的**唯一**字面量来源。面板与持久化解码器都必须引用它。
    /// ⚠️ 禁止任何地方再写 `1...5`（源码守卫 G5 钉死）。
    static let thicknessRange: ClosedRange<Int> = 1...5

    /// 把一份**可能来自磁盘 / 来自未来版本**的默认样式收敛成本构建一定能用的值。
    /// 三条规则各自复用既有单一真相，本函数**不新写任何判据**：
    ///   - `lineSubType` → `DrawingStyleAvailability.isRenderableSubType(_:toolType:)`
    ///   - `thickness`   → `thicknessRange`
    ///   - `labelMode`   → `DrawingStyleAvailability.normalizedLabelMode(current:lineSubType:toolType:)`
    /// ⚠️ **两处都必须用带 `toolType` 的重载**：两参版是**水平线专用**的，
    ///    对非水平工具套它会把合法的 `.show`/`.left` 静默改写成 `.hidden`
    ///    （`DrawingStyleAvailability` 里那个重载的头注逐字记录了这个后果）。
    func sanitized(for toolType: DrawingToolType) -> DrawingDefaultStyle {
        var out = self
        if !DrawingStyleAvailability.isRenderableSubType(out.lineSubType, toolType: toolType) {
            out.lineSubType = .straight
        }
        out.thickness = min(max(out.thickness, Self.thicknessRange.lowerBound),
                            Self.thicknessRange.upperBound)
        out.labelMode = DrawingStyleAvailability.normalizedLabelMode(
            current: out.labelMode, lineSubType: out.lineSubType, toolType: toolType)
        return out
    }
}
```

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "ios/Contracts" && swift test --filter DrawingDefaultStyleSanitizeTests 2>&1 | tail -5
```
Expected: `5 tests passed`

- [ ] **Step 5: 三个消费者全部改用同一常量**

值域在本仓有**三个持有者**（codex plan-P-R3 high② 指出前两个，第三个是我连带自查发现的）：

| 文件:行 | 现状 | 改成 |
|---|---|---|
| `DrawingStyleParams.swift:58` | `options(Array(1...5), current: style.thickness,` | `options(Array(DrawingDefaultStyle.thicknessRange), current: style.thickness,` |
| `DrawingObjectStyleEdit.swift:27` | `guard (1...5).contains(s.thickness) \|\| s.thickness == thickness else { return nil }` | `guard DrawingDefaultStyle.thicknessRange.contains(s.thickness) \|\| s.thickness == thickness else { return nil }` |
| `HorizontalLineTool.swift:33` | `let clamped = min(max(t, 1), 5)` | `let clamped = min(max(t, DrawingDefaultStyle.thicknessRange.lowerBound), DrawingDefaultStyle.thicknessRange.upperBound)` |

⚠️ **三处都是同值改名，行为零变化** —— 尤其 `DrawingObjectStyleEdit:27` 那条**条件式**
（`… || s.thickness == thickness`：写入新的越域值→拒、原样带回本对象已有的越域值→放行）
是 D61/D52 的既有语义，**只换值域的表达方式，那半个条件一字不动**。

- [ ] **Step 6: 加源码守卫 G5（追加到 `DrawingStylePanelSourceGuardTests.swift`）**

```swift
/// G5：粗细值域**单一真相**。
/// ⚠️ **不能只数 `1...5` 字面量**（codex plan-P-R3 high② + 我的连带自查）：同一个值域在本仓有
///    **三种书写形态**，换个写法就绕过纯字面量计数 ——
///      · `DrawingStyleParams.swift:58`        `Array(1...5)`            （面板档位）
///      · `DrawingObjectStyleEdit.swift:27`    `(1...5).contains(...)`   （**写入边界受理闸**）
///      · `HorizontalLineTool.swift:33`        `min(max(t, 1), 5)`       （渲染 clamp，**正则看不见**）
///    故 G5 = 「字面量恰好 1 处」**加上**「三个消费者都**引用常量**」两条断言。
@Test func thickness_domain_has_exactly_one_literal_source() throws {
    let hits = try SourceGuardScanner.countOccurrences(
        pattern: #"1\s*\.\.\.\s*5"#,
        inSourcesMatching: { _ in true },
        stripCommentsAndStringLiterals: true)
    #expect(hits == 1, "`1...5` 字面量应只在 DrawingDefaultStyle.thicknessRange 的定义处出现，实测 \(hits) 处")
}

/// G5b：三个消费者必须**引用常量**，而不是各写各的数字。
/// 这条比数字面量结实 —— 它挡得住「换成 min/max 写法」这种绕过。
@Test func thickness_domain_consumers_reference_the_constant() throws {
    for file in ["UI/DrawingStyleParams.swift",
                 "Drawing/DrawingObjectStyleEdit.swift",
                 "Drawing/HorizontalLineTool.swift"] {
        let src = try SourceGuardScanner.strippedSource(of: file)
        #expect(src.contains("thicknessRange"),
                "\(file) 没有引用 DrawingDefaultStyle.thicknessRange —— 值域又分叉了")
    }
}

/// G5b 的**双向自检**：不含常量引用的样本必须被判不合格
@Test func g5b_rejects_hardcoded_bounds() {
    let fake = "let clamped = min(max(t, 1), 5)"
    #expect(!fake.contains("thicknessRange"))
}
```

> ⚠️ 若 `SourceGuardScanner` 无 `countOccurrences(pattern:inSourcesMatching:stripCommentsAndStringLiterals:)`，
> **先读 `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift` 用它已有的 API 改写**，
> **不要**新建第二个扫描器。并按仓规给新扫描能力配**双向自检**（喂一个含 `1...5` 的样本必须命中、喂 `1...4` 必须不命中）。

- [ ] **Step 7: 变异验证（M5 / M6 / M14 / M15b）**

```bash
# 备份**变异表里出现的每一个文件**（M14b 变异的是 HorizontalLineTool，不是 DrawingEnums）
cp ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift        /tmp/DrawingEnums.bak
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift /tmp/HorizontalLineTool.bak
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift /tmp/DrawingObjectStyleEdit.bak
```
逐条改 → 跑 → 记录红的测试名 → 用对应的 `.bak` `cp` 回去复原（**禁止 `git checkout`**）：

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M5 | 删掉 `isRenderableSubType` 那三行 | `horizontal_segment_falls_back_to_straight` |
| M6 | 删掉 `thickness` 的夹取 | `thickness_is_clamped_to_range` |
| M15b | `normalizedLabelMode` 换成**两参**重载 | `non_horizontal_tool_keeps_its_label_and_subtype` |
| M14 | `thicknessRange` 改成 `1...4` | G5 字面量条（定义处变了）+ 面板档数断言 T16 |
| **M14b** | 把 `HorizontalLineTool:33` 改回 `min(max(t, 1), 5)`（模拟「换写法绕过字面量计数」） | **只有 G5b** 红（G5 字面量条**仍绿** —— 正则看不见 min/max 形态，这正是 G5b 存在的理由） |

- [ ] **Step 8: 跑 host 全量 + 提交**

```bash
cd "ios/Contracts" && (set -o pipefail; swift test 2>&1 | tail -3)
# 与本 task 的 Files 段逐一对应（三个消费者 + 定义 + 两个测试文件）
git add ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Drawing/HorizontalLineTool.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingDefaultStyleSanitizeTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingStylePanelSourceGuardTests.swift
git commit -m "feat(drawing): DrawingDefaultStyle.thicknessRange + sanitized(for:)（D99）"
git status --short          # 必须为空
```

---

## Task 2: 两个 Pending 模型加字段 + 显式 Codable

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/AppState.swift`（`PendingTraining` `:94-224`、`PendingReplay` `:230-…`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/PendingCodableDefaultStyleTests.swift`（新建）

**Interfaces:**
- Consumes: `DrawingDefaultStyle`（Task 1 未改其形状，此处只用类型）
- Produces: `PendingTraining.drawingDefaultStyle: DrawingDefaultStyle?` · `PendingReplay.drawingDefaultStyle: DrawingDefaultStyle?`（两个 `init` 的新参数**带默认值 `= nil`**）

- [ ] **Step 1: 写失败测试**

```swift
// PendingCodableDefaultStyleTests.swift
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("Pending* 的 Codable 契约：drawingDefaultStyle")
struct PendingCodableDefaultStyleTests {

    private func nonDefaultStyle() -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash3; s.thickness = 4
        s.colorToken = .cyan; s.labelMode = .right
        return s
    }

    /// T17：PendingTraining 的 Codable 往返 —— DB 路径不走 Codable，
    /// 漏掉 encodeIfPresent 时所有 DB 边界测试仍全绿，故这条不可省。
    @Test func pendingTraining_codable_roundtrip_preserves_style() throws {
        let s = nonDefaultStyle()
        let p = try PendingTrainingFixture.make(drawingDefaultStyle: s)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PendingTraining.self, from: data)
        #expect(back.drawingDefaultStyle == s)
    }

    /// T17b：PendingReplay 同上
    @Test func pendingReplay_codable_roundtrip_preserves_style() throws {
        let s = nonDefaultStyle()
        let p = try PendingReplayFixture.make(drawingDefaultStyle: s)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(PendingReplay.self, from: data)
        #expect(back.drawingDefaultStyle == s)
    }

    /// T18：旧载荷（无该 key）→ 解码成功且为 nil，其余字段照常
    @Test func old_payload_without_key_decodes_to_nil() throws {
        let p = try PendingTrainingFixture.make(drawingDefaultStyle: nil)
        var obj = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(p)) as! [String: Any]
        obj.removeValue(forKey: "drawingDefaultStyle")
        let data = try JSONSerialization.data(withJSONObject: obj)
        let back = try JSONDecoder().decode(PendingTraining.self, from: data)
        #expect(back.drawingDefaultStyle == nil)
        #expect(back.globalTickIndex == p.globalTickIndex)   // 其余字段未受影响
    }
}
```

> ⚠️ `PendingTrainingFixture` / `PendingReplayFixture` 是本 task 要新建的测试辅助（放同文件内 `enum`），
> **必须复用** `ios/Contracts/Tests/KlineTrainerContractsTests/` 下既有的构造样例（先 grep `PendingTraining(` 找现成的），
> **不要**凭空编造字段值。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "ios/Contracts" && swift test --filter PendingCodableDefaultStyleTests 2>&1 | tail -20
```
Expected: 编译失败，`extra argument 'drawingDefaultStyle' in call`

- [ ] **Step 3: 实现 —— `PendingTraining`**

在属性区（`AppState.swift:107` `sessionKey` 之后）加：

```swift
    /// D90/D91：本局画线默认样式。`nil` = 旧档 / 本局从未改过（→ 回落全局默认）。
    /// ⚠️ **落盘边界是 repo 的具名列 SQL，不是这个 Codable**（本类型的 Codable 生产上零消费者）；
    ///    但它是 `public`，故必须保持**无损**，否则未来第一个消费者会静默丢值。
    public let drawingDefaultStyle: DrawingDefaultStyle?
```

两个 `init` 的参数列表末尾加（**必须带默认值**，否则 `DebugFixtureData.swift:181` 等既有构造点全部编译失败）：

```swift
        drawingDefaultStyle: DrawingDefaultStyle? = nil
```
并在函数体加 `self.drawingDefaultStyle = drawingDefaultStyle`。

`CodingKeys` 加一个 case：

```swift
        case accumulatedCapital, drawdown, sessionKey, drawingDefaultStyle
```

`init(from:)` 末尾加：

```swift
        drawingDefaultStyle = try c.decodeIfPresent(DrawingDefaultStyle.self, forKey: .drawingDefaultStyle)
```

`encode(to:)` 末尾加：

```swift
        try c.encodeIfPresent(drawingDefaultStyle, forKey: .drawingDefaultStyle)
```

- [ ] **Step 4: 实现 —— `PendingReplay`**

逐条重复 Step 3 的四处改动（属性 / init 参数与赋值 / CodingKeys / init(from:) / encode(to:)）到 `PendingReplay`。
**不要写「同 Task 3」**——两个类型的 `CodingKeys` 列表不同，必须各自照抄自己的。

- [ ] **Step 5: `DrawingDefaultStyle` 加 `Codable`**

`DrawingEnums.swift:28` 的声明改为：

```swift
public struct DrawingDefaultStyle: Codable, Equatable, Sendable {
```
（五个成员均已是 `String` 原始值 `Codable` 枚举 + `Int`，合成实现即可。
⚠️ **合成解码遇未知原始值会抛** —— 这正是 Task 5 要写容错解码器的原因，此处不依赖它。）

- [ ] **Step 6: 跑测试确认通过 + 全量**

```bash
cd "ios/Contracts" && swift test --filter PendingCodableDefaultStyleTests 2>&1 | tail -5
cd "ios/Contracts" && (set -o pipefail; swift test 2>&1 | tail -3)
```
Expected: 3 tests passed；全量 ≥ 1831 + 新增条数

- [ ] **Step 7: 变异验证（M16 / M16b）**

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M16 | 删掉 `PendingTraining.encode(to:)` 的 `encodeIfPresent` | `pendingTraining_codable_roundtrip_preserves_style` |
| M16b | `init(from:)` 的 `decodeIfPresent` 改 `decode` | `old_payload_without_key_decodes_to_nil` |

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/AppState.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/PendingCodableDefaultStyleTests.swift
git commit -m "feat(contracts): PendingTraining/PendingReplay 加 drawingDefaultStyle（无损 Codable，D91）"
```

---

## Task 3: migration `0010` + `user_version` 7→8

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift:244`（`0009` 之后）
- Modify: **既有 `user_version` 断言共 6 处、分三个文件**（下表逐条列全；⚠️ **其中两处绝不能改**）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0010Tests.swift`（新建）

**Interfaces:**
- Produces: 两张表上的 `drawing_default_style TEXT`（可空）；`PRAGMA user_version == 8`

- [ ] **Step 1: 写失败测试**

```swift
// Migration0010Tests.swift
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

@MainActor
@Suite("migration 0010：升级路径 + 全新安装")
struct Migration0010Tests {

    /// T8（**升级路径**，本组重点）：构造一个「0001–0009 已应用」的真 pre-0010 库，
    /// 种入既有行，再跑完整 migrator → 两张表都要长出新列，**且既有行必须活着**。
    ///
    /// ⚠️ **不能用 `makeFreshDB()`**（codex plan-P-R2 high）：那是从空库跑完整 migrator，
    ///    证明的是**全新安装**。把列加到 baseline / 早期迁移的实现，fresh 测试照样全绿，
    ///    而**线上 v7 用户永远拿不到这一列**。
    /// ⚠️ **种行必须用 legacy raw SQL，不能用 repo**（codex plan-P-R3 high）：
    ///    Task 5 会把 repo 的 INSERT 改成**带新列**，而此刻库还停在 0009（无该列）
    ///    ⇒ 在最终树上 repo 种行会直接报 `no such column`，测试跑不到 0010 就先炸了。
    ///    **下面的列清单是 0009 时代的形状，逐字写死，不得改成引用 repo。**
    @Test func upgrade_from_v7_adds_column_to_both_tables_and_keeps_existing_rows() throws {
        let queue = try DatabaseQueue()
        let migrator = AppDBMigrations.makeMigrator()

        // ① 停在 0009 —— 真 pre-0010 现场
        try migrator.migrate(queue, upTo: "0009_v1.11_drawing_style")
        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 7)
        for t in ["pending_training", "pending_replay"] {
            let cols = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
            }
            #expect(!cols.contains("drawing_default_style"), "\(t) 在 0009 阶段就不该有新列")
        }

        // ② 用 **0009 时代的列清单** raw SQL 种既有行（此时无新列）
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO pending_training
                  (id, training_set_filename, global_tick_index, upper_period, lower_period,
                   position_data, fee_snapshot, trade_operations, drawings,
                   started_at, accumulated_capital, cash_balance, drawdown, session_key)
                VALUES (1, 'z.sqlite', 3, 'm60', 'daily', 'BwA=',
                        '{"commissionRate":0.0001,"minCommissionEnabled":true}', '[]', '[]',
                        123, 100000.0, 88000.0,
                        '{"peakCapital":100000,"maxDrawdown":0}', 'k')
                """)
            try db.execute(sql: """
                INSERT INTO pending_replay
                  (id, record_id, training_set_filename, global_tick_index, upper_period, lower_period,
                   position_data, fee_snapshot, trade_operations, drawings,
                   started_at, accumulated_capital, cash_balance, drawdown)
                VALUES (1, 9, 'z.sqlite', 3, 'm60', 'daily', 'BwA=',
                        '{"commissionRate":0.0001,"minCommissionEnabled":true}', '[]', '[]',
                        123, 100000.0, 88000.0,
                        '{"peakCapital":100000,"maxDrawdown":0}')
                """)
        }

        // ③ 跑完整 migrator（只应跑 0010）
        try migrator.migrate(queue)

        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 8)
        for t in ["pending_training", "pending_replay"] {
            let cols = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
            }
            #expect(cols.contains("drawing_default_style"), "\(t) 升级后仍缺该列，实测：\(cols)")
        }
        // ④ 既有行必须活着；**此刻才允许用 repo 读**（列已存在）
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_training") } == 1)
        #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM pending_replay") } == 1)
        #expect(try queue.read { try PendingTrainingRepositoryImpl.loadPending($0) }?.drawingDefaultStyle == nil)
        #expect(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }?.drawingDefaultStyle == nil)
    }

    /// T9（**全新安装**，与 T8 分开）：从空库跑完整 migrator → 终态 user_version = 8 且两表有列。
    @Test func fresh_install_reaches_v8_with_column() throws {
        let queue = try DatabaseQueue()
        try AppDBMigrations.makeMigrator().migrate(queue)
        #expect(try queue.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 8)
        for t in ["pending_training", "pending_replay"] {
            let cols = try queue.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(t))").map { $0["name"] as String }
            }
            #expect(cols.contains("drawing_default_style"), "\(t)")
        }
    }
}
```

> ✅ **`migrate(_:upTo:)` 已实测存在**：`ios/Contracts/.build/checkouts/GRDB.swift/GRDB/Migration/DatabaseMigrator.swift:252`
> `public func migrate(_ writer: some DatabaseWriter, upTo targetIdentifier: String) throws`
> —— 本仓 vendored 的就是这份，签名逐字可用，**不必再找替代路子**。
> （备用范式仍记录在此：`AppDB0005MigrationTests:102-121` 的「部分 migrator」写法，注册**与 `AppDBMigrations` 同 id 同体**的前序迁移。
> **两条路都可以，但绝不能退回 `makeFreshDB()`** —— 那就把升级路径的覆盖整个丢了。）

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "ios/Contracts" && swift test --filter Migration0010Tests 2>&1 | tail -20
```
Expected: 两条都 FAIL（缺列 / user_version 仍为 7）

- [ ] **Step 3: 实现（`AppDBMigrations.swift` `0009` 块之后、`return migrator` 之前）**

```swift
        // 0010：本局画线默认样式持久化（v1.12→1.13）。additive：两张 pending 表各加**可空** TEXT 列，
        // 故直接 ALTER ADD 即可（对比 0009 需要 NOT NULL/UNIQUE 才走「建新表+回填+换名」）。
        // 只走 migration，不动 v1_4_baselineDDL/app_schema_v1.sql（v1.4 冻结基线，drift-checked）。
        migrator.registerMigration("0010_v1.13_drawing_default_style") { db in
            try db.execute(sql: "ALTER TABLE pending_training ADD COLUMN drawing_default_style TEXT")
            try db.execute(sql: "ALTER TABLE pending_replay ADD COLUMN drawing_default_style TEXT")
            try db.execute(sql: "PRAGMA user_version = 8")
        }
```

- [ ] **Step 4: 改既有断言（**逐条对照本表，不要 sed 全局替换**）**

> ⚠️ **`user_version` 的断言点有 6 个、分三个文件**（我起草时只找到 1 个 —— 全仓 grep 才发现）。
> **其中两处断的是「部分迁移的中间落点」，改了就把测试的意义毁掉。**

| 文件:行 | 现值 | 动作 |
|---|---|---|
| `AppDB0005MigrationTests.swift:22-23`（`test_fresh_install_full_migrator_user_version_7`） | `7` | **改 8**；函数名与 `:17` 注释里的 `7` 一并改 8 |
| `AppDB0005MigrationTests.swift:29` | `2` | ❌ **不动**（`partial：仅 0001/0003/0004 → user_version 2`，真 pre-0005 前提） |
| `AppDB0005MigrationTests.swift:40` | `7` | **改 8** |
| `AppDB0005MigrationTests.swift:72` | `7` | **改 8**；行尾注释 `（0009 bump→7）` 改 `（0010 bump→8）` |
| `ReviewArchiveMigrationTests.swift:14` | `7` | **改 8** |
| `ReviewArchiveMigrationTests.swift:25` | `4` | ❌ **不动**（`0006 落点`，构造 pre-0007 现场） |
| `ReviewArchiveMigrationTests.swift:34` | `7` | **改 8**；行尾注释 `升级到 v7` 改 `v8` |
| `PendingReplayPersistenceTests.swift:11-14`（`migration0006_createsTable_userVersion7`） | `7` | **改 8**；函数名与行尾注释一并改 |

**自检**：改完跑
```bash
grep -rn "user_version" ios/Contracts/Tests/ | grep -E "== *7|, *7\)"
```
Expected: **无输出**（所有终态断言已迁到 8；`2` / `4` 两处不在此模式内、保持原样）

- [ ] **Step 5: 跑测试确认通过 + drift 闸门**

```bash
cd "ios/Contracts" && swift test --filter "Migration0010Tests|AppDB0005MigrationTests|ReviewArchiveMigrationTests|PendingReplayPersistenceTests" 2>&1 | tail -5
cd "/Users/maziming/Coding/Prj_Kline trainer" && bash scripts/check_app_schema_drift.sh
```
Expected: 测试全过；drift 脚本输出 `OK: AppDBMigrations.swift schema 与 ios/sql/app_schema_v1.sql 一致`

- [ ] **Step 6: 变异验证（M1 / M12）**

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M1 | 删掉 `pending_replay` 那一句 `ALTER` | `test_0010_adds_column_to_both_pending_tables` 的 replay 分支；`user_version` 那条**不得**红 |
| M12 | `PRAGMA user_version = 8` 改回 `7` | `test_fresh_install_user_version_is_8` + `AppDB0005MigrationTests` 那条 |

- [ ] **Step 7: 提交**

```bash
# ⚠️ user_version 断言散在**三个**测试文件里，三个都要 staged（漏一个 = 脏树假绿 / CI 红）
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0010Tests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/AppDB0005MigrationTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/ReviewArchiveMigrationTests.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingReplayPersistenceTests.swift
git commit -m "feat(db): migration 0010 两张 pending 表加 drawing_default_style + user_version 8（D91）"
git status --short          # 必须为空
```

---

## Task 4: `CONTRACT_VERSION` 1.12→1.13（两份源）+ m01 三行 + 守卫 G8

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`
- Modify: `backend/qmt_pilot_db.py:798`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift:8`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift:1260`
- Modify: `docs/governance/m01-schema-versioning-contract.md`（矩阵**三行**）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift`（新建，G8）
- **不得修改**：`backend/tests/test_qmt_pilot_db.py:770`

- [ ] **Step 1: 写失败测试（G8）**

```swift
// M01MatrixSyncGuardTests.swift
import XCTest

/// G8：m01 矩阵三行必须与本 PR 同步。
/// 为什么需要它：本片 spec 自己点名的「矩阵停在 0003、代码已到 0009」正是「要求同步但无人强制」的产物。
final class M01MatrixSyncGuardTests: XCTestCase {
    private func matrixSection() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root
            .appendingPathComponent("docs/governance/m01-schema-versioning-contract.md"))
        guard let start = doc.range(of: "## CONTRACT_VERSION 矩阵"),
              let end = doc.range(of: "## Bump 策略", range: start.upperBound..<doc.endIndex)
        else { XCTFail("m01 矩阵锚点失效，无法定位章节"); return "" }   // 锚点失效必须报错，不得静默返回空
        return String(doc[start.upperBound..<end.lowerBound])
    }

    func test_m01_matrix_three_rows_are_in_sync() throws {
        let s = try matrixSection()
        XCTAssertTrue(s.contains("`\"1.13\"`"), "m01 顶层版本行未同步到 1.13")
        XCTAssertTrue(s.contains("0010_v1.13_drawing_default_style"), "m01 app.sqlite migration 行未同步")
        XCTAssertTrue(s.contains("| `1.4`") || s.contains("`1.4` "), "m01 Swift 模型版本行未同步到 1.4")
    }

    /// 双向自检：一个不含这些值的样本必须不满足（防「恒真断言」）
    func test_guard_rejects_stale_matrix_sample() {
        let stale = "| `CONTRACT_VERSION`（顶层标识） | `\"1.12\"` | … |"
        XCTAssertFalse(stale.contains("`\"1.13\"`"))
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "ios/Contracts" && swift test --filter M01MatrixSyncGuardTests 2>&1 | tail -10
```
Expected: `test_m01_matrix_three_rows_are_in_sync` FAIL（三条断言均未满足）

- [ ] **Step 3: 改两份常量**

`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`：
```swift
public let CONTRACT_VERSION = "1.13"
```
`backend/qmt_pilot_db.py:798`：
```python
CONTRACT_VERSION = "1.13"
```

- [ ] **Step 4: 改两处 Swift 断言**

`ModelsTests.swift:8` 与 `RenderStateBuilderTests.swift:1260` 的 `#expect(CONTRACT_VERSION == "1.12")` 均改为 `"1.13"`。

- [ ] **Step 5: 改 m01 矩阵三行**

`docs/governance/m01-schema-versioning-contract.md` 矩阵：
- 顶层行 `"1.12"` → `"1.13"`
- app.sqlite GRDB migration 行 `0003_v1.4_purge_leased` → `0010_v1.13_drawing_default_style`
- Swift 模型版本（`M0.3`）行 `1.3` → `1.4`

- [ ] **Step 6: 跑三处闸门确认通过**

```bash
cd "ios/Contracts" && swift test --filter "M01MatrixSyncGuardTests|ModelsTests" 2>&1 | tail -5
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && python3 -m pytest tests/test_qmt_pilot_db.py -k contract_version -q 2>&1 | tail -5
```
Expected: Swift 全过；backend 跨语言断言 **自动变绿**（它动态读 Swift 文件，两边同步即过）

- [ ] **Step 7: 变异验证（M13 / M13b / M13c）**

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M13 | **只**把 backend 那份改回 `"1.12"` | `backend/tests/test_qmt_pilot_db.py` 的跨语言断言 |
| M13b | 两份都改回 `"1.12"` | `ModelsTests` + `RenderStateBuilderTests` |
| M13c | 两份常量都对、migration 也在，但把 m01 三行改回旧值 | **只有** `test_m01_matrix_three_rows_are_in_sync` |

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift backend/qmt_pilot_db.py \
        ios/Contracts/Tests/KlineTrainerContractsTests/ModelsTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift \
        docs/governance/m01-schema-versioning-contract.md \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift
git commit -m "chore(contract): CONTRACT_VERSION 1.12→1.13（两份源）+ m01 矩阵三行同步 + 守卫 G8（D97）"
```

> ⚠️ **提交信息里必须留一句**：本次 bump 会让**已建的 QMT pilot 库**在闸 1 报 `schema_fingerprint_mismatch`，
> 需 `--reset` 重建 —— **这是闸门按设计工作，不是回归**（`qmt_pilot_db.py:1694/2224`）。

---

## Task 5: 共用容错解码器 + 两个 repo 各接一次

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/DrawingDefaultStyleColumn.swift`
- Modify: `…/Internal/PendingTrainingRepositoryImpl.swift:18-31, 33-85`
- Modify: `…/Internal/PendingReplayRepositoryImpl.swift:18-30, 32-81`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingDefaultStyleColumnTests.swift`（新建）

**Interfaces:**
- Consumes: `DrawingDefaultStyle.sanitized(for:)`（Task 1）· 模型字段（Task 2）· 列（Task 3）
- Produces: `DrawingDefaultStyleColumn.decode(_ raw: String?) -> DrawingDefaultStyle?` · `DrawingDefaultStyleColumn.encode(_ s: DrawingDefaultStyle?) -> String?`

- [ ] **Step 1: 写失败测试（每条坏值档**两张表各跑一遍**）**

```swift
// PendingDefaultStyleColumnTests.swift
// 风格对齐同 target 的 PendingReplayPersistenceTests（swift-testing + 内存 DatabaseQueue）。
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

@MainActor
@Suite("drawing_default_style 列：两张表 × 坏值矩阵")
struct PendingDefaultStyleColumnTests {

    /// 两张表用同一份用例跑 —— 它们是**两条各自独立的读路径**，只测一张等于只做一半。
    private enum Slot: CaseIterable { case training, replay
        var table: String { self == .training ? "pending_training" : "pending_replay" }
    }

    /// **真 repo 往返**（T1/T2）：构造带 `drawingDefaultStyle` 的对象 → `savePending`/`saveReplay`
    /// → `loadPending`/`loadReplay`。**全程不碰 raw SQL**。
    /// ⚠️ 这条必须与下面的 `seedRowThenReadStyle` **分开**（codex plan-P-R2 medium）：
    ///    那个 helper 总是先 raw UPDATE 覆写该列，于是「往返」根本没测到 repo 的 INSERT ——
    ///    把该列从 INSERT 里删掉（M2）也照样绿。**写路径必须由这条来守。**
    private func saveThenLoad(_ slot: Slot, style: DrawingDefaultStyle?) throws -> DrawingDefaultStyle? {
        let queue = try DatabaseQueue()
        try AppDBMigrations.makeMigrator().migrate(queue)
        let fee = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let dd = DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0)
        switch slot {
        case .training:
            let p = try PendingTraining(
                trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd, sessionKey: "k",
                drawingDefaultStyle: style)
            try queue.write { try PendingTrainingRepositoryImpl.savePending($0, pending: p) }
            return try queue.read { try PendingTrainingRepositoryImpl.loadPending($0) }?.drawingDefaultStyle
        case .replay:
            let p = try PendingReplay(
                recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd,
                drawingDefaultStyle: style)
            try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
            return try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }?.drawingDefaultStyle
        }
    }

    /// T1/T2 正向档：**经真写入路径**往返，逐字段相等
    @Test func repo_roundtrip_preserves_all_five_fields() throws {
        for slot in Slot.allCases {
            var s = DrawingDefaultStyle()
            s.lineSubType = .ray; s.lineStyle = .dash3; s.thickness = 4
            s.colorToken = .cyan; s.labelMode = .right
            #expect(try saveThenLoad(slot, style: s) == s, "\(slot.table) 往返丢字段")
        }
    }

    /// T3：模型里就是 nil（旧档 / 从未改过）→ 写进去是 NULL、读回来是 nil，其余字段照常
    @Test func repo_roundtrip_nil_style_stays_nil() throws {
        for slot in Slot.allCases {
            #expect(try saveThenLoad(slot, style: nil) == nil, "\(slot.table)")
        }
    }

    /// 三步：存一行 → raw SQL 把该列覆写成 `raw` → 走**真 repo 的 load 路径**读回。
    /// ⚠️ 必须经 repo 的 load，不得直接调 `DrawingDefaultStyleColumn.decode` ——
    ///    那样就测不到「repo 到底有没有接上这个函数」（M2/M3/M15 全靠这一点才有判别力）。
    /// 返回 `.some(style?)` = load 成功（内层 nil 表示列为 NULL）；`.none` = load **抛了**。
    private func seedRowThenReadStyle(_ slot: Slot, column raw: String?) throws -> DrawingDefaultStyle?? {
        let queue = try DatabaseQueue()                       // in-memory，同 PendingReplayPersistenceTests
        try AppDBMigrations.makeMigrator().migrate(queue)
        let fee = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let dd = DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0)
        switch slot {
        case .training:
            let p = try PendingTraining(
                trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd, sessionKey: "k")
            try queue.write { try PendingTrainingRepositoryImpl.savePending($0, pending: p) }
        case .replay:
            let p = try PendingReplay(
                recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd)
            try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE \(slot.table) SET drawing_default_style = ? WHERE id = 1",
                           arguments: [raw])
        }
        do {
            switch slot {
            case .training: return .some(try queue.read { try PendingTrainingRepositoryImpl.loadPending($0) }?.drawingDefaultStyle ?? nil)
            case .replay:   return .some(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }?.drawingDefaultStyle ?? nil)
            }
        } catch {
            return .none        // load 抛了 —— D92 明令这不允许发生
        }
    }

    /// T3b：列被外部置为 NULL（raw 路径）→ 仍读作 nil、不抛
    @Test func raw_null_column_reads_as_nil() throws {
        for slot in Slot.allCases {
            #expect(try seedRowThenReadStyle(slot, column: nil) == .some(nil), "\(slot.table)")
        }
    }

    /// T4：未来枚举值，**四个枚举字段各一条** —— 只测 colorToken 时，
    /// 一个「只给 colorToken 加 try?」的实现照样能过，而 {"lineStyle":"dash5"} 仍会 brick。
    @Test func future_enum_value_falls_back_field_locally() throws {
        let cases: [(String, (DrawingDefaultStyle) -> Bool)] = [
            (#"{"lineSubType":"arc","colorToken":"cyan"}"#,  { $0.lineSubType == .straight && $0.colorToken == .cyan }),
            (#"{"lineStyle":"dash5","colorToken":"cyan"}"#,  { $0.lineStyle == .solid     && $0.colorToken == .cyan }),
            (#"{"colorToken":"未来色","thickness":4}"#,       { $0.colorToken == .orange   && $0.thickness == 4 }),
            (#"{"labelMode":"center","colorToken":"cyan"}"#, { $0.labelMode == .hidden    && $0.colorToken == .cyan }),
        ]
        for slot in Slot.allCases {
            for (raw, check) in cases {
                guard let loaded = try seedRowThenReadStyle(slot, column: raw), let s = loaded else {
                    { Issue.record("\(slot.table) 在 \(raw) 上抛了或返回 nil"); return }
                }
                #expect(check(s), "\(slot.table) / \(raw)：坏字段未回落或牵连了别的字段")
            }
        }
    }

    /// T5：整段不是合法 JSON → 整个默认回落，仍不抛
    @Test func invalid_json_falls_back_wholesale() throws {
        for slot in Slot.allCases {
            let loaded = try seedRowThenReadStyle(slot, column: "{{{")
            #expect(loaded == .some(DrawingDefaultStyle()), "\(slot.table)")
        }
    }

    /// T5b：**类型不匹配**，五个字段各一条 —— `decodeIfPresent(Int.self)` 能过 T4/T5 却在这里抛。
    /// ⚠️ **每条都带一个健康的 companion 字段并断言它存活**（codex plan-P-R1 medium）：
    ///    上一稿只断言「没抛且非 nil」，于是一个「任何类型不匹配就把整份默认丢回出厂」的实现
    ///    照样全绿 —— 而那**违反 D92 的逐字段回落不变量**。判据必须和 T4 对称。
    @Test func type_mismatch_falls_back_field_locally() throws {
        let cases: [(String, (DrawingDefaultStyle) -> Bool)] = [
            // 坏字段回落到出厂值；companion 字段必须**保留磁盘上的值**
            (#"{"thickness":"fat","colorToken":"cyan"}"#,
             { $0.thickness == DrawingDefaultStyle().thickness && $0.colorToken == .cyan }),
            (#"{"lineSubType":7,"colorToken":"cyan"}"#,
             { $0.lineSubType == .straight && $0.colorToken == .cyan }),
            (#"{"colorToken":null,"thickness":4}"#,
             { $0.colorToken == DrawingDefaultStyle().colorToken && $0.thickness == 4 }),
            (#"{"lineStyle":[],"colorToken":"cyan"}"#,
             { $0.lineStyle == .solid && $0.colorToken == .cyan }),
            (#"{"labelMode":{},"colorToken":"cyan"}"#,
             { $0.labelMode == .hidden && $0.colorToken == .cyan }),
        ]
        for slot in Slot.allCases {
            for (raw, check) in cases {
                guard let loaded = try seedRowThenReadStyle(slot, column: raw), let s = loaded else {
                    Issue.record("\(slot.table) 在 \(raw) 上抛了或返回 nil"); return
                }
                #expect(check(s), "\(slot.table) / \(raw)：坏字段未回落，或把同一对象里健康的 companion 字段一起丢了")
            }
        }
    }

    /// T6 在持久化侧的落地：磁盘上的 .segment 读出来后必须已被 sanitize
    @Test func segment_on_disk_is_sanitized_on_read() throws {
        for slot in Slot.allCases {
            let loaded = try seedRowThenReadStyle(slot, column: #"{"lineSubType":"segment"}"#)
            #expect(loaded??.lineSubType == .straight, "\(slot.table)")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "ios/Contracts" && swift test --filter PendingDefaultStyleColumnTests 2>&1 | tail -20
```
Expected: 编译失败（`DrawingDefaultStyleColumn` 不存在）

- [ ] **Step 3: 实现共用解码器**

```swift
// DrawingDefaultStyleColumn.swift
import Foundation
import KlineTrainerContracts

/// `drawing_default_style` 列的**唯一**编解码点。两个 pending repo 各调它一次（守卫 G7 钉死）。
///
/// ⚠️ **绝不 throw**（D92）：本列存的是**装饰性偏好**，它的一个坏字节**不得**让整局训练存档打不开。
///    这与 `settings` 表对财务键「malformed → .dbCorrupted」的策略**刻意不对称** —— 别为了"一致"改成抛。
/// ⚠️ 失败有**三类**，逐字段各自兜住：键缺失 / 值不是合法枚举 / **值的 JSON 类型就不对**。
///    故每个字段各自 `try?`，**不得**把五个字段包在同一个 `try` 里。
enum DrawingDefaultStyleColumn {

    static func encode(_ s: DrawingDefaultStyle?) -> String? {
        guard let s else { return nil }
        guard let data = try? JSONEncoder().encode(s) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// nil = 列为 NULL / 无任何可用内容。**任何解码失败都只影响对应字段**。
    static func decode(_ raw: String?) -> DrawingDefaultStyle? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return DrawingDefaultStyle().sanitized(for: .horizontal) }   // 整段坏 → 全量回落

        var s = DrawingDefaultStyle()
        if let v = obj["lineSubType"] as? String, let e = LineSubType(rawValue: v)   { s.lineSubType = e }
        if let v = obj["lineStyle"]   as? String, let e = LineStyle(rawValue: v)     { s.lineStyle = e }
        if let v = obj["thickness"]   as? Int                                        { s.thickness = v }
        if let v = obj["colorToken"]  as? String, let e = DrawingColorToken(rawValue: v) { s.colorToken = e }
        if let v = obj["labelMode"]   as? String, let e = LabelMode(rawValue: v)     { s.labelMode = e }
        // D93：解码边界即 sanitize —— 让「一个坏默认被读进内存」从构造上不可能。
        return s.sanitized(for: .horizontal)
    }
}
```

> 用 `JSONSerialization` 而非 `Decoder`：**每个字段的类型不匹配天然表现为 `as?` 失败**（回落），
> 而 `decodeIfPresent(Int.self)` 遇到 `"fat"` 会**抛**。这是本文件不用合成 `Codable` 的全部理由。

- [ ] **Step 4: 两个 repo 各接一次**

`PendingTrainingRepositoryImpl.savePending`：INSERT 的列清单末尾加 `, drawing_default_style`，
`VALUES` 加一个 `?`，arguments 末尾加：
```swift
                DrawingDefaultStyleColumn.encode(p.drawingDefaultStyle)
```
`loadPending` 的 `return PendingTraining(` 里加：
```swift
            drawingDefaultStyle: DrawingDefaultStyleColumn.decode(row["drawing_default_style"])
```
`PendingReplayRepositoryImpl` 的 `saveReplay` / `loadReplay` **逐条重复同样四处改动**（列清单 / 占位符 / arguments / 构造器）。

- [ ] **Step 5: 跑测试确认通过 + 全量**

```bash
cd "ios/Contracts" && swift test --filter PendingDefaultStyleColumnTests 2>&1 | tail -5
cd "ios/Contracts" && (set -o pipefail; swift test 2>&1 | tail -3)
```

- [ ] **Step 6: 守卫 G7 + 变异（M2 / M3 / M4 / M4b / M4c / M15）**

G7：`DrawingDefaultStyleColumn.decode` 在 `Sources/` 里**恰好 2 个调用点**，分别在两个 repo impl 内。

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M2 | INSERT 里去掉该列 | **`repo_roundtrip_preserves_all_five_fields`**（走真写入路径那条）。⚠️ **不是** `seedRowThenReadStyle` 系列 —— 那些 helper 自己会 raw UPDATE 写该列，对写路径**零判别力**（codex plan-P-R2 medium） |
| M3 | `decode` 恒返回 nil | 往返档 |
| M4 | `decode` 换成 `JSONDecoder().decode(DrawingDefaultStyle.self, …)` | T4 / T5 / T5b |
| M4b | 每个字段的 `as?` 换成强制解包 | T5b |
| M4c | **只**保留 `colorToken` 的容错、其余四个改成强制 | T4 的另外三条（`colorToken` 那条**仍绿**） |
| **M4d** | 任一字段类型不匹配时**整份丢回出厂**（而非逐字段回落） | **只有 T5b** 红 —— 专证「只断言没抛」是假绿（codex plan-P-R1 medium） |
| M15 | replay 的 `loadReplay` 改成直接 `JSONDecoder().decode` | **只有 replay 侧**的 T4/T5/T5b + G7 |

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/DrawingDefaultStyleColumn.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingDefaultStyleColumnTests.swift
git commit -m "feat(db): 两张 pending 表读写 drawing_default_style，共用容错解码器（D92/D93/D100）"
```

---

## Task 6: 写入 ×2 · replay clean-skip · 读回种子 ×2

**Files:**
- Modify: `…/TrainingEngine/TrainingSessionCoordinator.swift:56`（`replayBaseline` 元组）、`:207 / :588 / :942`（三处基线捕获）、`:611-621`（clean-skip）、`:623`（replay 写）、`:650`（normal 写）、`:294+`（resumePending 种子）、`:851+`（resumePendingReplay 种子）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/CoordinatorDefaultStylePersistTests.swift`（新建）⚠️ **在 Persistence target，不在 Contracts** —— coordinator 的真-DB 装配范式在那边（`CoordinatorLossyPreserveTests` / `CoordinatorCapitalIntegrationTests`）

**Interfaces:**
- Consumes: `PendingTraining.drawingDefaultStyle` / `PendingReplay.drawingDefaultStyle`（Task 2）
- Produces: 无新公共 API（`setDefaultStyle` 仍 internal）

- [ ] **Step 1: 写失败测试**

**Step 1a：先把 harness 抄过来（不要自己造）。**
打开 `ios/Contracts/Tests/KlineTrainerPersistenceTests/CoordinatorLossyPreserveTests.swift`，
**原样复制**它的三件套到新文件：`makeFreshDB()`（`:35-38`）、`static func candles(m3Count:)`（`:41-53`）、
以及紧随其后的 `makeCoordinator` 装配（它自述「镜像 `CoordinatorCapitalIntegrationTests.makeCoordinator`：
真 `DefaultAppDB` 作 repos + `PreviewTrainingSetDBFactory` 供 candles；m3Count=8 → maxTick=7」）。
⚠️ **抄，不要改几何参数** —— `m3Count=8` 与 maxTick 的对应关系是既有测试共享的前提。

**Step 1b：写下面这些失败测试。**

```swift
// CoordinatorDefaultStylePersistTests.swift
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerContracts
@testable import KlineTrainerPersistence

#if DEBUG
@MainActor
@Suite("Coordinator：本局默认的写入 / clean-skip / 种子")
struct CoordinatorDefaultStylePersistTests {

    // ← 此处粘贴 Step 1a 抄来的 makeFreshDB / candles / makeCoordinator

    private func nonDefaultStyle() -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash3; s.thickness = 4
        s.colorToken = .cyan; s.labelMode = .right
        return s
    }

    /// T10：`saveProgress` 的写入载荷里**带着**本局默认（值传递）。
    /// ⚠️ 它**不是** D94 的证据 —— D94 是 `TrainingView` 的 `.onChange`，host 够不着，靠守卫 G6。
    @Test func saveProgress_payload_carries_default_style() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = try makeCoordinator(db: db)
        let engine = try await coordinator.startNewNormalSession()
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)
        try await coordinator.saveProgress(engine: engine)
        let back = try db.loadPending()
        #expect(back?.drawingDefaultStyle == s)
    }

    /// T11：**fresh replay 只改默认** → `saveReplay` 确实写了（clean-skip 未跳过）。
    /// clean-skip 的**唯一**守门：tick/ops/drawingsSig/upper/lower 五个旧分量一个没变，
    /// 少了第六个分量就会被整条跳过、槽里什么都没有。
    @Test func fresh_replay_default_only_change_is_not_clean_skipped() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = try makeCoordinator(db: db)
        let recordId = try seedFinishedRecord(db: db)          // 见 Step 1c
        let engine = try await coordinator.replay(recordId: recordId)
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)               // 只改默认：其余五个分量一个没动
        try await coordinator.saveProgress(engine: engine)
        #expect(try db.loadReplay()?.drawingDefaultStyle == s, "clean-skip 把「只改默认」整条跳过了")
    }

    /// T13：normal 断点续训继承
    @Test func resume_normal_seeds_default_style() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = try makeCoordinator(db: db)
        let engine = try await coordinator.startNewNormalSession()
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)
        try await coordinator.saveProgress(engine: engine)
        let resumed = try #require(try await makeCoordinator(db: db).resumePending())
        #expect(resumed.drawingSession.defaultStyle == s)
    }

    /// T12：replay 断点续局继承
    @Test func resume_replay_seeds_default_style() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = try makeCoordinator(db: db)
        let recordId = try seedFinishedRecord(db: db)
        let engine = try await coordinator.replay(recordId: recordId)
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)
        try await coordinator.saveProgress(engine: engine)
        let resumed = try #require(try await makeCoordinator(db: db).resumePendingReplay(recordId: recordId))
        #expect(resumed.drawingSession.defaultStyle == s)
    }

    /// T14：**fresh 会话不种** —— 新局必须回落出厂值（用户 2026-08-13 裁决）
    @Test func fresh_session_does_not_seed() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c1 = try makeCoordinator(db: db)
        let e1 = try await c1.startNewNormalSession()
        e1.drawingSession.setDefaultStyle(nonDefaultStyle())
        try await c1.saveProgress(engine: e1)
        // 结束本局 → 开新局：不得继承
        try db.clearPending()
        let e2 = try await makeCoordinator(db: db).startNewNormalSession()
        #expect(e2.drawingSession.defaultStyle == DrawingDefaultStyle())
    }
}
#endif
```

**Step 1c：`seedFinishedRecord(db:)`** —— replay 需要一条已完成记录。
**不要自己编**：`CoordinatorLossyPreserveTests` 里已有同用途的种记录写法（它跑 `resumePendingReplay` 前也得先有 record），
**原样复制**过来并按需改名。若那里用的是别的名字，以那边的实现为准。

> ⚠️ 上面每条测试用到的 `coordinator.saveProgress(engine:)` / `startNewNormalSession()` / `replay(recordId:)` /
> `resumePending()` / `resumePendingReplay(recordId:)` **签名以源码为准**（`TrainingSessionCoordinator.swift`）。
> 抄 harness 时一并核对，**不匹配就以源码改测试，不要改源码去迁就测试**。

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "ios/Contracts" && swift test --filter CoordinatorDefaultStylePersistTests 2>&1 | tail -20
```

- [ ] **Step 3: 两处写入**

`:623` 的 `PendingReplay(` 与 `:650` 的 `PendingTraining(` 各加一个参数：
```swift
            drawingDefaultStyle: engine.drawingSession.defaultStyle,
```
（**取活值、不取快照**，与该函数内其它字段同一写法。）

- [ ] **Step 4: clean-skip 加第六分量**

`:56` 的元组类型加一项：
```swift
    @ObservationIgnored private var replayBaseline: (tick: Int, ops: Int, drawingsSig: String,
                                                     upper: Period, lower: Period,
                                                     defaultStyle: DrawingDefaultStyle)?
```
`:207 / :588 / :942` **三处捕获全部**在末尾加 `engine.drawingSession.defaultStyle`。
`:611-621` 的合取末尾加：
```swift
               base.defaultStyle == engine.drawingSession.defaultStyle,
```

> ⚠️ **三处捕获少改一处就是半个 bug**：`:55` 的既有注释记录着同形状的旧 bug（当初漏把 periods 纳入比较）。

- [ ] **Step 5: 两处种子**

`resumePending()` 在 `activeEngine = engine` **之前**加：
```swift
            if let s = pending.drawingDefaultStyle { engine.drawingSession.setDefaultStyle(s) }
```
`resumePendingReplay()` 在对应位置加同样一句（取 `pending.drawingDefaultStyle`）。
**fresh 会话（`startNewNormalSession` / 从头 `replay` / `review`）一律不加** —— 新局必须回落。

- [ ] **Step 6: 跑测试 + 全量**

```bash
cd "ios/Contracts" && swift test --filter CoordinatorDefaultStylePersistTests 2>&1 | tail -5
cd "ios/Contracts" && (set -o pipefail; swift test 2>&1 | tail -3)
```

- [ ] **Step 7: 守卫 G1 / G3 + 变异（M7 部分 / M8 / M9 / M10 / M11）**

- **G1**：`setDefaultStyle` 在 `Sources/` 里**恰好 3 个调用点**（`DrawingEditRouter` + 两处 resume）。
- **G3**：`replayBaseline` 的元组构造点**恰好 3 处**且**都含 `defaultStyle`**。

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M8 | `replayBaseline` 去掉 `defaultStyle` 分量 | **只有 T11** |
| M9 | 删掉 `resumePending` 的种子 | **只有 T13** |
| M10 | 删掉 `resumePendingReplay` 的种子 | **只有 T12** |
| M11 | 把种子挪到 fresh 会话的公共构造路径 | **只有 T14** |

- [ ] **Step 8: 提交**

```bash
# ⚠️ 测试在 **KlineTrainerPersistenceTests**（真-DB coordinator 装配在那边），不是 Contracts
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/CoordinatorDefaultStylePersistTests.swift
git commit -m "feat(coordinator): 本局默认写入两处存档 + clean-skip 纳入 + resume 两处种子（D94-D96）"
git status --short          # 必须为空
```

---

## Task 7: autosave 触发 + 视图层三条守卫

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift:368` 之后
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift`（追加 G4 / G4b / G4c / G6）

- [ ] **Step 1: 写失败守卫（G6 / G4b / G4c）**

```swift
// 共用小工具：从剥过注释/字面量的源码里，**按大括号配对**取出某个修饰符的闭包体。
// 为什么必须这么做：两条 `.onChange` 都在同一个文件里，任何「A 出现过 + B 出现过」式的
// 分离 contains 都会被**另一条**满足（codex plan-P-R1 high①：既有的 drawingsRevision
// 那条已经含 `lifecycle.autosave(immediate: true)`）。
private func closureBody(after needle: String, in src: String) throws -> String {
    guard let head = src.range(of: needle) else {
        Issue.record("未找到 \(needle)"); return ""      // 锚点失效必须报错，不得静默返回空
    }
    guard let open = src.range(of: "{", range: head.upperBound..<src.endIndex) else {
        Issue.record("\(needle) 之后没有 `{`"); return ""
    }
    var depth = 0
    var i = open.lowerBound
    while i < src.endIndex {
        if src[i] == "{" { depth += 1 }
        if src[i] == "}" { depth -= 1; if depth == 0 { return String(src[open.upperBound..<i]) } }
        i = src.index(after: i)
    }
    Issue.record("\(needle) 的闭包大括号未配对"); return ""
}

/// G6：D94 的**唯一**守门 —— host 够不着 TrainingView（UIKit-gated），行为测试受阻于
/// 本仓已记录的平台限制（DrawingLayoutInvariantTests:9-28：四条路三条死）。
/// ⚠️ **必须断言「那一条」闭包体内**有 autosave，不能分开判两个子串
///    （codex plan-P-R1 high①：分开判时，一个**空闭包**照样全绿）。
@Test func training_view_default_style_onchange_body_calls_autosave() throws {
    let src = try SourceGuardScanner.strippedSource(of: "UI/TrainingView.swift")
    let body = try closureBody(after: "onChange(of: engine.drawingSession.defaultStyle)", in: src)
    #expect(body.contains("lifecycle.autosave(immediate: true)"),
            "本局默认的 onChange 闭包体内没有调 autosave（D94）——空闭包也会让旧版 G6 变绿")
}

/// G6 的**双向自检**：喂一个「有 onChange 但闭包为空」的样本必须**不**满足
@Test func g6_rejects_empty_onchange_body() throws {
    let fake = ".onChange(of: engine.drawingsRevision) { _, _ in lifecycle.autosave(immediate: true) }\n"
             + ".onChange(of: engine.drawingSession.defaultStyle) { _, _ in }"
    let body = try closureBody(after: "onChange(of: engine.drawingSession.defaultStyle)", in: fake)
    #expect(!body.contains("lifecycle.autosave"), "自检失败：空闭包竟被判为合格")
}

/// 取 `private var X: Bool { <RHS> }` 的 RHS，压掉所有连续空白。
private func definitionRHS(of name: String, in src: String) throws -> String {
    let body = try closureBody(after: "var \(name): Bool", in: src)
    return body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// G4b：复盘排除依赖的是**整条合取式**。
/// ⚠️ **不能用 `contains`**（codex plan-P-R1 high②）：`… && typeRowExpanded || isReview`
///    仍然包含原子串、照样绿。改为取出定义式右侧、**归一化空白后精确相等**。
@Test func style_panel_visibility_predicate_is_exactly_the_three_way_conjunction() throws {
    let src = try SourceGuardScanner.strippedSource(of: "UI/TrainingView.swift")
    let rhs = try definitionRHS(of: "stylePanelWillBeVisible", in: src)
    #expect(rhs == "showsTradeButtons && isDrawingActive && typeRowExpanded",
            "stylePanelWillBeVisible 的定义式被改动了，D90 的复盘排除失效，实测：\(rhs)")
}

/// G4b 的**双向自检**：放宽后的谓词必须被判不合格
@Test func g4b_rejects_broadened_predicate() throws {
    let fake = "private var stylePanelWillBeVisible: Bool { showsTradeButtons && isDrawingActive && typeRowExpanded || isReview }"
    let rhs = try definitionRHS(of: "stylePanelWillBeVisible", in: fake)
    #expect(rhs != "showsTradeButtons && isDrawingActive && typeRowExpanded")
}

/// G4c：样式面板挂载点在 `Sources/` 里**恰好 1 处**（防「另开一条路径」绕过 G4/G4b）。
/// ⚠️ 上一稿这里是**空函数体** —— 编译通过、恒绿的 no-op（codex plan-P-R1 high②）。
@Test func style_panel_has_exactly_one_mount_site() throws {
    let hits = try SourceGuardScanner.countOccurrences(
        pattern: #"DrawingStylePanel\s*\("#,
        inSourcesMatching: { _ in true },
        stripCommentsAndStringLiterals: true)
    #expect(hits == 1, "样式面板挂载点应恰好 1 处，实测 \(hits) —— 多一处 = 有绕过 G4/G4b 的新路径")
}

/// G4c 的**双向自检**：两处挂载的样本必须被数出 2（防「恒返回 1」的计数实现）
@Test func g4c_rejects_second_mount_site() {
    let fake = "DrawingStylePanel(a: 1)\nDrawingStylePanel(b: 2)"
    let n = fake.components(separatedBy: "DrawingStylePanel(").count - 1
    #expect(n == 2)
}
```

> ⚠️ `SourceGuardScanner.strippedSource(of:)` / `countOccurrences(...)` 的**确切签名以
> `ios/Contracts/Tests/KlineTrainerContractsTests/SourceGuardScanner.swift` 为准**：
> 先读它、用它已有的 API 改写上面这些调用，**不要新建第二个扫描器**。
> 若它尚无「按大括号配对取闭包体」的能力，就把上面的 `closureBody` 作为**测试文件内的私有 helper** 保留
> （它不依赖扫描器，只依赖已剥离的源码字符串）。

- [ ] **Step 2: 跑守卫确认失败**

```bash
cd "ios/Contracts" && swift test --filter DrawingInteractionUISourceGuardTests 2>&1 | tail -10
```
Expected: `training_view_wires_default_style_autosave_trigger` FAIL

- [ ] **Step 3: 实现（`TrainingView.swift:370` 之后，紧邻既有那条）**

```swift
        .onChange(of: engine.drawingSession.defaultStyle) { _, _ in
            // D94：本局默认是局内状态，与画线改动同等待遇（旁边那条是 drawingsRevision）。
            // ⚠️ 价值是**收窄崩溃窗口** —— 用户主动退出/切后台已由 scenePhase 的
            //    flushForBackground 覆盖（:357-363），别把本条的作用写夸张。
            lifecycle.autosave(immediate: true)
        }
```

- [ ] **Step 4: 跑守卫 + Catalyst 门**

```bash
cd "ios/Contracts" && swift test --filter DrawingInteractionUISourceGuardTests 2>&1 | tail -5
cd "/Users/maziming/Coding/Prj_Kline trainer" && (set -o pipefail; xcodebuild test \
  -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' \
  2>&1 | tee /tmp/catalyst.log | tail -5)
grep -c "Test Case .* passed" /tmp/catalyst.log    # 判绿读执行量，不读 TEST SUCCEEDED
```

- [ ] **Step 5: 变异 M7 / M7b / M2c / M2d**

| 变异 | 改法 | 只应变红 |
|---|---|---|
| M7 | 删掉 Step 3 那条 `.onChange` | **只有 G6**（T10 **不得**红 —— 它对视图触发零判别力，这正是 G6 存在的理由） |
| **M7b** | `.onChange` **留着但闭包体清空** `{ _, _ in }` | **只有 G6** —— 专证「分离两个 `contains` 的旧写法是假绿」（codex plan-P-R1 high①） |
| **M2c** | `stylePanelWillBeVisible` 改成 `… && typeRowExpanded \|\| isReview`（放宽） | **只有 G4b** —— 专证 `contains` 挡不住放宽（high②） |
| **M2d** | 再加一处 `DrawingStylePanel(` 挂载 | **只有 G4c** —— 专证空函数体的旧写法是恒绿 no-op（high②） |

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift
git commit -m "feat(ui): 本局默认改动即触发 autosave + 视图层守卫 G4b/G4c/G6（D94/D90）"
```

---

## Task 8: spike（可选）· 三门齐跑 · 交付前检查

- [ ] **Step 1: D94 行为证据 spike（成则加，不成则如实记录）**

把 `TrainingView` 的**两条** autosave 触发抽成一个**纯 SwiftUI `ViewModifier`**（两条一起抽，否则会出现「两条触发分居两处」的漂移），再用 `ImageRenderer` + `drainAutosaveForTesting()` 在最小纯 SwiftUI 宿主里验证 `.onChange` 真的触发。
**跑通** → 加进必测，M7 的判绿对象改为它；**跑不通** → 在 PR 描述如实写「D94 只有结构证据，行为证据受阻于 `DrawingLayoutInvariantTests:9-28` 记录的平台限制」。

- [ ] **Step 2: 三门齐跑并记录数字**

```bash
cd "ios/Contracts" && (set -o pipefail; swift test 2>&1 | tail -3)                       # host
cd "/Users/maziming/Coding/Prj_Kline trainer" && bash scripts/check_app_schema_drift.sh   # drift
cd backend && python3 -m pytest tests/test_qmt_pilot_db.py -q 2>&1 | tail -3              # backend
```

- [ ] **Step 3: 交付前检查单**

- [ ] 变异表**每一条**都关门看红过，PR 描述里记录了「红的是哪个测试名」+ 恢复后重新变绿
- [ ] PR 描述复述了 spec §12 的 **override 边界**
- [ ] PR 描述写明 **bump 后 QMT pilot 库须 `--reset` 重建**（闸门按设计工作、非回归）
- [ ] PR 描述写明 **m01 矩阵在本片之前就已漂移**（停在 `0003`，代码已到 `0009`），本片只负责把自己这次做对
- [ ] 进度 memory 记「**spec override 收口，未 approve**」，**不得记 ✅**
- [ ] **整支 codex 评审已跑**（override 只覆盖 spec 阶段，不覆盖代码）
- [ ] 真机验收 9 条已跑；#9（旧版存档）若装不出，**如实标「无法验证」，不得打勾**
