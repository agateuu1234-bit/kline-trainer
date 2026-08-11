import Testing
@testable import KlineTrainerContracts

@Suite("DrawingSignature")
struct DrawingSignatureTests {

    @Test("canonicalDrawingsSignature: 语义相等→签名相等，字段变→签名变")
    func canonicalSignatureSemantics() throws {
        let a     = makeHLine(id: "x", candleIndex: 3, price: 10, thickness: 1)   // fixture 见「测试 fixture」节
        let aSame = makeHLine(id: "x", candleIndex: 3, price: 10, thickness: 1)
        let aThick = makeHLine(id: "x", candleIndex: 3, price: 10, thickness: 3)
        #expect(canonicalDrawingsSignature([a]) == canonicalDrawingsSignature([aSame]))  // 语义相等→签名相等
        #expect(canonicalDrawingsSignature([a]) != canonicalDrawingsSignature([aThick])) // 改 thickness→签名变
        #expect(canonicalDrawingsSignature([]) != canonicalDrawingsSignature([a]))       // 空 vs 一条
    }

    @Test("canonicalDrawingsSignature: id/text 含分隔符也不碰撞（codex plan-R2-F1，单射）")
    func canonicalSignatureInjectiveWithSeparators() throws {
        // 裸分隔符 join 会让这两个语义不同的数组产出相同签名；长度前缀编码不会。
        let x = makeHLine(id: "a\u{1F}b", text: "c")      // id 里塞了旧设计的字段分隔符 0x1F
        let y = makeHLine(id: "a", text: "b\u{1F}c")      // 挪到 text 里——裸 join 下与 x 拼出同串
        #expect(canonicalDrawingsSignature([x]) != canonicalDrawingsSignature([y]))
        // 条分隔符同理：两条 vs 一条含 0x1E 的 text
        let p = [makeHLine(id: "p"), makeHLine(id: "q")]
        let r = [makeHLine(id: "p", text: "\u{1E}q")]
        #expect(canonicalDrawingsSignature(p) != canonicalDrawingsSignature(r))
    }

    /// ⚠️ **本条无红绿验，是不变式复述而非回归测试**（Opus-F6）：`tailAnchor` 的三个子字段是
    /// `candleIndex`(Int) / `price`(Double) / `period.rawValue`（`3m`/`daily` 等），**都不可能含逗号**，
    /// 故旧的逗号拼接本来就单射——把实现改回逗号拼接，下面两条断言照样绿。Step 5 的改动价值在
    /// **纪律统一**（本文件所有字段一律长度前缀，不留"这个字段特殊"的例外），不在修 bug。
    @Test("canonicalDrawingsSignature: tailAnchor 子字段也走长度前缀（单射纪律无例外；无红绿验，见上）")
    func tailAnchorSubfieldsAreLengthPrefixed() throws {
        func withTail(_ id: String, _ ci: Int, _ price: Double) -> DrawingObject {
            DrawingObject(id: id, toolType: .horizontal,
                          anchors: [DrawingAnchor(period: .daily, candleIndex: 3, price: 10)],
                          isExtended: false, panelPosition: 0, period: .daily,
                          tailAnchor: DrawingAnchor(period: .daily, candleIndex: ci, price: price))
        }
        // 两条只差 tailAnchor 内容 → 签名必须不同
        #expect(canonicalDrawingsSignature([withTail("t", 1, 2)]) != canonicalDrawingsSignature([withTail("t", 12, 0)]))
        // 有 tailAnchor vs 无 tailAnchor → 签名必须不同
        let noTail = makeHLine(id: "t")
        #expect(canonicalDrawingsSignature([withTail("t", 1, 2)]) != canonicalDrawingsSignature([noTail]))
    }

    /// 不变量锁（1b-ii PR-1 修复轮1，user 亲验发现）：`resumePendingReplay`（`TrainingSessionCoordinator:945`）
    /// 会把 `replayHasPersisted` 置 `true`（「续局本就拥有该记录的槽 → 永不 clean-skip」）。这意味着
    /// `saveProgress` 的 replay clean-skip 判据（依赖本签名）**在续局路径上今天永不求值** —— 拿掉
    /// `canonicalDrawingsSignature` 里的 `String(d.locked)` 那一行，全套 1827+ 条测试（含 L13b）**全绿不变**。
    /// 本条不测「今天会不会丢」（今天不会，因为这条路径不可达），测的是**若未来那个时机被改动**、
    /// clean-skip 在续局也生效了，签名本身是否对 `locked` 敏感 —— 敏感性是「以后不静默丢锁定」的地基。
    /// D30② 裁定：本 PR 不改 `replayHasPersisted` 时机、不动 clean-skip 判据，只加这条锁。
    @Test("签名不变量: 只翻转 locked 必须改变 canonicalDrawingsSignature（clean-skip 的敏感性依赖它）")
    func lockedIsPartOfDrawingsSignature() {
        let a = makeHorizontalDrawing(id: "SIG", locked: false)
        let b = makeHorizontalDrawing(id: "SIG", locked: true)
        #expect(canonicalDrawingsSignature([a]) != canonicalDrawingsSignature([b]),
                "签名对 locked 失明 → 若将来 clean-skip 在续局路径上生效，只锁定的改动会被静默丢弃")
    }
}
