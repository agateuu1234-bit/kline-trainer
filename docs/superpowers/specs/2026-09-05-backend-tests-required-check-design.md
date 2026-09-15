# 把「后端测试」纳入 main 分支的必需检查 · 设计

- 日期：2026-09-05
- 分支：`chore/backend-tests-required-check`（base = main `db49f60`）
- 类别：trust-boundary（改 `scripts/governance/**`）→ 强制 `codex:adversarial-review`
- 由来：PR #180 收尾时记下的残留 **F5**

> ### ⚠️ 全文约定：「死锁 / 卡死 / 合不进去」一律指**应用之后**
>
> 本交付中凡写「→ 全仓 PR 死锁」「卡死」「卡在 Expected — waiting for status」
> 「合不进去」的地方，**一律指管理员跑过应用脚本、ruleset 真的带上
> `backend pytest (full suite)` 之后**的状态。**应用之前这些后果都不成立**
> —— 那时它只是个没人等的咨询信号，改名或加过滤器不会卡住任何人，
> 只会让盲区悄悄回来（理由与实测见 §3.2.1.1）。
>
> **为什么要立这条约定，而不是逐句加条件**：本条约定是评审第三轮的产物。
> 前两轮的做法是「评审点名几处 → 我逐句补条件」，结果每轮都漏（R1 点 3 处、
> 我 grep 出 2 处、R2 又找出 2 处、R3 换成扫**主语**的口径再找出 4 处），
> 而且补丁本身还制造了新缺陷。⛔ 我曾声称「按字面量枚举 131 条逐条定性、
> 只剩一处」，**这个穷尽性主张是假的** —— 我的词表里有 `卡死` 却没有 `死锁`，
> 12 处「死锁」命中里 5 处词表根本扫不到。
> ⇒ 改用本仓这份 spec 自己发明过的招（§4.3「消灭重复：只有 §4 那张表是真相」）：
> **立一处约定，让所有兄弟句子一次性正确**，也包括将来新写的。
> 本仓 memory：`feedback_exhaustiveness_claims_need_literal_enumeration`、
> `feedback_correction_echoes_scatter_across_eight_places`。

---

## 1. 问题

`backend pytest (full suite)` **不是** main 分支保护的必需检查。后果：**后端测试全红也不
阻止合并** —— 它今天只是一个咨询性信号。

（PR #180 刚把它的触发过滤器整个取消，因此它现在**每个 PR 都跑**，不再有「某类 PR 拿不到
结果」的情形。这是本次能把它设为必需的前提。）

### 1.1 本仓「必需检查」是怎么运作的（实测，2026-09-05 在 main `db49f60` 上复核）

| 环节 | 位置 | 事实 |
|---|---|---|
| 单一真相 | `scripts/governance/build-protection-put-payload.py` 的 `REQUIRED_CONTEXTS` | 目前 = `[Mac Catalyst build-for-testing on macos-15, iOS app build-for-running on macos-15]` |
| 施加 | `scripts/governance/admin-configure-required-checks.sh` | 管理员在终端跑，调 Rulesets API |
| 核对 | `scripts/governance/verify-required-checks.sh` | 从 builder 的 `--list-contexts` 派生，不自己硬编码 |
| 实际生效值 | GitHub ruleset `15660830` | `branch-protection-config-self-check` / `codeowners-config-check` / `check-bootstrap-used-once` / `Mac Catalyst build-for-testing on macos-15` / `acceptance` / `collect` |

**关键性质：一个 PR 改不了必需检查。** 它是 GitHub 的仓库设置。PR 能改的只有那份清单；
真正生效要管理员跑应用脚本。所以本次交付**天然分两半**，缺一不可。

### 1.2 顺带核出的两处既有问题（本次**不修**，见 §6）

- **G1 清单与现实已脱节**：`iOS app build-for-running on macos-15` **在清单里、不在
  ruleset 里**。`verify-required-checks.sh` 今天跑必然 FAIL，而**没有任何 workflow 在跑它**
  （已全仓 grep 确认），所以无人知晓。
- **G2 一道必需检查是橡皮图章**：`branch-protection-config-self-check` 只打印
  `::warning::` 后无条件 `exit 0`，**结构上不可能失败**；且它读旧版
  `/branches/main/protection`，实测本仓返回 **404 `Branch not protected`**（本仓用新版
  ruleset），所以它每次都走「读不到→警告→成功」这条路，什么都没校验。其文件头注释
  自称 "Informational non-required"，但它确实被列为必需检查。

## 2. 目标与非目标

**目标**：让 `backend pytest (full suite)` 红时**默认阻断合并** —— 从今天的「纯咨询信号、
红了也照合」变成「GitHub 明示合并被阻断，要合必须显式绕过」。

> ⚠️ **不能写成「无法合并」**（初版就是这么写的，Kimi R10 指出、已核实真实配置）：
> 本仓 ruleset 的 `bypass_actors` 含 `{"actor_type":"RepositoryRole","actor_id":5,
> "bypass_mode":"always"}`，而 user **就是** admin（`gh api repos/{owner}/{repo} --jq
> '.permissions'` → `admin: true`）。**always-bypass 对包括必需检查在内的全部规则生效** ⇒
> 对唯一会执行合并的那个人，红了**不是**「按钮点不动」，而是「GitHub 拦一下、可显式绕过」。
>
> 这与 PR #180 的 F6 是同一个威胁模型：**防的是意外，不是防所有者刻意为之**。价值仍然成立 ——
> 今天是「红了毫无阻力地合进去」，改完是「必须明知故犯」。但把它说成「无法合并」就是虚报。

