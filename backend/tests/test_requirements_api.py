# backend/tests/test_requirements_api.py
"""C1-1 / T1：API 容器依赖清单必须裁剪且与主清单 pin 一致。

为什么要裁剪（spec §4-D2）：`requirements.txt` 含 `pandas-ta==0.3.14b1`，
那是数据导入脚本用的，且是已知的安装陷阱。API 运行只需 fastapi / uvicorn / asyncpg
（读 `backend/app/*.py` 的 import 得到）。

为什么要双向锁 pin：两份清单各自漂移会让「本地 pytest 用的版本」与
「容器里真跑的版本」悄悄分家 —— 那是最难查的一类线上问题。
"""
from __future__ import annotations

import re
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
MAIN_REQS = BACKEND_DIR / "requirements.txt"
API_REQS = BACKEND_DIR / "requirements-api.txt"

EXPECTED_API_PACKAGES = {"fastapi", "uvicorn", "asyncpg"}

# 只认精确 pin：`name==version`。任何 >= / <= / ~= / > / < 都不算。
_EXACT_PIN_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([^\s;]+)$")


def _parse(path: Path) -> dict[str, str]:
    """requirements 文件 → {包名小写: 版本}。跳过空行与整行注释。

    不容忍无法解析的行：解析不了就抛，避免「读进来是空的 → 断言恒真」。
    """
    pins: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = _EXACT_PIN_RE.match(line)
        if match is None:
            raise AssertionError(
                f"{path.name} 里这一行不是精确 pin（name==version）: {raw!r}"
            )
        pins[match.group(1).lower()] = match.group(2)
    return pins


def test_api_requirements_is_not_empty():
    """防空转：解析结果为空时下面所有断言都会恒真。"""
    assert _parse(API_REQS), "requirements-api.txt 解析结果为空 —— 判据已失效"


def test_api_requirements_package_set_is_exact():
    """T1-4：包集合恰好三项，多一个少一个都红。"""
    assert set(_parse(API_REQS)) == EXPECTED_API_PACKAGES


def test_api_requirements_pins_match_main_requirements():
    """T1-1 / T1-2 / T1-3：每个包在主清单里存在，且版本逐字相同（两个方向都会红）。"""
    api = _parse(API_REQS)
    main = _parse(MAIN_REQS)
    for name, version in sorted(api.items()):
        assert name in main, f"{name} 在 requirements.txt 里不存在"
        assert version == main[name], (
            f"{name} 版本不一致: requirements-api.txt={version} / requirements.txt={main[name]}"
        )


def test_api_requirements_has_no_version_ranges():
    """T1-5：全精确 pin。_parse 遇到 range 会抛 AssertionError，这里显式跑一次证明。"""
    _parse(API_REQS)  # 不抛即通过


def test_api_requirements_excludes_pandas_ta():
    """C1-1 的意图档：那个已知安装陷阱绝不能溜进 API 镜像。"""
    assert "pandas-ta" not in _parse(API_REQS)
