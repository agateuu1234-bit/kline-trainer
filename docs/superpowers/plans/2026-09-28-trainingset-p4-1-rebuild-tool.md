# 切片一 P4 片 1：重建工具（R2 重建入口）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 造一个可复跑的「重建入口」，用**生产口径**、**钉死的起点**，从**只读**的源库产出 3 个训练组包与一份机器可读清单，并自证「连跑两次字节完全相同」与「整个过程没往源库写一个字节」。

**Architecture:** 不新写任何窗口 / 索引 / 装配逻辑。做法是**把候选起点收成一个**，然后调用与生产**完全同一个**纯入口 `build_training_windows` —— 于是 D6（每周期前后根数）与 D9（盘中逐日完整）两道门照样跑、窗口口径与生产逐字一致。读库与门控输入那一段从 `generate_one_training_set` **提取**成共用函数 `load_gating_inputs`，两个调用方共用同一份，杜绝「两份实现各自漂移」——那正是本切片要修的根缺陷。产出只经纯装配入口 `assemble_from_windows`（不碰 PostgreSQL），⛔ 绝不调 `_register_training_set`。

**Tech Stack:** Python 3.11 · pandas · asyncpg（生产路径）· pglast 7.13（解析既有 SQL 取旧值）· pytest。测试用仓内既有的 `_FakeConn` 假连接 + `gen_valid_sources` → `build_stock_import` 造出的**真** bundle，不需要真 PostgreSQL。

**Spec:** `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md`
本片覆盖其 **§3.4 的 R2**（含 ⓐⓑⓑ2ⓒ 四条硬约束）、**§7 判据 9**（确定性自证 + 源库只读 + 起点一致）、**§3.4 R3 的次序约束**（旧七元组必须在重新生成 P11 之前快照）。
⛔ 本片**不**覆盖 R0 / R1 / R3 / R4 / R5 / R6 / R7，也不覆盖崩溃恢复演练与任何文档订正 —— 那些在片 2 与片 3。

---

## Global Constraints

本节的每一条，都隐含地是下面每个 Task 的验收要求。

**范围与禁区**

- ⛔ 本片**不碰生产**：不连 NAS、不动 NAS 上任何文件或数据库、不启动 `qmt-trial` 容器本体、不启回 `api` / `scheduler` / 生成器 CLI。
- ⛔ 本片产出的代码**不得**调用 `_register_training_set`，**不得**取 `B2_GENERATION_LOCK_KEY`，**不得**对源库执行任何 `INSERT` / `UPDATE` / `DELETE` / DDL。
- ⛔ 不写入 `~/qmt_trial_out/` —— 那是 v1 审计归档，逐字节不得改动。
- ⛔ 不用 `git stash`；⛔ 不用 `git checkout <文件>` 复原变异（那会连未提交的工作一起毁掉）；复原一律靠重新编辑或 `git restore --source=HEAD --worktree <文件>` 之外的显式手段。
- 工作目录固定为 worktree `.dev/worktree/trainingset-p4-1`（分支 `feat/trainingset-p4-1-rebuild-tool`，base = `origin/main`）。⛔ 不在主 checkout 里改任何东西。

**写死的权威值（spec §3.4 R2 ⓑ / ⓑ2；取自 `docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql:39-45`）**

| stock_code | start_datetime | 期望 end_datetime |
|---|---|---|
| `000001.SZ` | `1756656000` | `1777996799` |
| `600519.SH` | `1762099200` | `1782835199` |
| `000001.SZ` | `1762099200` | `1782835199` |

**产物口径**

- `schema_version` 一律取模块常量 `SCHEMA_VERSION`（当前 = `2`），⛔ 不得在本片任何地方写字面量 `2`。
- 清单里的 `file_path` 用**容器内路径**：`/data/training-sets/<stock_code>_<start_datetime>.zip`（与 p11 SQL 里那三行一致）。
- `stock_name` 一律经 `_stock_name_of(stock_code)` 取得（它返回 code 本身），⛔ 不得另写一份。

**工程纪律（全部来自本仓记过的教训）**

- **变异前必须先证明变异真的落到文件里了**：改完之后把那一行读回来打印确认，或数锚点命中次数。⛔ 「以为改了其实没改」在本仓已发生三次。
- **计数类检查要警惕「含自身」**：扫描可能命中你自己写在注释或文档里的那句话。
- **报「0 条违反」之前，必须先证明它能报出非 0**（正向对照：故意造一条违反，看它红）。
- 跑变异前清字节码缓存并禁止生成：`find . -name __pycache__ -type d -exec rm -rf {} +` 且 `PYTHONDONTWRITEBYTECODE=1`。
- 判绿看**输出内容与执行量**，不看「成功」字样；⛔ 别用 `| tail` 接长命令；⛔ 扫描输出绝不截断；⚠️ 这台 Mac 上**没有** `timeout` 命令。
- 后端 CI 是 **Linux** 且**零容忍 skip**；测试的 `import` 不得依赖 `backend/requirements-test.txt` 之外的包。

**怎么跑测试**

先把解释器路径存成一个变量（下面每条命令都用它）：

```
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
```

⚠️ 用这个**绝对路径**，⛔ 不要写相对路径 —— 从 `.dev/worktree/<名字>/backend` 回到仓根是**四级**不是三级，写错会静默拿到系统的 python（那里**没有** `pglast`）。

```
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/trainingset-p4-1/backend" && \
  PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q -rs
```

（`backend/tests/__init__.py` 会把 `backend/` 注入模块搜索路径，所以必须在 `backend/` 目录下跑。）

**评审与提交**

- ⛔ 推送、开 PR、合并一律由 user 在自己终端执行（仓内守卫拦开发者）。
- 评审通道只有 `codex:adversarial-review`，以 attest 形式调用；**attest 必须是最后一步**，之后再提交任何东西账本就失配、得重跑。

---

## File Structure

| 文件 | 职责 | 动作 |
|---|---|---|
| `backend/generate_training_sets.py` | 生成器。本片只做**一处纯提取**：把「读库 → 门控输入」那段抽成 `load_gating_inputs`，`generate_one_training_set` 改为调它。行为零变化。 | 修改（Task 1） |
| `backend/rebuild_training_sets.py` | **新建**。重建入口：钉死起点 → 复用生产纯入口 → 右端断言 → 纯装配 → 清单。含只读守卫与确定性自证。 | 新建（Task 2–5） |
| `backend/tests/test_rebuild_training_sets.py` | **新建**。本片全部常驻测试。 | 新建（Task 2–5） |
| `backend/tests/test_generate_training_sets.py` | 既有。加一条「提取之后生产路径确实调到了共用函数」的测试。 | 修改（Task 1） |
| `docs/acceptance/2026-09-28-trainingset-p4-1-acceptance.md` | **新建**。非程序员可执行验收清单（动作 / 期望 / 通过与否）。 | 新建（Task 6） |
| `docs/acceptance/2026-09-28-trainingset-p4-1-mutation-log.md` | **新建**。变异记录：逐条写明「怎么改的 / 怎么证明改到了 / 红的是哪一条测试」。 | 新建（Task 6） |

⛔ **本片不碰**：任何 `.sql` 文件、任何 `docs/runbooks/**`、任何 `.github/workflows/**`、任何 `ios/**`。

---

### Task 1: 把「读库 → 门控输入」提取成共用函数 `load_gating_inputs`

**为什么先做这个**：重建入口需要的读库与门控输入，和生产路径**一模一样**。抄一份出来就等于亲手复制本切片要修的那个根缺陷（「两侧各写一份」）。所以先做纯提取，让两个调用方共用同一份。

**Files:**
- Modify: `backend/generate_training_sets.py:614-647`（提取）
- Test: `backend/tests/test_generate_training_sets.py`（新增 1 条）

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) class GatingInputs` 字段：`period_bars: dict[str, pd.DataFrame]`、`trading_dates: list[datetime.date]`、`dense_dates: set[datetime.date]`、`dropped: frozenset`、`month_boundaries: list[int]`
  - `async def load_gating_inputs(conn, stock_code: str) -> GatingInputs`
  - 失败一律抛既有的 `GenerateSkipException`（异常类型与消息逐字保持不变）

- [ ] **Step 1: 写失败的测试（证明提取之后生产路径真的调到了它）**

照抄仓内既有的同型写法（`backend/tests/test_generate_training_sets.py:789` 的 `test_week_end_date_is_module_level_and_shared`）。加到 `backend/tests/test_generate_training_sets.py` 末尾：

```python
def test_generate_one_training_set_uses_shared_load_gating_inputs(monkeypatch, tmp_path):
    """判据 = 提取之后，生产路径 generate_one_training_set 确实调到了模块级的
    load_gating_inputs（而不是留着一份自己的副本）。

    本切片的根缺陷就是「同一件事两边各写一份、各自漂移」，所以这条必须钉住
    【同一个函数对象】被两个调用方共用，而不只是「有这么个函数存在」。
    """
    import asyncio
    import random

    import generate_training_sets as g
    from tests._qmt_fixtures import gen_valid_sources
    from tests.test_b2_reconnect_integration import _FakeConn
    from qmt_ingest import build_stock_import

    code = "000001.SZ"
    s1, sd, e1, ed = gen_valid_sources(code)
    bundle = build_stock_import(s1, sd, stock_code=code, stock_name="平安",
                                entry_1m=e1, entry_daily=ed)
    bars = {p: pd.DataFrame(bundle.records[p]).sort_values("datetime").reset_index(drop=True)
            for p in g.PERIODS}
    cov = bundle.coverage
    conn = _FakeConn(code, bars, {
        "dense_1m_start_date": cov.start_date,
        "dense_1m_end_date": cov.end_date,
        "dropped_1m_dates": json.dumps([d.isoformat() for d in cov.dropped_dates]),
        "dense_day_count": cov.dense_day_count,
    })

    seen = []
    real = g.load_gating_inputs

    async def spy(c, sc):
        seen.append(sc)
        return await real(c, sc)

    monkeypatch.setattr(g, "load_gating_inputs", spy)
    asyncio.run(g.generate_one_training_set(conn, code, tmp_path, random.Random(0)))

    assert seen == [code], (
        f"generate_one_training_set 没有调到模块级的 load_gating_inputs（记录到 {seen}）"
        " —— 说明它还留着一份自己的读库副本，两份会各自漂移")
```

⚠️ 该测试文件顶部需要有 `import json` 与 `import pandas as pd`；先 `grep -n "^import json\|^import pandas" backend/tests/test_generate_training_sets.py` 确认，缺哪个就补哪个，⛔ 不要顺手动别的 import。

- [ ] **Step 2: 跑它，确认它是红的**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_generate_training_sets.py::test_generate_one_training_set_uses_shared_load_gating_inputs -q
```

期望：**FAIL**，报 `AttributeError: module 'generate_training_sets' has no attribute 'load_gating_inputs'`。
⛔ 如果它是绿的或报别的错，**停下来查清楚**再继续。

- [ ] **Step 3: 做提取**

在 `generate_training_sets.py` 里 `_stock_name_of` 之前插入：

```python
@dataclass(frozen=True)
class GatingInputs:
    """`generate_one_training_set` 与 P4 重建入口共用的门控输入（spec §3.1 的精神：
    同一件事只许有一份实现 —— 本切片的根缺陷正是「两侧各写一份」）。"""
    period_bars: dict
    trading_dates: list
    dense_dates: set
    dropped: frozenset
    month_boundaries: list


async def load_gating_inputs(conn, stock_code: str) -> GatingInputs:
    """读 coverage + 六周期 bars，重建交易日历并与权威天数交叉校验，求月边界。

    ⛔ **只读**：全部是 SELECT，且包在 repeatable_read + readonly 的快照事务里。
    ⛔ 不含 `_fetch_existing_starts` —— 那是生产路径独有的「起点去重」，P4 重建要的
       恰恰是【已登记的那三个起点】，带上它会把目标起点自己排除掉。
    """
    async with conn.transaction(isolation="repeatable_read", readonly=True):
        start_date, end_date, dropped, dense_day_count = await _fetch_dense_coverage(
            conn, stock_code)
        if start_date is None or end_date is None:
            raise GenerateSkipException(
                f"{stock_code}: stock_coverage 无覆盖 artifact（B1 未写入）→ 无法门控，跳过")

        period_bars = {p: await _fetch_period_bars(conn, stock_code, p) for p in PERIODS}
        for p, bars in period_bars.items():
            if bars.empty:
                raise GenerateSkipException(f"{stock_code}: {p} 无 bars")

    daily = period_bars["daily"]
    trading_dates = sorted({trading_date(int(e)) for e in daily["datetime"]})
    dense_dates = {d for d in trading_dates if start_date <= d <= end_date} - dropped
    if not dense_dates:
        raise GenerateSkipException(f"{stock_code}: dense 覆盖为空")

    # **交叉校验重建出的日历 vs 权威计数**（codex PF2-R6-F1）。
    # 上面的 trading_dates 是从**现存的 daily klines** 反推的：若带内某个交易日的
    # daily 行本身缺失（B1 半途导入 / 行丢失），那天就同时从 dense_dates 与 D9 的
    # span 里**一起消失** —— 两道门都看不见它，窗口能带着整日空洞过关。
    # dense_day_count 是 B1 写下的权威天数，对不上即 fail-closed。
    if dense_day_count is None:
        raise GenerateSkipException(
            f"{stock_code}: stock_coverage.dense_day_count 为 NULL，无法交叉校验")
    if len(dense_dates) != int(dense_day_count):
        raise GenerateSkipException(
            f"{stock_code}: dense 日历不一致——artifact 记 {dense_day_count} 天，"
            f"由 daily klines 重建出 {len(dense_dates)} 天（带内有 daily 行缺失？）")

    month_boundaries = period_boundaries(daily, "monthly")
    return GatingInputs(period_bars=period_bars, trading_dates=trading_dates,
                        dense_dates=dense_dates, dropped=frozenset(dropped),
                        month_boundaries=month_boundaries)
```

再把 `generate_one_training_set` 里原来那段（从 `# Plan 3 Task4：coverage + 六周期读包进 RR 只读快照事务` 起、到 `month_boundaries = period_boundaries(daily, "monthly")` 止）整段替换为：

```python
        gi = await load_gating_inputs(conn, stock_code)
        period_bars = gi.period_bars
        trading_dates = gi.trading_dates
        dense_dates = gi.dense_dates
        dropped = gi.dropped
        month_boundaries = gi.month_boundaries
        exclude = await _fetch_existing_starts(conn, stock_code)
```

