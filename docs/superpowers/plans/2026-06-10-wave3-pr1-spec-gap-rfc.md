# Wave 3 顺位 1 RFC（spec-gap 治理）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 RFC 设计文档（`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`）的七契约权威定义落为 live 权威 spec 的 anchor 增量 + supersede marker + fail-closed grep gate + acceptance，使顺位 3/4/6/7/8/9/10 实施时能 grep 到治理过的公共面。

**Architecture:** 纯文档 governance（**0 业务代码 / 0 schema / 0 CI**）。canonical 契约在 RFC 设计文档 §4.x；本 plan 只在 `kline_trainer_modules_v1.4.md`（E5/E6/F2 engine·持久化·主题契约）+ `kline_trainer_plan_v1.5.md`（tier 显示 / 结算 reconcile / 夜间）插入**简洁 authoritative anchor + 见 RFC 指针**（非搬全 rationale），并给 Wave 3 outline §3.1 加 supersede marker。每个 anchor 由 `scripts/governance/verify-wave3-pr1-rfc.sh` 七谓词 fail-closed 守护。

**Tech Stack:** Markdown spec 文档；bash fail-closed 验证脚本（沿用 `scripts/governance/verify-wave2-pr1-rfc.sh` 已实证 scaffolding）。

**改动文件（allowlist，共 7）**：
1. `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`（RFC 设计文档，已 committed）
2. `docs/superpowers/plans/2026-06-10-wave3-pr1-spec-gap-rfc.md`（本 plan）
3. `kline_trainer_modules_v1.4.md`（E5/E6/F2 anchor 增量）
4. `kline_trainer_plan_v1.5.md`（§6.2.1 tier+结算 reconcile / §Phase 5 夜间 marker）
5. `docs/superpowers/specs/2026-06-09-wave3-outline-design.md`（§3.1 supersede marker）
6. `scripts/governance/verify-wave3-pr1-rfc.sh`（七谓词 fail-closed gate）
7. `docs/acceptance/2026-06-10-wave3-pr1-spec-gap-rfc.md`（验收清单）

---

## Task 0: Review 策略 pre-check（无编辑）

- [ ] **Step 1: 记录 review 策略（per RFC §七 + outline §七）**

无文件编辑。确认策略：
- 主走 **opus 4.8 xhigh 对抗评审**（user 2026-06-10 explicit）：plan-stage + branch-diff 双闸门各到收敛。
- codex `codex:adversarial-review` 仍是治理 required channel；本 PR docs-only 不触 Catalyst（无 iOS 代码 / 无 `.github` 改动 → 无 trust-boundary CI 强制）。
- 超 5 轮或 permanent-bias → escalate user + attestation residual + admin merge（不绕 required checks）。

---

## Task 1: plan_v1.5 §6.2.1 — tier 派生公式（§4.1）+ 结算 reconcile（§4.2）

**Files:**
- Modify: `kline_trainer_plan_v1.5.md`（§6.2.1 顶部信息栏，L905-921 区块，顶栏「总资金/仓位」描述后）

- [ ] **Step 1: 预检 grep 应为空（anchor 尚未写入）**

Run: `grep -nF "仓位档位 X/5 派生公式" kline_trainer_plan_v1.5.md; echo "rc=$?"`
Expected: 无输出，`rc=1`（未写入 → gate 谓词 (a)/(b) 应 FAIL；证明非空洞）。

- [ ] **Step 2: 在 §6.2.1 顶栏描述后插入契约块**

在 `#### 6.2.1 顶部信息栏` 小节内、顶栏字段（总资金/仓位）列举之后插入：

