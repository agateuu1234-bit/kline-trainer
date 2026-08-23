# 划线 P1b「撤销 / 前进」实施计划（1b-ii 撤销 PR）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 画线底栏补齐 ④↩ ⑤↪ 两个键；画线 / 删线 / 改样式 / 锁定四类动作可撤销一步、可前进一步；**画线态改样式的「那条线 + 本局默认」两处写入当一个动作一并回滚、一并重做**。

**Architecture:** 撤销栈（深度 1）存在 `TrainingEngine` 里，入栈点与 `drawingsRevision += 1` **同一位置、同一条件**，使「写了却忘了入栈」在结构上不可发生。撤销的执行走**专用私有单点** `applyUndoEntry`，只吃引擎自己吐出的快照、不复用四个写入 API，因此不会被 D60 / D61 的门挡住，也不会把 z-order 搞乱。为了让「画线态一次改样式 = 两处写入」成为**一条**撤销记录，引擎新增一个「一次动作」作用域，路由把 `applyPanelStyleMutation` 整个函数体包进去；作用域进入时给「本局默认」拍快照，退出时比对，有差就并进同一条记录。

**Tech Stack:** Swift 6 / SwiftPM（`ios/Contracts`）· swift-testing（`@Test`/`@Suite`）+ XCTest（源码守卫那一族）· `@Observable` + `@MainActor` · Catalyst 闸门（UIKit-gated 测试）

**Spec:** `docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md` §2（PR-2 撤销）
**上游交接 spec:** `docs/superpowers/specs/2026-08-12-drawing-tools-P1b-autoselect-design.md` §10.1 + §12（override 边界，其中「撤销成对回滚」**不在** override 覆盖范围内）

**分支：** `feat/drawing-p1b-undo`，起点 = `feat/drawing-p1b-autoselect` @ `6c1497d`（自动选中 PR 的 tip）。
**评审 / PR 的 base = `feat/drawing-p1b-autoselect`**，不是 `origin/main`。
⚠️ `origin/main` 已到 `d38da4b`（QMT S3 / #169），三片都没合它。**此刻拿 main 当评审基准，S3 的代码会被当成"本片删掉的"（实测 -2310 行）→ 一堆假 finding。** 合并前才按次序把 main 合进三片，然后重跑 attest。

**闸门基线（本支起点 `6c1497d` 实测）：**
- host `swift test`：**1907 tests / 223 suites passed**，exit 0（2026-08-21 实跑）
- host XCTest：**288**（交接值；本次基线日志被 `tail -25` 截断没抓到该行，**Task 1 第一次完整判绿时实测回填本行**）
- Catalyst：`catalyst-total-baseline.txt` = **1811**，`catalyst-uikit-baseline.txt` = **78 行**

---

## 本计划新增的三条决策（spec 没有，**必须过 codex 评审**）

撤销 spec 写于 **2026-08-11**，那时「持久化片」与「自动选中片」都还不存在。它设计的撤销记录形状是「一条线的 before / after / index」，**通篇没有「本局默认」这个分量**。而自动选中片落地后，画线态的一次改样式变成了**两处写入**（`DrawingEditRouter.swift:258-268`：先写本局默认，再 best-effort 改那条线）。照 spec 字面实现会产出**两条**记录，深度 1 的栈让第二条把第一条挤掉 —— 正是交接 §10.1 点名的坏结果。

故本计划新增三条决策，编号接在 D100 之后。**它们是新决策，不是从 spec 抄的**，实施者不得把它们当成"spec 原文"引用。

### D101　入栈条件 = 「`drawings` 内容真的变了」；本局默认单独变化**不入栈**

- 一次动作里 `drawings` 内容真的变了 → 记一笔。若该动作**顺带**改了本局默认，把默认的 before / after **并进同一笔**。
- 一次动作只改了本局默认、一条线都没碰 → **不记**，↩ 保持原状（既不亮、也不冲掉已有的栈顶）；
  **但必须把栈顶那条记录的「默认分量」丢掉**（见下面的不变量）。

**不变量（codex plan-R3 high，已核实为真）：栈里那条记录的默认分量，两端必须仍与「当前默认值」对得上。**

对不上会怎样：栈顶记录说「默认从 X 变成了 Y」，而用户之后**又单独**把默认改成了 Z（那次按上一条不入栈）。
此后 ↩ 会把默认按 X 写回、↪ 会按 Y 写回 —— **两个方向都静默覆盖掉用户刚刚选的 Z**，
还经 autosave 落盘。这不是「那次改动撤不回来」（那是已接受残留），而是**一次更早的操作反过来
把更晚的操作抹掉了**，性质完全不同。

**处置**：默认真的变了、却没有任何 `drawings` 改动 ⇒ 把栈顶的**默认分量丢掉**（置 `nil`），
`drawings` 那一半**照常保留**（那条线根本没被碰过，它的 before/after 仍然有效）。

⚠️ **本处方比 codex 的建议更宽，是有意的**：它建议「把 `isUndone == true` 的记录作废」，
那只堵住了 ↪ 那一半 —— `isUndone == false` 时按 ↩ 同样会用旧的 `before` 覆盖掉新默认。
丢掉默认分量把**两个方向一起**堵死，且**不牺牲**「那条线的编辑仍可撤销」这个功能。
（若改成「整条作废」，则「选择态没选中任何线时改一下默认」这种最常见的操作
会把 ↩ 直接变灰 —— 那是比缺陷本身更糟的功能回归。）

**完整性论证（为什么只需管这一条路）**：`setDefaultStyle` 在 `Sources/` 里的调用点共 5 处（守卫 G1 钉死）——
路由 2 处**都在**本作用域内、coordinator 2 处是**新引擎**的续训种子（栈按定义为空）、
`applyUndoEntry` 1 处是撤销自己（它写的就是记录里的值，天然对得上）。故没有第二条会让默认分量过期的路。

**为什么**：D80 已经把「`drawingsRevision` 递增 ⟺ `drawings` 内容真的变了」立成不变量，入栈条件**恰好等于**它 —— 两者同条件同位置，「入栈与 revision 不同步」这个坏状态不可表达。若改成「默认变了也入栈」，就要另立一套判据，且用户点 ↩ 之后屏幕上什么都不变（默认不可见），是"按了没反应"。

> ⚠️ **已接受残留（必须写进 PR 描述）**：画线态下若那条线被拒（锁定 / 滑出屏 / 带未来数据 / 工具未实现四类门之一），结果是「只有默认变了」，这次改动**撤不回来**。用户 2026-08-21 明确接受。
> 并且按上面那条不变量，它会把栈顶记录的**默认分量清掉** —— 那条线的编辑**仍然可撤销**，
> 但撤销时不再连带回滚默认（因为默认已被一次**更晚的**用户操作改过，回滚它就是覆盖用户的新选择）。

### D102　「一次动作」作用域 —— 把画线态的两处写入合成一条撤销记录

引擎新增 `performDrawingAction(_ body: () -> Void)`：

- 进入时给 `drawingSession.defaultStyle` 拍快照，清空 pending 分量；
- 作用域内四个写入 API 的成功路径**不直接入栈**，只把 delta 记到 pending；
- 退出时：pending 为空 → 不入栈（D101）；非空 → 与「默认前后是否有差」合成**一条**记录压栈。
- **不许嵌套**；一个作用域内出现**第二次** `drawings` 改动 → fail-closed **作废整个栈**（不 crash，见 Task 5）。

**唯一调用点** = `DrawingEditRouter.applyPanelStyleMutation` 的整个函数体（源码守卫钉死）。其余三条动作路径（删线 / 锁定 / 画线提交）**不包作用域**，写入 API 直接自成一条记录 —— 行为与不包时逐字相同。

**为什么不把入栈搬到路由层**：D74 的理由「入栈必须与写入同处，否则'写了却忘了入栈'要靠人记」一个字都没过时（1b-i 的 D56 已经证明过一次）。作用域是在**不破坏**那条理由的前提下，补上 spec 当时没有的「一次动作可以跨两个写入面」。

### D103　清栈绑「`drawingModeActive` 真的翻转」，**不是**「调了 activate/deactivate」

> ⚠️ **spec §2.1 的「落地形态」那一句与它自己的 N-Q5 冲突，本计划按 N-Q5 收紧。**

spec §2.1 写：「清栈与 `drawingSession.activate(` / `deactivate(` **同一条语句序列、同一个分支**内（即：真的调了 activate/deactivate 才清）」。
**实测这句是错的**：`DrawingSession.activate(tool:)`（`DrawingSession.swift:201-209`）第一行就是 `drawingModeActive = true`，**幂等**；会话已开时再调一次 `beginDrawingSession` 会**再次**走到 `drawingSession.activate(tool:)`（`TrainingEngine.swift:1402`）却**没有任何状态翻转**。照那句实现 ⇒ N-Q5（「冗余的 begin-while-active 必须保留栈」）当场变红。

**正确落地形态**（四个站点逐处照抄，**不许抽 helper**——`clearDrawingUndoStack()` 必须**字面出现**在这三个函数体里，否则 N-S 共处守卫失效）：

```swift
let wasActive = drawingSession.drawingModeActive
drawingSession.activate(tool: tool)                                   // 或 deactivate()
if wasActive != drawingSession.drawingModeActive { clearDrawingUndoStack() }   // D103：只有真翻转才清
```

---

## Global Constraints

以下每一条对**每个 task** 都成立，task 正文不再重复。

### G-0　交接约束（自动选中 spec §10.1 + §12，**一条都不打折**）

自动选中 spec 的 override **只赦免「文档写法」，不赦免「行为正确性」**，且 §12 逐字把「R12 的撤销成对回滚（§10.1）」列进**不覆盖**清单。故以下两条是**硬约束**，实施中若发现难以落地，**必须回来改计划并重跑评审**：

1. **画线态改一次样式是两处写入 → 撤销必须把这一对当一个动作**，undo / redo 一并回滚一并重做。拆成两条记录 = 被撤销的样式会在下一笔新线上、以及续训后复活。**必配回归**：画线态改样式 → undo → 断言线的样式与本局默认**双双**回到改动前；redo → 双双回到改动后。（Task 5）
2. **undo 恢复回来的线不自动选中**，且**不得复用** `commitPendingAndSelect`。（Task 6 + 源码守卫）

PR 描述里**必须复述本节**，并复述 D101 的已接受残留。

### G-1　零契约影响

**不新增 / 不修改任何持久化字段、不改 `CONTRACT_VERSION`（当前 `1.13`）、不加迁移、不改 settings 表**（spec §3）。
**撤销栈绝不落盘**（D25：退出画线模式即清空）。
undo / redo 只改 `drawings` 与 `drawingSession.defaultStyle` 两个**已经**被 autosave 盯住的量（`TrainingView.swift:49/52` 的 `DrawingAutosaveTriggersModifier`），落盘路径与 1b-i / 持久化片逐字相同，**本片不新增任何触发器、不碰 `KlineTrainerPersistence/`**。
若任何一个 task 让你想去动 `AppDBMigrations.swift` 或 `PendingTraining*`，**停下来报回**——那是走错了。

### G-2　不放宽任何既有门

本片**不新增门、不放宽门、不重排门**。特别是：

- 四个写入 API（`appendDrawing` / `deleteDrawing(id:)` / `updateDrawingStyle` / `setDrawingLocked`）的门列表**一字不改**；本片只在它们的**成功路径**上加一行 `recordDrawingUndoDelta(...)`。
- `deletableIgnoringGeometry` 末行 `return !d.locked`（`DrawingEditRouter.swift:97`）**一字不改**。
- `lockableIgnoringGeometry` 刻意没有 `!d.locked` 分量，这个不对称**不碰**。
- ④↩ ⑤↪ 的置灰判据**刻意不共享** `selectionGeometryVisible`（D78）——撤销是会话级操作，与选中态、几何都无关。这是本片唯一的**有意不对称**，必须在实现处留承重注释，防后人"顺手统一"。

### G-3　判绿纪律（每个 task 收尾都要做，缺一视为证据不全）

