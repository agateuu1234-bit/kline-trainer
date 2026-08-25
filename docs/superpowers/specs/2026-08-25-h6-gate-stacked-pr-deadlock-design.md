# hardening-6 闸门 · 叠罗汉 PR 永久死锁修复 设计 spec

**日期**：2026-08-25
**基线**：`origin/main` `a018a7f`（#172 合并后）
**分支**：`fix/h6-gate-stacked-pr`，worktree `.dev/worktree/fix-h6-gate-stacked-pr`
**改动面**：`.github/workflows/hardening_6_gate.yml` 单文件，**净删 2 行 + 加 1 段头注释**

> **本文出现的所有行号均指基线 `a018a7f` 上的 `.github/workflows/hardening_6_gate.yml`**
> （121 行）。改动落地后行号会位移，届时以文件内容为准，不以本文行号为准。
> （见 `feedback_plan_embedded_facts_unreliable`：文档内嵌的数字/行号不可靠。）

**本 spec 自成一支**，与划线（D1–D80+）、QMT 两支的 D 编号无关；本文决策编号 **D1–D6** 仅在本文件内有效。

**类别**：治理 / CI 工具链改动 —— 按 `CLAUDE.md`「Repository governance backstop」，走
`superpowers:brainstorming` → `superpowers:writing-plans` → `codex:adversarial-review` → PR。

---

## 0. 一句话

`hardening_6_gate.yml` 的 `pull_request.branches: [main]` 触发过滤器，
让叠罗汉 PR（stacked PR）拿不到它必需的 `acceptance` 状态检查而永久 BLOCKED；
删掉该过滤器，并顺带删掉同文件里一条把仓库重新浅化、能造成同一症状第二种形态的冗余 `git fetch`。

---

## 1. 症状与事故记录

**症状**：叠罗汉 PR（A ← B ← C 顺序合并的 PR 链）开出来后，PR 页面上必需检查
`acceptance` **一直显示缺失（不是红，是根本没有）**，合并按钮永久 BLOCKED。
其余五项必需检查全部正常上报。

**事故**：2026-08-24 划线三片链条 #166 → #170 → #172 连踩两次，每次都靠
close / reopen PR 强行补触发才解开。

**为什么其它检查看起来正常**：GitHub 的检查状态挂在 **commit sha** 上。close / reopen
只是重新触发 workflow；其余五项之前已在同一个 sha 上报过结果，所以立刻显示 pass，
唯独 `acceptance` 从头到尾没有过任何结果。

---

## 2. 根因

### 2.1 根因一（主）：`branches: [main]` 过滤器

`.github/workflows/hardening_6_gate.yml` 第 8–10 行：

```yaml
on:
  pull_request:
    branches: [main]
```

`pull_request.branches` 过滤的是 **PR 的目标分支（base）**。叠罗汉 PR 开出来时
base 是上游分支（例如 `feat/drawing-session-default-persistence`），不是 `main`
⇒ 条件不匹配 ⇒ **这个 workflow 从来没有为它跑过一次**。

上游合并后 GitHub 会自动把下游 PR 的 base 重定向（retarget）到 `main`，
**但 retarget 不重新触发 workflow**（`pull_request` 的默认活动类型只有
`opened` / `synchronize` / `reopened`，不含 `edited`）。

于是构成闭环：**required 检查 + 从未上报 = 无法满足的条件 = 永久 BLOCKED**。

### 2.2 根因二（潜伏）：一条把仓库重新浅化的冗余 `git fetch`

同文件第 19–21 行的 checkout 已声明 `fetch-depth: 0`（拉全部历史），
但第 43–48 行的「Detect relevant changes」步骤开头又执行：

```yaml
        run: |
          set -euo pipefail
          git fetch origin main --depth=50
          CHANGED=$(git diff --name-only origin/main...HEAD)
```

`git fetch --depth=50` 会**把一个完整仓库重新变成浅仓库**（写 `.git/shallow`）。
当分支的共同祖先（merge base）落在浅化窗口之外时，
`git diff origin/main...HEAD` 报 `fatal: ... no merge base` 并以 rc=128 退出；
该步骤开头的 `set -euo pipefail` 使整步失败 ⇒ **`acceptance` 这个 job 变红**。

