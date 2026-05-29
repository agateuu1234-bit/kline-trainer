# PR B2 — generate_training_sets 训练组生成模块 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 spec §四 B2 + plan §8.3 字面要求的后端训练组生成模块 `backend/generate_training_sets.py`：从 PostgreSQL `klines`（B1 已写、指标已算）按月线选随机起始点 → 每周期独立取窗口 → 算 `global_index / end_global_index` → 写独立训练组 SQLite（`PRAGMA user_version`）→ 压缩 zip → 计算 zip CRC32（8 字符小写）→ 登记 `training_sets` —— Wave 1 顺位 17 / 交付序第 19 个 PR per outline v20。同时折入 **H6-part2 deps pin 确认**。

**Architecture:** **双层**，与 B1（顺位 16）确立的后端双层 mode + `backend/tests/test_schema.py` 既定边界（pglast 静态解析、"Production deployment validation 是 B3/NAS scope"）一致：
- **纯装配层**（`generate_training_sets.py` 的纯函数：`crc32_hex` / `select_start_index` / `monthly_after_end` / `select_period_window` / `assign_global_indices` / `build_training_set_sqlite` / `zip_and_hash` / `assemble_training_set`）—— 输入是**已取到内存的各周期 bars（含指标列）**，输出是磁盘上的 `.db`+`.zip` 与 `GeneratedTrainingSet`。**host pytest 全测、不碰 PostgreSQL**（用 `sqlite3` / `zipfile` / `zlib` 标准库即可端到端验）。B2 的全部正确性（起始点选取、窗口、global/end_global_index、SQLite schema、CRC32）都在这一层断言。
- **薄 PG 壳**（`_fetch_period_bars` / `_register_training_set` / `_exists_start` / `generate_one_training_set` / `generate_batch` / `backfill_content_hash` + `main` CLI）—— asyncpg 读 `klines` / 写 `training_sets`；**不在 CI 单测**（需 live PG = B3/NAS scope）；结构上把 PG I/O 与纯装配解耦，便于将来集成测试。

**Tech Stack:** Python 3.9+（host；`from __future__ import annotations` 使注解全为字符串，实测 3.9 可跑）/ 标准库 `sqlite3`+`zipfile`+`zlib`+`random`+`bisect`（**B2 不引入新运行时依赖**）/ pandas 2.2.3（已 `==` 锁）/ asyncpg 0.30.0（已 `==` 锁，仅薄壳用）/ pytest（dev dep，B1 已 `==` pin）/ 训练组 SQLite schema = `backend/sql/training_set_schema_v1.sql`（已冻，本 PR **只读不改**）/ PostgreSQL `training_sets` 表 schema `backend/sql/schema.sql`（已冻，本 PR **只读不改**）。

**Spec source:** `kline_trainer_modules_v1.4.md` §四 B2 (L725-753) + M0.1 `content_hash` CRC32 (L163-219) + `kline_trainer_plan_v1.5.md` §8.3 (L1097-1144) + 训练组 SQLite DDL §3.2 (L365-402) + `training_sets` DDL (L349-360) + `backend/sql/training_set_schema_v1.sql` + outline v20 顺位 17 (L42) + §15.4 ledger H6 (deps pin) / H7 (sample 数据)。

**Constraint reminders（per outline v20 §3.2 + memory `feedback_planner_packaging_bias`）：**
- ≤ 3 sub-items（本 plan：3 Tasks）
- ≤ 500 行 prod（本 plan：~290 行 prod 估算）
- review：**Claude Opus 4.8 ultracode effort 双闸门**（plan-stage + branch-diff），**不走 codex**（user 本次显式 prompt）；4-5 轮内收敛或 escalate（per memory `feedback_codex_plan_budget_overshoot`）
- **本 PR 不碰 `.github/workflows`**（沿用 B1 的 user CI 决策"纯 opus，CI 延后"——见 Task 0 §CI 决策）；故 B2 pytest 在本地 + acceptance 脚本里跑，不进 CI；CI 接线作独立 codex 治理 PR 后续补
- 后端命令从 `backend/` 跑：`cd backend && python3 -m pytest tests/test_generate_training_sets.py -v`
- Working branch：执行阶段由 `using-git-worktrees` 创建（EnterWorktree，分支名按 attest 名开 PR——见 memory `feedback_worktree_cwd_drift`）
- **memory `feedback_worktree_cwd_drift` 硬提醒**：每次 push / gh pr create 前先 `pwd && git branch --show-current && git rev-parse HEAD` 三连确认站在 worktree 正确分支
- **memory `feedback_acceptance_grep_anchoring` 硬提醒**：机检脚本负向断言一律 `if grep; then exit 1; fi`（`set -e` 下 `! grep` 是死闸门）；human-grep 用行首/前缀/固定串锚避免注释子串碰撞

---

## 背景与既有接缝（实施者必读）

- **B1（顺位 16，merged `51323ad`）是指标真相源**：`klines` 表的 `ma66/boll_*/macd_*/ticket_index` 均由 B1 预计算入库。**B2 不重算指标**——只把 `klines` 行（含已算指标）复制进训练组 SQLite。B2 的测试 fixture 可借 `import_csv.compute_indicators` 制造带指标列的合成 bars（仅为 fixture 真实感，非生产路径，见 D15）。
- **训练组 SQLite schema 已冻**（`backend/sql/training_set_schema_v1.sql`，本 PR **只读不改**）：`PRAGMA user_version = 1`；`meta(stock_code TEXT, stock_name TEXT, start_datetime INTEGER, end_datetime INTEGER)`；`klines(id PK AUTOINCREMENT, period TEXT, datetime INTEGER, open/high/low/close REAL, volume INTEGER, amount REAL, ma66/boll_*/macd_* REAL, global_index INTEGER NULL, end_global_index INTEGER NOT NULL)` + 2 索引。B2 写库时**逐字按此 DDL** 建表（见 D8）。
- **PostgreSQL `training_sets` 表已冻**（`backend/sql/schema.sql` / plan L349-360，本 PR **只读不改**）：`id SERIAL PK, stock_code, stock_name, start_datetime BIGINT, end_datetime BIGINT, schema_version INT DEFAULT 1, file_path VARCHAR(255), content_hash CHAR(8) NULL, created_at, status VARCHAR(10) DEFAULT 'unsent'`。**注意：DDL 无 `UNIQUE(stock_code, start_datetime)` 约束**（modules 不变量提到该 UNIQUE，但实际 schema 未建）→ 见 D7：B2 用"插入前 SELECT 预检"保证幂等，**不新增约束**（加约束 = schema 迁移 = B3 owner scope）。
- **后端测试不需 live PG**（`test_schema.py` 头注释 "Production deployment validation (on NAS PostgreSQL) is Wave 1 B3 owner scope"）→ B2 纯装配层 pytest 同样不碰 PG；薄壳的真实 DB 测试推迟到 B3/NAS。纯层全端到端可测（`sqlite3`/`zipfile`/`zlib` 都是标准库）。
- **CI 现状**：后端走逐文件 path-gated workflow（`schema-smoke.yml` 管 `backend/sql/**`；`openapi-smoke.yml` 管 `openapi.yaml`）。新 `test_generate_training_sets.py` 不被任何现有 workflow 触发；加 workflow = trust-boundary = 强制 codex。沿用 B1 user 决策本 PR 不加 workflow → B2 pytest 仅本地 + acceptance 脚本跑，merge 不依赖 backend pytest CI。
- **zip 字节非确定性**：`zipfile` 写入会嵌入条目元数据（B2 用固定 arcname，无 mtime 字段写入则相对稳定，但不保证跨机位级稳定）→ content_hash 是"本次产物的字节指纹"，**不要求跨重建可复现**；测试以"重算 zip 文件 CRC == `GeneratedTrainingSet.content_hash`"自洽断言（见 D3 / Task 1 测试），不 hardcode 期望 hash。

---

## Task 0 — §15.3 评审策略前置 + CI 决策 + spec 偏差裁决

per `docs/governance/wave1-plan-template.md`：本 plan 使用哪些评审形式。

- [ ] **局部对抗性评审（必）**：本 plan B2 scope 内 **Claude Opus 4.8 ultracode effort 双闸门**（plan-stage + branch-diff），**不走 codex**（per user 本次显式 prompt + memory `feedback_review_tool_switch_must_ask`：session 开头 user 指定的 review 工具是契约）。4-5 轮内收敛或 escalate。
- [x] **集成层评审（N/A）**：B2 的下游消费者（B3 服务 `training_sets` lease / B4 调度器调 `generate_batch`）在后续顺位 18/19 落地；本 PR 是生成叶子工具，无下游被桥接 surface 在本 PR 落地。
- [x] **性能评审（N/A）**：plan §一性能门槛属前端渲染 Phase 5；B2 是离线批生成，无 60Hz 路径。

### CI 决策（沿用 B1 user 2026-05-29 explicit）

沿用 B1 的 **"纯 opus，CI 延后"**：B2 只含业务模块 + 本地/acceptance pytest + H6 deps 确认 + acceptance doc/script，**不碰 `.github/workflows`**。理由：加 backend pytest workflow = trust-boundary 改动 = 治理 backstop 强制 codex 评审，与 user 指定的 opus ultracode 评审路径冲突。CI 接线作**独立 codex 治理 PR 后续补**——继续记为 **residual B1-R1 / B2-R1**（写进 acceptance §K + 收尾 memory）。

### Step ↔ Skill 显式映射（per memory `feedback_workflow_skill_invoke_explicit`）

| 阶段 | Skill | 何时调 | 不用 raw Agent 替代 |
|---|---|---|---|
| Plan-stage adversarial review | 主线 dispatch fresh **opus 4.8 ultracode** subagent | plan 写完后、Task 1 前 | 主线必须 dispatch 新 agent |
| Task 1-3 实施 | `superpowers:subagent-driven-development` | 每 Task fresh sonnet 4.6 high implementer + paired sonnet reviewer（spec + code-quality 双道） | 不用 raw Agent / 不主线自写 |
| Verification | `superpowers:verification-before-completion` | Task 3 acceptance 脚本跑完前 | 不主线自宣"绿了" |
| Self-review | `superpowers:requesting-code-review` | branch-diff review 前 | 不跳 |
| Branch-diff adversarial review | 主线 dispatch fresh **opus 4.8 ultracode** subagent | 全部实施 + self-review 后 + push 前 | 主线必须 dispatch 新 agent |