**PREAMBLE —— 任何带管道的验证命令都必须贴在这一段后面：**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
```

- ⭐⭐ **每条闸门命令必须同时打印 branch / HEAD**。分支不是 `feat/drawing-p1b-undo` 一律**拒绝判绿**。
- ⭐⭐ **判绿不能只读 `swift test | tail -3`**：那行 `Test run with N tests in M suites passed` **只统计 swift-testing**，本仓另有 **288 条 XCTest**（`func test…`）完全不在这行里 —— 而本计划的源码守卫**全是 XCTest**。只看这行，「守卫根本没跑」与「守卫跑了且通过」长得一模一样。**收尾判绿一律加这三条**：

```bash
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-gate.log | tail -3      # swift-testing 汇总
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-gate.log | tail -2 || exit 1   # XCTest 执行量
grep -E "Test Case .*<本 task 新增的 XCTest 名>.* passed" /tmp/undo-gate.log || exit 1    # 点名确认它真跑了
```

⚠️ **基线日志不许再用 `| tail -N` 落盘**（本计划起点基线就是这么丢掉 XCTest 那一行的）——一律 `tee` 全量再 `tail` 显示。
报告里**必须同时记录两个数字**（swift-testing 条数 / XCTest 条数）。
⚠️ **上面每一条 grep 都必须带 `|| exit 1`**（本计划自查扩出来的整族，与 codex plan-R2 那条 high 同源）：
不带的话，「XCTest 一条都没跑」与「跑了且全过」在脚本里长得**一模一样** —— 那行 grep 无输出、
退出码 1，而没人读它 ⇒ 判绿照样通过。这正是本计划最怕的假绿形态。

- ⭐ **多门连跑的块，每门单独 `|| exit 1`**，不许一门红了继续跑下一门然后报绿。
- ⭐⭐ **`grep -c` 绝不能直接当门**（codex plan-R2 high，**已核实为真**）：计数为 0 时 `grep` 自己的
  退出码是 **1**，拿它当判据方向正好反 —— 「日志干净」被读成失败、「日志有错」被读成通过。
  一律写成 `test "$(grep -c '<pat>' <log>)" -eq 0 || exit 1`，把**数值比较**和**退出码**分开。
- ⭐⭐ **`xcodebuild` 那一行必须自己带 `|| exit 1`**：`set -o pipefail` 只保证管道**传递**退出码，
  不会让脚本停下来。且编译失败时**不一定**打出 `error:` 字样（scheme 找不到 / destination 不可用
  都可能一行都不打）—— 只数 `error:` 会把这类失败整个读成绿。**退出码 + 日志内容 + 产物存在**
  三条要各断各的，缺一条就有一种失败形态从门底下溜过去。
- ⭐ **每个 task 收尾必须 `git status --short` 确认工作区干净**（输出为空）。非空 = 有改动没提交（脏树假绿）或变异没复原干净，**两者都必须当场查清再继续**。
- ⭐ **改了 `Sources/` 就要重跑门，哪怕「只改注释」**。

### G-4　变异纪律

> ⛔⛔ **次序铁律：先提交实现，再跑变异。**
>
> 1. 实现 + 测试写完、host 全量绿 → **先 `git commit`**；
> 2. **再**在这个已提交的基线上逐条跑变异；
> 3. 每条变异复原后立刻 `git status --short` 确认**输出为空**，再做下一条；
> 4. 变异证据写进**报告文件**（不进代码），故不需要第二个 commit。
>
> 上一片（自动选中）Task 6 第一次实施时被会话额度中途掐断，留下跨 5 个文件的未复原变异态，整个工作区作废重来过一次。这条纪律把「被杀」从灾难降级为无损。

- 每条变异必须回答「**红的是哪一条测试**」，不是「有测试变红」。PR 描述里逐条记录**测试名** + **复原后重新变绿**的证据。**实施者自报「验过了」不算数。**
- **变异复原一律 `cp` 到 `/tmp` 再 `cp` 回，禁止 `git checkout <file>`**（会静默抹掉未提交改动）。
- 变异**必须对准**你要证明的那条判据；若某判据在被测路径上根本不求值，正解是写成**不变量锁测试**而不是假装它有行为覆盖。

### G-5　守卫纪律

- **不得写成「禁词黑名单」**，一律用**结构计数**。
- 否定 / 结构断言必须**剥注释、剥字符串字面量**再匹配（用 `SourceGuardScanner.swift` 的 `squeezedSource` / `squeeze` / `callCount` / `callSiteCount` / `filesMentioning` / `expectEngineInternalOnly` / `expectIdentifierNeverVended`），否则本计划要求写的那些**承重注释**会把守卫自己打红，而「删掉那句注释」就成了合法绕过路径。
- **用户可见文案 / SF Symbol 名是字符串字面量** → 必须读**原始文本**（`squeezedSource` 会丢弃字面量内容，在它上面断言恒假）。
- **每个守卫必须配双向自检**：喂一段「本该命中」的合成样本必须命中、喂一段「本该不命中」的必须不命中。锚点失效必须**报错**，不得静默返回 0。
- ⭐⭐ **守卫必须在它自己那个 task 结束时是绿的** —— 一条开局就红的守卫等于给实施者发放宽许可证。本计划的 task 边界**就是按这条排的**，不得擅自把守卫挪到别的 task。

### G-6　Catalyst 基线同步（**只有 Task 8 触发**）

本片**不新增任何 UIKit-gated 测试**（`catalyst-uikit-baseline.txt` 保持 **78 行**），但新增大量 host 测试 ⇒ `catalyst-total-baseline.txt` 的 **1811** 必然漂出 ±30 容差窗口，**不同步 CI 必红**。Task 8 同步**三处**（uikit 基线那一处因为条数不变而只需**重生成后确认无 diff**）：

1. `.github/scripts/catalyst-uikit-baseline.txt` —— 用 `uikit-expected-tests.py` **重生成**，确认仍是 78 行、内容零 diff（**不是跳过，是要跑一遍拿证据**）
2. `.github/scripts/catalyst-total-baseline.txt` —— 1811 → 本轮真冷构建实测新值
3. `.github/scripts/catalyst-gate.test.sh` —— 「活基线覆盖」用例写死的旧数字（3 处）+ 追加维护记录条目
4. `.github/scripts/fixtures/pass-main-current.log` —— 用**本轮真冷构建**日志逐行重裁

⭐⭐ **喂闸门的日志必须冷构建**，否则会假红报「scheme 用错了？」。
**「冷构建」一律用专属的 `-derivedDataPath`（`mktemp -d` 出来的新目录），用完只删自己那个目录**
（codex plan-R8 medium，**已核实为真**）。⛔ **绝不** `rm -rf ~/Library/Developer/Xcode/DerivedData/KlineTrainerContracts-*`
—— 那个通配**不限于本 checkout**，本仓当前有 **16 个 worktree**，删它会把其它分支的构建产物、索引、
调试状态一并抹掉。全新目录天然就是冷的，效果一样而零外溢。
⭐⭐ Catalyst 双坑：必须 `-scheme KlineTrainerContracts-Package`（library scheme **不编译 testTarget**）+ `set -o pipefail`（tee 吞退出码）。**判绿读执行量，不读 `TEST SUCCEEDED` 字样**。
⭐ 取数用 CI 同款 `-only-testing:KlineTrainerContractsTests`。

### G-7　命名（**禁用相对编号**）

跨切片文档里**禁用「PR-1 / PR-2」这类相对编号**。一律用内容命名：

| 名字 | 含义 |
|---|---|
| **持久化 PR** | 本局默认随存档续训继承（PR #166 @ `3a0c88d`，整支评审真 approve、CI 全绿，**故意挂着不合**） |
| **自动选中 PR** | 画完线自动选中 + 改样式两套语义（PR #170 @ `6c1497d`，codex R1 真 approve 零 finding、CI 7/7 全绿）——**本片的起点** |
| **1b-ii 锁定 PR** | 底栏 🔒（已 MERGED #163，是本片的基线） |
| **1b-ii 撤销 PR** | 底栏 ↩ ↪ ——**本计划实施的就是它** |

**全局次序强制**：`持久化 PR → 自动选中 PR → 1b-ii 撤销 PR`。三片做完**一起真机验收、一起合**。

### G-8　评审通道与 push 边界

- 评审通道：**Codex**。`.claude/scripts/codex-attest.sh --scope branch-diff --head feat/drawing-p1b-undo --base feat/drawing-p1b-autoselect`
- ⛔ **绝不传未知参数**（含 `--help`，会被当成 focus → 假 approve）。
- ⛔ **push 和开 PR 由用户在终端自己跑** —— 守卫拦 Claude 的 Bash，根因是评审账本不跨 worktree 共享。实施者**不得**尝试 `git push` / `gh pr create`。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift` | **新建**：撤销记录的值类型（`DrawingUndoEntry` / `DrawingsDelta` / `DrawingDefaultStyleDelta`）。**纯值类型，不碰引擎、不碰 `drawings`** | Task 1 建，Task 5 加 `defaultDelta` 分量 |
| `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift` | 撤销栈存储 + 入栈 + 作用域 + `undoDrawing`/`redoDrawing`/`applyUndoEntry` + 清栈 | Task 1/2/3/4/5 **全部改在这一个文件里** |
| `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift` | 写入路由 + 可用性谓词（**无 UIKit → host 可测**） | Task 5 包作用域；Task 6 加 `undo`/`redo`/`undoButtonEnabled`/`redoButtonEnabled` |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingModeBar.swift` | 画线底栏（**UIKit-gated，host 不编译**） | Task 7：3 键 → **5 键** |
| `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift` | 训练页装配 | Task 7：给 `DrawingBottomBar(` 补 4 个参数 |
| `ios/Contracts/Tests/.../Drawing/DrawingUndoStackTests.swift` | **新建**：撤销栈的全部行为测试（swift-testing） | Task 1/2/3/5/6 各写自己那半 |
| `ios/Contracts/Tests/.../Drawing/DrawingUndoSourceGuardTests.swift` | **新建**：本片全部源码守卫（**XCTest**）+ 双向自检 | 每条守卫在**它自己那个 task** 里落地并转绿 |
| `ios/Contracts/Tests/.../TrainingEngineDrawingSessionTests.swift` | 引擎画线会话既有测试 | Task 4：L12b 期望值 **5 → 8** |
| `ios/Contracts/Tests/.../CoordinatorDefaultStyleSourceGuardTests.swift` | `setDefaultStyle` 调用点守卫 | Task 5：G1 期望值 **4 → 5** |
| `ios/Contracts/Tests/.../Render/DrawingInteractionUISourceGuardTests.swift` | 底栏接线守卫 | Task 7：三键守卫 **3 → 5** + 两条 ↩↪ 否定断言**反转** |
| `ios/Contracts/Tests/.../Render/DrawingBottomBarHeightTests.swift` | 底栏等高测试（**UIKit-gated**） | Task 7：`DrawingBottomBar(` 构造补 4 个参数（编译器逼的，**不是新增测试**） |
| `ios/Contracts/Tests/.../Drawing/DrawingUndoSourceGuardTests.swift`（同上一行） | 本片全部守卫**与它们的扫描器**（`functionBodies` / `engineDrawingsWritesByFunction`） | Task 2 建，Task 4 加逐函数扫描器 —— **不动** `SourceGuardScanner.swift` |
| `.github/scripts/catalyst-*.txt` · `catalyst-gate.test.sh` · `fixtures/pass-main-current.log` | Catalyst 闸门基线 | Task 8 一并同步 |

⚠️ **为什么引擎侧的所有撤销代码必须写在 `TrainingEngine.swift` 里，不许拆到 extension 文件**：`drawings` 声明为 `public private(set) var`（`TrainingEngine.swift:25`），**setter 是文件作用域** —— 别的文件里的 extension 根本写不了 `drawings`（编译器直接拦）。而且 L12b / D79 第一层那条穷尽守卫**只扫 `TrainingEngine.swift`**，把写入面挪到别的文件就等于从守卫底下溜走。两条理由同向，不许讨价还价。

---

## 开工前冲突扫描：**本片必然打破的 4 条既有守卫**（已实测，不是推测）

实施者遇到它们变红时**不许"顺手放宽"**，必须按下表在**指定的 task** 里连同理由一起改：

| # | 守卫 | 现值 | 本片改成 | 在哪个 task 改 |
|---|---|---|---|---|
| 1 | `TrainingEngineDrawingSessionTests.swift:1015` **L12b**「`drawings` 结构性写入点恰好 5 处」 | `n == 5` | **`n == 8`** | Task 4 |
| 2 | `CoordinatorDefaultStyleSourceGuardTests.swift:15` **G1**「`setDefaultStyle` 调用点恰好 4 个」 | `total == 4` | **`total == 5`**（+ `TrainingEngine.swift × 1`） | Task 5 |
| 3 | `Render/DrawingInteractionUISourceGuardTests.swift` **`bottomBarHasExactlyThreeKeys`** | `Button` 计数 `== 3`；且断言 `arrow.uturn.backward` / `arrow.uturn.forward` **不出现** | `== 5`；两条否定断言**反转成必须出现** | Task 7 |
| 4 | `Render/DrawingBottomBarHeightTests.swift:42` `DrawingBottomBar(...)` 构造 | 6 个参数 | 补 `undoEnabled` / `onUndo` / `redoEnabled` / `onRedo` | Task 7 |

⚠️ **第 1 条的既有注释预期是错的**：`TrainingEngineDrawingSessionTests.swift:1023` 写着「`drawings.insert(` ×0 → PR-2 才引入（届时期望值改为 **6**）」。**实测应为 8** —— `applyUndoEntry` 一个函数里就有**三处**结构性写入（`drawings.remove(at:)` / `drawings.insert(_:at:)` / `drawings[idx] =`），不是一处。Task 4 必须把那段注释一起改对，不许只改数字。

**另外确认无冲突的两处**（扫过，不用动）：
- `firstHit(` 调用点守卫（`DrawingHitTesterTests.swift:71`）只扫 `Sources/`，本片的 N-I 保序测试在 `Tests/` 里调它 → **不受影响**。
- `TrainingViewShellSourceGuardTests.swift:150`「autosave 触发器盯 `drawingsRevision`」—— 本片不动触发器 → **不受影响**。

---

## 依赖关系（**不得擅自重排**）

```
Task 1（入栈 + 数据结构）
   └─▶ Task 2（清栈生命周期 D74/D103）
          └─▶ Task 3（undo/redo 执行 + applyUndoEntry 前置条件 D76/D79②）
                 ├─▶ Task 4（写入面穷尽守卫 D79① + 两个绕过口子作废栈）
                 └─▶ Task 5（作用域 D102 + 本局默认成对回滚 —— G-0 的硬约束）
                        └─▶ Task 6（路由 undo/redo + 选中态 D77 + 置灰谓词 D78）
                               └─▶ Task 7（底栏 5 键 + TrainingView 接线 + 3 条既有守卫升级）
                                      └─▶ Task 8（收尾：Catalyst 基线 + 全量闸门 + 交接文档 + PR 描述）
```

三条捆绑是**结构逼出来的**：

1. **Task 1 必须先于 Task 2**：没有入栈就造不出「栈非空」这个状态，N-Q1…Q5 全部无从断言（用注入钩子替代 = 测不到真实入栈路径，正是 spec 点名的假绿套路）。
2. **Task 4 必须在 Task 3 之后**：L12b 的期望值 8 里有 3 处来自 `applyUndoEntry`，Task 3 没落地时改成 8 会立刻红 —— 违反 G-5「守卫必须在它自己那个 task 结束时是绿的」。
3. **Task 7 必须与既有守卫升级同 task**：加了两个 Button 那一刻 `bottomBarHasExactlyThreeKeys` 就红了，中间不能留一个红着的 commit。

---

### Task 1: 撤销记录的形状 + 四个写入 API 入栈（D75 + D101 的 `drawings` 那一半）

**Files:**
- Create: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift`
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
  （`deleteDrawing(id:):1115` / `appendDrawing:1133` / `updateDrawingStyle:1186` / `setDrawingLocked:1209` 四处成功路径；类体末尾 `:1425` 之前加栈存储与私有方法；`#if DEBUG` extension `:1480-1494` 加两个测试钩子）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`

**Interfaces:**
- Consumes：`DrawingObject`（`Models.swift`，`==` **排除 `id`**）、`DrawingDefaultStyle`、`TrainingEngine.drawings` / `drawingsRevision`、测试夹具 `makeStyledHLine(...)` / `expectDrawingsUnchanged(...)`（`DrawingTestFixtures.swift:27/69`）、`TrainingEngine.preview()`（`TrainingEngine.swift:1434`）
- Produces（后续 task 全部按这些名字引用，**不许改名**）：
  - `struct DrawingUndoEntry`，成员 `var drawingsDelta: DrawingsDelta`、`var isUndone: Bool`（Task 5 再加 `var defaultDelta: DrawingDefaultStyleDelta?`）
  - `enum DrawingUndoEntry.DrawingsDelta { case inserted(after: DrawingObject, at: Int); case removed(before: DrawingObject, at: Int); case replaced(before: DrawingObject, after: DrawingObject, at: Int) }`
  - `TrainingEngine.canUndoDrawing: Bool` / `TrainingEngine.canRedoDrawing: Bool`（**internal 计算属性**）
  - `TrainingEngine.clearDrawingUndoStack()`（**private**）
  - `TrainingEngine.recordDrawingUndoDelta(_:)`（**private**）
  - `TrainingEngine.drawingUndoEntryForTesting: DrawingUndoEntry?`（DEBUG 只读钩子）
  - `TrainingEngine.injectDrawingUndoEntryForTesting(_:)`（DEBUG 写钩子，Task 3 的陈旧栈测试要用）

- [ ] **Step 1: 写失败的测试**

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift
// Spec: docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md §2
// 计划新增决策：D101（入栈条件）/ D102（一次动作作用域）/ D103（清栈绑真翻转）
// ⚠️ `CoreGraphics` 是 Task 2 fix-1 补的：`periodSwitchKeepsStack` 要调 `recordRenderBounds(CGRect...)`。
import CoreGraphics
import Foundation
import Testing
@testable import KlineTrainerContracts

@Suite("1b-ii 撤销：入栈（D75 + D101）")
@MainActor
struct DrawingUndoPushTests {

    /// 从栈顶取「那一对 before/after 的 id 与下标」，供断言用。
    /// ⚠️ **绝不能直接比 `DrawingObject ==`** —— 它**排除 `id`**（`Models.swift` 实测），
    ///    一次「把 id 改写了、其它字段全同」的坏写入会从所有 == 断言底下溜过去。
    static func topShape(_ e: TrainingEngine) -> String? {
        guard let d = e.drawingUndoEntryForTesting?.drawingsDelta else { return nil }
        switch d {
        case .inserted(let after, let at):            return "inserted(\(after.id))@\(at)"
        case .removed(let before, let at):            return "removed(\(before.id))@\(at)"
        case .replaced(let before, let after, let at): return "replaced(\(before.id)->\(after.id))@\(at)"
        }
    }

    @Test("空引擎：↩ / ↪ 都不可用（栈为空）")
    func freshEngineHasEmptyStack() {
        let e = TrainingEngine.preview()
        #expect(e.canUndoDrawing == false)
        #expect(e.canRedoDrawing == false)
        #expect(e.drawingUndoEntryForTesting == nil)
    }

    @Test("画线入栈：appendDrawing 成功 → 栈顶是 inserted，下标 = 追加后的那个位置")
    func appendPushesInserted() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        #expect(Self.topShape(e) == "inserted(B)@1", "下标必须是追加后 B 所在的位置 1，不是 0")
        #expect(e.canUndoDrawing == true)
        #expect(e.canRedoDrawing == false, "刚做完新动作，↪ 必须是灰的")
    }

    @Test("删线入栈：deleteDrawing(id:) 成功 → 栈顶是 removed，下标 = 删除前的位置")
    func deleteByIdPushesRemoved() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "C", candleIndex: 5)) == true)
        #expect(e.deleteDrawing(id: "B") == true)
        #expect(Self.topShape(e) == "removed(B)@1", "下标必须是 B 被删之前所在的 1（保序的全部依据）")
    }

    @Test("改样式入栈：updateDrawingStyle 成功 → 栈顶是 replaced，before/after 同一条线")
    func updateStylePushesReplaced() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        var s = DrawingDefaultStyle(); s.thickness = 3
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)
        #expect(Self.topShape(e) == "replaced(A->A)@0")
        guard case .replaced(let before, let after, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.thickness == 1, "before 必须是**改动前**的快照")
        #expect(after.thickness == 3, "after 必须是**改动后**的快照")
    }

    @Test("锁定入栈：setDrawingLocked 成功 → 栈顶是 replaced，locked 前后不同")
    func lockPushesReplaced() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", locked: false)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        guard case .replaced(let before, let after, let at) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.locked == false && after.locked == true && at == 0)
    }

    // ── D101：内容没变 = 零副作用，**也不入栈**（栈顶必须原样保留） ──

    @Test("D101/N-R：no-op 改样式**不冲掉**栈顶那次真编辑")
    func noopStyleEditDoesNotClobberTop() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1)) == true)
        var s = DrawingDefaultStyle(); s.thickness = 3
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)          // 真编辑，入栈
        let rev = e.drawingsRevision
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)          // 同一份样式再来一次 = no-op
        #expect(e.drawingsRevision == rev, "D80：内容没变不得递增 revision")
        guard case .replaced(let before, _, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.thickness == 1, "栈顶仍必须是那次**真编辑**（before=1），不是被 no-op 覆盖成 before=3")
    }

    @Test("D101：幂等锁定不入栈（栈顶保持不变）")
    func idempotentLockDoesNotPush() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", locked: true)) == true)
        #expect(Self.topShape(e) == "inserted(A)@0")
        #expect(e.setDrawingLocked(id: "A", locked: true) == true, "D80：已经是该值 → 返 true")
        #expect(Self.topShape(e) == "inserted(A)@0", "幂等路径不得入栈，栈顶必须还是那次画线")
    }

    @Test("被拒的写入不入栈（三条门各一条）")
    func rejectedWritesDoNotPush() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        let top = Self.topShape(e)
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == false, "D66 重复 id → 拒")
        #expect(e.deleteDrawing(id: "ZZZ") == false, "不存在的 id → 拒")
        #expect(e.updateDrawingStyle(id: "ZZZ", style: DrawingDefaultStyle()) == false)
        #expect(Self.topShape(e) == top, "被拒的写入一条都不许入栈")
    }

    // ── 深度 1（N-K 的**栈内容**那半；行为那半在 Task 3） ──

    @Test("N-K 栈内容：深度 1 —— 新动作直接覆盖栈顶")
    func stackDepthIsOne() {
        let e = TrainingEngine.preview()
        #expect(e.appendDrawing(makeStyledHLine(id: "A")) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", candleIndex: 4)) == true)
        #expect(Self.topShape(e) == "inserted(B)@1", "栈里只能留最后一条")
    }
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift build --build-tests 2>&1 | tail -20
```
预期：**编译失败**，`value of type 'TrainingEngine' has no member 'canUndoDrawing'` / `'drawingUndoEntryForTesting'`。
⚠️ 编译不过就是本步的"红"，**不要**为了让它编译过而先塞空实现 —— 那会让 Step 4 的绿失去意义。

- [ ] **Step 3: 写最小实现**

**3a. 新建 `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift`：**

```swift
// ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift
// Spec: 2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md §2.2（D75）/ §2.3（D76）
// 计划决策 D101 / D102。
//
// ⚠️ **纯值类型**：本文件不引用 TrainingEngine、不写 `drawings`。
//    引擎侧的全部撤销代码必须留在 TrainingEngine.swift —— `drawings` 是 `public private(set)`，
//    setter 是**文件作用域**，别的文件里的 extension 根本写不了它（编译器直接拦）；
//    而 D79 第一层那条穷尽守卫也只扫 TrainingEngine.swift，挪出去就等于从守卫底下溜走。

/// 一条**可撤销动作**的快照。栈深度 1 —— 引擎里最多存一条（D25）。
struct DrawingUndoEntry {

    /// `drawings` 那一半。**必存** —— 没有 `drawings` 改动就根本不入栈（D101）。
    ///
    /// ⚠️ 三个 case 的 `at` 都是**动作发生时**的下标，D25 逐字：数组序 = z-order。
    ///    撤销必须回到**同一个下标**，不是"放回末尾"—— 否则同价位重合的三条线撤销之后，
    ///    在那个价位单击选中的就不是原来那条了（D25 / D33 / D40 点名的正是这个错误）。
    enum DrawingsDelta {
        /// 画线：undo = `remove(at:)`，redo = `insert(after, at:)`
        case inserted(after: DrawingObject, at: Int)
        /// 删线：undo = `insert(before, at:)`，redo = `remove(at:)`
        case removed(before: DrawingObject, at: Int)
        /// 改样式 / 锁定：undo = `drawings[at] = before`，redo = `drawings[at] = after`
        case replaced(before: DrawingObject, after: DrawingObject, at: Int)
    }

    var drawingsDelta: DrawingsDelta

    /// 栈顶是否**已被撤销**。`false` ⇒ ↩ 可用；`true` ⇒ ↪ 可用（D78）。
    /// ⚠️ 深度 1 的栈用**一个布尔**表达 undo/redo 两个位，而不是两个数组 ——
    ///    「↩ 和 ↪ 同时可用」「已撤销却还能再撤」这类坏状态因此不可表达。
    var isUndone: Bool

    /// ⚠️ **显式构造器，不用自动生成的那个**（codex plan-R1，**已核实为真**）。
    ///    自动构造器要求实参**按存储属性声明顺序**给标签；Task 5 要往本结构里加第三个字段
    ///    `defaultDelta`，一旦它插在中间、或调用处顺序写反，就是一个**编译期**错误 ——
    ///    而卡住的正好是风险最高的成对回滚那一步。写死一个显式签名，把顺序收在这一处：
    ///    将来再加字段只需在**这里**追加一个带默认值的尾参，既有调用点一处都不用动。
    init(drawingsDelta: DrawingsDelta, isUndone: Bool) {
        self.drawingsDelta = drawingsDelta
        self.isUndone = isUndone
    }
}
```

**3b. `TrainingEngine.swift`：在类体末尾（`:1425` 那个 `}` 之前）加撤销栈区块：**

```swift
    // MARK: 撤销栈（1b-ii 撤销 PR）—— D74 存引擎 / D75 入栈点 / D101 入栈条件

    /// 深度 1 的撤销栈（D25：不跨画线会话保留，故**绝不落盘**）。
    /// **存引擎不存 DrawingSession** 的两条理由（D74）：
    ///   ① 撤销要在 `drawings` 上按**精确下标**操作，那是引擎的私有存储；
    ///   ② 入栈点必须与写入点同处 —— 四个写入 API 全在引擎里，放这儿「写了却忘了入栈」
    ///      在结构上不可能发生。放 UI 层则每个调用点都要记得入栈，1b-i 的 D56 已经证明
    ///      「靠调用方记得」是错的。
    private var drawingUndoEntry: DrawingUndoEntry?

    /// ④↩ 亮的条件（D78）：栈非空**且**栈顶尚未被撤销。
    /// ⚠️ **与选中态无关、与几何无关** —— 撤销是会话级操作，不需要选中任何线，也不需要那条线
    ///    此刻看得见。这是本片唯一**不**共享 `selectionGeometryVisible` 的底栏判据，属**刻意不对称**，
    ///    后人不要"顺手统一"（D78 逐字）。
    var canUndoDrawing: Bool { drawingUndoEntry.map { !$0.isUndone } ?? false }

    /// ⑤↪ 亮的条件（D78）：存在一个**已被撤销**的栈顶。理由同上，刻意不对称。
    var canRedoDrawing: Bool { drawingUndoEntry?.isUndone ?? false }

    /// 清空撤销栈。**两类调用者共用同一个函数**（语义都是"栈作废"）：
    ///   ① 会话状态**真翻转**时（D74 / D103，见 begin/end/cancel 三处）；
    ///   ② 有人绕过栈直接改了 `drawings`、让已存下标失准时（D79 第一层，Task 4）。
    private func clearDrawingUndoStack() { drawingUndoEntry = nil }

    /// 入栈单点。**唯一**被四个写入 API 的成功路径调用（D75）。
    /// **位置纪律**：必须紧贴 `drawingsRevision += 1` —— D80 之后
    /// 「`drawingsRevision` 递增 ⟺ `drawings` 内容真的变了」是不变量，而入栈条件**恰好等于**它（D101）。
    /// 同条件同位置 ⇒ 「入栈与 revision 不同步」这个坏状态不可表达，而不是靠实施者两处都记得写。
    private func recordDrawingUndoDelta(_ delta: DrawingUndoEntry.DrawingsDelta) {
        // 深度 1：新动作直接**覆盖**栈顶，redo 位随之清空（`isUndone: false`）——
        // D25：做了新动作 → ↪ 置灰。
        drawingUndoEntry = DrawingUndoEntry(drawingsDelta: delta, isUndone: false)
    }
```

**3c. 四个写入 API 的成功路径各加一行**（**只加这一行**，门列表一字不改）：

`deleteDrawing(id:)`（`:1115` 附近），把
```swift
        drawings.remove(at: i)
        drawingsRevision += 1
```
改成
```swift
        let removed = drawings[i]
        drawings.remove(at: i)
        recordDrawingUndoDelta(.removed(before: removed, at: i))      // D75
        drawingsRevision += 1
```

`appendDrawing`（`:1133` 附近），把
```swift
        drawings.append(drawing)
        drawingsRevision += 1
```
改成
```swift
        drawings.append(drawing)
        recordDrawingUndoDelta(.inserted(after: drawing, at: drawings.count - 1))   // D75
        drawingsRevision += 1
```

`updateDrawingStyle`（`:1186` 附近），把
```swift
        drawings[i] = updated
        drawingsRevision += 1
```
改成
```swift
        drawings[i] = updated
        recordDrawingUndoDelta(.replaced(before: old, after: updated, at: i))       // D75
        drawingsRevision += 1
```

`setDrawingLocked`（`:1209` 附近），把 `drawings[i] = DrawingObject(...)` 那一整段改成**先造再赋值**：
```swift
        // ⚠️ 参数内部名必须仍是 `newLocked`、且必须**就地构造不抽 helper** ——
        //    L12 守卫（TrainingEngineDrawingSessionTests.swift:992）数的是
        //    「非拷贝直传的 `locked:` 写入恰好 1 处」，抽 helper 会让它误判。
        //    引入 `let updated` 不影响它（仍是就地构造，`locked: newLocked` 字面仍在本函数体内）。
        let updated = DrawingObject(
            id: old.id, toolType: old.toolType, anchors: old.anchors,
            isExtended: old.isExtended, panelPosition: old.panelPosition,
            revealTick: old.revealTick, period: old.period,
            lineSubType: old.lineSubType, lineStyle: old.lineStyle,
            thickness: old.thickness, colorToken: old.colorToken,
            labelMode: old.labelMode,
            locked: newLocked,                                                 // ← 唯一真正改动的字段
            text: old.text, fontSize: old.fontSize,
            textColorToken: old.textColorToken, textForm: old.textForm,
            tailAnchor: old.tailAnchor)
        drawings[i] = updated
        recordDrawingUndoDelta(.replaced(before: old, after: updated, at: i))       // D75
        drawingsRevision += 1
```

**3d. `#if DEBUG` extension（`:1480-1494`）末尾加两个钩子：**

```swift
    /// 仅测试：**只读**栈顶，用来断言"入栈了什么"（N-N4 要求断言**栈内容**，不是只断言行为）。
    var drawingUndoEntryForTesting: DrawingUndoEntry? { drawingUndoEntry }

    /// 仅测试：直接种一条栈项，用来构造生产入口**造不出**的坏状态
    /// （N-N2 的三个陈旧栈 case：越界 / id 对不上 / insert 时 id 已存在）。
    /// ⚠️ `Sources/` 中调用点必须恒为 **0**（Task 3 的守卫 U-G3 钉死）。
    func injectDrawingUndoEntryForTesting(_ entry: DrawingUndoEntry?) { drawingUndoEntry = entry }
```

- [ ] **Step 4: 跑测试确认全绿**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t1.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t1.log | tail -2 || exit 1
git -C "$repo" status --short
```
预期：swift-testing 条数 = **1907 + 9 = 1916**（本 task 新增 9 条 `@Test`）；XCTest 条数**回填到本计划的基线行**（预期仍是 288，本 task 不加 XCTest）；`git status --short` 输出为空以外的内容只应是本 task 改的文件。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift
git commit -m "feat(drawing): 撤销栈数据结构 + 四个写入 API 入栈（D75/D101）"
```

- [ ] **Step 6: 变异验证（**提交之后**，G-4 次序铁律）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M1 | `appendDrawing` 的 `at: drawings.count - 1` 改成 `at: 0` | 「下标必须是追加后的位置」 | `appendPushesInserted` |
| U-M2 | `deleteDrawing(id:)` 的 `recordDrawingUndoDelta` 整行删掉 | 删线根本没入栈 | `deleteByIdPushesRemoved` |
| U-M3 | `updateDrawingStyle` 的 `.replaced(before: old, ...)` 改成 `.replaced(before: updated, ...)` | before 拍错成改动后 | `updateStylePushesReplaced` |
| U-M4 | 把 `recordDrawingUndoDelta` 挪到 `guard updated != old else { return true }` **之前** | no-op 冲掉真编辑 | `noopStyleEditDoesNotClobberTop` |
| U-M5 | `setDrawingLocked` 的幂等 `guard old.locked != newLocked else { return true }` 之后补一行入栈 | 幂等路径误入栈 | `idempotentLockDoesNotPush` |

每条：`cp` 原文件到 `/tmp` → 改 → 跑 → 记**红的测试名** → `cp` 回 → `git status --short` **必须为空** → 下一条。

---

### Task 2: 清栈生命周期 —— 绑「真翻转」而非「调了 activate/deactivate」（D74 + D103）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
  （`cancelDrawingAllPanels:1361` / `beginDrawingSession:1399,1402` / `endDrawingSessionIfActive:1418` 四个站点）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`（追加一个 suite）
- Create: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`（守卫 U-G1）

**Interfaces:**
- Consumes：Task 1 的 `canUndoDrawing` / `clearDrawingUndoStack()` / `drawingUndoEntryForTesting`
- Produces：三个函数体内**字面出现**的 `clearDrawingUndoStack()`（守卫 U-G1 的锚点）；`DrawingUndoSourceGuardTests`（XCTest 类，后续 task 往里加守卫）

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingUndoStackTests.swift`：

```swift
@Suite("1b-ii 撤销：会话生命周期与撤销栈（D74 + D103）")
@MainActor
struct DrawingUndoSessionLifecycleTests {

    /// 造「已进画线模式 + 栈非空」。**必须走真实入栈路径**（不许用 inject 钩子）——
    /// spec N-N3 原稿那条恒过测试的错误就是拿一条根本没经过被测路径的状态去断言。
    static func drawingModeWithNonEmptyStack() -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.canUndoDrawing == true, "前置：栈必须非空")
        return e
    }

    // ── 两条**必须清**（且都是**非 UI 触发**的退出路径） ──

    @Test("N-Q1 下单成交：advanceAndAccount 隐式结束会话 → 栈必须清空")
    func tradeTriggeredClearsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        // ⚠️ 用 `holdOrObserve` 而不是 `buy(panel:shares:)`：前者是**不需要资金/持仓**的推进路径，
        //    同样走 `advanceAndAccount` → `.tradeTriggered` → `endDrawingSessionIfActive`（:532），
        //    既有测试 `TrainingEngineDrawingHandlerH1Tests.swift:103` 用的就是它。
        e.holdOrObserve(panel: .upper)
        #expect(e.drawingSession.drawingModeActive == false, "前置：下单确实隐式结束了画线会话")
        #expect(e.canUndoDrawing == false)
        #expect(e.canRedoDrawing == false)
        #expect(e.drawingUndoEntryForTesting == nil)
    }

    @Test("N-Q2 cancelDrawingAllPanels（第三条拆除路径）→ 栈必须清空")
    func cancelAllPanelsClearsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        e.cancelDrawingAllPanels()
        #expect(e.drawingSession.drawingModeActive == false)
        #expect(e.canUndoDrawing == false)
        #expect(e.drawingUndoEntryForTesting == nil)
    }

    @Test("N-L 栈生命期：退出画线模式再进入 → ↩ / ↪ 均不可用")
    func reenteringDrawingModeStartsWithEmptyStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        e.toggleDrawingMode()                   // 退出（endDrawingSessionIfActive）
        #expect(e.canUndoDrawing == false)
        e.toggleDrawingMode()                   // 再进
        #expect(e.canUndoDrawing == false)
        #expect(e.canRedoDrawing == false)
    }

    // ── 一条**必须保留**（正向测试，防我们把切周期误当退出路径） ──

    @Test("N-Q3 切周期必须**保留**栈 —— 切周期不结束会话（spec §2.1 的 ⛔ 段）")
    func periodSwitchKeepsStack() {
        // ⚠️ **必须**用 `engineMultiPeriod()`，**不能**用 `TrainingEngine.preview()`（fix-1 修复：
        //    原稿用 `drawingModeWithNonEmptyStack()`/`preview()`，而 preview 的 allCandles 只有
        //    .m3/.m60/.daily（**没有 .m15**），当前组合 (.m60,.daily) 无论 toSmaller（→ 需 .m15）
        //    还是 toLarger（→ 需 .weekly）都会撞 switchPeriodCombo 的「target 周期无数据 → no-op」
        //    守卫 → 切周期请求被挡回、什么都没发生，那三条断言在「什么都没做」的情况下当然全过 ——
        //    证明的不是「切周期不清栈」，而是「什么都不做时状态不变」，测试恒真 = 假守卫，U-M9
        //    （切周期末尾塞一句无条件清栈）测不出来。同一个坑已有先例：
        //    `TrainingEngineDrawingSessionTests.swift:76-80`。
        //    `engineMultiPeriod()` 备了 .m15/.m60/.daily，(.m60,.daily) --toSmaller--> (.m15,.m60)
        //    是能真切成功的。
        let (e, _) = TrainingEngineInteractionTests.engineMultiPeriod()
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .upper)
        e.recordRenderBounds(CGRect(x: 0, y: 0, width: 320, height: 480), panel: .lower)
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.canUndoDrawing == true, "前置：栈必须非空")
        let topBefore = e.drawingUndoEntryForTesting?.isUndone

        e.switchPeriodCombo(direction: .toSmaller)   // (.m60,.daily) → (.m15,.m60) 真的能切成功

        #expect(e.upperPanel.period == .m15, "周期真的变了（防假绿：不是撞 no-op 守卫）")
        #expect(e.lowerPanel.period == .m60)
        #expect(e.drawingSession.drawingModeActive == true,
                "切周期后必须仍在画线模式（restoreDrawingSessionAfterPeriodChange 刻意保留会话）")
        #expect(e.canUndoDrawing == true, "同一个会话没结束 → 撤销记录必须留着")
        #expect(e.drawingUndoEntryForTesting?.isUndone == topBefore, "栈内容不得被动过")

        // ③（控制者裁决补于 Task 3，spec §2.6 N-Q3 第 ③ 条，计划原稿只写了 ①②）：
        //    切周期之后点 ↩ 必须能正确撤掉**切换之前**画的那条线 —— 这是 Task 3 才有 `undoDrawing()`
        //    实现之后才补得上的断言，Task 2 落地时 undo/redo 尚不存在，只能先断言栈"没被清"。
        #expect(e.drawings.map(\.id) == ["A"], "前置：那条线切周期之后还在（未被期间切换清掉）")
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == [], "↩ 必须撤掉切周期之前画的那条线 A")
    }

    // ── 两条**必须保留**（把「清栈写在函数入口」那种实现直接测红，D103） ──

    @Test("N-Q4 被拒的 begin 必须保留栈（未实现工具 → 早退，无任何状态翻转）")
    func rejectedBeginKeepsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        // ⚠️ `DrawingToolType` **不是** CaseIterable（Models.swift:37 实测），没有 `allCases`。
        //    直接点名 `.trend`，并**当场断言它确实不在 implemented 里** —— 将来 P1c 把 .trend
        //    实现了，本断言会红，逼实施者换一个仍未实现的工具，而不是让本档静默失效。
        #expect(DrawingToolType.implemented == [.horizontal], "implemented 变了 → 本档的早退前提失效")
        e.beginDrawingSession(tool: .trend)     // 第一行 guard implemented 早退
        #expect(e.canUndoDrawing == true, "被拒的 begin 一个状态都没翻，绝不许清栈")
    }

    @Test("N-Q5 冗余的 begin-while-active 必须保留栈（activate 幂等，无翻转）")
    func redundantBeginKeepsStack() {
        let e = Self.drawingModeWithNonEmptyStack()
        e.beginDrawingSession(tool: .horizontal)   // 会话已开，再调一次
        #expect(e.drawingSession.drawingModeActive == true)
        #expect(e.canUndoDrawing == true,
                "D103：activate 幂等、没有翻转 —— 清栈若写在函数入口/activate 旁边无条件执行，本条必红")
    }
}
```

新建 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`：

