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

> 本次交付同时是三条挂了三个 Wave 的既有 residual（**PR11-R1 / W1-R1 / W1-R2**）点名归属的那个「NAS 部署 PR」。逐条处置见 **§13**。

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

### §2.5 2026-08-24 复核增量（基线从 `main @ 20f615a` 推进到 `origin/main @ d38da4b`）

⚠️ 本节每条同样是**亲测**。spec 停在 2026-08-14，其间 main 合入了 #162 / #163 / #164 / #165 / #167 / #169 六个 PR。**§2.1 的 13 条代码事实逐条重验，全部仍然成立**（`git diff --stat 20f615a origin/main -- backend/ ios/` 显示本切片要碰的文件——`app/main.py` / `docker-compose.yml` / `.env.example` / `requirements.txt` / `openapi.yaml` / `sql/schema.sql` / `tests/test_health.py` / 全部 `ios/`——**一个都没被改过**；被改的只有 `qmt_pilot_db.py` / `scripts/verify_pilot_{concurrency,db_lifecycle}.py` / `tests/test_qmt_pilot_db.py` 四个文件）。下面是**有增量**的条目。

**a · C1-6 的消费者枚举写错了（本节唯一一条推翻 spec 原文的）**

用 AST（`os.environ.get(...)` / `os.environ[...]` / `os.getenv(...)` 的字面量键）扫 `backend/` 下**非 tests** 的全部 `.py`，加上「真的 `source` 了 `.env` 的 `.sh`」，实测全集如下：

