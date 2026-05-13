# PR 7b2 — C1b Stale Drift Tests + Helper Extract + Cosmetic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Project memory `project_executing_plans_excluded` 明确：本项目只用 subagent-driven-development。每个 batch 派一个 fresh sonnet 4.6 high-effort subagent；批与批之间主线 review。

**Goal:** 补齐 spec L1159-1162 验收 #3「`staleDrawingSnapshot` 可达 3 条路径」单元测试（trade / periodCombo / offsetApplied 漂移）+ 抽出 ReducerTests.swift 内重复 9 处 `make` / 4 处 `drawingMode` 为 file-level helper（PR7b1 plan §4 R1 M-4 技术债）+ 修复 PR #48 post-impl 抓到的 2 个 L cosmetic 注释偏差（spec L1056/L1072/L1082 字面对齐）。

**Architecture:**
- prod 文件 `Reducer.swift` **只动 3 个 inline comment**，零行为变更——验收 #3 三条 stale 路径所需的 guard literal 已在 PR7b1 落地（L174-176），本 PR 是 characterization tests + cosmetic alignment，不是 TDD red→green。
- test 文件 `ReducerTests.swift` 重构 + 增 1 Suite + 既有 Suite 各加 1 test：抽 2 个 file-level helper（替换 13 处 inline copy）+ 新 `ReduceStaleDrawingSnapshotTests` Suite 含 **5 个 sequence tests**（trade spec-literal r=0 + trade nonzero-mutation-killer r=5 + periodCombo + offsetApplied auto + offsetApplied free）+ 既有 `ReduceDrawingCommittedTests` / `ReduceDrawingCancelledTests` 各加 1 个 distinguishing wrong-source mutation-killing test（**2 tests 总**）。
- 不动 §C1a Geometry、不动 M0.3 Models.swift、不动 PreviewFakes、不动 Persistence target、不动 PR7b1 已落 4 drawing case + 5 PR7a non-drawing case。
- 验收 doc 中文非-coder 可执行。

**Tech Stack:** Swift 6.0（toolchain 6.3.1）+ SwiftPM intra-package + Swift Testing macros（`@Test` / `@Suite` / `#expect`）+ `import Foundation` + `import CoreGraphics`。无新增依赖、无 `Package.swift` 改动。

**Spec 锚点：**
- 主要：`kline_trainer_modules_v1.4.md` L1146-1162（3 stale paths + 验收 #3）
- 次要：L1056（drawing/activateDrawing 注释）+ L1072（drawing/setDrawingSnapshot 注释）+ L1082（cross-session guard fall-through 注释）

**与 v6 outline 顺位关系：** v6 outline 顺位 13 = "PR 7b2: 3 漂移 + cross-session guard"。但「cross-session guard」（L1163-1166 验收 #4）在 PR7b1 R1 H-2 修订时已上移到 PR7b1 并完整落地（prod guard + 2 unmatched tests）。本 PR 接力剩余真实 scope：**3 auto stale paths + 1 free stale path（R2 medium-1） + helper 抽出 + 2 cosmetic 修**。

**承诺：** PR7b2 完成后回到 v6 outline 顺位（PR 7b3 = DecelerationAnimator 集成 / 顺位 14）。

---

## File Structure

| 文件 | 责任 | 状态 | 增量 LOC budget |
|---|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift` | 3 处 inline comment 字面对齐（L1056 / L1072 / L1082）；零行为变 | Modify | +3 / -1 净 ~+2；总 ~208（PR7b1 baseline 206） |
| `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift` | (a) 抽 file-level `makePanel` + `makeDrawingMode` 替换 9+4 inline copy；(b) 增 `ReduceStaleDrawingSnapshotTests` Suite × **5 stale tests**（3 auto spec-literal + 1 free + 1 nonzero-mutation-killer，R2 medium-1 + R6 medium-1）；(c) 往既有 `ReduceDrawingCommittedTests` / `ReduceDrawingCancelledTests` 各加 1 个 distinguishing wrong-source mutation-killing test（**2 tests 总**，R3 high-1） | Modify | 抽 helper -~51 / 加 helper +~14 / 加 stale Suite +~110 / 加 2 distinguishing tests +~30；净 ~+103；总 ~725（PR7b1 baseline 622） |
| `docs/acceptance/2026-05-13-pr7b2-stale-drift-tests-helpers-cosmetic.md` | 中文非-coder 验收清单（动作 / 预期 / 通过判定） | Create | ≤90 |

**File rationale：**
- 单 prod 文件改动延续 PR7a/7b1 单文件 bundle 模式；本 PR prod 改动比 7b1 更小（3 注释 vs 4 case literal）
- 不拆 prod 子文件：3 注释偏差是 7b1 落地遗漏，原地补齐即可；拆文件违反 simplicity-first
- 不抽测试到新文件：13 处 inline helper 抽到现有 ReducerTests.swift 文件顶部 file-level，新增 1 个 Suite 在文件尾部按既有 Suite 命名约定（`Reduce*Tests`），不破坏文件单一职责
- helper 抽到 file-level（不是某个 Suite 内部）：Swift Testing 允许 file-private function 被同文件多 struct Suite 调用，零 API 侵入

**Working directory：** worktree `feature/pr7b2-stale-drift-helpers-cosmetic`，由 `superpowers:using-git-worktrees` 在执行阶段创建（不在 plan 阶段创建）。SwiftPM root: `<worktree>/ios/Contracts/`。

**Baseline：** PR7b1 merged 后 origin/main = **258 tests in 57 suites / 0 failures / 0 warnings**（R5 medium-1 修订：suite count 从 56 改 57，实测 `swift test --package-path ios/Contracts` 输出末尾 `Test run with 258 tests in 57 suites passed`；R5 codex 静态 @Test 扫描 264 / @Suite 59 是 misleading，因为含未运行的 @Test(arguments:) 参数化展开与 disabled 计数）。PR7b2 完成后预期：
- helper 抽出：refactor only，**258 tests 全 PASS 不增不减**
- 增 5 stale tests（新 Suite `ReduceStaleDrawingSnapshotTests`：3 auto spec-literal + 1 free + 1 nonzero-mutation-killer，R6 medium-1）
- 增 2 distinguishing tests（R3 high-1：往 `ReduceDrawingCommittedTests` + `ReduceDrawingCancelledTests` 各加 1）
- 净 +7 测试 → **265 tests in 58 suites** / 0 failures / 0 warnings（baseline 57 suites + 1 新 Suite `ReduceStaleDrawingSnapshotTests` = 58；distinguishing tests 加在既有 commit/cancel Suite 内不增 suite）

**子项数（per memory feedback "硬规则 ≤3 子项 / ≤500 行 prod"）：**
1. **Batch A**：helper 抽出（refactor only；零行为变；258 tests 不增不减全 PASS）
2. **Batch B**：5 stale tests 新 Suite（3 auto + 1 free + 1 nonzero-mutation-killer，R2 medium-1 + R6 medium-1）+ 2 distinguishing tests（R3 high-1，加在既有 commit/cancel Suite）+ 3 处 prod inline comment 字面对齐（≤+3 行 prod 注释；+7 tests）
3. **Task 3**：中文非-coder 验收清单

合计 **3 子项** ✓ / prod 净增 ~+2 行（全部注释）≤500 ✓

---

## Design Decisions（plan-time 锁定，review 抓变动）

### §1 Scope 切分：PR7b2 真实 scope（v6 outline 「3 漂移 + cross-session guard」字面已部分由 PR7b1 兑现）

**v6 outline 字面 vs 实际兑现状态：**

| v6 outline 7b2 子项 | 兑现位置 | 本 PR 状态 |
|---|---|---|
| **3 stale 漂移路径单元测试**（spec L1159-1162 验收 #3 三条 auto path） | 本 PR Batch B | **本 PR 落** |
| **freeScrolling stale 单元测试**（R2 medium-1 加，spec L1059-1064 stale guard 的 freeScrolling 分支覆盖） | 本 PR Batch B | **本 PR 落** |
| **cross-session guard 单元测试**（spec L1163-1166 验收 #4） | PR7b1 R1 H-2 上移已落（10 tests 中 2 个 unmatched） | 已 done，不重复 |

**新增 scope（v6 outline 未列示，本 PR 顺手落）：**

| 新增子项 | 来源 | 理由 |
|---|---|---|
| **Helper 抽出** `make` × 9 + `drawingMode` × 4 → file-level | PR7b1 plan §4 R1 M-4 技术债 displayed | 增 Suite 前抽，避免再多 copy；refactor 在引入新测试前是干净 baseline |
| **3 prod inline comment 字面对齐** | PR #48 post-impl R1 抓的 L 注释偏差 | 单 PR 顺手修；零行为变；与 spec literal 一致后续 review 不再复抓 |

**3 选项评估（plan-time）：**

| 方案 | 优点 | 缺点 | 选/拒 |
|---|---|---|---|
| A. 仅落 3 stale tests，helper 与 cosmetic 推 PR7b3 | PR7b2 极小；scope 守 v6 outline 字面 | PR7b3 已锚 DecelerationAnimator 集成（独立大 scope）；helper 技术债再拖一 PR；cosmetic 偏差留 prod；3 stale tests 用 inline copy 会再加 ~30 行 helper duplication | ❌ 拒 |
| B. 一次落 3 stale tests + helper 抽出 + cosmetic + 顺手补 effect dispatch 集成 | 一次清完 7b2 / 7b3 残留 | effect dispatch 集成需要 mock `Effect` 派发管线、超 ~150 行；违反 ≤3 子项与 ≤500 行硬规则；与 7b3 边界蒸发 | ❌ 拒 |
| **C. 5 stale tests（3 auto spec-literal + 1 free + 1 nonzero-mutation-killer，R2 medium-1 + R6 medium-1）+ 2 distinguishing wrong-source mutation-killing tests（R3 high-1）+ helper 抽出 + 2 cosmetic comment** | 3 子项；prod 净 +2 行；refactor 与新增分批；与 PR7b3 边界清晰；trade 路径 spec literal + mutation 双守；cross-session wrong-source mutation 由 executable test + grep 双轨守 | scope 比 R2 略大（+3 tests over R2），但 PR scope 仍紧（≤500 行 prod ✓） | ✅ 选 |

**结论：选 C（R3 修订后）。**「第 3 L cosmetic」=「drawingUnmatchedKeepsSession 不能区分 guard 读 wrong source 的 mutation」，R3 codex 升级此 L 到 high，要求 executable test 而非纯 grep。Task 2.5b 加 2 distinguishing tests（`state.rev != snap.baseRev` 合成 fixture）作为主防线；acceptance §6.3 grep `guard base == snap\.frozen\.baseRevision else` 命中 commit + cancel 各 1 行 作为 belt+suspenders。三轨守备：spec literal + executable test + grep。

### §2 Helper 抽出方案：file-level `private func` 替换 13 处 copy

**当前 ReducerTests.swift 内 helper duplication（grep 实测，PR7b1 已 commit 后 baseline 622 行）：**

| Helper | 出现行号 | 出现次数 | 形态 |
|---|---|---|---|
| `make(_:rev:)` | L200, L243, L284, L324, L408, L455, L527, L570 | 8 | 2 参数（mode, rev: UInt64 = 0） |
| `make(_:rev:offset:)` | L364 | 1 | 3 参数（mode, rev: UInt64 = 0, offset: CGFloat = 0） |
| `drawingMode(baseRev:)` | L413, L460, L532, L575 | 4 | 1 参数（baseRev: UInt64 = 5） |

**抽出后 file-level helper 设计：**

```swift
// MARK: - File-level test helpers (extracted from per-Suite copies in PR7b2)

