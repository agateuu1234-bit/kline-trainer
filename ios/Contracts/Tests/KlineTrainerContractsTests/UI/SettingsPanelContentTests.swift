// ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettingsPanelContentTests.swift
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("SettingsPanelContent")
struct SettingsPanelContentTests {

    // commission 边界换算（spec modules L2009/L2013）
    @Test("commissionRate(fromUIInputTenThousandth:)：UI 1 → 0.0001")
    func uiToRate() {
        // ×1 平凡乘（乘 1.0 位等价）→ 精确 ==；非平凡乘用容差（per feedback_swift_local_toolchain_blindspot）
        #expect(SettingsPanelContent.commissionRate(fromUIInputTenThousandth: 1) == 0.0001)
        #expect(abs(SettingsPanelContent.commissionRate(fromUIInputTenThousandth: 7) - 0.0007) < 1e-12)
    }

    @Test("uiDisplayTenThousandth(fromCommissionRate:)：0.0001 → 1（容差，FP）")
    func rateToUI() {
        let v = SettingsPanelContent.uiDisplayTenThousandth(fromCommissionRate: 0.0001)
        #expect(abs(v - 1.0) < 1e-9)
    }

    @Test("formatCommissionUIInput：0.0001 → \"1.000\"（§6.4 精确 3 位）")
    func formatCommission() {
        #expect(SettingsPanelContent.formatCommissionUIInput(0.0001) == "1.000")
        #expect(SettingsPanelContent.formatCommissionUIInput(0.00125) == "12.500")
    }

    // commission 输入解析（§6.4 不能为空）
    @Test("parseCommissionUIInput：合法→stored 小数率；空/非法→nil")
    func parseCommission() {
        #expect(SettingsPanelContent.parseCommissionUIInput("1") == 0.0001)        // ×1 精确
        let p = SettingsPanelContent.parseCommissionUIInput("  2.5 ")              // ×2.5 容差
        #expect(p != nil && abs(p! - 0.00025) < 1e-12)
        #expect(SettingsPanelContent.parseCommissionUIInput("") == nil)
        #expect(SettingsPanelContent.parseCommissionUIInput("abc") == nil)
    }

    // 下载数量校验（§6.4 整数 1~20）
    @Test("validateDownloadCount：1~20 valid；边界/非整数/越界/空")
    func validateCount() {
        #expect(SettingsPanelContent.validateDownloadCount("1") == .valid(1))
        #expect(SettingsPanelContent.validateDownloadCount("20") == .valid(20))
        #expect(SettingsPanelContent.validateDownloadCount(" 5 ") == .valid(5))
        #expect(SettingsPanelContent.validateDownloadCount("0") == .outOfRange)
        #expect(SettingsPanelContent.validateDownloadCount("21") == .outOfRange)
        #expect(SettingsPanelContent.validateDownloadCount("3.5") == .notInteger)
        #expect(SettingsPanelContent.validateDownloadCount("") == .empty)
    }

    // displayMode label
    @Test("displayModeLabel：三态中文")
    func displayLabels() {
        #expect(SettingsPanelContent.displayModeLabel(.light) == "白天模式")
        #expect(SettingsPanelContent.displayModeLabel(.dark) == "夜间模式")
        #expect(SettingsPanelContent.displayModeLabel(.system) == "跟随系统")
    }
}

@Suite("SettingsPanelContent 重置资金文案（RFC-A R-plan-7-2：非破坏性）")
struct SettingsPanelContentResetCopyTests {
    // --- 正向：含「保留」「¥100,000」 ---

    @Test("按钮文案含保留记录 + 资金额度")
    func resetButtonContainsRetainAndCapital() {
        #expect(SettingsPanelContent.resetButtonLabel.contains("保留"))
        #expect(SettingsPanelContent.resetButtonLabel.contains("100,000"))
    }

    @Test("确认标题含重置资金（非破坏性措辞）")
    func resetConfirmTitleContainsReset() {
        #expect(SettingsPanelContent.resetConfirmTitle.contains("重置资金"))
    }

    @Test("确认消息含保留记录 + 资金额度")
    func resetConfirmMessageContainsRetainAndCapital() {
        #expect(SettingsPanelContent.resetConfirmMessage.contains("保留"))
        #expect(SettingsPanelContent.resetConfirmMessage.contains("100,000"))
    }

    // --- 负向：不含旧的破坏性措辞 ---

    @Test("三串均不含「删除全部」（旧破坏性文案）")
    func noDeleteAll() {
        #expect(!SettingsPanelContent.resetButtonLabel.contains("删除全部"))
        #expect(!SettingsPanelContent.resetConfirmTitle.contains("删除全部"))
        #expect(!SettingsPanelContent.resetConfirmMessage.contains("删除全部"))
    }

    @Test("三串均不含「清空记录」（旧破坏性文案）")
    func noClearRecords() {
        #expect(!SettingsPanelContent.resetButtonLabel.contains("清空记录"))
        #expect(!SettingsPanelContent.resetConfirmTitle.contains("清空记录"))
        #expect(!SettingsPanelContent.resetConfirmMessage.contains("清空记录"))
    }

    @Test("三串均不含「不可撤销」（旧破坏性文案）")
    func noIrreversible() {
        #expect(!SettingsPanelContent.resetButtonLabel.contains("不可撤销"))
        #expect(!SettingsPanelContent.resetConfirmTitle.contains("不可撤销"))
        #expect(!SettingsPanelContent.resetConfirmMessage.contains("不可撤销"))
    }
}
