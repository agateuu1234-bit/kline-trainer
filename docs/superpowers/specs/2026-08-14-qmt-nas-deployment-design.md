# QMT「A 方案 · NAS 版」部署设计（spec）

> 日期：2026-08-14 · 状态：待 user 评审 → writing-plans
> 目标：把后端部署到飞牛 NAS，让 iPhone 真机经 Tailscale HTTPS 完整跑通
> reserve → download → confirm，拉下 3 个用**真实 QMT 数据**生成的训练片段。

---

## §1 目标与判绿标准

本次交付**同时满足下列四条才算成**（缺一不算）：

| 编号 | 目标 | 权威判据 |
|---|---|---|
| G1 | 后端跑在 NAS 上，连**真 PostgreSQL**（不是 InMemory 假件） | `GET /health` 返回 `repository == "asyncpg"`（快速前置检查）**且** G3 成立（决定性证据，见 §9.1） |
| G2 | iPhone 经「设置 → 离线缓存下载」填 3，真的拉下 3 个 zip | 面板状态行显示 3 个成功；本地缓存出现 3 个训练组 |
| G3 | 库里那 3 行 `training_sets.status` 从 `unsent` 变 `sent` | 在 NAS 的 PG 里查这 3 行，`status` 全为 `sent` |
| G4 | App 里看得到这 3 个训练组、能进去真的画出 K 线 | 真机目视：训练组列表 3 条，任选一条进去有蜡烛渲染 |

**禁述**（本 spec 及后续所有文档）：「pilot 已完成」「100 股已出货」「真实数据接入完成」。本次只搬 3 个片段做端到端链路验收，不代表数据接入闭合。

---

## §2 已实测事实清单

⚠️ 本节每条都是 **2026-08-14 本会话亲测**，不是转述文档。后续 plan / 实施**不得**在未复测的情况下推翻，但**可以**复测后更新。

### §2.1 仓库侧（Mac，`main @ 20f615a`）

| 事实 | 怎么测的 |
|---|---|
| `app/main.py` 读的环境变量名是 **`DATABASE_URL`**；不设则回落 `InMemoryLeaseRepository` | 读 `backend/app/main.py:16-22` |
| `backend/.env.example` 定义的却是 **`DB_URL`** —— **名字对不上，是个真 bug** | 读 `backend/.env.example:6` |
| `backend/docker-compose.yml` **只有 `db` 一个服务**，已绑 `${DB_BIND_HOST:-127.0.0.1}:5433:5432` | 读全文 |
| `backend/requirements.txt` 含 `pandas-ta==0.3.14b1`（安装陷阱），API 运行只需 fastapi / uvicorn / asyncpg | 读全文 + 读 `app/*.py` 的 import |
| `/health` **不在** `openapi.yaml` 里（该文件恰好 3 条 path，由 `test_openapi.py::test_three_endpoints_present` 断言） | `grep -n health backend/openapi.yaml` 无输出 |
| `backend/tests/test_health.py` 断言 `response.json() == {"status": "ok"}` **精确相等** → 给 `/health` 加字段会让它变红 | 读全文 |
| 生产环境构造 `AppConfig(...)` 的地方**有且仅有一处**：`ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift:16`；其余 4 处全在测试里 | `grep -rn 'AppConfig(' ios --include='*.swift'`，5 处逐个打开确认 |
| `AppContainerTests` / `AppContainerDebugSeedTests` **直接构造** `AppConfig`，不经任何 resolver → 引入 resolver **不会**让它们变红 | 读 `AppContainerTests.swift:18,29,39` + `AppContainerDebugSeedTests.swift:15` |
| 仓库现有源码守卫用 `#filePath` + 逐级 `deletingLastPathComponent()` 定位源文件 → 可以走到包外的 `ios/KlineTrainer/` | 读 `DrawingStylePanelSourceGuardTests.swift:12-14` |
| `AsyncpgLeaseRepository.get_file_path` 真正执行的 SQL 是 `SELECT file_path FROM training_sets WHERE id = $1`；`reserve_meta` 的 `filename` 由 `file_path.rsplit("/", 1)[-1]` 派生 | 读 `backend/app/lease_repo.py:139-162` |
| `training_sets` 的 DDL：`file_path TEXT NOT NULL`、`content_hash CHAR(8) NOT NULL` 且 `CHECK (content_hash ~ '^[0-9a-f]{8}$')` | 读 `backend/sql/schema.sql:69-99` |
| App 侧 `DownloadAcceptanceRunner` 用 `meta.contentHash` 做 **CRC32** 完整性校验；`TRAINING_SET_SCHEMA_VERSION = 1` | 读 `DownloadAcceptanceRunner.swift:14,68,81` |
| 与并行会话**零文件重叠**：`qmt-4a2b-s3` 当前只有一份 plan 文档；`drawing-default-persist` / `drawing-autoselect` 改的是 `Drawing/*`、`AppState.swift`、`UI/DrawingStyleParams.swift`，都不碰 `KlineTrainerApp.swift` / `AppConfig.swift` | `git -C <worktree> diff --name-only origin/main...HEAD` 三个 worktree 逐个跑 |

