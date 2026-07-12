// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingToolManagerTests.swift
// Spec: docs/superpowers/specs/2026-05-26-pr-c6-drawing-tools-infrastructure.md §5.1
// 10 Manager state-machine tests. All pure state assertions; no dispatch spy / no revision spy.
// 跨平台：DrawingToolManager 不依赖 UIKit；tests 在 macOS host swift test 跑得通。

import Testing
@testable import KlineTrainerContracts

@MainActor
struct DrawingToolManagerTests {

    private func makeAnchor(_ price: Double = 100) -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 0, price: price)
    }

    @Test("§5.1 #1 first toggle activates tool, pendingAnchors stays empty")
    func toggleFirstActivatesTool() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        #expect(m.activeTool == .horizontal)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.isEmpty)
    }

    @Test("§5.1 #2 same-tool re-toggle deactivates")
    func toggleSameToolDeactivates() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.toggle(.horizontal)
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
    }

    @Test("§5.1 #3 different-tool toggle overrides and clears pending")
    func toggleDifferentToolOverridesAndClearsPending() {
        let m = DrawingToolManager(enabledTools: [.horizontal, .ray])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.toggle(.ray)
        #expect(m.activeTool == .ray)
        #expect(m.pendingAnchors.isEmpty)
    }

    @Test("§5.1 #4 toggling disabled tool is no-op")
    func toggleDisabledToolIsNoOp() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.ray)  // ray NOT in enabledTools
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.enabledTools == [.horizontal])
    }

    @Test("§5.1 #5 addAnchor appends to pendingAnchors")
    func addAnchorAppends() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        let a = makeAnchor(150)
        m.addAnchor(a)
        #expect(m.pendingAnchors.count == 1)
        #expect(m.pendingAnchors[0] == a)
    }

    @Test("§5.1 #6 commit moves drawing to completed and resets active/pending")
    func commitMovesToCompletedAndResets() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        let a = makeAnchor(180)
        m.addAnchor(a)
        m.commit()
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.count == 1)
        #expect(m.completedDrawings[0].toolType == .horizontal)
        #expect(m.completedDrawings[0].anchors == [a])
        #expect(m.completedDrawings[0].isExtended == false)
        #expect(m.completedDrawings[0].panelPosition == 0)
    }

    @Test("§5.1 #7 explicit cancel resets active and pending; completed untouched")
    func cancelExplicitResetsActiveAndPending() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.commit()
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor(200))
        m.cancel()
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.count == 1)  // prior commit preserved
    }

    @Test("§5.1 #8 cancel is idempotent no-op when activeTool == nil")
    func cancelIdempotentNoChange() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.cancel()
        #expect(m.activeTool == nil)
        #expect(m.pendingAnchors.isEmpty)
        #expect(m.completedDrawings.isEmpty)
        #expect(m.enabledTools == [.horizontal])
    }

    @Test("§5.1 #9 deleteDrawing removes at index, preserves order")
    func deleteDrawingRemovesAtIndex() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        for price in [100.0, 150.0, 200.0] {
            m.toggle(.horizontal)
            m.addAnchor(makeAnchor(price))
            m.commit()
        }
        #expect(m.completedDrawings.count == 3)
        m.deleteDrawing(at: 1)
        #expect(m.completedDrawings.count == 2)
        #expect(m.completedDrawings[0].anchors[0].price == 100)
        #expect(m.completedDrawings[1].anchors[0].price == 200)
    }

    @Test("§5.1 #10 enabledTools defaults to empty set; explicit init injects 7")
    func enabledToolsDefaultsToEmptySet() {
        let m1 = DrawingToolManager()
        #expect(m1.enabledTools.isEmpty)
        let all: Set<DrawingToolType> = [.ray, .trend, .horizontal, .golden, .wave, .cycle, .time]
        let m2 = DrawingToolManager(enabledTools: all)
        #expect(m2.enabledTools.count == 7)
    }

    // codex branch-R5 high：commit 旧签名收 `isExtended: Bool`，却从不传 lineSubType（init 默认 .straight）
    // → caller 传 isExtended:true 会存出「isExtended=true + lineSubType=.straight」的矛盾数据
    // （legacy 派生是 `lineSubType = isExtended ? .ray : .straight`，二者语义必须一致）。
    // 新签名改收 lineSubType 并【派生】isExtended，使矛盾在唯一写入点【不可表达】。
    @Test("§5.1 #11 commit(lineSubType: .ray) 派生 isExtended=true（codex branch-R5：二者不得矛盾）")
    func commitWithRayDerivesIsExtended() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.commit(lineSubType: .ray, panelPosition: 0)
        #expect(m.completedDrawings.count == 1)
        #expect(m.completedDrawings[0].lineSubType == .ray)
        #expect(m.completedDrawings[0].isExtended == true)
        #expect(m.completedDrawings[0].panelPosition == 0)
    }

    @Test("§5.1 #12 commit(lineSubType: .straight, panelPosition: 1) 派生 isExtended=false")
    func commitWithLowerPanelCarriesMetadata() {
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.commit(lineSubType: .straight, panelPosition: 1)
        #expect(m.completedDrawings.count == 1)
        #expect(m.completedDrawings[0].panelPosition == 1)
        #expect(m.completedDrawings[0].lineSubType == .straight)
        #expect(m.completedDrawings[0].isExtended == false)
    }

    @Test("不变量（codex branch-R5 high）：任何 commit 产出的对象都满足 isExtended == (lineSubType == .ray)")
    func commitAlwaysKeepsIsExtendedConsistentWithSubType() {
        for sub in LineSubType.allCases {
            let m = DrawingToolManager(enabledTools: [.horizontal])
            m.toggle(.horizontal)
            m.addAnchor(makeAnchor())
            m.commit(lineSubType: sub, panelPosition: 0)
            let d = m.completedDrawings[0]
            #expect(d.lineSubType == sub)
            #expect(d.isExtended == (sub == .ray))
        }
        // 默认（本期 tap 路径走的就是默认）→ .straight + isExtended=false，自洽
        let m = DrawingToolManager(enabledTools: [.horizontal])
        m.toggle(.horizontal)
        m.addAnchor(makeAnchor())
        m.commit()
        #expect(m.completedDrawings[0].lineSubType == .straight)
        #expect(m.completedDrawings[0].isExtended == false)
    }
}
