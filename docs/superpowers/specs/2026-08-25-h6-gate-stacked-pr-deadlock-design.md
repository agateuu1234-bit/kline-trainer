# hardening-6 闸门 · 叠罗汉 PR 永久死锁修复 设计 spec

**日期**：2026-08-25
**基线**：`origin/main` `a018a7f`（#172 合并后）
**分支**：`fix/h6-gate-stacked-pr`，worktree `.dev/worktree/fix-h6-gate-stacked-pr`
**改动面**：`.github/workflows/hardening_6_gate.yml` 单文件，**删 2 行 + 加 1 行 `types:` + 加 1 段头注释**

> **本文出现的所有行号均指基线 `a018a7f` 上的 `.github/workflows/hardening_6_gate.yml`**
> （121 行）。改动落地后行号会位移，届时以文件内容为准，不以本文行号为准。
> （见 `feedback_plan_embedded_facts_unreliable`：文档内嵌的数字/行号不可靠。）

**本 spec 自成一支**，与划线（D1–D80+）、QMT 两支的 D 编号无关；本文决策编号 **D1–D6** 仅在本文件内有效。

**类别**：治理 / CI 工具链改动 —— 按 `CLAUDE.md`「Repository governance backstop」，走
`superpowers:brainstorming` → `superpowers:writing-plans` → `codex:adversarial-review` → PR。

---

## 0. 一句话

`hardening_6_gate.yml` 的 `pull_request.branches: [main]` 过滤器**加上**「默认活动类型不含 `edited`」，
两者合取使叠罗汉 PR（stacked PR）**自始至终没有任何一次上报机会**，
必需检查 `acceptance` 永不出现 ⇒ 永久 BLOCKED。
修法：删掉该过滤器（让它一开 PR 就跑）**并**显式订阅 `edited`（让 retarget 时刻针对新 base 重跑一次）；
顺带删掉同文件里一条把仓库重新浅化、能造成同一症状第二种形态的冗余 `git fetch`。

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

上游合并（且其分支被删除）后，GitHub 会自动把下游 PR 的 base 重定向（retarget）到 `main`。

> ⚠️ **本 spec 初稿在此处写错过，已按 codex R1 更正**（轮次记录见 §11）。
> 初稿原文是「**retarget 不重新触发 workflow**」。**这是错的。**
> retarget 会发出 `pull_request` 事件、动作为 **`edited`**（F18 / F19 已用两次生产数据实证）。
> 真相是：**`pull_request` 的默认活动类型只有 `opened` / `synchronize` / `reopened`，不含 `edited`，
> 所以没有显式 opt-in 的 workflow 收不到这个事件** —— 事件发了，只是没人订阅。

于是死锁是**两个条件的合取**，缺任何一条都不会死锁：

| | 条件 | 它挡掉了什么 | 单独去掉会怎样 |
|---|---|---|---|
| **(a)** | `branches: [main]` | retarget **之前**的全部运行（base 是上游分支，不匹配） | PR 一开出就跑 ⇒ 检查存在 ⇒ 不死锁 |
| **(b)** | 默认活动类型不含 `edited` | retarget **那一刻**的运行（事件发了但没订阅） | retarget 时跑一次，且此时 base 已是 `main` ⇒ 不死锁 |