### §2.2 数据侧（Mac `qmt-trial` 容器）

| 事实 | 怎么测的 |
|---|---|
| `kline_trial` 库 4 张表：`klines`(66356 行) / `stocks` / `stock_coverage` / `training_sets`(3 行) | `docker exec qmt-trial psql -U postgres -d kline_trial -c "\dt"` + `count(*)` |
| 3 行全 `status=unsent`、`schema_version=1`、`stock_name` 与 `stock_code` 同值（真实数据没带中文名） | `SELECT ... FROM training_sets ORDER BY id` |
| 3 行 `file_path` 是 **Mac 绝对路径** `/Users/maziming/qmt_trial_out/*.zip` | 同上 |
| 库里 `content_hash` 与磁盘 zip 的真实 CRC32 **逐个吻合**：`851f9444` / `32892a5f` / `150d8d6c` | `python3 -c "zlib.crc32(...)"` 对三个 zip 各算一遍，与查询结果对照 |
| zip 内是单个 `.db`，`PRAGMA user_version = 1`，表 `meta` + `klines`，六周期齐全（`3m` 12870 / `15m` 2694 / `60m` 786 / `daily` 309 / `weekly` 154 / `monthly` 422） | 解压到 /tmp 后 `sqlite3 <db> "pragma user_version; .tables; select period,count(*) ..."` |

### §2.3 NAS 侧（192.168.5.229）

| 事实 | 怎么测的 |
|---|---|
| Debian 12 bookworm / 6.12.18-trim / x86_64；Docker 28.5.2 + compose v2.40.3 | ssh + `uname` / `docker --version` |
| `agate1234` 在 `docker` 组 → 跑 docker **不需要 sudo** | `id -nG` → `Users docker Administrators` |
| 8010 / 8443 / 5433 三个端口**当前空闲** | `ss -lntp | grep -E ':8010|:8443|:5433'` 无输出 |
| 现有容器只有 `tailscale`、`iyuuplus`；现有 compose 项目只有 `iyuuplus`、`redroid` | `docker ps` + `docker compose ls -a` |
| NAS 到 PyPI 可达（HTTP 200，1.9s）、到 Docker Hub registry 可达（401 = 需 token，正常） → **镜像可在 NAS 本地构建** | `curl -o /dev/null -w '%{http_code}'` 各一次 |
| 公网出口 IP = `202.156.27.151`（新加坡） | `curl https://api.ipify.org` |
| `/vol1` 3.7T 用 7%；用户目录 `/vol1/1000/agate1234` 可写 | `df -h` + `touch` 写测试 |
| ⚠️ NAS 上有 2026-04 遗留镜像 `backend-api:latest` 和旧目录 `klinetrainer` / `Kline Trainer` / `kline_generator`（四月的老实验，与本仓无关，**别碰也别混淆**） | `docker images` + `ls /vol1/1000/agate1234` |

### §2.4 网络侧（⚠️ 决定了 §4-D1）

| 事实 | 怎么测的 |
|---|---|
| 局域网内**所有未知域名都被 fake-IP 化**，且逐个递增：`example.com`→`198.18.176.30`、`zzz-not-a-real-domain-91237.com`→`.31`、`test123.176660067.dynv6.net`→`.32`、`nas-test.176660067.dynv6.net`→`.33` | `dig @192.168.5.1 <各域名> A` |
| **换 DNS 服务器绕不过去** —— 直接查 `@1.1.1.1` / `@223.5.5.5` 拿到的仍是同样的 fake-IP → 是**网关层拦 53 端口**，不是本机设置。手机改 Wi-Fi DNS 同样无效 | `dig @1.1.1.1 example.com` / `dig @223.5.5.5 example.com` |
| 唯一例外：`176660067.dynv6.net`（apex）返回真实公网 `58.35.80.98` → 它被单独加进了代理白名单，**子域名没有** | `dig @192.168.5.1 176660067.dynv6.net A` |
| DoH 侧证实 `176660067.dynv6.net` 这个 zone 已委派给 `ns1/ns2/ns3.dynv6.com`，但 apex 和 `kline.*` 的 A/AAAA 均 **NXDOMAIN**（Status 3） | `curl 'https://1.1.1.1/dns-query?name=...&type=A|NS|SOA'` |
| NAS 的 tailscale 容器：`network_mode=host`、`BackendState=Running`、`Self.Online=true`、`TUN=false`（userspace 模式）、DNS 名 `fnos.tail9dc815.ts.net` | `docker inspect` + `tailscale status --json` |
| Mac 上 `dig fnos.tail9dc815.ts.net` → `100.88.157.17` **正确**（由 tailscaled 的 100.100.100.100 应答，完全绕开网关 DNS 劫持） | `dig +short` |
| Mac ping NAS 的 tailscale IP 通，最快 **8.4ms**（直连，非 DERP 中继） | `ping -c 2 100.88.157.17` |
| iPhone (`iphone-15-pro-max`, `100.69.198.70`) 已是 tailnet 成员，仅 7 天未上线 | `tailscale status` |
| ⚠️ 该 tailnet **尚未开启 HTTPS 证书**（`CertDomains: None`）；user 具备 `is-owner` / `is-admin` 能力 → admin console 一个开关即可 | `tailscale status --json` 取 `CertDomains` / `Self.Capabilities` |
| NAS 上 `tailscale serve` 当前无配置（`No serve config`） | `tailscale serve status` |

