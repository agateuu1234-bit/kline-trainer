# QMT 4b 切片 **S2a**：manifest 结构 + 读侧闭合校验（纯函数） —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立 `fetch_manifest.json` 这份 pilot 唯一真相源的**结构定义**、fail-closed **读侧闭合校验**、`manifest_version` **三档出路**与**聚合指纹算法**——**纯函数层：不碰磁盘、不碰网络、不碰拷贝、不碰数据库**。

**⚠️ 本片是 S2 的前一半（任务 1–14）。**后一半（读回、两个提交入口、生命周期决策表）在 **S2b**，见 `2026-08-25-qmt-4b-s2b-commit.md`——user 2026-08-25 拍板 **S2a 先合进 main 再切 S2b，不叠 PR**（避开「改 base 静默丢门」与「前片 squash 后必然冲突」两个已踩过的坑）。

**Architecture:** 新增 `backend/qmt_manifest.py` 一个模块。读侧校验是**纯函数**（零文件系统、零 IO），落盘复用 S1 `qmt_fsroot` 的逐段无跟随 + 原子写 + 耐久提交。生命周期规则做成**纯函数决策表**，两个提交入口（per-stock / 收尾）对它的权限**结构上不等价**：per-stock 提交在写入路径上根本够不到那三个字段。

**Tech Stack:** Python 3.11+、标准库（`json` / `hashlib` / `re` / `os`）、pytest。**零新依赖**。

**Spec:** `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.4 + §4.5（§4 是唯一权威）；切片边界见 `docs/superpowers/specs/2026-08-21-qmt-plan4b-slice-map.md`。本片实施前对 spec 做了 4 条更正，登记在 spec 文末「S2 实施轮」（S2-F1~F4），本 plan 一律按**更正后**的 spec 实施。

---

## Global Constraints

- **CI 是 `ubuntu-latest`，且任何 skip 都算失败**。禁止 `@pytest.mark.skip` / `skipif` / `importorskip`。平台专属常量一律 `getattr(mod, "NAME", None)` 取，走「该平台最强的那个原语」。
- **测试的 import 不得依赖 CI 没装的包**。`requirements-test.txt` 不装 `asyncpg`；本模块**零外部依赖**，测试只 import 标准库 + `qmt_manifest` + `qmt_fsroot` + `qmt_normalize`。
- **全部测试跑在 `tmp_path`**，不连数据库、不连网络、不读真实挂载点。
- **中文错误信息**面向非程序员操作者：每条拒绝都要说清「哪里不对」**与**「该怎么办」。
  ⚠️ **落地方式（2026-08-25 裁决，勿逐点重复）**：「该怎么办」由 `ManifestInvalidError`
  **在类里统一追加**（`GUIDANCE` 常量），**调用点只写「哪里不对」**。本模块有约 90 个拒绝点，
  其中绝大多数的「该怎么办」是同一个答案；逐点重复既冗余、又必然漏——本片已因此被评审提了三次。
  提到类里之后，这条约束由 `test_every_invalid_error_carries_actionable_guidance` 钉死，
  **结构上不可违反**。
- **变异验证必须禁字节码缓存**：`PYTHONDONTWRITEBYTECODE=1` 且每次清 `__pycache__`。等长改动 + 同秒还原会让旧 `.pyc` 继续生效，**结论两个方向都可能是假的**。
- **变异由控制者亲跑**，不接受实施者自报「验过了」。
- `manifest_version` 本片定为 **1**。**新增任何必需字段必须 bump 版本**（spec O2-F8）。
- **每新增一个持久化字段，必须同时在写侧枚举与读侧枚举各出现一次，且层级逐字相同**（spec S2-F3 立的纪律；该家族已复发四次：R94-F2 / O4-F13 / S2-F3 / S2-F4）。

### ⚠️ 关于各步 `Expected: NNN passed` 里的数字

那些**绝对条数是估算**（`parametrize` 的展开数可能与我数的有出入），
**不是判据**。判据只有三条：**没有 `failed`、没有 `error`、没有 `skipped`**，
且条数**只增不减**。
本仓栽过「计划内嵌的数字/行号/历史陈述不可靠」——嵌的**代码**经 dry-run 可靠，
嵌的**事实**必须逐条实测。本 plan 里嵌的代码已 dry-run 过（相对路径分量规则 7 个坏档、
文件名解析 3 档、聚合指纹算法与测试期望一致、`ensure_ascii`/`separators` 确实改变结果、
两条判据结构上重叠），**数字没有**。

### 本片明确不做（防止顺手做）

| 不做的 | 归属 |
|---|---|
| 三条预筛判据、分层 seeded shuffle、冻结宇宙的**计算** | S3 |
| 真的拷文件、`.part`、`.inflight.json` 崩溃恢复、`--max-bytes` 流式扣减 | S4 |
| 七条源边界闸、挂载表、立基准/比对双模式、`qmt_fetch` 命令行 | S5 |
| `qmt_pilot`、`import_qmt_stock`、`staging_dir_fd`、`--output` 一族 | 4c |
| **读回 manifest、两个提交入口、生命周期决策表** | **S2b**（本 plan 的后一半，已单独成文） |
| `failures` / `batches` / `inflight_rollbacks` / `quota` / 预筛统计 / 累计字节的**形状定义** | S3/S4——它们是**可选顶层键**，经「未知顶层键原样保留」通道流转，**不 bump 版本** |

---

## File Structure

| 文件 | 职责 |
|---|---|
| `backend/qmt_manifest.py`（新建） | manifest 的常量、异常族、版本三档、读侧闭合校验（纯函数）、聚合指纹算法、两个提交入口、生命周期决策表 |
| `backend/tests/test_qmt_manifest.py`（新建） | 上述全部行为的正反档 |
| `backend/qmt_fsroot.py`（修改） | 公开一个既有私有原语：`split_relative_components`（`atomic_write_json` 那一半归 S2b） |
| `backend/tests/test_qmt_fsroot.py`（修改） | 为新公开的原语补正反档 |

**拆片已执行**（user 2026-08-24 拍板「超了当场拆」，2026-08-25 执行）：估算 S2 约 157 条测试 > S1 的 94 条，故拆点定在 **Task 14 与 Task 15 之间**——
- **S2a（本文件）** = Task 1–14：纯函数校验，零文件系统（除 Task 1 那次 S1 小改）
- **S2b** = Task 15–18：碰磁盘（读回、两个提交入口、生命周期决策表）

---

## manifest v1 字段表（唯一权威视图）

### 必需顶层键（10 个，外延写死；缺一即 `FAIL_MANIFEST_INVALID`）

| 键 | 类型 | 约束 |
|---|---|---|
| `manifest_version` | int | 必须 == `MANIFEST_VERSION`（1）；缺失视为 0 |
| `seed` | str | 非空 |
| `source_snapshot` | dict | `{export_log_sha256: sha256, universe: {SH,SZ,BJ: list[str]}, gmt_token?: str}` |
| `source_mount` | dict | `{fstype: 非空 str, device: 非空 str, source_root_relative: str（**可空串**）, mountpoint?, source_root?, gmt_token?}` |
| `pool_order` | dict | `{SH,SZ,BJ: list[{code: str, universe_idx: int}]}` |
| `cursor` | dict | `{SH,SZ,BJ: int}` |
| `files` | list | `[{stock_code, period, relative_path, bytes, sha256}]` |
| `staged_export_log` | dict | `{relative_path, bytes, sha256}` |
| `source_verification` | str | `snapshot` / `full` / `partial` |
| `source_verification_evidence` | dict | `{level, mount_check?, passes: list, passes_agree?}` |

> **⚠️ 顶层没有 `universe`**（spec S2-F3）。名单的唯一位置是 `source_snapshot.universe`。

### 可选顶层键（本片定义形状；若存在则校验）

| 键 | 约束 |
|---|---|
| `stopped_reason` | 闭合枚举 `{max_bytes, source_path_escape, staging_path_escape, staging_recheck_failed}` |
| `fetch_fatal_error` | `{kind, relative_path, component, errno}` **四字段**；`kind ∈ {source_path_escape, staging_path_escape}`；`errno ∈ {ELOOP, ENOTDIR}` |
| `stopped_reason_secondary` | 只允许 `max_bytes`（纯人读附注） |
| `operator_attestation` | `{no_export_window: bool, recorded_at: 非空 str}` |

**配对规则**：`stopped_reason ∈ {source_path_escape, staging_path_escape, staging_recheck_failed}` **必须**同时带形状合规的 `fetch_fatal_error`；`kind` 与 `stopped_reason` **解耦**（复校失败那一档正是「保留 fatal + 换 `stopped_reason`」，写成「`kind` 恒等于 `stopped_reason`」会让它结构上不可表达）。

### 未在本片定义的可选顶层键

`failures` / `batches` / `inflight_rollbacks` / `quota` / `prefilter_stats` / `committed_bytes` —— 由 S3/S4 定义。本片的校验**不认识它们，但必须原样保留回写**（spec O4-F10）。

---

## Task 1: S1 小改 —— 公开相对路径分量规则

**Files:**
- Modify: `backend/qmt_fsroot.py`（`__all__` 第 22-41 行；`_split_rel` 第 122 行之后）
- Test: `backend/tests/test_qmt_fsroot.py`

**Interfaces:**
- Consumes: 无（本任务只动 S1 自己）
- Produces: `split_relative_components(relpath: str) -> list[str]`（不合规时抛 `PathDisciplineError`）

**为什么必须动 S1**：读侧校验要判「manifest 里每条 `relative_path` 留在 staging 之内」，需要的正是 S1 `_split_rel` 那套分量规则——而它是**私有的**。本任务只是**公开它**，一行实现逻辑都不改。

> ⚠️ **S1 的另一处小改（公开 `atomic_write_json` 并加 `full_sync` 开关）不在本片**（2026-08-25 pre-flight 裁决）：它的唯一使用者是 manifest 落盘，而落盘在 **S2b**。**本片不引入零使用者的改动**——那是评审必提的 YAGNI 违规，而本仓的教训是评审不收敛的代价很大。S2b 的 Task 15 负责那一半。

- [ ] **Step 1: 写失败的测试**

```python
# backend/tests/test_qmt_fsroot.py 末尾追加

# ─────────────────────────────────────────────────────────────
# S2a Task 1：公开相对路径分量规则（读侧校验要用它判「留在 staging 之内」）
# ─────────────────────────────────────────────────────────────
from qmt_fsroot import split_relative_components


def test_split_relative_components_accepts_normal_relative_path():
    """正向放行档。"""
    assert split_relative_components("1分钟K线_前复权/000001.SZ_平安银行_1分钟K线_前复权.csv") == [
        "1分钟K线_前复权", "000001.SZ_平安银行_1分钟K线_前复权.csv",
    ]
    assert split_relative_components("export_log.csv") == ["export_log.csv"]


@pytest.mark.parametrize("bad", [
    "/abs/path.csv",        # 绝对路径
    "../escape.csv",        # 上跳
    "a/../b.csv",           # 中段上跳
    "./a.csv",              # 当前目录
    "a//b.csv",             # 空分量
    "a/",                   # 尾斜杠产生空分量（相对路径不做尾斜杠宽容）
    "",                     # 空串
])
def test_split_relative_components_rejects_escapes(bad):
    """七个坏档**已实测**（2026-08-24 在 `_split_rel` 上真跑过）全部被拒。"""
    with pytest.raises(PathDisciplineError):
        split_relative_components(bad)
```

> ⚠️ `PathDisciplineError` 与 `pytest` 在本文件顶部已 import；若测试文件里没有，
> 补 `from qmt_fsroot import PathDisciplineError`。

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_fsroot.py -q -k split_relative_components 2>&1 | tail -20
```

Expected: FAIL —— `ImportError: cannot import name 'split_relative_components' from 'qmt_fsroot'`

- [ ] **Step 3: 最小实现**

`backend/qmt_fsroot.py` 两处改动：

```python
# ① __all__ 里，"路径规则" 那一组改为：
    # 路径规则
    "normalize_abs_path", "split_components", "split_relative_components",
```

```python
# ② _split_rel 保持不动，紧跟其后新增一个公开别名：

def split_relative_components(relpath: str) -> list[str]:
    """相对路径 → 分量列表，与 `open_root` **同一套分量规则**：拒绝绝对路径 /
    空分量 / `.` / `..`。不合规时抛 `PathDisciplineError`。

    **公开出来是给 manifest 读侧校验用的**（S2）：manifest 里每条
    `relative_path` 都要判「留在 staging 之内」。spec 原文写的是「经 `resolve()`
    后落在 staging 之内」，但 `resolve()` **会跟随符号链接**（那正是 O2-F4 造
    `parent_fd_under` 的全部理由），拿它当边界判据等于把判据建在会被绕过的调用上。
    分量规则更强，且**不碰文件系统**——读侧校验因此得以是纯函数。
    真正的符号链接防线在打开那一刻由 `open_under` 逐段 `O_NOFOLLOW` 承担。
    """
    return _split_rel(relpath)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_fsroot.py -q 2>&1 | tail -5
```

Expected: 约 102 passed（数字是估算，**判据是没有 failed / error / skipped**，且比基线 94 条只增不减）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M1 | `split_relative_components` 内改为 `return relpath.split("/")`（绕过规则） | 7 条 `..._rejects_escapes` 参数档全红 |
| M2 | `split_relative_components` 内改为 `return _split_rel(relpath.lstrip("./"))` | `..._rejects_escapes[./a.csv]` 变绿 → **本条不红即说明规则被绕过** |

```bash
# 每次变异前后都要清字节码缓存
cd backend && find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cp qmt_fsroot.py /tmp/qmt_fsroot.bak     # 复原用 cp，绝不用 git checkout
```

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_fsroot.py backend/tests/test_qmt_fsroot.py
git commit -m "feat(4b-S2a): 公开 S1 的相对路径分量规则

读侧校验要判「manifest 里每条 relative_path 留在 staging 之内」，需要的正是
S1 _split_rel 那套分量规则——而它是私有的。本任务只公开它，一行实现逻辑未改。

分量规则替代 spec 原文的 resolve()：resolve() 会跟随符号链接（那正是 O2-F4
造 parent_fd_under 的理由），拿它当边界判据是把判据建在会被绕过的调用上。
分量规则更强，且让读侧校验保持纯函数（不碰文件系统）。

S1 的另一半小改（公开 atomic_write_json + full_sync 开关）留给 S2b——
它在本片零使用者，本片不引入用不到的改动。"
```

---

## Task 2: 常量与异常族

**Files:**
- Create: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: 无
- Produces: `MANIFEST_VERSION`、`MANIFEST_NAME`、`MARKETS`、`PERIODS`、`REQUIRED_KEYS`、`STOPPED_REASONS`、`FATAL_KINDS`、`REASONS_REQUIRING_FATAL`、`VERIFICATION_LEVELS`、`LIFECYCLE_KEYS`、`ManifestInvalidError`、`ManifestVersionError`

**为什么异常必须分两族**：spec O2-F8 明写——一棵已拉 400 只股（约 2 GiB）的旧 staging，如果「版本不对」与「形状非法」报同一句话，操作者根本不知道该重拉还是该换工具版本，而工具自己解不开这个状态。

- [ ] **Step 1: 写失败的测试**

```python
# backend/tests/test_qmt_manifest.py（新建）
"""QMT 4b S2：fetch_manifest.json 的结构、读侧闭合校验与生命周期。

Spec: docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md §4.4 + §4.5
（含文末「S2 实施轮」的四条更正 S2-F1~F4）。

⚠️ 本文件全部测试跑在 tmp_path 或纯内存，零 DB、零网络、零真实挂载点。
"""
from __future__ import annotations

import pytest

from qmt_manifest import (
    MANIFEST_VERSION,
    MANIFEST_NAME,
    MARKETS,
    PERIODS,
    REQUIRED_KEYS,
    STOPPED_REASONS,
    FATAL_KINDS,
    REASONS_REQUIRING_FATAL,
    VERIFICATION_LEVELS,
    LIFECYCLE_KEYS,
    ManifestInvalidError,
    ManifestVersionError,
)


def test_constants_have_the_exact_spec_values():
    """外延写死的枚举必须逐字等于 spec，不多不少。

    判别力：任一枚举漏一个值或多一个值，本条必红。spec 反复栽在
    「新错误码没进任何枚举」（R89 自查补抓到 staging_path_escape 出现 4 次
    却不属于任何枚举）。
    """
    assert MANIFEST_VERSION == 1
    assert MANIFEST_NAME == "fetch_manifest.json"
    assert MARKETS == ("SH", "SZ", "BJ")
    assert PERIODS == ("1m", "daily")
    assert set(STOPPED_REASONS) == {
        "max_bytes", "source_path_escape",
        "staging_path_escape", "staging_recheck_failed",
    }
    assert set(FATAL_KINDS) == {"source_path_escape", "staging_path_escape"}
    assert set(REASONS_REQUIRING_FATAL) == {
        "source_path_escape", "staging_path_escape", "staging_recheck_failed",
    }
    assert set(VERIFICATION_LEVELS) == {"snapshot", "full", "partial"}
    assert set(LIFECYCLE_KEYS) == {
        "stopped_reason", "stopped_reason_secondary", "fetch_fatal_error",
    }