```markdown
**仓位档位 X/5 派生公式（Wave 3 顺位 1 RFC §4.1 钉死，顺位 6 accessor `currentPositionTier` + 顺位 7 显示）**：顶栏「仓位 X/5」的 X = 当前持仓档位派生值——令 `holdingValue = 持仓股数 × 当前价`、`total = 实时总资金（现金 + 持仓市值）`；`total <= 0 → X = 0`，否则 `X = clamp(round(holdingValue / total × 5), 0, 5)`。**市值 / 当前总资金基准 + round（非成本基准 / 非 floor）**；空仓 0/5、满仓 5/5。派生非状态（无持久 tier 字段）。

**结算 vs 顶栏总资金显示语义（RFC §4.2 reconcile，E6b-R1 消解）**：训练中**顶栏** = `currentTotalCapital`（本局实时总资金 = 现金 + 持仓市值，含浮盈，Normal/Review/Replay 一致）；**结算窗** = `total_capital`（本局结束冻结值；Normal 持久化 `TrainingRecord` / Review 读历史 record / Replay in-memory 不持久化）。二者是两个字段用于两个场景，**非 dispute**。
```

- [ ] **Step 3: 验证 anchor 可 grep**

Run: `grep -nF "仓位档位 X/5 派生公式" kline_trainer_plan_v1.5.md && grep -nF "本局实时总资金 = 现金 + 持仓市值" kline_trainer_plan_v1.5.md; echo "rc=$?"`
Expected: 两行各命中 1，`rc=0`。（**grep 模式须为 backtick-free 连续子串**——`currentTotalCapital` 在文中被反引号包围，模式不可跨反引号边界。）

- [ ] **Step 4: Commit**

```bash
git add kline_trainer_plan_v1.5.md
git commit -m "Wave3 PR1 RFC: plan §6.2.1 tier 派生公式 + 结算 reconcile anchor (§4.1/§4.2)"
```

---

## Task 2: modules §E5 — engine 契约增量（§4.1 accessor / §4.4a/c/d）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§E5 训练引擎模块，L1581 小节内，engine API 文档区之后）

- [ ] **Step 1: 预检 grep 应为空**

Run: `grep -nF "currentPositionTier" kline_trainer_modules_v1.4.md; echo "rc=$?"`
Expected: 无输出 `rc=1`。

- [ ] **Step 2: 在 §E5 代码围栏外插入契约增量块（opus plan R1-H：务必围栏外）**

**插入位置（内容锚，不靠绝对行号）**：紧接**关闭 §E5 `TrainingSessionCoordinator` ```swift 代码围栏的那一行 ``` **（围栏 L1588 开、L1732 关；`saveProgress` 在 L1677 **围栏内**——增量块若落围栏内会被渲染成 swift 字面、破坏文档且 grep 仍 PASS 掩盖错误）**之后**、`## 八、iOS 持久化模块`（L1736）**之前**插入下方 markdown（注意：modules 无独立 `### E6` heading，E5/E6 运行时同居 §E5）：

```markdown
#### E5 Wave 3 顺位 1 RFC 契约增量（见 `docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md` §4.1/§4.4；顺位 6 序列化实现，serial neck，所有 Wave 3 engine 契约变更集中此锚，消费锚 3/4/7/8 不改 engine 契约）

- **`var currentPositionTier: Int { get }`（§4.1）**：read-only computed，0...5。`holdingValue = position.shares × currentPrice`、`total = currentTotalCapital`；`total <= 0 → 0`，否则 `clamp(Int((holdingValue / total × 5).rounded(.toNearestOrAwayFromZero)), 0, 5)`。市值 / 当前总资金基准 + round（非成本基准 / 非 floor）。
- **on-demand 手动强平（§4.4a）**：前置 `flow.canBuySell()`（「结束按钮」capability proxy，Normal✅/Review❌/Replay✅）；`position.shares > 0` → 按 `currentPrice`（modules L342「手动结束 = 用户点击结束时的值」）走 `TradeCalculator.forceCloseOnEnd` append forced sell（`.tier5`，佣金+印花税）→ `shares == 0`；幂等（再调 no-op）；与 auto-end（`forceCloseIfEnded`，`>= maxTick` 门）共用同一 force-close 体。
- **`func appendDrawing(_ drawing: DrawingObject)`（§4.4c）**：把 committed 画线追加进 `drawings`（更新 revision 重渲染 + 进 finalize/pending 持久化）。restore（`initialDrawings`）+ delete（`deleteDrawing`）已在，本子项只补 live commit 投影；`drawings` 是唯一渲染+持久化真相，manager.completedDrawings 仅输入暂存。
- **pinch/zoom panel-state mutation（§4.4d，D1：engine-owned 非 render-free）**：改 `panelState.visibleCount` 于 clamp `[MIN_VISIBLE, MAX_VISIBLE]` + 保持 focus（pinch 中点 candle x 不动，重算 offset）；**ephemeral**——不在 `pending_training`（现 13 列无 visibleCount），不跨 session 持久、不进 finalize。clamp/灵敏度数值 + C7 仲裁集成归顺位 3 plan。理由：crosshair(5)/drawing(4) 消费 post-pinch 视口几何，engine-free 会致双视口真相。
```

