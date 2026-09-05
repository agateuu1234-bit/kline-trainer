# hardening-6 闸门 · 叠罗汉 PR 永久死锁修复 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让叠罗汉 PR（stacked PR）能够拿到必需检查 `acceptance`，消除「required 但永不上报 ⇒ 永久 BLOCKED」的死锁。

**Architecture:** 只改 `.github/workflows/hardening_6_gate.yml` 的触发条件与一条冗余命令。删掉 `pull_request.branches: [main]`（让闸门在所有 PR 上运行、一开 PR 就上报），并显式订阅 `edited` 活动类型（让 GitHub 自动 retarget 那一刻针对新 base 强制重跑一次）；同时删掉一条会把完整克隆重新浅化、可导致 `git diff` 报 `no merge base` 的冗余 `git fetch`。**不新增任何测试文件、不新增守卫脚本** —— 验证靠 actionlint + 结构断言 + 本 PR 自证。

**Tech Stack:** GitHub Actions workflow YAML；`actionlint` 1.7.12（本机已装）；`git`；`grep` / `awk`。

**Spec:** `docs/superpowers/specs/2026-08-25-h6-gate-stacked-pr-deadlock-design.md`
（codex `adversarial-review` **R2 真 approve**，账本条目 `branch:fix/h6-gate-stacked-pr@718d54ed…`，`kind=branch` 无窄化）

---

## Global Constraints

以下为全局约束，**每个 Task 都隐含包含**：

1. **唯一可改文件**：`.github/workflows/hardening_6_gate.yml`。本计划**不得**新建或修改任何其它文件（spec 与本计划自身除外）。
2. **⛔ 不得 rebase 本分支**。spec 已在 `718d54e` 拿到 codex approve，账本记录的 `head_sha` 与该提交绑定；rebase 会改写提交号使 approve 失效。
3. **明确不改**（spec §7）：
   - 不改 `git diff --name-only origin/main...HEAD` 的比对基准（D4）；
   - 不改 `actions/checkout@v4` 的浮动标签（D5，已记为独立 backlog）；
   - 不改 `Detect relevant changes` 里第 50 行那张相关文件名单；
   - 不改 `scripts/acceptance/hardening_6_framework.sh`；
   - 不改 ruleset（必需检查 context 名 `acceptance` 来自 job 名，本次不动 job）；
   - 不改任何其它 workflow；
   - 不增加 `ready_for_review` 活动类型；
   - 不改 `strict_required_status_checks_policy`。
4. **注释语言**：该 workflow 文件头注释现状为**全英文**，按 `CLAUDE.md` §3「Match existing style」，新增注释**必须用英文**。
5. **提交信息 / PR 正文语言**：**中文**。
6. **⛔ 诚实性硬约束（spec D6 / §5.3）**：叠罗汉路径本 PR **无法自证**（本 PR 自己的 base 就是 `main`）。提交信息、PR 正文、任何汇报中，对「叠罗汉 PR 现在能拿到 acceptance」一律写「**未实证 · 待下一个叠罗汉 PR 验证**」，**不得写成已验证**。
7. **判绿纪律**：所有闸门一律**读输出内容**判定，不靠管道后的 `$?`（`cmd | tail` 之后的 `$?` 是尾部命令的退出码）。断言脚本中**不使用 `set -e`**（`grep -c` 命中 0 次时退出码为 1，会误杀整个脚本）。
8. **push 与开 PR 由用户在自己的终端执行**，Claude 不执行这两步。
9. **⛔ 所有「本分支改了什么」的比对一律用三点式 `main...HEAD`（从共同祖先算起），禁用两点式 `main..HEAD`。**
   原因：`main` 在本工作进行期间**已经前进过**（建分支时 `a018a7f` → 现在 `1437529`，多了 4 个提交）。
   两点式比的是两个分支的顶端，会把 `main` 独有的改动一并算成「本分支的改动」——
   实测此刻两点式返回 **26 个路径**，三点式返回正确的 **2 个**。
   （`git rev-list --count main..HEAD` 是例外：它统计「在 HEAD 不在 main 的提交」，本就是正确语义。）

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `.github/workflows/hardening_6_gate.yml` | **修改**（唯一） | 触发条件（`on:` 块）+ 「Detect relevant changes」步骤内一条冗余命令 |
| `docs/superpowers/specs/2026-08-25-h6-gate-stacked-pr-deadlock-design.md` | 已存在，不改 | 设计依据 |
| `docs/superpowers/plans/2026-08-30-h6-gate-stacked-pr-deadlock.md` | 本文件 | 实施计划 |

