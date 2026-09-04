# acceptance 闸门六条失败的修复 · 设计 spec

**日期**：2026-09-04
**分支**：`fix/acceptance-stale-literals`（**与诊断改动同一分支 / 同一 PR #182**）
**基线**：该分支 `a596014`（其 base 为 `origin/main@1437529`；**不 rebase**，理由见 §7）
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
| G4 | `ios/Contracts/Sources` 下 **38 个文件 `import CoreGraphics`，38 个全部未被 `#if` 包住**；另有 21 个 `import SwiftUI`、17 个 `import UIKit`、1 个 `import QuartzCore` | `grep -rl` 逐类计数 |
| G5 | 仓内**确实使用** `canImport`（36 个文件含该词），但用途是 **iOS 与 Mac Catalyst 之间**的差异 —— `DecelerationAnimator.swift` 注释原文：`CACurrentMediaTime（两平台）`，且该文件同时有 `#if canImport(UIKit)` 与**裸的** `import CoreGraphics` ⇒ **Linux 从不在设计意图之内** | 读该文件 L1–20 |
| G6 | `plan_1c` 共 **12 条断言**，在 ubuntu 上**只有 `swift test: exit 0` 一条失败**（其余 11 条通过） | §1 的 CI 日志 |
| G7 | `plan_1b` 共 5 条断言，在 ubuntu 上**只有 `pytest: 11 OpenAPI invariants` 一条失败** | 同上 |
| G8 | `plan_1` 在 ubuntu 上 **4 条全过** ⇒ 本次无需触碰 | 同上 |
| G9 | `M01MatrixSyncGuardTests.swift` 断言矩阵**三行**：`CONTRACT_VERSION` = `"1.13"`（L52）、`app.sqlite GRDB migration` = `0010_v1.13_drawing_default_style`（L53）、`Swift 模型版本` = `1.4`（L55），与 m01 文档当前值一致；自带防空转 `XCTAssertGreaterThanOrEqual(r.count, 5)` 与解析器免疫测试 | 读源码 |
| G10 | 该守卫由 `swift-contracts-smoke.yml`（`paths: ios/Contracts/**` → `runs-on: macos-15` → `swift test`）触发；最近 8 次运行**全部 success** | 读 workflow + `gh run list --workflow=swift-contracts-smoke.yml --limit 8` |
| G11 | ⚠️ **`swift test on macos-15` 不在必需检查名单里**。当前 ruleset 6 项必需为 `branch-protection-config-self-check` / `codeowners-config-check` / `check-bootstrap-used-once` / `Mac Catalyst build-for-testing on macos-15` / `acceptance` / `collect` | `gh api .../rulesets/15660830` |
| G12 | `plan_1f` 的矩阵断言共 **6 条**（L42/45/48/51/54/57），其中 **4 条已过期**（`"1.5"` / `0003_v1.3` / `0003_v1.4_purge_leased` / `1.3`），另 **2 条恰好仍通过**（训练组 SQLite `1`、P2 journal `v2`） | 读脚本 + §1 的 CI 失败清单 |
| G13 | `main` 已前进至 `06373ef`；`1437529..06373ef` 之间**未触碰** `plan_1f` / `plan_1b` / `plan_1c` 三个待改文件 | `git diff --name-only 1437529..origin/main -- scripts/acceptance/` |
| G14 | `main` 最新提交 **#180「后端 CI 触发路径：取消 paths 过滤器，每个 PR 都跑后端测试」** —— 与 PR #179 修的是**同一类死锁**（required 检查带过滤器 ⇒ 不匹配的 PR 永不上报） | `git log --oneline -1 origin/main` |

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
3. **为什么连那 2 条「还没烂」的也删（G12）**：留着它们会造成
   「同一张表 6 行里 2 行有断言、4 行没有」的畸形状态，而那 2 行之所以还对，
   纯粹是因为它们的值**碰巧没变过**。留着是给未来埋一个「看起来有守卫其实是巧合」的坑。

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
4. **不用管道** —— 原写法 `pytest … | tee … && grep …`，`&&` 判的是 `tee` 的退出码；
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
# swift test 依赖 Apple 平台专有框架（CoreGraphics / UIKit / SwiftUI / QuartzCore，
# 全部未加条件编译）⇒ 在非 Darwin 平台上【结构上】无法编译，不是可修的失败。
# 该覆盖在 CI 上由 swift-contracts-smoke.yml（runs-on: macos-15）承担。
if [[ "$(uname -s)" == "Darwin" ]]; then
    run "swift test: exit 0" \
        bash -c 'cd ios/Contracts && swift test'
