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
}
