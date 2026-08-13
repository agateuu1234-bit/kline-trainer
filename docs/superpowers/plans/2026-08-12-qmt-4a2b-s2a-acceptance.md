# QMT 4a-2b 切片 S2a 验收清单（给 user 在真终端逐条执行）

**worktree** `/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s2a`
**分支** `feat/qmt-4a2b-s2a-authorization`

> ⚠️ 本文件**只覆盖 S2a**。旧的那份（`2026-08-05-qmt-plan4a-2-handoff.md` §一–§七）
> 是 2026-08-09 原文，里面的 `authorize_reset` / `reset_pilot_database` / 「39 档 / 10 档」
> 对本片都对不上 —— 别用那份。

## 〇、这一片到底交付了什么（一句话）

**把「授权」与「销毁」之间那道缝删掉了**：整套可传递的授权凭据（凭据类、能力哨兵、
授权登记表、铸造函数、单一入口、身份快照）全部移除，本片只剩**判定** helper。
判定 helper 回答「这个库能不能碰」，**不发放任何东西**，因此本片**零破坏性能力**
是结构上的 —— 不再是「有凭据但暂时没人消费」这种偶然。

⛔ **本片不能做什么，先说清楚**：它**不会删任何库**。`--reset` 真正执行 DROP 的那一半
在 S2b′。凡是本片跑绿的档，证明的都只是「闸/例外判得对不对」。

---

## 一、准备（一行一条命令，**别用 `&&` 串**）

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4a2b-s2a"
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
```
export PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
```

> ⚠️ **venv 在主仓，worktree 里没有** —— 在 worktree 里敲 `.venv/bin/python` 会得到
> `zsh: no such file or directory`。故本清单一律用上面这个 `$PY`，
> 且**必须带引号**（路径里有空格）。先 `"$PY" -V` 确认打印 `Python 3.11.15`。

> ⚠️ `QMT_VERIFY_ALLOW_DESTRUCTIVE=1` **每次运行都要**。它是操作者对「这台集群整个可以被
> 毁掉」的明示；不带就直接退出码 3、一档都不跑。DSN 指向的**不是**本机时**另外**还要
> `export QMT_VERIFY_ALLOW_REMOTE=1`。
> ⚠️ 退出码 **8** = 同一台集群上已经有另一个同前缀的验收在跑 —— 等它跑完再来。
> ⚠️ **判绿一律读输出内容**（末尾那行 `✅ N 档…`），**不要看管道后的退出码**
> （`cmd | tail` 之后的 `$?` 是 tail 的，不是脚本的）。

---

## 二、验收表（动作 / 期望 / 通过-不通过）

| # | 动作 | 期望看到 | 通过? |
|---|---|---|---|
| 1 | `"$PY" -m pytest backend/tests -q`（在 worktree 根目录跑）| 末行 `727 passed`，**0 failed / 0 error / 0 skipped** | |
| 2 | 整行贴进终端：<br>`grep -rn "def authorize_reset\|class ResetAuthorization\|_mint_authorization\|_MINTED_AUTHORIZATIONS\|_RESET_CAPABILITY\|class ResetGateOutcome" backend/ --include='*.py' \| grep -v "^backend/tests/"` | **一行输出都没有**（测试文件里那些是守卫的名单与历史注释，已被后半段过滤掉）| |
| 3 | `grep -n "DROP DATABASE" backend/qmt_pilot_db.py` | 会打印十几行。逐行看：**每一行要么以 `#` 开头、要么在三引号说明文字里、要么在 `f"…"` 报错串里**；**没有一行长成 `await …execute("DROP DATABASE …")` 这种真的在发 SQL 的样子** —— 本片零破坏性能力 | |
| 4 | `"$PY" backend/scripts/verify_pilot_db_lifecycle.py` | 末尾 `✅ 34 档断言全部成立（真 PostgreSQL）`；整篇**没有** `FAIL` 也没有 `❌` | |
| 5 | 把第 4 条**再跑两遍**，比较三次的末行 | 三次**完全一样**（都是 `✅ 34 档`）。这一条专查「间歇性假拒」那类 flake，跑一遍绿不算数 | |
| 6 | `"$PY" backend/scripts/verify_pilot_two_phase_create.py` | 末行 `✅ 28 档断言全部成立（真 PostgreSQL）` | |
| 7 | `"$PY" backend/scripts/verify_pilot_concurrency.py` | 末行 `✅ 7 档断言全部成立（真 PostgreSQL）` | |
| 8 | 看第 4 条输出的**最后十几行** | 必须能看到三段⚠️：①本片只验到「闸/例外判得对不对」，**不验 DROP 真的执行得下去**；②spec §4 那条有向序列本片**没有任何东西机器强制**；③`--init-cluster-marker` 随 S3 补回。**看不到这三段就判不通过** —— 一份不肯说自己没验什么的报告，比没有报告更危险 | |
| 9 | `unset QMT_VERIFY_ALLOW_DESTRUCTIVE`，再跑一次第 4 条，然后 `echo "EXIT=$?"` | `EXIT=3`，且**一个 PASS 行都看不到**（证明破坏性闸不是摆设）。看完记得把它重新 `export` 回来 | |

