# 探针实测事实（2026-09-18，main 8d47e811，本机 macOS 25.6 / APFS）

驱动真实 `qmt_fsroot` / `qmt_manifest` / `qmt_pool` / `qmt_normalize`，
脚本 `engine.py` / `harness.py` / `q1.py` / `q234.py` / `q2b.py`。
**每条都是执行结果，不是推理。**

| # | 事实 | 出处 |
|---|---|---|
| E1 | 按股事务五步（两 `.part` → 标记 → 两次 `os.replace` → `commit_stock` → 删标记）**端到端可行**：两 final 落地、无 `.part` 残留、无标记残留、`files` 恰 2 条、`pool_order` 一条锚点、`cursor` 0→1 | q5 |
| E2 | `committed_bytes` 的写侧下限**含 staged export_log**：实测 340（两文件）+ 26（export_log）= 366 通过 | q5 |
| E3 | **重拷可达且可行**：本地文件坏、源没变 → 判 `recopy` → 重拷成功**提交通过**（重拷出的记录与账本逐字相同，不构成「改写」），`pool_order` 不重复追加 | q1-A |
| E4 | **跳过机制是幂等判据本身**：对已在池里且文件完好的股再跑 → `skipped`（来自四象限 `skip`），**不需要也不该拿 `pool_order` 预过滤** | q1-C |
| E5 | **收口前移真的生效**：本地坏 + 源等长换代 → 在写标记**之前**终止；标记未写、`.part` 无残留、`cursor` 不推进 | q1-B |
| E6 | 目标是**目录** + 有记录 → 判「重拷」**执行不了**：`os.replace` 抛 `IsADirectoryError`(errno 21)，**且此时在途标记已残留在盘上**。而目标是 **FIFO** 时 `os.replace` **成功** | q3 |
| E7 | 非普通文件**一律判 `untracked_target_file`（拒绝覆盖）**：目录与 FIFO **两种都执行得了**，无标记残留，那个对象原样留着 | q3b |
| E8 | 我规定的「源中途换代」终止**构造不出合法的收尾结局**：`FinalOutcome.kind` 闭合为 `{clean, escape, max_bytes}`；`escape_stop` 的 `kind` 闭合为两个 escape 值 | q2 |
| E9 | **未知顶层诊断键可随 per-stock 提交落盘并原样读回**；且**进度一步不推进**（`cursor`/`files` 逐字不变）的提交**被接受** | q2 / q2b |
| E10 | `committed_bytes` **单调只增**：恢复第③档把 `files` 删空后，把它降到 export_log 的量 → 被拒（「它是累计量，调小…等于绕开 --max-bytes」）；保持原值 → 接受 | q4 |

## 补跑的三条（h1.py / h1fix.py / h3.py）

| # | 事实 | 出处 |
|---|---|---|
| E11 | **「当前占用量」语义会死锁**：恢复第③档后重拉，扫描 `committed_bytes` 可接受值 → **366 / 400 / 705 全拒，706 才接受**，而盘上实占仍 366 | h1 |
| E12 | **「累计写入量」语义解得开**：366 → 366 → 706 → 1046 四步全通。代价：盘上恒 366 而账本累计涨到 1046 | h1fix |
| E13 | 重拷成功时转移守卫算出的 `added = 0`（记录逐字相同），而本次真写盘 140 字节；`366` 与 `506` **都被接受**（守卫是 `≥` 不是 `==`） | h3 |

---

⚠️ **本文件只记「跑出了什么」，不记结论。**
由这些事实得出的**决定**在 `docs/superpowers/specs/2026-09-18-qmt-4b-s4a-contract.md`，
那里是唯一副本 —— 本文件**不得**复述它们（曾经复述过一次，结果两份在同一天就相反了）。
