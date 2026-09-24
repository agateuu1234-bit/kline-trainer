import Testing
import Foundation
import CoreGraphics
@testable import KlineTrainerContracts

@MainActor
@Suite("DrawingNodeGeometry")
struct DrawingNodeGeometryTests {

    /// 与 HorizontalLineToolTests 同量纲：mainChartFrame x∈[0,800] y∈[0,360]，price∈[10,20]，candleStep=10。
    static func mapper(startIndex: Int = 0) -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: startIndex, visibleCount: 80, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    static func line(idx: Int, price: Double = 15, sub: LineSubType = .straight) -> DrawingObject {
        DrawingObject(toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .m3, candleIndex: idx, price: price)],
                      isExtended: sub == .ray, panelPosition: 0, lineSubType: sub)
    }

    @Test("T2：登记表漂移告警是集合等式（两个方向都成立，⛔ 不是存在性检查）")
    func nodeTableIsSetEquality() {
        #expect(DrawingToolType.implemented == DrawingNodeGeometry.toolsWithNodes,
                "有工具画得出却没登记节点（或反之）：implemented=\(DrawingToolType.implemented) nodes=\(DrawingNodeGeometry.toolsWithNodes)")
        #expect(DrawingNodeGeometry.toolsWithNodes == [.horizontal],
                "P1c 第 2 片表里只应有水平线一行（D122）")
    }

    /// ⚠️ D132 后语义上是**四态**；对**单锚**工具，「线不可见」与「该锚点自身画不出」
    /// 两态都表现为空数组，故这里可观察到的仍是三种。第四态（锚点自身画不出）
    /// 由 `malformedAnchorsProduceNoPhantomNodes` 的 ③④ 档单独覆盖。
    @Test("T1：结果互斥且穷尽 —— 任给输入恰好命中一种，且每种都出现过")
    func threeOutcomesAreMutuallyExclusiveAndExhaustive() {
        let m = Self.mapper()
        var seenNone = false, seenReal = false, seenProxy = false
        var cases = 0
        // idx=5 → x=50（屏内）；idx=-50 → x=-500（左外）；idx=500 → x=5000（右外）
        for idx in [5, -50, 500] {
            for price in [15.0, 25.0] {           // 15 在区间内、25 在区间外（线不可见）
                for vis in [true, false] {
                    let marks = DrawingNodeGeometry.marks(for: Self.line(idx: idx, price: price),
                                                          mapper: m, isVisible: vis, maxAnchors: 1)
                    let isNone  = marks.isEmpty
                    var isReal = false, isProxy = false
                    if marks.count == 1 {
                        if case .real  = marks[0] { isReal  = true }
                        if case .proxy = marks[0] { isProxy = true }
                    }
                    #expect([isNone, isReal, isProxy].filter { $0 }.count == 1,
                            "三态必须恰好命中一种：idx=\(idx) price=\(price) vis=\(vis) marks=\(marks)")
                    seenNone = seenNone || isNone; seenReal = seenReal || isReal; seenProxy = seenProxy || isProxy
                    cases += 1
                }
            }
        }
        #expect(cases == 12, "必须真的跑满 12 格")
        // ⭐ 判别力：三种都必须真的出现过，否则「恰好命中一种」可能因为恒返同一种而全绿
        #expect(seenNone && seenReal && seenProxy,
                "三态必须都出现过：none=\(seenNone) real=\(seenReal) proxy=\(seenProxy)")
    }

    @Test("N4：真节点坐标 ≡ 锚点经 mapper 的投影（先断言个数，防空数组恒真）")
    func realNodeEqualsAnchorProjection() {
        let m = Self.mapper()
        let d = Self.line(idx: 5)
        let marks = DrawingNodeGeometry.marks(for: d, mapper: m, isVisible: true, maxAnchors: 1)
        #expect(marks.count == d.anchors.count, "节点个数必须等于锚点个数（否则下面逐个比较恒真）")
        guard case let .real(i, p) = marks[0] else {
            Issue.record("屏内锚点必须产生真节点，实得 \(marks[0])"); return
        }
        #expect(i == 0, "必须是原 anchors 下标")
        #expect(p.x == m.indexToX(d.anchors[0].candleIndex))
        #expect(p.y == m.priceToY(d.anchors[0].price))
    }

    @Test("⭐T4：出屏锚点绝不被 clamp 成真节点（D123 硬约束的守卫）")
    func offscreenAnchorNeverBecomesRealNode() {
        let m = Self.mapper()
        for idx in [-50, -1, 81, 500] {     // x = -500, -10, 810, 5000，全在 [0,800] 之外
            let marks = DrawingNodeGeometry.marks(for: Self.line(idx: idx), mapper: m, isVisible: true, maxAnchors: 1)
            #expect(marks.count == 1, "线可见时必须产生恰好一个记号：idx=\(idx)")
            if case .real = marks[0] {
                Issue.record("idx=\(idx)：出屏锚点被画成了真节点 —— 真节点被挪到了不属于它的 K 线上（D123 硬约束破坏）")
            }
        }
        // 正向对照：屏内锚点确实产生真节点 ⇒ 证明上面不是因为恒不产生 .real 而绿
        let inside = DrawingNodeGeometry.marks(for: Self.line(idx: 5), mapper: m, isVisible: true, maxAnchors: 1)
        if case .real = inside[0] {} else { Issue.record("正向对照失败：屏内锚点必须是真节点") }
    }

    @Test("T3：代理标记的朝向与落点 —— 左外朝左贴左框、右外朝右贴右框（两个方向各自单独断言）")
    func proxyMarkSideAndDirection() {
        let m = Self.mapper()
        let frame = m.viewport.mainChartFrame
        // 左外
        guard case let .proxy(li, lp, lLeft) = DrawingNodeGeometry.marks(
            for: Self.line(idx: -50), mapper: m, isVisible: true, maxAnchors: 1)[0] else {
            Issue.record("左外锚点必须产生代理标记"); return
        }
        #expect(li == 0); #expect(lp.x == frame.minX, "左外必须贴左边框"); #expect(lLeft == true, "左外必须朝左")
        // 右外
        guard case let .proxy(ri, rp, rLeft) = DrawingNodeGeometry.marks(
            for: Self.line(idx: 500), mapper: m, isVisible: true, maxAnchors: 1)[0] else {
            Issue.record("右外锚点必须产生代理标记"); return
        }
        #expect(ri == 0); #expect(rp.x == frame.maxX, "右外必须贴右边框"); #expect(rLeft == false, "右外必须朝右")
        // 两者的 y 都等于该锚点的价位投影（与线同高）
        #expect(lp.y == m.priceToY(15)); #expect(rp.y == m.priceToY(15))
    }

    @Test("N6：线不可见 → 节点与代理标记都不画（三者同进同退）")
    func invisibleLineDrawsNothing() {
        let m = Self.mapper()
        for idx in [5, -50, 500] {
            #expect(DrawingNodeGeometry.marks(for: Self.line(idx: idx), mapper: m, isVisible: false, maxAnchors: 1).isEmpty,
                    "不可见时必须一个记号都不产生：idx=\(idx)")
        }
        // 正向对照：同样的输入在可见时产生记号 ⇒ 证明不是因为函数恒返空而绿
        #expect(!DrawingNodeGeometry.marks(for: Self.line(idx: 5), mapper: m, isVisible: true, maxAnchors: 1).isEmpty)
    }

    @Test("登记表之外的工具不产生任何节点（本片只登记水平线）")
    func unregisteredToolHasNoNodes() {
        let m = Self.mapper()
        let trend = DrawingObject(toolType: .trend,
                                  anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 15)],
                                  isExtended: false, panelPosition: 0)
        #expect(DrawingNodeGeometry.marks(for: trend, mapper: m, isVisible: true, maxAnchors: 1).isEmpty,
                ".trend 未登记，不得产生节点")
    }

    @Test("N5：节点跟着视口走 —— 平移与缩放后各自等于【当时那个 mapper】的投影")
    func nodeFollowsViewport() {
        let d = Self.line(idx: 20)
        // ① 平移：startIndex 0 → 10，锚点 x 必须真的左移 100pt
        let m0 = Self.mapper(startIndex: 0), m1 = Self.mapper(startIndex: 10)
        guard case let .real(_, p0) = DrawingNodeGeometry.marks(for: d, mapper: m0, isVisible: true, maxAnchors: 1)[0],
              case let .real(_, p1) = DrawingNodeGeometry.marks(for: d, mapper: m1, isVisible: true, maxAnchors: 1)[0] else {
            Issue.record("两档都必须是真节点"); return
        }
        #expect(p0.x != p1.x, "⭐ 平移后节点 x 必须真的变了，否则下面的等式可能因为节点被写死而恒真")
        #expect(p0.x == m0.indexToX(20) && p1.x == m1.indexToX(20),
                "每一档都必须等于【那一档自己的】mapper 投影（不得停在旧视口）")
        #expect(p1.x - p0.x == -100, "startIndex +10 × candleStep 10 ⇒ 左移 100pt，实得 \(p1.x - p0.x)")
        // ② 缩放：candleStep 10 → 5，同一根 K 线的 x 必须随之减半
        let mZoom = CoordinateMapper(viewport: ChartViewport(
            startIndex: 0, visibleCount: 160, pixelShift: 0,
            geometry: ChartGeometry(candleStep: 5, candleWidth: 3, gap: 2),
            priceRange: PriceRange(min: 10, max: 20),
            mainChartFrame: CGRect(x: 0, y: 0, width: 800, height: 360)), displayScale: 2.0)
        guard case let .real(_, pz) = DrawingNodeGeometry.marks(for: d, mapper: mZoom, isVisible: true, maxAnchors: 1)[0] else {
            Issue.record("缩放档必须是真节点"); return
        }
        #expect(pz.x == mZoom.indexToX(20) && pz.x != p0.x, "缩放后节点 x 必须跟着新的 candleStep 走")
        // ③ 节点 y 与线 y 同源（F2）：两档的 y 都等于同一个 priceToY
        #expect(p0.y == m0.priceToY(15) && p1.y == m1.priceToY(15))
    }

    @Test("T7：.ray 锚点滚出右缘 → 整条线不画，因此也没有代理标记")
    func rayBeyondRightEdgeDrawsNothing() {
        let m = Self.mapper()
        let tool = HorizontalLineTool()
        let rayOut = Self.line(idx: 500, sub: .ray)          // x = 5000 > frame.maxX = 800
        #expect(tool.isVisible(drawing: rayOut, mapper: m) == false,
                "前提：.ray 锚点超右缘时 lineXRange 返 nil ⇒ 线不可见")
        #expect(DrawingNodeGeometry.marks(for: rayOut, mapper: m,
                                          isVisible: tool.isVisible(drawing: rayOut, mapper: m), maxAnchors: 1).isEmpty,
                "线都不画了，节点与代理标记也一个都不许有")
        // 正向对照：同一条 .ray 锚点在框内 ⇒ 线可见且有真节点 ⇒ 证明上面不是恒空
        let rayIn = Self.line(idx: 5, sub: .ray)
        #expect(tool.isVisible(drawing: rayIn, mapper: m) == true)
        guard case .real = DrawingNodeGeometry.marks(for: rayIn, mapper: m, isVisible: true, maxAnchors: 1)[0] else {
            Issue.record("正向对照：框内 .ray 必须有真节点"); return
        }
    }

    @Test("⭐T11：极端 candleIndex 不得让节点投影崩溃（磁盘解码零范围校验）")
    func extremeCandleIndexDoesNotTrap() {
        // startIndex 为【正】—— 与 Int.min 相减即下溢。这正是 evaluation R3-high 指的构造。
        let m = Self.mapper(startIndex: 10)
        for (idx, expectLeft) in [(Int.min, true), (Int.max, false)] {
            let d = DrawingObject(toolType: .horizontal,
                                  anchors: [DrawingAnchor(period: .m3, candleIndex: idx, price: 15)],
                                  isExtended: false, panelPosition: 0)
            let marks = DrawingNodeGeometry.marks(for: d, mapper: m, isVisible: true, maxAnchors: 1)   // ⛔ 不得 trap
            #expect(marks.count == 1, "极端 candleIndex 仍须产出恰好一个记号：idx=\(idx)")
            guard case let .proxy(_, _, left) = marks[0] else {
                Issue.record("idx=\(idx)：极端锚点必须按「极远处」产出代理标记，实得 \(marks[0])"); return
            }
            #expect(left == expectLeft, "Int.min 应朝左、Int.max 应朝右：idx=\(idx) 实得 pointingLeft=\(left)")
        }
        // ⭐ 正向对照：普通 candleIndex 仍产出真节点 ⇒ 证明不是靠「一律返回代理标记」蒙混
        let normal = DrawingNodeGeometry.marks(for: Self.line(idx: 15), mapper: m, isVisible: true, maxAnchors: 1)
        guard case .real = normal[0] else {
            Issue.record("正向对照：普通锚点必须仍是真节点"); return
        }
    }

    @Test("⭐T12：畸形持久化数据不得产出幽灵节点（锚点数 / price 有限性，D132）")
    func malformedAnchorsProduceNoPhantomNodes() {
        let m = Self.mapper()
        /// 造一条**畸形**水平线：解码层对 anchors 数组长度零校验，故两个锚点是可从磁盘进来的。
        func twoAnchorLine(secondPrice: Double) -> DrawingObject {
            DrawingObject(toolType: .horizontal,
                          anchors: [DrawingAnchor(period: .m3, candleIndex: 5,  price: 15),
                                    DrawingAnchor(period: .m3, candleIndex: 40, price: secondPrice)],
                          isExtended: false, panelPosition: 0)
        }
        // ① 第二锚价位【在图内】(12，区间 10...20) —— 若不截断，它会在一个不相干的价位上冒出第二个节点
        let inChart = twoAnchorLine(secondPrice: 12)
        let m1 = DrawingNodeGeometry.marks(for: inChart, mapper: m, isVisible: true, maxAnchors: 1)
        #expect(m1.count == 1, "水平线只消费 anchors.first ⇒ 必须只产生 1 个记号，实得 \(m1.count)")
        // ⚠️ 命中侧的断言在 Task 3（`hitTestNode` 那时才存在）—— 见 `malformedAnchorsAreNotHittable`
        // ② 第二锚价位【在图外】(999) —— 渲染会被裁掉，若命中侧仍认它就直接违反 D131
        let offChart = twoAnchorLine(secondPrice: 999)
        let m2 = DrawingNodeGeometry.marks(for: offChart, mapper: m, isVisible: true, maxAnchors: 1)
        #expect(m2.count == 1, "实得 \(m2.count)")
        if case let .real(i, _) = m2[0] { #expect(i == 0, "留下的必须是第 0 个锚点") }
        // ③ price 为 NaN / ±Inf —— 解码零校验，可从磁盘进来
        for bad in [Double.nan, .infinity, -.infinity] {
            let d = DrawingObject(toolType: .horizontal,
                                  anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: bad)],
                                  isExtended: false, panelPosition: 0)
            #expect(DrawingNodeGeometry.marks(for: d, mapper: m, isVisible: true, maxAnchors: 1).isEmpty,
                    "price=\(bad) 的锚点画不出来 ⇒ 不得产生任何记号")
        }
        // ④ 锚点 y 在图外（price 25 超出 10...20）→ 不产生记号
        let offY = DrawingObject(toolType: .horizontal,
                                 anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: 25)],
                                 isExtended: false, panelPosition: 0)
        #expect(DrawingNodeGeometry.marks(for: offY, mapper: m, isVisible: true, maxAnchors: 1).isEmpty)
        // ⭐ 正向对照（⛔ 不可省）：把畸形部分换成正常值，记号数与命中结果【随之改变】
        //    没有这一条，上面所有「== 1」「isEmpty」都可能只是函数恒返固定结果
        let healthy = Self.line(idx: 5)
        let mh = DrawingNodeGeometry.marks(for: healthy, mapper: m, isVisible: true, maxAnchors: 1)
        #expect(mh.count == 1, "正常线必须产生 1 个记号 ⇒ 证明上面那些 isEmpty 不是因为函数恒返空")
        // ⑤ maxAnchors 真的在起作用：同一条畸形线放开到 2 ⇒ 记号数变成 2
        #expect(DrawingNodeGeometry.marks(for: inChart, mapper: m, isVisible: true, maxAnchors: 2).count == 2,
                "⭐ 证明截断是 maxAnchors 在管，而不是函数恒返 1 个")
    }
    /// T9 需要把锚点精确放在「出边框 N pt」处。indexToX(i) = i*candleStep + pixelShift，
    /// 故用 pixelShift 做亚格微调（candleStep=10 无法整除出 1pt 的偏移）。
    static func mapperShifted(_ pixelShift: CGFloat) -> CoordinateMapper {
        let main = CGRect(x: 0, y: 0, width: 800, height: 360)
        let vp = ChartViewport(
            startIndex: 0, visibleCount: 80, pixelShift: pixelShift,
            geometry: ChartGeometry(candleStep: 10, candleWidth: 7, gap: 3),
            priceRange: PriceRange(min: 10, max: 20), mainChartFrame: main)
        return CoordinateMapper(viewport: vp, displayScale: 2.0)
    }

    // MARK: - 内层（N7）

    @Test("N7：命中半径内 / 外各一档")
    func nearestNodeRespectsRadius() {
        let n = [(index: 0, at: CGPoint(x: 100, y: 100))]
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 110, y: 100), among: n, radius: 11) == 0,
                "距离 10 < 11 必须命中")
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 112, y: 100), among: n, radius: 11) == nil,
                "距离 12 > 11 必须不命中")
    }

    @Test("N7：两个靠得很近的节点 —— 取距离最近者（不依赖遍历顺序）")
    func nearestNodePicksClosest() {
        let n = [(index: 0, at: CGPoint(x: 100, y: 100)), (index: 1, at: CGPoint(x: 104, y: 100))]
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 101, y: 100), among: n, radius: 11) == 0)
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 103, y: 100), among: n, radius: 11) == 1)
        // 倒序喂同样的两个节点，答案必须不变 ⇒ 证明它不是靠数组顺序
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 101, y: 100),
                                                among: Array(n.reversed()), radius: 11) == 0)
    }

    @Test("N7：距离相等时取【原下标】较小者 —— 同时钉死返回的是原下标而非数组位置")
    func nearestNodeTieBreaksOnOriginalIndex() {
        // 故意让数组顺序与原下标相反：数组第 0 位的原下标是 7，第 1 位才是 3
        let n = [(index: 7, at: CGPoint(x: 100, y: 100)), (index: 3, at: CGPoint(x: 110, y: 100))]
        #expect(DrawingNodeGeometry.nearestNode(to: CGPoint(x: 105, y: 100), among: n, radius: 11) == 3,
                "距离都是 5 ⇒ 必须取原下标小的 3；若返回 7 说明按数组位置破的平局，若返回 0/1 说明返回的是数组位置")
    }

    // MARK: - 外层（T5 / T8 / T9）

    @Test("T5：可见真实节点附近，凡线命中的点节点也命中（前提限定为「可见真实节点」）")
    func visibleNodeCoversLineHitsNearby() {
        let m = Self.mapper()
        let d = Self.line(idx: 5)                      // x = 50，屏内
        let tool = HorizontalLineTool()
        #expect(tool.isVisible(drawing: d, mapper: m), "前提①：本例的线必须可见")
        guard case let .real(_, center) = DrawingNodeGeometry.marks(for: d, mapper: m, isVisible: true, maxAnchors: 1)[0] else {
            Issue.record("前提②：本例必须有可见真实节点"); return
        }
        var lineHits = 0
        for dx in stride(from: -8.0, through: 8.0, by: 2.0) {
            for dy in stride(from: -8.0, through: 8.0, by: 2.0) {
                guard dx*dx + dy*dy <= 64 else { continue }          // 半径 8 的圆盘（= 线容差）
                let p = CGPoint(x: center.x + dx, y: center.y + dy)
                guard tool.hitTest(point: p, mapper: m, drawing: d) else { continue }
                lineHits += 1
                #expect(DrawingNodeGeometry.hitTestNode(point: p, drawing: d, mapper: m, isVisible: true, maxAnchors: 1) == 0,
                        "线命中却节点不命中：p=\(p)")
            }
        }
        #expect(lineHits > 0, "⭐ 采样点里必须真的有线命中的，否则上面的蕴含式恒真")
    }

    @Test("T8：代理标记不参与命中 —— 同一条线把锚点移回屏内则有答案")
    func proxyMarkIsNotHittable() {
        let mOut = Self.mapperShifted(9)                 // idx=-1 → x = -10+9 = -1（出左缘 1pt）
        let d = Self.line(idx: -1)
        let probe = CGPoint(x: 0, y: mOut.priceToY(15))  // 正是代理标记所在处（贴左边框）
        #expect(DrawingNodeGeometry.hitTestNode(point: probe, drawing: d, mapper: mOut, isVisible: true, maxAnchors: 1) == nil,
                "代理标记处必须无答案")
        // 正向对照：同一条线、同一个探针点，把视口挪到让锚点恰好落在边框上 ⇒ 变成真节点 ⇒ 有答案
        let mIn = Self.mapperShifted(10)                 // idx=-1 → x = -10+10 = 0（恰在左边框上）
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 0, y: mIn.priceToY(15)),
                                                drawing: d, mapper: mIn, isVisible: true, maxAnchors: 1) == 0,
                "⭐ 正向对照：锚点回到屏内必须有答案，否则上面那条只是因为函数恒返空")
    }

    @Test("⭐T9：锚点出左/右边缘 1/8/11pt 共 6 档，在代理标记处命中均为空（+ 边框上的正向对照）")
    func offscreenAnchorIsNeverHittableAtAnyDistance() {
        // 左侧：idx=-1 → x = -10 + shift。要 x = -1/-8/-11 ⇒ shift = 9/2/-1
        for (shift, expectedX) in [(9.0, -1.0), (2.0, -8.0), (-1.0, -11.0)] {
            let m = Self.mapperShifted(CGFloat(shift))
            let d = Self.line(idx: -1)
            #expect(m.indexToX(-1) == CGFloat(expectedX), "构造自检：锚点 x 必须真的是 \(expectedX)")
            #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 0, y: m.priceToY(15)),
                                                    drawing: d, mapper: m, isVisible: true, maxAnchors: 1) == nil,
                    "左外 \(expectedX)pt：代理标记处必须无答案")
        }
        // 右侧：idx=80 → x = 800 + shift。要 x = 801/808/811 ⇒ shift = 1/8/11
        for (shift, expectedX) in [(1.0, 801.0), (8.0, 808.0), (11.0, 811.0)] {
            let m = Self.mapperShifted(CGFloat(shift))
            let d = Self.line(idx: 80)
            #expect(m.indexToX(80) == CGFloat(expectedX), "构造自检：锚点 x 必须真的是 \(expectedX)")
            #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 800, y: m.priceToY(15)),
                                                    drawing: d, mapper: m, isVisible: true, maxAnchors: 1) == nil,
                    "右外 \(expectedX)pt：代理标记处必须无答案")
        }
        // ⭐ 正向对照（⛔ 不可省）：锚点恰好落在边框【上】= 未出屏 ⇒ 同一个探针点必须有答案。
        //    没有这一条，上面 6 档全空可能只是因为函数恒返空。
        let mL = Self.mapperShifted(10)                  // idx=-1 → x = 0（左边框上）
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 0, y: mL.priceToY(15)),
                                                drawing: Self.line(idx: -1), mapper: mL, isVisible: true, maxAnchors: 1) == 0)
        let mR = Self.mapperShifted(0)                   // idx=80 → x = 800（右边框上）
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: 800, y: mR.priceToY(15)),
                                                drawing: Self.line(idx: 80), mapper: mR, isVisible: true, maxAnchors: 1) == 0)
    }

    @Test("⭐T12（命中侧）：畸形持久化数据的锚点一律点不中（D131 命中集合 ≡ 渲染集合）")
    func malformedAnchorsAreNotHittable() {
        let m = Self.mapper()
        // 两锚水平线：第二锚价位在图内，但水平线只消费 anchors.first ⇒ 第二锚处不该有可命中节点
        let two = DrawingObject(toolType: .horizontal,
                                anchors: [DrawingAnchor(period: .m3, candleIndex: 5,  price: 15),
                                          DrawingAnchor(period: .m3, candleIndex: 40, price: 12)],
                                isExtended: false, panelPosition: 0)
        let secondAnchorPoint = CGPoint(x: m.indexToX(40), y: m.priceToY(12))
        #expect(DrawingNodeGeometry.hitTestNode(point: secondAnchorPoint, drawing: two, mapper: m,
                                                isVisible: true, maxAnchors: 1) == nil,
                "第二锚处必须点不中 —— 它根本不该存在")
        // price 非有限（解码零校验，可从磁盘进来）
        for bad in [Double.nan, .infinity, -.infinity] {
            let d = DrawingObject(toolType: .horizontal,
                                  anchors: [DrawingAnchor(period: .m3, candleIndex: 5, price: bad)],
                                  isExtended: false, panelPosition: 0)
            #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: m.indexToX(5), y: 180),
                                                    drawing: d, mapper: m,
                                                    isVisible: true, maxAnchors: 1) == nil,
                    "price=\(bad) 的锚点必须点不中")
        }
        // ⭐ 正向对照①：正常线点得中 ⇒ 证明上面那些 nil 不是因为函数恒返 nil
        let healthy = Self.line(idx: 5)
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: m.indexToX(5), y: m.priceToY(15)),
                                                drawing: healthy, mapper: m,
                                                isVisible: true, maxAnchors: 1) == 0)
        // ⭐ 正向对照②：把 maxAnchors 放开到 2 ⇒ 同一个点变成【点得中】且返回原下标 1
        //    这证明拦截确实由 maxAnchors 决定，而不是「第二锚碰巧总也命中不了」
        #expect(DrawingNodeGeometry.hitTestNode(point: secondAnchorPoint, drawing: two, mapper: m,
                                                isVisible: true, maxAnchors: 2) == 1,
                "放开到 2 ⇒ 第二锚可命中且返回原下标 1")
    }

    @Test("外层：线不可见时一律无答案")
    func invisibleLineIsNotHittable() {
        let m = Self.mapper()
        let d = Self.line(idx: 5)
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: m.indexToX(5), y: m.priceToY(15)),
                                                drawing: d, mapper: m, isVisible: false, maxAnchors: 1) == nil)
        // 正向对照：同一个点、可见时有答案
        #expect(DrawingNodeGeometry.hitTestNode(point: CGPoint(x: m.indexToX(5), y: m.priceToY(15)),
                                                drawing: d, mapper: m, isVisible: true, maxAnchors: 1) == 0)
    }
}
