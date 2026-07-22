# 划线 1a-iii · 切片 3「自适应线色」实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 逐 task 实施。步骤用 `- [ ]`。

**Goal:** 把颜色行从「9 色 + 昼夜禁色灰态」收成「**7 彩 + 1 个「线色」格**」；「线色」= 随手机昼夜自动反色的纯 ink（日纯黑、夜纯白），根治「日间画的黑线切夜间看不见」。

**Architecture:** 关键决策（spec §4.2，codex spec 评审 R4 拍板）——**不新增枚举值**。既有 `.black`/`.white` 的**渲染函数**改成自适应纯 ink，`.black` 天然就是「新端自适应 ink」，故 UI「线色」直接复用 `.black`。由此**不 bump 契约、不动 schema、无迁移、无跨版本数据风险**——只有一处**渲染语义**变化（纯 UI 侧、不进持久化 blob）。

**Tech Stack:** SwiftUI（`#if canImport(UIKit)`，host `swift test` 覆盖纯函数 resolver / availability，Catalyst 编译 View + 跑 UIKit-gated 测试）；swift-testing；源码结构守卫。

## Global Constraints

- **不新增任何枚举值**：`DrawingColorToken` 保持 `red…purple / black / white` 九个 case 不变（spec §4.2）。
- **不 bump 契约**：`CONTRACT_VERSION` 保持不动（主仓已 1.12；本分支合并后取 main 的 1.12——本切片一个字都不改它），无 DB 迁移，无新持久化值 / 键 / schema（spec §4.3）。
- **不改默认样式**：`DrawingDefaultStyle.colorToken` 仍 `.orange`，仍内存整局、不落盘（spec §4.2）。
- **不动**：`PanelShield` 状态机 / `refreshShields` / `syncPanelShields` / `.task(id:)` / 任何盾逻辑 / 命中屏蔽 / 底栏 / 图标 / 上下镜像（切片 1/2 已交付，本切片零触碰）。
- **交易边界不变**：D45、`tradeStrip` 清理等一律不碰。
- **legacy 兼容**：老端写的 `.white` 记录新 UI 不再产出，但**仍可解码、仍渲染**（自适应）。既有 `DrawingModelP1aTests` / finalize / 复盘 / lossy 字节保真测试**全绿、断言不改**（值域没变，不触 `knownFutureEnumPayloads` 未来枚举门）。
- 既有切片 1/2/device-fix 全部测试**必须全绿**（除本计划显式指明要改 / 删的那几条）。
- 新增 / 删除 UIKit-gated `@Test` 后须同步 `.github/scripts/catalyst-uikit-baseline.txt`（脚本 `python3 .github/scripts/uikit-expected-tests.py > ...` 生成、**不手写**）、`catalyst-total-baseline.txt`（按真实日志 `✔ Test run with N tests`）、`fixtures/pass-main-current.log`（从同一 fresh 日志重切）。当前基线 total 1528 / uikit 57 行。

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `Sources/.../Drawing/DrawingColorResolver.swift` | token → RGBA 纯解析 | **改** `.black`/`.white` 分支为纯 ink（删糊色 fallback） |
| `Sources/.../Drawing/DrawingStyleAvailability.swift` | 灰态判据 | **删** `colorEnabled(_:scheme:)` 函数 |
| `Sources/.../UI/DrawingStyleParams.swift` | 5 组参数控件 | **改** `colorRow`：删 `colorEnabled` 消费、颜色列表从 9 全渲染改为「7 彩 + 1 线色」 |
| `Tests/.../Drawing/DrawingColorResolverTests.swift` | resolver 测试 | **改/加** 纯 ink 断言 + fixture |
| `Tests/.../Drawing/DrawingStyleAvailabilityTests.swift` | availability 测试 | **删** 6 条 `colorEnabled` 断言 |
| `Tests/.../Render/DrawingStylePanelSourceGuardTests.swift` | 面板结构守卫 | **改** 那条「切片3 才改」的守卫（现要求 colorEnabled 存在，须反转） |

**两个 task**（codex 计划-R1-F3：原删 `colorEnabled`(Task2) 与删其 UI 引用(Task3) 分属两 commit → 中间 commit 生产 UI 引用不存在的函数、Catalyst 编译失败、对 bisect/回滚/逐 commit CI 有害。**合并**）：
- **Task 1**：渲染层 `DrawingColorResolver` 改自适应纯 ink（纯函数、host 可测、风险最低、独立可交付）。
- **Task 2**：颜色行 UI 收成「7 彩 + 线色」 **+ 同一 commit 内**删 `colorEnabled` 及其测试（删函数与删其唯一引用原子发生，每个 commit 都过 Catalyst 编译门）。

---

