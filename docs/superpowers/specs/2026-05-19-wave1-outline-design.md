# Wave 1 outline（v18，strip 后）—— 21 顺位单线

**前置**：Wave 0 已冻结于 tag `wave0-frozen-v1.4`（PR #54 merged 2026-05-18）；本 outline 兑现 §15.4 ledger H3 残留（"Wave 1 内部 plan 排序"）。

**目的**：列出 Wave 1 全部 21 个 anchor PR 的顺序 + 范围概要 + 依赖 + residual 折入策略，作为后续每锚 `superpowers:brainstorming` + `writing-plans` 的输入索引。本文件**仅**是顺位 + Phase + residual 映射 outline；每个顺位 PR 的实施细节（脚本契约 / 测试矩阵 / runbook / acceptance 详情）由该顺位 plan-stage 文档承担 + 自有 codex review 闭环。

**outline strip 历史**：v1-v17 在 §3.3 内联 admin runbook 详细 scope（C1-C7 约束 / PUT schema / 13 case test / bash 命令序列等）触发 branch-diff codex 18 轮"挖边界"无止境模式。v18 strip 至 outline 应有的抽象层级——所有 hardening 措辞作 1b plan-stage 输入而非 outline lock-down。

---

## 一、排序策略

- **单线 19 业务/契约 anchor + 1a/1b/1c 三连 governance = 21 顺位**：用户 2026-05-19 明示沿用 Wave 0 v6 outline 单线模式
- **每 PR ≤3 子项 / ≤500 行 prod**（per memory `feedback_planner_packaging_bias`）
- **codex 4-5 轮内收敛**（per `feedback_codex_plan_budget_overshoot`；超 5 轮 escalate user）
- **scope shrink before split**：先 grep 验证文档归属（per `feedback_brainstorming_grep_first`）；同模块 brainstorming abort ≥2 次 = 换 anchor 或开独立 spec 升级窗口（per `feedback_module_level_abort_signal`）

---

## 二、顺位总览（21 anchor）

| 顺位 | Anchor | 组 | 范围估算 | 依赖（仅列上游 Wave 1） | 关键 residual 折入 |
|---|---|---|---|---|---|
| **1a** | Workflow split + H1 spec amendment（catalyst-build 独立 always-trigger workflow + spec L1180-1182 改 Wave 2 验收 + §15.4 ledger H1 同步） | governance | YAML + 2 文档 wording；0 业务代码；3 子项 | — | **H9 deadlock 闭** + **H1 reclassify** |
| **1b** | Builder + verifier + admin runbook scripts + 测试矩阵 + **所有 mutation safety contracts**（artifact schema / redaction / rollback / serialization / idempotency / preflight / failure-mode tests）由 1b plan-stage 收敛 + 1b ship + 测过 | governance | Python + bash scripts + tests + harness；0 业务代码；3 子项 | 1a | — |
| **1c** | Admin execute 1b 已 ship 并测过的 runbook（仅 environment-specific inputs + 跑已 validated 命令序列）+ commit redacted evidence + ledger 回填；**1c 不引入新 script 代码、不定义新 safety contract**——若发现 1b artifact/rollback/preflight contract 缺失或 stale，1c 必须 fail-closed 退回 1b 补 | governance | admin step + redacted ledger 回填；0 业务代码 + 0 新 script；3 子项 | 1b（runbook + tests + safety contracts 全过） | **H8 + H10 close** |
| 2 | P1 APIClient（Task 0 = OpenAPI 空/部分 meta 响应 contract-freeze；Task 1+ = APIClient 实施） | 持久化 + 后端契约 | Task 0：openapi.yaml + tests；Task 1+：~400 行 lease 状态机 + fail-closed unknown handling | 1c（required check 已生效） | — |
| 3 | C2 DecelerationAnimator | 图表核心 | ~200 行 | — | — |
| 4 | C7 Gesture Arbiter | 图表核心 | ~300 行 | C2 | — |
| 5 | E3 TradeCalculator | 业务逻辑 | ~200 行（Result<Buy/Sell, TradeReason>） | — | — |
| 6 | E4 TrainingFlowController | 业务逻辑 | ~250 行 | E3 | — |
| 7 | **E2 RFC**（spec §4.2 reaudit governance PR） | governance | 仅 spec 文档；0 业务代码 | — | H2 close part 1 |
| 8 | E2 PositionManager 实施 | 业务逻辑 | ~300 行（按 RFC 决议） | E2 RFC | H2 close part 2 |
| 9 | C3 Candles + MA66 + BOLL | 图表渲染 | ~300 行（替换 PR #51 stub） | — | — |
| 10 | C4 Volume + MACD | 图表渲染 | ~250 行（替换 stub） | — | — |
| 11 | C5 Crosshair + Markers | 图表渲染 | ~200 行（替换 stub） | — | — |
| 12 | C6 DrawingTools + DrawingInputController | 图表渲染 | ~350 行（替换 stub；**仅 infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3**） | C7 | — |
| 13 | U3 SettlementView | UI 壳 | ~200 行 SwiftUI | E3 | — |
| 14 | U5 PositionPickerView | UI 壳 | ~200 行 SwiftUI HUD | E2 | — |
| 15 | U6 HistoryActionSheet | UI 壳 | ~200 行 SwiftUI | E4 | — |
| 16 | B1 import_csv | 后端 | ~200 行 Python | — | H6 part 1 (deps pin) |
| 17 | B2 generate_training_sets | 后端 | ~250 行 Python（CRC32 + 函数式 API） | B1 | H6 part 2 + H7（3-5 sample 训练组生产 + ledger 回填） |
| 18 | B3 FastAPI lease | 后端 | ~300 行 Python | B2 | H6 part 3 |
| 19 | B4 APScheduler | 后端 | ~150 行 Python | B3 | H6 part 4 |