⚠️ 原来那行 `exclude = await _fetch_existing_starts(conn, stock_code)` **保留在生产路径里**，⛔ 不要一起搬进 `load_gating_inputs`。
⚠️ 确认 `dataclass` 已在文件顶部 import（`grep -n "^from dataclasses import" backend/generate_training_sets.py`）；没有就补 `from dataclasses import dataclass`。

- [ ] **Step 4: 跑新测试 + 整个生成器套件，确认提取行为零变化**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_generate_training_sets.py tests/test_qmt_e2e_generation.py tests/test_b2_reconnect_integration.py -q -rs
```

期望：**全部 PASS，0 skipped**，且新测试那条是 PASS。
⛔ 只要有一条从绿变红，说明提取不是行为等价的，**停下来查清楚**，不得「顺手改一下测试让它过」。

- [ ] **Step 5: 变异，证明这条测试真的有判别力**

变异体：把 `generate_one_training_set` 里的 `gi = await load_gating_inputs(conn, stock_code)` 改成把 `load_gating_inputs` 的函数体**内联抄回去**（即恢复成提取前的样子）。

先证明变异真的落进文件了：

```
cd .dev/worktree/trainingset-p4-1 && grep -c "load_gating_inputs" backend/generate_training_sets.py
```

记下变异前后两个数字，写进变异记录。然后跑那一条测试，期望 **FAIL**，报「没有调到模块级的 load_gating_inputs」。
复原变异（重新编辑回去，⛔ 不用 `git checkout`），再跑一遍确认回到 PASS。

- [ ] **Step 6: 提交**

```bash
cd ".dev/worktree/trainingset-p4-1"
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "refactor: 把读库门控输入提取成 load_gating_inputs（生产与 P4 重建共用一份）"
```

---

### Task 2: 起点钉死 —— `pin_start_excludes` + `build_pinned_windows`

**为什么这么做**：生产入口 `build_training_windows` 自带 `rng.shuffle(candidates)`（`generate_training_sets.py:183`），而 CLI 的 `--seed` 默认是 `None`，等于每次用系统熵播种 ⇒ 连跑两次会选到**完全不同的三个训练组**。spec §3.4 R2 ⓑ 因此要求起点显式给定且与旧三个相同。
做法不是「绕过那个入口自己切窗口」，而是**把候选集收窄到只剩目标那一个**（`exclude_starts` 参数本来就是干这个的），于是洗牌无关紧要，而 D6 / D9 两道门照样跑。

**Files:**
- Create: `backend/rebuild_training_sets.py`
- Test: `backend/tests/test_rebuild_training_sets.py`

**合成样本的实测底数**（2026-09-28 在 `origin/main` 上用 `gen_valid_sources("000001.SZ")` → `build_stock_import` 现跑得出，⛔ 不是推测）：

| 量 | 实测 |
|---|---|
| 月边界个数 | **47** |
| 合格候选起点个数 | **4**（`1669824000` / `1672588800` / `1675180800` / `1677600000`）|
| 不合格的月边界个数 | **43** |
| 8 个不同种子选出的不同起点 | **4 个**（就是上面那 4 个）|

⇒ 下面三条用例的前提全部成立：①「不钉死时起点会变」有 ≥2 个候选可比；②「钉死后恒定」不是因为只剩一个候选而恒真；③「起点过不了门就拒绝」找得到反例（43 个）。
⚠️ 若将来 fixture 变了导致候选只剩 1 个，**不要放宽断言** —— 那会让①②两条同时变成恒真。

**Interfaces:**
- Consumes: Task 1 的 `load_gating_inputs` / `GatingInputs`
- Produces:
  - `class RebuildMismatch(Exception)`
  - `@dataclass(frozen=True) class RebuildTarget`：`stock_code: str`、`start_datetime: int`、`expected_end_datetime: int`
  - `PINNED_TARGETS: tuple[RebuildTarget, ...]`（3 个）
  - `def pin_start_excludes(month_boundaries: list[int], start_datetime: int) -> frozenset[int]`
  - `def build_pinned_windows(period_bars, month_boundaries, *, start_datetime, dense_dates, trading_dates, dropped, rng: Optional[random.Random] = None) -> tuple[int, dict]`

- [ ] **Step 1: 写失败的测试**

新建 `backend/tests/test_rebuild_training_sets.py`：

```python
# backend/tests/test_rebuild_training_sets.py
# 切片一 P4 片 1：重建入口的常驻测试。
# 「假」的只有 asyncpg conn（沿用 _FakeConn）；bundle 是真 build_stock_import 产的，
# 窗口 / 索引 / SQLite / zip / CRC32 全链路是未改动的生产代码。
from __future__ import annotations

import json
import random
import sys
from pathlib import Path

import pandas as pd
import pytest

import generate_training_sets as g
import rebuild_training_sets as r
from qmt_ingest import build_stock_import
from tests._qmt_fixtures import gen_valid_sources
from tests.test_b2_reconnect_integration import _FakeConn

_CODE = "000001.SZ"


@pytest.fixture(scope="module")
def bundle():
    s1, sd, e1, ed = gen_valid_sources(_CODE)
    return build_stock_import(s1, sd, stock_code=_CODE, stock_name="平安",
                              entry_1m=e1, entry_daily=ed)


def _conn(bundle) -> _FakeConn:
    bars = {p: pd.DataFrame(bundle.records[p]).sort_values("datetime").reset_index(drop=True)
            for p in g.PERIODS}
    cov = bundle.coverage
    return _FakeConn(_CODE, bars, {
        "dense_1m_start_date": cov.start_date,
        "dense_1m_end_date": cov.end_date,
        "dropped_1m_dates": json.dumps([d.isoformat() for d in cov.dropped_dates]),
        "dense_day_count": cov.dense_day_count,
    })


def _gating(bundle):
    import asyncio
    return asyncio.run(g.load_gating_inputs(_conn(bundle), _CODE))


def _eligible_starts(gi) -> list[int]:
    """当前 bundle 下【所有】合格候选起点（不钉死时 build_training_windows 会从中选）。"""
    idxs = g.eligible_start_indices(gi.month_boundaries, random.Random(0),
                                    dense_dates=gi.dense_dates,
                                    trading_dates=gi.trading_dates,
                                    dropped=gi.dropped)
    return sorted(int(gi.month_boundaries[i]) for i in idxs)


def test_unpinned_start_is_not_stable_across_seeds(bundle):
    """**先证明这件事真的会发生**：不钉死时，不同种子选到的起点不一样。

    ⭐ 没有这条对照，下一条「钉死后恒定」可能只是因为本 fixture 恰好只有一个候选
    —— 那样它判别力为零、却一直是绿的。
    """
    gi = _gating(bundle)
    assert len(_eligible_starts(gi)) >= 2, (
        "本 fixture 只有不到 2 个合格候选起点 ⇒ 『钉死起点』这条判据无从验证。"
        " ⛔ 不要放宽本断言，请改用能产出多候选的 fixture。")

    picked = set()
    for seed in range(8):
        start, _ = g.build_training_windows(
            gi.period_bars, gi.month_boundaries, random.Random(seed),
            dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
            before_caps=g.PERIOD_BEFORE_CAP, dropped=gi.dropped)
        picked.add(int(start))
    assert len(picked) >= 2, (
        f"8 个不同种子只选出了 {picked} 一个起点 —— 与 rng.shuffle 的存在矛盾，"
        " 请查清楚再继续")


def test_pinned_start_is_identical_across_seeds(bundle):
    """钉死之后：无论什么种子，返回的起点恒等于目标。"""
    gi = _gating(bundle)
    target = _eligible_starts(gi)[0]
    for seed in range(8):
        start, windows = r.build_pinned_windows(
            gi.period_bars, gi.month_boundaries, start_datetime=target,
            dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
            dropped=gi.dropped, rng=random.Random(seed))
        assert int(start) == target
        assert set(windows) == set(g.PERIODS)


def test_pinned_start_not_a_month_boundary_is_refused(bundle):
    """起点不是月边界 ⇒ 当场拒绝，⛔ 不得悄悄退回随机选。"""
    gi = _gating(bundle)
    with pytest.raises(r.RebuildMismatch) as ei:
        r.pin_start_excludes(gi.month_boundaries, 12345)
    assert "12345" in str(ei.value)


def test_pinned_start_that_fails_gates_is_refused(bundle):
    """起点是月边界、但过不了 D6 / D9 两道门 ⇒ 抛 RebuildMismatch，
    ⛔ 不得退回去选别的起点（那会静默产出一个不同的训练组）。"""
    gi = _gating(bundle)
    eligible = set(_eligible_starts(gi))
    bad = next((int(b) for b in gi.month_boundaries if int(b) not in eligible), None)
    assert bad is not None, "本 fixture 里每个月边界都是合格候选 ⇒ 本用例无从验证"
    with pytest.raises(r.RebuildMismatch):
        r.build_pinned_windows(
            gi.period_bars, gi.month_boundaries, start_datetime=bad,
            dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
            dropped=gi.dropped, rng=random.Random(0))
```

- [ ] **Step 2: 跑它，确认是红的**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q
```

期望：`ModuleNotFoundError: No module named 'rebuild_training_sets'`。

- [ ] **Step 3: 写最小实现**

新建 `backend/rebuild_training_sets.py`：

```python
# backend/rebuild_training_sets.py
"""切片一 P4 的 R2：按【钉死的起点】用【生产口径】重建训练组产物。

⛔ 本模块对源库**只读**：全部是 SELECT，绝不 INSERT / UPDATE / DELETE / DDL，
   也绝不调 `_register_training_set`（它是一条 INSERT INTO training_sets）。
   理由见 spec §3.4 R2 ⓐ：源库 `kline_trial` 里那 3 行是权威原始数据。

⭐ 窗口**不自己切**：把候选起点收窄到只剩目标那一个，然后调用与生产完全同一个纯入口
   `build_training_windows` —— 于是 D6（每周期前后根数）与 D9（盘中逐日完整）两道门
   照样跑，窗口口径与生产逐字一致。⛔ 直接调 `select_period_window` 会绕过这两道门。
"""
from __future__ import annotations

import random
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

from generate_training_sets import (
    PERIOD_BEFORE_CAP, SCHEMA_VERSION, GeneratedTrainingSet, GenerateSkipException,
    _stock_name_of, assemble_from_windows, build_training_windows, compute_after_end,
    load_gating_inputs,
)

#: 训练组 zip 在 api 容器内的目录（与 p11 SQL 里那三行的 file_path 一致）
CONTAINER_TRAINING_SETS_DIR = "/data/training-sets"


class RebuildMismatch(Exception):
    """重建过程中任一「与权威值对不上」的断言失败。

    ⛔ 它**不是** `GenerateSkipException`：那个的语义是「这个候选不行，换一个」，
    而本异常的语义是「停下来查清楚，不得继续」。两者混用会把停机信号降级成跳过。
    """


@dataclass(frozen=True)
class RebuildTarget:
    stock_code: str
    start_datetime: int
    expected_end_datetime: int


#: spec §3.4 R2 ⓑ/ⓑ2：起点与右端都取自旧三个产物的权威值
#: （见 docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql 的 p11_expected）
PINNED_TARGETS: tuple[RebuildTarget, ...] = (
    RebuildTarget("000001.SZ", 1756656000, 1777996799),
    RebuildTarget("600519.SH", 1762099200, 1782835199),
    RebuildTarget("000001.SZ", 1762099200, 1782835199),
)


def pin_start_excludes(month_boundaries, start_datetime: int) -> frozenset:
    """把 `build_training_windows` 的候选集收成【至多一个】。

    `exclude_starts` 在 `select_valid_window` 里是在切 `[:max_retries]` **之前**过滤的
    （见该函数 docstring），所以把「除目标外的全部月边界」塞进去，剩下的候选最多一个，
    `rng.shuffle` 从此与结果无关。
    """
    targets = {int(b) for b in month_boundaries}
    if int(start_datetime) not in targets:
        raise RebuildMismatch(
            f"起点 {start_datetime} 不是月边界（本股共 {len(targets)} 个月边界）"
            f" —— 源库数据或月边界与当初不同，⛔ 停下来查清楚，不得继续")
    return frozenset(targets - {int(start_datetime)})


def build_pinned_windows(period_bars, month_boundaries, *, start_datetime: int,
                         dense_dates, trading_dates, dropped,
                         rng: Optional[random.Random] = None):
    """起点钉死版的 `build_training_windows`。返回 `(start_datetime, windows)`。"""
    excludes = pin_start_excludes(month_boundaries, start_datetime)
    try:
        start, windows = build_training_windows(
            period_bars, month_boundaries, rng or random.Random(0),
            dense_dates=dense_dates, trading_dates=trading_dates,
            before_caps=PERIOD_BEFORE_CAP, max_retries=1,
            exclude_starts=excludes, dropped=dropped)
    except GenerateSkipException as exc:
        # 钉死之后只剩一个候选：它被门拒 ⇒ 没有「换一个」这回事。
        raise RebuildMismatch(
            f"钉死的起点 {start_datetime} 过不了门控（{exc}）"
            f" —— ⛔ 停下来查清楚，不得退回去选别的起点") from exc
    if int(start) != int(start_datetime):
        raise RebuildMismatch(
            f"钉死的起点失效：要求 {start_datetime}，实际返回 {start}")
    return int(start), windows
```

- [ ] **Step 4: 跑测试，确认全绿**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q -rs
```

期望：**4 passed, 0 skipped**。

- [ ] **Step 5: 变异（对应 spec §4 的 B55）**

变异体：把 `build_pinned_windows` 里的 `exclude_starts=excludes` 改成 `exclude_starts=frozenset()`。

先证明改到了：

```
cd .dev/worktree/trainingset-p4-1 && grep -n "exclude_starts=" backend/rebuild_training_sets.py
```

期望看到那一行已经是 `frozenset()`。跑测试，期望 `test_pinned_start_is_identical_across_seeds` **FAIL**（不同种子返回不同起点 ⇒ 断言不等）。复原，再确认回绿。

- [ ] **Step 6: 提交**

```bash
cd ".dev/worktree/trainingset-p4-1"
git add backend/rebuild_training_sets.py backend/tests/test_rebuild_training_sets.py
git commit -m "feat: 重建入口第一步——把候选起点收窄到钉死的那一个（复用生产纯入口）"
```

---

### Task 3: `rebuild_one` —— 单个训练组的重建，含右端权威值断言

**为什么这条断言最重要**：spec §3.4 R2 ⓑ2 写得很直白 —— 后面 R6 的收口闸①②③ 比的全是「产出 vs R2 自己的清单」，窗口切错、右端取错，清单跟着错，**闸门照样全绿**。`end_datetime == 旧三个的权威值` 是本步**唯一一条独立于清单自身**的判据。

**Files:**
- Modify: `backend/rebuild_training_sets.py`
- Test: `backend/tests/test_rebuild_training_sets.py`

**Interfaces:**
- Produces: `async def rebuild_one(conn, target: RebuildTarget, output_dir: Path, *, rng=None) -> GeneratedTrainingSet`

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_rebuild_training_sets.py`：

