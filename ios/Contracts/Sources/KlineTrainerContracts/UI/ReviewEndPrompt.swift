// ios/Contracts/Sources/KlineTrainerContracts/UI/ReviewEndPrompt.swift
// Kline Trainer Swift Contracts — 复盘「结束」保存弹窗触发谓词（review-redesign Task 13）
// Spec: .superpowers/sdd/task-13-brief.md Step 3/6。
//
// 平台无关纯谓词（host 全测）：复盘「结束」是否弹「保存/不保存/取消」确认对话框——
// 仅当当前 session 相对已提交基线有净改动（lifecycle.reviewNetChanged()）才弹；
// 无改动则直接静默丢弃退出，不打扰用户。TrainingView 消费本谓词而非内联判断。
public enum ReviewEndPrompt {
    public static func shouldPrompt(netChanged: Bool) -> Bool { netChanged }
}