```swift
// ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift
// Spec: 2026-08-11-...-1b-ii-lock-undo-design.md §2.6（N-S / N-N3 的守卫那半）+ 计划决策 D102/D103
//
// 本文件是 XCTest（不是 swift-testing）：与 SourceGuardScanner.swift 的既有守卫同族，
// 且 `swift test | tail -3` 那行汇总**不包含** XCTest —— 判绿必须另读
// `Executed N tests, with 0 failures`（计划 Global Constraints G-3）。
//
// 纪律（G-5，缺一即失效）：结构计数不写黑名单；匹配前剥注释剥字面量；每条配双向自检。
import XCTest
@testable import KlineTrainerContracts

// ⚠️ 下面三个助手必须在**文件作用域**（类外），不能写成 `XCTestCase` 的实例方法
//    （codex plan-R7 high，**已核实为真**）：Task 4 的 `engineDrawingsWritesByFunction` 是文件级函数，
//    从它里面调实例方法 Swift 解析不了，整个守卫文件**编译不过**，后续所有 task 全部卡住。
//    放文件作用域后，XCTest 类与那个文件级函数**用的是同一份判据**，也不会漂移。

/// 读某个源文件的**保留边界**代码文本（剥注释、剥字符串字面量，但**保留空白**）。
/// 函数体切片必须在它上面做，见 `functionBodies` 的说明。
func boundaryCodeOf(_ path: String) throws -> String {
    codeTextPreservingBoundaries(try String(contentsOfFile: path, encoding: .utf8))
}

/// 取某个函数（含同名重载，全部）的**函数体**，返回值已 `squeeze`，可直接与 squeeze 过的 needle 比对。
    ///
    /// ⚠️ **必须在"保留边界"的文本上切，且用大括号配对定边界**（codex plan-R5 high，**已核实为真**）。
    ///    原稿是「在 `squeezedSource` 上切，从 `func <name>(` 到**下一个** `func ` 为止」——
    ///    `squeezedSource` 把空白**全删了**，`func ` 这个带空格的边界**永远匹配不到**
    ///    （`private func foo` 变成 `privatefuncfoo`），于是切出来的"函数体"一路吃到文件末尾。
    ///    后果：「某个调用在不在这个函数里」退化成「在不在这个文件里」——
    ///    U-G1 / U-G7 会在"要求的调用其实写在后面另一个函数里"时**假绿**，
    ///    而 U-G4 的逐函数计数（每个先出现的函数都会把后面所有写入算进来）**根本无法满足**。
    ///    也**不能**改成"在 squeezed 文本里找裸 `func` token"——`private`/`static` 前缀会让
    ///    `func` 紧邻标识符字符，token 边界在 squeeze 之后已经不存在了。
    ///
    /// 空数组 = 锚点失效，**调用方必须当场 XCTFail**，不得当成"零处、很干净"。
func functionBodies(_ code: String, funcName: String) -> [String] {
    let chars = Array(code)
    func isIdentChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    let kw = Array("func ")
    var out: [String] = []
    var i = 0
    while i + kw.count <= chars.count {
        guard Array(chars[i ..< i + kw.count]) == kw else { i += 1; continue }
        if i > 0, isIdentChar(chars[i - 1]) { i += 1; continue }   // `func` 必须是独立 token
        var j = i + kw.count
        while j < chars.count, chars[j] == " " { j += 1 }
        var name = ""
        while j < chars.count, isIdentChar(chars[j]) { name.append(chars[j]); j += 1 }
        guard name == funcName else { i += 1; continue }
        while j < chars.count, chars[j] != "{" { j += 1 }          // 走到函数体开头
        guard j < chars.count else { break }
        var depth = 0, k = j, body = ""
        while k < chars.count {                                    // 大括号配对定结束
            if chars[k] == "{" { depth += 1 }
            else if chars[k] == "}" { depth -= 1; if depth == 0 { break } }
            if depth >= 1 { body.append(chars[k]) }
            k += 1
        }
        out.append(squeeze(body))
        i = k
    }
    return out
}

/// 单函数版（无重载时用）。抓不到 / 抓到多个都当场 `XCTFail` —— 返回空串会让所有
/// "必须包含"断言恒假、"不得包含"断言恒真，守卫静默失效（G-5 的锚点纪律）。
func functionBody(_ code: String, funcName: String,
                  file: StaticString = #filePath, line: UInt = #line) -> String {
    let bodies = functionBodies(code, funcName: funcName)
    guard bodies.count == 1 else {
        XCTFail("锚点失效：func \(funcName) 抓到 \(bodies.count) 个函数体（期望恰好 1）",
                file: file, line: line)
        return ""
    }
    return bodies[0]
}

final class DrawingUndoSourceGuardTests: XCTestCase {

    /// U-G1（N-S）：凡含 `drawingSession.activate(` 或 `drawingSession.deactivate(` 的函数，
    /// **必定**也含 `clearDrawingUndoStack()`。当前应命中三个函数。
    /// ⚠️ **不许**写成「只准出现在 begin/end 内」—— 那条在 `cancelDrawingAllPanels` 这行
    ///    **既有合法代码**上就是红的（spec §2.1 codex R4-F2）。
    /// ⚠️ 本守卫**拦不住**「清栈写在函数入口无条件执行」—— 那种实现照样共处、却会在早退与
    ///    冗余调用上误清。那一半由**行为测试** N-Q4 / N-Q5 兜住，**两者缺一不可**。
    func test_uG1_sessionFlipFunctionsAllClearUndoStack() throws {
        let code = try boundaryCodeOf(trainingEnginePath)      // ⚠️ 切函数体必须用保留边界的文本（R5）
        let expected = ["cancelDrawingAllPanels", "beginDrawingSession", "endDrawingSessionIfActive"]
        var hit: [String] = []
        for name in expected {
            let body = functionBody(code, funcName: name)
            XCTAssertFalse(body.isEmpty, "\(name) 函数体为空 —— 锚点失效")
            let touchesSession = body.contains(squeeze("drawingSession.activate("))
                              || body.contains(squeeze("drawingSession.deactivate("))
            XCTAssertTrue(touchesSession, "\(name) 里应当有 activate/deactivate —— 代码被挪走了，本守卫需重定位")
            XCTAssertTrue(body.contains(squeeze("clearDrawingUndoStack()")),
                          "\(name) 翻转了会话状态却没有清栈调用（N-S）")
            hit.append(name)
        }
        XCTAssertEqual(hit.count, 3)
    }

    /// U-G1 的**双向自检**：合成一段「含 deactivate 但不含清栈」的函数体必须被判出来，
    /// 合成一段「两者都含」的必须通过（防 pattern 打错字 → 恒真 → 守卫恒绿）。
    func test_uG1_scanner_is_not_vacuous() {
        let bad  = functionBodies(codeTextPreservingBoundaries(
            "private func f() { drawingSession.deactivate() }"), funcName: "f")
        let good = functionBodies(codeTextPreservingBoundaries(
            "private func f() { drawingSession.deactivate(); clearDrawingUndoStack() }"), funcName: "f")
        XCTAssertEqual(bad.count, 1, "`private func` 前缀不得让 func token 识别失败（R5 点名的坑）")
        XCTAssertTrue(bad[0].contains(squeeze("drawingSession.deactivate(")))
        XCTAssertFalse(bad[0].contains(squeeze("clearDrawingUndoStack()")), "缺清栈的样本必须被判出来")
        XCTAssertTrue(good[0].contains(squeeze("clearDrawingUndoStack()")))

        // ⭐R5 点名要的那条：要求的调用只存在于**后面另一个函数**里，绝不能被算给前一个函数。
        let leaked = functionBodies(codeTextPreservingBoundaries("""
            func a() { drawingSession.deactivate() }
            func b() { clearDrawingUndoStack() }
            """), funcName: "a")
        XCTAssertEqual(leaked.count, 1)
        XCTAssertFalse(leaked[0].contains(squeeze("clearDrawingUndoStack()")),
            "函数体切片吃到了下一个函数 —— 这正是 R5 报的缺陷（原稿用 `func ` 当边界，squeeze 后永不匹配）")

        // 嵌套大括号（闭包 / if 块）不得让配对提前收尾
        let nested = functionBodies(codeTextPreservingBoundaries(
            "func c() { if x { y() }; clearDrawingUndoStack() }"), funcName: "c")
        XCTAssertTrue(nested[0].contains(squeeze("clearDrawingUndoStack()")), "嵌套块让函数体提前截断了")

        // 锚点失效必须返回空数组（调用方据此 XCTFail），不得静默返回一个空函数体
        XCTAssertTrue(functionBodies(codeTextPreservingBoundaries("func g() {}"),
                                     funcName: "zzzNoSuchFunc").isEmpty)
    }
}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t2-red.log | tail -20
grep -E "Test Case .*uG1.* failed|✘ Test .*(tradeTriggered|cancelAllPanels|reentering|periodSwitch|rejectedBegin|redundantBegin)" /tmp/undo-t2-red.log | head
```
预期：`test_uG1_sessionFlipFunctionsAllClearUndoStack` **失败**（三个函数都还没有清栈调用）；`tradeTriggeredClearsStack` / `cancelAllPanelsClearsStack` / `reenteringDrawingModeStartsWithEmptyStack` **失败**（栈没被清）。
`periodSwitchKeepsStack` / `rejectedBeginKeepsStack` / `redundantBeginKeepsStack` 此刻应**已经绿**（还没人清栈）—— 这是正常的，它们是**防退化档**，作用在 Step 3 之后。

- [ ] **Step 3: 写最小实现**

`TrainingEngine.swift` 四个站点各改成「先记 was，再调，翻转了才清」。**逐处照抄，不许抽 helper**（理由见 D103）：

`cancelDrawingAllPanels`（`:1361`）：
```swift
        let wasActive = drawingSession.drawingModeActive
        drawingSession.deactivate()                 // 幂等：先落会话真相
        // D74 / D103：清栈绑「drawingModeActive 真的翻转」，不是「进了这个函数」。
        // 本函数是**第三条真实拆除路径**（public，既有测试用它退出画线模式）——
        // 只在 begin/end 清栈会让它退出后残留一个陈旧栈（spec §2.1 codex R4-F2）。
        if wasActive != drawingSession.drawingModeActive { clearDrawingUndoStack() }
```

`beginDrawingSession` 的**回滚**分支（`:1399`）：
```swift
            let wasActive = drawingSession.drawingModeActive
            cancelDrawingAllPanels()          // 回滚（此刻会话仍未开 → fail-closed 守卫放行）
            drawingSession.deactivate()       // 幂等；确保工具/pending 不残留
            if wasActive != drawingSession.drawingModeActive { clearDrawingUndoStack() }   // D103
            return
```

`beginDrawingSession` 的**成功**分支（`:1402`）：
```swift
        let wasActive = drawingSession.drawingModeActive
        drawingSession.activate(tool: tool)   // 两面板都武装好了，才认会话开启
        // ⚠️ D103：`activate` 对 `drawingModeActive` 是**幂等**的（DrawingSession.swift:202 第一行就置 true）。
        //    会话已开时再调一次 begin 会走到这里却**没有翻转** —— 无条件清栈会悄悄抹掉一条有效撤销记录
        //    （用户什么都没做，↩ 就灰了）。N-Q5 就是把那种实现直接测红的档。
        if wasActive != drawingSession.drawingModeActive { clearDrawingUndoStack() }
```

`endDrawingSessionIfActive`（`:1418`）：
```swift
        let wasActive = drawingSession.drawingModeActive
        drawingSession.deactivate()
        if wasActive != drawingSession.drawingModeActive { clearDrawingUndoStack() }   // D103
```

- [ ] **Step 4: 跑测试确认全绿**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t2.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t2.log | tail -2 || exit 1
grep -E "Test Case .*uG1.* passed" /tmp/undo-t2.log || exit 1
git -C "$repo" status --short
```
预期：swift-testing = **1916 + 6 = 1922**；XCTest = **基线 + 2**（U-G1 与它的自检）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift
git commit -m "feat(drawing): 清栈绑会话真翻转（D74/D103）+ N-S 共处守卫"
```

- [ ] **Step 6: 变异验证（提交之后）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M6 | 把成功分支的 `if wasActive != ...` 去掉，改成无条件 `clearDrawingUndoStack()` | 冗余 begin 误清 | `redundantBeginKeepsStack` |
| U-M7 | 把 `endDrawingSessionIfActive` 里的清栈整行删掉 | 退出模式没清 | `reenteringDrawingModeStartsWithEmptyStack` + `tradeTriggeredClearsStack` |
| U-M8 | 把 `cancelDrawingAllPanels` 里的清栈整行删掉 | 第三条拆除路径漏清 | `cancelAllPanelsClearsStack` + `test_uG1_sessionFlipFunctionsAllClearUndoStack` |
| U-M9 | 在 `switchPeriodCombo` 末尾补一句 `clearDrawingUndoStack()` | 把切周期误当退出路径 | `periodSwitchKeepsStack` |
| U-M10 | 把清栈挪到 `beginDrawingSession` **函数入口第一行**（无条件） | 早退路径误清 | `rejectedBeginKeepsStack` + `redundantBeginKeepsStack`（**U-G1 仍绿** —— 这正是「共处守卫单靠自己不够」的证据，必须在报告里点明） |

---

### Task 3: undo / redo 的执行 —— 专用引擎入口 + `applyUndoEntry` 的三道前置条件（D76 + D79 第二层）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（撤销栈区块内追加）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`（追加两个 suite）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`（守卫 U-G2 / U-G3）

**Interfaces:**
- Consumes：Task 1 的 `DrawingUndoEntry` / `drawingUndoEntry` / `clearDrawingUndoStack()` / `injectDrawingUndoEntryForTesting(_:)`
- Produces：
  - `TrainingEngine.undoDrawing() -> Bool`（`@discardableResult`，**internal**）
  - `TrainingEngine.redoDrawing() -> Bool`（`@discardableResult`，**internal**）
  - `TrainingEngine.applyUndoEntry(_:direction:) -> Bool`（**private**，undo/redo 共用的唯一执行单点）
  - `enum DrawingUndoDirection { case undo, redo }`（放 `DrawingUndoEntry.swift`）

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingUndoStackTests.swift`：

```swift
@Suite("1b-ii 撤销：四类动作往返 + 保序 + 深度 1（D76）")
@MainActor
struct DrawingUndoRoundTripTests {

    /// 造一个已进画线模式的引擎（撤销栈只在画线会话内有意义）。
    static func engine() -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        return e
    }
    static func line(_ id: String, _ e: TrainingEngine, price: Double = 50, candleIndex: Int = 0) -> DrawingObject {
        makeStyledHLine(id: id, revealTick: 0, period: e.upperPanel.period,
                        candleIndex: candleIndex, price: price)
    }

    // ── N-M：四类动作各一条「做 → ↩ 复原 → ↪ 重做」+ revision 严格 +1 ──

    @Test("N-M 画线：做 → ↩ 线消失 → ↪ 线回来，revision 每步严格 +1")
    func roundTripAppend() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        let rev = e.drawingsRevision
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == [])
        #expect(e.drawingsRevision == rev + 1, "undo 必须递增 revision（autosave 的输入）")
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == true)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A"])
        #expect(e.drawingsRevision == rev + 2)
        #expect(e.canUndoDrawing == true && e.canRedoDrawing == false)
    }

    @Test("N-M 删线：做 → ↩ 线回来 → ↪ 线又没了")
    func roundTripDelete() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.deleteDrawing(id: "A") == true)
        let rev = e.drawingsRevision
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A"])
        #expect(e.drawingsRevision == rev + 1)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.map(\.id) == [])
    }

    @Test("N-M 改样式：做 → ↩ 回到旧样式 → ↪ 回到新样式")
    func roundTripStyle() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        var s = DrawingDefaultStyle(); s.thickness = 3
        #expect(e.updateDrawingStyle(id: "A", style: s) == true)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1)
        #expect(e.drawings[0].id == "A", "身份不能变（`DrawingObject.==` 排除 id，必须单独断言）")
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].thickness == 3)
    }

    @Test("N-M 锁定：做 → ↩ 回到未锁 → ↪ 回到锁定")
    func roundTripLock() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].locked == false)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].locked == true)
    }

    // ── N-I 保序（D25 / codex R25-high 专项，不可省） ──

    @Test("N-I 保序：删中间那条 → ↩ 必须回到**原下标**，且同价位单击选中的仍是最后画的 C")
    func undoRestoresExactIndexAndZOrder() {
        let e = Self.engine()
        // 同一价位依次画三条**重合**的线 A→B→C（数组序 [A,B,C] = z-order）
        for id in ["A", "B", "C"] {
            #expect(e.appendDrawing(Self.line(id, e, price: 50)) == true)
        }
        #expect(e.deleteDrawing(id: "B") == true)
        #expect(e.drawings.map(\.id) == ["A", "C"])
        #expect(e.undoDrawing() == true)
        // ① 数组**恰为** [A,B,C]：B 回到**下标 1**，不是末尾
        #expect(e.drawings.map(\.id) == ["A", "B", "C"],
                "只断言「B 回来了 / 条数是 3」的话，append 实现也能过 —— 必须断言精确序列")
        // ② 在该价位单击，命中的仍是 C（数组序 = z-order 的用户可见后果）
        let m = DrawingPanelStyleSemanticsTests.mapper()
        let p = CGPoint(x: 50, y: m.priceToY(50))
        let tools: [DrawingToolType: any DrawingTool] = [.horizontal: HorizontalLineTool()]
        #expect(DrawingHitTester.firstHit(in: e.drawings, point: p, mapper: m, tools: tools)?.id == "C",
                "撤销之后单击选中的必须仍是最后画的 C，不是刚撤回来的 B")
        // ↪ 之后数组恰为 [A,C]
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A", "C"])
    }

    // ── N-J redo 不漂移（codex R29-high 专项，改样式 + 锁定各一条） ──

    @Test("N-J redo 不漂移（改样式）：↩ 后改动别处 → ↪ 必须回到 after 快照，不是当前默认")
    func redoUsesAfterSnapshotNotCurrentDefault() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e, price: 50)) == true)
        #expect(e.appendDrawing(Self.line("Z", e, price: 80, candleIndex: 2)) == true)
        var red = DrawingDefaultStyle(); red.colorToken = .red
        #expect(e.updateDrawingStyle(id: "A", style: red) == true)     // A 改成红
        #expect(e.undoDrawing() == true)
        // 中途改动别处：把**本局默认**改成绿，并选中别的线
        var green = DrawingDefaultStyle(); green.colorToken = .green
        e.drawingSession.setDefaultStyle(green)
        e.drawingSession.setMode(.select)
        e.drawingSession.setSelection(id: "Z", panel: .upper)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings.first { $0.id == "A" }?.colorToken == .red,
                "redo 必须用 after 快照 —— 不是绿（当前默认）、也不是原色")
    }

    @Test("N-J redo 不漂移（锁定）：↩ 后改动别处 → ↪ 必须回到锁定态")
    func redoLockUsesAfterSnapshot() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        #expect(e.undoDrawing() == true)
        var green = DrawingDefaultStyle(); green.colorToken = .green
        e.drawingSession.setDefaultStyle(green)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].locked == true)
    }

    // ── N-K 深度 1 / N-N 空栈 / N-N4 不入栈 ──

    @Test("N-K 深度 1：连点两次 ↩ 只回退一步；连点两次 ↪ 只前进一步")
    func depthOneBehaviour() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.appendDrawing(Self.line("B", e, price: 60, candleIndex: 1)) == true)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings.map(\.id) == ["A"])
        let snapshot = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false, "深度 1：第二次 ↩ 无效果")
        expectDrawingsUnchanged(e, snapshot, revisionBefore: rev)
        #expect(e.redoDrawing() == true)
        let after = e.drawings, rev2 = e.drawingsRevision
        #expect(e.redoDrawing() == false, "第二次 ↪ 无效果")
        expectDrawingsUnchanged(e, after, revisionBefore: rev2)
    }

    @Test("N-N 空栈：undo / redo 返回 false、drawings 与 revision 均不动")
    func emptyStackIsNoop() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        e.toggleDrawingMode(); e.toggleDrawingMode()          // 清栈（进出一趟）
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        #expect(e.redoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N-N4：undo / redo **自身不入栈** —— 栈顶仍是那次锁定，不是「撤销锁定」")
    func undoDoesNotPushItself() {
        let e = Self.engine()
        #expect(e.appendDrawing(Self.line("A", e)) == true)
        #expect(e.setDrawingLocked(id: "A", locked: true) == true)
        #expect(e.undoDrawing() == true)
        guard case .replaced(let before, let after, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced —— 撤销把自己压进去了"); return
        }
        #expect(before.locked == false && after.locked == true,
                "栈顶必须还是**那次锁定**（false→true）。若撤销自己入了栈，这里会变成 true→false")
        #expect(e.drawingUndoEntryForTesting?.isUndone == true, "栈顶被标记为已撤销，而不是产生新栈项")
    }

    // ── N-O 复盘门 ──

    @Test("N-O：复盘模式下 undo / redo 恒 false（D34 纵深防御）")
    func reviewModeRejectsUndoRedo() {
        let e = TrainingEngine.preview(mode: .review)
        e.injectDrawingsForTesting([makeStyledHLine(id: "A")])
        e.injectDrawingUndoEntryForTesting(
            DrawingUndoEntry(drawingsDelta: .replaced(before: makeStyledHLine(id: "A"),
                                                      after: makeStyledHLine(id: "A", thickness: 3), at: 0),
                             isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        #expect(e.redoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }
}

@Suite("1b-ii 撤销：陈旧栈项 fail-closed（D79 第二层）")
@MainActor
struct DrawingUndoStaleEntryTests {

    /// 造「引擎里有一条线 A，但栈里那条记录对不上号」。
    static func engineWithStaleEntry(_ entry: DrawingUndoEntry) -> TrainingEngine {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        e.injectDrawingUndoEntryForTesting(entry)      // 覆盖掉刚才那条真记录
        return e
    }

    @Test("N-N2①：下标越界 → 返 false、**不崩**、数据与 revision 均不动、栈被作废")
    func outOfBoundsIndexFailsClosed() {
        // ⚠️ 这是**崩溃回归测试**：没有它，越界 trap 在测试里表现为整个 xctest 进程挂掉，
        //    而不是一条红断言，容易被误读成环境问题。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .inserted(after: makeStyledHLine(id: "A"), at: 99), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false, "fail-closed：整个栈必须作废")
    }

    @Test("N-N2②：下标在界内但 id 对不上 → false、**那条无辜的线逐字段不变**、栈被作废")
    func identityMismatchFailsClosed() {
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .replaced(before: makeStyledHLine(id: "GHOST"),
                                           after: makeStyledHLine(id: "GHOST", thickness: 3), at: 0),
                  isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings[0].id == "A", "下标 0 上那条无辜的 A 不许被改写")
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    @Test("N-N2③：insert 时 id 已存在（重复 id）→ false、条数不变、栈被作废")
    func duplicateIdOnInsertFailsClosed() {
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .removed(before: makeStyledHLine(id: "A"), at: 0), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false, "undo「删线」要 insert 一条 id=A 的线，但 A 已经在数组里（D66）")
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings.count == 1)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    // ── 修复轮 1（评审 Important，控制者核实为计划缺陷）：①②③ 按 case 枚举，
    //    但 applyUndoEntry 每个 case 都有**两道**门（越界 + 身份/去重），共 6 个判据点；
    //    ①②③ 每个 case 只钉住其中一道，另外三道删掉不会有任何测试变红或变崩。
    //    本仓纪律「修整族判据、不只修报到的那个点」在这里适用，补三条各只隔离一道门 ──

    @Test("N-N2④：remove 分支（undo 画线 / redo 删线共用）身份门单独隔离 —— 下标在界内但 id 对不上")
    func removeBranchIdentityMismatchFailsClosed() {
        // ⚠️ 下标 0 在界内，越界门不会先触发 —— 这条才真的只测身份门（remove(at:) 那一支）。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .inserted(after: makeStyledHLine(id: "GHOST"), at: 0), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings[0].id == "A", "下标 0 上那条无辜的 A 不许被删掉")
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    @Test("N-N2⑤：insert 分支（undo 删线 / redo 画线共用）越界门单独隔离 —— id 不存在，去重门不会先触发")
    func insertBranchOutOfBoundsFailsClosed() {
        // ⚠️ 这也是**崩溃回归测试**：insert(_:at:) 越界同样是 trap，不是红断言。
        //    故意用一个数组里不存在的 id（"Z"），这样「id 已存在」那道去重门不会先触发，隔离出的就是越界门。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .removed(before: makeStyledHLine(id: "Z"), at: 99), isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.drawings.count == 1)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }

    @Test("N-N2⑥：replaced 分支越界门单独隔离 —— 下标越界，不涉及任何身份判断")
    func replacedBranchOutOfBoundsFailsClosed() {
        // ⚠️ 崩溃回归测试：`drawings[index] = target` 越界同样是 trap，不是红断言。
        let e = Self.engineWithStaleEntry(
            .init(drawingsDelta: .replaced(before: makeStyledHLine(id: "A"),
                                           after: makeStyledHLine(id: "A", thickness: 3), at: 99),
                  isUndone: false))
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false)
    }
}
```

追加到 `DrawingUndoSourceGuardTests.swift`：

```swift
    /// U-G2（D79 第三条 + D76）：`undoDrawing` / `redoDrawing` **不接受任何外部参数**，
    /// 且执行单点 `applyUndoEntry` **恰好被这两个函数各调 1 次**（共 2 次）。
    /// ⚠️ 「不接受外部参数」不是风格 —— 那个签名**本身就是信任边界**（spec §2.3 逐字）：
    ///    它保证恢复用的只能是引擎自己吐出的、已经过完整门列表的快照，所以才可以不走
    ///    D60 / D61 那些防外部坏数据的门。一旦允许传参，「撤销」就变成了一个绕过全部门的写入面。
    func test_uG2_undoRedoTakeNoExternalArgumentsAndShareOneApplySite() throws {
        let code = try squeezedSource(trainingEnginePath)
        XCTAssertTrue(code.contains(squeeze("func undoDrawing() -> Bool")), "undoDrawing 必须无参")
        XCTAssertTrue(code.contains(squeeze("func redoDrawing() -> Bool")), "redoDrawing 必须无参")
        // ⚠️ `callCount` = 总出现数 **减去** 定义处数（按 `"func"+pattern` 扣）⇒ 定义本身**不计**。
        //    故期望值是 **2**（undo / redo 各 1 处调用），不是 3。写成 3 会让本守卫恒红。
        XCTAssertEqual(callCount(inSqueezed: code, pattern: squeeze("applyUndoEntry(")), 2,
                       "应为 undo / redo 各 1 处调用 = 2（定义已被 callCount 自动扣除）；多了说明出现了第二条执行路径")
        // 两个入口都不得 public/package/open（信任边界的第二半）
        try expectEngineInternalOnly("undoDrawing()")
        try expectEngineInternalOnly("redoDrawing()")
    }

    /// U-G3：撤销栈的两个测试钩子**不得有任何生产使用**。
    ///
    /// ⚠️ **必须连 `TrainingEngine.swift` 一起扫**（codex plan-R4，**已核实为真**）：
    ///    钩子的声明**和引擎侧全部撤销实现在同一个文件里**。把整个文件过滤掉 ⇒
    ///    `undoDrawing` / `applyUndoEntry` 里真冒出一句 `injectDrawingUndoEntryForTesting(...)`
    ///    会被整段丢掉、守卫照样全绿 —— 而那种调用绕过快照与全部前置校验，能种一条**任意的**
    ///    陈旧栈项，随后删掉或改写**另一条**线（D79 要防的崩溃级 / 静默改写那一族）。
    ///    **正确判据**：引擎之外零处；`TrainingEngine.swift` 里**恰好等于"声明本身"的处数**（各 1）。
    ///    多出一处 = 引擎自己在用它。
    func test_uG3_testOnlyHooksHaveNoProductionUse() throws {
        // ── 引擎之外：两个钩子一处都不许出现 ──
        for hook in ["injectDrawingUndoEntryForTesting", "drawingUndoEntryForTesting"] {
            let outside = try filesMentioning(hook).filter { !$0.hasSuffix("/TrainingEngine.swift") }
            XCTAssertTrue(outside.isEmpty, "\(hook) 被引擎之外的生产文件提到：\(outside)")
        }
        // ── 引擎之内（R4 补上的关键那一半）──
        // 用**裸标识符**计数而不是子串计数：`injectDrawingUndoEntryForTesting` 里含的是
        // `DrawingUndoEntryForTesting`（大写 D），与属性名 `drawingUndoEntryForTesting`（小写 d）
        // 大小写不同、互不误计；属性体里的 `drawingUndoEntry` 也不会被算成它。
        // ⚠️ **两个钩子要用两种不同的判据**（实施计划自查实测 `SourceGuardScanner.swift:171-186 / 252-278`）：
        //    · `callCount` = **总出现数 − 定义处数**（定义按 `"func"+pattern` 扣）⇒ 只有声明时它是 **0**，
        //      冒出一次真调用才变 1。所以带括号的注入钩子用它，期望 **0**；
        //      **`callSiteCount` 对每个文件跑的就是它**，因此**根本不需要**把 `TrainingEngine.swift`
        //      过滤掉 —— 当初那个过滤才是 codex plan-R4 报的盲区本身。
        //    · `bareIdentifierReferences` 第 ③ 条明写「后面第一个非空格字符是 `(` 就不算」⇒ 它数的是
        //      **vend**（把方法当值传出去），声明与调用都不计。无括号的那个计算属性只能用它。
        //    两条判据搞反 = 守卫恒真、永远抓不到非法调用（本计划自查实测踩过一次）。
        let injCalls = try callSiteCount("injectDrawingUndoEntryForTesting(")
        XCTAssertTrue(injCalls.isEmpty,
            "注入钩子被生产代码调用了：\(injCalls)。它绕过快照与全部前置校验，能种一条**任意**陈旧栈项去删改另一条线。")
        // 第二层：vend 形式不出现调用 pattern，只数调用会放过它。
        try expectIdentifierNeverVended("injectDrawingUndoEntryForTesting",
                                        inFiles: try filesMentioning("injectDrawingUndoEntryForTesting"))
        // 只读钩子（计算属性，无括号）：引擎之内恰好 1 处 = 那行声明；多出来就是引擎自己在读它。
        XCTAssertEqual(bareIdentifierReferences(inCode: try boundaryCodeOf(trainingEnginePath),
                                                identifier: "drawingUndoEntryForTesting"), 1,
            "应恰好 1 处 = 那个只读计算属性的声明（它无括号，声明本身就算一次裸引用）。")
    }

    /// U-G3 的**反向自检**（codex plan-R4 点名要的）：合成一段「同文件里的生产调用」，
    /// 判据必须数到 2（声明 + 那次非法调用）—— 这正是修正前那版守卫的盲区。
    func test_uG3_scanner_catches_same_file_production_call() {
        let illicit = squeezedText("""
            func undoDrawing() -> Bool { injectDrawingUndoEntryForTesting(nil); return false }
            func injectDrawingUndoEntryForTesting(_ e: DrawingUndoEntry?) { drawingUndoEntry = e }
            """)
        XCTAssertEqual(callCount(inSqueezed: illicit,
                                 pattern: squeeze("injectDrawingUndoEntryForTesting(")), 1,
            "callCount 会**自动扣掉声明**那一处 ⇒ 剩下的 1 就是那次非法调用。数成 0 = 判据坏了或又把整个文件过滤掉了。")
        let clean = squeezedText("""
            func injectDrawingUndoEntryForTesting(_ e: DrawingUndoEntry?) { drawingUndoEntry = e }
            """)
        XCTAssertEqual(callCount(inSqueezed: clean,
                                 pattern: squeeze("injectDrawingUndoEntryForTesting(")), 0,
            "只有声明的样本必须数成 0（声明被自动扣掉）—— 数成 1 说明扣除逻辑的理解又反了")
        // 第二层各管一半：vend 形式不出现调用 pattern，只能靠裸引用判据抓
        let vended = codeTextPreservingBoundaries("func f() { let g = injectDrawingUndoEntryForTesting }")
        XCTAssertEqual(callCount(inSqueezed: squeeze(vended),
                                 pattern: squeeze("injectDrawingUndoEntryForTesting(")), 0,
            "vend 形式没有括号 → 调用计数抓不到它，这正是需要第二层的理由")
        XCTAssertEqual(bareIdentifierReferences(inCode: vended,
                                                identifier: "injectDrawingUndoEntryForTesting"), 1,
            "裸引用判据必须抓到 vend")
    }

    /// U-G2 / U-G3 的**双向自检**。
    func test_uG2_uG3_scanners_are_not_vacuous() throws {
        XCTAssertEqual(callCount(inSqueezed: squeezedText("applyUndoEntry(x)"), pattern: squeeze("applyUndoEntry(")), 1)
        XCTAssertEqual(callCount(inSqueezed: squeezedText("nothing here"), pattern: squeeze("applyUndoEntry(")), 0)
        XCTAssertTrue(try callSiteCount("injectDrawingUndoEntryForTestingZZZ(").isEmpty)
    }
```

⚠️ 新测试文件顶部需补 `import CoreGraphics`（N-I 用到 `CGPoint`）。

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift build --build-tests 2>&1 | tail -20
```
预期：编译失败，`has no member 'undoDrawing'`。

- [ ] **Step 3: 写最小实现**

**3a. `DrawingUndoEntry.swift` 末尾加方向枚举：**

```swift
/// undo / redo 共用同一个执行单点，方向由本枚举表达 —— 两份镜像实现必然漂移（D76 的表格是对称的）。
enum DrawingUndoDirection { case undo, redo }
```

**3b. `TrainingEngine.swift` 撤销栈区块追加：**

```swift
    /// ④↩：撤销一步。返回 `false` = 没做任何事（空栈 / 栈顶已撤销 / 复盘 / 陈旧栈项）。
    /// **不接受任何外部参数** —— 这个签名本身就是信任边界（D76 / D79 第三条）。
    @discardableResult
    func undoDrawing() -> Bool {
        guard flow.mode != .review else { return false }              // N-O：D34 纵深防御
        guard var entry = drawingUndoEntry, !entry.isUndone else { return false }
        guard applyUndoEntry(entry, direction: .undo) else { return false }   // 失败时它内部已作废栈
        entry.isUndone = true
        drawingUndoEntry = entry
        return true
    }

    /// ⑤↪：前进一步。**恒用 `after` 快照，绝不从当前默认样式 / 当前选中态重算**（D25 / D76）。
    @discardableResult
    func redoDrawing() -> Bool {
        guard flow.mode != .review else { return false }
        guard var entry = drawingUndoEntry, entry.isUndone else { return false }
        guard applyUndoEntry(entry, direction: .redo) else { return false }
        entry.isUndone = false
        drawingUndoEntry = entry
        return true
    }

    /// undo / redo 的**唯一**执行单点（D79 第三条：它俩共用这一个私有函数）。
    ///
    /// **为什么不复用四个写入 API**（本片最容易做错的一处，D76 逐条）：
    ///   · `insert(at:)` 根本不存在 —— `appendDrawing` 只能 append，用它撤销删除会把线放到数组末尾
    ///     = **z-order 变了**，之后在同一位置单击选中的不再是原来那条（D25 / D33 / D40 点名的正是这个）；
    ///   · `updateDrawingStyle` 会被 D60 的 locked 门与 D61 的 raw-aware 门挡住 →
    ///     「撤销一条带未来数据线的锁定」直接走不通。
    /// **那些门为什么可以不走**：它们防的是**外部传进来的坏数据**；而 before / after 是引擎自己刚才
    /// 吐出来的、**已经过完整门列表**的快照。
    ///
    /// **D79 第二层：前置条件逐 case 写死，任一不成立 → 返 `false`、`drawings` 不动、
    /// `drawingsRevision` 不递增、并把整个撤销栈作废**（fail-closed，不留半吊子状态）。
    /// ⚠️ Swift 数组越界是 **trap（进程直接崩）**，`do/catch` 接不住；不越界但身份对不上时，则是
    ///    **删掉 / 改写了另一条线**，然后 `drawingsRevision += 1` 让这个坏状态被 autosave 固化。
    ///    所以校验必须在**任何一次突变之前**跑完。
    ///
    /// ⚠️ **本函数自身绝不入栈**（D79 第三条）：不调 `recordDrawingUndoDelta`，也不经过四个写入 API。
    ///    否则「撤销一次锁定」会把这次撤销本身又推进栈里，第二次点 ↩ 的行为无法定义。
    private func applyUndoEntry(_ entry: DrawingUndoEntry, direction: DrawingUndoDirection) -> Bool {
        switch (entry.drawingsDelta, direction) {

        // 目标操作：remove(at: index)
        case (.inserted(let obj, let index), .undo), (.removed(let obj, let index), .redo):
            guard drawings.indices.contains(index), drawings[index].id == obj.id else {
                clearDrawingUndoStack(); return false
            }
            drawings.remove(at: index)

        // 目标操作：insert(obj, at: index)
        case (.inserted(let obj, let index), .redo), (.removed(let obj, let index), .undo):
            guard (0...drawings.count).contains(index),
                  !drawings.contains(where: { $0.id == obj.id })          // 防 D66 的重复 id
            else { clearDrawingUndoStack(); return false }
            drawings.insert(obj, at: index)

        // 目标操作：drawings[index] = obj
        case (.replaced(let before, let after, let index), _):
            let target = (direction == .undo) ? before : after
            guard drawings.indices.contains(index), drawings[index].id == target.id else {
                clearDrawingUndoStack(); return false
            }
            drawings[index] = target
        }

        drawingsRevision += 1     // 照常触发 autosave（D56：与四个写入 API 同一个 dirty 信号）
        return true
    }
```

- [ ] **Step 4: 跑测试确认全绿**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t3.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t3.log | tail -2 || exit 1
grep -E "Test Case .*(uG2|uG3).* passed" /tmp/undo-t3.log || exit 1
git -C "$repo" status --short
```
预期：swift-testing = **1922 + 14 = 1936**；XCTest = 基线 + 6。
⚠️ 修复轮 1（评审 Important）后 N-N2 又补了④⑤⑥三条（见上方 N-N2 段落 + 变异表 U-M13b/U-M14b/U-M12b），
   最终实测 swift-testing = **1936 + 3 = 1939**；XCTest 不受影响，仍为原基线 + 6（本次未加新 XCTest）。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift \
        ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift \
        ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/
git commit -m "feat(drawing): undoDrawing/redoDrawing + applyUndoEntry 三道前置条件（D76/D79②）"
```

- [ ] **Step 6: 变异验证（提交之后）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M11 | `.removed` 的 undo 分支把 `drawings.insert(obj, at: index)` 改成 `drawings.append(obj)` | 保序（z-order） | `undoRestoresExactIndexAndZOrder` |
| U-M12 | 越界 guard 的 `drawings.indices.contains(index)` 删掉 | 崩溃级陈旧下标 | `outOfBoundsIndexFailsClosed`（**表现为进程崩，不是红断言** —— 报告里必须写明这一点） |
| U-M13 | 身份 guard 的 `drawings[index].id == target.id` 删掉 | 改写了无辜的线 | `identityMismatchFailsClosed` |
| U-M14 | insert 分支的 `!drawings.contains(where:)` 删掉 | 重复 id | `duplicateIdOnInsertFailsClosed` |
| U-M15 | 三处 `clearDrawingUndoStack()` 改成 `return false`（不作废） | fail-closed 只做了一半 | 三条 N-N2 的最后那句 `canUndoDrawing == false` |
| U-M16 | `redo` 分支的 `target = after` 改成 `target = drawings[index]` | redo 从当前态重算 | `redoUsesAfterSnapshotNotCurrentDefault` |
| U-M17 | `undoDrawing` 里补一句 `recordDrawingUndoDelta(...)` | 撤销自己入栈 | `undoDoesNotPushItself` |
| U-M18 | `guard flow.mode != .review` 删掉 | 复盘门 | `reviewModeRejectsUndoRedo` |
| U-M18b | 在 `undoDrawing` 里加一句 `injectDrawingUndoEntryForTesting(nil)`（**同文件**的非法生产调用） | R4 报的那个守卫盲区 | `test_uG3_testOnlyHooksHaveNoProductionUse`（修正前那版守卫**会全绿** —— 报告里点明这就是 R4 的价值） |
| U-M19 | `drawingsRevision += 1` 删掉 | autosave 的输入没了 | `roundTripAppend` / `roundTripDelete` |
| U-M13b | remove 分支（`.inserted`+undo / `.removed`+redo）的身份 guard `drawings[index].id == obj.id` 删掉 | 身份门单独隔离（修复轮 1） | `removeBranchIdentityMismatchFailsClosed` |
| U-M14b | insert 分支的越界 guard `(0...drawings.count).contains(index)` 删掉 | 越界门单独隔离（修复轮 1） | `insertBranchOutOfBoundsFailsClosed`（**很可能表现为进程崩，不是红断言**，与 U-M12 同理） |
| U-M12b | replaced 分支的越界 guard `drawings.indices.contains(index)` 删掉 | 越界门单独隔离（修复轮 1） | `replacedBranchOutOfBoundsFailsClosed`（**很可能表现为进程崩，不是红断言**，与 U-M12 同理）

---

### Task 4: D79 第一层（根因）—— 写入面穷尽守卫 + 两个绕过口子作废栈

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`
  （`deleteDrawing(at:):1089-1093` / `injectDrawingsForTesting:1492`）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`（新增 `engineDrawingsWritesByFunction`，**与 `functionBodies` 同文件**）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDrawingSessionTests.swift:1015-1030`（**L12b：5 → 8**）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`（N-N3a/b）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`（守卫 U-G4）

**Interfaces:**
- Consumes：Task 3 的 `applyUndoEntry`、既有 `engineDrawingsStructuralWrites(_:)`（`SourceGuardScanner.swift:299`，**入参必须是 squeeze 过的文本**）、Task 2 的 `functionBodies` / `boundaryCode`
- Produces：`func engineDrawingsWritesByFunction(_ squeezedCode: String, functions: [String]) -> [String: Int]`（测试模块顶层函数）

**D79 第一层的权威分类表（本片实施后的最终状态，L12b 与 U-G4 都从这一张表派生）：**

| # | 位置 | 性质 | 对栈的表态 | 结构性写入计数 |
|---|---|---|---|---|
| 1 | `init` 的 `self.drawings = seededLossy.drawings` | **构造**（不是替换） | 无需动作（新引擎的栈按定义为空） | 0（不是结构性写入） |
| 2 | `deleteDrawing(id:)` | 四写入 API | **入栈** | 1（`remove(`） |
| 3 | `appendDrawing` | 四写入 API | **入栈** | 1（`append(`） |
| 4 | `updateDrawingStyle` | 四写入 API | **入栈** | 1（下标赋值） |
| 5 | `setDrawingLocked` | 四写入 API | **入栈** | 1（下标赋值） |
| 6 | `deleteDrawing(at:)` | **零生产调用点**，但会移位下标 | **作废整个栈** | 1（`remove(`） |
| 7 | `injectDrawingsForTesting` | 仅测试可达 | **作废整个栈** | 0（`drawings = ds` 不是结构性写入） |
| 8 | `applyUndoEntry` | 撤销执行单点 | **既不入栈也不作废** | **3**（`remove(` + `insert(` + 下标赋值） |
| | | | **合计** | **8** |

**为什么 6 和 7 要作废而不是入栈**：两者都绕过栈直接改数组、且会让已存的下标失准，但它们都不是「用户动作」，入栈没有语义（用户撤销不了一次测试注入）。作废是唯一正确的表态。
**7 尤其不能省** —— 不作废的话，任何「先种一个非空栈、再注入一批线」的测试都会造出一个**下标必然错位**的引擎却全绿，正是本仓的假绿套路。

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingUndoStackTests.swift`（放进 `DrawingUndoStaleEntryTests` suite）：

```swift
    // ── N-N3：绕过栈的写入面必须**作废**栈（D79 第一层，根因）──
    // ⚠️ 必须在**同一个引擎实例**上做。spec 原稿用 `resumePendingReplay` 举证是错的：
    //    那条路径走 `TrainingEngine.make(...)` 造的是**全新引擎**，新引擎的栈本来就是空的
    //    → 测试恒过、证明不了任何事（codex R2-F1）。

    @Test("N-N3a：injectDrawingsForTesting 换一批线 → 撤销栈必须作废")
    func injectDrawingsInvalidatesStack() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.canUndoDrawing == true, "前置：栈非空")
        e.injectDrawingsForTesting([makeStyledHLine(id: "X"), makeStyledHLine(id: "Y", candleIndex: 4)])
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false, "栈必须已作废")
        let before = e.drawings, rev = e.drawingsRevision
        #expect(e.undoDrawing() == false)
        expectDrawingsUnchanged(e, before, revisionBefore: rev)
    }

    @Test("N-N3b：deleteDrawing(at:)（零生产调用点、但会移位下标）→ 撤销栈必须作废")
    func deleteByIndexInvalidatesStack() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 1, price: 60)) == true)
        #expect(e.canUndoDrawing == true)
        e.deleteDrawing(at: 0)                       // 把 B 的下标从 1 移到了 0 —— 栈里那条记录当场失准
        #expect(e.canUndoDrawing == false && e.canRedoDrawing == false, "栈必须已作废")
    }
```

追加到 `DrawingUndoSourceGuardTests.swift`：

```swift
    /// U-G4（D79 第一层，**穷尽性判据**）：`TrainingEngine.swift` 里 `drawings` 的结构性写入点，
    /// **全部**落在下表这 6 个具名函数里，且每个函数的处数与表一致；表外**零处**。
    ///
    /// ⚠️ 这条比既有 L12b（只数总数）强一档：总数对不上会红，但「把一处写入从 appendDrawing
    ///    挪到一个新的私有 helper 里」总数不变、L12b 全绿，而那个 helper 就是一条**没对栈表过态**
    ///    的新写入面。本条按**判据本身**穷尽（每处写入必须归属于表里某个函数），不是按这次
    ///    报告到的点位改。
    ///
    /// ⚠️ 作用域**只是 `TrainingEngine.swift`**，不是全 `Sources/` 的同名变量：
    ///    `drawings` 是 `public private(set)`，setter 是**文件作用域**，别的文件根本写不了它。
    func test_uG4_engineDrawingsWriteSitesAreExhaustivelyClassified() throws {
        let code = try boundaryCodeOf(trainingEnginePath)        // ⚠️ 切函数体用保留边界的文本（R5）
        let squeezed = try squeezedSource(trainingEnginePath)  // 全文件总数仍用 squeezed
        let expected: [String: Int] = [
            "deleteDrawing":           2,   // (at index:) 1 处 + (id:) 1 处 —— 两个重载同名，合并计数
            "appendDrawing":           1,
            "updateDrawingStyle":      1,
            "setDrawingLocked":        1,
            "applyUndoEntry":          3,   // remove + insert + 下标赋值
            "injectDrawingsForTesting": 0,  // `drawings = ds` 是整体替换，不计入结构性写入
        ]
        let byFunc = engineDrawingsWritesByFunction(code, functions: Array(expected.keys))
        for (name, want) in expected {
            XCTAssertEqual(byFunc[name], want,
                           "\(name) 的结构性写入处数应为 \(want)，实测 \(byFunc[name].map(String.init) ?? "锚点失效")")
        }
        // 表外零处：逐函数之和 == 全文件总数
        let total = engineDrawingsStructuralWrites(squeezed)
        XCTAssertEqual(byFunc.values.reduce(0, +), total,
                       """
                       有 \(total - byFunc.values.reduce(0, +)) 处 drawings 写入不在权威分类表里。
                       新增写入面必须先归入 D79 第一层那张表（入栈 / 作废 / 都不做，三选一），
                       再回来改本守卫 —— 不许直接改数字。
                       """)
        XCTAssertEqual(total, 8, "权威分类表的合计是 8（见计划 Task 4 那张表）")
    }

    /// U-G4 的**双向自检**：合成一段「写入落在表外函数里」的样本必须被判出来。
    func test_uG4_scanner_is_not_vacuous() {
        let good = codeTextPreservingBoundaries("func appendDrawing() { drawings.append(x) }")
        XCTAssertEqual(engineDrawingsWritesByFunction(good, functions: ["appendDrawing"])["appendDrawing"], 1)

        // ⭐R5 点名要的那条：写入只存在于**后面另一个函数**里，绝不能被算给前一个函数。
        let leaked = codeTextPreservingBoundaries("""
            func appendDrawing() { }
            private func sneakyHelper() { drawings.append(x) }
            """)
        XCTAssertEqual(engineDrawingsWritesByFunction(leaked, functions: ["appendDrawing"])["appendDrawing"], 0,
            "切片吃到了下一个函数 —— 这正是 codex plan-R5 报的缺陷（原稿用 `func ` 当边界，squeeze 后永不匹配）")
        XCTAssertEqual(engineDrawingsStructuralWrites(squeeze(leaked)), 1,
            "全文件总数仍是 1 → 逐函数之和 0 ≠ 1，穷尽性断言会红（表外写入因此暴露）")

        // 同名重载必须**各切各的、累加**（`deleteDrawing` 就是两个重载）
        let overloads = codeTextPreservingBoundaries("""
            func deleteDrawing(at i: Int) { drawings.remove(at: i) }
            func deleteDrawing(id x: String) { drawings.remove(at: 0) }
            """)
        XCTAssertEqual(engineDrawingsWritesByFunction(overloads, functions: ["deleteDrawing"])["deleteDrawing"], 2)

        XCTAssertNil(engineDrawingsWritesByFunction(good, functions: ["noSuchFunc"])["noSuchFunc"],
                     "锚点失效必须返回 nil（缺键），不得静默返回 0")
    }
```

⚠️ **不再往 `SourceGuardScannerTests.swift` 加东西**（R5 后的调整）：逐函数扫描器与它的自检
都留在 `DrawingUndoSourceGuardTests.swift` 里，与 `functionBodies` 同生共死。
跨函数误计那一档已由上面的 `test_uG4_scanner_is_not_vacuous` 覆盖（`leaked` 与 `overloads` 两个合成样本）。

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t4-red.log | tail -20
grep -E "Test Case .*uG4.* failed|✘ Test .*(injectDrawings|deleteByIndex)" /tmp/undo-t4-red.log | head
```
预期：`engineDrawingsWritesByFunction` 未定义 → 编译失败（本步的"红"）；补上扫描器后 `injectDrawingsInvalidatesStack` / `deleteByIndexInvalidatesStack` **失败**（还没作废栈），L12b 以 `n == 5` **失败**（实际 8）。

- [ ] **Step 3: 写最小实现**

**3a. `DrawingUndoSourceGuardTests.swift` 追加（与 `functionBodies` 同文件）：**

```swift
/// 按**具名函数**统计 `drawings` 的结构性写入处数（D79 第一层的穷尽性判据用）。
///
/// ⚠️ 入参是 **`codeTextPreservingBoundaries` 的输出**（保留空白），**不是** `squeezedSource`
///    （codex plan-R5 high，**已核实为真**）：squeeze 之后 `func ` 这个边界永远匹配不到，
///    每个先出现的函数都会把它后面所有函数的写入算到自己头上 —— 逐函数计数根本无法满足。
///    切片改由本文件的 `functionBodies` 用**大括号配对**完成（它返回的 body 已 squeeze，
///    正好是 `engineDrawingsStructuralWrites` 需要的形态）。
/// 同名重载（`deleteDrawing` 有 `(at:)` 与 `(id:)` 两个）会被**逐个**切片并累加 —— 这正是我们要的。
/// ⚠️ 找不到某个函数名 → 该键**缺席**（返回的字典里没有它），**不返回 0** ——
///    调用方的 `XCTAssertEqual(byFunc[name], want)` 会因 `nil != 某数` 而红，锚点失效因此出声。
/// ⚠️ 本函数依赖 `functionBodies`，故与它**同文件**（放 `DrawingUndoSourceGuardTests.swift`，
///    **不放** `SourceGuardScanner.swift`）—— 两个判据必须同生共死，分居两处必然漂移。
func engineDrawingsWritesByFunction(_ code: String, functions: [String]) -> [String: Int] {
    var out: [String: Int] = [:]
    for name in functions {
        let bodies = functionBodies(code, funcName: name)
        guard !bodies.isEmpty else { continue }        // 缺席 = 锚点失效，让调用方红
        out[name] = bodies.reduce(0) { $0 + engineDrawingsStructuralWrites($1) }
    }
    return out
}
```

**3b. `TrainingEngine.swift` 两处补作废：**

`deleteDrawing(at index:)`（`:1089`）：
```swift
    func deleteDrawing(at index: Int) {
        precondition(drawings.indices.contains(index), "deleteDrawing index out of bounds")
        drawings.remove(at: index)
        // D79 第一层：本方法**绕过撤销栈**直接改数组，且会让栈里已存的下标全部失准。
        // 它不是「用户动作」（零生产调用点），入栈没有语义 —— **作废**是唯一正确的表态。
        clearDrawingUndoStack()
        drawingsRevision += 1
    }
```

`injectDrawingsForTesting`（`:1492`，在 `#if DEBUG` extension 里）：
```swift
    /// ⚠️ D79 第一层：整体换掉 `drawings` 会让栈里已存的下标必然错位。**必须作废栈** ——
    ///    不作废的话，任何「先种一个非空栈、再注入一批线」的测试都会造出一个下标必然错位的
    ///    引擎却全绿，正是本仓的假绿套路（N-N3a 就是钉这一条的）。
    func injectDrawingsForTesting(_ ds: [DrawingObject]) {
        drawings = ds
        clearDrawingUndoStack()
    }
```

⚠️ `clearDrawingUndoStack()` 是 `private`，而 `injectDrawingsForTesting` 在**同一个文件**的 extension 里 → 可访问。**不要**为了这个把它改成 internal。

**3c. `TrainingEngineDrawingSessionTests.swift:1015-1030` 的 L12b：期望值 5 → 8，并把注释改对：**

```swift
    @Test("L12b: TrainingEngine 里 drawings 的结构性写入点恰好 8 处（穷尽性，多一处即红）")
    @MainActor func engineDrawingsWriteSurfaceIsExhaustive() throws {
        let code = try squeezedSource(trainingEnginePath)
        let n = engineDrawingsStructuralWrites(code)
        // 1b-ii 撤销 PR 后的构成（每一处都必须能对上号，见该 PR 计划 Task 4 的权威分类表）：
        //   drawings.remove(at:) ×3  → deleteDrawing(at:) / deleteDrawing(id:) / applyUndoEntry
        //   drawings.append(     ×1  → appendDrawing
        //   drawings.insert(     ×1  → applyUndoEntry
        //   drawings[x] =        ×3  → updateDrawingStyle / setDrawingLocked / applyUndoEntry
        // ⚠️ 锁定 PR 时这里的注释预估「PR-2 期望值改为 6」——**那个预估是错的**：
        //   applyUndoEntry 一个函数里就有三处结构性写入（remove/insert/下标赋值），不是一处。
        #expect(n == 8, """
            drawings 结构性写入点应为 8，实际 \(n)。
            多了 = 出现了未经分类的新写入面（可能绕过路由/几何/唯一性三道门，或漏了对撤销栈表态）；
            少了 = 判据坏了或某个写入面被挪走。两种都必须查清再改期望值，不许直接改数字。
            **归属**由同族守卫 U-G4（DrawingUndoSourceGuardTests）逐函数钉死。
            """)
    }
```

- [ ] **Step 4: 跑测试确认全绿**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t4.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t4.log | tail -2 || exit 1
grep -E "Test Case .*uG4.* passed" /tmp/undo-t4.log || exit 1
git -C "$repo" status --short
```
预期：swift-testing = **1936 + 2 = 1938**（N-N3a / N-N3b；扫描器自检已并入 XCTest 那边）；XCTest = 基线 + 8。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "feat(drawing): D79 第一层 —— 写入面穷尽守卫 U-G4 + 两个绕过口子作废栈（L12b 5→8）"
```

- [ ] **Step 6: 变异验证（提交之后）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M20 | `injectDrawingsForTesting` 里的 `clearDrawingUndoStack()` 删掉 | 整体替换后下标错位 | `injectDrawingsInvalidatesStack` |
| U-M21 | `deleteDrawing(at:)` 里的 `clearDrawingUndoStack()` 删掉 | 移位下标 | `deleteByIndexInvalidatesStack` |
| U-M22 | 把 `appendDrawing` 里的 `drawings.append(drawing)` 挪进一个新私有 helper `func sneakyAppend()` | **表外新写入面** | `test_uG4_engineDrawingsWriteSitesAreExhaustivelyClassified`（**L12b 仍绿** —— 这正是 U-G4 比 L12b 强一档的证据，报告里必须点明） |
| U-M23 | 故意新增一处 `drawings.append(x)` | 穷尽性 | L12b + U-G4 **双红** |

---

### Task 5: D102 「一次动作」作用域 + 本局默认成对回滚（**G-0 的硬约束，本片风险最高的一 task**）

> ⛔ **本 task 落地的是自动选中 spec §12 明确写着「override 不覆盖」的那一条。**
> 若发现难以落地，**必须回来改计划并重跑评审**，不得以任何理由降级。
> 缺了它的后果不是"少个功能"：**被撤销掉的样式会在下一笔新画的线上、以及断点续训之后复活**，
> 且经 `drawingsRevision` / `defaultStyle` 两条 autosave 触发被**落盘固化**。

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingUndoEntry.swift`（加 `DrawingDefaultStyleDelta` + `defaultDelta` 分量）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift`（作用域 + `applyUndoEntry` 恢复默认那一半）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift:253-296`（`applyPanelStyleMutation` 整个函数体包进作用域）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/CoordinatorDefaultStyleSourceGuardTests.swift:15-24`（**G1：4 → 5**）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`（追加 suite）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`（守卫 U-G5）

**Interfaces:**
- Consumes：Task 3 的 `applyUndoEntry`、`DrawingEditRouter.applyPanelStyleMutation`（`DrawingEditRouter.swift:253`）、`DrawingSession.defaultStyle` / `setDefaultStyle(_:)`（`DrawingSession.swift:154/158`）、测试搭台 `DrawingPanelStyleSemanticsTests.drawModeWithSelected(...)`（同测试模块，`internal` 可直接调）
- Produces：
  - `struct DrawingDefaultStyleDelta { let before: DrawingDefaultStyle; let after: DrawingDefaultStyle }`
  - `DrawingUndoEntry.defaultDelta: DrawingDefaultStyleDelta?`（**带默认值 `= nil`**，故 Task 1/3 的既有构造调用点**不受影响**、不用改）
  - `TrainingEngine.performDrawingAction(_ body: () -> Void)`（**internal**，唯一调用点 = `applyPanelStyleMutation`）

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingUndoStackTests.swift`：

```swift
@Suite("1b-ii 撤销：画线态改样式的成对回滚（D102 + 自动选中 spec §10.1）")
@MainActor
struct DrawingUndoPairedRollbackTests {

    /// 「画线态 + 上面板一条已选中的线 + mapper 已发布」。直接复用自动选中片的搭台函数
    /// （同一个测试模块，internal 可达）—— 另抄一份必然与它漂移。
    static func drawModeEngine(locked: Bool = false) -> TrainingEngine {
        DrawingPanelStyleSemanticsTests.drawModeWithSelected(
            id: "A", locked: locked, colorToken: .orange, thickness: 1)
    }

    // ── ⭐ 交接 §10.1 点名的**必配回归**：一并回滚、一并重做 ──

    @Test("⭐成对回滚：画线态改样式 → ↩ → 线与本局默认**双双**回到改动前")
    func undoRollsBackBothLineAndSessionDefault() {
        let e = Self.drawModeEngine()
        #expect(e.drawings[0].thickness == 1)
        #expect(e.drawingSession.defaultStyle.thickness == 1, "前置：默认与线都是 1")

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawings[0].thickness == 3, "前置：那条线真的被改了")
        #expect(e.drawingSession.defaultStyle.thickness == 3, "前置：本局默认也真的被改了（两处写入）")

        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1, "线必须回到改动前")
        #expect(e.drawingSession.defaultStyle.thickness == 1,
                """
                本局默认也必须回到改动前。
                只回滚线不回滚默认 ⇒ 被撤销掉的样式会在**下一笔新画的线**上复活，
                而且经 autosave 落盘、断点续训之后还在（自动选中 spec §10.1 逐字）。
                """)
    }

    @Test("⭐成对重做：↪ → 线与本局默认**双双**回到改动后")
    func redoRestoresBothLineAndSessionDefault() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.undoDrawing() == true)
        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].thickness == 3)
        #expect(e.drawingSession.defaultStyle.thickness == 3)
    }

    @Test("⭐成对：两处写入只产生**一条**栈记录（深度 1 下第二条会把第一条挤掉 = 交接点名的坏结果）")
    func pairProducesExactlyOneEntry() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        guard case .replaced(let before, let after, _) = e.drawingUndoEntryForTesting!.drawingsDelta else {
            Issue.record("栈顶不是 replaced"); return
        }
        #expect(before.thickness == 1 && after.thickness == 3, "drawings 那一半必须是这次改动本身")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta?.before.thickness == 1)
        #expect(e.drawingUndoEntryForTesting?.defaultDelta?.after.thickness == 3)
        // 深度 1：只有一条 → 撤销一次就回到起点，再撤无效
        #expect(e.undoDrawing() == true)
        #expect(e.undoDrawing() == false, "两处写入若各入一条，这里会是 true —— 那正是要防的")
    }

    // ── D101：只改默认、没碰线 → 不入栈（含已接受残留的正面证据） ──

    @Test("D101：画线态那条线被锁 → 只有默认变了 → **不入栈**，栈顶保持原样（已接受残留）")
    func lockedLineMeansDefaultOnlyChangeIsNotPushed() {
        let e = Self.drawModeEngine(locked: true)
        #expect(e.drawingSession.selectedDrawingID == "A")

        // 造一条**真**栈顶（修复轮 2，opus 评审 Important）：appendDrawing 一条新线 B。
        // ⚠️ `drawModeWithSelected` 内部是 `appendDrawing(A)` → `toggleDrawingMode()`，而
        //    `toggleDrawingMode` → `beginDrawingSession` 会清空撤销栈（U-G1 钉死）—— 所以进入
        //    本测试体时栈其实**已经是空的**，旧版在这里断言「先造一条真记录」是句假话，
        //    `topBefore == nil` 恒成立，后面的 `defaultDelta == nil` 因为 entry 本身是 nil 而
        //    恒真，对「误给栈顶挂上默认分量」这类缺陷零判别力。这里补一条**真**记录堵住它。
        //    `appendDrawing` 不改选中，选中仍是锁定的 A —— 后面「只改默认」的语义不变。
        #expect(e.appendDrawing(makeStyledHLine(id: "B", revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 1, price: 60)) == true)
        #expect(e.drawingSession.selectedDrawingID == "A", "appendDrawing 不改选中")
        #expect(e.canUndoDrawing == true, "前置：栈顶必须是真记录")
        #expect(DrawingUndoPushTests.topShape(e) == "inserted(B)@1", "前置：栈顶确实是 inserted(B)")

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawingSession.defaultStyle.thickness == 3, "默认确实变了")
        #expect(e.drawings[0].thickness == 1, "线锁着，applyStyle 被 D60 拒 —— A 没被改")

        // 栈顶必须原样保留（不被这次「只改默认」的动作覆盖 / 误清）—— 这是本条的判别力核心。
        #expect(DrawingUndoPushTests.topShape(e) == "inserted(B)@1",
                "栈顶必须仍是 inserted(B)@1，不许被这次只改默认的动作顶替或清空")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "只改默认不入栈（D101）：inserted(B) 那条本来就没有默认分量，这次也不该被挂上")
        #expect(e.canUndoDrawing == true)
    }

    // ── ⭐ 落盘往返：成对回滚必须**作为同一份状态**存下去、再一起读回来（codex plan-R9）──

    @Test("⭐落盘往返（undo）：画线态改样式 → ↩ → 存档 → 续局 → 线与本局默认**双双**是改动前那一侧")
    func pairedUndoSurvivesSaveAndResume() async throws {
        let (coord, _, _, _) = TrainingSessionPersistenceTests.makeCoordinator(
            candles: TrainingSessionPersistenceTests.validCandles())
        coord.now = { 222 }
        let e = try await coord.startNewNormalSession()
        e.toggleDrawingMode()
        // ⚠️ 线起手是 2，**不是** 1 —— 见下方 resumed 断言旁的承重注释：1 恰好是
        //    DrawingDefaultStyle() 的出厂值，用它会让这条测试对「读回被整个关掉」零判别力
        //    （修复轮 1 实测踩过：U-M30b/U-M30c 曾各有一条方向巧合绿过）。
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 2, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 10)) == true)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(DrawingPanelStyleSemanticsTests.mapper(), panel: .upper)

        // 先把本局默认从出厂值 1 挪到 2（线本来就是 2 → 这次 mutation 对线是 no-op，
        // 按 D101 不产生新的 drawings 入栈；下面确认这一点符合预期）。
        let topShapeBeforeNoop = DrawingUndoPushTests.topShape(e)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 2 }, engine: e)
        #expect(e.drawingSession.defaultStyle.thickness == 2, "前置：默认已离开出厂值 1")
        #expect(e.drawings[0].thickness == 2, "前置：线对这次 mutation 是 no-op（本来就是 2）")
        // D101：drawings 没变 → 不产生新记录；栈顶形状不得因为这次「只改默认」的 no-op 而改变。
        #expect(DrawingUndoPushTests.topShape(e) == topShapeBeforeNoop, "no-op 动作不该改变栈顶形状")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "no-op 动作不该给栈顶带上 defaultDelta（无论栈顶是否存在）")

        // 真正的成对编辑：默认 2→4、线 2→4。
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 4 }, engine: e)
        #expect(e.drawings[0].thickness == 4 && e.drawingSession.defaultStyle.thickness == 4)
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 2 && e.drawingSession.defaultStyle.thickness == 2,
                "↩ 之后线与默认都必须回到「改动前」= 2（不是出厂值 1）")

        try await coord.saveProgress(engine: e)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())

        // ⭐ 两半必须落在**同一侧**。只测 revision +1 证明不了这一条：
        //    autosave 的排序 / 合并一旦出问题，完全可能把「已回滚的线」和「没回滚的默认」一起存下去，
        //    于是被撤销掉的样式在续训之后、在下一笔新画的线上复活 —— 正是 D102 要防的那个高代价形态。
        // ⚠️ **这里刻意不用 1**：1 是 DrawingDefaultStyle() 的出厂值 —— 如果「读回」那一侧
        //    （`TrainingSessionCoordinator` 里 `pending.drawingDefaultStyle` 那句 `setDefaultStyle`）
        //    被整个关掉，续局引擎的默认样式会静默回落到出厂值 1，而「改动前」这个数字本身如果也
        //    恰好是 1，这条断言就会对「读回被关掉」这类缺陷**零判别力**（修复轮 1 实测发现的真问题：
        //    U-M30b/U-M30c 曾各让本条巧合放行一次）。改成 2 之后，出厂值 1 ≠ 期望值 2，
        //    读回被关掉时会如实变红。
        #expect(resumed.drawings.first { $0.id == "A" }?.thickness == 2, "线必须是改动前那一侧")
        #expect(resumed.drawingSession.defaultStyle.thickness == 2,
                "本局默认必须**同样**是改动前那一侧（非出厂值 1，见上方注释）")
        // 顺带钉住验收 #17：撤销栈不跨局（新引擎的栈按定义为空）
        #expect(resumed.canUndoDrawing == false && resumed.canRedoDrawing == false)
    }

    /// ⚠️ 本条对「删掉 `applyUndoEntry` 里恢复默认那一句」（U-M30c）**没有判别力** —— 那种实现下
    ///    默认值全程没被 undo/redo 触碰、一直停在「改动后」的值，而本条期望的正是该值，恒绿。
    ///    **该缺陷由 `pairedUndoSurvivesSaveAndResume` 捕获**（它期望的是「改动前」那一侧，
    ///    且刻意取了非出厂值）。两条不是对称的强度，别被后人误读成两条都强。
    @Test("⭐落盘往返（redo）：↩ 后再 ↪ → 存档 → 续局 → 线与本局默认**双双**是改动后那一侧")
    func pairedRedoSurvivesSaveAndResume() async throws {
        let (coord, _, _, _) = TrainingSessionPersistenceTests.makeCoordinator(
            candles: TrainingSessionPersistenceTests.validCandles())
        coord.now = { 222 }
        let e = try await coord.startNewNormalSession()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", thickness: 1, revealTick: 0,
                                                period: e.upperPanel.period,
                                                candleIndex: 0, price: 10)) == true)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(DrawingPanelStyleSemanticsTests.mapper(), panel: .upper)

        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.undoDrawing() == true)
        #expect(e.redoDrawing() == true)

        try await coord.saveProgress(engine: e)
        await coord.endSession()
        let resumed = try #require(try await coord.resumePending())
        #expect(resumed.drawings.first { $0.id == "A" }?.thickness == 3, "线必须是改动后那一侧")
        #expect(resumed.drawingSession.defaultStyle.thickness == 3, "本局默认必须**同样**是改动后那一侧")
    }

    // ── ⭐ D101 不变量：默认分量过期必须丢掉（codex plan-R3 high）──
    //    两个方向各一条 —— codex 只报了 ↪ 那一半，↩ 同样会覆盖用户的新默认。

    @Test("⭐R3-↪ 方向：旧记录已撤销 + 用户又单独改了默认 → ↪ 不得覆盖新默认")
    func staleDefaultDeltaDoesNotClobberOnRedo() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)   // 成对入栈
        #expect(e.undoDrawing() == true)                                             // ↪ 可用
        #expect(e.canRedoDrawing == true)
        #expect(e.drawingSession.defaultStyle.thickness == 1)

        // 让那条线不再够得着（几何判不了），**但不结束会话** → 栈按 N-Q3 原样保留
        e.drawingSession.clearViewportMapper(panel: .upper)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 5 }, engine: e)   // 只改默认
        #expect(e.drawingSession.defaultStyle.thickness == 5, "前置：默认真的变成 5 了")
        #expect(e.drawings[0].thickness == 1, "前置：那条线被几何门拒了，没被改")
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "过期的默认分量必须被丢掉 —— 留着它 ↪ 就会拿旧值覆盖用户刚选的 5")

        #expect(e.redoDrawing() == true)
        #expect(e.drawings[0].thickness == 3, "线那一半仍然有效，↪ 照常把它重做回去")
        #expect(e.drawingSession.defaultStyle.thickness == 5,
                "⭐用户刚选的默认 5 必须原样保留 —— 被旧记录的 after 覆盖成 3 就是本条要防的缺陷")
    }

    @Test("⭐R3-↩ 方向（codex 未报，复核补出）：记录尚未撤销 + 用户又单独改了默认 → ↩ 不得覆盖新默认")
    func staleDefaultDeltaDoesNotClobberOnUndo() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)   // 成对入栈，未撤销
        e.drawingSession.clearViewportMapper(panel: .upper)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 5 }, engine: e)   // 只改默认
        #expect(e.drawingSession.defaultStyle.thickness == 5)
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil, "过期的默认分量必须被丢掉")

        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1, "线那一半仍然有效，↩ 照常把它退回去")
        #expect(e.drawingSession.defaultStyle.thickness == 5,
                "⭐用户刚选的默认 5 必须原样保留 —— 被旧记录的 before 覆盖成 1 就是本条要防的缺陷")
    }

    @Test("D101：选择态改样式只写线、不写默认 → 栈记录里 defaultDelta 必须是 nil")
    func selectModeEditHasNoDefaultDelta() {
        let e = DrawingPanelStyleSemanticsTests.selectModeWithSelected(id: "A", colorToken: .orange)
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(e.drawings[0].thickness == 3)
        #expect(e.drawingUndoEntryForTesting?.defaultDelta == nil,
                "选择态本来就不回写默认（D49 的核心价值）→ 这条记录不该带默认分量")
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].thickness == 1)
    }

    @Test("N-R（D80 的 PR-2 侧）：画线态 no-op 点击不冲掉栈顶那次真编辑，↩ 仍回到最初")
    func noopClickInDrawModeDoesNotClobber() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)   // 真编辑
        DrawingEditRouter.applyPanelStyleMutation({ $0.colorToken = .purple }, engine: e)   // 同一个颜色再点一次
        #expect(e.undoDrawing() == true)
        #expect(e.drawings[0].colorToken == .orange, "必须回到**最初**那个色，不是回到紫")
        #expect(e.drawingSession.defaultStyle.colorToken == .orange, "默认也一并回到最初")
    }
}
```

追加到 `DrawingUndoSourceGuardTests.swift`：

```swift
    /// U-G5（D102）：`performDrawingAction` 在 `Sources/` 中的调用点**恰好 1 处**，且在
    /// `DrawingEditRouter.applyPanelStyleMutation` 里；作用域必须包住**整个**函数体
    /// （`performDrawingAction {` 紧跟在函数签名之后）。
    /// ⚠️ 只数调用点不够：把作用域只包住 `.draw` 那一个分支，调用点仍是 1 处、成对回滚的测试也照样绿，
    ///    但选择态那一支就落在作用域之外 —— 将来任何人给选择态补上「顺带写默认」的语义时，
    ///    那一对会静默拆成两条记录。故必须**同时**断言"紧跟在签名之后"。
    /// ⚠️ **2026-08-24 订正**（Task 5 实施中发现并经协调者裁决）：不能用
    ///    `callSiteCount("performDrawingAction(")` —— 它数的是带括号的 pattern，而本函数的调用点
    ///    是**尾随闭包**语法 `engine.performDrawingAction { … }`，源码里根本不出现 `(` ⇒ 那条判据
    ///    恒为 0，与下面第三句「调用点必须正是无括号写法」互斥（两句断言无法被同一份代码同时满足，
    ///    实测确认过）。改用裸标识符判据（同 U-G3 对无括号计算属性的处理）：它对**定义**不计数
    ///    （`func performDrawingAction(` 后面是 `(`），恰好只数尾随闭包调用。**不选**给调用点加空括号
    ///    `performDrawingAction() { … }`（原方案 1）：那是非惯用 Swift，将来「顺手清理」成正常写法
    ///    会静默打破守卫。
    func test_uG5_actionScopeWrapsWholePanelStyleMutation() throws {
        var sites: [(file: String, count: Int)] = []
        for f in try filesMentioning("performDrawingAction") {
            let n = bareIdentifierReferences(inCode: try boundaryCodeOf(f),
                                             identifier: "performDrawingAction")
            if n > 0 { sites.append((f, n)) }
        }
        let total = sites.reduce(0) { $0 + $1.count }
        XCTAssertEqual(total, 1, "performDrawingAction 调用点应恰好 1 处，实测：\(sites)")
        XCTAssertEqual(sites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift"), true,
                       "唯一调用点必须在路由里")

        let router = try squeezedSource(contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path)
        let sig = squeeze("engine: TrainingEngine) { engine.performDrawingAction {")
        XCTAssertTrue(router.contains(sig),
                      "作用域必须紧跟 applyPanelStyleMutation 的签名、包住整个函数体（不是只包 .draw 分支）")
    }

    /// U-G5 的**双向自检**。
    func test_uG5_scanner_is_not_vacuous() throws {
        XCTAssertEqual(bareIdentifierReferences(
            inCode: codeTextPreservingBoundaries("f { engine.performDrawingAction { } }"),
            identifier: "performDrawingAction"), 1, "尾随闭包调用必须被判成裸引用")
        XCTAssertEqual(bareIdentifierReferences(
            inCode: codeTextPreservingBoundaries("func performDrawingAction(_ b: () -> Void) { }"),
            identifier: "performDrawingAction"), 0, "定义本身（后面紧跟 `(`）不得被误计成调用点")

        let onlyDrawBranch = squeezedText("""
            static func applyPanelStyleMutation(_ m: X, engine: TrainingEngine) {
                if session.mode == .draw { engine.performDrawingAction { } }
            }
            """)
        XCTAssertFalse(onlyDrawBranch.contains(squeeze("engine: TrainingEngine) { engine.performDrawingAction {")),
                       "只包住 .draw 分支的样本必须不满足邻接条件")
    }
