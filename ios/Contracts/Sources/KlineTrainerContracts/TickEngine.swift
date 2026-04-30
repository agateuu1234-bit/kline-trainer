// Kline Trainer Swift Contracts — E1 TickEngine
// Spec: kline_trainer_modules_v1.4.md §E1 + kline_trainer_plan_v1.5.md §3

public struct TickEngine: Equatable {
    public private(set) var globalTickIndex: Int
    public let maxTick: Int

    public init(maxTick: Int, initialTick: Int = 0) {
        self.maxTick = maxTick
        self.globalTickIndex = max(0, min(initialTick, maxTick))
    }
}