else
    echo ""
    echo "========== swift test: exit 0 =========="
    echo "SKIP: 非 Darwin 平台（$(uname -s)）。本 package 依赖 Apple 专有框架"
    echo "      （38 个文件 import CoreGraphics，全部未加条件编译），结构上无法在此编译。"
    echo "      该覆盖由 .github/workflows/swift-contracts-smoke.yml（macos-15）承担。"
fi
```

**为什么是平台门而不是直接删除：**

1. **在 macOS 上这条断言是有效的** —— 本地实测 `swift test` 跑出 302 个测试全过。
   直接删会削弱 macOS 侧（包括开发者手工跑 `plan_1c` 的场景）。
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

### 5.1 负向对照（改动前，必做）

在 `#182` 分支当前状态（**已含诊断改动**，故本地也能看见明细）跑：

```bash
bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/e-before.log 2>&1
grep -E '^Plan 1f .* acceptance:' /tmp/e-before.log
grep -c 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
```

**期望**：`plan_1f` 汇总为 `24 passed, 7 failed`（本机无 venv 时；⚠️ **具体数字随环境变，判据是「前后对比」不是某个值**）；
后三条依次为 **6** / **1** / **0**。

### 5.2 结构判据（改动后）

| # | 命令 | 改动前 | 改动后 |
|---|---|---|---|
| E-S1 | `grep -c 'matrix row:' …plan_1f…` | **6** | **0** |
| E-S2 | `grep -cF "'^11 passed'" …plan_1b…` | **1** | **0** |
| E-S3 | `grep -cF 'ge 11' …plan_1b…` | **0** | **1** |
| E-S4 | `grep -cF 'uname -s' …plan_1c…` | **0** | **1** |
| E-S5 | `grep -cF 'swift test: exit 0' …plan_1c…` | **1** | **2**（`run` 那条 + `else` 分支打印的标题） |
| E-S6 | `git diff --numstat origin/main -- scripts/acceptance/` | 仅诊断改动的两行 | 三个文件都出现 |

> ⚠️ 全部用 `grep -cF`（定长串）—— 本机 `grep` 是 ugrep。
> ⚠️ `grep -c` 计数为 0 时退出码是 1，**一行一条单独敲**。

### 5.3 行为判据（改动后）

```bash
bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/e-after.log 2>&1
echo "exit=$?"
grep -E '^Plan 1f .* acceptance:' /tmp/e-after.log
grep -E '^PLAN 1f (PASS|FAIL)$' /tmp/e-after.log
grep -A3 '========== swift test: exit 0 ==========' /tmp/e-after.log
```

| # | 判据 | 期望 |
|---|---|---|
| E-B1 | `plan_1f` 退出码 | **0** |
| E-B2 | `plan_1f` 结论行 | **`PLAN 1f PASS`** |
| E-B3 | 汇总行的 **failed 数** | **0** |
| E-B4 | 本机（macOS）上 `swift test` 那段 | 应看到 **`run` 真跑**（不是 SKIP）—— 证明平台门在 Darwin 上走的是执行分支 |

> ⚠️ **E-B4 是平台门的关键判别力**：只在 Linux 上验「跳过了」是不够的，
> 必须同时在 macOS 上验「**没有**跳过」。否则一个恒真跳过的门会伪装成工作正常
> （`feedback_all_reject_suite_masks_always_throwing_guard` 的同族形态）。

### 5.4 CI 级（唯一能验 Linux 分支的地方）

推送后看 PR #182 的 `acceptance`：

