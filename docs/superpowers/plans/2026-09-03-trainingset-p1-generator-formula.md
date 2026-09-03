# 训练组索引公式与产物代际（切片一 · 第 1 片）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `end_global_index` 的算法从「对所有周期一律用下一根开盘 − 1」改成「按 `datetime` 标注语义分流」，并把产物代际从 `user_version = 1` 升到 `2`。

**Architecture:** 抽出一个纯函数 `period_end(datetime, period)` 作为**唯一**的「这根 K 线所属日历周期何时结束」的真相；`assign_global_indices` 用它算 upper，其余（`bisect_right` / `clamp` / `global_index` 仅 `3m` 赋值）一律不动。`period_end(weekly)` 复用仓内已有的 `_week_end_date` —— 为此先把它从 `select_period_window` 的函数体里提到模块级（纯搬移）。

**Tech Stack:** Python 3 / pandas / pytest（`backend/`，CI = `.github/workflows/backend-tests.yml`，Linux、零 skip）；SQLite（`PRAGMA user_version`）；bash（`backend/sql/tests/test_training_set_schema.sh`）。

**Spec:** `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md`（685 行，21 轮对抗性评审后 CONVERGED；本计划实现其 §3.1 / §3.2 / §3.3 的第 1·2·3·4b·4c·4d 项、§3.4「其它硬要求」里的确定性压缩，以及 §3.3 3d 里那两处 `PRAGMA user_version = 1` 验收锚）

## 本片在整条链子里的位置

| 片 | 范围 | 状态 |
|---|---|---|
| **P1（本计划）** | §3.1 `period_end` · §3.2 分流 · §3.3 第 1/2/3/4b/4c/4d 项 · 确定性压缩 | 本计划 |
| P2 | §4.1 跨端 fixture（生产者半边）+ CI 比对 | 待写 |
| P3 | §3.3 其余：冻结契约 3b/3b-2nd/3b2/3c、`CONTRACT_VERSION` 1.13→1.14（5–9 项）、3d 的 m01 矩阵锚、`INSERT` 补 `schema_version` 10 处 + 守卫、Mac 副本作废 + 文案守卫 | 待写 |
| P4 | §3.4 R0–R7 运维重建（Mac 源库 + NAS，人工执行，无测试闭环） | 待写 |

⚠️ **P1 单独可交付、CI 可全绿**，但它**只改代码不改产物** —— 库里那 3 个包仍是第 1 代，要到 P4 才被重建取代。

## Global Constraints

以下为 spec 的项目级要求，**每个 Task 的要求都隐含包含本节**：

- ⛔ **本片不碰任何 App 逻辑**（`ios/**` 在 P1 一行不改；`CONTRACT_VERSION` 相关的 iOS 常量改动归 P3）。
- ⛔ **时区一律用 tz 数据库的 `Asia/Shanghai`**，不得写成固定 `+08:00`。⚠️ 当前数据下两种写法结果完全相同（1991 年及更早的夏令时区间全在 3m 轴起点之前、一律 clamp 到 0）⇒ **没有任何测试能抓住这个差异**，所以这条**只写进规矩、⛔ 不设机械守卫**（spec §3.1；一条恒绿的守卫不该存在）。
- ⛔ **不得用 `isocalendar()` 的周数反推周日**：`date(2024,12,30).isocalendar()` 的 ISO **年是 2025**，任何以 `(iso_year, iso_week)` 为键的写法都会在跨年周出错。§2.2 写「ISO 周」只是给语义命名，**实现一律 `6 - weekday()`**。
- ⛔ **周期→标注约定必须用显式常量表**（`_CLOSE_LABELLED = frozenset({"3m","15m","60m"})`），不得用「周期名里有没有 `m`」之类的字符串把戏。
- ⛔ **期望值必须手写**，不得由「跑一遍生成器」得出 —— 否则生产者与校验者会**一起用错公式而全绿**，那正是缺陷藏住的机制（spec §4.1 note 3 / 变异 B18）。本计划里所有期望值均由**独立实现 §2.2 公式**算出（不 import 被测代码），推导写在各 Task 里。
- 后端 CI 是 **Linux 且零容忍 skip**；本地 macOS 全绿不代表 CI 绿。
- ⛔ 交付话术：可以说「日内周期与周线的形成时刻已订正」；**不得说**「手机能用了」「真实数据链路打通」—— App 侧一行未改。

---

## File Structure

| 文件 | 责任 | 本片动作 |
|---|---|---|
| `backend/generate_training_sets.py` | 训练组生成（纯装配层 + PG 壳 + CLI） | 提取 `_week_end_date`；新增 `period_end` 与 `_CLOSE_LABELLED`；改 `assign_global_indices`；改 `zip_and_hash` 确定性；改 `SCHEMA_VERSION` 与 DDL 字面量；改 `:16` / `:274-276` 两处陈旧注释 |
| `backend/tests/test_generate_training_sets.py` | 上面那个模块的 host pytest（不碰 PG） | 更新 3 条既有断言；新增 `period_end` 单测、日内边界、周线洞、monthly 真实量级、确定性、共用性 6 组 |
| `backend/sql/training_set_schema_v1.sql` | 冻结的训练组 SQLite DDL | `PRAGMA user_version = 1` → `2`，`:2`/`:3` 注释同步 |
| `backend/sql/tests/test_training_set_schema.sh` | 上面那份 DDL 的 CI 硬门 | 期望值 `1` → `2`（`:10-13` 与 `:38` PASS 文案） |
| `scripts/acceptance/plan_b2_generate_training_sets.sh` | 既有验收 grep 锚 | `:30` 的 `PRAGMA user_version = 1` → `2`（⛔ 只改这一行） |
| `docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md` | 同上，写在验收表里 | `:46` 同上（⛔ 只改这一行） |

⛔ **P1 不新建任何文件。** fixture 目录归 P2。

---

## Task 1: 把 `_week_end_date` 提到模块级（纯搬移）

**Files:**
- Modify: `backend/generate_training_sets.py:96-98`（从 `select_period_window` 体内移到模块级）
- Test: `backend/tests/test_generate_training_sets.py`

**Interfaces:**
- Consumes: `trading_date`（已 import 自 `qmt_normalize`）
- Produces: 模块级 `_week_end_date(open_epoch: int) -> datetime.date` —— Task 2 的 `period_end(weekly)` 要用它

**为什么必须先做这一步**（spec §3.3 行 3e / 变异 B66）：`period_end(weekly)` 被要求「复用仓内已有的 `_week_end_date`」，而它现在是 `select_period_window`（`:83`）**函数体内的嵌套闭包**，**作用域不可达** ⇒ 直接写「复用」兑现不了。实施者照字面执行只能另抄一份公式，**正好复活本片要防的「两份实现漂移」**。

- [ ] **Step 1: 写会失败的测试**

在 `backend/tests/test_generate_training_sets.py` 顶部的 import 区确认已有 `import generate_training_sets as _g`（若没有则加），然后在文件末尾追加：

