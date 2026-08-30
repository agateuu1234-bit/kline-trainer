# QMT 4b 切片 **S2b**：manifest 落盘与生命周期 —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 S2a 建好的 manifest 结构落到磁盘：逐段无跟随读回、**两个权限不等价的提交入口**（per-stock / 收尾），以及 `stopped_reason` / `fetch_fatal_error` 的生命周期决策表。

**⚠️ 前置：S2a 必须已合进 main。**本片从**新的 main** 切分支，**不叠 PR**（user 2026-08-25 拍板，避开「改 base 静默丢门」与「前片 squash 后必然冲突」两个已踩过的坑）。开工前先确认 `backend/qmt_manifest.py` 里已有 `validate_manifest` / `aggregate_sha256` / `LIFECYCLE_KEYS`。⚠️ **原文还写着「且 `qmt_fsroot.py` 已公开 `atomic_write_json`」——那是错的**：公开它正是本片 Task 15 的 **Step 0**（S2a 里它零使用者，故没做）。2026-08-30 实施前核实并订正。

**Architecture:** 落盘复用 S1 `qmt_fsroot` 的逐段无跟随 + 原子写 + 耐久提交（manifest 提交走 `F_FULLFSYNC`）。生命周期规则做成**纯函数决策表**；两个提交入口对它的权限**结构上不等价**——per-stock 提交在写入路径上根本够不到那三个字段。

**Tech Stack:** Python 3.11+、标准库、pytest。**零新依赖**。

