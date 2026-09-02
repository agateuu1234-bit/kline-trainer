# acceptance 闸门失败不可观测 · 设计 spec（诊断先行）

**日期**：2026-08-31（**2026-09-02 按对抗性评审重定范围**）
**基线**：`origin/main` `1437529`
**分支**：`fix/acceptance-stale-literals`，worktree `.dev/worktree/fix-acceptance-stale-literals`
**改动面**：`scripts/acceptance/hardening_6_framework.sh`（1 处）+ `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（3 处）—— **同一种改写重复 4 次**：把重定向改成流式 `tee`，让日志在运行时就进入 CI 输出

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

把 acceptance 闸门里被重定向吞掉的日志改成**运行时流式输出**（每一层都改），
使「哪一小项挂了、为什么」在 CI 上直接可见，**且在进程挂住 / job 被取消时同样可见**；
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
| **F17** | **`/tmp/p1f.log`（及 `/tmp/p1.log` / `p1b.log` / `p1c.log`）在全仓没有任何一处被打印** ⇒ CI 上 plan_1f 的失败细节完全不可见 | `grep -rn 'p1f.log' scripts/` 只命中 `hardening_6_framework.sh:99` 的重定向本身 |
| **F18** | **`plan_1c_m0_3_swift_contracts.sh` L41–42 执行 `cd ios/Contracts && swift test`**，而 `plan_1f` L120 内嵌调用它 | 读两个脚本 |
| **F19** | 闸门 job 跑在 **`ubuntu-latest`**，而验证 F14 用的环境是 **macOS** ⇒ **Linux 侧的 `swift test` 路径零证据** | 读 `hardening_6_gate.yml` `runs-on` + §5.1 的环境说明 |
| **F20** | `plan_1b` 的 11 vs 19 早在 **2026-05-25** 就被记入 `docs/acceptance/2026-05-25-pr-e2-position-manager.md` 第 4 项并明示「可忽略」 | 读该文档 |
| **F21** | `kline_trainer_modules_v1.4.md` L144–145 的矩阵**停在 `"1.5"` / `0003_v1.3`**，而 m01 与代码都是 `"1.13"` / `0004_...`（`Models.swift:7 = "1.13"`）⇒ **两份治理矩阵分叉、modules 落后 8 版**；而 `plan_e2` L37 正断言 modules = `"1.5"` 并**通过**（绿灯锁死错值） | 逐格比对三处 + `plan_e2` 实跑输出中该项未出现在 FAIL 列表 |
| **F22** | 用户本机 `grep` 是 **ugrep 7.8.4**（被 shell 函数替换）；`grep -c "'^11 passed'"` 返回 **0**，`grep -cF` 与 `/usr/bin/grep -c` 返回 **1** | 本人在 worktree 实跑三种写法 |
| **F23** | m01 文档 L125 有一条治理 backlog 明确描述「`plan_1f` 的 CONTRACT_VERSION 矩阵 6 行断言」 ⇒ 若删除那 6 条，该治理文本将指向不存在的对象 | 读 `docs/governance/m01-schema-versioning-contract.md:125` |
| **F24** | `hardening_6_framework.sh` **L83 / L85 已在用 `bash -o pipefail -c`**（两条 pytest 断言，形态为「重定向 → 存 `ec` → `tail -3` → `exit $ec`」）⇒ 本次的 `-o pipefail` 用法是同仓既有写法，非新引入 | 读该文件 L83、L85 |
| **F25** | `plan_1f` L118–123 **把三个嵌套脚本的输出各自重定向**到 `/tmp/p1.log` / `p1b.log` / `p1c.log` ⇒ 即使流式打印 `plan_1f` 自身输出，嵌套脚本的内部细节仍然看不到，故转储块必须保留这三个 | 读 `plan_1f` L118–123 |
| **F26** | 本机**既无 `timeout` 也无 `gtimeout`** ⇒ 在脚本里写 `timeout N ...` 会让本地执行直接 `command not found` | `command -v timeout` / `command -v gtimeout` 实跑，均无 |
| **F27** | `bash -o pipefail -c "test -x X && X 2>&1 \| tee LOG"` 的解析是 `A && (B \| C)`：X 不存在时**退出 1 且零输出**；X 存在且失败时**输出实时可见且退出 1** | scratchpad 两档实跑 |
| **F28** | **改动前** `hardening_6_framework.sh` 的输出中 `matrix row:` 与 `PLAN 1f` 各出现 **0 次**（`plan_1f` 的 31 条断言明细一行都上浮不到）；顶层标签 `regression: Plan 1f` 出现 3 次（framework 自己打的） | 本 worktree 实跑并 `grep -c` |
| **F29** | 顶层汇总数字**随环境变化**：本机无 venv 时 `11 passed, 3 failed`，CI 上 `13 passed, 1 failed` ⇒ 该数字**不可写死为判据**，只能做同环境前后对比 | 本机实跑 vs CI 日志比对 |

---

## 4. 决策

### D1　让 acceptance 的日志在**每一层**都流式输出

**两个文件、共 4 处，全部是同一种改写**：`> FILE 2>&1` → `2>&1 | tee FILE`，
并把 `bash -c` 换成 `bash -o pipefail -c`。

**A. `scripts/acceptance/hardening_6_framework.sh`（1 处，L98–99）**

```bash
run "regression: Plan 1f schema versioning" \
  bash -o pipefail -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh 2>&1 | tee /tmp/p1f.log && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"
