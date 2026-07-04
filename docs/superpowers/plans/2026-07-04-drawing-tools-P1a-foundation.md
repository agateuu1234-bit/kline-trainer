# 画线工具扩充 P1a（契约地基）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `DrawingObject` 契约与持久层一次性扩到画线工具扩充所需的全字段（身份/样式/文本/period），并把复盘存档 JSON 形状、跨层防碰撞身份、有损容错解码、迁移全部定死——纯契约/持久层，零 UI。

**Architecture:** 附加式扩 `DrawingObject`（自定义 Codable + `decodeIfPresent` 兜底，沿 `revealTick` 先例）；新增支撑枚举与 `DrawingID`；`drawings` 表迁移 `0009` 加 `style_json`+`draw_uuid`（回填+校验+UNIQUE）；复盘 `working_drawings/saved_drawings` 列形状固定为容错 wrapper `{drawings,hiddenIds}`；所有画线数组持久化边界用有损逐元素解码器（跳过坏条但字节级保真回写）。全部 host `swift test` + Mac Catalyst 两闸门守护，零运行期 UI。

**Tech Stack:** Swift 6 / Swift Testing（`@Test`/`#expect`）+ XCTest（既有持久化测试）/ GRDB 6.29（`DatabaseMigrator`）/ Foundation `JSONDecoder`。

## Global Constraints

（每个 Task 的要求都隐含包含本节；数值逐字对齐 spec `docs/superpowers/specs/2026-07-04-drawing-tools-expansion-design.md`）

- **CONTRACT_VERSION `"1.10"` → `"1.11"`**（本 P1a 落地；m01 §A 类"改既有语义"，连带 CODEOWNERS approve 门）。
- **迁移 `0009` 只走 migration**，`PRAGMA user_version = 7`；**绝不改 `AppDBMigrations.v1_4_baselineDDL` 或 `ios/sql/app_schema_v1.sql`**（v1.4 冻结基线，drift-checked——沿 0006/0007/0008 先例）。
- **`draw_uuid`**：迁移回填所有旧行 `legacy-<record_id>-<id>`；**回填后校验无 NULL、无重复，否则迁移抛错**；建 `UNIQUE INDEX`（D20）。
- **复盘 canonical 磁盘 JSON schema（全阶段唯一，禁改 key/形状）** = `{ "drawings": [DrawingObject], "hiddenIds": [DrawingID] }`；in-memory `reviewDrawings`/`hiddenOriginalIds` 经显式 `CodingKeys` 映射；解码容错裸 `[DrawingObject]` 数组（→ `hiddenIds=[]`）| wrapper（D14）。
- **有损 ≠ 丢数据（D21，全达成于 P1a；Z1）**：所有画线数组边界（`pending_*.drawings` / review wrapper 的 `drawings`）解码时坏/未知条只跳过、不整组失败。**P1a 达成 D21 全部**：① 解码永不崩 + ② repo `load→save` 往返无损 + ③ **coordinator 所有 save 路径（autosave / resume-save / commit）字节保真**（Task 12 引擎携带 `lossy`、`reconciled` 保未识别条原位）。→ **P1a 自洽安全**（bump 1.11 站得住、单独发版也不丢「未来版本写的画线条」；公开发布 [[project_app_public_release_intent]]）。
- **`DrawingID` 跨层防碰撞（D13/D16）**：新画线 = `UUID().uuidString`；原训练线 = `draw_uuid`（`legacy-<record_id>-<id>` 或后续新建时铸的 UUID）；旧 JSON blob 无 id 的元素在数组解码层回填 `legacy-idx-<index>`（命名空间唯一）。**禁进程内单调整数、禁裸数组下标整数**。
- **两闸门**：平台无关值类型/Codable/几何/迁移逻辑走 host `swift test`（Swift Testing + XCTest 两框架都要全绿）；DB 迁移走 `KlineTrainerPersistenceTests`（XCTest + GRDB in-memory）。UIKit 层本阶段无。
- **零 UI**：本阶段新字段无 UI 消费者，全靠 Codable round-trip + 迁移 + 持久化往返测覆盖（Wave-0 契约先行同款）。

---

## 文件结构图

**新建：**
- `ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift` — 支撑枚举 `LineSubType`/`LineStyle`/`DrawingColorToken`/`LabelMode`/`TextForm` + `DrawingID` typealias。（一处职责：画线样式/身份的值类型词汇表。）
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/LossyDrawingArray.swift` — 有损逐元素解码 + 保真回写编解码器（`LossyDrawingArray`）。（一处职责：画线数组持久化边界的容错编解码。）
- `ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveWrapper.swift` — 复盘 canonical wrapper Codable（`{drawings,hiddenIds}`）+ 容错解码。（一处职责：复盘存档磁盘形状。）
- `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift` — 枚举/DrawingObject/lossy/wrapper/ReviewNetChange host 测试。
- `ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0009Tests.swift` — 迁移 0009 + RecordRepository draw_uuid/style_json + review wrapper 落库 XCTest。

**修改：**
- `Models/Models.swift:37-39`（`DrawingToolType` 扩 11）+ `:209-248`（`DrawingObject` 加字段+Codable）+ `:7`（`CONTRACT_VERSION`）。
- `Persistence/ReviewArchiveRepository.swift`（`ReviewWorking`/`ReviewArchive` 加 `hiddenOriginalIds`；`ReviewNetChange.changed` 改按 id + hiddenIds）。
- `KlineTrainerPersistence/Internal/AppDBMigrations.swift:205-208 后`（加 `0009` migration）。
- `KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift:50-58`（drawings INSERT 加 draw_uuid+style_json）+ `:163-173`（`drawingFromRow` 读 draw_uuid+style_json）。
- `KlineTrainerPersistence/Internal/ReviewArchiveRepositoryImpl.swift`（working/saved 存取改经 wrapper）。
- `Persistence/LossyDrawingArray.swift`（Task 12 加 `reconciled(currentKnown:)` 合并器）+ `TrainingEngine/TrainingEngine.swift`（Task 12 加 `loadedDrawingsLossy`/`loadedReviewLossy` 携带 + `setReviewLossy`）+ `TrainingEngine/TrainingSessionCoordinator.swift`（Task 12 load 灌 lossy / save 用 `reconciled` 重发）。
- `TrainingEngine/TrainingEngine.swift:996-1005`（`routeDrawingCommit` 全字段 copy-with-revealTick）。

---

## Task 1: 支撑枚举 + DrawingID

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Produces:
  - `public typealias DrawingID = String`
  - `public enum LineSubType: String, Codable, Equatable, Sendable, CaseIterable { case straight, ray, segment }`
  - `public enum LineStyle: String, Codable, Equatable, Sendable, CaseIterable { case solid, dash1, dash2, dash3, dash4 }`
  - `public enum DrawingColorToken: String, Codable, Equatable, Sendable, CaseIterable { case red, orange, yellow, green, cyan, blue, purple, black, white }`
  - `public enum LabelMode: String, Codable, Equatable, Sendable, CaseIterable { case hidden, show, left, right }`
  - `public enum TextForm: String, Codable, Equatable, Sendable, CaseIterable { case borderTransparent, borderFilled, plain }`

- [ ] **Step 1: Write the failing test**

在 `DrawingModelP1aTests.swift` 新建文件：

```swift
import Testing
@testable import KlineTrainerContracts

@Suite("Drawing P1a — 支撑枚举")
struct DrawingEnumsTests {
    @Test("五枚举 rawValue 稳定 + CaseIterable 计数")
    func rawValuesStable() {
        #expect(LineSubType.allCases.map(\.rawValue) == ["straight", "ray", "segment"])
        #expect(LineStyle.allCases.map(\.rawValue) == ["solid", "dash1", "dash2", "dash3", "dash4"])
        #expect(DrawingColorToken.allCases.map(\.rawValue)
            == ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "black", "white"])
        #expect(LabelMode.allCases.map(\.rawValue) == ["hidden", "show", "left", "right"])
        #expect(TextForm.allCases.map(\.rawValue) == ["borderTransparent", "borderFilled", "plain"])
    }

    @Test("DrawingID 是 String 别名")
    func drawingIdIsString() {
        let id: DrawingID = "gen-abc"
        #expect(id == "gen-abc")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter DrawingEnumsTests`
Expected: FAIL — `cannot find 'LineSubType' in scope`。

- [ ] **Step 3: Write minimal implementation**

新建 `DrawingEnums.swift`：

```swift
// 画线样式/身份的值类型词汇表（画线工具扩充 P1a）。全部平台无关、host 可测。
import Foundation

public typealias DrawingID = String

public enum LineSubType: String, Codable, Equatable, Sendable, CaseIterable {
    case straight, ray, segment
}

public enum LineStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case solid, dash1, dash2, dash3, dash4
}

public enum DrawingColorToken: String, Codable, Equatable, Sendable, CaseIterable {
    case red, orange, yellow, green, cyan, blue, purple, black, white
}

public enum LabelMode: String, Codable, Equatable, Sendable, CaseIterable {
    case hidden, show, left, right
}

public enum TextForm: String, Codable, Equatable, Sendable, CaseIterable {
    case borderTransparent, borderFilled, plain
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter DrawingEnumsTests`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): 支撑枚举 LineSubType/LineStyle/DrawingColorToken/LabelMode/TextForm + DrawingID"
```

---

## Task 2: DrawingToolType 扩为 11

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:37-39`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Produces: `DrawingToolType` 新增 `channel, polyline, fib, timeRuler, rect, text`；保留 `ray, time`（legacy，容忍历史解码）；`horizontal, trend, golden, wave, cycle` 不变。

- [ ] **Step 1: Write the failing test**

在 `DrawingModelP1aTests.swift` 追加：

```swift
@Suite("Drawing P1a — DrawingToolType 11 工具")
struct DrawingToolTypeExpansionTests {
    @Test("新增 6 工具 case + 保留 legacy ray/time 可解码")
    func elevenPlusLegacy() throws {
        // 11 目标工具都能从 rawValue 构造
        for raw in ["horizontal", "trend", "channel", "polyline", "golden",
                    "wave", "cycle", "fib", "timeRuler", "text", "rect"] {
            #expect(DrawingToolType(rawValue: raw) != nil, "缺工具 \(raw)")
        }
        // legacy 两 case 仍可解码（历史 blob 兼容）
        #expect(DrawingToolType(rawValue: "ray") == .ray)
        #expect(DrawingToolType(rawValue: "time") == .time)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter DrawingToolTypeExpansionTests`
Expected: FAIL — `DrawingToolType(rawValue: "channel")` 返回 nil（断言失败）。

- [ ] **Step 3: Write minimal implementation**

`Models.swift:37-39` 替换：

```swift
public enum DrawingToolType: String, Codable, Equatable, Sendable {
    // 目标 11 工具
    case horizontal, trend, channel, polyline, golden, wave, cycle, fib, timeRuler, rect, text
    // legacy（历史 blob 容忍解码；ray 已下沉为线型子类、time 语义歧义——见 spec §4.1/D2）
    case ray, time
}
```

> 说明：`ray`/`time` 保留是为历史 blob 不 crash（D9）。生产落地数据仅 `.horizontal`。未知/废弃工具的整数组容错在 Task 5 的有损解码层。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter DrawingToolTypeExpansionTests`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): DrawingToolType 扩为 11 工具 + 保留 legacy ray/time"
```

---