**Phase 划分**：
- A CI gate prerequisite governance 三连（1a + 1b + 1c）
- B 网络基础 + 图表核心交互（2-4）
- C 业务逻辑（5-8，含 E2 RFC 独立窗口）
- D 图表渲染替换 stub（9-12）
- E UI 壳（13-15）
- F 后端 Python 线（16-19）

**H1 不在 Wave 1 PR 顺位（仅在 1a spec amendment 内 reclassify）**：spec L1180-1182 字面要求 "production handler 集成测试" 与 C2+C8+E5 三模块 orchestration **同 PR 落地**。C8 / E5 实施在 Wave 2，因此 H1 真正闭环在 Wave 2 C8 ChartContainerView 集成 PR；1a 内 spec amendment 仅 reclassify。

---

## 三、关键决策

### 3.1 后端 B1-B4 放 Wave 1 末段

**Why**：iOS chart 引擎 / 业务逻辑 spec-bias 风险最高（C2 / C7 / E2/E3/E4 历史易撞 codex），趁 spec §4.2 / §C 仍鲜活时跑完；末段 Python 作认知冷却。

**Trade-off**：H7 sample 训练组数据要等到顺位 17 才生产；中前期 iOS PR 只能跑 unit test，不能跑端到端 contract test。可接受——Wave 1 阶段端到端只在 Wave 2 集成时要求。

**Contract drift 缓解（per branch-diff R13 H2）**：顺位 2 P1 APIClient + 顺位 18 B3 FastAPI lease 跨 16 顺位有 drift 风险——加 **Wave 1 shared OpenAPI contract gate**：从 frozen `backend/openapi.yaml`（Wave 0 已冻）+ 顺位 2 Task 0 amend 部分定义的 empty/partial meta 响应字段 → 生成共享 fixture 目录（如 `tests/contract-fixtures/`）；P1 (顺位 2) 与 B3 (顺位 18) 各自 unit test **必须 import 同一套 contract fixtures** 跑通；P1 不能 fork local mock，B3 不能 fork local schema。fixture 文件作 frozen 契约层的一部分，B3 / P1 任一方需偏离 fixture 须先 RFC 修 fixture（独立 governance PR）。

### 3.2 E2 拆 RFC + 实施两 PR

