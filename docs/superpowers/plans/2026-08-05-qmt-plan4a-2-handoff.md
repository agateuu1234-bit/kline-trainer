# QMT Plan 4a-2 交接单（给 user 在真终端执行）

**worktree** `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2`
本文件是**操作说明**，不是设计文档。设计权威仍是
`docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md` §4。

---

## 〇、当前状态（**先读这一节**，下面 §一–§七 是 2026-08-09 那次交付时的原文）

`feat/qmt-plan4a-2b-destructive`（PR **#161**）**没有整条合并**。它被按
`docs/superpowers/plans/2026-08-10-qmt-plan4a-2b-repackaging.md` 重新切成三片：

| 片 | 内容 | 状态 |
|---|---|---|
| **S1** | 共用护栏 + 只读档位（**零生产代码改动**） | ✅ MERGED **#162**（main `567987b`） |
| **S2a** | 判定 helper（零对象例外 + 闸 0−/0/0b + 绑定标量）+ 32 档只到判定为止的真 PG | **本 PR** |
| **S2b′** | `reset_pilot_database` 单函数（封锁临界区 + DROP + 清凭据）+ 9 档破坏性真 PG + concurrency 3 档 | 未开始 |
| **S3** | `--init-cluster-marker` + 孤儿清理（含 R9-F1 / R14-F1） | 未开始 |

> ⛔⛔ **本文件 §一–§七（含那张验收清单）是 2026-08-09 的原文，对 S2a 已经不适用。**
> 2026-08-12 的**塌缩重构**删掉了整套「可传递的授权凭据」，
> `authorize_reset` / `ResetAuthorization` / `_mint_authorization` / `ResetGateOutcome`
> 这些名字在代码里**已经不存在**；`reset_pilot_database` / `_drop_pilot_database`
> 则要到 S2b′ 才有。原文里凡是提到这些名字、以及「39 档 / 10 档」的行，
> 照着做一定对不上。
> · 塌缩的由来与设计：`2026-08-12-qmt-4a2b-reset-api-collapse.md`
> · **S2a 该跑的验收清单**：`2026-08-12-qmt-4a2b-s2a-acceptance.md`（用那一份，别用下面那份）

⛔ **PR #161 在三片全部合并之前不要关闭** —— 它是唯一完整记录 R1–R15 账本与
三个生产缺陷的地方。三片合完再关，并在关闭评论里指向那份重打包计划。

### ⚠️⚠️ L2 三个脚本的**调用方式在 S1 之后变了**（照旧命令跑必然失败）

| 变化 | 内容 |
|---|---|
| **必须带** `QMT_VERIFY_ALLOW_DESTRUCTIVE=1` | **每一次运行都要**（codex 4a-2b/S1 R7-F1）。「在本地」不等于「这个集群可弃」，这个变量是操作者对「整台集群可以被毁掉」的明示。不带就 `EXIT=3`，一档都不跑。 |
| 非本地集群**再加** `QMT_VERIFY_ALLOW_REMOTE=1` | DSN 指向非 `localhost`/`127.0.0.1` 时另需这一个。 |
| **新增退出码 8** | `8 = 同集群上已有另一个同前缀的验收在跑`（运行锁没取到）。原来的 0–7 语义不变。 |
| `verify_pilot_db_lifecycle.py` **不再要 `DSN2`** | 它一个跨集群档都没有（codex S1 R1-F2：此前读了 DSN2、过了闸、却一处都没用过）。跨集群那条在 `verify_pilot_concurrency.py` 的 Ⓐb。**`verify_pilot_concurrency.py` 仍然必须给 DSN2。** |

### 档数（S2 交付态，**取代下面 §三 那张表里的 39/10/77**）

| 脚本 | S1 之后 | **S2 之后** | 最终（S3 之后） |
|---|---|---|---|
| `verify_pilot_two_phase_create.py` | 28 | 28 | 28 |
| `verify_pilot_db_lifecycle.py` | 19 | **38** | 43（预估） |
| `verify_pilot_concurrency.py` | 7 | **10** | 10 |
| 合计 | 54 | **76** | 81（预估） |

⚠️ **档号在重打包中动过**：S1 实施时新造了三档并占用了 ㉕㉖㉗，与 #161 分支上
同号的三档语义完全不同。S2 把搬进来的那三档改成 ㉝ / ㉞ / ㉞b，映射表写在
`verify_pilot_db_lifecycle.py` 的 `_EXPECTED_SCENARIOS` 上方。**读 #161 或旧计划时按那张表对。**

---

## 一、两条分支（4a-2b 基于 4a-2a）

| 分支 | 状态 | 内容 |
|---|---|---|
| ~~`feat/qmt-plan4a-2a-read-gates`~~ | ✅ **MERGED #158**（main squash `bd2c154`，2026-08-08）| 库级**只读**闸：0− / 0 / 0r / 0b / state / 1 / 2 |
| `fix/qmt-gate2-name-text-cast` | **待 push / 开 PR**；codex **一轮 approve**，账本已核 | 修 2a 带进 main 的死闸（`name[] = text[]`），+80 / −1 |
| `feat/qmt-plan4a-2b-destructive` | **待 push / 开 PR**（十余个提交，约 +5900 / −84；**准确数字用命令现查，别信写死的**）| 零对象例外 + `authorize_reset` + **`reset_pilot_database`**（授权+销毁一体）+ `--init-cluster-marker` + **共用 harness + 两个新 L2 真 PG 脚本** |