**不创建任何新文件。** 特别是：**不新增守卫脚本、不新增测试文件**。理由：spec §7 与 R3 已明确「后续保护由『任何改动本文件的 PR 都会 `relevant=true` 从而真跑一遍』这一自证机制兜底」，新增守卫属超范围（`CLAUDE.md` §2 最少代码 / §3 外科式改动）。

---

## 共用断言脚本（两个 Task 都用它）

**每个 Task 的「跑一遍看它失败」与「跑一遍看它通过」用的是同一个脚本**，只是期望值不同。

先在暂存目录创建它（**不放进仓库**）：

```bash
mkdir -p /tmp/h6plan
cat > /tmp/h6plan/assert.sh <<'SCRIPT'
#!/bin/bash
# 不使用 set -e：grep -c 命中 0 次时退出码为 1，会误杀脚本
F=.github/workflows/hardening_6_gate.yml
chk() { if [ "$2" = "$3" ]; then echo "PASS $1  (实际=$2)"; else echo "FAIL $1  (实际=$2 期望=$3)"; fi; }
chkmin() { if [ "$2" -ge "$3" ] 2>/dev/null; then echo "PASS $1  (实际=$2 期望≥$3)"; else echo "FAIL $1  (实际=$2 期望≥$3)"; fi; }

chk    G1 "$(grep -c '^    branches: \[main\]$' "$F" || true)" 0
chk    G2 "$(grep -c '^    types: \[opened, synchronize, reopened, edited\]$' "$F" || true)" 1
chk    G3 "$(grep -c 'git fetch origin main --depth=50' "$F" || true)" 0
chk    G4 "$(grep -c 'git diff --name-only origin/main\.\.\.HEAD' "$F" || true)" 1
chk    G6 "$(grep -c 'DO NOT drop either line' "$F" || true)" 1
chkmin G8 "$(grep -cE '^# .*edited' "$F" || true)" 1

OUT=$(actionlint "$F" 2>&1); RC=$?
chk G5rc "$RC" 0
chk G5out "$(printf '%s' "$OUT" | wc -c | tr -d ' ')" 0
[ "$RC" != "0" ] && echo "---- actionlint 输出 ----" && echo "$OUT"

DEL=$(git diff --numstat "$(git merge-base main HEAD)" -- "$F" | awk '{print $2}')
chk G7 "${DEL:-无改动}" 2
SCRIPT
chmod +x /tmp/h6plan/assert.sh
```

**九条断言各自证明什么：**

| ID | 断言 | 它防的是什么 |
|---|---|---|
| G1 | `branches: [main]` 出现 **0** 次 | 死锁条件 (a) 已拆除 |
| G2 | `types: [opened, synchronize, reopened, edited]` 出现 **1** 次 | 死锁条件 (b) 已拆除，且四个类型一字不差 |
| G3 | `git fetch origin main --depth=50` 出现 **0** 次 | 浅化那条已删 |
| G4 | `git diff --name-only origin/main...HEAD` 仍出现 **1** 次 | **删 fetch 时没有误伤紧挨着的 diff 那行** |
| G5 | actionlint 退出码 0 **且**输出零字节 | YAML 与 workflow schema 合法（已实测：塞入非法活动类型会退出 1 并精确报错，此闸门有真判别力） |
| G6 | 注释里含**精确整句** `DO NOT drop either line` | D3 要求：防止后人把 `types` 当成多余样板删掉。用整句而非计数，措辞微调不会误伤 |
| G8 | 注释行里提到 `edited` 的**至少 1 行** | `edited` 的存在理由被写进了注释（实测终态为 3 行，故用「≥1」而非等值，避免脆） |
| G7 | 该文件相对**共同祖先**的删除行数恰好 2 | 只删了预期的两行，没顺手删别的（实测 numstat = `9	2`：新增 9、删除 2）。<br>**写法有两处讲究，缺一不可**：<br>① 基准必须是**共同祖先**（`git merge-base main HEAD`），不能用两点式 `main..HEAD` —— 后者比的是两个分支顶端，`main` 一旦前进就会把 main 独有的改动一起算进来（实测两点式返回 26 路径、三点式返回 2）；<br>② 比较对象必须是**工作区**（`git diff <祖先> -- 文件`，不写第二个提交），不能用 `main...HEAD` —— 后者只看**已提交**内容，而本计划每个 Task 都是「改完先跑断言、再提交」，用它会在改完还没提交时读到旧值（实测：工作区删了一行时，`main...HEAD` 返回空，`git diff $(git merge-base main HEAD)` 返回 `0	1`） |

