# 修复轮 10 报告 —— codex R7 的 [high]：在途标记的耐久屏障

**分支 / BASE 自证**（每条闸门命令都带着打印，下文逐条贴出）：

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
3499287a
```

---

## 一、做了什么（一句话）

在途标记 `.inflight.json` 的**创建**从普通 `fsync` 升成 `full_sync=True`
（内容与目录项各一道 `full_fsync`），并把「为什么此前那条理由不成立」写进
代码 docstring 与契约，配两条测试钉住**次序**与**参数**，四道定向变异自证。

---

## 二、四层各走一遍（契约 / 做法 / 测试 / 验收门）

| 层 | 落在哪 | 内容 |
|---|---|---|
| **做法** | `backend/qmt_fetch.py` `_write_inflight_marker` | 传 `full_sync=True`；docstring 改写成新结论 + 为什么推翻旧理由 |
| **做法（回声）** | 同文件 3 处 | 模块 docstring:61、`_inflight_marker_on_disk` 两支、`copy_stock` docstring —— 同一句话的另外三份副本里「那次 `fsync(staging)`」改成 `full_fsync(staging)` |
| **契约** | `§5` 覆盖表 | 新增 **5 行**（不是 2 行，见第四节） |
| **契约** | `D6` | 新增「标记自己的耐久等级」段 + **代价**段（每股 1 次 → 2 次）|
| **契约** | `§4` 交接 | 新增**第 17 条**：删标记那一侧本片没动，S4b 必须补的那条测试 |
| **验收门** | `D6` 末尾「**验收**」两条 | ①次序（不得退化成「调过 full_sync」）②参数（判据在 `qmt_fsroot` 接口层，不得按 `fcntl` 判）；并在 `§5` 表里把大 spec `§9` 那条会**反向加固**的验收项列名除名 |
| **测试** | `backend/tests/test_qmt_fetch.py` | 新增 2 条；既有 1 条的注入点跟着换（见第五节）；1 处注释回声订正 |

---

## 三、改动清单

```
$ git diff --stat 3499287a
 backend/qmt_fetch.py                               |  48 ++++--
 backend/tests/test_qmt_fetch.py                    | 153 ++++++++++++++++++++-
 .../specs/2026-09-18-qmt-4b-s4a-contract.md        |  56 +++++++-
 3 files changed, 238 insertions(+), 19 deletions(-)
```

禁改五模块自证（**空**）：

```
$ git diff --stat 3499287a -- backend/qmt_fsroot.py backend/qmt_manifest.py \
      backend/qmt_pool.py backend/qmt_ingest.py backend/qmt_normalize.py
（无输出）
```

大 spec 自证（**空**，本片对它只在契约里列名，零删改）：

```
$ git diff --stat 3499287a -- docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md
（无输出）
```

`full_sync=True` 是 `qmt_fsroot` 的**既有参数**，未动该模块一个字。

---

## 四、§5 覆盖表为什么是 5 行而不是 2 行

任务书点名两条。按「**按字面量穷举后逐条定性**」的规矩，我对大 spec 全文枚举了
`fsync` / `F_FULLFSYNC` / `full_sync` 的**全部 53 处**、`inflight.json` 的**全部 23 处**，
逐处定性，另找出**三条**把标记钉成普通 `fsync` 的语句：

| # | 位置 | 为什么按概念搜词找不到它 |
|---|---|---|
| 1 | §4.5:468 五步序列第 2 条 | 任务书已点名 |
| 2 | §4.5:694 耐久闭合清单 | 任务书已点名 |
| **3** | **§4.5:676-677 O4-F11 定案**：「…两处改用 `F_FULLFSYNC`…**其余落地点保留 `fsync`**」 | **整句一个 `inflight` 字样都没有** —— 它用「其余落地点」这个**补集**指代标记 |
| **4** | **§9:1099 回归钉**：「**其余落地点断言仍是 `os.fsync`**」 | 同上，且它是一条**验收项** —— 照字面执行会要求造一条「标记必须走普通 `os.fsync`」的断言，**正是 §9-5 那次「把唯一没点名的副本反向加固」的第二次** |
| **5** | **§11 O4 轮缺陷表 O4-F11 行**：「…**其余保留 `fsync`**」 | 同一事实的第三份副本（历史结论行）；列名是因为「每份副本都要一起订正」 |

⚠️ 第 3、4 两条如果漏掉，后果不对称：第 3 条只是文档不一致，**第 4 条会让验收门
反过来要求标记走普通 `fsync`**。

**反方向也查了**（「哪些地方是上限、哪些只是下限」）：全仓用 `/usr/bin/grep`
（不是 shell 那个遵守 `.gitignore` 的 `grep`）扫 `其余落地点` / `保留 \`fsync\`` /
`仍是 \`os.fsync\``，**只有大 spec 那两处是上限语句**，两条都已列名。
`2026-07-27-qmt-plan4c-...md` §9-5m 与 `2026-08-21-...slice-map.md`
是**下限**（「命名空间改动之后必须 `fsync` 其所在目录」），`full_fsync` 满足它，
不构成冲突；`2026-07-26-qmt-plan4-pilot-shipment-design.md` 里那两份副本**已作废**
（文件头第一行即「⚠️ 本文件已切分，不再作为实施依据」）。