> ⚠️ **`fix/qmt-gate2-name-text-cast` 优先。** 它修的是**此刻就躺在 `main` 上**的缺陷：
> 闸 2 的业务表结构查询在真 PostgreSQL 上恒抛，**五组判据从未成功执行过一次**。
> 它与 2b 完全解耦，且已拿到 approve —— 先推它。
> ⚠️ 那条分支**不要 rebase**：attest 账本绑死在 `363fda9`，rebase 会让 `head_sha` 对不上、门变红。

> ⚠️ 破坏性入口**只有 `reset_pilot_database` 一个**：`_drop_pilot_database` 是私有的，
> 且 `ResetAuthorization` 需要一个**只有 `authorize_reset` 拿得到的模块私有哨兵**才能铸造，
> 使用点还用 `type(x) is` 复核（R4-F2 → R6-F1 → R7-F1 三轮才收口）。
> 把 DROP 单独暴露出去，一次接线失误就能现造凭据、把集群闸/归属闸/绑定闸/`--reset-foreign` 全绕过去。

**4a-2a 零 DDL、零破坏性能力**；所有会 DROP / 建表 / 删行的动作都集中在 4a-2b，
让评审把注意力压在危险的那一半上。

⚠️ **4a-2b 必须等 4a-2a 合并之后再开 PR**，否则 GitHub 会把 4a-2a 的内容算进 4a-2b 的 diff。

---

## 二、推分支与开 PR（2026-08-09 更新：2a 已合并，现在是**两条**待推）

> 踩过的坑：`git add x && git commit  # 说明` 里的 `#` 会被当**路径**传给 `git add` →
> add 失败 → `&&` 短路 → **commit 根本没发生**，而随后的推送照样成功，
> 推上去的是一个与 main 相同的空分支。命令看着全绿，结果是空的。
> **所以：一行一条，别用 `&&` 串，行尾别加 `#` 注释。**

### ① 先做 `fix/qmt-gate2-name-text-cast`（优先，codex 一轮 approve）

它修的是**此刻就躺在 `main` 上**的缺陷，与 2b 完全解耦。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-gate2-textcast"
git status --porcelain
git rev-parse --abbrev-ref HEAD
git rev-parse --short HEAD
```

期望：**没有输出** / `fix/qmt-gate2-name-text-cast` / `363fda9`。对不上先停下。

然后推送，并用**远端**判据核实（`0` 就是没推上去，别看推送自己的输出）：

```
git rev-list --count origin/main..origin/fix/qmt-gate2-name-text-cast
```

期望：**1**。之后开 PR，正文用 `--body-file` 指向：

```
/Users/maziming/Coding/Prj_Kline trainer/.dev/pr-bodies/pr_body_textcast.md
```

⚠️ **这条分支不要 rebase** —— attest 账本绑死在 `363fda9`，rebase 会让 `head_sha`
对不上、把门弄红。真要 rebase 就得重跑一轮评审。

### ② 再做 `feat/qmt-plan4a-2b-destructive`

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2"
git status --porcelain
git rev-parse --abbrev-ref HEAD
git rev-parse --short HEAD
git fetch origin
git rev-list --count HEAD..origin/main
```

期望：**没有输出**（工作区干净）/ `feat/qmt-plan4a-2b-destructive` / 最后一条是 **`0`**
（已与 main 齐平，**不需要 rebase**）。

⚠️ **本地提交数先记下来**（写死在文档里必然被后续提交打过期）：

```
git rev-list --count origin/main..HEAD
```

推送之后同样用远端判据核实：

```
git rev-list --count origin/main..origin/feat/qmt-plan4a-2b-destructive
```

期望：**与上一步记下的本地提交数完全相等**（不等就是没推全）。之后开 PR，
正文用 `--body-file` 指向：

```
/Users/maziming/Coding/Prj_Kline trainer/.dev/pr-bodies/pr_body_4a2b.md
```

> 两份 PR 描述都放在 `.dev/pr-bodies/`（**gitignored**，不进仓库、但不随会话消失）。

⚠️ 每次推送之后**去看 CI 是不是真绿** —— 推送成功不代表闸门过了。
⚠️ `codex-review-verify` 在 main 上长期红（至少自 2026-07-24 起），不是本轮引入、也不在必需集。
⛔ **4a-2b 不建议在评审看过之前合并** —— 理由见 §四。

---

## 三、验证证据（全部为宣称前新鲜跑出）

