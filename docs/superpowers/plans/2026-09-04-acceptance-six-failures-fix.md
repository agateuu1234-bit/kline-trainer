# acceptance 六条失败的修复 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉 CI 实测出的 6 条失败，让必需检查 `acceptance` **真正转绿**，从而解锁 PR #182 与被它挡住的 PR #179。

**Architecture:** 三个 acceptance 脚本各改一处，对应三个性质完全不同的病灶 —— **E1** 删掉 `plan_1f` 里 6 条触发时机错误的矩阵断言；**E2** 把 `plan_1b` 的「正好 11 passed」改成「≥11 且零失败」；**E3** 给 `plan_1c` 的 `swift test` 加平台门（Apple 专有代码在 Linux 上结构性编译不过）。

**Tech Stack:** Bash；Python 3（仅用于执行改写脚本）；`git`；`grep`（⚠️ 本机是 ugrep，判据一律 `-F`）。

**Spec:** `docs/superpowers/specs/2026-09-04-acceptance-six-failures-fix-design.md`
（上游 spec：`2026-08-31-acceptance-stale-literals-design.md`，其 D5 委托本 spec）

---

## Global Constraints

1. **唯一可改的三个文件**：`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`、`plan_1b_m0_2_rest_api.sh`、`plan_1c_m0_3_swift_contracts.sh`。**不得**新建或修改任何其它文件（本计划自身除外）。
2. **⛔ 除这三处外不得触碰任何断言** —— 不改别的期望值、不删别的 `run` 行、不动任何 `run()` 函数。范围由 **E-S6 范围锁**兜住。
3. **⛔ 不 rebase 本分支**（spec E6）。`main` 已至 `db49f60`，但未触碰这三个文件。
4. **⚠️ 所有「本分支改了什么」的判据一律钉 merge-base**：`git diff … $(git merge-base HEAD origin/main)`。**禁用 `origin/main` 作基准** —— `main` 会继续前进，用它会把 main 自己的改动算进来（实测 #183 改了 `plan_b2`，会凭空多一行）。
5. **⚠️ 本机 `grep` 是 ugrep 7.8.4**，所有计数判据一律 **`grep -cF`**（定长串）。
6. **判绿纪律**：读**输出内容**判定。`grep -c` 计数为 0 时退出码是 1，**验收命令一行一条单独敲**，不要串进带 `set -e` 的脚本。
7. **⚠️ 本机跑 `plan_1f` 必须先装 CI 等价依赖**（`pyyaml` / `pglast` / `openapi-spec-validator` / `pytest`），否则三条 `regression:` 会因缺包而红，**与本次修复无关**（spec G16）。
8. **⚠️⚠️ 判断 `swift test` 失败前必须先清 `.build`** —— 陈旧或跨路径拷贝的增量构建会造出与代码**完全无关**的 `emit-module command failed`。本计划的 dry-run 就踩过一次（见下方证据表）。
9. **提交信息 / PR 正文语言**：中文。
10. **push 由用户在自己的终端执行**，Claude 不执行。

---

## File Structure

