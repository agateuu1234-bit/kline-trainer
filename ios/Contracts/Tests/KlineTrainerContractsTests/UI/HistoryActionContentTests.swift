// ios/Contracts/Tests/KlineTrainerContractsTests/UI/HistoryActionContentTests.swift
// Spec: kline_trainer_plan_v1.5.md §6.1.3 L871-895 + plan 2026-05-29-pr-u6-history-action-sheet.md Task 1
// 平台无关：只 import Foundation（host swift test 直跑，不需 Catalyst）。

import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("HistoryActionContent host tests")
struct HistoryActionContentTests {

    // MARK: - 共享 fixture helper（测试内 private，不污染 prod）

    private func makeRecord(stockName: String, code: String) -> TrainingRecord {
        TrainingRecord(
            id: 1,
            trainingSetFilename: "t.sqlite",
            createdAt: 1_700_000_000,
            stockCode: code,
            stockName: stockName,
            startYear: 2021,
            startMonth: 8,
            totalCapital: 100_000,
            profit: 0,
            returnRate: 0,
            maxDrawdown: 0,
            buyCount: 0,
            sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true),
            finalTick: 1000
        )
    }

    // MARK: - D4/D5 formatStock 基础 + 边界

    @Test("D4/D5 formatStock 基础：name（code）全角括号")
    func formatStockBasic() {
        #expect(HistoryActionContent.formatStock(name: "贵州茅台", code: "600519") == "贵州茅台（600519）")
    }

    @Test("D4/D5 formatStock 另一只股票")
    func formatStockAnotherStock() {
        #expect(HistoryActionContent.formatStock(name: "宁德时代", code: "300750") == "宁德时代（300750）")
    }

    @Test("D5 formatStock 空 name → （code）")
    func formatStockEmptyName() {
        #expect(HistoryActionContent.formatStock(name: "", code: "600519") == "（600519）")
    }

    @Test("D5 formatStock 空 code → name（）")
    func formatStockEmptyCode() {
        #expect(HistoryActionContent.formatStock(name: "贵州茅台", code: "") == "贵州茅台（）")
    }

    // MARK: - D5 全角括号字符精确（防 ASCII 括号回归）

    @Test("D5 title 含全角左右括号 U+FF08 / U+FF09")
    func titleContainsFullWidthParens() {
        let title = HistoryActionContent.formatStock(name: "贵州茅台", code: "600519")
        #expect(title.contains("（"))  // U+FF08
        #expect(title.contains("）"))  // U+FF09
    }

    @Test("D5 title 不含 ASCII 半角括号 ( / )")
    func titleHasNoAsciiParens() {
        let title = HistoryActionContent.formatStock(name: "贵州茅台", code: "600519")
        #expect(!title.contains("("))  // ASCII U+0028
        #expect(!title.contains(")"))  // ASCII U+0029
    }

    // MARK: - D3/D14 Content.init 从 record 连线 title

    @Test("D3 Content.init 用 record.stockName + stockCode 拼 title")
    func contentInitWiresTitleFromRecord() {
        let r = makeRecord(stockName: "贵州茅台", code: "600519")
        let c = HistoryActionContent(record: r)
        #expect(c.title == "贵州茅台（600519）")
        #expect(c.title == HistoryActionContent.formatStock(name: r.stockName, code: r.stockCode))
    }

    // MARK: - Equatable

    @Test("Equatable：同 stockName/stockCode 的 record → Content 相等")
    func equatableSameStockEqual() {
        let c1 = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        let c2 = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        #expect(c1 == c2)
    }

    @Test("Equatable：不同股票 → Content 不相等")
    func equatableDifferentStockNotEqual() {
        let c1 = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        let c2 = HistoryActionContent(record: makeRecord(stockName: "宁德时代", code: "300750"))
        #expect(c1 != c2)
    }

    // MARK: - Sendable

    @Test("Content 是 Sendable（compile-time conformance）")
    func contentIsSendable() {
        let c = HistoryActionContent(record: makeRecord(stockName: "贵州茅台", code: "600519"))
        let _: any Sendable = c
    }
}