---

## §3 架构总览

```
iPhone (Tailscale App 开启)
   │  https://fnos.tail9dc815.ts.net/…
   │  ↑ Tailscale 自动签发的 Let's Encrypt 证书（iOS 默认信任）
   │  ↑ 流量在 WireGuard 隧道内 → 网关透明代理够不着
   ▼
NAS 192.168.5.229 · tailscaled（host 网络，userspace 模式）
   │  tailscale serve --https=443 → http://127.0.0.1:8010
   ▼
docker compose 项目 kline-trainer
   ├── api  (FastAPI + uvicorn)  端口 127.0.0.1:8010 → 容器 8000
   │     ├── DATABASE_URL → db:5432（compose 内网，不经宿主端口）
   │     └── 只读挂载 <宿主 zip 目录> → /data/training-sets:ro
   └── db   (postgres:15.12)     端口 127.0.0.1:5433 → 容器 5432
         └── training_sets 3 行，file_path = /data/training-sets/<name>.zip
```

**数据流（一次成功下载）**

1. App `reserveTrainingSets(count: 3)` → `GET /training-sets/meta?count=3`
   → PG 里 3 行置 `reserved` + 写 lease 三列 → 返回 `lease_id` + 3 条 meta。
2. 对每条 meta：`GET /training-set/{id}/download` → 后端按 `file_path` 从
   `/data/training-sets` 读 zip 字节返回（带 `Content-MD5`）。
3. App 侧：CRC32 校验（对 `meta.content_hash`）→ 解压 → 开 sqlite 验
   `user_version == 1` → 验非空 → 存入缓存。
4. `POST /training-set/{id}/confirm?lease_id=…` → PG 里该行置 `sent`。

---

## §4 关键决策

### D1 · 手机怎么连到后端 → **Tailscale**（user 2026-08-14 拍板）

**选定**：NAS 上 `tailscale serve` 把 `https://fnos.tail9dc815.ts.net` 反代到 `127.0.0.1:8010`。

理由（依据 §2.4 实测）：

1. 网关的透明代理 fake-IP 掉**所有**未知域名，且换 DNS 服务器绕不过去。走 dynv6 子域名会被 fake-IP → 连接丢进新加坡出口 → 打不回内网。要救只能改路由器代理规则，而那份配置不可见、可行性未知。
2. Tailscale 的 MagicDNS 由本机 tailscaled 应答、流量在 WireGuard 隧道内 → **整个绕开**这个变量。
3. 证书由 Tailscale 自动签发，不依赖 Lucky 那份读不出来的加密配置（`.lkcf`）。
4. 待办最少：admin console 开 HTTPS（1 次点击）+ NAS 一条命令 + 手机开 App。
5. 出门也能用，不限局域网。

**明确接受的代价**：手机必须开着 Tailscale App 才能下载。下载完成后**不影响** G4——训练组已落本地缓存，离线可用。

**被否方案 · dynv6 子域名 + Lucky 反代**：唯一优势是「更像将来上云的形态」。但将来上云是真域名 + 公网 + 真 LE 证书，与今天在内网绕劫持不是同一个问题。保留为后备：**它与本设计零冲突**——`backendBaseURL` 只是环境变量里的一个字符串，换条路不改任何代码。

### D2 · 后端怎么跑 → **容器 + docker compose**

**选定**：在现有 `backend/docker-compose.yml` 里**新增** `api` 服务，与既有 `db` 服务同项目。

理由：user 已定「以后要原样搬云服务器」——compose 文件搬过去改 `.env` 即可；systemd unit 是 Debian 特有的，搬云要重写。且 NAS 上跑 docker 不需要 sudo，systemd 反而需要。

**遵守 `project_backend_nas_now_server_later`（不许写死任一边假设）**：