/// 构造 `PanelViewState` 的统一测试 fixture。
/// 默认 visibleCount=100、offset=0、revision=0；可覆写。
/// （PR7b2 抽自 9 个 Suite 内 copy）
private func makePanel(_ mode: ChartInteractionMode,
                       rev: UInt64 = 0,
                       offset: CGFloat = 0) -> PanelViewState {
    PanelViewState(period: .m15, interactionMode: mode,
                   visibleCount: 100, offset: offset, revision: rev)
}

/// 构造 drawing 模式 fixture（candleRange: 0..<100, offset: 0, baseRev 可调）。
/// （PR7b2 抽自 4 个 Suite 内 copy）
private func makeDrawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
    let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                  candleRange: 0..<100, baseRevision: baseRev)
    return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
}
```

**改名 rationale：**
- `make(_:rev:)` → `makePanel(_:rev:offset:)`：原名 `make` 在抽到 file-level 后语义不清（"make 什么"？），加 `Panel` 前缀绑定 `PanelViewState` 返回类型；同时合并 3-param 形态（offset 默认 0），所有 8 个 2-param callsite 不需要改参数列表
- `drawingMode(baseRev:)` → `makeDrawingMode(baseRev:)`：统一 `make*` 前缀；返回 `ChartInteractionMode` 名义清晰
- 不命名为 `panel(_:rev:)` / `drawingMode(_:)`：避免与潜在 future API 名冲突；test helper 用动词式（make...）

**Swift visibility 校验：** Swift Testing 的 `@Suite` 注解 struct 与 file-level `private func` 在同一文件内可互相调用——`private` scope = file。零 API 侵入。

**callsite 替换：** 9 处 `make(...)` callsite 改为 `makePanel(...)`；4 处 `drawingMode(...)` callsite 改为 `makeDrawingMode(...)`。所有 8 个 Suite 内的 `private func make` / `private func drawingMode` 整段删除。

**LOC delta（Batch A 实测预估）：**
- 删 9 处 `make` × ~3 行 = -27（含 `func`/`return`/`}`）
- 删 4 处 `drawingMode` × ~6 行 = -24
- 加 2 file-level helper（含 MARK 注释）= +14
- 9 处 `make(...)` callsite 改 `makePanel(...)` 名 = 0 行差（仅函数名 rename）
- 4 处 `drawingMode(...)` callsite 改 `makeDrawingMode(...)` 名 = 0 行差
- **净 -37 行**；总 622 → ~585

> 注：净 -51 来自 Batch A refactor only；Batch B 加 1 stale Suite × 5 tests +~110 + 既有 Suite 加 2 distinguishing tests +~30 + helper 加 +~14 = 全 PR 净 ~+103（File Structure 表数字一致）。

### §3 5 stale paths：sequence tests 设计（spec L1159-1162 字面 + R2 medium-1 freeScrolling + R6 medium-1 nonzero-mutation-killer）

**Spec L1159-1162 字面（reproduced for plan-time 校对）：**

> 1. activateDrawing（r=0）→ tradeTriggered（r=1）→ setDrawingSnapshot(baseRev:0) → 断言 `.staleDrawingSnapshot(expected:0, actual:1)` + mode=autoTracking
> 2. activateDrawing（r=0）→ periodComboSwitched（r=1, clearPendingDrawing）→ setDrawingSnapshot(baseRev:0) → 同上
> 3. **offsetApplied 漂移**（闸门 #5 新增）：activateDrawing（r=0）→ offsetApplied(delta) 在 autoTracking 模式下（r=1）→ setDrawingSnapshot(baseRev:0) → 同上

**测试结构：** 3 个 `@Test`，单 Suite `ReduceStaleDrawingSnapshotTests`，每个 test 是三步 reduce sequence。命名延续 PR7a/7b1 `Reduce<Action>Tests` 约定（这里没有单一 action，按 *维度* 命名 `ReduceStaleDrawingSnapshotTests`）。

**5 path 设计（详细，R1 medium-2 + R6 medium-1 修订：trade 拆 spec-literal r=0 + 姊妹 nonzero-mutation-killer；R2 medium-1 加 freeScrolling stale）：**

| Path | 步骤 | 关键断言 |
|---|---|---|
| **trade 漂移**（spec literal r=0→r=1，R6 medium-1 修订保留） | `var s = makePanel(.autoTracking, rev: 0)` → `_ = s.reduce(.activateDrawing(.ray))` → `_ = s.reduce(.tradeTriggered)` → `let eff = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 0, candleRange: 0..<100))` | `eff == .staleDrawingSnapshot(expected:0, actual:1)` + `s.interactionMode == .autoTracking` + `s.revision == 1` |
| **trade 漂移 nonzero baseline**（R1 medium-2 mutation killer，R6 medium-1 拆为姊妹 test） | `var s = makePanel(.autoTracking, rev: 5)` → activateDrawing → tradeTriggered → setDrawingSnapshot(baseRev:5) | `eff == .staleDrawingSnapshot(expected:5, actual:6)` + `s.interactionMode == .autoTracking` + `s.revision == 6` |
| **periodCombo 漂移** | `var s = makePanel(.autoTracking, rev: 0)` → activateDrawing → periodComboSwitched (returns `.clearPendingDrawing`) → setDrawingSnapshot(baseRev:0) | `eff == .staleDrawingSnapshot(expected:0, actual:1)` + `s.interactionMode == .autoTracking` + `s.revision == 1` |
| **offsetApplied 漂移**（autoTracking） | `var s = makePanel(.autoTracking, rev: 0)` → activateDrawing → `offsetApplied(deltaPixels: 3)`（offset 0→3, rev 0→1）→ setDrawingSnapshot(baseRev:0) | 同上 + `s.offset == 3` 守 offset 累加副作用 |
| **freeScrolling 漂移**（offsetApplied，R2 medium-1 新增）| `var s = makePanel(.freeScrolling, rev: 0)` → activateDrawing → `offsetApplied(deltaPixels: 3)`（offset 0→3, rev 0→1，mode 保 freeScrolling）→ setDrawingSnapshot(baseRev:0) | `eff == .staleDrawingSnapshot(expected:0, actual:1)` + `s.interactionMode == .freeScrolling`（未进 drawing 也未掉 autoTracking）+ `s.revision == 1` + `s.offset == 3` |

**trade 路径 spec-literal + mutation 双守（R6 medium-1 修订）：** R1 medium-2 提出「3 path 全 baseRev=0、actual=1 造成 mutation 盲区」，原方案是把 tradeDrift 起点改 `rev: 5`。R6 medium-1 抓出此修订丢失 spec L1148/L1160 字面 r=0→r=1 boundary case（守 prod「revision==0 sentinel 错把 tradeTriggered 漂移当 no-op」回归）。R6 修订：trade 路径拆 2 个姊妹 test——`tradeDrift` 守 spec literal（rev=0→1），`tradeDriftNonZeroBaseline` 守 mutation gap（rev=5→6）。periodComboDrift / offsetAppliedDrift / freeScrollingOffsetAppliedDrift 仍用 rev=0 提供 spec L1159-1162 字面文档参照（spec 写「r=0 → r=1」）。5 path 总和：1 个 spec-literal trade + 1 个 nonzero-mutation-killer trade + 1 个 spec-literal periodCombo + 1 个 spec-literal offsetApplied auto + 1 个 freeScrolling stale。

**为什么不全部用非零：** spec L1159-1162 字面写 `r=0 → r=1`；5 path 全改非零会让 plan-to-spec 字面对照度下降（reviewer 复审验收 #3 时无法直接 grep `r=0 → r=1`）；非零仅 1 path 守 mutation gap、其余守 spec 字面 → 两个目标兼顾。

**为什么加 4th path freeScrolling（R2 medium-1 修订）：** R2 codex 抓出 spec L1059-1064 字面 stale guard 覆盖 `(.autoTracking, .setDrawingSnapshot)` + `(.freeScrolling, .setDrawingSnapshot)` 两个 mode，原 3 path 全在 autoTracking 起步；freeScrolling 路径的 stale guard 行为未被任何 unit test 覆盖（PR7b1 既有 `ReduceSetDrawingSnapshotTests.freeMatchedEntersDrawing` 只测 matched 路径）。回归风险：若 prod stale guard 错把 freeScrolling 分支跳出（例：写 `case (.autoTracking, .setDrawingSnapshot(...))` 单 case + `case (.freeScrolling, .setDrawingSnapshot): return .none`），freeScrolling stale 全静默通过。4th path 起点 `.freeScrolling` 关闭此回归窗口。选 offsetApplied 漂移路径（不选 tradeTriggered/periodCombo 漂移路径）：tradeTriggered/periodComboSwitched 都会硬切 autoTracking，从 freeScrolling 起步中间 step 后已不在 freeScrolling，与「freeScrolling-stale」语义不符；offsetApplied 在 freeScrolling 上是吞 + bump（不切 mode），中间 step 后仍是 freeScrolling，可同时验证 `interactionMode == .freeScrolling`（mode 未漂）+ stale。

**为什么 effect dispatch 不在本 PR：** spec L1167 验收 #5「Deceleration stop 契约测试」属 PR7b3 scope；本 PR 只测 reducer 内 stale guard 行为，不涉及 effect handler 真派发（reducer 单元测试只验证 reducer 返回的 `ChartReduceEffect` 值，不验证 effect 是否被 dispatch）。

**Distinguishing fixture（沿用 PR7b1 R1 H-3 模式）：**
- 起点 fixture `makePanel(.autoTracking, rev: 0|5)` 默认 offset=0；offsetApplied path test 用 `deltaPixels: 3` 明确观察 offset 累加（distinguishing from 0 → 0 false-pass）
- `setDrawingSnapshot` candleRange 用 `0..<100` 与 fixture frozen `candleRange` 一致（drawing 模式从未进入 → 这里 candleRange 是无效 stale 参数，但必须语法合法）

### §4 Prod 3 inline comment 字面对齐（spec literal patch）

**3 注释偏差（PR #48 post-impl review 抓）：**

| # | Spec 位置 | 当前 prod（PR7b1 落） | 应改为（spec literal） |
|---|---|---|---|
| 1 | L1056 | `case (.drawing, .activateDrawing):\n    return .none` | `case (.drawing, .activateDrawing):\n    return .none  // 切换工具由 DrawingToolManager 处理` |
| 2 | L1072 | `case (.drawing, .setDrawingSnapshot):\n    return .none` | `case (.drawing, .setDrawingSnapshot):\n    return .none  // drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing` |
| 3 | L1082 | `guard base == snap.frozen.baseRevision else {\n    return .none  // 旧 session 遗留 action，丢弃保持当前 drawing\n}`（注释在 return 后 inline） | `guard base == snap.frozen.baseRevision else {\n    // 来自上一轮 session 的延迟 action，忽略\n    return .none\n}`（注释在 return 前，spec 字面）|