| 项 | 命令 | 结果 |
|---|---|---|
| host 全量（4a-2a） | `cd backend && ../.venv/bin/python -m pytest tests/ -q -p no:randomly` | **660 passed**（合并前 563） |
| host 全量（4a-2b，交付态） | 同上 | **795 passed** |
| 本文件单跑 | `pytest tests/test_qmt_pilot_db.py -q` | 4a-2a **330** / 4a-2b **465**（合并前 233） |
| spec 一致性 | `python3 tools/check_spec_consistency.py` | **全过**；`--self-test` 的 11 项各自被反例触发 |
| mutation | 控制者亲验，逐条中和判据看具名测试变红后复原 | 4a-2a **93 条**、4a-2b **107 条**，**全部 RED** |
| 工作区 | `git status --porcelain` | 0 个变更 |
| **L2 真 PG ①**（4a-1）| `DSN=… DSN2=… .venv/bin/python backend/scripts/verify_pilot_two_phase_create.py` | **28 档全绿** |
| **L2 真 PG ②**（本轮新增）| `DSN=… DSN2=… .venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py` | **39 档全绿**（连跑三轮稳定）|
| **L2 真 PG ③**（本轮新增）| `DSN=… DSN2=… .venv/bin/python backend/scripts/verify_pilot_concurrency.py` | **10 档全绿** |
| L2 档位的 mutation | 控制者亲验，逐条中和生产守卫看**该档**的 FAIL 行出现后复原 | 24 条：**22 条 RED**，2 条如实登记为「被遮蔽 / 纯纵深」 |
| R9–R13 修复的 mutation | 同上（host 具名测试 / 真 PG 该档） | **21 条全 RED** |

真 PG 档位合计 **77**（28 + 39 + 10）。

### ⚠️⚠️ L2 脚本挖出**三个生产缺陷**（假件层结构性测不到，795 条 host 测试 + codex 前八轮全漏）

| # | 缺陷 | 影响 | 修法 |
|---|---|---|---|
| 1 | `_BUSINESS_STRUCTURE_SQL` 里 `array_agg(a.attname …) = ARRAY[…]` 是 `name[] = text[]`，**PostgreSQL 无此操作符** | 该查询在**任何**库上都抛 → 闸 2 的业务表五组判据**从未成功执行过一次**，全兜成 `target_db_unreadable`。fail-closed 不放行危险东西，但**整条复用路径 100% 不可用**，且错误码把运维指向权限/连通性而不是「schema 漂移 → 用 --reset 重建」 | `array_agg(a.attname::text ORDER BY a.attname::text)` |
| 2 | DROP 预检数了 `pg_stat_activity` 的**全部**行，把 `autovacuum worker` 当成占用者（PostgreSQL 自己的 `DROP DATABASE` 不算它 —— 真 PG 实测坐实）| `--reset`（陈旧 schema 库的**唯一**出路）**间歇性**假拒，还给运维一条执行不了的动作（「请让它们自行退出后重试」，而占用者是后台进程）。CI 里是 flake，现场是「重试几次又好了」的玄学 | 预检拆出 `_TARGET_CLIENT_SESSIONS_SQL`（`backend_type = 'client backend'`）；诊断仍看全部后端 |
| 3 | 验空与 `DROP DATABASE` 之间有 **0.7–2.2 ms** 的 TOCTOU 窗口（codex R10，critical）| 真 PG 上**已复现数据丢失**：普通角色在窗口里连进去建了表**再断开**，PostgreSQL 没有活会话可挡，库照样被删 —— 而这条来路**绕过** `pilot_meta` 归属与 `--reset-foreign` 令牌 | 三轮迭代（R10 → R11 → R12）收口成「**全程持住一条目标库连接**」：连上 + adopt → 读原 connlimit → 封锁 → 占用者复查（排除自己 pid）→ 在这条会话上验空 → 关闭 → DROP |

**为什么 host 层结构性抓不到**：假件 `_FakeConn` 按 SQL 子串派发预置字典，
**SQL 文本一次都没送进 PostgreSQL**。这正是 L2 脚本存在的全部理由。

**为什么本脚本原有档位也没抓到第 1 个**：它们**全部**断言「拒了」——
一条**恒抛**的闸在每一档看起来都在正常工作。故新增 ⑰b「健康库复用**必须被放行**」，
它是本脚本唯一断言「放行」的复用档。

**mutation 抓出来的、光读代码发现不了的测试自身缺陷（如实记，共 8 处）**：
1. 守卫被**自己的 docstring** 满足而恒真（把常量换成内联 SQL 仍绿）→ 改走 AST Name 节点
2. 禁用词判据误伤 4a-1 SQL 注释里的合法提及（`ENABLE/FORCE ROW LEVEL SECURITY`）→ 收窄到「DROP DATABASE 这条语句里出现 FORCE」
3. `_READ_INTENT_SQL` 的时钟来源在假件层**零覆盖**（换成常量所有 TTL 用例照样绿）→ 补 SQL 文本守卫
4. `uq_stock_start` 的**列**比对同样零覆盖 → 补 SQL 文本守卫
5. 零对象例外的**两处**释放校验因「让两次 close 都失败」而互相遮蔽，删掉任一处另一处仍拦得住
   （两条变异双双跑绿）→ 改成按「第几次 close 失败」参数化，每处各自可分辨
6. `_drop_pilot_database` **自己那次探测**的释放校验完全没有用例（变异跑出 16 passed）→ 补
7. 假件的 `_deletes` 判别式 `startswith("DELETE")` 对新的三引号 SQL 失配 →「不许删」那两条断言
   **当场变成恒真**（变异抓出）→ 改为先 `.strip()`
