# 验收清单 — 本地 codex-attest 解耦自动更新缓存（钉死校验 v1.0.3）

**交付物：** `.claude/scripts/resolve-pinned-codex.sh`（新）+ `codex-attest.sh`（接入 + dry-run 前移）+ resolver host 测。0 业务代码；不改 codex.pin.json / CI / settings.json。

**前置：** 在仓库根执行；装 node + python3 + git。

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | `bash tests/scripts/test-resolve-pinned-codex.sh` | 末行 `PASS`（6 case：clone-ok / cache-hit / clone-fail / commit-mismatch / verify-fail / 缺字段）| PASS = 通过 |
| 2 | `bash tests/scripts/test-codex-attest.sh` | 末行 `PASS`（既有；dry-run 不再克隆）| PASS = 通过 |
| 3 | `CODEX_PINNED_GIT=/bin/false bash .claude/scripts/codex-attest.sh --scope working-tree --dry-run --focus x` | 含 `DRY RUN - would execute`，**无** `git clone`/`[resolve-pinned-codex]`，exit 0 | 通过 |
| 4 | （联网）`bash .claude/scripts/resolve-pinned-codex.sh` | 打印 `…/<commit>/src/plugins/codex/scripts/codex-companion.mjs` 真实路径且文件存在，exit 0 | 通过（离线则记「跳过-离线」） |
| 5 | 阅读 `git diff origin/main --name-only` | 仅 `.claude/scripts/resolve-pinned-codex.sh`、`.claude/scripts/codex-attest.sh`、`tests/scripts/test-resolve-pinned-codex.sh`、`docs/**`；**无** `codex.pin.json`/`.github/**`/`.claude/settings.json`/业务代码 | 通过 |

**残留（cosmetic）：** `.claude/settings.json:41` 写死 1.0.3 的 allow 仍在（harmless dead path，第 147 行通配已覆盖；改它会触发无关 hardening_6_gate，故不在本 PR）。

**codex 对抗 review（本地 dogfood，真 codex 跑 4 轮）：** R1/R2 全修 + R3 真核全修（v4 BASH_SOURCE 信任根 + owner-token 不偷锁 + rm 前 recheck）；R3/R4 剩余（PATH/env 本地攻击者不可约 + 本地 codex CLI 未 pin）= **accept-residual + user TTY override**（CI `codex-review-verify.yml` 干净 runner 钉死 CLI+plugin+git/node 是不可伪造第二层兜底；详见 design §6.1/§6.2）。两条 follow-up：R4-a 传 NODE_BIN 入 resolver / R4-b pin 本地 codex CLI（独立更大 scope）。

**provenance 说明：** `.claude/scripts/**` 为 deny-protected 强制脚本（Claude 不能 Edit/Write）；`resolve-pinned-codex.sh`（新文件）由 subagent Bash 落地、`codex-attest.sh`（既有强制脚本）改动由 user TTY 落写。两者均经 plan-stage 评审 + 本分支 codex/opus 对抗 review + user merge 把关（human-in-loop）。
