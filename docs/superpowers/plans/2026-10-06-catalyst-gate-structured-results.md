# Catalyst 闸门改读结构化结果 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 用 `superpowers:subagent-driven-development`（推荐）
> 或 `superpowers:executing-plans` 逐 Task 执行。步骤用 `- [ ]` 勾选框跟踪。

**Goal:** 让 `catalyst-gate.sh` 的 G7/G8 两条判据不再依赖会被并发劈字污染的 stdout 文本，从而消除随机假红。

**Architecture:** `xcodebuild` 额外产出结构化结果包；G7/G8 改从包里读「测试名 + 结果」。
其余六条判据继续读文本日志、一行不动。注入缝沿用仓内既有模式（环境变量 + 默认值）。

**Tech Stack:** bash（闸门）· `xcrun xcresulttool`（取数）· `python3`（解析，闸门已依赖）· GitHub Actions（macos-15）

**Spec:** `docs/superpowers/specs/2026-10-06-catalyst-gate-structured-results-design.md`（codex 三轮 approve，账本 `0fa760ee`）

## Global Constraints

逐条抄自 spec，值不得改写：

1. **只改 G7/G8 两条判据**。其余六条（`TEST SUCCEEDED` / 编译器 error / `Sources/` 零警告 /
   测试 target 被编译 / `macabi` 标记 / 总数 ±delta）**一行不动**（spec §2）。
2. **不新增运行时依赖**：解析用 `python3`（闸门 `:106` 已依赖），⛔ 不引入 `jq`（spec §3）。
3. **`result` 判据必须是白名单**：只有 `"Passed"` 算通过。⛔ 不许写「不等于 Failed 就算过」（spec §4.2）。
4. **⛔ 不许把判据写成「日志里不许有转义」**（spec §4.3）。判据问的是「被逐条匹配的那个名字有没有被破坏」。
5. **不改** `catalyst-uikit-baseline.txt`（80 条）与 `catalyst-total-baseline.txt`（1935）（spec §4.1）。
6. **`.github/workflows/**` 对 Claude 硬 deny** ⇒ 走 ceremony：写 `/tmp` → user `cp`。⛔ 不许用 heredoc 绕过。
7. 本仓 CI 是 **macos-15 / Xcode 16**；本机是 **Xcode 27**。⛔ 本机绿不能当 CI 绿（spec §4.4）。

### ⚠️ 判绿口径（本片所有 Task 共用，⛔ 不许各写一套）

**唯一权威 = 测试台自己打印的末行** `结果：N 通过，M 失败`。判绿条件两条：

1. **`M = 0`**；
2. **`N ≥ 开工基线`**。⚠️ 开工基线 = **2026-10-07 实跑所得 `38`**
   （不是 20，也不是 23 —— 见下方「三个数的区别」）。

⛔ **不许用 grep 推算档位数当判据。** 本片已为此连错三次：
`fixtures/` 下有 **23 个文件**（含非 `.log`）、**20 份 `.log`**、`20` 个 `expect` 行，
而测试台实报 **38** 条断言（另外 18 条是内联的 fail-closed / TMPDIR / 结构性回归等）。
三个数都"对"，但只有 **38** 是「有多少条断言在跑」的答案。
依据：`feedback_derived_counts_rot_faster_than_totals`（派生数比总数更会变错且更隐蔽
⇒ **要么现场量，要么别写**）。

⇒ 每个 Task 的判绿一律写成：**跑测试台 → 读末行 → `M=0` 且 `N` 比上一 Task 增加了预期条数**。
⛔ 不写「XX 档全绿」。

---

## File Structure