这是**同一症状（`acceptance` 永久卡死）的第二个独立来源**，只是形态从「缺失」变成「红」，
且专挑活得久的分支下手 —— 正是叠罗汉 PR 那一类。

> **它现在有多急**：`--depth=50` 数的是提交「代 / 层」而非「个」，本仓合并提交密集，
> 实测 `--depth=50` 实际能摸到 **162 个提交、回溯到 2026-06-19**（约两个月）。
> 叠罗汉 PR 活不到两个月 ⇒ **这是潜伏的雷，不是正在烧的火**。本次一并拆除，
> 理由见 D2。

---

## 3. 已核实事实台账

本 spec 的每一条论证都锚在下表。**「证据来源」列写明是怎么验的**；
凡是本人未亲自验证的，一律标注 `未验证`（本表无此类条目）。

| # | 事实 | 证据来源 |
|---|---|---|
| F1 | `hardening_6_gate.yml` 第 10 行确有 `branches: [main]` | 读文件 |
| F2 | 它是本仓 **13 个 workflow 里唯一**在 `pull_request` 上带 `branches` 过滤器的 | 逐个打印 13 个 `.github/workflows/*.yml` 的 `on:` 段 |
| F3 | ruleset `main`（id `15660830`，target=branch，enforcement=active）的 6 项必需检查为：`branch-protection-config-self-check`、`codeowners-config-check`、`check-bootstrap-used-once`、`Mac Catalyst build-for-testing on macos-15`、`acceptance`、`collect` | `gh api repos/.../rulesets/15660830` |
| F4 | 本仓用 **ruleset**，不是老式分支保护 | `gh api .../branches/main/protection` → 404 `Branch not protected` |
| F5 | ruleset 作用范围是 `{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}}`，**只管 main** | 同上 |
| F6 | `strict_required_status_checks_policy = false`（不强制分支与 main 同步） | 同上 |
| F7 | 产出上述 6 项的 6 个 workflow 中，**除 `hardening_6_gate.yml` 外全部无 `pull_request.branches` 过滤器** | 读 `branch-protection-config-self-check.yml`（`on: pull_request:`）、`codeowners-config-check.yml`（`on: pull_request:`）、`check-bootstrap-used-once.yml`（`types: [...]`，无 branches）、`catalyst-build.yml`（`on: pull_request:` + `push: branches:[main]`）、`codex-review-collect.yml`（`types: [...]`，无 branches） |
| F8 | job 自带短路：`relevant == 'false'` 时只 echo 一句以成功收场 | 读文件第 55–57 行 |
| F9 | 文件里已有**步骤级 base 判断** `if: github.event.pull_request.base.ref == 'main'` | 读文件第 86–87 行 |
| F10 | 文件头注释记录了「当初为一模一样的死锁理由删掉 `paths` 过滤器」的先例 | 读文件第 2–7 行 |
| F11 | `scripts/acceptance/hardening_6_framework.sh`（108 行）中 `main` / `origin/main` / `base.ref` / `GITHUB_BASE_REF` **命中数为 0** | `grep -n` 全文，零命中 |
| F12 | `actions/checkout` 配 `fetch-depth: 0` 时执行的 refspec 含 `+refs/heads/*:refs/remotes/origin/*`，即 **`refs/remotes/origin/main` 在下一步开始前已存在且为完整深度** | 真实 CI 日志 run `32818673863`（2026-08-25，分支 `feat/drawing-p1b-undo`）checkout 步骤打印的 `[command]/usr/bin/git ... fetch --prune --no-recurse-submodules origin +refs/heads/*:refs/remotes/origin/* +refs/tags/*:refs/tags/* +5b1edd64...:refs/remotes/pull/172/merge` |
| F13 | 那条 `git fetch origin main --depth=50` 的实际输出是 `* branch main -> FETCH_HEAD` ——**只写 FETCH_HEAD**，而下一行 diff 读的是 `origin/main` | 同一份日志 |
| F14 | `git fetch --depth=N` 会把一个**完整**克隆重新浅化 | 本地复现：60 提交假仓库，完整克隆后 `git rev-list --count` = 60、无 `.git/shallow`；执行 `git fetch origin main --depth=50` 后 `.git/shallow` 出现、可见提交数 = 50 |
| F15 | 浅化后当分叉点在窗口外时，`git diff --name-only origin/main...HEAD` → `fatal: origin/main...HEAD: no merge base`，rc=**128** | 本地复现：分叉点距 main 顶端 55 个提交；浅化前同一条命令 rc=0 正常输出，浅化后 rc=128 |
| F16 | 在**本仓真实历史**上，`--depth=50` 实际抓到 162 个提交，最老可见 2026-06-19 | `git clone --depth=50 file:///<本仓>` 后 `git rev-list --count HEAD` = 162、`git log --format=%ci \| tail -1` = `2026-06-19` |
| F17 | `.claude/workflow-rules.json` 的 `skill_gate_policy.enforcement_mode` 当前 = `drift-log` | `jq -r` 读取 |