8. 两个假件的**子串分发**被自己的判据劫走（闸 (iii) 的豁免 CTE 里也含 `pilot_create_intent`
   这个表名字符串）→ 判别式收紧到 `FROM public.pilot_create_intent i`

---

## 四、codex 对抗性评审（4a-2a：R1–R6；4a-2b：R1–R13）

### ⛔ 交付时的口径（2026-08-09 更新）

**4a-2b 一共跑了 13 轮，从未 approve。**R9–R13 又挖出 **7 条 finding，全部为真、
全部已修、全部做过变异验证**（明细见下表）。

**最后一轮（R13）的修复本身零评审** —— 它改的是 DROP 授权路径上的调用方标量校验。
**故：不建议在评审看过之前合并 4a-2b。**
2a 当初能 override 的三条理由（零 DDL / 零破坏性 / 下游零调用点）在 2b **一条都不成立**。

| 轮 | 严重度 | finding | 修法 |
|---|---|---|---|
| R9 | medium | 混合态（一表在场但不耐久 + 另一表缺席）下 init **先落 DDL 再拒** | 耐久性判据拆成每表一条 |
| R10 | **critical** | 零对象例外 DROP 的 TOCTOU **数据丢失**窗口（真 PG 复现） | DROP 前 `CONNECTION LIMIT 0` |
| R11 | high | 清理只认被销毁的 oid → `db_oid=NULL` 陈旧行留存 → **reset 后重建不了** | 谓词补「指不到活实例」，锁内当下求值 |
| R11 | high | 恢复写死 −1（抹掉原策略）+ 非超级用户**自锁** | 读回原值再恢复 |
| R12 | high | 「非超级用户就跳过封锁」= 窗口原样留着 | **架构改动**：全程持住一条目标库连接 |
| R12 | medium | 两条 `ALTER DATABASE` 按名字发，可能落到同名替身 | 同上（持有期间名字↔实例稳定） |
| R13 | high | 复用/销毁两条路**不验**调用方绑定标量 | 抽 `assert_binding_scalars`，四入口各自强制 |

**为什么停在 R13**：严重度五轮是 medium → critical → 2×high → high+medium → high，
**不是递减**；且每轮修复都在长新的评审面。同时本 PR 严重超出「≤3 子项 ≤500 行」
（十余个提交 / 约 +5900 −84）——**不收敛有一部分是打包问题**，仓库记忆里明写过
「大 PR codex 不收敛 → 切超小片」。就地重切要重写整条分支的历史，
成本与风险更高，故选择**把评审挪到 PR 上继续**（与 2a 在 R6 的处置一致）。

---

### 历史（截至 2026-08-08 的 R1–R8）

**十四轮全是 `needs-attention`，从未 approve。**二十七条 finding。
⚠️ 其中**两族反复未闭合**：「破坏性入口可被伪造凭据驱动」提了 3 次、
「init 的副作用排在证明之前」提了 4 次（R5-F1 → R6-F2 → R7-F2 → R8-F1）—— 见下
全部为真、全部已修 + 变异验证。

> ⚠️ **本轮不是「收敛到 approve」**。截至交付时 codex 每一轮**仍在挖出新的**真缺陷，
> 只是 finding 越来越集中在**上一轮修复新增的表面**上。user 2026-08-08 拍板：
> **把评审挪到 PR 上继续**，先让不依赖 codex 的那几道 CI 闸跑出真结果。
> **合并前提：PR 上的 codex 必需门真绿，或由 user 显式 override —— 二者必居其一。**
> 最后一轮修复（2b R4 的 `reset_pilot_database` 一体化入口）**本身尚未被任何评审看过**。
>
> ⭐ **4a-2a 已由 user 显式 override 合并**（2026-08-08 拍板）——**不等 PR 上的 codex 门转绿**。
> 判断依据：**4a-2a 零 DDL、零破坏性能力**，`Sources/` 零调用点（4c 才接线），
> 最坏情况只是某道闸判得不够严，而下游还没有任何东西在调它。
> 2a 上唯一没被评审看过的是 **R6 的修复**（两个 public 入口各自强制集群闸；
> 3 条变异全红、逻辑直白）。codex 反复提的「reset 走不到空残骸逃生口」是**切分产物**
> （逃生口在 4a-2b），非 2a 缺陷。
>
> ⛔ **这条 override 不适用于 4a-2b。** 2b 是**会 `DROP DATABASE`** 的那一半，
> 且最后一轮修复本身零评审，还欠两个 L2 真 PG 脚本（2b 有四处判据的真语义只有真 PG 能坐实）。
> **2b 合并前必须：rebase 到含 2a 的 main → 重跑 codex → 最好先有 L2。**

4a-2a 的十一条见下表；4a-2b 的九条见该分支 commit message，其中最值得记的三条：
① **标记已存在时短路了「每次现查」**——直接违反 spec §4 R17-F1 逐字写着的
「标记证明的是**有人曾声明过**，只有现查才证明**现在仍然成立**」；
② **孤儿删除按快照决定**——取锁与判定之间，同 seed 的运行可以刷新自己的凭据，
本循环却按陈旧快照把那条**新鲜的恢复凭据**删掉；
③ **DROP 成功却不清凭据**——那一行仍新鲜且已确认、只是指向已消失的 oid，
而重建用新 run_id → `intent_row_conflict`：`--reset` 把库删了却重建不了（**自锁**）。