| 变量名 | 消费者 | 是否该进 `.env.example` |
|---|---|---|
| `DATABASE_URL` | `app/main.py` · `app/scheduler_main.py` · `generate_training_sets.py` · `import_csv.py` | ✅ **要**（本切片补上，就是 C1-6 的修法） |
| `DB_URL` | `scripts/nas-preflight.sh`（必需变量循环） | ✅ 已有，保留 |
| `NAS_HOST` / `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | `scripts/nas-preflight.sh`（同上） | ✅ 已有，保留 |
| `DSN` | `scripts/verify_advisory_lock_reentrancy.py` · `verify_pilot_concurrency.py` · `verify_pilot_db_lifecycle.py` · `verify_pilot_two_phase_create.py` · `verify_qmt_pg_chain.py` · `verify_repeatable_read_snapshot.py`（**6 个**） | ❌ 不进——人工验证脚本，每次在命令行显式传，从不读 `.env` |
| `DSN2` | `verify_pilot_concurrency.py` · `verify_pilot_two_phase_create.py` | ❌ 同上 |
| `QMT_VERIFY_ALLOW_DESTRUCTIVE` | `_pilot_verify_harness.py` · `verify_qmt_pg_chain.py` · `verify_repeatable_read_snapshot.py` | ❌ 同上（破坏性开关，故意要求每次手打） |
| `QMT_VERIFY_ALLOW_REMOTE` | `_pilot_verify_harness.py` | ❌ 同上 |
| `QMT_VERIFY_FORCE_CLEANUP` | `_pilot_verify_harness.py` · `verify_pilot_db_lifecycle.py` | ❌ 同上 |
| `TRAINING_SETS_DIR` | `app/scheduler_main.py` | ❌ 不进——B4 调度器**本次不部署**（§5.3）；将来部署调度器时必须重新归类 |

→ **T2-1 的判据形状因此必须改**（原文的「断言每一个都在 `.env.example` 里有同名 `KEY=` 行」会把上表下半部分全部误判为缺失）。订正后的判据 = **扫描出的全集与「进 `.env.example` 的集合 ∪ 明确不进的集合」精确相等**（两个方向同时断言）。这样既保住「新增一个消费者就变红」的枚举性（T2-5），又不会逼验证脚本的临时开关进部署配置。落地细节归 plan。

**b · 网络与暴露面**

| 事实 | 结论 |
|---|---|
| tailnet **仍未开 HTTPS 证书**（`CertDomains: None`，2026-08-24 实测） | **P1 仍是待办**，仍需 user 在 admin console 点一次 |
| tailnet 仍是 **7 个节点、归属者全为 `agateuu1234@`（同一个 UserID `6137041624589937`）、`ShareeNode` 全为 null** | §11-R8 接受理由的前提 ①② **仍成立**；P11b / P12b 的判据不变 |
| Mac 本机节点名从 `mac-mini` 变成 **`mac-mini-2`**（`100.90.32.87`）；`agatemac-mini` 另有其人且离线 | 只是节点改名，不影响任何判据；**§2.4 的节点清单以本节为准** |
| `fnos` 在线（`100.88.157.17`）；`iphone-15-pro-max` **离线，最后上线 17 天前** | **P2 仍是待办** |
| NAS 上 `tailscale serve status` = `No serve config` | 初始态未变，P16 的判据字面量仍然正确 |

**c · NAS 侧新发现两处遗留物（§2.3 没记，因为当时用的是 `docker ps` 而非 `docker ps -a`）**

| 遗留物 | 为什么要紧 |
|---|---|
| **卷 `backend_pgdata` 与 `backend_training_sets` 已存在**（4 个月前一个叫 `backend` 的 compose 项目留下的） | ⚠️ **这是一颗新的假绿地雷**：compose 默认拿目录名当项目名，若部署目录叫 `backend/` 且没写显式项目名，就会**静默复用 `backend_pgdata` 这个旧卷** → `schema.sql` 全是 `CREATE TABLE IF NOT EXISTS` → **什么都不修却报成功**，正是 R5-F2 描述的失败面。C1-3 的显式项目名 `kline-trainer` 恰好挡住它，但 §4-D2 给的理由只有「镜像重名」，**现在有第二个更严重的理由**。P6 的「全新空卷」判据必须同时排除 `backend_pgdata`。 |
| **容器 `kline-postgres`（exited）绑宿主 `5433`、挂卷 `kline_pgdata`** | 现在停着所以 `5433` 空闲；**部署全程不得启动它**，否则与本项目的 `db` 抢端口。判据：`docker ps -a` 里它必须保持 `Exited`。 |

其余 §2.3 事实复验通过：8010 / 8443 / 5433 三端口空闲；`agate1234` 在 `docker` 组、ssh 免密可用；`/vol1` 3.7T 用 10%；NAS 侧 Docker 28.5.2 + compose v2.40.3。

**d · 数据侧：比 §2.2 记录的更好，`W1-R2` 的证据链未断**

| 事实 | 实测 |
|---|---|
| Mac 上 `qmt-trial` 容器**没有消失**（换机交接单说它没了，是错的），`kline_trial` 库 4 张表完整、`training_sets` **3 行全在且全为 `unsent`** | `docker start qmt-trial` 后 `psql` 逐行查，查完已 `docker stop` 还原 |
| 3 行的权威字段值（P11 的 3 条 INSERT 直接照抄这里，**不必解 NAS 上的 dump**） | 见 §2.5-e |
| Mac 本地 `~/qmt_trial_out/` 三个 zip 仍在，重算 CRC32 = `851f9444` / `150d8d6c` / `32892a5f` | `zlib.crc32` 逐个算 |
| NAS `kline-trainer-handoff-20260814/` 三个 zip 重算 CRC32 **同样三个全对**；`kline_trial_20260814.sql.gz` `gzip -t` 通过 | NAS 上现算 |

→ 「不可再生」的两样东西现在是**本机 + NAS 双份**。P7 的 zip 既可从 Mac scp，也可直接用 NAS 上那份（**判据不变：落到目标目录后必须重算 CRC32 比对**）。

**e · P11 的 3 条 INSERT 的权威字段值（2026-08-24 从 `kline_trial` 库直接读出）**

| id | `stock_code` | `stock_name` | `start_datetime` | `end_datetime` | `schema_version` | `content_hash` | zip 文件名 |
|---|---|---|---|---|---|---|---|
| 1 | `000001.SZ` | `000001.SZ` | `1756656000` | `1777996799` | 1 | `851f9444` | `000001.SZ_1756656000.zip` |
| 2 | `600519.SH` | `600519.SH` | `1762099200` | `1782835199` | 1 | `32892a5f` | `600519.SH_1762099200.zip` |
| 3 | `000001.SZ` | `000001.SZ` | `1762099200` | `1782835199` | 1 | `150d8d6c` | `000001.SZ_1762099200.zip` |

（`stock_name` 与 `stock_code` 同值 = §11-R5 已接受的残留，真实 QMT 数据本身没带中文名。）

**f · 供应链 digest 实测到手（C1-8 / T6-7 的输入）**

| ref | digest | `MediaType` | 覆盖平台 |
|---|---|---|---|
| `postgres:15.12` | `sha256:8f6fbd24a12304d2adc332a2162ee9ff9d6044045a0b07f94d6e53e73125e11c` | OCI image **index** | 含 `linux/amd64` + `linux/arm64/v8` ✅ |
| `python:3.11.14-slim` | `sha256:c8271b1f627d0068857dce5b53e14a9558603b527e46f1f901722f935b786a39` | OCI image **index** | 含 `linux/amd64` + `linux/arm64/v8` ✅ |

（`docker buildx imagetools inspect` 各跑一次，2026-08-24。P4b 部署前仍须**再跑一次**——这两行是写进文件里的值，不是免验凭据。）

**g2 · main 在本次评审期间前进了两个提交（2026-08-24 当日）**

`origin/main` 从 `d38da4b` 推进到 **`a641a0d`**，多了：
- **#171 `a641a0d`**（QMT 4b 切片 S1，共享地基）—— 与本线仍然零文件重叠；
- **#173 `d6eae79`**（修真实 QMT 导出格式的两个生产缺陷）—— ⚠️ **这一条推翻了本 spec §10 与 §13.1 的一处陈述**：那两个「归 4b/4c、本次不修」的缺陷**已经修了**。两处已订正。

本分支已 rebase 到 `a641a0d`；改动文件仍只有本次交付的那 10 个，无冲突。

**g · 并行安全复核**

PR **#171**（`feat/qmt-4b-fetch`，QMT 4b 切片 S1）当前 OPEN，改的是 `backend/qmt_fsroot.py` / `backend/tests/test_qmt_fsroot.py` / 两份文档 —— 与本次两个切片**零文件重叠**；且 `qmt_fsroot.py` **零环境变量读取**，不会扰动 T2-1 的扫描全集。

**h · 工具链约束（写给实施者，踩过才知道）**

本仓 `.claude/settings.json` 对**任何**含 `.env` 字样的 Bash 命令有 deny 规则（`Bash(git show *.env*)` / `Bash(git grep *.env*)` / `Bash(cat **/.env*)` 等）。→ 读写 `backend/.env.example` **必须走 Read / Edit / Write 工具**，不要试图用 `cat` / `sed` / `git show`，也**不得**用 Bash 绕过该规则。

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

**⛔ 硬禁止：`tailscale funnel`**（codex spec-R2 F1）。
`serve` 只对**本 tailnet 内部**暴露；`funnel` 会把同一个端点暴露到**公网**。本 API **零认证**（§10），一旦走 funnel，任何人都能 `GET /training-sets/meta` 预占并下载全部训练组。故：

- 部署只许用 `tailscale serve`；
- P12 的判据里加一条：`tailscale serve status` 的输出**不得含 funnel**；
- 后续任何文档 / runbook / 配方**不得**出现 `tailscale funnel` 字样。

**暴露面的实测边界 + 接受的残留**：本 tailnet 现有 7 个节点（`mac-mini` / `agatemac-mini` / `desktop-cimqfns` / `fnos` / `ipad162` / `iphone-15-pro-max` / `macbook-air`），`tailscale status` 显示**归属者全部是 `agateuu1234@`**，无外部共享节点（§2.4 实测）。因此「任意 tailnet 成员可预占/下载/confirm 全部训练组」这一暴露面的实际范围 = **user 自己的 7 台设备**。本次**接受**该残留（详见 §11-R8），不加认证；但上面的 funnel 禁令是硬门，不属于可接受范围。

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

**补强：`/health` 字段只覆盖「验收那一刻」，不覆盖后续重启**（codex spec-R3 F3）。
P8 的 `/health` 检查只是一个时间点的快照。后来若 `.env` 丢失/被改、或在错误目录跑 `docker compose up`，变量插值会得到**空串** → `os.environ.get("DATABASE_URL")` 返回 `""`（falsy）→ **静默回落 InMemory**，服务照样 `status: ok` 地跑着，只是一行数据都没有。空串比未设更阴险。

**采纳的修法：compose 必需变量语法 `${DATABASE_URL:?…}`（C1-9）**，不是加 `KLINE_REQUIRE_DB` 开关。理由：

- **零生产代码改动** —— `main.py` 的 InMemory 回落保持原样，那本来就是给本地 dev / CI 用的，不该为部署场景改掉它；
- **零新配置开关** —— 不引入一个「本身也会被配错」的旗标；
- **每次 `up` 都拦**，不是只拦一次；
- 实测对**未设**和**空串**都拒，报错信息可读，正常值放行（2026-08-14）。

**被否方案**：`KLINE_REQUIRE_DB=1`。它要改生产代码 + 多一份配置面，而拦截点比 compose 语法更晚（进程起来之后），收益不如上面那条。

---

## §5 交付切片一：后端容器化

**范围**：`backend/Dockerfile`（新增）、`backend/requirements-api.txt`（新增）、`backend/docker-compose.yml`（改：新增 `api` 服务 + 收掉 W1-R1 的 image digest pin）、`backend/.env.example`（改）、`backend/app/main.py`（改 `/health`）、对应测试、验收清单。**零 App 改动。**

### §5.1 契约

| 编号 | 契约 |
|---|---|
| C1-1 | `requirements-api.txt` 的包集合**恰好**是 `{fastapi, uvicorn, asyncpg}`，每个都是精确 pin（无 `>=` / `<` / `~=`），且 pin 值与 `requirements.txt` 中同名包**完全一致** |
| C1-2 | `Dockerfile` 的 base image 是**精确 patch 版本 tag + `@sha256:` digest**（不得含 `latest`，不得用浮动的 `3.11-slim`），且安装的是 `requirements-api.txt` 而非 `requirements.txt` |
| C1-3 | compose 含顶层显式项目名 `kline-trainer`；新增 `api` 服务 |
| C1-3b | **（codex spec-R1 F3）** `db` 服务带 healthcheck；`api` 的 `depends_on` 用 **`condition: service_healthy`** 而非裸 `depends_on: [db]`；`api` 带 `restart: unless-stopped`（与既有 `db` 服务同风格） |
| C1-4 | `api` 的宿主端口绑定默认值是 **`127.0.0.1`**（形如 `${API_BIND_HOST:-127.0.0.1}`），不得默认对 LAN 开放 |
| C1-5 | 训练组目录挂载进 `api` 容器时是**只读**（`:ro`），容器内路径固定为 `/data/training-sets` |
| C1-6 | **（codex spec-R2 F3 收窄；⚠️ 2026-08-24 复核订正，见 §2.5-a）** `.env.example` 必须定义**「消费 `backend/.env` 的那一族」环境变量消费者**读取的名字。初稿在这里写「实测消费者共 5 处」——**这个数字是错的**，它漏掉了 `backend/scripts/verify_*.py` 一族（6 个文件读 `DSN`、2 个读 `DSN2`，且这些文件在 spec 写作时的 `20f615a` 上就已存在）。订正后的口径见 §2.5-a 的实测全表。<br>**本切片的修法不变**：把 **`DATABASE_URL` 补进 `.env.example`**（各带用途注释：`DATABASE_URL` = 容器内网 `db:5432`，后端代码读；`DB_URL` = 宿主侧管理用 DSN，`nas-preflight.sh` 读），**不是把 `DB_URL` 改名删掉**——改名会直接打断 `nas-preflight.sh` 的必需变量检查 |
| C1-7 | `GET /health` 返回 `{"status": "ok", "repository": <"asyncpg" \| "inmemory">}`，`repository` 反映**请求时**装配的 repository |
| C1-8 | **（收 W1-R1；codex spec-R3 F1 已纠正）** 供应链固定按服务类型分两条，**不是「所有 image: 都带 digest」**：<br>① **拉取型服务**（有 `image:`、无 `build:`，本设计里只有 `db`）→ `image:` 必须带 `@sha256:` digest；<br>② **构建型服务**（有 `build:`，本设计里只有 `api`）→ **不得**在 `image:` 里带 digest，其供应链固定由 Dockerfile 的 `FROM …@sha256:` 承担（C1-2）。本设计里 `api` **不写 `image:` 键**，镜像名由 compose 项目名派生为 `kline-trainer-api`（C1-3）。<br>digest 一律取**多架构 manifest list（OCI image index）**的顶层 digest，不得取单平台 manifest digest——否则镜像被钉死在一个架构上（Mac arm64 / NAS amd64）。已实测 `postgres:15.12` 与 `python:3.11.14-slim` 均为 index 且覆盖 `linux/amd64` + `linux/arm64/v8`（`docker buildx imagetools inspect`，2026-08-14） |
| C1-9 | **（codex spec-R3 F3）** compose 传给 `api` 的 `DATABASE_URL` 必须用 **Compose 必需变量语法** `${DATABASE_URL:?<可读错误信息>}`，使 DSN 缺失或为空串时 `docker compose up` **立即失败**而非静默起一个 InMemory 后端。已实测该语法对**未设**与**空串**都拒、消息可读、正常值放行（2026-08-14） |

### §5.2 测试判据（每条都须变异验证）

| 编号 | 判据 | 变异（中和后应变红的**具名**测试） |
|---|---|---|
| T1-1 | **正向档**：当前树上 `requirements-api.txt` 每个包在 `requirements.txt` 里存在且 pin 相同 → 绿 | — |
| T1-2 | 改掉 `requirements-api.txt` 任一 pin → T1-1 红 | 改 pin |
| T1-3 | 反向：改掉 `requirements.txt` 里同名包的 pin → T1-1 红 | 改另一侧的 pin（两个方向都要验） |
| T1-4 | 包集合恰好 `{fastapi, uvicorn, asyncpg}` | 往 `requirements-api.txt` 加一行 `pandas-ta` → 红 |
| T1-5 | 全 pin 无 range | 把某行改成 `fastapi>=0.115` → 红 |
| T2-1 | **整族扫描（codex spec-R2 F3；⚠️ 2026-08-24 订正判据形状，见 §2.5-a）**：机械枚举 `backend/` 下非 tests 的全部 `.py`（AST 提取 `os.environ.get(...)` / `os.environ[...]` / `os.getenv(...)` 的**字面量**键名）+ 真的 `source` 了 `.env` 的 `.sh`（提取其必需变量），得到**扫描全集** `discovered`。断言：<br>① `discovered == ENV_FILE_KEYS ∪ OUT_OF_SCOPE_KEYS`（**精确相等**，两个方向同时成立）；<br>② `ENV_FILE_KEYS ⊆ .env.example` 里解析出的 `KEY=` 名字集合。<br>⚠️ 原文写的「断言每一个都在 `.env.example` 里有同名 `KEY=` 行」**不能照做**——它会把 `DSN` / `DSN2` / 三个 `QMT_VERIFY_*` / `TRAINING_SETS_DIR` 一并误判为缺失（那些是人工验证脚本的开关，故意要求每次手打）。<br>⚠️ 判据①是**反向断言**，它同时兜住两种失效：扫描器坏掉返回空集 → 不相等 → 红；某个 key 被改名/删掉而分类表没跟着改 → 不相等 → 红。故「变量名写在测试里」在这里**不构成恒真**，因为被比较的另一侧是扫出来的 | — |
| T2-2 | 从 `.env.example` 删掉 `DATABASE_URL` → T2-1 红 | 改 env 侧 |
| T2-3 | 从 `.env.example` 删掉 `DB_URL` → T2-1 红（证明扫描**真的覆盖了 shell 消费者**，不只是 Python 那一半） | 改 env 侧另一半 |
| T2-4 | 把 `main.py` 改成读别的名字 → T2-1 红 | 改代码侧 |
| T2-5 | **新增一个**读未定义 DSN 变量的 Python 消费者 → T2-1 红 | 证明扫描是枚举式的、不是写死的 5 个名字 |
| T2-6 | **正向档**：当前树修完后 T2-1 绿 | — |
| T3-1 | **正向档**：无 `DATABASE_URL` 起 app，`GET /health` → `repository == "inmemory"` | — |
| T3-2 | **正向档**：装配 `AsyncpgLeaseRepository`（注入 fake pool，不需要真 PG），`GET /health` → `repository == "asyncpg"` | — |
| T3-3 | `status` 字段仍为 `"ok"` | 删掉 `status` → 红 |
| T3-4 | 中和 `/health` 的 repository 判定（写死一个值）→ T3-1 或 T3-2 其中**具名的那一条**变红 | — |
| T4-1 | 用 pyyaml 解析 compose 做结构断言：`api` 服务存在、顶层 `name == "kline-trainer"` | 删 `name` → 红 |
| T4-1b | `api.depends_on.db.condition == "service_healthy"`（**不是**裸列表形式） | 改成 `depends_on: [db]` → 红 |
| T4-1c | `db` 服务定义了 `healthcheck` | 删 healthcheck → 红 |
| T4-1d | `api` 有 `restart` 策略 | 删 `restart` → 红 |
| T4-2 | `api` 端口绑定默认值是 `127.0.0.1` | 改成 `0.0.0.0` → 红 |
| T4-3 | 训练组挂载带 `:ro` 且容器侧是 `/data/training-sets` | 删 `:ro` → 红 |
| T5-1 | Dockerfile base image 是精确 patch tag **且带 `@sha256:` digest** | 改成 `python:3.11-slim`（去 digest）→ 红 |
| T5-2 | Dockerfile 装的是 `requirements-api.txt` | 改成 `requirements.txt` → 红 |
| T6-1 | **正向档**：当前树上「拉取型服务的 `image:` 带 digest」+「构建型服务的 `image:` 不带 digest」两条同时成立 → 绿 | — |
| T6-2 | 去掉 `db` 服务 image 的 digest（退回裸 `postgres:15.12`）→ T6-1 红 | 拉取型侧 |
| T6-3 | 给 `api`（构建型）加一个带 `@sha256:` 的 `image:` → **具名的那条**红 | 构建型侧（**codex spec-R3 F1 就是这个坑**，必须有反向档钉住，不能只测「有 digest」） |
| T6-4 | 断言无任何 `:latest` | 改一个 image 为 `:latest` → 红 |
| T6-5 | Dockerfile `FROM` 去掉 digest → T5-1 红 | 见 T5-1 |
| T6-6 | ⚠️ **仅结构断言不足以覆盖 T6-3 那类错误**：实测 `docker compose config` 对 `build:` + digest `image:` 的坏配置**返回 0**，真正的报错要到 `docker compose build` 才出现（`failed to solve: build tag cannot contain a digest`）。故验收清单**必须**含一条「真跑一次 `docker compose build` 并读结论行」 | 这条是 runbook 判据，不是单测 |
| T6-7 | ⚠️ **结构断言同样抓不住「单平台 digest」**（codex spec-R4 F2）：T6-1…T6-5 只校验 `@sha256:` 的**有无**，而一个**单平台 manifest 的 digest** 完全能满足这些结构判据，却会在另一个架构上 pull/build 失败（Mac arm64 ↔ NAS amd64）。故 C1-8 的「必须是多架构 index digest」这条**必须另配机械判据**：对每个 pin 的 ref 跑 `docker buildx imagetools inspect`，断言 ① `MediaType` 是 OCI image index（不是单个 manifest）② `Platform` 列表同时含 `linux/amd64` 与 `linux/arm64/v8`。<br>⛔ **这条不能做成 pytest** —— 它需要网络 + Docker 且要访问 Docker Hub，而 `requirements-test.txt` 无 docker 依赖、CI 也不保证有 Docker daemon（对齐 `feedback_test_imports_must_not_need_optional_deps`）。**归验收清单的 runbook 判据**，在构建前执行 | runbook 判据，不是单测 |
| T7-0 | **（2026-08-24 新增：T7 一分为二）** `docker compose config` 需要 `docker` 可执行文件，而 `backend/requirements-test.txt` 无此依赖、CI 也不保证有；更要命的是本仓 CI **把任何 skip 都判失败**，所以「没 docker 就 skip」这条路走不通（对齐 `feedback_test_imports_must_not_need_optional_deps`）。故：**结构判据留在 pytest（T7-1s），行为判据归 runbook（T7-2r/T7-3r）** | — |
| T7-1s | **pytest 结构档**：用 pyyaml 解析 compose，断言 `api` 的 `DATABASE_URL` 取值字符串**恰好**是 `${DATABASE_URL:?…}` 形态——即以 `${DATABASE_URL:?` 开头、以 `}` 结尾。同时**反向**断言它不是 `${DATABASE_URL}`（无操作符）也不是 `${DATABASE_URL:-…}`（默认值操作符） | 把 `:?` 换成 `:-` → T7-1s 红；把 `:?` 整个删掉 → T7-1s 红 |
| T7-2r | **runbook 行为档**：`DATABASE_URL` **未设** → `docker compose config` 非零退出且报必需变量缺失 | runbook 判据，不是单测 |
| T7-3r | **runbook 行为档**：`DATABASE_URL` **为空串** → 同样非零退出（空串与未设是两档，`:-` 只挡未设、挡不住空串）。**正向档同跑**：有合法值时 `docker compose config` 退出 0 且解析出该值 | runbook 判据，不是单测 |

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
| **P4b** | **构建前校验每个 pin 的 digest 是多架构 index**（codex spec-R4 F2，判据见 T6-7）：对 compose 的 `db` image 与 Dockerfile `FROM` 各跑一次 `docker buildx imagetools inspect` | Claude 可跑 | 两者 `MediaType` 均为 OCI image index，且 `Platform` 同时含 `linux/amd64` 与 `linux/arm64/v8` |
| P5 | 写 `.env`（真密码，不入库；`DATABASE_URL` 指向 compose 内网 `db:5432`） | Claude 可跑 | `.env` 不进 git |
| P6 | `docker compose up -d db`（**必须是全新空卷**，见下方 R5-F2 说明），等就绪后灌 `backend/sql/schema.sql` | Claude 可跑 | ⚠️ `\dt` 出 4 张表**不是充分判据**，见 P6b |
| **P6b** | **schema 形状硬门**（codex spec-R5 F2；⚠️ **判据于 2026-08-24 收紧，见下方 P6b 补强**）：直接查 NAS 库的实际形状，逐条比对关键列类型与**约束的完整定义** | Claude 可跑 | 见下方「P6b 补强」——⛔ 原判据写的是「四条 CHECK 全部**存在**」，**存在性判据不够**，已作废 |
| P7 | scp 3 个 zip 到宿主训练组目录 | Claude 可跑 | **NAS 上重算 CRC32 = `851f9444` / `32892a5f` / `150d8d6c`** |
| P8 | `docker compose up -d api`（在 NAS 上构建镜像） | Claude 可跑 | `curl 127.0.0.1:8010/health` → `repository == "asyncpg"` |
| **P9** | **§9.2 的 NAS-A/B 真 PG 烟测 8 条（此刻 `training_sets` 表为空，只有烟测自己插的临时行）** | Claude 可跑 | 8 条全过；含 NAS-A.3 的 10 分钟等待 |
| **P10** | **删光烟测临时行**，并断言表为空 | Claude 可跑 | `SELECT count(*) FROM training_sets` **= 0**（⚠️ 这条断言是 P11 的前置硬门） |
| P11 | 3 条 INSERT 写 `training_sets`，`file_path` 用 `/data/training-sets/…` | Claude 可跑 | 恰好 3 行、全 `status=unsent`、`content_hash` 与 P7 一致 |
| **P11b** | **暴露前重新校验 tailnet 暴露面**（codex spec-R3 F2）：跑 `tailscale status --json`，逐节点断言归属者全为 `agateuu1234@`、无 shared/external 节点 | Claude 可跑 | 断言通过；**任一节点归属者不同或出现外部共享 → 停止，不得执行 P12**（须先回到 §11-R8 重新评估） |
| P12 | `tailscale serve --bg --https=443 http://127.0.0.1:8010`（⛔ **不得用 `funnel`**，见 §4-D1） | Claude 可跑 | Mac 上 `curl https://fnos.tail9dc815.ts.net/health` 成功且证书可验；`tailscale serve status` 输出**不含** funnel |
| **P12b** | **紧邻真机验收前再校验一次暴露面**（同 P11b 判据）——P11b 到 P13 之间隔着装机/签名，可能是几十分钟到几天 | Claude 可跑 | 同 P11b；不通过则不许开始 P13 |
| P13 | Debug 构建装机 + `devicectl` 带 `KLINE_BACKEND_BASE_URL` 启动 | **user**（需签名，真终端） | App 启动无错 |
| P14 | 走 §9 验收 | **user**（真机目视） | G1–G4 全过 |
| P15 | **（仅失败重跑时）** 按 **§7.1** 复位库侧 3 行 + 清设备侧状态，回到 P12b | 库侧 Claude 可跑 / 设备侧 **user** | 3 行回到 `unsent` 且 lease 三列全 NULL；设备上无残留训练组 |
| **P16** | **关闭暴露端点**（codex spec-R4 F1）：`tailscale serve reset`（或等效关闭命令） | Claude 可跑 | `tailscale serve status` 输出 **`No serve config`**（= NAS 上实测过的初始态，§2.4） |

