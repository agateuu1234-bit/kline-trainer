import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("Drawing P1a — 支撑枚举")
struct DrawingEnumsTests {
    @Test("五枚举 rawValue 稳定 + CaseIterable 计数")
    func rawValuesStable() {
        #expect(LineSubType.allCases.map(\.rawValue) == ["straight", "ray", "segment"])
        #expect(LineStyle.allCases.map(\.rawValue) == ["solid", "dash1", "dash2", "dash3", "dash4"])
        #expect(DrawingColorToken.allCases.map(\.rawValue)
            == ["red", "orange", "yellow", "green", "cyan", "blue", "purple", "black", "white"])
        #expect(LabelMode.allCases.map(\.rawValue) == ["hidden", "show", "left", "right"])
        #expect(TextForm.allCases.map(\.rawValue) == ["borderTransparent", "borderFilled", "plain"])
    }

    @Test("DrawingID 是 String 别名")
    func drawingIdIsString() {
        let id: DrawingID = "gen-abc"
        #expect(id == "gen-abc")
    }
}

@Suite("Drawing P1a — DrawingToolType 11 工具")
struct DrawingToolTypeExpansionTests {
    @Test("新增 6 工具 case + 保留 legacy ray/time 可解码")
    func elevenPlusLegacy() throws {
        // 11 目标工具都能从 rawValue 构造
        for raw in ["horizontal", "trend", "channel", "polyline", "golden",
                    "wave", "cycle", "fib", "timeRuler", "text", "rect"] {
            #expect(DrawingToolType(rawValue: raw) != nil, "缺工具 \(raw)")
        }
        // legacy 两 case 仍可解码（历史 blob 兼容）
        #expect(DrawingToolType(rawValue: "ray") == .ray)
        #expect(DrawingToolType(rawValue: "time") == .time)
    }
}

@Suite("Drawing P1a — DrawingObject 全字段 Codable")
struct DrawingObjectCodableTests {
    private func sampleAnchor() -> DrawingAnchor {
        DrawingAnchor(period: .m60, candleIndex: 3, price: 1710.5)
    }

    @Test("全字段编码→解码往返一致")
    func fullRoundTrip() throws {
        let d = DrawingObject(
            id: "gen-1", toolType: .trend, anchors: [sampleAnchor(), sampleAnchor()],
            isExtended: true, panelPosition: 1, revealTick: 42,
            period: .m60, lineSubType: .segment, lineStyle: .dash2, thickness: 4,
            colorToken: .blue, labelMode: .right, locked: true,
            text: "颈线", fontSize: 20, textColorToken: .red, textForm: .borderFilled,
            tailAnchor: sampleAnchor())
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(back == d)
    }

