# acceptance 闸门写死字面量过期导致长期假绿 · 设计 spec

**日期**：2026-08-31
**基线**：`origin/main` `1437529`
**分支**：`fix/acceptance-stale-literals`，worktree `.dev/worktree/fix-acceptance-stale-literals`
**改动面**：两个 shell 脚本各一处 —— `scripts/acceptance/plan_1f_m0_1_schema_versioning.sh`（删 6 条断言）与 `scripts/acceptance/plan_1b_m0_2_rest_api.sh`（改 1 条断言）

**本 spec 自成一支**，决策编号 **D1–D5** 仅在本文件内有效。

**类别**：治理 / 工具链改动 —— 按 `CLAUDE.md`「Repository governance backstop」走
`superpowers:brainstorming` → `superpowers:writing-plans` → `codex:adversarial-review` → PR。

**触发来源**：PR **#179**（hardening-6 闸门叠罗汉死锁修复）的 `acceptance` 检查变红。
排查后确认该红灯**与 #179 无关**，是既有故障。本 spec 修的是这个既有故障。

---

## 0. 一句话

必需闸门 `acceptance` 里嵌套的两个 acceptance 脚本，各有**写死的字面量已经过期**
（4 个版本号 + 1 个测试数量）；因为该闸门对绝大多数 PR **短路放行**，这些字面量
从不被执行、悄悄烂掉，使闸门**至少从 2026-08-16 起处于假绿状态**。

---

## 1. 症状与发现路径

**症状**：PR #179 的必需检查 `acceptance` 失败，`13 passed, 1 failed`，
失败项 `regression: Plan 1f schema versioning`。

**这个红灯与 #179 无关**，三条独立证据：

| # | 证据 | 来源 |
|---|---|---|
| 1 | 2026-08-16 在**无关分支** `chore/attest-toolchain-merge` 上，CI 里同一项失败，同为 `13 passed, 1 failed` | `gh run view 31957080150 --log-failed` |
| 2 | 在**干净的 `origin/main`**（`1437529`，零 #179 改动）本地跑同一脚本 → 同样失败 | 一次性 worktree 实跑 |
| 3 | #179 改的是 workflow 触发条件与一条 `git fetch`，与文档断言脚本零接触面 | 读 #179 的 diff（2 删 9 加，全在 `on:` 块与 `Detect relevant changes` 步骤内） |

---

## 2. 根因：写死的字面量 + 从不执行的闸门

### 2.1 闸门至少从 2026-08-16 起假绿

`hardening_6_gate.yml` 的 job 在「没碰那 8 个治理文件」时**短路放行**（echo 一句以成功收场）。
实测最近 25 次运行：

| 类别 | 次数 | 时长 | 结果 |
|---|---|---|---|
| **短路放行**（脚本零执行） | **23** | 16–30 秒 | 全部 success |
| **真跑满** | **2** | 1149 秒 / 104 秒 | **全部 failure** |

⇒ **这个必需闸门显示「通过」的 23 次，一次都没真正验证过任何东西。**
它真正执行过的两次，两次都是红的。

> 这与 `feedback_uikit_gated_evidence_traps` 记录的假绿家族同型：
> **「成功」字样配零执行量 = 假绿**。区别在于这次的零执行量是**设计内的短路**，
> 因此更隐蔽 —— 短路本身是正确的（它防的是另一种死锁），
> 错的是**没人意识到「短路 = 这些断言从不被执行 = 它们会静默腐烂」**。

### 2.2 病灶一：`plan_1f` 的 4 个版本号字面量过期

`scripts/acceptance/plan_1f_m0_1_schema_versioning.sh` 断言
`docs/governance/m01-schema-versioning-contract.md` 的版本矩阵含特定字面值。
文档已正常演进多次（文档内**逐条记着** bump 记录），脚本从未同步：

| 断言期望 | 文档实际 | 差距 |
|---|---|---|
| `CONTRACT_VERSION` = `"1.5"` | `"1.13"` | 8 个版本 |
| PostgreSQL = `0003_v1.3` | `0004_qmt_price_double_and_coverage` | 1 个 migration |
| app.sqlite = `0003_v1.4_purge_leased` | `0010_v1.13_drawing_default_style` | 7 个 migration |
| Swift 模型 = `1.3` | `1.4` | 1 个版本 |

另 2 条矩阵断言（训练组 SQLite `1`、P2 journal `v2`）恰好未变，仍通过。

### 2.3 病灶二：`plan_1b` 的测试数量字面量过期

`scripts/acceptance/plan_1b_m0_2_rest_api.sh` 第 33–35 行：