```python
def _target_for(bundle, *, expected_end: int | None = None) -> r.RebuildTarget:
    """拿本 fixture 的第一个合格起点造一个 RebuildTarget（右端由真实现现算）。"""
    import asyncio
    gi = _gating(bundle)
    start = _eligible_starts(gi)[0]
    idx = [int(b) for b in gi.month_boundaries].index(start)
    real_end = g.compute_after_end(gi.month_boundaries, idx)
    return r.RebuildTarget(_CODE, start, real_end if expected_end is None else expected_end)


def test_rebuild_one_produces_a_real_zip_with_schema_version_2(bundle, tmp_path):
    import asyncio
    target = _target_for(bundle)
    gts = asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))

    assert gts.start_datetime == target.start_datetime
    assert gts.end_datetime == target.expected_end_datetime
    assert gts.schema_version == g.SCHEMA_VERSION
    assert gts.stock_name == g._stock_name_of(_CODE)

    zip_path = tmp_path / f"{_CODE}_{target.start_datetime}.zip"
    assert zip_path.exists(), f"没产出 {zip_path.name}"
    assert gts.content_hash == g.crc32_hex(zip_path.read_bytes()), (
        "登记的 content_hash 与磁盘上 zip 字节的真实 CRC32 不一致")


def test_rebuild_one_refuses_when_end_datetime_differs_from_authority(bundle, tmp_path):
    """右端与权威值不符 ⇒ 抛 RebuildMismatch，且错误信息里**两个值都要有**
    （只说『对不上』的话，操作者不知道该去查哪一边）。"""
    import asyncio
    target = _target_for(bundle, expected_end=1)
    with pytest.raises(r.RebuildMismatch) as ei:
        asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))
    msg = str(ei.value)
    assert "1" in msg and str(_target_for(bundle).expected_end_datetime) in msg
    assert not list(tmp_path.glob("*.zip")), (
        "右端断言失败时不应该已经把 zip 写到盘上 —— 断言必须排在装配之前")
```

- [ ] **Step 2: 跑它，确认是红的**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q
```

期望：两条新用例 FAIL，报 `module 'rebuild_training_sets' has no attribute 'rebuild_one'`。

- [ ] **Step 3: 写实现**

追加到 `backend/rebuild_training_sets.py`：

```python
async def rebuild_one(conn, target: RebuildTarget, output_dir: Path,
                      *, rng: Optional[random.Random] = None) -> GeneratedTrainingSet:
    """重建一个训练组。⛔ 只读源库；⛔ 不登记；⛔ 不取 B2 生成锁。

    次序是硬的：**先断言右端等于权威值，再装配**。反过来会在断言失败时已经把
    zip 写到盘上，留下一个「看起来产出成功了」的残渣。
    """
    gi = await load_gating_inputs(conn, target.stock_code)
    start, windows = build_pinned_windows(
        gi.period_bars, gi.month_boundaries, start_datetime=target.start_datetime,
        dense_dates=gi.dense_dates, trading_dates=gi.trading_dates,
        dropped=gi.dropped, rng=rng)

    idx = [int(b) for b in gi.month_boundaries].index(int(start))
    after_end = compute_after_end(gi.month_boundaries, idx)
    if int(after_end) != int(target.expected_end_datetime):
        raise RebuildMismatch(
            f"{target.stock_code}@{target.start_datetime}: 算出的 end_datetime ="
            f" {after_end}，而旧产物的权威值是 {target.expected_end_datetime}"
            f" —— 源库数据或月边界与当初不同，⛔ 停下来查清楚，不得继续")

    return assemble_from_windows(
        output_dir, stock_code=target.stock_code,
        stock_name=_stock_name_of(target.stock_code),
        start_datetime=int(start), end_datetime=int(after_end), windows=windows)
```

- [ ] **Step 4: 跑测试，确认全绿**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q -rs
```

期望：**6 passed, 0 skipped**。

- [ ] **Step 5: 两组变异（对应 spec §4 的 B63）**

**变异 5a**：把右端断言整条删掉。证明改到了：`grep -c "停下来查清楚，不得继续" backend/rebuild_training_sets.py`（变异前 2、变异后 1）。期望 `test_rebuild_one_refuses_when_end_datetime_differs_from_authority` **FAIL**。

**变异 5b**：把断言挪到 `assemble_from_windows` **之后**。期望同一条用例的**后半截**（`not list(tmp_path.glob("*.zip"))`）FAIL —— 证明「次序」本身是被守着的，不只是「有这么条断言」。

两组都复原后再跑一遍确认回绿。

- [ ] **Step 6: 提交**

```bash
cd ".dev/worktree/trainingset-p4-1"
git add backend/rebuild_training_sets.py backend/tests/test_rebuild_training_sets.py
git commit -m "feat: rebuild_one —— 装配之前先断言右端等于旧产物的权威值"
```

---

### Task 4: 源库零写入的**证据**（不是纪律）

**为什么**：spec §3.4 R2 要求「源库只读要有机器可查的证据，不是口头纪律」，§7 判据 9② 要求跑前跑后四张表行数与 `training_sets` 的 `count/max(id)` 完全一致。对应 spec §4 的 **B56**。

⭐ **两道防线，次序不能颠倒**（codex 评审第 4 轮订正）：

| 道 | 做法 | 挡得住什么 | 实测 |
|---|---|---|---|
| **第一道（承重）** | 连接时让**数据库自己**进只读（`default_transaction_read_only=on`），并当场自证 | **全部** —— 包括纯文本解析**永远看不见**的函数副作用 | 一次性 PG 实测：裸 `UPDATE` / **写 CTE** / `CREATE TABLE` / `SELECT sneaky_write()`（函数体里有 UPDATE）**四种全被 PG 拒绝**，表内容一个字节没变 |
| **第二道（证据）** | 用 `pglast` 逐条判「是不是单条纯 SELECT」，并把发出的语句记下来 | 语法上看得见的写 | 实测对真实读查询**零误报**、对写 CTE 与多语句**全部拦住** |

⛔ **上一版只有第二道，而且是按【首个关键字】判的 —— 实测有两个洞**（codex 第 4 轮）：

```
WITH changed AS (UPDATE training_sets SET schema_version = 1 RETURNING id)
SELECT count(*) FROM changed          ← 首词是 WITH ⇒ 放行
SELECT 1; UPDATE training_sets SET …  ← 首词是 SELECT ⇒ 放行
```

而且这两条改的是 `schema_version`，**不动行数、也不动 `max(id)`** ⇒ 「跑前跑后计数一致」那条**同样发现不了**。
⇒ 一道专门用来发现误写的守卫，会在真有误写时照样报「全部为读」—— 本仓「假绿家族」的标准形态。

**Files:**
- Modify: `backend/rebuild_training_sets.py`
- Test: `backend/tests/test_rebuild_training_sets.py`

**Interfaces:**
- Produces:
  - `async def connect_read_only(dsn: str)`（**第一道**：数据库层只读 + 当场自证）
  - `def assert_no_write_statements(statements) -> None`（**第二道**：`pglast` 白名单判据；发现问题 → 抛 `RebuildMismatch`）
  - `class ReadOnlyConn`：包住任意 asyncpg 风格连接，把每条 SQL 记进 `.statements`，非纯读**当场拒绝**
  - `async def snapshot_source_counts(conn) -> dict`
  - ⛔ **不再有** `WRITE_KEYWORDS` / `_first_keyword` —— 按首词判有实测可复现的漏报

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_rebuild_training_sets.py`：

```python
def test_write_detector_reports_nonzero_on_a_planted_write():
    """⭐ 先证明这个检测器**能报出非 0**，再让它去报 0。

    ⭐ 后三条是**按首词判**会漏掉的（codex 评审第 4 轮实测复现）：
    前两条首词分别是 `WITH` / `SELECT`，第三条根本解析不了。
    """
    for bad in ["INSERT INTO training_sets(stock_code) VALUES ('X')",
                "UPDATE training_sets SET schema_version = 1",
                "DELETE FROM klines",
                "CREATE TABLE t(x int)",
                "ALTER TABLE klines ADD COLUMN x int",
                "TRUNCATE training_sets",
                "DROP TABLE klines",
                "WITH changed AS (UPDATE training_sets SET schema_version = 1"
                " RETURNING id) SELECT count(*) FROM changed",
                "SELECT 1; UPDATE training_sets SET schema_version = 1",
                "SELECT FROM WHERE ((("]:
        with pytest.raises(r.RebuildMismatch) as ei:
            r.assert_no_write_statements(["SELECT 1", bad])
        assert bad[:40] in str(ei.value), "错误信息里没点名是哪一条"


def test_write_detector_passes_on_reads_only():
    """⭐ 正向对照：本片真正会发出的那几条，一条都不许误报。"""
    r.assert_no_write_statements([
        "SELECT period, datetime FROM klines WHERE stock_code=$1 AND period=$2"
        " ORDER BY datetime",
        "SELECT dense_1m_start_date FROM stock_coverage WHERE stock_code=$1",
        "SELECT count(*) FROM training_sets",
        "SELECT max(id) FROM training_sets",
    ])


def test_connect_read_only_refuses_a_session_that_is_not_read_only(monkeypatch):
    """⛔ 连上了但会话不是只读 ⇒ 拒绝并把连接关掉。

    ⭐ 这条自证**有判别力**，不是恒返回 `on`：一次性 PG 上实测过对照 ——
    只读连接返回 `'on'`、普通连接返回 `'off'`。
    """
    import asyncio
    import types
    closed = {"n": 0}

    class _Conn:
        async def fetchval(self, q):
            return "off"

        async def close(self):
            closed["n"] += 1

    async def _connect(dsn, **kw):
        assert kw.get("server_settings", {}).get(
            "default_transaction_read_only") == "on", "连接时没有要求数据库进入只读"
        return _Conn()

    monkeypatch.setitem(sys.modules, "asyncpg", types.SimpleNamespace(connect=_connect))
    with pytest.raises(r.RebuildMismatch):
        asyncio.run(r.connect_read_only("postgresql://x/y"))
    assert closed["n"] == 1, "拒绝时没有把连接关掉"


def test_connect_read_only_accepts_a_read_only_session(monkeypatch):
    """⭐ 正向对照：⛔ 没有它，一个**恒抛**的 connect_read_only 也能让上一条绿。"""
    import asyncio
    import types

    class _Conn:
        async def fetchval(self, q):
            return "on"

        async def close(self):
            raise AssertionError("不该关掉一个合法的只读连接")

    async def _connect(dsn, **kw):
        return _Conn()

    monkeypatch.setitem(sys.modules, "asyncpg", types.SimpleNamespace(connect=_connect))
    got = asyncio.run(r.connect_read_only("postgresql://x/y"))
    assert isinstance(got, _Conn)


def test_rebuild_one_issues_no_write_statements(bundle, tmp_path):
    """真跑一次重建，断言发出去的每一条 SQL 都是读。"""
    import asyncio
    conn = r.ReadOnlyConn(_conn(bundle))
    target = _target_for(bundle)
    asyncio.run(r.rebuild_one(conn, target, tmp_path))

    assert conn.statements, "一条 SQL 都没记到 ⇒ 这个判据是空转的，⛔ 不算通过"
    r.assert_no_write_statements(conn.statements)
    assert conn.inner.registered == [], (
        "假 training_sets 存储里出现了登记行 —— 重建路径调到了 _register_training_set")
```

- [ ] **Step 2: 跑它，确认是红的**

期望：`module 'rebuild_training_sets' has no attribute 'assert_no_write_statements'`。

- [ ] **Step 3: 写实现**

追加到 `backend/rebuild_training_sets.py`：

```python
async def connect_read_only(dsn: str):
    """【第一道】连源库，让**数据库自己**进只读，并当场自证它真的只读了。

    ⭐ 这是唯一挡得住**函数副作用**的一道 —— 一次性 PG 实测：只读会话下
       `SELECT sneaky_write()`（函数体里有 `UPDATE`）被 PG 拒为
       `cannot execute UPDATE in a read-only transaction`，而**任何纯文本解析
       都看不见它**（语法上它就是个普通 SELECT）。
    ⭐ 自证不是走过场：实测对照过 —— 只读连接这句返回 `'on'`、普通连接返回 `'off'`
       ⇒ 这条判据**有判别力**，不是恒返回 `on`。
    ⚠️ 用 `SELECT current_setting(...)` 而**不是** `SHOW ...`：后者的语法树顶层不是
       `SelectStmt`，会被第二道自己拦下来。
    """
    import asyncpg
    conn = await asyncpg.connect(
        dsn, server_settings={"default_transaction_read_only": "on"})
    mode = await conn.fetchval("SELECT current_setting('transaction_read_only')")
    if mode != "on":
        await conn.close()
        raise RebuildMismatch(
            f"连上了，但这个会话不是只读的（transaction_read_only = {mode!r}）"
            f" —— ⛔ 拒绝在这种连接上跑重建")
    return conn


def assert_no_write_statements(statements) -> None:
    """【第二道】每条 SQL 都必须是**单条纯 SELECT**：解析得动、只有一条、顶层是
    `SelectStmt`、且语法树里不出现别的语句节点。不合格就逐条点名并抛错。

    ⛔ **不许按首个关键字判**（codex 评审第 4 轮，两个洞都实测复现过）：
       `WITH changed AS (UPDATE … RETURNING id) SELECT …` 首词是 `WITH` ⇒ 放行；
       `SELECT 1; UPDATE …` 首词是 `SELECT` ⇒ 放行。而它们改的是 `schema_version`，
       **不动行数也不动 `max(id)`** ⇒ 「跑前跑后计数一致」那条同样发现不了。
    ⭐ 判据写成**白名单**（只许 `SelectStmt`），⛔ 不枚举「危险写法」——
       攻击面枚举永远漏，合法面枚举不会。
    ⚠️ **解析不了 ⇒ 判不了 ⇒ 拒绝**，⛔ 不得当成「看起来没问题」。
    ⚠️ 它**看不见**函数副作用 —— 那一类由 `connect_read_only()` 兜住。
    """
    from pglast import parse_sql
    from pglast.visitors import Visitor

    class _Collect(Visitor):
        def __init__(self):
            self.tags = []

        def visit(self, ancestors, node):
            self.tags.append(node.__class__.__name__)

    bad = []
    for sql in statements:
        try:
            parsed = parse_sql(sql)
        except Exception as exc:
            bad.append((sql, f"解析不了（{exc}）⇒ 判不了 ⇒ 拒绝"))
            continue
        if len(parsed) != 1:
            bad.append((sql, f"一次发了 {len(parsed)} 条语句"))
            continue
        top = parsed[0].stmt.__class__.__name__
        if top != "SelectStmt":
            bad.append((sql, f"顶层是 {top}，不是 SelectStmt"))
            continue
        v = _Collect()
        v(parsed[0])
        others = sorted({x for x in v.tags
                         if x.endswith("Stmt") and x not in ("SelectStmt", "RawStmt")})
        if others:
            bad.append((sql, f"语法树里有非 SELECT 的语句节点：{others}"))
    if bad:
        listed = "\n".join(f"  · {s.strip()[:160]}\n      ↳ {why}" for s, why in bad)
        raise RebuildMismatch(
            f"源库只读被破坏：{len(bad)} 条语句不是纯读 —— ⛔ 停下来查清楚\n{listed}")