- [ ] **Step 3: 验证 anchor 可 grep**

Run: `grep -cF "currentPositionTier" kline_trainer_modules_v1.4.md && grep -cF "func appendDrawing(_ drawing: DrawingObject)" kline_trainer_modules_v1.4.md`
Expected: 各 ≥1。

- [ ] **Step 4: Commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "Wave3 PR1 RFC: modules §E5 engine 契约增量 (currentPositionTier/手动强平/appendDrawing/zoom §4.1/§4.4)"
```

---

## Task 3: modules §E6 — 持久化契约增量（§4.4e/§4.5/§4.6/§4.7）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§E6 持久化区，`saveProgress`（L1676 区块）/ `finalize` / `endSession` 描述附近）

- [ ] **Step 1: 预检 grep 应为空**

Run: `grep -nF "AUTOSAVE_TICK_INTERVAL" kline_trainer_modules_v1.4.md; echo "rc=$?"`
Expected: 无输出 `rc=1`。

- [ ] **Step 2: 紧接 Task 2 的 E5 增量块之后插入 E6 持久化契约增量块（同在 §E5 围栏外）**

**插入位置（内容锚）**：紧接 Task 2 插入的 `#### E5 Wave 3 顺位 1 RFC 契约增量` 块**之后**、`## 八、iOS 持久化模块`（L1736）**之前**插入下方 markdown（代码围栏外；E6 持久化契约紧邻其所扩展的 coordinator 文档，便于后续实施锚 grep 发现）：