**非目标**（每条都在 §6 记为残留，各自独立处理）：
- 不修 G1 的「无人守」（**user 2026-09-05 明确选择推迟**）；
- 不修 G2 的橡皮图章（**user 2026-09-05 明确选择推迟**）；
- 不把治理测试接进 CI；
- 不动 `require_code_owner_review` / `required_approving_review_count`（单人仓库必须保持
  0，见 memory `feedback_branch_protection_single_dev`）。

## 3. 方案（user 在三选一中选定「A」）

往 `REQUIRED_CONTEXTS` 追加 `backend pytest (full suite)`，复用既有的
builder → apply → verify 三件套。

被否掉的两个：
- **B（一并把守清单的机制接进 CI）**：能根治 G1，但要额外解决「CI 读不到 GitHub API /
  权限不足时怎么办」—— 若一律放行就又造一个 G2 式橡皮图章。user 选择推迟。
- **C（只在网页手工勾选，不动代码）**：清单与现实脱节得更厉害，`verify` 依旧 FAIL。

### 3.1 一个躲不掉的连带效应（user 已知情接受）

builder 的语义是「保证 `REQUIRED_CONTEXTS` 里**每一项**都在位」。因此一旦应用，
**`iOS app build-for-running on macos-15` 会被一并设为必需** —— 它本就该在，只是当年漏了。

这是**好事**：应用后清单与现实重新对齐，G1 的「脱节」这一半被顺带修复（剩下的「无人守」
仍是残留）。

**安全性已核**：设为必需的三项，其工作流的 `on.pull_request` **均无任何过滤键**
（`backend-tests.yml` 由 PR #180 取消、`app-build.yml` 与 `catalyst-build.yml` 本就没有），
因此不会出现「必需检查永远等不到结果 → PR 死锁」。这一点必须逐条核，不能想当然：本仓
`hardening_6_gate.yml` 当年正是为躲这个死锁才刻意删掉了自己的 paths 过滤器。

### 3.2 必需检查名的确切来源

GitHub 的 check context = job 的显示名。`backend-tests.yml` 里 job id 为 `pytest`、
`name: backend pytest (full suite)`，故 context 逐字为 **`backend pytest (full suite)`**。
已与 `gh pr checks` 的实际输出比对一致（PR #180 上）。**逐字**很重要：名字差一个字符，
必需检查就永远等不到结果，全仓 PR 死锁。

### 3.2.1 因此这个名字必须被钉住（Kimi R3 指出，复核属实）

本次改动把这个 job 名从「一个显示字符串」**升级成了死锁向量**，而全仓**没有任何测试
断言它**（已 grep 确认：`.py` 文件里的命中全部是注释/docstring）。

> 措辞订正（Kimi R7）：初版写「只出现在注释里」**字面不成立** —— 它当然也作为
> `backend-tests.yml:27` 的 `name:` **配置值**出现，并出现在若干 docs 正文里。
> 承重结论（**没有任何测试断言它**）不受影响；但这份文档通篇以「已核实」为凭据，
> 措辞就得经得起照字面复核。

现有的
`backend/tests/test_backend_tests_workflow_runs_on_every_pr.py` 三条判据只钉触发器，
不碰 job 名。

故本次**必须**给该文件加第四条判据。判据必须写成**两条相等断言**（都从 builder 动态读，
不在测试里另抄字符串 —— 抄一份就等于制造第二个真相）：

1. `backend-tests.yml` 里那个 job 的 `name` **等于** `BACKEND_TESTS_CONTEXT`；
2. `BACKEND_TESTS_CONTEXT` **在** `REQUIRED_CONTEXTS` 里。

> ⚠️ **不能写成「job 名是 `REQUIRED_CONTEXTS` 里的一项」**（成员关系）。初版就是这么写的，
> Kimi R7 指出它有绕过、复核属实：清单里有**多条** context，谁把后端 job 改名成**清单里的
> 另一条**（例如重构时复制粘贴成 Catalyst 那个名字），成员关系判据**仍然绿**，而必需检查
> `backend pytest (full suite)` 永远等不到结果 → **全仓 PR 死锁**，正是这条判据要防的灾难。
> 本仓 memory `feedback_guard_existence_vs_direction_and_identity_map` 记的就是这个形态：
> **守卫只钉「名字在不在」，挡不住两侧互换**。判据必须表达「谁配谁」，不是「在不在集合里」。

这样三个方向才都被挡住：
- 改 job 名（改成任何别的字符串，**含清单里的另一条**）→ 断言 1 红；
- 把 backend 从清单里删掉 → 断言 2 红；
- 改清单里 backend 那一项的字面值而不同步改 job 名 → 断言 1 红。

#### 3.2.1.1 「协同三改」为什么不构成可落地缺陷（Kimi R9 提出，**部分不接受**）

R9 提出一条组合路径：一个 PR **同时**把 job 名改成 X、把 `BACKEND_TESTS_CONTEXT` 改成 X、
并同步改掉 `test_build_payload.py` 里的硬编码期望。两条断言都动态读常量 ⇒ **都绿**；
治理测试又无 CI ⇒ 也不会红。R9 据此判 medium。

**接受的部分（措辞）**：本文档原写「改名的 PR **合并前就被拦住**」，暗示是**测试变红**拦的。
在协同三改这一路径上**不是** —— 拦它的是另一套机制，用户看到的现象也不同（PR 卡住 ≠ 检查变红）。
措辞已在此处修正。

**不接受的部分（严重度）—— 但这个结论有前提**：该路径在**管理员应用过 canonical 清单之后**
是 fail-closed 的：ruleset 上的必需 context 仍是**旧名**，而 PR 把 job 改名后，
**没有任何 job 产出那个 context** ⇒ 该必需检查停在「Expected — waiting for status」⇒
**这个 PR 自己合不了**（非 admin）。

