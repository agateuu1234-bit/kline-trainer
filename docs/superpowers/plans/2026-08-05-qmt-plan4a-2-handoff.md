# QMT Plan 4a-2 交接单（给 user 在真终端执行）

**worktree** `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2`
本文件是**操作说明**，不是设计文档。设计权威仍是
`docs/superpowers/specs/2026-07-27-qmt-plan4a-db-guardrails-design.md` §4。

---

## 一、两条分支（4a-2b 基于 4a-2a）

| 分支 | HEAD | 内容 | 生产代码 | 子项 |
|---|---|---|---|---|
| `feat/qmt-plan4a-2a-read-gates` | `75e9efc` | 库级**只读**闸：0− / 0 / 0r / 0b / state / 1 / 2 | +549 / −45 | 3 |
| `feat/qmt-plan4a-2b-destructive` | 见 `git log -1`（自引用，写死会随 amend 过期）| 零对象例外 + `authorize_reset` + **`reset_pilot_database`**（授权+销毁一体）+ `--init-cluster-marker` | +450 | 3 |

> ⚠️ 破坏性入口**只有 `reset_pilot_database` 一个**：`_drop_pilot_database` 是私有的。
> `ResetAuthorization` 只是个公开 NamedTuple，把 DROP 单独暴露出去，一次接线失误就能
> 用当前 oid 现造一个凭据、把集群闸/归属闸/绑定闸/`--reset-foreign` 全绕过去（codex 4a-2b R4-F2）。

**4a-2a 零 DDL、零破坏性能力**；所有会 DROP / 建表 / 删行的动作都集中在 4a-2b，
让评审把注意力压在危险的那一半上。

⚠️ **4a-2b 必须等 4a-2a 合并之后再开 PR**，否则 GitHub 会把 4a-2a 的内容算进 4a-2b 的 diff。

---

## 二、推分支（一行一条，别用 `&&` 串，行尾别加 `#` 注释）

> 踩过的坑：`git add x && git commit  # 说明` 里的 `#` 会被当**路径**传给 `git add` →
> add 失败 → `&&` 短路 → **commit 根本没发生**，而随后的推送照样成功，
> 推上去的是一个与 main 相同的空分支。命令看着全绿，结果是空的。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2"
git branch --show-current
git rev-parse --short HEAD
git checkout feat/qmt-plan4a-2a-read-gates
git push -u origin feat/qmt-plan4a-2a-read-gates
```

**验收判据用远端，不看本地**（0 就是没推上去）：

```
git fetch origin
git rev-list --count origin/main..origin/feat/qmt-plan4a-2a-read-gates
```

期望：**1**。

开 PR（标题/正文中文，正文直接引本文件）：

```
gh pr create --base main --head feat/qmt-plan4a-2a-read-gates --title "QMT 4a-2a：pilot 库级只读闸（闸 0− / 0 / 0r / 0b / state / 1 / 2）" --body "见 docs/superpowers/plans/2026-08-05-qmt-plan4a-2-handoff.md"
```

**等 4a-2a 合并之后**再做 4a-2b：

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4a-2"
git fetch origin
git checkout feat/qmt-plan4a-2b-destructive
git rebase origin/main
git push -u origin feat/qmt-plan4a-2b-destructive
gh pr create --base main --head feat/qmt-plan4a-2b-destructive --title "QMT 4a-2b：零对象例外 + reset 单一入口 + drop_pilot_database + --init-cluster-marker" --body "见 docs/superpowers/plans/2026-08-05-qmt-plan4a-2-handoff.md"
```

⚠️ 每次推送之后**去看 CI 是不是真绿** —— 推送成功不代表闸门过了。
⚠️ `codex-review-verify` 在 main 上长期红（至少自 2026-07-24 起），不是本轮引入、也不在必需集。

---

## 三、验证证据（全部为宣称前新鲜跑出）

