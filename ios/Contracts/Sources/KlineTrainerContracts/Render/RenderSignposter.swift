// Kline Trainer Swift Contracts — Wave 3 13c-R1 渲染热路径 os_signpost 帧相关 instrumentation
// Spec: docs/superpowers/specs/2026-06-16-wave3-13c-r1-signpost-instrumentation-design.md
//
// 平台无关（os 跨平台，host 可编可测）；**不** #if DEBUG 门控——帧预算判据（modules L1471）
// 测的是 Release（优化）包，故 instrumentation 必须编进 Release。os_signpost 未被 Instruments
// 录制时近零成本（Apple 框架自身在 Release 大量发 signpost）。
//
// 区间名 = per-panel×op 的 StaticString（Instruments 恒可见，无动态字符串 .private 隐患）。
// endInterval 真实 SDK 签名 = endInterval(_ name: StaticString, _ state:)（无单 state 重载；
// state 只携 id 不携 name），故 begin 返回令牌 bundle 名 + 态，end 收口时回传两者。

import os

enum RenderSignposter {
    /// runbook 在 os_signpost instrument 按此 subsystem 筛 lane。
    static let subsystem = "com.klinetrainer.render"

    /// 区间操作类别（update-pass make / crosshair 旁路 make / draw）。
    enum Op {
        case make, makeCrosshair, draw
    }

    /// begin 返回的令牌：bundle 区间名 + 区间态（end 需二者，见文件头）。
    struct Token {
        let name: StaticString
        let state: OSSignpostIntervalState
    }

    // OSSignposter 在 iOS17/macOS14 floor 为 Sendable（同 OSLog 在本包已用 static let，
    // 见 DefaultDownloadAcceptanceCleaner）；若个别 toolchain 报 strict-concurrency，
    // 加 `nonisolated(unsafe)`（os 句柄线程安全，注解语义正确）。
    private static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)

    /// (op, panel) → 区间名（编译期常量；runtime 选 StaticString 合法，已 spec R2 实证）。
    static func name(op: Op, panel: PanelId) -> StaticString {
        switch (op, panel) {
        case (.make, .upper): return "make-upper"
        case (.make, .lower): return "make-lower"
        case (.makeCrosshair, .upper): return "make-crosshair-upper"
        case (.makeCrosshair, .lower): return "make-crosshair-lower"
        case (.draw, .upper): return "draw-upper"
        case (.draw, .lower): return "draw-lower"
        }
    }

    static func beginMake(panel: PanelId) -> Token { begin(op: .make, panel: panel) }
    static func beginMakeCrosshair(panel: PanelId) -> Token { begin(op: .makeCrosshair, panel: panel) }
    static func beginDraw(panel: PanelId) -> Token { begin(op: .draw, panel: panel) }

    private static func begin(op: Op, panel: PanelId) -> Token {
        let n = name(op: op, panel: panel)
        return Token(name: n, state: signposter.beginInterval(n, id: signposter.makeSignpostID()))
    }

    static func end(_ token: Token) {
        signposter.endInterval(token.name, token.state)
    }
}