| 文件 | 动作 | 改什么 |
|---|---|---|
| `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 修改 | **删**「CONTRACT_VERSION 矩阵 6 行协同断言」整块（含注释） |
| `scripts/acceptance/plan_1b_m0_2_rest_api.sh` | 修改 | **改** 1 条 pytest 断言的判据 |
| `scripts/acceptance/plan_1c_m0_3_swift_contracts.sh` | 修改 | **包** `swift test` 那条进平台门 |

**不创建任何新文件**（改写脚本放 `/tmp`，不进仓库）。

---

## 全流程 dry-run 证据（写计划前已完成）

在 worktree 的完整副本上端到端跑过（副本用完即弃，真分支零污染）：

| 项 | 实测结果 |
|---|---|
| 改写脚本执行 | `OK: 三处全部改完（E1 删 6 条断言 / E2 改判据 / E3 加平台门）` |
| 三个脚本 `bash -n` | **全部通过** |
| 结构判据 E-S1..E-S5 | `0 / 0 / 1 / 2 / 2` —— 与 spec 期望**全部一致** |
| **幂等性**（重复执行） | **正确中止不写盘**：`ABORT: E1 区块锚点未命中（注释块起止）` |
| **⭐ 修复效果**（清 `.build` + CI 等价依赖） | **`Plan 1f … : 25 passed, 0 failed` / `PLAN 1f PASS` / 退出码 0** |
| `plan_1c`（macOS，走执行分支） | **`12 passed, 0 failed` / `PLAN 1c PASS`** |
| `swift test` 双摘要 | `Executed 302 tests, 0 failures`（XCTest）+ `Test run with 1960 tests in 229 suites passed`（Swift Testing）⇒ **真实执行量 ≈ 2262 条，不是 302** |

> ⚠️ **首次 dry-run 曾误判为「E3 没用」**：副本 `cp -R` 时把 **1.0 GB 的 `.build`** 一起拷了过来，
> 里面烤死的绝对路径导致 `emit-module command failed`。**清掉 `.build` 后立刻转绿。**
> ⇒ 这就是 Global Constraint 8 的由来：**环境的伤会被读成代码的伤。**

---

### Task 1: 三处修复

**Files:**
- Modify: `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（删 6 条矩阵断言块）
- Modify: `scripts/acceptance/plan_1b_m0_2_rest_api.sh`（改 pytest 判据）
- Modify: `scripts/acceptance/plan_1c_m0_3_swift_contracts.sh`（加平台门）

**Interfaces:**
- Consumes: 无
- Produces: 三个改好的脚本。Task 2 是纯验证，不依赖其内部结构。

---

- [ ] **Step 1: 确认起点**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"
pwd
git rev-parse --abbrev-ref HEAD
git rev-parse --short HEAD
git status --short
```

**期望**：分支 `fix/acceptance-stale-literals`、`git status --short` **零输出**。

---

- [ ] **Step 2: 负向对照 —— 确认五条结构判据在改动前是「旧形态」**

一行一条敲：

```bash
grep -cF 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'ge 11' scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
grep -cF 'swift test: exit 0' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
```

**期望依次为：`6` `1` `0` `0` `1`**（**已在本 worktree 实跑确认**）。

> ⚠️ 若某条在改动**之前**就已是「改动后」的值，说明该判据对本次改动零判别力，停下来查。

---

- [ ] **Step 3: 生成改写脚本**

```bash
mkdir -p /tmp/h6plan
cat > /tmp/h6plan/apply_fix.py <<'SCRIPT'
#!/usr/bin/env python3
"""acceptance 六条失败的修复：三处改动。每处锚点必须恰好命中 1 次，否则整体中止不写盘。"""
import io, sys

P1F = "scripts/acceptance/plan_1f_m0_1_schema_versioning.sh"
P1B = "scripts/acceptance/plan_1b_m0_2_rest_api.sh"
P1C = "scripts/acceptance/plan_1c_m0_3_swift_contracts.sh"

bufs = {f: io.open(f, encoding="utf-8").read() for f in (P1F, P1B, P1C)}


def fail(msg):
    sys.exit("ABORT: " + msg)


# ---------- E1：删掉 plan_1f 的 6 条 matrix row 断言（含其上方注释块） ----------
s = bufs[P1F]
start_marker = "# ---- CONTRACT_VERSION 矩阵 6 行协同断言"
end_marker = "# ---- Bump 策略 A/B 二分"
i = s.find(start_marker)
j = s.find(end_marker)
if i < 0 or j < 0 or j <= i:
    fail("E1 区块锚点未命中（注释块起止）")
removed = s[i:j]
if removed.count('run "matrix row:') != 6:
    fail("E1 待删区块内 matrix row 断言数 = %d（必须恰好 6）" % removed.count('run "matrix row:'))
bufs[P1F] = s[:i] + s[j:]

