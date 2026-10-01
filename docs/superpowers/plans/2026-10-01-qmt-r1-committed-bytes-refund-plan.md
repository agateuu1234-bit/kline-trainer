# QMT R1 · `committed_bytes` 退还修复 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让崩溃恢复删掉某只股的 `files` 记录时**同步退还**它们的字节，使同一只股反复重拉不再重复消耗 `--max-bytes` 预算。

**Architecture:** 只改 `backend/qmt_manifest.py` 里 `_require_no_progress_rollback` 的 `committed_bytes` 那一段。把它分成两支：`scoped_removed` 为假时**原样保留**现状（`nb ≥ ob` 且 `nb ≥ ob + added`）；为真时换成三条更严的判据（不得新增、必须恰好退还、不得为负）。不新增任何持久化字段，不动 `manifest_version`。

**Tech Stack:** Python 3.11+（纯标准库）、pytest。解释器：`/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python`。

**Spec:** `docs/superpowers/specs/2026-10-01-qmt-r1-committed-bytes-refund-design.md`（codex 已 approve，账本键 `branch:fix/qmt-r1-committed-bytes-refund@49a3f7cb…`，指纹已独立重算核对）

---

## Global Constraints

逐条照抄自 spec，每个任务都隐含这些要求：

- **工作目录**：`/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes`。**不要** `cd` 回主仓。
- **解释器**：`"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"`（路径含空格，必须加引号）。跑 pytest 时先 `cd backend`。
- **基线**（已在本分支起点 `25ad1c2a` 实测）：`backend/tests/` 全套 **1620 passed / 0 skipped**；`test_qmt_manifest.py` **381 passed**。每个任务结束时这两个数只许**增加通过数**，不许出现 failed / skipped。
- **不碰**：`backend/qmt_fetch.py`、`backend/qmt_pool.py`、`backend/qmt_fsroot.py`、`.claude/` 下任何文件、`backend/` 其余模块。
- **不新增持久化字段**，**不** bump `manifest_version`。
- 跑测试一律带 `PYTHONDONTWRITEBYTECODE=1`。
- 每条命令都要打印 `branch` 与 `HEAD`（防在错的工作树里跑出假绿）。
- 提交信息用**中文**。

**术语**（spec §2.2）：
- `ob` = 上一份的 `committed_bytes`；`nb` = 本次的 `committed_bytes`
- `added` = `new_files` 里存在而 `prev_files` 里没有的那些记录的 `bytes` 之和
- `removed_bytes` = `prev_files` 里存在而 `new_files` 里没有的那些记录的 `bytes` 之和
- `scoped_removed` = 已有变量（`qmt_manifest.py:1356` 初始化、`:1384` 置真），为真当且仅当：声明了 `RecoveryScope`、锚点与冻结名单对得上、该股的 `files` 与池条目**一起**消失

**判据**（spec §2.2）：
- **R1** `scoped_removed` 为假 ⇒ `nb ≥ ob` 且 `nb ≥ ob + added`（**现状，原样保留**）
- **R2** `scoped_removed` 为真 ⇒ `nb` 必须**恰好等于** `ob - removed_bytes`
- **R3** `nb ≥ 0`
- **R4** `scoped_removed` 为真 ⇒ `added` 必须为 0

---

## File Structure

| 文件 | 职责 | 本计划的动作 |
|---|---|---|
| `backend/qmt_manifest.py` | 账本的形状校验与转移守卫 | 改 `_require_no_progress_rollback` 内 `committed_bytes` 一段（现 `:1546-1575`） |
| `backend/tests/test_qmt_manifest.py` | 该模块的单元测试（现 381 条） | 追加一节 `R1 退还` 的用例 U1–U16 |
| `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md` | S4a 契约，§3 登记着 R1 | 把 R1 标为已闭合并指向本 PR |

---

## Task 1：先把「现状必须不变」的那几格钉住

这一步**不改产品代码**。先补上 5 条「今天就该这样」的用例，它们加进去**应当直接绿**。
价值：后面三个任务改守卫时，这 5 条就是「没误伤邻居」的证据；若它们一开始就不绿，
说明我对现状的理解有误，必须先停下来查清楚。

**Files:**
- Modify: `backend/tests/test_qmt_manifest.py`（文件末尾追加）