两条同时成立 ⇒ **必需检查从头到尾没有任何一次上报机会 = 无法满足的条件 = 永久 BLOCKED**。

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
| **F18** | **自动 retarget 确实会触发 `pull_request` 事件** —— PR **#172**：`automatic_base_change_succeeded` @ `06:49:06Z`，**3 秒后（`06:49:09Z`）全仓仅 `check-bootstrap-used-once` 一个 workflow 运行**；而它是全仓**唯一**在 `types:` 里含 `edited` 的 workflow（F7） | `gh api .../issues/172/timeline` + `gh run list --branch feat/drawing-p1b-undo --json workflowName,createdAt,event`（2026-08-25） |
| **F19** | **同一形态在 PR #170 上独立复现** —— `automatic_base_change_succeeded` @ `06:35:11Z` → `06:35:14Z` 仅 `check-bootstrap-used-once` 运行 | 同上，分支 `feat/drawing-p1b-autoselect` |
| **F20** | 上述两个时刻**其它活动类型均被排除**：head sha 未变（⇒ 无 `synchronize`）、非新开（⇒ 无 `opened`）、`closed`/`reopened` 均发生在其**之后**（#172 = `06:49:30` / `06:49:34`；#170 = `06:39:04` / `06:39:08`）、PR 非草稿（⇒ 无 `ready_for_review`）⇒ **触发动作只可能是 `edited`** | 同上两份 timeline 全事件流 |
| **F21** | 手工 close / reopen 之后（#172 `06:49:36Z`、#170 `06:39:10Z`）**8 个 workflow 全部运行**，其中含 `hardening-6 framework gate` —— 这就是当时唯一让 `acceptance` 上报的途径 | 同上两份 `gh run list` |
| **F22** | **检查结果挂在 PR 的 head sha 上，不是挂在临时合并提交上；retarget 不作废 retarget 之前的检查结果。** PR #172 head sha `526a0ca…` 上，必需检查 **`collect` 只在 `06:25:39Z`（早于 retarget 的 `06:49:06Z`）跑过一次、其后从未重跑**，而该 PR 于 `06:56:17Z` **成功合并** ⇒ 一次 retarget 前的运行满足了 retarget 后的必需检查 | `gh api repos/.../commits/526a0ca6e5bcd5917085a88e0d34f331e2943145/check-runs` 全量列表（2026-08-30 查） |
| **F23** | 依赖安装三步（`Install jq` / `Set up Python` / `Install Python test dependencies`）在 job 中**排在 `Detect relevant changes` 之前**，故短路 PR 同样付出该成本 | 读文件步骤顺序：基线第 22–41 行 vs 第 43 行 |
| **F24** | 短路（`relevant=false`）时该 job 实测**整体 25 秒**，其中依赖安装约 **15 秒**（jq 5s + Set up Python 1s + pip 9s）；检测步骤与其后所有步骤各 **0 秒** | `gh api .../actions/runs/32817127092/jobs` 逐步骤时间戳（2026-08-25，分支 `feat/qmt-nas-backend`） |
| **F25** | 本仓为 **PUBLIC** 仓库 ⇒ GitHub Actions 标准 runner 分钟数**免费且无限额** | `gh repo view --json visibility` → `PUBLIC` |

---

## 4. 决策

### D1（修订版 · codex R1 后）　删除 `branches: [main]`，**并**显式订阅 `edited`