**约束：**
- 3 注释字面与 spec L1056 / L1072 / L1082 **逐字符**一致（含 ASCII 中文标点）
- 第 3 项需把 drawingCancelled 分支（prod L194-198）**同步**改成 spec L1088-1090 字面（spec 在 commit 分支后只剩 `guard base == snap.frozen.baseRevision else { return .none }` 单行无注释，符合 spec L1087-1092 字面；cancel 分支与 spec L1087-1092 已一致，不动）

**验证：** Batch B 内 grep 命令验证（acceptance §6 同步加 3 条 inline comment 字面 grep）。

### §5 LOC 预算硬规则核对

| 维度 | 数字 | 限额 | 状态 |
|---|---|---|---|
| 子任务数 | 3（Batch A / Batch B / Task 3）| ≤3 | ✓ |
| Prod 净增 LOC | ~+2（3 注释 inline；Batch B 内）| ≤500 | ✓ |
| Test 净增 LOC | ~+12（Batch A 抽 helper 净 -37 + Batch B 加 Suite +~70 = +~33；保守上调 +12 净估）| 软上限 1000 | ✓ |
| 新文件 | 1 acceptance doc（≤90 行） | 软无限 | ✓ |
| 触及 prod 文件数 | 1（Reducer.swift） | 推荐 ≤3 | ✓ |
| 触及 test 文件数 | 1（ReducerTests.swift） | 推荐 ≤3 | ✓ |
| 新依赖 | 0 | 无 | ✓ |
| 新 SwiftPM target | 0 | 无 | ✓ |

### §6 TDD discipline（characterization tests + refactor，非典型 red→green）

**本 PR 不是经典 TDD red→green：**
- prod stale guard literal 已在 PR7b1 落地（Reducer.swift L172-176）→ 本 PR 写 5 stale tests 期望 PASS（不是 RED）
- Helper 抽出是纯 refactor → 抽前 258 PASS、抽后 258 PASS（不是 RED）

**对应纪律调整：**
- **Batch A（helper 抽）**：refactor-loop = run baseline → refactor → run again → 比对 PASS 数不变 → commit。任何测试在 refactor 后 FAIL = bug，须修；不允许"refactor 改测试断言"
- **Batch B（stale tests + cosmetic）**：characterization-loop = write tests（期望 PASS 直接）→ run → 真 PASS → commit。若任意 stale test FAIL = prod stale guard literal 与 spec L1062-1064 已偏离（PR7b1 落地错），属于 stop-the-line 信号需立即上报，不允许"改 test 期望迁就 prod"
- **mutation 校验（plan-time，非自动测试）**：Batch B 内 plan-time 心算：若 prod L174 改成 `guard baseRev == 0` 是否 trade test FAIL？是（actual=1 != 0 也走 stale，但 mode=autoTracking 仍 PASS……）——见 §6 mutation 注

**§6 mutation 注（R1 medium-2 修订后）：** R1 codex 抓出原 plan 3 path 全用 `baseRev:0 → actual:1` 形成 mutation 盲区——`guard baseRev != 0` 常量 guard 错改 prod 后 3 path 全仍 PASS（因 baseRev 永远 0、actual 永远 1）。

**修订后（R6 medium-1 最终方案）**：trade 路径拆 2 个姊妹 test——`tradeDrift` 守 spec literal r=0→r=1（与 spec L1148/L1160 字面对应），`tradeDriftNonZeroBaseline` 起点 rev=5（drift 后 `expected:5, actual:6`）守 mutation gap。`tradeDriftNonZeroBaseline` 能抓 `guard baseRev != 0` 常量 mutation——mutation 在 baseRev=5 时返回 `5 != 0 = true` → guard 失败 → 进 drawing mode，姊妹 test 期望 `.staleDrawingSnapshot` + mode=autoTracking → FAIL。periodComboDrift / offsetAppliedDrift / freeScrollingOffsetAppliedDrift 仍用 `rev: 0`（守 spec L1159-1162 字面文档对照度）。

