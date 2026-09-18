# 划线 P1c 第 1 片实施计划：样式矩阵结构泛化

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「本构建懂每个划线工具的哪些**样式语义**」从散落在四处的写死判据，收成 `DrawingStyleAvailability` 内部的一张按工具查的表；表内容一行不变（今天仍只有水平线）⇒ **对用户零可见变化**，但第 4/5/6 片每加一个工具从「改四处代码」变成「加一行」。

**Architecture:** 纯结构重构 + 举证测试。新增一个内部 `ToolStyleRules` 结构与 `styleRules` 静态表，四处判据（有效性 / 标注归一化 / 工具集 / 可编辑性）全部改成查这张表；横线的两条规则函数体**原地保留**并被表引用。行为等价由一张**穷举真值表**（208 格）直接钉死，不靠推理；「四处确实都查了表」「有效性列没被接到 UI」「锚数没被顺手泛化」三条由**结构计数守卫**钉死。

**Tech Stack:** Swift 6（`swift-tools-version: 6.0`，严格并发）、swift-testing（`@Suite` / `@Test` / `#expect`）、既有源码守卫扫描器 `SourceGuardScanner.swift`（`allSwiftFilesUnderSources()` / `squeeze()` / `squeezedText()`）。

**Spec:** `docs/superpowers/specs/2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md`（D112–D120；⚠️ 该 spec **12 轮 codex 从未 approve**，按 user 事先约定的停止规则收口）

**工作目录：** `.dev/worktree/drawing-p1c-1a`，分支 `feat/drawing-p1c-1a`，base `origin/main@1437529`

## Global Constraints

- **⛔ 零可见变化**：用户看得到的任何行为都不得改变。验收清单每一条的预期都是「跟以前一模一样」。
- **⛔ 零 UI 改动**：`Sources/KlineTrainerContracts/UI/` 下**一个字都不改**（面板三处写死横线规则归第 4 片，spec D116/Q8/Q14）。
- **⛔ 不碰锚数**：`Drawing/DefaultDrawingInputController.swift` **一个字都不改**（spec D119/Q12）。
- **⛔ 不 bump 契约**：`CONTRACT_VERSION` 维持 `"1.13"`；`user_version` 维持 `8`；不动 `docs/governance/m01-schema-versioning-contract.md`；无任何迁移（spec D114）。
- **⛔ 不碰归档阻塞判据**：`TrainingSessionCoordinator.swift:741-743` 一行不改、一条不加。
- **⛔ 横线规则函数不得改名 / 删除 / 移文件**：`horizontalLineSubTypeEnabled` 与 `horizontalLabelModeEnabled` 在 `Sources/` 中**各恰好 1 处 `func` 定义**，且必须留在 `DrawingStyleAvailability.swift`（既有源码守卫 `DrawingObjectStyleEditTests.swift:198-201` 钉死）。
- **⛔ `func normalizedLabelMode(` 恰好 2 处**（两参横线版 + 三参 tool-aware 版），都在 `DrawingStyleAvailability.swift`；**两参版必须保留**（面板 `DrawingStyleParams.swift:46` 还在用）。
- **⛔ 有效性列不是 UI 灰态判据**（spec D120）：`isRenderableSubType` 的语义严格限定为「这个值会不会让线画不出来 ⇒ 该不该**拒收**数据」。任何人不得把它接到样式面板的灰态上。
- **判绿纪律**：读**输出内容 / 执行量**，⛔ 不读「SUCCEEDED」字样、⛔ 不用 `tail` 截断；每条闸门命令必须**同时打印 branch 与 HEAD**。
- **变异纪律**：先提交实现、再跑变异；复原一律 `cp` 往返，**⛔ 禁止 `git checkout <file>`**。

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | 修改（1 行） | `DrawingToolType` 加 `CaseIterable`（D118），使穷举测试的遍历源是**生产枚举**而非测试里手写的数组 |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift` | 修改 | 新增 `ToolStyleRules` + `styleRules` 表；四处判据改查表；两条横线规则函数体原地不动 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolTypeCaseIterableTests.swift` | 新建 | 锁死枚举形态（13 个 case）与 `implemented` 边界 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixTests.swift` | 新建 | T1 行为等价穷举真值表（208 格）+ 三条防空转 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift` | 新建 | T2 单一真相守卫 / T2b 有效性列未接 UI / T1f 锚数边界（全部含反向自检） |
| `docs/superpowers/acceptance/2026-09-01-drawing-p1c-1-tool-matrix.md` | 新建 | 非程序员验收清单（中文，动作 / 预期 / 通过标准） |

**⚠️ 不新建源码文件**：表建在 `DrawingStyleAvailability` 内部（spec D117）—— 新文件会出现在既有源码守卫的 grep 命中里，需要额外实跑确认，无谓风险。

---

### Task 1: `DrawingToolType` 加 `CaseIterable` 并锁死枚举形态

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:37`
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolTypeCaseIterableTests.swift`（新建）

**Interfaces:**
- Consumes: 无
- Produces: `DrawingToolType.allCases: [DrawingToolType]`（13 个：11 目标工具 + legacy `.ray` / `.time`）—— Task 2 的真值表**必须**用它做遍历源

**Why：** T1 的全部价值在于「对**每一个**工具都断言了期望值」。若遍历源是测试里手写的 13 元素数组，「数量 == 13」就退化成「测试断言自己写的字面量」= 恒真空转；而且第 4–6 片加工具时 T1 **不会**自动覆盖新工具（spec D118）。

