# QMT「A 方案 · NAS 版」部署 runbook（P1–P16）

> 日期：2026-08-24 · 对应 spec：`docs/superpowers/specs/2026-08-14-qmt-nas-deployment-design.md` §7
> 目标：把后端跑在飞牛 NAS 上连**真 PostgreSQL**，让 iPhone 经 Tailscale 拉下 3 个用真实 QMT 数据生成的训练片段。
> 前置：PR-1 与 PR-2 均已合并进 `main`（`/health` 的 `repository` 字段与 `api` 服务是本手册的判据基础）。

## 怎么读这份手册

- 「执行者」写 **你** 的步骤，请在自己的终端里跑；写 **Claude** 的步骤我可以代跑。
- **一行一条命令**。⚠️ 不要把多行整块粘贴 —— 一次一条，看完输出再下一条。
- 每个新开的终端窗口都要先跑一遍「准备」那两行（环境变量不会跨窗口保留）。
- 判绿一律**读输出内容**，不要凭「命令没报错」就算过。

## 全局约定

| 名字 | 值 |
|---|---|
| NAS 地址 | `192.168.5.229`（用户名 `agate1234`，已配免密登录） |
| NAS 部署目录 | `/vol1/1000/agate1234/kline-trainer` （**新目录**，刻意避开四月遗留的 `klinetrainer` / `Kline Trainer` / `kline_generator`） |
| compose 项目名 | `kline-trainer`（写死在编排文件里） |
| 容器名 | `kline-trainer-db-1` / `kline-trainer-api-1` |
| 数据卷名 | `kline-trainer_pgdata` |
| tailnet 地址 | `https://fnos.tail9dc815.ts.net` |

### ⛔ 三条硬禁止

1. **不得使用 `tailscale` 的 `funnel` 子命令**（spec §4-D1）。`serve` 只对你自己的 tailnet 内部暴露；`funnel` 会暴露到**公网**，而本 API **零认证** —— 任何人都能把训练组预占、下载并打成已发送。
2. **不得启动 NAS 上那个叫 `kline-postgres` 的旧容器**（2026-04 遗留，绑同一个宿主端口 5433，启动会和我们的数据库打架）。
3. **不得复用旧数据卷**。NAS 上存在四月留下的 `backend_pgdata`；建表脚本全是「表已存在就跳过」的写法，挂错卷会**什么都不改却报成功**，后面所有验收都跑在一个没人校验过的数据库上。

### 准备（每个新终端窗口跑一次）

```
NAS=agate1234@192.168.5.229
```

```
DIR=/vol1/1000/agate1234/kline-trainer
```

---

## P1 · 打开 Tailscale 的 HTTPS 证书开关

**执行者：你**（网页操作，我做不了）

⚠️ **是两个开关，不是一个**（2026-08-24 实测发现 —— 原来这里只写了证书那一个）：

**开关 A · HTTPS 证书**

1. 浏览器打开 <https://login.tailscale.com/admin/dns>
2. 找到 **HTTPS Certificates**，把开关打开（它会让你确认一次）

**开关 B · Serve 功能**

3. 浏览器打开 <https://login.tailscale.com/f/serve?node=nyF6Fsm4hi11CNTRL>（这个链接是 NAS 上的 tailscale 自己吐出来的，直接点开即可），按提示启用 **Serve**

**判据一（我来核，对应开关 A）**：

```
ssh $NAS 'docker exec tailscale tailscale status --json' | /usr/bin/python3 -c "import json,sys;print('CertDomains =', json.load(sys.stdin).get('CertDomains'))"
```

- ✅ 通过：打印出一个含 `fnos.tail9dc815.ts.net` 的列表
- ❌ 不通过：打印 `CertDomains = None` → 开关没生效，**整条链路不要往下走**

**判据二（我来核，对应开关 B）**：直接在 P12 那一步验 —— 若 Serve 没启用，`expose.sh open` 会明确打印 `SERVE_FAILED: tailnet 还没开启 **Serve 功能**` 并且**不会开出任何端点**。

（2026-08-24 实测：`CertDomains` 仍是 `None`；且真跑了一次 `tailscale serve` 得到 `Serve is not enabled on your tailnet` —— 两个开关**都**还没开。）

---

## P2 · 手机连上 Tailscale

**执行者：你**

1. iPhone 上打开 **Tailscale** App
2. 把开关打开，等它显示已连接

**判据（我来核）**：

```
ssh $NAS 'L=$(docker exec tailscale tailscale status | grep iphone); [ -n "$L" ] || { echo QUERY_FAILED; exit 1; }; echo "$L"; echo "$L" | grep -q offline && echo IPHONE_OFFLINE || echo IPHONE_ONLINE'
```

- ✅ 通过：最后一行是 `IPHONE_ONLINE`
- ❌ 不通过：最后一行是 `IPHONE_OFFLINE`（手机没连上）或 `QUERY_FAILED`（这条命令自己没跑成，别当成通过）

> ⚠️ 这里刻意让命令**必须**打印一个明确结论。写成 `... | grep iphone` 的话，命令跑失败时**什么都不打印**，而「没看到 offline」很容易被当成「通过」。

（2026-08-24 实测：离线，最后上线 17 天前。）

---

## P3 · 在 NAS 上建部署目录

**执行者：Claude**

```
ssh $NAS "mkdir -p $DIR/app $DIR/sql $DIR/training-sets && printf 'kline-trainer-deploy\n' > $DIR/.kline-trainer-deploy && ls -la $DIR"
```

- ✅ 通过：列出 `app` / `sql` / `training-sets` 三个子目录，以及一个 `.kline-trainer-deploy` 标记文件

> 这个标记文件不是装饰：后面每一步**动这个目录之前**都会先确认它在，防止 `$DIR` 打错时把命令作用到别的目录上（`rsync --delete` 和销毁卷都会因此变成破坏别人的东西）。

**判据 —— 后面每次动 `$DIR` 前先跑这一条**（下文称「目录身份门」）：