`on:` 段变为：

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, edited]
```

（`opened` / `synchronize` / `reopened` 就是原本的默认三项，显式写出以便加上第四项；
**行为上只增不减**。）

两处改动各封掉 §2.1 里的一个死锁条件：**删 `branches` 封 (a)**，**加 `edited` 封 (b)**。

**为什么两条都要 —— 不是冗余，各自解决不同问题：**

| | 只删 `branches` | 只加 `edited` | **两者都做（本决策）** |
|---|---|---|---|
| 死锁解除 | ✅ | ✅ | ✅ |
| 评审期内看得到闸门结果 | ✅ 一开 PR 就有 | ❌ 直到 retarget 前一刻都没有 | ✅ |
| retarget 后闸门是**针对 `main`** 算出来的 | ❌ 沿用 retarget 前那次 ← **codex R1 的 [high]** | ✅ | ✅ |
| 万一将来 GitHub 改掉 retarget 行为 | 退化为「有检查但可能陈旧」 | **死锁复发** | 退化为「有检查但可能陈旧」，**不死锁** |

最后一行是关键：**`edited` 是加法式保险 —— 它只增加运行，从不减少运行。**
即使将来 GitHub 不再于 retarget 时发 `edited`，已删掉的 `branches` 仍保证有检查上报，
**不会退回死锁**；反过来「只加 `edited`」把全部赌注押在单一 GitHub 行为上。

> **末行成立的前提，已用生产数据锁死（F22）**：codex R3 曾主张此行是错的，理由是
> 「`pull_request` 运行以临时合并提交为 `GITHUB_SHA`，retarget 会产生新的合并提交，
> 故 retarget 前的结果无法满足新状态」。**该主张已被推翻。**
> `GITHUB_SHA`（workflow **内部**看到的提交）与**检查结果挂在哪个提交上**是两回事：
> 检查挂在 PR 的 **head sha** 上。实证 —— PR #172 的必需检查 `collect`
> **只在 retarget 之前跑过一次、其后从未重跑**，而该 PR 仍成功合并。
> 即：**一次 retarget 前的运行确实满足了 retarget 后的必需检查。**

**codex R1 的 [high] 是怎么被封掉的**：下游 PR 要够到 `main`，**只有两条路** ——
① 自动 retarget（上游分支被删）；② 有人手工把 base 改成 `main`。
**两条都会发出 `pull_request` / `edited`**（①见 F18–F20；②是同一事件、`changes.base` 字段）。
因此必然产生一次针对新 base 的**新运行**，且该运行 pending 期间 PR 不可合并
⇒ **retarget 前那盏绿灯不可能单独满足闸门**。详见 R6。

**删 `branches` 为什么安全 —— 四条论证，逐条锚到台账：**

1. **job 自带短路（F8）**。没碰第 50 行相关名单里那 8 个治理文件的 PR，
   `relevant=false`，跳到「Skip when nothing relevant changed」echo 一句成功收场。

   > ⚠️ **本条的成本估算初稿写错过，已按 codex R3 更正**（轮次记录见 §11）。
   > 初稿写的是「增量成本 ≈ 一次 ubuntu runner 启动」。**这低估了** ——
   > 依赖安装三步排在检测步骤**之前**（F23），所以短路 PR 也要付这笔钱。
   > **实测真值（F24）**：短路时整个 job **25 秒**，其中依赖安装约 **15 秒**。
   > 该成本可接受的依据是 F25（本仓 PUBLIC，标准 runner 免费无限额），
   > **不是**「成本约等于零」。详见 R8 与 §8 方案 E。
2. **作者早就预期它会在非 main-base 的 PR 上跑（F9）**。第 87 行的
   `base.ref == 'main'` 是**步骤级**判断 —— 如果这个 workflow 永远只在 main-base
   的 PR 上运行，这个判断恒真、毫无意义。它存在本身就是「预期会在别的 base 上跑」的证据。
   删掉 `branches` 之后，该步骤在叠罗汉 PR 上按原设计自动跳过。
3. **acceptance 脚本零 base 假设（F11）**。108 行里对 `main` / `origin/main` /
   `base.ref` / `GITHUB_BASE_REF` 的引用数为 0 —— 它是纯粹检查「当前这棵文件树」的脚本。
   因此「叠罗汉 PR 上跑它」在语义上**等同于**「同一棵树在 main-base PR 上跑」。
4. **同文件先例 + 同仓样式（F10 / F7）**。头注释白纸黑字写着当初为**一模一样的死锁理由**
   删掉了 `paths` 过滤器；同一个道理原样套到 `branches` 上。
   改完之后本文件**在两条轴上都不再是异类**：
   - `branches` 轴 —— 与其余 12 个 workflow 一致（都不按 base 过滤，F2）；
   - `types` 轴 —— 与 `check-bootstrap-used-once.yml` 一致（同样显式列出并含 `edited`，F7）。

   > 注：改完后 `on:` 段与 `branch-protection-config-self-check.yml` /
   > `codeowners-config-check.yml` 那两个光秃秃的 `on: pull_request:` **并不逐字相同**
   > —— 本闸门多一行 `types:`。这是刻意的（见 D1 对照表），不是样式漂移。

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
本次在其后追加一段同体例注释，必须记录三件事：
1. 删掉 `branches` 的理由（与当初删 `paths` 同构）；
2. **`edited` 为什么必须显式列出** —— retarget 会发该事件但它不在默认活动类型里
   （⚠️ 这一条最容易被后人当成「多余的样板」删掉，注释必须写明删了会怎样）；
3. 短路机制仍在兜底，故「在所有 PR 上跑」的成本可忽略。

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

### 5.3 本 PR 无法自证的部分（明确声明，不假装已验证）

| 命题 | 状态 |
|---|---|
| 删掉 `branches` 后，叠罗汉 PR 在 base=上游分支时**能拿到** `acceptance` | **未实证** —— 本 PR 自己的 base 就是 `main`，走的是改动前后行为相同的那条路径 |
| 加上 `edited` 后，retarget 时刻会产生一次**针对 `main` 的新** `acceptance` 运行 | **机制已实证**（F18–F20：事件确实发出、且已 opt-in 的 workflow 确实收到并运行）；但「**本闸门自身**加上 `types` 后也收得到」这一步**未实证** |

**待下一个真实叠罗汉 PR 核对的两条**：

1. PR 一开出（base 仍是上游分支）就有 `acceptance` 上报；
2. `automatic_base_change_succeeded` 事件后数秒内出现**新的** `acceptance` 运行。

**纪律**：spec、实施计划、提交信息、PR 正文中，对上表两条一律表述为
「**未实证 · 待下一个叠罗汉 PR 验证**」，**不得写成已验证**
（见 `feedback_codex_convergence_honest_reporting` 与 `superpowers:verification-before-completion`）。

### 5.4 不做的验证 —— 对 codex R1 第二条建议的答复

codex R1 建议：「新增一次性叠罗汉集成测试：在下游检查通过后更新上游分支，
再验证下游会针对最终 main base 重跑。」**不采纳**，三条理由：

1. **该测试要回答的核心问题，生产数据已经回答。** 它的待证命题是
   「base 变化时下游会不会重跑」—— F18 / F19 已用 #170 与 #172 **两次真实 retarget** 证实：
   事件确实发出，且唯一订阅 `edited` 的 workflow 确实收到并运行。
2. **剩下的推断只有一步，且失败是安全的。** F18/F19 证明的是
   「`check-bootstrap-used-once` 收到了」，不是「`hardening_6_gate` 加上 `types` 后也收得到」；
   这一步依赖 GitHub 对同一事件向所有 opt-in workflow 的统一投递。
   万一不成立，退化结果是「检查存在但可能陈旧」（因 `branches` 已删），
   **不会退回死锁**（见 D1 对照表末行）。
3. **成本不对称。** 造两个一次性 PR + 合并上游触发 retarget + 清理分支，
   换来的是对一个**已有两次生产观测**的行为的第三次观测。

**（补充）为什么也不在 `main` 上造实验 PR**：会留下无意义的合并记录。
若将来确需实测，正确做法是**全程不碰 `main`** —— 用三个一次性分支
（`tmp-base` ← `tmp-up` ← `tmp-down`）互相开 PR、把上游合进 `tmp-base` 触发 retarget、
观察后全部关闭并删除分支。本次不做。

---

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R1** | 叠罗汉 PR 上 `git diff origin/main...HEAD` 会**多算上游那片的改动**；上游若碰过治理文件，下游会**多跑一次完整 acceptance** | **无害，只费机器时间**。由 F11（脚本零 base 假设）可知其结果必然与上游 PR 自己那次相同，不会误红 | 接受。D4 明确不改 |
| **R2** | 本 workflow 现在会在**所有** PR 上跑，包括 base 不是 main 的 PR | 不产生新的阻塞：ruleset 只管 `~DEFAULT_BRANCH`（F5），合入非 main 分支不受必需检查约束 | 接受 |
| **R3** | `--depth=50` 那条删掉后，若将来有人给 checkout 改成 `fetch-depth: 1`，`origin/main` 会消失、diff 直接失败 | 属未来改动的风险，不是本次引入 | 由 §5.2 的自证机制兜底：任何改动本文件的 PR 都会 `relevant=true` 从而真跑一遍 |
| **R4** | `actions/checkout@v4` 未钉 SHA，与其余 12 个 workflow 不一致 | 真实的信任边界不一致 | D5：本次只记录不改，留作独立 backlog |
| **R5** | `enforcement_mode` 当前为 `drift-log`（F17），故第 58–75 行那一步里的 `--final` 分支与第 86–121 行的 advisory 步骤当前均不生效 | 本次改动不触碰这两处逻辑；将来翻到 `block` 时，第 87 行的 base 判断会让 advisory 步骤在叠罗汉 PR 上按原设计跳过 | 接受，无需动作 |
| **R6** | **retarget 之前跑出的绿灯被复用来满足闸门** —— 下游 PR 从未针对最终 `main` 状态验证过（**codex R1 的 [high]**） | **已由 D1 的 `edited` 封掉**：下游 PR 够到 `main` 只有「自动 retarget」与「人工改 base」两条路，**两条都发 `pull_request`/`edited`** ⇒ 必然产生一次针对新 base 的新运行，其 pending 期间 PR 不可合并 | **已处置**（D1 修订版） |
| **R7** | 残留的陈旧面：`strict_required_status_checks_policy = false`（F6）⇒ 检查通过后 `main` 仍可继续前进，合并时的 `main` 未必是验证时的 `main` | **仓库级既有配置，非本次引入** —— 本仓**任何** PR（不只叠罗汉）都同样如此。codex R1 称此配置「特别放大」本次风险，该定性不成立：R6 封掉后，叠罗汉 PR 的陈旧面与普通 PR 同级 | 接受，**超出本次范围**（要改需动 ruleset，属独立决策） |
| **R8** | 订阅 `edited` 后，**任何 PR 的标题 / 正文编辑**都会触发一次完整 job；而依赖安装排在短路判定之前（F23），故每次都要付约 15 秒安装成本（**codex R3 的 [medium]**） | 实测单次 job **25 秒**（F24）；本仓 PUBLIC，标准 runner 分钟数**免费无限额**（F25）⇒ **无配额、无费用影响**。绝对量级为「每次 PR 描述编辑 25 秒机器时间」 | **接受**；重排步骤顺序的方案已评估并否决，见 §8 方案 **E** |

---

## 7. 本 spec 明确不做

- 不改「Detect relevant changes」的比对基准（D4）；
- 不改 `actions/checkout@v4` 的钉版方式（D5）；
- 不改第 50 行的相关文件名单；
- 不改 acceptance 脚本 `scripts/acceptance/hardening_6_framework.sh`；
- 不改 ruleset（context 名 `acceptance` 不变，F3）；
- 不改任何其它 workflow；
- **不**增加 `ready_for_review` 活动类型（`check-bootstrap-used-once.yml` 有，本闸门无此需要）；
- 不改 `strict_required_status_checks_policy`（见 R7）。

---

## 8. 考虑过并否决的替代方案

| 方案 | 内容 | 否决理由 |
|---|---|---|
| **B** | **保留** `branches: [main]`，**只**增加 `types: [opened, synchronize, reopened, edited]` | **其机制已被 D1 采纳**（`edited` 那一半），但作为**替代方案**仍否决：① 从 PR 开出到上游合并的整段时间里必需检查一直缺失，评审期间**看不到闸门会不会过**，最后一刻才知道；② 一旦 GitHub 改掉 retarget 行为则**死锁复发**，而删掉 `branches` 的方案只退化为「陈旧检查」；③ 与 F7 的同仓样式不一致。<br>⚠️ **初稿的否决理由之一「无法离线证实 `edited` 是否触发」现已作废** —— F18–F20 已用生产数据证实它确实触发 |
| **C** | 把 `acceptance` 从 ruleset 必需名单里摘掉 | 等于关掉治理闸门，方向相反，违背 `CLAUDE.md` 治理 backstop 第 1 条的精神 |
| **D** | 把 `git fetch origin main --depth=50` 改成完整 fetch（而非删除） | 由 F12 已证 `origin/main` 本就存在且完整，改成完整 fetch 仍是纯冗余动作；删除更简单，符合 `CLAUDE.md` §2「最少代码」 |
| **E** | 把 `Detect relevant changes` 提到 checkout 之后，并给三个依赖安装步骤加 `if: steps.changes.outputs.relevant == 'true'`（codex R3 的建议） | **否决**：① 收益实测仅 **约 15 秒 / 次**（F24），而本仓 PUBLIC、runner 免费无限额（F25），既无配额也无费用压力；② 代价是**重排一个承重治理闸门的步骤顺序**，改动量从 3 行涨到约 10 行，且要重新论证「acceptance 那一步仍拿得到 jq 与 python」；③ 属**成本优化**而非**正确性修复**，与本次「修死锁」的请求无直接追溯关系（`CLAUDE.md` §3：每一行改动都要能追溯到用户请求）。**留作独立 backlog 项。** |
| **F** | 用 job 级 `if` 把 `edited` 事件限制为「只有 base 变化时才跑」（如 `github.event.changes.base`） | **否决，且这条有真实危险**：job 被 `if` 跳过时，检查以 `skipped` 结论上报，而「`skipped` 算不算满足必需检查」在 ruleset 下语义不确定 —— 一旦不算，**就重新造出本次要修的那个死锁**。用「可能重新引入死锁」的手段去省 15 秒，风险收益比不成立 |
| **G** | 加 `concurrency` + `cancel-in-progress` 避免重复排队（codex R3 的次要建议） | **否决**：被取消的运行以 `cancelled` 结论上报，同样触及「必需检查拿到非成功结论」的风险面；而实测 job 仅 25 秒（F24），排队堆积在本仓不是真实问题 |

---

## 9. 回滚方案

> ⚠️ **本节初稿写错过，已按 codex R5 更正**（轮次记录见 §11）。
> 初稿写的是「回滚 = `git revert` **该提交**」（单数）。**这是错的** ——
> 实施计划**刻意产生两个提交**（Task 1 触发条件 / Task 2 冗余 fetch），
> 只 revert 最后一个会**留下触发条件的改动仍然生效**。

**实测反例（一次性 worktree 真跑，见 §11 R5）：**

| 操作 | 文件 md5 | 与基线一致？ |
|---|---|---|
| 只 revert Task 2（初稿的做法） | `47942ada…` | **否** —— `branches: [main]` 仍缺失、`types:` 仍生效 |
| 逆序 revert Task 2 → Task 1 | `16ebdafc…` | **是，逐字节一致** ✅ |

### 9.1 已合并进 `main` 之后回滚（最常见）

本仓近期 PR 多以 **squash 合并**落地（`#174`–`#178` 均为单提交、标题带 `(#NNN)` 后缀），
此时整个 PR 在 `main` 上表现为**一个**提交：

