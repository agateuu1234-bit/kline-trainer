// 平台无关：host swift test 直跑。验缓存 DateFormatter 并发只读安全（codex spec-R2-H2 接受缓存的前提）。
import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("DateFormatter 缓存并发只读安全")
struct DateFormatterCacheConcurrencyTests {

    // 2025-01-02 01:36:00 UTC = 2025-01-02 09:36 (UTC+8)
    private let dt: Int64 = 1_735_781_760

    @Test("200 并发任务格式化 == 单线程基线（无崩溃/交叉污染）")
    func concurrentEqualsSequential() async {
        // 单线程基线
        let base1 = CrosshairLayout.formatTimeLabel(dt)
        let (baseD, baseT) = CrosshairSidebarContent.formatDateTime(datetime: dt, period: .m60)
        let baseAxisIntra = AxisGridLayout.formatTimeLabel(datetime: dt, period: .m60)
        let baseAxisDay   = AxisGridLayout.formatTimeLabel(datetime: dt, period: .daily)
        let baseAxisMon   = AxisGridLayout.formatTimeLabel(datetime: dt, period: .monthly)
        // sanity：捕捉 epoch/格式错误
        #expect(base1 == "2025-01-02 09:36")
        #expect(baseD == "2025-01-02" && baseT == "09:36")
        #expect(baseAxisIntra == "01-02 09:36")
        #expect(baseAxisDay == "2025-01-02")
        #expect(baseAxisMon == "2025-01")
        // 并发 hammer：每任务的每处输出须 == 基线
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    let (d, t) = CrosshairSidebarContent.formatDateTime(datetime: self.dt, period: .m60)
                    return CrosshairLayout.formatTimeLabel(self.dt) == base1
                        && d == baseD && t == baseT
                        && AxisGridLayout.formatTimeLabel(datetime: self.dt, period: .m60) == baseAxisIntra
                        && AxisGridLayout.formatTimeLabel(datetime: self.dt, period: .daily) == baseAxisDay
                        && AxisGridLayout.formatTimeLabel(datetime: self.dt, period: .monthly) == baseAxisMon
                }
            }
            for await ok in group { #expect(ok) }
        }
    }
}
