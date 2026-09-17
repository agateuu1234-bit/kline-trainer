# acceptance 闸门六条失败的修复 · 设计 spec

**日期**：2026-09-04
**分支**：`fix/acceptance-stale-literals`（**与诊断改动同一分支 / 同一 PR #182**）
**基线**：该分支 `e99bb8f`（其 base 为 `origin/main@1437529`；**不 rebase**，理由见 E6）
⚠️ **`origin/main` 已前进至 `db49f60`（#183）** —— 该漂移**改变了本 spec 的一条论证**，见 **G15**。
**改动面**：三个 acceptance 脚本各一处

**上游 spec**（继续全部生效）：`docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md`
—— 该 spec 的 **D5** 明确要求「拿到 CI 完整失败面后**另开一份 spec** 设计修复」，本文即是。

**本 spec 决策编号 E1–E6**（用 E 前缀，与上游 spec 的 D1–D5 不冲突）。

**类别**：治理 / 工具链改动 —— 走 `superpowers:brainstorming` → `superpowers:writing-plans` → 对抗性评审 → PR。

---

## 0. 一句话

PR #182 的诊断改动让 CI 打出了完整失败面：**`plan_1f` 在 ubuntu 上 25 通过 / 6 失败**。
这 6 条对应**三个性质完全不同**的病灶，本 spec 各给一个修法，目标是让 `acceptance` 真正转绿。

---

## 1. CI 实测的完整失败面（本次修复的唯一依据）

来源：PR #182，run `33774540228`（2026-09-03）。**这是诊断改动买来的东西** ——
在此之前 CI 日志里只有一行 `NG: regression: Plan 1f schema versioning`。

| 层 | 结果 | 失败项 |
|---|---|---|
| `plan_1`（M0.1 DDL） | **4 passed, 0 failed** ✅ | — |
| `plan_1b`（M0.2 REST API） | 4 passed, **1 failed** | `pytest: 11 OpenAPI invariants` |
| `plan_1c`（M0.3 Swift Contracts） | 11 passed, **1 failed** | `swift test: exit 0` |
| **`plan_1f`（M0.1 schema versioning）** | **25 passed, 6 failed** | 上述两条 + 4 条矩阵行 |

`plan_1f` 的 6 条完整清单：

```
- matrix row: CONTRACT_VERSION top | `"1.5"`
- matrix row: PostgreSQL | `0003_v1.3`
- matrix row: app.sqlite | `0003_v1.4_purge_leased`
- matrix row: Swift 模型 | `1.3`
- regression: Plan 1b (M0.2 OpenAPI) acceptance
- regression: Plan 1c (M0.3 Swift Models) acceptance (间接覆盖 Plan 1d AppError swift test)
```

⇒ **6 条 = 3 个病灶，无第四类、无隐藏项**（每一层的失败项都已逐条读出，见上表）。

---

## 2. 三个病灶的性质完全不同

| | 病灶 | 性质 | 为什么不能一锅端 |
|---|---|---|---|
| **A** | `plan_1f` 的 4 条矩阵断言值过期 | 断言**写对了，但值旧了** | 有一个**触发时机正确**的守卫已覆盖其中 3 条 |
| **B** | `plan_1b` 要求「**正好** 11 passed」而实际 19 | 断言的**判据形状错了** —— 把「新增测试」当成缺陷 | 改成当前值只是把跑步机往前推一格 |
| **C** | `swift test` 在 ubuntu 上编译不过 | ⚠️ **断言被放在了错误的平台上** | **这是设计问题，不是改个值** |

---

## 3. 已核实事实台账