```
ssh $NAS "grep -qx kline-trainer-deploy $DIR/.kline-trainer-deploy && echo DIR_OK || echo DIR_WRONG"
```

- ✅ 通过：打印 `DIR_OK`。打印 `DIR_WRONG` 或报错 → **立刻停**，先查 `$DIR`。

---

## P4 · 把后端文件同步到 NAS

**执行者：Claude**（`WT` = 本机仓库里 `backend` 目录的绝对路径）

⚠️ **先过一遍「目录身份门」**（见 P3）—— 下面第二条带 `--delete`，`$DIR` 打错会**删掉别的目录里的文件**。

```
ssh $NAS "grep -qx kline-trainer-deploy $DIR/.kline-trainer-deploy && echo DIR_OK || echo DIR_WRONG"
```

```
rsync -av "$WT/backend/Dockerfile" "$WT/backend/requirements-api.txt" "$WT/backend/docker-compose.yml" $NAS:$DIR/
```

```
rsync -av --delete --exclude '__pycache__' "$WT/backend/app/" $NAS:$DIR/app/
```

```
rsync -av "$WT/backend/sql/schema.sql" $NAS:$DIR/sql/
```

```
rsync -av "$WT/docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql" "$WT/docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql" "$WT/docs/runbooks/2026-08-24-qmt-nas-p15-reset-training-sets.sql" "$WT/docs/runbooks/2026-08-24-qmt-nas-p10-cleanup-smoke-rows.sql" $NAS:$DIR/sql/
```

```
rsync -av "$WT/docs/runbooks/2026-08-24-qmt-nas-expose.sh" $NAS:$DIR/ && ssh $NAS "chmod +x $DIR/2026-08-24-qmt-nas-expose.sh && echo CHMOD_OK"
```

**判据**：两侧对同一批文件算校验和并比对

```
ssh $NAS "cd $DIR && find . -type f \( -name '*.py' -o -name '*.txt' -o -name '*.yml' -o -name '*.sql' -o -name 'Dockerfile' \) | sort | xargs md5sum | md5sum"
```

```
cd "$WT/backend" && find ./app ./Dockerfile ./requirements-api.txt ./docker-compose.yml -type f -name '*' | sort | xargs md5sum | md5sum
```

- ✅ 通过：`app/` 下的文件个数与内容一致（逐文件比对更稳，见下）
- 更稳的判据（推荐）：

```
ssh $NAS "cd $DIR && md5sum Dockerfile requirements-api.txt docker-compose.yml sql/schema.sql \$(find app -name '*.py' | sort)"
```

把输出与本机 `cd "$WT/backend" && md5sum Dockerfile requirements-api.txt docker-compose.yml sql/schema.sql $(find app -name '*.py' | sort)` **逐行比对**，必须**全部相同**。

---

## P4b · 构建前校验两个基础镜像的 digest 是「多架构」的

**执行者：Claude**（本机跑，需要网络 + Docker）

```
docker buildx imagetools inspect postgres:15.12
```

```
docker buildx imagetools inspect python:3.11.14-slim
```

**判据（两条都要过）**：

- 顶部 `MediaType` 是 `application/vnd.oci.image.index.v1+json`（**image index**，不是单个 manifest）
- `Platform` 列表里**同时**出现 `linux/amd64` 与 `linux/arm64/v8`
- 顶部 `Digest` 与仓库里写的那串**逐字相同**：
  - `postgres:15.12` → `sha256:8f6fbd24a12304d2adc332a2162ee9ff9d6044045a0b07f94d6e53e73125e11c`（compose 里）
  - `python:3.11.14-slim` → `sha256:c8271b1f627d0068857dce5b53e14a9558603b527e46f1f901722f935b786a39`（Dockerfile 里）

⚠️ 为什么必须查这个：结构检查只看得出「有没有 digest」，看不出它是不是单平台的。钉一个单平台 digest 会让镜像在另一种芯片上直接构建/拉取失败（你的 Mac 是 ARM，NAS 是 Intel）。

---

## P5 · 在 NAS 上写配置文件（含真密码）

**执行者：你**（这一步含真实密码，按本仓的安全规则我不代写；密码由命令当场随机生成，不会出现在屏幕上，也不会进入我的上下文）

⚠️ 这是一条**很长但只有一行**的命令，请整行复制粘贴：

```
ssh agate1234@192.168.5.229 'D=/vol1/1000/agate1234/kline-trainer; PW=$(openssl rand -hex 16); printf "POSTGRES_USER=kline\nPOSTGRES_PASSWORD=%s\nPOSTGRES_DB=kline_trainer\nDATABASE_URL=postgresql://kline:%s@db:5432/kline_trainer\nTRAINING_SETS_HOST_DIR=%s/training-sets\n" "$PW" "$PW" "$D" > "$D/.env"; chmod 600 "$D/.env"; echo WROTE_OK'
```

- ✅ 通过：最后一行打印 `WROTE_OK`

**判据（我来核，只看变量名不看值）**：

```
ssh $NAS "cd $DIR && sed 's/=.*/=<hidden>/' .env"
```

- ✅ 通过：**恰好**打印 5 行，变量名依次是 `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` / `DATABASE_URL` / `TRAINING_SETS_HOST_DIR`

---

## P6 · 起数据库（必须是全新空卷）+ 灌建表脚本

**执行者：Claude**

**第一步，确认没有会被误用的旧卷**：

```
ssh $NAS 'docker volume ls --format "{{.Name}}" | grep -qx kline-trainer_pgdata && echo VOLUME_EXISTS || echo VOLUME_ABSENT; echo QUERY_OK'
```

- ✅ 通过：打印 `VOLUME_ABSENT` **且**紧接着打印 `QUERY_OK` → 直接进第二步
- 🛑 打印 `VOLUME_EXISTS`：转 P6-RESET
- ❌ 没看到 `QUERY_OK`：这条命令自己没跑成，**别当成「卷不存在」**，先查 ssh