> ⛔ **在应用之前，这条 backstop 不存在** —— ruleset 里还没有 `backend pytest (full suite)`
> 这一条，改名后没有任何检查在等它。实测「协同三改」（job 名 + `BACKEND_TESTS_CONTEXT`
> + 单测常量同时改）：`run-all.sh` **是红的**（4 条 bash 断言），但它
> **在 CI 里一次都不跑**（残留 F-C，`grep -rn 'run-all.sh\|tests/scripts' .github/workflows/`
> 命中 0）；CI 里唯一跑的是必需门里的 pin 测试 → **6 passed 全绿**。
> ⇒ 这样一个 PR **CI 全绿、能合进去**。
>
> 所以 §7「先合并再应用」不是流程洁癖，而是**这条严重度判断成立的必要条件**；
> 在应用完成之前，R9 那条路径是可落地的。而「应用」这一步没有任何机制保证会发生 ——
> 实证：`iOS app build-for-running on macos-15` 2026-06 就进了 canonical 清单，
> 至今（2026-09）取 live ruleset 仍**不在**里面，三个月无人发现。
> （Opus 通道 R2 Major-A 指出，逐条复核并自己重跑过实验）

> 这不是我的推断 —— 机制有仓库内的书面依据：
> `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md:13` 明写
> 「该 required check 永久停在『Expected — waiting for status』→ 非 admin 无法 merge」。
> **有意思的是，这正是 R9 自己在同一轮 F3 里引用的那条机制** —— F3 用它论证「在途 PR 会被卡死」，
> 那条机制同样把 F1 的攻击者自己卡死。两条 finding 互为印证与反证。
> 另：R8 对同族路径（同时改 job 名 + 常量）的结论也是「fail-closed，不构成可落地缺陷」。

**残留**：admin 拥有 always-bypass（见 §6 F-6 引述的 PR #180 F6），可强推过去。那属于
「所有者刻意绕过自己的 CI 策略」，与本判据要防的**意外**不是一类，不在本次范围。

**为什么这条特别值钱**：该文件正是 PR #180 接进 `codeowners-config-check` 那道
**必需门**的文件（那一步就是 `pytest <该文件>`）。所以这条判据由一道必需检查执行 ⇒
改名的 PR **合并前就被拦住**，而不是合进去之后全仓卡死。它也顺带把 F-C（治理测试无 CI）
在这一个常量上补掉了一角。

## 4. 改动面

| 文件 | 改什么 |
|---|---|
| `scripts/governance/build-protection-put-payload.py` | 新增 `BACKEND_TESTS_CONTEXT` 常量；`REQUIRED_CONTEXTS` 追加它；**订正 §4.2 那条 grep 命令在本文件命中的全部过时表述**（实测 `:4` 文件头 + `:31` **函数** docstring —— 别只改文件头） |
| `tests/scripts/governance/test_build_payload.py` | 同步 canonical 期望 |
| `tests/scripts/governance/test-verify-required-checks.sh` | 同上（见下方 ⚠️） |
| `tests/scripts/governance/test-admin-runbook.sh` | 同上（见下方 ⚠️） |
| `tests/scripts/governance/fixtures/*.json` | 代表「已合规」的 fixture 需含新 context（**哪几个由实跑决定，不靠猜**） |
| `backend/tests/test_backend_tests_workflow_runs_on_every_pr.py` | ①新增第四条判据钉住 job 名（§3.2.1）；②订正过时表述（见 §4.2）；③**整份工作流全等比对**（§4.5，code-R5） |
| `.github/workflows/backend-tests.yml` | **让失败传播不再依赖 shell 的 `-e`**（§4.5，code-R5）。⚠️ Claude 对该目录硬 deny → 走 ceremony 由 user `cp` 落地 |
| `scripts/governance/verify-required-checks.sh` | 订正头注释（把谓词描述成「Catalyst check 在位」） |
| `scripts/governance/admin-configure-required-checks.sh` | **订正 §4.2 那条 grep 命令在本文件命中的全部过时表述**（实测 `:2` 头注释、`:71` **`GATE PASS` 用户可见输出**、`:114` **函数内部注释** —— 三处，别只改前两处） |
| `.github/workflows/codeowners-config-check.yml` | **仅订正注释**（`:21` 那段安全论证以「backend-tests 不是必需检查」为前提，本次改动后变假）。**不改任何逻辑/触发器/job 名**。⚠️ Claude 对该目录硬 deny → 走 ceremony 由 user `cp` 落地 |
| 本 spec + 后续 plan + `docs/acceptance/<交付日>-backend-tests-required-check.md` | 文档（验收清单按本仓治理条款是每次交付的必备件，故也在改动面内；日期以实际交付日为准） |

**不新增文件。**触及 `.github/workflows/` 的有**两个**文件：
`codeowners-config-check.yml`（**只改注释**，理由见 §4.4）与 `backend-tests.yml`
（**改了那一步的 run 块**，理由见 §4.5）。两个都走 ceremony 由 user `cp` 落地。

### ⚠️ 4.1 改动面比初版 spec 写的大（Kimi 评审 R1 指出，已复核）

初版只列了 pytest 那一个文件。实际入口是 `tests/scripts/governance/run-all.sh`，它跑
**三套**：pytest + `test-verify-required-checks.sh` + `test-admin-runbook.sh`。而
`verify-required-checks.sh` 的清单是从 builder 的 `--list-contexts` **动态派生**的，
所以清单一加第三项，那些 fixture 只含两条 context 的用例**必然变红**。

已复核的具体破法（用例编号均已核实存在）：