```markdown
#### E6 Wave 3 顺位 1 RFC 契约增量（见 RFC §4.4e/§4.5/§4.6/§4.7）

- **周期 autosave 参数化（§4.6，顺位 10）**：`saveProgress` 触发 = **任何 state-dirtying mutation**（tick 推进 + 交易 buy/sell + 画线 commit/delete，**非仅 tick**——buy 未推 tick 仍须存，否则 inter-tick 丢交易）。cadence floor `AUTOSAVE_TICK_INTERVAL = N`（默认 1，可上调 `≤ AUTOSAVE_MAX_INTERVAL`，不变量：未落盘丢失 ≤ N tick 等价脏窗）；coalescing 单写者 latest-wins（in-flight 写中又脏→写完再存，不排队）；background/inactive flush（scenePhase `.inactive`/`.background` 立即 flush，**additive** 到 `.active → onSceneActivated` 动画链，不替换）；失败可见、不 teardown session。
- **replay non-persisting settlement payload（§4.4e/§4.5，顺位 6 产 / 顺位 8 消费）**：replay 结束强平后构造 in-memory `TrainingRecord`（原局 FeeSnapshot + 强平终态：total_capital/收益率/回撤/trade ops），**不写 `training_records`、不触 `pending_training`、`finalize` 对 replay 仍返 nil**；replay 结束后 DB 完全不变。
- **单事务 session-finalization port（§4.7b，顺位 10a）**：新 port 把 `insertRecord` + `clearPending` 收进单一 `DefaultAppDB` 事务（原子：要么 record 入库且 pending 清，要么都不）；注入 coordinator，禁 unsafe concrete downcast。
- **finalize 失败保留 session（§4.7a）**：finalize 失败 → 保留 active session（retry/discard，不 teardown reader/activeTraining）；**禁** `onSessionEnded(nil)` 拆毁路径。
- **durable session key + P4 schema 迁移（§4.7c，顺位 10a）**：session 启动生成稳定 key 落 `pending_training` + 随 record 入库；**additive named migration（如 `0004_*`）**加 session-key 列 + `training_records` 唯一约束（retry 同 key → `ON CONFLICT` no-op 返已存 id，幂等）；existing-row 回填；fresh-install/upgrade/crash-after-commit/retry 四态测试；**版本 bump MANDATORY**（随迁移原子 ship，列名/DDL/目标版本号归顺位 10a plan）。
- **终态 fence（§4.7d，顺位 10b）+ discard 终态（§4.7e）**：finalize/discard 前 drain/cancel 排队 autosave + finalization 启动后拒绝新 autosave（防终态脏写重建 `pending_training` → 重启重复 finalize/record）；discard = fence → 清 `pending_training` → endSession → exit（durable 终态，不复活；清 pending 失败则保留 session retry）。
- **provenance-aware 恢复（§4.7f，顺位 10b，安全红线）**：按 **source** 分流（非 `.dbCorrupted` error 类型，二者现同类型但调用点 source 已知）——training-set DB 损坏可弃（自动删 + 重下）；**`app.sqlite` 损坏 fail-closed 禁自动删**（settings 走 §P6 `forceResetAndReload(confirmation:)` 两层恢复；history/pending 无自动抹）。
```

- [ ] **Step 3: 验证 anchor 可 grep（含安全红线 + replay 不变量）**

Run: `grep -cF "AUTOSAVE_TICK_INTERVAL" kline_trainer_modules_v1.4.md && grep -cF "fail-closed 禁自动删" kline_trainer_modules_v1.4.md && grep -cF "replay 结束后 DB 完全不变" kline_trainer_modules_v1.4.md && grep -cF "单事务 session-finalization port" kline_trainer_modules_v1.4.md && grep -cF "durable session key" kline_trainer_modules_v1.4.md`
Expected: 各 ≥1。（grep 模式均 backtick-free 连续子串。）

- [ ] **Step 4: Commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "Wave3 PR1 RFC: modules §E6 持久化契约增量 (autosave/replay-payload/单事务 port/幂等迁移/fence/discard/provenance §4.4e-§4.7)"
```

---

## Task 4: modules §F2 — 夜间 light/dark 双集（§4.3）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（§F2 主题模块 `Theme/`，L828 小节内 ThemeController 描述后）

- [ ] **Step 1: 预检 grep 应为空**

Run: `grep -nF "light/dark 双 token 集" kline_trainer_modules_v1.4.md; echo "rc=$?"`
Expected: 无输出 `rc=1`。

- [ ] **Step 2: 在 §F2 代码围栏外插入契约增量块（opus plan R1-M）**

**插入位置（内容锚）**：紧接**关闭 §F2 ```swift 代码围栏的那一行 ``` **（围栏 L830 开、L849 关）**之后**、`---`（L851）**之前**插入下方 markdown（代码围栏外）：

```markdown
#### F2 Wave 3 顺位 1 RFC 契约增量（见 RFC §4.3，顺位 9 实现）

