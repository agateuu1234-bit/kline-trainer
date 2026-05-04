import Foundation
import KlineTrainerContracts

public struct DefaultTrainingSetDataVerifier: TrainingSetDataVerifying {
    public init() { }

    public func verifyNonEmpty(reader: TrainingSetReader) throws {
        let meta: TrainingSetMeta
        do {
            meta = try reader.loadMeta()
        } catch let app as AppError {
            throw app
        } catch {
            throw AppError.persistence(.dbCorrupted)
        }

        let candles: [Period: [KLineCandle]]
        do {
            candles = try reader.loadAllCandles()
        } catch let app as AppError {
            throw app
        } catch {
            throw AppError.persistence(.dbCorrupted)
        }

        let startDT = meta.startDatetime
        for period in Period.allCases {
            guard let arr = candles[period], !arr.isEmpty else {
                throw AppError.trainingSet(.emptyData)
            }
            // spec L1062：每周期 startDatetime 前 ≥30 candles
            let beforeCount = arr.lazy.filter { $0.datetime < startDT }.count
            guard beforeCount >= 30 else {
                throw AppError.trainingSet(.emptyData)
            }
            // spec L741：monthly 之后 ≥8；其它周期 ≥1（spec spirit 防 0-after trash）
            let afterCount = arr.lazy.filter { $0.datetime >= startDT }.count
            let requiredAfter = (period == .monthly) ? 8 : 1
            guard afterCount >= requiredAfter else {
                throw AppError.trainingSet(.emptyData)
            }
        }
    }
}
