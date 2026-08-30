# CI 触发路径补齐：paths 必须覆盖后端套件的全部外部输入

- 日期：2026-08-30
- 分支：`fix/ci-paths-suite-external-inputs`（base = main `1437529`）
- 类别：trust-boundary（改 `.github/workflows/**`）→ 强制 `codex:adversarial-review`
- 前置：PR #175（`test_env_example_coverage.py` 落地）、#178（残留已明写但再次推迟本项）

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

## B. 范围（user 2026-08-30 拍板）

交接单只点名 `scripts/**`。实测（§D）发现**同型的洞有两个**，user 选择一并补掉：

| # | 外部输入 | 谁在读 | 补前状态 |
|---|---|---|---|
| 1 | `scripts/`（递归，当前 30 个 `.sh`） | `test_env_example_coverage.py`：找出真的 `source` 了 `.env` 的脚本，读它自己声明的必需变量列表，与分类表做**双向精确相等**比对 | ❌ 未覆盖 |
| 2 | `ios/Contracts/Sources/KlineTrainerContracts/Models/Models.swift` | `test_qmt_pilot_db.py::test_contract_version_matches_swift_source_of_truth`：跨语言 `CONTRACT_VERSION` 漂移钉 | ❌ 未覆盖 |
| 3 | `tests/contract-fixtures/` | `test_openapi.py` | ✅ 早已覆盖 |
| 4 | `.github/workflows/backend-tests.yml` | 本次新增的守卫自己 | ✅ 早已覆盖 |

第 2 条**刻意只钉那一个文件、不写 `ios/**`**：写 `ios/**` 会让本仓绝大多数 PR
（都在动 iOS）平白多跑一趟后端全套。

**不在本次范围**：`hardening_6_gate.yml` 无 paths 过滤器（当年为避开必需检查死锁刻意
删掉的），`openapi-smoke.yml` 只跑单个测试文件且 paths 与之对齐 —— 两者都不存在本问题。

## C. 落地内容

1. **`.github/workflows/backend-tests.yml`**（trust-boundary，Claude 硬 deny，走 ceremony
   由 user `cp` 落地）：paths 增两条 + 一段说明为什么不能随手删的注释。
2. **`backend/tests/test_ci_paths_cover_external_inputs.py`**（新增，机械守卫）。
3. **三处 `EXTERNAL_INPUTS` 声明**（`test_env_example_coverage.py` /
   `test_qmt_pilot_db.py` / `test_openapi.py`）。

### 守卫的判据形状

```
① 每个测试模块把自己读到的外部输入声明成模块级 EXTERNAL_INPUTS，
   并且【用这个常量本身】去做那次读取；
② 守卫用 AST 静态扫描全部测试模块，收集所有 EXTERNAL_INPUTS；
③ 每一条声明都必须被 workflow 的 paths 覆盖（目录要覆盖到任意深度）。
```

①里「用常量本身去读」是关键：声明因此不可能与该模块的实际行为脱节。有人给
`test_env_example_coverage.py` 加第三个扫描根时，常量一改，③的覆盖要求自动跟着变 ——
守卫不是手抄一张会过期的清单。

**防空转四道**（每一道都对应一种「判据两侧同时缩水、于是恒真」的失效）：

| 道 | 断言 | 兜住的失效 |
|---|---|---|
| a | 至少扫到一条 `EXTERNAL_INPUTS` | AST 扫描器坏掉 → 声明集为空 → ③恒真 |
| b | `paths` 解析出非空列表 | YAML 口径失效 / paths 被整个删掉 → ③恒真 |
| c | 每条声明在磁盘上真实存在 | 陈旧声明：路径不存在时探针怎么拼都能被满足，声明变空话 |
| d | 声明不得落在 `backend/` 里 | 往表里塞内部路径会稀释这张表的含义（`backend/**` 早覆盖了） |

**fail-closed 两处**（不写 `continue`，避免把「判据够不着」伪装成「这里没有目标」）：

- `EXTERNAL_INPUTS` 存在但不是非空字符串字面量序列 → **抛异常**；
- paths 条目含本匹配器建模不了的元字符（`!` 否定式、`[]{}()|+`）→ **抛异常**。

### 匹配器

GitHub 的 paths 语法里 `*` 不跨 `/`、`**` 跨 `/`。守卫把条目翻成正则后，对**目录型**
声明拿两个探针去问：`<dir>/__probe__` 和 `<dir>/__probe_dir__/__probe__`。两个都要过。
这个区分是必须的：`scripts/*` 能过第一探、过不了第二探，而扫描器真的会读
`scripts/governance/*.sh`。