**⚠️ 暴露窗口的生命周期是硬约束**（codex spec-R4 F1 + **R5 F1 收紧**）：`tailscale serve --bg` 是**持久**配置，不会自己消失。

**P16 是 P12 之后每一条路径的强制收尾，不只是成功路径**（R5-F1）。初稿把 P16 写成「验收通过后必须执行」——**这是漏洞**：P13/P14 失败或中途暂停时，端点仍然对全 tailnet 开着，而 P15 正好把 3 行复位回 `unsent`，此时任何其它 tailnet 节点（或设备上一个残留的 App 进程）都能把库存预占/下载/confirm 掉，直接毁掉下一次验收。

正确契约（`finally` 语义）：

| 路径 | P16 是否必须执行 |
|---|---|
| P14 验收全过 | **是** |
| P13/P14 失败 | **是**，且必须在 P15 复位**之前**关 |
| 中途暂停 / 人为中止 / 换机 / 下班 | **是** |
| P15 复位后准备再来一轮 | 复位期间保持关闭，**重新开始时才由 P12 重新打开** |

即：**只有在「正要做 P13/P14」这一小段窗口里，端点才允许是开的。** 这是 §11-R8 接受理由的第四个成立前提（见 R8）。

**⚠️ 次序是硬约束，不是排版**（codex spec-R2 F2）：烟测（P9）必须在插入 3 行真数据（P11）**之前**跑完并清空。理由见 §9.2 —— `reserve` 无法指定行，烟测会抢走真数据行。P10 的 `count = 0` 断言就是这道门的机械判据。