```

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift build --build-tests 2>&1 | tail -20
```
预期：编译失败，`has no member 'defaultDelta'` / `'performDrawingAction'`。

⚠️ **本步必须额外做一件事**（TDD 的真正价值在这里）：先只加 `defaultDelta` 字段与 `performDrawingAction` 的**空壳**（直接 `body()`，不合并），跑一次 —— 断言 `undoRollsBackBothLineAndSessionDefault` 里**默认那一句**变红（线那一句是绿的）。这就是「只回滚线不回滚默认」那个坏实现的现场证据，**报告里必须记下这次红的输出**。

- [ ] **Step 3: 写最小实现**

**3a. `DrawingUndoEntry.swift`：**

```swift
/// 「本局默认」那一半的前后快照（D102）。
/// ⚠️ **用一个成对的结构而不是两个可选字段** —— `before` 有值而 `after` 没有（或反过来）
///    是个说不通的状态，用两个 `Optional` 就把它变成可表达的了。
struct DrawingDefaultStyleDelta: Equatable {
    let before: DrawingDefaultStyle
    let after: DrawingDefaultStyle
}
```

并给 `DrawingUndoEntry` 加**第三个字段**（放在 `isUndone` **之后**，即声明顺序的**最末**），
同时把 Task 1 那个显式构造器扩成三参、**新参数带默认值 `= nil` 且排在最后**：