| 用例 | 为什么破 |
|---|---|
| verify 的 "assert happy → 0" | fixture `ruleset-with-check.json` **不含 backend context**（它含 `swift-contracts-smoke` + Catalyst + app-build 三条）→ 报「缺 required check」→ rc=1 |
| admin-runbook #2「apply no-op（已合规）」 | fixture 缺新 context ⇒ builder 会补 ⇒ 不再 no-op ⇒「无 PUT」断言破 |
| #5、#6a | 同因，但**失败点比我原先写的更早**（Kimi R3 指出，复核属实）：re-read 状态缺新 context ⇒ `admin-configure-required-checks.sh:107` 的 `checks(desired) <= checks(actual)` 为假 ⇒ 走「保护流失/人工介入」rc=1，**根本到不了 post-assert**。结论对、归因错 —— 而这份 spec 通篇在强调「结论对不代表归因对」，自己的破法分析先犯了一次 |

`fixtures/` 目录下共 **18** 个文件（`ls | wc -l` 实测），远多于评审点名的两个。因此本 spec
**不预先列出**要改哪几个 —— 那是按印象猜。正确做法写进 plan：**跑一遍 `run-all.sh`，
红哪个改哪个**，改完再跑一遍确认 ALL GREEN。

### 4.2 过时表述必须**按家族穷尽**，不是按手头的文件改（Kimi R3+R4 连提两轮）

R3 让我订正 pin 测试里两处注释，我照做了；R4 立刻指出**同一条规矩我没在别处执行**。
于是本轮改为全仓扫这个家族，实测命中比评审点名的还多：

**家族①「把 canonical 清单描述成两项 / 把谓词描述成只管 Catalyst」**

> ⚠️ **这份清单不再手抄。权威口径 = 下面这条命令的输出，逐条定性**：
> ```
> grep -rn "Catalyst" scripts/governance/
> ```
> 我已经**三次**手抄这类枚举、三次抄漏（R4 漏 2 处、R6 漏 2 处、R8 漏 1 处）。手抄的清单
> 是第二份真相，必然漂移 —— 同 §4.3 的道理。实施时**跑这条命令**，对每条命中做定性，
> 不要照下表的行号去改（行号会随本次改动本身移位）。

在 `0ec2e22` 上跑该命令得 **8 条命中**，定性如下：

| 命中 | 定性 |
|---|---|
| `build-protection-put-payload.py:19`（`CATALYST_CONTEXT = "…"`） | ✅ **常量定义本身，合法，不动** |
| `build-protection-put-payload.py:4,31` | ❌ 过时（docstring 写「Catalyst + app-build」） |
| `verify-required-checks.sh:5,9` | ❌ 过时（把谓词描述成「Catalyst check 在位」） |
| `admin-configure-required-checks.sh:2` | ❌ 过时（头注释） |
| `admin-configure-required-checks.sh:71` | ❌ 过时，且是 **`GATE PASS` 用户可见输出** |
| `admin-configure-required-checks.sh:114` | ❌ 过时（「非仅 Catalyst 谓词」；R8 补 —— 我前一版漏了它） |

即 **7 处待改、1 处合法**。
其中 `admin:71` 是 **`GATE PASS` 的用户可见输出**（不只是注释）—— 它会向管理员**少报**
实际验证了哪些 context，比注释过时更严重。

**家族①还有两处在改动面内的文件里**（Kimi R6 指出）：`test-admin-runbook.sh:18` 的函数名
`both_contexts`、以及 `:64` 的注释「恰一条 Catalyst+15368」。该 helper 自身已从
`--list-contexts` 动态读、**行为不受项数影响**，所以只有名字和注释过时。

> ⚠️ **这暴露了「跑一遍、红哪个改哪个」这条处方的盲区**：函数名和注释过时**不会变红**。
> 因此 plan 里必须**另立一步文本扫描**，与「跑测试」并列，不能指望测试发现它们。

**家族②「把 pin 测试描述成三条判据」**：`test_backend_tests_workflow_runs_on_every_pr.py`
的 docstring（`:19-20`）。

**家族③「以『backend pytest 不是必需检查』为前提的陈述」**——同一个 pin 文件里 **3 处**
（`:23-24`、`:116`、`:123`）。本次改动恰恰把这个前提**翻转**了。其中 `:23-24` 尤其要命：
它是一段**安全论证**（「因为不是必需检查，所以没有过滤器不会造成死锁」），翻转后这段论证
本身变成错的 —— 正是这份文档反复强调要防的形态。

> ⚠️ **这一处是我自己修出来的回归**：R3 时 §4 明确写了「订正 `:23`、`:116`」；R4 我改写
> 那一行时把它换成了「见 §4.2」的指针，而 §4.2 只写了家族①②，**指针指向了一个没有这
> 部分内容的地方**。修复动作弄丢了上一轮的修复 —— 本仓 memory
> `feedback_constraint_must_be_verified_against_real_mechanism` 说的「结构性改动后要重核
> 原来成立的东西」，我又栽了一次。

**家族③还有一处在 workflow 里**：`.github/workflows/codeowners-config-check.yml:21`
——「判据永远执行不到，而它又不是必需检查，于是能合进去」。这同样是一段**安全论证**，
而且它就写在一道**必需门**里。

### 4.4 为什么破例改一个 workflow 文件

初版写「不改任何 workflow」+ 验收 A1 写「PR 里不许有 workflow 文件」。Kimi R6 指出这
构成一个**陷阱**：实施者若发现上面那处安全论证已变假并顺手订正，反而会被我的验收清单
判「不通过」。

权衡后**破例纳入，但只改注释**：一段变假的安全论证写在必需门里，风险高于多跑一次 ceremony；
而且同一条标准我已在 pin 测试上执行了三次，不能选择性适用。**逻辑、触发器、job 名一律不动**
（动了就会牵连 PR #180 那套判据）。代价是 user 要多跑一次 `cp`。

