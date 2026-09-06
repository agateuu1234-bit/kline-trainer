# backend/tests/_trainingset_contract_fixture.py
"""跨端契约 fixture 的**唯一**构造入口（spec §4.1）。

⭐ 生产者半边的三步全部走**生产代码**：合成 bars → `select_period_window` 切窗
   → `assemble_from_windows` 装配。
⛔ **不得**自己串调 `assign_global_indices` / `build_training_set_sqlite` / `zip_and_hash`：
   真正决定 zip 成员名的是 `assemble_from_windows` 里的 `f"{fname}.db"`，绕过它的测试对
   那一行**零敏感**（spec §4.1 note 1 / 变异 B64）。
⛔ 本模块**只造输入**。期望值（逐周期索引向量）是**手写字面量**，写在
   `test_trainingset_contract_fixture.py` 里 —— ⛔ 绝不由本模块或生成器算出，否则
   生产者与校验者会**一起用错公式而全绿**，那正是缺陷藏住的机制（spec §4.1 note 3 / 变异 B18）。
"""
from __future__ import annotations

import datetime as _dt
from pathlib import Path
from zoneinfo import ZoneInfo

import pandas as pd

from generate_training_sets import (
    PERIOD_BEFORE_CAP,
    PERIODS,
    GeneratedTrainingSet,
    assemble_from_windows,
    select_period_window,
)

_SH = ZoneInfo("Asia/Shanghai")   # ⛔ tz 数据库，不得写固定 +08:00


def _ep(y: int, m: int, d: int, H: int = 0, M: int = 0, S: int = 0) -> int:
    """Asia/Shanghai 的 Unix 秒。"""
    return int(_dt.datetime(y, m, d, H, M, S, tzinfo=_SH).timestamp())


# ── 身份：这三个常量决定 zip 与其内部成员的文件名，属**跨端契约**，改动 = 改契约
STOCK_CODE = "999002.SZ"        # 合成代码（合法格式、非真实上市股）；999001.SZ 已被
                                # backend/scripts/verify_qmt_pg_chain.py 占用
STOCK_NAME = "跨端契约样例"       # 刻意非 ASCII：顺带把 UTF-8 往返也钉进 fixture
START_DATETIME = _ep(2026, 4, 1)        # 周三 = **周中**（特征③的前提），同时是月边界
END_DATETIME = _ep(2026, 4, 2) - 1      # 起点当日 23:59:59

FIXTURE_ZIP_NAME = f"{STOCK_CODE}_{START_DATETIME}.zip"
FIXTURE_DB_NAME = f"{STOCK_CODE}_{START_DATETIME}.db"

# 仓库根 = backend/tests/ 的上上级（与 backend/tests/test_openapi.py:121 同款算法，
# ⇒ 与进程 CWD 无关；CI 是 `working-directory: backend` 跑的）。
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE_ZIP = REPO_ROOT / "tests" / "contract-fixtures" / "training-set" / FIXTURE_ZIP_NAME

# ── 压缩交易日（spec §4.1 note 3 ⭐ 明许）：每个交易日只放 6 根 3m，
#    照样覆盖「跨午休」（11:30 → 14:57）与「跨日」（15:00 → 次日 09:33）两条边界。
#    依据：`assemble_from_windows` 不校验每日根数（`per_day_intraday_complete` 只在
#    `build_training_windows` 里被调）⇒ 手写期望值控制在几十个量级。
_DAYS = ((2026, 3, 27), (2026, 3, 30), (2026, 3, 31), (2026, 4, 1))   # 五 / 一 / 二 / 三
_INTRADAY = ((9, 33), (9, 36), (11, 27), (11, 30), (14, 57), (15, 0))

RAW_DATETIMES: dict[str, list[int]] = {
    "3m":      [_ep(*day, *hm) for day in _DAYS for hm in _INTRADAY],
    "15m":     [_ep(*day, *hm) for day in _DAYS for hm in ((11, 30), (15, 0))],
    "60m":     [_ep(*day, 15, 0) for day in _DAYS],
    # 多给一根 03-26（起点前一天）：它的 period_end 早于 3m 轴首 ⇒ clamp 到 0
    "daily":   [_ep(2026, 3, 26)] + [_ep(*day) for day in _DAYS],
    # 03-30 那根会被 select_period_window 删掉（周末 04-05 ≥ 起点当日 04-01）⇒ 洞
    "weekly":  [_ep(2026, 3, 16), _ep(2026, 3, 23), _ep(2026, 3, 30)],
    # 前两根的月末都早于 3m 轴首 ⇒ 两根都 clamp 到 0 = spec §4.1 特征①
    "monthly": [_ep(2026, 1, 1), _ep(2026, 2, 1), _ep(2026, 3, 1), _ep(2026, 4, 1)],
}


def _synth_bars(period: str, datetimes: list[int]) -> pd.DataFrame:
    """确定性合成 bar：所有数值只由**该周期内的序号 i** 决定 ⇒ 同一输入恒等。

    `0.25` 在二进制里精确可表示，避免浮点累加漂移让 fixture 字节随平台变。
    指标列刻意全部给**真值而非 NULL**，让切片二的读取链路也要真的解一遍。
    """
    rows = []
    for i, e in enumerate(datetimes):
        close = 10.0 + i * 0.25
        rows.append({
            "period": period, "datetime": e,
            "open": close - 0.1, "high": close + 0.2, "low": close - 0.2, "close": close,
            "volume": 1000 + i, "amount": round(close * (1000 + i), 2),
            "ma66": round(close - 0.05, 4), "boll_upper": round(close + 1, 4),
            "boll_mid": round(close, 4), "boll_lower": round(close - 1, 4),
            "macd_diff": round(0.01 * i, 6), "macd_dea": round(0.008 * i, 6),
            "macd_bar": round(0.004 * i, 6),
        })
    return pd.DataFrame(rows)


def build_windows() -> dict[str, pd.DataFrame]:
    """走**生产**切窗函数 `select_period_window` 把合成 bars 切成 windows。

    ⛔ **不得**改成「手工挑几根塞进去」：spec §4.1 特征③要的是一处**真的被生产代码删掉**
    的跨界周。手工挑根的话，那条特征就是假的 —— 生产切窗逻辑哪天改了也不会有人红。
    """
    return {p: select_period_window(_synth_bars(p, RAW_DATETIMES[p]),
                                    START_DATETIME, PERIOD_BEFORE_CAP[p],
                                    END_DATETIME, p)
            for p in PERIODS}


def build_fixture(output_dir) -> GeneratedTrainingSet:
    """产出一份训练组 zip 到 `output_dir`，返回生成器自己的 `GeneratedTrainingSet`。"""
    return assemble_from_windows(Path(output_dir), stock_code=STOCK_CODE, stock_name=STOCK_NAME,
                                 start_datetime=START_DATETIME, end_datetime=END_DATETIME,
                                 windows=build_windows())