| # | 事实 | 证据来源 |
|---|---|---|
| G1 | 完整失败面如 §1（每层逐条读出） | `gh run view 33774540228 --log-failed` |
| G2 | **`ubuntu-latest` 自带 Swift 工具链，`swift test` 真跑起来了**：日志含 `Fetched … GRDB.swift.git from cache (9.65s)`、`Working copy … resolved at 6.29.3`、`Building for debugging...`、**115 行 `Compiling GRDB …`** | 同上 |
| G3 | **真实失败是 `error: no such module 'CoreGraphics'`**（`DecelerationAnimator.swift:6:8`），随后 `error: emit-module command failed with exit code 1` | 同上 |
| **G4（订正）** | `ios/Contracts/Sources` 下 **38 个文件 `import CoreGraphics`，其中 10 个在 `#if` 块内、28 个裸着**；另有 21 个 `import SwiftUI`、17 个 `import UIKit`、1 个 `import QuartzCore`。⚠️ 初稿写「38 个全部未被 `#if` 包住」，**错**（用 Python 跟踪 `#if/#endif` 深度实测得 10/28）。**结论方向不受影响** —— 28 个裸 import 已足以让 Linux 编译失败 | `grep -rl` 计数 + Python 逐文件跟踪块深度 |
| G5 | 仓内**确实使用** `canImport`（36 个文件含该词），但用途是 **iOS 与 Mac Catalyst 之间**的差异 —— `DecelerationAnimator.swift` 注释原文：`CACurrentMediaTime（两平台）`，且该文件同时有 `#if canImport(UIKit)` 与**裸的** `import CoreGraphics` ⇒ **Linux 从不在设计意图之内** | 读该文件 L1–20 |
| G6 | `plan_1c` 共 **12 条断言**，在 ubuntu 上**只有 `swift test: exit 0` 一条失败**（其余 11 条通过） | §1 的 CI 日志 |
| G7 | `plan_1b` 共 5 条断言，在 ubuntu 上**只有 `pytest: 11 OpenAPI invariants` 一条失败** | 同上 |
| G8 | `plan_1` 在 ubuntu 上 **4 条全过** ⇒ 本次无需触碰 | 同上 |
| G9 | `M01MatrixSyncGuardTests.swift` 断言矩阵**三行**：`CONTRACT_VERSION` = `"1.13"`（L52）、`app.sqlite GRDB migration` = `0010_v1.13_drawing_default_style`（L53）、`Swift 模型版本` = `1.4`（L55），与 m01 文档当前值一致；自带防空转 `XCTAssertGreaterThanOrEqual(r.count, 5)` 与解析器免疫测试 | 读源码 |
| G10 | 该守卫由 `swift-contracts-smoke.yml`（`paths: ios/Contracts/**` → `runs-on: macos-15` → `swift test`）触发；最近 8 次运行**全部 success** | 读 workflow + `gh run list --workflow=swift-contracts-smoke.yml --limit 8` |
| G11 | ⚠️ **`swift test on macos-15` 不在必需检查名单里**。当前 ruleset 6 项必需为 `branch-protection-config-self-check` / `codeowners-config-check` / `check-bootstrap-used-once` / `Mac Catalyst build-for-testing on macos-15` / `acceptance` / `collect` | `gh api .../rulesets/15660830` |
| G12 | `plan_1f` 的矩阵断言共 **6 条**（L42/45/48/51/54/57），其中 **4 条已过期**（`"1.5"` / `0003_v1.3` / `0003_v1.4_purge_leased` / `1.3`），另 **2 条恰好仍通过**（训练组 SQLite `1`、P2 journal `v2`） | 读脚本 + §1 的 CI 失败清单 |
| **G13（刷新）** | `main` 现为 **`db49f60`（#183）**（初稿写 `06373ef`/#180，已过期）。`1437529..db49f60` 之间**仍未触碰** `plan_1f` / `plan_1b` / `plan_1c` 三个待改文件（但**触碰了** `plan_b2_generate_training_sets.sh`，见 E-S6 的写法要求） | `git rev-parse origin/main` + `git diff --name-only 1437529..origin/main -- scripts/acceptance/` |
| **G14（刷新）** | **#180「后端 CI 触发路径：取消 paths 过滤器」已合入 main**，与 PR #179 修的是**同一类死锁**（required 检查带过滤器 ⇒ 不匹配的 PR 永不上报）。⚠️ 初稿称它是 main 的「最新提交」，现已被 **#183** 取代 | 读 `origin/main:.github/workflows/backend-tests.yml` 顶部注释 |

| **G15（⚠️ 由 #183 引入，改变了 E1 的一条论证）** | **`training_set_schema_v1.sql` 的 `PRAGMA user_version` 已由 `1` 改为 `2`**（main 上实测），而 `m01` 矩阵那一行**仍写 `1`** ⇒ **`plan_1f` 的 `matrix row: 训练组 SQLite … \| \`1\`` 断言此刻正「绿着」并锁死一个错值**。且 m01 该行的规则原文写「训练组 schema 结构变更；**联动顶层**」，而顶层 `CONTRACT_VERSION` 仍是 `"1.13"` —— **是否需要联动 bump 顶层，待裁定** | `git show origin/main:backend/sql/training_set_schema_v1.sql` + `git show origin/main:docs/governance/m01-…md` 逐行比对 |
| **G16** | 本机（macOS，无 venv）**缺 `pyyaml` 与 `pglast`** ⇒ 实跑 `plan_1b` 得 **`3 passed, 2 failed`**（多挂一条 `yaml: openapi-smoke.yml parse`）。`plan_1`（pglast）与 `plan_1c`（yaml）同理必挂 ⇒ **本机上 `plan_1f` 的三条 `regression:` 全部会红，与本次三处修复无关** | 本人实跑 `plan_1b` + `python3 -c 'import yaml'` / `import pglast` |
| **G18** | **最外层 `hardening_6_framework.sh` 自身还有断言**：共 17 个 `run`，其中 3 个只在 `--final` 模式执行；当前 `enforcement_mode` = `drift-log` ⇒ 走默认模式，**实执行 14 条**。§1 的表只覆盖了嵌套四层，**没覆盖这 14 条** —— acceptance 绿不绿取决于它们也全绿 | `grep -c '^run '` + `jq -r '.skill_gate_policy.enforcement_mode' .claude/workflow-rules.json` |
| **G17** | E3 代码块里 `uname -s` 出现在 **2 行**（`if` 条件一行 + SKIP 文案一行）；`swift test: exit 0` 出现在 **2 行**（`run` 标题 + `else` 分支打印的标题） | 把 E3 代码块逐字落盘后 `grep -cF` 实测 |

---

## 4. 决策

### E1　病灶 A：删除 `plan_1f` 的 **6 条**矩阵断言（不是 4 条）

删除 `plan_1f_m0_1_schema_versioning.sh` L42–59 的全部 6 条 `matrix row:` 断言
（含其配套的 `awk` 切片子进程与 L39–41 的注释块），**不替换、不改写、不迁移**。

**为什么删而不是把 4 个值改对：**

1. **触发时机错误 ⇒ 零信号**。这 6 条只在那 9 个治理文件改动时执行，
   而 `m01` 文档**不在**其中 —— 它们**永远不会在「矩阵真的变了」的时候运行**。
   把值改对，只是把同一台跑步机往前推一格：下次 bump 之后照样烂，照样没人发现。
