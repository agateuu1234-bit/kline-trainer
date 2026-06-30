// ios/Contracts/Tests/KlineTrainerContractsTests/ChartEngine/CrosshairTapResolverTests.swift
// Spec: docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md §2.1 纯函数 + §4
// 平台无关纯函数红绿覆盖：tap 归属真值表 + sync 退出决策（含 standalone 持久性回归守门）。
import Testing
@testable import KlineTrainerContracts

@Suite("CrosshairTapResolver decisions")
struct CrosshairTapResolverTests {

    // MARK: - resolve（tap 归属，顺序：exitLocal > requestGlobalExit > drawingAnchor > noop）

    @Test("localCrosshairMode=true → exitLocal（无视 drawing/remote，全 4 格）")
    func localOwnerExitsLocal() {
        // 全 4 个 localCrosshairMode=true 组合 → exitLocal（spec §4「全 8 格」之上半，余 4 格 false 见下方各测）
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: true, drawingMode: true, remoteOwnerPresent: true) == .exitLocal)
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: true, drawingMode: true, remoteOwnerPresent: false) == .exitLocal)
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: true, drawingMode: false, remoteOwnerPresent: true) == .exitLocal)
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: true, drawingMode: false, remoteOwnerPresent: false) == .exitLocal)
    }

    @Test("remoteOwnerPresent=true（非本地）→ requestGlobalExit（先于 drawing，spec-R3-M1）")
    func remoteOwnerExitsGlobalBeforeDrawing() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: true, remoteOwnerPresent: true) == .requestGlobalExit)
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: false, remoteOwnerPresent: true) == .requestGlobalExit)
    }

    @Test("无远端光标 + drawing → drawingAnchor（onTap 行为接线，spec-R5-H1）")
    func drawingNoRemoteAnchors() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: true, remoteOwnerPresent: false) == .drawingAnchor)
    }

    @Test("普通态（全 false）→ noop")
    func idleNoop() {
        #expect(CrosshairTapResolver.resolve(localCrosshairMode: false, drawingMode: false, remoteOwnerPresent: false) == .noop)
    }

    // MARK: - resolveSyncExit（sync 退出决策）

    @Test("被另一面板接管 → exitTakenOver")
    func takenOver() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: .upper, previousOwner: .lower, panel: .lower, crosshairActive: true) == .exitTakenOver)
    }

    @Test("self→nil 跃迁 → exitOwnerCleared（tap-anywhere）")
    func ownerCleared() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: nil, previousOwner: .upper, panel: .upper, crosshairActive: true) == .exitOwnerCleared)
    }

    @Test("standalone 恒 nil → none（黏滞光标持久性回归守门，spec-R2-M1）")
    func standalonePersists() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: nil, previousOwner: nil, panel: .upper, crosshairActive: true) == .none)
    }

    @Test("crosshairActive=false → none（无活动光标不退）")
    func inactiveNone() {
        #expect(CrosshairTapResolver.resolveSyncExit(incomingOwner: .upper, previousOwner: .lower, panel: .lower, crosshairActive: false) == .none)
    }

    // MARK: - remoteOwnerPresent（谓词：有别的面板持光标，排除自持，codex WB-3）

    @Test("remoteOwnerPresent: nil→false / 自持→false / 别面板→true（codex WB-3）")
    func remoteOwnerPresentPredicate() {
        #expect(CrosshairTapResolver.remoteOwnerPresent(syncedOwner: nil, panel: .upper) == false)       // 无人持
        #expect(CrosshairTapResolver.remoteOwnerPresent(syncedOwner: .upper, panel: .upper) == false)    // 自持（drawing 激活异步窗口）→ 放行画线锚点
        #expect(CrosshairTapResolver.remoteOwnerPresent(syncedOwner: .lower, panel: .upper) == true)     // 别面板持 → 退远端
        #expect(CrosshairTapResolver.remoteOwnerPresent(syncedOwner: .upper, panel: .lower) == true)
    }
}
