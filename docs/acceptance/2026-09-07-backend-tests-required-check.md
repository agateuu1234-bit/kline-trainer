# 验收清单 · 把「后端测试」纳入必需检查

- 日期：2026-09-07
- 分支：`chore/backend-tests-required-check`
- Spec：`docs/superpowers/specs/2026-09-05-backend-tests-required-check-design.md`
- Plan：`docs/superpowers/plans/2026-09-06-backend-tests-required-check.md`

> 每条：动作 / 预期 / 判定。判定只填「通过」或「不通过」。
> ⚠️ **次序不可颠倒**：先合并 PR，再由你应用。A0 必须在应用**之前**做。

---

## 一、合并前可做的

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| A1 | 把 PR 的改动文件列表与 spec §4 那张改动面表逐行对照 | 两边一一对应，PR 里没有表外的文件。**改动面以那张表为唯一真相**（§4.3：本清单刻意不复述文件名，复述过三次、漏改过三次）。表里每个 `.github/workflows/` 文件都打开看，确认改的范围与表上那格写的一致 | |
| A2 | 在 worktree 里跑 `bash tests/scripts/governance/run-all.sh` | 最后一行是 `ALL GREEN`，全文**没有** `FAIL:` 行 | |
| A2b | 从仓库根跑 `python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py` | `6 passed` | |
| A3 | 跑 `python3 scripts/governance/build-protection-put-payload.py --list-contexts` | 打印出**三项**，其中一项逐字是 `backend pytest (full suite)` | |
| A4 | 把那三项与 GitHub 网页上「必需检查」列表对照（**应用之前**） | 三项里有**两项还不在**网页上（后端测试、iOS 构建）—— 这正是待应用的差异 | |
| A5 | 看下面「§二 干跑凭据」那份 diff | 只有新增行、**没有任何删除或修改行**；只多出 2 条 context | |
| A7c | 临时把 `.github/workflows/backend-tests.yml` 里 `name: backend pytest (full suite)` 改掉一个字母，重跑 A2b | 必须**变红**（守的是「改名 → 全仓 PR 卡死」）。改回原名后重新全绿 | |
| A7d | 临时在 `.github/workflows/backend-tests.yml` 的 `jobs:` **上面**插三行 `defaults:` / `  run:` / `    shell: bash {0}`，重跑 A2b | 必须**变红**，且报错里出现「与被批准的结构不一致」。这一条守的是「测试全红、必需检查却报绿」（spec §4.5）。删掉那三行后重新全绿 | |
| A7e | 只在该文件里**改一句注释**（例如某行末尾加个句号），重跑 A2b | 必须**仍然全绿** —— 证明这道钉子钉的是结构不是文本，改注释不会误红 | |

### §一附：A8pre 的命令（一行一条，别拼成一行）

先激活本仓 venv（`python` 要能 `import yaml`；系统自带的 `python3` **没装** pyyaml）。

抽出那一步的 run 块：

```bash
python -c "import yaml;print(yaml.safe_load(open('.github/workflows/backend-tests.yml'))['jobs']['pytest']['steps'][-1]['run'],end='')" > /tmp/blk.sh
```

干净树上跑（预期 `退出码=0`，末行 `OK: 0 skipped / 0 failed / 0 errored`）：

```bash
(cd backend && RUNNER_TEMP=/tmp bash --noprofile --norc -e -o pipefail /tmp/blk.sh) > /tmp/blk.log 2>&1; echo "退出码=$?"; tail -1 /tmp/blk.log
```

再造一个必红的测试重跑（预期 `退出码=1`，末行 `FAIL: 1 个 failed …`）：

```bash
printf 'def test_red():\n    assert 1 == 2\n' > backend/tests/test_zzz_tmp_red.py
```

```bash
(cd backend && RUNNER_TEMP=/tmp bash --noprofile --norc -e -o pipefail /tmp/blk.sh) > /tmp/blk.log 2>&1; echo "退出码=$?"; tail -1 /tmp/blk.log
```

跑完**务必删掉**那个临时测试，并确认工作区干净：

```bash
rm -f backend/tests/test_zzz_tmp_red.py && git status --porcelain
```