| 项 | 命令 | 结果 |
|---|---|---|
| host 全量（4a-2a） | `cd backend && ../.venv/bin/python -m pytest tests/ -q -p no:randomly` | **660 passed**（合并前 563） |
| host 全量（4a-2b） | 同上 | **759 passed** |
| 本文件单跑 | `pytest tests/test_qmt_pilot_db.py -q` | 4a-2a **330** / 4a-2b **429**（合并前 233） |
| spec 一致性 | `python3 tools/check_spec_consistency.py` | **全过**；`--self-test` 的 11 项各自被反例触发 |
| mutation | 控制者亲验，逐条中和判据看具名测试变红后复原 | 4a-2a **93 条**、4a-2b **107 条**，**全部 RED** |
| 工作区 | `git status --porcelain` | 0 个变更 |

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

## 四、codex 对抗性评审（4a-2a 跑了 R1–R6，4a-2b 跑了 R1–R8）

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

| # | 动作 | 期望 | P/F |
|---|---|---|---|
| 1 | 在 worktree 根跑 `cd backend && ../.venv/bin/python -m pytest tests/test_qmt_pilot_db.py -q` | 末行显示 `passed`，无 `failed`/`error` | |
| 2 | 跑 `cd backend && ../.venv/bin/python -m pytest tests/ -q; echo "EXIT=$?"` | `EXIT=0`，且数量比合并前（563）只增不减 | |
| 3 | 在 `backend/qmt_pilot_db.py` 里搜 `assert ` （带空格） | **一处都搜不到**（守卫一律 if/raise） | |
| 4 | 在 `backend/qmt_pilot_db.py` 里搜 `pg_terminate_backend` | 只出现在**说明文字**里，不出现在任何被执行的语句/字符串里（有机械测试钉住） | |
| 5 | 在 `backend/qmt_pilot_db.py` 里搜 `information_schema.tables` | **搜不到**（【绝对空】必须白名单式） | |
| 6 | 跑 `python3 tools/check_spec_consistency.py` | 末行 `✅ 一致性检查全过` | |
| 7 | 跑 `python3 tools/check_spec_consistency.py --self-test` | 末行 `✅ mutation 自测通过（11 项检查各自被反例触发）` | |
| 8 | 打开 4a-2a 的 diff，找 `assert_db_allowed_for_reset` | 里面**没有**指纹比对、没有 `state` 判断、没有闸 2、没有九键检查（reset 是陈旧库唯一的出路） | |
| 9 | 打开 4a-2b 的 diff，找 `_drop_pilot_database` | 恰好一条 `DROP DATABASE`，**不带**任何强制选项，失败后**没有**重试 | |
| 10 | 在 `backend/qmt_pilot_db.py` 里搜 `def drop_pilot_database`（不带下划线）| **搜不到** —— 破坏性入口只有 `reset_pilot_database` 一个，授权与销毁一体 | |

> ⚠️ 判绿一律**读输出内容**，不要看管道后的 exit code（`cmd | tail` 之后 `$?` 是 tail 的）。

---

## 七、下一步（**不在本两个 PR 内**）

- **PR-2 = 两个 L2 真 PG 脚本**：`verify_pilot_db_lifecycle.py`（13 档）+
  `verify_pilot_concurrency.py`。它们是「假件不得替代真 PG」这条纪律的唯一落地处 ——
  假件对「同一 session 第二次取锁」和「第一次取锁」反应完全一样，也建模不出
  `relkind` 覆盖面与 DROP 是否真被顶住。本轮已有**四处**判据被记为「host 层零覆盖、
  只靠 SQL 文本守卫」，它们的语义正是要靠 L2 坐实。
- 之后才是 4b（SMB 真拉取）与 4c（100 股出货）。

**交付口径（禁述清单）**：本轮的正确表述是「**4a 的库级护栏建好、用假件验过**」。
**禁述**「pilot 已完成」「100 股已出货」「真实数据接入完成」——
**真 QMT 数据一个字节都还没流过。**
