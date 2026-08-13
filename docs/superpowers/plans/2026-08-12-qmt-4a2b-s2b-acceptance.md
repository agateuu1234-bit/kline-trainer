# QMT 4a-2b 切片 S2b′ 验收清单（给 user 在真终端逐条执行）

**worktree** `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s2b`
**分支** `feat/qmt-4a2b-s2b-drop`（在 S2a 之上）

> ⚠️ 本文件只覆盖 **S2b′**（破坏性执行面）。S2a 那一片的清单是
> `2026-08-12-qmt-4a2b-s2a-acceptance.md`；两片都要跑。
> ⚠️ 旧的 `2026-08-05-qmt-plan4a-2-handoff.md` §一–§七 是 2026-08-09 原文，**别用**。

## 〇、这一片交付了什么（一句话）

`reset_pilot_database` —— **判定与销毁一体的唯一破坏性入口**，一个函数体里走完
「名字护栏 → 集群闸 → seed 锁 → 零对象例外 / 否则闸 0−/0/0b → 占用者预检 →
实例复核 → 持连接封锁 → 紧贴复验 → DROP → 清凭据」。

⭐ 它**偿还了 S2a 明写接受的那条残留**：spec §4 的有向序列现在焊在这个函数体里，
由一颗 AST 钉子（`test_reset_welds_the_spec_order_into_one_function_body`）守着。

⛔ **这一片真的会删库**。跑它的每一条命令都必须带 `QMT_VERIFY_ALLOW_DESTRUCTIVE=1`，
指向的集群必须是可以整台毁掉的测试集群。

