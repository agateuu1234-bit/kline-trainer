# QMT Plan 4c 设计 —— pilot 编排 + 判定 + 诊断报告

> **本文件由 `2026-07-26-qmt-plan4-pilot-shipment-design.md` 切分而来**（映射见 `2026-07-27-qmt-plan4-spec-split-map.md`）。
> 旧 spec 的 **R1–R97 评审账本原样保留在那份文件里**；**它本身已不再作为实施依据**。
>
> **本文件的作用域 = PR 4c**：`import_qmt_stock` 公共入口提取、pilot 编排（逐股导入 → 生成 1 组 → 地板判定）、
> 判定与诊断报告。**出货凭据链不在本 PR**（已整块移出，见 §0）。
>
> **依赖**：文件系统共享地基（`open_root` / `open_under` / 归属标记与认领协议 / 耐久提交协议 / 锁纪律 /
> 源边界闸七条）定义在 **`2026-07-27-qmt-plan4b-fetch-design.md` §4.1（共享地基）与 §4.6（源边界闸七条）**，本文件**引用不复述**。
> 库级五闸与集群闸定义在 **`2026-07-27-qmt-plan4a-db-guardrails-design.md` §4**。
>
> **本文件是 verdict 枚举、错误码枚举、报告 schema 的唯一权威**——4a/4b 只声明「我会产生哪几个」，由本文件收口成闭合枚举。

- **⚠️ 章节权威性**：§4 是唯一权威规范；§5/§6/§9 是它的导出视图，冲突一律以 §4 为准。
  过程性规则只在 §4 定义一次。**跨 spec 引用必须写成「见 `<文件名>` §X」**。
- **⚠️ 每轮改动的收尾必做（五条机械检查）**：①新错误码 → 进了哪个字段枚举？触发哪个 verdict、本文件的权威定义处列了吗？
  ②新参数/枚举项 → 逐个 grep 全部调用点/登记处 ③新闸 → 把序列当有向图逐条出边查绕行 ④改规则 → 关键词**全文打印逐条读完**
  ⑤新持久字段/信号 → **谁写、谁读、谁清**。**扫描结果由脚本打印成可粘贴文本、照抄进 §11。**

---

## 0. 出货凭据链：已整块移出本 plan（2026-07-28 定案）

**本节保留为决策记录。** 完整论证见 §4.2 顶部那段说明。

**曾经的设计**是一条由 8 个部件组成的出货凭据链（`pilot_report.json` + 不可变时间戳报告、
`RUNNING` 先行发布、`①a′` 重核、`①e` 保护闸、`output_binding`、`marker_binding`、
`is_shipping_credential` 谓词、`--verify-shipment`），后来又加了 crc32 自证与 `--repair-artifacts`。

**三轮对抗性评审的实测分布**（4a / 4b / 4c）：

| 轮次 | 4a | 4b | 4c | 4c 里的 critical |
|---|---|---|---|---|
| 1 | 14 | 14 | **16** | 0 |
| 2 | 11 | 14 | **16** | 0 |
| 3 | 12 | — | **13** | **2** |

**4c 三轮都是重灾区，而第三轮的 2 条 critical 全部长在 ①e 与那两个谓词上，且都是上一轮修法自己引入的。**
数量在降（44→41→25），但**新增的 critical 说明修法本身在制造更严重的问题**。

**定案（user 拍板）**：`--verify-shipment` 与出货判定**整块移到后续独立 plan**；
4c 只保留「编排 + 判定 + **报告如实落盘**」；**§7 同步改成「本 plan 不做出货断言」**。

## 1. 背景（裁剪到本 PR）

前置事实（旧 spec §1 实测，未改）：本 plan 的候选起点极稀（每股 3~4 个），
`reconcile_sources` 的 `date_set_mismatch` 可能大规模杀股，而这正是 pilot 要观测的最大未知数。
4c 的职责是**把「拉到了什么」变成「入库并生成了什么」，再变成「一份能不能被信任的结论」**。

## 2. 目标与非目标

**目标**：`import_qmt_stock` 提取为公共入口（CLI 退化为薄壳，可观察行为逐字不变）；
pilot 编排（两阶段：先补地板 → 再补到 `target`）；判定与诊断报告。

**非目标**：**出货凭据链**（`--verify-shipment` / 凭据谓词 / ①e 保护闸 / crc32 自证 / `report_schema_version` 版本闸）——已整块移出后续独立 plan（§0）；不做 UI、不做调度、不改 B2/B4 既有调用点（`output_dir_fd` / `staging_dir_fd` 均为**可选参数**）。

---

## 4. 组件设计

### 4.1 `import_qmt_stock` 公共入口提取 + zip 原子落地

```python
@dataclass(frozen=True)
class ImportResult:
    counts: dict          # {period: rows}
    coverage: CoverageArtifact
    stock_name: str

async def import_qmt_stock(conn, *, staging_dir: Path, stock_code: str,
                           export_log_path: Path,
                           staging_dir_fd: Optional[int] = None) -> ImportResult:
    """glob → parse → build_stock_import → write_qmt_stock（复用 conn）。

    调用方契约（R9-F1 地基，提取时不得丢失）：调用前必须已在 `conn` 上持有该股的
    session 级锁 (IMPORT_GEN_LOCK_KEY, stock_lock_key(stock_code))，并持到本函数返回之后。
    失败按既有异常类型抛出，不做转换：
    QmtIngestRejected / InvalidImportBundleError / ImportBusyError /
    ReimportBlockedError / LegacyImportBlockedError / QmtSchemaError / SchemaDriftError

    `staging_dir_fd`（R74-F2 自查补，契约与 `output_dir_fd` 逐字同构，见 §9-2k）：
      · **给了就用调用方的 fd**（pilot 传 ①b 钉住的 `stg_fd`）。
        **`qmt_pilot` 侧的每一个调用点都必须传，无例外**（R89-F2：`try_one` 有三处调用——
        `!owned` 换代分支、`owned` 换代分支、正常导入分支——**漏传的那一处会让被调方
        按 `staging_dir` 字符串重新打开**，于是 `staging_intact` 之后的一次路径改指
        就能把**未经校验的字节**灌进库，而报告仍照旧 manifest 推理）；**没给则本函数在本次调用
        期间自己 `O_DIRECTORY|O_NOFOLLOW` 打开 `staging_dir` 并持有**（CLI 由此获得
        no-follow，但不获得跨调用的 inode 钉死——那本不是它的需求）。`_amain_qmt_import`
        **一行不改**。
      · **本函数内部的每一次目录遍历与文件打开都走 `open_under`**：既有的
        `rglob(f"{code}_*_1分钟K线_前复权.csv")` 改为 **`os.scandir(dir_fd=)` 逐层下钻**，
        每层 `O_DIRECTORY|O_NOFOLLOW`；`export_log_path` 同理按**相对 staging 的分量**打开。
    """
```

> **为什么这个参数必须加在这里（R74-F2 自查补）**：`open_under` 立在 `2026-07-27-qmt-plan4b-fetch-design.md` §4.5，管的是「pilot 自己的读」；可 pilot 真正读 K 线 CSV 的方式是**把路径交给 `import_qmt_stock`，由它 glob 再打开**。守卫立在调用方、而**打开动作发生在被调方**——中间目录分量的符号链接照样被跟随，`open_under` 等于没生效。这与 R19-F3 **一模一样**：那次是 `assemble_from_windows` 在内部才确定最终文件名，pilot 拿不到路径也就无从在打开前 `O_NOFOLLOW`。**一条 no-follow 纪律的执行点，必须是那个真正调用 `open()` 的函数，不是那个知道路径的函数。** 两处的解法也必须同构：可选 fd + 缺省自开（R60-F2 的 `output_dir_fd` 契约）。

`_amain_qmt_import` 退化为薄壳：调 `import_qmt_stock` → 打印既有格式 → 把异常映射为 `rc=2`。**CLI 可观察行为逐字不变**，由现有 `backend/tests/test_import_csv*.py` 钉住。

> 这是本 plan 触碰 Plan 3 已合并代码的第一处，属**当前需求逼出的重构**（编排必须拿到结构化 skip 原因，而 stderr 文本正则解析既脆又正是诊断报告的数据源），非顺手改进。

#### `assemble_from_windows` 的 zip 落地改原子写（R19-F3）

**第二处触碰 Plan 3 代码**：`assemble_from_windows` 目前用 `ZipFile(zip_path, "w")` **直接写最终路径**。改为**接受一个已钉住的输出目录 fd，并全程走 `*at` 语义**（R19-F3 + R57-F1）：

- 签名新增 **`output_dir_fd: Optional[int] = None`**（由 `generate_one_training_set` 透传；pilot 在 ①a/⑥ 取得后一路传下来）。**必须可选，不能设成必填（R60-F2）**：`generate_one_training_set` 同时被 **B2 CLI（`_amain` → `generate_batch`）与 B4 调度器（`app/scheduler.py` 的 `build_generate_batch`）**调用（已核 `generate_training_sets.py:668-693, 752` 与 `app/scheduler.py`），把它设成必填会**直接打断这两条既有生产路径**。
  - **`output_dir_fd is None` 时**（B2/B4 既有调用方）：函数**自己**以 **`open_root(output_dir)`**（逐段无跟随，R75-F2）打开 `output_dir`，在**本次调用期间**持有并用它做全部 `*at` 操作，返回前关闭。它们由此**免费获得原子落地与 no-follow**，但**得不到跨调用的 inode 钉死**——那本来就不是它们的需求（它们没有 pilot 那套「作废凭据」的语义）。
  - **`output_dir_fd` 给定时**（pilot）：**一律使用调用方给的 fd，不再自行打开**，从而与 ①a/⑥ 钉住的那个 inode 保持同一。
  - `generate_batch` 同样透传该可选参数，默认 `None`，B2/B4 的调用点**一行都不用改**。
- 临时文件：`os.open(tmp_name, O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW, dir_fd=output_dir_fd)`，`ZipFile` 包在这个 fd 上；
- 落地：`os.replace(tmp_name, final_name, src_dir_fd=output_dir_fd, dst_dir_fd=output_dir_fd)` → `os.fsync(output_dir_fd)`；
- 失败清理：`os.unlink(tmp_name, dir_fd=output_dir_fd)`。
- 登记进 `training_sets.file_path` 的**仍是绝对路径字符串**（B3 按路径下载，那是本次运行之外的事）——**但本次运行内的每一次写，都不再由 `--output` 这个字符串解析**。

> **为什么只改成「同目录临时文件 + `os.replace(path)`」不够（R57-F1 修正）**：那个版本仍然**用路径名去解析 `output_dir`**，而解析发生在**生成器内部、⑥ 之后**。⑥ 之后若 `--output` 指向的目录被整体换掉、或路径上某个分量被换成符号链接，zip 就会**创建在授权 inode 之外**——而 R57-F1 刚刚要求「⑥ 之后的每一次输出目录写入都走钉住的 fd」。**这条要求必须一路传到真正打开文件的那个函数里**，否则它在最关键的那条路径上等于没有（**与 R19-F3 当初的判据一模一样：守卫必须落在真正打开该路径的函数里**）。

**为什么必须改在这里，而不是在 pilot 侧加检查**：spec 要求「zip 目标拒绝符号链接」，但 `try_one` 的每条生成路径都是**直接调 `generate_one_training_set`**，而最终文件名（`{code}_{start_datetime}.zip`）是**在生成过程内部**才确定的 —— pilot **拿不到那个路径，也就无从在它被打开之前 `O_NOFOLLOW`**。这道守卫在强制路径上**根本执行不了**，等于没有。**只有真正打开这个路径的那个函数，才有能力安全地打开它。**

改动是外科式的，且顺带修掉两个既有隐患：
- `os.replace` **不跟随**目标符号链接（它替换链接本身），故预先埋在 `{code}_{start}.zip` 上的符号链接**无法**再把写入引出目录。
- 生成中途崩溃不再于最终路径上留下半截 zip（原 `ZipFile(final,"w")` 一打开就截断）。

同一改动对 B2/B4 的既有生成路径同样生效（它们共用这个函数），属正向外溢。`content_hash` 语义与文件名契约**逐字不变**，由现有测试钉住。


### 4.2 pilot 编排（权威序列 ①…⑥ + `try_one`）

**副作用必须晚于全部输入校验（R27-F2）**：`2026-07-27-qmt-plan4b-fetch-design.md` §4.5 已规定「实拷清单不合规 → 拒绝，**且必须在任何 DB 写入之前**」，但本节原先的动作序列**第一步就是建/复用 `kline_pilot_<seed>`** —— 照它实现，一份被篡改或半截写入的 manifest 会先让工具 `CREATE DATABASE` / reset / apply schema，**然后**才被发现该拒绝，持久副作用已经落地。故权威序列拆成**准入阶段 / 执行阶段**：**准入阶段只读、只校验、零副作用；任一闸不过就退出，此时尚未创建/复用/reset 任何数据库、未写任何文件。**（这套命名与消费循环的「阶段 1 / 阶段 2」是两套无关编号，刻意用词不同以免混淆。）

> 这与 R7-F2（先证明替换可行再销毁旧的）是同一条原则的另一面：**先证明，再动手**。R7-F2 管的是「破坏性动作」，本条管的是「任何持久副作用」——包括那些看起来无害的 `CREATE DATABASE`。

**「校验归属」与「声明归属」必须拆成两步（R28-F1 修正）**：R27-F2 把 `--output` 归属闸放进准入阶段，同时声明该阶段零副作用——**但首次使用时的归属声明本身就要写 `.pilot_output.json`**，二者不可兼得：

- 若在准入阶段就写标记 → 后续 `--source`/集群闸失败时，会留下一个**被错误标记为「归本次所有」的目录**，而本次运行根本没跑起来；
- 若推迟到最后才写 → 「判空」与「声明」之间存在**竞态**，期间另一进程可能占用该目录。

故拆成：**准入阶段只做只读判定**（**路径尚不存在** 或 已存在且第 1 层标记相符），**声明动作紧贴首次写入之前**。

**首次使用的声明机制只有一个：`open_root(<output>, create_leaf=True)` —— 逐段无跟随走到父目录、再 `mkdirat` 独占创建，然后在这个刚诞生的目录里写标记**（R30-F2 + R75-F2）。**撞 `EEXIST` 一律拒绝启动、一个字节都不写**（R91-F2 —— `--output` 侧收紧为单一结局；此处原写「两种结局：有合法标记 → 复用/引导态」，与 R91-F2 直接冲突）：无合法标记（空的也算）→ 提示人工 `rmdir`（R64-F1 + R66-F2）；**有合法标记也拒绝**，提示「另一次运行在本次启动之后创建了它，请原样重跑」——**重跑会被 ① 判为已归属，从而完整走完 ①a / ①a′ / 。**不得用 `os.rename` 当不覆盖发布原语**：它在目标是空目录时会**替换**掉目标。

> **⚠️ 只用标记文件的 `O_CREAT|O_EXCL` 是不够的，别照那个写**：`O_EXCL` 保护的是**那个文件名**，不是**那个目录的占用状态** —— 它只挡得住另一个 pilot 抢建同名标记，挡不住任何其他写者在「判定」与「建标记」之间往目录里放东西，而那之后 pilot 会把该目录当成己有、`os.replace` 可覆盖那个无主文件。**目录级的竞态只能用目录级的原子操作关死。**

这样「准入阶段零副作用」与「归属从目录诞生起成立」两句才同时为真。

**「零副作用」的作用域必须写明，否则会留下陈旧的成功证据（R29-F1 修正）**：把它理解成「准入阶段一个字节都不写」会产生一个更糟的后果——**在已归属的输出目录上重跑时，一次坏 `--source` 会在覆盖旧报告之前就退出**；若上一次那份 `pilot_report.json` 写着 `SUCCESS` / `ship_eligible: true`，磁盘上那份**持久交付证据仍在宣称可出货**，而最近一次运行其实失败了。这直接架空 §7 —— R4-F3 我自己写过「rc 只活在终端里，JSON 才是持久交付物」，**陈旧的成功证据比没有证据更危险**。

正确的作用域是：**对「归属尚未证明的对象」零副作用**（数据库、源、未归属的目录）；而**已证明归属的输出目录不在此列** —— 往里**新增**一份报告是创造证据，不销毁任何东西（R69「只增不毁」）。收尾规则见 本文件 §4.2「准入失败的收尾规则」：**目录存在且第 1 层归属成立就写报告**，首次使用且目录尚未创建则无处可写、直接退出。

**不变量（可一句话检查，R69 修订）**：`pilot_report.json` **只可能存在于归属已确立的目录里，且它永远是「最近一次在该目录写过报告的运行」的副本**；而**每一次运行的报告都另有一份不可变的时间戳文件永久留存**。**本 plan 不做出货断言**：`pilot_report.json` 是「最近一次运行的诊断结论」，任何交付/出货判断**不得基于它**（§7 与 §0）。


> **为什么每股必须有独立 RNG（R50-F3 修正）**：`generate_one_training_set(conn, code, output_dir, rng)` 会把这个 `rng` 一路传进 `eligible_start_indices`，那里执行 `rng.shuffle(candidates)`（已核 `backend/generate_training_sets.py:115-133, 510-520`）。**共用一个可变 `rng` 时，某只股抽到哪个 `start_datetime`，取决于它前面有多少只股消耗过这个 rng**——而断点续跑里走 `already_done` 的股**根本不调生成、不消耗 rng**。于是「跑到一半被中断再续」与「一口气跑完」在**同样的 seed + 同样的源**下，会给后面的股选出**不同的起点**，产出不同的 zip。这直接推翻本 spec 花了 `2026-07-27-qmt-plan4b-fetch-design.md` §4.3/`2026-07-27-qmt-plan4b-fetch-design.md` §4.4 整整两节去建立的可复现性（冻结宇宙、`universe_idx` 排序、seed 派生），**而且是在最后一米上推翻的**。
>
> `random.Random(f"{seed}:{code}")` 让每只股的随机序列**只由 seed 与它自己的 code 决定**，与「它前面发生过什么」彻底解耦——中断多少次、哪些股走了 `already_done`，都不影响任何一只股的产出。这与 `2026-07-27-qmt-plan4b-fetch-design.md` §4.3 各层用 `random.Random(f"{seed}:{market}")` 独立 shuffle 是同一手法（那里防的是「改一层配额扰动别层」），**同一个教训我在层级上做对了，在股级上却漏了**。

**储备池顺序不重新推导**：pilot 读 `<staging>/fetch_manifest.json` 里 `qmt_fetch` 已记录的三层 `pool_order`，**不**用 seed 重新推一遍。理由：重新推导要求 pilot 侧的预筛与分层逻辑与 fetch 侧逐字一致，任何一侧漂移都会静默产生不同顺序（而 seed 相同会让人误以为可复现）。manifest 是单一真相源。

**消费顺序 = 按 `universe_idx` 升序，而非 `pool_order` 的追加顺序**（R12-F1，见 `2026-07-27-qmt-plan4b-fetch-design.md` §4.4）——否则重试成功的股会排到末尾，最终选中哪 100 只将取决于当时的网络抖动而非 seed。

**两阶段消费（先补地板，再补总数）**：

```
# ===== 准入阶段（R27-F2 + R28-F1 + R29-F1）=====
#      （注意：与下文消费循环的「阶段 1 / 阶段 2」是两套无关的编号，勿混）
#
# 零副作用的**作用域**：对「归属尚未证明的对象」零副作用——数据库、源、
# 以及尚未证明归属的输出目录。**已证明归属的输出目录不在此列**（R29-F1）。

① `--output` **第 1 层归属校验**（`2026-07-27-qmt-plan4b-fetch-design.md` §4.1；**不依赖 manifest**：路径尚不存在，
   或已存在且标记的 `tool` + `output_dir` 相符。此处不建目录、不写标记、**不动既有报告**）

①a **钉住输出目录并取输出锁（仅「已归属」支；R59-F2）**：**`out_fd = open_root(output_dir)`**（`2026-07-27-qmt-plan4b-fetch-design.md` §4.1，从 `/` 逐段 `O_NOFOLLOW`，R75-F2——**不是**裸 `os.open(output_dir, O_NOFOLLOW)`，那只保护最后一段）
     取得**目录 fd 全程持有**，并在其上取 **非阻塞 `flock`**。取不到（另一进程正在同一输出目录上跑）
     → **拒绝启动，什么都不动**，非零码 + stderr。
     **必须早于任何 `pilot_report.json` 的读取与任何输出目录写入**（R59-F2；R69 后不再有「授权判定」）。
     「首次使用」支此时路径尚不存在，其 pin + flock 推迟到 ⑥ 的**认领成功（`mkdir` + 写标记 + 复查）之后**紧接着做。

> **为什么输出锁必须尽早取（R59-F2；R69 后判据更简单）**：`--maintenance-dsn` 不同的两个调用**不共享** ①c 的按 seed advisory lock，**只有输出锁能拦住它们同时写同一个 `--output`**。**输出目录是被保护的对象，那么保护它的锁就必须在「关于它的第一个判断」之前取得**。（R69 之前这里还要防「两个运行拿着同一份旧报告去授权作废」，那条随作废一并取消。）

①a′ **经 `out_fd` 重核第 1 层归属（仅「已归属」支；R78-F1）**：`openat(out_fd, ".pilot_output.json",
     O_NOFOLLOW)` 重读并验第 1 层（`tool` + `output_dir`）。不符 → **拒绝启动，一个字节都不写**
     （此刻 `RUNNING` 尚未发布，是干净的中止）。
     **第 2 层留到 ③**（它需要 manifest，而 manifest 在 ② 才读到；把它设成写入前提会让
     `FAIL_OUTPUT_BINDING` 永远写不出来，R61-F1）。

> **为什么 ①d 之前必须再核一次（R78-F1 修正）**：① 的第 1 层校验是**没有锁、也没有钉住 fd** 时做的；
> 而 `RUNNING` 是一次**写**。于是「① 校验通过 → 标记被换掉 → ①d 往一个已经不属于我的目录里写 `RUNNING`」
> 这条路径是敞开的，要等到 ⑥ 才被发现——**而那时报告已经写下去了**。
> 这正是 R46-F1 立的判据：**授权的最后一次确认必须紧贴被授权的动作**。R46-F1 当时只把它应用到
> 「第一次状态改变」（⑥），**因为那时 `RUNNING` 还不存在**；R74-F1 引入 `RUNNING` 之后，
> **输出目录上的第一次写提前到了 ①d，授权确认就必须跟着提前到 ①a′**。
> 「首次使用」支不需要本步：它的目录由 ⑥ 的 `mkdirat` 亲手创建、标记随即写下、复查通过后才发布 `RUNNING`。

①b **staging 钉死 + 归属只读闸 + 取锁**（R65-F1「闸在前、锁在后」；R71-F3「先钉住再校验」）：
     1. **`stg_fd = open_root(<staging>)` 并全程持有**（R71-F3；从 `/` 逐段 `O_NOFOLLOW`，R75-F2）。
     2. 以 `openat(stg_fd, ".staging_owner.json", O_NOFOLLOW)` **只读**验它确实是一棵
        `qmt_fetch` staging 树：`tool == "qmt_fetch"`、`dest` 等于 `resolve(--staging)`、
        `seed` 等于本次 `--seed`；并就地做**路径重叠检查**（`--staging` 与 `--output`、以及与
        `--source`（若传）都不得相等或互为子树）。任一不过 → **拒绝启动，一个字节都不写**。
     3. 通过后 **`openat(stg_fd, ".staging.lock", O_CREAT|O_RDWR|O_NOFOLLOW, 0o600)`**
        → **`fstat` 确认它是普通文件**（非目录、非 FIFO、非设备）→ `flock(LOCK_EX|LOCK_NB)`。
        `ELOOP`（它是符号链接）或类型不符 → **拒绝启动，一个字节都不写**（R72-F2）。
     **此后对 staging 的每一次读写都相对 `stg_fd`**：`fetch_manifest.json`、`export_log.csv`、
     每只股的两个 K 线 CSV、`.inflight.json`、`.part`、以及 `staging_intact(code)` 的复校 ——
     **一律 `openat`，绝不再由 `--staging` 这个字符串解析路径**（R71-F3）。

> **锁文件本身也必须 `O_NOFOLLOW`（R72-F2 修正）**：`.staging.lock` 是**本工具在 staging 里创建并写入持有者信息**的文件。若用 `O_CREAT|O_RDWR` 打开而不带 `O_NOFOLLOW`，**一棵在其他方面完全合法的 staging 树，只要 `.staging.lock` 是一条指向外部的符号链接，就会让 fetch/pilot 去锁住并写入一个 staging 之外的任意可写目标** —— 归属闸刚刚建立起来的信任边界，被它自己创建的第一个文件绕过去了。这与 `2026-07-27-qmt-plan4b-fetch-design.md` §4.1 对标记/报告/zip 的 `O_NOFOLLOW` 纪律是同一条，**唯独锁文件被漏掉了**：因为它在直觉里是「协调用的临时东西」，而不是「数据」。**判据：凡是本工具会写入的路径，无论它承载的是数据还是协调状态，都要过同一套符号链接纪律。**

> **为什么 staging 也必须钉住 inode（R71-F3 修正）**：我给 `--output` 配了目录 fd 钉死（R57-F1）、配了 `flock`、配了路径/inode 分叉检查，**却让 `--staging` 一直停留在「按路径校验一次」的水平**。后果是：`--staging` 若在归属校验之后、或在取锁之后被改名/改指，**锁保护的是一个目录、而后续读到的字节来自另一个目录**。最坏的一档发生在 `staging_intact(code)`（哈希复校）与 `import_qmt_stock`（真正打开文件）之间 —— 那正是 R32-F2 当初用锁去堵的窗口，而**锁只挡住了「别的进程改这棵树」，挡不住「这个路径指向了另一棵树」**：入库的字节可以与 manifest、与刚刚跑完的 ④b 三方源校验**全部对不上**，而所有哈希基线都还以为自己验的是同一批数据。
>
> 这与 R57-F1 是同一条原则的第二个对象：**凡是「先校验、后使用」的目录，都必须在校验的那一刻把对象本身钉住，此后不再解析路径。** 我在 output 上做了，在 staging 上漏了 —— 又一次「原则只落在发现它的那个对象上」。

     取不到（另一进程真持有）→ **拒绝启动，不写报告、不作废任何东西**，仅非零码 + stderr。
     **文件残留不算「已存在」**——崩溃留下的锁由内核自动释放，重跑照常取得（R48-F2）。
     锁**必须早于任何 staging 读取、也早于任何输出目录写入**（R32-F2 / R35-F1 / R39-F1），
     并**一直持到 pilot_report.json 原子落盘之后**（R39-F1）。

> **为什么闸必须排在取锁之前（R65-F1 修正）**：`.staging.lock` 的取得是**要创建/写文件**的（`2026-07-27-qmt-plan4b-fetch-design.md` §4.5 还要求把持有者信息写进去）。原序列把它放在 ②（读 manifest）与 ④（`--source` 边界闸）**之前**，于是 `--staging` 一旦打错字、指向一个可写的 SMB 导出目录或任意路径，**工具会先往那个未经证明的目录里写一个锁文件**，之后才开始判断「这到底是不是我的 staging」。这与 R4-F4「绝不试写源」是同一条原则的第二个执行点：**任何写动作之前，先证明目标是我的**。
>
> 重叠检查也一并前移：它本来就在 ④ 里（七条闸之二，R82-F1 后），但那时锁早已写下去了；而重叠检查恰恰是用来发现「`--staging` 指到了源里」这种情形的。

①c **按 seed 的集群级互斥锁（R52-F1；非阻塞 + 前移，R53-F1）**：连上 `--maintenance-dsn`，
     执行 **`SELECT pg_try_advisory_lock(hashtext('kline_pilot_' || seed))`** —— **非阻塞**，
     返回 `false` 即**立刻**失败退出，**绝不等待**。
     取不到（同 seed 的另一个 pilot 正在跑）→ **什么都不写**，非零码 + stderr 说明「同 seed 的另一次运行正在进行」。
     取得后**持到最终报告 fsync 之后**（与 `.staging.lock`、`B2_GENERATION_LOCK_KEY` 同）。
     会话级锁**在连接断开时自动释放**，故崩溃安全、不需要人工清理；它**不留任何持久痕迹**，
     因此不违反「准入阶段对归属未证明的对象零副作用」（R27-F2）。

> ### ⚠️ 出货凭据链已整块移出本 plan（2026-07-28，user 拍板）
>
> **移出的是**：`--verify-shipment` 子命令、`is_shipping_credential` / `looks_like_shipping_credential`
> 两个谓词、**①e 出货凭据保护闸**、crc32 自证、`--repair-artifacts`、`report_schema_version` 版本闸，
> 以及 §7 原先那套「唯一出货证据」口径。
> **它们连同各自的论证一起进后续独立 plan**，本文件不再定义它们。
>
> **为什么移出（三轮实证，不是嫌麻烦）**：4c 在三轮对抗性评审里始终是重灾区（16 / 16 / 13 条），
> 而第三轮的 2 条 critical **全部长在 ①e 与那两个谓词上、且都是上一轮修法自己引入的**。
> 数量在降（44→41→25），但**新增 critical 说明修法本身在制造更严重的问题**：
> - 验证器 `False` = 拒绝出货 = 安全，故**每收紧一次谓词，就扩大一次「不受保护」的集合**；
> - 拆成两个谓词之后，§6 那条回归钉会让 **CI 强制复现刚被否决的行为**；
> - ①e 在纯诊断语义下是 **no-op**，修了也验不过，且实际是**破坏性**的。
>
> **本 plan 保留的是**：pilot 编排、判定（verdict）、**报告如实落盘**。
> 报告是**诊断产物**，能声称的上限是「跑完了，报告如实记录了发生过什么」——**不是出货凭据**。
> **§7 已同步改成「本 plan 不做出货断言」**。
>
> **保留 `RUNNING` 与 ①a′、删掉 ①e**：前两者防的是「上一次的 `SUCCESS` 冒充本次结论」，
> 那在纯诊断语义下**依然是撒谎**，且代价只是一次极小的早写 + 一次紧贴的授权确认；
> 而 ①e 的全部正当性是「别毁掉可出货的凭据」——**凭据不在了它就没有存在理由**，
> 诊断性重跑覆盖诊断报告是预期行为。

①d **发布 `RUNNING` 当前状态（仅「已归属」支；R74-F1，位置由 R75-F1 + R78-F1 定死）**：
     **必须排在 ①a / ①a′ / ①b / ①c 这四道「什么都不写」的闸全部通过之后、②（第一道会产生 verdict 的检查）之前。**
     用 ①a 钉住的 `out_fd` 原子写 `pilot_report.json` =
     `{verdict:"RUNNING", ship_eligible:false, report_id, started_at}`
     （tmp → `fsync(文件)` → `os.replace` → `fsync(out_fd)`）。**写不出去 → 立刻非零码退出**（此刻
     尚未做任何 verdict 工作、未改动任何状态）。**它不写时间戳文件**——`RUNNING` 不是任何一次运行的结论。
     「首次使用」支的对应动作在 ⑥ 认领成功之后（见下）。

> **为什么 `RUNNING` 不能紧跟 ①a（R75-F1 修正）**：我把它放在 ①a 之后，而 ①b（staging 归属/锁）与 ①c（按 seed 锁）**仍然是「一个字节都不写、什么都没动」的中止**。于是最平常的两件事——**`--staging` 打错一个字**、或**同 seed 的另一次运行正在跑**——就会把上一次那份完好的 `SUCCESS` 换成一份**永久停在 `RUNNING` 的报告**，然后干净退出：既没有终局的时间戳报告，也没有任何结构化失败记录。消费者读到的是「上一次运行崩了、结论未知」，而真相是「本次运行被正当地拒绝了、上一次的结论依然有效」。**把一次良性的并发重试变成一份被毁掉的交付凭据，比 R74-F1 原本要修的那个洞更容易触发。**
>
> 判据（此后按它排任何「先行发布」类动作）：**先行发布必须排在最后一道「什么都不写」的闸之后**——因为它本身就是一次写，凡是排在它之后的中止都不再可能是「什么都不写」的。R74-F1 只算清了「它要早于所有会产生 verdict 的工作」，**漏了另一半：它也必须晚于所有不产生 verdict 的拒绝**。

> **为什么必须是 `pg_try_advisory_lock` 而不是 `pg_advisory_lock`（R53-F1 修正）**：我在散文里写了「非阻塞式尝试」，给出的 SQL 却是**会阻塞**的那一个 —— **散文与可执行契约不一致时，实施者照的是 SQL**。而一旦阻塞，就会出现这样一条时序：第二个 pilot 已经用**等待之前那个状态**跑完了一系列准入检查，然后在这里**一直等**；等待期间第一个 pilot 跑完并改变了库与输出目录；锁释放，第二个 pilot 醒来继续 —— **它手里那套检查结论全部过期了**，却拿着它继续往下走。**任何等待都会让「等待之前做过的授权检查」过期。**
>
> **同时把它前移到 ①c（R53-F1）**：仅仅换成非阻塞还不够 —— 它必须排在**所有检查之前**，把**全部检查与全部动作**一起放进同 seed 的互斥区，检查期间没有任何同 seed 的进程能改动输出目录或库。这正是 R46-F1 那条判据的应用：**授权的最后一次确认必须紧贴被授权的动作**；做不到「紧贴」，就把中间的一切都锁起来。

② 读 <staging>/fetch_manifest.json → **完整形状校验**（`2026-07-27-qmt-plan4b-fetch-design.md` §4.5 全部条款）
     **② 内立即分支 `stopped_reason`（R93-F1，早于 ②b、早于任何 DB 动作与任何股的消费）**：
       · `source_path_escape` → FAIL_SOURCE_BOUNDARY + source_path_escape、rc=1
       · `staging_path_escape` → FAIL_STAGING_INTEGRITY + staging_error{kind: staging_path_escape}、rc=1
       · `max_bytes` → 放行（干净的配额终止，已拉到的股完全可用，R44-F2）
②b **staged `export_log.csv` 复校**（R38-F1）：读 `<staging>/export_log.csv`，
     要求字节数与 sha256 == manifest `staged_export_log` 记录值
     （该记录本身已在 ② 里被要求 == `source_snapshot.export_log_sha256`）
③ `--output` **第 2 层运行绑定**（`seed` + `export_log_sha256`，须在 ② 之后）

# （原 ③a「出货凭据保护闸」已随 R69 的「只增不毁」一并取消：没有任何东西会被销毁，
#   也就不需要证明「我有权销毁它」。它当初要保的性质——不拿一份注定 ship_eligible:false
#   的运行去换掉一份有效凭据——现在由「旧凭据永远留在它自己的时间戳文件里」直接保住。）

④ `--source` 边界闸（若传了；本文件 §4.3 **七条**，R82-F1）
④b **出货级源校验（R17-F2；从消费循环之后前移到此，R54-F1）**：传了 `--source` 才跑，
     pilot **亲自读源**做三方相等（判据见 本文件 §4.3，此处不复述）。**全程只读**，
     不碰 DB、不碰 output。失败 → 按收尾规则写 `FAIL_SOURCE_VERIFICATION` + `source_errors`。
     未传 `--source` → `source_verification` 强制记 `partial`（无视 manifest 自述），
     不构成失败，继续。**本步的结果直接带到收尾定 verdict 时使用，不再重跑。**

> **为什么它必须前移（R54-F1 修正）**：出货级源校验是一次**纯只读的信任边界检查**（比对源 / staging / manifest 三方哈希），它却曾是准入之外**唯一留在「第一次状态改变」之后**的只读闸：要跑完整个消费循环（导入 100 只股、生成 100 个 zip）**才发现 SMB 上的 K 线字节变了而 `export_log` 没变**。前移之后**在动第一根手指之前**就知道。
>
> 前移后还顺带得到一个好处：**失败得早**。原顺序要跑完 100 只股的导入与生成（可能几十分钟）才发现源已漂移；现在在动第一根手指之前就知道。
>
> 这是「**凡只读检查一律排在第一次状态改变之前**」这条判据（R48-F1 立）的**最后一个执行点** —— 至此准入阶段的只读闸集合是：② ②b ③ ④ **④b** ⑤ ⑤b，此后只剩真正会改变状态的动作（建/复用库、导入、生成、写报告）。
⑤ 集群闸 (i)(ii)(iii)（`2026-07-27-qmt-plan4a-db-guardrails-design.md` §4；只读查询，不含任何 DDL）
> **为什么 `.staging.lock` 挡不住这一档（R52-F1 修正）**：staging 锁只串行化**共用同一个 staging 目录**的调用者。而 `--staging` 是独立参数——**两个 pilot 完全可以用同一个 `--seed` + 同一个 `--output`，却指向两份不同的 staging 拷贝**。它们各自持有自己 staging 的锁，互不相识，于是**双双**过完 ⑤b 只读闸、**双双**冲进 `DROP DATABASE` / `CREATE DATABASE` —— 一个 `--reset` 运行可以就此**摧毁另一个正在跑的 pilot 库**。
>
> 而原序列把 `B2_GENERATION_LOCK_KEY` 取在**建/复用库之后**，那道锁**从设计上就够不着 `CREATE`/`DROP`**（它是库内的生成锁，要先有库）。**「谁能碰 `kline_pilot_<seed>` 这个库本身」需要一把在库之外、按 seed 命名的锁** —— 维护库上的 advisory lock 正是它：与库的存在与否无关，且会话断开即释放。
>
> 这与 R39-F1 是同一条原则的第二个执行点：**串行化闸必须早于它要保护的第一个破坏性动作**。那次保护的是「作废报告」，这次保护的是「DROP/CREATE 数据库」。


⑤b **目标库只读闸（R48-F1；按动作分支，R49-F2）**：若 `kline_pilot_<seed>` **已存在**，
     连进去跑 `2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 闸表中**本次动作适用的那几道**——**跑哪几道以 `2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 闸表为准，此处不复述判据**：
       - **带 `--reset`**：**闸 0−（`pilot_meta` 授权完整性，R80-F1）** + 归属闸 + 绑定闸
         + `--reset-foreign` 令牌校验。**闸 0− 排在最前**：后两闸要从 `pilot_meta` 读值，
         键能重复则「读到哪一行」取决于实现，而 DROP 是不可逆的。
         **指纹闸与结构闸不跑**——`2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 明确它们不参与 DROP 判定（指纹失配**正是**该 reset 的场景；
         把它们塞进来会让一个陈旧 schema 的库连 reset 都做不了，R49-F2）。
       - **不带 `--reset`（复用）**：闸 0− + 归属 + 绑定 + 指纹 + 结构，全跑。
     以上**全部是只读查询，不含任何 `CREATE` / `DROP` / apply schema**。库不存在则本闸无对象、跳过。
     失败 → 按收尾规则写 `FAIL_DB_BOUNDARY` + `db_boundary_error` + `db_bound_identity`。