**Interfaces:**
- Consumes: 该文件已有的 `_valid_manifest()`、`_file_rec(code, name, period)`、`_min_bytes(m)`、`_recompute_evidence(m)`；`qmt_manifest` 的 `_require_no_progress_rollback`、`ManifestInvalidError`、`RecoveryScope`
- Produces: 本节的四个辅助函数 `_r1_base()`、`_r1_recs(code, name, nbytes)`、`_r1_pool_entry(m, code)`、`_r1_remove_stock(m, code, refund)`，Task 2–4 都用它们

- [ ] **Step 1：在 `backend/tests/test_qmt_manifest.py` 末尾追加辅助函数与 5 条用例**

```python
# ── R1 · committed_bytes 退还（2026-10-01 spec）─────────────────────────────
# 术语：ob = 上一份的 committed_bytes；nb = 本次的；
#       removed_bytes = 消失的记录字节之和；added = 新增记录字节之和。
import copy as _r1_copy

from qmt_manifest import RecoveryScope as _R1Scope

_R1_A = ("600000.SH", "浦发银行")      # 被恢复移除的那只
_R1_B = ("600004.SH", "白云机场")      # 另一只（用来测 R4）
_R1_MARKET = "SH"
_R1_EACH = 183                         # 每条记录的字节数；一只股两条 = 366


def _r1_recs(code, name, nbytes=_R1_EACH):
    """造某只股的两条 files 记录（1d + 1m），字节数可控。"""
    out = [_file_rec(code, name, "1d"), _file_rec(code, name, "1m")]
    for rec in out:
        rec["bytes"] = nbytes
    return out


def _r1_pool_entry(m, code):
    """照搬池里已有条目的形状，只换 code —— 不照想象造样本。"""
    proto = m["pool_order"][_R1_MARKET][0]
    entry = _r1_copy.deepcopy(proto)
    entry["code"] = code
    return entry


def _r1_base(headroom=0):
    """起点账本：池里只有 A，files 是 A 的两条，committed_bytes = 下界 + headroom。

    headroom 的用途：把 committed_bytes 抬到远高于固有下界，这样「被拦住」
    只可能是转移守卫干的，不会是固有下界检查代为拦截（spec §3 的夹具纪律）。
    """
    m = _valid_manifest()
    m["files"] = _r1_recs(*_R1_A)
    m["pool_order"][_R1_MARKET] = [_r1_pool_entry(m, _R1_A[0])]
    m = _recompute_evidence(m)
    m["committed_bytes"] = _min_bytes(m) + headroom
    return m


def _r1_remove_stock(m, code, refund):
    """模拟崩溃恢复第③档：删该股的 files + 池条目 **且**退游标。

    ⚠️ 退游标不可省：恢复是一次**耦合转移**（删条目且 cursor ← min(cursor, idx)），
    只删不退会先被既有的耦合检查拦下，于是这条用例**测不到本 PR 的判据**。
    """
    m2 = _r1_copy.deepcopy(m)
    removed = sum(f["bytes"] for f in m2["files"] if f["stock_code"] == code)
    m2["files"] = [f for f in m2["files"] if f["stock_code"] != code]
    m2["pool_order"][_R1_MARKET] = [
        e for e in m2["pool_order"][_R1_MARKET] if e.get("code") != code
    ]
    idx = m2["source_snapshot"]["universe"][_R1_MARKET].index(code)
    cur = m2.get("cursor", {}).get(_R1_MARKET)
    if isinstance(cur, int):
        m2["cursor"][_R1_MARKET] = min(cur, idx)
    m2 = _recompute_evidence(m2)
    if refund:
        m2["committed_bytes"] = m2["committed_bytes"] - removed
    return m2, removed


def _r1_scope(m, code=_R1_A[0]):
    idx = m["source_snapshot"]["universe"][_R1_MARKET].index(code)
    return _R1Scope(stock_code=code, market=_R1_MARKET, universe_idx=idx)


def test_r1_u5_undeclared_rollback_still_rejected():
    """U5 · **未**声明恢复时把累计量调小 —— R1 不变，照旧拦。"""
    before = _r1_base()
    after, _removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    with pytest.raises(ManifestInvalidError):
        _require_no_progress_rollback(before, after, "U5")   # 不传 recovery


def test_r1_u6_partial_removal_still_rejected():
    """U6 · 声明恢复但只**部分**移除 —— 既有耦合检查不得被削弱。"""
    before = _r1_base()
    after = _r1_copy.deepcopy(before)
    after["files"] = after["files"][:1]          # 只删一条，池条目还在
    after = _recompute_evidence(after)
    with pytest.raises(ManifestInvalidError):
        _require_no_progress_rollback(before, after, "U6",
                                      recovery=_r1_scope(before))


def test_r1_u7_removal_without_cursor_rewind_still_rejected():
    """U7 · 声明恢复、完整移除，但 **cursor 没退** —— 耦合检查不得被削弱。"""
    before = _r1_base()
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    after["cursor"] = _r1_copy.deepcopy(before["cursor"])    # 把游标推回去
    after = _recompute_evidence(after)
    with pytest.raises(ManifestInvalidError):
        _require_no_progress_rollback(before, after, "U7",
                                      recovery=_r1_scope(before))


def test_r1_u13_normal_non_recovery_commit_passes():
    """U13 · 正常的非恢复提交（新增一只股、累计量涨够）—— 必须放行。"""
    before = _r1_base()
    after = _r1_copy.deepcopy(before)
    after["files"] = before["files"] + _r1_recs(*_R1_B)
    after["pool_order"][_R1_MARKET] = (
        before["pool_order"][_R1_MARKET] + [_r1_pool_entry(before, _R1_B[0])]
    )
    after = _recompute_evidence(after)
    after["committed_bytes"] = before["committed_bytes"] + _R1_EACH * 2
    _require_no_progress_rollback(before, after, "U13")      # 不抛即通过


def test_r1_u14_identical_recopy_with_zero_added_still_passes():
    """U14 · 重拷成功那一格：记录逐字相同 ⇒ added = 0，而 nb > ob —— 必须放行。

    这是 D7 的 S2-F38 悬案（「能否收紧成严格相等」答否）。本 PR 只收紧
    `scoped_removed` 那一格，**不得**误伤这一格。
    """
    before = _r1_base()
    after = _r1_copy.deepcopy(before)                 # files 一字不改
    after["committed_bytes"] = before["committed_bytes"] + 140
    _require_no_progress_rollback(before, after, "U14")      # 不抛即通过
```