- [ ] **Step 1: 写测试（此刻编译不过）**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolTypeCaseIterableTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolTypeCaseIterableTests.swift
// Spec: 2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md D118
// 为什么需要：样式矩阵真值表（DrawingToolStyleMatrixTests）必须遍历**生产枚举**才算真断言。
import Testing
@testable import KlineTrainerContracts

@Suite("DrawingToolType 形态锁定（D118）")
struct DrawingToolTypeCaseIterableTests {

    @Test("allCases 恰好 13 个 —— 11 个目标工具 + 2 个 legacy（ray / time）")
    func caseCountIsThirteen() {
        #expect(DrawingToolType.allCases.count == 13)
    }

    @Test("allCases 内容逐个对齐已声明的 case（防漏、防多、防改名）")
    func caseSetIsExact() {
        let expected: Set<DrawingToolType> = [
            .horizontal, .trend, .channel, .polyline, .golden, .wave,
            .cycle, .fib, .timeRuler, .rect, .text,          // 目标 11 工具（Models.swift:39）
            .ray, .time,                                      // legacy：历史 blob 容忍解码（Models.swift:41）
        ]
        // 反向自检：期望集自己没被写重复（否则 count 会掉到 12 而断言仍可能过）
        #expect(expected.count == 13)
        #expect(Set(DrawingToolType.allCases) == expected)
    }

    @Test("D118 边界：implemented 仍恰好是 [.horizontal]，本片不得顺手改")
    func implementedUnchanged() {
        #expect(DrawingToolType.implemented == [.horizontal])
    }
}
```

- [ ] **Step 2: 跑测试确认它红（编译失败）**

```bash
cd "ios/Contracts" && swift test --filter DrawingToolTypeCaseIterableTests 2>&1 | tail -30
```

预期：**编译错误**，形如 `type 'DrawingToolType' has no member 'allCases'`。
⚠️ 若它直接通过，说明 `CaseIterable` 已经在了 —— 停下核实，不要继续。

- [ ] **Step 3: 加协议遵从（只改这一行）**

`ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift:37`，把

```swift
public enum DrawingToolType: String, Codable, Equatable, Sendable {
```

改成

```swift
public enum DrawingToolType: String, Codable, Equatable, Sendable, CaseIterable {
```

⛔ **只加协议遵从。** 不得改 case 名 / 次序 / raw value，不得动 `implemented` —— 次序变了 `allCases` 的顺序就变了，legacy 的 `ray` / `time` 必须留在原位。

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd "ios/Contracts" && swift test --filter DrawingToolTypeCaseIterableTests 2>&1 | tail -20
```

预期：3 个用例全部 passed。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolTypeCaseIterableTests.swift
git commit -m "P1c-1 Task1：DrawingToolType 加 CaseIterable（D118）+ 枚举形态锁定测试

纯加法的协议遵从：无关联值的 String raw-value 枚举，allCases 由编译器合成，
不改任何既有行为、不影响 Codable、不影响任何既有 switch 的穷尽性、不扩展值域
（故不触发 CONTRACT_VERSION bump，spec D114/D118）。

目的：让后续真值表的遍历源是生产枚举而非测试里手写的数组——后者会让
「数量 == 13」退化成「测试断言自己写的字面量」，且新工具不会自动进入覆盖面。"
```

---

### Task 2: T1 行为等价穷举真值表（写在重构**之前**，必须绿）

**Files:**
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixTests.swift`（新建）

**Interfaces:**
- Consumes: `DrawingToolType.allCases`（Task 1）；`DrawingStyleAvailability.isRenderableSubType(_:toolType:)` / `.normalizedLabelMode(current:lineSubType:toolType:)` / `.isEditableToolType(_:)` / `.toolsWithStyleMatrix`（均为现有 API，签名不变）
- Produces: 一张冻结的真值表，Task 3 重构前后**都必须绿** —— 它是这次重构的安全网

**⚠️ 这是行为保持型重构，TDD 的形状与平时相反**：本 Task 的测试**现在就该是绿的**（它描述的是当前行为）。它的判别力不来自「先红后绿」，而来自 Task 5 的**变异验证**（改坏实现必须让指定的档变红）。

- [ ] **Step 1: 写真值表测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixTests.swift
// Spec: 2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md §5-T1
// 本套件是「四处判据改成查表」这次重构的**安全网**：重构前后逐格结果必须一字不变。
// ⚠️ 不写成「泛化前后结果相同」（同一个构建里跑不出「前」）——逐格断言**具体期望值**。
import Testing
@testable import KlineTrainerContracts

@Suite("T1 样式矩阵行为等价真值表（P1c 第 1 片）")
struct DrawingToolStyleMatrixTests {
    typealias A = DrawingStyleAvailability

    /// 除水平线外的 12 个工具。⚠️ 遍历源**必须**是生产枚举（D118）——手写数组会让本套件恒真空转。
    private var nonHorizontal: [DrawingToolType] {
        DrawingToolType.allCases.filter { $0 != .horizontal }
    }

    // MARK: - 防空转三条（spec §5-T1「防空转」，缺一不可）

    @Test("防空转①：遍历源是生产枚举，且规模正确（13 / 12）")
    func enumerationIsNotVacuous() {
        #expect(DrawingToolType.allCases.count == 13)
        #expect(nonHorizontal.count == 12)
        #expect(LineSubType.allCases.count == 3)
        #expect(LabelMode.allCases.count == 4)
    }

    @Test("防空转②：表的键恰好是 {.horizontal} —— 表被误扩时下面几档会静默改变含义")
    func tableHasExactlyOneRow() {
        #expect(A.toolsWithStyleMatrix == [.horizontal])
    }

