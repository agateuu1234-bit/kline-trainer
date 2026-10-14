# Migration 0005 · `training_sets.schema_version` 去掉 `DEFAULT 1`

一项变更，同一次 `CONTRACT_VERSION` bump（1.14 → 1.15）覆盖。
（0004 是三项合一，本次只有这一项。）

## 变更内容

| # | 对象 | 从 | 到 |
|---|---|---|---|
| 1 | `training_sets.schema_version` | `INTEGER NOT NULL DEFAULT 1` | `INTEGER NOT NULL`（无默认值） |

附带：给该列加一条说明注释，写明「刻意不设默认值」。
⚠️ 该注释文字与 `backend/sql/schema.sql` 里那条**逐字一致**，由
`test_migration_0005_comment_text_is_byte_identical_to_schema_sql` 钉住。

## 为什么要改

有 `DEFAULT 1` 时，漏填该列的 `INSERT` 会被 PostgreSQL **静默补成 1** ——
第 2 代产物被标成第 1 代，写入方毫无察觉，错误一路流到 App 读取端才显形
（而那时已经无从分辨「这是真的第 1 代」还是「漏填被补的」）。

去掉默认值、**保留** `NOT NULL` ⇒ 漏填当场报
`null value in column "schema_version" ... violates not-null constraint`。

⚠️ 本次**不校验值对不对**：写 `schema_version = 99` 仍会被接受。钉死取值范围需要
`CHECK` 约束，且要先处理存量 1 / 2 两代共存，属另一条判据（见 spec §7）。

## Rollback 风险评估

**本次 rollback 无数据风险。** 理由：

- `DROP DEFAULT` / `SET DEFAULT` 只改列的**元数据**，PostgreSQL 不重写任何已有行；
- 回滚不删表、不改列类型、不收窄长度 ⇒ 没有既有数据会被截断或删除。

⛔ **「声称无风险」比「声称有风险」更需要证明。** 所以这条断言由同目录
`rehearse.sh` 的 **Part 3** 在真 PostgreSQL 上实地跑出来 —— 不是写在这里就算。

因此 `rollback.sql` **刻意不设**破坏性确认守卫（0004 的那一份有
`kline.rollback_confirm = 'I_HAVE_A_BACKUP'` 一道）。那道守卫的存在理由是
「真有东西会丢」；为一个不存在的风险加确认步骤，只会让下一个读者以为这里有风险。

⚠️ 回滚**之后**的副作用（不是数据损失，但要知道）：默认值装回去之后，漏填
`schema_version` 的写入会重新被静默补成 1。回滚只应在「本片引入的 fail-closed
行为本身导致停机」时执行。

## 怎么跑

```bash
# 演练（需要本机 Docker）
./rehearse.sh

# 应用到真库
psql -d <db> -v ON_ERROR_STOP=1 -f forward.sql

# 回滚
psql -d <db> -v ON_ERROR_STOP=1 -f rollback.sql
```

## 怎么在 NAS 上应用（⛔ 整套在这里，不要去部署手册找）

> ⛔⛔ **部署手册（`docs/runbooks/2026-08-24-qmt-nas-deployment.md`）里没有这一步。**
> 它的 P6 第一步看到数据卷已存在时，**唯一的出口是 P6-RESET（销毁重建）** ——
> 要保留数据就**不要走手册那条分支**，照本节做。
> （给手册补「保留数据 → 应用迁移」这条路是另一片的事，已记为 backlog。）

### 第一步：三个变量

先 `cd` 到**你要部署的那份代码**所在目录（合并之后就是主仓库目录），然后：

```bash
NAS=agate1234@192.168.5.229
DIR=/vol1/1000/agate1234/kline-trainer
WT="$(git rev-parse --show-toplevel)"
```

**自检 —— 不只看变量有没有值，还要确认你站的这份代码里真的有本次要部署的改动**：

