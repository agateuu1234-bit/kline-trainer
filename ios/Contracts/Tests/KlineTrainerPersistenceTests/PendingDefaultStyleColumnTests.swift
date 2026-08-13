// PendingDefaultStyleColumnTests.swift
// 风格对齐同 target 的 PendingReplayPersistenceTests（swift-testing + 内存 DatabaseQueue）。
import Testing
import Foundation
@preconcurrency import GRDB
@testable import KlineTrainerPersistence
@testable import KlineTrainerContracts

@MainActor
@Suite("drawing_default_style 列：两张表 × 坏值矩阵")
struct PendingDefaultStyleColumnTests {

    /// 两张表用同一份用例跑 —— 它们是**两条各自独立的读路径**，只测一张等于只做一半。
    private enum Slot: CaseIterable { case training, replay
        var table: String { self == .training ? "pending_training" : "pending_replay" }
    }

    /// **真 repo 往返**（T1/T2）：构造带 `drawingDefaultStyle` 的对象 → `savePending`/`saveReplay`
    /// → `loadPending`/`loadReplay`。**全程不碰 raw SQL**。
    /// ⚠️ 这条必须与下面的 `seedRowThenReadStyle` **分开**（codex plan-P-R2 medium）：
    ///    那个 helper 总是先 raw UPDATE 覆写该列，于是「往返」根本没测到 repo 的 INSERT ——
    ///    把该列从 INSERT 里删掉（M2）也照样绿。**写路径必须由这条来守。**
    private func saveThenLoad(_ slot: Slot, style: DrawingDefaultStyle?) throws -> DrawingDefaultStyle? {
        let queue = try DatabaseQueue()
        try AppDBMigrations.makeMigrator().migrate(queue)
        let fee = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let dd = DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0)
        switch slot {
        case .training:
            let p = try PendingTraining(
                trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd, sessionKey: "k",
                drawingDefaultStyle: style)
            try queue.write { try PendingTrainingRepositoryImpl.savePending($0, pending: p) }
            return try queue.read { try PendingTrainingRepositoryImpl.loadPending($0) }?.drawingDefaultStyle
        case .replay:
            let p = try PendingReplay(
                recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd,
                drawingDefaultStyle: style)
            try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
            return try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }?.drawingDefaultStyle
        }
    }

    /// T1/T2 正向档：**经真写入路径**往返，逐字段相等
    @Test func repo_roundtrip_preserves_all_five_fields() throws {
        for slot in Slot.allCases {
            var s = DrawingDefaultStyle()
            s.lineSubType = .ray; s.lineStyle = .dash3; s.thickness = 4
            s.colorToken = .cyan; s.labelMode = .right
            #expect(try saveThenLoad(slot, style: s) == s, "\(slot.table) 往返丢字段")
        }
    }

    /// T3：模型里就是 nil（旧档 / 从未改过）→ 写进去是 NULL、读回来是 nil，其余字段照常
    @Test func repo_roundtrip_nil_style_stays_nil() throws {
        for slot in Slot.allCases {
            #expect(try saveThenLoad(slot, style: nil) == nil, "\(slot.table)")
        }
    }

    /// 三步：存一行 → raw SQL 把该列覆写成 `raw` → 走**真 repo 的 load 路径**读回。
    /// ⚠️ 必须经 repo 的 load，不得直接调 `DrawingDefaultStyleColumn.decode` ——
    ///    那样就测不到「repo 到底有没有接上这个函数」（M2/M3/M15 全靠这一点才有判别力）。
    /// 返回 `.some(style?)` = load 成功（内层 nil 表示列为 NULL）；`.none` = load **抛了**。
    private func seedRowThenReadStyle(_ slot: Slot, column raw: String?) throws -> DrawingDefaultStyle?? {
        let queue = try DatabaseQueue()                       // in-memory，同 PendingReplayPersistenceTests
        try AppDBMigrations.makeMigrator().migrate(queue)
        let fee = FeeSnapshot(commissionRate: 0.0001, minCommissionEnabled: true)
        let dd = DrawdownAccumulator(peakCapital: 100_000, maxDrawdown: 0)
        switch slot {
        case .training:
            let p = try PendingTraining(
                trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd, sessionKey: "k")
            try queue.write { try PendingTrainingRepositoryImpl.savePending($0, pending: p) }
        case .replay:
            let p = try PendingReplay(
                recordId: 9, trainingSetFilename: "z.sqlite", globalTickIndex: 3,
                upperPeriod: .m60, lowerPeriod: .daily, positionData: Data([7]),
                cashBalance: 88_000, feeSnapshot: fee, tradeOperations: [], drawings: [],
                startedAt: 123, accumulatedCapital: 100_000, drawdown: dd)
            try queue.write { try PendingReplayRepositoryImpl.saveReplay($0, replay: p) }
        }
        try queue.write { db in
            try db.execute(sql: "UPDATE \(slot.table) SET drawing_default_style = ? WHERE id = 1",
                           arguments: [raw])
        }
        do {
            switch slot {
            case .training: return .some(try queue.read { try PendingTrainingRepositoryImpl.loadPending($0) }?.drawingDefaultStyle ?? nil)
            case .replay:   return .some(try queue.read { try PendingReplayRepositoryImpl.loadReplay($0) }?.drawingDefaultStyle ?? nil)
            }
        } catch {
            return .none        // load 抛了 —— D92 明令这不允许发生
        }
    }

    /// T3b：列被外部置为 NULL（raw 路径）→ 仍读作 nil、不抛
    @Test func raw_null_column_reads_as_nil() throws {
        for slot in Slot.allCases {
            #expect(try seedRowThenReadStyle(slot, column: nil) == .some(nil), "\(slot.table)")
        }
    }

    /// T4：未来枚举值，**四个枚举字段各一条** —— 只测 colorToken 时，
    /// 一个「只给 colorToken 加 try?」的实现照样能过，而 {"lineStyle":"dash5"} 仍会 brick。
    @Test func future_enum_value_falls_back_field_locally() throws {
        let cases: [(String, (DrawingDefaultStyle) -> Bool)] = [
            (#"{"lineSubType":"arc","colorToken":"cyan"}"#,  { $0.lineSubType == .straight && $0.colorToken == .cyan }),
            (#"{"lineStyle":"dash5","colorToken":"cyan"}"#,  { $0.lineStyle == .solid     && $0.colorToken == .cyan }),
            (#"{"colorToken":"未来色","thickness":4}"#,       { $0.colorToken == .orange   && $0.thickness == 4 }),
            (#"{"labelMode":"center","colorToken":"cyan"}"#, { $0.labelMode == .hidden    && $0.colorToken == .cyan }),
        ]
        for slot in Slot.allCases {
            for (raw, check) in cases {
                guard let loaded = try seedRowThenReadStyle(slot, column: raw), let s = loaded else {
                    Issue.record("\(slot.table) 在 \(raw) 上抛了或返回 nil"); continue
                }
                #expect(check(s), "\(slot.table) / \(raw)：坏字段未回落或牵连了别的字段")
            }
        }
    }

    /// T5：整段不是合法 JSON → 整个默认回落，仍不抛
    @Test func invalid_json_falls_back_wholesale() throws {
        for slot in Slot.allCases {
            let loaded = try seedRowThenReadStyle(slot, column: "{{{")
            #expect(loaded == .some(DrawingDefaultStyle()), "\(slot.table)")
        }
    }

    /// T5b：**类型不匹配**，五个字段各一条 —— `decodeIfPresent(Int.self)` 能过 T4/T5 却在这里抛。
    /// ⚠️ **每条都带一个健康的 companion 字段并断言它存活**（codex plan-P-R1 medium）：
    ///    上一稿只断言「没抛且非 nil」，于是一个「任何类型不匹配就把整份默认丢回出厂」的实现
    ///    照样全绿 —— 而那**违反 D92 的逐字段回落不变量**。判据必须和 T4 对称。
    @Test func type_mismatch_falls_back_field_locally() throws {
        let cases: [(String, (DrawingDefaultStyle) -> Bool)] = [
            // 坏字段回落到出厂值；companion 字段必须**保留磁盘上的值**
            (#"{"thickness":"fat","colorToken":"cyan"}"#,
             { $0.thickness == DrawingDefaultStyle().thickness && $0.colorToken == .cyan }),
            (#"{"lineSubType":7,"colorToken":"cyan"}"#,
             { $0.lineSubType == .straight && $0.colorToken == .cyan }),
            (#"{"colorToken":null,"thickness":4}"#,
             { $0.colorToken == DrawingDefaultStyle().colorToken && $0.thickness == 4 }),
            (#"{"lineStyle":[],"colorToken":"cyan"}"#,
             { $0.lineStyle == .solid && $0.colorToken == .cyan }),
            (#"{"labelMode":{},"colorToken":"cyan"}"#,
             { $0.labelMode == .hidden && $0.colorToken == .cyan }),
        ]
        for slot in Slot.allCases {
            for (raw, check) in cases {
                guard let loaded = try seedRowThenReadStyle(slot, column: raw), let s = loaded else {
                    Issue.record("\(slot.table) 在 \(raw) 上抛了或返回 nil"); continue
                }
                #expect(check(s), "\(slot.table) / \(raw)：坏字段未回落，或把同一对象里健康的 companion 字段一起丢了")
            }
        }
    }

    /// T6 在持久化侧的落地：磁盘上的 .segment 读出来后必须已被 sanitize
    @Test func segment_on_disk_is_sanitized_on_read() throws {
        for slot in Slot.allCases {
            let loaded = try seedRowThenReadStyle(slot, column: #"{"lineSubType":"segment"}"#)
            #expect(loaded??.lineSubType == .straight, "\(slot.table)")
        }
    }
}
