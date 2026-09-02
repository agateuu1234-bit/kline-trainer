# QMT Plan 4b 设计 —— SMB 真拉取（共享地基 + 预筛 + 分层储备池 + 幂等拷贝）

> **本文件由 `2026-07-26-qmt-plan4-pilot-shipment-design.md` 切分而来**（映射见 `2026-07-27-qmt-plan4-spec-split-map.md`）。
> 旧 spec 的 **R1–R97 评审账本原样保留在那份文件里**，是本文件全部结论的历史依据；**它本身已不再作为实施依据**。
>
> **本文件的作用域 = PR 4b**：`export_log` 预筛、分层 seeded 储备池、幂等拷贝 + manifest + 字节校验，
> 以及**三个 PR 共用的文件系统地基**（`open_root` / `open_under` / 归属标记与认领协议 / 耐久提交协议 / 锁纪律）。
>
> **⚠️ 共享地基定义在本文件 §4.1**，4c spec 引用它、不复述（4a 不需要——它完全不碰目录）。
> `--output` 的归属与锁**与 `--dest` 同规格**，差异只有 `EEXIST` 那一档（见 §4.1 末尾的对照表）。

- **⚠️ 章节权威性（文档级不变量）**：
  1. **§4 是唯一权威规范**。§5（错误处理表）、§6（测试策略）、§9（验收标准）都是它的**导出视图**；
     任何冲突一律以 §4 为准，且必须把导出视图改到与 §4 一致。
  2. **过程性规则只在 §4 定义一次**，其余散文可引用、**不得复述过程**。
  3. **跨 spec 引用必须写成「见 `<文件名>` §X」**——三份文档的 §号各自重排。
  4. **verdict 枚举与报告 schema 的唯一权威在 4c spec**；本文件只声明「我会产生
     `FAIL_SOURCE_BOUNDARY` / `FAIL_STAGING_INTEGRITY` / `FAIL_MANIFEST_INVALID` 及其错误码」，由 4c 收口。

- **⚠️ 本文件出现但由 4c 定义的名词**（一律**引用不复述**，见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md`）：
  `pilot_report.json` / `ship_eligible` / `output_binding` /
  准入序列步骤号 **①…⑥**（含 `①a` 钉 `out_fd` 取 `LOCK_EX`、`①d` 发布 `RUNNING`）/
  ⚠️ **`--verify-shipment` 与 `①e` 出货凭据保护闸已随出货凭据链移出后续独立 plan**（4c §0），
  **本轮不涉及**（O4-F15：留在名词表里会让实施者顺着「见 4c」去找一个已不存在的定义）/
  `try_one` 伪代码与 `.superseded` 先证后毁协议 / verdict 枚举与报告 schema。
  **本文件提到它们只为说明「4b 的某条纪律为什么存在」，不构成对它们的定义。**

- **⚠️ 每轮改动的收尾必做（五条机械检查，作用域限本文件）**：
  1. **新错误码** → ①进了哪个**字段枚举**？②它触发哪个 **verdict**，**4c spec 的权威定义处列了吗**？
  2. **新参数/枚举项** → 逐个 grep 它的**全部调用点/登记处**，数量对不上就是漏了。
  3. **新闸** → 把闸序列当有向图，**逐条出边检查有没有控制流能绕到它后面去**。
  4. **改规则** → 把该规则的关键词**全文打印逐条读完**——计数回答不了「它们说的是不是同一件事」。
  5. **新持久字段/信号** → **谁写、谁读、谁清**（清它与「证明已恢复」是不是同一次原子提交）。
  > **扫描结果由脚本打印成一行可粘贴文本、照抄进 §11，不许凭印象写**（旧 spec 里我连犯 4 次）。

- **⚠️ 对象 × 维度矩阵（机械检查用；旧 spec R73→R82 逐步立起来的）**：
  - **三个目录**：`--dest`（staging）↔ `--output`（4c）↔ **`--source`**。
    **`--source` 长期不在清单里，因为它「只读、不属于我们」——而信任边界不是按「谁拥有」划的，
    是按「哪些字节被当成证据」划的。** 它不适用维度①（归属证明），但②③④⑤全适用。
  - **两个工具**：`qmt_fetch` ↔ `qmt_pilot`（各有权威序列，纪律要写进各自那一节/那一份 spec）。
  - **五个维度**：①归属证明 ②inode 钉死（**且必须填「在第几步」**）③**逐段无跟随**（从 `/` 到叶子的每一个分量，
    **含建立信任边界的那一次 open 本身**）④耐久提交 ⑤崩溃恢复（**取消一条机制时先问它原本还顺带保证了什么**）。

---

## 1. 背景（裁剪到本 PR）

QMT 导出在 Windows 机上，通过 SMB 共享（`//agate@192.168.5.151/QMT_Export`）暴露。
4b 要做的是：**把这份权威导出的一个子集，可复现、可续跑、可证伪地拉到本机 staging**，
并留下一份 manifest，使 4c 能在**不重新信任源**的前提下判断「我消费的这批字节到底是不是当初那批」。

三条硬约束塑造了整个设计：
- **源不可控**：Windows 机由控制者手工开机、手工挂载；445 探测不通时全流程不可用。
- **磁盘只有约 30 GiB 余量**：不做全量镜像（27 GiB 会把盘撑到 98%），必须有硬性字节上限。
- **可复现性是出货凭据的一部分**：同一 `--seed` 必须选出同一批股、同一顺序，否则 4c 的报告不可复核。

## 2. 目标与非目标

**目标**
- `export_log` 预筛：零网络成本剔掉「数学上必然被拒」的股。
- 分层 seeded 储备池（SH/SZ/BJ 各自配额与游标），**顺序只从 manifest 读、不重推**。
- 幂等拷贝：**按股事务**、`.part` → `fsync` → `os.replace`、内容哈希复校、崩溃可回滚重试。
- **三个目录的信任边界地基**：逐段无跟随、inode 钉死、归属标记、耐久提交、锁纪律。

**非目标**
- 不做挂载/凭据逻辑（`mount_smbfs` 由控制者人工执行，密码不进代码/仓库/记忆）。
- 不做增量同步/断点续传协议 —— 幂等 + 游标已足够。
- **不定义 verdict 与报告 schema**（4c 的唯一权威）。

---

## 4. 组件设计

### 4.1 共享地基（三个 PR 共用；4c 引用本节、不复述）

`qmt_fetch.py` 只接 `--source <已挂载的只读路径>`，**不含任何挂载/凭据逻辑**。挂载由控制者在验收时人工执行：

```
mount_smbfs -o rdonly //agate@192.168.5.151/QMT_Export /Volumes/QMT_Export   # 密码交互输入
```

**`-o rdonly` 是强制要求，不是建议（R4-F4）**：`rdonly` 是 macOS `mount(8)` 的文档选项名（等价于 `mount -r`），效果是「连 super-user 也写不了」。原设计只在散文里把挂载点称作「只读」，却给了一条**可写**的挂载命令 —— 那只是个愿望，不是边界。

**三个根路径本身必须逐段无跟随地打开（R75-F2，`--dest` / `--staging` / `--output` 同规格）**：
`os.open(<root>, O_DIRECTORY|O_NOFOLLOW)` 的 `O_NOFOLLOW` **只保护最后一段**。`--output /a/b/out` 里的 `a`、`b` 若是符号链接（或在 pin 之前被换成符号链接），**内核照样跟随，于是被钉住的是另一棵树的 inode**——此后所有 `*at` 纪律都忠实地作用在**错的目录**上：报告、zip、staging CSV 全部写进去，而工具坚信信任边界已经闭合。**pin 本身是这套边界的起点，起点被绕过则其后一切纪律归零。**

```
def open_root(abs_path, *, create_leaf=False):
    # abs_path 必须是绝对路径；不做 realpath()（那正是「跟随」）
    fd = os.open("/", O_RDONLY|O_DIRECTORY)          # 从根开始
    *dirs, leaf = split_components(abs_path)          # 拒绝空分量 / "." / ".."
    # ⚠️ 入口处先对 --source/--dest/--output 做**纯字符串**规范化（O4-F17）：去尾斜杠、折叠重复 "/"；
    #    **不得 realpath()**（那正是「跟随」）。仍拒绝相对路径与含 "." / ".." 的路径，
    #    且「含 . / ..」与「含符号链接分量」两条提示必须分开——shell 目录补全默认补出尾斜杠，
    #    `--dest /Volumes/staging/` 会撞「拒绝空分量」，而本项目的操作者是非程序员。
    for d in dirs + ([] if create_leaf else [leaf]):
        nxt = os.open(d, O_RDONLY|O_DIRECTORY|O_NOFOLLOW, dir_fd=fd)   # 逐段
        os.close(fd); fd = nxt        # 符号链接或非目录分量 → ENOTDIR（实测）；叶子文件符号链接 → ELOOP：一律拒绝
    if create_leaf:                   # 首次使用：认领动作也走 dir_fd
        os.mkdir(leaf, 0o700, dir_fd=fd)              # EEXIST 语义与 本文件 §4.1 一致
        nxt = os.open(leaf, O_RDONLY|O_DIRECTORY|O_NOFOLLOW, dir_fd=fd)
        os.fsync(fd)                  # 父目录耐久（R45-F2）
        os.close(fd); fd = nxt
    return fd                          # 调用方全程持有
```
- **`--output`**：①a（已归属，`create_leaf=False`）与 ⑥（首次使用，`create_leaf=True`）都走它。
- **`--staging` / `--dest`**：①b 第 1 步与 `qmt_fetch` 的对应位置都走它。
- **`--source`（R82-F1）**：`qmt_fetch` 与 `qmt_pilot` 在使用它之前都走 `open_root(--source)`
  （`create_leaf=False`——只读、且不是我们的目录），此后源侧一切读经 `open_under(src_fd, …,
  create_dirs=False)`。它**没有**归属标记与 `flock`（那两样属于「我们的目录」），
  但**逐段无跟随与 inode 钉死一视同仁**。
- 路径含符号链接分量 → **拒绝启动**，stderr 提示改传**完全解析后的路径**（本工具不替操作者解析——`realpath()` 恰恰就是「跟随」，用它等于自愿放弃这道闸）。

> **这与 R74-F2 是同一条纪律的两半（R75-F2 修正）**：R74-F2 管的是**根之下**的相对路径（`open_under` 逐段走），本条管的是**根本身**（`open_root` 从 `/` 逐段走）。我上一轮刚把「逐段无跟随」写进对象 × 维度矩阵的维度③，**却只把它应用到了「pin 之后的读写」，没有应用到「pin 这个动作自己」**。判据补进维度③：**逐段无跟随必须覆盖从 `/` 到叶子的每一个分量，包括建立信任边界的那一次 open 本身。**

**目标目录也要证明归属，不只证明形状（R7-F3 + R8-F1）**：`--dest` 与 `--output` 原先只要求「绝对路径 + 与 source 不重叠」，那只是路径**形状**。指错一个已有内容的目录，`qmt_fetch` 会用 `.part → os.replace` 覆盖里面的 CSV、`qmt_pilot` 会往里写 zip —— 全程没有任何一步证明过「这个目录是我的」。故首次使用时须**凭标记文件证明归属**：

- **`--dest`**（与 `--output` 同规格，R36-F2）：
  - **首次使用 / 认领协议（R64-F1 重定；R66-F2 收口为 fail-closed）**：
    1. **`open_root(<dest>, create_leaf=True)`** —— 从 `/` 逐分量 `O_NOFOLLOW` 走到父目录，再 `os.mkdir(leaf, dir_fd=父fd)`：**`mkdir` 是唯一可移植的目录级独占创建原语**（已存在即 `EEXIST`），而逐段走保证「独占创建」发生在**验过的那个父 inode** 里（R75-F2）；
    2. 取 `flock` → 写 `.staging_owner.json`（`{tool: "qmt_fetch", seed, dest}`）+ `fsync(文件)` + `fsync(<dest>)` + `fsync(父目录)`。
    **`EEXIST`（路径已存在）→ 只有两种结局**：
       - **有合法标记** → 复用 / 引导态（见下）。**但必须整体退回复用路径的准入序列**（R91-F2 的
         `--dest` 侧对称补，自查：`--output` 那一侧已收紧为「一律拒绝」，`--dest` 这一侧
         结论不同是因为**它没有出货凭据可毁**，且复用路径本就要过「归属标记三项 + manifest `seed`
         + `.staging.lock`」三道闸 —— **但绝不能就地继续首次使用的流程**：那会跳过 `.staging.lock`
         的取得，两个 `qmt_fetch` 就能同时往一棵 staging 里写。**判据与 `--output` 侧同源：
         一条分支若跳过了另一条分支的准入序列，就不能在中途「并」进去**）；
       - **没有合法标记**（无论目录是空是满）→ **拒绝启动**。**在打印 rmdir 建议之前，必须先试
         `flock(LOCK_EX|LOCK_NB)`（O2-F9）**：
         **探测形态由 P2-F1 写死**（三个分支一个都不能省）：
         ```
         fd = open_root(<dest>, create_leaf=False)              # 逐段无跟随
         lk = openat(fd, ".staging.lock", O_RDWR|O_NOFOLLOW)    # ⚠️ **绝不带 O_CREAT**
         # ELOOP / fstat 非普通文件 → 拒绝启动（R72-F2）；ENOENT → 分支 ③
         flock(lk, LOCK_EX|LOCK_NB)                             # 取得后立即释放，不写任何内容
         ```
           · **取不到锁** → 报「**另一次运行正在认领该目录，请等待或确认**」，**绝不建议 `rmdir`**；
           · **取得锁** → 才可能是残骸。⚠️ **此时目录里必然有 `.staging.lock`（正是我们刚打开的那个），
             裸 `rmdir` 必撞 `ENOTEMPTY`（已实测）**（O4-F6）。故指引必须是：
             **先列出目录内容供操作者核对**，再给
             「若确认除 `.staging.lock` 外为空：`rm -f <dest>/.staging.lock && rmdir <dest>`」；
           · **`ENOENT`（锁文件不存在）** → 这是**崩在 `mkdir` 与 `openat` 之间**留下的**真空目录**，
             也是**唯一 rmdir 能干净成功的一档**（O4-F6）→ **先复查目录确为空**，再给 `rmdir <dest>` 指引。
             （原文把这两支的指引写反了：唯一能 rmdir 的那一档不给指引，给指引的那一档 rmdir 必然失败。
             §4.1 那句「代价是极偶发地手工 `rmdir` 一次」据此修正。）
         > **为什么必须不带 `O_CREAT`、且 `ENOENT` 必须单独成一支（P2-F1 修正）**：
         > **(a) 带 `O_CREAT` 会在一个已被证明不属于我们的目录里造文件**——`--dest` 打错成 `/Users/me/Documents`
         > 时，工具先落下 `.staging.lock`，**然后建议 `rmdir`，而 `rmdir` 恰恰因为我们刚造的这个文件而
         > `ENOTEMPTY`**，修复指引自己把自己堵死；真正的残骸空目录也再 rmdir 不掉。这直接违反 §5 明写的
         > R65-F1（「取锁要写文件，打错字的 `--dest` 会先在未经证明的目录里落下锁文件」）。
         > **(b) 不带 `O_CREAT` 时 `ENOENT` 有二义**：残骸空目录里本来就没有锁文件；而 A 的时序是
         > `mkdir` →（建锁文件）→ `flock`，**B 落在这两步之间看到的也是 ENOENT** —— 二者不可区分。
         > 若把 ENOENT 并进「取得锁」那一支照旧建议 rmdir，**O2-F9 声称关掉的洞原样还在**。
         **为什么必须加这一步**：原文为 fail-closed 辩护时说那个窗口「其间无任何 I/O」——**这是错的**，
         窗口里至少有一次 openat+flock、一次写、三次 `fsync`（目录 `fsync` 在负载下可达秒级）。
         于是 A、B 两次 `qmt_fetch` 先后启动时，B 会读不到标记 → 建议操作者 `rmdir`；
         **操作者照做后（此刻目录确实空的，`rmdir` 会成功），A 持有的 `stg_fd` 仍指向那个已被 unlink 的 inode**
         —— 此后几百个 CSV、manifest、全部 `fsync` 都会「成功」写进一棵**不可达**的树，
         **A 以 rc=0 退出并宣称 staging 就绪，而磁盘上什么都没有**。
         **⚠️ 我原先那句「取锁不会在打错字的路径上凭空造文件」是错的（P2-F1）**——`EEXIST` 只证明**目录**存在，
         **不证明 `.staging.lock` 存在**；带 `O_CREAT` 的探测会当场造出它。现形态（只读探测、不带 `O_CREAT`）
         才真正不违反 R65-F1。

    > **为什么这一档只能 fail-closed、不能自动认领（R66-F2 修正）**：我先后试过两版自动恢复，都不成立。
    > - **R64-F1 版**「无标记空目录即判为本工具残骸」：**「我崩在半路留下的空目录」与「操作者预先建好的空目录」在磁盘上完全一样**，同一节前脚说「预建空目录一律拒绝」（R30-F2 / R36-F2）、后脚说「空目录可认领」，两条规则对同一磁盘状态给出相反结论。
    > - **R65-F2 版**「父目录先写意图记录，有记录才认领」：**意图记录证明的是「我打算建」，不是「我建成了」**。崩在「写记录之后、`mkdir` 之前」时记录已在而目录尚无；若此时操作者或别的进程建了那个空目录，重跑就会拿着自己的意图记录去**认领一个别人造的目录**。写完标记后的「复查目录为空」也救不了——它只证明「里面没有文件」，**不证明「这个目录是我造的」**。
    >
    > **根因是：`mkdir` 之后的目录不携带任何出处信息，而崩溃恰恰抹掉了内存里那份「是我建的」。** 除非父目录本身是一个由不可伪造机制证明归属的工作区（本 plan 里它是操作者随手指定的路径，不是），否则这条信息在崩溃后就是不可恢复的。**造不出证据时，唯一诚实的做法是拒绝并交给人** —— 这个窗口只有 `mkdir` 与紧随其后的写标记之间那一瞬（其间无任何 I/O），代价是极偶发地手工 `rmdir` 一次；而自动认领的代价是**可能静默吞掉别人的目录**。**宁可要一次人工介入，不要一次静默越界。**

    > **为什么不能用 `os.rename` 做「不覆盖发布」（R64-F1 修正）**：R62-F2 我写的是「临时目录内写好标记 → `os.rename` 到最终路径，**目标已存在则失败**」—— **那句话是错的**。POSIX 的 `rename(2)` 在「源是目录、目标是**空目录**」时**会把目标替换掉**，macOS 同此。于是一个**预先建好的空 `--dest`/`--output`（或并发抢建的）会被静默删除并认领**，恰好把 R30-F2 / R36-F2 要堵的归属洞重新打开，还顺带删了别人的目录。真正的不覆盖原语是 Linux 的 `renameat2(RENAME_NOREPLACE)` / macOS 的 `renameatx_np(RENAME_EXCL)`，Python 都不直接暴露，**不值得为它引入 ctypes 依赖**。
    >
    > **这是「形容词 + 具体调用」不符的第二次**（第一次是 R53-F1 的「非阻塞」配 `pg_advisory_lock`）：我给 `rename` 安了一个它并不具备的语义。**凡断言某个系统调用「已存在就失败 / 原子 / 不跟随链接」，都必须对着 man page 逐条核实。**
    >
    > **改回 `mkdir` 之后，R62-F2 那个崩溃窗口靠「空目录残骸 + 复查」收口**：`mkdir` 独占创建保证的是「创建那一刻它不存在」；而「无标记空目录」这一档，**R66-F2 已判定不可自动认领、一律 fail-closed**（`mkdir` 之后的目录不携带出处信息，「我崩在半路留下的」与「别人预建的」在磁盘上完全一样；复查只证明「里面没有文件」，**不证明「这个目录是我造的」**）。
  - **⚠️ 第三种状态：已归属但未初始化（引导态，R60-F3）** —— 崩在「归属标记已耐久落盘」与「第一份 `fetch_manifest.json` 提交」之间时，目录**既不是首次使用**（路径已存在）**也不可复用**（没有合法 manifest）。若不为它留出路，`qmt_fetch` 会在此**永久拒绝启动、只能人工清理**，正好违背本 plan 的可重试目标。
    **判据与处置**（全部在 `.staging.lock` 之内做）：`.staging_owner.json` 存在且 `tool`/`dest` 相符、**`seed` 等于本次 `--seed`**，而 `fetch_manifest.json` **不存在** →
    - 目录里若存在**任何完整的 K 线 CSV**（非 `.part`）→ **拒绝启动**并要求人工处理：按新的提交顺序（首份 manifest 先于任何 K 线拷贝，R38-F1）那是**不可能出现**的状态，说明现场超出了本工具的理解范围；
    - 否则 → **判为引导态，允许从头继续初始化**：只清理**已知的引导产物**（`export_log.csv`、任何 `*.part`、`.inflight.json`），然后照首次使用的流程往下走。
    - `seed` **不等于**本次 → 仍然拒绝（那是别人的 staging）。
  - **复用**：路径已存在，且含该标记（`tool` + `dest` 相符）**与** `seed` 相符的合法 `fetch_manifest.json`。
  - 其余（**包括预先建好的空目录**）一律拒绝启动。

  > **为什么 `--dest` 不能只要求「为空」（R36-F2 修正）**：R30-F2 已经论证过「判空 → 声明」之间的窗口关不死——**但我只把结论应用到了 `--output`，漏了 `--dest`**。而 `.staging.lock` 只约束**尊重它的工具**，它**证明不了这个目录是 `qmt_fetch` 创建的**：一个指错的空目录会被静默认领，随后被灌进 `.staging.lock`、几百个 CSV 与 `fetch_manifest.json`；在 manifest 原子替换之前出现的外来文件也可能被覆盖或混进这棵无主的 staging 树。**同一条安全推理必须应用到它适用的每一个对象上。**
- **`--output`**：两种合法情形（R30-F2 收紧）——
  - **首次使用 / 认领协议（R64-F1 + R66-F2 + R91-F2）**：**`open_root(<output>, create_leaf=True)`**（逐段无跟随走到父目录，再 `mkdirat` 独占创建，R75-F2）→ 取 `flock` → 写 `.pilot_output.json` → `fsync`。**撞 `EEXIST` 一律拒绝启动、一个字节都不写**（R91-F2 由「两种结局」收紧为一种）：有合法标记时也拒绝，提示「另一次运行在本次启动之后创建了它，请原样重跑」——**重跑会走完整的已归属准入序列（①a / ①a′ / ①e），而首次使用支这三道一道都没跑过**；无合法标记（空的也算）则提示人工 `rmdir`（详见 `--dest` 那条的论证）。**不得用 `os.rename` 当不覆盖发布原语**——它在目标是空目录时会**替换**掉目标（R64-F1）。
  - **复用**：路径已存在且含一份合法 `.pilot_output.json`，且**两层校验都过**（见下）。

  其余一律拒绝启动。

  **标记分两层，因为它们的可校验时机不同（R31-F1 修正）**：

  ```jsonc
  {
    // 第 1 层：目录归属——**不依赖 manifest**，任何时候都能验
    "tool": "qmt_pilot",
    "output_dir": "/abs/resolved/path",     // 自指，防标记被整体搬走
    // 第 2 层：本次运行绑定——**需要一份合法 manifest 才能验**
    "seed": "…",
    "export_log_sha256": "…"
  }
  ```

  - **第 1 层**在准入序列最前面验（`tool` + `output_dir` 与 `resolve(--output)` 相等）。它一旦通过，就确立了「**这个目录是本工具的输出目录，我有权在里面新增东西**」——足以支撑「**写**失败报告」，**但不足以支撑「作废既有报告」**（R40-F1）。
  - **第 2 层**（`seed` + `export_log_sha256`）**必须等到 manifest 校验通过之后**才验；不符 → `FAIL_OUTPUT_BINDING` + `output_binding_error`（`seed_mismatch` / `export_log_mismatch` / **`owner_marker_swapped`**——⑥ 已归属支重核发现第 1 层被换掉，R75-F1）。两种动作的授权强度不同，判据见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2「报告的两种动作，两种授权」。
  - **（R43-F1 曾要求第 2 层之外再加一道「出货代次闸」来授权作废；R69 取消了作废本身，该闸随之取消。**`export_log.csv` 可逐字节不变而 K 线已换**这条事实仍然成立，它现在由逐股 `pilot_stock_source` 在消费循环里把关，见 `2026-07-27-qmt-plan4a-db-guardrails-design.md` §4。）

  > **为什么必须拆层（R31-F1 修正）**：R29-F1 把归属校验排到了读 manifest **之前**（为了能在任何后续失败前作废陈旧报告），可原标记的四项里**含 `export_log_sha256`，而那个值只能从 manifest 里取** —— 于是遇到**畸形 manifest** 时陷入死循环：既无法证明标记相符（缺 manifest），又被 R30-F1 要求往「已归属」的目录里写 `FAIL_MANIFEST_INVALID`。
  >
  > 拆层之后两个需求同时成立：**「我能不能在这里写」不依赖输入是否合法**（第 1 层），**「这次运行是否属于同一批数据」才依赖**（第 2 层）。这两件事本来就是不同的问题，之前被塞进同一个判据里。

  > **为什么首次使用要求「路径不存在」而不是「目录为空」（R30-F2 修正）**：R28-F1 曾声称用 `O_CREAT|O_EXCL` 创建标记就**关死了**「判空 → 声明」之间的竞态 —— **这话说过头了**。`O_EXCL` 只能挡住**另一个 pilot 进程**抢先建同名标记；若在判空之后、建标记之前，**任何其他写者**往该目录放进一个 zip，标记照样创建成功 → pilot 把一个**并非自己独占**的目录当成己有，此后 `os.replace` 就可能覆盖那个无主产物。
  >
  > **`os.mkdir` 是目录级的原子操作**：创建成功即证明「这个目录是我造出来的，创建那一刻它不存在」。**但它只保证「目录的创建」这一步原子，不保证「目录 + 归属标记」这个整体原子**（R62-F2）——两步之间崩溃会留下空的无标记目录。故最终形态是：**`os.mkdir(<final>)` 独占创建**；撞 `EEXIST` 时 —— **没有合法标记（空的也算）→ 一律拒绝并提示人工 `rmdir`**（R64-F1 + R66-F2）；**有合法标记**则按目录分别处置（**`--dest` 与 `--output` 在这一点上结局不同，R91-F2**：`--dest` 有合法标记 → 退回**复用路径的完整准入序列**；`--output` **一律拒绝、一个字节都不写**，因为首次使用支从未跑过 ①a/①a′/①e，就地转复用会让一次诊断性运行覆盖掉对方刚写出的 `SUCCESS` 凭据）。**不要用 `os.rename` 去做「不覆盖发布」——它在目标是空目录时会替换掉目标。**代价是操作者不能预先建好输出目录——这反而更安全（少一个出错的机会）。

> **为什么 `--output` 不能靠「里面的文件长得像我的产物」来判（R8-F1 修正）**：R7-F3 的第一版判据是「目录内每项都匹配 `{code}_{digits}.zip` / `pilot_report.json`」—— 但**那正是本仓所有训练组产物共用的命名空间**。B2 的 `generate` CLI 输出目录、上一次 pilot 的输出目录，里面每个文件都完美匹配这个形状。而 `assemble_from_windows` 是用 `ZipFile(path, "w")` 写的，**会直接截断同名文件**：`--output` 指错到一个真实的训练组目录，就会在报告发现任何问题之前先把别人的 zip 覆盖掉。**「内容的形状」仍然是形状，不是归属**——这与 R2-F1（`unlink` 白名单）、R3-F1（库归属闸）、R7-F3 是同一条原则被迫应用了第四次。
>
> 配套的写入纪律（**适用于文件目标与路径分量两者**，R13-F2）：
> - **文件目标**：`.pilot_output.json` / `pilot_report.json` / zip 目标路径在写之前一律拒绝符号链接（`O_NOFOLLOW`，或写前 `Path.is_symlink()` 判否）—— 否则一个名字对得上的符号链接会让写入**跟出目录**，把归属判定整个绕过去。
> - **路径分量**：本工具自建的每一个簿记目录（当前为 `<output>/.superseded/`）在使用前必须过 `ensure_owned_dir()`：`lstat` 它，**是符号链接 → 拒绝**，存在但不是真目录 → 拒绝，不存在则以 no-follow 语义创建。
>   > 光管文件目标不够（R13-F2）：`os.replace(p, <output>/".superseded"/name)` 里 `.superseded` 是**路径分量**，`os.replace` 会**穿过**它解析。若它是个指向别处的符号链接，这条**破坏性恢复路径**就会把 zip 挪出归属目录、甚至覆盖外部同名文件——归属边界在最需要它的时候被绕开。
> - 报告与标记文件都走临时文件 + `os.replace` 原子落地。
>
> **通用准则**：凡是本工具要写入或穿过的路径，**每一个分量都要么由本工具以 no-follow 创建、要么经 `lstat` 确认不是符号链接**；「只检查最后那个文件名」是不够的。

配套的两道机器闸（写在 `qmt_fetch` 里，因为挂载命令是人敲的、必然会有人漏掉 `-o rdonly`）：

1. **路径重叠 fail-closed**：`dest.resolve()` 与 `source.resolve()` 相等、或任一方在另一方的目录树内 → **拒绝启动**。否则一旦源挂载是可写的，`qmt_fetch` 会把 `.staging.lock` / `fetch_manifest.json` / `.part` / 拷贝出来的 CSV **写进那个权威导出共享里**，污染的正是本次要取证的数据集。
2. **只读挂载检测（非写入式，R5-F3 修正）**：`os.statvfs(source).f_flag & os.ST_RDONLY` 为真才继续，否则**拒绝启动**并提示以 `-o rdonly` 重新挂载。已实测该判据在 macOS 上可用且准确（根卷的 SSV 只读快照判为只读，`/Users`、`/tmp` 判为可写）。

> **为什么不能用「试写一个临时文件」来探测（R5-F3）**：那种主动探测在**恰恰是它要防的那个危险场景里**（共享真的可写）会**由 `qmt_fetch` 自己去写权威导出共享**——探测成功即污染。再叠加崩溃、删除失败或源本身是审计敏感目录，安全检查反而成了第一个破坏者。这与 R2-F1 是同一类错误：**为了防止破坏而引入的机制，本身带着破坏性**。正解是用只读的 `statvfs` 问内核要挂载标志，而不是拿真实写入去试探。

理由三条：
1. 凭据零代码路径最安全——没有任何一行代码碰得到密码，也就不存在写进日志/manifest/异常栈的可能。
2. 脚本退化为纯文件操作，可用本地 `tmp_path` 伪源目录做**完整**单测，无需网络。
3. 挂载失败模式（网络不可达 / 凭据错 / SMB 协商失败 / 挂载点被占）与拉取失败模式（预筛 / 配额 / 字节校验）完全不同；混在一起会让单测难以切分，也会让真跑时的错误定位变糊。

> macOS 沙箱连不到 LAN，挂载与后续对挂载点的读取需 `dangerouslyDisableSandbox`。


### 4.2 储备池只依赖 `export_log.csv`

不依赖 `stock_universe_with_name.csv`。理由：
- `export_log.csv` 已含全部所需字段：股票标识列（`qmt_ingest._STOCK_COL_CANDIDATES` 候选 + `_norm_code` 规范化，可吃文件名或裸 code）、`period`、`status`、`rows`、`first_time`、`last_time`。
- **市场从 code 后缀派生**：`qmt_normalize._STOCK_CODE_RE = ^\d+\.(?:SH|SZ|BJ)$`，后缀即市场。
- **股票名不需要提前知道**：导入时由 `parse_qmt_filename` 从 1m 文件名取。
- 少一个格式未知的依赖 = 少一处 fail 点。

**`stock_universe_with_name.csv` 一概不拷（R84-F3 决定删掉这条）**：原文写「存在则原样拷进 staging 备查，但不参与任何逻辑」——**而它从未成为 manifest 的一等记录**，于是它同时逃过了 `--max-bytes` 计账、`.part` 原子落地、sha256 复校、幂等四象限（撞到同名既存文件怎么办没定义）、以及目录 `fsync`。一个体积异常的、或拷到一半被换掉的源文件，**能在不出现在任何记录里的情况下把磁盘写满或覆盖掉一个无主文件**，而 manifest 解释不了这个副作用。

**取舍**：它「不参与任何逻辑」，删掉零成本；要让它安全就得给它配齐上面五套机制——**为一份备查文件付全套代价不值**。真需要时操作者可以自己从只读源复制。**这是本 spec 唯一一条「删掉而不是加固」的处置**，理由是它的收益（备查）与代价（五套机制 + 一条新的失败面）完全不成比例。


### 4.3 `export_log` 预筛（保守下界，只剔「数学上必然被拒」）

在拉取任何 K 线数据之前，用 `export_log.csv` 零网络成本地剔除必拒股：

