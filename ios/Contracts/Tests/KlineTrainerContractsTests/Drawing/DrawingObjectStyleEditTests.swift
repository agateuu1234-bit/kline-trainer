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
        // 保留：old.textColorToken(.blue) != old.colorToken(.orange)（known 独立字色）
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
        // ⚠️ 断言**具体期望值**，别复述实现（Opus-F7）：旧写法 `== (implemented ∧ matrix)` 是实现复述，
        //    改实现它跟着改、永远不红；新写法钉死具体值，任一集合被误扩当场红。
        //    ⚠️ 但**别过度宣称**（Opus 复核-N4）：两个集合今天恰好相等，`∧` 换成 `∨` 对所有 case 结果一致，
        //    **没有测试能区分它俩**——维持这个前提靠的是下面那条「两集合相等」的漂移告警。
        #expect(A.isEditableToolType(.horizontal) == true)
        for t: DrawingToolType in [.trend, .text, .ray, .fib, .rect] {
            #expect(A.isEditableToolType(t) == false, "\(t) 本构建没有样式矩阵，不得可编辑")
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

    @Test("归一化 tool-aware 的**行为**（Opus-F1）：非水平工具经 withStyle 后 labelMode 不被横线规则改写")
    func withStylePreservesNonHorizontalLabelMode() throws {
        // R2-F2 那个 bug 的**红绿验**：若 withStyle 改调两参横线版，`.left` 会被归一成 `.hidden`，当场红。
        // （`withStyle` 不含工具门——工具门在 `updateDrawingStyle`，R15-F2——故 `.trend` 走得到这里。）
        let trend = DrawingObject(id: "t", toolType: .trend,
                                  anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                                  isExtended: false, panelPosition: 0, period: .daily)
        #expect(trend.withStyle(style(.ray, .solid, 1, .orange, .left))?.labelMode == .left)
        #expect(trend.withStyle(style(.straight, .solid, 1, .orange, .show))?.labelMode == .show)
        let h = makeStyledHLine(id: "h")
        #expect(h.withStyle(style(.ray, .solid, 1, .orange, .left))?.labelMode == .hidden)   // 对照：横线仍归一
    }

    @Test("归一化 tool-aware（codex plan-R2-F2）：横规则只对横工具成立")
    func labelModeNormalizationIsToolAware() throws {
        typealias A = DrawingStyleAvailability
        // 直调重载本身（Opus 复核-N5 更正）：`withStyle` **不含**工具门（R15-F2 已挪到 `updateDrawingStyle`），
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