- [ ] **Step 2：跑这 5 条，确认它们现在就是绿的**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q -k "r1_u5 or r1_u6 or r1_u7 or r1_u13 or r1_u14" -v
```

Expected: **5 passed**。
⚠️ 若任何一条红，**停下来**——说明我对现状的理解有误，不要改产品代码去迁就它。

- [ ] **Step 3：跑单文件全量，确认没碰坏邻居**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q -rs
```

Expected: **386 passed / 0 skipped**（基线 381 + 新增 5）。

- [ ] **Step 4：提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes"
git add backend/tests/test_qmt_manifest.py
git commit -m "test(R1): 先钉住五格现状（未声明回退/部分移除/没退游标/正常提交/重拷成功）

这五条在改动前就应当全绿，是后面三个任务「没误伤邻居」的基准。
U14 尤其关键：它是 D7 的 S2-F38 悬案（≥ 不可收紧），本 PR 只收紧
scoped_removed 那一格，不得误伤它。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2：R2 + R3（恢复时必须恰好退还，且不得为负）

**Files:**
- Modify: `backend/qmt_manifest.py:1546-1575`
- Modify: `backend/tests/test_qmt_manifest.py`（接着 Task 1 的那一节往下写）

**Interfaces:**
- Consumes: Task 1 的 `_r1_base()`、`_r1_remove_stock()`、`_r1_scope()`
- Produces: 改造后的 `committed_bytes` 判据块；Task 3 在同一块里加 R4

- [ ] **Step 1：写失败的测试（U1–U4、U11、U12）**

追加到 `backend/tests/test_qmt_manifest.py`：

