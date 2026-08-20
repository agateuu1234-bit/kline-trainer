# 划线 P1b「画完自动选中 + 改样式两套语义」实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用户在画线态画完一条线，那条线立刻处于选中态（🔒 / 🗑 / 样式面板立刻作用于它）；同时把「改样式」分成两套语义 —— 画线态改 = 改本局默认 + 顺带套到刚画那条，选择态改旧线 = 只改那一条。

**Architecture:** 把 `ChartContainerView.handleDrawingTap` 的 `.draw` 分支里**整段「尝试提交」**搬进无 UIKit 的 `DrawingEditRouter`（拆内外两层：外层管「造对象」的两道门，内层管「落库 + 定选中」的四步），使「提交被拒 → 清空选中」的六条出口收进同一个函数体、且 16 条变异里 15 条能在 host `swift test` 上拿到证据。选中的建立走一个与 `setSelection` **守卫互斥**的新入口 `setCommittedSelection`（只认画线态），让「画线态靠命中判定挂上选中」这条路结构上不存在。面板的显示 / 置灰 / 写入三件事统一改按 `session.mode` 分流，UI 层的 if 分流整个删掉。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`）· swift-testing（`@Test`/`@Suite`）+ XCTest（源码守卫那一族）· `@Observable` + `@MainActor` · Catalyst 闸门（UIKit-gated 测试）

**Spec:** `docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md`
（12 轮 codex 评审后**用户 override 收口，未取得 approve**。override 边界见 spec §12，本计划逐条遵守。）

**分支：** `feat/drawing-p1b-autoselect`，起点 = `feat/drawing-session-default-persistence` @ `3a0c88d`（已 merge 进来，merge commit `67ce940`）。
**评审 / PR 的 base = `feat/drawing-session-default-persistence`**，不是 `origin/main`（那会把已 approve 的 #166 那 52 个提交重审一遍）。

---

## Global Constraints

以下每一条对**每个 task** 都成立，task 正文不再重复。

### G-0　override 边界（spec §12，**不得扩张**）

override **只赦免「文档写法」，不赦免「行为正确性」**。以下**一条都不打折**，实施中若发现难以落地，**必须回来改 spec 并重跑评审**，不得以「spec 已 override」为由跳过：

- **§6.3 #0 的两个 base**（画线态必须把字段级改动**分别**套到「默认」与「线自己」上）—— 它防的是**静默改掉用户锁定过的线并落盘**；
- **D89 的次序强制**（自动选中 PR 不得先于持久化 PR 合入）；
- **§10.1 的撤销成对回滚**（交接给 1b-ii 撤销 PR，本片只写交接，不实现）；
- **D82 / D83 / D84 的全部门与判据**，以及 **spec §7 里任何一条**变异 / 不变量锁 / 正向档。

PR 描述里**必须复述本节**。进度 memory 记为「**spec override 收口，未 approve**」，**不得记 ✅**。

### G-1　零契约影响

**不新增 / 不修改任何持久化字段、不改 `CONTRACT_VERSION`、不加迁移、不改 settings 表**（spec §11）。
`DrawingSession` 的选中态是瞬时 UI 状态，**绝不落盘**（D55 原样成立）。
若任何一个 task 让你想去动 `KlineTrainerPersistence/` 或 `AppDBMigrations.swift`，**停下来报回**——那是走错了。

### G-2　不放宽任何既有门

本片**不新增门、不放宽门、不重排门**（spec §1「D63/D64/D65/D66/D34/D40/D55 一字不动」）。特别是：

- `deletableIgnoringGeometry` 末行 `return !d.locked`（`DrawingEditRouter.swift:97`）**一字不改** —— 锁定的线在画线态**同样删不掉**，🗑 照样灰。自动选中**不得**成为放宽这道不可逆销毁门的理由（spec §6.5 #1）。
- `lockableIgnoringGeometry` 刻意**没有** `!d.locked` 分量（锁定线必须仍能被解锁），这个不对称是 D71 的原样保留，**不碰**。
- `lockButtonEnabled` / `deleteButtonEnabled` / `canToggleLock` / `canDelete` **不含 mode 分量，一律不改**。

### G-3　判绿纪律（每个 task 收尾都要做，缺一视为证据不全）

**PREAMBLE —— 任何带管道的验证命令都必须贴在这一段后面：**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
```

- ⭐⭐ **每条闸门命令必须同时打印 branch / HEAD**（[[feedback_subagent_git_checkout_branch_drift]]）。分支不是 `feat/drawing-p1b-autoselect` 一律**拒绝判绿**。
- ⭐⭐ **判绿不能只读 `swift test | tail -3`**：那行 `Test run with N tests in M suites passed` **只统计 swift-testing**（`@Test`/`@Suite`），本仓另有 **273 条 XCTest**（`func test…`）完全不在这行里 —— 而本计划的**全部源码守卫都是 XCTest**。只看这行，「守卫根本没跑」与「守卫跑了且通过」长得一模一样。**收尾判绿一律加这三条**：

```bash
swift test 2>&1 | tee /tmp/gate.log | tail -3                                # swift-testing 汇总
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate.log | tail -2      # XCTest 执行量
grep -E "Test Case .*<本 task 新增的 XCTest 名>.* passed" /tmp/gate.log       # 点名确认它真跑了
```

报告里**必须同时记录两个数字**（swift-testing 条数 / XCTest 条数）。
**闸门基线（本支起点实测值，收尾时对照）**：host `swift test` = **1875 tests / 220 suites**，XCTest = **273**。

- ⭐ **多门连跑的块，每门单独 `|| exit 1`**，不许一门红了继续跑下一门然后报绿（[[feedback_gate_pipe_swallows_exit_code]]）。
- ⭐ **每个 task 收尾必须 `git status --short` 确认工作区干净**（输出为空）。非空 = 有改动没提交（脏树假绿）或变异没复原干净，**两者都必须当场查清再继续**。
- ⭐ **改了 `Sources/` 就要重跑门，哪怕「只改注释」**（[[feedback_controller_must_run_gates_himself]]）。

### G-4　变异纪律（spec §7.2，本片最重的一条）

- **spec §7.2 表格里的每一条 M（含 M5a / M5b / M5c 等所有带字母后缀的分条）全部逐条关门看红**。清单**以 spec 的表格为准**，本计划不重新枚举成「M1–M15」（spec §7.2 明写：枚举会脱节）。
- 每条必须回答「**红的是哪一条测试**」，不是「有测试变红」。PR 描述里逐条记录**测试名** + **复原后重新变绿**的证据。**实施者自报「验过了」不算数**（[[feedback_mutation_testing_beats_reading]]）。
- **变异复原一律 `cp` 到 `/tmp` 再 `cp` 回，禁止 `git checkout <file>`**（会静默抹掉未提交改动，[[feedback_git_checkout_destroys_uncommitted_work]]）。
- 变异**必须对准**你要证明的那条判据；若某判据在被测路径上根本不求值，正解是写成**不变量锁测试**而不是假装它有行为覆盖（[[feedback_mutation_must_target_the_exact_predicate]]）。

### G-5　守卫纪律（spec §8）

- **不得写成「禁词黑名单」**，一律用**结构计数**（[[feedback_source_guard_text_source_discipline]]）。
- 否定 / 结构断言必须**剥注释、剥字符串字面量**再匹配（用 `SourceGuardScanner.swift` 的 `squeezedSource` / `callCount` / `callSiteCount` / `filesMentioning`），否则本计划要求写的那些**承重注释**会把守卫自己打红，而「删掉那句注释」就成了合法绕过路径。
- **每个守卫必须配双向自检**：喂一段「本该命中」的合成样本必须命中、喂一段「本该不命中」的必须不命中。锚点失效必须**报错**，不得静默返回 0（[[feedback_mechanical_checker_parser_disabled]]）。
- ⭐⭐ **守卫必须在它自己那个 task 结束时是绿的**（[[feedback_source_guard_must_be_green_on_current_tree]]）—— 一条开局就红的守卫等于给实施者发放宽许可证。本计划的 task 边界**就是按这条排的**，不得擅自把守卫挪到别的 task。

### G-6　Catalyst 四处基线同步（**只有 Task 4 触发**）

本片**只新增 1 条 UIKit-gated 测试**。新增 UIKit-gated 测试必须同步**四处**，少一处 CI 必红（[[feedback_catalyst_uikit_baseline_four_sync]]）：

1. `.github/scripts/catalyst-uikit-baseline.txt`（由 `uikit-expected-tests.py` **重生成**，77 → 78）
2. `.github/scripts/catalyst-total-baseline.txt`（1778 → 实测新值）
3. `.github/scripts/fixtures/pass-main-current.log`（用**本轮真冷构建**日志逐行重裁）
4. `.github/scripts/catalyst-gate.test.sh`（「活基线覆盖」用例写死的 `1778`，共 3 处 + 追加维护记录条目）

⭐⭐ **喂闸门的日志必须冷构建**（先 `rm -rf` DerivedData），否则 G6 会假红报「scheme 用错了？」。
⭐⭐ Catalyst 双坑：必须 `-scheme KlineTrainerContracts-Package`（library scheme **不编译 testTarget**）+ `set -o pipefail`（tee 吞退出码）。**判绿读执行量，不读 `TEST SUCCEEDED` 字样**（[[feedback_catalyst_scheme_and_pipefail_double_trap]] / [[feedback_uikit_gated_evidence_traps]]）。
⭐ 取数用 CI 同款 `-only-testing:KlineTrainerContractsTests`。

### G-7　名词与命名（spec §0.4，**禁用相对编号**）

跨切片文档里**禁用「PR-1 / PR-2」这类相对编号**（spec R11/R12 因此各挖出一条 high）。一律用内容命名：

| 名字 | 含义 |
|---|---|
| **持久化 PR** | 本局默认随存档续训继承（PR #166，已 R3 真 approve、CI 九道全绿，**故意挂着不合**） |
| **自动选中 PR** | **本计划实施的就是它** |
| **1b-ii 锁定 PR** | 底栏 🔒（已 MERGED #163，是本片的基线） |
| **1b-ii 撤销 PR** | 底栏 ↩ ↪，本片只交接不实现 |

**全局次序三段全部强制**：`持久化 PR → 自动选中 PR → 1b-ii 撤销 PR`。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift` | 画线会话共享状态容器（选中二元组、mode、pending 锚、本局默认样式） | **加** `setCommittedSelection`；`setSelection` 的**三行赋值体**抽成 private helper（守卫各自保留，spec §2.3 明令） |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift` | 选中对象的唯一写入路由 + 可用性谓词（**无 UIKit → host 可测**） | **加** `commitPendingAndSelect`（外层）/ `routeAndSelect`（内层）/ `selectedLineStyle` / `styleFields(of:)` / `applyPanelStyleMutation`；**改** `panelStyle` / `styleControlsEnabled` 的分流判据；**删** `applyStyleMutation` / `applyDefaultStyleMutation` |
| `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift` | UIKit 桥接 + tap 路由（**UIKit-gated，host 不编译**） | `.draw` 分支的四道 guard → 一次路由调用 + 补一次 `rebuildRenderState` |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | 训练页装配 | `onStyleChange` 里的 if 分流**整个删掉**，改为无条件调 `applyPanelStyleMutation` |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift` | 会话容器行为测试 | 追加 D82 两入口互斥（N-lock-1 / N-lock-2）与正/负向档 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift` | **新建**：提交路由（D83/D84/D85）的全部 host 测试 | Task 2 / 3 各写自己那半 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift` | **新建**：D86 三张表 + 两个 base 的 host 测试 | Task 5 / 6 各写自己那半 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift` | **新建**：G1 / G1b / G2 / G3 / G4 / G4b / G5 / G6 八条源码守卫（**XCTest**）+ 双向自检 | 每条守卫在**它自己那个 task** 里落地并转绿 |
| `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewAutoSelectTests.swift` | **新建**：M12 的守门测试（**唯一**一条 UIKit-gated 新增） | Task 4 |
| `.github/scripts/catalyst-*.txt` · `catalyst-gate.test.sh` · `fixtures/pass-main-current.log` | Catalyst 闸门四处基线 | Task 4 一并同步 |

---

## 依赖关系（**不得擅自重排**）

```
Task 1 ──▶ Task 2 ──▶ Task 3 ──▶ Task 4
   │                                 
   └──────▶ Task 5 ──▶ Task 6        ──▶ Task 7（收尾）
```

三条捆绑是**结构逼出来的**，不是偏好：

1. **Task 3 → Task 4 不可跨 PR**：G1 / G1b 要求 `commitPending` / `routeDrawingCommit` 在整个 `Sources/` 里**各恰好 1 个调用点**。Task 2/3 建好新路由那一刻，`ChartContainerView` 还在调 → 各 2 个。所以 Task 4 必须在**同一个 PR** 里把老路收掉。（Task 2/3 结束时 G1/G1b 是红的，这没关系 —— 它们**不属于**那两个 task，见 G-5。）
2. **Task 6 必须同时改 `TrainingView`**：删掉那两个旧 mutation 会让 `TrainingView.swift:543/545` 直接编译不过。这是编译器逼的。
3. **Task 5/6 依赖 Task 1**：P3 / P6 / P7 / M15 都需要「画线态里有一个选中」这个状态，而在**改动前的代码里这个状态根本造不出来**（`setSelection` 被 `mode == .select` 守卫挡死）。

---

### Task 1: D82 —— 画线态选中的唯一入口 `setCommittedSelection`（两入口守卫互斥）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift:97-102`（`setSelection` 的函数体）
- Test: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`（追加）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift`（G5）

**Interfaces:**
- Consumes: `DrawingSession.mode: DrawingSessionMode`（`.draw` / `.select`）、`drawingModeActive: Bool`、`selectedDrawingID: DrawingID?`、`selectedPanel: PanelId?`、`selectionGeometryVisible: Bool`（均已存在）
- Produces: `func setCommittedSelection(id: DrawingID, panel: PanelId)` —— **internal**（不加 `public`），返回 `Void`。Task 2 的 `routeAndSelect` 是它在 `Sources/` 里的**唯一**调用点。

- [ ] **Step 1: 写失败的测试**

追加到 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift`（放在文件内既有 `struct` 的末尾；若该文件是多个 `@Suite`，新起一个 suite）：

```swift
@Suite("D82：画线态选中的唯一入口 —— 两个入口守卫互斥")
@MainActor
struct DrawingCommittedSelectionEntryTests {