def test_required_keys_is_the_exact_ten_and_excludes_top_level_universe():
    """必需键外延写死，且**顶层没有 universe**（spec S2-F3）。

    判别力：把 "universe" 加回去，本条必红——而照原 spec 实现正是加了它，
    后果是本工具诚实产出的每一份 manifest 都被自己的读侧判非法。
    """
    assert set(REQUIRED_KEYS) == {
        "manifest_version", "seed", "source_snapshot", "source_mount",
        "pool_order", "cursor", "files", "staged_export_log",
        "source_verification", "source_verification_evidence",
    }
    assert "universe" not in REQUIRED_KEYS


def test_version_error_is_not_an_invalid_error():
    """两族异常必须可区分（spec O2-F8）：一个是「换 staging」，
    一个是「换工具版本」，混成一句话会让操作者无路可走。

    判别力：把 ManifestVersionError 写成 ManifestInvalidError 的子类，本条必红。
    """
    assert not issubclass(ManifestVersionError, ManifestInvalidError)
    assert not issubclass(ManifestInvalidError, ManifestVersionError)


def test_version_error_carries_kind_and_actionable_guidance():
    older = ManifestVersionError(kind="older", found=0, expected=1)
    newer = ManifestVersionError(kind="newer", found=99, expected=1)
    assert older.kind == "older" and older.found == 0 and older.expected == 1
    assert newer.kind == "newer"
    # 指引必须不同，且都是操作者能照做的动作
    assert older.guidance != newer.guidance
    assert "换新 staging" in older.guidance
    assert "更新版本" in newer.guidance


def test_invalid_error_carries_a_detail_string():
    e = ManifestInvalidError("缺少必需字段 seed")
    assert "seed" in str(e)
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -10
```

Expected: FAIL —— `ModuleNotFoundError: No module named 'qmt_manifest'`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py（新建）
"""`fetch_manifest.json` —— `qmt_fetch` 写、`qmt_pilot` 读的唯一真相源。

Spec: `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.4 + §4.5
（含文末「S2 实施轮」四条更正）。

本模块只做三件事，**不碰网络、不碰拷贝、不碰数据库**：
1. 定义 manifest 的结构与版本；
2. 读侧**闭合**校验（fail-closed，绝不「尽力而为地解析」）——纯函数，零文件系统；
3. 两个提交入口 + `stopped_reason` / `fetch_fatal_error` 的生命周期决策表。

⚠️ **为什么读侧校验必须闭合**：一个被截断的 manifest 解析出来往往仍是合法 JSON
的**前缀片段**，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」，最终产出一份
**会撒谎的 pilot 报告**（R1-F4）。
"""
from __future__ import annotations

# ── 版本 ─────────────────────────────────────────────────────
# 新增任何**必需**字段都必须 bump 本值（spec O2-F8）。可选字段经
# 「未知顶层键原样保留」通道流转，不需要 bump。
MANIFEST_VERSION = 1

MANIFEST_NAME = "fetch_manifest.json"

MARKETS = ("SH", "SZ", "BJ")
PERIODS = ("1m", "daily")

# 必需顶层键的**外延**（写死，不做「凡是我认识的都必需」这种开放定义）。
# ⚠️ 顶层**没有** `universe`（S2-F3）：名单的唯一位置是 `source_snapshot.universe`。
# 原 spec 把它列成顶层必需键，而写侧从不产出它 → 本工具诚实产出的每一份 manifest
# 都会被本工具自己的读侧判 FAIL_MANIFEST_INVALID，一次都跑不通。
REQUIRED_KEYS = (
    "manifest_version", "seed", "source_snapshot", "source_mount",
    "pool_order", "cursor", "files", "staged_export_log",
    "source_verification", "source_verification_evidence",
)

# `stopped_reason` 的闭合枚举（R87-F1 + R89 自查补 + O4-F3 补第四值）。
STOPPED_REASONS = frozenset({
    "max_bytes",
    "source_path_escape",
    "staging_path_escape",
    "staging_recheck_failed",
})

# `fetch_fatal_error.kind` 记录的是**首次逃逸的类型**，与 `stopped_reason` **解耦**
# （O4-F3）：复校失败那一档正是「保留 fatal + 换 stopped_reason」，
# 写成「kind 恒等于 stopped_reason」会让它**结构上不可表达**。
FATAL_KINDS = frozenset({"source_path_escape", "staging_path_escape"})

# 这三个 `stopped_reason` 必须同时带形状合规的顶层 `fetch_fatal_error`。
REASONS_REQUIRING_FATAL = frozenset({
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
})

VERIFICATION_LEVELS = ("snapshot", "full", "partial")

# 生命周期三字段：**只有收尾提交能动它们**，per-stock 提交在写入路径上够不到
# （R95-F2 + spec §9-3s「使规则可机械检验」）。
LIFECYCLE_KEYS = frozenset({
    "stopped_reason", "stopped_reason_secondary", "fetch_fatal_error",
})


class ManifestInvalidError(Exception):
    """manifest 形状/自洽性不过 → `FAIL_MANIFEST_INVALID`。

    **与 `ManifestVersionError` 是两族**：本族说「这份账本坏了」，那族说
    「这份账本是别的版本写的」。混成一句话会让操作者面对一棵已拉几百只股的
    staging 无路可走（O2-F8）。

    ⚠️ **动作指引由本类统一追加，调用点只说「哪里不对」**（2026-08-25 裁决）：
    全局约束要求每条拒绝都说清「哪里不对」**与**「该怎么办」，而本模块有约 90 个
    拒绝点、其中绝大多数的「该怎么办」是**同一个答案**。逐点重复同一句话既冗余、
    又必然漏（本片因此被评审提了三次）。把它提到类里，约束就从散文变成
    **结构上不可违反**的东西，并由 `test_every_invalid_error_carries_actionable_guidance`
    钉死。
    """

    #: 所有「账本坏了」类拒绝共用的动作指引。
    GUIDANCE = (
        "该怎么办：这份账本（fetch_manifest.json）已不可信，本工具不会尝试修复它"
        "——半份账本比没有账本更危险。请换一个新的 staging 目录 + 新 seed 重新拉取。"
    )

    def __init__(self, detail: str):
        self.detail = detail
        super().__init__(f"{detail}\n{self.GUIDANCE}")


class ManifestVersionError(Exception):
    """manifest 版本与本工具不等——**不是**形状非法。

    三档（O2-F8 + O4-F10）：低于 / 高于 / 缺失（视为 0，走「低于」）。
    每档给出**不同的、操作者照做得了的**指引。
    """

    def __init__(self, *, kind: str, found: int, expected: int):
        if kind not in ("older", "newer"):
            raise ValueError(f"kind 只能是 older/newer，收到 {kind!r}")
        self.kind = kind
        self.found = found
        self.expected = expected
        self.guidance = (
            f"该 staging 由旧版本（manifest_version={found}）产出，"
            f"本工具是 {expected} 版。请换新 staging + 新 seed 重拉。"
            if kind == "older" else
            f"该 staging 由更新版本（manifest_version={found}）产出，"
            f"本工具只到 {expected} 版。请用对应版本的工具，或换新 staging。"
        )
        super().__init__(self.guidance)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 5 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): manifest 的常量与两族异常

必需键外延写死为 10 个，**顶层不含 universe**（S2-F3：原 spec 把它列成顶层
必需键，而写侧只产出 source_snapshot.universe → 照原文实现，本工具诚实产出的
每一份 manifest 都被自己的读侧判非法）。

ManifestVersionError 与 ManifestInvalidError 刻意不互为子类：一个是「换
staging」，一个是「换工具版本」，混成一句话会让操作者面对一棵已拉几百只股的
staging 无路可走（O2-F8）。"
```

---

## Task 3: 版本三档 + 判定次序（先版本、后形状）

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: Task 2 的常量与异常
- Produces: `check_version(payload: object) -> int`

**为什么次序是判据的一部分**：一份版本更高的 manifest，其形状按**本版**要求去量必然缺东西。若先跑形状校验，操作者拿到的是「账本畸形」——而真相是「你用的工具太旧」。**指引整个走错**，且这正是 O4-F10 已经栽过的那档。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import check_version


def test_check_version_accepts_current():
    """正向放行档。"""
    assert check_version({"manifest_version": 1}) == 1


def test_check_version_missing_is_treated_as_zero_and_reported_as_older():
    """缺失视为 0，走「低于」档（O4-F10：原文只写了「低于」一档，
    「大于」与「缺失」只在 §5 出现过）。"""
    with pytest.raises(ManifestVersionError) as ei:
        check_version({})
    assert ei.value.kind == "older"
    assert ei.value.found == 0


def test_check_version_older_and_newer_are_distinct_kinds():
    with pytest.raises(ManifestVersionError) as older:
        check_version({"manifest_version": 0})
    assert older.value.kind == "older"

    with pytest.raises(ManifestVersionError) as newer:
        check_version({"manifest_version": 2})
    assert newer.value.kind == "newer"


def test_check_version_rejects_non_dict_as_invalid_not_version():
    """根本不是对象 → 形状非法，**不是**版本问题。"""
    for bad in ([], "x", 3, None):
        with pytest.raises(ManifestInvalidError):
            check_version(bad)


def test_check_version_rejects_non_int_version_as_invalid():
    """版本号存在但不是整数 → 形状非法。

    ⚠️ bool 是 int 的子类：True 必须被拒，否则 {"manifest_version": True}
    会被当成版本 1 放行。
    """
    for bad in ("1", 1.0, True, None, [1]):
        with pytest.raises(ManifestInvalidError):
            check_version({"manifest_version": bad})


def test_check_version_ignores_everything_but_the_version():
    """一份**只有版本号、别的全没有**的输入，`check_version` 也必须只看版本
    ——它不该顺手去查形状（那是 `validate_manifest` 的活）。

    ⚠️ **本条测不到「先版本后形状」的次序**（2026-08-25 控制者归因自查）：
    次序是 `validate_manifest` 内部两步的先后，而它到 Task 5 才存在。
    真正的次序钉是 Task 5 的 `test_validate_manifest_reports_version_before_shape`。
    判别力：`raw > MANIFEST_VERSION` 那一支短路掉，本条必红（已变异证实）。
    """
    with pytest.raises(ManifestVersionError) as ei:
        check_version({"manifest_version": 99})       # 只有版本号，别的全没有
    assert ei.value.kind == "newer"
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k check_version 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'check_version'`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py

def check_version(payload: object) -> int:
    """**读侧的第一道**：先定版本，再谈形状。

    返回本工具认可的版本号；不认可即抛 `ManifestVersionError`（三档）。
    根本不是对象、或版本号不是整数 → `ManifestInvalidError`。

    ⚠️ **次序是判据的一部分**：一份版本更高的 manifest，其形状按**本版**要求
    去量必然缺东西。先跑形状校验的实现会把「你的工具太旧」报成「账本畸形」，
    **指引整个走错**（O4-F10 栽过的那档）。

    ⚠️ `bool` 是 `int` 的子类：不排除它，`{"manifest_version": True}` 会被
    当成版本 1 放行。
    """
    if not isinstance(payload, dict):
        raise ManifestInvalidError(
            f"manifest 必须是一个 JSON 对象，实际读到 {type(payload).__name__}。"
            "这通常意味着文件被截断或根本不是 manifest。"
        )
    if "manifest_version" not in payload:
        # 缺失视为 0（O4-F10），走「低于」档的指引。
        raise ManifestVersionError(kind="older", found=0, expected=MANIFEST_VERSION)
    raw = payload["manifest_version"]
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise ManifestInvalidError(
            f"manifest_version 必须是整数，读到 {raw!r}（{type(raw).__name__}）"
        )
    if raw < MANIFEST_VERSION:
        raise ManifestVersionError(kind="older", found=raw, expected=MANIFEST_VERSION)
    if raw > MANIFEST_VERSION:
        raise ManifestVersionError(kind="newer", found=raw, expected=MANIFEST_VERSION)
    return raw
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 11 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M4 | 删掉 `isinstance(raw, bool)` 那半个条件 | `..._rejects_non_int_version_as_invalid`（`True` 那一档） |
| M5 | `raw < MANIFEST_VERSION` → `raw <= MANIFEST_VERSION` | `test_check_version_accepts_current` |
| M6 | 缺失时返回 `MANIFEST_VERSION` 而不是抛 | `..._missing_is_treated_as_zero...` |
| M7 | `raw > MANIFEST_VERSION` 那一支短路掉 | `..._older_and_newer_are_distinct_kinds` + `..._ignores_everything_but_the_version` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): manifest_version 三档 + 先版本后形状的次序钉

低于/高于/缺失（视为 0）三档各有不同且操作者照做得了的指引（O2-F8 + O4-F10）。
次序钉：版本更高的 manifest 形状按本版量必然缺东西，先跑形状校验会把
「你的工具太旧」报成「账本畸形」——指引整个走错。

bool 是 int 的子类，不排除它 {\"manifest_version\": True} 会被当成版本 1 放行。"
```

---

## Task 4: 聚合指纹算法（`aggregate_sha256` + `manifest_members`）

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: Task 2 的常量
- Produces:
  - `manifest_members(manifest: dict) -> list[tuple[str, str]]`
  - `aggregate_sha256(members: Iterable[tuple[str, str]]) -> str`

**为什么这条排在校验之前**：读侧校验要拿它重算聚合去比对，测试基座造一份合法 manifest 也要拿它算。而它本身是 spec 从未定义、由 S2-F4 补上的——**写它的是 4b、读它比对的是 4c**，拼法差一个空格或一个 `\uXXXX` 转义，每一份诚实产出的 manifest 都会被判非法。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

import hashlib
import json as _json

from qmt_manifest import aggregate_sha256, manifest_members


def test_aggregate_sha256_is_the_exact_frozen_serialization():
    """算法逐字写死（S2-F4）：按相对路径升序 → JSON（中文不转义、分隔符无空格）
    → UTF-8 → sha256。

    判别力：ensure_ascii、separators、排序、UTF-8 任一改动，本条必红。
    这四个都是**判据的一部分**——周期目录名是中文，ensure_ascii 的两个取值
    会产出完全不同的字节。
    """
    members = [
        ("日K线_前复权/000001.SZ_平安银行_日K线_前复权.csv", "b" * 64),
        ("1分钟K线_前复权/000001.SZ_平安银行_1分钟K线_前复权.csv", "a" * 64),
    ]
    expect_blob = _json.dumps(
        [["1分钟K线_前复权/000001.SZ_平安银行_1分钟K线_前复权.csv", "a" * 64],
         ["日K线_前复权/000001.SZ_平安银行_日K线_前复权.csv", "b" * 64]],
        ensure_ascii=False, separators=(",", ":"),
    ).encode("utf-8")
    assert aggregate_sha256(members) == hashlib.sha256(expect_blob).hexdigest()


def test_aggregate_sha256_is_order_independent_of_input():
    """输入次序不影响结果（内部排序），否则「先拷谁」会改变聚合值。"""
    a = [("x/1.csv", "a" * 64), ("x/2.csv", "b" * 64)]
    assert aggregate_sha256(a) == aggregate_sha256(list(reversed(a)))


def test_aggregate_sha256_differs_when_ensure_ascii_would_differ():
    """钉住 ensure_ascii=False 这一半：若实现漏写它（默认 True），
    中文路径会被转成 \\uXXXX，聚合值不同。

    判别力：把 ensure_ascii=False 删掉，本条必红。
    """
    members = [("1分钟K线_前复权/a.csv", "a" * 64)]
    ascii_blob = _json.dumps([["1分钟K线_前复权/a.csv", "a" * 64]],
                             ensure_ascii=True, separators=(",", ":")).encode("utf-8")
    assert aggregate_sha256(members) != hashlib.sha256(ascii_blob).hexdigest()


def test_aggregate_sha256_differs_when_separators_would_differ():
    """钉住 separators 这一半：默认分隔符带空格，聚合值不同。

    判别力：把 separators=(",", ":") 删掉，本条必红。
    """
    members = [("a.csv", "a" * 64)]
    spaced = _json.dumps([["a.csv", "a" * 64]], ensure_ascii=False).encode("utf-8")
    assert aggregate_sha256(members) != hashlib.sha256(spaced).hexdigest()


def test_manifest_members_is_files_plus_staged_export_log():
    """成员集合写死（O2-F12）：files 每条 + staged_export_log 一条。
    故 files_verified 恒为奇数 2N+1（O4-F13 定的就是这个数）。

    判别力：漏掉 staged_export_log 那一条，本条必红——而 spec 原文正是
    「写侧含 export_log、读侧要求由 files 逐条重算而 files 里没有它」，
    差这一项就让每份诚实产出的 manifest 都被判非法。
    """
    m = {
        "files": [
            {"relative_path": "1分钟K线_前复权/a.csv", "sha256": "a" * 64},
            {"relative_path": "日K线_前复权/a.csv", "sha256": "b" * 64},
        ],
        "staged_export_log": {"relative_path": "export_log.csv", "sha256": "c" * 64},
    }
    members = manifest_members(m)
    assert len(members) == 3                      # 2N+1，N=1
    assert ("export_log.csv", "c" * 64) in members
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "aggregate or members" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'aggregate_sha256'`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部补 import
import hashlib
import json
import re
from typing import Iterable


# 追加到 backend/qmt_manifest.py

def manifest_members(manifest: dict) -> list[tuple[str, str]]:
    """聚合指纹的**成员集合**（O2-F12 写死）：`files` 的每一条 + `staged_export_log`
    一条，各取 `(relative_path, sha256)`。

    ⚠️ **`staged_export_log` 那一条不能漏**：它是所有股共用的元数据基准
    （`build_stock_import` 门 2 拿它的 rows 与首尾时间戳卡每只股）。spec 原文
    「写侧含 export_log、读侧要求由 `files` 逐条重算」而 `files` 里没有它——
    **差这一项就让每一份诚实产出的 manifest 都被判 `FAIL_MANIFEST_INVALID`**
    （O4-F13 与 R94-F2 同类）。成员数因此恒为奇数 `2N+1`。
    """
    members = [(f["relative_path"], f["sha256"]) for f in manifest["files"]]
    sel = manifest["staged_export_log"]
    members.append((sel["relative_path"], sel["sha256"]))
    return members


def aggregate_sha256(members: Iterable[tuple[str, str]]) -> str:
    """对「全部已校验文件的 `(相对路径, 文件 sha256)` 排序列表」取 sha256。

    **序列化方式逐字写死（S2-F4）——两个工具必须算出同一个数，故拼法不许各写各的**：
    按相对路径升序 → `json.dumps(..., ensure_ascii=False, separators=(",", ":"))`
    → UTF-8 → sha256。

    ⚠️ `ensure_ascii=False` 与 `separators` **都是判据的一部分**：周期目录名是
    中文，两个取值会产出完全不同的字节。spec 原文只说「排序列表取 sha256」，
    **没定义这个列表怎么拼成字节**——而写这个数的是 `qmt_fetch`（4b）、拿它比对的
    是 `qmt_pilot`（4c），两个切片、两份 plan、不同时间实施。

    **本函数是唯一实现，4c 直接调用，不得各自重写。**
    """
    pairs = sorted(members)
    blob = json.dumps([[r, s] for r, s in pairs],
                      ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 16 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M7 | 删 `ensure_ascii=False` | `..._is_the_exact_frozen_serialization` + `..._differs_when_ensure_ascii...` |
| M8 | 删 `separators=(",", ":")` | `..._is_the_exact_frozen_serialization` + `..._differs_when_separators...` |
| M9 | 删 `sorted(...)` | `..._is_order_independent_of_input` |
| M10 | `manifest_members` 不追加 `staged_export_log` | `..._is_files_plus_staged_export_log` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): 聚合指纹算法逐字写死（S2-F4）+ 成员集合含 staged_export_log

spec 只说「排序列表取 sha256」，没定义列表怎么拼成字节。写它的是 4b、读它
比对的是 4c——两个切片两份 plan 不同时间实施，拼法差一个空格或一个 \\uXXXX
转义，每份诚实产出的 manifest 都会被判非法。

ensure_ascii=False 与 separators 都是判据的一部分（周期目录名是中文），
各配了一条只有它够得到的档。

成员集合 = files 每条 + staged_export_log 一条（O2-F12），故恒为奇数 2N+1。
漏掉那一条正是 O4-F13 与 R94-F2 同类的「写侧读侧不配对」。"
```

---

## Task 5: `validate_manifest` 骨架 + 顶层必需键 + 测试基座

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: Task 2/3/4
- Produces: `validate_manifest(payload: object) -> dict`（原样返回通过校验的 manifest）

**⚠️ 本任务引入的测试基座 `_valid_manifest()` 是后续所有否定档的唯一来源**：每个否定档从它派生、**只改一处**，断言恰好因为那一条被拒。基座本身就是那条「健康输入必须被放行」的正向档——没有它，一个**恒抛**的实现会让整套否定档全绿（本仓真栽过：闸 2 的 SQL 恒抛、五组判据一次都没执行过，429 测试 + codex 14 轮全漏）。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import validate_manifest


def _sha(tag: str) -> str:
    """造一个形状合法、可区分的假 sha256（只用于测试，不代表真实哈希）。"""
    return hashlib.sha256(tag.encode("utf-8")).hexdigest()


def _file_rec(code: str, name: str, period: str) -> dict:
    """按**真实 QMT 导出格式**造一条文件记录。

    ⚠️ 目录名与文件名里的 label 必须同源：目录 = f"{label}_前复权"，
    文件名 = f"{code}_{name}_{label}_前复权.csv"。照想象造样本让两个缺陷
    藏了三年且测试全绿（见 qmt_ingest 的 1d/status 两个生产缺陷）。
    """
    label = "1分钟K线" if period == "1m" else "日K线"
    rel = f"{label}_前复权/{code}_{name}_{label}_前复权.csv"
    return {"stock_code": code, "period": period, "relative_path": rel,
            "bytes": 1234567, "sha256": _sha(rel)}


_STOCKS = (("600000.SH", "浦发银行"), ("000001.SZ", "平安银行"))


def _valid_manifest(**overrides) -> dict:
    """一份**必须能通过全部校验**的最小合法 manifest。

    所有否定档从它派生、只改一处。`source_verification_evidence` 在 overrides
    **之后**按最终的 files/staged_export_log 重算，这样改 files 的档不会因为
    聚合值对不上而被**另一条**判据拒掉——**两条判据互相掩盖时，单独变异
    都不会红**（本仓栽过的假阴性形态之一）。
    """
    universe = {
        "SH": ["600000.SH", "600004.SH", "600006.SH"],
        "SZ": ["000001.SZ", "000002.SZ"],
        "BJ": ["430047.BJ"],
    }
    elog_sha = _sha("export_log.csv@2026-08-24")
    m: dict = {
        "manifest_version": 1,
        "seed": "s-2026-08-24",
        "source_snapshot": {"export_log_sha256": elog_sha, "universe": universe},
        "source_mount": {
            "fstype": "smbfs",
            "device": "//agate@192.168.5.151/QMT_Export",
            "source_root_relative": "front_ratio_cn_stocks_ab_bj",
        },
        "pool_order": {
            "SH": [{"code": "600000.SH", "universe_idx": 0}],
            "SZ": [{"code": "000001.SZ", "universe_idx": 0}],
            "BJ": [],
        },
        "cursor": {"SH": 1, "SZ": 1, "BJ": 0},
        "files": [r for code, nm in _STOCKS for r in
                  (_file_rec(code, nm, "1m"), _file_rec(code, nm, "daily"))],
        "staged_export_log": {"relative_path": "export_log.csv",
                              "bytes": 2399554, "sha256": elog_sha},
        "source_verification": "full",
        "operator_attestation": {"no_export_window": True,
                                 "recorded_at": "2026-08-24T12:00:00+08:00"},
    }
    m.update(overrides)
    if "source_verification_evidence" not in overrides:
        try:
            agg = aggregate_sha256(manifest_members(m))
            n = len(m["files"]) + 1
        except Exception:                     # overrides 把 files 弄坏了
            agg, n = _sha("uncomputable"), 0
        m["source_verification_evidence"] = {
            "level": "full",
            "passes": [
                {"pass": 1, "files_verified": n, "aggregate_sha256": agg,
                 "completed_at": "2026-08-24T12:01:00+08:00"},
                {"pass": 2, "files_verified": n, "aggregate_sha256": agg,
                 "completed_at": "2026-08-24T12:09:00+08:00"},
            ],
            "passes_agree": True,
        }
    return m


def _recompute_evidence(m: dict) -> dict:
    """改动 files / staged_export_log 之后**必须**调它一次。

    ⚠️⚠️ 不调的后果是**两条判据互相掩盖，让变异验证出假阴性**：聚合指纹的成员是
    `(relative_path, sha256)`，改了任一项（或增删条目）都会让存根里的
    `aggregate_sha256` 与 `files_verified` 同时对不上。此时否定档照样红——
    但红的是**聚合判据**，不是被测的那一条。于是把被测判据变异掉之后测试
    **仍然绿**，而变异表会显示「零红」，被误读成「测试没判别力」。
    本仓栽过这个形态（见 feedback_mutation_false_negatives_two_shapes）。

    弄坏到算不出来时保持原样：那种档由 files / staged_export_log 的形状判据
    负责（它们排在存根校验**之前**）。
    """
    try:
        agg = aggregate_sha256(manifest_members(m))
        n = len(m["files"]) + 1
    except Exception:
        return m
    m["source_verification_evidence"]["passes"] = [
        {"pass": i + 1, "files_verified": n, "aggregate_sha256": agg,
         "completed_at": f"2026-08-24T12:0{i}:00+08:00"} for i in range(2)]
    return m


def _with_universe(uni: dict, **overrides) -> dict:
    """只换 universe，**保持两处 export_log sha256 一致**。

    ⚠️ 不这么做的话，「staged_export_log.sha256 必须等于
    source_snapshot.export_log_sha256」那条判据会**掩盖**本要测的判据：
    否定档照样红，但红的是相等判据，于是变异掉被测判据后测试仍绿。
    """
    base = _valid_manifest()
    return _valid_manifest(
        source_snapshot={
            "export_log_sha256": base["source_snapshot"]["export_log_sha256"],
            "universe": uni},
        **overrides)


def test_the_baseline_manifest_passes_everything():
    """⭐ 正向放行档 —— 整套否定档的判别力全部建立在它之上。

    没有这一条，一个 `def validate_manifest(p): raise ManifestInvalidError("x")`
    的**恒抛**实现会让下面每一条否定档都绿，而五组判据一次都没执行过。
    本仓真栽过这个形态（429 测试 + codex 14 轮全漏）。
    """
    m = _valid_manifest()
    assert validate_manifest(m) == m


@pytest.mark.parametrize("missing", [
    "manifest_version", "seed", "source_snapshot", "source_mount",
    "pool_order", "cursor", "files", "staged_export_log",
    "source_verification", "source_verification_evidence",
])
def test_every_required_key_is_actually_required(missing):
    """10 个必需键**逐个**删，每个都必须让整份 manifest 被拒。

    判别力：把 REQUIRED_KEYS 里任一项删掉，对应那个参数档必红。
    ⚠️ 缺 manifest_version 那一档抛的是 ManifestVersionError（缺失视为 0），
    与其余九档不同——这正是「版本与形状是两族」的体现。
    """
    m = _valid_manifest()
    del m[missing]
    expected = ManifestVersionError if missing == "manifest_version" else ManifestInvalidError
    with pytest.raises(expected):
        validate_manifest(m)


def test_top_level_universe_is_not_required_and_not_rejected():
    """顶层没有 universe（S2-F3）：不加它照样过；加了也只当未知键保留。

    判别力：把 "universe" 加回 REQUIRED_KEYS，本条**第二半**必红。
    （⚠️ 不是第一半——`assert "universe" not in _valid_manifest()` 与 REQUIRED_KEYS
    无关：基座构造的字典本来就没有顶层 universe，改常量不影响那个断言。
    2026-08-25 评审独立推演指出，控制者核实为真。**结论对不代表归因对。**）
    """
    assert "universe" not in _valid_manifest()          # 基座本来就没有它
    validate_manifest(_valid_manifest())                # 且照样通过


def test_validate_manifest_reports_version_before_shape():
    """⭐⭐ **真正的次序钉**（Task 3 那条测不到它——它调的是 `check_version`，
    而 `validate_manifest` 那时还不存在；2026-08-25 控制者归因自查发现）。

    一份版本更高、且按**本版**要求缺了九个必需键的 manifest，必须报
    `ManifestVersionError`（「你的工具太旧」），**而不是** `ManifestInvalidError`
    （「账本畸形」）。一棵已拉几百只股的 staging 收到错误的那一句，
    操作者就不知道该重拉还是该换工具版本（O4-F10 栽过的那档）。

    判别力：把 `validate_manifest` 写成「先查必需键、再 `check_version`」，本条必红。
    """
    with pytest.raises(ManifestVersionError) as ei:
        validate_manifest({"manifest_version": 99})     # 只有版本号，别的全没有
    assert ei.value.kind == "newer"


def test_validate_manifest_reports_shape_error_when_version_matches():
    """反向档：版本对上了，才轮到形状判据说话。

    没有这一条，一个「凡缺键就报 VersionError」的实现也能让上一条绿。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest({"manifest_version": 1})      # 版本对，但九个必需键全缺