---

## 全流程 dry-run 证据（codex R4 要求，已完成）

本计划的**完整两步序列已在一个一次性 worktree 里端到端跑过**（跑完即销毁，真分支零污染）。
下表每一格都是**真实输出**，不是推演：

| 阶段 | 对应计划位置 | G1 | G2 | G3 | G4 | G6 | G8 | G5rc | G5out | G7 |
|---|---|---|---|---|---|---|---|---|---|---|
| ① 基线 | Task1 Step1 | ✗1 | ✗0 | ✗1 | ✓ | ✗0 | ✗0 | ✓ | ✓ | ✗无改动 |
| ② Task1 改完·**未提交** | Task1 Step4 | ✓ | ✓ | ✗1 | ✓ | ✓ | ✓3 | ✓ | ✓ | ✗**1** |
| ③ Task1 已提交 | Task2 Step1 | ✓ | ✓ | ✗1 | ✓ | ✓ | ✓3 | ✓ | ✓ | ✗1 |
| ④ Task2 改完·**未提交** | Task2 Step3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓3 | ✓ | ✓ | ✓**2** |
| ⑤ 全部提交后 | Task3 Step3 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓3 | ✓ | ✓ | ✓2 |

**④ 与 ⑤ 均为九条全绿** —— 即计划要求的终态可达。

**②→④ 的 G7 是本次 dry-run 的关键**：它证明修好后的 G7 写法能看见**尚未提交**的改动。
修之前用的是 `git diff --numstat main...HEAD`，在 ② 与 ④ 都只看得到已提交内容，
④ 会读到 1 而非 2，**九条全绿永远不可达**（codex R4 的 [medium]，成立）。

其余同批实测：

| 项 | 实测结果 |
|---|---|
| Task2 Step4 的人眼 diff | 减号行**恰好 2**（`branches: [main]`、`git fetch ... --depth=50`），加号行**恰好 9**（1 行 `types:` + 8 行注释） |
| Task3 Step1 `git status --short` | 零输出 |
| Task3 Step1 提交数 | 基数 5 → 实施后 **7**，正好 +2 |
| Task3 Step2 `git diff --name-only main...HEAD` | 恰好 3 行：workflow + spec + 本计划 |

---

### Task 1: 触发条件 —— 删 `branches` 过滤器 + 显式订阅 `edited`（spec D1 + D3）

**Files:**
- Modify: `.github/workflows/hardening_6_gate.yml`（`on:` 块，基线第 8–10 行；文件头注释，基线第 1–7 行之后）

**Interfaces:**
- Consumes: 无（本计划第一个 Task）
- Produces: 改动后的 `on:` 块形态为
  ```yaml
  on:
    pull_request:
      types: [opened, synchronize, reopened, edited]
  ```
  Task 2 不依赖本 Task 的产出，但两者改同一文件，**必须按 Task 1 → Task 2 的顺序执行**以保证 G7 的删除行数逐步累加可判读。

---

- [ ] **Step 1: 建立断言脚本并跑一遍，确认它在改动前就是失败的**

先按上文「共用断言脚本」一节创建 `/tmp/h6plan/assert.sh`，然后：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-h6-gate-stacked-pr"
bash /tmp/h6plan/assert.sh
```

**期望输出（改动前的基线，必须逐条对上）：**

```
FAIL G1  (实际=1 期望=0)
FAIL G2  (实际=0 期望=1)
FAIL G3  (实际=1 期望=0)
PASS G4  (实际=1)
FAIL G6  (实际=0 期望=1)
FAIL G8  (实际=0 期望≥1)
PASS G5rc  (实际=0)
PASS G5out  (实际=0)
FAIL G7  (实际=无改动 期望=2)
```

> 以上 9 行**已在未改动的当前树上真跑验证过**，逐字符一致。

> ⚠️ **这一步是负向对照，不能跳过。** 若某条断言在改动**之前**就是 PASS，说明它对本次改动零判别力，等于发放宽许可证。
> 特别注意：G4 与 G5 在改动前后**都应当 PASS** —— 它们不是「证明改动发生」的断言，而是「证明没弄坏」的不变量锁。

---

- [ ] **Step 2: 修改 `on:` 块**

把文件中这三行：

```yaml
on:
  pull_request:
    branches: [main]
