# Wave 3 账本 reconciliation Implementation Plan

> **For agentic workers:** 本 plan 由 controller **inline 执行**（superpowers:executing-plans，subagent-driven 决策树的同会话替代——3 文件治理 doc/script 紧耦合编辑、controller 持全上下文 + 穷尽枚举，fresh subagent 须重传全部 §二.1 枚举且易漏；故 inline 更可靠）。执行后照常做**两阶段 review**（spec-compliance + code-quality）于 diff。Steps 用 checkbox 跟踪。

**Goal:** 把 Wave 3 治理账本对齐到代码现状——W3-11-R1（bounce live 接线）由 #117 实现、#120 补 drag，翻 `feature-completeness PENDING→COMPLETE` + `residual-W3-11-R1 OPEN→CLOSED`，同步 verify 脚本 + completion 叙述 + runtime-matrix bounce 转 device 行；**保留** formal-closure/store-ready/runtime-matrix/freeze/ship 门全 pending。

**Architecture:** 0 业务代码 / 0 CI / 0 ruleset。改 3 文件（completion doc / verify 脚本 / runtime-matrix）+ 1 acceptance doc。verify gate 只解析 WAVE3-STATUS 机器块——故机器块 + require_kv 是 gate-critical（byte 精确），叙述是 gate-invisible（须 grep 自洽防静默漂移）。

**Spec（authority）:** `docs/superpowers/specs/2026-06-16-wave3-ledger-reconcile-design.md`（v1.3，opus R1→R2→R3 APPROVE）。**§二.1 逐句枚举表 + §二.2 矩阵改点是逐条 old→new 权威清单**——本 plan 不复述全文，列每条触点 + gate-critical 逐字值，实施时对照 spec §二.1/§二.2。

**评审通道:** 改 `docs/**` + `scripts/governance/*.sh`（trust-boundary）→ `codex:adversarial-review`（配额耗尽 fallback opus 4.8 xhigh）。

---

## File Structure

| 文件 | 改动 | gate 可见性 |
|---|---|---|
| `docs/governance/2026-06-14-wave3-completion.md` | WAVE3-STATUS 机器块 2 key（L8/L17）+ §二.1 九句叙述（§一L4/§二L68,L72,L74/§三L86,L87/§五L114,L118/§六L128） | 机器块=gate-critical；叙述=gate-invisible（grep 自洽） |
| `scripts/governance/verify-wave3-completion.sh` | require_kv L50/L58 + 注释 L6/L8/L9/L49/L55 + echo L73 | require_kv=gate-self（脚本断言自身）；注释/echo=可读性 |
| `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` | 标题 L20 + 排除节 L44-50→device 行 + L89 OPEN 清单（§二.2） | 全 gate-invisible（gate 仅 grep fixture/runbook 指针，不解析这些行）；grep 自洽 |
| `docs/superpowers/acceptance/2026-06-16-wave3-ledger-reconcile-acceptance.md`（新） | 非-coder 验收 checklist | — |

---

## Task 1: WAVE3-STATUS 机器块 2-key flip + verify 脚本断言/注释/echo

**Files:** `docs/governance/2026-06-14-wave3-completion.md`、`scripts/governance/verify-wave3-completion.sh`

- [ ] **Step 1: 机器块 2 key（byte 精确，anchored 全行）**

`completion.md` WAVE3-STATUS 块内：
```
# L8  旧: feature-completeness: PENDING-W3-11-R1-bounce-live-wiring
#     新: feature-completeness: COMPLETE
# L17 旧: residual-W3-11-R1-bounce-live-wiring: OPEN
#     新: residual-W3-11-R1-bounce-live-wiring: CLOSED W3-11-R1 #117
```
**不动**块内其余 key：`store-ready: NO` / `formal-closure: PENDING-runtime-matrix-device-record` / `runtime-matrix: PARTIAL` / `freeze-tag: NOT-TAGGED` / `residual-A/B/C/D` / `known-defect-13a-R2...` / `ship-gate-PR11-R1...: OPEN` / `ship-gate-W1-R2...: OPEN`。

- [ ] **Step 2: verify 脚本 require_kv（须与新块值 byte-match）**

