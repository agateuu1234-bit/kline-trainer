// ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettlementContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.3 L988-1009 + plan 2026-05-27-pr-u3-settlement-view.md Task 1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("SettlementContent host tests")
struct SettlementContentTests {

    // MARK: - Fixture helper

    private func makeRecord(
        stockCode: String = "600519",
        stockName: String = "贵州茅台",
        startYear: Int = 2021,
        startMonth: Int = 8,
        totalCapital: Double = 102_345.67,
        returnRate: Double = 0.0234,
        maxDrawdown: Double = -0.0832,
        buyCount: Int = 4,
        sellCount: Int = 3
    ) -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "fixture.sqlite",
            createdAt: 1_700_000_000,
            stockCode: stockCode,
            stockName: stockName,
            startYear: startYear,
            startMonth: startMonth,
            totalCapital: totalCapital,
            profit: 0,
            returnRate: returnRate,
            maxDrawdown: maxDrawdown,
            buyCount: buyCount,
            sellCount: sellCount,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 100
        )
    }

    // MARK: - D1-D8 字面 spec 对齐

    @Test("§6.3 L994 字面：stock 字段全角括号包代码（D7）")
    func stockFieldUsesFullWidthParens() {
        let c = SettlementContent(record: makeRecord())
        #expect(c.stock == "贵州茅台（600519）")
    }

    @Test("§6.3 L995 字面：起始月份零填充到两位（D4）")
    func startMonthZeroPadded() {
        let c = SettlementContent(record: makeRecord(startMonth: 8))
        #expect(c.startMonth == "2021年08月")
    }

    @Test("§6.3 L995 字面：12月不加多余零（边界）")
    func startMonthTwoDigitMonthUnchanged() {
        let c = SettlementContent(record: makeRecord(startYear: 2024, startMonth: 12))
        #expect(c.startMonth == "2024年12月")
    }

    @Test("§6.3 L997 字面：总资金 ¥ 与数字间一空格 + 千分位 + 2 小数（D3）")
    func capitalFormatHasSpaceAfterYen() {
        let c = SettlementContent(record: makeRecord(totalCapital: 102_345.67))
        #expect(c.totalCapital == "¥ 102,345.67")
    }

    @Test("§6.3 L997 整数总资金也补 2 位小数")
    func capitalIntegerStillTwoDecimals() {
        let c = SettlementContent(record: makeRecord(totalCapital: 100_000))
        #expect(c.totalCapital == "¥ 100,000.00")
    }

    @Test("§6.3 L998 字面：正收益率显式 + 号 + 2 位小数（D5/D6）")
    func returnRatePositiveSign() {
        let c = SettlementContent(record: makeRecord(returnRate: 0.0234))
        #expect(c.returnRate == "+2.34%")
    }

    @Test("§6.3 L999 字面：负回撤显式 - 号 + 2 位小数（D5/D6）")
    func maxDrawdownNegativeSign() {
        let c = SettlementContent(record: makeRecord(maxDrawdown: -0.0832))
        #expect(c.maxDrawdown == "-8.32%")
    }

    @Test("D5 零值显式 + 号（避免 -0.00%）")
    func zeroValueShowsPositiveSign() {
        let c = SettlementContent(record: makeRecord(returnRate: 0, maxDrawdown: 0))
        #expect(c.returnRate == "+0.00%")
        #expect(c.maxDrawdown == "+0.00%")
    }

    @Test("R1-C1 IEEE-754 signed zero -0.0 规范化为 +0.00%（D5 必修）")
    func signedZeroNormalizedToPositive() {
        let c = SettlementContent(record: makeRecord(returnRate: -0.0, maxDrawdown: -0.0))
        #expect(c.returnRate == "+0.00%")
        #expect(c.maxDrawdown == "+0.00%")
    }

    @Test("R1-M2 IEEE-754 ±0.0 输入都不显示 -0.00%（D5 反向断言；ULP 噪声不阈值化属 D5 注释明确 residual）")
    func neverShowsNegativeZero() {
        for v in [0.0, -0.0] {
            let c = SettlementContent(record: makeRecord(returnRate: v, maxDrawdown: v))
            #expect(c.returnRate != "-0.00%")
            #expect(c.maxDrawdown != "-0.00%")
        }
    }

    @Test("§6.3 L1000-L1001 字面：买卖次数与'次'一空格（D8）")
    func tradeCountsHaveSpaceBeforeCi() {
        let c = SettlementContent(record: makeRecord(buyCount: 4, sellCount: 3))
        #expect(c.buyCount == "4 次")
        #expect(c.sellCount == "3 次")
    }

    @Test("零次买卖也保留'次'后缀")
    func zeroTradeCountStillHasCi() {
        let c = SettlementContent(record: makeRecord(buyCount: 0, sellCount: 0))
        #expect(c.buyCount == "0 次")
        #expect(c.sellCount == "0 次")
    }

    // MARK: - 边界值

    @Test("R1-H3 rate 边界值：正则强锚 ^[+-]\\d+\\.\\d{2}%$ + halfUp 实测值锁定（强断言）")
    func rateBoundaryHalfDecimalRegex() {
        let c = SettlementContent(record: makeRecord(returnRate: 0.00501))
        // 强锚 #1：符号 + 至少一位整数 + 小数点 + 恰好两位小数 + 百分号
        #expect(c.returnRate.wholeMatch(of: #/^[+\-]\d+\.\d{2}%$/#) != nil)
        // 强锚 #2：本机 Swift 6.0 toolchain `String(format: "%+.2f", 0.501)` 实测 = "+0.50"（halfEven 规则在 0.501 不触发 banker's round）
        #expect(c.returnRate == "+0.50%")
    }

    @Test("R1-L1 ULP 边界：0.1 × 100 ≈ 10.000000000000002 不泄漏到显示")
    func ulpBoundaryDecimalDoesNotLeak() {
        let c = SettlementContent(record: makeRecord(returnRate: 0.1))
        #expect(c.returnRate == "+10.00%")
    }

    @Test("非常大的资金正常显示千分位（不科学记数）")
    func capitalLargeNumberUsesGrouping() {
        let c = SettlementContent(record: makeRecord(totalCapital: 12_345_678.99))
        #expect(c.totalCapital == "¥ 12,345,678.99")
    }

    @Test("负 returnRate 与 maxDrawdown 同时呈现")
    func negativeReturnRateAlsoSigned() {
        let c = SettlementContent(record: makeRecord(returnRate: -0.10, maxDrawdown: -0.15))
        #expect(c.returnRate == "-10.00%")
        #expect(c.maxDrawdown == "-15.00%")
    }

    @Test("SettlementContent 是 Equatable / Sendable")
    func contentEquatableAndSendable() {
        let c1 = SettlementContent(record: makeRecord())
        let c2 = SettlementContent(record: makeRecord())
        #expect(c1 == c2)
        // Sendable 编译时检查；同 actor 内 await 即证（这里用 @MainActor 不必要，结构体本身即时值）
        let _: any Sendable = c1
    }
}