```

替换为：

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
```

（`opened` / `synchronize` / `reopened` 就是 `pull_request` 原本的默认三项，显式写出以便加上第四项 `edited`；**行为上只增不减**。）

---

- [ ] **Step 3: 在文件头追加英文注释**

在现有 `# v28 R28 F3 fix: ...` 注释块之后、`on:` 之前，插入以下 **8 行**（一字不改，英文，与本文件既有注释体例一致）：

```yaml
# 2026-08-25 fix: REMOVED pull_request.branches filter + ADDED explicit
# types incl. `edited`. Stacked PRs (A<-B<-C) open with base = the upstream
# branch, so `branches: [main]` skipped them entirely; GitHub retargets them
# to main once the upstream merges, and that retarget DOES emit a
# pull_request `edited` event -- but `edited` is not in the default activity
# types, so nothing re-ran. Both gaps together = required check never
# reports = permanently BLOCKED. Removing `branches` makes it report early;
# `edited` forces a fresh run against the new base. DO NOT drop either line.
```

插入后文件开头应当长这样：

```yaml
name: hardening-6 framework gate
# v28 R28 F3 fix: REMOVED pull_request.paths filter. When this workflow is
# required by branch protection, GitHub only creates status checks for PRs
# matching paths; PRs that don't touch those paths would never report a
# status → required check waits forever → branch protection deadlocks all
# unrelated PRs. Fix: always run on every PR; the job itself short-circuits
# (fast pass) when no relevant file changed.
# 2026-08-25 fix: REMOVED pull_request.branches filter + ADDED explicit
# types incl. `edited`. Stacked PRs (A<-B<-C) open with base = the upstream
# branch, so `branches: [main]` skipped them entirely; GitHub retargets them
# to main once the upstream merges, and that retarget DOES emit a
# pull_request `edited` event -- but `edited` is not in the default activity
# types, so nothing re-ran. Both gaps together = required check never
# reports = permanently BLOCKED. Removing `branches` makes it report early;
# `edited` forces a fresh run against the new base. DO NOT drop either line.
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]

permissions:
  contents: read
```

---

- [ ] **Step 4: 再跑断言，确认 Task 1 该翻绿的翻绿了、该还红的还红着**

```bash
bash /tmp/h6plan/assert.sh
```

**期望输出：**

```
PASS G1  (实际=0)
PASS G2  (实际=1)
FAIL G3  (实际=1 期望=0)
PASS G4  (实际=1)
PASS G6  (实际=1)
PASS G8  (实际=3 期望≥1)
PASS G5rc  (实际=0)
PASS G5out  (实际=0)
FAIL G7  (实际=1 期望=2)
```

> **G3 与 G7 此刻仍必须是 FAIL** —— 它们属于 Task 2。若此刻 G3 已经 PASS，说明有人越界提前改了 Task 2 的内容，停下来核对。
> **G5rc / G5out 必须仍是 PASS** —— 证明新写的 `types` 四个值全部是 GitHub 认可的合法活动类型（actionlint 会拒绝非法值）。

---

- [ ] **Step 5: 提交**

```bash
git add .github/workflows/hardening_6_gate.yml
git commit -m "fix(ci): 删掉 hardening-6 闸门的 branches 过滤器并显式订阅 edited

叠罗汉 PR 开出来时 base 指向上游分支，branches: [main] 使该 workflow
从未为它运行过；上游合并后 GitHub 自动 retarget 到 main，该 retarget
确实会发出 pull_request/edited 事件，但 edited 不在默认活动类型里，
所以仍然没有任何 workflow 重跑。两个缺口合取 = 必需检查 acceptance
永不上报 = 永久 BLOCKED。

删 branches 让它一开 PR 就上报；加 edited 让 retarget 那一刻针对新 base
强制重跑一次。

注意措辞：这不等于「陈旧绿灯不可能满足闸门」。从 retarget 发生到新运行
被注册为 pending 之间有约 3 秒窗口，期间旧结果仍然有效。该窗口已作为
残留风险 R9 记账并被接受（本仓无 auto-merge、无合并队列；实测
retarget→合并间隔 431 秒与 833 秒，比窗口大两个数量级）。

edited 会在 retarget 时触发这一点，已由 PR #170 与 #172 两次真实
retarget 的生产数据实证（详见 spec F18-F21）。

叠罗汉路径本身未实证 · 待下一个叠罗汉 PR 验证。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BvzrZhLtJNBrVbVbyNdDjz"
```