**⚠️ 为什么 `\dt` 出 4 张表不算数**（codex spec-R5 F2）：`backend/sql/schema.sql` 建表全部用 **`CREATE TABLE IF NOT EXISTS`**（已实测：`schema.sql:8/13/57/69` 四处建表全带该子句，全文件共 7 处 `IF NOT EXISTS`）。这意味着——如果 PG 卷不是全新的（比如上一次部署留下的、或者列类型/CHECK 约束跟当前 DDL 有漂移的旧卷），**`schema.sql` 会静默跳过所有建表、什么都不修**，而 `\dt` 照样输出 4 张表、P6 照样「通过」。随后插入的数据和真机验收就跑在一个**没被校验过的 schema** 上，故障现象会跟数据 bug / App bug 混在一起，极难区分。

故 P6 追加两条硬约束：① **卷必须是全新的**（部署前确认 compose 项目 `kline-trainer` 无既有 `pgdata` 卷，有则先销毁）；② **P6b 直接查实际形状**，不看建表语句的返回值。

**⚠️ P6b 补强：存在性判据不够，必须比对完整定义**（codex plan-R1 high finding，2026-08-24，**实测坐实**）

P6b 的初版判据是「这几条 CHECK 全部**存在**」。按这条判据写出来的闸门只比对约束**名字**——不看它属于哪张表，也不看定义是什么。**两种漂移实测都被放行（退出码 0）**：

