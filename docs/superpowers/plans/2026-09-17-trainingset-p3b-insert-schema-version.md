# 切片一 P3b：`INSERT INTO training_sets` 补 `schema_version` + 两条按语句匹配的守卫　实施计划

> ⚠️⚠️⚠️ **本文件内嵌的守卫代码是【计划阶段】的形态，与【最终落地版本】已大幅分叉，⛔ 不要当作权威抄用。**
>
> 下面 Task 3 / Task 4 代码块里的守卫①（`test_insert_schema_version_guard.py`）与守卫②
> （`test_training_set_ddl_no_drift.py`），是**5 轮对抗性评审之前**写下的初版（守卫①当时约
> 226 行）。实施过程中经过 6 轮计划评审 + 守卫①单独 5 轮定向复评（含 1 次任务评审），判据被
> **重写过四次**，最终落地版本是 **576 行**（守卫②落地版本也新增了一条「前提检查」测试）。
>
> **⛔ 落地版以仓库里的这两个文件为准，不是以本文件里的代码块为准：**
> - `backend/tests/test_insert_schema_version_guard.py`
> - `backend/tests/test_training_set_ddl_no_drift.py`
>
> 分叉的具体来由（哪一轮评审挖出什么、怎么修的）见：
> - `docs/acceptance/2026-09-17-trainingset-p3b-acceptance.md`（验收清单）
> - `docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md`（逐组变异记录）
> - `.superpowers/sdd/2026-09-17-trainingset-p3b-insert-schema-version/progress.md`（完整台账）
>
> 本仓成文教训：「同一事实 N 份副本 ⇒ 每轮修复造下一个回声」——这段提示就是为了不让这份计划
> 里的旧代码在日后被误当成权威。**下面正文原样保留，不做任何改写。**

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把可执行路径里 **10 处**漏写 `schema_version` 的 `INSERT INTO training_sets` 补齐，并加**两条按 SQL 语句（不是按行）匹配**的机械守卫：①每一条该 `INSERT` 都带 `schema_version`；②生成器内嵌的建表语句与冻结的建表文件**逐语句相同**。

**Architecture:** 两条守卫都写成 Python 测试放进 `backend/tests/`（本仓既有做法）。⭐ **两者的判据形状是同一个**：都必须先把 SQL **按语句归一化**（剥注释、压空白、按 `;` 切），再比 —— 按行比在两处都会产生假结论（见下方「先读」）。

**Tech Stack:** Python 3（pytest）· PostgreSQL DDL · bash / markdown / GitHub Actions YAML 里的内嵌 SQL

**Spec:** `docs/superpowers/specs/2026-09-01-trainingset-timestamp-semantics-design.md` §3.3「关于 PostgreSQL 的 `training_sets.schema_version DEFAULT 1`」那一节的**三步改法**，外加该节点名的「生成器 DDL 字面量 ↔ 冻结 DDL 文件无守卫」残留。

---

## Global Constraints

1. ⛔ **次序不能反**：**先补字段（Task 1–2），再加守卫（Task 3–4）**。spec 明写：先加守卫会立刻红 5 处，进而诱使实施者「把那几处排除掉」—— **正好把缺口原样留下**。
2. ⛔ **不碰 `ios/**`**。本片对 App 侧改动**必须为 0 个文件**。
3. ⛔ **不改 PostgreSQL 的 DDL**（`backend/sql/schema.sql:75` 的 `schema_version INTEGER NOT NULL DEFAULT 1` **保持原样**）。spec 明写去掉那个默认值属 DDL 变更、需要受治理的 migration，**且会让 P6b 形状闸门的 `schema.sql` md5 锚失配、必须重新生成整份闸门文件** —— 代价与收益不成比例。归残留 TS1-R1。
4. ⛔ **不对 `backend/generate_training_sets.py` 与 `backend/sql/training_set_schema_v1.sql` 做任何【永久】改动**。Task 4 的守卫**只读**这两个文件。
   ⚠️ **但变异自测必须改它们**（M0 / M5 / M6 / M7 都要）—— 用 `cp` 备份、跑完立刻还原、`diff` 必须为空，**不在此限**。⛔ 实施者不得按字面把这条读成「连变异都不许做」，那会让 C1 那条最要紧的变异做不成。
5. ⚠️ **`.github/workflows/` 在本仓有单独的推送仪式** ⇒ 碰它的改动**单独成一个 Task**（Task 2），不与别的改动混在一个提交里。
6. ⛔ 变异一律 `cp` 备份/还原，**绝不用 `git checkout <文件>`**；Python 变异前后清 `__pycache__`；每次还原后 `git status --short` 核对。
7. 交付必须含**非程序员可执行**的中文验收清单 + 逐条变异记录。
8. ⛔ **交付话术**：可以说「写库语句已补齐字段、两条漂移守卫已就位」；**不得说**「手机能用了」「跨端契约已闭合」。

### 起点基线（**已在 `origin/main` = `8d47e811` 上实测**，2026-09-17）

| 项 | 命令 | 实测 |
|---|---|---|
| 后端全套 | `cd backend && $PY -m pytest tests/ -q` | **1505 passed**，0 failed / 0 skipped |
| Swift 全套 | `cd ios/Contracts && swift test` | XCTest **302 passed / 0 failed**；swift-testing **1993 tests / 232 suites** |
| 治理脚本套件 | `bash tests/scripts/governance/run-all.sh` | 末行 `ALL GREEN`，无 `FAIL:` |

⚠️ **Swift 的汇总行怎么读**（本片实测踩到的陷阱）：`swift test` 把 swift-testing 的汇总**有时报成 1 块、有时报成 2 块**（本次是 `173 in 24 suites` + `1820 in 208 suites`，合计正好 1993 / 232）。⇒ ⛔ **不能用 `| tail -1` 取汇总行**，那会让人以为测试从 1993 掉到了 173。**稳健口径**：逐条数 `Test Case '…' passed`（应为 302）+ 把所有 `Test run with N tests in M suites` **加起来**（应为 1993 / 232）。

`$PY` = `"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3"`（⚠️ 本 worktree 里**没有** `.venv`）。

---

## ⭐ 先读：两处判据为什么都必须「按语句」而不是「按行」

### (a) `INSERT` 那条：按行比会把**本来就对**的两处误报成缺字段

实测：可执行路径（`backend/` + `docs/runbooks/` + `.github/workflows/`）下 `INSERT INTO training_sets` 共 **15 处**命中，逐条定性后：

| 类别 | 处数 | 位置 |
|---|---|---|
| ⛔ **不是 SQL，必须排除** | **3** | `backend/tests/test_b2_reconnect_integration.py:208` / `:699`（是 `if "INSERT INTO training_sets" in query:` —— **分派条件**，结构上永远不可能「出现 schema_version」）；`backend/tests/test_deployment_source_texts.py:17`（**是 P3c 写的一句注释**） |
| ✅ **真 SQL 且已有该字段** | **2** | `backend/generate_training_sets.py:563-564`、`docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql:63-64` —— ⭐ **两处都跨行** |
| ⛔ **真 SQL 且缺该字段（本片要补）** | **10** | 见 Task 1 / Task 2 的表 |

⇒ 按**单行** grep，那 2 处已合规的跨行语句会被**误报成缺字段**。必须按**一条语句**（从 `INSERT INTO training_sets` 起到该语句的 `;`，Python 里到相邻字符串字面量拼接结束）为单位匹配。

⚠️ **⛔ 不写「仓内共 N 处」这种含自身的总数**：spec §3.3 对这个计数**连栽三轮**，而本片又亲眼见证了一次 —— **上一片（P3c）写的一句注释，让这个数当场 +1**。⇒ 守卫的排除必须**按结构判**（是不是真 SQL），**不能按数量判**。

### (b) 建表语句那条：按行比会让守卫**开局就红**

实测生成器内嵌的 `_TRAINING_SET_DDL`（`backend/generate_training_sets.py:369-385`）与冻结文件 `backend/sql/training_set_schema_v1.sql`：

- **按行归一化比 → 不相等**（冻结文件一列一行；生成器几列挤一行，纯排版差异）
- **按语句归一化比 → 完全相等**（各 **5 条**语句逐条一致：`PRAGMA user_version = 2` / `CREATE TABLE meta` / `CREATE TABLE klines` / 两条 `CREATE INDEX`）