完成 Task 0（仅"局部对抗性评审"项为可执行待办）才进 Task 1。

### Spec 偏差裁决（D1-D15，全部写进代码注释 + 验收 §J）

| # | 偏差/歧义 | 裁决 | 权威依据 |
|---|---|---|---|
| **D1** | 双层 vs 一体 | **纯装配层（host pytest 全测，sqlite3/zipfile/zlib 端到端）+ 薄 asyncpg PG 壳（CI 不单测，B3/NAS scope）**。纯层接受"已取到内存的各周期 bars"，PG 读写解耦到壳。 | B1 双层先例 + `test_schema.py` "Production validation 是 B3 scope" |
| **D2** | 训练组最小周期是谁 | **最小周期 = `3m`**（plan §8.3 `period_configs` 列出的最细粒度，无 1m）。`global_index` 仅赋给 3m bars（schema 注释"最小周期唯一"）；其它周期 `global_index = NULL`。 | plan §8.3 L1108-1114（period_configs 最细=3m）+ 训练组 schema L396 注释 |
| **D3** | `content_hash` CRC32 究竟算谁的字节（**spec 内部矛盾**） | **算整个 zip 文件字节的 CRC32**：`format(zlib.crc32(zip_bytes) & 0xFFFFFFFF, '08x')`（8 字符小写）——**取 modules L750 字面公式**（最精确的 code-level 契约 + 语义正确：它是"传输字节"的完整性指纹，P2 下载后对收到的 zip 字节重算即可验，无需解压）。modules L753 的"`unzip -v` 查看 CRC 与 content_hash 一致"指的是 **zip 条目 CRC（未压缩 sqlite 字节）**，与 L750 公式**不等价** → 标记为 **spec doc 内部不一致**（residual B2-R3，留独立 spec 清理 PR；不在本 PR 改 spec）。本 PR 验收用"重算 zip 文件 CRC == content_hash"自洽口径。 | modules L750 字面公式（authoritative）vs L753 验收描述（doc bug）|
| **D4** | `end_global_index` 二分匹配的边界语义 | **统一规则（含 3m 自身）**：把 bar 视为覆盖半开区间 `[bar.open, 下一根同周期 bar.open)`；`end_global_index = ` 该区间内**最后一根 3m bar 的 global_index** = `bisect_right(three_m_dts, upper) - 1`，其中 `upper = 下一根 open - 1`（**末根（无后继）用 `three_m_dts[-1]`** → 区间视作延伸到 +∞，吸收到 `N3-1`）；结果 `clamp 到 [0, N3-1]`。由此：3m bar `end_global_index == 自身 global_index`；**带后继、区间整段落在 3m 窗口之前**的老高周期 bar → `clamp 到 0`（开局即可见）；**末根（延伸出窗口尾部）**→ `N3-1`（末 tick 才完整）。R1 复核确认 `_aligned` 历史 fixture 的真值是 `[0,0,N3-1]`（首二根历史→0、末根→N3-1），原 v1 测试断言 `all==0` 是测试 bug（非 impl bug），v2 已按精确真值改写（见 R1→v2）。per-period `after≥1` 硬校验（D6）保证被接受训练组里每周期末根都 ≥ start，不会出现"末根仍整段在窗口前"的退化。 | plan §8.3 Step4 + L1143 "datetime 二分匹配（不依赖固定倍数）" + L592 联动语义（高周期在最后一根 3m 子棒出现时完成）|
| **D5** | 起始点选取 + 随机可测性 | 月线下标 `start_idx ∈ [30, len-9]`（前 ≥30 月线、含起始之后 ≥8 月线）；用**可注入 `rng: random.Random`**（缺省 `random.Random()`）保证 host 测试确定性；`len(monthly) < 39` → 抛 `GenerateSkipException`。 | plan §8.3 L1103-1105 `randint(30, len-9)` + modules L752 不变量"月线前≥30" + 可测性 |
| **D6** | 每周期窗口取法 + **per-period 硬校验** | `before = min(pivot, cap)`（`monthly` cap=None=取全部，weekly=120，daily/60m/15m/3m=150）；`after = ` datetime ∈ `[start_datetime, after_end_time]` 的所有 bar；`after_end_time = ` 起始起 8 根月 K（含起始）的最后一根 datetime（`monthly_after_end`）。**每周期硬校验（spec §8.3 L1130-1131 `assert before_count>=30` + `assert len(after_bars)>=1`）：起始前 < 30 根 OR 起始后 < 1 根 → `GenerateSkipException`**（不再只判空窗口——空窗口是该校验的子集；这样晚上市/稀疏数据股票会被正确跳过重选，符合 spec "硬校验不满足→跳过该股票重新选" L1144）。 | plan §8.3 L1107-1131 + L1144 |
| **D7** | 幂等"已存在则重选" + 无 UNIQUE 约束 | `training_sets` DDL **无** `UNIQUE(stock_code,start_datetime)`（modules 不变量提到但 schema 未建）→ B2 **不新增约束**（加约束=schema 迁移=B3 scope），改为**插入前 `SELECT 1 ... WHERE stock_code=$1 AND start_datetime=$2` 预检**；命中 → 重选起始点（bounded retry，缺省 8 次）；全部冲突 → `GenerateSkipException`。 | modules L752 "UNIQUE 冲突重选" + 实际 DDL L349-360 缺约束 + B1 "schema 只读不改"先例 |
| **D8** | 训练组 SQLite 建表 + 数值类型 | 逐字按 `training_set_schema_v1.sql`（`PRAGMA user_version=1` + meta + klines + 2 索引）；写行时 numpy 标量 → Python `int`/`float`，`NaN`→`None`（沿用 B1 R1-H2 教训：`sqlite3` 不接受 `numpy.float64`/`int64`，用 `to_dict("records")` + 逐列 cast，不用 `iterrows()`）。 | `training_set_schema_v1.sql` 字面 + B1 R1-H2 `to_kline_records` 先例 |
| **D9** | `GeneratedTrainingSet` 字段 | `@dataclass`：`path: Path`（zip）/ `content_hash: str` / `stock_code: str` / `stock_name: str` / `start_datetime: int` / `end_datetime: int` / `schema_version: int = SCHEMA_VERSION`。 | modules L739-743 dataclass 示例（`path` + `content_hash` + "..."）|
| **D10** | `generate_batch` 收敛 | 循环调 `generate_one_training_set` 直到产出 `target_count` 个，或连续 skip 超出 `max_skips`（缺省 `target_count*4`）→ 停并返回已产出的（记 warning），不死循环。 | modules L745-746 `generate_batch(conn, target_count)` + 防御性 |
| **D11** | v1.3 `content_hash` 回迁 | 薄壳函数 `backfill_content_hash(conn)`：`SELECT id,file_path FROM training_sets WHERE status='unsent' AND content_hash IS NULL` → 读各 `file_path` 的 zip 字节 → `crc32_hex` → `UPDATE`。CLI `--backfill` 子模式。**不 CI 单测**（需 PG+文件）；`crc32_hex` 本身在纯层已测。 | modules L751 + M0.1 L219 回迁策略 |
| **D12** | H6-part2 deps pin | B2 **不引入新运行时依赖**（`sqlite3`/`zipfile`/`zlib`/`random`/`bisect` 均标准库；pandas/asyncpg 已 `==`）。H6-part2 = 验证 `requirements.txt`/`requirements-dev.txt` 仍全 `==`（无回退）+ **best-effort 补 B1-R2 docker digest**（本机有 docker 则补 `docker-compose.yml` postgres digest，无则继续 residual）。 | §15.4 H6 + outline L42 "H6 part 2" + B1-R2 |
| **D13** | 不碰 .github/workflows | 本 PR 0 workflow 改动（沿用 B1 CI 决策）；B2 pytest 本地 + acceptance 脚本跑；CI 接线 = residual B1-R1/B2-R1 独立 codex PR。 | user 2026-05-29 explicit + 治理 backstop trust-boundary |
| **D14** | H7 sample 数据归属 | user 2026-05-29 explicit **选项 1**：本 PR 交付**生成器 + 合成数据端到端 host 测试**（证明生成器正确）；3-5 个**真实生产**样本训练组（需 NAS PostgreSQL + 真实股票数据）+ ledger 回填留 **residual B2-R2**，待有 NAS 环境补。 | user 2026-05-29 AskUserQuestion 选项 1 + outline L100 H7 拆分 |
| **D15** | B2 是否重算指标 | **否**。`klines` 指标由 B1 预计算（B1 是真相源）；B2 只复制 `klines` 行进训练组 SQLite。测试 fixture 借 `import_csv.compute_indicators` 仅为合成 bars 真实感（非生产路径）。 | modules §四 B1 职责 + 前端只读预计算先例 |

---

## File Structure

### Production（1 新文件 + 0-1 改，~290 行）

| 路径 | 动作 | 行数 | 职责 |
|---|---|---|---|
| `backend/generate_training_sets.py` | **新建** | ~290 | 纯装配层（`crc32_hex`/`select_start_index`/`monthly_after_end`/`select_period_window`/`assign_global_indices`/`build_training_set_sqlite`/`zip_and_hash`/`assemble_training_set` + `GeneratedTrainingSet`/`GenerateSkipException`/常量）+ 薄 asyncpg PG 壳（`_fetch_period_bars`/`_exists_start`/`_register_training_set`/`generate_one_training_set`/`generate_batch`/`backfill_content_hash`）+ `main()` CLI。仅纯装配层被单测。 |
| `backend/docker-compose.yml` | **改（条件性）** | ≤1 行 | 仅当本机有 docker 时补 postgres image digest（B1-R2 收尾）；无 docker 则不改（继续 residual）。 |

### Tests（1 文件，~270 行）

| 路径 | 动作 | 行数 | 测试 |
|---|---|---|---|
| `backend/tests/test_generate_training_sets.py` | **新建** | ~290 | ~19 pytest：crc32_hex 2 + select_start_index 2 + monthly_after_end 2 + select_period_window 3 + assign_global_indices 4（精确真值）+ build_sqlite 2 + zip_and_hash 1 + assemble 端到端(非平凡) 1 + skip 2（月线<39 / per-period before<30）。纯函数，无 PG。 |

### Docs / Scripts（2 文件）