```
# L50 旧: require_kv "residual-W3-11-R1-bounce-live-wiring" "OPEN"
#     新: require_kv "residual-W3-11-R1-bounce-live-wiring" "CLOSED W3-11-R1 #117"
# L58 旧: require_kv "feature-completeness" "PENDING-W3-11-R1-bounce-live-wiring"
#     新: require_kv "feature-completeness" "COMPLETE"
```
其余 require_kv（L44-47 A/B/C/D、L51 13a-R2、L52-53 ship 门、L56/57/59/60 store-ready/closure/matrix/freeze）+ 结构守卫（L25-32）**逐字不动**。

- [ ] **Step 3: verify 脚本注释 + echo（可读性一致，非 gate 但防误导）**

- L6 注释「W3-11-R1 + ship 门 PR11-R1 / W1-R2 标 OPEN」→「ship 门 PR11-R1 / W1-R2 标 OPEN（W3-11-R1 已 CLOSED #117）」。
- L8 注释「feature-completeness=PENDING-W3-11-R1」→「feature-completeness=COMPLETE」。
- L9 注释「无误 claim …feature-complete」→ 保留「无误 claim 上架/已关闭」语义（feature 现确 complete，但 store/closure 仍 NO/PENDING）。
- L49 注释「谓词 2：W3-11-R1 + ship 门…OPEN」→「谓词 2：ship 门 PR11-R1/W1-R2 OPEN；W3-11-R1 CLOSED #117（#117 bounce live 接线）」。
- L55 注释「无…feature-complete 误 claim」→ 同 L9 调整。
- L73 echo「W3-11-R1/PR11-R1/W1-R2 OPEN … feature-completeness」→「W3-11-R1 CLOSED #117 + PR11-R1/W1-R2 OPEN … feature-completeness=COMPLETE」。

> 对照 spec §二 flip 表「verify 脚本注释（L6/L8/L9）+ 末行 echo（L73）」+ §二.1「§六 grep-gate 描述 L128」（completion 内描述，非脚本——见 Task 2）。

- [ ] **Step 4: 跑 verify 脚本验证 PASS**

Run: `cd <worktree> && bash scripts/governance/verify-wave3-completion.sh`
Expected: 退出 0 + `PASS` 行（新 require_kv 匹配新块值；结构守卫不破）。**若 FAIL** → 机器块值与 require_kv 不 byte-match，逐字核对修正。

- [ ] **Step 5: Commit**

```bash
git add docs/governance/2026-06-14-wave3-completion.md scripts/governance/verify-wave3-completion.sh
git commit -m "feat(ledger-reconcile): WAVE3-STATUS 翻 feature COMPLETE + W3-11-R1 CLOSED #117 + verify 断言/注释/echo 同步"
```

---

## Task 2: completion doc 叙述九句（§二.1 逐句枚举，gate-invisible 须防漂移）

**Files:** `docs/governance/2026-06-14-wave3-completion.md`

- [ ] **Step 1: 按 spec §二.1 表逐句改（9 句，各句 old→new 见 spec，不可批量「轻触」）**