夜间模式 = **light/dark 双 token 集**：现有 13 个 `AppColorRGBA` 默认 token（背景近黑）= **dark/夜间集**；新增 **light/白天集**（背景近白 / 文本近黑 / 语义色保持红涨绿跌 / 辅助线按白底降明度，**具体 RGBA 归顺位 9 plan 依 WCAG AA 设备实测**）。render 层按 `themeController.resolve(trait:)` 返回的 `AppColorScheme` 选 light/dark 集（机制——token 参数化或双 static 集——归顺位 9 plan）。`displayMode == .system` 跟随 `UITraitCollection` 变化重解析重渲染。持久化经 `AppSettings.displayMode`（settings key `display_mode`，**无 schema 改动**）。
```

- [ ] **Step 3: 验证**

Run: `grep -cF "light/dark 双 token 集" kline_trainer_modules_v1.4.md`
Expected: ≥1。

- [ ] **Step 4: Commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "Wave3 PR1 RFC: modules §F2 夜间 light/dark 双集契约 (§4.3)"
```

---

## Task 5: plan §Phase 5 — 夜间 marker（§4.3 指针）

**Files:**
- Modify: `kline_trainer_plan_v1.5.md`（§Phase 5：磨光，L1224-1226「白天/夜间/跟随系统」后）

- [ ] **Step 1: 预检 grep 应为空**

Run: `grep -nF "Wave 3 顺位 1 RFC §4.3" kline_trainer_plan_v1.5.md; echo "rc=$?"`
Expected: 无输出 `rc=1`。

- [ ] **Step 2: 在 Phase 5「白天/夜间/跟随系统显示模式」条目后插入 marker**

```markdown
   - **契约（Wave 3 顺位 1 RFC §4.3 / modules §F2，顺位 9 实现）**：light/dark **双 token 集** + per-scheme 选取接线（现有 13 token = dark 集，新增 light 集）；具体 RGBA 归顺位 9 plan 依 WCAG AA 设备实测；持久化 `display_mode`（无 schema 改动）。
```

- [ ] **Step 3: 验证**

Run: `grep -cF "Wave 3 顺位 1 RFC §4.3" kline_trainer_plan_v1.5.md`
Expected: ≥1。

- [ ] **Step 4: Commit**

```bash
git add kline_trainer_plan_v1.5.md
git commit -m "Wave3 PR1 RFC: plan §Phase 5 夜间 marker (§4.3)"
```

---

## Task 6: Wave 3 outline §3.1 — supersede marker

**Files:**
- Modify: `docs/superpowers/specs/2026-06-09-wave3-outline-design.md`（`### 3.1 顺位 1` heading 之后、首个 stale 措辞之前）

- [ ] **Step 1: 定位 heading + 首个 stale 行**

Run: `grep -nF "### 3.1 顺位 1" docs/superpowers/specs/2026-06-09-wave3-outline-design.md; grep -nF "拒臆造" docs/superpowers/specs/2026-06-09-wave3-outline-design.md | head -1`
Expected: heading 行号 < 首个「拒臆造」行号（marker 须插在二者之间）。

- [ ] **Step 2: 在 `### 3.1` heading 紧接下一行插入 supersede banner**

**关键（opus plan R1-C1）**：marker 文本**不得含 stale token `拒臆造`**（否则谓词 (c) 的 `s = 首个 拒臆造 行` 会命中 marker 自身 → `m == s` 自撞 FAIL）；用与 stale token 不相交的措辞（沿用 wave2 marker 与 stale token disjoint 纪律）。§3.1 body 原文 L140 的 `拒臆造` 保留不动，作 (c) 的 `s` 锚。

```markdown
> **【顺位 1 RFC 已落地（`docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`，2026-06-10）**：本节所列各未决契约（仓位档位 X/5 派生 / 结算显示语义 / 夜间调色板 / 中断周期持久化 / E5·E6 engine 扩展 / replay 结算）**已由 RFC §4.1-§4.7 钉死权威定义**。后续 planner 以 RFC 为准，下方历史描述仅作背景；**本节契约已由顺位 1 RFC 钉死**。】
```

- [ ] **Step 3: 验证 marker 位置（heading < marker < 首个 stale）**