**Spec:** `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.5（含文末「S2 实施轮」的**全部** `S2-F*` 更正——写本计划时是四条，S2a 期间加到九条，S2b 期间加到十一条。**别写死条数**，写死的计数本身就是腐烂源；核对办法见验收清单 A7）。

> ⚠️ **对 S2b 有直接约束的三条**：**S2-F6**（读侧路径判据用**分量规则**而非 `resolve()`；§4.5:430 的 `.inflight.json` 形状校验仍写着 `resolve()`，那是 **S4** 范围但已预先登记——照原文实现会放行一条破坏性恢复路径删到边界之外）、**S2-F10**（读回口必须对**磁盘对象的类型**安全）、**S2-F11**（决策表里「source escape + 复校失败」那一格 spec 从未定义）。

## Global Constraints

与 S2a 逐字相同，此处不复述：见 `2026-08-25-qmt-4b-s2a-validation.md` 的「Global Constraints」一节（CI 是 Linux 且零容忍 skip、测试零外部依赖、变异必须禁字节码缓存且由控制者亲跑、写侧读侧逐字配对纪律）。

### ⚠️ 关于各步 `Expected: NNN passed` 里的数字

**绝对条数是估算，不是判据。**判据只有三条：没有 `failed`、没有 `error`、没有 `skipped`，且条数只增不减。

### ⭐ 从 S2a 继承的一条做法：**机械化全量变异 sweep**（务必沿用）

S2a 的教训：人工挑条目的「全量重跑」**漏了三条**——三条都是同一形态（一条判据交付时
有专属档，后面新加的判据把它的守护职责接管了，于是破坏原判据再也测不出来）。
整支评审用**机械化**的办法一次抓齐，控制者复跑确认。

**做法**：逐条把模块里每个 `_require*` 调用的第一个实参改成恒真值，各跑一遍测试，
记录红/绿。**变异后仍绿 = 那条判据没有任何测试在隔离地守它。**
要点：①改前用 `ast.parse` 自证语法合法（否则红的是语法错误，什么都没证明）；
②每次清 `__pycache__`（`PYTHONDONTWRITEBYTECODE=1` 也要带）；③用 `cp` 复原，**绝不 `git checkout`**。

S2a 的结果：82 条守卫、29 条无隔离覆盖——其中绝大多数是**类型/存在性守卫被邻居兜底**
（该登记而非该修），另有 3 条是已登记的等价变异/恒真断言。
**S2b 完成后请对新增判据跑同一个 sweep**，并把「仍绿」的逐条分类登记。

⚠️ **「每条判据都要有专属档」这条纪律，有时结构上做不到**（S2a 有一条经推演证明
无法隔离：要隔离它需同时满足两个互相矛盾的条件）。那时正确做法是**如实登记退化**，
**不是造一条看起来能红的假档**。

### 本片明确不做

预筛与分层洗牌（S3）、拷贝与崩溃恢复与 `--max-bytes`（S4）、七条源边界闸与命令行（S5）、`.staging.lock` 的取锁时机（S5）、`qmt_pilot` 与 `--output` 一族（4c）。

---


## 实施轮偏离登记（2026-08-30，实施者核实后逐条订正）

> **下面各 Task 的代码块是写计划时的草案，不是最终实现。**九处偏离全部朝
> 「坏状态不可表达」方向，每条各配专属档并由控制者亲手做过变异验证。
> 与本文件代码块 diff 不上的地方，以**仓库代码 + 本表**为准。

| # | 偏离处 | 计划原文的问题 | 处置 |
|---|---|---|---|
| D1 | Task 15 `read_manifest` 的打开方式 | 用裸 `open_under(flags=O_RDONLY)`。**实测**：manifest 被换成 FIFO 时 `open` 一直阻塞——变异后那条测试不是变红而是 15 秒被闹钟杀掉、日志 0 字节、退出码 142；被换成目录时 `os.read` 抛原始 `IsADirectoryError` | 改经 S1 的 `open_regular_probe`（`O_NONBLOCK` + `S_ISREG`）。已登记为 spec **S2-F10** |
| D2 | Task 15 的大小上限 | 只查 `st_size` 早拒，且自称「与 S1 给归属标记设上限同源」——而 S1 **恰恰明确未采纳** `st_size` 早拒（`st_size` 是打开那一刻的快照，文件可边读边长；且那道守卫钉不住，是负债不是资产） | 改为**读取过程中计数**，与 S1 逐字同规格。该档区分不了两种实现，已在测试 docstring 里如实登记 |
| D3 | Task 15 Step 0 的两个公开入口 | 只公开 `atomic_write_json` | 连同 `open_regular_probe` 一起公开（D1 的前提）；另加一条**回归钉**——`write_owner_marker` 仍不得走 `F_FULLFSYNC`，否则「默认不改行为」是空话 |
| D4 | Task 16 `commit_stock` 的 `lifecycle` 参数 | 不校验键名。`payload.update(lifecycle)` 是一条通往**任意顶层键**的走私通道（`lifecycle={"files": []}` 就能在这个自称「够不到生命周期字段」的入口里清空实拷清单）| 加 `_require_lifecycle_only` 白名单；docstring 如实登记它**挡不住**「调用方传伪造快照」（那需要每次提交回读磁盘） |
| D5 | Task 17 决策表分支次序 | 「staging 复校失败」写在 `fatal.kind` 判断**之后** → 「上次 source escape + 本次复校失败」走到 `return {}`，把 fatal 与复校失败一起丢掉 | 提到 `kind` 判断**之前**。已登记为 spec **S2-F11** |
| D6 | Task 17 对「有 fatal 却没 stopped_reason」的输入 | 用 `if prev_reason is not None:` 兜着 → 安静产出一份读侧判非法的 manifest（写侧/读侧不配对家族又一次），且那两个分支本身没有任何测试钉得住 | 当场抛 `ManifestInvalidError`，两处改为无条件回写 |
| D7 | Task 17 `FinalOutcome` | 公开 dataclass 却不校验 `kind` → `FinalOutcome(kind="whatever")` 落到「上次没 fatal → 返回 {}」，**被静默当成干净跑完** | `__post_init__` 校验 `kind` 与 `staging_recheck` |
| D8 | Task 17 `escape_stop` | 只查「非空」不查类型 → `relative_path=123` 一路通过构造与决策表、写上磁盘，到**下一次读**才被判非法 | 连类型一起在构造期校验 |
| D9 | Task 17 `max_bytes_stop` | 开了 `revisited_fatal_path` / `staging_recheck` 两个参数，而决策表对 max_bytes 这一支**根本不看它们**（O4-F1）→ 可传而被静默忽略 | 两个参数从签名里去掉，让它**不可表达** |

**另有一处测试判别力订正**：Task 18 那条「内存预置 `stopped_reason`」的档判别力不够
（决策表会把同一个值塞回去，剥不剥都绿），改成预置一条**陈旧的 `stopped_reason_secondary`**
并断言它必须被剥掉——变异实测：不剥时三条档一起变红。

**收尾机械化 sweep 的结果**：84 个 `_require*` 判据、**73 条变红、8 条仍绿**。
8 条全部有明确归因（6 条邻居兜底 / 1 条等价变异 / 1 条代码里已写明的恒真断言），
零条「不明原因仍绿」。首轮 12 条仍绿里那 4 条**真的没人守**的已补上专属档
（缺 `source_snapshot.universe`、`fetch_fatal_error` 的 `relative_path`/`component` 为空串、
存根 `completed_at` 为空串）。
⚠️ 984 组合那条整族扫描探不到它们，因为它只断言「若抛异常则必须是本模块的族」、
**不断言「必须抛」**，且只做「替换值」从不做「删键」。

---

## Task 15: S1 小改（另一半）+ `read_manifest` —— 逐段无跟随读回并校验

> **⚠️ 本任务比 S2a 的原版多一个前置步骤（2026-08-25 pre-flight 裁决）**：
> S1 的 `_atomic_write_json` 是**私有**的、且文件内容走普通 `fsync`，而 manifest
> 提交按 O4-F11 定案要走 `F_FULLFSYNC`。这半边小改原本排在 S2a 的 Task 1，
> 但它在 S2a 里**零使用者**（落盘在本片），故移到这里。
>
> **前置 Step 0：公开 `atomic_write_json` 并加 `full_sync` 开关**
>
> `backend/qmt_fsroot.py`：
>
> ```python
> # ① __all__ 里，"耐久提交" 那一组改为：
>     # 耐久提交
>     "fsync_dir", "full_fsync", "atomic_write_json",
> ```
>
> ```python
> # ② _atomic_write_json 加参数（签名 + 文件 fsync 那一处）：
> def _atomic_write_json(dir_fd: int, name: str, payload: dict, *,
>                        full_sync: bool = False) -> None:
>     """（……原有 docstring 全部保留……）
>
>     `full_sync=True` 时，文件内容改用 `full_fsync()`（macOS 上即
>     `fcntl(fd, F_FULLFSYNC)`）——**manifest 提交专用**（O4-F11 定案：断电在
>     威胁模型之内，而本平台的 `fsync(2)` man page 明写它既不保证断电耐久、
>     也不保证跨设备写序）。**默认 `False`**：归属标记等其余落地点保留 `fsync`，
>     行为不变。目录项一律走 `fsync_dir`（`F_FULLFSYNC` 对目录 fd 的语义未经
>     实测，不外推）。
>     """
>     ...
>         try:
>             _write_all(fd, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
>             if full_sync:
>                 full_fsync(fd)
>             else:
>                 os.fsync(fd)
>         finally:
>             os.close(fd)
>     ...
>
>
> def atomic_write_json(dir_fd: int, name: str, payload: dict, *,
>                       full_sync: bool = False) -> None:
>     """公开入口，语义同 `_atomic_write_json`。manifest 提交走它并传
>     `full_sync=True`；模块内部（归属标记）继续走私有名与默认刷盘。
>     """
>     _atomic_write_json(dir_fd, name, payload, full_sync=full_sync)
> ```
>
> 配套测试（追加到 `backend/tests/test_qmt_fsroot.py`）：`full_sync=True` 必须真的
> 走 `F_FULLFSYNC`；`full_sync=False` **不得**走；`F_FULLFSYNC` 不存在的平台
> （Linux CI）不得抛 `AttributeError`；**外加一条回归钉**——`write_owner_marker`
> 仍然**不**走 `F_FULLFSYNC`（否则「默认不改行为」这句话就是空的）。
> 三条 spy 档的写法与本片 Task 16 的 `..._uses_full_fsync` 相同，注意
> `test_qmt_manifest.py` 顶部需要 `import fcntl`（S2a 未引入它，本片补）。

### `read_manifest` 本体

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: `qmt_fsroot.open_root` / `open_under`（S1）、Task 5–14 的 `validate_manifest`
- Produces: `read_manifest(stg_fd: int) -> dict | None`、`lifecycle_snapshot(manifest: dict) -> dict`

**为什么返回 `None` 而不是抛**：manifest 不存在是**引导态**（崩在标记落盘与首份 manifest 之间），spec 明写它「允许从头继续初始化」（R60-F3）。把「不存在」与「坏了」混成一个异常，会让引导态这一档**无法与畸形区分**。

**⚠️ 本片新增一条 spec 没写的安全上限**：`_MANIFEST_MAX_BYTES = 64 MiB`。manifest 是**不可信输入**（staging 可能被人动过），读到 EOF 为止意味着一个被植入的几 GB 文件能把进程 OOM 掉，而不是得到一个干净的 `ManifestInvalidError`。这与 S1 给归属标记设 `_MARKER_MAX_BYTES` 是同一条判据；64 MiB 宽松到不可能误伤（5608 只股的完整 universe + 800 条 files 实测量级约 0.5 MB）。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

import json as _json_rw

from qmt_fsroot import open_root, PathEscapeError
from qmt_manifest import read_manifest, lifecycle_snapshot, MANIFEST_NAME


def _staging(tmp_path, manifest=None, *, raw=None):
    """造一个 staging 目录并返回 (path, stg_fd)。调用方负责 os.close。"""
    d = tmp_path / "staging"
    d.mkdir()
    if raw is not None:
        (d / MANIFEST_NAME).write_text(raw, encoding="utf-8")
    elif manifest is not None:
        (d / MANIFEST_NAME).write_text(
            _json_rw.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    return d, open_root(str(d))


def test_read_manifest_round_trips_a_valid_one(tmp_path):
    """正向放行档。"""
    m = _valid_manifest()
    _d, fd = _staging(tmp_path, m)
    try:
        assert read_manifest(fd) == m
    finally:
        os.close(fd)


def test_read_manifest_returns_none_when_absent(tmp_path):
    """⭐ 引导态：manifest 不存在 ≠ manifest 坏了。

    判别力：把「不存在」也抛成 ManifestInvalidError，本条必红——而那会让
    「崩在标记落盘与首份 manifest 之间」这一档无法与畸形区分，
    一棵本可继续初始化的 staging 变成人工才能清理的状态（R60-F3）。
    """
    _d, fd = _staging(tmp_path)
    try:
        assert read_manifest(fd) is None
    finally:
        os.close(fd)


def test_read_manifest_rejects_truncated_json(tmp_path):
    """⭐ 截断的 manifest 往往仍是合法 JSON 的**前缀片段**。

    静默消费它 = 把 manifest 损坏伪装成「候选就这么多」（R1-F4）。
    """
    good = _json_rw.dumps(_valid_manifest(), ensure_ascii=False)
    _d, fd = _staging(tmp_path, raw=good[: len(good) // 2])
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_empty_file(tmp_path):
    _d, fd = _staging(tmp_path, raw="")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_a_json_array(tmp_path):
    """合法 JSON 但不是对象。"""
    _d, fd = _staging(tmp_path, raw="[1,2,3]")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_oversized_file(tmp_path, monkeypatch):
    """⭐ 不可信输入的大小上限（本片新增，非 spec 条款）：manifest 决定
    整棵 staging 可不可信，读到 EOF 为止意味着一个被植入的几 GB 文件能把
    进程 OOM 掉，而不是得到一个干净的拒绝。

    判别力：删掉上限检查，本条必红（会读进去并报 JSON 错或直接通过）。
    """
    import qmt_manifest as qm
    monkeypatch.setattr(qm, "_MANIFEST_MAX_BYTES", 100)
    _d, fd = _staging(tmp_path, _valid_manifest())      # 远超 100 字节
    try:
        with pytest.raises(ManifestInvalidError) as ei:
            read_manifest(fd)
        assert "过大" in str(ei.value)
    finally:
        os.close(fd)


def test_read_manifest_lets_path_escape_bubble_up(tmp_path):
    """⭐ manifest 被换成指向 staging 之外的符号链接 → `open_under` 逐段
    `O_NOFOLLOW` 撞 ELOOP → **PathEscapeError 原样上浮**，不被降级成
    「manifest 畸形」。

    判别力：把 open_under 的异常 catch 成 ManifestInvalidError，本条必红——
    而那会把一次**信任边界破坏**报成「账本坏了」，恢复指引整个走错
    （R94-F2 同族：一个合规的写者产出的 manifest 被读者判成畸形）。
    处置（stopped_reason: staging_path_escape + rc≠0）由 S4/S5 负责。
    """
    outside = tmp_path / "outside.json"
    outside.write_text(_json_rw.dumps(_valid_manifest(), ensure_ascii=False),
                       encoding="utf-8")
    d = tmp_path / "staging"
    d.mkdir()
    (d / MANIFEST_NAME).symlink_to(outside)
    fd = open_root(str(d))
    try:
        with pytest.raises(PathEscapeError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_propagates_version_error_not_invalid(tmp_path):
    """版本三档必须原样穿过 read_manifest（两族异常不许在这一层被抹平）。"""
    _d, fd = _staging(tmp_path, _valid_manifest(manifest_version=99))
    try:
        with pytest.raises(ManifestVersionError) as ei:
            read_manifest(fd)
        assert ei.value.kind == "newer"
    finally:
        os.close(fd)


def test_lifecycle_snapshot_captures_only_the_three_keys():
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal(),
                        stopped_reason_secondary="max_bytes")
    snap = lifecycle_snapshot(m)
    assert set(snap) == {"stopped_reason", "fetch_fatal_error",
                         "stopped_reason_secondary"}


def test_lifecycle_snapshot_of_a_clean_manifest_is_empty():
    assert lifecycle_snapshot(_valid_manifest()) == {}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "read_manifest or lifecycle_snapshot" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'read_manifest'`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部补 import
import os
from qmt_fsroot import atomic_write_json, open_under


# 常量区补：
# manifest 是**不可信输入**（它决定整棵 staging 可不可信），故读入有上限。
# **本片新增，非 spec 条款**——与 S1 给归属标记设 `_MARKER_MAX_BYTES` 同一条
# 判据：读到 EOF 为止意味着一个被植入的几 GB 文件能把进程 OOM 掉，而不是得到
# 一个干净的 `ManifestInvalidError`。64 MiB 宽松到不可能误伤：5608 只股的完整
# universe + 800 条 files 实测量级约 0.5 MB。
_MANIFEST_MAX_BYTES = 64 * 1024 * 1024


# 追加到 backend/qmt_manifest.py

def lifecycle_snapshot(manifest: dict) -> dict:
    """捕获生命周期三字段的当前值，供 per-stock 提交逐字回写。

    **这是 per-stock 提交够不到那三个字段的实现手段**（R95-F2 + §9-3s
    「使规则可机械检验」）：`commit_stock` 把 manifest 里的同名键一律剥掉，
    再把本快照塞回去——**调用方即使污染了内存里的 manifest，也写不进磁盘**。
    """
    return {k: manifest[k] for k in LIFECYCLE_KEYS if k in manifest}


def read_manifest(stg_fd: int) -> dict | None:
    """相对 `stg_fd` **逐段无跟随**读回 manifest 并过全套读侧校验。

    返回校验通过的 manifest；**文件不存在返回 `None`**（引导态——崩在归属标记
    落盘与首份 manifest 之间，spec 明写它允许从头继续初始化，R60-F3）。
    把「不存在」与「坏了」混成一个异常，会让引导态这一档无法与畸形区分。

    抛：
    - `ManifestInvalidError` —— 空文件 / 截断 / 不是 JSON 对象 / 超过大小上限 /
      任一读侧判据不过；
    - `ManifestVersionError` —— 版本三档（**不在本层抹平成 Invalid**）；
    - `PathEscapeError` —— manifest 这一段或其父分量被换成符号链接
      （`open_under` 逐段 `O_NOFOLLOW` 撞 `ELOOP` / `ENOTDIR`）。
      **原样上浮，不降级成「manifest 畸形」**：那是一次**信任边界破坏**，
      处置是 `stopped_reason: staging_path_escape` + 顶层 `fetch_fatal_error`
      + rc≠0（S4/S5 负责），报成「账本坏了」会让恢复指引整个走错。
    """
    try:
        fd = open_under(stg_fd, MANIFEST_NAME, flags=os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if st.st_size > _MANIFEST_MAX_BYTES:
            raise ManifestInvalidError(
                f"{MANIFEST_NAME} 过大（{st.st_size} 字节，上限 "
                f"{_MANIFEST_MAX_BYTES}）——它决定整棵 staging 可不可信，"
                "拒绝把一个来路不明的巨型文件读进内存"
            )
        chunks: list[bytes] = []
        while True:
            block = os.read(fd, 1 << 20)
            if not block:
                break
            chunks.append(block)
    finally:
        os.close(fd)

    data = b"".join(chunks)
    if not data:
        raise ManifestInvalidError(f"{MANIFEST_NAME} 是空文件")
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ManifestInvalidError(
            f"{MANIFEST_NAME} 不是合法 JSON：{e}。"
            "这通常意味着上一次写入被打断（文件被截断）。"
        ) from e
    return validate_manifest(payload)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 134 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M47 | `except FileNotFoundError: return None` → `raise ManifestInvalidError(...)` | `..._returns_none_when_absent` |
| M48 | 删掉 `st.st_size > _MANIFEST_MAX_BYTES` 那条 | `..._rejects_oversized_file` |
| M49 | 把 `open_under(...)` 换成 `os.open(MANIFEST_NAME, os.O_RDONLY, dir_fd=stg_fd)` | `..._lets_path_escape_bubble_up` |
| M50 | 在 `validate_manifest(payload)` 外包一层 `except Exception: raise ManifestInvalidError` | `..._propagates_version_error_not_invalid` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): read_manifest —— 逐段无跟随读回并校验

不存在返回 None 而不是抛：manifest 不存在是引导态（崩在标记落盘与首份
manifest 之间，R60-F3 明写允许从头继续初始化）。混成一个异常会让引导态
无法与畸形区分。

PathEscapeError 原样上浮，不降级成「manifest 畸形」：那是信任边界破坏，
报成「账本坏了」会让恢复指引整个走错。版本三档同样不在这一层被抹平。

新增一条 spec 没写的安全上限（64 MiB）：manifest 是不可信输入，读到 EOF
为止意味着被植入的几 GB 文件能把进程 OOM 掉。与 S1 给归属标记设上限同源。"
```

---

## Task 16: `commit_stock` —— per-stock 提交**够不到**生命周期三字段

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Produces: `commit_stock(stg_fd: int, manifest: dict, *, lifecycle: dict) -> dict`

**为什么这条必须是结构性的而不是纪律性的**：spec §9-3s 明写「**per-stock 提交一律不动这两个字段**，**使规则可机械检验**」。靠「实施者记得别改」是纪律；把 `lifecycle` 做成**必需参数**、并在写入前把 manifest 里的同名键**剥掉**，才是结构——调用方即使污染了内存里的 manifest，也写不进磁盘。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import commit_stock


def test_commit_stock_writes_a_readable_manifest(tmp_path):
    """正向放行档：写出去的必须读得回来。"""
    m = _valid_manifest()
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, lifecycle={})
        assert read_manifest(fd) == m
    finally:
        os.close(fd)


def test_commit_stock_cannot_change_lifecycle_fields(tmp_path):
    """⭐⭐ 核心不变量：即使调用方**故意**改了内存里的三个字段，
    磁盘上写出去的仍是 lifecycle 快照里的值。

    判别力：把实现写成 `atomic_write_json(fd, NAME, manifest)`（直接写入参），
    本条必红。这就是 §9-3s 说的「使规则可机械检验」——
    不是靠实施者记得别改。
    """
    prev = {"stopped_reason": "staging_path_escape",
            "fetch_fatal_error": _fatal()}
    poisoned = _valid_manifest(**prev)
    snap = lifecycle_snapshot(poisoned)

    # 调用方「不小心」把 fatal 洗掉了
    del poisoned["fetch_fatal_error"]
    poisoned["stopped_reason"] = "max_bytes"

    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, poisoned, lifecycle=snap)
        on_disk = read_manifest(fd)
        assert on_disk["stopped_reason"] == "staging_path_escape"
        assert on_disk["fetch_fatal_error"] == _fatal()
    finally:
        os.close(fd)


def test_commit_stock_cannot_invent_lifecycle_fields(tmp_path):
    """反向档：一份**干净的** manifest，调用方硬塞一个 stopped_reason
    进去 —— 磁盘上必须仍然干净。

    没有这一条，「只在 lifecycle 有值时覆盖」的实现也能让上一条绿。
    """
    poisoned = _valid_manifest(stopped_reason="max_bytes")
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, poisoned, lifecycle={})       # 启动时磁盘上是干净的
        assert "stopped_reason" not in read_manifest(fd)
    finally:
        os.close(fd)


def test_commit_stock_preserves_unknown_top_level_keys(tmp_path):
    """S3/S4 的 failures / batches 等经 per-stock 提交流转，不得被剥掉。"""
    m = _valid_manifest(failures=[{"stock_code": "600004.SH", "attempts": 1}],
                        committed_bytes=123)
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, lifecycle={})
        on_disk = read_manifest(fd)
        assert on_disk["failures"] == [{"stock_code": "600004.SH", "attempts": 1}]
        assert on_disk["committed_bytes"] == 123
    finally:
        os.close(fd)


def test_commit_stock_uses_full_fsync(tmp_path, monkeypatch):
    """manifest 提交按 O4-F11 定案走 F_FULLFSYNC（断电在威胁模型之内）。

    判别力：把 full_sync=True 去掉，本条必红。
    """
    if not hasattr(fcntl, "F_FULLFSYNC"):
        return
    calls = []
    real = fcntl.fcntl
    monkeypatch.setattr(fcntl, "fcntl",
                        lambda fd, cmd, *a: (calls.append(cmd), real(fd, cmd, *a))[1])
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), lifecycle={})
    finally:
        os.close(fd)
    assert fcntl.F_FULLFSYNC in calls


def test_commit_stock_is_atomic_leaving_no_tmp_files(tmp_path):
    """走 tmp → replace，落地后目录里不得有残留临时文件。"""
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), lifecycle={})
    finally:
        os.close(fd)
    assert sorted(p.name for p in d.iterdir()) == [MANIFEST_NAME]
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k commit_stock 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'commit_stock'`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py

def _write_manifest(stg_fd: int, payload: dict) -> None:
    """manifest 的唯一落盘路径：tmp → `fsync(文件)` → `os.replace` →
    `fsync(目录)`，且文件内容走 **`F_FULLFSYNC`**（O4-F11 定案：断电在威胁
    模型之内，而本平台的 `fsync(2)` man page 明写它既不保证断电耐久、
    也不保证跨设备写序）。

    ⚠️ **绝不就地截断重写**——「原子」（`os.replace` 不会看到半截）与「耐久」
    （崩溃后仍在）是两件事，两者都要（R45-F2）。
    """
    atomic_write_json(stg_fd, MANIFEST_NAME, payload, full_sync=True)


def commit_stock(stg_fd: int, manifest: dict, *, lifecycle: dict) -> dict:
    """**per-stock 提交**（每只股一次，R37-F1）。返回真正写出去的那份。

    ⚠️⚠️ **本函数在写入路径上够不到生命周期三字段**：manifest 里的
    `stopped_reason` / `stopped_reason_secondary` / `fetch_fatal_error`
    一律被**剥掉**，再把 `lifecycle`（启动时从磁盘捕获的快照）逐字塞回去。
    调用方即使污染了内存里的 manifest，也写不进磁盘。

    这不是纪律而是结构：spec §9-3s 要求「per-stock 提交一律不动这两个字段，
    **使规则可机械检验**」。靠「实施者记得别改」的实现无法被机械检验，
    而这两个字段是 pilot 的 fail-closed 判据——被 per-stock 提交洗掉一次，
    一棵**已被证明动过**的 staging 就会拿到干净标签。
    """
    payload = {k: v for k, v in manifest.items() if k not in LIFECYCLE_KEYS}
    payload.update(lifecycle)
    _write_manifest(stg_fd, payload)
    return payload
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 140 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M51 | 整个函数体换成 `_write_manifest(stg_fd, manifest); return manifest` | `..._cannot_change_lifecycle_fields` + `..._cannot_invent_lifecycle_fields` |
| M52 | 只做 `payload.update(lifecycle)`、不先剥 | `..._cannot_invent_lifecycle_fields`（lifecycle 为空时剥不掉） |
| M53 | `full_sync=True` → `False` | `..._uses_full_fsync` |

> M52 是「两条判据互相掩盖」的反面教材：**剥**与**塞**是两个动作，只做后者时
> 「洗掉」那档仍绿（快照非空会覆盖回去），只有「凭空塞」那档会红。**两档缺一不可。**

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): commit_stock —— per-stock 提交在写入路径上够不到生命周期三字段

