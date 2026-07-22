# B2 生成锁下沉到写入临界区 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `B2_GENERATION_LOCK_KEY` 从调用方下沉到 `generate_one_training_set` 的写入临界区，让「不得覆写已登记产物」这条数据耐久性不变量由**代码**强制，而非依赖调用方纪律。

**Architecture:** 在 `generate_one_training_set` 内部用锁包住「装配 → 两道冲突检查 → 登记」这一段，用完立即释放。依据 PostgreSQL session 级 advisory lock 的**可重入计数**语义，已持锁的 CLI/调度器路径内层获取必然成功，行为零变化。外层两处锁保留（提供整轮独占 + 用户可见的拒绝语义）。取不到锁 → `GenerateSkipException`，干净跳过不中止 sweep。

**Tech Stack:** Python 3.11（pytest 8.4.2 / pandas 2.2.3）、PostgreSQL advisory lock、asyncpg（生产）/ 假 conn（测试）。

**Spec:** `docs/superpowers/specs/2026-07-20-b2-generation-lock-descent-design.md`

## Global Constraints

- **Python 解释器**：必须用仓库根 `.venv`（Python 3.11.15）。host `python3` 是 3.14.6，**跑 pandas 会段错误**。所有 pytest 一律 `cd backend && ../.venv/bin/python -m pytest ...`。
- **基线**：分支 `qmt-plan2b-b2-reconnect` @ `3a84d6a` = **243 passed / 0 failed / 0 skipped**。任务结束时测试数只增不减。
- **CI 禁 skip**：`.github/workflows/backend-tests.yml` 解析 junit XML，**任何 `skipped>0` 即 fail**。禁止新增 `pytest.mark.skip` / `xfail` / 条件 skip。
- **负向断言禁 `! grep`**：用 `if grep -q ...; then exit 1; fi`（`set -e` 下 `! grep` 会死闸门）。
- **管道吞退出码**：`cmd 2>&1 | tail` 拿到的是 `tail` 的退出码。用 `set -o pipefail` 并显式打印退出码。
- **git 纪律**：禁止 `git checkout` / `git switch` / `git stash` / `git rebase` / `git reset`（共享主仓）。mutation 恢复用精确 Edit 还原。每条闸门命令同时打印 `git branch --show-current` 与 `git rev-parse --short HEAD`。`git add` 只加明确路径，不用 `git add -A`。
- **诚实义务**：禁止在 commit message / 注释 / 文档写「B4 补货已恢复」「库存已可生成」「训练组已能产出」类表述。
- **外层两处锁不动**：`generate_training_sets.py:616-624`（`_amain`）与 `app/scheduler.py:158-166`（`_gen`）保持原样。
- **不重建两阶段发布**：不引入唯一 temp 路径 / 赢得登记后才发布（PF2-R3 设计，已被 PF2-R4 攻掉、PF2-R5 论证拆除更优）。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `backend/generate_training_sets.py`（改） | `generate_one_training_set` 内新增写入临界区加锁/释放 |
| `backend/tests/test_b2_reconnect_integration.py`（改） | `_FakeConn` 支持 advisory lock 查询并记录取放；新增 4 条锁语义测试 |

---

## Task 1: `_FakeConn` 支持 advisory lock（先行，否则 23 处直调全爆）

**为什么先做**：集成测有 **23 处**直接调用 `generate_one_training_set`，其 `_FakeConn.fetchval`（`test_b2_reconnect_integration.py:155`）只认 `INSERT INTO training_sets`，其余一律 `raise AssertionError(_FakeConn 收到未预期的 fetchval)`。Task 2 加了内层锁后这 23 处会全线爆掉。与 Task 5「加锁打挂 3 个 scheduler 测试」同形状（那次靠 dry-run 才发现）。

本 Task **只动测试基建，不动生产代码**，结束时 243 passed 不变（纯增能力、无行为变化）。

**Files:**
- Modify: `backend/tests/test_b2_reconnect_integration.py`（`_FakeConn.fetchval`，约 155 行起）

