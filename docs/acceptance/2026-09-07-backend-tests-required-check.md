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
| A1 | 把 PR 的改动文件列表与 spec §4 那张改动面表逐行对照 | 两边一一对应，PR 里没有表外的文件。表里**有且只有一个** `.github/workflows/` 文件（`codeowners-config-check.yml`），打开它确认**只改了注释** —— 若 `on:`、job 名或任何 `run:` 步骤被动过，判**不通过** | |
| A2 | 在 worktree 里跑 `bash tests/scripts/governance/run-all.sh` | 最后一行是 `ALL GREEN`，全文**没有** `FAIL:` 行 | |
| A2b | 从仓库根跑 `python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py` | `5 passed` | |
| A3 | 跑 `python3 scripts/governance/build-protection-put-payload.py --list-contexts` | 打印出**三项**，其中一项逐字是 `backend pytest (full suite)` | |
| A4 | 把那三项与 GitHub 网页上「必需检查」列表对照（**应用之前**） | 三项里有**两项还不在**网页上（后端测试、iOS 构建）—— 这正是待应用的差异 | |
| A5 | 看下面「§二 干跑凭据」那份 diff | 只有新增行、**没有任何删除或修改行**；只多出 2 条 context | |
| A7c | 临时把 `.github/workflows/backend-tests.yml` 里 `name: backend pytest (full suite)` 改掉一个字母，重跑 A2b | 必须**变红**（守的是「改名 → 全仓 PR 卡死」）。改回原名后重新全绿 | |

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
| A7b | 看脚本打印的 artifact 目录 | 里面**真的有** `rollback-payload.json` —— 它是唯一可用的回滚凭据（见 spec §9；**该路径未实跑演练过**） | |
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

- **F-A**：canonical 清单**无人守** —— `verify-required-checks.sh` 没有任何 workflow 在跑。
- **F-B**：`branch-protection-config-self-check` 是**永不失败**的橡皮图章（只打印警告 + 无条件退出成功；且读旧版 API，实测本仓恒 404）。
- **F-C**：`tests/scripts/governance/` **没有任何 CI 在跑**，本次改的 canonical 常量 CI 不会验证它。
- **F4 新引入的代价**：`codeowners-config-check` 这道治理门从此依赖 `pip install pyyaml pytest`，装依赖失败会让一道必需检查因不相干原因变红。
- **F6**：仓库内守卫无法自证（PR #180 已记）；且**管理员对 ruleset 有 always-bypass**，所以本次改动防的是**意外**，不是防所有者刻意为之。