### 三条「守卫真的拦得住吗」的手工反证（做完**务必还原**）

| # | 动作 | 期望看到 | 通过? |
|---|---|---|---|
| 10 | 打开 `backend/qmt_pilot_db.py`，在文件**最末尾**加一行 `class ResetAuthorization: pass`，存盘，重跑第 1 条 | 必须出现**两条** FAILED，名字里分别带 `machinery_is_gone_from_the_module` 和 `no_production_file_reintroduces`。**看完把那一行删掉**，重跑第 1 条确认回到 `727 passed` | |
| 11 | 打开 `backend/qmt_pilot_db.py`，找到 `try_empty_remnant_exception` 里那行 `await assert_cluster_allowed(maint_conn, connect=connect, target_db=db_name)`，把它删掉，存盘，重跑第 1 条 | 必须出现**两条** FAILED，名字里都带 `remnant_exception` 和 `cluster_gate`。**看完把那行加回去**，重跑第 1 条确认回到 `727 passed` | |
| 12 | 打开 `backend/qmt_pilot_db.py`，找到 `assert_db_allowed_for_reset` **最后**那行 `return oid`，改成 `return "0"`，存盘，先跑第 1 条、再跑第 4 条 | 第 1 条出现**三条** FAILED（都带 `oid`）；第 4 条出现**四条** FAIL（⑬ ⑰ ㉒ ㉓），每条都打印「实得 '0'，该库当前 oid=…」。**看完改回 `return oid`**，重跑第 1 条与第 4 条确认全绿 | |

> ⚠️ 第 10–12 条是本片的要害：它们证明新加的守卫**真的拦得住**，不是恒真断言。
> 三条都是**改一行、看红、改回去**；改回去之后一定要重跑一次确认真的还原了。

---

## 二之二、⭐ codex 对抗性评审的结论（PR 评审者请先读这一段）

**本片跑了 5 轮 codex（`--scope branch-diff --base 567987b`），从未 approve。**
挖出的**代码类** finding 全部修完并各自做过变异验证（读失败裸逃 + TTL 的三种绕过：
时钟回拨 / 亚秒取整 / 长事务）。逐轮账本见
`2026-08-12-qmt-4a2b-reset-api-collapse.md` §五之二 / §五之四。

⚠️ **剩下唯一没修的那条，请不要原样重提**：R2/R4/R5 连提三次
「S2a 没有一个原子的 `reset_pilot_database` 入口」。它**是切片边界造成的**，不是缺陷 ——
证据：把 S2a + S2b′ 当**一次完整改动**送审（`--head feat/qmt-4a2b-s2b-drop`）时，
这条**一条都没再出现**，换成了两条针对真实临界区的 finding（已修）。
下一片 S2b′ 就是那个入口，并由 `test_reset_welds_the_spec_order_into_one_function_body` 钉着。

**收口方式 = user override（2026-08-13）**，边界写在计划 §五之四：
覆盖上述结构性异议与一条设计分歧（已转 4c backlog），
**不覆盖**任何新的授权正确性 / 数据丢失窗口类 finding。

## 三、已知的、**本片明写接受**的残留（不是遗漏，是代价）

1. **spec §4 的有向序列（集群闸 → 零对象例外 → 否则闸 0−/0/0b）本片没有任何东西机器强制。**
   它随 S2b′ 的 `reset_pilot_database` 函数体落地。本片能证明的只是这两步在同一份
   fixture 上给出**相反**的判定（host 一档 + lifecycle ⑨ 一档）。
2. **「集群闸下沉进零对象例外」这一条只有 host 层证据，真 PG 上零覆盖** ——
   lifecycle 每个 remnant 档的维护库都写了合法 marker，没有「标记缺失 + 走例外」这种档。
3. **DROP 执行、DROP 前的紧贴复查、连接封锁与占用者检查、DROP 后的凭据清理** ——
   本片**一档都没跑**，坏掉也不会让任何脚本变红。它们随 S2b′ 补回。

## 四、判 F 之后怎么办

任何一行判「不通过」，**先把那一行的完整输出贴回来**（不要只贴一句「失败了」）。
尤其第 4/6/7 条：中间全是 PASS 而末行是 `❌` 的情况真实发生过 —— **读末行**。