```python
# ── Task 1：_week_end_date 必须在模块级，且 select_period_window 用的就是它（变异 B66）

def _ep(y, m, d, H=0, M=0):
    """构造 Asia/Shanghai 的 Unix 秒（测试内独立实现，⛔ 不 import 被测模块的时区常量）。"""
    import datetime as _d
    from zoneinfo import ZoneInfo
    return int(_d.datetime(y, m, d, H, M, tzinfo=ZoneInfo("Asia/Shanghai")).timestamp())


def test_week_end_date_is_module_level_and_shared(monkeypatch):
    """B66：period_end(weekly) 与 select_period_window 必须共用同一个 _week_end_date。

    判据 = monkeypatch 模块级函数后，select_period_window 确实调到了它。
    若 select_period_window 内部仍有一份嵌套闭包，spy 不会被调用 ⇒ 本测试红
    ⇒ 「共用」没有兑现（这正是 spec §3.3 行 3e 要防的「两份实现漂移」）。
    """
    import generate_training_sets as g
    assert hasattr(g, "_week_end_date"), "_week_end_date 必须提到模块级（现在还在函数体内）"

    calls = []
    real = g._week_end_date

    def spy(e):
        calls.append(e)
        return real(e)

    monkeypatch.setattr(g, "_week_end_date", spy)
    bars = _df("weekly", [_ep(2026, 3, 23), _ep(2026, 3, 30)])
    g.select_period_window(bars, _ep(2026, 4, 2), before_cap=None,
                           after_end=_ep(2026, 4, 3, 23, 59), period="weekly")
    assert calls, "select_period_window 没有调用模块级 _week_end_date（说明它还在用内部闭包）"
```

- [ ] **Step 2: 跑，确认它红**

```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py::test_week_end_date_is_module_level_and_shared -v
```

Expected: **FAIL**，报 `AssertionError: _week_end_date 必须提到模块级（现在还在函数体内）`

- [ ] **Step 3: 纯搬移**

把 `backend/generate_training_sets.py` 里 `select_period_window` **函数体内**这三行：

```python
    def _week_end_date(open_epoch):
        d = trading_date(open_epoch)
        return d + _dt.timedelta(days=(6 - d.weekday()))   # 该周周日
```

**整段删除**，改到模块级（放在 `select_period_window` **之前**，紧跟 `B2_GENERATION_LOCK_KEY` 那组常量之后）：

```python
def _week_end_date(open_epoch: int) -> _dt.date:
    """该周的周日（Asia/Shanghai 交易日历）。

    ⭐ 单一真相：`select_period_window` 的 weekly 过滤与 `period_end(weekly)` **共用本函数**
    —— 两处各写一份正是本次整个缺陷的成因（spec §1.4 / §3.1）。
    ⛔ **不得用 `isocalendar()` 的周数反推**：`date(2024,12,30).isocalendar()` 的 ISO 年是
    **2025**，任何以 `(iso_year, iso_week)` 为键的写法都会在跨年周出错。实现一律 `6 - weekday()`。
    """
    d = trading_date(open_epoch)
    return d + _dt.timedelta(days=(6 - d.weekday()))
```

⛔ **行为一个字节都不改** —— 这一步是纯搬移，不改公式、不改签名、不改调用点的语义。

- [ ] **Step 4: 跑，确认它绿，且既有 weekly 测试没被碰坏**

```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -v -k "week"
```

Expected: **PASS**，且既有的 `test_select_period_window_weekly_*` 一类用例全绿（纯搬移不该改变任何行为）

- [ ] **Step 5: 提交**

```bash
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "refactor(backend): _week_end_date 提到模块级（纯搬移，为 period_end(weekly) 复用做准备）

spec §3.3 行 3e / 变异 B66：它原本是 select_period_window 函数体内的嵌套闭包、作用域不可达，
导致 §3.1「period_end(weekly) 必须复用它」没有机制能兑现——实施者只能另抄一份公式，
正好复活本片要防的「两份实现漂移」。

配 test_week_end_date_is_module_level_and_shared：monkeypatch 模块级函数后断言
select_period_window 确实调到它；若内部仍有闭包，spy 不被调用 ⇒ 红。"
```

---

## Task 2: 新增 `period_end(datetime, period)` 纯函数

**Files:**
- Modify: `backend/generate_training_sets.py`（在 `_week_end_date` 之后新增 `_CLOSE_LABELLED` 与 `period_end`）
- Test: `backend/tests/test_generate_training_sets.py`

**Interfaces:**
- Consumes: `_week_end_date`（Task 1）、`trading_date`（`qmt_normalize`）
- Produces: `period_end(datetime_epoch: int, period: str) -> int` —— Task 3 的 `assign_global_indices` 与 P4 的迁移脚本共用；**切片二的读取端校验也将 import 它**（spec §8 第 2 条）

- [ ] **Step 1: 写会失败的测试**

追加到 `backend/tests/test_generate_training_sets.py`：

```python
# ── Task 2：period_end 纯函数（spec §2.2）

def _sh_dt(epoch):
    """Unix 秒 → Asia/Shanghai 的 datetime（测试内独立实现）。"""
    import datetime as _d
    from zoneinfo import ZoneInfo
    return _d.datetime.fromtimestamp(int(epoch), ZoneInfo("Asia/Shanghai"))


def test_period_end_close_labelled_returns_input_unchanged():
    """3m / 15m / 60m 的 datetime 本身就是收盘时刻 ⇒ 原样返回（spec §2.1）。"""
    from generate_training_sets import period_end
    e = _ep(2026, 4, 2, 11, 30)
    for p in ("3m", "15m", "60m"):
        assert period_end(e, p) == e


def test_period_end_daily_is_end_of_that_trading_day():
    from generate_training_sets import period_end
    got = _sh_dt(period_end(_ep(2026, 4, 2), "daily"))
    assert (got.year, got.month, got.day) == (2026, 4, 2)
    assert (got.hour, got.minute, got.second) == (23, 59, 59)


def test_period_end_weekly_is_that_weeks_sunday():
    """含两类真实边界（spec §3.1 实测）：首日非周一、跨年周。

    ⛔ 跨年周是 isocalendar() 的坑：date(2024,12,30).isocalendar() 的 ISO 年是 2025。
    本函数一律 6 - weekday()，与 ISO 年无关。
    """
    from generate_training_sets import period_end
    import datetime as _d
    cases = [
        (_ep(2024, 12, 30), _d.date(2025, 1, 5)),    # 跨年周（周一 → 次年周日）
        (_ep(2025, 12, 29), _d.date(2026, 1, 4)),    # 跨年周
        (_ep(2025, 2, 5),   _d.date(2025, 2, 9)),    # 首日非周一（春节后周三）
        (_ep(2025, 10, 9),  _d.date(2025, 10, 12)),  # 首日非周一（国庆后周四）
        (_ep(2026, 3, 23),  _d.date(2026, 3, 29)),   # 常规周一
    ]
    for e, expected_date in cases:
        got = _sh_dt(period_end(e, "weekly"))
        assert got.date() == expected_date, f"{_sh_dt(e).date()} 的周日应为 {expected_date}"
        assert (got.hour, got.minute, got.second) == (23, 59, 59)


def test_period_end_monthly_is_last_moment_of_that_month():
    from generate_training_sets import period_end
    import datetime as _d
    cases = [
        (_ep(2026, 2, 2),  _d.date(2026, 2, 28)),   # 平年 2 月
        (_ep(2024, 2, 5),  _d.date(2024, 2, 29)),   # 闰年 2 月
        (_ep(2026, 4, 1),  _d.date(2026, 4, 30)),
        (_ep(2026, 12, 1), _d.date(2026, 12, 31)),  # 跨年边界
    ]
    for e, expected_date in cases:
        got = _sh_dt(period_end(e, "monthly"))
        assert got.date() == expected_date
        assert (got.hour, got.minute, got.second) == (23, 59, 59)


def test_period_end_rejects_unknown_period():
    """⛔ 显式常量表，不做字符串把戏 ⇒ 未知周期必须炸，不能静默走某个分支。"""
    from generate_training_sets import period_end
    import pytest as _pt
    with _pt.raises(ValueError):
        period_end(_ep(2026, 4, 2), "30m")
```