| 轮 | 严重度 | finding | 处置 |
|---|---|---|---|
| R1 | high | 闸 2 太窄：看不见 ready 之后新装的触发器/RLS、默认值/序列改动、pilot 表多出的索引；业务表清单手写三张漏了 `stocks`；`uq_stock_start` 只比名字不比列 | **已修**：把建库时那三条活体判据提成共用 helper，建库与复用调**同一组**；表清单改从 `REQUIRED_BUSINESS_TABLES` 派生；列比对补上 |
| R2 | high | 关不掉自己的探测会话仍发 DROP 授权 → 随后的 DROP 被自己顶住，而诊断说「有别人连着」 | **已修**：改成「闸过 → 关连接 → 证明真关掉 → 才交出 oid」，且 close 失败不得顶掉闸结论 |
| R2 | medium | 三条活体判据的读失败裸逃 → 被 4c 兜成 `FAIL_INFRASTRUCTURE` | **已修**：归一成 `target_db_unreadable` |
| R3 | high | 确认令牌被写进异常 message（**计划片段里也是这么写的**）→ 任何把 `str(exc)` 写进报告的调用方都会漏，wrapper 可读报告取令牌再重跑 | **已修**：只走 `confirm_token` 专用通道，加防泄漏钉 |
| R3 | high | 目标库归属只信库内自证（同侪库早就要求「自证 + 维护库登记绑 oid」两个独立事实） | **升级给 user 裁决**（spec §4 闸表没有 registry 闸；给 reset 加会复活 R55-F1 锁死）→ user 拍板 **只加在复用路径**，已落地为闸 0r + 钉住不对称 |
| R4 | high | 发放 DROP 授权前没验按 seed 的锁（建库/DROP/零对象例外三处都验了，唯独它没） | **已修**：补上，且排在开探测连接之前；复用路径**刻意不要求**（只读，有钉子） |
| R4 | high | 「空残骸没有 `pilot_meta` 时走不到零对象例外」 | **本 PR 切分的产物**：那条逃生口在 4a-2b。已在 4a-2b 用 `authorize_reset` 把 spec §4 的次序**焊进模块**而不是留给调用方纪律，并留 AST 守卫钉住先后 |
| R5 | high | R4 加的验锁**排在任何 `search_path` 钉桩之前** —— `_SEED_LOCK_HELD_SQL` 用不限定的 `pg_locks`/`pg_backend_pid()`/`hashtext()`，敌意 search_path 能让**锁的证明返回 true 而锁并不存在** | **已修**：钉桩提到函数最前（两个 public 入口各一处）|
| R5 | medium | NULL 的 `pilot_meta` 值让 `_bound_identity` 在 `None[:12]` 上抛**裸 TypeError** | **已修**：闸 0− 拒非字符串值；`attnotnull` 补进 `_PILOT_META_SHAPE_SQL` |
| R6 | high | 两个 public 入口（复用 / reset）**自己不跑集群闸** —— 一次接线失误就能在**生产集群**上批准复用/销毁再灌几百只股（spec §1 风险 ①）| **已修**：两个入口各自机器强制，且排在**碰目标库之前** |
| R6 | high | 「reset 走不到空残骸的逃生口」——**与 R4 那条同一条**，切分产物的再提 | **非缺陷**：逃生口在 4a-2b。本轮把 `assert_db_allowed_for_reset` 的 docstring 写死「这不是 `--reset` 的入口」。codex 单看 2a 的 diff 看不到 2b，故会反复提 |

> ⚠️ **R4/R5 的三条是我自己在上一轮修复时引入的** ——「修 symptom 会挪动失败面」的实证，
> 如实登记，不粉饰成「逐轮收敛」。
>
> ⚠️ **「破坏性入口可被伪造凭据驱动」这一个洞被提了三次**，前两次我的修法都不够 ——
> 这条**单独记下来**，因为它是本轮最值得学的一处：
> | 轮 | 我的修法 | 为什么不够 |
> |---|---|---|
> | R4-F2 | `drop_pilot_database` → `_drop_pilot_database`（改私有）| 下划线只是**约定**，不是机制 |
> | R6-F1 | 凭据构造要模块私有哨兵 `_RESET_CAPABILITY` | **使用点从不检查对象类型** |
> | R7-F1 | 使用点查 `type(...) is` + 只在 `__init__` 里设的 `_minted` 标记 | Python 注解不强制：`SimpleNamespace(db_oid=…, via_empty_remnant=…)` 鸭子类型直接就过；`object.__new__` 还能绕过 `__init__` |
>
> 教训：**「把纪律写成机制」要写到使用点，不是写到构造点。**
>
> ⚠️ **第二族：「init 的副作用排在证明之前」被提了四次**，每次我都只堵了当时被点名的那条路：
> | 轮 | 我的修法 | 漏了什么 |
> |---|---|---|
> | R5-F1 | 加「零副作用预检」（哈希/标记/维护库空）| 预检**分不开**「表缺席」与「表在场但坏」 |
> | R6-F2 | 加 presence 查询，按表分别判 | **同侪库**的证明仍排在 DDL 之后 |
> | R7-F2 | 同侪库证明挪进预检 | 挂在 `if not rows` 上，漏了**混合态**（标记在、表缺）|
> | R8-F1 | 判据改挂「**这次会不会真的动 DDL**」+ 健康集群零 DDL | —— |
>
> 教训：**「副作用先于证明」这类问题要按「哪些路径会产生副作用」穷尽，
> 不能按「评审点到的那条路径」逐条堵。**

