# B2 生成锁下沉到写入临界区 — Design

**日期**：2026-07-20
**背景来源**：codex 对抗评审 R1-F2（PR 2b `qmt-plan2b-b2-reconnect` @ `2a1287c`）
**范围**：`backend/generate_training_sets.py` + `backend/tests/test_b2_reconnect_integration.py`

---

## 1. 问题

`generate_one_training_set` 把 zip 写到**确定性最终路径** `{code}_{start}.zip`，且这次写入发生在两道冲突检查**之前**：

```
assemble_from_windows()            ← 无条件写最终路径
  ↓
_exists_start() 预检               ← 第一道检查
  ↓
_register_training_set()           ← 第二道（ON CONFLICT DO NOTHING）
```

并发写者选中同一 `(stock_code, start_datetime)` 时，输家会**覆写赢家已登记的那个 zip**。后果：`training_sets` 行里的 `content_hash` 与磁盘字节失配（B3 下载校验失败或静默坏产物，**用户可见**）；写入中途崩溃则留下损坏 zip。

本 PR 已修的部分（commit `a7b009d`）：输家的 `_exists_start` 预检**不再 unlink** 赢家的文件。**未修的部分**：覆写本身。

### 当前防线为什么不够

`B2_GENERATION_LOCK_KEY`（PF2-R5-F2 引入）由**调用方**持有：

| 调用方 | 位置 | 是否持锁 |
|---|---|---|
| CLI `_amain` | `generate_training_sets.py:616-624` | ✅ |
| 调度器 `_gen` | `app/scheduler.py:158-166` | ✅ |
| **直接调用 `generate_batch` / `generate_one_training_set`** | — | ❌ |

即：**这个数据耐久性不变量靠"调用方记得先取锁"维持，被调函数自身零防御。**

这与 PF2-R5-F2 当初的论证不一致 —— 那轮 codex 指出「"不受支持"不是强制手段」，我们据此把 CLI/B4 并跑的接受残留改成了锁强制。同一论证用在"直调路径"上，结论应当相同。

Plan 3（B1 接入）会引入新的调用方，届时这条纪律更难维持。

---

## 2. 设计

**把锁下沉到写入临界区**：在 `generate_one_training_set` 内部，锁包住「装配 → 两道冲突检查 → 登记」这一段，用完立即释放。

```
（早退检查：覆盖行 / bars / dense 交叉校验 / 选窗口）   ← 不取锁
  ↓
┌─ 取 B2_GENERATION_LOCK_KEY ─────────────────┐
│  assemble_from_windows()                     │
│  _exists_start() 预检                        │
│  _register_training_set()                    │
└─ 释放 ───────────────────────────────────────┘
```

### 2.1 不变量

> 任一时刻，最多一个数据库 session 可处于「向确定性最终路径写入并登记」的临界区内。

由代码强制，不依赖调用方纪律。

### 2.2 可重入性（本设计成立的关键）

PostgreSQL 的 session 级 advisory lock 对**同一 session** 是可重入计数的：已持锁的 session 再次 `pg_try_advisory_lock` **返回 true** 并使计数 +1，需配对解锁。

因此对已持锁的 CLI / 调度器路径，内层获取**必然成功**，行为零变化。外层锁与内层锁的取放严格配对嵌套，不会泄漏。

### 2.3 外层两处锁保留

不删。它们提供内层给不了的两样东西：

1. **整轮 sweep 期间独占** —— 内层锁只在单个训练组的临界区内持有，两个 sweep 仍可交替进入；外层锁保证一轮 sweep 期间没有第二个 B2 在跑。
2. **用户可见的拒绝行为** —— CLI 打印错误信息并返回退出码 1；调度器打 warning、本轮产 0 等下次 cron。这是「被拒绝」而非「产出 0」的语义区分。

若删掉外层，`generate_batch` 需要发明一个"我是被拒了、不是产出 0"的返回值或异常 —— 平白的 API 改动，且丢失上述两个语义。

### 2.4 取不到锁的处理

另一个 session 持锁时，内层获取失败 → 抛 `GenerateSkipException`（附原因："B2 生成锁被占"）。

复用本 PR 已建立的降级约定：`generate_batch` 只捕 `GenerateSkipException`，抛别的异常会中止整轮 sweep 并在 B4 常驻进程里一路冒泡。**不新增失败模式。**

无锁的直调方跑整轮时，每只股票都会干净跳过 —— 保守且正确。

### 2.5 临界区不包住早退路径

真库当前状态（`stock_coverage` 空表）下每只股票都在覆盖行检查处提前 skip，**那条路径连锁都不碰**，零额外开销。这也是把锁放在写入临界区而非函数入口的原因。

---

## 3. 明确不做

- **不重建两阶段发布**（唯一 temp 路径 → 赢得登记后才发布）。这是计划 PF2-R3 的设计，被 PF2-R4 攻掉（造出「数据库行先于产物可见」→ `uq_stock_start` 占死 → B3 反复预定却 404 的**永久卡死行**，严格更糟），PF2-R5 据此拆除并回到「先写文件后登记」（崩溃窗口 = 孤儿 zip + 无数据库行，**自愈**）。
  本设计采纳 codex R1-F2 建议的前半句（`Centralize the generation lock inside the public generation entrypoint`），**不采纳**后半句（`or change publishing so each attempt writes to a unique temp/final path`）。