⑤b′ **复用库既有活跃行数的前置断言（O3-F9 + P3-F5 + P3r3-F11）**——**物理次序已移到 ⑤b 之后**
     （P3r3-F11：原文标题写「排在 ⑤b 之后」而正文物理上排在它**之前**，实施者按序列自上而下实现
     拿到的正是 P3-F5 判错的次序）；**只在复用分支跑**；**verdict 用独立的 `FAIL_REUSE_OVERFULL`**
     （P3r3-F11：复用 `FAIL_TARGET_MISMATCH` 与它的权威定义冲突——那条定义是「**仅在本已准备判 SUCCESS
     的路径上检查**」且报告带三字段 `{expected, actual_total, actual_distinct}`，而准入期根本没有
     `actual_distinct` 这个量；照定义实现的人会认为 ⑤b′ 不该存在而不实现它，O3-F9 的「带内无出路」原样复活）
     > **为什么必须在 ⑤b 之后（P3-F5）**：原文次序是 ⑤ → ⑤b′ → ⑤b，于是在库**还没过归属/绑定/闸 0−**
     > 之前就连进去查活跃行数。`--maintenance-dsn` 指向共享集群、`--seed` 撞名别人的 `kline_pilot_alpha`
     > （4a 反复论证这个门槛很低）→ 145 > 100 → 直接判 `FAIL_TARGET_MISMATCH`，
     > stderr 还劝操作者「**请换 seed 或 `--reset`**」——**第一条指引就是去 DROP 一个 4a 用闸 0/0b +
     > `--reset-foreign` 整套机制保护的、别人的库**；而真正该出的 `FAIL_DB_BOUNDARY`（优先级 0b2）
     > 被一条低优先级 verdict 抢先。次一档：外来库没有 `training_sets` 表 → 抛异常 → 报成
     > `FAIL_INFRASTRUCTURE`，恢复指引同样走错。
     > **`--reset` 分支不跑本闸**——库马上要被 DROP，查它的行数没有意义。：复用库的活跃 `training_sets`
     行数 **> `target`** → **直接判 `FAIL_TARGET_MISMATCH`**，`target_mismatch` 说明「本库由更大门槛的运行
     建立，请换 seed 或 `--reset`」。
     > **为什么必须前置**：操作者先用 `--floors SH=95,SZ=1,BJ=1 --target 100` 做过分层实验（合法，
     > 判 `SUCCESS_NON_SHIPPING`，库里留下约 97 条 SH 行），随后用**默认门槛**跑正式那次：阶段 1 把 SZ 补到 40、
     > BJ 补到 8 → 活跃行数 ≈ 144；阶段 2 的 `while 成功总数 < target` 一次都不执行；危险形状全过 →
     > 完整性不变量 `总行数 == target` 不成立 → **`FAIL_TARGET_MISMATCH`**。**重跑判定完全相同**
     > （全走 `already_done`），而 spec 没有任何一条会删除「多余的、合法的、当代的」活跃行 →
     > **唯一出路是 `--reset` 丢光全部进度**，而「避免丢掉全部进度」正是允许复用的唯一理由（同 R1-F3 的死锁）。
     > 原文只断言了 `sum(floors) <= target`，**没断言「复用库既有活跃行数 <= target」**。
# ===== 准入失败的收尾规则（R69 简化 —— 唯一权威）=====
# **所有报告写入都是纯增量，故不再有「哪一步之后才允许写」的分界**。收尾只看两件事：
#   · **目录存在且第 1 层归属成立** → **写报告**（两份：时间戳文件 + 刷新 `pilot_report.json`），
#     verdict 取该失败对应项：
#       ①  归属不符      → 不写（那不是我的目录，仅非零码 + stderr）
#       ①a 输出锁取不到  → 不写（并发；什么都没动）
#       ①b staging 闸/锁 → 不写（尚未证明 staging 是我的，且目录可能还不存在）
#       ①a′ 经 out_fd 重核第 1 层不符 → 不写（R78-F1；RUNNING 尚未发布）
#       ①c seed 锁取不到 → 不写（并发）
#       ①d 自身写 `RUNNING` 失败（输出盘写不了、fsync 失败…）
#          输出盘写不了…）→ **什么都不写**，非零码 + stderr（R97-F1）：此刻 `RUNNING` 尚未发布
#          （或正是它写不出去），**且 ② 还没跑过，没有任何可信的 `output_binding` 可写进报告**。
#          **「准入阶段的基础设施异常一律写报告」那句话必须按 ①d 切开**（本文件 §4.3 0c 行同步）
#       ⚠️ ② 的三个分支**必须先判 `fetch_fatal_error` 是否存在**（O4-F1，判据由 4b §4.5 定）：
#          存在 → **无条件 fail-closed**，按 `fetch_fatal_error.kind` 映射；不存在才按 stopped_reason 走。
#          **不得拿 `stopped_reason` 取值当安全判据**——它是「本次为什么停」，会被后续运行的
#          `max_bytes` 洗掉，而 `fetch_fatal_error` 是「这棵 staging 是否已被证明动过」的粘性状态。
#       ②(fetch_fatal_error.kind == source_path_escape)  → FAIL_SOURCE_BOUNDARY  + source_path_escape   （O3-F4）
#       ②(fetch_fatal_error.kind == staging_path_escape) → FAIL_STAGING_INTEGRITY + staging_error{kind}  （O3-F4）
#       ②(stopped_reason == staging_recheck_failed)      → FAIL_STAGING_INTEGRITY + staging_error{kind}  （O4-F3：
#          4b P2-F3 的具名结局；缺这一行会让未匹配的值落到默认分支 → **放行**）
#       ②(其余形状不合规)                          → FAIL_MANIFEST_INVALID + manifest_error      （R30-F1）
#          ⚠️ 原文只有最后一行 → 照「唯一权威」的清单实现，**一次源树逃逸会被报成「manifest 畸形」**
#          （manifest 四字段齐全、读侧校验全过，只是收尾映射把结论抹平了），恢复指引整个走错。
#          **机械检查补一条：凡是一个步骤能产出 >1 个 verdict，收尾清单里就必须有 >1 行。**
#       ②b → FAIL_STAGING_INTEGRITY  + staging_error         （R38-F1）
#       ③  → FAIL_OUTPUT_BINDING     + output_binding_error  （R31-F1）
#       ④  → FAIL_SOURCE_BOUNDARY    + source_boundary_error
#       ④b → FAIL_SOURCE_VERIFICATION + source_errors        （R54-F1）
#       ⑤  → FAIL_CLUSTER_BOUNDARY   + cluster_boundary_error（R30-F1）
#       ⑤b → FAIL_DB_BOUNDARY        + db_boundary_error     （R48-F1）
#       ⑥  **已归属支**归属重核不符 → **写** FAIL_OUTPUT_BINDING + output_binding_error:
#          "owner_marker_swapped"，经 ①a 钉住的 out_fd（R75-F1；①d 已发布 RUNNING，
#          不写等于把「被正当拒绝」永久谎报成「结论未知」）
#       ⑥  **首次使用支** mkdir 撞 EEXIST 且无合法标记 → 不写（从未发布过 RUNNING）
#       **三处 `(st_dev, st_ino)` 分叉检查**（第一次状态改变之前 / 每条登记之前 / 最终报告落盘之前）
#          → **两支一律写终局** FAIL_ARTIFACT_INVALID + 顶层 output_path_diverged，经钉住的 out_fd 写
#          （P3r3-F7：三个检查点**都在 ①d/⑥ 发布 RUNNING 之后**——已归属支在 ①d 发、首次使用支在 ⑥ 内发，
#           故 `running_published` 在这三点上**恒为 True**，「未发布→什么都不写」那一臂**不可达**。
#           原文按「哪一支」切分会让首次使用支的报告**永久停在 RUNNING**，正是 §9-2s 判据的第四个反例）
#       ⑤b′ 复用库既有活跃行数 > target → **FAIL_REUSE_OVERFULL** + reuse_overfull{expected, actual_total}
#          （P3r3-F11：独立 verdict，不复用 FAIL_TARGET_MISMATCH——后者的权威定义要求三字段且
#           仅在准备判 SUCCESS 的路径上检查，准入期没有 actual_distinct）
#       执行阶段的任何失败 → 照常写（FAIL_INFRASTRUCTURE / FAIL_ARTIFACT_INVALID / …）
#   · **首次使用且目录尚未创建**（失败发生在 ⑥ 之前）→ 无处可写，直接非零码退出。
#   · 已归属支的这两份报告，覆盖的是 ①d 发布的 `RUNNING`（R74-F1 + R75-F1）。
#
# **这条规则比 R38-F2→R56-F2 那一版简单得多（R89-F1 更正，2026-07-28 再简化）**：
#   那时要区分「作废之前 / 之后」「有无既有报告」，是因为**授权判据是后验的**。
#   ①e 移出之后（§0），收尾只剩**一个纯前置问题**——「这目录是不是我的」（①/①a′/⑥）。
#   R86-F1 那条「别白白废掉一份可出货的凭据」随凭据链一并移出：**本 plan 没有出货凭据**，
#   诊断性重跑覆盖诊断报告是预期行为。
#   **区别在于它是静态可判的前置闸，不是 R29-F1→R68 那套后验授权。**


# ===== ⑥ 声明 / 重核归属——**必须整体排在第一次状态改变之前**（R28-F1 + R30-F2 + R46-F1）
#       「第一次状态改变」= 建/复用/reset 库、写产物、写**终局**报告；
#       **①d 的 `RUNNING` 被显式挖出去，是唯一被授权的更早报告写入**（R96-F1，定义见下方注释）=====
若为首次使用：open_root(<output>, create_leaf=True)   # 逐段无跟随走到父目录，再 mkdirat 独占创建
              # EEXIST → **一律拒绝启动、一个字节都不写**（R91-F2 收紧为单一结局）：
              #   · 有合法标记 → **也拒绝**，stderr：「另一次运行在本次启动之后创建了该输出目录；
              #     本次不做任何改动，请原样重跑」。**重跑时它会被 ① 判为『已归属』，
              #     从而完整走一遍 ①a（钉 fd + 取 `LOCK_EX`）/ ①a′（经 fd 重核第 1 层）**两道闸**」，
              #     而当前这条首次使用支**这两道都没跑过**（R91-F2：就地转复用会让一次运行
              #     绕开串行化与经 fd 的重核——两者都没发生过）。
              #   · 无合法标记（空的也算）→ 拒绝启动、提示人工 rmdir，**绝不自动认领**（R66-F2）。
              # ↓↓↓ 次序由 R97-F2 定死：**先取锁，再让标记可见**
              flock(新目录 fd, LOCK_EX|LOCK_NB)      # ← 必须在写标记之前（R97-F2）
              O_CREAT|O_EXCL|O_NOFOLLOW 写 .pilot_output.json（两层四项全写）
              → fsync(文件) + fsync(<output>) + fsync(父目录)   # R45-F2 耐久提交协议
若已有标记   ：**再核一次两层全部相符**（防 ① 之后标记被换掉）
首次使用支   ：`open_root(..., create_leaf=True)` **在 `mkdirat` 之后已直接返回该目录的 fd**
              （R75-F2：不再二次按路径打开——否则「刚建好的那个 inode」与「现在这个名字
              指向的 inode」可能已不是同一个）；**紧接着就在该 fd 上取 `flock(LOCK_EX|LOCK_NB)`**，
              **取到之后才写标记**（R97-F2；已归属支在 ①a 就已取得，此处不重复，R59-F2）

> **为什么锁必须早于标记可见（R97-F2 修正）**：原次序是「`mkdirat` → 写标记 + `fsync` → 取 `flock`」。
> 标记一旦 `fsync` 落盘，**这个目录对外就是一个「已归属、可复用」的输出目录**——第二个 pilot 会
> 在 ① 把它判为「已归属」，走完整的 ①a（钉 fd + 取 `LOCK_EX`）**并抢先取到锁**，随后发布 `RUNNING`
> 甚至写出终局报告；而**创建者此时才去取锁，必然失败**——它已经改过磁盘（建了目录、写了标记），
> 却拿不到锁、只能退出。**「同一 `--output` 的写者被串行化」这条不变量在创建这一瞬间是不成立的**，
> 于是「当前报告是谁的」取决于两次调用的竞速结果。
>
> 判据（补进对象 × 维度矩阵的维度①）：**让一个对象「对外可见地成为我的」与「我持有它的锁」
> 之间不得有窗口——取锁必须早于发布归属，而不是紧随其后。**
首次使用支   ：pin + flock 之后**紧接着**发布 `RUNNING`（同 ①d 的写法，R74-F1）。
              该支目录刚由本进程创建，不可能有陈旧报告，故这一步**失败即中止**即可，
              语义与 ①d 完全一致（写不出去说明输出盘本来就写不了，早退是干净的）。
两支共同     ：自此**一切对输出目录的写入都走这个 fd 的 `*at` 语义**
              （见下方「输出目录写入协议」B 段，R57-F1）
# ⑥ 失败按支分开（R75-F1 修正——①d 之后已写过 RUNNING，「什么都不写」在已归属支上不再成立）：
#   · **首次使用支**（`mkdir` 撞 EEXIST 且无合法标记）→ **一个字节都不写**，仅非零码 + stderr。
#       该支从未发布过 RUNNING（目录本就不存在），故它仍是干净的「什么都不写」中止。
#   · **已归属支**（重核两层不符 = ① 之后标记被换掉）→ **写终局报告**：
#       `FAIL_OUTPUT_BINDING` + `output_binding_error: "owner_marker_swapped"`、rc=1，
#       两份都写（新时间戳文件 + 覆盖 ①d 那份 RUNNING），**全部经 ①a 钉住的 `out_fd`**。
#       依据是 R57-F1 已立好的那条：**标记在别处被换掉，不能追溯性地把「① 验过、①a 钉住、
#       此后一直被 flock 持有的那个 inode」变成别人的**——把一份 RUNNING 永久留在那里才是真的坏。

> **为什么 ⑥ 必须在第一次状态改变之前（R46-F1 修正）**：原序列把「再核一次两层标记」放在动手**之后**，理由是 R28-F1 的「声明归属紧贴首次写入」。但那条理由只管**首次使用**（写标记是副作用，要尽量晚）；**已归属**那一支的动作是**纯只读的重核**，它被顺带一起挪到了后面 —— 于是「①（准入之初）验过标记」与「真正动手」之间那段窗口里标记被换掉时，**工具已经拿着过期授权往一个不再属于它的目录里写东西了**，重核才姗姗来迟地发现。**授权的最后一次确认，必须紧贴被授权的那个动作，而不是紧贴它之后。**
>
> 首次使用那一支同样要前移：`os.mkdir` 撞 `EEXIST` 时那是一个**我们刚刚证明认领失败了的目录**，往里写任何东西都违反归属边界 —— 该支的收尾规则仍是**什么都不写**。
>
> **但「⑥ 失败一律不写」这句在 R74-F1 之后已不再成立（R75-F1 修正）**：已归属支在 ①d 就写过一份 `RUNNING`；若 ⑥ 重核不符仍坚持「什么都不写」，结果是**把一份 `RUNNING` 永久留在那里**——那正是 R74-F1 引入 `RUNNING` 时要消灭的「结论未知」状态，而这次的真相明确得很：**本次运行被归属闸正当拒绝了**。故已归属支改写终局的 `FAIL_OUTPUT_BINDING`。**新增一条「先行发布」，就必须回头重算每一条「什么都不写」的出口是否还成立**——这与 R74-F1 那条「取消一条机制时先问它原本还顺带保证了什么」是同一个动作的反向。
>
> **（R69 之后这条边界的名字变了；R96-F1 把 `RUNNING` 显式挖出去）**：不再有「作废点」，取而代之的锚点是
>
> **【第一次状态改变】的唯一定义**：**建 / 复用 / reset 数据库、写产物 zip、写「终局」报告**（成功或任一 `FAIL_*`）。
> **`①d` 发布的 `RUNNING` 是唯一被授权、且必须发生在这条线之前的报告写入**，**不计入「第一次状态改变」**。
>
> **它凭什么被单独授权**：`RUNNING` 由 ①a 钉住的 `out_fd` 写、由 ①a′ 刚刚重核过的第 1 层归属授权、
> 在 ①a 取得的 `LOCK_EX` 保护之下，且**内容上不宣称任何结论**（`ship_eligible: false`）。
> 它是「作废旧结论」这件事被压缩成的那一次极小写入（R74-F1），**发生得越早越安全**——
> 而 ⑥ 要挡的是「往一个已经不属于我的目录里做实质改动」，`RUNNING` 不属于那一类。
>
> ⑥ 的 `mkdir` + 写标记是那第一次状态改变的一部分，故它与其后的一切都在这条线之后；
> **①–⑤b 的全部只读闸、以及 ①d 这一次 `RUNNING` 写入，都在它之前。**

# ===== 报告生命周期：只增不毁（R69 设计简化 —— 唯一权威）=====
# **本 spec 不再有「作废点」，也不再有任何销毁既有报告的动作。**
#
# 收尾时写两份**内容相同**的文件：
#   1) `<output>/pilot_report-<seed>-<UTC>.json` —— **不可变**：一经落盘永不覆盖、永不删除、永不改写；
#   2) `<output>/pilot_report.json`             —— 「**最新那份的副本**」，tmp + fsync → os.replace → fsync(<output>)。
# **刷新 (2) 是「创造」而不是「销毁」**：上一次的内容原封不动留在它自己的时间戳文件里。
#
# 由此，整条「谁有权销毁凭据」的授权链**不再需要存在**：
#   · 无「作废点」及其位置约束（那条边界曾被 R38→R39→R40→R43→R45→R46 挪了五次）
#   · 无 ③a 出货凭据保护闸（代次相符 / 出货能力 / 严格校验既有报告）
#   · 无 `SUPERSEDED` 中间态、无「先中和再归档」协议、无 ENOSPC 空洞
#   · 报告写入不再分 A/B 段：**所有报告写入都是纯增量**
# **没有销毁，就没有需要被授权的破坏。**
#
# ===== 【当前状态先行发布】——R74-F1 补齐的 fail-closed 前置 =====
# **在任何会产生 verdict 的工作之前，先把「当前状态」发布成一份诚实的非出货报告**：
#   · **已归属** → 在 **①d** 原子发布——即 ①a（输出锁）/ ①b（staging 闸与锁）/ ①c（按 seed 锁）
#     **三道「什么都不写」的拒绝全部通过之后**、② 之前（R75-F1：放在 ①a 之后，一次
#     `--staging` 笔误或一次良性的同 seed 并发重试就会把上一次的 `SUCCESS` 变成永久 `RUNNING`）
#     `pilot_report.json` = `{verdict: "RUNNING", ship_eligible: false, report_id, started_at}`
#     （tmp + fsync(文件) → os.replace → fsync(<output>)）。**写不出去（ENOSPC 等）→ 立刻中止**，
#     此时尚未改动任何状态，退出是干净的。
#   · **首次使用** → 目录在 ⑥ 才诞生，此前不可能有陈旧报告；⑥ 建好目录后**紧接着**发布同样的 RUNNING。
#   · 最终报告（成功或失败）在收尾时**覆盖**这份 RUNNING。**上一次运行的不可变时间戳文件始终不动。**
#   · 每一份报告都必须带 `output_binding`（R77-F2；口径由 R81-F1 收口）：取值来自
#     **② 已校验通过的 manifest**，**不是**现场重读 `.pilot_output.json`
#     （`owner_marker_swapped` 那一档标记已经不可信了）。
#     **允许 `export_log_sha256: null` 的只有三种**（判据：该 verdict 可能在 ② 通过之前产生，R97-F1）：
#     `RUNNING`（①d，manifest 还没读）、`FAIL_MANIFEST_INVALID`（② 本身没过）、
#     **`FAIL_INFRASTRUCTURE` 中 ①d 之后 / ② 通过之前那一段**（由 `fatal_error.stage` 区分；
#     ② 通过之后产生的 `FAIL_INFRASTRUCTURE` 必须非 null）。**其余一切 verdict 都必须非 null**——
#     包括 ②b `FAIL_STAGING_INTEGRITY` 与 ⑥ `owner_marker_swapped`，**它们都发生在 ② 之后**
#     （R81-F1 纠正：R79-F3 把这两档误列进「② 之前」了）。
#   · 另记 `marker_binding`（R81-F1）：标记自称的第 2 层身份，**仅供诊断**；读不到或已被换掉记 `null`。

