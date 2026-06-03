# 验收清单 — Wave 2 顺位 1 RFC（baseline reconciliation + H1 闭环 + P6 两层恢复契约）

**PR 性质**：纯文档 governance RFC，0 业务代码（0 `.swift`/`.py`）。
**改动文件**：9 个 — RFC spec + 本 plan + `kline_trainer_modules_v1.4.md` + wave0 ledger + wave1-completion + wave1-outline + wave2-outline + 本 acceptance + `scripts/governance/verify-wave2-pr1-rfc.sh`。
**执行方式**：以下每项给出「操作 / 期望 / 判定」。非编码人员逐项照命令执行、对照期望勾选 ☐。

---

## 一、唯一总闸门（一条命令覆盖六谓词）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | 在仓库根运行：`bash scripts/governance/verify-wave2-pr1-rfc.sh; echo "exit=$?"` | 末尾依次打印 `(a) PASS` `(b) PASS` `(c) PASS` `(d) PASS` `(e) PASS` `(f) PASS` `ALL PASS`，且最后一行 `exit=0` | ☐ |

脚本为 fail-closed：源文件不可读 → 打印 `GATE FAIL: unreadable source ...` 并 `exit 2`；任一谓词命中残留 → 对应 `(x) FAIL` 并 `exit 1`。仅当全部六谓词通过才 `exit 0`。

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1b | 不可写 TMPDIR 下运行（模拟受限沙箱，codex 最终 review FR1）：`TMPDIR=/nonexistent-xyz bash scripts/governance/verify-wave2-pr1-rfc.sh; echo "exit=$?"` | 仍正常逐项判定（脚本用 `IFS=换行 + noglob` for-loop，无 here-string/临时文件依赖；启动自检探针若迭代机制坏 → `GATE FAIL ... exit 2`）——不会因临时目录不可写而静默 fail-open | ☐ |

---

## 二、逐项 scope 核对（与谓词对应）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 2 | 运行：`grep -nE "同 PR" kline_trainer_modules_v1.4.md docs/governance/2026-05-17-wave0-signoff-ledger.md docs/governance/2026-06-01-wave1-completion.md docs/superpowers/specs/2026-05-19-wave1-outline-design.md \| grep -vE "decoder\|顺位 8\|CONTRACT_VERSION\|position_data\|三连而非"` | 无输出（4 个 live 权威源已无 H1「同 PR」残留；E2 顺位 8 的「同 PR」被排除项保留） | ☐ |
| 3 | 运行：`grep -nE "^- \[ \].*(P4 .DefaultAppDB. 实现\|4 内部端口默认实现)" kline_trainer_modules_v1.4.md` | 无输出（§Wave 2 checklist 不再把 P4/P2 端口列为未勾选待办） | ☐ |
| 4 | 运行：`grep -nF "C8 / E5 / E6 / P2 / P4 / U1" docs/governance/2026-06-01-wave1-completion.md` | 无输出（§五旧边界串已 reconcile 为「P2 runner」） | ☐ |
| 5 | 运行：`grep -nE "snapshotFees" kline_trainer_modules_v1.4.md \| grep -vE "snapshotFeesIfReady\|fail-open\|UI 显示" \| grep -E "startNewNormalSession\|NormalFlow.fees\|打包"` | 无输出（交易/费用打包指引均已改 `snapshotFeesIfReady` fail-closed；含 L2000/L2040/risk-table R36 两行） | ☐ |
| 6 | 运行：`grep -nF "func retryReload() async throws" kline_trainer_modules_v1.4.md` 与 `grep -nF "func forceResetAndReload(confirmation: SettingsResetConfirmation) async throws" kline_trainer_modules_v1.4.md` | 各命中 1 行（P6 §协议两层恢复方法签名在位；破坏性方法带 confirmation 参数，非无参） | ☐ |
| 7 | 运行：`grep -nF "本节措辞已 superseded" docs/superpowers/specs/2026-06-02-wave2-outline-design.md` | 命中 1 行，且该行位于 `### 3.1` 标题之后、首个「落地时同 PR 内」之前（后续 anchor 规划者先读到 supersede 标记） | ☐ |

---

## 三、P6 两层恢复契约文本核对（目视）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 8 | 在 `kline_trainer_modules_v1.4.md` §P6 找到「P6 loadError 两层恢复契约」prose 块，目视核对 | 含：① `retryReload()` 非破坏（重读保留真实设置，失败置 `_retryReloadFailed`）；② `forceResetAndReload(confirmation:)` 破坏性，**三重守卫** `loadError != nil` + `_retryReloadFailed == true` + **`loadError` 是 `.persistence(.dbCorrupted)`**（transient `.diskFull`/`.ioError`/`.schemaMismatch` → throws retry-only）；破坏前 **`do { try loadSettings() }`**：成功则不写默认，`catch` **仅 final 也 dbCorrupted 才 saveSettings(default)**，否则更新 loadError + throws 不破坏；健康态两者 throws 不改 settings | ☐ |
| 9 | 在 RFC spec `docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md` §四查 acceptance 列表 | 含 **9** 条验收场景：transient 恢复（retryReload）/ persistent dbCorrupted / 健康态 / 未先 retryReload 直接破坏 / 入口 dbCorrupted 但破坏前可读 / **transient 未恢复（非 dbCorrupted）throws 不破坏** / persistent corruption 写默认 / **混合错误（入口 dbCorrupted 破坏时刻变 transient）throws 不破坏** / 破坏写失败 | ☐ |

---

## 四、范围与边界（无越界）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 10 | 运行：`git diff --name-only "$(git merge-base origin/main HEAD)" HEAD` | 恰好 9 个文件（见文首清单）；无 `ios/`、无 `.swift`/`.py`/`.sql`/`.yml`、无 `kline_trainer_plan_v1.5.md`、无 `docs/superpowers/plans/2026-05-*` 等冻结历史 | ☐ |
| 11 | 运行：`grep -nF "同 PR" kline_trainer_modules_v1.4.md \| grep "1494"` | 命中 L1494（E2 顺位 8 bump 的「同 PR」**保留未动**，证明只改 H1 相关、未误伤 E2） | ☐ |

---

**全部 ☐ 勾选 = 本 RFC 验收完成。** 谓词由 `scripts/governance/verify-wave2-pr1-rfc.sh`（fail-closed，数组+`-r`断言+per-grep rc 区分+merge-base allowlist）机器化守护，第 1 项总闸门退出码即为权威判定。
