# 冻结契约文本一致性（切片一 · 第 3a 片）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把两份根级权威文件里与 P1 新公式**直接矛盾**的那条规则（`global_index / end_global_index` 全周期严格递增）改写成按周期语义分流的表述，把冻结契约里另外三处仍写「第 1 代」的版本引用改成 `2` **且各带过渡态标注**，并加两条机械守卫把这两件事钉住。

**Architecture:** 纯文本改写 + 两条守卫。守卫落在 `backend/tests/` 下（后端 CI **无 paths 过滤器、每个 PR 都跑**），用 P2 已确立的 `REPO_ROOT` 方式读仓库根的 markdown。守卫①禁旧表述、守卫②断言「生产者已升第 2 代、App 读取端仍钉在 1」这个**有意的过渡态**——把它写成可断言的事实，而不是留成矛盾。

**Tech Stack:** Python 3.11 / pytest（`backend/tests/`，CI = `.github/workflows/backend-tests.yml`，Linux、零 skip）；markdown。

**Spec:** `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §3.3 的 **3b / 3b-2nd / 3b2 / 3c** 四行

---

## ⚠️ 先说切分：P3 必须拆成三片，本计划只做第一片

spec §3.3 剩余部分实测有 **7 个互不相干的子项**，远超本仓「每 PR ≤3 子项」的教训线，且其中一项要碰 `.github/workflows/`（本仓有**独立 push 仪式**）。⇒ 拆分如下：

| 片 | 范围 | 状态 |
|---|---|---|
| **P3a（本计划）** | 3b R03 改写 · 3b-2nd 孪生条款改写 · 3b2 三处版本引用 + 过渡态标注 · 3c 两条守卫 | 本计划 |
| P3b | `INSERT INTO training_sets` 补 `schema_version`（实测 10 处，含 `.github/workflows/schema-smoke.yml` 5 处 ⇒ **独立 push 仪式**）+ 按语句匹配的守卫 | 待写 |
| P3c | `CONTRACT_VERSION` `1.13`→`1.14`（5–9 项）· m01 治理矩阵 `user_version` 1→2 与触发条件扩写（第 4 项）· Mac 本地三个 v1 包作废 + 文案守卫 | 待写 |

⚠️ **P3a 单独可交付、CI 可全绿**，但它**只改文本与守卫，不改任何可执行逻辑**。

---

## Global Constraints

- ⛔ **不碰任何 App 逻辑**（`ios/**` 一行不改）。守卫**只读** `ios/` 下两处常量以断言「App 读取端仍钉在 1」。
- ⛔ **不碰** `backend/generate_training_sets.py`、`backend/sql/**`、`.github/workflows/**`。
- ⛔ **守卫①的判据不得写成裸「严格递增」**。实测作用域内有一条**合法且无关**的命中（`kline_trainer_modules_v1.4.md:723`「`ticket_index` 严格递增」，讲的是另一件事）；裸词判据会把它误报成违例，而实施者最省事的修法是**去改那条无关的行**。判据必须同时要求命中行含 `global_index`。
- ⛔ **守卫①的作用域不得写成「全仓」**。实测 `docs/superpowers/**` 下有 **19 个文件**逐字引用旧表述（历史记述，含本 spec 自己与 P1 的计划）、`ios/**` 下有 8+ 处「严格递增」讲的是完全无关的事（画线图标线宽、datetime 次序）。写全仓 ⇒ 守卫**恒红**，要它变绿只能删历史记述或改 App 源文件。
- ⛔ **3b2 三处必须同时改值与加标注**。只改值会让冻结契约声称「前后端共享 = 2」，而守卫②同时把「App 侧 = 1」认证为正确 —— **3b 反对留下 R03 的理由会被本片自己反向再造一次**。
- 后端 CI 是 **Linux 且零容忍 skip** ⇒ ⛔ 不得出现任何 `pytest.mark.skip` / `skipif` / `importorskip`。
- ⛔ 交付话术：可以说「冻结契约里与新公式矛盾的表述已订正」；**不得说**「手机能用了」「跨端契约已闭合」「版本已对齐」——`CONTRACT_VERSION` 仍是 `1.13`（归 P3c）、App 侧一行未改（归切片二）。

---

## 前置事实（全部本机实测于 `origin/main` = `60dff65`，⛔ 不得照抄，实施前请按命令复跑）

**F1 — 要改写的两条孪生条款，逐字命中 2 处、且判据必须带 `global_index`。**

```bash
grep -rn "严格递增" kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md docs/governance/ backend/ | grep -E "global_index"
```

实测 2 行：

```
kline_trainer_modules_v1.4.md:2302:| R03 | 后端 Index 预计算一致性 | P1 | global_index/end_global_index 严格递增 + 前后端 assert | B2/P3 |
kline_trainer_plan_v1.5.md:1285:3. **后端 Index 预计算**：global_index / end_global_index 必须严格递增；后端 assert + 前端 DEBUG 校验
```

同作用域内**不含** `global_index` 的命中（⛔ 判据必须放过它）：

```
kline_trainer_modules_v1.4.md:723:- **验收**：row count、时间连续性、ticket_index 严格递增
```

**F2 — 守卫作用域为何必须排除 `docs/superpowers/` 与 `ios/`。**

```bash
grep -rln "严格递增" docs/superpowers/ | wc -l      # → 20（历史记述；含本 spec、P1 计划与本片自己的计划）
grep -rn  "严格递增" ios/ | grep -v "/\.build/"     # ⛔ 不要加 head！见下
```

⛔⛔ **订正（最终评审 Important 1）**：上一版这里写「`ios/` 下 8+ 处主题全不相干」，**是错的** —— 我当时给 grep 加了 `head` 而**输出被截断**（本仓有成文教训：一致性扫描的 grep 输出绝不截断）。不截断后实测 `ios/` 的命中**分两类**：

- ⛔ **同一条规则，而且是生产代码**：`ios/Contracts/Sources/KlineTrainerPersistence/DefaultTrainingSetReader.swift:80` 的注释「校验 per-period endGlobalIndex 严格递增」，`:90-92` **就是执行它的那段代码**：

  ```swift
  if let prev = lastEnd[period], r.endGlobalIndex <= prev {
      throw AppError.persistence(.dbCorrupted)
  }
  ```

  ⇒ 它会**拒掉每一个第 2 代产物**（`monthly [0, 0, 17, 23]` 的 `0 <= 0` 当场抛错）。`:146` 还逐字引用 R03 原句作为依据。
  ⭐ **这是给切片二的关键事实**：App 侧至少有**两道**独立的拦路石 —— 除已知的「只认 `.sqlite` 成员」外，还有这道运行时的严格递增校验。
- ⚪ 其余（画线图标线宽、`datetime` 次序等）与本片不相干。

⇒ 结论（守卫作用域排除 `ios/`）**不变**，但**理由必须写对**：不是「都不相干」，而是「其中那条相干的属于切片二的范围，本片明令不碰 App」。

**F3 — 3b2 的三处版本引用现状。**

```bash
grep -n "user_version\|TRAINING_SET_SCHEMA_VERSION" kline_trainer_modules_v1.4.md
```

- `:146` —— 矩阵行 `| 训练组 SQLite \`PRAGMA user_version\` | \`1\` | 训练组 schema 结构变更；联动顶层 |`
- `:1882` —— `/// - expectedSchemaVersion: 预期 schema 版本（M0.1 TRAINING_SET_SCHEMA_VERSION = 1）`
- `:2239` —— `- [ ] \`TRAINING_SET_SCHEMA_VERSION = 1\` 双方共享常量`

⚠️ 顺带实测到一处**本片不改**的既有陈旧：`:144` 的矩阵写 `CONTRACT_VERSION | "1.5"`，而实际常量是 `"1.13"`。它自 v1.4 起就 stale，**不由本片引入** ⇒ ⛔ 不顺手改（范围蔓延；本仓有「别顺手修 stale 行」的成文教训）。

**F4 — 守卫②要断言的「App 读取端仍钉在 1」两处，spec 给的行号有一处已过期。**

```bash
grep -rn "TRAINING_SET_SCHEMA_VERSION = 1" ios/Contracts/Sources/
grep -n  "expectedSchemaVersion" ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingSessionCoordinator.swift
```

- `ios/.../DownloadAcceptance/DownloadAcceptanceRunner.swift:14` —— `public let TRAINING_SET_SCHEMA_VERSION = 1` ✅ spec 的 `:14` 正确
- `ios/.../TrainingEngine/TrainingSessionCoordinator.swift:1360` —— `try dbFactory.openAndVerify(file: file.localURL, expectedSchemaVersion: 1)`
  ⚠️ **spec 写的是 `:1307`，实测在 `:1360`**。且这两处**形状不同**：前者是常量定义，后者是**写死的字面量**（`:1358` 的注释解释了为什么硬编码）。⇒ 守卫必须**分别**断言，不能套同一个正则。

**F5 — spec 的 3d 项（三处验收 grep 锚）实测已由 P1 全部闭合，本片无事可做。**

```bash
grep -rn "PRAGMA user_version = 1\b" scripts/ docs/acceptance/     # → 无输出（P1 已改掉两处）
grep -n  "user_version" scripts/acceptance/plan_1f_m0_1_schema_versioning.sh   # → 无输出
```

⇒ spec 声称的第三处锚（`plan_1f_m0_1_schema_versioning.sh:48-50`「断言 m01 矩阵那行是 `1`」）**在该文件里根本不存在**。⇒ **3d 从本片移除**；m01 矩阵本身的值改动归 P3c 第 4 项。

**F6 — 基线。**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```

实测 **1394 passed / 0 failed / 0 skipped**（⚠️ 不是 1130 —— `db49f60..60dff65` 之间另有 #184 / #182 合入 main）。

---

## File Structure

| 文件 | 责任 | 本片动作 |
|---|---|---|
| `kline_trainer_modules_v1.4.md` | 根级冻结契约（模块册） | 改 `:2302` R03 正文 · `:146`/`:1882`/`:2239` 三处值 1→2 且各加过渡态标注 · 修订记录加一行 |
| `kline_trainer_plan_v1.5.md` | 根级冻结契约（计划册） | 改 `:1285` 孪生条款 · 修订记录加一行 |
| `backend/tests/test_frozen_contract_texts.py` | 两条守卫 | **新建** |
| `docs/acceptance/2026-09-06-trainingset-p3a-acceptance.md` | 非程序员验收清单（治理底线第 2 条） | **新建** |
| `docs/acceptance/2026-09-06-trainingset-p3a-mutation-log.md` | 变异验证记录 | **新建** |

⛔ 本片不新建也不修改任何其它文件。

---

## Task 1: 改写两条孪生条款（3b / 3b-2nd）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md:2302` + 修订记录
- Modify: `kline_trainer_plan_v1.5.md:1285` + 修订记录

**为什么必须改**：这两条是**同一条规则的两份权威表述**，现文都写「`global_index / end_global_index` 严格递增」。P1 落地后，非 `3m` 周期的 `end_global_index` **允许重复**（多根落在同一个 3 分钟刻上，例如本片 fixture 的 `monthly [0, 0, 17, 23]`）。不改它，后端第 2 代产物会在**两条互相矛盾的权威规则**下发布；日后任何照 R03 写的守卫会**把每个新产物都判死**。

- [ ] **Step 1: 改 `kline_trainer_modules_v1.4.md:2302`**

原文：

```
| R03 | 后端 Index 预计算一致性 | P1 | global_index/end_global_index 严格递增 + 前后端 assert | B2/P3 |
```

改为：

```
| R03 | 后端 Index 预计算一致性 | P1 | `3m`：`global_index == end_global_index == 行下标`，严格递增；**其它周期**：`global_index` 恒 NULL，`end_global_index` 逐根等于按 §2.1 datetime 标注语义反算的值（**允许重复**，但重复由反算式决定而非任意）+ 前后端 assert | B2/P3 |
```

⚠️ **不得**保留「全周期严格递增」这半句 —— 守卫①正是按它判违例。

- [ ] **Step 2: 改 `kline_trainer_plan_v1.5.md:1285`**

原文：

```
3. **后端 Index 预计算**：global_index / end_global_index 必须严格递增；后端 assert + 前端 DEBUG 校验
```

改为：

```
3. **后端 Index 预计算**：`3m` 的 global_index / end_global_index 等于行下标且严格递增；**其它周期** global_index 恒 NULL、end_global_index 逐根等于按 datetime 标注语义反算的值（**允许重复**）；后端 assert + 前端 DEBUG 校验
```

- [ ] **Step 3: 两份文件各加一行修订记录**

在各自的修订记录小节末尾追加（⛔ 只追加，不动既有行）：

```
- 2026-09-06（训练组切片一 P3a）：R03 / 「后端 Index 预计算」由「全周期严格递增」改写为按 `datetime` 标注语义分流 —— `3m` 仍严格递增，其它周期的 `end_global_index` 允许重复。依据 `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §2.1 / §2.2。
```

⚠️ 两份文件的修订记录小节标题不同，**先 grep 定位再追加**：

```bash
grep -n "^## .*修订\|^## .*变更记录\|^## .*Changelog" kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md
```

若某份文件**没有**修订记录小节，则**不新建**，改为在被修改行的紧邻位置加一句括注（并在报告里说明）。

- [ ] **Step 4: 核对旧表述在作用域内已清零**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -rn "严格递增" kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md docs/governance/ backend/ | grep -E "global_index"
```

Expected：**只剩改写后的新表述**（新表述里 `3m` 那半句仍含「严格递增」与 `global_index`，属**预期命中**）。⛔ 判绿读的是**命中行的内容**，不是「有没有输出」。

- [ ] **Step 5: Commit**

```bash
git add kline_trainer_modules_v1.4.md kline_trainer_plan_v1.5.md
git commit -m "docs(contract): R03 与孪生条款由「全周期严格递增」改写为按 datetime 语义分流（P3a Task 1）"
```

---

## Task 2: 三处版本引用改 2 且各带过渡态标注（3b2）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md:146` / `:1882` / `:2239`

**Interfaces:**
- Produces: 三处各含一段**统一措辞**的过渡态标注 —— Task 3 的守卫②要按它断言

**⛔ 为什么必须带标注**：`:2239` 的字面语义是「**双方**共享常量」。只把值改成 `2`，冻结契约就声称「前后端共享 = 2」，而守卫②同时把「App 侧 = 1」认证为正确 —— 谁拿冻结契约去写读取端就会直接写 `2`、越过切片次序；谁拿它去核 App 都会判 App「未同步」。

**统一标注措辞**（三处逐字一致，守卫按这段判）：

```
⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地
```

- [ ] **Step 1: 改 `:146`（矩阵行）**

```
| 训练组 SQLite `PRAGMA user_version` | `2` | 训练组 schema 结构变更**或字段语义变更导致新旧产物互不可读**；联动顶层（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地） |
```

- [ ] **Step 2: 改 `:1882`（Swift 文档注释的引述）**

```
    /// - expectedSchemaVersion: 预期 schema 版本（M0.1 TRAINING_SET_SCHEMA_VERSION = 2；⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地）
```

- [ ] **Step 3: 改 `:2239`（清单条目）**

```
- [ ] `TRAINING_SET_SCHEMA_VERSION = 2` 双方共享常量（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地；过渡态的权威定义见 `CONTRACT_VERSION 1.14 / 1.15`）
```

- [ ] **Step 4: 核对**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && grep -n "user_version\|TRAINING_SET_SCHEMA_VERSION" kline_trainer_modules_v1.4.md
```

Expected：`:146` / `:1882` / `:2239` 三行都出现 `2` **且**都含「App 侧仍为 1」。⛔ 其余行（`:130` / `:157` / `:727`）不含版本数值，**不动**。

- [ ] **Step 5: Commit**

```bash
git add kline_trainer_modules_v1.4.md
git commit -m "docs(contract): 冻结契约三处版本引用 1→2 并各带过渡态标注（P3a Task 2）"
```

---

## Task 3: 两条机械守卫（3c）

**Files:**
- Create: `backend/tests/test_frozen_contract_texts.py`

**⚠️ 本 Task 的红绿从哪来**：Task 1/2 已把文本改好，所以守卫**写完就是绿的**。它们是**防退化守卫**，RED 由 Task 4 的变异提供。每条断言都要能回答「**什么样的改动会让这条测试红？**」——答案分别是：把旧表述改回去（守卫①）、把三处值改回 1 或删掉标注（守卫②前半）、把 App 那两处从 1 改掉（守卫②后半）。

- [ ] **Step 1: 写守卫文件**

```python
# backend/tests/test_frozen_contract_texts.py
"""冻结契约文本的两条机械守卫（spec §3.3 3c）。

⭐ 本片处理的是一个**有意的过渡态**：生产者（后端）已升到第 2 代，而 App 读取端**仍钉在 1**
   —— 这不是没同步，是切片次序决定的。守卫②把它写成**可断言的事实**，而不是留成矛盾。
⛔ 本文件只**读** `ios/` 下两处常量，不改 App 一行。
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

MODULES = REPO_ROOT / "kline_trainer_modules_v1.4.md"
PLAN15 = REPO_ROOT / "kline_trainer_plan_v1.5.md"

# ── 守卫①作用域：**后端与治理文档**
# ⛔ 不得扩成全仓：
#   · `docs/superpowers/**` 下实测 19 个文件**逐字引用**旧表述（历史记述，含本片的 spec 与 P1 计划）
#   · `ios/**` 下实测 8+ 处「严格递增」讲的是完全无关的事（画线图标线宽、datetime 次序）
#   扩成全仓 ⇒ 守卫恒红，要它变绿只能删历史记述或改 App 源文件。
# 切片二把作用域扩到 `ios/`（spec §8）。
_SCOPE_FILES = [MODULES, PLAN15]
_SCOPE_DIRS = [REPO_ROOT / "docs" / "governance", REPO_ROOT / "backend"]

_OLD_WORDING = "严格递增"

# ⛔ 守卫**不扫自己**：本文件的 docstring 必须能**逐字引用**它所禁止的那句旧表述
# （不然它就没法说明自己在禁什么），于是天然满足「同行既有『严格递增』又有 global_index」。
# 用**解析后的自身路径**排除，⛔ 不按文件名字符串（改名后会静默重新自指、红得莫名其妙），
# ⛔ 也不整目录排除 `backend/tests/`（那等于把一整个目录永久移出作用域）。
_SELF = Path(__file__).resolve()


def _scope_lines():
    """作用域内所有 (相对路径, 行号, 行文本)。"""
    files = list(_SCOPE_FILES)
    for d in _SCOPE_DIRS:
        files += [p for p in d.rglob("*")
                  if p.is_file() and p.suffix in (".md", ".py", ".sql", ".sh")
                  and "__pycache__" not in p.parts]
    for p in files:
        if p.resolve() == _SELF:
            continue
        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for i, line in enumerate(text.splitlines(), start=1):
            yield p.relative_to(REPO_ROOT).as_posix(), i, line


def test_old_all_periods_strictly_increasing_wording_is_gone():
    """守卫①：作用域内不得再出现「全周期严格递增」这条旧表述（spec §3.3 3c①）。

    ⛔ **判据不是裸的「严格递增」**：作用域内有一条**合法且无关**的命中
       —— `kline_trainer_modules_v1.4.md:723` 讲的是 `ticket_index`，与本片无关。
       裸词判据会把它误报成违例，而最省事的「修法」是去改那条无关的行。
    ⇒ 判据 = 同一行里**既有**「严格递增」**又有** `global_index`，**且不是**改写后的新表述
      （新表述保留了「`3m` … 严格递增」这半句，属预期命中）。
    """
    offenders = []
    for rel, lineno, line in _scope_lines():
        if _OLD_WORDING not in line or "global_index" not in line:
            continue
        # 改写后的新表述必然同时点名「其它周期」与「允许重复」；旧表述两者皆无。
        if "其它周期" in line and "允许重复" in line:
            continue
        offenders.append(f"{rel}:{lineno}: {line.strip()[:120]}")
    assert not offenders, (
        "作用域内仍有「全周期严格递增」旧表述（与 spec §2.2 直接矛盾，"
        "照它写的守卫会把每个第 2 代产物判死）：\n" + "\n".join(offenders))


def test_rewritten_clauses_are_present_in_both_root_authorities():
    """守卫①的**正向对照**：两份根级权威都必须**真的**有改写后的表述。

    ⚠️ 只有上面那条否定式守卫的话，把两行**整行删掉**同样能让它变绿 —— 那不是订正，是删证据。
    """
    for path in (MODULES, PLAN15):
        text = path.read_text(encoding="utf-8")
        hits = [l for l in text.splitlines()
                if "global_index" in l and "其它周期" in l and "允许重复" in l]
        assert len(hits) == 1, (
            f"{path.name} 应恰好有 1 行改写后的 Index 预计算表述，实测 {len(hits)} 行 —— "
            f"0 行 = 被整行删掉（删证据不是订正）；>1 行 = 又抄了一份（两份实现漂移的老毛病）")


# ── 守卫②：分阶段版本守卫（spec §3.3 3c②，切片一断言）

_TRANSITION_NOTE = "App 侧仍为 1"


def test_frozen_contract_version_refs_are_2_with_transition_note():
    """守卫②前半：冻结契约三处版本引用为 `2`，且**各自带过渡态标注**。

    ⛔ **只断言值 = 2 是不够的**（spec 3b2 / 变异 B16）：那样冻结契约会声称「前后端共享 = 2」，
       而本守卫后半同时把「App 侧 = 1」认证为正确 —— 两条权威互相打脸，正是本片要消灭的形状。
    """
    lines = MODULES.read_text(encoding="utf-8").splitlines()
    targets = [l for l in lines
               if ("PRAGMA user_version" in l or "TRAINING_SET_SCHEMA_VERSION" in l)
               and re.search(r"[=|]\s*`?2`?", l)]
    assert len(targets) == 3, (
        f"冻结契约里带版本数值的引用应恰好 3 处且都为 2，实测 {len(targets)} 处：\n"
        + "\n".join(t.strip()[:110] for t in targets))
    missing = [t.strip()[:110] for t in targets if _TRANSITION_NOTE not in t]
    assert not missing, (
        "这几处改了值但**没带过渡态标注** —— 冻结契约会声称『前后端共享 = 2』，"
        "而 App 侧实际仍是 1：\n" + "\n".join(missing))


def test_app_reader_is_still_pinned_to_generation_one():
    """守卫②后半：App 读取端**仍显式钉在 1**（切片一的过渡态，切片二才改）。

    ⚠️ 两处**形状不同**，必须分别断言（spec 给的行号 `:1307` 已过期，实测在 `:1360`）：
      · `DownloadAcceptanceRunner.swift` —— 常量定义 `public let TRAINING_SET_SCHEMA_VERSION = 1`
      · `TrainingSessionCoordinator.swift` —— **写死的字面量** `expectedSchemaVersion: 1`
    ⛔ 本条**只读不改** `ios/`。它变红有两种含义：要么有人越界提前改了 App（违反切片次序），
       要么切片二已落地而这条守卫没跟着收敛（spec §8 要求那时改成「三方同时为 2」）。
    """
    runner = (REPO_ROOT / "ios/Contracts/Sources/KlineTrainerContracts"
              / "DownloadAcceptance/DownloadAcceptanceRunner.swift").read_text(encoding="utf-8")
    assert "public let TRAINING_SET_SCHEMA_VERSION = 1" in runner, (
        "DownloadAcceptanceRunner 的 TRAINING_SET_SCHEMA_VERSION 不再是 1 —— "
        "切片一期间 App 读取端必须仍钉在第 1 代")

    coordinator = (REPO_ROOT / "ios/Contracts/Sources/KlineTrainerContracts"
                   / "TrainingEngine/TrainingSessionCoordinator.swift").read_text(encoding="utf-8")
    assert "expectedSchemaVersion: 1)" in coordinator, (
        "TrainingSessionCoordinator 里写死的 expectedSchemaVersion 不再是 1 —— 同上")


def test_backend_production_side_is_already_generation_two():
    """守卫②中段：后端生产侧两处均为 `2`（P1 已落地，本条防退化）。"""
    ddl = (REPO_ROOT / "backend/sql/training_set_schema_v1.sql").read_text(encoding="utf-8")
    assert "PRAGMA user_version = 2;" in ddl
    gen = (REPO_ROOT / "backend/generate_training_sets.py").read_text(encoding="utf-8")
    assert "SCHEMA_VERSION = 2" in gen
    assert "PRAGMA user_version = 2;" in gen
```

- [ ] **Step 2: 跑，确认全绿**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -v
```

Expected: **5 passed**

- [ ] **Step 3: 跑全套**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run/backend" && \
find tests -name __pycache__ -type d -exec rm -rf {} + ; \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q 2>&1 | tail -3
```

Expected: `1399 passed`（实测基线 **1394** + 本片 5），**0 failed / 0 skipped**。
⚠️ 对不上时**先查是不是别的 PR 又动了基线**，⛔ 不许改这里的数字了事。

- [ ] **Step 4: Commit**

```bash
git add backend/tests/test_frozen_contract_texts.py
git commit -m "test(contract): 冻结契约文本两条机械守卫——禁旧表述 + 分阶段版本过渡态（P3a Task 3）"
```

---

## Task 4: 变异验证 + 非程序员验收清单

**Files:**
- Create: `docs/acceptance/2026-09-06-trainingset-p3a-mutation-log.md`
- Create: `docs/acceptance/2026-09-06-trainingset-p3a-acceptance.md`

**⛔ 变异纪律**（每条本仓都栽过）：一组一条命令；备份用 `cp`、⛔ 不用 `git checkout <file>`；每组跑前清 `__pycache__`、跑完**单独再看一次 `git status --short``；锚点命中数 ≠ 1 当场中止不写盘；判绿读**红的是哪一条用例**，不读「成功」字样。

- [ ] **Step 1: 逐组跑变异**

| # | 变异 | 期望红的**具体用例** |
|---|---|---|
| **M1** | 把 `modules:2302` 改回旧表述（「global_index/end_global_index 严格递增 + 前后端 assert」） | 🔴 `test_old_all_periods_strictly_increasing_wording_is_gone`（报出 `modules:2302`）**且** 🔴 `test_rewritten_clauses_are_present_in_both_root_authorities`（modules 变 0 行） |
| **M2** | 把 `plan_v1.5:1285` **整行删掉**（而不是改回去） | ⭐ 🟢 守卫①**不红**（旧表述确实没了）、🔴 `test_rewritten_clauses_are_present_in_both_root_authorities` —— 证明**正向对照那条不可省**：只有否定式守卫的话，「删证据」也能过关 |
| **M3** | 把 `modules:723`（`ticket_index 严格递增`，无关行）改成含 `global_index` 的措辞 | 🔴 守卫① —— 证明判据**确实**在按「同行含 `global_index`」筛，不是恒真 |
| **M4** | ⭐ **判据退化实验**：把守卫①的 `and "global_index" not in line` 那半个条件删掉（判据变成裸「严格递增」） | 🔴 守卫①**在当前树上当场红**，报出 `modules:723` 这条**合法无关**的行 —— 证明「不得写成裸词」不是空话 |
| **M5** | `modules:2239` 只把值改回 `1`（标注留着） | 🔴 `test_frozen_contract_version_refs_are_2_with_transition_note`（3 处变 2 处） |
| **M6** | ⭐ `modules:2239` 值保持 `2`，**只删掉过渡态标注** | 🔴 同上（报「改了值但没带过渡态标注」）—— 这正是 spec 变异 **B16** 的观测量：**只断言值会让这条溜过去** |
| **M7** | `DownloadAcceptanceRunner.swift:14` 的常量改成 `2` | 🔴 `test_app_reader_is_still_pinned_to_generation_one`（前半） |
| **M8** | `TrainingSessionCoordinator.swift:1360` 的字面量 `1` 改成 `2` | 🔴 同上（后半）—— ⚠️ **M7 / M8 必须分开跑并分开记**：两处形状不同，一条断言覆盖不了另一处 |
| **M9** | `backend/sql/training_set_schema_v1.sql` 的 `user_version` 改回 `1` | 🔴 `test_backend_production_side_is_already_generation_two`（另有既有 schema CI 也会红，如实记） |

单组标准跑法（以 M6 为例）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && \
cp kline_trainer_modules_v1.4.md /tmp/mod.bak && \
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" - <<'PY'
import pathlib
p = pathlib.Path("kline_trainer_modules_v1.4.md"); t = p.read_text(encoding="utf-8")
old = "（⚠️ 2026-09 切片一起：产物已第 2 代、**App 侧仍为 1**，直到切片二落地；过渡态的权威定义见 `CONTRACT_VERSION 1.14 / 1.15`）"
assert t.count(old) == 1, f"锚点命中 {t.count(old)} 次，变异未施加"
p.write_text(t.replace(old, ""), encoding="utf-8"); print("变异已施加")
PY
find backend/tests -name __pycache__ -type d -exec rm -rf {} + ; \
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_frozen_contract_texts.py -q 2>&1 | tail -8
```

复原（**单独一条命令**）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && \
cp /tmp/mod.bak kline_trainer_modules_v1.4.md && \
find backend/tests -name __pycache__ -type d -exec rm -rf {} + && \
git status --short && \
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q 2>&1 | tail -2
```

Expected：`git status --short` 无输出 + 全套回到 `1399 passed`。

- [ ] **Step 2: 写变异记录**（逐组：变异内容、施加命令、**跑出来的原始输出片段**、红的**具体用例名**、复原后 `git status` 与全套计数。⛔ 不得只写「已验证」）

- [ ] **Step 3: 写非程序员验收清单**

结构同 P2 那份（`docs/acceptance/2026-09-05-trainingset-p2-acceptance.md`）：每条一个**动作**（可复制的整行命令）、一个**期望**（看输出里的什么内容，⛔ 不是看「成功」字样）、一个**通过/不通过判定**。至少覆盖：

1. 后端全套跑通且零 skip（期望 **1399**，⚠️ 这是**分支期快照**，日后 main 上会变）；
2. 新守卫 5 条全过；
3. 两份根级权威里那两条已是新表述（给出 grep 命令与应看到的行）；
4. 冻结契约三处都是 `2` 且都带「App 侧仍为 1」；
5. `ios/` 一行未改（`git diff --name-only origin/main...HEAD -- ios/ | wc -l` 得 `0`）；
6. `backend/generate_training_sets.py`、`backend/sql/`、`.github/workflows/` 一行未改（同款得 `0`）；
7. 一节「**本片交付后仍不成立的事**」，逐条写清下面 §「已知残留」。

⛔ 禁用词见 `.claude/workflow-rules.json` 的 `verification_template.forbidden_phrases`，写完扫一遍确认 0 命中。

- [ ] **Step 4: Commit**

---

## 已知残留（本片不解决）

- **R1 — `CONTRACT_VERSION` 仍是 `"1.13"`**。归 **P3c**。⚠️ spec 明写「留着不 bump 会让本片合并后**治理契约处于被违反状态**」⇒ P3c 应紧跟本片，别拖。
- **R2 — `INSERT INTO training_sets` 有 10 处缺 `schema_version`**（含 `.github/workflows/schema-smoke.yml` 5 处）。归 **P3b**，且它是唯一要碰 workflows 的一片（**独立 push 仪式**）。
- **R3 — m01 治理矩阵 `docs/governance/m01-schema-versioning-contract.md:31` 仍写 `1`**、触发条件仍是「结构变更」。归 **P3c**。
- **R4 — Mac 本地 `~/qmt_trial_out/` 三个 v1 包尚未明确作废**、相关文案守卫未加。归 **P3c**。
- **R5 — 生成器的 DDL 字面量与冻结 DDL 文件之间没有任何守卫**（自 Plan B2 起就在，非本切片引入）：`schema-smoke.yml` 测的是**文件**，生产写库用的是 `generate_training_sets.py` 里的**字面量**。⇒ 建议并入 **P3b**（同属「加守卫」类）。
- **R6 — 库里 3 个产物仍是第 1 代**；`api` / `scheduler` / 生成器 CLI **必须保持停止**；重建归 **P4**。
- **R7 — App 侧一行未改**，缝只闭合生产者半边；切片二必须用 P2 提交的那一份 fixture。
- **R8 — 本片新加的守卫今天全红也不阻止合并**（后端测试不在 `main` ruleset 的必需检查里）。属独立 PR + 需 user 在 GitHub 改配置。
- **R9 — `kline_trainer_modules_v1.4.md:144` 的矩阵写 `CONTRACT_VERSION | "1.5"`，实际是 `"1.13"`**，自 v1.4 起就 stale，**不由本切片引入** ⇒ 刻意不改（范围蔓延）。P3c 做 bump 时可评估是否顺带。

---

## Self-Review

**1. Spec 覆盖（§3.3 逐行对表）**

| spec 行 | 落在哪 |
|---|---|
| 3b（R03 改写 + 修订记录） | Task 1 Step 1 / 3 |
| 3b-2nd（`plan_v1.5:1285` + 修订记录） | Task 1 Step 2 / 3 |
| 3b2（三处值 + **过渡态标注**） | Task 2 |
| 3c①（旧表述禁令，作用域**不得**全仓） | Task 3 守卫① + Global Constraints |
| 3c②（切片一断言：三处带标注且=2 · R03/plan 已改写 · 后端生产侧=2 · **App 读取端仍钉 1**） | Task 3 后三条守卫 |
| 3d（三处验收 grep 锚） | ⛔ **移除** —— 实测 P1 已闭合两处，第三处在 spec 声称的文件里**根本不存在**（前置事实 F5） |
| 1 / 2 / 3 / 3e / 4b / 4c / 4d | ⛔ **P1 已交付**，本片不重复 |
| 4（m01 矩阵） / 5–9（`CONTRACT_VERSION`） | ⛔ **归 P3c** |
| `INSERT` 补字段 + 守卫 | ⛔ **归 P3b** |

**2. 占位符扫描**：无 TBD / TODO / 「类似 Task N」。每个 Task 的文本与代码都可直接落盘。

**3. 一致性**：守卫②断言的三处标注措辞与 Task 2 写入的**逐字一致**（`App 侧仍为 1`）；守卫①放行新表述所用的两个词（`其它周期` / `允许重复`）与 Task 1 写入的**逐字一致**。⚠️ 实施者若改动其中任一措辞，**必须同时改另一处**，否则守卫当场红。

**4. 已知的计划自身弱点**

- Task 1/2/3 的用例**写完就是绿的**，价值完全押在 Task 4 的变异上。若某组跑不出预期的红，⛔ **不要改期望值让它红**，回来问「这条断言是不是根本没在测它」。
- `1399` 是**推算**（实测基线 1394 + 5），属计划内嵌的「事实」类，必须实测。
- ⭐ **执行中被实施者挡下一个计划缺陷（2026-09-07）**：守卫的作用域含 `backend/**/*.py`，而守卫**自己就住在那里**，且它的 docstring 必须逐字引用所禁止的那句话 ⇒ **它把自己判成违例**（实测 `:52` 那行，全套 1398 过 1 失败）。裁定 = **按解析后的自身路径排除自己**，⛔ 不改写 docstring 去绕开自己的判据（说不出自己在禁什么的守卫是更糟的守卫）、⛔ 不整目录排除、⛔ 不按文件名字符串排除（改名会静默重新自指）。控制者亲跑对照：往 `generate_training_sets.py` 塞一行假违例 ⇒ 守卫①**照样红并点名该文件**（`:845`）⇒ 自排除**没有把守卫弄瞎**；复原后 `git status` 空、全套 1399 全过。
- 守卫①用「同行含 `global_index`」作筛选，**对跨行改写无判别力**（有人把旧表述拆成两行就绕过去了）。这是有意的取舍：按语句/段落匹配 markdown 表格与列表的复杂度远高于收益。**M4 那组变异只证明了判据不是裸词，没有证明它抗跨行绕过** —— 如实记进变异记录。
