# acceptance 闸门日志流式化 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让必需闸门 `acceptance` 失败时，被重定向吞掉的日志在 CI 上**运行时可见**，从而拿到它到底为什么红的完整失败面。

**Architecture:** 两个 shell 脚本、共 5 处**同一种机械变换**：`bash -c` → `bash -o pipefail -c`，且 `> FILE 2>&1` → `2>&1 | tee FILE`。其余一字不动（哨兵 `&& grep -Fxq '…'` 原样保留）。**本次不修复任何断言。**

**Tech Stack:** Bash；`git`；`grep`（⚠️ 本机是 ugrep，判据一律用 `-F`）；Python 3（仅用于执行改写脚本）。

**Spec:** `docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md`
（**5 轮对抗性评审**：R1/R4/R5 Opus 子代理、R2/R3 codex。⚠️ **本线至今没有任何 codex attest 账本条目** —— codex 配额耗尽至 2026-09-07 13:31，后三轮走子代理通道，不写账本。）

---

## Global Constraints

1. **唯一可改的两个文件**：`scripts/acceptance/hardening_6_framework.sh`、`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`。**不得**新建或修改任何其它文件（本计划自身与 spec 除外）。
2. **⛔ 不得触碰任何断言**：不改任何期望值、不删任何 `run` 行、不动任何 `run()` 函数。**违反此条的两种形态（改断言期望值 / 删断言）由主判据 + S0 + B7 三重锁住**。
3. **⛔ 哨兵一字不动**：`hardening_6_framework.sh` 里两处 `&& grep -Fxq 'PLAN 1 PASS' /tmp/p1.log` 与 `&& grep -Fxq 'PLAN 1f PASS' /tmp/p1f.log` 必须完整保留。它与 `-o pipefail` **防的不是同一件事**（`pipefail` 防「管道吞码」，哨兵防「脚本自己 return 0」），删任何一个都开一个洞。
4. **⚠️ 本 PR 不会让 `acceptance` 变绿，这是有意的**（spec D3）。`plan_1f` 仍会失败 ⇒ `acceptance` 仍为红 ⇒ **在后续修复落地前不可合并**。本 PR 的产物是**那一次 CI 失败运行里打印出来的完整失败面**。
5. **⛔ 不得为了让 PR 变绿而顺手改断言** —— 那正是 spec D2 否决的做法。
6. **判绿纪律**：一律读**输出内容**判定，不靠管道后的 `$?`。`grep -c` 计数为 0 时退出码是 1，**验收命令一行一条单独敲**，不要串进带 `set -e` 的脚本。
7. **⚠️ 本机 `grep` 是 ugrep 7.8.4**（被 shell 函数替换）。所有计数判据一律用 **`grep -cF`**（定长串）。
8. **提交信息 / PR 正文语言**：中文。
9. **push 与开 PR 由用户在自己的终端执行**，Claude 不执行这两步。

---

## File Structure

| 文件 | 动作 | 改几处 |
|---|---|---|
| `scripts/acceptance/hardening_6_framework.sh` | 修改 | **2 处**（L96–97 的 `regression: Plan 1 DDL`、L98–99 的 `regression: Plan 1f schema versioning`） |
| `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 修改 | **3 处**（L118–123 的三条 `regression:` 嵌套调用） |
| `docs/superpowers/specs/2026-08-31-…-design.md` | 已存在，不改 | — |
| `docs/superpowers/plans/2026-09-03-acceptance-log-streaming.md` | 本文件 | — |

**不创建任何新文件**（改写脚本放 `/tmp`，不进仓库）。

---

## 全流程 dry-run 证据（写计划前已完成）

本计划内嵌的改写脚本与全部期望值，**已在 worktree 的一份完整副本上端到端跑过**（副本用完即弃，真分支零污染）：

| 项 | 实测结果 |
|---|---|
| 改写脚本执行 | `OK: 5 处全部改完（2 个文件）` |
| 主判据：精确 diff | **5 行减号、5 行加号** |
| 范围锁 numstat | `2　2　hardening_6_framework.sh` + `3　3　plan_1f_m0_1_schema_versioning.sh` |
| **幂等性**（脚本重复执行） | **正确中止、不写盘**：`ABORT: 锚点在 … 命中 0 次（必须恰好 1 次）` |

---

### Task 1: 五处流式化改写

**Files:**
- Modify: `scripts/acceptance/hardening_6_framework.sh`（2 处）
- Modify: `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（3 处）