- zip 在**容器内**的挂载点固定为 `/data/training-sets`；宿主侧路径由 `.env` 的一个变量决定。
- `training_sets.file_path` 存**容器内路径**，宿主目录怎么变都不用改 DB（见 D3）。
- compose 里不出现任何 NAS 特有路径 / fnOS 特有假设；`/vol1/...` 只出现在**部署 runbook**（非仓库代码）里。

**⚠️ 镜像名撞车防护**：compose 默认用目录名做项目名 → 从 `backend/` 跑会生成 `backend-api:latest`，而 NAS 上已有一个 2026-04 的同名遗留镜像。故 compose 文件必须带**显式项目名** `kline-trainer`，产出 `kline-trainer-api`。

**⚠️ 依赖裁剪**：API 镜像只装 `fastapi` / `uvicorn` / `asyncpg`，**不装** `pandas-ta`（后者是数据导入脚本用的，且是已知安装陷阱）。为此新增 `backend/requirements-api.txt`，并配一条一致性测试防 pin 漂移（§5-T1）。

### D3 · 数据怎么搬 + `file_path` 怎么改

**选定**：

1. **schema 从仓库权威 DDL 建**，不从 Mac dump —— NAS 的 PG 起来后跑 `backend/sql/schema.sql`。避免把 Mac 上可能的偶发漂移搬过去。
   **「schema.sql 已含 migration 0004」这一断言本会话已复核**（不是照抄它的头部注释）：逐条比对 `migrations/0004/forward.sql` 的三项目标态，schema.sql 全部具备——klines OHLC 为 `DOUBLE PRECISION` + `ck_klines_price_finite_positive` + `ck_klines_price_ordering`；`training_sets.file_path` 为 `TEXT`；`stock_coverage` 表带全部三条 CHECK。且两侧各自的属性已有既存 CI 测试逐条锁定（`test_schema.py::test_klines_ohlc_are_double_precision` / `test_training_sets_file_path_is_text` / `test_stock_coverage_has_integrity_checks` / `test_klines_has_price_integrity_checks` 等，与 `test_migrations.py` 的对应条目一一对应）。
   ⚠️ 残留精度：既存测试锁的是**两侧各自的属性**，没有一条断言「两条路径产出的形状等价」。本次不补这条测试（属 migration-runner 治理范畴，`docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md` §residual 已明确 defer）。
2. **只搬 `training_sets` 那 3 行**。Mac 库里 66356 行 `klines` 对 App 下载链路**完全无用**——App 只要 zip；klines 是生成训练组时用的，那步已经做完（依据 §2.2 + §3 数据流）。
3. 用 **3 条手写 INSERT**，不用 `pg_dump`：数据量极小、可读、能在 INSERT 时**直接写入正确的容器内 `file_path`**，一步到位，无需事后 UPDATE，也避开 dump 带 sequence 的麻烦。
4. **`file_path` = `/data/training-sets/<原文件名>.zip`**（容器内绝对路径）。
   - 已核到落盘边界：DDL 是 `file_path TEXT NOT NULL`（无格式约束），真正执行的读取 SQL 是 `SELECT file_path FROM training_sets WHERE id = $1`，`filename` 由 `rsplit("/", 1)[-1]` 派生 → Linux 绝对路径完全适配（§2.1）。
5. **zip 用 scp 传，传完必须在 NAS 上重算 CRC32 比对** `851f9444` / `32892a5f` / `150d8d6c`。传坏了的话失败点会落在 App 的完整性校验，症状很难认。

### D4 · `backendBaseURL` 环境变量的形状

**选定**：

- 变量名 **`KLINE_BACKEND_BASE_URL`**（与既有 `KLINE_SEED_FIXTURE` 同前缀）。
- **判定逻辑下沉到 `KlineTrainerPersistence` 包**，做成纯函数（收 `[String: String]` 字典 + fallback URL，返回 URL），**不直接读 `ProcessInfo`**。
  - 理由：`KlineTrainerApp.swift` 在 app target 里，**host 测试套件根本编译不到它**（对齐 `feedback_uikit_gated_evidence_traps` 同族陷阱）。逻辑写在那儿 = 零测试覆盖、无法变异验证。
  - 组合根只剩一行：把 `ProcessInfo.processInfo.environment` 传进去。
- **`#if DEBUG` 只包组合根的调用点**，纯函数本身不加条件编译（保证任何配置下都可测）。Release 二进制不读环境变量。
- **Release 怎么配（Info.plist / xcconfig）本次不做** —— user 已定，属正式部署决定。
- **ATS 不动** —— 走的是有可信证书的 https（§2.1 已核工程为 `GENERATE_INFOPLIST_FILE=YES`、无 Info.plist 文件、pbxproj 零 ATS 键，真要加例外并不容易，幸好不用）。