    // MARK: - T1a/T1b 有效性列（会不会拒收数据）

    @Test("T1a 有效性 · 水平线：直线✅ 射线✅ 线段❌")
    func t1a_renderableHorizontal() {
        // ⚠️ 必须含 ❌ 档：全 ✅ 的套件会与「实现恒返 true」这种坏实现同时为绿
        #expect(A.isRenderableSubType(.straight, toolType: .horizontal))
        #expect(A.isRenderableSubType(.ray, toolType: .horizontal))
        #expect(!A.isRenderableSubType(.segment, toolType: .horizontal))
    }

    @Test("T1b 有效性 · 其余 12 个工具 × 3 种线型 恒 true（36 格）")
    func t1b_renderableNonHorizontal() {
        var checked = 0
        for t in nonHorizontal {
            for sub in LineSubType.allCases {
                #expect(A.isRenderableSubType(sub, toolType: t),
                        "\(t) + \(sub)：表里没有的工具不得据此拒收数据")
                checked += 1
            }
        }
        #expect(checked == 36)   // 反向自检：真的跑满了 36 格
    }

    // MARK: - T1c/T1d 标注归一化列（不可用则回落 .hidden，不拒收）

    @Test("T1c 归一化 · 水平线：LabelMode × LineSubType 全笛卡尔积 12 格逐格期望值")
    func t1c_normalizedHorizontal() {
        var checked = 0
        for sub in LineSubType.allCases {
            for mode in LabelMode.allCases {
                let expected: LabelMode
                switch mode {
                case .show:           expected = .hidden                     // 「显示」恒灰 → 落 hidden
                case .left:           expected = (sub == .ray) ? .hidden : .left  // 射线下「左」不可用
                case .hidden, .right: expected = mode                        // 恒原样
                }
                #expect(A.normalizedLabelMode(current: mode, lineSubType: sub, toolType: .horizontal) == expected,
                        "水平线 \(sub) + \(mode) 应归一到 \(expected)")
                checked += 1
            }
        }
        #expect(checked == 12)
    }

    @Test("T1d 归一化 · 其余 12 个工具：恒原样返回 current（144 格）")
    func t1d_normalizedNonHorizontal() {
        var checked = 0
        for t in nonHorizontal {
            for sub in LineSubType.allCases {
                for mode in LabelMode.allCases {
                    #expect(A.normalizedLabelMode(current: mode, lineSubType: sub, toolType: t) == mode,
                            "\(t) 的 labelMode 不得被水平线规则改写")
                    checked += 1
                }
            }
        }
        #expect(checked == 144)
    }

    // MARK: - T1e 可编辑性

    @Test("T1e 可编辑：水平线 ✅，其余 12 个 ❌（13 格）")
    func t1e_editable() {
        var checked = 0
        #expect(A.isEditableToolType(.horizontal)); checked += 1
        for t in nonHorizontal {
            #expect(!A.isEditableToolType(t), "\(t) 本构建没有样式矩阵，不得可编辑")
            checked += 1
        }
        #expect(checked == 13)
    }
}
```

- [ ] **Step 2: 跑测试确认它**现在就绿**（它描述的是当前行为）**

```bash
cd "ios/Contracts" && swift test --filter DrawingToolStyleMatrixTests 2>&1 | tail -25
```

预期：7 个用例全部 passed。
⚠️ **若有任何一格红，立刻停下**：说明我对当前行为的理解有错，必须先查清楚再动重构 —— 带着错误的安全网做重构等于没有安全网。

- [ ] **Step 3: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixTests.swift
git commit -m "P1c-1 Task2：T1 行为等价穷举真值表（208 格，重构前的安全网）

本套件描述的是**当前**行为，故现在就是绿的；它的判别力由 Task 5 的变异验证提供。
含三条防空转：遍历源是生产枚举 / 表的键恰好 {.horizontal} / 每档断言实际跑满的格数。
T1a 与 T1c 各含 ❌ 档，避免与「实现恒返 true」这类坏实现同时为绿。"
```

---

### Task 3: 引入样式表并把四处判据改成查表（本片的核心改动）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift`（`:18-20` / `:30` / `:58-62`；`:48-49` 表达式不变）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift`（新建，本 Task 只放 T2）

**Interfaces:**
- Consumes: `DrawingToolType.allCases`（Task 1）；Task 2 的真值表作为安全网
- Produces:
  - `DrawingStyleAvailability.ToolStyleRules`（internal struct，字段 `renderableLineSubType: @Sendable (LineSubType) -> Bool`、`labelModeEnabled: @Sendable (LabelMode, LineSubType) -> Bool`）
  - `DrawingStyleAvailability.styleRules: [DrawingToolType: ToolStyleRules]`（internal static let，**唯一登记处**）
  - `DrawingStyleAvailability.toolsWithStyleMatrix: Set<DrawingToolType>`（**改为计算属性**，由 `Set(styleRules.keys)` 派生；类型与既有调用点不变）

- [ ] **Step 1: 先写 T2 结构守卫（此刻必红 —— 还没有表）**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift
// Spec: 2026-08-30-drawing-tools-P1c-1A-tool-matrix-design.md §5-T2 / T2b / T1f
// ⚠️ 判据一律用**结构计数**，⛔ 不得写成「某文件里不许出现某个词」的禁词黑名单
//    （后者可被删注释 / 改写法绕过，也会被承重注释误伤）。
// ⚠️ 扫描一律经 squeezedText()：剥行注释 / 嵌套块注释 / 字符串字面量内容，并删光空白。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("P1c 第 1 片结构守卫：单一真相 / 有效性列未接 UI / 锚数边界")
struct DrawingToolStyleMatrixGuardTests {

