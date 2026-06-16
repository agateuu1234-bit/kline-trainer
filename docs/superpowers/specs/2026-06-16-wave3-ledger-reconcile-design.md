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
| completion doc 叙述（**逐句**，见 §二.1 枚举表，不可当「轻触」批量改） | OPEN / 功能门未解 / feature PENDING / bounce 排除 | RESOLVED by #117(+#120) / 功能门已解 / feature COMPLETE；**formal-closure 仍 gated on device** |
| runtime-matrix「排除/OPEN bounce 节」（L44-50）→ device 行；标题 L20 + L89 OPEN 清单（见 §二.2） | bounce 排除（W3-11-R1 OPEN）/ 标题「7 项」 | bounce **转 device happy-path 行**（第 8 项），device pass/fail 留空待回填；标题改 **「8 项：6 数据交互 + 顺位 2 竖屏/窗口 + 顺位 11 bounce」**；L89 移除 W3-11-R1 OPEN（保 PR11-R1/W1-R2） |

### §二.1 completion doc 叙述逐句改点（reviewer R1-High/Med：每句单列，防漏改致机器块↔散文自相矛盾）
| 位置 | 现（含 feature-PENDING/W3-11-R1-OPEN 真值） | 改后（与 `feature COMPLETE` / W3-11-R1 CLOSED 一致；**保 formal-closure pending**） |
|---|---|---|
| **§一 性质 L4**（reviewer R1-High：标题下最显眼段，5 处 PENDING 断言） | 「功能交付确认（**除 W3-11-R1 外**）」「live 接线（W3-11-R1）**仍 OPEN**」「功能完整性标 **PENDING-W3-11-R1**，非无条件 feature-complete」「W3-11-R1 是功能完成门 + 正式关闭前提」 | 「功能交付确认（**含 W3-11-R1**，bounce live 接线 #117 已上线 / drag 橡皮筋 #120）」「功能完整性 **COMPLETE**」；**保留**「**正式关闭仍 gated on device 矩阵回填**、非『正式关闭』、不打 tag」框架 |
| **§二 L68** | 「正式关闭 = 三连硬门全 PASS **+ 解 W3-11-R1**（13a-R2 已解…）」 | 「W3-11-R1 **已解（#117）**；正式关闭 = 三连硬门全 PASS（W3-11-R1 不再列 pending 前提，仅余 device 矩阵合取）」 |
| **§二 L72**（R2-High：独立段，「点名 spec §E.2 bounce 纠正」） | 「把 bounce 列进 device 运行时矩阵属 **overclaim**…**W3-11-R1 标 OPEN**…**运行时矩阵不列 bounce device happy-path 行**…device happy-path 矩阵实为 **7** 项」 | 保留**历史叙述**（13c 当时 bounce 未接线、spec §E.2 列入曾属 overclaim、不回改冻结 spec §E.2）+ **更新结论**：「bounce live 接线 **#117(+#120) 已上线** → 由『排除节』**转 device happy-path 行**（§二.2，矩阵现 **8** 项）+ **W3-11-R1 CLOSED**」 |
| **§二 L74** | 整段「排除 bounce ≠ 抹账 → 取 codex option (b) feature 标 **PENDING-W3-11-R1** + W3-11-R1 升功能完成门」 | 重写：「bounce live 接线 #117 已上线 → 由矩阵『排除节』**转 device happy-path 行**（§二.2）+ 功能完整性 **COMPLETE**；W3-11-R1 功能门**已解**」 |
| **§三 residual 表「运行时矩阵」行 L86**（R2-High 同类：stale count） | 「runbook 交付（…，**7 项** + 三连合取关闭门）」 | 「runbook 交付（…，**8 项**〔+bounce〕 + 三连合取关闭门）」（仅 7→8，PARTIAL/其余不动） |
| **§三 W3-11-R1 行 L87** | 「**OPEN（功能完成门 + 正式关闭前提）**…live 接线未上线…解门 = 实现 live 接线」 | 「**RESOLVED（#117 live 接线 + #120 drag 橡皮筋，2026-06-16）**…bounce 已上线、转 device 矩阵行；功能完整性 COMPLETE。**非** NAS ship 门」 |
| **§五 L114**（freeze 理由 #2，reviewer R1-Med：前提反转） | 「W3-11-R1 **未解，功能完整性本身 PENDING**…冻结语义在功能不完整时不成立」 | 「W3-11-R1 **已解（#117），功能完整性 COMPLETE**；freeze 仍 deferred——**理由改 base 在 device 矩阵未回填（理由 #1），非功能不完整**」 |
| **§五 L118**（后续步骤清单，reviewer R1-Med） | 「② **W3-11-R1（bounce live 接线）实现并回填**其运行时 acceptance」 | 「② W3-11-R1 live 接线 **#117 已实现**；仅余其 bounce **device runbook 回填**（并入 device 矩阵第 8 行）」 |
| **§六 grep-gate 描述 L128** | 「W3-11-R1/PR11-R1/W1-R2 **OPEN** … **feature-completeness=PENDING-W3-11-R1**」 | 「**W3-11-R1 CLOSED（#117）** / PR11-R1/W1-R2 OPEN … **feature-completeness=COMPLETE**」 |