# ===== 报告写入的唯一约束 =====
# 1. **落笔前重核归属——只作用于「①a 钉住 fd 之前」的写（R77-F1 收窄作用域）**：
#    · **①a 之前**（理论上只剩「首次使用支在 ⑥ 认领成功之前」这一段，此时无 fd 可用）：
#      `O_NOFOLLOW` 读 `.pilot_output.json` 验**第 1 层**（`tool` + `output_dir`），不符 → 一个字节都不写。
#      **第 2 层绑定不作为写入前提**——③ 的失败本身就是第 2 层不符，把它设成门槛会让
#      `FAIL_OUTPUT_BINDING` 永远写不出来（R61-F1）。
#    · **①a 之后**（`out_fd` 已钉住、输出 `flock` 已持有）：**一律经 `out_fd` 直接写，不再重核标记**。
#      **即使此刻读标记会失败或不符，也必须写**——那正是 ⑥ 已归属支的 `owner_marker_swapped` 场景。
#
#    > **为什么必须收窄（R77-F1 修正）**：这条协议立于 R56-F2，那时既没有 `out_fd` 钉死（R57-F1），
#    > 也没有 `RUNNING` 先行发布（R74-F1）。照它字面执行，真实时序是：①d 已把旧 `SUCCESS` 换成
#    > `RUNNING` → 标记在 ⑥ 之前被换掉 → 本条要求「一个字节都不写」→ **进程退出，
#    > `pilot_report.json` 永久停在 `RUNNING`，连时间戳报告都没有**。这与紧邻它的 R75-F1 规则
#    > （⑥ 已归属支必须写终局 `FAIL_OUTPUT_BINDING`）**在同一节里正面打架**。
#    >
#    > 判据取自 R57-F1 已经立好的那条：**`out_fd` 钉住的是 ① 验过、①a 起一直被 flock 持有的那个
#    > inode；标记在别处被换掉，不能追溯性地把它变成别人的。** 「重读标记、不符即不写」这个手段的
#    > **失败动作是「留下一个非终局状态」**——而 R57-F1 的判据正是：**一个保护手段的失败动作是什么，
#    > 决定了它能用在哪一段。** 它只能用在「还没有任何非终局状态需要收尾」的那一段，即 ①a 之前。
# 2. **⑥ 之后一律走钉住的 `out_fd` 与 `*at` 语义**（R57-F1）：zip 落地、`.superseded/` 挪动与删除、
#    owned zip `unlink`、两份报告的写入、目录 `fsync` —— 路径不再解析。
# 3. **耐久**：每次写各自 `fsync(文件)` + `fsync(<output>)`（R45-F2 / R51-F1）。
# 4. **失败也要留下报告**：任何 verdict-producing 的失败都写两份（含 `FAIL_INFRASTRUCTURE`）；
#    **首次使用**若失败发生在目录被创建之前，则无目录可写、直接非零码退出（那不是我的目录）。
# 5. **写最终报告之前**查一次 `(st_dev, st_ino)` 与 `--output` 是否分叉（R68-F1）。
#
# ===== 消费口径（诊断用；本 plan 不做出货断言，§0 + §7）=====
# · `pilot_report.json` = **最近一次在该目录写过报告的运行**的诊断结论。
#   **任何交付/出货判断都不得基于它**——本 plan 交付后唯一的读法是「按路径读」，
#   而按路径读**没有任何防线**（`--output` 中途被换 → 读到别的目录，§8 如实登记）。
# · 时间戳文件是**历史记录**：各自如实描述当时那次运行、不因后来的运行而失效。
# · 每份报告带 `report_id: "<seed>-<UTC>"` 与 `written_at`，读者可与 `pilot_report.json` 比对，
#   判断自己手上是不是最新那份。

> **为什么改成「只增不毁」（R69 设计简化）**：R29-F1 当初要求「重跑时必须作废陈旧的成功报告」，理由是「磁盘上那份持久证据仍在宣称可出货，而最近一次运行其实失败了」——**这个担忧完全正当，但「销毁旧的」并不是解决它的唯一办法，而且是代价最高的一种**。从 R38 到 R68 的三十一轮里，**约二十二条 finding 长在这条轴上**：作废点的位置被往后挪了五次、授权判据被加强了四次（第 1 层 → 第 2 层 → 代次 → 出货能力 → 严格校验既有报告）、崩溃安全被返工三次（R41 / R64 / R68），其中**五条是我自己上一轮的修复引入的**。
>
> 根因很简单：**「销毁一份证据」这个动作，天然要求回答「谁有权销毁」「凭什么」「销毁到一半崩了怎么办」「销毁完写不出新的怎么办」** —— 每个问题都要一条规则，每条规则都要在五个章节里同步一遍。
>
> 「只增不毁」把这些问题**一次性取消**。而 R29-F1 要保的那条性质——「读者不会把上一次的成功误当成当前状态」——由**一条更简单的规则**保住：**出货断言只认 `pilot_report.json`，而它永远是最新那份的副本**。
>
> **代价**：输出目录每跑一次多留一个几十 KB 的 JSON。**换来的**：整条授权链、一个持久中间态、一套 A/B 写入协议，以及围绕它们的二十余条规则，全部消失。
>
> **保留不动的**：所有锁与其次序、只读闸排在任何状态改变之前、`out_fd` 钉死、归属闸、耐久提交协议、路径/inode 分叉检查 —— 它们保护的是**数据库与产物**，与报告是否被销毁无关。这些纪律的锚点从「作废点之前」改为「**第一次状态改变（建/复用库、写产物）之前**」。


# ===== 执行阶段：从这里开始才允许产生副作用（全程仍持有 .staging.lock）=====
建/复用 kline_pilot_<seed> 库（P4-D7）
    # 此处**只剩真正的变更动作**，且必须两阶段（R55-F1）：
    #   CREATE DATABASE → **立刻**在一个事务里建 pilot_meta 并写 state=initializing
    #   → apply schema.sql → 同一事务补写指纹键并置 state=ready。
    #   （归属先于 schema：崩在中间时留下的是一个**带身份的**库，能被自己 --reset 清掉）它们所依赖的四闸与令牌校验**已在 ⑤b 全部跑完**（R48-F1），
    # 此处不重跑、也不再有「闸失败」这条出口。
取全局 B2_GENERATION_LOCK_KEY（**目标库内**的生成锁，session 级，**持到报告落盘之后**，R39-F1）
    # 注意它与 ①c 的按 seed 集群锁分工不同：①c 管「谁能碰这个库本身（含 CREATE/DROP）」，
    # 本锁管「库内的生成流程」。前者必须在库存在之前就生效，故两者不可互相替代（R52-F1）。

# 阶段 1：只消费尚未达地板的层，轮转（缺口最大的层优先）
while 存在未达地板的层:
    L = 未达地板且池未穷尽的层中，缺口最大者
    if 无这样的 L:                      # 某层池穷尽而地板不可达
        verdict = FAIL(floor_unreachable); 提前终止      # 见下
    try_one(L 的下一只)

# 阶段 2：三层轮转补到总数 target（默认 100）
while 成功总数 < target:
    L = 池未穷尽的层中，按 SH→SZ→BJ 轮转
    if 无这样的 L:
        verdict = FAIL(pool_exhausted); 提前终止
    try_one(L 的下一只)

verdict = SUCCESS
判定 + 报告（**全程仍持有全局锁与 `.staging.lock`**，R39-F1）

# **每股一个独立、可复现的 RNG（R50-F3）**——绝不共用一个可变 rng：
def rng_for(code): return random.Random(f"{seed}:{code}")

def try_one(code):
    取按股 session 锁 (IMPORT_GEN_LOCK_KEY, stock_lock_key(code))
    try:
        rows = SELECT file_path, content_hash FROM training_sets WHERE stock_code=code
        if len(rows) > 1:                             # R22-F2：不得随便挑一条继续
            记 stage=resume, reason=duplicate_active_rows ；return   # 由收尾集合校验判 FAIL_SET_CARDINALITY
        row = rows[0] if rows else None
        if row:                                       # 断点续跑候选，先验真（R1-F3）
            # R60-F1 + R61-F2：归属判定要**两条同时成立**，缺一不可
            p = Path(row.file_path)                            # **不 resolve**（resolve 会跟随符号链接）
            owned = (os.path.normpath(str(p.parent)) == canonical_output_str   # ① 字面判据：登记的那串路径
                                                                # 本身必须就在 canonical output 下
                     and same_inode(p.parent, out_fd)          # ② 身份判据：它现在确实指向钉住的那个 inode
                     and re.fullmatch(rf"{re.escape(code)}_\d+\.zip", p.name))   # R2-F1

            # ① 源代次：决定「库内 klines 还有没有效」，故排在归属判定之前（R6-F1）
            if not 源身份匹配(code):                   # pilot_stock_source vs 当前 manifest
                记 stage=resume, reason=source_generation_changed
                # R7-F2：先证明「换得成」，再销毁旧的。顺序不可颠倒。
                if not staging_intact(code):
                    记 stage=staging, reason=staging_integrity_mismatch
                    return                             # 旧行/旧 zip 原封不动，下次可重试
                # R9-F2：旧 zip 先「挪开」而不是留在原地——重生成极可能选中同一个
                # start_datetime，那样 ZipFile(final,"w") 会当场截断这个仍然有效的文件
                # R11-F3：挪动必须崩溃幂等（崩在 os.replace 与事务提交之间时可重放）
                # R87-F2：**先按归属分支**——!owned 时根本没有可保全的旧产物，
                #   下面整套 .superseded 协议都不适用（旧文无条件走它，会在收尾
                #   `unlink(p.name, dir_fd=sup_fd)` 处炸掉，因为 sup_fd 从未创建）
                if not owned:
                    记 stage=resume, reason=source_generation_changed + foreign_output_path
                    async with conn.transaction():
                        DELETE FROM training_sets WHERE stock_code=code   # **只删 DB 行**
                        import_qmt_stock(conn, ..., staging_dir_fd=stg_fd)
                        UPSERT pilot_stock_source(code, sha_1m, sha_daily)
                    generate_one_training_set(conn, code, output_dir, rng_for(code),
                                              output_dir_fd=out_fd)      # 重生成到**本次** output
                    成功 → 计数[该层] += 1（**绝不 unlink 那个外部文件**，R2-F1）
                    失败 → 记 `stage=regenerate, reason=…`（O3-F13：与 `owned` 分支、分支 ③、完整导入路径
                           三处同构——**只有这一条边此前没写**，于是事务已提交、生成失败时该股
                           **既不在 `succeeded` 也不在 `skips`**，`skip_reason_counts` 与池消费数对不平，
                           而它正是判断「`FAIL_POOL_EXHAUSTED` 是市场没货还是别的原因」的依据）
                    return

                if owned:
                    # R60-F1：以下全部相对 out_fd，绝不经过 --output 字符串
                    sup_fd = ensure_owned_dir_at(out_fd, ".superseded")  # R13-F2：lstat 判非符号链接，否则拒绝
                    if exists_at(out_fd, p.name):
                        os.replace(p.name, p.name, src_dir_fd=out_fd, dst_dir_fd=sup_fd)  # 同卷原子改名
                        os.fsync(out_fd); os.fsync(sup_fd)
                    elif exists_at(sup_fd, p.name) and crc32_at(sup_fd, p.name) == row.content_hash:
                        pass                                        # 上次已挪过，视作已完成
                    else:
                        记 stage=resume, reason=stale_artifact_missing   # 旧产物已不在，照常重建
                                                                    # ——不 abort、不卡死
                async with conn.transaction():         # 外层事务：删行与重导同生共死
                    DELETE FROM training_sets WHERE stock_code=code   # 让 write_qmt_stock 的重导互锁放行
                    import_qmt_stock(conn, ..., staging_dir_fd=stg_fd)   # R89-F2：必须传钉住的 fd
                                                       # 失败 → 整体回滚，旧行自动复原
                    UPSERT pilot_stock_source(code, sha_1m, sha_daily)
                    # 失败时把 .superseded 里的文件挪回原位（行已回滚，状态完全复原）
                generate_one_training_set(conn, code, output_dir, rng_for(code),
                                          output_dir_fd=out_fd)   # R58-F1；失败 → 记 regenerate
                成功 → **仅当本次真的把旧产物挪进过 `.superseded`** 才 `os.unlink(p.name, dir_fd=sup_fd)`
                       + `os.fsync(sup_fd)`（**缺失即忽略**，O3-F5）；计数[该层] += 1
                       ⚠️ 挪动三分支的**第三档**（最终路径与 `.superseded` 都不存在 → 记 `stale_artifact_missing`、
                       **不 return、照常重建**）走到这里会 `FileNotFoundError`；而「`.superseded` 里存在但 crc32
                       与 `row.content_hash` 不符」那一档 unlink **会成功**——删掉的是一份**本次从未挪进去、
                       也从未验过归属**的文件（很可能正是上次生成失败时保留、并写进 `preserved_superseded` 的那份）。
                       **规定：缺失即忽略；哈希不符时不得 unlink，只在报告如实记一条。**
                       （与 §9-3j / R87-F2 是**同一个 bug**——那次修的是 `!owned` 那条边，
                       **同一行 unlink 在 `owned` 分支内部还有第二条没被覆盖的边**；分支 ③ 的对应 unlink 明写
                       「缺失即忽略」而本处没有，**两处不对称本身就是它被漏掉的证据**。）
                失败 → **保留** .superseded 里那份，报告记 preserved_superseded 路径
                       （**文件名须带 `report_id` 前缀使其不可撞名**，O3-F14：该股此后 `training_sets` 已无行，
                       后续运行走完整导入路径、**永远不会再碰 `.superseded` 里那一份**；而候选起点只有 3~4 个，
                       若干轮后重生成很可能又选中同一 `start_datetime` → `os.replace(..., dst_dir_fd=sup_fd)`
                       **静默覆盖**它 → 操作者照旧报告去取「保留下来的旧产物」，取到的是另一代次的字节，**无任何报错**。
                       **`.superseded/` 的清理责任写明：本工具从不清，由人工清**）
                return

            # ② 同代且产物完好且归属本次 output → 才算数
            elif owned and 验证通过_at(out_fd, p.name, row.content_hash):   # 存在 + 可读 + crc32 相符（R60-F1：相对 out_fd）
                记 already_done，计入成功；return

            # ③ 同代但产物坏了 / 或路径不属于本次 output
            else:
                记 stage=resume, reason=(stale_training_set if owned else foreign_output_path)
                DELETE FROM training_sets WHERE stock_code=code
                if owned: os.unlink(p.name, dir_fd=out_fd) (缺失即忽略) ; os.fsync(out_fd)   # R60-F1
                generate_one_training_set(conn, code, output_dir, rng_for(code),
                                          output_dir_fd=out_fd)   # klines 同代有效，只需重生成
                成功 → 计数[该层] += 1 ；失败 → 记 stage=regenerate, reason=...
                return

        # 完整导入路径：新股，或上面 ① 判定源代次已变的旧股
        if not staging_intact(code):        # R4-F1：导入前复校 staging 两个 CSV
            记 stage=staging, reason=staging_integrity_mismatch
            return                          # 绝不导入来路存疑的字节
        import_qmt_stock(conn, ..., staging_dir_fd=stg_fd)      # R89-F2：必须传钉住的 fd
                                                                # 失败 → 记 stage=import, reason
        UPSERT pilot_stock_source(code, sha_1m, sha_daily)      # R6-F1：与登记同一逻辑步骤
        generate_one_training_set(conn, code, output_dir, rng_for(code),
                                  output_dir_fd=out_fd)   # 失败 → 记 stage=generate, reason
        成功计数[该层] += 1
    finally:
        释放按股锁
```

**三条断点续跑分支的处置为什么不同**：
- **①源代次变了** → 库内 klines 本身是旧一代数据，**重生成解决不了**（生成只是把库内数据序列化），必须走完整重导入让 `write_qmt_stock` 的整体替换语义把 klines 换成当代。
- **③同代但产物坏/外部路径** → 库内 klines 有效且是当代的，**只需重生成 zip**，不必付重新解析 + 合成六周期的代价。
- **②全都对** → 直接计入，这是断点续跑省时间的主路径。

**销毁必须排在「替换已就绪」之后（R7-F2 修正）**：分支 ① 原先的写法是「先删行 + 删 zip，再落到下面的完整导入路径」——而 `staging_intact` 检查就在那条路径上。于是新 staging 一旦损坏/缺文件，**旧产物已经没了、新的又产不出来**：一次本可重试的失败被变成不可逆的进度丢失，而这恰恰发生在「允许复用」所要保护的东西上。

修正后的顺序与其成立理由：

1. **`staging_intact` 提到最前** —— 输入不可信就直接返回，旧行与旧 zip 原封不动，下次可重试。
2. **删行与重导入包进同一个外层事务** —— 必须先 `DELETE` 那一行，`write_qmt_stock` 的重导入互锁（`ReimportBlockedError`）才会放行；而两者同事务意味着导入若失败，**回滚会把那一行原样恢复**，不需要手写补偿逻辑。（`write_qmt_stock` 内部自带 `conn.transaction()`，在外层事务里退化为 savepoint，语义正确。）
3. **旧 zip 先原子改名挪进 `<output>/.superseded/`，而不是留在原地等着被覆盖（R9-F2 修正）** —— 只有新产物登记成功才删掉挪走的那份；生成失败则**保留**它并在报告里记 `preserved_superseded` 路径。

> **为什么「等新旧路径不同再删」是错的（R9-F2）**：我原以为新 zip 叫 `{code}_{新 start}.zip`、起点变了就不同名，所以「先生成、再按需删旧」是安全的。实际上**候选起点总共只有 3~4 个**（§1.2），而删掉 `training_sets` 行之后 `exclude_starts` 为空，重生成**极可能选中同一个 `start_datetime`** → 新旧同名 → `assemble_from_windows` 的 `ZipFile(path, "w")` 会**当场截断那个仍然有效的旧 zip**，而此时 DB 行已经提交删除了。生成再抛异常（磁盘满、数据不过门），行和文件双双消失。
>
> 把旧文件**先挪开**，就让「最终路径」在生成开始时必定是空的：截断打不到任何有效产物，失败时挪走的那份原封不动。`os.replace` 同卷改名是原子的，代价接近零。

**挪动本身必须崩溃幂等（R11-F3 修正）**：`os.replace` 与随后的事务提交之间存在一个崩溃窗口——挪完了、事务还没提交就断电/被杀。重跑时 `training_sets` 行仍在（事务从未提交）、仍指向**原始路径**，而那个文件已经被挪走了。若照直再执行一次 `os.replace(p, …)`，会因 `p` 不存在而抛 `FileNotFoundError`，**该股从此每轮都卡在同一个地方**。故挪动三分支：

| 状态 | 判定 | 动作 |
|---|---|---|
| 最终路径存在 | 正常首次 | `os.replace` 挪走 |
| 最终路径不存在、`.superseded/` 里那份存在**且 crc32 与 `row.content_hash` 相符** | 上次已挪过 | 视作已完成，继续 |
| 两处都不存在（或 `.superseded` 那份哈希对不上） | 旧产物已丢失 | 记 `stale_artifact_missing`，**照常继续重建**，不中止 |

第三分支的取舍：旧产物本来就是要被替换掉的**旧代次**数据，它丢了不构成损失；此时中止只会把一个能自愈的状态变成永久卡死。

**簿记项豁免有前提：只在归属已被证明之后才成立（R27-F1）**：

- **首次使用**（尚无经校验的归属）：`--output` 由 `mkdirat` **独占创建**（R30-F2）；**撞 `EEXIST` 一律拒绝启动**（R91-F2：无论有无合法标记；无标记那一档另见 R64-F1 + R66-F2「绝不自动认领」）。故 `.superseded/` 与任何 `.pilot_output.json` 都**不可能**先于本次运行存在——**「预先建好的空目录」一律拒绝**，因为「判空 → 建标记」之间的窗口挡不住其他写者放进文件。
- **归属已证明之后**（存在 `.pilot_output.json` 且两层校验全过，R31-F1）：`.superseded/` 与 `.pilot_output.json` 才不参与「空目录」判定，也不进产物校验（里面的文件从不被登记）。

> **为什么豁免不能无条件（R27-F1 修正）**：这条豁免的本意是「**在已经确认是我的目录里**，这些簿记项不该被当成外来内容」，但原文把它写成了无条件。字面实现的话，一个只含**陈旧或不匹配**的 `.pilot_output.json`、或只含一棵遗留 `.superseded/` 树的目录，会被判为「空」→ 被新运行**收编** → 随后 `source_generation_changed` 的恢复路径就往那个**归属从未被证明**的 `.superseded/` 里 `os.replace` 覆盖文件，而报告还宣称输出目录归本次运行所有。**豁免自身成了绕过归属闸的通道**——这与 R8-F1「形状不是归属」是同一件事的另一副面孔：**不能用「我认得这个文件名」来代替「这个目录是我的」**。

万一在第 2 步提交之后、第 3 步之前崩溃：库内 klines 与 `pilot_stock_source` 已是当代、`training_sets` 无该股行、旧产物安放在 `.superseded/` → 下次重跑走完整导入路径，`write_qmt_stock` 的整体替换语义使其**幂等**，不产生坏状态。

**为什么 `already_done` 必须先验真再计数（R1-F3 修正）**：原设计「见到 `training_sets` 有该股的行就计入成功」，而 `file_path` 可读性检查放在**整轮结束后**（本文件 §4.3）。这组合会产生一个**不可恢复的死锁状态**：上一轮留下一行 zip 已丢失/被移动/`content_hash` 失配的记录 → 本轮把它计入地板与总数 → 判定达标 → 最后的可读性检查失败 → rc 非零 → **重跑时对同一行做出完全相同的 `already_done` 判定** → 永远失败，除非整库 `--reset` 丢掉全部进度（而「避免丢掉全部进度」正是允许复用的唯一理由）。

改法要点：
- 验证下沉到**按股锁内**（原设计的 EXISTS 查询在锁外，与后续写入之间存在窗口）。
- 验证 = 文件存在 + 可读 + **crc32 与 `content_hash` 相符**（不只是存在性；`zip_and_hash` 产出的就是 crc32，`^[0-9a-f]{8}$`）。
- 坏行的处置是**就地恢复**而非报错退出：删行 + 删残留 zip（**仅当 owned**）+ 重跑一次 `generate_one_training_set`。klines 还在库里，无需重新导入，代价很低。恢复也失败才记 skip。
  > 本条只描述 本文件 §4.2 `try_one` 的**分支 ③**（同代次、产物坏掉）。**分支 ①（源代次已变）不适用**——那里必须走 `.superseded` 先证后毁序列，且要完整重导入而非只重生成。以伪代码为准。
- 报告里 `stale_training_set` 与 `foreign_output_path` 各自单独成一类 reason —— 它们出现的频次本身就是「上一轮/上一个 output 发生过什么」的重要信号，不该被并进普通 skip。

**`unlink` 的白名单判据（R2-F1 修正 —— 这条是不可逆删除，必须写死）**：`kline_pilot_` 前缀护栏约束的是**库名**，它对 `training_sets.file_path` 里存的**文件系统路径**没有任何约束力 —— 两者毫不相干。一个复用的库若来自上一次用了**不同 `--output`** 的运行，行里的路径就指向另一棵输出树；手工损坏的行更可以指向任意可写文件。

因此，**只有同时满足以下两条**的路径才允许 `unlink`：

1. **字面判据**：`os.path.normpath(file_path)` 的父目录**逐字等于** canonical `output_dir`（`normpath` 顺带折叠 `..`）——**绝不用 `resolve()`**：它**会跟随符号链接**，`/tmp/alias/{code}_{start}.zip`（`/tmp/alias -> <output>`）会被放行，而登记进 DB、日后交给 B3 打开的**仍是那串别名**（R61-F2）；
1b. **身份判据**：该父目录的 `(st_dev, st_ino)` 等于 ⑥ 钉住的 `out_fd`（R60-F1）。两条**缺一不可**：字面判据挡「登记的字符串不在 canonical 下」，身份判据挡「字符串看着 canonical、但那个目录已不是我们钉住的那个」
2. 文件名匹配 `^{re.escape(stock_code)}_\d+\.zip$` —— 即 `assemble_from_windows` 的既有命名契约 `f"{stock_code}_{start_datetime}.zip"`

不满足 → **绝不 `unlink`**，只删 DB 行（`reason=foreign_output_path`）并重生成到本次 `--output`。

同样重要的是**外部路径即便验证通过也不得计入 `already_done`**：那意味着本次 `--output` 里根本没有这只股的产物，而报告却宣称成功——等于用另一棵输出树的产物给本次运行背书。本文件 §4.3 末尾的「逐条打开 `file_path`」检查也会因为读的是那个外部文件而一并被骗过去。

**导入前必须复校 staging 完整性（R4-F1 修正）**：`staging_intact(code)` = 定位该股的两个 staged CSV，逐个比对**字节数与 sha256** 是否仍与 `fetch_manifest.json` 记录一致；不一致 → 记 `stage=staging, reason=staging_integrity_mismatch`，**不导入**。

> **为什么这道闸不能省**：`qmt_fetch` 与 `qmt_pilot` 之间隔着任意长的时间（可能几天、可能中间跑过多轮 pilot），而 staging 是一棵普通的本地目录树 —— 磁盘坏道、误编辑、半途中断的复制都可能改动它。链路上现有的校验**没有一个覆盖这一段**：最终 zip 的 crc32 只证明「zip 与 DB 行一致」，`build_stock_import` 门2 只比行数与首尾时间戳，门4 比的是 1m↔日线**彼此**自洽 —— 正是本 spec 自己在 R2-F3 里论证过「等长的中段改动一道门都拦不住」的那类损坏，会一路走进 `verdict: SUCCESS` 的报告。
>
> 成本很低：两个文件约 5 MiB 的本地读，且只在**真要导入**这只股时才做（`already_done` 分支提前 return，不付这个代价）。

**为什么必须分两阶段**：三层等量轮转到 100 只会收敛到约 33/33/34，而地板要求 **SZ ≥ 40** —— 等量轮转**永远达不到 SZ 地板**。先把三个地板（30/40/8，合计 78）补齐、再用剩余的 22 个名额轮转补到 100，既保证地板必达，也让总数**恰好**落在 `target`（而不是为了追补某层地板而超出）。

> 这条约束成立的前提是 `sum(floors) ≤ target`（默认 78 ≤ 100）。若调参使 `sum(floors) > target`，两阶段会在阶段 1 就超出 `target`。CLI 启动时**先断言 `sum(floors) <= target`**，不满足即拒绝（配置矛盾不可表达，而不是运行到一半才暴露）。

**要点**：
- **全局锁整轮持有，直到报告落盘之后才释放（R39-F1）**：pilot 是该库唯一 writer；同时防止误在同一库上并行跑两个 pilot，也保证「产物校验 / 全库源代次扫描 / 集合校验」这套取证与它的结论落盘之间，库不会被第三方改动。
- **按股锁可重入性**：pilot 外层取 session 级按股锁，`generate_one_training_set` 内部对同一把 key 再取一次 session 级锁。PostgreSQL session 级 advisory lock **按 session 计数**（Plan 3 已在真 PG 15.12 上实测 session+xact 跨级别可重入），故 `generate_one_training_set` 的 `finally` 解一次后计数回到 1，pilot 外层再解一次归 0。**此假设必须在 `verify_pilot_e2e.py` 里对真 PG 复验，不得只靠假 conn**（假件会静默建模出「锁永远拿得到」的错误语义）。
- **每股至多 1 组**：调 `generate_one_training_set` 恰好一次，绝不调 `generate_batch`。
- **地板不可达即刻终止**：某层池穷尽而其地板未达 → 该地板已不可能达成，继续消费其他层纯属浪费（真跑一只股的导入含完整门检查，成本可观）→ 立即 FAIL。**报告须显式写明「因 X 层池穷尽、地板不可达而提前终止，其余层未继续消费」**，不得让读者误以为其余层已被验证。
- **单股失败不中止整批**；仅基础设施级错误（DB 断连、staging 目录不可读）中止并以非零码退出。


### 4.3 判定与诊断报告（verdict 枚举 / 报告 schema 的唯一权威）

**出货级源校验：由 pilot 自己读源（R17-F2）**

`qmt_pilot` 新增可选参数 `--source <已挂载的只读路径>`：

- **传了 `--source`**：pilot **先过下述「源边界闸」**，通过后才在定 verdict 之前**自己跑一遍全量源校验**。校验是**三方相等**（R20-F1），不是两方自比：

  ```
  对每个已拷文件 f（= manifest `files` 全部条目 + `staged_export_log`，R38-F1）：
      sha_source   = 读【源】算 sha256
      sha_staging  = 读【staging】算 sha256
      sha_manifest = manifest 里 f 的记录值
      要求 sha_source == sha_staging == sha_manifest     # 三方全等，缺一不可
  ```
  `full` 级跑两趟并要求两趟一致。结果写进**报告自己的** `pilot_source_verification`（含趟数、`files_verified`、每趟 `aggregate_sha256`、时间戳、`passes_agree`）。三方相等断言失败 → **`FAIL_SOURCE_VERIFICATION` + `source_errors`（每条必带 `error` 判别字段，枚举见 本文件 §4.3 报告 schema，R86-F2）**（R21-F2），**不得降级为 `partial`**。

  **出货级源级别 = fetch 侧与 pilot 侧的「取小」，两边都要有各自的凭据（R21-F1）**：

  | | 要求 |
  |---|---|
  | fetch 侧 | manifest 的 `source_verification` 必须 ∈ `{snapshot, full}`。**是 `partial` 则本次运行封顶 `partial`，pilot 再怎么验也升不上去** |
  | pilot 侧 | 三方相等校验通过；且 `full` 需 pilot 自己的 `--confirm-no-export-window`，`snapshot` 需 pilot 自己的 `--snapshot-gmt-token`（与 本文件 §4.3 源边界闸第 4 条的挂载 token 比对一致） |
  | 最终级别 | **两侧级别取较低者**（`snapshot` > `full` > `partial`） |

  > **为什么 fetch 侧的 `partial` 必须是黏性的（R21-F1 修正）**：`2026-07-27-qmt-plan4b-fetch-design.md` §4.4 明写 `partial` → **直接排除出货资格**，而 本文件 §4.3 又说 pilot 自己读源即可定到 `snapshot`/`full` —— **两处从未定义优先级**。照后者实现，一次「fetch 时故意 `--skip-existing-verify` 跳过校验」的运行，可以在 pilot 阶段被**洗白**成出货证据，`2026-07-27-qmt-plan4b-fetch-design.md` §4.4 那条排除规则形同虚设。
  >
  > 取小规则同时保住两件事：fetch 侧的凭据（操作者当时对导出窗口的声明、快照 token）**不因后续补验而失效**；pilot 侧的亲自读源仍是**必要**条件（R17-F2 的结论不动）。**两侧各自证明的是不同时段的事，谁也替代不了谁。**

  > **为什么必须三方相等，只比 source↔staging 不够（R20-F1 修正）**：边界闸只钉死了 `export_log.csv` 的哈希，而本 spec 自己在 R3-F3 / R6-F1 里已经论证过——**`export_log.csv` 可以逐字节不变而 K 线 CSV 内容已换**。于是「source 与 staging **双双**是新一代」这个情形下，两者自比必然一致 → `ship_eligible: true`；而 `pilot_stock_source`、源代次全库扫描、`staging_intact` 这一整套不变量，**全部是拿冻结的 manifest 当基准的**。出货断言与其余所有不变量**锚在了两个不同的东西上**，报告就可能宣称「已验证的源代次」而实际出货的 zip 来自另一代。
  >
  > 把 manifest 拉进等式，等于宣告：**出货资格所验证的那一代，必须就是全套不变量所依据的那一代。** 代价接近零（manifest 的哈希本来就在内存里）。




**判定顺序（R4-F3 修正 + R17-F2）**：**产物校验与出货级源校验都必须跑在 verdict 定稿与报告落盘之前**，不能放在报告生成之后。

```
消费循环结束
  → 出货级源校验的结果**取自准入阶段的 ④b**（R54-F1：它是只读闸，已在第一次状态改变之前跑完），
     此处**不重跑**；未传 --source 时该结果恒为 partial
  → 产物校验（逐条：归属 + 可读 + crc32，见下）
  → 源代次全库扫描（R14-F1）：遍历**所有活跃 training_sets 行**，逐条比对
     pilot_stock_source 与当前 manifest；有对不上的即 FAIL_STALE_GENERATION
  → 集合「危险形状」校验（R22-F2，**无条件跑**）：无任何股占 >1 行、
     每行都属于本次 manifest 池；不符即 FAIL_SET_CARDINALITY
  → 按下方**优先级表**定 verdict（R28-F2；不再用散文描述顺序）
  → 定 verdict（上面任一失败都压过「计数意义上的达标」）
  → 写 pilot_report.json + 人读摘要
  → **报告原子落盘之后**才释放全局锁与 `.staging.lock`（R39-F1）
  → 按 verdict 退出：**退出码以 本文件 §4.4 的中央映射表为准**
     （SUCCESS→0，SUCCESS_UNVERIFIED_SOURCE→2，SUCCESS_NON_SHIPPING→3，任一 FAIL_*→1；R35-F3）