2. **其中 3 条已被一个触发时机正确、且确实在维护的守卫覆盖（G9/G10）**。
   `M01MatrixSyncGuardTests` 由 `ios/Contracts/**` 改动触发 —— 而 `CONTRACT_VERSION`
   正是在那里被 bump 的；它当前为绿、值与文档同步、自带防空转与解析器免疫。
   ⚠️ **限定（该守卫只在一个方向上有效）**：它覆盖的是「**代码侧 bump 后文档没跟**」这个方向。
   **m01 文档本身不在 `ios/Contracts/**` 下**，所以只改文档、或只改 `backend/sql/**` 的 PR
   **不会触发它** —— **#183 就是活例**（它改了 `backend/sql/training_set_schema_v1.sql`，
   守卫没跑，m01 矩阵就此漂移，见 G15）。
3. **为什么连那 2 条「还没通过」的也删 —— 这条理由已按 G15 大幅加强**：
   初稿写「那 2 行之所以还对，纯粹是因为值碰巧没变过 ⇒ 留着是给**未来**埋坑」。
   **事实比这更糟：坑已经踩了。** #183（2026-09-03/04）把
   `training_set_schema_v1.sql` 的 `PRAGMA user_version` 从 `1` 改成了 `2`，
   而 m01 矩阵那一行**仍写 `1`** ⇒ **`matrix row: 训练组 SQLite … | \`1\`` 此刻正「绿着」
   并锁死一个错值**（它比对的是文档，不是代码）。
   ⇒ 这不是「未来可能腐烂」，是**当下已经烂在了绿的那一侧** ——
   而绿着的腐烂比红着的腐烂更危险，因为没有任何人会去看它。
   **这是「删而不是改值」的最强论据**：删掉之后至少不会有假绿。

### E2　病灶 B：`plan_1b` 的「正好 11 passed」→「**≥11 且零失败**」

把 `plan_1b_m0_2_rest_api.sh` L33–35 改为：

```bash
# 下限断言（≥11）而非等值：新增不变量测试是健康行为，不是 drift；
# 真正危险的是有人【删掉】不变量测试，「≥下限」恰好只抓后者。
# 不用管道：bash -c 不继承外层的 pipefail，管道会吞掉 pytest 的退出码。
run "pytest: OpenAPI invariants (≥11, 0 failed)" \
    bash -c "cd backend && python3 -m pytest tests/test_openapi.py -q > /tmp/plan1b-pytest.out 2>&1; ec=\$?; cat /tmp/plan1b-pytest.out; [ \$ec -eq 0 ] && [ \"\$(sed -n 's/^\\([0-9]\\{1,\\}\\) passed.*/\\1/p' /tmp/plan1b-pytest.out)\" -ge 11 ]"
```

**四条设计要点：**

1. **下限而非等值** —— 原注释写「若将来 test 数变化说明 spec drift」，但**新增不变量测试是健康行为**
   （11 → 19 正是这样发生的）；危险的是**删测试**。「≥下限」只抓后者。
   **同仓已有先例**：`M01MatrixSyncGuardTests` 用的正是 `XCTAssertGreaterThanOrEqual(r.count, 5)` 做防空转下限（G9）。
2. **下限取 11 而非 19** —— 11 是该断言原本记录的不变量数量下限，语义是「不得少于当初」。
   取 19 会在下次正常新增测试后再次面临同一问题的镜像形态。
3. **必须先判 `$ec` 再判计数** —— 只判计数会漏掉「pytest 崩溃 / collection error / 0 个测试被收集」，
   那些情况下 `sed` 取不到数、比较式会因空串报错或误判。
4. **不用管道** —— 这同时**关闭了上游 spec 的残留 R10**（「`plan_1b` L35 的 `| tee` 无 `-o pipefail`」，
   上游明写「转入 D5 的修复 spec 一并处理」）。原写法 `pytest … | tee … && grep …`，`&&` 判的是 `tee` 的退出码；
   而 `run` 把命令交给一个**全新的 `bash -c`**，它**不继承**外层脚本的 `set -o pipefail`
   （同仓 `hardening_6_framework.sh` L83/L85 正是为此显式写 `bash -o pipefail -c`）。
   改为「重定向到文件 → 存 `ec` → `cat` 出来 → 判 `ec` 与计数」，既避开管道，又保留输出可见。

**E2 判据的判别力已实测五档（scratchpad）：**

| 档 | 输入 | 判定 | 说明 |
|---|---|---|---|
| 1 | `19 passed`，exit 0 | **PASS** ✅ | 当前真实情况 |
| 2 | `10 passed`，exit 0 | **FAIL** ✅ | **有人删了测试** —— 这是该判据唯一声称的收益，抓住了 |
| 3 | `1 failed, 18 passed`，exit 1 | **FAIL** ✅ | 真有测试挂了 |
| 4 | `ERROR: found no collectors`，exit 2 | **FAIL** ✅ | collection error，输出里没有 `N passed` |
| 5 | `19 skipped`，exit 0 | **FAIL** ✅ | 全 skip（本仓对 skip 零容忍） |

⇒ **档 2 证明「≥下限」确实抓得住删测试；档 4/5 证明它不会被「没有 passed 行」蒙混过关。**


### E3　病灶 C：`plan_1c` 的 `swift test` 加**平台门**（不是删除）

把 `plan_1c_m0_3_swift_contracts.sh` L41–42 改为：