**Interfaces:**
- Consumes: 无
- Produces: 改写后的两个脚本。后续无 Task 依赖其产出（Task 2 是纯验证）。

---

- [ ] **Step 1: 确认起点，并留下负向对照的存档**

⛔ **这一步必须在改代码之前做。** 两个 `-keep` 副本要活到 Task 2 比对完。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"
pwd
git rev-parse --abbrev-ref HEAD
git rev-parse --short HEAD
git status --short
```

**期望**：路径是该 worktree、分支 `fix/acceptance-stale-literals`、`git status --short` **零输出**。

```bash
mkdir -p /tmp/h6plan
bash scripts/acceptance/hardening_6_framework.sh > /tmp/h6-before.log 2>&1
cp /tmp/h6-before.log /tmp/h6-before-keep.log
cp /tmp/p1f.log /tmp/p1f-before-keep.log
```

> 该命令会以非 0 退出（闸门本来就是红的），**这是预期的**，不要当成失败。

---

- [ ] **Step 2: 跑负向对照，确认判据在改动前全红**

一行一条敲：

```bash
grep -cF 'bash -o pipefail -c' scripts/acceptance/hardening_6_framework.sh
grep -cF 'bash -o pipefail -c' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF '> /tmp/p1' scripts/acceptance/hardening_6_framework.sh
grep -cF '> /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF '2>&1 | tee /tmp/p1' scripts/acceptance/hardening_6_framework.sh
grep -cF '2>&1 | tee /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -c 'matrix row:' /tmp/h6-before.log
grep -c 'PLAN 1c' /tmp/h6-before.log
```

**期望输出，依次为：`2` `0` `2` `3` `0` `0` `0` `0`**
（**这八个值已在本 worktree 实跑确认**。）

> ⚠️ **这一步是负向对照，不能跳过。** 若某条在改动**之前**就已是「改动后」的值，说明该判据对本次改动零判别力。

---

- [ ] **Step 3: 生成改写脚本**

```bash
cat > /tmp/h6plan/apply.py <<'SCRIPT'
#!/usr/bin/env python3
"""acceptance 日志流式化：5 处机械变换。每处锚点必须恰好命中 1 次，否则整体中止不写盘。"""
import io, sys

F = "scripts/acceptance/hardening_6_framework.sh"
G = "scripts/acceptance/plan_1f_m0_1_schema_versioning.sh"

EDITS = [
    (F, '  bash -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1 && grep -Fxq \'PLAN 1 PASS\' /tmp/p1.log"',
        '  bash -o pipefail -c "./scripts/acceptance/plan_1_m0_1_db_schema.sh 2>&1 | tee /tmp/p1.log && grep -Fxq \'PLAN 1 PASS\' /tmp/p1.log"'),
    (F, '  bash -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/p1f.log 2>&1 && grep -Fxq \'PLAN 1f PASS\' /tmp/p1f.log"',
        '  bash -o pipefail -c "./scripts/acceptance/plan_1f_m0_1_schema_versioning.sh 2>&1 | tee /tmp/p1f.log && grep -Fxq \'PLAN 1f PASS\' /tmp/p1f.log"'),
    (G, '    bash -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh > /tmp/p1.log 2>&1"',
        '    bash -o pipefail -c "test -x scripts/acceptance/plan_1_m0_1_db_schema.sh && ./scripts/acceptance/plan_1_m0_1_db_schema.sh 2>&1 | tee /tmp/p1.log"'),
    (G, '    bash -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh > /tmp/p1b.log 2>&1"',
        '    bash -o pipefail -c "test -x scripts/acceptance/plan_1b_m0_2_rest_api.sh && ./scripts/acceptance/plan_1b_m0_2_rest_api.sh 2>&1 | tee /tmp/p1b.log"'),
    (G, '    bash -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh > /tmp/p1c.log 2>&1"',
        '    bash -o pipefail -c "test -x scripts/acceptance/plan_1c_m0_3_swift_contracts.sh && ./scripts/acceptance/plan_1c_m0_3_swift_contracts.sh 2>&1 | tee /tmp/p1c.log"'),
]