```bash
git revert --no-edit <该 squash 提交的 sha>
```

若该 PR 以 **merge commit** 方式落地（本仓也有此形态，如 `#172`），则必须指定主线父提交：

```bash
git revert --no-edit -m 1 <merge 提交的 sha>
```

### 9.2 尚未合并、在分支上回滚

必须 **revert 两个实施提交，且按逆序**（先 Task 2，再 Task 1）：

```bash
git revert --no-edit <Task 2 的 sha>
git revert --no-edit <Task 1 的 sha>
```

> ⛔ `git revert` **没有 `-q` / `--quiet` 选项**。写了会直接报 usage 并**什么都不做**，
> 而后续的 `grep` 断言仍会照常输出数字 —— 看起来像「回滚了但没生效」，
> 极易误判成「revert 不管用」。（本条是 R5 dry-run 首次尝试时真踩到的。）

### 9.3 回滚后必须逐条核实，不能只看 revert 命令是否成功

```bash
grep -c '^    branches: \[main\]$' .github/workflows/hardening_6_gate.yml
grep -c '^    types: \[opened, synchronize, reopened, edited\]$' .github/workflows/hardening_6_gate.yml
grep -c 'git fetch origin main --depth=50' .github/workflows/hardening_6_gate.yml
grep -c 'DO NOT drop either line' .github/workflows/hardening_6_gate.yml
```