**Interfaces:**
- Consumes: 无
- Produces: `_FakeConn` 新增两个可断言属性 —— `lock_calls: list[str]`（按序记录 `"lock"` / `"unlock"`）、`lock_held_by_other: bool`（默认 `False`；置 `True` 模拟另一 session 持锁 → `pg_try_advisory_lock` 返回 `False`）。Task 2 的测试依赖这两个名字。

- [ ] **Step 1: 给 `_FakeConn.__init__` 加两个字段**

在 `_FakeConn.__init__` 末尾追加（读实际源码确认 `__init__` 现有字段后追加，不要改动既有字段）：

```python
        self.lock_calls: list[str] = []      # 按序记录 "lock" / "unlock"
        self.lock_held_by_other = False      # True = 模拟另一 session 持锁
```

- [ ] **Step 2: 在 `fetchval` 顶部处理 advisory lock 查询**

在 `async def fetchval(self, query: str, *args):` 的**第一行**插入（必须在 `INSERT INTO training_sets` 分支**之前**）：

```python
        if "pg_try_advisory_lock" in query:
            if self.lock_held_by_other:
                return False
            self.lock_calls.append("lock")
            return True
        if "pg_advisory_unlock" in query:
            self.lock_calls.append("unlock")
            return True
```

- [ ] **Step 3: 确认 `execute` 也能吃解锁语句**

生产代码可能用 `conn.execute("SELECT pg_advisory_unlock($1)", ...)`（既有两处外层锁就是这么写的）而非 `fetchval`。读 `_FakeConn` 是否有 `execute` 方法：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer" && grep -n "async def execute" backend/tests/test_b2_reconnect_integration.py
```

若**存在** `execute` 且会对未预期 SQL 抛断言 → 同样加 `pg_advisory_unlock` 分支并 `self.lock_calls.append("unlock")`。
若**不存在** `execute` → 不新增（Task 2 将统一用 `fetchval` 发解锁语句，见 Task 2 Step 3）。
把实际情况记进报告。

- [ ] **Step 4: 跑全套确认零行为变化**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && set -o pipefail && ../.venv/bin/python -m pytest tests/ -q 2>&1 | tail -2; echo "EXIT=$?"
```

期望：`243 passed`、`EXIT=0`。本 Task 未动生产代码，数字必须不变。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer" && git add backend/tests/test_b2_reconnect_integration.py && git commit -m "测试基建：_FakeConn 支持 advisory lock 查询并记录取放次序

为 B2 生成锁下沉做准备。23 处直调 generate_one_training_set 的测试在
内层加锁后会撞 _FakeConn 未预期 SQL 断言（与 Task 5 加锁打挂 scheduler
测试同形状），故先行扩能力。新增 lock_calls / lock_held_by_other 两个
可断言属性。本提交不动生产代码，243 passed 不变。"
```

---

## Task 2: 锁下沉到写入临界区 + 四条语义测试

**Files:**
- Modify: `backend/generate_training_sets.py:531-554`（`generate_one_training_set` 的装配→登记段）
- Modify: `backend/tests/test_b2_reconnect_integration.py`（文件末尾追加 4 条测试）

**Interfaces:**
- Consumes: Task 1 的 `_FakeConn.lock_calls` / `_FakeConn.lock_held_by_other`
- Produces: `generate_one_training_set` 在临界区内取不到锁时抛 `GenerateSkipException`，消息含 `"B2 生成锁"`；成功路径 `lock_calls == ["lock", "unlock"]`

- [ ] **Step 1: 写失败测试（4 条，追加到 `test_b2_reconnect_integration.py` 末尾）**

```python
# ===== B2 生成锁下沉到写入临界区（codex R1-F2 收敛；spec 2026-07-20）=====
# 不变量：任一时刻最多一个 DB session 处于「向确定性最终路径写入并登记」的临界区。
# 此前该不变量靠**调用方纪律**维持（CLI _amain / 调度器 _gen 各自在外层取锁），
# 直调 generate_one_training_set / generate_batch 的路径零防御。