bufs = {}
for path, old, new in EDITS:
    if path not in bufs:
        bufs[path] = io.open(path, encoding="utf-8").read()
    cnt = bufs[path].count(old)
    if cnt != 1:
        sys.exit("ABORT: 锚点在 %s 命中 %d 次（必须恰好 1 次）：\n%s" % (path, cnt, old[:90]))
    bufs[path] = bufs[path].replace(old, new)

for path, text in bufs.items():
    io.open(path, "w", encoding="utf-8").write(text)
print("OK: 5 处全部改完（%d 个文件）" % len(bufs))
SCRIPT
```

**该脚本的两条安全性质（已 dry-run 验证）：**
1. **全有或全无** —— 五个锚点任一命中次数 ≠ 1 就 `sys.exit` 中止，**在写盘之前**；
2. **幂等安全** —— 重复执行会因锚点已消失而中止，不会造成二次改写。

---

- [ ] **Step 4: 执行改写**

```bash
python3 /tmp/h6plan/apply.py
```

**期望输出，一字不差**：`OK: 5 处全部改完（2 个文件）`

> 若输出以 `ABORT:` 开头，**不要手工去改文件**。停下来核对：当前树是否干净、是否已经跑过一次。

---

- [ ] **Step 5: 主判据 —— 精确 diff 比对**

```bash
git diff origin/main -- scripts/acceptance/
```

**输出的增删行必须与下面**逐字符相同（**恰好 5 行减号、5 行加号，仅涉及那两个文件**）：

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

> **为什么这是主判据**：spec §5.5 记录了 17 种错误实现形态（少改一处、漏 `-o pipefail`、
> 丢 `2>&1`、用 `tee -a`、改 tee 目标名、不写 tee、删哨兵、改断言期望值、删断言、越界改别的行……）
> —— **每一种都会让这份 diff 与上面不同**。上一版靠 10 条 grep 抽查，实测有 7 种抓不住。

---

- [ ] **Step 6: 机械辅助判据（改动后）**

一行一条敲：

```bash
git diff --numstat origin/main -- scripts/acceptance/
grep -cF 'bash -o pipefail -c' scripts/acceptance/hardening_6_framework.sh
grep -cF 'bash -o pipefail -c' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF '> /tmp/p1' scripts/acceptance/hardening_6_framework.sh
grep -cF '> /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF '2>&1 | tee /tmp/p1' scripts/acceptance/hardening_6_framework.sh
grep -cF '2>&1 | tee /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF "PLAN 1f PASS' /tmp/p1f.log" scripts/acceptance/hardening_6_framework.sh
grep -cF "PLAN 1 PASS' /tmp/p1.log" scripts/acceptance/hardening_6_framework.sh
```

**期望，依次为：**

| # | 期望 | 它锁住什么 |
|---|---|---|
| numstat | 恰好两行：`2　2　…hardening_6_framework.sh`、`3　3　…plan_1f_m0_1_schema_versioning.sh` | **范围锁** —— 越界改/删任何别的行都会让这两个数字变（实测：改一条断言期望值 → `4　4`；删 4 条断言 → `3　21`） |
| S1 | **4** | framework 两处都加了 `-o pipefail`（原有 2 + 新增 2） |
| S2 | **3** | plan_1f 三处都加了 |
| S3 | **0** | framework 旧形态已消失 |
| S4 | **0** | plan_1f 旧形态已消失 |
| S5 | **2** | framework 两处**真的**是 `2>&1 \| tee`（封掉「无 tee」「`tee -a`」「改目标名」「丢 `2>&1`」） |
| S6 | **3** | plan_1f 三处同上 |
| S7 | **1** | `PLAN 1f` 哨兵未被删 |
| S8 | **1** | `PLAN 1 ` 哨兵未被删（范围锁抓不住「同一行内删哨兵」，实测仍是 `2　2`，**必须靠这条**） |

---

- [ ] **Step 7: 行为判据 —— 确认每一层的输出都上浮了、且断言结果零改变**

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

| # | 判据 | 期望 |
|---|---|---|
| B1–B4 | 前四条计数 | **全部 > 0**（改动前全是 0） |
| B5 | 第五条计数 | **1**（顶层汇总行没被嵌套层同格式汇总污染） |
| B6 | 第六、七条的**输出内容** | **两行一字不差** ⇒ framework 层没有任何断言由红变绿 |
| B7 | 第八、九条的**输出内容** | **两行一字不差** ⇒ **plan_1f 内部 31 条断言的结果零改变**（这是唯一能看见「越界改/删断言」的行为判据） |

> ⚠️ **B6 / B7 必须用打印内容的命令，不能用 `-c`。** 本 spec 曾三次栽在「判据文字与判据命令对不上」：
> `-c` 只输出行数，永远打印不出要比对的内容 —— 曾在一个真有断言由 `NG:` 翻成 `OK:` 的形态上，
> 两条 `-c` 都输出 `1`，执行者比对「1 == 1」判通过。
>
> ⚠️ **B6 / B7 不得写死具体数字**：本机无 venv 时 framework 汇总是 `11 passed, 3 failed`，
> CI 上是 `13 passed, 1 failed`；`plan_1f` 自身汇总本机 venv 下是 `24 passed, 7 failed`。
> **判据是同环境前后逐字相同，不是某个具体值。**

---

- [ ] **Step 8: 提交**

```bash
git add scripts/acceptance/hardening_6_framework.sh scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
git commit -m "fix(ci): acceptance 闸门日志改为运行时流式输出（5 处）