    @Test("tailAnchor 为 nil 时全字段往返一致（encodeIfPresent 不写 key，decodeIfPresent 读回 nil）")
    func roundTripTailAnchorNil() throws {
        let d = DrawingObject(
            id: "gen-2", toolType: .horizontal, anchors: [sampleAnchor()],
            isExtended: false, panelPosition: 0, revealTick: 5,
            period: .m60, lineSubType: .straight, lineStyle: .solid, thickness: 2,
            colorToken: .green, labelMode: .show, locked: false,
            text: "", fontSize: 14, textColorToken: .orange, textForm: .plain,
            tailAnchor: nil)
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DrawingObject.self, from: data)
        #expect(back == d)
        #expect(back.tailAnchor == nil)
    }

    @Test("旧 blob（仅 5 字段）解码 → 新字段取语义默认")
    func legacyBlobDefaults() throws {
        // 模拟 #139 时代的 DrawingObject JSON（无新字段）
        let legacy = """
        {"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":2,"price":9.9}],
         "isExtended":true,"panelPosition":0,"revealTick":7}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(DrawingObject.self, from: legacy)
        #expect(d.lineSubType == .ray)          // isExtended:true → .ray（迁移映射）
        #expect(d.lineStyle == .solid)
        #expect(d.thickness == 1)
        #expect(d.colorToken == .orange)
        #expect(d.labelMode == .hidden)
        #expect(d.locked == false)
        #expect(d.text == "")
        #expect(d.tailAnchor == nil)
        #expect(d.period == .m3)                // 取 anchors.first.period
        #expect(d.id.isEmpty == true)            // 无 id → 解码为空串（Task 5 数组层按位回填 legacy-idx-<N>）
    }
}

@Suite("Drawing P1a — 有损解码 + 保真回写")
struct LossyDrawingArrayTests {
    @Test("未知 toolType 单条只跳过、不整组失败")
    func skipsUnknownOnly() throws {
        let json = Data(#"[{"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0,"revealTick":0},{"toolType":"__future_tool__","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}]"#.utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.count == 1)            // 只保 horizontal
        #expect(arr.drawings[0].toolType == .horizontal)
        #expect(arr.unknownRaw.count == 1)          // future_tool 保原文
        #expect(arr.unknownRaw[0].contains("__future_tool__"))
    }

    @Test("保真回写：未识别条逐字节等于原始输入（不只子串）")
    func roundTripBytePerfect() throws {
        // 未来条：特意的 key 顺序（z 在前 a 在后）+ 数字格式 1.0 / 高精度尾数——只有原样保留才能全等。
        let unknownElem = #"{"toolType":"__future__","z_last":1.0,"a_first":"x, ]}\"escaped","p":0.10000000000000001}"#
        let json = Data("[\(unknownElem)]".utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.isEmpty)
        #expect(arr.unknownRaw == [unknownElem])              // 原始文本逐字符保留（未重序列化）
        let out = try arr.encoded()
        #expect(out == json)                                  // 单元素数组 → 逐字节等于原始
        let reparsed = try LossyDrawingArray.decode(out)      // 幂等
        #expect(reparsed.unknownRaw == [unknownElem])
    }

    @Test("已知条 + 未知条混排：已知存活、未知保真、幂等")
    func mixedKnownUnknownIdempotent() throws {
        let unknown = #"{"toolType":"__future__","weird":[1,2,{"x":"]"}]}"#
        let known = #"{"id":"g1","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}"#
        let json = Data(("[" + known + "," + unknown + "]").utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.count == 1)
        #expect(arr.drawings[0].id == "g1")
        #expect(arr.unknownRaw.count == 1)
        // 未识别条经切分器 trim 两侧空白后仍应保内部字节（含字符串里的 ']'）
        #expect(arr.unknownRaw[0].contains(#"{"x":"]"}"#))
        // encoded→decode 幂等：已知 1 条 + 未知 1 条
        let r2 = try LossyDrawingArray.decode(try arr.encoded())
        #expect(r2.drawings.count == 1 && r2.unknownRaw.count == 1)
    }

    // MARK: - codex WB R11 finding：畸形元素不得被洗白成 durable unknownRaw（须 fail-closed → .dbCorrupted）

    @Test("畸形元素（非 JSON）→ decode 抛 .dbCorrupted，不洗白成 unknownRaw（codex WB R11-high 红→绿）")
    func malformedNonJsonElementThrows() throws {
        let json = Data(#"[not-json]"#.utf8)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try LossyDrawingArray.decode(json)
        }
    }

    @Test("畸形元素（标量 123）→ decode 抛 .dbCorrupted（codex WB R11-high 红→绿）")
    func scalarElementThrows() throws {
        let json = Data(#"[123]"#.utf8)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try LossyDrawingArray.decode(json)
        }
    }

    @Test("畸形元素（空对象 {}，无 toolType）→ decode 抛 .dbCorrupted，不再洗白成 unknownRaw（codex WB R11-high 红→绿）")
    func emptyObjectElementThrows() throws {
        let json = Data(#"[{}]"#.utf8)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try LossyDrawingArray.decode(json)
        }
    }

    @Test("对照组：合法未来对象（有非空字符串 toolType）→ 仍保留为 .unknownRaw（不因 R11 修复破坏前向兼容）")
    func plausibleFutureDrawingStillPreserved() throws {
        let json = Data(#"[{"id":"x","toolType":"futureTool","anchors":[]}]"#.utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings.isEmpty)
        #expect(arr.unknownRaw.count == 1)
        #expect(arr.unknownRaw[0].contains("futureTool"))
    }

    // MARK: - codex WB R12 finding：已知 toolType 但 DrawingObject 解码失败 = 损坏，不得被 R11 的门洗白成 unknownRaw

    @Test("已知 toolType（horizontal）但缺必填字段 → decode 抛 .dbCorrupted，不再洗白成 unknownRaw（codex WB R12-high 红→绿）")
    func knownToolTypeMissingRequiredFieldsThrows() throws {
        let json = Data(#"[{"toolType":"horizontal"}]"#.utf8)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try LossyDrawingArray.decode(json)
        }
    }

    @Test("已知 toolType（horizontal）但字段类型错（thickness 是字符串）→ decode 抛 .dbCorrupted（codex WB R12-high 红→绿）")
    func knownToolTypeWrongFieldTypeThrows() throws {
        let json = Data(#"[{"toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"thickness":"not-a-number"}]"#.utf8)
        #expect(throws: AppError.persistence(.dbCorrupted)) {
            _ = try LossyDrawingArray.decode(json)
        }
    }

    @Test("保序：[known, unknownFuture, known] 往返后元素顺序逐一保持")
    func preservesElementOrder() throws {
        let kA = #"{"id":"A","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}"#
        let uF = #"{"toolType":"__future__","mid":true}"#
        let kB = #"{"id":"B","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0}"#
        let json = Data(("[" + kA + "," + uF + "," + kB + "]").utf8)
        let arr = try LossyDrawingArray.decode(json)
        // elements 有序：第 0=known A、第 1=unknownRaw future、第 2=known B
        guard arr.elements.count == 3,
              case .known(let a, _) = arr.elements[0],
              case .unknownRaw(let mid) = arr.elements[1],
              case .known(let b, _) = arr.elements[2] else { Issue.record("顺序错"); return }
        #expect(a.id == "A" && b.id == "B" && mid == uF)
        // 回写后未识别条仍在【中间】（不被排到末尾）
        let out = String(decoding: try arr.encoded(), as: UTF8.self)
        #expect(out.range(of: "__future__")!.lowerBound > out.range(of: "\"A\"")!.lowerBound)
        #expect(out.range(of: "__future__")!.lowerBound < out.range(of: "\"B\"")!.lowerBound)
    }

    @Test("切分器：正确按顶层元素切、忽略字符串内的括号逗号")
    func splitterHandlesNestingAndStrings() throws {
        let data = Data(#"[ {"a":"x,]y","b":[1,2]} , {"c":{"d":"}"}} ]"#.utf8)
        let elems = JSONTopLevelArray.rawElementStrings(data)
        #expect(elems?.count == 2)
        #expect(elems?[0] == #"{"a":"x,]y","b":[1,2]}"#)      // 去两侧空白、内部原样
        #expect(elems?[1] == #"{"c":{"d":"}"}}"#)
        #expect(JSONTopLevelArray.rawElementStrings(Data("[]".utf8)) == [])   // 空数组
        #expect(JSONTopLevelArray.rawElementStrings(Data("{}".utf8)) == nil)  // 非数组 → nil
    }

    @Test("无 id 成功条按下标回填 legacy-idx-<index>")
    func backfillsLegacyIndexId() throws {
        let json = Data(#"[{"toolType":"horizontal","anchors":[{"period":"3m","candleIndex":1,"price":9.0}],"isExtended":false,"panelPosition":0}]"#.utf8)
        let arr = try LossyDrawingArray.decode(json)
        #expect(arr.drawings[0].id == "legacy-idx-0")
    }

    // ── W1（codex plan-R12-high）：现有 toolType 上的【未来未知字段】也须保真 ──
    @Test("已知工具 horizontal + 未来字段：decode 成 .known、未编辑 encoded() 逐字节保留未来字段")
    func knownToolFutureFieldSurvivesUnedited() throws {
        // 合法 horizontal（所有必填字段都在）+ 未来客户端加的 "futureX"/"futureObj"
        let future = #"{"id":"K","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureX":9,"futureObj":{"k":1}}"#
        let arr = try LossyDrawingArray.decode(Data(("[" + future + "]").utf8))
        #expect(arr.drawings.count == 1)                       // 解码成功（未来字段被 JSONDecoder 忽略）
        #expect(arr.drawings[0].id == "K")
        let out = String(decoding: try arr.encoded(), as: UTF8.self)
        #expect(out.contains("\"futureX\":9"))                 // 未编辑→原样字节，未来字段仍在
        #expect(out.contains("\"futureObj\""))
    }

    @Test("已知工具 horizontal + 未来字段：编辑已知字段后 merge 仍保未来 key、且已知字段已更新")
    func knownToolFutureFieldSurvivesEdit() throws {
        let future = #"{"id":"K","toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","futureX":9}"#
        let arr = try LossyDrawingArray.decode(Data(("[" + future + "]").utf8))
        var edited = arr.drawings[0]
        edited = DrawingObject(id: edited.id, toolType: edited.toolType, anchors: edited.anchors,
            isExtended: edited.isExtended, panelPosition: edited.panelPosition, revealTick: edited.revealTick,
            period: edited.period, lineSubType: edited.lineSubType, lineStyle: edited.lineStyle,
            thickness: 5, colorToken: edited.colorToken, labelMode: edited.labelMode, locked: edited.locked,
            text: edited.text, fontSize: edited.fontSize, textColorToken: edited.textColorToken,
            textForm: edited.textForm, tailAnchor: edited.tailAnchor)     // 改 thickness 1→5
        let out = String(decoding: try arr.reconciled(currentKnown: [edited]).encoded(), as: UTF8.self)
        #expect(out.contains("\"futureX\":9"))                 // merge 后未来 key 仍在
        #expect(out.contains("\"thickness\":5"))               // 已知字段已更新
    }

    @Test("编辑把可选已知字段 tailAnchor 清空 → 输出不再含 tailAnchor（不从旧 raw 复活）、未来 key 仍在")
    func editClearingOptionalKnownFieldRemovesIt() throws {
        // 原 raw 有 tailAnchor（带框标注）+ 未来 key
        let raw = #"{"id":"K","toolType":"text","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"hi","fontSize":14,"textColorToken":"orange","textForm":"borderFilled","tailAnchor":{"period":"3m","candleIndex":5,"price":10},"futureX":9}"#
        let arr = try LossyDrawingArray.decode(Data(("[" + raw + "]").utf8))
        let e = arr.drawings[0]
        let cleared = DrawingObject(id: e.id, toolType: e.toolType, anchors: e.anchors,
            isExtended: e.isExtended, panelPosition: e.panelPosition, revealTick: e.revealTick,
            period: e.period, lineSubType: e.lineSubType, lineStyle: e.lineStyle, thickness: e.thickness,
            colorToken: e.colorToken, labelMode: e.labelMode, locked: e.locked, text: e.text,
            fontSize: e.fontSize, textColorToken: e.textColorToken, textForm: e.textForm,
            tailAnchor: nil)                                    // 尾巴清空（切到无框形式/删尾巴）
        let out = String(decoding: try arr.reconciled(currentKnown: [cleared]).encoded(), as: UTF8.self)
        #expect(!out.contains("tailAnchor"))                   // 已清空的可选已知字段不复活（codex R13-high）
        #expect(out.contains("\"futureX\":9"))                 // 未来未知 key 仍保留
    }

    @Test("reconciled fail-closed：loaded 元素含重复 id → 抛 .dbCorrupted（不静默折叠）")
    func reconciledRejectsDuplicateLoadedIds() throws {
        let d = DrawingObject(id: "dup", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let raw = try LossyDrawingArray.encodeKnown(d)
        let lossy = LossyDrawingArray(elements: [.known(d, raw: raw), .known(d, raw: raw)])
        #expect(throws: AppError.self) { _ = try lossy.reconciled(currentKnown: [d]) }
    }

    @Test("reconciled fail-closed：currentKnown 含重复 id → 抛 .dbCorrupted")
    func reconciledRejectsDuplicateCurrentIds() throws {
        let d = DrawingObject(id: "dup", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let raw = try LossyDrawingArray.encodeKnown(d)
        let lossy = LossyDrawingArray(elements: [.known(d, raw: raw)])
        #expect(throws: AppError.self) { _ = try lossy.reconciled(currentKnown: [d, d]) }   // 两条同 id
    }

    // codex whole-branch High fix：`encodeKnown` 曾用 `try? ... else return "{}"` 吞掉非有限价
    // （NaN/Infinity）的 JSONEncoder 失败，把该条静默伪造成 `"{}"` 持久化——下次加载 `"{}"` 解不出
    // DrawingObject → 被归类 `.unknownRaw`，用户这条已知画线无声消失（durable data loss）。fail-closed
    // 后必须抛错（不再吞、不再伪造 `{}`），让调用方（save 路径）失败并经既有 autosave 错误通路呈现给用户。
    @Test("fail-closed：非有限价（NaN/Infinity）DrawingObject 编码抛错，不再伪造 {}（红→绿：修前会静默返回 {} 不抛）")
    func nonFiniteAnchorPriceThrowsInsteadOfFabricatingEmptyObject() throws {
        let nanDrawing = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: .nan)],
            isExtended: false, panelPosition: 0)
        let infDrawing = DrawingObject(toolType: .horizontal,
            anchors: [DrawingAnchor(period: .m3, candleIndex: 1, price: .infinity)],
            isExtended: false, panelPosition: 0)
        // 直接单元：encodeKnown 本身抛（不是 catch 后 fallback 成 "{}"）。
        #expect(throws: EncodingError.self) { _ = try LossyDrawingArray.encodeKnown(nanDrawing) }
        #expect(throws: EncodingError.self) { _ = try LossyDrawingArray.encodeKnown(infDrawing) }
        // 级联 1：批量构造 init(drawings:) 传播（不吞、不让整批 fallback 成 "{}"）。
        #expect(throws: EncodingError.self) { _ = try LossyDrawingArray(drawings: [nanDrawing]) }
        // 级联 2：reconciled 真新增追加路径（末尾 `out.append(.known(k, raw: try encodeKnown(k)))`）同样传播。
        let empty = LossyDrawingArray(elements: [])
        #expect(throws: EncodingError.self) { _ = try empty.reconciled(currentKnown: [nanDrawing]) }
    }

    @Test("reconciled 按 id：删 unknown 之前的 known → 未来条仍在原位（不被后续 known 挤到前面）")
    func reconciledByIdPreservesOrderOnDelete() throws {
        let a = DrawingObject(id: "gA", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let bK = DrawingObject(id: "gB", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let unknown = #"{"toolType":"__future__","weird":true}"#
        let lossy = try LossyDrawingArray(elements: [
            .known(a, raw: LossyDrawingArray.encodeKnown(a)),
            .unknownRaw(unknown),
            .known(bK, raw: LossyDrawingArray.encodeKnown(bK))
        ])
        let out = String(decoding: try lossy.reconciled(currentKnown: [bK]).encoded(), as: UTF8.self)  // 删了 A
        let iU = out.range(of: "__future__")!.lowerBound
        let iB = out.range(of: #""gB""#)!.lowerBound
        #expect(iU < iB)                                               // 未来条仍在 B 之前（原位），非位置法的 [B, 未来]
        #expect(!out.contains(#""gA""#))                              // A 已删
    }

    @Test("reconciled 未编辑短路：cur == old → 原始 raw 逐字节保留（不重序列化，防 key 重排/数字重格式）")
    func reconciledUneditedEmitsOriginalRawVerbatim() throws {
        // 特意的异常 key 顺序（zzz 在最前、id 在最后）+ 数字用 1.0（JSONSerialization 重序列化后会变 1 或 key 重排）。
        let raw = #"{"zzz_marker":true,"toolType":"horizontal","anchors":[],"isExtended":false,"panelPosition":0,"revealTick":0,"period":"3m","lineSubType":"straight","lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,"text":"","fontSize":14,"textColorToken":"orange","textForm":"plain","id":"K"}"#
        let arr = try LossyDrawingArray.decode(Data(("[" + raw + "]").utf8))
        let unedited = arr.drawings[0]
        let out = try arr.reconciled(currentKnown: [unedited]).encoded()
        #expect(String(decoding: out, as: UTF8.self) == "[" + raw + "]")   // 逐字节等于原始 raw，未重序列化
    }

    // ── codex WB R8 finding 2：load 时归一化重复/空已知 id（防 autosave/finalize 的 reconciled fail-close brick）──

    @Test("normalizedUniqueIds：重复 known id → 首个原样字节不变，后出现的换发新 UUID；unknownRaw 原样不变、顺序不变（codex WB R8 finding 2）")
    func normalizedUniqueIdsReassignsDuplicateKnownIds() throws {
        let d = DrawingObject(id: "dup", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let raw = try LossyDrawingArray.encodeKnown(d)
        let unknown = #"{"toolType":"__future__","z":1}"#
        let lossy = LossyDrawingArray(elements: [.known(d, raw: raw), .unknownRaw(unknown), .known(d, raw: raw)])
        let out = try lossy.normalizedUniqueIds()
        guard out.elements.count == 3,
              case .known(let first, let firstRaw) = out.elements[0],
              case .unknownRaw(let mid) = out.elements[1],
              case .known(let second, let secondRaw) = out.elements[2] else {
            Issue.record("形状变了"); return
        }
        #expect(first.id == "dup" && firstRaw == raw)              // 首次出现（此时唯一）→ 原样不变
        #expect(mid == unknown)                                    // 未识别条原样不变
        #expect(second.id != "dup")                                // 后出现的重复 → 换发新 id
        #expect(!secondRaw.contains(#""id":"dup""#))              // raw 已按新 id 重新 encode
        // 归一化后对同批 currentKnown 可安全 reconciled（此前因 loaded 侧重复会 fail-closed）。
        #expect(throws: Never.self) { _ = try out.reconciled(currentKnown: out.drawings) }
    }

    @Test("normalizedUniqueIds：空 id known → 换发新 UUID；唯一非空 id known 原样字节不变")
    func normalizedUniqueIdsReassignsEmptyId() throws {
        let empty = DrawingObject(id: "", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let rawEmpty = try LossyDrawingArray.encodeKnown(empty)
        let unique = DrawingObject(id: "u1", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let rawUnique = try LossyDrawingArray.encodeKnown(unique)
        let lossy = LossyDrawingArray(elements: [.known(empty, raw: rawEmpty), .known(unique, raw: rawUnique)])
        let out = try lossy.normalizedUniqueIds()
        guard case .known(let first, _) = out.elements[0],
              case .known(let second, let secondRaw) = out.elements[1] else {
            Issue.record("形状变了"); return
        }
        #expect(!first.id.isEmpty)                                 // 空 id 已换发
        #expect(second.id == "u1" && secondRaw == rawUnique)       // 唯一非空 id → 原样不变
    }

    @Test("normalizedUniqueIds：重复 known id 且后出现那条携带未来字段 → 换发新 id 后未来字段仍保留在新 raw 里（不再用 encodeKnown 丢未来字段）（codex WB R10 finding 2）")
    func normalizedUniqueIdsPreservesFutureFieldOnRename() throws {
        let d = DrawingObject(id: "dup", toolType: .horizontal, anchors: [], isExtended: false, panelPosition: 0)
        let plainRaw = try LossyDrawingArray.encodeKnown(d)
        let futureRaw = String(plainRaw.dropLast()) + #","futureField":1}"#
        let lossy = LossyDrawingArray(elements: [.known(d, raw: plainRaw), .known(d, raw: futureRaw)])
        let out = try lossy.normalizedUniqueIds()
        guard out.elements.count == 2,
              case .known(let first, let firstRaw) = out.elements[0],
              case .known(let second, let secondRaw) = out.elements[1] else {
            Issue.record("形状变了"); return
        }
        #expect(first.id == "dup" && firstRaw == plainRaw)          // 首次出现（此时唯一）→ 原样不变
        #expect(second.id != "dup" && second.id != first.id)        // 后出现的重复 → 换发新 id，与首条不同
        #expect(secondRaw.contains(#""futureField":1"#))            // 未来字段在换发新 id 后的 raw 里仍存活
    }
}

@Suite("Drawing P1a — 复盘 canonical wrapper")
struct ReviewArchiveWrapperTests {
    private func d(_ id: String) -> DrawingObject {
        DrawingObject(id: id, toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .daily, candleIndex: 0, price: 1.0)],
                      isExtended: false, panelPosition: 0)
    }

    @Test("canonical 磁盘 key = drawings/hiddenIds")
    func canonicalKeys() throws {
        let w = try ReviewArchiveWrapper(drawings: [d("a")], hiddenIds: ["orig-1"])
        let json = try w.encodedColumn()
        #expect(json.contains("\"drawings\""))
        #expect(json.contains("\"hiddenIds\""))
    }

    @Test("wrapper 字节保真：含未来画线条的 wrapper，load→autosave 后该条逐字节等于原始")
    func wrapperBytePerfectForUnknown() throws {
        // wrapper 里 drawings 数组含一条未来画线（敏感 key 顺序 + 1.0 + 转义），且 key 顺序 hiddenIds 在前。
        let unknown = #"{"toolType":"__future__","z":1.0,"a":"x, ]}\"esc"}"#
        let column = #"{"hiddenIds":["orig-2"],"drawings":[\#(unknown)]}"#
        let w = try ReviewArchiveWrapper.decodeColumn(column)
        #expect(w.drawings.isEmpty)                       // 未来条不解码
        #expect(w.hiddenIds == ["orig-2"])
        let out = try w.encodedColumn()
        #expect(out.contains(unknown))                    // 未来条原文逐字节保留在输出里（未被重序列化）
        // 幂等：再 decode→encode 仍含原文
        #expect(try ReviewArchiveWrapper.decodeColumn(out).encodedColumn().contains(unknown))
    }

    @Test("wrapper 保留未知顶层 key：decode→encode 后未来顶层 key（如 futureMeta）逐字节保留、不被抹掉（codex WB R7 finding 1）")
    func preservesUnknownTopLevelKey() throws {
        // 模拟未来版本客户端在 wrapper 顶层加的、本版本不认识的 key——只经过结构性解码/编码时不得丢失
        // （否则下次 saveWorking/commitSaved 会用「只认识 drawings+hiddenIds」的新对象覆盖，永久抹掉）。
        let column = #"{"drawings":[],"hiddenIds":["orig-3"],"futureMeta":{"x":1}}"#
        let w = try ReviewArchiveWrapper.decodeColumn(column)
        #expect(w.hiddenIds == ["orig-3"])
        let out = try w.encodedColumn()
        #expect(out.contains(#""futureMeta":{"x":1}"#))            // 未知顶层 key 逐字节保留
        // 幂等：再 decode→encode 仍保留（非一次性侥幸）
        #expect(try ReviewArchiveWrapper.decodeColumn(out).encodedColumn().contains(#""futureMeta":{"x":1}"#))
    }

    @Test("wrapper 保留多个未知顶层 key：按原出现顺序逐一保留")
    func preservesMultipleUnknownTopLevelKeysInOrder() throws {
        let column = #"{"drawings":[],"hiddenIds":[],"alpha":1,"beta":"two","gamma":[3,4]}"#
        let w = try ReviewArchiveWrapper.decodeColumn(column)
        let out = try w.encodedColumn()
        #expect(out.contains("\"alpha\":1"))
        #expect(out.contains("\"beta\":\"two\""))
        #expect(out.contains("\"gamma\":[3,4]"))
        let iAlpha = out.range(of: "\"alpha\"")!.lowerBound
        let iBeta = out.range(of: "\"beta\"")!.lowerBound
        let iGamma = out.range(of: "\"gamma\"")!.lowerBound
        #expect(iAlpha < iBeta && iBeta < iGamma)                   // 出现顺序保留
    }

    @Test("容错：裸数组解码 → hiddenIds 为空")
    func tolerantBareArray() throws {
        let bare = """
        [{"id":"x","toolType":"horizontal","anchors":[{"period":"daily","candleIndex":0,"price":1.0}],
          "isExtended":false,"panelPosition":0,"revealTick":0,"period":"daily","lineSubType":"straight",
          "lineStyle":"solid","thickness":1,"colorToken":"orange","labelMode":"hidden","locked":false,
          "text":"","fontSize":14,"textColorToken":"orange","textForm":"plain"}]
        """
        let w = try ReviewArchiveWrapper.decodeColumn(bare)
        #expect(w.drawings.count == 1)
        #expect(w.hiddenIds.isEmpty)
    }

    @Test("fail-closed：valid-prefix + 尾部垃圾 → .dbCorrupted（不洗白成干净 wrapper，codex R15-medium）")
    func rejectsTrailingGarbageWrapper() {
        let bad = #"{"drawings":[],"hiddenIds":[]}{junk}"#
        #expect(throws: AppError.self) { _ = try ReviewArchiveWrapper.decodeColumn(bad) }
    }

    @Test("fail-closed：顶层重复 key（两个 drawings）→ .dbCorrupted")
    func rejectsDuplicateTopLevelKey() {
        let bad = #"{"drawings":[],"drawings":[{"id":"z"}],"hiddenIds":[]}"#
        #expect(throws: AppError.self) { _ = try ReviewArchiveWrapper.decodeColumn(bad) }
    }

    @Test("四态往返：空/drawings-only/hidden-only/都有")
    func fourStateRoundTrip() throws {
        let states: [ReviewArchiveWrapper] = try [
            ReviewArchiveWrapper(drawings: [], hiddenIds: []),
            ReviewArchiveWrapper(drawings: [d("a")], hiddenIds: []),
            ReviewArchiveWrapper(drawings: [], hiddenIds: ["orig-9"]),
            ReviewArchiveWrapper(drawings: [d("a")], hiddenIds: ["orig-9"]),
        ]
        for s in states {
            let back = try ReviewArchiveWrapper.decodeColumn(s.encodedColumn())
            #expect(back.drawings.map(\.id) == s.drawings.map(\.id))
            #expect(back.hiddenIds == s.hiddenIds)
        }
    }
}

// 注：类型名故意不叫 `ReviewNetChangeTests`——ReviewPersistenceTests.swift 已有同名非-private
// @Suite struct（旧字段-key 语义），同模块内重名会撞编译期 redeclaration。
@Suite("Drawing P1a — ReviewNetChange 按 id + hiddenIds")
struct ReviewNetChangeIdTests {
    private func d(_ id: String, price: Double = 1.0, locked: Bool = false) -> DrawingObject {
        DrawingObject(id: id, toolType: .horizontal,
                      anchors: [DrawingAnchor(period: .daily, candleIndex: 0, price: price)],
                      isExtended: false, panelPosition: 0, locked: locked)
    }

    @Test("仅锁定变了（几何不变）→ 判净改动（脏）")
    func styleOnlyIsDirty() {
        let committed = [d("a")]
        let working = [d("a", locked: true)]
        #expect(ReviewNetChange.changed(working: working, committed: committed) == true)
    }

    @Test("重复几何按 id 保留重数、不折叠")
    func duplicatesNotFolded() {
        // 两条同价水平线，id 不同 → 删掉其一应判脏
        let committed = [d("a"), d("b")]
        let working = [d("a")]
        #expect(ReviewNetChange.changed(working: working, committed: committed) == true)
    }

    @Test("仅隐藏集变了 → 判净改动（脏）")
    func hiddenOnlyIsDirty() {
        let same = [d("a")]
        #expect(ReviewNetChange.changed(working: same, committed: same,
                                        workingHiddenIds: ["orig-1"], committedHiddenIds: []) == true)
    }

    @Test("画线+隐藏都相等 → 不脏")
    func equalIsClean() {
        let same = [d("a")]
        #expect(ReviewNetChange.changed(working: same, committed: same,
                                        workingHiddenIds: ["orig-1"], committedHiddenIds: ["orig-1"]) == false)
    }
}