```

> **为什么两把锁都必须持到报告落盘之后（R39-F1 修正）**：原序列在消费循环结束后就释放全局锁，`.staging.lock` 也只写到「持到导入与出货级源校验结束」—— 而**报告的取证过程恰恰全在那之后**：产物逐条校验、源代次全库扫描、集合危险形状校验、verdict 定稿、JSON 落盘。锁一放，另一个 pilot（或补拉的 fetch）就能在**取证与落盘之间**改掉库、改掉输出目录、换掉 staging 文件 —— 于是 `pilot_report.json` 描述的是一个**已经不存在的状态**：它逐条验过的 zip 可能已被覆盖，它扫过的活跃行可能已被增删。
>
> 这与 R32-F2 是同一个错误的下半段：那次是「导入期间 staging 可能被改」，这次是「**取证期间库与输出可能被改**」。两次的根因都一样 —— **锁的生命周期按「主要工作做完了没」来划，而不是按「这份断言依赖的状态什么时候不再需要稳定」来划**。报告是对状态的断言，锁就必须活到断言落盘为止。

> **为什么「每股至多 1 组」必须由集合级校验来保证（R22-F2 修正）**：这是 spec 的**核心契约**（原 pilot spec D6 / codex R10-F2：防凑数掩盖失败），可它此前**从未被 verdict 验证过**。verdict 只数 distinct 成功股，而底层 schema 只有 `UNIQUE(stock_code, start_datetime)` —— **同一只股完全可以有两条起点不同的有效行**；复用库还可能残留上一轮的**超额**活跃行。断点续跑那条路径又是 `SELECT … WHERE stock_code = code` **只读一行**，连「这只股有几行」都不问。
>
> 于是 SUCCESS 可以与「库里和输出目录里躺着重复/多余的训练组」共存，下游 B3 租借会把它们当独立库存发出去。**逐股检查证不了集合性质**——必须把活跃集合当整体校验。
>
> **但这四条不是同一类，不能一起无条件跑（R24-F1 修正）**：
>
> | 类别 | 判据 | 何时跑 |
> |---|---|---|
> | **危险形状**（任何情形下都不该出现） | 某股 >1 条活跃行；有行不属于本次 manifest 池 | **无条件**，任何 verdict 之前 |
> | **完整性不变量**（只在「本该齐了」时才成立） | 总活跃行数 == `target`；distinct 股数 == `target` | **仅在准备判 SUCCESS 时** |
>
> R22 的原写法把四条一起无条件跑，后果是：**任何正当的凑不够场景**（`FAIL_FLOOR_UNREACHABLE` / `FAIL_POOL_EXHAUSTED`）下活跃集合**必然低于 `target`** → 基数闸抢先触发、把那个更具体更可行动的 verdict **盖掉**，操作者只拿到一句泛泛的「基数不对」，而不是「BJ 层池穷尽，去补拉」。这直接架空了 本文件 §4.3 存在的理由（诊断可行动）。
>
> **根因是我加不变量时没问「它什么时候会被正当地违反」**——「总数等于 target」在失败运行里被违反是**正常且预期的**，它根本不是一条恒真不变量，而是 SUCCESS 的**候选前提**。
>
> 附带修正：断点续跑读该股行时若发现 **>1 条**，直接记为基数违规而**不是**随便挑一条继续。

> **为什么必须做全库扫描而不只看本轮处理过的股（R14-F1 修正）**：R7-F2 规定「新 staging 损坏时**保留**旧行旧 zip、不销毁」——这条本身是对的（不可重试的销毁比暂时的不一致更糟）。但我漏了下半句：**那个被保留下来的、源代次已对不上的行，不能与 `SUCCESS` 共存**。原判据只看计数、地板、产物路径/可读/crc32，**没有一项要求「所有活跃行都属于当前源代次」**。于是某只股卡在 `source_generation_changed` + `staging_integrity_mismatch` 时，其余股照样能凑够 100 → 报告写 SUCCESS，而库与输出目录里**还留着一个旧代次的已登记训练组**，`pilot_stock_source` 这条不变量就被绕过去了。
>
> **保留（不销毁）与判失败（不放行）并不冲突**，两者恰恰应当同时成立：行留着等操作者修好 staging 后重跑，而本次运行**如实判 FAIL**。这比「为了让 verdict 好看而把行删掉」诚实得多，也比「留着行却报 SUCCESS」安全得多。

**verdict 优先级表（R28-F2 —— 唯一权威，取代一切散文式顺序描述）**：自上而下第一个命中者即最终 verdict。

| 优先级 | verdict | 类别 | 为什么排在这 |
|---|---|---|---|
| 0a | `FAIL_MANIFEST_INVALID` | 准入·输入 | manifest 不合规（`2026-07-27-qmt-plan4b-fetch-design.md` §4.5 任一条款）→ 一切下游判断失去基准。报告带 `manifest_error`（R30-F1） |
| 0a2 | `FAIL_STAGING_INTEGRITY` | 准入·输入 | **两种触发（R90-F1 补齐第二种）**：①staged `export_log.csv` 与 manifest `staged_export_log` 记录不符（本文件 §4.2 步骤 ②b）→ 导入器真正消费的那份全局元数据已漂移，所有股的门2 判定失去基准（R38-F1）；②**staging 树内任一 `open_under` 调用撞 `ELOOP`/`ENOTDIR`（`staging_path_escape`）**→ 树布局本身被动过，同目录下所有股都受影响（R89 自查补）。报告带**判别式** `staging_error`（形状见 本文件 §4.3 schema）。**两种都是整轮致命，`staging_path_escape` 绝不得降级成逐股 skip**（R87-F1 判据：「树布局被动过」不是「这只股拉不到」）。排在 `FAIL_MANIFEST_INVALID` 之后（须先有可信的 manifest 才谈得上比对），在其余准入闸之前 |
| 0a3 | `FAIL_OUTPUT_BINDING` | 准入·绑定 | 目录归属（第 1 层）成立，但**本次运行绑定**（`seed` / `export_log_sha256`）不符。报告带 `output_binding_error: "seed_mismatch\|export_log_mismatch\|owner_marker_swapped"`（R31-F1 + R75-F1；`owner_marker_swapped` = ⑥ 已归属支重核发现第 1 层标记在 ① 之后被换掉） |
| 0b | `FAIL_CLUSTER_BOUNDARY` | 准入·环境 | 集群闸 (i)(ii)(iii) 任一不过 → 连碰这台集群的资格都没有。报告带 `cluster_boundary_error: "no_marker\|unrelated_database\|unowned_pilot_database\|maintenance_db_not_empty"`（R30-F1） |
| 0b2 | `FAIL_DB_BOUNDARY` | 信任边界·目标库 | `2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 中**本次动作适用的**库级闸（`--reset`：**闸 0−** + 归属 + 绑定 + 令牌；复用：**闸 0−** + 归属 + 绑定 + 指纹 + 结构；R49-F2 + R80-F1）不过 → 这个库**不是我能碰的、或不是我这套设置的**。报告带 `db_boundary_error` 与 `db_bound_identity`（R39-F2）。**它发生在步骤 ⑤b，即第一次状态改变之前（R48-F1 + R50-F2）**：按 R69/R70 规则，**只要目录已存在且第 1 层归属成立就写两份报告并把 `pilot_report.json` 刷成本 verdict**（R70-F1：否则陈旧的 `SUCCESS` 会继续冒充当前凭据）。归在信任边界而非 `FAIL_INFRASTRUCTURE`——「拒绝碰别人的库」是一次**正确的守卫动作**，不是环境故障 |
| 0c | `FAIL_INFRASTRUCTURE` | 中止 | 基础设施级异常（DB 断连、staging 不可读、磁盘满…）。**按 ①d 切成两段（R97-F1）**：**①d 之前**（①a/①a′/①b/①c/→ **什么都不写**、非零码 + stderr —— 此刻 `RUNNING` 尚未发布，**且 ② 还没跑过，没有任何可信的 `output_binding` 可写进报告**；**①d 之后** → 按 本文件 §4.2 收尾规则写两份报告（目录存在且第 1 层归属成立），其中 **② 通过之前那一段允许 `output_binding.export_log_sha256: null`**、② 之后必须非 null（由 `fatal_error.stage` 区分）。**陈旧 `.staging.lock` 不在此列**——它发生在 ①b（尚未证明 staging 归属、也未取输出锁），无副作用退出、不写报告。报告带 `fatal_error: {stage, exception}` 与已完成部分的统计。**必须原子写出两份**——否则 `pilot_report.json` 会停留在上一次的结论上（R31-F3 + R69） |
| 0b3 | `FAIL_REUSE_OVERFULL` | 准入·复用 | 复用库**既有活跃行数 > `target`**（步骤 ⑤b′）→ 这个库由一次**门槛更大**的运行建立，本次无论如何消费都不可能落在 `target` 上。报告带 `reuse_overfull: {expected, actual_total}`（P3r3-F11）。**独立于 `FAIL_TARGET_MISMATCH`**：后者要求三字段且仅在准备判 SUCCESS 的路径上检查，准入期根本没有 `actual_distinct` |
| 1 | `FAIL_SOURCE_BOUNDARY` | 信任边界 | 输入本身不可信，后续一切结论无意义 |
| 2 | `FAIL_SOURCE_VERIFICATION` | 信任边界 | 同上；且「查了不合格」必须可见 |
| 3 | `FAIL_SET_CARDINALITY` | **不变量** | 重复行/超池行是**下游可见的坏库存**（B3 会当独立库存发出去），比「配额没凑够」危险得多 |
| 4 | `FAIL_STALE_GENERATION` | **不变量** | 库里留着旧代次的已登记产物 |
| 5 | `FAIL_ARTIFACT_INVALID` | **不变量** | 登记的产物本身坏了。**第二个产生源 = 顶层 `output_path_diverged` 非 null**（O3-F6 + P3-F7：`--output` 在 fd 钉死之后被换掉；若无更高优先级失败则取本 verdict）|
| 6 | `FAIL_FLOOR_UNREACHABLE` / `FAIL_POOL_EXHAUSTED` | 诊断性短缺 | 「没凑够」——**只有在上面全部干净时**，它才是操作者该关注的那件事 |
| 7 | `FAIL_TARGET_MISMATCH` | 完整性 | 仅在**本已准备判 SUCCESS** 的路径上检查（R24-F1） |
| 8 | `SUCCESS_NON_SHIPPING` | 成功但不够格出货 | 用了**非默认** `--target`/`--floors`（**rc=3**、`ship_eligible: false`、带 `threshold_override`）。让 L2 跑同一套判定逻辑，同时使非默认门槛**结构上不可能**冒充出货证据（R31-F2 + R32-F1）。**必须排在 `SUCCESS_UNVERIFIED_SOURCE` 之前**（R37-F2，理由见下） |
| 8b | `SUCCESS_UNVERIFIED_SOURCE` | 成功但不够格出货 | 门槛为默认，但 `source_verification == partial` |
| 9 | `SUCCESS` | — | **rc=0 且 `ship_eligible: true`**：计数/地板/产物/源校验全过且门槛为默认。**本 plan 中它只是「最干净的诊断结论」，不构成出货凭据**（§0 + §7）|

> **两个「成功但不够格」并存时，谁先命中（R37-F2 修正）**：优先级表是**首个命中即终**的，而原表把 `SUCCESS_UNVERIFIED_SOURCE` 排在前面 —— 于是一次「非默认门槛 + 没传 `--source`」的运行（这正是 L2 脚本的常态）先命中它，得到 rc=2；而 本文件 §4.4 白纸黑字写着非默认门槛**只能**是 `SUCCESS_NON_SHIPPING`（rc=3）。**spec 自己和自己打架，实现与测试照哪边写都能自称正确**。互换次序即消解：非默认门槛是比「源没校验」**更强**的不可出货信号 —— 后者说「数据来源存疑」，前者说**连及格线都不是出货那条线**。
>
> verdict 只承载**最强的那一个**不可出货信号，但另一件事不许因此消失：`threshold_override` 与 `source_verification` **始终各自如实写出**，与 verdict 命中了哪一个无关（同 R26-F1：让报告的字段负责陈述事实，verdict 只负责给出唯一结论）。

> **为什么不变量必须压过短缺（R28-F2 修正）**：原文一处写「消费循环判定的 FLOOR/POOL **以它为准**」，另一处写「危险形状**无条件、先于其他 verdict**」——**两句直接打架**。照前者实现，一条重复的活跃行会被**藏在 `FAIL_POOL_EXHAUSTED` 后面**：操作者盯着「配额不够、去补拉」，而 B3 可见的重复库存无人处理。**「没凑够」是可以下次再补的短缺；「库里有坏行」是已经在影响下游的事实**——后者必须先说。

**各 verdict 的判据**：

- `SUCCESS`（rc=0）：distinct 成功股 = 100 **且** SH ≥ 30 **且** SZ ≥ 40 **且** BJ ≥ 8 **且产物校验全过 且 `source_verification ∈ {snapshot, full}`**。
- `SUCCESS_NON_SHIPPING`（**rc=3**，R31-F2 + R32-F1）：按**传入的** `--target` / `--floors` 其余全过，但门槛非默认（`target != 100` 或 `floors != {SH: 30, SZ: 40, BJ: 8}`）。报告带 `threshold_override`；`source_verification` 照常如实写出，**不因本 verdict 命中而省略**（R37-F2）。
- `SUCCESS_UNVERIFIED_SOURCE`（**rc=2**，R8-F3）：**门槛为默认**（否则先命中 `SUCCESS_NON_SHIPPING`，R37-F2）且其余全过，但 `source_verification` 是 `partial`（操作者用过 `--skip-existing-verify`，或 pilot 未传 `--source`）。**这是一个成功的运行，但它不满足 §7 的出货口径**——报告无法证明所有数据来自同一个源代次。
- `FAIL_FLOOR_UNREACHABLE`（rc=1）：某层池穷尽而其地板未达 → 阶段 1 提前终止。
- `FAIL_POOL_EXHAUSTED`（rc=1）：三地板均已达成，但全部三层池穷尽仍凑不满 100 只。
- `FAIL_ARTIFACT_INVALID`（rc=1）：计数上达标了，但至少一个登记产物过不了校验。报告须带 `artifact_errors: [{stock_code, file_path, error}]` 逐条说明（**字段名恒为 `error`**，R85-F2）。
- `FAIL_STALE_GENERATION`（rc=1，R14-F1）：计数上达标了，但库里**仍有活跃的 `training_sets` 行**，其 `pilot_stock_source` 哈希与当前 manifest 对不上（或该股根本不在当前 manifest 里）。报告须带 `stale_generation_rows: [{stock_code, reason}]`。
- `FAIL_SET_CARDINALITY`（rc=1，R22-F2 + R24-F1）：活跃 `training_sets` 集合出现**危险形状**——**某只股有 >1 条活跃行**，或存在**不属于本次 manifest 池**的活跃行。**无条件检查**（不因运行已失败而跳过）；次序见上方优先级表。报告须带 `cardinality_errors: [{kind: "duplicate_stock"|"row_outside_pool", stock_code?, count?}]`。
- `FAIL_TARGET_MISMATCH`（rc=1，R25-F1）：其余全部通过、**本已准备判 SUCCESS**，但持久化的活跃集合 `总行数 != target` 或 `distinct 股数 != target`。报告须带 `target_mismatch: {expected, actual_total, actual_distinct}`。
  > **为什么它必须是独立 verdict（R25-F1 修正）**：R24-F1 把「完整性不变量」从 `FAIL_SET_CARDINALITY` 的定义里摘了出去（因为它在正当的凑不够场景下被违反是**预期**的），却**没给它另立一个 verdict** —— 于是流程图仍写「不符即 `FAIL_SET_CARDINALITY`」、定义里又说这不属于该 verdict、JSON schema 还留着 `total_mismatch`/`distinct_mismatch`，**三处互相打架**。照定义实现 → 一个内存计数 bug（比如把同一股重复计入成功数）能带着 `SUCCESS` 出货；照流程图实现 → 产出一个定义说不该存在的 verdict。
  >
  > 立独立 verdict 同时保住两件事：凑不够的运行仍报 `FAIL_POOL_EXHAUSTED`/`FAIL_FLOOR_UNREACHABLE`（R24-F1 的目的），而「自认为齐了、持久化却对不上」这种**内部一致性失败**有专属的、可诊断的出口。
- `FAIL_DB_BOUNDARY`（rc=1，R39-F2）：`2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 的库级闸拒绝了本次运行。报告须带
  `db_boundary_error`（**闭合枚举的唯一权威在下方报告 schema，此处不复述**——两处各写一份是 P3r3-M13 抓到的漂移源：4a 会产出 `schema_fingerprint_mismatch`/`structure_mismatch` 而 schema 那份没有它们，按 JSON 枚举校验的消费者会拒掉一份合法报告）
  与 `db_bound_identity: {export_log_sha256_prefix, output_dir, created_at}`（该库自称的身份，供操作者判断下一步）。
  > **`confirm_token` 绝不进报告 JSON（R39-F2 自查补）**：`--reset-foreign` 的令牌之所以能承载「知情同意」，靠的是**它只出现在本次运行打印给人看的那一处**（R34-F1）。一旦写进 `pilot_report.json`，一个 wrapper 就能「读报告 → 取令牌 → 带着令牌重跑」，把知情同意退化成一次自动化的两步操作 —— 与裸布尔无异。故令牌**只写 stderr**，报告里只留可供人判断的身份，不留可供机器直接复用的凭据。
  > **为什么不能塞进 `FAIL_INFRASTRUCTURE`**：那会把一次**成功的守卫**记成一次**环境故障**。操作者看到 `fatal_error` 会去查磁盘和网络，而真正该做的是核对「这个库到底是谁的」——正是 `2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 花了四道闸要让他看见的信息。同 R21-F2：「查了、不合格」必须有自己的出口。
- `FAIL_STAGING_INTEGRITY`（rc=1，R38-F1 + R89 自查补 + R90-F1）：**两种触发，都在任何 DB 动作与任何股的导入之前**——①`staging_error.kind == "hash_mismatch"`：staged `export_log.csv` 的字节数或 sha256 与 manifest `staged_export_log` 记录不符；②`staging_error.kind == "staging_path_escape"`：**staging 树内任一 `open_under(stg_fd, …)` 调用**（manifest / `export_log.csv` / 任一股的 K 线 CSV / `.part` / `.inflight.json` / `.staging_owner.json`）**撞 `ELOOP`/`ENOTDIR`**。**②绝不得降级成逐股 skip**——路径分量被换成符号链接是**树布局本身**被动过，同目录下所有股都受影响；降级会让一棵被污染的 staging 表现为普通池缩水，甚至走到 `SUCCESS`。
  > **为什么它必须中止全局、而不是像逐股 `staging_integrity_mismatch` 那样只 skip 一只**：per-stock 那条守的是**一只股自己的两个 CSV**，其余股不受影响，跳过它继续是正确的；而 `export_log.csv` 是**所有股共用的元数据基准**（`build_stock_import` 门2 拿它的 `rows` 与首尾时间戳卡每一只）。它一旦漂移，**没有任何一只股的判定还是可信的** —— 继续跑只会产出一份看起来正常、实则每条结论都建立在错误基准上的报告。**守卫的作用域必须等于被守护对象的作用域**（同 R37-F1：粒度对不上就是漏洞）。
- `FAIL_SOURCE_VERIFICATION`（rc=1，R21-F2）：pilot 跑了出货级源校验，而**三方相等断言失败**（`sha(源)`/`sha(staging)`/`manifest` 三者中任意两个不等），或两趟之间不一致。报告须带 `source_errors: [{relative_path, expected_manifest, actual_source, actual_staging}]`。

> **`FAIL_SOURCE_VERIFICATION` 的优先级高于 `SUCCESS_UNVERIFIED_SOURCE`（R21-F2 修正）**：原枚举只有地板/池/产物/陈旧代次四种失败态，**没有给「校验跑了但没通过」留位置**。实现被迫二选一：要么把它塞进 `SUCCESS_UNVERIFIED_SOURCE`（**那正是把「发现源不符」伪装成「没检查」**——我在 R8-F2 明令禁止过的同一件事，却忘了在 pilot 侧应用），要么直接中止（丢掉本 spec 承诺的诊断报告）。两条都在隐瞒一次**真实的信任边界失败**。故必须有独立 verdict + 结构化 `source_errors`，且**排在 `SUCCESS_UNVERIFIED_SOURCE` 之前判定**：「查了、不合格」与「没查」是完全不同的两件事，报告必须能区分。

> **为什么 `source_verification` 必须进 SUCCESS 判据（R5-F2 修正）**：原判据只看计数、地板、产物三项，于是一份报告可以一边写着 `verdict: "SUCCESS"`、一边在 `source_verification` 里**明白承认自己没校验过源**。而 §7 的出货口径闸写的是「除非 `verdict == "SUCCESS"` 否则禁述已出货」——这就让「已用真数据出货 100 只」这个论断，可以建立在一份自认无法保证数据同源的报告上。这与 R4-F3 是同一类错误：**让 verdict 与它所要担保的事实脱钩**。
>
> 拆出 `SUCCESS_UNVERIFIED_SOURCE` 而不是直接判 FAIL，是因为那种运行**确实成功了**（操作者主动选择跳过复校，产物也都是好的）；只是它**不够格当出货证据**。两件事分开表达，比把它们压成一个布尔值诚实。
>
> **但它的退出码必须非零（R8-F3 修正）**：原设计给了它 rc=0，理由是「运行确实成功」。这在文档层面自洽，在**自动化层面却是个陷阱**——任何 wrapper、PR 检查清单、或者「跑完看退出码」的操作习惯，都会把一次自认没验过源的运行当成功放过去，从而绕过本文档里那套更严的 verdict 语义。**退出码是最容易被机器消费、也最不容易被人细读的那个信号，它必须与出货闸对齐**：`rc == 0` ⟺ `verdict == SUCCESS` ⟺ 够格当出货证据。报告里另设 `ship_eligible` 布尔字段，下游只要断言它即可，不必去解析 verdict 字符串的枚举含义。

> **为什么顺序要紧**：`pilot_report.json` 是**持久交付物**，而进程退出码只活在当次终端里。原设计让校验发生在报告落盘之后、只翻转 rc —— 于是一份写着 `verdict: "SUCCESS"` 的 JSON 可以与损坏或外部的 zip 共存。而 §7 的诚实口径闸恰恰是「除非 `verdict == "SUCCESS"` 否则禁述已出货」——若 JSON 能在产物坏掉时仍写 SUCCESS，**这道闸就被从内部架空了**。verdict 必须是报告自身能自证的结论，不能靠一个读者看不到的 rc 去纠正。

> **`RUNNING` 是「当前状态」而非运行结论（R74-F1）**：它由「当前状态先行发布」在任何 verdict 工作之前写进 `pilot_report.json`，收尾时被最终报告覆盖。约束：必带 `ship_eligible: false` 与 `started_at`；**不进 verdict 优先级表**（它不是任何一次运行的结论）；**没有退出码**（磁盘上读到它，说明那次运行被崩溃/ENOSPC 打断，rc 由那次的真实失败给出）；**绝不写进不可变的时间戳文件**——那些只记录已经产生结论的运行。

**不静默低产、不凑数、不放宽地板。**