必需检查 acceptance 红了，但 CI 日志里只有一行 NG: regression: Plan 1f
schema versioning —— plan_1f 的输出被重定向到 /tmp/p1f.log，而该文件在
scripts/ 下从未被 cat 过；它内嵌的三个脚本又各自重定向到另外三个文件。
于是「哪一小项挂了、为什么」在 CI 上完全不可见，排查只能在本地从零复现。

本次把 5 处重定向全部改成运行时流式：
  bash -c            → bash -o pipefail -c
  > FILE 2>&1        → 2>&1 | tee FILE
其余一字不动，两个哨兵 && grep -Fxq '…' 完整保留。

-o pipefail 不可省：没有它管道退出码取自 tee（恒 0），被测脚本的失败会
被吞掉，直接制造假绿。同仓 L83/L85 已有此写法先例。

为什么必须含 framework L96-97 那一处（第 5 处）：regression: Plan 1 DDL
排在 plan_1f 之前，若它自己挂住则 plan_1f 永不运行，「稍后重跑覆盖」永远
不会发生 —— 那正是本 spec 前两轮评审判死的同一失效模式换了位置。

⚠️ 本次不修复任何断言。acceptance 仍会是红的，这是有意的：本 PR 的产物
是那一次失败运行打印出的完整失败面，修复按证据另行设计。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BvzrZhLtJNBrVbVbyNdDjz"
```

---

### Task 2: 交付前整体核验

**Files:** 无改动（纯核验）

**Interfaces:**
- Consumes: Task 1 的产出

---

- [ ] **Step 1: 工作区与范围**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"
pwd
git rev-parse --abbrev-ref HEAD
git status --short
git diff --name-only main...HEAD
```

