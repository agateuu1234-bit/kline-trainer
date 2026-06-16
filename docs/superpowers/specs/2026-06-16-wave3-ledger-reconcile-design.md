# Wave 3 账本 reconciliation（W3-11-R1 关门 + feature-completeness flip）—— 设计文档 v1

**日期**：2026-06-16
**性质**：Wave 3 **治理收尾 reconciliation**（doc + 治理脚本，**trust-boundary**）。把 Wave 3 完成账本对齐到已 merged 的代码现状——W3-11-R1（边缘 bounce live 接线）已由 **PR #117（R1b-wire）** 实现、**PR #120（R1b-drag）** 补拖拽期橡皮筋；而 `WAVE3-STATUS` 机器块 + `verify-wave3-completion.sh` + runtime-matrix 仍断言它 `OPEN` / `feature-completeness: PENDING-W3-11-R1`。本 PR **仅翻转已被代码兑现的两项门**，**不**触碰任何仍真实 pending 的关闭/上架/冻结门。改 `docs/**` + `scripts/governance/*.sh`（trust-boundary）→ 经 **`codex:adversarial-review`**（配额耗尽 fallback opus 4.8 xhigh）。

**授权来源（本 PR 形状由前序治理决定，非新发明）**：
- R1b-wire spec（`docs/superpowers/specs/2026-06-16-w3-11-r1b-wire-design.md` §九 ledger-B）：「`feature-completeness: PENDING-W3-11-R1` 翻转 + 矩阵 bounce 行转 device 行**留收尾 reconciliation PR**」——本 PR 即该收尾 PR。
- R1b-wire（#117）用 ledger-B 模式**故意不碰** `wave3-completion.md`，把账本翻转 deferred 至本 PR。

**前置（已满足）**：#117 `c7feea8`（bounce live 接线）+ #120 `c22fa81`（drag 橡皮筋）均 merged。本分支 `worktree-wave3-ledger-reconcile` off `origin/main`（`c22fa81`）。

---

## 一、问题：账本滞后于代码

`origin/main`（`c22fa81`）的 `WAVE3-STATUS` 机器块 + `verify-wave3-completion.sh`（fail-closed grep gate）+ runtime-matrix 仍把 **W3-11-R1（bounce live 接线）标 `OPEN`**、**`feature-completeness: PENDING-W3-11-R1-bounce-live-wiring`**、并在 runtime-matrix「排除/OPEN 节」把 bounce 排除出 device 矩阵（理由：「真 app 无可见回弹运行时」）。

但 **#117（R1b-wire）的明确目的就是关闭此门**——其 header：「把已就绪的 bounce 物理接进真 app 的手势/渲染管线，使甩动到最老边 → 弹簧 overscroll+回弹可见。**关闭功能门 feature-completeness: PENDING-W3-11-R1**」。#120（R1b-drag）进一步补「拖过最老边带阻尼跟手 + 松手回弹」。故 W3-11-R1「真 app 无可见回弹」的前提**已不成立**。

**本 PR 任务**：把这两项**已被代码兑现**的门如实翻转，并据 R1b-wire spec §九 把 runtime-matrix 的 bounce 从「排除」转为 **device happy-path 行**（供用户实测回填）。

---

## 二、范围：精确翻什么 / 精确保留什么

### 翻转（已被 #117/#120 兑现）
| 触点 | 旧 | 新 |
|---|---|---|
| `WAVE3-STATUS` `residual-W3-11-R1-bounce-live-wiring` | `OPEN` | `CLOSED W3-11-R1 #117` |
| `WAVE3-STATUS` `feature-completeness` | `PENDING-W3-11-R1-bounce-live-wiring` | `COMPLETE`（本 PR 推荐值；user 审 spec 时确认） |
| `verify-wave3-completion.sh` L50 `require_kv` | `"OPEN"` | `"CLOSED W3-11-R1 #117"` |
| `verify-wave3-completion.sh` L58 `require_kv` | `"PENDING-W3-11-R1-bounce-live-wiring"` | `"COMPLETE"` |
| verify 脚本注释（L6/L8/L9）+ 末行 echo（L73） | 述「W3-11-R1 OPEN / feature PENDING」 | 述「W3-11-R1 CLOSED #117 / feature COMPLETE」 |
| completion doc §三 W3-11-R1 行（L87）+ §二/§五/§六 叙述 + grep-gate 描述（L128） | OPEN / 功能门未解 / feature PENDING | RESOLVED by #117(+#120) / 功能门已解 / feature COMPLETE；**formal-closure 仍 gated on device** |
| runtime-matrix「排除/OPEN bounce 节」（L44-50）+ device 矩阵标题（L20 「7 项」）+ L89 OPEN 清单 | bounce 排除（W3-11-R1 OPEN） | bounce **转 device happy-path 行**（第 8 项），device pass/fail 留空待回填；L89 移除 W3-11-R1 OPEN（保 PR11-R1/W1-R2） |

### 保留不动（仍真实 pending）
| key/门 | 值 | 为何不动 |
|---|---|---|
| `store-ready` | `NO` | NAS ship 门（PR11-R1/W1-R2）仍 OPEN，未上架 |
| `formal-closure` | `PENDING-runtime-matrix-device-record` | device 三连合取回填仍未做；W3-11-R1 仅是关闭的**功能侧**前提之一，device 侧前提仍欠 |
| `runtime-matrix` | `PARTIAL` | device pass/fail 全留空 |
| `freeze-tag` | `NOT-TAGGED` | gated on 上两项 |
| `residual-A/B/C/D` | CLOSED（各自值） | 不动 |
| `known-defect-13a-R2...` | `CLOSED 13a-R2 2026-06-15` | 不动 |
| `ship-gate-PR11-R1-prod-backend-url` | `OPEN` | NAS，out-of-Wave-3-scope，不动 |
| `ship-gate-W1-R2-sample-data` | `OPEN` | NAS，out-of-Wave-3-scope，不动 |