> ⚠️ 必须有 `QUERY_OK` 这个哨兵。原来写成 `... || echo "(两个都不存在)"`，命令失败时整条什么都不打印，而「没看到那个卷名」正好会被读成「通过」。
> （`backend_pgdata` 是四月遗留，我们不碰它，所以这里不再把它列进来干扰判断。）

> ⚠️ **看到 `VOLUME_EXISTS` 时刻意不写 `docker compose down -v`**（codex 评审 R3 的 high finding）。原来的写法是「看到卷存在 = 授权销毁」，问题有三个：
> ① 卷存在**不等于**它可以丢 —— 上一轮可能已经装进了真数据；
> ② `down -v` 作用于「当前目录解析出来的那个项目」，`$DIR` 写错就会**销毁 NAS 上别的项目的卷**（这台 NAS 上还跑着 `iyuuplus`）；
> ③ 销毁前既不看内容也不留备份，出错不可逆。

**第二步，起数据库**：

```
ssh $NAS "cd $DIR && docker compose up -d db"
```

---

### P6-RESET · 销毁旧数据卷（**破坏性，需要你明确点头**）

只有第一步发现 `kline-trainer_pgdata` 已存在时才走这一节。**四道门全过 + 你明确说「销毁」之后**才执行最后一步。

**门 1 · 确认要动的确实是我们的项目**（防 `$DIR` 写错打到别的项目）

```
ssh $NAS "grep -qx kline-trainer-deploy $DIR/.kline-trainer-deploy && echo DIR_OK || echo DIR_WRONG"
```

- ✅ 通过：打印 `DIR_OK`

```
ssh $NAS "docker compose -f $DIR/docker-compose.yml config" | head -1
```

- ✅ 通过：输出**恰好**是 `name: kline-trainer`。不是的话**立刻停**，先查 `$DIR`。

**门 2 · 看清楚这个卷里到底有什么**

```
ssh $NAS "cd $DIR && docker compose up -d db"
```

```
ssh $NAS "docker inspect kline-trainer-db-1 --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'"
```

- ✅ 通过：输出是 `kline-trainer_pgdata -> /var/lib/postgresql/data`（确认待销毁的就是这一个）

```
ssh $NAS "docker exec kline-trainer-db-1 psql -U kline -d kline_trainer -c 'SELECT count(*) AS 训练组行数 FROM training_sets;' -c 'SELECT id, stock_code, status FROM training_sets ORDER BY id;'"
```

**门 3 · 先备份，并且把备份**真恢复一遍**来验证它能用**

> ⚠️ **刻意不用 `pg_dump ... | gzip > 文件` 这种写法**（codex 评审 R4 的 high finding，**已实测**）。
> 那条管道没开 `pipefail`，`pg_dump` 失败时 —— 比如连不上、认证失败、库名写错 ——
> **整条管道的退出码仍然是 0**，`gzip` 会产出一个 **20 字节、`gzip -t` 能通过、内容 0 行**的
> 空文件。原来的判据「大小不是 0 + `gzip -t` 通过」会打印 `BACKUP_OK`，紧接着卷就被销毁 ——
> 这是一条真实的、不可逆的数据丢失路径。
>
> 现在：用**自定义格式**（`-Fc`，本身就压缩）**完全去掉管道**，退出码直接就是 `pg_dump` 的；
> 先写临时名，**只有成功才改名**（失败时连最终文件都不会存在）；再用三道递进的校验。

**3a · 先给这次备份定一个带时间戳的名字**（在你自己的终端里跑，只设一个变量）

```
BK=$DIR/backup-before-reset-$(date +%Y%m%d-%H%M%S).dump
```

**3b · 备份（无管道；失败就不改名）**

```
ssh $NAS "docker exec kline-trainer-db-1 pg_dump -U kline -d kline_trainer -Fc > $BK.tmp && mv $BK.tmp $BK && echo DUMP_OK"
```

- ✅ 通过：打印 `DUMP_OK`
- ❌ 没打印 `DUMP_OK`：备份失败，**立刻停**，绝不往下走

**3c · 结构校验：备份里必须含 4 张表的数据**

```
ssh $NAS "docker exec -i kline-trainer-db-1 pg_restore --list < $BK" | grep -c 'TABLE DATA'
```

- ✅ 通过：打印 `4`
（实测：空文件与截断文件在这一步都会被拒，退出码 1。）

**3d · 语义校验：把备份真恢复到一个临时库，比对行数**

```
ssh $NAS "docker exec kline-trainer-db-1 psql -q -U kline -d postgres -c 'DROP DATABASE IF EXISTS restore_check;' -c 'CREATE DATABASE restore_check;'"
```

```
ssh $NAS "docker exec -i kline-trainer-db-1 pg_restore -U kline -d restore_check --no-owner < $BK && echo RESTORE_OK"
```

```
ssh $NAS "docker exec kline-trainer-db-1 psql -tA -U kline -d restore_check -c \"SELECT count(*) FROM pg_tables WHERE schemaname='public';\" -c 'SELECT count(*) FROM training_sets;'"
```

- ✅ 通过：上一条打印 `RESTORE_OK`；这一条打印**两行** —— 第一行是 `4`（表数），第二行的行数与**门 2 看到的行数一模一样**
- ❌ 任一条不符：**立刻停**，备份不可信，绝不销毁卷

```
ssh $NAS "docker exec kline-trainer-db-1 psql -q -U kline -d postgres -c 'DROP DATABASE restore_check;'"
```

（校验用的临时库清掉。它本来就在马上要销毁的那个卷里，但保持干净便于后面读日志。）

**门 4 · 报给你，等你明确点头**

我会把门 2 看到的行数与内容、门 3 的备份文件名报给你。⛔ **在你明确回复「销毁」之前，下面两条不执行。**

**执行销毁**（⚠️ 不可逆；**显式指名那一个卷**，不用 `down -v`）

```
ssh $NAS "docker compose -f $DIR/docker-compose.yml down"
```

```
ssh $NAS "docker volume rm kline-trainer_pgdata"
```