acceptance §6 grep `guard baseRev == revision else` 字面守备仍保留作为 belt+suspenders（守 mutation 写成 `guard baseRev <= revision` 这种 partial-correct 常数关系的盲区）。

---

## Tasks

> Discipline: Batch A = refactor (test PASS 数不变即 GREEN)；Batch B = characterization tests（write 后期望直接 PASS）+ prod 注释 patch（零行为变）。每 batch 内最后一步 commit。

---

### Task 1 (Batch A): Helper 抽出 — refactor only

**Files:**
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift`（抽 9 处 `make` + 4 处 `drawingMode` → 2 个 file-level helper）

#### Step 1.1: 记录 baseline 测试数

- [ ] 运行：

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

预期：`Test run with 258 tests in 57 suites passed` / `0 failures` / `0 warnings`。**记录此 baseline 数字（tests 与 suites 都记）**——本数字是 PR7b2 全程的"源真相"，后续所有 +6 / +1 (suite) 计算都以此为基准。

**偏差处理：**
- 若实测 `tests` != 258 或 `suites` != 57：表示 baseline 已漂（可能是新 merge / 本地未 fetch）；**stop the line**，问 user 是否 fetch origin/main 或确认新 baseline，再决定是否 patch plan 的 258/57 → 新数字（用 sed/Edit 全文替换）。
- 若 `failures` != 0 或 `warnings` != 0：baseline 已脏；同样 stop，先修脏 baseline 再继续 PR7b2。

**注（R5 medium-1 修订）：** R5 codex 静态扫描 `@Test` 264 与 `@Suite` 59 是 misleading——实际 runtime 跑 258/57，差异来自 disabled / 参数化 `@Test(arguments:)`。**只信 swift test runner 输出，不信 grep `@Test` 行数。**

#### Step 1.2: 在文件顶部 (import 块后、`// MARK: - PanelViewState` 前) 加 2 个 file-level helper

- [ ] 在 `ReducerTests.swift` L12（`@testable import KlineTrainerContracts` 后）加：

```swift

// MARK: - File-level test helpers (extracted in PR7b2 from per-Suite copies)

/// 构造 `PanelViewState` 的统一测试 fixture。
/// 默认 visibleCount=100、offset=0、revision=0；可覆写。
/// PR7b2 抽自 9 个 Suite 内 `private func make` copy（PR7b1 plan §4 R1 M-4 技术债）。
private func makePanel(_ mode: ChartInteractionMode,
                       rev: UInt64 = 0,
                       offset: CGFloat = 0) -> PanelViewState {
    PanelViewState(period: .m15, interactionMode: mode,
                   visibleCount: 100, offset: offset, revision: rev)
}

/// 构造 drawing 模式 fixture（candleRange: 0..<100, offset: 0, baseRev 可调）。
/// PR7b2 抽自 4 个 Suite 内 `private func drawingMode` copy。
private func makeDrawingMode(baseRev: UInt64 = 5) -> ChartInteractionMode {
    let frozen = FrozenPanelState(period: .m15, visibleCount: 100, offset: 0,
                                  candleRange: 0..<100, baseRevision: baseRev)
    return .drawing(snapshot: DrawingSnapshot(frozen: frozen))
}

```

> 注：新 helper 块之前/之后各留 1 空行，与现有 `// MARK:` 块间距风格一致。

#### Step 1.3: 删除 9 处 per-Suite `private func make` copy

按以下行号（PR7b1 baseline 622 行内）逐 Suite 删除对应的 `private func make...` 块（含 `{` 行、`PanelViewState(...)` 行、`}` 行；通常 3-4 行）：

- [ ] L200-203（`ReducePanStartedTests`）
- [ ] L243-246（`ReducePanEndedTests`）
- [ ] L284-287（`ReduceTradeTriggeredTests`）
- [ ] L324-327（`ReducePeriodComboTests`）
- [ ] L364-367（`ReduceOffsetAppliedTests`；这一个是 3-param 形态）
- [ ] L408-411（`ReduceActivateDrawingTests`）
- [ ] L455-458（`ReduceSetDrawingSnapshotTests`）
- [ ] L527-530（`ReduceDrawingCommittedTests`）
- [ ] L570-573（`ReduceDrawingCancelledTests`）

> 行号是 plan-time 估算（PR7b1 merged 后 baseline）；实际删除时按 grep 命中而非死行号：`grep -n 'private func make(_ mode' ReducerTests.swift` 应返回 9 行（删前）→ 0 行（删后）。

#### Step 1.4: 删除 4 处 per-Suite `private func drawingMode` copy

按以下行号（PR7b1 baseline）：

- [ ] L413-418（`ReduceActivateDrawingTests`）
- [ ] L460-465（`ReduceSetDrawingSnapshotTests`）
- [ ] L532-537（`ReduceDrawingCommittedTests`）
- [ ] L575-580（`ReduceDrawingCancelledTests`）

> 同上：实际按 `grep -n 'private func drawingMode' ReducerTests.swift` 应返回 4 行（删前）→ 0 行（删后）。

#### Step 1.5: 全文 `make(...)` callsite rename 到 `makePanel(...)`

- [ ] 全文搜索 `var s = make(.` 和 `var s = make(drawingMode(` 形式，逐处改 `make` → `makePanel`、`drawingMode(` → `makeDrawingMode(`。

> 注：所有原 `make(_ mode:rev:offset:)` callsite 参数列表保持不变（新 helper 的 3 参数中 offset 默认 0，2-param 形式向后兼容）。

具体 sed 不可用（中文注释 + Swift 多行结构），按以下命令辅助核对：

```bash
# 应返回 0（删后）
grep -c 'var s = make(\.\|var s = make(drawingMode(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# 应返回非零（全文应有同等数量的 makePanel 调用）
grep -c 'var s = makePanel(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# 应返回非零（drawingMode 单独调用：Suite 内构造 drawing 模式 fixture）
grep -c 'makeDrawingMode(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# 应返回 0：无残留 inline helper definition
grep -cE 'private func (make|drawingMode)\(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# 应返回 2：唯一 2 个 file-level helper
grep -cE 'private func (makePanel|makeDrawingMode)\(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
```

#### Step 1.6: 跑测试 — 258/258 GREEN

- [ ] 运行：

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

预期：`Test run with 258 tests in 57 suites passed` / `0 failures` / `0 warnings`。**与 Step 1.1 baseline 完全一致**（tests + suites 数量、warnings、failures）。

判定：任一偏差表示 refactor 引入 bug 或新警告 → stop the line 不进 commit。

#### Step 1.7: Commit Batch A

- [ ] 

```bash
git add ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
git commit -m "refactor(PR7b2): 抽 ReducerTests helper 到 file-level

抽出 ReducerTests.swift 内重复 9 处 \`make\` + 4 处 \`drawingMode\` inline copy
为 2 个 file-level \`private func\`（PR7b1 plan §4 R1 M-4 技术债）：
- \`makePanel(_:rev:offset:)\` 替换原 9 处 \`make\` copy（含 3-param 形态）
- \`makeDrawingMode(baseRev:)\` 替换原 4 处 \`drawingMode\` copy

零行为变：258 tests / 0 failures / 0 warnings 与 baseline 完全一致。
LOC 净 -37（删 13 copy 加 2 file-level helper + MARK 块）。

下一 Batch：5 stale 路径 characterization tests + 2 distinguishing tests + 3 prod inline comment
字面对齐。"
```

---

### Task 2 (Batch B): 5 stale tests + 2 distinguishing tests + 3 prod inline comment 字面对齐

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift`（3 inline comment 字面对齐 spec L1056 / L1072 / L1082）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift`（增 `ReduceStaleDrawingSnapshotTests` Suite × 5 stale tests + 往既有 `ReduceDrawingCommittedTests` / `ReduceDrawingCancelledTests` 各加 1 个 distinguishing test）

#### Step 2.1: 修 prod inline comment — L1056（drawing/activateDrawing）

- [ ] 修改 `Reducer.swift`：定位 PR7b1 落的（约 L168-169）

```swift
        case (.drawing, .activateDrawing):
            return .none
```

改为：

```swift
        case (.drawing, .activateDrawing):
            return .none  // 切换工具由 DrawingToolManager 处理
```

#### Step 2.2: 修 prod inline comment — L1072（drawing/setDrawingSnapshot）

- [ ] 修改 `Reducer.swift`：定位 PR7b1 落的（约 L183-184）

```swift
        case (.drawing, .setDrawingSnapshot):
            return .none
```

改为：