def test_write_critical_section_acquires_and_releases_lock(tmp_path):
    """成功产出时，临界区必须恰好取一次锁、放一次锁（配对，无泄漏）。"""
    conn, _ = _fixture_conn()
    gts = asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                                random.Random(7)))
    assert gts is not None
    assert conn.lock_calls == ["lock", "unlock"], (
        f"临界区锁取放不配对：{conn.lock_calls}")


def test_write_blocked_when_another_session_holds_lock(tmp_path):
    """另一 session 持锁 → 干净跳过，且**不产出任何文件、不登记任何行**。
    必须是 GenerateSkipException（generate_batch 只捕这个；抛别的会中止整轮 sweep
    并在 B4 常驻进程里一路冒泡）。"""
    conn, _ = _fixture_conn()
    conn.lock_held_by_other = True
    with pytest.raises(GenerateSkipException, match="B2 生成锁"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.registered == [], "被锁拒绝时不得登记任何行"
    assert list(tmp_path.iterdir()) == [], "被锁拒绝时不得留下任何产物"


def test_lock_released_even_when_registration_conflicts(tmp_path):
    """临界区内走异常分支（登记撞 ON CONFLICT）后，锁仍须被释放——
    否则 session 级 advisory lock 泄漏会永久挡住后续所有生成。"""
    conn, _ = _fixture_conn()
    conn.steal_first_insert = True          # 模拟并发赢家抢先登记
    with pytest.raises(GenerateSkipException):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.lock_calls == ["lock", "unlock"], (
        f"异常路径未释放锁（泄漏）：{conn.lock_calls}")


def test_early_skip_path_does_not_touch_lock(tmp_path):
    """早退路径（无 stock_coverage 覆盖行）在临界区之前就返回，**不得取锁**。
    这是 spec §2.5 的零开销主张：真库当前每只股票都走这条路，
    若这里取锁 = 每轮 sweep 白白多上千次 advisory lock 往返。"""
    days = _trading_days(dt.date(2022, 1, 3), 1000)
    conn = _FakeConn("000001.SZ", _pg_fixture(dt.date(2022, 1, 3), 1000), None)
    with pytest.raises(GenerateSkipException, match="stock_coverage"):
        asyncio.run(generate_one_training_set(conn, "000001.SZ", tmp_path,
                                              random.Random(7)))
    assert conn.lock_calls == [], (
        f"早退路径不应触碰锁，实际：{conn.lock_calls}")
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q -k "lock" 2>&1 | tail -20
```

期望：前 3 条 FAIL（`lock_calls == []` 因为生产代码还没取锁；第 2 条不抛 `B2 生成锁`），第 4 条 `test_early_skip_path_does_not_touch_lock` **已 PASS**（当前就没取锁）。
若第 4 条也 FAIL，停下报告——说明 `_FakeConn` 或早退路径与预期不符。

- [ ] **Step 3: 生产代码加锁**

把 `backend/generate_training_sets.py` 中从 `gts = assemble_from_windows(` 到 `return gts` 这一整段（现 531-554 行）替换为：

```python
    # **写入临界区加锁**（codex R1-F2 收敛；spec 2026-07-20）。
    # 不变量 = 任一时刻最多一个 session 处于「写确定性最终路径 + 登记」的临界区。
    # 此前该不变量只靠调用方纪律（_amain / _gen 各自在外层取锁），直调本函数
    # 或 generate_batch 的路径零防御 → 输家会覆写赢家已登记的 zip、content_hash 失配。
    #
    # PG session 级 advisory lock 是**可重入计数**的：已持锁的 CLI / 调度器
    # 在此再取同一把锁必然成功（计数 +1），配对释放，故既有两条路径行为零变化。
    # 外层两处锁保留——它们提供整轮 sweep 独占 + 用户可见的拒绝语义（CLI 退出码 1 /
    # 调度器 warning 本轮产 0），这两样内层给不了。
    #
    # 早退检查（覆盖行 / bars / 交叉校验 / 选窗口）全部在此**之前**完成，故真库
    # 当前"每股都跳过"的状态下这段根本不执行，零额外往返（spec §2.5）。
    if not await conn.fetchval("SELECT pg_try_advisory_lock($1)",
                               B2_GENERATION_LOCK_KEY):
        raise GenerateSkipException(
            f"{stock_code}: B2 生成锁被占（另一个 B2 正在写入），跳过")
    try:
        # 顺序 = **先写文件、后登记**（codex PF2-R4 后简化；见计划文末 PF2-R5 决议）。
        # 崩溃窗口 = 写完 zip、登记前进程死 → **孤儿 zip + 无数据库行**，它是**自愈**的：
        # 没有行引用它、exclude_starts 也不含该起点 → 下次 sweep 可重选同一起点、
        # 覆盖它并登记成功。（反之「先登记后发布」留下的是 uq_stock_start 被占、
        # B3 反复预定却 404 的**永久卡死行**，严格更糟。）
        gts = assemble_from_windows(output_dir, stock_code=stock_code,
                                    stock_name=_stock_name_of(stock_code),
                                    start_datetime=int(start_datetime),
                                    end_datetime=int(after_end), windows=windows)

        # 预检：候选已按 exclude_starts 过滤，这条只是省掉常见情形下的一次白建 zip。
        # **不删最终路径文件**（codex Task 5 review-Important：与下面第二道检查同语义）——
        # `gts.path` 是 `{code}_{start}` 确定性最终路径，若并发写者已经用同一
        # (stock_code, start_datetime) 抢先注册，这里命中的正是**对方已登记的那个文件**；
        # unlink 会把 training_sets 里那一行的 file_path 变成指向不存在的文件
        # （数据丢失，实测复现）。只跳过，不删。
        if await _exists_start(conn, stock_code, gts.start_datetime):
            raise GenerateSkipException(
                f"{stock_code}: start {gts.start_datetime} 已登记，跳过")

        # ON CONFLICT DO NOTHING = 廉价保险：唯一冲突返回 None 而非抛
        # UniqueViolationError（后者不被 generate_batch 捕获 → 中止整轮 sweep）。
        # 此时不删最终路径的文件（可能是对方的产物），只干净跳过。
        row_id = await _register_training_set(conn, gts)
        if row_id is None:
            raise GenerateSkipException(
                f"{stock_code}: start {gts.start_datetime} 已登记（并发 CLI？），跳过")
        return gts                   # 中间 .db 从不落在 output_dir，无需清理
    finally:
        await conn.fetchval("SELECT pg_advisory_unlock($1)", B2_GENERATION_LOCK_KEY)
```

**注意**：解锁用 `conn.fetchval` 而非 `conn.execute`（`pg_advisory_unlock` 有返回值；且 Task 1 的 `_FakeConn` 在 `fetchval` 上记录取放）。若 Task 1 Step 3 发现 `_FakeConn` 也有 `execute` 且已加分支，仍统一用 `fetchval`，保持记录路径唯一。

- [ ] **Step 4: 跑测试确认通过**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && set -o pipefail && ../.venv/bin/python -m pytest tests/ -q 2>&1 | tail -2; echo "EXIT=$?"
```

期望：`247 passed`（243 + 4）、0 failed、0 skipped、`EXIT=0`。

若既有 4 条锁测试（`test_cli_refuses_when_b2_lock_held` / `test_amain_acquires_and_releases_b2_lock_on_success` / `test_amain_releases_b2_lock_even_if_generate_batch_raises` / `test_gen_adapter_returns_zero_when_b2_lock_held`）有任何一条变红，**停下报告**——那说明外层/内层锁交互与可重入假设不符，不要改断言凑绿。

- [ ] **Step 5: mutation 验证（硬性，三条）**

每条：改坏 → 跑 → 确认**期望的那条测试**变红且失败原因正是要守的那件事 → 精确 Edit 恢复 → `git diff --stat` 确认为空。

**M1 删掉锁获取**：把 `if not await conn.fetchval("SELECT pg_try_advisory_lock($1)", B2_GENERATION_LOCK_KEY):` 及其 `raise` 两行删除（保留 `try`/`finally`）。
期望：`test_write_critical_section_acquires_and_releases_lock` 与 `test_write_blocked_when_another_session_holds_lock` 变红。

**M2 拿不到锁却继续执行**：把 `raise GenerateSkipException(f"{stock_code}: B2 生成锁被占...")` 改成 `pass`。
期望：`test_write_blocked_when_another_session_holds_lock` 变红（会产出文件/登记行）。

**M3 删掉 `finally` 释放**：把 `finally:` 块整个删除（`try:` 改回普通顺序执行）。
期望：`test_write_critical_section_acquires_and_releases_lock` 与 `test_lock_released_even_when_registration_conflicts` 变红（`lock_calls` 少了 `"unlock"`）。

⚠️ 本项目有**伪证前科**（探针被外键先拦下、约束删了仍全绿）。`_FakeConn` 是自写的，**必须确认红/绿取决于生产代码而非 FakeConn 自身行为**——每条 mutation 后确认失败断言指向的正是那条不变量。

- [ ] **Step 6: 收尾负向断言**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && if grep -rnE "pytest\.mark\.skip|pytest\.skip|xfail" backend/tests/; then echo "FAIL: skip/xfail"; exit 1; fi; echo "OK skip/xfail=0"; if grep -rn "NotImplementedError" backend/generate_training_sets.py backend/app/scheduler.py; then echo "FAIL: 停用残留"; exit 1; fi; echo "OK NotImplementedError=0"
```

期望：两条 OK。

- [ ] **Step 7: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer" && git add backend/generate_training_sets.py backend/tests/test_b2_reconnect_integration.py && git commit -m "B2 生成锁下沉到写入临界区（codex R1-F2 收敛）

不变量「不得覆写已登记产物」此前只靠调用方纪律维持（_amain / _gen 各自
外层取锁），直调 generate_one_training_set / generate_batch 的路径零防御。
现把锁下沉到「装配→两道冲突检查→登记」临界区，由代码强制。

PG session 级 advisory lock 可重入计数 → 已持锁的 CLI/调度器内层获取必然
成功，既有两条路径行为零变化；外层两处锁保留（整轮独占 + 用户可见拒绝语义）。
取不到锁抛 GenerateSkipException，干净跳过不中止 sweep。
早退路径在临界区之前返回，不取锁（零额外往返）。

采纳 codex R1-F2 建议前半句（集中锁到生成入口），不采纳后半句（两阶段发布，
已被 PF2-R4 攻掉、PF2-R5 论证拆除更优）。

新增 4 条锁语义测试 + 3 条 mutation 验证（删获取 / 拒绝后继续 / 删 finally）。"
```

---

## Task 3: 更新 PR body 与验收清单

**Files:**
- Modify: `.superpowers/sdd/PR-body-qmt-plan2b.md`（「当前局限」节）
- Modify: `docs/acceptance/2026-07-18-qmt-plan2b-b2-reconnect.md`（测试计数 + L3 局限）

**Interfaces:**
- Consumes: Task 2 落地后的实际测试总数
- Produces: 无（文档收尾）

- [ ] **Step 1: 实测最终计数**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/backend" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && set -o pipefail && ../.venv/bin/python -m pytest tests/ -q 2>&1 | tail -2 && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q 2>&1 | tail -2
```

把两个实测数字记下来。**不要用计划里的预期数字**（本项目文字数字已连错八次，一律以实测为准）。

- [ ] **Step 2: 改 PR body 的「当前局限」**

在 `.superpowers/sdd/PR-body-qmt-plan2b.md` 中，删除以「**另一条已知残留（codex R1-F2，经评估维持既有架构决策）**」开头的整段（含其后解释两阶段发布为何不做的那段），替换为：

```markdown
**codex R1-F2 已收敛**：`assemble_from_windows` 写确定性最终路径这件事本身未变，但**写入临界区（装配 → 两道冲突检查 → 登记）现由 `B2_GENERATION_LOCK_KEY` 在 `generate_one_training_set` 内部强制互斥**，不再依赖调用方纪律 —— 绕开 CLI / 调度器直接调用 `generate_one_training_set` / `generate_batch` 的路径同样受保护。PG session 级 advisory lock 可重入计数保证既有两条路径行为零变化。

不重建两阶段发布（唯一 temp 路径 → 赢得登记后才发布）：该设计是计划 PF2-R3 的方案，被 PF2-R4 攻掉（造出「数据库行先于产物可见」→ `uq_stock_start` 占死 → B3 反复预定却 404 的**永久卡死行**，严格更糟），PF2-R5 据此拆除并回到「先写文件后登记」（崩溃窗口 = 孤儿 zip + 无数据库行，**自愈**）。本次采纳 codex 建议的前半句（集中锁到生成入口），不采纳后半句。
```

- [ ] **Step 3: 改验收清单**

在 `docs/acceptance/2026-07-18-qmt-plan2b-b2-reconnect.md`：

1. 第 1 条的期望数字改为 Step 1 实测的全套数字；第 2 条改为实测的集成测数字。
2. L3 那一行的说明整体替换为：

```markdown
| L3 | **并发竞态已由锁强制** | 本 PR 修了一处并发下会删掉他人已登记产物的缺陷，并把生成的写入临界区用 `B2_GENERATION_LOCK_KEY` 强制互斥（不再只靠「调用方记得先取锁」）。该竞态在两条受支持入口下本就被挡住，锁下沉是让直接调用底层函数的路径也受保护。未在真 PostgreSQL 上验证过 advisory lock 的实际行为（见 L2）。 |
```

- [ ] **Step 4: 禁语自查**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer" && echo "branch=$(git branch --show-current) HEAD=$(git rev-parse --short HEAD)" && if grep -rnE "B4 ?补货已(恢复|打通)|库存已可生成|训练组已能产出|已恢复出货" docs/acceptance/2026-07-18-qmt-plan2b-b2-reconnect.md .superpowers/sdd/PR-body-qmt-plan2b.md; then echo "FAIL: 过度宣称"; exit 1; fi; echo "OK 无过度宣称"
```

期望：`OK 无过度宣称`。

- [ ] **Step 5: 提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer" && git add docs/acceptance/2026-07-18-qmt-plan2b-b2-reconnect.md && git commit -m "验收清单：测试计数同步实测 + L3 改为「并发竞态已由锁强制」

锁下沉后 L3 不再是「靠调用方纪律」的残留。PR body 同步更新
（.superpowers/ 为 gitignore，不入库）。"
```

---

## Self-Review

**Spec 覆盖核对**：

| Spec 条目 | 覆盖 |
|---|---|
| §2 锁下沉到写入临界区 | Task 2 Step 3 |
| §2.2 可重入（既有路径零变化） | Task 2 Step 4 的「既有 4 条锁测试须保持绿」硬性检查 |
| §2.3 外层两处锁保留 | Global Constraints 明列「外层两处锁不动」 |
| §2.4 取不到锁 → GenerateSkipException | Task 2 Step 1 的 `test_write_blocked_when_another_session_holds_lock` |
| §2.5 早退路径不取锁 | Task 2 Step 1 的 `test_early_skip_path_does_not_touch_lock` |
| §3 不做两阶段发布 / 不加 feature flag | Global Constraints 明列 |
| §5.1 四条新增覆盖 | Task 2 Step 1（四条一一对应） |
| §5.2 mutation 验证 | Task 2 Step 5（M1/M2/M3） |
| §5.3 `_FakeConn` 坑 | Task 1（整个 Task 为此存在） |
| §6 成功标准（PR body 残留可删） | Task 3 |

**Placeholder 扫描**：无 TBD / TODO；每个改代码的 Step 都给了完整代码块；mutation 三条各自写明改法与期望红的测试名。

**类型一致性**：Task 1 Produces 的 `lock_calls: list[str]` / `lock_held_by_other: bool` 与 Task 2 测试中使用的 `conn.lock_calls` / `conn.lock_held_by_other` 一致；`B2_GENERATION_LOCK_KEY` 在 `generate_training_sets.py:51` 已定义（同文件内，无需 import）；`GenerateSkipException` / `_fixture_conn` / `_FakeConn` / `_pg_fixture` / `_trading_days` 均为既有名字。

**风险点已在计划内显式处理**：Task 2 Step 4 明确要求既有 4 条锁测试若变红须停下报告而非改断言凑绿——这是可重入假设万一不成立时的唯一发现路径。