    /// 造「会话已开、处于画线态（默认就是 .draw）」的引擎。
    private func drawingSessionEngine() -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()                       // beginDrawingSession(tool: .horizontal)
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.mode == .draw)
        return e
    }

    // ── 正向档（防「全是拒了的套件掩盖恒抛守卫」，spec §7.1 的同一条纪律）──

    @Test("画线态 + 非空 id → setCommittedSelection **建立**选中，并置 selectionGeometryVisible")
    func committedEntryGrantsInDrawMode() {
        let e = drawingSessionEngine()
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == "A")      // 断言等于哪个 id，不是「非 nil」
        #expect(e.drawingSession.selectedPanel == .upper)
        #expect(e.drawingSession.selectionGeometryVisible == true)   // spec §2.4
    }

    @Test("选择态 + 非空 id → setSelection **建立**选中（既有入口未被本片削弱）")
    func selectEntryStillGrantsInSelectMode() {
        let e = drawingSessionEngine()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "B", panel: .lower)
        #expect(e.drawingSession.selectedDrawingID == "B")
        #expect(e.drawingSession.selectedPanel == .lower)
        #expect(e.drawingSession.selectionGeometryVisible == true)
    }

    // ── N-lock-1 / N-lock-2：两个入口互斥（spec §7.3）──

    @Test("N-lock-1：mode == .draw 时调 setSelection → 选中保持 nil（画线态恒不做命中判定）")
    func setSelectionRejectedInDrawMode() {
        let e = drawingSessionEngine()
        e.drawingSession.setSelection(id: "A", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == nil)
        #expect(e.drawingSession.selectedPanel == nil)
        #expect(e.drawingSession.selectionGeometryVisible == false)
    }

    @Test("N-lock-2：mode == .select 时调 setCommittedSelection → 选中保持 nil（提交路径专用）")
    func committedEntryRejectedInSelectMode() {
        let e = drawingSessionEngine()
        e.drawingSession.setMode(.select)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == nil)
        #expect(e.drawingSession.selectedPanel == nil)
        #expect(e.drawingSession.selectionGeometryVisible == false)
    }

    // ── 另两个分量各自单独被守（防「三条合取里只有一条在工作」）──

    @Test("空 id 两个入口都拒（resume 路径可解码出空 id 的线，放行会让所有空 id 的线一起高亮）")
    func emptyIdRejectedByBothEntries() {
        let e = drawingSessionEngine()
        e.drawingSession.setCommittedSelection(id: "", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == nil, "画线态入口漏了 !id.isEmpty")
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == nil, "选择态入口漏了 !id.isEmpty")
    }

    @Test("没有画线会话时 setCommittedSelection 恒拒（fail-closed）")
    func committedEntryRejectedWithoutSession() {
        let e = TrainingEngine.preview()             // 没调 toggleDrawingMode
        #expect(e.drawingSession.drawingModeActive == false)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == nil)
    }
}
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingCommittedSelectionEntryTests 2>&1 | tail -20
```

预期：**编译失败**，报 `value of type 'DrawingSession' has no member 'setCommittedSelection'`。

- [ ] **Step 3: 最小实现**

编辑 `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift`，把现有 `setSelection`（`:97-102`）的**函数体**替换，并在其后新增两个函数。改动后这三个函数长这样（守卫行**一字不改**）：

```swift
    func setSelection(id: DrawingID, panel: PanelId) {
        guard drawingModeActive, mode == .select, !id.isEmpty else { return }
        assignSelection(id: id, panel: panel)
    }

    /// D82（自动选中 spec §2.3）：**提交路径专用**。画线态下能产生选中的**唯一**入口。
    /// 守卫与 `setSelection` **互斥**：那边只认 `.select`，这边只认 `.draw`；两者的并集
    /// 恰好等于允许的全集。于是「画线态靠 hitTest 挂上一个选中」这条路**结构上不存在**，
    /// `ChartContainerView` 的 `.draw` 分支里不需要写任何防御性代码。
    /// ⚠️ **不得**把两个入口合并成一个带 mode 参数的函数（spec §2.3 明令）—— 那会让
    ///    「哪个 mode 允许」重新变成调用点的责任，也就是这条 D82 要消灭的东西。
    /// `!id.isEmpty` 与 `setSelection` 同理由（见其头注：resume 路径不经 `appendDrawing` 的门）。
    /// `selectionGeometryVisible = true` 与 `setSelection` 同理由（spec §2.4）：能走到这一步，
    /// **同一次调用**里已经对这条线跑过 `HorizontalLineTool.visibleGeometry != nil`
    /// （`DrawingEditRouter.commitPendingAndSelect` 的第 ② 步）——过了那道门即证明此刻几何可见。
    /// internal（同容器 mutator 纪律，见文件顶部大注释：mutator 一旦 public，包外就能绕过
    /// `beginDrawingSession` / `endDrawingSessionIfActive` 这两个唯一收口点）。
    func setCommittedSelection(id: DrawingID, panel: PanelId) {
        guard drawingModeActive, mode == .draw, !id.isEmpty else { return }
        assignSelection(id: id, panel: panel)
    }

    /// 两个入口**共用的赋值体**（spec §2.3：若要消重，只允许抽一个 `private` 的赋值 helper，
    /// **两个入口各自保留自己的守卫**）。抽出来让「两个入口的函数体一致」由**构造**保证，
    /// 而不是靠两份三行代码日后不漂移这个承诺。
    private func assignSelection(id: DrawingID, panel: PanelId) {
        selectedDrawingID = id
        selectedPanel = panel
        selectionGeometryVisible = true
    }
```

- [ ] **Step 4: 跑测试，确认它通过**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingCommittedSelectionEntryTests 2>&1 | tail -10
```

预期：`Test run with 6 tests in 1 suites passed`。

- [ ] **Step 5: 写守卫 G5（回归守卫，今天已绿）**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §8
//
// 本文件是 XCTest（不是 swift-testing）：与 SourceGuardScanner.swift 的既有守卫同族，
// 且 `swift test | tail -3` 那行汇总**不包含** XCTest —— 判绿必须另读
// `Executed N tests, with 0 failures`（计划 Global Constraints G-3）。
//
// 纪律（spec §8，缺一即失效）：
//   · 一律**结构计数**，不写禁词黑名单；
//   · 匹配前必须**剥注释、剥字符串字面量**（用 squeezedSource / callCount）——否则本片要求写的
//     那些承重注释会把守卫自己打红，而「删掉那句注释」就成了合法绕过路径；
//   · 每条守卫配**双向自检**：本该命中的合成样本必须命中、本该不命中的必须不命中。
import XCTest
@testable import KlineTrainerContracts

final class DrawingAutoSelectSourceGuardTests: XCTestCase {

    private let routerPath  = "Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift"
    private let containerPath = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"
    private let trainingViewPath = "Sources/KlineTrainerContracts/UI/TrainingView.swift"

    /// `Sources/` 里某调用 pattern 的调用点（file, count）。零调用的文件不出现。
    private func sites(_ pattern: String) throws -> [(file: String, count: Int)] {
        try callSiteCount(pattern)
    }

    /// 断言：`Sources/` 里 pattern 恰好 `n` 个调用点，且**全部**落在后缀为 `suffix` 的那个文件里。
    private func assertExactlyOneSite(_ pattern: String, inFileSuffixed suffix: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let s = try sites(pattern)
        let total = s.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 1, "『\(pattern)』在 Sources/ 里有 \(total) 个调用点（期望 1）：\(s)",
                       file: file, line: line)
        XCTAssertEqual(s.count, 1, "『\(pattern)』散在多个文件里：\(s.map(\.file))", file: file, line: line)
        XCTAssertTrue(s.first?.file.hasSuffix(suffix) == true,
                      "『\(pattern)』的唯一调用点应在 \(suffix)，实际在 \(s.first?.file ?? "<无>")",
                      file: file, line: line)
    }

    // MARK: G5（回归守卫 —— 改动前就已经是绿的，故与生产改动分开落库是合法的）

    func testG5_setSelectionHasExactlyOneCallSiteInChartContainerView() throws {
        // ⚠️ pattern 用**完整调用语法锚** `setSelection(id:`：裸写 `setSelection(` 在字面上不会被
        //    `setCommittedSelection(` 命中（那里 `setS` 不成串），但完整锚同时挡住未来任何改名带来的
        //    子串误命中，是更强也更便宜的写法（spec §8 G5 点名要求边界锚）。
        try assertExactlyOneSite("setSelection(id:", inFileSuffixed: "Render/ChartContainerView.swift")
    }

    func testG5SelfCheck_bothDirections() {
        // ① 本该命中：一次真实调用（换行 / 块注释排版都逃不掉，squeeze 后一样）
        let positive = """
        func caller() {
            session.setSelection(
                id: hit.id, panel: panel
            )
        }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive), pattern: "setSelection(id:"), 1,
                       "自检①失败：真实调用没被数到 —— 守卫已失效")

        // ② 本该**不**命中：定义行 / 注释里的字样 / 互斥入口 setCommittedSelection
        let negative = """
        func setSelection(id: DrawingID, panel: PanelId) { }
        // session.setSelection(id: 注释里的不算)
        func caller() {
            session.setCommittedSelection(id: committed.id, panel: panel)
        }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(negative), pattern: "setSelection(id:"), 0,
                       "自检②失败：定义/注释/互斥入口被误计 —— 守卫会假红")
    }
}
```

- [ ] **Step 6: 跑守卫 + host 全量**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts"
swift test --filter DrawingAutoSelectSourceGuardTests 2>&1 | tail -10 || exit 1
swift test 2>&1 | tee /tmp/gate-t1.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-t1.log | tail -2
grep -E "Test Case .*testG5_setSelectionHasExactlyOneCallSiteInChartContainerView.* passed" /tmp/gate-t1.log
```

预期：三条都有输出；swift-testing 条数 ≈ 1881（1875 + 6）、XCTest 条数 ≈ 275（273 + 2）。**把两个真实数字记进报告**。

- [ ] **Step 7: 变异 M3 / M4**

先备份（**禁止 `git checkout` 复原**）：

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift /tmp/DrawingSession.swift.bak
```

逐条：改 → 跑 → **记录红的是哪个测试名** → `cp /tmp/DrawingSession.swift.bak <原路径>` 复原 → `git status --short` 确认干净 → 下一条。

| 变异 | 改法 | 必须且只应变红 |
|---|---|---|
| **M3** | `setCommittedSelection` 的守卫 `mode == .draw` 改成 `mode == .select` | `committedEntryGrantsInDrawMode`（正向档失效）**和** `committedEntryRejectedInSelectMode`（N-lock-2）。⚠️ **spec §7.2 只写了 P1**（P1 在 Task 3 才有）；N-lock-2 同时变红是**预期内的额外红**，不是偏离 —— 它测的就是这条守卫。**必须在报告里写明这一点**，不要为了「只红一条」去弱化 N-lock-2 |
| **M4** | `setSelection` 的守卫放宽成 `guard drawingModeActive, !id.isEmpty else { return }`（删掉 mode 分量） | **只有** `setSelectionRejectedInDrawMode`（N-lock-1）红；`selectEntryStillGrantsInSelectMode` **不得**红 |

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingSession.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingSessionTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift
git commit -m "feat(drawing): D82 画线态选中的唯一入口 setCommittedSelection（两入口守卫互斥）+ G5

两个入口的守卫互斥、并集恰好等于允许的全集：setSelection 只认 .select，
setCommittedSelection 只认 .draw。于是「画线态靠 hitTest 挂上一个选中」结构上不存在——
不是靠放宽 setSelection 的守卫，也不是靠 .draw 分支自觉不调 hitTest（spec §2.2 明令禁止）。
三行赋值体抽成 private assignSelection，让「两个入口函数体一致」由构造保证。

测试：正向 2 档（断言取到的是哪个 id）+ N-lock-1 / N-lock-2 + 空 id / 无会话各一档。
守卫 G5（setSelection 恰好 1 个调用点在 ChartContainerView）+ 双向自检。
变异 M3 / M4 逐条关门看红（详见 PR 描述）。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: D83 / D84 / D85 内层 —— `routeAndSelect`（落库与选中处置，第③④⑤⑥步）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`（在 `deleteSelected` 之前新增；`import CoreGraphics` 已在文件顶部）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift`（追加 G2）

**Interfaces:**
- Consumes: `DrawingSession.setCommittedSelection(id:panel:)`（Task 1）、`DrawingSession.clearSelection()`、`TrainingEngine.drawings: [DrawingObject]`、`TrainingEngine.routeDrawingCommit(_:)`、`TrainingEngine.flow.mode`、`RenderStateBuilder.visibleDrawings(engine:panel:tick:) -> [DrawingObject]`
- Produces: `static func routeAndSelect(_ committed: DrawingObject, panel: PanelId, engine: TrainingEngine)` —— **internal**，返回 `Void`。Task 3 的 `commitPendingAndSelect` 是它在 `Sources/` 里的**唯一**调用点（G6）。

- [ ] **Step 1: 写失败的测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §3 / §4 / §5
// ⚠️ 本文件**刻意不是** UIKit-gated：D85 把整段「尝试提交」从 ChartContainerView 搬进
//    DrawingEditRouter 的全部收益就在这里 —— 16 条变异里 15 条能在 host 上拿到真证据。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("D83/D84/D85：提交路由 —— 落库与选中处置")
@MainActor
struct DrawingCommitRouteTests {

    /// 主图 x ∈ [0,100]、价格区间 [0,100]、candleStep 10 → index 0..<10 在图内，index ≥ 10 越右缘。
    static func mapper(priceMin: Double = 0, priceMax: Double = 100) -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: priceMin, max: priceMax),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「训练态 + 会话已开 + 画线态」的引擎。
    static func drawingEngine(mode: TrainingMode = .normal) -> TrainingEngine {
        let e = TrainingEngine.preview(mode: mode)
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.mode == .draw)
        return e
    }

    /// 造一条**属于上面板**的候选线（period 取上面板当前周期；revealTick 由 routeDrawingCommit 盖）。
    static func upperCandidate(_ e: TrainingEngine, id: String, price: Double = 50,
                               candleIndex: Int = 0) -> DrawingObject {
        makeStyledHLine(id: id, revealTick: 0, period: e.upperPanel.period,
                        candleIndex: candleIndex, price: price)
    }

    // ── P1 的内层版（正向档：健康输入必须被放行，spec §7.1）──

    @Test("内层正向：健康候选线 → 落库 + 选中**就是它**（断言等于新那条的 id）")
    func innerGrantsSelectionOnHealthyCommit() {
        let e = Self.drawingEngine()
        let before = e.drawings.count
        let d = Self.upperCandidate(e, id: "N1")
        DrawingEditRouter.routeAndSelect(d, panel: .upper, engine: e)
        #expect(e.drawings.count == before + 1)
        #expect(e.drawingSession.selectedDrawingID == "N1")
        #expect(e.drawingSession.selectedPanel == .upper)
    }

    @Test("内层正向：连落两条 → 选中**转移**到第二条（== id2 且 != id1）")
    func innerTransfersSelectionToSecond() {
        let e = Self.drawingEngine()
        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "N1"), panel: .upper, engine: e)
        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "N2", price: 60),
                                         panel: .upper, engine: e)
        #expect(e.drawings.count == 2)
        #expect(e.drawingSession.selectedDrawingID == "N2")
        #expect(e.drawingSession.selectedDrawingID != "N1")
    }

    // ── D84 复盘门：**两个断言缺一不可**（spec §4.2）──

    @Test("D84：复盘下走一次提交 → reviewDrawings **递增**（落线不回归）且选中 **nil**（不越界）")
    func reviewLandsLineButNeverSelects() {
        let e = Self.drawingEngine(mode: .review)
        #expect(e.flow.mode == .review)
        let before = e.reviewDrawings.count
        let d = Self.upperCandidate(e, id: "R1")
        DrawingEditRouter.routeAndSelect(d, panel: .upper, engine: e)
        // 断言 ①：落线能力**没有**被门回归掉（浮动铅笔钮，1a-iii 起的既有功能，D26）
        #expect(e.reviewDrawings.count == before + 1, "复盘落线功能被回归了 —— 门放到 routeDrawingCommit 之前了？")
        // 断言 ②：复盘**不得**获得选中能力（D34 trust boundary，P5 才做带层权限的选中）
        #expect(e.drawingSession.selectedDrawingID == nil, "复盘越界拿到了选中")
    }

    // ── D83 合取项 ①：id 碰撞（出口 e）。**只能经内层构造**（外层的 commitPending 生成全新 UUID）──

    @Test("M5a 的档 / 出口 e：提交前已存在同 id 的老线 → 落库被拒，选中**保持 nil**（绝不选中那条老线）")
    func idCollisionNeverSelectsStaleLine() {
        let e = Self.drawingEngine()
        // 先塞一条同 id 的**老线**，它本来就在可见集合里
        #expect(e.appendDrawing(Self.upperCandidate(e, id: "DUP", price: 40)) == true)
        #expect(e.drawingSession.selectedDrawingID == nil)
        let before = e.drawings.count

        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "DUP", price: 70),
                                         panel: .upper, engine: e)

        #expect(e.drawings.count == before, "appendDrawing 的 !contains(id) 门应当拒收本次新线")
        #expect(e.drawingSession.selectedDrawingID == nil,
                "只判『提交后在可见集合里』会选中那条陈旧的老线 —— D37 的陷阱原样复现")
    }

    // ── D83 合取项 ②：出口 f（落库成功但不属于本面板）。合取项 ② 唯一的判别力来源 ──

    @Test("N-lock-5 / 出口 f：落库**成功**但该线不属于被点面板 → **不授予选中**")
    func landsButDoesNotBelongToPanelSoNoSelection() {
        let e = Self.drawingEngine()
        #expect(e.upperPanel.period != e.lowerPanel.period, "preview 上下面板周期必须不同，本档才成立")
        let before = e.drawings.count
        // period 取**下**面板的，却当作在**上**面板落的锚：
        //   · appendDrawing 放行（isPeriodConsistent 只比对象自身的锚与 period）
        //   · belongsToPanel(_, panel: .upper, …) 判 false → 不在 .upper 的可见集合里
        let d = makeStyledHLine(id: "F1", revealTick: 0, period: e.lowerPanel.period,
                                candleIndex: 0, price: 50)
        DrawingEditRouter.routeAndSelect(d, panel: .upper, engine: e)

        #expect(e.drawings.count == before + 1, "落库应当成功 —— 少了这条断言，删掉被测那句照样绿")
        #expect(e.drawingSession.selectedDrawingID == nil, "合取项 ② 失守：选中了一条不属于本面板的线")
    }

    // ── M6 的档：分支 2 必须**清空**既有选中（不是「不动」）──

    @Test("M6 的档：先有一个选中 → 下一次提交被拒（id 碰撞）→ 选中被**清空**")
    func rejectedCommitClearsExistingSelection() {
        let e = Self.drawingEngine()
        #expect(e.appendDrawing(Self.upperCandidate(e, id: "DUP", price: 40)) == true)
        e.drawingSession.setCommittedSelection(id: "DUP", panel: .upper)   // 先建立一个选中
        #expect(e.drawingSession.selectedDrawingID == "DUP")

        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "DUP", price: 70),
                                         panel: .upper, engine: e)

        #expect(e.drawingSession.selectedDrawingID == nil, "被拒的提交留下了陈旧选中 —— D37 的陷阱")
        #expect(e.drawingSession.selectedPanel == nil, "二元组必须整体清（只清 id 会留下半个）")
    }

    // ── M5c 的档：第 ③ 步快照的顺序不是纸面约定 ──

    @Test("M5c 的档：wasPresent 必须是**提交前**的快照 —— 健康提交下它必为 false，选中才建立得起来")
    func snapshotTakenBeforeCommit() {
        let e = Self.drawingEngine()
        DrawingEditRouter.routeAndSelect(Self.upperCandidate(e, id: "S1"), panel: .upper, engine: e)
        #expect(e.drawingSession.selectedDrawingID == "S1",
                "把 wasPresent 挪到 routeDrawingCommit 之后 → 恒 true → 自动选中整体失效")
    }
}
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingCommitRouteTests 2>&1 | tail -20
```