> ⚠️ 把 `bash --noprofile --norc -e -o pipefail` 换成裸 `bash`（模拟
> `defaults.run.shell: bash {0}`）再跑一遍，两次结果应当**完全一样** —— 那正是
> spec §4.5 那条加固要保证的事。

## 二、干跑凭据（2026-09-07 实测，真实 ruleset `15660830`）

命令（builder 是纯函数、不发网络请求）：

```bash
gh api "repos/{owner}/{repo}/rulesets/15660830" > /tmp/ruleset-live.json
python3 scripts/governance/build-protection-put-payload.py --ruleset-json /tmp/ruleset-live.json --out /tmp/payload-new.json
python3 scripts/governance/build-protection-put-payload.py --normalize-only --ruleset-json /tmp/ruleset-live.json --out /tmp/payload-cur.json
python3 -m json.tool --sort-keys /tmp/payload-cur.json > /tmp/payload-cur.pretty.json
python3 -m json.tool --sort-keys /tmp/payload-new.json > /tmp/payload-new.pretty.json
diff -u /tmp/payload-cur.pretty.json /tmp/payload-new.pretty.json
```

**diff 全文**（只有新增行）：

```diff
@@ -67,6 +67,14 @@
                     {
                         "context": "collect",
                         "integration_id": 15368
+                    },
+                    {
+                        "context": "iOS app build-for-running on macos-15",
+                        "integration_id": 15368
+                    },
+                    {
+                        "context": "backend pytest (full suite)",
+                        "integration_id": 15368
                     }
                 ],
                 "strict_required_status_checks_policy": false
```

**逐字段核对结果**（spec §5.3 要求按字段穷尽，不能只看眼熟的几个）：

| 字段 / 规则 | 结果 |
|---|---|
| `name` / `target` / `enforcement` / `conditions` / `bypass_actors` | ✅ 全部未变 |
| 规则类型集合 | ✅ 未变（`deletion` / `non_fast_forward` / `pull_request` / `required_status_checks`） |
| `deletion` / `non_fast_forward` 规则 | ✅ 逐字未变 |
| ⚠️ **`pull_request` 规则**（装着批准数） | ✅ **逐字未变**，`required_approving_review_count` 仍为 **0** |
| required checks | 6 → 8 条；**被删除的：无** |

> ⚠️ 那条 `pull_request` 规则单独列出来，是因为**单人仓库一旦把批准数改成 ≥1，你就再也
> 合不了任何 PR**（GitHub 不允许作者批准自己的 PR）。这一条必须每次应用前都确认。

## 三、应用（你在真实终端做）

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| **A0** | **【硬前提，别跳】应用前**跑 `gh pr list`，看还有没有开着的 PR | 要么没有；要么每个都已 rebase 到含 `06373ef`（PR #180）之后的 main。**否则先别应用** | |
| A6 | 跑应用脚本后，再看网页上的必需检查列表 | 从 6 项变成 8 项，新增的正是后端测试和 iOS 构建 | |
| A7 | 随便开一个新 PR（或看已开的） | 检查列表里 `backend pytest (full suite)` 标着 **Required** | |
| A7b | 看脚本打印的 artifact 目录 | 里面**真的有** `rollback-payload.json`（见 spec §9）。⚠️ **它不是「唯一凭据」，也不持久** —— 详见 §六 | |
| A8pre | 按下面「§一附」把那一步的 run 块在本地原样跑两遍：干净树一遍、临时加一个必红测试一遍 | 干净树 → `退出码=0`；有红测试 → `退出码` **非 0**，末行 `FAIL: 1 个 failed …`。这一条在本地就能证明「测试红了这一步真的会红」，不必等到 A8 | |
| **A8** | **要害验证**：找一个后端测试会红的改动开 PR（比如故意改坏一个后端测试） | `backend pytest (full suite)` 标着 **Required** 且是**红的**，GitHub 明示**合并被阻断**。⚠️ **按钮未必变灰** —— 你是管理员且 ruleset 给管理员开了 always-bypass，GitHub 多半仍让你点、但会提示你正在**绕过规则**。**看到「绕过」提示＝通过**；完全看不到任何阻断迹象才算不通过。确认后**关掉该 PR、不要合** | |