| 文件 | 职责 | 本片动作 |
|---|---|---|
| `.github/workflows/catalyst-build.yml` | 跑 Catalyst 测试 + 调闸门 | 加 `-resultBundlePath`（Task 6，ceremony） |
| `.github/scripts/catalyst-gate.sh` | 八道判据 | G7/G8 改读结构化结果（Task 4/5） |
| `.github/scripts/catalyst-result-tests.sh`（新建） | 取数：跑 `xcresulttool` 输出 JSON | 新建（Task 3）。**单一职责**：只取数不判断，这样测试能换掉它 |
| `.github/scripts/catalyst-gate.test.sh` | 闸门自测（已在闸门上岗前执行，`catalyst-build.yml:51`） | 加 M0–M9 档位（Task 3/4/5/7） |
| `.github/scripts/fixtures/*.tests.json`（新建） | 结构化结果样本 | 新建若干（Task 3） |
| `docs/acceptance/2026-10-??-…md` | 非程序员可执行验收清单（治理条款必备件） | Task 8 |

**注入缝设计**（沿用 `UIKIT_EXPECTED_TESTS_SCRIPT` 的既有模式，⛔ 不发明新花样）：

- 闸门读 `CATALYST_RESULT_TESTS_SCRIPT`，默认 `.github/scripts/catalyst-result-tests.sh`；
- 该脚本 stdout 吐 JSON；闸门只消费 stdout，**不关心它从哪来**；
- 测试台把它指向一个「cat 对应 fixture JSON」的桩 ⇒ **不需要把二进制 `.xcresult` 包签进 git**。

**fixture 配对规则**：日志 `<name>.log` 的结构化样本是 `<name>.tests.json`；
文件不存在时回退到一份公共的「全 Passed」样本。

⚠️ **但「现有 fixture 一个都不用改」是错的**（codex plan-R1 指出，实核属实）。
公共「全 Passed」样本会把**本该缺失的节点补回来** ⇒ 依赖 G8 的既有**负向**档位
会被正确实现判成通过，而它们期望 `exit 1` ⇒ **判别力归零**。

实核 `catalyst-gate.test.sh` 的 20 个档位，**必须配专属 JSON 的只有 2 档**：

| 档位 | 现断言 | 要配的 JSON |
|---|---|---|
| `missing-one-uikit-test.log:315` | exit 1 + 点名 `§5.3 #15 registered tool render called once with passed-through drawing` | **去掉**该测试的节点 |
| `stdout-spoof.log:326` | exit 1 + 点名 `§5.3 #14 drawDrawings with empty list calls no render` | **去掉**该测试的节点（其余保留，与它「删真 ✔ 行 + 插伪造文本」的原意一致） |

其余 18 档的断言都**不经过 G8**（`TEST SUCCEEDED` / 编译 error / 警告 / target 标记 /
macabi / 汇总行 / 用例数上下限 …）⇒ 用公共「全 Passed」样本即可，**不用改**。

⇒ 公共样本**只给与结构化判据无关的档位**；凡断言里出现「UIKit-gated 测试未执行」的，
一律配专属 JSON。这条规则本身要在 Task 3 加一档测试钉住（见该 Task）。

**G7 相关的 5 档不受影响** —— 因为 spec §4.1 已决定 **G7 不迁移**（它不是受害者，
且迁移会连带搞坏这 5 档）。

---

## Task 1 · CI 探针（丢弃型 PR，⛔ 不写任何判据代码）

spec §8 的硬要求。两个假设必须由 **CI 自己**回答，不是本机。

- [ ] **Step 1：写探针步骤到 `/tmp`**

只往 `catalyst-build.yml` 的 `xcodebuild test` 之后插**一个纯打印步骤**，内容四项：