## Task 1: `DrawingColorResolver` 把 `.black`/`.white` 改成自适应纯 ink

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingColorResolver.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingColorResolverTests.swift`

**Interfaces:**
- Produces（Task 3 消费）：`DrawingColorResolver.resolve(.black, scheme:)` → `.light` 近黑 `(0,0,0)`、`.dark` 近白 `(1,1,1)`；`.white` 同（两者成同义自适应 ink）。7 彩 token 解析**不变**。

- [ ] **Step 1: 改测试断言（先写期望的新行为）**

先读现有 `DrawingColorResolverTests.swift` 全文，定位其中断言 `.black`/`.white` **糊色**的用例（当前期望：`.black` 夜间 = 0.85 浅灰、`.white` 白天 = 0.20 深灰）。把它们改成纯 ink 期望，并**新增**一条「昼夜反色」不变量：
```swift
@Test("线色自适应（切片3）：.black/.white 都解析成纯 ink——日近黑、夜近白，无糊色 fallback")
func adaptiveInkNoMuddyFallback() throws {
    // 日间：纯黑（0,0,0），不再是白天的 .white→0.20 深灰
    #expect(DrawingColorResolver.resolve(.black, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
    #expect(DrawingColorResolver.resolve(.white, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
    // 夜间：纯白（1,1,1），不再是夜间的 .black→0.85 浅灰
    #expect(DrawingColorResolver.resolve(.black, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
    #expect(DrawingColorResolver.resolve(.white, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
    // .black 与 .white 现在是同义自适应 ink
    #expect(DrawingColorResolver.resolve(.black, scheme: .light) == DrawingColorResolver.resolve(.white, scheme: .light))
    #expect(DrawingColorResolver.resolve(.black, scheme: .dark) == DrawingColorResolver.resolve(.white, scheme: .dark))
}

@Test("线色永远与背景反色、看得见（根治『黑线夜间消失』）：日夜两态的 ink 与各自背景对比度拉满")
func adaptiveInkAlwaysReadable() throws {
    // 纯黑 vs 白底、纯白 vs 黑底——各通道差 1.0（对比度最大），不会与背景同色
    let dayInk = DrawingColorResolver.resolve(.black, scheme: .light)
    let nightInk = DrawingColorResolver.resolve(.black, scheme: .dark)
    #expect(dayInk.red == 0 && dayInk.green == 0 && dayInk.blue == 0)      // 日：纯黑
    #expect(nightInk.red == 1 && nightInk.green == 1 && nightInk.blue == 1) // 夜：纯白
    #expect(dayInk != nightInk)   // 昼夜真的反了
}
```
> 7 彩色（red…purple）的既有断言**保留不动**（值域没变）。

- [ ] **Step 1b: 补 legacy 双 token × 双 scheme 渲染 fixture（codex 计划-R1-F1 采纳的部分）**

codex R1-F1 正确指出：把 `.black`/`.white` 都解析成同一自适应 ink，会让**已持久化**的老画线渲染语义漂移（老 `.white` 日间从「深灰」变「纯黑」、老 `.black` 夜间从「浅灰」变「纯白」，黑白历史区分在**渲染层**消失）。这是 spec §4.3 **已显式接受**的「渲染语义漂移」（数据零风险、字节不变、仅显示变，正是 user 要的「黑白合一自适应」）。但 spec §4.3 要求「**加渲染 fixture 显式钉住该漂移**」——本 step 落实：把四种 (token × scheme) 组合的**新语义**逐一钉死，任何回退到糊灰都会红。
```swift
@Test("legacy 渲染 fixture（codex 计划-R1-F1 / spec §4.3）：老 .black/.white 记录在新端的自适应渲染逐一钉死")
func legacyTokensRenderAdaptiveInkBothSchemes() throws {
    // 老记录里持久化的 raw 值仍是 .black / .white（字节不变）；变的只有 resolve 的输出。
    // 日间：两者都纯黑（老 .white 曾是 0.20 深灰 → 现 0）
    #expect(DrawingColorResolver.resolve(.black, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
    #expect(DrawingColorResolver.resolve(.white, scheme: .light) == AppColorRGBA(red: 0, green: 0, blue: 0))
    // 夜间：两者都纯白（老 .black 曾是 0.85 浅灰 → 现 1）
    #expect(DrawingColorResolver.resolve(.black, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
    #expect(DrawingColorResolver.resolve(.white, scheme: .dark) == AppColorRGBA(red: 1, green: 1, blue: 1))
    // 反向钉：绝不回退到糊灰（0.85 / 0.20 任一出现即漂移被破坏）
    for s in [AppColorScheme.light, .dark] {
        for t in [DrawingColorToken.black, .white] {
            let c = DrawingColorResolver.resolve(t, scheme: s)
            #expect(c.red == 0 || c.red == 1, "出现糊灰值 \(c.red) —— 自适应纯 ink 语义被破坏")
        }
    }
}
```
> 这条与 `adaptiveInkNoMuddyFallback` 有重叠，但**语义不同**：前者是「新画线的正确性」，本条是「**老持久化记录**的跨版本渲染漂移被显式钉住」——满足 spec §4.3「byte/finalize 测不到渲染层，须加渲染 fixture」的硬要求。两条都保留。
> `DrawingObject.textColorToken`（价格标签字色，与 `colorToken` 同 token 类型）走同一个 `DrawingColorResolver.resolve` → 本 fixture 同时覆盖它，无需单独测（Task 2 的 commit message 注明这层）。

- [ ] **Step 2: 运行 → 确认失败**

Run: `cd ios/Contracts && swift test --filter adaptiveInk`
Expected: FAIL（当前 resolver 仍返回糊灰 0.85/0.20）

- [ ] **Step 3: 改 resolver 的 `.black`/`.white` 分支**

`DrawingColorResolver.swift`：
```swift
        // 切片3：自适应「线色」——.black/.white 都解析成纯 ink（日纯黑、夜纯白），删糊色 fallback。
        // 复用既有值域（不新增枚举）；两者成同义自适应 ink。根治「日间黑线切夜间不可读」。
        case .black, .white:
            return scheme == .dark ? AppColorRGBA(red: 1, green: 1, blue: 1)   // 夜：纯白
                                   : AppColorRGBA(red: 0, green: 0, blue: 0)   // 日：纯黑