**如实说明**：这不是「收敛到 approve」，而是「每一轮的 finding 都被证实、修掉并钉住」。
是否以 override 方式收口由 user 决定 —— reviewer 的 verdict 替代不了这个授权。

---

## 五、与实施计划的偏离（计划的代码片段写于 4a-1 经 32 轮评审长到 1815 行之前）

计划 Task 3/4 的代码块**不能逐字转写**，实测对不上的地方：

| 计划里写的 | 实际 |
|---|---|
| `_DELETE_INTENT_SQL(dbname)` 清孤儿行 | 实际签名 `(dbname, run_id)` 且带 `AND NOT create_confirmed` —— 孤儿恰恰是已确认的行，用它删**永远匹配 0 行**（命令发了、一行没删的静默失败）→ 另立 `_DELETE_ORPHAN_INTENT_SQL` |
| `MAINTENANCE_EXEMPT_QUERY` | 常量不存在，现在是 `_user_objects(conn, exempt_maintenance=True)` |
| `holds_seed_lock: bool` 参数 | 正是 4a-1 已删掉的可伪造断言 → 改为在活连接上查 `pg_locks` |
| `now_epoch` 参数 | 新鲜度不能由调用方给时钟 → 年龄由库自己的 `now() - inserted_at` 算出来 |
| 测试里新定义 `_meta_rows` / `_FakeConn(empty_counts=…)` | 两者都已存在且形状不同 |
| `--reset` 绑定不符报 `binding_mismatch` | spec §5 明写 `reset_foreign_token_required`（填错才是 `..._invalid`）；4c 消费者按它分诊 |
| 闸 2 整条推给 L2 脚本 | spec §4 闸分工表写明「复用时必过」；只放验收脚本里的话生产路径上根本没有闸 2 |
| 没有任何 DROP 函数 | spec §4 规定 1/2/3（连接数为 0 / 禁强制模式 / `target_db_in_use`）在 4a 没有落点 → 新增 `drop_pilot_database` |

**新错误码**（已按 spec 收尾规则补进 4c 的 `db_boundary_error` 枚举，C12 本轮真的抓到过）：
`registry_proof_missing`（4a-2a）、`target_db_replaced`（4a-2b）。

---

## 六、非 coder 验收清单

> ⛔ **下面这张表是 2026-08-09 为整条 #161 写的，档数已过期**（第 11/12 条写的 39 档
> 是 #161 的数字；S2 交付态是 **38** 档，见 §〇）。**S2 这一片的验收清单在 §六b**，
> 请用那一张。这一张保留是为了记录当初宣称过什么。



| # | 动作 | 期望 | P/F |
|---|---|---|---|
| 1 | 在 worktree 根跑 `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_pilot_db.py -q` | 末行显示 `passed`，无 `failed`/`error` | |
| 2 | 跑 `cd backend && ../.venv/bin/python -m pytest tests/ -q; echo "EXIT=$?"` | `EXIT=0`，且数量比合并前（759）只增不减（交付态实测 **795 passed**） | |
| 3 | 在 `backend/qmt_pilot_db.py` 里搜 `assert ` （带空格） | **一处都搜不到**（守卫一律 if/raise） | |
| 4 | 在 `backend/qmt_pilot_db.py` 里搜 `pg_terminate_backend` | 只出现在**说明文字**里，不出现在任何被执行的语句/字符串里（有机械测试钉住） | |
| 5 | 在 `backend/qmt_pilot_db.py` 里搜 `information_schema.tables` | **搜不到**（【绝对空】必须白名单式） | |
| 6 | 跑 `python3 tools/check_spec_consistency.py` | 末行 `✅ 一致性检查全过` | |
| 7 | 跑 `python3 tools/check_spec_consistency.py --self-test` | 末行 `✅ mutation 自测通过（11 项检查各自被反例触发）` | |
| 8 | 打开 4a-2a 的 diff，找 `assert_db_allowed_for_reset` | 里面**没有**指纹比对、没有 `state` 判断、没有闸 2、没有九键检查（reset 是陈旧库唯一的出路） | |
| 9 | 打开 4a-2b 的 diff，找 `_drop_pilot_database` | 恰好一条 `DROP DATABASE`，**不带**任何强制选项，失败后**没有**重试 | |
| 10 | 在 `backend/qmt_pilot_db.py` 里搜 `def drop_pilot_database`（不带下划线）| **搜不到** —— 破坏性入口只有 `reset_pilot_database` 一个，授权与销毁一体 | |
| 11 | 两个测试库容器起着（`docker ps` 能看到 `qmt-pg-r8` 和 `qmt-pg-r8b`）时，按下面「L2 三连跑」那段命令逐行跑三个脚本 | 三行末尾分别是 `✅ 28 档`、`✅ 39 档`、`✅ 10 档`，**都带「断言全部成立（真 PostgreSQL）」**；任何一行出现 `FAIL` 或 `❌` 即判 F | |
| 12 | 把 `verify_pilot_db_lifecycle.py` **连跑三遍**，比较三次的末行 | 三次**完全一样**（都是 `✅ 39 档`）—— 这一条专门查「间歇性假拒」那类 flake，跑一遍绿不算数 | |

