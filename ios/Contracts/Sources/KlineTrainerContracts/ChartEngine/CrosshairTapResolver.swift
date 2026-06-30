// ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/CrosshairTapResolver.swift
// Spec: docs/superpowers/specs/2026-06-30-tap-anywhere-settings-popover-design.md §2.1
// 平台无关纯决策（host 全测）：tap 归属 + sync 退出。无 UIKit 依赖——ChartGestureArbiter（UIKit 壳）/
// ChartContainerView（Coordinator）调它（沿 GestureClassifiers 纯函数 + UIKit 壳一贯模式）。
import Foundation

/// 一次 tap 的归属（顺序即优先级：本地退 > 退远端光标 > drawing 锚点 > 无操作）。
public enum CrosshairTapOutcome: Equatable {
    case exitLocal          // 本 panel 持光标 → onCrosshairExit
    case requestGlobalExit  // 别的面板持光标 → 退之（onCrosshairExit 清 owner → 持有面板 self→nil 自退）
    case drawingAnchor      // 无光标 + 本 panel drawing → onTap 落锚点
    case noop               // 普通态 → 无操作
}

/// sync 时本 panel 是否应退出黏滞光标。
public enum CrosshairSyncExit: Equatable {
    case none
    case exitTakenOver      // 被另一面板接管
    case exitOwnerCleared   // 本面板曾持有、owner 被清（tap-anywhere）
}

public enum CrosshairTapResolver {

    /// tap 归属。`remoteOwnerPresent` = 本面板视角「有别的面板持光标」（arbiter 经注入谓词得到；
    /// 直接消费者未注入谓词 → 传 false → 退化旧真值表逐格等价）。
    public static func resolve(localCrosshairMode: Bool, drawingMode: Bool, remoteOwnerPresent: Bool) -> CrosshairTapOutcome {
        if localCrosshairMode { return .exitLocal }
        if remoteOwnerPresent { return .requestGlobalExit }  // **先于** drawing（spec-R3-M1）
        if drawingMode { return .drawingAnchor }
        return .noop
    }

    /// sync 退出决策。owner==nil 退出**门控在 self→nil 跃迁**（`previousOwner==panel`）——
    /// standalone（`crosshairOwner=.constant(nil)`）下 owner/previousOwner 恒 nil → 永不退、黏滞光标保留（spec-R2-M1）。
    public static func resolveSyncExit(incomingOwner: PanelId?, previousOwner: PanelId?,
                                       panel: PanelId, crosshairActive: Bool) -> CrosshairSyncExit {
        guard crosshairActive else { return .none }
        if let owner = incomingOwner, owner != panel { return .exitTakenOver }
        if incomingOwner == nil, previousOwner == panel { return .exitOwnerCleared }
        return .none
    }

    /// 本面板视角「有**别的**面板持光标」（供 arbiter `onShouldExitRemoteCrosshair` 谓词 → resolve 的 `remoteOwnerPresent`）。
    /// **排除自持**（`syncedOwner == panel`，codex WB-3）：自持时 `crosshairMode==true` 已由 `resolve` 的 `exitLocal` 优先短路；
    /// 但 drawing 激活的**异步 owner 释放窗口**内 `crosshairMode` 已 false 而 `syncedOwner` 仍==自己——此时必须返 false，
    /// 否则首个画线 tap 被误判 `requestGlobalExit` 吞掉（而非落锚点）。
    public static func remoteOwnerPresent(syncedOwner: PanelId?, panel: PanelId) -> Bool {
        syncedOwner != nil && syncedOwner != panel
    }
}