```bash
# 必须确切 11 passed；若将来 test 数变化说明 spec drift，label 必须同步更新
run "pytest: 11 OpenAPI invariants" \
    bash -c "cd backend && python3 -m pytest tests/test_openapi.py -q | tee /tmp/plan1b-pytest.out && grep -q '^11 passed' /tmp/plan1b-pytest.out"
```

实测该 pytest **自身报 `19 passed in 1.36s`（全部通过）**，断言却判 NG ——
因为它要求**正好 11**。测试从 11 个正常增长到 19 个，作者注释里写明的「必须同步更新」
从未发生，原因同 2.1：**这个脚本从不运行**。

### 2.4 关键触发时机错配（病灶一的深层原因）

仓内**已有**一个覆盖同一份矩阵的守卫：
`ios/Contracts/Tests/KlineTrainerPersistenceTests/M01MatrixSyncGuardTests.swift`。

| | Swift 守卫 `M01MatrixSyncGuardTests` | `plan_1f` 的 shell 副本 |
|---|---|---|
| 覆盖行 | 顶层版本 / app.sqlite / Swift 模型（**3 行**） | 6 行 |
| 触发时机 | `ios/Contracts/**` 改动 → `swift test on macos-15`。**`CONTRACT_VERSION` 正是在 iOS 契约代码里被 bump 的** | 那 8 个治理文件改动。**m01 文档不在其中** |
| 当前状态 | **绿、且值为 `1.13` 与文档同步**（本地实跑：2 tests, 0 failures） | **4/6 已烂** |
| 防空转 | 有（`XCTAssertGreaterThanOrEqual(r.count, 5)`）+ 解析器免疫测试 | 无 |

**Swift 守卫的注释里直说了它的由来**：「本片 spec 自己点名的『矩阵停在 0003、代码已到 0009』
正是『要求同步但无人强制』的产物」—— 也就是说，**这个腐烂问题被发现过一次，
并已用一个触发时机正确的守卫解决了；shell 副本是被遗留的、触发时机错误的那一份。**

---

## 3. 已核实事实台账

| # | 事实 | 证据来源 |
|---|---|---|
| F1 | #179 的 CI 失败项 = `regression: Plan 1f schema versioning`，`13 passed, 1 failed` | `gh run view 33315497789 --log-failed` |
| F2 | 2026-08-16 无关分支上同一项失败、同样数字 | `gh run view 31957080150 --log-failed` |
| F3 | 干净 `origin/main` 上本地复现同一失败 | 一次性 worktree `origin/main@1437529` 实跑 |
| F4 | 闸门最近 25 次运行：23 次短路（16–30s，全 success）、2 次跑满（**全 failure**） | `gh run list --workflow=hardening_6_gate.yml --limit 25` + 时长计算 |
| F5 | 4 个版本号字面量与文档实际值的具体差距 | 读脚本 + `awk` 切出文档矩阵章节 |
| F6 | `plan_1b` 的 pytest 实际 `19 passed`，断言要求 `^11 passed` | CI 等价环境实跑 `/tmp/p1b.log` |
| F7 | **全仓 19 个 acceptance 脚本中，含「版本号样式写死值」的只有 `plan_1f` 一个** | `grep -lE` 全量扫描 + 放宽模式复扫 |
| F8 | **全仓 19 个 acceptance 脚本中，含「写死测试数量」断言的只有 `plan_1b` 一条** | `grep -nE "[0-9]+ passed"` 全量扫描 |
| F9 | 另两个引用 m01 文档的脚本（`plan_e2` / `plan_m0_5`）只做**存在性 / 交叉引用**检查，无版本字面量 | 逐个 `grep -B1 -A2` 打开看 |
| F10 | `M01MatrixSyncGuardTests` **无 UIKit 门**（`canImport(UIKit)` 命中数 = 0），在 `swift test on macos-15` 中运行 | 读文件头 + 读 `swift-contracts-smoke.yml` |
| F11 | 该 Swift 守卫**当前为绿**：本地 `swift test --filter M01MatrixSyncGuardTests` = **2 tests, 0 failures** | 本地实跑 |
| F12 | 该守卫断言的三个值（`"1.13"` / `0010_v1.13_drawing_default_style` / `1.4`）**与文档当前值一致** | 读测试源码第 52/53/55 行 + 读文档矩阵 |
| F13 | 该守卫自带**防空转**（`XCTAssertGreaterThanOrEqual(r.count, 5)`）与**解析器免疫**测试（防「bump 记录喂饱整节 contains」） | 读测试源码第 51、60–77 行 |
| F14 | **依赖齐全时（CI 等价环境）`plan_1f` 的真实失败面是 5 项**：4 条矩阵 + `regression: Plan 1b` | 一次性 venv（pglast 7.13 / PyYAML 6.0.3 / openapi-spec-validator 0.7.2 / pytest 8.4.2）+ 干净 main 实跑 |
| F15 | 纯本地（缺依赖）跑出 7 项失败，其中 3 项（Plan 1 pglast / Plan 1b yaml / Plan 1c yaml）是**本机缺包噪音**；CI 会安装 `backend/requirements-dev.txt` | 对比 F14 与纯本地结果；读 `hardening_6_gate.yml` 的依赖安装步骤 |
| F16 | **`plan_1f` 与 `plan_1b` 都不在闸门的「相关文件名单」里** —— 名单只含 `scripts/acceptance/hardening_6_framework.sh` 与 7 个 `.claude` / `tests/hooks` / workflow 路径 | 读 `hardening_6_gate.yml` `Detect relevant changes` 步骤的 grep 正则 |