## Task 3: DrawingObject 全字段 + 自定义 Codable

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:209-248`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Consumes: Task 1 枚举 + `DrawingID`；Task 2 `DrawingToolType`。
- Produces（新 `DrawingObject`，字段顺序即持久顺序）：
  - `id: DrawingID`（默认 init 生成 `UUID().uuidString`）
  - `toolType: DrawingToolType`, `anchors: [DrawingAnchor]`
  - `period: Period`（渲染绑定周期，§10；取 `anchors.first?.period`，无锚 fallback `.daily`）
  - `lineSubType: LineSubType`（默认 `.straight`）
  - `lineStyle: LineStyle`（默认 `.solid`）
  - `thickness: Int`（1…5，默认 1）
  - `colorToken: DrawingColorToken`（默认 `.orange`）
  - `labelMode: LabelMode`（默认 `.hidden`）
  - `locked: Bool`（默认 false）
  - `text: String`（默认 ""）, `fontSize: Int`（默认 14）, `textColorToken: DrawingColorToken`（默认 `.orange`）, `textForm: TextForm`（默认 `.plain`）, `tailAnchor: DrawingAnchor?`（默认 nil）
  - `isExtended: Bool`, `panelPosition: Int`, `revealTick: Int`（保留）
  - `init(id: DrawingID = UUID().uuidString, toolType:anchors:isExtended:panelPosition:revealTick: = 0, period: = nil, lineSubType: = .straight, lineStyle: = .solid, thickness: = 1, colorToken: = .orange, labelMode: = .hidden, locked: = false, text: = "", fontSize: = 14, textColorToken: = .orange, textForm: = .plain, tailAnchor: = nil)`

- [ ] **Step 1: Write the failing test**

追加：

```swift
@Suite("Drawing P1a — DrawingObject 全字段 Codable")
struct DrawingObjectCodableTests {
    private func sampleAnchor() -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.5)
    }

    @Test("全字段编码→解码往返一致")
    func fullRoundTrip() throws {
        let d = DrawingObject(
            id: "gen-1", toolType: .trend, anchors: [sampleAnchor(), sampleAnchor()],
            isExtended: true, panelPosition: 1, revealTick: 42,
            period: .m60, lineSubType: .segment, lineStyle: .dash2, thickness: 4,
            colorToken: .blue, labelMode: .right, locked: true,
            text: "颈线", fontSize: 20, textColorToken: .red, textForm: .borderFilled,
            tailAnchor: sampleAnchor())
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(back == d)
    }

    @Test("旧 blob（仅 5 字段）解码 → 新字段取语义默认")
    func legacyBlobDefaults() throws {
        // 模拟 #139 时代的 DrawingObject JSON（无新字段）
        let legacy = """
        {"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":2,"price":9.9}],
         "isExtended":true,"panelPosition":0,"revealTick":7}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(DrawingObject.self, from: legacy)
        #expect(d.lineSubType == .ray)          // isExtended:true → .ray（迁移映射）
        #expect(d.lineStyle == .solid)
        #expect(d.thickness == 1)
        #expect(d.colorToken == .orange)
        #expect(d.labelMode == .hidden)
        #expect(d.locked == false)
        #expect(d.text == "")
        #expect(d.tailAnchor == nil)
        #expect(d.period == .m3)                // 取 anchors.first.period
        #expect(d.id.isEmpty == false)          // 无 id → 生成非空
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter DrawingObjectCodableTests`
Expected: FAIL — `DrawingObject` 无 `id`/`period`/… 参数，编译失败。

- [ ] **Step 3: Write minimal implementation**

`Models.swift:209-248` 整体替换：

```swift
public struct DrawingObject: Codable, Equatable, Sendable {
    public let id: DrawingID                 // 跨层防碰撞身份（§4.2/D13/D16）
    public let toolType: DrawingToolType
    public let anchors: [DrawingAnchor]
    public let period: Period                // 渲染绑定周期（§10）
    public let lineSubType: LineSubType
    public let lineStyle: LineStyle
    public let thickness: Int                // 1…5
    public let colorToken: DrawingColorToken
    public let labelMode: LabelMode
    public let locked: Bool
    public let text: String
    public let fontSize: Int
    public let textColorToken: DrawingColorToken
    public let textForm: TextForm
    public let tailAnchor: DrawingAnchor?    // 标注气泡尾巴尖；仅带框两形式有值（§5.10/D11）
    public let isExtended: Bool              // 保留（兼容/派生）
    public let panelPosition: Int            // 保留但不再作渲染绑定（§10）
    /// review-redesign 整改④：提交这条画线时会话所处的全局 tick（= 渐显时机）。
    public let revealTick: Int

    public init(id: DrawingID = UUID().uuidString,
                toolType: DrawingToolType, anchors: [DrawingAnchor],
                isExtended: Bool, panelPosition: Int, revealTick: Int = 0,
                period: Period? = nil,
                lineSubType: LineSubType = .straight, lineStyle: LineStyle = .solid,
                thickness: Int = 1, colorToken: DrawingColorToken = .orange,
                labelMode: LabelMode = .hidden, locked: Bool = false,
                text: String = "", fontSize: Int = 14,
                textColorToken: DrawingColorToken = .orange, textForm: TextForm = .plain,
                tailAnchor: DrawingAnchor? = nil) {
        self.id = id
        self.toolType = toolType
        self.anchors = anchors
        self.period = period ?? anchors.first?.period ?? .daily
        self.lineSubType = lineSubType
        self.lineStyle = lineStyle
        self.thickness = thickness
        self.colorToken = colorToken
        self.labelMode = labelMode
        self.locked = locked
        self.text = text
        self.fontSize = fontSize
        self.textColorToken = textColorToken
        self.textForm = textForm
        self.tailAnchor = tailAnchor
        self.isExtended = isExtended
        self.panelPosition = panelPosition
        self.revealTick = revealTick
    }

    private enum CodingKeys: String, CodingKey {
        case id, toolType, anchors, period, lineSubType, lineStyle, thickness
        case colorToken, labelMode, locked, text, fontSize, textColorToken, textForm, tailAnchor
        case isExtended, panelPosition, revealTick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolType = try c.decode(DrawingToolType.self, forKey: .toolType)
        self.anchors = try c.decode([DrawingAnchor].self, forKey: .anchors)
        self.isExtended = try c.decode(Bool.self, forKey: .isExtended)
        self.panelPosition = try c.decode(Int.self, forKey: .panelPosition)
        self.revealTick = try c.decodeIfPresent(Int.self, forKey: .revealTick) ?? 0
        // 新字段：旧 blob 无 → 语义默认（沿 revealTick 先例）
        self.id = try c.decodeIfPresent(DrawingID.self, forKey: .id) ?? UUID().uuidString
        self.period = try c.decodeIfPresent(Period.self, forKey: .period)
            ?? self.anchors.first?.period ?? .daily
        // isExtended:true → .ray；false → .straight（旧语义迁移，§4.2）
        self.lineSubType = try c.decodeIfPresent(LineSubType.self, forKey: .lineSubType)
            ?? (self.isExtended ? .ray : .straight)
        self.lineStyle = try c.decodeIfPresent(LineStyle.self, forKey: .lineStyle) ?? .solid
        self.thickness = try c.decodeIfPresent(Int.self, forKey: .thickness) ?? 1
        self.colorToken = try c.decodeIfPresent(DrawingColorToken.self, forKey: .colorToken) ?? .orange
        self.labelMode = try c.decodeIfPresent(LabelMode.self, forKey: .labelMode) ?? .hidden
        self.locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 14
        self.textColorToken = try c.decodeIfPresent(DrawingColorToken.self, forKey: .textColorToken) ?? .orange
        self.textForm = try c.decodeIfPresent(TextForm.self, forKey: .textForm) ?? .plain
        self.tailAnchor = try c.decodeIfPresent(DrawingAnchor.self, forKey: .tailAnchor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(toolType, forKey: .toolType)
        try c.encode(anchors, forKey: .anchors)
        try c.encode(period, forKey: .period)
        try c.encode(lineSubType, forKey: .lineSubType)
        try c.encode(lineStyle, forKey: .lineStyle)
        try c.encode(thickness, forKey: .thickness)
        try c.encode(colorToken, forKey: .colorToken)
        try c.encode(labelMode, forKey: .labelMode)
        try c.encode(locked, forKey: .locked)
        try c.encode(text, forKey: .text)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(textColorToken, forKey: .textColorToken)
        try c.encode(textForm, forKey: .textForm)
        try c.encodeIfPresent(tailAnchor, forKey: .tailAnchor)
        try c.encode(isExtended, forKey: .isExtended)
        try c.encode(panelPosition, forKey: .panelPosition)
        try c.encode(revealTick, forKey: .revealTick)
    }
}
```

> ⚠️ 兼容风险：现有构造点（`DrawingToolManager.commit`、既有测试）用旧 5 参 `init(toolType:anchors:isExtended:panelPosition:revealTick:)`——新 init 把这些设为**非默认必填 + 其余全默认**，旧调用**无需改**（`id` 默认生成 UUID）。实施时 `swift build` 若报某调用点歧义，按新签名补默认即可。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter DrawingObjectCodableTests`
Expected: PASS（含 legacy 默认）。再跑全量确保未破坏既有：`cd ios/Contracts && swift test 2>&1 | tail -5` → 0 failures。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): DrawingObject 加 id/period/样式/文本/tailAnchor 全字段 + decodeIfPresent 兜底"
```

---

## Task 4: CONTRACT_VERSION 1.10 → 1.11

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:7`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Produces: `public let CONTRACT_VERSION = "1.11"`

- [ ] **Step 1: Write the failing test**

追加：

```swift
@Suite("Drawing P1a — 契约版本")
struct ContractVersionTests {
    @Test("CONTRACT_VERSION == 1.11")
    func bumped() { #expect(CONTRACT_VERSION == "1.11") }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter ContractVersionTests`
Expected: FAIL — 实际 `"1.10"`。

- [ ] **Step 3: Write minimal implementation**

`Models.swift:7`：`public let CONTRACT_VERSION = "1.10"` → `public let CONTRACT_VERSION = "1.11"`。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter ContractVersionTests` → PASS。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): CONTRACT_VERSION 1.10 -> 1.11"
```

---

## Task 5: 有损逐元素解码 + 保真回写（LossyDrawingArray）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/LossyDrawingArray.swift`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Consumes: Task 3 `DrawingObject`。
- Produces:
  - `enum JSONTopLevelArray { static func rawElementStrings(_ data: Data) -> [String]? }`——**平台无关、host 可测的顶层 JSON 数组切分器**：把数组文本按顶层元素切成各元素的**原始字节文本**（正确处理字符串内转义与嵌套 `{}[]`），非顶层数组 → `nil`。
  - `public enum LossyDrawingElement: Equatable, Sendable { case known(DrawingObject); case unknownRaw(String) }`——**有序**元素（已知条 / 未识别条原始字节文本）。**保序是正确性要求**（codex plan-R2-high：分开存会把未识别条排到已知条之后、改变顺序/图层）。
  - `public struct LossyDrawingArray: Equatable, Sendable`（**不 Codable**——用下面显式 `decode`/`encoded`）
    - `public let elements: [LossyDrawingElement]`（已知/未识别**按原顺序**排列）
    - `public init(elements: [LossyDrawingElement])`
    - `public init(drawings: [DrawingObject])`（便捷：纯已知条，新写入路径）
    - `public var drawings: [DrawingObject]`（按序过滤 known；供 Task 6/7 消费，**名/类型不变**）
    - `public var unknownRaw: [String]`（按序取未识别条原文；诊断/测试用）
  - `public static func decode(_ data: Data) throws -> LossyDrawingArray`（切分器取每元素**原始文本**→各自 failable 解码；成功→`.known`（无 id 回填 `legacy-idx-<index>`）、失败→`.unknownRaw(原文)`（**不重序列化**）；**按原顺序**入 `elements`）
  - `public func encoded() throws -> Data`（**按 `elements` 原顺序**：`.known` `JSONEncoder` 编码 + `.unknownRaw` **原样重发**，以 `,` 拼接包 `[]`——未识别条**字节级保真 + 保序**）

**背景：** 现 `RecordRepositoryImpl.jsonDecode($0, as: [DrawingObject].self)` 是全量解码——一条坏/未知 toolType 整组失败（D21/codex R8-medium）。本类是所有画线数组持久化边界的容错入口。
**保真关键（codex plan-R1-high）：** 未识别条**绝不经 `JSONSerialization` 反/重序列化**（那会改 key 顺序/数字格式 → 老客户端 load+autosave 静默改写未来客户端数据）；改为**切分器捕获原始元素字节文本 + 回写时原样拼接**。

- [ ] **Step 1: Write the failing test**

追加：

```swift
@Suite("Drawing P1a — 有损解码 + 保真回写")
struct LossyDrawingArrayTests {
    @Test("未知 toolType 单条只跳过、不整组失败")
    func skipsUnknownOnly() throws {
        let json = Data(#"[{"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0},{"toolType":"__future_tool__","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}]"#.utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.count == 1)            // 只保 horizontal
        #expect(arr.drawings[0].toolType == .horizontal)
        #expect(arr.unknownRaw.count == 1)          // future_tool 保原文
        #expect(arr.unknownRaw[0].contains("__future_tool__"))
    }

    @Test("保真回写：未识别条逐字节等于原始输入（不只子串）")
    func roundTripBytePerfect() throws {
        // 未来条：特意的 key 顺序（z 在前 a 在后）+ 数字格式 1.0 / 高精度尾数——只有原样保留才能全等。
        let unknownElem = #"{"toolType":"__future__","z_last":1.0,"a_first":"x, ]}\"escaped","p":0.10000000000000001}"#
        let json = Data("[\(unknownElem)]".utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.isEmpty)
        #expect(arr.unknownRaw == [unknownElem])              // 原始文本逐字符保留（未重序列化）
        let out = try arr.encoded()
        #expect(out == json)                                  // 单元素数组 → 逐字节等于原始
        let reparsed = try LossyDrawingArray.decode(out)      // 幂等
        #expect(reparsed.unknownRaw == [unknownElem])
    }

    @Test("已知条 + 未知条混排：已知存活、未知保真、幂等")
    func mixedKnownUnknownIdempotent() throws {
        let unknown = #"{"toolType":"__future__","weird":[1,2,{"x":"]"}]}"#
        let known = #"{"id":"g1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}"#
        let json = Data(("[" + known + "," + unknown + "]").utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.count == 1)
        #expect(arr.drawings[0].id == "g1")
        #expect(arr.unknownRaw.count == 1)
        // 未识别条经切分器 trim 两侧空白后仍应保内部字节（含字符串里的 ']'）
        #expect(arr.unknownRaw[0].contains(#"{"x":"]"}"#))
        // encoded→decode 幂等：已知 1 条 + 未知 1 条
        let r2 = try LossyDrawingArray.decode(try arr.encoded())
        #expect(r2.drawings.count == 1 && r2.unknownRaw.count == 1)
    }

    @Test("保序：[known, unknownFuture, known] 往返后元素顺序逐一保持")
    func preservesElementOrder() throws {
        let kA = #"{"id":"A","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}"#
        let uF = #"{"toolType":"__future__","mid":true}"#
        let kB = #"{"id":"B","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}"#
        let json = Data(("[" + kA + "," + uF + "," + kB + "]").utf8)
        let arr = try LossyDrawingArray.decode(json)
        // elements 有序：第 0=known A、第 1=unknownRaw future、第 2=known B
        guard arr.elements.count == 3,
              case .known(let a) = arr.elements[0],
              case .unknownRaw(let mid) = arr.elements[1],
              case .known(let b) = arr.elements[2] else { Issue.record("顺序错"); return }
        #expect(a.id == "A" && b.id == "B" && mid == uF)
        // 回写后未识别条仍在【中间】（不被排到末尾）
        let out = String(decoding: try arr.encoded(), as: UTF8.self)
        #expect(out.range(of: "__future__")!.lowerBound > out.range(of: "\"A\"")!.lowerBound)
        #expect(out.range(of: "__future__")!.lowerBound < out.range(of: "\"B\"")!.lowerBound)
    }

    @Test("切分器：正确按顶层元素切、忽略字符串内的括号逗号")
    func splitterHandlesNestingAndStrings() throws {
        let data = Data(#"[ {"a":"x,]y","b":[1,2]} , {"c":{"d":"}"}} ]"#.utf8)
        let elems = JSONTopLevelArray.rawElementStrings(data)
        #expect(elems?.count == 2)
        #expect(elems?[0] == #"{"a":"x,]y","b":[1,2]}"#)      // 去两侧空白、内部原样
        #expect(elems?[1] == #"{"c":{"d":"}"}}"#)
        #expect(JSONTopLevelArray.rawElementStrings(Data("[]".utf8)) == [])   // 空数组
        #expect(JSONTopLevelArray.rawElementStrings(Data("{}".utf8)) == nil)  // 非数组 → nil
    }

    @Test("无 id 成功条按下标回填 legacy-idx-<index>")
    func backfillsLegacyIndexId() throws {
        let json = Data(#"[{"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0}]"#.utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings[0].id == "legacy-idx-0")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter LossyDrawingArrayTests`
Expected: FAIL — `cannot find 'LossyDrawingArray'`。

- [ ] **Step 3: Write minimal implementation**

新建 `LossyDrawingArray.swift`：

```swift
// 所有画线数组持久化边界的容错编解码器（画线工具扩充 P1a，D21）。
// 坏/未知 toolType 单条只跳过、不整组失败；未识别条【原始字节级保真】回写，防「读时跳过+全量重写」丢线。
import Foundation

/// 平台无关、host 可测的顶层 JSON 数组切分器：按顶层元素切出各元素【原始字节文本】（去两侧空白、内部原样）。
/// 正确处理字符串内的转义与嵌套 {}[]。非顶层数组 → nil。空数组 → []。
enum JSONTopLevelArray {
    static func rawElementStrings(_ data: Data) -> [String]? {
        let b = [UInt8](data); let n = b.count; var i = 0
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func trimmedEmpty(_ lo: Int, _ hi: Int) -> Bool {   // 槽去空白后是否为空
            var a = lo; while a < hi, isWS(b[a]) { a += 1 }; return a >= hi
        }
        func slice(_ lo: Int, _ hi: Int) -> String {
            var a = lo, z = hi
            while a < z, isWS(b[a]) { a += 1 }
            while z > a, isWS(b[z - 1]) { z -= 1 }
            return String(decoding: b[a..<z], as: UTF8.self)
        }
        func tailAllWS(_ from: Int) -> Bool { var k = from; while k < n, isWS(b[k]) { k += 1 }; return k == n }
        while i < n, isWS(b[i]) { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "[") else { return nil }
        i += 1
        // 空数组：`[` 后（跳空白）即 `]`（尾部须纯空白）
        var j = i; while j < n, isWS(b[j]) { j += 1 }
        if j < n, b[j] == UInt8(ascii: "]") { return tailAllWS(j + 1) ? [] : nil }
        var out: [String] = []
        var depth = 1, inString = false, escaped = false, start = i
        while i < n {
            let c = b[i]
            if inString {
                if escaped { escaped = false }
                else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") { inString = false }
                i += 1; continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true; i += 1
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; i += 1
            case UInt8(ascii: "}"): depth -= 1; i += 1
            case UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 {
                    if trimmedEmpty(start, i) { return nil }        // 尾随逗号/空槽(如 `[x,]`) → 损坏
                    out.append(slice(start, i)); i += 1
                    return tailAllWS(i) ? out : nil                 // 尾部非纯空白(`[valid]]`/`[valid]{junk}`) → 损坏
                }
                i += 1
            case UInt8(ascii: ","):
                if depth == 1 {
                    if trimmedEmpty(start, i) { return nil }        // 前导/连续逗号/纯空白元素(`[,x]`/`[x,,y]`) → 损坏
                    out.append(slice(start, i)); i += 1; start = i
                } else { i += 1 }
            default: i += 1
            }
        }
        return nil   // 未闭合数组
    }
}

/// 有损画线数组的【有序】元素：已知条 或 未识别条（原始字节文本）。保序是正确性要求（codex plan-R2-high）。
public enum LossyDrawingElement: Equatable, Sendable {
    case known(DrawingObject)
    case unknownRaw(String)
}

public struct LossyDrawingArray: Equatable, Sendable {
    public let elements: [LossyDrawingElement]      // 已知/未识别按【原顺序】排列

    public init(elements: [LossyDrawingElement]) { self.elements = elements }
    /// 便捷：纯已知条（新写入路径）。
    public init(drawings: [DrawingObject]) { self.elements = drawings.map { .known($0) } }

    /// 按序过滤已知条（供 Task 6/7 消费，名/类型不变）。
    public var drawings: [DrawingObject] {
        elements.compactMap { if case .known(let d) = $0 { return d } else { return nil } }
    }
    /// 按序取未识别条原文（诊断/测试用）。
    public var unknownRaw: [String] {
        elements.compactMap { if case .unknownRaw(let s) = $0 { return s } else { return nil } }
    }

    public static func decode(_ data: Data) throws -> LossyDrawingArray {
        guard let rawElements = JSONTopLevelArray.rawElementStrings(data) else {
            throw AppError.persistence(.dbCorrupted)
        }
        let decoder = JSONDecoder()
        var elems: [LossyDrawingElement] = []
        for (index, raw) in rawElements.enumerated() {
            if let d = try? decoder.decode(DrawingObject.self, from: Data(raw.utf8)) {
                // 无 id 的成功条按【原下标】回填命名空间唯一 id（D16）
                if d.id.isEmpty {
                    elems.append(.known(DrawingObject(
                        id: "legacy-idx-\(index)", toolType: d.toolType, anchors: d.anchors,
                        isExtended: d.isExtended, panelPosition: d.panelPosition, revealTick: d.revealTick,
                        period: d.period, lineSubType: d.lineSubType, lineStyle: d.lineStyle,
                        thickness: d.thickness, colorToken: d.colorToken, labelMode: d.labelMode,
                        locked: d.locked, text: d.text, fontSize: d.fontSize,
                        textColorToken: d.textColorToken, textForm: d.textForm, tailAnchor: d.tailAnchor)))
                } else {
                    elems.append(.known(d))
                }
            } else {
                elems.append(.unknownRaw(raw))      // 原始文本，字节级保留（【不】重序列化）、【保序】
            }
        }
        return LossyDrawingArray(elements: elems)
    }

    public func encoded() throws -> Data {
        // 按【原顺序】走 elements：.known JSONEncoder 编码、.unknownRaw 原样重发，, 拼接包 []。
        let encoder = JSONEncoder()
        var parts: [String] = []
        for e in elements {
            switch e {
            case .known(let d): parts.append(String(decoding: try encoder.encode(d), as: UTF8.self))
            case .unknownRaw(let s): parts.append(s)
            }
        }
        return Data(("[" + parts.joined(separator: ",") + "]").utf8)
    }
}
```

> 说明：`decode` 里 `d.id.isEmpty` 分支需要 Task 3 的 `init(from:)` 在无 id 时给空串——把 Task 3 的 `?? UUID().uuidString` 改为 `?? ""`，让「按下标回填」在数组层做（顶层单条 DrawingObject 解码时无 index 上下文）。**实施 Task 5 时回改 Task 3 的 `init(from:)`：`self.id = try c.decodeIfPresent(DrawingID.self, forKey: .id) ?? ""`，并把 Task 3 的 legacy 测试 `#expect(d.id.isEmpty == false)` 改为在数组层验证（本 Task 已覆盖）。**

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter LossyDrawingArrayTests` → PASS。
再 `cd ios/Contracts && swift test --filter DrawingObjectCodableTests`（确认 Task 3 微调后仍绿）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/LossyDrawingArray.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): LossyDrawingArray 有损逐元素解码 + 未识别条保真回写 + legacy-idx id 回填"
```

---

## Task 6: 复盘 canonical wrapper（ReviewArchiveWrapper + hiddenOriginalIds）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveWrapper.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveRepository.swift`（`ReviewWorking`/`ReviewArchive` 加 `hiddenOriginalIds`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Consumes: Task 3 `DrawingObject`, Task 5 `LossyDrawingArray`, `DrawingID`。
- Produces:
  - `enum JSONObjectScan { static func rawValueBytes(_ data: Data, key: String) -> String? }`——顶层 JSON 对象按 key 取【原始值字节文本】（去两侧空白、内部字节原样；非对象/找不到→nil）。用于 wrapper 保留 `drawings` 数组值原始字节喂 LossyDrawingArray（**字节保真**，codex plan-R2-high：整体 `JSONSerialization` 反/重序列化会破坏未识别条保真）。
  - `public struct ReviewArchiveWrapper: Equatable, Sendable`
    - `public let lossy: LossyDrawingArray`（有序 known/unknownRaw，保序+保真）
    - `public let hiddenIds: [DrawingID]`
    - `public var drawings: [DrawingObject]`（= `lossy.drawings`；下游 Task 10 消费**不变**）
    - `public init(lossy: LossyDrawingArray, hiddenIds: [DrawingID])`
    - `public init(drawings: [DrawingObject], hiddenIds: [DrawingID])`（便捷：纯已知条，新写入）
    - `public static func decodeColumn(_ json: String) throws -> ReviewArchiveWrapper`（容错：裸数组→`hiddenIds=[]`；wrapper 对象→取 `drawings` 值**原始字节切片**喂 LossyDrawingArray + `hiddenIds`）
    - `public func encodedColumn() throws -> String`（`{"drawings":<lossy.encoded()字节>,"hiddenIds":<编码>}` **直接拼接、不重序列化整体**）
  - `ReviewWorking`：新增 `public let lossy: LossyDrawingArray`（承载**有序 known + unknownRaw**，供 repo save 保真回写）；`drawings` 改为**计算属性** `{ lossy.drawings }`（下游消费不变）；加 `public let hiddenOriginalIds: [DrawingID]`（init 增参默认 `[]`）。**目的：repo load→save 边界无损**——只留 `.drawings` 会在下次 saveWorking 丢 unknownRaw（codex plan-R4-high①）。
  - `ReviewArchive`：新增 `public let workingLossy: LossyDrawingArray?` + `savedLossy: LossyDrawingArray?`（承载保真字节）；`workingDrawings`/`savedDrawings` 改为计算属性 `{ workingLossy?.drawings }` / `{ savedLossy?.drawings }`；加 `public let workingHiddenIds: [DrawingID]?` + `savedHiddenIds: [DrawingID]?`（init 增参默认 nil）。

- [ ] **Step 1: Write the failing test**

追加：

```swift
@Suite("Drawing P1a — 复盘 canonical wrapper")
struct ReviewArchiveWrapperTests {
    private func d(_ id: String) -> DrawingObject {
        DrawingObject(id: id, toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .daily, candleIndex: 0, price: 1.0)],
                      isExtended: false, panelPosition: 0)
    }

    @Test("canonical 磁盘 key = drawings/hiddenIds")
    func canonicalKeys() throws {
        let w = ReviewArchiveWrapper(drawings: [d("a")], hiddenIds: ["orig-1"])
        let json = try w.encodedColumn()
        #expect(json.contains("\"drawings\""))
        #expect(json.contains("\"hiddenIds\""))
    }

    @Test("wrapper 字节保真：含未来画线条的 wrapper，load→autosave 后该条逐字节等于原始")
    func wrapperBytePerfectForUnknown() throws {
        // wrapper 里 drawings 数组含一条未来画线（敏感 key 顺序 + 1.0 + 转义），且 key 顺序 hiddenIds 在前。
        let unknown = #"{"toolType":"__future__","z":1.0,"a":"x, ]}\"esc"}"#
        let column = #"{"hiddenIds":["orig-2"],"drawings":[\#(unknown)]}"#
        let w = try ReviewArchiveWrapper.decodeColumn(column)
        #expect(w.drawings.isEmpty)                       // 未来条不解码
        #expect(w.hiddenIds == ["orig-2"])
        let out = try w.encodedColumn()
        #expect(out.contains(unknown))                    // 未来条原文逐字节保留在输出里（未被重序列化）
        // 幂等：再 decode→encode 仍含原文
        #expect(try ReviewArchiveWrapper.decodeColumn(out).encodedColumn().contains(unknown))
    }

    @Test("容错：裸数组解码 → hiddenIds 为空")
    func tolerantBareArray() throws {
        let bare = """
        [{"id":"x","toolType":"horizontal","anchors":[{"period":"daily","candleIndex":0,"price":1.0}],
          "isExtended":false,"panelPosition":0,"revealTick":0,"period":"daily","lineSubType":"straight",
          "lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,
          "text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}]
        """
        let w = try ReviewArchiveWrapper.decodeColumn(bare)
        #expect(w.drawings.count == 1)
        #expect(w.hiddenIds.isEmpty)
    }

    @Test("四态往返：空/drawings-only/hidden-only/都有")
    func fourStateRoundTrip() throws {
        let states: [ReviewArchiveWrapper] = [
            ReviewArchiveWrapper(drawings: [], hiddenIds: []),
            ReviewArchiveWrapper(drawings: [d("a")], hiddenIds: []),
            ReviewArchiveWrapper(drawings: [], hiddenIds: ["orig-9"]),
            ReviewArchiveWrapper(drawings: [d("a")], hiddenIds: ["orig-9"]),
        ]
        for s in states {
            let back = try ReviewArchiveWrapper.decodeColumn(s.encodedColumn())
            #expect(back.drawings.map(\.id) == s.drawings.map(\.id))
            #expect(back.hiddenIds == s.hiddenIds)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter ReviewArchiveWrapperTests`
Expected: FAIL — `cannot find 'ReviewArchiveWrapper'`。

- [ ] **Step 3: Write minimal implementation**

新建 `ReviewArchiveWrapper.swift`：

```swift
// 复盘存档列的 canonical 磁盘形状（画线工具扩充 P1a，§11.2/D14）。
// working_drawings/saved_drawings 列存 {"drawings":[…],"hiddenIds":[…]}；解码容错裸 [DrawingObject] 数组。
import Foundation

/// 顶层 JSON 对象按 key 取【原始值字节文本】（去两侧空白、内部字节原样）；非对象/找不到 → nil。
/// 让 wrapper 把 drawings 数组值的原始字节喂给 LossyDrawingArray（保真），不经 JSONSerialization 重序列化（codex plan-R2-high）。
enum JSONObjectScan {
    static func rawValueBytes(_ data: Data, key: String) -> String? {
        let b = [UInt8](data); let n = b.count; var i = 0
        func isWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }
        func readString(_ i0: Int) -> (Int, Int, Int) {   // (内容start, 内容end, 闭引号后)
            var j = i0 + 1; let start = j; var esc = false
            while j < n { let c = b[j]
                if esc { esc = false } else if c == UInt8(ascii: "\\") { esc = true }
                else if c == UInt8(ascii: "\"") { return (start, j, j + 1) }
                j += 1 }
            return (start, j, j)
        }
        func skipValue(_ i0: Int) -> Int {
            var j = i0; guard j < n else { return j }
            let c = b[j]
            if c == UInt8(ascii: "\"") { return readString(j).2 }
            if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") {
                var depth = 0, inStr = false, esc = false
                while j < n { let ch = b[j]
                    if inStr { if esc { esc = false } else if ch == UInt8(ascii: "\\") { esc = true } else if ch == UInt8(ascii: "\"") { inStr = false } }
                    else if ch == UInt8(ascii: "\"") { inStr = true }
                    else if ch == UInt8(ascii: "{") || ch == UInt8(ascii: "[") { depth += 1 }
                    else if ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") { depth -= 1; if depth == 0 { return j + 1 } }
                    j += 1 }
                return j
            }
            while j < n { let ch = b[j]   // 数字/true/false/null → 读到分隔符
                if ch == UInt8(ascii: ",") || ch == UInt8(ascii: "}") || ch == UInt8(ascii: "]") || isWS(ch) { break }
                j += 1 }
            return j
        }
        while i < n, isWS(b[i]) { i += 1 }
        guard i < n, b[i] == UInt8(ascii: "{") else { return nil }
        i += 1
        let keyBytes = [UInt8](key.utf8)
        while i < n {
            while i < n, isWS(b[i]) { i += 1 }
            if i < n, b[i] == UInt8(ascii: "}") { return nil }
            guard i < n, b[i] == UInt8(ascii: "\"") else { return nil }
            let (ks, ke, afterKey) = readString(i); i = afterKey
            let thisKey = Array(b[ks..<ke])
            while i < n, isWS(b[i]) { i += 1 }
            guard i < n, b[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            while i < n, isWS(b[i]) { i += 1 }
            let vs = i, ve = skipValue(i)
            if thisKey == keyBytes {
                var a = vs, z = ve
                while a < z, isWS(b[a]) { a += 1 }
                while z > a, isWS(b[z - 1]) { z -= 1 }
                return String(decoding: b[a..<z], as: UTF8.self)
            }
            i = ve
            while i < n, isWS(b[i]) { i += 1 }
            if i < n, b[i] == UInt8(ascii: ",") { i += 1 } else { break }
        }
        return nil
    }
}

public struct ReviewArchiveWrapper: Equatable, Sendable {
    public let lossy: LossyDrawingArray      // 有序 known/unknownRaw（保序 + 保真）
    public let hiddenIds: [DrawingID]

    public var drawings: [DrawingObject] { lossy.drawings }

    public init(lossy: LossyDrawingArray, hiddenIds: [DrawingID]) {
        self.lossy = lossy; self.hiddenIds = hiddenIds
    }
    /// 便捷：纯已知条（新写入）。
    public init(drawings: [DrawingObject], hiddenIds: [DrawingID]) {
        self.init(lossy: LossyDrawingArray(drawings: drawings), hiddenIds: hiddenIds)
    }

    public static func decodeColumn(_ json: String) throws -> ReviewArchiveWrapper {
        let data = Data(json.utf8)
        // 裸数组（旧形状）→ 整列就是 drawings；hiddenIds 空。
        if JSONTopLevelArray.rawElementStrings(data) != nil {
            return ReviewArchiveWrapper(lossy: try LossyDrawingArray.decode(data), hiddenIds: [])
        }
        // wrapper 对象：取 drawings 值【原始字节切片】喂 LossyDrawingArray（保真）；hiddenIds 无保真需求。
        guard let drawingsRaw = JSONObjectScan.rawValueBytes(data, key: "drawings") else {
            throw AppError.persistence(.dbCorrupted)
        }
        let lossy = try LossyDrawingArray.decode(Data(drawingsRaw.utf8))
        // hiddenIds：缺失(旧 wrapper)→ []；**present 但 malformed（非 [String]）→ .dbCorrupted**（不静默当空，
        // 否则损坏/schema 漂移会覆盖唯一隐藏态副本使已隐藏原训练线重现，codex R10-medium）。
        var hidden: [DrawingID] = []
        if let hraw = JSONObjectScan.rawValueBytes(data, key: "hiddenIds") {   // 存在该键
            guard let decoded = try? JSONDecoder().decode([DrawingID].self, from: Data(hraw.utf8)) else {
                throw AppError.persistence(.dbCorrupted)                        // 存在但非 [String] → 损坏
            }
            hidden = decoded
        }
        return ReviewArchiveWrapper(lossy: lossy, hiddenIds: hidden)
    }

    public func encodedColumn() throws -> String {
        // 直接拼接：drawings 用 lossy 保真字节、hiddenIds 正常编码；不重序列化整体。
        let drawingsStr = String(decoding: try lossy.encoded(), as: UTF8.self)
        let hiddenStr = String(decoding: try JSONEncoder().encode(hiddenIds), as: UTF8.self)
        return "{\"drawings\":\(drawingsStr),\"hiddenIds\":\(hiddenStr)}"
    }
}
```

`ReviewArchiveRepository.swift` 的 `ReviewWorking` 加字段：

```swift
public struct ReviewWorking: Equatable, Sendable {
    public let stepTick: Int
    public let lossy: LossyDrawingArray            // 携带有序 known+unknown → 支持 repo load→save 往返无损（codex R6-high①/Y）
    public let hiddenOriginalIds: [DrawingID]      // 复盘隐藏原训练线 id 集（§11.5/D12）
    public var drawings: [DrawingObject] { lossy.drawings }   // 计算属性：app 消费的已知条

    public init(stepTick: Int, lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = []) {
        self.stepTick = stepTick; self.lossy = lossy; self.hiddenOriginalIds = hiddenOriginalIds
    }
    /// 便捷：纯已知条（coordinator fresh save 用；活编辑保住 unknown = P1b 引擎携带 lossy，§Y 分层）。
    public init(stepTick: Int, drawings: [DrawingObject], hiddenOriginalIds: [DrawingID] = []) {
        self.init(stepTick: stepTick, lossy: LossyDrawingArray(drawings: drawings), hiddenOriginalIds: hiddenOriginalIds)
    }
}
```

`ReviewArchive` 加字段：

```swift
public struct ReviewArchive: Equatable, Sendable {
    public let recordId: Int64
    public let savedLossy: LossyDrawingArray?          // 携带有序 known+unknown（保 unknownRaw 跨 loadArchive→save，codex R10-high）
    public let savedHiddenIds: [DrawingID]?
    public let workingStepTick: Int?
    public let workingLossy: LossyDrawingArray?
    public let workingHiddenIds: [DrawingID]?
    public var savedDrawings: [DrawingObject]? { savedLossy?.drawings }       // 计算属性（app 消费的已知条）
    public var workingDrawings: [DrawingObject]? { workingLossy?.drawings }

    public init(recordId: Int64, savedLossy: LossyDrawingArray?, savedHiddenIds: [DrawingID]? = nil,
                workingStepTick: Int?, workingLossy: LossyDrawingArray?, workingHiddenIds: [DrawingID]? = nil) {
        self.recordId = recordId
        self.savedLossy = savedLossy
        self.savedHiddenIds = savedHiddenIds
        self.workingStepTick = workingStepTick
        self.workingLossy = workingLossy
        self.workingHiddenIds = workingHiddenIds
    }
}
```
> `loadArchive`/`loadSaved` 构 `ReviewArchive` 时用 `savedLossy: try? ...decodeColumn(savedCol)?.lossy`（携带 unknownRaw）；`savedDrawings`/`workingDrawings` 由计算属性给旧读取方。加 loadArchive→save/commit 含未来画线条的字节保真 fixture。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter ReviewArchiveWrapperTests` → PASS。
全量 host：`cd ios/Contracts && swift test 2>&1 | tail -5` → 0 failures（`ReviewArchive`/`ReviewWorking` 新参默认，既有构造点不破）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveWrapper.swift \
        ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveRepository.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): 复盘 canonical wrapper {drawings,hiddenIds} + 容错解码 + ReviewWorking/Archive 加 hiddenIds"
```

---

## Task 7: ReviewNetChange 按 id 归组 + hiddenIds

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveRepository.swift:35-45`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift`

**Interfaces:**
- Consumes: Task 3 `DrawingObject`, `DrawingID`。
- Produces（**扩签名，旧调用向后兼容**）：
  - `public static func changed(working: [DrawingObject], committed: [DrawingObject], workingHiddenIds: [DrawingID] = [], committedHiddenIds: [DrawingID] = []) -> Bool`
  - 语义：按 `id` 归组 + 全字段比较、**保留重数**（不再用「排序字段 key 集」折叠重复几何，D13）；额外比较 hiddenIds 集（D6/D12）。

- [ ] **Step 1: Write the failing test**

追加：

```swift
@Suite("Drawing P1a — ReviewNetChange 按 id + hiddenIds")
struct ReviewNetChangeTests {
    private func d(_ id: String, price: Double = 1.0, locked: Bool = false) -> DrawingObject {
        DrawingObject(id: id, toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .daily, candleIndex: 0, price: price)],
                      isExtended: false, panelPosition: 0, locked: locked)
    }

    @Test("仅锁定变了（几何不变）→ 判净改动（脏）")
    func styleOnlyIsDirty() {
        let committed = [d("a")]
        let working = [d("a", locked: true)]
        #expect(ReviewNetChange.changed(working: working, committed: committed) == true)
    }

    @Test("重复几何按 id 保留重数、不折叠")
    func duplicatesNotFolded() {
        // 两条同价水平线，id 不同 → 删掉其一应判脏
        let committed = [d("a"), d("b")]
        let working = [d("a")]
        #expect(ReviewNetChange.changed(working: working, committed: committed) == true)
    }

    @Test("仅隐藏集变了 → 判净改动（脏）")
    func hiddenOnlyIsDirty() {
        let same = [d("a")]
        #expect(ReviewNetChange.changed(working: same, committed: same,
                                        workingHiddenIds: ["orig-1"], committedHiddenIds: []) == true)
    }

    @Test("画线+隐藏都相等 → 不脏")
    func equalIsClean() {
        let same = [d("a")]
        #expect(ReviewNetChange.changed(working: same, committed: same,
                                        workingHiddenIds: ["orig-1"], committedHiddenIds: ["orig-1"]) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter ReviewNetChangeTests`
Expected: FAIL — `styleOnlyIsDirty` 现返 false（旧 key 不含 locked），且新 hiddenIds 参数不存在（编译失败）。

- [ ] **Step 3: Write minimal implementation**

`ReviewArchiveRepository.swift:35-45` 替换：

```swift
/// 复盘 session 净改动判定：工作态 {drawings, hiddenIds} 是否偏离 committed 基线。
public enum ReviewNetChange {
    /// 净改动 = 画线集（按 id 归组、保留重数、全字段比较）或隐藏 id 集 与基线不等。
    public static func changed(working: [DrawingObject], committed: [DrawingObject],
                               workingHiddenIds: [DrawingID] = [],
                               committedHiddenIds: [DrawingID] = []) -> Bool {
        // 全字段稳定序列化（含 id + 所有样式/文本/tailAnchor/period），按 id 排序保留重数。
        func fullKey(_ d: DrawingObject) -> String {
            let a = d.anchors.map { "\($0.period.rawValue):\($0.candleIndex):\($0.price)" }.joined(separator: ";")
            let t = d.tailAnchor.map { "\($0.period.rawValue):\($0.candleIndex):\($0.price)" } ?? "-"
            return [d.id, d.toolType.rawValue, "\(d.panelPosition)", "\(d.isExtended)", "\(d.revealTick)",
                    d.period.rawValue, d.lineSubType.rawValue, d.lineStyle.rawValue, "\(d.thickness)",
                    d.colorToken.rawValue, d.labelMode.rawValue, "\(d.locked)", d.text, "\(d.fontSize)",
                    d.textColorToken.rawValue, d.textForm.rawValue, t, a].joined(separator: "|")
        }
        if working.map(fullKey).sorted() != committed.map(fullKey).sorted() { return true }
        return workingHiddenIds.sorted() != committedHiddenIds.sorted()
    }
}
```

> 说明：`fullKey` 含 `d.id` → 重复几何（不同 id）不折叠、保留重数（D13）；含全部样式字段 → 仅改样式/锁定也判脏（D6）。hiddenIds 排序集比较 → 仅隐藏/显示也判脏（D12）。旧调用（仅两 drawings 数组）经默认参数向后兼容。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter ReviewNetChangeTests` → PASS。全量 host 0 failures。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/ReviewArchiveRepository.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingModelP1aTests.swift
git commit -m "feat(drawing-P1a): ReviewNetChange 按 id 归组保留重数 + 全字段 + hiddenIds 集比较"
```

---

## Task 8: routeDrawingCommit 全字段 copy-with-revealTick

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift:996-1005`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift`（既有文件追加）

**Interfaces:**
- Consumes: Task 3 `DrawingObject`。
- Produces: `routeDrawingCommit(_:)` 行为变更——盖 `revealTick = tick.globalTickIndex` **但保留 DrawingObject 全部其它字段**（现只从 5 字段重建，会丢 id/样式/锁定/文本/tailAnchor，D15）。

- [ ] **Step 1: Write the failing test**

在 `TrainingEngineDrawingCommitTests.swift` 追加（参照该文件既有建 engine 的 helper；下用占位 `makeEngine()` = 该文件既有工厂）：

```swift
@Test("routeDrawingCommit 保留 id/样式/锁定/文本/tailAnchor，仅盖 revealTick")
func routePreservesAllFields() {
    let e = makeEngine()   // 既有 helper：normal flow，tick 在窗口内
    let anchor = DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.0)
    let d = DrawingObject(
        id: "gen-keep", toolType: .trend, anchors: [anchor, anchor],
        isExtended: true, panelPosition: 1, revealTick: 0,
        period: .m60, lineSubType: .segment, lineStyle: .dash3, thickness: 5,
        colorToken: .purple, labelMode: .right, locked: true,
        text: "标注文本", fontSize: 22, textColorToken: .green, textForm: .borderFilled,
        tailAnchor: anchor)
    e.routeDrawingCommit(d)
    let stored = e.drawings.last!
    #expect(stored.id == "gen-keep")
    #expect(stored.toolType == .trend)
    #expect(stored.lineSubType == .segment)
    #expect(stored.lineStyle == .dash3)
    #expect(stored.thickness == 5)
    #expect(stored.colorToken == .purple)
    #expect(stored.labelMode == .right)
    #expect(stored.locked == true)
    #expect(stored.text == "标注文本")
    #expect(stored.textForm == .borderFilled)
    #expect(stored.tailAnchor == anchor)
    #expect(stored.revealTick == e.tick.globalTickIndex)   // revealTick 被盖成当前 tick
}
```

> 注：`makeEngine()` 若非该文件既有工厂，实施时改用文件内既有建 engine 方式（见 `TrainingEngineDrawingHandlerH1Tests.swift` / `TrainingEngineInteractionTests.swift` 的 `TrainingEngine.preview(...)` 或 fixture 构造）。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter routePreservesAllFields`
Expected: FAIL — `stored.id != "gen-keep"`（现 routeDrawingCommit 重建丢 id/样式）。

- [ ] **Step 3: Write minimal implementation**

`TrainingEngine.swift:996-1005` 的 `routeDrawingCommit` 里，把「只从 5 字段重建」改为 copy-with-revealTick 全字段：

```swift
public func routeDrawingCommit(_ drawing: DrawingObject) {
    let stamped = DrawingObject(
        id: drawing.id, toolType: drawing.toolType, anchors: drawing.anchors,
        isExtended: drawing.isExtended, panelPosition: drawing.panelPosition,
        revealTick: tick.globalTickIndex,               // 仅盖 revealTick
        period: drawing.period, lineSubType: drawing.lineSubType, lineStyle: drawing.lineStyle,
        thickness: drawing.thickness, colorToken: drawing.colorToken, labelMode: drawing.labelMode,
        locked: drawing.locked, text: drawing.text, fontSize: drawing.fontSize,
        textColorToken: drawing.textColorToken, textForm: drawing.textForm, tailAnchor: drawing.tailAnchor)
    if flow.mode == .review {
        appendReviewDrawing(stamped)
    } else {
        appendDrawing(stamped)
    }
}
```

> 说明：仅 `revealTick` 用当前 tick，其余 17 字段原样复制。若想更省样板，实施时可在 `DrawingObject` 加一个 `func withRevealTick(_:) -> DrawingObject` copy helper（可选优化，不改契约）。

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter routePreservesAllFields` → PASS。
Mac Catalyst 编译闸门（UIKit 层未改但 engine 属包）：`xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3` → BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingCommitTests.swift
git commit -m "feat(drawing-P1a): routeDrawingCommit copy-with-revealTick 保留 DrawingObject 全字段"
```

---

## Task 9: 迁移 0009（drawings 加 style_json + draw_uuid + 回填校验 + UNIQUE）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift:205-208 后`
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0009Tests.swift`（新建）

**Interfaces:**
- Produces: migration `"0009_v1.11_drawing_style"`（GRDB `registerMigrationWithDeferredForeignKeyCheck` 表重建）——新 `drawings` 加 `style_json TEXT`（可空）+ `draw_uuid TEXT NOT NULL CHECK(draw_uuid <> '') UNIQUE`（DB 边界强制非空唯一，D20）；拷贝旧行时确定性回填 `draw_uuid = 'legacy-' || record_id || '-' || id`；保留原列/PK/FK；`PRAGMA user_version = 7`。

- [ ] **Step 1: Write the failing test**

新建 `Migration0009Tests.swift`（参照 `KlineTrainerPersistenceTests` 既有迁移测试建 in-memory DB 的方式）：

```swift
import XCTest
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

final class Migration0009Tests: XCTestCase {
    // 建一个迁移到 0008（user_version 6）、含 1 条 drawings 行的 DB，再跑全量迁移（到 0009）。
    private func migratedDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        var upto8 = DatabaseMigrator()
        // 复用生产 migrator 的前缀：先只迁到 0008，插一行历史 drawings，再迁到 0009。
        let full = AppDBMigrations.makeMigrator()
        try full.migrate(dbq, upTo: "0008_v1.10_drawing_reveal_tick")
        try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO training_records
                  (id, stock_code, stock_name, start_datetime, end_datetime, profit, return_rate,
                   total_capital, created_at, final_tick)
                VALUES (7,'600519','贵州茅台',0,0,0,0,100000,0,0)
                """)  // 列名以实际 training_records schema 为准；实施时对齐
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick)
                VALUES (1, 7, 'horizontal', 0, 0, '[]', 0)
                """)
        }
        try full.migrate(dbq)   // 迁到最新（含 0009）
        _ = upto8
        return dbq
    }

    func testAddsColumnsAndBackfillsDrawUuid() throws {
        let dbq = try migratedDB()
        try dbq.read { db in
            let uv = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(uv, 7)
            let row = try Row.fetchOne(db, sql: "SELECT draw_uuid, style_json FROM drawings WHERE id = 1")
            XCTAssertEqual(row?["draw_uuid"], "legacy-7-1")     // 回填格式
            XCTAssertNil(row?["style_json"] as String?)          // 旧行 style_json NULL
        }
    }

    func testDrawUuidUniqueIndexEnforced() throws {
        let dbq = try migratedDB()
        // 插重复 draw_uuid → UNIQUE 约束报错
        XCTAssertThrowsError(try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid)
                VALUES (2, 7, 'horizontal', 0, 0, '[]', 0, 'legacy-7-1')
                """)
        })
    }

    func testNullDrawUuidRejected() throws {
        let dbq = try migratedDB()
        // 不给 draw_uuid → NOT NULL 违约（DB 边界拦，D20）
        XCTAssertThrowsError(try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick)
                VALUES (3, 7, 'horizontal', 0, 0, '[]', 0)
                """)
        })
    }

    func testEmptyDrawUuidRejected() throws {
        let dbq = try migratedDB()
        // draw_uuid = '' → CHECK(draw_uuid <> '') 违约（DB 边界拦，D20）
        XCTAssertThrowsError(try dbq.write { db in
            try db.execute(sql: """
                INSERT INTO drawings (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid)
                VALUES (4, 7, 'horizontal', 0, 0, '[]', 0, '')
                """)
        })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter Migration0009Tests`
Expected: FAIL — 无 `draw_uuid` 列 / user_version 仍 6。

- [ ] **Step 3: Write minimal implementation**

`AppDBMigrations.swift` 在 `0008` migration 之后、`return migrator` 之前插入：

```swift
        // 0009：画线样式/文本/身份持久化（画线工具扩充 P1a，v1.11）。drawings 加 style_json（样式束）+
        // draw_uuid（跨层防碰撞身份，D16/D20）。draw_uuid 须【DB 层强制非空唯一】——SQLite 无法 ALTER ADD
        // 带 NOT NULL/CHECK/UNIQUE 到有数据的表，故【建新表 + 回填拷贝 + 换名】重建（保留原列/PK/FK）。
        // 只走 migration，不动 v1_4_baselineDDL/app_schema_v1.sql（v1.4 冻结基线，drift-checked）。
        // FK：drawings 仅有【出边】(record_id→training_records)、无表引用 drawings，重建安全；用 GRDB 的
        // registerMigrationWithDeferredForeignKeyCheck（表重建标准变体，GRDB 6.29；迁移末自动重检 FK 完整性）。
        migrator.registerMigrationWithDeferredForeignKeyCheck("0009_v1.11_drawing_style") { db in
            try db.execute(sql: """
                CREATE TABLE drawings_new (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    record_id INTEGER NOT NULL REFERENCES training_records(id),
                    tool_type TEXT NOT NULL,
                    panel_position INTEGER NOT NULL,
                    is_extended INTEGER NOT NULL DEFAULT 0,
                    anchors TEXT NOT NULL,
                    reveal_tick INTEGER NOT NULL DEFAULT 0,
                    style_json TEXT,
                    draw_uuid TEXT NOT NULL CHECK(draw_uuid <> '') UNIQUE
                )
                """)
            // 拷贝旧行：style_json 置 NULL；draw_uuid 确定性回填 legacy-<record_id>-<id>（天然唯一非空）。
            try db.execute(sql: """
                INSERT INTO drawings_new
                    (id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, style_json, draw_uuid)
                SELECT id, record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, NULL,
                       'legacy-' || record_id || '-' || id
                FROM drawings
                """)
            // 防御性校验：回填后无空 draw_uuid（回填保证；异常则迁移 fail，D20）。
            let bad = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drawings_new WHERE draw_uuid IS NULL OR draw_uuid = ''") ?? 0
            guard bad == 0 else { throw AppError.persistence(.dbCorrupted) }
            try db.execute(sql: "DROP TABLE drawings")
            try db.execute(sql: "ALTER TABLE drawings_new RENAME TO drawings")
            try db.execute(sql: "PRAGMA user_version = 7")
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter Migration0009Tests` → PASS（4 测试：加列+回填、UNIQUE 拦重复、NOT NULL 拦缺失、CHECK 拦空串）。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/AppDBMigrations.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0009Tests.swift
git commit -m "feat(drawing-P1a): 迁移 0009 drawings 加 style_json+draw_uuid + 回填校验 + UNIQUE + uv 6->7"
```

---

## Task 10: RecordRepository 读写 draw_uuid + style_json + 复盘 wrapper 落库

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift:50-58`（INSERT）+ `:163-173`（`drawingFromRow`）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/ReviewArchiveRepositoryImpl.swift`（working/saved 存取改经 `ReviewArchiveWrapper`）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0009Tests.swift`（追加往返测）

**Interfaces:**
- Consumes: Task 3 `DrawingObject`, Task 6 `ReviewArchiveWrapper`。
- Produces:
  - `RecordRepositoryImpl` drawings INSERT/读取携带 `draw_uuid`(=`DrawingObject.id`) + `style_json`（编码除 anchors 外的样式/文本字段束）；读取时 `DrawingObject.id = row["draw_uuid"]`。
  - `ReviewArchiveRepositoryImpl.saveWorking/commitSaved/loadWorking/loadSaved/loadArchive` 的 working/saved 列改存/解 `ReviewArchiveWrapper.encodedColumn()` / `decodeColumn()`。

- [ ] **Step 1: Write the failing test**

`Migration0009Tests.swift` 追加：

```swift
func testDrawingFullFieldRoundTripThroughRecordRepo() throws {
    let dbq = try migratedDB()
    let anchor = DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.0)
    let d = DrawingObject(id: "gen-xyz", toolType: .trend, anchors: [anchor, anchor],
                          isExtended: true, panelPosition: 1, revealTick: 9,
                          period: .m60, lineSubType: .segment, lineStyle: .dash2, thickness: 4,
                          colorToken: .blue, labelMode: .right, locked: true,
                          text: "颈线", fontSize: 20, textColorToken: .red, textForm: .borderFilled,
                          tailAnchor: anchor)
    try dbq.write { db in
        try RecordRepositoryImpl.insertDrawings(db, recordId: 7, drawings: [d])   // 名称以实际 API 为准
    }
    let loaded = try dbq.read { db in try RecordRepositoryImpl.loadDrawings(db, recordId: 7) }
    let back = loaded.first { $0.id == "gen-xyz" }!
    XCTAssertEqual(back.lineStyle, .dash2)
    XCTAssertEqual(back.locked, true)
    XCTAssertEqual(back.text, "颈线")
    XCTAssertEqual(back.textForm, .borderFilled)
    XCTAssertEqual(back.tailAnchor, anchor)
}
```

> 注：`insertDrawings`/`loadDrawings` 是占位名——实施时对齐 `RecordRepositoryImpl` 真实 save/load 入口（`:11` save 签名 + `:76` load 返回 `(TrainingRecord,[TradeOperation],[DrawingObject])`）。可用完整 save 一条记录 + load 回来断言，或抽一个 drawings-only helper。

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ios/Contracts && swift test --filter testDrawingFullFieldRoundTrip`
Expected: FAIL — INSERT 没写 draw_uuid/style_json；`drawingFromRow` 没读 → 字段丢失/id 为空。

- [ ] **Step 3: Write minimal implementation**

`RecordRepositoryImpl.swift` INSERT（`:50-58`）改为：

```swift
        for dr in drawings {
            let anchorsJSON = try jsonEncode(dr.anchors)
            let styleJSON = try jsonEncode(DrawingStyle(from: dr))   // 见下方 struct
            try db.execute(sql: """
                INSERT INTO drawings
                  (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
                  VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [recordId, dr.toolType.rawValue, dr.panelPosition,
                                 dr.isExtended ? 1 : 0, anchorsJSON, dr.revealTick, dr.id, styleJSON])
        }
