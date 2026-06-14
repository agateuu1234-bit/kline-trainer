// ios/Contracts/Sources/KlineTrainerContracts/UI/ToastState.swift
// Kline Trainer Swift Contracts — 统一 Toast latest-wins 调度核（Wave 3 PR 13a §B.1）
//
// 平台无关纯值（host 全测）：把「latest-wins token + 何时清空」逻辑从 SwiftUI 壳抽出，使其可在
// swift test 确定性断言（壳层的 Task.sleep 计时留在 ToastOverlay/视图，调本结构的 expire）。
// 取代 Wave 3 顺位 7 内联于 TrainingView 的 toastToken/toastMessage（无 host 测）。

import Foundation

public struct ToastState: Equatable, Sendable {
    /// 当前展示的文案；nil = 无 toast。
    public private(set) var message: String?
    /// 单调递增 token：每次 present 递增，用于 latest-wins（晚来的覆盖早来的过期清空）。
    public private(set) var token: Int = 0

    public init() {}

    /// 展示新文案，返回本次 token。调用方据返回 token 安排过期回调。
    public mutating func present(_ message: String) -> Int {
        token += 1
        self.message = message
        return token
    }

    /// 过期指定 token：仅当它仍是最新 token 时清空 message（latest-wins，旧 token 过期 no-op）。
    public mutating func expire(token expiredToken: Int) {
        if token == expiredToken { message = nil }
    }
}