| 路径 | 动作 | 内容 |
|---|---|---|
| `docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md` | **新建** | 中文非程序员验收清单 §A-§K（文件存在 / pytest 全绿 / 算法 grep 锚 / SQLite schema 语义 / CRC32 口径 / 双层边界 / deps pin / 不碰 schema+workflow 反向验证 / residual B2-R1/R2/R3）。 |
| `scripts/acceptance/plan_b2_generate_training_sets.sh` | **新建** | 机检 bash（`set -euo pipefail` + 负向断言一律 `if grep; then exit 1; fi` per memory `feedback_acceptance_grep_anchoring`；human-grep 用行首/前缀/`-F` 固定串锚）。 |

**Total：1 新 prod（+ 条件性 1 改）+ 1 test + 1 doc + 1 script = 4 文件 / ~290 prod / ~290 test / ~19 新测试。**

---

## Task 1 — 纯装配层 `generate_training_sets.py` + ~19 host pytest

**Files:**
- Create: `backend/generate_training_sets.py`（先只写纯函数 + 常量 + dataclass + exception；PG 壳 + CLI 在 Task 2）
- Create: `backend/tests/test_generate_training_sets.py`

- [ ] **Step 1: 写失败测试 `test_generate_training_sets.py`**

```python
# backend/tests/test_generate_training_sets.py
# Spec: kline_trainer_modules_v1.4.md §四 B2 + plan 2026-05-29-pr-b2-generate-training-sets.md Task 1
# 纯装配层：全部 in-memory bars + 本地临时文件，不连 PostgreSQL（PG 壳由 B3/NAS 集成测试覆盖，D1）。
from __future__ import annotations

import random
import sqlite3
import zipfile
import zlib

import pandas as pd
import pytest

from generate_training_sets import (
    GeneratedTrainingSet,
    GenerateSkipException,
    PERIODS,
    SCHEMA_VERSION,
    assemble_training_set,
    assign_global_indices,
    build_training_set_sqlite,
    crc32_hex,
    monthly_after_end,
    select_period_window,
    select_start_index,
    zip_and_hash,
)

# ---- 合成 bars 构造 ----
# 独立窗口测试用"市场名义步长"_STEP；端到端/索引测试用压缩步长 _CSTEP。
# 压缩时间轴的周期步长比例**非市场真实**——assign_global_indices 只用 datetime 排序 + 二分，
# 与真实倍率无关；压缩仅为让 6 周期同轴、3m 跨越起始点、且各周期起始前 ≥30 根的 fixture 行数可控。
_STEP = {"monthly": 2_592_000, "weekly": 604_800, "daily": 86_400,
         "60m": 3_600, "15m": 900, "3m": 180}
_CSTEP = {"monthly": 100, "weekly": 60, "daily": 40, "60m": 30, "15m": 20, "3m": 10}
_BASE = 1_600_000_000


def _bars(period: str, n: int, *, base: int = _BASE, step: int = 0) -> pd.DataFrame:
    """造 n 根某周期 bars：datetime 等步长升序；OHLCV + 指标列占位（合成，非生产）。
    step=0 → 用 _STEP[period] 名义步长；否则用显式 step（压缩时间轴）。"""
    s = step if step else _STEP[period]
    rows = []
    for i in range(n):
        close = 10.0 + i * 0.01
        rows.append({
            "period": period,
            "datetime": base + i * s,
            "open": round(close - 0.01, 2), "high": round(close + 0.02, 2),
            "low": round(close - 0.02, 2), "close": round(close, 2),
            "volume": 1000 + i, "amount": round(close * (1000 + i), 2),
            "ma66": round(close, 4), "boll_upper": round(close + 0.5, 4),
            "boll_mid": round(close, 4), "boll_lower": round(close - 0.5, 4),
            "macd_diff": round(0.01 * i, 6), "macd_dea": round(0.008 * i, 6),
            "macd_bar": round(0.004 * i, 6),
        })
    return pd.DataFrame(rows)


def _df(period: str, datetimes: list) -> pd.DataFrame:
    """按显式 datetime 列表造某周期 bars（索引单测精确控值；指标列留 None）。"""
    rows = [{"period": period, "datetime": d, "open": 10.0, "high": 10.1,
             "low": 9.9, "close": 10.0, "volume": 1000, "amount": 10000.0,
             "ma66": None, "boll_upper": None, "boll_mid": None, "boll_lower": None,
             "macd_diff": None, "macd_dea": None, "macd_bar": None} for d in datetimes]
    return pd.DataFrame(rows)


def _index_windows() -> dict:
    """assign_global_indices 精确断言用。3m 6 根（global 0..5，datetime 0,10,…,50）；
    高周期手工摆位覆盖 end_global_index 三情形：内部映射 / 历史(整段在窗口前)→0 / 末根(无后继)→N3-1。"""
    return {
        "3m": _df("3m", [0, 10, 20, 30, 40, 50]),       # global_index 0..5；end == global
        "15m": _df("15m", [0, 30, 60]),                 # egi [2,5,5]（末根 60 无后继→N3-1=5）
        "60m": _df("60m", [-100, -90, 40]),             # egi [0,3,5]：历史→0 / 内部→3 / 末根→5
        "daily": _df("daily", [0, 50]),                 # egi [4,5]
        "weekly": _df("weekly", [50]),                  # egi [5]
        "monthly": _df("monthly", [-100, 20]),          # egi [1,5]
    }


def _period_bars(*, monthly_n: int = 39) -> dict:
    """端到端 fixture：6 周期同压缩时间轴；finer 周期覆盖整条月线轴 →
    起始点(月线下标 30)前每周期 ≥30 根、后 ≥1 根（满足 D6 per-period 硬校验）。
    monthly_n=39 → select_start_index 范围 [30,30] 定值，fixture 完全确定。"""
    base = 100_000
    span = monthly_n * _CSTEP["monthly"]
    pb = {}
    for p in PERIODS:
        step = _CSTEP[p]
        pb[p] = _bars(p, span // step + 1, base=base, step=step)
    pb["monthly"] = _bars("monthly", monthly_n, base=base, step=_CSTEP["monthly"])
    return pb


# ---- D3 crc32_hex ----

def test_crc32_hex_known_value_lowercase_8():
    # zlib.crc32(b"kline") 的确定值；8 字符小写十六进制
    expected = format(zlib.crc32(b"kline") & 0xFFFFFFFF, "08x")
    got = crc32_hex(b"kline")
    assert got == expected
    assert len(got) == 8 and got == got.lower()

def test_crc32_hex_zero_padded():
    # 小 CRC 值必须左零填充到 8 位（CHAR(8) 列要求）
    got = crc32_hex(b"")          # crc32(b"") == 0
    assert got == "00000000"

# ---- D5 select_start_index ----

def test_select_start_index_in_valid_range_deterministic():
    dts = list(range(50))
    idx = select_start_index(dts, random.Random(42))
    assert 30 <= idx <= len(dts) - 9          # [30, 41]
    # 同 seed 可复现
    assert idx == select_start_index(dts, random.Random(42))

def test_select_start_index_too_few_monthly_raises():
    with pytest.raises(GenerateSkipException):
        select_start_index(list(range(38)), random.Random(1))   # <39

# ---- D6 monthly_after_end ----

def test_monthly_after_end_is_eighth_bar_inclusive():
    dts = [100 + i * 10 for i in range(20)]   # 100,110,...
    start = dts[5]                            # 150
    # 起始起 8 根（含起始）= dts[5..12] → 末根 dts[12] = 220
    assert monthly_after_end(dts, start) == dts[12]

def test_monthly_after_end_no_bar_after_raises():
    dts = [100, 110, 120]
    with pytest.raises(GenerateSkipException):
        monthly_after_end(dts, 999)           # 起始后无月线

# ---- D6 select_period_window ----

def test_select_period_window_before_cap_respected():
    bars = _bars("daily", 400)
    start = int(bars["datetime"].iloc[300])
    after_end = int(bars["datetime"].iloc[310])
    win = select_period_window(bars, start, before_cap=150, after_end_time=after_end)
    before = win[win["datetime"] < start]
    assert len(before) == 150                 # cap 生效（pivot=300 > 150）

def test_select_period_window_monthly_before_all():
    bars = _bars("monthly", 50)
    start = int(bars["datetime"].iloc[40])
    after_end = int(bars["datetime"].iloc[47])
    win = select_period_window(bars, start, before_cap=None, after_end_time=after_end)
    before = win[win["datetime"] < start]
    assert len(before) == 40                  # before=ALL（pivot=40）

def test_select_period_window_after_inclusive_bounds():
    bars = _bars("daily", 400)
    start = int(bars["datetime"].iloc[300])
    after_end = int(bars["datetime"].iloc[305])
    win = select_period_window(bars, start, before_cap=150, after_end_time=after_end)
    after = win[win["datetime"] >= start]
    assert after["datetime"].min() == start                 # 含起始
    assert after["datetime"].max() == after_end             # 含 after_end
    assert (after["datetime"] <= after_end).all()

# ---- D2/D4 assign_global_indices（精确真值断言）----

def test_assign_3m_global_index_and_end_equal():
    out = assign_global_indices(_index_windows())
    assert list(out["3m"]["global_index"]) == [0, 1, 2, 3, 4, 5]      # 0..5 严格递增
    assert list(out["3m"]["end_global_index"]) == [0, 1, 2, 3, 4, 5]  # 3m: end == 自身 global

def test_assign_non_min_period_global_index_is_null():
    out = assign_global_indices(_index_windows())
    assert out["15m"]["global_index"].isna().all()            # 非最小周期 global_index = NULL
    assert out["60m"]["global_index"].isna().all()

def test_assign_end_global_index_interior_historical_trailing():
    # 精确真值：内部二分 / 历史(整段在窗口前)→0 / 末根(无后继)→N3-1=5
    out = assign_global_indices(_index_windows())
    assert list(out["15m"]["end_global_index"]) == [2, 5, 5]
    assert list(out["60m"]["end_global_index"]) == [0, 3, 5]  # 历史→0 / 内部→3 / 末根→5
    assert list(out["monthly"]["end_global_index"]) == [1, 5]

def test_assign_end_global_index_monotonic_and_in_range():
    out = assign_global_indices(_index_windows())
    n3 = len(out["3m"])
    for period in ("monthly", "weekly", "daily", "60m", "15m", "3m"):
        egi = list(out[period]["end_global_index"])
        assert egi == sorted(egi)                             # 非递减
        assert all(0 <= e <= n3 - 1 for e in egi)             # clamp 到 [0, N3-1]

# ---- D8 build_training_set_sqlite ----

def test_build_sqlite_user_version_meta_and_rowcount(tmp_path):
    windows = assign_global_indices(_index_windows())
    db = tmp_path / "t.db"
    build_training_set_sqlite(db, stock_code="600519", stock_name="测试股",
                              start_datetime=_BASE, end_datetime=_BASE + 999,
                              windows=windows)
    conn = sqlite3.connect(str(db))
    try:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION
        meta = conn.execute("SELECT stock_code, stock_name, start_datetime, end_datetime FROM meta").fetchone()
        assert meta == ("600519", "测试股", _BASE, _BASE + 999)
        total = sum(len(windows[p]) for p in PERIODS)
        assert conn.execute("SELECT COUNT(*) FROM klines").fetchone()[0] == total
    finally:
        conn.close()

def test_build_sqlite_integer_columns_are_int_not_float(tmp_path):
    # 沿用 B1 R1-H2：datetime/volume/global_index/end_global_index 必须是 SQLite INTEGER
    windows = assign_global_indices(_index_windows())
    db = tmp_path / "t.db"
    build_training_set_sqlite(db, stock_code="X", stock_name="X",
                              start_datetime=_BASE, end_datetime=_BASE + 1, windows=windows)
    conn = sqlite3.connect(str(db))
    try:
        row = conn.execute(
            "SELECT typeof(datetime), typeof(volume), typeof(end_global_index) "
            "FROM klines WHERE period='3m' LIMIT 1").fetchone()
        assert row == ("integer", "integer", "integer")
    finally:
        conn.close()

# ---- D3 zip_and_hash ----

def test_zip_and_hash_content_hash_matches_zip_bytes(tmp_path):
    db = tmp_path / "t.db"
    db.write_bytes(b"SQLite format 3\x00fake")
    zp = tmp_path / "t.zip"
    h = zip_and_hash(db, zp)
    # content_hash == 整个 zip 文件字节的 CRC32（D3：取 modules L750 字面口径）
    assert h == format(zlib.crc32(zp.read_bytes()) & 0xFFFFFFFF, "08x")
    with zipfile.ZipFile(zp) as zf:
        assert db.name in zf.namelist()       # zip 内含该 .db

# ---- 端到端 assemble + skip ----

def test_assemble_training_set_end_to_end(tmp_path):
    gts = assemble_training_set(tmp_path, stock_code="600519", stock_name="测试股",
                                period_bars=_period_bars(), rng=random.Random(7))
    assert isinstance(gts, GeneratedTrainingSet)
    assert gts.path.exists() and gts.path.suffix == ".zip"
    assert len(gts.content_hash) == 8 and gts.content_hash == gts.content_hash.lower()
    assert gts.schema_version == SCHEMA_VERSION
    assert gts.start_datetime < gts.end_datetime
    with zipfile.ZipFile(gts.path) as zf:
        data = zf.read(zf.namelist()[0])
    db2 = tmp_path / "extracted.db"
    db2.write_bytes(data)
    conn = sqlite3.connect(str(db2))
    try:
        three_dt = [r[0] for r in conn.execute(
            "SELECT datetime FROM klines WHERE period='3m' ORDER BY datetime")]
        # 3m 真正跨越起始点（非平凡窗口：前后都有根，H1 防 vacuous）
        assert min(three_dt) < gts.start_datetime <= max(three_dt)
        gi = [r[0] for r in conn.execute(
            "SELECT global_index FROM klines WHERE period='3m' ORDER BY datetime")]
        assert gi == list(range(len(gi))) and len(gi) > 0     # 0,1,2,… 严格递增
        n3 = len(gi)
        nulls = conn.execute(
            "SELECT COUNT(*) FROM klines WHERE end_global_index IS NULL").fetchone()[0]
        assert nulls == 0                                      # end_global_index NOT NULL 全有值
        egi15 = [r[0] for r in conn.execute(
            "SELECT end_global_index FROM klines WHERE period='15m'")]
        # 高周期联动非平凡：至少一根 end_global_index 严格落在 (0, N3-1)
        assert any(0 < e < n3 - 1 for e in egi15)
    finally:
        conn.close()

def test_assemble_skip_when_monthly_insufficient(tmp_path):
    with pytest.raises(GenerateSkipException):                # <39 月线 → select_start_index 抛
        assemble_training_set(tmp_path, stock_code="X", stock_name="X",
                              period_bars=_period_bars(monthly_n=20), rng=random.Random(1))

def test_assemble_skip_when_period_before_under_30(tmp_path):
    # D6 per-period 硬校验：把 3m 换成"起始前仅 5 根"→ before<30 → GenerateSkipException
    pb = _period_bars()
    pb = {**pb, "3m": _bars("3m", 80, base=102_950, step=10)}  # start=103000；前仅 102950..102990 = 5 根
    with pytest.raises(GenerateSkipException):
        assemble_training_set(tmp_path, stock_code="X", stock_name="X",
                              period_bars=pb, rng=random.Random(7))
```