- **不加 feature flag 门控 B2/B4**（codex R1-F1）。当前 fail-closed skip 在效果上已等价于「未启用」；user 2026-07-18 裁决保持范围。
- **不改 schema、不改状态机、不新增 `building` 状态。**
- 不动 `assemble_from_windows` / `_register_training_set` 各自的内部逻辑。

---

## 4. 失败模式分析

| 场景 | 行为 |
|---|---|
| CLI / 调度器（已持外层锁） | 内层可重入获取成功 → 行为与今天完全一致 |
| 直调方，无人竞争 | 内层获取成功 → 正常产出 |
| 直调方，另一 session 持锁 | 内层获取失败 → `GenerateSkipException` → 该股跳过，整轮继续 |
| 临界区内抛异常 | `finally` 释放锁；已有的 orphan 清理逻辑不变 |
| 临界区内进程崩溃 | session 断开 → PG 自动释放 advisory lock；磁盘留孤儿 zip + 无数据库行 = **自愈**（PF2-R5 已论证） |
| 解锁本身失败 | 与既有两处外层锁同构；不在本次范围内改变该语义 |

---

## 5. 测试要求

### 5.1 新增覆盖

1. **临界区互斥**：另一 session 持锁时，直调 `generate_one_training_set` 抛 `GenerateSkipException`，且**不产出任何文件、不登记任何行**。
2. **可重入不误伤**：已持锁的 session 调用能正常产出（锁计数配对、无泄漏）。
3. **异常路径释放锁**：临界区内抛异常后锁被释放（后续获取能成功）。
4. **早退路径不取锁**：覆盖行缺失时跳过，**不发生任何 advisory lock 查询**（守 2.5 的零开销主张）。

### 5.2 mutation 验证（硬性）

每条新测试必须做 mutation：删掉内层锁获取 / 把失败分支改成继续执行 / 删掉 `finally` 释放 —— 确认**期望的那条测试**变红且**失败原因正是要守的那件事**。

⚠️ 本项目有伪证前科（探针被外键先拦下、约束删了仍全绿）。`_FakeConn` 是自写的，尤须确认红/绿取决于**生产代码**而非 FakeConn 自身行为。

### 5.3 已知实施坑（现已探明，不留给实施者踩）

集成测里有 **23 处直接调用 `generate_one_training_set`**，其 `_FakeConn.fetchval`（`test_b2_reconnect_integration.py:155`）目前只认 `INSERT INTO training_sets`，其余一律 `raise AssertionError(未预期的 fetchval)`。

**加了内层锁，这 23 处会全线爆掉。** 与 Task 5「加锁打挂 3 个 scheduler 测试」同形状（那次靠 dry-run 才发现）。

因此 `_FakeConn` 必须先支持 advisory lock 查询，且**要把锁的取放记入可断言的状态**（否则新防线自身没有覆盖，又成一处 vacuous）。

### 5.4 真 PG 验证（地基已坐实，非 CI 门禁）

2.2 的可重入 / 计数 / 互斥语义此前只是基于 PostgreSQL 文档的推导。`_FakeConn` 建模的是「锁永远能拿到」，验的是**生产代码的控制流**（取锁失败走哪个分支、`finally` 是否释放）——验不了 PostgreSQL 服务器本身是否真按文档描述的语义加锁。

现已用 `backend/scripts/verify_advisory_lock_reentrancy.py` 在真 `postgres:15.12` 上跑通两条裸连接，四条断言全部 PASS：

1. **可重入**：同一连接连续两次 `pg_try_advisory_lock` 均返回 `true`。
2. **计数**：取锁 2 次、仅 unlock 1 次后，另一连接仍拿不到锁（未过早释放）。
3. **配对释放后可用**：两次 unlock 后，另一连接能成功获取（互斥确实解除，不是永久占死）。
4. **跨连接互斥**：A 持锁期间，B 直接 `pg_try_advisory_lock` 返回 `false`（锁确实生效）。

这坐实了 2.2 可重入性论证的地基假设——`_FakeConn` 仅用于单测控制流覆盖，可重入 / 计数 / 互斥这三条语义本身的真实性由本脚本在真 PG 上实测确认，不再是纯理论推导。**未覆盖**：完整生产链（真实 `asyncpg` + `generate_one_training_set` 全流程调用栈）在真 PG 下端到端跑通——脚本验的是独立裸连接，不经过生产代码路径；这部分仍待 Plan 3 或专门的容器化集成验证。

---

## 6. 成功标准

- 后端全套 pytest 绿，0 failed / 0 skipped，测试数只增不减。
- 5.1 四条覆盖全部落地，5.2 mutation 全部确认。
- 既有 4 条锁测试（CLI 成功 / CLI 异常释放 / CLI 被拒 / 调度器被拒）保持绿，语义不变。
- 直调路径的互斥由**代码**强制，不再依赖调用方纪律 → PR body「当前局限」中该条残留可删除。
- 重跑 codex `--scope branch-diff`。

---

## 7. 风险

收尾期改动生产代码的并发语义。缓解：改动面窄（不碰 schema / 状态机 / 不新增状态）、可重入保证既有路径行为不变（该假设已由 5.4 的 `verify_advisory_lock_reentrancy.py` 在真 PG 15.12 上实测坐实，不再是纯理论推导；`_FakeConn` 仅用于单测控制流）、每步 mutation 验证、`_FakeConn` 的坑已提前探明。

**codex 未必因此 approve**：它 R1-F2 的建议是「集中锁 **或** 改发布方式」，本设计采纳前者、仍拒后者。若下轮继续坚持两阶段发布，属已接受 residual 复述，按停止规则处理并如实记录，不硬凑 approve。
