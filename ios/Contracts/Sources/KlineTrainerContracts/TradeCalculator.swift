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
        // averageCost 属冻结签名；E3 不用它（已实现盈亏由 E5 调用方按 averageCost 计算），
        // 故有意不做 isFinite 校验（未参与计算，校验无意义）。
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
        // 仅 non-tier5 可达：tier5 分支已令 sellShares = holding（holding>0 已由上方 guard 保证）
        guard sellShares > 0 else { return .failure(.insufficientHolding) }

        return .success(makeSellQuote(shares: sellShares, price: price, fees: fees))
    }

    // MARK: - Force close (end of game)

    public static func forceCloseOnEnd(holding: Int, averageCost: Double,
                                       price: Double, fees: FeeSnapshot) -> SellQuote {
        // 局终全量清仓，无错误通道；holding<=0 或非法 price -> 全零报价（无交易无费用）。
        // averageCost 属冻结签名；E3 不用它（已实现盈亏由 E5 调用方计算）。
        guard holding > 0, price > 0, price.isFinite else {
            return SellQuote(shares: 0, notional: 0, commission: 0, stampDuty: 0, proceeds: 0)
        }
        return makeSellQuote(shares: holding, price: price, fees: fees)
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

    // MARK: - RFC-A 按股数 API（A1）

    /// 按股数买入报价（可用现金约束）。
    public static func quoteBuy(cash: Double, shares: Int, price: Double,
                                fees: FeeSnapshot) -> Result<BuyQuote, TradeReason> {
        guard price > 0, cash >= 0, price.isFinite, cash.isFinite else {
            return .failure(.invalidShareCount)
        }
        // codex R-plan-6-1：费率信任边界守卫——拒非有限/负费率，防后续除法/Int 转换 trap。
        guard fees.commissionRate.isFinite, fees.commissionRate >= 0 else { return .failure(.invalidShareCount) }
        guard shares > 0, shares % shareLotSize == 0 else { return .failure(.invalidShareCount) }
        let notional = Double(shares) * price
        let commission = computeCommission(notional: notional, fees: fees)
        let totalCost = notional + commission
        guard totalCost <= cash else { return .failure(.insufficientCash) }
        return .success(BuyQuote(shares: shares, notional: notional,
                                 commission: commission, totalCost: totalCost))
    }

    /// 按股数卖出报价。D7：shares==holding（清仓）放行任意股数（含奇数）；部分卖要求整手。
    /// R-plan-14-1：集中**可执行性契约**（输出有限 + 净现金非负），UI 与 engine 同源。
    public static func quoteSell(cash: Double, holding: Int, shares: Int, price: Double,
                                 fees: FeeSnapshot) -> Result<SellQuote, TradeReason> {
        guard price > 0, holding >= 0, price.isFinite, cash.isFinite else { return .failure(.invalidShareCount) }
        guard fees.commissionRate.isFinite, fees.commissionRate >= 0 else { return .failure(.invalidShareCount) }  // R-plan-6-1
        guard shares > 0 else { return .failure(.invalidShareCount) }
        guard shares <= holding else { return .failure(.insufficientHolding) }
        if shares != holding {                      // 部分卖才要求整手（清仓例外）
            guard shares % shareLotSize == 0 else { return .failure(.invalidShareCount) }
        }
        let q = makeSellQuote(shares: shares, price: price, fees: fees)
        // R-plan-14-1：极端价 → 输出非有限 → 失败（防 UI 格式化非有限 / engine 写脏值）。
        guard q.notional.isFinite, q.commission.isFinite, q.stampDuty.isFinite, q.proceeds.isFinite else {
            return .failure(.invalidShareCount)
        }
        // R-plan-12-1/13-1：净现金不得为负（手续费>持仓价值且现金不够覆盖）→ 不可执行。
        let newCash = cash + q.proceeds
        guard newCash.isFinite, newCash >= 0 else { return .failure(.insufficientCash) }
        return .success(q)
    }

    /// fee-aware 可买上限：满足 totalCost(N) ≤ cash 的最大 100 股整数倍。
    public static func maxBuyableShares(cash: Double, price: Double, fees: FeeSnapshot) -> Int {
        guard price > 0, cash > 0, price.isFinite, cash.isFinite else { return 0 }
        // codex R-plan-6-1：守卫费率 finite 且 ≥0 → (1+rate)≥1>0 不除零、无 inf。
        guard fees.commissionRate.isFinite, fees.commissionRate >= 0 else { return 0 }
        // codex R-plan-10-2：极小有限价会令商 +inf 或 > Int.max → robustFloor 的 Int() trap；
        // 守卫商有限且在 Int 转换界内（degenerate 行情 → 返 0 禁买，不崩）。
        let quotient = cash / (price * (1 + fees.commissionRate))
        guard quotient.isFinite, quotient < Double(Int.max) else { return 0 }
        // 上界 = 忽略 min 佣金的估值（lot 数）；min 佣金只增成本 → 真值 ≤ 此上界。
        let hiBound = robustFloor(quotient) / shareLotSize
        guard hiBound >= 1 else { return 0 }
        // totalCost(lots) 对 lots **单调增**（notional 增、commission = max(notional×rate, min) 增/平）→ 可二分。
        func totalCost(_ lots: Int) -> Double {
            let n = Double(lots * shareLotSize) * price
            return n + computeCommission(notional: n, fees: fees)
        }
        // codex R-plan-15-1：用**二分**取代逐手递减循环（tiny 价+免5 时递减可达千万次 → UI 卡死）。O(log) ≤ ~60 次。
        guard totalCost(1) <= cash else { return 0 }              // 1 手都买不起
        if totalCost(hiBound) <= cash { return hiBound * shareLotSize }   // 上界即可行
        var lo = 1, hi = hiBound                                  // lo 可行、hi 不可行
        while lo + 1 < hi {
            let mid = lo + (hi - lo) / 2
            if totalCost(mid) <= cash { lo = mid } else { hi = mid }
        }
        return lo * shareLotSize
    }

    /// 比例 → 买入快捷股数（1/5..4/5 = cash 基准 lot-floor；全仓 = maxBuyableShares）。
    public static func sharesForBuyTier(cash: Double, price: Double, tier: PositionTier,
                                        fees: FeeSnapshot) -> Int {
        if tier == .tier5 { return maxBuyableShares(cash: cash, price: price, fees: fees) }
        guard price > 0, cash >= 0, price.isFinite, cash.isFinite else { return 0 }
        // R-plan-10-2：同 maxBuyableShares，极小价令商溢出 → 守卫后 robustFloor 不 trap。
        let quotient = cash * ratio(of: tier) / price
        guard quotient.isFinite, quotient < Double(Int.max) else { return 0 }
        let raw = robustFloor(quotient)
        return (raw / shareLotSize) * shareLotSize
    }

    /// 比例 → 卖出快捷股数（1/5..4/5 = holding 基准 lot-floor；清仓 = 全部持仓含奇数）。
    public static func sharesForSellTier(holding: Int, tier: PositionTier) -> Int {
        guard holding > 0 else { return 0 }
        if tier == .tier5 { return holding }
        return (robustFloor(Double(holding) * ratio(of: tier)) / shareLotSize) * shareLotSize
    }

    /// 成交占比 → 最近档（仅供 TradeOperation.positionTier 记录展示，D4；不参与算术）。
    public static func tierForFraction(_ fraction: Double) -> PositionTier {
        let n = max(1, min(5, Int((fraction * 5).rounded(.toNearestOrAwayFromZero))))
        switch n {
        case 1: return .tier1
        case 2: return .tier2
        case 3: return .tier3
        case 4: return .tier4
        default: return .tier5
        }
    }
}