def test_every_invalid_error_carries_actionable_guidance():
    """⭐ 不变量：**任何**一条「账本坏了」的拒绝，字符串里都必须带动作指引。

    本模块有约 90 个拒绝点，逐点检查那句话写没写是不可能的纪律——
    把指引提到异常类里统一追加，这条不变量就成了结构上不可违反的东西。
    （2026-08-25：本片曾因「只说哪里不对、没说该怎么办」被评审提了三次，根因即在此。）

    判别力：把 GUIDANCE 的追加去掉（`super().__init__(detail)`），本条必红。
    """
    e = ManifestInvalidError("随便什么细节")
    assert "随便什么细节" in str(e)          # 「哪里不对」还在
    assert "该怎么办" in str(e)              # 「该怎么办」被统一追加
    assert "换一个新的 staging" in str(e)    # 且是可执行的动作，不是空话


def test_invalid_error_keeps_the_raw_detail_separately():
    """`detail` 保留未经追加的原文，便于精确断言与日志分级。"""
    e = ManifestInvalidError("缺少必需字段 'seed'")
    assert e.detail == "缺少必需字段 'seed'"


def test_empty_seed_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(seed=""))


def test_non_string_seed_is_rejected():
    for bad in (1, None, ["s"]):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(seed=bad))
```

> **⚠️ 本任务另有一项「修正 Task 3 遗留」的要求（控制者 2026-08-25 裁决）**：
> 把已落地的 `def test_version_is_decided_before_shape(  ):` 改名为
> `def test_check_version_ignores_everything_but_the_version():`（顺带去掉括号内
> 多余的两个空格），并把它的 docstring 换成上面 ① 给出的版本——原 docstring 声称
> 判别力来自 `validate_manifest` 的次序，而它调的是 `check_version`，**归因是错的**。
> 本仓纪律：**报告里的归因要单独核，结论对不代表归因对**。

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "baseline or required_key or top_level_universe or seed or version_before_shape" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'validate_manifest'`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py

def _require(cond: bool, detail: str) -> None:
    """判据不满足即 fail-closed。**绝不「尽力而为地解析」**。"""
    if not cond:
        raise ManifestInvalidError(detail)


def _require_nonempty_str(value: object, where: str) -> None:
    _require(isinstance(value, str) and value != "",
             f"{where} 必须是非空文字，读到 {value!r}")


def validate_manifest(payload: object) -> dict:
    """**读侧闭合校验**：`qmt_fetch` 与 `qmt_pilot` 读 manifest 时都必须过它，
    任一判据不满足即 fail-closed 拒绝整份 manifest。原样返回通过校验的 manifest。

    ⚠️ **必须在任何 DB 写入之前**（R21-F3）。

    ⚠️ **不做「尽力而为地解析」**：一个被截断的 manifest 解析出来往往仍是合法
    JSON 的**前缀片段**，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」，
    最终产出一份**会撒谎的 pilot 报告**（R1-F4）。

    本函数的作用域**仅限于**把畸形/不自洽的 manifest 挡在门外。
    **它不授予、也不参与任何出货资格判定**（R17-F2 / R18-F2）——
    `ship_eligible ≡ (final_verdict == "SUCCESS")` 是派生量，与本函数无关。
    """
    check_version(payload)                 # ← 先版本、后形状（次序是判据的一部分）
    assert isinstance(payload, dict)       # check_version 已保证

    for key in REQUIRED_KEYS:
        _require(key in payload,
                 f"manifest 缺少必需字段 {key!r}。"
                 "这通常意味着文件被截断，或由不兼容的版本写出。")

    _require_nonempty_str(payload["seed"], "seed")
    return payload
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 30 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M11 | `for key in REQUIRED_KEYS:` → `for key in ():` | 9 个 `..._is_actually_required` 参数档 |
| M12 | `_require_nonempty_str` 里去掉 `!= ""` | `test_empty_seed_is_rejected` |
| M13 | `validate_manifest` 首行改成 `raise ManifestInvalidError("x")`（**恒抛**） | `test_the_baseline_manifest_passes_everything` —— 这一条就是为它存在的 |
| M14 | 把 `check_version(payload)` 挪到必需键循环**之后** | `test_validate_manifest_reports_version_before_shape`（真正的次序钉） |
| M15 | 把必需键循环整个删掉 | `..._reports_shape_error_when_version_matches` + 9 个 `..._is_actually_required` 档 |
| M16 | `ManifestInvalidError.__init__` 改回 `super().__init__(detail)`（不追加指引） | `test_every_invalid_error_carries_actionable_guidance` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): validate_manifest 骨架 + 10 个必需键 + 正向放行档