---

## 五、测试

### 5.1 新增两条（macOS 与 Linux 都真跑，**零 `skipif`**）

- `test_marker_full_fsync_barrier_precedes_first_part_to_final_replace`
  —— **次序**：打桩 `qmt_fsroot.full_fsync` 与 `os.replace`，按 fd 指向的对象类型
  把两道屏障分成「内容」与「目录项」，断言**第一次** `.part → final` 的 `os.replace`
  **之前**那一段里两者各恰好一次，且内部次序是「内容屏障 → 发布 → 目录项屏障」，
  目录项那道下在 `stg_fd` 上。
- `test_write_inflight_marker_asks_fsroot_for_full_sync`
  —— **参数**：打桩 `qmt_fetch.atomic_write_json`，断言写 `INFLIGHT` 那次调用的
  关键字参数里 `full_sync is True`。判据放在 **`qmt_fsroot` 接口层**，不按 `fcntl` 判
  （`full_fsync` 在没有 `F_FULLFSYNC` 的平台退回 `os.fsync`，按 `fcntl` 判会在
  Linux 上恒假、Mac 上恒真，两边各自失去判别力）。

### 5.2 既有一条**必须**跟着改（否则静默变成假绿）

`test_copy_stock_keeps_everything_when_fsync_fails_after_marker_publication`
注入的是 `qmt_fsroot.fsync_dir`。标记改走 `full_sync=True` 之后那条路径不再调
`fsync_dir` ⇒ **什么都没注入、`copy_stock` 正常跑完**。已把注入点换成
`qmt_fsroot.full_fsync`，并按 fd 类型只在**目录项那次**（排在 `os.replace` 之后）
炸，保留它原有的「炸的那一刻标记必须已在盘上」前提断言。

### 5.3 闸门

```
$ git rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD
qmt-4b-s4a
3499287a
$ PYTHONDONTWRITEBYTECODE=1 ../.venv/bin/python -m pytest tests/ -q -rs
1596 passed in 38.69s
```

BASE 是 1594 passed / 0 skipped；交付 **1596 passed / 0 failed / 0 skipped**（+2 条新测试）。

其它不变量：`argparse` 出现 **0** 次；异常三族与 `reason` 闭集 4 个
——`git diff 3499287a -- qmt_fetch.py` 里没有任何一行触及 `class` 定义、
`raise StockCopyFailed(` 或四个 `reason` 字面量（只有新写的散文提到 `untracked_target_file`）。

---

## 六、变异自证

每条：锚点 `assert count == 1`；前后各清 `__pycache__`；
`PYTHONDONTWRITEBYTECODE=1`；**邻居 deselect，只跑目标那一条**；
还原后 sha256 与原文件逐字相同。

三份文件的变异前基线：

```
0e858b1ffb6746b547bff300f7496f8cf3bde4e8b4c6f95e28c1d667b35059a5  qmt_fetch.py
71d2ef1e6cd9e1ba832c3a811bacba632a2a7ad5e18af12aa4e52bcbe651f4d6  qmt_fsroot.py
```

### M1（最关键）：`full_sync=True` → `False`，只跑**次序**那一条

```
apply ok · count == 1
E       AssertionError: 第一次 `.part → final` 之前，标记**内容**那道 `full_fsync` 必须已经下过（且恰好一次）——实测那一段是 ['replace_marker']，完整事件 [('replace_marker', 12), ('replace_final', 14), ('replace_final', 14), ('full_fsync_file', 13), ('full_fsync_dir', 12)]
E       assert 0 == 1
E        +  where 0 = <built-in method count of list object at 0x109bd4b80>('full_fsync_file')
FAILED tests/test_qmt_fetch.py::test_marker_full_fsync_barrier_precedes_first_part_to_final_replace
1 failed in 0.45s
```