```swift
        case (.drawing, .setDrawingSnapshot):
            return .none  // drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing
```

#### Step 2.3: 修 prod inline comment — L1082（drawingCommitted guard fall-through）

- [ ] 修改 `Reducer.swift`：定位 PR7b1 落的（约 L187-190）

```swift
        case (.drawing(let snap), .drawingCommitted(let base)):
            guard base == snap.frozen.baseRevision else {
                return .none  // 旧 session 遗留 action，丢弃保持当前 drawing
            }
            interactionMode = .autoTracking
            return .none
```

改为（注释位置从 return 行后 inline 移到 return 前，wording 改 spec L1082 字面）：

```swift
        case (.drawing(let snap), .drawingCommitted(let base)):
            guard base == snap.frozen.baseRevision else {
                // 来自上一轮 session 的延迟 action，忽略
                return .none
            }
            interactionMode = .autoTracking
            return .none
```

> 注：`drawingCancelled` 分支（约 L193-198）spec L1087-1092 字面已无注释，本 step 不动。

#### Step 2.4: 跑全包 — 258 GREEN（注释改不影响行为）

- [ ] 运行：

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

预期：`258 tests / 0 failures / 0 warnings`。任何偏差 = 改注释时误改代码，stop。

#### Step 2.5: 写 5 stale tests — `ReduceStaleDrawingSnapshotTests` Suite

- [ ] 在 `ReducerTests.swift` 末尾（`@Suite("revision UInt64 overflow")` 之前）插入：

```swift
// MARK: - reduce: 5 stale drift paths (spec L1146-1162 验收 #3 + R2 freeScrolling 补 + R6 trade nonzero baseline 拆姊妹 test)
// Characterization tests: prod stale guard literal 在 PR7b1 已落（Reducer.swift L174-176）；
// 本 Suite 验证 3 条 spec 字面 sequence path（trade / periodCombo / offsetApplied 漂移）
// 在 reducer 内端到端可达，stale guard 真返回 .staleDrawingSnapshot。

@Suite("reduce stale drift paths")
struct ReduceStaleDrawingSnapshotTests {

    @Test("trade 漂移 (spec literal r=0→1): activateDrawing(r=0) → tradeTriggered(r=1) → setDrawingSnapshot(baseRev:0) → stale")
    func tradeDrift() {
        // R6 medium-1 修订：保留 spec L1148/L1160 字面 r=0→r=1 trade path（守 r=0 boundary case，
        // 防 "revision==0 sentinel 错把 tradeTriggered 漂移当成 no-op"回归窗口）。
        // R1 medium-2 提出的 nonzero mutation-killing 拆到独立 `tradeDriftNonZeroBaseline` test（下方），
        // 两个 test 分担：本 test 守 spec literal、姊妹 test 守 mutation gap。
        var s = makePanel(.autoTracking, rev: 0)

        // Step 1: activateDrawing — 不 bump revision，mode 不变
        let eff1 = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 0))

        // Step 2: tradeTriggered 漂移 — revision bump 到 1，mode 保持 autoTracking
        let eff2 = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff2 == .none)

        // Step 3: setDrawingSnapshot(baseRev=0) handler 回推 — revision 已漂到 1
        // → reducer 守 stale guard 返回 .staleDrawingSnapshot；mode 保持 autoTracking（未进 drawing）
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }

    @Test("trade 漂移 (nonzero baseline, mutation killer): activateDrawing(r=5) → tradeTriggered(r=6) → setDrawingSnapshot(baseRev:5) → stale")
    func tradeDriftNonZeroBaseline() {
        // R1 medium-2 + R6 medium-1 修订：与 `tradeDrift` (r=0) 互补的姊妹 test，起点 rev=5。
        // 抓 mutation `guard baseRev != 0` 常量 guard 错改：mutation 在 baseRev=5 时 false（5 != 0 = true
        // → guard 失败 → 不返回 stale → 进 drawing mode），test FAIL → mutation 被抓。
        var s = makePanel(.autoTracking, rev: 5)

        let eff1 = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 5)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 5))

        let eff2 = s.reduce(.tradeTriggered)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff2 == .none)

        let eff3 = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 5, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 6)
        #expect(eff3 == .staleDrawingSnapshot(expected: 5, actual: 6))
    }

    @Test("periodCombo 漂移: activateDrawing(r=0) → periodComboSwitched(r=1, .clearPendingDrawing) → setDrawingSnapshot(baseRev:0) → stale")
    func periodComboDrift() {
        var s = makePanel(.autoTracking, rev: 0)

        // Step 1: activateDrawing
        let eff1 = s.reduce(.activateDrawing(.trend))
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .trend, baseRevision: 0))

        // Step 2: periodComboSwitched 漂移 — bump + .clearPendingDrawing
        let eff2 = s.reduce(.periodComboSwitched)
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff2 == .clearPendingDrawing)

        // Step 3: setDrawingSnapshot(baseRev=0) → stale
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .trend, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }

    @Test("offsetApplied 漂移 (autoTracking): activateDrawing(r=0) → offsetApplied(delta=3, autoTracking, r=1) → setDrawingSnapshot(baseRev:0) → stale")
    func offsetAppliedDrift() {
        // 闸门 #5 新增路径：handler 计算 candleRange 期间发生 .offsetApplied（手势 / deceleration 余震），
        // mode 仍是 autoTracking → revision bump → setDrawingSnapshot 回推已 stale
        var s = makePanel(.autoTracking, rev: 0)

        // Step 1: activateDrawing
        let eff1 = s.reduce(.activateDrawing(.horizontal))
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .horizontal, baseRevision: 0))

        // Step 2: offsetApplied 漂移 — offset 累加 + bump
        let eff2 = s.reduce(.offsetApplied(deltaPixels: 3))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.offset == 3)
        #expect(s.revision == 1)
        #expect(eff2 == .none)

        // Step 3: setDrawingSnapshot(baseRev=0) → stale
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .horizontal, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .autoTracking)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }

    @Test("freeScrolling 漂移 (offsetApplied): activateDrawing(r=0, free) → offsetApplied(delta=3, free, r=1) → setDrawingSnapshot(baseRev:0) → stale + mode 保 free")
    func freeScrollingOffsetAppliedDrift() {
        // R2 medium-1 修订：覆盖 spec L1059-1064 stale guard 的 freeScrolling 分支；
        // 关闭 prod 错写「auto 单 case + free 单走 .none」回归窗口。
        // 选 offsetApplied（非 trade/period）：spec L1098-1102 / L1104-1108 trade/period
        // 会硬切 autoTracking，中间 step 后 mode 已不在 freeScrolling；offsetApplied 在
        // freeScrolling 上吞 + bump（不切 mode），mode 全程保 freeScrolling。
        var s = makePanel(.freeScrolling, rev: 0)

        // Step 1: activateDrawing — 不 bump revision，mode 保 freeScrolling
        let eff1 = s.reduce(.activateDrawing(.ray))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 0)
        #expect(eff1 == .requestDrawingSnapshotAfterStoppingAnimator(tool: .ray, baseRevision: 0))

        // Step 2: offsetApplied 漂移 — offset 累加 + bump；mode 保 freeScrolling
        let eff2 = s.reduce(.offsetApplied(deltaPixels: 3))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.offset == 3)
        #expect(s.revision == 1)
        #expect(eff2 == .none)

        // Step 3: setDrawingSnapshot(baseRev=0) → stale；mode 保 freeScrolling（未进 drawing 也未掉 auto）
        let eff3 = s.reduce(.setDrawingSnapshot(tool: .ray, baseRevision: 0, candleRange: 0..<100))
        #expect(s.interactionMode == .freeScrolling)
        #expect(s.revision == 1)
        #expect(eff3 == .staleDrawingSnapshot(expected: 0, actual: 1))
    }
}
```

> 注：本 Suite **不需要**任何 per-Suite helper（fixture 全部用 file-level `makePanel`）。`makeDrawingMode` 在本 Suite 不需要——5 stale path 不进 drawing 模式（4 个 autoTracking 起步：trade r=0 + trade r=5 + periodCombo + offsetApplied + 1 个 freeScrolling 起步）。

#### Step 2.5b: 加 2 个 distinguishing wrong-source mutation-killing tests（R3 high-1 修订）

R3 codex 抓出 PR7b1 既有 `drawingUnmatchedKeepsSession` (commit + cancel) 使用 `state.rev == snap.baseRev` fixture，不能区分 prod guard 读 `snap.frozen.baseRevision` 还是 `revision`——mutation `guard base == revision` 会让 unmatched test 误通过（因 `base != state.rev == snap.baseRev` 形态下 `base == revision` 与 `base == snap.baseRev` 等价）。

修订：往 `ReduceDrawingCommittedTests` 和 `ReduceDrawingCancelledTests` 各加 1 个 distinguishing fixture test（`state.rev != snap.baseRev` 合成 fixture）。