---

## 4. 决策

### D1　`plan_1f`：删除 6 条矩阵行断言

删除 `plan_1f_m0_1_schema_versioning.sh` 中全部 6 条 `matrix row: ...` 断言
（含它们各自的 `awk` 切片子进程），**不替换、不改写、不迁移**。

**理由三条，逐条锚到台账：**

1. **触发时机错误 ⇒ 零信号（F16 / 2.4）**。这 6 条只在那 8 个治理文件改动时执行，
   而 m01 文档**不在**其中 —— 它们**永远不会在「矩阵真的变了」的时候运行**，
   只会在无关 PR 上空转。一个永远不在正确时机运行的断言，提供的信号为零。
2. **其中 3 条已被一个触发时机正确、且确实在维护的守卫覆盖（F10–F13）**。
   `M01MatrixSyncGuardTests` 由 `ios/Contracts/**` 改动触发 —— 而 `CONTRACT_VERSION`
   正是在那里被 bump 的；它当前为绿、值与文档同步、且自带防空转与解析器免疫。
3. **它们已经腐烂并正在造成实际损害（F1 / F5）**：4/6 过期，
   直接把必需闸门 `acceptance` 判红，阻塞 PR #179。

**为什么不选「把 4 个数字改成当前值」**：那不触碰根因（F4：脚本从不运行）。
改完之后它会**以同样的方式、同样无人察觉地再次腐烂**，只是把下一次事故推迟。

### D2　`plan_1b`：把「正好 11 passed」改为「≥11 且零失败」

把 2.3 引用的那条断言改为：**pytest 必须成功退出，且 passed 数 ≥ 11**。

**理由：**

1. **区分「加测试」与「删测试」**。原断言的注释说「test 数变化说明 spec drift」，
   但**新增不变量测试是健康行为，不是 drift**（11 → 19 正是这样发生的）；
   真正危险的是**有人删掉不变量测试**。「≥ 下限」恰好只抓后者。
2. **同仓已有先例（F13）**：维护良好的 `M01MatrixSyncGuardTests` 用的正是
   `XCTAssertGreaterThanOrEqual(r.count, 5)` 作为防空转下限。本决策与之同构。
3. **顺带消除一个既有的吞退出码结构**：原写法 `pytest ... | tee ... && grep`，
   `&&` 判的是 `tee` 的退出码，pytest 自身的失败被管道吞掉
   （`feedback_gate_pipe_swallows_exit_code` 同型）。改后必须**直接读 pytest 的退出码**。
   ⚠️ 这是 D2 的**必要副产物**（要判「零失败」就必须读退出码），**不是**额外扩展。

**下限取 11 而非 19**：11 是该断言原本记录的不变量数量下限，语义是「不得少于当初」；
取 19 会让下次正常新增测试后再次面临同一问题的镜像形态（虽然方向相反，但仍是硬编码跟踪）。

### D3　不给 Swift 守卫补 PostgreSQL 行（残留缺口，记 backlog）

删除 D1 那 6 条后，**PostgreSQL migration id 行将没有任何自动守卫**。

**本次不补**，理由：该行的正确触发条件是 **`backend/sql/**` 改动**，
而 `M01MatrixSyncGuardTests` 由 `ios/Contracts/**` 触发 —— 把它塞进 Swift 守卫
会**造出一个新的触发时机错配**，即本 spec 正在修的那个毛病的镜像。
正确做法需要一个 backend 侧的守卫，属独立设计问题。

**记为残留风险 R1，归入独立 backlog。**