**四条期望值依次为 `1` / `0` / `1` / `0`**（实测：逆序 revert 两个提交后四条全部对上）。
四条全部对上，才算真正回到基线。

**回滚后的行为**：叠罗汉 PR 重新需要 close / reopen 手工补触发。
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

---

## 11. 评审轮次记录

### R1 · codex `adversarial-review` · 2026-08-25 · HEAD `0c7bf3c` → **needs-attention**（1 条 high）

**Finding [high]**：D1 让下游 PR 在 base 仍指向上游分支时就跑出绿灯，
而 spec 又自称依赖「retarget 不重新触发」⇒ 那盏绿灯可被复用来满足闸门，
下游却从未针对最终 `main` 状态验证过；`strict: false` 放大该风险。

**判定：成立 —— 且它暴露了 spec 的一处事实错误。** 四条处置：

| # | 处置 | 落点 |
|---|---|---|
| 1 | **事实更正**。「retarget 不重新触发 workflow」是错的：retarget 会发 `pull_request`/`edited`，只是默认活动类型不含它。已用 #170 / #172 两次生产数据实证 | 新增 F18–F21；§2.1 重写为「两条件合取」 |
| 2 | **设计修订**。D1 增加 `types: [..., edited]`，使 retarget 必然产生一次针对新 base 的运行 ⇒ 陈旧绿灯不可能单独满足闸门 | D1 修订版；R6 |
| 3 | **不采纳**其「新增一次性叠罗汉集成测试」的建议 —— 待证问题已由 #170/#172 生产数据回答，且剩余推断失败时**退化为陈旧而非死锁** | §5.4 |
| 4 | **不采纳**其对 `strict: false` 的定性（称「特别放大」）—— 该配置是仓库级既有设定，本仓任何 PR 均如此，R6 封掉后叠罗汉与普通 PR 同级 | R7 |

