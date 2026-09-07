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
