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

import pytest

BACKEND_DIR = Path(__file__).resolve().parents[1]
MAIN_REQS = BACKEND_DIR / "requirements.txt"
API_REQS = BACKEND_DIR / "requirements-api.txt"
# CI（.github/workflows/backend-tests.yml）装的是这一份，不是 requirements.txt。
TEST_REQS = BACKEND_DIR / "requirements-test.txt"
# hardening_6_gate.yml（Python 3.12）与 openapi-smoke.yml 装的是这一份。
DEV_REQS = BACKEND_DIR / "requirements-dev.txt"

EXPECTED_API_PACKAGES = {"fastapi", "uvicorn", "asyncpg"}

# 只认单一精确 pin：`name==version`。拒绝 >= / <= / ~= / > / <、通配符（7.*）与复合多约束。
_EXACT_PIN_RE = re.compile(
    r"^([A-Za-z0-9][A-Za-z0-9._-]*)==([A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*(?:\+[A-Za-z0-9.]+)?)$"
)


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


def _assert_shared_pins_match(
    left_name: str,
    left: dict[str, str],
    right_name: str,
    right: dict[str, str],
) -> None:
    """校验两份清单交集非空且所有共享包的精确版本逐字一致。"""
    shared = sorted(set(left) & set(right))
    assert shared, (
        f"{left_name} 与 {right_name} 没有任何同名包 —— "
        "下面的循环恒真通过，本条判据已失效"
    )
    for name in shared:
        assert left[name] == right[name], (
            f"{name} 版本不一致: {left_name}={left[name]} / "
            f"{right_name}={right[name]}"
        )


def _assert_dev_pins_match_test(
    dev: dict[str, str],
    test: dict[str, str],
) -> None:
    """校验 requirements-dev.txt 为 requirements-test.txt 子集、含 pglast 且共享版本一致。"""
    assert dev, "requirements-dev.txt 解析结果为空 —— 判据已失效"
    assert "pglast" in dev, "requirements-dev.txt 缺少 pglast"
    missing = sorted(set(dev) - set(test))
    assert not missing, (
        f"requirements-dev.txt 中的包未出现在 requirements-test.txt: {missing}"
    )
    _assert_shared_pins_match(
        "requirements-dev.txt", dev, "requirements-test.txt", test
    )


def test_api_and_test_requirements_pins_match():
    """CI 真正安装的是 requirements-test.txt —— 这条把那一侧也锁上。

    为什么单独一条：本文件开头承诺「本地 pytest 用的版本」不能与「容器里真跑的版本」
    分家，但上面那条锁的是 requirements.txt，而 CI 从来不装它。只锁 requirements.txt
    的话，把 requirements-test.txt 里的 fastapi 单独提一个版本，**没有任何测试会红** ——
    那正好就是承诺要挡住的那种漂移。

    交集为什么现在只有 {fastapi}：uvicorn 与 asyncpg 是**刻意**不在测试清单里的
    （测试里没有任何东西 import 它们，装了只是浪费 CI 时间）。所以这条比对的
    公共包目前就 fastapi 一个 —— 下面那句防空转断言就是用来在「哪天交集变空了」
    时当场报错的，否则循环会静默地一条都不比。
    """
    _assert_shared_pins_match(
        "requirements-api.txt",
        _parse(API_REQS),
        "requirements-test.txt",
        _parse(TEST_REQS),
    )


def test_api_requirements_has_no_version_ranges():
    """T1-5：全精确 pin。_parse 遇到 range 会抛 AssertionError，这里显式跑一次证明。"""
    _parse(API_REQS)  # 不抛即通过


def test_api_requirements_excludes_pandas_ta():
    """C1-1 的意图档：那个已知安装陷阱绝不能溜进 API 镜像。"""
    assert "pandas-ta" not in _parse(API_REQS)


def test_dev_and_test_requirements_pins_match():
    """CI 的 dev 清单与 full-suite test 清单共享包（含 pglast）版本必须逐字一致。"""
    _assert_dev_pins_match_test(_parse(DEV_REQS), _parse(TEST_REQS))


def test_dev_requirements_has_no_version_ranges(tmp_path: Path):
    """requirements-dev.txt 只允许单一精确 == pin，拒绝区间、通配符与复合约束。"""
    _parse(DEV_REQS)
    for bad_line in ("foo>=1.0\n", "foo==1.*\n", "foo==1.0,!=1.1\n"):
        req_file = tmp_path / "requirements-bad.txt"
        req_file.write_text(bad_line, encoding="utf-8")
        with pytest.raises(AssertionError):
            _parse(req_file)


def test_shared_pins_guard_rejects_version_drift():
    """共享包版本一旦在两份清单中分叉，守卫必须抛出含包名的 AssertionError。"""
    with pytest.raises(AssertionError, match="pkg"):
        _assert_shared_pins_match(
            "left.txt", {"pkg": "1.0"}, "right.txt", {"pkg": "2.0"}
        )


def test_shared_pins_guard_rejects_empty_overlap():
    """交集为空时守卫必须报错，防止比对循环一次都不执行而假绿。"""
    with pytest.raises(AssertionError):
        _assert_shared_pins_match(
            "left.txt", {"alpha": "1.0"}, "right.txt", {"beta": "1.0"}
        )


def test_dev_pins_guard_rejects_missing_package_from_test():
    """dev 清单出现 test 清单缺少的包时，必须失败并点名缺失包。"""
    with pytest.raises(AssertionError, match="extra-pkg"):
        _assert_dev_pins_match_test(
            {"pglast": "1.0", "extra-pkg": "2.0"}, {"pglast": "1.0"}
        )


def test_dev_pins_guard_requires_pglast():
    """dev 清单缺少 pglast 时，守卫必须明确拒绝。"""
    with pytest.raises(AssertionError, match="pglast"):
        _assert_dev_pins_match_test({"pytest": "1.0"}, {"pytest": "1.0"})
