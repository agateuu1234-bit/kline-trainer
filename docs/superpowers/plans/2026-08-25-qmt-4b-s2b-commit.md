# QMT 4b 切片 **S2b**：manifest 落盘与生命周期 —— 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 S2a 建好的 manifest 结构落到磁盘：逐段无跟随读回、**两个权限不等价的提交入口**（per-stock / 收尾），以及 `stopped_reason` / `fetch_fatal_error` 的生命周期决策表。

**⚠️ 前置：S2a 必须已合进 main。**本片从**新的 main** 切分支，**不叠 PR**（user 2026-08-25 拍板，避开「改 base 静默丢门」与「前片 squash 后必然冲突」两个已踩过的坑）。开工前先确认 `backend/qmt_manifest.py` 里已有 `validate_manifest` / `aggregate_sha256` / `LIFECYCLE_KEYS`。⚠️ **原文还写着「且 `qmt_fsroot.py` 已公开 `atomic_write_json`」——那是错的**：公开它正是本片 Task 15 的 **Step 0**（S2a 里它零使用者，故没做）。2026-08-30 实施前核实并订正。

**Architecture:** 落盘复用 S1 `qmt_fsroot` 的逐段无跟随 + 原子写 + 耐久提交（manifest 提交走 `F_FULLFSYNC`）。生命周期规则做成**纯函数决策表**；两个提交入口对它的权限**结构上不等价**——per-stock 提交在写入路径上根本够不到那三个字段。

**Tech Stack:** Python 3.11+、标准库、pytest。**零新依赖**。

**Spec:** `docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md` §4.5（含文末「S2 实施轮」的**全部** `S2-F*` 更正——写本计划时是四条，S2a 期间加到九条，S2b 期间加到十一条。**别写死条数**，写死的计数本身就是腐烂源；核对办法见验收清单 A7）。

> ⚠️ **对 S2b 有直接约束的三条**：**S2-F6**（读侧路径判据用**分量规则**而非 `resolve()`；§4.5:430 的 `.inflight.json` 形状校验仍写着 `resolve()`，那是 **S4** 范围但已预先登记——照原文实现会放行一条破坏性恢复路径删到边界之外）、**S2-F10**（读回口必须对**磁盘对象的类型**安全）、**S2-F11**（决策表里「source escape + 复校失败」那一格 spec 从未定义）。

## Global Constraints

与 S2a 逐字相同，此处不复述：见 `2026-08-25-qmt-4b-s2a-validation.md` 的「Global Constraints」一节（CI 是 Linux 且零容忍 skip、测试零外部依赖、变异必须禁字节码缓存且由控制者亲跑、写侧读侧逐字配对纪律）。

### ⚠️ 关于各步 `Expected: NNN passed` 里的数字

**绝对条数是估算，不是判据。**判据只有三条：没有 `failed`、没有 `error`、没有 `skipped`，且条数只增不减。

### ⭐ 从 S2a 继承的一条做法：**机械化全量变异 sweep**（务必沿用）

S2a 的教训：人工挑条目的「全量重跑」**漏了三条**——三条都是同一形态（一条判据交付时
有专属档，后面新加的判据把它的守护职责接管了，于是破坏原判据再也测不出来）。
整支评审用**机械化**的办法一次抓齐，控制者复跑确认。

**做法**：逐条把模块里每个 `_require*` 调用的第一个实参改成恒真值，各跑一遍测试，
记录红/绿。**变异后仍绿 = 那条判据没有任何测试在隔离地守它。**
要点：①改前用 `ast.parse` 自证语法合法（否则红的是语法错误，什么都没证明）；
②每次清 `__pycache__`（`PYTHONDONTWRITEBYTECODE=1` 也要带）；③用 `cp` 复原，**绝不 `git checkout`**。

S2a 的结果：82 条守卫、29 条无隔离覆盖——其中绝大多数是**类型/存在性守卫被邻居兜底**
（该登记而非该修），另有 3 条是已登记的等价变异/恒真断言。
**S2b 完成后请对新增判据跑同一个 sweep**，并把「仍绿」的逐条分类登记。

⚠️ **「每条判据都要有专属档」这条纪律，有时结构上做不到**（S2a 有一条经推演证明
无法隔离：要隔离它需同时满足两个互相矛盾的条件）。那时正确做法是**如实登记退化**，
**不是造一条看起来能红的假档**。

### 本片明确不做

预筛与分层洗牌（S3）、拷贝与崩溃恢复与 `--max-bytes`（S4）、七条源边界闸与命令行（S5）、`.staging.lock` 的取锁时机（S5）、`qmt_pilot` 与 `--output` 一族（4c）。

---


## 实施轮偏离登记（2026-08-30，实施者核实后逐条订正）

> **下面各 Task 的代码块是写计划时的草案，不是最终实现。**四十四处偏离全部朝
> 「坏状态不可表达」方向，每条各配专属档并由控制者亲手做过变异验证。
> 与本文件代码块 diff 不上的地方，以**仓库代码 + 本表**为准。

| # | 偏离处 | 计划原文的问题 | 处置 |
|---|---|---|---|
| D1 | Task 15 `read_manifest` 的打开方式 | 用裸 `open_under(flags=O_RDONLY)`。**实测**：manifest 被换成 FIFO 时 `open` 一直阻塞——变异后那条测试不是变红而是 15 秒被闹钟杀掉、日志 0 字节、退出码 142；被换成目录时 `os.read` 抛原始 `IsADirectoryError` | 改经 S1 的 `open_regular_probe`（`O_NONBLOCK` + `S_ISREG`）。已登记为 spec **S2-F10** |
| D2 | Task 15 的大小上限 | 只查 `st_size` 早拒，且自称「与 S1 给归属标记设上限同源」——而 S1 **恰恰明确未采纳** `st_size` 早拒（`st_size` 是打开那一刻的快照，文件可边读边长；且那道守卫钉不住，是负债不是资产） | 改为**读取过程中计数**，与 S1 逐字同规格。该档区分不了两种实现，已在测试 docstring 里如实登记 |
| D3 | Task 15 Step 0 的两个公开入口 | 只公开 `atomic_write_json` | 连同 `open_regular_probe` 一起公开（D1 的前提）；另加一条**回归钉**——`write_owner_marker` 仍不得走 `F_FULLFSYNC`，否则「默认不改行为」是空话 |
| D4 | Task 16 `commit_stock` 的 `lifecycle` 参数 | 不校验键名。`payload.update(lifecycle)` 是一条通往**任意顶层键**的走私通道（`lifecycle={"files": []}` 就能在这个自称「够不到生命周期字段」的入口里清空实拷清单）| 加 `_require_lifecycle_only` 白名单；docstring 如实登记它**挡不住**「调用方传伪造快照」（那需要每次提交回读磁盘） |
| D5 | Task 17 决策表分支次序 | 「staging 复校失败」写在 `fatal.kind` 判断**之后** → 「上次 source escape + 本次复校失败」走到 `return {}`，把 fatal 与复校失败一起丢掉 | 提到 `kind` 判断**之前**。已登记为 spec **S2-F11** |
| D6 | Task 17 对「有 fatal 却没 stopped_reason」的输入 | 用 `if prev_reason is not None:` 兜着 → 安静产出一份读侧判非法的 manifest（写侧/读侧不配对家族又一次），且那两个分支本身没有任何测试钉得住 | 当场抛 `ManifestInvalidError`，两处改为无条件回写 |
| D7 | Task 17 `FinalOutcome` | 公开 dataclass 却不校验 `kind` → `FinalOutcome(kind="whatever")` 落到「上次没 fatal → 返回 {}」，**被静默当成干净跑完** | `__post_init__` 校验 `kind` 与 `staging_recheck` |
| D8 | Task 17 `escape_stop` | 只查「非空」不查类型 → `relative_path=123` 一路通过构造与决策表、写上磁盘，到**下一次读**才被判非法 | 连类型一起在构造期校验 |
| D9 | Task 17 `max_bytes_stop` | 开了 `revisited_fatal_path` / `staging_recheck` 两个参数，而决策表对 max_bytes 这一支**根本不看它们**（O4-F1）→ 可传而被静默忽略 | 两个参数从签名里去掉，让它**不可表达** |

| D10 | Task 15 Step 0 的耐久提交 | `full_sync` 只施加在**临时文件**上，`os.replace` 之后仍只有普通 `fsync(目录)` → 断电可能丢掉那次改名，manifest 停在旧版本而按股 CSV 已是新状态（codex R1 [high]）| `full_sync=True` 时改名后改走 `full_fsync`。依据是**本机 `man 2 fcntl` 原文**：`F_FULLFSYNC`「arg is ignored」「drains the entire queue of the device and acts as a barrier」「implemented on … APFS」⇒ 它是**设备级**屏障，与 fd 指向文件还是目录无关，不是「对目录 fd 的外推」|
| D11 | Task 15 `lifecycle_snapshot` | 只拷顶层映射，`fetch_fatal_error` 仍是**同一个可变 dict**；取完快照再改它照样写进磁盘，Task 16 的核心不变量当场作废（codex R1 [high]，本机端到端复现整条洗白链）| 改深拷贝；同族一并修：决策表保留 fatal 时也不再递出输入那个对象 |
| D12 | Task 17 `FinalOutcome` | `revisited_fatal_path` 从未校验类型（`"false"` 是真值 → 无凭无据清 fatal）；`escape` 是可变 dict 塞进 frozen dataclass（构造完再改就绕过校验）；`kind` 与 `escape` 的配对从未校验（只剩决策表里一句 `assert`，`-O` 下会被剥掉）（codex R1 [high]）| 全部不变量移进 `__post_init__`（**守卫立在工厂而对象能绕过工厂构造 = 守卫不存在**），`escape` 冻成 `MappingProxyType`，`escape_stop` 退化为便利入口 |

| D13 | Task 15/16/18 的落盘路径 | `_write_manifest` **不校验就落盘** → 提交入口能写出一份自己读不回来的账本，一次 per-stock 提交就能把几百只股的 staging 变成砖头，而调用返回成功（codex R2 [high]，已登记为 spec **S2-F13**）| 落盘前先跑 `validate_manifest`，**且必须排在 `atomic_write_json` 之前**（排在之后好账本已被 replace 换掉）|
| D14 | Task 17 / 读侧生命周期 | `stopped_reason` 与 `fetch_fatal_error` 之间**没有取值级配对判据** → `reason=staging_path_escape` 配 `kind=source_path_escape` 被放行，而决策表只看 `kind` ⇒ 绕过 P2-F3 的 staging 全量复校清掉 fatal（codex R2 [high]，已登记为 spec **S2-F12**）；按判据穷尽又挖出同族两条 | 抽出 `_require_escape_pairing`，读侧与决策表共用；三条判据分别配专属档，方向②由 `staging_recheck_failed` 的正向档承担 |

| D15 | Task 17 决策表分支① | 「本次又撞 escape → 覆盖上一次的」照抄 spec，而它会**抹掉未解除的粘性信任证据**：`staging → source → 干净(未复校)` 三步就把一棵从未证明恢复过的 staging 洗成干净账本（codex R3 [high]，已登记为 spec **S2-F14**）| 覆盖改为「同级或升级才许，绝不许降级」；严格性 = 「清除它是否需要 staging 全量复校」，同时看 `kind` 与 `stopped_reason`（`staging_recheck_failed` 的 kind 可以是 source，只按 kind 判会漏）。三种安全覆盖各配放行档 |

| D16 | Task 17 清除闸 | D15 抽出的「要不要 staging 全量复校」判定**只用在了覆盖闸**，清除闸仍按 `kind` 判 → `staging_recheck_failed` 配 source kind 的状态两次运行即可无复校洗白（codex R4 [high]，已登记为 spec **S2-F15**）| 清除闸改用同一判定函数；**留机械守卫**（AST 断言该比较只许出现在那一个函数里，带防空转下限）|

| D17 | Task 17 分支次序 | 「复校失败」仍被前提①的早退挡住（次序改了三轮还没到位）（codex R5 [high]，spec **S2-F16**）| 提到前提①早退**之前**，并配把次序钉死的档 |
| D18 | Task 18 `commit_final` | 凭据取自调用方内存 → 内存被污染时会发布一份干净账本，而**它是唯一能清除证据的入口**（codex R5 [high]，spec **S2-F17**）| 先 `read_manifest` 取磁盘上的生命周期作凭据；连带把四条既有 `commit_final` 档改成**先落盘**（原本磁盘是空的，其中两条已变成恒真）|
| D19 | Task 15/16/18 落盘路径 | 只校验结构、不校验**序列化后的字节数** → 能发布一份超过读侧 64 MiB 上限的账本（codex R5 [medium]，spec **S2-F18**）| 按最终编码序列化 → 量 → 超限即拒 → 把**同一批字节**交给写入函数；新增 `encode_json` / `atomic_write_bytes` 消除序列化漂移 |

| D20 | Task 16 `commit_stock` | 「够不到三个字段」是**有条件**的（靠调用方传对快照），而伪造空快照能抹掉磁盘上的警报——**这是我在 R1 亲手登记为「已接受残留」的那条，R6 期间重核实测证明是活的洞**（spec **S2-F21**）| **拆掉 `lifecycle` 参数**：三字段一律从磁盘读、原样写回，「够不到」变成无条件；`_require_lifecycle_only` 随之成为孤儿，一并删除 |
| D21 | Task 18 `commit_final` | 凭据只信磁盘 → 「账本被删」成了新的洗白入口（codex R6 [high]，spec **S2-F19**）| 磁盘=当前真相、`begin_run()` 的快照=预期，两者不一致（含「预期非空而账本不见了」）一律 fail closed |
| D22 | 新增启动闸 | `--skip-existing-verify` 的互斥只在收尾提交才判 → 带 flag 的运行能先拷完文件再被拒（codex R6 [high]，spec **S2-F20**）| 新增 `begin_run()`；⚠️ 残留=本模块无法强制调用方先调它，已写成对 S4/S5 的硬性要求 |

| D23 | Task 16/18 共用判定 | R6 只修了 `commit_final` 的「账本被删」，而 `commit_stock` 同一轮也刚改成从磁盘取，**同样的洞照样在**（控制者自查，spec **S2-F22**）| 抽出 `_lifecycle_from_disk`，两个入口共用；`startup_lifecycle` 只当预期比对、从不写进 payload |
| D24 | `begin_run` 参数 | `skip_existing_verify` 没做 bool 校验 —— R1 那条教训没应用到**新加的**参数上（控制者自查）| 构造期拒非布尔值 |

| D25 | Task 16/18 的运行凭据 | 裸生命周期 dict 当凭据，`{}` 同时表示「没有账本」和「账本干净」→ 已建成的干净账本被删/被换都检测不出（codex R7 [high]，spec **S2-F23**）| 改为不透明的 `RunLedger`（存在位 + 字节指纹），三种异常全部 fail closed，**每次提交后更新预期** |

| D26 | Task 16/18 非生命周期内容 | 两个入口的非生命周期内容**全部**来自调用方内存 → 一份过期副本就能回滚已提交的 files / pool_order / cursor，而运行凭据管不着（spec **S2-F24**）| 加回滚守卫；⚠️**不能写成单调**（会打死 spec 自己的崩溃恢复），改为只拦**未声明**的回退，唯一正当理由由 `recovering_from_crash=True` 显式声明 |