---

### Task 2: 删掉会把完整克隆重新浅化的冗余 `git fetch`（spec D2）

**Files:**
- Modify: `.github/workflows/hardening_6_gate.yml`（`Detect relevant changes` 步骤，基线第 43–48 行）

**Interfaces:**
- Consumes: Task 1 已完成（同文件，顺序执行）
- Produces: `Detect relevant changes` 步骤的 `run:` 块首两行变为
  ```bash
  set -euo pipefail
  CHANGED=$(git diff --name-only origin/main...HEAD)
  ```

---

- [ ] **Step 1: 跑断言，确认 G3 / G7 此刻仍是失败的**

```bash
bash /tmp/h6plan/assert.sh
```

**期望**：G3 = `FAIL (实际=1 期望=0)`，G7 = `FAIL (实际=1 期望=2)`，其余**七条** PASS。

---

- [ ] **Step 2: 删掉那一行**

在 `- name: Detect relevant changes` 步骤里，把：

```yaml
        run: |
          set -euo pipefail
          git fetch origin main --depth=50
          CHANGED=$(git diff --name-only origin/main...HEAD)
```

改为（**只删中间那一行，其余三行一字不动**）：

```yaml
        run: |
          set -euo pipefail
          CHANGED=$(git diff --name-only origin/main...HEAD)
```

> **删它的依据（spec D2 / F12 / F13 / F14 / F15）**：
> 第 19–21 行的 `actions/checkout` 已配 `fetch-depth: 0`，真实 CI 日志显示它执行的 refspec 是
> `+refs/heads/*:refs/remotes/origin/*` ⇒ `origin/main` 在该步骤开始前**已存在且为完整深度**；
> 而这条 `git fetch` 的真实输出是 `* branch main -> FETCH_HEAD`，**只写 FETCH_HEAD**，
> 下一行的 `git diff` 读的是 `origin/main`，对结果零贡献；
> 它唯一可观测的差异化效果是把完整克隆重新浅化（写 `.git/shallow`），
> 进而在分叉点落在窗口外时让 `git diff` 报 `fatal: ... no merge base` / rc=128，
> 因该步骤 `set -euo pipefail` 而把整个 job 打红。**净收益为负。**

---

- [ ] **Step 3: 再跑断言，确认七条全绿**

```bash
bash /tmp/h6plan/assert.sh
```

**期望输出（九行全部 PASS，一条不许剩）：**

```
PASS G1  (实际=0)
PASS G2  (实际=1)
PASS G3  (实际=0)
PASS G4  (实际=1)
PASS G6  (实际=1)
PASS G8  (实际=3 期望≥1)
PASS G5rc  (实际=0)
PASS G5out  (实际=0)
PASS G7  (实际=2)
```

> **G4 在这一步尤其重要**：它证明你删的是 `git fetch` 那一行，**没有连带删掉紧挨着的 `git diff` 那一行**。
> **G7 = 2** 证明整个改动相对 `main` 只删了两行（`branches: [main]` 与 `git fetch ...`），没顺手删别的。

---

- [ ] **Step 4: 人眼复核完整 diff**

```bash
git diff "$(git merge-base main HEAD)" -- .github/workflows/hardening_6_gate.yml
```

> ⚠️ **这里也必须用「共同祖先 vs 工作区」的写法。** 此刻 Task 2 的改动还没提交，
> 若写成 `git diff main..HEAD` 或 `main...HEAD`，你看到的是**上一次提交的旧内容**，
> 会漏掉你刚删的那一行 —— 等于人眼复核了个寂寞。

**逐条核对**（这是机械断言够不着的部分）：

1. 删除行**恰好两行**：`    branches: [main]` 与 `          git fetch origin main --depth=50`；
2. 新增行 = 1 行 `types:` + 8 行英文注释，**共 9 行**，无其它新增；
3. `permissions:`、`jobs:`、`steps:` 及以下所有内容**零改动**；
4. 缩进层级正确（`types:` 与原 `branches:` 同为 4 空格缩进）。

---

- [ ] **Step 5: 提交**

