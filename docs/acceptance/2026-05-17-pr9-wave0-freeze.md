# PR 9 验收清单 — Wave 0 契约冻结 ceremony

> 这份清单给非-coder 用户用：复制每一行"action"到 Claude Code 或 Terminal，对照"expected"判断 pass / fail。

## A. 文件落地

| # | action | expected | pass_fail |
|---|---|---|---|
| A1 | `grep -c "Wave 1 验收" kline_trainer_modules_v1.4.md` | ≥ 1（spec §6 C1b L1167 修订落地；spec 实际是 markdown bold `**Wave 1 验收**`） | ☑ |
| A2 | `grep -c "23 M0.3 类型" kline_trainer_modules_v1.4.md` | ≥ 1（§M0.3 inventory 表落地） | ☑ |
| A3 | `python3 -c "import yaml; print(list(yaml.safe_load(open('.github/workflows/swift-contracts-smoke.yml'))['jobs'].keys()))"` | 输出 `['swift-test', 'catalyst-build']` | ☑ |
| A4 | `ls docs/governance/2026-05-17-wave0-signoff-ledger.md` | 文件存在 | ☑ |
| A5 | `ls docs/governance/wave1-plan-template.md` | 文件存在 | ☑ |
| A6 | `grep -c "Wave 0 契约冻结 v1.4" README.md` | ≥ 1 | ☑ |
| A7 | `test -x scripts/governance/verify-freeze-tag.sh && echo OK` | 输出 `OK`（脚本可执行） | ☑ |

## B. 编译验证（spec amendments + governance docs 不影响代码）

| # | action | expected | pass_fail |
|---|---|---|---|
| B1 | `cd ios/Contracts && swift build` | 输出 `Build complete!`，无 error 无 warning | ☑ |
| B2 | `cd ios/Contracts && swift test 2>&1 \| tail -3` | 末尾出现 `Test run with 297 tests in 63 suites passed`（与 PR #53 baseline 一致；本 PR 0 业务代码改动） | ☑ |

## C. Ledger 完整性（10 residuals H1-H10）

| # | action | expected | pass_fail |
|---|---|---|---|
| C1 | `grep -c "H\([1-9]\|10\)" docs/governance/2026-05-17-wave0-signoff-ledger.md` | 至少 11（H1-H10 各出现 ≥ 1 次） | ☑ |
| C2 | `grep "## .*sign-off" docs/governance/2026-05-17-wave0-signoff-ledger.md` | 输出 3 行：后端代表 / iOS 代表 / 数据代表 | ☑ |
| C3 | `grep -c "Provenance" docs/governance/2026-05-17-wave0-signoff-ledger.md` | ≥ 1（codex R1 finding 1 修订标记） | ☑ |
| C4 | `grep -F "(PR 9 squash commit SHA" docs/governance/2026-05-17-wave0-signoff-ledger.md` | 空输出（ledger 不含 SHA 占位符；codex R1 finding 1 修） | ☑ |

## D. CI（GitHub Actions）

| # | action | expected | pass_fail |
|---|---|---|---|
| D1 | `gh pr checks <pr_number>` | 7/7 checks SUCCESS（含新 catalyst-build job） — 或 OpenAI quota fail 走 admin bypass per memory `feedback_openai_quota_ci_pattern` | ☐ 待 push 后跑 |

## E. Tag 三层 blocking gate（PR 9 merge 之后跑，mirror spec §5.6）

> ⚠️ 本节在 **PR 9 merge 之后**单独跑，不在 PR 9 commits 内。**整段保持 `set -euo pipefail`** strict mode。任一 `exit 1` 失败 = freeze ceremony fail，回查诊断。