### 4.5 为什么最终还是改了 `backend-tests.yml` 的逻辑（code-R5）

§4.4 说过「逻辑、触发器、job 名一律不动」。那句话的对象是
`codeowners-config-check.yml`，本节是**另一个文件、另一条理由**，不是推翻它。

整支代码评审连续五轮落在同一条判据上 ——「这道必需检查是不是真的在跑、测试失败
会不会传播出去」。前四轮我都在**列白名单**，一层比一层高：

| 轮次 | 我收紧的层 | 下一轮被从哪里绕过 |
|---|---|---|
| code-R1 | 「run 里有 pytest 字样」 | `echo pytest` |
| code-R2 | 「含 `-m pytest` 且含 `tests/`」 | `echo python -m pytest tests/` / `--collect-only` / `\|\| true` |
| code-R3 | 首行命令**逐字**相等 | 步骤级 `if: false`、job 级 `if:`、`continue-on-error: ${{ true }}` |
| code-R4 | job 与步骤的**键级**白名单 | **工作流级** `defaults: run: shell: bash {0}` |

最后这一个之所以致命：GitHub 默认用 `bash --noprofile --norc -e -o pipefail` 跑
`run`，`-e` 让任何一条命令失败就中止。改成 `bash {0}` 就没有 `-e` 了。而那一步的
脚本有两条命令 —— 先跑 pytest，再解析 junit XML 看有没有被跳过的用例。没有 `-e`，
pytest 红了脚本继续往下走，第二条只数 skip 不看 failure，于是打印 `OK` 并以 0 退出：
**整套测试红着，必需检查报绿。**

⇒ 两处改动，一处治标一处治本：

1. **治本 —— 改 `backend-tests.yml` 那一步的 run 块**：显式记住 pytest 与 skip 检查
   各自的退出码，最后 `exit $rc`；skip 检查同时看 `skipped`/`failures`/`errors`。
   这样失败传播**不再依赖 shell 的 `-e`**，`defaults.run.shell` 那条路自己就失效了。
   实测五种情形（全绿 / 有失败 / 有跳过 / XML 干净但 rc 非 0 / 报告根本没生成）在
   `bash -e -o pipefail` 与裸 `bash` 两种 shell 下退出码完全一致；并拿**真实的 1402
   条后端套件**跑过绿、红两侧。

2. **治标 —— 守卫改成整份文档全等比对**：逐层枚举永远差「上一层」（工作流级除
   `defaults` 外还有 `env`、`concurrency`、`run-name`…，GitHub 明年新增什么谁也不知道）。
   文档之上没有层，所以在那里收口。**原有五条语义判据一条不删** —— 全等比对是钉子，
   两边一起改就绿；那五条即便在两边一起改时也照样拦得住危险内容。

代价明写：改这份工作流的任何内容（连 actions 的 SHA）都会让守卫变红，必须显式同步
`_approved_doc`。这正是想要的 —— 它决定这道必需检查是否真的在门控合并。
注释与空行不进解析结果，改注释不会误红。

### 4.3 为什么验收 A1 不复述文件清单

R2/R3/R5 连着三轮，缺陷都落在同一个地方：**改动面被我在三处各写了一遍**（§4 表、§4.2、
验收 A1），每次扩范围就漏改其中一两处，于是「正确的实现会被自己的验收清单判不通过」。

按本仓「判断是不是方案选错了」的三条指标自查：缺陷总量与严重度**在降**（2→3→3→2→2，
medium→low），说明方案没问题；但**集中度极高**、且有一条是上轮修复引入的 ⇒ 问题出在
**文档结构**，不是方案。

所以不再打补丁，改为**消灭重复**：改动面**只有 §4 那张表是真相**，A1 改成「与那张表逐行
对照」。以后再扩范围，只需要改一个地方。

> ⚠️ **扫描方法本身也踩了一下**：我第一遍 `grep "三条判据"` **漏掉了这一处**，因为原文里
> 「三条」和「判据」被**换行拆开**了。教训 = 一致性扫描要考虑「同一说法的不同书写形态」
> （换行、空格、全半角），不能只搜一个连写的词。

**刻意不改（逐条给理由，避免「两头都没占」）**：

| 文件 | 为什么不改 |
|---|---|
| `docs/superpowers/plans/2026-08-30-ci-paths-suite-external-inputs.md`（「三条判据」） | PR #180 **交付当时的历史记录**，描述那次交付的状态、不是现行契约。改它等于篡改档案 |
| `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md`（`:6` 写 canonical = Catalyst + app-build，§4 贴了只含两条 context 的预期输出） | 它是**顺位 2 那次交付的 evidence 记录**（标题即「post-merge admin runbook + evidence 模板」，正文写「本次是真实 mutation」），同属历史档案 |
| `docs/governance/2026-06-10-pr2-pr-body.md`（`:23` 把 `--list-contexts` 应输出两条写成 checklist、`:30` 描述 apply 流程） | 同属顺位 2 那次交付的**历史 PR 描述草稿**；形态是 checklist、风险低于 runbook，但按「按家族穷尽」的标准也要占个位（Kimi R10 补） |
| `docs/superpowers/plans|specs/2026-06-*`、`docs/acceptance/**` 内的同类表述 | 同上，全是历史交付记录 |

> ⚠️ 但第二行那份 runbook 有个**现实风险**（Kimi R7 指出）：它长得像一份**可照着做的操作手册**，
> 而 §7 第 2 步正是让 user 去应用。若 user 翻它对照「预期输出」，会看到与改动后现实不符的
> 「两条 context」。故 §7 已加一句醒目提示：**以本 spec 为准，别照那份旧 runbook 的预期数字核对**。