```python
def test_r1_u1_recovery_with_exact_refund_passes():
    """U1 · 恢复 + 恰好退还 —— 这是**今天被拒**的那一格，修好后必须放行。"""
    before = _r1_base()
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    assert removed == _R1_EACH * 2, "夹具自检：该股应占两条共 366 字节"
    assert after["committed_bytes"] == before["committed_bytes"] - removed
    _require_no_progress_rollback(before, after, "U1",
                                  recovery=_r1_scope(before))   # 不抛即通过


def test_r1_u2_recovery_without_refund_rejected():
    """U2 · 恢复但**不退还**（今天的行为）—— 修好后必须拦。"""
    before = _r1_base()
    after, _removed = _r1_remove_stock(before, _R1_A[0], refund=False)
    with pytest.raises(ManifestInvalidError, match="恰好退还"):
        _require_no_progress_rollback(before, after, "U2",
                                      recovery=_r1_scope(before))


def test_r1_u3_recovery_refunding_one_byte_too_much_rejected():
    """U3 · 多退 1 字节 —— 等式的下侧要钉住。"""
    before = _r1_base()
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    after["committed_bytes"] -= 1
    with pytest.raises(ManifestInvalidError, match="恰好退还"):
        _require_no_progress_rollback(before, after, "U3",
                                      recovery=_r1_scope(before))


def test_r1_u4_recovery_refunding_one_byte_too_little_rejected():
    """U4 · 少退 1 字节 —— 等式的上侧要钉住。"""
    before = _r1_base()
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    after["committed_bytes"] += 1
    with pytest.raises(ManifestInvalidError, match="恰好退还"):
        _require_no_progress_rollback(before, after, "U4",
                                      recovery=_r1_scope(before))


def test_r1_u11_refund_down_to_exactly_zero_passes():
    """U11 · 退还后恰好为 0 —— 边界，0 合法。"""
    before = _r1_base()
    before["committed_bytes"] = sum(f["bytes"] for f in before["files"])
    # 这份账本的 committed_bytes 低于固有下界，固有检查会先拦；
    # 故本例直接对转移守卫下断言，不走端到端。
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    assert after["committed_bytes"] == 0
    _require_no_progress_rollback(before, after, "U11",
                                  recovery=_r1_scope(before))   # 不抛即通过


def test_r1_u12_refund_that_would_go_negative_rejected():
    """U12 · 账本已损坏（ob < removed），退还会变负 —— 必须拦。"""
    before = _r1_base()
    before["committed_bytes"] = _R1_EACH            # 比该股两条之和还小
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    assert after["committed_bytes"] < 0, "夹具自检：这份账本退还后应为负"
    with pytest.raises(ManifestInvalidError, match="不得为负"):
        _require_no_progress_rollback(before, after, "U12",
                                      recovery=_r1_scope(before))
```

- [ ] **Step 2：跑它们，确认全红**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q \
  -k "r1_u1 or r1_u2 or r1_u3 or r1_u4 or r1_u11 or r1_u12" -v
```

Expected: **6 failed**。
- U1 / U11 应报「committed_bytes 从 … 变成 … 它是累计量，调小…」
- U2 / U3 / U4 / U12 应报 `DID NOT RAISE` 或匹配不上 `恰好退还` / `不得为负`

⚠️ **若出现 `no tests ran`，不算红**——那是选择器没选中任何用例，必须先修 `-k` 表达式
（本仓栽过这个假绿）。

- [ ] **Step 3：改产品代码**

把 `backend/qmt_manifest.py` 现有的这一段（起于 `ob = _int_or_none(...)`，止于
`added` 那条 `raise` 的右括号）：

```python
    ob = _int_or_none(previous.get("committed_bytes"))
    if ob is not None:
        nb = _int_or_none(payload.get("committed_bytes"))
        if nb is None or nb < ob:
            raise ManifestInvalidError(
                f"{where} 会让 committed_bytes 从 {ob} 变成 "
                f"{payload.get('committed_bytes')!r}——它是累计量，"
                "调小、删掉或换成别的类型都等于绕开 --max-bytes 这条硬上限。"
            )
```

替换为（**只在开头插入退款分支，原有两条判据整体挪进 `else`，一字不改**）：

```python
    ob = _int_or_none(previous.get("committed_bytes"))
    if ob is not None:
        nb = _int_or_none(payload.get("committed_bytes"))
        # ⚠️ **崩溃恢复第③档必须退还被移除记录的字节**（R1，2026-10-01）：
        # 不退还时，重拉同一只股会被下面那条 `added` 判据算成「新增」，
        # 于是每崩一次就多烧一份预算（实测 366 → 706 → 1046，而盘上恒 366），
        # 最终以**虚假的 --max-bytes 触顶**结束运行 —— 一次基础设施故障
        # 被记成一次正常结束。
        # 口子挂在既有的 `scoped_removed` 上（它已保证：声明了 RecoveryScope、
        # 锚点与冻结名单对得上、该股 files 与池条目一起消失），**不另造旁路**。
        if scoped_removed:
            removed_bytes = 0
            for key, rec in prev_files.items():
                if key not in new_files:
                    b = _int_or_none(rec.get("bytes"))
                    if b is not None:
                        removed_bytes += b
            if nb is None:
                raise ManifestInvalidError(
                    f"{where} 崩溃恢复没有给出合法的 committed_bytes —— "
                    "恢复必须**恰好退还**被移除记录的字节数，缺了它无从比较。"
                )
            if nb < 0:
                raise ManifestInvalidError(
                    f"{where} 崩溃恢复把 committed_bytes 退成了 {nb}——"
                    "累计量**不得为负**。出现这种值说明上一份账本已经损坏"
                    f"（ob={ob}，被移除记录合计 {removed_bytes} 字节）。"
                )
            if nb != ob - removed_bytes:
                raise ManifestInvalidError(
                    f"{where} 崩溃恢复移除了合计 {removed_bytes} 字节的 files "
                    f"记录，而 committed_bytes 从 {ob} 变成 {nb}——恢复必须"
                    f"**恰好退还**这些字节（应为 {ob - removed_bytes}）。"
                    "多退会让 --max-bytes 失守，少退会让同一只股每崩一次"
                    "就多烧一份预算。"
                )
        else:
            if nb is None or nb < ob:
                raise ManifestInvalidError(
                    f"{where} 会让 committed_bytes 从 {ob} 变成 "
                    f"{payload.get('committed_bytes')!r}——它是累计量，"
                    "调小、删掉或换成别的类型都等于绕开 --max-bytes 这条硬上限。"
                )