```

`drawingFromRow`（`:163-173`）改为读回：

```swift
    /// 返回 nil = 未知/未来 `tool_type` 的 finalized 行 → **lossy 跳过**（不静默伪装成 `.horizontal`，codex R3-medium）。
    /// finalized 行只读、加载不重写，跳过非破坏性（DB 行保留、仅本次不呈现）。caller 用 compactMap 过滤 nil。
    private static func drawingFromRow(_ row: Row) throws -> DrawingObject? {
        let toolRaw: String = row["tool_type"]
        guard let tool = DrawingToolType(rawValue: toolRaw) else { return nil }   // 未知→跳过，不 coerce .horizontal
        let anchorsJSON: String = row["anchors"]
        let anchors: [DrawingAnchor] = try jsonDecode(anchorsJSON, as: [DrawingAnchor].self)
        let drawUuid: String = row["draw_uuid"]
        let isExt = (row["is_extended"] as Int) != 0
        // NULL style_json（旧行）→ **行感知兜底**：lineSubType 由 is_extended 派生（true→.ray/false→.straight）、
        // period 由锚点派生——不能用扁平 defaults（会把 is_extended=1 的旧线错读成 .straight，codex R3-high）。
        let style: DrawingStyle = try (row["style_json"] as String?)
            .map { try jsonDecode($0, as: DrawingStyle.self) }
            ?? DrawingStyle.legacyFallback(isExtended: isExt, period: anchors.first?.period ?? .m3)
        return DrawingObject(
            id: drawUuid, toolType: tool, anchors: anchors,
            isExtended: isExt, panelPosition: row["panel_position"],
            revealTick: row["reveal_tick"], period: style.period, lineSubType: style.lineSubType,
            lineStyle: style.lineStyle, thickness: style.thickness, colorToken: style.colorToken,
            labelMode: style.labelMode, locked: style.locked, text: style.text, fontSize: style.fontSize,
            textColorToken: style.textColorToken, textForm: style.textForm, tailAnchor: style.tailAnchor)
    }