```bash
set -euo pipefail

# 前置 0：auto-detect 真实 GitHub PR number（不能硬码 9）
BRANCH="pr9-wave0-freeze"
PR_NUMBER=$(gh pr list --repo agateuu1234-bit/kline-trainer --head "$BRANCH" --state merged --json number --jq '.[0].number')
[ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ] || { echo "FAIL: 找不到 branch $BRANCH 的已 merge PR"; exit 1; }
echo "Detected actual GitHub PR #$PR_NUMBER"
EXPECTED_SHA=$(gh pr view "$PR_NUMBER" --repo agateuu1234-bit/kline-trainer --json mergeCommit --jq '.mergeCommit.oid')
[ -n "$EXPECTED_SHA" ] && [ "$EXPECTED_SHA" != "null" ] || { echo "FAIL: PR #$PR_NUMBER mergeCommit"; exit 1; }
git fetch origin main
LOCAL_MAIN=$(git rev-parse origin/main)
[ "$LOCAL_MAIN" = "$EXPECTED_SHA" ] || { echo "FAIL: origin/main HEAD != PR #$PR_NUMBER squash SHA"; exit 1; }
TAG_COMMIT="$EXPECTED_SHA"

# 层 1：protected tag namespace 完整谓词检查（显式 || exit 1，set -e 已防呆，双保险）
./scripts/governance/verify-freeze-tag.sh --ref "refs/tags/wave0-frozen-v1.4" || { echo "FAIL: 层 1 protected ruleset"; exit 1; }

# Tag 创建（优先 signed，fallback unsigned）
if git tag -s wave0-frozen-v1.4 \
    -m "Wave 0 契约冻结 v1.4：17 业务模块 + M0 契约 + §15.4 三方签字 ledger" \
    "$TAG_COMMIT" 2>/dev/null; then
  TAG_SIGNED=1
else
  echo "WARN: GPG/SSH signing 未配，fallback annotated"
  git tag -a wave0-frozen-v1.4 -m "Wave 0 契约冻结 v1.4" "$TAG_COMMIT" || { echo "FAIL: annotated tag 创建"; exit 1; }
  TAG_SIGNED=0
fi

# 层 2：本地 signed verify + 本地 peeled SHA pre-check（push 前本地拦截 fail）
if [ "$TAG_SIGNED" = "1" ]; then
  git verify-tag wave0-frozen-v1.4 || { echo "FAIL signed verify (push 前本地)"; git tag -d wave0-frozen-v1.4; exit 1; }
fi
LOCAL_PEELED=$(git rev-parse "wave0-frozen-v1.4^{}")
[ "$LOCAL_PEELED" = "$EXPECTED_SHA" ] || { echo "FAIL local peeled != EXPECTED"; git tag -d wave0-frozen-v1.4; exit 1; }

# Push 到 remote (set -e + 显式 || exit 双保险)
git push origin wave0-frozen-v1.4 || { echo "FAIL: git push tag"; exit 1; }

# 层 3：remote peeled SHA 反查（codex R4 finding 1 + R2 finding 2 修：用 ^{} peeled，不用 .object.sha）
REMOTE_PEELED=$(git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}" | awk '{print $1}')
[ -n "$REMOTE_PEELED" ] || { echo "FAIL: remote peeled SHA 拿不到"; exit 1; }
[ "$REMOTE_PEELED" = "$EXPECTED_SHA" ] || { echo "FAIL remote peeled != EXPECTED"; exit 1; }

echo "GATE PASS: tag wave0-frozen-v1.4 三层验证全过"
```

| # | action | expected | pass_fail |
|---|---|---|---|
| E1 | 跑完上面命令链 | 末尾 `GATE PASS: tag wave0-frozen-v1.4 三层验证全过`；无 FAIL | ☐ 待 PR merge 后跑 |
| E2 | `git tag -l 'wave0-frozen-*'` | 输出 `wave0-frozen-v1.4` | ☐ 待 PR merge 后跑 |
| E3 | `git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}" \| awk '{print $1}'` | 输出 = `$EXPECTED_SHA`（PR 9 squash commit） | ☐ 待 PR merge 后跑 |

## F. Scope 边界（不应做的事）

| # | action | expected | pass_fail |
|---|---|---|---|
| F1 | `git diff main -- ios/Contracts/Sources/` | 输出为空（不动业务代码） | ☑ |
| F2 | `git diff main -- ios/Contracts/Tests/` | 输出为空（不动测试） | ☑ |
| F3 | `git diff main -- ios/Contracts/Package.swift` | 输出为空（不动 SwiftPM manifest） | ☑ |

## G. 文档

| # | action | expected | pass_fail |
|---|---|---|---|
| G1 | `ls docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md` | 文件存在 | ☑ |
| G2 | `ls docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md` | 文件存在 | ☑ |
| G3 | `ls docs/acceptance/2026-05-17-pr9-wave0-freeze.md` | 文件存在（本文件） | ☑ |

## H. 后续 admin 手动步骤（PR 9 merge 之后 + tag 之前）

| # | action | expected | pass_fail |
|---|---|---|---|
| H8 | GitHub repo Settings → Rules → New tag ruleset：name `wave0-frozen-protected` / target ref_name include `wave0-frozen-*` / enforcement Active / Rules ✅ Restrict creations + Updates + Deletions / Bypass actors Repository admin only | UI 配置完成 | ☐ 待 PR merge 后 admin 手动 |
| H8' | `gh api repos/agateuu1234-bit/kline-trainer/branches/main/protection --jq '.required_status_checks.contexts'` 含 `catalyst-build` | 输出 array 含 `catalyst-build`；如不含 admin 在 Settings → Branches → main edit required status checks | ☐ 待 PR merge 后 admin 手动 |