class ReadOnlyConn:
    """包住一个 asyncpg 风格连接：记录每条 SQL，非纯读**当场拒绝**。

    ⚠️ 它是**第二道 + 证据**，不是保险 —— 真正兜底的是 `connect_read_only()` 让
    数据库自己拒绝。本片重建路径只用 fetch / fetchrow / fetchval / transaction 四样，
    由 `test_rebuild_one_issues_no_write_statements` 钉住实际发出的语句集合。
    """

    def __init__(self, inner):
        self.inner = inner
        self.statements: list[str] = []

    def _record(self, sql: str):
        self.statements.append(sql)
        assert_no_write_statements([sql])

    def transaction(self, *, isolation=None, readonly=False):
        return self.inner.transaction(isolation=isolation, readonly=readonly)

    async def fetch(self, query: str, *args):
        self._record(query)
        return await self.inner.fetch(query, *args)

    async def fetchrow(self, query: str, *args):
        self._record(query)
        return await self.inner.fetchrow(query, *args)

    async def fetchval(self, query: str, *args):
        self._record(query)
        return await self.inner.fetchval(query, *args)

    async def execute(self, query: str, *args):
        self._record(query)
        return await self.inner.execute(query, *args)


#: spec §7 判据 9②：跑前跑后必须完全一致的那几个数
_COUNT_TABLES = ("klines", "stock_coverage", "stocks", "training_sets")


async def snapshot_source_counts(conn) -> dict:
    """四张表行数 + training_sets 的 max(id)。⛔ 全是 SELECT。"""
    out = {}
    for t in _COUNT_TABLES:
        out[f"{t}.count"] = int(await conn.fetchval(f"SELECT count(*) FROM {t}"))
    out["training_sets.max_id"] = await conn.fetchval("SELECT max(id) FROM training_sets")
    return out
```

⚠️ `pglast` 的两个 import 放在 `assert_no_write_statements` **函数里**（⛔ 不放模块顶部）——与 `read_legacy_rows` 一致。它在 `backend/requirements-test.txt` 里（CI 有），但放模块顶部会让「机器上没装 pglast 就 import 不了本模块」。
⚠️ `import re` **仍然需要**（`_CONTENT_HASH_RE` 用它）—— ⛔ 别照着上一版的说法删掉它。首词法那段用的 `_LEADING` / `_first_keyword` 才是要删的。

- [ ] **Step 4: 跑测试，确认全绿**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q -rs
```

期望：**9 passed, 0 skipped**。并且把 `conn.statements` 打印出来**逐条**看一遍（⛔ 不截断），确认里面确实是 `SELECT ... FROM klines` / `FROM stock_coverage` 这些，而不是空的。

- [ ] **Step 5: 两组变异（对应 spec §4 的 B56）**

**变异 5a**：在 `rebuild_one` 结尾加一行 `await conn.execute("INSERT INTO training_sets(stock_code) VALUES ('X')")`。证明改到了：`grep -n "INSERT INTO training_sets" backend/rebuild_training_sets.py` 应命中 1 行。期望 `test_rebuild_one_issues_no_write_statements` **FAIL**。

**变异 5b（对准第 4 轮那两个洞）**：把 `assert_no_write_statements` 换回**按首个关键字**判。
证明改到了：`grep -c "parse_sql" backend/rebuild_training_sets.py`（变异前后差 1）。
期望 `test_write_detector_reports_nonzero_on_a_planted_write` **FAIL**，且 pytest 打出的
失败样本正是那条 `WITH changed AS (UPDATE …)`。

**变异 5c（判别力的另一半）**：把 `assert_no_write_statements` 改成直接 `return`（恒放行）。
期望同一条用例 **FAIL**；而 `test_write_detector_passes_on_reads_only` **仍绿** ——
如实记下：这说明「全是拒了」那一组**单独**不足以证明它没坏，正向对照才是另一半。

**变异 5d（第一道防线）**：把 `connect_read_only` 里的 `server_settings={...}` 整个删掉。
期望 `test_connect_read_only_refuses_a_session_that_is_not_read_only` **FAIL**
（替身里那句「连接时没有要求数据库进入只读」当场炸）。

⚠️ 变异 5a 之前先跑 `find . -name __pycache__ -type d -exec rm -rf {} +`。两组都复原后再跑一遍确认回绿。

- [ ] **Step 6: 提交**

```bash
cd ".dev/worktree/trainingset-p4-1"
git add backend/rebuild_training_sets.py backend/tests/test_rebuild_training_sets.py
git commit -m "feat: 源库只读的机器证据——语句级写检测 + 行数快照（含正向对照）"
```

---

### Task 5: 确定性自证 + 清单（含旧七元组快照）

**为什么**：确定性是整条恢复处方的地基 —— spec §3.4 的崩溃处方里「R2 产物有疑 → 任何时刻重跑得到同一批包」这条，全靠它。对应 spec §4 的 **B34**。
清单里那一栏**旧值**是 P11b 身份闸的输入，spec §3.4 R3 明令**必须在重新生成 P11 之前抄**（B68）。

⛔ **上一版这里写着「把它放进片 1 的清单生成里，这条次序就成了构造保证」—— 那句话是错的**（codex 评审第 1 轮 finding 2，已实测坐实）。
我保证的次序是「读在重建之前」，而 spec 要的次序是「读在 **P11 被重新生成**之前」——**两者不是一回事**。
实测：把 P11 按片 2 的样子重新生成（指纹换新、代数换 2）之后，再按 spec 的崩溃处方「重跑 R2」，
`read_legacy_rows` 读回来的三行全是 `schema_version=2` + 新指纹，**被原样当成「旧值」记进清单**；
CLI 又无条件覆盖清单 ⇒ **真正的旧身份快照就此消失**，而 P11b 的身份闸要拿这份假「旧值」去比一张还是旧值的表 ⇒ 必然失配、整轮卡死，错误信息看起来像「数据被人动过」（正是 B68 描述的那个故障）。

⇒ **改成按判据本身守，而不是按次序守**：`read_legacy_rows` **失败即拒**——只要读到的代数不是迁移前那一代就抛错，让它**不可能**把新值当旧值返回；旧值的来源改由命令行显式选择（首轮 `--p11-sql`，重跑 `--old-snapshot` 指向首轮清单），且清单**拒绝覆盖**。

**Files:**
- Modify: `backend/rebuild_training_sets.py`
- Test: `backend/tests/test_rebuild_training_sets.py`

**Interfaces:**
- Produces:
  - `LEGACY_SCHEMA_VERSION: int = 1`（库存产物迁移前的代数，实测事实）
  - `def assert_seven_tuple_shape(rows, *, where, expect_schema_version, regenerated_hint=False) -> None`
  - `def assert_matches_pinned_targets(rows, *, where) -> None`
  - `def read_old_snapshot(path) -> list[dict]`（重跑时从首轮清单取旧身份，走上面两条共用校验）
  - ⚠️ `rebuild_all` 的签名是 `(conn, targets, output_dir, *, old_rows)` —— **不再**接 `p11_sql_path`
  - `def container_file_path(stock_code: str, start_datetime: int) -> str`
  - `def manifest_row(gts: GeneratedTrainingSet) -> dict`（七元组）
  - `def read_legacy_rows(p11_sql_path: Path) -> list[dict]`（用 pglast 从 p11 SQL 解析旧七元组）
  - `async def rebuild_all(conn, targets, output_dir, *, p11_sql_path) -> dict`（返回 `{"new": [...], "old": [...], "source_counts_before": {...}, "source_counts_after": {...}}`）
  - `def assert_byte_identical(dir_a: Path, dir_b: Path) -> None`

- [ ] **Step 1: 写失败的测试**

追加到 `backend/tests/test_rebuild_training_sets.py`：

```python
_P11 = "docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql"


def _repo_root():
    import pathlib
    return pathlib.Path(__file__).resolve().parents[2]


def test_two_runs_are_byte_identical(bundle, tmp_path):
    """同一输入连跑两次 ⇒ zip 字节与 CRC32 完全相同。
    这是『随时可以重来』这条恢复前提的唯一依据。"""
    import asyncio
    target = _target_for(bundle)
    a, b = tmp_path / "a", tmp_path / "b"
    a.mkdir(); b.mkdir()
    g1 = asyncio.run(r.rebuild_one(_conn(bundle), target, a))
    g2 = asyncio.run(r.rebuild_one(_conn(bundle), target, b))
    assert g1.content_hash == g2.content_hash
    r.assert_byte_identical(a, b)


def test_manifest_row_is_the_seven_tuple(bundle, tmp_path):
    import asyncio
    target = _target_for(bundle)
    gts = asyncio.run(r.rebuild_one(_conn(bundle), target, tmp_path))
    row = r.manifest_row(gts)
    assert set(row) == {"stock_code", "stock_name", "start_datetime", "end_datetime",
                        "schema_version", "file_path", "content_hash"}
    assert row["schema_version"] == g.SCHEMA_VERSION
    assert row["file_path"] == f"/data/training-sets/{_CODE}_{target.start_datetime}.zip"


def test_legacy_rows_are_parsed_from_the_real_sql_by_a_real_parser():
    """旧七元组由 **pglast**（真 PostgreSQL 解析器）从 p11 SQL 解析出来，
    ⛔ 不是人手抄的字面量 —— 手抄的边界就是抄写者的想象力。"""
    rows = r.read_legacy_rows(_repo_root() / _P11)
    assert len(rows) == 3, f"p11_expected 里应有 3 行，解析出 {len(rows)} 行"
    assert {x["content_hash"] for x in rows} == {"851f9444", "32892a5f", "150d8d6c"}
    assert {x["schema_version"] for x in rows} == {1}, (
        "库存三行仍应是第 1 代 —— 若这里变成 2，说明 P11 已被重新生成过，"
        "⛔ 旧值已经没有落脚点了，停下来查清楚")


def test_read_legacy_rows_refuses_a_regenerated_p11(tmp_path):
    """片 2 把 P11 整份重新生成之后，⛔ 不得再从它取旧身份。

    ⭐ 这条是 codex 评审第 1 轮 finding 2 逼出来的：实测证明，不加这道闸时
    `read_legacy_rows` 会把**新**七元组原样当成「旧值」返回，而调用方看不出任何异常。
    """
    src = (_repo_root() / _P11).read_text(encoding="utf-8")
    fake = (src.replace("851f9444", "aaaa1111")
               .replace("32892a5f", "bbbb2222")
               .replace("150d8d6c", "cccc3333")
               .replace("1756656000, 1777996799, 1,", "1756656000, 1777996799, 2,")
               .replace("1762099200, 1782835199, 1,", "1762099200, 1782835199, 2,"))
    assert fake != src and "aaaa1111" in fake, "变异体没造出来 —— 替换锚点漂了，停下来查"
    q = tmp_path / "p11-regenerated.sql"
    q.write_text(fake, encoding="utf-8")
    with pytest.raises(r.RebuildMismatch) as ei:
        r.read_legacy_rows(q)
    assert "已经被重新生成过" in str(ei.value)


_HOLES = {
    "缺 content_hash（P11b 身份闸的输入）": lambda rows: [r.pop("content_hash") for r in rows],
    "缺 file_path": lambda rows: [r.pop("file_path") for r in rows],
    "缺 stock_name": lambda rows: [r.pop("stock_name") for r in rows],
    "缺 stock_code": lambda rows: [r.pop("stock_code") for r in rows],
    "content_hash 是空串": lambda rows: rows[0].__setitem__("content_hash", ""),
    "指纹是大写": lambda rows: rows[0].__setitem__("content_hash", "AAAA1111"),
    "三行共用同一个【小写】指纹":
        lambda rows: [r.__setitem__("content_hash", "deadbeef") for r in rows],
    "两行指纹相撞":
        lambda rows: rows[0].__setitem__("content_hash", rows[1]["content_hash"]),
    "多出一个字段": lambda rows: [r.__setitem__("extra", 1) for r in rows],
    "file_path 与自己的身份不符":
        lambda rows: rows[0].__setitem__("file_path", "/data/training-sets/WRONG.zip"),
    "start_datetime 是字符串":
        lambda rows: rows[0].__setitem__("start_datetime", "1756656000"),
    "schema_version 变成 2":
        lambda rows: [r.__setitem__("schema_version", 2) for r in rows],
}


def _legacy_shaped_rows() -> list[dict]:
    """一份**完整合法**的旧七元组（三个真指纹，与 p11 SQL 一致）。"""
    return [{"stock_code": t.stock_code, "stock_name": t.stock_code,
             "start_datetime": t.start_datetime,
             "end_datetime": t.expected_end_datetime,
             "schema_version": r.LEGACY_SCHEMA_VERSION,
             "file_path": r.container_file_path(t.stock_code, t.start_datetime),
             "content_hash": h}
            for t, h in zip(r.PINNED_TARGETS,
                            ("851f9444", "32892a5f", "150d8d6c"))]


def test_seven_tuple_shape_accepts_a_complete_legacy_snapshot():
    """⭐ 正向对照，必须排在下面那一堆「拒了」之前看 ——
    ⛔ 一套全是「拒了」的用例掩盖得住一个**恒抛**的校验器。"""
    r.assert_seven_tuple_shape(_legacy_shaped_rows(), where="正向对照",
                               expect_schema_version=r.LEGACY_SCHEMA_VERSION)
    r.assert_matches_pinned_targets(_legacy_shaped_rows(), where="正向对照")


@pytest.mark.parametrize("label", sorted(_HOLES))
def test_seven_tuple_shape_rejects_each_known_hole(label):
    """codex 评审第 5 轮那条线索（它被额度掐断前只说到一半，这些是我逐条实测出来的）。

    ⛔ 上一版只查「行数 / 代数 / (code,start,end) 集合」三样，
    下面这些**当时全部通过**，其中「缺 stock_code」还抛的是 KeyError（命令行接不住）。
    """
    rows = _legacy_shaped_rows()
    _HOLES[label](rows)
    with pytest.raises(r.RebuildMismatch):
        r.assert_seven_tuple_shape(rows, where="残缺快照",
                                   expect_schema_version=r.LEGACY_SCHEMA_VERSION)


def test_read_old_snapshot_rejects_an_incomplete_snapshot_file(tmp_path):
    """端到端走一遍文件：残缺快照必须抛 RebuildMismatch，⛔ 不能是 KeyError。"""
    rows = _legacy_shaped_rows()
    for row in rows:
        row.pop("content_hash")
    s = tmp_path / "s.json"
    s.write_text(json.dumps({"old": rows}), encoding="utf-8")
    with pytest.raises(r.RebuildMismatch):
        r.read_old_snapshot(s)


def test_pinned_targets_match_the_authority_row_for_row():
    """spec §7 判据 9③：新一批的 (stock_code, start_datetime) 与旧三个**逐一相同**。

    ⭐ 判据两侧都指向**活数据**：左边是代码里的 PINNED_TARGETS，右边是真解析器从
    p11 SQL 现读出来的。⛔ 不写成「等于某三个字面量」—— 那只是把同一份手抄值抄了第三遍。
    ⭐ 用**集合等式**而不是「这几个各自存在」：后者抓不住「多出来的第四个」。
    """
    rows = r.read_legacy_rows(_repo_root() / _P11)
    authority = {(x["stock_code"], x["start_datetime"], x["end_datetime"]) for x in rows}
    pinned = {(t.stock_code, t.start_datetime, t.expected_end_datetime)
              for t in r.PINNED_TARGETS}
    assert pinned == authority, (
        f"钉死的目标与权威值对不上\n  代码里：{sorted(pinned)}\n  p11 SQL：{sorted(authority)}")
    assert len(r.PINNED_TARGETS) == len(rows) == 3, (
        f"数量对不上：PINNED_TARGETS {len(r.PINNED_TARGETS)} 个、p11 SQL {len(rows)} 行")
```