## D. 外部输入是怎么穷尽出来的（复核配方）

**没有靠读代码猜**。做法是给 pytest 挂一个插件，把 `builtins.open` /
`pathlib.Path.{read_text,read_bytes,open}` / `os.{scandir,listdir}` 全部包一层，
记录每一次落在仓库内、且不在 `backend/` 下的访问，然后**真跑一遍全套**。

2026-08-30 在 main `1437529` 上的实测结果：`1106 passed`，命中 74 条记录，
去掉 pytest 自己的 `.pytest_cache` 后，外部输入恰好就是 §B 那四条（`scripts/` 下
30 个 `.sh` 全部被读到 + 3 次目录扫描）。

复核脚本留在 scratchpad（不进仓库，因为它 monkeypatch 全套 IO，常驻会给 1106 个
测试引入风险）。要重跑：写一个 pytest 插件包住上述五个入口把路径记进集合，
`python -m pytest tests/ -q -p <插件名>`，约 35 秒。

### ⚠️ 明写的盲区

一个测试模块如果读了 `backend/` 之外的东西却**没声明** `EXTERNAL_INPUTS`，守卫看不见。

试过用「扫字符串字面量、看它是不是一个存在的仓库相对路径」来无声明地识别，**行不通**：
5 个候选里 3 个是假阳性 —— `"fixtures"` 实际拼到 `backend/tests/fixtures`，
`"scripts"`（`test_pilot_verify_harness.py`）实际拼到 `backend/scripts`，
`"scripts/"`（`test_qmt_pilot_db.py`）根本不是路径拼接而是断言里的子串判断。
锚点表达式在本套件里有四种写法（`__file__.parent` / `parents[1]` / `parents[2]` /
`parents[3]`），靠名字启发式去认锚点属于本仓明令回避的「禁词黑名单」形状。

穷尽的手段就是上面那个运行期追踪，作为**人工复核工具**保留，不做成常驻守卫。

## E. 验收清单（非程序员可执行）

> 每条：动作 / 预期 / 判定。判定只填「通过」或「不通过」。

| # | 动作 | 预期 | 通过 / 不通过 |
|---|---|---|---|
| E1 | 在终端进入仓库，运行 `git -C '.dev/worktree/ci-paths-external' diff --stat main` | 只列出 5 个文件：1 个 workflow、3 个已有测试文件、1 个新测试文件；没有其它文件 | |
| E2 | 打开 `.github/workflows/backend-tests.yml`，看 `paths:` 那一段 | 能看到 `- 'scripts/**'` 和那一行很长的 `Models.swift` 路径，各一条 | |
| E3 | 在 worktree 的 `backend` 目录里运行后端全套测试 | 最后一行显示全部通过，数量不少于 1120，且**没有** `failed` / `error` / `skipped` 字样 | |
| E4 | 只运行新守卫那一个文件 | 显示 18 个测试全部通过 | |
| E5 | 临时把 workflow 里 `- 'scripts/**'` 那一行删掉，重跑 E4 | 必须**变红**，且报错文字里点名 `scripts` 没被覆盖 | |
| E6 | 把 E5 删掉的那一行加回去，重跑 E4 | 重新全绿 | |
| E7 | 临时把 `- 'scripts/**'` 改成 `- 'scripts/*'`（两颗星改一颗），重跑 E4 | 必须**变红**（一颗星管不到 `scripts/governance/` 那一层子目录） | |
| E8 | 把 E7 改的那一行改回两颗星，重跑 E4 | 重新全绿 | |
| E9 | PR 开出来后看 GitHub 的检查列表 | 有一项叫 `backend pytest (full suite)`，且是绿的 | |

E5/E7 是这份改动的**要害**：它们证明这道守卫真的会因为 paths 漂移而变红，
而不是一个永远绿着的摆设。两条都必须亲手做一次，不能只看代码推断。

## F. 已知残留

- **F1**：`.github/workflows/backend-tests.yml` 的 paths 仍未含 `.claude/**` 等治理文件 ——
  后端套件不读它们，不是本判据的范围。
- **F2**：§D 的盲区（未声明的外部输入）——用运行期追踪人工复核，不常驻。
- **F3**：本次不碰 `hardening_6_gate.yml` / `openapi-smoke.yml`（§B 已核实两者无此问题）。