**`<output>/pilot_report.json`**（**错误列表的字段名约定，R85-F2 写死，不许各处自行发挥**：
`artifact_errors[].error` / `cardinality_errors[].kind` / `stale_generation_rows[].reason` /
`source_errors[].error` —— **每个列表的判别字段名固定如上**，实现与测试一律照此，
**同一个列表在不同章节出现时不得换名**）：
```jsonc
{
  "report_id": "<seed>-<UTC>",                       // R69：本份报告的身份
  "written_at": "…",                                  // R69：落盘时刻（UTC）
  "seed": "...",
  "report_schema_version": "4c.1",   // P3-F2：**与 4a 的 `pilot_meta.contract_version` 是两个东西**
      // 只随**本文件**的 verdict / 错误码 / schema 枚举变更而 bump。
      // ⚠️ 绝不能复用 `contract_version`：那是仓库级 DB 契约版本（近几个 plan 已 1.8→1.12 连跳五次），
      // 一次与 pilot 完全无关的 iOS/DB 迁移 bump 会把 pilot 报告一起作废，两者变更节奏毫不相干。
      // ⚠️ **本 plan 只写不读**：消费它的版本闸随出货凭据链一并移出（§0）。
      // 保留字段是为了让后续 plan 能识别本 plan 产出的报告；**读侧版本闸在后续 plan 定义**。
      // `KNOWN_REPORT_SCHEMA_VERSIONS` 的权威登记处**就在本节**（与 verdict 枚举同处），实现从该常量读。
  "output_binding": {"seed": "…", "export_log_sha256": "…|null"},  // R77-F2；R81-F1 重写；R97-F1 补 FAIL_INFRASTRUCTURE
      // 语义 = **本次运行自己的身份**，取自**已校验通过的 manifest**（`source_snapshot.export_log_sha256`）。
      //   · 允许 `null` 的**只有三种**（判据：**该 verdict 可能在 ② 通过之前产生**，R97-F1）：
      //     `RUNNING`（①d，manifest 还没读）、`FAIL_MANIFEST_INVALID`（② 本身没通过）、
      //     **`FAIL_INFRASTRUCTURE`**——它既可能发生在 ② 之前（如 ② 读 manifest 时 IO 异常）
      //     也可能在其后；**② 通过之后产生的 `FAIL_INFRASTRUCTURE` 必须非 null**
      //     （那时 manifest 已校验，身份是确定的），两者由 `fatal_error.stage` 可区分。
      //     ⚠️ **①d 之前的基础设施异常一律不写报告**（R97-F1，见 本文件 §4.2 收尾清单），
      //     故这里的 `FAIL_INFRASTRUCTURE`-with-null 只覆盖 ①d 之后、② 通过之前那一段。
      //   · **其余一切 verdict 必须非 null**——它们全都发生在 ② 之后（②b / ③ / ④ / ④b / ⑤ / ⑤b / ⑥ /
      //     执行阶段），那一刻 manifest 已校验通过，本次运行的身份是**确定**的。
      //   · **它不与标记比对、也不从标记抄**（R77-F1：`owner_marker_swapped` 那一档标记已不可信）。
  "marker_binding": {"seed": "…", "export_log_sha256": "…"} | null,  // R81-F1：**标记自称的身份**
      // 取自 `.pilot_output.json` 第 2 层，**仅供诊断**。读不到 / 已被换掉（`owner_marker_swapped`）
      // → `null`。**它与 `output_binding` 不等，正是 `FAIL_OUTPUT_BINDING` 这个 verdict 的定义**，
      // 不是报告损坏；把两者硬性要求相等会让该 verdict 结构上不可能被如实表达（R81-F1）。
  "verdict": "RUNNING|SUCCESS|SUCCESS_UNVERIFIED_SOURCE|SUCCESS_NON_SHIPPING|FAIL_MANIFEST_INVALID|FAIL_STAGING_INTEGRITY|FAIL_OUTPUT_BINDING|FAIL_CLUSTER_BOUNDARY|FAIL_DB_BOUNDARY|FAIL_INFRASTRUCTURE|FAIL_SOURCE_BOUNDARY|FAIL_SOURCE_VERIFICATION|FAIL_FLOOR_UNREACHABLE|FAIL_POOL_EXHAUSTED|FAIL_ARTIFACT_INVALID|FAIL_STALE_GENERATION|FAIL_SET_CARDINALITY|FAIL_REUSE_OVERFULL|FAIL_TARGET_MISMATCH",
  "manifest_error": "…",                              // R30-F1：哪一条 `2026-07-27-qmt-plan4b-fetch-design.md` §4.5 校验不过
  "staging_error": {"kind": "hash_mismatch|staging_path_escape",       // R38-F1 + R89 自查补 + R90-F1
                    "relative_path": "export_log.csv",                 // 两种 kind 都有
                    // kind == "hash_mismatch" 时另带：
                    "expected_sha256": "…", "actual_sha256": "…",
                    "expected_bytes": 0, "actual_bytes": 0,
                    // kind == "staging_path_escape" 时另带（R90-F1）：
                    "component": "1分钟K线_前复权",                     // 撞上的那一段分量
                    "errno": "ELOOP|ENOTDIR"},
      // **判别式形状**：按 `kind` 分支带各自字段；消费者先读 `kind` 再取字段，
      // 不得假设两组字段同时存在（R90-F1）。
  "output_binding_error": "seed_mismatch|export_log_mismatch|owner_marker_swapped",  // R31-F1 + R75-F1
  "cluster_boundary_error": "no_marker|unrelated_database|unowned_pilot_database|maintenance_db_not_empty|intent_not_confirmed|registry_not_written|intent_not_cleared|created_database_replaced|cluster_schema_not_canonical",  // 后 3 项 O4-R18-C2；再后 1 项 O4-R36-C1；末项 4a-2b codex R5-F1（--init-cluster-marker 递进来的 DDL 必须逐字节等于仓库那份）
  // R39-F2 + R80-F1；后 5 项由 4a 实现引入（PR 4a 收尾的机械检查①）
  // ⚠️ 原文是一条被注释截断的两行字符串，且尾部三项重复了一遍 —— 已合成单行并去重（O4 自查补）
  "db_boundary_error": "not_owned|registry_proof_missing|forged_reset_authorization|pilot_meta_ambiguous|target_db_in_use|target_db_replaced|target_db_unreadable|db_state_initializing|binding_mismatch|reset_foreign_token_required|reset_foreign_token_invalid|schema_fingerprint_mismatch|structure_mismatch|illegal_db_name|illegal_seed|seed_db_name_mismatch|confirm_token_underivable|destructive_without_reset|run_id_missing|seed_lock_not_held|intent_row_conflict|schema_transaction_conflict|schema_transaction_missing|pilot_schema_malformed|ready_not_set|fingerprint_content_mismatch|schema_declares_no_tables|schema_tables_missing|pilot_schema_invalidated|phase1_meta_tampered|pilot_tables_have_dependents|final_meta_mismatch|pilot_source_not_empty|connection_wrong_database|connection_wrong_cluster|connection_wrong_instance|business_tables_missing|schema_not_canonical|identity_scalar_invalid|business_schema_drift|business_tables_have_dependents|connection_limit_not_restored",  // 后 7 项 O4-R18-C2；再后 3 项 O4-R19-C1；后二项 O4-R21-C2 / R22-C2；末项 4a-2 R10-F1（零对象例外 DROP 前把库封成 CONNECTION LIMIT 0，拒绝路径上恢复失败 → 库对非超级用户不可连，必须让人立刻知道）
  "db_bound_identity": {"export_log_sha256_prefix": "…", "output_dir": "…",        // 该库自称的身份
                        "created_at": "…"},                     // ⚠️ confirm_token 只进 stderr，不进本文件
  "fatal_error": {"stage": "db|staging_read|disk|…", "exception": "…"},   // **报告顶层**，两字段
      // ⚠️ O3-F12：**manifest 顶层那个同名字段是四字段** `{kind, relative_path, component, errno}`
      // （见 `2026-07-27-qmt-plan4b-fetch-design.md` §4.5）。两者语义与形状都不同；
      // §6 回归钉里「断言顶层 `fetch_fatal_error` 恰有四字段」说的是 **manifest 的**那一个。
      // ⚠️ **改名由 4b 定名（它是 manifest 的唯一权威），本文件只引用、不宣布**（O4-F9）：
      // 上一轮此处单方面写「manifest 那个改叫 `fetch_fatal_error`」，而 4b 写侧/读侧/§5/§9 四处仍是
      // `fatal_error` → 照本文件实现则 4b 读侧缺字段 → **一次源树逃逸被报成「manifest 畸形」**（R94-F2 原样跨文件复发）。
      // **4b 已定名为 `fetch_fatal_error`**（4b §4.5 写侧/读侧/§5/§9 四处已改齐）；本文件的 `fatal_error` 专指**报告顶层**（两字段）。  // R31-F3：第一次状态改变之后的基础设施中止
  "threshold_override"   // **恒存在**（P3-F10）：默认门槛时**逐项等于默认值**，不得省略。
      // 此前三处互斥：§4.3 散文说 SUCCESS_NON_SHIPPING「报告带」它（暗示默认时不带）、
      // `threshold_is_default` 说「缺失或逐项等于默认」（明确可缺）、schema 画成恒存在。
      // 恒存在使「本次实际门槛」有唯一读法：**报告消费者不必猜「缺失是不是等于默认」**。
      // 规则本身与凭据链无关，故随本 plan 保留（原先它另外服务于已移出的凭据谓词）。
  "_threshold_note": {"target": 100, "floors": {"SH": 30, "SZ": 40, "BJ": 8}},  // R31-F2：非默认即不可出货
  "cardinality_errors": [{"kind": "duplicate_stock|row_outside_pool",  // R22-F2：仅危险形状
                          "stock_code": "…", "count": 0}],
  "reuse_overfull": {"expected": 100, "actual_total": 0},              // P3r3-F11：⑤b′ 复用库既有活跃行 > target
  "target_mismatch": {"expected": 100, "actual_total": 0,              // R25-F1：SUCCESS 候选完整性
                      "actual_distinct": 0},
  "source_boundary_error": "not_readonly|overlaps_staging|overlaps_output|export_log_mismatch|mount_identity_mismatch|source_root_mismatch|source_path_escape",   // R82-F1
  "source_errors": [{"error": "source_staging_mismatch|manifest_mismatch"   // R21-F2 + R86-F2
                              "|passes_disagree|source_path_escape|unreadable",
                     "relative_path": "…", "expected_manifest": "…",
                     "actual_source": "…", "actual_staging": "…"}],
      // R86-F2：`error` 是**必填判别字段**（R85-F2 的字段名约定已把它写进契约，schema 却漏了它）。
      //   source_staging_mismatch = 源 ≠ staging；manifest_mismatch = 源 == staging 但 ≠ manifest
      //     （**双双换代**那一档，正是 R20-F1 引入三方相等要抓的）；passes_disagree = `full` 两趟不一致；
      //   source_path_escape = 源树内逐段无跟随撞 ELOOP/ENOTDIR（R82-F1 + R84-F1）；unreadable = 读不到。
      //   **三档必须可区分**：它们分别对应「源被改了」「源和 staging 一起换代了」「源正在变」。
  "artifact_errors": [{"stock_code": "…", "file_path": "/abs/…",
                       "error": "not_under_output|missing|unreadable|crc32_mismatch"}],   // **不含** output_path_diverged（P3r3-F10）
                                          // O3-F6：`output_path_diverged` 已提出为顶层字段（见下）
  "output_path_diverged": {"canonical_path": "…", "pinned_dev_ino": [0,0],   // O3-F6
                           "current_dev_ino": [0,0],
                           "detected_at_stage": "pre_first_change|pre_register|pre_report"} | null,
      // **P3-F7 写死：`output_path_diverged` 非 null ⟹ verdict 必为 `FAIL_ARTIFACT_INVALID`**
      // **删掉「它不改变 verdict」这句歧义表述**——它与 §4.3「分叉 → verdict 必为 FAIL_ARTIFACT_INVALID」
      // 在同一节里正面打架，且照它实现会写出 `verdict: "SUCCESS"` + 非 null 的 `output_path_diverged`：
      // 报告落在原 inode，而按路径去读的人打开的是**换上来的那个目录**；
      // 若它恰是同一份产物的拷贝（备份 / rsync 目标，很常见）→ 标记与报告都在、crc32 全过 → **rc=0**，
      // 而 `training_sets.file_path` 登记的路径现在指向另一个目录的内容（R59-F3「用别人的产物背书」）。
      // **非 null ⟹ verdict 必为 `FAIL_ARTIFACT_INVALID`**（若无更高优先级失败）；另作附加事实 + stderr 醒目告警。理由（O3-F6）：①在 `artifact_errors[]` 里时与优先级表冲突——
      // 一次已在 ④b 判 `FAIL_SOURCE_VERIFICATION`（优先级 2）的运行若也分叉，照「verdict 必为
      // FAIL_ARTIFACT_INVALID」（优先级 5）就**把真实的信任边界失败改写成产物失败**（R81-F1 禁的「盖掉真实原因」），
      // 照优先级表则**这个信号整个消失**；②第一个检查点在「第一次状态改变之前」，**一条 training_sets 都还没登记**
      // ——`{stock_code, file_path, error}` 这个形状**装不下它**。与 R61-F1 是同一类结构性不可表达。
                                          // R85-F2 补 output_path_diverged；字段名恒为 `error`（不是 `kind`）
  "stale_generation_rows": [{"stock_code": "…",                 // R14-F1：活跃行但源代次对不上
                             "reason": "source_hash_mismatch|absent_from_manifest"}],
  "terminated_early": true,              // 提前终止时为 true
  "termination_note": "BJ 层池穷尽（消费 120/120），地板 8 未达（实得 5）；SH/SZ 层剩余候选未继续消费",
  "ship_eligible": false,                           // ⟺ verdict == SUCCESS ⟺ rc == 0。**诊断字段**：
      // 本 plan 不定义出货凭据，它只表示「本次运行门槛为默认且全过」，**不得单独作为出货依据**（§0 + §7）
  "source_verification": "snapshot|full|partial",   // 见 `2026-07-27-qmt-plan4b-fetch-design.md` §4.4 三级定义与各自的局限
  "source_verification_caveat": "…",                // full 级时原样带出「两趟一致≠证明不可变」的声明
  "pilot_source_verification": {                    // R17-F2：pilot 亲自读源的记录
    "ran": true, "level": "snapshot|full",
    "passes": [{"pass": 1, "files_verified": 812, "aggregate_sha256": "…", "completed_at": "…"}],
    "passes_agree": true,
    "source_abspath": "/Volumes/QMT_Export-1/front_ratio_cn_stocks_ab_bj"   // R25-F2：只留痕，不参与判定
  },
  "fetch_failures": {"total": n,                    // R3-F2：池缩水的真实原因
    "by_reason": {"fetch_missing_file": n, "fetch_copy_hash_mismatch": n,
                  "untracked_target_file": n, "fetch_interrupted_rollback": n}},  // R37-F1：全集四种
  "pool_sizes": {"SH": n, "SZ": n, "BJ": n},        // manifest pool_order 各层长度（成功拷进 staging 的）
  "universe_sizes": {"SH": n, "SZ": n, "BJ": n},    // 冻结宇宙各层总数（还能补拉多少的依据）
  "consumed": {"SH": n, "SZ": n, "BJ": n},          // 实际尝试过的只数
  "succeeded": {"total": n, "SH": n, "SZ": n, "BJ": n},
  "already_done": {"total": n},                     // 断点续跑命中的
  "floors": {"SH": {"required": 30, "actual": n, "met": true}, "SZ": {...}, "BJ": {...}},
  "sets": [{"stock_code": "...", "market": "SH", "start_datetime": 0,
            "zip_path": "/abs/...", "content_hash": "abcd1234",
            "source_sha_1m": "…", "source_sha_daily": "…",   // R43-F1：这一只股出货时的源字节身份
                                                             //   供人核对该 zip 出自哪一代源字节
            "dense_start": "YYYY-MM-DD", "dense_end": "YYYY-MM-DD",
            "dense_day_count": 0}],
  "skips": [{"stock_code": "...", "market": "SZ",
             "stage": "staging|import|generate|resume|regenerate",   // R45-F3：`staging` 是
                       //   `staging_integrity_mismatch` 的归属阶段，原枚举漏了它
             "reason": "no_eligible_training_window"}],
  "preserved_superseded": [{"stock_code": "…", "relative_path": "…", "content_hash": "…"}],  // O3-F7
      // §4.2 要求写、§6 要求断言，schema 里**一直没有它** → `schema_valid()` 严格实现时
      // **一份内容完全正确的 SUCCESS 报告会被报告形状校验判为非法**（诊断信息就此丢失）
  "inflight_rollbacks": {"total": 0, "by_universe_idx": {}},   // O2-F11：4b 强制要求，本文件此前 0 次提及
  "fetch_stopped_reason": "max_bytes|source_path_escape|staging_path_escape|staging_recheck_failed|null",  // O2-F11 + O4-F3
  "fetch_fatal_error_kind": "source_path_escape|staging_path_escape|null",   // O4-F1：**fail-closed 的真正判据**（非 null ⟹ 无条件 fail-closed）
  "skip_reason_counts": {"no_eligible_training_window": 0, "date_set_mismatch": 0,
                         "stale_artifact_missing": 0, "duplicate_active_rows": 0,   // O3-F7 补齐
                         "stale_training_set": 0, "foreign_output_path": 0,
                         "source_generation_changed": 0, "staging_integrity_mismatch": 0}
}
```

`terminated_early` / `termination_note` 是**诚实义务字段**：提前终止时未消费的层没有被验证过，报告不得让读者误读为「其余层也不行」。

`fetch_failures` / `universe_sizes` / `source_verification` 同属诚实义务字段（R3-F2 / R3-F3）：一个 `FAIL_POOL_EXHAUSTED` 究竟是「市场上真的没有更多合格股」还是「拷贝失败让池缩水了」或「冻结宇宙还剩几百只没拉」，读者必须能从报告本身分辨，而不需要去翻 manifest。

`reason` 直接用既有结构化短语，无需自造分类：
`stale_artifact_missing` / `duplicate_active_rows` （**O3-F7 补齐**）/ `export_log_not_ok` / `no_dense_1m` / `daily_not_cover_dense` / `date_set_mismatch` / `ohlcv_mismatch` / `source_identity_mismatch` / `export_log_mismatch` / `clean_dropped_rows_1m` / `daily_clean_dropped_rows` / `no_intraday_after_dense_filter` / `empty_period` / `no_eligible_training_window`。

同时向 stdout 打人读摘要（成功数、三市场分布与地板达成、skip 原因 top-K）。

**`file_path` 绝对可读验证**：**在定 verdict 之前**（R4-F3），逐条检查登记的 `file_path`——① **两条同时成立**（R2-F1 + R61-F2）：**①a 字面判据** `os.path.normpath(file_path)` 的父目录**逐字等于** canonical `output_dir`（**绝不 `resolve()`**——它会跟随符号链接）；**①b 身份判据** 该父目录的 `(st_dev, st_ino)` 等于钉住的 `out_fd`② 打开读取 zip 首字节（模拟 B3 按路径下载）③ crc32 与 `content_hash` 相符。任一不满足 → 该条进 `artifact_errors`，verdict 定为 `FAIL_ARTIFACT_INVALID`，rc=1。

> **为什么必须字面判据与身份判据并用（R61-F2 修正）**：`Path(file_path).resolve().parent == output_dir.resolve()` 这条判据**会跟随符号链接** —— `/tmp/alias/600000.SH_123.zip`（其中 `/tmp/alias` 指向 `<output>`）解析后父目录正好等于 output，**判定通过**。可**登记进 `training_sets.file_path` 的仍是那串带别名的字符串**，而 B3 就是拿这串字符串去开文件的：别名一旦被删掉或改指，下游要么 404、要么读到**别人的字节**。
> - **字面判据**挡住「登记的字符串本身不在 canonical output 下」（含 `..` —— `normpath` 会折叠它）；
> - **身份判据**挡住「字符串看着 canonical、但那个目录现在已经不是我们钉住的那个」。
>
> 两条各挡一半，缺一不可。**并且从源头堵死**：登记时**只写 canonical 路径**（`<canonical_output>/{code}_{start}.zip`），别名根本不该进 DB。**注意 R60-F1 把这条判据改成纯 `same_inode` 之后，别名反而畅通无阻** —— 身份判据对别名是「通过」的，因为它解析后确实是同一个 inode。**把「按名字」换成「按身份」时，原来那条按名字的检查不一定能删。**

**本项校验必须按「字符串路径」打开，绝不走钉住的目录 fd（R59-F3）**：它模拟的正是 **B3 的视角**——B3 拿到的是 `training_sets.file_path` 这个字符串，它不知道也拿不到我们的 fd。**fd 用于「写」（保证写在授权对象上），路径用于「验证消费者真能读到」——两者角色相反，不可互换。**

**并额外断言路径与 inode 未分叉（R59-F3；检查点前移并加密，R68-F1）**：`os.stat(--output)` 的 `(st_dev, st_ino)` 必须等于 `os.fstat(pinned_fd)` 的。**这条检查不能只在产物校验时做一次**，而要放在**三个点**上：
- **第一次状态改变之前**（**首次使用支的实际位置是「⑥ 认领成功之后、建/复用库之前」**，P3-F4：
  该支在检查点 1 的原锚点处连 `--output` 都还不存在，两边都没有对象、分支不可执行；
  而挪到 ⑥ 之后时 `RUNNING` **已经发布了**，故原文括号里那句「尚未发布」是假的——
  这正是 §9-2s 判据的**第四个反例**，也是 O3-F3 自称在修的那一个）（O3-F3 更正：**「此时尚未改动任何状态」对已归属支是假的**——①d 早已发布 `RUNNING`，
  而 ①d 被 R96-F1 显式挖出「第一次状态改变」的定义、就发生在这条线**之前**）。**切分判据不是「哪一支」，而是「本进程有没有发布过 `RUNNING`」（P3-F4 更正）**——
  一个进程内布尔量 `running_published`，两支共用。
  **⚠️ 在三处分叉检查点上它恒为 True**（已归属支 ①d 发、首次使用支 ⑥ 内发），
  故那里只保留**显式的内部不变量检查**（**不得用 `assert`** —— `python -O` 会整条剥离，
  O4-F14：剥离后同一路径直接落进「已发布 → 必须写终局报告」，而首次使用支此刻 `out_fd` 可能还不存在 → 崩在写报告里）：
  ```python
  if not running_published:            # 内部不变量被违反，不是可达的业务分支
      raise InternalInvariantViolated(...)   # → 非零码 + stderr 说清楚，**不写报告**
  ```
  **不要写成一个看起来可达的 if/else 分支**（P3r3-F7：那会让实施者以为「首次使用支确实有不写的情形」，
  从而倒推回旧写法）。**检查点 1 的位置锚点是「①d / ⑥ 发布 `RUNNING` 之后、建或复用库之前」**
  （O4-F14：原锚点「第一次状态改变之前」按 R96-F1 的定义**不含** ①d，在 ①a…⑥ 之间任何位置都成立，
  实施者把它放在 ①a 紧后是很自然的读法 → 一次真实的路径分叉只留下一条裸 traceback）。
  **未发布**（仅可能出现在 ①a–①c 的中止）→ 拒绝启动、什么都不写；
  **已发布** → **必须写终局报告**（`FAIL_ARTIFACT_INVALID` + 顶层 `output_path_diverged`，见 O3-F6），
  经 ①a 钉住的 `out_fd` 写。否则 `pilot_report.json` **永久停在 `RUNNING`**，
  正是 §9-2s 判据「①d 之后的每一条出口都必须写终局报告」的**第三个反例**——
  而它躲过前两次修复，是因为**这条出口从来没进过 §4.2 的收尾清单**（与 R89-F1 抓到的「清单自称唯一权威却漏了
  ①a′ 与 ；
- **每一条 `training_sets` 登记之前**（分叉 → 立即中止，绝不再产生「写在旧 inode、却登记成新路径」的行）；
- **最终报告落盘之前**（分叉 → 报告仍写进钉住的 inode，但 verdict 必为 `FAIL_ARTIFACT_INVALID` + `output_path_diverged`，且 stderr 用醒目措辞告知**该报告不在 `--output` 现在解析到的那个目录里**）。不等 → 说明 `--output` 这个路径在 ⑥ 之后**被改指到了别的目录**，于是「我们写进去的那个 inode」与「登记进 `training_sets.file_path` 的那串路径」**指向两个不同的地方**；该条进 `artifact_errors`（**`error: "output_path_diverged"`**——字段名恒为 `error`，R85-F2 统一：此处原写 `kind`，与 schema 及其余各处不一致），verdict 为 `FAIL_ARTIFACT_INVALID`。

> **为什么必须显式断言，而不能指望前两项顺带发现（R59-F3 修正）**：R57-F1 把写入钉在 inode 上之后，出现了一个**新的**失败形态——**产物与报告都写成功了、内容也全对，但它们所在的路径已经不是 `--output` 现在解析到的那个地方**。B3 按 `file_path` 打开会 404，而运行本身「一切正常」。① ② 两项**在多数情形下会顺带失败**（新目录里没有那些 zip），但这是**巧合而非保证**：若被换上去的目录恰好也含同名 zip，检查反而会「通过」，我们就用**别人的产物**给自己背书。**「写在哪」与「登记成什么路径」必须被显式绑定，不能靠副作用去发现分叉。**
> **不为它新增 verdict**：它的可观察后果就是「登记的产物在登记路径上读不到」，与 `FAIL_ARTIFACT_INVALID` 的语义完全一致；新增一个只在极窄条件下可达的枚举，反而制造死枚举（R39-F2 / R43-F1 的教训）。
>
> **一条必须写明的残余局限（R68-F1）**：若 `--output` 在**运行中途**才被外部替换，本次的诊断报告只会存在于**原 inode**里；而操作者 / B3 / 自动化按 `<output>/pilot_report.json` 这个**路径**去读，读到的是替换上来的那个目录里的内容——**那个目录不归本工具所有，我们既无权写它、也无从保证它的内容**。把报告写进它才是真正的越界（R8-F1 / R66-F2 的边界）。因此本工具能做的只有三件：**尽早发现（上面三个检查点）、立刻中止、并在 stderr 里说清楚报告落在哪里**。**这条残余风险须写进 §8，不得用「已妥善处理」一笔带过。**


### 4.4 CLI 接口

```
python qmt_fetch.py
    --source     <已挂载的只读路径>            必填
    --dest       <staging 绝对路径>            必填（必须绝对）
    --seed       <^[a-z0-9_]{1,32}$>          必填（与已存在 manifest 的 seed 必须一致）
    --quota      SH=120,SZ=160,BJ=120         可选，默认如左；补拉时提高它即可
    --max-bytes  <字节数>                     可选，默认 3 GiB
    --skip-existing-verify                    可选；跳过对既有文件的源哈希复校，
                                              但会把 source_verification 标成 partial
                                              并在报告里显式声明（R3-F3）
    --snapshot-gmt-token @GMT-YYYY.MM.DD-HH.MM.SS
                                              可选；声明源是经 VSS 快照挂载的。会与
                                              --source 挂载点的实际挂载信息核对，不符
                                              即拒绝启动（防手填假 token）。核对通过
                                              → source_verification 可达 snapshot 级
    --confirm-no-export-window                可选；操作者显式声明本次窗口内未运行 QMT
                                              导出任务，记入 manifest.operator_attestation。
                                              **无快照时，缺此声明则最高只能到 partial**
                                              （即不够格出货）——见 `2026-07-27-qmt-plan4b-fetch-design.md` §4.4 三级定义（R10-F3）
    # 无 --skip-first：补拉由「读 manifest、每层各自从 cursor[market] 续」自动完成
    # （R1-F1 + R3-F2）。全局偏移量与按层不等配额语义上不可调和；而游标必须独立于
    # 成功列表 pool_order，否则拷贝失败会让它错位。

python qmt_pilot.py --init-cluster-marker --maintenance-dsn <DSN>
    # 一次性：在该集群维护库里写 pilot_cluster_marker（R15-F1）。写之前跑闸 (ii)+(iii)，
    # 判据与 `2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 完全一致（此处不重述规则，只列适用范围）：
    #   (ii) 枚举每一个非系统库：名字不匹配 kline_pilot_* 即拒；**匹配的也要逐个连进去
    #        验 pilot_meta.tool == 'qmt_pilot'**，缺表/缺键/值不符即拒（R22-F1）
    #   (iii) 维护库自身除该标记外无任何用户表/视图/序列/自定义 schema（R20-F2）
    # 任一不满足即拒绝初始化。


python qmt_pilot.py
    --maintenance-dsn <指向 postgres 维护库的 DSN>   必填（用于 CREATE/DROP DATABASE）
                                                     **须已初始化 pilot_cluster_marker**，
                                                     否则在任何 DDL/导入之前即拒绝（R15-F1）
    --seed            <^[a-z0-9_]{1,32}$>            必填（库名恒为 kline_pilot_<seed>）
    --staging         <staging 绝对路径>             必填
    --output          <zip 输出绝对路径>             必填（必须绝对，沿用 B2 CLI 的守卫理由）
    --confirm-no-export-window                       pilot 侧的同名声明；`full` 级出货必需（R21-F1）
    --snapshot-gmt-token @GMT-…                      pilot 侧的快照 token；`snapshot` 级出货必需，
                                                     且与源边界闸第 4 条的挂载 token 比对一致
    --source          <已挂载的只读路径>             可选；传了则 pilot **亲自读源**跑出货级
                                                     源校验（R17-F2）。**不传则本次运行一律
                                                     记 partial、不够格出货**，无论 manifest
                                                     里写的是什么——离线重跑照常可用，只是
                                                     不能充当出货证据
    --reset                                          可选；缺省时已存在的库按 P4-D7 复用
    --reset-foreign=<令牌>                           可选；仅在 --reset 遇到「归属通过但绑定
                                                     不符」时需要，且必须在看过打印出的所绑
                                                     身份后显式加（R7-F1）
    # 退出码（R8-F3）：0 仅当 verdict == SUCCESS（＝够格当出货证据）；
    # SUCCESS_UNVERIFIED_SOURCE = 2；SUCCESS_NON_SHIPPING = 3；其余 FAIL_* = 1。
    # 报告另有 ship_eligible 布尔字段；rc==0 与 ship_eligible 恒等价（R32-F1）。
    --target          100                            可选，默认 100
    --floors          SH=30,SZ=40,BJ=8               可选，默认如左