- [ ] **Step 2: 跑，确认它红**

```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -v -k "period_end"
```

Expected: **5 个用例全 FAIL**，报 `ImportError: cannot import name 'period_end'`

- [ ] **Step 3: 实现**

在 `backend/generate_training_sets.py` 的 import 区加 `import calendar`（放在 `import datetime as _dt` 之后，保持字母序）；并从 `qmt_normalize` 多 import 一个时区常量：

```python
from qmt_normalize import is_valid_stock_code, trading_date
from qmt_normalize import _SH as _SHANGHAI      # ⭐ 刻意复用私有常量而非另建一个 ZoneInfo：
                                                #    本片的整个主题就是「不要写第二份」，
                                                #    tz 对象的单一真相在 qmt_normalize。
```

在 `_week_end_date` 之后新增：

```python
# 周期 → datetime 标注约定（spec §2.1）。⛔ 显式常量表，不得用「周期名里有没有 m」之类的字符串把戏。
_CLOSE_LABELLED = frozenset({"3m", "15m", "60m"})


def period_end(datetime_epoch: int, period: str) -> int:
    """spec §2.2：这根 K 线所属【日历周期】的**结束时刻**（Unix 秒）。

    - **收盘标注**（`3m` / `15m` / `60m`）：`datetime` 本身就是收盘时刻 ⇒ 原样返回；
    - **开盘侧标注**（`daily` / `weekly` / `monthly`）：返回该日历周期的最后一秒。

    时区一律 tz 数据库的 `Asia/Shanghai`（⛔ 不得写固定 `+08:00`）。
    ⚠️ 当前数据下两种写法结果完全相同（1991 年及更早的夏令时区间全在 3m 轴起点之前、
    一律 clamp 到 0）⇒ **没有任何测试能抓住这个差异**，故只写进规矩、不设守卫。

    ⛔ **开盘侧不得退化成「下一根 − 1」**：那些序列**允许有洞**（spec §1.3 —— `select_period_window`
    会故意删掉跨训练起点 / 跨 `after_end` 的那根周线），洞前那根会被判成「在洞里某个时刻才完成」。
    """
    if period in _CLOSE_LABELLED:
        return int(datetime_epoch)
    d = trading_date(datetime_epoch)
    if period == "daily":
        last = d
    elif period == "weekly":
        last = _week_end_date(datetime_epoch)
    elif period == "monthly":
        last = _dt.date(d.year, d.month, calendar.monthrange(d.year, d.month)[1])
    else:
        raise ValueError(f"period_end: 未知周期 {period!r}（认识的只有 {sorted(_CLOSE_LABELLED)} "
                         f"+ daily/weekly/monthly）")
    return int(_dt.datetime(last.year, last.month, last.day, 23, 59, 59,
                            tzinfo=_SHANGHAI).timestamp())
```

- [ ] **Step 4: 跑，确认它绿**

```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -v -k "period_end"
```

Expected: **5 passed**

- [ ] **Step 5: 提交**

```bash
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "feat(backend): 新增 period_end(datetime, period) 纯函数（spec §2.2）

按周期区分 datetime 标注语义：收盘标注（3m/15m/60m）原样返回；开盘侧标注
（daily/weekly/monthly）返回该日历周期的最后一秒。weekly 复用 Task 1 提到模块级的
_week_end_date，⛔ 不用 isocalendar() 反推（date(2024,12,30) 的 ISO 年是 2025）。

时区用 tz 数据库的 Asia/Shanghai，复用 qmt_normalize 的 _SH（⛔ 不另建一个 ZoneInfo
——本片主题就是不要写第二份）。未知周期显式 ValueError，不静默走分支。

测试覆盖跨年周（2024-12-30 / 2025-12-29）、首日非周一（春节后 2025-02-05、
国庆后 2025-10-09）、闰年 2 月、跨年月边界。"
```

---

## Task 3: `assign_global_indices` 按语义分流

**Files:**
- Modify: `backend/generate_training_sets.py:288-292`（循环体）、`:274-276`（docstring）、`:16`（模块头 D4 那行）
- Modify: `backend/tests/test_generate_training_sets.py:144-146`（三条既有断言的期望值）
- Test: `backend/tests/test_generate_training_sets.py`（新增 4 组）

**Interfaces:**
- Consumes: `period_end`（Task 2）
- Produces: `assign_global_indices(windows) -> dict[str, pd.DataFrame]`（签名不变，`end_global_index` 取值语义变）

⚠️ **本 Task 会让 3 条既有断言变红**（`:144-146`），所以期望值更新与实现改动**必须在同一个提交里**，否则 CI 在两次提交之间是红的。

### 期望值的来历（⛔ 不是跑生成器抄回来的）

下面每一组数字都由**独立实现 spec §2.2 的公式**算出（`clamp(bisect_right(m3, period_end(e, period)) − 1, 0, n3−1)`），**不 import 被测代码**。推导逐条写在测试的 docstring 里，实施者应当能照着复算。

- [ ] **Step 1: 更新既有三条断言 + 写新的边界测试**

**(a)** 把 `backend/tests/test_generate_training_sets.py:144-146` 三行改成：

```python
def test_assign_end_global_index_interior_historical_trailing():
    """新公式（spec §2.2）下的期望值。3m 轴 = [0,10,20,30,40,50]（n3=6）。

    · 15m 标收盘 [0,30,60]  ⇒ upper 即本根 ⇒ bisect_right = 1/4/6 ⇒ −1 ⇒ [0,3,5]
    · 60m 标收盘 [-100,-90,40] ⇒ upper=-100/-90 落在轴前 ⇒ clamp 到 0；40 ⇒ 5−1=4 ⇒ [0,0,4]
    · monthly 标开盘侧 [-100,20] ⇒ 两者都落在 1970-01，月末 = 2649599（1970-01-31
      23:59:59 Asia/Shanghai）已超过轴末根 50 ⇒ 均 clamp 到 5 ⇒ [5,5]
    ⚠️ monthly 这组在本 fixture 上判别力归零（两根都被 clamp），
       真实量级的 monthly 判据见 test_assign_monthly_realistic_scale。
    """
    out = assign_global_indices(_index_windows())
    assert list(out["15m"]["end_global_index"]) == [0, 3, 5]
    assert list(out["60m"]["end_global_index"]) == [0, 0, 4]
    assert list(out["monthly"]["end_global_index"]) == [5, 5]
```