### ⚠️ A0 为什么是硬前提

新增一条必需检查后，**任何「分支上跑不出该检查」的在途 PR 会被永久卡住** —— 停在
「Expected — waiting for status」，非管理员无法合并。

- 对 `backend pytest (full suite)`：分支需含 PR #180（`06373ef`）之后的 main；
- 对 `iOS app build-for-running on macos-15`：分支需含 2026-06 上线 `app-build.yml` 之后的 main。

**解卡办法**（万一忘了）：给那个 PR 推一个空提交重跑 CI。

> ⛔ **别去照 `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md` 核对预期
> 输出** —— 那是顺位 2 那次交付的历史记录，里面的清单和数字都是「两条 context」时代的。
> 但它记的这条**在途 PR 前提**是对的，所以抄到了上面。

## 四、已知残留

> ### ✅ 治理闸门已补上（2026-09-19）；合并当时是 override 收口
>
> CLAUDE.md 要求所有 PR 过 `codex:adversarial-review`。**合并时没有**（override），
> **合并后补跑并取得了 approve**。经过如实记在这里：
>
> - **codex 通道**：code-R1..R4 四轮都给了 `needs-attention` 并被逐条修掉；
>   第 5 轮（HEAD `1234386`）**撞到账号额度上限**（提示恢复时间 2026-09-19），
>   `Turn failed`、无 verdict。按本仓惯例「评审被杀 ≠ 判决」，**这不算一轮评审**。
> - **替代通道**：按 user 指示改用 Opus 5 xhigh 子代理做对抗性评审，跑了 **3 轮**
>   （独立上下文，非 fork）。它累计做了 **40+ 组变异**、真实 ruleset 干跑逐字复现、
>   必需门最小环境重跑、**完整**后端套件绿红两侧对拍（写这句时 1402 条，
>   rebase 到 main `d0d4643` 后 1499 —— 条数随仓库演进会变，**不是判据**），判定
>   **可执行产物（工作流 / builder / verifier / 应用脚本 / fixtures / 守卫测试）零缺陷**；
>   三轮共 7 条 Major **全部落在散文**（措辞缺前提、文档改坏、编号撞号）。
> - **但这个通道写不了 attest 账本** ⇒ 它**兑现不了** CLAUDE.md 那道闸门
>   （闸门后来由 9/19 补跑的 codex approve 兑现，见下）。
> - **收敛判断**：第 3 轮时本仓「该不该换做法」的三条指标**全中**
>   （①归因率 0%→50%→**100%** ②Major 数 2→2→**3**，一轮都没降 ③三轮 7 条全落在两个家族）。
>   评审员独立判「**该换做法，不要再开一轮**」。据此做了一次**结构性去重**
>   （删 plan 里那个会照抄出事的代码块、立一条全文约定替代逐句补条件、残留编号去撞号）
>   而不是再开 R4。
> - **user 决策**：override 收口（2026-09-15），据此合并 PR #191。
> - **补跑（2026-09-19，额度恢复后）**：对交付态 `365e56c`（base `d0d4643`）跑
>   `codex-attest.sh --scope branch-diff`，**verdict = `approve`**，账本已写入
>   （`head_sha=365e56c8…`、`base_sha=d0d4643…`、reviewer `codex/v1.0.3`，
>   **无 `override` 字段、无 `focus` 窄化**）。该 head 的内容树与落在 main 的
>   squash 提交 `b0c5961` **逐字相同**，所以这条 approve 覆盖的正是 main 上的内容。
>
> ⚠️ **这条 approve 的覆盖面要打折，别当成「codex 验过全部」**：它自己的摘要写着
> *Workflow guard tests could not run because PyYAML is unavailable* —— 它的沙箱用系统
> `python3`，而 pyyaml 只在仓库 venv 里。所以它实际做的是**通读整个 diff + 跑 15 个
> builder 测试**；**那 6 条守卫判据、1499 条后端套件、24 组变异，它一个都没跑**。
> 那部分的证据来自别处，且都成立：本地 6 条判据全绿 + 24 组变异全中、
> 真实 CI `1499 passed`、以及 **A8 在真 PR #192 上实证阻断**（见 §五）。
>
> ⇒ 治理记录成立；但若要让 codex 的 approve 名副其实，需要让它的沙箱能 import yaml
> （给系统 `python3` 装 pyyaml）后重跑。**本次判断不值得**——那部分已有三重独立证据。