> ⚠️ **本节两处数字曾经写错**（Kimi R2 指出，均复核属实）：曾写「19 个 fixture（已枚举）」
> —— 实际 18 个，我数的是两个 bash 文件里**被引用的名字去重**，不是目录里的文件数；
> 又曾写该 fixture「只含 Catalyst + app-build」—— 实际三条，而**我自己前一条命令的输出
> 就打印了那三条**，我却照抄了上一轮评审的措辞。
> 记在这里是因为评审的元批评成立：**这份文档通篇拿「已核实」当凭据，而错恰好出在可以
> 静态核验的地方**。据此已把 spec 里其余可核断言重新核了一遍（ruleset 6 条必需 context、
> 三个工作流均无 `pull_request` 过滤键、检查名逐字），**结果全部成立**。

## 5. 验证策略

判绿一律读**执行量**，不读结论字样（本仓最常踩的假绿家族）。

### 5.1 基线（初版写错了，已订正）

**判绿要跑​**两条​**命令，缺一不可**（Kimi R11 指出，复核属实 —— 初版只写了第一条）：

```
bash tests/scripts/governance/run-all.sh                                    # ① 治理三件套
python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py   # ② 钉名判据（从仓库根跑）
```

- ① 判绿 = 最后一行 `ALL GREEN` 且全文无 `FAIL:` 行；② 判绿 = 无 failed。
- ⚠️ **`run-all.sh` 不跑 ② 那个文件**（它只跑 `test_build_payload.py` + 两个 bash 套件）。
  §3.2.1 新增的钉名判据**只在 ② 里体现** —— 只跑 ① 的话，M6/M7/M8 三条变异会显示
  `ALL GREEN`，与变异表「必须红」直接打架，实施者可能误判判据失效、反过来去「修」一条
  本来正确的判据。这正是本文档反复在防的形态。

实测组成（`ea818f2`，供对账用；数字随仓库演进会变，**以实际输出为准，不要拿这里的数字当判据**）：

| 来源 | 执行量 |
|---|---|
| `test_build_payload.py`（pytest） | `15 passed` |
| 两个 bash 套件 | `63` 行 `PASS`、`0` 行 `FAIL` |
| **合计** | **78** |

这一节被订正过两次，都是**同一种错**——量少了：
- 初版写「15 passed」= 只跑了三套里的一套；
- 第二版写「63 条断言」= 只数了两个 bash 套件的 `PASS` 行，把 pytest 的 15 条漏在计数外
  （Kimi R2 指出，复核属实：我那条 `grep -cE '^(PASS|FAIL)'` 天然数不到 pytest 的点号输出）。

**教训**：别在文档里写手工推出来的数字。判绿读 `ALL GREEN` 这一行，对账用上表、且注明测量时的 SHA。

### 5.2 变异验证（必做，全部亲跑）
每条都要**先看它红、且红在预期的那一条判据上**。归因要单独核 —— 结论对不代表归因对。

> **每条变异用哪条命令看红**：M1–M5 看 ①；**M6 / M7 看 ②**；M8 两边都会红（① 因 fixture 期望、② 因断言 2）。

| # | 变异 | 预期 |
|---|---|---|
| M1 | 常量拼写改错一个字符 | 红，且报出的是 context 不匹配 |
| M2 | 从 `REQUIRED_CONTEXTS` 里删掉新加的那项 | 红 |
| M3 | 删掉 `APP_BUILD_CONTEXT`（既有项） | 红 —— 证明测试不是只盯新项。⚠️ **红的是哪一条要看清**（Opus R2）：自 Opus R1 把四个循环改成遍历 `REQUIRED_CONTEXTS` 之后，本档红在 `test_required_contexts_constant` / `test_list_contexts_cli` 这两条**列表相等**断言上；证明「builder 对**既有**项也生效」的是**另一档**变异（builder 单独跳过某个既有 context，实测 2 failed）。别把两者混为一谈 |
| M4 | 常量顺序调换 | 记录是红是绿。**若绿**，说明判据不约束顺序 —— 那就明写「顺序无语义」，别假装它被测了 |
| M6 | 把 `backend-tests.yml` 里那个 job 的 `name` 改掉一个字符 | 新加的第四条判据必须**红**（§3.2.1）。这条变异模拟的正是「全仓 PR 卡死」那个场景 |
| **M7** | 把那个 job 的 `name` 改成 **`REQUIRED_CONTEXTS` 里的另一条**（如 Catalyst 那个名字） | 必须**红**。这一条专打「成员关系判据」那个绕过（见 §3.2.1 的 ⚠️）——**此档若变绿，说明判据被写回成员关系了** |
| M8 | 把 `BACKEND_TESTS_CONTEXT` 从 `REQUIRED_CONTEXTS` 里删掉、但保留常量定义 | 必须**红**（断言 2） |
| **M5** | **反向对照**：不做任何变异 | **必须全绿**（`run-all.sh` → ALL GREEN）。缺了这一档，一个恒红的测试看起来也像在工作 |

**⚠️ 额外的归因要求 —— 但范围比我原先写的窄（Kimi R1 提出，R9 订正，均复核属实）**

`test-admin-runbook.sh` 的 #6b/#6c/#6d/#6e **本来就期望 rc=1**，我原先写「这四个都会因为
缺 context 而换掉失败理由」。**错了**。`preservation_ok` 的检查是**有顺序**的
（`admin-configure-required-checks.sh:98-109`）：标量 → 非 rsc 规则 → rsc policy 字段 →
**checks 子集** → bypass 精确相等。据此逐条核：