| D27 | Task 16/18 回滚守卫 | 只看了 files/pool 身份与 cursor 方向，其余非生命周期字段（计数 / 历史 / 遥测 / 已提交文件的 bytes+sha256 / 冻结的 seed·universe·source_mount）**逐字段实测 9 项全部能被改写**（codex R9 [high]，spec **S2-F25**）| 扩为三类：冻结字段逐字不变 / 已提交 files 记录不得改写 / 单调计数只增不减 |
| D28 | Task 16 崩溃恢复 | `recovering_from_crash=True` 是**无限制旁路**，一次「恢复」能清空所有市场（codex R9 [high]，spec **S2-F26**）| 换成 `RecoveryScope(stock_code, market, universe_idx)` 范围描述符，逐项比对增量，范围外一切不变量照旧 |
| D29 | Task 15 解析器 | 只接 `JSONDecodeError` → 5 KB 的超长整数 JSON 让启动抛裸 `ValueError`（codex R9 [medium]，spec **S2-F27**）| 改接 `(UnicodeDecodeError, ValueError, RecursionError)` |

| D30 | Task 16 回滚守卫（attempts）| 「只增不减」堵死了 spec 自己的**重试成功**路径（§4.4:350 明写要移出 failures）（codex R10 [high]，spec **S2-F28**）| 改为「移出必须自证成功」（池里有锚点条目 + files 恰好两条）|
| D31 | Task 16 单调守卫 | 写成「两边类型都对才比」→ **字段缺席/类型不对时守卫被跳过**，实测 5 种绕法全通过（codex R10 [high]，spec **S2-F29**）| 改为「上一份里有的，新的必须仍在、类型仍对、满足转移规则」；batches 另加**前缀不变** |

| D32 | Task 16 崩溃恢复 | 「删条目」与「退游标」判成两条独立判据，而 spec 是**一次耦合的转移**；另漏了「只退游标」与「锚点核对」（codex R11 [high]，spec **S2-F30**）| 改判成耦合转移 + 提交时核锚点；方向②配恢复第①档放行档 |
| D33 | Task 16 校验级别 | **漏读了 §4.5:785 的明文规定**：per-stock 提交必须写死 `partial` + 空 passes（codex R11 [medium]，spec **S2-F31**）| `commit_stock` 无条件投影；定级留给收尾提交 |

| D34 | Task 18 校验级别 | R11-B 只修了 per-stock 提交；**收尾提交**同样照发调用方给的级别，而 spec §4.5:342 明写「一旦用了 `--skip-existing-verify` 就打 partial」（控制者自查，spec **S2-F32**）| `RunLedger` 记住该开关，收尾据此投影成 partial |

| D35 | Task 16/18 运行凭据 | `RunLedger` 是普通可变 dataclass，而它记的全是安全事实；两个入口还不核对类型（codex R12 [high]，spec **S2-F33**）| 改 `frozen=True` + `object.__setattr__` 内部推进；两个入口加 isinstance 核对 |
| D36 | Task 16 转移守卫 | `failures` 按 stock_code 归并成 dict，**同名两条后者覆盖前者** → 绕开有界重试（codex R12 [high]，spec **S2-F34**）| 转移比较前先拦同名记录 |

| D37 | Task 16 恢复豁免 | 「完全移除」只数条数 → 换掉路径/字节/指纹仍算没变，已提交股票被重绑到别的文件（codex R13 [high]，spec **S2-F35**）| 豁免加 `scoped_removed` 前置；否则记录必须逐字不变 |
| D38 | Task 16/18 凭据来源 | `isinstance` 挡不住「另造一个真类实例」（codex R13 [high]，spec **S2-F36**）| 加模块私有令牌，构造期核对 |

| D39 | Task 16/18 运行凭据 | 令牌是初始化字段 → `dataclasses.replace` 一起复制；`object.__setattr__` 也改得动（codex R14 [high]，spec **S2-F37**）| 改成**不透明句柄 + 模块内注册表**，安全事实不再放在调用方手里的对象上 |
| D40 | Task 16 累计字节 | 只拦减少 → 加了文件却原地不动照样过（codex R14 [high]，spec **S2-F38**）| 改判「至少涨够新增文件的字节数」；不取严格相等（spec 未定失败 .part 计不计）|
| D41 | Task 16 固有检查 | 引导态早退把「只看 payload 的检查」一起跳过了（codex R14 [high]，spec **S2-F39**）| 拆成独立函数，先于早退执行 |

| D42 | Task 16/18 提交语义 | 「用调用方那份整体覆盖」⇒ **省略即删除**，打破 O4-F10 的未知顶层键通道（codex R15 [high]，spec **S2-F40**）| 两个入口补 carry-forward（只带非必需键）|
| D43 | Task 17/18 复校失败 | **P2-F3 有半句从未实现**：那一轮不得推进 cursor / 新增 files·pool（codex R15 [high]，spec **S2-F41**）| 凭据里留运行起点进度指纹，收尾逐项比对 |
| D44 | Task 16 配额判据 | 账本一直不带 `committed_bytes` → 判据永久不生效（codex R15 [high]，spec **S2-F42**）| 升级为固有检查：有 files 就必须带非负整数且 ≥ 文件字节之和 |
| D45 | Task 17/18 复校闸 | **P2-F3 的收口点位置错了**：判在收尾，而 per-stock 提交早已逐只落盘、抛异常收不回（codex R16 [high]，spec **S2-F43**）| 新增 `attest_staging_recheck`：复校未通过时**一只股都不许提交**；收尾另查「上报 == 登记」；结论不许改口。⚠️ S2-F41 那条收尾判据保留（收尾 payload 仍够得着）|
| D46 | Task 16 池顺序 | `pool_order` 只比**集合** → 重排 / 插队全放行（codex R16 [high]，spec **S2-F44**）| 改判「上一份必须是新一份的**前缀**」；恢复档先摘掉被授权删的那一只再比 |
| D47 | Task 16 配额下限 | 漏掉 staged `export_log.csv`（spec 明定的**唯一非股级计账对象**），且触发条件 `if files:` 把引导态整个跳过（codex R16 [high]，spec **S2-F45**）| 下限 = `files` 之和 **+** export_log；触发条件含引导态。⚠️ 顺带**推翻**了 R15 自己写的那条正向档 |
| D48 | Task 17/18 一致性检查 | R16 那条「上报 == 登记」写成**无条件相等**，把 `max_bytes_stop()` / `escape_stop()` 两个合法结局全挡了（Opus [high]，spec **S2-F46**）| 只在 `kind == "clean"` 那一支强制相等；另加「登记 failed 只许发具名结局」；「非 clean 不得携带 `staging_recheck`」下沉到 `__post_init__` |
| D49 | Task 17 attest 入口 | 账本上没有那类记录时，登记「复校失败」被**静默丢弃**（Opus [medium]，spec **S2-F47**）| **拒绝登记**（只写 reason 是假安全，造 fatal 是凭空捏造）；运行级失败交 S4/S5 |
| D50 | Task 17 启动闸 | `--skip-existing-verify` 互斥**窄于 spec 原文**，`source_path_escape` 被放行且同轮清掉 fatal（Opus [medium]，spec **S2-F48**）| 判据改为「`fetch_fatal_error` 在不在」|
| D51 | Task 16 测试判别力 | S2-F45 的新下限把两条累计字节老攻击档抬到门槛以下 ⇒ 两条守卫**零红**（Opus [medium]，spec **S2-F49**）| 两档抬到下限之上 + 断言改判据专属措辞。⚠️ 收紧判据后要重跑邻居档的变异 |
| D52 | Task 16 AST 守卫 | 守卫只扫 `comparators` 且只认一个字面量，三种绕法查不出（Opus [low]，spec **S2-F50**）| 扫 `left`+`comparators`、展开 Tuple/List/Set、补第二个字面量；两个诱饵档坐实 |
| D53 | Task 17/18 复校闸 | 闸只立在 per-stock 入口，收尾入口照收推进过的 payload（Opus-2 [medium]，spec **S2-F51**）| 闸从「入口」改成「进度」，涵盖并合并旧判据；凭据加 `owes_staging_recheck` |
| D54 | Task 17 进度指纹 | 四个分量只有 `files` 被钉住（Opus-2 [low]，spec **S2-F52**）| 补两条单分量推进档 |
| D55 | Task 15 耐久性 | `F_FULLFSYNC` 文件内容那半被目录那半掩盖（Opus-2 [low]，spec **S2-F53**）| 断言 `os.fsync` 零次 + `replace` 两侧各有屏障 |
| D56 | Task 15/16 正则 | `_STOCK_CODE_RE` 的 `\Z` 没人守；**补档第一版还是假的**（Opus-2 [low]，spec **S2-F54**）| 走 `RecoveryScope` + 断言判据专属措辞 |
| D57 | Task 15 探测器 | socket 型对象让「先 open 后查 S_ISREG」整个失效，四个调用点全抛裸 `OSError`（Opus-3 [medium]，spec **S2-F56**）| 修在共用探测器：打不开就回头 `lstat`；新异常继承 `OSError` 故 S1 三个调用点行为不变 |
| D58 | Task 18 收尾剥键 | 剥生命周期三键那步没人守，注入方向可写伪造 fatal（Opus-3 [low]，spec **S2-F57**）| 补对称的注入档 |
| D59 | Task 17 进度指纹 | `files`/`pool_order` 互相掩盖（Opus-3 [low]，spec **S2-F58**）| 端到端造不出隔离 → 直接对纯函数下四档参数化断言 |
| D60 | Task 16/17 小守卫 | 三条守卫零覆盖（Opus-3 [low]，spec **S2-F59**）| 各补专属档 |
| D61 | Task 16/17 转移守卫 | 不可哈希的 JSON 值让四处守卫抛裸 `TypeError`（Kimi K1 [medium]，spec **S2-F60**）| ①`failures[].stock_code` 先验类型；②`_hashable()` 让四处守卫总算得出键。⚠️ 补档时自查发现「不同坏值要不同键」那半没人守，另补两条纯函数档 |
| D62 | Task 15 写侧上限 | 那条档的后半段其实钉的是**读侧**（Kimi K1 [low]，spec **S2-F61**）| 换一棵空 staging（引导态读侧无从插手）+ 断言写侧专属措辞「拒绝发布」|
| D63 | Task 18 注释 | 注释引用改名前的 `_lifecycle_from_disk`（Kimi K1 [low]，spec **S2-F62**）| 改为 `_expect_from_disk` |

**另有一处测试判别力订正**：Task 18 那条「内存预置 `stopped_reason`」的档判别力不够
（决策表会把同一个值塞回去，剥不剥都绿），改成预置一条**陈旧的 `stopped_reason_secondary`**
并断言它必须被剥掉——变异实测：不剥时三条档一起变红。

**收尾机械化 sweep 的结果**（R16 后跑过一次，Opus 那轮修完**又跑了一次**，两次与 R16 之前那棵树三者数字全同、仍绿名单逐条相同）：**91 个 `_require*` 判据、74 条变红、
9 条仍绿、8 条无法构造恒真实参**。
⭐ **在 R16 之前的那棵树上（`c145db1`，模块与测试都取 HEAD 版）单独又跑了一遍**：
同样是 91 / 74 / 9，**仍绿名单逐条完全相同** ⇒ R16 的三条修复没有新增任何无覆盖判据。
⭐ **9 条仍绿全部做了机械归因**（不是凭印象分类）：对每条单独施加同一个恒真变异，
再喂一份**只违反它**的 manifest —— **9 条全部仍被拒**，且拒它的都是一条**具名的
另一条判据**（`staged_export_log.sha256` 格式 / 后缀不符 / 池内重复 / 文件名解析对不上 /
`stopped_reason` 配对 / 聚合值对不上 …）⇒ **全部是邻居兜底、造不出专属档**，
零条「不明原因仍绿」、零条「真没人守」。
⚠️ R16 新增的三条判据都**不是** `_require*` 调用，sweep 覆盖不到 ——
它们由 **15 组定向变异**单独证明（见下方 R16 那一行，零红为 0）。首轮 12 条仍绿里那 4 条**真的没人守**的已补上专属档
（缺 `source_snapshot.universe`、`fetch_fatal_error` 的 `relative_path`/`component` 为空串、
存根 `completed_at` 为空串）。
⚠️ 984 组合那条整族扫描探不到它们，因为它只断言「若抛异常则必须是本模块的族」、
**不断言「必须抛」**，且只做「替换值」从不做「删键」。

---

## Task 15: S1 小改（另一半）+ `read_manifest` —— 逐段无跟随读回并校验

> **⚠️ 本任务比 S2a 的原版多一个前置步骤（2026-08-25 pre-flight 裁决）**：
> S1 的 `_atomic_write_json` 是**私有**的、且文件内容走普通 `fsync`，而 manifest
> 提交按 O4-F11 定案要走 `F_FULLFSYNC`。这半边小改原本排在 S2a 的 Task 1，
> 但它在 S2a 里**零使用者**（落盘在本片），故移到这里。
>
> **前置 Step 0：公开 `atomic_write_json` 并加 `full_sync` 开关**
>
> `backend/qmt_fsroot.py`：
>
> ```python
> # ① __all__ 里，"耐久提交" 那一组改为：
>     # 耐久提交
>     "fsync_dir", "full_fsync", "atomic_write_json",
> ```
>
> ```python
> # ② _atomic_write_json 加参数（签名 + 文件 fsync 那一处）：
> def _atomic_write_json(dir_fd: int, name: str, payload: dict, *,
>                        full_sync: bool = False) -> None:
>     """（……原有 docstring 全部保留……）
>
>     `full_sync=True` 时，文件内容改用 `full_fsync()`（macOS 上即
>     `fcntl(fd, F_FULLFSYNC)`）——**manifest 提交专用**（O4-F11 定案：断电在
>     威胁模型之内，而本平台的 `fsync(2)` man page 明写它既不保证断电耐久、
>     也不保证跨设备写序）。**默认 `False`**：归属标记等其余落地点保留 `fsync`，
>     行为不变。目录项一律走 `fsync_dir`（`F_FULLFSYNC` 对目录 fd 的语义未经
>     实测，不外推）。
>     """
>     ...
>         try:
>             _write_all(fd, json.dumps(payload, ensure_ascii=False).encode("utf-8"))
>             if full_sync:
>                 full_fsync(fd)
>             else:
>                 os.fsync(fd)
>         finally:
>             os.close(fd)
>     ...
>
>
> def atomic_write_json(dir_fd: int, name: str, payload: dict, *,
>                       full_sync: bool = False) -> None:
>     """公开入口，语义同 `_atomic_write_json`。manifest 提交走它并传
>     `full_sync=True`；模块内部（归属标记）继续走私有名与默认刷盘。
>     """
>     _atomic_write_json(dir_fd, name, payload, full_sync=full_sync)
> ```
>
> 配套测试（追加到 `backend/tests/test_qmt_fsroot.py`）：`full_sync=True` 必须真的
> 走 `F_FULLFSYNC`；`full_sync=False` **不得**走；`F_FULLFSYNC` 不存在的平台
> （Linux CI）不得抛 `AttributeError`；**外加一条回归钉**——`write_owner_marker`
> 仍然**不**走 `F_FULLFSYNC`（否则「默认不改行为」这句话就是空的）。
> 三条 spy 档的写法与本片 Task 16 的 `..._uses_full_fsync` 相同，注意
> `test_qmt_manifest.py` 顶部需要 `import fcntl`（S2a 未引入它，本片补）。

### `read_manifest` 本体

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Consumes: `qmt_fsroot.open_root` / `open_under`（S1）、Task 5–14 的 `validate_manifest`
- Produces: `read_manifest(stg_fd: int) -> dict | None`、`lifecycle_snapshot(manifest: dict) -> dict`

**为什么返回 `None` 而不是抛**：manifest 不存在是**引导态**（崩在标记落盘与首份 manifest 之间），spec 明写它「允许从头继续初始化」（R60-F3）。把「不存在」与「坏了」混成一个异常，会让引导态这一档**无法与畸形区分**。