# ---------- E2：plan_1b 的「正好 11 passed」→「≥11 且零失败」 ----------
s = bufs[P1B]
old_b = '''# 必须确切 11 passed；若将来 test 数变化说明 spec drift，label 必须同步更新
run "pytest: 11 OpenAPI invariants" \\
    bash -c "cd backend && python3 -m pytest tests/test_openapi.py -q | tee /tmp/plan1b-pytest.out && grep -q '^11 passed' /tmp/plan1b-pytest.out"'''
if s.count(old_b) != 1:
    fail("E2 锚点命中 %d 次（必须恰好 1）" % s.count(old_b))
new_b = '''# 下限断言（≥11）而非等值：新增不变量测试是健康行为，不是 drift；
# 真正危险的是有人【删掉】不变量测试，「≥下限」恰好只抓后者。
# 不用管道：run 把命令交给全新的 bash -c，它不继承外层 set -o pipefail，
# 管道会让退出码取自 tee（恒 0），吞掉 pytest 自己的失败。
run "pytest: OpenAPI invariants (>=11, 0 failed)" \\
    bash -c "cd backend && python3 -m pytest tests/test_openapi.py -q > /tmp/plan1b-pytest.out 2>&1; ec=\\$?; cat /tmp/plan1b-pytest.out; [ \\$ec -eq 0 ] && [ \\"\\$(sed -n 's/^\\\\([0-9]\\\\{1,\\\\}\\\\) passed.*/\\\\1/p' /tmp/plan1b-pytest.out)\\" -ge 11 ]"'''
bufs[P1B] = s.replace(old_b, new_b)

# ---------- E3：plan_1c 的 swift test 加平台门 ----------
s = bufs[P1C]
old_c = '''run "swift test: exit 0" \\
    bash -c 'cd ios/Contracts && swift test\''''
if s.count(old_c) != 1:
    fail("E3 锚点命中 %d 次（必须恰好 1）" % s.count(old_c))
new_c = '''# swift test 依赖 Apple 平台专有框架（CoreGraphics / UIKit / SwiftUI / QuartzCore）。
# 实测 28 个源文件裸 import CoreGraphics（另 10 个在 #if 块内）
# ⇒ 在非 Darwin 平台上【结构上】无法编译，不是可修的失败。
# 该覆盖在 CI 上由 .github/workflows/swift-contracts-smoke.yml（runs-on: macos-15）承担。
if [[ "$(uname -s)" == "Darwin" ]]; then
    run "swift test: exit 0" \\
        bash -c 'cd ios/Contracts && swift test'
else
    echo ""
    echo "========== swift test: exit 0 =========="
    echo "SKIP: 非 Darwin 平台（$(uname -s)）。本 package 依赖 Apple 专有框架"
    echo "      （28 个源文件裸 import CoreGraphics），结构上无法在此编译。"
    echo "      该覆盖由 .github/workflows/swift-contracts-smoke.yml（macos-15）承担。"
fi'''
bufs[P1C] = s.replace(old_c, new_c)

for f, text in bufs.items():
    io.open(f, "w", encoding="utf-8").write(text)
print("OK: 三处全部改完（E1 删 6 条断言 / E2 改判据 / E3 加平台门）")
SCRIPT
```

**该脚本的三条安全性质（已 dry-run 验证）：**
1. **全有或全无** —— 任一锚点未命中或数量不对就 `sys.exit` 中止，**在写盘之前**；
2. **E1 额外自校验** —— 待删区块内必须**恰好 6 条** `run "matrix row:`，多一条少一条都中止（防区块边界漂移）；
3. **幂等安全** —— 重复执行会因区块已消失而中止。

---

- [ ] **Step 4: 执行改写**

```bash
python3 /tmp/h6plan/apply_fix.py
```

**期望输出，一字不差**：`OK: 三处全部改完（E1 删 6 条断言 / E2 改判据 / E3 加平台门）`

