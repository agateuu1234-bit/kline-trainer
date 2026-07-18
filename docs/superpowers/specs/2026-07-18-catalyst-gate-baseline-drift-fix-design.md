# Catalyst 闸门基线漂移修复 — 设计

**日期**：2026-07-18
**分支**：`ci-catalyst-baseline-drift-fix`（基线 main `6068522`）
**类型**：CI 闸门修复（trust-boundary，`.github/scripts/**`）

## 1. 问题

`Mac Catalyst build-for-testing on macos-15`（ruleset `15660830` 六个必需门之一）在 main `6068522` 上**变红**。失败发生在 **Gate self-test 步骤**（`catalyst-gate.test.sh`），11 秒即挂，未进真构建：

```
UIKit-gated 期望测试清单基线一致性检测（F1）：
  FAIL — 当前源码推导出的 UIKit-gated 测试清单与基线 catalyst-uikit-baseline.txt 不一致
```

这是**必需门**，红在 main 上会让**后续每一个 PR 的 Catalyst 检查都卡在同一个 F1** —— 全仓被堵（含 QMT Plan2）。

## 2. 根因（已用真构建验证）

两个 PR 并行开发、按次序合并造成的**语义合并冲突**：

- **PR #146**（划线 P1b-1a-ii，main `8bec593`）先合入，给 `KlineTrainerContractsTests` **新增 50 个 swift-testing 测试**（其中 7 个是 UIKit-gated：D42/D39×2/D31/R7/连续画线/未开会话点图）。
- **PR #145**（Catalyst 门 scheme 修复，引入本闸门体系）后合入，其签入基线是 **#146 之前的快照**：`catalyst-uikit-baseline.txt`=28、`catalyst-total-baseline.txt`=1407。
- #145 合并前**未 rebase 到含 #146 的 main**，两个 PR 各自单独 CI 全绿，合到一起才冲突。

**真构建实测证据**（本地 `xcodebuild test -scheme KlineTrainerContracts-Package -destination 'platform=macOS,variant=Mac Catalyst'`，main `6068522` 源码）：
- `✔ Test run with 1457 tests in 188 suites passed` → main 真实总数 **1457**，不是基线 1407
- `uikit-expected-tests.py` 对 main 源码推导出 **35** 个 UIKit-gated 测试，不是基线 28
- 用旧基线（28/1407）跑真 main 日志 → `GATE FAIL: 1457 高于上限 1437`

**结论：闸门在正确 fail-closed 工作**（F1 漂移检测 + G7 上限判据都按设计触发）。这不是门的缺陷，是签入基线该随 #146 更新而没更新。缺陷在合并次序/流程，不在门。

## 3. 设计（方案 A：把 total 基线照 UIKit 侧成熟模式解耦）

### 3.1 关键观察

**UIKit 侧早已解决过同类问题**（codex R6，见 `catalyst-gate.test.sh:235-243`）：自测 fixture 用一份**冻结清单** `fixtures/uikit-expected-tests-frozen.py`（28 名，配套 fixture 日志），通过 `UIKIT_EXPECTED_TESTS_SCRIPT` 注入点喂给所有 `expect` 调用；真 xcodebuild 日志（workflow 真跑）不设该环境变量，仍走默认的**活推导**。所以活源码到 35 不影响 fixture。

破的只有 **total 基线一处**：fixture 的 `expect` 调用（`catalyst-gate.test.sh:18` 的 `bash "$GATE" "$FIX/$fixture"`）**没注入** `CATALYST_TOTAL_BASELINE_FILE`，直接读活 `catalyst-total-baseline.txt`。活基线一改到 1457，delta 窗口挪到 [1427,1487]，fixture 里钉在 1407/1390 的用例掉出窗口 → 5 条自测挂。

### 3.2 改动（4 处 + 1 处可选加固，全在 `.github/scripts/`）

| # | 文件 | 改动 | 消费者 |
|---|---|---|---|
| 1 | `catalyst-uikit-baseline.txt` | 28 → 35（`uikit-expected-tests.py` 对 main 源码确定性重生成） | F1 一致性检测（活） |
| 2 | `catalyst-total-baseline.txt` | 1407 → 1457（真 main 值） | **仅真 CI 构建** |
| 3 | `fixtures/total-baseline-frozen.txt`（**新增**） | `1407`（见 §3.2 冻结值选择） | 自测 fixture（冻结） |
| 4 | `catalyst-gate.test.sh` | 在 `export UIKIT_EXPECTED_TESTS_SCRIPT=…`（:243）旁加 `export CATALYST_TOTAL_BASELINE_FILE="$FIX/total-baseline-frozen.txt"` + 注释（镜像 :235-243 的 UIKit 解释） | — |
| 5（加固，纳入） | `catalyst-gate.test.sh` 补一条自测回归 | 注入**非整数**活基线 → 断言 fail-closed 且报"不是合法整数"。**注**：生产门 `catalyst-gate.sh:215-221` 已对活基线做正整数校验（缺失 + 非整数内容均 fail-closed），无需改生产逻辑；现有自测（:421）只覆盖了"基线缺失"、没覆盖"内容非整数"，本条补齐该空档 | 回归覆盖既有 fail-closed 路径 |