Run: `h=$(grep -nF "### 3.1 顺位 1" docs/superpowers/specs/2026-06-09-wave3-outline-design.md | head -1 | cut -d: -f1); m=$(grep -nF "本节契约已由顺位 1 RFC 钉死" docs/superpowers/specs/2026-06-09-wave3-outline-design.md | head -1 | cut -d: -f1); s=$(grep -nF "拒臆造" docs/superpowers/specs/2026-06-09-wave3-outline-design.md | head -1 | cut -d: -f1); echo "h=$h m=$m s=$s"; [ "$h" -lt "$m" ] && [ "$m" -lt "$s" ] && echo OK || echo BAD`
Expected: `OK`（h < m < s）。

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-06-09-wave3-outline-design.md
git commit -m "Wave3 PR1 RFC: outline §3.1 supersede marker (契约已由顺位1 RFC 钉死)"
```

---

## Task 7: 写 fail-closed 验证脚本 `verify-wave3-pr1-rfc.sh`

**Files:**
- Create: `scripts/governance/verify-wave3-pr1-rfc.sh`
- Reference scaffolding（**已实证 fail-closed**）: `scripts/governance/verify-wave2-pr1-rfc.sh`

- [ ] **Step 1: 复用 Wave 2 脚本 scaffolding（verbatim 结构）**

采用 `verify-wave2-pr1-rfc.sh` 的已实证 fail-closed scaffolding：`set -uo pipefail`；源路径用**数组**；跑前 `-r` 断言每源可读否则 `exit 2`；`gg()`/`ggF()` helper 区分 grep rc 0/1/**>1→exit 2**；过滤用纯 bash `case`（非 `grep|grep -v`）；负向断言用 `if [ -n "$hits" ]; then FAIL` （**不用 `set -e` 下 `! grep`**）；启动 line-filter 自检探针（坏→exit 2）。

**反引号纪律（关键，per `feedback_acceptance_grep_anchoring`）**：所有 `grep -F` 模式**必须是 anchor 文本的 backtick-free 连续子串**——模式可匹配「被反引号包围的标识符」（如模式 `currentPositionTier` 匹配文中 `` `currentPositionTier` ``，因反引号在标识符**外侧**），但模式本身**不得含反引号、不得跨反引号边界**（如 `currentTotalCapital（本局` 会因 `currentTotalCapital` 与 `（` 间夹一反引号而**永不命中**）。下方每谓词的匹配短语均已选为 backtick-free 连续子串。

- [ ] **Step 2: 实现七谓词（每条 anchored + fail-closed）**

源数组：`modules=kline_trainer_modules_v1.4.md`、`plan=kline_trainer_plan_v1.5.md`、`outline=docs/superpowers/specs/2026-06-09-wave3-outline-design.md`、`rfc=docs/superpowers/specs/2026-06-10-wave3-pr1-spec-gap-rfc-design.md`。

- **(a) 七契约权威锚在位（正向，全须命中）**：
  - modules：`grep -cF "currentPositionTier"` ≥1；`grep -cF "func appendDrawing(_ drawing: DrawingObject)"` ≥1；`grep -cF "on-demand 手动强平"` ≥1；`grep -cF "AUTOSAVE_TICK_INTERVAL"` ≥1；`grep -cF "单事务 session-finalization port"` ≥1；`grep -cF "durable session key"` ≥1；`grep -cF "light/dark 双 token 集"` ≥1。
  - plan：`grep -cF "仓位档位 X/5 派生公式"` ≥1；`grep -cF "Wave 3 顺位 1 RFC §4.3"` ≥1。
  - pass = 全锚 ≥1（任一缺 → (a) FAIL）。
- **(b) §4.2 结算 reconcile 文本在位（正向，取代 vacuous 负搜）**：plan `grep -cF "本局实时总资金 = 现金 + 持仓市值"` ≥1（顶栏 = currentTotalCapital）**且** `grep -cF "本局结束冻结值"` ≥1（结算 = total_capital）。pass = 两锚命中。（均 backtick-free 连续子串。）
- **(c) outline supersede marker 位置**：`h < m < s`（heading `### 3.1 顺位 1` 行 < marker `本节契约已由顺位 1 RFC 钉死` 行 < 首个 `拒臆造` 行）。任一缺/序错 → FAIL。**marker 文本不得含 `拒臆造`**（否则 m 行即首个 `拒臆造` → m==s 自撞，opus plan R1-C1）——marker 用与 stale token 不相交的措辞，body L140 的 `拒臆造` 作 `s`。
- **(d) provenance 安全红线在位**：modules `grep -cF "fail-closed 禁自动删"` ≥1（backtick-free 子串，对应 `` `app.sqlite` 损坏 fail-closed 禁自动删 ``）。pass = ≥1。
- **(e) replay non-persisting 不变量在位**：modules `grep -cF "replay 结束后 DB 完全不变"` ≥1（backtick-free 子串）。pass = ≥1。
- **(f) scope allowlist fail-closed**：`base=$(git merge-base origin/main HEAD)`；`git diff --name-only "$base" HEAD` 每路径须在 7 文件 allowlist（见 plan 文首清单）；任一非白名单（`ios/`/`.swift`/`.py`/`.sql`/`.yml`/`.xcodeproj`/`docs/superpowers/plans/2026-05-*`）→ 硬 FAIL。base 取不到 → exit 2。
- **(g) 冻结历史 immutability（opus plan R1-H1 修正）**：`git diff --name-only "$base" HEAD | grep -E '^docs/superpowers/(plans|specs)/2026-05-'` 须**空**（无任何 2026-05 冻结 point-in-time plan/spec 被动）。命中 → FAIL。**不**再用 `plan.*\.md` 黑名单——会误伤本 on-branch RFC plan doc `docs/superpowers/plans/2026-06-10-*`（它合法在 allowlist item 2）；冻结红线由 `2026-05-` 路径前缀精确锚，全 allowlist 由 (f) fail-closed 兜底。