- [ ] **Step 2: 跑测试确认全 fail（import 失败 / 函数未定义 → exit ≠ 0）**

Run:
```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -q > /tmp/b2-red.txt 2>&1; echo "exit=$?"
grep -iE "ModuleNotFoundError|ImportError|cannot import|error" /tmp/b2-red.txt | head -3
```
Expected：`exit=` 非 0 + import/未定义错误命中（用 exit code 不依赖 wording）。

- [ ] **Step 3: 写纯装配层实现 `generate_training_sets.py`（只到纯函数 + 常量 + dataclass + exception；PG 壳 Task 2）**

```python
# backend/generate_training_sets.py
# Spec: kline_trainer_modules_v1.4.md §四 B2 (L725-753) + M0.1 CRC32 (L163-219)
#       + kline_trainer_plan_v1.5.md §8.3 (L1097-1144) + 训练组 SQLite DDL §3.2
#       + backend/sql/training_set_schema_v1.sql（本 PR 只读不改）
#
# 双层（D1）：纯装配层（crc32_hex / select_start_index / monthly_after_end /
#   select_period_window / assign_global_indices / build_training_set_sqlite /
#   zip_and_hash / assemble_training_set）host pytest 全测、不碰 PostgreSQL；
#   薄 asyncpg PG 壳 + CLI 在同文件下半（D13，CI 不单测，B3/NAS scope）。
#
# 决议：
# - D2 最小周期 = 3m，global_index 仅赋 3m（其它 NULL）
# - D3 content_hash = format(zlib.crc32(zip_file_bytes) & 0xFFFFFFFF, '08x')（8 字符小写；modules L750 字面）
# - D4 end_global_index = bisect_right(3m_dts, [open,下一open) 上界) - 1，clamp[0,N-1]
# - D5 起始 idx ∈ [30, len-9]，rng 可注入；月线<39 → GenerateSkipException
# - D6 before=min(pivot,cap)（monthly=ALL），after=[start, after_end]；after_end=8 根月 K 末根
# - D7 幂等用插入前 SELECT 预检（schema 无 UNIQUE，不新增约束）
# - D8 SQLite 逐字 training_set_schema_v1.sql；numpy→python int/float，NaN→None
from __future__ import annotations

import random
import sqlite3
import zipfile
import zlib
from bisect import bisect_left, bisect_right
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional, Sequence

import pandas as pd

SCHEMA_VERSION = 1
MIN_PERIOD = "3m"
# 训练组包含的周期（plan §8.3 period_configs；最细=3m）
PERIODS = ("monthly", "weekly", "daily", "60m", "15m", "3m")
# 各周期"起始前"取根数上限；None = 全取（monthly）
PERIOD_BEFORE_CAP = {"monthly": None, "weekly": 120, "daily": 150,
                     "60m": 150, "15m": 150, "3m": 150}


class GenerateSkipException(Exception):
    """月线不足 / "之后" 窗口为空 / 起始点冲突 → 跳过重选（modules L737）。"""


@dataclass
class GeneratedTrainingSet:
    path: Path                 # zip 文件路径
    content_hash: str          # zip 文件 CRC32 8 字符小写十六进制（D3）
    stock_code: str
    stock_name: str
    start_datetime: int
    end_datetime: int
    schema_version: int = SCHEMA_VERSION


def crc32_hex(data: bytes) -> str:
    """D3：zip 字节 CRC32 → 8 字符小写十六进制（modules v1.3 L750 字面公式）。"""
    return format(zlib.crc32(data) & 0xFFFFFFFF, "08x")


def select_start_index(monthly_datetimes: Sequence[int], rng: random.Random) -> int:
    """D5：随机选起始月线下标 ∈ [30, len-9]（前 ≥30、含起始之后 ≥8）。
    月线 <39 根 → GenerateSkipException。"""
    n = len(monthly_datetimes)
    if n < 39:                          # 需 [30, n-9] 非空 → n-9 >= 30 → n >= 39
        raise GenerateSkipException(f"月线仅 {n} 根，不足 39 根无法选起始点")
    return rng.randint(30, n - 9)


def monthly_after_end(monthly_datetimes: Sequence[int], start_datetime: int) -> int:
    """D6："之后"时间窗口 = 起始起 8 根月 K（含起始）的最后一根 datetime。"""
    after = [d for d in monthly_datetimes if d >= start_datetime][:8]
    if not after:
        raise GenerateSkipException("起始点之后无月线")
    return int(after[-1])


def select_period_window(bars: pd.DataFrame, start_datetime: int,
                         before_cap: Optional[int], after_end_time: int) -> pd.DataFrame:
    """D6：单周期窗口 = 起始前 min(pivot, cap) 根 + datetime∈[start, after_end] 的所有根。
    bars 须按 datetime 升序。"""
    b = bars.sort_values("datetime").reset_index(drop=True)
    dts = b["datetime"].tolist()
    pivot = bisect_left(dts, start_datetime)               # 第一根 datetime >= start 的下标
    before_count = pivot if before_cap is None else min(pivot, before_cap)
    before = b.iloc[pivot - before_count: pivot]
    after = b[(b["datetime"] >= start_datetime) & (b["datetime"] <= after_end_time)]
    return pd.concat([before, after]).reset_index(drop=True)


def assign_global_indices(windows: dict[str, pd.DataFrame]) -> dict[str, pd.DataFrame]:
    """D2/D4：3m 升序赋 global_index 0,1,2…（其它周期 NULL）；所有周期(含3m)
    end_global_index = 覆盖区间 [open, 下一根 open) 内最后一根 3m 的 global_index
    = bisect_right(3m_dts, upper) - 1，clamp[0, N3-1]（datetime 二分匹配）。"""
    three = windows[MIN_PERIOD].sort_values("datetime").reset_index(drop=True)
    three_dts = three["datetime"].tolist()
    n3 = len(three_dts)
    if n3 == 0:
        raise GenerateSkipException("3m 窗口为空，无法建 global_index")

    out: dict[str, pd.DataFrame] = {}
    for period, df in windows.items():
        d = df.sort_values("datetime").reset_index(drop=True).copy()
        opens = d["datetime"].tolist()
        egi = []
        for i, _open in enumerate(opens):
            nxt = opens[i + 1] if i + 1 < len(opens) else None
            upper = (nxt - 1) if nxt is not None else three_dts[-1]
            j = bisect_right(three_dts, upper) - 1
            egi.append(max(0, min(j, n3 - 1)))
        d["end_global_index"] = egi
        d["global_index"] = list(range(len(d))) if period == MIN_PERIOD else None
        out[period] = d
    return out


def _int_or_none(v: Any) -> Optional[int]:
    if v is None or (isinstance(v, float) and pd.isna(v)):
        return None
    return int(v)


def _float_or_none(v: Any) -> Optional[float]:
    if v is None:
        return None
    fv = float(v)
    return None if pd.isna(fv) else fv


# 训练组 SQLite DDL（逐字 backend/sql/training_set_schema_v1.sql，D8；本 PR 只读不改源文件）
# 注：`PRAGMA user_version = 1` 用字面 1（== SCHEMA_VERSION）以逐字对齐冻结 schema 文件
# （C2 修：原 f-string `{SCHEMA_VERSION}` 渲染后不含子串 "user_version = 1"，会让验收 grep 锚失配）。
_TRAINING_SET_DDL = """
PRAGMA user_version = 1;
CREATE TABLE meta (
    stock_code TEXT NOT NULL, stock_name TEXT NOT NULL,
    start_datetime INTEGER NOT NULL, end_datetime INTEGER NOT NULL
);
CREATE TABLE klines (
    id INTEGER PRIMARY KEY AUTOINCREMENT, period TEXT NOT NULL,
    datetime INTEGER NOT NULL, open REAL NOT NULL, high REAL NOT NULL,
    low REAL NOT NULL, close REAL NOT NULL, volume INTEGER NOT NULL, amount REAL,
    ma66 REAL, boll_upper REAL, boll_mid REAL, boll_lower REAL,
    macd_diff REAL, macd_dea REAL, macd_bar REAL,
    global_index INTEGER, end_global_index INTEGER NOT NULL
);
CREATE INDEX idx_period_endidx ON klines(period, end_global_index);
CREATE INDEX idx_period_datetime ON klines(period, datetime);
"""

_KLINE_INSERT = (
    "INSERT INTO klines (period, datetime, open, high, low, close, volume, amount, "
    "ma66, boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar, "
    "global_index, end_global_index) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
)


def build_training_set_sqlite(db_path: Path, *, stock_code: str, stock_name: str,
                              start_datetime: int, end_datetime: int,
                              windows: dict[str, pd.DataFrame]) -> None:
    """D8：写独立训练组 SQLite（schema=training_set_schema_v1.sql）。
    sqlite3 不接受 numpy 标量 → 用 to_dict('records') 逐列 cast 成 Python int/float，NaN→None。"""
    conn = sqlite3.connect(str(db_path))
    try:
        conn.executescript(_TRAINING_SET_DDL)
        conn.execute("INSERT INTO meta (stock_code, stock_name, start_datetime, end_datetime) "
                     "VALUES (?,?,?,?)", (stock_code, stock_name, int(start_datetime), int(end_datetime)))
        for period in PERIODS:
            for row in windows[period].to_dict("records"):
                conn.execute(_KLINE_INSERT, (
                    period, _int_or_none(row.get("datetime")),
                    _float_or_none(row.get("open")), _float_or_none(row.get("high")),
                    _float_or_none(row.get("low")), _float_or_none(row.get("close")),
                    _int_or_none(row.get("volume")), _float_or_none(row.get("amount")),
                    _float_or_none(row.get("ma66")), _float_or_none(row.get("boll_upper")),
                    _float_or_none(row.get("boll_mid")), _float_or_none(row.get("boll_lower")),
                    _float_or_none(row.get("macd_diff")), _float_or_none(row.get("macd_dea")),
                    _float_or_none(row.get("macd_bar")),
                    _int_or_none(row.get("global_index")), _int_or_none(row.get("end_global_index")),
                ))
        conn.commit()
    finally:
        conn.close()


def zip_and_hash(db_path: Path, zip_path: Path) -> str:
    """D3：把 .db 压进 zip → 返回整个 zip 文件字节的 CRC32（8 字符小写）。"""
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.write(db_path, arcname=db_path.name)
    return crc32_hex(zip_path.read_bytes())


def assemble_training_set(output_dir: Path, *, stock_code: str, stock_name: str,
                          period_bars: dict[str, pd.DataFrame],
                          rng: random.Random) -> GeneratedTrainingSet:
    """纯装配（D1，不碰 PG）：已取到内存的各周期 bars → 选起始 → 窗口 → 赋 index →
    建 SQLite → zip → CRC32 → GeneratedTrainingSet。"""
    monthly = period_bars["monthly"].sort_values("datetime").reset_index(drop=True)
    monthly_dts = [int(x) for x in monthly["datetime"]]
    start_idx = select_start_index(monthly_dts, rng)
    start_datetime = monthly_dts[start_idx]
    after_end = monthly_after_end(monthly_dts, start_datetime)

    windows: dict[str, pd.DataFrame] = {}
    for period in PERIODS:
        win = select_period_window(period_bars[period], start_datetime,
                                   PERIOD_BEFORE_CAP[period], after_end)
        # D6 per-period 硬校验（spec §8.3 assert before_count>=30 + len(after_bars)>=1）：
        # 晚上市/稀疏数据 → 跳过该股票重选（L1144）。空窗口是 before<30 的子集。
        before_n = int((win["datetime"] < start_datetime).sum())
        after_n = int((win["datetime"] >= start_datetime).sum())
        if before_n < 30 or after_n < 1:
            raise GenerateSkipException(
                f"{period} 起始前 {before_n}(<30) 或 起始后 {after_n}(<1) 不足")
        windows[period] = win
    windows = assign_global_indices(windows)

    fname = f"{stock_code}_{start_datetime}"
    db_path = output_dir / f"{fname}.db"
    zip_path = output_dir / f"{fname}.zip"
    build_training_set_sqlite(db_path, stock_code=stock_code, stock_name=stock_name,
                              start_datetime=start_datetime, end_datetime=after_end,
                              windows=windows)
    content_hash = zip_and_hash(db_path, zip_path)
    return GeneratedTrainingSet(path=zip_path, content_hash=content_hash,
                                stock_code=stock_code, stock_name=stock_name,
                                start_datetime=start_datetime, end_datetime=after_end,
                                schema_version=SCHEMA_VERSION)
```