⇒ 按行比，这条守卫**今天就是红的**。本仓成文教训：**一条开局就红的守卫 = 给实施者发放宽许可证**。

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh` | 修改 3 处 | 迁移彩排脚本里的三条 `INSERT`（**跨行**） |
| `docs/runbooks/2026-08-24-qmt-nas-deployment.md` | 修改 2 处 | P9 两条烟测 `INSERT`（**单行**） |
| `.github/workflows/schema-smoke.yml` | 修改 5 处 | schema 烟测的五条 `psql` SQL（**单行**）· ⚠️ **独立推送仪式** |
| `backend/tests/test_insert_schema_version_guard.py` | **新建** | 守卫①：作用域内每一条该 `INSERT` 都带 `schema_version`（按语句匹配） |
| `backend/tests/test_training_set_ddl_no_drift.py` | **新建** | 守卫②：生成器内嵌 DDL ↔ 冻结 DDL **逐语句相同** |
| `docs/acceptance/2026-09-17-trainingset-p3b-acceptance.md` | **新建** | 非程序员验收清单 |
| `docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md` | **新建** | 变异逐条记录 |

---

## Task 1: 补齐 5 处非 CI 配置的 `INSERT`（`rehearse.sh` ×3 + `deployment.md` ×2）

**Files:**
- Modify: `backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh:206`、`:213`、`:443`
- Modify: `docs/runbooks/2026-08-24-qmt-nas-deployment.md:613`、`:645`

**Interfaces:**
- Consumes: 无
- Produces: 这 5 条语句都显式带 `schema_version`，值一律 **`1`**（⚠️ 理由见下）

### ⚠️ 为什么这 5 处补的值是 `1` 而不是 `2`

这 5 条**全都是测试/彩排/烟测用的假数据**，不是真实产物：`rehearse.sh` 是迁移彩排、`deployment.md:613/645` 是 P9 的两条「SMOKE-A / SMOKE-B」烟测行（插完就删）。它们**不代表任何真实训练组的代际**。

⇒ 本片的目的是**让「漏写字段」这件事不可能再发生**（漏写会被 `DEFAULT 1` 静默补上、无人察觉），**不是**把这些假数据升代。显式写 `1` 保持它们**行为逐字不变**，只是把原本隐式的默认值变成显式的。

⛔ **不得改成 `2`** —— 那会改变 `rehearse.sh` 与 P9 烟测的既有断言语义，属范围蔓延。

- [ ] **Step 1: 改 `rehearse.sh:206-207`**

现文：
```sql
INSERT INTO training_sets
  (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)
VALUES
  ('000001', '平安银行', 20260101093000, 20260101150000,
   '/mnt/nas/kline_trainer/datasets/000001/20260101_093000_20260101_150000.zip',
   'a1b2c3d4');
```
改为（只在列清单里加 `schema_version`、在 VALUES 里加对应的 `1`）：
```sql
INSERT INTO training_sets
  (stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)
VALUES
  ('000001', '平安银行', 20260101093000, 20260101150000, 1,
   '/mnt/nas/kline_trainer/datasets/000001/20260101_093000_20260101_150000.zip',
   'a1b2c3d4');
```

- [ ] **Step 2: 改 `rehearse.sh:213-214`**

现文的列清单是：
```sql
  (stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash,
   status, lease_id, lease_expires_at, reserved_at)
```
⇒ 把 `schema_version` 插在 `end_datetime` 之后、`file_path` 之前，并在 `VALUES` 的**对应位置**补 `1`。
⚠️ **列与值必须一一对应** —— 改完务必自己数一遍两边的个数是否相等。

- [ ] **Step 3: 改 `rehearse.sh:443-446`**

它在 `pg_exec overlong_db <<SQL` 的 heredoc 里，形状与 Step 1 相同（6 列），照 Step 1 的办法改。

- [ ] **Step 4: 改 `deployment.md:613` 与 `:645`（单行，两条形状相同）**

现文（`:613`，`:645` 只是 `SMOKE-A`→`SMOKE-B`、`none-a`→`none-b`）：
```
INSERT INTO training_sets(stock_code,stock_name,start_datetime,end_datetime,file_path,content_hash) VALUES('SMOKE-A','SMOKE-A',0,0,'/data/training-sets/none-a.zip','deadbeef') RETURNING id;
```
改为：
```
INSERT INTO training_sets(stock_code,stock_name,start_datetime,end_datetime,schema_version,file_path,content_hash) VALUES('SMOKE-A','SMOKE-A',0,0,1,'/data/training-sets/none-a.zip','deadbeef') RETURNING id;
```

⚠️ 这两行外面包着 `ssh $NAS "docker exec … psql … -c \"…\""` 的多层引号 —— **只动 SQL 本身，一个引号都别碰**。

- [ ] **Step 5: ⭐ 自查列/值个数（跨行统一检查器 —— 上一版这条【结构上看不见 rehearse.sh】）**

⛔ **上一版是错的**（整支评审 R2-M2）：原稿用 `git diff -U0 | grep "^+" | grep "INSERT INTO training_sets\|VALUES"`。而 `rehearse.sh` 那三条里，**要改的两行**（列清单行、数据行）**都不含这两个关键词** —— 于是恰好被过滤掉，真跑只输出 2 行，**看不见的正是最难的那 3 条**（跨行；其中一条 10 列、VALUES 里有 3 个函数调用）。而**全仓无人执行 `rehearse.sh`**（`backend/tests/test_migrations.py:139` 只把它当**文本**读）⇒ 列/值错位会静默随 PR 合并。

⇒ 改用下面这个**跨行**检查器（与 Task 2 Step 2 同一份逻辑，一次看全 10 处）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" - <<'PY'
import re, pathlib

HEAD = re.compile(r'INSERT\s+INTO\s+(?:"?[A-Za-z_][\w$]*"?\s*\.\s*)?"?training_sets"?\b', re.I)

def balanced(t, pos):
    """从 pos 起找左括号，**括号配平**取出里面的文本（跨行有效）。"""
    m = re.compile(r"[\s\"'\\+,)]*\(").match(t, pos)
    if not m: return None
    d, i = 0, m.end() - 1
    while i < len(t):
        if t[i] == "(": d += 1
        elif t[i] == ")":
            d -= 1
            if d == 0: return t[m.end():i]
        i += 1
    return None

def top_split(x):
    """顶层逗号切分：括号内的逗号（NOW() 等函数实参）不算。"""
    out, d, cur = [], 0, ""
    for ch in x:
        if ch == "(": d += 1
        elif ch == ")": d -= 1
        if ch == "," and d == 0: out.append(cur); cur = ""
        else: cur += ch
    out.append(cur); return out

FILES = ["backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh",
         "docs/runbooks/2026-08-24-qmt-nas-deployment.md",
         ".github/workflows/schema-smoke.yml"]
seen = bad = 0
for f in FILES:
    t = pathlib.Path(f).read_text(encoding="utf-8")
    for m in HEAD.finditer(t):
        cols = balanced(t, m.end())
        if cols is None: continue
        vk = re.compile(r"\s*VALUES", re.I).search(t, m.end())
        vals = balanced(t, vk.end()) if vk else None
        if vals is None: continue
        seen += 1
        nc, nv = len(top_split(cols)), len(top_split(vals))
        has = "schema_version" in cols
        ok = (nc == nv and has)
        if not ok: bad += 1
        print(f"{'✅' if ok else '❌'} {f.split('/')[-1]}:{t.count(chr(10),0,m.start())+1}"
              f"  列={nc} 值={nv} 含 schema_version={has}")
print(f"\n共看到 {seen} 条（要 10）；不合格 {bad} 条（要 0）")
PY
```

**期望**：`共看到 10 条；不合格 0 条`，且**每一行都是 `✅`**。

⚠️ **这一步要跑两次**：
- **Task 1 做完、Task 2 还没做时**：`rehearse.sh` 与 `deployment.md` 那 5 条应为 `✅`，`schema-smoke.yml` 那 5 条仍为 `❌`（`含 schema_version=False`）—— **这是预期的中间态**；
- **Task 2 也做完后**：10 条全 `✅`。

⭐ 这个检查器**抓得住「只加列、不加值」**（实测：故意只在列清单加一项 ⇒ 该行报 `列=7 值=6 ❌`），而上一版的 grep 对这三条**完全看不见**。

- [ ] **Step 6: 跑全套，确认零 delta**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```
期望 **1505 passed**（本任务不新增测试；若有测试在读这两个文件的文本，这里会立刻暴露）。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run" && bash tests/scripts/governance/run-all.sh
```
期望末行 `ALL GREEN`。
⚠️ **这条的路径相对【仓库根】**，不是 `backend/`（实测 `backend/tests/scripts/…` 不存在）。上一条 pytest 把你留在了 `backend/`，所以这里必须先回到仓库根 —— 否则报 `No such file`。

- [ ] **Step 7: 提交**

```bash
git add backend/sql/migrations/0004_qmt_price_double_and_coverage/rehearse.sh docs/runbooks/2026-08-24-qmt-nas-deployment.md
git commit -F <(printf '%s\n' 'fix(p3b): 5 处非 CI 的 INSERT INTO training_sets 补上 schema_version' '' 'PostgreSQL 那一列是 NOT NULL DEFAULT 1 —— 漏写不报错，会【静默】把行标成第 1 代。' '这 5 处（rehearse.sh 三条、runbook P9 两条烟测）全是测试/彩排用的假数据，' '故显式写 1、保持行为逐字不变，只是把隐式默认变成显式。⛔ 不改成 2（那会改变既有断言语义）。' '' '⚠️ 次序：先补字段、再加守卫（Task 3）。反了的话守卫一上来就红 5 处，' '会诱使实施者「把那几处排除掉」，正好把缺口原样留下（spec §3.3 明写）。')
```

---

## Task 2: 补齐 CI 配置里的 5 处（`.github/workflows/schema-smoke.yml`）

**Files:**
- Modify: `.github/workflows/schema-smoke.yml:73`、`:76`、`:79`、`:82`、`:85`

**Interfaces:**
- Consumes: Task 1 已定下「值写 `1`」的口径
- Produces: 这 5 条也都显式带 `schema_version`