**期望**：分支 `fix/acceptance-stale-literals`、`git status --short` **零输出**、
`git diff --name-only main...HEAD`（**三个点**）恰好 **4 行**：

```
docs/superpowers/plans/2026-09-03-acceptance-log-streaming.md
docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md
scripts/acceptance/hardening_6_framework.sh
scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
```

> ⚠️ **三个点，不是两个点。** 两点式比的是两个分支顶端，`main` 一旦前进就会把 main 独有的改动一并算成本分支的。

---

- [ ] **Step 2: 生成 PR 正文（必须早于 Step 3）**

```bash
cat > /tmp/h6plan/pr-body.md <<'BODY'
## 问题

必需检查 `acceptance` 是红的 —— 但 **CI 日志里只有一行** `NG: regression: Plan 1f schema versioning`，看不出 31 条断言里挂了哪一条、也看不出嵌套三层里挂在哪一层。

根因：`plan_1f` 的输出被重定向到 `/tmp/p1f.log`，而该文件在 `scripts/` 下**从未被打印过**；它内嵌的 `plan_1` / `plan_1b` / `plan_1c` 又各自重定向到另外三个文件，同样从不打印。

⚠️ 这个红灯**与 PR #179 无关**（三条独立证据见 spec §1）：2026-08-16 在无关分支上 CI 里同一项失败、同样数字；干净 `origin/main` 上本地复现；#179 的 diff 与文档断言脚本零接触面。

## 本 PR 做什么

**只做一件事：让失败可观测。5 处同一种机械变换（5 删 5 加）。**

```
bash -c        →  bash -o pipefail -c
> FILE 2>&1    →  2>&1 | tee FILE
```

其余一字不动，两个哨兵 `&& grep -Fxq '…'` 完整保留。

- `-o pipefail` **不可省**：没有它管道退出码取自 `tee`（恒 0），被测脚本的失败会被吞掉 —— 直接制造假绿。同仓 L83/L85 已有此写法先例。
- 为什么含 framework L96–97（第 5 处）：`regression: Plan 1 DDL` 排在 `plan_1f` **之前**，若它自己挂住则 `plan_1f` 永不运行，「稍后重跑覆盖」永远不会发生。

## ⚠️ 本 PR **不会**让 `acceptance` 变绿，这是有意的

`plan_1f` 仍会失败 ⇒ `acceptance` 仍为红 ⇒ **在后续修复落地前不可合并**。

**本 PR 的产物是那一次失败运行里打印出来的完整失败面。** 拿到它之后，修复提交会追加到本 PR，直至转绿方可合并。

⛔ 不得为了让 PR 变绿而顺手改断言。

## 已知但本次不修（残留风险台账见 spec §6）

| # | 内容 |
|---|---|
| R1 | `plan_1f` 的 4 条版本号断言过期（脚本要 `"1.5"`，文档已是 `"1.13"`）+ `plan_1b` 要求「正好 11 passed」而实际 19 |
| R2 | `plan_e2_position_manager.sh` 带着 2 条同族红断言，其中一条**用绿灯锁死了错值** |
| R3 | `kline_trainer_modules_v1.4.md` 的版本矩阵**落后 8 版**，与 m01 文档分叉 |
| R4 | `plan_1c` 在 `ubuntu-latest` 上跑 `swift test`，而 gate 全文零处提到 swift ⇒ **预期因缺工具链快速失败**（本 PR 正是要看清这一点） |
| R6 | 该缺陷 2026-05-25 就被写进验收清单并明示「可忽略」—— 「看见了但当噪音放行」这条失效模式无任何机制约束 |

## 验证状态（诚实声明）

| 命题 | 状态 |
|---|---|
| 5 处改写逐字符正确 | ✅ 主判据「精确 diff 比对」+ 8 条机械辅助判据，全部实跑 |
| 断言结果零改变 | ✅ framework 与 plan_1f 两层汇总行前后**逐字相同** |
| 每一层输出都上浮 | ✅ 改动前四条计数全为 0，改动后全 > 0 |
| **Linux 侧的完整失败面** | ⚠️ **本 PR 的交付物，待本次 CI 运行给出** |

## 评审

**5 轮对抗性评审**（R1/R4/R5 Opus 子代理、R2/R3 codex），每轮都挖出真 high，其中四条足以让本 PR 白做：

| 轮 | 那条 high |
|---|---|
| R2 | 诊断在「挂住」时零证据 |
| R3 | 只修对一半，最关键的嵌套日志仍会丢 |
| R4 | **验收判据形同虚设** —— 半吊子实现能 100% 通过 |
| R5 | 判据放过 17 种形态里的 7 种，含两种越界动作 |

⚠️ **本线至今没有任何 codex attest 账本条目**：codex 配额于 2026-09-02 耗尽（恢复 09-07 13:31），后三轮走 Opus 子代理通道，**该通道不写账本**。这一点不含糊。

- 设计 spec：`docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md`（37 条事实台账 / 11 条残留风险 / 5 轮评审记录）
- 实施计划：`docs/superpowers/plans/2026-09-03-acceptance-log-streaming.md`
BODY
```