**「所有 X 都走 Y」的出口表**（对齐 `feedback_spec_all_paths_must_reach_the_chokepoint`）：
生产环境构造 `AppConfig` 的出口**枚举完毕、恰好 1 个**——`KlineTrainerApp.swift:16`（§2.1 实测）。其余 4 处全在测试文件里，测试直接传字面 URL 是**有意的**（它们测的不是 URL 来源），不算漏网。故「生产的 backendBaseURL 全部经过 resolver」这一断言成立，且由 §6-R2 的源码守卫钉住。

### D5 · `/health` 暴露当前 repository 种类

**选定**：`GET /health` 响应新增 `repository` 字段，取值恰好为 `"asyncpg"` 或 `"inmemory"`。

理由：`main.py` 在 `DATABASE_URL` 缺失时**静默**回落 InMemory —— 这正是本仓反复踩的假绿家族（`feedback_all_reject_suite_masks_always_throwing_guard` 同型）。手机拉到假数据时表面一切正常。加这个字段把「有没有走 asyncpg」从不可验证变成一条 curl。

- `/health` **不在** `openapi.yaml` 里（§2.1 实测，该文件恰好 3 条 path 且被测试锁死）→ 加字段**不触碰契约冻结文件**。
- `status: "ok"` 字段保持不变，不破坏既有消费者。
- 字段必须**请求时读取**当前装配的 repository（lifespan 会在 startup 把它换掉），不能在 import 时定死。
- 取值是**固定的两个字面量**，不是类名派生（否则会得到 `asyncpgleaserepository` 这种）。
- `_default_repo` 未设的第三态在组合根不可达（模块 import 即设 InMemory）→ **不设第三个取值、不写不可达分支**（对齐 CLAUDE.md §2）。

**被否的更强方案**：加 `KLINE_REQUIRE_DB=1` 让缺 DSN 时拒绝启动。多一份配置面，而 `/health` 字段已足够支撑验收，YAGNI。

---

## §5 交付切片一：后端容器化

**范围**：`backend/Dockerfile`（新增）、`backend/requirements-api.txt`（新增）、`backend/docker-compose.yml`（改）、`backend/.env.example`（改）、`backend/app/main.py`（改 `/health`）、对应测试、验收清单。**零 App 改动。**

### §5.1 契约

| 编号 | 契约 |
|---|---|
| C1-1 | `requirements-api.txt` 的包集合**恰好**是 `{fastapi, uvicorn, asyncpg}`，每个都是精确 pin（无 `>=` / `<` / `~=`），且 pin 值与 `requirements.txt` 中同名包**完全一致** |
| C1-2 | `Dockerfile` 的 base image 是**精确 patch 版本 tag**（不得含 `latest`，不得用浮动的 `3.11-slim`），且安装的是 `requirements-api.txt` 而非 `requirements.txt` |
| C1-3 | compose 含顶层显式项目名 `kline-trainer`；新增 `api` 服务，`depends_on` 含 `db` |
| C1-4 | `api` 的宿主端口绑定默认值是 **`127.0.0.1`**（形如 `${API_BIND_HOST:-127.0.0.1}`），不得默认对 LAN 开放 |
| C1-5 | 训练组目录挂载进 `api` 容器时是**只读**（`:ro`），容器内路径固定为 `/data/training-sets` |
| C1-6 | `.env.example` 里定义的 DSN 变量名与 `app/main.py` 实际读取的名字**一致**（当前是 `DB_URL` vs `DATABASE_URL`，不一致——本切片修掉） |
| C1-7 | `GET /health` 返回 `{"status": "ok", "repository": <"asyncpg" \| "inmemory">}`，`repository` 反映**请求时**装配的 repository |

### §5.2 测试判据（每条都须变异验证）