预期：**编译失败**，报 `type 'DrawingEditRouter' has no member 'routeAndSelect'`。

- [ ] **Step 3: 最小实现**

在 `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift` 里，紧接在 `applyDefaultStyleMutation` 之后、`deleteSelected` 之前插入：

```swift
    // MARK: D83 / D84 / D85 提交路由（自动选中 spec §3 / §4 / §5）

    /// **内层**：落库与选中处置（六步流程的 ③④⑤⑥）。**接收一个已经造好的 `DrawingObject`**。
    ///
    /// 这个缝不是为测试硬开的口子，它就是「造对象」与「落库 + 定选中」两件事的自然分界；
    /// 但它顺带让四条变异**可构造**（spec §5.1）—— 外层的 `commitPending` 内部经
    /// `DrawingObject.init` 生成**全新 UUID**，测试无从预知 id，经外层根本写不出 id 碰撞档。
    ///
    /// ⚠️ **六步顺序是 load-bearing 的，一步都不许换位**（每一步的换位后果见各自行内注）。
    /// ⚠️ 生产路径上**只有外层 `commitPendingAndSelect` 一个调用点**（源码守卫 G6）——
    ///    拆内外两层**不得**变成两个生产入口。
    static func routeAndSelect(_ committed: DrawingObject, panel: PanelId, engine: TrainingEngine) {
        // ③ 提交**前**的存在性快照。**必须在 ④ 之前求值**：挪到 ④ 之后恒为 true
        //    → 第 ⑥ 步的合取项 ① 恒假 → 自动选中整体失效（变异 M5c）。
        let wasPresent = engine.drawings.contains { $0.id == committed.id }

        // ④ **无条件**落库：复盘照常落线（浮动铅笔钮，1a-iii 起的既有功能，D26 明写复盘继续用它）。
        engine.routeDrawingCommit(committed)

        // ⑤ D84 复盘门。**只包住「授予选中」这一步**（spec §4.2）：
        //    挪到 ④ 之前 = 复盘的**落线**功能整个回归掉（变异 M2），与 1b-ii 那道 `.segment` 门
        //    误管所有工具是同一类错误 —— fail-closed 的门必须限定到它真适用的那一类。
        //    删掉它 = 复盘获得选中能力，于是能对**已归档 record 里的原训练线**做 🗑 / 🔒 / 改样式
        //    （D34 trust boundary，带 (层, id) 权限门控的复盘选中是 P5，变异 M1）。
        guard engine.flow.mode != .review else { return }

        // ⑥ D83 的判据 = **提交前后两次状态快照的合取**，**绝不读任何返回值**（D64：
        //    `routeDrawingCommit` 返回 `Void`、吞掉 `appendDrawing` 的返回值；而失败原因有五类，
        //    一个 Bool 表达不了）。
        //    合取项 ①（提交前不存在）单独挡 id 碰撞——少了它会选中那条**陈旧的老线**（D37 的陷阱）；
        //    合取项 ②（提交后在**本面板**的可见集合里）单独挡周期不一致 / 几何 nil / revealTick 未到 /
        //    归属判到了另一个面板。
        //    ⚠️ ② 用 **membership**，不用 `count == 1`：与 `syncSelectionByState` 的判据纪律逐字一致
        //    （见其头注「不复用 uniqueSelected」），有了 ① 之后「同 id 出现两条」在本路径上不可达。
        let visible = RenderStateBuilder.visibleDrawings(
            engine: engine, panel: panel, tick: engine.tick.globalTickIndex)
        if !wasPresent && visible.contains(where: { $0.id == committed.id }) {
            engine.drawingSession.setCommittedSelection(id: committed.id, panel: panel)
        } else {
            engine.drawingSession.clearSelection()          // 出口 d / e / f
        }
    }
```

- [ ] **Step 4: 跑测试，确认它通过**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingCommitRouteTests 2>&1 | tail -10
```

预期：`Test run with 7 tests in 1 suites passed`。

- [ ] **Step 5: 写守卫 G2**

**先做一件清理**（控制者裁决，Task 1 评审的 Minor）：`DrawingAutoSelectSourceGuardTests.swift` 顶部有三个 `private let` 路径常量，实测 **0 个被引用**。其中 `routerPath` 在 **Task 3 的 G4b** 会真的用到（保留），而 `containerPath` / `trainingViewPath` **任何 task 都不会用到**（G1/G1b/G3/G4/G5 全部经 `assertExactlyOneSite` 传硬编码后缀字符串）。

**删掉这两行**（CLAUDE.md §2：不写超出当前需求的代码；这是本计划自己造成的孤儿，属 §3 允许的清理）：

```swift
    private let containerPath = "Sources/KlineTrainerContracts/Render/ChartContainerView.swift"
    private let trainingViewPath = "Sources/KlineTrainerContracts/UI/TrainingView.swift"
```

⚠️ **`routerPath` 那一行留着**，Task 3 的 `testG4b_…` 要用。删完跑一次 `swift test --filter DrawingAutoSelectSourceGuardTests` 确认仍全绿。

然后追加到 `DrawingAutoSelectSourceGuardTests.swift` 的 `// MARK: G5` 段之前（保持 MARK 分段顺序 G1/G1b/G2/G3/G4/G4b/G5/G6 与 spec §8 表一致；本 task 只填 G2）：

```swift
    // MARK: G2（本 task 落地：setCommittedSelection 的唯一调用点必须在路由里）

    func testG2_setCommittedSelectionHasExactlyOneCallSiteInRouter() throws {
        try assertExactlyOneSite("setCommittedSelection(id:",
                                 inFileSuffixed: "Drawing/DrawingEditRouter.swift")
    }

    func testG2SelfCheck_bothDirections() {
        let positive = """
        func caller() {
            engine.drawingSession.setCommittedSelection(id: committed.id, panel: panel)
        }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive),
                                 pattern: "setCommittedSelection(id:"), 1,
                       "自检①失败：真实调用没被数到 —— 守卫已失效")

        let negative = """
        func setCommittedSelection(id: DrawingID, panel: PanelId) { }
        // engine.drawingSession.setCommittedSelection(id: 注释里的不算)
        func caller() { session.setSelection(id: hit.id, panel: panel) }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(negative),
                                 pattern: "setCommittedSelection(id:"), 0,
                       "自检②失败：定义/注释/另一个入口被误计 —— 守卫会假红")
    }
```

- [ ] **Step 6: 跑守卫 + host 全量**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts"
swift test --filter DrawingAutoSelectSourceGuardTests 2>&1 | tail -10 || exit 1
swift test 2>&1 | tee /tmp/gate-t2.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-t2.log | tail -2
grep -E "Test Case .*testG2_setCommittedSelectionHasExactlyOneCallSiteInRouter.* passed" /tmp/gate-t2.log
```

> ℹ️ 本 task 结束时 **G1 / G1b 仍是红的**（`commitPending` / `routeDrawingCommit` 此刻在 `ChartContainerView` 与 `DrawingEditRouter` 各有一个调用点），**这是预期的** —— 它们属于 Task 4，见 G-5 与「依赖关系」第 1 条。**本 task 不得**为了让它们变绿而提前动 `ChartContainerView`。

- [ ] **Step 7: 变异 M1 / M2 / M5a / M5b / M5c / M6**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift /tmp/DrawingEditRouter.swift.bak
```

逐条：改 → 跑 → **记录红的是哪个测试名** → `cp /tmp/DrawingEditRouter.swift.bak <原路径>` 复原 → `git status --short` 确认干净 → 下一条。

| 变异 | 改法 | 必须且只应变红 |
|---|---|---|
| **M1** | 删掉第 ⑤ 步整行 `guard engine.flow.mode != .review else { return }` | **只有** `reviewLandsLineButNeverSelects` 的**第二个**断言（选中越界）；`innerGrantsSelectionOnHealthyCommit` / `innerTransfersSelectionToSecond` **不得**红 |
| **M2** | 把第 ⑤ 步整行**挪到**第 ④ 步 `engine.routeDrawingCommit(committed)` **之前** | **只有** `reviewLandsLineButNeverSelects` 的**第一个**断言（`reviewDrawings.count` 不再递增）。这条证明 §4.2 的双断言不是空转 |
| **M5a** | 把第 ⑥ 步的合取项 **①** 删掉（`if visible.contains(...)`，去掉 `!wasPresent &&`） | **只有** `idCollisionNeverSelectsStaleLine`；其余全绿 |
| **M5b** | 把第 ⑥ 步的合取项 **②** 改成恒真（`if !wasPresent {`） | **只有** `landsButDoesNotBelongToPanelSoNoSelection`；其余全绿 |
| **M5c** | 把第 ③ 步 `let wasPresent = …` **挪到**第 ④ 步之后 | `snapshotTakenBeforeCommit` + `innerGrantsSelectionOnHealthyCommit` + `innerTransfersSelectionToSecond`（自动选中整体失效） |
| **M6** | 把第 ⑥ 步的 `else { engine.drawingSession.clearSelection() }` 整个删掉（改成只有 `if`） | **只有** `rejectedCommitClearsExistingSelection`；`idCollisionNeverSelectsStaleLine` **不得**红（它开局就没有选中，删掉 `clearSelection` 照样绿 —— 这正是「M6 的档必须先建立一个选中」的原因） |

⚠️ **每条变异跑完必须回答「红的是哪一条」**，只写「有测试红了」视为证据不全（G-4）。

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift
git commit -m "feat(drawing): D83/D84/D85 内层 routeAndSelect —— 落库与选中处置（③④⑤⑥）+ G2

判据是**提交前后两次状态快照的合取**，绝不读任何返回值（D64：routeDrawingCommit 返 Void、
吞掉 appendDrawing 的返回值；失败原因五类，一个 Bool 表达不了）。
合取项 ① 挡 id 碰撞（否则选中的是那条陈旧老线 = D37 的陷阱），
合取项 ② 挡周期不一致 / 几何 nil / revealTick 未到 / 归属判到另一个面板。
D84 复盘门钉在第 ⑤ 步、只包住「授予选中」——挪到 ④ 之前会把复盘落线功能整个回归掉。

内外分层不是为测试硬开的口子：外层 commitPending 内部生成全新 UUID，
id 碰撞档经外层根本写不出来（spec §5.1 / codex spec-R5 medium）。

测试 7 条（含复盘双断言、出口 e、出口 f 的不变量锁）；守卫 G2 + 双向自检。
变异 M1/M2/M5a/M5b/M5c/M6 逐条关门看红（详见 PR 描述）。
⚠️ 本提交后 G1/G1b 仍红（旧调用点还在 ChartContainerView），由 Task 4 收口。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: D85 外层 —— `commitPendingAndSelect`（造对象的两道门 + 出口 a/b/c 清空选中）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`（在 `routeAndSelect` **之前**插入外层）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift`（追加）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift`（追加 G6 / G4b）

**Interfaces:**
- Consumes: `DrawingSession.commitPending(panelPosition: Int) -> DrawingObject?`、`HorizontalLineTool.visibleGeometry(for:mapper:) -> (y: CGFloat, minX: CGFloat, maxX: CGFloat)?`、`DrawingEditRouter.routeAndSelect(_:panel:engine:)`（Task 2）
- Produces: `static func commitPendingAndSelect(panel: PanelId, mapper: CoordinateMapper, engine: TrainingEngine)` —— **internal**，返回 `Void`。Task 4 的 `ChartContainerView.handleDrawingTap` 是它在 `Sources/` 里的唯一调用点。

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingCommitRouteTests.swift` 的 `struct` 末尾（`Self.mapper` / `Self.drawingEngine` 已在 Task 2 定义）：

