# QMT Plan 4b 切片映射（2026-08-21）

**起点**：`main d38da4b`（4a 全部闭合，S3 = PR #169）。`backend/qmt_fetch.py` **零实现**。
**实施依据**：`2026-07-27-qmt-plan4b-fetch-design.md`（1155 行，§4 为唯一权威）。
**本文件不定义任何规则**——它只回答「1155 行 spec 分几个 PR 落地、每个 PR 的边界在哪」。
规则一律引用 spec，不复述。

---

## 一、开工前的核实（2026-08-21，读代码/跑命令，不是转述文档）

### 1.1 spec 引用的本仓代码锚点：**全部为真**

| spec 断言 | 实际位置 | 结论 |
|---|---|---|
| `reconcile_sources` 第一门返回 `export_log_not_ok` | `backend/qmt_resample.py:154-156` | ✅ 逐字相同 |
| `eligible_start_indices` 要求月边界 ≥ `31 + 8 = 39` | `backend/generate_training_sets.py:128` `if n < 31 + months` | ✅ |
| `_amain_qmt_import` 的 `rglob` 在 `import_csv.py:507-508` | 正是那两行 | ✅ 行号未漂 |
| `_STOCK_CODE_RE = ^\d+\.(?:SH\|SZ\|BJ)$` | `backend/qmt_normalize.py:21` | ✅ |
| `_STOCK_COL_CANDIDATES` / `_norm_code` / `parse_export_log` | `backend/qmt_ingest.py:19 / 39 / 48` | ✅ |
| `_FILENAME_RE` / `parse_qmt_filename` / `QmtSchemaError` | `backend/qmt_normalize.py:14 / 44 / 23` | ✅ |
| `assemble_from_windows` 用 `ZipFile(path,"w")` 会截断同名文件 | `backend/generate_training_sets.py:375` | ✅ 存在 |

### 1.2 spec 标「已实测」的平台断言：**本机全部复现**（macOS 25.6 / APFS，2026-08-21）

| 断言 | 复现结果 |
|---|---|
| `os.replace in os.supports_dir_fd` 为 **False**，而 `os.rename` 为 True | ✅ 复现。**且 `os.replace(..., src_dir_fd=, dst_dir_fd=)` 实测可用** —— 按 CPython 文档写能力探测的实现会在本平台退回 O2-F4 明令禁止的按路径改名 |
| 目录分量为符号链接 → `ENOTDIR`（**不是** `ELOOP`） | ✅ 复现 |
| 叶子文件符号链接 + 不带 `O_DIRECTORY` → `ELOOP` | ✅ 复现 |
| `os.unlink(dir_fd=)` 对不存在目标抛 `ENOENT` | ✅ 复现（O4-F4 的容忍规则有依据） |
| `fcntl.F_FULLFSYNC` 可用 | ✅ 存在，值 51 |
| `"/Volumes/QMT_Export" + "/" + ""` → `.split('/')` 末位空分量 | ✅ 复现；`posixpath.normpath(join(...))` 得挂载点本身（O2-F6 的修法有效） |
| 根卷 `/` 自身即 `read-only`，`ST_RDONLY` 分不出网络共享与本地卷 | ✅ 复现（`/` True，`/Users`、`/tmp` False） |
| `/sbin/mount` 输出格式 `<device> on <mountpoint> (<fstype>, …)` | ✅ 复现 |

### 1.3 三条 spec 与现实不符 —— **均为范围问题，须移交 4c**

全仓搜索确认以下符号实现数量**均为 0**：
`open_root` / `open_under` / `parent_fd_under` / `ensure_owned_dir` / `output_dir_fd` /
`import_qmt_stock` / `qmt_fetch` / `fetch_manifest` / `staging_owner`。

| # | 4b spec 的条目 | 问题 | 处置 |
|---|---|---|---|
| A | §9-**1s6** 要求 `import_qmt_stock` 新增 `staging_dir_fd` 参数 | **该函数不存在**；4c spec 第 6 行、§4.1 明写它是「4c 的公共入口提取」 | **移交 4c**，4b 不实现 |
| B | §9-**3l** 要求「pilot 每一处 `import_qmt_stock` 都传 `staging_dir_fd`」 | 同上，且 `qmt_pilot` 本身属 4c | **移交 4c** |
| C | §9-1s6 称新参数「契约与 `output_dir_fd`（§9-2k）逐字同构」 | `output_dir_fd` 同样零实现，§9-2k 在 4c spec | **移交 4c** |