```

**B. `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（3 处，L118–123）**

```bash
run "regression: Plan 1 (M0.1 DDL) acceptance" \
    bash -o pipefail -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh 2>&1 | tee /tmp/p1.log"
run "regression: Plan 1b (M0.2 OpenAPI) acceptance" \
    bash -o pipefail -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh 2>&1 | tee /tmp/p1b.log"
run "regression: Plan 1c (M0.3 Swift Models) acceptance (间接覆盖 Plan 1d AppError swift test)" \
    bash -o pipefail -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh 2>&1 | tee /tmp/p1c.log"
```

**不再需要任何事后转储块。** 所有输出在**运行时**就进入 CI 日志。

> ⚠️ **本节已按 codex R3 第二次重写**（见 §11）。演化过程本身是判据的一部分：
> - **初稿**：`> log` + 失败后 `cat` ⇒ **挂住时零证据**（R2 high）。
> - **R2 版**：只把最外层改流式 + 事后转储三个嵌套日志 ⇒ **挂住时仍丢最关键的那份**
>   （`swift test` 的输出被 `plan_1f` 重定向进 `/tmp/p1c.log`，转储块在 `run` 返回后才执行，
>   而挂住时 `run` 永不返回）（R3 high）。
> - **本版**：**每一层都流式** ⇒ 挂住时 `swift test` 已经打印的内容**已经在 CI 日志里**。
>   顺带**删掉**了 R2 版引入的 `_h6_fail_before` 转储机制，改动比 R2 版**更小**。

**为什么这样写：**

1. **`-o pipefail` 不可省** —— 没有它，管道退出码取自 `tee`（恒 0），被测脚本的失败会被吞掉，
   直接制造假绿。**同仓已有此写法先例**：`hardening_6_framework.sh` L83 / L85（F24）。
2. **保留 `tee` 写文件而不是纯 `echo`** —— `plan_1f` 末尾会提示「失败日志位置：`/tmp/p1.log` …」，
   保留文件不破坏该提示；且 `grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log` 这条**哨兵检查依赖该文件存在**。
3. **`test -x X && X | tee` 的优先级已实测**（F27）：shell 解析为 `A && (B | C)`，
   脚本不存在时直接失败且不产生输出，脚本存在时管道正常运行、`pipefail` 正确传递失败。
4. **不碰任何 `run()` 函数** —— 两个文件的 `run()` 都被各自全部断言共用，改它会把风险面从 4 处扩到几十处。