### §二.2 runtime-matrix 改点
- L44-50「排除/OPEN bounce 节」→ **device happy-path 第 8 行**（判据见 §四）。
- L20 device 矩阵标题「7 项：6 数据交互 + 顺位 2 竖屏/窗口」→「**8 项：6 数据交互 + 顺位 2 竖屏/窗口 + 顺位 11 bounce**」。
- L89 OPEN 清单：移除 `W3-11-R1 ... = OPEN` 项（保 `PR11-R1`/`W1-R2`）；若该行同时含「W3-11-R1 是关闭前须解的功能门」字样 → 改「W3-11-R1 已解（#117）」。

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
- **honesty 反向断言**：grep WAVE3-STATUS 块确认 ①**翻转后正值**逐字落位：`feature-completeness: COMPLETE`（无尾随空格）+ `residual-W3-11-R1-bounce-live-wiring: CLOSED W3-11-R1 #117`；②**keep-pending 逐字未变**：`store-ready: NO` / `formal-closure: PENDING-runtime-matrix-device-record` / `runtime-matrix: PARTIAL` / `freeze-tag: NOT-TAGGED` / `ship-gate-PR11-R1-prod-backend-url: OPEN` / `ship-gate-W1-R2-sample-data: OPEN`（防误翻关闭/上架门）。`COMPLETE` 与 `PENDING-runtime-matrix-device-record` 是最易误读对——两者并存即「功能完成但未关闭」的诚实表达。
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
| 2026-06-16 | **v1.1（opus 4.8 xhigh 对抗性 review R1 修：1 High + 2 Med + 2 Low）** | reviewer 实编验证全部承重事实正确（L50/L58 行号、§九 授权属实、#117 确接线 bounce、acceptance refs 存在、verify gate 完整、honesty key 正确、值格式、矩阵收紧）。**R1-High**：completion doc **§一 性质 L4**（5 处 feature-PENDING 断言）漏入 change-set → 翻 COMPLETE 后机器块↔标题散文自相矛盾 → 加 **§二.1 逐句枚举表**（§一 L4 + §二 L68/L74 + §三 L87 + §五 L114/L118 + §六 L128，各句 old→new）；**R1-Med×2**：§二 L68（「解 W3-11-R1」列 pending 前提）+ L74（option-(b) PENDING 论证）+ §五 L114（freeze 理由 #2「功能不完整」前提反转）+ L118（W3-11-R1 列未来步骤）逐句钉死；**R1-Low×2**：矩阵标题精确串「8 项：6 数据交互 + 顺位 2 + 顺位 11 bounce」+ §五 反向断言加钉翻转后正值（`COMPLETE` 无尾空格 / `CLOSED W3-11-R1 #117`）。 |
| 2026-06-16 | **v1.2（opus R2 修：2 High 同类穷尽性遗漏）** | R2 独立 per-occurrence inversion 扫描确认 R1 五修全正确 + 枚举其余穷尽 + anchor SHA 行/矩阵 caveat/pr13c-completion.md 正确未动；但揪出 **completion doc L72**（独立段「spec §E.2 bounce 纠正」：overclaim / W3-11-R1 OPEN / 不列 bounce / **7 项**）+ **L86**（§三 residual 表「runbook 交付…7 项」）两个翻转后反转却**未枚举**（verify gate 只解析机器块故 gate-invisible 静默漂移）→ 补 §二.1 两行（L72 保历史叙述+更新结论转 device 行/CLOSED/8 项；L86 仅 7→8）。**作者自查穷尽 grep 复核三文件全部 W3-11-R1/feature/「7 项」/overclaim/未上线/功能完成门 出现点 → 全覆盖。设计收敛待 R3。** |