- [ ] **Step 2: 跑它，确认是红的**

期望：`module 'rebuild_training_sets' has no attribute 'assert_byte_identical'` 等。

- [ ] **Step 3: 写实现**

追加到 `backend/rebuild_training_sets.py`：

```python
import filecmp


def container_file_path(stock_code: str, start_datetime: int) -> str:
    return f"{CONTAINER_TRAINING_SETS_DIR}/{stock_code}_{int(start_datetime)}.zip"


def manifest_row(gts: GeneratedTrainingSet) -> dict:
    """spec §3.4 R2 的【新清单】一行 = 完整七元组。"""
    return {
        "stock_code": gts.stock_code,
        "stock_name": gts.stock_name,
        "start_datetime": int(gts.start_datetime),
        "end_datetime": int(gts.end_datetime),
        "schema_version": int(gts.schema_version),
        "file_path": container_file_path(gts.stock_code, gts.start_datetime),
        "content_hash": gts.content_hash,
    }


def assert_byte_identical(dir_a: Path, dir_b: Path) -> None:
    """两个目录里的 zip 必须逐字节相同（文件名集合也必须相同）。"""
    a = sorted(p.name for p in Path(dir_a).glob("*.zip"))
    b = sorted(p.name for p in Path(dir_b).glob("*.zip"))
    if a != b or not a:
        raise RebuildMismatch(f"两次产出的文件名集合不同或为空：{a} vs {b}")
    for name in a:
        if not filecmp.cmp(Path(dir_a) / name, Path(dir_b) / name, shallow=False):
            raise RebuildMismatch(
                f"{name} 两次产出的字节不同 —— 确定性压缩失效，"
                f"⛔『随时可以重来』这条恢复前提当场不成立")


_P11_EXPECTED_COLUMNS = ("stock_code", "stock_name", "start_datetime", "end_datetime",
                         "schema_version", "file_path", "content_hash")

#: 库存 3 个产物在迁移【之前】的代数。⚠️ 这是一条**历史事实**（实测 p11 SQL 现为 1），
#: 不是可配置常量；它的作用是让「P11 已被重新生成」这件事**当场可判**。
LEGACY_SCHEMA_VERSION = 1

#: `content_hash` 的形状：8 位**小写**十六进制。与 PG 侧约束
#: `ck_content_hash_crc32_lowercase` 同一口径（⛔ 不是随手定的）。
_CONTENT_HASH_RE = re.compile(r"^[0-9a-f]{8}$")


def assert_seven_tuple_shape(rows, *, where: str, expect_schema_version: int,
                             regenerated_hint: bool = False) -> None:
    """校验**完整七元组契约**：字段集合、类型、指纹形状、身份自洽、代数、指纹互不相同。

    ⛔ **这是一份判据，不是几条顺手的检查**（codex 评审第 5 轮的线索，实测复现）：
       上一版只查了「行数 / 代数 / (code,start,end) 集合」三样，于是 —— 逐条实测过 ——
       每行都缺 `content_hash` / 缺 `file_path` / 缺 `stock_name` **全部通过**，
       `content_hash` 是空串**通过**，三行共用同一个大写指纹**通过**，
       缺 `stock_code` 则抛 `KeyError`（命令行接不住，裸崩）。
       而 `content_hash` 正是 **P11b 身份闸的输入** —— 残缺的旧快照会被原样抄进新清单。
    ⭐ 用**集合等式**判字段（`set(row) != set(_P11_EXPECTED_COLUMNS)`），
       ⛔ 不用「这几个键各自在不在」—— 后者抓不住「多出来的第八个」。
    ⭐ `file_path` **由身份现算再比对**，⛔ 不单独相信文件里写的那一串。
    ⭐ 指纹互不相同这条有来历：`…-p15-….sql` 文件头自述，「三行共用同一期望指纹」
       正是它 R2 版被打回的原因（当时闸门还通过了、还打印 PASS）。
    ⚠️ 本函数**不**管行数与目标集合 —— 那是 `assert_matches_pinned_targets` 的事：
       `rebuild_all` 可能只跑一个目标（单测），而「必须是那三个」只对命令行成立。
    """
    if not isinstance(rows, list) or not rows:
        raise RebuildMismatch(f"{where}: 一行都没有")
    for i, row in enumerate(rows, 1):
        if not isinstance(row, dict) or set(row) != set(_P11_EXPECTED_COLUMNS):
            got = sorted(row) if isinstance(row, dict) else type(row).__name__
            raise RebuildMismatch(
                f"{where} 第 {i} 行的字段集合不对\n  实际：{got}\n"
                f"  应为：{sorted(_P11_EXPECTED_COLUMNS)}")
        for k in ("start_datetime", "end_datetime", "schema_version"):
            if not isinstance(row[k], int) or isinstance(row[k], bool):
                raise RebuildMismatch(f"{where} 第 {i} 行的 {k} 不是整数：{row[k]!r}")
        for k in ("stock_code", "stock_name", "file_path", "content_hash"):
            if not isinstance(row[k], str) or not row[k]:
                raise RebuildMismatch(
                    f"{where} 第 {i} 行的 {k} 不是非空字符串：{row[k]!r}")
        if not _CONTENT_HASH_RE.match(row["content_hash"]):
            raise RebuildMismatch(
                f"{where} 第 {i} 行的 content_hash 不是 8 位小写十六进制："
                f"{row['content_hash']!r}")
        if row["stock_name"] != row["stock_code"]:
            raise RebuildMismatch(
                f"{where} 第 {i} 行 stock_name({row['stock_name']!r}) "
                f"!= stock_code({row['stock_code']!r})")
        want_fp = container_file_path(row["stock_code"], row["start_datetime"])
        if row["file_path"] != want_fp:
            raise RebuildMismatch(
                f"{where} 第 {i} 行的 file_path 与它自己的身份对不上\n"
                f"  实际：{row['file_path']}\n  应为：{want_fp}")
    seen = sorted({r["schema_version"] for r in rows})
    if seen != [expect_schema_version]:
        extra = ("—— 说明这份 P11 已经被重新生成过，⛔ 旧身份不能再从它取"
                 "（取到的会是【新】值）。重跑请改用 --old-snapshot 指向【首轮】清单。"
                 if regenerated_hint else "")
        raise RebuildMismatch(
            f"{where}: schema_version 是 {seen}，应为 [{expect_schema_version}] {extra}")
    hashes = {r["content_hash"] for r in rows}
    if len(hashes) != len(rows):
        raise RebuildMismatch(
            f"{where}: {len(rows)} 行却只有 {len(hashes)} 个不同的 content_hash —— "
            f"「三行共用一个指纹」正是 p15 当初被打回的原因，⛔ 拒绝")


def assert_matches_pinned_targets(rows, *, where: str) -> None:
    """行数与 `(stock_code, start_datetime, end_datetime)` 集合必须与 `PINNED_TARGETS` 相同。"""
    if len(rows) != len(PINNED_TARGETS):
        raise RebuildMismatch(
            f"{where}: 应有 {len(PINNED_TARGETS)} 行，实际 {len(rows)} 行")
    got = {(r["stock_code"], r["start_datetime"], r["end_datetime"]) for r in rows}
    want = {(t.stock_code, t.start_datetime, t.expected_end_datetime)
            for t in PINNED_TARGETS}
    if got != want:
        raise RebuildMismatch(
            f"{where}: 与钉死的目标对不上\n  实际：{sorted(got)}\n  应为：{sorted(want)}")


def read_legacy_rows(p11_sql_path) -> list[dict]:
    """用 pglast（真 PostgreSQL 解析器）从 p11 SQL 里取出 `p11_expected` 的三行。

    ⛔ 不用正则、不人手抄：旧值**由机器从那份文件里读出来**，才谈得上可检验。
    ⛔ **只有在 P11 还是第 1 代时才许用它取旧值**：片 2 会把 P11 整份重新生成，
       之后再从它取，取到的是**新**值 —— 实测会被原样当成「旧值」写进清单
       （codex 评审第 1 轮 finding 2）。所以下面那道代数检查是**失败即拒**的，
       ⛔ 不得放宽成警告。重跑请改用 `read_old_snapshot()` 读【首轮】清单。
    """
    from pglast import parse_sql
    from pglast.stream import RawStream

    text = Path(p11_sql_path).read_text(encoding="utf-8")
    # `\set` 等 psql 元命令不是 SQL，parse_sql 会拒；逐行剔除后再解析。
    sql = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("\\"))
    rows: list[dict] = []
    for stmt in parse_sql(sql):
        node = stmt.stmt
        if node.__class__.__name__ != "InsertStmt":
            continue
        if node.relation.relname != "p11_expected":
            continue
        for row in node.selectStmt.valuesLists:
            vals = []
            for item in row:
                rendered = RawStream()(item)
                vals.append(rendered.strip().strip("'"))
            if len(vals) != len(_P11_EXPECTED_COLUMNS):
                raise RebuildMismatch(
                    f"p11_expected 的一行有 {len(vals)} 个值，"
                    f"而列清单有 {len(_P11_EXPECTED_COLUMNS)} 个 —— 结构变了，停下来查清楚")
            d = dict(zip(_P11_EXPECTED_COLUMNS, vals))
            for k in ("start_datetime", "end_datetime", "schema_version"):
                d[k] = int(d[k])
            rows.append(d)
    if not rows:
        raise RebuildMismatch(f"{p11_sql_path} 里没找到 p11_expected 的 INSERT")
    assert_seven_tuple_shape(rows, where=str(p11_sql_path),
                             expect_schema_version=LEGACY_SCHEMA_VERSION,
                             regenerated_hint=True)
    assert_matches_pinned_targets(rows, where=str(p11_sql_path))
    return rows


def read_old_snapshot(path) -> list[dict]:
    """重跑时从【首轮清单】取旧身份，并逐项验证它确实是迁移前那一代。

    ⛔ 三条验证缺一不可：代数、目标集合、行数。少一条就可能把一份**新**清单
       当成旧快照接受，而那正是 finding 2 要堵的那个洞。
    """
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RebuildMismatch(f"{path} 读不出来或不是合法 JSON：{exc}") from None
    rows = data.get("old") if isinstance(data, dict) else None
    where = f"{path} 的 old 段"
    assert_seven_tuple_shape(rows, where=where,
                             expect_schema_version=LEGACY_SCHEMA_VERSION)
    assert_matches_pinned_targets(rows, where=where)
    return rows


async def rebuild_all(conn, targets, output_dir: Path, *, old_rows) -> dict:
    """R2 全流程：快照源库计数 → 逐个重建 → 再快照计数并比对。

    ⛔ `old_rows` **由调用方传进来**，本函数不自己去读 P11（codex 评审第 1 轮 finding 2）：
       「旧值必须来自迁移前的来源」这条判据，由 `read_legacy_rows` / `read_old_snapshot`
       各自**失败即拒**地守住；写成「在这里先读一次」只保证了『读在重建之前』，
       **保证不了**『读在 P11 被重新生成之前』。
    """
    before = await snapshot_source_counts(conn)
    new_rows = []
    for t in targets:
        new_rows.append(manifest_row(await rebuild_one(conn, t, output_dir)))
    assert_seven_tuple_shape(new_rows, where="本轮产出的新清单",
                             expect_schema_version=SCHEMA_VERSION)
    after = await snapshot_source_counts(conn)
    if before != after:
        raise RebuildMismatch(
            f"源库在重建前后发生了变化 —— ⛔ 停下来查清楚\n  前：{before}\n  后：{after}")
    return {"new": new_rows, "old": old_rows,
            "source_counts_before": before, "source_counts_after": after}
```

⚠️ `import filecmp` 放到文件顶部的 import 区。