- [ ] **Step 4: 跑测试确认 ~19 全绿**

Run:
```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -q > /tmp/b2-green.txt 2>&1; echo "exit=$?"
tail -5 /tmp/b2-green.txt
```
Expected：`exit=0` + `N passed`（N≥19），0 failed。某测试 fail → 改实现不改断言（除非断言本身算错——那是 plan bug，报 DONE_WITH_CONCERNS）。

- [ ] **Step 5: Commit**

```bash
cd "<repo-root>"
git add backend/generate_training_sets.py backend/tests/test_generate_training_sets.py
git commit -m "feat(b2): 训练组生成纯装配层 + ~17 host pytest (Task 1)

select_start_index(月线[30,len-9],rng可注入) + monthly_after_end(8根月K窗口) +
select_period_window(before cap/after窗口) + assign_global_indices(3m global +
datetime二分 end_global_index clamp) + build_training_set_sqlite(逐字schema v1,
numpy→python cast) + zip_and_hash(zip字节CRC32 8hex) + assemble端到端。纯函数不碰PG。
PG壳 + CLI 在 Task 2。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — 薄 asyncpg PG 壳 + CLI

**Files:**
- Modify: `backend/generate_training_sets.py`（追加 PG 壳 + `main` CLI；不动 Task 1 纯函数）

> 本 Task **不加单测**（D1/D13：读写 PG 需 live PG = B3/NAS scope）；正确性靠纯层（Task 1）+ Task 3 acceptance grep 锚验签名存在。

- [ ] **Step 1: 追加 PG 壳 + CLI 到 `generate_training_sets.py` 末尾**

```python
# ===== 薄 asyncpg PG 壳 + CLI（D1/D13：不单测，B3/NAS 集成 scope）=====
import argparse
import asyncio
import os

# klines 列：复制进训练组 SQLite 的列（指标由 B1 预计算，D15 B2 不重算）
_KLINE_SELECT_COLS = ("period, datetime, open, high, low, close, volume, amount, "
                      "ma66, boll_upper, boll_mid, boll_lower, macd_diff, macd_dea, macd_bar")


async def _fetch_period_bars(conn, stock_code: str, period: str) -> pd.DataFrame:
    """读某股某周期全部 klines（升序）→ DataFrame。指标列已由 B1 算好（D15）。"""
    rows = await conn.fetch(
        f"SELECT {_KLINE_SELECT_COLS} FROM klines "
        "WHERE stock_code=$1 AND period=$2 ORDER BY datetime", stock_code, period)
    return pd.DataFrame([dict(r) for r in rows])


async def _exists_start(conn, stock_code: str, start_datetime: int) -> bool:
    """D7：幂等预检（schema 无 UNIQUE，用 SELECT 判断 (stock_code,start_datetime) 是否已生成）。"""
    row = await conn.fetchrow(
        "SELECT 1 FROM training_sets WHERE stock_code=$1 AND start_datetime=$2",
        stock_code, start_datetime)
    return row is not None