```
echo "=== ① CI 实际版本 ==="
xcodebuild -version; xcrun xcresulttool version
echo "=== ② 子命令是否存在（看退出码，别看有没有输出）==="
xcrun xcresulttool get test-results tests --path /tmp/catalyst.xcresult --format json >/tmp/t.json; echo "exit=$?"
echo "=== ③ 字段名与中文是否完好 ==="
python3 -c 'import json,collections;d=json.load(open("/tmp/t.json"));c=collections.Counter();\
ns=[]\
;
def w(n):
    if isinstance(n,dict):
        if "nodeType" in n: c[n["nodeType"]]+=1
        if n.get("nodeType")=="Test Case" and any(ord(ch)>127 for ch in n.get("name","")): ns.append(n)
        [w(v) for v in n.values()]
    elif isinstance(n,list): [w(v) for v in n]
w(d); print("nodeType 分布:",dict(c)); print("含中文节点样例:",json.dumps(ns[0],ensure_ascii=False) if ns else "无")'
echo "=== ④ 结果包本身能否区分两种框架（⛔ 必须解析 JSON，不许只 grep 文本）==="
python3 -c 'import json,collections;d=json.load(open("/tmp/t.json"))
rows=[]
def w(n,path=()):
    if isinstance(n,dict):
        if n.get("nodeType")=="Test Case": rows.append((path,sorted(n.keys()),n.get("name","")))
        for k,v in n.items(): w(v,path+(k if k!="children" else n.get("name",k),))
    elif isinstance(n,list):
        for v in n: w(v,path)
w(d)
print("Test Case 节点总数:",len(rows))
print("节点字段名全集:",sorted({k for _,ks,_ in rows for k in ks}))
paths=collections.Counter(p[-3:] for p,_,_ in rows)
print("前 6 种树路径尾段（看有没有框架维度）:")
[print("   ",c,p) for p,c in paths.most_common(6)]'
echo "--- 同次运行的文本计数，用于交叉核对 ---"
grep -oE "✔ Test run with [0-9]+ tests" /tmp/catalyst-build.log | head -1
echo "XCTest 汇总行数: $(grep -cE 'Executed [0-9]+ tests?, with' /tmp/catalyst-build.log)"
```

⚠️ ④ 的判绿标准：**从 JSON 里指出「哪个字段或哪段树路径能区分框架」，并给出两类节点各自的计数，
再与同次运行的文本计数交叉核对**。
⛔ 只拿到两个「不一样的数」**不算回答** —— 那只证明口径不同，不证明包里分得开。
（初版 ④ 就是只 grep 文本，被 codex plan-R1 判为「无法回答该假设」，属实。）
ℹ️ 注：spec §4.1 修订后 **G7 已决定不迁移** ⇒ ④ 的答案**不再决定分叉**，
但仍要跑：它是将来万一要迁 G7 的现成素材，且成本只是多打印几行。

⚠️ 同步加 `-resultBundlePath /tmp/catalyst.xcresult`（否则 ② 必然无包可读）。
⛔ **不动任何判据**，`catalyst-gate.sh` 这一步零改动。

- [ ] **Step 2：ceremony —— user `cp` 落地**，给出 diff 与 md5 自校
- [ ] **Step 3：push + 开 PR（标题带「探针·勿合」），等 CI 跑完**
- [ ] **Step 4：读 CI 输出，把四项答案抄回 spec**

判绿：拿到 ①②③④ 四项**真实输出**。
⛔ 不是「CI 绿了」—— 探针是纯打印，它绿不代表答案是想要的那个。

- [ ] **Step 5：按答案分叉（只剩一条真分叉）**
  - **② 退出码非 0（子命令在 Xcode 16 上不存在）⇒ 整个 §3 作废**，回 spec 改走
    「解转义 + 额外设计防伪造」，本 plan 重写。这是唯一的致命分叉。
  - **③ 字段名与 Xcode 27 不同** ⇒ 不致命，但 Task 4 取字段的路径要按 CI 的实际结构写，
    ⛔ 不许照搬本机 spike 的字段名。
  - **④ 无论什么答案都不再分叉** —— spec §4.1 修订后 G7 已决定不迁移。④ 只作素材留档。
  - 以上都顺利 ⇒ 继续 Task 2。
- [ ] **Step 6：关掉探针 PR、删分支**（⛔ 不合）

---

## Task 2 · 按探针结论定稿 spec

- [ ] **Step 1**：把四项真实输出写进 spec §4.1 / §4.4，删掉「未实测」字样
- [ ] **Step 2**：若触发 Step 5 任一分叉，改 spec 对应小节并重跑 codex 评审
- [ ] **Step 3**：提交

判绿：`grep -n "未实测\|尚未实测\|未验证假设" <spec>` **零命中**（并先证明该 grep 能报非 0）。

---

## Task 3 · 取数脚本 + fixture 基建（先把「能喂数据」做出来）

- [ ] **Step 1：写失败的测试**

