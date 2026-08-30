# backend/tests/test_dockerfile.py
"""C1-2 / T5 / T6-5：API 镜像的基础镜像形态与依赖来源。

供应链固定（spec C1-8 ①②）按服务类型分两条：
  - 拉取型服务（compose 里有 image: 无 build:）→ image: 必须带 @sha256: digest；
  - 构建型服务（有 build:）→ 供应链固定由**本文件的 FROM** 承担。
所以这里的 FROM 必须同时具备「精确 patch tag」与「@sha256: digest」。

⚠️ 本文件只做**文本结构**断言。「digest 是不是多架构 index」需要网络 + Docker
（`docker buildx imagetools inspect`），CI 不保证有，且本仓 CI 把任何 skip 判失败
→ 那条归验收清单 / runbook（spec T6-7）。
"""
from __future__ import annotations

import re
from pathlib import Path

DOCKERFILE = Path(__file__).resolve().parents[1] / "Dockerfile"

# python:<major>.<minor>.<patch>-slim@sha256:<64 hex>
_FROM_RE = re.compile(
    r"^FROM\s+python:(\d+\.\d+\.\d+)-slim@sha256:([0-9a-f]{64})\s*$"
)


def _lines() -> list[str]:
    return DOCKERFILE.read_text(encoding="utf-8").splitlines()


def _from_lines() -> list[str]:
    return [ln for ln in _lines() if ln.strip().startswith("FROM ")]


def _instruction_lines() -> list[str]:
    """剥掉整行注释与空行 —— 判据只许读**指令**，不许读注释（本仓明令）。

    读整份原始文本的话，一句完全正当的解释性注释（本仓的 Dockerfile 注释很多）
    只要提到 `:latest` 或 `requirements.txt` 就会把闸门打红，而唯一的"修法"是
    **把注释删掉** —— 判据变成在惩罚写注释的人。
    """
    return [ln for ln in _lines() if ln.strip() and not ln.strip().startswith("#")]


def test_dockerfile_has_exactly_one_from():
    """防空转 + 防多阶段意外：本镜像是单阶段的。"""
    assert len(_from_lines()) == 1, f"期望恰好 1 条 FROM，实际 {len(_from_lines())} 条"


def test_base_image_is_exact_patch_tag_with_digest():
    """T5-1 / T6-5：精确 patch tag **且**带 digest。

    `python:3.11-slim`（浮动 minor）、`python:3.11.14-slim`（无 digest）、
    `python:latest` 三种写法都会在这里红。
    """
    line = _from_lines()[0].strip()
    assert _FROM_RE.match(line), (
        f"FROM 行不符合「python:<x.y.z>-slim@sha256:<64位>」形态: {line!r}"
    )


def test_no_latest_anywhere():
    """T6-4 的 Dockerfile 侧：**指令行**里不得出现 :latest（注释不算）。"""
    for line in _instruction_lines():
        assert ":latest" not in line, f"Dockerfile 指令行出现 :latest: {line!r}"


def test_installs_api_requirements_not_main_requirements():
    """T5-2：装的是裁剪后的清单，且判据锚在**指令行**上。

    要同时挡住两种形状：
      ① 装了 `requirements.txt`（那份含 pandas-ta 安装陷阱）；
      ② 根本不从清单装 —— `RUN pip install fastapi uvicorn asyncpg` 再配一句提到
         `requirements-api.txt` 的注释，能满足"整份文本里出现过这个词"式的判据，
         装进去的却是一组完全没有 pin 的版本。所以正向断言必须落在真正的
         COPY / RUN 指令上，而不是全文文本。

    注意 `requirements.txt` **不是** `requirements-api.txt` 的子串，
    所以下面那条否定断言不会误伤。
    """
    instructions = _instruction_lines()
    copy_lines = [ln for ln in instructions if ln.strip().startswith("COPY ")]
    run_lines = [ln for ln in instructions if ln.strip().startswith("RUN ")]

    assert any("requirements-api.txt" in ln for ln in copy_lines), (
        f"没有一条 COPY 指令把 requirements-api.txt 拷进镜像: {copy_lines!r}"
    )
    assert any(
        "pip install" in ln and "-r requirements-api.txt" in ln for ln in run_lines
    ), f"没有一条 RUN 指令用 `-r requirements-api.txt` 安装依赖: {run_lines!r}"

    for line in instructions:
        assert "requirements.txt" not in line, (
            f"Dockerfile 指令行引用了 requirements.txt —— 那份含 pandas-ta 安装陷阱: {line!r}"
        )