- **同名但定义被改宽**：`ck_status_enum` 被改成多允许一个非法取值，闸门照样通过；
- **同名约束被挪到别的表**：`klines` 上的 `ck_klines_price_ordering` 被整个删掉、同名约束建到 `stocks` 上，闸门照样通过 —— 此时 `high < low` 的脏数据可以直接进库。

而 P6b 的**全部存在理由**就是「旧卷/漂移卷会让 `schema.sql` 静默什么都不修」。一个连定义漂移都看不见的闸门，在它唯一要防的场景上是失效的。

**第二轮又被打回**（codex plan-R2 high，同日）：R2 版把「存在性」换成了「完整定义」，但**扫描面仍然太窄** —— 只查 6 个选定列、只看 `contype IN ('c','u')`。于是**主键、外键、索引、可空性、默认值、其余列类型全部不查**。实测 `schema.sql` 里确有：`klines.stock_code → stocks(code)` 外键、3 个主键、3 条显式索引（其中**两条是带 `WHERE` 谓词的部分索引**）、多处 `NOT NULL` 与 `DEFAULT`。少了那个外键会产生孤儿行；少了两条 lease 部分索引会让预占查询退化；主键缺失会产生重复身份 —— 而闸门照样说「健康」。

**收紧后的判据（R3 版，已实现于 `docs/runbooks/2026-08-24-qmt-nas-p6b-schema-shape-check.sql`）= 完整 schema 契约，三类各自双向集合相等**：