```

然后把紧随其后的 `added` 计算与那条 `raise`（现 `:1555-1575`）**整体缩进一级**，
使它们落在上面那个 `else:` 里面。缩进后那段应为：

```python
            # ⚠️ **只拦「减少」不够**（codex R14 [high]）：**加了文件却原地不动**
            # 照样通过 —— 下一次运行从一个被低估的累计值起步，突破 --max-bytes
            # 这条硬上限，最坏把仅约 30 GiB 的可用空间写满（本机复现：新增 246 万
            # 字节而累计值纹丝不动）。
            # ⚠️ 判据取「**至少涨够新增文件的字节数**」而非严格相等：
            # spec 未定 committed_bytes 计不计失败 `.part` 的字节（5o 只说
            # `--max-bytes` 是逐块扣减的流式上限），严格相等会把那种合法记账判死。
            added = 0
            for key, rec in new_files.items():
                if key not in prev_files:
                    b = _int_or_none(rec.get("bytes"))
                    if b is not None:
                        added += b
            _ = added                    # 下面用
            if added and nb < ob + added:
                raise ManifestInvalidError(
                    f"{where} 新增了合计 {added} 字节的 files 记录，而 "
                    f"committed_bytes 只从 {ob} 涨到 {nb}——累计量必须至少涨够"
                    "新增文件的字节数，否则下一次运行会从一个被低估的总数起步，"
                    "突破 --max-bytes 硬上限。"
                )
```

- [ ] **Step 4：跑那 6 条，确认全绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q \
  -k "r1_u1 or r1_u2 or r1_u3 or r1_u4 or r1_u11 or r1_u12" -v
```

Expected: **6 passed**。

- [ ] **Step 5：跑后端全套，确认没碰坏任何邻居**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/ -q -rs
```

Expected: **1631 passed / 0 skipped**（基线 1620 + Task 1 的 5 + 本任务的 6）。
⚠️ 出现任何 failed 或 skipped 都要停下查清楚，不许继续。

- [ ] **Step 6：提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes"
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "fix(R1): 崩溃恢复必须恰好退还被移除记录的字节（R2 + R3）

committed_bytes 判据分成两支：scoped_removed 为假时原样保留现状；
为真时要求 nb 恰好等于 ob - removed_bytes，且不得为负。
口子挂在既有的 scoped_removed 上，不另造旁路；removed_bytes 由前后两份
files 的差集算出，不依赖调用方自报，所以这个口子不是可滥用的旁路。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3：R4（恢复提交不得同时新增记录）

spec §2.2b：`scoped_removed` 只检查**目标股**完整消失，守卫并不禁止同时新增别的股。
实测（抬高 1000 万余量以排除固有下界代拦）：那种形状**现有守卫是允许的** ⇒
Task 2 的等式会让新增那只股**完全不计账**。本任务堵上它。

**Files:**
- Modify: `backend/qmt_manifest.py`（Task 2 新加的 `if scoped_removed:` 块内，最前面）
- Modify: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: Task 1 的辅助函数；Task 2 的 `if scoped_removed:` 分支
- Produces: R4 判据

- [ ] **Step 1：写失败的测试（U15、U16）**

```python
def test_r1_u15_recovery_that_also_adds_another_stock_rejected():
    """U15 · 恢复提交里**完整移除 A 的同时新增 B** —— 必须拦（R4）。

    ⚠️ 夹具把 committed_bytes 抬高 1000 万：这样「被拦住」只可能是 R4 干的，
    不会是固有下界检查代为拦截（否则这条用例测不到它要测的判据）。
    """
    before = _r1_base(headroom=10_000_000)
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    after["files"] = after["files"] + _r1_recs(*_R1_B)
    after["pool_order"][_R1_MARKET] = (
        after["pool_order"][_R1_MARKET] + [_r1_pool_entry(after, _R1_B[0])]
    )
    after = _recompute_evidence(after)
    after["committed_bytes"] = before["committed_bytes"] - removed
    with pytest.raises(ManifestInvalidError, match="只许移除"):
        _require_no_progress_rollback(before, after, "U15",
                                      recovery=_r1_scope(before))