> 同理，删除后「训练组 SQLite `1`」与「P2 journal `v2`」两行也无守卫。
> 二者当前值恰好未变，故此前未暴露；一并归入 R1 的同一个 backlog 项。

### D4　不改闸门的「相关文件名单」

不把 `plan_1f` / `plan_1b`（或其它嵌套脚本）加进 `hardening_6_gate.yml` 的相关文件名单。

**理由**：改名单会改变**哪些 PR 要付出完整 acceptance 成本**，是行为面改动，
需要独立论证（触发频率、成本、是否引入新的阻塞面），超出「修复既有假绿」的范围
（`CLAUDE.md` §3：每一行改动都要能追溯到用户请求）。
**记为残留风险 R2。**

### D5　验证的诚实边界

见 §5.3。本次修复**在 CI 上的最终确认点是 PR #179 的重跑**，不是本 PR 自己。

---

## 5. 验证方案

### 5.1 本地：CI 等价依赖环境

已建一次性 venv（不污染系统 Python，路径在 scratchpad）：
`pglast 7.13` / `PyYAML 6.0.3` / `openapi-spec-validator 0.7.2` / `pytest 8.4.2` / `httpx 0.28.1`
（= `requirements-dev.txt` + `backend/requirements-dev.txt`，与 `hardening_6_gate.yml` 安装的一致）。

**该环境已被证明具有判别力**：它抓出了纯本地跑**看不见**的 `plan_1b` 失败（F14 vs F15）。
纯本地缺包时，Plan 1b 因 `ModuleNotFoundError: No module named 'yaml'` 提前失败，
**掩盖了真正的 `11 passed` 断言失败** —— 两个缺陷互相掩盖，与
`feedback_mutation_false_negatives_two_shapes` 记录的形态同型。

**判据**：改动后在该环境下跑 `plan_1f_m0_1_schema_versioning.sh`，
必须输出 `PLAN 1f PASS` 且退出码 0。

### 5.2 负向对照（必做，防「改完才发现断言本来就绿」）

改动**之前**必须先在同一环境跑一次并记录失败面（预期 5 项，见 F14）。
若某项在改动前就是 PASS，说明该项与本次修复无关，不得计入收益。

### 5.3 无法在本 PR 内实证的部分（明确声明）

| 命题 | 状态 |
|---|---|
| 改动后 `plan_1f` 在**本地 CI 等价环境**通过 | 可实证（§5.1） |
| 改动后 `plan_1f` 在**真实 CI（Linux）**通过 | ⚠️ **本 PR 无法自证** —— `plan_1f` / `plan_1b` 不在闸门相关文件名单里（F16），故只改它们的 PR 会**短路放行**，CI 不会真跑 |

**CI 级确认点**：本 PR 合并后，**PR #179 重跑**时会真跑 `plan_1f`
（#179 触碰了 `.github/workflows/hardening_6_gate.yml`，在名单内），届时才是 CI 级证据。

**纪律**：spec、计划、提交信息、PR 正文中，对「CI 上通过」一律表述为
「**本地 CI 等价环境已验证 · 真实 CI 待 #179 重跑确认**」，**不得写成已在 CI 验证**
（`feedback_codex_convergence_honest_reporting` / `superpowers:verification-before-completion`）。

**残留声明**：本地为 macOS、CI 为 Linux。本次两条断言分别是
**纯文本比对**（矩阵行）与**纯计数比对**（pytest 数量），均平台无关；
但该推理不构成 CI 级证据，故仍按上表如实标注。

---

## 6. 残留风险台账

| # | 风险 | 定性 | 处置 |
|---|---|---|---|
| **R1** | 删除 6 条矩阵断言后，**PostgreSQL migration id / 训练组 SQLite user_version / P2 journal states** 三行无任何自动守卫 | 删除前它们的守卫**也是零信号**（触发时机错误 + 4/6 已烂），故**不是净损失**；但确实是覆盖缺口 | **接受**，D3 记为独立 backlog：需一个 **backend 侧**触发的守卫 |
| **R2** | 闸门相关文件名单不含嵌套脚本 ⇒ 修改这些脚本的 PR 不会验证自己 | 既有设计，非本次引入；已在 §5.3 如实声明并给出 CI 级确认点 | **接受**，D4 记为独立 backlog |
| **R3** | 闸门本身仍会对绝大多数 PR 短路放行 ⇒ 剩余断言仍是低频执行、仍可能腐烂 | 短路机制本身是**正确的**（它防的是另一种死锁，见 #179 的 spec）；本次只拆除已腐烂且零信号的部分，未也无法改变执行频率 | **接受**，超出本次范围 |
| **R4** | D2 的下限 `11` 本身仍是硬编码数字 | 但语义已从「必须正好 N」变为「不得少于 N」：**新增测试不再使其失效**，只有删测试才触发 —— 腐烂路径被切断 | **接受**，这是有意的设计 |