spec §9-3s 要求「per-stock 提交一律不动这两个字段，使规则可机械检验」。
靠「实施者记得别改」是纪律，无法被机械检验；把 lifecycle 做成必需参数、
写入前把 manifest 里的同名键剥掉再塞回快照，才是结构——调用方即使污染了
内存里的 manifest 也写不进磁盘。

「剥」与「塞」是两个动作，各配一档（洗掉 / 凭空塞），缺一会互相掩盖。

manifest 提交走 F_FULLFSYNC（O4-F11：断电在威胁模型之内）。"
```

---

## Task 17: 收尾生命周期决策表（纯函数）

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Produces: `FinalOutcome`（frozen dataclass）、`clean_finish()` / `max_bytes_stop()` / `escape_stop()` 三个工厂、`resolve_final_lifecycle(manifest: dict, outcome: FinalOutcome) -> dict`、`SkipVerifyWithEscapeError`

**为什么这条规则反直觉、且两种朴素做法都错（R95-F2）**：
- **就地合并式更新**：操作者修好树、重跑成功，陈旧 fatal 仍在 → **pilot 永远拒绝启动**；
- **启动即清除**：重试崩在中途便**抹掉唯一的持久证据** → 下一次看到的是一份**看起来干净、实则来自被污染源树**的 staging。

**规则**：启动不清；**只在「收尾提交」那一次原子提交里**写入本次值并删除 `fetch_fatal_error`；崩在此前则旧记录保留（安全侧）。

**⚠️ 清除的谓词不是「本次没撞 escape」，而是「已证明受影响的路径确实干净」（O2-F7）**：反例——上次因 `staging_path_escape` 终止（manifest 已记 56 只股），操作者删掉被换的分量重建，重跑时新股走**新建目录**全部成功、收尾复校只对**源**重算 sha256（**从不回读 staging 里那 56 只股**）→「本次没撞 escape」成立 → 清除 → **manifest 声称拥有的 56 只股在 staging 里已不存在，而唯一记录「这棵树被动过」的持久证据没了**。

**⚠️ `max_bytes` 绝不许洗白 escape（O4-F1）**：Run1 撞 `staging_path_escape`（已记 56 只股）→ pilot fail-closed ✅ → 操作者修好重跑 → Run2 拉几只就触到 `--max-bytes`（**累计字节含 Run1，触顶几乎必然**）→ 若把 `stopped_reason` 改写成 `max_bytes`，**pilot 读到就放行**，那 56 只从未被复校过的股照常消费——**一次被证明破坏的信任边界被一次容量停止洗白成合法凭据**。

| 本次运行 | 上次留的 fatal | 结果 |
|---|---|---|
| 撞了 escape | 任意 | `stopped_reason` = 本次 escape；`fetch_fatal_error` = 本次四字段（覆盖）；清掉 secondary |
| 干净跑完 | 无 | 删掉 `stopped_reason`；无 fatal |
| `max_bytes` 触顶 | 无 | `stopped_reason` = `max_bytes` |
| `max_bytes` 触顶 | **有** | **fatal 原样保留、escape 的 `stopped_reason` 不得被覆盖**；另记 `stopped_reason_secondary: "max_bytes"` |
| 干净跑完 | 有，但**没重走过**那条路径 | **原样保留**（前提①不满足） |
| 干净跑完 | 有 `source_path_escape`，**已重走过** | **清除** fatal 与 `stopped_reason` |
| 干净跑完 | 有 `staging_path_escape`，已重走过，全量复校 **通过** | **清除** |
| 干净跑完 | 有 `staging_path_escape`，已重走过，全量复校 **失败** | 保留 fatal；`stopped_reason` = `staging_recheck_failed` |
| 干净跑完 | 有 `staging_path_escape`，已重走过，**跳过了复校** | **拒绝**（P2-F3：`--skip-existing-verify` 与带 escape 记录的 manifest 互斥） |

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import (
    FinalOutcome, clean_finish, max_bytes_stop, escape_stop,
    resolve_final_lifecycle, SkipVerifyWithEscapeError,
)


def _prev(fatal=None, reason=None, secondary=None):
    m = _valid_manifest()
    if reason is not None:
        m["stopped_reason"] = reason
    if fatal is not None:
        m["fetch_fatal_error"] = fatal
    if secondary is not None:
        m["stopped_reason_secondary"] = secondary
    return m


# ── 上次没有 fatal ────────────────────────────────────────────
def test_clean_finish_on_a_clean_manifest_clears_stopped_reason():
    assert resolve_final_lifecycle(_prev(), clean_finish()) == {}


def test_max_bytes_on_a_clean_manifest_records_max_bytes():
    assert resolve_final_lifecycle(_prev(), max_bytes_stop()) == {
        "stopped_reason": "max_bytes"}


def test_clean_finish_drops_a_stale_max_bytes_reason():
    """上次是干净的容量停止，这次跑完了 → 那条 stopped_reason 该消失。"""
    assert resolve_final_lifecycle(_prev(reason="max_bytes"), clean_finish()) == {}


# ── 本次撞 escape ─────────────────────────────────────────────
def test_escape_stop_overwrites_everything():
    out = escape_stop(kind="source_path_escape",
                      relative_path="1分钟K线_前复权/x.csv",
                      component="1分钟K线_前复权", errno="ENOTDIR")
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape", secondary="max_bytes"), out)
    assert got == {
        "stopped_reason": "source_path_escape",
        "fetch_fatal_error": {"kind": "source_path_escape",
                              "relative_path": "1分钟K线_前复权/x.csv",
                              "component": "1分钟K线_前复权", "errno": "ENOTDIR"},
    }
    assert "stopped_reason_secondary" not in got


# ── ⭐⭐ max_bytes 绝不洗白 escape（O4-F1）────────────────────
def test_max_bytes_never_launders_a_retained_escape():
    """⭐⭐ 本片最危险的一档：Run1 撞 escape，Run2 触顶。

    若把 stopped_reason 改写成 max_bytes，pilot 读到就放行，那 56 只从未被
    复校过的股照常消费——一次被证明破坏的信任边界被一次容量停止洗白成
    合法凭据。

    判别力：把实现写成「max_bytes 一律覆盖 stopped_reason」，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"), max_bytes_stop())
    assert got["stopped_reason"] == "staging_path_escape"      # 未被覆盖
    assert got["fetch_fatal_error"] == _fatal()                # 原样保留
    assert got["stopped_reason_secondary"] == "max_bytes"      # 只作诊断附注


# ── ⭐ 清除的谓词是「证明干净」而非「本次没撞」（O2-F7）───────
def test_clean_finish_without_revisiting_the_fatal_path_keeps_the_fatal():
    """⭐ 反例场景：上次 staging_path_escape 记了 56 只股，操作者重建目录，
    本次新股走**新建目录**全部成功、收尾复校只对**源**重算——
    从不回读那 56 只股。「本次没撞 escape」成立，但什么都没被证明干净。

    判别力：把清除条件写成「本次没撞 escape」，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=False))
    assert got["fetch_fatal_error"] == _fatal()
    assert got["stopped_reason"] == "staging_path_escape"


def test_source_escape_clears_after_revisiting_that_path():
    """source_path_escape 只要前提①（重走过那条路径）——
    前提②（staging 全量复校）是 staging_path_escape **另加**的。"""
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
        clean_finish(revisited_fatal_path=True))
    assert got == {}


def test_staging_escape_clears_only_after_a_passing_full_recheck():
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="passed"))
    assert got == {}


def test_staging_escape_with_failing_recheck_keeps_fatal_and_renames_reason():
    """⭐ P2-F3：此前完全未定义 → 不可解 staging。
    保留 fatal、覆盖 stopped_reason 为 staging_recheck_failed。

    ⭐ 这一档也是 `kind` 与 `stopped_reason` **必须解耦**的唯一理由
    （O4-F3）：kind 仍是 staging_path_escape，reason 已换成 recheck_failed。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="failed"))
    assert got["fetch_fatal_error"] == _fatal()
    assert got["fetch_fatal_error"]["kind"] == "staging_path_escape"
    assert got["stopped_reason"] == "staging_recheck_failed"


def test_skipping_the_recheck_on_a_staging_escape_manifest_is_refused():
    """⭐ P2-F3：--skip-existing-verify 与「manifest 带 escape 记录」互斥。

    不拒的话：第 1 次带 flag 跑清掉 fatal、标 partial（看似安全），
    第 2 次不带 flag 跑时收尾复校**只重算源、从不回读 staging** →
    **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 full 标签**。

    判别力：把这一档实现成「当作 passed 清除」或「当作没重走过保留」，
    本条必红——前者是那条出货级假凭据，后者会让 fatal 永远清不掉。
    """
    with pytest.raises(SkipVerifyWithEscapeError):
        resolve_final_lifecycle(
            _prev(fatal=_fatal(), reason="staging_path_escape"),
            clean_finish(revisited_fatal_path=True, staging_recheck=None))


# ── 构造期就排除非法组合 ──────────────────────────────────────
def test_escape_stop_rejects_a_kind_outside_the_enum():
    for bad in ("staging_recheck_failed", "max_bytes", ""):
        with pytest.raises(ValueError):
            escape_stop(kind=bad, relative_path="x", component="c", errno="ELOOP")


def test_escape_stop_rejects_an_errno_outside_the_enum():
    with pytest.raises(ValueError):
        escape_stop(kind="staging_path_escape", relative_path="x",
                    component="c", errno="EACCES")


def test_clean_finish_rejects_an_unknown_recheck_verdict():
    for bad in ("ok", "PASSED", True):
        with pytest.raises(ValueError):
            clean_finish(revisited_fatal_path=True, staging_recheck=bad)


def test_every_resolved_state_passes_the_read_side_validator():
    """⭐⭐ 写侧/读侧配对钉：决策表吐出的**每一种**状态，塞回 manifest 后
    都必须能过读侧校验。

    这是 R94-F2 / O4-F13 / S2-F3 / S2-F4 那个家族（写侧形状与读侧要求不配对）
    的**机械防线**：任何一支的输出若读侧不认，一个合规的写者就会产出被自己
    判非法的 manifest。
    """
    cases = [
        (_prev(), clean_finish()),
        (_prev(), max_bytes_stop()),
        (_prev(fatal=_fatal(), reason="staging_path_escape"), max_bytes_stop()),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=False)),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="passed")),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="failed")),
        (_prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
         clean_finish(revisited_fatal_path=True)),
        (_prev(), escape_stop(kind="staging_path_escape", relative_path="a/b.csv",
                              component="a", errno="ELOOP")),
    ]
    for prev, outcome in cases:
        new_lc = resolve_final_lifecycle(prev, outcome)
        merged = {k: v for k, v in prev.items() if k not in LIFECYCLE_KEYS}
        merged.update(new_lc)
        assert validate_manifest(merged) is merged
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "resolve_final or escape_stop or clean_finish or max_bytes_never or every_resolved" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'FinalOutcome'`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部补 import
from dataclasses import dataclass