末尾：逐条 `echo "(a) PASS"…"(g) PASS"` + `ALL PASS` + `exit 0`；任一 FAIL → 对应 `(x) FAIL` + `exit 1`；读错/源缺 → `exit 2`。

- [ ] **Step 3: 实测 fail-closed（关键，per `feedback_acceptance_grep_anchoring`）**

Run（未写 anchor 前的 stash 态 / 或临时移除一锚）：脚本应 `(a) FAIL` + `exit 1`。
Run（源不可读）：`chmod 000` 某源或改名 → `GATE FAIL: unreadable source` + `exit 2`。
Run（受限 TMPDIR）：`TMPDIR=/nonexistent-xyz bash scripts/governance/verify-wave3-pr1-rfc.sh` → 仍正常判定（无 here-string/临时文件依赖）。
Expected: 三种 fail-closed 行为均如述（**绝不** 把 FAIL 静默成 PASS）。

- [ ] **Step 4: Commit**

```bash
chmod +x scripts/governance/verify-wave3-pr1-rfc.sh
git add scripts/governance/verify-wave3-pr1-rfc.sh
git commit -m "Wave3 PR1 RFC: fail-closed 七谓词验证脚本"
```

---

## Task 8: 写 acceptance 清单

**Files:**
- Create: `docs/acceptance/2026-06-10-wave3-pr1-spec-gap-rfc.md`
- Reference 模板: `docs/acceptance/2026-06-03-wave2-pr1-baseline-h1-rfc.md`

- [ ] **Step 1: 按模板写四节（中文，action/expected/pass-fail，非编码人员可执行）**