## 一、准备（一行一条命令，**别用 `&&` 串**）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s2b"
```
```
git rev-parse --abbrev-ref HEAD
```
```
git rev-parse HEAD
```
```
docker start qmt-pg-r8 qmt-pg-r8b
```
```
export DSN="postgresql://postgres:$(docker inspect qmt-pg-r8 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55444/postgres"
```
```
export DSN2="postgresql://postgres:$(docker inspect qmt-pg-r8b --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_PASSWORD=' | cut -d= -f2)@localhost:55445/postgres"
```
```
export QMT_VERIFY_ALLOW_DESTRUCTIVE=1
```

> ⚠️ DSN 指向的**不是**本机时**另外**还要 `export QMT_VERIFY_ALLOW_REMOTE=1`。
> ⚠️ 退出码 **8** = 同一台集群上已经有另一个同前缀的验收在跑 —— 等它跑完再来。
> ⚠️ 退出码 **9**（并发脚本）= 它要用的固定名角色（`zzqmtverify_plain` / `zzqmtverify_owner`）
>    在运行之前就已存在 —— 那说明不是本次造的，脚本**拒绝碰它**。按 stderr 的提示手工清掉再跑。
> ⚠️ **判绿一律读输出内容**（末尾那行 `✅ N 档…`），**不要看管道后的退出码**。

## 二、验收表（动作 / 期望 / 通过-不通过）

| # | 动作 | 期望看到 | 通过? |
|---|---|---|---|
| 1 | `.venv/bin/python -m pytest backend/tests -q` | 末行 `770 passed`，**0 failed / 0 error / 0 skipped** | |
| 2 | `.venv/bin/python backend/scripts/verify_pilot_db_lifecycle.py` | 末尾 `✅ 41 档断言全部成立（真 PostgreSQL）`；整篇**没有** `FAIL` 也没有 `❌` | |
| 3 | 把第 2 条**再跑两遍**，比较三次的末行 | 三次**完全一样**（都是 `✅ 41 档`）—— 专查「间歇性假拒」那类 flake | |
| 4 | `.venv/bin/python backend/scripts/verify_pilot_concurrency.py` | 末行 `✅ 11 档断言全部成立（真 PostgreSQL）` | |
| 5 | `.venv/bin/python backend/scripts/verify_pilot_two_phase_create.py` | 末行 `✅ 28 档断言全部成立（真 PostgreSQL）` | |
| 6 | 整行贴进终端：<br>`grep -rn "def authorize_reset\|class ResetAuthorization\|_mint_authorization\|_MINTED_AUTHORIZATIONS\|_RESET_CAPABILITY\|class ResetGateOutcome" backend/ --include='*.py' \| grep -v "^backend/tests/"` | **一行输出都没有** —— 塌缩买到的东西在本片仍然成立：判定与销毁之间没有可传递的凭据 | |
| 7 | `grep -rn "DROP DATABASE" backend/qmt_pilot_db.py \| grep -v "^.*:[0-9]*: *#"` | 只有**一行**长成真的在发 SQL 的样子（`f"DROP DATABASE {quote_ident(db_name)}"`），其余全是说明文字或报错串 | |
| 8 | `.venv/bin/python tools/check_spec_consistency.py` | 末行 `✅ 一致性检查全过` | |
| 9 | `.venv/bin/python tools/check_spec_consistency.py --self-test` | 末行 `✅ mutation 自测通过（11 项检查各自被反例触发）` | |
| 10 | 看第 2 条输出的**最后几行** | 必须能看到「仍**没有**覆盖的」那一段（`--init-cluster-marker` 随 S3；autovacuum worker 那一向没有常驻档）。**看不到就判不通过** —— 一份不肯说自己没验什么的报告，比没有报告更危险 | |

### 五条「守卫真的拦得住吗」的手工反证（做完**务必还原**）

| # | 动作 | 期望看到 | 通过? |
|---|---|---|---|
| 11 | 打开 `backend/qmt_pilot_db.py`，在 `reset_pilot_database` 里找到封锁临界区那句 `await maint_conn.execute(_SEAL_CONNECTIONS_SQL(db_name))`，把它连同上一行 `_sealed = True` 一起改成 `_sealed = False`，存盘，跑第 4 条 | 必须出现 `FAIL  Ⓓ 窗口里普通角色**连不进**目标库` 且写着「竟然连进去并建了表」。**看完改回去**，重跑第 4 条确认回到 `✅ 11 档` | |
| 12 | 打开 `backend/qmt_pilot_db.py`，把封锁临界区里 `else:` 分支那句 `await _assert_reset_gates_on(target_conn, …)` 换成两行：`_meta_now = await read_pilot_meta(target_conn)` 和 `await _assert_ownership(_meta_now, seed=seed)`，存盘，跑第 2 条 | 必须**只有 ㉟b 变红**（`竟然删掉了`），而 ㉟ 仍然 PASS —— 这证明 ㉟b 不是 ㉟ 的重复，它单独钉着「绑定/令牌那半也要在封锁下重跑」。**看完改回去**，重跑第 2 条确认回到 `✅ 41 档` | |
| 13 | 打开 `backend/qmt_pilot_db.py`，把最后那句 `await maint_conn.execute(_CLEAR_DROPPED_INTENT_SQL, db_name, seed, db_oid)` 改成 `pass`，存盘，跑第 2 条 | ㉞ 与 ㉞b 各出**两条** FAIL（凭据没清掉 + 重建被卡成 intent 冲突）。**看完改回去**，重跑第 2 条确认回到 `✅ 41 档` | |
| 14 | 打开 `backend/qmt_pilot_db.py`，把 `reset_pilot_database` 里那句 `db_oid = await try_empty_remnant_exception(…)` 整段（含随后的 `if not via_empty_remnant:`）注释掉、改成直接走 `assert_db_allowed_for_reset`，存盘，跑第 1 条 | 必须出现 `FAILED …test_reset_welds_the_spec_order_into_one_function_body`，另外 ⑨ 那一族也会红。**看完改回去**，重跑第 1 条确认回到 `770 passed` | |
| 15 | 用任意 PG 客户端（psql / DBeaver 皆可）连上 DSN 那台集群，执行 `CREATE ROLE zzqmtverify_plain LOGIN PASSWORD 'x'`，然后跑第 4 条，再 `echo "EXIT=$?"` | 必须 **`EXIT=9`**、stderr 打出「这些角色在本次运行之前就已经存在」；**并且回客户端确认那个角色仍然在**（`SELECT rolname FROM pg_roles WHERE rolname='zzqmtverify_plain'` 有一行）—— 守卫护住了它、没删。看完手工 `DROP ROLE zzqmtverify_plain`，重跑第 4 条确认回到 `✅ 11 档` | |

> ⚠️ 第 11–15 条是本片的要害。前四条是**改一行/一段、看指定的档变红、改回去**；
> 第 15 条不改代码，它证明「验收脚本不会误删别人的角色」。
> 改回去之后一定要重跑一次确认真的还原了。

## 二之二、⭐ codex 对抗性评审的结论（PR 评审者请先读这一段）

**本片（连同 S2a）跑了 3 轮**合并视角的 codex（`--base 567987b --head feat/qmt-4a2b-s2b-drop`），
**从未 approve**。挖出的临界区缺陷全部修完并各自变异验证：
封锁挡不住超级用户 / 恢复会改到替身的配置 / 恢复抛异常时跳过关自己的会话
（**最后那条是实施者自己上一轮引入的回归**，如实登记）。
逐轮账本见 `2026-08-12-qmt-4a2b-reset-api-collapse.md` §五之四。

⚠️ 唯一未修的一条（R3-F1，high）：`--reset` 只靠目标库自证的 `pilot_meta`、
**刻意不要**维护库的 registry 凭据。这条不对称是 **user 2026-08-05 拍板**的
（否则维护库一重初始化，非空 pilot 库就再也清不掉 = R55-F1 锁死）。
codex 给的中间路线「缺凭据时要人工确认令牌」已由 **user 2026-08-13 拍板放进 4c**
（见 4c spec §10a），不在本片实施。

**收口方式 = user override（2026-08-13）**，边界写在计划 §五之四。

## 三、已知的、**本片明写接受**的残留

1. **「不数 autovacuum worker」那一向没有常驻档**：逼出一个 autovacuum worker 要改集群的
   `autovacuum_naptime`（`ALTER SYSTEM`，持久且全局），对验收脚本太侵入。
   该向由一次性真 PG 实验坐实并记进计划。
2. **封锁下的复验与 `DROP` 之间仍有一个窗口**（不可消除）。把窗口从「整条判定链」
   收窄到「一次读之后」是这里能做到的全部 —— 模块 docstring 里逐字登记了这一条。
3. **`--init-cluster-marker` 的幂等语义与孤儿 intent 清理**随 **S3** 补回；
   因此 lifecycle 脚本此刻**仍不是** spec §6.2 生命周期那一组的完整 ship gate。
4. **`created_at` 单独被改不再拒**（塌缩带来的**有意**语义变化）：本次放行的理由是
   「绑定与调用方的两个标量相符」，而 `created_at` 不参与这个理由。
   走令牌那条路不受影响（令牌由三元组派生，改了就对不上）。
   由 `test_normal_reset_still_proceeds_when_only_created_at_changes_under_the_seal` 钉住。

## 四、判 F 之后怎么办

任何一行判「不通过」，**先把那一行的完整输出贴回来**（不要只贴一句「失败了」）。
尤其第 2/4/5 条：中间全是 PASS 而末行是 `❌` 的情况真实发生过 —— **读末行**。