```swift
    // ── 外层：P1 / P2 正向档（走完整六步）──

    @Test("P1：训练态 + 画线态 + 健康锚点 → 提交后选中 == 新那条的 id，落锚面板 == selectedPanel，drawings +1")
    func outerCommitSelectsTheNewLine() throws {
        let e = Self.drawingEngine()
        let before = e.drawings.count
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 0, price: 50), panel: .upper)

        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)

        #expect(e.drawings.count == before + 1)
        let newId = try #require(e.drawings.last?.id)
        #expect(e.drawingSession.selectedDrawingID == newId, "选中的必须**就是**刚提交那条")
        #expect(e.drawingSession.selectedPanel == .upper)
    }

    @Test("P2：连画两条 → 选中**转移**到第二条（== id2 且 != id1），drawings == 2")
    func outerSecondCommitTransfersSelection() throws {
        let e = Self.drawingEngine()
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 0, price: 50), panel: .upper)
        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)
        let id1 = try #require(e.drawingSession.selectedDrawingID)

        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 1, price: 60), panel: .upper)
        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)

        #expect(e.drawings.count == 2)
        let id2 = try #require(e.drawingSession.selectedDrawingID)
        #expect(id2 != id1, "选中没有转移到第二条")
        #expect(e.drawings.last?.id == id2)
    }

    @Test("画线态**不退出**：连续画线（D38）—— 两次提交之后仍是 .draw 且工具没变")
    func outerKeepsDrawingSessionAlive() {
        let e = Self.drawingEngine()
        let tool = e.drawingSession.activeDrawingTool
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 0, price: 50), panel: .upper)
        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)
        #expect(e.drawingSession.mode == .draw)
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.drawingSession.activeDrawingTool == tool)
    }

    // ── N-lock-3（出口 a，对应 M13）：commitPending 返 nil ──

    @Test("N-lock-3 / 出口 a：先有选中 → 多锚 period 不一致致 commitPending 返 nil → 选中被清空、零落库")
    func exitAClearsSelectionAndLandsNothing() {
        let e = Self.drawingEngine()
        #expect(e.appendDrawing(Self.upperCandidate(e, id: "OLD", price: 40)) == true)
        e.drawingSession.setCommittedSelection(id: "OLD", panel: .upper)   // 先建立一个选中
        #expect(e.drawingSession.selectedDrawingID == "OLD")
        let before = e.drawings.count

        // 两个 period 互不相同的锚 → commitPending 的 allSatisfy 门拒 → 返 nil（出口 a）
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 0, price: 50), panel: .upper)
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.lowerPanel.period, candleIndex: 1, price: 60), panel: .upper)
        #expect(e.drawingSession.pendingAnchors.count == 2, "两个锚都要在 pending 里，本档才成立")

        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)

        #expect(e.drawings.count == before, "出口 a 不得落库")
        #expect(e.drawingSession.selectedDrawingID == nil, "出口 a 留下了陈旧选中（M13 要挡的就是这个）")
    }

    // ── N-lock-4（出口 c，对应 M14）：几何预检 nil ──

    @Test("N-lock-4 / 出口 c：先有选中 → 射线锚点越主图右缘致 visibleGeometry 返 nil → 选中被清空、零落库")
    func exitCClearsSelectionAndLandsNothing() {
        let e = Self.drawingEngine()
        #expect(e.appendDrawing(Self.upperCandidate(e, id: "OLD", price: 40)) == true)
        e.drawingSession.setCommittedSelection(id: "OLD", panel: .upper)
        #expect(e.drawingSession.selectedDrawingID == "OLD")
        let before = e.drawings.count

        // 本局默认改成射线；锚落在 candleIndex 20 →
        // indexToX(20) = (20-0)*10 + 0 = 200 ≥ mainChartFrame.maxX(100) → lineXRange 返 nil。
        // ⚠️ 必须**单元级直接造 viewport**：spec §3.2 已证明这一条经真实 tap 恒不可达
        //   （tapToAnchor 的 contains 门 + xToIndex 的 round-trip 后置条件）。
        var s = e.drawingSession.defaultStyle
        s.lineSubType = .ray
        e.drawingSession.setDefaultStyle(s)
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 20, price: 50), panel: .upper)

        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)

        #expect(e.drawings.count == before, "出口 c 不得落库（既有落库门，本片一字不改）")
        #expect(e.drawingSession.selectedDrawingID == nil, "出口 c 留下了陈旧选中（= codex spec-R1 那条 high）")
    }

    // ── 边界：② 用的必须是**调用方传进来的** mapper，不是 session 里发布的那一份 ──

    @Test("第 ② 步用调用方传入的 mapper：session 从未发布过视口也照样提交成功（不得顺手改成 fail-closed）")
    func exitCUsesCallerMapperNotSessionMapper() {
        let e = Self.drawingEngine()
        #expect(e.drawingSession.viewportMapper(for: .upper) == nil, "本档要求 session 里没有已发布的视口")
        e.drawingSession.addAnchor(
            DrawingAnchor(period: e.upperPanel.period, candleIndex: 0, price: 50), panel: .upper)

        DrawingEditRouter.commitPendingAndSelect(panel: .upper, mapper: Self.mapper(), engine: e)

        #expect(e.drawings.count == 1,
                "改成 session.viewportMapper(for:) 会在这里变成 fail-closed —— 那是对既有落库门的行为改动")
    }
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingCommitRouteTests 2>&1 | tail -20
```

预期：**编译失败**，报 `type 'DrawingEditRouter' has no member 'commitPendingAndSelect'`。

- [ ] **Step 3: 最小实现**

在 `DrawingEditRouter.swift` 里，紧接在 `// MARK: D83 / D84 / D85 提交路由` 之后、`routeAndSelect` **之前**插入：

```swift
    /// **外层 = 生产入口**：从 pending 锚提交一条新线，并按状态决定选中处置。
    ///
    /// 覆盖 D83 分支 1 与分支 2 的**全部六条出口**（spec §3.1 那张表）—— 这就是它必须从
    /// `commitPending` 开始、而不是从 `routeDrawingCommit` 开始的全部理由（spec §3.4）：
    /// 出口 a / b / c 在改动前是 `ChartContainerView` 里的 `return`，在 `routeDrawingCommit`
    /// **之前**就退出了，于是最主要的两条被拒路径**永远不会清空选中**，D37 那个陷阱原样复现。
    /// ⚠️ **错误的修法（明令禁止，spec §3.4）**：在 `ChartContainerView` 的两处 `guard … else { return }`
    ///    里各补一句 `clearSelection()` —— 那会把分支 2 的判据散进三个地方，其中两处在 UIKit-gated
    ///    文件里（host 上根本不编译），且「三处保持一致」没有任何机制保证。
    ///
    /// `commitPending` 与 `routeDrawingCommit` 在 `Sources/` 里的**唯一**调用点（源码守卫 G1 / G1b）。
    static func commitPendingAndSelect(panel: PanelId, mapper: CoordinateMapper, engine: TrainingEngine) {
        let session = engine.drawingSession

        // ① 出口 a（多锚 period 不一致）/ 出口 b（`withStyle` 语义闸拒，如水平线的 `.segment`）。
        //    判据与顺序**一字承接**改动前 `ChartContainerView` 的那道门 —— 本片只是给它补一句
        //    `clearSelection()` 并搬了位置，**不新增、不放宽、不重排任何落库门**（spec §5.1 约束 3）。
        guard let committed = session.commitPending(panelPosition: panel == .upper ? 0 : 1) else {
            session.clearSelection()                       // 变异 M13 守这一句
            return
        }

        // ② 出口 c（射线锚点越主图右缘 → `lineXRange` 返 nil）。承接改动前那道「不可见画线不落库」的门。
        //    ⚠️ 用的是**调用方传进来的 `mapper`**，**不是** `session.viewportMapper(for: panel)`
        //       （spec §5.1 约束 2）：改动前那道门用的就是本次 tap 现算的 mapper；换成 session 里
        //       发布的那一份会在「本面板无 candles」时变成 fail-closed —— 那是对**既有落库门**的
        //       行为改动，不属本片范围。**不得顺手"改进"**。
        guard HorizontalLineTool.visibleGeometry(for: committed, mapper: mapper) != nil else {
            session.clearSelection()                       // 变异 M14 守这一句（= codex spec-R1 那条 high）
            return
        }

        // ⚠️ ① / ② 的 `clearSelection()` 在 D84 复盘门（内层第 ⑤ 步）**之前**，这是有意的
        //    （spec §5.1 约束 1）：那道门管的是复盘**不得获得**选中能力，而「清空」从不授予任何能力
        //    —— 无论哪个模式，一次被拒的提交都不该留下陈旧选中。**不得**把第 ⑤ 步提前去包住 ① / ②。
        routeAndSelect(committed, panel: panel, engine: engine)
    }
```

- [ ] **Step 4: 跑测试，确认它通过**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingCommitRouteTests 2>&1 | tail -10
```

预期：`Test run with 13 tests in 1 suites passed`（Task 2 的 7 条 + 本 task 的 6 条）。

- [ ] **Step 5: 写守卫 G6 / G4b**

追加到 `DrawingAutoSelectSourceGuardTests.swift`：

```swift
    // MARK: G6（本 task 落地：拆内外两层不得变成两个生产入口）

    func testG6_routeAndSelectHasExactlyOneCallSiteInRouter() throws {
        try assertExactlyOneSite("routeAndSelect(", inFileSuffixed: "Drawing/DrawingEditRouter.swift")
    }

    func testG6SelfCheck_bothDirections() {
        let positive = """
        func caller() { routeAndSelect(committed, panel: panel, engine: engine) }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive), pattern: "routeAndSelect("), 1,
                       "自检①失败：真实调用没被数到 —— 守卫已失效")

        let negative = """
        static func routeAndSelect(_ committed: DrawingObject, panel: PanelId, engine: TrainingEngine) { }
        // routeAndSelect(注释里的不算)
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(negative), pattern: "routeAndSelect("), 0,
                       "自检②失败：定义/注释被误计 —— 守卫会假红")
    }

    // MARK: G4b（本 task 落地：分支 2 的每条出口都真的接上了 clearSelection）

    func testG4b_routerHasAtLeastFourClearSelectionCallSites() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // ios/Contracts
        let path = repoRoot.appendingPathComponent(routerPath).path
        let n = callCount(inSqueezed: try squeezedSource(path), pattern: "clearSelection(")
        // **下界**不是精确值（spec §8 G4b）：applyStyle / deleteSelected 等既有路径也可能增加。
        // 4 = 外层第 ① 步 + 外层第 ② 步 + 内层第 ⑥ 步的 else + 既有 syncSelectionByState。
        XCTAssertGreaterThanOrEqual(n, 4,
            "DrawingEditRouter 里只有 \(n) 处 clearSelection —— 分支 2 的某条出口没接上")
    }

    func testG4bSelfCheck_bothDirections() {
        let positive = """
        func a() { session.clearSelection() }
        func b() { engine.drawingSession.clearSelection() }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive), pattern: "clearSelection("), 2,
                       "自检①失败：真实调用没被数全 —— 守卫已失效")

        let negative = """
        func clearSelection() { }
        // session.clearSelection(注释里的不算)
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(negative), pattern: "clearSelection("), 0,
                       "自检②失败：定义/注释被误计 —— 守卫会假红")
    }
```

⚠️ `testG4b_…` 里的 `repoRoot` 上溯层数必须与本文件所在深度一致（`Tests/KlineTrainerContractsTests/Drawing/<本文件>` → 上溯 3 层到 `ios/Contracts`）。**跑之前先加一句自足断言**：若 `try squeezedSource(path)` 抛错或返回空串，测试必须**报错**而不是静默通过 —— `squeezedSource` 读不到文件会抛，XCTest 会把它记成 failure，这一条已满足。

- [ ] **Step 6: 跑守卫 + host 全量**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts"
swift test --filter DrawingAutoSelectSourceGuardTests 2>&1 | tail -10 || exit 1
swift test 2>&1 | tee /tmp/gate-t3.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-t3.log | tail -2
grep -E "Test Case .*(testG6_routeAndSelectHasExactlyOneCallSiteInRouter|testG4b_routerHasAtLeastFourClearSelectionCallSites).* passed" /tmp/gate-t3.log
```

- [ ] **Step 7: 变异 M13 / M14**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift /tmp/DrawingEditRouter.swift.bak
```

| 变异 | 改法 | 必须且只应变红 |
|---|---|---|
| **M13** | 删掉第 ① 步的 `session.clearSelection()`（`else { return }` 保留） | **只有** `exitAClearsSelectionAndLandsNothing`；`exitCClearsSelectionAndLandsNothing` **不得**红 |
| **M14** | 删掉第 ② 步的 `session.clearSelection()`（`else { return }` 保留） | **只有** `exitCClearsSelectionAndLandsNothing`；`exitAClearsSelectionAndLandsNothing` **不得**红 |

⚠️ 两条**互不重叠**是判别力的核心 —— 若两条变异红的是同一批测试，说明两个档没有各自对准自己那一步，**必须回头拆开再验**（[[feedback_same_predicate_multiple_bypasses]]）。

复原后 `git status --short` 确认干净。

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingCommitRouteTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift
git commit -m "feat(drawing): D85 外层 commitPendingAndSelect —— 造对象的两道门 + 出口 a/b/c 清空选中 + G6/G4b

分界线定在 shouldCommit 之后（分支 3「还没到提交」与分支 1/2「已尝试提交」的天然分水岭），
于是六条出口全部落进同一个函数体，一处写完没有第二处可以写漏。
①② 的判据与顺序一字承接改动前 ChartContainerView 的两道门，只是各补一句 clearSelection 并搬了位置——
不新增、不放宽、不重排任何落库门。第 ② 步用的是**调用方传入的 mapper**，不是 session 里发布的那一份
（换了会在「本面板无 candles」时变成 fail-closed = 对既有落库门的行为改动）。
①② 的 clearSelection 刻意在复盘门之前：门管「不得获得选中能力」，清空从不授予任何能力。

测试 6 条（P1/P2 + 连续画线 + N-lock-3/N-lock-4 + mapper 来源边界）；守卫 G6 / G4b + 双向自检。
变异 M13/M14 逐条关门看红，且已验两条**互不重叠**（详见 PR 描述）。
⚠️ 本提交后 G1/G1b 仍红（旧调用点还在 ChartContainerView），由 Task 4 收口。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `ChartContainerView` 换调用 + 补 `rebuildRenderState` + Catalyst 四处基线同步

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift:349-364`（`.draw` 分支）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewAutoSelectTests.swift`（**唯一**一条新增 UIKit-gated 测试）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift`（追加 G1 / G1b）
- Modify: `.github/scripts/catalyst-uikit-baseline.txt` · `catalyst-total-baseline.txt` · `catalyst-gate.test.sh` · `fixtures/pass-main-current.log`

**Interfaces:**
- Consumes: `DrawingEditRouter.commitPendingAndSelect(panel:mapper:engine:)`（Task 3）、`Coordinator.rebuildRenderState(bounds: CGRect)`（既有，`ChartContainerView.swift:174`）
- Produces: 无新符号。本 task 之后 `commitPending` / `routeDrawingCommit` 在 `Sources/` 里各恰好 1 个调用点。

- [ ] **Step 1: 写失败的测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewAutoSelectTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewAutoSelectTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §5.3（M12）
// 平台门：UIKit-only（Catalyst / 模拟器跑；macOS host swift test 整份不编译）。
// ⚠️ 本文件是本片**唯一**新增的 UIKit-gated 测试 —— 新增即触发 Catalyst 四处基线同步
//    （[[feedback_catalyst_uikit_baseline_four_sync]]，本 task Step 6）。
#if canImport(UIKit)
import Testing
import SwiftUI
import UIKit
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("自动选中 × 渲染态：画线态提交后**本帧**高亮就跟上")
@MainActor
struct ChartContainerViewAutoSelectTests {

    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 480)

    /// 造「一个 engine + 上面板一个真 Coordinator（真 KLineView，已布局出有效 viewport）」。
    /// 结构照抄同目录 `ChartContainerViewDrawingSessionTests.makeRig`（同一份 rig 语义）。
    private func makeRig() -> (TrainingEngine, ChartContainerView.Coordinator, KLineView) {
        let engine = TrainingEngine.preview()
        let c = ChartContainerView(panel: .upper, engine: engine).makeCoordinator()
        let v = KLineView(frame: bounds)
        c.attach(to: v)
        c.rebuildRenderState(bounds: bounds)          // 出真 viewport（candleStep > 0）
        return (engine, c, v)
    }

    /// 主图区内一个**真实可见 candle 上**的可落锚点 = 首根可见 candle 的中心。
    /// ⚠️ 不可用 `mainChartFrame.midX`：preview rig 的可见 slice 只有 1 根，midX 落在右侧 overscroll
    ///    空白区，`xToIndex` 越界会被 fail-closed 校验拒掉（理由与同目录既有 rig 逐字相同）。
    private func mainChartPoint(_ view: KLineView) -> CGPoint {
        let vp = view.renderState.viewport
        let mapper = CoordinateMapper(viewport: vp, displayScale: view.traitCollection.displayScale)
        return CGPoint(x: mapper.indexToX(vp.startIndex) + vp.geometry.candleStep / 2,
                       y: vp.mainChartFrame.midY)
    }

    @Test("M12 的守门测试：画线态点一下 → 落线 + 自动选中，且**本帧** renderState.selectedDrawingID 已是新那条")
    func drawTapUpdatesRenderStateSelectionInSameFrame() {
        let (engine, c, v) = makeRig()
        engine.toggleDrawingMode()
        #expect(engine.drawingSession.mode == .draw)

        c.handleDrawingTapForTesting(at: mainChartPoint(v))

        // ① 落线 + 自动选中（经 DrawingEditRouter，路由本身的判据已在 host 测过）
        #expect(engine.drawings.count == 1)
        let newId = try! #require(engine.drawings.last?.id)
        #expect(engine.drawingSession.selectedDrawingID == newId)

        // ② **本帧**渲染态就已经跟上 —— 这是 M12 唯一的判别力所在：
        //    handleDrawingTap 开头那次 rebuildRenderState 发生在选中改变**之前**，
        //    不补 `.draw` 分支这一次重建，本帧画出来的还是旧选中（高亮慢一帧）。
        //    ⚠️ 不得改成依赖 SwiftUI observation 顺带刷新：Coordinator 这条直连路径不经
        //       updateUIView，那样等于没有证据。
        #expect(v.renderState.selectedDrawingID == newId,
                "本帧渲染态没跟上 —— `.draw` 分支缺了那一次 rebuildRenderState")
    }
}
#endif
```

⚠️ 把 `try!` 写成 `func … throws` + `try #require`（swift-testing 惯例，本仓既有测试的写法）。