| 13 | 把 `authorize_reset` 里那行 `assert_binding_scalars(export_log_sha256, output_dir)` 手工删掉，重跑第 1 条 | 必须出现 `FAILED …binding_scalar…`；**看完把改动还原** | |

> ⚠️ 判绿一律**读输出内容**，不要看管道后的 exit code（`cmd | tail` 之后 `$?` 是 tail 的）。
> ⚠️ 第 13 条是本轮的要害之一：它证明 R13 新加的守卫**真的拦得住**，不是恒真断言。
> ⚠️ 第 11/12 条尤其：**读末尾那行 `✅ N 档…`**，别读中间某段 PASS —— 中间全是 PASS 而
> 末行是 `❌` 的情况本轮真实发生过（我自己就因为只看了过滤片段而漏判了一次）。

### L2 三连跑（第 11/12 条用；一行一条，别用 `&&` 串）

> ⛔ **下面这段是 2026-08-09 的旧命令，S1 之后已经跑不通**（缺
> `QMT_VERIFY_ALLOW_DESTRUCTIVE=1` 会直接 `EXIT=3`，一档都不跑）。
> **以 §〇「L2 三个脚本的调用方式在 S1 之后变了」那一节为准**，现行命令见其下方。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2"
export DSN="postgresql://postgres:$(docker inspect qmt-pg-r8 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55444/postgres"
export DSN2="postgresql://postgres:$(docker inspect qmt-pg-r8b --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55445/postgres"
.venv/bin/python backend/scripts/verify_pilot_two_phase_create.py
.venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py
.venv/bin/python backend/scripts/verify_pilot_concurrency.py
```

### L2 三连跑（**现行**，S2 交付态；一行一条，别用 `&&` 串，行尾别加 `#` 注释）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s2"
export DSN="postgresql://postgres:$(docker inspect qmt-pg-r8 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55444/postgres"
export DSN2="postgresql://postgres:$(docker inspect qmt-pg-r8b --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55445/postgres"
export QMT_VERIFY_ALLOW_DESTRUCTIVE=1
../../.venv/bin/python backend/scripts/verify_pilot_two_phase_create.py
../../.venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py
../../.venv/bin/python backend/scripts/verify_pilot_concurrency.py
```

期望末行分别是 `✅ 28 档` / `✅ 38 档` / `✅ 10 档`，都带「断言全部成立（真 PostgreSQL）」。
⚠️ 容器没起时先 `docker start qmt-pg-r8 qmt-pg-r8b`。
⚠️ 出现 `EXIT=8` = 同集群上已有另一个同前缀的验收在跑，等它跑完再来（不是缺陷）。

---

## 六b、非 coder 验收清单（**S2 这一片，用这张**）

> 判绿一律**读输出内容**（末尾那行结论），不要看管道后的 exit code
> （`cmd | tail` 之后 `$?` 是 tail 的）。一行一条命令，别用 `&&` 串。
> 先 `cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s2"`。

| # | 动作 | 期望 | P/F |
|---|---|---|---|
| 1 | 跑 `cd backend` 然后 `../../.venv/bin/python -m pytest tests/ -q -p no:randomly` | 末行是 `767 passed`，无 `failed` / `error`（合并前 672） | |
| 2 | 跑 `cd backend` 然后 `../../.venv/bin/python -m pytest tests/test_qmt_pilot_db.py -q` | 末行显示 `passed`，无 `failed` / `error` | |
| 3 | 起容器：`docker start qmt-pg-r8 qmt-pg-r8b`，再按 §「L2 三连跑（**现行**）」逐行跑三个脚本 | 三行末尾分别是 `✅ 28 档`、`✅ 38 档`、`✅ 10 档`，都带「断言全部成立（真 PostgreSQL）」。任何一行出现 `FAIL` 或 `❌` 即判 F | |
| 4 | 把 `verify_pilot_db_lifecycle.py` **连跑三遍**，比较三次末行 | 三次**完全一样**（都是 `✅ 38 档`）—— 这条专查「间歇性假拒」那类 flake，跑一遍绿不算数 | |
| 5 | 故意**不带** `QMT_VERIFY_ALLOW_DESTRUCTIVE=1` 跑一次 lifecycle（`unset QMT_VERIFY_ALLOW_DESTRUCTIVE` 之后跑），再 `echo "EXIT=$?"` | `EXIT=3`，且**一档都没跑**（看不到任何 `PASS` 行）—— 证明破坏性闸不是摆设 | |
| 6 | 在 `backend/qmt_pilot_db.py` 里搜 `def drop_pilot_database`（**不带**下划线） | **搜不到** —— 破坏性入口只有 `reset_pilot_database` 一个，授权与销毁一体 | |
| 7 | 在 `backend/qmt_pilot_db.py` 里搜 `pg_terminate_backend` | 只出现在**说明文字**里，不出现在任何被执行的语句/字符串里（有机械测试钉住） | |
| 8 | 在 `backend/qmt_pilot_db.py` 里搜 `assert `（带空格） | **一处都搜不到**（守卫一律 if/raise） | |
| 9 | 打开本 PR 的 diff，找 `_drop_pilot_database` | 恰好一条 `DROP DATABASE`，**不带**任何强制选项，失败后**没有**重试 | |
| 10 | 打开本 PR 的 diff，在 `_drop_pilot_database` 里找 `if _auth_via_remnant:` | 它在**封锁块的里面**（`ALTER DATABASE … CONNECTION LIMIT 0` 之后），而不是把整个封锁块包起来 —— 这就是 R15-F1 要的「两条路统一」 | |
| 11 | 跑 `../../.venv/bin/python tools/check_spec_consistency.py` | 末行 `✅ 一致性检查全过` | |
| 12 | 跑 `../../.venv/bin/python tools/check_spec_consistency.py --self-test` | 末行 `✅ mutation 自测通过（11 项检查各自被反例触发）` | |
| 13 | 把 `_drop_pilot_database` 里那句 `meta_now = await read_pilot_meta(target_conn)` 到 `_assert_reset_foreign_token(meta_now, _auth_token)` 整段（正常路的复验）手工删掉，重跑第 1 条 | 必须出现 `FAILED …normal_reset_revalidates…`；**看完把改动还原**（用编辑器撤销，**别用 `git checkout`**） | |
| 14 | 同上还原后，把 `backend/qmt_pilot_db.py` 里 `_TARGET_CLIENT_SESSIONS_SQL` 的 `'client backend'` 改成 `'autovacuum worker'`，重跑 lifecycle | 必须出现 `FAIL  ㉜b …`；**看完把改动还原** | |
| 15 | 在 `backend/qmt_pilot_db.py` 里搜 `init_cluster_marker` | **搜不到** —— 那一块属于 S3，本片刻意不含（本片的评审面只有破坏性核心） | |

