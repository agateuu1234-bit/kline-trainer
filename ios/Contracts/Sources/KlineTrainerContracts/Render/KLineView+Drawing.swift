// Kline Trainer Swift Contracts — C6 绘线渲染层 extension stub
// Spec: kline_trainer_modules_v1.4.md §C6（DrawingTools + DrawingInputController；Phase 2.5 水平线先行）
//
// 注：本文件只交付 drawDrawings 一个方法 stub；DrawingTool protocol / DrawingToolManager
// 由 Wave 1 C6 真实现引入，不在本 PR scope。drawings 类型 [DrawingObject] 占位见 Task 1.2（已确认 Models.swift L196 真类型存在）。

#if canImport(UIKit)
import UIKit
import CoreGraphics

extension KLineView {
    /// C6 绘线渲染 stub。Wave 1 C6 落地：遍历 DrawingObject 逐个 dispatch 到对应 tool draw 函数；
    /// period 用于价格/时间坐标映射跨周期一致性。
    func drawDrawings(ctx: CGContext,
                      mapper: CoordinateMapper,
                      drawings: [DrawingObject],
                      period: Period) {
        // Wave 1 (C6): dispatch each DrawingObject to its DrawingTool.draw(...)
    }
}

#endif