```

- `--seed` 在两个命令间必须一致：fetch 用它定储备池顺序并写进 manifest，pilot 用它派生库名；储备池顺序 pilot 只从 manifest 读、不重推（见 P4-D8）。
- `--dest` / `--output` 强制绝对路径。相对 `--output` 会让 `_register_training_set` 存下相对 `file_path`，B3 按 web 进程自己的 cwd 解析 → 训练组已在库却下载 404（`generate_training_sets._amain` 已有同款守卫，此处沿用同一理由）。
- `--target` / `--floors` 可调是为了让 L2 脚本用小数字跑通**同一套 verdict 逻辑**。**非默认门槛结构上不可能产出出货证据（R31-F2）**：只要 `target != 100` 或 `floors != {SH:30, SZ:40, BJ:8}`，即便其余全过，verdict 也只能是 **`SUCCESS_NON_SHIPPING`**（**rc=3**、`ship_eligible: false`），报告另记 `threshold_override: {target, floors}`。**「只能」要成立，它就必须在优先级表里排在 `SUCCESS_UNVERIFIED_SOURCE` 之前**（R37-F2）——L2 脚本通常也不传 `--source`，按原次序会先命中后者、拿到 rc=2，本句就成了假陈述。

  > **为什么不能只靠「说明它只给 L2 用」（R31-F2 修正）**：`ship_eligible ≡ (verdict == SUCCESS)`，而 SUCCESS 的判据用的是**传进来的** target/floors —— 于是真跑时把门槛调低，照样产出 `ship_eligible: true` 的报告。反过来若实现为了防这点而在 SUCCESS 判定里无视这两个参数，L2 就**跑不通同一套 verdict 逻辑**（小数字永远达不到 100，只能测到失败路径）。两难的根源是「100/30/40/8 这个出货契约当前只由散文约定守着」。
  >
  > 拆出 `SUCCESS_NON_SHIPPING` 同时解决两头：L2 仍走**完全相同**的判定代码路径（只是门槛小），而**任何非默认门槛的运行都不可能冒充出货证据**。这是「让正确性由结构保证，而不是由操作者纪律保证」的又一次应用（同 R26-F1 派生式定义）。
  >
  > **它的退出码必须非零（rc=3，R32-F1 修正）**：初版给了它 rc=0，理由是「运行确实成功」——**这正是 R8-F3 已经判过一次的同一个陷阱，我又造了一个新实例**。`rc == 0` ⟺ `verdict == SUCCESS` ⟺ 够格出货 这条不变量是给**机器**看的；任何 wrapper / PR 检查清单 / 「跑完看退出码」的习惯，都会把一次 rc=0 的非默认门槛运行当成功放过去。**每新增一个 verdict，都必须回到这条不变量前问一次「它该是 0 还是非 0」**。

---
---

## 5. 错误处理（§4 的导出视图）

| 情形 | 处置 |
|---|---|
| 复用库的既有活跃 `training_sets` 行数 **> `target`**（⑤b′，只读前置断言，**排在 ⑤b 之后、只在复用分支跑**） | **`FAIL_REUSE_OVERFULL` + `reuse_overfull: {expected, actual_total}`**（P3r3-F11 独立 verdict），说明「本库由更大门槛的运行建立，请换 seed 或 `--reset`」。**在动第一根手指之前**给可行动结论——否则阶段 1 补完地板后行数恒 > target、阶段 2 一次不执行、每次重跑判定完全相同，**唯一出路是 `--reset` 丢光全部进度**，而那正是允许复用的唯一理由（同 R1-F3 的死锁） |
| 报告的 `output_binding` 与 `marker_binding` 不相等 | **这正是 `FAIL_OUTPUT_BINDING` 的定义，不是报告损坏**（R81-F1）：`output_binding` = 本次运行自己的身份（取自已校验 manifest），`marker_binding` = 标记自称的身份（**仅供诊断**，读不到/已换记 `null`）。**两者硬性要求相等会让该 verdict 结构上无法被如实表达** |
| **出货凭据链相关的一切**（`--verify-shipment` / 谓词 / ①e / crc32 自证 / `--repair-artifacts`） | **已整块移出本 plan**（见 §4.2 顶部说明）。本文件的报告是**诊断产物**，不是出货凭据 |
| 场景 | 行为 |
| 源挂载非只读（`statvfs` 的 `ST_RDONLY` 未置位） | **拒绝启动**，提示以 `-o rdonly` 重新挂载。**用非写入式检测，绝不试写源**（R4-F4 + R5-F3） |
| 无快照且缺 `--confirm-no-export-window` | 最高只能定级到 `partial`（不够格出货）——凭据缺失不得默认成立（R10-F3） |
| 活跃总数 / distinct 数 ≠ `target`，**而本次运行本就因池穷尽或地板不可达而失败** | **保持 `FAIL_POOL_EXHAUSTED` / `FAIL_FLOOR_UNREACHABLE`**，**不得转成 `FAIL_SET_CARDINALITY`**（R24-F1：凑不够时集合必然小于 target，这是预期而非异常；转码会盖掉「哪一层穷尽、去补拉」这个唯一可行动的结论） |
| `qmt_pilot` 未传 `--source` | `source_verification` 强制记 `partial`、`ship_eligible: false`；门槛为默认时 verdict=`SUCCESS_UNVERIFIED_SOURCE`/rc=2，**门槛非默认时先命中 `SUCCESS_NON_SHIPPING`/rc=3**（R37-F2），**无视 manifest 的自述**（R17-F2：manifest 里关于「我校验过源」的记载是 fetch 的自述，证不了那两趟读真发生过） |
| 首次使用 `os.mkdir` 撞 `EEXIST` 且目录**没有合法归属标记**（空的也算） | **拒绝启动**（R8-F1 + R66-F2），stderr 提示：若确认是本工具上次崩在 `mkdir` 与写标记之间留下的空目录，请手工 `rmdir` 后重跑。**不做自动认领**——`mkdir` 之后的目录不携带出处信息，崩溃抹掉了内存里那份「是我建的」；意图记录只能证明「我打算建」（R65-F2 的方案已撤回） |
| `--output` 非空且无相符的 `.pilot_output.json` 标记 | **拒绝启动**——**无论里面的文件长什么样**（R8-F1：`{code}_{digits}.zip` 正是全仓训练组共用的命名空间，靠形状判断会让 `ZipFile(...,"w")` 截断别人的 zip）。归属只认标记文件 |
| **首次使用**时 `--output` 含 `.superseded/` 或**不匹配**的 `.pilot_output.json` | **算「非空」→ 拒绝启动**（R27-F1：簿记项豁免只在归属已被证明之后才成立；无条件豁免会让豁免本身变成绕过归属闸的通道） |
| **准入阶段任一检查不过**（② manifest / ②b staged export_log / ③ 第 2 层绑定 / ④ `--source` 边界 / **④b 出货级源校验** / ⑤ 集群闸 / **⑤b 目标库四闸与 `--reset-foreign` 令牌** / **⑥ 归属声明或重核**）—— **全都在第一次状态改变之前**（＝建/复用/reset 库、写产物、写**终局**报告之前；**①d 的 `RUNNING` 已被显式挖出该定义**，R96-F1） | **在建/复用/reset 任何数据库之前**退出（R27-F2：`CREATE DATABASE` 也算持久副作用）。**只要目录已存在且第 1 层归属成立，就写两份报告**（R69「只增不毁」：写新报告是创造证据，不销毁任何东西——上一次的时间戳报告原封不动）：新的 `pilot_report-<seed>-<UTC>.json` + 刷新 `pilot_report.json`，verdict 为 ②→`FAIL_MANIFEST_INVALID` / ②b→`FAIL_STAGING_INTEGRITY` / ③→`FAIL_OUTPUT_BINDING` / ④→`FAIL_SOURCE_BOUNDARY` / ④b→`FAIL_SOURCE_VERIFICATION` / ⑤→`FAIL_CLUSTER_BOUNDARY` / ⑤b→`FAIL_DB_BOUNDARY`。**绝不能「有既有报告就不写」**——那会让一份陈旧的 `SUCCESS` 继续占据 `pilot_report.json`，而 §7 恰恰告诉消费者以它为准（R70-F1）。**首次使用**目录尚未创建 → 无处可写，直接退出（此时也不可能存在陈旧报告）。**已归属时这两份报告是在覆盖本次开跑时发布的 `RUNNING`**（R74-F1） |
| 同一 `--output` 上另一进程正持有输出 `flock`（①a 取不到） | **拒绝启动，什么都不动**（`RUNNING` 在 ①d 才发布，此刻尚未写，故上一次的两份报告逐字节未变——R75-F1），非零码 + stderr（R59-F2：`--maintenance-dsn` 不同的两个调用不共享 ①c 的按 seed 锁，**只有输出锁能拦住它们同时写同一个 `--output`**） |
| **⑥ 之后**（整个执行阶段）标记被换掉 / 目录被整体替换 / 路径分量被换成符号链接 | **写入不受影响**：⑥ 那一刻已 `O_DIRECTORY\|O_NOFOLLOW` 取得目录 fd 并全程持有，此后 zip 落地、`.superseded` 挪动与删除、owned zip `unlink`、报告写与删**一律走 `*at` 语义**，路径不再解析 → 始终写在验过的那个 inode 上（R57-F1）。**绝不能在此改用「重读标记、不符即不写」**——那会让本次运行的结论写不出来，`pilot_report.json` 停在上一次的结论上 |
| ⑥ **已归属支**重核发现 `.pilot_output.json` 在 ① 之后被换掉（两层任一不符） | **写终局报告**：`FAIL_OUTPUT_BINDING` + `output_binding_error: "owner_marker_swapped"`、rc=1，两份都写并覆盖 ①d 那份 `RUNNING`，**全部经 ①a 钉住的 `out_fd`，即使此刻重读标记失败或不符也照写**（R77-F1：「落笔前重核归属」只作用于 ①a 之前的写；R75-F1：①d 之后「什么都不写」已不成立；留一份 `RUNNING` 等于把「被正当拒绝」谎报成「结论未知」。依据 R57-F1：标记在别处被换掉，不能追溯性地把已验过、已钉住、一直被 flock 持有的那个 inode 变成别人的） |
| ⑥ **首次使用支** `mkdirat` 撞 `EEXIST`——**无论有没有合法标记**（R91-F2 收紧） | **拒绝启动、什么都不写**，仅非零码 + stderr（该支从未发布过 `RUNNING`——目录本就不存在）。**有合法标记时也拒绝**：那说明另一次运行在本次启动之后创建并写好了它，而**首次使用支从未跑过 ①a（钉 fd + 取 `LOCK_EX`）/ ①a′（重核）/ **——就地转复用会让一次诊断性运行绕开 。stderr 提示「请原样重跑」，重跑时它会被 ① 判为「已归属」，从而完整走一遍那三道闸 |
| `source_generation_changed` 且该行 `file_path` **不属于本次 `--output`**（`!owned`） | **只删 DB 行 + 重导入 + 重生成到本次 output**，**跳过整套 `.superseded` 协议**（R87-F2：`!owned` 时 `sup_fd` 从未创建，旧文无条件走 `.superseded` 会在收尾 `unlink(p.name, dir_fd=sup_fd)` 处崩）。**绝不 `unlink` 那个外部文件**（R2-F1）；记 `source_generation_changed` + `foreign_output_path` 两个原因 |
| **首次使用**：`mkdirat` 成功之后、`.pilot_output.json` 可见之前，另一个 pilot 在同一 `--output` 上启动 | **不可发生**：`mkdirat` 返回目录 fd 后**紧接着就取 `flock(LOCK_EX\|LOCK_NB)`，取到才写标记**（R97-F2）。**先写标记后取锁的实现**会让第二个进程把该目录判为「已归属」、抢先取到 `LOCK_EX`、发布 `RUNNING` 甚至写出终局报告，而**创建者已经改过磁盘却拿不到锁**——「同一 `--output` 的写者被串行化」这条不变量在创建那一瞬间不成立，当前报告归谁取决于竞速 |
| ⑥ 之前（① 与 ①a′ 之间）`.pilot_output.json` 被换掉 | **①a′ 经 `out_fd` 重核第 1 层即拒绝，一个字节都不写**（R78-F1：`RUNNING` 尚未发布）。**① 与 ①a′ 之间的窗口无法完全消除**（① 时还没有锁与 fd），但 ①a′ 之后的写全部落在钉住的 inode 上，且 ⑥ 会再核一次 |
| `.pilot_output.json` / `pilot_report.json` / zip 目标路径是符号链接 | **拒绝写入**（`O_NOFOLLOW`）——否则写入会跟着链接出目录，把归属判定整个绕过（R8-F1） |
| **已归属**的 `--output` 上「当前状态先行发布」（`RUNNING`）写不出去（ENOSPC / EIO 等） | **立刻中止，非零码退出**，此时尚未做任何 verdict 工作、未改动任何状态（R74-F1：作废旧结论被缩成最早时刻的一次极小写入，**它失败的后果是干净中止，而不是留下空洞**） |
| 本次运行**在写自己的失败报告时**崩溃/撞 ENOSPC | `pilot_report.json` 停在本次开跑时发布的 `RUNNING`（`ship_eligible: false`）→ 消费者读到的是「上一次运行被打断、结论未知」而**不是上一次的 `SUCCESS`**（R74-F1）。上一次的时间戳报告仍原封不动可供追溯 |
| 断点续跑遇坏产物（zip 缺失/不可读/crc32 失配，**且路径在本次 `--output` 内**） | 锁内删行 + 删残留 zip + 重生成一次；仍失败则记 skip。**不计入成功、不卡死**（R1-F3） |
| 单股导入/生成失败 | 记 skip 原因，继续下一只 |
| **①d 之前**的基础设施异常（维护 DSN 连不上、staging 不可读、输出盘写不了；含 ①d 自身写 `RUNNING` 失败） | **什么都不写**，非零码 + stderr（R97-F1）：`RUNNING` 尚未发布（或正是它写不出去），且 **② 未跑过、没有可信的 `output_binding`**。**「准入阶段的基础设施异常一律写报告」按 ①d 切开** |
| DB 断连 / staging 不可读 / 磁盘满等基础设施异常（**①d 之后**；陈旧 `.staging.lock` 不属此类，见上行） | `FAIL_INFRASTRUCTURE`（rc=1）+ `fatal_error: {stage, exception}` + 已完成部分统计，**必须原子写出两份报告**（R31-F3 + R69：`pilot_report.json` 必须反映本次运行的真实结局，否则上一次的成功会继续冒充当前状态） |


---

## 6. 测试策略

**L1** host pytest（CI 强制）→ **L2** 真 PostgreSQL `verify_pilot_e2e.py` → **L3** 真数据人工验收。
**三层不可互相替代：L1 全绿只证明纯逻辑与假件契约成立，证明不了链路已通。**

### 6.1 L1 回归钉（本 PR）

| 4c | `import_qmt_stock` 提取后 CLI 行为不变（现有测试）；编排：成功路径 / import 失败记 reason 继续 / generate 失败记 reason 继续 / `already_done` 验证通过才计入成功且不重复导入 / **坏产物恢复（R1-F3）**：造一行 zip 缺失的 `training_sets` + 一行 crc32 失配的，断言 ①不被计入成功 ②锁内删行删 zip 后重生成 ③重生成成功即计入 ④重生成失败记 `stage=regenerate` ⑤**同一场景连跑两轮，第二轮不得重现第一轮的失败**（这是「死锁状态」的回归钉）/ **外部路径不得被删也不得被计数（R2-F1）**：造三种行——`file_path` 指向 `--output` 之外的**真实可读且 crc32 相符**的 zip、指向 `--output` 之外的坏文件、指向 `--output` 内但文件名不匹配 `{code}_{digits}.zip` —— 断言三者 ①**目标文件在测试结束时仍然存在**（未被 unlink，用真实 tmp 文件验，这是不可逆删除的回归钉）②不计入 `already_done` ③记 `foreign_output_path` 并重生成到本次 output；另测 `..` 与符号链接别名两种（R61-F2，**绝不用 `resolve()`**）：`..` 按**词法** `normpath` 归一后若父目录逐字等于 canonical output **且**父目录 inode 等于钉住的 `out_fd` → 判 owned；**指向 output 内部的符号链接别名一律判 `foreign_output_path`**——不计入 `already_done`、**绝不 `unlink`**、重生成到 canonical 路径。**照旧文用 `resolve()` 的实现会把别名判成 owned 并删掉它，而 B3 随后打开的是那条可变的别名路径**（R78-F2：该测试契约是 R61-F2 之前的遗留，与 §9-2l 的权威判据直接冲突） / **阶段 1 先补地板**（构造一个「等量轮转会卡在 SZ<40」的场景，断言两阶段实现能达标——这是 P4-D8 那处自相矛盾的回归钉）/ 阶段 2 补到恰好 `target` 不超出 / 某层池穷尽且地板未达 → `FAIL_FLOOR_UNREACHABLE` 且 `terminated_early=true` + `termination_note` 指名该层 / 三层全穷尽 → `FAIL_POOL_EXHAUSTED` / 储备池顺序取自 manifest 而非重推（manifest 顺序与 seed 重推顺序**故意造得不同**，断言实际消费的是 manifest 那个）；报告 JSON 形状与 `skip_reason_counts` 聚合。**导入前 staging 复校（R4-F1）**：把某股的 staged CSV 改成**同尺寸不同内容**，断言该股记 `staging_integrity_mismatch` 且 `import_qmt_stock` **从未被调用**（不复校的实现会让它一路导入成功）。**verdict 与产物校验的顺序（R4-F3）**：构造「计数上达标、但有一条登记 zip 被删」的场景，断言 ①落盘的 `pilot_report.json` 里 `verdict == "FAIL_ARTIFACT_INVALID"`（**不是** SUCCESS）②`artifact_errors` 逐条列出 ③rc=1 —— 这是「报告写 SUCCESS 而产物已坏」的回归钉。**陈旧代次行不得与 SUCCESS 共存（R14-F1）**：构造「某股 `source_generation_changed` + `staging_integrity_mismatch` 被保留下来，其余股凑够 `target` 且三地板全达」的场景，断言 ①`verdict == "FAIL_STALE_GENERATION"`（**不是** SUCCESS）②`stale_generation_rows` 列出该股 ③**那一行与它的 zip 事后仍在**（不得为了让 verdict 好看而删掉）④rc=1 —— 只检查本轮处理过的股、不做全库扫描的实现会在①变绿。**SUCCESS 内含源已验（R5-F2）**：manifest 标 `source_verification: "partial"` 而其余全过 → 断言 verdict 是 `SUCCESS_UNVERIFIED_SOURCE` 而**不是** `SUCCESS`（只看计数/地板/产物的实现会在此变绿，从而让 §7 的出货口径闸失效）。**跨 staging 同 export_log 不同 K 线（R6-F1）**：造两份 staging，`export_log.csv` **逐字节相同**（故 `export_log_sha256` 一致、库级绑定闸放行）但某股的 K 线 CSV 是**同尺寸不同内容**；用 staging A 跑一轮出货，再用**同 seed + 同 output + staging B** 跑第二轮 —— 断言该股 ①**不被**计入 `already_done` ②记 `source_generation_changed` ③走**完整重导入**（`import_qmt_stock` 被调用，不是只调 `generate_one_training_set`）④重导后 `pilot_stock_source` 更新为 B 代哈希。只绑 `export_log_sha256` 的实现会在 ①②双双变红 —— 这是「一份 SUCCESS 报告混两个数据代次」的回归钉。**换代恢复不得先毁后建（R7-F2）**：在上述场景基础上把 staging B 的该股 CSV 弄成与 B 自己的 manifest 不符（模拟新输入损坏），断言 ①记 `staging_integrity_mismatch` ②**旧 `training_sets` 行仍在、旧 zip 文件仍在**（先删后检查的实现会在此变红——这是「可重试失败被变成不可逆丢失」的回归钉）；另测「导入在事务内失败 → 旧行被回滚复原 + 挪走的旧 zip 被挪回原位」。**同名重生成不得截断旧产物（R9-F2）**：构造重生成**选中同一个 `start_datetime`**（新旧 zip 同名）且生成在打开最终文件之后抛异常的场景，断言 ①旧 zip 完整存在于 `<output>/.superseded/`、**逐字节与原件一致** ②报告记 `preserved_superseded` 路径 ③最终路径上不留半截文件（「先生成再按需删旧」的实现会在此变红——`ZipFile(path,"w")` 已把旧文件截断）。**staged `export_log.csv` 被钉住（R38-F1 回归钉）**：fetch 完成后**改动 staging 里那份 `export_log.csv`**（三种：截断 / 同尺寸改一个字节 / 换成上一代的那份）→ 每种都断言 ①`verdict == "FAIL_STAGING_INTEGRITY"` ②`staging_error` 五字段齐全 ③rc=1 ④**`import_qmt_stock` 从未被调用、`kline_pilot_<seed>` 未被创建**（只钉 K 线 CSV 的实现会在①变绿，然后拿一份被改过的元数据去卡每一只股的门2）；再造一条**反向钉**：staged log 与 manifest 相符、但 `--source` 那份不同 → 应判 `FAIL_SOURCE_BOUNDARY`（第 3 条闸），**不是** `FAIL_STAGING_INTEGRITY`（两个位置的漂移必须可区分）。**续跑必须与一口气跑完等价（R50-F3 回归钉）**：同一 seed + 同一 staging，跑两遍——第一遍**一口气跑完 N 只**，第二遍**在第 k 只之后中断再续**（续跑时前 k 只走 `already_done`）→ 断言两遍产出的**每一只股的 `start_datetime` 与 zip `content_hash` 逐一相等**（共用一个可变 `rng` 的实现会在此变红：走 `already_done` 的股不消耗 rng，后面的股因此抽到不同起点）。**无标记目录一律拒绝、绝不自动认领（R66-F2 回归钉，崩溃注入）**：对 `--dest` 与 `--output` **各**注入一次「`os.mkdir` 已成功、**写标记之前**进程中止」→ 断言原样重跑**拒绝启动**且 stderr 含「手工 `rmdir` 后重跑」的指引；**手工 `rmdir` 后重跑 → 正常首次使用建成**。**关键对照钉**：手工预先建一个空目录 → 同样**拒绝启动**、其内容与 inode **事后未变**（任何形式的「空目录自动认领」实现都会在此变红——它会把操作者预建或指错的空目录静默转成 staging/输出树，R36-F2 的洞原样复活）。再造两条**安全钉**：①目标是**预先建好的非空目录**（哪怕只有一个无关文件）→ **拒绝启动**、其内容逐字节未变；②打桩让「写标记」与「复查」之间有一个文件出现在该目录 → 断言**认领失败、刚写的标记被删掉、拒绝启动**。**用 `os.rename(临时目录, 最终路径)` 实现「不覆盖发布」的会在①变红**——POSIX 的 rename 在目标是空目录时**会替换**它，于是预先建好的空目录被静默删除并认领（R64-F1）。**指纹闸必须覆盖 `pilot_schema_sha256`（R63-F1 回归钉）**：只改 `backend/sql/pilot_schema.sql` 一个字节（`schema.sql` 与 `contract_version` 都不动）→ 用同一个库跑复用 → 断言**指纹闸拒绝**（只比 `schema_sha256` + `contract_version` 的实现会在此变绿——那正是让 `pilot_stock_source` 的 schema 漂移完全失明的口子）。**`pilot_stock_source` 必须在 `state=ready` 之前就存在（R62-F1 回归钉）**：新建/reset 一个库跑到 `state='ready'` → 断言 ①`pilot_stock_source` **确实存在**且列定义合规 ②`pilot_meta.pilot_schema_sha256` 等于 `backend/sql/pilot_schema.sql` 的实算 sha256 ③把该文件改一个字节后复用同一个库 → **指纹闸拒绝**（只哈希 `schema.sql` 的实现会在②③变红：那张安全关键表将永远游离在指纹之外）。**符号链接别名不得被判为 owned（R61-F2 回归钉，codex 点名）**：造一行 `file_path = /tmp/alias/{code}_{start}.zip`，其中 `/tmp/alias` 是**指向本次 `--output` 的符号链接**（故 `resolve()` 后父目录恰等于 output）→ 断言 ①**不判为 owned**（不计入 `already_done`、**绝不 `unlink`**）②记 `foreign_output_path` 并重生成到 canonical 路径 ③测试结束时 `/tmp/alias` 指向的真实文件**仍然存在**。只用 `resolve()`（R2-F1 原版）或只用 `same_inode`（R60-F1 版）的实现**都会在①变绿**——前者被别名骗过、后者因别名确实指向同一 inode 而放行。**并断言登记进 DB 的是 canonical 路径**。**FAIL_OUTPUT_BINDING 必须写得出来（R61-F1 回归钉）**：目录**已归属但没有既有报告**，喂一个**错 `--seed`** → 断言 ①确实写出 `pilot_report.json` 且 `verdict == "FAIL_OUTPUT_BINDING"`、带 `output_binding_error` ②rc=1（把第 2 层绑定也设成写入前提的实现会在①变红：那个 verdict 恰好在它该出现的唯一情形下永远写不出来）。**换代恢复也必须走 fd（R60-F1 回归钉，codex 点名）**：在 `source_generation_changed` 与 `stale_training_set` 两条恢复路径跑到一半时把 `--output` **改指到另一个目录** → 断言 ①`.superseded/` 的创建、zip 的挪动/挪回、`unlink` **全部发生在 ⑥ 钉住的那个 inode 里** ②被换上去的目录**逐字节未变**（`try_one` 里仍写 `output_dir/".superseded"` / `os.replace(p, sup)` / `unlink(p)` 的实现会在②变红——那是在一个未经授权的目录里做破坏性动作）。**引导态可恢复（R60-F3 回归钉）**：造一个「`.staging_owner.json` 已在、`fetch_manifest.json` 不在、`seed` 相符」的 `--dest` → 断言 ①`qmt_fetch` **能从头继续初始化并跑完**（不需人工清理）②只清理了 `export_log.csv` / `*.part` / `.inflight.json` 三类引导产物；再造一个同样状态**但目录里放了一个完整 K 线 CSV** 的 → 断言**拒绝启动并提示人工**。**路径与 inode 分叉必须被抓到（R59-F3 回归钉，codex 点名）**：跑到执行阶段后把 `--output` **改指到另一个目录**（原 inode 仍在），分两种：①新目录为空 → 断言 verdict 为 `FAIL_ARTIFACT_INVALID`、顶层 `output_path_diverged` 三字段齐全（**不在 `artifact_errors` 里**，P3r3-F10）；②**新目录里预置了同名的 `{code}_{start}.zip`**（内容不同）→ 断言**仍然**判 `FAIL_ARTIFACT_INVALID` 且带 `output_path_diverged`（只靠「能不能打开 + crc32」的实现会在②变绿——它会拿别人的同名产物给本次运行背书）。并断言**产物校验是按字符串路径打开的**（改成走 dirfd 的实现会在①②双双变绿，因为它永远读得到自己写的那份）。**⑥ 之后换标记 / 换目录都不得改变写入去向（R57-F1 回归钉，codex 点名）**：跑到执行阶段后，分别打桩制造三种篡改——①把 `.pilot_output.json` 换成两层不符的另一份 ②把 `<output>` **整个目录换成另一个目录**（原 inode 仍在，只是路径改指别处）③把路径上的某个分量换成符号链接 → 每种都断言 ①生成的 zip、`.superseded/` 的挪动与删除、**最终 `pilot_report.json`** 全部落在 **⑥ 那一刻验过的那个 inode** 里 ②被换上去的那个目录**逐字节未变** ③**运行正常收尾、报告确实写出**（把 B 段实现成「重读标记、不符即不写」的会在③变红——①d 已把 `pilot_report.json` 换成 `RUNNING`，拒绝写出恰好把它永久留在那里，R75-F1）。**最终报告的目录项也要落地（R51-F1 回归钉，崩溃注入）**：打桩模拟「最终 `pilot_report.json` 的 `os.replace` 已返回、但 `fsync(<output>)` 之前断电、目录项丢失」→ 断言 ①实现在 `os.replace` 之后**确实调用了 `fsync(<output>)`**（少这一步的实现会在此变红）②在注入丢失的场景下重跑，目录**不会停留在 `RUNNING`**——要么终局报告在，要么重跑能把它补出来（R75-F1：`RUNNING` 是「有运行未收尾」，不是任何一次运行的结论）。**`--dest` 首次使用的归属也要落地（R51-F1）**：模拟「`open_root(<dest>, create_leaf=True)` 的 `mkdirat` + `.staging_owner.json` 已写、但父目录/自身未 fsync 即断电」→ 断言实现调用了两处 `fsync`；否则一棵已拉好几百个 CSV 的 staging 会变成无主目录，下次 `qmt_fetch` 按「首次使用须路径不存在」直接拒绝、整批数据只能人工处理。**拿不到锁 = 一个字节都不许动（R39-F1 回归钉）**：预置一个**另一进程真正持有**的 `.staging.lock` 后跑 pilot → 断言 ①`--output` 里**没有任何新文件**（连报告都没写）②原有报告逐字节未变 ③rc≠0 ④DB 与 staging 零改动。**锁持到报告落盘之后（R39-F1 回归钉）**：打桩在「产物校验完成」与「报告落盘」之间插入一次断言，检查全局锁与 `.staging.lock` **仍被持有**（消费循环结束即释放全局锁的实现会在此变红——取证与落盘之间的窗口足以让另一个 writer 改掉库与输出目录）。**库级闸有专属 verdict（R39-F2 回归钉）+ 按动作分支（R49-F2 回归钉）**：分别造「无 `pilot_meta`」「`seed` 不符」「绑定不符（复用）」「指纹不符」「结构缺 `pilot_stock_source`」「`--reset` 绑定不符且未带令牌」「令牌填错」七种 → 各自断言（见下）；**外加一条正向钉：一个归属与绑定都相符、但 `schema_sha256` 已漂移的库，带 `--reset` 跑 → 必须放行到 DROP + 重建**（把指纹/结构闸也塞进 `--reset` 分支的实现会在此变红——那会让一个陈旧 schema 的库连 reset 都做不了，而 reset 正是它唯一的出路，R49-F2）。七种 → 各自断言 ①`verdict == "FAIL_DB_BOUNDARY"` ②`db_boundary_error` 取到各自专属码 ③`db_bound_identity` 三字段齐全 ④**报告 JSON 里不含 `confirm_token`**（写进去的实现会在④变红——那让 wrapper 可以读报告取令牌再重跑）⑤rc=1 ⑥DROP 从未执行。**准入阶段零副作用（R27-F2）**：喂一份**畸形 manifest**（实拷清单缺一条）跑完整 pilot → 断言 ①非零码退出 ②`kline_pilot_<seed>` **在 `pg_database` 里查不到**（未被创建）③已存在的库**未被 reset** ④**首次使用**场景下 `--output` 路径**仍未被创建**（把建库放在校验之前的实现会在②③变红）。**报告写入必须崩溃安全（R41-F1 → R69 重定，崩溃注入）**：在「时间戳文件已落盘、`pilot_report.json` 尚未刷新」处注入一次中止 → 断言重跑能正常完成，且**上一次的时间戳报告逐字节未变**（只增不毁使这一档天然安全：任何中间态都只是「多了一份历史报告」）。**ENOSPC 既不造成空洞、也不让陈旧 SUCCESS 幸存（R69 + R74-F1 回归钉，两档）**：预置一份上一次运行的 `verdict: "SUCCESS"` / `ship_eligible: true` 报告（时间戳文件 + `pilot_report.json`），然后打桩让**最终**报告写入失败（模拟磁盘满）→ 断言 ①**上一次运行的时间戳报告逐字节未变** ②本次未产生任何半截报告 ③**`pilot_report.json` 现在是本次开跑时发布的 `RUNNING` / `ship_eligible: false`，而不是上一次那份 `SUCCESS`**（R74-F1：不发 `RUNNING` 的实现会在③变红——那正是「新运行失败了，旧的成功凭据却继续冒充当前状态」）。**第二档**：让 `RUNNING` 自己写不出去（在 ①d 处注入 ENOSPC）→ 断言 ①进程**立刻非零码退出** ②DB / staging / 输出目录**零改动**、连时间戳报告都没多一份 ③上一次的两份报告逐字节未变（把 `RUNNING` 失败当可忽略、继续往下跑的实现会在①②变红）。**第三档（R75-F1 回归钉，codex 点名）——良性拒绝绝不能毁掉上一次的凭据**：预置上一次的 `SUCCESS` 报告后，分别制造 ①`--staging` 打错字（①b 归属闸不过）②另一进程真持有 `.staging.lock`（①b 取锁失败）③同 seed 的另一次运行正持有 advisory lock（①c 失败）→ 每种都断言 **`pilot_report.json` 仍是上一次那份 `SUCCESS`、逐字节未变**、`--output` 里没有任何新文件、rc≠0。**把 `RUNNING` 发布在 ①a 之后（而非 ①c 之后）的实现会在三档全部变红**——它会把一次良性的并发重试变成一份永久停在 `RUNNING` 的报告。**第四档（R75-F1）**：⑥ 已归属支重核不符 → 断言 ①`pilot_report.json` 是 `FAIL_OUTPUT_BINDING` + `output_binding_error: "owner_marker_swapped"`（**不是** `RUNNING`、**也不是**上一次的 `SUCCESS`）②新时间戳文件已写出 ③上一次的时间戳报告逐字节未变 ④rc=1；**首次使用支** `mkdir` 撞 `EEXIST` 无标记 → 断言一个字节都不写。**畸形 `pilot_meta` 必须挡住 DROP，不只是挡住复用（R80-F1 回归钉，codex 点名）**：造一个 `key` 上**没有唯一约束**、塞着**两行 `seed`**（一行等于本次 seed、一行不等）的库，**带 `--reset`** 跑 → 断言 ①`verdict == "FAIL_DB_BOUNDARY"` + `db_boundary_error == "pilot_meta_ambiguous"` ②**`DROP DATABASE` 从未执行、该库事后仍在** ③rc=1；再造「缺 `output_dir` 键」「两行 `output_dir`」「`value` 为 `varchar(8)`」三种同样带 `--reset` 跑 → 同样拒绝。**把 `pilot_meta` 断言只放进「闸 2 结构」（复用专属）的实现会在全部四档变红**——DROP 路径根本不跑闸 2，于是最危险的那条路径原封不动。**反向钉（分寸不能过头，R49-F2）**：一个 `pilot_meta` **完全合规**、归属与绑定都相符、但 `schema_sha256` 已漂移的库，带 `--reset` 跑 → **必须放行到 DROP + 重建**（把指纹/结构塞进 DROP 路径的实现会在此变红——陈旧 schema 的库连 reset 都做不了，而 reset 是它唯一的出路）。**零对象残骸不走闸 0−**：一个零用户对象、库名全等 `kline_pilot_<seed>` 的空库 + `--reset` → 断言仍按 R56-F1 五条例外**正常 DROP 重建**（把闸 0− 套到它头上的实现会在此变红——它根本没有 `pilot_meta` 可查）。**`pilot_meta` 自身必须被结构闸覆盖（R79-F2 回归钉，L1 + L2 各一遍）**：造四种坏 `pilot_meta` —— ①`key` 上没有主键/唯一约束，且塞进**两行 `seed`**（值不同）②缺 `output_dir` 键 ③`value` 列类型被改成 `varchar(8)` ④`state == 'initializing'` —— 每种都断言**复用被拒**（①②③ 判 `structure_mismatch`、④ 判 R55-F1 的「一律拒绝复用、提示 `--reset`」），且**DROP 从未执行**。**只断言 klines/stock_coverage/training_sets/pilot_stock_source 的实现会在①②③变绿**——而归属闸与绑定闸随后读到哪一行取决于实现，`--reset` 的破坏性正建立在这张表上。**落笔前重核归属不得反噬终局报告（R77-F1 回归钉）**：在 ⑥ 之前把 `.pilot_output.json` 换成两层不符的另一份、**或干脆删掉它** → 断言 ①仍写出终局 `FAIL_OUTPUT_BINDING` + `owner_marker_swapped` ②`pilot_report.json` **不停在 `RUNNING`** ③写入落在 ①a 钉住的 inode。**把 R56-F2 那条「读标记、不符即不写」无差别套到 ①a 之后所有报告写入的实现会在①②双双变红**——它会让运行永久停在非终局状态。**首次使用：锁必须早于标记可见（R97-F2 回归钉，codex 点名）**：打桩让首次使用支在 **`mkdirat` 返回之后、写 `.pilot_output.json` 之前**暂停，此时启动第二个 pilot（同 `--output`）→ 断言 ①第二个 pilot **拿不到 `LOCK_EX`**（创建者已持有）、干净退出、一个字节都不写 ②创建者恢复后正常写标记 + 发布 `RUNNING` + 跑完。**先写标记后取锁的实现会在①变红**——第二个进程会把该目录判为「已归属」、抢先取锁、发布 `RUNNING` 甚至写出终局报告，而创建者已改过磁盘却拿不到锁。**①d 之前的基础设施异常一律不写报告（R97-F1 回归钉）**：分别在 ①a（输出目录打不开）/ ①b（staging 不可读）/ ①c（维护 DSN 连不上）/ 注入基础设施异常 → 每种都断言 ①`--output` 里**没有任何新文件**（**尤其没有 `FAIL_INFRASTRUCTURE` 报告，也没有 `RUNNING`**）②既有报告逐字节未变 ③rc≠0 ④DB / staging 零改动。**照「准入阶段的基础设施异常一律写报告」实现的会在①变红**——那时 ② 还没跑过，**根本没有可信的 `output_binding` 可写**，只能产出一份 schema 非法的报告或抹掉旧凭据。**反向钉**：在 ② 读 manifest 时注入 IO 异常（此刻 `RUNNING` 已发布）→ 断言**写出 `FAIL_INFRASTRUCTURE` 报告且 `output_binding.export_log_sha256 == null` 合法**；再在消费循环中途注入 → 断言此时 `output_binding` **必须非 null**。**`fetch_fatal_error` 写侧与读侧形状必须逐字相同（R94-F2 回归钉）**：让 fetch 撞 `source_path_escape`（再跑一次 `staging_path_escape`）→ 断言写出的顶层 `fetch_fatal_error` **恰有四字段** `{kind, relative_path, component, errno}`；**另一条钉（O4-F1）**：让 Run1 撞 escape、Run2 触 `--max-bytes` → 断言 pilot **仍然 fail-closed**（照「按 `stopped_reason` 取值分支」实现的会在此变绿——一次信任边界破坏被一次容量停止洗白）；再把这份 manifest 喂给 pilot → 断言得到 **`FAIL_SOURCE_BOUNDARY` / `FAIL_STAGING_INTEGRITY`**（**不是 `FAIL_MANIFEST_INVALID`**）。**写三字段（漏 `errno`）的实现会在第二步变红**——读侧要求四字段，于是一次信任边界破坏被报成「manifest 畸形」，恢复指引整个走错。**`source_errors` 每条必带 `error`（R86-F2 回归钉）**：分别构造「源≠staging」「源==staging 但≠manifest（双双换代）」「`full` 两趟不一致」三种 → 断言 `source_errors[].error` 分别取 `source_staging_mismatch` / `manifest_mismatch` / `passes_disagree`，**三者可区分**（只填路径与哈希、不填 `error` 的实现会在此变红：消费者拿不到机器可读的失败原因，而这三档分别意味着「源被改了」「源与 staging 一起换代了」「源正在变」——处置完全不同）。**`--dest` 首次使用须目录级原子创建（R36-F2 回归钉）**：预先建一个**空的** `--dest` 目录 → 断言 `qmt_fetch` **拒绝启动**、该目录**未被写入 `.staging.lock`/CSV/manifest**（「为空即可」的实现会静默认领它）。**复用库既有活跃行数 > `target` → `FAIL_REUSE_OVERFULL`（P3r3-F11 回归钉）**：预置一个既有 120 行活跃 `training_sets` 的库（模拟上一次用 `--target 120` 跑过），用默认 `--target 100` 复用它 → 断言 ①`verdict == "FAIL_REUSE_OVERFULL"`（**不是** `FAIL_TARGET_MISMATCH`——后者要求三字段且只在准备判 SUCCESS 的路径上检查，准入期根本没有 `actual_distinct`）②报告带 `reuse_overfull: {expected: 100, actual_total: 120}` ③rc=1 ④**一只股都没被导入**（该闸在 ⑤b′、执行阶段之前）。**没有独立 verdict 的实现会在①变红**：优先级表里查不到它 → KeyError → 被顶层兜成 `FAIL_INFRASTRUCTURE`，操作者去查磁盘和网络，而真相是「换个 seed 或 `--reset`」。

**全部新增测试必须 mutation 验证**：中和被测守卫 → 该测必须变红 → 复原。由控制者亲验，不接受 subagent 自证。

### 6.2 L2 — 真 PostgreSQL（流程纪律，非 CI 门；O3-F15 补齐——此前 §6 只有 6.1 与 6.3，而 §9-12 要求 L2 全 PASS）

Docker `postgres:15.12`，脚本 `verify_pilot_e2e.py`（与 4a 的 `verify_pilot_db_lifecycle.py` 一并跑）。
**这一层是「假 conn 不得替代真 PG」这条纪律的唯一落地处**。五项按 §9-12 逐条落地：
1. **session 锁可重入**（同一连接重复取同一把 advisory lock）——假件建模不出来；
2. **四类陈旧库拒绝**（OHLC 仍 `DECIMAL` / `file_path` 为 `VARCHAR` / 缺 `uq_stock_start` / 缺 `content_hash`）；
3. **坏产物两轮恢复**（造 zip 缺失 + crc32 失配两行 → 连跑两轮，第二轮必须干净通过）；
4. **绑定失配的 `--reset` 破坏性分支**（R12-F3）：裸 flag / 错令牌 / 正确令牌**三跑**，
   每跑都真验目标库是否幸存 —— 它守的是 `DROP DATABASE` 这条**不可逆**路径，假件建模不出来；
5. **`pilot_stock_source` 结构闸的真 PG 复验**（4a 闸 2 的七组闭合清单在真库上逐条断言）。

### 6.3 L3 — 真数据人工验收（非 coder 可执行；**诊断性，不做出货断言**）

| # | 动作 | 期望 | P/F |
|---|---|---|---|
| 1 | 开 Windows 机、确认 QMT 已导出，挂载 SMB 共享到 mac | `ls <source>/export_log.csv` 能列出 | |
| 2 | 跑 `qmt_fetch --source … --dest … --max-bytes 3G` | rc=0；`<dest>/fetch_manifest.json` 存在且 `stopped_reason` 为空 | |
| 3 | 跑 `qmt_pilot --staging <dest> --output <out> --maintenance-dsn …` | 进程正常结束（rc 任意值都算 PASS，**本步不判成败**）| |
| 4 | 贴回 `<out>/pilot_report.json` 全文 + 进程 rc | 两者都拿得到 | |
| 5 | 从报告里读出 `verdict` / `skip_reason_counts` / `universe_sizes` / 分层分布 | 四项都在、且能回答「真数据流过了吗、卡在哪道门」 | |

**本层只回答两个问题**：①**真 QMT 数据第一次流过 B1→B2 了吗**；②**卡在哪道门、为什么**。
**不回答「能不能出货」**——那需要出货凭据链，已移出后续 plan（§0）。

## 7. 交付诚实口径

- **CI 绿 ≠ 真数据已流过。** 4c 合并时的正确表述是「编排建好、用假 conn + fixture 与真-PG 脚本验过」。
- **禁述**：「pilot 已完成」「100 股已出货」「真实数据接入完成」。
- **⚠️ 本 plan 不做出货断言（2026-07-28 定案）**：出货凭据链（`--verify-shipment` / 凭据谓词 /
  ①e 保护闸 / crc32 自证）**已整块移出**。因此：
  - `pilot_report.json` 与时间戳报告都是**诊断产物**，**不构成任何出货凭据**；
  - **不得**基于它们声称「这批训练组可以交付/使用」——本 plan 能声称的上限是
    「**跑完了，报告如实记录了发生过什么**」；
  - L3 人工验收贴出的报告，**只用于回答「真数据流过了吗、卡在哪一道门」**，
    不用于回答「够不够格出货」——后者由后续 plan 定义。
- 若 `source_verification == "full"`（非 `snapshot`），交付说明须**原样带上** `source_verification_caveat`：
  两趟复校一致证明的是「源在验证窗口内未变」，不等于证明源不可变。
- 真跑结果**无论成败都如实报告**。若凑不齐 100 只，报告即为交付物之一；**不在本 plan 内放宽任何门**。
- PR body 须写明「当前局限」，与 Plan 2 / Plan 3 的口径一致。

## 8. 已知风险与 pilot 要观测的未知数（P4-D14）

| 风险 | 说明 | 缓解 |
|---|---|---|
| **`--output` 路径在运行中途被外部替换** | 本次的诊断报告只存在于**原 inode**；而按 `<output>/pilot_report.json` 这个**路径**去读的人/自动化，读到的是替换上来那个目录里的内容 —— **那个目录不归本工具所有，我们既无权写它、也无从保证其内容**（往里写才是真正的越界） | ①**尽早发现 + 立刻中止 + 说清楚**：在第一次状态改变之前、每条登记之前、最终报告落盘之前各查一次 `(st_dev, st_ino)`（`openat(parent_fd, basename, O_NOFOLLOW)` 与钉住的 `out_fd` 比对——父目录由 `open_root` 钉住，故这条检查本身不会被换分量骗过，R75-F2）；分叉即中止。**残余（如实登记，不声称已缓解）**：本 plan 交付后，读报告的**唯一**方式就是按 `<output>/pilot_report.json` 这个路径读，**读侧没有任何防线**——原先堵这条的 `--verify-shipment`（先验归属两层、再经同一 fd 读报告）**已随出货凭据链移出**（§0）。故一份被替换上来的目录里的陌生报告**读得到、且无从分辨**。**这正是「本 plan 不做出货断言」的直接理由**（§7）：诊断结论可以这样读，交付判断不可以。另有一档更强的残余：对 `<output>` 有写权限的外部写者可以整套伪造——那等价于「凭据存放处不可信」，**任何带内机制都修不了**。本工具对**并发的自身运行**由输出 `flock` 强制。 |
| **D10 `date_set_mismatch` 可能大规模杀股** | `reconcile_sources` 要求 `dense == daily_in_span` **完全相等**。dense = 1m 恰好 241 根的日子；覆盖带**内**任一日 1m 不足 241 根、而日线有该日行 → 整股拒。既有实证（「在库交易日恒 241 根、停牌整日缺席、唯一 partial = 覆盖边界日」）**只在 2 只深市老股上验过**（`000001.SZ` / `000004.SZ`），**全市场是否成立未知**——这是 pilot 最大的未知数 | 诊断报告按 reason 聚合，一眼看出是不是这道门在杀股 |
| 每股候选起点仅 3~4 个 | 1m ≈ 11.5 个自然月 vs 窗口需 8 个完整月 | 预筛 (c) 提前剔掉必不可能的；报告记录 `no_eligible_training_window` 计数 |
| 上市不满 39 个月整只拒 | BJ 主要死因（北交所 2021-11 开市，2023-04 后上市的均不足） | 预筛 (b) 零成本剔除；BJ 配额给到 120 ≈ 全拉通过预筛的 |
| `dropped_dates` 在被接受的股票上大概率恒空 | 带内 dropped ⟹ `date_set_mismatch` ⟹ 该股已在更早的门被拒 | 这是**推论不是缺陷**：Plan 3 为 `dropped` 加的独立阻断器（R5-F2/R6-F1）在真实数据上多半是纵深防御死路径。pilot 报告可证实/证伪 |
| 磁盘 30 GiB 余量 | staging ≈2 GiB + PG ≈1.5 GiB + zip ≈50 MiB ≈ 3.6 GiB | `--max-bytes` 默认 3 GiB fail-closed；不做全量镜像（27 GiB 会把盘撑到 98%） |
| 源机不可控 | 445 探测不通，需控制者开机 | 计划内显式前置步骤；4a/4b/4c 的自动化验证均不依赖源机 |

---


---

## 9. 验收标准（P/F）

| # | 判据 |
|---|---|
| 0 | **本 plan 不做出货断言**：`--verify-shipment`、出货凭据谓词、①e 保护闸、crc32 自证均**已移出**（见 §4.2 顶部）。验收只判「编排正确 + 报告如实落盘」 |
| 1n | **`ship_eligible` 必须是派生量，不得枚举贡献者（R26-F1）**：实现里只能写 `ship_eligible = (final_verdict == "SUCCESS")`。**任何「由 X + Y + Z 推导」式的枚举写法都是缺陷**——本 spec 曾在 `2026-07-27-qmt-plan4b-fetch-design.md` §4.4/`2026-07-27-qmt-plan4b-fetch-design.md` §4.5 用四项枚举，随后新增的 fetch 侧取小（R21-F1）、危险形状（R22-F2）、target 失配（R25-F1）三道否决闸**全部没被补进那个枚举**，照它实现即可带着 fetch-`partial`/重复行/超池行/计数漂移出货。派生式定义自动随 verdict 集合演进保持正确 |
| 1i | **出货资格由 pilot 亲自读源挣得，且校验为三方相等（R17-F2 + R20-F1）**：`ship_eligible: true` 必须以 `pilot_source_verification.ran == true` 为前提，且该校验须逐文件断言 **`sha(源) == sha(staging) == manifest 记录值`**（只比 source↔staging 不够——`export_log.csv` 可逐字节不变而 K 线已换，两者双双漂到新一代时自比必然一致，而全套不变量却锚在冻结的 manifest 上）。未传 `--source` 时一律 `partial`（门槛默认→rc=2；门槛非默认→先命中 `SUCCESS_NON_SHIPPING`/rc=3，R37-F2），**无视 manifest 自述**。manifest 侧的存根校验降级为「一致性检查」（可挡截断/版本错位/字段缺失），**不再单独授予出货资格**——它拿 manifest 自己的哈希算聚合，证不了校验进程读过源 |
| 1k | **zip 落地原子化 + 走钉住的目录 fd（R19-F3 + R57-F1）**：`assemble_from_windows` 签名新增 `output_dir_fd`，临时文件用 `os.open(..., O_CREAT\|O_EXCL\|O_NOFOLLOW, dir_fd=)`、落地用 `os.replace(..., src_dir_fd=, dst_dir_fd=)` + `os.fsync(dirfd)`、清理用 `os.unlink(..., dir_fd=)`，不再 `ZipFile(最终路径, "w")`、**也不再由 `--output` 字符串解析路径**。**守卫必须落在真正打开该路径的函数里**——`try_one` 直调 `generate_one_training_set`，最终文件名在生成过程内部才确定，pilot 拿不到路径也就无从在打开前 `O_NOFOLLOW`，那道守卫在强制路径上等于没有。顺带修掉「崩溃在最终路径留半截 zip」 |
| 1h | **证据读侧核实，输入与过程存根缺一不可（R15-F2 + R16-F1）**：①**前置输入**——`snapshot`→合法 `gmt_token`；`full`→`operator_attestation.no_export_window == true`。②**过程存根 `source_verification_evidence`**——`snapshot` 恰 1 趟且 `verified_against_mount`；`full` 恰 2 趟且 `passes_agree`；两级都须 `aggregate_sha256` 与「由 manifest 自身逐文件 sha256 重算的聚合」逐字相符、`files_verified` 等于已拷文件数。任一缺失/不自洽 → 拒绝整个 manifest。**本条的作用域到此为止：它只 fail-close 畸形/不自洽的 manifest，不授予也不参与出货资格判定（R18-F2）**——`ship_eligible` 是派生量 `≡ (final_verdict == "SUCCESS")`（R26-F1；此处**不得**枚举贡献者） |
| 2l | **归属判定须字面 + 身份双条件（R61-F2）**：`file_path` 的归属**不得用 `resolve()`**（它跟随符号链接，`/tmp/alias -> <output>` 会被放行，而登记进 DB 的仍是那串别名，B3 按它开文件会 404 或读到别人的字节）；判据 = **字面**（`normpath` 后父目录逐字等于 canonical output）**且** **身份**（父目录 inode 等于钉住的 `out_fd`）。登记时**只写 canonical 路径**。⚠️ R60-F1 把判据改成纯 `same_inode` 后别名反而畅通——**把「按名字」换成「按身份」时，原来那条按名字的检查不一定能删** |
| 2j | **恢复路径同样只能走钉住的 fd（R60-F1）**：`try_one` 的 `.superseded` 创建、zip 挪动/挪回、`unlink`、以及 `owned` 归属判定，**全部相对 `out_fd`**（`same_inode` / `ensure_owned_dir_at` / `os.replace(..., src_dir_fd=, dst_dir_fd=)` / `os.unlink(..., dir_fd=)`），**不得再解析 `--output` 字符串**。这是「⑥ 之后所有输出改动走 fd」这条规则的**第三个执行点**（前两个：zip 落地、报告写入）——**破坏性恢复恰恰是最不能走错目录的那条路径** |
| 2k | **`output_dir_fd` 必须可选，不得打断 B2/B4（R60-F2）**：`generate_one_training_set` / `generate_batch` 同时被 B2 CLI（`_amain`）与 B4 调度器（`app/scheduler.py`）调用；该参数设为必填会直接打断这两条既有生产路径。契约：**给了就用调用方的 fd**（pilot），**没给则函数自己在本次调用期间打开并持有**（B2/B4 由此获得原子落地与 no-follow，但不获得跨调用的 inode 钉死——那本不是它们的需求）。B2/B4 调用点**一行不改** |
| 2h | **输出锁必须早于关于输出的第一个判断（R59-F2）**：已归属支在 **①a**（**任何输出目录读写之前**）就 `O_DIRECTORY\|O_NOFOLLOW` 钉住目录并取**非阻塞** `flock`，持到最终报告 fsync 之后；首次使用支在 ⑥ 的认领成功（`mkdir` + 写标记 + 复查）之后紧接着取。`--maintenance-dsn` 不同的两个调用**不共享** ①c 的 advisory lock，只有输出锁能拦住它们 |
| 2i | **写用 fd、验用路径，且必须显式断言两者未分叉（R59-F3）**：产物校验**必须按字符串路径打开**（它模拟的是 B3 的视角，B3 拿不到我们的 fd）；另加一条 `os.stat(--output)` 与 `os.fstat(pinned_fd)` 的 `(st_dev, st_ino)` 相等断言，不等即写**顶层** `output_path_diverged`（**不进 `artifact_errors`**，P3r3-F10——`{stock_code, file_path, error}` 这个形状在「一条 `training_sets` 都还没登记」的检查点 1 上**装不下它**）→ `FAIL_ARTIFACT_INVALID`。**钉住 inode 之后出现的新失败形态是「产物写成功了、但登记的路径已指向别处」**，靠 ①② 顺带发现只是巧合——被换上去的目录若恰含同名 zip，检查反而会「通过」，我们就用别人的产物给自己背书 |
| 2r | **路径分叉要早查、且如实交代残余（R68-F1）**：`(st_dev, st_ino)` 一致性检查放三处——第一次状态改变之前、每条登记之前、最终报告落盘之前；分叉即中止。**残余局限须写进 §8**：分叉后诊断报告只在原 inode，而 canonical 路径上的内容**不归本工具管、也不许写**——只能尽早发现 + 立刻中止 + stderr 说清楚 |
| 1y | **授权的最后一次确认必须紧贴被授权的动作（R46-F1）**：`.pilot_output.json` 两层重核（已归属）与**认领协议**（首次使用：`mkdir` + 写标记 + 复查）**整体排在第一次状态改变之前**（该词的唯一定义见 本文件 §4.2：建/复用/reset 库、写产物、写**终局**报告；**①d 的 `RUNNING` 显式不在其中**，R96-F1）；⑥ 失败**按支分开**（R75-F1）：首次使用支什么都不写；**已归属支写终局 `FAIL_OUTPUT_BINDING` + `owner_marker_swapped`**（①d 已发布过 `RUNNING`，留着它等于把「被正当拒绝」谎报成「结论未知」）。重核若排在动手之后，标记在准入后被换掉时，工具会**拿着过期授权往一个不再属于它的目录里写东西** |
| 2x | **输出目录上的第一次写，也要紧贴一次授权确认（R78-F1）**：`RUNNING` 是**写**，而 ① 的第 1 层校验是**无锁、无 fd** 时做的 → 必须在 ①a 钉住 fd + 取锁之后、①d 之前**经 `out_fd` 重核第 1 层**（①a′），不符即什么都不写。R46-F1 那条「授权的最后一次确认必须紧贴被授权的动作」当初只落在 ⑥（第一次状态改变），**因为那时 `RUNNING` 还不存在**；**新增一次写，就必须给它配一次紧贴的授权确认** |
| 2y | **测试契约里不得残留 `resolve()`（R78-F2）**：§6 4c 曾写「`..`／符号链接指向 output 内部的路径也走 `resolve()` 后判定」，与 §9-2l 的权威判据（**字面 `normpath` 父目录 + 父目录 inode，明令禁用 `resolve()`**）直接冲突。照它实现，**符号链接别名会被判成 owned 并被 `unlink`**，而 B3 随后打开的是那条可变别名。已改为断言「`..` 按词法归一、别名一律 `foreign_output_path`」 |
| 2v | **「落笔前重核归属」只作用于 ①a 之前（R77-F1）**：该协议立于 R56-F2，那时既无 `out_fd` 钉死（R57-F1）也无 `RUNNING` 先行发布（R74-F1）。**①a 之后一律经 `out_fd` 直接写、不再重核标记**——即使标记已被换掉或删掉也必须写终局报告，否则真实时序是「①d 已发布 `RUNNING` → 标记被换 → 一个字节都不写 → **永久停在 `RUNNING`、连时间戳报告都没有**」，与 R75-F1 在同一节里正面打架。**判据（R57-F1 原话）**：一个保护手段的**失败动作**是什么，决定了它能用在哪一段——「不符即不写」的失败动作是「留下非终局状态」，故它只能用在「还没有任何非终局状态需要收尾」的那一段 |
| 3k | **「唯一权威」的收尾清单必须列全所有 no-write 出口（R89-F1）**：该清单自称唯一权威，却只列了 ①/①a/①b/①c/⑥-首次使用，**漏掉 ①a′ 与 。照它实现，一次被 据**。R69 写下的「不再有出货能力闸」一句也须同步更正：**历史凭据毫发无损，但 §7 只认当前那份**，故刷新在唯一有意义的语义下仍是破坏 |
| 3t | **取锁必须早于「对外可见地成为我的」，中间不得有窗口（R97-F2）**：首次使用支原写「`mkdirat` → 写标记 + `fsync` → 取 `flock`」。**标记一旦落盘，该目录对外就是「已归属、可复用」**——第二个 pilot 会在 ① 判它已归属、走 ①a **抢先取到 `LOCK_EX`**、发布 `RUNNING` 甚至写终局报告，而**创建者已改过磁盘却拿不到锁**。「同一 `--output` 的写者被串行化」这条不变量**在创建那一瞬间不成立**。改为：`mkdirat` 返回 fd → **立即 `flock(LOCK_EX\|LOCK_NB)`** → 取到才写标记 → 再发布 `RUNNING` |
| 3u | **报告的形状必须覆盖「还没有可信身份」的那一段（R97-F1）**：schema 只允许 `RUNNING` / `FAIL_MANIFEST_INVALID` 的 `output_binding.export_log_sha256` 为 null，而 本文件 §4.3 又要求「准入阶段的基础设施异常一律写报告」——**①c 维护 DSN 连不上发生在 ② 之前，实现手里根本没有可信的 `export_log_sha256`**，只能写一份 schema 非法的报告、或跳过报告让旧凭据继续当前。按 **①d 切开**：**①d 之前的基础设施异常一律不写**（`RUNNING` 尚未发布，退出是干净的）；**①d 之后、② 通过之前**的 `FAIL_INFRASTRUCTURE` **允许 null**；② 之后必须非 null（由 `fatal_error.stage` 区分）|
| 3f | **`artifact_errors` 的枚举与字段名（R85-F2）**：顶层 `output_path_diverged` 字段必须存在（**不进 `error` 枚举**，P3r3-F10）（§9-2i 与 本文件 §4.3 都要求用它报告「`--output` 在 fd 钉死之后被换掉」，而 schema 里没有它）；**字段名恒为 `error`**——本文件 §4.3 分叉规则原写 `kind`，与 schema 及其余各处不一致。**照 schema 生成/校验的实现会把这个唯一精确的诊断拒掉或归一化掉，而它正是路径边界失败的唯一信号** |
| 3j | **`try_one` 的每条分支必须对它自己承认可能出现的状态是全函数（R87-F2）**：`source_generation_changed` 分支排在归属处理之前，而 `!owned`（行的 `file_path` 在 output 之外）**是本 spec 明确承认会出现的状态**（R2-F1 / R61-F2 都在处理它）。旧文无条件走 `.superseded` 协议 → `sup_fd` 从未创建，收尾 `unlink(p.name, dir_fd=sup_fd)` **直接崩**。改为**先按 `owned` 分支**：`!owned` 时只删 DB 行 + 重导入 + 重生成到本次 output，**跳过整套 `.superseded` 协议、绝不 `unlink` 外部文件** |
| 3p | **规则被加强后，旧版本必须删掉或并入，不能作为「另一条」并存（R93-F2）**：R91-F1 给源边界闸补了 `4b′`（fd 派生挂载点 + 反向验证到 `src_fd`），**而旧版 `4b`（只要求相对路径字符串相等）被留在同一张权威清单里、且排在新条之后**。实施者照「看得见的七条」逐条做，完全可能只做到字符串相等就收工——**而克隆调包攻击恰恰只被反向验证挡住**。已合并为单一条 `4b`（三小项 i/ii/iii 全为强制），§9-1j 与 §6 同步。**并存时后来者读到的是「有两条要求」，实际做到的往往是较松的那条** |
| 3n | **首次使用支撞 `EEXIST` 一律 no-write，不得就地转复用（R91-F2）**：首次使用支**从未跑过** ①a（钉 fd + 取 `LOCK_EX`）与 ①a′（经 fd 重核第 1 层）**这两道闸**。若另一次运行在 ① 与 ⑥ 之间创建并写好了该目录，**就地转复用会让这次运行同时绕开串行化（`LOCK_EX`）与经 fd 的重核**。收紧为单一结局：**撞 `EEXIST` 一律拒绝启动、一个字节都不写**，提示原样重跑——重跑会被 ① 判为「已归属」，从而完整走完那三道闸。**一条分支若跳过了另一条分支的准入序列，就不能在中途「并」进去** |
| 1s | **staging 锁进权威序列（R35-F1 + R65-F1）**：`.staging.lock` 的取得**必须写在 本文件 §4.2 序列的 ①b**（早于任何 staging 读取），**且 ①b 内部必须「先过 staging 归属只读闸 + 路径重叠检查、再取锁」**——取锁要创建/写文件，打错字的 `--staging` 会先在未经证明的目录里落下锁文件（R4-F4「任何写动作之前先证明目标是我的」的第二个执行点），并**持到 `pilot_report.json` 原子落盘之后**（R39-F1：取证与落盘之间无锁则报告可能描述一个已不存在的状态）。**`2026-07-27-qmt-plan4b-fetch-design.md` §4.5 只声明语义、不定义顺序**——过程性规则只在 本文件 §4.2/`2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 定义（R11 立的权威规则）。实施者只读 本文件 §4.2 也必须能拿到锁 |
| 1q | **不得留下会被误读为「当前状态」的陈旧成功证据（R29-F1 + R30-F1；R69 重定）**：不变量——**`pilot_report.json` 永远是「最近一次在该目录写过报告的运行」的副本，出货断言只认它**；而每次运行的报告另有一份**不可变时间戳文件**（**`<UTC>` 写死为微秒级 ISO-8601 basic：`20260727T101530123456Z`；撞名时用
`O_CREAT|O_EXCL` 重试并递增后缀，**该重试本身不得触发 `FAIL_INFRASTRUCTURE` 递归**，O3-F8——
粒度此前未定义，两次亚秒级准入失败会撞名，而规则是「一经落盘永不覆盖」：第二次要么违反不可变性覆盖、
要么写失败，而写失败又被当成基础设施异常 → 「必须原子写出两份报告」→ **递归到同一个失败**。
这是「不可变历史」唯一的持久载体，它的主键此前没有唯一性保证）永久留存。正向：在一份 `SUCCESS` 报告之上跑出任意**会产生 verdict 的**失败（含准入阶段的 ②/②b/③/④/④b/⑤/⑤b）→ `pilot_report.json` **必须**已刷新为本次结论、`ship_eligible == false`（**「有既有报告就不写」的实现会在此变红**：那会让陈旧的 `SUCCESS` 继续冒充当前凭据，而 §7 正以它为准，R70-F1）。**反向（只增不毁）**：上一次的时间戳报告**逐字节未变**，没有任何「中和 / 改名 / 删除」发生 |
| 1r | **首次使用的归属是目录级原子创建（R30-F2 + R64-F1 + R91-F2）**：`--output` 由 `mkdirat` **独占创建**；**撞 `EEXIST` 一律拒绝启动、一个字节都不写**（无标记那一档另提示人工 `rmdir`，R66-F2；有标记那一档提示原样重跑，R91-F2）。**不得**用「目录为空 + `O_CREAT\|O_EXCL` 建标记」代替——后者只挡得住另一个 pilot 进程抢建标记，挡不住任何其他写者在「判空」与「建标记」之间放进一个文件，而那之后 `os.replace` 会覆盖该无主产物。测试须构造「判空后、建标记前有文件出现」的竞态 |
| 1p | **簿记项豁免须以归属已证明为前提（R27-F1 + R30-F2）**：首次使用 `--output` 由 `os.mkdir` 独占创建（R64-F1），故 `.superseded/` 与不匹配的 `.pilot_output.json` 天然无从存在；仅当标记四项相符、归属已证明后，这两项才不参与空目录判定。否则豁免自身成为绕过归属闸的通道 |
| 5m | **耐久提交：命名空间改动后必须 fsync 目录（R45-F2 + R51-F1）**：`.part`→final 的 rename、`.inflight.json` 建/删、`export_log.csv` replace、manifest 每次提交、**`--dest` mkdir 与 `.staging_owner.json` 创建**、`--output` mkdir 与标记创建、zip replace 与 `.superseded` 挪动、**两份报告的落盘**（不可变时间戳文件 + 刷新 `pilot_report.json`；成功与失败报告都算）——**每一处之后都要 `fsync` 其所在目录**。**报告那两条尤其不能漏**：它们是整条流水线最后的写，漏了等于前面所有耐久性功夫白做。`os.replace` 只保证**原子**（不会看到半截），**不保证耐久**（崩溃后仍在）；少了目录 fsync，按股事务会在断电后退化成「final 已落地而 manifest 无记录」——正是它要消灭的那个状态。崩溃注入须覆盖**目录项丢失**，不只文件内容截断 |
| 5j | **符号链接纪律覆盖路径分量（R13-F2）**：本工具自建的簿记目录（`<output>/.superseded/`）使用前须 `ensure_owned_dir()` —— `lstat` 判非符号链接、非真目录即拒。`os.replace` 会**穿过路径分量**解析，只查最后那个文件名不够 |
| 5h | **重试不改变消费顺序（R12-F1）**：`pool_order` 每项携带 `universe_idx`，pilot **按 `universe_idx` 升序消费**而非按追加顺序。U5 重试才成功时，它在消费序列里仍排在 U6 之前——最终选中哪 100 只必须只取决于 `seed` + 源快照，**不得取决于当时 SMB 是否抖动**（否则 `2026-07-27-qmt-plan4b-fetch-design.md` §4.3/`2026-07-27-qmt-plan4b-fetch-design.md` §4.4 全部 seeded 设计所声称的可复现性即告失效） |
| 5e | 源快照覆盖 K 线 CSV（R3-F3）：补拉默认对所有既有已拷文件重算源 sha256 并比对，任一不符即拒绝启动；`--skip-existing-verify` 可跳过但必须把 `source_verification` 标为 `partial` 并在报告人读摘要里显式声明「本次未校验既有文件」 |
| 6 | `import_qmt_stock` 提取后 CLI 可观察行为逐字不变（现有测试全绿） |
| 7 | pilot 每股至多 1 组（调 `generate_one_training_set` 恰好一次，全程不调 `generate_batch`） |
| 7b | **「每股至多 1 组」由集合级校验兜底，但分两类跑（R22-F2 + R24-F1）**：**危险形状**（某股 >1 行 / 有行不属本次池）**无条件**在任何 verdict 之前查，不符即 `FAIL_SET_CARDINALITY` + `cardinality_errors`；**完整性不变量**（总行数 == `target` 且 distinct == `target`）**只在准备判 SUCCESS 时**查，不符判**独立的 `FAIL_TARGET_MISMATCH`**（R25-F1：它与「危险形状」是两码事，共用一个 verdict 会让流程图/定义/schema 三处打架，且照定义实现时一个内存计数 bug 能带着 SUCCESS 出货）。**不得把正当的凑不够（`FAIL_POOL_EXHAUSTED`/`FAIL_FLOOR_UNREACHABLE`）转成任何基数类错误**——那会用一句泛泛的技术错误盖掉「哪一层穷尽、去补拉」这个唯一可行动的结论。断点续跑读到该股 >1 行时**不得随便挑一条继续** |
| 8 | 断点续跑：已有 `training_sets` 行的股**先在锁内验真**（文件存在 + 可读 + crc32 == `content_hash`）才记 `already_done` 计入成功 |
| 8b | 坏产物可恢复且不卡死（R1-F3）：zip 缺失/crc32 失配的行 → 不计入成功、锁内删行删残留 zip、重生成一次；**同一场景连跑两轮，第二轮必须干净通过**（原设计会让它永远失败，除非整库 `--reset` 丢光进度） |
| 8c | `unlink` 白名单（R2-F1 + R61-F2）：**只有三条同时成立**才可删——①**字面判据**：`os.path.normpath(file_path)` 的父目录**逐字等于** canonical `--output`（**绝不 `resolve()`**，它会跟随符号链接把别名放行）②**身份判据**：该父目录 `(st_dev, st_ino)` 等于钉住的 `out_fd` ③文件名匹配 `^{code}_\d+\.zip$`；删除本身走 `os.unlink(basename, dir_fd=out_fd)`；外部路径**绝不 unlink**（测试须断言目标文件事后仍存在）且**即便验证通过也不计入成功**；本文件 §4.3 的可读性检查同样先判归属，防止用别的输出树的产物给本次运行背书 |
| 9 | 达标判据 = 100 distinct **且** SH≥30 **且** SZ≥40 **且** BJ≥8 **且产物校验全过**；两阶段消费（先补地板再补总数）使等量轮转达不到 SZ≥40 的缺陷不可复现；池穷尽未达 → rc=1 + 完整诊断报告（非静默低产/凑数） |
| 9b | **verdict 先于报告落盘定稿（R4-F3）**：产物校验跑在定 verdict 之前；计数达标但有产物坏掉时，落盘的 `pilot_report.json` 必须写 `FAIL_ARTIFACT_INVALID` + `artifact_errors`，**不得写 SUCCESS 靠 rc 去纠正**（rc 只活在终端里，而 JSON 是持久交付物，§7 的诚实口径闸正建立在它之上） |
| 10 | `pilot_report.json` 含 `skip_reason_counts` 聚合（reason 取自既有结构化短语），且提前终止时 `terminated_early`/`termination_note` 如实标注未消费的层；另含 `fetch_failures` / `universe_sizes` / `source_verification`，使读者**无需翻 manifest** 就能分辨 `FAIL_POOL_EXHAUSTED` 是「市场上真没有更多合格股」还是「拷贝失败让池缩水」或「冻结宇宙还剩几百只没拉」 |
| 11 | 登记的 `file_path` 为绝对路径且逐条可读（模拟 B3 下载） |
| 12 | L2 真-PG：`verify_pilot_db_lifecycle.py` 与 `verify_pilot_e2e.py` 全 PASS，**含 session 锁可重入 + 四类陈旧库拒绝 + 坏产物两轮恢复 + 绑定失配的 `--reset` 破坏性分支（R12-F3）+ `pilot_stock_source` 结构闸的真 PG 复验**。绑定失配那条尤其不能只靠假件：它涉及 `CREATE`/`DROP DATABASE` 的真实时序与「目标库是否幸存」，守的正是不可逆销毁 |
| 12b | **`FAIL_REUSE_OVERFULL` 六处齐全（O4-F6）**：verdict 枚举 / 优先级表 0b3 / 各 verdict 判据 / 报告 schema `reuse_overfull` / §6.1 回归钉 / 本表——**逐处 grep 确认**，缺任一处即 FAIL（上一轮它只进了枚举与收尾清单，优先级表查不到它 → KeyError → 恢复指引整个走错）|
| 13 | 全部新增测试经 mutation 验证（中和守卫→测变红→复原），由控制者亲验 |
| 9c | **SUCCESS 内含「源已验」（R5-F2 + R8-F2）**：`source_verification == "partial"` 时即便计数/地板/产物全过，verdict 也只能是 `SUCCESS_UNVERIFIED_SOURCE`（**门槛为默认时**；门槛非默认则先命中 `SUCCESS_NON_SHIPPING`，R37-F2——两者都 `ship_eligible: false`，故本条要保的性质不受影响）；§7 的出货口径只认 `SUCCESS`（要求 `source_verification ∈ {snapshot, full}`）。杜绝「报告一边写 SUCCESS、一边自认没校验过源」 |
| 9d | **三级定级各自只声称能证明的、且每级凭据可机器核验（R8-F2 + R10-F3）**：`snapshot` ＝ `--snapshot-gmt-token` 与实际挂载信息核对通过 + 一趟复校 → 单一源代次**已证明**；`full` ＝ `--confirm-no-export-window` 显式声明（记入 `operator_attestation`）+ **两趟**全量复校一致 → 源在**验证窗口内**未变、**不等于**证明不可变，报告须原样带 `source_verification_caveat`；`partial` ＝ 凭据缺失或用了 `--skip-existing-verify`，什么都没证明。**凡写进「够格出货」判据的条件都必须有可持久化凭据，缺凭据即降级、不得默认成立**。两趟不一致 → 判失败非零码，**不得降级为 `partial`** |
| 9e | **退出码与出货闸对齐（R8-F3 + R32-F1）**：`rc == 0` ⟺ `verdict == SUCCESS` ⟺ `ship_eligible == true`；`SUCCESS_UNVERIFIED_SOURCE` = rc 2，**`SUCCESS_NON_SHIPPING` = rc 3**，其余 `FAIL_*` = rc 1。退出码是最容易被机器消费、最不容易被人细读的信号，不得与文档里的 verdict 语义脱节 |
| 14 | 交付表述不含「pilot 已完成」「100 股已出货」「真实数据接入完成」，**无例外**（本 plan 不定义出货凭据，`ship_eligible` 只是诊断字段；是否够格出货由后续凭据链 plan 定义）|