⚠️ **本任务单独成一个提交**，因为本仓对 `.github/workflows/` 有单独的推送仪式。⛔ 不要把它与 Task 1 的改动混进同一个提交。

### 这 5 条各自在测什么（改之前必须看懂，别改坏了断言）

| 行 | 前缀 | 它在证明什么 |
|---|---|---|
| `:73` | `! psql` | `content_hash` 大写十六进制应被**拒绝** |
| `:76` | `! psql` | `status` 非法值应被**拒绝** |
| `:79` | `! psql` | `unsent` 状态却带 lease 字段应被**拒绝** |
| `:82` | `! psql` | `reserved` 状态却缺 lease 字段应被**拒绝** |
| `:85` | `psql`（**无 `!`**）| 合法行应**插入成功** |

⚠️ 前四条开头的 `!` 是「**这条必须失败**」的意思。⛔ **一个 `!` 都不能动** —— 动了会把「拒绝」测成「接受」，而套件照样绿（本仓「全是拒了的套件 → 恒抛的守卫处处像在工作」那条教训的反面）。

- [ ] **Step 1: 五条逐条改（只在列清单里加 `schema_version`、在 VALUES 对应位置加 `1`）**

以 `:73` 为例，现文：
```yaml
          ! psql -v ON_ERROR_STOP=1 -c "INSERT INTO training_sets(stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash) VALUES ('X', 'Y', 0, 0, 'f', 'ABCDEF12');"
```
改为：
```yaml
          ! psql -v ON_ERROR_STOP=1 -c "INSERT INTO training_sets(stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash) VALUES ('X', 'Y', 0, 0, 1, 'f', 'ABCDEF12');"
```

其余四条同理：`schema_version` 插在 `end_datetime` 之后、`file_path` 之前；`VALUES` 里对应位置插 `1`。
⚠️ `:79` 与 `:82` 的列更多（带 `status` / `lease_*`），**插入位置仍是 `end_datetime` 之后**，别插到末尾去。

- [ ] **Step 2: 逐条核对列/值个数（⚠️ 必须用括号配平，不能用 `[^)]*`）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" - <<'PY'
import re, pathlib

def balanced(t, start):
    """从 `start` 处的 `(` 扫到它的**配对** `)`，返回中间的文本。"""
    m = re.compile(r"\s*\(").match(t, start)
    if not m: return None
    depth, i = 0, m.end() - 1
    while i < len(t):
        if t[i] == "(": depth += 1
        elif t[i] == ")":
            depth -= 1
            if depth == 0: return t[m.end():i]
        i += 1
    return None

p = pathlib.Path(".github/workflows/schema-smoke.yml")
for n, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
    k = line.find("INSERT INTO training_sets")
    if k == -1: continue
    cols = balanced(line, k + len("INSERT INTO training_sets"))
    vk = line.find("VALUES", k)
    vals = balanced(line, vk + len("VALUES")) if vk != -1 else None
    if cols is None or vals is None:
        print(f"❌ :{n}  括号没配平（列={cols is not None} 值={vals is not None}）"); continue
    # 顶层逗号切分：括号内的逗号（如 NOW(), 函数实参）不算
    def top_split(x):
        out, d, cur = [], 0, ""
        for ch in x:
            if ch == "(": d += 1
            elif ch == ")": d -= 1
            if ch == "," and d == 0: out.append(cur); cur = ""
            else: cur += ch
        out.append(cur); return out
    nc, nv = len(top_split(cols)), len(top_split(vals))
    ok = "✅" if nc == nv else "❌"
    print(f"{ok} :{n}  列={nc}  值={nv}  含 schema_version={'schema_version' in cols}")
PY
```

**期望**：**5 行全部 `✅`，且 `含 schema_version=True`**。

⚠️ **上一版这一步是错的**（整支评审 M2 打回）：原稿用 `re.search(r"VALUES\s*\(([^)]*)\)", line)`，而 `[^)]*` 在 `:79` 的 `NOW()` 处**提前截断** ⇒ 那一行**结构上恒报 ❌**，与写死的期望「5 行全部 ✅」直接冲突。实施者当时只有两条路，**两条都坏**：
- 照期望「把它变绿」—— 最省事的做法是从 `:79` 删掉一个 lease 列。那是 `! psql`（**必须失败**）的用例，删完 INSERT 仍会被约束拒绝、`!` 仍成立、**套件照样绿**，但它测的场景已被悄悄换掉；
- 判定「脚本不准」而整步跳过 —— 那 5 条改动的列/值对齐就**没有任何机械检查**了。

⇒ 本版改成**括号配平 + 顶层逗号切分**（与 Task 3 守卫同一个思路）。⚠️ **期望输出必须先真跑一遍再抄**，⛔ 不许照抄本计划里的字样就交。

- [ ] **Step 3: 确认那四个 `!` 一个没少**

```bash
grep -c '! psql -v ON_ERROR_STOP=1 -c "INSERT INTO training_sets' .github/workflows/schema-smoke.yml
```
期望：**4**（单独跑这一行，别接 `&&`）。

- [ ] **Step 4: YAML 还能解析吗**

```bash
"/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -c "import yaml,sys; d=yaml.safe_load(open('.github/workflows/schema-smoke.yml')); print('YAML OK, jobs =', list(d['jobs'].keys()))"
```
期望：打印 `YAML OK, jobs = [...]`。

- [ ] **Step 5: 提交（单独一个）**

```bash
git add .github/workflows/schema-smoke.yml
git commit -F <(printf '%s\n' 'fix(p3b): schema-smoke 的 5 条 INSERT 补上 schema_version' '' '⚠️ 本提交只碰 .github/workflows/ —— 本仓对它有单独的推送仪式，故单独成一个提交。' '' '⛔ 四条 `! psql`（意为「这条必须失败」）的感叹号一个没动 —— 动了会把「拒绝」测成' '「接受」而套件照样绿。第五条无感叹号、测的是合法行应插入成功。' '值一律写 1，与 Task 1 同口径：这些是烟测假数据，目的是消灭「漏写」而不是升代。')
```

---

## Task 3: 守卫① —— 每一条该 `INSERT` 都必须带 `schema_version`（按语句匹配）

**Files:**
- Create: `backend/tests/test_insert_schema_version_guard.py`

**Interfaces:**
- Consumes: Task 1、Task 2 已把 10 处补齐（⇒ 本守卫写完就应当是绿的）
- Produces: 一条机械判据，任何新增的漏写 `INSERT` 都会被抓到

- [ ] **Step 1: 先确认此刻 10 处都补齐了（守卫写之前）**

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
grep -rn "INSERT INTO training_sets" backend/ docs/runbooks/ .github/workflows/ | grep -v "schema_version" | grep -v 'in query' | grep -v "test_deployment_source_texts"
```
⚠️ 上面这条是**粗筛**（按行），跨行语句会漏网 —— 它只是让你先看一眼。真正的判据在下一步的守卫里。

- [ ] **Step 2: 新建守卫文件**