```bash
git add .github/workflows/hardening_6_gate.yml
git commit -m "fix(ci): 删掉会把完整克隆重新浅化的冗余 git fetch

checkout 已配 fetch-depth: 0，真实 CI 日志证实它抓的 refspec 是
+refs/heads/*:refs/remotes/origin/*，origin/main 在该步骤开始前已存在
且为完整深度；而这条 git fetch 的输出只是 * branch main -> FETCH_HEAD，
下一行的 git diff 读的是 origin/main，对结果零贡献。

它唯一可观测的差异化效果是把完整克隆重新浅化（写 .git/shallow），
本地复现证实：分叉点落在窗口外时 git diff origin/main...HEAD 会报
fatal: no merge base 并以 rc=128 退出，因该步骤 set -euo pipefail
而把整个 job 打红 —— 这是 acceptance 永久卡死的第二个独立来源
（形态从「缺失」变成「红」）。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BvzrZhLtJNBrVbVbyNdDjz"
```

---

### Task 3: 交付前整体核验

**Files:** 无改动（纯核验）

**Interfaces:**
- Consumes: Task 1 与 Task 2 的全部产出

---

- [ ] **Step 1: 确认工作区干净、分支与提交数正确**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-h6-gate-stacked-pr"
pwd; git rev-parse --abbrev-ref HEAD; git rev-parse --short HEAD; git status --short; git rev-list --count main..HEAD
```

**期望**：路径是 worktree、分支 `fix/h6-gate-stacked-pr`、`git status --short` **零输出**。

**提交数不写死**（`main` 与本分支都可能因评审轮次继续增长）。判据是**相对的**：

> **实施后的提交数 = 开始 Task 1 之前的提交数 + 2**（Task 1 与 Task 2 各一次提交）。

所以 Task 1 的第一步就该先记下基数：

```bash
git rev-list --count main..HEAD
```

> 本计划成文时该数为 **4**（spec 2 次 + 本计划 1 次 + R3 修订 1 次），故彼时实施完应为 **6**。
> **若你实际看到的基数不是 4，以你看到的为准 +2** —— 不要拿这里的 6 去对。
> （教训来源：本计划先写 4、再改 5，两次都因为又多了一次评审修订提交而当场过期。）

---

- [ ] **Step 2: 确认本次只碰了允许碰的文件**

```bash
git diff --name-only main...HEAD
```

> ⚠️ **三个点，不是两个点。** 两点式此刻会返回 26 个路径（含 `main` 独有的 QMT 改动），三点式才是「本分支相对共同祖先加了什么」。

**期望恰好三行，多一行少一行都要停下来查：**

```
.github/workflows/hardening_6_gate.yml
docs/superpowers/plans/2026-08-30-h6-gate-stacked-pr-deadlock.md
docs/superpowers/specs/2026-08-25-h6-gate-stacked-pr-deadlock-design.md
```

---

- [ ] **Step 3: 最后一次全量断言**

```bash
bash /tmp/h6plan/assert.sh
```

**期望**：**九行**全部 `PASS`。

---

- [ ] **Step 4: 送 codex 对抗性评审（对整支分支）**

```bash
.claude/scripts/codex-attest.sh --scope branch-diff --head fix/h6-gate-stacked-pr --base main
```

> ⛔ **只许传这四个参数。** 该脚本的参数解析末尾是 `*) FOCUS="$FOCUS $1"`，**任何未知参数（含 `--help`）都会被吞成 focus 目标**，导致「窄化 → 假 approve → 写脏账本」。
>
> **收口判据**：不看终端那行字，**打开 `.claude/state/attest-ledger.json` 逐字段核**：
> `head_sha` == 当前 HEAD、`base_sha` == main、`kind` == `branch`、无 focus 字段。
>
> ⛔ **attest 之后不得再 rebase**（会改写提交号使 approve 失效）。

---

- [ ] **Step 5: 先生成 PR 正文文件（必须早于 Step 6）**

```bash
mkdir -p /tmp/h6plan
cat > /tmp/h6plan/pr-body.md <<'BODY'
## 问题

叠罗汉 PR（A ← B ← C 顺序合并的 PR 链）开出来后，必需检查 `acceptance` **一直缺失**（不是红，是根本没有），合并按钮永久 BLOCKED。2026-08-24 划线三片 #166 → #170 → #172 连踩两次，每次都靠 close / reopen 强行补触发才解开。

## 根因是两个条件的合取，缺任一条都不会死锁