**本轮的方法论教训**：初稿把「我无法离线证实」直接当成了「不可证实」，
据此否决了方案 B 的机制。实际上仓内**已有生产数据**可证（#170/#172 的 timeline + run 列表），
只是我没想到去查。⇒ **判定「无法证实」之前，先问一遍「历史数据里有没有现成的自然实验」。**

---

### R2 · codex `adversarial-review` · 2026-08-25 · HEAD `718d54e` → **approve**

零 material finding。账本已写入，条目 `branch:fix/h6-gate-stacked-pr@718d54ed…`，
`kind=branch`（整支、无窄化），已 **Read 文件逐字段核实** `head_sha` / `base_sha`。

---

### R3 · codex `adversarial-review` · 2026-08-30 · HEAD `3cd531f`（含实施计划）→ **needs-attention**（3 条 medium）

> ⚠️ 本轮 base 已不是 `a018a7f` —— `main` 在此期间前进到 `1437529`（多 4 个提交）。

| # | Finding | 判定 | 处置 |
|---|---|---|---|
| 1 | 「retarget 产生新的合并提交，故 retarget 前的检查无法满足新状态 ⇒ `edited` 是硬依赖而非保险」 | **不成立 · 已用生产数据推翻** | 把 `GITHUB_SHA` 与「检查挂在哪个 sha」区分开；证据落为 **F22**（#172 的 `collect` 只在 retarget 前跑过一次仍成功合并），并写进 D1 对照表下的说明块。**D1 末行维持原判。** |
| 2 | 「计划的交付检查用了两点式 `main..HEAD`，必然失败」 | **成立** | 计划已改：G7 与范围核对全部改用三点式 `main...HEAD`；提交数期望 4 → **5**；新增全局约束第 9 条并写明「实测两点式返回 26 路径、三点式返回 2 路径」 |
| 3 | 「所谓快速短路其实要先装完全部依赖，成本估算错误」 | **成立（成本陈述部分）· 补救措施否决** | D1 论证 1 的成本估算已更正为**实测 25 秒 / 其中依赖安装约 15 秒**（F23/F24）；接受该成本的依据改为 F25（PUBLIC 仓、runner 免费无限额），并新增 **R8**。其三条补救建议（重排步骤 / `changes.base` 门控 / 并发取消）分别记为 §8 的方案 **E / F / G** 并逐条写明否决理由 —— 其中方案 **F 有真实危险**：job 被 `if` 跳过会以 `skipped` 上报，可能重新造出本次要修的死锁。 |