```swift
    /// 「本局默认」那一半（D102）。**只有画线态改样式那条路会带** ——
    /// 那一次动作是**两处写入**（那条线 + 本局默认，见 `DrawingEditRouter.applyPanelStyleMutation`
    /// 的 `.draw` 分支）。撤销必须把这一对当**一个**动作一并回滚，否则被撤销掉的样式会在
    /// 下一笔新画的线上、以及断点续训之后复活（自动选中 spec §10.1，**override 不覆盖**）。
    var defaultDelta: DrawingDefaultStyleDelta?

    /// ⚠️ 新参数**必须排在最后且带默认值**（codex plan-R1）：这样 Task 1 / Task 3 里那些
    ///    两参构造点（`DrawingUndoEntry(drawingsDelta:isUndone:)`）**一处都不用改**。
    ///    把它插在中间 = 那些调用点全部编译不过。
    init(drawingsDelta: DrawingsDelta, isUndone: Bool,
         defaultDelta: DrawingDefaultStyleDelta? = nil) {
        self.drawingsDelta = drawingsDelta
        self.isUndone = isUndone
        self.defaultDelta = defaultDelta
    }
```

⚠️ **构造实参一律按 `drawingsDelta` → `isUndone` → `defaultDelta` 的顺序写**，全计划无例外。