> 若输出以 `ABORT:` 开头，**不要手工去改文件**。停下来核对当前树是否干净、是否已跑过一次。

---

- [ ] **Step 5: 语法检查（三个脚本都必须通过）**

```bash
bash -n scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
bash -n scripts/acceptance/plan_1b_m0_2_rest_api.sh
bash -n scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
```

**期望**：三条命令**都零输出**（`bash -n` 只在语法错时说话）。

> E2 与 E3 都引入了新的 shell 结构（`$(...)`、`[[ ]]`、多层引号转义），这一步不可省。

---

- [ ] **Step 6: 结构判据（改动后）**

一行一条敲：

```bash
grep -cF 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -cF "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'ge 11' scripts/acceptance/plan_1b_m0_2_rest_api.sh
grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
grep -cF 'swift test: exit 0' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
git diff --numstat $(git merge-base HEAD origin/main) -- scripts/acceptance/
```

| # | 期望 | 它锁住什么 |
|---|---|---|
| E-S1 | **0** | 6 条矩阵断言已全删 |
| E-S2 | **0** | 旧判据已消失 |
| E-S3 | **1** | 新判据已到位 |
| E-S4 | **2** | 平台门到位（`if` 条件一行 + SKIP 文案一行）—— ⚠️ **是 2 不是 1** |
| E-S5 | **2** | `run` 标题 + `else` 分支打印的标题 |
| E-S6 | **恰好四行**：`hardening_6_framework.sh`、`plan_1b…`、`plan_1c…`、`plan_1f…` | **范围锁** —— 越界改任何别的行/文件都会让它多出来 |

> ⚠️ **E-S6 必须钉 merge-base**。用 `origin/main` 会把 main 自己的改动算进来（实测会多出 `plan_b2_generate_training_sets.sh`），
> 让实施者误判「范围超了」进而去"清理"一个自己根本没碰的文件 —— **那才是真事故**。
>
> `hardening_6_framework.sh` 那一行是**上一轮诊断改动**留下的，属预期内。

---

- [ ] **Step 7: 行为判据 —— 确认修复真的生效**

⚠️ **两个前置条件缺一不可**（否则结果无效）：

```bash
# 前置 1：装 CI 等价依赖（否则三条 regression 会因缺包而红，与本次修复无关）
python3 -m venv /tmp/h6plan/venv
/tmp/h6plan/venv/bin/pip install -q --upgrade pip
/tmp/h6plan/venv/bin/pip install -q -r requirements-dev.txt -r backend/requirements-dev.txt

# 前置 2：清掉可能陈旧的 swift 构建缓存（见 Global Constraint 8）
rm -rf ios/Contracts/.build
```

然后跑（含 swift 冷构建，需几分钟）：

```bash
PATH="/tmp/h6plan/venv/bin:$PATH" bash scripts/acceptance/plan_1f_m0_1_schema_versioning.sh > /tmp/h6plan/fix-after.log 2>&1
echo "exit=$?"
grep -E '^Plan 1f .* acceptance:' /tmp/h6plan/fix-after.log
grep -E '^PLAN 1f (PASS|FAIL)$' /tmp/h6plan/fix-after.log
grep -E 'Plan 1c .* acceptance:' /tmp/p1c.log
grep -E 'Executed [0-9]+ tests|Test run with [0-9]+ tests' /tmp/p1c.log
```

| # | 判据 | 期望 |
|---|---|---|
| E-B1 | 退出码 | **0** |
| E-B2 | `plan_1f` 汇总 | **`25 passed, 0 failed`** |
| E-B3 | `plan_1f` 结论行 | **`PLAN 1f PASS`** |
| E-B4 | `plan_1c` 汇总 | **`12 passed, 0 failed`** |
| E-B5 | `swift test` 摘要 | **两条都要出现**：`Executed 302 tests, 0 failures`（XCTest）+ `Test run with 1960 tests in 229 suites passed`（Swift Testing） |

