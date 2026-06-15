# PR Wave 3 13c 验收清单（中文非-coder 可执行）

**PR 范围**：Wave 3 顺位 13 收尾 doc-only 三件套——completion doc（功能交付确认 + reconcile §三.3 + residual 终态回填 + freeze 决策）+ 单一运行时矩阵 runbook + 机器可校验 grep gate + 本验收清单。**0 业务代码 / 0 CI workflow / 0 ruleset 改动**。

**source-of-truth**：spec `docs/superpowers/specs/2026-06-14-wave3-pr13-completion-design.md` §E；outline `docs/superpowers/specs/2026-06-09-wave3-outline-design.md` §三.3；plan `docs/superpowers/plans/2026-06-14-wave3-pr13c-completion.md`（**规划** source-of-truth = 任务结构/判据）。**权威状态 ledger = `docs/governance/2026-06-14-wave3-completion.md` 的 WAVE3-STATUS 机器块**（codex review R6-Med：plan 内 WAVE3-STATUS 示意块为 plan-stage 初稿、已标 SUPERSEDED，勿作权威状态引用）。

**评审通道**：doc-only 经 `codex:adversarial-review`（治理 doc 类，唯一 review 通道）；codex 周配额耗尽时 fallback opus 4.8 xhigh（documented）。

---

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR | 见 5 新文件：4 交付件（completion doc `docs/governance/2026-06-14-wave3-completion.md` + 矩阵 runbook `docs/acceptance/2026-06-14-wave3-runtime-matrix.md` + grep gate `scripts/governance/verify-wave3-completion.sh` + 本 acceptance）+ 1 plan（`docs/superpowers/plans/2026-06-14-wave3-pr13c-completion.md`）；0 业务 `.swift` / 0 CI workflow / 0 ruleset 改动 | □ Pass / □ Fail |
| 2 | 看 completion doc 一节 anchor 表 | 18 行（含「—」起点行 + 17 anchor：顺位 — / 1 / 2 / 3 / 4 / 5 / 6a / 6b / 7 / 8 / 9 / 10a / 10b / 11 / 12 / 13a / 13b / 13c）+ squash SHA 与 `git log origin/main` 一致；非-anchor #105 `2d2e28f` 作脚注 | □ Pass / □ Fail |
| 3 | 看二节 reconcile | 含 outline §三.3 原文引用「其完成是 Wave 3 关闭的硬前提，非『某天再说』」+「为何不宣布 closure」论证 + 点名对 spec §E.2 矩阵清单的 bounce 纠正（W3-11-R1 OPEN，矩阵不列 bounce device 行） | □ Pass / □ Fail |
| 4 | 看三节 residual 表（9 行） | A/B/C = CLOSED（引 13a #108 / 13b #109）；**D = PARTIAL**（§D smoke 用 fake verifier，runner↔真 verifier 接线未 smoke 覆盖，codex R4-Med）；运行时矩阵 = PARTIAL；**W3-11-R1**（bounce live 接线）= OPEN 且标 **Wave 3 功能完成门**（codex High：承诺交互未上线 → 功能完整性 PENDING-W3-11-R1）；**13a-R2**（跨 lease cache **data-loss**）= OPEN 顶层可见（codex R3-High：pre-existing，路由 P2-confirm RFC）；PR11-R1 / W1-R2 = OPEN NAS ship 门；人读表与机器块 WAVE3-STATUS（含 `feature-completeness: PENDING-W3-11-R1` + `residual-D-e2e-smoke: PARTIAL` + `known-defect-13a-R2-…: OPEN`）事实一致 | □ Pass / □ Fail |
| 5 | 看五节 freeze 决策 | 含字面「不打 freeze tag」+ 3 理由（无 recorded 矩阵不满足 §三.3 硬门 / ship 门未关 store-frozen 语义不成立 / 与 Wave 1/2 一致） | □ Pass / □ Fail |
| 6 | 终端进工作树根目录后跑 `bash scripts/governance/verify-wave3-completion.sh` | 末行 `[verify-wave3-completion] PASS：…`，退出码 0（A/B/C CLOSED + D PARTIAL + W3-11-R1/13a-R2/PR11-R1/W1-R2 OPEN + WAVE3-STATUS 诚实〔含 feature-completeness PENDING-W3-11-R1〕+ 矩阵 fixture 机制 + §三.3 三连合取指针就位） | □ Pass / □ Fail |
| 7 | 看矩阵 runbook | 含 `KLINE_SEED_FIXTURE=1` 启动机制 + 7 项（6 数据交互 pinch 3 / 水平线 4 / 十字光标 5 / 手动强平 7 / replay 结算 8 / 主题 9 + **顺位 2 竖屏/iPad 窗口**）+ save-resume/复盘/replay 端到端 + 关闭前其余硬门（Wave 2 两 runbook + 帧预算，全 PASS 判据）+ bounce/W3-11-R1 排除节 + §B toast 归属澄清块 | □ Pass / □ Fail |
| 8 | 看 codex 对抗 review verdict | APPROVE（或 codex 配额耗尽 → opus 4.8 xhigh fallback APPROVE / accept residual + override） | □ Pass / □ Fail |