---

## 10. 后续（不在本 PR）

- 训练组作废/版本化（P3-D10①）：独立 plan
- 复盘/划线等其余 backlog：见各自 plan

---

## 11. 评审轮次记录

> **本文件已评 4 轮（O3 / P3 / P3r3 / O4）；本轮 O4 共 21 条。**
> 旧 spec `2026-07-26-qmt-plan4-pilot-shipment-design.md` 的 **R1–R97 账本**是本文件的历史前身。
> **O4 之后不再跑 spec 评审轮次**（user 2026-07-29 定案）：四轮 44→41→25→47 未收敛，
> 且约 22/47 是上一轮修改自身引入的损坏或未传播完的改动；剩余的真设计缺口交由实现期的
> **测试**证伪（本轮 4b 的 3 条平台事实就是评审**真跑代码**才发现的，散文推不出来）。

### O4 轮（2026-07-29，Opus 5 对抗性评审）

| 编号 | 级别 | 结论 | 核实 | 处置 |
|---|---|---|---|---|
> **⚠️ 本轮 21 条里有 13 条是「砍凭据链」那次字符串切除造成的结构损坏**（章节号重复、`## 7` 被粘进正文、
> §6.3 整节丢失、§5 表格被截断、§4.2 五处断句、收尾清单 ①e 残条）。
> **而 `tools/check_spec_consistency.py` 报全过** —— 因为它的 `sections()` 用 `^## N\.` 切章，
> **粘连标题让它自己的解析器失效**（`body(t,"7")` 恒空）。这是本会话第三次同一种失败
> （C5 锚点吞尾 → C7 收集不读 → 本次解析器被绕过），已加 C9「相邻重复短语」并把结构断言纳入收尾检查。