> ⚠️ **E-B5 为什么要读两条**：`ios/Contracts` 是**双测试框架**包，`swift test` 打印**两条**摘要行。
> 只读其中一条会严重低估执行量（302 vs 真实约 2262），本 spec 上一轮评审就栽在这里。
>
> ⚠️ **E-B4 是平台门在 Darwin 侧的判别力检查**：本机必须走**执行分支**（`12 passed` 含 `swift test` 那条），
> 而不是 SKIP。只验「Linux 上跳过了」不够 —— 一个**恒真跳过**的门会伪装成工作正常。

---

- [ ] **Step 8: 提交**

```bash
git add scripts/acceptance/plan_1f_m0_1_schema_versioning.sh scripts/acceptance/plan_1b_m0_2_rest_api.sh scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
git commit -m "fix(ci): 修掉 acceptance 的六条失败（三个病灶三种修法）

上一轮诊断改动让 CI 打出了完整失败面：plan_1f 在 ubuntu 上 25 passed,
6 failed。逐层读出后确认这 6 条对应三个性质完全不同的病灶。

E1 删掉 plan_1f 的 6 条矩阵断言（不是把 4 个值改对）
  它们只在那 9 个治理文件改动时执行，而 m01 文档不在其中 ⇒ 永远不会在
  矩阵真变时运行 ⇒ 改对值只是把跑步机推一格。其中 3 条已被
  M01MatrixSyncGuardTests 覆盖（触发正确、当前绿、自带防空转）。
  连那 2 条「还通过」的也删：#183 已把训练组 user_version 从 1 改成 2，
  而 m01 矩阵仍写 1 —— 那条断言此刻正【绿灯锁死错值】。坑不是未来会踩，
  是已经踩了，而且烂在绿的那一侧（比红着更危险，没人会去看）。

E2 plan_1b 的「正好 11 passed」改「≥11 且零失败」
  新增不变量测试是健康行为不是 drift（11→19 正是这样发生的），危险的是
  删测试，「≥下限」只抓后者。判别力已实测 8 档：19 passed→PASS、
  10 passed→FAIL（抓住删测试）、1 failed→FAIL、collection error→FAIL、
  19 passed 但 exit 1→FAIL（证明先判退出码的短路有效）。
  顺带关闭上游残留 R10：去掉管道（bash -c 不继承外层 pipefail，
  管道会让退出码取自 tee 恒 0，吞掉 pytest 的失败）。

E3 plan_1c 的 swift test 加平台门（不是删除）
  真实失败是 no such module 'CoreGraphics' —— 不是缺 Swift 工具链
  （ubuntu-latest 自带，实测真跑起来了），是代码依赖 Apple 专有框架：
  28 个源文件裸 import CoreGraphics。让它在 Linux 编译通过从来不是设计
  意图。不直接删是因为该断言在 macOS 上有效，删了会削弱 macOS 侧。
  该 skip 大声打印、判据是 uname 无模糊地带、覆盖由 swift-contracts-smoke
  （macos-15）承担。

实测（清 .build + CI 等价依赖后）：
  plan_1f: 25 passed, 0 failed / PLAN 1f PASS / 退出码 0
  plan_1c: 12 passed, 0 failed（macOS 走执行分支，非 SKIP）
  swift test 双摘要: Executed 302 tests + Test run with 1960 tests
                     ⇒ 真实执行量约 2262 条，不是 302

⚠️ 未做：swift test on macos-15 仍不是必需检查。它带 paths 过滤器，
直接设必需极可能复现 #179 的死锁（main 的 #180 正是为同类问题而做）。
需先设计且需用户授权，记为 R-E1。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BvzrZhLtJNBrVbVbyNdDjz"
```

---

### Task 2: 交付前整体核验

**Files:** 无改动（纯核验）

---

