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
**文件不存在时回退到一份公共的「全 Passed」样本** ⇒ 现有 23 个 fixture **一个都不用改**。

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
echo "=== ④ 两种框架能否分开计数 ==="
grep -oE "✔ Test run with [0-9]+ tests" /tmp/catalyst-build.log | head -1
grep -cE "Executed [0-9]+ tests?, with" /tmp/catalyst-build.log
```

⚠️ 同步加 `-resultBundlePath /tmp/catalyst.xcresult`（否则 ② 必然无包可读）。
⛔ **不动任何判据**，`catalyst-gate.sh` 这一步零改动。

- [ ] **Step 2：ceremony —— user `cp` 落地**，给出 diff 与 md5 自校
- [ ] **Step 3：push + 开 PR（标题带「探针·勿合」），等 CI 跑完**
- [ ] **Step 4：读 CI 输出，把四项答案抄回 spec**

判绿：拿到 ①②③④ 四项**真实输出**。
⛔ 不是「CI 绿了」—— 探针是纯打印，它绿不代表答案是想要的那个。

- [ ] **Step 5：按答案分叉**
  - ② 退出码非 0（子命令不存在）⇒ **整个 §3 作废**，回 spec 改走「解转义 + 额外防伪造」，本 plan 重写；
  - ④ 无法分开计数 ⇒ 按 spec §7 R1 的 (a) 收口：**G7 继续读文本**（它不是受害者），本片只治 G8；
  - 都顺利 ⇒ 继续 Task 2。
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
- [ ] **Step 5：跑，四档转绿**；再跑一次现有 23 档，确认**一个都没被弄红**
- [ ] **Step 6：提交**

判绿：`bash .github/scripts/catalyst-gate.test.sh` 全绿且档位数 = 原数 + 4。

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
- [ ] **Step 5：跑，全绿**；现有 23 档仍全绿
- [ ] **Step 6：提交**

---

## Task 5 · G7（按 Task 1 Step 5 的分叉处理）

- [ ] **Step 1**：若④顺利 —— 加 M4，改 G7 从包里**只取 swift-testing 那部分**计数，保持 1935 与 ±delta 语义
- [ ] **Step 1′**：若④不顺 —— **G7 不动**，在闸门该处加注释写明「它读文本是刻意的：
      汇总行是 ASCII + 数字，不受劈字影响；受害者只有 G8」，并在 spec §7 R1 标记为已采纳
- [ ] **Step 2**：跑，全绿
- [ ] **Step 3**：提交

---

## Task 6 · workflow 加 `-resultBundlePath`（ceremony）

- [ ] **Step 1**：写新 `catalyst-build.yml` 到 `/tmp`，打印 diff + md5
- [ ] **Step 2**：user `cp` 落地，核 md5 一致、`git diff --stat` 只此一文件
- [ ] **Step 3**：核对 job 名**逐字未变**（它是必需检查的 context；改名 ⇒ 全仓 PR 卡死）
- [ ] **Step 4**：提交

---

## Task 7 · 全矩阵 + 三道闸门

- [ ] **Step 1**：跑完整 M0–M9（含 M5a/M5b 两档对照），逐档记录「红/绿 + 红在哪条判据」
- [ ] **Step 2**：跑 `bash .github/scripts/catalyst-gate.test.sh`（档位全绿）
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
  §6 → Task 3/4/5/7；§6.1 → Task 4 Step 1 的 M5a/M5b；§7 R1 → Task 5 Step 1′；§8 → Task 1。
- ⛔ 本计划**刻意不内嵌闸门最终代码**：本仓 `feedback_plan_code_blocks_cause_vacuous_tests`
  记过「计划代码块是恒真测试的根因」，且上一条治理线实证过「plan 复制交付代码 = 造第二份真相，
  后续必失同步」。⇒ 这里只写**行为与期望输出**，代码以交付态文件为准。
  Task 1 的探针脚本是例外：它是**一次性丢弃物**，不会成为第二份真相。
