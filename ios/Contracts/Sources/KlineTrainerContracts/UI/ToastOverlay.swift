// ios/Contracts/Sources/KlineTrainerContracts/UI/ToastOverlay.swift
// Kline Trainer Swift Contracts — 统一非阻塞 Toast 呈现壳（Wave 3 PR 13a §B.1）
//
// content-agnostic SwiftUI 复用 modifier：行为字节对齐 Wave 3 顺位 7 TrainingView 内联 toast
// （顶部 / regularMaterial Capsule / move+opacity / easeInOut 0.2）。latest-wins/计时由调用方
// 持 ToastState 驱动（本壳只渲染传入 message）。薄 UI 壳，不 host 单测（无 snapshot infra）；
// 仅用跨平台 SwiftUI API → host + Catalyst 双可编译（不 #if canImport(UIKit) 闸门，
// 否则 host-compiled SettingsPanel 调用处编译失败，plan-review R1-Critical）。

import SwiftUI

public struct ToastOverlay: ViewModifier {
    let message: String?

    public func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: message)
    }
}

public extension View {
    /// 顶部非阻塞 toast。`message` 非 nil 时展示，nil 时隐去（带过渡动画）。
    func toastOverlay(_ message: String?) -> some View {
        modifier(ToastOverlay(message: message))
    }
}