- [ ] **Step 1: 工作区与范围**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"
git status --short
git diff --name-only $(git merge-base HEAD origin/main)
```

**期望**：`git status --short` **零输出**；文件清单**恰好这 8 行**（⚠️ **逐行核对，不要只数行数**）：

```
docs/superpowers/plans/2026-09-03-acceptance-log-streaming.md
docs/superpowers/plans/2026-09-04-acceptance-six-failures-fix.md
docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md
docs/superpowers/specs/2026-09-04-acceptance-six-failures-fix-design.md
scripts/acceptance/hardening_6_framework.sh
scripts/acceptance/plan_1b_m0_2_rest_api.sh
scripts/acceptance/plan_1c_m0_3_swift_contracts.sh
scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
```

其中 `hardening_6_framework.sh` 与 `plan_1f`（部分）来自**上一轮诊断改动**，属预期内。

---

- [ ] **Step 2: 更新 PR 正文**

⚠️ **PR #182 的正文写的是「诊断阶段」的状态**（含「本 PR 不会让 acceptance 变绿，这是有意的」）。
修复落地后该表述**已过时**，必须更新，否则 PR 正文与实际状态自相矛盾。

```bash
cat > /tmp/h6plan/pr-body.md <<'BODY'
## 这个 PR 做了两件事

**第一步（已完成）：让失败可观测。** 把 acceptance 闸门里 5 处被重定向吞掉的日志改成运行时流式输出（`2>&1 | tee` + `-o pipefail`）。在此之前 CI 日志里关于它只有一行 `NG: regression: Plan 1f schema versioning`，看不出 31 条断言里挂了哪一条。

**第二步（本次）：按拿到的完整失败面修掉它。** 诊断改动买来的清单是 `plan_1f: 25 passed, 6 failed`，逐层读出后确认这 6 条对应**三个性质完全不同**的病灶。

## 三个病灶，三种修法

| | 问题 | 修法 | 为什么不用更省事的办法 |
|---|---|---|---|
| **E1** | `plan_1f` 4 条矩阵断言值过期 | **删掉这 6 条** | 它们只在那 9 个治理文件改动时执行，而 m01 文档**不在其中** ⇒ 永远不会在矩阵真变时运行 ⇒ 改对值只是把跑步机推一格 |
| **E2** | `plan_1b` 要求「正好 11 passed」而实际 19 | 改「**≥11 且零失败**」 | 新增不变量测试是健康行为不是 drift；危险的是**删**测试，「≥下限」只抓后者 |
| **E3** | `swift test` 在 ubuntu 上编译不过 | 加**平台门** | 真实失败是 `no such module 'CoreGraphics'` —— 不是缺工具链（ubuntu 自带 Swift，实测真跑起来了），是代码依赖 Apple 专有框架 |

**E1 为什么连那 2 条「还通过」的也删**：#183 已把训练组 `user_version` 从 `1` 改成 `2`，而 m01 矩阵仍写 `1` —— 那条断言此刻正**绿灯锁死一个错值**。坑不是未来会踩，是**已经踩了**，而且烂在**绿的那一侧**（比红着更危险，因为没人会去看）。

## 验证状态（全部实测）

| 判据 | 期望 | 实测 |
|---|---|---|
| 结构判据 E-S1..E-S5 | `0 / 0 / 1 / 2 / 2` | ✅ 全部对上 |
| 负向对照（改动前） | `6 / 1 / 0 / 0 / 1` | ✅ 全部对上 |
| 三个脚本 `bash -n` | 零输出 | ✅ |
| **`plan_1f` 修复后** | `PLAN 1f PASS` | ✅ **`25 passed, 0 failed`，退出码 0** |
| **`plan_1c`（macOS 走执行分支）** | 非 SKIP | ✅ **`12 passed, 0 failed`** |
| `swift test` 双摘要 | 两条都读 | ✅ `Executed 302 tests` + `Test run with 1960 tests in 229 suites` |
| 改写脚本幂等性 | 重复执行应中止 | ✅ `ABORT:` 且不写盘 |