def test_r1_u16_recovery_adding_another_stock_rejected_even_if_paid_for():
    """U16 · 同 U15，但把 B 的字节补上 —— **照样拦**。

    理由：恢复提交一律不许新增，否则 R2 的等式就不再可机械检验
    （无法区分「退还了多少」与「新增补了多少」）。
    """
    before = _r1_base(headroom=10_000_000)
    after, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    added_recs = _r1_recs(*_R1_B)
    after["files"] = after["files"] + added_recs
    after["pool_order"][_R1_MARKET] = (
        after["pool_order"][_R1_MARKET] + [_r1_pool_entry(after, _R1_B[0])]
    )
    after = _recompute_evidence(after)
    after["committed_bytes"] = (before["committed_bytes"] - removed
                                + sum(r["bytes"] for r in added_recs))
    with pytest.raises(ManifestInvalidError, match="只许移除"):
        _require_no_progress_rollback(before, after, "U16",
                                      recovery=_r1_scope(before))
```

- [ ] **Step 2：跑它们，确认全红**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q -k "r1_u15 or r1_u16" -v
```

Expected: **2 failed**（U15 报 `DID NOT RAISE`；U16 可能匹配不上 `只许移除`）。
⚠️ `no tests ran` 不算红。

- [ ] **Step 3：加 R4 判据**

在 Task 2 加的 `if scoped_removed:` 块**最前面**（`removed_bytes` 计算之前）插入：

```python
            # ⚠️ **退款分支必须禁止同时新增**（R4，codex 2026-10-01 [medium]）：
            # `scoped_removed` 只保证**目标股**完整消失，files 守卫并不禁止
            # 新增别的键、pool_order 也允许追加。若不禁，下面那条等式会让新增
            # 那些记录的字节**完全不计账**（本机复现：余量 1000 万时固有下界
            # 也拦不住）—— 那就是一条记账旁路。
            added_in_recovery = 0
            for key, rec in new_files.items():
                if key not in prev_files:
                    b = _int_or_none(rec.get("bytes"))
                    if b is not None:
                        added_in_recovery += b
            if added_in_recovery:
                raise ManifestInvalidError(
                    f"{where} 崩溃恢复提交里**只许移除**，不许同时新增 files "
                    f"记录（本次新增了合计 {added_in_recovery} 字节）。"
                    "请把新增放到另一次提交，好让它的字节被正常计账。"
                )
```

- [ ] **Step 4：跑那 2 条，确认全绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q -k "r1_u15 or r1_u16" -v
```

Expected: **2 passed**。

- [ ] **Step 5：跑后端全套**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/ -q -rs
```

Expected: **1633 passed / 0 skipped**。

- [ ] **Step 6：提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes"
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "fix(R1): 退款分支禁止同时新增记录（R4）—— 堵一条记账旁路

scoped_removed 只保证目标股完整消失，守卫并不禁止同一次提交新增别的股。
不禁的话 R2 的等式会让新增那些记录的字节完全不计账（实测余量 1000 万时
固有下界也拦不住）。U15/U16 的夹具特意抬高余量，确保拦住它的是 R4 本身。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4：端到端回归 —— R1 缺陷本身的钉子

前三个任务测的是单次转移。本任务测**完整的「崩 → 重拉 → 再崩 → 再重拉」循环**，
直接钉住 R1 这个缺陷：修复前每轮最小可接受值会 +366，修复后恒定不变。

**Files:**
- Modify: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: Task 1 的辅助函数；Task 2/3 的判据
- Produces: 无（终端用例）