```
ssh $NAS 'docker volume ls --format "{{.Name}}" | grep -qx kline-trainer_pgdata && echo STILL_THERE || echo GONE; echo QUERY_OK'
```

- ✅ 通过：打印 `GONE` **且**紧接着打印 `QUERY_OK`

```
ssh $NAS 'docker volume ls --format "{{.Name}}" | grep -c . ; echo QUERY_OK'
```

- ✅ 通过：卷总数比销毁前**恰好少 1**（销毁前先跑一次这条记下数字），且打印 `QUERY_OK` —— 证明只删掉了那一个，没误伤别的项目

销毁后回到 P6 第二步。

**第三步，等它健康**：

```
ssh $NAS "cd $DIR && docker compose ps --format '{{.Service}} {{.State}} {{.Status}}'"
```

- ✅ 通过：`db running Up ... (healthy)`

**第四步，确认挂的是新卷**：

```
ssh $NAS "docker inspect kline-trainer-db-1 --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'"
```

- ✅ 通过：输出是 `kline-trainer_pgdata -> /var/lib/postgresql/data`
- ❌ 若出现 `backend_pgdata`：**立刻停止**，编排文件的项目名没生效

**第五步，灌建表脚本**：

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -f - < sql/schema.sql > /tmp/schema-load.log 2>&1 && echo SCHEMA_LOAD_OK || echo SCHEMA_LOAD_FAILED"
```

```
ssh $NAS "grep -c ERROR /tmp/schema-load.log; echo GREP_DONE"
```

- ✅ 通过：第一条打印 `SCHEMA_LOAD_OK`，第二条打印 `0` 且随后打印 `GREP_DONE`
- ❌ 任一条不符：**停止**

> ⚠️ 刻意不用 `| tail -5` 判断。日志前面出现的 `ERROR` 会被 `tail` 整个截掉 —— 那正是最需要看到的那一行。

⚠️ `\dt` 能列出 4 张表**不算通过** —— 建表脚本全是「已存在就跳过」，旧卷会让它什么都不改却报成功。真正的判据是下一步 P6b。

---

## P6b · 直接查数据库的**实际形状**（硬门）

**执行者：Claude**

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -U kline -d kline_trainer -f - < sql/2026-08-24-qmt-nas-p6b-schema-shape-check.sql"
```

- ✅ 通过：命令**只打印不合格项**，所以健康库上表格是 `(0 rows)`，末尾出现 `NOTICE: P6b GATE PASS: 38 列 + 15 约束（含主键/外键）+ 9 索引，逐条吻合且无多余项`
- ❌ 有任何一行被打出来：命令会以**非零码**退出并打印 `P6b GATE FAIL`。**停止**，走 **P6-RESET** 那一节（⛔ 不要直接 `docker compose down -v` —— 理由见 P6），销毁后回 P6 第二步，**不得**往下插数据

**它查的是「完整形状契约」，三类各自双向比对**（缺、多、改都会红）：

| 类别 | 查什么 |
|---|---|
| 列（38 个） | 每张表每一列的**类型**（含长度精度）、**能不能为空**、**默认值** |
| 约束（15 条） | **主键 / 外键 / 唯一 / CHECK 全四类**，按「所属表 + 名字」匹配，比对**完整定义原文** |
| 索引（9 条） | 完整索引定义，**含部分索引的 `WHERE` 条件与列的顺序** |

六种失败标签各自的含义：

| 标签 | 意思 |
|---|---|
| `FAIL-missing` | 该列 / 约束 / 索引在这个库里**不存在** |
| `FAIL-type-mismatch` | 列存在但**类型不对** |
| `FAIL-nullability-drift` | 列的「能不能为空」被改过 |
| `FAIL-default-drift` | 列的**默认值**被改过 |
| `FAIL-definition-drift` | 约束/索引名字还在、但**定义被改过**（最阴险的一种：名字看着没变） |
| `FAIL-unexpected` | 库里有**预期之外**的列 / 约束 / 索引（多半是上一版 schema 留下的） |

⚠️ **如果是在一个全新空卷上本门也红**：那说明 `backend/sql/schema.sql` 改过了，而这份闸门文件是它的形状快照（文件头记着 schema.sql 的 md5）。这时要**重新生成闸门文件**，不是怀疑部署。

⚠️ **一个已知且刻意保留的行为**：如果这个库是被**就地改造**出来的（比如跑过 `ALTER COLUMN ... TYPE` 之类的迁移），PostgreSQL 会把依赖那一列的约束**重新渲染一遍** —— 语义完全一样、文字不一样，本门会报 `FAIL-definition-drift`。**这是想要的结果**，不是误报：P6 的前提本来就是「必须是全新空卷」，库不是新的就该停下来重建，而不是把闸门放宽。

**判别力已逐档实测**（2026-08-24，本机真 PostgreSQL 15.12。⚠️ **每一档都在一个全新建的库上跑**，不用「就地复原」—— 因为 `ALTER COLUMN TYPE` 会顺带改写约束文字，就地复原会把后面几档的结果污染成假的）：

| 破坏 | 结果 |
|---|---|
| 删掉一条 CHECK | `FAIL-missing` |
| **同名 CHECK 定义被改宽** | `FAIL-definition-drift` |
| **同名 CHECK 挪到别的表** | `FAIL-missing` + `FAIL-unexpected` |
| 多出一条约束 | `FAIL-unexpected` |
| 改列类型（`file_path`） | `FAIL-type-mismatch` |
| **删掉 `klines`→`stocks` 外键** | `FAIL-missing` |
| **删掉 `training_sets` 主键** | `FAIL-missing` |
| **删掉 lease 部分索引** | `FAIL-missing` |
| **部分索引丢掉 `WHERE` 条件（名字不变）** | `FAIL-definition-drift` |
| **lease 列类型 `timestamptz`→`timestamp`** | `FAIL-definition-drift` + `FAIL-type-mismatch` |
| **默认值被改（`schema_version`）** | `FAIL-default-drift` |
| **可空性被改（`file_path`）** | `FAIL-nullability-drift` |
| 多出一列 / 删掉一列 | `FAIL-unexpected` / `FAIL-missing` |
| **唯一约束的列集合被改** | `FAIL-definition-drift` |