**⚠️ 本片新增一条 spec 没写的安全上限**：`_MANIFEST_MAX_BYTES = 64 MiB`。manifest 是**不可信输入**（staging 可能被人动过），读到 EOF 为止意味着一个被植入的几 GB 文件能把进程 OOM 掉，而不是得到一个干净的 `ManifestInvalidError`。这与 S1 给归属标记设 `_MARKER_MAX_BYTES` 是同一条判据；64 MiB 宽松到不可能误伤（5608 只股的完整 universe + 800 条 files 实测量级约 0.5 MB）。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

import json as _json_rw

from qmt_fsroot import open_root, PathEscapeError
from qmt_manifest import read_manifest, lifecycle_snapshot, MANIFEST_NAME


def _staging(tmp_path, manifest=None, *, raw=None):
    """造一个 staging 目录并返回 (path, stg_fd)。调用方负责 os.close。"""
    d = tmp_path / "staging"
    d.mkdir()
    if raw is not None:
        (d / MANIFEST_NAME).write_text(raw, encoding="utf-8")
    elif manifest is not None:
        (d / MANIFEST_NAME).write_text(
            _json_rw.dumps(manifest, ensure_ascii=False), encoding="utf-8")
    return d, open_root(str(d))


def test_read_manifest_round_trips_a_valid_one(tmp_path):
    """正向放行档。"""
    m = _valid_manifest()
    _d, fd = _staging(tmp_path, m)
    try:
        assert read_manifest(fd) == m
    finally:
        os.close(fd)


def test_read_manifest_returns_none_when_absent(tmp_path):
    """⭐ 引导态：manifest 不存在 ≠ manifest 坏了。

    判别力：把「不存在」也抛成 ManifestInvalidError，本条必红——而那会让
    「崩在标记落盘与首份 manifest 之间」这一档无法与畸形区分，
    一棵本可继续初始化的 staging 变成人工才能清理的状态（R60-F3）。
    """
    _d, fd = _staging(tmp_path)
    try:
        assert read_manifest(fd) is None
    finally:
        os.close(fd)


def test_read_manifest_rejects_truncated_json(tmp_path):
    """⭐ 截断的 manifest 往往仍是合法 JSON 的**前缀片段**。

    静默消费它 = 把 manifest 损坏伪装成「候选就这么多」（R1-F4）。
    """
    good = _json_rw.dumps(_valid_manifest(), ensure_ascii=False)
    _d, fd = _staging(tmp_path, raw=good[: len(good) // 2])
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_empty_file(tmp_path):
    _d, fd = _staging(tmp_path, raw="")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_a_json_array(tmp_path):
    """合法 JSON 但不是对象。"""
    _d, fd = _staging(tmp_path, raw="[1,2,3]")
    try:
        with pytest.raises(ManifestInvalidError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_rejects_oversized_file(tmp_path, monkeypatch):
    """⭐ 不可信输入的大小上限（本片新增，非 spec 条款）：manifest 决定
    整棵 staging 可不可信，读到 EOF 为止意味着一个被植入的几 GB 文件能把
    进程 OOM 掉，而不是得到一个干净的拒绝。

    判别力：删掉上限检查，本条必红（会读进去并报 JSON 错或直接通过）。
    """
    import qmt_manifest as qm
    monkeypatch.setattr(qm, "_MANIFEST_MAX_BYTES", 100)
    _d, fd = _staging(tmp_path, _valid_manifest())      # 远超 100 字节
    try:
        with pytest.raises(ManifestInvalidError) as ei:
            read_manifest(fd)
        assert "过大" in str(ei.value)
    finally:
        os.close(fd)


def test_read_manifest_lets_path_escape_bubble_up(tmp_path):
    """⭐ manifest 被换成指向 staging 之外的符号链接 → `open_under` 逐段
    `O_NOFOLLOW` 撞 ELOOP → **PathEscapeError 原样上浮**，不被降级成
    「manifest 畸形」。

    判别力：把 open_under 的异常 catch 成 ManifestInvalidError，本条必红——
    而那会把一次**信任边界破坏**报成「账本坏了」，恢复指引整个走错
    （R94-F2 同族：一个合规的写者产出的 manifest 被读者判成畸形）。
    处置（stopped_reason: staging_path_escape + rc≠0）由 S4/S5 负责。
    """
    outside = tmp_path / "outside.json"
    outside.write_text(_json_rw.dumps(_valid_manifest(), ensure_ascii=False),
                       encoding="utf-8")
    d = tmp_path / "staging"
    d.mkdir()
    (d / MANIFEST_NAME).symlink_to(outside)
    fd = open_root(str(d))
    try:
        with pytest.raises(PathEscapeError):
            read_manifest(fd)
    finally:
        os.close(fd)


def test_read_manifest_propagates_version_error_not_invalid(tmp_path):
    """版本三档必须原样穿过 read_manifest（两族异常不许在这一层被抹平）。"""
    _d, fd = _staging(tmp_path, _valid_manifest(manifest_version=99))
    try:
        with pytest.raises(ManifestVersionError) as ei:
            read_manifest(fd)
        assert ei.value.kind == "newer"
    finally:
        os.close(fd)


def test_lifecycle_snapshot_captures_only_the_three_keys():
    m = _valid_manifest(stopped_reason="staging_path_escape",
                        fetch_fatal_error=_fatal(),
                        stopped_reason_secondary="max_bytes")
    snap = lifecycle_snapshot(m)
    assert set(snap) == {"stopped_reason", "fetch_fatal_error",
                         "stopped_reason_secondary"}


def test_lifecycle_snapshot_of_a_clean_manifest_is_empty():
    assert lifecycle_snapshot(_valid_manifest()) == {}
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "read_manifest or lifecycle_snapshot" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'read_manifest'`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部补 import
import os
from qmt_fsroot import atomic_write_json, open_under


# 常量区补：
# manifest 是**不可信输入**（它决定整棵 staging 可不可信），故读入有上限。
# **本片新增，非 spec 条款**——与 S1 给归属标记设 `_MARKER_MAX_BYTES` 同一条
# 判据：读到 EOF 为止意味着一个被植入的几 GB 文件能把进程 OOM 掉，而不是得到
# 一个干净的 `ManifestInvalidError`。64 MiB 宽松到不可能误伤：5608 只股的完整
# universe + 800 条 files 实测量级约 0.5 MB。
_MANIFEST_MAX_BYTES = 64 * 1024 * 1024


# 追加到 backend/qmt_manifest.py

def lifecycle_snapshot(manifest: dict) -> dict:
    """捕获生命周期三字段的当前值，供 per-stock 提交逐字回写。

    **这是 per-stock 提交够不到那三个字段的实现手段**（R95-F2 + §9-3s
    「使规则可机械检验」）：`commit_stock` 把 manifest 里的同名键一律剥掉，
    再把本快照塞回去——**调用方即使污染了内存里的 manifest，也写不进磁盘**。
    """
    return {k: manifest[k] for k in LIFECYCLE_KEYS if k in manifest}


def read_manifest(stg_fd: int) -> dict | None:
    """相对 `stg_fd` **逐段无跟随**读回 manifest 并过全套读侧校验。

    返回校验通过的 manifest；**文件不存在返回 `None`**（引导态——崩在归属标记
    落盘与首份 manifest 之间，spec 明写它允许从头继续初始化，R60-F3）。
    把「不存在」与「坏了」混成一个异常，会让引导态这一档无法与畸形区分。

    抛：
    - `ManifestInvalidError` —— 空文件 / 截断 / 不是 JSON 对象 / 超过大小上限 /
      任一读侧判据不过；
    - `ManifestVersionError` —— 版本三档（**不在本层抹平成 Invalid**）；
    - `PathEscapeError` —— manifest 这一段或其父分量被换成符号链接
      （`open_under` 逐段 `O_NOFOLLOW` 撞 `ELOOP` / `ENOTDIR`）。
      **原样上浮，不降级成「manifest 畸形」**：那是一次**信任边界破坏**，
      处置是 `stopped_reason: staging_path_escape` + 顶层 `fetch_fatal_error`
      + rc≠0（S4/S5 负责），报成「账本坏了」会让恢复指引整个走错。
    """
    try:
        fd = open_under(stg_fd, MANIFEST_NAME, flags=os.O_RDONLY)
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if st.st_size > _MANIFEST_MAX_BYTES:
            raise ManifestInvalidError(
                f"{MANIFEST_NAME} 过大（{st.st_size} 字节，上限 "
                f"{_MANIFEST_MAX_BYTES}）——它决定整棵 staging 可不可信，"
                "拒绝把一个来路不明的巨型文件读进内存"
            )
        chunks: list[bytes] = []
        while True:
            block = os.read(fd, 1 << 20)
            if not block:
                break
            chunks.append(block)
    finally:
        os.close(fd)

    data = b"".join(chunks)
    if not data:
        raise ManifestInvalidError(f"{MANIFEST_NAME} 是空文件")
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        raise ManifestInvalidError(
            f"{MANIFEST_NAME} 不是合法 JSON：{e}。"
            "这通常意味着上一次写入被打断（文件被截断）。"
        ) from e
    return validate_manifest(payload)
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 134 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M47 | `except FileNotFoundError: return None` → `raise ManifestInvalidError(...)` | `..._returns_none_when_absent` |
| M48 | 删掉 `st.st_size > _MANIFEST_MAX_BYTES` 那条 | `..._rejects_oversized_file` |
| M49 | 把 `open_under(...)` 换成 `os.open(MANIFEST_NAME, os.O_RDONLY, dir_fd=stg_fd)` | `..._lets_path_escape_bubble_up` |
| M50 | 在 `validate_manifest(payload)` 外包一层 `except Exception: raise ManifestInvalidError` | `..._propagates_version_error_not_invalid` |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): read_manifest —— 逐段无跟随读回并校验

不存在返回 None 而不是抛：manifest 不存在是引导态（崩在标记落盘与首份
manifest 之间，R60-F3 明写允许从头继续初始化）。混成一个异常会让引导态
无法与畸形区分。

PathEscapeError 原样上浮，不降级成「manifest 畸形」：那是信任边界破坏，
报成「账本坏了」会让恢复指引整个走错。版本三档同样不在这一层被抹平。

新增一条 spec 没写的安全上限（64 MiB）：manifest 是不可信输入，读到 EOF
为止意味着被植入的几 GB 文件能把进程 OOM 掉。与 S1 给归属标记设上限同源。"
```

---

## Task 16: `commit_stock` —— per-stock 提交**够不到**生命周期三字段

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Produces: `commit_stock(stg_fd: int, manifest: dict, *, lifecycle: dict) -> dict`

**为什么这条必须是结构性的而不是纪律性的**：spec §9-3s 明写「**per-stock 提交一律不动这两个字段**，**使规则可机械检验**」。靠「实施者记得别改」是纪律；把 `lifecycle` 做成**必需参数**、并在写入前把 manifest 里的同名键**剥掉**，才是结构——调用方即使污染了内存里的 manifest，也写不进磁盘。

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import commit_stock


def test_commit_stock_writes_a_readable_manifest(tmp_path):
    """正向放行档：写出去的必须读得回来。"""
    m = _valid_manifest()
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, lifecycle={})
        assert read_manifest(fd) == m
    finally:
        os.close(fd)


def test_commit_stock_cannot_change_lifecycle_fields(tmp_path):
    """⭐⭐ 核心不变量：即使调用方**故意**改了内存里的三个字段，
    磁盘上写出去的仍是 lifecycle 快照里的值。

    判别力：把实现写成 `atomic_write_json(fd, NAME, manifest)`（直接写入参），
    本条必红。这就是 §9-3s 说的「使规则可机械检验」——
    不是靠实施者记得别改。
    """
    prev = {"stopped_reason": "staging_path_escape",
            "fetch_fatal_error": _fatal()}
    poisoned = _valid_manifest(**prev)
    snap = lifecycle_snapshot(poisoned)

    # 调用方「不小心」把 fatal 洗掉了
    del poisoned["fetch_fatal_error"]
    poisoned["stopped_reason"] = "max_bytes"

    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, poisoned, lifecycle=snap)
        on_disk = read_manifest(fd)
        assert on_disk["stopped_reason"] == "staging_path_escape"
        assert on_disk["fetch_fatal_error"] == _fatal()
    finally:
        os.close(fd)


def test_commit_stock_cannot_invent_lifecycle_fields(tmp_path):
    """反向档：一份**干净的** manifest，调用方硬塞一个 stopped_reason
    进去 —— 磁盘上必须仍然干净。

    没有这一条，「只在 lifecycle 有值时覆盖」的实现也能让上一条绿。
    """
    poisoned = _valid_manifest(stopped_reason="max_bytes")
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, poisoned, lifecycle={})       # 启动时磁盘上是干净的
        assert "stopped_reason" not in read_manifest(fd)
    finally:
        os.close(fd)


def test_commit_stock_preserves_unknown_top_level_keys(tmp_path):
    """S3/S4 的 failures / batches 等经 per-stock 提交流转，不得被剥掉。"""
    m = _valid_manifest(failures=[{"stock_code": "600004.SH", "attempts": 1}],
                        committed_bytes=123)
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, m, lifecycle={})
        on_disk = read_manifest(fd)
        assert on_disk["failures"] == [{"stock_code": "600004.SH", "attempts": 1}]
        assert on_disk["committed_bytes"] == 123
    finally:
        os.close(fd)


def test_commit_stock_uses_full_fsync(tmp_path, monkeypatch):
    """manifest 提交按 O4-F11 定案走 F_FULLFSYNC（断电在威胁模型之内）。

    判别力：把 full_sync=True 去掉，本条必红。
    """
    if not hasattr(fcntl, "F_FULLFSYNC"):
        return
    calls = []
    real = fcntl.fcntl
    monkeypatch.setattr(fcntl, "fcntl",
                        lambda fd, cmd, *a: (calls.append(cmd), real(fd, cmd, *a))[1])
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), lifecycle={})
    finally:
        os.close(fd)
    assert fcntl.F_FULLFSYNC in calls