必需键逐个删各配一档；缺 manifest_version 那档抛的是 VersionError 而非
InvalidError，这正是「版本与形状是两族」的体现。

⭐ _valid_manifest() 基座既是后续全部否定档的唯一来源，本身也是那条
「健康输入必须被放行」的正向档：没有它，一个恒抛的实现会让整套否定档全绿
而五组判据一次都没执行过（本仓真栽过，429 测试 + codex 14 轮全漏）。
基座的 evidence 在 overrides 之后重算，避免两条判据互相掩盖。"
```

---

## Task 6: `source_snapshot` 与 `source_mount` 的形状

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: Task 5 的 `validate_manifest` / `_require`
- Produces: 无新公开符号（判据并入 `validate_manifest`）

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_source_snapshot_universe_must_have_all_three_markets_as_lists():
    for bad in (
        {"SH": [], "SZ": []},                       # 缺 BJ
        {"SH": [], "SZ": [], "BJ": {}},             # BJ 不是 list
        {"SH": [], "SZ": [], "BJ": [], "HK": []},   # 多一层
    ):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_with_universe(
                bad, pool_order={"SH": [], "SZ": [], "BJ": []},
                cursor={"SH": 0, "SZ": 0, "BJ": 0}, files=[]))


def test_source_snapshot_universe_entries_must_be_valid_codes():
    """池与清单一并清空，好让 pool_order 的交叉核对（与本判据重叠）够不着
    ——否则变异掉本判据后交叉核对会顶上来，测试仍绿而变异表显示「零红」。"""
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_with_universe(
            {"SH": ["../escape"], "SZ": [], "BJ": []},
            pool_order={"SH": [], "SZ": [], "BJ": []},
            cursor={"SH": 0, "SZ": 0, "BJ": 0}, files=[]))


def test_universe_code_suffix_must_match_its_layer():
    """⭐ 只有本条够得到：代码本身合法，但被放进了**错的层**。

    池与清单清空的理由同上：pool_order 的交叉核对与本判据重叠。
    （对比 Task 7 的同名判据——那一条**造不出**专属档，已登记为等价变异。）
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_with_universe(
            {"SH": ["000001.SZ"], "SZ": [], "BJ": []},
            pool_order={"SH": [], "SZ": [], "BJ": []},
            cursor={"SH": 0, "SZ": 0, "BJ": 0}, files=[]))


def test_source_snapshot_export_log_sha256_must_be_hex64():
    """⚠️ **两处 sha 同时设成同一个坏值**，好让「两处必须相等」那条判据够不着。

    只改 source_snapshot 那一处的话，相等判据会掩盖格式判据：把格式判据
    变异掉（例如放宽成允许大写）之后，"A"*64 那一档仍会被相等判据拒 →
    测试仍绿 → 变异表显示「零红」，被误读成「测试没判别力」。
    """
    base = _valid_manifest()
    for bad in ("", "XYZ", "A" * 64, "a" * 63, 1, None):
        m = _valid_manifest(
            source_snapshot={"export_log_sha256": bad,
                             "universe": base["source_snapshot"]["universe"]})
        m["staged_export_log"]["sha256"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_source_mount_requires_three_subkeys():
    base = {"fstype": "smbfs", "device": "//h/s", "source_root_relative": "d"}
    for drop in ("fstype", "device", "source_root_relative"):
        bad = dict(base)
        del bad[drop]
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_mount=bad))


def test_source_mount_fstype_and_device_must_be_nonempty():
    for key in ("fstype", "device"):
        bad = {"fstype": "smbfs", "device": "//h/s", "source_root_relative": "d"}
        bad[key] = ""
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_mount=bad))


def test_source_root_relative_may_be_empty_string():
    """⭐ S2-F2：`source_root_relative` **允许空串**。

    §4.6 (ii-a) 用实测论证了「共享本身就是导出根」时它就是空串，并规定拼接
    走 posixpath.normpath 以免撞空分量。而读侧原文写「三子键均为非空 str」——
    两条并存时，一次**完全合法的部署**会先过 (ii-a) 的拼接、再被读侧判死，
    操作者被指向一个不存在的问题。

    判别力：把 source_root_relative 也按「非空」校验，本条必红。
    """
    m = _valid_manifest(source_mount={
        "fstype": "smbfs", "device": "//h/s", "source_root_relative": "",
    })
    assert validate_manifest(m) == m


def test_source_root_relative_must_still_be_a_string():
    """允许空串 ≠ 允许任意类型。"""
    for bad in (None, 0, [], {}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_mount={
                "fstype": "smbfs", "device": "//h/s", "source_root_relative": bad,
            }))


def test_source_mount_may_carry_extra_trace_only_keys():
    """mountpoint / source_root 只留痕、不参与判定（R25-F2），
    带着它们必须照样通过——否则一个诚实产出的 manifest 会被拒。"""
    m = _valid_manifest(source_mount={
        "fstype": "smbfs", "device": "//h/s",
        "source_root_relative": "front_ratio_cn_stocks_ab_bj",
        "mountpoint": "/Users/agate/qmt_mnt",
        "source_root": "/Users/agate/qmt_mnt/front_ratio_cn_stocks_ab_bj",
    })
    assert validate_manifest(m) == m
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "source_snapshot or source_mount or source_root_relative" 2>&1 | tail -10
```

Expected: FAIL —— 多条 `DID NOT RAISE ManifestInvalidError`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部（常量区）补：
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_STOCK_CODE_RE = re.compile(r"^\d+\.(SH|SZ|BJ)$")


# 追加到 backend/qmt_manifest.py（放在 validate_manifest 之前）

def _require_sha256(value: object, where: str) -> None:
    """sha256 必须是 **64 位小写十六进制**。大写不放行——同一份字节两种写法
    会让「逐字相符」这条判据静默失效。"""
    _require(isinstance(value, str) and _SHA256_RE.match(value) is not None,
             f"{where} 必须是 64 位小写十六进制的 sha256，读到 {value!r}")


def _require_market_map(value: object, where: str, kind: str) -> dict:
    """三层字典：键恰为 SH/SZ/BJ，不多不少。"""
    _require(isinstance(value, dict), f"{where} 必须是对象，读到 {type(value).__name__}")
    _require(set(value.keys()) == set(MARKETS),
             f"{where} 的键必须恰为 {list(MARKETS)}，读到 {sorted(value.keys())}")
    for mk in MARKETS:
        if kind == "list":
            _require(isinstance(value[mk], list), f"{where}[{mk}] 必须是列表")
        elif kind == "int":
            _require(isinstance(value[mk], int) and not isinstance(value[mk], bool),
                     f"{where}[{mk}] 必须是整数，读到 {value[mk]!r}")
    return value


def _validate_source_snapshot(snap: object) -> None:
    _require(isinstance(snap, dict), "source_snapshot 必须是对象")
    _require("export_log_sha256" in snap, "source_snapshot 缺 export_log_sha256")
    _require_sha256(snap["export_log_sha256"], "source_snapshot.export_log_sha256")
    _require("universe" in snap,
             "source_snapshot 缺 universe —— 冻结的候选名单是补拉游标的唯一锚点，"
             "缺了它整棵 staging 无法续跑")
    uni = _require_market_map(snap["universe"], "source_snapshot.universe", "list")
    for mk in MARKETS:
        for i, code in enumerate(uni[mk]):
            _require(isinstance(code, str) and _STOCK_CODE_RE.match(code) is not None,
                     f"source_snapshot.universe[{mk}][{i}] 不是合法股票代码：{code!r}")
            _require(code.endswith("." + mk),
                     f"source_snapshot.universe[{mk}][{i}] = {code!r} 的后缀与所在层不符")


def _validate_source_mount(mount: object) -> None:
    """`source_mount` 的形状（S2-F2 更正）。

    ⚠️ **`source_root_relative` 允许空串**：§4.6 (ii-a) 用实测论证了
    「共享本身就是导出根」时它就是空串。读侧原文的「三子键均为非空 str」
    会让那种**完全合法的部署**先过 (ii-a) 的拼接、再被读侧判死，
    并把操作者指向一个不存在的问题。

    `mountpoint` / `source_root` 是 fetch 那次的**绝对形态，仅供留痕、
    不参与判定**（R25-F2：把偶然的挂载点形态写进身份判据，会让同一共享重挂到
    `/Volumes/QMT_Export-1` 时否决掉一次完全合法的出货）——故本函数不校验它们，
    但也不拒绝它们的存在。
    """
    _require(isinstance(mount, dict), "source_mount 必须是对象")
    for key in ("fstype", "device", "source_root_relative"):
        _require(key in mount, f"source_mount 缺 {key}")
    _require_nonempty_str(mount["fstype"], "source_mount.fstype")
    _require_nonempty_str(mount["device"], "source_mount.device")
    _require(isinstance(mount["source_root_relative"], str),
             "source_mount.source_root_relative 必须是文字"
             f"（允许空串——共享本身即导出根时就是空的），读到 "
             f"{mount['source_root_relative']!r}")


# validate_manifest 里，`_require_nonempty_str(payload["seed"], "seed")` 之后追加：
    _validate_source_snapshot(payload["source_snapshot"])
    _validate_source_mount(payload["source_mount"])
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 38 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M14 | `_require(isinstance(mount["source_root_relative"], str), ...)` → `_require_nonempty_str(...)` | `test_source_root_relative_may_be_empty_string` |
| M15 | `_SHA256_RE` 改成 `^[0-9a-fA-F]{64}$` | `..._export_log_sha256_must_be_hex64`（`"A"*64` 那档） |
| M16 | `set(value.keys()) == set(MARKETS)` → `set(MARKETS) <= set(value.keys())` | `..._must_have_all_three_markets_as_lists`（多一层那档） |
| M17 | 删掉 `_validate_source_snapshot` 里的 `code.endswith("." + mk)` | `test_universe_code_suffix_must_match_its_layer` |

> ⚠️ M17 是「重叠判据必须各配一个只有它够得到的档」的实例：`..._entries_must_be_valid_codes`
> 测的是**正则**那条，对后缀判据零判别力。专属档已单列（池与清单清空，好让 pool_order
> 的交叉核对够不着）。**发现某条判据没有专属档时，补档，不是删判据。**

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): source_snapshot 与 source_mount 的形状（含 S2-F2 的空串更正）

source_root_relative 允许空串：§4.6 (ii-a) 用实测论证了「共享本身即导出根」
时它就是空的，而读侧原文要求非空——两条并存会让一次完全合法的部署先过
(ii-a) 的拼接、再被读侧判死。

mountpoint / source_root 只留痕不参与判定（R25-F2），故不校验也不拒绝，
并为「带着它们照样通过」立了一条正向档。

sha256 只认小写：同一份字节两种写法会让「逐字相符」静默失效。"
```

---

## Task 7: `pool_order` 的元素形状、代码规则与层内唯一

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么元素必须是对象而不是裸字符串**：R12-F1 把元素从裸字符串改成 `{code, universe_idx}`，因为**拷贝失败是跳过继续的、而重试发生在下一批的开头**——U5 第一批失败、U6–U121 成功后顺次追加，第二批重试 U5 成功就被追加到**列表末尾**。pilot 把 `pool_order` 当唯一消费顺序，结果是**最终选中哪 100 只取决于当时 SMB 有没有抖一下**，而不是取决于 `seed` 与源快照。**裸字符串元素的旧式 manifest 必须被拒**，否则那个口子重开（R13-F1）。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_pool_order_must_have_all_three_markets_as_lists():
    for bad in ({"SH": [], "SZ": []}, {"SH": [], "SZ": [], "BJ": 0}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(pool_order=bad))


def test_pool_order_bare_string_elements_are_rejected():
    """⭐ 旧式裸字符串必须被拒（R13-F1）。

    判别力：若实现「兼容」裸字符串（退回只读 code），本条必红。
    退回等于丢掉 universe_idx，把 R12-F1 那个「产出取决于网络抖动」的口子重开。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(pool_order={
            "SH": ["600000.SH"], "SZ": [], "BJ": [],
        }))


def test_pool_order_element_needs_both_code_and_universe_idx():
    for bad in ({"code": "600000.SH"}, {"universe_idx": 0}, {}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                pool_order={"SH": [bad], "SZ": [], "BJ": []},
                files=[], staged_export_log={"relative_path": "export_log.csv",
                                             "bytes": 1, "sha256": _sha("e")}))


def test_pool_order_code_must_match_the_stock_code_pattern():
    for bad in ("600000", "600000.HK", "../600000.SH", "600000.sh", ""):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                pool_order={"SH": [{"code": bad, "universe_idx": 0}],
                            "SZ": [], "BJ": []}))


def test_pool_order_code_suffix_must_match_its_market_layer():
    """代码本身合法，但被放进了错的层。

    ⚠️⚠️ **本档对应的变异是「等价变异」，已登记**（2026-08-24 实测确认）：
    在一份**合法的** universe 下（每层 code 后缀都对），一个后缀错的
    pool_order code **必然也过不了**交叉核对 `universe[mk][idx] == code`
    ——两条判据**结构上重叠**，造不出「只有后缀判据够得到」的档。

    保留后缀判据的理由是它给出**更准确的错误信息**（「放错层了」而不是
    「锚点对不上」），**不是**它挡住了别的判据挡不住的东西。
    故变异 M19 之后本条**仍绿是预期的**——别把它当成「测试没判别力」而去
    删判据，也别为了让它红而伪造一个 universe（那会同时踩到
    `_validate_source_snapshot` 的后缀判据，测的就不是这一条了）。

    （`source_snapshot.universe` 那一侧的同名判据**有**专属档，
    见 `test_universe_code_suffix_must_match_its_layer`。）
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "000001.SZ", "universe_idx": 0}],
                        "SZ": [], "BJ": []}))


def test_pool_order_duplicate_code_within_a_layer_is_rejected():
    """层内 code 唯一：同一只股出现两次会让 pilot 重复消费。"""
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 0},
                               {"code": "600000.SH", "universe_idx": 1}],
                        "SZ": [], "BJ": []}))


def test_pool_order_duplicate_universe_idx_within_a_layer_is_rejected():
    """⭐ 层内 universe_idx 也必须唯一 —— 与 code 唯一是**两条**判据。

    判别力：只查 code 唯一的实现会放行本档（两个不同 code 指向同一下标），
    而那意味着锚点坏了。删掉 idx 唯一那条，本条必红。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 0},
                               {"code": "600004.SH", "universe_idx": 0}],
                        "SZ": [], "BJ": []}))
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k pool_order 2>&1 | tail -10
```

Expected: FAIL —— 多条 `DID NOT RAISE`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

def _validate_pool_order(pool: object, universe: dict) -> None:
    """`pool_order` 是 **pilot 的唯一消费顺序来源**（P4-D8），故它的每一条都要
    带锚点、锚点要交叉核对、层内两个字段各自唯一。

    ⚠️ **裸字符串元素必须被拒**（R13-F1）：R12-F1 把元素改成 `{code, universe_idx}`
    正是因为拷贝失败是跳过继续、而重试发生在下一批开头——U5 第一批失败、
    U6–U121 成功后顺次追加，第二批重试 U5 成功就被追加到**列表末尾**。
    pilot 按追加顺序消费的话，**最终选中哪 100 只取决于当时 SMB 有没有抖一下**。
    「兼容」裸字符串等于丢掉锚点，把那个口子重开。
    """
    _require_market_map(pool, "pool_order", "list")
    for mk in MARKETS:
        seen_codes: set[str] = set()
        seen_idx: set[int] = set()
        for i, item in enumerate(pool[mk]):
            where = f"pool_order[{mk}][{i}]"
            _require(isinstance(item, dict),
                     f"{where} 必须是对象 {{code, universe_idx}}，读到 "
                     f"{type(item).__name__}——裸字符串是旧版格式，"
                     "缺锚点会让消费顺序取决于网络抖动，一律拒绝")
            _require("code" in item and "universe_idx" in item,
                     f"{where} 必须同时有 code 与 universe_idx，读到 {sorted(item)}")
            code = item["code"]
            _require(isinstance(code, str) and _STOCK_CODE_RE.match(code) is not None,
                     f"{where}.code 不是合法股票代码：{code!r}")
            _require(code.endswith("." + mk),
                     f"{where}.code = {code!r} 的后缀与所在层 {mk} 不符")
            idx = item["universe_idx"]
            _require(isinstance(idx, int) and not isinstance(idx, bool),
                     f"{where}.universe_idx 必须是整数，读到 {idx!r}")
            _require(code not in seen_codes, f"{where}.code = {code!r} 在本层重复出现")
            _require(idx not in seen_idx, f"{where}.universe_idx = {idx} 在本层重复出现")
            seen_codes.add(code)
            seen_idx.add(idx)