- **F-A**：canonical 清单**无人守** —— `verify-required-checks.sh` 没有任何 workflow 在跑。
- **F-B**：`branch-protection-config-self-check` 是**永不失败**的橡皮图章（只打印警告 + 无条件退出成功；且读旧版 API，实测本仓恒 404）。
- **F-C**：`tests/scripts/governance/` **没有任何 CI 在跑**，本次改的 canonical 常量 CI 不会验证它。
- **F4（归因订正）**：`codeowners-config-check` 这道治理门依赖 `pip install pyyaml pytest`，装依赖失败会让一道必需检查因不相干原因变红。⚠️ 这条**不是本次引入的** —— 该安装步骤与跑 pin 测试那步都是 **PR #180** 加的；本次对该 workflow 只改了注释（diff 逐行可查）。初版验收文档把它写成「本次新引入的代价」属归因失实，已订正（code-R1 指出）。
- **F-D（＝ spec §6 的 F-D；也就是 PR #180 记的 F6）**：仓库内守卫无法自证；且**管理员对 ruleset 有 always-bypass**，所以本次改动防的是**意外**，不是防所有者刻意为之。
- **F-E（Opus R2 挖出，非本次引入）**：`integration_id` 漂移修复那条判据，**测试盖不住**。把 builder 的 `c["integration_id"] = …` 改成 `c.setdefault(…)`，`test_build_payload.py` 仍 0 failed —— 因为唯一的漂移样本 `ruleset-anysource.json` 里是**整个键缺失**，`setdefault` 恰好也能补上。换成 `integration_id: null` 或 `integration_id: 99999`（别的 app）两种真实漂移形状，好坏 builder 就分得开了。这条「防伪造同名 status」是该脚本的立身之本。**不阻断的理由**：`verify-required-checks.sh --mode assert` 独立拦得住（该档实测绿），且 live ruleset 6 条全是 15368、当前无漂移。**补法很便宜**：给 fixtures 加一条 `integration_id: 99999` 的样本。本次不做，是因为它不属本 PR 的改动面，而本 PR 已经三轮栽在「改动面写了三遍、每次漏改一两处」上。
- **F-F（Opus R2 挖出，非本次引入）**：往 canonical 清单里混进一条**没有任何 job 会产出**的 context（例如打错字的 `backend pytest (ful suite)`），必需门里的 pin 测试**全绿**；唯一会红的是 `test_build_payload.py`，而它**没有任何 CI 在跑**（即 F-C）。应用之后其后果是**全仓 PR 死锁**。spec §3.2.1 的口径是诚实的（只声称「在这一个常量上补掉一角」），但这条风险值得单独记着。
- **F-G（Opus R2 量化）**：本次把 `test_build_payload.py` 四个循环改成遍历 `REQUIRED_CONTEXTS` 之后，「清单被整体缩短」那两档变异的红数从 4 降到 2（循环跟着少转一圈，两条行为断言变空转）。**检出没有丢** —— `test_required_contexts_constant` / `test_list_contexts_cli` 两条列表相等断言仍然红，`run-all.sh` 照样 `SOME FAILED`；换来的是「builder 唯独漏掉新项」那一档从 **0 → 2**，而那才是本次真正要防的形状。spec §5.2 的 M3 行已按「红的是哪一条」订正。

## 五、执行记录（2026-09-15 ~ 09-19，逐条带证据）

