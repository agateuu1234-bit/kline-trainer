// Kline Trainer Swift Contracts — E5 TrainingEngine (Wave 0 类型壳)
// Spec: kline_trainer_modules_v1.4.md §E5 (line 1563-1621)
// Wave 0 范围：仅类型存在，使 E6 TSC 方法签名可返回 TrainingEngine
// stored properties / public init / mutators / scenePhase 中继 / accessors：Wave 2 E5 实现 PR
// 故意 fileprivate init 防外部构造 + fatalError 防误调用

#if canImport(Observation)
import Observation
#endif

@MainActor
@Observable
public final class TrainingEngine {
    fileprivate init() {
        fatalError("Wave 0 stub: TrainingEngine 不可实例化；Wave 2 E5 PR 提供完整 init")
    }
}