| 编号 | 判据 | 变异（中和后应变红的**具名**测试） |
|---|---|---|
| T1-1 | **正向档**：当前树上 `requirements-api.txt` 每个包在 `requirements.txt` 里存在且 pin 相同 → 绿 | — |
| T1-2 | 改掉 `requirements-api.txt` 任一 pin → T1-1 红 | 改 pin |
| T1-3 | 反向：改掉 `requirements.txt` 里同名包的 pin → T1-1 红 | 改另一侧的 pin（两个方向都要验） |
| T1-4 | 包集合恰好 `{fastapi, uvicorn, asyncpg}` | 往 `requirements-api.txt` 加一行 `pandas-ta` → 红 |
| T1-5 | 全 pin 无 range | 把某行改成 `fastapi>=0.115` → 红 |
| T2-1 | **结构提取**：从 `app/main.py` 解析出 lifespan 实际读取的环境变量名（AST 提取，**不是**测试里再硬写一遍字面量——否则恒真），断言 `.env.example` 存在同名 `KEY=` 行 | — |
| T2-2 | 把 `.env.example` 的名字改回 `DB_URL` → T2-1 红 | 改 env 侧 |
| T2-3 | 把 `main.py` 改成读别的名字 → T2-1 红 | 改代码侧（两个方向都要验） |
| T3-1 | **正向档**：无 `DATABASE_URL` 起 app，`GET /health` → `repository == "inmemory"` | — |
| T3-2 | **正向档**：装配 `AsyncpgLeaseRepository`（注入 fake pool，不需要真 PG），`GET /health` → `repository == "asyncpg"` | — |
| T3-3 | `status` 字段仍为 `"ok"` | 删掉 `status` → 红 |
| T3-4 | 中和 `/health` 的 repository 判定（写死一个值）→ T3-1 或 T3-2 其中**具名的那一条**变红 | — |
| T4-1 | 用 pyyaml 解析 compose 做结构断言：`api` 服务存在、`depends_on` 含 `db`、顶层 `name == "kline-trainer"` | 删 `name` → 红 |
| T4-2 | `api` 端口绑定默认值是 `127.0.0.1` | 改成 `0.0.0.0` → 红 |
| T4-3 | 训练组挂载带 `:ro` 且容器侧是 `/data/training-sets` | 删 `:ro` → 红 |
| T5-1 | Dockerfile base image 是精确 patch tag | 改成 `python:3.11-slim` → 红 |
| T5-2 | Dockerfile 装的是 `requirements-api.txt` | 改成 `requirements.txt` → 红 |

**已知会变红的既有测试**：`backend/tests/test_health.py::test_health_returns_200`（断言 `== {"status": "ok"}` 精确相等）。这是**预期中的 TDD 先红**，随 C1-7 一起更新。

**CI 约束**（对齐 `feedback_test_imports_must_not_need_optional_deps`）：新增测试**不得**在模块顶层 import CI 未安装的包。`requirements-test.txt` 有 `pyyaml`、`fastapi`、`httpx`，**没有 asyncpg** → T3-2 必须用注入的 fake pool，不得 import asyncpg。

### §5.3 明确不做

- **不部署 B4 调度器**（`app/scheduler_main.py`）：租约过期后重新预占是 `reserve_meta` 自己做的（依据 `lease_repo.py:120-128` 的 `OR (status='reserved' AND lease_expires_at <= $1)`），不依赖调度器。
- 不加认证 / 限流 / TLS 终结到容器内（TLS 由 `tailscale serve` 终结）。
- 不改 `openapi.yaml`、`backend/sql/`、`tests/contract-fixtures/`。

---

## §6 交付切片二：App 后端地址可配

**范围**：`ios/Contracts/Sources/KlineTrainerPersistence/AppConfig.swift`（加纯函数）、新增测试、`ios/KlineTrainer/KlineTrainer/KlineTrainerApp.swift`（一行接线 + 删 TODO 注释）、验收清单。**零后端改动。**

### §6.1 契约

`AppConfig` 新增一个静态纯函数，输入 `(environment: [String: String], fallback: URL)`，输出 `URL`：

| 输入 | 输出 |
|---|---|
| `KLINE_BACKEND_BASE_URL` 缺失 | `fallback` |
| 值为空串 | `fallback` |
| 值只含空白 | `fallback` |
| 值不是合法 URL | `fallback` |
| 值的 scheme 不在 `{http, https}` | `fallback` |
| 值无 host | `fallback` |
| 值是合法 `https://…` | 该 URL |
| 值是合法 `http://…` | 该 URL |

组合根：`backendBaseURL` 实参改为该函数的调用，`#if DEBUG` 包裹；非 DEBUG 走原有字面量默认值。

### §6.2 测试判据（每条都须变异验证）

| 编号 | 判据 | 性质 |
|---|---|---|
| R1-1 | 合法 `https://…` → 采用 | **正向档** |
| R1-2 | 合法 `http://…` → 采用 | **正向档** |
| R1-3 | key 缺失 → fallback | 拒绝档 |
| R1-4 | 空串 → fallback | 拒绝档 |
| R1-5 | 全空白 → fallback | 拒绝档 |
| R1-6 | 非法 URL 文本 → fallback | 拒绝档 |
| R1-7 | scheme 为 `file` / `ftp` → fallback | 拒绝档 |
| R1-8 | 无 host（如 `https:///path`）→ fallback | 拒绝档 |
| R1-9 | base 带结尾 `/` 与不带时，拼出的 `training-sets/meta` URL 一致且正确 | 形状锁 |
| R2-1 | 源码守卫：组合根的 `backendBaseURL:` 实参是该函数调用，**不是**字面量 URL | 结构断言 |
| R2-2 | 源码守卫：该调用被 `#if DEBUG` 包裹 | 结构断言 |
| R3-1 | `AppContainerTests` / `AppContainerDebugSeedTests` 保持绿（它们不经 resolver，§2.1 已核） | 回归 |