```python
# backend/tests/test_insert_schema_version_guard.py
"""守卫：可执行路径里每一条 `INSERT INTO training_sets` 的【列清单】都必须含 `schema_version`。

⭐ 为什么要紧：PostgreSQL 那一列是 `schema_version INTEGER NOT NULL DEFAULT 1`
   （`backend/sql/schema.sql:75`）—— 漏写**不会报错**，会**静默**把行标成第 1 代。
   作用域里**唯一真正往生产库写行**的是 `_register_training_set`
   （`backend/generate_training_sets.py:554-567`），其余全是彩排 / 烟测 / 提及。

⛔ **判据是「`schema_version` 是不是列清单里的一个【列名】」** —— 既不是「它在某段文本里出现过」，
   **也不是「它是列清单的子串」**（见 `_column_names` 的说明：子串判据会被 `old_schema_version` 假通过）。
   这一版是整支对抗性评审 C1 打回后重写的。上一版「从命中点切到下一个 `;`，找不到就往后
   取 2000 字符，然后在这段文本里搜词」对那条唯一的生产语句**零判别力**：它是 Python
   字符串拼的、**整条 SQL 里没有分号**，窗口于是吞进了下面那行实参 `gts.schema_version`
   —— 把字段从 SQL 列清单里删掉，守卫**照样放行**（spec §3.3 / B23 明令必须变红的那条变异）。
   ⛔ 而且上一版把失效方向**说反了**（写「窗口取长更容易发现缺字段」）：判据是
   `not in`，**窗口越长子串越可能命中，越容易【假通过】**。

⛔ **不写「真 SQL 只有 N 种形状」这类穷尽性断言**（评审 M3）：本文件只**认得**下面几种，
   **认不出的形状默认归宿是「响」**（`unknown` 必报），不是「静默放行」。
   ⚠️ **准确说法**（R2-M1 / R4-M1 两轮打回后订正）：认不出**且列清单解析得出来**的形状归宿是「响」；
   而**解析不出列清单、又恰好被引号包住**的会被当成「提及」**静默跳过** —— 这是本守卫**已知的静默通道**。
   ⛔ 因此**不得**写〔废〕「其余一律必报」这类全称断言。已知的静默通道逐条列在残留 2（**不写总数**）。
   · 带列清单（含 `AS t` / 裸别名 / `public.` 前缀 / 多空白 / 大小写任意）→ 解析列清单；
   · 不带列清单（`VALUES` / `SELECT` / `DEFAULT` / `OVERRIDING` 紧跟）→ **一律必报**
     （按位置插入 ⇒ **本守卫不接受这种写法**）；
   · 整体被同一种引号或反引号包住 → 只是**提及**（Python 字符串谓词、markdown 反引号）；
   · **其余**（例如 `INSERT INTO training_sets WITH …`）→ **必报为「未知形状」**。

⛔ **排除项按结构判、不按数量判**：spec 对「共有几处」这个计数连栽三轮，而上一片（P3c）
   写的一句文档字符串又让命中数 +1。故本文件**不写任何总数**。
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent

# ⛔ 作用域 = spec §3.3 亲自枚举的三类【可执行】路径。
_SCOPE_DIRS = [REPO_ROOT / "backend",
               REPO_ROOT / "docs" / "runbooks",
               REPO_ROOT / ".github" / "workflows"]
# ⚠️ 后缀白名单是**静默**盲区：日后往作用域里放 `.txt` / `.env` / `.psql` 之类
#    同样会被执行的文件，会被悄悄漏掉、不报错。新增后缀必须回来补。
_SUFFIXES = (".py", ".sql", ".sh", ".md", ".yml", ".yaml")

# ⚠️ 三条正则的大小写策略必须一致 —— 上一版 needle 不带 `re.I` 而形状正则带，
#    导致 `re.I` 在整条链路上是装饰品（小写写法在第一步就丢了）。
# ⚠️ 表头允许标识符带双引号（`INSERT INTO "training_sets"` / `"public"."training_sets"`）——
#    整支评审 R2-M1：上一版对这两种写法**零命中**，整条语句静默漏掉。
_HEAD = re.compile(r'INSERT\s+INTO\s+(?:"?[A-Za-z_][\w$]*"?\s*\.\s*)?"?training_sets"?\b', re.I)
_NO_COLS = re.compile(r"\s*(VALUES|SELECT|DEFAULT|OVERRIDING)\b", re.I)
_ALIAS = re.compile(r"\s*(?:AS\s+)?(?!VALUES\b|SELECT\b|DEFAULT\b|OVERRIDING\b)[A-Za-z_]\w*", re.I)
# ⭐ 允许跨过 Python 相邻字符串字面量拼接的引号 / 反斜杠 / 加号 —— 生产语句正是这种写法
_OPEN_PAREN = re.compile(r"[\s\"'\\+,)]*\(")
_QUOTES = "\"'`"

_SELF = Path(__file__).resolve()


def _iter_files():
    for d in _SCOPE_DIRS:
        if not d.is_dir():
            raise AssertionError(f"作用域目录不存在：{d} —— 是不是被改名/移走了？")
        for q in sorted(d.rglob("*")):
            if q.is_file() and q.suffix in _SUFFIXES and "__pycache__" not in q.parts:
                if q.resolve() != _SELF:
                    yield q


def _column_list(text: str, pos: int) -> str | None:
    """从 `pos` 起找列清单的左括号，**括号配平**取出里面的文本。取不到返回 None。"""
    m = _OPEN_PAREN.match(text, pos)
    if not m:
        return None
    depth, i = 0, m.end() - 1
    while i < len(text):
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
            if depth == 0:
                return text[m.end():i]
        i += 1
    return None                      # 括号没配平 ⇒ 交给「未知形状」必报


def _top_split(x: str) -> list[str]:
    """顶层逗号切分：括号内的逗号（函数实参等）不算。"""
    out, d, cur = [], 0, ""
    for ch in x:
        if ch == "(":
            d += 1
        elif ch == ")":
            d -= 1
        if ch == "," and d == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def _column_names(cols: str) -> set[str]:
    """把列清单切成**列名集合**（小写）。

    ⛔ **判据必须是【列名精确相等】，不能是子串 `"schema_version" in cols`**
       —— 控制者自查发现（R4 轮）：子串判据会被 `old_schema_version`、
       `schema_version_legacy`、甚至「列清单里的注释提到它」**假通过**。
       ⭐ 这正是本仓成文教训「裸子串 `= 1` 会被 `= 12` 满足，必须加词界」的同一个形状
       —— 而那条教训是本片作者在上一片（P3a）亲手写下的。
    ⚠️ 要吃得下生产语句那种 Python 拼接后**残留引号**的列清单
       （`… end_datetime, "\n        "schema_version, …`）。
    """
    cols = re.sub(r"--[^\n]*", "", cols)          # 剥 SQL 行注释
    names = set()
    for part in _top_split(cols):
        part = part.strip().strip('"').strip()
        m = re.match(r'"?([A-Za-z_][\w$]*)"?', part)
        if m:
            names.add(m.group(1).lower())
    return names


def _classify(text: str, a: int, b: int):
    """(a, b) = 表头匹配的起止。返回 ('cols', 列清单) / ('nocols',None) / ('mention',None) / ('unknown',None)

    ⛔ **顺序不能反：先试 SQL，试不成才判「提及」**（整支评审 R2-M1）。
       上一版先按「整体被引号包住」判提及，结果把**最常见的 Python 拼接写法**
       `q = "INSERT INTO training_sets" " (a, b) VALUES ($1,$2)"` 判成提及、**静默漏掉**
       —— 而那恰恰是生产语句最可能被重构成的样子。
       倒过来之后：这种写法的列清单能解析出来 ⇒ 判为真语句；而 `if "…" in query:`
       解析不出列清单 ⇒ 才落到「提及」。三处合法提及实测仍判对。
    """
    if _NO_COLS.match(text, b):
        return ("nocols", None)

    m = _ALIAS.match(text, b)        # 可选别名：INSERT INTO x AS t (...) / INSERT INTO x t (...)
    if m:
        if _NO_COLS.match(text, m.end()):
            return ("nocols", None)
        cols = _column_list(text, m.end())
        if cols is not None:
            return ("cols", cols)

    cols = _column_list(text, b)
    if cols is not None:
        return ("cols", cols)

    # 试不成 SQL，才看是不是被引号/反引号整体包住的**提及**
    before = text[a - 1] if a > 0 else ""
    after = text[b] if b < len(text) else ""
    if before in _QUOTES and after in _QUOTES:
        return ("mention", None)
    return ("unknown", None)


def test_every_executable_insert_carries_schema_version():
    """每一条真 `INSERT INTO training_sets` 的列清单里都必须有 `schema_version`。"""
    missing, positional, unknown, checked = [], [], [], 0

    for q in _iter_files():
        try:
            text = q.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError) as e:
            # ⛔ 不把「读不了」混进「不是目标」：读不了必须**响**。
            raise AssertionError(f"作用域内的文件读不了，无法判定：{q} —— {e}") from e

        for m in _HEAD.finditer(text):
            rel = q.relative_to(REPO_ROOT).as_posix()
            where = f"{rel}:{text.count(chr(10), 0, m.start()) + 1}"
            kind, cols = _classify(text, m.start(), m.end())
            if kind == "mention":
                continue
            if kind == "nocols":
                positional.append(where)
            elif kind == "unknown":
                unknown.append(where)
            else:
                checked += 1
                if "schema_version" not in _column_names(cols):
                    missing.append(f"{where}  列清单={cols.strip()[:120]}")

    # ⛔ 防空转：一条列清单都没解析到 ⇒ 作用域或解析坏了，而不是「全都合规」。
    assert checked >= 2, f"只解析到 {checked} 条列清单 —— 作用域或括号配平坏了"

    # ⭐ **锚点加固**（整支评审 R4-M1）：宽守卫有一条**结构性**静默通道 ——
    #    把 SQL 头抽成模块常量（`_INSERT_HEAD = "INSERT INTO training_sets"` 这种**寻常重构**）
    #    之后，列清单解析不出来、而表名两侧恰好是引号 ⇒ 落进「提及」**被静默跳过**；
    #    此时再把 `schema_version` 删掉，守卫**仍然绿**，连 M0 那组变异也一并变成恒真。
    # ⇒ 本断言要求：**生产文件里必须至少有 1 条被认出来的 `INSERT`**，认不出就响。
    # ⚠️ **它接得住什么、接不住什么**（R5-M3 实测后订正 —— ⛔ 上一版写〔废〕「不依赖形状判据」是**假的**）：
    #    · 接得住：SQL 被重构成变量拼接 / f-string / 搬去别的文件 ⇒ `gen_seen` 掉到 0 ⇒ 响；
    #    · ⛔ 接不住：**判据本身被改坏**（退回子串 / 退回旧判定顺序 / 去掉双引号支持）——
    #      实测这三种下 `gen_seen` 仍为 1、一声不吭。它用的就是 `_HEAD`/`_classify`，
    #      是同一判据的**回声**，不是独立第二来源。判据被改坏由变异 M0/M4c–M4f 负责发现。
    gen_src = (REPO_ROOT / "backend" / "generate_training_sets.py").read_text(encoding="utf-8")
    gen_seen = sum(1 for m in _HEAD.finditer(gen_src)
                   if _classify(gen_src, m.start(), m.end())[0] == "cols")

    # ⛔ **三类问题必须一次全报，不能用三条 assert 串起来**：只要前一条炸了，
    #    后面的就永远执行不到 —— 而 `missing` 才是本守卫的**招牌判据**。
    #    本仓成文教训：「断言顺序导致招牌判据从未执行」。
    problems = []
    if gen_seen < 1:
        problems.append(
            "【生产语句脱离视野】`backend/generate_training_sets.py` 里一条都认不出 "
            "`INSERT INTO training_sets` 的列清单 —— 唯一真正写生产库的那条语句本守卫已经看不见了"
            "（多半是 SQL 被重构成变量拼接 / f-string / 搬去了别处）。"
            "⛔ 这不是「它没问题」，是「守卫看不见它了」。")
    if unknown:
        problems.append(
            "【认不出的形状】必须由人来定性（是真语句就补 `schema_version` 并把该形状加进判据；"
            "是提及就说明理由）：\n  " + "\n  ".join(unknown))
    if positional:
        problems.append(
            "【不写列清单、按位置插入】**本守卫不接受这种写法**，必须改成显式列清单：\n  "
            + "\n  ".join(positional))
    if missing:
        problems.append(
            "【列清单里没有 `schema_version`】PostgreSQL 会用 `DEFAULT 1` **静默**把行标成第 1 代，"
            "而所有闸门照样绿：\n  " + "\n  ".join(missing))

    assert not problems, (
        f"`INSERT INTO training_sets` 守卫发现 {len(problems)} 类问题：\n\n"
        + "\n\n".join(problems))