| 类别 | 判据 | 期望项数 |
|---|---|---|
| 列 | 每张表每一列的 `format_type()`（含长度/精度）+ 可空性 + 默认值表达式 | 38 |
| 约束 | **`p` / `f` / `u` / `c` 全四类**，按 (所属表, 名字) 匹配、比对 `pg_get_constraintdef()` 完整定义，限定 `connamespace='public'` | 15 |
| 索引 | `pg_indexes.indexdef` 完整定义（**含部分索引的 `WHERE` 谓词与有序列**） | 9 |

三类都同时断言「预期的都在」与「不许有多余的」；另配期望项计数自检（38/15/9）与合格项计数自检（62），判据本身被改坏时直接失败。

**15 档破坏逐档实测**（详表见 runbook 的 P6b 一节）：删 CHECK / 同名改定义 / 同名换表 / 多出约束 / 改列类型 / **删外键** / **删主键** / **删部分索引** / **部分索引丢 `WHERE`** / **lease 列类型漂移** / **默认值漂移** / **可空性漂移** / 多出列 / 删列 / **唯一约束列集合被改** —— 全部退出码 3，健康库 0。

⚠️ **变异验证的方法论坑（本轮踩到）**：`ALTER COLUMN ... TYPE` 会让 PostgreSQL **重新渲染**依赖该列的约束表达式（语义相同、文字不同）。所以「就地复原」复原不干净，会把后续档次的结果污染成假的。**每一档必须在全新建的库上跑**。

**已知且刻意保留的行为**：被**就地迁移**出来的库（跑过 `ALTER COLUMN TYPE`）会因上述重渲染而报 `FAIL-definition-drift`。这是想要的结果 —— P6 的前提就是「必须全新空卷」，不新就该重建，而不是放宽闸门。

**接受的残留**：该闸门是 `backend/sql/schema.sql` 在 PostgreSQL 15.12 上产出形状的**快照**（文件头记着 schema.sql 的 md5）。`schema.sql` 若变更而闸门未重生成，会在**全新空卷**上误红。现在只靠文件头注释与 runbook 里的一句说明提示操作者，**没有机械守卫**。把它接进 `schema-smoke.yml`（那条 workflow 已有真 PostgreSQL 服务）可以让它自维护，但那属于 CI 闸门改动、超出本次范围 → 记为 residual，不在本次收。

**⚠️ 2026-08-24 复核发现这颗地雷已经埋在 NAS 上了**（§2.5-c）：NAS 现存卷 **`backend_pgdata`**（4 个月前的遗留）。compose 默认用目录名当项目名——部署目录若叫 `backend/` 且漏了显式项目名，就会正好挂上这个旧卷。故 P6 的「全新空卷」判据必须**同时**核实：`kline-trainer_pgdata` 不存在（或已销毁）**且**实际启动后挂载的卷名确实是 `kline-trainer_pgdata` 而不是 `backend_pgdata`。

**⚠️ P11 的环境变量只在这次 `devicectl` 启动的进程里有效**：之后从桌面图标点开 App 不会带这个变量，后端地址回落到默认值。这**不影响 G4**——训练组已落本地缓存，离线可看可练。

**并行安全**（本次全程遵守）：不碰 `.dev/worktree/qmt-4a2b-s3`；Mac 上只碰 `qmt-trial` 容器，绝不碰 `qmt-pg-r8` / `qmt-pg-r8b`；不动主仓 HEAD，代码从 `origin/main` 切**新** worktree。

### §7.1 验收可重跑契约（codex spec-R1 F2，2026-08-14）

**为什么需要**（依据实测的真实 SQL，非推演）：

- `reserve_meta` 的谓词是 `WHERE status = 'unsent' OR (status = 'reserved' AND lease_expires_at <= $1)`（`lease_repo.py:122-125`）→ **`sent` 行永远不会被再次选中**。
- `reserved` 行靠 10 分钟 TTL 自愈，**`sent` 行永不自愈**。
- 本次库存**恰好 3 行**，而 G2/G3 要求的正是这 3 行走到 `sent`。

→ **一次部分失败的真机跑（如 2 行 confirm 成功、第 3 行断网）会永久吃掉库存**，此后无法再跑一次干净的 3 行验收。这不是理论风险：真机链路涉及证书、Tailscale、签名、网络，首次跑通常不会一把过。

**库侧复位契约**：

1. 对那 3 个 id 无条件置 `status='unsent'`，并把 `lease_id` / `lease_expires_at` / `reserved_at` **三列同时置 NULL**。
   ⚠️ 三列必须一起 NULL —— `ck_lease_state_invariant` 规定 `unsent` 行的 lease 三列必须全空，漏一列整条 UPDATE 被 CHECK 拒绝。
2. **必须是无条件 UPDATE，不得写成依赖当前状态的条件更新** —— 复位要在「已经是 unsent」时重复执行也安全（幂等），否则第二次重跑会静默不生效。
3. 复位后核实：查这 3 行，`status` 全 `unsent` 且三列全 NULL。

**设备侧复位契约（⚠️ 这条不做会产生假绿）**：

必须 **uninstall App 再装**，不能只是覆盖安装（`project_device_testing_requires_seed_fixture`：install 不擦 data）。理由：

- App 的缓存按训练组 id 键控。**上一轮已经落地的 3 个训练组在覆盖安装后仍然在**——此时 G2「看到 3 个训练组」和 G4「能进去画 K 线」会在**上一轮的残留物**上「通过」，而这一轮其实一个字节都没下载。这是标准的假绿。
- P2 journal 的残留行还会在下次启动时触发 `retryPendingConfirmations`：拿旧 lease 去 confirm 已复位的行 → `decide_confirm` 走 `row.lease_id != lease_id` 分支 → `LEASE_INVALID` → 409 → journal 标 `.rejected` 并**删掉本地缓存副本**。行为上自洽，但会让「训练组莫名消失」这种现象混进验收观察，干扰判断。

