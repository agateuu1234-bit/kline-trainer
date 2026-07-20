# 验收清单：QMT 数据接入 Plan 2b（B2 生产装配重接）

分支：`qmt-plan2b-b2-reconnect`　基线 main：`09be7cd`（PR 2a #148 合并后）
本清单面向**非编码人员**：照「动作」一列敲命令，比对「预期」一列，勾「通过/不通过」。

命令统一在仓库根目录下执行。仓库根 = 存放 `backend/`、`ios/` 的那个目录。

---

## ⚠️ 第 0 条：先读这条，它决定你怎么理解后面所有「通过」

| 动作 | 预期 | 通过/不通过 |
|---|---|---|
| 阅读本 PR 说明中「当前局限」一节 | 明确写着：本 PR **不会**让 B4 补货真的产出训练组；真库 `stock_coverage` 仍是空表，每股都会 skip、`generate_batch` 仍返回 0；解锁出货的是 Plan 3（B1 写覆盖表） | ☐ |

**大白话解释**：这个 PR 修好的是「管道」，不是「водопровод 通水」。管道现在从头到尾接通了、也有测试证明它通，但**上游水源（`stock_coverage` 表里的数据）还没有人往里灌** —— 灌水那一步属于下一个 PR（Plan 3）。所以合并这个 PR 之后，真实环境里能产出的训练组数量**和合并之前一样，都是 0**。这不是 bug，是本 PR 刻意保持的范围。

---

## 一、主闸门：后端测试

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 1 | 在仓库根执行：<br>`cd backend && ../.venv/bin/python -m pytest tests/ -q` | 最后一行形如 `240 passed`。**必须是 0 failed、0 skipped**（没有 failed/skipped 字样即可） | ☐ |
| 2 | 单独跑本 PR 新增的集成测：<br>`cd backend && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q` | 形如 `29 passed`，无 failed / 无 skipped | ☐ |
| 3 | 确认用的是正确的 Python：<br>`.venv/bin/python -V` | 输出 `Python 3.11.15`。<br>⚠️ 若你用系统的 `python3`（3.14）跑上面的测试，**会段错误崩溃** —— 那是环境问题不是代码问题 | ☐ |

---

## 二、旧的「停用路径」必须已彻底移除

Plan 1 曾把装配函数用 `NotImplementedError` 强行停用（调用即抛异常）。本 PR 的核心就是解除它。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 4 | `grep -rn "NotImplementedError" backend/generate_training_sets.py backend/app/scheduler.py` | **无任何输出**（命令直接返回，屏幕上什么都不打印） | ☐ |
| 5 | `grep -rn "def assemble_training_set" backend/` | **无任何输出**（旧的、未经门控的装配函数已删除） | ☐ |
| 6 | `grep -rnE "pytest\.mark\.skip\|pytest\.skip\|xfail" backend/tests/` | **无任何输出**（CI 对任何 skipped 测试都会判失败，所以一条都不能有） | ☐ |

> 若上面任意一条**打印出了内容**，即为不通过。

---

## 三、核心能力：真实链路能产出训练组

本 PR 的核心断言是「真实 sweep 能产出 ≥1 个已登记的训练组」。集成测里只有数据库连接是假的，其余（选窗口、装配、SQLite、zip 打包、CRC32 校验）全是真实生产代码。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 7 | `cd backend && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q -k "sweep or registered"` | 相关测试全部 passed —— 证明在注入覆盖行的测试数据上，`generate_batch` 真的产出了已登记的训练组（不只是「没报错」） | ☐ |
| 8 | `cd backend && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q -k "malformed or null or reversed or mismatch"` | 全部 passed —— 证明**坏数据**（非法 JSON、日期区间反了、天数对不上、字段为空）只会让**那一只股票**被跳过，**不会让整轮任务崩溃** | ☐ |

---

## 四、诚实义务自查（禁止过度宣称）

