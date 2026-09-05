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
| `tests/scripts/governance/test_build_payload.py` | 同步 canonical 期望。**必须逐条打开那 15 个测试判断哪些依赖该清单**，不能只改名字最像的那一个 |
| 本 spec + 后续 plan | 文档 |

**不新增文件，不改任何 workflow。**

## 5. 验证策略

判绿一律读**执行量**，不读结论字样（本仓最常踩的假绿家族）。

### 5.1 基线
`tests/scripts/governance/` 当前 **15 passed**（已在 main `db49f60` 实测）。

### 5.2 变异验证（必做，全部亲跑）
每条都要**先看它红、且红在预期的那一条判据上**。归因要单独核 —— 结论对不代表归因对。

| # | 变异 | 预期 |
|---|---|---|
| M1 | 常量拼写改错一个字符 | 红，且报出的是 context 不匹配 |
| M2 | 从 `REQUIRED_CONTEXTS` 里删掉新加的那项 | 红 |
| M3 | 删掉 `APP_BUILD_CONTEXT`（既有项） | 红 —— 证明测试不是只盯新项 |
| M4 | 常量顺序调换 | 记录是红是绿。**若绿**，说明判据不约束顺序 —— 那就明写「顺序无语义」，别假装它被测了 |
| **M5** | **反向对照**：不做任何变异 | **必须全绿**。缺了这一档，一个恒红的测试看起来也像在工作 |

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
| A1 | 看 PR 的改动文件列表 | 只有 2 个代码文件 + 2 份文档；**没有**任何 `.github/workflows/` 下的文件 | |
| A2 | 在 worktree 里跑那套治理测试 | 全部通过，数量不少于 15 | |
| A3 | 跑 `build-protection-put-payload.py --list-contexts` | 打印出**三项**，其中一项逐字是 `backend pytest (full suite)` | |
| A4 | 把那三项与 GitHub 网页上「必需检查」列表对照（**应用之前**） | 三项里有**两项还不在**网页上（后端测试、iOS 构建）—— 这正是待应用的差异 | |
| A5 | 看我给出的干跑 diff | 只新增两条 context；`enforcement`、绕过名单、其它四条 context 一个字都没变 | |
| A6 | 应用之后再看网页上的必需检查列表 | 从 6 项变成 8 项，新增的正是后端测试和 iOS 构建 | |
| A7 | 应用之后随便开一个新 PR（或看已开的） | 检查列表里 `backend pytest (full suite)` 标着「Required」 | |
| A8 | **要害验证**：找一个后端测试会红的改动开 PR（比如故意改坏一个后端测试） | 合并按钮**变灰、点不了**，提示必需检查未通过。确认后关掉该 PR、不要合 | |

A8 是这次改动的**唯一真凭据**：前面几条都只证明「配置改了」，只有它证明「真的拦得住」。
不做 A8 就不能说这件事完成了。

## 9. 回滚

应用脚本是幂等的：把 `REQUIRED_CONTEXTS` 改回两项、重跑应用即可。**但注意** GitHub 的
Rulesets API 是整份 PUT —— 回滚同样要走 builder 生成的完整 payload，不要手工编辑网页，
否则会引入新的「清单与现实脱节」。