- [ ] **Step 4: 跑测试，确认全绿**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/test_rebuild_training_sets.py -q -rs
```

期望：**0 skipped**，且条数 = Task 2 的 4 条 + Task 3 的 2 条 + Task 4 的 5 条 + 本任务的 8 条（其中一条是 `parametrize`，实际会展开成 `len(_HOLES)` 个）。⛔ 这里**不写死总数** —— `_HOLES` 一加条目它就过期；跑完把实测数字记进验收清单即可。

- [ ] **Step 5: 三组变异**

**变异 5a（B34）**：在 `generate_training_sets.py` 的 `zip_and_hash` 里，把固定的 `date_time` 换成一个**每次调用都不同的确定性值**——模块级加 `_MUT_N = 0`，函数体开头 `global _MUT_N; _MUT_N += 1`，然后 `date_time=(1980, 1, 1, 0, 0, _MUT_N % 60)`。

⛔ **不要用 `time.localtime()`**：两次调用可能落在同一秒里，那样变异体和对照组同色、判别力为零，而它看起来是「变异没红」。用计数器则**必然**不同。

证明改到了：`grep -n "date_time=" backend/generate_training_sets.py` 应看到 `_MUT_N` 出现在那一行。期望 `test_two_runs_are_byte_identical` **FAIL**（两次 `content_hash` 不等）。

**变异 5b（B68 —— 按新判据重写）**：⚠️ 上一版这条写的是「把 `rebuild_all` 里读 P11 那行挪到重建之后」。
**那条变异现在不适用了** —— `rebuild_all` 已经不自己读 P11（见 finding 2 的订正），次序不再是承重判据。
改成对准真正承重的那条：把 `read_legacy_rows` 末尾那道**代数闸**（`if seen != [LEGACY_SCHEMA_VERSION]`）整段删掉。

证明改到了：`grep -c "已经被重新生成过" backend/rebuild_training_sets.py`（变异前 1、变异后 0）。
期望 `test_read_legacy_rows_refuses_a_regenerated_p11` **FAIL**。

**反向变异**：把代数闸改成 `if seen != [2]`。期望 `test_legacy_rows_are_parsed_from_the_real_sql_by_a_real_parser`
**在当前树上就 FAIL** —— 证明这道闸不是恒真放行，它确实在读那份文件里的真实代数。

**变异 5d（对准新加的那条集合等式）**：把 `PINNED_TARGETS` 第一条的 `start_datetime` 改成 `1756656001`（末位 +1）。证明改到了：`grep -n "1756656001" backend/rebuild_training_sets.py` 应命中 1 行。期望 `test_pinned_targets_match_the_authority_row_for_row` **FAIL**，且错误信息把两边都打出来。
⚠️ 再做一次**反向**变异：往 `PINNED_TARGETS` 里**多加一条**（复制第三条）。期望同一条用例**仍然 FAIL** —— 证明它用的是集合等式、抓得住「多出来的第四个」，而不是「这三个各自存在」。

**变异 5c**：把 `read_legacy_rows` 改成返回人手写死的三行字面量（不解析文件）。期望 `test_legacy_rows_are_parsed_from_the_real_sql_by_a_real_parser` 里 `schema_version == 1` 那条**仍然绿** —— 如实记下，并说明为什么可以接受：这条用例的价值在于「P11 一旦被重新生成，它会当场红」，而那正是片 2 要触发的场景。

- [ ] **Step 6: 提交**

```bash
cd ".dev/worktree/trainingset-p4-1"
git add backend/rebuild_training_sets.py backend/tests/test_rebuild_training_sets.py
git commit -m "feat: 确定性自证 + 新旧两栏清单（旧七元组由真解析器从 p11 SQL 读出）"
```

---

### Task 6: 命令行入口 + 验收清单 + 变异记录

**Files:**
- Modify: `backend/rebuild_training_sets.py`
- Test: `backend/tests/test_rebuild_training_sets.py`
- Create: `docs/acceptance/2026-09-28-trainingset-p4-1-acceptance.md`
- Create: `docs/acceptance/2026-09-28-trainingset-p4-1-mutation-log.md`

**Interfaces:**
- Produces:
  - `def _resolve_v1_archive() -> Path`
  - `def assert_write_target_is_safe(path, *, kind: str, must_not_exist: bool = False) -> Path`
  - `def publish_manifest(manifest_path: Path, payload: str) -> None`（原子发布，目标已存在即失败）
  - `def main(argv=None) -> int`（参数：`--dsn`、`--out-dir`、`--manifest`、`--p11-sql` **或** `--old-snapshot`（恰好给一个））
    ⛔ **没有**跳过确定性自证的开关 —— 它是无条件的（见 Task 6 实现里的注释）

- [ ] **Step 1: 写失败的测试**

⚠️ 这一组是 **codex 评审第 1 轮 finding 1** 逼出来的。原来只校验了 `--out-dir` 一个入口，
而这个流程实际会往**三个**地方写：产出目录、验证目录、清单文件。**只挡其中一个等于没挡** ——
本仓管这叫「同一判据的正交绕法」。下面每条都实测复现过。

```python
def test_write_gate_rejects_a_symlink_pointing_into_the_archive(tmp_path, monkeypatch):
    """⭐ 最要命的一条：一个【指向归档的符号链接】目录。

    实测（2026-09-28）：`assemble_from_windows` **自带**的那道「没逃出 output_dir」守卫
    会**放行** —— 它比的是 `output_dir.resolve()` 与 `zip_path.resolve().parents`，
    而 `.resolve()` 会跟着符号链接走，两边都被解析进了归档 ⇒ 判定「没逃出去」为真
    ⇒ 归档里那个同名 zip 被 `ZipFile(..., "w")` 就地截断（实测原始 17 字节被销毁）。
    ⇒ 所以这道闸必须在**我们自己这一侧**拦住，⛔ 不能指望下游守卫。
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    archive = tmp_path / "qmt_trial_out"
    archive.mkdir()
    link = tmp_path / "newbatch-verify"
    link.symlink_to(archive, target_is_directory=True)
    with pytest.raises(r.RebuildMismatch) as ei:
        r.assert_write_target_is_safe(link, kind="验证目录")
    assert "归档" in str(ei.value)


def test_write_gate_accepts_a_normal_target(tmp_path, monkeypatch):
    """⭐ 正向对照：⛔ 一套全是「拒了」的用例掩盖得住一个恒抛的守卫 ——
    那是本仓点名的头号假绿形态（真栽过：五组判据一次都没执行，429 测试 + 14 轮评审全漏）。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    got = r.assert_write_target_is_safe(tmp_path / "newbatch", kind="产出目录")
    assert got == (tmp_path / "newbatch").resolve()


def test_cli_refuses_out_dir_inside_the_v1_archive(tmp_path, monkeypatch):
    """⛔ spec §3.4 R2 ⓒ：不得写入 ~/qmt_trial_out/（v1 审计归档，逐字节不得改）。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    archive = tmp_path / "qmt_trial_out"
    archive.mkdir()
    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(archive),
                 "--p11-sql", str(_repo_root() / _P11),
                 "--manifest", str(tmp_path / "m.json")])
    assert rc != 0


def test_cli_refuses_manifest_inside_the_v1_archive(tmp_path, monkeypatch):
    """清单路径也要过同一道闸 —— 实测 `Path(...).write_text()` 会把归档里的包**截断成 3 字节**。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    archive = tmp_path / "qmt_trial_out"
    archive.mkdir()
    victim = archive / "000001.SZ_1756656000.zip"
    victim.write_bytes(b"V1-ORIGINAL-BYTES")
    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(tmp_path / "out"),
                 "--p11-sql", str(_repo_root() / _P11), "--manifest", str(victim)])
    assert rc != 0
    assert victim.read_bytes() == b"V1-ORIGINAL-BYTES", "归档里的文件被动过了"


def test_cli_refuses_to_overwrite_an_existing_manifest(tmp_path, monkeypatch):
    """⛔ 首轮清单里的【旧身份快照】一旦被盖掉就再也取不回来（P11 那时已是第 2 代）。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    man = tmp_path / "m.json"
    man.write_text('{"old": "首轮快照"}', encoding="utf-8")
    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(tmp_path / "out"),
                 "--p11-sql", str(_repo_root() / _P11), "--manifest", str(man)])
    assert rc != 0
    assert "首轮快照" in man.read_text(encoding="utf-8"), "已有清单被覆盖了"


def test_cli_refuses_an_existing_out_dir(tmp_path, monkeypatch):
    """产出目录必须【不存在】（spec §3.4 R2 要的就是一个新目录）。

    ⭐ 这比「必须为空」强：`os.mkdir` 是原子的，两个进程同时开工时后来者当场失败；
    而「先看是不是空的、再往里写」拦不住它们（与清单那条是同一个窗口）。
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    out = tmp_path / "out"
    out.mkdir()                       # 已经存在，哪怕是空的也要拒
    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(out),
                 "--p11-sql", str(_repo_root() / _P11),
                 "--manifest", str(tmp_path / "m.json")])
    assert rc != 0


def test_publish_manifest_refuses_an_existing_destination(tmp_path):
    """目标已存在 ⇒ 抛错，且**一个字节都不碰**。"""
    dest = tmp_path / "m.json"
    dest.write_bytes(b"FIRST-RUN-SNAPSHOT")
    with pytest.raises(r.RebuildMismatch):
        r.publish_manifest(dest, '{"new": []}\n')
    assert dest.read_bytes() == b"FIRST-RUN-SNAPSHOT", "目标被动过了"
    assert not list(tmp_path.glob(".manifest.*")), "临时文件没清干净"


def test_publish_manifest_writes_when_destination_is_free(tmp_path):
    """⭐ 正向对照：⛔ 没有它，一个**恒抛**的 publish_manifest 也能让上面那条绿。"""
    dest = tmp_path / "m.json"
    r.publish_manifest(dest, '{"ok": 1}\n')
    assert json.loads(dest.read_text(encoding="utf-8")) == {"ok": 1}
    assert not list(tmp_path.glob(".manifest.*")), "临时文件没清干净"


def _stub_connection(monkeypatch):
    """把「连源库」整个换成替身 —— 本组用例验的是命令行的闸门，不是数据库。

    ⭐ 换的是 `connect_read_only` 本身：如果哪天 `main` 绕过它去裸连数据库，
    这些用例会去真连 `postgresql://x/y` 然后炸掉 —— 等于顺带钉住了「必须走只读连接」。
    """
    class _StubConn:
        async def close(self):
            pass

    async def _connect(dsn):
        return _StubConn()

    monkeypatch.setattr(r, "connect_read_only", _connect)


def test_cli_always_verifies_determinism_even_without_any_flag(tmp_path, monkeypatch):
    """⛔ 确定性自证是**无条件**的（spec §3.4 R2 / §7 判据 9① / 变异 B54）。

    ⭐ 判据是「`rebuild_all` 被调了**两次**、且两次落在**不同目录**」——
    只断言「跑完了」抓不住「只跑了一遍」；两次落同一个目录的话，逐字节比对是**恒真**的。
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    _stub_connection(monkeypatch)
    man = tmp_path / "m.json"
    calls = []

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        calls.append(Path(output_dir))
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": [], "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)

    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(tmp_path / "out"),
                 "--p11-sql", str(_repo_root() / _P11), "--manifest", str(man)])

    assert rc == 0, "合法输入却失败了"
    assert len(calls) == 2, f"只重建了 {len(calls)} 遍 —— 确定性自证被跳过了"
    assert calls[0] != calls[1], "两遍产出到了同一个目录 ⇒ 逐字节比对是恒真的，判别力为零"
    assert json.loads(man.read_text(encoding="utf-8"))["determinism_verified_against"]


def test_cli_does_not_publish_when_the_two_rounds_differ(tmp_path, monkeypatch):
    """两轮字节不一致 ⇒ ⛔ 不发布清单、退出码非 0。

    ⭐ 这条是上一条的**反向**：没有它，一个「调了两次但从不比较」的实现照样能让上一条绿。
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    _stub_connection(monkeypatch)
    man = tmp_path / "m.json"
    n = {"i": 0}

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        n["i"] += 1
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(
            b"ROUND-1-BYTES" if n["i"] == 1 else b"ROUND-2-DIFFERENT")
        return {"new": [], "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)

    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(tmp_path / "out"),
                 "--p11-sql", str(_repo_root() / _P11), "--manifest", str(man)])

    assert rc != 0, "两轮不一致却报成功了"
    assert not man.exists(), "两轮不一致却还是把清单发布了"


def test_cli_does_not_clobber_a_manifest_created_after_preflight(tmp_path, monkeypatch):
    """⭐ codex 评审第 2 轮那条：预检与真正写盘之间隔着**整轮重建**（几分钟）。

    这里让「重建」那一步自己在窗口期内把清单建出来，模拟另一个进程
    （操作者以为卡住了、在另一个终端又跑了一次）。
    ⛔ 预检必然放行 —— 它早就跑完了。拦住它的只能是 `publish_manifest` 的原子发布。
    """
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    _stub_connection(monkeypatch)
    man = tmp_path / "m.json"

    async def _fake_rebuild_all(conn, targets, output_dir, *, old_rows):
        man.write_bytes(b"FIRST-RUN-SNAPSHOT")      # ← 窗口期内被别的进程建出来
        (Path(output_dir) / "000001.SZ_1756656000.zip").write_bytes(b"SAME-BYTES")
        return {"new": [], "old": old_rows}

    monkeypatch.setattr(r, "rebuild_all", _fake_rebuild_all)

    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(tmp_path / "out"),
                 "--p11-sql", str(_repo_root() / _P11), "--manifest", str(man)])
    assert rc != 0
    assert man.read_bytes() == b"FIRST-RUN-SNAPSHOT", "首轮快照被覆盖了"


def test_cli_requires_exactly_one_old_value_source(tmp_path, monkeypatch):
    """首轮给 --p11-sql、重跑给 --old-snapshot，⛔ 不得都给也不得都不给。"""
    monkeypatch.setenv("HOME", str(tmp_path))
    (tmp_path / "qmt_trial_out").mkdir()
    base = ["--dsn", "postgresql://x/y", "--out-dir", str(tmp_path / "out"),
            "--manifest", str(tmp_path / "m.json")]
    assert r.main(base) != 0                                        # 都不给
    assert r.main(base + ["--p11-sql", str(_repo_root() / _P11),
                          "--old-snapshot", str(tmp_path / "s.json")]) != 0   # 都给


def _valid_snapshot() -> dict:
    return {"old": [{"stock_code": t.stock_code, "stock_name": t.stock_code,
                     "start_datetime": t.start_datetime,
                     "end_datetime": t.expected_end_datetime,
                     "schema_version": r.LEGACY_SCHEMA_VERSION,
                     "file_path": r.container_file_path(t.stock_code, t.start_datetime),
                     "content_hash": "deadbeef"}
                    for t in r.PINNED_TARGETS]}


def test_read_old_snapshot_accepts_a_valid_first_round_manifest(tmp_path):
    """⭐ 正向对照（同上：防一套全是拒了的用例掩盖恒抛守卫）。"""
    s = tmp_path / "s.json"
    s.write_text(json.dumps(_valid_snapshot()), encoding="utf-8")
    assert len(r.read_old_snapshot(s)) == len(r.PINNED_TARGETS)


