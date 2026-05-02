// Kline Trainer Swift Contracts — P3b
// Spec: kline_trainer_modules_v1.4.md §P3b (line 1840-1856，protocol 体 1843-1850)

public protocol TrainingSetReader: AnyObject, Sendable {
    /// 从已 openAndVerify 的 sqlite 加载元数据
    func loadMeta() throws -> TrainingSetMeta
    /// 加载全部周期 candles
    func loadAllCandles() throws -> [Period: [KLineCandle]]
    /// 关闭 reader（释放 DatabaseQueue）；调用方应在 session 结束时调用
    func close()
}