健康库退出码 0，上述 15 档全部退出码 3。

> ⚠️ **本门前两版都被 codex 评审打回过，两条都实测坐实**：
> **R1** 只比对约束**名字**，不看所属表也不看定义 → 「同名改定义」与「同名换表」两档实测**放行**；后者会让 `klines` 的价格排序约束整个消失，`high < low` 的脏数据可以直接进库。
> **R2** 只查 6 个选定列、只看 CHECK/UNIQUE 两类 → **主键、外键、索引、可空性、默认值、其余列类型全部不查**；少了那个外键会产生孤儿行，少了两条 lease 部分索引会让预占查询退化，而闸门照样说「健康」。

---

## P7 · 把 3 个训练组压缩包放到 NAS，并**重算指纹**

**执行者：Claude**

⚠️ 先过一遍「目录身份门」（见 P3）：

```
ssh $NAS "grep -qx kline-trainer-deploy $DIR/.kline-trainer-deploy && echo DIR_OK || echo DIR_WRONG"
```

NAS 上本来就有一份备份（2026-08-24 复核过指纹三个全对），直接从那里复制最省事：

```
ssh $NAS "cp /vol1/1000/agate1234/kline-trainer-handoff-20260814/training-sets/*.zip $DIR/training-sets/ && ls -la $DIR/training-sets/"
```

**判据（必做，不许跳）**：

```
ssh $NAS "cd $DIR/training-sets && for f in *.zip; do printf '%s  %s\n' \"\$(python3 -c \"import zlib,sys;print('%08x'%(zlib.crc32(open(sys.argv[1],'rb').read())&0xffffffff))\" \"\$f\")\" \"\$f\"; done"
```

- ✅ 通过：三行**逐字**等于

```
851f9444  000001.SZ_1756656000.zip
150d8d6c  000001.SZ_1762099200.zip
32892a5f  600519.SH_1762099200.zip
```

⚠️ 传坏了的话，失败点会落在手机端的完整性校验上，症状非常难认 —— 所以在这里先拦一道。

---

## P8 · 起后端服务

**执行者：Claude**

```
ssh $NAS "cd $DIR && docker compose build > /tmp/build.log 2>&1 && echo BUILD_OK || echo BUILD_FAILED"
```

```
ssh $NAS "grep -c 'failed to solve' /tmp/build.log; echo GREP_DONE"
```

- ✅ 通过：第一条打印 `BUILD_OK`，第二条打印 `0` 且随后打印 `GREP_DONE`
- ❌ 任一条不符：**停止**

> ⚠️ 同样刻意不用 `| tail -5`：`failed to solve` 往往出现在很长的构建日志中间，会被 `tail` 截掉。

**如果这一步失败（spec §11-R4 的退路）**：NAS 上构建需要它能连到 PyPI 和 Docker Hub（2026-08-14 实测都通，但网络会变）。若构建卡在下载上，改成**在 Mac 上构建好再送过去**：

```
docker build --platform linux/amd64 -t kline-trainer-api:latest "$WT/backend"
```

```
docker save kline-trainer-api:latest | ssh $NAS 'docker load'
```

⚠️ `--platform linux/amd64` 不能省 —— 你的 Mac 是 ARM 芯片，NAS 是 Intel，不指定会造出一个 NAS 跑不了的镜像。
送过去之后，编排里的 `api` 服务要临时改成用 `image: kline-trainer-api:latest` 代替 `build:`（⚠️ 那个 `image:` **不得**带 `@sha256:` digest，否则 compose 会直接报错）。这条退路属于应急，走了要在 PR 里记一笔。

```
ssh $NAS "cd $DIR && docker compose up -d api"
```

```
ssh $NAS "cd $DIR && docker compose ps --format '{{.Service}} {{.State}} {{.Status}} {{.Ports}}'"
```

- ✅ 通过：`api running Up ... 127.0.0.1:8010->8000/tcp` 且 `db ... (healthy)`

**关键判据 —— 后端到底连的是真库还是假库**：

```
ssh $NAS "curl -s --max-time 10 http://127.0.0.1:8010/health"
```

- ✅ 通过：输出**恰好**是 `{"status":"ok","repository":"asyncpg"}`
- ❌ 若 `"repository":"inmemory"`：数据库地址没生效，后端在用内存假库。**停止排查**，不要往下走

**顺带确认只读挂载真的生效**：

```
ssh $NAS "docker exec kline-trainer-api-1 sh -c 'ls /data/training-sets && (touch /data/training-sets/x 2>&1 || true)'"
```

- ✅ 通过：能列出 3 个 zip，且 `touch` 报 `Read-only file system`

---

## P9 · 8 条真 PostgreSQL 烟测

**执行者：Claude** · **⚠️ 必须在插入 3 行真数据（P11）之前跑完**

原因（spec §9.2）：预占接口的 SQL 是「按创建时间排序取最早的 N 行」，**没有任何参数能指定预占哪一行**。如果表里已经有真数据，烟测就会抢走真数据行并把它打成「已发送」—— 手机还没开始下载，库存就被烧掉了。唯一可靠的隔离是**时间隔离**：此刻表里除了烟测自己插的行，什么都没有。

**NAS-A.1** 插入一条临时行：

```
ssh $NAS "docker exec kline-trainer-db-1 psql -U kline -d kline_trainer -c \"INSERT INTO training_sets(stock_code,stock_name,start_datetime,end_datetime,file_path,content_hash) VALUES('SMOKE-A','SMOKE-A',0,0,'/data/training-sets/none-a.zip','deadbeef') RETURNING id;\""
```

- ✅ 记下返回的 `id`（下面叫 `A_ID`）

**NAS-A.2** 预占一条：