**已隔离实测（scratchpad，`bash -o pipefail -c` 形态）：**

| 档 | 输入 | 实际 |
|---|---|---|
| A | 被测脚本失败退出 1 | 输出**实时可见**，整体退出码 **1** ✅ |
| B | 被测脚本成功且哨兵 `PLAN 1f PASS` 存在 | 退出码 **0** ✅ |
| C | 被测脚本**静默返回 0 但哨兵缺失** | 退出码 **1** ✅ —— **原有哨兵防护未被削弱**（L96–97 注释所防的正是「捕获了失败却返回 0」） |
| D | `test -x` 目标不存在 | 退出码 **1**、零输出 ✅ |

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
⇒ 本 PR 上 `relevant=true` ⇒ acceptance 脚本**必然真执行** ⇒ 新加的日志转储**必然被触发**（因为 plan_1f 必然失败）。

**本 PR 因此不需要依赖 PR #179 的重跑来取证** —— 初稿把确认点挂在 #179 上，
而 #179 的实施计划明令「⛔ 不得 rebase 本分支」，两条纪律互相冲突（§11 Finding 4）。本决策消除该耦合。

### D5　修复方案待证据到位后另行设计

拿到 CI 完整失败面后，**另开一份 spec** 设计修复。届时至少已知的候选范围：
`plan_1f` 6 条矩阵断言、`plan_1b` 的 `11 passed`、`plan_e2` 的 4 处字面量（F9）、
modules 矩阵落后 8 版（F21）、m01 L125 的悬空 backlog（F23）、
以及 CI 才会暴露的 Linux 侧问题。**本 spec 不预判其结论。**

---

## 5. 验证方案

### 5.1 负向对照（必做）

改动**之前**在当前树跑一次并存档：

```bash
bash scripts/acceptance/hardening_6_framework.sh > /tmp/h6-before.log 2>&1
grep -c 'matrix row:' /tmp/h6-before.log
grep -c 'PLAN 1f' /tmp/h6-before.log
```

**两条期望值均为 `0`** —— 即 `plan_1f` 的 31 条断言明细**一行都到不了上层输出**。
**已在本 worktree 实跑确认：两条均为 0**（另：`regression: Plan 1f` 这个**顶层标签**出现 3 次，
那是 `framework` 自己打的，不是 `plan_1f` 的明细，勿混淆）。

> 若改动**之前**这两条就不是 0，说明该判据零判别力，停下来查。

### 5.2 本地正向

改动**之后**同样跑一次并对比：

```bash
bash scripts/acceptance/hardening_6_framework.sh > /tmp/h6-after.log 2>&1
grep -c 'matrix row:' /tmp/h6-after.log
grep -c 'PLAN 1f' /tmp/h6-after.log
grep -E 'acceptance: .* passed' /tmp/h6-before.log /tmp/h6-after.log
```

**判据三条：**

1. `matrix row:` 计数 **> 0**（`plan_1f` 的逐条明细已上浮）；
2. `PLAN 1f` 计数 **> 0**（其结论行已上浮）；
3. **两次运行的顶层汇总行完全相同** —— 即 `N passed, M failed` 的两个数字不因本次改动而变化。
   ⚠️ **不得写死这两个数字**：它们随本机是否装齐 Python 依赖而变
   （无 venv 时实测 `11 passed, 3 failed`，CI 上是 `13 passed, 1 failed`）。
   判据是**同环境前后一致**，不是某个具体值。

### 5.3 CI 级（本 PR 自证，见 D4）

PR 开出后，`acceptance` 检查**预期为红**（D3）。在其日志中确认：

1. 出现 `plan_1f` 的逐条断言明细（`OK:` / `NG:` 行），而非只有一行顶层 `NG`；
2. 出现三个嵌套脚本（Plan 1 / 1b / 1c）各自的输出；
3. 记录下 `plan_1f` 在 **ubuntu-latest** 上的**完整失败项清单** —— 这是本 PR 的交付物。