**注**：`state.revision != snap.frozen.baseRevision` 是 *合成* fixture——真实业务流程不会触达此状态（spec L1153：drawing 模式内任何 action 都不 bump revision；进入 drawing 时 `snap.frozen.baseRevision` 由 `freeze()` 复制当前 `revision`）。但 mutation testing 的目的是暴露 wrong-source 误改，此 fixture 是必要的工程手段；测试注释里明确标注。

- [ ] 在 `ReduceDrawingCommittedTests` Suite 内（已有 `drawingMatchedExits` + `drawingUnmatchedKeepsSession` 之后）插入：

```swift
    @Test("drawing(snap.baseRev=5) + state.rev=99 + drawingCommitted(base=99) → guard 读 snap.baseRev 而非 state.rev → mode 不变 + .none")
    func drawingCommittedReadsSnapshotNotRevision() {
        // R3 high-1 修订：distinguishing fixture where state.revision != snap.frozen.baseRevision。
        // 守 prod guard literal `guard base == snap.frozen.baseRevision`：
        //   - 真 guard: base(99) == snap.baseRev(5) → false → guard 失败 → return .none → mode 保 drawing ✓
        //   - mutation `guard base == revision`: base(99) == state.rev(99) → true → guard 通过 → 退出 drawing ✗
        // 此 fixture 合成（drawing 模式内 revision 不会被 bump，真实流程触达不到 state.rev != snap.baseRev），
        // 但 mutation testing 需要此 fixture 暴露 wrong-source 误改。
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 99)
        let eff = s.reduce(.drawingCommitted(baseRevision: 99))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged (wrong-source mutation would exit drawing)")
            return
        }
        #expect(snap.frozen.baseRevision == 5)  // snap 不变
        #expect(s.revision == 99)                // state.rev 不变
        #expect(eff == .none)
    }
```

- [ ] 在 `ReduceDrawingCancelledTests` Suite 内（已有 `drawingMatchedExits` + `drawingUnmatchedKeepsSession` 之后）插入镜像测试：

```swift
    @Test("drawing(snap.baseRev=5) + state.rev=99 + drawingCancelled(base=99) → guard 读 snap.baseRev 而非 state.rev → mode 不变 + .none")
    func drawingCancelledReadsSnapshotNotRevision() {
        // R3 high-1 修订（mirror committed）：distinguishing fixture state.revision != snap.frozen.baseRevision。
        // 守 cancel 分支 prod guard 同样读 snap.frozen.baseRevision；mutation 同上抓。
        var s = makePanel(makeDrawingMode(baseRev: 5), rev: 99)
        let eff = s.reduce(.drawingCancelled(baseRevision: 99))
        guard case .drawing(let snap) = s.interactionMode else {
            Issue.record("expected drawing mode unchanged (wrong-source mutation would exit drawing)")
            return
        }
        #expect(snap.frozen.baseRevision == 5)
        #expect(s.revision == 99)
        #expect(eff == .none)
    }
```

> **scope 调整：** §1 选项 C 原说「第 3 L cosmetic 不补 unit test」；R3 codex 升级此 L 到 high（grep 不是 behavioral gate）；本 step 加 2 distinguishing tests 后该 L 由 *executable test + grep* 双轨守，比单 grep 强。Self-Review §1 表 + §1 option C 描述同步修订。

#### Step 2.6: 跑全包 — 265 GREEN（5 stale + 2 distinguishing tests 期望直接 PASS）

- [ ] 运行：

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

预期：`Test run with 265 tests in 58 suites passed` / `0 failures` / `0 warnings`。

判定：相对 Step 1.1 baseline 净 +7 tests + 1 suite；5 stale tests 直接 PASS = prod stale guard literal 与 spec L1059-1064 一致（auto + free 两 mode 分支）+ trade 路径双重覆盖（spec literal r=0→1 + mutation killer r=5→6）；2 distinguishing tests 直接 PASS = prod cross-session guard 读 `snap.frozen.baseRevision`（非 `revision`）一致；任意 FAIL = stop-the-line（不允许"改 test 期望迁就 prod"）。

#### Step 2.7: 单跑新 Suite + distinguishing tests — 7/7 PASS

- [ ] 运行（新 stale Suite 5 + 2 个 distinguishing tests = 7 个）：

```bash
swift test --package-path ios/Contracts \
    --filter "ReduceStaleDrawingSnapshotTests|drawingCommittedReadsSnapshotNotRevision|drawingCancelledReadsSnapshotNotRevision" 2>&1 | tail -10
```

预期：`Test run with 7 tests passed`（stale Suite 5 + distinguishing 2）。这是相对 Step 1.1 baseline 的 +7 增量在 filter scope 内的明确证据，不受 baseline 漂移影响。

#### Step 2.8: Lint check — prod 注释字面与 spec 一致

- [ ] 运行（5 条 grep 应全部命中）：

```bash
# §6.1: spec L1056 inline comment
grep -nF '// 切换工具由 DrawingToolManager 处理' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.2: spec L1072 inline comment
grep -nF '// drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.3: spec L1082 cross-session guard 注释（注意在 return 前，不在 return inline 后）
grep -nF '// 来自上一轮 session 的延迟 action，忽略' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.4: 旧 PR7b1 wording 已删
grep -cF '// 旧 session 遗留 action，丢弃保持当前 drawing' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.5: prod stale guard 字面（守住 §6 mutation 注 belt+suspenders）
grep -nE 'guard baseRev == revision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.6: prod cross-session guard 字面（R2 medium-2 修订：守第 3 L cosmetic mutation 盲区 belt+suspenders；
#        Task 2.3 修改了 L1082 注释紧邻 drawingCommitted 分支，必须双 grep 守 commit+cancel 两处都未被
#        误改为 wrong-source 形式如 `guard base == revision`）
grep -cE 'guard base == snap\.frozen\.baseRevision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

预期：
- §6.1 命中 1 行
- §6.2 命中 1 行
- §6.3 命中 1 行
- §6.4 返回 0（旧 wording 已删）
- §6.5 命中 1 行
- §6.6 返回 2（drawingCommitted + drawingCancelled 各 1 行，不允许 0/1/3+）

#### Step 2.9: Commit Batch B

- [ ] 

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
git commit -m "feat(PR7b2): 5 stale drift tests + 2 distinguishing tests + 3 prod inline comment 字面对齐

spec L1146-1162 验收 #3 三条 staleDrawingSnapshot 可达路径单元测试 + R2
medium-1 加 freeScrolling stale 路径（characterization tests，prod stale
guard 字面在 PR7b1 已落）：
- trade 漂移 (R1 nonzero): activateDrawing(r=5) → tradeTriggered(r=6) → setDrawingSnapshot(5)
- periodCombo 漂移: activateDrawing(r=0) → periodComboSwitched(r=1) → setDrawingSnapshot(0)
- offsetApplied 漂移 (auto): activateDrawing(r=0) → offsetApplied(delta=3) → setDrawingSnapshot(0)
- freeScrolling 漂移 (R2 medium-1): activateDrawing(r=0, free) → offsetApplied(delta=3, free) → setDrawingSnapshot(0)
auto path 断言 mode=autoTracking；free path 断言 mode=freeScrolling（未掉 auto 也未进 drawing）。

Reducer.swift 3 处 inline comment 字面对齐 spec：
- L1056: case (.drawing, .activateDrawing) 注释「切换工具由 DrawingToolManager 处理」
- L1072: case (.drawing, .setDrawingSnapshot) 注释「drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing」
- L1082: 跨 session guard fall-through 注释 wording + 位置改 spec 字面
  （注释从 return 行 inline 后移到 return 前，wording 改「来自上一轮 session 的延迟 action，忽略」）
零行为变；258 → 265 tests (+5 stale: 3 auto spec-literal + 1 free + 1 nonzero-mutation-killer; +2 distinguishing: committed + cancelled wrong-source mutation kill)，0 failures / 0 warnings。

第 3 L cosmetic（unmatched test wrong-source mutation 盲区）R3 high-1 修订后由 2
distinguishing tests（drawingCommittedReadsSnapshotNotRevision /
drawingCancelledReadsSnapshotNotRevision）+ acceptance §6.3 grep 三轨守备。"
```

---

### Task 3: 中文非-coder 验收清单

**Files:**
- Create: `docs/acceptance/2026-05-13-pr7b2-stale-drift-tests-helpers-cosmetic.md`

#### Step 3.1: 写验收文档

- [ ] 