**生成后立刻校验非空：**

```bash
[ -s /tmp/h6plan/pr-body.md ] && echo "OK 非空，$(wc -l < /tmp/h6plan/pr-body.md) 行" || echo "FAIL 文件为空或不存在"
```

---

- [ ] **Step 3: 交给用户 push 与开 PR**

> ⚠️ **本步依赖 Step 2 已生成 `/tmp/h6plan/pr-body.md`，顺序不可颠倒。**
> 干净环境下该文件不存在会让开 PR 的命令直接失败；更糟的是若 `/tmp/h6plan` 是上一轮遗留的，会**静默提交一份过期的 PR 正文**。

Claude **不执行**这两步。交给用户在自己终端**一行一条**敲：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"
git push -u origin fix/acceptance-stale-literals
gh pr create --base main --head fix/acceptance-stale-literals --title "让 acceptance 闸门的失败细节在 CI 上可见（诊断先行，不修断言）" --body-file /tmp/h6plan/pr-body.md
```

---

- [ ] **Step 4: 读取 CI 的完整失败面（本 PR 的交付物）**

PR 开出后，`acceptance` **预期为红**。

> **为什么它必然真跑**（spec D4）：本 PR 修改了 `scripts/acceptance/hardening_6_framework.sh`，
> 而该路径**就在** `hardening_6_gate.yml` 的相关文件名单（9 条路径）之内
> ⇒ `relevant=true` ⇒ acceptance 脚本**必然真执行**，不会短路放行。
> 这也是本 PR **不需要依赖任何其它 PR 重跑**来取证的原因。

在其日志中确认并**记录**：

1. `plan_1f` 的逐条断言明细（`OK:` / `NG:` 行）出现；
2. 三个嵌套脚本各自的结论行出现（`PLAN 1 …` / `PLAN 1b …` / `PLAN 1c …`）；
3. **`plan_1f` 在 `ubuntu-latest` 上的完整失败项清单** —— 特别注意 `regression: Plan 1c` 那一条的真实报错（spec F19 预期是缺 Swift 工具链，但**不写成结论**）。

> ⚠️ **判绿纪律不适用于本 PR**：成功判据不是「检查变绿」，而是**「失败面变得可读」**。
> 若 `acceptance` 意外变绿，反而说明有别的东西不对，停下来排查。

---

## 验收清单（用户自己动手，不需要懂代码）

> 用法：照「动作」一行一条敲，把看到的和「期望看到」对一下打勾。
> 全部命令请先在这个目录下执行：
> `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"`