```bash
# swift test 依赖 Apple 平台专有框架（CoreGraphics / UIKit / SwiftUI / QuartzCore）。
# 实测 28 个源文件裸 import CoreGraphics（另 10 个在 #if 块内）
# ⇒ 在非 Darwin 平台上【结构上】无法编译，不是可修的失败。
# 该覆盖在 CI 上由 swift-contracts-smoke.yml（runs-on: macos-15）承担。
if [[ "$(uname -s)" == "Darwin" ]]; then
    run "swift test: exit 0" \
        bash -c 'cd ios/Contracts && swift test'
else
    echo ""
    echo "========== swift test: exit 0 =========="
    echo "SKIP: 非 Darwin 平台（$(uname -s)）。本 package 依赖 Apple 专有框架"
    echo "      （28 个源文件裸 import CoreGraphics），结构上无法在此编译。"
    echo "      该覆盖由 .github/workflows/swift-contracts-smoke.yml（macos-15）承担。"
fi
```

**为什么是平台门而不是直接删除：**

1. **在 macOS 上这条断言是有效的** —— 直接删会削弱 macOS 侧（包括开发者手工跑 `plan_1c` 的场景）。
   ⚠️ **本条不再引用任何测试计数**：`ios/Contracts` 是**双测试框架**包（XCTest + Swift Testing），
   `swift test` 会打印**两条**摘要行，只读其中一条会严重低估执行量
   （`feedback_uikit_gated_evidence_traps`：判绿读执行量、且要读全）。
   覆盖依据改为「`swift-contracts-smoke.yml` 在 `macos-15` 上跑**同一条命令**」—— 该依据不依赖计数。
2. **把「这条依赖平台」这个事实显式写出来** —— 现状是它**隐含**依赖 Darwin 却假装跨平台，
   这正是本次事故的根源。平台门让隐含依赖变成显式契约。

**为什么这个 skip 可以接受**（本仓对 skip 是零容忍的，必须逐条说明）：

| 顾虑 | 本例的回答 |
|---|---|
| skip 会静默丢覆盖 | **不静默** —— 它打印完整的 `========== 标题 ==========` + 三行原因，与其它断言同格式，在 CI 日志里一眼可见 |
| 判据可能误判 | 判据是 `uname -s`，**不存在模糊地带** |
| 覆盖真的丢了吗 | **没丢**：macOS 侧由 `swift-contracts-smoke.yml` 承担，触发时机正确（`ios/Contracts/**` 改动时跑），最近 8 次全绿（G10） |
| 会不会变成假绿 | 该 skip **不计入 PASS 计数**（不走 `run`），所以 `plan_1c` 的汇总会从 `11 passed, 1 failed` 变成 **`11 passed, 0 failed`** —— 断言总数由 12 降为 11，这是**如实反映**「该平台上只有 11 条可执行」 |

### E4　⚠️ 覆盖缺口：`swift test on macos-15` 不是必需检查（**本次不改**）

E3 落地后，Swift 测试的唯一 CI 执行者是 `swift-contracts-smoke.yml`，
而它**不在必需检查名单里**（G11）。

**本次不把它升为必需**，两条理由：

1. **它带 `paths:` 过滤器**（`ios/Contracts/**` 等）。直接设为必需检查，
   **极可能立刻复现 PR #179 修的那个死锁** —— required 但对不匹配路径的 PR **永不上报**。
   `main` 最新的 #180 正是为同一类问题而做（G14）。⇒ **必须先设计再动，不能顺手做。**
2. 改 ruleset 属治理改动，需**用户明示授权**。

**记为 R-E1，转独立 backlog。**

### E5　不改的东西

- 不碰 `plan_1`（ubuntu 上 4 条全过，G8）；
- 不碰 `plan_1c` 的其余 11 条断言（G6）；
- 不碰 `plan_1b` 的其余 4 条断言（G7）；
- 不碰 `M01MatrixSyncGuardTests.swift`（当前绿且维护良好，G9）；
- 不碰 `m01` 与 `kline_trainer_modules_v1.4.md` 两份文档；
- 不碰任何 workflow、不碰 ruleset（E4）；
- 不给 38 个 `import CoreGraphics` 加条件编译 —— 该 package 本就只为 Apple 平台而生（G4/G5），
  为零收益改近百个文件且极易引入真实回归。

### E6　不 rebase 到新 main

`main` 已至 `06373ef`，但 `1437529..06373ef` **未触碰**三个待改文件（G13）⇒ 无冲突风险。
不 rebase，避免无谓改写提交号。PR 合并时 GitHub 自会与当时的 `main` 合并。

---

## 5. 验证方案

> ⚠️ **本节已按 R1 评审整节重写。** 初稿的 §5.3 要求「本机跑出 `PLAN 1f PASS` / failed=0」——
> 而本机缺 `pyyaml` 与 `pglast`（**G16**），`plan_1`/`plan_1b`/`plan_1c` 三条 `regression:`
> **必然全红**，与本次三处修复无关。⇒ 那三条判据**在本机结构上不可能满足**，
> 实施者照做只会得出「我改坏了」的错误结论。**本版把「本机能验的」与「只有 CI 能验的」彻底分开。**

### 5.1 本机能验的：结构判据（不依赖任何 Python 包）

一行一条敲（`grep -c` 计数为 0 时退出码是 1，**别串进带 `set -e` 的脚本**）：