---

## 4. 决策

### D1　删除 `pull_request.branches: [main]`

`on:` 段变为：

```yaml
on:
  pull_request:
```

即：**在所有 PR 上运行，不论 base 指向哪里**。

**为什么安全 —— 四条论证，逐条锚到台账：**

1. **job 自带短路（F8）**。没碰第 50 行相关名单里那 8 个治理文件的 PR，
   `relevant=false`，跳到「Skip when nothing relevant changed」echo 一句成功收场。
   增量成本 ≈ 一次 ubuntu runner 启动。
2. **作者早就预期它会在非 main-base 的 PR 上跑（F9）**。第 87 行的
   `base.ref == 'main'` 是**步骤级**判断 —— 如果这个 workflow 永远只在 main-base
   的 PR 上运行，这个判断恒真、毫无意义。它存在本身就是「预期会在别的 base 上跑」的证据。
   删掉 `branches` 之后，该步骤在叠罗汉 PR 上按原设计自动跳过。
3. **acceptance 脚本零 base 假设（F11）**。108 行里对 `main` / `origin/main` /
   `base.ref` / `GITHUB_BASE_REF` 的引用数为 0 —— 它是纯粹检查「当前这棵文件树」的脚本。
   因此「叠罗汉 PR 上跑它」在语义上**等同于**「同一棵树在 main-base PR 上跑」。
4. **同文件先例 + 同仓样式（F10 / F7）**。头注释白纸黑字写着当初为**一模一样的死锁理由**
   删掉了 `paths` 过滤器；同一个道理原样套到 `branches` 上。删完之后这个 `on:` 段与
   `branch-protection-config-self-check.yml`、`codeowners-config-check.yml` 完全一致，
   本文件不再是 13 个 workflow 里的异类（F2）。

**必需检查的名字不变**：ruleset 里登记的 context 是 `acceptance`（F3），
它来自 job id / job 名，本次不动 job，**context 名稳定，ruleset 无需改**。

### D2　删除 `git fetch origin main --depth=50`

「Detect relevant changes」步骤变为：

```yaml
        run: |
          set -euo pipefail
          CHANGED=$(git diff --name-only origin/main...HEAD)
```

**为什么安全，且为什么必须删而不是留着：**

1. **删掉后 `origin/main` 依然存在（F12）**。这是本决策唯一的硬前提，
   已用**真实 CI 日志**证实：checkout 的 `fetch-depth: 0` 抓的是
   `+refs/heads/*:refs/remotes/origin/*`，`origin/main` 在该步骤开始前已就位、且是完整深度。
   （此前不存在「checkout 后不自己 fetch 就直接用 `origin/main`」的仓内 workflow 先例，
   故必须用日志实证，不接受推测。）
2. **它对 diff 结果零贡献（F13）**。真实日志显示它只写 `FETCH_HEAD`，
   而下一行的 `git diff` 读的是 `origin/main`。
3. **它唯一可观测的差异化效果是把仓库浅化（F14），并因此可以把 job 打红（F15）**。
   净收益为负。

**为什么在本次一起做（而不是另开一片）**：它与 D1 是**同一个文件、同一个步骤块、
同一个症状（`acceptance` 永久卡死）、同一类受害者（活得久的叠罗汉分支）**的两个来源。
分两片的唯一好处是切片更小，但本次总改动量只有 2 行删除 + 1 段注释，
`codex:adversarial-review` 的评审面几乎不因它变大。

### D3　头注释按本文件既有体例，追记本次先例

