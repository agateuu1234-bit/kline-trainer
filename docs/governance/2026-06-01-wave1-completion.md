# Wave 1 完成确认（轻量收尾，doc-only）

**日期**：2026-06-01
**性质**：Wave 1 outline（v20，PR #55）的 21 个 anchor 全部 merged 后的轻量收尾——residual 终态回填 + 完成确认。**不打 freeze tag**（见末段决策）。0 业务代码 / 0 CI / 0 ruleset 改动。

---

## 一、21 anchor 交付清单（全 merged）

| 顺位 | Anchor | PR | squash SHA |
|---|---|---|---|
| — | Wave 1 outline v20（H3，非 anchor，列为起点） | #55 | `97d5e89` |
| 1a | Catalyst CI workflow 拆分（解 H9）+ H1 reclassify | #56 | `fa0ddda` |
| 1b | Required-checks 治理脚本 + mutation safety | #57 | `8a2f9ca` |
| 1c | Required-checks admin execute（H8/H10 close） | #58 | `f9aab4d` |
| 2 | P1 APIClient + M0.4 gate 闭合 | #59 | `706b29a` |
| 3 | C2 DecelerationAnimator | #60 | `fe76ca0` |
| 4 | C7 ChartGestureArbiter | #61 | `48a08ad` |
| 5 | E3 TradeCalculator | #62 | `63f4da0` |
| 6 | E4 TrainingFlowController | #63 | `da981fc` |
| 7 | E2 RFC（spec §4.2 重审） | #64 | `fc98ebf` |
| 8 | E2 PositionManager 实施 + CONTRACT_VERSION 1.4→1.5 | #65 | `785ea98` |
| 9 | C3 Candles + MA66 + BOLL | #66 | `4015c3e` |
| 10 | C4 Volume + MACD | #67 | `a0d23f7` |
| 11 | C5 Crosshair + Markers | #68 | `6940c18` |
| 12 | C6 DrawingTools 基础设施 | #69 | `b770ee1` |
| 13 | U3 SettlementView | #70 | `ae21d87` |
| 14 | U5 PositionPickerView | #71 | `271ae9b` |
| 15 | U6 HistoryActionSheet | #72 | `7435d4b` |
| 16 | B1 import_csv | #73 | `51323ad` |
| 17 | B2 generate_training_sets | #74 | `69cc7f2` |
| 18 | B3 FastAPI lease | #75 | `59b6d1b` |
| 19 | B4 APScheduler | #76 | `1c3615a` |

**21 anchor = 1a/1b/1c + 顺位 2-19，全部 merged。** 每 anchor 的验收清单见各自 `docs/acceptance/` 文件；每 anchor 的 merge 记录见 memory `project_pr<N>_*_merged`。

---

## 二、residual H1-H10 终态（基于 `docs/governance/2026-05-17-wave0-signoff-ledger.md` §28 表回填）

