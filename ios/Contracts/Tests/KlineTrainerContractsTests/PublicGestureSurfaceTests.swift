// W3-11-R1b-wire — public gesture API 面编译保障（codex branch-diff R3）
// **non-@testable import**：本文件只见 KlineTrainerContracts 的 **public** 接口（@testable 是 per-import，
// 同 target 其它文件用 @testable 不影响本文件）。若任一被引用方法非 public → 本文件编译失败 → CI 红。
// 用途：外部消费者（非 @testable）驱动手势的 public 面回归保障（旧 public endPan/applyPanOffset 改 internal 后，
// 须有 public bounded 替代 = renderBounds 重载，codex R3）。不构造 engine（init internal）、不运行——存在即证 public 面完整。
import KlineTrainerContracts
import CoreGraphics

@MainActor
func publicGestureSurfaceCompileCheck(engine: TrainingEngine, panel: PanelId) {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    engine.beginPan(panel: panel)
    engine.applyPanOffset(deltaPixels: 10, renderBounds: bounds, panel: panel)   // public bounded（不暴露 OffsetBounds）
    engine.endPan(velocity: 1000, renderBounds: bounds, panel: panel)             // public bounded（机制 A）
    engine.cancelPan(panel: panel)
    engine.recordRenderBounds(bounds, panel: panel)
}

#if canImport(UIKit)
// RFC-E follow-up（tap-anywhere）：arbiter tap 公共面回归保障——
// onTap（drawing 锚点）/onCrosshairExit（退出）保留，新增 onShouldExitRemoteCrosshair（纯加法）。
// 存在即证 public 面完整（codex spec-R4-H1/R5-H1）；Catalyst 编译闸门覆盖。
@MainActor
func crosshairTapPublicSurfaceCompileCheck() {
    let arbiter = ChartGestureArbiter()
    arbiter.onTap = { _ in }
    arbiter.onCrosshairExit = { }
    arbiter.onShouldExitRemoteCrosshair = { false }
}
#endif