---

## 范围注（诚实边界）

- 本 PR 定位 = **「Wave 3 功能交付确认 + 运行时验收待回填」**，**非「Wave 3 正式关闭」**。device/sim 运行时矩阵实测执行 = 用户 device 职责（本 PR 仅交付可执行 runbook + §C fixture 使其可玩）。
- **正式关闭 + freeze tag** 待用户在 device 跑完矩阵 runbook 并记录结果后（per outline §三.3 硬门；见 completion doc §二/§五）。
- **W3-11-R1**（bounce live 接线）= OPEN，是 **Wave 3 功能完成门 + 正式关闭前提**（顺位 11 承诺交互未上线 → 功能完整性 PENDING-W3-11-R1，codex review High）——**计入**功能完整性账（区别于下二门）；解门 = fast-follow 实施 PR 实现 live 接线 + 回填运行时 acceptance。PR11-R1（生产 backendBaseURL）/ W1-R2（真实样本数据）= OPEN，NAS scope ship 门，**不**计入 Wave 3 功能完成度。

---

## Residual（codex review 残留）

| Residual | 来源 | 处理 |
|---|---|---|
| **13c-R1：帧预算 device 测量「采样≠帧相关」** —— Time Profiler 分别取 make/draw 峰值相加 ≠ 同帧真实合并耗时（上/下双图实例 + make 调度 draw 延后）；严谨测量需 `os_signpost` 帧相关 instrumentation | codex R8-H1 | **accept residual**：根治 = 顺位 12 #104 **生产代码** signpost instrumentation，超 13c doc-only scope。doc-only 已做：矩阵 ③ caveat 标合并峰值为「指示性上界」，临界值须 signpost 复核 → fast-follow perf-instrumentation PR |
| **13c-R2：帧预算 fixture 欠载** —— §C seed `.m60`=12/`.daily`=6 < `RenderStateBuilder` 80-visible 渲染负载 → 经 §C fixture 测的是欠载图表 | codex R8-H2 | **accept residual**：根治 = 13b `DebugFixtureData` **代码增强**（各 profiled 周期 ≥80 蜡烛），超 13c doc-only scope。doc-only 已做：矩阵 ③ caveat 要求记录周期+渲染蜡烛数，<80 标「欠载非满载 PASS」 → fast-follow perf-fixture PR |

**codex review 收敛说明（accept residual + override）**：doc-only 13c 经 `codex:adversarial-review` **8 轮 branch-diff**（配额未耗尽，全程真 codex）。**R1–R7 全部实质 finding 已修**（每轮新的、bounded、in-scope honesty/robustness 问题，非重复）：R1 bounce/feature-completeness PENDING + W3-11-R1 功能门；R2 gate fail-open 根治（块解析）+ u2-gesture；R3 13a-R2 data-loss 升顶层 ledger + awk 拒未闭合块 + 关闭须全 PASS；R4 D→PARTIAL（fake verifier 不掩盖）+ PR12 手势修正；R5 make+draw 合并判据 + Debug↔Release seed 衔接 + 散文↔机器块 drift；R6 cache Caches-only 纠正 + action 列 make+draw + plan SUPERSEDED；R7 补 顺位 2 orientation 进闭关矩阵。**R8 两 High 转向 frame-budget 测量精度无止境下钻**，其根治均为**已 merged PR 的生产代码改动**（os_signpost 帧相关 instrumentation #104 / ≥80 蜡烛 perf fixture #109），**超 13c doc-only scope**。依 `feedback_big_pr_codex_noncovergence`（>5 轮 escalate；本 PR 已 8 轮）+ `feedback_codex_distributed_reliability_drilldown`（codex 子域无止境下钻、根治越界 → accept residual + override）：**doc-only 如实记录限制（矩阵 ③ caveat + 本残留 13c-R1/R2）已做；代码级根治 accept residual + user TTY attest-override + admin merge**。整体 opus 4.8 xhigh plan-review R1→R2 APPROVE + spec-compliance PASS + code-quality APPROVED + 最终整体 review R1→R2 APPROVE；grep gate fail-closed（块解析 + 全行 + 拒重复 + 拒未闭合 + 红验证多路）。