**判别力要求**（对齐 `feedback_mutation_must_target_the_exact_predicate`）：R1-3…R1-8 是一整族「应该回落」的档，**必须**配 R1-1 / R1-2 两条正向档，否则一个「无条件返回 fallback」的空实现会让整族全绿。变异时须逐条中和**对应的那一条**判据，并记录**红的是具名的哪一条**。

**源码守卫的文本纪律**（对齐 `feedback_source_guard_text_source_discipline`）：R2-1 / R2-2 的结构断言须**剥注释**后再判（当前该行尾部有 `// TODO(NAS) PR11-R1：部署后替换` 注释，改完会删，但判据不得依赖注释的存在或消失）。

### §6.3 明确不做

- 不做 Release 构建的配置通道（Info.plist / xcconfig）。
- 不改 ATS / pbxproj。
- 不动 `DefaultAPIClient` 的任何逻辑。

---

## §7 部署与数据迁移（非 PR，写成 runbook）

以下是**运维动作**，不进仓库代码，由 writing-plans 阶段产出一份非程序员可执行的配方（一行一条命令、绝对路径、无中文混入命令行）。此处只定契约与次序。

| 步 | 动作 | 执行者 | 判据 |
|---|---|---|---|
| P1 | Tailscale admin console → DNS → 启用 HTTPS 证书 | **user**（网页） | NAS 上 `tailscale status --json` 的 `CertDomains` 非 None |
| P2 | 手机打开 Tailscale App 并连上 | **user** | `tailscale status` 里 `iphone-15-pro-max` 不再 offline |
| P3 | NAS 建部署目录（**新目录**，避开四月遗留的 `klinetrainer` / `Kline Trainer`） | Claude 可跑 | 目录存在且可写 |
| P4 | 把 `backend/` 需要的文件同步到 NAS 部署目录 | Claude 可跑 | 文件校验一致 |
| P5 | 写 `.env`（真密码，不入库；`DATABASE_URL` 指向 compose 内网 `db:5432`） | Claude 可跑 | `.env` 不进 git |
| P6 | `docker compose up -d db`，等就绪后灌 `backend/sql/schema.sql` | Claude 可跑 | `\dt` 出 4 张表 |
| P7 | scp 3 个 zip 到宿主训练组目录 | Claude 可跑 | **NAS 上重算 CRC32 = `851f9444` / `32892a5f` / `150d8d6c`** |
| P8 | 3 条 INSERT 写 `training_sets`，`file_path` 用 `/data/training-sets/…` | Claude 可跑 | 3 行 `status=unsent`，`content_hash` 与 P7 一致 |
| P9 | `docker compose up -d api`（在 NAS 上构建镜像） | Claude 可跑 | `curl 127.0.0.1:8010/health` → `repository == "asyncpg"` |
| P10 | `tailscale serve --bg --https=443 http://127.0.0.1:8010` | Claude 可跑 | Mac 上 `curl https://fnos.tail9dc815.ts.net/health` 成功且证书可验 |
| P11 | Debug 构建装机 + `devicectl` 带 `KLINE_BACKEND_BASE_URL` 启动 | **user**（需签名，真终端） | App 启动无错 |
| P12 | 走 §9 验收 | **user**（真机目视） | G1–G4 全过 |

**⚠️ P11 的环境变量只在这次 `devicectl` 启动的进程里有效**：之后从桌面图标点开 App 不会带这个变量，后端地址回落到默认值。这**不影响 G4**——训练组已落本地缓存，离线可看可练。

**并行安全**（本次全程遵守）：不碰 `.dev/worktree/qmt-4a2b-s3`；Mac 上只碰 `qmt-trial` 容器，绝不碰 `qmt-pg-r8` / `qmt-pg-r8b`；不动主仓 HEAD，代码从 `origin/main` 切**新** worktree。

---

## §8 错误处理与失败模式

| 失败面 | 症状 | 定位手段 |
|---|---|---|
| `DATABASE_URL` 没生效 → 走了 InMemory | 手机下载「成功」但一个训练组都没有（InMemory 零行 → `sets: []`） | `GET /health` 的 `repository` 字段（D5 就是为这个加的） |
| zip 传输损坏 | App 侧 CRC32 校验失败，状态行报失败 | P7 的 CRC32 比对（前置拦截） |
| `file_path` 写成了宿主路径 | download 一律 404 | 容器内 `ls /data/training-sets` 与 DB 里的值对照 |
| 挂载没配 / 配错 | 同上 404 | 同上 |
| Tailscale 手机端没开 | App 报网络错误 | `tailscale status` 看 iPhone 在不在线 |
| tailnet HTTPS 没开 | `tailscale serve --https` 报错或证书不可验 | P1 的判据 |
| 租约 10 分钟过期后才 confirm | confirm 返 409 `lease_expired`，行退回 `unsent` | 库里查 `status` + `lease_expires_at` |
| schema_version 不为 1 | App 侧 `openAndVerify` 失败 | §2.2 已实测为 1，理论上不该发生 |