async def _register_training_set(conn, gts: GeneratedTrainingSet) -> int:
    """登记 training_sets 行（status 默认 'unsent'）。返回新行 id。"""
    return await conn.fetchval(
        "INSERT INTO training_sets (stock_code, stock_name, start_datetime, end_datetime, "
        "schema_version, file_path, content_hash) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id",
        gts.stock_code, gts.stock_name, gts.start_datetime, gts.end_datetime,
        gts.schema_version, str(gts.path), gts.content_hash)


async def generate_one_training_set(conn, stock_code: str, output_dir: Path,
                                    rng: Optional[random.Random] = None,
                                    max_retries: int = 8) -> GeneratedTrainingSet:
    """D7：取各周期 bars → 装配 → 幂等预检（冲突重选）→ 登记。
    重试耗尽 / 月线不足 → GenerateSkipException。"""
    rng = rng or random.Random()
    period_bars = {p: await _fetch_period_bars(conn, stock_code, p) for p in PERIODS}
    for _ in range(max_retries):
        gts = assemble_training_set(output_dir, stock_code=stock_code,
                                    stock_name=_stock_name_of(period_bars, stock_code),
                                    period_bars=period_bars, rng=rng)
        if await _exists_start(conn, stock_code, gts.start_datetime):
            gts.path.unlink(missing_ok=True)            # 重选：删掉冲突产物
            (gts.path.with_suffix(".db")).unlink(missing_ok=True)
            continue
        await _register_training_set(conn, gts)
        return gts
    raise GenerateSkipException(f"{stock_code}: {max_retries} 次起始点全冲突，跳过")


def _stock_name_of(period_bars: dict, stock_code: str) -> str:
    """从 stocks 名取不到时退回 code（训练组生成不查 stocks 表，简化为 code）。"""
    return stock_code


async def generate_batch(conn, target_count: int, output_dir: Path,
                         rng: Optional[random.Random] = None) -> list[GeneratedTrainingSet]:
    """D10：B4 调度器直接调用。循环生成直到 target_count 个或连续 skip 超限。"""
    rng = rng or random.Random()
    codes = [r["code"] for r in await conn.fetch("SELECT code FROM stocks ORDER BY code")]
    if not codes:
        return []
    out: list[GeneratedTrainingSet] = []
    skips = 0
    max_skips = target_count * 4
    i = 0
    while len(out) < target_count and skips < max_skips:
        code = codes[i % len(codes)]
        i += 1
        try:
            out.append(await generate_one_training_set(conn, code, output_dir, rng))
        except GenerateSkipException:
            skips += 1
    if len(out) < target_count:
        print(f"[B2] 警告：仅生成 {len(out)}/{target_count}（skip {skips} 次）")
    return out


async def backfill_content_hash(conn) -> int:
    """D11：v1.3 回迁——重算 status='unsent' AND content_hash IS NULL 行的 CRC32 并回写。返回回填行数。"""
    rows = await conn.fetch(
        "SELECT id, file_path FROM training_sets "
        "WHERE status='unsent' AND content_hash IS NULL")
    n = 0
    for r in rows:
        zip_bytes = Path(r["file_path"]).read_bytes()
        await conn.execute("UPDATE training_sets SET content_hash=$1 WHERE id=$2",
                           crc32_hex(zip_bytes), r["id"])
        n += 1
    print(f"[B2] backfill：回填 {n} 行 content_hash")
    return n


async def _amain(args) -> int:
    import asyncpg                          # 局部 import：纯装配层不依赖 asyncpg（单测不装也能跑）
    conn = await asyncpg.connect(args.dsn)
    try:
        out_dir = Path(args.output)
        out_dir.mkdir(parents=True, exist_ok=True)
        if args.backfill:
            await backfill_content_hash(conn)
            return 0
        sets = await generate_batch(conn, args.count, out_dir, random.Random(args.seed))
        for g in sets:
            print(f"[B2] {g.path.name} crc32={g.content_hash} start={g.start_datetime}")
        print(f"[B2] 完成：生成 {len(sets)} 个训练组")
        return 0
    finally:
        await conn.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="生成训练组 SQLite + zip + 登记 training_sets (B2)")
    ap.add_argument("--dsn", default=os.environ.get("DATABASE_URL"), help="PostgreSQL DSN")
    ap.add_argument("--count", type=int, default=100, help="目标生成个数")
    ap.add_argument("--output", required=True, help="训练组 .zip 输出目录")
    ap.add_argument("--seed", type=int, default=None, help="随机种子（可复现）")
    ap.add_argument("--backfill", action="store_true", help="仅回迁 content_hash（v1.3 迁移）")
    args = ap.parse_args(argv)
    if not args.dsn:
        ap.error("需要 --dsn 或环境变量 DATABASE_URL")
    return asyncio.run(_amain(args))


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: 跑纯层测试确认零回归（PG 壳追加不破坏纯函数 import）**

Run:
```bash
cd backend && python3 -m pytest tests/test_generate_training_sets.py -q > /tmp/b2-task2.txt 2>&1; echo "exit=$?"
```
Expected：`exit=0`，仍 ~17 passed（PG 壳的 `import asyncpg` 在 `_amain` 内，纯层测试不触发；asyncpg 未装也不影响纯层）。

- [ ] **Step 3: 编译/语法自检（不连 DB）**

Run: `cd backend && python3 -c "import generate_training_sets as m; print('main' in dir(m), 'generate_one_training_set' in dir(m), 'generate_batch' in dir(m), 'backfill_content_hash' in dir(m))"`
Expected：`True True True True`（模块可 import、CLI + PG 壳符号存在）。

- [ ] **Step 4: Commit**

```bash
cd "<repo-root>"
git add backend/generate_training_sets.py
git commit -m "feat(b2): asyncpg PG 壳 + generate_batch + backfill + CLI (Task 2)

_fetch_period_bars(读klines指标已算) + _exists_start(D7幂等预检,无UNIQUE) +
_register_training_set + generate_one(冲突重选) + generate_batch(收敛防死循环) +
backfill_content_hash(v1.3回迁) + CLI(--dsn/--count/--output/--seed/--backfill)。
asyncpg 局部 import，纯层单测不依赖（D13 PG CI 不测，B3/NAS scope）。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — H6-part2 deps 确认 + acceptance doc + 机检脚本

**Files:**
- Modify（条件性）: `backend/docker-compose.yml`（仅本机有 docker 时补 postgres digest，收 B1-R2）
- Create: `docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md`
- Create: `scripts/acceptance/plan_b2_generate_training_sets.sh`

- [ ] **Step 1: H6-part2 deps 确认（B2 无新运行时依赖）**

先确认 B2 import 的全是标准库 / 已 pin 的库：
```bash
cd backend && python3 -c "import generate_training_sets" && echo "import OK"
grep -nE '^(import|from) ' generate_training_sets.py | grep -vE 'sqlite3|zipfile|zlib|random|bisect|dataclasses|pathlib|typing|argparse|asyncio|os|__future__|pandas|asyncpg'
```
Expected：第二条命令**无输出**（所有 import 都是标准库 / pandas / asyncpg——后两者已在 `requirements.txt` `==` pin）。若有输出 = 引入了未 pin 的新依赖，必须 pin 或移除。

确认现有 pin 未回退：
```bash
grep -cE '(>=|<|~=)' backend/requirements.txt backend/requirements-dev.txt
```
Expected：`0`（B1 已把 dev deps pin 成 `==`；本 PR 不得引入 range）。

- [ ] **Step 2: best-effort 补 B1-R2 docker digest（仅本机有 docker）**

```bash
docker pull postgres:15.12 >/dev/null 2>&1 && docker inspect --format='{{index .RepoDigests 0}}' postgres:15.12 || echo "NO_DOCKER"
```
- 若打印出 `postgres@sha256:<digest>`：把 `backend/docker-compose.yml` 的 `image: postgres:15.12`（或现有 tag pin）改为 `image: postgres:15.12@sha256:<digest>`，收掉 B1-R2。
- 若打印 `NO_DOCKER` 或拉取失败：**不改** `docker-compose.yml`，B1-R2 继续 residual（acceptance §K 说明）。**不要编造 digest。**

- [ ] **Step 3: 写 acceptance doc `docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md`**

完整内容（§A-§K）：

````markdown
# PR B2 验收清单（中文非程序员可执行）

> Wave 1 顺位 17 / 交付序第 19 个 PR。spec `kline_trainer_modules_v1.4.md` §四 B2 + `kline_trainer_plan_v1.5.md` §8.3。
> plan `docs/superpowers/plans/2026-05-29-pr-b2-generate-training-sets.md`。

## §A 文件存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| A.1 | `ls backend/generate_training_sets.py` | 存在 | 文件在 |
| A.2 | `ls backend/tests/test_generate_training_sets.py` | 存在 | 文件在 |
| A.3 | `test -f scripts/acceptance/plan_b2_generate_training_sets.sh && echo OK` | OK | 输出 OK |

## §B 纯层 pytest 全绿（本地，无需 DB）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| B.1 | `cd backend && python3 -m pytest tests/test_generate_training_sets.py -q` | `N passed`（N≥19），0 failed | exit=0 + 末行无 failed |

## §C 模块可导入 + CLI/PG 壳符号存在

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| C.1 | `cd backend && python3 -c "import generate_training_sets as m; print('main' in dir(m), 'generate_one_training_set' in dir(m), 'generate_batch' in dir(m), 'backfill_content_hash' in dir(m))"` | `True True True True` | 命中 |

## §D 算法落地（D2-D6 grep 锚）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| D.1 | `grep -nc 'rng.randint(30, n - 9)' backend/generate_training_sets.py` | 1 (D5 起始范围) | =1 |
| D.2 | `grep -Fnc "[:8]" backend/generate_training_sets.py` | ≥1 (D6 8 根月 K 窗口) | ≥1 |
| D.3 | `grep -nc 'bisect_right(three_dts, upper) - 1' backend/generate_training_sets.py` | 1 (D4 end_global_index 二分) | =1 |
| D.4 | `grep -nc 'MIN_PERIOD = "3m"' backend/generate_training_sets.py` | 1 (D2 最小周期 3m) | =1 |

## §E content_hash CRC32 口径（D3）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| E.1 | `grep -Fnc "format(zlib.crc32(data) & 0xFFFFFFFF, \"08x\")" backend/generate_training_sets.py` | 1 (modules L750 字面 8 字符小写) | =1 |
| E.2 | `grep -nc 'crc32_hex(zip_path.read_bytes())' backend/generate_training_sets.py` | 1 (算整个 zip 文件字节) | =1 |

## §F SQLite schema 语义（D8）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| F.1 | `grep -nc 'PRAGMA user_version = 1' backend/generate_training_sets.py` | 1 (schema_version) | =1 |
| F.2 | `grep -nc 'end_global_index INTEGER NOT NULL' backend/generate_training_sets.py` | 1 (逐字 schema) | =1 |

## §G 双层边界：纯层不顶层依赖 asyncpg（D1/D13）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| G.1 | `grep -ncE '^import asyncpg$' backend/generate_training_sets.py` | 0 (asyncpg 只在 _amain 内 import) | =0 |
| G.2 | `grep -nc 'import asyncpg' backend/generate_training_sets.py` | 1 (壳内局部 import) | =1 |

## §H H6-part2 deps 未回退（D12）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| H.1 | `grep -cE '(>=\|<\|~=)' backend/requirements.txt backend/requirements-dev.txt` | 0 (无 range) | =0 |

## §I 不碰 schema + .github/workflows（D13 / 只读 schema）

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| I.1 | `git diff --name-only origin/main...HEAD -- backend/sql/ .github/` | 空 | 无输出 |

## §J 机检脚本自身

| 编号 | 命令 | 预期 | 通过条件 |
|---|---|---|---|
| J.1 | `bash scripts/acceptance/plan_b2_generate_training_sets.sh 2>&1 \| tail -2` | `✅ 所有 8 项 G1-G8 验收通过` | 末行 ✅ + exit 0 |

## §K Residuals

- **B2-R1**：backend pytest 未接 CI（沿用 B1 user 2026-05-29 "纯 opus，CI 延后"）。`test_generate_training_sets.py` 仅本地 + 本脚本跑；接 path-gated CI workflow = trust-boundary，作独立 codex 治理 PR 后续补（= B1-R1）。
- **B2-R2（= ledger H7）**：3-5 个**真实生产**样本训练组数据 + ledger 回填需 NAS PostgreSQL + 真实股票数据（本会话无此环境，user 2026-05-29 选项 1）。本 PR 交付生成器 + 合成数据端到端 host 测试（证明正确性）；真实样本待 NAS 环境补。
- **B2-R3**：modules L753 验收文案"`unzip -v` 查看 CRC 与 content_hash 一致"指 zip **条目 CRC**（未压缩 sqlite 字节），与 L750 字面公式 `crc32(zip_bytes)`（**整个 zip 文件字节**）不等价 → **验收时请勿用 `unzip -v` 比对 content_hash（会误判不一致）**；正确口径 = 对 zip 文件字节重算 `crc32`（= P2 客户端对下载到的 zip 字节做的传输完整性校验，无需解压）。本 PR 取 L750（更精确 + 传输完整性语义正确）；spec doc 文案清理留独立 spec PR。
- **B2-R4（条件性）**：若实施时本机无 docker，B1-R2 docker digest 继续 residual，`docker-compose.yml` 保留 tag pin。
- **B2-R5**：`generate_one_training_set` 重试在月线极窄（n=39 → 唯一可选下标）时会把同一 start 试满 `max_retries` 次（每次写+删 db/zip），终止于 `GenerateSkipException`（**不死循环**，已验证），但低效。接受 residual：bounded + 终止 + 窄场景；B4 调度补齐时跨股票轮转，单股满槽降级为 skip 可接受。
- **PG 壳无 CI 单测**：`_fetch_period_bars`/`generate_one`/`generate_batch`/`backfill_content_hash`/CLI 无 live PG 单测（D1/D13，B3/NAS scope）；纯装配层覆盖全部业务正确性。
- **zip 字节非确定性**：`content_hash` 不跨重建复现（zip 头嵌 mtime）；它是"传输完整性指纹"，P2 须对**收到的 zip 字节**重算比对，不可重新打包再 hash。
````

- [ ] **Step 4: 写机检脚本 `scripts/acceptance/plan_b2_generate_training_sets.sh`**

```bash
#!/usr/bin/env bash
# Wave 1 顺位 17 (B2 generate_training_sets) 机检验收
# 负向断言一律用 if/exit 1（per memory feedback_acceptance_grep_anchoring：set -e 下 ! grep 是死闸门）
set -euo pipefail
cd "$(dirname "$0")/../.."