def test_read_old_snapshot_refuses_a_second_generation_snapshot(tmp_path):
    d = _valid_snapshot()
    for row in d["old"]:
        row["schema_version"] = 2
    s = tmp_path / "s.json"
    s.write_text(json.dumps(d), encoding="utf-8")
    with pytest.raises(r.RebuildMismatch):
        r.read_old_snapshot(s)


def test_read_old_snapshot_refuses_when_targets_do_not_match(tmp_path):
    d = _valid_snapshot()
    d["old"][0]["start_datetime"] += 1
    s = tmp_path / "s.json"
    s.write_text(json.dumps(d), encoding="utf-8")
    with pytest.raises(r.RebuildMismatch):
        r.read_old_snapshot(s)


def test_read_old_snapshot_refuses_wrong_row_count(tmp_path):
    d = _valid_snapshot()
    d["old"].append(d["old"][-1])
    s = tmp_path / "s.json"
    s.write_text(json.dumps(d), encoding="utf-8")
    with pytest.raises(r.RebuildMismatch):
        r.read_old_snapshot(s)
```

```python
def test_cli_refuses_to_write_into_the_v1_archive(tmp_path, monkeypatch):
    """⛔ spec §3.4 R2 ⓒ：不得写入 ~/qmt_trial_out/（那是 v1 审计归档，逐字节不得改）。"""
    import os
    archive = tmp_path / "qmt_trial_out"
    archive.mkdir()
    monkeypatch.setenv("HOME", str(tmp_path))
    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(archive),
                 "--p11-sql", _P11, "--manifest", str(tmp_path / "m.json")])
    assert rc != 0


def test_cli_requires_empty_out_dir(tmp_path):
    """输出目录里已有 zip ⇒ 拒绝，⛔ 不得把旧产物和新产物混在一起。"""
    out = tmp_path / "out"
    out.mkdir()
    (out / "stale.zip").write_bytes(b"x")
    rc = r.main(["--dsn", "postgresql://x/y", "--out-dir", str(out),
                 "--p11-sql", _P11, "--manifest", str(tmp_path / "m.json")])
    assert rc != 0
```

- [ ] **Step 2: 跑它，确认是红的**（`has no attribute 'main'`）

- [ ] **Step 3: 写实现**

```python
def _resolve_v1_archive() -> Path:
    """v1 审计归档的真实路径。⚠️ 读 `HOME` —— 测试里可以 monkeypatch 它。"""
    return Path(os.path.expanduser("~/qmt_trial_out")).resolve()


def assert_write_target_is_safe(path, *, kind: str, must_not_exist: bool = False) -> Path:
    """**任何**要写的路径，写之前都必须过这一道。返回解析后的真实路径。

    ⛔ **对每一个写入目标都要跑一遍**（产出目录 / 验证目录 / 清单）——
       只挡其中一个等于没挡（codex 评审第 1 轮 finding 1：原来只挡了产出目录）。
    ⭐ 判据用 `.resolve()` 是**故意的**：它会跟着符号链接走，而这正是需要的 ——
       实测一个指向归档的符号链接能让 `assemble_from_windows` 自带的守卫放行。
    """
    q = Path(path)
    real = q.resolve()
    archive = _resolve_v1_archive()
    if real == archive or archive in real.parents:
        raise RebuildMismatch(
            f"{kind} 的真实路径 {real} 落在 v1 审计归档 {archive} 之内"
            f"（给进来的是 {q}）—— 那里逐字节不得改动，⛔ 拒绝写入")
    if must_not_exist and (q.exists() or q.is_symlink()):
        raise RebuildMismatch(
            f"{kind} {q} 已经存在 —— ⛔ 拒绝覆盖。首轮清单里的【旧身份快照】"
            f"一旦被盖掉就再也取不回来（那时 P11 已经是第 2 代了）")
    # ⚠️ `must_not_exist` 这一支是**早失败**（给操作者一个好看的错误），
    #    **不是**保证 —— 它与真正写盘之间隔着整轮重建。承重的那道在 `publish_manifest`
    #    的 `os.link`（codex 评审第 2 轮）。⛔ 不要因为有了这里就把那里放宽。
    return real