| # | 命令 | 改动前 | 改动后 |
|---|---|---|---|
| E-S1 | `grep -cF 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | **6** | **0** |
| E-S2 | `grep -cF "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh` | **1** | **0** |
| E-S3 | `grep -cF 'ge 11' scripts/acceptance/plan_1b_m0_2_rest_api.sh` | **0** | **1** |
| E-S4 | `grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh` | **0** | **2** |
| E-S5 | `grep -cF 'swift test: exit 0' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh` | **1** | **2** |
| E-S6 | `git diff --numstat $(git merge-base HEAD origin/main) -- scripts/acceptance/` | 两行（诊断改动） | **五行**：`hardening_6_framework.sh`、`plan_1f…`、`plan_1b…`、`plan_1c…`，外加诊断改动已含的两个文件与本次三个文件的并集 |

> ⚠️ **E-S4 的期望值是 2，不是 1**（初稿写错）：`uname -s` 在 E3 代码块里出现**两行** ——
> `if` 条件一行 + SKIP 文案里 `$(uname -s)` 一行（**G17**）。
> 若实施者为了凑成 1 而删掉文案里的那个，恰好削掉了 skip 分支唯一一处「告诉你当前平台是什么」的信息，
> 而那正是 E3 表格里「不静默」那一栏的凭据。
>
> ⚠️ **E-S6 必须钉 merge-base，不能用 `origin/main`**：`main` 会继续前进
> （初稿写作时是 `06373ef`，现已是 `db49f60`），用 `origin/main` 会把 **main 自己的改动**
> 算进来（实测 #183 改了 `plan_b2_generate_training_sets.sh`，会凭空多出一行），
> 让实施者误判「范围超了」进而去"清理"一个自己根本没碰的文件 —— **那才是真事故**。
>
> ⚠️ 全部用 `grep -cF`（定长串）—— 本机 `grep` 是 ugrep。**E-S1 初稿漏了 `-F`，本版已补**。

### 5.2 本机能验的：E2 判据的判别力（不需要真跑 pytest）

把 E2 那行**逐字**抽出，配一个假的 `python3` shim 灌入各种输出与退出码。
**这是本节唯一能在本机验「新判据是否真有判别力」的手段** —— 真跑 pytest 需要 `pyyaml`（G16）。

| 档 | 输入 | 期望判定 | 说明 |
|---|---|---|---|
| 1 | `19 passed`，exit 0 | **PASS** | 当前真实情况 |
| 2 | `10 passed`，exit 0 | **FAIL** | **有人删了测试** —— 该判据唯一声称的收益 |
| 3 | `1 failed, 18 passed`，exit 1 | **FAIL** | 真有测试挂了 |
| 4 | `ERROR: found no collectors`，exit 2 | **FAIL** | collection error |
| 5 | `19 skipped`，exit 0 | **FAIL** | ⚠️ 见下方限定 |
| 6 | **`12 passed, 7 skipped`，exit 0** | **PASS** | ⚠️ **局部 skip 会穿透** |
| 7 | `11 passed`，exit 0 | **PASS** | 边界值 |
| 8 | `19 passed` 但 exit 1 | **FAIL** | 证明先判 `$ec` 的短路有效 |

> ⚠️ **关于档 5 与档 6 的诚实限定**（初稿把档 5 的说明写成「本仓对 skip 零容忍」，**误导**）：
> 档 5 之所以 FAIL，是因为输出里**根本没有 `N passed` 行** ⇒ `sed` 取不到数，
> **不是**因为判据认得 skip。档 6 实测**穿透**（`12 passed, 7 skipped` 判 PASS）。
> ⇒ **本判据不守 skip。** 真正守 skip 的是 `backend-tests.yml`（解析 junit XML，`skipped>0` 即 fail），
> 但那是另一条 workflow，`plan_1b` 这条断言**不继承**它。**记为 R-E9。**

### 5.3 本机能验的：平台门在 **Darwin 侧**走执行分支

```bash
bash scripts/acceptance/plan_1c_m0_3_swift_contracts.sh > /tmp/e-p1c.log 2>&1
grep -A3 '========== swift test: exit 0 ==========' /tmp/e-p1c.log
```

**期望**：看到 `swift test` **真的被执行**（不是 `SKIP:`）。

> ⚠️ **这一条不可省。** 只在 Linux 上验「跳过了」是不够的 ——
> 一个**恒真跳过**的门会伪装成工作正常
> （`feedback_all_reject_suite_masks_always_throwing_guard` 的同族形态）。
> 必须两侧都验：Darwin 走执行分支（本节）、Linux 走跳过分支（§5.5 E-C2）。

### 5.4 本机**不能**验的（明确声明，不许含糊）

| 命题 | 为什么本机验不了 |
|---|---|
| `plan_1f` 转绿 / `PLAN 1f PASS` / failed=0 | 本机缺 `pyyaml`、`pglast`（G16）⇒ 三条 `regression:` 必红，**与本次修复无关** |
| 平台门的 **Linux 分支** | 本机 `uname -s` 恒为 `Darwin`。⛔ **不得**用「把 `uname` 结果硬改掉」的方式伪造验证 —— 那验的是被篡改的判据，不是真实路径 |
| `acceptance` 整体转绿 | 同上，且还取决于最外层 14 条断言（G18） |

**本机可用的替代判据（前后对比，非绝对值）**：

```bash
# 改动前
bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/e-before.log 2>&1
grep -E '^Plan 1f .* acceptance:' /tmp/e-before.log
# 改动后
bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/e-after.log 2>&1
grep -E '^Plan 1f .* acceptance:' /tmp/e-after.log
```