| 判据 | 推导 | 命中即剔 |
|---|---|---|
| (a) `status != "ok"`（1m 或 daily 任一） | `reconcile_sources` 第一门：`if status_1m != "ok" or status_daily != "ok": return (False, "export_log_not_ok")` | ✅ 必拒 |
| (b) daily 的 `[first_time, last_time]` 跨越的**不同自然月数 k_daily < 39** | 月边界数 = 日线覆盖的不同月份数 **≤ k_daily**；`eligible_start_indices` 要求 ≥ `31 + 8 = 39` | ✅ 必拒 |
| (c) 1m 的 `[first_time, last_time]` 跨越的**不同自然月数 k_1m < 8** | 窗口需 8 个**完整**月，完整月数 **≤ k_1m**；k_1m < 8 ⟹ 完整月 < 8 ⟹ 无 eligible 候选 | ✅ 必拒 |

三条都取**保守下界**（用「覆盖的不同自然月数」这个上界去卡，绝不误杀边界情形），**不替代真门**——真门照样在 pilot 里跑。作用是把「N 只随机股」换成「N 只高质量候选」，同样的磁盘与开机时长换更多成功股。

**预筛统计写进 `fetch_manifest.json`**（各条命中数），它本身就是关于数据源的第一份真实观测。


### 4.4 分层 seeded 储备池

- 按 code 后缀分 **SH / SZ / BJ** 三层。
- 各层内独立 shuffle：`random.Random(f"{seed}:{market}")`——这样改动某层配额不会扰动其他层的顺序（可复现性对逐层增量补拉是必需的）。
- **默认配额**：`SH=120 / SZ=160 / BJ=120`（约 400 只，≈2 GiB）。可 `--quota SH=..,SZ=..,BJ=..` 覆盖。各层实取 `min(配额, 该层通过预筛的股数)`——配额大于可用数不是错误，取全部即可。
  - BJ 给 120 而非按地板（≥8）等比缩：北交所 2021-11 开市，2023-04 之后上市的股票均不满 39 个月，预筛 (b) 会大批剔除，通过预筛的 BJ 股预计仅 100~150 只 → 配额 120 实质接近「全拉通过预筛的 BJ」。
  - SZ 给得比 SH 多：地板 SZ≥40 > SH≥30，且 pilot 的消费顺序（P4-D8）会优先补地板，SZ 的消耗量结构性地更大。
  - 配额是**首批下注**，不是保证。池穷尽时 pilot 显式 FAIL 并提示可再跑一次 `qmt_fetch`（提高配额）拉下一批。

**补拉靠「按层自动续」，不设 `--skip-first`（R1-F1 修正）**：`qmt_fetch` 启动时先读 `<dest>/fetch_manifest.json`（若存在），**每层各自**从该层的**消费游标**处继续。

> **为什么撤掉 `--skip-first`**：默认配额按层不等（SH=120 / SZ=160 / BJ=120），而 `--skip-first` 是**全局一个 N**，对三层同时生效。补拉第二批时 N 取任何值都错：N=120 会把 SZ 的第 121–160 只**重复**拉一遍；N=160 又会让 SH/BJ 的第 121–160 只**永远拉不到**。而 manifest 的 `pool_order` 是 pilot 的唯一消费顺序来源（P4-D8），顺序一旦被重复项污染或缺项，就会产出**假的** `pool_exhausted` / `floor_unreachable`。全局偏移量与按层配额在语义上不可调和 —— 正解是让偏移量本身按层派生，而不是让操作者去算一个不可能算对的 N。

**偏移量必须落在「冻结的宇宙」上，而不是每次重算的宇宙（R2-F2 修正）**：首次 fetch 把**预筛 + 分层 shuffle 之后的完整候选宇宙**（不只是本批实拷的前缀）连同源快照身份一起冻进 manifest：

```jsonc
"source_snapshot": {
  "export_log_sha256": "…",            // 源 export_log.csv 字节的 sha256
  "universe": {"SH": ["600000.SH", …], // 预筛+shuffle 后的完整有序候选列表
               "SZ": [...], "BJ": [...]}
},
"cursor":   {"SH": 120, "SZ": 160, "BJ": 120},   // 已「尝试」到 universe 的下标（R3-F2）
"failures": [{"stock_code": "…", "market": "SH", "universe_idx": 5,
              "reason": "fetch_missing_file", "attempts": 1}]
```

> **全文约定（S2-F3）**：本文件凡写 `universe[market]`，一律指 **`source_snapshot.universe[market]`**
> ——如上方示例，名单**只存在于 `source_snapshot` 之内**，manifest 顶层**没有**同名键。
> 读侧校验与形状校验那几条**判据**已就地写全层级，不依赖本约定。

补拉时**不重新计算宇宙**，直接从冻结的 `universe[market]` 里取该层下一段。并在启动时对源 `export_log.csv` 重算 sha256：

- **与 manifest 记录不等 → 拒绝启动**，提示「源导出已变化，请换新 staging + 新 seed 重新开始」。
- 相等才允许把源 `export_log.csv` 覆盖到 staging（相等时覆盖本就是空操作，故实际等于「永不覆盖不匹配的」）。

**快照校验还必须覆盖 K 线 CSV 本身（R3-F3 修正）**：`export_log.csv` 的哈希**不足以**代表源状态。QMT 完全可以重新导出一批内容有别、但 `rows` / `first_time` / `last_time` 都不变的 CSV —— 此时 `export_log.csv` 逐字节不变，哈希闸放行，而 K 线内容已经换了一批。这正是本 spec 自己在 R2-F3 里论证过「导入侧的门证不了」的那类改动（门2 只比行数与首尾时间戳）。

因此**补拉默认对「所有先前已拷文件」重算源 sha256**，与 manifest 里记的逐条比对，任一不符 → **拒绝启动**，要求新 staging + 新 seed。
**源文件已不存在（`ENOENT`）单独成码（O4-F16）**：QMT 重新导出并清理旧文件后，某个已拷股的源文件会直接缺失——
那不是「哈希不符」，是**算不出哈希**。处置与不符相同（拒绝启动 + 换新 staging 指引），
但错误码须可区分（**`source_file_vanished`**），**且必须是干净拒绝、不是裸 traceback**（与 §5 对 `export_log` 缺失的口径一致）。

**收尾复校对「每一次」fetch 都要跑，首次也不例外（R4-F2 修正）**：每次 fetch 在给 `source_verification` 定级**之前**，必须跑收尾复校 —— 对 `export_log.csv` 与**本 staging 内所有已成功拷贝的**源文件重算 sha256、与 manifest 逐条比对。

**`source_verification` 分三级，各自只声称它真能证明的东西（R8-F2 修正）**：

> **⚠️ 本表只定义 `qmt_fetch` 侧的「源校验级别」，不定义出货资格（R19-F1）。** 出货资格是**派生量**，定义只有一条（R26-F1）：
>
> ```
> ship_eligible ≡ (final_verdict == "SUCCESS")
> ```
>
> fetch 侧无论定到哪一级，**本身都不足以出货**——它只是 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 最终 verdict 的众多前提之一。

| 级别 | 取得条件（**每一项都必须有机器可记录的凭据**，R10-F3） | 它证明了什么 | 对出货的作用 |
|---|---|---|---|
| `snapshot` | ① 传入 `--snapshot-gmt-token @GMT-YYYY.MM.DD-HH.MM.SS` ② 该 token 与 `--source` 挂载点的实际挂载信息一致（校验通过才接受，防手填一个假 token）③ 收尾复校一趟通过。token 记入 `source_snapshot.gmt_token` | **fetch 那一刻**取到的是单一源代次——VSS 快照在服务端不可变，拷贝期间源树怎么变都影响不到它 | **必要不充分**：仍须 pilot 侧 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 亲自读源才可能出货 |
| `full` | ① 传入 `--confirm-no-export-window`（操作者显式声明本次窗口内未运行 QMT 导出任务，记入 manifest 的 `operator_attestation`）② **两趟连续的全量源哈希复校结果完全一致** | 源在 fetch 的**验证窗口内**没有变化 + 操作者就窗口外的情形作了具名声明。**不等于证明了不可变** | **必要不充分**：同上（报告须原样带出本级别的局限声明） |
| `partial` | 上述凭据任一缺失，或用了 `--skip-existing-verify` | 什么都没证明 | ❌ 直接排除出货资格 |

任一趟复校发现不符 → 直接判失败、非零码退出，不降级为 `partial`（降级会把「发现了源在变」伪装成「没检查」）。

> **凭据必须可记录，否则那句话不算数（R10-F3 修正）**：本表原先把「操作者确认窗口内未跑导出」写进了 `full` 的取得条件，却**没有任何 CLI 参数或 manifest 字段去承载它**；`snapshot` 级要的 GMT token 同样没有入口。结果是实现只要跑完两趟一致就能标 `full` → `ship_eligible: true`，而 spec 声称属于证据一部分的人工确认**从未发生过**。这是「声称超出实际保证」在**流程凭据**上的又一次复现（承接 R4-F2/F3、R5-F2、R8-F2/F3）。
>
> 收口原则：**凡是被写进「够格出货」判据的条件，都必须有一个机器可检、可持久化的凭据**——不能靠散文里的一句约定。缺凭据即降级为 `partial`（非出货资格），而不是默认它成立。

> **为什么不满足于「加一趟复校」就叫 `full`（R8-F2）**：客户端 `-o rdonly` 只挡住**本工具**去写，**挡不住服务端重写导出树**。单趟复校里，每个文件都可能在被读到的那一刻恰好与 staging 一致，而整个 staging 仍是多代次混合——单趟从原理上就证不了单一代次。两趟一致把窗口收窄到「源在两趟之间没动」，这是**实打实的证据但不是证明**，所以它单独成一级并把局限写进报告，而不是继续挂在 `full` 这个词下面假装等价于快照。
>
> `mount_smbfs -t` 的快照挂载是本机 `mount_smbfs(8)` 就支持的能力（已查证 man page），前提是那台 Windows 对该卷启用了「以前的版本 / 卷影复制」。**验收时优先尝试快照挂载**；不可用再退到两趟模式，并在报告里如实标级。

> **为什么首次 fetch 同样需要**：原设计把复校只挂在补拉上，理由是「首次拷贝时每个文件都是边读边算哈希的」。但那个哈希只证明**该文件在被拷的那一刻**是自洽的，**不证明整批文件来自同一个源代次**。首批要拷约 2 GiB、耗时可观，QMT 完全可能在拷到一半时重新导出——于是前一半文件来自第 1 代、后一半来自第 2 代，每个文件的哈希都「对」，而 `source_verification` 却堂而皇之写着 `full`。**一个声称 `full` 的标签，必须由一次真正覆盖全集的校验来支撑**，否则它就是在替流程说流程没做过的话。

- 成本：`snapshot` 级只需一趟（快照本身保证不变）；`full` 级需两趟，即把已拷字节从源读两遍（首批约 2×2 GiB）。fetch 是每次 pilot 至多几次的低频操作，这是「一份 pilot 报告只对应一个源代次」的应付代价。
- 提供 `--skip-existing-verify` 供确知源未变时省时间（同时跳过补拉前置复校与收尾复校），但**一旦使用，manifest 与 pilot 报告都打上 `source_verification: "partial"`**，并在报告的人读摘要里显式印出「本次未校验既有文件，不能保证单一源代次」。宁可让报告自己承认它证不了什么，也不要让读者以为它证过。

> **为什么必须冻结**：原设计的偏移量续进的是一个**每次重新算**的宇宙。QMT 源导出在两批之间但凡变过（新股上市、重跑导出、某只股 `status` 从 `ok` 变成别的），预筛与 shuffle 的输出就整体位移——同一个 `len()` 偏移量指向的是完全不同的股票，于是跳过一批、重复另一批。更糟的是 staging 里的 `export_log.csv` 被新版覆盖后，第一批已拷的 CSV 会与新 `export_log` 的 `rows`/端点对不上，`build_stock_import` 门2 直接判 `export_log_mismatch` —— **一批本来完好的数据集体变成「坏数据」**。最终 pilot 报告里混着两个 QMT 快照的产物，而报告本身对此一无所知。

**游标必须独立于成功列表（R3-F2 修正）**：`cursor[market]` 记录**已尝试到 `universe[market]` 的下标**，对**每一个尝试过的槽位都推进**（无论拷成功、源文件缺失、还是哈希失配）；`pool_order[market]` 只收**成功拷进 staging 的** code。两者**语义不同、不可互相替代**。推进的确切写法是 `cursor[market] ← max(cursor[market], universe_idx + 1)`（R37-F1）——重试台账里的旧槽位位于 `cursor` **之前**，直接赋值会让游标倒退、把已尝试过的一段重走一遍。

> **为什么不能拿 `len(pool_order[market])` 当游标**：拷贝失败是**跳过继续**的，所以 `pool_order` 是一个**成功列表**，而不是冻结宇宙的前缀。举例：配额 120，`universe` 的 U5 拷失败、U6–U121 全成功 → `pool_order` 长度 120 → 下一批从 `universe[120]`（= U121）开始，**U121 已经拉过了**（重复），而 **U5 永远不会被重试**（遗漏）。失败越多，游标落后越多，越靠近末尾越容易原地打转。最终 pilot 会拿着一个**不完整的池**报出 `pool_exhausted` / `floor_unreachable` —— 又是一份**会撒谎的报告**。这与 R1-F1 是同一个错误的两种形态：**把「成功了多少」当成「走到了哪里」**。

**失败台账与有界重试**：拷贝失败进 `failures`（含 `universe_idx` 与 `attempts`）。补拉时**先重试 `attempts < 2` 的条目**（一次重试，覆盖瞬时网络故障），再从 `cursor` 继续；重试仍失败则 `attempts` 加一后不再自动重试；**重试成功即把该条目移出 `failures` 并计入 `batches` 历史
（O2-F14）**——`fetch_failures` 只统计**未解决**条目。否则一只已在 `pool_order` 里的股会被一直算成
「拷贝失败让池缩水」，而 pilot 报告的读者正是据此判断池为什么缩水的。`failures` 的条数与原因分布必须出现在 pilot 报告里 —— 否则一个因拷贝失败而缩水的池，会被误读成「候选就这么少」。

**`pool_order` 的每一项都必须携带 `universe_idx`，消费时按它排序（R12-F1 修正）**：

```jsonc
"pool_order": {"SH": [{"code": "600000.SH", "universe_idx": 0},
                      {"code": "600004.SH", "universe_idx": 1}, …], …}
```

`qmt_pilot` 消费某层时，**一律先按 `universe_idx` 升序排序**，而不是按 `pool_order` 的追加顺序。

> **为什么追加顺序不可用（R12-F1）**：拷贝失败是跳过继续的，而重试发生在**下一批的开头**。于是 U5 第一批失败、U6–U121 成功后被顺次追加，第二批重试 U5 成功 → U5 被追加到**列表末尾**，顺序变成 `[…, U121, U5]`。pilot 把 `pool_order` 当唯一消费顺序（P4-D8），结果就是**最终选中哪 100 只，取决于当时 SMB 有没有抖一下**——而不是取决于 `seed` 与源快照。这直接推翻本 spec 自己声称的「可复现」（本文件 §4.3/本文件 §4.4 的全部 seeded 设计都是为了它），并且会让地板/穷尽的诊断结论跟着漂。
>
> 携带 `universe_idx` 并按它排序，等于把消费顺序**重新锚回冻结宇宙**：无论某只股是第一次拉成功还是重试才成功，它在消费序列里的位置都不变。这比「把重试成功者插回原位」更稳——插入要维护顺序不变量，排序只需每项自带其真值。

**磁盘上限**：`--max-bytes`（默认 3 GiB），**是一条硬上限，不是事后统计（R48-F3）**：

- **流式逐块扣减预算**：拷贝时每写一块就从剩余预算里扣；**若这一块会越界，立刻停止写入**（不写出去），删掉该股的 `.part`，走下方「配额触顶」路径。这条是硬保证。
- **事前 `stat` 早拒（尽力而为）**：开拷前读源两个文件的 `st_size`，若 `已提交字节 + 两者之和 > --max-bytes` 则直接触顶、连拷都不开始。SMB 上的 `st_size` 可能不准或期间变化，**故它只是省时间的早拒，正确性由上一条保证**。
- **不做按 `rows` 的估算**——那需要经验系数，不准且会造成假安全感。
- **计入总账的单位是「已提交的股」而不是「已写的文件」（R37-F1）**：未提交的股其字节随 `.part` 一起消失，不计入。

> **为什么必须是流式硬限而不是事后核账（R48-F3 修正）**：原文写「事后累计实拷字节，超限即停止」——**那是在字节已经落到本地盘之后才发现超了**。一个损坏或异常巨大的源 CSV（QMT 导出出错、或某只股的 1m 文件被写坏成几十 GiB）会被**一路流进 `.part`**，等我们发现时磁盘已经被占满。而本 plan 明确记录本机可用空间只有约 30 GiB，磁盘打满会连带**打断 DB 写入、报告落盘与机器上的其他工作** —— 一条本该是护栏的规则，反而成了故障放大器。

**配额触顶是「终止条件」，不是「这只股失败了」（R44-F2 —— 权威定义）**。触顶时：

1. 删掉当前这只股的两个 `.part`，**不留任何 final 文件**（R37-F1）；
2. **不记 failure、`attempts` 不加一、`cursor` 不推进** —— 这只股**根本没被真正尝试完**，它必须在下一次运行里从原位重来；
3. manifest 提交，记 **`stopped_reason: "max_bytes"`**（`stopped_reason` 的**全集**为 `max_bytes` / `source_path_escape` / `staging_path_escape` / `staging_recheck_failed`（O4-F3 补第四项），R87-F1 + R89 自查补；附触顶时的累计字节与所在层/下标，仅供人读）；
4. **立即停止本次拉取，非零码退出并报告** —— **绝不继续下一只**。

**⚠️ 上面三步只适用于「股级对象」；非股级对象触顶是第二档（O4-F8）**：
staged `export_log.csv` 是**唯一的非股级计账对象**，它落盘在**第一份 manifest 之前**。
它触顶时 → **不提交任何 manifest、只删 `.part`、rc≠0，目录停在引导态**。
**照第 1~4 步实现会砖化整棵 staging**：那份 manifest 必然缺 `staged_export_log`、`files`/`pool_order`/
`source_verification_evidence` 全空 → 读侧「缺 `staged_export_log` → 拒绝整个 manifest」→
该目录此后既不是首次（路径存在且标记合法）、也不是引导态（manifest 存在）、也不是复用（manifest 非法）
→ **工具自己解不开，只能人工清理**（正是 O2-F8 要防的那个状态）。
**补拉时重复拷贝 staged `export_log.csv` 的字节**：相等时覆盖是空操作、**不重复计入累计字节**。

> **为什么必须与普通失败分开（R44-F2 修正）**：R37-F1 写按股事务时，我把 `--max-bytes` 触顶和「源文件缺失 / 哈希失配」并列成了同一条收尾路径（记 failure、推进 cursor、继续下一只）。照字面实现，**一次配额触顶会把剩下的整个宇宙当成失败烧掉**：每只股都触顶、每只都记 failure、每只都推进 cursor —— 于是 `cursor` 冲到宇宙末尾、`failures` 里堆满几百条假失败，而**它们一只都没被真正尝试过**。下一次运行无处可续，pilot 随后报出的 `FAIL_POOL_EXHAUSTED` / `FAIL_FLOOR_UNREACHABLE` 完全是假的。
>
> 这与 R3-F2 是同一家族的第三次：**把「我这次到此为止」记成了「这些候选不行」**。容量停止是**可恢复的、与数据无关的**，而 failure 台账描述的是**候选自身的问题**；两者混在一起，就等于让磁盘配额去污染市场结论。


### 4.5 幂等拷贝（按股事务 + 崩溃恢复 + manifest）

- 每只股拷两个文件：`{code}_{name}_1分钟K线_前复权.csv` 与 `{code}_{name}_日K线_前复权.csv`（`qmt_normalize._FILENAME_RE` 的字面格式）。
- **保留源端目录结构**（**源根之下**的 `{1分钟K线_前复权,日K线_前复权}/` 两个周期目录，S2-F1）——`import_csv._amain_qmt_import` 用 `input_dir.rglob(...)` **递归**定位，保留结构即可直接被复用。
  **staging 因此是源根的逐层镜像**：同一条 `relative_path` 在源侧与 staging 侧**逐字相同**。
  ⚠️ **已实测（2026-08-24，纯 `tmp_path`）**：staging 保留或不保留 `front_ratio_cn_stocks_ab_bj/`
  这一层，`rglob` 两种布局都**恰好命中 1 个**文件、`.part` 残留都不被误命中——
  **导入侧对这一层的有无零依赖**（此前只有推理，无证据）。
- **拷贝时流式算 sha256**（R2-F3）：边读源边算，写完对**落地文件**重算一遍并与源哈希比对，不等即判拷贝失败（删**该股的两个** `.part`、记 `fetch_copy_hash_mismatch`、继续下一只；R37-F1：清理的粒度是股不是文件）。字节反正要过一遍内存，哈希是顺带的。
- **幂等判据 = 字节数 + 内容哈希**（R2-F3），按「manifest 有无记录 × 目标在不在」四象限判（R7-F3 + R26-F2）：

  | | manifest **有**记录 | manifest **无**记录 |
  |---|---|---|
  | 目标**存在** | 字节数与 sha256 都相符 → 跳过；不符 → 重拷 | **拒绝覆盖**，记 `untracked_target_file`，跳过该股 |
  | 目标**不存在** | 正常拷贝 | 正常拷贝 |

  **本表的适用前提是「崩溃恢复流程已先跑过」（R37-F1）**：它判的是**恢复之后仍然无主**的文件，那才真是来路不明的。上一次运行留下的半成品由下方的按股事务负责回收，不走本表。

  **「manifest 无记录」不等于「没拉过」**（R26-F2）：只有在**目标也不存在**时它才意味着没拉过；目标已存在却无记录，说明那是一个**来路不明的文件**，静默覆盖它就是数据丢失。
  - 判据只查**本地文件与 manifest**，不回读源文件——这一步只回答「**本地这份拷贝还完整吗**」。
  - **「源变没变」不由本判据回答，也不由 `export_log_sha256` 单独回答（R35-F2）**：`export_log.csv` 可以**逐字节不变而 K 线内容已换**（R3-F3 已论证）。源漂移由 本文件 §4.4 的**收尾复校**负责——它对**每一个先前已拷文件逐个重算源 sha256**；`export_log_sha256` 只是批次级的**快速前置筛**，**不能替代逐文件复校**。
  - **为什么不能只比字节数**：同尺寸不同内容会被静默跳过并一路导入。而导入侧的门**证不了这件事**——`build_stock_import` 门2 只比 `len(raw) == ent.rows` 与首尾 `datetime`，门4 `reconcile_sources` 比的是 1m 与日线**彼此**是否自洽，**没有任何一道门拿落地文件与源文件逐值比对**。文件中段一处等长损坏（前复权价格是变长小数串，改动后长度不变完全可能）能一路过关，最终写进训练组。
