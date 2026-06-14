import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("cache touch-on-use（E6a-R3）：read 路径成功打开后刷新 LRU mtime")
@MainActor
struct CacheTouchOnUseTests {

    @Test("startNewNormalSession 成功打开 → touch 该训练组")
    func startNewNormal_touchesOpenedFile() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        _ = try await coord.startNewNormalSession()
        #expect(cache.touchedFilenames == ["a.sqlite"])
    }

    @Test("resumePending 成功打开 → touch 该训练组")
    func resumePending_touchesOpenedFile() async throws {
        let (coord, _, cache, pending) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        engine.holdOrObserve(panel: .upper)
        try await coord.saveProgress(engine: engine)
        await coord.endSession()
        let resumed = try await coord.resumePending()
        #expect(resumed != nil)
        #expect(cache.touchedFilenames.contains("a.sqlite"))
        _ = pending
    }

    @Test("review 成功打开 → touch 该训练组")
    func review_touchesOpenedFile() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: engine)
        await coord.endSession()
        _ = try await coord.review(recordId: id!)
        #expect(cache.touchedFilenames.contains("a.sqlite"))
    }

    @Test("replay 成功打开 → touch 该训练组")
    func replay_touchesOpenedFile() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(files: ["a.sqlite"], corrupt: [])
        let engine = try await coord.startNewNormalSession()
        while engine.tick.globalTickIndex < engine.tick.maxTick { engine.holdOrObserve(panel: .upper) }
        let id = try await coord.finalize(engine: engine)
        await coord.endSession()
        _ = try await coord.replay(recordId: id!)
        #expect(cache.touchedFilenames.contains("a.sqlite"))
    }

    @Test("损坏训练组被删除而非 touch（startNewNormal 跳损坏选下一个）")
    func corruptFile_isDeletedNotTouched() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["bad.sqlite", "good.sqlite"], corrupt: ["bad.sqlite"])
        _ = try await coord.startNewNormalSession()
        #expect(cache.deletedFilenames.contains("bad.sqlite"))
        #expect(!cache.touchedFilenames.contains("bad.sqlite"), "损坏文件不应被 touch（已删）")
        #expect(cache.touchedFilenames == ["good.sqlite"], "仅成功打开的 good 被 touch")
    }
}