| 用例 | 它自己的理由命中在哪一步 | 缺 backend context 会不会换理由 |
|---|---|---|
| #6c（缺 deletion 规则） | 非 rsc 规则（**早于** checks） | ❌ 不会 |
| #6e（policy 字段翻转） | rsc policy（**早于** checks） | ❌ 不会 |
| #6b（缺 Catalyst） | checks 子集 —— **正是它声称的理由** | ❌ 不会 |
| **#6d（多出 bypass actor）** | bypass（**晚于** checks） | ✅ **会** —— 缺 context 在 checks 那步就先挂了。⚠️ 而且**它不会变红**（该用例只断言 rc=1），等于**静默失去 bypass 分支的覆盖**。⇒ plan Task 2 Step 3 明确要求给 `ruleset-extra-bypass.json` **补上** backend context，补完归因就不会漂；Step 5 用「拿掉它要测的那个缺陷、应当转绿」来证明 |

⇒ **只有 #6d 需要盯归因**。处方（逐个确认失败理由）保留，因为它无害且能兜住我判断错的情况。

> 又一次栽在同一处：**我在专门讲「结论对不代表归因对」的段落里，自己写错了归因**。

### 5.3 真环境干跑（比读代码可靠）
builder 是**纯函数、不发网络请求**（其 docstring 明写）。因此：取**真实的** ruleset JSON
喂给它，逐字段 diff 它产出的 payload，确认**只多出 backend + app-build 两条**。

必须逐条确认「没变」的东西（**按字段穷尽，不能只看眼熟的那几个**）：

- `enforcement`、`conditions`、`bypass_actors`；
- `required_status_checks` 里**除 canonical 清单那几条之外的每一条既有 context 及其
  `integration_id`** —— ⚠️ **别照一个写死的数字去数**。初版写「4 条」，实测是 **5 条**
  （live ruleset 现有 6 条 context，其中只有 Catalyst 属于 canonical 清单；误算来源是
  把 6 减去 Catalyst 之后又多减了一次 app-build，而 app-build 本就不在那 6 条里）。
  ruleset 以后再增删 context，写死的数字还会漂 —— 同 §4.3「消灭重复」的道理；
- ⚠️ **`rules` 数组里的其它规则整体逐字不变** —— 尤其那条 `pull_request` 规则，
  它装着 `require_code_owner_review` / `required_approving_review_count`。§2 把「不动这两个
  值」列为非目标，而应用走的是**整份 PUT**：只要 builder 对它不认识的规则处理有偏差，
  这两个值就可能被悄悄改掉，而单人仓库一旦把批准数改成 ≥1 就**再也合不了任何 PR**
  （见 memory `feedback_branch_protection_single_dev`）。这条不是假想 —— 「非目标」只有在
  diff 里被逐字确认过，才算真的没被碰。

⚠️ 这一步是本设计**唯一**能在应用前看清真实后果的手段，不可省。

### 5.4 应用前给 user 的凭据
把 §5.3 的 diff 原样交给 user 过目，**确认后再应用**。不得先应用后汇报。

## 6. 残留（明写）

- **F-A（G1 的一半，本次不修）**：清单**无人守** —— `verify-required-checks.sh`
  没有任何 workflow 在跑。user 2026-09-05 选择推迟。**下一个 PR 的候选**。
  （G1 的另一半「app-build 脱节」会被本次应用顺带修复，见 §3.1。）
- **F-B（G2，本次不修）**：`branch-protection-config-self-check` 是永不失败的橡皮图章。
  修它需要：改读新版 ruleset API、重写判据（它现在还在警告
  `require_code_owner_reviews=false`，而那在单人仓库是**刻意**的）、并配变异验证。
  user 2026-09-05 选择推迟。
- **F-C**：`tests/scripts/governance/` **没有任何 CI 在跑**。也就是说本次改的这个常量，
  **CI 不会验证它** —— 只有本地跑和人工核对。这条与 F-A 同源，建议一起治。
- **F-D**：本次不解决 PR #180 的 F6（仓库内守卫无法自证）。但**本次改动实质上削弱了
  F6 的可利用性**：应用后，谁给 `backend-tests.yml` 加回触发过滤器，必需检查就永远等不到
  结果 → 那个 PR **卡死合不了**。表现为「PR 一直等」而非「检查变红」，第一次遇到会困惑，
  故在此明写。

## 7. 交付次序（不可颠倒）

0. **【应用前的硬前提，别跳】处理在途 PR**（Kimi R9 指出，复核属实）：
   新增一条必需检查后，**任何分支上跑不出该检查的在途 PR 会被永久卡住** ——
   它会停在「Expected — waiting for status」，非 admin 无法合并。
   - 对 `backend pytest (full suite)`：分支需含 PR #180（`06373ef`，取消 paths 过滤器那次）之后的 main；
   - 对 `iOS app build-for-running on macos-15`：分支需含 2026-06 上线 `app-build.yml` 之后的 main。
   **动作**：应用前先 `gh pr list` 看有无开着的 PR；有就先让它们 rebase 到最新 main（或先合、或先关）。
   解卡办法（万一忘了）：给那个 PR 推一个空提交重跑 CI；admin bypass 也能临时解，但不作正常路径。
   > 依据：`docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md:13-20`。
   > ⚠️ 这条前提**只记在那份旧 runbook 里**，而 §7 第 2 步又叫你别去看它 —— 所以特意抄到这里。
   > 抄的是**前提**，不是那份文档里过时的预期数字。

1. PR 合并；
2. user 在真实终端跑应用脚本（**先看 §5.3/§5.4 的干跑 diff**）。
   ⚠️ **别去照 `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md` 核对预期输出** ——
   那是顺位 2 那次交付的历史 evidence，里面的 canonical 清单和预期数字都是**两条 context** 时代的，
   与本次改动后的现实不符（理由见 §4.2 的「刻意不改」表）；