**(b)** 在文件末尾追加四组新测试：

```python
# ── Task 3：分流后的边界判据（spec §1.2 / §1.3；变异 B1 / B2 / B3 / B4 / B5 / B7）

def _intraday_axis():
    """两个交易日、每日 4 根 3m：09:33 / 11:30 / 14:57 / 15:00。

    ⇒ 11:30→14:57 之间是**午休缺口**、15:00→次日 09:33 之间是**日界**。
    下标：[0]=04-02 09:33 [1]=04-02 11:30 [2]=04-02 14:57 [3]=04-02 15:00
          [4]=04-03 09:33 [5]=04-03 11:30 [6]=04-03 14:57 [7]=04-03 15:00
    """
    return [_ep(2026, 4, d, H, M)
            for d in (2, 3)
            for (H, M) in ((9, 33), (11, 30), (14, 57), (15, 0))]


def test_assign_intraday_crosses_lunch_and_day_boundary():
    """B1 / B5：日内周期必须用【本根 datetime】当 upper，不得用「下一根 − 1」或固定偏移。

    15m 标收盘 [04-02 11:30, 04-02 15:00, 04-03 11:30, 04-03 15:00]
      新公式 ⇒ [1, 3, 5, 7]      （每根都精确指向它自己那一刻的 3m）
      旧公式 ⇒ [2, 4, 6, 7]      （跨午休 / 跨日各晚 1 根；末根因退化而恰好相同）
    60m 标收盘 [04-02 15:00, 04-03 15:00]
      新公式 ⇒ [3, 7]            旧公式 ⇒ [6, 7]（第一根晚了 3 根 = 跨了一整个日界）
    """
    axis = _intraday_axis()
    windows = {
        "3m": _df("3m", axis),
        "15m": _df("15m", [axis[1], axis[3], axis[5], axis[7]]),
        "60m": _df("60m", [axis[3], axis[7]]),
        "daily": _df("daily", [_ep(2026, 4, 2), _ep(2026, 4, 3)]),
        "weekly": _df("weekly", [_ep(2026, 3, 30)]),
        "monthly": _df("monthly", [_ep(2026, 4, 1)]),
    }
    out = assign_global_indices(windows)
    assert list(out["15m"]["end_global_index"]) == [1, 3, 5, 7]
    assert list(out["60m"]["end_global_index"]) == [3, 7]


def test_assign_daily_unchanged_by_the_split():
    """正向对照（spec §4.1 ①）：`daily` 在新旧两式下**逐根相同** ⇒ 必须放行。

    daily 标开盘侧 [04-02 00:00, 04-03 00:00]
      新公式：period_end = 当日 23:59:59 ⇒ [3, 7]
      旧公式：下一根 − 1 / 末根退化 ⇒ 同样 [3, 7]
    ⇒ 若把分流方向弄反（变异 B2）或顺手也改了 daily（变异 B7），本条会红。
    """
    axis = _intraday_axis()
    windows = {
        "3m": _df("3m", axis),
        "15m": _df("15m", [axis[1], axis[3], axis[5], axis[7]]),
        "60m": _df("60m", [axis[3], axis[7]]),
        "daily": _df("daily", [_ep(2026, 4, 2), _ep(2026, 4, 3)]),
        "weekly": _df("weekly", [_ep(2026, 3, 30)]),
        "monthly": _df("monthly", [_ep(2026, 4, 1)]),
    }
    out = assign_global_indices(windows)
    assert list(out["daily"]["end_global_index"]) == [3, 7]
    assert list(out["3m"]["end_global_index"]) == [0, 1, 2, 3, 4, 5, 6, 7]
    assert list(out["3m"]["global_index"]) == [0, 1, 2, 3, 4, 5, 6, 7]


def test_assign_monthly_realistic_scale():
    """monthly 在真实量级上的判据（spec §3.3 行 4c 要求的专用用例）；同时覆盖变异 B4（时区）。

    3m 轴同上（2026-04-02 / 04-03，8 根）。monthly 标开盘侧：
      2026-02-02 ⇒ 月末 02-28 23:59:59，早于轴首 ⇒ clamp 0
      2026-03-02 ⇒ 月末 03-31 23:59:59，早于轴首 ⇒ clamp 0
      2026-04-01 ⇒ 月末 04-30 23:59:59，晚于轴末 ⇒ clamp 7
    ⇒ [0, 0, 7]。⭐ 前两根落在 0 = spec §4.1 特征①「≥2 根落在 end_global_index = 0」。
    ⭐ 判别力：若 period_end 的时区改成 UTC（变异 B4），2026-04-01 00:00 CST 会被算成
       3 月 ⇒ 月末 04-01 07:59:59 CST ⇒ 仍早于轴首 ⇒ 结果变成 [0, 0, 0]，本条红。
    """
    axis = _intraday_axis()
    windows = {
        "3m": _df("3m", axis),
        "15m": _df("15m", [axis[1], axis[3]]),
        "60m": _df("60m", [axis[3]]),
        "daily": _df("daily", [_ep(2026, 4, 2)]),
        "weekly": _df("weekly", [_ep(2026, 3, 30)]),
        "monthly": _df("monthly", [_ep(2026, 2, 2), _ep(2026, 3, 2), _ep(2026, 4, 1)]),
    }
    out = assign_global_indices(windows)
    assert list(out["monthly"]["end_global_index"]) == [0, 0, 7]


def test_assign_weekly_hole_uses_calendar_period_end():
    """B3：开盘侧**不得**用「下一根 − 1」—— 周线序列允许有洞（spec §1.3）。

    3m 轴 = 03-27(Fri) / 03-30(Mon) / 04-02(Thu) 各 2 根（09:33、15:00），共 6 根：
      [0]=03-27 09:33 [1]=03-27 15:00 [2]=03-30 09:33 [3]=03-30 15:00
      [4]=04-02 09:33 [5]=04-02 15:00
    起点设 04-02（**周四，周中**）⇒ select_period_window 的 weekly before 过滤会删掉
    03-30 那根（其周末 04-05 ≥ start 日 04-02）⇒ 窗口里只剩 03-23 一根 ⇒ **有洞**。

      新公式：period_end(03-23, weekly) = 03-29 23:59:59 ⇒ 指向 03-27 15:00 = 下标 1
      旧公式：「下一根」已被删 ⇒ 退化成轴末根 ⇒ 下标 5
    ⇒ 差 4 根，判别力充足。
    """
    axis = [_ep(y, m, d, H, M)
            for (y, m, d) in ((2026, 3, 27), (2026, 3, 30), (2026, 4, 2))
            for (H, M) in ((9, 33), (15, 0))]
    raw_weekly = _df("weekly", [_ep(2026, 3, 23), _ep(2026, 3, 30)])
    win_weekly = select_period_window(raw_weekly, _ep(2026, 4, 2), before_cap=None,
                                      after_end=_ep(2026, 4, 3, 23, 59), period="weekly")
    assert len(win_weekly) == 1, "03-30 那根应被 weekly 跨界过滤删掉（这是本用例的前提）"

    windows = {
        "3m": _df("3m", axis),
        "15m": _df("15m", [axis[1], axis[5]]),
        "60m": _df("60m", [axis[5]]),
        "daily": _df("daily", [_ep(2026, 4, 2)]),
        "weekly": win_weekly,
        "monthly": _df("monthly", [_ep(2026, 3, 2)]),
    }
    out = assign_global_indices(windows)
    assert list(out["weekly"]["end_global_index"]) == [1]
```