- **原子落地**：先写 `<name>.part`，`fsync` 后 `os.replace` 原子 rename。杜绝半截文件被后续运行当成完整。`.part` 的文件名形如 `<…>.csv.part`，不匹配 `import_csv._amain_qmt_import` 的 `rglob("{code}_*_1分钟K线_前复权.csv")`（`backend/import_csv.py:507-508`，已核），故任何残留 `.part` 都不会被导入侧误当成数据。
- **按股事务：两个文件要么都提交、要么都不留（R37-F1）**。**提交点 ＝ manifest 原子落盘，且 manifest 每只股提交一次**（不是每批一次）。一只股的完整序列：

  1. 两个文件各写 `<name>.part`（流式 sha256，写完对落地 `.part` 重算并与源哈希比对）。任一失败或源文件缺失 → **删掉这只股的两个 `.part`**，记 failure（`attempts` 加一），提交 manifest（含 `cursor` 推进），继续下一只。**此路径不产生任何 final 文件。**
     **`--max-bytes` 触顶不走这条路（R44-F2）**——它是**终止条件，不是这只股的失败**，见下方「配额触顶」。
  2. 两个 `.part` 都通过 → 原子写在途标记 `<staging>/.inflight.json`（tmp → `fsync` → `os.replace`）：`{code, universe_idx, targets: [两条 staging 内相对路径], parts: [两条], started_at}`。
  3. 依次 `os.replace` 两个 `.part` → final。
  4. **提交**：manifest 原子落盘（该股 2 条 `files` 记录 + `pool_order` 条目 + `cursor` 推进）。
  5. 删除 `.inflight.json`。

  **崩溃恢复**（取得 `.staging.lock`、读完并校验 manifest 之后，**任何拷贝之前**）：若 `.inflight.json` 存在 →
  - **先校验标记自身的形状**（同 R21-F3 的纪律：一个能授权删文件的结构，自己必须先被校验）：`code` 匹配 `^\d+\.(SH|SZ|BJ)$`；`universe_idx` 在界内且 `source_snapshot.universe[market][universe_idx] == code`；`targets` / `parts` 各 2 条、`resolve()` 后落在 staging 之内、由文件名解析出的 code 与 `code` 一致且 period 恰为 `1m` / `daily` 各一。**任一不符 → 拒绝启动、一个文件都不删**，提示人工处理。
  - 校验通过后分**三档**（O4-F5：原文的两分法在「manifest 已提交但文件校验不过」这一档会把状态改坏）：
    **①manifest 里该股无记录** → 崩在第 4 步之前 → 走下面的回滚（cursor 未推进，原地重试同一槽位）；
    **②有记录且 final 文件字节数与 sha256 都相符** → 崩在第 4 步之后 → **只删标记**，文件保留；
    **③有记录但文件不符**（第 4 步已提交并**推进过 cursor**，随后某个 final 因写回丢失/被外部改动而校验不过）
    → 除回滚四条路径外，**必须同时删掉该股的 `files`/`pool_order` 条目并把 `cursor` 回退为
    `min(cursor, universe_idx)`**。**不这么做的后果**：两条 final 被删（**连那条好的一起删**）、
    manifest 里的记录原样留着、cursor 停在已推进的位置、该股不在 `failures` 里 →
    拷贝循环从 cursor 继续、**永远不会回头** → pilot 随后判 `staging_integrity_mismatch` 跳过 →
    **池静默缩水、结论记到市场账上**，正是按股事务存在的全部理由（R37-F1）被这条恢复路径重新打开。
    ①③ 两档的回滚动作同为：**删掉标记里明写的那两条 target 与两条 `.part`**（只删这四条，不做任何模式匹配式清扫）；
    ⚠️ **这四条 `unlink` 一律容忍 `ENOENT`，其余 errno 才算失败**（O4-F4，已实测 `os.unlink(dir_fd=)`
    对不存在的目标抛 `FileNotFoundError`）：本分支的触发条件正是「崩在**两次 `os.replace` 中间**」——
    此时 target[0] 已是 final、target[1] 还是 `.part`，`parts[0]` 已消失，**四条里至少两条必然不存在**。
    不写这一条 → 恢复流程第一条 `unlink` 就抛异常 → 要么让异常上浮（**每次重跑都在同一处崩、池永远拉不完**，
    且 `inflight_rollbacks` 涨不上去，3 次转 failure 的兜底同样够不着）、要么把一次正常回滚误报成
    `staging_path_escape`（把正常恢复报成信任边界破坏），删标记，**记一条基础设施遥测 `inflight_rollbacks[universe_idx] += 1`**（R66-F3），提交 manifest —— **不记 failure、不加 `attempts`、`cursor` 不推进**，于是下一步就是**原地重试同一个槽位**。
     **仅当同一 `universe_idx` 的 `inflight_rollbacks` 达到 3** 时，才记一条 failure（`fetch_interrupted_rollback`、`attempts` 加一）并推进 `cursor`，避免确定性故障下原地打转；报告里须标明这条失败**属于基础设施原因**。
  - failure 的 `reason` 全集：`fetch_missing_file` / `fetch_copy_hash_mismatch` / `untracked_target_file` / `fetch_interrupted_rollback`（**最后一条只在同槽位回滚累计到 3 次时才产生**，R66-F3），逐类计数进 pilot 报告的 `fetch_failures.by_reason`。

  **`source_path_escape` 不在这个全集里，因为它不是「一只股的失败」（R87-F1）**：源树内任一路径分量撞
  `ELOOP`/`ENOTDIR`（`open_under(src_fd, …)`，`2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 源边界闸第 4c 条）是**源树布局本身**的问题，
  不是某只股拉不到——同一目录下的**所有**股都受影响。处置与 `--max-bytes` 触顶同族（R44-F2），
  即**终止条件而非候选失败**：
  - **立即终止整次 fetch**：删当前股的两个 `.part`、**不记 failure / 不加 `attempts` / 不推进 `cursor`**；
  - manifest 记 **`stopped_reason: "source_path_escape"`** 与顶层
    **`fetch_fatal_error: {kind, relative_path, component, errno}`**（**四字段，与 本文件 §4.5 读侧要求逐字相同**；
    ⚠️ **本文件是 manifest 的唯一权威，字段名由此处定为 `fetch_fatal_error`**（O4-F9）——
    与 4c **报告顶层**那个两字段的 `fatal_error` 消歧；写侧 / 读侧 / §5 / §9 **四处一次改齐**，
    R94-F2；`errno ∈ {ELOOP, ENOTDIR}`；**不在 `failures` 里**）后提交；
    ⚠️ **`kind` 记录的是「首次逃逸的类型」，与 `stopped_reason` 解耦**（O4-F3）：
    「保留 fatal + 换 `stopped_reason`」（复校失败那一档）在「`kind` 恒等于 `stopped_reason`」下**结构上不可表达**。
  - **rc≠0 退出**。
  **⚠️ 消费侧的 fail-closed 判据是「`fetch_fatal_error` 存在」，不是「`stopped_reason` 取值」（O4-F1 —— 唯一权威）**：
  `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 步骤 ② 的分支**必须先判 `fetch_fatal_error` 是否存在**：
  **存在 → 无条件 fail-closed**（按 `fetch_fatal_error.kind` 取 `FAIL_SOURCE_BOUNDARY` / `FAIL_STAGING_INTEGRITY`）；
  不存在才按 `stopped_reason` 走「容量停止 → 放行」。`stopped_reason` 只作**人读附注**。
  **理由**：`stopped_reason` 是「本次运行为什么停」，`fetch_fatal_error` 是「这棵 staging 是否已被证明动过」——
  后者是**粘性的信任状态**，前者是**易失的本次事件**，拿前者当安全判据必然被后续运行洗掉（O4-F1 实证）。

  **`stopped_reason` / `fetch_fatal_error` 的生命周期（唯一权威，R95-F2）**——**只在「收尾提交」这一次原子提交里被写入或清除，per-stock 提交一律不动它们**：
  - `qmt_fetch` **启动时不清除**上一次留下的 `stopped_reason` / `fetch_fatal_error`（**清早了，重试若崩在证明干净之前，唯一的持久记录就没了**）；
  - **收尾提交**发生在两种时刻：①正常跑完整批；②干净的 `--max-bytes` 触顶。**在那一次原子提交里**：
    · **清除谓词不是「本次没撞 escape」，而是「已证明受影响的路径确实干净」（O2-F7）**：
      收尾提交的两个触发点（正常跑完 / 干净 `max_bytes` 触顶）**都不要求这次运行走过上次出事的那些分量**。
      具体反例：上次因 `staging_path_escape` 终止（manifest 已记 56 只股），操作者删掉被换的分量重建，
      重跑时新股走新建目录全部成功、收尾复校只对**源**重算 sha256（**从不回读 staging 里那 56 只股**）→
      「本次没撞 escape」成立 → 清除 → **manifest 声称拥有的 56 只股在 staging 里已不存在，而唯一记录
      「这棵树被动过」的持久证据没了**；pilot 随后对这 56 只逐股判 `staging_integrity_mismatch` **跳过**，
      池静默缩水一半，结论被记到市场账上。
      **规定**：清除的前提是 ①本次已**重新遍历过** `fetch_fetch_fatal_error.relative_path` 所指的那条路径且未撞 escape；
      **②对 `staging_path_escape` 另加（无条件，不受任何 flag 影响，P2-F3）**：清除前须对 manifest 里
      **所有已记录的 staging 文件**做一次存在性 + sha256 复校（顺带补上「fetch 从不校验自己 staging 里
      既有文件」这个缺口）。
      **`--skip-existing-verify` 与「manifest 带 escape 记录」互斥——撞上即拒绝启动**（P2-F3：该 flag 的定义是
      「同时跳过补拉前置复校与收尾复校」，实施者最自然的读法会把 ② 一并跳过 → 第 1 次带 flag 跑清掉 fatal、
      标 `partial`（看似安全），第 2 次不带 flag 跑时收尾复校**只重算「源」、从不回读 staging** →
      **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 `full` 标签**）。
      **复校失败的具名结局（P2-F3；此前完全未定义 → 不可解 staging）**：保留 `fetch_fatal_error`、覆盖写本次
      `stopped_reason: "staging_recheck_failed"`、rc≠0，**且本次不得推进 `cursor`、不得新增
      `files`/`pool_order` 条目**（否则每次重跑继续消耗冻结宇宙与 `--max-bytes` 预算却永远清不掉 fatal）。
      **操作者出路与 O2-F8 同规格**：提示「该 staging 已被证明动过且无法自证完整，请换新 staging + 新 seed 重拉」。
      **⚠️ `max_bytes` 触顶**（前提① 对它不可能满足——事前 `stat` 早拒不遍历任何路径）：
      **`fetch_fatal_error` 原样保留，且 escape 的 `stopped_reason` 一律不得被覆盖**（O4-F1）。
      本次触顶另记 **`stopped_reason_secondary: "max_bytes"`**（纯诊断附注）。
      **原文写「`stopped_reason` 只覆盖为 `max_bytes`」是一条会洗白信任边界破坏的规则**：
      Run1 撞 `staging_path_escape`（manifest 已记 56 只股）→ pilot fail-closed ✅ →
      操作者修好被换掉的分量重跑 → Run2 拉几只股后触到 `--max-bytes`（**累计字节含 Run1，触顶几乎必然**）
      → `stopped_reason` 被改写成 `max_bytes` → **pilot 读到 `max_bytes` 放行** →
      那 56 只从未被复校过的股照常消费，**一次被证明破坏的信任边界被一次容量停止洗白成合法凭据**。
    · 本次**没有**撞任何 escape **且上述两条前提成立** → **同时**写入本次的 `stopped_reason`（`max_bytes` 或**删除该字段**）并**删除 `fetch_fatal_error`**；
    · 本次**又撞**了 escape → 写入本次的 escape `stopped_reason` + 四字段 `fetch_fatal_error`（**覆盖**上一次的）。
  - **崩在收尾提交之前** → manifest 仍带着上一次的 escape 记录，pilot 继续 fail-closed（**安全侧**）。

  > **为什么清除必须与「证明干净」同处一次提交（R95-F2 修正）**：`stopped_reason` 的两个 escape 值让 pilot 无条件 fail-closed（R93-F1），**而我从没写过它什么时候被清掉**。两种朴素做法都错：**就地合并式更新**会让操作者修好源树、重跑成功之后，**那条陈旧的 fatal 记录永远留在 manifest 里，pilot 永远拒绝启动**；**启动即清除**则会在「重试崩在中途」时**抹掉唯一的持久证据**，下一次运行看到的是一份看起来干净、实则来自被污染源树的 staging。**把清除与「本次已干净收尾」绑进同一次原子提交，两种坏结局都不可表达。**

  - **pilot 侧连带 fail-closed**：读到 `stopped_reason == "source_path_escape"` 的 manifest →
    **拒绝启动**，判 **`FAIL_SOURCE_BOUNDARY` + `source_boundary_error: "source_path_escape"`**、rc=1。
    修好源树后重跑 `qmt_fetch` 才能继续。

  > **为什么必须是整次致命、而不是记一条 failure（R87-F1 修正）**：我在 R82/R84 把
  > `source_path_escape` 定义好了，**却只把它接进了 pilot 侧的 `source_boundary_error`**——
  > fetch 侧那份「failure `reason` 全集」是**声明为闭合的**，里面根本没有它的位置。于是实施者只有三条路：
  > 让自己的 manifest 形状校验失败、把一次**信任边界破坏**降级成普通 fetch 失败、或者干脆不记。
  > 中间那条最危险：**一次源树逃逸会伪装成普通的池缩水**，剩下的股照样凑够 100 只走到 `SUCCESS`，
  > 而报告里没有任何字段说得出「源边界被绕过了」。
  >
  > 定为整次致命的理由：**逃逸是目录层面的事实，不是候选层面的事实**。记成候选失败会同时犯两个错——
  > 把责任归给市场（`FAIL_POOL_EXHAUSTED` 反映的成了源树被人动过的历史），以及**让一次可以出货的运行
  > 建立在一棵已被证明不可信的源树上**。这与 R44-F2、R66-F3 是同一条判据的第三次应用：
  > **「我这次没做完 / 环境不对」不能记成「这个候选不行」。**
  - **`inflight_rollbacks` 单独统计、不进 `failures`（R66-F3）**：崩溃是**基础设施中断**，不是「这只股拉不到」的证据。若把它记成候选失败并推进游标，**反复崩溃会把合格候选一个个永久踢出 `pool_order`**，最终 `FAIL_POOL_EXHAUSTED` / `FAIL_FLOOR_UNREACHABLE` 反映的就成了**本机故障史而不是市场数据** —— 这与 R44-F2（配额触顶被记成候选失败）是**同一个错误的第二次**：**把「我这次没做完」记成了「这个候选不行」**。manifest 与 pilot 报告都要带 `inflight_rollbacks` 的总数与分布
  **（O2-F11：⚠️ 已核实 4c 报告 schema 里 `inflight_rollbacks` 出现 0 次——本条要求悬空。须同时核
  `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3，把 `inflight_rollbacks` 与 `fetch_stopped_reason`
  补进报告 schema；否则 1~2 次回滚在报告里完全不可见——`fetch_interrupted_rollback` 只在累计 3 次时才产生——
  SMB 抖动让 40 只股各回滚 2 次时读者只能得出「候选就这么少」，正是 R66-F3 要防的误读）**，让读者能把两类原因分开。

  > **为什么必须是按股事务（R37-F1 修正）**：原设计的幂等与原子性都是**按文件**的，而一只股需要**两个**文件。1m 拷成功、daily 失败（或进程恰好死在两次 `os.replace` 之间）→ 该股不进 `pool_order`、manifest 里无记录，**而 1m 的 final 文件已经躺在 staging 里**。下一次重试撞上的就是四象限表的「目标存在 × manifest 无记录」→ 判 `untracked_target_file` 跳过 —— **一次瞬时网络抖动被永久固化成「这只股拉不了」**。池就此缩水，最终报出的 `FAIL_POOL_EXHAUSTED` / `FAIL_FLOOR_UNREACHABLE` 会把责任归给市场，而真实原因是本工具自己留下的半成品。这与 R3-F2 是同一家族：**把「部分成功」当成了一个完整的状态**。
  >
  > **在途标记不是给 untracked 闸开的后门**：它只授权删除**标记里逐条明写的那两条路径**，且标记本身要先过形状校验。四象限表管的是「恢复跑完之后仍然无主」的文件——那是真正来路不明的，仍旧拒绝覆盖。
  >
  > **manifest 改为每股提交一次，是这条事务成立的前提**。原文从未写明提交节奏，而按批提交会把同一个错误放大一个量级：一次崩溃让**整批**已拷文件同时失去记录，untracked 闸会一次性毒死几十只股。每股写一次几十 KB 的 JSON，代价可忽略。
- **staged `export_log.csv` 也计入 `--max-bytes` 流式硬限（O2-F2）**：它是**唯一的非股级计账对象**，
  须与 K 线 CSV 同规格逐块扣减 + 事前 `stat` 早拒。原文只把「计入总账的单位」定为「已提交的股」，
  而它在**第一次 manifest 之前**就落盘 → 一份异常巨大或被写坏的 `export_log.csv` 能把本机仅约 30 GiB
  的余量写满，连带打断 DB 写入与报告落盘。这与 R48-F3 逐字同构，只是对象换成了**所有股都依赖的全局输入**；
  也是 R84-F3 删掉 `stock_universe_with_name.csv` 时列的五套机制里**唯一没给它补上的那一套**。
- 把 `export_log.csv` 复制到 `<staging>/export_log.csv`（`_amain_qmt_import` 的默认查找位置）；补拉时仅在源哈希与 `source_snapshot.export_log_sha256` 相等时才覆盖（R2-F2）。**它与 K 线 CSV 受同等纪律（R38-F1）**：走 `.part` → `fsync` → `os.replace` 原子落地，并作为**一等记录**写进 manifest 的 `staged_export_log: {relative_path: "export_log.csv", bytes, sha256}`。
  - **时机：在任何 K 线拷贝之前，随首次 manifest 一起落盘**（R38-F1）。放在拷贝循环之后会制造一个新的坏状态：manifest 读侧现在**要求** `staged_export_log` 存在，而 fetch 崩在循环中途会留下一份没有该键的 manifest —— **fetch 自己也读不回来、无法续跑**。它是全局输入，本就该在消费它之前先钉住。

  > **为什么它必须被钉住（R38-F1 修正）**：`import_qmt_stock` 真正消费的元数据就是**这一份 staged 副本** —— `build_stock_import` 的门2 拿它的 `rows` 与首尾 `datetime` 去卡每只股的 K 线。而此前全套完整性闸只钉了 K 线 CSV：`files` 清单逐条 `bytes`+`sha256`、`staging_intact` 逐股复校、三方相等逐文件比对，**唯独漏了这个所有股都依赖的全局输入**。`source_snapshot.export_log_sha256` 记的是**源那一份**的哈希，源边界闸第 3 条查的也是**源那一份**——没有任何一处回头看过 staging 里这一份。于是它被截断、被手工改过、或残留自上一代，pilot 都照用不误：轻则把好数据判成 `export_log_mismatch` 一片 skip，重则**一份手改的 staged log 能让本该被拒的股过门**，而权威源里那份根本不认。这与 R21-F3（被最广泛信任的结构自己没被校验）是同一模式的第二次，只是这次漏掉的不是一个清单而是一个文件。
- 写 `fetch_manifest.json`（**每只股提交一次**，提交节奏见上方按股事务，R37-F1）：**`manifest_version`**（O4-F10：此前只在读侧必填、写侧枚举里没有它 → 自己产出的每一份 manifest 都被自己的读侧拒绝）/ `seed` / 配额 / 预筛统计 / **`source_snapshot`**（`export_log_sha256` + 冻结的完整分层 `universe`，`snapshot` 级另含 `gmt_token`）/ **`source_mount`**（`{fstype, device, mountpoint, source_root, source_root_relative, gmt_token?}`——`source_root_relative` 是 fetch 当初使用的**导出根在共享内的相对路径**，**它才是 pilot 侧的比对判据**；`source_root`/`mountpoint` 记的是 fetch 那次的绝对形态，**仅供留痕、不参与判定**，因为挂载点会变，R19-F2 + R23-F1 + R25-F2）/ **`cursor`**（按层已尝试到的 universe 下标，R3-F2）/ **`failures`**（含 `universe_idx` 与 `attempts`）/ **实拷清单 `files`**（每条 **`{stock_code, period, relative_path, bytes, sha256}` 五字段**，与读侧枚举**逐字相同**，S2-F5；`market` 从 code 后缀派生，**不落盘**）/ **各层储备池顺序 `pool_order`**（成功列表，每项 `{code, universe_idx}`，pilot 的唯一消费顺序来源，见 P4-D8）/ `source_verification`（`snapshot`/`full`/`partial`）/ **`source_verification_evidence`**（校验过程存根，R16-F1）/ `operator_attestation`（`full` 级）/ 累计字节 / `batches` 历史。

**补拉的 manifest 语义**：第二次 fetch 落到**同一 staging**，manifest **就地更新而非覆盖**——`pool_order[market]` **按序追加**该层新拉到的 code（已在列表中的不重复追加），并记一条 `batches: [{seed, quota, added: [...]}]` 历史。理由：pilot 只从 manifest 读顺序，若覆盖式重写会让第一批已消费的股从顺序里消失，断点续跑的 `already_done` 判定与「池穷尽」判定双双失真。**若第二次 fetch 的 `--seed` 与 manifest 里已记的 seed 不同 → 拒绝**（不同 seed 的顺序不可拼接，混用会让「可复现」这个属性静默失效）。

**manifest 的崩溃/并发保护（R1-F4 修正）**：manifest 是 pilot 的唯一真相源，它的写入必须和 CSV 拷贝受同等纪律约束——原设计只给 CSV 配了 `.part` + `os.replace`，把 manifest 留成裸写，是不对称的疏漏。

1. **staging 生命周期锁（两个工具共用，R32-F2；R48-F2 改为内核持有）**：`<dest>/.staging.lock`，用 **`fcntl.flock(fd, LOCK_EX | LOCK_NB)`** 取得——**锁由内核持有，进程无论正常退出还是被杀都自动释放**。文件本身可以残留，**残留不构成拒绝**：唯一判据是 `flock` 能否取得。取得后把持有者信息（pid / 主机名 / 启动时间 / 工具名）写进该文件，**仅供人读诊断**，不参与判定。

   > **为什么不能是 `O_CREAT|O_EXCL` 的存在性锁（R48-F2 修正）**：存在性锁的释放靠「进程记得删文件」，而**被 kill -9 / 断电时它删不掉**。这与 R39-F1「拿不到锁就什么都不做」叠在一起，会造出一个**死锁**：若进程恰好死在**执行阶段中途**，重跑会卡在 ①b 拒绝启动、只能靠人手工删锁才能脱困。**用内核持有的锁，崩溃即释放，重跑天然能完成恢复。**（R69 之后旧报告不再被销毁，故「旧报告已作废、新报告没写」这个更糟的状态已不可能出现；但死锁本身仍要避免。）（本机 staging 是本地盘，`flock` 语义可靠；不用于 SMB 源。）
   - **`qmt_fetch`**：在**任何改动 staging 的动作之前**取得（故崩溃恢复也在锁内），直到**最后一次** manifest 提交后释放（R37-F1：manifest 现在每股提交一次，「manifest 落盘」不再是单一时刻）。
     **两个工具取锁与访问 staging 的方式完全相同（R73-F1）**：
     1. **`stg_fd = open_root(<staging 根>)`**（本文件 §4.1，从 `/` 逐分量 `O_NOFOLLOW`，R75-F2）**并全程持有**（R71-F3）。
        **不是**裸 `os.open(<staging 根>, O_NOFOLLOW)` —— 那只保护最后一段，被换掉的父分量会让
        整棵 staging 钉在**另一棵树**上，此后 `open_under`、`flock`、manifest、CSV 全部落在错的目录里（R76-F1）；
     2. `openat(stg_fd, ".staging.lock", O_CREAT|O_RDWR|O_NOFOLLOW, 0o600)` → **`fstat` 确认普通文件** → `flock(LOCK_EX|LOCK_NB)`；`ELOOP` 或类型不符 → **拒绝启动、一个字节都不写**（R72-F2）；
     2b. **`parent_fd_under(stg_fd, relpath)` —— 命名空间动作的逐段无跟随原语（O2-F4）**：
        `open_under` 只能 `open()`，而按股事务里最关键的三个动作是 `os.replace(.part → final)`、
        回滚 `unlink` 四条路径、对子目录 `fsync` —— 三者都要**父目录 fd + basename**。
        故另定义：逐段 `O_DIRECTORY|O_NOFOLLOW` 走到**父目录**并返回 `(parent_fd, leaf)`；
        `os.replace(a, b, src_dir_fd=, dst_dir_fd=)` / `os.unlink(leaf, dir_fd=)` / `os.fsync(parent_fd)`
        **一律对着它跑**。**与 `open_under` 同规格的三条必须写死（O4-F14）**：
        ①**分量规则相同**：拒绝空分量 / `.` / `..`，逐段 `O_DIRECTORY|O_NOFOLLOW`
          （`.inflight.json` 的形状校验用 `resolve()`，而 `resolve()` **会跟随符号链接**——
          逐段无跟随是最后一道防线，此前这条规则只写在 `open_under` 上）；
        ②**中间 fd 在 `finally` 里关掉**，返回的 `parent_fd` **归调用方，用完必须关**
          （每股泄漏 3~4 个 fd 会让「staging 已被 rename 掉」这类分叉检查拿着陈旧 fd 继续成立）；
        ③**恢复路径上撞 escape 的处置**（`open_under` 那套「删当前股的两个 `.part`」在这里**无路可走**——
          崩溃恢复时没有「当前股」，且删 `.part` 本身又要经 `parent_fd_under`，循环依赖）：
          **不删任何文件、保留 `.inflight.json`、记 `stopped_reason: staging_path_escape` +
          `fetch_fatal_error` 后 rc≠0**。
        ⚠️ **`os.replace` 一律直接传 `src_dir_fd`/`dst_dir_fd`，不得用 `os.supports_dir_fd` 做能力探测**
        （O4-F14，已实测：本机 `os.replace in os.supports_dir_fd` 返回 **False**、`os.rename` 才是 True，
        尽管 `os.replace(..., src_dir_fd=, dst_dir_fd=)` 实际能跑通。按 CPython 文档写防御式能力探测的实现，
        会在 macOS 上**恰好退回 O2-F4 明令禁止的按路径改名**）。
        **不这么做的具体后果**：实施者最自然的写法 `os.unlink(str(staging / rel))` 会让
        `.inflight.json` 的形状校验（只要求 `resolve()` 后落在 staging 之内，而 `resolve()` **会跟随符号链接**）
        放行一条**破坏性恢复路径**删到边界之外 —— 与 R13-F2 给 `.superseded` 立规矩时的论证一字不差，
        只是那次只落在 `--output`，**staging 侧第四次没跟上**。
     3. 此后 staging 内的**每一次读、写、改名、删除、目录 `fsync`**（manifest、`export_log.csv`、K 线 CSV、`.part`、`.inflight.json`、`.staging_owner.json`）**一律经 `open_under()` / `parent_fd_under()` 相对 `stg_fd`**，绝不再由路径字符串解析。

     **`open_under(stg_fd, relpath, ...)`——staging 侧逐段无跟随打开器（R74-F2 补齐，两个工具共用）**：
     ```
     def open_under(stg_fd, relpath, *, flags, mode=0o600, create_dirs=False):
         # relpath 必须是相对路径，且不含 "" / "." / ".." 分量；否则 ValueError
         cur = stg_fd; opened = []
         try:
             *dirs, leaf = split_components(relpath)
             for d in dirs:                       # 逐段走，每段都无跟随
                 if create_dirs:
                     try:
                         os.mkdir(d, 0o700, dir_fd=cur)   # 只创建本工具自己拥有的目录
                         os.fsync(cur)                    # ← O2-F3：新建成功才 fsync 父目录
                     except FileExistsError: pass         #    （耐久提交协议闭合清单第 2 条）
                 nxt = os.open(d, O_RDONLY|O_DIRECTORY|O_NOFOLLOW, dir_fd=cur)
                 opened.append(nxt); cur = nxt    # 目录分量：符号链接与非目录**同为 ENOTDIR**（实测）：都拒绝
             return os.open(leaf, flags|O_NOFOLLOW, mode, dir_fd=cur)
         finally:
             for fd in opened: os.close(fd)
         # 任一 ELOOP / ENOTDIR → **整次致命，不是候选失败**（R89 自查补，与 source 侧
         #   R87-F1 同一判据）：staging 树的路径分量被换成符号链接，是**树布局本身**被动过，
         #   不是「这只股拉不到」——同一目录下所有股都受影响。
         #   · qmt_fetch：删当前股两个 .part、**不记 failure / 不加 attempts / 不推进 cursor**、
         #     manifest 记 stopped_reason: "staging_path_escape" + 顶层
         #     fatal_error: {kind, relative_path, component, errno}（四字段，与读侧逐字相同，
         #     R94-F2）后提交、rc≠0；
         #   · qmt_pilot：整轮 FAIL_STAGING_INTEGRITY + staging_error.kind = "staging_path_escape"、rc=1，
         #     且**在任何 DB 动作与任何股的导入之前**。
     ```
     - **`qmt_fetch` 的每一次写**（含建 `1分钟K线_前复权/` / `日K线_前复权/` 这一级子目录，`create_dirs=True`）；
     - **`qmt_pilot` 的每一次读**（`create_dirs=False`——pilot 从不创建 staging 目录）。

     > **为什么「相对 `stg_fd` 的 `openat`」本身不够（R74-F2 修正）**：staging 保留源的分层结构（`1分钟K线_前复权/<code>_..._前复权.csv`——S2-F1 定源根之后为**一级**中间目录；**逐段无跟随的全部论证照旧成立**，本条要挡的正是这一级被换成符号链接），所以每次读写都要**穿过若干中间目录分量**。`os.open("a/b/c.csv", dir_fd=stg_fd)` 只保证**起点**是 `stg_fd`，`O_NOFOLLOW` 也**只作用于最后一段**——**中间的 `a` 或 `b` 是符号链接时，内核照样跟随**。于是一棵被复用的 staging 里，只要 `1分钟K线_前复权` 被换成指向 staging 之外的链接，`qmt_fetch` 就会把 `.part`/CSV **写到 staging 树外面**，随后 pilot 又会**从树外面读**，而全套 `staging_intact` 哈希校验查的是「同一条路径读回来的字节」——**换过的分量对它完全透明**。
     >
     > 这正是输出侧 `ensure_owned_dir` 逐段校验要挡的那条逃逸，**只是换到了 staging 侧**：R13-F2 立规矩时只把它落在 `--output` 上，`--dest` 这一支再一次没跟上（与 R36-F2、R51-F1 同一处盲区的**第三次**）。**「两个目录」这条同类对象清单，此后必须连「逐段无跟随」一起核，而不只是核「有没有归属标记」。**

     > **为什么这套纪律必须写在本节（R73-F1 修正）**：R71-F3 与 R72-F2 是在 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 里立的，而 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 是 **`qmt_pilot` 的**权威序列；**`qmt_fetch` 的权威序列在 本文件 §4.4/本文件 §4.5**（R44-F1 定的分工）。于是照 fetch 侧权威实施的人，拿到的仍是「`flock(<dest>/.staging.lock)` 然后写持有者信息」——**符号链接照样能把锁与写引到 staging 之外**，而且这发生在任何 CSV / manifest 工作**之前**。**同一条纪律必须写在每个工具各自的权威处，不能指望实施者去读另一个工具的章节。**
   - **`qmt_pilot`**：取/放的**确切位置由 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 权威序列定义**（步骤 ①b 取、**`pilot_report.json` 原子落盘之后**释放；R39-F1）；本节只声明它的存在与语义，不定义过程顺序（R35-F1：过程性规则只在 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2/`2026-07-27-qmt-plan4a-db-guardrails-design.md` §4 定义）。

   > **为什么必须是共用锁而非「fetch 的单写者锁」（R32-F2 修正）**：原设计把它定义成 `qmt_fetch` 自己的锁，`qmt_pilot` **既不取也不尊重**。但 pilot 的 `staging_intact(code)` 是在**哈希完到 `import_qmt_stock` 真正打开文件之间**留有窗口的 —— 一次并发补拉完全可以在这中间把那个 CSV 换掉，于是**入库的字节与 manifest（以及报告里那套哈希基线）不一致**，而三方相等校验、`pilot_stock_source`、源代次扫描全部建立在「staging 在 pilot 运行期间不变」这个**从未被强制过的假设**上。
   >
   > 把锁提升为**staging 生命周期锁**，等于把那个隐含假设变成机器强制：**pilot 运行期间 staging 不可能被改动**。代价是 fetch 与 pilot 不能并发——而它们本来就不该并发。
2. **原子写 + 目录耐久（R45-F2）**：manifest 走 `<dest>/.fetch_manifest.json.tmp` → `fsync(文件)` → `os.replace` → **`fsync(目录)`**。绝不就地截断重写。

   **⚠️ 威胁模型必须显式声明（O4-F11，已在目标平台实测 `man 2 fsync`）**：macOS 的 `fsync(2)` man page 原文写
   「if the drive loses power or the OS crashes, the application may find that only some or none of their data
   was written. The disk drive may also **re-order** the data … **This is not a theoretical edge case.**」
   ——即 `fsync` 在本平台上**既不保证断电耐久、也不保证跨设备写序**。而本节的论证通篇以**断电**为威胁模型
   （O2-F1 那道顺序屏障要的正是 man page 说 `fsync` 给不了的跨设备写序）；反过来，对 §9-5n 明写的
   `SIGKILL` / 进程被杀，页缓存本来就一致，**闭合清单里的 `fsync` 一个都不需要**。
   现形态是「**对进程崩溃多余、对断电不足**」，:577 那条「目录项丢失注入测试」的绿灯**证明不了任何东西**。
   **定案**：**断电在威胁模型之内**。故 **manifest 提交** 与 **O2-F1 那道顺序屏障** 两处改用
   **`fcntl(fd, F_FULLFSYNC)`**（每股 1~2 次，400 股量级完全可接受），其余落地点保留 `fsync`。
   （实测：`fsync(dirfd)` 在本机 APFS 上返回 0，**不会有任何报错提示实施者这层保证并不存在**。）

   **耐久提交协议（唯一权威，本 spec 全部命名空间改动都适用，R45-F2）**：`os.replace` / `os.mkdir` / `unlink` 改的是**目录项**，而目录项的持久化**不由文件的 `fsync` 保证**。故凡改动命名空间之处，都必须在动作之后 **`fsync` 其所在目录**；写文件内容则先 `fsync` 文件本身。

   **入选判据（自查补）**：一个命名空间改动进本清单，当且仅当**它的丢失会改变后续运行的判断**。据此有两类**显式豁免**（写出来是为了让「闭合」可被检验，而不是靠沉默）：
   - `<staging>/.staging.lock` 文件本身的创建——R48-F2 已规定**文件存在与否不参与任何判定**（锁由内核持有），丢了下次重建即可；
   - 失败路径上 `.part` 的删除——`.part` 不匹配导入侧的 glob（本文件 §4.5 已核），残留只会在重试时被覆盖或再删一次。

   适用点逐条列举（**这是一份闭合清单；新增任何落地动作，先回到本清单登记**）：
   - `.part` → final 的两次 `os.replace`（每只股）→ 之后 `fsync(staging 子目录)`
   - **`open_under(..., create_dirs=True)` 新建的每一级 staging 子目录**（`1分钟K线_前复权/`、`日K线_前复权/`）→ **每新建一级，`fsync` 它的父目录**（R84-F2）
   - **崩溃回滚删除两条 final target** → **先 `fsync` 各自所在子目录，才允许删 `.inflight.json`**（O2-F1）：
     `.inflight.json` 是**授权删除那四条路径的唯一凭据**，**它必须比被它授权的动作后消失**。
     否则断电后可能「标记的删除已持久、manifest 提交已持久，而两条 final 的 unlink 丢失」→
     重跑时恢复流程找不到标记 → 什么都不做 → 撞四象限表「目标存在 × manifest 无记录」→
     `untracked_target_file` + 推进 cursor → **这只股被永久踢出池**，而按股事务的全部目的就是消灭这个状态。
     窗口不是窄 race：子目录的目录项回写默认可晚几十秒。（`.part` 的删除继续豁免——它不匹配导入侧 glob。）
   - `.inflight.json` 的**创建**与**删除** → 各自之后 `fsync(staging)`
   - `<staging>/export_log.csv` 的 `os.replace` → 之后 `fsync(staging)`
   - `fetch_manifest.json` 的每一次提交 → 之后 `fsync(staging)`
   - **`<dest>` / `<output>` 的 `os.mkdir` 与归属标记创建** → `fsync(文件)` + `fsync(该目录)` + **`fsync(父目录)`**（R51-F1 + R64-F1）
   - zip 的 `os.replace`、`.superseded/` 的挪入挪出 → 之后 `fsync(相关目录)`
   - **owned zip 的 `unlink`**（`try_one` 分支③ 的白名单删除）与**成功后删掉 `.superseded/` 里那一份** → 之后 `fsync(相关目录)`（自查补：删除同样是目录项改动）
   - **两份报告的落盘**（`pilot_report-<seed>-<UTC>.json` 不可变文件 + 刷新 `pilot_report.json`）→ 每份之后 `fsync(<output>)`（R69）
   - **最终 `pilot_report.json` 的落盘**（tmp → `fsync(文件)` → `os.replace` → **`fsync(<output>)`**）——**含成功报告与一切失败报告**（R51-F1）

   > **最终报告这一条尤其不能漏（R51-F1 修正）**：作废发生在执行阶段**之前**，新报告落盘发生在**最后**。若断电发生在「新报告 `os.replace` 已返回、`fsync(<output>)` 还没做」这个窗口里，**目录项可能丢失** —— 结果是**旧报告已被中和/删除、新报告没能持久化**，目录里没有任何当前证据。这正是 R31-F3 立的不变量所禁止的那个状态，而且它是**整条流水线上最后一次写**：前面所有耐久性功夫都白做，唯独在交付物本身上漏了。同理 `<dest>` 那一支漏掉后，一棵已经拉好几百个 CSV 的 staging 会在崩溃后**变成无主目录**（`.staging_owner.json` 的目录项没落地），下次 `qmt_fetch` 按「首次使用须路径不存在」直接拒绝，整批数据只能人工处理。
   >
   > **我把它叫做「闭合清单」，却漏了两项** —— 而且漏掉的恰是**交付物本身**和 **`--dest` 那一支**（与 R36-F2「结论只应用到 `--output`、漏了 `--dest`」是同一处盲区的第二次）。**声明一份清单是闭合的，本身不构成它闭合**；此后新增任何落地动作，先回到本清单登记。

   > **为什么少了目录 fsync 就等于没有事务（R45-F2 修正）**：按股事务把「两个 final 文件」与「manifest 里那两条记录」绑成一次提交，可两者是**两次独立的目录项变更**。断电后，文件系统完全可能**只持久化了 rename、没持久化 manifest 的 replace**（或反过来）——于是重启后 staging 里躺着两个 final 文件而 manifest 无记录，**正是按股事务要消灭的那个状态**：下一次运行判 `untracked_target_file`、把这只股永久除名、池静默缩水、pilot 报出假的池穷尽。**R37-F1 设计了事务，却没给它配上让提交真正落地的手段**——「原子」（`os.replace` 不会看到半截）与「耐久」（崩溃后仍在）是两件事，我只做了前者。
   >
   > 崩溃注入测试也要跟着分层：不只测「文件内容截断」，还要测**「目录项丢失」**（rename 或 unlink 未持久化）。
   >
   > **子目录创建也在其中（R84-F2 补）**：staging 保留源的分层结构，那些中间目录是 `open_under(create_dirs=True)` 建的，**却没进这份清单**。后果与 R45-F2 论证的完全同构、只是层级更高一层：manifest 已经提交了「某只股的两个文件在 `1分钟K线_前复权/` 下」这条记录，而**那个目录的目录项没落地** → 重启后记录在、文件不在、目录也不在。此时既不是 `untracked_target_file`（那要求文件存在），也不会被在途标记回收（标记早删了）——**它会表现为一只被静默记成「已拉过」却读不到的股**，最终以假的 `staging_integrity_mismatch` 或假的池穷尽收场。**「入选判据 = 它的丢失会改变后续运行的判断」这条判据是对的，我只是没把 `mkdir` 当成一次命名空间改动。**
3. **读侧校验**：`qmt_fetch` 与 `qmt_pilot` 读 manifest 时都必须过形状校验，任一不满足即 **fail-closed 拒绝**，不做「尽力而为地解析」：
   - 必需键齐全（**外延写死**：`manifest_version` / `seed` / `source_snapshot` / **`source_mount`** /
     `pool_order` / `cursor` / `files` / `staged_export_log` / `source_verification` /
     `source_verification_evidence`；O4-F7 + O4-F10：`source_mount` 此前只在散文里被声称「已进必需键」，
     实际逐条枚举里没有它）；`seed` 非空；`source_snapshot.universe` 三层皆为 list
     > **顶层 `universe` 是笔误，已删（S2-F3）**：原枚举把 `universe` 列为**顶层**必需键，而**同一句话
     > 末尾**校验的却是 `source_snapshot.universe`；写侧（本节「写 `fetch_manifest.json`」那一条）与
     > §4.4 的结构示例也**只产出 `source_snapshot.universe`，从不产出顶层 `universe`**。
     > 照原文实现的后果是：**本工具诚实产出的每一份 manifest 都被本工具自己的读侧判
     > `FAIL_MANIFEST_INVALID`**，一次都跑不通。
     > **这是「写侧形状与读侧要求不配对」的第三次**（前两次：R94-F2 的 `fetch_fatal_error`
     > 三字段 vs 四字段、O4-F13 的 `files_verified` 是 `2N` 还是 `2N+1`）——三次都由同一条纪律
     > 拦得住：**每新增一个持久化字段，必须同时在写侧枚举与读侧枚举里各出现一次，且层级逐字相同**。
     > 名单的唯一位置是 **`source_snapshot.universe`**。
   - **`source_mount` 的形状**：`{fstype, device, source_root_relative}` 三子键齐全且均为 str；
     **`fstype` / `device` 非空；`source_root_relative` 允许为空串（S2-F2 更正）**
     > **原文的「三者均为非空」与 §4.6 (ii-a) 直接冲突**：(ii-a) 用实测论证了「共享本身就是导出根」
     > 时 `source_root_relative` **就是空串**，并规定拼接走 `posixpath.normpath` 以免撞空分量。
     > 两条并存时，一次完全合法的部署会**先过 (ii-a) 的拼接、再被读侧的「非空」判死**——
     > 而操作者收到的指引指向一个不存在的问题。保留 (ii-a)（它有实测支撑），读侧放宽为「必须是 str」。
   - **读到不认识的顶层键必须原样保留回写，不得丢弃**（O4-F10：旧工具消费新版 manifest 后回写会把
     不认识的字段丢掉 → 再用新工具打开时缺必需字段 → 一棵 400 只股的 staging 被一次「用错版本跑补拉」永久毁掉）
   - **`pool_order` 三层皆为 list，每个元素是对象 `{code: str, universe_idx: int}`**（R13-F1：R12-F1 把元素从裸字符串改成了带锚点的对象，本校验必须同步，否则实现要么拒绝合法 manifest、要么退回字符串而丢掉 `universe_idx`，把 R12-F1 那个「产出取决于网络抖动」的口子重新打开）
   - `code` 匹配 `^\d+\.(SH|SZ|BJ)$` **且后缀与所在层一致**
   - `universe_idx` 在 `[0, len(source_snapshot.universe[market]))` 范围内，**且 `source_snapshot.universe[market][universe_idx] == code`**（交叉核对锚点真的指向它自称的那只股）
   - 层内 `code` 与 `universe_idx` **各自唯一**
   - `cursor[market]` 为整数且在 `[0, len(source_snapshot.universe[market])]` 内
   - **实拷清单（`files`）必须逐项合规（R21-F3）**——它是 `staging_intact`、`pilot_stock_source`、三方源校验**共同的真相基准**，却一直不在本校验的枚举里：
     - `pool_order` 里的**每一只**股恰好对应 **2 条**记录，`period` 分别为 `1m` 与 `daily`；**不得缺、不得重、不得有不属于任何 `pool_order` 股的多余活跃记录**
     - 每条的 `relative_path` 经**分量规则**（S1 的 `split_relative_components`：拒绝绝对路径 / 空分量 / `.` / `..`）校验后**必须落在 staging 之内**（S2-F6：**不用 `resolve()`**——它会跟随符号链接，且要碰文件系统；真正的符号链接防线在打开那一刻由 `open_under` 逐段 `O_NOFOLLOW` 承担），且其**文件名解析出的 code/period 与该记录的 `stock_code`/`period` 一致**（用 `qmt_normalize.parse_qmt_filename` 的同一套规则）
     - `bytes` 为非负整数；`sha256` 匹配 `^[0-9a-f]{64}$`

   - **顶层 `manifest_version: <int>` 必填，且旧版本要有出路（O2-F8）**：读侧在三轮内**追加过三次必需字段**
     （`staged_export_log` / 对象型 `pool_order` / `stopped_reason`），每次都让**既有 staging 永久不可用**：
     一棵已拉 400 只股（约 2 GiB）的旧 staging，升级后既不能复用（manifest 非法）、也不是引导态（manifest 存在）、
     也不能首次使用（目录存在且标记合法）→ **工具自己解不开，而 spec 没有任何一行告诉操作者该怎么办**
     （对比：无标记空目录那一档至少写了「请手工 `rmdir`」）。且读者**无法区分**「旧版本写的」与「被篡改的」，
     正因如此更需要一条出路。
     **规定（三档，O4-F10：此前只有「低于」一档在 §4，「大于」「缺失」只在 §5）**：
     `manifest_version` **低于**本工具 → 给出与「形状非法」**不同**的错误与指引；
     **大于** → 拒绝并提示「由更新版本产出，请用对应版本或换新 staging」；**缺失** → 视为 `0`。
     原文只写「低于」→ 一份版本更高的 manifest 是合法 int、形状全过 → **旧工具照常消费并就地更新**，
     把不认识的新版必需字段丢掉 → 再用新工具打开即 `FAIL_MANIFEST_INVALID`。
     补充原「低于」档的说明
     （「该 staging 由旧版本产出，请换新 staging + 新 seed 重拉」）；**新增任何必需字段必须 bump 版本**
     （写进本文件 §11 的五条机械检查——现有第 5 条只问「谁写谁读谁清」，**没问「旧数据怎么办」**）。
     **不做迁移机制**（YAGNI：本 plan 的 staging 是本机可重建的中间产物，不是用户数据）。
   - **顶层 `stopped_reason` / `fetch_fatal_error` 必须被读侧校验并分支（R93-F1）**：`stopped_reason` 是
     **可选字段，但若存在则必须落在闭合枚举**
     `{max_bytes, source_path_escape, staging_path_escape, staging_recheck_failed}` 内（O4-F3 补第四值），
     且 `source_path_escape` / `staging_path_escape` / `staging_recheck_failed` **三值必须同时带**形状合规的顶层
     `fetch_fatal_error: {kind, relative_path, component, errno}`
     （⚠️ **`kind` 与 `stopped_reason` 解耦**，O4-F3：`kind` 记录**首次逃逸**的类型，
     而 `stopped_reason` 是本次为什么停 —— 复校失败那一档正是「保留 fatal + 换 `stopped_reason`」，
     写成「`kind` 恒等于 `stopped_reason`」会让它**结构上不可表达**）；不合规 →
     **拒绝整个 manifest**（`FAIL_MANIFEST_INVALID`）。
     **并在 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 步骤 ② 内立即分支**（早于 ②b、早于任何 DB 动作与任何股的消费）：
       ⚠️ **先判 `fetch_fatal_error` 是否存在：存在即无条件 fail-closed，按 `kind` 映射**（O4-F1）；
       不存在才按 `stopped_reason` 走。**绝不拿 `stopped_reason` 取值当安全判据**——
       它会被后续运行的 `max_bytes` 洗掉，而 `fetch_fatal_error` 是粘性的信任状态。
       · `fetch_fatal_error.kind == "source_path_escape"` → **`FAIL_SOURCE_BOUNDARY` + `source_path_escape`**、rc=1；
       · `stopped_reason == "staging_path_escape"` → **`FAIL_STAGING_INTEGRITY` +
         `staging_error{kind: "staging_path_escape", …}`**、rc=1；
       · `stopped_reason == "max_bytes"` → **放行**（那是一次干净的配额终止，已拉到的股完全可用，R44-F2）。

     > **为什么必须写进读侧校验（R93-F1 修正）**：`stopped_reason` 是 R87-F1 / R89 自查补引入的
     > **fetch 侧致命信号**，§5 也写了「pilot 读到即 fail-closed」——**可这份「读侧校验清单」
     > 从头到尾没提过它**。而一次被源树逃逸终止的 fetch，其 manifest **仍然带着此前成功拉到的
     > `pool_order` 与 `files` 记录**，形状上完全合法。照这份清单实现的 pilot 会**照常消费那批股**，
     > 把一次**信任边界破坏**报成「候选不够」甚至走到 `SUCCESS`。
     > **一个信号只有同时进了「写侧规定」与「读侧校验」，它才真的存在。**

   - **`staged_export_log` 必须存在且自洽（R38-F1）**：`relative_path` 经**分量规则**校验后落在 staging 之内（S2-F6，同上）；`bytes` 为非负整数；`sha256` 匹配 `^[0-9a-f]{64}$` **且等于 `source_snapshot.export_log_sha256`**（同一份字节的两处记录，不等即 manifest 自相矛盾）。缺失或不自洽 → 拒绝整个 manifest。

     任一不符 → **拒绝整个 manifest，且必须发生在任何 DB 写入之前**。

     > **为什么必须校验它（R21-F3 修正）**：后续三道完整性闸全部把这份清单当**权威**用——`staging_intact` 拿它比对 staged 文件、`pilot_stock_source` 拿它写入逐股源身份、三方校验拿它当第三方。而读侧校验此前只枚举了 `universe`/`pool_order`/`cursor`/证据存根，**唯独漏了这份被最广泛信任的结构**。一份被编辑过或半截写入的 manifest 可以形状全过，却给某只股缺一条、重一条、或把 1m 的哈希绑到 daily 上 —— 结果要么跑到很晚才崩，要么**校验的字节与导入器实际消费的字节根本不是同一批**。这与 R12-F2（新增安全表没进结构闸）、R13-F1（改了数据结构没同步校验）是同一模式的第三次：**被信任的结构，自己没有被校验**。
   - **`source_verification` 必须携带与其级别相符的证据（R15-F2 + R16-F1）**，缺失或不自洽即拒绝整个 manifest。证据分**两类，缺一不可**：

     **(a) 前置输入**（证明操作者提供了该级别要求的声明）
     | 级别 | 必需输入 |
     |---|---|
     | `snapshot` | `source_snapshot.gmt_token` 存在且匹配 `^@GMT-\d{4}\.\d{2}\.\d{2}-\d{2}\.\d{2}\.\d{2}$` |
     | `full` | `operator_attestation.no_export_window == true`，且带记录时间 |
     | `partial` | 无 |

     **(b) 校验过程存根 `source_verification_evidence`（R16-F1）**——证明校验**真的跑过**：
     ```jsonc
     "source_verification_evidence": {
       "level": "snapshot|full|partial",
       "mount_check": {"gmt_token": "@GMT-…", "verified_against_mount": true},  // 仅 snapshot
       "passes": [                                    // snapshot 一趟；full 两趟
         {"pass": 1, "files_verified": 813, "aggregate_sha256": "…", "completed_at": "…"},   // = 2×406 股 + 1 份 staged export_log
         {"pass": 2, "files_verified": 813, "aggregate_sha256": "…", "completed_at": "…"}
       ],
       "passes_agree": true                           // 仅 full：pass1 与 pass2 的聚合摘要相等
     }
     ```
     `aggregate_sha256` = 对「全部已校验文件的 `(相对路径, 文件 sha256)` 排序列表」取 sha256。
     **序列化方式写死（S2-F4）——两个工具必须算出同一个数，故拼法不许各写各的**：

     ```python
     pairs = sorted(members)          # members = [(relative_path, sha256), ...]；相对路径在全集内唯一
     blob  = json.dumps([[r, s] for r, s in pairs],
                        ensure_ascii=False, separators=(",", ":")).encode("utf-8")
     aggregate_sha256 = hashlib.sha256(blob).hexdigest()
     ```

     `ensure_ascii=False` 与 `separators` **都是判据的一部分**（周期目录名是中文，两个取值会产出
     完全不同的字节）。**本算法由 4b 提供唯一实现，4c 直接调用，不得各自重写。**
     > **为什么必须写死（S2-F4）**：原文只说「排序列表取 sha256」，**没定义这个列表怎么拼成字节**。
     > 而写这个数的是 `qmt_fetch`（4b）、拿它比对的是 `qmt_pilot`（4c）——两个切片、两份 plan、
     > 不同时间实施。拼法差一个空格或一个 `\uXXXX` 转义，**每一份诚实产出的 manifest 都会被读侧
     > 判非法**。与 S2-F3 / R94-F2 / O4-F13 同族，只是这次跨的是**两个工具**而不是**读写两侧**。
     **成员集合写死（O2-F12）：`files` 的每一条 + `staged_export_log` 一条；`files_verified` 是同一集合的基数
     （故它恒为奇数 `2N+1`，N = 已拷股数）。**

     **⚠️ per-stock 提交时这两个字段的取值必须写死（O4-F2）**：`source_verification: "partial"` +
     `source_verification_evidence: {"level": "partial", "passes": []}`。
     并且**趟数 / `passes_agree` / `aggregate_sha256` / `files_verified` 的一致性校验只适用于
     `snapshot` / `full` 两级**——**`partial` 级的 manifest 永远可读**。
     **不写死会让崩溃恢复整个够不着**：存根只能由**批后**的收尾复校产出，而首次 fetch 跑到第 200 只股被
     SIGKILL 时，磁盘上那份 manifest 有 400 条 `files`、没有存根 → 读侧 fail-closed 拒绝 →
     而 §4.5 明写「崩溃恢复在**读完并校验 manifest 之后**」→ `.inflight.json` 回滚、幂等四象限、
     按股事务**一条都执行不到**，§9-5n 那条「执行阶段 SIGKILL → 原样重跑自愈」的回归钉写出来就是红的，
     代价是一棵 2 GiB 的 staging。
     原文写侧含 `export_log.csv`（收尾复校覆盖它），读侧却要求「由 manifest 自身逐文件记录重算」而 `files`
     里没有它 —— **差一项就让每一份诚实产出的 manifest 都被判 `FAIL_MANIFEST_INVALID`**（与 R94-F2 同类）。

     读侧强制：`snapshot` 须 `verified_against_mount == true` 且恰有 1 趟；`full` 须恰有 2 趟且 `passes_agree == true` 且两趟聚合摘要相等；`files_verified` 须等于 **`len(files) + 1`**（O4-F13：原文「已成功拷贝的文件数」自然读法是 `2N`，与 O2-F12 写死的 `2N+1` 互斥，两边照哪个实现都会让另一边全红）；**两级都须让 `aggregate_sha256` 与「由 manifest 自身的逐文件 sha256 记录重算出的聚合」逐字相符**；`files_verified` 须等于 manifest 里已成功拷贝的文件数。任一不符 → 拒绝整个 manifest。

     **这套校验的作用域仅限于此：把畸形/不自洽的 manifest 挡在门外（fail-closed）。它不授予、也不参与任何出货资格判定（R17-F2 / R18-F2）。** `ship_eligible` 是派生量 `≡ (final_verdict == "SUCCESS")`（R26-F1），与本节无关。

     > **为什么「输入」不够、必须要过程存根（R16-F1 修正）**：`operator_attestation` 只证明操作者**按下了那个开关**，`gmt_token` 只证明**传了一个形状对的字符串**——两者都**不证明那两趟全量哈希校验真的跑过、且结果一致**。一份版本错位、截断或手工编辑的 manifest，完全可以同时具备 `source_verification: "full"` 与 attestation，而校验从未发生。
     >
     > **⚠️ 但存根本身是自指的，它不足以支撑出货资格（R17-F2 更正）**：上述校验拿 `aggregate_sha256` 与「manifest **自己记录的**逐文件 sha256」比对，因此它证明的只是**这份 manifest 内部自洽**，**不证明校验进程真的去读过 SMB 源**。手工编辑者完全可以自填哈希、自算聚合、自称 `full`。R16 曾在此写下「能伪造聚合摘要就等于真做过校验」——**那句话是错的**，聚合摘要恰恰可以在完全不碰源的情况下算出来。
     >
     > 故 manifest 侧的这套校验**降级为「一致性检查」**：它能挡住截断、版本错位、字段缺失，但**不再单独授予任何出货资格**。出货资格改由 pilot 自己读源来挣（见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3「出货级源校验」）。

   理由：一个被截断的 manifest 解析出来往往仍是合法 JSON 的前缀片段，静默消费它 = 把 manifest 损坏伪装成「候选就这么多」。而锚点交叉核对则让手工编辑/错位的 manifest 无法冒充合法输入。

   > **证据字段必须在读侧被核实，而不只是在写侧被记录（R15-F2 修正）**：R10-F3 解决的是「证据无处可记」——加了 `--snapshot-gmt-token` 与 `--confirm-no-export-window`。但**读侧从未被要求去核实它们真的在**。于是版本错位、半截写入、或手工编辑出来的 manifest 里，一个光秃秃的 `source_verification: "full"` 字符串就足以让 `qmt_pilot` 判出 `ship_eligible: true` —— 而 本文件 §4.4 声称属于该级别必要条件的那份证据**整个缺席**。写侧记录与读侧校验是两件事，**只做前者等于把出货闸建立在一个可以凭空写下的字符串上**。


### 4.6 源边界闸（七条全过才算「源」；两个工具共用同一判据）

  **⚠️ `qmt_fetch` 的权威启动序列（O4-F7 —— 谓词必须有确定的求值时刻）**：

  ```
  open_root(--dest)  →  取 .staging.lock (LOCK_EX)  →  读并校验 manifest  →  【判模式】
    →  源边界闸（open_root(--source) 在此，不在最前）  →  崩溃恢复  →  拷贝循环
  ```
  **不写这条序列的后果**：§4.6 第 0 步写着「`src_fd = open_root(--source)` **必须最先做**」，
  照它直译的实现会在**读 manifest 之前**跑完整套闸，此刻「没有 manifest」恒为真 →
  **每一次补拉都跑立基准模式** → 把 `--source` 指到同一 SMB 共享下的陈旧兄弟目录
  （`…/backup_2026_06/`，其 `export_log.csv` 与当初逐字节相同）时，第 3/4/4b 条全换成「据 `src_fd` 派生并记录」
  → `fstype == smbfs` 通过 → **工具重写 `source_mount.source_root_relative` 指向兄弟目录** →
  新拉的 K 线来自旧代次，而 pilot 的比对基准已被本次运行改写，三方哈希自洽 → 一路 `SUCCESS`。
  **R23-F1 的陈旧兄弟目录洞原样复活**，且所有反向验证都作用在一个被本次运行重写过的基准上。

  **⚠️ 本闸分两种模式（O2-F5；不分模式则首次 fetch 结构上跑不起来，或它自己立基准时零检查）**：

  | 模式 | 谁 | 第 2 条的 `out_fd` 半边 | 第 3/4/4b 条「与 manifest 相符」 |
  |---|---|---|---|
  | **立基准模式** | **首次 `qmt_fetch`**（正在**创建**这份 manifest） | **不适用**：`qmt_fetch` 根本没有 `--output` 参数 → 只比 `stg_fd` | 换成「**据 `src_fd` 派生并记录**」；第 4 条的**绝对要求部分仍强制**（`fstype == "smbfs"` + device 形状合法） |
  | **比对模式** | 补拉 `qmt_fetch` / 全部 `qmt_pilot` | pilot 侧：已归属支比 `out_fd`；**首次使用支此刻 `--output` 必然不存在 → 该半边恒真、显式跳过**，并在 ⑥ 认领成功后补做一次 | 全部强制逐项相符 |

  **⚠️ 立基准模式里那条「`fstype == "smbfs"` 仍强制」的可测形态必须写死（P2-F4）**：
  `tmp_path` 永远是 `apfs`，而 §4.1 说「可用本地 `tmp_path` 伪源做**完整**单测」、§6 说「L2 `tmp_path`
  伪源端到端、本 PR 不依赖真 SMB 源」、§8 说「4a/4b 的自动化验证均不依赖源机」——
  **首次 fetch 这条主路径在自动化里一次都跑不起来**（连带 §9 的 5c/5d/5f/5k/5l 全部依赖先有一份 manifest）。
  实施者只剩一条路：加一个 spec 里不存在的旁路（env 或 `--allow-nonsmb-source`），
  **而那个旁路一旦存在就是「两个模式之间可被选择的余地」**——它会同时关掉挂载身份闸，
  正是 R19-F2 要堵的本地克隆档。（`ST_RDONLY` 那条只读还能用只读磁盘映像满足；
  **`smbfs` 在无真 SMB 服务端时完全无法伪造**。）

  **定案：把「挂载表解析 + fstype/device 判定」定义成一个可注入的纯函数**
  ```python
  def resolve_mount_identity(src_fd, *, mount_table_reader=_read_system_mount_table): ...
  ```
  - **生产默认不变**：缺省读 `/sbin/mount` 的真实输出，**没有任何 CLI 开关或 env 能改它**；
  - **测试注入伪挂载表**——注入点在**函数签名**，不是 env、不是 flag，**产品代码路径上不可达**；
  - §6 的 L1/L2 用注入覆盖立基准模式；**真 SMB 的 `fstype` 只在 L3 人工验收里被真正验证一次**，
    §8 如实登记这条残余（「`smbfs` 判定在自动化里是注入的，真值只由 L3 覆盖」）。
  **不选另一条路**（「首次 fetch 的边界闸只能在 L3 覆盖」）：那会让 §9 的五条验收项全部悬空。

  > **为什么必须显式分模式**：第 3 条要求源 `export_log.csv` 的 sha256 等于 **manifest 的** `source_snapshot.export_log_sha256`，
  > 第 4/4b 条要求挂载身份与 `source_mount` 逐项相符 —— 而**首次 fetch 正是创建这份 manifest 的那一次**，没有任何东西可比。
  > 实施者只有两条路：(a) 照字面实现 → **首次 fetch 永远过不了闸，工具产不出第一份 manifest**（自锁的初始状态）；
  > (b) 首次跳过 3/4/4b → **fetch 在写下 `source_mount` 这份此后一切比对的基准时，自己没做过任何挂载身份检查**，
  > 基准可以是本地只读克隆或同一共享下的陈旧兄弟目录，而后续所有运行都会与这个**未经检查的基准**「一致」。
  > 那正是 R19-F2 / R23-F1 要堵的两档，只是从「校验侧」挪到了「立基准侧」。

  **源边界闸（R18-F1 + R19-F2 + R23-F1 + R82-F1 + **R84-F1 重排** + **O2-F5 分模式**，**七条**全过才算「源」）**：

  **第 0 步（必须最先做，R84-F1）：`src_fd = open_root(--source)` 并全程持有。**
  **此后的每一条闸都对着 `src_fd` 跑，不再由 `--source` 这个字符串二次解析路径。**

  > **为什么顺序在这里是安全性的一部分（R84-F1 修正）**：R82-F1 我把 `open_root` 写成了**第 4c 条**——
  > 排在只读、重叠、`export_log` 哈希、挂载身份这四条**按路径做的**检查之后。而 `--source`
  > **没有归属标记、也没有锁**（它不是我们的目录），**没有任何东西阻止它在这几条检查之间被换掉**：
  > 前四条在真 SMB 源上跑通，随后路径被改指到一个只读本地克隆，`open_root` 钉住的就是**克隆**——
  > 而 4c 的分叉检查比对的是「已经被换过的路径」与「刚刚打开的 fd」，**两者当然一致**。
  > 于是 pilot 读的、哈希的、写进三方相等等式的，全是那份从未通过边界闸的字节。
  > **这正是 R71-F3 在 staging 上立的「先钉住再校验」，我在 source 上写成了「先校验再钉住」。**
  > **一条「先 X 后 Y」的纪律，方向反了就等于没有。**

  1. **只读**：**`os.fstatvfs(src_fd)`**`.f_flag & os.ST_RDONLY` 为真（同 本文件 §4.1 的非写入式判据；
     **对 fd 而非对路径**，R84-F1）。
  2. **与 staging / output 无重叠**：`resolve()` 后 `--source` 不得等于、包含、或被包含于 `--staging` 与 `--output` 中的任何一个；**并另比 `(st_dev, st_ino)`**——`os.fstat(src_fd)` 不得等于 `os.fstat(stg_fd)` 或 `os.fstat(out_fd)`（R84-F1：路径判据可被换掉，inode 判据不会）。
  3. **是那份导出**：**`open_under(src_fd, "export_log.csv", create_dirs=False)`** 读到的那一份存在，且其 sha256 **等于 manifest 的 `source_snapshot.export_log_sha256`**（R84-F1：经钉住的 fd 读，不按路径读）。
  4. **挂载身份相符——判据必须由 `src_fd` 派生，不得再解析 `--source`（R19-F2 + R91-F1）**：
     解析挂载表（`/sbin/mount` 输出，格式 `<device> on <mountpoint> (<fstype>, <opts…>)`），
     **定位挂载点的方式是：逐条 `os.stat(mountpoint).st_dev`，取与 `os.fstat(src_fd).st_dev` 相等的那一条**
     （**不是**「找包含 `--source` 这个字符串的那一条」）。要求与 manifest `source_mount` 记录**逐项相符**：
     `fstype == "smbfs"`、`device` 相等 —— **比对前必须剥掉 `user@` 部分，判据 = `//<server>/<share>`**（O2-F13：
     macOS `mount` 输出确实带 `agate@`，但**用户名是凭据、不是共享身份**；控制者换个账号重挂同一共享就会
     device 串不等 → 一次共享没换、目录没换、内容没换的合法出货被拒 —— 与 R25-F2 论证的
     `/Volumes/QMT_Export-1` 那一档一模一样。原始串仍全文记进 manifest 留痕）；
     `snapshot` 级另须 `gmt_token` 相符。

     > **为什么按路径定位挂载点会让整套边界失效（R91-F1 修正）**：R84-F1 把 `open_root` 前移到第 0 步，
     > 我以为「其后全部对着 fd 跑」就闭合了——**可这一条仍写着「定位包含 `--source` 的挂载点」**。
     > `--source` 没有锁、没有归属标记，于是这条时序是通的：`src_fd` 已钉在一个**只读本地克隆**上，
     > 此刻把 `--source` **换回真 SMB 路径** → 挂载表查到的是**真 SMB 的 `smbfs` + device**，第 4 条通过；
     > 再**换回克隆**，第 4c 条的 `(st_dev, st_ino)` 分叉检查比对的是「克隆路径」与「克隆 fd」，**也通过**。
     > **结果：哈希的是克隆的字节，报告里写的却是 SMB 导出的身份——一份彻头彻尾的假出货凭据。**
     > **把「fd 派生」写成一句总纲是不够的，每一条子判据都要逐条落实到 fd 上。**

  4b. **就是当初那个导出根——判据为「共享内相对路径」，且必须反向验证到 `src_fd`
     （R23-F1 + R25-F2 + R91-F1 合并为一条；R93-F2 删去旧版重复条款）**：
       (i) `source_root_relative` **只在第 0 步钉住的那一刻**从当时的路径算出一次；
       (ii) 它必须与 manifest 的 `source_mount.source_root_relative` **逐字相等**；
       **(ii-a) `source_root_relative` 允许为空串（O2-F6，已实测）**：本文件给的挂载示例把共享挂在
             `/Volumes/QMT_Export`；**当那个共享本身就是导出根**（`export_log.csv` 与两个 K 线目录
             直接躺在共享根下）时，**`--source` 就是挂载点本身、`source_root_relative` 为空串**。
             （真实的那台机器不是这个形态——它的导出根是共享内的 `front_ratio_cn_stocks_ab_bj/`，
             故 `source_root_relative` 非空；但「共享直接挂在导出根这一层」是**完全合法的部署**，
             不得因此被拒，S2-F2。）此时若按 `mountpoint + "/" + rel`
             拼接，得到 `/Volumes/QMT_Export/`，`split('/')` 产生**尾部空分量** → 撞 `open_root` 的
             「拒绝空分量」判据 → **一次完全合法的部署被 `FAIL_SOURCE_BOUNDARY` + `source_root_mismatch` 拒掉**，
             把配置正确的操作者引向不存在的问题。
             > **⚠️ 实测坐实（2026-07-27）**：`"/Volumes/QMT_Export" + "/" + ""` → `'/Volumes/QMT_Export/'`；
             > `.split('/')` → `['', 'Volumes', 'QMT_Export', '']`，末位空分量确实存在。
             **规定**：拼接一律走 `posixpath.normpath(posixpath.join(mountpoint, rel))`（空串时得 `mountpoint` 本身）。
       **(ii-b) 源根的定义写死（O2-F6；判据经真实导出实测后由 S2-F1 更正）**：
             **`--source` = 包含 `export_log.csv` 的那一层**，**不认目录名字**。
             它决定 manifest 里每条 `relative_path` 的形状与 `open_under` 要走几段，**必须唯一**。
             > **⚠️ O2-F6 的原判据在真实导出上无解（S2-F1，2026-08-23 挂载实测）**：原文写「包含
             > `front_ratio_cn_stocks_ab_bj/` **与** `export_log.csv` 的那一层」，而真实布局里
             > **这两样不在同一层**——`export_log.csv` 在 `front_ratio_cn_stocks_ab_bj/` **里面**，
             > 与两个 K 线目录并列。照原判据取上一层（共享根），则 `<source>/export_log.csv` **不存在**
             > → **源边界闸第 3 条当场判死**，一次完全合法的部署永远过不了闸。
             > 改用「含 `export_log.csv` 的那一层」后：闸 3 天然满足；源根在真实布局里就是
             > `front_ratio_cn_stocks_ab_bj/` 本身；且**不写死目录名**——那个名字是 QMT 导出脚本的
             > 产物名，把它钉进代码等于让一次导出脚本改名就废掉整个工具。
             > **唯一性**由操作者传的 `--source` 保证，**同一性**由 (ii) 逐字相等 + (iii) 反向验证保证
             > ——正是第 4 闸「绑得住共享、绑不住共享内哪个目录」那条论证要覆盖的场景。
       (iii) **反向验证**：`open_root(<第 4 条按 `st_dev` 定位到的 mountpoint> + "/" + source_root_relative)`
             得到的 `(st_dev, st_ino)` 必须**等于** `os.fstat(src_fd)`。
       任一不满足 → `FAIL_SOURCE_BOUNDARY` + `source_root_mismatch`。
     **绝对路径不参与判定**，只作现场留痕写进报告（`pilot_source_verification.source_abspath`）。

     > **(iii) 不是可选的历史注记（R93-F2）**：R91-F1 补上它之后，我**把旧版 4b（只要求字符串相等）
     > 留在了同一张权威清单里、而且排在新条之后**。实施者照「看得见的七条」逐条实现，完全可能
     > 只做到 (ii) 就收工——**而 R91-F1 描述的克隆调包攻击恰恰只被 (iii) 挡住**。
     > **一条规则被加强之后，旧版本必须删掉或并入，不能作为「另一条」并存**——并存时
     > 后来者读到的是「有两条要求」，实际做到的往往是「较松的那条」。
  4c. **源树内部逐段无跟随（R82-F1；`open_root` 已前移为第 0 步，R84-F1）**：`--source` 与
      `--dest`/`--staging`/`--output` **同规格**——`src_fd` 已在第 0 步钉住并全程持有；此后
      `<source>/export_log.csv` 与**每一个** K 线 CSV 的读取**一律经 `open_under(src_fd, relative_path,
      create_dirs=False)`**（逐分量 `O_DIRECTORY|O_NOFOLLOW`，拒 `..` / 符号链接 / 非目录分量）。
      **`qmt_fetch` 的拷贝读与 `qmt_pilot` 的三方校验读都走它**。任一分量撞 `ELOOP`/`ENOTDIR` →
      `FAIL_SOURCE_BOUNDARY` + **`source_boundary_error: "source_path_escape"`**（逐股读时该股记
      `source_path_escape` 并使本次运行判该 verdict——源侧逃逸不是「跳过一只股」能了结的）。
      **另加运行中途分叉检查**：与 `--output`/`--staging` 同规格，比对 `os.stat(--source)` 与
      `os.fstat(src_fd)` 的 `(st_dev, st_ino)`。
      **`--source` 是只读的、不属于本工具**，故它**没有**归属标记、没有 `flock`、`open_root` 时
      `create_leaf=False`、`open_under` 时 `create_dirs=False`——**维度①（归属证明）不适用，
      维度②（inode 钉死）与维度③（逐段无跟随）适用**。

  > **为什么第 4/4b 条挡不住这一档（R82-F1 修正）**：第 4 条绑的是**挂载/共享**，第 4b 条绑的是
  > **导出根相对于挂载点的那条路径**——**两条都只管「根」**。而 K 线 CSV 躺在根之下的
  > **源根之下**的 `1分钟K线_前复权/` 里：**只要把这个中间目录换成指向同一共享内
  > 某个陈旧备份目录的符号链接**，第 1/2/3/4/4b 条**全部照过**（挂载没变、导出根相对路径没变、
  > `export_log.csv` 就是那一份），而 `qmt_fetch` 与 `qmt_pilot` **读到的都是逃逸后的字节** ——
  > 于是 source / staging / manifest **三方哈希完全一致**，一路走到 `SUCCESS`。
  > **R23-F1 当初要堵的「同一共享下的陈旧兄弟目录」就此在授权根内部原样复活。**
  >
  > **根因是我的同类对象清单从头到尾写的是「两个目录」**（`--dest`/`--staging` ↔ `--output`），
  > **`--source` 从来没进过那份清单**——因为它「只读、不属于我们」，直觉上不像需要被保护的对象。
  > 可**信任边界不是按「谁拥有」划的，是按「哪些字节被当成证据」划的**：`--source` 提供的正是
  > 出货资格所依据的那批字节。清单据此改为**三个目录**，并注明每个对象适用哪几个维度。

  > **为什么挂载身份还不够（R23-F1 修正）**：第 4 闸绑住的是**共享（share）**，不是**共享里的哪个目录**。同一个 SMB 共享下完全可能并存多份导出——例如 fetch 当初用的 `…/front_ratio_cn_stocks_ab_bj/`，和某人留下的陈旧兄弟目录 `…/backup_2026_06/`。后者只要 `export_log.csv` 哈希碰巧对得上，`fstype`/`device` 检查**必然全过**（本来就是同一个共享），三方哈希也会自洽 → `ship_eligible: true`，而 pilot 读的**根本不是 fetch 当初那份导出**。
  >
  > **身份判据只能是「device/fstype + 共享内相对路径」，绝对路径不能进判据（R25-F2 修正）**：R23 原写「绝对路径与相对路径**都**须逐字相等」，可紧接着的理由却说「挂载点可能变，相对路径保证实质、绝对路径供留痕」——**规则与理由自相矛盾**。真遇到 macOS 把同一共享重挂到 `/Volumes/QMT_Export-1`（共享没换、目录没换、内容没换），绝对路径必然不同 → `FAIL_SOURCE_BOUNDARY` → **一次完全合法的 L3 出货被拒**。
  >
  > 「是不是同一份导出」这个性质，由 **device（`//server/share`）+ 共享内相对路径**唯一确定；挂载点只是本机这一次的偶然形态，**把偶然形态写进身份判据，就是在用环境噪声否决合法运行**。绝对路径仍然记录，但它的角色是**取证留痕**，不是**准入判据**。
  5. 任一不满足 → **`FAIL_SOURCE_BOUNDARY`（rc=1）+ `source_boundary_error`** 记明是哪一条闸不过（自查补，与 R21-F2 同原则）。

  > **边界闸失败不得降级成「没传 `--source`」**：操作者**确实传了** `--source`，是它**被判定不合格**。若按「未传」处置成 `SUCCESS_UNVERIFIED_SOURCE`，就是把「**你给的源不合格**」伪装成「**你没给源**」—— 与 R8-F2（两趟不一致不得降级为 `partial`）、R21-F2（三方校验失败要有独立 verdict）是**同一条原则在第三个执行点上的应用**。三处的判据统一为：**「查了、不合格」「没查」「查了、合格」必须是报告里三个可区分的结局。**

  > **为什么只读 + 不重叠 + 哈希仍然不够（R19-F2 修正）**：这三条只能证明「这是**某个**只读目录，里面那份 `export_log.csv` 与当初一致」。**一份 staging 的只读本地克隆完全满足全部三条**——把它传给 `--source`，pilot 照样两趟自比一致 → `ship_eligible: true`，而权威的 SMB 导出从未被读。
  >
  > 实测佐证：本机根卷 `/` 自己就是 `apfs … read-only` —— **「只读」在 macOS 上根本区分不出「网络共享」与「本地卷」**。唯一能绑住「这就是那台机器上的那个共享」的，是**挂载身份**（fstype=`smbfs` + `//server/share` 设备串）。本地克隆会显示 `apfs` + `/dev/diskXsY`，当场出局。
  >
  > 对应地，`qmt_fetch` 须在 manifest 里记下 `source_mount: {fstype, device, mountpoint, gmt_token?}`，供 pilot 侧比对。

  > **为什么「源」必须被这样约束（R18-F1 修正）**：P4-D6 明确要求 staging **保留源端目录结构**（好让 `import_csv` 的 `rglob` 直接复用）。这条设计的副作用是 —— **`--source=<staging>` 在结构上完全合法**：pilot 会去读它**正在验证的那批文件**，两趟当然一致，于是 `ship_eligible: true`，而 SMB 导出**从头到尾没被碰过**。R17-F2 的全部目的是「让做出货断言的进程自己去读源」，若不约束「源」这个词，它就能退化成「读自己的本地副本」，整条信任边界原地失效。
  >
  > 第 3 条尤其关键：只读 + 不重叠只能证明「这是别的某个只读目录」，**只有 `export_log.csv` 的哈希与 manifest 冻结的那份逐字相符，才证明它就是当初那份导出**。
