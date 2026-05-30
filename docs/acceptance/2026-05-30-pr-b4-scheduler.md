# B4 APScheduler 调度器模块 验收清单（Wave 1 顺位 19 / 第 21 个 PR）

**模块**：后端调度器 `app/scheduler.py`（核心编排）+ `app/scheduler_main.py`（独立单例进程入口）——每天北京时间 05:00 回滚过期 lease + unsent ≤ 40 时调用 B2 generate_batch 补到 100，部分补足同进程有界重试。

**验收性质**：非-coder 可执行；纯层 + 接线 host 可测（pytest + InMemory repo + fake pool/gen）。真实 asyncpg pool、定时触发、跨进程行为需 NAS 部署人工验。

## 一、自动化测试验收（host 本地跑）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 终端 `cd backend && python3 -m pip install "apscheduler==3.10.4" -q` | 安装成功无报错 | ☐ Pass / ☐ Fail |
| 2 | 终端 `cd backend && python3 -m pytest -q` | 全绿（128 passed，0 failed，0 skipped） | ☐ Pass / ☐ Fail |
| 3 | 看 `tests/test_scheduler_logic.py` | is_expired_reserved 5 + compute_replenish_deficit 5 case | ☐ Pass / ☐ Fail |
| 4 | 看 `tests/test_scheduler.py` 的 test_run_sweep_replenish_30_to_70 | deficit==70 且 generated==70 且请求数==70 | ☐ Pass / ☐ Fail |
| 5 | 看 `tests/test_scheduler.py` 的 test_inmemory_rollback_five_expired | 5 个 id 全回滚 | ☐ Pass / ☐ Fail |
| 6 | 看 test_run_sweep_until_target_retries_partial | 首轮补一半→重试补足→count_unsent 达 100（重试不被 40 阈值门卡住） | ☐ Pass / ☐ Fail |
| 7 | 看 test_build_scheduler_cron_and_reentrancy_guard | cron hour=5 minute=0 Asia/Shanghai + max_instances=1 + coalesce=True + misfire_grace_time=3600 | ☐ Pass / ☐ Fail |
| 8 | 看 test_scheduler_main_exits_when_lock_held | 拿不到 advisory lock 时不起调度器、仍关 pool | ☐ Pass / ☐ Fail |
| 9 | 看 test_scheduler_main_requires_absolute_training_sets_dir | TRAINING_SETS_DIR 缺失或相对路径 → SystemExit | ☐ Pass / ☐ Fail |

## 二、依赖锁定验收（H6 part 4）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 10 | 终端 `grep -n "apscheduler==" backend/requirements.txt` | 输出 `3:apscheduler==3.10.4` | ☐ Pass / ☐ Fail |

## 三、人工 / 集成验收（NAS 部署，CI 不跑）

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 11 | 设 DATABASE_URL + 绝对 TRAINING_SETS_DIR 跑 `python -m app.scheduler_main` | 入口可启动：起 asyncpg pool + 调度器，含 b4_daily_sweep job（常驻/restart 部署归 B4-R4） | ☐ Pass / ☐ Fail |
| 12 | 不设 TRAINING_SETS_DIR 或设相对路径跑 `python -m app.scheduler_main` | 报错退出（须绝对共享路径，D15） | ☐ Pass / ☐ Fail |
| 13 | 已有 scheduler 进程时再启一个 `python -m app.scheduler_main` | 第二个 log error 退出、不重复 sweep（D14 advisory lock） | ☐ Pass / ☐ Fail |
| 14 | B2 部分生成（generated < 请求数）时看进程日志 | 重试耗尽后含 "B4 replenish degraded after retries" warning（非静默） | ☐ Pass / ☐ Fail |
| 15 | 真实 Postgres 造 5 条过期 reserved 行 + 手动触发 run_sweep | 5 行 status 回 unsent，lease/reserved_at 清空 | ☐ Pass / ☐ Fail |
| 16 | 真实 Postgres unsent=30 + 手动触发 run_sweep | 调用 B2 后 unsent 达 100 | ☐ Pass / ☐ Fail |
| 17 | 取一条新生成行 file_path，从 web (uvicorn app.main) 进程下载该 id | 文件可读、下载成功（D15 路径共享，无 404） | ☐ Pass / ☐ Fail |
| 18 | 本验收文件存在 | 在 PR 文件列表中 | ☐ Pass / ☐ Fail |

## 四、residual（本 PR 不实现，已记录追踪）

- **B4-R1（清理职责 3 defer）**：spec modules §四 B4 职责 3「清理 30 天前 sent」标注「（可选）」，user explicit 选不实现（2026-05-30）。无行为缺口。后续按存储压力以独立后端 PR 落地（同双层：select_stale_sent 纯函数 + asyncpg DELETE 薄壳）。
- **B4-R2（CI 不加 backend pytest workflow）**：沿用 B1/B2/B3——backend pytest 为 trust-boundary，与现有 OpenAPI workflow 冲突；host 本地跑 + codex attest 对抗 review 覆盖。
- **B4-R3（进程级 advisory lock 已实现，非 defer）**：进程级 `pg_try_advisory_lock`（D14）强制 scheduler 单例——误启第二进程拿不到锁即 log error 退出。更细的 per-sweep 级锁非必要。
- **B4-R4（生产部署编排 defer，PR goal 已收窄）**：`scheduler_main` 的常驻部署单元（compose/systemd service + restart policy + enabled/auto-restart）属 NAS 部署 scope；本仓 FastAPI web 自身亦无 Dockerfile/compose service（仅 db）。本 PR goal 已收窄为「交付调度器代码 + 可启动入口」，不声称生产常驻启动；容器化与「服务 enabled / 崩溃重启」验收由后续部署 PR 统一落地。
- **B4-R5（advisory lock conn-scoped failover 极端 defer）**：进程级 lock 随 lock_conn 释放——正常运行已覆盖单例；仅 DB failover/网络断使 lock_conn 掉线而 Python 进程仍存活的极端窗口，第二 scheduler 可能拿锁并发（over-generate 几个训练组，非数据损坏）。codex R7-F2；user explicit 接受残留（2026-05-30，超 3 轮 escalate）。严肃多实例化时改 per-sweep lock + conn-loss 检测。