| ID | 终态 | 依据 |
|---|---|---|
| H1 | **→ Wave 2**：1a (#56) 已做 spec amendment（modules §C1b 闸门 #4 reclassify Wave 1→Wave 2）；真正闭环 = Wave 2 顺位 7 C8 集成 anchor（C2 + E5a/E5b + C8 三模块在场时验证；Wave 2 顺位 1 RFC 松绑措辞） | #56 |
| H2 | **CLOSED**：E2 RFC (#64) + 实施 (#65) merged；CONTRACT_VERSION bump 1.4→1.5 已在 #65 落地 | #64 + #65 |
| H3 | **CLOSED**：Wave 1 内部 plan 排序 = outline v20 (#55) | #55 |
| H4 | **CLOSED**（Wave 0）：M0.3 multi-file split | Wave 0 |
| H5 | **CLOSED**：Catalyst CI 持续守护 = 1a 拆 always-trigger workflow + H8/H9/H10 配套 | #56 + 1c |
| H6 | **PARTIAL**：`backend/requirements.txt` 6 依赖全 `==` exact pin **已做**（fastapi==0.115.12 / uvicorn==0.34.2 / apscheduler==3.10.4 / pandas==2.2.3 / pandas-ta==0.3.14b1 / asyncpg==0.30.0）；但 `docker-compose.yml` 用 image **tag** `postgres:15.12`（非 `@sha256:` digest）→ image digest pin **未做** → **新 residual W1-R1** | #73-#76 |
| H7 | **OPEN / deferred**：3-5 个样本训练组数据 **未生成**（需 NAS 真实 CSV 数据源 + 库；见 B2 PR #74 的 B2-R2，user 选项 1 defer）→ **新 residual W1-R2** | #74 (B2-R2) |
| H8 | **CLOSED**：顺位 1c (#58) 配 required check `Mac Catalyst build-for-testing on macos-15`（integration_id=15368） | #58 |
| H9 | **CLOSED**：顺位 1a (#56) 拆 always-trigger workflow（无 paths filter） | #56 |
| H10 | **CLOSED**：顺位 1c (#58) `verify-required-checks.sh --mode assert` + live `default_branch==main` 双谓词 | #58 |

**净结果**：H2/H3/H8/H9/H10 本 Wave close；H1 → Wave 2（C8）；H4/H5 Wave 0 已 close；**H6 部分（deps pin done，image digest 转 W1-R1）/ H7 deferred（转 W1-R2）**。

---

## 三、Wave 1 新增 residual（W1 系列 + 各 anchor deferred 汇总指针）

| ID | residual | 处理路径 |
|---|---|---|
| W1-R1 | `docker-compose.yml` image digest pin 未做（用 tag `postgres:15.12`） | supply-chain 加固，内网单容器 + 确定性 tag 现可接受；NAS 部署 PR 时改 `postgres@sha256:<digest>` |
| W1-R2 | 3-5 样本训练组数据未生成（H7） | 需 NAS 真实数据源；归 NAS 部署 / 数据生产任务（B1 import + B2 generate 真跑） |
| — | 各 anchor 自身 deferred（如 B4-R1/R4/R5/R6、C3-C6 交 C8 的渲染 residual、C2/C7 运行时 gate 等） | 见各 `project_pr<N>_*_merged` memory 与各 PR plan 的 residual 段；多数归 Wave 2 集成（C8/E5/E6）或后续部署 PR |

---

## 四、决策：Wave 1 不打 freeze tag

**与 Wave 0 的区别**：Wave 0 freeze ceremony（PR #54 + tag `wave0-frozen-v1.4`）冻结的是 **spec 契约首版**（spec/modules v1.4 + §15.2 deps freeze + §15.4 ledger）。Wave 1 主体是**按已冻 spec 实现 21 个模块的代码**——spec 契约本身在 Wave 1 仅一处变更（E2 `CONTRACT_VERSION` 1.4→1.5，已在 #65 内随实施落地并经 codex review）。

**决策**（user explicit 轻量收尾，2026-06-01）：Wave 1 **不**新建 signoff ledger、**不**打 `wave1-frozen` tag、**不**改 README freeze 章节。理由：
1. 无 spec 契约首冻语义（仅 E2 bump，已逐 PR review + frozen tag namespace 不适用实现代码）。
2. 每 anchor 已各自经 codex attest + acceptance + memory，provenance 已分布式留痕。
3. freeze tag / signoff ledger 的成本（三层 protected-tag gate + 三角色签字）对「实现 Wave」收益低。
4. 若后续需要正式冻结点（如 Wave 2 启动前基线），可届时补打 tag。

---

## 五、Wave 2 边界（确认，不在本收尾 scope）

Wave 1 outline §六明列 Wave 2 范围：**C8 / E5 / E6 / P2 runner / U1 / U2 / U4** + H1 真正闭环（C8 ChartContainerView 集成）。〔baseline reconcile（Wave 2 顺位 1 RFC）：**P4 `DefaultAppDB` + P2 4 内部端口已 Wave 0 落地（PR #42/#43），不在 Wave 2；Wave 2 仅 P2 runner**。〕Wave 2 outline 排序为独立规划 session（brainstorming + writing-plans），不在本轻量收尾内。