文件头已有 `# v28 R28 F3 fix: REMOVED pull_request.paths filter. ...` 一段（F10）。
本次在其后追加一段同体例注释，记录：删掉 `branches` 的理由、
「retarget 不重新触发 workflow」这一事实、以及短路机制仍在兜底。

**语言**：本文件头注释现状为全英文，按 `CLAUDE.md` §3「Match existing style」，
本次追加的注释**用英文**；spec 与 PR 正文用中文（见 `feedback_pr_language_chinese`）。

### D4　不改「Detect relevant changes」的比对基准

保留 `git diff --name-only origin/main...HEAD`，**不**改成按 PR 真实 base 比对。

**理由**：改「跟谁比」是**语义改动** —— 短路判定里「哪些文件算相关」的范围会跟着变，
需要额外论证「上游那片的改动由谁来盖」，会显著拉长评审面（参见
`feedback_big_pr_codex_noncovergence`：大 PR 会让 codex 不收敛）。
而它造成的后果已由 F11 界定为**无害**：见 §6 残留风险 R1。

### D5　不动 `actions/checkout@v4` 的浮动标签

本文件第 19 行用的是 `actions/checkout@v4`（浮动标签），
而其余 12 个 workflow 全部钉死完整 SHA `11bd71901bbe5b1630ceea73d27597364c9af683`。
这是信任边界上的真实不一致，**但与本次死锁无关**。
按 `CLAUDE.md` §3「If you notice unrelated dead code, mention it - don't delete it」，
**本 spec 只记录、不修改**，留作独立 backlog 项。

### D6　叠罗汉路径**不假装已验证**

见 §5.3。

---

## 5. 验证方案

### 5.1 静态：`actionlint`

对改动后的 `.github/workflows/hardening_6_gate.yml` 跑 `actionlint`，
断言 YAML 与 workflow schema 仍合法。

**判绿方式**：读 `actionlint` 的**输出内容**（无 error 行）**并**核对退出码，
不使用管道后取 `$?`（见 `feedback_gate_pipe_swallows_exit_code`：
`cmd | tail` 之后的 `$?` 是尾部命令的退出码）。

### 5.2 动态：**本 PR 自证**（这是本次最强的一条）

本 PR 改的正是 `.github/workflows/hardening_6_gate.yml`，
而该路径**就在第 50 行的相关文件名单里**（F1 所在文件自身 grep 名单末项
`\.github/workflows/hardening_6_gate\.yml`）
⇒ 本 PR 上 `relevant=true` ⇒ **acceptance 脚本会被真正执行**。

因此本 PR 的 CI 一次跑完，同时证明三件事：

| 证明什么 | 怎么看 |
|---|---|
| main-base 路径没被改坏 | `acceptance` 检查为绿 |
| 删掉 `git fetch` 后 `origin/main` 仍可解析（D2 的硬前提在真环境成立） | 「Detect relevant changes」步骤成功，且输出了改动文件清单 |
| 短路判定仍工作、且本 PR 走的是 `relevant=true` 分支 | 日志中出现 acceptance 脚本的真实执行输出，而**非**「No hardening-6 framework files touched...」那句 |

> ⚠️ **判绿纪律**：必须在日志里看到 acceptance 脚本的**真实执行输出**，
> 而不是只看检查显示绿。见 `feedback_uikit_gated_evidence_traps`：
> 「成功字样 + 零执行量」是本仓踩过的典型假绿。

### 5.3 无法在本 PR 内实证的部分（明确声明）

**「叠罗汉 PR 现在能拿到 `acceptance` 了」这一条，本 PR 无法自证** ——
本 PR 自己的 base 就是 `main`，走的是修改前后行为相同的那条路径。
要实证必须等**下一个真实的叠罗汉 PR**。

**纪律**：spec、实施计划、提交信息、PR 正文中，
对这一条一律表述为「**未实证 · 待下一个叠罗汉 PR 验证**」，
**不得写成已验证**（见 `feedback_codex_convergence_honest_reporting`
与 `superpowers:verification-before-completion`）。

### 5.4 不做的验证

不构造人工叠罗汉 PR 来验证。理由：造一个假的上游 PR + 下游 PR、
等上游合并触发 retarget、再观察下游 —— 会在 `main` 上留下两个无意义的合并记录，
代价与收益不成比例。等真实叠罗汉 PR 出现即可。

