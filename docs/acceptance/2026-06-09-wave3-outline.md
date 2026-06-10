# PR Wave 3 Outline 验收清单（中文非-coder 可执行）

**PR 范围**：仅 1 文件 `docs/superpowers/specs/2026-06-09-wave3-outline-design.md`（v13）；0 业务代码 / CI workflow / 设置改动。

**Codex 对抗 review 统计**（branch-diff，11 轮，从未 clean APPROVE）：
- R1（3 high）结构：可上架 claim / app-target CI 前置 / 运行时阻塞
- R2（3 high）结构：运行时矩阵 / 画线 source-of-truth / orientation
- R3（2H+2M）：back-save 失败 / fixture provisioning / iPad 窗口 / 交易反馈
- R4（2 high）持久化：finalize 原子 / autosave
- R5（2 high）持久化：周期保存契约（**纠正 Claude pushback 误判**）/ finalize teardown
- R6（2 high）持久化：终态 autosave 竞争 / 单事务 port 治理
- R7（1 high）并行模型：3/5 共享视口轨内串行
- R8（2 high）并行模型：TrainingEngine 跨轨共写→engine 序列化 / discard 复活
- R9（2H+1M）并行模型：8 replay engine 边界 / DAG 编号矛盾 / zoom RFC 治理
- R10（2 high）：8→10 DAG 边 / finalize 幂等 schema 迁移 owner
- R11（1H+2M）：持久化基础 10a 早置 / 6←1,2 DAG 边 / provenance 恢复

**收敛性质**：每轮 finding 均 grep 核实为真、逐条修入（v1→v13）。codex R9/R11 明确确认主结构修 present。R3/R5/R6/R8/R10 持久化 reliability = documented `feedback_codex_distributed_reliability_drilldown`（P6 先例 8 轮→accept+override）；R7-R11 并行/DAG = Wave 1 v18「inline 细节→edge-mining→strip」同型。结构整类已 owns，剩余为 plan-stage 职责。

## user explicit accept residual + override（2026-06-10 user TTY 授权）

| 项 | 处理方式 | 证据 / Follow-up |
|---|---|---|
| codex 从未 clean APPROVE（持续 reliability/scheduling drilldown） | **user explicit accept + attestation override + admin merge**（沿用 P6 + Wave 2 多锚先例）。outline 结构已扎实（13 anchor + 双轨并行 + canonical DAG + 全 residual owns），剩余 codex 会挖的 plan-level 细节（finalize/discard reliability 子case、scheduling 微调）归**顺位 1 RFC plan-stage + 顺位 6/10 plan-stage**（各有独立 codex 闭环） | override ledger entry（user TTY `attest-override.sh`）；下游 plan 各自 review |
| 持久化健壮性整类（autosave/back-save/finalize 保留/原子 port/幂等/终态 fence/discard/schema 迁移/provenance 恢复） | **已 owns 入 RFC item 6/7（a-e）+ 顺位 10a/10b**——契约层钉死，实现细节归顺位 10 plan-stage | 见 spec §三.1 item 6/7 + 顺位 10 行 |
| engine 跨轨共写 | **已根治**：所有 engine 契约变更序列化顺位 6（serial neck），消费锚只消费冻结 API | 见 spec §二·并行执行模型 |

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` 新文件 | □ Pass / □ Fail |
| 2 | 文件标题行 | 含「Wave 3 outline（v13）」+「双轨并行顺位」 | □ Pass / □ Fail |
| 3 | §二「顺位总览（13 anchor）」表格 | 含顺位 1-13 共 13 行，每行 Anchor/组/范围/依赖/residual 5 列均填，无 TBD | □ Pass / □ Fail |
| 4 | §二·并行执行模型 段 | 含「轨 G」「轨 T」「Gate」+ 轨内串行规则 + TrainingEngine 序列化（engine 契约集中顺位 6）| □ Pass / □ Fail |
| 5 | §二 canonical DAG | 含「顺位编号 = 标识符非执行顺序」+ 每锚 → 上游边（含 6←1,2 / 10a←1,6 早置 / 7,8←10a / 9←all-views）| □ Pass / □ Fail |
| 6 | §三.1 RFC 须钉死契约 | 共 8 项（tier/结束总资金/夜间调色板/E5E6 扩展含 zoom+replay/replay 结算/中断持久化/finalize 含 schema 迁移+discard/grep gate）| □ Pass / □ Fail |
| 7 | §四 Residual 映射表 | 每行 Residual/来源/处理/顺位 四列均填，含 R1-R11 各 finding 归属 | □ Pass / □ Fail |
| 8 | §六 不在 Wave 3 | 含 Phase 4 完整画线 / NAS（PR11-R1+W1-R2 为「未完成 ship 门」）/ iPad 横屏 layout 三类排除 | □ Pass / □ Fail |
| 9 | §七 变更日志 | v1 → v13 共 13 条，每条标 codex R1/R2/.../R11 来源 | □ Pass / □ Fail |
| 10 | override ledger 条目 | `attest-override.sh wave3-outline` 由 user TTY 执行后，override 审计 log 含本分支条目 | □ Pass / □ Fail |
| 11 | 本 acceptance 文件存在 | `docs/acceptance/2026-06-09-wave3-outline.md` 在 PR 文件列表 | □ Pass / □ Fail |

## merge 后

- memory 落地：写 `project_pr<N>_wave3_outline_merged.md` + 更新 `MEMORY.md` index
- 下一步：进入 writing-plans 排 **顺位 1 RFC**（spec-gap 治理 RFC：tier 公式 + 结束总资金显示 + 夜间调色板 + E5/E6 扩展含 zoom/replay + 中断持久化 + finalize/discard/schema 契约），依 spec §三.1 八项