| # | 动作 | 期望看到 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 敲 `git status --short` | **一个字都不输出**（空白） | ☐ / ☐ |
| 2 | 敲 `git diff --name-only main...HEAD`（**三个点**） | **恰好 4 行**：两个 `scripts/acceptance/` 下的脚本 + 一个 specs 文件 + 一个 plans 文件 | ☐ / ☐ |
| 3 | 敲 `git diff --numstat origin/main -- scripts/acceptance/` | **恰好两行**，第一行以 `2	2` 开头，第二行以 `3	3` 开头 | ☐ / ☐ |
| 4 | 敲 `git diff origin/main -- scripts/acceptance/` 然后用眼睛看 | **恰好 5 行带减号、5 行带加号**；每一对都是同一句话，区别只有两处：`bash -c` 变成 `bash -o pipefail -c`，`> 文件 2>&1` 变成 `2>&1 \| tee 文件` | ☐ / ☐ |
| 5 | 敲 `grep -cF "PLAN 1f PASS' /tmp/p1f.log" scripts/acceptance/hardening_6_framework.sh` | 数字 **1**（一道防伪保护没被删掉） | ☐ / ☐ |
| 6 | 敲 `grep -cF "PLAN 1 PASS' /tmp/p1.log" scripts/acceptance/hardening_6_framework.sh` | 数字 **1**（另一道防伪保护也没被删掉） | ☐ / ☐ |
| 7 | 敲 `grep -cF '> /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 数字 **0**（旧写法已全部消失） | ☐ / ☐ |
| 8 | 敲 `grep -cF '2>&1 \| tee /tmp/p1' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 数字 **3**（新写法三处都在） | ☐ / ☐ |
| 9 | PR 开出来后，在 GitHub 页面看这个 PR 的检查列表 | 里面有一项叫 `acceptance`，它是**红的** —— ⚠️ **这是预期的，不是失败** | ☐ / ☐ |
| 10 | 点开 `acceptance` 的日志，往下翻 | 能看到**一条条**具体的检查结果（`OK:` / `NG:` 开头的行），而**不是**只有一行「Plan 1f 挂了」 | ☐ / ☐ |
| 11 | 在同一份日志里找 `PLAN 1c` / `PLAN 1b` 这两个词 | **都能找到** —— 说明嵌套在里面的脚本的结果也浮上来了 | ☐ / ☐ |

> ⚠️ **第 9 项为什么期望是「红的」**：这个 PR **只让失败看得见，不修复失败**。
> 真正的修复要等看清失败面之后另行设计。**这个 PR 在修复落地前不会合并。**
>
> ⚠️ **第 10、11 项才是这个 PR 真正的成果** —— 如果检查变绿了但看不到明细，反而说明出了别的问题。

---

## 遇到问题怎么办

| 症状 | 可能原因 | 怎么办 |
|---|---|---|
| 改写脚本输出 `ABORT: 锚点在 … 命中 0 次` | 已经跑过一次了 | 跑 `git diff origin/main -- scripts/acceptance/` 看是不是已经改好了。**不要手工改文件** |
| 改写脚本输出 `ABORT: … 命中 2 次` | 文件被别的改动污染了 | 停下来查 `git status`，**不要继续** |
| 主判据（Step 5）的 diff 多出行 | 越界改了别的地方 | 跑 `git diff --numstat origin/main -- scripts/acceptance/`，两行必须是 `2 2` 和 `3 3`；不是就逐行核对 |
| S7 或 S8 = 0 | **哨兵被删了** | 立刻恢复。它与 `-o pipefail` 防的不是同一件事，删了会开一个洞 |
| B6 或 B7 两行内容不一致 | **有断言由红变绿或由绿变红** | ⛔ 停下来。这意味着改动越界了，不是纯粹的日志改动 |
| `acceptance` 在 CI 上变绿了 | 不符合预期 | 停下来排查 —— 本 PR 不修断言，闸门不该变绿 |