```markdown
# PR 7b2 — C1b Stale Drift Tests + Helper Extract + Cosmetic 验收清单

> **目标读者：** 不写代码的复审人（按 §动作 步骤跑命令、对照 §预期 / §通过判定 勾选）。
> **前置条件：** 已 checkout PR7b2 worktree branch；macOS 终端打开；`xcrun --find swift` 命令存在。
> **工作目录：** `<worktree>/`（运行 swift 命令前 `cd` 进去；命令内带 `--package-path ios/Contracts` 不需要进子目录）。

## §1. 编译通过

**动作：**

```bash
swift build --package-path ios/Contracts
swift build --package-path ios/Contracts -c release
```

**预期：** debug + release 两次都打印「Build complete!」无 warning 无 error。

**通过判定：** 两次 stdout 均含 `Build complete!`。任何 `error:` / `warning:` 行 → 不通过。

## §2. 全部测试通过 265/265 in 58 suites（baseline 258/57 + 7 新测试 + 1 新 Suite）

**动作：**

```bash
swift test --package-path ios/Contracts 2>&1 | tail -5
```

**预期：** 输出末尾 `Test run with 265 tests in 58 suites passed`。

**通过判定（R5 medium-1 + R6 medium-1 修订：双轨判定，绝对 + 相对）：**
- **绝对：** 数字 = 265 tests in 58 suites（baseline 258 in 57 suites + 5 stale + 2 distinguishing 新测试 + 1 新 Suite `ReduceStaleDrawingSnapshotTests`）；`0 failures` 且 `0 warnings`
- **相对：** = Step 1.1 baseline + 7 tests + 1 suite（若 baseline 漂移而 plan 已 patch baseline 数字，相对差不变）
- 若 baseline 在实施期间漂（Step 1.1 实测 != 258/57），则 plan 内 265/58 同步 +漂移量，相对差仍为 +7/+1

## §3. 新 Suite `ReduceStaleDrawingSnapshotTests` 5/5 + distinguishing 2/2 = 7/7 PASS

**动作（R4 medium-1 修订：filter 必须包含 2 distinguishing test 函数名，不能只过滤 Suite——distinguishing tests 在 `ReduceDrawingCommittedTests` / `ReduceDrawingCancelledTests` 既有 Suite 内）：**

```bash
swift test --package-path ios/Contracts \
    --filter "ReduceStaleDrawingSnapshotTests|drawingCommittedReadsSnapshotNotRevision|drawingCancelledReadsSnapshotNotRevision" 2>&1 | tail -10
```

**预期：** 7/7 PASS（5 stale：tradeDrift / tradeDriftNonZeroBaseline / periodComboDrift / offsetAppliedDrift / freeScrollingOffsetAppliedDrift；2 distinguishing：drawingCommittedReadsSnapshotNotRevision / drawingCancelledReadsSnapshotNotRevision）。

**通过判定：** 末尾 `Test run with 7 tests passed` 且无 fail 行。**严格要求 7 不允许 5 / 6**——任何小于 7 = filter 未匹配全部 distinguishing tests / nonzero baseline test 缺失 = mutation-killing 覆盖未跑。

## §4. Helper 抽出完成 — 13 处 inline copy 已删，2 个 file-level helper 已加

**动作：**

```bash
# 旧 inline helper 应全删（应返回 0）
grep -cE 'private func (make|drawingMode)\(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# 新 file-level helper 应存在（应返回 2）
grep -cE 'private func (makePanel|makeDrawingMode)\(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift

# callsite rename 完成（旧名 0；新名 ≥13）
grep -c 'makePanel(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
grep -c 'makeDrawingMode(' \
    ios/Contracts/Tests/KlineTrainerContractsTests/ReducerTests.swift
```

**预期：**
- 第 1 条：`0`
- 第 2 条：`2`
- 第 3 条：`≥9`（每处原 make callsite 替换；不计 helper 定义本身的 1 行）
- 第 4 条：`≥4`（每处原 drawingMode callsite 替换；不计 helper 定义本身的 1 行）

**通过判定：** 4 条 grep 数值符合上述。任何偏差 → 不通过。

## §5. Prod inline comment 字面对齐 spec L1056 / L1072 / L1082

**动作：**

```bash
# §5.1: spec L1056 inline comment
grep -nF '// 切换工具由 DrawingToolManager 处理' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §5.2: spec L1072 inline comment
grep -nF '// drawing 模式下切工具由 DrawingToolManager 处理，不重复进 drawing' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §5.3: spec L1082 cross-session guard 注释字面
grep -nF '// 来自上一轮 session 的延迟 action，忽略' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §5.4: 旧 PR7b1 wording 已删
grep -cF '// 旧 session 遗留 action，丢弃保持当前 drawing' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

**预期：**
- §5.1 命中 1 行
- §5.2 命中 1 行
- §5.3 命中 1 行
- §5.4 返回 `0`

**通过判定：** 3 条 grep 命中 1 行 + 1 条 grep 返回 0。任何偏差 → 不通过。

## §6. Stale guard + cross-session guard 字面守住 — mutation belt+suspenders

**动作：**

```bash
# §6.1: stale guard 字面
grep -nE 'guard baseRev == revision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.2: stale return literal
grep -nF '.staleDrawingSnapshot(expected: baseRev, actual: revision)' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift

# §6.3: cross-session guard 字面（R2 medium-2：守第 3 L cosmetic mutation 盲区——
#        unmatched unit test 使用 snap.baseRev == state.revision，wrong-source mutation
#        `guard base == revision` 不被 unit test 抓；grep 守 prod 字面 `base == snap.frozen.baseRevision`
#        在 commit + cancel 两处都未误改）
grep -cE 'guard base == snap\.frozen\.baseRevision else' \
    ios/Contracts/Sources/KlineTrainerContracts/Reducer/Reducer.swift
```

**预期：**
- §6.1 命中 1 行
- §6.2 命中 1 行
- §6.3 返回 `2`（drawingCommitted + drawingCancelled 各 1 行；不允许 0 / 1 / 3+）

**通过判定：** §6.1 + §6.2 命中 1 行 + §6.3 返回 2。任意偏差 → 不通过（说明 PR7b1 已落的 stale guard 或 cross-session guard 被本 PR 误改）。

## §7. PR7a / PR7b1 既有 Suite 行为零回归

**动作：**

```bash
swift test --package-path ios/Contracts \
    --filter "ReducePanStartedTests|ReducePanEndedTests|ReduceTradeTriggeredTests|ReducePeriodComboTests|ReduceOffsetAppliedTests|ReduceActivateDrawingTests|ReduceSetDrawingSnapshotTests|ReduceDrawingCommittedTests|ReduceDrawingCancelledTests|RevisionWrapTests" 2>&1 | tail -10
```

**预期：** 全部 PASS（≥26 tests = PR7a 15 + PR7b1 10 + revision wrap 1）。

**通过判定：** 末尾 PASS 总数 ≥ 26，无 fail。

## §8. PR7b2 scope-out 项目（不在本 PR 验收，已留下一锚点）

不验证以下行为（PR 7b3 scope）：
1. `requestDrawingSnapshotAfterStoppingAnimator` effect handler **真派发**集成测试（含 animator.stop() 必须在 candleRange 计算前 → PR 7b3）
2. `DecelerationAnimator.stop()` handler 合约 + integration test → PR 7b3
3. 第 3 L cosmetic「unmatched test 不能区分 guard 读 wrong source mutation」→ R3 high-1 修订后由本 PR 2 个 distinguishing tests（`drawingCommittedReadsSnapshotNotRevision` + `drawingCancelledReadsSnapshotNotRevision`）+ §6.3 grep 三轨守备落地，不再 scope-out

## §9. 总结

- 新增 5 个 stale 漂移 tests（spec L1159-1162 验收 #3 三条 auto path 完整覆盖 + R2 medium-1 freeScrolling + R6 medium-1 trade nonzero baseline：tradeDrift / tradeDriftNonZeroBaseline / periodComboDrift / offsetAppliedDrift / freeScrollingOffsetAppliedDrift）
- 新增 2 个 distinguishing wrong-source mutation-killing tests（R3 high-1：drawingCommittedReadsSnapshotNotRevision / drawingCancelledReadsSnapshotNotRevision；distinguishing fixture state.rev != snap.baseRev 覆盖 prod cross-session guard 读取源）
- 抽出 13 处 inline test helper copy → 2 个 file-level `private func`（PR7b1 plan §4 R1 M-4 技术债结算）
- prod 3 处 inline comment 字面对齐 spec L1056 / L1072 / L1082；零行为变
- 0 新依赖、0 新文件 prod、0 新 SwiftPM target
- 265 tests in 58 suites / 0 failures / 0 warnings；PR7a + PR7b1 既有 Suite 零回归
```

#### Step 3.2: Commit acceptance

- [ ] 

```bash
git add docs/acceptance/2026-05-13-pr7b2-stale-drift-tests-helpers-cosmetic.md
git commit -m "docs(PR7b2): 验收清单（中文非-coder 可执行）

