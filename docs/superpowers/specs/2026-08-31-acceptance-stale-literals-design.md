# acceptance 闸门失败不可观测 · 设计 spec（诊断先行）

**日期**：2026-08-31（**2026-09-02 按对抗性评审重定范围**）
**基线**：`origin/main` `1437529`
**分支**：`fix/acceptance-stale-literals`，worktree `.dev/worktree/fix-acceptance-stale-literals`
**改动面**：`scripts/acceptance/hardening_6_framework.sh`（**2 处**）+ `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（3 处）—— **同一种机械变换重复 5 次**（5 删 5 加）：重定向改流式 `tee` + 加 `-o pipefail`

**本 spec 自成一支**，决策编号 **D1–D5** 仅在本文件内有效。

**类别**：治理 / 工具链改动 —— 走 `superpowers:brainstorming` → `superpowers:writing-plans` → 对抗性评审 → PR。

**触发来源**：PR **#179** 的必需检查 `acceptance` 变红。排查确认该红灯**与 #179 无关**（§1），是既有故障。

> ## ⚠️ 范围已于 2026-09-02 重定 —— 读这份 spec 前必须知道
>
> **初稿的范围是「修掉过期字面量」**（删 `plan_1f` 6 条断言 + 改 `plan_1b` 1 条）。
> 一轮 Opus 对抗性评审（§11）推翻了初稿的三条事实台账，并指出一个**决定性问题**：
> **我们目前无法知道 `acceptance` 到底为什么红** —— `plan_1f` 的输出被重定向到
> `/tmp/p1f.log`，而该文件**从未被打印过**（F17），CI 日志里关于它的全部信息只有一行
> `NG: regression: Plan 1f schema versioning`。
>
> 而 `plan_1f` 内嵌的 `plan_1c` 会执行 **`swift test`**（F18），闸门却跑在 **`ubuntu-latest`** 上（F19）——
> 这条路径**从未被任何证据覆盖**。因此**初稿宣称的修复效果（让闸门变绿）无法从现有证据推出**。
>
> ⇒ **本 spec 重定为「诊断先行」**：本次**只**让失败可观测，**不**做任何断言修复。
> 真正的修复待拿到 CI 的完整失败面后另行设计（D5）。
> 用户已于 2026-09-02 明示选择该范围。

---

## 0. 一句话

把 acceptance 闸门里被重定向吞掉的日志改成**运行时流式输出**（5 处，每一层都改），
使「哪一小项挂了、为什么」在 CI 上直接可见；**进程挂住 / job 被取消时，
至少可见「卡在哪一层」**（更深的内容受生产者 stdio 缓冲限制，见 **R8**）。
本次**不修复任何断言**。

---

## 1. 红灯与 PR #179 无关（三条独立证据）

| # | 证据 | 来源 |
|---|---|---|
| 1 | 2026-08-16 在**无关分支** `chore/attest-toolchain-merge` 上，CI 里同一项失败，同为 `13 passed, 1 failed` | `gh run view 31957080150 --log-failed` |
| 2 | 在**干净的 `origin/main`**（`1437529`）本地跑同一脚本 → 同样失败 | 一次性 worktree 实跑 |
| 3 | #179 改的是 workflow 触发条件与一条 `git fetch`，与文档断言脚本零接触面 | 读 #179 的 diff（2 删 9 加，全在 `on:` 块与 `Detect relevant changes` 步骤内） |

---

## 2. 根因

### 2.1 直接病灶：失败细节被重定向吞掉，从不打印

`scripts/acceptance/hardening_6_framework.sh` 第 98–99 行：

```bash
run "regression: Plan 1f schema versioning" \
  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1 && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"