- § 一、唯一总闸门：`bash scripts/governance/verify-wave3-pr1-rfc.sh; echo "exit=$?"` → 末尾 `(a)…(g) PASS` `ALL PASS` `exit=0`；+ 受限 TMPDIR 行（fail-closed 不静默）。
- § 二、逐项 scope 核对（与谓词对应）：每谓词一条 grep 命令 + 期望（如 tier 公式 anchor 命中 / 结算 reconcile 两锚 / provenance 红线 / replay 不变量 / supersede marker 位置）。
- § 三、契约文本目视核对：在 modules §E5/§E6/§F2 + plan §6.2.1 + outline §3.1 找到对应契约块，目视核对 7 契约要点齐全（tier 公式 / 手动强平 / appendDrawing / zoom / autosave 参数 / replay payload / 单事务 port+幂等迁移+fence+discard+provenance / 夜间双集）。
- § 四、范围与边界：`git diff --name-only "$(git merge-base origin/main HEAD)" HEAD` 恰好 7 文件；无 `ios/`/`.swift`/`.py`/`.sql`/`.yml`/`.xcodeproj`/冻结历史 doc。

**禁用措辞**（per `.claude/workflow-rules.json` forbidden_phrases）：不得出现「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」。**注（opus plan R1-L1）**：acceptance doc **不得原文复述上述禁用措辞列表**（描述抽象化，如「断言无 forbidden_phrases 残留」），否则 Step 2 grep 自撞 false-FAIL（wave2 acceptance 模板即不内联该列表）。

- [ ] **Step 2: 验证 acceptance 无禁用措辞**

Run: `grep -nE "验证通过即可|看起来正常|应该没问题|should work|looks fine" docs/acceptance/2026-06-10-wave3-pr1-spec-gap-rfc.md; echo "rc=$?"`
Expected: 无输出 `rc=1`。

- [ ] **Step 3: Commit**

```bash
git add docs/acceptance/2026-06-10-wave3-pr1-spec-gap-rfc.md
git commit -m "Wave3 PR1 RFC: acceptance 清单"
```

---

## Task 9: 端到端 gate 验证 + 修锚

**Files:** 无新建（修锚则回对应文件）

- [ ] **Step 1: 跑总闸门**

Run: `bash scripts/governance/verify-wave3-pr1-rfc.sh; echo "exit=$?"`
Expected: `(a) PASS` … `(g) PASS` `ALL PASS` `exit=0`。

- [ ] **Step 2: 若任一谓词 FAIL → 回对应 Task 修 anchor 措辞使 grep 命中（anchor 与脚本 grep 字面须逐字一致）**

修后重跑 Step 1 直至 `ALL PASS`。

- [ ] **Step 3: allowlist 核对**

Run: `git diff --name-only "$(git merge-base origin/main HEAD)" HEAD`
Expected: 恰好 7 文件（plan 文首 allowlist）；无业务/schema/CI 路径。

- [ ] **Step 4: Commit（若有修锚）**

```bash
git add -A && git commit -m "Wave3 PR1 RFC: 修锚使七谓词 ALL PASS"
```

---

## Self-Review（plan vs spec 覆盖核对）

- **§4.1 tier**：Task 1（plan 公式）+ Task 2（modules `currentPositionTier`）✓
- **§4.2 结算 reconcile**：Task 1 ✓
- **§4.3 夜间**：Task 4（modules §F2 双集）+ Task 5（plan §Phase 5 marker）✓
- **§4.4a 手动强平**：Task 2 ✓ ｜ **§4.4c appendDrawing**：Task 2 ✓ ｜ **§4.4d zoom**：Task 2 ✓
- **§4.4e/§4.5 replay payload**：Task 3 ✓
- **§4.6 autosave 参数化**：Task 3 ✓
- **§4.7 finalize 原子性+失败保留+port+幂等迁移+fence+discard+provenance**：Task 3 ✓
- **§五 grep gate 七谓词**：Task 7 ✓ ｜ **acceptance**：Task 8 ✓ ｜ **supersede**：Task 6 ✓
- **类型一致性**：accessor `currentPositionTier`、方法 `appendDrawing(_:)`、常量 `AUTOSAVE_TICK_INTERVAL`、谓词锚短语在 plan(Task7) 与 spec(§五)/modules(Task2/3) 逐字一致（Task 9 闭环校）。
- **0 业务代码 / 0 schema / 0 CI**：allowlist 仅 7 文档/脚本（Task 7(f)/Task 9 守护）✓