```

### ⭐ 这版判据是【整支对抗性评审 C1/M3 打回后】重写的，证据如下

**上一版错在哪**（评审 C1，我已复跑证实）：判据是「从命中点切到下一个 `;`，找不到就往后取 2000 字符，然后在这段文本里搜词」。而作用域里**唯一真正写生产库**的那条语句是 Python 字符串拼的、**整条 SQL 里没有分号**：

```
needle 在 :563 ；命中点之后整份文件再无分号 ⇒ 窗口走「退化到 2000 字符」，实测长度 2001
窗口里 'schema_version' 出现 2 次：一次在 SQL 列清单里，一次是下一行的 Python 实参 gts.schema_version
```

⇒ 施加 spec §3.3 / B23 **明令必须变红**的那条变异（把字段从 SQL 列清单里删掉、保留实参），守卫**不红**：

```
[原文]   offender=0   [变异后] offender=0     ← 恒绿，零判别力
```

⛔ 而且上一版在两处把失效方向**说反了**（「窗口取长更容易发现缺字段、不会静默放行」）。判据是 `not in` ——**窗口越长子串越可能命中，越容易假通过**。那两句已删除。

**新判据实测**（当前树，与上一版分类逐条相同）：

```
列清单缺字段 = 10    列清单已有 = 2    不带列清单 = 0    未知形状 = 0    提及 = 3
```

**对抗关**：计划阶段逐条构造过多种写法（大小写 / `public.` 前缀 / 双引号标识符 / `AS` 别名 / 裸别名 / `OVERRIDING` / 不带列清单 / `WITH` / 跨行 / Python 相邻字面量拼接 / 多空白 / 字符串谓词 / markdown 反引号 / 注释掉的真 SQL / 列名前后缀相同 / 列清单内注释 …）。

⛔ **这里刻意不再抄那张逐行表**（R5 收口）：一次性演示**不是钉子**，而抄一份表就多一个会漂移的台账 —— 前五轮里「形状种数」这个数字被打回过两次。**真正钉住判据的是变异 M0 / M4c–M4f**，它们可复跑、且各自绑定一处具体修复。

- [ ] **Step 3: 跑，确认绿**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -v
```
期望 **1 passed**。⛔ 若是红的，**别改判据去迁就** —— 先看它点名的是哪一处，那说明 Task 1/2 漏补了。

- [ ] **Step 3b: ⭐⭐ 变异 M0 —— spec §3.3 / B23 明令的那一条（最要紧，上一版正是在这里恒绿）**

把 `schema_version` 从**唯一那条生产语句的 SQL 列清单**里删掉，**保留**下面那行 Python 实参 `gts.schema_version`。守卫必须**红并点名 `backend/generate_training_sets.py:563`**。

⚠️ 这一条是**判据正确性的要害** —— 上一版判据在这里 `offender=0`（恒绿），整条守卫对唯一会毁数据的那处**零判别力**。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
cp backend/generate_training_sets.py /tmp/m0.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("backend/generate_training_sets.py")
s = p.read_text(encoding="utf-8")
old = '"schema_version, file_path, content_hash) VALUES ($1,$2,$3,$4,$5,$6,$7) "'
assert s.count(old) == 1, f"锚点命中 {s.count(old)} 次，应为 1 —— 中止，不写文件"
new = '"file_path, content_hash) VALUES ($1,$2,$3,$4,$5,$6) "'
p.write_text(s.replace(old, new), encoding="utf-8")
print("M0 已施加：SQL 列清单里删掉 schema_version（Python 实参仍在）")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m0.bak backend/generate_training_sets.py
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
diff /tmp/m0.bak backend/generate_training_sets.py && echo "M0 还原逐字一致"
git status --short
```

**期望**：**1 failed**，失败信息属于「**列清单里没有**」那一条（⛔ 不是「未知形状」也不是「按位置插入」—— 报错的必须是**对应的**那条），且**点名 `backend/generate_training_sets.py:563`**。
⛔ 若它**没红**，说明判据又退回了「在一段文本里搜词」的形态 —— **改判据，不许改期望**。

⚠️ 本条会临时改 `generate_training_sets.py`。Global Constraint 4 已明写：**变异用的 `cp` 备份/还原不在「不许改」之列**。还原后 `diff` 必须为空、`git status --short` 里该文件**不得出现**。

- [ ] **Step 4: 变异 M1 —— 把某一处的字段删掉，守卫必须红并点名**

```bash
cp .github/workflows/schema-smoke.yml /tmp/m1.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path(".github/workflows/schema-smoke.yml")
s = p.read_text(encoding="utf-8")
n = s.count("end_datetime, schema_version, file_path")
assert n >= 1, f"锚点命中 {n} 次 —— 中止，不写文件"
p.write_text(s.replace("end_datetime, schema_version, file_path", "end_datetime, file_path", 1), encoding="utf-8")
print("M1 已施加：删掉第 1 处的列名")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m1.bak .github/workflows/schema-smoke.yml
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
diff /tmp/m1.bak .github/workflows/schema-smoke.yml && echo "M1 还原逐字一致"
git status --short
```
期望：**1 failed**，失败信息**点名 `.github/workflows/schema-smoke.yml` 与行号**。

- [ ] **Step 5: ⭐ 变异 M2 —— 把一条【跨行且本来合规】的语句的字段删掉**

这一条证明「按语句匹配」真的有用：按行 grep 抓不到跨行语句。

```bash
cp docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql /tmp/m2.bak
python3 - <<'PY'
import pathlib
p = pathlib.Path("docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql")
s = p.read_text(encoding="utf-8")
old = "(stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash)\nSELECT stock_code, stock_name, start_datetime, end_datetime, schema_version, file_path, content_hash"
assert s.count(old) == 1, f"锚点命中 {s.count(old)} 次 —— 中止"
new = "(stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash)\nSELECT stock_code, stock_name, start_datetime, end_datetime, file_path, content_hash"
p.write_text(s.replace(old, new), encoding="utf-8")
print("M2 已施加：跨行语句的字段被删")
PY
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m2.bak docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
diff /tmp/m2.bak docs/runbooks/2026-08-24-qmt-nas-p11-insert-training-sets.sql && echo "M2 还原逐字一致"
git status --short
```
期望：**1 failed** 并点名该 `.sql` 文件。⭐ **这条红了，才证明守卫真的按语句在看**。

- [ ] **Step 6: ⭐ 变异 M3 —— 把防空转那条打掉，证明它不是恒真**

把 `_SCOPE_DIRS` 临时改成一个**不含任何 INSERT 的目录**（例如只留 `REPO_ROOT / "docs" / "runbooks"` 改成 `REPO_ROOT / "docs" / "acceptance"`），守卫必须因 `checked >= 2` 而红，**且报的是「作用域或语句切分坏了」**，不是「全都合规」。

⛔ 这一条不改业务文件，只临时改守卫自身；用 `cp` 备份还原。

- [ ] **Step 7: 变异 M4 —— 证明「排除项」没把守卫弄瞎**

往 `backend/tests/test_b2_reconnect_integration.py` **临时**加一条**真的缺字段的 SQL**（例如在文件末尾加一行 `_TMP = "INSERT INTO training_sets(stock_code) VALUES ('X');"`），守卫必须**红并点名它** —— 证明「排除字符串谓词」没有把整个文件排除掉。

⛔ 用 `cp` 备份还原；还原后 `git status --short` 必须干净。

- [ ] **Step 7b: ⭐ 变异 M4b —— 证明「按位置插入」那条分支不是恒真**

该分支今天命中数是 **0**。⛔ **零命中的分支必须单独证伪**，否则它是恒真的、白写。

往 `docs/runbooks/2026-08-24-qmt-nas-deployment.md` **临时**追加一行：

```
INSERT INTO training_sets VALUES ('X','Y',0,0,'/tmp/f.zip','abcdef12');
```

守卫必须**红**，且失败信息是**「不写列清单、按位置插入」**那一条（⛔ 不是「没写 schema_version」那一条 —— 两条信息不一样，报错的必须是**对应的**那条，否则说明分支判错了）。

用 `cp` 备份还原；还原后 `diff` 必须为空、`git status --short` 干净。

- [ ] **Step 7c: ⭐⭐ 变异 M4c / M4d / M4e —— 把【本轮三处修复】各自钉住**

⛔ **整支评审 R3-M1 打回**：R2 那一轮为修 R2-M1 改了三处判据（`_classify` **判定顺序**、`_HEAD` 允许**双引号标识符**、`unknown` **兜底必报**），但**一条变异都没有** —— 实测把它们逐一退回旧形态，原有 6 组守卫①变异与真实树判定**逐格不变**。也就是说：**这三处修复没有任何东西钉着，有人退回去一切照样绿**。

⇒ 三组变异都是「**往作用域里注入一条该形状的语句**」，跑完还原。用同一个宿主文件即可：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
T=docs/runbooks/2026-08-24-qmt-nas-deployment.md
cp $T /tmp/m4x.bak

# —— M4c：Python 拼接、表名独占一个字面量（钉「判定顺序」）——
printf '\n```\nq = "INSERT INTO training_sets" " (stock_code, file_path) VALUES ($1,$2)"\n```\n' >> $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m4x.bak $T

# —— M4d：双引号标识符（钉「_HEAD 放宽」）——
printf '\n```\nINSERT INTO "training_sets" (stock_code, file_path) VALUES (1,2);\n```\n' >> $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m4x.bak $T

# —— M4e：未知形状（钉「兜底必报」）——
printf '\n```\nINSERT INTO training_sets WITH c AS (SELECT 1) SELECT 1;\n```\n' >> $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m4x.bak $T

find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
diff /tmp/m4x.bak $T && echo "M4c/M4d/M4e 还原逐字一致"
git status --short
```