# 追加到 backend/qmt_manifest.py

class SkipVerifyWithEscapeError(Exception):
    """`--skip-existing-verify` 撞上「manifest 带 escape 记录」——拒绝启动（P2-F3）。

    **不拒的具体后果**：第 1 次带 flag 跑清掉 fatal、标 `partial`（看似安全），
    第 2 次不带 flag 跑时收尾复校**只重算「源」、从不回读 staging** →
    **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 `full` 标签**。
    """


@dataclass(frozen=True)
class FinalOutcome:
    """本次运行的**收尾事件**。用三个工厂函数构造，非法组合在构造期就被排除。

    - `kind`：`clean`（正常跑完）/ `max_bytes`（干净的配额触顶）/ `escape`（撞了逃逸）
    - `escape`：`kind == "escape"` 时的四字段
    - `revisited_fatal_path`：本次是否**重新遍历过**上次 fatal 所指的那条路径（前提①）
    - `staging_recheck`：`staging_path_escape` 另加的全量复校结果（前提②），
      `"passed"` / `"failed"` / `None`（未做）
    """
    kind: str
    escape: dict | None = None
    revisited_fatal_path: bool = False
    staging_recheck: str | None = None


def clean_finish(*, revisited_fatal_path: bool = False,
                 staging_recheck: str | None = None) -> FinalOutcome:
    """本次正常跑完整批。"""
    if staging_recheck not in (None, "passed", "failed"):
        raise ValueError(
            f"staging_recheck 只能是 None/'passed'/'failed'，收到 {staging_recheck!r}")
    return FinalOutcome(kind="clean", revisited_fatal_path=revisited_fatal_path,
                        staging_recheck=staging_recheck)


