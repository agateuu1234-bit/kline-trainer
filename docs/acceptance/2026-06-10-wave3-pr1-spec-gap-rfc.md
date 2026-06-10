# 验收清单 — Wave 3 顺位 1 RFC（spec-gap 治理）

**PR 性质**：纯文档 governance RFC，0 业务代码（0 `.swift`/`.py`/`.sql`/`.yml`）。
**改动文件**：7 个 — RFC spec + 本 plan + `kline_trainer_modules_v1.4.md` + `kline_trainer_plan_v1.5.md` + wave3-outline + 验证脚本 + 本 acceptance。
**执行方式**：以下每项给出「操作 / 期望 / 判定」。非编码人员逐项照命令执行、对照期望勾选 ☐。

---

## 一、唯一总闸门（一条命令覆盖七谓词）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | 在仓库根运行：`bash scripts/governance/verify-wave3-pr1-rfc.sh; echo "exit=$?"` | 末尾依次打印 `(a) PASS` `(b) PASS` `(c) PASS` `(d) PASS` `(e) PASS` `(f) PASS` `(g) PASS` `ALL PASS`，且最后一行 `exit=0` | ☐ |

七谓词：(a) 七契约权威锚在位（modules + plan 各字面子串全命中）/ (b) §4.2 结算 reconcile 两锚在位（顶栏实时总资金 + 结算冻结值）/ (c) outline §3.1 supersede marker 位置（heading < marker < 首个拒臆造）/ (d) provenance 安全红线（fail-closed 禁自动删）/ (e) replay non-persisting 不变量（replay 结束后 DB 完全不变）/ (f) merge-base allowlist（仅 7 白名单文件）/ (g) 冻结历史 immutability（无 2026-05 point-in-time plan/spec 被改动）。脚本 fail-closed：源文件不可读 → `GATE FAIL: unreadable source ...` + `exit 2`；任一谓词命中失败 → `(x) FAIL` + `exit 1`；全通过才 `exit 0`。

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1b | 受限 TMPDIR 下运行（无 here-string/临时文件依赖验证）：`TMPDIR=/nonexistent-xyz bash scripts/governance/verify-wave3-pr1-rfc.sh; echo "exit=$?"` | 仍正常逐项判定，`ALL PASS` + `exit=0`（启动自检探针若迭代机制坏 → `GATE FAIL ... exit 2`，不静默 fail-open） | ☐ |

---

## 二、逐项 scope 核对（与谓词对应）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 2 | 运行：`grep -cF "currentPositionTier" kline_trainer_modules_v1.4.md` | ≥1（tier accessor 契约锚在位，§4.1 根据 modules §E5 RFC 增量块） | ☐ |
| 2b | 运行：`grep -cF "pinch/zoom panel-state mutation" kline_trainer_modules_v1.4.md` | ≥1（§4.4d pinch/zoom panel-state engine-owned mutation 契约锚在位） | ☐ |
| 3 | 运行：`grep -cF "仓位档位 X/5 派生公式" kline_trainer_plan_v1.5.md` | ≥1（plan §6.2.1 tier 派生公式权威 anchor） | ☐ |
| 4 | 运行：`grep -cF "本局实时总资金 = 现金 + 持仓市值" kline_trainer_plan_v1.5.md && grep -cF "本局结束冻结值" kline_trainer_plan_v1.5.md` | 各 ≥1（§4.2 结算 reconcile 顶栏语义锚 + 结算窗语义锚双锚在位） | ☐ |
| 5 | 运行：`grep -cF "fail-closed 禁自动删" kline_trainer_modules_v1.4.md` | ≥1（provenance 安全红线：app.sqlite 损坏禁自动删，§4.7f） | ☐ |
| 6 | 运行：`grep -cF "replay 结束后 DB 完全不变" kline_trainer_modules_v1.4.md` | ≥1（replay non-persisting 不变量，§4.4e/§4.5） | ☐ |
| 7 | 运行：`h=$(grep -nF "### 3.1 顺位 1" docs/superpowers/specs/2026-06-09-wave3-outline-design.md \| head -1 \| cut -d: -f1); m=$(grep -nF "本节契约已由顺位 1 RFC 钉死" docs/superpowers/specs/2026-06-09-wave3-outline-design.md \| head -1 \| cut -d: -f1); s=$(grep -nF "拒臆造" docs/superpowers/specs/2026-06-09-wave3-outline-design.md \| head -1 \| cut -d: -f1); echo "h=$h m=$m s=$s"; [ "$h" -lt "$m" ] && [ "$m" -lt "$s" ] && echo OK \|\| echo BAD` | 打印 `OK`（h < m < s，supersede marker 落在 §3.1 heading 紧后、首个 stale 短语之前） | ☐ |
| 8 | 运行：`grep -cF "AUTOSAVE_TICK_INTERVAL" kline_trainer_modules_v1.4.md` | ≥1（autosave 参数化常量锚，§4.6） | ☐ |
| 9 | 运行：`grep -cF "单事务 session-finalization port" kline_trainer_modules_v1.4.md` | ≥1（单事务 port anchor，§4.7b） | ☐ |
| 10 | 运行：`grep -cF "durable session key" kline_trainer_modules_v1.4.md` | ≥1（durable session key 锚，§4.7c） | ☐ |
| 11 | 运行：`grep -cF "light/dark 双 token 集" kline_trainer_modules_v1.4.md` | ≥1（夜间双集契约锚，§4.3 / modules §F2 RFC 增量块） | ☐ |