⚠️ **先确认 `handleDrawingTapForTesting` 与 `KLineRenderState.selectedDrawingID` 两个名字在当前树上真实存在**（同目录 `ChartContainerViewDrawingSessionTests.swift` 已在用前者）。若签名不同，**以当前树为准改测试，不要改生产代码去迁就测试**。

- [ ] **Step 2: 跑测试，确认它失败**

⚠️ **host `swift test` 对本条零判别力**（`#if canImport(UIKit)` 在 macOS 上整份不编译）。必须上 Catalyst：

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
rm -rf /tmp/derived-t4                       # 冷构建（G-6）
cd "$repo/ios/Contracts" && xcodebuild test \
  -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath /tmp/derived-t4 2>&1 | tee /tmp/catalyst-t4-red.log | tail -20
grep -c "✔ Test .* passed after" /tmp/catalyst-t4-red.log     # 判绿读执行量，不读 TEST SUCCEEDED
```

预期：`drawTapUpdatesRenderStateSelectionInSameFrame` **失败** —— 断言 ② 红（`renderState.selectedDrawingID` 仍是 nil，因为 `.draw` 分支还没补 `rebuildRenderState`）。
**若断言 ① 也红**，说明路由没接上，先回头查 Task 3。

- [ ] **Step 3: 最小实现**

编辑 `ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift`，把 `.draw` 分支（`:349-364`，含那段「本分支一字未改」的旧注释）**整段替换**为：

```swift
            case .draw:
                let ps = (panel == .upper) ? engine.upperPanel : engine.lowerPanel
                guard let anchor = inputController.tapToAnchor(at: point, panel: ps, mapper: mapper) else { return }
                session.addAnchor(anchor, panel: panel)          // D31：落在 ≠ pendingAnchorPanel 的面板 → 容器内部只丢 pending
                // D83 分支 3 的边界（spec §3.4）：`shouldCommit` 是「还没发起提交」与「已尝试提交」的
                // 天然分水岭。它之前返回 = 连锚都没成形 → **不动选中**（一次误触不该夺走选中，
                // 而画线态无法重新选中：D38 画线态恒不做命中判定）。
                guard inputController.shouldCommit(current: session.pendingAnchors, tool: tool) else { return }
                // D85：整段「尝试提交」收口进路由 —— 四道 guard 变一次调用，UIKit-gated 文件里的判据
                // **净减少两条**；分支 2 的六条出口从此在同一个函数体内，host `swift test` 就能验。
                // ⚠️ **不得**在这里另写 clearSelection（spec §3.4 明令）：判据散进三处、其中两处
                //    在本文件里（host 上不编译），且「三处保持一致」没有任何机制保证。
                DrawingEditRouter.commitPendingAndSelect(panel: panel, mapper: mapper, engine: engine)
                // ⚠️ 选中态变了必须**立刻**重建渲染态（理由与下面 `.select` 分支那一句逐字相同，spec §5.3）：
                //    本函数开头的 `rebuildRenderState` 发生在选中改变**之前**，而高亮渲染读的是
                //    `KLineRenderState.selectedDrawingID` → 不补这一次重建，本帧画出来的还是旧选中。
                //    **不要**改成依赖 SwiftUI observation 顺带刷新：Coordinator 这条直连路径不经
                //    `updateUIView`，那样等于没有证据。
                rebuildRenderState(bounds: view.bounds)
                // ← 此处**故意没有** engine.commitDrawing(panel:)：连续画线（D38），会话与工具保持不变。