def max_bytes_stop(*, revisited_fatal_path: bool = False,
                   staging_recheck: str | None = None) -> FinalOutcome:
    """干净的 `--max-bytes` 触顶（R44-F2：**终止条件，不是这只股的失败**）。"""
    if staging_recheck not in (None, "passed", "failed"):
        raise ValueError(
            f"staging_recheck 只能是 None/'passed'/'failed'，收到 {staging_recheck!r}")
    return FinalOutcome(kind="max_bytes", revisited_fatal_path=revisited_fatal_path,
                        staging_recheck=staging_recheck)


def escape_stop(*, kind: str, relative_path: str, component: str,
                errno: str) -> FinalOutcome:
    """本次撞了逃逸（源树或 staging 树的路径分量被换）。"""
    if kind not in FATAL_KINDS:
        raise ValueError(f"kind 必须是 {sorted(FATAL_KINDS)} 之一，收到 {kind!r}")
    if errno not in FATAL_ERRNOS:
        raise ValueError(f"errno 必须是 {sorted(FATAL_ERRNOS)} 之一，收到 {errno!r}")
    if not relative_path or not component:
        raise ValueError("relative_path 与 component 都必须非空")
    return FinalOutcome(kind="escape", escape={
        "kind": kind, "relative_path": relative_path,
        "component": component, "errno": errno,
    })