---

## 7. 本 spec 明确不做

- 不修改 `docs/governance/m01-schema-versioning-contract.md`（文档是**对的**，烂的是断言）；
- 不修改 `M01MatrixSyncGuardTests.swift`（它当前为绿且维护良好）；
- 不给 Swift 守卫增加 PostgreSQL / 训练组 SQLite / P2 journal 行（D3）；
- 不修改 `hardening_6_gate.yml` 的相关文件名单（D4）；
- 不修改 `hardening_6_framework.sh`（顶层脚本没问题）；
- 不修改其余 17 个 acceptance 脚本（F7 / F8 已确认它们无同类字面量）；
- 不修改 `backend/tests/test_openapi.py`（19 个测试全部通过，**它们没问题**）；
- 不触碰 PR #179 的分支或其任何文件。

---

## 8. 考虑过并否决的替代方案

| 方案 | 内容 | 否决理由 |
|---|---|---|
| **A** | 把 `plan_1f` 的 4 个版本号改成当前值（`"1.13"` / `0004_...` / `0010_...` / `1.4`） | 不触碰根因（F4：脚本从不运行）。改完会以同样方式、同样无人察觉地**再次腐烂**，只是推迟下一次事故。且与 F10–F13 的既有 Swift 守卫构成重复维护面 |
| **B** | 把 `plan_1b` 的 `11` 改成 `19` | 同上：下次正常新增 OpenAPI 不变量测试后立刻再次失效。且它把「新增测试」错误地当作缺陷信号 |
| **C** | 让 `plan_1f` 的 shell 断言从**代码**（而非文档）推导期望值 | 这正是 `M01MatrixSyncGuardTests` 已经在做的事（F10–F13），且它的触发时机更正确。重复造一份是 DRY 反面 |
| **D** | 把 `plan_1f` / `plan_1b` 加进闸门相关文件名单，让修复自证 | 改变「哪些 PR 付出完整 acceptance 成本」，是行为面改动，需独立论证（D4）。且**不解决**字面量腐烂本身 |
| **E** | 直接删除整个 `plan_1f` 脚本 | 过度 —— 该脚本共 31 项断言，其中 26 项（含 H2 结构完整性、Bump 策略、Migration Rollback、应用范围、交叉引用、AppError 结构不变量）**当前全部通过且有价值**。只该切除腐烂的那 6 条 |

---

## 9. 回滚方案

两处改动均为**删除 / 收窄断言**，无数据、无状态、无迁移。

本次实施产生**两个提交**（D1 一个、D2 一个），故：

- **已合并进 `main` 后回滚**：本仓近期 PR 多为 squash 合并（单提交、标题带 `(#NNN)`），
  `git revert --no-edit <squash 提交 sha>`；若为 merge commit 则 `git revert --no-edit -m 1 <sha>`。
- **尚未合并、在分支上回滚**：必须**逆序 revert 两个提交**（先 D2 再 D1）。
  ⛔ `git revert` **没有 `-q` 选项**，误写会只打印 usage 而**什么都不做**。

**回滚后核实**（不能只看 revert 命令是否成功）：

```bash
grep -c 'matrix row:' scripts/acceptance/plan_1f_m0_1_schema_versioning.sh
grep -c "'^11 passed'" scripts/acceptance/plan_1b_m0_2_rest_api.sh
```

期望依次为 **6** 与 **1**（= 回到基线）。

---

## 10. 交付与流程

1. 本 spec 提交；
2. `codex:adversarial-review` 对 spec 评审
   —— `.claude/scripts/codex-attest.sh --scope branch-diff --head fix/acceptance-stale-literals --base main`
   ⛔ 不传任何其它参数（脚本的参数解析末尾是 `*) FOCUS="$FOCUS $1"`，未知参数会被吞成 focus 目标 → 假 approve + 写脏账本）；
   收口只认 **Read 账本文件**核实 `head_sha` == HEAD、`kind` == `branch`、无 focus 字段；
3. 收敛后 → `superpowers:writing-plans`；
4. 实施 → PR → 合并；
5. **合并后**：PR #179 重跑，届时取得 CI 级证据（§5.3）。

**push 与开 PR 由用户在自己的终端执行**（Claude 的 Bash 被守卫拦截）。