```

- [ ] **Step 3b: 把既有守卫 `rejectsInvisibleDrawingBeforePersist` **重新指向路由文件**（不是删掉它）**

> **控制者裁决（开工前冲突扫描 F1）**：`Drawing/DrawingSessionSourceGuardTests.swift` 里的
> `rejectsInvisibleDrawingBeforePersist` 断言「`ChartContainerView` 里 `session.commitPending(` 与
> `engine.routeDrawingCommit(` **之间**夹着 `HorizontalLineTool.visibleGeometry(` + `!= nil`」。
> Step 3 把这三样全从该文件搬走了 → 它的 `try #require(code.range(of: "session.commitPending("))`
> **会当场红**。
>
> **裁决：重新指向 `Drawing/DrawingEditRouter.swift`，不得删除。**
> 理由：这条守卫守的不变量（**不可见画线不落库** —— 落在右缘的射线会 append + autosave 成一条
> 画不出、命不中、删不掉的幽灵线）**在 D85 搬家之后一字不变地继续成立**，只是换了文件。
> 删掉它 = 本片顺手拆掉了一道与自己无关的安全网，正是 spec §1「不新增门、不放宽门」的反面。

把该测试改为（**只换文件与注释，判据结构一字不动**）：

```swift
    @Test("codex rebased-R2：不可见画线（右缘 ray 等 visibleGeometry==nil）不落库——commitPending 与 routeDrawingCommit 之间有 fail-closed 守卫")
    func rejectsInvisibleDrawingBeforePersist() throws {
        // ⚠️ 自动选中 PR（D85）把整段「尝试提交」从 ChartContainerView 搬进了 DrawingEditRouter，
        //    本守卫随之改读路由文件。**守的不变量一字未变**：落在右缘的射线不得 append + autosave
        //    成一条画不出 / 命不中 / 删不掉的幽灵线。
        let code = try source("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift")
        let s = try #require(code.range(of: "session.commitPending("), "找不到 commitPending 调用")
        let tail = String(code[s.upperBound...])
        let e = try #require(tail.range(of: "engine.routeDrawingCommit("), "找不到 routeDrawingCommit")
        let between = String(tail[..<e.lowerBound])
        #expect(between.contains("HorizontalLineTool.visibleGeometry("))
        #expect(between.contains("!= nil"))
    }
```

⚠️ **两处必须实测确认再改**：① `source(_:)` 这个 helper 接的是「相对 `ios/Contracts` 的路径」（见该文件顶部的 `contractsDir` 定义）；② 搬家后 `routeDrawingCommit` 在路由文件里位于**内层** `routeAndSelect`，而 `commitPending` 在**外层** —— 外层在文件中排在内层**之前**（Task 3 Step 3 明确要求插在 `routeAndSelect` 之前），故「先 `commitPending` 后 `routeDrawingCommit`」的文本顺序成立。**若实测顺序相反，报回，不要为了让守卫过而调换生产代码的函数顺序。**

同时把同文件里 `#expect(code.contains("session.addAnchor("))` 那两条「先证明真读到文件」的自足断言逐条跑一遍确认仍绿（`addAnchor` 仍留在 `ChartContainerView`）。

- [ ] **Step 4: 跑 Catalyst，确认它通过**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
rm -rf /tmp/derived-t4
cd "$repo/ios/Contracts" && xcodebuild test \
  -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath /tmp/derived-t4 2>&1 | tee /tmp/catalyst-t4.log | tail -5
grep -E "✔ Test run with [0-9]+ tests" /tmp/catalyst-t4.log      # 记下这个总数，Step 6 要用
grep -c "Test Case .* failed" /tmp/catalyst-t4.log || true       # 必须是 0
grep "drawTapUpdatesRenderStateSelectionInSameFrame" /tmp/catalyst-t4.log
```

预期：总数行出现、failed 计数为 0、点名的那条测试有 `✔ … passed after`。

- [ ] **Step 5: 写守卫 G1 / G1b**

追加到 `DrawingAutoSelectSourceGuardTests.swift`：

```swift
    // MARK: G1 / G1b（本 task 落地：两个写入面各自收口到路由里，「只搬一半」会被抓）

    func testG1_routeDrawingCommitHasExactlyOneCallSiteInRouter() throws {
        try assertExactlyOneSite("routeDrawingCommit(", inFileSuffixed: "Drawing/DrawingEditRouter.swift")
    }

    /// G1b 防的是「只搬一半」——把 `commitPending` 留在 `ChartContainerView` 里，
    /// 于是出口 a / b 的 clearSelection 又回到了 host 测不到的地方。
    func testG1b_commitPendingHasExactlyOneCallSiteInRouter() throws {
        try assertExactlyOneSite("commitPending(", inFileSuffixed: "Drawing/DrawingEditRouter.swift")
    }

    func testG1AndG1bSelfCheck_bothDirections() {
        let positive = """
        func caller() {
            engine.routeDrawingCommit(committed)
            let c = session.commitPending(panelPosition: 0)
        }
        """
        let sq = squeezedText(positive)
        XCTAssertEqual(callCount(inSqueezed: sq, pattern: "routeDrawingCommit("), 1, "自检①失败：G1")
        XCTAssertEqual(callCount(inSqueezed: sq, pattern: "commitPending("), 1, "自检①失败：G1b")

        let negative = """
        func routeDrawingCommit(_ drawing: DrawingObject) { }
        func commitPending(panelPosition: Int) -> DrawingObject? { nil }
        // engine.routeDrawingCommit(注释里的不算)
        func caller() { commitPendingAndSelect(panel: panel, mapper: mapper, engine: engine) }
        """
        let sqn = squeezedText(negative)
        XCTAssertEqual(callCount(inSqueezed: sqn, pattern: "routeDrawingCommit("), 0, "自检②失败：G1")
        // ⚠️ 关键的一条：`commitPendingAndSelect(` **不含**子串 `commitPending(`（那里是 `A` 不是 `(`），
        //    外层入口不得被 G1b 误计成第二个调用点。
        XCTAssertEqual(callCount(inSqueezed: sqn, pattern: "commitPending("), 0,
                       "自检②失败：G1b 把定义/注释/commitPendingAndSelect 误计了")
    }
```

- [ ] **Step 6: Catalyst 四处基线同步（缺一 CI 必红）**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo"

# 1) uikit 清单：由脚本**重生成**（不许手写）。预期 77 → 78，diff 恰为本 task 新增那一条。
python3 .github/scripts/uikit-expected-tests.py > /tmp/uikit-new.txt || exit 1
diff .github/scripts/catalyst-uikit-baseline.txt /tmp/uikit-new.txt || true
wc -l /tmp/uikit-new.txt          # 必须是 78
cp /tmp/uikit-new.txt .github/scripts/catalyst-uikit-baseline.txt

# 2) total 基线：写入 Step 4 那条 `✔ Test run with N tests` 的**真实 N**
grep -E "✔ Test run with [0-9]+ tests" /tmp/catalyst-t4.log
# → 把 N 写进去（把 <N> 换成真实数字，不要凭估算）
# echo "<N>" > .github/scripts/catalyst-total-baseline.txt
```

3) **`fixtures/pass-main-current.log`**：用 **Step 4 的真冷构建日志** `/tmp/catalyst-t4.log` 逐行重裁。
   照上一片 `e5dbc96` 的做法：汇总行 / macabi 编译证据 / `SwiftCompile` / **78 条 `✔ … passed after` 行**全部**逐字取自真日志**。
   ⚠️ **禁手打伪造行**（`catalyst-gate.test.sh` L379-380 的维护约定）。任何一条摘不到就整体失败、回头查日志，不要补写。
   ⚠️ 日志里的绝对路径会从 `drawing-default-persist` 变成 `drawing-autoselect` —— **这是正常的**，闸门不校验路径。

4) **`catalyst-gate.test.sh`**：把「活基线覆盖」用例里写死的 `1778` 改成新的 N（**共 3 处**，用 `grep -n "1778"` 逐处确认），并在文件末尾的维护记录段追加本轮条目：

```
#   【画完自动选中（本轮）】总数 <旧N>→<新N>（+<差>）：Task 1-6 新增的 host-visible 测试。
#   uikit 77→78（+1）：Task 4 的 M12 守门测试 ChartContainerViewAutoSelectTests
#   （`#if canImport(UIKit)` 门控，host swift test 完全不编译）。
#   pass-main-current.log 已用本轮真 fresh Catalyst 日志重裁。
```

- [ ] **Step 7: 跑三道闸门 + host 全量**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo"
bash .github/scripts/catalyst-gate.test.sh 2>&1 | tail -5 || exit 1        # 期望：N 通过 0 失败，exit=0
bash .github/scripts/catalyst-gate.sh /tmp/catalyst-t4.log 2>&1 | tail -5 || exit 1   # 期望：GATE PASS
cd "$repo/ios/Contracts"
swift test --filter DrawingAutoSelectSourceGuardTests 2>&1 | tail -10 || exit 1
swift test 2>&1 | tee /tmp/gate-t4.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-t4.log | tail -2
grep -E "Test Case .*(testG1_routeDrawingCommitHasExactlyOneCallSiteInRouter|testG1b_commitPendingHasExactlyOneCallSiteInRouter).* passed" /tmp/gate-t4.log
```

⚠️ **`catalyst-gate.test.sh` 是本步真正的判据** —— 上一片实测教训：本地 `xcodebuild test` 跑得过**不等于** CI 过，CI 在真构建之前还有一步 Gate self-test，它把**活基线**与**冻结样例日志**对拴；只跑构建本身对这一步零判别力。

- [ ] **Step 8: 变异 M12（唯一一条必须上 Catalyst 的）**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift /tmp/ChartContainerView.swift.bak
```

| 变异 | 改法 | 必须且只应变红 |
|---|---|---|
| **M12** | 删掉 `.draw` 分支新增的那句 `rebuildRenderState(bounds: view.bounds)` | **只有** `drawTapUpdatesRenderStateSelectionInSameFrame` 的**断言 ②**（`renderState.selectedDrawingID` 本帧仍是旧值）；断言 ① 与既有 `ChartContainerViewDrawingSessionTests` **不得**红 |

跑法与 Step 4 同（**冷构建**）。记录红的测试名，复原后 `git status --short` 确认干净，并**重跑一次 Step 4 确认变回绿**。

- [ ] **Step 9: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Render/ChartContainerViewAutoSelectTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift \
        .github/scripts/catalyst-uikit-baseline.txt .github/scripts/catalyst-total-baseline.txt \
        .github/scripts/catalyst-gate.test.sh .github/scripts/fixtures/pass-main-current.log
git commit -m "feat(drawing): .draw 分支换调用 + 补 rebuildRenderState + G1/G1b + Catalyst 四处基线同步

四道 guard 变一次 DrawingEditRouter.commitPendingAndSelect：UIKit-gated 文件里的判据净减少两条，
分支 2 的六条出口从此全部在 host swift test 上有证据（16 条变异里 15 条落在 host）。
补的那次 rebuildRenderState 与 .select 分支那一句同理由：本函数开头那次发生在选中改变之前，
不补则本帧画出来的还是旧选中；不得改成依赖 SwiftUI observation（Coordinator 直连路径不经 updateUIView）。

G1/G1b 此刻转绿（commitPending / routeDrawingCommit 在 Sources/ 里各恰好 1 个调用点，都在路由内）。
G1b 专防「只搬一半」——把 commitPending 留在 ChartContainerView 里会让出口 a/b 的清空又回到 host 测不到的地方。

Catalyst 四处同步：uikit 清单 77→78（脚本重生成）/ total 基线 / pass-main-current.log 真冷构建重裁 /
catalyst-gate.test.sh 写死值三处 + 维护记录。变异 M12 已上 Catalyst 关门看红。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: D86 读侧 —— `panelStyle` / `styleControlsEnabled` 改按 `mode` 分流

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift:117-121`（`styleControlsEnabled`）、`:134-143`（`panelStyle`）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift`

**Interfaces:**
- Consumes: `DrawingSession.mode`、`DrawingEditRouter.uniqueSelected(engine:)`（既有 private）、`editableIgnoringGeometry`（既有 private）、`setCommittedSelection`（Task 1）
- Produces: `private static func styleFields(of d: DrawingObject) -> DrawingDefaultStyle` —— Task 6 的 `selectedLineStyle` 复用它。`panelStyle` / `styleControlsEnabled` 的**签名不变**，只改内部判据。

- [ ] **Step 1: 写失败的测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift
// Spec: docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md §6（D86）
// 三张表（显示 / 置灰 / 写入）统一按 session.mode 分流，UI 层不得再自己判。
import Testing
import CoreGraphics
@testable import KlineTrainerContracts

@Suite("D86：面板的显示 / 置灰 / 写入按 mode 分流")
@MainActor
struct DrawingPanelStyleSemanticsTests {

    static func mapper() -> CoordinateMapper {
        CoordinateMapper(
            viewport: ChartViewport(startIndex: 0, visibleCount: 10, pixelShift: 0,
                                    geometry: ChartGeometry(candleStep: 10, candleWidth: 8, gap: 2),
                                    priceRange: PriceRange(min: 0, max: 100),
                                    mainChartFrame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            displayScale: 2)
    }

    /// 造「画线态 + 上面板有一条已选中的线（经 D82 的提交入口）+ mapper 已发布」。
    /// `locked` 为 true 时那条线是锁定的（`applyStyle` 会被 `editableIgnoringGeometry` 拒）。
    static func drawModeWithSelected(id: String = "A", locked: Bool = false,
                                     colorToken: DrawingColorToken = .orange,
                                     thickness: Int = 1) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, thickness: thickness, colorToken: colorToken,
                                                locked: locked, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()                                   // mode 默认 .draw
        e.drawingSession.setCommittedSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        #expect(e.drawingSession.mode == .draw)
        #expect(e.drawingSession.selectedDrawingID == id)
        return e
    }

    /// 造「选择态 + 上面板有一条已选中的线 + mapper 已发布」。
    static func selectModeWithSelected(id: String = "A", locked: Bool = false,
                                       colorToken: DrawingColorToken = .orange) -> TrainingEngine {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: id, colorToken: colorToken, locked: locked,
                                                revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: id, panel: .upper)
        e.drawingSession.setViewportMapper(mapper(), panel: .upper)
        return e
    }

    // ── 第一张表：panelStyle（面板显示什么）──

    @Test("M7 的档：画线态 + 选中线已锁定 + 默认已被改过 → 面板显示的是**本局默认**，不是那条线")
    func drawModePanelShowsSessionDefaultNotTheLine() {
        let e = Self.drawModeWithSelected(locked: true, colorToken: .orange)
        // 把本局默认改成另一个颜色（那条线锁着，改不动 → 两者分叉）
        var d = e.drawingSession.defaultStyle
        d.colorToken = .purple
        e.drawingSession.setDefaultStyle(d)

        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == .purple,
                "画线态的面板必须显示「接下来要画的样式」= 本局默认")
        #expect(e.drawings[0].colorToken == .orange, "那条线锁着，本来就没被改动")
    }

    @Test("选择态 + 有选中 → 面板显示**那条线自己**的样式（D49 这一半原样保留）")
    func selectModePanelShowsTheSelectedLine() {
        let e = Self.selectModeWithSelected(colorToken: .orange)
        var d = e.drawingSession.defaultStyle
        d.colorToken = .purple
        e.drawingSession.setDefaultStyle(d)

        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == .orange,
                "选择态必须回显那条线自己的样式，不是默认")
    }

    @Test("选择态 + 无选中 → 面板显示本局默认")
    func selectModeWithoutSelectionShowsDefault() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        var d = e.drawingSession.defaultStyle
        d.colorToken = .purple
        e.drawingSession.setDefaultStyle(d)
        #expect(DrawingEditRouter.panelStyle(engine: e).colorToken == .purple)
    }

    // ── 第二张表：styleControlsEnabled（灰不灰）──

    @Test("M8 的档：画线态 + 选中线已锁定 → 样式控件**仍可用**（面板此刻改的是本局默认）")
    func drawModeStyleControlsAlwaysEnabled() {
        let e = Self.drawModeWithSelected(locked: true)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true,
                "画线态恒可用 —— 锁定的线只该让附带的 applyStyle 被拒，不该把面板整个灰掉")
    }

    @Test("选择态 + 选中线已锁定 → 样式控件**置灰**（既有五分量谓词一字未改）")
    func selectModeLockedLineDisablesStyleControls() {
        let e = Self.selectModeWithSelected(locked: true)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == false)
    }

    @Test("选择态 + 无选中 → 样式控件可用（改「下一条线的默认」，1a-iii 起的既有能力）")
    func selectModeWithoutSelectionEnablesStyleControls() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        e.drawingSession.setMode(.select)
        #expect(DrawingEditRouter.styleControlsEnabled(engine: e) == true)
    }

    // ── P6：自动选中**不得**放宽不可逆删除的门（codex spec-R3 high 要求的回归档）──

    @Test("P6：画线态 + 自动选中的线**已锁定** → 🗑 恒灰且不可删；🔒 仍可用（否则永远解不开）")
    func lockedLineStaysUndeletableInDrawMode() {
        let e = Self.drawModeWithSelected(locked: true)
        // 两个断言缺一不可：只断言前者，一个「锁定线连 🔒 也灰掉」的实现照样绿。
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == false, "锁定线在画线态被放开删除了")
        #expect(DrawingEditRouter.canDelete(engine: e) == false, "路由层的删除门也被放开了")
        #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == true, "🔒 被误灰 → 那条线永远解不开锁")
    }
}
```

- [ ] **Step 2: 跑测试，确认它失败**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingPanelStyleSemanticsTests 2>&1 | tail -25
```

预期：`drawModePanelShowsSessionDefaultNotTheLine` 与 `drawModeStyleControlsAlwaysEnabled` **失败**（改动前两者都按「有没有选中」分流）；其余 6 条通过。
⚠️ **必须确认失败的正是这两条** —— 若别的也红，说明 rig 造错了，先修 rig 再往下走。

- [ ] **Step 3: 最小实现**

在 `DrawingEditRouter.swift` 里：

① 把 `styleControlsEnabled`（`:117-121`）的函数体改为（**头注前三段原样保留，只在 `guard` 前加一句新注释**）：

```swift
    static func styleControlsEnabled(engine: TrainingEngine) -> Bool {
        // D86（自动选中 spec §6.1 第二张表）：分流判据是 `session.mode`，不再是「有没有选中」。
        // 画线态**恒可用** —— 面板此刻改的是「本局默认」（必然写得进去），与任何线的状态无关；
        // 锁定的线只该让**附带的** `applyStyle` 被拒（§6.3 #2：灰只降饱和、绝不写解释文案），
        // 不该把面板整个灰掉。
        guard engine.drawingSession.mode == .select else { return true }
        guard engine.drawingSession.selectedDrawingID != nil else { return true }   // ①
        return editableIgnoringGeometry(engine: engine)
            && engine.drawingSession.selectionGeometryVisible                        // ②
    }
```

② 把 `panelStyle`（`:134-143`）改为：

```swift
    static func panelStyle(engine: TrainingEngine) -> DrawingDefaultStyle {
        // D86（自动选中 spec §6.1 第一张表）：分流判据是 `session.mode`，不再是「有没有选中」。
        // 画线态恒显示**本局默认**（=「接下来要画的样式」）。这条规则的自洽性来源是 D38：
        // 画线态下点图表是落锚、**不做 hitTest** → 画线态下被选中的必然是刚画的那一条；
        // 提交那一刻两者相等（`commitPending` 就是用 `defaultStyle` 造的线），只在「那条线改不动、
        // 默认继续改」之后才分叉 —— 而画线态的语义本来就是「我下一笔要画成什么样」。
        // 这是对 D49 的**有意修订**（§6.5 #3），不是回归。
        guard engine.drawingSession.mode == .select,
              let d = uniqueSelected(engine: engine) else { return engine.drawingSession.defaultStyle }
        return styleFields(of: d)
    }

    /// 从一条线上取 5 个样式字段。**`Sources/` 里唯一一处从 `DrawingObject` 取样式**（D49）。
    /// ⚠️ 它服务两个**不同的问题**：`panelStyle` 的选择态分支问「面板显示什么」，
    ///    Task 6 的 `selectedLineStyle` 问「改线时从哪儿起算」。两者在画线态**刻意不同**
    ///    （前者取默认、后者取线）—— 合并成一个函数正是 codex spec-R9 那条 high 的来源
    ///    （§6.4：「单一真相」是对同一个问题只留一个答案，不是对两个问题共用一个函数）。
    private static func styleFields(of d: DrawingObject) -> DrawingDefaultStyle {
        var s = DrawingDefaultStyle()
        s.lineSubType = d.lineSubType
        s.lineStyle = d.lineStyle
        s.thickness = d.thickness
        s.colorToken = d.colorToken
        s.labelMode = d.labelMode
        return s
    }
```

- [ ] **Step 4: 跑测试，确认它通过**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingPanelStyleSemanticsTests 2>&1 | tail -10
```

预期：`Test run with 8 tests in 1 suites passed`。

- [ ] **Step 5: 跑 host 全量**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts"
swift test 2>&1 | tee /tmp/gate-t5.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-t5.log | tail -2
```

⚠️ **本 task 改的是两个被 UI 直接消费的谓词** —— 若既有测试（尤其 `DrawingEditRouterTests` / `DrawingStylePanelSourceGuardTests`）出现红，**逐条查明是「既有测试写的是旧语义、应当按 D86 更新」还是「本改动真的破坏了别的东西」**，不要一律改测试。判据：那条测试断言的若是「选择态」的行为，本片**不该**动它。

- [ ] **Step 6: 变异 M7 / M8**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift /tmp/DrawingEditRouter.swift.bak
```

| 变异 | 改法 | 必须且只应变红 |
|---|---|---|
| **M7** | `panelStyle` 的 guard 改回旧形态（`guard let d = uniqueSelected(engine: engine) else { return … }`，去掉 mode 分量） | **只有** `drawModePanelShowsSessionDefaultNotTheLine`；`selectModePanelShowsTheSelectedLine` / `selectModeWithoutSelectionShowsDefault` **不得**红 |
| **M8** | `styleControlsEnabled` 删掉新加的 `guard … mode == .select else { return true }` 那一行 | **只有** `drawModeStyleControlsAlwaysEnabled`；两条选择态的档 **不得**红 |

复原后 `git status --short` 确认干净。

- [ ] **Step 7: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift
git commit -m "feat(drawing): D86 读侧 —— panelStyle / styleControlsEnabled 改按 mode 分流

画线态恒显示本局默认、恒可用；选择态维持既有语义一字不改。
自洽性来源是 D38：画线态点图表是落锚、不做 hitTest → 画线态下被选中的必然是刚画那条，
所以「画线态改样式连默认一起改」不会误伤用户手动挑的旧线。

抽出 styleFields(of:) 作为「从 DrawingObject 取 5 个样式字段」的唯一一处，Task 6 的
selectedLineStyle 复用它——但两者回答的是**两个不同的问题**（面板显示什么 / 改线从哪儿起算），
在画线态刻意不同，不得合并成一个函数（codex spec-R9 high 的根因就在这里）。

P6 回归档：画线态 + 锁定线 → deleteButtonEnabled/canDelete 恒 false 且 lockButtonEnabled 恒 true，
三个断言缺一不可——自动选中不得成为放宽不可逆删除门的理由。
变异 M7/M8 逐条关门看红（详见 PR 描述）。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: D86 写侧 —— `applyPanelStyleMutation` 两个 base + 删掉两个旧 mutation + `TrainingView` 删 if 分流

> ⚠️ **本 task 承载 spec §12 明写「override 不覆盖」的那条**（§6.3 #0 的两个 base）。
> 它防的是「**静默改掉用户锁定过的线并落盘**」。M15 是**强制项**，不是可选项。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`（新增 2 个函数、**删除** `applyStyleMutation` / `applyDefaultStyleMutation`）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift:540-547`（`onStyleChange` 闭包）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift`（追加）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift`（追加 G3 / G4）

**Interfaces:**
- Consumes: `styleFields(of:)`（Task 5）、`uniqueSelected(engine:)`、`applyStyle(_:engine:)`、`DrawingSession.setDefaultStyle(_:)`
- Produces:
  - `private static func selectedLineStyle(engine: TrainingEngine) -> DrawingDefaultStyle?`
  - `static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void, engine: TrainingEngine)` —— **internal**，返回 `Void`。`TrainingView.swift` 是它在 `Sources/` 里的唯一调用点（G4）。
  - **删除**：`applyStyleMutation` / `applyDefaultStyleMutation`（被 `applyPanelStyleMutation` 严格泛化后的孤儿，CLAUDE.md §3）。

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingPanelStyleSemanticsTests.swift` 的 `struct` 末尾：

```swift
    // ── 第三张表：写入（P3 / P4 / P5 / P7 + M15 的五步档）──

    @Test("P3：画线态 + 有选中 + 改样式 → 那条线的该字段变了**且** session.defaultStyle 的该字段也变了")
    func drawModeWritesBothLineAndDefault() {
        let e = Self.drawModeWithSelected(colorToken: .orange)
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        #expect(e.drawings[0].colorToken == .purple, "线没跟着改")
        #expect(e.drawingSession.defaultStyle.colorToken == .purple, "本局默认没改 —— 主语义丢了")
    }

    @Test("P4：选择态 + 选中旧线 + 改样式 → 那条线变了**且** defaultStyle **逐字段未变**（D49 保留的那一半）")
    func selectModeWritesOnlyTheLine() {
        let e = Self.selectModeWithSelected(colorToken: .orange)
        let before = e.drawingSession.defaultStyle
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        #expect(e.drawings[0].colorToken == .purple, "线没改")
        // 逐字段断言（判别力就在这条：只比 colorToken 会漏掉别的字段被顺手写回）
        #expect(e.drawingSession.defaultStyle.colorToken == before.colorToken, "默认被回写了")
        #expect(e.drawingSession.defaultStyle.lineSubType == before.lineSubType)
        #expect(e.drawingSession.defaultStyle.lineStyle == before.lineStyle)
        #expect(e.drawingSession.defaultStyle.thickness == before.thickness)
        #expect(e.drawingSession.defaultStyle.labelMode == before.labelMode)
    }

    @Test("P5：画线态 + 无选中（刚进会话还没画）+ 改样式 → defaultStyle 变了、drawings 全部未变")
    func drawModeWithoutSelectionWritesOnlyDefault() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "OLD", colorToken: .orange, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.toggleDrawingMode()
        #expect(e.drawingSession.selectedDrawingID == nil)
        let before = e.drawings
        let revisionBefore = e.drawingsRevision

        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)

        #expect(e.drawingSession.defaultStyle.colorToken == .purple)
        expectDrawingsUnchanged(e, before, revisionBefore: revisionBefore)
    }

    @Test("P7：画线态 + 选中线未锁定 + 只改**一项** → 线上**只有该项**变、其余 4 项逐字段未变")
    func drawModeChangesOnlyTheTouchedField() {
        let e = Self.drawModeWithSelected(colorToken: .orange, thickness: 1)
        let before = e.drawings[0]

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)

        #expect(e.drawings[0].thickness == 3, "用户点的那一项没变")
        // ⚠️ 断言「其余 4 项未变」是 §6.3 #0 的**正向证据**，不能只断言变了的那一项
        #expect(e.drawings[0].colorToken == before.colorToken)
        #expect(e.drawings[0].lineSubType == before.lineSubType)
        #expect(e.drawings[0].lineStyle == before.lineStyle)
        #expect(e.drawings[0].labelMode == before.labelMode)
        #expect(e.drawingSession.defaultStyle.thickness == 3, "本局默认的该项也要变")
    }

    /// **M15 的具名档（spec §7.2 强制项）**：完整五步。
    /// ⚠️ 少任何一步都零判别力 —— 没有「锁定 → 改色被拒」，默认与线不会分叉，
    ///    把写线的 base 改回默认快照也照样绿。
    @Test("M15 五步档：画线 → 锁定 → 改色被拒 → 解锁 → 只改粗细 ⇒ 颜色**仍是原色**（不得被追认）")
    func lockedDivergenceIsNeverRetroactivelyApplied() {
        // 第 1 步：画一条橙色、粗细 1 的线并自动选中（画线态）
        let e = Self.drawModeWithSelected(id: "A", locked: false, colorToken: .orange, thickness: 1)
        #expect(e.drawings[0].colorToken == .orange)

        // 第 2 步：锁定它
        #expect(e.setDrawingLocked(id: "A", locked: true) == true, "锁定失败，本档不成立")
        #expect(e.drawings[0].locked == true)

        // 第 3 步：改颜色为紫 → 默认变紫；applyStyle 被 !d.locked 拒 → 线仍是橙 ⇒ **默认与线已分叉**
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        #expect(e.drawingSession.defaultStyle.colorToken == .purple, "默认必须改成功（主语义）")
        #expect(e.drawings[0].colorToken == .orange, "锁定的线不该被改动 —— 分叉没造出来，本档零判别力")

        // 第 4 步：解锁
        #expect(e.setDrawingLocked(id: "A", locked: false) == true)
        #expect(e.drawings[0].locked == false)

        // 第 5 步：只改**粗细**
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)

        #expect(e.drawings[0].thickness == 3, "用户真正点的那一项要生效")
        #expect(e.drawings[0].colorToken == .orange,
                "颜色被静默追认成紫了 —— §6.3 #0 那条缺陷复现（用户特意锁起来保护过的值被改掉并落盘）")
        #expect(e.drawingSession.defaultStyle.colorToken == .purple, "默认那一侧不受影响，仍是紫")
    }

    /// M11 的档：两个 base 都必须**现取**，不得接收调用方传入的快照。
    @Test("M11 的档：两次连续改动不互相 revert（1b-i PR-4 整支 R3 那条真丢数据回归的守门）")
    func consecutiveMutationsDoNotRevertEachOther() {
        let e = Self.drawModeWithSelected(colorToken: .orange, thickness: 1)
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 4 }, engine: e)
        #expect(e.drawings[0].colorToken == .purple, "第二次改动把第一次 revert 掉了（用了旧快照）")
        #expect(e.drawings[0].thickness == 4)
        #expect(e.drawingSession.defaultStyle.colorToken == .purple)
        #expect(e.drawingSession.defaultStyle.thickness == 4)
    }