```
ssh $NAS "curl -s --max-time 10 'http://127.0.0.1:8010/training-sets/meta?count=1'"
```

- ✅ 通过：返回 JSON 里 `sets` 恰好 1 条且其 `id` == `A_ID`；`expires_at` 以 `Z` 结尾

**NAS-A.3** **不要** confirm，等 **10 分 1 秒**（租约有效期是 10 分钟）：

```
sleep 601 && echo "等待完成"
```

⚠️ 这一条耗时长但**必须真等**，不得靠推演判过。

**NAS-A.4** 再预占一次：

```
ssh $NAS "curl -s --max-time 10 'http://127.0.0.1:8010/training-sets/meta?count=1'"
```

- ✅ 通过：`sets[0].id` 仍然是 `A_ID`（过期的预占可以被重新选中）

**NAS-B.1** 再插一条临时行：

```
ssh $NAS "docker exec kline-trainer-db-1 psql -U kline -d kline_trainer -c \"INSERT INTO training_sets(stock_code,stock_name,start_datetime,end_datetime,file_path,content_hash) VALUES('SMOKE-B','SMOKE-B',0,0,'/data/training-sets/none-b.zip','deadbeef') RETURNING id;\""
```

- ✅ 记下 `B_ID`

**NAS-B.2** 预占：

```
ssh $NAS "curl -s --max-time 10 'http://127.0.0.1:8010/training-sets/meta?count=1'"
```

- ✅ 通过：`sets[0].id` == `B_ID`（A 行刚在 A.4 拿到新租约，还没过期，所以选不到它）
- ✅ 记下返回的 `lease_id`

**NAS-B.3** 确认收货（把上一步的 `lease_id` 填进去）：

```
ssh $NAS "curl -s --max-time 10 -X POST 'http://127.0.0.1:8010/training-set/<B_ID>/confirm?lease_id=<LEASE_ID>'"
```

- ✅ 通过：输出**恰好**是 `{"ok":true}`

**NAS-B.4** 再预占：

```
ssh $NAS "curl -s --max-time 10 'http://127.0.0.1:8010/training-sets/meta?count=1'"
```

- ✅ 通过：`sets` 是 `[]`（已发送的行不会被再次选中）

---

## P10 · 删光烟测临时行（这是 P11 的前置硬门）

**执行者：Claude**

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -f - < sql/2026-08-24-qmt-nas-p10-cleanup-smoke-rows.sql"
```

- ✅ 通过：打印 `P10 GATE PASS: 表已清空，可以执行 P11`（表本来就空时打印 `P10 GATE PASS（幂等）`）
- ❌ 非零退出：**停止**，不得往下插真数据

> ⚠️ **这一步刻意不做无条件全表删除**（codex 评审 R3 的 high finding）。原来写的是 `DELETE FROM training_sets;` —— 安全性**完全**靠操作者按 P9→P10→P11 的次序执行。实测过后果：如果 P10 在 P11 之后被重跑一次，**3 行真数据被删光、退出码 0、闸门打印 `P10 GATE PASS`**。一边毁数据一边报成功，是最难发现的一种错。
>
> 现在的脚本：整段在**一个事务**里；先断言表里**没有任何非烟测行**（有就拒绝、一行都不动）；只删带 `SMOKE-A` / `SMOKE-B` 标记的行；删完再断言表为空；表本来就空时幂等通过。
>
> **判别力已实测**（2026-08-24，本机真 PostgreSQL）：只有烟测行 → 删净通过；空表 → 幂等通过；**只有 3 行真数据 → 拒绝，3 行一行不少**；**烟测行与真数据混合 → 拒绝，4 行一行不少**（事务回滚）。

---

## P11 · 写入 3 行真数据

**执行者：Claude**

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -f - < sql/2026-08-24-qmt-nas-p11-insert-training-sets.sql"
```

- ✅ 通过：打印 `P11 GATE PASS: 恰好 3 行、逐字段与期望吻合、全部 unsent`，随后列出 3 行，`content_hash` 依次是 `851f9444` / `32892a5f` / `150d8d6c`
- ❌ 非零退出：**停止**（表非空时它会拒绝插入，不会往已有内容上叠加）

> ⚠️ 判据是**完整七元组双向比对**（股票代码 / 名称 / 起止时间 / schema 版本 / 文件路径 / 指纹），不是「3 行 + 路径前缀对」。理由见 P15 那一节 —— 指纹只有 8 位且表上没有唯一约束，单靠它认不出身份。
>
> **判别力已实测**（2026-08-24，本机真 PostgreSQL）：空表上跑 → 3 行写入且逐字段吻合；**重跑一次 → 拒绝，行数不变**；**表里已有别的行 → 拒绝，不叠加**；P11 的产物直接喂给 P15 → 通过（这一步同时证明两份 SQL 里的期望副本逐字一致）。

---

## P11b · 暴露之前，重新核一遍谁能连进这个 tailnet

**执行者：Claude**

```
ssh $NAS 'docker exec tailscale tailscale status --json' | /usr/bin/python3 -c "
import json,sys
d=json.load(sys.stdin); peers=d.get('Peer') or {}; users=d.get('User') or {}
me=d.get('Self',{}).get('UserID')
bad=[]
for p in peers.values():
    if p.get('UserID')!=me or p.get('ShareeNode'): bad.append((p.get('HostName'),p.get('UserID'),p.get('ShareeNode')))
print('节点数（含自己） =', len(peers)+1)
print('归属者 =', sorted({users[str(u)]['LoginName'] for u in [me]+[p.get('UserID') for p in peers.values()] if str(u) in users}))
print('异常节点 =', bad if bad else '无')
print('GATE', 'PASS' if not bad else 'FAIL')
"
```

- ✅ 通过：最后一行是 `GATE PASS`，归属者只有 `agateuu1234@gmail.com` 一个
- ❌ 出现别的归属者或共享节点：**停止，不得执行 P12**，须先回 spec §11-R8 重新评估「不加认证」这个决定还成不成立