**期望（⚠️ 注意判的是「落进哪一类」，不是「红不红」）**：本片做完之后守卫本来就是绿的，所以三条都必须让它**变红**，且**报错的类别必须对**：

| 变异 | 注入的形状 | 必须落进 | 它钉的是 | 退回旧形态会怎样 |
|---|---|---|---|---|
| **M4c** | `q = "INSERT INTO training_sets" " (a, b) VALUES …"` | **【列清单里没有】** | `_classify` 先试 SQL、后判提及 | 旧顺序判成「提及」⇒ **静默漏掉** |
| **M4d** | `INSERT INTO "training_sets" (a, b) VALUES …` | **【列清单里没有】** | `_HEAD` 允许双引号标识符 | 旧正则**零命中** ⇒ 整条静默漏掉 |
| **M4e** | `INSERT INTO training_sets WITH c AS (…) SELECT …` | **【认不出的形状】** | `unknown` 兜底必报 | 旧兜底是 `continue` ⇒ 静默跳过 |

⛔ **落错类别与没红同样算失败**：例如 M4c 若报成「认不出的形状」，说明列清单没解析出来、判定顺序那处修复没生效。

- [ ] **Step 7d: ⭐⭐ 变异 M4f —— 钉住「列名精确相等」（防子串假通过）**

⛔ **控制者自查发现（R4 轮）**：判据若写成子串 `"schema_version" in cols`，会被 **`old_schema_version`**、**`schema_version_legacy`**、甚至**列清单里的注释**假通过 —— 方向是**危险的那一侧**。⭐ 这正是本仓「裸子串 `= 1` 会被 `= 12` 满足」那条教训的同一形状，而那条教训是本片作者在上一片（P3a）**亲手写下的**。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
T=docs/runbooks/2026-08-24-qmt-nas-deployment.md
cp $T /tmp/m4f.bak
printf '\n```\nINSERT INTO training_sets (stock_code, old_schema_version, file_path) VALUES (1,1,2);\n```\n' >> $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m4f.bak $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
diff /tmp/m4f.bak $T && echo "M4f 还原逐字一致"
git status --short
```

**期望**：**变红**，且注入的那一行落进**【列清单里没有】**那一类。
⛔ 若它**放行**，说明判据退回了子串形态 —— **改判据，不许改期望**。

- [ ] **Step 7e: ⭐ 变异 M4g / M4h —— 钉住 `_HEAD` 的两处放宽（整支评审 R6-M1）**

⛔ **R6-M1 实测**：`_HEAD` 的 `re.I`（大小写）与 **schema 限定前缀**支持，**零变异覆盖** —— 把它们退回去，真实树与既有全部变异**逐格不变**，而小写 `insert into` / `public.training_sets` **当场漏报**。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
T=docs/runbooks/2026-08-24-qmt-nas-deployment.md
cp $T /tmp/m4gh.bak

# M4g：小写写法
printf '\n```\ninsert into training_sets (stock_code, file_path) values (1,2);\n```\n' >> $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m4gh.bak $T

# M4h：schema 限定前缀
printf '\n```\nINSERT INTO public.training_sets (stock_code, file_path) VALUES (1,2);\n```\n' >> $T
find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_insert_schema_version_guard.py -q; cd ..
cp /tmp/m4gh.bak $T

find backend -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; true
diff /tmp/m4gh.bak $T && echo "M4g/M4h 还原逐字一致"
git status --short
```

**期望**：两组都**变红**，且注入行落进**【列清单里没有】**那一类。
⭐ **对角线已实测**：退掉 `re.I` ⇒ 只有 M4g 失效（表头零命中）；退掉前缀支持 ⇒ 只有 M4h 失效。两组各自精确钉住一处。

- [ ] **Step 8: 跑全套 + 提交**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```
期望 **1506 passed**（1505 + 本任务 1 条）。

```bash
git add backend/tests/test_insert_schema_version_guard.py
git commit -F <(printf '%s\n' 'feat(p3b): 守卫① —— 每条 INSERT INTO training_sets 都必须显式写 schema_version' '' '判据按【一条 SQL 语句】匹配，⛔ 不按行 grep：实测在场两条本来就合规的语句是跨行的' '（generate_training_sets.py 与 p11 那份 .sql），按行比会把它们误报成缺字段。' '变异 M2 实测：把跨行那条的字段删掉 ⇒ 守卫红并点名 —— 证明它真的按语句在看。' '' '排除项按【结构】判（字符串谓词 / 注释），⛔ 不按数量判：spec 对「共有几处」这个计数' '连栽三轮，而上一片写的一句注释又让命中数 +1。故本守卫不写任何总数。' '另配防空转断言（checked >= 2），免得作用域坏掉时报成「全都合规」。')
```

---

## Task 4: 守卫② —— 生成器内嵌建表语句 ↔ 冻结建表文件**逐语句相同**

**Files:**
- Create: `backend/tests/test_training_set_ddl_no_drift.py`

**Interfaces:**
- Consumes: 无（只读两个既有文件）
- Produces: 一条机械判据，两份建表语句一旦漂移就报红

### ⚠️ 这个洞有多久了

`backend/generate_training_sets.py:364` 的注释写着「**逐字** `backend/sql/training_set_schema_v1.sql`」—— 但**从 Plan B2 起就没有任何东西在核这句话**。这不是本片引入的，是本片顺手补上。

- [ ] **Step 1: 新建守卫文件**

```python
# backend/tests/test_training_set_ddl_no_drift.py
"""守卫：生成器内嵌的训练组建表语句，必须与冻结的建表文件**逐语句相同**。

⭐ 为什么要紧：`generate_training_sets.py` 的注释自称「逐字 training_set_schema_v1.sql」，
   但从 Plan B2 起**没有任何东西在核这句话**。两份一旦漂移，生成出来的 `.db` 结构
   就与冻结契约不一致，而两边各自的测试都照样绿。

⛔ **必须按【语句】比，不能按行比**：实测两份**语义完全相同、排版不同**
   —— 冻结文件一列一行，生成器里几列挤一行。按行比这条守卫**开局就是红的**，
   而本仓成文教训是「一条开局就红的守卫 = 给实施者发放宽许可证」。
"""
from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
GENERATOR = REPO_ROOT / "backend" / "generate_training_sets.py"
FROZEN_DDL = REPO_ROOT / "backend" / "sql" / "training_set_schema_v1.sql"


def _statements(sql: str) -> list[str]:
    """归一化成语句列表：剥行注释 → 按 `;` 切 → 把连续空白压成单个空格 → 丢掉空段。"""
    sql = re.sub(r"--[^\n]*", "", sql)
    parts = [re.sub(r"\s+", " ", p).strip() for p in sql.split(";")]
    return [p for p in parts if p]


def _embedded_ddl() -> str:
    text = GENERATOR.read_text(encoding="utf-8")
    m = re.search(r'_TRAINING_SET_DDL = """(.*?)"""', text, re.S)
    assert m, ("在 generate_training_sets.py 里找不到 `_TRAINING_SET_DDL = \"\"\"…\"\"\"` —— "
               "是不是被改名或改成了别的写法？⛔ 抓不到就必须响，不能静默当作『没有漂移』")
    return m.group(1)


