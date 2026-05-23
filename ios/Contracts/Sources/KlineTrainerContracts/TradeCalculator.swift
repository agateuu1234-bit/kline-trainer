// Kline Trainer Swift Contracts — E3 TradeCalculator
// Spec: kline_trainer_modules_v1.4.md §E3 (签名 + 常量)
//     + kline_trainer_plan_v1.5.md §4.2 (买卖计算规则)
// M0.4: 豁免 — 返 Result<_, TradeReason>，从不 throws AppError
//       (docs/governance/m04-apperror-translation-gate.md L62)

public enum TradeCalculator {

    public struct BuyQuote: Equatable {
        public let shares: Int
        public let notional, commission, totalCost: Double
        public init(shares: Int, notional: Double, commission: Double, totalCost: Double) {
            self.shares = shares
            self.notional = notional
            self.commission = commission
            self.totalCost = totalCost
        }
    }

    public struct SellQuote: Equatable {
        public let shares: Int
        public let notional, commission, stampDuty, proceeds: Double
        public init(shares: Int, notional: Double, commission: Double,
                    stampDuty: Double, proceeds: Double) {
            self.shares = shares
            self.notional = notional
            self.commission = commission
            self.stampDuty = stampDuty
            self.proceeds = proceeds
        }
    }

    public static let stampDutyRate: Double = 0.0005   // 卖出印花税 0.05%，始终生效
    public static let minCommissionAmount: Double = 5  // 免5关闭时的最低佣金
    public static let shareLotSize: Int = 100          // A股一手 = 100 股

    // MARK: - Buy

    public static func quoteBuy(totalCapital: Double, cash: Double,
                                tier: PositionTier, price: Double,
                                fees: FeeSnapshot) -> Result<BuyQuote, TradeReason> {
        guard price > 0, totalCapital >= 0, cash >= 0,
              price.isFinite, totalCapital.isFinite, cash.isFinite else {
            return .failure(.invalidShareCount)
        }
        let targetAmount = totalCapital * ratio(of: tier)
        let rawShares = robustFloor(targetAmount / price)
        let lotShares = (rawShares / shareLotSize) * shareLotSize
        guard lotShares > 0 else { return .failure(.insufficientCash) }

        let notional = Double(lotShares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let totalCost = notional + commission
        guard totalCost <= cash else { return .failure(.insufficientCash) }

        return .success(BuyQuote(shares: lotShares, notional: notional,
                                 commission: commission, totalCost: totalCost))
    }

    // MARK: - Sell

    public static func quoteSell(holding: Int, averageCost: Double,
                                 tier: PositionTier, price: Double,
                                 fees: FeeSnapshot) -> Result<SellQuote, TradeReason> {
        // averageCost 属冻结签名；E3 不用它（已实现盈亏由 E5 调用方按 averageCost 计算）。
        guard price > 0, holding >= 0, price.isFinite else {
            return .failure(.invalidShareCount)
        }
        guard holding > 0 else { return .failure(.disabled) }

        let sellShares: Int
        if tier == .tier5 {
            sellShares = holding                        // 清仓：全部持仓，不取整，允许零股
        } else {
            // robustFloor 在 sell 路径为防御性对称（整数 holding × 5 档比例不会 FP 下溢），
            // 与 buy 路径保持一致 floor 语义。
            sellShares = (robustFloor(Double(holding) * ratio(of: tier)) / shareLotSize) * shareLotSize
        }
        guard sellShares > 0 else { return .failure(.insufficientHolding) }

        return .success(makeSellQuote(shares: sellShares, price: price, fees: fees))
    }

    // MARK: - Private helpers

    /// floor() 对二进制浮点表示误差做 verify-and-correct（C1a 模式）。
    /// 适用前提：price 为 0.01 整数倍、capital/holding 近整数——此类操作数的乘除积真值
    /// 要么是精确整数、要么离整数远超 FP 噪声底（≤ ~1e-8），故 1e-6 容差能干净区分
    /// "整数的 FP 下溢"(应进位) vs"真实小数结果"(应截断)。signature 不强制该前提，故对
    /// 任意 Double 并非无条件正确的 floor（只在本模块的输入域内成立）。
    private static func robustFloor(_ value: Double) -> Int {
        let f = value.rounded(.down)
        return ((f + 1) - value <= 1e-6) ? Int(f) + 1 : Int(f)
    }

    private static func computeCommission(notional: Double, fees: FeeSnapshot) -> Double {
        let raw = notional * fees.commissionRate
        if fees.minCommissionEnabled && raw < minCommissionAmount {
            return minCommissionAmount
        }
        return raw
    }

    private static func makeSellQuote(shares: Int, price: Double, fees: FeeSnapshot) -> SellQuote {
        let notional = Double(shares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let stampDuty = notional * stampDutyRate
        let proceeds = notional - commission - stampDuty
        return SellQuote(shares: shares, notional: notional, commission: commission,
                         stampDuty: stampDuty, proceeds: proceeds)
    }

    private static func ratio(of tier: PositionTier) -> Double {
        switch tier {
        case .tier1: return 0.2
        case .tier2: return 0.4
        case .tier3: return 0.6
        case .tier4: return 0.8
        case .tier5: return 1.0
        }
    }
}