- [ ] **Step 1：写用例（U8、U9、U10）**

```python
def _r1_readd(m_removed, base_full, committed):
    """重拉：把 A 的两条记录与池条目加回来、游标推回去，committed_bytes 设为给定值。"""
    m3 = _r1_copy.deepcopy(m_removed)
    m3["files"] = _r1_copy.deepcopy(base_full["files"])
    m3["pool_order"] = _r1_copy.deepcopy(base_full["pool_order"])
    m3["cursor"] = _r1_copy.deepcopy(base_full["cursor"])
    m3 = _recompute_evidence(m3)
    m3["committed_bytes"] = committed
    return m3


def _r1_min_acceptable_on_readd(m_removed, base_full, lo, hi):
    """扫描 [lo, hi]，返回重拉时最小可接受的 committed_bytes（没有则 None）。"""
    for cand in range(lo, hi + 1):
        try:
            _require_no_progress_rollback(
                m_removed, _r1_readd(m_removed, base_full, cand), "扫描")
            return cand
        except ManifestInvalidError:
            continue
    return None


def test_r1_u8_readd_after_refund_accepts_the_original_total():
    """U8 · 恢复（已退还）后重拉，nb = ob —— 必须放行。"""
    before = _r1_base()
    ob = before["committed_bytes"]
    removed_m, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    _require_no_progress_rollback(
        removed_m, _r1_readd(removed_m, before, ob), "U8")      # 不抛即通过


def test_r1_u9_readd_one_byte_below_the_original_total_rejected():
    """U9 · 重拉时 nb = ob - 1 —— 仍受「至少涨够新增」约束，必须拦。"""
    before = _r1_base()
    ob = before["committed_bytes"]
    removed_m, removed = _r1_remove_stock(before, _R1_A[0], refund=True)
    with pytest.raises(ManifestInvalidError):
        _require_no_progress_rollback(
            removed_m, _r1_readd(removed_m, before, ob - 1), "U9")


def test_r1_u10_repeated_crash_and_readd_does_not_inflate_the_budget():
    """U10 · **R1 缺陷的直接回归钉**：连续两轮「崩 → 重拉」，预算不得被放大。

    修复前：最小可接受值 ob → ob+366 → ob+732（实测 2400286 / 2400652）。
    修复后：两轮都恒等于 ob。
    """
    before = _r1_base()
    ob = before["committed_bytes"]
    per_stock = _R1_EACH * 2
    cur = before
    seen = []
    for _ in range(2):
        removed_m, removed = _r1_remove_stock(cur, _R1_A[0], refund=True)
        _require_no_progress_rollback(cur, removed_m, "U10 恢复",
                                      recovery=_r1_scope(cur))
        lo = removed_m["committed_bytes"]
        got = _r1_min_acceptable_on_readd(removed_m, before,
                                          lo, lo + per_stock + 3)
        assert got is not None, "重拉找不到任何可接受的 committed_bytes"
        seen.append(got)
        cur = _r1_readd(removed_m, before, got)
    assert seen == [ob, ob], (
        f"预算被放大了：两轮最小可接受值 {seen}，应当都等于 {ob}。"
        f"若出现 {[ob, ob + per_stock]} 这种递增，说明退还没生效。"
    )
```

- [ ] **Step 2：跑它们**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/test_qmt_manifest.py -q -k "r1_u8 or r1_u9 or r1_u10" -v
```

Expected: **3 passed**（Task 2/3 已经把判据改好，这三条应当直接绿）。
⚠️ 若 U10 红且断言信息显示 `[ob, ob+366]`，说明退还没生效，回头查 Task 2。

- [ ] **Step 3：跑后端全套**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes/backend"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
PYTHONDONTWRITEBYTECODE=1 "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python" \
  -m pytest tests/ -q -rs
```

Expected: **1636 passed / 0 skipped**。

- [ ] **Step 4：提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes"
git add backend/tests/test_qmt_manifest.py
git commit -m "test(R1): 端到端回归 —— 连崩两次重拉，预算不再被放大

U10 是 R1 缺陷的直接回归钉：修复前最小可接受值 ob → ob+366 → ob+732，
修复后两轮都恒等于 ob。断言信息里写明了「若出现递增说明退还没生效」。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5：把契约里的 R1 标为已闭合

**Files:**
- Modify: `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`（§3「已登记的阻断级残留 R1」）

**Interfaces:**
- Consumes: 无
- Produces: 无

- [ ] **Step 1：在 §3 标题下方插入闭合说明**