def test_commit_stock_is_atomic_leaving_no_tmp_files(tmp_path):
    """走 tmp → replace，落地后目录里不得有残留临时文件。"""
    d, fd = _staging(tmp_path)
    try:
        commit_stock(fd, _valid_manifest(), lifecycle={})
    finally:
        os.close(fd)
    assert sorted(p.name for p in d.iterdir()) == [MANIFEST_NAME]
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k commit_stock 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'commit_stock'`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py

def _write_manifest(stg_fd: int, payload: dict) -> None:
    """manifest 的唯一落盘路径：tmp → `fsync(文件)` → `os.replace` →
    `fsync(目录)`，且文件内容走 **`F_FULLFSYNC`**（O4-F11 定案：断电在威胁
    模型之内，而本平台的 `fsync(2)` man page 明写它既不保证断电耐久、
    也不保证跨设备写序）。

    ⚠️ **绝不就地截断重写**——「原子」（`os.replace` 不会看到半截）与「耐久」
    （崩溃后仍在）是两件事，两者都要（R45-F2）。
    """
    atomic_write_json(stg_fd, MANIFEST_NAME, payload, full_sync=True)


def commit_stock(stg_fd: int, manifest: dict, *, lifecycle: dict) -> dict:
    """**per-stock 提交**（每只股一次，R37-F1）。返回真正写出去的那份。

    ⚠️⚠️ **本函数在写入路径上够不到生命周期三字段**：manifest 里的
    `stopped_reason` / `stopped_reason_secondary` / `fetch_fatal_error`
    一律被**剥掉**，再把 `lifecycle`（启动时从磁盘捕获的快照）逐字塞回去。
    调用方即使污染了内存里的 manifest，也写不进磁盘。

    这不是纪律而是结构：spec §9-3s 要求「per-stock 提交一律不动这两个字段，
    **使规则可机械检验**」。靠「实施者记得别改」的实现无法被机械检验，
    而这两个字段是 pilot 的 fail-closed 判据——被 per-stock 提交洗掉一次，
    一棵**已被证明动过**的 staging 就会拿到干净标签。
    """
    payload = {k: v for k, v in manifest.items() if k not in LIFECYCLE_KEYS}
    payload.update(lifecycle)
    _write_manifest(stg_fd, payload)
    return payload
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 140 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M51 | 整个函数体换成 `_write_manifest(stg_fd, manifest); return manifest` | `..._cannot_change_lifecycle_fields` + `..._cannot_invent_lifecycle_fields` |
| M52 | 只做 `payload.update(lifecycle)`、不先剥 | `..._cannot_invent_lifecycle_fields`（lifecycle 为空时剥不掉） |
| M53 | `full_sync=True` → `False` | `..._uses_full_fsync` |

> M52 是「两条判据互相掩盖」的反面教材：**剥**与**塞**是两个动作，只做后者时
> 「洗掉」那档仍绿（快照非空会覆盖回去），只有「凭空塞」那档会红。**两档缺一不可。**

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): commit_stock —— per-stock 提交在写入路径上够不到生命周期三字段

spec §9-3s 要求「per-stock 提交一律不动这两个字段，使规则可机械检验」。
靠「实施者记得别改」是纪律，无法被机械检验；把 lifecycle 做成必需参数、
写入前把 manifest 里的同名键剥掉再塞回快照，才是结构——调用方即使污染了
内存里的 manifest 也写不进磁盘。

「剥」与「塞」是两个动作，各配一档（洗掉 / 凭空塞），缺一会互相掩盖。

manifest 提交走 F_FULLFSYNC（O4-F11：断电在威胁模型之内）。"
```

---

## Task 17: 收尾生命周期决策表（纯函数）

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Produces: `FinalOutcome`（frozen dataclass）、`clean_finish()` / `max_bytes_stop()` / `escape_stop()` 三个工厂、`resolve_final_lifecycle(manifest: dict, outcome: FinalOutcome) -> dict`、`SkipVerifyWithEscapeError`

**为什么这条规则反直觉、且两种朴素做法都错（R95-F2）**：
- **就地合并式更新**：操作者修好树、重跑成功，陈旧 fatal 仍在 → **pilot 永远拒绝启动**；
- **启动即清除**：重试崩在中途便**抹掉唯一的持久证据** → 下一次看到的是一份**看起来干净、实则来自被污染源树**的 staging。

**规则**：启动不清；**只在「收尾提交」那一次原子提交里**写入本次值并删除 `fetch_fatal_error`；崩在此前则旧记录保留（安全侧）。

**⚠️ 清除的谓词不是「本次没撞 escape」，而是「已证明受影响的路径确实干净」（O2-F7）**：反例——上次因 `staging_path_escape` 终止（manifest 已记 56 只股），操作者删掉被换的分量重建，重跑时新股走**新建目录**全部成功、收尾复校只对**源**重算 sha256（**从不回读 staging 里那 56 只股**）→「本次没撞 escape」成立 → 清除 → **manifest 声称拥有的 56 只股在 staging 里已不存在，而唯一记录「这棵树被动过」的持久证据没了**。

**⚠️ `max_bytes` 绝不许洗白 escape（O4-F1）**：Run1 撞 `staging_path_escape`（已记 56 只股）→ pilot fail-closed ✅ → 操作者修好重跑 → Run2 拉几只就触到 `--max-bytes`（**累计字节含 Run1，触顶几乎必然**）→ 若把 `stopped_reason` 改写成 `max_bytes`，**pilot 读到就放行**，那 56 只从未被复校过的股照常消费——**一次被证明破坏的信任边界被一次容量停止洗白成合法凭据**。

| 本次运行 | 上次留的 fatal | 结果 |
|---|---|---|
| 撞了 escape | 任意 | `stopped_reason` = 本次 escape；`fetch_fatal_error` = 本次四字段（覆盖）；清掉 secondary |
| 干净跑完 | 无 | 删掉 `stopped_reason`；无 fatal |
| `max_bytes` 触顶 | 无 | `stopped_reason` = `max_bytes` |
| `max_bytes` 触顶 | **有** | **fatal 原样保留、escape 的 `stopped_reason` 不得被覆盖**；另记 `stopped_reason_secondary: "max_bytes"` |
| 干净跑完 | 有，但**没重走过**那条路径 | **原样保留**（前提①不满足） |
| 干净跑完 | 有 `source_path_escape`，**已重走过** | **清除** fatal 与 `stopped_reason` |
| 干净跑完 | 有 `staging_path_escape`，已重走过，全量复校 **通过** | **清除** |
| 干净跑完 | 有 `staging_path_escape`，已重走过，全量复校 **失败** | 保留 fatal；`stopped_reason` = `staging_recheck_failed` |
| 干净跑完 | 有 `staging_path_escape`，已重走过，**跳过了复校** | **拒绝**（P2-F3：`--skip-existing-verify` 与带 escape 记录的 manifest 互斥） |

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import (
    FinalOutcome, clean_finish, max_bytes_stop, escape_stop,
    resolve_final_lifecycle, SkipVerifyWithEscapeError,
)


def _prev(fatal=None, reason=None, secondary=None):
    m = _valid_manifest()
    if reason is not None:
        m["stopped_reason"] = reason
    if fatal is not None:
        m["fetch_fatal_error"] = fatal
    if secondary is not None:
        m["stopped_reason_secondary"] = secondary
    return m


# ── 上次没有 fatal ────────────────────────────────────────────
def test_clean_finish_on_a_clean_manifest_clears_stopped_reason():
    assert resolve_final_lifecycle(_prev(), clean_finish()) == {}


def test_max_bytes_on_a_clean_manifest_records_max_bytes():
    assert resolve_final_lifecycle(_prev(), max_bytes_stop()) == {
        "stopped_reason": "max_bytes"}


def test_clean_finish_drops_a_stale_max_bytes_reason():
    """上次是干净的容量停止，这次跑完了 → 那条 stopped_reason 该消失。"""
    assert resolve_final_lifecycle(_prev(reason="max_bytes"), clean_finish()) == {}


# ── 本次撞 escape ─────────────────────────────────────────────
def test_escape_stop_overwrites_everything():
    out = escape_stop(kind="source_path_escape",
                      relative_path="1分钟K线_前复权/x.csv",
                      component="1分钟K线_前复权", errno="ENOTDIR")
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape", secondary="max_bytes"), out)
    assert got == {
        "stopped_reason": "source_path_escape",
        "fetch_fatal_error": {"kind": "source_path_escape",
                              "relative_path": "1分钟K线_前复权/x.csv",
                              "component": "1分钟K线_前复权", "errno": "ENOTDIR"},
    }
    assert "stopped_reason_secondary" not in got


# ── ⭐⭐ max_bytes 绝不洗白 escape（O4-F1）────────────────────
def test_max_bytes_never_launders_a_retained_escape():
    """⭐⭐ 本片最危险的一档：Run1 撞 escape，Run2 触顶。

    若把 stopped_reason 改写成 max_bytes，pilot 读到就放行，那 56 只从未被
    复校过的股照常消费——一次被证明破坏的信任边界被一次容量停止洗白成
    合法凭据。

    判别力：把实现写成「max_bytes 一律覆盖 stopped_reason」，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"), max_bytes_stop())
    assert got["stopped_reason"] == "staging_path_escape"      # 未被覆盖
    assert got["fetch_fatal_error"] == _fatal()                # 原样保留
    assert got["stopped_reason_secondary"] == "max_bytes"      # 只作诊断附注


# ── ⭐ 清除的谓词是「证明干净」而非「本次没撞」（O2-F7）───────
def test_clean_finish_without_revisiting_the_fatal_path_keeps_the_fatal():
    """⭐ 反例场景：上次 staging_path_escape 记了 56 只股，操作者重建目录，
    本次新股走**新建目录**全部成功、收尾复校只对**源**重算——
    从不回读那 56 只股。「本次没撞 escape」成立，但什么都没被证明干净。

    判别力：把清除条件写成「本次没撞 escape」，本条必红。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=False))
    assert got["fetch_fatal_error"] == _fatal()
    assert got["stopped_reason"] == "staging_path_escape"


def test_source_escape_clears_after_revisiting_that_path():
    """source_path_escape 只要前提①（重走过那条路径）——
    前提②（staging 全量复校）是 staging_path_escape **另加**的。"""
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
        clean_finish(revisited_fatal_path=True))
    assert got == {}


def test_staging_escape_clears_only_after_a_passing_full_recheck():
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="passed"))
    assert got == {}


def test_staging_escape_with_failing_recheck_keeps_fatal_and_renames_reason():
    """⭐ P2-F3：此前完全未定义 → 不可解 staging。
    保留 fatal、覆盖 stopped_reason 为 staging_recheck_failed。

    ⭐ 这一档也是 `kind` 与 `stopped_reason` **必须解耦**的唯一理由
    （O4-F3）：kind 仍是 staging_path_escape，reason 已换成 recheck_failed。
    """
    got = resolve_final_lifecycle(
        _prev(fatal=_fatal(), reason="staging_path_escape"),
        clean_finish(revisited_fatal_path=True, staging_recheck="failed"))
    assert got["fetch_fatal_error"] == _fatal()
    assert got["fetch_fatal_error"]["kind"] == "staging_path_escape"
    assert got["stopped_reason"] == "staging_recheck_failed"


def test_skipping_the_recheck_on_a_staging_escape_manifest_is_refused():
    """⭐ P2-F3：--skip-existing-verify 与「manifest 带 escape 记录」互斥。

    不拒的话：第 1 次带 flag 跑清掉 fatal、标 partial（看似安全），
    第 2 次不带 flag 跑时收尾复校**只重算源、从不回读 staging** →
    **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 full 标签**。

    判别力：把这一档实现成「当作 passed 清除」或「当作没重走过保留」，
    本条必红——前者是那条出货级假凭据，后者会让 fatal 永远清不掉。
    """
    with pytest.raises(SkipVerifyWithEscapeError):
        resolve_final_lifecycle(
            _prev(fatal=_fatal(), reason="staging_path_escape"),
            clean_finish(revisited_fatal_path=True, staging_recheck=None))


# ── 构造期就排除非法组合 ──────────────────────────────────────
def test_escape_stop_rejects_a_kind_outside_the_enum():
    for bad in ("staging_recheck_failed", "max_bytes", ""):
        with pytest.raises(ValueError):
            escape_stop(kind=bad, relative_path="x", component="c", errno="ELOOP")


def test_escape_stop_rejects_an_errno_outside_the_enum():
    with pytest.raises(ValueError):
        escape_stop(kind="staging_path_escape", relative_path="x",
                    component="c", errno="EACCES")


def test_clean_finish_rejects_an_unknown_recheck_verdict():
    for bad in ("ok", "PASSED", True):
        with pytest.raises(ValueError):
            clean_finish(revisited_fatal_path=True, staging_recheck=bad)


def test_every_resolved_state_passes_the_read_side_validator():
    """⭐⭐ 写侧/读侧配对钉：决策表吐出的**每一种**状态，塞回 manifest 后
    都必须能过读侧校验。

    这是 R94-F2 / O4-F13 / S2-F3 / S2-F4 那个家族（写侧形状与读侧要求不配对）
    的**机械防线**：任何一支的输出若读侧不认，一个合规的写者就会产出被自己
    判非法的 manifest。
    """
    cases = [
        (_prev(), clean_finish()),
        (_prev(), max_bytes_stop()),
        (_prev(fatal=_fatal(), reason="staging_path_escape"), max_bytes_stop()),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=False)),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="passed")),
        (_prev(fatal=_fatal(), reason="staging_path_escape"),
         clean_finish(revisited_fatal_path=True, staging_recheck="failed")),
        (_prev(fatal=_fatal(kind="source_path_escape"), reason="source_path_escape"),
         clean_finish(revisited_fatal_path=True)),
        (_prev(), escape_stop(kind="staging_path_escape", relative_path="a/b.csv",
                              component="a", errno="ELOOP")),
    ]
    for prev, outcome in cases:
        new_lc = resolve_final_lifecycle(prev, outcome)
        merged = {k: v for k, v in prev.items() if k not in LIFECYCLE_KEYS}
        merged.update(new_lc)
        assert validate_manifest(merged) is merged
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "resolve_final or escape_stop or clean_finish or max_bytes_never or every_resolved" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'FinalOutcome'`

- [ ] **Step 3: 最小实现**

```python
# backend/qmt_manifest.py 顶部补 import
from dataclasses import dataclass


# 追加到 backend/qmt_manifest.py

class SkipVerifyWithEscapeError(Exception):
    """`--skip-existing-verify` 撞上「manifest 带 escape 记录」——拒绝启动（P2-F3）。

    **不拒的具体后果**：第 1 次带 flag 跑清掉 fatal、标 `partial`（看似安全），
    第 2 次不带 flag 跑时收尾复校**只重算「源」、从不回读 staging** →
    **一棵被证明动过、且从未被复校过的 staging 拿到了出货级 `full` 标签**。
    """


@dataclass(frozen=True)
class FinalOutcome:
    """本次运行的**收尾事件**。用三个工厂函数构造，非法组合在构造期就被排除。

    - `kind`：`clean`（正常跑完）/ `max_bytes`（干净的配额触顶）/ `escape`（撞了逃逸）
    - `escape`：`kind == "escape"` 时的四字段
    - `revisited_fatal_path`：本次是否**重新遍历过**上次 fatal 所指的那条路径（前提①）
    - `staging_recheck`：`staging_path_escape` 另加的全量复校结果（前提②），
      `"passed"` / `"failed"` / `None`（未做）
    """
    kind: str
    escape: dict | None = None
    revisited_fatal_path: bool = False
    staging_recheck: str | None = None


def clean_finish(*, revisited_fatal_path: bool = False,
                 staging_recheck: str | None = None) -> FinalOutcome:
    """本次正常跑完整批。"""
    if staging_recheck not in (None, "passed", "failed"):
        raise ValueError(
            f"staging_recheck 只能是 None/'passed'/'failed'，收到 {staging_recheck!r}")
    return FinalOutcome(kind="clean", revisited_fatal_path=revisited_fatal_path,
                        staging_recheck=staging_recheck)


def max_bytes_stop(*, revisited_fatal_path: bool = False,
                   staging_recheck: str | None = None) -> FinalOutcome:
    """干净的 `--max-bytes` 触顶（R44-F2：**终止条件，不是这只股的失败**）。"""
    if staging_recheck not in (None, "passed", "failed"):
        raise ValueError(
            f"staging_recheck 只能是 None/'passed'/'failed'，收到 {staging_recheck!r}")
    return FinalOutcome(kind="max_bytes", revisited_fatal_path=revisited_fatal_path,
                        staging_recheck=staging_recheck)


def escape_stop(*, kind: str, relative_path: str, component: str,
                errno: str) -> FinalOutcome:
    """本次撞了逃逸（源树或 staging 树的路径分量被换）。"""
    if kind not in FATAL_KINDS:
        raise ValueError(f"kind 必须是 {sorted(FATAL_KINDS)} 之一，收到 {kind!r}")
    if errno not in FATAL_ERRNOS:
        raise ValueError(f"errno 必须是 {sorted(FATAL_ERRNOS)} 之一，收到 {errno!r}")
    if not relative_path or not component:
        raise ValueError("relative_path 与 component 都必须非空")
    return FinalOutcome(kind="escape", escape={
        "kind": kind, "relative_path": relative_path,
        "component": component, "errno": errno,
    })