在 `catalyst-gate.test.sh` 加 **M8 三档 + M9**（此时闸门还没改，**必然失败** —— 这是要看的红）：

| 档 | fixture 侧条件 | 期望 |
|---|---|---|
| M8a | 取数脚本退出码非 0 | exit 1，输出含「结构化结果取数失败」 |
| M8b | 取数脚本输出空 | exit 1，含「结构化结果为空」 |
| M8c | 输出不是合法 JSON | exit 1，含「结构化结果解析失败」 |
| M9 | JSON 合法但**零个 `Test Case` 节点** | exit 1，含「结构化结果里没有任何测试节点」 |

- [ ] **Step 2：跑，确认四档都红**，且红的理由是「闸门还没有这条判据」而非别的
- [ ] **Step 3：建 `catalyst-result-tests.sh`**（只取数：跑 `xcresulttool`，stdout 吐 JSON，失败非 0 退出）
- [ ] **Step 4：闸门加 fail-closed 前置**（取数失败/空/非法 JSON/零节点 → `fail`），不加任何名字匹配
- [ ] **Step 5：加一档元测试钉住 fixture 配对规则本身**

公共「全 Passed」样本只许给**不经过 G8** 的档位 —— 这条规则靠人记得就会漂。
⇒ 加一档**对测试台自身的静态检查**：断言「凡 `expect 1 … UIKit-gated 测试未执行` 的 fixture，
都存在同名 `.tests.json`」。将来有人加 G8 负向档位却忘配 JSON，这一档会红。

- [ ] **Step 6：跑测试台，读末行**。预期 `M=0` 且 `N = 38 + 5`（M8a/b/c + M9 + 元测试）
- [ ] **Step 7：提交**

判绿：见上方「判绿口径」—— 跑测试台读末行，`M=0` 且 `N` 比开工基线 38 增加 5。

---

## Task 4 · G8 改读结构化结果

- [ ] **Step 1：写失败的测试** —— M1 / M2 / M3 / M5a / M5b / M6 / M7（见 spec §6）

⚠️ **M6 的样本造法**（spec §6 已写明，不得含糊）：取 2026-10-06 那份**真日志**，
把其中**某条 baseline 测试**的 ✔ 行里一个非 ASCII 字符按**真实形态**替换成 `\NNN`；
保留原始日志作对照。⛔ 提交信息与 fixture 注释里都**不许**称它是「捕获到的真实假红样本」。

⚠️ **M5b 不可省** —— 它是「没制造新假红」那一半证据。只有 M5a 的话，
一个「见到伪造文本就判红」的错实现也能过关（spec §6.1）。

- [ ] **Step 2：跑，确认每档红在预期那一条判据上**（归因单独核，⛔ 别只看退出码）
- [ ] **Step 3：改 G8** —— 从 JSON 取 `nodeType == "Test Case"` 的节点，按 `name` 对 baseline 80 条逐条找，
      要求存在且 `result == "Passed"`（白名单，Global Constraint 3）。失败信息**必须点名**那条测试。
- [ ] **Step 4：删掉 G8 的文本匹配**（`match_str` / `grep -qF` 那一段）
- [ ] **Step 5：跑测试台，读末行**。预期 `M=0` 且 `N` 比 Task 3 末态再增加 7（M1/M2/M3/M5a/M5b/M6/M7）
- [ ] **Step 6：提交**

---

## Task 5 · G7 **明确不迁移**（spec §4.1 已定，不再是分叉）

G7 继续读文本汇总行。本 Task 只做两件小事，⛔ 不改 G7 的判据逻辑。

- [ ] **Step 1：在 G7 处加注释**写明这是**刻意**的，三条理由逐条抄 spec §4.1（不另创措辞）：
      ① 汇总行除 `✔` 外全是 ASCII 与数字、**没有测试名** ⇒ 劈字伤不到它，受害者只有 G8；
      ② 迁移它会连带搞坏 5 档既有负向回归（那些变异加在文本上）；
      ③ 不迁移就不必处理 1935 vs 2054 的口径差。
      ⚠️ 这条注释是**防回归**的：下一个读到「G8 读结构化、G7 读文本」的人会觉得不一致、想顺手统一。