```

⚠️ **先确认 `TrainingEngine.setDrawingLocked(id:locked:)` 的真实签名与返回类型**（1b-ii 锁定 PR #163 引入，已在 main）。若签名不同，**按当前树改测试**。

- [ ] **Step 2: 跑测试，确认它失败**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingPanelStyleSemanticsTests 2>&1 | tail -20
```

预期：**编译失败**，报 `type 'DrawingEditRouter' has no member 'applyPanelStyleMutation'`。

- [ ] **Step 3: 最小实现（三处一起，缺一编译不过）**

**① `DrawingEditRouter.swift`：删掉 `applyStyleMutation` 与 `applyDefaultStyleMutation` 两个函数（含它们的头注），在原位置换成：**

```swift
    /// §6.4 base ②：选中线**当前**的 5 个样式字段（无选中 / 不唯一 / 结构性不可见 → nil）。
    /// 与 `panelStyle` 的选择态分支**同源取值**（都经 `uniqueSelected` + `styleFields`），
    /// 但**语义不同**：那个回答「面板显示什么」，这个回答「改线时从哪儿起算」。
    /// 两者在画线态**刻意不同** —— 前者取默认、后者取线。
    private static func selectedLineStyle(engine: TrainingEngine) -> DrawingDefaultStyle? {
        guard let d = uniqueSelected(engine: engine) else { return nil }
        return styleFields(of: d)
    }

    /// D86：常驻面板的**唯一**写入入口。取代 applyStyleMutation / applyDefaultStyleMutation
    /// （三个分支的 base 与写入与它们逐一等价，是严格泛化 → 那两个成为本次改动制造的孤儿，已一并删除）。
    ///
    /// ⚠️ **画线态把同一个 mutation 分别套到两个 base 上**（spec §6.3 #0），**不是**套一份默认快照。
    ///    反例（上一稿会真的发生）：画线 A（橙、粗细 1，自动选中）→ 锁定 A → 改颜色为紫
    ///    （默认变紫；`applyStyle` 被 `!d.locked` 拒 → A 仍是橙 ⇒ **默认与 A 已分叉**）→ 解锁 A
    ///    → 只改**粗细**为 3。若此刻把「默认的整份快照 {紫, 3}」套上去 ⇒ **A 的颜色被静默从橙改成紫**，
    ///    并经 `drawingsRevision` → autosave **落盘**。用户只碰了粗细，被改掉的却是他刚刚特意
    ///    锁起来保护过的颜色。
    ///    ⚠️ `applyStyle` 的入参是**完整的** `DrawingDefaultStyle`（D50 的 API 形状，本片不改），
    ///       所以「只改一项」**只能靠选对 base 来表达**。**base 选错就是这条缺陷本身。**
    ///
    /// ⚠️ 两个 base 都**现取**（动作发生这一刻的真值，不是视图渲染时的快照）——
    ///    **绝不能改成接收调用方传入的快照**，那正是 1b-i PR-4 整支 R3 修过的那个真丢数据回归
    ///    （两个控件在 SwiftUI 重渲染之前先后触发，第二次拿旧快照把第一次 revert 掉，
    ///    选中线路径还会经 `drawingsRevision` 被 autosave 持久化）。
    static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                        engine: TrainingEngine) {
        let session = engine.drawingSession
        if session.mode == .draw {
            // **顺序 load-bearing**：先写默认（主语义、必须成功），**再** best-effort 改线
            // （附带、可能被锁定 / 滑出屏幕 / 未来数据 / 工具未实现四类门拒）。反过来写会让
            // 「线改失败」在实现上很容易被顺手写成「整个操作失败」，而用户点了一下颜色却什么都没变。
            var d = session.defaultStyle                        // base ①：默认自己
            mutate(&d)
            session.setDefaultStyle(d)
            if let cur = selectedLineStyle(engine: engine) {    // base ②：那条线自己当前的 5 个样式字段
                var l = cur
                mutate(&l)
                // ⚠️ 返回值**刻意丢弃**且**不得**据它决定选中生命期（D64 原样成立：失败原因有五类，
                //    其中三类必须保留选中，一个 Bool 表达不了）。失败也**不回滚默认、不给任何反馈**
                //    （母 spec §3 逐字：灰只降饱和、绝不写任何解释文案）。
                _ = applyStyle(l, engine: engine)
            }
        } else if session.selectedDrawingID != nil {
            // 选择态 + 有选中：只改那一条，**不回写默认**（D49 的核心价值，原样保留）。
            // base 取 `panelStyle` —— 选择态下它与 `selectedLineStyle` 同源，且这一支与被本函数
            // 取代的 `applyStyleMutation` **逐字等价**（严格泛化的证据）。
            var l = panelStyle(engine: engine)
            mutate(&l)
            _ = applyStyle(l, engine: engine)
        } else {
            // 选择态 + 无选中：改「下一条线的默认」。与被取代的 `applyDefaultStyleMutation` 逐字等价。
            var d = session.defaultStyle
            mutate(&d)
            session.setDefaultStyle(d)
        }
    }
```

**② `TrainingView.swift`：把 `onStyleChange` 闭包（`:540-547`）整段替换为：**

```swift
                             onStyleChange: { mutate in
                                 // D86：显示 / 置灰 / 写入三件事**统一按 `session.mode` 分流**，
                                 // UI 层**不得再自己判**。这里原先那个
                                 // `if selectedDrawingID != nil { … } else { … }` 是**第二份判据**，
                                 // 早晚与 `panelStyle` / `styleControlsEnabled` 漂移 → 必须删掉（spec §6.2）。
                                 // codex 整支 R3 的纪律不变：只转发**变更意图**（mutation 闭包），
                                 // 「现取当前真值 + 合并」交给 DrawingEditRouter，不许在这里先读一份快照。
                                 DrawingEditRouter.applyPanelStyleMutation(mutate, engine: engine)
                             },
```

同时把上方 `style:` 那一行的注释更新为 D86 语义（**只改注释文字，不改表达式**）：

```swift
                             // D86：派生值**每次求值现算**（`panelStyle` 内部按 `session.mode` 分流：
                             // 画线态恒取本局默认；选择态有选中取那条线、无选中取默认）。
                             style: DrawingEditRouter.panelStyle(engine: engine),
```

- [ ] **Step 4: 跑测试，确认它通过**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts" && swift test --filter DrawingPanelStyleSemanticsTests 2>&1 | tail -10
```

预期：`Test run with 14 tests in 1 suites passed`（Task 5 的 8 条 + 本 task 的 6 条）。

- [ ] **Step 5: 写守卫 G3 / G4**

追加到 `DrawingAutoSelectSourceGuardTests.swift`：

```swift
    // MARK: G3 / G4（本 task 落地：旧的两个 mutation 已删净，新入口只有一个调用点）

    /// ⚠️ **必须剥注释后再数**（spec §8 G3）：`applyPanelStyleMutation` 的头注里写着
    ///    「取代 applyStyleMutation / applyDefaultStyleMutation」这句**承重注释**，
    ///    不剥注释 G3 会被这句注释自己打红，而「删掉那句注释」就成了合法绕过路径。
    ///    `filesMentioning` 内部走 `squeezedSource`（已剥注释与字符串字面量），满足这一条。
    func testG3_oldMutationIdentifiersAreFullyRemoved() throws {
        for identifier in ["applyStyleMutation", "applyDefaultStyleMutation"] {
            let files = try filesMentioning(identifier)
            XCTAssertTrue(files.isEmpty,
                "『\(identifier)』本应已删除，仍出现在：\(files)（注释已剥，故这是真实代码残留）")
        }
    }

    /// 自足断言：证明扫描器**真的在扫**（否则「一个都没找到」与「扫描器坏了」长得一样）。
    func testG3IsNotVacuous_scannerReallyFindsTheReplacement() throws {
        let files = try filesMentioning("applyPanelStyleMutation")
        XCTAssertFalse(files.isEmpty, "扫描器连新入口都找不到 —— G3 是空转的")
    }

    func testG4_applyPanelStyleMutationHasExactlyOneCallSiteInTrainingView() throws {
        try assertExactlyOneSite("applyPanelStyleMutation(", inFileSuffixed: "UI/TrainingView.swift")
    }

    func testG3AndG4SelfCheck_bothDirections() {
        // ① 本该命中
        let positive = """
        func caller() { DrawingEditRouter.applyPanelStyleMutation(mutate, engine: engine) }
        """
        XCTAssertEqual(callCount(inSqueezed: squeezedText(positive),
                                 pattern: "applyPanelStyleMutation("), 1, "自检①失败：G4")

        // ② 本该**不**命中：定义 / 注释 / 名字互不为子串
        let negative = """
        static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                            engine: TrainingEngine) { }
        // 取代 applyStyleMutation / applyDefaultStyleMutation
        """
        let sqn = squeezedText(negative)
        XCTAssertEqual(callCount(inSqueezed: sqn, pattern: "applyPanelStyleMutation("), 0,
                       "自检②失败：定义被误计 —— G4 会假红")
        XCTAssertFalse(sqn.contains("applyStyleMutation"),
                       "自检②失败：注释没被剥掉 —— G3 会被自己的承重注释打红")
        // 名字互不为子串（防未来改名引入误命中）
        XCTAssertFalse("applyPanelStyleMutation".contains("applyStyleMutation"))
        XCTAssertFalse("applyPanelStyleMutation".contains("applyDefaultStyleMutation"))
    }
```

- [ ] **Step 6: 跑守卫 + host 全量**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts"
swift test --filter DrawingAutoSelectSourceGuardTests 2>&1 | tail -10 || exit 1
swift test 2>&1 | tee /tmp/gate-t6.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-t6.log | tail -2
grep -E "Test Case .*(testG3_oldMutationIdentifiersAreFullyRemoved|testG4_applyPanelStyleMutationHasExactlyOneCallSiteInTrainingView).* passed" /tmp/gate-t6.log
```

⚠️ **删掉两个旧函数会打破三处既有测试。开工前的冲突扫描已把它们逐个定位并裁决，照下表做，不要自己另行发挥：**

> **控制者裁决（开工前冲突扫描 F2 / F3 / F5）。** 共同原则：**不要为了让旧测试过而把旧函数留着**
> —— 那正是 G3 要抓的；也**不要**把守的不变量顺手删掉 —— 那是拆别人的安全网。

| # | 位置 | 为什么会红 | 裁决 |
|---|---|---|---|
| **F2** | `Render/DrawingInteractionUISourceGuardTests.swift::panelRoutesBySelection`（`:183-204`） | 五条断言：`tv.contains("DrawingEditRouter.applyStyleMutation(")` / `…applyDefaultStyleMutation(` / `tv.contains("engine.drawingSession.selectedDrawingID != nil")` / 两条 `callSiteCount(…) == 1` | **改写成 D86 形态**，见下方代码 |
| **F3** | `Drawing/DrawingEditRouterTests.swift:437-470` 两条「现取而非快照」的行为测试 | 直接调用被删的两个函数；且 `:451-452` 断言 `applyStyleMutation(…) == true`，而新入口返回 `Void` | **平移到 `applyPanelStyleMutation`**，见下方 |
| **F5** | `Render/DrawingStylePanelSourceGuardTests.swift:102` | 只在**注释**里提到旧名（`squeezedSource` 剥注释，且 G3 只扫 `Sources/`）→ **不会红** | 顺手把注释里的旧名改成 `applyPanelStyleMutation`（纯注释、零行为）；**这是本片改动造成的文档孤儿，属 CLAUDE.md §3 允许的清理** |

**F2 的改写**（`panelRoutesBySelection`）：删掉那五条，换成三条 —— 两条正向（新入口真的接上了）+ 一条**限定在 `onStyleChange:` 闭包体内**的负向（UI 层不得再自己判）：

```swift
    @Test("D86：面板写入统一按 mode 分流 —— TrainingView 只转发变更意图，**不得再自己判有没有选中**")
    func panelRoutesByMode() throws {
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains(squeeze("DrawingEditRouter.panelStyle(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.styleControlsEnabled(engine: engine)")))
        #expect(tv.contains(squeeze("DrawingEditRouter.deleteButtonEnabled(engine: engine)")))
        // D86：唯一写入入口（调用点计数归 G4 管，这里只钉「真的接上了」）
        #expect(tv.contains(squeeze("DrawingEditRouter.applyPanelStyleMutation(")))
        // spec §6.2：`onStyleChange` 闭包里留一个「有没有选中」的分流就是**第二份判据**，
        // 早晚与 panelStyle / styleControlsEnabled 漂移。**判据限定在闭包体内**——
        // 裸写 `!tv.contains("selectedDrawingID")` 会被本视图其它正当用途打红（假红）。
        let start = try #require(tv.range(of: squeeze("onStyleChange: { mutate in")),
                                 "找不到 onStyleChange 闭包起点 —— 锚点失效必须报错，不得静默通过")
        let after = String(tv[start.upperBound...])
        let end = try #require(after.range(of: squeeze("onToggleMode:")),
                               "找不到闭包终点锚 onToggleMode —— 锚点失效必须报错")
        let body = String(after[..<end.lowerBound])
        #expect(!body.contains("selectedDrawingID"),
                "onStyleChange 里还留着按「有没有选中」的分流 —— 那是 D86 要消灭的第二份判据")
    }
```

⚠️ **两处必须实测**：① `code(_:)` / `squeeze(_:)` 两个 helper 在该文件里的真实签名；② 两个锚（`onStyleChange: { mutate in` 与 `onToggleMode:`）**在 squeeze 之后**的真实形态 —— `squeeze` 会删空白，锚串要跟着写成 squeeze 后的样子（照该文件既有断言的写法）。**锚点取不到必须 `#require` 报错，不得静默返回空串通过**（[[feedback_mechanical_checker_parser_disabled]]）。

**F3 的平移**（`DrawingEditRouterTests.swift:437-470`）：两条测试的**被测性质不变**（「现取当前真值，不是渲染时的快照」），只换入口：

- `applyStyleMutation({ … }, engine: e)` → `applyPanelStyleMutation({ … }, engine: e)`；
- **删掉 `== true`**（新入口返回 `Void`），改为断言**结果字段值**（比原来的 `== true` 更强）；
- ⚠️ **先确认那两条测试的 rig 处于哪个 mode**：若是 `.select` + 有选中 / `.select` + 无选中，`applyPanelStyleMutation` 走的正是与旧函数**逐字等价**的那两支，语义完全保留；**若 rig 是 `.draw` 态，则语义会变（画线态现在同时写默认），此时必须把 rig 显式设成 `.select` 以保持原测试的被测性质**，并在提交信息里写明这一点。
- ⚠️ **不要**因为 Task 6 新写的 `consecutiveMutationsDoNotRevertEachOther` 看起来覆盖了同一性质就删掉这两条：新那条测的是**画线态**、这两条测的是**选择态与无选中态**，三者互不重叠（判别力不同）。