**判绿纪律**：任何一次重跑，若**没有**同时做库侧复位 + 设备侧 uninstall，其 G2/G4 观察结果**一律作废**，不得记为通过。

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
| NAS 断电重启，`api` 比 PG 先起来 | `create_pool` 抛错 → FastAPI startup 失败 → 容器退出后不再拉起 | C1-3b 的 healthcheck + `service_healthy` + `restart` 三件套预防；判据是 `docker compose ps` 里 `api` 为 running |
| **重跑时没复位就直接看结果**（假绿） | G2/G4 在上一轮残留的缓存训练组上「通过」，实际本轮零下载 | §7.1 的库侧复位 + 设备侧 uninstall；缺任一项则该次 G2/G4 观察作废 |

---

## §9 验收

### §9.1 四条目标的权威判据

- **G1**：`curl https://fnos.tail9dc815.ts.net/health` → `repository == "asyncpg"`。
  ⚠️ 这是**快速前置检查**，不是决定性证据。决定性证据是 **G3**：InMemory repo 里零行，若真走了 InMemory，`reserve` 会返回 `sets: []`、手机一个 zip 都拉不到、库里三行也不会变 `sent`。G2+G3 同时成立即排除了假件路径。
- **G2**：面板状态行显示 3 个成功 + 本地训练组列表出现 3 条。
  ⚠️ **若本次是重跑**，必须先按 **§7.1** 完成库侧复位 + 设备侧 uninstall，否则 G2/G4 会在上一轮残留的缓存上假绿，观察结果作废。
- **G3**：在 NAS 的 PG 里查那 3 行，`status` 全为 `sent`。
- **G4**：真机目视，任选一条进去有蜡烛渲染。

### §9.2 顺带收掉仓库里躺着没跑过的清单

`docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md` 的 **§NAS 真 PG 烟测**（NAS-A.1～A.4、NAS-B.1～B.4，共 8 条）本次一并执行，作为 **§7 的 P9**。

- NAS-A.3 需要**等 10 分钟 + 1 秒**（租约 TTL）。这条耗时长但必须真跑，不得推演。
- **必须在插入 3 行真数据之前跑**（P9 < P11），跑完删光临时行并断言 `count = 0`（P10）。

> **本 spec 初稿在这里写错过，已纠正**（codex spec-R2 F2，2026-08-14）：
> 初稿写的是「执行时用另建的临时测试行，不要用那 3 行真数据」。**这条路根本走不通** ——
> `reserve_meta` 的 SQL 是 `... ORDER BY created_at LIMIT $2`（`lease_repo.py:122-128`），
> **没有任何参数能指定要预占哪一行**。临时行的 `created_at` 晚于 3 行真数据，所以
> `GET /training-sets/meta?count=1` 拿到的**必然是最早的那行真数据**，而 NAS-B.3 紧接着就会
> 把它 confirm 成 `sent` —— 真数据行在手机还没开始下载前就被烧掉，G2/G3 直接失效。
>
> 这是 memory 里 `feedback_spec_all_paths_must_reach_the_chokepoint` 那条守则的又一次重演：
> 我断言了「用临时行」，却没核实**这个动作有没有办法够到那一行**。唯一可靠的隔离手段是
> **时间隔离**（表里此刻除了临时行没有别的行），不是「意图上用临时行」。

### §9.3 清单形态

两个切片各自附一份验收清单，**中文、非程序员可执行、动作 / 预期 / 通过条件三列**，禁用 `.claude/workflow-rules.json` 里列的禁止措辞。部署 + 真机部分单独一份。

---

## §10 明确不属于本次范围

- ~~真实数据试跑挖出的两个生产缺陷（`export_log.period` 写 `1d` 而代码只认 `daily` 导致日线被静默跳过；`status='empty'` 行让 `parse_export_log` 整份崩掉）→ 归 4b/4c，本次不修。~~ **⚠️ 2026-08-24 已作废：这两条已由 PR #173（`d6eae79`）在 main 上修掉**（`_LABEL_TO_PERIOD` 补进 `1d`，且认不出的取值改为**报错并点名那个值**而不再静默 `continue`）。本次交付仍然不碰它们 —— 只是「它们还开着」这个陈述不再成立。
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
| **R8** | **API 零认证**：任意 tailnet 节点可 `reserve` → `download` → `confirm`，把全部训练组预占、下载并打成 `sent` | **本次接受 —— user 2026-08-14 明示裁决**（codex spec-R2 F1 / spec-R3 F2 两轮均建议加 bearer token，user 两次范围内均选择不加；**后续轮次不得把这条当新 finding 反复提**）。<br>**codex spec-R3 F2 的增量部分已采纳**：接受理由原本只建立在 brainstorming 期的一次快照上；现加 **P11b 硬门**——暴露前重新校验 tailnet 归属者与外部共享，不通过则不许执行 P12。<br>**codex spec-R4 F1 的增量部分已采纳**：`tailscale serve --bg` 是持久配置，原 runbook **没有关闭步骤**（真漏项，与认证与否无关）→ 现加 **P12b**（紧邻真机验收再校验一次）+ **P16**（用完必关，判据 `No serve config`）。<br>**接受理由的成立前提共四条**（缺一即不成立）：① 单用户 tailnet ② 无外部共享节点 ③ 无 funnel ④ **暴露窗口仅限 P12→P16 的验收期间，用完即关**。实测边界：7 个节点归属者全是 `agateuu1234@`、无外部共享（§2.4），故实际暴露范围 = user 自己的设备。硬门是 §4-D1 的 **funnel 禁令**（走 funnel 则暴露到公网，该残留立刻不可接受）。被否方案：bearer token 需改 `DefaultAPIClient`（§6.3 明说不动）+ 设备端多一个配置通道 + 后端中间件 + 测试 ≈ 第三个切片。⚠️ **这条不随 App 上架自动消失** —— 真上云服务器时必须先解决认证，届时属正式部署 PR 的**阻塞项**，**不得沿用本次的接受理由**（本次理由的成立前提是「单用户 tailnet + 无外部共享 + 无 funnel」，上云后三条全部不成立） |
| **R9** | `scripts/nas-preflight.sh` 的拓扑假设**已经**与 compose 默认不一致（**先于本次改动存在**） | 它第 57 行检查 `$NAS_HOST:5433` 从 Mac 可达，而 compose 默认 `${DB_BIND_HOST:-127.0.0.1}:5433` 只绑回环 → 该脚本在默认配置下本就跑不过第 3 步。**本次不修**（CLAUDE.md §3：不改与本请求无关的既有代码），但**本次 runbook 完全不使用它**——我们用 `/health` 在 NAS 回环 + 经 tailnet 两处各验一次（P8 / P12）。⚠️ 本次只保证不**新增**破坏（C1-6 保留 `DB_URL` 定义），不声称该脚本可用 |