⚠️ 若 `select_period_window` 未在测试文件顶部 import，请在 import 行补上它。

- [ ] **Step 2: 跑，确认红的是预期那几条**

```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -v \
  -k "interior_historical_trailing or crosses_lunch or monthly_realistic or weekly_hole or daily_unchanged"
```

Expected: **`interior_historical_trailing` / `crosses_lunch` / `monthly_realistic` / `weekly_hole` 四条 FAIL；`daily_unchanged` PASS**（daily 新旧同解，这正是它作为正向对照的意义）

- [ ] **Step 3: 改实现**

把 `backend/generate_training_sets.py` 里 `assign_global_indices` 的循环体：

```python
        for i, _open in enumerate(opens):
            nxt = opens[i + 1] if i + 1 < len(opens) else None
            upper = (nxt - 1) if nxt is not None else three_dts[-1]
            j = bisect_right(three_dts, upper) - 1
            egi.append(max(0, min(j, n3 - 1)))
```

改为：

```python
        for _open in opens:
            upper = period_end(_open, period)
            j = bisect_right(three_dts, upper) - 1
            egi.append(max(0, min(j, n3 - 1)))
```

⛔ **其余一律不动**：`bisect_right` / `clamp` / `global_index` 仅 `3m` 赋值 / 排序 / 空窗抛 `GenerateSkipException` 全部保持原样（spec §3.2）。

同时改 docstring（`:274-276`，spec §3.3 行 4d —— 它现在写的正是 §1.1 引为缺陷证据的那段旧表述）：

```python
def assign_global_indices(windows: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    """D2/D4：3m 升序赋 global_index 0,1,2…（其它周期 NULL）；所有周期（含 3m）
    end_global_index = 「这根 K 线在全局 3 分钟轴上**于第几刻形成**」
    = bisect_right(3m_dts, period_end(本根 datetime, 周期)) - 1，clamp[0, N3-1]。

    ⭐ upper 由 `period_end` 按 datetime 标注语义分流（spec §2.1 / §2.2）：
       收盘标注（3m/15m/60m）取本根 datetime；开盘侧标注（daily/weekly/monthly）
       取该【日历周期】的结束时刻。
    ⛔ **不得退化成「下一根 open − 1」** —— 开盘侧序列允许有洞（spec §1.3）。
    """
```

以及模块头 `:16` 那行 D4：

```python
# - D4 end_global_index = bisect_right(3m_dts, period_end(本根 datetime, 周期)) - 1，clamp[0,N-1]
#      （spec 2026-09-01 §2.2；⛔ 旧表述「[open,下一open) 上界」已作废，见 §1.1）
```

- [ ] **Step 4: 跑全套，确认全绿**

```bash
cd backend && python3 -m pytest tests/ -v
```

Expected: **全部 PASS，0 failed、0 skipped**。特别确认这三条既有用例仍绿（它们是正向对照）：
`test_assign_3m_global_index_and_end_equal` / `test_assign_end_global_index_monotonic_and_in_range` / `test_assign_non_min_period_global_index_is_null`

- [ ] **Step 5: 提交**

```bash
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "fix(backend): end_global_index 按 datetime 标注语义分流（spec §2.2）

原实现对所有周期一律 upper = 下一根 datetime − 1，而仓库里有两套标注约定从未对账：
3m/15m/60m 标收盘时刻，daily/weekly/monthly 标周期开始侧。后果实测：
· 日内周期的「形成时刻」晚一整个周期（60m 每根晚 19 根 3m，标 15:00 的指到次日 10:27）；
· 开盘侧用「下一根」当边界，而周线序列允许有洞（select_period_window 会删跨界周），
  洞前那根会被判成「在洞里某个时刻才完成」——三个真实产物里两个已带此错。

改为 upper = period_end(本根 datetime, 周期)。其余（bisect_right / clamp /
global_index 仅 3m 赋值）一律不动。同步改掉模块头 :16 与 docstring 里那段旧表述
（它们正是 §1.1 引为缺陷证据的原文）。

新增边界判据：跨午休 + 跨日（15m 新 [1,3,5,7] vs 旧 [2,4,6,7]；60m 新 [3,7] vs 旧 [6,7]）、
周线洞（新 [1] vs 旧 [5]，差 4 根）、monthly 真实量级（[0,0,7]，对时区变异有判别力）；
daily 作正向对照（新旧同解 [3,7]，必须放行）。
既有三条断言按手算新值更新：15m [2,5,5]→[0,3,5]、60m [0,3,5]→[0,0,4]、monthly [1,5]→[5,5]。
⛔ 期望值全部由独立实现 §2.2 公式算出，非跑生成器抄回（变异 B18 要防的正是后者）。"
```

---

## Task 4: zip 确定性（固定 `ZipInfo.date_time`）

**Files:**
- Modify: `backend/generate_training_sets.py:368-372`（`zip_and_hash`）
- Test: `backend/tests/test_generate_training_sets.py`

**Interfaces:**
- Consumes: 无新增
- Produces: `zip_and_hash(db_path, zip_path) -> str`（签名不变，产出字节变确定）

**为什么本片必须做**（spec §3.4「其它硬要求」/ 变异 B34）：`zipfile` 默认把文件 mtime 嵌进 zip 头 ⇒ **同一输入每跑一次 CRC 都不同**。而 P4 的整个恢复模型（「R2 产物有疑 → 因为字节确定性，任何时刻重跑得到同一批包 ⇒ 不需要备份四态、不需要阶段清单」）**完全架在这条上**。

⚠️ **本改动会让现有 3 个产物的 `content_hash` 与重算值不同** —— 这是预期的：P4 本来就要重建它们。P1 交付时**不重算任何既有产物的指纹**。

- [ ] **Step 1: 写会失败的测试**

```python
# ── Task 4：确定性压缩（spec §3.4「其它硬要求」；变异 B34）

def test_zip_and_hash_is_deterministic_across_runs(tmp_path):
    """同一输入连跑两次 ⇒ zip 字节与 CRC32 完全相同。

    ⭐ 这是 P4 恢复模型的唯一依据（「产物有疑就重跑 R2，必得同一批包」）。
    默认 zipfile 会把 db 文件的 mtime 嵌进 zip 头 ⇒ 不固定 date_time 就每跑一次都变。
    构造：先造一份 .db，再改它的 mtime（模拟两次运行落在不同时刻），压两次比字节。
    """
    import os
    from generate_training_sets import zip_and_hash

    db = tmp_path / "x.db"
    db.write_bytes(b"deterministic-payload" * 64)

    z1 = tmp_path / "a.zip"
    os.utime(db, (1_600_000_000, 1_600_000_000))
    h1 = zip_and_hash(db, z1)
    b1 = z1.read_bytes()

    z2 = tmp_path / "b.zip"
    os.utime(db, (1_700_000_000, 1_700_000_000))   # mtime 变了
    h2 = zip_and_hash(db, z2)
    b2 = z2.read_bytes()

    assert h1 == h2, "CRC32 随 mtime 变化 ⇒ 确定性不成立"
    assert b1 == b2, "zip 字节随 mtime 变化 ⇒ 确定性不成立"


def test_zip_member_name_is_db_basename(tmp_path):
    """成员名契约不变（`<code>_<start>.db`）—— 改确定性时不得顺手改它。"""
    import zipfile as _z
    from generate_training_sets import zip_and_hash
    db = tmp_path / "600519.SH_1762099200.db"
    db.write_bytes(b"payload")
    zp = tmp_path / "out.zip"
    zip_and_hash(db, zp)
    with _z.ZipFile(zp) as zf:
        assert zf.namelist() == ["600519.SH_1762099200.db"]
```