（2026-08-24 实测：7 个节点、归属者全是同一个、无共享节点。）

---

## P12 · 打开对外端点（⛔ 只许用 serve，不许用 funnel）

**执行者：Claude**

```
ssh $NAS "$DIR/2026-08-24-qmt-nas-expose.sh open 7200"
```

- ✅ 通过：先打印 `WATCHDOG_ARMED 到期时刻=…`，最后一行是 `EXPOSE_OK`
- ❌ 打印 `SERVE_FAILED` / `REFUSING_TO_OPEN`：**没有开出任何端点**，按提示回去补 P1 的两个开关

> ⚠️ **为什么不直接敲 `tailscale serve`**（codex 评审 R6 的 high finding）：`serve --bg` 是**持久**配置，跟开它的那个终端无关。而这个 API **零认证** —— spec 里「本次不加认证」这个决定的四个前提，第四条就是「暴露窗口只限验收期间、用完即关」。把关闭交给一条人工嘱咐，等于断线/临时有事/某步失败就一直开着。
>
> `expose.sh open` 做了两件手动敲做不到的事：① **先装超时自动关闭的看门狗，装不上就拒绝开端点**；② 开完立刻自检配置里没有 funnel。`7200` = 2 小时窗口，到点自动关。
>
> **判别力已实测**（2026-08-24，NAS 真机）：不撤销 → 到点真的执行了关闭并记进日志；`open` 时前置没满足 → 打印精确诊断、撤掉看门狗、**未开出任何端点**；撤销后 → 到点不触发（日志记 `WATCHDOG_DISARMED`）。

**验收时间不够怎么办**（别让它在你正用着的时候关掉）：

```
ssh $NAS "$DIR/2026-08-24-qmt-nas-expose.sh status"
```

```
ssh $NAS "$DIR/2026-08-24-qmt-nas-expose.sh renew 7200"
```

- `status` 会打印剩余秒数；剩得不多就 `renew` 续 2 小时

⚠️ **NAS 如果重启过**：看门狗进程会被杀掉，而 tailscale 的 serve 配置是持久的 —— 端点会自己回来却没人看着。`status` 会把这种情况明确报成 `WATCHDOG_PROCESS_MISSING`。看到它就立刻跑 `close`。

**判据二 —— 从你的 Mac 经 tailnet 真的连得上，且证书可验**：

```
curl -s --max-time 15 https://fnos.tail9dc815.ts.net/health
```

- ✅ 通过：输出**恰好**是 `{"status":"ok","repository":"asyncpg"}`（`curl` 不加 `-k` 也不报证书错，就说明证书是可信的）

⚠️ 从这一刻起，端点对你 tailnet 里的**全部设备**开着，且**零认证**。P16 之前不要走开太久。

---

## P12b · 紧挨着真机验收前，再核一次暴露面

**执行者：Claude** · 判据与 P11b **完全相同**（重跑那条命令）

原因：P11b 到 P13 之间隔着装机和签名，可能是几十分钟到几天。

- ❌ 不通过 → **不许开始 P13**

---

## P13 · 把 Debug 版 App 装到手机并带上后端地址启动

**执行者：你**（需要开发者签名，必须在你自己的终端里跑）

1. 用 Xcode 把 Debug 版装到 iPhone（Product → Run，或 Xcode 的 Devices 窗口安装）
2. ⚠️ **如果这是重跑**（之前已经装过并下载过训练组），必须先在手机上**长按图标 → 删除 App**，再重新安装。仅仅覆盖安装**不会**清掉本地数据 —— 上一轮下载的 3 个训练组还在，你会在**旧东西**上看到「成功」，而这一轮其实一个字节都没下载。
3. 用下面这条命令启动（它会把后端地址传给这次启动的进程）：

```
xcrun devicectl device process launch --device <你的设备ID> --environment-variables '{"KLINE_BACKEND_BASE_URL":"https://fnos.tail9dc815.ts.net"}' <你的 App Bundle ID>
```

（设备 ID 用 `xcrun devicectl list devices` 查。）

- ✅ 通过：App 正常启动，没有报错弹窗

⚠️ 这个环境变量**只在这一次启动的进程里有效**。之后从桌面图标点开 App 不会带它，后端地址会回落到占位值。这**不影响**验收 —— 训练组下载完就存在手机本地了，离线也能看能练。

---

## P14 · 真机验收（四条缺一不算成）

**执行者：你**（目视）

| 编号 | 动作 | 预期 | 通过条件 |
|---|---|---|---|
| G1 | （我来跑）`curl -s https://fnos.tail9dc815.ts.net/health` | 打印一行 | 内容恰好是 `{"status":"ok","repository":"asyncpg"}` |
| G2 | App 里进「设置 → 离线缓存下载」，数量填 **3**，点下载 | 状态行逐条变化 | 状态行显示 **3 个成功**；本地训练组列表出现 **3 条** |
| G3 | （我来跑）查数据库那 3 行 | 打印 3 行 | `status` 全部是 `sent` |
| G4 | 训练组列表里**任选一条**点进去 | 图表区出现蜡烛图 | 真的画出了 K 线（不是空白、不是报错） |

G3 的命令（我跑）：

```
ssh $NAS "docker exec kline-trainer-db-1 psql -U kline -d kline_trainer -c 'SELECT id, stock_code, status FROM training_sets ORDER BY id;'"
```

### 验收时会看到、但**不是** bug 的两件事

1. **训练组显示的名字是股票代码（`000001.SZ` / `600519.SH`），不是中文名**（spec §11-R5）。真实 QMT 导出的数据本身就没带中文名，不是程序错。本次不修。
2. **列表里有两条都是 `000001.SZ`**，只是时间区间不同（一条 2025-09-01 → 2026-05-05，一条 2025-11-03 → 2026-06-30；均为北京时间，由库里的时间戳换算，2026-08-24 实算）。这是对的 —— 3 个片段本来就是 2 只股票、3 个区间（另一条是 `600519.SH`，区间同后者）。