**Why**：PR #36 8 轮 codex abort 教训（per `project_pr36_aborted`）；spec §4.2 vs codex bias "永久冲突" 必须先经 spec 章节修订才能继续。

- **顺位 7 E2-RFC**：仅修订 `kline_trainer_plan_v1.5.md` §4.2 / `kline_trainer_modules_v1.4.md` §E2；决议 precondition vs throwing API 选择 + 5 层 defense-in-depth 是否保留 + ledger 更新 §15.4 H2 状态；0 业务代码改动
- **顺位 8 E2 实施**：仅 `PositionManager.swift` + tests；严格按 RFC 决议；**不在 PR 中途切换 API 风格**；撞 ≥3 轮 codex 立即 abort（per `feedback_big_pr_codex_noncovergence`）

### 3.3 顺位 1 拆 1a / 1b / 1c 三连 governance PR

**Why split**：原顺位 1 4 子项（workflow + builder + verifier + spec amendment）违反 "≤3 子项 / ≤500 行 prod" 硬规则 + 跨 YAML/Python/Bash/Markdown 4 review 维度过载（PR #51 7 轮教训再现风险）；拆 3 连 PR 每个单一 review 维度。

**Why 三连而非 2 PR**：branch-diff codex R7 H1 教训——runbook script 不能与首次 mutation 同 PR（rollback 路径未先验过就上场）；必须 1b 先 ship + 测过 runbook，1c 才 admin execute。

**1a → 1b → 1c 序列**：
- **1a**：workflow split + H1 spec amendment（解 H9 deadlock，让后续 docs-only PR 不卡）
- **1b**：所有 builder / verifier / runbook scripts + 完整测试矩阵 + fixture / harness + **所有 mutation safety contracts**（artifact schema / redaction / rollback / serialization / idempotency / preflight / failure-mode tests）（**不动 origin protection**——仅 scripts + contracts + tests ship）
- **1c**：admin local execute 1b 已 ship 并测过的 runbook + commit redacted artifact + ledger 回填（**不引入新 script 代码、不定义新 safety contract**——若 1b contract 缺失或 stale，1c fail-closed 退回 1b 补）

每 PR ≤3 子项符合 `feedback_planner_packaging_bias`。每 PR 自有 brainstorming + writing-plans + codex review 三段独立闭环——本 outline **不内联** 具体 contract / 命令序列 / case 矩阵 / artifact schema 等实施细节，由各自 plan-stage 文档收敛（v18 strip 教训：outline 内联实施细节触发 codex 18 轮"挖边界"无止境模式）。

---

## 四、Residual 处理映射（§15.4 ledger H1-H10）

| Residual | 处理方式 | 顺位 |
|---|---|---|
| H1 L1167 production handler 集成测试 | 顺位 1a spec amendment（L1180-1182 + §15.4 ledger row 改 Wave 2 验收）+ Wave 2 C8 ChartContainerView 集成 PR 真正闭环 | 1a (spec amendment) + Wave 2 (test 落地) |
| H2 E2 spec §4.2 重审窗口 | 顺位 7 RFC + 顺位 8 实施两 PR | 7+8 |
| H3 Wave 1 内部 plan 排序 | **本 outline 文档 + 后续 writing-plans 兑现** | 本文件 |
| H4 M0.3 multi-file split 历史 over-claim | 已 PR 9 处理 | — |
| H5 Catalyst CI 持续守护 | 已 PR 9 处理 + 1a workflow split / 1c 配 required gate 延续 | 1a + 1c |
| H6 backend deps exact pin | 折入 B1-B4 各 PR Task 0（`backend/requirements.txt == X.Y.Z` + `docker-compose.yml` image digest pin） | 16-19 |
| H7 3-5 sample 训练组数据 | 折入 B1 (导入) + B2 (生成) PR；ledger 回填数据正确性 | 16-17 |
| H8 Catalyst CI required merge gate enforcement | 顺位 1c admin step | 1c |
| H9 workflow paths filter vs required check 架构性矛盾 | 顺位 1a workflow split | 1a |
| H10 acceptance §G 缺 machine-checkable required check 验证 | 顺位 1b scripts 实施 + 顺位 1c admin local execute + redacted ledger 回填 | 1b + 1c |