- [ ] **Step 2: 跑，确认第一条红**

```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -v -k "zip_and_hash_is_deterministic or zip_member_name"
```

Expected: `test_zip_and_hash_is_deterministic_across_runs` **FAIL**（CRC 不等）；`test_zip_member_name_is_db_basename` **PASS**

- [ ] **Step 3: 改实现**

```python
def zip_and_hash(db_path: Path, zip_path: Path) -> str:
    """D3：把 .db 压进 zip → 返回整个 zip 文件字节的 CRC32（8 字符小写）。

    ⭐ **确定性**（spec §3.4「其它硬要求」）：固定 `ZipInfo.date_time` 与权限位，使同一输入
    **恒产出同一字节** —— `zipfile` 默认把文件 mtime 嵌进 zip 头，不固定就每跑一次 CRC 都变，
    而运维侧「产物有疑就重跑、必得同一批包」这条恢复前提完全架在本条上。
    ⛔ 成员名仍是 `db_path.name`（`<code>_<start>.db`），契约不变。
    """
    info = zipfile.ZipInfo(filename=db_path.name, date_time=(1980, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16          # 固定权限位，避免 umask 影响字节
    with zipfile.ZipFile(zip_path, "w") as zf:
        zf.writestr(info, db_path.read_bytes())
    return crc32_hex(zip_path.read_bytes())
```

- [ ] **Step 4: 跑，确认两条都绿，且全套没被碰坏**

```bash
cd backend && python3 -m pytest tests/ -v
```

Expected: **全部 PASS，0 failed、0 skipped**

- [ ] **Step 5: 提交**

```bash
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "fix(backend): zip 产出确定化（固定 ZipInfo.date_time 与权限位）

zipfile 默认把 .db 的 mtime 嵌进 zip 头 ⇒ 同一输入每跑一次 CRC32 都不同。而运维侧的
整个恢复模型（spec §3.4：产物有疑就重跑 R2、必得同一批包 ⇒ 不需要备份四态与阶段清单）
完全架在「字节确定」这一条上。变异 B34 钉的就是它。

成员名契约不变（<code>_<start>.db），另配一条用例守住。
⚠️ 本改动会让既有 3 个产物的 content_hash 与重算值不同——预期之内，P4 本就要重建它们。"
```

---

## Task 5: 产物代际 `user_version` `1` → `2`

**Files:**
- Modify: `backend/sql/training_set_schema_v1.sql:2-3,5`
- Modify: `backend/generate_training_sets.py:39`（`SCHEMA_VERSION`）、`:313-316`（DDL 字面量与那段注释）
- Modify: `backend/sql/tests/test_training_set_schema.sh:10-13,38`
- Modify: `scripts/acceptance/plan_b2_generate_training_sets.sh:30`
- Modify: `docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md:46`

**Interfaces:**
- Consumes: 无
- Produces: `SCHEMA_VERSION = 2`；新产物 `PRAGMA user_version = 2`

**判据依据**（spec §2.3）：迁移前后的产物**互不可读**（同一张表、同一组列，但 `end_global_index` 取值语义变了）⇒ 属**两代**。⚠️ **判断依据是「新旧产物能否互读」，不是「列有没有变」** —— 冻结 schema 文件 `:3` 自己写着「schema 变更时 bump `user_version`，旧 version reader 直接拒收」。

⚠️ **本 Task 的四个文件必须在同一个提交里改完**，否则 schema CI（`test_training_set_schema.sh`）在中间状态是红的。

- [ ] **Step 1: 先改 CI 硬门的期望值（让它红）**

`backend/sql/tests/test_training_set_schema.sh`，把 `:10-13`：

```bash
# PRAGMA user_version 必须 = 1
UV=$(sqlite3 "$DB" "PRAGMA user_version;")
if [[ "$UV" != "1" ]]; then
  echo "FAIL: expected user_version=1, got $UV"
```

改为：

```bash
# PRAGMA user_version 必须 = 2（spec 2026-09-01 §2.3：end_global_index 语义变更 ⇒ 新旧产物互不可读 ⇒ 第 2 代）
UV=$(sqlite3 "$DB" "PRAGMA user_version;")
if [[ "$UV" != "2" ]]; then
  echo "FAIL: expected user_version=2, got $UV"
```

并把末行 `:38`：

```bash
echo "PASS: training_set_schema_v1.sql deploys with user_version=1"
```

改为：

```bash
echo "PASS: training_set_schema_v1.sql deploys with user_version=2"
```

- [ ] **Step 2: 跑，确认它红**

```bash
bash backend/sql/tests/test_training_set_schema.sh; echo "退出码=$?"
```

Expected: **FAIL: expected user_version=2, got 1**，退出码 **1**

- [ ] **Step 3: 改 DDL 与常量**

**(a)** `backend/sql/training_set_schema_v1.sql`，把 `:2-3` 与 `:5`：

```sql
-- 每个训练组生成为独立 .db 文件，PRAGMA user_version=1 标识版本
-- 不支持 rollback：schema 变更时 bump user_version，旧 version reader 直接拒收

PRAGMA user_version = 1;
```

改为：

```sql
-- 每个训练组生成为独立 .db 文件，PRAGMA user_version=2 标识版本
-- 不支持 rollback：schema 变更时 bump user_version，旧 version reader 直接拒收
-- v1 → v2（2026-09-01）：表结构不变，但 end_global_index 的取值语义改为「按 datetime 标注
--   分流后反算」⇒ 新旧产物互不可读 ⇒ 属两代（判据是「能否互读」，不是「列有没有变」）

PRAGMA user_version = 2;
```

**(b)** `backend/generate_training_sets.py:39`：

```python
SCHEMA_VERSION = 2
```

**(c)** `backend/generate_training_sets.py:313-316`（DDL 字面量与那段注释 —— ⛔ **保留「为何写字面量而非 f-string」的理由**，并按 spec §3.3 行 3d 把锚点路径写进注释）：

```python
# 训练组 SQLite DDL（逐字 backend/sql/training_set_schema_v1.sql，D8；本 PR 只读不改源文件）
# 注：`PRAGMA user_version = 2` 用字面 2（== SCHEMA_VERSION）以逐字对齐冻结 schema 文件
# （原 f-string `{SCHEMA_VERSION}` 渲染后不含子串 "user_version = 2"，会让验收 grep 锚失配）。
# 锚点在：scripts/acceptance/plan_b2_generate_training_sets.sh:30
#         docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md:46
_TRAINING_SET_DDL = """
PRAGMA user_version = 2;
```