```
（把原来分开的 `.black:` 与 `.white:` 两个 case 合并成一个 `case .black, .white:`，删掉 0.85 / 0.20 糊灰返回。文件头注释「black/white 主题相关（避免与背景同色不可读）」更新为「自适应纯 ink」。）

- [ ] **Step 4: 运行 → 通过**

Run: `cd ios/Contracts && swift test --filter DrawingColorResolver`
Expected: PASS（新断言绿 + 7 彩既有断言仍绿）

- [ ] **Step 5: 全量 host 回归（确认 legacy/finalize 不受影响）**

Run: `cd ios/Contracts && swift test 2>&1 | tail -3`
Expected: 全绿。**特别确认** `DrawingModelP1aTests` / finalize / lossy 字节保真类测试**未红**——值域没变，它们测的是 codec/字节层，与 resolver 渲染无关。若有红，说明某测试意外把「糊灰」当成了断言值 → 那是它测错了层，报告出来由 whole-branch 裁决，不要就地放松。

- [ ] **Step 6: Commit**
```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingColorResolver.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingColorResolverTests.swift
git commit -m "划线1a-iii切片3 Task1：DrawingColorResolver 把 .black/.white 改自适应纯 ink（日黑夜白、删糊色）"
```

---

## Task 2: 颜色行收成「7 彩 + 1 线色」+ 原子删除 `colorEnabled` + 守卫反转

> **原子性（codex 计划-R1-F3）**：删 `colorEnabled` 函数、删其唯一 UI 引用、删其单元测试**必须在同一 commit**——否则任何中间 commit 的生产 UI 会引用不存在的函数，host `swift test` 因不编 `#if canImport(UIKit)` 体而假绿、但 Catalyst 编译失败，污染 bisect/回滚/逐 commit CI。本 task 一次做完、一次提交、提交前过 Catalyst 编译门。

> **F2 的处置——不留 deprecated shim（codex 计划-R1-F2 pushback，已实测核实）**：codex 担心删 `public static colorEnabled` 是「跨包源码兼容破坏」。**实测否证**：`grep -rn "colorEnabled" ios --include=*.swift`（含 App target、排除测试）→ **唯一非测试调用者是 `DrawingStyleParams.swift:100`，同包内**；`KlineTrainerContracts` 包的消费者 App 就在本仓/本 worktree、已一并 grep，**包外零调用者**。`public` 只是 `DrawingStyleAvailability` 全部 4 个函数的一致风格，不代表对外契约。删一个无任何包外调用者的 helper **不构成源码兼容破坏**；留「返回 true 的 deprecated shim」是给不存在的调用者留兼容 = YAGNI，且会留下一个恒真的死判据误导后人。**故直接删，不留 shim**。实施者若在别处（如另一 git worktree / 未 grep 到的 target）发现真实包外调用者，**停下报告**，届时再议 shim。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingStyleParams.swift`（`colorRow` + 头注释 + accessibilityLabel + 删 `colorEnabled` 引用）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingStyleAvailability.swift`（删 `colorEnabled` 函数）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingStyleAvailabilityTests.swift`（删 6 条 `colorEnabled` 断言）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingStylePanelSourceGuardTests.swift`（反转「切片3 才改」守卫）