    /// 读一个源文件并剥成「只剩代码、无空白」的文本。
    private func code(_ path: String) throws -> String {
        squeezedText(try String(contentsOfFile: path, encoding: .utf8))
    }

    private func fileNamed(_ suffix: String, in files: [String]) throws -> String {
        try #require(files.first { $0.hasSuffix(suffix) }, "扫描不到 \(suffix)（路径锚点失效）")
    }

    @Test("T2 单一真相：查表调用恰好 2 处且都在定义文件；工具集由表的键派生")
    func t2_singleSourceOfTruth() throws {
        let files = try allSwiftFilesUnderSources()
        #expect(!files.isEmpty)                       // 反向自检：真的扫到文件了

        var hits: [String: Int] = [:]
        for path in files {
            let n = try code(path).components(separatedBy: squeeze("styleRules[")).count - 1
            if n > 0 { hits[URL(fileURLWithPath: path).lastPathComponent] = n }
        }
        // isRenderableSubType 与 normalizedLabelMode(三参) 各查一次，且只许出现在定义文件里
        #expect(hits == ["DrawingStyleAvailability.swift": 2], "查表点分布异常：\(hits)")

        let availPath = try fileNamed("Drawing/DrawingStyleAvailability.swift", in: files)
        let avail = try code(availPath)
        // 工具集必须**派生**自表的键，不得是第二份写死清单
        #expect(avail.contains(squeeze("Set(styleRules.keys)")),
                "toolsWithStyleMatrix 必须由表的键派生")
        // 反向自检：这个文件确实含已知锚点（防「路径写对了但读到空文件也全绿」）
        #expect(avail.contains(squeeze("func isRenderableSubType(")))
        #expect(avail.contains(squeeze("func horizontalLineSubTypeEnabled(")))
        #expect(avail.contains(squeeze("func horizontalLabelModeEnabled(")))
    }
}
```

- [ ] **Step 2: 跑守卫确认它红**

```bash
cd "ios/Contracts" && swift test --filter DrawingToolStyleMatrixGuardTests 2>&1 | tail -25
```

预期：`t2_singleSourceOfTruth` **FAIL**，消息形如 `查表点分布异常：[:]`（还没有表，零命中）。

- [ ] **Step 3: 改实现 —— 加表并把四处改成查表**

编辑 `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift`。

**3a. 在 `horizontalLineSubTypeEnabled` 之后、`isRenderableSubType` 之前插入表定义**：

```swift
    /// 本构建懂某个工具的哪些**样式语义**。一行 = 一个工具；P1c 后续切片加工具 = **加一行**。
    ///
    /// ⛔⛔ **第一列是「有效性」，不是 UI 灰态判据**（P1c 第 1 片 spec D120）：它回答的是
    ///    「这个值会不会让线画不出来 ⇒ 该不该**拒收**这条数据」。样式面板的灰态是**另一个维度**，
    ///    今天独立存在于 `DrawingStyleParams`（`:39` / `:142` 直接调横线专用函数），由第 4 片正式建立。
    ///    把这一列接到面板灰态上，箱体 / 折线落地时必然二选一地坏掉 ——
    ///    母 spec §3.1 要求它们「三个线型全灰」，但 `DrawingObject.lineSubType` **非可选**、
    ///    每条线都必带一个值：写成三个全 false ⇒ 落线被 `TrainingEngine` 的 append 门拒 ⇒ **画不出来**；
    ///    写成 `.straight` 为 true 好让写入通过 ⇒ 面板会把「直线」显示成**可点** ⇒ 违反 §3.1。
    ///    ⇒ 箱体 / 折线的正确取值是「有效性**全 ✅**（工具忽略该字段，不得据此拒收）+ 灰态全灰（另一维）」。
    struct ToolStyleRules: Sendable {
        /// 【有效性】该 `lineSubType` 会不会让这条线画不出来 ⇒ 该不该拒收。⛔ 不得接到 UI 灰态（D120）。
        let renderableLineSubType: @Sendable (LineSubType) -> Bool
        /// 【归一化】该 `labelMode` 在此 `lineSubType` 下可不可用；不可用由 `normalizedLabelMode` 回落
        /// `.hidden`（**是归一化，不是拒收** —— 故这一列没有「有效性 vs 灰态」的分裂问题）。
        let labelModeEnabled: @Sendable (LabelMode, LineSubType) -> Bool
    }

    /// 本构建**写得出样式矩阵**的工具表 —— 这些语义的**唯一登记处**。
    /// ⚠️ 与 `DrawingToolType.implemented`（= 画得出 / 提交得了）是**两件事**；今天二者恰好相等，
    ///    由 `DrawingObjectStyleEditTests` 的漂移告警钉死：只把新工具加进 `implemented` 而没在这里
    ///    加行，那条断言当场红（fail-closed：现象是「新工具样式控件不生效」，一眼可见、不污染数据）。
    static let styleRules: [DrawingToolType: ToolStyleRules] = [
        .horizontal: ToolStyleRules(renderableLineSubType: horizontalLineSubTypeEnabled,
                                    labelModeEnabled: horizontalLabelModeEnabled),
    ]
```

**3b. `isRenderableSubType` 改查表**（原 `:18-21`）：

```swift
    public static func isRenderableSubType(_ sub: LineSubType, toolType: DrawingToolType) -> Bool {
        guard let rules = styleRules[toolType] else { return true }   // 表里没有 → 放行（与泛化前逐字等价）
        return rules.renderableLineSubType(sub)
    }
