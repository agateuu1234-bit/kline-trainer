import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("TrainingSession provenance 恢复（source-based 路由，RFC §4.7f）")
@MainActor
struct TrainingSessionProvenanceTests {

    @Test("训练组损坏: startNew 先选损坏文件（确定性）→ 删该文件 + 用好文件成功开局")
    func corrupt_training_set_is_deleted_and_recovered() async throws {
        // pickOverride 按 filename 升序 → 先选 "bad"（< "good"）；bad 删后选 good。
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["bad.sqlite", "good.sqlite"], corrupt: ["bad.sqlite"])
        let engine = try await coord.startNewNormalSession()
        #expect(engine.flow.mode == .normal)                       // 成功开局
        #expect(cache.deletedFilenames.contains("bad.sqlite"))     // 损坏文件被删（确定性，非 flake）
        #expect(!cache.deletedFilenames.contains("good.sqlite"))   // 好文件不删
    }

    @Test("全部损坏: 删尽 → throw .trainingSet(.fileNotFound)（caller 走重下路径）")
    func all_corrupt_exhausts_to_fileNotFound() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["a.sqlite", "b.sqlite"], corrupt: ["a.sqlite", "b.sqlite"])
        await #expect(throws: AppError.trainingSet(.fileNotFound)) {
            _ = try await coord.startNewNormalSession()
        }
        // 2 删除：fake delete 从 store 移除 → attempts(=count+1=3) 跑 删a/删b/取空 → .fileNotFound
        #expect(cache.deletedFilenames.count == 2)
    }

    @Test("app.sqlite 损坏 fail-closed: loadPending 抛 .dbCorrupted → 透传 + 零 cache.delete（安全红线）")
    func app_sqlite_corruption_never_deletes_cache() async throws {
        let (coord, _, cache, pending) = PIFixtures.makeProvenanceCoordinator(
            files: ["x.sqlite"], corrupt: [])
        pending.failNextLoadPending = .persistence(.dbCorrupted)   // app.sqlite source
        await #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try await coord.resumePending()
        }
        #expect(cache.deletedFilenames.isEmpty)                    // 绝不删训练组缓存
    }

    @Test("非损坏错误不删: diskFull 透传，不误删训练组文件")
    func non_corruption_error_does_not_delete() async throws {
        let (coord, _, cache, _) = PIFixtures.makeProvenanceCoordinator(
            files: ["y.sqlite"], corrupt: [], openError: .persistence(.diskFull))
        await #expect(throws: AppError.persistence(.diskFull)) {
            _ = try await coord.startNewNormalSession()
        }
        #expect(cache.deletedFilenames.isEmpty)
    }
}