```bash
echo "NAS=$NAS"; echo "DIR=$DIR"; echo "WT=$WT"
ls "$WT" | grep -cE '^(backend|docs)$'
grep -c 'schema_version INTEGER NOT NULL,' "$WT/backend/sql/schema.sql"
grep -c 'schema_version INTEGER NOT NULL DEFAULT 1,' "$WT/backend/sql/schema.sql"
test -f "$WT/backend/sql/migrations/0005_schema_version_fail_closed/forward.sql" && echo FORWARD_EXISTS
echo VARS_OK
```

- ✅ 三行都有值；三个计数依次是 **2 / 1 / 0**；并打印 `FORWARD_EXISTS` 与 `VARS_OK`
- ❌ 第二个计数是 0 而第三个是 1 ⇒ 你站的这份代码**还是旧的**，先切到合并后的仓库目录
- ❌ 变量为空 ⇒ **停止**。空的 `$DIR` 会让下面的 `rsync` 作用到 NAS 的家目录上

> ⚠️ 自检刻意**正反各问一次**（新那行在不在 + 旧那行在不在）：只问「新的在不在」时，
> 一份把两行都写进去的畸形文件也会通过。
> ⚠️ `$WT` 在部署手册里**从未被赋值**（它只在手册 `:119` 被文字描述过，而那句描述
> 说的是「`backend` 目录」—— 与全部用法 `$WT/backend/...` 自相矛盾，按用法是**仓库根**）。
> 本节按实际用法给赋值。

### 第二步：同步三份文件，并逐字节核对

⚠️ 要同步的是**三份**，不是一份：

| 文件 | 为什么 |
|---|---|
| `0005/forward.sql` | 要执行的迁移脚本 |
| `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql` | ⚠️ **P6b 硬门执行的是 NAS 上那份副本**。它是 `schema.sql` 形状的快照，本片改过它。**不同步 ⇒ 迁移成功之后 P6b 照样红**（旧快照还要求 `DEFAULT 1`） |
| `backend/sql/schema.sql` | 顺带。本节不用它，但 P6-RESET 之后重建会用 NAS 上那份；不同步的话哪天真做了 RESET，重建出来的库又带回 `DEFAULT 1` |

```bash
rsync -av "$WT/backend/sql/migrations/0005_schema_version_fail_closed/forward.sql" \
          "$NAS:$DIR/sql/0005_schema_version_fail_closed_forward.sql"
```

```bash
rsync -av "$WT/docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql" \
          "$WT/backend/sql/schema.sql" \
          "$NAS:$DIR/sql/"
```

**逐字节核对**（⛔ 不要只看 rsync 打印了文件名就算 —— 结论必须由对比派生）：

```bash
ssh $NAS "cat $DIR/sql/0005_schema_version_fail_closed_forward.sql" \
  | diff -q - "$WT/backend/sql/migrations/0005_schema_version_fail_closed/forward.sql" \
  && echo FORWARD_SYNCED
```

```bash
ssh $NAS "cat $DIR/sql/2026-08-24-qmt-nas-p6b-schema-shape-check.sql" \
  | diff -q - "$WT/docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql" \
  && echo P6B_SNAPSHOT_SYNCED
```

```bash
ssh $NAS "cat $DIR/sql/schema.sql" | diff -q - "$WT/backend/sql/schema.sql" && echo SCHEMA_SYNCED
```

- ✅ 三条分别打印 `FORWARD_SYNCED` / `P6B_SNAPSHOT_SYNCED` / `SCHEMA_SYNCED`
- ❌ 哪条没打印出哨兵 ⇒ **停止**，那份文件没同步成功（或 `$DIR` 写错了）

> ⚠️ 用 `diff -q` 而不是比 md5：NAS（群晖）上有没有 `md5sum` / `sha256sum` 不一定，
> 而 `cat` 一定有。`diff` 不一致时退出码非 0 ⇒ `&&` 后面的哨兵**不会**被打印 ——
> 与手册里 `QUERY_OK` / `CHMOD_OK` 是同一个套路。