---

## 三、契约文本目视核对

在对应文件、对应节中定位契约块，目视确认 7 契约要点齐全：

| # | 定位方式 | 核对要点 | 判定 |
|---|---|---|---|
| 12 | `kline_trainer_modules_v1.4.md` 第 `#### E5 Wave 3 顺位 1 RFC 契约增量` 块 | ① `currentPositionTier` 0...5 市值基准 + round 公式；② on-demand 手动强平前置 `flow.canBuySell()` + 幂等；③ `func appendDrawing(_ drawing: DrawingObject)` append committed 画线 + 触发重渲染；④ pinch/zoom 改 `panelState.visibleCount` + clamp + focus 保持，ephemeral 不持久 | ☐ |
| 13 | `kline_trainer_modules_v1.4.md` 第 `#### E6 Wave 3 顺位 1 RFC 契约增量` 块 | ① `AUTOSAVE_TICK_INTERVAL` cadence floor + any state-dirtying mutation 触发（非仅 tick）；② replay 结束后不写 DB + `finalize` 对 replay 返 nil；③ 单事务 session-finalization port；④ `durable session key` + 幂等迁移 `ON CONFLICT` no-op；⑤ fence 拒绝终态后新 autosave；⑥ `fail-closed 禁自动删` provenance 安全红线（app.sqlite 不自动抹） | ☐ |
| 14 | `kline_trainer_modules_v1.4.md` 第 `#### F2 Wave 3 顺位 1 RFC 契约增量` 块 | `light/dark 双 token 集`：现有 13 token = dark/夜间集；新增 light 集；`displayMode == .system` 跟随 `UITraitCollection`；持久化 `display_mode`（无 schema 改动） | ☐ |
| 15 | `kline_trainer_plan_v1.5.md` 第 `#### 6.2.1 顶部信息栏` 小节内 RFC anchor 块 | 含「仓位档位 X/5 派生公式」市值/总资金基准 + round + 空仓 0/5 满仓 5/5；含「结算 vs 顶栏总资金显示语义」顶栏 = 本局实时总资金 + 结算窗 = 本局结束冻结值，标注「非 dispute」 | ☐ |
| 16 | `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` 第 `### 3.1 顺位 1` 节首 | supersede banner：注明「本节契约已由顺位 1 RFC 钉死」+ RFC doc 路径 + 2026-06-10 日期；banner 位于 heading 紧后、§3.1 原有体内「拒臆造」短语之前 | ☐ |

---

## 四、范围与边界（无越界）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 17 | 运行：`git diff --name-only "$(git merge-base origin/main HEAD)" HEAD` | 恰好 7 个文件（RFC spec + plan + modules + plan_v1.5 + wave3-outline + 验证脚本 + 本 acceptance）；无 `ios/`、无 `.swift`/`.py`/`.sql`/`.yml`/`.xcodeproj`、无 `docs/superpowers/plans/2026-05-*` 等冻结历史 doc | ☐ |
| 18 | 确认第 17 项的输出中**无** `docs/superpowers/plans/2026-05-` 或 `docs/superpowers/specs/2026-05-` 开头路径 | 无（冻结历史 point-in-time doc 未被改动，谓词 (g) 守护） | ☐ |
| 19 | 断言本 acceptance 文件无 forbidden_phrases 残留（`.claude/workflow-rules.json` 所列四组禁用措辞）：`grep -cnE "禁用措辞_A\|禁用措辞_B\|禁用措辞_C\|禁用措辞_D" docs/acceptance/2026-06-10-wave3-pr1-spec-gap-rfc.md`（将四组实际措辞替换后执行）| 0 匹配，`rc=1` | ☐ |

---

**全部 ☐ 勾选 = 本 RFC 验收完成。** 谓词由 `scripts/governance/verify-wave3-pr1-rfc.sh`（fail-closed，数组 + `-r` 断言 + per-grep rc 区分 + merge-base allowlist + IFS 行迭代无 here-string 依赖）机器化守护，第 1 项总闸门退出码即为权威判定。
