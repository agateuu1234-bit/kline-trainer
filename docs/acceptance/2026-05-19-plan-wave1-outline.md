# PR Wave 1 Outline 验收清单（中文非-coder 可执行）

**PR 范围**：仅 1 文件 `docs/superpowers/specs/2026-05-19-wave1-outline-design.md`（v20）；0 业务代码 / CI workflow / 设置改动。

**Codex 对抗 review 统计**：
- plan-stage 7 轮：R1→R7 收敛 approve
- branch-diff 13 轮：R1→R13；R11 后用户授权 strip 根治；R12 修 1b/1c safety contract ownership；R13 = 2 high + 1 medium

## R13 unresolved findings 处理（user explicit accept residual）

| Finding | Severity | 处理方式 | 证据 / Follow-up |
|---|---|---|---|
| R13 F1 review budget escape hatch | high | **作 residual 不修**——属于 process-wide rule 修订（修 CLAUDE.md / `.claude/workflow-rules.json`），不在 outline 自身 scope；本 outline §五.6 措辞已 conform 现有 governance budget rule（per `feedback_codex_plan_budget_overshoot` + `feedback_autonomous_execution_mandate`）；review budget 收紧需独立 governance PR 走 brainstorming → writing-plans → codex review 三段；本 PR 不带 process rule 变更 | Follow-up：独立 governance PR 改 `.claude/workflow-rules.json` 加 "unresolved high/critical adversarial finding 时 admin merge prohibited" 限制词 + 改 CLAUDE.md backstop §4 相应措辞；ETA = Wave 1 顺位 1c merge 后 |
| R13 F2 Wave 1 contract drift gate | high | **修入 outline v20**：§3.1 加 "Contract drift 缓解 = Wave 1 shared OpenAPI contract gate"——P1 (顺位 2) 与 B3 (顺位 18) 共享 `tests/contract-fixtures/` 目录；各自 unit test 必须 import 同一套 contract fixture 跑通；任一方偏离须先 RFC 修 fixture（独立 governance PR） | 已 commit at v20 |
| R13 F3 C6 ownership 矛盾 | medium | **修入 outline v20**：顺位 12 C6 行 "Phase 2.5 水平线先行" 改 "infrastructure + tool 框架；Phase 2.5 水平线 MVP 归 Wave 3" | 已 commit at v20 |

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 在浏览器打开本 PR | 见 `docs/superpowers/specs/2026-05-19-wave1-outline-design.md` 新文件 | □ Pass / □ Fail |
| 2 | 该文件第 18 行起见"二、顺位总览（21 anchor）"表格 | 表格含 1a/1b/1c + 2-19 共 21 行 | □ Pass / □ Fail |
| 3 | 表格 21 行内每行都有 Anchor / 组 / 范围估算 / 依赖 / residual 5 列内容 | 无空行 / 无 TBD | □ Pass / □ Fail |
| 4 | §3.1 段末"Contract drift 缓解"出现 | 含 "P1" + "B3" + "tests/contract-fixtures/" 三关键字 | □ Pass / □ Fail |
| 5 | §四 Residual 处理映射表含 H1-H10 共 10 行 | 每行 Residual / 处理方式 / 顺位 三列均填 | □ Pass / □ Fail |
| 6 | §五 每锚 plan 流程统一约束 1-8 步骤完整 | 含 Task 0 §15.3 / brainstorming / writing-plans / codex review / acceptance / memory 全 8 步 | □ Pass / □ Fail |
| 7 | §六 Wave 2 范围列 C8 / E5 / E6 / P2 / P4 / U1 / U2 / U4 共 8 项 | 不含 C6 / Phase 2.5 水平线（已纠正 ownership）| □ Pass / □ Fail |
| 8 | §七 变更日志 v1 → v20 共 20 条记录（v2-v17 合并 1 条） | 含每个 fix 来源标 codex R1/R2/...R13 | □ Pass / □ Fail |
| 9 | GitHub PR Required status checks 列绿 | 当前 protected branches required checks 全 ✓（无 catalyst-build 因 H8 尚未配 required） | □ Pass / □ Fail |
| 10 | 本 acceptance 文件存在 | `docs/acceptance/2026-05-19-plan-wave1-outline.md` 在 PR 文件列表中 | □ Pass / □ Fail |

## merge 后

- ledger §15.4 H3 行回填"Wave 1 内部 plan 排序" status = closed at PR #N
- 立即 brainstorm 顺位 1a writing-plans 启动（依本 outline §五 1-8 流程）
