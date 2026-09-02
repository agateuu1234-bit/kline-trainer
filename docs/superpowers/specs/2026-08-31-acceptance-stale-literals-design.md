# acceptance 闸门失败不可观测 · 设计 spec（诊断先行）

**日期**：2026-08-31（**2026-09-02 按对抗性评审重定范围**）
**基线**：`origin/main` `1437529`
**分支**：`fix/acceptance-stale-literals`，worktree `.dev/worktree/fix-acceptance-stale-literals`
**改动面**：`scripts/acceptance/hardening_6_framework.sh` **单文件、单处**（失败时打印被吞掉的日志）

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

必需闸门 `acceptance` 失败时，**把被重定向吞掉的 `plan_1f` 日志打印出来**，
使「哪一小项挂了」在 CI 上直接可见；本次**不修复任何断言**。

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

---

## 4. 决策

### D1　`hardening_6_framework.sh`：`plan_1f` 失败时打印其日志与三个嵌套日志

在第 98–99 行的 `run` 调用**前后**加入失败检测与日志转储，**不修改共享的 `run()` 函数**：

```bash
_h6_fail_before=$FAIL
run "regression: Plan 1f schema versioning" \
  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1 && grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log"
if [[ $FAIL -ne $_h6_fail_before ]]; then
  for _h6_log in /tmp/p1f.log /tmp/p1.log /tmp/p1b.log /tmp/p1c.log; do
    [[ -f "$_h6_log" ]] || continue
    echo ""; echo "---------- $_h6_log ----------"; cat "$_h6_log"
  done
fi
```

**为什么这样写：**

1. **用「失败计数前后比较」而非匹配 label 字符串** —— 后者依赖标签文本，改标签即静默失效。
2. **不碰 `run()`** —— 它被全部 14 条断言共用，改它会把风险面从 1 条扩到 14 条。
3. **同时转储三个嵌套日志** —— `plan_1f` 自己把 `plan_1` / `plan_1b` / `plan_1c` 的输出也重定向了（其末行提示了这三个路径）。只打印 `p1f.log` 只能知道**哪一层**挂了，知道不了**为什么**；一次 CI 就要拿到完整失败面。
4. **`[[ -f ]] || continue` 而非直接 `cat`** —— 文件可能不存在（例如 `plan_1f` 在到达嵌套段之前就失败），`set -euo pipefail` 下直接 `cat` 会中断脚本。

**已隔离实测**（scratchpad，`set -euo pipefail` 环境下）：

| 档 | 输入 | 实际结果 |
|---|---|---|
| 失败档 | `FAIL` 由 0 变 1、4 个日志中只存在 2 个 | **打印存在的 2 个、跳过缺失的 2 个，脚本正常走完（退出码 0）** ✅ |
| 成功档 | `FAIL` 未变 | **零额外输出** ✅ |

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

改动**之前**在当前树跑 `bash scripts/acceptance/hardening_6_framework.sh`，
断言输出中**不含** `---------- /tmp/p1f.log ----------` 这一行。
若改动前就含有，说明该判据零判别力。

### 5.2 本地正向

改动**之后**同样跑一遍，断言：

1. 输出**包含** `---------- /tmp/p1f.log ----------`；
2. 输出**包含** `plan_1f` 内部逐条断言的 `NG:` 明细（即真正拿到了失败面）；
3. 顶层汇总行仍为 `Hardening-6 framework acceptance: 13 passed, 1 failed`
   —— **断言结果本身零改变**，只多了输出。

### 5.3 CI 级（本 PR 自证，见 D4）

PR 开出后，`acceptance` 检查**预期为红**（D3）。在其日志中确认：

1. 出现 `---------- /tmp/p1f.log ----------` 及后续明细；
2. 记录下 `plan_1f` 在 **ubuntu-latest** 上的**完整失败项清单** —— 这是本 PR 的交付物。

> ⚠️ **判绿纪律不适用于本 PR** —— 本 PR 的成功判据不是「检查变绿」，而是
> **「失败面变得可读」**。若 `acceptance` 意外变绿，反而说明日志转储没被触发，需要排查。

### 5.4 明确不做的验证

不预测 `plan_1f` 在 Linux 上会失败在哪几项。任何此类预测都是猜测，
本 spec 拒绝把它写成事实（初稿正是栽在这里）。

---

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R1** | `plan_1f` 的 4 条矩阵断言 + `plan_1b` 的 `11 passed` **仍然是红的** | 本次有意不修（D2） | 待 D5 的修复 spec |
| **R2** | `plan_e2_position_manager.sh` 带着 2 条红断言留在仓里（F9），且其 L37 用绿灯锁死了 modules 矩阵的错值（F21） | 既有故障，非本次引入；初稿曾错误声称其无问题 | 待 D5；**已在台账中订正，不再有「其余脚本干净」的错误陈述** |
| **R3** | `kline_trainer_modules_v1.4.md` 矩阵落后 8 版（F21），与 m01 分叉 | 治理文档不一致，影响任何按它核对版本的人 | 待 D5；需先厘清两份矩阵谁是权威 |
| **R4** | `plan_1f` 在 `ubuntu-latest` 上跑 `swift test`（F18/F19），可行性未知 | **本 PR 的存在就是为了回答它** | 由 §5.3 的 CI 运行给出答案 |
| **R5** | 闸门仍对绝大多数 PR 短路放行（F4）⇒ 剩余断言仍是低频执行、仍可能腐烂 | 短路机制本身是正确的（防另一种死锁）；本次不改变执行频率 | 超出范围 |
| **R6** | 「验收清单里口头豁免闸门失败」这一失效模式（F20）无任何机制约束 | 真实且已发生过一次 | 超出范围，记入独立 backlog |
| **R7** | 日志转储会让失败时的 CI 输出显著变长 | 仅在失败时发生；相比「完全看不见」是净收益 | 接受 |

---

## 7. 本 spec 明确不做

- 不修改任何 acceptance 断言（D2）；
- 不修改 `plan_1f` / `plan_1b` / `plan_e2` / `plan_1c` / `plan_1`；
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
| **E** | 让 `plan_1f` 自己在失败时打印嵌套日志（改 `plan_1f` 而非 `framework`） | 需要改**被诊断的对象本身**，且 `plan_1f` 仍会被 D5 的修复改动 —— 诊断设施应放在**不打算改**的那一侧 |

---

## 9. 回滚方案

单文件、单处、纯新增输出、**零断言语义改动**。本次实施只产生**一个**提交。

- **已合并进 `main` 后**：`git revert --no-edit <squash 提交 sha>`；若为 merge commit 则 `git revert --no-edit -m 1 <sha>`。
- **分支上**：`git revert --no-edit <该提交 sha>`。

⛔ `git revert` **没有 `-q` 选项**，误写会只打印 usage 而**什么都不做**（已实测 `git revert -h`）。

**回滚后核实**：

```bash
grep -cF '_h6_fail_before' scripts/acceptance/hardening_6_framework.sh
```

期望 **0**（= 回到基线）。

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