- [ ] **Step 7: 变异 M9 / M10 / M11 / M15**

```bash
cp ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift /tmp/DrawingEditRouter.swift.bak
```

| 变异 | 改法 | 必须且只应变红 |
|---|---|---|
| **M9** | 画线态分支里删掉 `session.setDefaultStyle(d)`（只改线） | P3 的 `defaultStyle` 断言红、**线的断言不红** |
| **M10** | 选择态有选中的分支里，在 `applyStyle` 之后**加一句** `session.setDefaultStyle(l)` | **只有** `selectModeWritesOnlyTheLine`（P4） |
| **M11** | 把 `applyPanelStyleMutation` 改成接收调用方传入的快照（加一个 `_ base: DrawingDefaultStyle` 参数，两个 base 都用它；调用点传 `panelStyle(engine:)` 一次算出的值） | **只有** `consecutiveMutationsDoNotRevertEachOther` |
| **M15** | 画线态**写线**的 base 从 `selectedLineStyle(engine:)` 改回 `session.defaultStyle`（= 整份快照：`var l = session.defaultStyle`） | **只有** `lockedDivergenceIsNeverRetroactivelyApplied`（M15 五步档）；**P7 不得红**（P7 没有分叉步骤，改回快照也照样绿 —— 这正是「M15 必须走完整五步」的机械证据） |

⚠️ **M15 是 spec §12 明写「override 不覆盖」的那一条**。它红的测试名必须在 PR 描述里**单独列出**，并写明：跑过完整五步、且**已验证 P7 在该变异下不红**（否则说明两个档判别力重叠，M15 的证据不成立）。

复原后 `git status --short` 确认干净。

- [ ] **Step 8: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift \
        ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingPanelStyleSemanticsTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingAutoSelectSourceGuardTests.swift
git commit -m "feat(drawing): D86 写侧 —— applyPanelStyleMutation 两个 base + 删两个旧 mutation + TrainingView 删 if 分流

画线态把**同一个字段级 mutation 分别套到两个 base 上**：默认的 base 是默认自己，
线的 base 是**那条线当前的 5 个样式字段**。不是套一份默认的整份快照——
后者会在「画线→锁定→改色被拒→解锁→只改粗细」这条路上把颜色静默追认成紫并落盘，
改掉的正是用户特意锁起来保护过的值（spec §6.3 #0 / codex spec-R9 high，§12 明写 override **不覆盖**）。

顺序 load-bearing：先写默认（主语义、必须成功），再 best-effort 改线（可能被四类门拒）。
applyStyle 的返回值刻意丢弃且不得据它决定选中生命期（D64：五类失败，Bool 表达不了）。
两个 base 都现取，绝不接收调用方快照（1b-i PR-4 整支 R3 那条真丢数据回归）。

TrainingView 的 if 分流整个删掉——它是第二份判据，早晚与 panelStyle / styleControlsEnabled 漂移。
旧的 applyStyleMutation / applyDefaultStyleMutation 被严格泛化后成为孤儿，一并删除（CLAUDE.md §3）。

守卫 G3（两个旧标识符剥注释后恰好 0 次，配非空转自检）/ G4 + 双向自检。
变异 M9/M10/M11/M15 逐条关门看红；**M15 已验 P7 在该变异下不红**（判别力不重叠）。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: 收尾 —— 全量闸门、交接文档、PR 描述

**Files:**
- Modify: `docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md`（只加一行实施状态，**不改任何决策**）
- 无生产代码改动

- [ ] **Step 1: 跑全部闸门（控制者**亲手**跑，不许只读 subagent 报的数字）**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd "$repo/ios/Contracts"

# ① host swift-testing + XCTest 两个数字都要记
swift test 2>&1 | tee /tmp/gate-final.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/gate-final.log | tail -2

# ② 八条源码守卫逐条点名（不是只看套件通过）
for t in testG1_routeDrawingCommitHasExactlyOneCallSiteInRouter \
         testG1b_commitPendingHasExactlyOneCallSiteInRouter \
         testG2_setCommittedSelectionHasExactlyOneCallSiteInRouter \
         testG3_oldMutationIdentifiersAreFullyRemoved \
         testG4_applyPanelStyleMutationHasExactlyOneCallSiteInTrainingView \
         testG4b_routerHasAtLeastFourClearSelectionCallSites \
         testG5_setSelectionHasExactlyOneCallSiteInChartContainerView \
         testG6_routeAndSelectHasExactlyOneCallSiteInRouter ; do
  grep -qE "Test Case .*$t.* passed" /tmp/gate-final.log \
    && echo "ok   $t" || { echo "FAIL $t —— 没跑或没过"; exit 1; }
done

# ③ Catalyst：冷构建 + 三道闸门
rm -rf /tmp/derived-final
xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath /tmp/derived-final 2>&1 | tee /tmp/catalyst-final.log | tail -5 || exit 1
grep -E "✔ Test run with [0-9]+ tests" /tmp/catalyst-final.log
grep -c "Test Case .* failed" /tmp/catalyst-final.log || true      # 必须 0
cd "$repo"
bash .github/scripts/catalyst-gate.test.sh 2>&1 | tail -3 || exit 1
bash .github/scripts/catalyst-gate.sh /tmp/catalyst-final.log 2>&1 | tail -3 || exit 1
git status --short                                                  # 必须为空
```

⚠️ **多行汇总别 `tail -1`**；**改了 `Sources/` 就要重跑门，哪怕「只改注释」**（[[feedback_controller_must_run_gates_himself]]）。

- [ ] **Step 2: 回填 spec 的实施状态（只加，不改决策）**

在 spec `§12 交付前必须补的动作` 那一节后面追加一小节（**不得**改动 §12 已有的任何一行）：

```markdown
### 实施状态（2026-08-18）

**自动选中 PR 已实施完毕**，7 个 task 全部落地（分支 `feat/drawing-p1b-autoselect`，
base = `feat/drawing-session-default-persistence`）。§7.2 表格里的每一条 M 均已逐条关门看红，
红的测试名与复原后重新变绿的证据记在 PR 描述里。

**本 spec 的收口状态不变：override 收口，未取得 approve。**
本节只记录实施进度，**不构成对 §12 override 边界的任何扩张**。
```

- [ ] **Step 3: 提交并推送**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
cd "$repo"
git add docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md
git commit -m "docs(spec): 回填自动选中 PR 的实施状态（不改任何决策，不扩张 override 边界）

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
echo "pwd=$(pwd) branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)"
git rev-list --count feat/drawing-session-default-persistence..HEAD    # 报给 user 核对提交数
git push -u origin feat/drawing-p1b-autoselect
```

⚠️ push / 开 PR 前 **pwd + branch + HEAD 三连**（[[feedback_worktree_cwd_drift]]）。主仓 `gh` 被 guard 拦时，把命令交给 user 在真终端跑（[[feedback_worktree_local_ledger_user_tty_pr]]）。

- [ ] **Step 4: 对抗性评审（Codex 通道）**

> **通道决定（user 2026-08-20）**：Codex 限额已恢复，**本片评审走 Codex**，不走 Kimi。
> `codex:adversarial-review` 是本仓**唯一**的 Codex 评审通道；`codex:rescue` 是辅助工具，**不是**评审通道。
> Skill 若被 harness 挡住，**不等于这条能力不存在** —— 直接跑底层脚本
> （[[feedback_codex_skill_blocked_use_attest_script.md]]）。

跑整支评审（**base 是持久化分支，不是 origin/main** —— 否则会把已 approve 的 #166 那 52 个提交重审一遍）：

```bash
.claude/scripts/codex-attest.sh --scope branch-diff \
  --head feat/drawing-p1b-autoselect \
  --base feat/drawing-session-default-persistence
```

- ⭐ **零 focus 窄化**（`--scope branch-diff`，不传任何 focus 目标）—— 窄化会产出**假 approve** 且账本静默不写（[[feedback_codex_focus_narrowing_false_approve]]）。
- ⛔ **绝不给脚本传未知参数**（含 `--help`）：兜底分支会把**任何未知参数**当成 focus 目标 → 假 approve + 写脏账本，三周内踩过两次（[[feedback_codex_attest_unknown_arg_becomes_focus]]）。
- ⭐ **被杀（日志里没有 `Verdict:` 行）≠ verdict**，**重跑且不计轮次**（[[feedback_codex_review_killed_not_verdict]]）。
- ⭐ 每轮跑完必须 **Read 账本文件**核实 `head_sha` == 当前 HEAD，不能只看脚本的退出码；**attest 之后别再 rebase**。
- ⚠️ Bash 对含 `attest-ledger.json` 的命令有 deny 规则，**别用 Write 绕**；需要清理时写脚本交给 user 在真终端跑。
- ⭐ 若某轮 finding 明显是「两片交界处才说得清」的形态（[[feedback_slice_boundary_masquerades_as_defect]]），**再单独跑一轮合并视角**：`--base origin/main`，把持久化片与本片当**一次完整改动**审。
- ⭐ **codex 没 approve 别写「收敛」**；6+ 轮出现自相矛盾 / 复述已接受 residual → 停下来报回。

- [ ] **Step 5: 开 PR（base = 持久化分支）**

⚠️ **base 必须在创建时就设对，不要事后改** —— 改 base 会**静默丢门**（[[feedback_stacked_pr_base_change_and_squash_conflict]]）。开完 PR 后**逐条比对本 PR 与 #166 的 check 名单**，缺项当场报回。

PR 描述（中文）**必须包含**：

1. **§12 override 边界的完整复述**（G-0 那四条），并写明「override 只赦免文档写法，不赦免行为正确性」；
2. **spec §7.2 表格里每一条 M 的逐条记录**：变异改法 / **红的是哪个测试名** / 复原后重新变绿的证据。**M15 单列**，并写明已验证 P7 在该变异下不红；
3. **八条源码守卫**各自的调用点计数实测值；
4. **两个数字**：host swift-testing 条数 / XCTest 条数；**Catalyst 总数 / uikit 条数**，以及四处基线同步的前后值；
5. **横幅**：⚠️ **本 PR 不得先于持久化 PR #166 合入**（D89 / spec §6.8）—— 本片新增的 `applyStyle` 写入会经 `drawingsRevision` → autosave 落盘，而本局默认在 #166 之前不落盘 ⇒ 「线已落盘、默认没落盘」的半持久化坏状态；
6. **交接**：画线态的一次改样式是**两处写入**，**1b-ii 撤销 PR 必须把这一对当一个动作入栈、undo/redo 一并回滚一并重做**（spec §10.1），否则被撤销的样式会在下一笔新画的线上、以及续训之后复活。

- [ ] **Step 6: 真机验收（spec §9，22 条）**

⚠️ **三片一起做真机验收、一起合**（user 2026-08-18 决定）。本 task 只把清单准备好，**不单独跑**。

前置：Debug 构建 + `KLINE_SEED_FIXTURE=1` 装机（NAS 后端未部署，不带 seed 必报「训练组文件不存在」，那是**环境缺口不是回归**，[[project_device_testing_requires_seed_fixture]]）。

**#18 / #19 / #22 是本片的三条硬边界**（不跨局 / 复盘不越界 / 被拒的改动不得被后续无关操作追认），任何一条不过都是**阻塞级**。
**#5 若弹出确认框或删掉了线 → 立即停止验收并报回**（锁定保护被削弱）。
⚠️ 验收清单的 UI 陈述**须核真机，别照 spec 抄**（[[project_drawing_p1b_1a_iv_status]]）。

---

## Self-Review（写完计划后自查，已执行）

**1. spec 覆盖**

| spec 章节 | 落在哪 |
|---|---|
| §2 D82 两入口互斥 | Task 1（含 N-lock-1 / N-lock-2、M3 / M4、G5） |
| §3 D83 三分支 + 六出口 + 两合取项 | Task 2（③⑥ + M5a/M5b/M5c/M6）+ Task 3（①② + N-lock-3/4 + M13/M14） |
| §4 D84 复盘门位置 | Task 2（第 ⑤ 步 + 双断言 + M1/M2） |
| §5 D85 内外分层 + §5.3 `rebuildRenderState` | Task 2 / Task 3 / Task 4（M12 + G1/G1b/G6） |
| §6 D86 三张表 | Task 5（显示 / 置灰 + M7/M8/P6）+ Task 6（写入 + 两个 base + M9/M10/M11/M15 + G3/G4） |
| §6.6 D87 / §6.7 D88 / §6.8 D89 | **本片不实现**（属持久化 PR，已 MERGED-pending #166）；D89 的次序约束落在 Task 7 Step 5 的 PR 横幅 |
| §7.1 正向档 P1–P7 | P1/P2 → Task 3；P3/P4/P5/P7 → Task 6；P6 → Task 5 |
| §7.2 变异表全部 | Task 1/2/3/4/5/6 分摊，Task 7 汇总进 PR 描述 |
| §7.3 不变量锁 N-lock-1..5 | Task 1（1/2）· Task 2（5）· Task 3（3/4） |
| §7.4 平台覆盖 | 15 条 host + M12 上 Catalyst（Task 4） |
| §8 源码守卫 G1/G1b/G2/G3/G4/G4b/G5/G6 | 按「守卫必须在自己 task 末尾是绿的」分派，见依赖关系 |
| §9 验收 22 条 | Task 7 Step 6（三片一起做） |
| §10.1 交接 1b-ii 撤销 PR | Task 7 Step 5 的 PR 描述第 6 条 |
| §10.2 交接 P6 | 无需动作（spec 已写死，本片不碰全局默认） |
| §11 契约影响 = 零 | Global Constraints G-1 |
| §12 override 边界 | Global Constraints G-0 + Task 7 Step 2 / Step 5 |

**2. 无占位符**：每个 code step 都有可直接粘贴的完整代码块；每个「跑一下」step 都有完整命令与**具体的预期输出**。

**3. 类型一致性**：`setCommittedSelection(id:panel:)` / `routeAndSelect(_:panel:engine:)` / `commitPendingAndSelect(panel:mapper:engine:)` / `selectedLineStyle(engine:)` / `styleFields(of:)` / `applyPanelStyleMutation(_:engine:)` 六个新符号的签名在**定义处与所有引用处逐字一致**，已逐个比对。

**4. 计划里引用的既有符号 —— 已在本支当前树（`67ce940`）上逐个实测确认**：

| 符号 | 实测结果 | 出处 |
|---|---|---|
| `Coordinator.handleDrawingTapForTesting(at: CGPoint)` | 存在，`internal` | `Render/ChartContainerView.swift:323` |
| `KLineRenderState.selectedDrawingID: DrawingID?` | 存在，`public let` | `Render/KLineRenderState.swift:28` |
| `TrainingEngine.setDrawingLocked(id:locked:) -> Bool` | 存在，`internal`，返回 `Bool`；复盘态恒返 `false`（⓪ D34） | `TrainingEngine/TrainingEngine.swift:1202` |
| `DrawingColorToken.purple` | 存在（`red/orange/yellow/green/cyan/blue/purple/black/white`） | `Models/DrawingEnums.swift:15` |
| `expectDrawingsUnchanged(_:_:revisionBefore:)` | 存在（同时比 `==`、id 序列、`drawingsRevision`） | `Tests/…/DrawingTestFixtures.swift` |
| `makeStyledHLine(...)` 的参数表（含 `locked` / `revealTick` / `period` / `candleIndex` / `price`） | 与计划中的调用逐字一致 | `Tests/…/DrawingTestFixtures.swift` |

⚠️ 实施中若发现任何一处**与上表不符**（例如上游又动过），**以当前树为准改测试，不得改生产代码去迁就测试**，并把差异报回。

**5. 计划中援引的行号一律是本支 `67ce940` 上的实测值**，不是从 spec 抄的（spec 写于持久化片落地之前，`TrainingView` 的行号已从 `517-527` 位移到 `540-547`）。实施时**以符号名定位、不要盲信行号**（[[feedback_plan_embedded_facts_unreliable]]）。