# validate_manifest 里，`_validate_source_mount(...)` 之后追加：
    _validate_pool_order(payload["pool_order"], payload["source_snapshot"]["universe"])
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 45 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M18 | `isinstance(item, dict)` → `isinstance(item, (dict, str))` | `..._bare_string_elements_are_rejected` |
| M19 | 删 `_validate_pool_order` 里的 `code.endswith("." + mk)` | **等价变异，预期不红**（见下） |
| M20 | 删 `idx not in seen_idx` 那条 | `..._duplicate_universe_idx_within_a_layer...` |
| M21 | 删 `code not in seen_codes` 那条 | `..._duplicate_code_within_a_layer...` |

> ⚠️ **M19 是已登记的等价变异**（2026-08-24 实测）：在合法 universe 下，后缀错的 code
> 必然也过不了交叉核对，两条判据结构上重叠。变异后不红是**预期**，**不得据此删判据**
> ——它的价值是更准确的错误信息。`source_snapshot` 那一侧的同名判据**有**专属档（M17）。
>
> M20 与 M21 **必须各自单独变异**：只删一条时另一条不会红（两个否定档分别只碰一个字段），
> 但若实现把两个集合写成同一个，两条变异**互相掩盖**——那时须补一条组合档。

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): pool_order 元素形状、代码规则与层内双唯一

裸字符串元素一律拒（R13-F1）：R12-F1 改成带锚点的对象，正是因为重试成功的
股会被追加到列表末尾，pilot 按追加顺序消费就让「最终选中哪 100 只」取决于
当时 SMB 有没有抖一下。兼容裸字符串等于把那个口子重开。

code 唯一与 universe_idx 唯一是两条判据，各配一个只有它够得到的档。"
```

---

## Task 8: `universe_idx` 交叉核对与 `cursor` 边界

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么要交叉核对**：锚点必须**真的指向它自称的那只股**。一份被手工编辑或版本错位的 manifest，完全可以有合法的 code、合法的下标，而两者对不上——此时消费顺序静默错乱，且没有任何一处会报错。

**为什么 `cursor` 的上界是闭区间**：`cursor[market]` 记的是「已尝试到的下标」，取遍全层时它等于 `len(universe[market])`——那是**合法的终态**（池穷尽），不是越界。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_universe_idx_out_of_range_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 99}],
                        "SZ": [], "BJ": []}))


def test_negative_universe_idx_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": -1}],
                        "SZ": [], "BJ": []}))


def test_universe_idx_must_actually_point_at_that_code():
    """⭐ 交叉核对：下标合法、代码合法、后缀对层，但**指向的是另一只股**。

    判别力：删掉 `universe[mk][idx] == code` 那条，本条必红（且只有它会红）。
    一份手工编辑或版本错位的 manifest 正是这个形状。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            pool_order={"SH": [{"code": "600000.SH", "universe_idx": 1}],  # [1] 是 600004.SH
                        "SZ": [], "BJ": []}))


def test_cursor_must_be_int_per_market():
    for bad in ({"SH": "1", "SZ": 1, "BJ": 0}, {"SH": 1.0, "SZ": 1, "BJ": 0},
                {"SH": True, "SZ": 1, "BJ": 0}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(cursor=bad))


def test_cursor_out_of_range_is_rejected():
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(cursor={"SH": 4, "SZ": 1, "BJ": 0}))
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(cursor={"SH": -1, "SZ": 1, "BJ": 0}))


def test_cursor_equal_to_universe_length_is_the_legal_exhausted_state():
    """⭐ 上界是**闭**区间：取遍全层时 cursor == len(universe)，那是池穷尽
    这个合法终态，不是越界。

    判别力：把 `<= len` 写成 `< len`，本条必红——而那会让一次正常跑到池尽的
    staging 在下次启动时被判「账本非法」。
    """
    m = _valid_manifest(cursor={"SH": 3, "SZ": 2, "BJ": 1})   # 各层 len 分别是 3/2/1
    assert validate_manifest(m) == m
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "universe_idx or cursor" 2>&1 | tail -10
```

Expected: FAIL

- [ ] **Step 3: 最小实现**

```python
# _validate_pool_order 的循环体内，`seen_idx.add(idx)` 之前追加：
            layer = universe[mk]
            _require(0 <= idx < len(layer),
                     f"{where}.universe_idx = {idx} 越界"
                     f"（本层冻结名单长度 {len(layer)}）")
            _require(layer[idx] == code,
                     f"{where} 的锚点对不上：universe[{mk}][{idx}] 是 "
                     f"{layer[idx]!r}，而这条记录自称是 {code!r}。"
                     "这份 manifest 被编辑过或来自另一次 fetch。")


# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

def _validate_cursor(cursor: object, universe: dict) -> None:
    """`cursor[market]` = **已尝试到**冻结名单的下标（R3-F2），与 `pool_order`
    这个**成功列表**语义不同、不可互相替代。

    ⚠️ **上界是闭区间**：取遍全层时 `cursor == len(universe[market])`，
    那是「池穷尽」这个合法终态。写成开区间会让一次正常跑到池尽的 staging
    在下次启动时被判「账本非法」。
    """
    _require_market_map(cursor, "cursor", "int")
    for mk in MARKETS:
        n = len(universe[mk])
        _require(0 <= cursor[mk] <= n,
                 f"cursor[{mk}] = {cursor[mk]} 越界（本层冻结名单长度 {n}，"
                 f"合法范围 0..{n}，取到 {n} 表示该层已取遍）")


# validate_manifest 里，`_validate_pool_order(...)` 之后追加：
    _validate_cursor(payload["cursor"], payload["source_snapshot"]["universe"])
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 51 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M22 | 删 `layer[idx] == code` 那条 | `..._must_actually_point_at_that_code` |
| M23 | `0 <= cursor[mk] <= n` → `0 <= cursor[mk] < n` | `..._equal_to_universe_length_is_the_legal_exhausted_state` |
| M24 | `0 <= idx < len(layer)` → `idx < len(layer)` | `test_negative_universe_idx_is_rejected` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): universe_idx 交叉核对 + cursor 闭区间边界

交叉核对锚点真的指向它自称的那只股：一份手工编辑或版本错位的 manifest
完全可以有合法 code、合法下标而两者对不上，此时消费顺序静默错乱。

cursor 上界是闭区间：取遍全层时它等于 len(universe)，那是池穷尽这个合法
终态。写成开区间会让一次正常跑到池尽的 staging 下次启动被判账本非法。"
```

---

## Task 9: `files` 实拷清单逐项合规

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: `qmt_fsroot.split_relative_components`（Task 1）、`qmt_normalize.parse_qmt_filename`