> ⚠️ 首次 dry-run 曾误判为「E3 没用」—— 副本 `cp -R` 时把 **1.0 GB 的 `.build`** 一起拷了过来，烤死的绝对路径造出 `emit-module command failed`。**清掉后立刻转绿。** 环境的伤会被读成代码的伤。

## 已知但本次不修

| # | 内容 |
|---|---|
| R-E1 | **`swift test on macos-15` 不是必需检查**。⚠️ 直接设为必需**极可能复现 #179 的死锁**（它带 `paths` 过滤器；main 的 #180 正是为同类问题而做）。需先设计且需授权 |
| R-E2 | m01 矩阵训练组行 doc=`1` / code=`2`（源自 #183）需订正；该行规则写明「联动顶层」而顶层仍 `"1.13"`，**是否联动 bump 待裁定** |
| R-E3 | `plan_e2_position_manager.sh` 仍带 2 条同族红断言，其中一条用绿灯锁死 `kline_trainer_modules_v1.4.md` 的错值 |
| R-E4 | `kline_trainer_modules_v1.4.md` 矩阵落后 8 版，与 m01 分叉 |
| R-E8 | `plan_1d` 等 5 处也裸跑 `swift test`（**不在** acceptance 路径上，不影响本次转绿） |
| R-E9 | E2 的新判据**不守局部 skip**（`12 passed, 7 skipped` 会判 PASS） |

## 评审

- 诊断阶段 spec：**5 轮**对抗性评审
- 修复阶段 spec：**1 轮**（1 high + 7 medium + 4 low，全部复核成立并已修）

⚠️ **本线至今没有任何 codex attest 账本条目**：codex 配额于 2026-09-02 耗尽（恢复 09-07 13:31），后续走 Opus 子代理通道，**该通道不写账本**。这一点不含糊。

- 诊断 spec：`docs/superpowers/specs/2026-08-31-acceptance-stale-literals-design.md`
- 修复 spec：`docs/superpowers/specs/2026-09-04-acceptance-six-failures-fix-design.md`
- 两份实施计划见 `docs/superpowers/plans/`
BODY

[ -s /tmp/h6plan/pr-body.md ] && echo "OK 非空，$(wc -l < /tmp/h6plan/pr-body.md) 行" || echo "FAIL 为空或不存在"
```

---

- [ ] **Step 3: 交给用户 push 与更新 PR**

> ⚠️ 本步依赖 Step 2 已生成 `/tmp/h6plan/pr-body.md`，顺序不可颠倒。

Claude **不执行**这两步。交给用户在自己终端**一行一条**敲：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"
git push
gh pr edit 182 --body-file /tmp/h6plan/pr-body.md
```

---

- [ ] **Step 4: 读 CI 结果（本次的最终判据）**

| # | 判据 | 期望 |
|---|---|---|
| E-C1 | **`acceptance` 检查** | **绿** —— 这是本次修复成立的**唯一最终判据** |
| E-C2 | 日志里 `swift test: exit 0` 那段 | 出现 **`SKIP: 非 Darwin 平台（Linux）`** —— 证明平台门在 Linux 上走跳过分支 |
| E-C3 | `plan_1f` 汇总行 | `N passed, **0** failed` |
| E-C4 | 最外层 `Hardening-6 framework acceptance:` | `N passed, **0** failed` |

> ⚠️ **E-C2 与 Task 1 Step 7 的 E-B4 是一对**：本机验「Darwin 走执行分支」，CI 验「Linux 走跳过分支」。
> **两侧都验才排除得掉「恒真跳过」的伪装。**
>
> ⚠️ **本 PR 的成功判据在此从上一阶段切换**：诊断阶段是「失败面变得可读」，**本阶段是 `acceptance` 真的变绿**。
> 绿了即可合并，并解锁被它挡住的 **PR #179**。

---

## 验收清单（用户自己动手，不需要懂代码）

> 用法：照「动作」一行一条敲，把看到的和「期望看到」对一下打勾。
> 先进目录：`cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-acceptance-stale-literals"`