- **没传 `--source`**（离线重跑）：报告的 `source_verification` 一律记 `partial`，**无论 manifest 里写的是什么** → `ship_eligible: false`；门槛为默认时 verdict 为 `SUCCESS_UNVERIFIED_SOURCE`、rc=2，**门槛非默认时先命中 `SUCCESS_NON_SHIPPING`、rc=3**（R37-F2，见优先级表）。

> **为什么出货资格不能建立在 manifest 上（R17-F2 修正）**：manifest 由 `qmt_fetch` 写、被 `qmt_pilot` 读。从 pilot 的角度看，**里面任何关于「我校验过源」的记载都是 fetch 的自述**；再怎么加字段、加存根、加交叉核对，都只能证明这份文件内部自洽，**证不了那两趟读真的发生过**。要打破这个自指，唯一的办法是**让做出货断言的那个进程自己去读源**。
>
> 这个取舍是划算的：出货那一次真跑，Windows 机器本来就开着、共享本来就挂着（fetch 刚跑完），多付一趟约 2 GiB 的读。而**离线重跑 pilot 仍然完全可用**（调参、看 skip 分布、断点续跑），只是它们**本来就不该充当出货证据**——现在这一点变成机器强制的，而不是靠人记得。
---

## 5. 错误处理（§4 的导出视图）