| # | 判据 | 期望 |
|---|---|---|
| E-C1 | `acceptance` 检查 | **绿** —— 这是本次修复成立的最终判据 |
| E-C2 | 日志里 `swift test: exit 0` 那段 | 出现 **`SKIP: 非 Darwin 平台（Linux）`** —— 证明平台门在 Linux 上走的是跳过分支 |
| E-C3 | `plan_1f` 汇总行 | `N passed, **0** failed` |

> ⚠️ **E-C1 与上游 spec 的 D3 在此交接**：上游 spec 说「本 PR 不会让 acceptance 变绿，这是有意的」——
> 那是**诊断阶段**的状态。本 spec 落地后，该约束**解除**：`acceptance` 转绿即为可合并。

### 5.5 明确不做的验证

- **不在本机验证 Linux 分支**（本机是 Darwin，`uname -s` 恒为 `Darwin`）。
  Linux 侧只能由 CI 验（E-C2）。**不得**用「把 `uname` 结果硬改掉」的方式伪造验证 ——
  那验的是被篡改的判据，不是真实路径。

---

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R-E1** | `swift test on macos-15` 不是必需检查（G11）⇒ E3 之后 Swift 测试无必需检查强制 | **现状即如此**，非本次引入：ubuntu 那份是**恒红**的，从不提供有效信号。但确实是缺口 | **接受**，转独立 backlog。⚠️ 升为必需**必须先设计**：它带 `paths` 过滤器，直接设必需极可能复现 #179 的死锁（E4） |
| **R-E2** | 删掉 6 条矩阵断言后，**PostgreSQL migration id / 训练组 SQLite user_version / P2 journal states** 三行无任何自动守卫 | 删除前它们的守卫**也是零信号**（触发时机错误 + 4/6 已烂）⇒ 不是净损失，但确是缺口 | **接受**，转独立 backlog：需一个 **backend 侧**触发的守卫 |
| **R-E3** | `plan_e2_position_manager.sh` 仍带 2 条同族红断言，且其 L37 用绿灯锁死 `kline_trainer_modules_v1.4.md` 的错值 | 既有故障，超出本次范围（本次只修 `acceptance` 闸门路径上的） | 转独立 backlog |
| **R-E4** | `kline_trainer_modules_v1.4.md` 矩阵落后 8 版，与 m01 分叉 | 治理文档不一致 | 转独立 backlog；需先厘清两份矩阵谁是权威 |
| **R-E5** | E3 之后 `plan_1c` 在 Linux 上断言数由 12 降为 11 | **如实反映**该平台上只有 11 条可执行；skip 大声打印、不计入 PASS | 接受 |
| **R-E6** | `m01` 文档 L125 的治理 backlog 描述「`plan_1f` 的 CONTRACT_VERSION 矩阵 6 行断言」，E1 删除后该文本指向不存在的对象 | 纯文档腐烂，无守卫会红 | 接受，记录在案 |
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
| **δ** | 病灶 C 改为「直接删掉 `swift test` 那条断言」 | 会削弱 macOS 侧 —— 该断言在 Darwin 上是有效的（本地实测 302 测试全过），开发者手工跑 `plan_1c` 时应当继续覆盖 |
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
grep -c 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
grep -cF 'ge 11' scripts/acceptance/plan_1b_m0_2_rest_api.sh
```

**期望依次为 `6` / `1` / `0` / `0`**（= 三处修复已全部撤销、旧形态已回来）。
**前两条为「旧形态回来了」、后两条为「新形态消失了」** —— 双向判据，缺一不可
（只查单向时「整段删掉」也会返回同样的值）。

---

## 10. 交付与流程

1. 本 spec 提交；
2. 对抗性评审（⚠️ codex 配额耗尽至 **2026-09-07 13:31**；期间若需评审，用户已多次授权改用独立 Opus 子代理，**该通道不写 attest 账本**）；
3. 收敛后 → `superpowers:writing-plans`；
4. 实施 → 追加提交到 **PR #182** → CI 上验 `acceptance` 转绿（E-C1）；
5. 绿了才可合并。

**push 由用户在自己的终端执行。**