在 `## 3. 已登记的阻断级残留 R1` 这一行的**下一行**插入：

```markdown
> **✅ 已闭合（2026-10-01）**：由独立 PR `fix/qmt-r1-committed-bytes-refund` 修复 ——
> 崩溃恢复第③档必须**恰好退还**被移除记录的字节（R2），且退款分支**不许同时新增**
> 记录（R4）。设计见 `docs/superpowers/specs/2026-10-01-qmt-r1-committed-bytes-refund-design.md`。
> 本节以下文字保留为**缺陷现场记录**，不再描述现行行为。
```

- [ ] **Step 2：确认没动别处**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes"
echo "branch=$(git rev-parse --abbrev-ref HEAD) HEAD=$(git rev-parse --short HEAD)"
git diff --stat docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md
```

Expected: 只有该文件，且 `1 file changed, 5 insertions(+)`（只增不删）。

- [ ] **Step 3：提交**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-r1-committed-bytes"
git add docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md
git commit -m "docs: S4a 契约 §3 的残留 R1 标为已闭合，指向本 PR

原文保留为缺陷现场记录，只在标题下加一段闭合说明。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## 收尾验收（控制者亲手跑，不采信 subagent 报的数字）

对应 spec §4。每条命令都要打印 `branch` 与 `HEAD`。

- [ ] **A1 · 单文件**：`pytest tests/test_qmt_manifest.py -q -rs` ⇒ **397 passed / 0 skipped**
      （基线 381 + U1–U16 共 16 条）
- [ ] **A2 · 全套**：`pytest tests/ -q -rs` ⇒ **1636 passed / 0 skipped**（基线 1620 + 16）
- [ ] **A3 · 变异验证**：R1、R2 的等式两侧、R3、R4 共 **5 条**判据逐条改反，
      每条至少让一个用例变红。纪律见 spec §4：
      - 按判据枚举不按语法枚举；变异必须落在该判据本身
        （把 R2 的 `!=` 改成 `<`、改成 `>`；把 `removed_bytes` 的求和改成只数条数；
        把 R4 的 `if added_in_recovery:` 改成 `if False:`；把 R3 的 `nb < 0` 改成 `nb < -1`）
      - 每次变异前后清 `__pycache__`，带 `PYTHONDONTWRITEBYTECODE=1`
      - 把邻居用例 deselect 掉单独跑目标用例
      - 还原后用 `sha256` 与变异前逐字比对
- [ ] **A4 · 探针重跑**：`probe_r1_fix.py` 的「退还」那一列从「⛔被拒」翻为放行，
      且两轮最小可接受值都等于 `ob`

⚠️ **codex 对 spec 的 approve 自陈 "Runtime correctness remains unverified until
implementation"** —— 它只审了设计、没跑任何代码。上面四条是控制者的责任，不得省。

---

## Self-Review（写完计划后自查）

**1. Spec 覆盖**：
- spec §2.1 恢复时退还 → Task 2
- spec §2.2 R1 → Task 2 Step 3 的 `else` 分支（原文一字不改）
- spec §2.2 R2 → Task 2；R3 → Task 2；R4 → Task 3
- spec §2.3 算术 → Task 4 的 U8/U10
- spec §2.4 明确不做 → Global Constraints 的「不碰」与「不新增字段」
- spec §3 U1–U16 → Task 1（U5/U6/U7/U13/U14）、Task 2（U1–U4/U11/U12）、
  Task 3（U15/U16）、Task 4（U8/U9/U10）—— **16 条全部有归属**
- spec §4 A1–A4 → 收尾验收四条
- spec §5 基线 → Global Constraints
- spec §6 交付物三个文件 → Task 2/3（`qmt_manifest.py`）、Task 1–4（测试）、Task 5（契约）

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」；每个代码步骤都给了可直接粘贴的真实代码。

**3. 类型一致性**：`_r1_base(headroom=0)`、`_r1_recs(code, name, nbytes)`、
`_r1_pool_entry(m, code)`、`_r1_remove_stock(m, code, refund) -> (m, removed)`、
`_r1_scope(m, code)`、`_r1_readd(m_removed, base_full, committed)`、
`_r1_min_acceptable_on_readd(m_removed, base_full, lo, hi)` —— 全部在 Task 1 / Task 4
定义，后续调用的参数名与个数逐一核对一致。
产品代码侧新增的局部变量 `removed_bytes`、`added_in_recovery` 不与现有 `added` 重名。