**Interfaces:**
- Consumes: Task 1 的自适应 resolver（`swatchColor` 经它取色，「线色」格日间显纯黑圈、夜间显纯白圈）。
- Produces: 颜色行渲染 7 个彩色 token + 1 个「线色」格（`.black`）；无独立黑 / 白格；无禁色灰态；`DrawingStyleAvailability` 不再有 `colorEnabled`。

- [ ] **Step 1: 改结构守卫（先写新期望）**

`DrawingStylePanelSourceGuardTests.swift:88-97` 那条 `colorSemanticsUnchangedInThisSlice`（现断言 `DrawingColorToken.allCases` + `colorEnabled` 都在）**反转**为切片3 语义。
> ⭐**codex 计划-R2-F3**：原稿的守卫太松——只禁 `allCases`/`colorEnabled` + 查有 `.black`/`线色`，一个显式写 `[.red,…,.purple,.black,.white]` 或加 `colorSwatch(.white,…)` 的实现照样过，正是要消灭的「留着白格」回归漏网。改为**切出 colorRow 片段**、精确断言七彩清单 + **恰好一个** `.black` swatch + **零** `.white` swatch。
```swift
@Test("颜色行收成 7 彩 + 1 线色（切片3，codex 计划-R2-F3 精确判据）：无 allCases/colorEnabled、恰好 1 个 .black、0 个 .white")
func colorRowIsSevenChromaticPlusLineColor() throws {
    let code = try source(params)
    // ① 不再全量渲染 9 色、不再消费禁色判据
    #expect(!code.contains("DrawingColorToken.allCases"), "颜色行仍在全量渲染 9 色")
    #expect(!code.contains("colorEnabled"), "颜色行仍在消费已删的 colorEnabled")
    // ② 七彩清单逐字（顺序与 chromaticColors 定义一致，防漏色/加色）
    #expect(code.contains("[.red, .orange, .yellow, .green, .cyan, .blue, .purple]"),
            "chromaticColors 不是精确的 7 彩清单")
    // ③ 切出 colorRow 片段，在片段内计数 swatch（防把整文件其它地方的 .black/.white 算进来）
    let row = try slice(code, from: "private var colorRow: some View {", to: "private func colorSwatch")
    // 线色格恰好一个 .black；片段内不得出现任何独立 .white swatch/token
    #expect(row.components(separatedBy: "colorSwatch(.black").count == 2, "colorRow 里 .black 线色格不是恰好 1 个")
    #expect(!row.contains(".white"), "colorRow 仍出现 .white —— 独立白格未删除（正是本切片要消灭的回归）")
    #expect(row.contains("colorSwatch(.black, label: \"线色\")"), "缺「线色」格或 label 不对")
}
```
（`slice(_:from:to:)` = 本测试文件既有 helper，切片1/2 已用；两锚点须各恰好出现一次，fail-closed。）
> `noNotApplicableCopy` / 图标化 / accessibilityLabel 等其它守卫**保留不动**。

**并补一条 swatch 计数守卫**（codex 计划-R2-F3/R3-F2：源码守卫必须能数出「恰好 8 个 swatch、七彩各一、无白格」，光禁 `allCases` 不够）。
> ⭐**codex 计划-R3-F2**：原稿这里放了一个**只有注释、无可执行代码的空壳** `colorRowRendersExactlyEightSwatches`，还说它让 uikit 基线 +1——那等于用一个什么都不验的测试占一个「已覆盖」名额（正是本 session 反复批评的「声称了没写」，我自己犯了）。**改为真源码计数**（不渲染、无 harness 风险）：在 colorRow 片段内计 `colorSwatch(` 恰好 8 次、七彩 token 各恰好 1 次、`.white` 0 次。这是**可执行、真验证**的判据。「渲染出来真是 8 个」那层交 §4.4 真机验收（user 亲数），不引入本仓无先例的 hosted 可访问性计数 harness。
```swift
@Test("颜色行 swatch 计数（codex 计划-R3-F2 真判据）：colorRow 恰好 8 个 swatch = 七彩各1 + 线色1，无白格")
func colorRowHasExactlyEightSwatches() throws {
    let code = try source(params)
    let row = try slice(code, from: "private var colorRow: some View {", to: "private func colorSwatch")
    // 七彩各恰好出现一次（在 ForEach(Self.chromaticColors) 里，故 colorRow 片段内不逐色写——
    // 改为断言 chromaticColors 定义 + 计 colorSwatch( 调用点）：ForEach 1 处 + 线色 1 处 = 2 个 colorSwatch(
    #expect(row.components(separatedBy: "colorSwatch(").count - 1 == 2,
            "colorRow 的 colorSwatch( 调用点不是 2（ForEach 七彩 + 线色各一）")
    // 七彩清单逐字 7 个、无 black/white 混入
    #expect(code.contains("[.red, .orange, .yellow, .green, .cyan, .blue, .purple]"))
    #expect(!code.contains("[.red, .orange, .yellow, .green, .cyan, .blue, .purple, .black")
            && !code.contains(".white]"), "chromaticColors 混入了 black/white")
    // 线色格恰好 .black、零 .white
    #expect(row.components(separatedBy: "colorSwatch(.black").count == 2, "线色 .black 格不是恰好 1")
    #expect(!row.contains(".white"), "colorRow 出现 .white —— 独立白格未删（本切片要消灭的回归）")
}
```
> 这条是 **host-pure 源码守卫**（非 UIKit-gated、非渲染）→ **不动 uikit 基线**。原稿「uikit +1」作废,改回「uikit 基线**不变**、total 按真实日志净值」。与上面 `colorRowIsSevenChromaticPlusLineColor` 合并也可（判据重叠），实施者择一或合并，但**必须有可执行的精确计数**，不留空壳。