逐句 checklist（每句改后须与机器块 `feature COMPLETE` / W3-11-R1 CLOSED 一致，且**保 formal-closure pending**）：
- [ ] **§一 性质 L4**：5 处 PENDING 断言→「含 W3-11-R1 / #117 已上线 / 功能完整性 COMPLETE」；**保**「正式关闭仍 gated on device 矩阵回填、非正式关闭、不打 tag」。
- [ ] **§二 L68**：去掉「+ 解 W3-11-R1」pending 前提→「W3-11-R1 已解(#117)，仅余 device 矩阵合取」。
- [ ] **§二 L72**：**保历史叙述**（13c 当时 bounce 未接线 / spec §E.2 列入曾属 overclaim / **不回改冻结 spec §E.2**）+ **更新结论**「#117(+#120) 已上线→转 device happy-path 行（矩阵 8 项）+ W3-11-R1 CLOSED」。
- [ ] **§二 L74**：option-(b) PENDING 论证→「#117 已上线→转 device 行 + 功能完整性 COMPLETE，W3-11-R1 已解」。
- [ ] **§三 residual 表 L86**：「runbook 交付（…7 项…）」→「…8 项〔+bounce〕…」（仅 7→8，PARTIAL/其余不动）。
- [ ] **§三 W3-11-R1 行 L87**：「OPEN（功能完成门…）」→「RESOLVED（#117 live 接线 + #120 drag，2026-06-16）…转 device 矩阵行；功能完整性 COMPLETE；非 NAS ship 门」。
- [ ] **§五 L114**（freeze 理由 #2）：「未解，功能不完整」→「已解(#117)，功能 COMPLETE；freeze 仍 deferred 因 device 矩阵未回填（理由 #1），非功能不完整」。
- [ ] **§五 L118**（后续步骤 ②）：「W3-11-R1 实现并回填」→「#117 已实现；仅余 bounce device runbook 回填（并入 device 矩阵第 8 行）」。
- [ ] **§六 grep-gate 描述 L128**：「W3-11-R1…OPEN … feature-completeness=PENDING-W3-11-R1」→「W3-11-R1 CLOSED(#117) / PR11-R1/W1-R2 OPEN … feature-completeness=COMPLETE」。

- [ ] **Step 2: grep 自洽核对（穷尽，防漂移）**

Run:
```bash
grep -nE "PENDING-W3-11-R1|功能完整性 ?PENDING|W3-11-R1.*OPEN|未上线|实为 .?7.? 项|7 项" docs/governance/2026-06-14-wave3-completion.md
```
Expected: **0 命中**（除被引用为历史/「曾」语境者；若有残留指代当前状态的 PENDING/OPEN/7 项 → 漏改，回 Step 1）。再 `bash scripts/governance/verify-wave3-completion.sh` 仍 PASS（叙述改不影响机器块）。

- [ ] **Step 3: Commit**

```bash
git add docs/governance/2026-06-14-wave3-completion.md
git commit -m "feat(ledger-reconcile): completion 叙述九句对齐 COMPLETE（§一L4/§二L68,L72,L74/§三L86,L87/§五L114,L118/§六L128）"
```

---

## Task 3: runtime-matrix bounce 排除节转 device 行（§二.2）

**Files:** `docs/acceptance/2026-06-14-wave3-runtime-matrix.md`

- [ ] **Step 1: 标题 L20**

「## device happy-path 矩阵（7 项：6 数据交互 + 顺位 2 竖屏/窗口）」→「**## device happy-path 矩阵（8 项：6 数据交互 + 顺位 2 竖屏/窗口 + 顺位 11 bounce）**」。

- [ ] **Step 2: 排除节 L44-50 → device happy-path 第 8 行**

把「## 排除 / OPEN 节：bounce（顺位 11）= W3-11-R1 OPEN」整节（标题 L44 + 正文 L46/48/50）改为：**device 矩阵表新增第 8 行**（接在第 7 行后；若矩阵是 markdown 表，加一表行），判据（spec §四，二元 pass/fail 留空待用户回填）：
- 甩到最老边松手 → 弹簧 overscroll 间隙 + 回弹 + 落贴最老边（#117 机制 A）
- 拖过最老边 → 阻尼跟手（越拖越沉）+ 松手回弹贴边（#120 橡皮筋）
- 甩/拖向最新边 → 无前向间隙、停当前 tick（reveal 硬钳）
- 满屏无滚动空间 → 不动不弹

引用 acceptance：`docs/superpowers/acceptance/2026-06-16-w3-11-r1b-wire-acceptance.md`（#117）+ `docs/superpowers/acceptance/2026-06-16-w3-11-r1b-drag-acceptance.md` §六.11（#120）。**保留**原节的「device 验收 = 用户回填」语义；删「W3-11-R1 OPEN / device 验收 BLOCKED」措辞（bounce 现可测）。

- [ ] **Step 3: L89 OPEN 清单**

「W3-11-R1（bounce live 接线）+ PR11-R1 + W1-R2 = OPEN…其中 W3-11-R1 是关闭前须解的功能门」→ 移除 W3-11-R1（保 PR11-R1/W1-R2 OPEN）；「W3-11-R1 是关闭前须解的功能门」→「W3-11-R1 已解（#117 bounce live 接线，2026-06-16）」。

- [ ] **Step 4: grep 自洽 + verify PASS**

Run:
```bash
grep -nE "W3-11-R1.*OPEN|7 项|排除 / OPEN 节|不列 bounce|BLOCKED" docs/acceptance/2026-06-14-wave3-runtime-matrix.md
bash scripts/governance/verify-wave3-completion.sh
```
Expected: grep 0 命中当前状态的 W3-11-R1-OPEN/7项/排除节（编译期「排除」L16 与 bounce 无关，允许）；verify **PASS**（matrix 谓词 3b/3c/3d——`KLINE_SEED_FIXTURE=1` + 三 runbook 指针 + orientation 指针——均未动，仍命中）。

- [ ] **Step 5: Commit**

```bash
git add docs/acceptance/2026-06-14-wave3-runtime-matrix.md
git commit -m "feat(ledger-reconcile): runtime-matrix bounce 排除节转 device 第8行（7→8）+ L89 W3-11-R1 已解"
```

---

## Task 4: verification + 非-coder 验收 checklist

**Files:** `docs/superpowers/acceptance/2026-06-16-wave3-ledger-reconcile-acceptance.md`（新）

- [ ] **Step 1: 全量 verification（fresh 证据）**

```bash
bash scripts/governance/verify-wave3-completion.sh          # 预期 PASS
# honesty 反向断言（机器块翻转后正值 + keep-pending 逐字）：
grep -nE "^feature-completeness: COMPLETE$|^residual-W3-11-R1-bounce-live-wiring: CLOSED W3-11-R1 #117$|^store-ready: NO$|^formal-closure: PENDING-runtime-matrix-device-record$|^runtime-matrix: PARTIAL$|^freeze-tag: NOT-TAGGED$" docs/governance/2026-06-14-wave3-completion.md
# host 不受影响（doc/script PR，0 业务代码；host 测不读这些 doc → 与 baseline 同）：
cd ios/Contracts && swift test 2>&1 | tail -2        # 预期 1085/0（与 baseline 同）
```
Expected: verify PASS；6 条 grep 各命中 1 次（翻转正值 + keep-pending）；host 1085/0。

- [ ] **Step 2: 写非-coder 验收 checklist**

`docs/superpowers/acceptance/2026-06-16-wave3-ledger-reconcile-acceptance.md`：表格列（操作/预期/通过-不通过），中文，二元判据：
- `bash scripts/governance/verify-wave3-completion.sh` → 退出 0 + PASS 行。
- 机器块 grep：`feature-completeness: COMPLETE` + `residual-W3-11-R1-bounce-live-wiring: CLOSED W3-11-R1 #117` 各 1 命中。
- honesty 反向：`store-ready: NO` / `formal-closure: PENDING-runtime-matrix-device-record` / `runtime-matrix: PARTIAL` / `freeze-tag: NOT-TAGGED` / 两 ship 门 OPEN 各 1 命中（**未被误翻**）。
- completion 叙述自洽：`grep "PENDING-W3-11-R1\|实为.*7 项"` 当前状态 0 命中。
- matrix 标题含「8 项」+ device 第 8 行 bounce 存在。
- 范围 gate：`git diff --name-only origin/main...HEAD` 仅 4 文件白名单（completion / verify 脚本 / matrix / 本 acceptance + spec/plan）；**三 0 改动**：`git diff origin/main...HEAD -- ios/ .github/ <ruleset>` 为空（0 业务代码 / 0 CI / 0 ruleset）。
- 无 forbidden phrases（`.claude/workflow-rules.json`）。
- 评审 APPROVE 落账行（spec R1→R3 / plan / 两阶段 / final overall）。

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/acceptance/2026-06-16-wave3-ledger-reconcile-acceptance.md
git commit -m "docs(ledger-reconcile): 非-coder 验收 checklist（verify PASS + honesty 反向断言 + 范围 gate）"
```

---

## Self-Review
- **spec 覆盖**：§二 机器块 flip（Task 1）/ §二.1 九句（Task 2 逐句 checklist）/ §二.2 矩阵（Task 3）/ §五 acceptance + honesty 反向（Task 4）。✓
- **gate-critical byte 精确**：机器块 L8/L17 + require_kv L50/L58 逐字值在 plan 内（Task 1 Step 1/2）。✓
- **gate-invisible 防漂移**：Task 2 Step 2 + Task 3 Step 4 grep 自洽穷尽核对（呼应 spec R1/R2 两轮遗漏教训）。✓
- **honesty 不变量**：keep-pending 五 key + 两 ship 门全程不动；Task 4 反向断言显式核。✓
- **无占位/无 scope creep**：仅 4 文件；三 0 改动 Task 4 gate 验。✓