> ⚠️ 第 3/4 条尤其：**读末尾那行 `✅ N 档…`**，别读中间某段 PASS —— 中间全是 PASS
> 而末行是 `❌` 的情况在本 plan 里真实发生过。
> ⚠️ 第 13/14 条是本片的要害：它们证明新加的守卫**真的拦得住**，不是恒真断言。

---

## 七、下一步（**不在本两个 PR 内**）

- ~~**PR-2 = 两个 L2 真 PG 脚本**~~ → **已完成并并入本 PR**，见计划
  `docs/superpowers/plans/2026-08-09-qmt-plan4a-2-l2-scripts.md`：
  `verify_pilot_db_lifecycle.py`（**39 档**）+ `verify_pilot_concurrency.py`（**10 档**），
  外加把 4a-1 那个脚本的安全护栏抽进共用的 `_pilot_verify_harness.py`。
  它们是「假件不得替代真 PG」这条纪律的唯一落地处 —— 而它们**立刻兑现了**：
  挖出上面 §三 记的**三个生产缺陷**，都是 795 条 host 测试与 codex 前八轮
  结构性抓不到的（假件按子串派发预置字典，SQL 文本不进 PG）。

### 已知残留（交付时如实登记，**不含糊**）

1. **R13 的修复零评审** —— 它改的是 DROP 授权路径上的调用方标量校验。
   这是「不建议在评审看过之前合并 4a-2b」的首要理由。
2. **超级用户维护角色是硬前提。**【绝对空】判据要遍历所有带 oid 列的 `pg_catalog` 表，
   其中 `pg_user_mapping` 非超级用户读不了。该前提此前是**偶然**成立的（没写下来也没验过），
   现由档 Ⓔ 钉成可验证事实，并证明它 **fail-closed**（库没被删、连接限制也没留在半封锁状态）。
   ⛔ **不要**「顺手让 `_user_objects` 跳过读不了的目录」—— 那是 fail-open，
   模块明写「查不出目录清单就抛，绝不返回『空』」。
3. **DROP 与最后一次重核之间仍有毫秒级窗口**：对**非超级用户**已由 `CONNECTION LIMIT 0`
   封死；对**另一个超级用户**保留 —— 但超级用户本来就能直接 DROP 任何库。
4. **档 ㉜ 的判别力被前面的档遮蔽**（不编场景，如实登记）：让集群闸持住连接的强变异
   确实制造出滞留会话，但它在档 ④ 的清场就把脚本打死了，按构造 ㉜ 不可能是第一个观测点。
5. **本 PR 严重超出「≤3 子项 ≤500 行」**（十余个提交 / 约 +5900 −84）。
   **不收敛有一部分是打包问题** —— 仓库记忆里明写过「大 PR codex 不收敛 → 切超小片」。
   就地重切要重写整条分支的历史，成本与风险更高，故选择把评审挪到 PR 上继续。

### 再往后

- 4b（SMB 真拉取）→ 4c（100 股出货）。**都在 4a-2b 落地之后。**

**交付口径（禁述清单）**：本轮的正确表述是
「**4a 的库级护栏建好，并在真 PostgreSQL 上验过 77 档**」。
**禁述**「pilot 已完成」「100 股已出货」「真实数据接入完成」——
**真 QMT 数据一个字节都还没流过。**