**冻结值的选择（关键决策）**：`fixtures/total-baseline-frozen.txt` 应为 **1407**。理由：现有 total 相关 fixture（`pass-*.log`=1407、`total-baseline-within-delta.log`=1390、`-below-delta`=1300、`-above-delta`=1500、`too-few-tests.log`=500）全是**围绕 1407 构造**的，判据语义（1390 在 [1377,1437] 内→PASS；1300/1500 出界→FAIL）也全相对 1407。冻结值取 1407 则**零 fixture 重裁**、判据语义完全不变。冻结值与活值（1457）从此**永久解耦**——冻结值绑 fixture、活值绑真 CI，各自独立演进。

### 3.3 关键性质

- **零 fixture 重裁**：所有 total 相关 fixture 保持原样。
- **活基线只服务真 CI**：真构建报 1457 vs 活基线 1457 → PASS；自测 fixture 走冻结 1407 → 判据逻辑照测。
- **未来韧性**：谁再增删 >30 测试，只改 `catalyst-total-baseline.txt` 一个文件，自测 fixture 一律不动（这正是 #146 场景该有的维护成本——1 个文件，不是连锁破裂）。
- **UIKit F1 仍活**：`catalyst-uikit-baseline.txt` 保持活比对（增删 UIKit 测试仍须重生成它，这是 F1 的设计意图，不解耦）。

## 4. 验收（全部实跑，不推断）

1. `bash .github/scripts/catalyst-gate.test.sh` → **36/36 通过 0 失败**（F1 转绿 + 5 条 total fixture 用例仍按原语义 PASS/FAIL）
2. `bash .github/scripts/catalyst-gate.sh <真 main 构建日志>`（活基线 35/1457）→ **`GATE PASS`**，回显 `1457`
3. **红-绿对照**：把活 `catalyst-total-baseline.txt` 临时改回 1407 跑真 main 日志 → 必须 `GATE FAIL: 高于上限`（证明活基线判据仍承重、没被解耦削弱）
4. 注入非整数活基线（如 `abc`）经 `CATALYST_TOTAL_BASELINE_FILE` → 闸门 fail-closed 且报"不是合法整数"（补齐现有自测只测"缺失"的空档）
5. 推到 PR 分支后，真 CI 上 `Mac Catalyst build-for-testing on macos-15` **转绿**

## 5. 不做（out of scope）

- 不改 fixture 日志内容（保真度：它们是真实抓取的裁剪件）。
- 不改 `fixtures/uikit-expected-tests-frozen.py`（冻结 28，配套 fixture 日志的 UIKit 结果行，不能动）。
- 不动 `catalyst-build.yml` 的 job 显示名 / scheme / 动作（#145 已定稿，改名=必需 context 失配）。
- `Tests/` 下 48 条既有警告仍只统计不拦（#145 已划为独立残留）。
- 不追加"活 total 基线 vs 真构建"的静态一致性检测（无法在不构建的前提下静态验证真值；真 CI 构建即该检测）。

## 6. 流程

spec → **codex 对抗评审至收敛** → writing-plans → **codex 对抗评审 plan 至收敛** → subagent-driven-development → verification-before-completion → requesting-code-review → **整体 codex 对抗评审** → push → PR（user）→ merge（user）。`.github/scripts/**` 属 `trust_boundary_globs` + `codeowners_required_globs`，故受同等治理保护。

## 7. 教训（记入本 spec 上下文）

- **合并次序会造成语义冲突**：两个 PR 都改同一测试面（UIKit-gated 测试 / 总数），先合的改了源码、后合的基线快照就 stale。**后合的 PR 合并前必须 rebase 到最新 main 并重跑闸门自测**；GitHub"require branch up to date before merging"能拦下这类，本仓未开该项 → 靠人工 rebase 纪律。
- **合并后必须 `gh run watch` 确认 main 真绿**（守则已有）——本次正是靠合并后核查抓到红 main，否则会一直红着堵住全仓。