**本轮的方法论教训**：`main` 会在长流程中前进。**任何「本分支改了什么」的判据都必须相对共同祖先（三点式）**，
否则闸门会在某天 `main` 一动就静默失真 —— 而且失真方向是**变松还是变紧取决于 main 改了什么**，无法预测。

---

### R4 · codex `adversarial-review` · 2026-08-30 · HEAD `6485007` → **needs-attention**（1 条 medium）

**Finding [medium]**：计划的 G7 用 `git diff --numstat main...HEAD`，
它比的是「共同祖先 vs **已提交的** HEAD」，**看不见工作区里尚未提交的改动**；
而两个 Task 都是「改完 → 立刻跑断言 → 才提交」，
故 Task 2 Step 3 永远只能读到 1，**计划要求的九条全绿不可达**。

**判定：成立，且是阻塞级的。** 处置：

1. G7 改为 `git diff --numstat "$(git merge-base main HEAD)" -- "$F"`
   —— 基准仍是共同祖先，但比较对象变成**工作区**。
   实证：工作区删掉一行时，`main...HEAD` 返回空，新写法返回 `0	1`。
2. **顺着同一条判据把整族查了一遍**，发现 codex 未点名的第二处同病：
   Task 2 Step 4 给人眼复核的 `git diff main..HEAD -- <file>` 同样只看已提交内容，
   在该时点会漏掉刚删的那一行 —— 已一并改为共同祖先对工作区的写法。
   （遵循 `feedback_fix_the_whole_predicate_family_not_the_reported_site`：
   修判据要按「判据本身」穷尽，而不是只修被点名的那一处。）
