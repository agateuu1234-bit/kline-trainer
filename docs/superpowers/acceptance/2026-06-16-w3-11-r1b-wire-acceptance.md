# W3-11-R1b-wire 边缘 bounce 实时接线 — 非-coder 验收清单

> **本交付性质**：把已就绪的 bounce 物理 + R1a 几何 helper **接进** app 手势/渲染管线（机制 A 速度方向分派 + 三 clamp 层 + `interruptDeceleration`），使**甩到最老边 → 弹簧 overscroll+回弹可见**、最新边硬钳无弹。改 3 生产 Swift（`RenderStateBuilder`/`TrainingEngine`/`ChartContainerView`）+ 2 测试 + spec/plan/本验收。
>
> 验收判据 = **确定性 host 单元测试（机制/clamp/几何）+ 范围 gate + Catalyst build + codex APPROVE 落账 + §8 真机 runbook（用户实测回填）**。手势的**实时回弹观感**属真机/模拟器范畴（§8），host 测覆盖其底层契约。
>
> **如何用**：你（非编码者）逐条照抄「操作命令」到终端回车，把屏幕输出对照「预期输出」，吻合即「判定」勾 ✅，不吻合勾 ❌。每条二元（是/否），无需读代码。
>
> **运行前置**（终端先进工作树根，含空格须带引号）：
> ```bash
> cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave3-pr13-completion"
> ```

---

## 第 1 条 · 范围 gate（改动文件白名单 fail-closed）

**目的**：确认本交付只动 3 生产 Swift + 2 测试 Swift + spec/plan/验收 3 文档，**没有**碰其它模块。

**操作命令**（整段粘贴回车）：
```bash
set -euo pipefail
ALLOW='docs/superpowers/acceptance/2026-06-16-w3-11-r1b-wire-acceptance.md
docs/superpowers/plans/2026-06-16-w3-11-r1b-wire.md
docs/superpowers/specs/2026-06-16-w3-11-r1b-wire-design.md
ios/Contracts/Sources/KlineTrainerContracts/Render/ChartContainerView.swift
ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift
ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
ios/Contracts/Tests/KlineTrainerContractsTests/Render/RenderStateBuilderTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineBounceWiringTests.swift'
changed=$(git diff --name-only origin/main...HEAD)
extra=$(comm -23 <(echo "$changed" | sort -u) <(echo "$ALLOW" | sort -u))
if [ -z "$extra" ]; then echo "GATE-PASS：仅白名单文件改动"; else echo "GATE-FAIL：越界文件："; echo "$extra"; fi
```

**预期输出**：单行 `GATE-PASS：仅白名单文件改动`。

**判定**：打印 `GATE-PASS` → ✅；出现 `GATE-FAIL` 及任意文件名 → ❌。

---

## 第 2 条 · B4 单边 overscroll（仅最老边露间隙）

**目的**：确认 offset 顶过最老边 → makeViewport 渲 overscroll 间隙（`pixelShift=offset−maxOffset`），且 startIndex 不越界。

**操作命令**：
```bash
cd ios/Contracts && swift test --filter b4OverscrollOldestEdge 2>&1 | grep "✔ Test"; cd - >/dev/null
```

**预期输出**：含 `✔ Test "B4 overscroll：offset>maxOffset（最老边）→ startIndex==0 + pixelShift==offset−maxOffset" passed`。

**判定**：该行 `passed` → ✅；无输出或 `✘` → ❌。

---

## 第 3 条 · 机制 A 速度方向分派（v>0 弹 / v≤0 不弹）

**目的**：确认松手甩向最老边（v>0）走弹簧 overscroll 并回落边缘；甩向最新边（v<0）走单调减速、不越界、停当前 tick。

**操作命令**（两步，逐条回车）：
```bash
cd ios/Contracts && swift test --filter dispatchPositiveBounces 2>&1 | grep "✔ Test"; cd - >/dev/null
cd ios/Contracts && swift test --filter dispatchNegativeDecel 2>&1 | grep "✔ Test"; cd - >/dev/null
```

**预期输出**：两行分别含 `✔ Test "dispatch v>0 有空间 → bounce overscroll（offset 朝 maxOffset 移动并越界）M5" passed` 与 `✔ Test "dispatch v<0 → plain decel（offset 朝 0 单调、不越 maxOffset）" passed`。

**判定**：两行均 `passed` → ✅；任一无输出或 `✘` → ❌。

---

## 第 4 条 · 满屏（无滚动空间）甩动不 strand（C1）

**目的**：确认 K 线不足一屏时甩动 → offset 钳回 0、不漂成正值（C1 修：无滚动空间也 full-clamp）。

**操作命令**：
```bash
cd ios/Contracts && swift test --filter c1NoScrollSpacePositiveNoStrand 2>&1 | grep "✔ Test"; cd - >/dev/null
```

**预期输出**：含 `✔ Test "C1：v>0 无滚动空间（bounceEdges==[]）→ plain decel full-clamp 钳 0，不 strand" passed`。

**判定**：该行 `passed` → ✅；无输出或 `✘` → ❌。