def publish_manifest(manifest_path: Path, payload: str) -> None:
    """**原子发布**清单：先写临时文件并落盘，再用「目标已存在就失败」的方式挂上去。

    ⛔ **不能用 `write_text()`**（codex 评审第 2 轮）：它是 `O_CREAT|O_TRUNC`，
       会**截断**既有文件。而 `main` 里那道「清单不得已存在」的预检与这里之间
       隔着**整轮重建**（几分钟）—— 窗口期内另一个进程（比如操作者以为卡住了、
       在另一个终端重跑了一次）把清单建出来，预检**拦不住**，随后就被截断。
       实测：首轮那份 22 字节的快照被覆盖成新内容，**旧身份从此取不回来**。
    ⭐ `os.link` 在目标已存在时抛 `FileExistsError` 且**一个字节都不碰**（实测坐实），
       这一步本身是原子的 —— 预检只是「早点给出好看的错误信息」，
       **真正的保证在这里**。⛔ 不要因为有了预检就把这里退回 `write_text`。
    ⚠️ 这里用硬链接是**取它「已存在即失败」这一条性质**，与本仓记过的
       「硬链接能穿过守卫写到仓外」是两回事：那里的路径来自外部，这里的目标由我们自己算出、
       且刚刚过完路径闸。
    """
    d = manifest_path.parent
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".manifest.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        try:
            os.link(tmp, manifest_path)
        except FileExistsError:
            raise RebuildMismatch(
                f"清单 {manifest_path} 在本轮重建期间被别的东西创建了 —— "
                f"⛔ 拒绝覆盖，一个字节都没动。"
                f"（首轮清单里的【旧身份快照】一旦被盖掉就再也取不回来）") from None
        # 改名/挂链接的原子性 **不等于** 目录项已经落盘（spec §3.4 R4 同一条道理）
        dfd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        os.unlink(tmp)      # 成功时目标已是同一 inode 的另一个名字，删临时名无损


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="切片一 P4 R2：按钉死的起点重建 3 个训练组（只读源库）")
    ap.add_argument("--dsn", required=True, help="源库连接串（⛔ 必须是源库的只读副本）")
    ap.add_argument("--out-dir", required=True, help="产出目录（⛔ 必须【不存在】，由本命令新建）")
    ap.add_argument("--manifest", required=True, help="清单写到哪里（JSON，⛔ 不得已存在）")
    ap.add_argument("--p11-sql",
                    help="【首轮用】现有 p11 SQL 的路径；⛔ P11 已被片 2 重新生成后不可再用")
    ap.add_argument("--old-snapshot",
                    help="【重跑用】首轮清单 JSON 的路径，旧身份从它取")
    args = ap.parse_args(argv)

    if bool(args.p11_sql) == bool(args.old_snapshot):
        print("拒绝：--p11-sql 与 --old-snapshot 必须【恰好给一个】——"
              " 首轮给 --p11-sql（那时 P11 还是第 1 代），重跑给 --old-snapshot"
              "（P11 已被片 2 改过，再从它取会取到【新】值）", file=sys.stderr)
        return 2

    try:
        out = assert_write_target_is_safe(args.out_dir, kind="产出目录")
        manifest_path = Path(args.manifest)
        assert_write_target_is_safe(manifest_path, kind="清单", must_not_exist=True)
        if out in manifest_path.resolve().parents:
            raise RebuildMismatch(
                f"清单 {manifest_path} 落在产出目录 {out} 里 —— ⛔ 输入输出不得混放")
        # `publish_manifest` 的临时文件要建在清单的上级目录里；上级不存在的话
        # `mkstemp` 抛的是 FileNotFoundError，会变成一个没人接的崩溃栈而不是干净的退出码。
        if not manifest_path.parent.is_dir():
            raise RebuildMismatch(
                f"清单 {manifest_path} 的上级目录不存在 —— ⛔ 请先把它建好")
        old_rows = (read_legacy_rows(Path(args.p11_sql)) if args.p11_sql
                    else read_old_snapshot(Path(args.old_snapshot)))
        # ⭐ 用 `os.mkdir`（⛔ **不加** `exist_ok`）把产出目录**原子地占下来**。
        #   spec §3.4 R2 要的本来就是「产出到一个【新目录】」，所以「必须不存在」
        #   比「必须为空」更贴合，而且顺手关掉了与清单同型的那个窗口：
        #   「先检查是不是空的、再往里写」拦不住两个进程同时开工，`mkdir` 拦得住
        #   （实测：第二次 mkdir 抛 FileExistsError）。
        try:
            os.mkdir(out)
        except FileExistsError:
            raise RebuildMismatch(
                f"产出目录 {out} 已经存在 —— spec §3.4 R2 要求产出到一个【新目录】，"
                f"⛔ 请换一个不存在的路径") from None
        except FileNotFoundError:
            raise RebuildMismatch(
                f"产出目录 {out} 的上级目录不存在 —— ⛔ 请先把上级目录建好") from None
    except RebuildMismatch as exc:
        print(f"重建中止：{exc}", file=sys.stderr)
        return 2

    async def _run():
        conn = ReadOnlyConn(await connect_read_only(args.dsn))
        try:
            man = await rebuild_all(conn, PINNED_TARGETS, out, old_rows=old_rows)
            # ⛔ **确定性自证是无条件的，不是开关**（codex 评审第 3 轮）：
            #    spec §3.4 R2 写的是「⭐ 确定性自证：同一输入【连跑两次】」，
            #    §7 判据 9① 写的是「这是『随时可重来』的唯一依据」，变异 B54 专门盯它。
            #    上一版把它做成 `--verify-determinism`（默认关）⇒ 只给必填参数跑一次
            #    就会发布正式清单并返回成功。**而后面 R6 收口闸比的全是「产出 vs 这份清单」**，
            #    两边同源、必然自洽 ⇒ 真有非确定性也照样全绿，直到恢复时重建的包对不上
            #    已发布的指纹才暴露 —— 那时已经没有退路了。
            #    ⛔ 不得加回任何跳过它的开关（本仓教训：同一类缺陷反复上移 ⇒ 塌层 + 去开关）。
            # ⭐ 用**全新的临时目录**，⛔ 不用 `out.parent / (out.name + "-verify")`：
            #    那个名字可能早就被一个【指向归档的符号链接】占着（第 1 轮 finding 1 实测）。
            #    mkdtemp 保证是新建的，根本不存在「被占着」这回事。
            second = Path(tempfile.mkdtemp(prefix="rebuild-verify-"))
            assert_write_target_is_safe(second, kind="验证目录")   # 纵深防御
            await rebuild_all(conn, PINNED_TARGETS, second, old_rows=old_rows)
            assert_byte_identical(out, second)          # 不一致 → 抛错 → 清单不发布
            man["determinism_verified_against"] = str(second)
            man["statements_issued"] = len(conn.statements)
            return man
        finally:
            await conn.inner.close()

    try:
        manifest = asyncio.run(_run())
    except RebuildMismatch as exc:
        print(f"重建中止：{exc}", file=sys.stderr)
        return 1
    try:
        publish_manifest(
            manifest_path,
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    except RebuildMismatch as exc:
        print(f"清单发布失败：{exc}", file=sys.stderr)
        return 1
    print(f"清单已写到 {manifest_path}；发出的 SQL 共 {manifest['statements_issued']} 条，"
          f"全部为读")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
```

⚠️ 顶部补 `import argparse, asyncio, json, os, sys, tempfile`（`tempfile` 是验证目录用的）。
⚠️ `import asyncpg` 放在 `connect_read_only` 里（⛔ 不放模块顶部）—— 否则测试 `import rebuild_training_sets` 就会拉 asyncpg，而本片其它用例根本不需要它。`pglast` 同理（放在用到它的函数里）。

- [ ] **Step 4: 跑全套后端测试**

```
cd .dev/worktree/trainingset-p4-1/backend && PYTHONDONTWRITEBYTECODE=1 "$PY" -m pytest tests/ -q -rs
```

期望：全部 PASS、**0 skipped**，且总数 = 合并前基线 + 本片新增条数。先把基线数字实测出来（在 `origin/main` 的干净副本上跑一次），⛔ 不要照抄任何文档里写的数字。

- [ ] **Step 5: 写验收清单与变异记录**

`docs/acceptance/2026-09-28-trainingset-p4-1-acceptance.md` —— 非程序员可执行，每条三栏：**动作（可直接复制粘贴的命令）/ 期望看到什么 / 通过与否**。至少覆盖：
1. 全套后端测试跑一遍，看总数与 0 skipped；
2. 本片新增的测试逐条跑一遍，逐条 PASS；
3. 「不钉死时起点会变」那条对照确实是绿的（证明「钉死」这条判据不是空转）；
4. 把 `conn.statements` 打印出来**逐条**看，确认里面全是 `SELECT`；
5. 用真解析器读出的旧三行指纹 == `851f9444` / `32892a5f` / `150d8d6c` 且 `schema_version` 全是 `1`；
6. 命令行入口对下面每一种都拒绝、退出码非 0：产出目录落在归档里 / **清单落在归档里** /
   **清单已存在** / **产出目录已存在** / `--p11-sql` 与 `--old-snapshot` 都给或都不给 /
   **清单在重建途中被别的进程建出来**（这一条拦住它的不是预检，是原子发布）/
   **两轮重建字节不一致**（此时清单必须**没有**被创建出来）；
7. ⭐ **两条正向对照各跑一次并确认是绿的**：合法路径能通过路径闸、合法的首轮清单能通过旧快照校验。
   ⛔ 少了这两条，上面那一串「拒了」掩盖得住一个**恒抛**的守卫 —— 那是本仓点名的头号假绿形态；
8. ⭐ 亲手确认一次：把清单指向归档里的某个 zip 跑一遍，**那个 zip 的字节数跑完仍然没变**。
⛔ 清单里禁止出现 `.claude/workflow-rules.json` 列的那些禁用措辞；每条都要自查「非程序员在这台机器上真做得到吗」。

`docs/acceptance/2026-09-28-trainingset-p4-1-mutation-log.md` —— 逐条记：**怎么改的 / 怎么证明改真的落到文件里了（贴出计数或读回的那一行）/ 红的是哪一条测试 / 复原后是否回绿**。⛔ 只写「已变异」不算。⛔ 文内不写变异总数（数字会漂）。
⚠️ 把 Task 5 变异 5c 那条「**现有用例没红**」如实记进去，连同补救措施 —— 延后或未覆盖的发现必须逐条列出，只记数量等于静默丢弃。
⚠️ 变异 5b 已按 codex 评审第 1 轮的订正**换了对象**（原来那条针对「读 P11 的次序」，而那已不再是承重判据），变异记录里要写明**换过对象、为什么换**。

- [ ] **Step 6: 提交**

```bash
cd ".dev/worktree/trainingset-p4-1"
git add backend/rebuild_training_sets.py backend/tests/test_rebuild_training_sets.py docs/acceptance/
git commit -m "feat: 重建入口命令行 + 非程序员验收清单 + 变异记录"
```

---

## 交接给片 2 / 片 3 的既定事实

1. 片 2 的 SQL 生成器**读片 1 产出的清单 JSON**，⛔ 不自己去解析 p11 SQL 取旧值。
   ⚠️ **上一版这里写「次序约束（B68）已由片 1 的 `rebuild_all` 构造性保证」—— 那句话是错的**，已订正（同 Task 5 开头那段）。
   真正的保证是：`read_legacy_rows` 在 P11 不是第 1 代时**失败即拒**，`read_old_snapshot` 对首轮清单做三项验证，且清单**拒绝覆盖**。
2. ⛔ **片 2 把 P11 重新生成之后，任何重跑 R2 都必须带 `--old-snapshot <首轮清单>`**，⛔ 不得再用 `--p11-sql`（用了会当场被拒，这是设计如此）。
2. 清单 JSON 的结构：`{"new": [七元组×3], "old": [七元组×3], "source_counts_before": {...}, "source_counts_after": {...}, "statements_issued": N}`。
3. ⛔ **`B2_GENERATION_LOCK_KEY` 要在 NAS 的生产库 `kline_trainer` 上取，不是在 Mac 的源库副本上** —— PostgreSQL 的 advisory lock 是**每个数据库各一套**的，在源库上持锁对生产端零约束。这条归片 3。
4. 片 1 ⛔ 未覆盖：R0 静默期、R1 源库副本的制作、R3 三份 SQL、R4 部署、R5 写库、R6 收口闸、崩溃恢复演练、runbook P7 与 `2026-08-14-…-design.md` 的文字订正、旧指纹全仓 grep 闸、文案守卫。
5. ⛔ **P11 本轮生成但不执行** —— 这条已知残留要一路带到片 3 的验收清单里。

## 评审记录

### 第 1 轮 · `codex:adversarial-review`（2026-09-28，attest 形式，scope=branch-diff，**未传 focus**）

判决 **needs-attention**，账本**未写入**（脚本退出码 7）。两条 high，**逐条回源码实测复现后确认全部属实**：

| # | 结论 | 怎么证实的 |
|---|---|---|
| 1 | 归档保护只挡住三个写入口里的一个 —— **属实** | 造了一个指向假归档的符号链接目录，实测 `assemble_from_windows` **自带**的「没逃出 output_dir」守卫**放行**（`.resolve()` 跟着符号链接走，两边都解析进了归档），归档里那个文件的原始 17 字节被 `ZipFile(..., "w")` 就地销毁；另实测 `Path(...).write_text()` 把归档里另一个包截断成 3 字节 |
| 2 | 重跑会把**新**七元组当成「旧值」，覆盖掉真正的旧身份快照 —— **属实** | 把 P11 按片 2 的样子重新生成（指纹换新、代数换 2），再跑 `read_legacy_rows`，读回来的三行全是 `schema_version=2` + 新指纹，被原样当成「旧值」 |

⭐ **第 2 条还揭穿了我写在计划里的一句错话**：我声称「把读取排在重建之前，次序就成了构造保证」。
实测证明我保证的是「读在重建之前」，而 spec 要的是「读在 **P11 被重新生成**之前」——两者不是一回事。
那句话在计划里**有两份副本**（Task 5 开头、交接段），已**两处都订正**。

⛔ **它没能跑起来什么**：codex 的沙箱**只读、且没装 pglast**，所以它审的是「判据站不站得住」，
**没有**执行过本计划里的任何代码。上面那两条的复现是我在本机跑的，不是它跑的。

⇒ 修法见 Task 5（代数闸 + `read_old_snapshot` + `rebuild_all` 改为接收 `old_rows`）与
Task 6（统一路径闸 `assert_write_target_is_safe` + 验证目录改用全新临时目录 + 清单拒绝覆盖 + 两条正向对照）。

### 第 2 轮 · `codex:adversarial-review`（2026-09-28，同上口径，**未传 focus**）

判决仍是 **needs-attention**，账本**未写入**（退出码 7）。finding 从 2 条降到 **1 条 high**，
而且它是第 1 轮那两条的**更深一层**：

| # | 结论 | 怎么证实的 |
|---|---|---|
| 1 | 清单的「不得覆盖」只是**预检**，与真正写盘之间隔着整轮重建 —— **属实** | 实测：预检时目标不存在（放行），窗口期内另一个进程把它建出来，随后 `write_text` 把它截断；另实测 `os.link` 在目标已存在时抛 `FileExistsError` 且**一个字节都不碰**，`os.mkdir` 不加 `exist_ok` 时第二个进程当场失败 |

⭐ **这一条的价值在于它区分了「早失败」与「保证」**：预检给的是好看的错误信息，
真正承重的必须是一个**原子操作**。我上一轮把预检当成了保证。

⇒ 修法：新增 `publish_manifest()`（临时文件 → `fsync` → `os.link` 不覆盖 → 目录 `fsync`）；
产出目录从「必须为空或不存在」收紧为「**必须不存在**」并用 `os.mkdir` 原子占位
（顺手关掉同型的那个窗口，且更贴合 spec §3.4 R2 的「产出到一个【新目录】」）；
补 1 条模拟窗口期被抢占的用例 + 1 条正向对照。

⛔ **它这一轮同样没有执行任何代码**（沙箱只读、无 pglast）。上表的复现是我在本机跑的。

### 第 3 轮 · `codex:adversarial-review`（2026-09-28，同上口径，**未传 focus**）

判决仍是 **needs-attention**，账本**未写入**（退出码 7）。**1 条，且降到 `medium`**：

| # | 结论 | 怎么证实的 |
|---|---|---|
| 1 | 确定性自证被我写成了可跳过的开关 —— **属实** | 回 spec 原文核对：§3.4 R2 写「⭐ 确定性自证：同一输入【连跑两次】」、§7 判据 9① 写「这是『随时可重来』的**唯一依据**」、§4 变异 **B54** 专门盯「R2 不做自证」。**三处都没有「可选」的意思**，是我把硬要求降级成了 `--verify-determinism`（默认关）|

⭐ **为什么这条比看起来严重**：R6 收口闸比的全是「产出 vs **R2 自己的清单**」——两边同源、必然自洽。
所以真有非确定性时，闸门照样全绿，一直到**恢复时重建的包对不上已发布的指纹**才暴露，而那时已经没有退路。
这正是 spec 在 R2 ⓑ2 里点名过的那个形状。

⇒ 修法：**删掉那个开关**，第二轮重建与逐字节比对改为**无条件**、且排在清单发布**之前**；
补 2 条用例 —— ①不带任何开关也必须重建两遍、且两遍落在**不同目录**
（落同一个目录的话逐字节比对是恒真的）；②两轮不一致时**清单必须没有被创建出来**且退出码非 0。
⛔ 计划里写明：不得加回任何跳过它的开关（本仓教训：同一类缺陷反复上移 ⇒ 塌层 + 去开关）。

⛔ **它这一轮仍然没有执行任何代码**。

### 第 4 轮 · `codex:adversarial-review`（2026-09-28，同上口径，**未传 focus**）

判决仍是 **needs-attention**，账本**未写入**（退出码 7）。**1 条 `medium`**，打的是只读守卫**自己**：

| # | 结论 | 怎么证实的 |
|---|---|---|
| 1 | 只看首个关键字 ⇒ 带写入的 SQL 会被放行 —— **属实** | 逐条实测：`WITH changed AS (UPDATE … RETURNING id) SELECT …` 首词是 `WITH` ⇒ 放行；`SELECT 1; UPDATE …` 首词是 `SELECT` ⇒ 放行。两条改的都是 `schema_version`，**不动行数也不动 `max(id)`** ⇒ 「跑前跑后计数一致」那条同样发现不了 |

⭐ **为什么这条值钱**：它不是「重建路径里有写」——重建路径里没有。
它是「**这道专门用来发现误写的守卫，在真有误写时会照样报『全部为读』**」。
本仓管这叫假绿家族：一个报不出非 0 的「0 违反」。

⇒ 修法分两道，**都在一次性 PG 上真跑验过**（⛔ 没碰 `qmt-trial`、⛔ 没碰 `kline-postgres`、⛔ 没复用 `backend_pgdata`；容器用完已删、零残留）：

| 道 | 做法 | 实测 |
|---|---|---|
| **第一道** | `connect_read_only()`：连接时 `default_transaction_read_only=on`，并用 `SELECT current_setting('transaction_read_only')` 当场自证 | 裸 `UPDATE` / **写 CTE** / `CREATE TABLE` / **`SELECT sneaky_write()`（函数体里有 UPDATE）四种全被 PG 拒绝**，表内容一个字节没变。⭐ 最后那种**任何纯文本解析都看不见**。自证有判别力：只读连接返回 `'on'`、普通连接返回 `'off'` |
| **第二道** | `assert_no_write_statements()` 改用 `pglast`：解析得动 + 只有一条 + 顶层是 `SelectStmt` + 树里无别的语句节点，**白名单**写法；解析不了 ⇒ 判不了 ⇒ 拒绝 | 写 CTE 与多语句**全部拦住**；本片真实会发的四条读查询**零误报** |

⛔ **它这一轮仍然没有执行任何代码**（上表每一格都是我在本机跑出来的）。

### 第 5 轮 · `codex:adversarial-review`（2026-09-28 22:5x）—— ⛔ **没有拿到判决**

**额度被掐断，评审中途失败**（退出码 **1**，不是 7；账本同样未写入）：

```
[codex] Codex error: You've hit your usage limit ... try again at Sep 29th, 2026 3:18 AM.
[codex] Turn failed.
Codex did not return valid structured JSON.
```

⛔ **这不算「没发现问题」，更不算 approve** —— 本仓记过：被杀与额度掐断都会留下看起来像结论的输出。

**但它掐断前留下了一条具体线索**（它自己还没来得及验完）：

> "The old-identity check appears to accept incomplete snapshots. I'm checking whether a snapshot
> missing identity fields can pass validation and be copied into a successful rebuild manifest."

**我自己逐条验了，线索属实，而且比它来得及看到的更多 —— 六个洞**（全部实测复现）：

| 造的残缺快照 | 上一版的结果 |
|---|---|
| 每行都缺 `content_hash`（**正是 P11b 身份闸的输入**） | ⛔ 通过 |
| 每行都缺 `file_path` | ⛔ 通过 |
| 每行都缺 `stock_name` | ⛔ 通过 |
| `content_hash` 是空串 | ⛔ 通过 |
| 三行共用同一个大写指纹 | ⛔ 通过 |
| 缺 `stock_code` | ⛔ 抛 `KeyError` —— `main` 只接 `RebuildMismatch`，裸崩 |

⭐ **根因与前面每一轮同型**：我写的是**三条顺手的检查**（行数 / 代数 / 三元组集合），
而不是**「完整七元组」这个契约本身**。⇒ 改成一份**共用的**校验器，
`read_legacy_rows` 与 `read_old_snapshot` **都走它**（⛔ 不许各写一份 —— 那正是本切片要修的根缺陷），
`rebuild_all` 发布前也拿它校验**新**清单。

判据：字段**集合等式**（抓得住「多出来的第八个」）、类型、`content_hash` 形状（8 位小写十六进制，
与 PG 的 `ck_content_hash_crc32_lowercase` 同口径）、`file_path` **由身份现算再比对**、
`stock_name == stock_code`、代数、**三个指纹互不相同**
（⭐ 有来历：`…-p15-….sql` 文件头自述「三行共用同一期望指纹」正是它 R2 版被打回的原因）。

**实测**：这道新校验器在**当前树上用真 p11 SQL 跑是绿的**（⛔ 不是一条开局就红的守卫），
上面六个洞**全部被拒**，另加「多一个字段 / `file_path` 与身份不符 / 类型不对 / 两行指纹相撞」也全拒。
⚠️ 「三行共用大写指纹」那条**先被小写规则拦下**，所以去重规则当时**没被执行到** ——
我另外用**小写**指纹单独验过一次，去重规则确实会红（三行共用、两行相撞都拦住）。

⇒ **第 5 轮必须重跑**：上面这些是我自查的结果，**不是评审结论**。

---

## 已知残留（本片交付时仍在）

- ⛔ 库存 3 个产物仍是第 1 代，NAS 上的 `api` 容器**仍在运行**（实测 2026-09-28：`Up 4 weeks`，宿主 `127.0.0.1:8010` 有监听）—— 停它归片 3 的 R0。
- ⚠️ `ReadOnlyConn` 与 `assert_no_write_statements` 是**第二道 + 证据**，不是保险：不走 SQL 文本的
  写入路径（如 `copy_records_to_table`）、以及**函数副作用**，它们都看不见。
  兜底的是 `connect_read_only()` 让**数据库自己**拒绝（实测四种写入全拦、含函数副作用）。
  ⚠️ 剩下的真残留只有一条：**它保护的是源库，不是文件系统** —— 文件那侧由
  `assert_write_target_is_safe` 与原子发布负责，两者互不覆盖。
- ⛔ 片 1 的测试全部跑在假连接 + 合成 bundle 上，**没有碰过真源库** —— 「在真数据上算出的右端等于权威值」要到片 3 真跑时才验得到。
- ⛔⛔ **`assemble_from_windows` 自带的那道「没逃出 output_dir」守卫，挡不住符号链接** —— 实测坐实：
  它比的是 `output_dir.resolve()` 与 `zip_path.resolve().parents`，而 `.resolve()` 会跟着符号链接走，
  于是「一个指向别处的符号链接目录」两边都被解析到同一个地方，判定「没逃出去」为真、放行。
  ⚠️ 这与本仓记过的硬链接那条是**同一形状**：越围着「非普通路径」打磨，越想不到「被解析之后它就是个普通目录」。
  **本片在调用方这一侧拦住了它**（`assert_write_target_is_safe`），但**没有改那个生产函数本身** ——
  它还被 `generate_batch` 等路径调用，改它属于行为变更、要走自己的评审。
  ⇒ 这是一条**明确交出去的发现**，不是被忘掉的；片 3 或一个独立小 PR 决定要不要修。