**期望**：`failed` 数**从 7 降到 3**，且降掉的正好是**4 条矩阵行**
（剩下的 3 条 = `plan_1`/`plan_1b`/`plan_1c` 三条 `regression:`，均为**本机缺依赖**所致，见 G16）。
⚠️ **判据是「前后差值与降掉的具体项」，不是某个绝对数字。**

### 5.5 CI 级（唯一能验 Linux 分支与整体转绿的地方）

推送后看 PR #182 的 `acceptance`：

| # | 判据 | 期望 |
|---|---|---|
| E-C1 | `acceptance` 检查 | **绿** —— 这是本次修复成立的**最终判据** |
| E-C2 | 日志里 `swift test: exit 0` 那段 | 出现 **`SKIP: 非 Darwin 平台（Linux）`** —— 证明平台门在 Linux 上走跳过分支 |
| E-C3 | `plan_1f` 汇总行 | `N passed, **0** failed` |
| E-C4 | 最外层 `hardening_6_framework` 汇总行 | `N passed, **0** failed`（G18：最外层还有 14 条断言，它们也必须全绿） |

> ⚠️ **E-C1 与上游 spec 的 D3 在此交接**：上游 spec 说「本 PR 不会让 acceptance 变绿，这是有意的」——
> 那是**诊断阶段**的状态。本 spec 落地后该约束**解除**：`acceptance` 转绿即为可合并。

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R-E1** | `swift test on macos-15` 不是必需检查（G11）⇒ E3 之后 Swift 测试无必需检查强制 | **现状即如此**，非本次引入：ubuntu 那份是**恒红**的，从不提供有效信号。但确实是缺口 | **接受**，转独立 backlog。⚠️ 升为必需**必须先设计**：它带 `paths` 过滤器，直接设必需极可能复现 #179 的死锁（E4） |
| **R-E2（已按 G15 具体化）** | 删掉 6 条矩阵断言后，**PostgreSQL migration id / 训练组 SQLite user_version / P2 journal states** 三行无任何自动守卫（已全仓扫描确认：`P2 journal states` 仅在 `plan_1f` 出现一处；PostgreSQL 那行除 `M01MatrixSyncGuardTests` 的**反例样本**外无任何断言；`UserVersionAssertionGuardTests` 守的是**代码里的断言站点**，不读 m01 文档） | 删除前它们的守卫**也是零信号** ⇒ 不是净损失。<br>⚠️ **但 backlog 条目必须写具体待办，不能只写抽象缺口**：**m01 矩阵训练组行 doc=`1` / code=`2`（源自 #183），需订正；且该行规则写明「联动顶层」而顶层仍是 `"1.13"`，是否需要联动 bump 待裁定**（G15） | **接受**，转独立 backlog（含上述具体待办） |
| **R-E8** | `plan_1d_m0_4_apperror.sh:42-43` 有一处与 `plan_1c` **逐字相同**的 `swift test` 断言；另 `plan_c3` / `plan_c4` / `plan_u3` / `plan_u6` 共 4 处也裸跑 `swift test` —— 全都带着 E3 要修的那个「隐含依赖 Darwin」缺陷 | **不在 acceptance 路径上**（已逐层核实：`hardening_6` 只嵌 `plan_1` 与 `plan_1f`；`plan_1f` 只嵌 `plan_1`/`plan_1b`/`plan_1c`，**刻意不嵌 `plan_1d`**）⇒ 不影响本次转绿 | **接受，本次不改**，登记以免下一个人从零发现一遍（守则：改判据要按判据本身穷尽全仓） |
| **R-E9** | **E2 的新判据不守 skip**：`12 passed, 7 skipped` + exit 0 会**判 PASS**（实测）。§5.2 档 5 之所以 FAIL 是因为没有 `N passed` 行，不是因为认得 skip | 真正守 skip 的是 `backend-tests.yml`（解析 junit XML，`skipped>0` 即 fail），但 `plan_1b` 这条断言**不继承**它 | **接受**，如实记录；若要守 skip 需另行设计 |
| **R-E3** | `plan_e2_position_manager.sh` 仍带 2 条同族红断言，且其 L37 用绿灯锁死 `kline_trainer_modules_v1.4.md` 的错值 | 既有故障，超出本次范围（本次只修 `acceptance` 闸门路径上的） | 转独立 backlog |
| **R-E4** | `kline_trainer_modules_v1.4.md` 矩阵落后 8 版，与 m01 分叉 | 治理文档不一致 | 转独立 backlog；需先厘清两份矩阵谁是权威 |
| **R-E5** | E3 之后 `plan_1c` 在 Linux 上断言数由 12 降为 11 | **如实反映**该平台上只有 11 条可执行；skip 大声打印、不计入 PASS | 接受 |
| **R-E6（定性已加重）** | `m01` L125 **不只是提了一句** —— 它是一条 **accepted residual + 明确的升级触发点**：「触发升级时机：Plan 2 B3 首次真 migration PR 时借道扩 acceptance 断言至『行内 3 列全配』+『A/B bullet 独立断言』」。E1 删掉断言 = **静默注销这条承诺** | 初稿定性为「纯文档腐烂」**偏轻** | **接受**，但 backlog 条目必须写明：该 R7-hardening 升级承诺失去载体，需**显式作废**或改挂到 R-E2 的新守卫上 |
| **R-E7** | 本 PR 不 rebase 到 `06373ef`（E6） | `1437529..06373ef` 未触碰三个待改文件（G13）⇒ 无冲突风险 | 接受 |

---

## 7. 明确不做

见 E5。另外：**不修改上游 spec 的任何决策** —— 本 spec 只承接其 D5 的委托。

---

## 8. 考虑过并否决的替代方案