```

> caller（`loadDrawings` 组装 `[DrawingObject]` 处）改为 `rows.compactMap { try drawingFromRow($0) }` 过滤 nil（未知 tool_type 行跳过）。

在 `RecordRepositoryImpl` 内新增私有 `DrawingStyle`（style_json 的 payload 结构 = 除 id/toolType/anchors/isExtended/panelPosition/reveal_tick 外的样式束；这些已是独立列不重复存）：

```swift
    struct DrawingStyle: Codable {
        var period: Period; var lineSubType: LineSubType; var lineStyle: LineStyle
        var thickness: Int; var colorToken: DrawingColorToken; var labelMode: LabelMode
        var locked: Bool; var text: String; var fontSize: Int
        var textColorToken: DrawingColorToken; var textForm: TextForm; var tailAnchor: DrawingAnchor?
        init(from d: DrawingObject) {
            period = d.period; lineSubType = d.lineSubType; lineStyle = d.lineStyle
            thickness = d.thickness; colorToken = d.colorToken; labelMode = d.labelMode
            locked = d.locked; text = d.text; fontSize = d.fontSize
            textColorToken = d.textColorToken; textForm = d.textForm; tailAnchor = d.tailAnchor
        }
        static var defaults: DrawingStyle {
            DrawingStyle(from: DrawingObject(toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0))
        }
        /// 旧行（NULL style_json）行感知兜底：lineSubType 由 is_extended 派生、period 由锚点派生（codex R3-high）。
        static func legacyFallback(isExtended: Bool, period: Period) -> DrawingStyle {
            var s = DrawingStyle.defaults
            s.period = period
            s.lineSubType = isExtended ? .ray : .straight   // spec §11.1/§4.2：旧 isExtended→lineSubType
            return s
        }
    }
