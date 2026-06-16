# Wave 3 账本 reconciliation —— 非-coder 验收 checklist

**PR**：Wave 3 治理收尾——把账本对齐到代码现状（W3-11-R1 bounce live 接线由 #117 实现 + #120 drag 橡皮筋）。翻 `feature-completeness PENDING→COMPLETE` + `residual-W3-11-R1 OPEN→CLOSED`，同步 verify 脚本 + completion 叙述九句 + runtime-matrix bounce 转 device 行；**保留** formal-closure/store-ready/runtime-matrix/freeze/ship 门全 pending。0 业务代码 / 0 CI / 0 ruleset。

**Spec**：`docs/superpowers/specs/2026-06-16-wave3-ledger-reconcile-design.md`（v1.3，opus R1→R2→R3 APPROVE）。
**Plan**：`docs/superpowers/plans/2026-06-16-wave3-ledger-reconcile.md`（opus R1 APPROVE）。

> 操作均在 worktree 根目录执行；判据为二元（满足=通过 / 不满足=不通过）。

| # | 操作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| 1 | `bash scripts/governance/verify-wave3-completion.sh; echo $?` | 末行打印 `PASS：…`；`$?` = `0` | ☐ |
| 2 | `grep -cE "^feature-completeness: COMPLETE$" docs/governance/2026-06-14-wave3-completion.md` | 输出 `1`（feature 门已翻 COMPLETE） | ☐ |
| 3 | `grep -cE "^residual-W3-11-R1-bounce-live-wiring: CLOSED W3-11-R1 #117$" docs/governance/2026-06-14-wave3-completion.md` | 输出 `1`（W3-11-R1 residual 已 CLOSED #117） | ☐ |
| 4 | `for p in "^store-ready: NO$" "^formal-closure: PENDING-runtime-matrix-device-record$" "^runtime-matrix: PARTIAL$" "^freeze-tag: NOT-TAGGED$" "^ship-gate-PR11-R1-prod-backend-url: OPEN$" "^ship-gate-W1-R2-sample-data: OPEN$"; do grep -cE "$p" docs/governance/2026-06-14-wave3-completion.md; done` | 6 行各输出 `1`（关闭/上架/冻结/NAS 门**全未被误翻**，仍 pending） | ☐ |
| 5 | `grep -n -e "feature-completeness: PENDING-W3-11-R1" -e "residual-W3-11-R1-bounce-live-wiring: OPEN" docs/governance/2026-06-14-wave3-completion.md` | **无输出**（机器块旧 PENDING/OPEN 值已无残留；用 `-e` 多模式避免 ERE `\|` 字面竖线假 PASS） | ☐ |
| 6 | `grep -c "8 项：6 数据交互" docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | 输出 `1`（device 矩阵标题 7→8） | ☐ |
| 7 | `grep -c "^| 11 | 边缘 bounce" docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | 输出 `1`（bounce 已列 device 矩阵第 8 行，顺位 11） | ☐ |
| 8 | `git diff --name-only origin/main...HEAD -- ':!docs/superpowers'` | 仅账本 3 文件：`docs/governance/2026-06-14-wave3-completion.md`、`docs/acceptance/2026-06-14-wave3-runtime-matrix.md`、`scripts/governance/verify-wave3-completion.sh`（spec/plan/本 acceptance 在 docs/superpowers 已排除） | ☐ |
| 9 | `git diff origin/main...HEAD -- ios/ .github/` | **无输出**（三 0 改动：0 业务代码 / 0 CI；本仓无独立 ruleset 文件，ruleset 在 GitHub 侧未动） | ☐ |
| 10 | `cd ios/Contracts && swift test 2>&1 \| tail -1` | `Test run with 1085 tests in 149 suites passed`（doc/script PR 不影响 host 测，与 baseline 同） | ☐ |
| 11 | 人工查 `.claude/workflow-rules.json` forbidden phrases，对本 acceptance + 改动文件 grep | 无 forbidden phrase 命中 | ☐ |

## 评审 APPROVE 落账（opus 4.8 xhigh 对抗性 review 代 codex，per user 指示）
- **Spec review R1（NEEDS-ATTENTION：1 High §一L4 漏枚举 + 2 Med §二L68/L74·§五L114/L118 + 2 Low）→ R2（NEEDS-ATTENTION：2 High 同类穷尽性遗漏 §二L72 + §三表L86）→ R3 = APPROVE**：R3 per-hit 穷尽性表覆盖三文件 11 token，category-(b)（反转未覆盖）= 空；verify gate 结构守卫不破、翻转值 byte-match、无 scope creep、冻结 spec §E.2 保留。
- **Plan review R1 = APPROVE**：reviewer **实证 gate PASS**（拷贝三文件套用 4 编辑跑 gate → exit 0）+ Task 3 不删任何 gate-grep 指针 + 九句 list 与 spec §二.1 逐字一致 + host 测不受影响。0 C/H，2 Low 非阻塞。
- **实施 verification**：verify gate PASS；honesty 反向断言 8/8 各 1 命中（2 翻转正值 + 6 keep-pending）；机器块旧值 0 残留；matrix 8 项 + bounce 第 8 行；host 1085/149/0。
- **两阶段 review + final overall opus review**：见 PR。
- **评审通道**：改 `docs/**` + `scripts/governance/verify-wave3-completion.sh`（trust-boundary）→ codex 配额耗尽 → opus 4.8 xhigh 代 `codex:adversarial-review`；merge 经 user TTY `attest-override` + `--admin` bypass 缺失 `codex-verify-pass`。

## 仍 OPEN（本 PR **不**触碰，如实保留）
- **device 实测**：runtime-matrix 8 行 device pass/fail 全留空 + Wave 2 两份 runbook（c8b/u2-gesture）+ Instruments 帧预算 <4ms（os_signpost #119 机制就绪）——user device 职责。
- **NAS ship 门**：PR11-R1（生产 backendBaseURL）、W1-R2（真实样本数据）。
- **formal-closure / freeze tag**：gated on 上述 device 回填 + NAS。本 PR 仅翻**功能完成门**，不宣布关闭/上架/冻结。
