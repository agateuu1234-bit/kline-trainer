import Testing
@testable import KlineTrainerContracts

@Suite("TradeFeedback")
struct TradeFeedbackTests {
    // 成功（载荷类型与决策无关 → 用 Int 占位，验 D4 泛型 init）
    @Test("success → 触觉、无 Toast")
    func successFiresHapticNoToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.success(0))
        #expect(fb.firesHaptic == true)
        #expect(fb.toastMessage == nil)
    }

    @Test("资金不足 → 无触觉、Toast = AppError.userMessage")
    func insufficientCashToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.insufficientCash)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == "可用资金不足")
    }

    @Test("持仓不足 → 无触觉、Toast = 持仓不足")
    func insufficientHoldingToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.insufficientHolding)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == "持仓不足")
    }

    @Test("invalidShareCount → Toast = 股数非法")
    func invalidShareCountToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.invalidShareCount)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == "股数非法")
    }

    // disabled 由按钮禁用态自然呈现 → shouldShowToast == false → 不打 Toast（D1）
    @Test("disabled → 无触觉、无 Toast（按钮禁用态已呈现）")
    func disabledSuppressesToast() {
        let fb = TradeFeedback(result: Result<Int, AppError>.failure(.trade(.disabled)))
        #expect(fb.firesHaptic == false)
        #expect(fb.toastMessage == nil)
    }

    @Test("Equatable / Sendable 值语义")
    func equatable() {
        let a = TradeFeedback(result: Result<Int, AppError>.success(1))
        let b = TradeFeedback(result: Result<String, AppError>.success("x"))
        #expect(a == b)   // 同决策（成功）→ 相等，与载荷类型无关
    }
}