def resolve_final_lifecycle(manifest: dict, outcome: FinalOutcome) -> dict:
    """**收尾提交**时三个生命周期字段的完整新值（纯函数；缺席的键表示该字段应被删除）。

    ⚠️ **两种朴素做法都错**（R95-F2）：**就地合并式更新**会让操作者修好树、
    重跑成功之后，陈旧 fatal 永远留着、**pilot 永远拒绝启动**；**启动即清除**
    则会在「重试崩在中途」时**抹掉唯一的持久证据**，下一次看到的是一份
    看起来干净、实则来自被污染源树的 staging。把清除与「本次已干净收尾」绑进
    **同一次原子提交**，两种坏结局都不可表达。

    ⚠️ **清除的谓词不是「本次没撞 escape」，而是「已证明受影响的路径确实干净」**
    （O2-F7）：上次 `staging_path_escape` 记了 56 只股，操作者重建目录后重跑，
    新股走**新建目录**全部成功、收尾复校只对**源**重算 sha256（从不回读那 56 只股）
    ——「本次没撞」成立，而什么都没被证明干净。

    ⚠️ **`max_bytes` 绝不许洗白 escape**（O4-F1）：Run2 的累计字节含 Run1，
    触顶几乎必然；把 `stopped_reason` 改写成 `max_bytes` 会让 pilot 放行那批
    从未被复校过的股——**一次被证明破坏的信任边界被一次容量停止洗白成合法凭据**。
    """
    prev_fatal = manifest.get("fetch_fatal_error")
    prev_reason = manifest.get("stopped_reason")

    # ① 本次撞了 escape → 覆盖为本次的（secondary 清掉）
    if outcome.kind == "escape":
        assert outcome.escape is not None
        return {"stopped_reason": outcome.escape["kind"],
                "fetch_fatal_error": dict(outcome.escape)}

    # ② 上次没有 fatal → 只写本次的停止原因
    if prev_fatal is None:
        return {"stopped_reason": "max_bytes"} if outcome.kind == "max_bytes" else {}

    # ③ 上次有 fatal，本次是 max_bytes 触顶 → 一律保留，只加诊断附注。
    #    前提① 对它**不可能满足**（事前 stat 早拒不遍历任何路径），故不看 outcome
    #    里的两个前提字段。
    if outcome.kind == "max_bytes":
        kept = {"fetch_fatal_error": prev_fatal, "stopped_reason_secondary": "max_bytes"}
        if prev_reason is not None:
            kept["stopped_reason"] = prev_reason
        return kept

    # ④ 上次有 fatal，本次干净跑完 —— 清除与否取决于「有没有证明干净」
    if not outcome.revisited_fatal_path:
        kept = {"fetch_fatal_error": prev_fatal}
        if prev_reason is not None:
            kept["stopped_reason"] = prev_reason
        return kept

    if prev_fatal["kind"] == "staging_path_escape":
        # 前提②（无条件，不受任何 flag 影响，P2-F3）
        if outcome.staging_recheck is None:
            raise SkipVerifyWithEscapeError(
                "这棵 staging 的 manifest 里带着 staging_path_escape 记录，"
                "而本次跳过了既有文件复校。两者互斥：跳过复校就无法证明那些"
                "已记录的文件还在、还是原来的字节。请去掉 --skip-existing-verify "
                "重跑，或换新 staging + 新 seed 重拉。"
            )
        if outcome.staging_recheck == "failed":
            # ⭐ kind 与 stopped_reason 解耦的唯一理由（O4-F3）
            return {"fetch_fatal_error": prev_fatal,
                    "stopped_reason": "staging_recheck_failed"}

    # 已证明干净 → 清除（source_path_escape 只需前提①）
    return {}
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 154 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M54 | 分支③ 改成 `return {"stopped_reason": "max_bytes", "fetch_fatal_error": prev_fatal}` | `..._never_launders_a_retained_escape` |
| M55 | 分支③ 改成 `return {}`（把 max_bytes 当清除） | `..._never_launders_a_retained_escape` |
| M56 | `if not outcome.revisited_fatal_path:` → `if False:` | `..._without_revisiting_the_fatal_path_keeps_the_fatal` |
| M57 | `if outcome.staging_recheck is None: raise` → `pass` | `..._skipping_the_recheck_..._is_refused` |
| M58 | `staging_recheck == "failed"` 那支删掉 | `..._with_failing_recheck_keeps_fatal_and_renames_reason` |
| M59 | 分支④ 的 `prev_fatal["kind"] == "staging_path_escape"` → `True`（source 也要复校） | `..._source_escape_clears_after_revisiting_that_path` |
| M60 | 分支① 改成 `return {"fetch_fatal_error": dict(outcome.escape)}`（漏 stopped_reason） | `test_every_resolved_state_passes_the_read_side_validator` ← 配对钉抓到 |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): 收尾生命周期决策表（R95-F2 + O2-F7 + O4-F1 + P2-F3 + O4-F3）

两种朴素做法都错：就地合并式更新让陈旧 fatal 永远留着、pilot 永远拒绝启动；
启动即清除则在重试崩中途时抹掉唯一的持久证据。把清除与「本次已干净收尾」
绑进同一次原子提交，两种坏结局都不可表达。

⭐ 清除的谓词是「已证明受影响的路径确实干净」而非「本次没撞 escape」（O2-F7）：
重跑时新股走新建目录全部成功、收尾复校只重算源——什么都没被证明干净。

⭐⭐ max_bytes 绝不洗白 escape（O4-F1）：Run2 的累计字节含 Run1，触顶几乎
必然；覆盖 stopped_reason 会让 pilot 放行那批从未被复校过的股。

⭐ --skip-existing-verify 与带 escape 记录的 manifest 互斥（P2-F3），
不拒的话第一次带 flag 跑就能清掉 fatal，第二次拿到出货级 full 标签。