**(d)** `scripts/acceptance/plan_b2_generate_training_sets.sh:30` —— ⛔ **只改这一行**，不顺手修该脚本先前遗留的其它 stale 行（spec §3.3 行 3d 明令，避免范围蔓延）：

```bash
grep -q 'PRAGMA user_version = 2' backend/generate_training_sets.py
```

**(e)** `docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md:46` —— 同样**只改这一行**：

```markdown
| F.1 | `grep -nc 'PRAGMA user_version = 2' backend/generate_training_sets.py` | 1 (schema_version) | =1 |
```

- [ ] **Step 4: 跑，确认全绿**

```bash
bash backend/sql/tests/test_training_set_schema.sh; echo "退出码=$?"
cd backend && python3 -m pytest tests/ -v
```

Expected: shell 门打印 `PASS: training_set_schema_v1.sql deploys with user_version=2`、退出码 **0**；pytest **全部 PASS，0 failed、0 skipped**。
⭐ 特别确认 `test_build_sqlite_user_version_meta_and_rowcount` 绿 —— 它断言 `PRAGMA user_version == SCHEMA_VERSION`，两边同时改成 2 才会绿（变异 B9 钉的就是这条）。

- [ ] **Step 5: 复核那两条「7 轮没进过评审视野」的清单项**

⛔ **spec §8 明令的独立复核**：§3.3 的 `4`（m01 治理契约矩阵）与 `4b`（本 Task 改的 `test_training_set_schema.sh`）因历史上的表格断裂，**在 codex R9–R15 共 7 轮里都不在「清单条目」的视野内**。⇒ 不得默认「已被多轮评审过」。

本 Task 只负责 `4b`。逐条确认（把输出贴进提交说明）：

```bash
grep -n 'user_version' backend/sql/tests/test_training_set_schema.sh
grep -rn 'test_training_set_schema.sh' .github/workflows/
```

Expected: 前者只剩 `2`、无残留的 `1`；后者证明这道门**确实在 CI 里跑**（`schema-smoke.yml`）—— 若它根本没被 CI 调用，那这条「硬门」是假的，**必须当场报告，不要继续**。
⚠️ `4`（m01 矩阵）归 P3，本片不动，但**P3 必须同样做一次独立复核**。

- [ ] **Step 6: 提交**

```bash
git add backend/sql/training_set_schema_v1.sql backend/generate_training_sets.py \
        backend/sql/tests/test_training_set_schema.sh \
        scripts/acceptance/plan_b2_generate_training_sets.sh \
        docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md
git commit -m "feat(backend)!: 训练组产物代际 user_version 1 → 2（spec §2.3）

表结构不变（无新列 / 无类型变化 / 无约束变化），但 end_global_index 的取值语义改了
⇒ 新旧产物互不可读 ⇒ 属两代。判据是「能否互读」，不是「列有没有变」——冻结 schema
文件自己写着「schema 变更时 bump user_version，旧 version reader 直接拒收」。

同步四处：DDL 源文件、SCHEMA_VERSION 常量、生成器内逐字 DDL 的字面量、schema CI 硬门。
另改两处既有验收 grep 锚（plan_b2_…sh:30 与 2026-05-29 验收表 :46）——⛔ 只改本片相关
的那一行，不顺手修这两个文件先前遗留的其它 stale 行。
DDL 字面量保留「为何写字面 2 而非 f-string」的理由，并按 spec §3.3 行 3d 把两个锚点
路径写进注释（原文只说「有个验收 grep 锚」却从没定位过它在哪）。

⛔ 独立复核（spec §8 明令）：4b 这条 CI 硬门因历史表格断裂，在 codex R9–R15 共 7 轮里
都不在清单条目视野内，本次已单独核过它确实被 .github/workflows 调用。"
```

---

## Task 6: 变异逐条跑并记录

**Files:**
- Create: `docs/acceptance/2026-09-03-trainingset-p1-mutation-log.md`

**Interfaces:**
- Consumes: Task 1–5 的全部实现与测试
- Produces: 一份逐条变异记录，供 PR 正文与后续切片引用

**判据**（spec §7 第 1 条）：**每组写明红的是哪一条测试**。⛔ 只写「已验证」不算 —— 那正是本仓「假绿家族」的标准形态。

⚠️ 本片只跑**本片射程内**的变异；其余归 P2/P3/P4。

- [ ] **Step 1: 建记录文件骨架**

```bash
cat > docs/acceptance/2026-09-03-trainingset-p1-mutation-log.md <<'EOF'
# 切片一 · P1 变异验证记录

> spec：`docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §4
> 判据：每组必须写明**红的是哪一条测试**（⛔ 只写「已验证」不算）
> 复原：⛔ 不用 `git checkout <file>`（会静默抹掉未提交改动）；用 `git stash push -u -m` 或手工改回

| 变异 | 改了什么 | 红的是哪一条测试 | 结论 |
|---|---|---|---|
EOF
```

- [ ] **Step 2: 逐条跑（本片射程内 8 组 + 1 组组合）**

⚠️ **每跑一组之前先清字节码缓存**，否则等长改动 + 同秒复原会命中陈旧 `.pyc`、两个方向的结论都可能是假的：

```bash
cd backend && find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; \
  PYTHONDONTWRITEBYTECODE=1 python3 -m pytest tests/ -q
```

逐条执行下表，每条：**改 → 清缓存 → 跑 → 记下红的用例名 → 改回 → 再跑确认恢复全绿**。

| 变异 | 具体怎么改 | 预期红的用例 |
|---|---|---|
| **B1** | `assign_global_indices` 里 `upper = period_end(_open, period)` 改回「下一根 − 1」 | `test_assign_intraday_crosses_lunch_and_day_boundary`、`test_assign_end_global_index_interior_historical_trailing`、`test_assign_weekly_hole_uses_calendar_period_end` |
| **B2** | `period_end` 的分流反过来（`if period not in _CLOSE_LABELLED: return int(datetime_epoch)`） | `test_assign_daily_unchanged_by_the_split`、`test_assign_monthly_realistic_scale` |
| **B3** | 只把**开盘侧**改回「下一根 − 1」（日内保持新式） | `test_assign_weekly_hole_uses_calendar_period_end` |
| **B4** | `period_end` 的 `tzinfo=_SHANGHAI` 改成 `tzinfo=_dt.timezone.utc` | `test_assign_monthly_realistic_scale`、`test_period_end_daily_is_end_of_that_trading_day` |
| **B5** | 日内分支改成固定偏移（`return int(datetime_epoch) - 1140`，即减 19 根 3m 的秒数） | `test_assign_intraday_crosses_lunch_and_day_boundary` |
| **B6** | `period_end` 里 weekly 分支改成走 `daily` 的算法 | `test_period_end_weekly_is_that_weeks_sunday`、`test_assign_weekly_hole_uses_calendar_period_end` |
| **B7** | `_CLOSE_LABELLED` 里加上 `"daily"` | `test_assign_daily_unchanged_by_the_split` |
| **B9** | `SCHEMA_VERSION` 改回 `1`（DDL 字面量保持 2） | `test_build_sqlite_user_version_meta_and_rowcount` |
| **B34** | `zip_and_hash` 改回 `zf.write(db_path, arcname=db_path.name)` | `test_zip_and_hash_is_deterministic_across_runs` |
| **B66** | 把 `_week_end_date` 挪回 `select_period_window` 函数体内 | `test_week_end_date_is_module_level_and_shared` |
| **B1+B3 组合** | 同时施加 B1 与 B3 | ⚠️ 必须确认**仍有测试红**并记下是哪一条 —— 这一组是防「两条变异互相掩盖」（spec §4.1 末） |

⛔ **每一条都要真的看到红**。若某条**没红**，那不是「通过」，是**判据不成立** —— 停下来，把该条的观测量与实现对齐后重跑，并在记录里写明原委。

- [ ] **Step 3: 确认恢复全绿**

```bash
cd backend && find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; \
  python3 -m pytest tests/ -v