9 节验收：编译 + 全包 265 tests + 新 Suite 5/5 + distinguishing 2/2 (= 7/7) + helper 抽出完成（13 删 + 2
加） + prod 3 注释 spec 字面对齐 + stale guard belt+suspenders + PR7a/7b1
零回归 + scope-out 列示。Reducer.swift 不跨 trust-boundary 不消费 AppError，
无单独 gate 节。"
```

---

## Self-Review

**1. Spec coverage：**

| spec 章节 / 验收点 | 任务 | 状态 |
|---|---|---|
| L1056 case (.drawing, .activateDrawing) 注释字面 | Task 2.1 | ✓ |
| L1072 case (.drawing, .setDrawingSnapshot) 注释字面 | Task 2.2 | ✓ |
| L1082 跨 session guard fall-through 注释字面 | Task 2.3 | ✓ |
| L1146-1158 stale 可达路径设计说明 | 设计 §3 + Task 2.5 测试 | ✓（覆盖在 5 stale tests） |
| L1148/L1160 验收 #3 path 1（trade 漂移 spec literal r=0→r=1，R6 medium-1 修订保留） | Task 2.5 `tradeDrift` | ✓ |
| 同上 + mutation gap（R1 medium-2，R6 拆姊妹 test） | Task 2.5 `tradeDriftNonZeroBaseline` | ✓ |
| L1160 验收 #3 path 2（periodCombo 漂移） | Task 2.5 `periodComboDrift` | ✓ |
| L1161-1162 验收 #3 path 3（offsetApplied 漂移 auto） | Task 2.5 `offsetAppliedDrift` | ✓ |
| L1059-1064 stale guard 的 freeScrolling 分支（R2 medium-1 新增） | Task 2.5 `freeScrollingOffsetAppliedDrift` | ✓ |
| L1163-1166 验收 #4 cross-session（已 PR7b1 落 + 本 PR acceptance §6.3 grep 再守） | Task 2.8 + acceptance §6.3 | grep belt+suspenders |
| L1167 验收 #5（Deceleration stop 集成） | **PR 7b3** scope-out | — |
| L1168-1171 验收 #6+#7（assertion + 双分支）（已 PR7b1 落） | — | 不重复 |
| L1172-1174 验收 #8 offsetApplied（已 PR7a 落） | — | 不重复 |
| PR7b1 plan §4 R1 M-4 helper 抽出技术债 | Task 1 (Batch A) | ✓ |
| PR #48 post-impl L1 cosmetic（L1056 注释） | Task 2.1 | ✓ |
| PR #48 post-impl L2 cosmetic（L1072 + L1082 注释） | Task 2.2 + 2.3 | ✓ |
| PR #48 post-impl L3 cosmetic（unmatched mutation 盲区，wrong-source guard） | R3 high-1 修订：Task 2.5b 2 distinguishing tests（drawingCommittedReadsSnapshotNotRevision / drawingCancelledReadsSnapshotNotRevision，distinguishing fixture state.rev != snap.baseRev）+ Task 2.8 §6.6 + acceptance §6.3 grep `guard base == snap.frozen.baseRevision else` 在 commit+cancel 各 1 行 | 决议 + executable test + grep 三轨守 |

**2. Placeholder scan：** 全 plan grep `TBD\|TODO\|implement later\|fill in details\|appropriate error handling\|edge cases\|similar to`：仅 PR 7b3 scope-out 引用作为 forward reference，无 plan-internal placeholder。✓

**3. Type consistency：**
- `PanelViewState` / `FrozenPanelState` / `DrawingSnapshot` / `ChartInteractionMode` / `ChartAction` / `ChartReduceEffect`：与 PR7a/7b1 `Reducer.swift` 完全一致（本 plan 不改类型签名）
- `makePanel(_ mode:rev:offset:)` 签名：`(ChartInteractionMode, UInt64 = 0, CGFloat = 0) -> PanelViewState`——plan 内 9+5+2=16 处引用全用此 ✓（含 5 stale tests + 2 distinguishing tests）
- `makeDrawingMode(baseRev:)` 签名：`(UInt64 = 5) -> ChartInteractionMode`——plan 内 0 处直接引用（4 stale tests 不进 drawing 模式；callsite rename 由 Step 1.5 处理既有 4 处）✓
- `ChartReduceEffect.staleDrawingSnapshot(expected:actual:)` / `.requestDrawingSnapshotAfterStoppingAnimator(tool:baseRevision:)` / `.clearPendingDrawing` / `.none`：plan 内 4 stale + 2 distinguishing tests 引用全 spec 字面 ✓
- `ChartAction.activateDrawing(_:)` / `.tradeTriggered` / `.periodComboSwitched` / `.offsetApplied(deltaPixels:)` / `.setDrawingSnapshot(tool:baseRevision:candleRange:)` / `.drawingCommitted(baseRevision:)` / `.drawingCancelled(baseRevision:)`：plan 内 6 tests 引用全 spec 字面 ✓
- `DrawingToolType.ray / .trend / .horizontal`：4 stale tests 使用（ray 出现 2 次：trade auto + free，trend 1 次 periodCombo，horizontal 1 次 offsetApplied auto），与 Models.swift 一致 ✓；distinguishing tests 不用 DrawingToolType（committed/cancelled action 只带 baseRevision，不带 tool）✓
- `makeDrawingMode(baseRev:)` 反向引用：4 stale tests 中 0 处直接调用；**2 distinguishing tests 各调用 1 次**（构造 `drawing(snap.baseRev=5)` mode 然后传入 makePanel rev=99）→ helper 抽出在 Batch A 落地后，Batch B 内自动可用 ✓

**4. Sub-task budget：** 3 子项（Batch A / Batch B / Task 3） ≤3 ✓；prod 净增 ~+2 ≤500 ✓；触及 prod 文件 1 个；触及 test 文件 1 个；新依赖 0；新 target 0。

**5. TDD/refactor discipline 校验：**
- Batch A 是 refactor-only（不是 red→green）；纪律 = baseline test count 与抽后 test count 完全一致（258 → 258）；任何偏差立刻 stop
- Batch B 是 characterization tests + cosmetic patch；5 stale tests + 2 distinguishing tests 期望直接 PASS（prod 字面已在 PR7b1 落）；任意 FAIL = stop-the-line（不允许"改 test 期望迁就 prod"）
- §6 stale guard mutation 校验（R6 medium-1 最终方案）：trade 路径拆 2 个姊妹 test——`tradeDrift` 守 spec literal r=0→r=1，`tradeDriftNonZeroBaseline` 起点 `rev: 5`（drift 后 `expected:5, actual:6`）可抓 `guard baseRev != 0` 常量 mutation；periodCombo / offsetApplied / freeScrolling 仍用 `rev: 0` 保留 spec L1159-1162 字面对照；acceptance §6.1 grep `guard baseRev == revision else` 字面守备保留作为 belt+suspenders
- cross-session guard mutation 校验（R3 high-1 修订后）：2 distinguishing tests 用 `state.rev = 99, snap.baseRev = 5, base = 99` fixture，可抓 wrong-source mutation `guard base == revision`（mutation: 99 == 99 → guard 通过 → 退出 drawing → test FAIL）；acceptance §6.3 grep `guard base == snap\.frozen\.baseRevision else` 命中 2 次（commit + cancel）作为 belt+suspenders

**6. Forward-reference 一致性：** plan 内所有 "PR 7b3 scope-out" 引用 → §1 覆盖矩阵表 + acceptance §8 + Self-Review §1 spec coverage 表三处显式列示；与 v6 outline 顺位 14（DecelerationAnimator 集成）一致。

**7. LOC 估算复核：**
- Reducer.swift：3 inline comment 字面对齐；L1056 / L1072 各 +1 行（新加注释）；L1082 注释从 inline 后移到前（同 1 行 → 同 1 行 但位置变）；prod 净 +2 行；总 206 → 208
- ReducerTests.swift：
  - Batch A 抽 helper：删 9 处 `make` × ~3 行 + 4 处 `drawingMode` × ~6 行 = -27 - 24 = -51；加 2 file-level helper（含 MARK + 注释）+~14；callsite rename 零行差；Batch A 净 -37
  - Batch B 加 1 Suite × 5 stale tests + MARK + 注释 = +~110；加 2 distinguishing tests（committed + cancelled Suite 内插入）+~30；
  - 全 PR 净 +88（-37 Batch A + 125 Batch B）；总 622 → ~710
- Acceptance doc：~95 行新文件

净 prod +2 行 ≤500 ✓ / 净 test +88 行（无硬规则）/ 文件粒度无变 ✓

---

**Plan complete and saved to `docs/superpowers/plans/2026-05-13-pr7b2-stale-drift-tests-helpers-cosmetic.md`.**