| | 条件 | 挡掉了什么 |
|---|---|---|
| (a) | `pull_request.branches: [main]` | retarget **之前**的全部运行（base 是上游分支，不匹配） |
| (b) | 默认活动类型不含 `edited` | retarget **那一刻**的运行（事件发了，但没有 workflow 订阅） |

> ⚠️ 常见误解：「retarget 不重新触发 workflow」。**这是错的** —— retarget 会发出 `pull_request` / `edited` 事件，只是没有显式 opt-in 的 workflow 收不到。

## 本 PR 的改动（只碰一个文件，删 2 行 + 加 1 行 + 8 行注释）

- 删 `branches: [main]` → 封 (a)，闸门一开 PR 就上报，评审期内看得到结果；
- 加 `types: [opened, synchronize, reopened, edited]` → 封 (b)，retarget 那一刻针对新 base 强制重跑一次；
- 删 `git fetch origin main --depth=50` → 它会把 `fetch-depth: 0` 的完整克隆重新浅化，分叉点出窗口时 `git diff` 报 `no merge base` / rc=128 把 job 打红，是同一症状的第二个独立来源。

## 证据

`edited` 会在自动 retarget 时触发 —— 两次真实生产数据：

| PR | `automatic_base_change_succeeded` | 3 秒后运行的 workflow |
|---|---|---|
| #170 | 06:35:11Z | **只有 `check-bootstrap-used-once`**（全仓唯一订阅了 `edited` 的） |
| #172 | 06:49:06Z | **只有 `check-bootstrap-used-once`** |

两个时刻 `synchronize` / `opened` / `reopened` / `ready_for_review` 均可排除（head sha 未变、非新开、close/reopen 发生在其后、PR 非草稿）。

`git fetch --depth=N` 会浅化完整克隆并导致 `no merge base` —— 本地复现验证。

## 验证状态（诚实声明）

| 命题 | 状态 |
|---|---|
| YAML 与 workflow schema 合法 | ✅ actionlint 退出 0、零输出（已实测其对非法活动类型会退出 1，有真判别力） |
| main-base 路径没被改坏 | ✅ **本 PR 自证** —— 本 PR 改的正是该 workflow，它在相关文件名单里 ⇒ `relevant=true` ⇒ acceptance 脚本真执行 |
| 删掉 `git fetch` 后 `origin/main` 仍可解析 | ✅ 同上，本 PR 的「Detect relevant changes」步骤成功即为证据 |
| **叠罗汉 PR 现在能拿到 `acceptance`** | ⚠️ **未实证 · 待下一个叠罗汉 PR 验证**（本 PR 自己的 base 就是 main，走的是改动前后行为相同的路径） |

## 评审

- spec：codex `adversarial-review` **R2 真 approve**（R1 挖出 1 条 high，成立并已修；同时更正了 spec 的一处事实错误）
- 设计 spec：`docs/superpowers/specs/2026-08-25-h6-gate-stacked-pr-deadlock-design.md`
- 实施计划：`docs/superpowers/plans/2026-08-30-h6-gate-stacked-pr-deadlock.md`
BODY
echo "已生成，行数：$(wc -l < /tmp/h6plan/pr-body.md)"
```

**生成后立刻校验非空** —— 空文件会让开 PR 的命令产出一个正文空白的 PR：

```bash
[ -s /tmp/h6plan/pr-body.md ] && echo "OK 非空，$(wc -l < /tmp/h6plan/pr-body.md) 行" || echo "FAIL 文件为空或不存在"
```

---

- [ ] **Step 6: 交给用户 push 与开 PR**

Claude **不执行**这两步。把下列命令交给用户，在他自己的终端里**一行一条**执行：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-h6-gate-stacked-pr"
git push -u origin fix/h6-gate-stacked-pr
gh pr create --base main --head fix/h6-gate-stacked-pr --title "修复 hardening-6 闸门在叠罗汉 PR 上的永久死锁" --body-file /tmp/h6plan/pr-body.md
```

> ⚠️ **本步依赖 Step 5 已生成 `/tmp/h6plan/pr-body.md`，顺序不可颠倒。**
> 干净环境下该文件不存在会让开 PR 的命令直接失败；更糟的是若 `/tmp/h6plan`
> 是上一轮遗留的，会**静默提交一份过期的 PR 正文**。


---

## 验收清单（用户自己动手，不需要懂代码）