```

`/tmp/p1f.log` 在整个仓库里**没有任何一处被 `cat` 或以其它方式输出**（F17）。
而 `plan_1f` 自己有 **31 条**断言，其末尾还提示「失败日志位置（regression 段）：
`/tmp/p1.log`, `/tmp/p1b.log`, `/tmp/p1c.log`」—— 这三个文件同样从不被打印。

⇒ **闸门红了，CI 日志只告诉你「plan_1f 挂了」，不告诉你 31 条里的哪一条、也不告诉你嵌套三层里的哪一层。**
本次事故的排查成本几乎全部来自这一点：必须在本地从零复现，且要复现三次
（纯本地 → 装 Python 依赖 → 才发现还有 Linux 侧完全没覆盖）。

### 2.2 为什么它长期没被发现：闸门对绝大多数 PR 短路放行

实测 `hardening_6_gate.yml` 最近 25 次运行：

| 类别 | 次数 | 时长 | 结果 |
|---|---|---|---|
| **短路放行**（脚本零执行） | **23** | 16–30 秒 | 全部 success |
| **真跑满** | **2** | 1149 秒 / 104 秒 | **全部 failure** |

⇒ 该必需闸门显示「通过」的 23 次，**一次都没真正验证过任何东西**。

### 2.3 ⚠️ 但「从不运行」只是失效模式之一 —— 另一条是「看见了，主动豁免」

`docs/acceptance/2026-05-25-pr-e2-position-manager.md` 第 4 项验收动作原文（F20）：

> 注：该脚本整体会报 1 个**预存且无关**的失败 `regression: Plan 1b (M0.2 OpenAPI) acceptance`
> （plan_1b 硬编码期望 11 实际 19，与本 PR 零 backend 改动无关），**可忽略**

⇒ **`plan_1b` 的 11 vs 19 早在 2026-05-25 就被人跑到、看到、写进验收清单、并明示豁免。**
比本次最早的 CI 证据（2026-08-16）早三个月。

这条**推翻了初稿 §2.3 的「从未同步，原因是这个脚本从不运行」** ——
它运行过、被看见过、被口头放行了。这是与「从不运行」**完全不同**的失效模式，
对策也不同（前者要提高可观测性与执行频率，后者要禁止在验收清单里口头豁免闸门失败）。

---

## 3. 已核实事实台账

> ⚠️ **F7 / F9 / F16 是初稿写错、经对抗性评审证伪后订正的**，见 §11。

| # | 事实 | 证据来源 |
|---|---|---|
| F1 | #179 的 CI 失败项 = `regression: Plan 1f schema versioning`，`13 passed, 1 failed` | `gh run view 33315497789 --log-failed` |
| F2 | 2026-08-16 无关分支上同一项失败、同样数字 | `gh run view 31957080150 --log-failed` |
| F3 | 干净 `origin/main` 上本地复现同一失败 | 一次性 worktree `origin/main@1437529` 实跑 |
| F4 | 闸门最近 25 次运行：23 次短路（16–30s，全 success）、2 次跑满（**全 failure**） | `gh run list --workflow=hardening_6_gate.yml --limit 25` + 时长计算 |
| F5 | `plan_1f` 的 4 个版本号字面量已过期（`"1.5"`/`0003_v1.3`/`0003_v1.4_purge_leased`/`1.3` vs 文档 `"1.13"`/`0004_qmt_price_double_and_coverage`/`0010_v1.13_drawing_default_style`/`1.4`）；另 2 条（训练组 SQLite `1`、P2 journal `v2`）仍通过 | 读脚本 + `awk` 切文档矩阵 + 直跑 6 条断言（4 NG / 2 OK） |
| F6 | `plan_1b` 的 pytest 实际 `19 passed`，断言要求 `^11 passed` | CI 等价依赖环境实跑 `/tmp/p1b.log` |
| **F7（订正）** | **含「版本号写死值」的 acceptance 脚本共 2 个：`plan_1f` 与 `plan_e2_position_manager.sh`**。初稿写「只有 `plan_1f` 一个」，**错**。正确做法是**先撒宽网再逐个打开看**：`grep -lE '[0-9]+\.[0-9]+|000[0-9]_|v[0-9]+' scripts/acceptance/*.sh` **返回 12 个文件**（本人实跑），其中含 `plan_e2`；它是**候选筛**不是判据，必须逐个人工核。初稿用的窄模式只盯 `"1.x"` 与 `NNNN_vN` 两种书写形态，因而漏掉 `plan_e2` 里 `CONTRACT_VERSION = "1.5"` 这种写法（转义反斜杠形态） | 对抗性评审用一条正则翻出；我复跑确认 |
| F8 | 含「写死测试数量」断言的只有 `plan_1b` 一条 | `grep -nE "[0-9]+ passed" scripts/acceptance/*.sh`（`plan_0a`/`plan_1c` 里的 `passed` 只在注释中） |
| **F9（订正）** | **`plan_e2_position_manager.sh` 含 4 处版本字面量（L22 / L23 / L36 / L37）且当前就是红的**。实跑输出：`FAIL: §4.2.7 门: CONTRACT_VERSION 已 bump 为 1.5` + `FAIL: m01 矩阵 CONTRACT_VERSION = 1.5` + `=== E2 ACCEPTANCE FAILED ===`。初稿写「plan_e2 只做存在性检查」，**错** | 本人实跑 `bash scripts/acceptance/plan_e2_position_manager.sh` |
| F10 | `M01MatrixSyncGuardTests` **无 UIKit 门**，是 `Package.swift` 里正式 testTarget，由 `swift-contracts-smoke.yml`（`paths: ios/Contracts/**` → `swift test`）触发 | 读文件头 + 读 `Package.swift` + 读 workflow |
| F11 | 该 Swift 守卫**当前为绿**：本地 `swift test --filter M01MatrixSyncGuardTests` = **2 tests, 0 failures** | 本地实跑 |
| F12 | 该守卫断言的三个值（`"1.13"` / `0010_v1.13_drawing_default_style` / `1.4`）与 m01 文档当前值一致 | 读测试源码 L52/53/55 + 读文档矩阵 |
| F13 | 该守卫自带防空转（`XCTAssertGreaterThanOrEqual(r.count, 5)`）与解析器免疫测试 | 读源码 L51、L60–77 |
| F14 | **本机 macOS + CI 的 Python 依赖版本**下，`plan_1f` 失败面为 5 项（4 条矩阵 + `regression: Plan 1b`） | 一次性 venv 实跑 ⚠️ **该环境不等价于 CI**，见 F19 |
| F15 | CI 会安装 `backend/requirements-dev.txt`（pglast 7.13 / pyyaml 6.0.3 / openapi-spec-validator 0.7.2 / pytest 8.4.2 / httpx 0.28.1） | 读 `hardening_6_gate.yml` L31–41 |
| **F16（订正）** | 闸门相关文件名单展开后是 **9 条路径**（`.claude/hooks/` 2 条 + config + settings + workflow-rules + `tests/hooks/` 2 条 + `hardening_6_framework.sh` + `hardening_6_gate.yml`），初稿写 8，**错**。「不含 `plan_1f` / `plan_1b`」这半句**属实** | 展开 `hardening_6_gate.yml` L50 的正则逐条数 |
| **F17（措辞收窄）** | **这四个日志文件在 `scripts/` 下没有任何一处被 `cat` 或以其它方式输出** ⇒ CI 上失败细节完全不可见。⚠️ 初稿写「整个仓库」，与证据范围不符：全仓另有一处命中 `docs/superpowers/plans/2026-04-22-hardening-6-framework-plan.md`（逐字嵌旧命令，非 `cat`），实质结论不变 | `grep -rn 'p1f.log' scripts/` + 全仓扫描 |
| **F18（行号订正）** | **`plan_1c_m0_3_swift_contracts.sh` L41–42 执行 `cd ios/Contracts && swift test`**，而 `plan_1f` **L122–123**（初稿写 L120，**错**；L120–121 是 plan_1b 那条）内嵌调用它 | 读两个脚本 |
| **F19（❌ 该条的预测已被 PR #182 的 CI 实测证伪）** | 前半属实：闸门跑 `ubuntu-latest`，`hardening_6_gate.yml` 全文零处提到 `swift`。**但据此推出的「预期因缺工具链快速失败」是错的** —— `ubuntu-latest` 镜像**自带 Swift 工具链**，`swift test` 真的跑起来了（见 **F38–F40**）。<br>⚠️ **教训**：「配置里没装 X」推不出「运行环境没有 X」—— GitHub runner 镜像预装了大量工具，不在 workflow 里出现不等于不存在 | 前半：读两份 workflow；后半：**PR #182 run `33774540228` 的真实日志推翻** |
| **F20** | `plan_1b` 的 11 vs 19 早在 **2026-05-25** 就被记入 `docs/acceptance/2026-05-25-pr-e2-position-manager.md` 第 4 项并明示「可忽略」 | 读该文档 |
| **F21** | `kline_trainer_modules_v1.4.md` L144–145 的矩阵**停在 `"1.5"` / `0003_v1.3`**，而 m01 与代码都是 `"1.13"` / `0004_...`（`Models.swift:7 = "1.13"`）⇒ **两份治理矩阵分叉、modules 落后 8 版**；而 `plan_e2` L37 正断言 modules = `"1.5"` 并**通过**（绿灯锁死错值） | 逐格比对三处 + `plan_e2` 实跑输出中该项未出现在 FAIL 列表 |
| **F22（归因已软化）** | 用户本机 `grep` 是 **ugrep 7.8.4**（被 shell 函数替换）；`grep -c "'^11 passed'"` 返回 **0**，`grep -cF` 与 `/usr/bin/grep -c` 返回 **1**。⚠️ 三个数字属实。**归因已由 R5 补做区分实验证成**：同一条模式喂 ugrep 与 `/usr/bin/grep` 得不同结果 ⇒「引擎语义不同」成立。**结论（一律用 `-F`）不受影响** | 本人在 worktree 实跑三种写法 |
| **F23** | m01 文档 L125 有一条治理 backlog 明确描述「`plan_1f` 的 CONTRACT_VERSION 矩阵 6 行断言」 ⇒ 若删除那 6 条，该治理文本将指向不存在的对象 | 读 `docs/governance/m01-schema-versioning-contract.md:125` |
| **F24** | `hardening_6_framework.sh` **L83 / L85 已在用 `bash -o pipefail -c`**（两条 pytest 断言，形态为「重定向 → 存 `ec` → `tail -3` → `exit $ec`」）⇒ 本次的 `-o pipefail` 用法是同仓既有写法，非新引入 | 读该文件 L83、L85 |
| **F25** | `plan_1f` L118–123 **把三个嵌套脚本的输出各自重定向**到 `/tmp/p1.log` / `p1b.log` / `p1c.log` ⇒ 即使流式打印 `plan_1f` 自身输出，嵌套脚本的内部细节仍然看不到，故转储块必须保留这三个 | 读 `plan_1f` L118–123 |
| **F26** | 本机**既无 `timeout` 也无 `gtimeout`** ⇒ 在脚本里写 `timeout N ...` 会让本地执行直接 `command not found` | `command -v timeout` / `command -v gtimeout` 实跑，均无 |
| **F27（措辞订正）** | 解析为 `A && (B \| C)`：X 不存在时**退出非 0、零输出、日志文件不创建**；X 存在且失败时**输出实时可见**，退出码为**被测脚本自身的码**（初稿写「退出 1」不准；`run()` 只看非 0，结论不受影响） | scratchpad 多档实跑 |
| **F28** | **改动前** `hardening_6_framework.sh` 的输出中 `matrix row:` 与 `PLAN 1f` 各出现 **0 次**（`plan_1f` 的 31 条断言明细一行都上浮不到）；顶层标签 `regression: Plan 1f` 出现 3 次（framework 自己打的） | 本 worktree 实跑并 `grep -c` |
| **F29** | 顶层汇总数字**随环境变化**：本机无 venv 时 `11 passed, 3 failed`，CI 上 `13 passed, 1 failed` ⇒ 该数字**不可写死为判据**，只能做同环境前后对比 | 本机实跑 vs CI 日志比对 |
| **F30** | **`tee` 只能转发已经离开生产者 stdio 缓冲区的字节。** 实测两档：无缓冲生产者（`echo` 后 `sleep 20`）3 秒后下游**已有内容**；块缓冲生产者（`python3 print` 未 flush 后 `sleep 20`）3 秒后下游**为空**，被 `kill -9` 后内容永久丢失 ⇒ **「流式 ⇒ 挂住时证据一定还在」是假的** | scratchpad 两档实跑 |
| **F31** | **「只改 framework 一处」的半吊子实现能通过旧 §5 的全部判据**：实跑得 `matrix row:` = **16**、`PLAN 1f` = **1**（两条都「通过」），而嵌套层标记 `PLAN 1c` / `PLAN 1b` **全为 0** | 本 worktree 直接以半吊子形态实跑 |
| **F32** | 结构判据的当前值：framework 的 `bash -o pipefail -c` = **2**、plan_1f = **0**；framework 的 `> /tmp/p1f.log` = **1**、plan_1f 的 `> /tmp/p1` = **3** | 本 worktree `grep -cF` 实跑 |
| **F33** | `hardening_6_framework.sh` **L96–97** 还有**第 5 处**完全同型的重定向吞日志（`regression: Plan 1 DDL` → `> /tmp/p1.log`），本次**不改** | 读该文件 L96–97 |
| **F34** | `plan_1b_m0_2_rest_api.sh` L35 有一处 **`\| tee` 但无 `-o pipefail`**；当前靠哨兵 `grep -q '^11 passed'` 兜住，不是活的假绿 | 读该文件 L35 |
| **F35** | **5 处全改后的实测值**：numstat = `2　2　framework` + `3　3　plan_1f`；精确 diff = **5 删 5 加**；S1–S8 = `4/3/0/0/2/3/1/1`；两个哨兵完整保留 | 在 scratchpad 完整实现副本上逐条实跑 |
| **F36** | **越界形态的 numstat 实测**：改一条断言期望值 → plan_1f 变 `4　4`；删掉 4 条矩阵断言 → 变 `3　21`；**删哨兵（同一行内）→ 仍是 `2　2`**（故必须另有 S7/S8 与主判据兜住） | 在副本上分别构造后实跑 |
| **F38** | **PR #182 的 CI 实测：`plan_1f` 在 ubuntu 上的完整失败清单 = `25 passed, 6 failed`**：4 条矩阵行（`"1.5"` / `0003_v1.3` / `0003_v1.4_purge_leased` / `1.3`）+ `regression: Plan 1b (M0.2 OpenAPI)` + `regression: Plan 1c (M0.3 Swift Models)` | `gh run view 33774540228 --log-failed` |
| **F39** | **`ubuntu-latest` 自带 Swift 工具链，`swift test` 真的跑起来了**：日志含 `Fetched https://github.com/groue/GRDB.swift.git from cache (9.65s)`、`Working copy of GRDB.swift resolved at 6.29.3`、`Building for debugging...`、**115 行 `Compiling GRDB …`** | 同上日志 |
| **F40** | **`swift test` 在 Linux 上的真实失败是 `error: no such module 'CoreGraphics'`**（`DecelerationAnimator.swift:6:8`），随后 `error: emit-module command failed with exit code 1`。根因是**代码依赖 Apple 平台专有框架**，非工具链缺失 | 同上日志 |
| **F41** | `ios/Contracts/Sources` 下 **38 个文件 `import CoreGraphics`，38 个全部未被 `#if` 包住**；另有 21 个 `import SwiftUI`、17 个 `import UIKit`、1 个 `import QuartzCore`。仓内**确实使用** `canImport`（36 个文件含该词），但用途是 **iOS 与 Mac Catalyst 之间**的差异（`DecelerationAnimator.swift` 注释原文：`CACurrentMediaTime（两平台）`），**从不包括 Linux** ⇒ 让该 package 在 Linux 上编译通过**从来不是设计意图** | `grep -rl` 逐类计数 + 读 `DecelerationAnimator.swift` L1–20 |
| **F42** | **`swift test on macos-15` 不在必需检查名单里**。当前 ruleset 的 6 项必需检查为 `branch-protection-config-self-check` / `codeowners-config-check` / `check-bootstrap-used-once` / `Mac Catalyst build-for-testing on macos-15` / `acceptance` / `collect`。⚠️ R5 评审员曾引 `docs/governance/2026-05-21-pr1c-required-checks-evidence.md:53` 称它属于「11 条 required check」之一 —— **该文档已过期，不可作为依据** | `gh api .../rulesets/15660830` 实查 |
| **F37（实施时订正）** | 改动后日志量实测由 **56 行增至 5317 行（约 95×）**。⚠️ R5 报的「366 行 / 6.5×」是**低估** —— 那次副本的 swift 构建目录是坏的，`swift test` 只吐了十几行。真跑通时输出由 swift 逐条测试主导（604 行 `Test Case`、2443 行含 `passed`、27 处 `Executed N tests` 汇总） | 实施时在真 worktree 实跑对比 |

---

## 4. 决策

### D1　让 acceptance 的日志在**每一层**都流式输出

**两个文件、共 5 处，全部是同一种机械变换**：
`bash -c` → `bash -o pipefail -c`，且 `> FILE 2>&1` → `2>&1 | tee FILE`。
**其余一字不动**（哨兵 `&& grep -Fxq '…'` 原样保留）。

**这就是全部改动的逐字 diff（5 删 5 加，已实测）：**

```diff
-  bash -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1 && grep -Fxq 'PLAN 1 PASS' /tmp/p1.log"
+  bash -o pipefail -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh 2>&1 | tee /tmp/p1.log && grep -Fxq 'PLAN 1 PASS' /tmp/p1.log"
-  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1 && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"
+  bash -o pipefail -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh 2>&1 | tee /tmp/p1f.log && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"
-    bash -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1"
+    bash -o pipefail -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh 2>&1 | tee /tmp/p1.log"
-    bash -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh > /tmp/p1b.log 2>&1"
+    bash -o pipefail -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh 2>&1 | tee /tmp/p1b.log"
-    bash -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh > /tmp/p1c.log 2>&1"
+    bash -o pipefail -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh 2>&1 | tee /tmp/p1c.log"
```

前 2 处在 `hardening_6_framework.sh`（L96–99），后 3 处在 `plan_1f_m0_1_schema_versioning.sh`（L118–123）。

> ⚠️ **本节已第三次改写，且第 5 处是按 R5 新增的。** 演化本身是判据的一部分：
> - **初稿**：`> log` + 失败后 `cat` ⇒ **挂住时零证据**（R2 high）。
> - **R2 版**：只改最外层 + 事后转储 ⇒ **挂住时仍丢最关键那份**（R3 high）。
> - **R3 版**：4 处流式、删掉转储机制 ⇒ 仍漏 `framework` L96–97 的 `regression: Plan 1 DDL`。
> - **本版（R5）**：**5 处全改**。理由见下方「为什么必须含第 5 处」。

**为什么必须含第 5 处（R5 的 [medium] 7，成立）：**

`regression: Plan 1 DDL`（L96–97）在脚本里**排在 `plan_1f`（L98–99）之前**。
上一版把它排除在外，理由是「`plan_1f` 稍后会流式重跑同一个 `plan_1`，细节已覆盖」——
**该理由只在「正常失败」下成立**。若 `plan_1` 本身**挂住**，framework 会先卡在 L96–97，
那一处仍是 `> /tmp/p1.log`（零输出），而 `plan_1f` **永远轮不到运行**，
所谓「稍后重跑覆盖」永远不会发生 —— 这正是 R2 / R3 两轮判 [high] 的同一失效模式换了个位置。
⇒ 一并改，`R9`（原「有意不改」条）随之**删除**，§0 的「每一层」也因此**字面成立**，
不再需要事后收窄定义。

**为什么这样写：**

1. **`-o pipefail` 不可省** —— 没有它，管道退出码取自 `tee`（恒 0），被测脚本的失败会被吞掉，
   **直接制造假绿**。实测：漏写该选项时同一形态由 exit 1 变 exit 0。
   **同仓已有此写法先例**：`hardening_6_framework.sh` L83 / L85（F24）。
2. **`2>&1` 必须在 `| tee` 之前** —— 否则 stderr 绕过 `tee`，既不进日志文件也可能不进 CI 输出。
3. **保留 `tee` 写文件而非纯流式** —— `plan_1f` L142 会提示「失败日志位置：`/tmp/p1.log` …」，
   且 framework 两处的哨兵 `grep -Fxq '…' /tmp/pX.log` **依赖该文件存在**。
4. **哨兵一字不动** —— 它是 v46 R46 F2 专门加的防护（脚本吞掉失败却返回 0 时仍能拦住）。
   加了 `-o pipefail` 后**看起来**冗余，但两者防的不是同一件事：
   `pipefail` 防「管道吞码」，哨兵防「脚本自己 return 0」。**删任何一个都会开一个洞。**
5. **不碰任何 `run()` 函数** —— 两个文件的 `run()` 被各自全部断言共用。
6. **`test -x X && X | tee` 的优先级已实测**（F27）：解析为 `A && (B | C)`，
   X 不存在时 exit 非 0 且**零输出、日志文件不创建**；X 存在且失败时输出实时可见、退出码为被测脚本自身的码。

### D2　本次**不做**任何断言修复

**不**删 `plan_1f` 的 6 条矩阵断言、**不**改 `plan_1b` 的 `11 passed`、**不**碰 `plan_e2`、**不**同步 modules 矩阵。

**理由**：初稿主张「删 6 条 + 改 1 条 ⇒ 闸门变绿」，但该结论**无法从现有证据推出** ——
`plan_1f` 内嵌的 `swift test`（F18）在 `ubuntu-latest`（F19）上的行为**零证据**。
在没看到 CI 完整失败面之前设计修复，是在猜。**先让失败可见，再按证据设计修复**（D5）。

### D3　⚠️ 本 PR **不会**让 `acceptance` 变绿，这是有意的

`plan_1f` 仍会失败 ⇒ `acceptance` 仍为红 ⇒ **本 PR 在修复落地前不可合并**。

**这不是缺陷，是本次交付的形态**：本 PR 的产物是**那一次 CI 失败运行里打印出来的完整失败面**。
拿到它之后，修复提交会**追加到同一个 PR**，直至 `acceptance` 转绿方可合并。

⛔ **不得**为了让 PR 变绿而在没有证据的情况下顺手改断言 —— 那正是 D2 否决的做法。

### D4　自证机制：本 PR 触碰名单内文件，因而必然真跑

`scripts/acceptance/hardening_6_framework.sh` **在闸门的相关文件名单内**（F16）
⇒ 本 PR 上 `relevant=true` ⇒ acceptance 脚本**必然真执行** ⇒ 流式输出**必然出现**（流式与失败与否无关，不像已废弃的事后转储那样依赖 plan_1f 失败）。

**本 PR 因此不需要依赖 PR #179 的重跑来取证** —— 初稿把确认点挂在 #179 上，
而 #179 的实施计划明令「⛔ 不得 rebase 本分支」，两条纪律互相冲突（§11 Finding 4）。本决策消除该耦合。

### D5　修复方案待证据到位后另行设计

拿到 CI 完整失败面后，**另开一份 spec** 设计修复。届时至少已知的候选范围：
`plan_1f` 6 条矩阵断言、`plan_1b` 的 `11 passed`、`plan_e2` 的 4 处字面量（F9）、
modules 矩阵落后 8 版（F21）、m01 L125 的悬空 backlog（F23）、
以及 CI 才会暴露的 Linux 侧问题。**本 spec 不预判其结论。**

---

## 5. 验证方案

> ⚠️ **本节已第四次改写（R5）。** 上一版是「4 条结构 + 6 条行为」共 10 条 grep，
> R5 造了 **17 种错误实现逐个实跑**，实测**其中 7 种能 10 条全绿通过** ——
> 包括 **V6（改断言期望值）** 与 **V7（删掉 4 条过期断言）**，
> 而这两个正是 D2 / D3 / §7 三处明令禁止的越界动作。
> ⇒ 本版**换主判据**：不再靠堆 grep，改用**精确 diff 比对**为主 ——
> 任何变体都会让 diff 不同，一条顶十条，且执行者更省事。

### 5.1 主判据：精确 diff 比对（一条顶十条）

```bash
git diff origin/main -- scripts/acceptance/
```

**输出必须与 D1 里印的那份 diff 逐字符相同：恰好 5 行减号、5 行加号，且仅涉及那两个文件。**

**为什么它是主判据**：R5 构造的 17 种错误形态 —— 少改一处、漏 `-o pipefail`、
丢 `2>&1`、用 `tee -a`、改 tee 目标名、完全不写 `tee`、删哨兵、改断言期望值、
删断言、越界改别的行 —— **每一种都会让这份 diff 与基准不同**。
上一版那 10 条 grep 有 7 种抓不住，本条一条全覆盖。

### 5.2 机械辅助判据（给脚本 / 不想读 diff 的人）

一行一条单独敲（`grep -c` 计数为 0 时退出码是 1，**别串进带 `set -e` 的脚本**）：

| # | 命令 | 改动前 | 改动后 |
|---|---|---|---|
| S0 | `git diff --numstat origin/main -- scripts/acceptance/` | 无输出 | 恰好两行：`2　2　…hardening_6_framework.sh` 与 `3　3　…plan_1f_m0_1_schema_versioning.sh` |
| S1 | `grep -cF 'bash -o pipefail -c' scripts/acceptance/hardening_6_framework.sh` | **2** | **4** |
| S2 | `grep -cF 'bash -o pipefail -c' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | **0** | **3** |
| S3 | `grep -cF '> /tmp/p1' scripts/acceptance/hardening_6_framework.sh` | **2** | **0** |
| S4 | `grep -cF '> /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | **3** | **0** |
| S5 | `grep -cF '2>&1 \| tee /tmp/p1' scripts/acceptance/hardening_6_framework.sh` | **0** | **2** |
| S6 | `grep -cF '2>&1 \| tee /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | **0** | **3** |
| S7 | `grep -cF "PLAN 1f PASS' /tmp/p1f.log" scripts/acceptance/hardening_6_framework.sh` | **1** | **1**（哨兵不得被删） |
| S8 | `grep -cF "PLAN 1 PASS' /tmp/p1.log" scripts/acceptance/hardening_6_framework.sh` | **1** | **1**（哨兵不得被删） |

**「改动后」列的全部数值已在 scratchpad 的完整实现副本上实跑确认**（F35）。
`> /tmp/p1` 与 `2>&1 | tee /tmp/p1` 都是**前缀式定长串**，同时覆盖 `p1.log` / `p1b.log` / `p1c.log` / `p1f.log`。

> ⚠️ 必须用 `grep -cF`（定长串）—— 本机 `grep` 是 ugrep（F22）。

### 5.3 负向对照（改动前必须全红）

```bash
bash scripts/acceptance/hardening_6_framework.sh > /tmp/h6-before.log 2>&1
cp /tmp/h6-before.log /tmp/h6-before-keep.log
cp /tmp/p1f.log /tmp/p1f-before-keep.log
grep -c 'matrix row:' /tmp/h6-before.log
grep -c 'PLAN 1c' /tmp/h6-before.log
grep -c 'PLAN 1b' /tmp/h6-before.log
grep -cE '^PLAN 1 (PASS|FAIL)$' /tmp/h6-before.log
```

**四条计数期望值全为 `0`** —— `plan_1f` 与三个嵌套层的输出一行都上浮不到。
**前两条已在本 worktree 实跑确认为 0**（F28）。

> ⛔ **这一步必须在改代码之前做**，且两个 `-keep` 副本要活到 §5.4 比对完
> —— 否则重跑会就地覆盖 before 日志（R5 的 [low] 8）。

### 5.4 行为判据（改动后）

```bash
bash scripts/acceptance/hardening_6_framework.sh > /tmp/h6-after.log 2>&1
grep -c 'matrix row:' /tmp/h6-after.log
grep -c 'PLAN 1c' /tmp/h6-after.log
grep -c 'PLAN 1b' /tmp/h6-after.log
grep -cE '^PLAN 1 (PASS|FAIL)$' /tmp/h6-after.log
grep -cE '^Hardening-6 framework acceptance: ' /tmp/h6-after.log
grep -E '^Hardening-6 framework acceptance: ' /tmp/h6-before-keep.log
grep -E '^Hardening-6 framework acceptance: ' /tmp/h6-after.log
grep -F 'Plan 1f (M0.1 schema versioning) acceptance:' /tmp/p1f-before-keep.log
grep -F 'Plan 1f (M0.1 schema versioning) acceptance:' /tmp/p1f.log
```

| # | 判据 | 期望 | 它锁住什么 |
|---|---|---|---|
| B1 | `matrix row:` | > 0 | framework→plan_1f 那处生效 |
| B2 | `PLAN 1c` | > 0 | plan_1f→plan_1c 那处生效 |
| B3 | `PLAN 1b` | > 0 | plan_1f→plan_1b 那处生效 |
| B4 | `^PLAN 1 (PASS\|FAIL)$` | > 0 | plan_1f→plan_1 那处生效 |
| B5 | 顶层汇总**行数** | **1** | 汇总行没被嵌套层同格式汇总污染 |
| B6 | 顶层汇总**内容**（最后两条命令的输出） | **两行一字不差** | framework 层**没有任何断言由红变绿** |
| B7 | `plan_1f` 自身汇总**内容**（最后两条命令的输出） | **两行一字不差** | **plan_1f 内部 31 条断言的结果零改变** —— 这是唯一能看见越界改/删断言的行为判据 |

> ⚠️ **B6 / B7 必须用「打印内容」的命令，不能用 `-c`。**
> 上一版 B6 写的判据是「两个汇总行内容逐字相同」，给出的命令却是 `grep -cE …`
> —— `-c` 只输出行数，**永远打印不出要比对的内容**。R5 实测：在一个真有断言由
> `NG:` 翻成 `OK:` 的形态上，两条 `-c` 命令都输出 `1`，执行者比对「1 == 1」判通过。
> **判据文字与命令必须能对上，这是本 spec 第三次栽在这一点上。**
>
> ⚠️ **B6 / B7 不得写死具体数字**：本机无 venv 时 framework 汇总是 `11 passed, 3 failed`，
> CI 上是 `13 passed, 1 failed`（F29）；`plan_1f` 自身汇总本机 venv 下是 `24 passed, 7 failed`。
> 判据是**同环境前后逐字相同**，不是某个具体值。

### 5.5 判别力矩阵（本节判据自己的变异验证）

R5 构造 17 种错误实现逐个实跑。**本版判据对每一种的抓捕情况**：

| 错误形态 | 被哪条抓住 |
|---|---|
| 只改 framework 一处 / 只改 3 中的 1 或 2 处 | 主判据 + S0 + S2 + S6 + B2/B3/B4 |
| 某一处漏 `-o pipefail` | 主判据 + S1 或 S2 |
| 加了 pipefail 但仍写 `> file` | 主判据 + S3/S4/S5/S6 + B1–B4 |
| 丢 `2>&1` / 用 `tee -a` / 改 tee 目标名 / 完全不写 tee | 主判据 + S5/S6 |
| **删掉哨兵** | 主判据 + S7/S8 |
| **改断言期望值**（V6，D2 禁止） | 主判据 + S0（`3 3`→`4 4`）+ **B7** |
| **删掉 4 条过期断言**（V7，§7 禁止） | 主判据 + S0（`3 3`→`3 21`）+ **B7** |
| 越界改其它行 / 其它文件 | 主判据 + S0 |

> 上述 S0 的两个数值（`4　4` 与 `3　21`）是我在完整实现副本上**实跑测得**，非推演。

### 5.6 CI 级（本 PR 自证，见 D4）

PR 开出后 `acceptance` **预期为红**（D3）。在其日志中确认：
① `plan_1f` 的逐条断言明细（`OK:` / `NG:`）出现；
② 三个嵌套脚本各自的结论行出现；
③ 记录 `plan_1f` 在 **ubuntu-latest** 上的**完整失败项清单** —— 这是本 PR 的交付物。

> ⚠️ **判绿纪律不适用于本 PR**：成功判据不是「检查变绿」，而是**「失败面变得可读」**。

### 5.7 明确不做的验证

- 不预测 `plan_1f` 在 Linux 上具体失败在哪几项（F19 已给出有依据的**预期**，但不写成结论）。
- 不构造人工挂起测试 —— 但注意否决理由已收窄：「生产者缓冲」这一层本机**能验且已验**（F30），
  只有「Linux 上真实的 Swift 挂起」本机不可复现。

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R1** | `plan_1f` 的 4 条矩阵断言 + `plan_1b` 的 `11 passed` **仍然是红的** | 本次有意不修（D2） | 待 D5 的修复 spec |
| **R2** | `plan_e2_position_manager.sh` 带着 2 条红断言留在仓里（F9），且其 L37 用绿灯锁死了 modules 矩阵的错值（F21） | 既有故障，非本次引入；初稿曾错误声称其无问题 | 待 D5；**已在台账中订正，不再有「其余脚本干净」的错误陈述** |
| **R3** | `kline_trainer_modules_v1.4.md` 矩阵落后 8 版（F21），与 m01 分叉 | 治理文档不一致，影响任何按它核对版本的人 | 待 D5；需先厘清两份矩阵谁是权威 |
| **R4（✅ 已由 PR #182 的 CI 实测关闭）** | `plan_1f` 在 `ubuntu-latest` 上跑 `swift test`（F18） | **实测结果与两次预测都不同**：不是「缺工具链」（F39：Swift 装了且真跑了），也不是「挂住」（R8 设想）；而是 **`no such module 'CoreGraphics'` 编译失败**（F40）—— iOS 专有框架在 Linux 上不存在，且 38 个 `import CoreGraphics` 全部未加条件编译（F41） | **本残留已关闭**。它揭示的新问题（ubuntu 闸门内嵌 `swift test` 结构性不可能通过）转为 **R12**，由 D5 的修复 spec 处理 |
| **R5** | 闸门仍对绝大多数 PR 短路放行（F4）⇒ 剩余断言仍是低频执行、仍可能腐烂 | 短路机制本身是正确的（防另一种死锁）；本次不改变执行频率 | 超出范围 |
| **R6** | 「验收清单里口头豁免闸门失败」这一失效模式（F20）无任何机制约束 | 真实且已发生过一次 | 超出范围，记入独立 backlog |
| ~~R9~~ | ~~framework L96–97 有意不改~~ | **已作废（R5）**：其理由「plan_1f 稍后会重跑覆盖」只在**正常失败**下成立；`plan_1 DDL` 排在 `plan_1f` **之前**，若它自己挂住则 `plan_1f` 永不运行 ⇒ **第 5 处已纳入 D1** | — |
| **R11** | `docs/superpowers/plans/2026-04-22-hardening-6-framework-plan.md` L2919–2922 逐字嵌了 framework 的**旧写法**，改完后变陈旧 | 纯文档腐烂，无守卫会红，不影响执行 | 接受，记录在案 |
| **R12（新，由 CI 实测揭示）** | **`ubuntu-latest` 的 acceptance 闸门内嵌 `swift test`，而被测 package 是 iOS 专有的 ⇒ 该断言在结构上永远不可能通过** | 这**不是**「字面量过期」那一类问题，性质完全不同：不是断言写错了，是**断言被放在了错误的平台上**。且仓内已有 `swift test on macos-15`（`swift-contracts-smoke.yml`）在正确平台上做同一件事 —— 只是它**不是必需检查**（F42） | **超出本 PR 范围**，转 D5 的修复 spec；该 spec 必须回答「ubuntu 闸门该不该跑 `swift test`」这个设计问题 |
| **R10** | `plan_1b_m0_2_rest_api.sh` L35 有一处 `\| tee` **无 `-o pipefail`**（F34） | 当前靠哨兵 `grep -q '^11 passed'` 兜住（pytest 失败时摘要行形如 `2 failed, 11 passed`，匹配不到 `^11 passed`）⇒ **不是活的假绿**；但属同族隐患 | 接受，**转入 D5 的修复 spec 一并处理** |
| **R7（量级已按实施实测订正）** | 流式输出会让 CI 日志显著变长（**成功时也会**） | **实测由 56 行增至 5317 行（约 95×，F37）** —— 主要来自 `swift test` 的逐条输出。⚠️ R5 阶段记的「6.5×」是低估（那次 swift 构建目录是坏的）。<br>**为什么仍可接受**：① 该闸门 25 次运行里只有 2 次真跑满（F4）⇒ 绝对频次低；② GitHub Actions 单 job 日志上限为 64MB，5317 行约数百 KB，远未触顶；③ **这正是本次要买的东西** —— 在此之前那 5317 行信息量为 0 | 接受 |
| **R8（按 R4 降级）** | 若 `plan_1c` 的 `swift test` 在 Linux 上**挂住**，job 会跑到 GitHub 默认的 **360 分钟**才被杀 | ⚠️ **初稿写「证据不会丢失」，该论断已被实测证伪（F30）**：`tee` 只转发已离开生产者 stdio 缓冲区的字节，而 Swift 的 `print` 走 C stdio、stdout 非终端时为**块缓冲** ⇒ 挂住时**能看出卡在哪一层**（`plan_1f` 自己 `echo` 的层级标题已 flush），但 **Swift 自身缓冲区里未 flush 的内容仍会丢**。<br>量级已按 **F19 订正**下调：gate 上无 Swift 工具链，预期是**快速失败**而非挂住，故本风险实际概率低 | 接受。**未采纳**「脚本内加 `timeout`」（本机无 `timeout`/`gtimeout`，F26）；若将来要限时，正确位置是 workflow 的 job 级 `timeout-minutes`，属独立改动 |

---

## 7. 本 spec 明确不做

- 不修改任何 acceptance 断言（D2）；
- 不修改 `plan_1b` / `plan_e2` / `plan_1c` / `plan_1`；
- `plan_1f` **仅允许**把 L118–123 三处的重定向改成流式 `tee`（D1-B），
  **不得**触碰它的任何一条断言、任何期望值、任何其它行
  —— 这是 codex R3 后从「完全不改」放宽的唯一一点，理由见 D1 的演化说明；
- 不修改 `M01MatrixSyncGuardTests.swift`（当前为绿且维护良好，F11/F12）；
- 不修改 `m01-schema-versioning-contract.md` 与 `kline_trainer_modules_v1.4.md`；
- 不修改 `hardening_6_gate.yml`（含其相关文件名单）；
- 不修改共享的 `run()` 函数；
- 不触碰 PR #179 的分支或其任何文件。

---

## 8. 考虑过并否决的替代方案

| 方案 | 内容 | 否决理由 |
|---|---|---|
| **A** | 照初稿执行：删 `plan_1f` 6 条 + 改 `plan_1b` 的 11 | 其「闸门会变绿」的结论**无证据支撑**（F18/F19）。若 Linux 侧 `swift test` 本就跑不通，改完仍红，而**此时对照组（那 6 条断言）已被删除、不可复现** |
| **B** | 修改 `run()` 函数，让所有断言失败时都转储对应日志 | 风险面从 1 条扩到 14 条；且多数断言根本没有对应日志文件。YAGNI |
| **C** | 只转储 `/tmp/p1f.log`，不转储三个嵌套日志 | 只能知道**哪一层**挂了，知道不了**为什么** —— 还要再跑一轮 CI 才能定位，与本次「一次拿到完整失败面」的目的相悖 |
| **D** | 把 `plan_1f` / `plan_1b` 加进闸门相关文件名单，让修复 PR 自证 | 改变「哪些 PR 付出完整 acceptance 成本」，是行为面改动需独立论证；且本 PR 触碰 `hardening_6_framework.sh` 已天然自证（D4），无需此改动 |
| **E** | 只改 `framework`、完全不碰 `plan_1f`（初稿与 R2 版的立场） | **已否决（codex R3）**：`plan_1f` 把三个嵌套脚本的输出各自重定向（F25），只改外层则 `swift test` 的输出仍在临时文件里；而事后转储块在 `run` 返回后才执行 —— **挂住时永远到不了**。「诊断设施放在不打算改的那一侧」这条美学考虑，敌不过「诊断在最该用的场景下失效」这个硬缺陷。故 §7 已放宽为「`plan_1f` 仅允许改这 3 处重定向」 |
| **F** | 加一个人工构造的「挂起测试」验证输出能在被终止前到达 CI（codex R3 建议） | **否决**：真实复现需要 Linux runner + 会挂的 Swift 工具链，本机无法构造等价环境；用 `sleep` 伪造只能证明 `tee` 会流式（已由 D1 实测档 A 证明），证明不了真实场景。流式与非流式的差别是**结构性的**（输出在运行时进 stdout vs 运行后才写出），不依赖挂起测试来确立 |

---

## 9. 回滚方案

> ⚠️ **本节初稿与 D3 自相矛盾，已按 codex R2 重写**（见 §11）。
> 初稿写「本次实施只产生**一个**提交」并让操作者「revert squash 提交」——
> 但 D3 明确要求**修复提交会追加到同一个 PR**。合并后 revert 那个 squash 会把
> **诊断与修复一起撤销**，等于把坏掉的闸门原样放回去，而不是「只回滚日志输出」。

**本 spec 覆盖的实施只产生一个提交**（诊断），但**本 PR 最终会包含更多提交**（D5 的修复）。
因此回滚要分清撤的是哪一层：

### 9.1 只想撤掉「诊断输出」这一层（PR 尚未合并时）

```bash
git revert --no-edit <诊断那一个提交的 sha>
```

撤完后 `acceptance` 会回到「红且看不见原因」的状态 —— 这通常**不是**你想要的，除非诊断本身出了问题。

### 9.2 想撤掉整个 PR（已合并进 `main` 之后）

本仓近期 PR 多为 squash 合并（单提交、标题带 `(#NNN)`）：

```bash
git revert --no-edit <squash 提交 sha>
```

若为 merge commit 则 `git revert --no-edit -m 1 <sha>`。

⚠️ **这会同时撤销诊断与修复** ⇒ `acceptance` 会退回本次事故前的状态（红、且失败原因不可见）。
**撤销后必须立刻重跑一次闸门确认其实际状态**，不得假设「回滚 = 回到好的状态」。

### 9.3 §9 需在 PR 最终范围确定后复核

D5 的修复提交落地后，本节的提交清单会变。**合并前必须回来把 9.1 的 sha 清单补全**。

⛔ `git revert` **没有 `-q` 选项**，误写会只打印 usage 而**什么都不做**（已实测 `git revert -h`）。

**回滚后核实**：

```bash
grep -cF 'tee /tmp/p1f.log' scripts/acceptance/hardening_6_framework.sh
grep -cF 'tee /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF '> /tmp/p1f.log' scripts/acceptance/hardening_6_framework.sh
grep -cF '> /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
```

**四条期望值依次为 `0` / `0` / `1` / `3`**（**已在本 worktree 实跑确认全部对上**，当前树尚未实施 = 等价于「回滚后」）。

> ⚠️ **前两条必须配后两条，缺一不可。** 只查前两条是**单向**判据 ——
> 「把那 4 行整段删掉」或「解冲突时取错边留下裸命令」同样返回 `0 / 0`，
> 于是「回滚成功」的结论是**假绿**，而实际上闸门少了几条断言（codex/Opus R4 的 [medium]）。
> 后两条锁的是「旧形态确实回来了」。
>
> ⚠️ 用 `grep -cF`（定长串）—— 本机 `grep` 是 ugrep（F22）。
> ⚠️ `grep -c` 计数为 0 时**退出码是 1**，**一行一条单独敲**，别串进带 `set -e` 的脚本。

> ⚠️ **必须用 `-F`**：用户本机 `grep` 是 **ugrep 7.8.4**（F22），对含正则元字符的模式与
> GNU/BSD grep 行为不同 —— 初稿的回滚核实命令正因此在用户机器上返回了错误的值（§11 Finding 5）。
> 本命令的期望值 **0 已在本 worktree 实跑确认**（当前树尚未实施，故应为 0）。

---

## 10. 交付与流程

1. 本 spec 提交；
2. 对抗性评审（当前 codex 配额耗尽 → 用户指定改用独立 Opus 子代理，见 §11）；
3. 收敛后 → `superpowers:writing-plans`；
4. 实施 → PR → **CI 跑出完整失败面**（本 PR 的交付物）；
5. 按该失败面另开 spec 设计修复（D5），修复提交追加到同一 PR，直至 `acceptance` 转绿方可合并。

**push 与开 PR 由用户在自己的终端执行**。

---

## 11. 评审轮次记录

### R1 · **Opus 子代理**对抗性评审 · 2026-09-02 · HEAD `5acd5f0` → **needs-attention**（3 high / 4 medium / 5 low）

> ⚠️ **评审通道说明（不得含糊）**：codex 配额于 2026-08-31 21:16 耗尽（恢复时间 09-01 00:31），
> 期间两次调用均产出**假 approve**（`Turn failed.` + 无 `[codex-attest] verdict=` 收口行；
> 账本已用 Read 核实**未被写入**）。用户明示改用独立 Opus 子代理执行本轮对抗性评审。
> **本轮不写 attest 账本**，故本线**至今没有任何 codex attest 条目**。

**我逐条复核后的结论**（凡「成立」者均为我自己在本 worktree 实跑/实读所得，非采信评审员转述）：

| # | 严重度 | Finding | 我的复核 | 处置 |
|---|---|---|---|---|
| 1 | high | F7/F9 错误：`plan_e2_position_manager.sh` 含 4 处同族版本字面量且**当前就是红的** | **成立** —— 实跑得 `FAIL: §4.2.7 门…` + `FAIL: m01 矩阵…` + `=== E2 ACCEPTANCE FAILED ===` | 台账 F7/F9 已订正；新增 R2 |
| 2 | high | 根因漏了「两份治理矩阵分叉」：modules 矩阵停在 `"1.5"`，落后 8 版，且被 `plan_e2` L37 绿灯锁死；初稿 §7「文档是对的」不成立 | **成立** —— 逐格比对 modules L144-145 / m01 / `Models.swift:7` | 新增 F21、R3；初稿那句已随范围重定删除 |
| 3 | high | 「D1+D2 能让闸门变绿」无 Linux 侧证据；`plan_1c` 跑 `swift test` 而闸门在 ubuntu 上；且失败细节被重定向吞掉、CI 完全看不见 | **成立，且是本次范围重定的直接原因** —— 读得 `plan_1c` L41-42、`hardening_6_gate.yml` `runs-on: ubuntu-latest`、`grep -rn p1f.log` 仅命中重定向本身 | 新增 F17/F18/F19；**整份 spec 重定为诊断先行** |
| 4 | medium | 确认点「#179 重跑」与 #179 自己「⛔不得 rebase」的硬约束冲突 | **耦合确实存在** —— #179 的实施计划 Global Constraints 第 2 条原文如此 | D4 改为本 PR 自证，消除该耦合 |
| 5 | medium | §9 回滚核实的第 2 条 grep 在用户本机返回 **0** 而非 spec 写的 1 | **成立** —— 本机 `grep` = ugrep 7.8.4；三种写法实测 0 / 1 / 1 | 新增 F22；§9 已改为 `grep -cF` 单条并注明已实跑 |
| 6 | medium | D2 只给语义未给判据形状（`bash -c` 不继承 pipefail / 全 skip / 失败时行首形状） | **技术上成立** | 因 D2 已取消（本次不修断言），该 finding **转入 D5 的修复 spec 必须回答的清单** |
| 7 | medium | D1 与 D2 用了互相矛盾的取舍标准；§8 未考虑「D2 也删掉」 | **成立** | 同上，转入 D5 |
| 8 | low | F16 数错（9 条路径写成 8）；D1 理由 1 的「永远不会」可证伪 | **成立** | F16 已订正为 9；范围重定后不再有该论证 |
| 9 | low | §8 方案 E 的「31 / 26 / 6」账算不平（26+6=32>31） | **成立** | 范围重定后该段已删除 |
| 10 | low | 删 6 条会让 m01 L125 的治理 backlog 指向不存在的对象 | **成立** —— 读得该行原文 | 新增 F23；本次不删断言故暂不触发，转入 D5 |
| 11 | low | 改完 `plan_1b` 会留下 L3 / L33 / L34 三处新的「11」文字 | **成立** | 转入 D5 |
| 12 | low | 「至少从 2026-08-16 起假绿」漏掉 2026-05-25 的书面豁免记录；§2.3「从未运行」的根因判断有误 | **成立，且改变了根因叙述** —— 读得该验收文档第 4 项原文 | 新增 F20；§2.3 已重写为「两条失效模式」并新增 R6 |

**未采信 / 已修正评审员的部分**：

- 评审员称 F1/F2/F4「未能复核」（其 `gh` 被本机权限守卫拒绝）。**这三条由我在本会话中实跑取得**，
  证据命令已列于台账，**不因评审员无法复核而降级**。
- 评审员建议「§9 的『逆序 revert』是多余的」—— **采纳**：本次只产生一个提交，§9 已不含逆序要求。

**本轮的方法论教训**：

1. **我自己踩了自己记过的守则**：F7 的扫描模式过窄，漏掉 `plan_e2` ——
   `feedback_fix_the_whole_predicate_family_not_the_reported_site` 说的正是
   「改判据要按**判据本身**穷尽全仓，不是按手头的文件块」。**订正后的 spec 必须写出实际用过的那条正则**，否则复核者无法证伪。
2. **§9 的期望值是推出来的、没在目标目录真跑过** —— `feedback_recipe_must_be_run_in_target_dir`。
   本次已改为实跑确认，且发现用户本机 `grep` 是 ugrep（F22），这本身是一条以后所有配方都要考虑的环境事实。
3. **⭐ 最重要的一条：在「无法观测失败」的前提下设计修复，等于猜。**
   初稿把「本地 macOS + Python 依赖」称作「CI 等价环境」，而 CI 是 Linux 且要跑 `swift test` ——
   一个从未被任何证据触及的路径。**先让失败可见，再谈修复**，是本次范围重定的全部理由。

---

### R2 · codex `adversarial-review` · 2026-09-02 · HEAD `e7be906` → **needs-attention**（1 high / 1 medium）

> ✅ **本轮是真 verdict**：收口行 `[codex-attest] verdict=needs-attention` 存在（判据 ④ = 1）。
> 与 2026-08-31 那两次配额期假 approve（④ = 0）性质完全不同。**账本未写入**（verdict ≠ approve）。

**两条我都复核成立，均已修。**

| # | 严重度 | Finding | 我的复核 | 处置 |
|---|---|---|---|---|
| 1 | **high** | 「先重定向、失败后再 `cat`」的诊断**对挂住 / 超时 / 取消无效** —— 日志只在 `run` 返回后才打印，若 `plan_1c` 的 `swift test` 在 Linux 上挂住或 job 被取消，控制流永远到不了转储块 ⇒ 闸门对**恰恰是本 PR 要调查的那种退化行为**完全沉默 | **成立，且直击本 PR 的唯一目的**（拿证据）。若它在最可能出问题的路径上产出零证据，这个 PR 就白做了 | D1 改为 `bash -o pipefail -c` + `\| tee` **流式**输出；转储块只保留三个嵌套日志。**已隔离实测三档**（失败/成功/静默返回 0 但哨兵缺失），其中档 C 证明**原有哨兵防护未被削弱** |
| 2 | medium | §9 回滚与 D3 自相矛盾：§9 说「只产生一个提交、revert squash」，而 D3 要求修复提交追加到同一 PR ⇒ revert squash 会把诊断与修复**一起**撤掉 | **成立** —— L266 与 L171/L293 直接打架 | §9 重写为 9.1（只撤诊断层）/ 9.2（撤整个 PR，并警告会同时撤掉修复、撤后必须重跑闸门确认）/ 9.3（最终范围确定后必须回来补 sha 清单） |

**未采纳的部分（附理由与证据）**：

- codex 建议「add an explicit bounded timeout」（在脚本里加超时）。**未采纳** ——
  本机 `command -v timeout` 与 `command -v gtimeout` **均无输出**（F26），
  把 `timeout` 写进 acceptance 脚本会让**本地执行直接 `command not found`**。
  这正是 `feedback_codex_review_killed_not_verdict` 记录过的坑：
  「给长命令加超时这种顺手的保护本身也是判据的一部分，它一失败，被保护的命令零执行」。
  若将来确需限时，正确位置是 workflow 的 job 级 `timeout-minutes`，属独立改动。
  **该风险已量化记为 R8**。
  ⚠️ **本轮当时给的另一半理由「流式输出已保证证据不丢失」已被 R4 的 F30 实测证伪**，
  不再作为拒绝超时建议的依据；**拒绝该建议现在只靠 F26（本机无 `timeout`/`gtimeout`）这一条**。
- codex 建议「`if: always()` artifact 上传」。**未采纳** —— 需要改
  `hardening_6_gate.yml`（§7 明确不改），而流式输出已经把证据直接放进 CI 日志，
  artifact 是同一目的的更重手段。

**本轮的方法论收获**：**诊断设施本身也要按「最坏路径」设计。**
我原来的写法在「正常失败」下工作良好，却在「挂住」下完全失效 ——
而挂住恰恰是这次最该担心的那种失败（Linux 上从未跑过的 `swift test`）。
⇒ **为「拿证据」而做的改动，要先问「它在最糟的那种失败下还产出证据吗」。**

---

### R3 · codex `adversarial-review` · 2026-09-02 · HEAD `03db644` → **needs-attention**（1 high / 1 medium）

> ✅ 真 verdict（收口行存在，判据 ④ = 1）。账本未写入（verdict ≠ approve）。

**两条我都复核成立，均已修。而且 [high] 那条说明 R2 的修法只修对了一半。**

| # | 严重度 | Finding | 我的复核 | 处置 |
|---|---|---|---|---|
| 1 | **high** | R2 版只把**最外层**改成流式，但 `plan_1f` 把三个嵌套脚本的输出**各自重定向**（F25）；转储块又在 `run` 返回后才执行 ⇒ **`swift test` 挂住时，CI 只看得到外层那行 `========== Plan 1c ==========`，Swift 自己的进度与报错仍在临时文件里、永远不会被打印** ⇒ 承诺的「一次拿到完整失败面」在最该用的场景下做不到 | **成立。R2 只修对了一半** —— 我在 F25 里其实写下了这个事实，却没意识到它意味着「关键那份仍然丢」 | D1 改为**每一层都流式**（framework 1 处 + `plan_1f` 3 处，同一种改写）。**事后转储块整个删除**，连带删掉 R2 引入的 `_h6_fail_before` 机制 —— 改动反而比 R2 版**更小更简单** |
| 2 | medium | §5 的验证判据要求出现 `---------- /tmp/p1f.log ----------`，但 D1 已把 `p1f.log` 移出转储列表、根本不产出该标记 ⇒ **正确实现必然通不过自己的验收标准** | **成立，且是我在 R2 修订时自己制造的** —— 改了 D1 却没同步 §5，三处（L220/227/236）全留着旧标记 | §5 整节重写：负向对照改为「`matrix row:` 与 `PLAN 1f` 计数为 0」（**已实跑确认均为 0**，F28），正向改为「两者 > 0 且顶层汇总前后一致」 |

**未采纳的部分（附理由）**：

- codex 建议「加一个有界的挂起测试，验证输出在被终止前到达 CI」。**未采纳**（§8 方案 F）——
  真实复现需要 Linux runner + 会挂的 Swift 工具链，本机无法构造等价环境；
  用 `sleep` 伪造只能证明 `tee` 会流式（已由 D1 实测档 A 证明），证明不了真实场景。
  **流式与非流式的差别是结构性的**（输出在运行时进 stdout vs 运行后才写出），不依赖挂起测试来确立。

**本轮的方法论教训（两条，都很硬）**：

1. **⭐ 我把关键事实写进了台账，却没读懂它的含义。** F25 是我自己写的：
   「`plan_1f` 把三个嵌套脚本的输出各自重定向 ⇒ 即使流式打印 `plan_1f` 自身输出，
   嵌套脚本的内部细节仍然看不到」。我把它当成「已知限制」记了一笔就过去了，
   **没有把它和「挂住时转储块到不了」这条连起来** —— 两条一连，结论就是「最关键的那份必丢」。
   ⇒ **台账不是记完就完事；每加一条事实，要回头问它是否推翻了现有决策。**
2. **改了 D，必须同步查 §5 的判据。** 这是同一类错误的第二次（R2 改 D1 没动 §5）。
   凡是改动「产出什么」的决策，都要立刻回到「怎么验」那一节逐条对齐 ——
   否则会产出「正确实现却通不过验收」的自相矛盾交付物。

---

### R4 · **Opus 子代理**对抗性评审 · 2026-09-02 · HEAD `2ec3733` → **needs-attention**（1 high / 3 medium / 4 low）

> ⚠️ **评审通道说明**：codex 配额于 2026-09-02 再次耗尽（恢复时间 **09-07 13:31**，约 5 天），
> 本次调用产出 `Codex did not return valid structured JSON` + `Parse error: You've hit your usage limit`，
> **无任何 Verdict 行、退出码 1、0 条命令**（判据 ④ = 0）⇒ 不算一轮，账本未写。
> 用户明示改用独立 Opus 子代理。**本轮同样不写 attest 账本**；本线**至今没有任何 codex attest 条目**。
> 该评审员复核了 **26 条**台账（要求 ≥10），其中 3 条因禁用 `gh` 未能复核。

**七条我都复核成立，均已修或已记录。**

| # | 严重度 | Finding | 我的复核 | 处置 |
|---|---|---|---|---|
| **H1** | **high** | **§5 的全部判据对 4 处改写中的 3 处零判别力** —— 「只改 framework 一处」的半吊子实现（R3 判为致命的那个形态）能 100% 通过；「某处漏写 `-o pipefail`」也一条抓不到 | **成立，且我自己复跑坐实**：半吊子形态下 `matrix row:` = **16**、`PLAN 1f` = **1**（两条都「通过」），嵌套层标记全为 **0**（F31） | §5 **第三次整节重写**：新增 **4 条结构判据**（S1–S4，双向：新形态到位 + 旧形态消失，且计数形式直接封掉漏 `-o pipefail`）+ **6 条行为判据**（B1–B6）。⚠️ **该版仍不足**：改动后的期望值当时为推导，且判据对越界动作零判别力 —— 已由 **R5** 再次重写，见下 |
| **M1** | medium | R8 的承重论断「挂住时证据不会丢失」**是假的** —— `tee` 只转发已离开生产者 stdio 缓冲区的字节，Swift `print` 走 C stdio、非终端时块缓冲 | **成立，我自跑两档证实**：无缓冲生产者 3 秒后下游有内容；块缓冲生产者下游**为空**，`kill -9` 后永久丢失（F30） | R8 降级：改为「能看出卡在哪一层，但 Swift 缓冲区里未 flush 的内容仍会丢」 |
| **M2** | medium | 「Linux 侧 `swift test` 零证据」**过强** —— `swift-contracts-smoke.yml` L20–24 特意用 `macos-15` 并注明依赖预装 Xcode 提供 Swift，而 gate 跑 ubuntu-latest 且**全文零处提到 swift** ⇒ 有指向性证据表明是**快速失败**而非未知 | **成立** —— 我实读两份 workflow + `grep -ci swift hardening_6_gate.yml` = **0**。⚠️ 而 F10 明确写着我读过 `swift-contracts-smoke.yml`，却没看到 3 行之外的 `runs-on` | 当时把 F19 订正为「预期因缺工具链快速失败」；R4 残留同步降级。<br>⚠️ **该「预期」本身已于 2026-09-04 被 PR #182 的 CI 实测证伪**（ubuntu-latest 自带 Swift，真实失败是 CoreGraphics 缺失）—— 见 F19 / F38–F42 与 R12 |
| **M3** | medium | §9 回滚核实是**单向**的 —— 「把那几行整段删掉」或「解冲突取错边」同样返回 0/0，判「回滚成功」是假绿 | **成立** | §9 改为**四条**（0/0/**1/3**），后两条锁「旧形态确实回来了」。四条已实跑对上 |
| **L1** | low | `framework` **L96–97** 还有**第 5 处**同型重定向（`regression: Plan 1 DDL`），既没改也没进残留台账 | **成立** | 新增 F33 + **R9**：有意不改（`plan_1f` 稍后会以流式重跑同一个 `plan_1`，细节已覆盖），并澄清 §0「每一层」指的是通往 `plan_1f` 的那条链 |
| **L2** | low | §5 的汇总对比用了宽松正则，改动后会从 1 行变 **5 行**（四个嵌套汇总同格式），非技术执行者会误判 | **成立** | B5 的锚改为 `^Hardening-6 framework acceptance: ` 并写明会多出哪四行 |
| **L3** | low | F22 的归因（ugrep 正则语义）**未证成** —— 那条模式带着多余单引号，「模式写错」是同样成立的解释 | **成立** | F22 加「归因未证成、结论不受影响」的限定 |
| **L4** | low | `plan_1b` L35 还有一处 `\| tee` **无 `-o pipefail`**，而 D1 的理由 1 正是拿这个当核心论据 | **成立**（当前靠哨兵兜住，非活的假绿） | 新增 F34 + **R10**，转入 D5 |

**评审员另外确认为「未发现问题」的方向**（我采信，因其给出了逐条证据）：
D1 四处改写与现状**逐字符比对一致**（label / 缩进 / 续行 / 引号 / 路径 / 行号）；
`A && B | C` 在每一处都解析为 `A && (B|C)`；四档实测全部复现，
另加两档 A′（漏 `-o pipefail` → exit **0**，证明该选项不可省）与 E（`tee` 目标不可写 → exit 1，非新增风险）；
`-Fx` 整行匹配不会被嵌套层的 `PLAN 1 PASS` / `PLAN 1b FAIL` 误伤；
`/tmp/p1.log` 被 framework L97 与 plan_1f L119 共用但**次序安全**；
**没有任何断言会从「会红」变成「会绿」**，唯一路径是漏写 `-o pipefail`（已由 S1/S2 封掉）。

**本轮的方法论教训（第三次同族，必须记死）**：

1. **⭐⭐ 「判据同步」有两层：标签同步 ≠ 判别力同步。**
   R3 我学到「改了 D 要同步查 §5」，R4 我**照做了** —— 判据里的字符串确实换成了新产出。
   但我**没问「这些判据能不能区分完整实现与半吊子实现」**。
   结果：一个被上一轮明确判死的形态，能满分通过我的验收。
   ⇒ **写完每条判据，必须构造「最像但错」的实现，实跑证明它会被判红。** 这就是变异验证用在判据上。
2. **引用自己读过的文件时，要读全那一段。** F10 我声称读过 `swift-contracts-smoke.yml`
   （用它论证 Swift 守卫的触发路径），却漏掉同一段里 3 行之外的 `runs-on: macos-15` ——
   而那正是回答「Linux 上能不能跑 swift」的关键。**同一份文件，为 A 问题读过 ≠ 为 B 问题读够。**
3. **本机能验的东西不要写成「本机无法验证」。** §8 方案 F 我以「需要 Linux runner + 会挂的
   Swift 工具链」为由否决挂起测试，但真正要验的机制（stdio 缓冲）**本机 20 行就能验**，
   评审员验了，我复跑也验了。**否决一个验证之前，先拆清它要验的到底是哪一层。**

---

### R5 · **Opus 子代理**对抗性评审 · 2026-09-03 · HEAD `b4bdc83` → **needs-attention**（2 high / 5 medium / 4 low）

> ⚠️ codex 配额耗尽至 **09-07 13:31**，用户明示继续用 Opus 子代理。**本轮不写 attest 账本。**
> 该评审员复核 **28 条**台账，并按要求**构造 17 种错误实现逐个实跑**。

**本轮的核心结果：R4 那条 [high] 确实修好了**（V1/V2/V3/V5 现在都被多条判据同时抓住），
**但新判据放过了另外 7 种形态** —— 其中两种正是本 spec 三处明令禁止的越界动作。

| # | 严重度 | Finding | 我的复核 | 处置 |
|---|---|---|---|---|
| **H1** | **high** | **B6 用 `-c` 命令，永远打印不出它要比对的「内容」** —— 在一个真有断言由 `NG:` 翻成 `OK:` 的形态上，两条命令都输出 `1`，执行者比对「1 == 1」判通过 | **成立，我实跑坐实**：`grep -cE '^Hardening-6 …'` 输出就是个 `1` | B6 改为**打印内容**的命令；并新增 **B7**（`plan_1f` 自身汇总行前后逐字相同） |
| **H2** | **high** | **17 种形态里 7 种能 10 条判据全绿通过**，含 V6（改断言期望值）与 V7（删 4 条断言）—— 而 D2 / D3 / §7 三处明令禁止这两个动作 ⇒ **本 spec 最核心的范围纪律，验证方案一条也没守** | **成立** | §5 **第四次重写，换主判据**：改用**精确 diff 比对**（一条顶十条，任何变体都会让 diff 不同）+ 新增 **S0 范围锁**（numstat）、**S5/S6 内容锁**、**S7/S8 哨兵锁**。全部判别力我自跑复核（F36） |
| **M3** | medium | S1–S4 **从头到尾没有一条断言 `tee` 存在** ⇒ 只要换成 `bash -o pipefail -c` 并去掉 `>`，不管有没有 tee 都全绿 | **成立** —— §5.1 里 `tee` 出现 **0** 次 | 新增 S5/S6：`2>&1 \| tee /tmp/p1` 计数。我实跑确认它一次封掉「无 tee」「`tee -a`」「改目标名」「丢 `2>&1`」四种 |
| **M4** | medium | 没有任何判据锁住哨兵；实施者若觉得「有了 pipefail 哨兵就冗余」而删掉，10 条判据一条不红。且它与「漏 pipefail」**互相掩盖** —— 单独看都不痛，组合起来就是活的假绿 | **成立** | 新增 S7/S8（两个哨兵计数各 = 1）；D1 的「为什么这样写」补写**两者防的不是同一件事** |
| **M5** | medium | S1/S2 锁的是拼写不是语义：等价写法 `bash -c "set -o pipefail; …"` 与「在改动行上方加一句含该短语的注释」都会**误红正确实现** | **成立** | 主判据换成精确 diff 后，S1/S2 降为辅助；§5.1 写明「必须逐字使用 D1 的写法」 |
| **M6** | medium | 已被本 spec 自己证伪的论断仍在两处生效，其中一处是**拒绝 codex 超时建议的承重理由** | **成立** | §0 与 §11-R2 均已订正；拒绝超时现在只靠 F26 一条理由 |
| **M7** | medium | R9（framework L96–97 有意不改）的理由**只覆盖正常失败** —— `plan_1 DDL` 排在 `plan_1f` **之前**，若它自己挂住则 `plan_1f` 永不运行，「稍后重跑覆盖」永远不发生 | **成立，且这是 R2/R3 判死的同一失效模式换了位置** | **第 5 处纳入 D1**；**R9 作废删除**；§0 的「每一层」因此字面成立，不再需要事后收窄定义 |
| **L8–L11** | low | §5 次序与产物保管未写明（非技术执行者做不了）；§11-R4 的「全部期望值已实跑」是 overclaim（改动后那列本分支不可能跑过）；F17/F18/F27 三处措辞或行号不准；计划文档 L2919–2922 将变陈旧 | **全部成立** | §5.3 加 `-keep` 副本与「必须在改代码前做」；R4 记录改为「改动前已实跑、改动后当时为推导，已于 R5 补跑」；F17/F18/F27 逐条订正；新增 **R11** |

**未采纳 / 已修正评审员的部分**：

- 评审员建议范围锁的期望值是「各为 `4　4`」。**这个数字是错的** —— 我在完整实现副本上实测为
  **`2　2`（framework）+ `3　3`（plan_1f）**（F35）。已按实测值写入。
- 评审员把 F22 的「归因未证成」列为我的问题，理由是它自己**做了**区分实验并证成了归因。
  **采纳** —— F22 的限定已放回。

**本轮的方法论收获**：

1. **⭐ 判据堆得越多，越该问「有没有一条更强的单条判据」。** 上一版是 10 条 grep，
   仍漏 7 种形态；本版换成「精确 diff 比对」**一条全覆盖**，且对执行者更省事。
   **判据的强度不等于判据的条数** —— 当一个改动的正确形态是**唯一确定**的，
   「比对完整 diff」永远比「抽查若干特征」强。
2. **⭐ 「判据文字」与「判据命令」必须能对上 —— 这是本 spec 第三次栽在同一点。**
   R2：判据要求一个已不产出的标记；R4：判据同步了标签但没同步判别力；
   R5：判据文字说「比对内容」而命令是 `-c` 只输出计数。
   ⇒ **写完每条判据，把命令原样敲一遍，看输出是不是判据文字要的那个东西。**
3. **收窄定义不是回答反驳。** R9 用「§0 的『每一层』指的是通往 plan_1f 那条链」来
   化解「第 5 处没改」，属于事后改定义而非解决问题。这次直接把第 5 处改了，定义随之自洽。