```

`ReviewArchiveRepository` 协议 + `ReviewArchiveRepositoryImpl.swift`（**repo 边界无损**，codex plan-R4-high①：只取 `.drawings` 会在下次 save 丢 unknownRaw）：
- **签名改带 lossy**：`saveWorking(recordId:stepTick:lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = [])`、`commitSaved(recordId:lossy: LossyDrawingArray, hiddenOriginalIds: [DrawingID] = [])`——**接收完整 lossy（含 unknownRaw 有序），原样保真回写**，不从 `[DrawingObject]` 重建。
- 写：`jsonEncode(drawings)` → `ReviewArchiveWrapper(lossy: lossy, hiddenIds: hiddenOriginalIds).encodedColumn()`（内含 `lossy.encoded()` 字节保真）。
- 读：`loadWorking` → `ReviewWorking(stepTick:, lossy: ReviewArchiveWrapper.decodeColumn(col).lossy, hiddenOriginalIds: <wrapper.hiddenIds>)`；`loadSaved`/`loadArchive` 同理填 `savedLossy`/`workingLossy` + hiddenIds。
- **coordinator 调用点（P1a 仅签名对齐，非行为）**：现 `saveWorking(drawings: engine.reviewDrawings)` → 改 `saveWorking(lossy: LossyDrawingArray(drawings: engine.reviewDrawings))`（P1a 传纯已知条）。**把加载 blob 带来的 unknownRaw 一路穿过 engine/coordinator autosave/resume-save/commit 路径 = Task 12（P1a，Z1）**——引擎携带 `loadedReviewLossy`、save 用 `reconciled(currentKnown:)` 重发（未识别条原位保留）。本 Task 只改 repo 签名/形状（`saveWorking(lossy:)`/wrapper）；engine/coordinator 接线（`saveWorking(lossy: engine.loadedReviewLossy.reconciled(currentKnown: engine.reviewDrawings))`、commitSaved 同理）在 Task 12。本 Task 集成测试证 **repo 契约无损**（给列种 unknown → load 再 save → 字节不变）；coordinator 级 autosave/commit 保真测试在 Task 12。

> 说明：本 Task 只改**存取形状**（wrapper + draw_uuid/style_json 列）；hide/show 的**行为逻辑**在 P5。saveWorking 新增 hiddenIds 参默认 `[]`，coordinator 现有调用不破。

**补测（Step 1 一并写为 failing test；codex R3）**：直接向 `drawings` 表插旧格式行（`style_json` NULL）再 load，验证兼容：

```swift
    @Test("旧行 is_extended=1 + NULL style_json → 读回 lineSubType==.ray（不被错读成 .straight）")
    func legacyExtendedRowLoadsAsRay() throws {
        let db = try makeMigratedDB()   // 迁移到 0009 的库（同 Migration0009Tests 工厂）
        let rid = try insertRecord(db)  // 一条 training_records
        try db.execute(sql: """
            INSERT INTO drawings (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
            VALUES (?, 'horizontal', 0, 1, ?, 0, 'legacy-1-1', NULL)
            """, arguments: [rid, try jsonEncode([DrawingAnchor(period: .daily, candleIndex: 3, price: 10)])])
        let loaded = try RecordRepositoryImpl.loadDrawings(db, recordId: rid)
        #expect(loaded.count == 1)
        #expect(loaded[0].lineSubType == .ray)         // 由 is_extended=1 派生，非扁平 .straight
        #expect(loaded[0].period == .daily)            // 由锚点派生
        #expect(loaded[0].id == "legacy-1-1")
    }

    @Test("未知 tool_type 的 finalized 行 → 跳过（不被伪装成 .horizontal）")
    func unknownToolTypeRowSkipped() throws {
        let db = try makeMigratedDB()
        let rid = try insertRecord(db)
        try db.execute(sql: """
            INSERT INTO drawings (record_id, tool_type, panel_position, is_extended, anchors, reveal_tick, draw_uuid, style_json)
            VALUES (?, 'future_tool_xyz', 0, 0, ?, 0, 'legacy-1-2', NULL)
            """, arguments: [rid, try jsonEncode([DrawingAnchor(period: .daily, candleIndex: 3, price: 10)])])
        let loaded = try RecordRepositoryImpl.loadDrawings(db, recordId: rid)
        #expect(loaded.isEmpty)                        // 跳过，绝不出现一条 .horizontal
    }
