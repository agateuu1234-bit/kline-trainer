# K 线训练器 · Kline Trainer

用于 K 线形态识别训练的应用。当前处于规划阶段，尚无代码。

## 文档

- [项目计划](./kline_trainer_plan_v1.5.md)
- [模块文档](./kline_trainer_modules_v1.2.md)
- [协作规则](./CLAUDE.md)

## Wave 0 契约冻结 v1.4（2026-05-17）

Wave 0 已签字冻结。tag：`wave0-frozen-v1.4`。Sign-off ledger：[docs/governance/2026-05-17-wave0-signoff-ledger.md](docs/governance/2026-05-17-wave0-signoff-ledger.md)。

### 依赖版本锁定（spec §15.2；codex R2 finding 1 修：iOS exact pin / backend 移 residual）

**iOS 依赖（Wave 0 freeze，exact 版本，来自 `ios/Contracts/Package.resolved`）：**

| 依赖 | 用途 | 版本 | Lock 源 |
|---|---|---|---|
| GRDB.swift | iOS SQLite ORM | **6.29.3** | `Package.resolved` |
| ZipFoundation | iOS zip 解压 | **0.9.20** | `Package.resolved` |
| SQLite | iOS 内嵌 | iOS 17+ 系统自带 | iOS minimum deployment target |

**Wave 0 起 `Package.resolved` 视为锁定 source-of-truth**。变更走 RFC + ledger。

**后端依赖（Wave 1 B1-B4 PR 内 exact pin；Wave 0 暂用 ranges + residual H6）：**

| 依赖 | 用途 | spec §15.2 range | 真锁定时点 |
|---|---|---|---|
| FastAPI | 后端 API 框架 | 0.110+ | B3 PR 落 `backend/requirements.txt == 0.110.x` |
| Uvicorn | ASGI server | 0.27+ | B3 PR |
| APScheduler | 后端定时 | 3.10+ | B4 PR |
| pandas | 后端数据 | 2.x | B1 PR |
| pandas-ta | 指标计算 | 0.3.14b0+ | B2 PR |
| asyncpg | PG 驱动 | 0.29+ | B3 PR |
| PostgreSQL | 数据仓库 | 15+ | `docker-compose.yml` image digest pin B3 PR |

Wave 0 freeze **仅 iOS deps exact pin**；backend ranges 待 Wave 1 B1-B4 PR 各自落 `requirements.txt == X.Y.Z` 时同步锁定（residual H6 in `docs/governance/2026-05-17-wave0-signoff-ledger.md`）。

### Wave 0 交付清单

17 业务模块（PR #37 - #53）+ M0 契约 + F1/F2 基础 + C1a/C1b/C1c 图表核心 → 见 sign-off ledger。