def test_generator_ddl_matches_frozen_schema_file_statement_by_statement():
    """两份建表语句逐条相同（语句级，排版差异不算漂移）。"""
    frozen = _statements(FROZEN_DDL.read_text(encoding="utf-8"))
    embedded = _statements(_embedded_ddl())

    # ⛔ 防空转：切不出语句就说明归一化坏了，而不是「两边都空所以相等」
    assert len(frozen) >= 3, f"冻结文件只切出 {len(frozen)} 条语句 —— 归一化坏了"

    assert frozen == embedded, (
        "生成器内嵌的建表语句与冻结的建表文件**已漂移**。\n"
        f"冻结文件 {len(frozen)} 条 / 生成器 {len(embedded)} 条。\n"
        "只在冻结文件里：\n  " + "\n  ".join(s[:120] for s in frozen if s not in embedded) +
        "\n只在生成器里：\n  " + "\n  ".join(s[:120] for s in embedded if s not in frozen))
```

- [ ] **Step 2: 跑，确认绿（关键：它在当前树上必须是绿的）**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/test_training_set_ddl_no_drift.py -v
```
期望 **1 passed**。⛔ 若红，先确认是不是**真的**漂移了，**别改判据去迁就**。

- [ ] **Step 3: ⭐ 变异 M5 —— 只改排版，守卫必须仍绿**

这一条证明判据钉的是**结构**不是**文本**（否则它会天天误报）。

把冻结文件里 `CREATE TABLE meta ( … )` 内部的换行改一下（例如把两列并到同一行），守卫必须**仍然 passed**。用 `cp` 备份还原。

- [ ] **Step 4: ⭐ 变异 M6 —— 真改一个列名，守卫必须红**

把冻结文件里 `ma66 REAL` 改成 `ma67 REAL`，守卫必须**红**，且失败信息里**同时列出**「只在冻结文件里」与「只在生成器里」那两条。用 `cp` 备份还原。

- [ ] **Step 5: 变异 M7 —— 把生成器里那个变量改名，守卫必须响（不能静默变绿）**

把 `_TRAINING_SET_DDL` 临时改成 `_TRAINING_SET_DDL_X`，守卫必须因抓不到而**红**，报「找不到 `_TRAINING_SET_DDL`」。
⭐ 这一条防的是「锚点失效 → 静默全绿」（本仓成文教训：机械检查器被它该抓的损坏禁用了自身解析器）。

- [ ] **Step 6: 跑全套 + 提交**

```bash
cd backend && "/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3" -m pytest tests/ -q
```
期望 **1507 passed**（1505 + Task 3 的 1 条 + 本任务 1 条）。

```bash
git add backend/tests/test_training_set_ddl_no_drift.py
git commit -F <(printf '%s\n' 'feat(p3b): 守卫② —— 生成器内嵌建表语句 ↔ 冻结建表文件逐语句相同' '' '生成器的注释自称「逐字 training_set_schema_v1.sql」，但从 Plan B2 起没有任何东西核这句话。' '' '判据按【语句】归一化（剥注释 / 按分号切 / 压空白），⛔ 不按行比：实测两份语义完全相同、' '排版不同（冻结文件一列一行，生成器几列挤一行）⇒ 按行比这条守卫开局就红，' '而本仓教训是「开局就红的守卫 = 给实施者发放宽许可证」。' '' '三组变异：M5 只改排版仍绿（证明钉的是结构不是文本）、M6 改一个列名变红、' 'M7 把变量改名必须报「找不到锚点」而不是静默变绿。')
```

---

## Task 5: 验收清单 + 变异记录 + 计划入库

**Files:**
- Create: `docs/acceptance/2026-09-17-trainingset-p3b-acceptance.md`
- Create: `docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md`
- Add: 本计划文件

- [ ] **Step 1: 写验收清单**（中文、非程序员可执行、动作/期望/通过判定三段式）

格式照抄本仓既有范例 `docs/acceptance/2026-09-07-trainingset-p3c-acceptance.md`（**先读它**）。

| 序 | 动作 | 期望 |
|---|---|---|
| A1 | 跑后端全套 | `1507 passed`，无 `failed`/`skipped`/`error` |
| A2 | 跑本片新加的 2 条守卫 | 含 `PASSED` 的行恰好 2 行 |
| A3 | 跑治理脚本套件 | 末行 `ALL GREEN` |
| A4 | 列出所有该 `INSERT` 及其是否带字段 | 逐条打印，**全部带** |
| A5 | 确认那四个「必须失败」的感叹号一个没少 | 数字是 `4` |
| A6 | 确认 CI 配置文件还能被解析 | 打印 `YAML OK` |
| A7 | 三个禁区一行未动 | `ios/` = 0；`backend/sql/schema.sql` = 0；`generate_training_sets.py` = 0 |
| A8 | 本片一共动了哪些文件 | 逐个列出并说明用途 |

⚠️ **每条的期望数字必须先用真实输出对过**，⛔ 不许照抄本计划里的数字就交（本仓栽过：清单写「7 个文件」而命令实际打印 9 个）。

- [ ] **Step 2: 写变异记录**（⛔ **不写「共 N 组」** —— 这个数在 R2/R3/R4 三轮里错过三次；改为**逐个列出编号**，条数由 `grep -c '^### M' 记录文件` 现场数）：**M0 / M1 / M2 / M3 / M4 / M4b / M4c / M4d / M4e / M4f / M4g / M4h / M5 / M6 / M7**；⚠️ 编号不连续是有由来的：`M4b` 是计划阶段预演打回后补加的，`M0` 是**整支评审 R1-C1 打回后**补加的（排最前，因为它是判据正确性的要害）；`M4c/M4d/M4e` 是**整支评审 R3-M1 打回后**补加的（钉住 R2 那轮改的三处判据）；`M4f` 是**控制者自查**发现子串漏洞后补加的；M1–M7 已在别处按号引用，故都不重排），每组四样：改了什么 / 跑了什么命令 / **原样贴出的观测输出** / 结论。

末尾挑出下面这几组并说明各自证明了什么（⛔ **不写「共 N 组」** —— 这个数在 R3/R5 两轮被打回过）：
- **M0**（把唯一那条生产语句列清单里的字段删掉）—— 这是 spec 明令的那条，也是**上一版判据恒绿的地方**。它红了，才证明守卫对「唯一会真毁数据的那一处」有判别力；
- **M2**（跨行那条的字段被删 ⇒ 红）—— 证明守卫**真的按语句在看**，不是按行；
- **M5 + M6 配对**（只改排版仍绿 / 改一个列名变红）—— 证明第二条守卫钉的是**结构**不是**文本**；
- **M7**（变量改名 ⇒ 报「找不到锚点」而非静默变绿）—— 证明锚点失效会**响**。
- **M4b**（临时写一条不带列清单的 `INSERT`）—— 证明「按位置插入」那条**今天零命中**的分支**不是恒真**，而且报的是**它自己**那条失败信息。

- [ ] **Step 3: 把残留写进清单末尾**（见下节，逐条照抄）

- [ ] **Step 4: 提交**

```bash
git add docs/acceptance/2026-09-17-trainingset-p3b-acceptance.md docs/acceptance/2026-09-17-trainingset-p3b-mutation-log.md docs/superpowers/plans/2026-09-17-trainingset-p3b-insert-schema-version.md
git commit -m "docs(p3b): 验收清单 + 变异记录 + 实施计划"
```

---

## 已知残留（本片**不**解决，必须逐条写进验收清单）

1. ⛔ **PostgreSQL 的 `schema_version INTEGER NOT NULL DEFAULT 1` 保持原样**。更强的做法是去掉默认值（漏写直接失败），但那属 DDL 变更 ⇒ 需受治理的 migration，**且会让 P6b 形状闸门的 `schema.sql` md5 锚失配、必须重新生成整份闸门文件**。⇒ 日后 `training_sets` 若因别的原因要改 DDL，**顺带把这个默认值一起去掉**（spec 残留 TS1-R1）。
2. ⚠️ **守卫①已知的静默盲区逐条列在下面（⛔ 刻意不写总数 —— 这个数已经在 R2/R3/R4 三轮里错过三次）**：①**目录**只含三类可执行路径（`backend/` / `docs/runbooks/` / `.github/workflows/`）—— 日后在 `scripts/` 等处新写的 `INSERT` 不会被抓到（已实测：今天 `scripts/`、`ios/` 下一处命中都没有）；②**后缀白名单** `_SUFFIXES` 同样是盲区 —— 往作用域里放 `.txt` / `.env` / `.psql` 之类会被悄悄漏掉、**不报错**。③**表名不是字面量时守卫结构上够不着** —— 例如 f-string `INSERT INTO {TABLE} (...)`，`_HEAD` 在第一步就零命中（实测）。这一层**修不了**：按字面量 grep 的守卫看不见计算出来的表名。⛔ 因此**不得**在任何地方写〔废〕「其余一律必报」这类全称断言（整支评审 R2-M1 打回过一次）。
④**列清单与表名之间夹了非字面量**时（变量 / f-string / `.format` / `%` / shell 变量），`_column_list` 解析不出列清单；若表名两侧恰好是引号或反引号 ⇒ 判为「提及」**静默跳过**（整支评审 R4-M1 实测：把 SQL 头抽成模块常量这种**寻常重构**就会触发，之后删掉 `schema_version` 守卫仍绿）。
   ⇒ 这一层由**锚点加固断言**兜底：生产文件里认不出任何列清单就**响**（见守卫代码里的 `gen_seen`）。⚠️ 但它**只兜底那一个文件**，别处发生同样的重构仍会静默。
   ⛔ 别写「共 N 层」「哪几条已写进注释」这类会漂移的对账（R2/R3/R4/R5 因同类表述被打回四次）。
