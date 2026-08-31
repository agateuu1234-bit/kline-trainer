# 后端 CI 触发路径：取消过滤器，每个 PR 都跑

- 日期：2026-08-30
- 分支：`fix/ci-paths-suite-external-inputs`（base = main `1437529`）
- 类别：trust-boundary（改 `.github/workflows/**`）→ 强制 `codex:adversarial-review`
- 前置：PR #175 落地了 `test_env_example_coverage.py`；#178 明写「CI paths 漏 `scripts/**`」为残留，已连续两个 PR 推迟

---

## A. 问题

`.github/workflows/backend-tests.yml` 只在 `on.pull_request.paths` 命中的改动上跑。
合并前的 paths 是：

```yaml
- 'backend/**'
- 'pytest.ini'
- 'tests/contract-fixtures/**'
- '.github/workflows/backend-tests.yml'
```

而后端套件里有测试**读 `backend/` 之外的文件**。这些文件不在 paths 里 ⇒ 只改它们的
PR 根本不触发本套件 ⇒ **守卫存在但有一条静默旁路**：守卫真要红，也得等合进 main
之后由 `push: branches: [main]` 触发才暴露。本仓在 Catalyst 闸门上踩过同型的坑
（后合 PR 引红 main，见 memory `project_catalyst_gate_scheme_fix`）。

## B. 外部输入到底有哪些（实测，非推断）

**没有靠读代码猜**。给 pytest 挂一个插件，把 `builtins.open` /
`pathlib.Path.{read_text,read_bytes,open}` / `os.{scandir,listdir}` 各包一层记录路径，
然后**真跑一遍全套**（2026-08-30 在 main `1437529` 上：`1106 passed`，命中 74 条记录）。
去掉 pytest 自己的 `.pytest_cache` 后，外部输入是：