**`--output` 那一族同理**：`.superseded/` 目录、`ensure_owned_dir`、报告落盘、zip 改名
（均出现在 §4.1 与耐久提交协议的闭合清单里）在 4b 里**没有使用者**——`qmt_fetch` 无 `--output` 参数。
切分图自己也写了「`--output` 的归属/锁纪律写在 4c」。
**故 4b 只交付通用原语**（目录归谁、标记文件叫什么、自指字段名，全部作为参数），4c 去用。
S1 的验收须包含「同一套原语能同时表达 `--dest` 与 `--output` 两种规格，差异只有 `EEXIST` 那一档」。

---

## 二、五个切片

| 片 | 交付物 | 依赖 | spec 出处 |
|---|---|---|---|
| **S1 共享地基** | 逐段无跟随打开器、锁纪律、耐久提交、归属标记与认领协议 | 无 | §4.1 + §4.5 的锁/耐久两小节 |
| **S2 manifest** | manifest 结构、读侧闭合校验、`manifest_version` 三档、`stopped_reason`/`fetch_fatal_error` 生命周期 | S1（原子写要用耐久提交） | §4.5 读侧校验 + §4.4 manifest 字段 |
| **S3 预筛 + 分层储备池** | 三条预筛判据、按层 seeded shuffle、冻结宇宙、`cursor`/`pool_order`/`failures` 语义 | S2（结构定义） | §4.2 §4.3 §4.4 |
| **S4 拷贝引擎** | 按股事务、`.part`→`replace`、`.inflight.json` 三档恢复、`--max-bytes` 流式硬限 | S1 S2 S3 | §4.5 |
| **S5 源边界闸 + CLI** | 七条边界闸、立基准/比对双模式、可注入挂载表、收尾复校与三级定级、`qmt_fetch` 命令行 | S1–S4 | §4.6 + §4.4 的 `source_verification` |

**⚠️ S1 可能需要再拆成两个 PR**：它含约 10 个原语，而按切分图的统计「路径·锁信任边界」在 spec 层就吃掉 47 条 finding 里的 8 条，是被 codex 挖得最狠的部分之一。若第一轮对抗性评审的 finding 集中在锁/归属这一半，就地拆成 S1a（纯路径原语 + 耐久）与 S1b（锁 + 归属标记 + 三分支探测 + 只读/重叠/分叉检查）。**由评审结果决定，不预先拆。**

### 不在 4b 范围内（逐条登记，防止顺手做）

- `qmt_pilot` 命令行 —— 4c。（4a 收官时 codex 连两轮报 high 判 no-ship，已由 user 拍板维持；见 4a 残留 1）
- `import_qmt_stock` 提取、`staging_dir_fd`、`output_dir_fd` —— 4c（上表 A/B/C）
- `--output` 的归属标记、`.superseded/`、报告与 zip 落盘 —— 4c
- verdict 枚举与报告 schema —— 4c 是唯一权威；4b 只声明「我会产生
  `FAIL_SOURCE_BOUNDARY` / `FAIL_STAGING_INTEGRITY` / `FAIL_MANIFEST_INVALID`」
- 4a 残留 2（同侪库归属判据两份近似实现）与「闸 1 绑死全局 `CONTRACT_VERSION`」的解耦 ——
  两者都动 4a 的破坏性模块，按治理要走各自的 spec→plan→评审，**不在 4b 顺手做**

---

## 三、真实数据端到端（与 S1 并行）

4a 收官记录里 2026-08-13 提的建议，2026-08-21 由 user 拍板执行：
挂载 → 拷一小批股 → `import_csv --qmt` → `generate_training_sets`。

**目的不是交付，是证伪 S3/S5 的假设**：源目录真实层级、`export_log.csv` 真实列名与
`status` 取值分布、K 线文件名是否真的匹配 `_FILENAME_RE`、单股两文件的真实体积
（`--max-bytes` 默认 3 GiB 与「约 400 只 ≈ 2 GiB」这两个数字目前**没有任何实测支撑**）。

**S1 不依赖它**（纯 `tmp_path` 文件系统原语），故两条线并行。
真跑结论回来后若与 spec 冲突，**先改 spec 再进 S3/S5 的 plan**。

状态：445 已通、`~/qmt_mnt` 已建；挂载需 user 交互输密码（密码不进代码/仓库/记忆，spec §4.1 理由一）。
