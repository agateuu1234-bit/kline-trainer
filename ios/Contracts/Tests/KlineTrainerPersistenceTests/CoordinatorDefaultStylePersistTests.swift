// CoordinatorDefaultStylePersistTests.swift
// 画线 P1b 本局默认持久化 Task 6：coordinator 级真-DB 装配验证——
// 两处写入（saveProgress）/ replay clean-skip 纳入新分量 / resume 两处读回种子（D94-D96）。
// harness 镜像 CoordinatorLossyPreserveTests（真 DefaultAppDB + PreviewTrainingSetDBFactory，m3Count=8→maxTick=7）。
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerContracts
@testable import KlineTrainerPersistence

#if DEBUG
@MainActor
@Suite("Coordinator：本局默认的写入 / clean-skip / 种子")
struct CoordinatorDefaultStylePersistTests {

    // MARK: - Coordinator harness（原样抄自 CoordinatorLossyPreserveTests，镜像 CoordinatorCapitalIntegrationTests.makeCoordinator）

    private func makeFreshDB() throws -> (url: URL, db: DefaultAppDB) {
        let url = try AppDBFixture.makeFreshDB()
        return (url, try DefaultAppDB(dbPath: url))
    }

    private static func candles(m3Count: Int = 8) -> [Period: [KLineCandle]] {
        func c(_ p: Period, gi: Int, egi: Int, close: Double) -> KLineCandle {
            KLineCandle(period: p, datetime: 1 + Int64(gi) * 180, open: 10, high: 11, low: 9,
                        close: close, volume: 1000, amount: nil, ma66: nil,
                        bollUpper: nil, bollMid: nil, bollLower: nil,
                        macdDiff: nil, macdDea: nil, macdBar: nil,
                        globalIndex: gi, endGlobalIndex: egi)
        }
        let m3 = (0..<m3Count).map { c(.m3, gi: $0, egi: $0, close: 10 + Double($0) * 0.1) }
        let last = m3Count - 1
        let m60 = [c(.m60, gi: 0, egi: last / 2, close: 10.3),
                   c(.m60, gi: last / 2 + 1, egi: last, close: 10.7)]
        let daily = [c(.daily, gi: 0, egi: last, close: 10.7)]
        return [.m3: m3, .m60: m60, .daily: daily]
    }

    private func makeCoordinator(db appDB: DefaultAppDB) -> TrainingSessionCoordinator {
        let cache = InMemoryCacheManager()
        cache._seedForTesting([TrainingSetFile(id: 1, filename: "set.sqlite",
            localURL: URL(fileURLWithPath: "/tmp/set.sqlite"),
            schemaVersion: 1, lastAccessedAt: 1, downloadedAt: 1)])
        return TrainingSessionCoordinator(
            dbFactory: PreviewTrainingSetDBFactory(candles: Self.candles()),
            recordRepo: appDB, pendingRepo: appDB,
            pendingReplayRepo: appDB, reviewArchiveRepo: appDB,
            finalization: appDB, settingsDAO: appDB, cache: cache,
            settings: SettingsStore(settingsDAO: appDB))
    }

    /// 最小合法 finalized record（finalTick=7 与 candles 一致；filename="set.sqlite" ↔ cache 注册的文件一致），
    /// 供 replay(recordId:) 入口使用（镜像 CoordinatorLossyPreserveTests.makeRecord）。
    private func seedFinishedRecord(db appDB: DefaultAppDB) throws -> Int64 {
        try appDB.insertRecord(TrainingRecord(
            id: nil, trainingSetFilename: "set.sqlite", createdAt: 1,
            stockCode: "000001", stockName: "股", startYear: 2020, startMonth: 1,
            totalCapital: 100_000, profit: 0, returnRate: 0, maxDrawdown: -0.03,
            buyCount: 0, sellCount: 0,
            feeSnapshot: FeeSnapshot(commissionRate: 0.0002, minCommissionEnabled: false),
            finalTick: 7), ops: [], drawings: [])
    }

    private func nonDefaultStyle() -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = .ray; s.lineStyle = .dash3; s.thickness = 4
        s.colorToken = .cyan; s.labelMode = .right
        return s
    }

    /// T10：`saveProgress` 的写入载荷里**带着**本局默认（值传递）。
    /// ⚠️ 它**不是** D94 的证据 —— D94 是 `TrainingView` 的 `.onChange`，host 够不着，靠守卫 G6。
    @Test func saveProgress_payload_carries_default_style() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = makeCoordinator(db: db)
        let engine = try await coordinator.startNewNormalSession()
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)
        try await coordinator.saveProgress(engine: engine)
        let back = try db.loadPending()
        #expect(back?.drawingDefaultStyle == s)
    }

    /// T11：**fresh replay 只改默认** → `saveReplay` 确实写了（clean-skip 未跳过）。
    /// clean-skip 的**唯一**守门：tick/ops/drawingsSig/upper/lower 五个旧分量一个没变，
    /// 少了第六个分量就会被整条跳过、槽里什么都没有。
    @Test func fresh_replay_default_only_change_is_not_clean_skipped() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = makeCoordinator(db: db)
        let recordId = try seedFinishedRecord(db: db)
        let engine = try await coordinator.replay(recordId: recordId)
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)               // 只改默认：其余五个分量一个没动
        try await coordinator.saveProgress(engine: engine)
        #expect(try db.loadReplay()?.drawingDefaultStyle == s, "clean-skip 把「只改默认」整条跳过了")
    }

    /// T13：normal 断点续训继承
    @Test func resume_normal_seeds_default_style() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = makeCoordinator(db: db)
        let engine = try await coordinator.startNewNormalSession()
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)
        try await coordinator.saveProgress(engine: engine)
        let resumed = try #require(try await makeCoordinator(db: db).resumePending())
        #expect(resumed.drawingSession.defaultStyle == s)
    }

    /// T12：replay 断点续局继承
    @Test func resume_replay_seeds_default_style() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let coordinator = makeCoordinator(db: db)
        let recordId = try seedFinishedRecord(db: db)
        let engine = try await coordinator.replay(recordId: recordId)
        let s = nonDefaultStyle()
        engine.drawingSession.setDefaultStyle(s)
        try await coordinator.saveProgress(engine: engine)
        let resumed = try #require(try await makeCoordinator(db: db).resumePendingReplay(recordId: recordId))
        #expect(resumed.drawingSession.defaultStyle == s)
    }

    /// T14：**fresh 会话不种** —— 新局必须回落出厂值（用户 2026-08-13 裁决）
    @Test func fresh_session_does_not_seed() async throws {
        let (url, db) = try makeFreshDB(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let c1 = makeCoordinator(db: db)
        let e1 = try await c1.startNewNormalSession()
        e1.drawingSession.setDefaultStyle(nonDefaultStyle())
        try await c1.saveProgress(engine: e1)
        // 结束本局 → 开新局：不得继承
        try db.clearPending()
        let e2 = try await makeCoordinator(db: db).startNewNormalSession()
        #expect(e2.drawingSession.defaultStyle == DrawingDefaultStyle())
    }
}
#endif
