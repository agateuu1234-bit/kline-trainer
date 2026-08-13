import Testing
@testable import KlineTrainerContracts

/// G7（D100）：`drawing_default_style` 列的容错解码必须是**唯一边界**。
///
/// ⚠️ 光数「恰好 2 个调用点」挡不住 D100 真正怕的那件事 —— **两个 repo 各拷一份容错解码器**
/// 同样是「各调一次自己那份」，调用点计数与行为矩阵**双双通过**，而单边界不变量已经没了。
/// 故 G7 = 正向的「2 个调用点、落在指定的两个文件里」**加上**反向的「零处自行解码」。
@Test func g7_column_decoder_is_the_single_boundary() throws {
    let sites = try callSiteCount("DrawingDefaultStyleColumn.decode(")
    let total = sites.reduce(0) { $0 + $1.count }
    #expect(total == 2, "解码调用点应恰好 2 个，实测 \(total)：\(sites.map(\.file))")

    // 不只数总数，还要数**落点**：2 次都挤在同一个 repo 里同样是「另一条读路径没接上」
    for needle in ["PendingTrainingRepositoryImpl.swift", "PendingReplayRepositoryImpl.swift"] {
        #expect(sites.contains { $0.file.hasSuffix(needle) && $0.count == 1 },
                "\(needle) 里应恰好 1 个解码调用点，实测：\(sites.map { "\($0.file)×\($0.count)" })")
    }
}

/// G7 反向条：除该 enum 自身外，`Sources/` 里零处直接解码这个类型。
@Test func g7_no_direct_decode_path_exists() throws {
    let direct = try callSiteCount("JSONDecoder().decode(DrawingDefaultStyle")
        .filter { !$0.file.hasSuffix("DrawingDefaultStyleColumn.swift") }
    #expect(direct.isEmpty, "出现了绕过共享解码器的直接解码路径：\(direct.map(\.file))")
}

/// G7 的**双向自检**：证明上面两条不是恒真的 —— 一个真实存在的符号必须数得出来，
/// 一个不存在的符号必须数出 0（防「pattern 打错字 → 恒 0 → 恒绿」）。
@Test func g7_scanner_is_not_vacuous() throws {
    #expect(try callSiteCount("DrawingDefaultStyleColumn.encode(").reduce(0) { $0 + $1.count } == 2,
            "encode 同样是两处（两个 repo 的写路径）—— 数不出来说明 pattern 或扫描根坏了")
    #expect(try callSiteCount("DrawingDefaultStyleColumnZZZ.decode(").isEmpty)
}

/// G5c（codex P-R9 **high**）：**持久化解码器也是粗细值域的消费者**，而 Task 1 的 G5b
/// 只钉了三个 UI/渲染消费者、G5 的字面量计数又**看不见 `min(max(` 形态**
///（那正是 G5b 当初存在的理由）——于是「在解码器里自己写一个 clamp」
/// **能同时躲过 G5 和 G5b**，让**磁盘读回路径**与 UI/编辑/渲染路径的值域悄悄分叉。
/// D99 要防的正是这个：存档里一个越界粗细，读回来被夹成 A、界面按 B 渲染。
///
/// 判据 = 正向「必须委托给唯一的 sanitizer」+ 反向「自己不得有任何数值边界」。
/// ⚠️ 反向条**只能限定在这一个文件里**：`Sources/` 全域 `min(max(` **实测有 27 处正当用途**
///    （PanLinkage / PinchZoomModel / Theme / …），全域禁会把一大片无关代码打红。
@Test func g5c_persistence_decoder_has_no_thickness_bounds_of_its_own() throws {
    let path = contractsDirForGuards
        .appendingPathComponent("Sources/KlineTrainerPersistence/Internal/DrawingDefaultStyleColumn.swift").path
    let src = try squeezedSource(path)        // 已剥注释与字符串字面量

    // 防空转：先证明真读到了那个文件（否则下面的否定断言恒真）
    #expect(src.contains(squeeze("DrawingDefaultStyle")), "没读到解码器源文件？路径推导坏了")

    #expect(src.contains(squeeze("sanitized(")),
            "解码器必须把夹取**委托**给唯一的 sanitizer，而不是自己写边界")
    for shape in ["min(max(", "1...5"] {
        #expect(!src.contains(squeeze(shape)),
                "解码器里出现了自成一套的粗细边界写法 `\(shape)` —— 值域又分叉了（D99）")
    }
}
