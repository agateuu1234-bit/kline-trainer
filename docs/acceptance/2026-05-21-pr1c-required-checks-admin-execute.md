# Wave 1 顺位 1c — Required-checks admin execute 验收清单

> 面向项目所有者（无代码经验）。每行：**动作** / **预期** / **通过判据**。
> 全部命令在仓库根目录终端执行。

**交付物**：对 origin `main` ruleset **确认** Catalyst required check 已配 + 绑 GitHub Actions app（防伪造）+ redacted 证据 commit + ledger H8/H10 close。**本次执行 = 路径 A（幂等 no-op，零 origin mutation）**：origin 早已合规（Catalyst check 在位且绑 `integration_id=15368`），1c 经 dry-run 确认 + assert 验证 + 取证，**未跑 `--apply`**。**1c 不改任何脚本 / 测试 / workflow / 业务代码。**

## 一、机器可检查验收（命令 + 退出码）

> **运行 #1/#1b 已自带 fail-closed gh pin + 机械退出码**：子 shell `( ... )` 内 allowlist 校验 `GH_BIN`，落 allowlist 外即 `exit 1`；末尾 `[ "$rc" -eq 0 ]` / `[ "$out" = main ]` 令进程状态机械反映断言（不被 `echo` 掩盖）。**若遇 `EOF` 网络抖动 → 重试一次**。

| # | 动作（在终端粘贴运行） | 预期 | 通过判据 |
|---|---|---|---|
| 1 | `( GH_BIN=$(command -v gh); case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL 不可信 gh:$GH_BIN" >&2; exit 1;; esac; env -u REPO -u MOCK_FIXTURE -u MOCK_LOG -u MOCK_PUT_FAIL -u MOCK_LIST_ID GH_HOST=github.com GH_CMD="$GH_BIN" bash scripts/governance/verify-required-checks.sh --mode assert --repo agateuu1234-bit/kline-trainer ); rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]` | 打印 `OK: main branch ruleset + 绑默认分支 + active + 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin`，`退出码=0` | 见 OK 且进程退 0 = 通过（= H10 谓词在 origin 真成立） |
| 1b | `( GH_BIN=$(command -v gh); case "$GH_BIN" in /opt/homebrew/bin/gh|/usr/local/bin/gh|/usr/bin/gh) ;; *) echo "FAIL 不可信 gh:$GH_BIN" >&2; exit 1;; esac; out=$(env GH_HOST=github.com "$GH_BIN" api repos/agateuu1234-bit/kline-trainer --jq '.default_branch'); echo "default_branch=$out"; [ "$out" = main ] ); rc=$?; echo "退出码=$rc"; [ "$rc" -eq 0 ]` | 打印 `default_branch=main`，进程退 0 | 进程退 0（`out`==`main`）= 通过。**与 #1 共同构成 H8/H10 close 条件** |
| 2 | `bash tests/scripts/governance/run-all.sh` | 末行 `ALL GREEN`，退出码 `0` | 见 ALL GREEN 且退出码 0 = 通过（1b 契约仍完整） |
| 3 | `{ git rev-parse --verify main >/dev/null && files=$(git diff --name-only main...HEAD -- scripts/governance tests/scripts/governance .github/workflows) && { [ -n "$files" ] && printf '%s\n' "$files"; [ -z "$files" ]; }; }; rc=$?; echo "scope 退出码=$rc"; [ "$rc" -eq 0 ]` | 无文件输出，`scope 退出码=0`，进程退 0 | 无输出 + 进程退 0 = 通过（1c 未越界改脚本/测试/workflow） |
| 4 | `git diff --name-only main...HEAD` | 仅出现 5 个 `docs/` 文件：`docs/governance/2026-05-21-pr1c-required-checks-evidence.md`、`docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`、`docs/governance/2026-05-17-wave0-signoff-ledger.md`、`docs/acceptance/2026-05-21-pr1c-required-checks-admin-execute.md`、`docs/superpowers/plans/2026-05-21-pr1c-required-checks-admin-execute.md`。**绝不含** `scripts/` `tests/` `.github/` `kline_trainer*` | 仅这 5 个 docs 文件 = 通过 |
| 5 | `out=$(grep -nE -e 'gh[pousr]_' -e 'github_pat_' -e '://[^/[:space:]@]+:[^/[:space:]@]+@' docs/governance/2026-05-21-pr1c-required-checks-evidence.md docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json); if [ -n "$out" ]; then printf '%s\n' "$out"; echo FAIL; false; else echo "no secret OK"; fi` | 打印 `no secret OK`，进程退 0 | 见 `no secret OK` 且进程退 0 = 通过（扩展 token 前缀 + basic-auth URL + fail-closed） |
| 5b | （scanner 自测，证明 fail-closed）`printf 'ghp_FAKE\ngithub_pat_FAKE\nhttps://u:p@github.com/x\n' \| grep -cE -e 'gh[pousr]_' -e 'github_pat_' -e '://[^/[:space:]@]+:[^/[:space:]@]+@'` | 打印 `3` | 打印 `3` = scanner 真能抓三类凭证 |
| 6 | `grep -cE '^\| H[0-9]+ ' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `10` | 10 条 residual 一条不少 = 通过 |
| 7 | `grep -c '✅ \*\*顺位 1c close' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `2` | H8 + H10 均 close = 通过 |
| 8 | `grep -cE 'api[^|]*branches/[^ |]*/protection.*app_id' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `0` | stale legacy 验证命令已清除 = 通过 |
| 9 | `cmp -s /tmp/pr1c-final/ruleset-snapshot.json docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json && shasum -a 256 docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`（仅本次执行后立即可验；artifact 清理后跳过） | sha256 == evidence §4 记录的 `2901c81f500bcf2270771398b75e68058ccb946f15f9d5cda2f93c1a0fd1e38e` | sha 一致 = 入仓 snapshot 与执行时产物字节相等 |

## 二、PR merge gate 真生效（GitHub 上人工确认）

| # | 动作 | 预期 | 通过判据 |
|---|---|---|---|
| 10 | 打开本 1c PR 的「Checks」页 | 含名为 `Mac Catalyst build-for-testing on macos-15` 的检查（pending/pass，非 skipped、非缺失） | 该检查在列 = 通过 |
| 11 | 看 PR 顶部 merge 区 | 在该检查为非 success 前，merge 被 required check 挡住（仅 admin 可 bypass） | merge 受 gate = 通过 |

## 三、本次执行采集到的真实证据（2026-05-22）

完整见 `docs/governance/2026-05-21-pr1c-required-checks-evidence.md` + 完整 redacted snapshot `docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json`。摘要：
- host/gh guard：`GH_BIN=/opt/homebrew/bin/gh | host=github.com auth OK | origin fetch+push=https://github.com/agateuu1234-bit/kline-trainer.git | guard OK`。
- `default_branch=main` ✅。
- dry-run：`preflight OK` + `（无变更——已是 desired 状态，幂等 no-op）` → **路径 A，零 mutation，未跑 `--apply`**。
- live assert：`OK: ... 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin`，退出码 0。
- 最终态 snapshot sha256 `2901c81f500bcf2270771398b75e68058ccb946f15f9d5cda2f93c1a0fd1e38e`；origin `main` ruleset：enforcement=active、绑 `~DEFAULT_BRANCH`、bypass 仅 admin（actor_id=5）、11 条 required check 全绑 `integration_id=15368`（含 Catalyst）。
- 执行 HEAD（clean script-tree）：`9edb7c02efd96478ac03e810f60d52fde74de276`。