| 情形 | 处置 |
|---|---|
| 挂载点不存在 / 不可读 | `qmt_fetch` 立即拒绝，非零码，提示先 `mount_smbfs -o rdonly` |
| `--dest` 与 `--source` 相等或互为子树 | **拒绝启动**（R4-F4：否则会把锁/manifest/`.part`/CSV 写进权威导出共享，污染取证对象） |
| 某股 `pilot_stock_source` 记的源哈希与当前 manifest 不符 | 记 `source_generation_changed`，按 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 的**先证后毁**序列处置（R6-F1 + R7-F2 + R9-F2）：① `staging_intact` 先过，不过则原样返回、旧行旧 zip 不动 → ② owned zip **原子改名挪进 `.superseded/`**（不是删！同名重生成会截断它）→ ③「删行 + 完整重导入」包进同一外层事务，失败回滚并把 zip 挪回 → ④ 新产物登记成功才删掉挪走的那份，失败则保留并记 `preserved_superseded`。**必须完整重导入而非只重生成**——库内 klines 是旧代数据 |
| 上一次运行崩在某只股的两个文件之间（`.inflight.json` 存在且该股在 manifest 里不完整） | 恢复流程**删掉标记里明写的那两条 target 与两条 `.part`**，记 `inflight_rollbacks[universe_idx] += 1`（**基础设施遥测，不是候选失败**）后**原地重试同一槽位**：不记 failure、不加 `attempts`、`cursor` 不推进（R37-F1 + R66-F3）。**仅当同槽位回滚累计到 3 次**才转成 failure 并推进游标，避免确定性故障原地打转 |
| `.inflight.json` 存在但形状不合规（code 非法 / `universe_idx` 越界或与 code 对不上 / 路径逃出 staging / 文件名与记录不符） | **拒绝启动、一个文件都不删**，提示人工处理（R37-F1：一个能授权删除的标记，自己必须先被校验——同 R21-F3） |
| 收尾复校发现任一已拷文件源哈希变了（含两趟之间不一致） | **判失败、非零码退出，不得降级为 `partial`**（R8-F2：降级会把「发现了源在变」伪装成「没检查」）。首次 fetch 同样要跑收尾复校（R4-F2） |
| 传了 `--snapshot-gmt-token` 但与 `--source` 实际挂载信息不符 | **拒绝启动**（防手填假 token 骗到 `snapshot` 级）（R10-F3） |
| pilot 导入前 staged **K 线** CSV 的字节数/sha256 与 manifest 不符（**逐股**；全局 `export_log.csv` 走下方 `FAIL_STAGING_INTEGRITY`，R38-F1） | 记 `stage=staging, reason=staging_integrity_mismatch`，**不导入**该股，继续下一只（R4-F1） |
| `export_log.csv` 缺失/零字节/截断 | 沿用 `parse_export_log` 的 `QmtSchemaError`，干净拒绝非裸 traceback |
| 源文件缺失（export_log 有条目但文件不在） | 该股记 `fetch_missing_file` 跳过，继续；**若另一个文件的 `.part` 已写，一并删除**（R37-F1）；写进 manifest |
| 拷贝后 sha256 与源不符 | 删**该股的两个** `.part`（R37-F1），记 `fetch_copy_hash_mismatch`，继续下一只（R2-F3） |
| 补拉时源 `export_log.csv` 的 sha256 与 `source_snapshot` 不符 | **拒绝启动**，提示换新 staging + 新 seed 重新开始；不覆盖 staging 的 `export_log.csv`（R2-F2） |
| 补拉时任一**既有**已拷文件的源 sha256 与 manifest 不符 | **拒绝启动**（默认全量复校）；用 `--skip-existing-verify` 可跳过，但 `source_verification` 标 `partial` 并在报告里声明（R3-F3） |
| 拷贝失败（源缺失 / 哈希失配） | 推进 `cursor`（**不**推进 `pool_order`）、进 `failures` 台账；补拉时 `attempts < 2` 的先重试一次（R3-F2） |
| 收尾发现**危险形状**：某股 >1 条活跃行 / 有活跃行不属于本次 manifest 池 | **`FAIL_SET_CARDINALITY`（rc=1）+ `cardinality_errors`**，**无条件检查**；相对其他 verdict 的次序**以 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 优先级表为准**（R22-F2 + R28-F2） |
| pilot 三方相等校验失败（源/staging/manifest 任意两者不等，或两趟不一致） | **它跑在准入阶段的 ④b、即第一次状态改变之前（R54-F1）**：按收尾规则写 **`FAIL_SOURCE_VERIFICATION`（rc=1）+ `source_errors` 逐条**（R21-F2）。次序以 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 优先级表为准（R28-F2）——「查了、不合格」与「没查」必须能被报告区分，降级即是把前者伪装成后者 |
| manifest 的 fetch 侧 `source_verification` 是 `partial` | 本次运行**封顶 `partial`**，pilot 再怎么验也升不上去（R21-F1：两侧级别取小；fetch 与 pilot 证明的是不同时段的事，谁也替代不了谁） |
| manifest 实拷清单不合规（某股不是恰好 2 条 / 缺 1m 或 daily / 有重复或多余活跃记录 / `relative_path` 逃出 staging / 文件名解析出的 code·period 与记录不符 / `sha256` 格式非法） | **拒绝整个 manifest，且必须在任何 DB 写入之前**（R21-F3：这份清单是 `staging_intact`、`pilot_stock_source`、三方校验共同的真相基准） |
| `--source` 过不了边界闸（可写 / 与 staging 或 output 重叠 / `export_log.csv` 哈希与 manifest 不符 / **挂载身份与 `source_mount` 不符** / **不是当初那个导出根**，R23-F1） | **`FAIL_SOURCE_BOUNDARY`（rc=1）+ `source_boundary_error` 记明哪一条不过**（自查补）。**不得降级成「未传 `--source`」**——操作者确实传了，是它被判不合格；降级即把「你给的源不合格」伪装成「你没给源」（R18-F1 + R19-F2 定的是闸本身；本条定的是**失败该被报成什么**） |
| manifest 的 `source_verification` 与其**前置输入**不符（`snapshot` 缺 `gmt_token` / `full` 缺 `operator_attestation`） | **拒绝整个 manifest**，fail-closed（R15-F2：写侧记录 ≠ 读侧核实） |
| manifest 缺 `source_verification_evidence`，或存根的趟数/`passes_agree`/`files_verified`/聚合摘要与 manifest 自身记录对不上 | **拒绝整个 manifest**（R16-F1：输入只证明「操作者按了开关」，存根才证明「校验真的跑过且一致」；聚合摘要只能由真实逐文件哈希算出） |
| `--dest` 首次使用时路径已存在**且没有合法归属标记**（空的也算），或复用时缺 `.staging_owner.json` / manifest `seed` 不符 | **拒绝启动**（R7-F3 + R36-F2：与 `--output` 同规格——「判空 → 声明」的窗口关不死，`.staging.lock` 也证明不了这目录是 `qmt_fetch` 建的）。**例外：引导态**见下行 |
| `--dest` 有 `.staging_owner.json`（`seed` 相符）但**没有** `fetch_manifest.json`（崩在标记落盘与首份 manifest 之间） | **判为引导态，允许从头继续初始化**：锁内只清理已知引导产物（`export_log.csv` / `*.part` / `.inflight.json`）后照首次使用流程走（R60-F3）。**但若目录里有任何完整 K 线 CSV → 拒绝并要求人工**：按「首份 manifest 先于任何 K 线拷贝」的提交顺序那不可能出现，现场已超出本工具理解范围 |
| `--source` 在**挂载身份闸**前后被来回改指（先换成只读本地克隆让 `open_root` 钉住它，再换回真 SMB 路径让挂载表查到真身份，然后换回克隆） | **不可发生**：挂载点由 **`os.fstat(src_fd).st_dev`** 逐条比对挂载表定位（**不是**按 `--source` 字符串查），且 `source_root_relative` 须**反向验证** `open_root(mountpoint + "/" + rel)` 的 `(st_dev, st_ino)` 等于 `src_fd`（R91-F1）。按路径定位挂载点的实现会**哈希克隆的字节、却在报告里写 SMB 导出的身份**——一份彻头彻尾的假出货凭据 |
| `--source` 在源边界闸各条之间被改名/改指 | **第 0 步就已 `open_root` 钉住 `src_fd`，其后全部闸对着 fd 跑**（R84-F1），故改指不影响判定；另有 `(st_dev, st_ino)` 分叉检查会抓到并判 `FAIL_SOURCE_BOUNDARY` + `source_path_escape`。**闸的顺序在这里是安全性的一部分**：R82-F1 把 `open_root` 排在四条按路径做的检查**之后**，等于让真 SMB 源过闸、却钉住随后换上来的本地克隆 |
| staging 子目录（`1分钟K线_前复权/`、`日K线_前复权/`）的 `mkdir` 目录项在崩溃中丢失 | **不可发生**：每新建一级子目录都须 `fsync` 其父目录（R84-F2，已进耐久提交协议的闭合清单）。否则 manifest 已提交「文件在该目录下」而目录本身没落地 → 重启后**记录在、文件与目录都不在**，既不是 `untracked_target_file` 也回收不了，最终以假的 `staging_integrity_mismatch` 或假的池穷尽收场 |
| manifest 顶层带 `stopped_reason ∈ {source_path_escape, staging_path_escape}`（上一次 fetch 被信任边界破坏终止） | **pilot 在步骤 ② 内立即 fail-closed**（R93-F1）：`source_path_escape` → `FAIL_SOURCE_BOUNDARY`；`staging_path_escape` → `FAIL_STAGING_INTEGRITY`；rc=1，**在 ②b、任何 DB 动作与任何股的消费之前**。**读侧校验清单不含它的实现会照常消费此前拉到的那批股**——那份 manifest 形状上完全合法——把一次信任边界破坏报成「候选不够」甚至走到 `SUCCESS` |
| 操作者修好源树/staging 树后重跑 `qmt_fetch`，上一次的 `stopped_reason`/`fetch_fatal_error` 何时消失 | **只在「收尾提交」那一次原子提交里清除**（R95-F2）：启动时不清；本次干净跑完（或干净 `max_bytes` 触顶）→ 同一次提交内写入本次 `stopped_reason` 并删除 `fetch_fatal_error`；本次又撞 escape → 覆盖为本次的。**崩在收尾提交之前 → 旧记录仍在，pilot 继续 fail-closed（安全侧）**。**就地合并式更新会让陈旧 fatal 永远留着、pilot 永远拒绝启动；启动即清除则会在重试崩溃时抹掉唯一证据** |
| manifest 顶层 `stopped_reason` 不在闭合枚举内，或 `source_path_escape`/`staging_path_escape` 缺形状合规的顶层 `fetch_fatal_error` | **拒绝整个 manifest** → `FAIL_MANIFEST_INVALID`（R93-F1） |
| staging 内的**改名 / 删除 / 目录 `fsync`**（`os.replace`、回滚 `unlink`、子目录 `fsync`） | **一律经 `parent_fd_under(stg_fd, relpath)`** 拿到 `(parent_fd, leaf)` 再操作（O2-F4）。**`open_under` 只能 `open()`**，够不到这三类命名空间动作；实施者最自然的 `os.unlink(str(staging/rel))` 会让 `.inflight.json` 的形状校验（用 `resolve()`，**会跟随符号链接**）放行一条**破坏性恢复路径删到边界之外** |
| 源边界闸在**首次 `qmt_fetch`**（尚无 manifest 可比）时怎么跑 | **走「立基准模式」**（O2-F5 + P2-F5）：判定谓词 = 「**按下方权威启动序列走到「判模式」那一步时**，没有成功读入并通过校验的 manifest」（首次 + 引导态）。**谓词的求值时刻由序列定死**（O4-F7），且 `source_mount` 与 `source_snapshot` 同规格——**只在立基准那一次写入，比对模式下一律只读、任何情况下不得重写**。该模式下第 2 条的 `out_fd` 半边不适用（fetch 无 `--output`）、第 3/4/4b 条的「与 manifest 相符」换成「**据 `src_fd` 派生并记录**」，但**第 4 条的绝对要求部分仍强制**（`fstype == "smbfs"` + device 形状）。**补拉 fetch 同样没有 `--output`**，该半边一并不适用。**绝不是「读不到基准就重新立基准」**——`source_mount` 已进读侧必需键，比对模式下「基准缺失」结构上不可表达 |
| manifest 的 `manifest_version` 与本工具不等 | **不等即一个字节都不写**（O2-F8 + P2-F6）：小于 → 「该 staging 由旧版本产出，请换新 staging + 新 seed 重拉」；大于 → 「由更新版本产出，请用对应版本或换新 staging」；**缺失视为版本 0**，走旧版本指引。**这三档的错误与指引必须与「形状非法」可区分**——否则一棵已拉 400 只股的 staging 会变成工具自己解不开的状态 |
| `staging_path_escape` 修好后重跑，全量存在性 + sha256 复校不过 | **`stopped_reason: "staging_recheck_failed"`**、rc≠0、**保留 fatal**，且**本次不得推进 `cursor`、不得新增 `files`/`pool_order`**（P2-F3；否则每次重跑继续消耗冻结宇宙与 `--max-bytes` 预算却永远清不掉 fatal）。出路与 O2-F8 同规格：「该 staging 已被证明动过且无法自证完整，请换新 staging + 新 seed 重拉」 |
| staged `export_log.csv` 的字节怎么计入 `--max-bytes` | **它是唯一的非股级计账对象**（O2-F2），与 K 线 CSV 同规格逐块扣减 + 事前 `stat` 早拒。**它触顶发生在第一份 manifest 之前**，故不提交任何 manifest，只删 `.part` 并 rc≠0（目录停在引导态，下次按引导态清理重来）——触顶协议里「记 `stopped_reason` + 所在层/下标」两步**仅适用于股级对象** |
| `qmt_fetch` 在源树内撞 `source_path_escape` | **整次 fetch 致命，不是一只股的失败**（R87-F1）：删当前股两个 `.part`、**不记 failure / 不加 `attempts` / 不推进 `cursor`**、manifest 记 `stopped_reason: "source_path_escape"` + 顶层 `fetch_fatal_error{kind, relative_path, component, errno}`（**四字段，与 本文件 §4.5 读侧要求逐字相同**，R94-F2）后提交、rc≠0。**pilot 读到该 `stopped_reason` → 拒绝启动**，判 `FAIL_SOURCE_BOUNDARY` + `source_path_escape`、rc=1。**记成普通 fetch failure 的实现会让一次源树逃逸伪装成池缩水**，剩下的股照样凑够 100 只走到 `SUCCESS` |
| **`--source` 树内**任一路径分量（含从 `/` 到 `--source` 的根路径、以及根之下 `1分钟K线_前复权/` / `日K线_前复权/` 这些中间目录）是符号链接或非目录（**⚠️ 实测（macOS 25.4 / APFS）：目录分量为符号链接时得 `ENOTDIR`，不是 `ELOOP`；只有不带 `O_DIRECTORY` 的叶子文件 `O_NOFOLLOW` 才得 `ELOOP`。且 `ENOTDIR` 与「这里放了个普通文件」**不可区分**。两者一律按逃逸处置；若确需区分，须撞错后补一次 `os.lstat(component, dir_fd=parent)` 判 `S_ISLNK` 再落进 `fetch_fatal_error`（O4-F12）**）| **`FAIL_SOURCE_BOUNDARY`（rc=1）+ `source_boundary_error: "source_path_escape"`**（R82-F1）。**源边界闸第 1/2/3/4/4b 条只管根**——把根之下一个中间目录换成指向同一共享内陈旧备份的符号链接，那五条全部照过，而 fetch 与 pilot 读到的都是逃逸后的字节，**三方哈希因此完全一致、一路走到 `SUCCESS`**。**`qmt_fetch` 侧一律整次致命**（R87-F1 + R88-F2 更正：此处原写「拒绝启动/**记该股失败**」，与 R87-F1「不是候选失败」直接冲突；照它实现会让源树逃逸伪装成普通池缩水，后续股照拉、甚至走到 `SUCCESS`）——见上一行的 `stopped_reason` / 顶层 `fetch_fatal_error` / 不推进 cursor 三条 |
| `--output` / `--staging` / `--dest` 的**任一路径分量**（从 `/` 起）是符号链接或非目录（`open_root` 逐段撞 `ELOOP`/`ENOTDIR`） | **拒绝启动，一个字节都不写**，stderr 提示改传完全解析后的绝对路径（R75-F2：裸 `os.open(root, O_NOFOLLOW)` 只保护最后一段，被换掉的父分量会让 pin 钉在另一棵树上，此后所有 `*at` 纪律忠实地作用在错的目录上）。**本工具不替操作者 `realpath()`**——那正是「跟随」 |
| `<output>/.superseded` 是符号链接、或存在但不是真目录 | **拒绝**（`ensure_owned_dir` 先 `lstat`）——`os.replace` 会**穿过路径分量**解析，否则这条破坏性恢复路径会把 zip 挪出归属目录或覆盖外部同名文件（R13-F2） |
| 拷贝时目标文件已存在但 manifest 无其记录 | **拒绝覆盖**，记 `untracked_target_file` 跳过该股（R7-F3）。**前提是崩溃恢复已先跑过**（R37-F1）——上一次运行留下的半成品由在途标记回收，不到这条规则 |
| `source_generation_changed` 但新 staging 不完整 | 记 `staging_integrity_mismatch` 并返回，**旧行与旧 zip 原封不动**（R7-F2：先证明换得成，再销毁旧的）。**但该行会被收尾的源代次全库扫描抓到 → 本次运行判 `FAIL_STALE_GENERATION`**（R14-F1：保留不销毁 ≠ 可以报 SUCCESS） |
| 收尾扫描发现任一活跃 `training_sets` 行的源哈希与当前 manifest 不符（或该股不在 manifest 里） | `verdict = FAIL_STALE_GENERATION`、rc=1，报告列出 `stale_generation_rows`。**不删行**——留给操作者修好 staging 后重跑（R14-F1） |
| 拷贝中断 | `.part` 残留不会被误判为完整（原子 rename + 字节数 + sha256 三保险）；**一只股的两个文件按事务提交，半成品由 `.inflight.json` 回收后重试**（R37-F1）；重跑续传 |
| 触到 `--max-bytes` 硬上限（流式逐块扣减时越界，或事前 `stat` 早拒） | **终止条件，不是这只股的失败**（R44-F2 + R48-F3：越界的那一块**根本不写出去**，不是写完再核账）：删当前股的两个 `.part`、**不记 failure / 不加 `attempts` / 不推进 `cursor`**，manifest 记 `stopped_reason: "max_bytes"` 后提交，**立即停止、非零码退出**，绝不继续下一只（若按普通失败处理，一次触顶会把剩余整个宇宙记成假失败并把 cursor 冲到末尾，pilot 随后报出的池穷尽/地板不可达全是假的） |
| `--staging` 不是一棵合法 staging 树（缺 `.staging_owner.json` / `tool`·`dest`·`seed` 任一不符）；**或 `.staging.lock` 是符号链接 / 非普通文件**（`O_NOFOLLOW` 撞 `ELOOP` 或 `fstat` 类型不符，R72-F2）；或与 `--output`/`--source` 路径重叠；**或运行中途 `--staging` 被改名/改指**（`stg_fd` 与当前路径的 `(st_dev, st_ino)` 不符） | **拒绝启动，一个字节都不写**——**该闸排在取 `.staging.lock` 之前**（R65-F1：取锁要写文件，打错字的 `--staging` 会先在未经证明的目录里落下锁文件） |
| staging 内任一**中间路径分量**（如 `1分钟K线_前复权/`、`日K线_前复权/`）是符号链接或非目录（`open_under` 逐段 `O_DIRECTORY\|O_NOFOLLOW` 撞 `ELOOP`/`ENOTDIR`） | **整次致命，不分「某只股」还是「全局对象」**（R89 自查补更正——原写「记 `staging_path_escape` 跳过该股」，与 R87-F1 对 `source_path_escape` 定的判据直接冲突：**路径分量被换是树布局本身被动过，不是这只股拉不到**）：`qmt_fetch` → `stopped_reason: "staging_path_escape"` + 顶层 `fetch_fatal_error{kind, relative_path, component, errno}`（四字段，R94-F2）、不记 failure、不推进 cursor、rc≠0；`qmt_pilot` → **`FAIL_STAGING_INTEGRITY`（rc=1）+ `staging_error{kind: "staging_path_escape", relative_path, component, errno}`**（判别式形状，R90-F1），在任何 DB 动作与任何导入之前。**`2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 的 verdict 唯一权威表已补入这一支**——它此前只定义了 `hash_mismatch` 那一支，照它实现的人没有分支可走，只能退回逐股 skip（R90-F1）（R74-F2：`dir_fd=stg_fd` 只钉住起点、`O_NOFOLLOW` 只管末段，中间分量被换掉时 fetch 会写到 staging 树外、pilot 又会从树外读，而 `staging_intact` 哈希对此完全透明） |
| `<dest>/.staging.lock` **被另一进程真正持有**（`flock` 取不到） | **两个工具都拒绝启动**，非零码（R1-F4 + R32-F2）。**锁文件残留不算被持有**——锁由内核持有、进程死亡即释放，**不需要也不应提示人工删锁**（R48-F2：存在性锁会把「执行阶段中途崩溃」锁死成永久状态，每次重跑都卡在 ①b）。**pilot 侧取锁排在任何输出目录写入之前（R39-F1）→ 拿不到锁时什么都没被改动：一个字节都不写**（此时尚未证明 staging 是我的，也未取得输出锁） |
| staged `<staging>/export_log.csv` 的字节数或 sha256 与 manifest `staged_export_log` 不符 | **`FAIL_STAGING_INTEGRITY`（rc=1）+ `staging_error`**，在任何 DB 动作与任何股的导入之前（R38-F1：它是所有股共用的元数据基准，漂了就没有一只股的判定还可信——**不能像逐股 `staging_integrity_mismatch` 那样只 skip 一只**） |
| manifest 形状校验不过（截断/缺键/层内重复/坏 code） | `qmt_fetch` 与 `qmt_pilot` 双方均 fail-closed 拒绝，**不做尽力而为解析**（R1-F4） |
| 补拉时 `--seed` 与 manifest 已记 seed 不同 | 拒绝（顺序不可拼接，混用会静默毁掉可复现性） |
| 断点续跑遇 `file_path` **字面不在 canonical `--output` 下**（含符号链接别名，R61-F2）、或其父目录 inode 与钉住的 `out_fd` 不同、或文件名不匹配 `{code}_{digits}.zip` | **绝不 unlink**；只删 DB 行、记 `foreign_output_path`、重生成到本次 output。即便该文件验证通过也**不计入成功**（R2-F1） |
| 池穷尽未达标 | rc=1 + 完整诊断报告 + 提示提高 `--quota` 再跑一次 `qmt_fetch` 补拉 |


---

## 6. 测试策略

**L1** host pytest（CI 强制）+ **L2** `tmp_path` 伪源端到端。**本 PR 不依赖真 SMB 源**——
4a/4b 的自动化验证均不依赖源机（源机不可控是已知风险）。真源只在 4c 之后的 L3 人工验收里出现。

回归钉逐条见旧 spec §6.1 的 4b 格（已随本节迁移，实施时按 §5/§9 的每一条造反例）。
**耐久提交的威胁模型是断电，且顺序屏障必须真用 `F_FULLFSYNC`（O4-F11 回归钉）**：
打桩记录 manifest 提交与 O2-F1 顺序屏障两处**实际调用的系统调用**，断言是 `fcntl(fd, F_FULLFSYNC)` 而**不是** `os.fsync`
（macOS `man 2 fsync` 明写它不保证断电耐久也不保证写序 —— 用 `fsync` 写出来的那条「目录项丢失注入测试」**绿灯证明不了任何东西**）；
其余落地点断言仍是 `os.fsync`（全都改成 `F_FULLFSYNC` 会让 400 股量级付出不必要的代价）。
**符号链接分量的 errno 断言必须是 `ENOTDIR`（O4-F12 回归钉）**：造「中间目录分量被换成指向真实目录的符号链接」→
断言 `fetch_fatal_error.errno == ENOTDIR`（**不是 `ELOOP`**，本机实测）；另造「叶子文件符号链接 + 不带 `O_DIRECTORY`」→ 断言 `ELOOP`。
**两者一律按逃逸处置**，但错误消息不得声称「这是符号链接」（`ENOTDIR` 与「放了个普通文件」不可区分）。

**全部新增测试必须 mutation 验证**：中和被测守卫 → 该测必须变红 → 复原。由控制者亲验，不接受 subagent 自证。

---

## 7. 交付诚实口径

- **CI 绿 ≠ 真数据已流过。** 4b 合并时的正确表述是「拉取层建好、用 `tmp_path` 伪源验过」。
- **禁述**：「pilot 已完成」「100 股已出货」「真实数据接入完成」。
- 若 `source_verification == "full"`（非 `snapshot`），交付说明须**原样带上** `source_verification_caveat`：
  两趟复校一致证明的是「源在验证窗口内未变」，**不等于证明源不可变**。

## 8. 已知风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| 源机不可控 | 445 探测不通，需控制者开机 | 计划内显式前置步骤；4a/4b 的自动化验证均不依赖源机 |
| 磁盘 30 GiB 余量 | staging ≈2 GiB + PG ≈1.5 GiB + zip ≈50 MiB ≈ 3.6 GiB | `--max-bytes` 默认 3 GiB fail-closed；不做全量镜像 |
| 预筛可能过严/过松 | 三条判据来自对 2 只深市老股的实证 | 预筛只剔「数学上必然被拒」，保守下界；报告记录各 reason 计数以便证伪 |
| SMB 的 `st_size` 不可全信 | 事前 `stat` 早拒只是尽力而为 | 真正的护栏是**流式逐块扣减**（越界的那一块根本不写出去） |

---

## 9. 验收标准（P/F）

| # | 判据 |
|---|---|
| 1l | **源级别取小 + 失败有独立 verdict（R21-F1 + R21-F2）**：最终 `source_verification` = **min(fetch 侧级别, pilot 侧级别)**；fetch 侧 `partial` 则本次封顶 `partial`（不可被 pilot 洗白）；pilot 侧 `full`/`snapshot` 各需其自身的 `--confirm-no-export-window` / `--snapshot-gmt-token`。三方相等失败 → **`FAIL_SOURCE_VERIFICATION` + `source_errors`**，且**优先于 `SUCCESS_UNVERIFIED_SOURCE` 判定**（「查了不合格」≠「没查」，降级即伪装） |
| 1m | **实拷清单进读侧校验（R21-F3）**：`pool_order` 每股恰好 2 条（1m + daily）、无缺无重无多余、`relative_path` 不逃出 staging、文件名解析出的 code/period 与记录一致、`sha256` 格式合法；任一不符即拒绝整个 manifest，**且在任何 DB 写入之前**。它是 `staging_intact`/`pilot_stock_source`/三方校验共同的真相基准，此前却唯独漏在校验枚举之外 |
| 1j | **「源」必须真的是源（R18-F1 + R19-F2 + R23-F1 + R82-F1）**：`--source` 须过**七条**边界闸——①只读（`statvfs ST_RDONLY`）②`resolve()` 后与 `--staging`/`--output` **不相等、不互为子树** ③`<source>/export_log.csv` 的 sha256 **等于 manifest 冻结的 `source_snapshot.export_log_sha256`** ④**挂载身份与 manifest 的 `source_mount` 逐项相符**（`fstype == "smbfs"` + `device` 即 `//server/share`；`snapshot` 级另比 `gmt_token`）**④b 就是当初那个导出根（R91-F1 + R93-F2 合并为一条）**——(i) `source_root_relative` 只在第 0 步钉住那一刻算一次 (ii) 与 `source_mount.source_root_relative` 逐字相等 (iii) **反向验证** `open_root(mountpoint + "/" + rel)` 的 `(st_dev, st_ino)` **等于** `os.fstat(src_fd)`；**挂载点本身由 `os.fstat(src_fd).st_dev` 比对挂载表定位，绝不按 `--source` 字符串查**（R91-F1）。**(iii) 与 fd 派生的挂载点定位都是强制项，不是历史注记**——只做到 (ii) 的实现挡不住 R91-F1 的克隆调包；**绝对路径不参与判定**，仅作现场记录写进报告（R25-F2：把偶然的挂载点形态写进身份判据，会让同一共享重挂到 `/Volumes/QMT_Export-1` 时否决掉一次完全合法的出货）。④ 绑的是**共享**，绑不住共享内的哪个目录；同一共享下的陈旧兄弟目录只要 `export_log` 哈希碰巧相符就能全过 ①②③④ ⑤**源树内部逐段无跟随**（`open_root(--source)` + `open_under(src_fd, …)`，R82-F1：前四条只管**根**，根之下一个中间目录被换成指向同一共享内陈旧备份的符号链接就能让三方哈希全部一致）⑥任一不满足即判 **`FAIL_SOURCE_BOUNDARY`（rc=1）+ `source_boundary_error`**，**不得降级成「未传 `--source`」**（那是把「你给的源不合格」伪装成「你没给源」）。**`--source == --staging` 与「staging 的只读本地克隆」都必须不够格出货**——前者因 P4-D6 保留源目录结构而结构合法，后者能过①②③三条（实测：本机根卷 `/` 自己就是 `apfs … read-only`，「只读」在 macOS 上区分不出网络共享与本地卷） |
| 1t | **staged `export_log.csv` 与 K 线 CSV 同等纪律（R38-F1）**：fetch 侧原子落地 + 进 manifest `staged_export_log`（`bytes`+`sha256`，且 `sha256 == source_snapshot.export_log_sha256`）；pilot 侧在 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 步骤 **②b** 复校，不符即 **`FAIL_STAGING_INTEGRITY` + `staging_error`**，且发生在任何 DB 动作与任何导入之前；传了 `--source` 时它也进三方相等的文件集合 |
| 2o | **首次使用的认领协议（R64-F1 + R66-F2 + R91-F2）**：`--dest` 与 `--output` **创建方式同规格**——`mkdirat` **独占创建**（唯一可移植的目录级排他原语）→ 写标记 → `fsync`；**撞 `EEXIST` 且无合法标记（空的也算）→ 两者都拒绝启动**，提示人工 `rmdir`。**有合法标记时两者结局不同（R91-F2）**：`--dest` → 退回**复用路径的完整准入序列**（归属标记三项 + manifest `seed` + `.staging.lock`，**绝不就地继续首次使用流程**）；`--output` → **一律拒绝、一个字节都不写**（首次使用支从未跑过 ①a / ①a′ / ①e，就地转复用会让一次诊断性运行覆盖掉对方刚写出的 `SUCCESS`）。**绝不自动认领任何无标记目录**——`mkdir` 之后的目录不携带出处信息，「我崩在半路留下的空目录」与「操作者预建的空目录」在磁盘上完全一样；意图记录（R65-F2 曾试）只能证明「我打算建」，不能证明「我建成了」。**造不出证据时，拒绝并交给人，好过静默吞掉别人的目录**。**绝不能用 `os.rename` 做「不覆盖发布」**：POSIX 的 `rename` 在目标是空目录时**会替换**它，预先建好或并发抢建的空目录会被**静默删除并认领** |
| 2d | **出货级源校验必须在第一次状态改变之前跑（R54-F1）**：它是**纯只读**的三方哈希比对，却曾排在消费循环之后——「`export_log` 逐字节不变而 SMB 上 K 线已漂移」这一档要**跑完 100 只股的导入与生成之后**才被发现。前移到 ④b 后**在动第一根手指之前**就失败。至此「凡只读检查一律排在第一次状态改变之前」（R48-F1）的执行点集合闭合：② ②b ③ ④ ④b ⑤ ⑤b |
| 2b | **每股一个独立可复现 RNG（R50-F3）**：`generate_one_training_set` 的 `rng` 必须是 `random.Random(f"{seed}:{code}")` **按股派生**，**绝不共用一个可变 rng**——走 `already_done` 的股不消耗 rng，共用会让「中断后续跑」与「一口气跑完」在同 seed 同源下选出**不同起点**，产出不同 zip，推翻本 spec 全部可复现性设计。须有「中断续跑 vs 一口气跑完，逐股 `start_datetime` 与 `content_hash` 全等」的回归钉 |
| 5n | **staging 锁必须由内核持有（R48-F2）**：用 `flock(LOCK_EX\|LOCK_NB)`，**进程死亡即释放**；**锁文件残留不构成拒绝**，也不得提示人工删锁。存在性锁（`O_CREAT\|O_EXCL`）会与「执行阶段中途崩溃」叠成**死锁**：每次重跑都卡在 ①b，只能人工删锁。须有「执行阶段 SIGKILL → 原样重跑自愈」的回归钉 |
| 5o | **`--max-bytes` 是流式硬上限（R48-F3）**：逐块扣减剩余预算，**越界的那一块根本不写出去**；另有事前 `stat` 早拒（尽力而为，SMB 的 `st_size` 不可全信）。「拷完再核账」不是护栏——一个损坏或异常巨大的源 CSV 能在被发现前把本机仅约 30 GiB 的可用空间写满，连带打断 DB 写入与报告落盘 |
| 3l | **pilot 的每一处 `import_qmt_stock` 都必须传 `staging_dir_fd=stg_fd`（R89-F2）**：`2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.1 的契约写了「pilot 传钉住的 fd」，而 `try_one` 伪代码里有**两处**仍是裸 `import_qmt_stock(conn, ...)`。**被调方缺省会按 `staging_dir` 字符串重新打开**，于是 `staging_intact` / manifest / 源校验之后的一次路径改指，就能把**未经校验的字节**灌进库，而报告仍按旧 manifest 推理。**契约写在一处、调用点漏在别处 = 契约不存在**（与 R74-F2 自查补同族：守卫必须落在真正 `open()` 的那一层，**并且每个调用点都要真的把它传下去**）|
| 3r | **持久化对象的写侧形状与读侧要求必须逐字相同（R94-F2）**：fetch 写 `fetch_fatal_error{kind, relative_path, component}` 三字段，而 本文件 §4.5 读侧要求四字段（含 `errno`）→ **一个合规的写者产出的 manifest 会被读者判成 `FAIL_MANIFEST_INVALID`**，于是一次信任边界破坏被报成「manifest 畸形」，恢复指引整个走错。统一为 `{kind, relative_path, component, errno}`，两个 `stopped_reason` escape 值同规格。**这正是 R93-F1 刚立的第五问（写侧/读侧配对）没有对 `fetch_fatal_error` 自己跑一遍** |
| 3h | **`source_errors` 的判别字段必须真的存在（R86-F2）**：R85-F2 我把 `source_errors[].error` 写进了「字段名约定」契约，**schema 里却只有 `relative_path`/`expected_manifest`/`actual_source`/`actual_staging`**。照 JSON 形状实现的人会漏掉这个字段，而照约定写的消费者/测试会拒掉合法报告或**丢掉源校验失败的机器可读原因**。补 `error` 及其枚举，且**三档必须可区分**：`source_staging_mismatch`（源被改了）/ `manifest_mismatch`（源与 staging **一起换代了**，R20-F1 引入三方相等正为抓它）/ `passes_disagree`（源正在变）；另加 `source_path_escape` / `unreadable` |
| 2t | **信任边界的起点本身也要逐段无跟随（R75-F2）**：`--dest` / `--staging` / `--output` 的 pin **必须走 `open_root()`**——从 `/` 起**每一个分量** `O_DIRECTORY\|O_NOFOLLOW`，首次使用的叶子用 `mkdirat`。裸 `os.open(root, O_NOFOLLOW)` **只保护最后一段**，被换掉的父分量会让 pin 钉在**另一棵树**上，此后 `flock`、`*at` 写入、inode 分叉检查全部忠实地作用于错的目录，而工具坚信边界已闭合。**不得 `realpath()`**（那正是「跟随」）；含符号链接分量 → 拒绝启动并提示改传解析后的路径。**这是 R74-F2 的另一半**：那条管「根之下的相对路径」，本条管「根本身」 |
| 3i | **`source_path_escape` 在 fetch 侧必须有唯一的、非候选级的表达（R87-F1）**：fetch 的 failure `reason` **全集是声明为闭合的**，里面没有它 → 实施者只能三选一：让自己的 manifest 校验失败、**把信任边界破坏降级成普通 fetch 失败**、或干脆不记。中间那条最危险——**一次源树逃逸伪装成池缩水**，剩下的股照样凑够 100 只走到 `SUCCESS`。定为**整次 fetch 致命**（与 `--max-bytes` 触顶同族，R44-F2）：不记 failure、不推进 cursor、manifest 记 `stopped_reason` + 顶层 `fetch_fatal_error`、rc≠0；**pilot 读到该 `stopped_reason` 连带 fail-closed**。判据第三次应用：**「我这次没做完 / 环境不对」不能记成「这个候选不行」** |
| 3s | **fail-closed 的信号必须有明确的解除时机，且解除要与「证明已干净」同处一次原子提交（R95-F2）**：`stopped_reason` 的两个 escape 值让 pilot 无条件 fail-closed，**而 spec 从没写过它何时被清掉**。两种朴素做法都错——**就地合并式更新**：操作者修好树、重跑成功，陈旧 fatal 仍在，**pilot 永远拒绝启动**；**启动即清除**：重试崩在中途便**抹掉唯一的持久证据**，下一次看到的是一份看起来干净、实则来自被污染源树的 staging。规则：启动不清；**只在「收尾提交」（干净跑完 / 干净 `max_bytes` 触顶）那一次原子提交里**写入本次值并删除 `fetch_fatal_error`；崩在此前则旧记录保留（安全侧）。**per-stock 提交一律不动这两个字段**，使规则可机械检验 |
| 3o | **一个信号只有同时进了「写侧规定」与「读侧校验」才真的存在（R93-F1）**：`stopped_reason` 是 fetch 侧的致命信号（R87-F1 / R89 自查补），§5 也写了「pilot 读到即 fail-closed」——**可 本文件 §4.5 那份读侧校验清单从头到尾没提过它**。而被逃逸终止的 fetch，其 manifest **仍带着此前成功拉到的 `pool_order` / `files`，形状完全合法** → 照清单实现的 pilot 会照常消费那批股，把信任边界破坏报成「候选不够」甚至 `SUCCESS`。补：读侧把 `stopped_reason` 列为**可选但闭合枚举**（`max_bytes` / `source_path_escape` / `staging_path_escape`），后两值须带形状合规的顶层 `fetch_fatal_error`；**`2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 步骤 ② 内立即分支**（escape 两值 fail-closed，`max_bytes` 放行）|
| 3m | **「fd 派生」必须逐条落实，不能只写一句总纲（R91-F1）**：挂载身份闸仍写着「定位包含 `--source` 的挂载点」——而 `--source` 无锁无标记。可构造「钉住克隆 → 换回真 SMB 让挂载表查到真身份 → 换回克隆」的三段时序，**四条闸全过，哈希的却是克隆的字节，报告里写的是 SMB 导出的身份**。改为：挂载点按 `os.fstat(src_fd).st_dev` 比对挂载表定位；`source_root_relative` 须**反向验证** `open_root(mountpoint + "/" + rel)` 的 `(st_dev, st_ino)` 等于 `src_fd`。**R84-F1 写下「其后全部对着 fd 跑」并不构成每一条子判据都真的对着 fd 跑** |
| 1s8 | **`--source` 必须先钉后校，顺序即安全性（R84-F1）**：`src_fd = open_root(--source)` 是源边界闸的**第 0 步**，其后只读（`os.fstatvfs(src_fd)`）、重叠（另比 `(st_dev, st_ino)`）、`export_log` 哈希（经 `open_under`）、挂载身份、逐段无跟随**全部对着 fd 跑**。**`--source` 没有归属标记也没有锁**，把 `open_root` 排在按路径做的检查之后（R82-F1 原版），就等于让真 SMB 源过闸、却钉住随后换上来的只读本地克隆——而分叉检查比对的是「已被换过的路径」与「刚打开的 fd」，**两者当然一致**。**这是 R71-F3 在 staging 上立的「先钉住再校验」，我在 source 上写成了反方向；一条「先 X 后 Y」的纪律，方向反了就等于没有** |
| 5p | **staging 子目录创建也是命名空间改动（R84-F2）**：`open_under(create_dirs=True)` 建的每一级子目录**都进耐久提交协议的闭合清单**——每新建一级即 `fsync` 其父目录。漏掉的后果与 R45-F2 同构、只是高一层：manifest 已提交「文件在该目录下」而**目录项没落地** → 重启后记录在、文件与目录都不在，既不是 `untracked_target_file`（那要求文件存在）也回收不了（在途标记早删了），最终以**假的 `staging_integrity_mismatch` 或假的池穷尽**收场 |
| 5q | **备查副本要么全套治理、要么删掉（R84-F3）**：`stock_universe_with_name.csv` 原写「存在则原样拷进 staging 备查，但不参与任何逻辑」——**它从未成为 manifest 一等记录**，于是同时逃过 `--max-bytes` 计账、`.part` 原子落地、sha256 复校、幂等四象限、目录 `fsync`；一个体积异常或拷到一半被换掉的源文件**能在不出现在任何记录里的情况下把磁盘写满或覆盖无主文件**。**本 spec 唯一一条「删掉而不是加固」的处置**：它的收益（备查）与代价（五套机制 + 一条新失败面）完全不成比例 |
| 1s7 | **源侧同样逐段无跟随（R82-F1）**：`--source` 是**第三个目录**，`qmt_fetch` 的拷贝读与 `qmt_pilot` 的三方校验读都必须经 `open_root(--source)` + `open_under(src_fd, relative_path, create_dirs=False)`。源边界闸第 1/2/3/4/4b 条**只管根**（挂载、导出根相对路径、`export_log.csv` 哈希）——**把根之下的一个中间目录换成指向同一共享内陈旧备份的符号链接，这五条全部照过，而 fetch 与 pilot 读到的都是逃逸后的字节，三方哈希因此完全一致，一路走到 `SUCCESS`**。判据见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 源边界闸第 4c 条 |
| 1s9 | **`staging_path_escape` 与 `source_path_escape` 同判据：整次致命、且必须进枚举（R89 自查补）**：路径分量被换成符号链接是**树布局本身被动过**，不是「这只股拉不到」——同目录下所有股都受影响。`qmt_fetch` → `stopped_reason: "staging_path_escape"`（全集三项）+ 顶层 `fetch_fatal_error`、不记 failure、不推进 cursor；`qmt_pilot` → 整轮 `FAIL_STAGING_INTEGRITY` + **判别式 `staging_error`**（`kind` ∈ `hash_mismatch` / `staging_path_escape`；后者另带 `component` 与 `errno`，R90-F1）。**`2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.3 的 verdict 唯一权威表与 verdict 定义都必须列出这一支**——只写 `hash_mismatch` 的表会让实施者无分支可走、退回逐股 skip，于是一棵被污染的 staging 表现为普通池缩水甚至走到 `SUCCESS`。**本条由 R89 立的机械检查自己抓出**：「新错误码逐个 grep 它进了哪个枚举」——`staging_path_escape` 出现 4 次却不属于任何枚举，且还留着 R87-F1 刚判定为错的「跳过该股」措辞 |
| 1s5 | **staging 侧必须逐段无跟随打开（R74-F2）**：`dir_fd=stg_fd` 只钉住**起点**、`O_NOFOLLOW` 只管**最后一段**——而 staging 保留源的分层结构，每次读写都要穿过中间目录。须定义 `open_under(stg_fd, relpath)`：**逐个分量** `O_RDONLY\|O_DIRECTORY\|O_NOFOLLOW` 走下去（`create_dirs` 时只创建本工具自己的目录），拒绝任何符号链接/非目录分量与 `.`/`..`；**`qmt_fetch` 的每一次写与 `qmt_pilot` 的每一次读都走它**。否则一棵被复用的 staging 里，`1分钟K线_前复权` 被换成外指链接就能让 fetch 写到树外、pilot 从树外读，而 `staging_intact` 的哈希**对此完全透明**（它读的是同一条被换过的路径）。这是输出侧 `ensure_owned_dir` 逐段校验的**同一条纪律**，此前只落在 `--output` 上 |
| 1s6 | **no-follow 的执行点必须是真正 `open()` 的那个函数（R74-F2 自查补）**：`import_qmt_stock` 新增 **`staging_dir_fd: Optional[int] = None`**，契约与 `output_dir_fd`（§9-2k）**逐字同构**——给了就用、没给自开自持，`_amain_qmt_import` 一行不改；函数内部把 `rglob` 换成 `os.scandir(dir_fd=)` 逐层下钻。**守卫立在调用方而 `open()` 发生在被调方 = 守卫不存在**，这是 R19-F3（`assemble_from_windows`）的原样复发 |
| 1s4 | **两个工具的 staging 访问纪律必须一致（R73-F1）**：`qmt_fetch` 与 `qmt_pilot` **同样**要 `O_DIRECTORY\|O_NOFOLLOW` 钉住 staging、`openat(..., O_CREAT\|O_RDWR\|O_NOFOLLOW)` + `fstat` 取锁、其后一切 staging 读写走 `openat`。**纪律必须写进每个工具各自的权威节**（fetch 在 本文件 §4.4/本文件 §4.5、pilot 在 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2），不能指望实施者去读另一个工具的章节 |
| 1s3 | **锁文件也要过符号链接纪律（R72-F2）**：`.staging.lock` 必须 `openat(..., O_CREAT\|O_RDWR\|O_NOFOLLOW, 0o600)` + `fstat` 确认普通文件；`ELOOP` 或类型不符即拒绝启动。**凡是本工具会写入的路径，无论承载的是数据还是协调状态，都要过同一套符号链接纪律**——锁文件在直觉里像「临时协调物」，恰恰因此被漏掉 |
| 1s2 | **staging 必须像 output 一样被 inode 钉死（R71-F3）**：①b 第一步 `O_DIRECTORY\|O_NOFOLLOW` 取 `stg_fd` 并全程持有；`.staging_owner.json`、`.staging.lock`、manifest、`export_log.csv`、每股 K 线 CSV、`.inflight.json`、`staging_intact` 复校**一律 `openat` 相对 `stg_fd`**，绝不再由 `--staging` 字符串解析。否则「锁保护的是一个目录、读到的字节来自另一个目录」——最坏一档在 `staging_intact` 与 `import_qmt_stock` 之间，入库字节可与 manifest 及 ④b 源校验**全部对不上**，而所有哈希基线都以为自己验的是同一批数据 |
| 1o | **准入阶段零副作用，但作用域限于「归属未证明的对象」（R27-F2 + R29-F1）**：manifest 形状校验、`--source` 边界、④b 源校验、集群闸、⑤b 库级闸**全部排在任何 DB 生命周期动作之前**；任一不过须断言**目标库未被创建/未被 reset**。`CREATE DATABASE` 也算持久副作用。**已归属的 `--output` 不在零副作用范围内**——往里**新增**一份报告是创造证据（R69「只增不毁」），收尾规则见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md` §4.2 |
| 1f | **目标目录归属（R7-F3 + R8-F1 + R36-F2 + R91-F2）**：**创建方式同规格、`EEXIST` 结局不同**——首次使用由 `mkdirat` **独占创建**并写归属标记 `<dest>/.staging_owner.json`；撞 `EEXIST` 且**无合法标记**（空的也算）→ 两者都拒绝并提示人工 `rmdir`（R66-F2）；**有合法标记时**：`--dest` → 退回**复用路径的完整准入序列**（绝不就地继续首次使用流程），`--output` → **一律拒绝**（R91-F2）。`--dest` 复用须标记 + `seed` 相符的合法 manifest，**预先建好的空目录一律拒绝**；**引导态（标记在、manifest 不在、seed 相符）须可从头继续初始化**，否则崩在这两步之间就得人工清理（R60-F3）；`--output` 须**路径尚不存在**（`mkdirat` 独占创建后写标记；**撞 `EEXIST` 一律拒绝，无论有无标记**，R91-F2）或在 ① 那一刻已存在且**两层标记全相符**（第 1 层 `tool`+`output_dir` 免 manifest 先验；第 2 层 `seed`+`export_log_sha256` 待 manifest 校验后再验，R31-F1），**仅凭「里面的文件长得像我的产物」不算归属**（那正是全仓训练组共用的命名空间，而 `ZipFile(...,"w")` 会截断同名文件）；标记/报告/zip 目标是符号链接 → 拒绝写入；拷贝遇 manifest 无记录的既存目标文件 → 拒绝覆盖并记 `untracked_target_file`（均须断言相关文件事后逐字节未变） |
| 1d | **逐股源身份（R6-F1）**：`pilot_stock_source(stock_code, sha_1m, sha_daily)` 在导入成功时与登记同步写入；`already_done` **计入成功之前**须与当前 manifest 的该股哈希相等，不等则记 `source_generation_changed` 并走**完整重导入**。覆盖「`export_log.csv` 逐字节不变而 K 线内容已换」这一档——库级绑定挡不住它，而 crc32 产物校验也挡不住（旧 zip 本身完好） |
| 3 | 预筛三条边界值精确（`k_daily==39` 放行 / `==38` 剔；`k_1m==8` 放行 / `==7` 剔），且**只剔数学上必拒的** |
| 4 | 分层 seeded 储备池同 seed 可复现；改一层配额不扰动其他层顺序；**补拉按层各自从 `cursor[market]` 续，各层游标不等时零重复零遗漏**（R1-F1 撤销全局 `--skip-first`；R3-F2 明确游标≠`len(pool_order)`。实现中不得再出现全局偏移量，也不得拿成功计数当游标） |
| 5 | 拷贝幂等判据 = **字节数 + sha256**（R2-F3；同尺寸不同内容必须重拷、不得跳过）+ 拷后 src/dst 哈希比对 + 原子落地（`.part` → rename）+ 累计字节超 `--max-bytes` fail-closed（**触顶的确切语义见 5l——它是终止条件、不是候选失败**） |
| 5l | **配额触顶是终止条件（R44-F2）**：`--max-bytes` 触顶时删当前股的两个 `.part`、**不记 failure、不推进 `cursor`**、manifest 记 `stopped_reason` 后立即停止并非零码退出；提高上限重跑须从**原位**续。绝不把容量停止记成候选失败——那会用磁盘配额污染「市场上还有没有合格股」这个结论 |
| 5k | **按股事务（R37-F1）**：一只股的两个 CSV **要么都提交、要么都不留 final**；提交点 = manifest 原子落盘，**manifest 每股提交一次**；崩在两次 `os.replace` 之间时，`<staging>/.inflight.json` 使下次运行能**只删标记里明写的那四条路径**并重试该股，而不是把它判成 `untracked_target_file` 永久除名；标记自身形状不合规则**拒绝启动、一个文件都不删** |
| 5b | manifest 抗崩溃/抗并发（R1-F4 + R32-F2）：**staging 生命周期锁 `.staging.lock`（fetch 与 pilot 共用；pilot 须**持到报告落盘之后**，R39-F1）** + tmp→`fsync`→`os.replace` 原子写 + 读侧形状校验 fail-closed（截断的 manifest **不得**被尽力而为地解析成「候选就这么多」） |
| 5c | 源快照绑定（R2-F2）：manifest 冻结 `export_log_sha256` + 完整分层 `universe`；补拉的偏移量落在**冻结的** universe 上；源 `export_log.csv` 变了即拒绝启动且不覆盖 staging 副本（禁止两个 QMT 快照混进同一份报告） |
| 5d | 游标独立于成功列表（R3-F2）：`cursor[market]` 对**每个尝试过的槽位**推进，`pool_order` 只收成功项；拷贝失败进 `failures` 且有界重试（`attempts<2` 补拉时重试一次）。**「U5 失败 / U6–U121 成功」场景下不得重拷 U121、不得永久丢失 U5** |
| 5i | **manifest 校验与 `pool_order` 新 schema 同步（R13-F1）**：读侧必须要求元素为 `{code, universe_idx}` 对象并交叉核对 `source_snapshot.universe[market][idx] == code`、后缀与层一致、`idx` 在界内、层内二者各自唯一；**裸字符串元素的旧式 manifest 必须被拒**（否则锚点丢失，R12-F1 的口子重开） |
| 5f | 收尾复校覆盖**每一次** fetch（R4-F2）：给 `source_verification` **定级之前**必须对 `export_log.csv` + 全部已成功拷贝文件跑全集复校，**首次 fetch 不例外**（否则「拷到一半源被重导出」会让整批混代次而标签仍写得很好看）。任何级别的标签都必须由真正覆盖全集的校验支撑 |
| 5g | 源不可写 + 路径不重叠（R4-F4 + R5-F3）：挂载命令文档为 `mount_smbfs -o rdonly`；`qmt_fetch` 对 `--dest` 与 `--source` 相等/互为子树、以及 `statvfs` 判出源非只读，均**拒绝启动**；只读检测**必须非写入式**（`os.statvfs().f_flag & os.ST_RDONLY`），**禁止用试写临时文件的方式探测**——那会在恰恰要防的场景里由本工具亲手污染权威导出共享 |
| 8e | **换代恢复先证后毁（R7-F2 + R9-F2）**：`source_generation_changed` 分支必须先过 `staging_intact` → **旧 zip 原子改名挪进 `<output>/.superseded/`** → 「删行 + 重导入」包进同一外层事务（失败自动回滚复原旧行并把 zip 挪回）→ 生成成功才删掉挪走的那份，失败则**保留**并在报告记 `preserved_superseded`。新 staging 损坏时旧行与旧 zip 必须原封不动；**重生成选中同一 `start_datetime` 时也绝不能截断旧产物**（候选起点只有 3~4 个，同名是常态而非例外） |
| 8d | 导入前 staging 复校（R4-F1）：staged CSV 的字节数 + sha256 与 manifest 不符时记 `staging_integrity_mismatch` 且**绝不调用** `import_qmt_stock`（fetch 与 pilot 之间那段目前无人守，而链路上没有任何既有校验覆盖它） |
| 9f | **活跃行必须全属当前源代次（R14-F1）**：收尾对**所有活跃 `training_sets` 行**做源代次扫描，任一行的 `pilot_stock_source` 与当前 manifest 不符（或该股不在 manifest 里）→ `FAIL_STALE_GENERATION` + `stale_generation_rows`，**即便计数与地板都已达标**。行**不删**（留给操作者修 staging 后重跑）——「保留不销毁」与「判失败不放行」必须同时成立，否则一个卡在 `staging_integrity_mismatch` 的旧代次行会与 SUCCESS 共存，把 `pilot_stock_source` 不变量绕过去 |


---

## 10. 后续（不在本 PR）

- **4a**：DB 护栏（见 `2026-07-27-qmt-plan4a-db-guardrails-design.md`）
- **4c**：pilot 编排 + 报告凭据链（见 `2026-07-27-qmt-plan4c-pilot-shipment-design.md`）

---

## 11. 评审轮次记录

> **本文件已评 3 轮（O2 / P2 / O4）；本轮 O4 共 17 条。**
> 旧 spec `2026-07-26-qmt-plan4-pilot-shipment-design.md` 的 **R1–R97 账本**是本文件的历史前身。
> **O4 之后不再跑 spec 评审轮次**（user 2026-07-29 定案）：四轮 44→41→25→47 未收敛，
> 且约 22/47 是上一轮修改自身引入的损坏或未传播完的改动；剩余的真设计缺口交由实现期的
> **测试**证伪（本轮 4b 的 3 条平台事实就是评审**真跑代码**才发现的，散文推不出来）。
>
> **⚠️ 实施期修正另立一节，不计评审轮次**：见文末 **「S2 实施轮」**（2026-08-24 起，**9 条**）。
> 它们**不是**新一轮 spec 评审，正是上面这句预言的那种东西——**由真实数据与逐字核原文证伪的
> 设计缺口**：一条由挂载真实导出量出来（原判据在真实布局上无解），三条由把读侧枚举与写侧枚举
> **逐字对表**查出来（照原文实现会 100% 全红或跨工具算不出同一个数）。

### O4 轮（2026-07-29，Opus 5 对抗性评审）

| 编号 | 级别 | 结论 | 核实 | 处置 |
|---|---|---|---|---|
| O4-F1 | **critical** | `max_bytes` 收尾提交会覆盖 escape 的 `stopped_reason`，而 pilot 的 fail-closed **只认 `stopped_reason`** → 一棵已被证明动过的树被一次容量停止**洗白成合法凭据** | 逐条对读 4b 生命周期与 4c ② 分支，属实 | 已修：fail-closed 判据改为「**`fetch_fatal_error` 存在即无条件 fail-closed**」，`stopped_reason` 降为人读附注；escape 的 reason 不得被覆盖，另记 `stopped_reason_secondary`；4c ② 分支同步 |
| O4-F2 | high | per-stock 提交的 manifest **结构上**满足不了读侧强制的 `source_verification_evidence` → 崩溃恢复（含 §9-5n 的 SIGKILL 自愈钉）**永远够不着**，一棵 2 GiB staging 报废 | 属实（存根只能由批后收尾复校产出）| 已修：写死 per-stock 取值 `partial` + 空 `passes`；一致性校验显式限定在 `snapshot`/`full` 两级 |
| O4-F3 | high | 新值 `staging_recheck_failed` **不在自己声明为闭合的枚举里**（三处 + 4c `fetch_stopped_reason`）→ 写出来即被自己的读侧判非法，P2-F3 特意写的出路永远打印不出来 | grep 四处确认 | 已修：四处补入 + 4c 增 fail-closed 分支；`kind` 与 `stopped_reason` **解耦**（否则「保留 fatal + 换 reason」结构上不可表达）|
| O4-F4 | high | 回滚 `unlink` 撞 `ENOENT` 未定义，而它恰是**最常见**的回滚形态（崩在两次 `os.replace` 之间 → 四条里至少两条必不存在）→ 每次重跑都在同一处崩、池永远拉不完 | **本机实测** `os.unlink(dir_fd=)` 抛 `FileNotFoundError` | 已修：明写「四条一律容忍 `ENOENT`，其余 errno 才算失败」|
| O4-F5 | high | 回滚 else 分支在「manifest 已提交但文件校验不过」时把状态改坏：文件被删、记录留着、cursor 已越过 → **没有任何人会重拉**，池静默缩水 | 逐条读分支前提，属实 | 已修：拆成三档，第③档须删 `files`/`pool_order` 条目并回退 `cursor` |
| O4-F6 | high | 无标记残骸的两条 `rmdir` 指引与真实残骸形态**正好错位**：能 rmdir 的那档不给指引，给指引的那档必撞 `ENOTEMPTY` | **本机实测** `rmdir` 对含 `.staging.lock` 的目录返回 `ENOTEMPTY` | 已修：两支指引对调并具体化（先列目录内容 / 先删锁文件再 rmdir）|
| O4-F7 | high | 「立基准 / 比对」的二分**时序相关**而 `qmt_fetch` 无权威启动序列；且它依据的「`source_mount` 已进读侧必需键」不属实 → 一次补拉可被判成立基准 → **R23-F1 陈旧兄弟目录洞原样复活** | grep 读侧清单确认无 `source_mount` | 已修：写死权威启动序列（谓词有确定求值时刻）+ `source_mount` 及三子键进必需键 + 「只在立基准那次写入，比对模式一律只读」|
| O4-F8 | high | staged `export_log.csv` 触顶：§4（唯一权威）要求提交 manifest，而那份必然缺 `staged_export_log` → 读侧拒绝 → **staging 砖化**；正确处置只写在 §5（导出视图）| 对读文档级不变量第 1 条，属实 | 已修：第二档写进 §4.4 触顶协议本体，§5 退回引用 |
| O4-F9 | high | manifest 字段改名只做了一半：4c 宣布改叫 `fetch_fatal_error`，4b（manifest 权威）全文仍是 `fatal_error` → 一次源树逃逸被报成「manifest 畸形」，R94-F2 跨文件复发 | grep 两文件确认 | 已修：**由 4b 定名** `fetch_fatal_error`，写侧/读侧/§5/§9 四处一次改齐；4c 改为引用不宣布 |
| O4-F10 | medium | `manifest_version` **不在写侧字段清单里**（读侧必填）→ 自己产出的每份 manifest 都被自己拒绝；「大于/缺失」两档只在 §5 | grep :477 确认 | 已修：补进写侧枚举；三档全提进 §4.5；另补「不认识的顶层键须原样保留回写」|
| O4-F11 | medium | 整套耐久提交协议建立在 `fsync` 上，而 macOS `man 2 fsync` 明写**不保证断电耐久、也不保证写序** → O2-F1 的顺序屏障在目标平台不成立；现形态「对进程崩溃多余、对断电不足」| **本机 `man 2 fsync` 原文核实**：「This is not a theoretical edge case.」| 已修：显式声明威胁模型（断电在内）；manifest 提交 + O2-F1 顺序屏障改用 `F_FULLFSYNC`，其余保留 `fsync` |
| O4-F12 | medium | 「符号链接 → `ELOOP`」这条断言对**目录分量**是错的，而它已写进持久化的 `errno` 与 §5/§6 的造反例判据 → 照它写的回归钉在目标平台**必红** | **本机实测**：目录分量符号链接 → `ENOTDIR`（与「放了个普通文件」不可区分）；叶子文件 → `ELOOP` | 已修：伪代码注释与 §5 两处改成实测口径；`errno` 枚举保持 `{ELOOP, ENOTDIR}` 但注明含义 + 需区分时补 `lstat` |
| O4-F13 | medium | `files_verified: 812`（偶数）与 O2-F12 刚写死的成员集合（`2N+1`，必为奇数）互斥；同段读侧强制句仍是旧口径 | 算术核实 | 已修：示例改 813 并加注；读侧改为 `len(files) + 1` |
| O4-F14 | medium | `parent_fd_under` 只有一句话定义（失败语义 / `..` 拒绝 / fd 归属全缺），而它承载**唯一那条破坏性恢复路径** | 与 `open_under` 对读，属实 | 已修：补齐三条规格 + 恢复路径撞 escape 的专门处置；并明写**禁用 `os.supports_dir_fd` 能力探测**（**本机实测** `os.replace` 返回 False 却实际可用 → 防御式实现会恰好退回被禁止的按路径改名）|
| O4-F15 | low | 4b 名词表仍把 `--verify-shipment` 与 `①e` 列为「由 4c 定义」，而它们已移出 | grep 确认 | 已修 |
| O4-F16 | low | 补拉前置复校遇「源文件已不存在」未定义（那不是哈希不符，是算不出哈希）| 属实 | 已修：单独错误码 `source_file_vanished` + 干净拒绝非裸 traceback |
| O4-F17 | low | `--dest` / `--source` 输入规范化未定义 —— 一个 tab 补全带出的**尾斜杠**就会撞 `open_root` 的「拒绝空分量」，而唯一沾边的提示说的是符号链接 | O2-F6 已实测尾斜杠产生空分量 | 已修：入口做**纯字符串**规范化（去尾斜杠、折叠 `/`，**不得 `realpath()`**）+ 两条提示分开 |


**历史依据**：本文件全部结论来自旧 spec 的 **R1–R97 账本（201 条 codex finding + 3 处自查补，
全部为真、全部已修，codex 从未 approve）**。那份账本原样保留，本文件不复制。

**切分后本文件的评审从 R1 重新计数。**

### O2（Opus 5 对抗性评审，needs-attention，14 finding，全部接受并已修）

**评审通道**：codex 配额耗尽（2026-08-02 10:53 恢复），user 指示 spec 阶段改用 Opus 5。
**不替代** CLAUDE.md 治理 backstop 要求的 PR 阶段 `codex:adversarial-review` 必需状态检查。
**处置流程按 `superpowers:receiving-code-review`：先逐条 VERIFY 再 IMPLEMENT**，
下表「核实」列记录我实际验过什么（不是转述评审的话）。

| # | 级别 | 结论 | 核实 | 处置 |
|---|---|---|---|---|
| O2-F1 | high | 崩溃回滚对两条 final 的 `unlink` **不在耐久闭合清单、也不在两条豁免里** → 目录项丢失后该股被永久判 `untracked_target_file` 除名 | grep 清单：只有 `.part→final` 与 `.inflight.json`，**确无回滚项** | 补进清单 + **顺序屏障**：unlink → `fsync` 各自子目录 → 才允许删 `.inflight.json`（标记必须比它授权的动作**后**消失）|
| O2-F2 | medium | staged `export_log.csv` 逃过 `--max-bytes` 流式硬限 | 「计入总账的单位是已提交的股」确未含它 | 纳入逐块扣减，标为**唯一的非股级计账对象** |
| O2-F3 | medium | `open_under` 伪代码 `create_dirs` 分支**没有 `fsync`**，与同节耐久清单第 2 条打架 | grep 伪代码：有 `os.mkdir`、**无 `fsync`** | 补 `os.fsync(cur)`（新建成功才做）|
| O2-F4 | medium | 逐段无跟随只有 `open()` 原语；`os.replace`/`unlink`/`fsync(目录)` 没有对应原语 → 实施者会写 `os.unlink(str(staging/rel))`，而 `.inflight.json` 的形状校验用 `resolve()`（**会跟随符号链接**）→ **破坏性恢复路径删到边界外** | 签名确只有 `flags/mode` | 定义 `parent_fd_under(stg_fd, relpath)`；「每一次读写」改为「读、写、改名、删除、目录 `fsync`」 |
| O2-F5 | medium | 源边界闸七条在**首次 fetch** 时不可执行（第 3/4/4b 要跟 manifest 比，而这一次正在**创建**它；第 2 条要比 `out_fd`，而 `qmt_fetch` 根本没有 `--output`）→ 要么自锁、要么**立基准时零检查** | grep 593 行确引用 `out_fd` | 显式分**立基准模式 / 比对模式**两栏；立基准仍强制第 4 条的绝对要求部分 |
| O2-F6 | medium | `source_root_relative == ""`（正是本文件的挂载示例）时反向验证退化；源根定义在文内自相矛盾 | **已实测**：`"/Volumes/QMT_Export"+"/"+""` → `split('/')` 末位空分量 | 规定走 `posixpath.normpath(join(...))`；源根定义写死 |
| O2-F7 | medium | fail-closed 信号的清除谓词写成「本次没撞 escape」，而收尾提交**不要求走过出事的那些路径** → 一次不遍历它们的运行就能清掉它，manifest 声称拥有的 56 只股已不存在而证据没了 | 谓词确实只看「本次有没有撞」 | 改为「已**重新遍历过** `fatal_error.relative_path` 且未撞」；`staging_path_escape` 另加全量存在性 + sha256 复校 |
| O2-F8 | medium | manifest 无 schema 版本字段，读侧严格 fail-closed 且**无恢复路径**——三轮内追加过三次必需字段，每次都让既有 staging 永久不可用且工具自己解不开 | 三次追加属实（`staged_export_log` / 对象型 `pool_order` / `stopped_reason`）| 加 `manifest_version`，旧版本给**不同的错误与指引**；**不做迁移机制**（YAGNI：staging 是本机可重建的中间产物）|
| O2-F9 | medium | 首次认领的 `mkdir → 写标记`窗口无互斥，而 spec 辩护用的「其间无任何 I/O」**不成立**（至少一次 openat+flock、一次写、三次 `fsync`）→ 工具会指示操作者 `rmdir` 掉另一次运行**正在使用**的目录；A 的 `stg_fd` 此后写进一棵**不可达**的树并以 rc=0 宣称就绪 | 窗口内的 I/O 逐条对得上 | 打印 rmdir 建议**之前先试 `flock`**：取不到 → 报「另一次运行正在认领」；取得 → 才给 rmdir 指引 |
| O2-F10 | medium | 跨文件引用大面积损坏、§4 重号 | **是我切分时造的**（空标题 + 级联替换）| 已在结构性修复提交 `ac0aec8` 全部重建 |
| O2-F11 | medium | 本文件强制 pilot 报告带 `inflight_rollbacks`，而 4c 报告 schema 里**没有这个字段** | grep 4c 全文：**0 次** | 本节标注「须同时核 4c §4.3」，并在 4c 补入（见 O3）|
| O2-F12 | low | `aggregate_sha256` 成员集合写侧含 `export_log.csv`、读侧不含 → **每一份诚实产出的 manifest 都被判 `FAIL_MANIFEST_INVALID`** | 两处定义确差一项 | 成员集合写死为「`files` 每一条 + `staged_export_log` 一条」 |
| O2-F13 | low | `device` 判据含 `user@` —— 用户名是**凭据**不是共享身份，换账号重挂即拒 | macOS `mount` 输出确带它 | 比对前剥掉 `user@`，判据 = `//<server>/<share>`；原始串仍留痕 |
| O2-F14 | low | `failures` 台账无「重试成功后如何处置」，而它的条数是报告里判断池为何缩水的依据 | 确只写了「仍失败则 attempts 加一」 | 重试成功即移出 `failures` 计入 `batches`；`fetch_failures` 只统计**未解决**条目 |

**本轮唯一由我实测（非推理）坐实的**：O2-F6 的空分量（`posixpath` 行为）。其余为逐条 grep 核实文本断言。

⚠️ **本文件承载的是「路径·锁 信任边界」这一族**——按 R74–R97 共 47 条 finding 的实测分布，
fetch/储备池占 4 条、路径·锁占 8 条。**共享地基（§4.1）是三份 spec 里被 codex 挖得最狠的部分之一**
（`open_root` / `open_under` / 先钉后校 / 取锁早于发布归属，分别来自 R74-F2 / R75-F2 / R84-F1 / R97-F2），
实施时对它的每一条都要按「对象 × 维度矩阵」逐格核过。


---

## S2 实施轮（2026-08-24 ~ 08-30，4b 切片 S2a / S2b 实施前与实施中的核实）

> **不是评审轮次。** 依据两类硬证据：①2026-08-23 `mount_smbfs -o rdonly` 挂载真实 QMT 导出量到的
> 目录布局；②把 §4.4 写侧枚举、§4.5 读侧枚举、§4.6 边界闸三处**逐字对表**。
>
> ⚠️ **前四条（F1~F4）是实施前核出来的；后三条是实施中才浮出水面的**——
> **S2-F5** 由 Task 4 评审的一句「⚠️ 无法从 diff 核实字段名是否与写侧一致」引出、控制者回本文件追锚点时发现；
> **S2-F6** 由 S2a 的整支评审在对表实现与本文件时发现；
> **S2-F7** 由 S2a 的 **codex 对抗性评审 R1** 挖出——它是**唯一一条不是「对表」而是「拿畸形输入去撞」撞出来的**，也是**唯一一条方向为「畸形被放行」的**；
> **S2-F8** 由 **codex R2** 提出而**经核实不采纳**（它会误杀 spec 自己状态机产生的合法账本），但它指向的写侧缺口是真的，已移交 S4；
> **S2-F9** 由 **codex R3** 挖出——读侧判据**自己**会被它该抓的那种损坏弄坏；
> **S2-F10 / S2-F11** 由 **S2b 实施前核实 + 本机真跑**挖出（2026-08-30）——前者是「读侧校验必须对**磁盘对象的类型**安全」（F9 管的是 JSON **值**的类型），后者是生命周期决策表里 spec 从未定义的一格；
> **S2-F40 / S2-F41 / S2-F42** 由 **S2b 的 codex 对抗性评审 R15** 挖出（2026-09-01，3 条 high，均本机复现坐实）——⭐ **这一轮的层次终于变了**：F40 打的是**核心提交语义**、F41 是**一条 spec 要求从未被实现**，只有 F42 属于守卫边界；
> **S2-F37 / S2-F38 / S2-F39** 由 **S2b 的 codex 对抗性评审 R14** 挖出（2026-09-01，3 条 high，均本机复现坐实）；
> **S2-F35 / S2-F36** 由 **S2b 的 codex 对抗性评审 R13** 挖出（2026-09-01，各一条 high）——**两条都是 S2-F33/F34 那次修复留下的边界**；
> **S2-F33 / S2-F34** 由 **S2b 的 codex 对抗性评审 R12** 挖出（2026-09-01，各一条 high，本机复现坐实）；
> **S2-F32** 由**控制者自查**挖出（2026-09-01，等配额期间用第⑪问追 S2-F31 的同族另一处）；
> **S2-F30 / S2-F31** 由 **S2b 的 codex 对抗性评审 R11** 挖出（2026-09-01）——**S2-F31 是 §4.5 里一条我实现时直接漏掉的明文规定**（不是新缺陷，是漏读）；
> **S2-F28 / S2-F29** 由 **S2b 的 codex 对抗性评审 R10** 挖出（2026-09-01，各一条 high）——**两条都是 S2-F25 那次修复自己引入的**：一条修过头（堵死 spec 自己的重试成功路径）、一条修不足（守卫对坏输入「跳过」而不是「拒绝」）；
> **S2-F25 / S2-F26 / S2-F27** 由 **S2b 的 codex 对抗性评审 R9** 挖出（2026-09-01，2 high + 1 medium，**最彻底的一轮：73 条查看命令**，均本机复现坐实）；
> **S2-F24** 由**控制者追查 codex R8 掐断前留下的一条未完成线索**得来（2026-08-31）——那轮判决行是配额伪造的，但它中途那句「stale-but-valid caller snapshot can roll back already committed progress」值得追，本机复现坐实；
> **S2-F23** 由 **S2b 的 codex 对抗性评审 R7** 挖出（2026-08-31，high，本机复现坐实）——「空 dict 当哨兵」把两种截然不同的状态压成了一个；
> **S2-F22** 由**控制者自查**挖出（2026-08-31，等配额期间拿十条自问对刚改过的新代码跑一遍）——它是 **S2-F19 的同一个洞在另一个入口**，评审只报了其中一处；
> **S2-F19 / S2-F20** 由 **S2b 的 codex 对抗性评审 R6** 挖出（2026-08-31，各一条 high，本机复现坐实）；**S2-F21** 是控制者顺着 F19 回头重核**已登记残留**时发现它其实是活的洞——⚠️ **判据：登记为「已接受残留」的东西，每一轮都要重新问一次它还能不能被利用**；
> **S2-F16 / S2-F17 / S2-F18** 由 **S2b 的 codex 对抗性评审 R5** 挖出（2026-08-31，2 high + 1 medium，均本机复现坐实）——**三条的共同形态仍是「我只修了一半」**：F16 是那条分支的次序被改了三轮仍没到位；F17 是「用启动快照挡住调用方污染」只落在 `commit_stock`、漏了**唯一能清除证据**的 `commit_final`；F18 是「写侧要产出读侧收得下的东西」只补了**结构**那一半、漏了**大小**那一半；
> **S2-F15** 由 **S2b 的 codex 对抗性评审 R4** 挖出（2026-08-31，high）——**它是 S2-F14 的修复动作自己留下的另一半**：为「哪些状态必须做过 staging 全量复校才能清」抽出的那个判定被用在了**覆盖闸**上，却漏了**清除闸**；
> **S2-F14** 由 **S2b 的 codex 对抗性评审 R3** 挖出（2026-08-30，high，本机**三次运行**端到端复现坐实）——spec 自己的两句话（「本次又撞 escape → 覆盖上一次的」与「`fetch_fatal_error` 是粘性的信任状态」）在某个次序上直接冲突；
> **S2-F12 / S2-F13** 由 **S2b 的 codex 对抗性评审 R2** 挖出（2026-08-30，各一条 high，本机端到端复现坐实）——前者是「读侧接受了写侧根本产不出的组合」（**S2-F7 的同一方向：畸形被放行·安静**，而且这次连**取值之间的配对**都没查），后者是「写入口能产出自己读不回来的账本」（**写侧/读侧不配对家族的第六次**，只是这次跨的是写入口与读入口）。
>
> ⚠️ **S2-F7 与 S2-F8 是同一枚硬币的两面，必须一起读**：
> F7 = 读侧**太松**（畸形被放行），F8 = 差点让读侧**太紧**（诚实产出的被判非法）。
> 两者都产生于「拿写侧与读侧对照」这一个动作，**方向相反**。
> 判据：每提出一条读侧新判据，必须**双向**各问一次——
> ①有没有畸形能溜过去？②有没有**合法**状态会被它判死？
> 只问一个方向，就会在修好一个洞的同时凿开另一个。
> **这本身是一条判据**：写侧/读侧对表**光在评审 spec 时跑一遍不够**——实施与评审各自还会再照出一批。
> **凡「已实测」均为本机真跑，非推理**；凡「逐字核」均给出原文行位。

| 编号 | 级别 | 结论 | 核实 | 处置 |
|---|---|---|---|---|
| S2-F1 | **high** | **O2-F6 的源根判据在真实导出上无解** —— 它写死「包含 `front_ratio_cn_stocks_ab_bj/` **与** `export_log.csv` 的那一层」，而真实布局里 `export_log.csv` 在 `front_ratio_cn_stocks_ab_bj/` **里面**、与两个 K 线目录并列。照原判据取上一层则 `<source>/export_log.csv` 不存在 → **源边界闸第 3 条当场判死一次完全合法的部署** | 真实挂载实测（见 `project_qmt_real_source_measurements`）；闸 3 原文（§9-1j ③）逐字核 | 改判据为「**包含 `export_log.csv` 的那一层，不认目录名**」。连带：staging 由**两级**中间目录变**一级**（`1分钟K线_前复权/`），staging 成为源根的逐层镜像；§4.5/§4.6/§5 共 **9 处**举例同步更新。**已实测**：`import_csv` 的 `rglob` 对这一层的有无**零依赖**（两种布局都恰好命中 1 个、`.part` 不误命中） |
| S2-F2 | medium | **读侧「三子键均为非空 str」与 §4.6 (ii-a) 直接冲突** —— (ii-a) 用实测论证 `source_root_relative` **就是空串**（共享本身即导出根时），读侧却要求它非空 → 该部署先过 (ii-a) 的拼接、再被读侧判死，操作者被指向一个不存在的问题 | §4.5 读侧枚举 vs §4.6 (ii-a) 逐字对照 | 读侧放宽为「三子键均为 str；`fstype`/`device` 非空，`source_root_relative` 允许空串」。(ii-a) 原样保留（它有实测支撑），其举例改为一个在新源根定义下真正成立的形态 |
| S2-F3 | **high** | **读侧必需键里的顶层 `universe` 是笔误** —— 同一句话末尾校验的是 `source_snapshot.universe`，写侧枚举与 §4.4 结构示例也**只产出后者**。照原文实现：**本工具诚实产出的每一份 manifest 都被本工具自己的读侧判 `FAIL_MANIFEST_INVALID`**，一次都跑不通 | §4.5:662 顶层枚举 vs §4.5:664 校验句 vs §4.5:533 写侧枚举 vs §4.4:295 示例，四处逐字核 | 删掉顶层 `universe`；名单唯一位置定为 `source_snapshot.universe`。**这是「写侧形状与读侧要求不配对」的第三次**（R94-F2 四字段、O4-F13 `2N+1`）→ 立纪律：**每新增一个持久化字段，必须同时在写侧枚举与读侧枚举各出现一次且层级逐字相同** |
| S2-F4 | medium | **`aggregate_sha256` 的序列化方式从未定义** —— 只说「排序列表取 sha256」，没说列表怎么拼成字节。而**写它的是 4b、读它比对的是 4c**（两个切片、两份 plan、不同时间实施），拼法差一个空格或一个 `\uXXXX` 转义就让每一份诚实产出的 manifest 被判非法 | §4.5 存根定义处逐字核：无任何字节级规定 | 写死为 `json.dumps(sorted(pairs), ensure_ascii=False, separators=(",", ":")).encode("utf-8")` 后取 sha256；`ensure_ascii=False` 与 `separators` **都是判据的一部分**（周期目录名是中文）。**由 4b 提供唯一实现，4c 直接调用，不得各自重写** |
| S2-F5 | **high** | **`files` 每条记录的字段名，写侧与读侧又一次不配对（同族第五次）** —— 写侧枚举写「实拷清单（`code`, `market`, 每文件 `{bytes, sha256}`）」，读侧却要求 `stock_code` / `period`，且**写侧从头到尾没提 `relative_path`**（而读侧把它当作路径逃逸判据的对象）。照写侧实现的 `qmt_fetch` 产出的每一份 manifest，都会被读侧判 `FAIL_MANIFEST_INVALID` | 写侧 §4.5「写 `fetch_manifest.json`」那一条 vs 读侧 §4.5「实拷清单必须逐项合规」逐字对照 | 写侧改为 **`{stock_code, period, relative_path, bytes, sha256}` 五字段**，与读侧逐字相同。**`market` 不落盘**（可由 code 后缀派生；冗余字段一旦落盘就必须再配一条「与后缀一致」的校验，否则可伪造——白加一个字段与一条判据，user 2026-08-24 拍板不存） |
| S2-F6 | medium | **读侧的路径判据写着 `resolve()`，而实现用的是分量规则 —— 偏离未登记**（S2a 整支评审 I3 指出）。`resolve()` **会跟随符号链接**（那正是 O2-F4 造 `parent_fd_under` 的全部理由），拿它当边界判据等于把判据建在**会被绕过的调用**上；且它要碰文件系统，读侧校验就不再是纯函数。实现改用 S1 的**分量规则**（拒绝绝对路径 / 空分量 / `.` / `..`）——**更强且不碰磁盘** | S2a 实现与 §4.5:697/:740 逐字对照 | 两处读侧要求改为「经**分量规则**校验后落在 staging 之内」，并注明真正的符号链接防线在打开那一刻由 `open_under` 逐段 `O_NOFOLLOW` 承担。⚠️ §4.5:430 的 `.inflight.json` 形状校验**同样写着 `resolve()`**，那是 **S4** 的范围，本片不改，但已在此登记——**照原文实现会放行一条破坏性恢复路径删到边界之外**（R13-F2 早已论证过同一件事，只是那次只落在 `--output`） |
| S2-F7 | medium | **读侧枚举漏了 `passes[].pass` 的取值，只查键在不在**（codex 对抗性评审 R1 指出，控制者实测坐实）。§4.5 的读侧强制句列了「趟数 / `passes_agree` / `aggregate_sha256` / `files_verified`」，**唯独没列 `pass` 本身**，而 §4.4 的 JSON 把它钉死为 `1` / `2`。后果：两条都写着 `pass: 1` 的记录、次序颠倒的 `[2,1]`、以及 `None` / 布尔 / 越界 / 字符串，**六种畸形全部被放行**——一份存根凭「两个列表元素」就能冒充「两趟连续复校」，而 R16-F1 造这份存根的全部理由正是要证明「那两趟**真的跑过**」 | **本机实测**六种构造全部通过校验（非读代码推断）；§4.4:737-739 JSON 与 §4.5:760 读侧强制句逐字对照 | 读侧补判据：`passes[i].pass` 须为**整数（排除布尔）且等于 `i + 1``，故 `snapshot` 恰为 `[1]`、`full` 恰为 `[1, 2]`。**这是写侧/读侧对表家族的第六次，但方向与前几次相反**：S2-F3/F5 是「诚实产出的被判非法」（吵闹、开跑即全红），本条是「畸形的被放行」（**安静**，一份 fail-closed 校验对这个字段实际是敞开的）。**吵闹那一半开跑就会暴露，安静这一半只能靠对表或对抗性评审挖出来** |
| S2-F8 | **high**（**不采纳读侧判据**；真缺口移交 S4）| **codex R2 提出：读侧应强制「每个 `pool_order` 条目的 `universe_idx` < 该层 `cursor`」**，理由是池条目代表已成功、cursor 是下一个待尝试位。**该判据对本 spec 的状态机不成立** —— §4.4:346 规定补拉**先重试台账里的旧槽位**（§4.4:342 明说旧槽位位于 `cursor` **之前**），而崩溃恢复第③档（§4.4:426-428）在「已提交但 final 不符」时要求 `cursor ← min(cursor, universe_idx)` 且**只删该股的**`files`/`pool_order` 条目。二者一凑即产生「池里存在 `universe_idx ≥ cursor` 的条目」这一**合法**状态 | **本机实测构造**：冻结名单 SH=[600000(0), 600004(1), 600006(2)]，重试 idx0 提交后崩、恢复走第③档 → `cursor[SH]=0` 而池留 idx1/idx2。该 manifest **现行校验放行**（与 §4.5:668-672 的枚举一致，其中本就没有此交叉判据）；加上建议判据则 **2 条被判非法** → 一份 spec 明令产生的账本被 `FAIL_MANIFEST_INVALID`，整棵 staging（约 2 GiB）读不回来 | **读侧不加该判据。** 但 finding 指向的缺口是真的，**位置在写侧**：cursor 回退到已有池条目之前后，拷贝循环从 `cursor` 续跑会**重新尝试已在池里的槽位**，再次提交即撞上「层内 `universe_idx` 唯一」→ 账本自我判非法。§7 验收判据 5d 早已要求「U5 失败 / U6–U121 成功场景下**不得重拷 U121**」，但**没说 cursor 回退后循环怎么认已成功的槽位**。**移交 S4（拷贝引擎）**：续跑循环须以 `pool_order` 为准跳过已成功槽位，不得只看 `cursor` |
| S2-F9 | medium | **读侧判据自己会被它该抓的那种损坏弄坏**（codex R3 指出）—— `fetch_fatal_error.kind` / `errno` 的校验先做 `x in <frozenset>` 再验类型，而 list/dict **不可哈希**：一份被编辑坏的 manifest 得到的不是 fail-closed 拒绝，而是带原始 traceback 的进程崩溃，`ManifestInvalidError` 那句「换新 staging + 新 seed 重拉」的恢复指引**一个字都印不出来** | **本机系统性探测**：一份合法 manifest 的**每一个**位置 × 六种 JSON 坏值（list/dict/null/int/str/bool）共 **984 个组合**，抛出非 `ManifestInvalidError` 的**恰好 4 个**，全部落在这两个字段；其余全部安全（要么先验了类型——同文件 `stopped_reason` 就是对的写法，要么常量是元组而非集合）| 两处改为**先验类型再比取值**。另立**整族守卫**（不是 4 条点测）：该 984 组合扫描固化为一条测试，**对将来新增的字段自动生效**，并带**防空转下限断言**（探测数 < 900 即判红，免得枚举器被改坏后「零崩溃」通过而实际什么都没测）。⚠️ **这条纪律对 S4/S5/4c 全部适用**：它们还要写更多读侧判据——**每一条判据自己必须对任意 JSON 类型安全**，否则守卫会在最该工作的时候崩掉 |
| S2-F10 | **high** | **读侧的 manifest 读回口对「磁盘对象的类型」完全没有判据** —— §4.5 只写「相对 `stg_fd` 逐段无跟随读回」。照原文实现（裸 `open(O_RDONLY)`）时：manifest 被换成 **FIFO** → `open` **一直阻塞等写入方**，`qmt_fetch` **永久挂起且不打印任何提示**（比崩溃更糟：没有任何错误信息，操作者只看到卡住）；被换成**目录** → `open` 成功、随后 `os.read` 抛原始 `IsADirectoryError`，`ManifestInvalidError` 那句恢复指引一个字都印不出来。**这是 S2-F9 的另一半**：F9 管「JSON **值**的类型」，本条管「**磁盘对象**的类型」 | **本机真跑**（非推理）：①目录能被 `O_RDONLY\|O_NOFOLLOW` 成功打开，`st_size=64`、`S_ISREG=False`，`os.read` → `errno 21`；②FIFO 的 `open(O_RDONLY)` 3 秒未返回；带 `O_NONBLOCK` 立即返回。③变异验证：把 `O_NONBLOCK` 去掉后那条测试**不是变红而是 15 秒被闹钟杀掉、日志 0 字节**，退出码 142 | 读回口改为经 S1 的 `open_regular_probe`（`O_NONBLOCK` 打开 → `S_ISREG` 判类型 → 是普通文件才清掉 `O_NONBLOCK`），不是普通文件即 `ManifestInvalidError`。S1 的 docstring 早已写明「三个打开点（取锁 / 探测 / 读标记）统一走本函数，**避免『同一条纪律只落在其中一处』**」——`read_manifest` 是**第四个**打开点，S2b 把它接进来（连带把 `_open_regular_probe` 转公开）。⚠️ **这条纪律对 S4/S5 全部适用**：`.inflight.json`、staged CSV、`export_log.csv` 的每一个读回口都是同一形态 |
| S2-F11 | **high** | **生命周期决策表有一格 spec 从未定义：「上次是 `source_path_escape` + 本次重走过那条路径 + staging 全量复校**失败**」** —— §4.5 把「复校失败 → 保留 fatal + `stopped_reason: staging_recheck_failed`」**只写在 `staging_path_escape` 的语境里**（前提②是它「另加」的）。照原文的分支次序（先判 `fatal.kind` 再判复校结果），source escape 这一支会直接走到「已证明干净 → 清除」，**把 fatal 与「复校失败」这两个信号一起丢掉** → 一棵已被证明与账本对不上的 staging 拿到干净标签，pilot 照常消费 | S2b 实施时按「双向各问一次」逐格穷举决策表：对每一格问「①有没有畸形能溜过去？②有没有合法状态会被判死？」，本格在方向①上漏了 | **「复校失败」提到 `kind` 判断之前**：复校失败一律不清除，与 fatal 的种类无关（`staging` 全量复校失败是一个与「上次为什么出事」无关的事实）。该判据**只增加拒绝**，方向②上不误杀任何合法状态——被它拦下的唯一新情形就是「staging 复校失败却要清 fatal」。已配专属档 + 变异验证（把两句挪回 kind 之后，该档必红）|
| S2-F12 | **high** | **§4.5 的读侧枚举从未规定 `stopped_reason` 与 `fetch_fatal_error` 之间的取值配对**，只写了「三值必须同时带形状合规的 fatal」这一个方向。于是 `stopped_reason="staging_path_escape"` 配 `kind="source_path_escape"` 被放行——而生命周期决策表只看 `kind`，这份账本走「重走过 + 未做复校」时会**绕过 P2-F3 无条件要求的 staging 全量复校**直接清掉 fatal，**一棵被证明动过的树拿到干净标签**。改一个字段的 6 个字符即可，而「有人动过 staging」正是本 spec 的威胁模型 | codex R2 [high]，控制者**本机端到端复现**：读侧放行 → `clean_finish(revisited_fatal_path=True, staging_recheck=None)` 返回 `{}`。另按判据穷尽挖出同族两条（评审未报）：`fatal` 在而 reason 为 `max_bytes`、只有 `secondary` 而无 `fatal`，两者写侧同样产不出 | 读侧补**取值级配对**三条：①有 `fatal` ⇒ reason ∈ 那三值；②reason ∈ `FATAL_KINDS` ⇒ **reason == `fatal.kind`**；③有 `secondary` ⇒ 有 `fatal`。**`staging_recheck_failed` 是唯一允许解耦的（O4-F3），两种 kind 都放行**——已配正向档。决策表（公开纯函数，可绕过 `read_manifest` 直接调用）**共用同一判据自查**。⚠️ **对 S4/S5/4c 全部适用**：新增任何持久化字段，除了「写侧枚举与读侧枚举各出现一次」，还要问**它与既有字段之间的取值组合，写侧能产出哪些**，读侧照单收口 |
| S2-F13 | **high** | **spec 从未规定「提交前先过一遍读侧校验」** —— 于是 `qmt_fetch` 的提交入口能写出一份**自己读不回来**的 manifest。实例：`commit_stock` 的 `lifecycle` 参数塞 `{"stopped_reason": "source_path_escape"}`（合法的生命周期键），写入**报告成功**，而下一次 `read_manifest` 判它非法（那个 reason 必须带 `fetch_fatal_error`）→ **整棵 staging 读不回来**。一次 per-stock 提交就能把已经拉了几百只股（约 2 GiB）的 staging 变成砖头，而干成这件事的那次调用返回的是成功 | codex R2 [high]，控制者**本机端到端复现**：先写一份合法账本、再提交一次不配对的、下一次读回即 `FAIL_MANIFEST_INVALID` | manifest 的唯一落盘路径在 `atomic_write_json` **之前**先跑 `validate_manifest`。**次序是判据的一部分**：排在写入之后的话，上一份好账本已被 `os.replace` 换掉，报不报错都救不回来——已配「拒绝后上一份账本逐字节未变 + 无临时残留」的专属档。⚠️ **这是 R94-F2 / O4-F13 / S2-F3 / S2-F4 / S2-F5 那个家族的第六次**，只是这次跨的是**写入口与读入口**而不是两份枚举；修法不是「调用方小心点」而是让坏状态**不可表达**：写不出去。**S4/S5 新增任何落盘入口都必须走同一条路径** |
| S2-F14 | **high** | **「本次又撞 escape → 覆盖上一次的」这条规则会抹掉未解除的粘性信任证据** —— 清除 `staging_path_escape` 要过**两道**前提（另加全量存在性 + sha256 复校，P2-F3），清除 `source_path_escape` 只要一道。于是次序 `staging → source` 让后者覆盖前者，等于**把那道门取消了**。⚠️ 同族变体（控制者按判据穷尽挖出）：`stopped_reason == "staging_recheck_failed"` 同样是「必须做过全量复校才能清」的状态，而它的 `kind` 可以是 `source_path_escape`（O4-F3 解耦）——**只按 `kind` 判「严不严」会漏掉它**，一次 source 逃逸就能把「上次复校没通过」这个结论抹掉 | codex R3 [high]；控制者**本机三次运行**端到端复现：Run1 撞 staging → Run2 撞 source（staging 证据消失）→ Run3 干净跑完、重走过源路径、**未做 staging 全量复校** → fatal 被清除，一棵从未证明恢复过的 staging 拿到干净账本 | 覆盖规则改为「**同级或升级才许覆盖，绝不许降级**」，严格性的定义 = **清除它是否需要 staging 全量复校**（同时看 `kind` 与 `stopped_reason`）。方向②逐条配了放行档：`source → staging`（升级）、`staging → staging`（同类；**全量复校是路径无关的**，只留最新那条路径不构成信息损失）、`source → source`（同类）三种覆盖都必须照常发生。⚠️ **已接受的残留**：被拒绝覆盖的那一次 source 逃逸不进 manifest（schema 只有一条 `fetch_fatal_error`，本片不引入新字段）；本次运行的失败由 S4/S5 在**运行级**输出（rc≠0 + 报告）承担，manifest 保留的是**更难清除的那个结论**，方向是 fail-closed。⚠️ **对 S4/S5/4c 适用**：凡「新事件覆盖旧状态」的规则，都要先问「新状态是不是至少和旧的一样严」|
| S2-F15 | **high** | **清除闸仍按 `fetch_fatal_error.kind` 判「要不要 staging 全量复校」，漏掉 `stopped_reason == "staging_recheck_failed"`** —— 而后者的 `kind` 可以是 `source_path_escape`（O4-F3 解耦，且**本代码自己就会产出这个组合**：source fatal 恢复过程中复校失败）。于是两次运行即可洗白：Run1 复校失败 → Run2 干净跑完、重走过、**未做任何复校** → 两个信号一起被抹掉，一棵已被证明与账本对不上的 staging 拿到干净账本 | codex R4 [high]，控制者**本机两次运行**端到端复现（第一步产出的那份 manifest 本身过读侧校验）；并按判据穷尽做 AST 扫描确认全模块**只剩这一处**在直接比 `kind` | 清除闸改用同一个判定函数。⚠️ **根因是同一件事判在两处、改了一处忘了另一处**——这正是 S2-F14 的修复动作留下的另一半，属「结构性改动后要重核原来成立的东西」那一类。修完**留了机械守卫**：AST 断言「与字面量 `staging_path_escape` 的比较只许出现在那一个判定函数里」，并带**防空转下限**（一处都找不到即判红）；用 AST 而非 grep，因为承重注释里出现该字面量是正常的，文本扫描会被自己的注释打红、而绕过方式是删注释。方向②另配三档防止修过头（纯 source 逃逸仍只需前提①）——变异实测：把清除闸写成恒真，那三档立刻变红 |
| S2-F16 | **high** | **「本次 staging 全量复校失败」被「有没有重走过出事路径」的早退挡住** —— 前者是**本次运行的事实**，后者（前提①）管的是**能不能清除**，两者无关。次序颠倒时 `clean_finish(revisited_fatal_path=False, staging_recheck="failed")` 会原样保留旧的 `source_path_escape`、**把复校失败这个事实丢掉**；下一次运行重走过源路径又不做复校 → 只看见一个 source 逃逸 → 两个信号全清 | codex R5 [high]，本机两次运行复现 | 「复校失败」提到前提①早退**之前**。⚠️ **这条分支的次序被改过三轮**（S2b 的 D5 → D16 → 本次），每次都只挪了一格——**凡「判据 A 必须先于判据 B」的结论，都要把该分支挪到它该在的最前面，并配一条把次序钉死的档** |
| S2-F17 | **high** | **收尾提交的「上一次状态」取自调用方内存，而不是磁盘** —— per-stock 提交早已用启动快照挡住「调用方污染内存里那份 manifest」，但**唯一能清除证据的收尾提交**却直接从同一份可变 manifest 取粘性状态。磁盘上有未解除的 staging 警报、内存里三个键被弄没了 → 决策表看见「上次没有 fatal」→ 产出空生命周期 → **发布一份干净账本**，而落盘前的读侧校验抓不到（它结构上完全合法）| codex R5 [high]，本机复现 | 收尾提交先 `read_manifest(stg_fd)` 取**磁盘上**的生命周期作为凭据；`None`（引导态）合法，抛异常则拒绝发布（fail-closed）。⚠️ **判据**：凡「防调用方污染」的保护，要问**能造成最大损害的那个入口**有没有被它覆盖到——本片当初只覆盖了调用频次最高的那个 |
| S2-F18 | medium | **写侧不校验序列化后的字节数** —— 读侧有 64 MiB 硬上限，而未知顶层键按 O4-F10 是「原样保留且**无上限**」的通道。一份结构完全合法、序列化后 67,113,084 字节的账本**写入报告成功**，下一次启动却以「过大」拒绝整棵 staging，已积累的数据全部不可用 | codex R5 [medium]，本机构造复现 | 落盘前按**最终编码**序列化、量字节数、超限即拒，并把**同一批字节**交给写入函数（另立 `encode_json` / `atomic_write_bytes` 消除序列化漂移：两处各自 `dumps` 一次，`ensure_ascii` 一改中文周期目录名长度差好几倍，量到的就不是落盘的）。⚠️ **这是 S2-F13 的另一半**：「写侧要产出读侧收得下的东西」不只是**结构**，还包括**大小**、以及任何读侧设了上限/下限的维度 |
| S2-F19 | **high** | **「磁盘上没有账本」被当成全新引导态** —— S2-F17 把收尾提交的凭据从「调用方内存」改成「磁盘」之后，**账本消失**就成了新的洗白入口：运行中把 `fetch_manifest.json` 删掉/改名 → `read_manifest` 返回 `None` → 内存里还带着未解除的警报、磁盘上的证据却没了 → **发布一份结构完全合法的干净账本** | codex R6 [high]，本机复现 | **正解不是二选一，而是两边都要**：磁盘是**当前真相**，`begin_run()` 在启动时取的快照是**预期**；「预期非空而磁盘上账本不见了」以及「磁盘与预期不一致」一律 fail closed。⚠️ **这条是 S2-F17 的修复自己带出来的另一面**——凡把凭据从 A 换成 B，都要问「B 缺席/被篡改时会怎样」 |
| S2-F20 | **high** | **`--skip-existing-verify` 的互斥只在收尾提交才被判定** —— P2-F3 明写「撞上即**拒绝启动**」，而它此前只在 `resolve_final_lifecycle` 里求值，那是**收尾**才走的路径。一次带 flag 的运行可以先拷完文件、推进 `cursor`、写满 `pool_order`，到最后才被拒 —— **已提交的状态与已消耗的冻结宇宙/`--max-bytes` 配额都收不回来**，与「拒绝启动、一个字节都不写」直接冲突 | codex R6 [high]；模块里当时**根本没有启动闸类入口** | 新增 `begin_run(stg_fd, *, skip_existing_verify)` 作为**启动闸**：读回账本、判互斥、返回启动快照。⚠️ **已接受的残留**：本模块没有运行上下文对象，**无法强制调用方先调它再动文件系统**。→ **对 S4/S5 的硬性要求**：启动序列第一步就调 `begin_run`，且在任何拷贝 / 建目录 / 提交之前 |
| S2-F21 | **high** | **「per-stock 提交够不到生命周期三字段」当时是**有条件**的** —— 它靠「调用方在启动时取一次快照、每次提交原样传进来」。本片曾把「调用方可能传一份伪造的快照」登记为**已接受的残留**；R6 期间控制者回头重核，**实测证明它是活的洞**：`commit_stock(..., lifecycle={})` 一次就能把磁盘上的 `fetch_fatal_error` 抹掉，而它是 pilot 的 fail-closed 判据 | 控制者本机复现（非评审报告项）| **拆掉那个参数**：三个字段一律从**磁盘上那份 manifest** 读出来原样写回，调用方无从干预 —— 「够不到」从此**无条件**成立。代价是每股多一次 manifest 读回（与同一次提交里的 `F_FULLFSYNC` 相比可忽略）。⚠️⚠️ **判据（对 S3/S4/S5/4c 全部适用）**：**登记为「已接受残留」的东西，每一轮都要重新问一次它还能不能被利用**——残留是「当时判断代价不划算」，不是「证明了无害」 |
| S2-F22 | **high** | **S2-F19 的同一个洞在 per-stock 提交上照样存在** —— S2-F21 把它也改成「三个字段从磁盘读」，于是「账本被删」对它同样成立：`read_manifest` 返回 `None` → 写出一份**没有警报**的账本。收尾提交的快照比对能在**最后**兜住，但**运行若崩在收尾之前，下一次就从一份干净账本开始**——而崩溃恰恰是本 spec 明写要扛的场景 | **控制者自查**（非评审报告项）：拿第⑨问「凭据从 A 换成 B ⇒ B 缺席时会怎样」对**两个**入口各跑一遍 | 抽出 `_lifecycle_from_disk(stg_fd, startup_lifecycle)`，**两个提交入口共用同一份判定**（S2-F15 的教训：同一件事绝不判在两处）；`startup_lifecycle` 只当**预期**比对、**从不写进 payload**，故不构成走私通道。另把 `begin_run` 的 `skip_existing_verify` 补上 bool 类型校验（R1 那条教训没有应用到**新加的**参数上）。⚠️ **判据**：评审报了 A 处，**必须自己把同族的 B 处也找出来**——尤其当两处是同一轮改动引入的 |
| S2-F23 | **high** | **`{}` 这个哨兵把「磁盘上没有账本」与「账本在、但没有生命周期字段」压成了同一个状态** —— 提交入口拿它的**真假值**判断「后来账本不见了算不算合法引导态」。于是一棵**已经积累了 `files` / `pool_order` / `cursor` 的干净 staging**，账本被删之后会被当成引导态、拿调用方内存里那份（可能过期的）**凭空重建**，已积累的进度静默丢弃；被换成另一份合法的干净账本同样无人察觉（两份的生命周期都是空的）| codex R7 [high]，本机复现两档：删掉已建成账本后 `committed_bytes`/`failures` 全部消失；换成别的 seed 后被静默覆盖 | 凭据改为**不透明的 `RunLedger`**，分别记 ①当时**有没有**账本 ②那份账本的**字节指纹**；消失 / 被替换 / 引导态里凭空出现，三种都 fail closed，**且每次提交成功后自动更新预期**（否则引导态跑完首份提交后，账本再消失就检测不出来了——已配专属档）。⚠️⚠️ **判据（对 S3/S4/S5/4c 全部适用）**：**凡用「空值/假值」当哨兵，先问它是不是把两种语义压在了一起**。⭐ 这与 R60-F3「manifest 不存在 ≠ manifest 坏了」是同一族的**反向**错误：那次正确地分开了两种状态，这次又把两种状态合并了 |
| S2-F24 | **high** | **一份过期的调用方副本能悄悄回滚已提交的进度** —— 运行凭据管的是「账本有没有被**外人**动过」（消失 / 被替换 / 指纹变了），它**管不了**「调用方自己交回来的内容退步了」：两个提交入口的**非生命周期内容全部**来自调用方内存。本机复现：调用方拿一份过期副本再提交一次，`files` 由 6 条退回 4 条、`cursor` 倒退、`pool_order` 缩水，而凭据检查照过。后果：已拷到盘上的股票被从台账里抹掉——随后既不在池里，又会被 pilot 当成 `untracked_target_file` | 控制者本机复现（线索来自 codex R8 掐断前的中途消息，**那轮判决是配额伪造的、不计轮次**）| 加回滚守卫：`files` / `pool_order` 条目不得消失、`cursor` 不得倒退。⚠️⚠️ **绝不能写成「条目只增不减」**——§4.4:429 明写崩溃恢复发生在「读完并校验 manifest **之后**、任何拷贝**之前**」（即 `begin_run` 之后、运行之内），而恢复第③档要求 `cursor ← min(cursor, universe_idx)` 且只删该股条目，**那是合法回退**；写死单调会打死 spec 自己的恢复路径。⇒ 只拦**未声明**的回退，唯一正当理由由调用方显式声明（`commit_stock(..., recovering_from_crash=True)`，且该参数须为真布尔）；**收尾提交没有这个声明**（崩溃恢复不走它）。⚠️ **已如实登记的判别力退化**：`files` 与 `pool_order` 两条判据被账本自身的一致性规则（R21-F3）**结构性绑死**，只缩其中一边会先被读侧校验拒掉 → 造不出专属档；`cursor` 那条已单独配档 |
| S2-F25 | **high** | **回滚守卫只看了三样东西**（`files` 身份 / `pool_order` 身份 / `cursor` 方向），其余非生命周期字段**全部**能被一份过期副本改写。**逐字段实测 9 项全部通过**：`committed_bytes` 调小（**绕开 `--max-bytes` 硬上限**）、`failures[].attempts` 清零（**复活已耗尽重试的候选**）、`batches` 与 `inflight_rollbacks` 被丢弃（**把本机故障史抹成「市场就这样」**，R66-F3 白立）、已提交文件的 `bytes`/`sha256` 被改（**完整性基线被污染，`staging_intact` 从此校验一条假基线**）、冻结的 `seed`/`universe`/`source_mount` 被换（**staging 与归属标记永久对不上**）| codex R9 [high]；控制者逐字段本机复现 9 档 | 守卫扩为三类：①**冻结字段**逐字不变（`manifest_version`/`seed`/`source_snapshot`/`source_mount`/`staged_export_log`；⚠️`source_verification*` **不在**此列，它们本就该被收尾复校重算）；②**已提交的 files 记录**不得消失、也不得被改写；③**单调计数**只增不减（`committed_bytes`/`batches` 长度/`inflight_rollbacks` 每键/每股 `attempts`）。⚠️ **判据**：第①问（按字段穷尽）**同样适用于守卫本身**——我只列了想得到的那几个字段 |
| S2-F26 | **high** | **崩溃恢复是一个「无限制旁路」** —— `recovering_from_crash=True` 整条跳过回滚守卫。本机复现：一次「恢复」把**所有市场的所有股票**全清了、`cursor` 全归零，而账本结构上仍然合法 —— 已提交的 CSV 全部变成无主文件、整轮进度丢光。spec §4.4 恢复第③档只允许**删那一只在途的股**并把**该层** `cursor` 退到它的 `universe_idx` | codex R9 [high]，本机复现 | 布尔旁路换成**范围描述符** `RecoveryScope(stock_code, market, universe_idx)`（构造期校验代码正则 / 市场枚举 / 后缀与市场一致 / 下标非负整数），逐项比对增量：只许删该股的 files、只许删该层那一个池条目、`cursor` 只许退到 `min(cursor, universe_idx)`；**其余不变量照旧强制**（顺手夹带改 `seed` 仍被拒——已配专属档）。⚠️ **判据**：**布尔旁路是反模式**——「允许做某事」要连**做到什么程度**一起声明 |
| S2-F27 | medium | **语法完全合法的 JSON 仍能让读回口抛裸异常** —— 解析器只接了 `JSONDecodeError`，而 Python 3.11（CI 钉的版本）对**超过 4300 位的整数**在 `int()` 转换时抛**裸 `ValueError`**，深嵌套则抛 `RecursionError`。一份约 **5 KB** 的 manifest（远低于 64 MiB 上限）就能让启动带着原始 traceback 崩掉 | codex R9 [medium]；本机实测 `sys.get_int_max_str_digits() == 4300`，5007 字节的构造即触发 | 改接 `(UnicodeDecodeError, ValueError, RecursionError)`（`JSONDecodeError` 是 `ValueError` 子类）。⚠️ **这是 S2-F9 / S2-F10 的第三次**：F9 管「JSON **值**的类型」、F10 管「**磁盘对象**的类型」、本条管「**解析器本身**会抛什么」——**每一层都要问一遍「这层的失败模式我接全了吗」** |
| S2-F28 | **high** | **「`failures[].attempts` 只增不减」把 spec 自己的重试成功路径堵死了** —— §4.4:350 与 O2-F14 明写「**重试成功即把该条目移出 `failures` 并计入 `batches` 历史**」，而该守卫把「条目消失」一律判成回滚。后果：一个只是**瞬时**失败过的候选**永远回不到池子里**，池子凭空缩水，最终可能报出**假的 `FAIL_POOL_EXHAUSTED` / 达不到地板** —— 而那是要记到市场账上的结论 | codex R10 [high]；控制者查 spec 原文（§4.4:350 + O2-F14）坐实，本机复现被拒 | 改为「**移出必须自证成功**」：该股在 `pool_order` 里有锚点条目、且 `files` 里恰好两条记录（R21-F3）。⚠️ **判据**：方向②不只有「合法的增长」，还有**「合法的移除」**——我当时只为前者配了放行档 |
| S2-F29 | **high** | **单调守卫对坏输入「跳过」而不是「拒绝」** —— 它们写成 `if isinstance(旧) and isinstance(新) …`，于是**字段缺席或类型不对时守卫整条被跳过**、改写照样落盘。而 `committed_bytes` / `batches` / `inflight_rollbacks` 都是**扩展字段**，读侧校验根本不要求它们存在、兜不住。实测 5 种绕法全部通过（删字段 / 换字符串 / 换 null / 换非列表 / **等长改写 `batches`**）| codex R10 [high]，本机复现 5 档 | 改为「**上一份里有的，新的必须仍在、类型仍对、且满足转移规则**」；`batches` 另加**前缀不变**（只比长度挡不住等长改写）。⚠️⚠️ **判据（对 S3/S4/S5/4c 全部适用）**：S2-F9 那条「守卫必须对任意坏输入安全」说的是**别崩**，**不是别拦** —— 「对坏输入健壮」写成「对坏输入放行」就是把守卫送给了攻击面 |
| S2-F30 | **high** | **崩溃恢复的两半被判成了两个各自独立的许可** —— §4.4 恢复第③档是**一次耦合的转移**：删该股的 `files`/`pool_order` 条目 **且** `cursor[market] ← min(cursor, universe_idx)`。分开判时「删了条目、游标原样停在后面」照样通过 → 那只股**永远不会被重新拉取**，池子静默缩水，最终可能报出假的池穷尽 —— **正是恢复流程本来要消灭的那个状态**。另两处同族缺口：**只退游标不删条目**同样超范围；`RecoveryScope` **没核锚点**（`universe[market][idx] == stock_code`），一个错的下标能让 cursor 退到任意位置 | codex R11 [high]，本机复现 | 改判成一次耦合转移：删了 ⇒ 游标必须等于 `min(cursor, idx)`；没删 ⇒ 游标不许退；提交时核锚点（构造期核不了，`RecoveryScope` 手里没有 manifest）。方向②另配放行档：**恢复第①档**（该股从未提交、什么都不用删、游标不推进）必须照常提交。⚠️ **判据**：spec 里写成「**且**」的转移，实现里就不能拆成两条独立判据 |
| S2-F31 | medium | **per-stock 提交把调用方的校验级别原样写盘** —— 而 §4.5:785（O4-F2）**明写「per-stock 提交时这两个字段的取值必须写死」**：`source_verification: "partial"` + `source_verification_evidence: {"level": "partial", "passes": []}`。⚠️ **这不是新缺陷，是我实现时漏读了正在实现的那一节**。不写死的后果：一棵干净 staging 用 `--skip-existing-verify` 起跑，一次「只失败、没新增文件」的提交把上一次的 `full` 存根**原样写回**（它结构上仍然合法）；进程若崩在收尾之前，**磁盘上那份账本就一直声称自己是 `full` 级**，而本次运行明确跳过了校验 | codex R11 [medium]，本机复现 | `commit_stock` 无条件投影成 `partial` + 空 passes；定级留给**收尾提交**（且必须在收尾复校跑完之后）。已配方向②档：收尾提交仍要能发布真实级别 |
| S2-F32 | **high** | **用了 `--skip-existing-verify` 的运行，收尾提交照样能发布 `full`/`snapshot`** —— §4.5:342 明写「**一旦使用，manifest 与 pilot 报告都打上 `source_verification: "partial"`**」，而收尾提交只是把调用方给的级别原样写盘，**运行凭据里根本没记住这个开关**。后果：一次明确跳过了校验的运行产出一份**自称完整校验过**的账本，下游据此判出货资格 | **控制者自查**（非评审报告项）：用第⑪问追 S2-F31 的同族另一处 —— 那条管 per-stock 提交，本条管**收尾**提交；本机复现 | `RunLedger` 记住该开关（**它是这件事唯一的持久记忆**），收尾提交据此把级别投影成 `partial` + 空 passes。采取**投影**而非拒绝：spec 的措辞是「打上 partial」，且与 per-stock 提交的处置一致；跑了几小时的一轮不该在最后一步整个失败。方向②已配档：**没**用该开关时收尾仍要能发布真实级别（变异实测：一律压 partial 会红两条）|
| S2-F33 | **high** | **运行凭据本身是可变的，而它记的全是安全事实** —— 「本次跳没跳过校验」「启动时见没见过账本」「那份账本的字节指纹」。调用方一行赋值就能抹掉：改 `skip_existing_verify` → **跳过校验的运行又发布 `full`**；改 `existed` → **被删掉的账本被当成引导态凭空重建**；改 `digest` → 「被替换」检测失效。⚠️ 同族第二处：两个提交入口**不核对**传进来的是不是真凭据，任何带同名属性的对象都收 | codex R12 [high]，本机复现三档 + 鸭子类型一档 | 凭据改 `frozen=True`（`_advance` 走 `object.__setattr__`，只许本模块调用）；两个入口加 `isinstance(ledger, RunLedger)` 核对。⚠️ **判据**：**凡承载安全事实的对象，先问「调用方改得动吗」；改不动之后再问「另造一个行不行」** |
| S2-F34 | **high** | **`failures` 里两条同名记录就能绕开有界重试** —— 转移守卫按 `stock_code` 收进 dict（**后者覆盖前者**），而读侧根本不校验 `failures`（它是扩展字段）。于是 `[attempts 0, attempts 2]` 既过守卫又过读侧校验；而补拉是「**先重试 `attempts < 2` 的条目**」（§4.4:350），会命中**第一条** —— **一个已经耗尽重试的候选被复活**，反复运行还可能原地打转 | codex R12 [high]，本机复现 | 转移比较**之前**先拦同名记录（两种次序都拦）。⚠️ **判据**：**把列表按某个键归并成 dict 时，先问「同一个键出现两次会怎样」** —— 归并是有损的 |
| S2-F35 | **high** | **恢复豁免能把已提交股票的完整性基线整个换掉** —— 判「是不是完全移除」只看「files 条数 + 在不在池里」，于是把那两条记录的 `relative_path` / `bytes` / `sha256` **全换掉**仍是 `(2, True)`：既不算完全移除、也不用退游标，而文件豁免却照样放行。后果：一只**已提交**的股票被**重新绑定到不同的（甚至不存在的）文件**，原文件变无主孤儿，pilot 的 `staging_intact` 从此校验的是**被换过的基线** | codex R13 [high]，本机复现 | 豁免加**前置条件**：只在该股被判定为「完全移除」时才生效；否则它的 files / 池记录必须逐字不变。⚠️ **判据**：**「等价」的判定不能只数个数** —— 数量相同不等于内容相同 |
| S2-F36 | **high** | **`isinstance` 证明不了凭据来自启动闸** —— `frozen=True` 只挡住「改」，挡不住「**重造**」：dataclass 的构造函数是公开的，照着字段值另造一个**一模一样的真类实例**即可。本机复现两档：关掉 `skip_existing_verify` 位 → 跳过校验的运行又发布 `full`；伪造成引导态 → **被删掉的账本被凭空重建** | codex R13 [high]，本机复现 | 加**模块私有令牌**，构造期核对 —— 于是只有 `begin_run()` 造得出运行凭据。⚠️ **判据**：**「不可变」与「不可伪造」是两回事** —— 冻结之后要再问一次「能不能另造一个」 |
| S2-F37 | **high** | **运行凭据仍可伪造** —— 令牌是 dataclass 的**初始化字段**，`dataclasses.replace(real, skip_existing_verify=False)` 把它**一起复制**过去、构造期核对照过；`object.__setattr__` 也照样改得动冻结实例 | codex R14 [high]，本机复现两条绕法 | 终局做法：凭据改成**不透明句柄 + 模块内注册表** —— 句柄只是查表的钥匙（`__slots__` 为空、无公开构造路径），安全事实全部存在模块内部。⚠️ **这条走了三轮才到位**（R12 可变 → R13 冻结 → R14 仍可重造/复制）：**「把安全事实放在调用方手里的对象上」这个前提本身就是错的**，前两轮都只在修表现 |
| S2-F38 | **high** | **累计字节守卫只拦「减少」** —— **加了文件却原地不动**照样通过（本机复现：新增 246 万字节而累计值纹丝不动）。下一次运行从一个**被低估的总数**起步，**突破 `--max-bytes` 硬上限**，最坏把仅约 30 GiB 的可用空间写满 | codex R14 [high]，本机复现 | 改判为「**至少涨够新增文件的字节数**」。⚠️ **已登记的取舍**：不取严格相等 —— spec 未定 `committed_bytes` 计不计失败 `.part` 的字节（5o 只说 `--max-bytes` 是逐块扣减的流式上限），严格相等会把那种合法记账判死。**S4 定下记账口径后可收紧** |
| S2-F39 | **high** | **引导态（首次提交）整个跳过了「只看 payload」的固有检查** —— `if previous is None: return` 把「固有检查」与「新旧对比的转移检查」绑在了一起。本机复现：**首次**提交就把 `[attempts 0, attempts 2]` 两条同名记录写了进去，既复活一个已耗尽重试的候选，又让**下一次**提交因「重复」被拒 —— **这棵 staging 当场卡死** | codex R14 [high]，本机复现 | 拆成两个函数：固有检查先跑、与有没有上一份无关。⚠️ **判据**：**一个 `if` 里别绑两件事** —— 「没有上一份」只该跳过「对比」，不该跳过「这一份自己合不合法」|
| S2-F40 | **high** | **提交 = 用调用方那份整体覆盖 ⇒「省略即删除」** —— 两个提交入口都从调用方的 manifest 重建 payload，于是**省略**任何一个已持久化的顶层键就等于**静默删掉它**。这直接打破 O4-F10 的「未知顶层键原样保留」——而那条通道正是 S3/S4 的 `failures` / `batches` / `inflight_rollbacks` / `quota` 赖以流转、且**不需要 bump `manifest_version`** 的理由。它一旦漏水，「旧工具消费新版 manifest 后把不认识的字段丢掉 → 再用新工具打开时缺必需字段 → 一棵 400 只股的 staging 被一次『用错版本跑补拉』永久毁掉」就重新成立 | codex R15 [high]，本机复现（两个自定义顶层键被静默抹掉）| 两个入口都补 `_carry_forward_persisted_keys`：**磁盘上有、而这次 payload 没有的顶层键原样带过来**。⚠️ 只带**非必需键**：必需键缺了就该被读侧校验当场拒掉，替调用方补上会把它的 bug 修得看不见（已配方向②档）|
| S2-F41 | **high** | **P2-F3 有半句我从未实现** —— 原文：复校失败那一轮「**且本次不得推进 `cursor`、不得新增 `files`/`pool_order` 条目**」（否则每次重跑都继续消耗冻结宇宙与 `--max-bytes` 预算，却永远清不掉 fatal）。我只实现了「保留 fatal + 换 `stopped_reason`」那半句 | codex R15 [high]，本机复现（复校失败那一轮先提交了一只股，收尾照样接受）| 运行凭据里留一份**运行起点**的进度指纹（files / pool / cursor / committed_bytes），收尾遇到 `staging_recheck == "failed"` 时逐项比对。⚠️ 比的是**运行起点**而不是上一次提交 —— 否则本轮先提交几只股再收尾，比对就恒等成立了（已配变异档）|
| S2-F42 | **high** | **账本里一直不带 `committed_bytes` ⇒ 配额判据永久不生效** —— 增量判据只在「上一份已有合法值」时才跑，而该字段既非必需键、也无固有校验。本机复现：`files` 从 4 条涨到 6 条而它始终缺席，守卫一次都没触发 | codex R15 [high]，本机复现 | 升级为**只看 payload 的固有检查**：只要有 `files`，就必须带非负整数且 ≥ 已记录文件字节之和。⚠️ 放在固有检查里而不是转移守卫里，否则**引导态的早退会把它跳过**，而引导态正是它最该管的那一档。⚠️ **只在写侧强制**：加进读侧必需键构成「新增必需字段」，按 O2-F8 必须 bump `manifest_version` —— 超出本片范围，**交给 S4/S5** |
| S2-F43 | **high** | **P2-F3 那条判据的收口点位置错了** —— 「复校失败那一轮不得推进进度」我判在**收尾提交**，而 per-stock 提交早已**逐只落盘**。本机端到端复现：带 `staging_path_escape` 的账本起跑 → per-stock 提交照常落盘（`cursor` 1→3、`files` 4→8）→ 收尾才抛，而**抛异常收不回磁盘上的进度**；更糟的是 P2-F3 为这一轮指定的 `stopped_reason: "staging_recheck_failed"` **一次都没记上**（盘上仍是上一轮的 `staging_path_escape`），下一次重跑继续从被推进过的 cursor 消耗冻结宇宙与 `--max-bytes` | codex R16 [high]，控制者本机端到端复现 | 新增 `attest_staging_recheck(ledger, *, passed)`：**模块自己记住**本次运行的复校结论（调用方口头上报的不算凭据）。`commit_stock` 在「起跑时账本欠一次复校」且结论不是 `passed` 时**一只股都不许提交**；`commit_final` 另查「**上报的结论 == 登记的结论**」——否则登记 `failed` 挡住提交、收尾上报 `passed` 照样把 fatal 清掉，闸白立。结论**不许改口**（`failed → passed` 即洗白）。⚠️ 原 S2-F41 那条收尾进度判据**保留且仍够得着**：收尾提交自己交回来的 payload 同样会落盘（已配变异档，红 1 条）。⚠️ **对 S4/S5 的硬性要求**（本模块强制不了，与 S2-F20 同源）：账本带这类记录时，启动序列必须是 `begin_run` → 全量复校 → `attest_staging_recheck` → 才允许开拷 |
| S2-F44 | **high** | **`pool_order` 只比集合，次序不设防** —— §4.5:545 明写「`pool_order[market]` **按序追加**」，且它是「pilot 的**唯一消费顺序来源**」（P4-D8），而回滚守卫把它压成 `{(code, universe_idx)}` 集合、只查「有没有少」。本机复现两档：已提交条目被**整个倒序**、新条目**插到已提交条目之前**——成员一个没少，全部放行。后果：pilot 消费的次序被换掉，断点续跑的 `already_done` 与「池穷尽」判定双双失真，而**不改变任何身份**，**安静地**发生 | codex R16 [high]，控制者本机复现两档 | 判据改为「**上一份必须是新一份的前缀**」；崩溃恢复档先把被授权删的那一只**摘掉**再比前缀（幸存条目的相对次序照旧不许动，已配专属档：跳过恢复那一支 → 红 1 条）|
| S2-F45 | **high** | **配额下限漏掉「唯一的非股级计账对象」** —— §4.5:532（O2-F2）明写 staged `export_log.csv` 计入 `--max-bytes`，而 S2-F42 那条固有检查只加 `files[].bytes`、且挂在 `if files:` 上。两档本机复现：①**引导态**账本 `files` 为空 → 整条判据被跳过，而 export_log 在**第一份 manifest 之前**就落盘（§4.5:538），盘上已占 2399554 字节而账本记 0；②有 files 时把 export_log 那一份漏掉，同样放行。下一次运行从**被低估的总数**起步，`--max-bytes` 硬上限被突破正好一份 export_log 的量 | codex R16 [high]，控制者本机复现两档 | 下限改为 `sum(files[].bytes) + staged_export_log.bytes`，触发条件改为「有 `files` **或** 有 `staged_export_log`」。⚠️⚠️ **这一条推翻了我在 R15 那轮自己写下的正向档** `test_a_manifest_with_no_files_needs_no_committed_bytes` —— **写「方向②（合法状态不得被判死）」时同样要按字段穷尽**：我当时只看了 `files`，没问「这份账本里还有谁占着字节」。判据二从此对**正向档**也生效 |

**本轮由真跑（非推理）坐实的两条**：S2-F1 的真实目录布局（挂载实测）、以及「`rglob` 对
`front_ratio_cn_stocks_ab_bj/` 这一层零依赖」（纯 `tmp_path` 实测）；
**S2-F7 亦由真跑坐实**（六种畸形构造实测全部被放行）；**S2-F10 由 S2b 的三组真跑坐实**（目录能被打开而 `os.read` 抛原始异常 / FIFO 的 `open` 真的阻塞 / 去掉 `O_NONBLOCK` 后测试挂死 15 秒）。其余各条为逐字核原文或逐格穷举决策表。

**⚠️ S2-F5 是在 S2a 实施到 Task 4 时才被翻出来的**（2026-08-25，由任务评审的一条
「⚠️ 无法从 diff 核实：字段名是否与写侧一致」引出，控制者回 spec 追锚点时发现）。
**这说明「写侧/读侧逐字对表」这条纪律，光在评审 spec 时跑一遍是不够的**——
S2-F3 立它的时候我对着 `universe` 跑过一遍，却没对 `files` 的**条目字段**再跑一遍。
判据是：**每一个持久化结构，连同它的每一层条目，都要单独对一次表**。

**S2-F3 与 S2-F4 同属一个家族，且这是该家族第三、第四次**：一个持久化字段的
**写侧形状**与**读侧要求**、或**两个工具各自的算法**，只要没有被逐字对过表，就会产出
「谁都按规矩写、却谁也读不了对方」的死局。**九条里有五条**是对表对出来的；后四条（F6~F9）全部来自**实施与对抗性评审**，其中 F7/F9 靠拿畸形输入去撞、F8 由评审提出而经核实不采纳——
**对表本身就是最便宜的评审**。

> **但对表有个盲区，S2-F7 正落在里面**：对表擅长发现「两边说的不是一件事」（诚实产出的被判非法——**吵闹**，开跑即全红）；
> 它发现不了「一边**根本没提**这个字段」（畸形的被放行——**安静**，永远不会有人来报错）。
> 判据：**对表之外，每一份自称 fail-closed 的校验，都要再拿一批畸形输入去撞一遍**。
> 「哪些字段被校验了」要按**字段**穷尽，不能按**判据句**穷尽——判据句漏写的字段，对表看不见。