| # | 结果 | 证据 |
|---|---|---|
| A1–A5 | ✅ | 干跑 diff 只新增 8 行、零删除零修改；`enforcement`/绕过名单/`pull_request` 规则逐字未变，`required_approving_review_count` 仍为 **0** |
| A2b | ✅ `6 passed` | 守卫判据 3 → 6 条 |
| **A0** | ✅ | 三个在途 PR 全含 #180。**#179 原本会被卡死**（它的检查列表里根本没有 `backend pytest (full suite)`，只有 7 项），`gh pr update-branch 179` 后变 8 项，且挂了 18 天的 `acceptance` 红**自己变绿**（纯属 base 太旧） |
| A6 | ✅ | 必需检查 **6 → 8** 项，`verify-required-checks.sh --mode assert` 退出码 0 |
| A7 | ✅ | #179 / #188 的检查列表里该项标 Required |
| A7b | ✅（但措辞已订正，见 §六） | 当时 `/tmp/apply-art/rollback-payload.json` 存在（1226 字节、7 条 context）。⛔ **回滚路径仍未实跑演练**；⚠️ 该文件**已于 5 天内被系统清理**（2026-09-23 复查：目录在、文件没了） |
| A7d / A7e | ✅ | 插 `defaults.run.shell: bash {0}` → 判据红且报「与被批准的结构不一致」；只改注释 → 仍全绿 |
| A8pre | ✅ | run 块原样抽出跑：干净树两种 shell 均 exit 0；塞一个必红测试后两种 shell 均 exit 1 |
| **A8** | ✅ **通过** | PR #192（2026-09-17，看完即关）：`gh pr checks --required` 列出 8 项且该项在内 → **唯独它 fail、其余 7 项 pass** → GitHub `mergeStateStatus=BLOCKED` → 归因 `test_a8_required_check_proof.py:6: AssertionError` / `1 failed, 1505 passed` / `FAIL: 1 个 failed —— CI 拒绝静默 skip，也拒绝红着报绿`（**正是本次加固那段运行块打的**） |

⇒ **PR #180 记下的残留 F5「后端测试全红也不阻止合并」到此闭合。**

⚠️ **应用当晚 ruleset 被写了两次**（23:13 与 23:15），非本脚本单次行为：
23:13 那次只加了 `iOS app build-for-running on macos-15`，经复核是**另一个会话在尚未包含
本 PR 的检出里跑了同一个应用脚本**（那一版 canonical 清单只有两项）。拿合并前那版 builder
对当时快照复跑，结果逐字吻合。**无害** —— 该 builder 的循环只增不删，先后顺序不影响终态；
但若将来改成「会删多余项」，旧检出跑一次就会删掉新加的必需检查。

## 六、订正：回滚凭据「唯一且易失」这个说法是错的（2026-09-23 复查）

原文把 `/tmp/apply-art/rollback-payload.json` 写成「**唯一**可用的回滚凭据」，
并把「未实跑演练」列为重点残留。复查后三条事实推翻了这个框架：

1. **它确实不持久，但这不要紧。** 2026-09-23 复查：`/tmp/apply-art/` 目录还在、
   **文件已被系统清理**（约 5 天）。若它真是唯一凭据，这里已经出事了。
2. **它可以随时重新生成。** 对 live ruleset 跑
   `build-protection-put-payload.py --normalize-only --ruleset-json <live>`
   即产出一份干净的 PUT body（实测：只读字段已剥离，顶层只剩
   `name/target/enforcement/conditions/bypass_actors/rules` 六个键）。
3. **要回到过去某个已知良好状态，GitHub 自己就存着。**
   `gh api "repos/{owner}/{repo}/rulesets/<id>/history"` 列出每次写入的时间与 actor，
   `.../history/<version_id>` 取回那一版的完整状态。本次排查「应用当晚为何被写两次」
   用的就是它。

⇒ **真正的残留只剩一条**：「这种形状的 PUT 会不会被 GitHub 接受」没有端到端演练过。
但同一个 builder 产出的**姊妹 payload**（`payload.json`，同一套字段剥离逻辑）
已于 2026-09-17 被真实 PUT 接受 ⇒ 形状基本已证。

**为什么不做实弹演练**：真演练要对分支保护**连写两次**（先降回 7 条、再恢复 8 条），
中间有窗口期主干不设防，换来的边际信息很少。**风险大于收益，明确决定不做。**
若将来非做不可，正确做法是先用 history API 记下当前 version_id 作为回退锚点。
