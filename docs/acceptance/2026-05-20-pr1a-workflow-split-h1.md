# PR 1a 验收清单 — Catalyst CI workflow split + H1 reclassify

> 面向非编码者：逐条照做，把每条「实际结果」与「预期」对比，勾选「通过 / 不通过」。任一条不通过 → 不合并，退回修复。

## 一、Workflow split（解 H9）

| # | 动作（在仓库根目录终端执行） | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | 运行 `actionlint .github/workflows/catalyst-build.yml .github/workflows/swift-contracts-smoke.yml 2>&1 | grep -c 'shellcheck reported issue'`（actionlint 未装则先 `brew install actionlint`） | 打印 `1`（仅 1 条 pre-existing SC2010 `ls\|grep` 警告，随 job 字节级平移而来，本 PR 无新增 finding、无 schema error） | ☐ |
| 2 | 运行 `grep -F 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/catalyst-build.yml` | 打印出该行（job 名未改 → required check 不破） | ☐ |
| 3 | 运行 `grep -c 'paths:' .github/workflows/catalyst-build.yml` | 打印 `0`（新 workflow 无 paths filter → 每个 PR 都会跑） | ☐ |
| 4 | 运行 `grep -c 'catalyst-build:' .github/workflows/swift-contracts-smoke.yml` | 打印 `0`（旧文件已移除该 job，无重复定义） | ☐ |
| 5 | 运行 `grep -rh 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/ | wc -l` | 打印 `1`（全仓恰好一个 job 用该 name → required-check 信号不歧义） | ☐ |
| 6 | **（权威 H9 证明，push 后）** 运行 `gh pr checks <本 PR 号>`（或看 PR「Checks」页） | 列表含名为 `Mac Catalyst build-for-testing on macos-15` 的检查且状态是 pending/pass（**不是** skipped、**不是** 缺失） | ☐ |

## 二、H1 spec amendment（modules §C1b 闸门 #4）

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 7 | 运行 `grep -c 'production handler 集成测试移 Wave 2' kline_trainer_modules_v1.4.md` | 打印 `1` | ☐ |
| 8 | 运行 `grep -c 'production handler 集成测试移 Wave 1' kline_trainer_modules_v1.4.md` | 打印 `0`（旧 Wave 1 措辞已清除，无内部矛盾） | ☐ |
| 9 | 运行 `grep -c '\*\*Wave 2 验收\*\*（C8 ChartContainerView + E5 TrainingEngine' kline_trainer_modules_v1.4.md` | 打印 `1` | ☐ |

## 三、§15.4 ledger sync

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 10 | 运行 `grep -c 'reclassify Wave 1→Wave 2' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `1`（H1 行已 reclassify） | ☐ |
| 11 | 运行 `grep -c '✅ 顺位 1a 决议（option B）' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `1`（H9 行已标记已解） | ☐ |
| 12 | 运行 `grep -cE '加 .catalyst-build|断言含 .catalyst-build' docs/governance/2026-05-17-wave0-signoff-ledger.md`（`.` 通配反引号，避免转义；修订前此命令返回 `2`，修订后返回 `0`） | 打印 `0`（H8/H10 不再让 admin 把 job key `catalyst-build` 当 context；已改为 job name） | ☐ |
| 13 | 运行 `grep -cE '^\| H[0-9]+ ' docs/governance/2026-05-17-wave0-signoff-ledger.md` | 打印 `10`（10 条 residual 一条不少，未误删） | ☐ |

## 四、范围隔离

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 14 | 运行 `git diff --name-only main...HEAD`（或在 PR「Files changed」页看） | 仅出现：`.github/workflows/catalyst-build.yml`、`.github/workflows/swift-contracts-smoke.yml`、`kline_trainer_modules_v1.4.md`、`docs/governance/2026-05-17-wave0-signoff-ledger.md`、`docs/acceptance/2026-05-20-pr1a-workflow-split-h1.md`、`docs/superpowers/plans/2026-05-20-pr1a-workflow-split-h1-amendment.md`；**不含** `scripts/governance/verify-freeze-tag.sh` | ☐ |

## 证据留存

把第 1-5、7-14 条命令输出截图 / 文本，连同第 6 条 `gh pr checks` 输出，贴到 PR 评论区。