**为什么这份清单必须被校验**：它是 `staging_intact`、`pilot_stock_source`、三方源校验**共同的真相基准**，而读侧校验此前**唯独漏了它**（R21-F3）。一份被编辑过或半截写入的 manifest 可以形状全过，却给某只股缺一条、重一条、或**把 1m 的哈希绑到 daily 上**——结果是「校验的字节与导入器实际消费的字节根本不是同一批」。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_each_pooled_stock_needs_exactly_two_file_records():
    m = _valid_manifest()
    m["files"] = [r for r in m["files"] if r["stock_code"] != "600000.SH"]
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_a_stock_with_two_records_of_the_same_period_is_rejected():
    """⭐ 只有本条够得到：条数对（2 条），但周期是 1m + 1m。

    判别力：只数「恰好 2 条」而不查周期集合的实现会放行本档。
    """
    m = _valid_manifest()
    dup = dict(_file_rec("600000.SH", "浦发银行", "1m"))
    dup["relative_path"] = dup["relative_path"].replace(".csv", "_2.csv")
    m["files"] = [r for r in m["files"]
                  if not (r["stock_code"] == "600000.SH" and r["period"] == "daily")] + [dup]
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_extra_file_record_not_belonging_to_any_pooled_stock_is_rejected():
    m = _valid_manifest()
    m["files"] = m["files"] + [_file_rec("600004.SH", "上海机场", "1m")]
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_relative_path_must_stay_inside_staging():
    for bad in ("../outside.csv", "/etc/passwd", "a/../../x.csv", "./x.csv", ""):
        m = _valid_manifest()
        m["files"][0]["relative_path"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_file_name_must_parse_to_the_same_code_and_period():
    """⭐ 文件名解析出的 code/period 必须与记录里写的一致。

    判别力：删掉这条，「把 1m 的哈希绑到 daily 上」就静默通过——
    而校验的字节与导入器消费的字节从此不是同一批（R21-F3 原话）。
    """
    m = _valid_manifest()
    # 记录说自己是 daily，文件名却是 1 分钟线
    rec = next(r for r in m["files"]
               if r["stock_code"] == "600000.SH" and r["period"] == "daily")
    rec["relative_path"] = "日K线_前复权/600000.SH_浦发银行_1分钟K线_前复权.csv"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_name_code_mismatch_is_rejected():
    m = _valid_manifest()
    m["files"][0]["relative_path"] = "1分钟K线_前复权/600004.SH_上海机场_1分钟K线_前复权.csv"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_name_not_matching_qmt_rules_is_rejected():
    m = _valid_manifest()
    m["files"][0]["relative_path"] = "1分钟K线_前复权/随便一个名字.csv"
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_file_bytes_must_be_nonnegative_int():
    for bad in (-1, "1", 1.5, True, None):
        m = _valid_manifest()
        m["files"][0]["bytes"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_file_sha256_must_be_hex64_lowercase():
    for bad in ("", "z" * 64, "A" * 64, "a" * 63, 1):
        m = _valid_manifest()
        m["files"][0]["sha256"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_zero_byte_file_record_is_allowed():
    """正向档：bytes == 0 合法（一只 status=empty 的股导出 0 行的 CSV
    仍是一个真实存在、可被哈希的文件）。判据是「非负」，不是「正」。"""
    m = _valid_manifest()
    m["files"][0]["bytes"] = 0
    assert validate_manifest(m) == m


def test_empty_pool_with_empty_files_is_valid():
    """⭐ 正向档：一次刚起步、还没拷到任何股的 fetch。

    判据是「pool_order 里每只股恰好 2 条」，池为空时 files 也为空是合法的
    ——首份 manifest 就是这个形状（staged_export_log 先于任何 K 线落盘）。
    """
    m = _valid_manifest(
        pool_order={"SH": [], "SZ": [], "BJ": []},
        cursor={"SH": 0, "SZ": 0, "BJ": 0},
        files=[])
    assert validate_manifest(m) == m
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "file_ or pooled_stock or empty_pool" 2>&1 | tail -10
```

Expected: FAIL

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部补 import
from qmt_fsroot import PathDisciplineError, split_relative_components
from qmt_normalize import QmtSchemaError, parse_qmt_filename


# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

def _require_relative_inside(relpath: object, where: str) -> list[str]:
    """路径必须**留在 staging 之内**。

    ⚠️ 用的是 S1 的**分量规则**，不是 spec 字面写的 `resolve()`：`resolve()`
    **会跟随符号链接**（那正是 O2-F4 造 `parent_fd_under` 的全部理由），拿它当
    边界判据等于把判据建在会被绕过的调用上。分量规则更强，且**不碰文件系统**
    ——读侧校验因此得以是纯函数。真正的符号链接防线在打开那一刻由
    `open_under` 逐段 `O_NOFOLLOW` 承担。
    """
    _require(isinstance(relpath, str), f"{where} 必须是文字，读到 {relpath!r}")
    try:
        return split_relative_components(relpath)
    except PathDisciplineError as e:
        raise ManifestInvalidError(f"{where} 不是一条留在 staging 内的相对路径：{e}") from e


def _validate_files(files: object, pool: dict) -> None:
    """实拷清单逐项合规（R21-F3）。

    ⚠️ **这份清单是 `staging_intact` / `pilot_stock_source` / 三方源校验共同的
    真相基准**，而读侧校验此前唯独漏了它。一份被编辑过或半截写入的 manifest
    可以形状全过，却给某只股缺一条、重一条、或**把 1m 的哈希绑到 daily 上**
    ——于是「校验的字节与导入器实际消费的字节根本不是同一批」。
    """
    _require(isinstance(files, list), "files 必须是列表")

    pooled: set[str] = {item["code"] for mk in MARKETS for item in pool[mk]}
    by_stock: dict[str, list[str]] = {}

    for i, rec in enumerate(files):
        where = f"files[{i}]"
        _require(isinstance(rec, dict), f"{where} 必须是对象")
        for key in ("stock_code", "period", "relative_path", "bytes", "sha256"):
            _require(key in rec, f"{where} 缺 {key}")

        code = rec["stock_code"]
        _require(isinstance(code, str) and _STOCK_CODE_RE.match(code) is not None,
                 f"{where}.stock_code 不是合法股票代码：{code!r}")
        _require(rec["period"] in PERIODS,
                 f"{where}.period 必须是 {list(PERIODS)} 之一，读到 {rec['period']!r}")

        parts = _require_relative_inside(rec["relative_path"], f"{where}.relative_path")
        try:
            f_code, _f_name, f_period = parse_qmt_filename(parts[-1])
        except QmtSchemaError as e:
            raise ManifestInvalidError(
                f"{where}.relative_path 的文件名不符合 QMT 导出规则：{e}") from e
        _require(f_code == code,
                 f"{where} 自称是 {code!r}，而文件名解析出的是 {f_code!r}")
        _require(f_period == rec["period"],
                 f"{where} 自称周期是 {rec['period']!r}，而文件名解析出的是 "
                 f"{f_period!r}——把 1m 的哈希绑到 daily 上，校验的字节与导入器"
                 "消费的字节就不是同一批了")

        _require(isinstance(rec["bytes"], int) and not isinstance(rec["bytes"], bool)
                 and rec["bytes"] >= 0,
                 f"{where}.bytes 必须是非负整数，读到 {rec['bytes']!r}")
        _require_sha256(rec["sha256"], f"{where}.sha256")

        _require(code in pooled,
                 f"{where} 记的 {code!r} 不属于 pool_order 里的任何一只股——"
                 "多余的活跃记录会让完整性闸拿着一个没人认领的基准去比对")
        by_stock.setdefault(code, []).append(rec["period"])

    for code in sorted(pooled):
        got = sorted(by_stock.get(code, []))
        _require(got == sorted(PERIODS),
                 f"{code} 在 files 里的记录是 {got}，必须恰好是 "
                 f"{sorted(PERIODS)} 各一条——一只股的两个文件是一次事务，"
                 "缺一条意味着上一次运行崩在两次 os.replace 之间")


# validate_manifest 里，`_validate_cursor(...)` 之后追加：
    _validate_files(payload["files"], payload["pool_order"])
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 62 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M25 | 删 `f_period == rec["period"]` 那条 | `..._must_parse_to_the_same_code_and_period` |
| M26 | 删 `f_code == code` 那条 | `..._file_name_code_mismatch_is_rejected` |
| M27 | `got == sorted(PERIODS)` → `len(got) == 2` | `..._two_records_of_the_same_period_is_rejected` |
| M28 | 删 `code in pooled` 那条 | `..._extra_file_record_not_belonging...` |
| M29 | `rec["bytes"] >= 0` → `rec["bytes"] > 0` | `test_zero_byte_file_record_is_allowed` |
| M30 | `_require_relative_inside` 直接 `return relpath.split("/")` | 5 条 `..._must_stay_inside_staging` |

> ⚠️ **本组每一条否定档都调了 `_recompute_evidence(m)`**——不调的话聚合判据会
> **掩盖**被测判据：否定档照样红，但红的是聚合、不是被测的那条，于是变异掉
> 被测判据后测试**仍然绿**、变异表显示「零红」，被误读成「测试没判别力」。
> **归因要单独核**：跑变异时确认红的那条断言真的指向被测判据。

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): files 实拷清单逐项合规（R21-F3 —— 被最广泛信任却唯独没被校验的结构）

每只池内股恰好 2 条且周期集合恰为 {1m, daily}（只数条数的实现放行不了
1m+1m）、无多余记录、路径留在 staging 内、文件名解析出的 code/period 与
记录一致、bytes 非负、sha256 小写 hex64。

「把 1m 的哈希绑到 daily 上」是这条清单最危险的坏法：形状全过，而校验的
字节与导入器实际消费的字节不是同一批。

路径判据用 S1 的分量规则而非 spec 字面的 resolve()——resolve() 会跟随符号
链接（O2-F4 造 parent_fd_under 的全部理由），拿它当边界判据是把判据建在
会被绕过的调用上。分量规则更强，且让读侧校验保持纯函数。

bytes 判据是「非负」不是「正」：status=empty 的股导出 0 行 CSV 仍是真实文件。"
```

---

## Task 10: `staged_export_log` 自洽

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么它必须被钉住（R38-F1）**：`import_qmt_stock` 真正消费的元数据就是**这一份 staged 副本**——`build_stock_import` 的门 2 拿它的 `rows` 与首尾时间戳去卡每只股。而此前全套完整性闸只钉了 K 线 CSV，**唯独漏了这个所有股都依赖的全局输入**。它被截断、被手工改过、或残留自上一代，pilot 都照用不误：轻则把好数据判成 `export_log_mismatch` 一片 skip，重则**一份手改的 staged log 能让本该被拒的股过门**。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_staged_export_log_requires_all_three_subkeys():
    for drop in ("relative_path", "bytes", "sha256"):
        m = _valid_manifest()
        del m["staged_export_log"][drop]
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_staged_export_log_path_must_stay_inside_staging():
    for bad in ("../export_log.csv", "/etc/passwd", ""):
        m = _valid_manifest()
        m["staged_export_log"]["relative_path"] = bad
        _recompute_evidence(m)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_staged_export_log_sha256_must_equal_source_snapshot_sha256():
    """⭐ 只有本条够得到：两处都是合法的 sha256，但**互不相等**。

    同一份字节在 manifest 里被记了两次（源那一份 / staged 那一份），
    不等即 manifest **自相矛盾**（R38-F1）。

    判别力：删掉这条相等判据，本条必红（且只有它会红）。
    """
    m = _valid_manifest()
    m["staged_export_log"]["sha256"] = _sha("another")
    _recompute_evidence(m)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_staged_export_log_bytes_must_be_nonnegative_int():
    for bad in (-1, "1", 1.5, True):
        m = _valid_manifest()
        m["staged_export_log"]["bytes"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k staged_export_log 2>&1 | tail -10
```

Expected: FAIL

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

def _validate_staged_export_log(sel: object, export_log_sha256: str) -> None:
    """staged `export_log.csv` 与 K 线 CSV 受**同等纪律**（R38-F1）。

    ⚠️ **它是所有股共用的元数据基准**：`build_stock_import` 的门 2 拿它的
    `rows` 与首尾时间戳去卡每一只股。此前全套完整性闸只钉了 K 线 CSV，
    唯独漏了它——**一份手改的 staged log 能让本该被拒的股过门**，而权威源里
    那一份根本不认。

    `sha256` 必须**等于** `source_snapshot.export_log_sha256`：同一份字节在
    manifest 里被记了两次，不等即自相矛盾。
    """
    _require(isinstance(sel, dict), "staged_export_log 必须是对象")
    for key in ("relative_path", "bytes", "sha256"):
        _require(key in sel, f"staged_export_log 缺 {key}")
    _require_relative_inside(sel["relative_path"], "staged_export_log.relative_path")
    _require(isinstance(sel["bytes"], int) and not isinstance(sel["bytes"], bool)
             and sel["bytes"] >= 0,
             f"staged_export_log.bytes 必须是非负整数，读到 {sel['bytes']!r}")
    _require_sha256(sel["sha256"], "staged_export_log.sha256")
    _require(sel["sha256"] == export_log_sha256,
             "staged_export_log.sha256 与 source_snapshot.export_log_sha256 不等"
             "——同一份字节的两处记录对不上，这份 manifest 自相矛盾")


# validate_manifest 里，`_validate_files(...)` 之后追加：
    _validate_staged_export_log(payload["staged_export_log"],
                                payload["source_snapshot"]["export_log_sha256"])
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 71 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M31 | 删 `sel["sha256"] == export_log_sha256` 那条 | `..._must_equal_source_snapshot_sha256` |
| M32 | 删整个 `_validate_staged_export_log` 调用 | 上面 4 组全红 |

> ⚠️ **M32 的归因需人核**：删掉该调用后，「缺子键」那一组会在存根校验里撞
> `KeyError`（`manifest_members` 取不到 `sha256`）而不是干净的
> `ManifestInvalidError` —— 测试确实红，但**红的原因不是被测判据**。
> 正常流程里不会走到那里（形状判据排在存根校验之前），故不改实现；
> 但变异报告里必须如实写明这一条的红是 `KeyError`。

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): staged_export_log 自洽（R38-F1）

它是所有股共用的元数据基准（build_stock_import 门 2 拿它的 rows 与首尾时间戳
卡每只股），此前全套完整性闸只钉了 K 线 CSV、唯独漏了它——一份手改的
staged log 能让本该被拒的股过门，而权威源里那份根本不认。

sha256 必须等于 source_snapshot.export_log_sha256：同一份字节被记了两次，
不等即 manifest 自相矛盾。"
```

---

## Task 11: `stopped_reason` / `fetch_fatal_error` 的形状与配对

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么必须进读侧校验（R93-F1）**：`stopped_reason` 是 fetch 侧的**致命信号**，§5 也写了「pilot 读到即 fail-closed」——**可那份读侧校验清单从头到尾没提过它**。而一次被源树逃逸终止的 fetch，其 manifest **仍然带着此前成功拉到的 `pool_order` 与 `files`，形状上完全合法**。照那份清单实现的 pilot 会**照常消费那批股**，把一次**信任边界破坏**报成「候选不够」甚至走到 `SUCCESS`。

**⚠️ `kind` 与 `stopped_reason` 必须解耦（O4-F3）**：`kind` 记的是**首次逃逸的类型**，`stopped_reason` 是**本次为什么停**。复校失败那一档正是「保留 fatal + 换 `stopped_reason`」——写成「`kind` 恒等于 `stopped_reason`」会让它**结构上不可表达**。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def _fatal(kind="staging_path_escape"):
    return {"kind": kind, "relative_path": "1分钟K线_前复权/x.csv",
            "component": "1分钟K线_前复权", "errno": "ENOTDIR"}


def test_manifest_without_stopped_reason_is_valid():
    """正向档：绝大多数 manifest 没有这个字段（它是可选的）。"""
    m = _valid_manifest()
    assert "stopped_reason" not in m
    assert validate_manifest(m) == m


def test_max_bytes_needs_no_fatal_error():
    """正向档：干净的配额触顶**不**带 fetch_fatal_error（R44-F2：
    容量停止是可恢复的、与数据无关的终止条件，不是信任边界破坏）。"""
    m = _valid_manifest(stopped_reason="max_bytes")
    assert validate_manifest(m) == m


def test_stopped_reason_outside_the_closed_enum_is_rejected():
    for bad in ("disk_full", "", "MAX_BYTES", None, 1):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(stopped_reason=bad))


@pytest.mark.parametrize("reason", [
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
])
def test_escape_reasons_require_a_fetch_fatal_error(reason):
    """⭐ 三个值都必须同时带 fetch_fatal_error。

    判别力：只对两个 escape 要求而漏掉 staging_recheck_failed（原 spec 只写了
    两个值，O4-F3 才补的第四值），本条第三个参数档必红。
    """
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(stopped_reason=reason))


@pytest.mark.parametrize("reason", [
    "source_path_escape", "staging_path_escape", "staging_recheck_failed",
])
def test_escape_reasons_pass_with_a_well_formed_fatal_error(reason):
    """正向放行档：带上合规的四字段就必须通过。

    没有这一条，一个「凡带 stopped_reason 就拒」的实现也能让上一条绿。
    """
    m = _valid_manifest(stopped_reason=reason, fetch_fatal_error=_fatal())
    assert validate_manifest(m) == m


def test_fetch_fatal_error_needs_exactly_four_fields():
    """⭐ 四字段（R94-F2）：写侧曾写三字段、读侧要四字段 → 一个合规的写者
    产出的 manifest 会被读者判 FAIL_MANIFEST_INVALID，于是一次信任边界破坏
    被报成「manifest 畸形」，恢复指引整个走错。"""
    for drop in ("kind", "relative_path", "component", "errno"):
        bad = _fatal()
        del bad[drop]
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape", fetch_fatal_error=bad))


def test_fatal_kind_must_be_in_the_kind_enum():
    for bad in ("staging_recheck_failed", "max_bytes", "whatever", ""):
        f = _fatal()
        f["kind"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape", fetch_fatal_error=f))


def test_fatal_errno_must_be_eloop_or_enotdir():
    for bad in ("EACCES", "ENOENT", 20, ""):
        f = _fatal()
        f["errno"] = bad
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape", fetch_fatal_error=f))


def test_fatal_kind_is_decoupled_from_stopped_reason():
    """⭐⭐ O4-F3 的核心：`kind` 记首次逃逸类型，`stopped_reason` 记本次为何停。
    「保留 fatal + 换 stopped_reason」是复校失败那一档的**唯一**表达方式。

    判别力：把校验写成 `kind == stopped_reason`，本条必红——而那会让
    「修好后重跑、复校没过」这一档**结构上不可表达**，实施者无路可走。
    """
    m = _valid_manifest(stopped_reason="staging_recheck_failed",
                        fetch_fatal_error=_fatal(kind="staging_path_escape"))
    assert validate_manifest(m) == m


def test_fetch_fatal_error_without_stopped_reason_is_rejected():
    """反向配对：有 fatal 却没有 stopped_reason 说明写侧漏了一半。"""
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(fetch_fatal_error=_fatal()))


def test_max_bytes_with_a_retained_fatal_error_is_valid():
    """⭐ 正向档：Run1 撞 escape、Run2 触顶——**fatal 原样保留、escape 的
    stopped_reason 不得被覆盖**，本次触顶另记 stopped_reason_secondary（O4-F1）。

    这份形状必须**可读**，否则那条「不许被 max_bytes 洗白」的规则无处落地。
    """
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal(),
                        stopped_reason_secondary="max_bytes")
    assert validate_manifest(m) == m


def test_stopped_reason_secondary_only_allows_max_bytes():
    for bad in ("staging_path_escape", "", None, 1):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                stopped_reason="staging_path_escape",
                fetch_fatal_error=_fatal(),
                stopped_reason_secondary=bad))
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "stopped_reason or fatal or max_bytes" 2>&1 | tail -10
```

Expected: FAIL

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 常量区补：
FATAL_ERRNOS = frozenset({"ELOOP", "ENOTDIR"})
FATAL_FIELDS = ("kind", "relative_path", "component", "errno")


# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

def _validate_lifecycle(payload: dict) -> None:
    """`stopped_reason` / `fetch_fatal_error` / `stopped_reason_secondary` 的形状与配对。

    ⚠️ **一个信号只有同时进了「写侧规定」与「读侧校验」，它才真的存在**（R93-F1）：
    一次被源树逃逸终止的 fetch，其 manifest 仍带着此前成功拉到的 `pool_order` 与
    `files`，**形状上完全合法**——读侧不查这两个字段的实现会照常消费那批股，
    把一次信任边界破坏报成「候选不够」甚至走到 `SUCCESS`。

    ⚠️ **`kind` 与 `stopped_reason` 解耦**（O4-F3）：`kind` 记**首次逃逸的类型**，
    `stopped_reason` 记**本次为什么停**。复校失败那一档正是「保留 fatal +
    换 `stopped_reason`」——写成「`kind` 恒等于 `stopped_reason`」会让它
    **结构上不可表达**，实施者无路可走。

    ⚠️ 消费侧的 fail-closed 判据是「`fetch_fatal_error` 存在」，**不是**
    「`stopped_reason` 取值」（O4-F1）：前者是**粘性的信任状态**，后者是
    **易失的本次事件**，拿后者当安全判据必然被后续运行的 `max_bytes` 洗掉。
    本函数只管形状；分支由消费方（4c §4.2 步骤 ②）负责。
    """
    reason = payload.get("stopped_reason")
    fatal = payload.get("fetch_fatal_error")

    if reason is not None:
        _require(isinstance(reason, str) and reason in STOPPED_REASONS,
                 f"stopped_reason 必须是 {sorted(STOPPED_REASONS)} 之一，"
                 f"读到 {reason!r}")

    if fatal is not None:
        _require(reason is not None,
                 "有 fetch_fatal_error 却没有 stopped_reason——写侧只落了一半")
        _require(isinstance(fatal, dict), "fetch_fatal_error 必须是对象")
        for key in FATAL_FIELDS:
            _require(key in fatal,
                     f"fetch_fatal_error 缺 {key}（必须是 {list(FATAL_FIELDS)} "
                     "四字段——写侧三字段、读侧四字段会让一个合规的写者产出的 "
                     "manifest 被读者判非法，恢复指引整个走错）")
        _require(fatal["kind"] in FATAL_KINDS,
                 f"fetch_fatal_error.kind 必须是 {sorted(FATAL_KINDS)} 之一，"
                 f"读到 {fatal['kind']!r}")
        _require_nonempty_str(fatal["relative_path"], "fetch_fatal_error.relative_path")
        _require_nonempty_str(fatal["component"], "fetch_fatal_error.component")
        _require(fatal["errno"] in FATAL_ERRNOS,
                 f"fetch_fatal_error.errno 必须是 {sorted(FATAL_ERRNOS)} 之一，"
                 f"读到 {fatal['errno']!r}")

    if reason in REASONS_REQUIRING_FATAL:
        _require(fatal is not None,
                 f"stopped_reason = {reason!r} 必须同时带形状合规的 "
                 "fetch_fatal_error——它才是那个粘性的信任状态，"
                 "stopped_reason 会被后续运行的 max_bytes 洗掉")

    secondary = payload.get("stopped_reason_secondary")
    if secondary is not None:
        _require(secondary == "max_bytes",
                 "stopped_reason_secondary 只允许 'max_bytes'（纯人读附注："
                 "Run1 撞 escape、Run2 触顶时，escape 的 stopped_reason "
                 f"不得被覆盖），读到 {secondary!r}")


# validate_manifest 里，`_validate_staged_export_log(...)` 之后追加：
    _validate_lifecycle(payload)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 94 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M33 | `REASONS_REQUIRING_FATAL` 去掉 `staging_recheck_failed` | `..._require_a_fetch_fatal_error[staging_recheck_failed]` |
| M34 | 加一条 `fatal["kind"] == reason` | `test_fatal_kind_is_decoupled_from_stopped_reason` |
| M35 | 删 `reason is not None` 那条反向配对 | `..._without_stopped_reason_is_rejected` |
| M36 | `FATAL_FIELDS` 去掉 `errno` | `..._needs_exactly_four_fields[errno]` |
| M37 | `_validate_lifecycle` 整体删掉调用 | 上述否定档全红，**而 5 条正向档仍绿** ← 证明正向档不是靠这条判据活着 |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): stopped_reason / fetch_fatal_error 的形状与配对（R93-F1 + O4-F3 + R94-F2）

一个信号只有同时进了写侧规定与读侧校验才真的存在：被源树逃逸终止的 fetch，
其 manifest 仍带着此前成功拉到的 pool_order 与 files，形状上完全合法——
读侧不查它的实现会照常消费那批股，把信任边界破坏报成「候选不够」。

kind 与 stopped_reason 刻意解耦（O4-F3）：kind 记首次逃逸类型、stopped_reason
记本次为何停。写成「kind 恒等于 stopped_reason」会让「保留 fatal + 换
stopped_reason」这一档结构上不可表达，实施者无路可走。为此立了正向档。

四字段而非三字段（R94-F2）；staging_recheck_failed 也要带 fatal（O4-F3 补的
第四值，原文只写了两个 escape）。"
```

---

## Task 12: `source_verification` 三级与前置输入

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么读侧必须核实前置输入（R15-F2）**：R10-F3 解决的是「证据无处可记」——加了 `--snapshot-gmt-token` 与 `--confirm-no-export-window`。但**读侧从未被要求去核实它们真的在**。于是版本错位、半截写入或手工编辑出来的 manifest 里，一个**光秃秃的 `source_verification: "full"` 字符串**就足以让 pilot 判出 `ship_eligible: true`，而 spec 声称属于该级别必要条件的那份证据**整个缺席**。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

_GMT = "@GMT-2026.08.24-04.00.00"


def _evidence(level, *, n_pass, files_verified, agg, agree=None, mount=None):
    ev = {"level": level, "passes": [
        {"pass": i + 1, "files_verified": files_verified, "aggregate_sha256": agg,
         "completed_at": f"2026-08-24T12:0{i}:00+08:00"} for i in range(n_pass)]}
    if agree is not None:
        ev["passes_agree"] = agree
    if mount is not None:
        ev["mount_check"] = mount
    return ev


def _agg_of(m):
    return aggregate_sha256(manifest_members(m))


def test_source_verification_must_be_one_of_three_levels():
    for bad in ("FULL", "verified", "", None, 1):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_verification=bad))


def test_full_level_requires_operator_attestation():
    """⭐ R15-F2：一个光秃秃的 "full" 字符串不许换来出货级标签。"""
    m = _valid_manifest()
    del m["operator_attestation"]
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)


def test_full_level_attestation_must_be_true_and_timestamped():
    for bad in ({"no_export_window": False, "recorded_at": "t"},
                {"no_export_window": True},
                {"no_export_window": True, "recorded_at": ""},
                {"recorded_at": "t"}):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(operator_attestation=bad))


def test_snapshot_level_requires_a_well_formed_gmt_token():
    base = _valid_manifest()
    agg = _agg_of(base)
    n = len(base["files"]) + 1
    for token in (None, "", "@GMT-2026.8.24-4.0.0", "2026.08.24", "@GMT-xxxx"):
        snap = {"export_log_sha256": base["source_snapshot"]["export_log_sha256"],
                "universe": base["source_snapshot"]["universe"]}
        if token is not None:
            snap["gmt_token"] = token
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_snapshot=snap,
                source_verification="snapshot",
                source_verification_evidence=_evidence(
                    "snapshot", n_pass=1, files_verified=n, agg=agg,
                    mount={"gmt_token": _GMT, "verified_against_mount": True})))