echo "== G1: 文件存在 =="
test -f backend/generate_training_sets.py
test -f backend/tests/test_generate_training_sets.py
test -f docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md

echo "== G2: 纯层 pytest 全绿（无需 DB）=="
( cd backend && python3 -m pytest tests/test_generate_training_sets.py -q 2>&1 | tee /tmp/b2-accept-pytest.txt | tail -3 )
if grep -qiE "failed|error" /tmp/b2-accept-pytest.txt; then echo "G2 FAIL: pytest 有失败"; exit 1; fi

echo "== G3: 模块可导入 + 符号存在 =="
( cd backend && python3 -c "import generate_training_sets as m; assert all(s in dir(m) for s in ('main','generate_one_training_set','generate_batch','backfill_content_hash'))" )

echo "== G4: 算法落地（D2-D6）=="
grep -q 'rng.randint(30, n - 9)' backend/generate_training_sets.py
grep -qF '[:8]' backend/generate_training_sets.py
grep -q 'bisect_right(three_dts, upper) - 1' backend/generate_training_sets.py
grep -q 'MIN_PERIOD = "3m"' backend/generate_training_sets.py

echo "== G5: content_hash CRC32 口径（D3）=="
grep -qF 'format(zlib.crc32(data) & 0xFFFFFFFF, "08x")' backend/generate_training_sets.py
grep -q 'crc32_hex(zip_path.read_bytes())' backend/generate_training_sets.py

echo "== G6: SQLite schema 语义（D8）=="
grep -q 'PRAGMA user_version = 1' backend/generate_training_sets.py
grep -q 'end_global_index INTEGER NOT NULL' backend/generate_training_sets.py

echo "== G7: 双层边界 — 纯层不顶层 import asyncpg（D1/D13）=="
if grep -qE '^import asyncpg$' backend/generate_training_sets.py; then echo "G7 FAIL: asyncpg 不应顶层 import"; exit 1; fi
grep -q 'import asyncpg' backend/generate_training_sets.py

echo "== G8: deps 无回退 + 不改 schema/workflows（H.1/I.1）=="
if grep -qE '(>=|<|~=)' backend/requirements.txt backend/requirements-dev.txt; then echo "G8 FAIL: requirements 出现 range"; exit 1; fi
if git diff --name-only origin/main...HEAD -- backend/sql/ | grep -q .; then echo "G8 FAIL: 本 PR 不应改 schema"; exit 1; fi
if git diff --name-only origin/main...HEAD -- .github/ | grep -q .; then echo "G8 FAIL: 本 PR 不应碰 .github（CI 延后）"; exit 1; fi

echo
echo "✅ 所有 8 项 G1-G8 验收通过"
```

加可执行：`chmod +x scripts/acceptance/plan_b2_generate_training_sets.sh`

- [ ] **Step 5: 跑机检脚本确认全绿**

Run: `bash scripts/acceptance/plan_b2_generate_training_sets.sh 2>&1 | tail -2`
Expected：`✅ 所有 8 项 G1-G8 验收通过` + exit 0。

- [ ] **Step 6: Commit**

```bash
cd "<repo-root>"
git add backend/docker-compose.yml \
        docs/acceptance/2026-05-29-pr-b2-generate-training-sets.md \
        scripts/acceptance/plan_b2_generate_training_sets.sh
git commit -m "chore(b2): H6-part2 deps 确认 + acceptance §A-§K + 机检脚本 (Task 3)

B2 无新运行时依赖（全标准库 + 已 pin pandas/asyncpg）；best-effort 补 docker digest；
非程序员验收 + 机检脚本（负向断言用 if/exit 1）；residual B2-R1/R2(H7)/R3(CRC32口径)。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
> 注：若 Step 2 未改 `docker-compose.yml`（无 docker），从 `git add` 去掉该文件。

---

## R1 → v2 修订（plan-stage opus 4.8 ultracode adversarial review）

R1 verdict **NEEDS-ATTENTION**（2C/2H/2M/2L），reviewer 装 pandas 2.2.3 / Python 3.9 **实跑** plan 内 impl+test（结果 `1 failed, 17 passed`）+ 手算二分真值验证。全部处理：

| Finding | 严重度 | 真相 / 修订 | 落地位置 |
|---|---|---|---|
| C1 `test_assign_higher_period_end_index_monotonic_and_in_range` 实跑 FAIL（monthly egi 实为 `[0,0,99]` ≠ 断言 `all==0`）| Critical | **测试 bug 非 impl bug**：reviewer 实测的 `[0,0,99]` 正是正确真值（历史 bar 带后继→0、末根→N3-1）。`assign_global_indices` 算法正确。v2 弃用不真实的 `_aligned_windows`，改 `_index_windows()` 手工摆位 + **精确真值断言**（`test_assign_end_global_index_interior_historical_trailing` 断 15m=`[2,5,5]`/60m=`[0,3,5]`/monthly=`[1,5]`）。 | Task 1 测试（assign 段重写）+ D4 注 |
| C2 验收 §F.1/script G6 `grep 'PRAGMA user_version = 1'` 返 0 → `set -e` 下杀脚本（源是 f-string `= {SCHEMA_VERSION}`，无子串 `= 1`）| Critical | **真 bug**：`_TRAINING_SET_DDL` 由 `f"""..."""` 改普通 `"""..."""` + 字面 `PRAGMA user_version = 1;`（逐字对齐冻结 schema 文件 + grep 锚匹配）。SCHEMA_VERSION 常量保留供 dataclass/比较。 | Task 1 impl `_TRAINING_SET_DDL` |
| H1 `test_assemble_training_set_end_to_end` 通过但 vacuous（seed7 start≈1046 天外，3m 仅跨 8 天 → 所有日内周期 after=0，断言平凡真）| High | **真弱测**：`_period_bars` 改**压缩同轴 fixture**（6 周期同覆盖月线轴，monthly_n=39 → start_idx 定值 30，3m 真跨起始点）；e2e 加断言 `min(three_dt)<start<=max`（真跨越）+ `any(0<e<N3-1 for egi15)`（联动非平凡）。 | Task 1 fixture + e2e 测试 |
| H2 plan 丢 spec §8.3 per-period `assert before_count>=30`/`len(after)>=1` 未裁决（before=10 的周期被静默接受）| High | **真缺失**：`assemble_training_set` 每周期加 `before_n>=30 AND after_n>=1` 硬校验 → `GenerateSkipException`（spec L1130-1131/L1144）；D6 补裁决；加 `test_assemble_skip_when_period_before_under_30`。 | D6 + Task 1 impl `assemble` + 新测试 |
| M1 D3 CRC32 裁决正确但 residual 低估下游风险（照 L753 用 `unzip -v` 会误判）| Medium | residual B2-R3 加"**勿用 `unzip -v` 比对**；正确口径 = 对 zip 文件字节重算 crc32（= P2 传输完整性校验）"。 | 验收 §K B2-R3 |
| M2 重试在月线极窄时把同一 start 试满 8 次（写+删 8 次），但终止不死循环 | Medium | **接受 residual B2-R5**：bounded + 终止 + 窄场景；记 §K。 | 验收 §K B2-R5 |
| L1 e2e 测试 `import io` 未用 | Low | 删除。 | Task 1 e2e 测试 |
| L2 plan 标 "Python 3.11+" 但 impl（future annotations）实测 3.9 可跑 | Low | Tech Stack 改 "Python 3.9+（host）"。 | header |