| # | 外部输入 | 谁在读 | 补前状态 |
|---|---|---|---|
| 1 | `scripts/`（递归，当前 30 个 `.sh`） | `test_env_example_coverage.py` | ❌ 未覆盖 |
| 2 | `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | `test_qmt_pilot_db.py` 的跨语言 `CONTRACT_VERSION` 漂移钉 | ❌ 未覆盖 |
| 3 | `tests/contract-fixtures/` | `test_openapi.py` **和** `test_routes.py` 两处 | ✅ 已覆盖 |

> ⚠️ 第 3 条「两处」是 codex R2 挖出来的：追踪器记录的是**被读的路径**，
> 不是**哪个模块读的**，我当时凭印象把它归给了 `test_openapi.py` 一家。
> 教训=归因要单独核，结论对不代表归因对。

## C. 走过的弯路与最终决策

### C-1 初版（R1 前）：补 paths + 造一道守卫

思路是：每个测试模块把自己读到的外部输入声明成 `EXTERNAL_INPUTS`，守卫 AST 收集后
逐条核 paths 覆盖。**两轮评审两次被打回**：

| 轮 | 结果 | 缺陷 |
|---|---|---|
| —— | 额度用完（日志无 `Verdict:`，账本未写入） | 按规矩不计轮次，等额度重跑 |
| R1 | needs-attention | 覆盖判据有两个假绿：①`scripts/*`+`scripts/*/*` 骗过两个固定探针却盖不住第三层；②GitHub 的 `?` 是「前一个字符 0 或 1 次」的数量词而非任意字符，`Model?.swift` 被误判成盖得住 `Models.swift`。**两条都本地复现后重写了判据** |
| R2 | needs-attention | 更根本：声明制**靠人自觉**，不是构造上穷尽的。而且假阴性**当场就存在** —— `test_routes.py` 也读 `tests/contract-fixtures` 却没声明 |

R2 说得对。要做到不靠自觉，得再写约 100 行静态分析去解析各种路径表达式
（`__file__.parent` / `parents[1]` / `parents[2]` / `parents[3]` 四种锚点写法都要认），
而且静态分析永远有它看不见的写法 —— 盲区只是变小、不会消失。

### C-2 最终决策（user 2026-08-30 拍板）：**取消过滤器**

实测本 job 在 CI 上**只跑 1.5–2 分钟**（`gh run list` 最近 8 次：1.5 / 1.6 / 1.6 / 1.7 /
1.8 / 1.9 / 2 / 2 分钟）。为省这 2 分钟去维护一张「必须与套件实际读取面永远同步」的
清单，不划算 —— 而那张清单已经漏过两次。

取消过滤器后，「某个外部输入没进清单」这件事**从根上不可能发生**，于是那套发现机制
和三处声明全部不需要，一并删掉。

**代价**：以后每个 PR（包括只改 iOS 界面的）都多跑约 2 分钟。user 已知悉并接受。

**为什么这么做是安全的**：
- `backend pytest (full suite)` **不是**分支保护的必需检查（已核 `codeowners_required_globs`
  与 required-checks 配置），所以「无过滤器」不会造成必需检查等不到状态的死锁；
- 本仓已有先例：`hardening_6_gate.yml` 就没有 paths 过滤器（当年正是为避开必需检查
  死锁而刻意删掉的）。

### C-3 R3：钉子写成了黑名单，四种等效过滤器全能绕过

第一版钉子只断言「`paths` 必须为空」。codex R3 指出这是黑名单，并给出四种等效
绕过，**本地全部复现为绿**：

| 绕过写法 | 效果 |
|---|---|
| `paths-ignore: ['scripts/**']` | 重建一模一样的外部输入盲区 |
| `branches: [main]` | 只在目标是 main 的 PR 上跑，其余 PR 静默跳过 |
| `branches-ignore: ['feat/**']` | 按分支排掉一批 PR |
| `types: [closed]` | 只在 PR **关闭**时触发 = 合并前完全不验 |

根因是本仓 memory `feedback_same_predicate_multiple_bypasses`（同一条判据有多种
**正交**的绕过方式）叠加 `feedback_source_guard_text_source_discipline`（禁用
「禁词黑名单」，要用结构判据）。GitHub 在 `on.pull_request` 下支持的键就是
`types` / `branches` / `branches-ignore` / `paths` / `paths-ignore` 五个，每一个都会
让「哪些 PR 会跑」变窄，所以改成**白名单：一个键都不接受**。

将来真需要其中某个（例如用 `types` 去**放宽**触发时机），就改这条判据并写清理由 ——
判据刻意连「放宽」也拒（变异 M11 验证过），让这种改动必须是显式的。

### C-4 R4：钉子住在它自己看守的那道门里（**已接受的残留**）

codex R4 指出：这三条判据跑在 `backend-tests.yml` 自己的 job 里。若有人提一个
**只改该 workflow、且过滤器把该文件自身排除在外**的 PR，那个 PR 上这道 job 根本
不会启动，判据也就不会红；而 `backend pytest (full suite)` 不是必需检查，于是能合。

**核实后对严重程度的修正**：R4 说这会「静默回归」，但 `push: branches: [main]`
没有路径过滤 —— 合并到 main 之后工作流照样跑，钉子在那里变红。所以真实后果是
**「合并后才发现」而不是「永远发现不了」**。

不过这暴露了一个真漏洞：初版钉子只看 `pull_request`，**完全没看 `push`**。同一个
坏改动只要把 `push` 也过滤掉，就真的全静默了。已补第三条判据
`test_push_trigger_is_not_narrowed_by_paths`（`push` 只许有 `branches: [main]`），
把这条退路焊死。变异 5 组验证：push 加 `paths` / 加 `paths-ignore` / 换分支 /
删掉整个 push / push 写成裸的 —— 全红且全走显式断言。

**「合并前就拦住」没有做**，理由与决定见 §F-4。

## D. 落地内容

1. **`.github/workflows/backend-tests.yml`**（trust-boundary，Claude 硬 deny，走 ceremony
   由 user `cp` 落地）：删掉 `pull_request.paths` 整段，加一段注释说明为什么不设过滤器。
2. **`backend/tests/test_backend_tests_workflow_runs_on_every_pr.py`**（新增）：
   钉住这个决定别被悄悄改回去。三条判据：
   - `test_workflow_still_triggers_on_pull_request` —— **防空转**：`pull_request`
     触发器本身必须在。没有这条，整个触发器被删掉时下面那条也会绿，而那种情况比
     有过滤器更糟（后端测试一次都不跑）。
   - `test_push_trigger_is_not_narrowed_by_paths` —— `push` 只许有 `branches: [main]`：
     它是 `pull_request` 触发被绕过时**唯一还能发现问题**的退路（见 §C-4）。
   - `test_pull_request_trigger_is_completely_unfiltered` —— 正题：`pull_request:`
     下面**一个键都不许有**（白名单），不是「只拒 `paths`」（黑名单）。理由见 §C-3。
   解析 `on:` 段时对 PyYAML 的坑做了处理并 fail-closed（见下）。

> 📌 这道钉子**不是** C-1 里被否掉的那套东西。被否的是「靠声明发现外部输入」的
> 259 行机制（有盲区）；这里只有一条无歧义的不变量，没有发现逻辑，也就没有盲区。

### 一个必须记住的解析坑

YAML 1.1 里裸键 `on:` 会被 PyYAML 解析成**布尔 `True`**，不是字符串 `"on"`
（PyYAML 6.0.3 实测）。`doc["on"]` 会 KeyError。两种键都要试，都取不到就**报错**，
不能返回空字典 —— 返回空会让两条判据一起恒真。

## E. 验收清单（非程序员可执行）

> 每条：动作 / 预期 / 判定。判定只填「通过」或「不通过」。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| E1 | 在终端运行 `git -C '.dev/worktree/ci-paths-external' diff --stat main` | 只列出 3 个文件：1 个 workflow、1 个新测试文件、1 个计划文档。**不含**任何已有测试文件 | |
| E2 | 打开 `.github/workflows/backend-tests.yml` | `on:` 段下面**看不到** `paths:` 这一项；`pull_request:` 后面直接就是 `push:` | |
| E3 | 在 worktree 的 `backend` 目录里运行后端全套测试 | 最后一行显示 **1109 passed**（main 是 1106，减掉被删的守卫、加上新钉子那 3 条），且**没有** `failed` / `error` / `skipped` 字样 | |
| E4 | 只运行新钉子那一个文件 | 显示 3 个测试全部通过 | |
| E5 | 临时在 workflow 的 `pull_request:` 下面加回两行 `paths:` 和 `- 'backend/**'`，重跑 E4 | 必须**变红**，报错文字里列出你刚加的那条 | |
| E6 | 把 E5 加的两行删掉，重跑 E4 | 重新全绿 | |
| E5b | 临时在 `pull_request:` 下面加 `    paths-ignore:` 和 `      - 'scripts/**'` 两行，重跑 E4 | 必须**变红**，报错文字里点名 `paths-ignore`（这条最关键：它能重建一模一样的盲区） | |
| E5c | 把 E5b 换成 `    types: [closed]` 一行，重跑 E4 | 必须**变红**，点名 `types` | |
| E5d | 临时在 `push:` 的 `branches: [main]` 下面加 `    paths:` 和 `      - 'backend/**'` 两行，重跑 E4 | 必须**变红**，报错文字说 push 下面出现了 branches 之外的键（这条守的是「合并后兜底」那条退路） | |
| E7 | 临时把整个 `pull_request:` 那一行删掉，重跑 E4 | 必须**变红**（防空转那条：触发器都没了，比有过滤器更糟） | |
| E7b | 临时把 `pull_request:` 改成 `pull_request: 123`，重跑 E4 | 必须**变红**，且报错文字要说「既不是空、也不是映射（实得 int）」——不能是一句看不懂的 `AttributeError` | |
| E8 | 把 E7 删掉的那行加回去，重跑 E4 | 重新全绿 | |
| E9 | PR 开出来后看 GitHub 的检查列表 | 有一项叫 `backend pytest (full suite)`，且是绿的 | |
| E10 | 合并之后，随便找一个**只改 iOS 界面**的新 PR 看它的检查列表 | 也应该有 `backend pytest (full suite)` 在跑 —— 这就是本次改动的正题 | |

E5 / E5b / E5c / E7 是要害：证明这颗钉子真的会变红，不是摆设。E6 / E8 这两条「改回去要重新变绿」
同样不能省 —— 只有「拒了」的档，没法区分「守卫在工作」和「守卫恒红」。

## F. 已知残留

- **F1**：每个 PR 多跑约 2 分钟 CI（本次决策刻意换来的，见 §C-2）。
- **F2**：本次不碰 `hardening_6_gate.yml`（本来就无过滤器）与 `openapi-smoke.yml`
  （只跑单个测试文件、paths 与之对齐，不存在本问题）—— 两者均已核实。
- **F4（codex R4，user 2026-08-31 明确接受）**：**合并前**没有强制拦截。
  一个「只改 `backend-tests.yml`、且过滤器自我排除」的 PR 上，这三条判据不会执行。
  兜底是 `push: branches: [main]`：**合并后 main 会红**（该退路已由第三条判据焊死）。
  - 为什么接受：原 bug 是**被动**的 —— 任何无辜 PR 都会掉进去；F4 需要有人**刻意**
    写一个自我排除的过滤器，而 workflow 文件里已有一整段注释写着别加回来。
  - 要闭合它有两条路，都超出本次范围、且各自应作独立 PR：
    ① 把 `backend pytest (full suite)` 设为分支保护的必需检查（现在无过滤器了，
       这么做是自洽的；**顺带能补上另一个更大的洞** —— 今天后端测试全红也不阻止合并）；
    ② 把这条不变量搬进一道既「必需」又「每个 PR 无条件跑」的门
       （本仓有两道：`codeowners-config-check`、`branch-protection-config-self-check`）。
- **F3**：§B 那套运行期 IO 追踪脚本留在 scratchpad、不进仓库。它 monkeypatch 全套 IO，
  常驻会给上千个测试引入风险，而且 `-k` 选跑时结果不完整、会给出「少报」的假安心。
  取消过滤器后也不再需要它当守卫，只作为将来的人工排查工具。
