# 把「后端测试」纳入 main 分支的必需检查 · 设计

- 日期：2026-09-05
- 分支：`chore/backend-tests-required-check`（base = main `db49f60`）
- 类别：trust-boundary（改 `scripts/governance/**`）→ 强制 `codex:adversarial-review`
- 由来：PR #180 收尾时记下的残留 **F5**

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

**目标**：让 `backend pytest (full suite)` 红时**无法合并**。

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

## 4. 改动面

| 文件 | 改什么 |
|---|---|
| `scripts/governance/build-protection-put-payload.py` | 新增 `BACKEND_TESTS_CONTEXT` 常量；`REQUIRED_CONTEXTS` 追加它；订正文件头 docstring 里已过时的「Catalyst + app-build」表述 |
| `tests/scripts/governance/test_build_payload.py` | 同步 canonical 期望 |
| `tests/scripts/governance/test-verify-required-checks.sh` | 同上（见下方 ⚠️） |
| `tests/scripts/governance/test-admin-runbook.sh` | 同上（见下方 ⚠️） |
| `tests/scripts/governance/fixtures/*.json` | 代表「已合规」的 fixture 需含新 context（**哪几个由实跑决定，不靠猜**） |
| 本 spec + 后续 plan | 文档 |

**不新增文件，不改任何 workflow。**

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
| #5、#6a | 同因（N3 fixture 缺新 context → post-assert 败） |

`fixtures/` 目录下共 **18** 个文件（`ls | wc -l` 实测），远多于评审点名的两个。因此本 spec
**不预先列出**要改哪几个 —— 那是按印象猜。正确做法写进 plan：**跑一遍 `run-all.sh`，
红哪个改哪个**，改完再跑一遍确认 ALL GREEN。

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

**判绿的唯一口径 = `bash tests/scripts/governance/run-all.sh` 的最后一行是 `ALL GREEN`
且全文无 `FAIL:` 行。**

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

| # | 变异 | 预期 |
|---|---|---|
| M1 | 常量拼写改错一个字符 | 红，且报出的是 context 不匹配 |
| M2 | 从 `REQUIRED_CONTEXTS` 里删掉新加的那项 | 红 |
| M3 | 删掉 `APP_BUILD_CONTEXT`（既有项） | 红 —— 证明测试不是只盯新项 |
| M4 | 常量顺序调换 | 记录是红是绿。**若绿**，说明判据不约束顺序 —— 那就明写「顺序无语义」，别假装它被测了 |
| **M5** | **反向对照**：不做任何变异 | **必须全绿**（`run-all.sh` → ALL GREEN）。缺了这一档，一个恒红的测试看起来也像在工作 |

**⚠️ 额外的归因要求（Kimi R1 指出，属实）**：`test-admin-runbook.sh` 里 #6b/#6c/#6d/#6e
这几个用例**本来就期望 rc=1**。它们的 fixture 缺新 context 之后，会因为「缺 context」
而继续 rc=1 —— 看起来是绿的，但**红的理由已经不是它们各自声称的那个**（保护流失 /
多出 bypass / param 削弱 / 未知状态）。这正好踩中本 spec §5.2 开头那句「结论对不代表
归因对」。故：**这四个用例改完 fixture 后必须逐个确认它仍因自己那条理由失败**，
不能只看 rc。

### 5.3 真环境干跑（比读代码可靠）
builder 是**纯函数、不发网络请求**（其 docstring 明写）。因此：取**真实的** ruleset JSON
喂给它，逐字段 diff 它产出的 payload，确认**只多出 backend + app-build 两条**。

必须逐条确认「没变」的东西（**按字段穷尽，不能只看眼熟的那几个**）：

- `enforcement`、`conditions`、`bypass_actors`；
- `required_status_checks` 里**其余 4 条 context 及其 `integration_id`**；
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

1. PR 合并；
2. user 在真实终端跑应用脚本（**先看 §5.3/§5.4 的干跑 diff**）；
3. user 复核 GitHub 上必需检查列表已含两项新条目。

**先合并再应用**：反过来会让本 PR 自己立刻受新规则约束 —— 虽然它会绿，但没必要给自己
加变量。

## 8. 验收清单（非程序员可执行）

> 每条：动作 / 预期 / 判定。判定只填「通过」或「不通过」。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| A1 | 看 PR 的改动文件列表 | 含这些：1 个 builder 脚本、3 个测试文件（1 个 `.py` + 2 个 `.sh`）、若干 `fixtures/*.json`、2 份文档。**关键是：没有任何 `.github/workflows/` 下的文件**（本次不碰 CI 配置） | |
| A2 | 在 worktree 里跑 `bash tests/scripts/governance/run-all.sh` | 最后一行是 `ALL GREEN`，且**没有**任何 `FAIL:` 行 | |
| A3 | 跑 `build-protection-put-payload.py --list-contexts` | 打印出**三项**，其中一项逐字是 `backend pytest (full suite)` | |
| A4 | 把那三项与 GitHub 网页上「必需检查」列表对照（**应用之前**） | 三项里有**两项还不在**网页上（后端测试、iOS 构建）—— 这正是待应用的差异 | |
| A5 | 看我给出的干跑 diff | 只新增两条 context；`enforcement`、绕过名单、其它四条 context 一个字都没变 | |
| A6 | 应用之后再看网页上的必需检查列表 | 从 6 项变成 8 项，新增的正是后端测试和 iOS 构建 | |
| A7 | 应用之后随便开一个新 PR（或看已开的） | 检查列表里 `backend pytest (full suite)` 标着「Required」 | |
| A7b | 应用之后，看脚本打印的 artifact 目录，确认里面**真的有** `rollback-payload.json` 这个文件 | 文件存在且非空 —— 它是唯一可用的回滚凭据（见 §9；**该路径未实跑演练过**） | |
| A8 | **要害验证**：找一个后端测试会红的改动开 PR（比如故意改坏一个后端测试） | 合并按钮**变灰、点不了**，提示必需检查未通过。确认后关掉该 PR、不要合 | |

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