def resolve_final_lifecycle(manifest: dict, outcome: FinalOutcome) -> dict:
    """**收尾提交**时三个生命周期字段的完整新值（纯函数；缺席的键表示该字段应被删除）。

    ⚠️ **两种朴素做法都错**（R95-F2）：**就地合并式更新**会让操作者修好树、
    重跑成功之后，陈旧 fatal 永远留着、**pilot 永远拒绝启动**；**启动即清除**
    则会在「重试崩在中途」时**抹掉唯一的持久证据**，下一次看到的是一份
    看起来干净、实则来自被污染源树的 staging。把清除与「本次已干净收尾」绑进
    **同一次原子提交**，两种坏结局都不可表达。

    ⚠️ **清除的谓词不是「本次没撞 escape」，而是「已证明受影响的路径确实干净」**
    （O2-F7）：上次 `staging_path_escape` 记了 56 只股，操作者重建目录后重跑，
    新股走**新建目录**全部成功、收尾复校只对**源**重算 sha256（从不回读那 56 只股）
    ——「本次没撞」成立，而什么都没被证明干净。

    ⚠️ **`max_bytes` 绝不许洗白 escape**（O4-F1）：Run2 的累计字节含 Run1，
    触顶几乎必然；把 `stopped_reason` 改写成 `max_bytes` 会让 pilot 放行那批
    从未被复校过的股——**一次被证明破坏的信任边界被一次容量停止洗白成合法凭据**。
    """
    prev_fatal = manifest.get("fetch_fatal_error")
    prev_reason = manifest.get("stopped_reason")

    # ① 本次撞了 escape → 覆盖为本次的（secondary 清掉）
    if outcome.kind == "escape":
        assert outcome.escape is not None
        return {"stopped_reason": outcome.escape["kind"],
                "fetch_fatal_error": dict(outcome.escape)}

    # ② 上次没有 fatal → 只写本次的停止原因
    if prev_fatal is None:
        return {"stopped_reason": "max_bytes"} if outcome.kind == "max_bytes" else {}

    # ③ 上次有 fatal，本次是 max_bytes 触顶 → 一律保留，只加诊断附注。
    #    前提① 对它**不可能满足**（事前 stat 早拒不遍历任何路径），故不看 outcome
    #    里的两个前提字段。
    if outcome.kind == "max_bytes":
        kept = {"fetch_fatal_error": prev_fatal, "stopped_reason_secondary": "max_bytes"}
        if prev_reason is not None:
            kept["stopped_reason"] = prev_reason
        return kept

    # ④ 上次有 fatal，本次干净跑完 —— 清除与否取决于「有没有证明干净」
    if not outcome.revisited_fatal_path:
        kept = {"fetch_fatal_error": prev_fatal}
        if prev_reason is not None:
            kept["stopped_reason"] = prev_reason
        return kept

    if prev_fatal["kind"] == "staging_path_escape":
        # 前提②（无条件，不受任何 flag 影响，P2-F3）
        if outcome.staging_recheck is None:
            raise SkipVerifyWithEscapeError(
                "这棵 staging 的 manifest 里带着 staging_path_escape 记录，"
                "而本次跳过了既有文件复校。两者互斥：跳过复校就无法证明那些"
                "已记录的文件还在、还是原来的字节。请去掉 --skip-existing-verify "
                "重跑，或换新 staging + 新 seed 重拉。"
            )
        if outcome.staging_recheck == "failed":
            # ⭐ kind 与 stopped_reason 解耦的唯一理由（O4-F3）
            return {"fetch_fatal_error": prev_fatal,
                    "stopped_reason": "staging_recheck_failed"}

    # 已证明干净 → 清除（source_path_escape 只需前提①）
    return {}
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 154 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M54 | 分支③ 改成 `return {"stopped_reason": "max_bytes", "fetch_fatal_error": prev_fatal}` | `..._never_launders_a_retained_escape` |
| M55 | 分支③ 改成 `return {}`（把 max_bytes 当清除） | `..._never_launders_a_retained_escape` |
| M56 | `if not outcome.revisited_fatal_path:` → `if False:` | `..._without_revisiting_the_fatal_path_keeps_the_fatal` |
| M57 | `if outcome.staging_recheck is None: raise` → `pass` | `..._skipping_the_recheck_..._is_refused` |
| M58 | `staging_recheck == "failed"` 那支删掉 | `..._with_failing_recheck_keeps_fatal_and_renames_reason` |
| M59 | 分支④ 的 `prev_fatal["kind"] == "staging_path_escape"` → `True`（source 也要复校） | `..._source_escape_clears_after_revisiting_that_path` |
| M60 | 分支① 改成 `return {"fetch_fatal_error": dict(outcome.escape)}`（漏 stopped_reason） | `test_every_resolved_state_passes_the_read_side_validator` ← 配对钉抓到 |

- [ ] **Step 6: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): 收尾生命周期决策表（R95-F2 + O2-F7 + O4-F1 + P2-F3 + O4-F3）

两种朴素做法都错：就地合并式更新让陈旧 fatal 永远留着、pilot 永远拒绝启动；
启动即清除则在重试崩中途时抹掉唯一的持久证据。把清除与「本次已干净收尾」
绑进同一次原子提交，两种坏结局都不可表达。

⭐ 清除的谓词是「已证明受影响的路径确实干净」而非「本次没撞 escape」（O2-F7）：
重跑时新股走新建目录全部成功、收尾复校只重算源——什么都没被证明干净。

⭐⭐ max_bytes 绝不洗白 escape（O4-F1）：Run2 的累计字节含 Run1，触顶几乎
必然；覆盖 stopped_reason 会让 pilot 放行那批从未被复校过的股。

⭐ --skip-existing-verify 与带 escape 记录的 manifest 互斥（P2-F3），
不拒的话第一次带 flag 跑就能清掉 fatal，第二次拿到出货级 full 标签。

立了一条写侧/读侧配对钉：决策表吐出的每一种状态塞回 manifest 都必须过读侧
校验——这是 R94-F2/O4-F13/S2-F3/S2-F4 那个家族的机械防线。"
```

---

## Task 18: `commit_final` —— 唯一能动生命周期字段的落盘入口

**Files:**
- Modify: `backend/qmt_manifest.py`
- Test: `backend/tests/test_qmt_manifest.py`

**Interfaces:**
- Produces: `commit_final(stg_fd: int, manifest: dict, *, outcome: FinalOutcome) -> dict`

- [ ] **Step 1: 写失败的测试**

```python
# 追加到 backend/tests/test_qmt_manifest.py

from qmt_manifest import commit_final


def test_commit_final_writes_a_readable_manifest(tmp_path):
    """正向放行档。"""
    d, fd = _staging(tmp_path)
    try:
        written = commit_final(fd, _valid_manifest(), outcome=clean_finish())
        assert read_manifest(fd) == written
    finally:
        os.close(fd)


def test_commit_final_clears_the_fatal_when_proven_clean(tmp_path):
    """⭐ 与 commit_stock 的权限差：收尾提交**能**清除。"""
    m = _valid_manifest(fetch_fatal_error=_fatal(kind="source_path_escape"),
                        stopped_reason="source_path_escape")
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, m, outcome=clean_finish(revisited_fatal_path=True))
        on_disk = read_manifest(fd)
        assert "fetch_fatal_error" not in on_disk
        assert "stopped_reason" not in on_disk
    finally:
        os.close(fd)


def test_commit_final_keeps_the_fatal_when_not_proven(tmp_path):
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, m, outcome=clean_finish(revisited_fatal_path=False))
        on_disk = read_manifest(fd)
        assert on_disk["fetch_fatal_error"] == _fatal()
        assert on_disk["stopped_reason"] == "staging_path_escape"
    finally:
        os.close(fd)