| 方案 | 内容 | 否决理由 |
|---|---|---|
| **α** | 病灶 A 改为「把 4 个值更新到当前值」 | 不触碰根因（触发时机错误 ⇒ 从不运行 ⇒ 必然再次腐烂）。且与 `M01MatrixSyncGuardTests` 构成重复维护面 |
| **β** | 病灶 B 改为「把 11 改成 19」 | 同上：下次正常新增 OpenAPI 不变量测试后立刻再次失效。且它把「新增测试」错误地当作缺陷信号 |
| **γ** | 病灶 C 改为「给 38 处 `import CoreGraphics` 加条件编译，让它在 Linux 上编译通过」 | 近百个文件的改动面，为**零收益**服务（这就是个 iOS app 的契约层，没有任何人会在 Linux 上运行它），且极易引入真实回归。G4/G5 已证 Linux 从不在设计意图内 |
| **δ** | 病灶 C 改为「直接删掉 `swift test` 那条断言」 | 会削弱 macOS 侧 —— 该断言在 Darwin 上是有效的，开发者手工跑 `plan_1c` 时应当继续覆盖。（⚠️ 初稿此处引用「本地实测 302 测试全过」，**已删** —— 该包是双测试框架，只读一条摘要会严重低估执行量） |
| **ε** | 病灶 C 改为「让 `plan_1f` 不再嵌套 `plan_1c`」 | 会连带丢掉 `plan_1c` 另外 11 条与平台无关的断言（G6） |
| **ζ** | 顺手把 `swift test on macos-15` 升为必需检查 | 它带 `paths` 过滤器，直接设必需**极可能复现 #179 的死锁**（E4）。必须先设计再动，且改 ruleset 需用户授权 |

---

## 9. 回滚方案

三处改动、三个文件，均为**修改断言**，无数据、无状态、无迁移。

本 spec 的实施预计产生 **1 个提交**（三处一并）。但**本 PR 最终包含诊断 + 修复两部分**，回滚要分清撤哪一层：

- **只撤修复层**（PR 未合并时）：`git revert --no-edit <修复那个提交的 sha>` ⇒ 回到「能看见失败但没修」的状态。
- **撤整个 PR**（已合并后）：`git revert --no-edit <squash 提交 sha>`（若为 merge commit 用 `-m 1`）
  ⇒ **诊断与修复一起撤销**，`acceptance` 回到「红且看不见原因」。**撤销后必须立刻重跑闸门确认实际状态。**

⛔ `git revert` **没有 `-q` 选项**，误写会只打印 usage 而什么都不做。

**回滚后核实**（四条，一行一条敲）：

```bash
grep -cF 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
grep -cF 'ge 11' scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'swift test: exit 0' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
```

**期望依次为 `6` / `1` / `0` / `0` / `1`**（前四条已在当前树实跑确认）。

- **前两条**：旧形态回来了；**第三、四条**：新形态消失了 —— 双向，缺一不可。
- **第五条是按 R1-M6 补的**：`plan_1c` 原先只有第三条（单向）——
  「正确回滚」与「回滚时把整个 `swift test` 断言连 `run` 那行一起删掉」**都返回 0**，
  而后者会让 macOS 侧的覆盖**从此消失且无人察觉**。第五条锁的是「`run` 那行还在」
  （改动后为 2，回滚后应回到 **1**）。

---

## 10. 交付与流程

1. 本 spec 提交；
2. 对抗性评审（⚠️ codex 配额耗尽至 **2026-09-07 13:31**；期间若需评审，用户已多次授权改用独立 Opus 子代理，**该通道不写 attest 账本**）；
3. 收敛后 → `superpowers:writing-plans`；
4. 实施 → 追加提交到 **PR #182** → CI 上验 `acceptance` 转绿（E-C1）；
5. 绿了才可合并。

**push 由用户在自己的终端执行。**

---

## 11. 评审轮次记录

### R1 · **Opus 子代理**对抗性评审 · 2026-09-04 · HEAD `e99bb8f` → **needs-attention**（1 high / 7 medium / 4 low）

> ⚠️ codex 配额耗尽至 **2026-09-07 13:31**，用户已授权改用独立 Opus 子代理。**本轮不写 attest 账本。**
> 该评审员独立复核 14 条台账、**独立实测 E2 判据 12 档**（比 spec 自测的 5 档多 7 档）、
> 并逐条实跑了 §9 的四条回滚命令。

**评审员确认三个决策的方向都站得住**（E1 删而不改值 / E2 下限+先判退出码 / E3 平台门而非删除），
但挖出的问题里有三条会**直接绊住实施者**，一条**改变了论证基础**。