3. ⚠️ **守卫①只看【列清单】，不看 `VALUES` 侧值的个数**。也就是说「列里写了 `schema_version`、但 `VALUES` 里少给一个值」这种错，守卫①抓不到 —— 它由 **Task 1 Step 5 的跨行统一检查器**（覆盖全部 **10** 处）与 **Task 2 Step 2**（覆盖 CI 配置那 5 条）两处覆盖。
   ⚠️ **上一版这里写「`rehearse.sh` 与 runbook 那 5 条靠人眼」是过时的**（整支评审 R3-M2）—— 那句话在 Task 1 Step 5 被换成跨行检查器的同一轮里就已作废，而残留层没跟上。⛔ 但要注意：这两处检查是**实施期的一次性自查**，**不是**长期守卫 —— 日后新写的 `INSERT` 若列/值错位，**没有任何常驻检查会报**。
   ⚠️ 另一处已知**误报（安全方向）**：**被注释掉的真 SQL**（如 `-- INSERT INTO training_sets (a,b) …`）会被判为缺字段而报错。这是有意的取舍 —— 让人来定性，好过静默放过。
   ⛔ **上一版这条残留写的是一条【假的安全属性】**（「窗口取长不会静默放行」），方向恰好写反，已整条删除（整支评审 C1）。
4. ⚠️ **守卫②是交叉校验，对「两边一起改错」天然没有判别力**（实测：把两份都从 `user_version = 2` 降回 `1`，守卫仍绿）。`PRAGMA` 那一行另有 `test_frozen_contract_texts.py` 单独钉住（它比的是 DDL ↔ m01 治理矩阵），但**列名一类的「一起改错」确实无人看管**。
   ⚠️ 另外守卫②**只比 `_TRAINING_SET_DDL` 这一个字面量**；生成器里若日后新增第二段内嵌 DDL，不会被覆盖。
5. ⛔ **库存 3 个产物仍是第 1 代**；`api` / `scheduler` / 生成器 CLI **必须保持停止**；重建归 **P4**。
6. ⛔ **runbook 的 P7 仍从 NAS 那个 handoff 目录拷、判据仍是三个第 1 代指纹** ⇒ **P4 必须把这个来源目录一并处理**（P3c 挖出、明确划给 P4）。
7. ⛔ **App 侧运行逻辑一行未改** ⇒ **切片二**，两道拦路石：只认 `.sqlite` 成员、以及 `DefaultTrainingSetReader.swift:90-92` 的严格递增运行时校验。
8. ⛔ **切片二必须再 bump 一次顶层、不得与 `1.14` 共号**（若期间无其它 bump 则是 `1.15`，⛔ 不是无条件的）。
9. ✅ **本片守卫红了会拦合并** —— 2026-09-17 起 `backend pytest (full suite)` 已进 main 的必需检查（8 项，且都绑 GitHub Actions app）。⚠️ 这与 P1/P2/P3a/P3c 那几片交付时的情况**不同**，别照抄旧清单里那条残留。

---

## Self-Review（⚠️ 第 5 轮收口：**只留三节，删掉全部自证句**）

⛔ **为什么这一节被砍到只剩三条**：五轮对抗性评审里，**每一轮**都有缺陷落在这一节 —— R2-M4（引用被推翻版本的符号）、R4-M2（没跟上自己的改动）、R5-M1（新判据被它自己的脚本证伪）。而**判据本身在 R5 零缺陷**。
⇒ 诊断是评审给的：**病灶是台账形态，不是判据**。本节因此**不再声称「我核过了」** —— 自证句本身就是漂移源（R5 实测：`§8` 给一份已被删掉的清单背书）。⛔ 凡是要「核过才成立」的东西，一律改成**可复跑的命令**写进正文，不写进本节。

**1. spec 覆盖**：§3.3「三步改法」第 1 步 → Task 1 + Task 2；第 2 步（作用域成文）→ 守卫①的 `_SCOPE_DIRS` 与注释；第 3 步 → Task 3。spec §3.3 / B23 明令的那条变异 → Task 3 Step 3b（M0）。该节点名的「生成器 DDL ↔ 冻结 DDL 无守卫」残留 → Task 4。PG `DEFAULT 1` 按 spec 明写**刻意不改** → 残留 1。

**2. 落地前必跑的三条自检**（⛔ 替代原先那些「已逐个核过」的断言）：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-nas-deploy-run"
PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python3"
PLAN=docs/superpowers/plans/2026-09-17-trainingset-p3b-insert-schema-version.md

# ① 计划里的守卫代码抽出来能跑，且在【未补字段的树】上恰好报 10 处
"$PY" - <<'PYX'
import pathlib, re
plan = pathlib.Path("docs/superpowers/plans/2026-09-17-trainingset-p3b-insert-schema-version.md").read_text(encoding="utf-8")
m = re.search(r"```python\n(# backend/tests/test_insert_schema_version_guard\.py\n.*?)\n```", plan, re.S)
assert m, "抽不到守卫①的代码块"
pathlib.Path("backend/tests/_selfcheck_guard.py").write_text(m.group(1), encoding="utf-8")
PYX
(cd backend && "$PY" -m pytest tests/_selfcheck_guard.py -q 2>&1 | grep -cE "^E +(backend|docs|\.github)")
rm -f backend/tests/_selfcheck_guard.py

# ⚠️ ②③ 必须【切掉本节自身】再数 —— 否则 grep 会命中它自己的定义。
#    （这正是本仓「不写含自身的总数」那条教训换了个形态：一条会匹配自己的检查，
#      结构上永远到不了 0。首次跑这两条时就是这么发现的。）
BODY=$(sed '/^## Self-Review/,$d' "$PLAN")

# ② 变异编号只在一个地方存在（Task 5 Step 2）—— 单独跑，看数字
printf '%s' "$BODY" | grep -c "M0 / M1 / M2 / M3 / M4 / M4b / M4c / M4d / M4e / M4f / M4g / M4h / M5 / M6 / M7"

# ③ 旧措辞是否仍被当作【当前断言】—— 单独跑，看数字
#    ⚠️ 词表【只有这一份】（就在下面「收口纪律」里），本命令直接从那一节读取，
#       ⛔ 不在这里再抄一遍（R6-M2：上一版抄了两份、6 词 vs 8 词互不一致，
#       而那一节自己还写着「台账只许有一份」）。
#    ⭐ 合法的**订正引文**统一带 `〔废〕` 前缀，本命令把它们排除 ⇒ 判据回到硬 0，
#       ⛔ 不再「每出现一处合法引文就从词表里删一个词」（那样词表最后会变空）。
#    ⚠️ 词条用【反引号】界定，按反引号提取 —— ⛔ 别按空格切（首次这么写时
#       把「全仓实测 4 处」切成三段，`处` 到处命中，当场报 114）。
WORDS=$(sed -n '/^超期作废词表：/,/^$/p' "$PLAN" | grep -oE '`[^`]+`' | tr -d '`' | paste -sd'|' -)
printf '%s' "$BODY" | grep -vF '〔废〕' | grep -cE "$WORDS"
```

**判据**：① 输出 **10**；② 输出 **1**；③ 输出 **0**。
⚠️ ③ 的模式里**刻意不含**「其余一律必报」—— 正文有一处**禁令引文**（「⛔ 不得写『其余一律必报』」）是合法的，把它列进模式会让这条检查永远到不了 0。⛔ 若 ③ 非 0，**逐条打开看**：订正引文合法，当前断言不合法。

**3. 次序**：Task 1/2（补字段）**必须**在 Task 3（守卫①）之前 —— 理由写死在 Global Constraint 1。Task 2 单独成一个提交（`.github/workflows/` 的独立推送仪式）。Task 4 与前三个任务无依赖。
⚠️ **中间态**：做完 Task 1 未做 Task 2 时，守卫会报 CI 配置那 5 条 —— **这是预期行为**，Task 3 Step 1/Step 3 已写明「别改判据去迁就」。

---

## 收口纪律（改完必须跑，⛔ 不许跳）

改动这份计划的**任何**判据之后，必须问三句（五轮实测：漏问其中任一句，下一轮必出同类缺陷）：

1. **有没有变异钉住它？** —— 没有就补一组（R3-M1 的教训：我修的三处一条变异都没有，退回去一切照样绿）。
2. **残留清单里有没有因此作废的话？** —— R3-M2 / R5-M2 都死在这里。
3. **有没有在别处抄了第二份台账？** —— R5 的三条**全部**是台账不同步。⛔ 台账只许有一份。

然后拿**旧措辞**全文 grep，命中应为 **0**。合法的订正引文一律加 `〔废〕` 前缀，grep 时排除该前缀 —— ⛔ **不许靠从词表里删词来让检查变绿**。

超期作废词表：
`九组` `四组` `③已在` `不依赖形状判据` `其余一律必报` `只有两种形状` `全仓实测 4 处` `三层都已写进注释` `唯一台账`

