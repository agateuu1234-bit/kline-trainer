// Tests/KlineTrainerContractsTests/Render/DrawingStylePanelSourceGuardTests.swift
// Spec: 2026-07-18-...-panel-redesign-design.md §2/§3 + 母 spec §3/§3.1。
// 迁自 DrawingStyleCardSourceGuardTests（长按卡片 → 常驻面板，1a-iii 切片2 Task3）——
// 灰态矩阵与「无解释文案」这两条母 spec 逐字要求全程有守卫覆盖，不留空窗。
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("常驻样式面板结构守卫：5 组控件 / 灰态判据 / 图标化 / 无解释文案（1a-iii 切片2）")
struct DrawingStylePanelSourceGuardTests {
    private var srcDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }
    private func source(_ rel: String) throws -> String {
        let text = try String(contentsOf: srcDir.appendingPathComponent(rel), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            guard let r = s.range(of: "//") else { return s }
            return String(s[s.startIndex..<r.lowerBound])
        }.joined(separator: "\n")
    }
    private let params = "Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift"
    private let panel  = "Sources/KlineTrainerContracts/UI/DrawingStylePanel.swift"

    @Test("五组控件标签齐 + 消费灰态判据 + 写 setDefaultStyle（迁自卡片守卫）")
    func hasGroupsAndWiring() throws {
        let code = try source(params)
        for label in ["线型", "线样式", "粗细", "颜色", "标注"] { #expect(code.contains(label)) }
        #expect(code.contains("DrawingStyleAvailability"))         // 灰态真被消费
        #expect(code.contains("normalizedLabelMode"))              // 切线型真规整 labelMode
        #expect(code.contains("session.setDefaultStyle"))          // 选择真写单一真相
    }

    @Test("面板文案洁净：无「不适用」类解释字（母 spec §3 逐字，迁自卡片守卫）")
    func noNotApplicableCopy() throws {
        for file in [params, panel] {
            let code = try source(file)
            for banned in ["不适用", "不可用", "N/A", "暂不支持"] { #expect(!code.contains(banned)) }
        }
    }

    @Test("图标化（spec §3）：线型/线样式/粗细三组**可见处**无文字（但 accessibilityLabel 必须有语义）")
    func lineGroupsAreIconsNotText() throws {
        let code = try source(params)
        #expect(code.contains("LineSubTypeIcon(") && code.contains("LineStyleIcon(") && code.contains("ThicknessIcon("))
        // ⭐codex 计划-R14-F2：守卫的**意图**是「界面上不显示文字」，原稿却实现成「这些字串整个文件都不许有」，
        //   于是逼出 `线型一` / `线样式solid` 这种无意义 accessibilityLabel —— 图标-only 控件配无语义标签，
        //   VoiceOver 用户**无法分辨直线/射线、实线/虚线**，是真可访问性缺陷（本 App 可能公开上架）。
        //   正确判据：只禁**可见 `Text(...)`** 里出现这些词；`.accessibilityLabel(...)` 里**必须**出现。
        for banned in ["Text(\"直线\")", "Text(\"射线\")", "Text(\"线段\")",
                       "Text(\"实线\")", "Text(\"虚线1\")", "Text(\"虚线2\")",
                       "Text(\"虚线3\")", "Text(\"虚线4\")"] {
            #expect(!code.contains(banned), "线型/线样式在界面上写了文字：\(banned)")
        }
        // 旧卡片的文字标签函数仍须绝迹（它们是「把枚举渲染成可见文字」的实现手段）。
        for banned in ["func subLabel(", "func styleLabel("] {
            #expect(!code.contains(banned), "仍留着渲染可见文字的标签函数：\(banned)")
        }
        // 粗细不得再用数字文案渲染档位。
        #expect(!code.contains("Text(\"\\($0)\")") && !code.contains("title: { \"\\($0)\" }"))
    }

    @Test("可访问性（codex 计划-R14-F2）：图标-only 控件必须带**语义** accessibilityLabel，VoiceOver 可分辨")
    func iconOnlyControlsCarrySemanticAccessibilityLabels() throws {
        let code = try source(params)
        // 线型三档 + 线样式五档 + 粗细五档，每一档都要有人话标签（图标看不见时的唯一依据）。
        for label in ["\"直线\"", "\"射线\"", "\"线段\"",
                      "\"实线\"", "\"虚线1\"", "\"虚线2\"", "\"虚线3\"", "\"虚线4\""] {
            #expect(code.contains(label), "缺语义可访问性标签 \(label) —— VoiceOver 用户分辨不出这一档")
        }
        #expect(code.contains("accessibilityLabel"), "图标控件未挂 accessibilityLabel")
        // 粗细用「粗细N」（1…5），见实现里的 label 闭包。
        #expect(code.contains("粗细"), "粗细档位缺语义标签")
    }

    @Test("标注组维持文字 + 灰态（spec §3 表格：唯一保留文字的组）")
    func labelGroupStaysTextual() throws {
        let code = try source(params)
        for word in ["隐藏", "显示", "左", "右"] { #expect(code.contains(word)) }
        #expect(code.contains("horizontalLabelModeEnabled"))
    }

    @Test("常驻面板读 session.defaultStyle 单一真相（不留本地 @State 镜像，防常驻期漂移）")
    func readsSessionDirectlyWithoutLocalMirror() throws {
        let code = try source(params)
        #expect(code.contains("session.defaultStyle"))
        #expect(!code.contains("@State private var style"))
    }

    @Test("颜色语义本切片不动（切片3 才改）：仍全 9 色 + 仍消费 colorEnabled 昼夜禁色")
    func colorSemanticsUnchangedInThisSlice() throws {
        let code = try source(params)
        #expect(code.contains("DrawingColorToken.allCases"))
        #expect(code.contains("colorEnabled"))
    }

    // ⭐codex 计划-R3-F1：R2 里我声称「第一道盾由源码守卫覆盖」，却**没真去加这条断言**——
    //   等于拿一个不存在的守卫去 justify「不跑真 SwiftUI 命中测试」这个残留风险。现补齐。
    //   这是第一道盾**唯一**的自动化覆盖（第二道盾走 handleDrawingTap 输入层测试），必须精确到修饰符顺序。
    // 从 text 中切出 [startMarker, endMarker) 之间的片段；两个 marker 都必须**恰好出现一次**
    // （出现 0 次 = 接线没了；出现多次 = 切片有歧义、顺序判据不可信）→ 都 fail-closed。
    // codex 计划-R4-F1：不这么切就只能拿「全文首次匹配」比先后，而 TrainingView.swift 有几十处
    // `.padding(`，全文首个 padding 与全文首个 GeometryReader 根本不在同一条修饰符链上，比出来无意义。
    private func slice(_ text: String, from startMarker: String, to endMarker: String) throws -> String {
        #expect(text.components(separatedBy: startMarker).count == 2, "起始锚 \(startMarker) 非唯一出现，切片有歧义")
        #expect(text.components(separatedBy: endMarker).count == 2, "结束锚 \(endMarker) 非唯一出现，切片有歧义")
        let start = try #require(text.range(of: startMarker)).lowerBound
        let end = try #require(text.range(of: endMarker, range: start..<text.endIndex)).lowerBound
        return String(text[start..<end])
    }

    @Test("第一道盾（codex 计划-R3-F1 / R4-F1）：面板根修饰符链上有 contentShape+吞点手势，且面板本体**零 padding**")
    func firstShieldPresentAndPrecedesPadding() throws {
        let code = try source(panel)
        // ⭐R4-F1：不再全文搜。切出 body 的根修饰符链（从可见材质到 body 结束）再判顺序。
        // ⭐codex 计划-R5-F2：切到文件级 `#endif` **不是根链边界**——中间可以夹任意 helper / extension，
        //   一个「根链上没有 contentShape、但后面某个 helper 里有一处」的文件照样能过唯一性检查。
        //   改用**根链专属终止锚**：生产代码必须在根 `.onTapGesture {}` 之后紧跟
        //   `.accessibilityIdentifier("drawingStylePanel")`，切片切到它为止 → 切出来的必是根链本身。
        let rootChain = try slice(code, from: ".background(.regularMaterial",
                                  to: ".accessibilityIdentifier(\"drawingStylePanel\")")
        // 根链内不得出现任何声明边界——出现即说明锚之间夹了别的 helper/extension，切片不可信。
        for boundary in ["func ", "struct ", "extension ", "var body"] {
            #expect(!rootChain.contains(boundary),
                    "根链切片内出现声明边界 `\(boundary)` —— 切到的不是单一根修饰符链，顺序判据不可信")
        }
        let shapeIdx = try #require(rootChain.range(of: ".contentShape(Rectangle())"),
                                    "面板**根链**上缺第一道盾 contentShape —— 点面板会穿透到下层图表").lowerBound
        let tapIdx = try #require(rootChain.range(of: ".onTapGesture {}"),
                                  "根链缺吞点手势，contentShape 单独不吞 tap").lowerBound
        #expect(shapeIdx < tapIdx, "contentShape 必须在吞点手势之前（否则命中形状不作用于该手势）")
        // ⭐R4-F1：禁**任何写法**的 padding，不只 8pt 那两种拼法（`.padding(8)`/`.padding(.all, 8)` 同样致命）。
        // 面板本体一旦自带 padding，call-site 的 GeometryReader 量到的就是含透明边距的框 → 死条（R1-F2 回归）。
        #expect(!code.contains(".padding("),
                "DrawingStylePanel.swift 出现 .padding( —— 面板本体不得自带任何边距，离屏边距只能加在 call site 测量之后")
        // contentShape 必须唯一：文件里另有一个嵌套/闲置的 contentShape 会让上面的断言假绿。
        #expect(code.components(separatedBy: ".contentShape(Rectangle())").count == 2,
                "contentShape(Rectangle()) 非唯一出现 —— 无法确定护住的是面板根")
    }

    @Test("call-site 顺序（codex 计划-R3-F1 / R4-F1）：**同一条链上** GeometryReader 先量、两个方向的 8pt padding 后加")
    func callSiteMeasuresBeforePadding() throws {
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        // ⭐R4-F1：切出 overlay 里挂 DrawingStylePanel 的**那一条链**，只在链内比顺序。
        let chain = try slice(tv, from: "DrawingStylePanel(session:", to: ".accessibilityIdentifier(\"chartPanels\")")
        let geoIdx = try #require(chain.range(of: "DrawingShieldFrameKey.self"),
                                  "链上缺 shield frame 上报").lowerBound
        let hIdx = try #require(chain.range(of: ".padding(.horizontal, 8)"),
                                "链上缺水平 8pt 离屏边距").lowerBound
        let vIdx = try #require(chain.range(of: ".padding(.vertical, 8)"),
                                "链上缺垂直 8pt 离屏边距（上半区 minY==8 断言依赖它）").lowerBound
        // 两个方向都必须在测量**之后**——只查「存在」不够，垂直 padding 排在测量前同样会把边距量进盾。
        #expect(geoIdx < hIdx, "水平 padding 在测量之前 → 透明边距进盾，图表出现看不见的死条（R1-F2 回归）")
        #expect(geoIdx < vIdx, "垂直 padding 在测量之前 → 同上")
        // 链内不得有**任何**排在测量之前的 padding（含 `.padding(8)` 等其它拼法）。
        let beforeMeasure = String(chain[chain.startIndex..<geoIdx])
        #expect(!beforeMeasure.contains(".padding("),
                "测量之前就有 padding —— 量到的不是可见面板本体（R1-F2 回归）")
    }

    // ⚠️**与 task-3-brief 派发时的字面稿刻意分歧（上游派发前已明确指出、非实施者自决）**：
    //   brief/计划原稿这里写的是 `panelCarriesVisibilityHooks`，断言面板根挂
    //   `.onAppear { session.setStylePanelVisible(true) }` / `.onDisappear { session.setStylePanelVisible(false) }`。
    //   但 Task 2（commit a1e420c）已用 hosted 测试证实：`ImageRenderer` 离屏渲染拆除时会**多触发一次
    //   `.onDisappear`**（即便面板逻辑上从未消失），若面板自己用 onAppear/onDisappear 置位可见性信号，
    //   刚算好的盾会被这次假消失清空——四个屏蔽差分测试当场假红（见 TrainingView.swift:641-652 大注释）。
    //   Task 2 因此把 `stylePanelVisible` 改成**纯计算属性**（`showsTradeButtons && isDrawingActive &&
    //   typeRowExpanded`，与挂载条件同一表达式），交给 `ChartPanelsContainer.refreshShields()`
    //   （经三个 PreferenceKey 收敛）统一维护 fail-closed 窗口，不再依赖任何一次性生命周期事件。
    //   若本 task 给 `DrawingStylePanel` 加回这两个钩子，就是重新引入已被证伪的设计，且与 Task 2
    //   建立的单一真相冲突（两处都能写 shield，谁后写谁赢）。故本条守卫改为**锁定 Task 2 修正后的
    //   不变量**——面板自身不得再持有可见性钩子；可见性判据的唯一权威仍是
    //   `ChartPanelsContainer.stylePanelVisible`。
    @Test("fail-closed 接线（Task2 a1e420c 修正）：面板自身不持有可见性钩子——可见性由 ChartPanelsContainer 的计算属性 + refreshShields 统一维护，不靠 onAppear/onDisappear")
    func panelDoesNotOwnVisibilityHooks() throws {
        let code = try source(panel)
        #expect(!code.contains(".onAppear { session.setStylePanelVisible(true) }"),
                "面板根不得自带 onAppear 置位 —— ImageRenderer 离屏拆除的假 onDisappear 会清空刚算好的盾（Task2 实证）")
        #expect(!code.contains(".onDisappear { session.setStylePanelVisible(false) }"),
                "面板根不得自带 onDisappear 清位 —— 同上，可见性单一真相已挪到 ChartPanelsContainer.stylePanelVisible")
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains("private var stylePanelVisible: Bool"),
                "ChartPanelsContainer 必须仍持有 stylePanelVisible 计算属性（唯一权威可见性判据）")
    }

    @Test("单一真相（codex 计划-R10-F3）：DrawingStylePanel 无 expanded 参数/存储属性（展开态只由挂载条件决定）")
    func panelHasNoExpandedParameter() throws {
        let code = try source(panel)
        #expect(!code.contains("expanded"),
                "DrawingStylePanel 出现 expanded —— 与 ChartPanelsContainer 的挂载条件构成第二份真相")
        let overlay = try source("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(!overlay.contains("let expanded"), "DrawingTypeOverlay 的 expanded 参数应随 Step 5 删除")
    }

    @Test("镜像只翻两大块、参数内部 5 组顺序两态相同（user 确认）+ ⇅ 在类型行右端")
    func mirrorFlipsOnlyTwoBlocks() throws {
        let panel = try source(self.panel)
        #expect(panel.contains("position == .top"))                 // 两态分支存在
        // 参数区在两个分支里都是**同一个** DrawingStyleParams 调用 → 组内顺序结构上不可能被翻。
        #expect(panel.contains("DrawingStyleParams(session: session, scheme: scheme)"))
        let overlay = try source("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(overlay.contains("onTogglePosition"))
        #expect(overlay.contains("Spacer()"))                       // ⇅ 被 Spacer 推到右端
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains("stylePanelPosition == .top ? .top : .bottom"))   // alignment 随位置切
        #expect(tv.contains("onChange(of: stylePanelPosition)"))             // 位置变化清盾
    }

    // codex 计划-R16-F1：`settleWithNoShields(_:)` 是测试专用逃生舱，生产代码一律不得引用——切位置
    // 正是几何尚未重新收敛的时刻，若生产在此标记「已收敛」会在最需要保护的瞬间关掉 fail-closed。
    // ⚠️与 brief 字面稿的刻意分歧：brief 里 `slice(tv, from: ".onChange(of: stylePanelPosition)", to: "}")`
    //   的结束锚 `"}"` 在 700+ 行的 TrainingView.swift 里绝非唯一出现，会让 `slice()` 内部「结束锚必须
    //   唯一」的自检恒假、测试恒败。改用下一条 `.onChange` 的字面量（`.onChange(of: engine.tick.globalTickIndex)`，
    //   本 task 实现里把 stylePanelPosition 那条紧接着插在它前面）作结束锚——两个锚都唯一，且切出来的
    //   恰好就是 `.onChange(of: stylePanelPosition)` 那条闭包的完整正文。
    @Test("生产不得使用测试逃生舱（codex 计划-R16-F1）：TrainingView 不引用 settleWithNoShields")
    func productionNeverUsesTestOnlySettleHelper() throws {
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(!tv.contains("settleWithNoShields"),
                "生产代码引用了测试逃生舱 —— 会在几何未收敛时开闸，重开幽灵线窗口")
        let chain = try slice(tv, from: ".onChange(of: stylePanelPosition)",
                              to: ".onChange(of: engine.tick.globalTickIndex)")
        #expect(chain.contains("clearAllShields()"), "切位置未清盾 → 旧位置盾残留成死区")
    }

    @Test("旧长按卡片已删除、长按钩子已摘除（不留两套设置入口）")
    func longPressCardRetired() throws {
        let cardPath = srcDir.appendingPathComponent("Sources/KlineTrainerContracts/UI/DrawingStyleCard.swift")
        #expect(!FileManager.default.fileExists(atPath: cardPath.path))
        let tv = try source("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(!tv.contains("DrawingStyleCard("))
        #expect(!tv.contains("showingStyleCard"))
        let overlay = try source("Sources/KlineTrainerContracts/UI/DrawingTypeOverlay.swift")
        #expect(!overlay.contains("onLongPressType"))
        #expect(!overlay.contains("LongPressGesture"))
    }
}