```

**3c. `toolsWithStyleMatrix` 改为派生**（原 `:30`）：

```swift
    static var toolsWithStyleMatrix: Set<DrawingToolType> { Set(styleRules.keys) }
```

**3d. `normalizedLabelMode`（三参 tool-aware 版）改查表**（原 `:58-62`）：

```swift
    public static func normalizedLabelMode(current: LabelMode, lineSubType: LineSubType,
                                           toolType: DrawingToolType) -> LabelMode {
        guard let rules = styleRules[toolType] else { return current }   // 表里没有 → 原样（与泛化前逐字等价）
        return rules.labelModeEnabled(current, lineSubType) ? current : .hidden
    }
```

**⛔ 不改的东西**（逐条确认）：
- `horizontalLineSubTypeEnabled` / `horizontalLabelModeEnabled` **函数体原地不动**（表只是引用它们）；
- `normalizedLabelMode(current:lineSubType:)` **两参横线版保留**（面板还在用，且守卫要求 `func normalizedLabelMode(` 恰好 2 处）；
- `isEditableToolType` **表达式一字不改**（它读的 `toolsWithStyleMatrix` 现在是派生值）；
- 文件里既有的头注 / `⚠️` 注释块**全部保留**（它们是承重的，源码守卫会读剥注释后的文本，但人要读原文）。

- [ ] **Step 4: 跑三套测试确认全绿**

```bash
cd "ios/Contracts" && swift test --filter "DrawingToolStyleMatrix|DrawingToolTypeCaseIterable" 2>&1 | tail -30
```

预期：
- `DrawingToolStyleMatrixTests` 7 个用例 **仍然全绿**（← 这是「行为一字未变」的直接证据）；
- `t2_singleSourceOfTruth` 由红转绿；
- `DrawingToolTypeCaseIterableTests` 3 个仍绿。

⚠️ 若真值表有任何一格由绿转红，**说明重构改变了行为** —— 回退这一步重做，不要去改测试。

- [ ] **Step 5: 逐个打开 7 个消费方复核调用形状未变（spec §3.3 要求，⛔ 不得只靠推理）**

**守则：「有 N 个调用点」≠「这 N 处语义都一样」，必须逐个打开看。** 本片**没有改任何函数签名**，故预期 7 处调用形状**一字不变**；这一步是确认这一点，不是改它们。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1c-1a"
sed -n '1157p;1265p;1193p;1299,1300p' ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
sed -n '17p;37p'                      ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift
sed -n '58p;65p'                      ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift
sed -n '81p'                          ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift
git diff origin/main -- ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/ ios/Contracts/Sources/KlineTrainerContracts/Models/DrawingEnums.swift ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingObjectStyleEdit.swift ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift | head -5
```

逐条核对（对照 spec §3.3 那张表）：
- `TrainingEngine.swift:1157` / `:1265` —— 两处 append 门仍是 `guard isRenderableSubType(drawing) else { return false }`；`:1299-1300` 私有 helper 仍转发到共享单点；`:1193` 编辑门仍调 `isEditableToolType`；
- `DrawingObjectStyleEdit.swift:17` —— `withStyle` 的可用性闸仍是 `guard DrawingStyleAvailability.isRenderableSubType(s.lineSubType, toolType: toolType) else { return nil }`；`:37` 仍调**三参** tool-aware 归一化；
- `DrawingEnums.swift:58` / `:65` —— `sanitized(for:)` 两处仍走共享单点；
- `DrawingEditRouter.swift:81` —— 仍调 `isEditableToolType`。

预期：最后那条 `git diff` **输出为空**（这四个文件本片一个字都没改）。

- [ ] **Step 6: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift
git commit -m "P1c-1 Task3：四处样式判据改成查同一张表（D117），行为逐格等价

新增 ToolStyleRules + styleRules（唯一登记处），四处改法：
- isRenderableSubType → 查表；表里没有 → return true（与泛化前逐字等价）
- normalizedLabelMode(三参) → 查表；表里没有 → 原样返回 current（同上）
- toolsWithStyleMatrix → Set(styleRules.keys) 派生，不再是第二份写死清单
- isEditableToolType → 表达式一字不改

⛔ 有效性列的语义严格限定为「该不该拒收数据」，不是 UI 灰态判据（D120，见表定义处的长注释）。
横线两条规则函数体原地保留、两参归一化保留（面板在用）。
T1 真值表 208 格重构前后全绿 = 行为一字未变。"
```

---

### Task 4: 两条边界守卫（有效性列未接 UI / 锚数没被顺手泛化）

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift`（追加两个 `@Test`）

**Interfaces:**
- Consumes: Task 3 产出的 `styleRules`；既有 `allSwiftFilesUnderSources()` / `squeeze()` / `squeezedText()`
- Produces: 无（纯守卫）

**Why：** D120 那个矛盾（箱体要么画不出、要么面板错误可点）**要到第 5 片才会暴露**；D119 的边界（锚数归第 4 片）**没有任何编译期约束**。这两条把它们变成**现在就会红**的机械判据。

- [ ] **Step 1: 追加两个守卫**

在 `DrawingToolStyleMatrixGuardTests.swift` 的 `t2_singleSourceOfTruth` 之后追加：

```swift
    @Test("T2b 有效性列没有被接到 UI 上（D120 的落地闸门）")
    func t2b_validityPredicateNotUsedByUI() throws {
        let files = try allSwiftFilesUnderSources()
        #expect(!files.isEmpty)

        var byFile: [String: Int] = [:]
        var uiHits: [String] = []
        for path in files {
            let n = try code(path).components(separatedBy: squeeze("isRenderableSubType(")).count - 1
            guard n > 0 else { continue }
            byFile[URL(fileURLWithPath: path).lastPathComponent] = n
            if path.contains("/Sources/KlineTrainerContracts/UI/") { uiHits.append(path) }
        }
        // ① **消费方恰好是这四个文件**（spec §5-T2b 的前半条）。
        //    ⛔⛔ 这里**不得**写成「这四个各自 != nil」的存在性检查 —— 本片首版就是那样写的，
        //       被对抗性评审用双臂变异实证打穿：存在性检查抓不到**多出来的第五个消费方**，
        //       守卫的有效覆盖面塌缩成「仅 Sources/KlineTrainerContracts/UI/ 一个目录」，
        //       而 D120 的第一现场在 `Render/KLineView+Drawing.swift:33`（按 toolType 决定画不画）。
        #expect(Set(byFile.keys) == ["TrainingEngine.swift", "DrawingObjectStyleEdit.swift",
                                     "DrawingEnums.swift", "DrawingStyleAvailability.swift"],
                "有效性判据的消费方不再恰好是那四处写入闸：\(byFile)")
        // ② UI 层零命中 —— 只为给最典型的违规一个可读文案；**覆盖面由 ① 承担**。
        #expect(uiHits.isEmpty, "有效性判据被接到 UI 层，违反 D120：\(uiHits)")
        // ③ 反向自检：两道 append 门**逐个**仍在（⛔ 不能只看该文件命中数非零：
        //    TrainingEngine.swift 有 4 处命中，:1299 是私有 helper 定义、:1300 是转发，
        //    把 :1157/:1265 两道门删光后计数仍为 2）。
        let engineCode = try squeezedSource(try fileNamed("TrainingEngine/TrainingEngine.swift", in: files))
        #expect(engineCode.components(separatedBy: squeeze("guard isRenderableSubType(drawing) else { return false }")).count - 1 == 2,
                "两道 append 门不再各自经共享单点（D67）")
    }

    @Test("T1f 边界：本片不碰锚数（D119）——定义仍只在输入控制器里，且它不引用样式表")
    func t1f_anchorCountBoundary() throws {
        let files = try allSwiftFilesUnderSources()
        #expect(!files.isEmpty)

        var defs: [String] = []
        for path in files where try code(path).contains(squeeze("func minAnchors(")) {
            defs.append(URL(fileURLWithPath: path).lastPathComponent)
        }
        // ① 锚数定义恰好一处，且仍在原文件
        #expect(defs == ["DefaultDrawingInputController.swift"], "锚数定义处异常：\(defs)")

        let ctrlPath = try fileNamed("Drawing/DefaultDrawingInputController.swift", in: files)
        let ctrl = try code(ctrlPath)
        // ② 该文件不得引用样式表 —— 锚数不是样式，单一真相归第 4 片的 requiredAnchors（D119/Q12）
        #expect(!ctrl.contains(squeeze("styleRules")), "锚数不得从样式表取值（D119 边界）")
        // ③ 反向自检：文件真被扫到（防「路径写错 → 零命中 → 恒过」）
        #expect(ctrl.contains(squeeze("func shouldCommit(")), "锚点失效：扫不到 shouldCommit")
    }
```

- [ ] **Step 2: 跑守卫确认全绿**

```bash
cd "ios/Contracts" && swift test --filter DrawingToolStyleMatrixGuardTests 2>&1 | tail -25
```

预期：3 个用例全部 passed。

- [ ] **Step 3: 亲手验证两条守卫真的有判别力（各变异一次）**

⚠️ 复原一律 `cp` 往返，**⛔ 禁止 `git checkout`**。

⚠️ **变异必须对准判据本身，⛔ 不得顺手弄坏语法或参数个数** —— 否则红的是编译错误而不是那条判据，等于没验。故变异 A 用**新增一个能编译的探针文件**（而不是去改面板里那个调用，那样会因缺参数直接编译失败）。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1c-1a/ios/Contracts"

# ── 变异 A：在 UI 目录里制造一个合法的有效性判据消费方（模拟 D120 被违反）
cat > Sources/KlineTrainerContracts/UI/__MutationProbe.swift <<'PROBE'
import Foundation
enum __MutationProbe {
    static func probe(_ s: LineSubType) -> Bool {
        DrawingStyleAvailability.isRenderableSubType(s, toolType: .horizontal)
    }
}
PROBE
swift test --filter t2b_validityPredicateNotUsedByUI 2>&1 | grep -E "^✘|passed|failed|违反 D120" | tail -8
rm Sources/KlineTrainerContracts/UI/__MutationProbe.swift        # 复原 = 删掉新增文件，不碰任何既有文件

# ── 变异 B：让输入控制器引用样式表（模拟 D119 边界被破）
C=Sources/KlineTrainerContracts/Drawing/DefaultDrawingInputController.swift
cp "$C" /tmp/ddic.bak
perl -0pi -e 's/guard DrawingToolType\.implemented\.contains\(tool\) else \{ return Int\.max \}/guard DrawingToolType.implemented.contains(tool), DrawingStyleAvailability.styleRules[tool] != nil else { return Int.max }/' "$C"
grep -c "styleRules" "$C"                                        # 必须为 1，确认变异真的落地了
swift test --filter t1f_anchorCountBoundary 2>&1 | grep -E "^✘|passed|failed|D119" | tail -8
cp /tmp/ddic.bak "$C"

# ── 复原后确认全绿 + 工作区干净
swift test --filter DrawingToolStyleMatrixGuardTests 2>&1 | tail -8
git status --porcelain
```

预期：
- 变异 A → 红的是 `t2b_validityPredicateNotUsedByUI`，消息里列出 `__MutationProbe.swift`；
- 变异 B → 红的是 `t1f_anchorCountBoundary`，消息为「锚数不得从样式表取值（D119 边界）」；⚠️ **先看 `grep -c` 输出为 1**，确认变异真的落地了再判读结果（等长/未生效的变异会给出方向相反的假结论）；
- 复原后两条都绿，`git status --porcelain` **输出为空**。

- [ ] **Step 4: 提交**

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolStyleMatrixGuardTests.swift
git commit -m "P1c-1 Task4：T2b（有效性列未接 UI）+ T1f（锚数边界）两条结构守卫

两条都配了反向自检：
- T2b 除「UI 零命中」外，还断言四处写入闸各自命中——否则「函数被整个删掉」也会全绿
- T1f 除「定义恰好一处」外，还断言目标文件确实被扫到（命中 func shouldCommit）

两条守卫各自做过一次变异验证（把有效性判据接进面板 / 让输入控制器引用样式表），
均按预期变红，复原后全绿、工作区干净。"
```

---

### Task 5: 三绿门 + 基线核对 + T4 变异验证

**Files:** 无（只跑闸门与变异；如需更新基线则改 `.github/scripts/catalyst-total-baseline.txt`）

**Interfaces:**
- Consumes: Task 1–4 的全部产物
- Produces: 一份可粘进 PR 描述的闸门证据

- [ ] **Step 1: host 全量测试（真跑）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1c-1a"
echo "BRANCH=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)"
cd ios/Contracts && set -o pipefail && swift test 2>&1 | tee /tmp/p1c1-host.log | tail -5
grep -cE "^✘|error:" /tmp/p1c1-host.log
```

预期：末行汇总显示 0 failures；`grep -c` 输出 `0`。
⚠️ **判绿读执行量与失败计数，不读「SUCCEEDED」字样，不用 `tail` 当判据。**

- [ ] **Step 2: T3 既有闸门逐条实跑（spec §5-T3 点名的八个文件）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1c-1a/ios/Contracts"
set -o pipefail && swift test --filter "DrawingObjectStyleEditTests|DrawingStyleAvailabilityTests|DrawingDefaultStyleSanitizeTests|DrawingEditRouterTests|DrawingStylePanelSourceGuardTests|DrawingProtocolTests|HorizontalLineToolTests" 2>&1 | tee /tmp/p1c1-t3.log | tail -6
grep -cE "^✘" /tmp/p1c1-t3.log
```

预期：`grep -c` 输出 `0`。**这一步是必须的，不得只靠推理** —— 新增的表是否把源码守卫的计数打乱，只有真跑才知道。

- [ ] **Step 3: Catalyst 真执行（⛔ 不得只 build-for-testing）+ 总数基线核对**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1c-1a"
echo "BRANCH=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)"
DD=$(mktemp -d)                       # ⛔ 专属 derivedDataPath，绝不删全局 DerivedData（本仓 20 个 worktree）
cd ios/Contracts && set -o pipefail && xcodebuild test \
  -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath "$DD" 2>&1 | tee /tmp/p1c1-catalyst.log | tail -5
bash ../../.github/scripts/catalyst-gate.sh /tmp/p1c1-catalyst.log
```

预期：闸门脚本自身判绿（它内含 TEST SUCCEEDED / 零编译错误 / 零 Sources 警告 / 用例数在基线 ±30 内 / UIKit 基线逐测试点名 五类判据）。

**⚠️ 若闸门因「用例数超出基线 ±30」而红**：本片新增用例（Task 1 三条 + Task 2 七条 + Task 4 三条 ≈ 13 个）本应落在窗口内；真超了就**更新 `.github/scripts/catalyst-total-baseline.txt` 为实测新总数**，并在 PR 描述里说明增量来源，**⛔ 不得放宽 delta**。

- [ ] **Step 4: T4 变异验证（三组，逐条记「红的是哪一条测试名」）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1c-1a/ios/Contracts"
A=Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift
cp "$A" /tmp/dsa.bak

# 变异 1：表里没有的工具 → 返回 false（应只红 T1b，不应红 T1a）
perl -0pi -e 's/else \{ return true \}   \/\/ 表里没有 → 放行/else { return false }   \/\/ MUT1/' "$A"
grep -c "MUT1" "$A"                                   # 必须为 1：确认变异真的落地了
swift test --filter DrawingToolStyleMatrixTests 2>&1 | grep -E "^✘|passed|failed" | tail -12
cp /tmp/dsa.bak "$A"

# 变异 2：表里没有的工具 → 落 .hidden（应只红 T1d）
perl -0pi -e 's/else \{ return current \}   \/\/ 表里没有 → 原样/else { return .hidden }   \/\/ MUT2/' "$A"
grep -c "MUT2" "$A"                                   # 必须为 1
swift test --filter DrawingToolStyleMatrixTests 2>&1 | grep -E "^✘|passed|failed" | tail -12
cp /tmp/dsa.bak "$A"

# 变异 3：表多加一行（应红「防空转②表的键恰好 {.horizontal}」+ 既有漂移告警 :82）
perl -0pi -e 's/(labelModeEnabled: horizontalLabelModeEnabled\),\n)/$1        .trend: ToolStyleRules(renderableLineSubType: horizontalLineSubTypeEnabled, labelModeEnabled: horizontalLabelModeEnabled),\n/' "$A"
grep -c "\.trend: ToolStyleRules" "$A"                # 必须为 1
swift test --filter "DrawingToolStyleMatrixTests|DrawingObjectStyleEditTests" 2>&1 | grep -E "^✘|passed|failed" | tail -14
cp /tmp/dsa.bak "$A"

swift test --filter DrawingToolStyleMatrixTests 2>&1 | tail -5     # 复原后必须全绿
git status --porcelain                                              # 必须为空
```

**⚠️ 必须逐条记录「红的是哪一条测试名」，「有测试变红」是假信号。** 预期：
- 变异 1 → 红的是 `t1b_renderableNonHorizontal`；**若 `t1a_renderableHorizontal` 也红，说明判据串了，停下查**；
- 变异 2 → 红的是 `t1d_normalizedNonHorizontal`；
- 变异 3 → 红的是 `tableHasExactlyOneRow` **且** `DrawingObjectStyleEditTests` 的漂移告警。

**⭐ 一条已识别的等价变异（登记在案，不算测试失效）**：把 `isEditableToolType` 的 `&&` 改成 `||` **预期不红** —— `implemented` 与 `toolsWithStyleMatrix` 今天恰好相等，没有任何输入能区分二者。该不变量由「表的键恰好是 `{.horizontal}`」（T1 防空转②）+ 既有漂移告警 `DrawingObjectStyleEditTests.swift:82` 共同承担。**⛔ 不得因此去「加强」T1e —— 它测的是结果值，是对的。**

- [ ] **Step 5: 提交闸门证据（若基线需要更新才有文件改动）**

```bash
git status --porcelain    # 若为空则跳过本步；若只有 catalyst-total-baseline.txt 则提交它
git add -A && git commit -m "P1c-1 Task5：三绿门实跑通过 + 同步 Catalyst 总用例数基线

host swift test 全量 0 失败；T3 八个既有测试文件逐条实跑 0 失败；
Catalyst xcodebuild test 真执行 + catalyst-gate.sh 五类判据全绿。
T4 三组变异逐条关门看红，红的分别是 t1b / t1d / tableHasExactlyOneRow+漂移告警；
另登记一条已识别的等价变异（isEditableToolType 的 && → ||，预期不红）。"
```

---

### Task 6: 非程序员验收清单

**Files:**
- Create: `docs/superpowers/acceptance/2026-09-01-drawing-p1c-1-tool-matrix.md`

**Interfaces:**
- Consumes: spec §6 的骨架
- Produces: 交付物之一（治理要求每片必带）

- [ ] **Step 1: 写验收清单**

```bash
mkdir -p docs/superpowers/acceptance
```

新建 `docs/superpowers/acceptance/2026-09-01-drawing-p1c-1-tool-matrix.md`：

```markdown
# 验收清单：划线 P1c 第 1 片（样式矩阵结构泛化）

**这一片改了什么**：只改了程序内部的组织方式 —— 把「本版本懂每种画线工具的哪些样式」从散在四处的写法，收成一张表。
**你应该看到什么**：**什么变化都没有。** 下面每一条的通过标准都是「跟以前一模一样」。

> ⚠️ **只要有任何一条「跟以前不一样」，就是不通过。**

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 1 | 进入训练，画三条水平线 | 与本片之前**完全一样**，能正常画出来 | ☐ 通过 ☐ 不通过 |
| 2 | 选中其中一条，把颜色、粗细、线样式各改一遍 | 与本片之前**完全一样**，改哪个变哪个 | ☐ 通过 ☐ 不通过 |
| 3 | 在样式面板里点「线型」那一组 | 「直线」「射线」可选，**「线段」是灰的** —— 与本片之前一模一样 | ☐ 通过 ☐ 不通过 |
| 4 | 选「射线」之后再看「标注」那一组 | **「左」变灰**；若原来选的就是「左」，会自动回到「隐藏」—— 与本片之前一模一样 | ☐ 通过 ☐ 不通过 |
| 5 | 锁定一条线、解锁、删除、撤销 | 与本片之前**完全一样** | ☐ 通过 ☐ 不通过 |
| 6 | 打完一整局并结算入账 | 与本片之前**完全一样**，能正常写进历史记录 | ☐ 通过 ☐ 不通过 |
| 7 | 打开历史记录做一次复盘，在复盘里画线、改样式 | 与本片之前**完全一样** | ☐ 通过 ☐ 不通过 |
| 8 | 退出 App 再进来，看上面画的线还在不在、样式对不对 | 与本片之前**完全一样**，一条不少、一字不差 | ☐ 通过 ☐ 不通过 |

**验收环境提醒**：真机验收需 Debug 构建并带 `KLINE_SEED_FIXTURE=1`（否则会因训练组文件不存在而报错 —— 那是环境缺口，不是本片的回归）。
```

- [ ] **Step 2: 提交**

```bash
git add docs/superpowers/acceptance/2026-09-01-drawing-p1c-1-tool-matrix.md
git commit -m "P1c-1 Task6：非程序员验收清单（8 条，全部预期「跟以前一模一样」）"
```

---

## 交付前最后动作（不属于任何 Task）

- [ ] **整支评审**：`.claude/scripts/codex-attest.sh --scope branch-diff --head feat/drawing-p1c-1a --base origin/main`
  ⛔ 不得传任何未知参数（含 `--help`）。判绿三项：日志有 `Verdict:` 行 / **无** `Turn failed` / 脚本打印了 `[codex-attest] verdict=…` 收尾行 —— 三项缺一即不算一轮，重跑。
- [ ] **push 与开 PR 由 user 在自己终端执行**（本仓账本不跨 worktree）。给 user 的命令**超过一行一律落成 `/tmp/*.sh`**。
- [ ] PR 标题与正文用**中文**。