---

## 三、honesty 不变量（本 PR 的核心约束）

1. **`feature-completeness: COMPLETE` ≠ 正式关闭/上架**。功能代码完成 ≠ Wave 3 关闭。device 回填 + NAS ship 门由 `formal-closure`/`runtime-matrix`/`store-ready`/`freeze-tag`/`ship-gate-*` 五个独立 key 承载，**全保持 PENDING/NO/OPEN**。一 key 一事实（承袭 verify 脚本设计哲学），不把「device 待回填」糅进 feature 门值。
2. **新增 bounce device 行 = 收紧而非放松**：device happy-path 矩阵从 **7 项 → 8 项**（多一项待用户实测）。关闭判据「全行 PASS」因此**更严**，杜绝「翻 feature 门 = 偷偷少测一项」的反向 overclaim。
3. **不回改已冻结 spec §E.2**（散文措辞留 doc 维护）；只动 completion doc/matrix/verify 脚本的 ledger 事实，承袭 #117/#118 的「ledger 完整性优先、不回改冻结 spec」惯例。
4. **W3-11-R1 关门引用 #117**（live 接线本身），#120（drag 橡皮筋）作叙述补充——residual key 值引一个权威 ref（匹配既有 `CLOSED <context> <ref>` 格式），避免值膨胀。

---

## 四、runtime-matrix bounce device 行（用户实测对象）

把 L44-50「排除节」改为 device happy-path 矩阵新增行（第 8 项），二元判据：
- **甩动到最老边松手** → 弹簧 overscroll 间隙可见 + 回弹 + 落贴最老边（#117 机制 A）。
- **手指拖过最老边** → 带阻尼跟手（越拖越沉）+ 松手回弹贴边（#120 橡皮筋）。
- **甩/拖向最新边** → 无前向间隙、停当前 tick（reveal 硬钳）。
- **满屏（无滚动空间）** → 不动不弹。

device pass/fail 留空（用户 device 回填，与其余 7 行同）。引用 acceptance：`#117` = `docs/superpowers/acceptance/2026-06-16-w3-11-r1b-wire-acceptance.md`（如存在则指针，否则指 PR）+ `#120` = `docs/superpowers/acceptance/2026-06-16-w3-11-r1b-drag-acceptance.md` §六.11 device runbook。

---

## 五、验收 / 治理

- **评审通道**：改 `docs/**` + `scripts/governance/verify-wave3-completion.sh`（trust-boundary）→ `codex:adversarial-review`（配额耗尽 fallback opus 4.8 xhigh）。本 spec + plan 阶段评审用 **opus 4.8 xhigh 对抗性 review 到收敛**（user 指定）。
- **acceptance（机器可验）**：① `bash scripts/governance/verify-wave3-completion.sh` → **PASS**（新断言匹配新块值；结构守卫/其余谓词不破）；② grep 自洽：WAVE3-STATUS 块值 ↔ verify 脚本 require_kv ↔ completion 叙述 ↔ matrix 三处对 W3-11-R1/feature 门的措辞**互不矛盾**；③ host `swift test` **不受影响**（本 PR 0 业务代码，doc+script only，预期与 baseline 同 1085/0——但 host 测不读这些 doc，实为「无关」确认）；④ 无 forbidden phrases（`.claude/workflow-rules.json`）。
- **honesty 反向断言**：grep WAVE3-STATUS 块确认 `store-ready: NO` / `formal-closure: PENDING-runtime-matrix-device-record` / `runtime-matrix: PARTIAL` / `freeze-tag: NOT-TAGGED` / `ship-gate-* OPEN` **逐字未变**（防误翻关闭/上架门）。
- **非-coder acceptance checklist**：落 `docs/superpowers/acceptance/2026-06-16-wave3-ledger-reconcile-acceptance.md`（verify PASS / 块值对照 / honesty 反向断言 / device 矩阵 7→8 / 无 forbidden phrases）。

---

## 六、out of scope（全不动）
- device 实测本身（runbook 交付，user 职责）。
- NAS ship 门：PR11-R1（生产 backendBaseURL）、W1-R2（真实样本数据）。
- freeze tag ceremony（gated on device 回填，未来独立 PR）。
- 任何业务代码 / CI workflow / ruleset。
- 已冻结 spec §E.2 的散文措辞（不回改）。

---

## Changelog
| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-06-16 | v1 | 锁范围：翻 `residual-W3-11-R1 OPEN→CLOSED #117` + `feature-completeness PENDING→COMPLETE`（本 PR 推荐，待 user 审 spec 确认）+ 同步 verify 脚本 L50/L58/注释/echo + completion §二/§三/§五/§六 叙述 + runtime-matrix bounce 排除节转 device 第 8 行（7→8）。honesty 不变量：formal-closure/store-ready/runtime-matrix/freeze/ship 门**全保留**；feature 门翻转 ≠ 关闭；矩阵收紧非放松。授权 = R1b-wire spec §九。 |