```
> `makeMigratedDB`/`insertRecord` 为测试工厂——实施时对齐 `KlineTrainerPersistenceTests` 既有迁移测试的库构造 + records 插入 helper（同 Migration0009Tests）。

**集成测试（复盘 repo 边界字节无损；codex R4-high①）**：证 load→save 不丢未识别条。

```swift
    @Test("复盘 repo 边界无损：working_drawings 含未来画线条，loadWorking→saveWorking 后该条逐字节保留")
    func reviewRepoPreservesUnknownAcrossLoadSave() throws {
        let db = try makeMigratedDB()
        let rid = try insertRecord(db)
        let unknown = #"{"toolType":"__future__","z":1.0,"a":"x, ]}\"esc"}"#
        // 直接种入 wrapper 列（drawings 数组含一条已知 + 一条未来条）
        let known = #"{"id":"g1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"m3","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"#
        try db.execute(sql: """
            INSERT INTO review_archive (record_id, working_step_tick, working_drawings, updated_at)
            VALUES (?, 5, ?, 0)
            """, arguments: [rid, #"{"drawings":[\#(known),\#(unknown)],"hiddenIds":[]}"#])
        let repo = ReviewArchiveRepositoryImpl(...)          // 实施时用既有构造
        let w = try repo.loadWorking(recordId: rid)
        #expect(w?.drawings.count == 1)                      // 只 1 条已知（未来条不解码）
        #expect(w?.lossy.unknownRaw.first == unknown)        // 未来条原文被 repo 携带
        try repo.saveWorking(recordId: rid, stepTick: 6, lossy: w!.lossy)   // 原样回写 lossy
        let col: String = try Row.fetchOne(db, sql: "SELECT working_drawings FROM review_archive WHERE record_id=?", arguments: [rid])!["working_drawings"]
        #expect(col.contains(unknown))                       // 未来条逐字节仍在（未被重建丢弃）
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ios/Contracts && swift test --filter Migration0009Tests` → 全 PASS。
全量：`cd ios/Contracts && swift test 2>&1 | tail -6` → Swift Testing + XCTest 两框架 0 failures。
Catalyst：`xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3` → BUILD SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/ReviewArchiveRepositoryImpl.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/Migration0009Tests.swift
git commit -m "feat(drawing-P1a): RecordRepository 读写 draw_uuid+style_json + 复盘 wrapper 落库"
```

---

## Task 11: pending_training / pending_replay 有损保真解码（codex plan-R4-high②）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift`（drawings 存取，`saveReplay`/`loadReplay`）
- Modify: `ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift`（drawings 存取；若 pending_training 存取实际在别处，实施时对齐同款改）
- Test: `ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingLossyTests.swift`

**Interfaces:**
- Consumes: Task 5 `LossyDrawingArray`。
- Produces: pending 两表 `drawings` 列 load/save 走 lossy——load 跳未知条不整组失败；save 保留**同记录**既有 unknownRaw 字节。

**背景**：现 `loadReplay` 用 `jsonDecode(drawingsJSON, as: [DrawingObject].self)`——一条未来/未知 toolType 整组解码失败 →`.dbCorrupted`→ resume 失败；`saveReplay` 用 `jsonEncode(p.drawings)`（纯已知）→ 丢 unknownRaw。公开发布（[[project_app_public_release_intent]]）会丢别版本用户数据。

- [ ] **Step 1: 写 failing test**

```swift
@Suite("Pending 有损保真")
struct PendingLossyTests {
    @Test("pending_replay: [knownA, 未来条, knownB] → loadReplay 不抛得 2 已知；saveReplay 后未来条字节保留【且仍在中间】")
    func replayLossyLoadPreservesOrder() throws {
        let db = try makeMigratedDB()
        let unknown = #"{"toolType":"__future__","z":1.0}"#
        func known(_ id: String) -> String { #"{"id":"\#(id)","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"m3","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"# }
        try seedPendingReplayRow(db, recordId: 42, drawingsJSON: "[\(known("g1")),\(unknown),\(known("g2"))]")
        let p = try PendingReplayRepositoryImpl.loadReplay(db)
        #expect(p != nil)                                  // 不再因一条未来条整体 .dbCorrupted
        #expect(p?.drawings.count == 2)                    // 两条已知（未来条不解码）
        try PendingReplayRepositoryImpl.saveReplay(db, replay: p!)   // 保真+保序回写（重发 p.lossy）
        let col: String = try Row.fetchOne(db, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        #expect(col.contains(unknown))                     // 未来条字节仍在
        let iA = col.range(of: #""g1""#)!.lowerBound        // 顺序断言：knownA → 未来条 → knownB
        let iU = col.range(of: "__future__")!.lowerBound
        let iB = col.range(of: #""g2""#)!.lowerBound
        #expect(iA < iU && iU < iB)                         // 未来条仍在中间（未被 append 到末尾）
    }

    @Test("saveReplay 换记录（record 变）→ 不把旧记录 unknownRaw 串进新记录")
    func replayNoCrossRecordLeak() throws {
        let db = try makeMigratedDB()
        try seedPendingReplayRow(db, recordId: 42, drawingsJSON: #"[{"toolType":"__future__"}]"#)
        let fresh = makePendingReplay(recordId: 99, drawings: [])   // 新记录、无画线
        try PendingReplayRepositoryImpl.saveReplay(db, replay: fresh)
        let col: String = try Row.fetchOne(db, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        #expect(!col.contains("__future__"))               // 旧记录的未来条不串进 99
    }
}
```
> `makeMigratedDB`/`seedPendingReplayRow`/`makePendingReplay` = 测试工厂，实施时对齐 `PendingReplayPersistenceTests` 既有 helper。

- [ ] **Step 2: run FAIL**（现 loadReplay 对未来条抛 .dbCorrupted）

- [ ] **Step 3: impl**

**先改模型**（对齐 ReviewWorking 那套，防结构体-用法不一致）：`PendingReplay` / `PendingTraining` 结构体（实施时对齐其真实定义文件）**加 `lossy` 字段、`drawings` 降计算属性、补便捷 init**：

```swift
    // PendingReplay（PendingTraining 同款）：
    public let lossy: LossyDrawingArray                        // 携带有序 known+unknown → repo 往返无损
    public var drawings: [DrawingObject] { lossy.drawings }    // 计算属性（下游消费不变）
    // 便捷 init：coordinator fresh save 用（纯已知；活编辑保住 unknown = P1b 引擎携带 lossy，§Y）
    public init(recordId: Int64, /*…其余原字段…*/ drawings: [DrawingObject]) {
        self.lossy = LossyDrawingArray(drawings: drawings); /*…原字段赋值…*/
    }
```

`loadReplay`（`PendingReplayRepositoryImpl.swift:57`）改为有损解码、构 `PendingReplay(lossy:)`；整体数组解析失败（`rawElementStrings` 返 nil）仍→.dbCorrupted，保持已验证损坏语义：

```swift
            let lossy = try LossyDrawingArray.decode(Data(drawingsJSON.utf8))   // 构 PendingReplay(…, lossy: lossy)
```

`saveReplay`（`:13`）保真回写——INSERT OR REPLACE **前**读同记录现有列的 unknownRaw、拼在新已知条后：

```swift
        // 保真+保序：直接重发 p.lossy（有序 known+unknown）——**不重排、不把 unknown append 到 known 后面**（codex R5-high）。
        // load 得到的 p.lossy 已含原有序未识别条；未编辑的 load→save 逐字节 + 保序无损。
        let drawingsJSON = String(decoding: try p.lossy.encoded(), as: UTF8.self)
```
（`PendingTrainingRepositoryImpl` 同款：`PendingTraining` 携带 `lossy`、load 填充、save 重发 `lossy.encoded()`。）

> 说明：`PendingReplay`/`PendingTraining` 模型增 `var lossy: LossyDrawingArray`（`drawings` = 计算属性 `lossy.drawings`）。**P1a 只保 repo 边界的无损 + 保序**（未编辑的 load→save 逐字节 + 原序，含 `[knownA, unknown, knownB]` 保序）。coordinator 从 engine 构建 fresh pending 时把 known 与加载携带的 unknown **按稳定 `DrawingObject.id` 归并**——**由 Task 12（P1a）引擎携带 `loadedDrawingsLossy` + save 用 `reconciled(currentKnown:)` 完成**（未识别条原位、known 编辑/新增/**删除**都正确保序）；P1a 的 autosave/resume-save 全路径保真（Task 12 coordinator 级测试证）。

- [ ] **Step 4: run PASS + 全量**：`cd ios/Contracts && swift test 2>&1 | tail -6`（两框架 0 fail）+ Catalyst build-for-testing SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingReplayRepositoryImpl.swift \
        ios/Contracts/Sources/KlineTrainerPersistence/Internal/PendingTrainingRepositoryImpl.swift \
        ios/Contracts/Tests/KlineTrainerPersistenceTests/PendingLossyTests.swift
git commit -m "feat(drawing-P1a): pending_training/replay 有损保真解码（load 跳未知条 + save 保留同记录 unknownRaw）"
```

---

## Task 12: 引擎/coordinator 携带 `lossy` 穿过所有 save 路径（Z1，codex plan-R9-high）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Persistence/LossyDrawingArray.swift`（加 `reconciled(currentKnown:)` 合并器）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（`:25` drawings 旁加 `loadedDrawingsLossy`；`:31` reviewDrawings 旁加 `loadedReviewLossy`；`:144` init 灌入；`:274` `setReviewDrawings` 携带 lossy 变体）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift`（load 灌 lossy：`:288`/`:775` `initialDrawingsLossy: pending.lossy`、`:356`/`:464` 复盘 `w.lossy`；save 重建：`:548`/`:575`/`:621` `savePending/saveReplay`、`:879`/`:898` `saveWorking/commitSaved` 用 `reconciled`）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngine/CoordinatorLossyPreserveTests.swift`

**Interfaces:**
- Consumes: Task 5 `LossyDrawingArray`/`LossyDrawingElement`, Task 3 `DrawingObject`, Task 6 `ReviewArchiveWrapper`, Task 10/11 的 `saveWorking(lossy:)`/`saveReplay`/`savePending` 携带-lossy 签名。
- Produces: coordinator 所有 save 路径（pending_training / pending_replay / review working / commit）**保住加载 blob 的未识别条**——`load→(编辑/不编辑)→autosave/resume-save` 未来条字节存活。**至此 P1a 自洽安全**（bump 1.11 站得住、单独发版也不丢线）。

- [ ] **Step 1: 写 failing test（coordinator 级保真，release-blocking）**

```swift
@Suite("coordinator 携带 lossy 保真（Z1）")
struct CoordinatorLossyPreserveTests {
    // 直接给 pending/review 列种入含「未来版本画的线」的 blob，走真 coordinator load→save 路径
    let unknown = #"{"toolType":"__future__","z":1.0}"#
    func known(_ id: String) -> String { #"{"id":"\#(id)","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"m3","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}"# }

    @Test("pending_replay: load(含未来条)→saveProgress(autosave) 后未来条仍在、且在原位")
    func replayAutosavePreservesUnknown() async throws {
        let (coord, db) = try makeCoordinator()
        try seedPendingReplayRow(db, recordId: 42, drawingsJSON: "[\(known("g1")),\(unknown),\(known("g2"))]")
        let engine = try await coord.resumePendingReplay()!            // load：engine 携带 loadedDrawingsLossy
        try await coord.saveProgress(engine: engine)                   // autosave：reconciled 重发
        let col: String = try Row.fetchOne(db, sql: "SELECT drawings FROM pending_replay WHERE id=1")!["drawings"]
        #expect(col.contains(unknown))                                 // 未来条未被 known-only 覆盖
        let iA = col.range(of: #""g1""#)!.lowerBound, iU = col.range(of: "__future__")!.lowerBound, iB = col.range(of: #""g2""#)!.lowerBound
        #expect(iA < iU && iU < iB)                                    // 原位保序
    }

    @Test("复盘 working: load(含未来条)→净改动 autosave 后未来条仍在")
    func reviewWorkingAutosavePreservesUnknown() async throws {
        let (coord, db) = try makeCoordinator()
        try seedReviewWorking(db, recordId: 7, drawingsJSON: "[\(known("g1")),\(unknown)]")
        let engine = try await coord.resumePendingReview(recordId: 7)  // load：engine.loadedReviewLossy 携带
        engine.appendDrawing(decodedKnown(known("g3")))                // 编辑：加一条已知（P1a 现有横线能力）
        try coord.persistReviewWorkingIfChanged(engine: engine)        // autosave：reconciled(currentKnown) 重发
        let col: String = try Row.fetchOne(db, sql: "SELECT working_drawings FROM review_archive WHERE record_id=7")!["working_drawings"]
        #expect(col.contains(unknown))                                 // 未来条经「编辑+autosave」仍存活
    }

    @Test("reconciled 按 id：删 unknown 之前的 known → 未来条仍在原位（不被后续 known 挤到前面）")
    func reconciledByIdPreservesOrderOnDelete() {
        let a = decodedKnown(known("gA")); let bK = decodedKnown(known("gB"))
        let lossy = LossyDrawingArray(elements: [.known(a), .unknownRaw(unknown), .known(bK)])
        let out = String(decoding: try! lossy.reconciled(currentKnown: [bK]).encoded(), as: UTF8.self)  // 删了 A
        let iU = out.range(of: "__future__")!.lowerBound
        let iB = out.range(of: #""gB""#)!.lowerBound
        #expect(iU < iB)                                               // 未来条仍在 B 之前（原位），非位置法的 [B, 未来]
        #expect(!out.contains(#""gA""#))                              // A 已删
    }

    @Test("复盘 hiddenIds：load(wrapper 含 hiddenIds)→autosave/commit 后 hiddenIds 原样保留（不被覆盖成 []）")
    func reviewHiddenIdsSurviveSave() async throws {
        let (coord, db) = try makeCoordinator()
        // wrapper 含 hiddenIds（模拟 P5/未来版本写的隐藏态）
        try seedReviewWorking(db, recordId: 8, wrapperJSON: #"{"drawings":[\#(known("g1"))],"hiddenIds":["h-1","h-2"]}"#)
        let engine = try await coord.resumePendingReview(recordId: 8)  // engine.loadedReviewHiddenIds 携带
        engine.appendDrawing(decodedKnown(known("g9")))
        try coord.persistReviewWorkingIfChanged(engine: engine)        // autosave 传回 loadedReviewHiddenIds
        let col: String = try Row.fetchOne(db, sql: "SELECT working_drawings FROM review_archive WHERE record_id=8")!["working_drawings"]
        #expect(col.contains("h-1") && col.contains("h-2"))           // 隐藏态未被覆盖成 []
    }
}
```
> `makeCoordinator`/`seedPendingReplayRow`/`seedReviewWorking`/`decodedKnown` = 测试工厂，实施时对齐 `CoordinatorReplayPersistenceTests` 既有 helper（真 coordinator + in-memory app.sqlite）。

- [ ] **Step 2: run FAIL**（现 saveProgress 用 `drawings: engine.drawings` 纯 known，未来条被覆盖）

- [ ] **Step 3: impl**

① `LossyDrawingArray.swift` 加合并器（保未识别条原位 + 应用 known 编辑/追加）：

```swift
    /// 用当前已知条重建 lossy：**按稳定 `DrawingObject.id` 归并**（非位置——否则删除一条 known 会把后续 known 挪到
    /// unknownRaw 前面破坏顺序，codex R11-medium；deleteDrawing/removeReviewDrawing 现已存在故 P1a 必须按 id）。
    /// 规则：按原序走 elements——`.unknownRaw` 原位保留；`.known` 若其 id 仍在 currentKnown 则原位发射更新后的该条、
    /// 否则（被删）跳过；currentKnown 里 id 不在原 elements 的（新增画线）按其在 currentKnown 的顺序追加末尾。
    func reconciled(currentKnown: [DrawingObject]) -> LossyDrawingArray {
        let byId = Dictionary(currentKnown.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var emitted = Set<DrawingID>()
        var out: [LossyDrawingElement] = []
        for el in elements {
            switch el {
            case .known(let old):
                if let cur = byId[old.id] { out.append(.known(cur)); emitted.insert(old.id) }   // id 仍在→原位更新；被删→跳过
            case .unknownRaw(let r):
                out.append(.unknownRaw(r))                                                       // 未识别条原位保留
            }
        }
        for k in currentKnown where !emitted.contains(k.id) { out.append(.known(k)) }             // 真新增（原不在）追加末尾
        return LossyDrawingArray(elements: out)
    }
```

② `TrainingEngine.swift`：`drawings`(`:25`) 旁 `public private(set) var loadedDrawingsLossy = LossyDrawingArray(drawings: [])`；`reviewDrawings`(`:31`) 旁 `public private(set) var loadedReviewLossy = LossyDrawingArray(drawings: [])` + **`public private(set) var loadedReviewHiddenIds: [DrawingID] = []`**（携带加载来的隐藏态，防 save 覆盖成 `[]`，codex R11-high）。init(`:144`) 加 `initialDrawingsLossy: LossyDrawingArray? = nil` → `loadedDrawingsLossy = initialDrawingsLossy ?? LossyDrawingArray(drawings: initialDrawings)`（`drawings = loadedDrawingsLossy.drawings`）。`setReviewDrawings`(`:274`) 加携带变体 `setReviewLossy(_ l: LossyDrawingArray, hiddenIds: [DrawingID] = []) { loadedReviewLossy = l; loadedReviewHiddenIds = hiddenIds; reviewDrawings = l.drawings }`（旧 `setReviewDrawings(_:)` 保留 = `setReviewLossy(LossyDrawingArray(drawings: ds))`）。

③ `TrainingSessionCoordinator.swift`：
- **load 灌入**：`resumePending`(`:288`)/`startReplay`(`:775`) 的 `initialDrawings: pending.drawings` 旁加 `initialDrawingsLossy: pending.lossy`；`buildReviewEngine`(`:464`) 的 `engine.setReviewDrawings(reviewDrawings)` 改 `engine.setReviewLossy(reviewLossy, hiddenIds: reviewHiddenIds)`（`review()`/`resumePendingReview` 把 `w.lossy` + `w.hiddenOriginalIds`/baseline 传下来）。
- **save 重建**：`saveProgress`(`:548`/`:575`/`:621`) 建 `PendingReplay`/`Pending` 时 `lossy: engine.loadedDrawingsLossy.reconciled(currentKnown: engine.drawings)`（非 `drawings: engine.drawings`）；`persistReviewWorkingIfChanged`(`:879`) `saveWorking(...lossy: engine.loadedReviewLossy.reconciled(currentKnown: engine.reviewDrawings), hiddenOriginalIds: engine.loadedReviewHiddenIds)`（**传回携带的 hiddenIds、不用默认 `[]`**，codex R11-high；P1a 无 hide 编辑故 = 加载值原样保存）；`commitSaved`(`:898`) 同理传 `engine.loadedReviewHiddenIds`。

- [ ] **Step 4: run PASS + 全量**：`cd ios/Contracts && swift test 2>&1 | tail -6`（两框架 0 fail）+ Catalyst build-for-testing SUCCEEDED。

- [ ] **Step 5: Commit**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Persistence/LossyDrawingArray.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngine/CoordinatorLossyPreserveTests.swift
git commit -m "feat(drawing-P1a): 引擎/coordinator 携带 lossy，全 save 路径保住未识别画线条（Z1）"
```

> **§Z1**：本 Task 令 lossy 保真穿过 engine/coordinator 的 **autosave / resume-save / commit** 全路径——**P1a 自此自洽安全**，D21「所有 save 路径字节保真」在 P1a 完整达成，不再依赖「与 P1b 同版本发布」。`reconciled` **按稳定 `DrawingObject.id` 归并**（新增/编辑/**删除** known 都保未识别条原位——`deleteDrawing/removeReviewDrawing` 现已存在故 P1a 即须按 id，非位置，codex R11-medium）+ 携带 `loadedReviewHiddenIds` 传回 save（不覆盖 P5 隐藏态，codex R11-high）。

---

## 验收清单（中文·非程序员可执行）

> 说明：本阶段是"数据契约与存储"改造，无可见界面。验收靠"跑自动化测试看结果"。请在 `ios/Contracts` 目录逐条执行、对照"预期"。

| # | 动作 | 预期 | 通过判定 |
|---|---|---|---|
| 1 | 执行 `swift test 2>&1 | tail -8` | 结尾出现 Swift Testing 与 XCTest 两个框架的汇总，均 0 failed | 两个"failed: 0"（或"All tests passed"）都出现 = 通过 |
| 2 | 执行 `swift test --filter DrawingObjectCodableTests` | 全字段编码解码往返一致 + 旧格式补默认 | 结尾 0 failed = 通过 |
| 3 | 执行 `swift test --filter LossyDrawingArrayTests` | 未知画线类型只跳过不整组失败、原文**逐字节**不丢（含 key 顺序/数字格式） | 全用例绿 = 通过 |
| 4 | 执行 `swift test --filter ReviewArchiveWrapperTests` | 复盘存档四种状态存取都往返一致 | 结尾 0 failed = 通过 |
| 5 | 执行 `swift test --filter Migration0009Tests` | 升级后新增两列、身份串按规则回填、**重复/缺失/空**身份都被数据库拦下 | 全 4 用例绿 = 通过 |
| 6 | 执行 `swift test --filter ContractVersionTests` | 版本号变为 1.11 | 绿 = 通过 |
| 7 | 执行 `swift test --filter PendingLossyTests` | 待续训练/复盘草稿里含「未来版本画的线」时不再整体读失败、保存后那条线**逐字节不丢**、且不会串到别的记录 | 全用例绿 = 通过 |
| 8 | 执行 `swift test --filter reviewRepoPreservesUnknownAcrossLoadSave` | 复盘存档里「未来版本画的线」经「读出→再存」后**逐字节保留** | 绿 = 通过 |
| 9 | 执行 `xcodebuild -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' build-for-testing 2>&1 | tail -3` | 苹果编译器把改动全编过 | 出现 BUILD SUCCEEDED = 通过 |
| 10 | 执行 `swift test --filter CoordinatorLossyPreserveTests` | 「未来版本画的线」经真 coordinator 的 载入→自动保存 / 载入→加线→自动保存 后仍**逐字节保留、且在原位** | 全绿 = 通过（证 P1a 所有保存路径都不丢未来版本的线，Z1） |

---

## 自查记录（writing-plans self-review）

- **spec 覆盖**：§4 数据模型（Task 1-3）、§11.1 兜底默认（Task 3）、§11.2 wrapper+lossy（Task 5/6）、§11.3 迁移 0009+draw_uuid 约束（Task 9）、§11.4 net-change（Task 7）、§5.0/D15 routeDrawingCommit（Task 8）、CONTRACT bump（Task 4）——均有对应 Task。§5-§10 的**几何/工具/UI/放大镜/手势/周期绑定渲染**属 P1b/后续阶段，本 P1a 只做契约地基，spec §15 P1 已注明分 P1a/P1b。
- **占位扫描**：无 TBD/TODO；两处显式标注"占位名以实际 API 为准"（Task 8 `makeEngine()`、Task 10 `insertDrawings/loadDrawings`）——因这两个既有入口的确切签名需实施时对齐真身，非设计占位，已给出对齐指引（引用真实文件行）。
- **类型一致**：`DrawingID=String`、`ReviewArchiveWrapper{drawings,hiddenIds}`、`DrawingObject` 18 字段跨 Task 一致；`ReviewNetChange.changed` 扩参与旧调用兼容。`LossyDrawingArray` 改为有序 `elements:[LossyDrawingElement]`（`.known`/`.unknownRaw` 保序，codex plan-R2），`drawings`/`unknownRaw` 降为计算属性——Task 6/7 消费 `.drawings` 名/类型不变；Task 10 用 `ReviewArchiveWrapper(drawings:hiddenIds:).encodedColumn()`/`.decodeColumn().drawings` 便捷入口不变。wrapper 用 `JSONObjectScan` 保留 drawings 原始字节切片（字节保真，codex plan-R2）。
- **codex plan-R1 收口（2 high）**：① Task 5 有损解码改**真字节级保真**——新增 `JSONTopLevelArray` 顶层数组切分器捕获未识别条**原始字节文本**、回写原样重发（**不再经 `JSONSerialization` 反/重序列化**改 key 序/数字格式，防 load+autosave 静默改写未来客户端数据），加**字节全等**测试；② Task 9 迁移改**表重建**令 `draw_uuid NOT NULL CHECK(draw_uuid <> '') UNIQUE`（DB 边界强制、非仅一次回填校验），加 缺失/空/重复 三道 DB 拦截测试。
- **codex plan-R2/R3/R4/R5/R6 收口**：R2 `LossyDrawingArray` 改**有序** `elements` 保未识别条原位 + wrapper 用 `JSONObjectScan` 保 `drawings` 原始字节（不重序列化整体）；R3 Task 10 finalized 行 NULL style_json **行感知兜底**（`is_extended`→lineSubType、锚点→period）+ 未知 tool_type **跳过**不伪装 `.horizontal`；**R4/R5/R6（公开发布标准，[[project_app_public_release_intent]]；分层决策 Y）**：`ReviewWorking/PendingReplay` 携带有序 `lossy`（`drawings` 计算属性），三处画线数组边界（record/review/pending）均 **① 有损解码永不崩 + ② repo load→save 往返无损（同内容逐字节+保序）**；R5 修 pending append 破坏顺序（改重发有序 `lossy`）+ 切分器拒尾部垃圾；R6 修 `ReviewWorking` 结构体片段补 `lossy`（与接口 + `w.lossy` 用法一致）。**（§Y 分层曾拟把 coordinator save 保真延后 P1b；codex R9 指出「版本化 PR 须自洽安全」→ user 选 Z1，见下条：该保真由 Task 12 挪回 P1a，P1a 自洽安全，A 字节保真在 P1a 即完整。）**
- **codex plan-R7 收口**：**切分器拒畸形 JSON**——`JSONTopLevelArray` 拒绝空槽（尾随 `[x,]`/前导 `[,x]`/连续 `[x,,y]`/纯空白元素），空数组 `[]` 仍合法；回归测试：尾/首/双逗号、纯空白元素、`[valid]]`、`[valid]{junk}` 全 → nil（`.dbCorrupted`，不被静默"修好"）。
- **codex plan-R8/R9 收口 → 决策 Z1（P1a 自洽安全）**：R8 统一「引擎携带 lossy」延后目标（消 P1b-vs-P5 矛盾）；R9 指出「P1a bump 1.11+迁移=版本化 PR 但 autosave 仍丢 unknown → 不自洽安全」。**user 选 Z1**：**新增 Task 12** 把 engine/coordinator 携带 `lossy`（`reconciled(currentKnown:)` 保未识别条原位）挪回 **P1a**——D21「全 save 路径（autosave/resume-save/commit）字节保真」在 P1a 完整达成、bump 1.11 站得住、单独发版也不丢「未来版本写的画线条」；不再需「与 P1b 同版本发布」发布流程兜底。画线编辑 UI 仍 P1b。
- **codex plan-R11 收口（1 high+1 med，Z1 精化）**：① 引擎/coordinator **也携带 `loadedReviewHiddenIds`**、autosave/commit 传回（不用默认 `[]` 覆盖 P5 写的隐藏态使已隐藏线重现，codex R11-high）+ hiddenIds load→save 不变 fixture；② `reconciled` **从「按位置」改「按稳定 `DrawingObject.id`」**——删一条 known 时未识别条仍原位（位置法会把后续 known 挤到 unknown 前破坏顺序；`deleteDrawing/removeReviewDrawing` 现已存在故 P1a 即须按 id，非 P1b）+ 删 known 绕 unknown 保序 fixture。
- **codex plan-R10 收口（1 high+1 med）**：① `ReviewArchive` 结构体片段补 `savedLossy/workingLossy`（`savedDrawings/workingDrawings` 降计算属性，同 R6 ReviewWorking 修法）——与「携带 lossy 保 unknownRaw 跨 loadArchive→save」接口一致，加 loadArchive→save 未来条字节保真 fixture；② `ReviewArchiveWrapper.decodeColumn` 的 `hiddenIds`：缺失→`[]`，**present 但 malformed（非 `[String]`）→ `.dbCorrupted` fail-closed**（不静默当空覆盖唯一隐藏态副本），加 缺失/合法/malformed 三 fixtures。

## 留给 P1b / 后续的点（本 P1a 不做）
1. **DrawingTool 协议具体工具实现 + 渲染/hitTest**（P1b：水平线升级/趋势线/通道线/箱体/折线）。
2. **画线模式外壳 UI / 类型行按阶段门控 / 选中两层门控 / 手势消歧 / 周期绑定渲染**（P1b，§2/§7/§10/§14）。
3. **coordinator 把 saveWorking 的 hiddenIds 接真值 + hide/show 行为 + clear-saved 空判**（P5，§12）。
4. **`ray`/`time` legacy case 的 UI 侧最终退役**（其解码兼容已在 P1a）。
5. Task 8 `makeEngine()`、Task 10 `insertDrawings/loadDrawings` 的真实入口名对齐（实施时按引用行核对）。
6. **hide/show 行为 + hiddenIds 编辑（写入非空隐藏态）= P5**：Task 12 已在 **P1a** 令 engine/coordinator 携带 `lossy` + `loadedReviewHiddenIds`、`reconciled` 按稳定 id 归并，**全 save 路径（autosave/resume-save/commit）不丢 unknown、不覆盖已加载 hiddenIds、删/增/改 known 都保序**（codex R11 全收）。P1a 只**透传**加载来的 hiddenIds（无 hide 编辑）；用户实际隐藏/显示原训练线的**写入行为**在 **P5**（§12）。P1a 自洽安全、A 字节保真在 P1a 即完整（非缺口）。