- [ ] **Step 2：加一档测试钉住「G7 仍读文本」** —— 取一份既有 G7 负向 fixture
      （如 `missing-summary-line.log`），**同时**给它配一份「全 Passed、计数正常」的 `.tests.json`。
      期望仍是 exit 1 + 「找不到 swift-testing 汇总行」。
      ⇒ 有人把 G7 改成读 JSON，这一档会立刻变绿 = 红旗。**这是 Step 1 注释的机械化版本。**
- [ ] **Step 3**：跑，全绿
- [ ] **Step 4**：提交

---

## Task 6 · workflow 加 `-resultBundlePath`（ceremony）

- [ ] **Step 1**：写新 `catalyst-build.yml` 到 `/tmp`，打印 diff + md5
- [ ] **Step 2**：user `cp` 落地，核 md5 一致、`git diff --stat` 只此一文件
- [ ] **Step 3**：核对 job 名**逐字未变**（它是必需检查的 context；改名 ⇒ 全仓 PR 卡死）
- [ ] **Step 4**：提交

---

## Task 7 · 全矩阵 + 三道闸门

- [ ] **Step 1**：跑完整 M0–M9（含 M5a/M5b 两档对照），逐档记录「红/绿 + 红在哪条判据」
- [ ] **Step 2**：跑 `bash .github/scripts/catalyst-gate.test.sh`，读末行：`M=0`，并把 `N` 的终值记进验收清单
- [ ] **Step 3**：本机真跑一次 Catalyst（带 `-resultBundlePath`），用真包跑闸门 ⇒ `GATE PASS`
- [ ] **Step 4**：⚠️ **本机绿 ≠ CI 绿**（Global Constraint 7）⇒ 这一步只是必要条件，CI 由 PR 验
- [ ] **Step 5**：提交

---

## Task 8 · 验收清单 + 整支评审 + PR

- [ ] **Step 1**：写 `docs/acceptance/<交付日>-catalyst-gate-structured-results.md`
      （动作 / 预期 / 通过-不通过；中文；非程序员可执行；禁用语见 `.claude/workflow-rules.json`）
- [ ] **Step 2**：整支 codex 对抗性评审（`--scope branch-diff --head <本分支> --base origin/main`）
- [ ] **Step 3**：收敛后拿 approve，**Read 账本**核 `head_sha` 吻合、无 `override`、无 `focus`
- [ ] **Step 4**：push + 开 PR（ceremony：user 跑裸命令）
- [ ] **Step 5**：**要害验证** —— 另开一个丢弃型 PR，把某条 baseline 测试的 ✔ 行在**真 CI** 上做成转义态，
      确认闸门**不再**假红；看完即关
      ⚠️ 若无法在 CI 上可控地制造转义（它是竞态），此步降级为：
      在 CI 上跑一次带 `-resultBundlePath` 的真构建，确认 G8 走的是结构化路径
      （输出里出现结构化判据的专属字样），**并在验收清单里如实写明这一步只做到了这个程度**

---

## 自查（写完后对着 spec 过一遍）

- spec 覆盖：§2 非目标 → Global Constraint 1；§3 → Task 4/5/6；§4.1 → Task 5 分叉；
  §4.2 → Global Constraint 3 + M2/M3；§4.3 → Global Constraint 4 + M7；§4.4 → Task 1；
  §6 → Task 3/4/5/7；§6.1 → Task 4 Step 1 的 M5a/M5b；§7 R1 → **已升为 §4.1 的默认决定** ⇒ Task 5；§8 → Task 1。
- ⛔ 本计划**刻意不内嵌闸门最终代码**：本仓 `feedback_plan_code_blocks_cause_vacuous_tests`
  记过「计划代码块是恒真测试的根因」，且上一条治理线实证过「plan 复制交付代码 = 造第二份真相，
  后续必失同步」。⇒ 这里只写**行为与期望输出**，代码以交付态文件为准。
  Task 1 的探针脚本是例外：它是**一次性丢弃物**，不会成为第二份真相。