---

## 五、每锚 plan 流程统一约束

每个 Wave 1 anchor PR 走以下流程：

1. **Task 0 §15.3 评审策略前置**（per `docs/governance/wave1-plan-template.md`）
2. **brainstorming**（superpowers:brainstorming）：scope / 路线 / 关键风险点
3. **grep-first 验证文档归属**（per `feedback_brainstorming_grep_first`）
4. **writing-plans**（superpowers:writing-plans）+ codex plan-stage adversarial review（4-5 轮内收敛）
5. **subagent-driven-development** 实施 + verification-before-completion + requesting-code-review
6. **codex branch-diff adversarial review**（4-5 轮内收敛；超 5 轮 escalate user 走 attestation residual + admin merge 路径，**不绕过 required checks**）
7. **non-coder acceptance checklist**（中文，action / expected / pass-fail；禁忌词见 `.claude/workflow-rules.json`）
8. **memory 落地**：merge 后写 `project_pr<N>_<anchor>_merged.md` + 更新 `MEMORY.md` index

---

## 六、不在 Wave 1 顺位的工作

- **Wave 2 范围**：C8 ChartContainerView 集成（含 H1 真正闭环）、E5 TrainingEngine 实施、E6 TrainingSessionCoordinator 实施、P2 DownloadAcceptanceRunner 4 内部端口真实现、P4 DefaultAppDB 实施、U1 HomeView、U2 TrainingView、U4 SettingsPanel
- **Wave 3 范围**：Phase 2.5 水平线 MVP / Phase 3 完整流程 / Phase 5 磨光

---

## 七、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-05-19 | v1 (draft) | 起草 |
| 2026-05-19 | v2-v7 (plan-stage codex R1→R7 收敛) | R7 approve（详细 fix 历史此条目省略，见 v17 changelog 全文） |
| 2026-05-19 | v8-v17 (branch-diff codex R1→R10 收敛) | 拆 1a/1b/1c / 每轮 fresh fix（PUT schema / GET→PUT normalization / rollback path / preflight / artifact redact / 字段一致性等） |
| 2026-05-19 | v18 (branch-diff R11 strip) | R11 fresh 2 findings（HMAC + ETag/If-Match）暴露 outline 被当 production runbook 审 + 18 轮不收敛模式；user explicit 选 strip 根治：删除 §3.3 详细 scope（C1-C7 约束 / admin runbook 命令序列 / PUT schema / 13 case test / artifact schema）→ 推到顺位 1b/1c 各自 plan-stage 文档自有 codex review 闭环；outline 回归顶层 abstraction（仅 21 顺位表 + Phase + residual 映射 + 关键决策 + plan 流程统一约束） |
| 2026-05-19 | v19 (branch-diff R12 修) | finding 1 修：所有 mutation safety contracts（artifact schema / redaction / rollback / serialization / idempotency / preflight / failure-mode tests）由 1b plan-stage 收敛 + 1b ship + tested——之前 v18 把这部分推到 1c plan-stage 收敛是错的（mutation 安全合约应在 ship/test 阶段定义不是 execute 阶段）；1c 仅 environment-specific inputs + 跑已 validated 命令序列 + 若 1b contract 缺失或 stale fail-closed 退回 1b 补 |
| 2026-05-19 | v20 (branch-diff R13 修，user explicit accept residual) | F3 修：C6 顺位 12 row "Phase 2.5 水平线先行" 改成 "infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3"（消除与 §六 Wave 3 scope 的 ownership 矛盾）；F2 修：§3.1 加 "Contract drift 缓解 = Wave 1 shared OpenAPI contract gate"（P1 与 B3 共享 fixture 目录跑同一套契约 fixture；任一方偏离须先 RFC 修 fixture）；**F1 review budget escape hatch 作 residual**（process 级规则修订 = 改 CLAUDE.md / workflow-rules.json 不在本 outline scope；residual 记入 .claude/state/codex-attest-overrides.jsonl + docs/acceptance/<PR>.md）；user TTY override + admin merge 路径 push outline |