---

## 第 5 条 · 中断归一（re-grab / 开画线中途 overscroll 不残留）

**目的**：确认 overscroll 进行中再次按下（re-grab）或开画线工具 → offset 归回最老边、不残留越界间隙（drawing 快照取归一后 offset）。

**操作命令**（两步）：
```bash
cd ios/Contracts && swift test --filter interruptBeginPanNormalizes 2>&1 | grep "✔ Test"; cd - >/dev/null
cd ios/Contracts && swift test --filter activateDrawingDuringOverscrollNormalizes 2>&1 | grep "✔ Test"; cd - >/dev/null
```

**预期输出**：两行分别含 `✔ Test "H3：bounce overscroll 中途 beginPan → offset 归 maxOffset（不 strand）" passed` 与 `✔ Test "M2-new：overscroll 中途 activateDrawingTool → snap.frozen.offset==maxOffset（归一在算 range 前）" passed`。

**判定**：两行均 `passed` → ✅；任一无输出或 `✘` → ❌。

---

## 第 6 条 · 全量 host 测试 + Mac Catalyst build 零回归

**目的**：确认全包 host 单测全绿（含 P7：既有 freeScrolling/drawing/interaction 测仍绿）+ Mac Catalyst 测试 build 成功（governance 闸门）。

**操作命令**（两步，逐条回车；第二步约 30–60 秒）：
```bash
cd ios/Contracts && swift test 2>&1 | grep -E "Test run with"; cd - >/dev/null
cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -1; cd - >/dev/null
```

**预期输出**：第一行 `Test run with 1060 tests in 146 suites passed`（数字 ≥ 1060，0 failures）；第二行 `** TEST BUILD SUCCEEDED **`。

**判定**：第一行含 `passed`（无 `failed`）且第二行含 `TEST BUILD SUCCEEDED` → ✅；任一含 `failed`/`FAILED`/`error` → ❌。

---

## 第 7 条 · codex 对抗性 review APPROVE 落账（ledger）

**目的**：确认本分支 head 的 `codex:adversarial-review` 已 `approve` 并写入 ledger（治理强制 trust-boundary review channel）。

**操作命令**：
```bash
grep -F "wave3-w3-11-r1b-wire@$(git rev-parse HEAD)" .claude/state/codex-attest-ledger.jsonl 2>/dev/null | grep -o '"verdict":"[a-z-]*"' | tail -1
```

**预期输出**：`"verdict":"approve"`。

**判定**：打印 `"verdict":"approve"` → ✅；空输出或非 approve → ❌。
（注：head 在「加入本验收 doc」后重跑 codex 落账，故 `$(git rev-parse HEAD)` 与 ledger approve 条目一致；若 ledger 路径不同，以 `codex-attest` 运行时打印的 `ledger updated` + 同一 head SHA 为准。）

---

## 第 8 条 · 真机/模拟器 runbook（W3-11-R1 device 验收，用户实测回填）

> 本节为运行时观感验收（host 不可复现），用户在真机或模拟器逐项操作并打勾。每项 action/expected/pass-fail。

| # | 操作（action） | 预期（expected） | 判定（pass/fail） |
|---|---|---|---|
| 8.1 | 在历史区**甩动**手指到最老边后松手 | 弹簧 overscroll（左露间隙）+ 回弹 + 落最老边缘 | ☐ |
| 8.2 | **轻拖**到最老边、零速松手（不甩） | 停在最老边、**不**回弹（无弹簧） | ☐ |
| 8.3 | 甩/拖**向最新边**（朝当前 tick 方向）松手 | 平滑减速回 autoTracking、停当前 tick、**无前向间隙、无回弹** | ☐ |
| 8.4 | K 线不足一屏（满屏）时甩动 | 图不动、不弹、不漂移 | ☐ |
| 8.5 | 切周期组合 / 缩放后，再甩到最老边 | 最老边 bounce 仍正确（消费新视口几何） | ☐ |
| 8.6 | bounce 回弹**进行中**切后台→回前台 | 无残留越界间隙（offset 落边缘） | ☐ |
| 8.7 | bounce 回弹**进行中**开画线工具 | 无残留越界间隙、画线锚点基于归一后视口 | ☐ |
| 8.8 | bounce 回弹**进行中**旋转/分屏（M1-new，允许落旧边） | 不卡死、不 strand 越界（新几何下次手势收口） | ☐ |

---

## 残留（移交，非本交付义务）

- **R1b-drag**：拖拽期跟手橡皮筋阻尼（独立 follow-up，本 spec out of scope）。
- **M1-new resize 中途 bounce**：旋转/分屏中途 bounce 沿父 §B5 MVP（停 + 归一到可能旧边，下次手势/scene 收口），本 PR 不追求无缝续弹（§8.8 验证不 strand）。
- **ledger-B**：`feature-completeness: PENDING-W3-11-R1` 的翻转 + 矩阵 bounce 行转 device 行留收尾 reconciliation PR；本 PR 不碰 `wave3-completion.md`/`verify-wave3-completion.sh`。