> 用法：照「动作」一行一条敲，把看到的和「期望看到」对一下，在「通过 / 不通过」打勾。
> 全部命令请在这个目录下执行：
> `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/fix-h6-gate-stacked-pr"`

| # | 动作 | 期望看到 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 敲 `git rev-list --count main..HEAD` | 一个数字。它应当**正好比动手改代码之前大 2**（因为只多了 Task 1、Task 2 两次提交）。**不要对照本文里写死的数字** —— main 和本分支都可能因评审又长了提交 | ☐ / ☐ |
| 2 | 敲 `git diff --name-only main...HEAD`（**三个点**） | **恰好 3 行**：一个 `.github/workflows/hardening_6_gate.yml`，一个 specs 下的文件，一个 plans 下的文件 | ☐ / ☐ |
| 3 | 敲 `git status --short` | **一个字都不输出**（空白） | ☐ / ☐ |
| 4 | 敲 `grep -c 'branches: \[main\]' .github/workflows/hardening_6_gate.yml` | 数字 **0**（那行已删掉） | ☐ / ☐ |
| 5 | 敲 `grep -c 'types: \[opened, synchronize, reopened, edited\]' .github/workflows/hardening_6_gate.yml` | 数字 **1**（新那行已加上） | ☐ / ☐ |
| 6 | 敲 `grep -c 'depth=50' .github/workflows/hardening_6_gate.yml` | 数字 **0**（浅化那行已删掉） | ☐ / ☐ |
| 7 | 敲 `grep -c 'git diff --name-only origin/main' .github/workflows/hardening_6_gate.yml` | 数字 **1**（紧挨着的那行**没被误删**） | ☐ / ☐ |
| 8 | 敲 `actionlint .github/workflows/hardening_6_gate.yml` | **一个字都不输出**（这个工具专门检查这类配置文件写得对不对，不出声就是没毛病） | ☐ / ☐ |
| 9 | 敲 `git diff main...HEAD -- .github/workflows/hardening_6_gate.yml`（**三个点**）然后用眼睛看 | 只有**两行前面带减号**（被删的），**九行前面带加号**（新增的：1 行配置 + 8 行英文说明）；其余全无改动 | ☐ / ☐ |
| 10 | PR 开出来后，在 GitHub 页面上看这个 PR 的检查列表 | 里面有一项叫 **`acceptance`**，最终是**绿的对勾** | ☐ / ☐ |
| 11 | 点开 `acceptance` 那项的运行日志，找「Run hardening-6 acceptance」那一步 | 能看到脚本**真的跑起来的输出**；**不应该**看到 `No hardening-6 framework files touched in this PR` 那句话 | ☐ / ☐ |

> ⚠️ **第 11 项为什么重要**：只看到「绿对勾」不算数 —— 本仓踩过「显示成功但其实一个检查都没跑」的坑。必须看到脚本**真实执行的输出**，才算这个闸门真的跑过。
>
> ⚠️ **本次验收清单不包含「叠罗汉 PR 能拿到检查」这一项** —— 本 PR 自己的目标分支就是 main，物理上验不了。它要等**下一个真正的叠罗汉 PR** 出现时才能核对，核对方法写在 spec 的 §5.3。

---

## 遇到问题怎么办

| 症状 | 可能原因 | 怎么办 |
|---|---|---|
| 断言 G4 变成 FAIL | 删 `git fetch` 那行时把紧挨着的 `git diff` 那行也删了 | 把 `CHANGED=$(git diff --name-only origin/main...HEAD)` 那行加回去 |
| 断言 G5 有输出 | `types` 里某个词拼错了（actionlint 会指名道姓说哪个非法） | 照它报的位置改回 `opened, synchronize, reopened, edited` |
| 断言 G7 不等于 2 | 除了预期的两行还删了别的 | 跑 `git diff "$(git merge-base main HEAD)" -- .github/workflows/hardening_6_gate.yml` 逐行看减号行（**必须用这个写法** —— 排障时改动往往还没提交，`main..HEAD` / `main...HEAD` 都看不见） |
| PR 上 `acceptance` 显示「No hardening-6 framework files touched」 | 相关文件名单没匹配上本文件 | 停下来查名单那行正则，**不要**为了让它过而去改名单（Global Constraints 第 3 条禁止） |
| codex 给出 needs-attention | 正常，评审就是干这个的 | 逐条技术核实，**成立就改、不成立就带理由写进 spec 的评审轮次记录**，不要为了过审而盲改 |