- [ ] **Step 2: 运行 → 确认失败**

Run: `cd ios/Contracts && swift test --filter colorRowIsSevenChromaticPlusLineColor`
Expected: FAIL（现 colorRow 仍是 `allCases` + `colorEnabled`）

- [ ] **Step 3: 改 `colorRow`**

`DrawingStyleParams.swift` 的 `colorRow`（`:97-114`）改成显式「7 彩 + 1 线色」。7 彩用固定列表（不含 black/white），「线色」格单独一个、落 `.black`：
```swift
    // 颜色行（切片3）：7 彩 + 1「线色」。「线色」= .black canonical，随昼夜自动反色（日纯黑/夜纯白，
    // 经 DrawingColorResolver 自适应渲染）。无独立黑/白格、无禁色灰态——.black/.white 现恒可读。
    private static let chromaticColors: [DrawingColorToken] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple]

    private var colorRow: some View {
        HStack(spacing: 6) {
            ForEach(Self.chromaticColors, id: \.self) { token in
                colorSwatch(token, label: colorAccessibilityLabel(token))
            }
            // 「线色」格：canonical .black，圈内颜色 = resolver 自适应结果（日黑夜白），
            // 即「选它画出来是什么色，格子就显什么色」，所见即所得。
            colorSwatch(.black, label: "线色")
        }
    }

    private func colorSwatch(_ token: DrawingColorToken, label: String) -> some View {
        Button { commit { $0.colorToken = token } } label: {
            Circle().fill(swatchColor(token))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(Color.accentColor,
                                         lineWidth: token == style.colorToken ? 2.5 : 0))
                .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
```
> 删掉原 colorRow 里的 `let on = colorEnabled(...)` / `.disabled(!on)` / `.opacity(on ? 1 : 0.3)`——不再有禁色。`swatchColor(.black)` 经 Task 1 的自适应 resolver：日间纯黑圈、夜间纯白圈。
> ⚠️**选中判据**：`token == style.colorToken`——`.black` 格在 `colorToken == .black` 时高亮。legacy `.white` 记录加载后 `colorToken == .white`，此时 `.black` 格不高亮（无格对应 `.white`）——**可接受**：新 UI 不产出 `.white`，老记录仅需可渲染（自适应），不需要在新面板里回显选中态。若 subagent 认为需要让 `.white` 也高亮「线色」格，**报告出来**由 whole-branch 裁决，别自行扩范围。
> 删掉原 colorRow 里对 `colorEnabled` 的引用后，`DrawingStyleParams` 已无任何 `colorEnabled` 调用——这是删函数的前提。头注释（`:5`「颜色组本切片原样保留 9 色 + colorEnabled」）与 `:96` 同步更新为切片3 语义。

- [ ] **Step 4: 同一 commit 内删 `colorEnabled` 函数 + 其单元测试（原子，codex 计划-R1-F3）**

先删测试再删函数（删完 UI 引用后此刻二者都无消费者）：
1. `DrawingStyleAvailabilityTests.swift:31-39` 那个测 `colorEnabled` 的 `@Test` **整体删除**（`.white`/`.black` 昼夜 4 条 + 7 彩恒可选 2 条）。`horizontalLineSubTypeEnabled` / `horizontalLabelModeEnabled` / `normalizedLabelMode` 测试**保留不动**。
2. `DrawingStyleAvailability.swift:23-29` 的 `colorEnabled(_:scheme:)` 函数 + 上方 doc 注释 **整体删除**。其余 3 个函数不动。