**3b. `TrainingEngine.swift` 撤销栈区块：加作用域，并改写 `recordDrawingUndoDelta`：**

```swift
    /// D102：「一次动作」作用域的中间态。`nil` = 当前没有打开的作用域。
    /// ⚠️ 用**一个可选结构**而不是几个平行布尔/可选量 —— 「作用域没开却存着 defaultBefore」
    ///    这类坏状态因此不可表达。
    private struct DrawingActionScope {
        let defaultBefore: DrawingDefaultStyle
        var delta: DrawingUndoEntry.DrawingsDelta?
        var aborted: Bool
    }
    private var drawingActionScope: DrawingActionScope?

    /// D102：把 `body` 里发生的写入合并成**一条**撤销记录。
    ///
    /// **为什么需要它**：自动选中片（D86）让画线态的一次改样式变成**两处写入** ——
    /// 先写「本局默认」（`DrawingSession`），再 best-effort 改「那条线」（引擎）。
    /// 入栈点在引擎的四个写入 API 里（D74/D75），它**看不见**前面那次默认写入；
    /// 照原样各入一条，深度 1 的栈会让第二条把第一条挤掉 —— 正是交接 §10.1 点名的坏结果。
    ///
    /// **为什么不把入栈搬到路由层**：D74 的理由「入栈必须与写入同处，否则'写了却忘了入栈'
    /// 要靠人记」一个字都没过时（1b-i 的 D56 已经证明过一次）。本作用域是在**不破坏**那条理由
    /// 的前提下，补上「一次动作可以跨两个写入面」这件 spec 当时没有的事。
    ///
    /// **唯一调用点** = `DrawingEditRouter.applyPanelStyleMutation`（守卫 U-G5 钉死）。
    /// 其余三条动作路径（删线 / 锁定 / 画线提交）**不包作用域**，写入 API 直接自成一条记录。
    func performDrawingAction(_ body: () -> Void) {
        // 嵌套 = 「哪一层算一个动作」无法定义 → fail-closed：整个外层动作作废，绝不 crash。
        guard drawingActionScope == nil else {
            drawingActionScope?.aborted = true
            body()
            return
        }
        drawingActionScope = DrawingActionScope(
            defaultBefore: drawingSession.defaultStyle, delta: nil, aborted: false)
        body()
        let scope = drawingActionScope
        drawingActionScope = nil

        guard let scope, !scope.aborted else { clearDrawingUndoStack(); return }
        let after = drawingSession.defaultStyle
        let defaultChanged = (after != scope.defaultBefore)

        // D101：`drawings` 没变就不入栈 —— 只改了本局默认的动作**撤不回来**，这是已接受残留。
        guard let delta = scope.delta else {
            // ⚠️ **但不能就这么放着**（codex plan-R3 high，已核实为真）：
            //    栈顶那条记录的默认分量说「默认从 X 变成 Y」，而用户刚刚又把默认改成了 Z。
            //    此后 ↩ 按 X 写回、↪ 按 Y 写回 —— **两个方向都会静默覆盖掉用户刚选的 Z**，
            //    并经 autosave 落盘。不变量：**默认分量两端必须仍与当前默认值对得上**；
            //    对不上就把这一半丢掉。`drawings` 那一半照常保留 —— 那条线根本没被碰过。
            if defaultChanged { drawingUndoEntry?.defaultDelta = nil }
            return
        }
        // ⚠️ 实参顺序 = 声明顺序 `drawingsDelta` → `isUndone` → `defaultDelta`（codex plan-R1）。
        drawingUndoEntry = DrawingUndoEntry(
            drawingsDelta: delta,
            isUndone: false,
            defaultDelta: defaultChanged
                ? DrawingDefaultStyleDelta(before: scope.defaultBefore, after: after) : nil)
    }
```

`recordDrawingUndoDelta` 改成：

```swift
    private func recordDrawingUndoDelta(_ delta: DrawingUndoEntry.DrawingsDelta) {
        if drawingActionScope != nil {
            // 一个作用域内只允许**一次** `drawings` 改动（D102）。第二次到达 = 我们对
            // 「一个动作」的建模已经与现实脱节 → fail-closed 作废，**绝不 crash**
            // （这条路径在生产里不可达，但 crash 会把一个建模问题变成用户可见的闪退）。
            if drawingActionScope?.delta != nil { drawingActionScope?.aborted = true }
            else { drawingActionScope?.delta = delta }
            return
        }
        // 深度 1：新动作直接覆盖栈顶，redo 位随之清空（D25）。
        drawingUndoEntry = DrawingUndoEntry(drawingsDelta: delta, isUndone: false)
    }
```

`applyUndoEntry` 在 `drawingsRevision += 1` **之前**补默认那一半：

```swift
        // D102：本局默认与那条线是**同一个动作**的两半，一并回滚 / 一并重做。
        // 写它会经 `DrawingSession.defaultStyle` 的 @Observable 变化触发 autosave
        // （TrainingView 的 DrawingAutosaveTriggersModifier，D94）—— 本片不新增任何触发器。
        if let dd = entry.defaultDelta {
            drawingSession.setDefaultStyle(direction == .undo ? dd.before : dd.after)
        }
        drawingsRevision += 1
```

**3c. `DrawingEditRouter.swift:253` 把整个函数体包进作用域**（函数体内容一字不改，只加一层）：

```swift
    static func applyPanelStyleMutation(_ mutate: (inout DrawingDefaultStyle) -> Void,
                                        engine: TrainingEngine) {
        // D102（1b-ii 撤销 PR）：画线态的一次改样式是**两处写入**（本局默认 + 那条线）。
        // 包在作用域里，两处合并成**一条**撤销记录 —— undo / redo 一并回滚一并重做。
        // ⚠️ 必须包住**整个**函数体，不是只包 `.draw` 分支：将来任何人给别的分支补上
        //    「顺带写默认」的语义时，那一对不会静默拆成两条（守卫 U-G5 钉死这条邻接关系）。
        engine.performDrawingAction {
            let session = engine.drawingSession
            if session.mode == .draw {
                // …（原有三个分支一字不改）…
            } else if session.selectedDrawingID != nil {
                // …
            } else {
                // …
            }
        }
    }
```

**3d. `CoordinatorDefaultStyleSourceGuardTests.swift:15-24` 的 G1：4 → 5：**

```swift
/// G1（D96 + 自动选中 PR 的 D86 + 1b-ii 撤销 PR 的 D102）：`setDefaultStyle` 的调用点**恰好 5 个** ——
/// `DrawingEditRouter.applyPanelStyleMutation` **2 处** + `resumePending` + `resumePendingReplay`
/// + **`TrainingEngine.applyUndoEntry` 1 处**（撤销 / 前进时把本局默认一并回滚 / 一并重做）。
/// ⚠️ 4→5 是**1b-ii 撤销 PR 有意为之**：D102 让「画线态改样式」的两处写入成为一个可撤销动作，
///    撤销执行单点因此必须能写回默认。这是第五条写默认路径，已按本守卫头注的要求重审并接受。
/// 多于 5 ⇒ 又出现了新的写默认路径，必须再次回来重审；
/// 少于 5 ⇒ 有一处没接上（种子漏接、D86 某分支没写默认，或撤销漏了默认那一半 = 成对回滚失效）。
@Test func g1_setDefaultStyle_has_exactly_five_call_sites() throws {
    let sites = try callSiteCount("setDefaultStyle(")
    let total = sites.reduce(0) { $0 + $1.count }
    #expect(total == 5, "setDefaultStyle 调用点应恰好 5 个，实测 \(total)：\(sites.map { "\($0.file)×\($0.count)" })")
    #expect(sites.first { $0.file.hasSuffix("DrawingEditRouter.swift") }?.count == 2,
            "路由里应恰好 2 处（D86 画线态分支 + 无选中分支），实测：\(sites.map { "\($0.file)×\($0.count)" })")
    #expect(sites.first { $0.file.hasSuffix("TrainingSessionCoordinator.swift") }?.count == 2,
            "coordinator 里应恰好 2 处（resumePending + resumePendingReplay）")
    #expect(sites.first { $0.file.hasSuffix("TrainingEngine.swift") }?.count == 1,
            "引擎里应恰好 1 处（applyUndoEntry 的成对回滚）—— 0 处 = 撤销没回滚默认（D102 失效）")
}
```
⚠️ 函数**改名**（`four` → `five`）后必须确认没有别处引用旧名（`grep -rn g1_setDefaultStyle ios/Contracts/Tests`）。

- [ ] **Step 4: 跑测试确认全绿**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t5.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t5.log | tail -2 || exit 1
grep -E "Test Case .*uG5.* passed" /tmp/undo-t5.log || exit 1
git -C "$repo" status --short
```
预期：swift-testing = **1938 + 10 = 1948**（G1 是既有测试，改名不改数量）；XCTest = 基线 + 10。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "feat(drawing): D102 一次动作作用域 —— 画线态改样式成对回滚（交接 §10.1 硬约束）"
```