git status --short   # 应为空——所有变异都已复原
```

Expected: pytest **全部 PASS、0 failed、0 skipped**；`git status --short` **无输出**

- [ ] **Step 4: 提交记录**

```bash
git add docs/acceptance/2026-09-03-trainingset-p1-mutation-log.md
git commit -m "docs(acceptance): 切片一 P1 变异验证记录（本片射程内 10 组 + 1 组组合）

spec §7 第 1 条要求「每组写明红的是哪一条测试」——只写「已验证」不算，那正是本仓
假绿家族的标准形态。B1+B3 组合单列，防两条变异互相掩盖。
每组均先清 __pycache__ 再跑（等长改动 + 同秒复原会命中陈旧 .pyc，两个方向的结论
都可能是假的）。"
```

---

## Task 7: 交付前自检

**Files:** 无（只跑校验）

- [ ] **Step 1: 后端 CI 口径全套（Linux 零 skip 是 CI 的要求，本地先自查 skip 数）**

```bash
cd backend && python3 -m pytest tests/ -v --tb=short 2>&1 | tail -20
```

Expected: 末行形如 `NN passed in X.XXs`，**skipped = 0、failed = 0**

- [ ] **Step 2: schema CI 硬门**

```bash
bash backend/sql/tests/test_training_set_schema.sh; echo "退出码=$?"
```

Expected: `PASS: training_set_schema_v1.sql deploys with user_version=2`，退出码 `0`

- [ ] **Step 3: 确认本片没碰 App**

```bash
git diff --name-only origin/main...HEAD | grep -c '^ios/' || echo 0
```

Expected: **0**（⛔ 本片不碰任何 App 逻辑；`CONTRACT_VERSION` 相关的 iOS 常量归 P3）

- [ ] **Step 4: 确认旧表述已清干净**

```bash
grep -n '下一根 open\|下一open\|\[open, *下一' backend/generate_training_sets.py
```

Expected: **无输出**（`:16` 与 docstring 两处旧表述都已改写；spec §3.3 行 4d）

- [ ] **Step 5: 确认没有残留的 `user_version = 1`**

```bash
grep -rn 'user_version = 1\|user_version=1' backend/ scripts/acceptance/ docs/acceptance/ 2>/dev/null
```

Expected: 只应命中 `docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md:16`（它锚的是 **App 侧** `DebugTrainingSetWriter` 的常量，**切片一保持 `1` 是正确的**，⛔ 不得改，spec 变异 B33 明写它必须进白名单）。其余任何命中都要当场定性。

---

## Self-Review（写完后的自查，已执行）

**1. 本片对 spec 的覆盖**

| spec 条目 | 落在哪个 Task | 备注 |
|---|---|---|
| §3.1 `period_end` | Task 2 | 含时区规矩、⛔ 禁 `isocalendar`、显式常量表 |
| §3.1 复用 `_week_end_date` | Task 1 | 提取到模块级 + 共用性测试（B66） |
| §3.2 分流 | Task 3 | 其余一律不动 |
| §3.3 第 1/2/3 项 | Task 5 | DDL / 生成器字面量 / `SCHEMA_VERSION` |
| §3.3 4b | Task 5 | schema CI 硬门 + spec §8 明令的独立复核 |
| §3.3 4c | Task 3 | 三条断言新值 + monthly 专用用例 |
| §3.3 4d | Task 3 | `:16` 与 docstring 两处旧表述 |
| §3.3 3e | Task 1 | — |
| §3.3 3d（两处 `user_version = 1` 锚） | Task 5 | m01 矩阵那处归 P3 |
| §3.4「确定性压缩」 | Task 4 | — |
| §7 第 1 条（变异逐条记录） | Task 6 | 本片射程内 10 组 + 1 组组合 |

⛔ **本片不覆盖**（各有归属，已在开头的分片表里写明）：§4.1 跨端 fixture（P2）、§3.3 其余同步点与守卫（P3）、§3.4 R0–R7（P4）。

**2. 占位符扫描**：本计划无 `TBD` / `TODO` / 「类似 Task N」/「加上适当的错误处理」/ 无代码的测试步骤。每个 code step 都给了可直接粘贴的代码。

**3. 类型与命名一致性**：`period_end(datetime_epoch: int, period: str) -> int`、`_week_end_date(open_epoch: int) -> _dt.date`、`_CLOSE_LABELLED: frozenset[str]`、`zip_and_hash(db_path: Path, zip_path: Path) -> str` —— Task 2/3/4 引用的名字与定义处逐一对应；测试里的 `_ep` / `_sh_dt` / `_df` / `_intraday_axis` 也都在使用前定义。

**4. 期望值来历**：本计划全部期望值（`[0,3,5]` / `[0,0,4]` / `[5,5]` / `[1,3,5,7]` / `[3,7]` / `[0,0,7]` / `[1]` 与各 `period_end` 日期）均由**独立实现 spec §2.2 的公式**算出，**未 import 被测代码**；每组的推导写在对应测试的 docstring 里，实施者可照着复算。

---

## 已知残留（本片不解决，须带进后续片）

1. ⛔ **库里那 3 个产物仍是第 1 代** —— P1 只改代码，重建在 P4。P1 合并后到 P4 完成之间，生成器会产出第 2 代、而库存是第 1 代，**这段窗口里 `api` / `scheduler` / 生成器 CLI 必须保持停止**（spec §3.4 静默期）。
2. ⛔ **`CONTRACT_VERSION` 仍是 `"1.13"`** —— 顶层 bump 归 P3。spec §3.3 明写「留着不 bump 会让本片合并后治理契约处于被违反状态」⇒ **P3 必须紧跟 P1，不得长期悬空**。
3. ⛔ **冻结契约 `kline_trainer_modules_v1.4.md:2302`（R03）与 `kline_trainer_plan_v1.5.md:1285` 仍写着「全周期严格递增」** —— 与本片 §2.2 直接矛盾，归 P3。在 P3 落地前，**任何照 R03 写的守卫都会把新产物判死**。
4. ⛔ **既有 3 个产物的 `content_hash` 与重算值已不同**（Task 4 的确定性改动 + Task 3 的公式改动共同导致）—— 预期之内，P4 重建时一并处理。