---

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R1** | 叠罗汉 PR 上 `git diff origin/main...HEAD` 会**多算上游那片的改动**；上游若碰过治理文件，下游会**多跑一次完整 acceptance** | **无害，只费机器时间**。由 F11（脚本零 base 假设）可知其结果必然与上游 PR 自己那次相同，不会误红 | 接受。D4 明确不改 |
| **R2** | 本 workflow 现在会在**所有** PR 上跑，包括 base 不是 main 的 PR | 不产生新的阻塞：ruleset 只管 `~DEFAULT_BRANCH`（F5），合入非 main 分支不受必需检查约束 | 接受 |
| **R3** | `--depth=50` 那条删掉后，若将来有人给 checkout 改成 `fetch-depth: 1`，`origin/main` 会消失、diff 直接失败 | 属未来改动的风险，不是本次引入 | 由 §5.2 的自证机制兜底：任何改动本文件的 PR 都会 `relevant=true` 从而真跑一遍 |
| **R4** | `actions/checkout@v4` 未钉 SHA，与其余 12 个 workflow 不一致 | 真实的信任边界不一致 | D5：本次只记录不改，留作独立 backlog |
| **R5** | `enforcement_mode` 当前为 `drift-log`（F17），故第 58–75 行那一步里的 `--final` 分支与第 86–121 行的 advisory 步骤当前均不生效 | 本次改动不触碰这两处逻辑；将来翻到 `block` 时，第 87 行的 base 判断会让 advisory 步骤在叠罗汉 PR 上按原设计跳过 | 接受，无需动作 |

---

## 7. 本 spec 明确不做

- 不改「Detect relevant changes」的比对基准（D4）；
- 不改 `actions/checkout@v4` 的钉版方式（D5）；
- 不改第 50 行的相关文件名单；
- 不改 acceptance 脚本 `scripts/acceptance/hardening_6_framework.sh`；
- 不改 ruleset（context 名 `acceptance` 不变，F3）；
- 不改任何其它 workflow；
- 不给 `pull_request` 增加 `types:`（替代方案 B，已否决，见 §8）。

---

## 8. 考虑过并否决的替代方案

| 方案 | 内容 | 否决理由 |
|---|---|---|
| **B** | 保留 `branches: [main]`，改为增加 `types: [opened, synchronize, reopened, edited]`，指望 retarget 触发 `edited`（仓内 `check-bootstrap-used-once.yml` 确有 `edited` 的用法先例） | ① 依赖「GitHub 自动 retarget 会不会发 `edited` 事件」这一**本人无法离线证实**的行为；② **即使成立也更糟**：从 PR 开出到上游合并的整段时间里，必需检查一直缺失，评审期间**看不到闸门会不会过**，最后一刻才知道；③ 与 F7 揭示的同仓样式背道而驰 |
| **C** | 把 `acceptance` 从 ruleset 必需名单里摘掉 | 等于关掉治理闸门，方向相反，违背 `CLAUDE.md` 治理 backstop 第 1 条的精神 |
| **D** | 把 `git fetch origin main --depth=50` 改成完整 fetch（而非删除） | 由 F12 已证 `origin/main` 本就存在且完整，改成完整 fetch 仍是纯冗余动作；删除更简单，符合 `CLAUDE.md` §2「最少代码」 |

---

## 9. 回滚方案

单文件、纯触发条件与冗余命令的改动，**回滚 = `git revert` 该提交**。
回滚后行为完全回到 `a018a7f` 的状态（叠罗汉 PR 重新需要 close / reopen 手工补触发）。
无数据迁移、无状态残留、无需改 ruleset。

---

## 10. 交付与流程

1. 本 spec 提交并推送；
2. `codex:adversarial-review` 对 spec 做对抗性评审
   —— `.claude/scripts/codex-attest.sh --scope branch-diff --head fix/h6-gate-stacked-pr --base main`
   ⛔ 不传任何其它参数（见 `feedback_codex_attest_unknown_arg_becomes_focus`：
   未知参数会被当成 focus 目标 → 假 approve + 写脏账本）；
3. 评审收敛后 → `superpowers:writing-plans` 出实施计划；
4. 实施 → PR。

**push 与开 PR 由用户在自己的终端执行**（Claude 的 Bash 被守卫拦截）。