- [ ] **Step 6: 变异验证（提交之后）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M24 | `applyUndoEntry` 里 `if let dd = entry.defaultDelta { ... }` 整段删掉 | **只回滚线不回滚默认** | `undoRollsBackBothLineAndSessionDefault` + `g1_setDefaultStyle_has_exactly_five_call_sites` |
| U-M25 | `performDrawingAction` 里 `defaultDelta:` 恒传 `nil` | 默认分量根本没记 | `pairProducesExactlyOneEntry` + `undoRollsBackBothLineAndSessionDefault` |
| U-M26 | 把作用域从整个函数体缩到只包 `.draw` 分支 | 邻接条件 | `test_uG5_actionScopeWrapsWholePanelStyleMutation`（**成对回滚三条仍绿** —— 这正是「只数调用点不够」的证据，报告里点明） |
| U-M27 | `recordDrawingUndoDelta` 在作用域内改成直接压栈（不合并） | 两处写入拆成两条 | `pairProducesExactlyOneEntry`（`undoDrawing()` 第二次会变成 `true`） |
| U-M28 | `guard let delta = scope.delta else { return }` 改成「delta 为空也压一条」 | D101 | `lockedLineMeansDefaultOnlyChangeIsNotPushed`（**修复轮 2 后**用真栈顶验证：`DrawingUndoPushTests.topShape(e)` 从 `inserted(B)@1` 变成 `replaced(A->A)@0`，判别力确认；修复轮 2 之前该测试栈顶恒为 nil，`defaultDelta == nil` 恒真，对本变异**零判别力**——已堵住） |
| U-M29 | `defaultChanged ? ... : nil` 的三元反过来 | 选择态误带默认分量 | `selectModeEditHasNoDefaultDelta` |
| U-M29b | `if defaultChanged { drawingUndoEntry?.defaultDelta = nil }` 整行删掉 | **过期默认分量覆盖用户新选择**（codex plan-R3） | `staleDefaultDeltaDoesNotClobberOnRedo` + `staleDefaultDeltaDoesNotClobberOnUndo` |
| U-M29c | 把那行改成 codex 原处方（`if entry.isUndone { clearDrawingUndoStack() }`） | 只堵了 ↪ 那一半 | `staleDefaultDeltaDoesNotClobberOnUndo`（**↪ 那条会绿** —— 这正是"处方需要加强"的证据，报告里点明） |
| U-M30 | `applyUndoEntry` 里把 `dd.before` / `dd.after` 对调 | 方向反了 | `undoRollsBackBothLineAndSessionDefault` + `redoRestoresBothLineAndSessionDefault` |
| U-M30b | 把 `TrainingSessionCoordinator.swift:331` 那句 `if let s = pending.drawingDefaultStyle { …setDefaultStyle(s) }` 注释掉（**关掉默认那一侧的读回**） | 落盘往返：两半落在**不同侧** | **修复轮 1 后**（`pairedUndoSurvivesSaveAndResume` 改用非出厂值 2 起手）：`pairedUndoSurvivesSaveAndResume` + `pairedRedoSurvivesSaveAndResume` **两条都红**（引擎内的成对回滚三条仍全绿 —— 这正是 codex plan-R9 要的证据：只测 revision 证明不了落盘一致）。⚠️ **修复轮 1 之前**这条曾用 `thickness == 1` 断言，恰好等于 `DrawingDefaultStyle()` 出厂值，`pairedUndoSurvivesSaveAndResume` 那一侧对本变异是巧合绿——该缺陷已堵住，改用非出厂值 2 后两条都能捕获。 |
| U-M30c | 把 `applyUndoEntry` 里恢复默认那一句删掉（**关掉默认那一侧的写出**） | 同上，另一端 | `pairedUndoSurvivesSaveAndResume` + `undoRollsBackBothLineAndSessionDefault` 红；**`pairedRedoSurvivesSaveAndResume` 仍绿**（已接受的机制内在盲区——该实现下默认值全程未被 undo/redo 触碰、一直停在"改动后"的值，而这条期望的正是该值，见该测试上方承重注释；缺陷由 `pairedUndoSurvivesSaveAndResume` 单独捕获，两条不对称）。 |

---

### Task 6: 路由 `undo` / `redo` + 撤销后的选中态（D77）+ ④↩⑤↪ 置灰判据（D78）

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift`（文件末尾追加）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoStackTests.swift`（追加 suite）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawingUndoSourceGuardTests.swift`（守卫 U-G6 / U-G7）

**Interfaces:**
- Consumes：Task 3 的 `undoDrawing()` / `redoDrawing()`、Task 1 的 `canUndoDrawing` / `canRedoDrawing`、既有 `syncSelectionByState(engine:)`（`DrawingEditRouter.swift:181`，**private**）
- Produces：
  - `DrawingEditRouter.undo(engine:) -> Bool` / `redo(engine:) -> Bool`（`@discardableResult`）
  - `DrawingEditRouter.undoButtonEnabled(engine:) -> Bool` / `redoButtonEnabled(engine:) -> Bool`

- [ ] **Step 1: 写失败的测试**

追加到 `DrawingUndoStackTests.swift`：

```swift
@Suite("1b-ii 撤销：路由与选中态（D77）+ 置灰判据（D78）")
@MainActor
struct DrawingUndoRouterTests {

    static func drawModeEngine() -> TrainingEngine {
        DrawingPanelStyleSemanticsTests.drawModeWithSelected(id: "A", colorToken: .orange, thickness: 1)
    }

    // ── N-T：D77 表格四行 ──

    @Test("N-T：undo 把**当前选中**那条线移除 → 选中被清空，🔒 / 🗑 回灰")
    func undoRemovingSelectedLineClearsSelection() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        let d = makeStyledHLine(id: "A", revealTick: 0, period: e.upperPanel.period,
                                candleIndex: 0, price: 50)
        #expect(e.appendDrawing(d) == true)
        e.drawingSession.setCommittedSelection(id: "A", panel: .upper)
        e.drawingSession.setViewportMapper(DrawingPanelStyleSemanticsTests.mapper(), panel: .upper)
        #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == true, "前置：🔒 是亮的")

        #expect(DrawingEditRouter.undo(engine: e) == true)
        #expect(e.drawingSession.selectedDrawingID == nil, "线没了，选中必须被清空（D54 clause 4）")
        #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == false, "🔒 必须回灰")
        #expect(DrawingEditRouter.deleteButtonEnabled(engine: e) == false, "🗑 必须回灰")
    }

    @Test("N-T：undo「改样式」→ 对象还在原下标、身份没变 → 选中**不变**")
    func undoStyleKeepsSelection() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(DrawingEditRouter.undo(engine: e) == true)
        #expect(e.drawingSession.selectedDrawingID == "A", "身份没变，选中必须原样保留")
    }

    @Test("N-T + 交接②：undo「删线」把线恢复回来 → **不自动选中**")
    func undoRestoredLineIsNotAutoSelected() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(e.deleteDrawing(id: "A") == true)
        #expect(e.drawingSession.selectedDrawingID == nil, "前置：删完没有选中")
        #expect(DrawingEditRouter.undo(engine: e) == true)
        #expect(e.drawings.map(\.id) == ["A"], "线确实回来了")
        #expect(e.drawingSession.selectedDrawingID == nil,
                "恢复回来的线**不自动选中**（与 D37「新提交的线不自动选中」一致，交接 §10.1 第 2 条）")
    }

    // ── D78：置灰判据「与选中态无关、与几何无关」 ──

    @Test("D78：↩ / ↪ 的可用性**不看**选中态、**不看**几何（刻意不对称）")
    func undoRedoEnabledIgnoresSelectionAndGeometry() {
        let e = Self.drawModeEngine()
        DrawingEditRouter.applyPanelStyleMutation({ $0.thickness = 3 }, engine: e)
        #expect(DrawingEditRouter.undoButtonEnabled(engine: e) == true)
        #expect(DrawingEditRouter.redoButtonEnabled(engine: e) == false)

        // 清掉选中 + 撤掉 mapper（几何判不了）—— 两个 🔒/🗑 会灰，但 ↩ 必须仍然亮
        e.drawingSession.clearSelection()
        e.drawingSession.clearViewportMapper(panel: .upper)
        #expect(DrawingEditRouter.lockButtonEnabled(engine: e) == false, "对照：🔒 灰了")
        #expect(DrawingEditRouter.undoButtonEnabled(engine: e) == true,
                "撤销是**会话级**操作，不需要选中任何线、也不需要那条线此刻看得见（D78）")

        #expect(DrawingEditRouter.undo(engine: e) == true)
        #expect(DrawingEditRouter.undoButtonEnabled(engine: e) == false)
        #expect(DrawingEditRouter.redoButtonEnabled(engine: e) == true)
    }

    @Test("D78：刚进画线模式什么都没做 → ↩ / ↪ 都是灰的；做了新动作 → ↪ 变灰")
    func enabledPredicatesAtSessionStartAndAfterNewAction() {
        let e = TrainingEngine.preview()
        e.toggleDrawingMode()
        #expect(DrawingEditRouter.undoButtonEnabled(engine: e) == false)
        #expect(DrawingEditRouter.redoButtonEnabled(engine: e) == false)
        #expect(e.appendDrawing(makeStyledHLine(id: "A", revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 0, price: 50)) == true)
        #expect(DrawingEditRouter.undo(engine: e) == true)
        #expect(DrawingEditRouter.redoButtonEnabled(engine: e) == true)
        #expect(e.appendDrawing(makeStyledHLine(id: "B", revealTick: 0, period: e.upperPanel.period,
                                                candleIndex: 1, price: 60)) == true)
        #expect(DrawingEditRouter.redoButtonEnabled(engine: e) == false,
                "做了新动作 → ↪ 失效（D25）")
    }
}
```

追加到 `DrawingUndoSourceGuardTests.swift`：

```swift
    /// U-G6（D77，codex R5-F2）：`undoDrawing(` / `redoDrawing(` 在 `Sources/` 中的调用点
    /// **各恰好 1 处**、都在 `DrawingEditRouter.swift`。
    /// ⚠️ 底栏的 ↩ / ↪ 如果被**直接**接到 `engine.undoDrawing()` 上，引擎侧的往返测试照样全绿，
    ///    可选中态永远不同步 —— 撤销掉的正好是选中那条线时，`selectedDrawingID` 变成一个指向
    ///    已不存在的线的死值：高亮没了、🔒/🗑 灰着、要等用户再点一下别处才恢复。
    func test_uG6_undoRedoHaveExactlyOneRouterCallSiteEach() throws {
        // ⚠️ **不要过滤掉 `TrainingEngine.swift`**（与 codex plan-R4 报的是同一类盲区）：
        //    `callSiteCount` 内部用的 `callCount` 已经把「定义」那一处自动扣掉了，引擎文件本来就
        //    不会因为"声明在那儿"而出现在结果里；一旦过滤，引擎自己**真的调了** undo/redo
        //    （绕过路由 ⇒ 选中态永远不同步）反而看不见。
        for name in ["undoDrawing(", "redoDrawing("] {
            let sites = try callSiteCount(name)
            let total = sites.reduce(0) { $0 + $1.count }
            XCTAssertEqual(total, 1, "\(name) 应恰好 1 个调用点，实测：\(sites)")
            XCTAssertEqual(sites.first?.file.hasSuffix("/Drawing/DrawingEditRouter.swift"), true,
                           "\(name) 的唯一调用点必须是路由（选中态同步只在那里）—— 落在引擎里就是绕过了路由")
        }
    }

    /// U-G7（D77）：路由的 `undo` / `redo` 必须带 `defer { syncSelectionByState(engine: engine) }`，
    /// 且**不得**出现 `commitPendingAndSelect`（交接 §10.1 第 2 条：恢复回来的线不自动选中）。
    func test_uG7_routerUndoRedoSyncSelectionAndNeverAutoSelect() throws {
        let router = try boundaryCodeOf(contractsDirForGuards
            .appendingPathComponent("Sources/KlineTrainerContracts/Drawing/DrawingEditRouter.swift").path)
        // ⚠️ `functionBody` 内部会自己拼上 `(`（needle = `func <name>(`），
        //    所以这里**只能传裸函数名** —— 传 "undo(engine" 会拼成 `func undo(engine(`，
        //    永远匹配不到 ⇒ 走 XCTFail 的锚点失效分支（幸好它会出声，不是静默恒绿）。
        for fn in ["undo", "redo"] {
            let body = functionBody(router, funcName: fn)
            XCTAssertFalse(body.isEmpty, "锚点失效：找不到路由的 \(fn)(engine:)")
            XCTAssertTrue(body.contains(squeeze("defer { syncSelectionByState(engine: engine) }")),
                          "\(fn) 缺少选中态同步 —— D77 的四行全靠它")
            XCTAssertFalse(body.contains(squeeze("commitPendingAndSelect(")),
                           "\(fn) 不得复用 commitPendingAndSelect（交接 §10.1 明令）")
            XCTAssertFalse(body.contains(squeeze("setCommittedSelection(")),
                           "\(fn) 不得建立选中 —— 恢复回来的线不自动选中")
        }
    }

    /// U-G6 / U-G7 的**双向自检**。
    func test_uG6_uG7_scanners_are_not_vacuous() throws {
        XCTAssertTrue(try callSiteCount("undoDrawingZZZ(").isEmpty)
        let bad = squeezedText("static func undo(engine: TrainingEngine) -> Bool { engine.undoDrawing() }")
        XCTAssertFalse(bad.contains(squeeze("defer { syncSelectionByState(engine: engine) }")),
                       "缺 defer 的样本必须被判出来")
    }
```

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift build --build-tests 2>&1 | tail -20
```
预期：编译失败，`type 'DrawingEditRouter' has no member 'undo'`。

- [ ] **Step 3: 写最小实现**

`DrawingEditRouter.swift` 文件末尾（`toggleLockSelected` 之后）追加：

```swift
    // MARK: 撤销 / 前进（1b-ii 撤销 PR，D76 / D77 / D78）—— 形状同上面的删除 / 锁定三件套

    /// ④↩。`undoDrawing` 在 `Sources/` 里的**唯一**调用点（守卫 U-G6）。
    /// `defer` 里的选中态同步是 D77 表格四行的**全部**实现 ——
    /// 判据「选中 id 不在 `visibleDrawings` 里就清空」已经把四行覆盖完，**不新写第二套**（D64）。
    /// ⚠️ **不得**复用 `commitPendingAndSelect`、也不得建立任何选中：
    ///    恢复回来的线**不自动选中**（与 D37 一致，自动选中 spec §10.1 第 2 条明令）。
    @discardableResult
    static func undo(engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        return engine.undoDrawing()
    }

    /// ⑤↪。同上。
    @discardableResult
    static func redo(engine: TrainingEngine) -> Bool {
        defer { syncSelectionByState(engine: engine) }
        return engine.redoDrawing()
    }

    /// **UI 用**：④↩ 是否可用（D78）。
    /// ⚠️ **刻意不含 `selectionGeometryVisible`、也不含任何选中分量** —— 这是本片唯一
    ///    **不**共享几何判据的底栏键。撤销是**会话级**操作：不需要选中任何线，也不需要那条线
    ///    此刻看得见。**后人不要"顺手统一"成和 🔒/🗑 一样的形状**（D78 逐字）。
    static func undoButtonEnabled(engine: TrainingEngine) -> Bool { engine.canUndoDrawing }

    /// **UI 用**：⑤↪ 是否可用（D78）。理由同上，刻意不对称。
    static func redoButtonEnabled(engine: TrainingEngine) -> Bool { engine.canRedoDrawing }
}
```

- [ ] **Step 4: 跑测试确认全绿**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t6.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t6.log | tail -2 || exit 1
grep -E "Test Case .*(uG6|uG7).* passed" /tmp/undo-t6.log || exit 1
git -C "$repo" status --short
```
预期：swift-testing = **1948 + 5 = 1953**；XCTest = 基线 + 13。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "feat(drawing): 路由 undo/redo + 选中态同步（D77）+ ↩↪ 置灰判据（D78）"
```

- [ ] **Step 6: 变异验证（提交之后）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M31 | 路由 `undo` 的 `defer { syncSelectionByState(...) }` 删掉 | 选中态死值 | `undoRemovingSelectedLineClearsSelection` + `test_uG7_...` |
| U-M32 | `undoButtonEnabled` 改成 `engine.canUndoDrawing && selectionGeometryVisible(engine:)` | **"顺手统一"** | `undoRedoEnabledIgnoresSelectionAndGeometry` |
| U-M33 | 路由 `undo` 里补一句 `engine.drawingSession.setCommittedSelection(...)` | 恢复回来的线自动选中 | `test_uG7_...`（**行为档**：`undoRestoredLineIsNotAutoSelected` 也红） |
| U-M34 | `redoButtonEnabled` 改成恒 `true` | ↪ 恒亮 | `enabledPredicatesAtSessionStartAndAfterNewAction` |

---

### Task 7: 底栏 3 键 → **5 键** + `TrainingView` 接线 + 三条既有守卫升级

**Files:**
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/DrawingModeBar.swift`（**UIKit-gated**）
- Modify: `ios/Contracts/Sources/KlineTrainerContracts/UI/TrainingView.swift:284-289`
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingInteractionUISourceGuardTests.swift`（`bottomBarHasExactlyThreeKeys` → 五键版）
- Modify: `ios/Contracts/Tests/KlineTrainerContractsTests/Render/DrawingBottomBarHeightTests.swift:42`（**UIKit-gated**，构造补 4 个参数）

**Interfaces:**
- Consumes：Task 6 的 `DrawingEditRouter.undoButtonEnabled(engine:)` / `redoButtonEnabled(engine:)` / `undo(engine:)` / `redo(engine:)`
- Produces：`DrawingBottomBar` 新增 4 个参数 `undoEnabled: Bool` / `onUndo: () -> Void` / `redoEnabled: Bool` / `onRedo: () -> Void`

⚠️ **本 task 一动手就会打破 3 条既有守卫**（开工前冲突扫描第 3、4 条 + 那两条 ↩↪ 否定断言）。**必须在同一个 commit 里连同理由一起改**，中间不许留一个红着的提交。

- [ ] **Step 1: 写失败的测试**（= 把既有守卫改成新形状）

把 `DrawingInteractionUISourceGuardTests.swift` 里的 `bottomBarHasExactlyThreeKeys` 整条替换为：

```swift
    @Test("1b-ii 撤销 PR：底栏**恰好 5 个按钮**（①类型 ②🔒 ③🗑 ④↩ ⑤↪ = 母 spec §2 的终局形态）")
    func bottomBarHasExactlyFiveKeys() throws {
        let bar = try code("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        // 结构计数（G-5：不是「禁止图标名」黑名单）—— 锁定 PR 把 2 改成 3，撤销 PR 把 3 改成 5
        #expect(bar.components(separatedBy: "Button").count - 1 == 5,
                "底栏按钮数不是 5 —— 少了就是 ↩ / ↪ 没接进来，多了就是把 P1c 的键提前 ship 了")
        #expect(bar.contains("deleteEnabled"), "🗑 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!deleteEnabled)")))
        #expect(bar.contains("lockEnabled"), "🔒 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!lockEnabled)")))
        #expect(bar.contains("undoEnabled"), "↩ 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!undoEnabled)")))
        #expect(bar.contains("redoEnabled"), "↪ 必须由传入谓词置灰，不得自己判")
        #expect(bar.contains(squeeze(".disabled(!redoEnabled)")))
        // 底栏不得自己读任何状态 —— 判据必须在路由里
        #expect(!bar.contains(squeeze("drawing.locked")), "底栏不得自己读 DrawingObject.locked")
        #expect(!bar.contains(squeeze("canUndoDrawing")), "底栏不得自己读引擎的栈状态")
        #expect(bar.contains("BottomBarMetrics.height"))
        // ★ 用户可见文案 / SF Symbol 名是**字符串字面量** → 必须读原始文本
        let barRaw = try raw("Sources/KlineTrainerContracts/UI/DrawingModeBar.swift")
        #expect(barRaw.contains("Text(\"类型\")"))
        #expect(barRaw.contains("Image(systemName: \"trash\")"), "③🗑 未接入")
        #expect(barRaw.contains(".accessibilityLabel(\"删除\")"))
        #expect(barRaw.contains("Image(systemName: lockIsOn ? \"lock\" : \"lock.open\")"))
        #expect(barRaw.contains(".accessibilityLabel(lockIsOn ? \"解锁\" : \"锁定\")"))
        // ④↩ ⑤↪ 本期**必须**渲染（锁定 PR 时这两条是否定断言，撤销 PR 反转过来）
        #expect(barRaw.contains("Image(systemName: \"arrow.uturn.backward\")"), "④↩ 未接入")
        #expect(barRaw.contains(".accessibilityLabel(\"撤销\")"))
        #expect(barRaw.contains("Image(systemName: \"arrow.uturn.forward\")"), "⑤↪ 未接入")
        #expect(barRaw.contains(".accessibilityLabel(\"前进\")"))
    }

    /// ⚠️ 只查 `DrawingModeBar.swift` **挡不住**「按钮长得对但根本没接上」——
    ///    `DrawingBottomBar(undoEnabled: true, onUndo: {}, …)` 会让上面那条五键守卫全绿，
    ///    而屏幕上那个 ↩ 恒亮、点了没反应。可用性与动作的**真相在路由里**。
    @Test("底栏 ↩ / ↪ 的可用性与动作四者都必须接 DrawingEditRouter，不得传常量或空闭包")
    func trainingViewWiresUndoRedoToRouter() throws {
        let tv = try code("Sources/KlineTrainerContracts/UI/TrainingView.swift")
        #expect(tv.contains(squeeze("undoEnabled: DrawingEditRouter.undoButtonEnabled(engine: engine)")),
                "↩ 的可用性没接路由 —— 可能传了常量")
        #expect(tv.contains(squeeze("redoEnabled: DrawingEditRouter.redoButtonEnabled(engine: engine)")),
                "↪ 的可用性没接路由")
        #expect(tv.contains(squeeze("DrawingEditRouter.undo(engine: engine)")), "↩ 的动作没接路由")
        #expect(tv.contains(squeeze("DrawingEditRouter.redo(engine: engine)")), "↪ 的动作没接路由")
        // ⚠️ **不得**绕过路由直接调引擎（那样选中态永远不同步，D77 / U-G6 同族）
        #expect(!tv.contains(squeeze("engine.undoDrawing(")), "↩ 绕过了路由直接调引擎")
        #expect(!tv.contains(squeeze("engine.redoDrawing(")), "↪ 绕过了路由直接调引擎")
    }
```

- [ ] **Step 2: 跑测试确认它红**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t7-red.log | tail -20
grep -E "✘ Test .*(bottomBarHasExactlyFiveKeys|trainingViewWiresUndoRedo)" /tmp/undo-t7-red.log
```
预期：两条都**失败**（底栏还是 3 个按钮、`TrainingView` 还没传那 4 个参数）。

- [ ] **Step 3: 写最小实现**

**3a. `DrawingModeBar.swift`：** 头注释改掉那句「④↩⑤↪ 属 PR-2，本期一个占位都不渲染」，并在 🗑 之后、`Spacer()` 之前插两个按钮：

```swift
/// 画线底栏（单行）：①「类型」键 + ②🔒 锁定 + ③🗑 删除 + **④↩ 撤销 + ⑤↪ 前进（1b-ii 撤销 PR）**。
/// 至此为母 spec §2 的 5 键终局形态。
/// 与 TradeActionBar/ReviewControlBar 共享同一个 `BottomBarMetrics.height` 固定高度 → 三者切换零跳动。
```

```swift
    /// D78「撤销可用」谓词的结果。**本视图自己不判任何东西**——判据全在 `DrawingEditRouter`。
    /// ⚠️ 这个谓词**刻意不含**几何与选中分量（与 🔒/🗑 不同）：撤销是会话级操作。
    ///    形状不一致是**有意的**，不要"顺手统一"（D78）。
    let undoEnabled: Bool
    let onUndo: () -> Void
    /// D78「前进可用」谓词的结果。理由同上。
    let redoEnabled: Bool
    let onRedo: () -> Void
```

```swift
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .accessibilityLabel("撤销")
                .disabled(!undoEnabled)
            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .accessibilityLabel("前进")
                .disabled(!redoEnabled)