| # | 严重度 | Finding | 我的复核 | 处置 |
|---|---|---|---|---|
| **H1** | **high** | §5.3 的行为判据（`PLAN 1f PASS` / failed=0）**在本机结构上不可能满足** —— 本机缺 `pyyaml`/`pglast`，三条 `regression:` 必红，与本次修复无关 | **成立，我实跑坐实**：`plan_1b` 得 `3 passed, 2 failed`（多挂 `yaml: openapi-smoke.yml parse`）；`import yaml` / `import pglast` 均 ImportError（**G16**） | §5 **整节重写**，把「本机能验的」与「只有 CI 能验的」彻底分开；本机改用**前后差值**判据（failed 由 7 降到 3，且降掉的正好是 4 条矩阵行） |
| **M1** | medium | **#183 已把训练组 `PRAGMA user_version` 从 `1` 改成 `2`**，而 m01 矩阵仍写 `1` ⇒ `plan_1f` 那条断言**此刻正绿灯锁死错值**。E1 理由 3 的「值碰巧没变过」今天是错的 | **成立，我实读 main 坐实**（**G15**） | E1 理由 3 改写：**坑已经踩了，且烂在绿的那一侧**（比红着更危险，因为没人会去看）。这反而成了「删而不改值」的**最强论据**。R-E2 补上具体待办 |
| **M2** | medium | G4「38 个全部未被 `#if` 包住」**不属实** —— 实测 10 个被包住、28 个裸着。该错数字会被写进长期留仓的**源码注释** | **成立，我用 Python 跟踪块深度复核得 10/28** | G4 订正；E3 代码块注释同步改为「28 个未加任何条件编译」。**结论方向不受影响**（28 个已足够） |
| **M3** | medium | E-S4 期望值算错：`uname -s` 在 E3 代码块里出现 **2 行**（`if` 条件 + SKIP 文案），spec 写 1 | **成立**（**G17**） | E-S4 改为 2，并写明「为凑成 1 而删掉文案里那个，恰好削掉 skip 分支唯一一处平台信息」 |
| **M4** | medium | E-S6 用 `origin/main` 做基准，**现在就已经返回三行**（多出 main 自己改的 `plan_b2`），既抓不到范围超了也抓不到范围少了，还会让实施者去"清理"自己没碰的文件 | **成立** | E-S6 改钉 **merge-base**：`git diff --numstat $(git merge-base HEAD origin/main)`。**我实跑验证**：只返回诊断改动的两行，不含 `plan_b2` ✅ |
| **M5** | medium | 「6 条 = 3 个病灶，无第四类」的穷尽性论证**漏掉最外层** —— `hardening_6_framework.sh` 自身 14 条断言一条都没入表 | **成立** | 新增 **G18**；§5.5 加 **E-C4**（最外层汇总也必须 0 failed） |
| **M6** | medium | §9 回滚判据自称双向，但对 `plan_1c` **只有单向** —— 「正确回滚」与「把整个 `swift test` 断言连 `run` 一起删掉」都返回 0 | **成立** | §9 加第五条：`grep -cF 'swift test: exit 0' …plan_1c…` 期望 **1**（改动后 2、回滚后回到 1） |
| **M7** | medium | 同族判据没穷尽全仓：`plan_1d:42-43` 有一处与 `plan_1c` **逐字相同**的 `swift test` 断言，另 4 处也裸跑，全 spec 一字未提 | **成立**（且评审员核实它们**不在** acceptance 路径上，不影响本次转绿） | 新增 **R-E8** 登记这 5 处 |
| **L1** | low | E2 判据**对局部 skip 完全穿透**（`12 passed, 7 skipped` → PASS），而 §4 的说明暗示它守住了 skip | **成立** —— 档 5 之所以 FAIL 是因为没有 `N passed` 行，不是认得 skip | §5.2 加诚实限定；新增 **R-E9** |
| **L2** | low | E1 理由 2 的「触发时机正确」**只在一个方向成立** —— m01 文档不在 `ios/Contracts/**` 下，只改文档或只改 `backend/sql/**` 的 PR 不触发该守卫（**#183 就是活例**） | **成立** | E1 理由 2 补限定 |
| **L3** | low | R-E6 把一条**已登记的升级承诺**写成「纯文档腐烂」 —— m01 L125 是 accepted residual + 明确升级触发点，E1 删掉断言等于**静默注销** | **成立** | R-E6 定性加重，backlog 条目必须写明需显式作废或改挂 |
| **L4** | low | 若干小不一致：E-S1 漏 `-F`；头部基线写 `a596014` 而实为 `e99bb8f`；上游 spec 的 **R10**（`plan_1b` 的 `\| tee` 无 pipefail）实际**已被 E2 关闭**但本 spec 没提，残留关闭链断了 | **全部成立** | 逐条修；并在 E2 写明它同时关闭了上游 R10 |

**未采纳 / 需订正评审员的部分**：

- 评审员对 **G2**（`swift test` 本地 302 测试）提出质疑，认为 `ios/Contracts` 是双测试框架包
  （XCTest + Swift Testing），302 只是 XCTest 那一半，Swift Testing 的两千多条**没被看到**。
  **该质疑成立且重要**，但我**未采用它推算的具体数字**（它自己声明「未实跑 `swift test`，为声明计数 + 历史基线推证」）。
  ⇒ 处置：**把该数字从 E3 的论证里删掉**，改用「`swift-contracts-smoke.yml` 在 macos-15 上跑同一条命令」
  作为覆盖依据 —— 该依据不依赖任何测试计数。

**本轮的方法论教训**：

1. **⭐ 上游依赖会在你写 spec 的过程中变化。** 本 spec 写作期间 `main` 从 `06373ef` 走到 `db49f60`，
   而 **#183 恰好改动了本 spec 论证所依赖的一个值**（训练组 `user_version` 1→2）。
   ⇒ **凡是引用「当前值」的论证，都要在评审前重新取一次**；且**判据里凡是拿 `origin/main` 当基准的，
   一律改钉 merge-base** —— 否则 main 一动判据就失真。
2. **「我的结论方向对」不等于「我的事实陈述对」。** G4 的 38/38 与结论方向无关（28 个已足够），
   但那个错数字**会被写进长期留仓的源码注释**，将来有人按它估工作量就会被误导。
   ⇒ **要写进代码注释的数字，验证标准比写进 spec 更高。**