立了一条写侧/读侧配对钉：决策表吐出的每一种状态塞回 manifest 都必须过读侧
校验——这是 R94-F2/O4-F13/S2-F3/S2-F4 那个家族的机械防线。"
```

---

## Task 18: `commit_final` —— 唯一能动生命周期字段的落盘入口

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Produces: `commit_final(stg_fd: int, manifest: dict, *, outcome: FinalOutcome) -> dict`

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import commit_final


def test_commit_final_writes_a_readable_manifest(tmp_path):
    """正向放行档。"""
    d, fd = _staging(tmp_path)
    try:
        written = commit_final(fd, _valid_manifest(), outcome=clean_finish())
        assert read_manifest(fd) == written
    finally:
        os.close(fd)


def test_commit_final_clears_the_fatal_when_proven_clean(tmp_path):
    """⭐ 与 commit_stock 的权限差：收尾提交**能**清除。"""
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, m, outcome=clean_finish(revisited_fatal_path=True))
        on_disk = read_manifest(fd)
        assert "fetch_fatal_error" not in on_disk
        assert "stopped_reason" not in on_disk
    finally:
        os.close(fd)


def test_commit_final_keeps_the_fatal_when_not_proven(tmp_path):
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, m, outcome=clean_finish(revisited_fatal_path=False))
        on_disk = read_manifest(fd)
        assert on_disk["fetch_fatal_error"] == _fatal()
        assert on_disk["stopped_reason"] == "staging_path_escape"
    finally:
        os.close(fd)


def test_commit_final_ignores_lifecycle_fields_already_in_the_passed_manifest(tmp_path):
    """⭐ 与 commit_stock 同源的结构性保证：写出去的三个字段**只能**来自
    决策表，绝不来自调用方内存里那份 manifest 的直接赋值。

    这里内存里写着 max_bytes、磁盘上应当出现的却是「保留 escape」——
    因为决策表看的是 manifest 里**上一次**的 fatal，而不是调用方现在写的
    stopped_reason。

    判别力：把实现写成 `payload.update(...)` 而不先剥 LIFECYCLE_KEYS，
    本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    m["stopped_reason"] = "staging_path_escape"
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, m, outcome=max_bytes_stop())
        on_disk = read_manifest(fd)
        assert on_disk["stopped_reason"] == "staging_path_escape"
        assert on_disk["stopped_reason_secondary"] == "max_bytes"
    finally:
        os.close(fd)


def test_commit_final_uses_full_fsync(tmp_path, monkeypatch):
    if not hasattr(fcntl, "F_FULLFSYNC"):
        return
    calls = []
    real = fcntl.fcntl
    monkeypatch.setattr(fcntl, "fcntl",
                        lambda fd, cmd, *a: (calls.append(cmd), real(fd, cmd, *a))[1])
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, _valid_manifest(), outcome=clean_finish())
    finally:
        os.close(fd)
    assert fcntl.F_FULLFSYNC in calls


def test_commit_final_refuses_skip_verify_with_escape_and_writes_nothing(tmp_path):
    """⭐ P2-F3 的落盘侧：拒绝时**一个字节都不写**。

    判别力：把 resolve 的调用放在写入之后，本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    d, fd = _staging(tmp_path)
    try:
        with pytest.raises(SkipVerifyWithEscapeError):
            commit_final(fd, m, outcome=clean_finish(revisited_fatal_path=True))
        assert not (d / MANIFEST_NAME).exists()
    finally:
        os.close(fd)


def test_full_round_trip_stock_commits_then_final(tmp_path):
    """⭐⭐ 端到端不变量：一次带着 escape 记录的运行里，
    **任意多次 per-stock 提交都动不了 fatal，只有收尾那一次能**。
    """
    start = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    snap = lifecycle_snapshot(start)
    d, fd = _staging(tmp_path)
    try:
        for _ in range(3):                       # 三次 per-stock 提交
            commit_stock(fd, start, lifecycle=snap)
            assert read_manifest(fd)["fetch_fatal_error"] == _fatal()
        commit_final(fd, start,
                     outcome=clean_finish(revisited_fatal_path=True,
                                          staging_recheck="passed"))
        assert "fetch_fatal_error" not in read_manifest(fd)
    finally:
        os.close(fd)
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "commit_final or full_round_trip" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'commit_final'`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py

def commit_final(stg_fd: int, manifest: dict, *, outcome: FinalOutcome) -> dict:
    """**收尾提交** —— 全流程中**唯一**能写入或清除生命周期三字段的入口
    （R95-F2）。返回真正写出去的那份。

    与 `commit_stock` 的差别不在「记不记得改」，而在**能不能改**：
    per-stock 提交把那三个键剥掉再回填启动快照，本函数把它们剥掉再回填
    **决策表的输出**。两者都不从调用方内存里那份 manifest 直接取值。

    ⚠️ **`resolve_final_lifecycle` 必须在任何写入之前求值**：它可能抛
    `SkipVerifyWithEscapeError`（P2-F3），而那一档的规定是「拒绝启动、
    一个字节都不写」。
    """
    new_lifecycle = resolve_final_lifecycle(manifest, outcome)   # ← 可能抛，必须在写之前
    payload = {k: v for k, v in manifest.items() if k not in LIFECYCLE_KEYS}
    payload.update(new_lifecycle)
    _write_manifest(stg_fd, payload)
    return payload
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 161 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M61 | 把 `resolve_final_lifecycle(...)` 挪到 `_write_manifest` 之后 | `..._refuses_skip_verify_..._writes_nothing` |
| M62 | 不剥 `LIFECYCLE_KEYS`，直接 `payload = dict(manifest)` 再 update | `..._ignores_lifecycle_fields_already_in_the_passed_manifest` |
| M63 | `commit_final` 内部改调 `commit_stock` | `..._clears_the_fatal_when_proven_clean` |

- [ ] **Step 6: 跑全量 + 两条 CI 复刻闸**

```bash
cd backend
find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null

# ① 复刻 CI 的 no-skip 闸
PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/ -q --junitxml=/tmp/s2-final.xml 2>&1 | tail -5
python - <<'PY'
import xml.etree.ElementTree as ET
r = ET.parse("/tmp/s2-final.xml").getroot()
n = lambda k: sum(int(s.get(k, 0)) for s in r.iter("testsuite"))
print(f"tests={n('tests')} skipped={n('skipped')} failures={n('failures')} errors={n('errors')}")
assert n("skipped") == 0 and n("failures") == 0 and n("errors") == 0, "CI no-skip 闸不过"
print("CI no-skip 闸 PASS")
PY

# ② 模拟 Linux：抹掉 macOS 专属常量再跑全量
mkdir -p /tmp/nofs && cat > /tmp/nofs/nofullfsync.py <<'PY'
import fcntl
def pytest_configure(config):
    if hasattr(fcntl, "F_FULLFSYNC"):
        del fcntl.F_FULLFSYNC
PY
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/tmp/nofs python -m pytest tests/ -q -p nofullfsync 2>&1 | tail -5
```

Expected: 两条都全绿，且 `skipped == 0`

- [ ] **Step 7: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): commit_final —— 唯一能动生命周期三字段的落盘入口

与 commit_stock 的差别不在「记不记得改」而在「能不能改」：两者都把三个键
剥掉再回填，per-stock 填启动快照、收尾填决策表输出，都不从调用方内存里
那份 manifest 直接取值。

resolve 必须在任何写入之前求值：P2-F3 那一档要抛，而它的规定是「拒绝启动、
一个字节都不写」。

端到端不变量钉：一次带着 escape 记录的运行里，任意多次 per-stock 提交都
动不了 fatal，只有收尾那一次能。"
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
> ⚠️ **后面每次用它都写成 `"$PY"`（带双引号）**。这个路径里有一个空格，
> 不加引号会被终端拆成两半，报 `/Users/maziming/Coding/Prj_Kline: No such file or directory`。
> 本清单初稿五处全是裸 `$PY`，2026-08-30 真跑时当场报错，已逐处修正。
>
> 再进 worktree 的 backend 目录：
>
> ```
> cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s2b/backend"
> ```

### A1 · 确认你在对的地方

**动作**

```
git branch --show-current && git rev-parse --short HEAD && pwd
```

**期望**：三行依次是 `feat/qmt-4b-s2b-commit`、一个 7 位提交号、以 `.dev/worktree/qmt-4b-s2b/backend` 结尾的路径。

**通过判定**：分支名完全一致 → 通过；不一致 → 不通过（说明开了别的窗口或切错分支，**先别继续**）。

---

### A2 · 全部测试通过，且一条都没被跳过

> 「跳过」= 测试没真跑，只是被标成「不算数」。本仓的自动检查把**任何跳过**都判失败，
> 因为在开发者的 Mac 上跳过的那条，正是在服务器（Linux）上会出问题的那条。

**动作**

```
"$PY" -m pytest tests/ -q --junitxml=/tmp/s2-accept.xml
```