3. user 复核 GitHub 上必需检查列表已含两项新条目。

**先合并再应用**：反过来会让本 PR 自己立刻受新规则约束 —— 虽然它会绿，但没必要给自己
加变量。

## 8. 验收清单（非程序员可执行）

> 每条：动作 / 预期 / 判定。判定只填「通过」或「不通过」。
>
> ⚠️ **交付时以 `docs/acceptance/2026-09-07-backend-tests-required-check.md` 为准**。
> 那一份是实际执行的清单，且比本节多出 A2b（判据条数）、A7d/A7e（整份工作流全等
> 比对的判别力与「改注释不误红」）、A8pre（在本地就能证明「测试红了这一步真的会红」）。
> 本节保留为设计当时的记录。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| A1 | 把 PR 的改动文件列表与本文档 **§4 那张改动面表**逐行对照 | 两边一一对应，PR 里没有表外的文件。**改动面以那张表为唯一真相**，本行刻意不复述文件名（§4.3：复述过三次、漏改过三次；code-R5 又漏了一次——那次改动面多了 `backend-tests.yml`，而这里还写着「有且只有一个」）。表里每个 `.github/workflows/` 文件都打开看，确认改动范围与表上那格写的一致（理由见 §4.4、§4.5） | |
| A2 | 在 worktree 里跑 `bash tests/scripts/governance/run-all.sh` | 最后一行是 `ALL GREEN`，且**没有**任何 `FAIL:` 行 | |
| A3 | 跑 `build-protection-put-payload.py --list-contexts` | 打印出**三项**，其中一项逐字是 `backend pytest (full suite)` | |
| A4 | 把那三项与 GitHub 网页上「必需检查」列表对照（**应用之前**） | 三项里有**两项还不在**网页上（后端测试、iOS 构建）—— 这正是待应用的差异 | |
| A5 | 看我给出的干跑 diff | 只新增两条 context；`enforcement`、绕过名单、**其余每一条既有 context**（当前 5 条，别照写死的数字数）一个字都没变 | |
| A6 | 应用之后再看网页上的必需检查列表 | 从 6 项变成 8 项，新增的正是后端测试和 iOS 构建 | |
| A7 | 应用之后随便开一个新 PR（或看已开的） | 检查列表里 `backend pytest (full suite)` 标着「Required」 | |
| A0 | **应用之前**跑 `gh pr list`，看还有没有开着的 PR | 要么没有；要么每个都已 rebase 到含 `06373ef` 之后的 main。**否则先别应用** —— 应用后它们会永久卡在「Expected — waiting for status」（见 §7 第 0 步） | |
| A7b | 应用之后，看脚本打印的 artifact 目录，确认里面**真的有** `rollback-payload.json` 这个文件 | 文件存在且非空 —— 它是唯一可用的回滚凭据（见 §9；**该路径未实跑演练过**） | |
| A7c | 临时把 `.github/workflows/backend-tests.yml` 里 `name: backend pytest (full suite)` 改掉一个字母，从仓库根跑 `python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py` | 必须**变红**（这条守的是「改名 → 全仓 PR 卡死」）。改回原名后重新全绿 | |
| A8 | **要害验证**：找一个后端测试会红的改动开 PR（比如故意改坏一个后端测试） | 检查列表里 `backend pytest (full suite)` 标着 **Required** 且是**红的**，且 GitHub 明示**合并被阻断**。⚠️ **按钮未必变灰** —— 你是管理员且 ruleset 给管理员开了 always-bypass，GitHub 多半仍让你点、但会提示你正在**绕过规则**。**看到「绕过」提示＝通过**（说明规则真的在拦），看不到任何阻断迹象才算不通过。确认后关掉该 PR、**不要合** | |

A8 是这次改动的**唯一真凭据**：前面几条都只证明「配置改了」，只有它证明「真的拦得住」。
不做 A8 就不能说这件事完成了。

## 9. 回滚

> ⚠️ **初版这一节写的方法是假的**（Kimi 评审 R1 指出，已逐行复核源码确认）。原文写
> 「把 `REQUIRED_CONTEXTS` 改回两项、重跑应用即可」—— **那样什么都不会发生**，而且脚本
> 还会报「已合规」，让人以为回滚成功了。这类「看起来成功、实际没做」是本仓最该防的形态，
> 故完整保留原委。

**为什么假**（两处源码，均已亲自读过）：

1. `build-protection-put-payload.py:52-64` 的循环**只遍历 `REQUIRED_CONTEXTS`、只增不删** ——
   对不在清单里的既有条目原样保留。所以清单改回两项后，live 上那条 backend **依然被复制进
   payload**。
2. `admin-configure-required-checks.sh:168` 有个 **no-op 短路**：
   `diff -q payload.json rollback-payload.json` 一致就「skip PUT」。而第 1 点保证了两者一致 ⇒
   **根本不发 PUT**，必需检查纹丝不动。

**真正的回滚路径**：应用时脚本会用 `--normalize-only` 把**应用前的原状态**落盘为
`<artifact 目录>/rollback-payload.json`（`admin-configure-required-checks.sh:157-158`）。
回滚 = 把**那份文件**整份 PUT 回去。

因此本次交付有一条硬要求：

> **应用那一步必须保留 artifact 目录，并把 `rollback-payload.json` 的路径记录下来。**
> 没有它就没有可用的回滚凭据 —— 只能手工在网页上改，而那会引入新的「清单与现实脱节」。

**验收**：回滚路径**不做实跑演练**（那要求先真改一次 main 的保护设置再改回来，代价过高）。
它作为**书面凭据**交付，并在 §8 的验收里要求 user 确认 artifact 目录与该文件真实存在 ——
这一点必须诚实标注为「未实跑验证」，不能写成已验证。