```

**3b. `TrainingView.swift:284-289` 的 `DrawingBottomBar(` 调用补 4 个参数：**

```swift
                    DrawingBottomBar(typeRowExpanded: $typeRowExpanded,
                                     lockEnabled: DrawingEditRouter.lockButtonEnabled(engine: engine),
                                     lockIsOn: DrawingEditRouter.lockIsOn(engine: engine),
                                     onToggleLock: { DrawingEditRouter.toggleLockSelected(engine: engine) },
                                     deleteEnabled: DrawingEditRouter.deleteButtonEnabled(engine: engine),
                                     onDelete: { confirmingDeleteDrawing = true },
                                     undoEnabled: DrawingEditRouter.undoButtonEnabled(engine: engine),
                                     onUndo: { DrawingEditRouter.undo(engine: engine) },
                                     redoEnabled: DrawingEditRouter.redoButtonEnabled(engine: engine),
                                     onRedo: { DrawingEditRouter.redo(engine: engine) })
```

⚠️ **↩ / ↪ 不弹确认框**（与 🗑 不同）：撤销**可逆**（↪ 就在旁边），而删除不可逆。这个不对称是有意的。

**3c. `DrawingBottomBarHeightTests.swift:42` 的构造补参**（编译器逼的，**不是新增测试**）：

```swift
        let bar = DrawingBottomBar(typeRowExpanded: .constant(false),
                                   lockEnabled: false, lockIsOn: false, onToggleLock: {},
                                   deleteEnabled: false, onDelete: {},
                                   undoEnabled: false, onUndo: {},
                                   redoEnabled: false, onRedo: {})
```
⚠️ 若该文件里有第二处构造（`grep -n "DrawingBottomBar(" ios/Contracts/Tests -r`），**每一处都要补**，否则 Catalyst 编译不过而 host 完全看不见（该文件 UIKit-gated）。

- [ ] **Step 4: 跑测试确认全绿（host + Catalyst 编译）**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-t7.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-t7.log | tail -2 || exit 1
```
⚠️ **host 绿不代表 Catalyst 编译得过** —— `DrawingModeBar.swift` 与 `DrawingBottomBarHeightTests.swift` 都是 UIKit-gated，host 上**根本不编译**。本步必须**额外**跑一次 Catalyst 编译（不必跑全量测试，只要编译过）：

```bash
set -o pipefail                                   # ⚠️ 本块必须自己再设一次（上一个块的设置不跨块）
rm -rf /tmp/undo-t7-dd                            # 冷构建：只清本次专用的 DerivedData，**不动**全局那份
xcodebuild build-for-testing -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -derivedDataPath /tmp/undo-t7-dd 2>&1 | tee /tmp/undo-t7-cat.log | tail -5 || exit 1   # ① 退出码
test "$(grep -c 'error:' /tmp/undo-t7-cat.log)" -eq 0 || { echo "GATE FAIL: 日志里有 error:"; exit 1; }   # ② 日志内容
ls -d /tmp/undo-t7-dd/Build/Products/Debug-maccatalyst/*.xctest >/dev/null 2>&1 \
  || { echo "GATE FAIL: 没产出任何 .xctest bundle（等于什么都没编译）"; exit 1; }                        # ③ 产物存在
echo "Catalyst 编译门：三条全过"
```

⚠️ **三条各断各的，一条都不能省**（codex plan-R2 high，**已核实为真**）：
① `xcodebuild` 自己的退出码 —— `set -o pipefail` 只**传递**退出码、不会让脚本停下来，
   所以那一行必须自带 `|| exit 1`，否则编译失败后照样往下跑；
② 日志零条 `error:` —— **必须用 `test "$(grep -c …)" -eq 0` 包起来**，
   直接拿 `grep -c` 当门方向是反的（计数 0 时 grep 退出码为 1）；
③ 真的产出了 `.xctest` bundle —— 编译失败时**可能一行 `error:` 都不打**
   （scheme 找不到、destination 不可用），只靠 ①② 仍会把「什么都没编译」读成绿。
   用**产物存在**而不是 `BUILD SUCCEEDED` 字样，理由同 G-6「判绿读实物，不读字样」。

预期：swift-testing = **1953 + 1 = 1954**（新增 `trainingViewWiresUndoRedoToRouter`；五键那条是替换不是新增）；Catalyst 三条门全过。

- [ ] **Step 5: 提交**

```bash
git add ios/Contracts/Sources ios/Contracts/Tests
git commit -m "feat(ui): 底栏补齐 ④↩ ⑤↪（5 键终局）+ 接路由 + 三条既有守卫升级"
```

- [ ] **Step 6: 变异验证（提交之后）**

| # | 变异 | 只有它够得到的档 | 预期变红的测试名 |
|---|---|---|---|
| U-M35 | `TrainingView` 里 `undoEnabled:` 改成传常量 `true` | ↩ 恒亮 | `trainingViewWiresUndoRedoToRouter` |
| U-M36 | `onUndo:` 改成 `{ engine.undoDrawing() }`（绕过路由） | 选中态不同步 | `trainingViewWiresUndoRedoToRouter` + `test_uG6_...` |
| U-M37 | `DrawingModeBar` 里 `.disabled(!undoEnabled)` 删掉 | 置灰没接 | `bottomBarHasExactlyFiveKeys` |
| U-M38 | 把 ↩ 的图标名改成 `arrow.left` | 图标接错 | `bottomBarHasExactlyFiveKeys` |

---

### Task 8: 收尾 —— Catalyst 基线同步 + 全量闸门 + 交接文档 + PR 描述

**Files:**
- Modify: `.github/scripts/catalyst-total-baseline.txt`
- Modify: `.github/scripts/catalyst-gate.test.sh`
- Modify: `.github/scripts/fixtures/pass-main-current.log`
- Verify（重生成后确认零 diff）: `.github/scripts/catalyst-uikit-baseline.txt`
- Modify: `docs/superpowers/specs/2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md`（末尾追加「实施状态」小节，**不改任何决策**）
- Create: `.superpowers/sdd/2026-08-21-drawing-p1b-undo/progress.md`（本片账本）

- [ ] **Step 1: 冷构建取 Catalyst 真实数**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
# ⭐ 冷构建 = **用一个全新的专属 DerivedData 目录**，而不是去删全局那份
#    （codex plan-R8 medium，**已核实为真**）：`~/Library/.../DerivedData/KlineTrainerContracts-*`
#    这个通配**不限于本 checkout** —— 本仓当前有 16 个 worktree，删它等于把其它分支的构建产物、
#    索引、调试状态一起抹掉。全新目录天然就是冷的，既达到目的又零外溢。Task 7 用的就是这个写法。
DD="$(mktemp -d /tmp/undo-t8-dd.XXXXXX)"
cd ios/Contracts
xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests \
  -derivedDataPath "$DD" 2>&1 | tee /tmp/undo-catalyst.log | tail -5 || exit 1   # ① 退出码
test "$(grep -c 'Executed [0-9]* tests' /tmp/undo-catalyst.log)" -ge 1 \
  || { echo "GATE FAIL: 日志里没有任何执行量行（很可能根本没跑起来）"; exit 1; }                      # ② 有执行量
grep -E "Executed [0-9]+ tests" /tmp/undo-catalyst.log | tail -2                                    # ③ 人读取数
rm -rf "$DD"        # 只删本次那个 mktemp 出来的目录，**绝不**碰全局 DerivedData
```
⚠️ **和 Task 7 同款的三条纪律**（codex plan-R2 在 Next steps 点名要审这一块，**已核实同样有问题**）：
`xcodebuild` 那行必须自带 `|| exit 1`；「有没有执行量」要用 `test "$(grep -c …)" -ge 1` 断，
**不能**把 `grep` 的退出码当门。
⚠️ **判绿读执行量，不读 `TEST SUCCEEDED` 字样**。记下 total 实测新值。

- [ ] **Step 2: 同步四处**

```bash
# ① uikit 基线重生成 —— 本片不新增 UIKit-gated 测试，预期**零 diff、仍是 78 行**
python3 .github/scripts/uikit-expected-tests.py > /tmp/uikit-new.txt
diff /tmp/uikit-new.txt .github/scripts/catalyst-uikit-baseline.txt && echo "uikit 零 diff ✓"
wc -l < /tmp/uikit-new.txt      # 必须是 78

# ② total 基线：1811 → 实测新值
echo "<实测新值>" > .github/scripts/catalyst-total-baseline.txt

# ③ catalyst-gate.test.sh：把「活基线覆盖」用例写死的 1798 换成实测新值（共 3 处）+ 追加维护记录

# ④ pass-main-current.log：用**本轮真冷构建**日志逐行重裁
```

**维护记录条目模板**（追加到 `catalyst-gate.test.sh` 的注释块）：
```
#   【1b-ii 撤销 PR（本轮）】total 1811→<新值>（+N）：本片新增 N 条 host 测试（撤销栈行为 + 源码守卫），
#   **零条 UIKit-gated 新增**（uikit 基线仍 78，已重生成确认零 diff）。
#   同步理由：不同步的话下一轮读到的仍是旧基线 1811，窗口下限锁死在 1811−30=1781，而当前真实总数
#   已是 <新值> ⇒ 从 <新值> 掉到 1781 都不会报警，等于把这道门「掉 30 条就报警」的设计意图废掉。
#   pass-main-current.log 已用本轮真冷构建日志逐行重裁。
```

- [ ] **Step 3: 全量闸门（host + Catalyst + 闸门自测三门连跑，每门单独 `|| exit 1`）**

```bash
set -o pipefail
repo="$(git rev-parse --show-toplevel)"
echo "branch=$(git -C "$repo" branch --show-current) HEAD=$(git -C "$repo" rev-parse --short HEAD)"
cd ios/Contracts && swift test 2>&1 | tee /tmp/undo-final.log | tail -3 || exit 1
grep -E "Executed [0-9]+ tests, with 0 failures" /tmp/undo-final.log | tail -2 || exit 1
cd "$repo" && bash .github/scripts/catalyst-gate.test.sh 2>&1 | tail -10 || exit 1
git status --short
```

- [ ] **Step 4: 回填 spec 的实施状态（不改任何决策）**

在 `2026-08-11-drawing-tools-P1b-1b-ii-lock-undo-design.md` 末尾追加：

```markdown
## 5. 实施状态（2026-08-21）

**PR-1（锁定）** 已实施并合入 `origin/main`（#163）。
**PR-2（撤销）** 已实施完毕，分支 `feat/drawing-p1b-undo`，base = `feat/drawing-p1b-autoselect`。

**本 spec 写于 2026-08-11，早于「持久化片」与「自动选中片」。** PR-2 实施时补了三条本 spec 没有的决策
（记在实施计划 `docs/superpowers/plans/2026-08-21-drawing-p1b-undo.md` 的「本计划新增的三条决策」一节）：

- **D101** 入栈条件 = 「`drawings` 内容真的变了」；本局默认单独变化不入栈（含已接受残留）。
- **D102** 「一次动作」作用域 —— 把画线态改样式的两处写入合成一条撤销记录（自动选中 spec §10.1 的硬约束）。
- **D103** 清栈绑「`drawingModeActive` 真的翻转」，**修正本 spec §2.1「落地形态」那一句** ——
  它与本 spec 自己的 N-Q5 冲突（`DrawingSession.activate` 对 `drawingModeActive` 是幂等的，
  冗余的 begin 会走到 activate 却没有翻转，照原句实现会静默抹掉一条有效撤销记录）。

**另外更正本 spec §2.3b 的一处预估**：`TrainingEngine.swift` 里 `drawings` 的结构性写入点，
实施后是 **8 处**（不是锁定 PR 时预估的 6 处）—— `applyUndoEntry` 一个函数里就有三处
（`remove` / `insert` / 下标赋值）。守卫 L12b 与 U-G4 都按 8 钉死。
```

- [ ] **Step 5: 写本片账本**

`.superpowers/sdd/2026-08-21-drawing-p1b-undo/progress.md`，逐 task 记：改了什么、闸门两个数字、变异逐条的**红测试名** + 复原证据、评审轮次与裁决。

- [ ] **Step 6: 提交**

```bash
git add .github/scripts docs/superpowers/specs .superpowers/sdd
git commit -m "chore: Catalyst 基线同步（total 1811→<新值>）+ spec 实施状态回填 + 本片账本"
```

- [ ] **Step 7: codex 对抗性评审（收口）**

```bash
.claude/scripts/codex-attest.sh --scope branch-diff \
  --head feat/drawing-p1b-undo --base feat/drawing-p1b-autoselect
```
⛔ **绝不传未知参数**（含 `--help`，会被当成 focus → 假 approve）。
⛔ **base 必须是 `feat/drawing-p1b-autoselect`**，不是 `origin/main`（后者会把 S3 的 -2310 行当成本片删的，产出一堆假 finding）。

评审 finding 逐条**核实为真 / 驳回**（不许performative 采纳），修完重跑，直到 approve 或用户裁决 override。

- [ ] **Step 8: PR 描述（用户自己 push 与开 PR，本步只产出文本）**

PR 描述**必须**包含：
1. **G-0 全文复述**（交接 §10.1 的两条硬约束 + 自动选中 spec §12 的 override 边界）；
2. **D101 的已接受残留**：画线态下线被拒时只有默认变了，这次改动撤不回来（用户 2026-08-21 明确接受）；
3. **D103 修正了 spec §2.1 的一句**，以及 §2.3b 的 6→8 更正；
4. 每条变异的**红测试名** + 复原后重新变绿的证据；
5. 闸门两个数字（swift-testing / XCTest）+ Catalyst total 新值；
6. **合并前才把 `origin/main` 按次序合进三片、然后重跑 attest** 这条操作提示。

---

## 非程序员验收清单（真机，spec §2.7 的 19 条 + 本计划新增 3 条）

> 用法：一条一条照做，对照「预期」打勾。**任何一条不通过就停下来报回**，不要自己判断"应该问题不大"。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 进画线模式，看下面那行按钮 | 现在是 **5 个**：类型键、🔒、🗑、↩、↪ | |
| 2 | 刚进画线模式，什么都还没做，看 ↩ 和 ↪ | 两个都是灰的 | |
| 3 | 画一条线，看 ↩ | ↩ 变亮 | |
| 4 | 点 ↩ | 刚画的线消失了；↪ 变亮 | |
| 5 | 点 ↪ | 线又回来了 | |
| 6 | 删掉一条线，点 ↩ | 线回来了 | |
| 7 | 接上一条：再点 ↪ | 线又没了 | |
| 8 | 改一条线的颜色，点 ↩ | 颜色变回改之前 | |
| 9 | 锁定一条线，点 ↩ | 变回没锁定（🗑 恢复可用） | |
| 10 | 在**同一个价位**从上往下依次画三条重合的线（叫它们 A、B、C），把**中间那条 B** 删掉，再点 ↩ | B 回来了 | |
| 11 | 接上一条：切到选择态，在那个价位单击一下 | 选中的是**最后画的 C**，和删 B 之前一模一样——不是刚撤销回来的 B | |
| 12 | 连点两次 ↩ | 只回退一步（第二次没反应） | |
| 13 | 连点两次 ↪ | 只前进一步（第二次没反应） | |
| 14 | 撤销之后再画一条新线，看 ↪ | ↪ 变灰（做了新动作，"前进"就失效了） | |
| 15 | 改一条线的颜色 → 点 ↩ → **切到选择态，点空白处取消选中** → 在样式面板把默认颜色改成**绿色** → 再点 ↪ | 那条线回到**你之前改的那个颜色**，**不是**绿色<br>⚠️ 中间那步「切到选择态并取消选中」不能省——画线态改默认会**连线一起改**，选择态**有选中**时也只改线不改默认，只有「选择态 + **无**选中」才是本条要测的语义 | |
| 16 | 点「退出」离开画线模式，再进来，看 ↩ / ↪ | 两个都是灰的（撤销记录不跨会话保留） | |
| 16b | *（本条由引擎测试覆盖，真机不可执行——当前 UI 下画线模式的底栏是画线工具栏，买/卖/持有三个键在画线态下根本不存在，没法在不退出画线模式的情况下下单）* | 对应引擎测试 `DrawingUndoSessionLifecycleTests.tradeTriggeredClearsStack`（N-Q1）：下单会**隐式结束**画线会话，撤销记录跟着清掉——这是对的，不是 bug | N/A |
| 16c | 画一条线（不点退出）→ **竖滑切一次周期** → 再看 ↩，然后点它 | ↩ **仍然是亮的**，点下去能把那条线撤掉。<br>⚠️ 与 16b 刻意相反：切周期**不会**结束画线会话（你还在画线模式里），所以撤销记录必须留着 | |
| 16d | 改一条线的颜色 → 把**同一个颜色再点一次** → 点 ↩ | 颜色回到**改之前**那个色。<br>（不是"没反应"——重复点同一个颜色不该把你上一次的真改动冲掉） | |
| 17 | 撤销一条线之后**杀掉 App**，续这一局 | 撤销的结果被保留了（那条线确实不在）；↩ / ↪ 都是灰的 | |
| 18 | 进复盘模式看画线入口 | 还是浮动铅笔钮，**没有**两行底栏 | |
| 19 | 「再次训练」（replay）模式下重做第 3～9 条 | 行为与训练模式完全一致 | |
| **20** ⭐ | **在画线模式下**（不是选择态）画一条线 → 它自动被选中 → 把粗细改成 3（注意：这一步同时改了那条线**和**"下一条线的默认") → 点 ↩ → **再画一条新线** | 新画的这条线**粗细是 1**（回到你改之前的默认），不是 3。<br>说明：撤销必须把"那条线"和"下一条线的默认"**一起**退回去；只退线不退默认的话，你刚撤销掉的粗细会在下一笔新线上**复活** | |
| **21** ⭐ | 画一条线 → 把粗细改成 3（同时改了那条线**和**"下一条线的默认"）→ 点 ↩ → 点 ↪（前进）→ 再画一条新线 | 新画的这条线**粗细是 3**（默认也跟着前进了） | |
| **22** | **锁定**一条线（🔒 亮起）→ 在画线模式下改颜色 → 点 ↩ | 那条锁着的线**颜色没变**（本来就没被改），而"下一条线的默认"**也不会**回退；**同时 🔒 会变回开锁的样子**——因为"改颜色只改默认"那步没产生新的可撤销记录，栈顶一直是"锁定"那次动作，↩ 撤销的其实是它。<br>说明：颜色/默认撤不回来是**已知的、我们接受的**限制；🔒 被解锁是**正确**的连带结果，两者都不是 bug——测试员看到解锁不要报上来 | |

⚠️ **第 20 / 21 条是本片最关键的两条**（对应交接 §10.1 的硬约束）。第 22 条是**已接受残留**的现场确认，看到"撤不回来"是**正确**行为，不要报 bug。

---

## Self-Review（写完计划后自查，已执行）

**1. spec 覆盖度**：逐条对 spec §2 的小节与 §2.6 的测试清单点名到 task：

| spec 条目 | 落在哪 |
|---|---|
| D74 栈存引擎 | Task 1（存储）+ Task 2（生命周期） |
| D75 入栈点 = 四个写入 API 成功路径 | Task 1 |
| D80 内容未变零副作用 | **锁定 PR 已落地**（`TrainingEngine.swift:1185` 实测），Task 1 只加下游断言 |
| D76 undo/redo 专用入口 | Task 3 |
| D79 第一层（写入面穷尽） | Task 4 |
| D79 第二层（前置条件） | Task 3 |
| D79 第三条（不入栈） | Task 3（N-N4） |
| D77 撤销后的选中态 | Task 6 |
| D78 置灰判据 | Task 6（谓词）+ Task 7（接线） |
| N-I 保序 | Task 3 |
| N-J redo 不漂移 ×2 | Task 3 |
| N-K 深度 1 | Task 1（栈内容）+ Task 3（行为） |
| N-L 栈生命期 | Task 2 |
| N-M 四类往返 + dirty | Task 3 |
| N-N 空栈 + 正向档 | Task 3 |
| N-N2 陈旧栈三 case | Task 3 |
| N-N3a/b 绕过栈作废 | Task 4 |
| N-N4 undo 不入栈 | Task 3 |
| N-O 复盘门 | Task 3 |
| N-P 前作回归 | 每个 task 的全量判绿 + Task 8 |
| N-Q1…Q5 | Task 2 |
| N-R no-op 不冲掉 | Task 1（引擎侧）+ Task 5（路由侧，画线态） |
| N-S 共处守卫 | Task 2 |
| §2.7 验收清单 | 本文件「非程序员验收清单」（19 条 + 新增 3 条） |
| §3 契约零影响 | G-1 |

**gap 1（R9 后已关闭）**：spec N-M 里「autosave 被触发 → **重新加载后结果正确**」这半条，原稿只用「`drawingsRevision` 严格 +1」＋既有守卫 G6b 顶替，并把它标成「codex 评审必须正面审」的计划级裁决。
**codex plan-R9 判定不足，理由成立并已核实**：那两条只证明「保存被请求了」，证明不了**分别观察到的** `drawings` 与 `defaultStyle` 被序列化成**同一份连贯状态**、一起活过 coordinator 的落盘、再一起读回来。autosave 的排序 / 合并一旦出问题，完全可能把「已回滚的线」和「没回滚的默认」一起存下去 —— 被撤销掉的样式在续训之后复活，正是 D102 要防的高代价形态。
**处置**：按当初写下的那条正解补齐 —— Task 5 增加两条走 `TrainingSessionCoordinator` 的落盘往返测试（undo / redo 各一），并配两条变异（分别关掉「默认那一侧的读回」与「写出」）证明它们真有判别力。**本 gap 关闭。**

**gap 2（R3 后新增，已处置）**：D101 原稿只说「默认单独变化不入栈」，没说**栈里那条旧记录的默认分量会因此过期**。
codex plan-R3 从 ↪ 方向报了这个缺陷，复核发现 ↩ 方向同样成立（它未报）。已把「默认分量两端必须与当前默认对得上」
写成显式不变量、给出完整性论证（`setDefaultStyle` 五个调用点逐一交代），并补两条方向对称的回归测试
＋三条变异（含一条专门证明 codex 原处方不够）。

**2. 占位符扫描**：全文无 TBD / TODO / "类似 Task N" / "写测试覆盖以上"。每个代码步都给了可直接粘贴的代码块；`<实测新值>` 只出现在 Task 8 的 Catalyst 基线（那是**必须实跑才能知道**的数，已配取数命令）。

**3. 类型一致性**（跨 task 逐个核对）：
- `DrawingUndoEntry` 的构造顺序**钉死为 `drawingsDelta` → `isUndone` → `defaultDelta`**，且由 Task 1 写下的**显式构造器**承载（不用自动生成的那个）。Task 5 只在**末尾**追加带默认值的第三参 → Task 1/3 那些两参构造点一处都不用改 ✓
  （codex plan-R1 抓到的就是这里：原稿把 `defaultDelta` 写在 `isUndone` 前面，Swift 会因实参顺序不符声明顺序而**编译不过**，卡住的正是风险最高的 Task 5。已核实为真并按其"显式构造器"建议修。）
- `canUndoDrawing` / `canRedoDrawing`（Task 1）→ Task 6 的 `undoButtonEnabled` / `redoButtonEnabled` 引用 ✓ 名字一致
- `clearDrawingUndoStack()`（Task 1 定义，private）→ Task 2 三处、Task 3 三处、Task 4 两处调用，**全在 `TrainingEngine.swift` 内** ✓（private 的可访问性成立）
- `applyUndoEntry(_:direction:)`（Task 3）→ Task 5 在其中加默认恢复 ✓
- `performDrawingAction(_:)`（Task 5）→ 唯一调用点在 Task 5 的路由改动里 ✓
- `functionBody(_:funcName:)` 在 Task 2 的守卫文件里定义 → Task 4/6 复用 ✓
- `functionBodies(_:funcName:)`（Task 2 定义，按**大括号配对**在**保留边界**的文本上切）→ Task 4 的 `engineDrawingsWritesByFunction`、Task 4/6 的守卫都用它；两者**同文件** ✓
  （codex plan-R5 抓到的就是这里：原稿用 `func `（带空格）当函数体边界，而入参是空白已被删光的 squeezed 文本 ⇒ 边界永不匹配、函数体一路吃到文件末尾 ⇒ U-G1/U-G7 假绿、U-G4 无法满足。已核实为真并重写。）
- 测试搭台 `DrawingPanelStyleSemanticsTests.drawModeWithSelected` / `.selectModeWithSelected` / `.mapper()` 均为同测试模块 internal `static` ✓

**4. 事实核对（本计划写作期间实测，非推测）**：`TrainingEngine` / `DrawingSession` 均 `@Observable` ✓；`drawings` 是 `public private(set)`、setter 文件作用域 ✓；`deleteDrawing(at:)` 生产调用点 **0** ✓；`DrawingToolType` **不是** `CaseIterable`、`implemented == [.horizontal]` ✓；`PeriodDirection` 只有 `.toLarger`/`.toSmaller` ✓；`holdOrObserve(panel:)` 是不需要资金的推进路径 ✓；`injectDrawingsForTesting` 在 `#if DEBUG` extension（同文件）✓。