⚠️ **G1 只是快速前置检查，不是决定性证据**。决定性的是 **G3**：内存假库里一行都没有，如果真走了假库，预占会返回空列表、手机一个压缩包都拉不到、库里三行也不会变 `sent`。G2 + G3 同时成立就排除了假库那条路。

⚠️ **如果这是重跑**：没有同时做「库侧复位（P15）+ 手机上删掉 App 重装」的话，G2 / G4 的观察结果**一律作废**，不得记为通过。

---

## P15 · （仅在失败重跑时）复位

**执行者：库侧 Claude / 设备侧 你**

**库侧**：

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -f - < sql/2026-08-24-qmt-nas-p15-reset-training-sets.sql"
```

- ✅ 通过：打印 `P15 GATE PASS: 3 行全部 unsent 且 lease 三列全 NULL`
- ❌ 非零退出：**停止**，一行都没被动过；先查清楚库里到底是什么

> ⚠️ **这一步被打回过两次，现在是第三版**。
> **R1 版**：无条件全表 `UPDATE` + 事后数行数 —— 与 codex 打回 P10 的是同一类缺陷。
> **R2 版**：改成「按指纹（`content_hash`）认身份」—— **仍然不够**（codex 评审 R5）。指纹只有 8 位 CRC32，表上**没有唯一约束**；判据只证明了「这 3 行的指纹都属于期望集合」，没证明每个指纹**各出现一次**，也没检查股票代码 / 时间区间 / 文件路径。
> **实测坐实**：三行股票代码全错、文件路径指向 `/tmp/WRONG-*.zip`、三行共用同一个期望指纹 —— **R2 版通过了，把这三行全部复位成「可下载」，还打印 PASS**。后果是让不该发的数据变成可下载。
>
> **现在（R3 版）**：期望写成**完整七元组**，与表内容做**双向 `EXCEPT ALL`**（保留重数）—— 多一行、少一行、重复一行、任一字段不符都会红；`UPDATE` **按主键**进行，主键从精确匹配中取，不再拿指纹当身份。
>
> **判别力已实测**（2026-08-24，本机真 PostgreSQL，六档）：正常 → 复位成功；再跑一次 → 幂等通过；**上面那个「三行全错共用一个指纹」的场景 → 拒绝，0 行被复位**；**指纹对但文件路径被换掉一个 → 拒绝**；**指纹对但时间区间被改 → 拒绝**；**重数不对（一行重复、另一行缺失）→ 拒绝**。另已验「只改状态不清租约列」会被数据库完整性约束拒绝。

**设备侧**：手机上**长按图标 → 删除 App**，然后回到 P13 重装。

⚠️ **次序**：复位期间端点必须保持**关闭**（先做 P16 再复位）。复位后重新开始时才由 P12 重新打开。理由：复位把 3 行退回「未发送」，此时任何 tailnet 里的设备（或手机上一个残留的 App 进程）都能把库存预占掉，直接毁掉下一次验收。

---

## P16 · 关闭对外端点（**每一条路径都必须做，不只是成功路径**）

**执行者：Claude**

```
ssh $NAS "$DIR/2026-08-24-qmt-nas-expose.sh close"
```

- ✅ 通过：打印 `No serve config`，最后一行是 `CLOSE_OK`
- ❌ 打印 `CLOSE_FAILED`：按提示处理，**不要当成已关**

（`close` 是幂等的：本来就没开也会直接 `CLOSE_OK`。它同时撤掉看门狗，避免陈旧看门狗在下一个窗口里乱关。）

**什么时候必须执行**：

| 路径 | 是否必须关 |
|---|---|
| P14 四条全过 | **是** |
| P13 / P14 失败 | **是**，而且必须在 P15 复位**之前**关 |
| 中途暂停 / 人为中止 / 换机 / 下班 | **是** |
| 复位后准备再来一轮 | 复位期间保持关闭，重新开始时才由 P12 重开 |

⚠️ `tailscale serve --bg` 是**持久**配置，不会自己消失。这是「本次不加认证」这个决定能成立的第四个前提（前三个是：单用户 tailnet、无外部共享节点、不用 funnel）。

---

## 失败时怎么认症状

| 现象 | 多半是哪一步的问题 | 怎么确认 |
|---|---|---|
| 手机「下载成功」但一个训练组都没有 | 后端连的是内存假库 | P8 的 `/health` 是不是 `"repository":"inmemory"` |
| 下载一律 404 | 数据库里的文件路径与容器里的实际路径对不上 | `docker exec kline-trainer-api-1 ls /data/training-sets` 与库里 `file_path` 对照 |
| 手机端报完整性校验失败 | 压缩包传坏了 | 回 P7 重算指纹 |
| App 报网络错误 | 手机的 Tailscale 没开 | P2 |
| `tailscale serve` 报错或证书不可验 | HTTPS 证书开关没开 | P1 |
| confirm 返回 409 | 租约过期了（10 分钟） | 库里查 `status` 与 `lease_expires_at` |
| NAS 断电重启后 api 没起来 | 数据库比 api 慢 | `docker compose ps` 看 api 是不是 running；编排里已配健康检查 + 依赖条件 + 自动重启三件套 |

---

## 本次交付**不**代表的事（措辞纪律，spec §1 + §13.0）

- **不得**说「pilot 已完成」「100 股已出货」「真实数据接入完成」—— 本次只搬 3 个片段做端到端链路验收。
- **不得**说「PR11-R1 已关闭」「生产后端地址已接通」「backendBaseURL 已可配置」（不带限定）—— Release 构建**仍然**是硬编码占位地址，上架阻塞依然存在。本次打通的是 **debug-only** 通道。
- 这 3 组数据是在**本地副本上做了临时转换**后生成的、**不是**走生产流水线产出的（残留 W1-R2 只能标「部分满足」）。生产路径上还压着两个已知缺陷（导出日志里周期列写 `1d` 而代码只认 `daily`，导致日线被静默跳过；一只股的坏行会让整份日志读不了），归 4b/4c，本次不修。