def test_snapshot_level_passes_with_a_valid_token():
    """正向放行档。"""
    base = _valid_manifest()
    snap = dict(base["source_snapshot"], gmt_token=_GMT)
    m = _valid_manifest(
        source_snapshot=snap,
        source_verification="snapshot",
        source_verification_evidence=_evidence(
            "snapshot", n_pass=1, files_verified=len(base["files"]) + 1,
            agg=_agg_of(base),
            mount={"gmt_token": _GMT, "verified_against_mount": True}))
    assert validate_manifest(m) == m


def test_partial_level_needs_no_inputs_at_all():
    """正向放行档：partial 什么都不需要（它什么都没证明）。"""
    m = _valid_manifest(
        source_verification="partial",
        source_verification_evidence={"level": "partial", "passes": []})
    del m["operator_attestation"]
    assert validate_manifest(m) == m
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "source_verification or _level_" 2>&1 | tail -10
```

Expected: FAIL

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 常量区补：
_GMT_TOKEN_RE = re.compile(r"^@GMT-\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}$")


# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

def _validate_verification_inputs(payload: dict) -> str:
    """`source_verification` 的级别，以及该级别要求的**前置输入**（R15-F2）。

    ⚠️ **写侧记录与读侧核实是两件事**：R10-F3 加了 `--snapshot-gmt-token` 与
    `--confirm-no-export-window` 让证据有处可记，**却从没要求读侧去核实它们真的在**。
    于是版本错位、半截写入或手工编辑的 manifest 里，一个**光秃秃的
    `source_verification: "full"` 字符串**就足以让 pilot 判出 `ship_eligible: true`，
    而声称属于该级别必要条件的那份证据整个缺席。

    ⚠️ **本校验不授予任何出货资格**（R17-F2 / R18-F2）——它只是一致性检查。
    `ship_eligible ≡ (final_verdict == "SUCCESS")` 是派生量（R26-F1）。
    """
    level = payload["source_verification"]
    _require(isinstance(level, str) and level in VERIFICATION_LEVELS,
             f"source_verification 必须是 {list(VERIFICATION_LEVELS)} 之一，"
             f"读到 {level!r}")

    if level == "snapshot":
        token = payload["source_snapshot"].get("gmt_token")
        _require(isinstance(token, str) and _GMT_TOKEN_RE.match(token) is not None,
                 "source_verification = 'snapshot' 要求 source_snapshot.gmt_token "
                 f"形如 @GMT-YYYY.MM.DD-HH.MM.SS，读到 {token!r}")
    elif level == "full":
        att = payload.get("operator_attestation")
        _require(isinstance(att, dict),
                 "source_verification = 'full' 要求 operator_attestation —— "
                 "缺了它，一个光秃秃的 'full' 字符串就成了出货级标签，"
                 "而那份人工声明从未发生过")
        _require(att.get("no_export_window") is True,
                 "operator_attestation.no_export_window 必须为 true")
        _require_nonempty_str(att.get("recorded_at"),
                              "operator_attestation.recorded_at")
    return level


# validate_manifest 里，`_validate_lifecycle(payload)` 之后追加：
    level = _validate_verification_inputs(payload)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 105 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M38 | `att.get("no_export_window") is True` → `in att` | `..._must_be_true_and_timestamped`（False 那档） |
| M39 | `_GMT_TOKEN_RE` 改成 `^@GMT-` 前缀匹配 | `..._requires_a_well_formed_gmt_token`（`@GMT-xxxx` 档） |
| M40 | `level == "full"` 那支整体删掉 | `..._requires_operator_attestation` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): source_verification 三级与其前置输入（R15-F2）

写侧记录与读侧核实是两件事：R10-F3 让证据有处可记，却从没要求读侧核实它们
真的在。于是一个光秃秃的 \"full\" 字符串就足以让 pilot 判出 ship_eligible，
而那份人工声明从未发生过。

三级各配正向放行档（partial 什么都不需要，因为它什么都没证明）。
本校验不授予任何出货资格（R17-F2/R18-F2），只是一致性检查。"
```

---

## Task 13: `source_verification_evidence` 校验过程存根

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么「输入」不够、必须要过程存根（R16-F1）**：`operator_attestation` 只证明操作者**按下了那个开关**，`gmt_token` 只证明**传了一个形状对的字符串**——两者都**不证明那两趟全量哈希校验真的跑过、且结果一致**。

**⚠️ 但存根本身是自指的（R17-F2）**：本校验拿 `aggregate_sha256` 与「manifest **自己记录的**逐文件 sha256」比对，因此它证明的只是**这份 manifest 内部自洽**，**不证明校验进程真的去读过 SMB 源**。故它是**一致性检查**，不单独授予任何出货资格。

**⚠️ `partial` 级的 manifest 必须永远可读（O4-F2）**：存根只能由**批后**的收尾复校产出，而首次 fetch 跑到第 200 只股被 SIGKILL 时，磁盘上那份 manifest 有几百条 `files`、**没有存根**。若对 `partial` 也强制趟数/聚合一致性，读侧会 fail-closed 拒绝 → 而崩溃恢复明写在「读完并校验 manifest 之后」→ **`.inflight.json` 回滚、幂等四象限、按股事务一条都执行不到**，代价是一棵 2 GiB 的 staging。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_evidence_level_must_match_source_verification():
    base = _valid_manifest()
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_verification_evidence=_evidence(
                "snapshot", n_pass=2, files_verified=len(base["files"]) + 1,
                agg=_agg_of(base), agree=True)))


def test_full_level_requires_exactly_two_passes():
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    for k in (0, 1, 3):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_verification_evidence=_evidence(
                    "full", n_pass=k, files_verified=n, agg=agg, agree=True)))


def test_full_level_requires_passes_agree_true():
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    for agree in (False, None, "true"):
        ev = _evidence("full", n_pass=2, files_verified=n, agg=agg)
        if agree is not None:
            ev["passes_agree"] = agree
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(source_verification_evidence=ev))


def test_full_level_rejects_two_passes_with_different_aggregates():
    """⭐ 只有本条够得到：两趟都在、passes_agree 写着 true，但两趟的聚合
    摘要**不等** —— 即 passes_agree 在撒谎。

    判别力：只查 passes_agree 布尔值而不比两趟聚合的实现会放行本档。
    """
    base = _valid_manifest()
    n, agg = len(base["files"]) + 1, _agg_of(base)
    ev = _evidence("full", n_pass=2, files_verified=n, agg=agg, agree=True)
    ev["passes"][1]["aggregate_sha256"] = _sha("different")
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(source_verification_evidence=ev))


def test_snapshot_level_requires_exactly_one_pass_and_a_verified_mount_check():
    base = _valid_manifest()
    snap = dict(base["source_snapshot"], gmt_token=_GMT)
    n, agg = len(base["files"]) + 1, _agg_of(base)
    ok_mount = {"gmt_token": _GMT, "verified_against_mount": True}
    for ev in (
        _evidence("snapshot", n_pass=2, files_verified=n, agg=agg, mount=ok_mount),
        _evidence("snapshot", n_pass=1, files_verified=n, agg=agg),           # 缺 mount_check
        _evidence("snapshot", n_pass=1, files_verified=n, agg=agg,
                  mount={"gmt_token": _GMT, "verified_against_mount": False}),
    ):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_snapshot=snap, source_verification="snapshot",
                source_verification_evidence=ev))


def test_files_verified_must_equal_len_files_plus_one():
    """⭐ O4-F13：是 2N+1 不是 2N。

    原文「已成功拷贝的文件数」的自然读法是 2N，与 O2-F12 写死的成员集合
    （files 每条 + staged_export_log 一条）互斥 —— **两边照哪个实现都会让
    另一边全红**。

    判别力：把判据写成 len(files)，本条必红。
    """
    base = _valid_manifest()
    agg = _agg_of(base)
    for wrong in (len(base["files"]), len(base["files"]) + 2, 0):
        with pytest.raises(ManifestInvalidError):
            validate_manifest(_valid_manifest(
                source_verification_evidence=_evidence(
                    "full", n_pass=2, files_verified=wrong, agg=agg, agree=True)))


def test_aggregate_must_match_recomputation_from_manifests_own_records():
    """⭐ 存根里的聚合必须与「拿 manifest 自己记的逐文件 sha256 重算」逐字相符。

    判别力：删掉重算比对，一份自填聚合的 manifest 就静默通过。
    （它挡的是截断/版本错位/字段缺失；**挡不住**手工伪造——那由 pilot 自己
    读源来挣，R17-F2。）
    """
    base = _valid_manifest()
    n = len(base["files"]) + 1
    with pytest.raises(ManifestInvalidError):
        validate_manifest(_valid_manifest(
            source_verification_evidence=_evidence(
                "full", n_pass=2, files_verified=n, agg=_sha("forged"), agree=True)))


def test_partial_evidence_is_always_readable_even_mid_crash():
    """⭐⭐ O4-F2：partial 级的 manifest **永远可读**。

    模拟「首次 fetch 拷到一半被 SIGKILL」：几百条 files 都在、**没有任何存根**
    （存根只能由批后的收尾复校产出）。若对 partial 也强制趟数/聚合一致性，
    读侧会 fail-closed 拒绝 → 而崩溃恢复明写在「读完并校验 manifest 之后」→
    .inflight.json 回滚、幂等四象限、按股事务**一条都执行不到**，
    代价是一棵 2 GiB 的 staging。

    判别力：把 partial 也纳入趟数/聚合校验，本条必红。
    """
    m = _valid_manifest(
        source_verification="partial",
        source_verification_evidence={"level": "partial", "passes": []})
    del m["operator_attestation"]
    assert validate_manifest(m) == m


def test_partial_evidence_still_needs_the_two_structural_keys():
    """partial 宽容的是**一致性**，不是**形状**：level 与 passes 仍必须在。"""
    for bad in ({}, {"level": "partial"}, {"passes": []},
                {"level": "full", "passes": []}):
        m = _valid_manifest(source_verification="partial",
                            source_verification_evidence=bad)
        m.pop("operator_attestation", None)
        with pytest.raises(ManifestInvalidError):
            validate_manifest(m)


def test_partial_with_nonempty_passes_is_rejected():
    """per-stock 提交时的取值写死为 passes: []（O4-F2）。带着趟数的 partial
    说明写侧没按写死的取值来。"""
    base = _valid_manifest()
    m = _valid_manifest(
        source_verification="partial",
        source_verification_evidence=_evidence(
            "partial", n_pass=1, files_verified=len(base["files"]) + 1,
            agg=_agg_of(base)))
    m.pop("operator_attestation", None)
    with pytest.raises(ManifestInvalidError):
        validate_manifest(m)
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "evidence or passes or files_verified or aggregate_must" 2>&1 | tail -10
```

Expected: FAIL

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py（validate_manifest 之前）

_PASSES_REQUIRED = {"snapshot": 1, "full": 2}


def _validate_verification_evidence(payload: dict, level: str) -> None:
    """校验过程存根（R16-F1）——证明校验**真的跑过**。

    ⚠️ **存根本身是自指的，不足以支撑出货资格**（R17-F2）：本函数拿
    `aggregate_sha256` 与「manifest **自己记录的**逐文件 sha256」比对，
    因此它证明的只是**这份 manifest 内部自洽**，**不证明校验进程真的读过
    SMB 源**——手工编辑者完全可以自填哈希、自算聚合、自称 `full`。
    故这套校验是**一致性检查**：能挡住截断、版本错位、字段缺失，
    **不再单独授予任何出货资格**。

    ⚠️ **`partial` 级永远可读**（O4-F2）：趟数 / `passes_agree` /
    `aggregate_sha256` / `files_verified` 的一致性校验**只适用于
    `snapshot` / `full` 两级**。首次 fetch 跑到第 200 只股被 SIGKILL 时，
    磁盘上那份 manifest 有几百条 `files`、没有存根（存根只能由**批后**的
    收尾复校产出）；对 `partial` 也强制一致性会让读侧 fail-closed 拒绝，
    而崩溃恢复明写在「读完并校验 manifest **之后**」——于是 `.inflight.json`
    回滚、幂等四象限、按股事务**一条都执行不到**。
    """
    ev = payload["source_verification_evidence"]
    _require(isinstance(ev, dict), "source_verification_evidence 必须是对象")
    _require("level" in ev and "passes" in ev,
             "source_verification_evidence 必须有 level 与 passes")
    _require(ev["level"] == level,
             f"source_verification_evidence.level = {ev['level']!r} 与 "
             f"source_verification = {level!r} 不一致")
    _require(isinstance(ev["passes"], list),
             "source_verification_evidence.passes 必须是列表")

    if level == "partial":
        # 形状仍要，一致性不要（O4-F2）。
        _require(ev["passes"] == [],
                 "partial 级的存根必须是 passes: [] —— per-stock 提交时这两个"
                 "字段的取值是写死的，带着趟数说明写侧没按写死的取值来")
        return

    want = _PASSES_REQUIRED[level]
    _require(len(ev["passes"]) == want,
             f"{level} 级要求恰好 {want} 趟复校，读到 {len(ev['passes'])} 趟")

    expect_n = len(payload["files"]) + 1          # O4-F13：2N+1，含 staged_export_log
    expect_agg = aggregate_sha256(manifest_members(payload))
    aggs: list[str] = []
    for i, p in enumerate(ev["passes"]):
        where = f"source_verification_evidence.passes[{i}]"
        _require(isinstance(p, dict), f"{where} 必须是对象")
        for key in ("pass", "files_verified", "aggregate_sha256", "completed_at"):
            _require(key in p, f"{where} 缺 {key}")
        _require(p["files_verified"] == expect_n,
                 f"{where}.files_verified = {p['files_verified']}，"
                 f"必须等于 len(files) + 1 = {expect_n}"
                 "（成员集合含那一份 staged export_log，故恒为奇数 2N+1）")
        _require_sha256(p["aggregate_sha256"], f"{where}.aggregate_sha256")
        _require(p["aggregate_sha256"] == expect_agg,
                 f"{where}.aggregate_sha256 与「拿 manifest 自己记的逐文件 "
                 "sha256 重算出的聚合」不符——这份存根与它所在的 manifest 对不上")
        _require_nonempty_str(p["completed_at"], f"{where}.completed_at")
        aggs.append(p["aggregate_sha256"])

    if level == "snapshot":
        mc = ev.get("mount_check")
        _require(isinstance(mc, dict), "snapshot 级要求 mount_check")
        _require(mc.get("verified_against_mount") is True,
                 "snapshot 级要求 mount_check.verified_against_mount 为 true"
                 "——否则那个 token 只是一个形状对的字符串，没跟真实挂载核过")
    else:                                          # full
        _require(ev.get("passes_agree") is True,
                 "full 级要求 passes_agree 为 true")
        _require(aggs[0] == aggs[1],
                 "full 级的两趟聚合摘要不相等，而 passes_agree 写着 true"
                 "——存根自相矛盾")


# validate_manifest 里，`level = _validate_verification_inputs(payload)` 之后追加：
    _validate_verification_evidence(payload, level)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 122 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M41 | `if level == "partial": ... return` 那支删掉 | `..._always_readable_even_mid_crash` |
| M42 | `expect_n = len(payload["files"]) + 1` → `len(payload["files"])` | `..._must_equal_len_files_plus_one` |
| M43 | 删 `p["aggregate_sha256"] == expect_agg` | `..._must_match_recomputation...` |
| M44 | 删 `aggs[0] == aggs[1]` | `..._rejects_two_passes_with_different_aggregates` |
| M45 | `mc.get("verified_against_mount") is True` → `is not None` | `..._a_verified_mount_check`（False 那档） |
| M46 | `ev["passes"] == []` → `isinstance(ev["passes"], list)` | `..._partial_with_nonempty_passes_is_rejected` |

> ⚠️ **M43 与 M44 会互相掩盖**：删 M43 时 `..._different_aggregates` 仍红（因为
> 第二趟的伪造聚合也过不了重算比对）。故 M44 必须**在 M43 已复原的前提下单独跑**，
> 且若两条都删仍有档红，须补一条**组合变异**档。

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): source_verification_evidence 存根（R16-F1 + R17-F2 + O4-F2 + O4-F13）

输入只证明「操作者按了开关」，存根才证明「校验真的跑过且一致」。但存根本身
是自指的：它拿 manifest 自己记的逐文件 sha256 重算，只证明内部自洽，不证明
进程真读过 SMB 源——故降级为一致性检查，不单独授予出货资格。

files_verified 是 2N+1 不是 2N（O4-F13）：成员集合含那份 staged export_log，
两边照哪个实现都会让另一边全红。

⭐ partial 级永远可读（O4-F2）：存根只能由批后的收尾复校产出，而首次 fetch
拷到一半被 SIGKILL 时磁盘上有几百条 files、没有存根。对 partial 强制一致性
会让读侧拒绝，而崩溃恢复排在「读完并校验 manifest 之后」——回滚、幂等四象限、
按股事务一条都执行不到，代价是一棵 2 GiB 的 staging。"
```

---