⚠️ 这次失败的事件表**顺带证实了那条注释不是主张**：`commit_stock` 自己那两道
`full_fsync` 真的排在两次 `replace_final` **之后** ⇒ 若判据退化成「全程调过
`full_sync`」，它会被那两道满足而恒绿。

### M2：删掉 `full_sync=True` 这个关键字实参，只跑**参数**那一条

```
apply ok · count == 1
E       AssertionError: 在途标记必须以 `full_sync=True` 写下：它是契约 D6 的唯一授权凭据，耐久等级不得低于它要授权去删的那两条 final。实测这次调用的关键字参数是 {}
E       assert None is True
E        +  where None = <built-in method get of dict object at 0x10d9a9c80>('full_sync')
FAILED tests/test_qmt_fetch.py::test_write_inflight_marker_asks_fsroot_for_full_sync
1 failed in 0.35s
```

### M3：**只退目录项那一半**（`qmt_fsroot._atomic_write_bytes` 的 `full_fsync(dir_fd)` → `fsync_dir(dir_fd)`），只跑次序那一条

证明「内容」与「目录项」两半**各自独立**被钉住（S2-F53 登记过反方向的坑：
改名那道屏障自己就能满足只看「出现过」的断言）。

```
apply ok · count == 1
E       AssertionError: 第一次 `.part → final` 之前，标记**目录项**那道 `full_fsync` 必须已经下过（且恰好一次）——实测那一段是 ['full_fsync_file', 'replace_marker']，完整事件 [('full_fsync_file', 13), ('replace_marker', 12), ('replace_final', 14), ('replace_final', 14), ('full_fsync_file', 13)]
E       assert 0 == 1
E        +  where 0 = <built-in method count of list object at 0x10d884100>('full_fsync_dir')
FAILED tests/test_qmt_fetch.py::test_marker_full_fsync_barrier_precedes_first_part_to_final_replace
1 failed in 0.33s
```

⚠️ 这一档**临时改过 `qmt_fsroot.py`**（两处锚点各 count == 1），跑完即还原，
sha256 与基线逐字相同（见下）。交付 diff 对该文件为空。

### M4：**保留 `full_sync=True`，只把写标记挪到两次 final 替换之后**

这是钉「**相对次序**」而非「调过 full_sync」的那条定向变异。两条新测试分别跑：

```
apply ok · 两处锚点 count == 1
--- 次序那条（红）---
E       AssertionError: 第一次 `.part → final` 之前，标记**内容**那道 `full_fsync` 必须已经下过（且恰好一次）——实测那一段是 []，完整事件 [('replace_final', 14), ('replace_final', 14), ('full_fsync_file', 13), ('replace_marker', 12), ('full_fsync_dir', 12), ('full_fsync_file', 13), ('full_fsync_dir', 12)]
E       assert 0 == 1
FAILED tests/test_qmt_fetch.py::test_marker_full_fsync_barrier_precedes_first_part_to_final_replace
1 failed in 0.46s
--- 参数那条（绿）---
1 passed in 0.30s
```

**两条测试因此被证明不冗余**：M4 下参数那条恒绿，只有次序那条抓得到。

### 还原自证

```
$ diff baseline-sha256.txt after-sha256.txt
（无差异）
0e858b1ffb6746b547bff300f7496f8cf3bde4e8b4c6f95e28c1d667b35059a5  qmt_fetch.py
71d2ef1e6cd9e1ba832c3a811bacba632a2a7ad5e18af12aa4e52bcbe651f4d6  qmt_fsroot.py
43a866e597e8bfbaeb680eed468559e36cd185c852fcf6a468f66b69baa425da  tests/test_qmt_fetch.py
```

（`tests/test_qmt_fetch.py` 此后还有一处**注释回声**订正，见 §二，故最终 sha 与此不同；
变异只碰过 `qmt_fetch.py` 与 `qmt_fsroot.py`，两者均逐字还原。）

---

## 七、代价的两个口径（实测）

D6 里按大 spec 同口径记的是**落地点**：一只股由 1 处（`commit_stock`）变 2 处。
但 `F_FULLFSYNC` drain 的是**每一次调用**，而每个 `full_sync=True` 的落地点各下
**两道**屏障（内容 + 目录项）。打桩实测：一只股的 `full_fsync` **调用数由 2 变 4**
（变异 M1 与 M4 的事件表可直接数出来）。两个口径都已写进 D6 —— 代价挂在调用上、
大 spec 的预算挂在落地点上，只写一个会让下一次算账的人拿错乘数。

---

## 八、没做的事 / 疑虑

见返回值。