---

## §12 流程与评审

- 本 spec 定稿后 → `superpowers:writing-plans` 出两份实施计划（每切片一份）。
- 实施走 TDD：**先看红再实现**；每条新测试**必须变异验证**（中和判据 → 看**具名的那条**变红 → 用 `cp` 复原，⛔ 绝不用 `git checkout <file>`），且由控制者亲跑。
- 收口走 `.claude/scripts/codex-attest.sh --base main --head <分支>` 的 branch-diff，**不许窄化 focus**。拿到 approve 先确认它**真跑了测试**。没真 approve 就如实写 needs-attention / 接受残留 / override，**不得**写「收敛」。
- `git push` / `gh pr create` / `gh pr merge` 全部由 user 在真终端跑。

---

## §13 既有 residual 账目

本次交付**就是**三条 residual 在治理账本里点名归属的那个「NAS 部署 PR」。原始定义在 `kline_trainer_plan_v1.5.md` §九 Phase 0 第 6 步「Docker 部署 FastAPI」+ §二目录结构（`Backend/docker-compose.yml` + `.env`）+ §8.1「所有配置集中于 `.env`，便于日后迁移服务器」；`kline_trainer_modules_v1.4.md:129` 把 PostgreSQL 部署位置写作 NAS。

**为什么拖了三个 Wave**：卡点是 **W1-R2** 的前置条件「需 NAS 真实 CSV 数据源 + B1/B2 真跑」。没有真实数据时，即便部署了后端，库里也是空的——手机拉不到东西，验收无从谈起。真实 QMT 数据是 **2026-08-14** 才第一次跑出 3 个片段的。次序上部署必须排在数据之后。

| 编号 | 内容 | 账本轨迹 | 本次处置 |
|---|---|---|---|
| **PR11-R1** | 生产 `backendBaseURL` 是 placeholder `http://kline-trainer.local` | `docs/acceptance/2026-06-08-wave2-pr11-composition-root.md:67` 起 → Wave 2 completion `DEFERRED → NAS 部署` → Wave 3 completion 仍 **OPEN** | **保持 OPEN，仅收窄描述**（见 §13.0） |
| **W1-R1** | `docker-compose.yml` 用 image tag 而非 `@sha256:` digest | Wave 1 completion §48 → W1-R1，Wave 2/3 completion 均 **OPEN**，处置写明「归 NAS 部署 PR」 | **CLOSE**（切片一 C1-8 / T6，user 2026-08-14 拍板一并收） |
| **W1-R2** | 3-5 个样本训练组数据未生成（源自 H7 = plan v1.5 Phase 0 第 7 步「手动检查 3-5 个训练组数据正确性」） | Wave 1 completion §49 起 **OPEN**，理由「需 NAS 真实 CSV 数据源 + B1/B2 真跑」 | **部分满足，不 CLOSE**（见下） |

### §13.0 PR11-R1 为什么**不能**标 CLOSE（codex spec-R1 F1，2026-08-14）

本 spec 初稿把 PR11-R1 标成 CLOSE，**这是 overclaim，已纠正**。

PR11-R1 的原始定义是「**生产** `backendBaseURL` = placeholder」。而切片二只打通 **Debug** 通道（`#if DEBUG` 读 `KLINE_BACKEND_BASE_URL`）；**Release 构建仍然回落到硬编码的 `http://kline-trainer.local`**，Release 配置通道本次明确不做（§6.3，user 已定）。所以：

- Release / TestFlight 包**仍然带着原来那个上架阻塞**；
- 即便是 Debug 包，只要不是那一次 `devicectl` 启动的进程（比如从桌面图标点开），也会回落到 placeholder（§7-P11 已明写）。

因此「Debug 演示能过」**不等于**生产阻塞已解。本仓 Wave 3 completion 曾把同型问题点名为 **overclaim**（把无运行时接线的 bounce 列进运行时矩阵），此处是同一种错，不再犯。

**处置**：PR11-R1 **保持 OPEN**，描述收窄为——

> Debug 通道已可配（`KLINE_BACKEND_BASE_URL`，切片二）；**Release 配置通道仍 OPEN**，归正式部署 PR。本次的 NAS 验收属 **debug-only 链路验证**，不构成生产 URL 配置的关闭证据。

**连带的措辞纪律**（并入 §1 禁述族）：本次交付的任何文档 / PR 描述 / 提交信息**不得**出现「backendBaseURL 已可配置（不加限定）」「PR11-R1 已关闭」「生产后端地址已接通」。提到时必须带 **debug-only** 限定。

### §13.1 W1-R2 为什么只能标「部分满足」

本次确实拿到了 3 个用**真实 QMT 数据**生成的训练片段，并且验证强度**高于** H7 原本要求的「SQLite 客户端打开验证」——它们会走完整的 App 端到端链路（CRC32 → 解压 → `user_version` 校验 → 非空校验 → 缓存 → 真机渲染）。

但**不得据此标 CLOSE**，三条理由：

1. 这 3 个片段是在**本地副本上做了临时转换**后生成的（源共享全程只读），**不是**走生产路径产出的。
2. ⚠️ **2026-08-24 订正**：原文写「生产路径上还压着两个已知缺陷…本次不修」——那两条**已由 PR #173（`d6eae79`）修掉**。但 W1-R2 **仍然只能标「部分满足」**，理由变为：这 3 组是在**本地副本上临时转换**后产出的，**没有**在修复后的生产路径上重跑过；「生产路径现在能跑通」需要用真实导出重新验证一次，本次不做。
3. 3 组 ≠ H7 语境下的样本充分性，更远不是 plan v1.5 Phase 0 第 4 步的「生成 100 个训练组」。

故本次只把 W1-R2 从 OPEN 改注为「**部分满足：3 组真实数据已端到端验证；生产路径仍欠 4b/4c 两个缺陷修复**」，并继续守 §1 的禁述。

### §13.2 本次**不**收的既有 residual

- `docs/acceptance/2026-05-29-pr-b3-fastapi-lease.md` §residual 的 **migration-runner defer**（迁移执行脚本 + 版本追踪）：本次仍不做。理由是本次只需在**空库**上跑一次 `schema.sql`，不涉及任何 schema 变更（见 §4-D3 第 1 条）。
- B4 调度器相关 residual：本次不部署调度器（§5.3）。