- [ ] **Step 5: 颜色行 accessibility 保持语义**

确认 7 彩仍走 `colorAccessibilityLabel`（赤/橙/黄/绿/青/蓝/紫），「线色」格 label = `"线色"`。`colorAccessibilityLabel` 里的 `"black":"黑"` / `"white":"白"` 映射**保留**（legacy 记录若以某种方式回显仍需可读），但新 UI 不再产出黑/白格、故实际不触发。

- [ ] **Step 6: Catalyst 编译门（原子性验证——每个 commit 都要过这关）+ 全量三绿等价**

Run（**关键**：这是删 `colorEnabled` 后第一次真编 View 体，验证「删函数 + 删引用」在同一工作树里自洽，无中间破损态）：
`cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -3`
Expected: `BUILD SUCCEEDED`（若报 `colorEnabled` 未定义 → UI 引用没删干净，回 Step 3 补——**绝不允许**在 Catalyst 编不过的状态下 commit）
然后全量 host + fresh Catalyst：
Run: `cd ios/Contracts && swift test 2>&1 | tail -3` → 全绿
Run: `cd ios/Contracts && xcodebuild clean test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst' -only-testing:KlineTrainerContractsTests 2>&1 | tee /tmp/cat-slice3.log | tail -3`

- [ ] **Step 7: 基线同步（本切片删了测试，计数会降）**

本切片测试全是 **host-pure**（resolver fixture / availability 删测试 / 颜色行源码守卫，均无 `#if canImport(UIKit)`）→ **uikit 基线不变**、只 total 变。按真实日志核（别纸上算）：
```bash
grep -o '✔ Test run with [0-9]* tests' /tmp/cat-slice3.log | tail -1   # 据此更新 catalyst-total-baseline.txt
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt   # 脚本生成
git diff --stat .github/scripts/catalyst-uikit-baseline.txt   # 期望 **空**（无 UIKit-gated 增删）
# fixture 从同一 fresh 日志重切
bash .github/scripts/catalyst-gate.test.sh                     # 38/0
bash .github/scripts/catalyst-gate.sh /tmp/cat-slice3.log      # GATE PASS
```
若 uikit 基线**有变**（本切片理论上不增删 UIKit-gated 测试 → 应无变），停下核对是哪条动了。

- [ ] **Step 8: Commit（一次原子提交，含 UI + 删函数 + 删测试 + 守卫 + 基线）**
```bash
git add ios/Contracts/Sources ios/Contracts/Tests .github/scripts
git commit -m "划线1a-iii切片3 Task2：颜色行收成 7 彩+1 线色（线色落 .black 自适应）+ 原子删 colorEnabled 禁色判据 + 守卫反转"
```

---

## 三绿门（切片 3 收尾，作者亲跑，每条打印 branch/HEAD）

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/drawing-p1b-1a-iii" && \
  pwd && git branch --show-current && git rev-parse --short HEAD && git status --porcelain