reviewer **VERIFIED-CORRECT（实跑/手算）**：`select_start_index` idx 边界（30→恰 30 前 / len-9→9 根含起始后 8 / n=39 最小 / n=38 抛）、`monthly_after_end` 8 根含起始、`select_period_window` `min(pivot,cap)` 防负切片 + start 落 after 不双计、in-window 高周期联动（15m=`[4,9,…,99]`/60m=`[19,39,…,99]` 末根吸收至 N-1）、3m 自映射 end==global、非 3m global_index=None（object 列 → `to_dict` 出 Python None 不崩）、SQLite typeof 整数列 = "integer"（numpy 经 `to_dict`+cast 规避）、`zip_and_hash` content_hash 自洽、17 列/17 占位符对齐、`with_suffix(".db")` 正确、`rng.randint` 重试间状态推进、§D/E/F(除G6.1)/G grep 锚命中。impl 核心算法 `assign_global_indices` 经实跑确认正确（C1 是测试断言错）。

v2 测试数 17→19（+`test_assemble_skip_when_period_before_under_30`；assign 段 4 个重写但仍 4 个）。修订不改 reviewer 已确认正确的核心算法，仅修测试断言/fixture（C1/H1）、DDL 字面化（C2）、补 spec 硬校验（H2）、doc/residual（M1/M2/L1/L2）。

### R2 → v3 修订（plan-stage opus 4.8 ultracode R2）

R2 verdict **NEEDS-ATTENTION**，但**四项 R1 fix 全部 CONFIRMED FIXED + 实跑 19/19 passed + 手算复核全部 egi 断言精确匹配**；唯一 blocker = doc-vs-code 漂移：

| Finding | 严重度 | 修订 |
|---|---|---|
| R2-H1 plan 的两个 `build_sqlite` 测试仍引用已废弃、未定义的 `_aligned_windows()`（我 v2 只改了 assign 段测试，漏改 build 段）→ 实施者逐字提取会 NameError | High（doc 漂移）| 两处 `assign_global_indices(_aligned_windows())` → `assign_global_indices(_index_windows())`（`_index_windows()` 已含全部 6 PERIODS，build 测试可用）。修后 plan 代码块与已实跑绿的 `/tmp` 验证一致。 |
| R2-L1 `_INT_COLS`/`_FLOAT_COLS` 常量定义后从未引用（impl 逐列 inline cast）| Low | 删除两个 dead 常量。 |
| R2-L2 §G.2 `grep -nc 'import asyncpg'==1` 依赖该行注释不含第二个 `import asyncpg` 子串（实测注释为"局部 import...不依赖 asyncpg"，count==1 成立）| Low（note only）| 接受：锚当前正确；注释措辞勿改含该短语。 |

R2 "VERIFIED-CORRECT" 清单（实跑/手算）：19/19 passed（py3.9.6 + pandas2.2.3）；6 组 egi 断言手算逐一匹配；e2e 非平凡（start_idx 定值 30 / 3m 真跨起始 / egi15 内部值）；before<30 skip 真触发；DDL 字面 == 冻结 schema 文件；17 占位符对齐；`training_sets` 无 UNIQUE → D7 SELECT 预检正确；monthly before-guard 永不误跳（before==start_idx≥30）；Task 2 壳 retry 删对文件 + rng 推进 + bounded 终止 / generate_batch 收敛 / backfill SQL / 7 列对齐 全 sound；验收脚本负向断言全 `if/exit 1`。

**plan-stage 对抗性 review 收敛**：R2 四 fix confirmed + 实跑绿，唯一 doc-drift blocker（R2-H1）+ L1 已修，剩 L2 note-only（锚当前正确）。无 Critical/High 残留。进入 subagent-driven-development。

---

## Self-Review（plan 写完后、push 给 reviewer 前）

**1. Spec 覆盖检查：**

| spec 要求 | 实现 task |
|---|---|
| §B2 职责 月线选起始 → 每周期独立查询 → global/end_global_index → SQLite + user_version → zip → CRC32 → 登记 | Task 1 纯装配（select_start/window/assign/build/zip）+ Task 2 PG 壳（fetch/register/generate_one） |
| §B2 `generate_one_training_set(conn, stock_code)` + `generate_batch(conn, target_count)` | Task 2 `generate_one_training_set` / `generate_batch`（+ output_dir/rng 注入参数，spec 签名超集，便于测试与 B4 复用） |
| §B2 `GeneratedTrainingSet` dataclass（path + content_hash + ...） | Task 1 D9 dataclass |
| §B2 幂等 UNIQUE(stock_code,start_datetime) 冲突重选 | D7 `_exists_start` 预检 + `generate_one` 重试循环（schema 无约束，不新增） |
| §B2 失败 → GenerateSkipException | D5/D6/D7/D10 全路径抛 `GenerateSkipException` |
| §B2 content_hash = `format(zlib.crc32(zip_bytes)&0xFFFFFFFF,'08x')` 8 字符小写 | D3 `crc32_hex` + `zip_and_hash` + 测试 `test_crc32_hex_*` |
| §B2 不变量：月线前≥30 / 之后 8 根月 K 窗口 / end_global_index 二分 / 冲突重选 | D5（月线≥30 选起始）/ D6（8 根窗口 + **per-period before≥30 & after≥1 硬校验**，测 `test_assemble_skip_when_period_before_under_30`）/ D4（二分，测 `test_assign_end_global_index_*`）/ D7（重选） |
| §B2 v1.3 回迁 status='unsent' AND content_hash IS NULL | D11 `backfill_content_hash` + CLI `--backfill` |
| 训练组 SQLite §3.2 DDL（user_version + meta + klines + 2 索引） | D8 `build_training_set_sqlite` 逐字 DDL + 测试 `test_build_sqlite_*` |
| §15.4 H6 deps pin | Task 3 D12 + 验收 §H |
| §15.4 H7 sample 数据 | D14：生成器 + 合成端到端测试；生产数据 residual B2-R2（user 选项 1） |

无 spec 要求缺 task。

**2. 占位扫描：** 无 "TBD/TODO/implement later"。Task 3 Step 2 的 docker digest 是**显式"先查再填 / 无 docker 则不改"指令**（非占位，附"不要编造"约束 + residual 兜底）。

**3. 类型一致性：** `crc32_hex`/`select_start_index`/`monthly_after_end`/`select_period_window`/`assign_global_indices`/`build_training_set_sqlite`/`zip_and_hash`/`assemble_training_set`/`generate_one_training_set`/`generate_batch`/`backfill_content_hash`/`main` 在 Task 1/2 定义与 test import 一致；`GeneratedTrainingSet`/`GenerateSkipException`/`PERIODS`/`SCHEMA_VERSION`/`MIN_PERIOD` 常量定义于 Task 1、test + 壳引用一致；`assemble_training_set` 用 keyword-only（`*`）参数，测试调用同形；`build_training_set_sqlite` 入参 `windows` = `assign_global_indices` 输出（含 `global_index`+`end_global_index` 列），链路对齐；`_KLINE_INSERT` 17 占位符与 17 列顺序一致（period,datetime,open,high,low,close,volume,amount,ma66,boll_upper,boll_mid,boll_lower,macd_diff,macd_dea,macd_bar,global_index,end_global_index）。

**4. Acceptance/script 一致性：** §D/§E/§F/§G/§H grep 锚与 script G4-G8 同字符串；**§F.1 锚 `PRAGMA user_version = 1` 现与 impl 字面 DDL 匹配**（C2 修：DDL 改字面 `1` 不用 f-string `{SCHEMA_VERSION}`，否则 grep 失配杀 `set -e` 脚本）；负向断言（G2 pytest / G7 asyncpg 顶层 / G8 range+schema+workflows）全用 `if grep; then exit 1; fi`（per memory `feedback_acceptance_grep_anchoring` C1）；human-grep §G.1 用 `^import asyncpg$` 行首锚、§D.2/§E.1 用 `-F` 固定串避免 `[`/`(`/`&`/`*` 被正则解释（per 同 memory bug-class，B1 R5-C1 第 6 次复发教训）；§J.1 表格 cell 内 `|` 已 `\|` 转义。

**5. memory 教训落实：** 死闸门 idiom ✅ / 行首+`-F` 锚 ✅ / B1 R1-H2 numpy→python cast 复用（sqlite3 同样拒 numpy 标量）✅ / worktree cwd 三连确认提醒 ✅ / review 工具 = opus 4.8 ultracode 不擅自换 codex ✅ / spec 内部矛盾（CRC32 L750 vs L753）显式裁决不沉默 ✅。

无 plan failure。

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-29-pr-b2-generate-training-sets.md`。

下一步走 user 已指定路径（本次 prompt 显式）：先 **Plan-stage 对抗性 review = Claude Opus 4.8 ultracode effort**（主线 dispatch fresh subagent），收敛 APPROVE 后才进 **subagent-driven-development**（Task 1→2→3，每 Task fresh sonnet implementer + spec reviewer + code-quality reviewer 双道）→ verification-before-completion → requesting-code-review → branch-diff opus 4.8 ultracode review 到收敛 → attest-override + admin merge。