| # | 动作 | 期望看到 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 敲 `git status --short` | **一个字都不输出** | ☐ / ☐ |
| 2 | 敲 `grep -cF 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` | 数字 **0**（6 条过期断言已删干净） | ☐ / ☐ |
| 3 | 敲 `grep -cF 'ge 11' scripts/acceptance/plan_1b_m0_2_rest_api.sh` | 数字 **1**（新的「至少 11 个」判据到位） | ☐ / ☐ |
| 4 | 敲 `grep -cF 'uname -s' scripts/acceptance/plan_1c_m0_3_swift_contracts.sh` | 数字 **2**（平台门到位；**是 2 不是 1**） | ☐ / ☐ |
| 5 | 敲 `bash -n scripts/acceptance/plan_1c_m0_3_swift_contracts.sh` | **一个字都不输出**（这个命令只在语法写错时说话） | ☐ / ☐ |
| 6 | 敲 `git diff --name-only $(git merge-base HEAD origin/main)` 然后数一数 | **8 行**：4 个 `scripts/acceptance/` 下的脚本 + 2 个 specs + 2 个 plans。**不该有别的** | ☐ / ☐ |
| 7 | PR 页面上看检查列表里的 **`acceptance`** | **绿的对勾** ⭐ 这是这次唯一真正重要的一项 | ☐ / ☐ |
| 8 | 点开 `acceptance` 日志，搜 `PLAN 1f` | 看到 **`PLAN 1f PASS`** | ☐ / ☐ |
| 9 | 同一份日志里搜 `SKIP: 非 Darwin` | **能找到** —— 说明那条「苹果专属测试」在 Linux 上被正确跳过了，并且**大声说明了原因** | ☐ / ☐ |
| 10 | 同一份日志里搜 `Hardening-6 framework acceptance:` | 那一行的 failed 数是 **0** | ☐ / ☐ |

> ⚠️ **第 7 项与上一个阶段相反**：上次期望它是**红的**（那次只让失败可见、不修复）。
> **这次期望它是绿的** —— 绿了才算修复成功，也才能合并。
>
> ⚠️ **第 9 项为什么重要**：它证明跳过是**大声的、有原因的**，不是静默丢覆盖。
> 若找不到这句，说明平台门没生效，停下来查。

---

## 遇到问题怎么办

| 症状 | 可能原因 | 怎么办 |
|---|---|---|
| 改写脚本输出 `ABORT: E1 区块锚点未命中` | 已经跑过一次了 | 跑 `grep -cF 'matrix row:' …plan_1f…` 看是不是已经是 0。**不要手工改文件** |
| 改写脚本输出 `ABORT: E1 待删区块内 matrix row 断言数 = N` | 区块边界漂移了（有人改过 plan_1f） | 停下来人工核对区块起止注释，**不要改脚本里的数字来"绕过"** |
| `bash -n` 报语法错 | 引号转义出问题 | 用 `git checkout -- <文件>` 恢复后重跑改写脚本。⛔ **不要手工补引号** |
| E-S4 得到 1 而不是 2 | 有人删了 SKIP 文案里的 `$(uname -s)` | 恢复它 —— 那是跳过分支唯一一处「告诉你当前平台」的信息 |
| E-S6 多出行 | 越界改了别的地方 | 逐行看 `git diff $(git merge-base HEAD origin/main) -- scripts/acceptance/` |
| **`swift test` 报 `emit-module command failed`** | **大概率是陈旧/跨路径的 `.build`** | ⭐ **先 `rm -rf ios/Contracts/.build` 再重跑**，然后才判断是不是真失败 |
| `plan_1f` 本机跑仍有 3 条 regression 红 | **本机缺 pyyaml/pglast**，与本次修复无关 | 按 Task 1 Step 7 的前置 1 装 venv 后重跑 |
| CI 上 `acceptance` 仍红 | 可能有第四类问题 | **读日志里的逐条明细**（诊断改动已让它可见），按真实失败项重新设计，⛔ 不要猜 |