## 四、已知 residual（不阻塞本交付）

- **`~DEFAULT_BRANCH` 脚本层未 live 核实**（1b branch-diff R4）：1c 已在本次执行加 live `default_branch == main` 断言，**为本次执行**证明假设成立；脚本层完整修（live 查 + offline `--default-branch` 参数）归 1b 脚本 backlog，不在 1c scope（1c 不改脚本）。
- **真 mutation（Path B）的 pre-PUT payload 绑定**：本仓本次为 no-op 故未触发；若将来 origin 漂移需真 `--apply`，须先在 1b 给 runbook 加 `--expected-payload-sha` pre-PUT 绑定 + `--hostname` host pin，再以新一轮 1c 执行（grounding #13）。

## 五、评审记录

- plan-stage codex 对抗性 review **13 轮**逐条真 finding 全修（R1-R4 架构 / R5-R13 信任边界 + shell 加固）+ 本地实测捕获 zsh `$P` 假绿 bug；命中 governance-runbook permanent edge-mining（同 PR #1b），2026-05-21 user explicit TTY override 收口 plan-stage（见 plan「Plan-stage codex 收敛记录」）。
- subagent-driven 实施（user-gated origin 命令 → inline 降级，per workflow-rules degradation_policy；每文档 task 走 spec + code-quality 两段 review）。
- 整体 branch-diff codex 对抗性 review（收敛轮数 merge 前回填）。

> 禁忌词自查：本清单已规避 `.claude/workflow-rules.json` `forbidden_phrases` 所列的全部模糊判据用语（无任何此类含糊措辞，判据均为二元可判定）。