> **给验收人的说明**：本 PR 有一条硬性纪律 —— 任何地方都不许声称补货功能恢复了、库存能生成了、训练组能产出了。
> 下面两条就是查这个的。
> ⚠️ 注意：**禁语原文不写进本文件**，否则查禁语的命令会命中本文件自身、永远报失败（这个坑本项目踩过）。
> 禁语清单的权威来源 = 计划文档 `docs/superpowers/plans/2026-07-18-qmt-plan2-b2-reconnect.md` 的「PR 2b 收尾 Step 2」。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 9 | 执行下面这条（一整条复制，查的是**提交记录**）：<br>`if git log 09be7cd..HEAD --pretty=%B \| grep -nE "B4 ?补货已(恢复\|打通)\|库存已可生成\|训练组已能产出\|已恢复出货"; then echo "FAIL"; exit 1; fi; echo OK` | 只打印 `OK`，不打印 `FAIL` | ☐ |
| 10 | 通读 PR 说明，判断它对「本 PR 带来什么产出变化」的描述 | 说的是**代码通路打通、测试证明可用**；并明确写着真实环境的训练组产出数量**与合并前一样是 0**。若你读到任何"现在可以出货了"意味的表述，即为不通过 | ☐ |

---

## 五、运维可诊断性（本 PR 的一项诚实义务）

合并后真实环境里 `generate_batch` 会返回 0。运维必须能看出**为什么是 0**，而不是只看到一个光秃秃的数字。

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 11 | `cd backend && ../.venv/bin/python -m pytest tests/test_b2_reconnect_integration.py -q -k "skip_reason or first_skip or unprefixed"` | 全部 passed —— 证明当所有股票都被跳过时，日志里会打印**第一条跳过原因**（例如「600519: 缺少 stock_coverage 覆盖行」），而不是只说「仅生成 0/100」 | ☐ |

---

## 六、范围核查（本 PR 不该碰的东西）

| # | 动作 | 预期 | 通过/不通过 |
|---|---|---|---|
| 12 | `git diff --name-only 09be7cd..HEAD` | 只列出 5 个文件，全部在 `backend/` 下：`app/scheduler.py`、`generate_training_sets.py`、`tests/test_b2_reconnect_integration.py`、`tests/test_generate_training_sets.py`、`tests/test_scheduler.py`（外加本验收清单文件） | ☐ |
| 13 | `git diff --name-only 09be7cd..HEAD \| grep -E "\.swift$\|^\.github/"` | **无任何输出**（本 PR 零 Swift 改动、零 CI 配置改动） | ☐ |

---

## 七、已知局限与遗留（不属于「不通过」，但请知悉）

| # | 事项 | 说明 |
|---|---|---|
| L1 | **真库仍产 0** | `stock_coverage` 表至今**无写入方**。本 PR 的集成测是靠假连接注入覆盖行才产出训练组的。真实环境每只股票都会因「查不到覆盖行」被跳过。**解锁出货 = Plan 3**（B1 接 QMT 规整/合成层 + 写 `stock_coverage`）。 |
| L2 | **未在真 PostgreSQL 上跑过** | 本仓库没有真 PG 测试基建（CI 对 skipped 测试判失败，所以不能用「没有 Docker 就跳过」的写法）。集成测用假连接验的是**控制流**；真实 asyncpg 的异常类型是否与假件完全一致，需等 Plan 3 或专门的容器化验证。 |
| L3 | **并发竞态修复无 CI 回归锁之外的真实验证** | 本 PR 修了一处并发下会删掉他人已登记产物的缺陷，并补了回归测试。但该竞态在两条受支持入口（CLI / 调度器）下**本就被互斥锁挡住**，修复的价值是纵深防御与语义自洽，而非修复一个当前可从正常路径触发的线上故障。 |
| L4 | **D9 门的一处既有盲点未处理** | 当 `before_cap=0` 且数据洞恰好落在窗口首日时，该判据会漏检。此缺陷**非本 PR 引入**（Plan 1 原代码同病），且当前生产不可达（三个周期的 cap 恒为 150，且更早的 D6 门会先拦截）。已记录备查。 |

---

## 验收结论

- 全部 ☐ 勾为「通过」→ 本 PR 可合并。
- 任一条不通过 → 记录条目号与实际输出，反馈给开发者。