### 第三步：应用迁移

```bash
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -U kline -d kline_trainer -v ON_ERROR_STOP=1 -f - < sql/0005_schema_version_fail_closed_forward.sql && echo MIGRATION_0005_OK"
```

- ✅ 打印 `BEGIN` / `ALTER TABLE` / `COMMENT` / `COMMIT`，**且**最后一行是 `MIGRATION_0005_OK`
- ❌ 没看到 `MIGRATION_0005_OK` ⇒ **停止**，⛔ 别当成「迁移已应用」就往下走

> ⚠️ 必须有 `MIGRATION_0005_OK` 这个哨兵。`-v ON_ERROR_STOP=1` 让 psql 一遇错就非零退出，
> 而 `&&` 保证出错时哨兵**不会**被打印。
> ⚠️ **重复执行是安全的**：`ALTER COLUMN … DROP DEFAULT` 对一个已经没有默认值的列
> 不报错、不改任何东西（幂等）。拿不准「跑过没跑过」时，再跑一次比不跑安全。

### 第四步：当场确认默认值真的没了

```bash
ssh $NAS "docker exec -i kline-trainer-db-1 psql -U kline -d kline_trainer -tA -c \"SELECT coalesce(column_default, 'NO_DEFAULT') FROM information_schema.columns WHERE table_name='training_sets' AND column_name='schema_version';\""
```

- ✅ 打印 `NO_DEFAULT`
- ❌ 打印 `1` ⇒ 迁移没生效，回第三步看报错，⛔ 不要往下走

### 第五步：跑 P6b 硬门，并按标签归因

P6b 的命令见部署手册的 P6b 一节。**如果它红了，按标签决定去哪，⛔ 不要一律去销毁数据卷**：

- 红的是 **`FAIL-default-drift`** 且不合格的列是 **`training_sets.schema_version`**
  → 有**两种**可能，先分清，⛔ 否则会来回绕圈：
  1. **NAS 上的闸门快照是旧的**。重跑第二步那条 `P6B_SNAPSHOT_SYNCED` 核对 ——
     **没打印哨兵** ⇒ 就是这一种：库其实是对的、快照过期了。
     回第二步把快照同步上去，再跑 P6b。⛔ 不要再跑一遍迁移。
  2. 快照是新的（打印了哨兵）⇒ 那才是**迁移真没跑**。回第三步。

  ⛔ **最多往返一次。** 第二次还红就停下来，按下面那条处理。
- 其它标签（`FAIL-missing` / `FAIL-type-mismatch` / `FAIL-nullability-drift` /
  `FAIL-definition-drift` / `FAIL-unexpected`）
  → 说明这个库**比 `0005` 落后更多**（例如连 `0004` 都没跑过）。两条路，**都要人明确点头**：
  ① 按同样的方式把 `backend/sql/migrations/0004_qmt_price_double_and_coverage/forward.sql`
     也应用上去（⚠️ 它改列类型、建新表，比 `0005` 重得多，先读它的 `README.md`）；
  ② 确认这个库的数据不值得保留 → 走手册的 P6-RESET 重建。

  ⛔ **不要反复盲试** —— 每跑一个 `forward.sql` 都是在改一个有数据的库。

> ⚠️ 本仓**没有迁移编排器**（没有「记录哪些迁移已经跑过」的表），`0004` 也是同样形态。
> 所以「这个库跑过哪些迁移」只能靠人记 + 靠 P6b 事后发现形状不对。

### 要回滚怎么办

照第二、三步的写法把 `rollback.sql` 换上去执行即可。本次回滚**无数据风险**
（只改列的元数据，不重写任何已有行，已由同目录 `rehearse.sh` 的 Part 3 在真数据库上实证）。
⚠️ 但回滚之后 P6b 会反过来报 `FAIL-default-drift` —— 因为 NAS 上的闸门快照记的是**新形状**。
回滚是「本片的 fail-closed 行为本身导致停机」时的应急手段，不是常规操作。