3. 按 codex 的第二条 next-step，**完成了全流程端到端 dry-run**（一次性 worktree，跑完销毁）：
   五个阶段的九条断言输出全部与计划文档逐字符吻合，
   Task2 Step3 与 Task3 Step3 **均为九条全绿**，diff 恰好 2 减 9 加。
   证据表已写入计划正文的「全流程 dry-run 证据」一节。

**本轮的方法论教训**：**「计划里嵌的检查命令」本身也必须被 dry-run。**
本计划的断言脚本此前只在**单一时点**（未改动的基线）验过，
而它要在**五个不同时点**被调用 —— 只验一个时点，等于只走了路的一半
（`feedback_spec_all_paths_must_reach_the_chokepoint`）。
正确做法是把每个调用时点都真跑一遍，这次照做后立刻发现终态不可达。

---

### R5 · codex `adversarial-review` · 2026-08-30 · HEAD `0a890a9` → **needs-attention**（3 条 medium）

**三条全部成立**，无争议项。

| # | Finding | 处置 |
|---|---|---|
| 1 | 计划 Task 3 里，**开 PR 的那步用了 `--body-file`，而生成该文件的步骤排在它后面** ⇒ 干净环境下必然失败；若 `/tmp/h6plan` 是上一轮遗留的，会**静默提交过期的 PR 正文** | 两步对调：先生成正文（新 Step 5）再交付 push/PR（新 Step 6）；并在生成后加 `[ -s ... ]` 非空校验与顺序告诫 |
| 2 | 验收清单第 9 项与排障表**仍在用两点式** `git diff main..HEAD`，与本 spec 自己确立的「main 会独立前进」相矛盾 | 第 9 项（此时已全部提交）改三点式 `main...HEAD`；排障表（此时改动多半未提交）改 `git diff "$(git merge-base main HEAD)"`，并写明为何两点式与三点式在排障场景都不行 |
| 3 | §9 回滚方案说「revert **该提交**」，但计划**刻意产生两个提交**，只 revert 后一个会留下触发条件改动仍生效 | §9 完全重写：分「已合并到 main」与「分支上回滚」两种情形给出确切回滚单元 + 四条核实断言；并附实测 md5 对照表 |

**已按 codex 的 next-step 完成回滚 dry-run**（一次性 worktree，跑完销毁）：
只 revert Task 2 时 md5 = `47942ada…`（≠ 基线，`branches` 仍缺、`types` 仍在）；
逆序 revert 两个后 md5 = `16ebdafc…`，与基线**逐字节一致**，四条核实断言全部对上。

**本轮额外收获（dry-run 首次尝试时踩到的真坑）**：`git revert` **没有 `-q` 选项**。
误写后 git 只打印 usage、**什么都不做**，而后面的 `grep` 断言照常输出数字 ——
输出看上去像「revert 执行了但没效果」，差点让我把「逆序 revert 也没用」当成结论。
⇒ **判绿必须读命令自身的输出，不能只读后续断言的数字**
（`feedback_gate_pipe_swallows_exit_code` 的同族形态）。已写入 §9.2 的告诫。