> ⚠️ **判绿纪律不适用于本 PR** —— 成功判据不是「检查变绿」，而是**「失败面变得可读」**。
> 若 `acceptance` 意外变绿，反而说明有别的东西不对，需要排查。

### 5.4 明确不做的验证

- 不预测 `plan_1f` 在 Linux 上会失败在哪几项。任何此类预测都是猜测。
- **不构造人工挂起测试**。codex R3 建议「加一个有界的挂起测试，验证输出在被终止前到达 CI」。
  **不采纳**：要真实复现「CI 上 `swift test` 挂住」需要一个 Linux runner + 一个会挂的 Swift 工具链，
  本机无法构造等价环境；用 `sleep` 伪造的挂起只能证明 `tee` 会流式（已由 D1 的实测档 A 证明），
  证明不了真实场景。**流式与非流式的差别是结构性的**（输出在运行时进入 stdout vs 运行后才写出），
  不依赖挂起测试来确立。

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R1** | `plan_1f` 的 4 条矩阵断言 + `plan_1b` 的 `11 passed` **仍然是红的** | 本次有意不修（D2） | 待 D5 的修复 spec |
| **R2** | `plan_e2_position_manager.sh` 带着 2 条红断言留在仓里（F9），且其 L37 用绿灯锁死了 modules 矩阵的错值（F21） | 既有故障，非本次引入；初稿曾错误声称其无问题 | 待 D5；**已在台账中订正，不再有「其余脚本干净」的错误陈述** |
| **R3** | `kline_trainer_modules_v1.4.md` 矩阵落后 8 版（F21），与 m01 分叉 | 治理文档不一致，影响任何按它核对版本的人 | 待 D5；需先厘清两份矩阵谁是权威 |
| **R4** | `plan_1f` 在 `ubuntu-latest` 上跑 `swift test`（F18/F19），可行性未知 | **本 PR 的存在就是为了回答它** | 由 §5.3 的 CI 运行给出答案 |
| **R5** | 闸门仍对绝大多数 PR 短路放行（F4）⇒ 剩余断言仍是低频执行、仍可能腐烂 | 短路机制本身是正确的（防另一种死锁）；本次不改变执行频率 | 超出范围 |
| **R6** | 「验收清单里口头豁免闸门失败」这一失效模式（F20）无任何机制约束 | 真实且已发生过一次 | 超出范围，记入独立 backlog |
| **R7** | 流式输出会让 CI 日志显著变长（**成功时也会**，且现在含三个嵌套脚本的全部输出，其中 `plan_1c` 的 `swift test` 输出可达数百行） | 该闸门 25 次运行里只有 2 次真跑满（F4），量级可接受；相比「完全看不见」是净收益。**这是本次有意付出的代价** | 接受 |
| **R8** | 若 `plan_1c` 的 `swift test` 在 Linux 上**挂住**，job 会跑到 GitHub 默认的 **360 分钟**上限才被杀 | **证据不会丢失**（流式输出已落在 CI 日志里，能看出停在哪一行）；代价只是等待时间与 runner 占用，而本仓为 PUBLIC、标准 runner 免费无限额 | 接受。**未采纳** codex R2 建议的「在脚本里加 `timeout`」—— 本机既无 `timeout` 也无 `gtimeout`（F26），写进去会让本地执行直接失败。若将来要限时，正确位置是 workflow 的 job 级 `timeout-minutes`，属独立改动 |

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
```

**两条期望值依次为 `0` 与 `0`**（= 4 处流式改写已全部撤销）。
**已在本 worktree 实跑确认两条均为 0**（当前树尚未实施）。

⚠️ 用 `grep -cF`（定长串）而非正则形式 —— 用户本机 `grep` 是 ugrep 7.8.4（F22），
正则元字符的行为与 GNU/BSD grep 不同。

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
  **该风险已量化记为 R8**：流式输出已保证证据不丢失，挂住的代价只是等待时间，
  且本仓 PUBLIC、标准 runner 免费无限额。
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