**期望**：最后一行形如 `NNN passed in XX.XXs`，**没有** `failed`、**没有** `skipped`、**没有** `error`。

**通过判定**：出现 `passed`、且**没有** `failed` / `skipped` / `error` 字样 → 通过。

> 数字本身只作参考：**本片开工前在 `origin/main` (`1437529`) 上实测的基线是 1106**（写本计划时写的 937 是 S2a 之前的旧数，已作废）。做完后应当明显更多。
> 若数字**比 1106 还少**，说明有测试没被收集到——那是不通过，请把完整输出贴出来。

---

### A3 · 用机器再数一遍跳过的条数（不看结论字样，看执行量）

> 为什么要多这一步：终端最后一行是**结论**，而结论字样可能与真实执行量不符。
> 本仓栽过「显示 `TEST SUCCEEDED` 而实际跑了 0 个测试」。这一步直接数**数字**。

**动作**

```
"$PY" -c "import xml.etree.ElementTree as E;r=E.parse('/tmp/s2-accept.xml').getroot();f=lambda k:sum(int(s.get(k,0)) for s in r.iter('testsuite'));print('总数',f('tests'),'跳过',f('skipped'),'失败',f('failures'),'错误',f('errors'))"
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
PYTHONPATH=/tmp/nofs "$PY" -m pytest tests/ -q -p nofullfsync
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
"$PY" -c "
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

### A6 · 亲眼看「容量停止」洗不白「安全警报」

> 这是本片最要紧的一条规则。场景：第一次拉取时发现目录被人动过手脚（安全警报，
> 下游会拒绝使用这批数据）；你修好后重跑，结果因为磁盘配额满了而停下。
> **那条安全警报绝不能因此消失。**——否则「被动过手脚」会被一次「磁盘满了」洗成合法。

**动作**

```
"$PY" -c "
import sys; sys.path.insert(0,'tests')
from test_qmt_manifest import _valid_manifest, _fatal
from qmt_manifest import resolve_final_lifecycle, max_bytes_stop, clean_finish
prev = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason='staging_path_escape')
r = resolve_final_lifecycle(prev, max_bytes_stop())
print('① 安全警报还在吗：', '✅ 在' if r.get('fetch_fatal_error') else '❌ 被洗掉了')
print('② 停止原因被改写了吗：', '✅ 没有（仍是 staging_path_escape）' if r['stopped_reason']=='staging_path_escape' else '❌ 被改写成 '+str(r['stopped_reason']))
print('③ 容量停止有没有单独记下：', '✅ 有' if r.get('stopped_reason_secondary')=='max_bytes' else '❌ 没有')
r2 = resolve_final_lifecycle(prev, clean_finish(revisited_fatal_path=False))
print('④ 没重走过出事的路就想清警报：', '✅ 清不掉' if r2.get('fetch_fatal_error') else '❌ 被清掉了')
r3 = resolve_final_lifecycle(prev, clean_finish(revisited_fatal_path=True, staging_recheck='passed'))
print('⑤ 真的重走过且全量复查通过：', '✅ 警报解除' if not r3.get('fetch_fatal_error') else '❌ 还清不掉')
"
```

**期望**：五行全部以 `✅` 开头的判定。

**通过判定**：五个 ✅ 全中 → 通过。

---

### A7 · 确认 spec 的更正都真的写进去了

> ⚠️ 路径是 `../docs/`（**两个点**）。本清单初稿写成了 `../../../docs/`，
> 那会退到仓库外面去，跑出来是 `No such file` —— 已实测并修正。
>
> ⚠️ 判据**不写死条数**：写死的计数本身就是腐烂源，以后每加一条更正都得回来改它。
> 下面两条命令**互相印证**，所以不用记住今天是几条。

**动作**（两行，逐行执行）

```
grep -o 'S2-F[0-9]\+' ../docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md | sort -u -V
```

```
grep -c '^| S2-F' ../docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md
```

**期望**：第一条输出一串**从 `S2-F1` 开始、连号不跳**的编号（今天到 `S2-F11`，以后还会更多）；
第二条输出的数字**等于第一条的行数**。

**通过判定**：编号连号不跳、且两条数字相等 → 通过。任一不满足 → 不通过。

> ⚠️ 注意 `S2-F[0-9]\+` 的 `\+`：S2a 版写的是 `S2-F[0-9]`（只匹配一位数），
> 到 `S2-F10` 就会把它截成 `S2-F1`、造成「看起来连号其实少了一条」的假绿。

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
| manifest 原子写 + 目录耐久 + `F_FULLFSYNC`（R45-F2 + O4-F11） | Task 1 + 15 + 16 |
| 每股提交一次（R37-F1）且**不动**生命周期字段（§9-3s） | Task 16 |
| 收尾提交的清除/保留规则（R95-F2 + O2-F7 + O4-F1 + P2-F3） | Task 17 + 18 |
| 引导态：manifest 不存在 ≠ 畸形（R60-F3） | Task 15 |

**已知不覆盖（按切片边界，逐条登记）**：`.staging.lock` 取锁（S1 已交付原语，取锁时机在 S5）、`.inflight.json` 崩溃恢复（S4）、四象限幂等（S4）、`--max-bytes` 流式扣减（S4）、七条源边界闸（S5）、预筛与分层洗牌（S3）。

## 2. Placeholder 扫描

无 `TBD` / `TODO` / 「稍后补」/「适当的错误处理」/「类似 Task N」。每个代码步骤都带可直接粘贴的代码，每个测试步骤都带完整测试体。

## 3. 类型一致性（自查发现并已修的两条）

- ❌→✅ **`_fcntl_t1` 跨文件引用**：Task 16/18 的测试在 `test_qmt_manifest.py` 里，却用了 `test_qmt_fsroot.py` 的别名 `_fcntl_t1`。已改为在 `test_qmt_manifest.py` 顶部 `import fcntl` 并直接用 `fcntl`；Task 1 那 14 处别名保留不动（它们在正确的文件里）。
- ❌→✅ **存根未重算导致的变异假阴性**：改动 `files` / `staged_export_log` 的 10 处否定档，若不重算 `source_verification_evidence`，聚合判据会**掩盖**被测判据——否定档照样红，但红的是聚合，于是把被测判据变异掉后测试**仍然绿**，变异表显示「零红」被误读成「测试没判别力」。已加 `_recompute_evidence(m)` 帮手并在 10 处调用，另给 M30 / M32 补了归因提醒。

- ❌→✅ **上游判据掩盖下游档（第二轮自查，Task 6）**：三条改 `source_snapshot` 的否定档只改了
  一处 sha / 留着默认 pool_order，于是「两处 sha 必须相等」与「pool_order 交叉核对」会**顶上来**，
  把被测判据变异掉后测试仍绿。已加 `_with_universe` 帮手、把 sha 格式档改成两处同时设坏值、
  并给三条档清空池与清单。
- ✅ **等价变异已识别并登记（Task 7）**：`pool_order` 的「后缀与层一致」与「交叉核对」
  **结构上重叠**（已实测），造不出专属档。M19 登记为等价变异、测试 docstring 写明「变异后
  仍绿是预期」，并在 `source_snapshot` 那一侧补了**真有**专属档的 `test_universe_code_suffix...`。

其余符号：`_valid_manifest` / `_sha` / `_file_rec` / `_recompute_evidence` / `_with_universe`（Task 5）→ 后续全用；`_fatal`（Task 11）→ Task 15/17/18 用；`_evidence` / `_agg_of` / `_GMT`（Task 12）→ Task 13 用；`_staging`（Task 15）→ Task 16/18 用；`_prev`（Task 17）→ Task 17 内用。**定义均早于首次使用。**

---

# 交付诚实口径

**做完 S2b 的正确表述**：manifest 这一层（结构 + 校验 + 落盘 + 生命周期）建好了，全部验证跑在临时目录里；`qmt_fetch.py` 仍然**零实现**。

**⛔ 禁止的表述**（无论听起来多顺）：

- 「4b 完成」
- 「SMB 拉取做好了」
- 「真实数据接入完成」
- 「pilot 已完成」
- 「100 股已出货」
- 「验证通过即可」/「看起来正常」/「应该没问题」

**本片之后还剩什么**：S3（预筛 + 分层储备池）、S4（拷贝引擎）、S5（源边界闸 + 命令行），然后才是 4c（编排 / 报告 / 出货凭据）。