---

## §9 验收

### §9.1 四条目标的权威判据

- **G1**：`curl https://fnos.tail9dc815.ts.net/health` → `repository == "asyncpg"`。
  ⚠️ 这是**快速前置检查**，不是决定性证据。决定性证据是 **G3**：InMemory repo 里零行，若真走了 InMemory，`reserve` 会返回 `sets: []`、手机一个 zip 都拉不到、库里三行也不会变 `sent`。G2+G3 同时成立即排除了假件路径。
- **G2**：面板状态行显示 3 个成功 + 本地训练组列表出现 3 条。
- **G3**：在 NAS 的 PG 里查那 3 行，`status` 全为 `sent`。
- **G4**：真机目视，任选一条进去有蜡烛渲染。

### §9.2 顺带收掉仓库里躺着没跑过的清单

`docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md` 的 **§NAS 真 PG 烟测**（NAS-A.1～A.4、NAS-B.1～B.4，共 8 条）本次一并执行。

- NAS-A.3 需要**等 10 分钟 + 1 秒**（租约 TTL）。这条耗时长但必须真跑，不得推演。
- 执行时用**另建的临时测试行**，不要用那 3 行真数据（避免把它们提前打成 `sent` 影响 G3）。

### §9.3 清单形态

两个切片各自附一份验收清单，**中文、非程序员可执行、动作 / 预期 / 通过条件三列**，禁用 `.claude/workflow-rules.json` 里列的禁止措辞。部署 + 真机部分单独一份。

---

## §10 明确不属于本次范围

- 真实数据试跑挖出的两个生产缺陷（`export_log.period` 写 `1d` 而代码只认 `daily` 导致 5608 行日线被静默跳过；`status='empty'` 行让 `parse_export_log` 整份崩掉）→ 归 4b/4c，**本次不修**。
- 4b `qmt_fetch.py`、4c 编排 / 报告 / 出货凭据 → 不碰。
- Release 构建的后端地址配置通道。
- dynv6 子域名 + Lucky 反代（保留为后备，零代码耦合）。
- B4 调度器部署。
- 认证 / 授权 / 限流。

---

## §11 风险与残留

| 编号 | 风险 | 缓解 |
|---|---|---|
| R1 | tailnet 开 HTTPS 是 user 在网页做的一次性动作，我无法代劳也无法预验 | P1 定义了可机械核实的判据（`CertDomains` 非 None）；未过则整条链路不往下走 |
| R2 | `tailscale serve` 在 `TUN=false`（userspace）模式下的行为未实测 | 它是应用层代理、不依赖 TUN，但 **P10 必须真跑真验**，不得按推演判过 |
| R3 | ~~`schema.sql` 是否真含 migration 0004~~ **本会话已复核，风险出清**（见 D3 第 1 条） | 残留精度：无「两条建库路径形状等价」的测试，属已 defer 的 migration-runner 治理范畴 |
| R4 | 镜像在 NAS 上构建依赖 PyPI / Docker Hub 可达 | §2.3 已实测可达；若构建时失败，退路是 Mac 上 `--platform linux/amd64` 构建后 `docker save \| ssh docker load` |
| R5 | `stock_name` 与 `stock_code` 同值 → App 里训练组显示的是代码不是中文名 | **已知且接受**，是真实 QMT 数据本身没带中文名，非缺陷。不在本次修 |
| R6 | 手机端环境变量只在 `devicectl` 启动的那次进程有效 | §7 已明写；不影响 G4 |
| R7 | 部署 runbook 里的命令若在 worktree 里跑会踩 `.venv` 不存在的坑 | 配方一律用绝对路径变量、一行一条命令；不在 worktree 里假设 `.venv` |

---

## §12 流程与评审

- 本 spec 定稿后 → `superpowers:writing-plans` 出两份实施计划（每切片一份）。
- 实施走 TDD：**先看红再实现**；每条新测试**必须变异验证**（中和判据 → 看**具名的那条**变红 → 用 `cp` 复原，⛔ 绝不用 `git checkout <file>`），且由控制者亲跑。
- 收口走 `.claude/scripts/codex-attest.sh --base main --head <分支>` 的 branch-diff，**不许窄化 focus**。拿到 approve 先确认它**真跑了测试**。没真 approve 就如实写 needs-attention / 接受残留 / override，**不得**写「收敛」。
- `git push` / `gh pr create` / `gh pr merge` 全部由 user 在真终端跑。
