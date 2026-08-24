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

1. 浏览器打开 <https://login.tailscale.com/admin/dns>
2. 找到 **HTTPS Certificates**，把开关打开（它会让你确认一次）

**判据（我来核）**：

```
ssh $NAS 'docker exec tailscale tailscale status --json' | /usr/bin/python3 -c "import json,sys;print('CertDomains =', json.load(sys.stdin).get('CertDomains'))"
```

- ✅ 通过：打印出一个含 `fnos.tail9dc815.ts.net` 的列表
- ❌ 不通过：打印 `CertDomains = None` → 开关没生效，**整条链路不要往下走**

（2026-08-24 实测仍是 `None`，所以这一步确实还没做。）

---

## P2 · 手机连上 Tailscale

**执行者：你**

1. iPhone 上打开 **Tailscale** App
2. 把开关打开，等它显示已连接

**判据（我来核）**：

```
ssh $NAS 'docker exec tailscale tailscale status' | grep iphone
```

- ✅ 通过：那一行**不含** `offline`
- ❌ 不通过：仍显示 `offline, last seen ...`

（2026-08-24 实测：离线，最后上线 17 天前。）

---

## P3 · 在 NAS 上建部署目录

**执行者：Claude**

```
ssh $NAS "mkdir -p $DIR/app $DIR/sql $DIR/training-sets && ls -la $DIR"
```

- ✅ 通过：列出 `app` / `sql` / `training-sets` 三个子目录

---

## P4 · 把后端文件同步到 NAS

**执行者：Claude**（`WT` = 本机仓库里 `backend` 目录的绝对路径）

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
rsync -av "$WT/docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql" "$WT/docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql" "$WT/docs/runbooks/2026-08-24-qmt-nas-p15-reset-training-sets.sql" $NAS:$DIR/sql/
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
ssh $NAS 'docker volume ls | grep -E "kline-trainer_pgdata|backend_pgdata" || echo "(两个都不存在)"'
```

- ✅ 通过：**看不到** `kline-trainer_pgdata`。（看到 `backend_pgdata` 是正常的 —— 那是四月遗留，我们不碰它。）
- ❌ 若已存在 `kline-trainer_pgdata`：说明之前部署过。**必须先销毁**再继续：
  ```
  ssh $NAS "cd $DIR && docker compose down -v"
  ```

**第二步，起数据库**：

```
ssh $NAS "cd $DIR && docker compose up -d db"
```

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
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -f - < sql/schema.sql" | tail -5
```

- ✅ 通过：最后一行是 `COMMIT`，且**没有** `ERROR`

⚠️ `\dt` 能列出 4 张表**不算通过** —— 建表脚本全是「已存在就跳过」，旧卷会让它什么都不改却报成功。真正的判据是下一步 P6b。

---

## P6b · 直接查数据库的**实际形状**（硬门）

**执行者：Claude**

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -U kline -d kline_trainer -f - < sql/2026-08-24-qmt-nas-p6b-schema-shape-check.sql"
```

- ✅ 通过：表格里 15 行 `verdict` **全部**是 `pass`，末尾出现 `NOTICE: P6b GATE PASS: 15/15 全部符合`
- ❌ 任一行是 `FAIL-missing` / `FAIL-type-mismatch`：命令会以非零码退出并打印 `P6b GATE FAIL`。**停止，销毁卷重来**（`docker compose down -v` 后回 P6），**不得**往下插数据

（这段 SQL 与它的判别力已于 2026-08-24 在本机真 PostgreSQL 上验过：15/15 通过、退出码 0；故意删掉一条约束后退出码变 3 并打印 `P6b GATE FAIL: 1 条不符`。）

---

## P7 · 把 3 个训练组压缩包放到 NAS，并**重算指纹**

**执行者：Claude**

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
ssh $NAS "cd $DIR && docker compose build" 2>&1 | tail -5
```

- ✅ 通过：出现 `Built`，且**没有** `failed to solve`

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
ssh $NAS "docker exec kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -c \"DELETE FROM training_sets;\" -c \"DO \\\$\\\$ DECLARE n int; BEGIN SELECT count(*) INTO n FROM training_sets; IF n <> 0 THEN RAISE EXCEPTION 'P10 GATE FAIL: 表里还有 % 行', n; END IF; RAISE NOTICE 'P10 GATE PASS: 表已清空'; END \\\$\\\$;\""
```

- ✅ 通过：打印 `P10 GATE PASS: 表已清空`
- ❌ 非零退出：**停止**，不得往下插真数据

---

## P11 · 写入 3 行真数据

**执行者：Claude**

```
ssh $NAS "cd $DIR && docker exec -i kline-trainer-db-1 psql -v ON_ERROR_STOP=1 -U kline -d kline_trainer -f - < sql/2026-08-24-qmt-nas-p11-insert-training-sets.sql"
```

- ✅ 通过：打印 `P11 GATE PASS: 3 行、全 unsent、file_path 全为容器内路径`，随后列出 3 行，`content_hash` 依次是 `851f9444` / `32892a5f` / `150d8d6c`

（这段 SQL 与它的自校验已于 2026-08-24 在本机真 PostgreSQL 上跑通。）

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
ssh $NAS "docker exec tailscale tailscale serve --bg --https=443 http://127.0.0.1:8010"
```

**判据一 —— 配置里不得含 funnel**：

```
ssh $NAS "docker exec tailscale tailscale serve status"
```

- ✅ 通过：显示把 443 反代到 `http://127.0.0.1:8010`，且输出里**没有** `funnel` 字样

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

（该脚本是**无条件**更新，重复执行安全；已在本机验过幂等，也验过「只改状态不清租约列」会被数据库的完整性约束拒绝。）

**设备侧**：手机上**长按图标 → 删除 App**，然后回到 P13 重装。

⚠️ **次序**：复位期间端点必须保持**关闭**（先做 P16 再复位）。复位后重新开始时才由 P12 重新打开。理由：复位把 3 行退回「未发送」，此时任何 tailnet 里的设备（或手机上一个残留的 App 进程）都能把库存预占掉，直接毁掉下一次验收。

---

## P16 · 关闭对外端点（**每一条路径都必须做，不只是成功路径**）

**执行者：Claude**

```
ssh $NAS "docker exec tailscale tailscale serve reset"
```

```
ssh $NAS "docker exec tailscale tailscale serve status"
```

- ✅ 通过：输出**恰好**是 `No serve config`

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