```
1. `cd ios/Contracts && swift test`（host 全绿）
2. `bash .github/scripts/catalyst-gate.test.sh`（38/0）
3. `xcodebuild clean test ... -only-testing:KlineTrainerContractsTests` + `catalyst-gate.sh <log>`（**fresh 非增量**，GATE PASS）
4. `xcodebuild build ... 'platform=iOS Simulator,name=iPhone 17'`（BUILD SUCCEEDED；**iPhone 16 本机不存在**）

## §4.4 人工验收（真机，本切片新增条目）
- 颜色行：**7 个彩色圈 + 1 个「线色」圈**；**无**独立黑格 / 白格；**无**灰掉点不动的格子。
- 选「线色」画一条线：**日间是黑的**；系统切**夜间自动变白、始终看得见**（原「黑线夜间消失」解决）。
- 「线色」圈本身：日间显**纯黑圈**、夜间显**纯白圈**（所见即所得）。
- 老局兼容（若有素材）：以前用「黑」画的线，这版加载后日间纯黑 / 夜间纯白（渲染语义漂移，非缺陷）。
> 真机须 seed fixture（NAS 未部署，见 [[project_device_testing_requires_seed_fixture]]）。

## Self-Review（写完自查）

**1. spec 覆盖**（§4）：
- §4.1 行为（7 彩 + 1 线色 / 删黑白格 / 删禁色 / 日黑夜白）→ Task 1（渲染）+ Task 3（UI）✓
- §4.2 实现（不新增枚举 / resolver 改纯 ink 删糊色 / UI 落 .black / 删 colorEnabled / 默认仍橙）→ Task 1+2+3 ✓；「默认仍橙不落盘」= Global Constraints 显式钉，本切片零触碰 ✓
- §4.3 兼容（不 bump / 无迁移 / legacy .white 可解码可渲染 / 已记录渲染语义漂移）→ Global Constraints + Task 1 Step 5 回归 + §4.4 老局验收 ✓
- §4.3 渲染 fixture（把渲染语义漂移显式钉住，byte/finalize 测不到渲染层）→ Task 1 的 `adaptiveInkNoMuddyFallback`/`adaptiveInkAlwaysReadable` 即 resolver 层 fixture；**这是纯函数层的钉子**（resolver 是 host 可测纯函数，无需 hosted 渲染即可锁死日夜纯 ink 值）✓

**2. 占位扫描**：无 TBD / 无「类似 Task N」/ 每步给完整可粘贴代码。两处显式标注的「报告出来由 whole-branch 裁决」（legacy `.white` 是否高亮线色格、finalize 测试若意外测糊灰值）是**边界升级点**，非占位。

**3. 类型一致**：`DrawingColorResolver.resolve(_:scheme:)`、`AppColorRGBA(red:green:blue:)`、`DrawingColorToken`(.black/.white/.red…)、`chromaticColors`、`colorSwatch(_:label:)`、`swatchColor(_:)`、`colorAccessibilityLabel(_:)`、`style.colorToken` — 跨 task 一致。**已删的名字**：`DrawingStyleAvailability.colorEnabled`——计划全文（含守卫）确认它在 Task 2 后不再被任何生产代码引用。

**4. 不做项**：不新增枚举 / 不 bump 契约 / 不动 schema / 不改默认橙 / 不碰盾 / 图标 / 底栏 / 镜像。

## codex 计划评审修正史

**R1（needs-attention，3 finding）**：
- **F3-medium 非原子提交**（真，已修）：原 Task2/Task3 分删函数与删引用 → 中间 commit Catalyst 编不过。**合并为单原子 Task 2**，提交前过 Catalyst 编译门。
- **F2-high 删 public API**（**pushback**，实测否证）：codex 称删 `public colorEnabled` 是跨包源码兼容破坏。`grep -rn colorEnabled ios`（含 App target）→ 唯一非测试调用者同包内、包外零消费者。`public` 是该 enum 4 函数一致风格、非对外契约。**直接删、不留 shim**（留恒真 shim = YAGNI + 死判据误导）；实施者若发现真实包外调用者则停下报告。
- **F1-high legacy `.black`/`.white` 渲染语义折叠**（**部分采纳 + 决策上交 user**）：codex 现象描述属实（老 `.white` 日间变纯黑、老 `.black` 夜间变纯白、黑白历史区分在渲染层消失）。**但这正是 spec §4.3 已显式记录并接受的「渲染语义漂移」**（codex spec 评审 R1→R5 反复推演后接受，数据零风险/字节不变/仅显示变）。codex 建议的「新增 `.adaptive` + bump 契约」= spec 评审 **R2/R3 试过并 R4 否决**的路——实测核实：新增枚举 raw 值会被老端 `LossyDrawingArray.knownFutureEnumPayloads`（`:230`）当「未来枚举值」进 fail-closed 机制（注释 `:1024` 例证 `colorToken:"futureNeon"`），正是要避免的 finalize 风险。**采纳其唯一合理部分**：补 legacy 双 token × 双 scheme 渲染 fixture（Step 1b）钉住漂移。**决策部分（是否接受这个语义漂移 vs 改方案）上交 user**——因其牵涉「App 可能公开上架 → 跨版本数据保真按公开标准」这条全局约束。

**R2（needs-attention，3 finding；F3 修，F1/F2 保持——见下）**：
- **F3-medium 守卫太松**（真，已修）：原守卫只禁 `allCases`/`colorEnabled`，一个显式列 `.white` 的实现照样过。已改为**切 colorRow 片段**精确断言七彩清单 + 恰好 1 个 `.black` + 0 个 `.white` + 补 Catalyst 8-按钮渲染计数测试（uikit 基线 +1）。
- **F1-high 持久化语义折叠**（**决策已由 user 拍板，保持**）：codex 重申「需要 explicit product sign-off + migration/rollback policy」。**该 sign-off 已经发生**——user 于本 plan 评审期间明确拍板「接受漂移、照 spec 方案做」（codex 看不到 CC↔user 对话，不知授权已给）。spec §4.3 的推演（新增 `.adaptive` 会撞老端 `knownFutureEnumPayloads` fail-closed）已实测核实、R4 否决在先。**保持 spec 方案 + Step 1b 渲染 fixture 钉住漂移**。这不是「未解决」，是「已由有权者裁决」。
- **F2-high 删 public API**（**pushback 保持**）：codex 重申「grep 只证明当前 checkout、不能证明无未来下游」。**技术上它对一半**：grep 确实不能证伪未来。但（a）本仓是**唯一** `KlineTrainerContracts` 消费者、无独立发布/无 SemVer 承诺（非公开 SDK）；（b）留一个恒返回 `true` 的 deprecated shim 会引入一条**永远为真的死判据**，未来读者无法从代码判断「禁色逻辑还在不在」——这本身是坏信号；（c）真有下游时编译期立刻报错、一行加回即可，成本极低。**权衡后仍直接删**；实施者若发现真实包外调用者则停下报告。这是**成本权衡下的 pushback**，非疏漏。

> **本轮定性（防无限轮）**：R2 三条里只有 F3 是新的真缺陷（已修）。F1 是 codex 在要求一个**已经给过**的授权；F2 是 codex 重申一个我已用证据+成本权衡回应过的点。二者均非「计划有 bug」，而是 codex 完美主义 tail + 看不到 user 授权。按项目守则（reviewer verdict ≠ user 授权；codex 6+轮完美主义 tail 可 override），F3 修完后若 R3 仍只在 F1/F2 打转，**由 user override 进实施**，不无限改。

**R3（needs-attention，3 finding；1 新真缺陷已修，2 条 = 重申已裁决建议 → user override 收口）**：
- **F2-medium 我加的 swatch 计数测试是空壳**（真，我犯了本 session 反复批评的「声称了没写」，已修）：原稿 `colorRowRendersExactlyEightSwatches` 只有注释、无可执行代码，还挂 uikit 基线 +1 = 空壳占「已覆盖」名额。**已改**为 host-pure 真源码计数 `colorRowHasExactlyEightSwatches`（切 colorRow 片段计 `colorSwatch(` 恰好 2 处 + 七彩清单逐字 + `.black` 恰好 1 + `.white` 零）；不引入本仓无先例的 hosted 可访问性计数 harness；「渲染真是 8 个」交 §4.4 真机验收；uikit 基线**不变**。
- **F1-high 持久化语义**（= R1-F1 = R2-F1 **第三次重申**）：**user 已拍板接受漂移、照 spec 做**（本 plan 评审期间明确授权）。codex 看不到该授权。已裁决。
- **F3-medium 删 public API**（= R2-F2 **第二次重申**）：**user 已拍板直接删、不留 shim**（本 plan 评审期间明确授权）。已裁决。

> **收口决定（user override）**：R3 里唯一的新真缺陷 F2 已修。F1/F3 是 codex 第 3/2 次重申**两个 user 已明确否决的建议**（新增 `.adaptive`+bump 契约 / 留 deprecated shim）——codex 因看不到 CC↔user 对话而不知授权已给，故持续标 needs-attention。按项目守则「reviewer verdict ≠ user 授权，user 授权高于 reviewer verdict」+「codex 完美主义 tail 可 override」：**本计划 accept 残留、override 进实施**。残留（跨版本渲染漂移 / 删 colorEnabled）均由 user 显式授权、并有 Step 1b 渲染 fixture + Step 1 计数守卫钉住。这不是「没收敛」，是「有权者已裁决、reviewer 在坚持被否的方案」。

## 实施后 codex whole-branch（branch-diff base `1e50b57`，HEAD `55069f6`）
**needs-attention，1 finding（medium）= F2 第 4 次重申，user override 收口**：
- codex 重申「删 `public colorEnabled` 破坏 exported library 的 public API」。**技术论点无变、已连降为 medium**（自己承认非硬阻断）。事实：`KlineTrainerContracts` 唯一消费者是同仓 App、包外零调用者、非发布 SDK、无 SemVer、无「下游分支偏斜」（本仓不存在别的引用分支）；真有下游编译期立刻报错、加回一行即可；恒真 shim = 死判据。**user 已于计划评审拍板「直接删、不留 shim」，本轮再次确认 override。**
- **账本状态（如实）**：whole-branch 非 approve → **切片3 增量无独立 attest 记录**；账本最新 attest 仍是切片1+2 到 `1e50b57`。切片3 的质量保证 = 三绿全亲验（host1633/Catalyst1531 exact/GATE PASS/iOS SUCCEEDED）+ 逐 task 双 verdict 全清 + reviewer mutation-verify 守卫（插 `.white` 真红）+ legacy 渲染 fixture 真 pin。这不是「蒙混」，是「有权者裁决 + 内部证据链完整，reviewer 在坚持被否方案」。

## Execution Handoff

计划存 `docs/superpowers/plans/2026-07-21-drawing-P1b-1a-iii-slice3-adaptive-line-color.md`。
下一步：**codex 对抗性评审本计划到收敛** → `superpowers:subagent-driven-development` 逐 task 实施（subagent Sonnet high）。