## Task 14: 未知顶层键原样保留

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**为什么（O4-F10）**：旧工具消费新版 manifest 后回写会把不认识的字段丢掉 → 再用新工具打开时缺必需字段 → **一棵 400 只股的 staging 被一次「用错版本跑补拉」永久毁掉**。本片的 `failures` / `batches` / `inflight_rollbacks` / `quota` 等由 S3/S4 定义的可选键，正是靠这条通道流转。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

def test_unknown_top_level_keys_are_preserved_not_dropped():
    """⭐ O4-F10：读侧不认识的顶层键必须原样保留。

    这里用的正是 S3/S4 将要定义、而本片**不认识**的那些键——它们靠这条
    通道流转，因此**不需要 bump manifest_version**。

    判别力：把 validate_manifest 写成「只返回认识的键」（白名单投影），
    本条必红。
    """
    extras = {
        "failures": [{"stock_code": "600004.SH", "market": "SH",
                      "universe_idx": 1, "reason": "fetch_missing_file",
                      "attempts": 1}],
        "batches": [{"seed": "s-2026-08-24", "quota": {"SH": 120},
                     "added": ["600000.SH"]}],
        "inflight_rollbacks": {"1": 2},
        "quota": {"SH": 120, "SZ": 160, "BJ": 120},
        "committed_bytes": 4600000,
        "一个将来才会有的字段": {"任意": "结构"},
    }
    m = _valid_manifest(**extras)
    out = validate_manifest(m)
    for k, v in extras.items():
        assert out[k] == v, f"未知顶层键 {k!r} 被丢掉或改动了"


def test_validate_returns_the_same_object_not_a_copy():
    """返回的就是传进去的那个对象——避免调用方以为拿到了净化过的副本，
    转头把原对象写回磁盘。"""
    m = _valid_manifest()
    assert validate_manifest(m) is m
```

- [ ] **Step 2: 跑测试确认它红**

先确认它**当前是绿的**（实现从一开始就是 `return payload`），然后用变异证明这条测试**有判别力**：

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "unknown_top_level or same_object" 2>&1 | tail -5
```

Expected: PASS（2 passed）

> ⚠️ **这是本 plan 里唯一一条「测试一开始就绿」的任务**。TDD 的红→绿在这里
> 换成**变异**证伪：把实现改成白名单投影，测试必须变红。**不许跳过 Step 3**
> ——「一开始就绿的守卫等于给实施者发放宽许可证」。

- [ ] **Step 3: 变异证明这条测试有判别力（本任务的红→绿等价物，控制者亲跑）**

```bash
cd backend && find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
cp qmt_manifest.py /tmp/qmt_manifest.bak
# 变异：把 validate_manifest 的返回改成白名单投影
python - <<'PY'
import pathlib
p = pathlib.Path("qmt_manifest.py")
s = p.read_text(encoding="utf-8")
assert s.count("    return payload\n") == 1
p.write_text(s.replace("    return payload\n",
                       "    return {k: payload[k] for k in REQUIRED_KEYS}\n"), encoding="utf-8")
PY
find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "unknown_top_level or same_object" 2>&1 | tail -5
# Expected: 2 failed  ← 证明这两条真的在测「保留」而不是恒真
cp /tmp/qmt_manifest.bak qmt_manifest.py       # 复原用 cp，绝不用 git checkout
find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null
```

- [ ] **Step 4: 在实现里把这条纪律写成承重注释**

```python
# validate_manifest 的最后一行改为：

    # ⚠️ **原样返回，绝不做白名单投影**（O4-F10）：读到不认识的顶层键必须原样
    # 保留回写。旧工具消费新版 manifest 后若把不认识的字段丢掉 → 再用新工具
    # 打开时缺必需字段 → **一棵 400 只股的 staging 被一次「用错版本跑补拉」
    # 永久毁掉**。S3/S4 的 failures / batches / inflight_rollbacks / quota
    # 正是靠这条通道流转，因此它们**不需要 bump manifest_version**。
    return payload
```

- [ ] **Step 5: 跑全量确认仍绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 124 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): 未知顶层键原样保留（O4-F10）

旧工具消费新版 manifest 后回写若丢掉不认识的字段 → 再用新工具打开时缺必需
字段 → 一棵 400 只股的 staging 被一次「用错版本跑补拉」永久毁掉。

S3/S4 的 failures / batches / inflight_rollbacks / quota 正是靠这条通道流转，
因此它们不需要 bump manifest_version。

⚠️ 这两条测试一开始就是绿的，故用变异（把返回改成白名单投影）证明它们有
判别力——一开始就绿的守卫等于给实施者发放宽许可证。"
```

---

# 验收清单（非程序员可自行执行）

> 三段式：**动作 / 期望 / 通过判定**。每条一行命令，**不要整块粘贴**。
> 环境：Python 解释器在**主仓**的 `.venv` 里，worktree 里没有。先执行这一条把它记下来：
>
> ```
> export PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
> ```
>
> 再进 worktree 的 backend 目录：
>
> ```
> cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s2/backend"
> ```

### A1 · 确认你在对的地方

**动作**

```
git branch --show-current && git rev-parse --short HEAD && pwd
```

**期望**：三行依次是 `feat/qmt-4b-s2-manifest`、一个 7 位提交号、以 `.dev/worktree/qmt-4b-s2/backend` 结尾的路径。

**通过判定**：分支名完全一致 → 通过；不一致 → 不通过（说明开了别的窗口或切错分支，**先别继续**）。

---

### A2 · 全部测试通过，且一条都没被跳过

> 「跳过」= 测试没真跑，只是被标成「不算数」。本仓的自动检查把**任何跳过**都判失败，
> 因为在开发者的 Mac 上跳过的那条，正是在服务器（Linux）上会出问题的那条。

**动作**

```
$PY -m pytest tests/ -q --junitxml=/tmp/s2-accept.xml
```

**期望**：最后一行形如 `NNN passed in XX.XXs`，**没有** `failed`、**没有** `skipped`、**没有** `error`。

**通过判定**：出现 `passed`、且**没有** `failed` / `skipped` / `error` 字样 → 通过。

> 数字本身只作参考：本片开工前的基线是 **937**，做完后应当明显更多（新增约 160 条）。
> 若数字**比 937 还少**，说明有测试没被收集到——那是不通过，请把完整输出贴出来。

---

### A3 · 用机器再数一遍跳过的条数（不看结论字样，看执行量）

> 为什么要多这一步：终端最后一行是**结论**，而结论字样可能与真实执行量不符。
> 本仓栽过「显示 `TEST SUCCEEDED` 而实际跑了 0 个测试」。这一步直接数**数字**。

**动作**

```
$PY -c "import xml.etree.ElementTree as E;r=E.parse('/tmp/s2-accept.xml').getroot();f=lambda k:sum(int(s.get(k,0)) for s in r.iter('testsuite'));print('总数',f('tests'),'跳过',f('skipped'),'失败',f('failures'),'错误',f('errors'))"
```

**期望**：`跳过 0 失败 0 错误 0`，且`总数`与 A2 的数字一致。

**通过判定**：三个 0 全中且总数一致 → 通过；任一不为 0 → 不通过。

---

### A4 · 模拟服务器环境（Linux）再跑一遍

> 本片用到一个**只有 Mac 才有**的「更用力刷硬盘」的功能。服务器上没有它。
> 这一步把那个功能藏起来，看代码会不会崩。**上一片（S1）就是栽在这里**：
> 本地 932 个测试全过，服务器上 2 个失败 + 1 个跳过。

**动作**（三行，逐行执行）

```
mkdir -p /tmp/nofs
```

```
printf 'import fcntl\ndef pytest_configure(config):\n    if hasattr(fcntl, "F_FULLFSYNC"):\n        del fcntl.F_FULLFSYNC\n' > /tmp/nofs/nofullfsync.py
```

```
PYTHONPATH=/tmp/nofs $PY -m pytest tests/ -q -p nofullfsync
```

**期望**：与 A2 相同的通过数，**没有** `failed` / `skipped` / `error`。

**通过判定**：通过数与 A2 一致且无其它字样 → 通过。数字变小 → 不通过（说明有测试在服务器上跑不了）。

---

### A5 · 亲眼看一份「坏账本」被挡住、一份「好账本」被放行

> 这一步是本片的**本质**：账本坏了必须当场拒绝，而不是「尽力读一读」。
> 「尽力读一读」的后果是把**账本损坏**伪装成「候选股票就这么少」，
> 最后产出一份**会撒谎的报告**。

**动作**

```
$PY -c "
import sys; sys.path.insert(0,'tests')
from test_qmt_manifest import _valid_manifest, _recompute_evidence
from qmt_manifest import validate_manifest, ManifestInvalidError, ManifestVersionError
m = _valid_manifest(); validate_manifest(m); print('① 好账本：放行 ✅')
b = _valid_manifest(); del b['seed']
try: validate_manifest(b); print('② 缺字段：没拦住 ❌')
except ManifestInvalidError as e: print('② 缺字段：拦住了 ✅ ——', str(e)[:40])
c = _valid_manifest(); c['files'][0]['relative_path']='../跑到外面.csv'; _recompute_evidence(c)
try: validate_manifest(c); print('③ 路径跑到外面：没拦住 ❌')
except ManifestInvalidError as e: print('③ 路径跑到外面：拦住了 ✅ ——', str(e)[:40])
d = _valid_manifest(manifest_version=99)
try: validate_manifest(d); print('④ 版本更高：没拦住 ❌')
except ManifestVersionError as e: print('④ 版本更高：拦住了 ✅ ——', e.guidance[:40])
"
```

**期望**：四行，全部以 `✅` 结尾；第 ④ 行的提示里出现「更新版本」字样（**不是**「账本坏了」）。

**通过判定**：四个 ✅ 全中 → 通过。任一出现 ❌ → 不通过。

> 第 ④ 行为什么重要：一棵已经拉了几百只股票（约 2 GB）的目录，如果「版本对不上」
> 和「账本坏了」报同一句话，你根本不知道该重新拉一遍还是该换个版本的工具。

---

### A7 · 确认 spec 的四处更正真的写进去了

**动作**

```
git log --oneline -1 -- ../../../docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md
```

```
grep -c 'S2-F1\|S2-F2\|S2-F3\|S2-F4' ../../../docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md
```

**期望**：第一条显示一次 `docs(4b): S2 实施前核实` 的提交；第二条输出的数字 ≥ 10。

**通过判定**：两条都满足 → 通过。

---

# Self-Review（写完 plan 后逐项自查）

## 1. Spec 覆盖 —— §4.5 读侧校验清单逐条对到任务

| spec 判据 | 任务 |
|---|---|
| 必需键齐全（外延写死） | Task 5 |
| `seed` 非空 | Task 5 |
| `source_snapshot.universe` 三层皆为 list | Task 6 |
| `source_mount` 三子键形状（S2-F2 更正后） | Task 6 |
| 未知顶层键原样保留（O4-F10） | Task 14 |
| `pool_order` 三层 list + 元素为 `{code, universe_idx}`（R13-F1） | Task 7 |
| `code` 正则 + 后缀与所在层一致 | Task 7 |
| 层内 `code` 与 `universe_idx` 各自唯一 | Task 7 |
| `universe_idx` 界内 + 交叉核对锚点 | Task 8 |
| `cursor[market]` 整数且在闭区间内 | Task 8 |
| `files` 逐项合规（R21-F3） | Task 9 |
| `staged_export_log` 自洽（R38-F1） | Task 10 |
| `manifest_version` 三档（O2-F8 + O4-F10） | Task 3 |
| `stopped_reason` 闭合枚举 + `fetch_fatal_error` 四字段配对（R93-F1 + R94-F2 + O4-F3） | Task 11 |
| `source_verification` 三级与**前置输入**（R15-F2） | Task 12 |
| `source_verification_evidence` 存根（R16-F1 + O4-F2 + O4-F13） | Task 13 |
| 聚合指纹算法（S2-F4 补定义） | Task 4 |
| 读侧路径判据所需的**原语**（`split_relative_components`） | Task 1 |

**本片刻意不覆盖、留给 S2b 的（逐条登记，防止「声称覆盖了而实际没做」）**：

| spec 判据 | 去处 |
|---|---|
| manifest 的实际落盘（`atomic_write_json` + `F_FULLFSYNC` + 目录耐久，R45-F2 + O4-F11） | S2b Task 15/16 |
| 每股提交一次（R37-F1）且**不动**生命周期字段（§9-3s） | S2b Task 16 |
| 收尾提交的清除/保留规则（R95-F2 + O2-F7 + O4-F1 + P2-F3） | S2b Task 17/18 |
| 引导态：manifest 不存在 ≠ 畸形（R60-F3） | S2b Task 15 |

> ⚠️ **S2a 交付的 `stopped_reason` / `fetch_fatal_error` 只是它们的「形状校验」**（Task 11），
> **不含**「谁能改、什么时候清」那套生命周期规则。这两件事必须分开说：
> 一个 manifest 形状合规，**不等于**那个字段的写入权限被约束住了。

**两片都不覆盖（按切片边界，逐条登记）**：`.staging.lock` 取锁时机（S1 已交付原语，时机在 S5）、`.inflight.json` 崩溃恢复（S4）、四象限幂等（S4）、`--max-bytes` 流式扣减（S4）、七条源边界闸（S5）、预筛与分层洗牌（S3）。

## 2. Placeholder 扫描

无 `TBD` / `TODO` / 「稍后补」/「适当的错误处理」/「类似 Task N」。每个代码步骤都带可直接粘贴的代码，每个测试步骤都带完整测试体。

## 3. 类型一致性（自查发现并已修的两条）

- ❌→✅ **`_fcntl_t1` 跨文件引用**（原 Task 16/18，现已随 S2b 拆出）：那两个测试在 `test_qmt_manifest.py` 里，却用了 `test_qmt_fsroot.py` 的别名 `_fcntl_t1`。已改为在 `test_qmt_manifest.py` 顶部 `import fcntl` 并直接用 `fcntl`（S2a 的 Task 2 已把 `import fcntl` 写进 import 区，S2b 直接用）；Task 1 那 14 处别名保留不动（它们在正确的文件里）。
- ❌→✅ **存根未重算导致的变异假阴性**：改动 `files` / `staged_export_log` 的 10 处否定档，若不重算 `source_verification_evidence`，聚合判据会**掩盖**被测判据——否定档照样红，但红的是聚合，于是把被测判据变异掉后测试**仍然绿**，变异表显示「零红」被误读成「测试没判别力」。已加 `_recompute_evidence(m)` 帮手并在 10 处调用，另给 M30 / M32 补了归因提醒。

- ❌→✅ **上游判据掩盖下游档（第二轮自查，Task 6）**：三条改 `source_snapshot` 的否定档只改了
  一处 sha / 留着默认 pool_order，于是「两处 sha 必须相等」与「pool_order 交叉核对」会**顶上来**，
  把被测判据变异掉后测试仍绿。已加 `_with_universe` 帮手、把 sha 格式档改成两处同时设坏值、
  并给三条档清空池与清单。
- ✅ **等价变异已识别并登记（Task 7）**：`pool_order` 的「后缀与层一致」与「交叉核对」
  **结构上重叠**（已实测），造不出专属档。M19 登记为等价变异、测试 docstring 写明「变异后
  仍绿是预期」，并在 `source_snapshot` 那一侧补了**真有**专属档的 `test_universe_code_suffix...`。

其余符号：`_valid_manifest` / `_sha` / `_file_rec` / `_recompute_evidence` / `_with_universe`（Task 5）→ 后续全用；`_fatal`（Task 11）→ 本片 Task 11 内用，**并由 S2b 继续复用**；`_evidence` / `_agg_of` / `_GMT`（Task 12）→ Task 13 用。**定义均早于首次使用。**

> ⚠️ **交给 S2b 的接口面**（S2b 的 plan 假定它们已存在，实施 S2a 时不得改名）：
> 常量 `MANIFEST_NAME` / `LIFECYCLE_KEYS` / `FATAL_KINDS` / `FATAL_ERRNOS`、
> 函数 `validate_manifest` / `aggregate_sha256` / `manifest_members`、
> 异常 `ManifestInvalidError` / `ManifestVersionError`、
> 测试帮手 `_valid_manifest` / `_sha` / `_file_rec` / `_fatal` / `_recompute_evidence`。

---

# 交付诚实口径

**做完 S2a 的正确表述**：manifest 的**结构与读侧校验**建好了，是**纯函数**（连磁盘都还没碰）；落盘与生命周期在 S2b；`qmt_fetch.py` 仍然**零实现**。

**⛔ 禁止的表述**（无论听起来多顺）：

- 「4b 完成」
- 「SMB 拉取做好了」
- 「真实数据接入完成」
- 「pilot 已完成」
- 「100 股已出货」
- 「验证通过即可」/「看起来正常」/「应该没问题」

**本片之后还剩什么**：**S2b**（读回 + 两个提交入口 + 生命周期决策表）、S3（预筛 + 分层储备池）、S4（拷贝引擎）、S5（源边界闸 + 命令行），然后才是 4c（编排 / 报告 / 出货凭据）。