def test_commit_final_ignores_lifecycle_fields_already_in_the_passed_manifest(tmp_path):
    """⭐ 与 commit_stock 同源的结构性保证：写出去的三个字段**只能**来自
    决策表，绝不来自调用方内存里那份 manifest 的直接赋值。

    这里内存里写着 max_bytes、磁盘上应当出现的却是「保留 escape」——
    因为决策表看的是 manifest 里**上一次**的 fatal，而不是调用方现在写的
    stopped_reason。

    判别力：把实现写成 `payload.update(...)` 而不先剥 LIFECYCLE_KEYS，
    本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    m["stopped_reason"] = "staging_path_escape"
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, m, outcome=max_bytes_stop())
        on_disk = read_manifest(fd)
        assert on_disk["stopped_reason"] == "staging_path_escape"
        assert on_disk["stopped_reason_secondary"] == "max_bytes"
    finally:
        os.close(fd)


def test_commit_final_uses_full_fsync(tmp_path, monkeypatch):
    if not hasattr(fcntl, "F_FULLFSYNC"):
        return
    calls = []
    real = fcntl.fcntl
    monkeypatch.setattr(fcntl, "fcntl",
                        lambda fd, cmd, *a: (calls.append(cmd), real(fd, cmd, *a))[1])
    d, fd = _staging(tmp_path)
    try:
        commit_final(fd, _valid_manifest(), outcome=clean_finish())
    finally:
        os.close(fd)
    assert fcntl.F_FULLFSYNC in calls


def test_commit_final_refuses_skip_verify_with_escape_and_writes_nothing(tmp_path):
    """⭐ P2-F3 的落盘侧：拒绝时**一个字节都不写**。

    判别力：把 resolve 的调用放在写入之后，本条必红。
    """
    m = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    d, fd = _staging(tmp_path)
    try:
        with pytest.raises(SkipVerifyWithEscapeError):
            commit_final(fd, m, outcome=clean_finish(revisited_fatal_path=True))
        assert not (d / MANIFEST_NAME).exists()
    finally:
        os.close(fd)


def test_full_round_trip_stock_commits_then_final(tmp_path):
    """⭐⭐ 端到端不变量：一次带着 escape 记录的运行里，
    **任意多次 per-stock 提交都动不了 fatal，只有收尾那一次能**。
    """
    start = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason="staging_path_escape")
    snap = lifecycle_snapshot(start)
    d, fd = _staging(tmp_path)
    try:
        for _ in range(3):                       # 三次 per-stock 提交
            commit_stock(fd, start, lifecycle=snap)
            assert read_manifest(fd)["fetch_fatal_error"] == _fatal()
        commit_final(fd, start,
                     outcome=clean_finish(revisited_fatal_path=True,
                                          staging_recheck="passed"))
        assert "fetch_fatal_error" not in read_manifest(fd)
    finally:
        os.close(fd)
```

- [ ] **Step 2: 跑测试确认它红**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q -k "commit_final or full_round_trip" 2>&1 | tail -10
```

Expected: FAIL —— `ImportError: cannot import name 'commit_final'`

- [ ] **Step 3: 最小实现**

```python
# 追加到 backend/qmt_manifest.py

def commit_final(stg_fd: int, manifest: dict, *, outcome: FinalOutcome) -> dict:
    """**收尾提交** —— 全流程中**唯一**能写入或清除生命周期三字段的入口
    （R95-F2）。返回真正写出去的那份。

    与 `commit_stock` 的差别不在「记不记得改」，而在**能不能改**：
    per-stock 提交把那三个键剥掉再回填启动快照，本函数把它们剥掉再回填
    **决策表的输出**。两者都不从调用方内存里那份 manifest 直接取值。

    ⚠️ **`resolve_final_lifecycle` 必须在任何写入之前求值**：它可能抛
    `SkipVerifyWithEscapeError`（P2-F3），而那一档的规定是「拒绝启动、
    一个字节都不写」。
    """
    new_lifecycle = resolve_final_lifecycle(manifest, outcome)   # ← 可能抛，必须在写之前
    payload = {k: v for k, v in manifest.items() if k not in LIFECYCLE_KEYS}
    payload.update(new_lifecycle)
    _write_manifest(stg_fd, payload)
    return payload
```

- [ ] **Step 4: 跑测试确认它绿**

```bash
cd backend && PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/test_qmt_manifest.py -q 2>&1 | tail -5
```

Expected: 约 161 passed（数字是估算，**判据是没有 failed / error / skipped**）

- [ ] **Step 5: 变异验证（控制者亲跑）**

| # | 变异 | 必红的测试 |
|---|---|---|
| M61 | 把 `resolve_final_lifecycle(...)` 挪到 `_write_manifest` 之后 | `..._refuses_skip_verify_..._writes_nothing` |
| M62 | 不剥 `LIFECYCLE_KEYS`，直接 `payload = dict(manifest)` 再 update | `..._ignores_lifecycle_fields_already_in_the_passed_manifest` |
| M63 | `commit_final` 内部改调 `commit_stock` | `..._clears_the_fatal_when_proven_clean` |

- [ ] **Step 6: 跑全量 + 两条 CI 复刻闸**

```bash
cd backend
find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null

# ① 复刻 CI 的 no-skip 闸
PYTHONDONTWRITEBYTECODE=1 python -m pytest tests/ -q --junitxml=/tmp/s2-final.xml 2>&1 | tail -5
python - <<'PY'
import xml.etree.ElementTree as ET
r = ET.parse("/tmp/s2-final.xml").getroot()
n = lambda k: sum(int(s.get(k, 0)) for s in r.iter("testsuite"))
print(f"tests={n('tests')} skipped={n('skipped')} failures={n('failures')} errors={n('errors')}")
assert n("skipped") == 0 and n("failures") == 0 and n("errors") == 0, "CI no-skip 闸不过"
print("CI no-skip 闸 PASS")
PY

# ② 模拟 Linux：抹掉 macOS 专属常量再跑全量
mkdir -p /tmp/nofs && cat > /tmp/nofs/nofullfsync.py <<'PY'
import fcntl
def pytest_configure(config):
    if hasattr(fcntl, "F_FULLFSYNC"):
        del fcntl.F_FULLFSYNC
PY
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=/tmp/nofs python -m pytest tests/ -q -p nofullfsync 2>&1 | tail -5
```

Expected: 两条都全绿，且 `skipped == 0`

- [ ] **Step 7: 提交**

```bash
git add backend/qmt_manifest.py backend/tests/test_qmt_manifest.py
git commit -m "feat(4b-S2): commit_final —— 唯一能动生命周期三字段的落盘入口

与 commit_stock 的差别不在「记不记得改」而在「能不能改」：两者都把三个键
剥掉再回填，per-stock 填启动快照、收尾填决策表输出，都不从调用方内存里
那份 manifest 直接取值。

resolve 必须在任何写入之前求值：P2-F3 那一档要抛，而它的规定是「拒绝启动、
一个字节都不写」。

端到端不变量钉：一次带着 escape 记录的运行里，任意多次 per-stock 提交都
动不了 fatal，只有收尾那一次能。"
```

---

# 验收清单（非程序员可自行执行）

> 三段式：**动作 / 期望 / 通过判定**。每条一行命令，**不要整块粘贴**。
> 环境：Python 解释器在**主仓**的 `.venv` 里，worktree 里没有。先执行这一条把它记下来：
>
> ```
> export PY="/Users/maziming/Coding/Prj_Kline trainer/.venv/bin/python"
> ```
>
> ⚠️ **后面每次用它都写成 `"$PY"`（带双引号）**。这个路径里有一个空格，
> 不加引号会被终端拆成两半，报 `/Users/maziming/Coding/Prj_Kline: No such file or directory`。
> 本清单初稿五处全是裸 `$PY`，2026-08-30 真跑时当场报错，已逐处修正。
>
> 再进 worktree 的 backend 目录：
>
> ```
> cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-4b-s2b/backend"
> ```

### A1 · 确认你在对的地方

**动作**

```
git branch --show-current && git rev-parse --short HEAD && pwd
```

**期望**：三行依次是 `feat/qmt-4b-s2b-commit`、一个 7 位提交号、以 `.dev/worktree/qmt-4b-s2b/backend` 结尾的路径。

**通过判定**：分支名完全一致 → 通过；不一致 → 不通过（说明开了别的窗口或切错分支，**先别继续**）。

---

### A2 · 全部测试通过，且一条都没被跳过

> 「跳过」= 测试没真跑，只是被标成「不算数」。本仓的自动检查把**任何跳过**都判失败，
> 因为在开发者的 Mac 上跳过的那条，正是在服务器（Linux）上会出问题的那条。

**动作**

```
"$PY" -m pytest tests/ -q --junitxml=/tmp/s2-accept.xml
```

**期望**：最后一行形如 `NNN passed in XX.XXs`，**没有** `failed`、**没有** `skipped`、**没有** `error`。

**通过判定**：出现 `passed`、且**没有** `failed` / `skipped` / `error` 字样 → 通过。

> 数字本身只作参考：**本片开工前在 `origin/main` (`1437529`) 上实测的基线是 1106**（写本计划时写的 937 是 S2a 之前的旧数，已作废）。做完后应当明显更多。
> 若数字**比 1106 还少**，说明有测试没被收集到——那是不通过，请把完整输出贴出来。

---

### A3 · 用机器再数一遍跳过的条数（不看结论字样，看执行量）

> 为什么要多这一步：终端最后一行是**结论**，而结论字样可能与真实执行量不符。
> 本仓栽过「显示 `TEST SUCCEEDED` 而实际跑了 0 个测试」。这一步直接数**数字**。

**动作**

```
"$PY" -c "import xml.etree.ElementTree as E;r=E.parse('/tmp/s2-accept.xml').getroot();f=lambda k:sum(int(s.get(k,0)) for s in r.iter('testsuite'));print('总数',f('tests'),'跳过',f('skipped'),'失败',f('failures'),'错误',f('errors'))"
```

**期望**：`跳过 0 失败 0 错误 0`，且`总数`与 A2 的数字一致。

**通过判定**：三个 0 全中且总数一致 → 通过；任一不为 0 → 不通过。

---

### A4 · 模拟服务器环境（Linux）再跑一遍

> 本片用到一个**只有 Mac 才有**的「更用力刷硬盘」的功能。服务器上没有它。
> 这一步把那个功能藏起来，看代码会不会崩。**上一片（S1）就是栽在这里**：
> 本地 932 个测试全过，服务器上 2 个失败 + 1 个跳过。

**动作**（三行，逐行执行）

```
mkdir -p /tmp/nofs
```

```
printf 'import fcntl\ndef pytest_configure(config):\n    if hasattr(fcntl, "F_FULLFSYNC"):\n        del fcntl.F_FULLFSYNC\n        print("[nofullfsync] 已抹掉 F_FULLFSYNC")\n' > /tmp/nofs/nofullfsync.py
```

```
PYTHONPATH=/tmp/nofs "$PY" -m pytest tests/ -q -p nofullfsync
```

> ⚠️ 输出里**必须**出现一行 `[nofullfsync] 已抹掉 F_FULLFSYNC`。
> 没有它就说明那个「藏起来」的动作根本没发生，这一步等于没做
> ——本仓的 A3 存在的理由就是「看执行量，不看结论字样」，这里同理。
> （另：`-p` 指向一个不存在的插件时 pytest 会**硬报 `ImportError`**、
> 不会静默跳过，所以命令能跑完本身也是加载成功的旁证。两条都实测过。）

**期望**：与 A2 相同的通过数，**没有** `failed` / `skipped` / `error`。

**通过判定**：通过数与 A2 一致且无其它字样 → 通过。数字变小 → 不通过（说明有测试在服务器上跑不了）。

---

### A5 · 亲眼看一份「坏账本」被挡住、一份「好账本」被放行

> 这一步是本片的**本质**：账本坏了必须当场拒绝，而不是「尽力读一读」。
> 「尽力读一读」的后果是把**账本损坏**伪装成「候选股票就这么少」，
> 最后产出一份**会撒谎的报告**。

**动作**

```
"$PY" -c "
import sys; sys.path.insert(0,'tests')
from test_qmt_manifest import _valid_manifest, _recompute_evidence
from qmt_manifest import validate_manifest, ManifestInvalidError, ManifestVersionError
m = _valid_manifest(); validate_manifest(m); print('① 好账本：放行 ✅')
b = _valid_manifest(); del b['seed']
try: validate_manifest(b); print('② 缺字段：没拦住 ❌')
except ManifestInvalidError as e: print('② 缺字段：拦住了 ✅ ——', str(e)[:40])
c = _valid_manifest(); c['files'][0]['relative_path']='../跑到外面.csv'; _recompute_evidence(c)
try: validate_manifest(c); print('③ 路径跑到外面：没拦住 ❌')
except ManifestInvalidError as e: print('③ 路径跑到外面：拦住了 ✅ ——', str(e)[:40])
d = _valid_manifest(manifest_version=99)
try: validate_manifest(d); print('④ 版本更高：没拦住 ❌')
except ManifestVersionError as e: print('④ 版本更高：拦住了 ✅ ——', e.guidance[:40])
"
```

**期望**：四行，全部以 `✅` 结尾；第 ④ 行的提示里出现「更新版本」字样（**不是**「账本坏了」）。

**通过判定**：四个 ✅ 全中 → 通过。任一出现 ❌ → 不通过。

> 第 ④ 行为什么重要：一棵已经拉了几百只股票（约 2 GB）的目录，如果「版本对不上」
> 和「账本坏了」报同一句话，你根本不知道该重新拉一遍还是该换个版本的工具。

---

### A6 · 亲眼看「容量停止」洗不白「安全警报」

> 这是本片最要紧的一条规则。场景：第一次拉取时发现目录被人动过手脚（安全警报，
> 下游会拒绝使用这批数据）；你修好后重跑，结果因为磁盘配额满了而停下。
> **那条安全警报绝不能因此消失。**——否则「被动过手脚」会被一次「磁盘满了」洗成合法。

**动作**

```
"$PY" -c "
import sys; sys.path.insert(0,'tests')
from test_qmt_manifest import _valid_manifest, _fatal
from qmt_manifest import resolve_final_lifecycle, max_bytes_stop, clean_finish
prev = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason='staging_path_escape')
r = resolve_final_lifecycle(prev, max_bytes_stop())
print('① 安全警报还在吗：', '✅ 在' if r.get('fetch_fatal_error') else '❌ 被洗掉了')
print('② 停止原因被改写了吗：', '✅ 没有（仍是 staging_path_escape）' if r['stopped_reason']=='staging_path_escape' else '❌ 被改写成 '+str(r['stopped_reason']))
print('③ 容量停止有没有单独记下：', '✅ 有' if r.get('stopped_reason_secondary')=='max_bytes' else '❌ 没有')
r2 = resolve_final_lifecycle(prev, clean_finish(revisited_fatal_path=False))
print('④ 没重走过出事的路就想清警报：', '✅ 清不掉' if r2.get('fetch_fatal_error') else '❌ 被清掉了')
r3 = resolve_final_lifecycle(prev, clean_finish(revisited_fatal_path=True, staging_recheck='passed'))
print('⑤ 真的重走过且全量复查通过：', '✅ 警报解除' if not r3.get('fetch_fatal_error') else '❌ 还清不掉')
"
```

**期望**：五行全部以 `✅` 开头的判定。

**通过判定**：五个 ✅ 全中 → 通过。

---

### A7 · 确认 spec 的更正都真的写进去了

> ⚠️ 路径是 `../docs/`（**两个点**）。本清单初稿写成了 `../../../docs/`，
> 那会退到仓库外面去，跑出来是 `No such file` —— 已实测并修正。
>
> ⚠️ 判据**不写死条数**：写死的计数本身就是腐烂源，以后每加一条更正都得回来改它。
> 下面两条命令**互相印证**，所以不用记住今天是几条。

**动作**（两行，逐行执行）

```
grep -o 'S2-F[0-9]\+' ../docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md | sort -u -V
```

```
grep -c '^| S2-F' ../docs/superpowers/specs/2026-07-27-qmt-plan4b-fetch-design.md
```

**期望**：第一条输出一串**从 `S2-F1` 开始、连号不跳**的编号（条数每次评审都会增长，**不要去记具体到几**——两条命令互相印证就够了）；
第二条输出的数字**等于第一条的行数**。

**通过判定**：编号连号不跳、且两条数字相等 → 通过。任一不满足 → 不通过。

> ⚠️ 注意 `S2-F[0-9]\+` 的 `\+`：S2a 版写的是 `S2-F[0-9]`（只匹配一位数），
> 到 `S2-F10` 就会把它截成 `S2-F1`、造成「看起来连号其实少了一条」的假绿。

---

### A8 · 亲眼看「欠一次全量复查的目录」推不动进度

> 场景：上一次拉取时发现目录被人动过（安全警报）。你修好后重跑。
> 规矩是：**必须先把整棵目录重新核对一遍（全量复查），核对通过之前，一只股票都不许提交。**
> 不然每次重跑都会继续消耗「冻结的股票名单」和磁盘配额，而那条警报永远解除不掉
> ——白白烧掉几个小时和几个 GB，最后还是解不开。
>
> ⚠️ 这条闸此前**只装在其中一个入口上**，另一个入口照收（评审两轮先后挖出），
> 所以这里**两个入口各测一次**。

**动作**

```
"$PY" -c "
import os, sys, tempfile; sys.path.insert(0,'tests')
from test_qmt_manifest import _valid_manifest, _fatal, _with_more_stocks
from qmt_fsroot import open_root, atomic_write_json
from qmt_manifest import (MANIFEST_NAME, begin_run, commit_stock, commit_final,
                          attest_staging_recheck, clean_finish, read_manifest,
                          ManifestInvalidError)
d = os.path.join(os.path.realpath(tempfile.mkdtemp()), 'staging'); os.mkdir(d)
fd = open_root(d)
warned = _valid_manifest(fetch_fatal_error=_fatal(), stopped_reason='staging_path_escape')
atomic_write_json(fd, MANIFEST_NAME, warned)
grown = _with_more_stocks(warned)
led = begin_run(fd)
try: commit_stock(fd, grown, ledger=led); print('① 没复查就提交股票：没拦住 ❌')
except ManifestInvalidError: print('① 没复查就提交股票：拦住了 ✅')
try: commit_final(fd, grown, ledger=led, outcome=clean_finish()); print('② 没复查就想收尾推进：没拦住 ❌')
except ManifestInvalidError: print('② 没复查就想收尾推进：拦住了 ✅')
attest_staging_recheck(led, passed=False)
try: commit_stock(fd, grown, ledger=led); print('③ 复查没通过还想提交：没拦住 ❌')
except ManifestInvalidError: print('③ 复查没通过还想提交：拦住了 ✅')
led2 = begin_run(fd); attest_staging_recheck(led2, passed=True)
commit_stock(fd, grown, ledger=led2)
print('④ 复查通过后继续拉：放行 ✅，文件记录', len(read_manifest(fd)['files']), '条')
"
```

**期望**：四行，①②③ 都是「拦住了 ✅」，④ 是「放行 ✅，文件记录 6 条」。

**通过判定**：四行全部带 ✅ → 通过。
④ 那行**必须是放行**——只会拦不会放的闸等于把修好的目录永久锁死，同样是不通过。

---

### A9 · 亲眼看「账本被换成一个假东西」被挡住

> 账本文件本身被换成**不是普通文件的东西**（比如一个通信管道、一个目录、
> 一个 socket），说明这棵目录已经被动过。工具必须当场拒绝并给出恢复指引，
> 而**不是**吐一堆看不懂的报错。
>
> ⚠️ socket 这一档此前是**漏的**：程序打不开它就直接崩了，根本走不到「这是不是
> 普通文件」那一步（评审第三轮挖出）。

**动作**

```
"$PY" -c "
import os, socket, sys, tempfile; sys.path.insert(0,'tests')
from qmt_fsroot import open_root
from qmt_manifest import MANIFEST_NAME, read_manifest, begin_run, ManifestInvalidError
d = os.path.join(os.path.realpath(tempfile.mkdtemp()), 'staging'); os.mkdir(d)
fd = open_root(d); os.chdir(d)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(MANIFEST_NAME)
for name, fn in (('读账本', read_manifest), ('启动闸', begin_run)):
    try: fn(fd); print(name, '：没拦住 ❌')
    except ManifestInvalidError as e: print(name, '：拦住了 ✅ ——', str(e).splitlines()[0][:34])
s.close()
"
```

**期望**：两行都是「拦住了 ✅」，后面跟着「存在但不是普通文件——拒绝。」

**通过判定**：两行都带 ✅ → 通过。
出现 `OSError` 或 `Operation not supported` 之类的原始报错 → **不通过**
（那说明修复没生效，你拿到的会是一堆看不懂的东西而不是恢复指引）。

> ⚠️ 脚本里那句 `os.chdir(d)` 不是多余的：socket 的路径长度上限约 104 个字符，
> 临时目录的完整路径本身就超了（实测报 `AF_UNIX path too long`），
> 所以要先切进目录、再用短名字创建。

---

# Self-Review（写完 plan 后逐项自查）

## 1. Spec 覆盖 —— §4.5 读侧校验清单逐条对到任务

| spec 判据 | 任务 |
|---|---|
| 必需键齐全（外延写死） | Task 5 |
| `seed` 非空 | Task 5 |
| `source_snapshot.universe` 三层皆为 list | Task 6 |
| `source_mount` 三子键形状（S2-F2 更正后） | Task 6 |
| 未知顶层键原样保留（O4-F10） | Task 14 |
| `pool_order` 三层 list + 元素为 `{code, universe_idx}`（R13-F1） | Task 7 |
| `code` 正则 + 后缀与所在层一致 | Task 7 |
| 层内 `code` 与 `universe_idx` 各自唯一 | Task 7 |
| `universe_idx` 界内 + 交叉核对锚点 | Task 8 |
| `cursor[market]` 整数且在闭区间内 | Task 8 |
| `files` 逐项合规（R21-F3） | Task 9 |
| `staged_export_log` 自洽（R38-F1） | Task 10 |
| `manifest_version` 三档（O2-F8 + O4-F10） | Task 3 |
| `stopped_reason` 闭合枚举 + `fetch_fatal_error` 四字段配对（R93-F1 + R94-F2 + O4-F3） | Task 11 |
| `source_verification` 三级与**前置输入**（R15-F2） | Task 12 |
| `source_verification_evidence` 存根（R16-F1 + O4-F2 + O4-F13） | Task 13 |
| 聚合指纹算法（S2-F4 补定义） | Task 4 |
| manifest 原子写 + 目录耐久 + `F_FULLFSYNC`（R45-F2 + O4-F11） | Task 1 + 15 + 16 |
| 每股提交一次（R37-F1）且**不动**生命周期字段（§9-3s） | Task 16 |
| 收尾提交的清除/保留规则（R95-F2 + O2-F7 + O4-F1 + P2-F3） | Task 17 + 18 |
| 引导态：manifest 不存在 ≠ 畸形（R60-F3） | Task 15 |

**已知不覆盖（按切片边界，逐条登记）**：`.staging.lock` 取锁（S1 已交付原语，取锁时机在 S5）、`.inflight.json` 崩溃恢复（S4）、四象限幂等（S4）、`--max-bytes` 流式扣减（S4）、七条源边界闸（S5）、预筛与分层洗牌（S3）。

## 2. Placeholder 扫描

无 `TBD` / `TODO` / 「稍后补」/「适当的错误处理」/「类似 Task N」。每个代码步骤都带可直接粘贴的代码，每个测试步骤都带完整测试体。

## 3. 类型一致性（自查发现并已修的两条）

- ❌→✅ **`_fcntl_t1` 跨文件引用**：Task 16/18 的测试在 `test_qmt_manifest.py` 里，却用了 `test_qmt_fsroot.py` 的别名 `_fcntl_t1`。已改为在 `test_qmt_manifest.py` 顶部 `import fcntl` 并直接用 `fcntl`；Task 1 那 14 处别名保留不动（它们在正确的文件里）。
- ❌→✅ **存根未重算导致的变异假阴性**：改动 `files` / `staged_export_log` 的 10 处否定档，若不重算 `source_verification_evidence`，聚合判据会**掩盖**被测判据——否定档照样红，但红的是聚合，于是把被测判据变异掉后测试**仍然绿**，变异表显示「零红」被误读成「测试没判别力」。已加 `_recompute_evidence(m)` 帮手并在 10 处调用，另给 M30 / M32 补了归因提醒。

- ❌→✅ **上游判据掩盖下游档（第二轮自查，Task 6）**：三条改 `source_snapshot` 的否定档只改了
  一处 sha / 留着默认 pool_order，于是「两处 sha 必须相等」与「pool_order 交叉核对」会**顶上来**，
  把被测判据变异掉后测试仍绿。已加 `_with_universe` 帮手、把 sha 格式档改成两处同时设坏值、
  并给三条档清空池与清单。
- ✅ **等价变异已识别并登记（Task 7）**：`pool_order` 的「后缀与层一致」与「交叉核对」
  **结构上重叠**（已实测），造不出专属档。M19 登记为等价变异、测试 docstring 写明「变异后
  仍绿是预期」，并在 `source_snapshot` 那一侧补了**真有**专属档的 `test_universe_code_suffix...`。

其余符号：`_valid_manifest` / `_sha` / `_file_rec` / `_recompute_evidence` / `_with_universe`（Task 5）→ 后续全用；`_fatal`（Task 11）→ Task 15/17/18 用；`_evidence` / `_agg_of` / `_GMT`（Task 12）→ Task 13 用；`_staging`（Task 15）→ Task 16/18 用；`_prev`（Task 17）→ Task 17 内用。**定义均早于首次使用。**

---

# 评审轮次记录

| 轮 | 判决 | 内容 |
|---|---|---|
| **R1** | needs-attention（3 high）| 三条**同一形态**：结构性保证被「可变的嵌套状态」与「没被校验的字段」绕过。①`lifecycle_snapshot` 浅拷贝 → 取完快照改嵌套 `fetch_fatal_error` 照样落盘，且 `kind` 被改成 `source_path_escape` 后只需前提①即可清除 → 完整洗白链；②`revisited_fatal_path` 未校验类型（`"false"` 是真值）+ `escape` 可变 + `kind↔escape` 配对未校验；③`os.replace` 之后只有普通 `fsync(目录)`，断电可丢改名。**三条均本机端到端复现后才修**，修完再复现证明已堵，各配专属档 + 7 条变异全部命中 |
| **R2** | needs-attention（2 high）| ①**读侧接受了写侧根本产不出的生命周期组合** —— `reason=staging_path_escape` 配 `kind=source_path_escape` 被放行，而决策表只看 `kind` ⇒ 绕过 P2-F3 无条件要求的 staging 全量复校、直接清掉粘性 fatal（改 6 个字符即可，而「有人动过 staging」正是威胁模型）。按判据穷尽又挖出同族两条评审没报的。②**提交入口能写出自己读不回来的账本** —— `_write_manifest` 不校验就落盘，一次 per-stock 提交能把几百只股的 staging 变成砖头而调用返回成功。**两条均本机端到端复现后才修**，6 条变异全部命中；连带订正三条既有测试的判别力（含 984 探测的 base 自身变非法会掩盖整条扫描）|
| **R3** | needs-attention（1 high）| **一次后来的逃逸会抹掉未解除的粘性信任证据** —— spec 自己的两句话（「本次又撞 escape → 覆盖上一次的」与「`fetch_fatal_error` 是**粘性**的信任状态」）在 `staging → source` 这个次序上直接冲突：清除 staging 逃逸要过两道前提，清除 source 逃逸只要一道，用后者覆盖前者等于把那道门取消。**本机三次运行端到端复现**。控制者按判据穷尽又挖出同族变体（`staging_recheck_failed` 同样会被抹掉，而它的 kind 可以是 source）。3 条变异全部命中，含一条专门证明「没修过头」的方向②档；连带订正一条既有测试——它原样编码的正是被证明有洞的那个覆盖方向 |
| **R4** | needs-attention（1 high）| **清除闸仍按 `kind` 判「要不要全量复校」** —— 这是 **R3 的修复动作自己留下的另一半**：我为这件事专门抽出了判定函数，把它用在覆盖闸上却漏了清除闸，而清除闸正是它本来要服务的地方。两次运行即可洗白，本机复现。修完**留了机械守卫**（AST + 防空转）钉住「只许一处判定」；3 条变异：复现原 bug（行为档与守卫**同时**变红）、修过头（三条方向②档变红）、改坏守卫（防空转抓住）|
| **R5** | needs-attention（2 high + 1 medium）| 三条**共同形态仍是「我只修了一半」**：①「复校失败」被前提①的早退挡住（这条分支的次序被改过三轮，每次只挪一格）；②「用启动快照挡住调用方污染」只落在 `commit_stock`，漏了**唯一能清除证据**的 `commit_final` —— 内存被污染时它会发布一份干净账本；③「写侧要产出读侧收得下的东西」只补了**结构**那一半，漏了**大小**那一半。三条均本机复现；4 条变异全部命中（含一条专证「序列化漂移」）；连带把四条既有 `commit_final` 档改成先落盘——原本磁盘是空的，其中**两条已经变成恒真** |
| **R6** | needs-attention（2 high）| ①**「磁盘上没有账本」被当成全新引导态** —— 这是 R5 那个「凭据改从磁盘取」的修复自己带出来的另一面，运行中删掉账本就能发布一份干净账本；②**`--skip-existing-verify` 的互斥只在收尾才判**，而 P2-F3 明写「拒绝启动」——带 flag 的运行能先拷完文件、推进游标再被拒，已消耗的配额收不回来。⭐ 控制者顺着①回头**重核已登记残留**，实测证明「伪造启动快照」是**活的洞**，遂把 `commit_stock` 的 `lifecycle` 参数整个拆掉。5 条变异全部命中（含一条证明没修过头）|
| **自查** | 2 high（控制者，非评审）| 等配额期间拿十条自问对**刚改过的新代码**跑了一遍：①第⑨问应用到 `commit_stock`——R6 只报了 `commit_final` 的「账本被删」，而两个入口是**同一轮**改成从磁盘取的，洞照样在（崩在收尾之前就永久洗白）；②第①问应用到**新加的** `skip_existing_verify` 参数——没做 bool 校验。4 条变异全部命中，其中「引导态也一律拒」红了 14 条，方向②覆盖充分 |
| **R7** | needs-attention（1 high）| **`{}` 当哨兵，把「没有账本」与「账本干净」压成同一状态** —— 已建成进度的干净 staging，账本被删就会被当成引导态、拿内存里那份凭空重建，`files`/`pool_order`/`cursor` 静默丢失；换成另一份合法账本也无人察觉。本机两档复现。改用不透明 `RunLedger`（存在位 + 字节指纹）并在每次提交后更新预期。5 条变异全部命中：复现原 bug / 删指纹 / 不更新预期（连续提交那条立刻红）/ 删反向检查 / 修过头（红 15 条）|
| **追查** | 1 high（控制者；线索来自被掐断的 R8）| codex R8 被配额掐断、判决行是伪造的，但它中途留下一句「stale-but-valid caller snapshot can roll back already committed progress」——**当线索追**，本机复现坐实：过期副本让 files 6→4、cursor 倒退、池缩水。⚠️ 差点修过头：第一反应「条目只增不减」会**打死 spec 自己的崩溃恢复**（§4.4:429 明写它在 begin_run 之后、运行之内，且第③档合法回退）——查了 spec 原文才没写错。6 条变异里**两条零红**（files/pool 被账本自身一致性规则结构性绑死，造不出专属档，如实登记）；cursor 那条补了专属档后判别力恢复 |
| **R9** | needs-attention（2 high + 1 medium）| **最彻底的一轮（73 条查看命令）**。①回滚守卫**只看了我想到的那三样**，其余 9 个字段逐字段实测全部能被过期副本改写（累计字节调小=绕开 --max-bytes、重试清零=复活耗尽的候选、已提交文件指纹被改=完整性基线被污染、冻结的 seed/universe 被换=与归属标记永久对不上）；②崩溃恢复的布尔声明是**无限制旁路**，一次「恢复」能清空所有市场；③解析器只接 JSONDecodeError，5 KB 的超长整数就让启动抛裸 ValueError。9 条变异：7 条命中；2 条零红（files 范围判据被 pool 判据 + 账本一致性规则结构性兜住，如实登记），cursor 范围补专属档后判别力恢复 |
| **R10** | needs-attention（2 high）| **两条都是 R9 那次修复自己引入的**：①「attempts 只增不减」**堵死了 spec 自己的重试成功路径**（§4.4:350 明写重试成功要移出 failures）→ 瞬时失败过的候选永远回不到池里，可能报出假的池穷尽；②单调守卫写成「两边类型都对才比」→ **字段缺席/类型不对时守卫被跳过**，实测 5 种绕法全通过（含**等长改写 batches**）。6 条变异 5 条命中；1 条零红（自证成功的「files 恰好两条」那半边被账本一致性规则兜住，**第三次**撞同一耦合，如实登记）|
| **R11** | needs-attention（1 high + 1 medium）| ①**崩溃恢复的两半被判成两个独立许可** —— spec 是「删条目**且**退游标」的一次耦合转移，分开判时「删了却不退」照样过 → 那只股永远不会被重拉、池子静默缩水，正是恢复流程要消灭的状态；另漏「只退游标」与「锚点核对」两处同族。②**漏读了 §4.5:785 的明文规定**：per-stock 提交必须写死 partial + 空 passes —— 不写死时 `full` 标签会被原样写回，崩在收尾前就留下一份自称 full 的账本。6 条变异 5 条命中；1 条零红（「部分移除」被账本一致性规则兜住，**第四次**撞同一耦合，如实登记）|
| **自查②** | 1 high（控制者，非评审）| R12 等配额期间用**第⑪问**追 R11-B 的同族另一处：那条管 per-stock 提交写死 partial，而**收尾提交**同样照发调用方给的级别 —— spec §4.5:342 明写「一旦用了 --skip-existing-verify，manifest 就打 partial」，而运行凭据里根本没记住这个开关。本机复现：skip-verify 的运行发布了 full。3 条变异全部命中（含一条「一律压 partial」的修过头档）|
| **R12** | needs-attention（2 high）| ①**运行凭据本身可变**，而它记的全是安全事实 —— 改 `skip_existing_verify` 让跳过校验的运行又发 full、改 `existed` 让被删的账本当引导态重建；同族第二处：两个入口**不核对**传进来的是不是真凭据（鸭子类型照收）。②**`failures` 两条同名记录**绕开有界重试（按 stock_code 归并成 dict，后者覆盖前者），补拉「先重试 attempts<2」会命中第一条，复活一个已耗尽重试的候选。4 条变异全部命中 |
| **R13** | needs-attention（2 high）| **两条都是 R12 那次修复留下的边界**：①恢复豁免判「完全移除」**只数条数** → 把两条记录的路径/字节/指纹全换掉仍是 (2, True)，已提交股票被**重新绑定到不同的文件**、原文件变孤儿；②`isinstance` 证明不了凭据**来自** begin_run —— 冻结挡住了「改」，挡不住「**重造**」（照字段值另造一个真类实例）。4 条变异 3 条命中；1 条零红（池豁免被 files 判据抢先接住，**第五次**撞同一耦合，如实登记）|
| **R14** | needs-attention（3 high）| ①**凭据仍可伪造** —— 令牌是初始化字段，`dataclasses.replace` 一起复制；`object.__setattr__` 也改得动。**这条走了三轮才到位**（可变→冻结→仍可重造），根因是「把安全事实放在调用方手里的对象上」这个前提本身就错了。②累计字节只拦减少 → **加了 246 万字节的文件却原地不动**照样过，突破 --max-bytes。③引导态早退把「只看 payload 的固有检查」一起跳过 → **首次提交**就能写进同名 failures，而下一次提交又会因重复被拒，staging 当场卡死。5 条变异 4 条命中；1 条零红是**设计使然**（真正的防线在句柄属性访问上，入口那道是早失败冗余）|
| **R15** | needs-attention（3 high）| ⭐**层次终于变了**：①打**核心提交语义** —— 「用调用方那份整体覆盖」⇒ 省略即删除，O4-F10 的未知顶层键通道被打破；②**P2-F3 有半句我从未实现**（复校失败那一轮不得推进进度）；③才是守卫边界（`committed_bytes` 缺席 → 配额判据永久不生效）。6 条变异全部命中，含两条修过头档（carry-forward 连必需键也带 / 进度比对改成与上次提交比）|
| **R16** | needs-attention（3 high）| ⭐⭐**三条全部落在核心语义 / spec 漏实现，没有一条是守卫边界**（R15 是 3 条里 1 条，趋势继续走对）。①**收口点位置错了** —— P2-F3 判在收尾，而 per-stock 提交早已逐只落盘，抛异常收不回来，且那一轮 spec 指定的 `staging_recheck_failed` 一次没记上；②**`pool_order` 只比集合** —— §4.5:545 的「按序追加」+「pilot 唯一消费顺序来源」被**重排 / 插队**安静绕过，成员一个没少；③**配额下限漏掉 staged export_log**（§4.5:532 明定的唯一非股级计账对象），引导态那一档更是被 `if files:` 整个跳过。⚠️ ③**推翻了我 R15 那轮自己写的正向档** —— 「方向②」的正向档同样要按字段穷尽。**15 组定向变异全部命中、零红为 0**，隔离度可核：闸「只看结论不看起跑状态」红 68 条、「只看起跑状态不看结论」红 1 条，两半各自承重；`attest` 入口那道凭据检查**首轮零红**（与 `_state()` 的文案互相掩盖），补一档「传错类型」后判别力恢复 |
| **Opus** | needs-attention（1 high + 3 medium + 1 low）| ⚠️ **换了评审通道**（user 指定：codex 配额掐断后改用另一个 Opus 5 做对抗性评审；它**写不了账本**，故不兑现治理闸门，只当找缺陷用）。**五条全部本机复现坐实、零误报**。⭐⭐ **两条是 R16 那次修复自己引入的**：①一致性检查写成无条件相等，把 `max_bytes_stop()`/`escape_stop()` 两个合法结局全堵死 —— **唯一合法的恢复路径被自己封了**，还劝操作者报废一棵健康 staging；②新加的配额下限把两条累计字节老攻击档抬到门槛以下，**两条守卫从此零红**。另三条：登记「复校失败」在无 fatal 账本上被静默丢弃、`--skip-existing-verify` 互斥窄于 spec 原文、AST 守卫自己漏了一半判据。**10 组变异全部命中、零红为 0**（含两个注入诱饵函数坐实 AST 守卫的加强）。⚠️ 评审自报未覆盖：S2a 期的读侧校验器（~240-455 行）与本轮新增测试的大部分 |
| **自查③** | 1 档（控制者，非评审）| 放开「非 clean 结局不查一致性」之后，`elif` 那一支只剩「clean 且取值不等」一种情形，而两条新正向档都不经过它 —— 补 `test_a_passing_recheck_must_still_be_reported_at_the_final_commit` 钉住「登记通过却不上报」。变异实测（把判据窄化成 `is not None and …`）**只有它一条红**，判别力隔离 |
| **Opus-2** | needs-attention（1 medium + 3 low）| ⭐⭐ **本片第一次没有 high**。评审对**安全核心做了穷尽验证并判定找不到洞**，方法可核：`resolve_final_lifecycle` 的 **10 种合法前态 × 9 种结局**全枚举；走**真入口**的**两轮链路 2916 条**全枚举（凡产出「无 fatal」账本的链路**无一例外**都经过「登记通过 + 上报通过 + 重走过路径」）；**84 个决策表输出**逐个回喂读侧全部往返成功。①medium = 复校闸只立在 per-stock 入口（同一份 payload：per-stock 拒、收尾收）；②③④ 全是**测试判别力**（生产代码正确但判据没人守）。四条**全部本机复核属实、零误报**。8 组变异 7 组一次命中；**P7 首轮零红 —— 追下去发现我补的那条档本身是假的**（邻居 `endswith` 抢先抛且文案同样含 `stock_code`），改成断言判据专属措辞后判别力才成立 ⇒ **同一族错误在修它的过程中原地又踩一次**（见 S2-F49/F54）|
| **Opus-3** | needs-attention（1 medium + 3 low）| **连续第二轮没有 high**。①medium = **socket 型 `fetch_manifest.json` 逃过「不是普通文件」那道闸**：`O_NONBLOCK` 只解决 FIFO 阻塞，socket 上 `open(2)` 直接失败 ⇒ 走不到 `S_ISREG`，四个入口全抛裸 `OSError`；而注释里那条枚举写着「FIFO/目录/设备/socket」—— **列四项只兑现两项**。②③④ 全是**判据没人守**（收尾剥键 / 进度指纹两分量互相掩盖 / 三条小守卫）。四条**全部本机复核属实**（6 组复核变异全存活）。修完 **9 组变异全部命中、零红为 0**，四个进度分量各杀各的。⚠️ 评审另指出 `acquire_lock` 有同样 socket 盲区 —— **S1 既有代码、不在 diff 里**，按规矩不动，已登记 |
| **Kimi-1** | needs-attention（1 medium + 2 low）| ⚠️ **换通道**（user 指定；codex 配额要等到 9/7、Opus 子代理撞 session 限流）。⭐ **Kimi 通道能写 `attest-ledger.json`**（账本里已有先例 PR #166 的 `reviewer: kimi-code/k3@…`）⇒ 它拿到真 approve 就**兑现得了治理条款 1**，不必 override。跑前按纪律先跑探针（`kimi -p` 极小提示，不算评审不写账本）确认通道健康。三条**全部本机复现属实、零误报**：①medium = **不可哈希的 JSON 值让四处新守卫抛裸 `TypeError`** —— `failures` 是扩展字段、**读侧从不校验**，而守卫又排在读侧校验之前 ⇒ 没有任何上游判据接得住；「守卫自己被它该抓的损坏弄坏」第四次。②③ = 写侧上限那条档其实钉的是读侧（两侧报错都含「过大」，**第三次**互相掩盖）、注释引用了改名前的函数。7 组变异 6 组一次命中；**K7 零红 —— 我在 `_hashable` 注释里claim 的「不同坏值→不同键」那半没人守**（退化成返回常量全量不红），补两条纯函数档后变异红 3 条 |

> ⚠️ **R1 三条的共同根因**：我校验了「想到的那几个字段」（`kind` /
> `staging_recheck` / `relative_path` / `component`），漏了 `revisited_fatal_path`；
> 我拷贝了「顶层的三个键」，漏了它们**里面**那一层。
> 这正是 [[feedback_read_side_predicate_both_directions]] 那条
> 「按**字段**穷尽而不是按**判据句**穷尽」——只是这次对象从「读侧校验的字段」
> 换成了「构造期校验的字段」与「拷贝边界」。

> ⚠️⚠️ **R2 与 R1 是同一根因的两个层级**：R1 是「**对象内部**的字段与拷贝深度
> 没穷尽」，R2 是「**字段之间的取值组合**没穷尽」。判据要升级成三问：
> ①每个字段都校验了吗？
> ②字段**之间**的组合——写侧能产出哪些、读侧收了哪些？（读侧多收的那些，
>   就是「畸形被放行·安静」那一半）
> ③写出去的东西，自己**读得回来**吗，而且是在**写之前**就知道？

> ⚠️⚠️ **R3 是第四个层级：状态机的「时间维度」**。R1/R2 问的都是「**一个**状态合不合法」，
> R3 问的是「**状态之间的转移**安不安全」——一个单看每一步都合法的序列，整体却能把安全结论洗掉。
> 判据补第四问：**④凡「新事件覆盖旧状态」的规则，新状态是不是至少和旧状态一样严？**
> 配套纪律：状态机测试必须**跨多次运行**，只测单步转移看不见这类洞。

> ⚠️⚠️⚠️ **R4 是第五个层级，也是最该记住的一条：修复动作自己会留下另一半**。
> R4 那条 high 完全是 R3 修复的产物——我为「哪些状态必须做过全量复校才能清」
> 抽出了一个判定函数，**把它用在了覆盖闸上，却漏了清除闸**，而清除闸正是它本来
> 要服务的地方。判据补第五问：**⑤新抽出一个判定/常量时，把它该管的调用点列全了吗？**
> 配套纪律：**这类修复必须留机械守卫**（本片用 AST 断言「只许一处判定」+ 防空转下限），
> 因为「同一件事判在两处」靠人眼复核是必然会漏的。

> ⚠️⚠️⚠️ **R5 把「只修了一半」拆成三种可复用的问法**：
> ⑥ **次序类结论**（「A 必须先于 B」）——挪到位了吗？还是又只挪了一格？
>   （本片这条分支的次序被改了**三轮**才到位，每轮都以为改完了。）
> ⑦ **保护类改动**（「防调用方污染」「防越权」）——**能造成最大损害的那个入口**
>   被它覆盖到了吗？本片当初只覆盖了调用频次最高的那个，而不是危害最大的那个。
> ⑧ **「写侧要产出读侧收得下的东西」**——不只是**结构**，还包括**大小**，
>   以及读侧设了上限/下限的**任何**维度。

> ⭐ 另一条贯穿五轮的做法：**每次改动之后要回头问「哪些既有测试因此变成恒真了」**。
> R5 这轮就有两条 `commit_final` 档在凭据换成磁盘之后变成恒真（磁盘是空的，
> 决策表看不到 fatal，断言自动成立）——它们**照样是绿的**，不主动查就发现不了。

> ⚠️⚠️⚠️ **R6 补第⑨⑩问，两条都很贵**：
> ⑨ **凡把凭据从 A 换成 B**（如「从内存改成从磁盘」），必须问「**B 缺席或被篡改时会怎样**」。
>   正解往往不是二选一，而是**两边都要、不一致即 fail closed**。
> ⑩ **登记为「已接受残留」的东西，每一轮都要重新问一次它还能不能被利用。**
>   「残留」的含义是「当时判断修它代价不划算」，**不是「证明了它无害」**。
>   本片那条残留（伪造启动快照）第 6 轮被实测证明是活的洞——而且拆掉它之后
>   代码反而**更简单**（少一个参数、少一条守卫）。

> ⚠️⚠️ **第⑪问（等配额期间自查得来的）：评审报了 A 处，同族的 B 处呢？**
> R6 报的「账本被删」落在 `commit_final`，而 `commit_stock` 是**同一轮**被改成
> 「从磁盘取」的——洞一模一样，评审没提。**凡评审报出一处，先问「这一轮我还把
> 同样的改动做在哪些地方」，逐处套用同一条判据**；修完把判定抽成**一份**共用的
> （S2-F15 已经教过：同一件事判在两处，改了一处忘了另一处）。

> ⚠️⚠️ **第⑫问（R7）：凡用「空值 / 假值」当哨兵，先问它是不是把两种语义压在了一起。**
> 本片的 `{}` 同时表示「磁盘上没有账本」与「账本在、但没有生命周期字段」，
> 而判断逻辑取的正是它的**真假值** —— 于是一棵已积累进度的干净 staging
> 被删掉账本后会被当成「全新开始」，进度静默丢失。
> ⭐ 讽刺的是 R60-F3（manifest 不存在 ≠ manifest 坏了）本片一开始就**正确地
> 分开过**这两种状态；后来引入凭据时又把它们合并了。**同一族错误的正反两面，
> 在同一片里各犯一次。** 解法：用**不透明的类型**承载状态，别用容器的真假值。

> ⚠️⚠️ **第⑬问（追查 R8 线索得来）：这个守卫管的是「谁」？**
> 运行凭据管住了「**外人**动账本」（消失 / 被替换 / 指纹变了），却管不住
> 「**调用方自己**交回来的内容退步了」——而两个入口的非生命周期内容**全部**
> 来自调用方内存。**列一遍「这个守卫挡住了哪些主体」，缺的那个主体往往最常见。**

> ⭐ 另一条方法论收获：**被掐断那一轮的判决行是假的，但它中途说的话可以当线索。**
> 本条 high 正是这么来的。反过来同样成立——那只是「我**正要去**查」，
> **结论必须自己复现出来才算数**，不能直接当 finding 采信。

> ⚠️⚠️ **第⑭问（R9）：第①问「按字段穷尽」同样适用于**守卫本身**。**
> 我写回滚守卫时只列了想得到的三样（files 身份 / pool 身份 / cursor 方向），
> 剩下 9 个字段全都敞着。**写完一条守卫，回头把「它没看的字段」列一遍。**

> ⚠️⚠️ **第⑮问（R9）：布尔旁路是反模式。**
> `recovering_from_crash=True` 一开就是**无限制**的。「允许做某事」必须连
> **做到什么程度**一起声明 —— 改成 `RecoveryScope(股票, 市场, 下标)` 之后，
> 「一次恢复清空所有市场」这种状态**根本表达不出来**。

> ⚠️ **第⑯问（R9）：每一层的失败模式都要问一遍「我接全了吗」。**
> S2-F9 管「JSON **值**的类型」、S2-F10 管「**磁盘对象**的类型」、
> S2-F27 管「**解析器本身**会抛什么」——同一族错误的第三次。

> ⚠️⚠️ **第⑰问（R10）：方向②不只有「合法的增长」，还有「合法的移除」。**
> 我给「计数只增不减」配了增长的放行档，**没配「合法移除」的**——而 spec 明写
> 「重试成功即把该条目移出 failures」。**写单调守卫时，先去 spec 里找一遍
> 「什么情况下它该减少 / 该消失」。**

> ⚠️⚠️ **第⑱问（R10）：「对坏输入健壮」不等于「对坏输入放行」。**
> S2-F9 教的是守卫别被坏输入弄崩，我却把它写成了 `if 两边类型都对才比` ——
> 于是**字段缺席或类型不对时整条守卫被跳过**。正确姿势：**上一份里有的，
> 新的必须仍在、类型仍对、且满足转移规则**；坏输入要**拒**，不是**跳**。

> ⚠️⚠️ **第⑲问（R11）：spec 里写成「A **且** B」的转移，实现里不能拆成两条独立判据。**
> 崩溃恢复是「删该股条目 **且** 退游标」——我判成了两个各自独立的许可，
> 于是「删了却不退」照样通过。**看到「且」就问：这两半我是一起判的吗？**

> ⚠️⚠️ **第⑳问（R11）：实现一节 spec 之前，把那一节从头到尾读完再动手。**
> S2-F31 不是什么精妙缺陷 —— §4.5:785 白纸黑字写着「per-stock 提交时这两个
> 字段的取值**必须写死**」，而我实现的正是 §4.5。**漏读比想错更常见，也更便宜避免。**

> ⚠️⚠️ **第㉑问（R12）：凡承载安全事实的对象，先问「调用方改得动吗」；
> 改不动之后，再问「另造一个行不行」。**
> `RunLedger` 记的是「跳没跳过校验 / 见没见过账本 / 账本指纹」——一行赋值就能抹掉。
> 冻结之后还要核类型，否则鸭子类型直接绕过。（与 R1 那条「escape 证据塞进
> frozen dataclass 仍可变」是同一族的第二次。）

> ⚠️⚠️ **第㉒问（R12）：把列表按某个键归并成 dict 时，先问「同一个键出现两次会怎样」。**
> 归并是**有损**的：`failures` 里两条同名记录，后者覆盖前者，守卫看到的是「好的那条」，
> 而真正被消费的是「坏的那条」。**归并前先拦重复。**

> ⚠️⚠️ **第㉓问（R13）：「等价」的判定不能只数个数。**
> 恢复豁免判「这只股是不是被完全移除了」时，我只比了 files **条数**与「在不在池里」
> —— 把两条记录的路径、字节数、指纹**全换掉**，条数仍是 2。**数量相同 ≠ 内容相同。**

> ⚠️⚠️ **第㉔问（R13）：「不可变」与「不可伪造」是两回事。**
> R12 我把凭据冻结了，挡住了「改」；R13 才发现挡不住「**重造**」——
> dataclass 的构造函数是公开的。**冻结之后要再问一次「能不能另造一个」**，
> 答案是加模块私有令牌，让只有本模块造得出。

> ⚠️⚠️⚠️ **第㉕问（R14，最贵的一条）：这条判据我已经修了三轮 —— 是不是前提就错了？**
> 凭据这件事走了 R12（可变）→ R13（冻结）→ R14（仍可 `replace` / `__setattr__`）三轮。
> 前两轮都在**修表现**：改不动了、造不出了……而真正的问题是
> **「把安全事实放在调用方手里的那个对象上」这个前提本身就是错的**。
> 换成「句柄 + 模块内注册表」之后，那一整族绕法**一次性全部不可表达**。
> **判据：同一条判据连修两轮以上，停下来问「我是不是在修表现」。**

> ⚠️ **第㉖问（R14）：一个 `if` 里别绑两件事。**
> `if previous is None: return` 本意是跳过「新旧对比」，却把「这一份自己合不合法」
> 也一起跳过了 —— **首次**提交因此能写进同名 failures，而下一次提交又会拒它，
> staging 当场卡死。**早退之前先问：我要跳过的到底是哪一类检查？**

> ⚠️⚠️ **第㉗问（R15）：「整体覆盖」式的写入，天然会把「省略」变成「删除」。**
> 两个提交入口都从调用方那份重建 payload —— 于是**少写一个键就等于删掉它**，
> 而 O4-F10 的「未知顶层键原样保留」正是前向兼容的命根子。
> **凡「用新值整体替换旧值」的写入，先问：旧值里有而新值里没有的，去哪了？**

> ⚠️ **第㉘问（R15）：spec 里带「且」的句子，两半都实现了吗？**
> P2-F3 是「保留 fatal + 换 stopped_reason **且** 本次不得推进进度」——
> 我实现了前半句，后半句**从未落地**。这与第⑲问（「且」不能拆成两条独立判据）
> 是同一句话的两个方向：⑲说别拆，㉘说**别只做一半**。

---

# 交付诚实口径

**做完 S2b 的正确表述**：manifest 这一层（结构 + 校验 + 落盘 + 生命周期）建好了，全部验证跑在临时目录里；`qmt_fetch.py` 仍然**零实现**。

**⛔ 禁止的表述**（无论听起来多顺）：

- 「4b 完成」
- 「SMB 拉取做好了」
- 「真实数据接入完成」
- 「pilot 已完成」
- 「100 股已出货」
- 「验证通过即可」/「看起来正常」/「应该没问题」

**本片之后还剩什么**：S3（预筛 + 分层储备池）、S4（拷贝引擎）、S5（源边界闸 + 命令行），然后才是 4c（编排 / 报告 / 出货凭据）。