| O4-F1 | **critical** | §4.2 的「消费口径」块与不变量仍把 `pilot_report.json` 定义成出货凭据，而**§4 对 §7 有优先权** → 移出决定被文档自己的权威规则推翻，而堵这条路的验证器已移出、读侧**完全无防线** | 对读文档级不变量第 1 条，属实 | 已修：删消费口径块的出货措辞，改「诊断结论、不得作交付判断」；`ship_eligible` / `SUCCESS` / `pilot_source_verification` 四处口径同步 |
| O4-F2 | **critical** | 收尾清单（自称唯一权威）里留着 ①e 的**触发条件残条**（无步骤号、无 verdict、无动作）→ 照字面实现＝把刚移出的 ①e 复活成「拒绝启动」规则，凡跑出过 SUCCESS 的 `--output` 此后每次诊断重跑都被拒 | 结构损坏，已核 | 已修：删残条 + 补全 0c 的步骤列表 |
| O4-F3 | high | §9-14 仍**授权**「100 股已出货」，判据只有报告的 `ship_eligible` —— 全文唯一一句授予权限的话 | 属实 | 已修：改为「**无例外**禁述，是否够格出货由后续凭据链 plan 定义」|
| O4-F4 | high | §9-3e 整条是对已移出 `--verify-shipment` 的验收判据 → 无法判 P/F，且会让 writing-plans 派生出「实现验证器」的任务 | 属实 | 已修：删除 |
| O4-F5 | high | §5 表里残留被删表格行的碎片（`①b 取不到 LOCK_SH → rc=5`）：截断 markdown 表（后 9 行脱表）、引入 §4.4 之外的退出码、挂了条不存在的共享锁路径 | 结构损坏，已核 | 已修：删除 |
| O4-F6 | high | `FAIL_REUSE_OVERFULL` 只进了 verdict 字符串与 §5：**优先级表没有它**（→ KeyError → 兜成 `FAIL_INFRASTRUCTURE`，恢复指引整个走错）、判据没有、`reuse_overfull` 不在 schema、§6/§9 无出口 | grep 四处确认 | 已修：优先级表补 0b3 + schema 补字段 + §6.1 回归钉 + §9-12b 六处齐全的验收行 |
| O4-F7 | high | §4.2 与 §4.3 对「`export_log_sha256` 可为 null 的档数」直接打架（两种 vs 三种），而 §6.1 有钉子钉死三种 | 对读，属实 | 已修：§4.2 改三种 |
| O4-F8 | high | §6.2 被截断成 2.5 项（应 5 项）、§6.3（L3 人工验收）**整节删除**、`## 7` 被粘进 §6.2 第 3 项 → §7 不再是标题 | 结构损坏，已核 | 已修：补回 L2 第 3/4/5 项（含守 `DROP DATABASE` 的绑定失配三跑）+ 新写 §6.3 L3（诊断口径）+ `## 7` 拆回行首 |
| O4-F9 | medium | §8 风险表仍把「出货凭据改为经 `--verify-shipment` 读取」当缓解手段 → §9-2r 形式满足、实质假陈述 | 属实 | 已修：改为如实登记「读侧无防线」为残余 |
| O4-F10 | medium | 标题 / 作用域 / §2 目标三处仍把「出货凭据链」列为本 PR 范围 → writing-plans 会直接排出该任务 | 属实 | 已修：三处 + §2 非目标 |
| O4-F11 | medium | 「那三道闸」的计数与实际列出的两道不符（三处）→ 做机械检查③ 的人会判「序列缺一道闸」把 ①e 加回来，或放宽 R91-F2 | grep 三处 | 已修：改两道并重述 R91-F2 的理由 |
| O4-F12 | medium | §0 / §5 / §9-0 引用的「§4.2 顶部完整论证」块本身有 5 处断句，已不可读 | 结构损坏，已核 | 已修：用 commit `0ef0e9a` 的完整 message 重写该块 |
| O4-F13 | medium | 收尾规则按语仍宣称收尾要回答**两个**前置问题，第二个是已删掉的「会不会白白废掉可出货凭据」；且自身断句 | 属实 | 已修：改为「只剩一个纯前置问题」|
| O4-F14 | medium | `assert running_published` 的**失败动作未定义**，且 `assert` 在 `python -O` 下被剥离；检查点 1 的位置锚点按 R96-F1 的定义在 ①a…⑥ 之间处处成立 | 属实（本文件自己的 R57-F1 判据即「失败动作决定它能用在哪一段」）| 已修：改显式检查 + 非零码 + 不写报告；锚点改为「①d/⑥ 发布 `RUNNING` 之后、建或复用库之前」|
| O4-F15 | medium | 4b 仍把 `--verify-shipment` / `①e` 列为「由 4c 定义的名词」（工具的 C1 只校验 `文件 §X` 形式，抓不到名词级断链）| grep 确认 | 已修（记在 4b O4-F15）|
| O4-F16 | low | `report_schema_version` 仍在 schema 但**已无读者**，注释断句，§4.3 与 §11 账本互相矛盾 | 属实 | 已修：保留字段 + 写明「本 plan 只写不读，读侧版本闸在后续 plan」|
| O4-F17 | low | `threshold_override` 恒存在的理由写的是「KeyError → rc=4」，而 rc=4 是已移出验证器的退出码，句子还断着 | 属实 | 已修：理由重写为诊断口径 |
| O4-F18 | low | schema 自称「优先级表第 5 行注明它是第二个产生源」，而第 5 行**没有**这样的注明 | grep 确认 | 已修：第 5 行补注，删自指句 |
| O4-F19 | low | 收尾清单为已取消的 ③a 留了条件出口「（若序列中存在该步）」 | 属实 | 已修：删除 |
| O4-F20 | low | §6.1 最后一条回归钉有标题、有冒号、**零内容**，且主题已被 R69「只增不毁」取消 | 属实（切除前也是空的，旧伤）| 已修：换成 `FAIL_REUSE_OVERFULL` 的回归钉 |
| O4-F21 | low | §8 章节号 `## 8` 出现两次 | 结构损坏，已核 | 已修：去重 |


**历史依据**：旧 spec 的 **R1–R97 账本（201 条 codex finding + 3 处自查补，全部为真、全部已修，codex 从未 approve）**。

**切分后本文件的评审从 R1 重新计数。**

### P3（第二轮 Opus 评审，needs-attention，16 finding，全部接受并已修）

**处置流程按 `superpowers:receiving-code-review`：先逐条 VERIFY 再 IMPLEMENT。**

| # | 级别 | 结论 | 处置 |
|---|---|---|---|
| P3-F1 | high | **同一谓词在两个消费者上安全方向相反** —— 验证器 `False` = 拒绝出货（安全），①e `False` = 放行（危险）→ 每收紧一次谓词就扩大一次「不受保护」的集合 | 拆两个谓词 + 不变量「保护集合 ⊇ 承认集合」。**⚠️ 该整块已于第三轮随凭据链移出本 plan** |
| P3-F2 | high | `contract_version` 不在 schema 且与 4a 的库级同名 | 改 `report_schema_version`。**已随凭据链移出** |
| P3-F3 | high | crc32 只写在谓词里，步骤表 / 「不证明」块 / 次序表三处都否认它 | 三处同步 + 补 rc 出口。**已随凭据链移出** |
| P3-F4 | high | O3-F3 的修法在首次使用支重犯它自己要修的错 | 切分判据改「本进程有没有发布过 `RUNNING`」（**保留**，见 P3r3-F7 的后续更正）|
| P3-F5 | high | ⑤b′ 排在 ⑤b 之前 → 在库还没过归属闸时就查它，还劝操作者 `--reset` 别人的库 | 移到 ⑤b 之后、只在复用分支跑（**保留**，物理次序由 P3r3-F11 真正落实）|
| P3-F6 | high | ①e 的两条出路在其余闸下都是死路 | 新增 `--repair-artifacts`。**已随凭据链移出**（第三轮证明它在动机场景里是 no-op 且实为破坏性）|
| P3-F7 | high | `output_path_diverged` 降级为「不改变 verdict」后不在谓词里 → `SUCCESS` + 路径分叉可拿 rc=0 | 写死「非 null ⟹ verdict 必为 `FAIL_ARTIFACT_INVALID`」（**保留**，四处口径由 P3r3-F10 统一）|
| P3-F8…F10b | medium/low | 时间戳粒度、`⑤b′`、`fatal_error` 两套形状、`!owned` 分支失败路径、`.superseded` 孤儿、§6 缺 L2、`effective_target`、`threshold_override` 恒存在 | 逐条已修；其中 `effective_target` 随凭据链移出，`threshold_override` 恒存在作为**诊断字段**保留 |

**P3 轮的教训**：16 条里 **4 条是 O3 轮修法引入的**、**6 条是 O3 轮没修干净的**。这个比率是后来
「把凭据链整块移出」那个决定的直接依据。

### O3（Opus 5 对抗性评审，needs-attention，16 finding + §0 定案，全部接受并已修）

**处置流程按 `superpowers:receiving-code-review`：先逐条 VERIFY 再 IMPLEMENT。**

**§0 定案（user 2026-07-27 拍板）：方案 A（保留 8 部件）+ crc32 自证加固。**
**评审驳回了我推荐的方案 B，我核过它的反例成立**——run2 是一次**完全诚实的尝试**（带 `--source` + 默认门槛），
重生成的 zip 覆盖了 run1 的部分产物后断电：A 下 `pilot_report.json` 停在 `RUNNING` → rc=5「结论未知」（正确）；
**B 下 run2 从未写出时间戳报告，最新的仍是 run1 的 `SUCCESS` → rc=0，而产物是两代混合、库是半建的**。
**B 自己新开了一条假凭据路径，且不需要任何外部写者**；它还把「谁更新」交给写者时钟（NTP 回拨即可翻转次序）。
**我原先说「六条 finding 的成因同时消失」是错的**：①e 与 ①a′ 在 B 下仍然必须存在。

| # | 级别 | 结论 | 核实 | 处置 |
|---|---|---|---|---|
| O3-F0 | — | §0 定案的加固项 | — | `--verify-shipment` 增 crc32 自证；**两条残余（证不了库还在 / 不防外部写者）写进 §7** |
| O3-F1 | high | `--verify-shipment` **只把 `ship_eligible` 当外部数据重校**，却把 §7 声称 SUCCESS「内含」的另外三件事当可信推论 → 一份 `source_verification: "partial"` 的 `SUCCESS` 能拿到 rc==0 | §7 确写「已内含…两项」而验证器不查 | `is_shipping_credential` 逐项补齐；**并加 `contract_version` fail-closed** —— 见下方对修法的异议 |
| O3-F2 | high | ①e 漏了「**绑定必然不符**」这一整类，而判据所需的两个值 ①e **已读在手里**（零额外 I/O）→ **一个字的 `--seed` 笔误就废掉唯一凭据** | b1–b4 确无身份维 | 补 b5/b6，并把判据改成「**凡在 ①d 之前就能确定某道后续闸必然失败的输入，都属于 (b)**」 |
| O3-F3 | high | 分叉检查第一处写「立即拒绝启动，**此时尚未改动任何状态**」——**对已归属支是假的**（①d 早发布过 `RUNNING`），且这条出口**从来没进过收尾清单** → 永久停在 `RUNNING` | grep 1037 行属实 | 三处检查点进收尾清单并按 ①d 切开；删掉那句不成立的话。**是 R89-F1「清单自称唯一权威却漏了出口」的第二次** |
| O3-F4 | high | 收尾清单把 ② 一律映射 `FAIL_MANIFEST_INVALID`，与 ② 自己的 `stopped_reason` 分支正面冲突 → **一次源树逃逸被报成「manifest 畸形」** | grep 397 行属实 | 拆三行；**机械检查补一条：一个步骤能产出 >1 个 verdict，清单里就必须有 >1 行** |
| O3-F5 | medium | `try_one` 收尾 `unlink` 对挪动三分支不是全函数（第三档 `FileNotFoundError`；「哈希不符」那档会**删掉一份从未挪进去、也从未验过归属**的文件）| 分支 ③ 明写「缺失即忽略」而本处没有 | 缺失即忽略；哈希不符不得 unlink。**是 R87-F2 同一行 unlink 的第二条未覆盖边** |
| O3-F6 | medium | `output_path_diverged` **结构上写不出来**（verdict 与优先级表冲突；`{stock_code, file_path, error}` 装不下「还没有任何股」时的分叉）| 两处均属实 | 提为**顶层字段**，**不改变 verdict**，只作附加事实 + stderr |
| O3-F7 | medium | 报告 schema 不闭合：`preserved_superseded` 根本不在 schema 里；`stale_artifact_missing` / `duplicate_active_rows` 不在枚举 → **一次合法 SUCCESS 会被 `schema_valid()` 判 rc=4「凭据损坏」** | grep：全文 3/2/1 次，schema 内 **0 次** | 三个字段补进 schema 与枚举；连带补 4b 要求的 `inflight_rollbacks` / `fetch_stopped_reason`（O2-F11）|
| O3-F8 | medium | 时间戳文件名的粒度未定义且无撞名规则 → 两次亚秒级失败撞名 → 违反不可变性或**递归到同一失败** | `<UTC>` 确无定义 | 微秒级 basic ISO + `O_CREAT\|O_EXCL` 递增后缀 + 该重试不得递归 |
| O3-F9 | medium | 复用库活跃行数 > `target` → 永久 `FAIL_TARGET_MISMATCH`，**带内无出路**（只能 `--reset` 丢光进度，而那正是允许复用的唯一理由）| 只断言了 `sum(floors) <= target` | 加 ⑤b′ 只读前置断言，**在动第一根手指之前**给可行动结论 |
| O3-F10 | medium | 跨文件引用大面积损坏 + §4 重号 | **是我切分时造的** | 已在 `ac0aec8` 重建 |
| O3-F11 | low | §5 把 rc=4 那一档的提示文本挂到了 rc=5 上 → 操作者去查「路径传错没有」，真相是「等它跑完」| 属实 | 两档文本各归各位 |
| O3-F12 | low | `fatal_error` 在同一份「schema 唯一权威」里有两套不兼容形状（报告两字段 / manifest 四字段）| 属实 | manifest 那个改名 `fetch_fatal_error`；两处各加限定 |
| O3-F13 | low | `!owned` 分支只写成功路径，生成失败时该股**既不计数也不留 skip 记录** | 其余三处同构路径都有 | 补失败分支 |
| O3-F14 | low | `.superseded` 孤儿从不清理，后来的同名挪入**静默覆盖**报告指给人看的那份（候选起点仅 3~4 个，撞名很可能）| 属实 | 文件名带 `report_id` 前缀；清理责任写明「本工具从不清，人工清」 |
| O3-F15 | low | §6 **缺整个 6.2**，而 §9-12 把 L2 全 PASS 列为验收判据 | grep：只有 6.1 / 6.3 | 补 §6.2，五项逐条落地 |
| O3-F16 | low | 4b 源边界闸第 2 条的 inode 半边在「首次使用」支不可执行 | 属实 | 已在 4b 的 O2-F5 分模式表里处置 |

**⚠️ 我对 O3-F1 的修法提出过异议并做了调整**：评审建议把七八个事实**枚举**进 `is_shipping_credential`，
而 R26-F1 判过「枚举贡献者会随新增闸静默失效」。**finding 本身成立**（读侧无法派生、只能逐项检查），
但为了兜住枚举失效，**我加了 `contract_version` fail-closed**：验证器遇到不认识的版本一律 rc=4。
**这把失效模式从「静默漏检」换成「明确拒绝」**——新增判定闸时旧验证器不会假装通过。

⚠️ **本文件是三份里最难的一份**：R74–R97 共 47 条 finding 里 **25 条落在本文件承载的「报告/凭据链」上**，
且**其中约 10 条是前一轮修复自己引入的**。故 §0 把「要不要砍部件」作为**待决项**摆在最前面——
**在这条链上继续加固之前，先确认它该不该这么复杂。**
