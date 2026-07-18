# Catalyst 闸门基线漂移修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Catalyst 闸门自测的 total 基线照 UIKit 侧成熟模式解耦，再把活基线重设到 main 真实值（35/1457），让必需门 `Mac Catalyst build-for-testing on macos-15` 在 main 转绿，且不削弱门的防护。

**Architecture:** 自测 fixture 的 total 基线冻结在 `fixtures/total-baseline-frozen.txt`（1407，配套现有 fixture 日志），通过已存在的 `CATALYST_TOTAL_BASELINE_FILE` 注入点喂给所有 `expect` 调用；活 `catalyst-total-baseline.txt`（1457）与 `catalyst-uikit-baseline.txt`（35）只服务真 CI 构建。这镜像了 UIKit 侧早已用 `fixtures/uikit-expected-tests-frozen.py` + `UIKIT_EXPECTED_TESTS_SCRIPT` 做的解耦（codex R6）。

**Tech Stack:** bash（macOS 自带 bash 3.2 兼容）、Python 3（`uikit-expected-tests.py`）、GitHub Actions。全部在 `.github/scripts/`。

## Global Constraints

- 所有改动只在 `.github/scripts/**`（trust-boundary + codeowners_required_globs）。
- **不改** fixture 日志内容（保真度：真实抓取的裁剪件）。
- **不改** `fixtures/uikit-expected-tests-frozen.py`（冻结 28，配套 fixture 日志的 UIKit 结果行）。
- **不动** `catalyst-build.yml` 的 job 显示名 / scheme / 动作。
- bash 3.2 兼容：无 mapfile / 无关联数组；`$var` 紧跟全角标点加 `${}`。
- 每个 task 的验证判据 = `bash .github/scripts/catalyst-gate.test.sh` 退出码与通过计数；活基线 vs 真构建的验证在最后「Verification（orchestrator 跑）」段。
- 冻结值取 **1407**（= 现有 total fixture 全部围绕的值），故 total fixture **零重裁**。

---

### Task 1: 解耦自测 total 基线（行为保持）

把自测 fixture 的 total 基线从"读活 `catalyst-total-baseline.txt`"改成"读冻结的 `fixtures/total-baseline-frozen.txt`"。本 task **不改活基线值**（仍 1407），故自测**逐条 verdict 保持不变**。**注意本分支起点状态**：分支基于 main（活 uikit 基线 28 vs 源码 35），Task 1 前自测已是 **35 通过 / 1 失败**——唯一失败是 F1「UIKit-gated 期望清单一致性」，那是 **Task 2 才修**的、与本 task 无关。故 Task 1 后必须**仍是 35/1**，且所有 total 基线相关断言逐条 verdict 不变（这才证明冻结 1407==活 1407 的解耦行为保持、没引入回归）。

**Files:**
- Create: `.github/scripts/fixtures/total-baseline-frozen.txt`
- Modify: `.github/scripts/catalyst-gate.test.sh`（在 :243 `export UIKIT_EXPECTED_TESTS_SCRIPT=…` 旁加一行 export + 注释）

**Interfaces:**
- Consumes: `catalyst-gate.sh` 已有的 `CATALYST_TOTAL_BASELINE_FILE` 环境注入点（`catalyst-gate.sh:214`）。
- Produces: 冻结基线文件路径 `$FIX/total-baseline-frozen.txt`，供后续所有 `expect` 调用继承。

- [ ] **Step 1: 建冻结基线 fixture**

```bash
printf '1407\n' > .github/scripts/fixtures/total-baseline-frozen.txt
```

- [ ] **Step 2: 在自测里注入冻结基线（紧挨 UIKit 那句 export）**

在 `.github/scripts/catalyst-gate.test.sh` 第 243 行 `export UIKIT_EXPECTED_TESTS_SCRIPT="$FIX/uikit-expected-tests-frozen.py"` 之后，新增：

```bash
# total 基线同理解耦（2026-07-18）：下面的 fixture 用例测的是「G7 total 判据逻辑」，
# 不是「main 当前真实总数」。若让它们读活 catalyst-total-baseline.txt，任何大幅增减
# 测试的 PR（如 #146 加 50 个）把活基线一挪，这些围绕 1407 构造的 fixture 就整片掉出
# delta 窗口、自测在真跑之前先崩（复现：main 6068522 F1 变红事故）。改用一份跟 fixture
# 日志配套、冻结在提交历史里的 total 基线（fixtures/total-baseline-frozen.txt=1407），
# 通过 catalyst-gate.sh 已有的 CATALYST_TOTAL_BASELINE_FILE 注入点喂给下面所有 expect。
# 真实 xcodebuild 日志（workflow 真跑）不设这个环境变量，仍走默认的活 catalyst-total-
# baseline.txt——活基线的保护完全没丢（见文件末尾独立说明 + 本 PR Verification 段）。
export CATALYST_TOTAL_BASELINE_FILE="$FIX/total-baseline-frozen.txt"
```

- [ ] **Step 3: 跑自测，必须仍 35/1（行为保持；F1 是 Task 2 才修的 pre-existing 失败）**

Run: `bash .github/scripts/catalyst-gate.test.sh`
Expected: 末行 `结果：35 通过，1 失败`。唯一失败是 F1「UIKit-gated 期望测试清单基线一致性检测」（活 uikit 基线 28 vs 源码 35，Task 2 修）；所有 **total 基线相关断言**（pass-new-scheme / pass-ci-format / total-baseline-within/below/above-delta / too-few-tests）逐条与改动前 verdict 一致（都 ok）。这证明冻结 1407==活 1407 的解耦行为保持。

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/fixtures/total-baseline-frozen.txt .github/scripts/catalyst-gate.test.sh
git commit -m "ci: 解耦 Catalyst 自测 total 基线（冻结 fixtures/total-baseline-frozen.txt=1407，行为保持）"
```

---

### Task 2: 重设活基线到 main 真实值（35/1457）

把活 `catalyst-uikit-baseline.txt`（28→35）和活 `catalyst-total-baseline.txt`（1407→1457）更新到 main `6068522` 的真实值。因 Task 1 已把 fixture 解耦到冻结 1407，本 task 不会打破那 5 个 total fixture；F1 uikit 一致性检测（读活基线 vs 活源码）此时 35==35 转绿。

**Files:**
- Modify: `.github/scripts/catalyst-uikit-baseline.txt`（28 行 → 35 行，`uikit-expected-tests.py` 确定性重生成）
- Modify: `.github/scripts/catalyst-total-baseline.txt`（`1407` → `1457`）

**Interfaces:**
- Consumes: `uikit-expected-tests.py` 对 main 源码的确定性推导（35 名）。
- Produces: 活基线 35/1457，仅被真 CI 构建的 `catalyst-gate.sh` 默认路径消费。

- [ ] **Step 1: 确定性重生成 uikit 活基线**

```bash
python3 .github/scripts/uikit-expected-tests.py > .github/scripts/catalyst-uikit-baseline.txt
```
Expected: 文件变 35 行（`wc -l < .github/scripts/catalyst-uikit-baseline.txt` == 35）。

- [ ] **Step 2: 更新 total 活基线到 1457**

```bash
printf '1457\n' > .github/scripts/catalyst-total-baseline.txt
```

- [ ] **Step 3: 跑自测，必须 36/36（F1 uikit 转绿 + total fixture 走冻结不受影响）**

Run: `bash .github/scripts/catalyst-gate.test.sh`
Expected: 末行 `结果：36 通过，0 失败`，退出码 0。特别是 F1 那条从 FAIL 变 `ok — 当前源码推导出的 35 个测试名与基线 catalyst-uikit-baseline.txt 完全一致`。

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/catalyst-uikit-baseline.txt .github/scripts/catalyst-total-baseline.txt
git commit -m "ci: Catalyst 活基线重设到 main 真实值（uikit 28→35 / total 1407→1457；#146 加 50 测试后同步）"
```

---

### Task 3: 活基线覆盖 fixture + 自测用例（codex plan R1 [high]）

解耦后活 `catalyst-total-baseline.txt`(1457) / `catalyst-uikit-baseline.txt`(35) 不被上面任何走冻结基线的 fixture 用例覆盖——误设/漂移只会在真 CI 的真构建步暴露，reviewer 也无法从仓库状态复现 1457。补一份代表当前 main 的裁剪真日志 fixture + 一条**显式 unset 冻结覆盖、走活基线**的自测用例，给活基线自动化覆盖 + 可复现。

**Files:**
- Create: `.github/scripts/fixtures/pass-main-current.log`（从真 main Catalyst 构建日志裁剪；保真=只摘真实行）
- Modify: `.github/scripts/catalyst-gate.test.sh`（在冻结 fixture 判据断言块之后新增一条）

**Interfaces:**
- Consumes: 活 `catalyst-uikit-baseline.txt`(35) + 活 `catalyst-total-baseline.txt`(1457)（`catalyst-gate.sh` 默认路径，即不设两个 `*_SCRIPT`/`*_FILE` 环境变量时）。
- Produces: 无。

- [ ] **Step 1: 从真 main 构建日志裁出 fixture（保真，只摘真实行）**

fixture 必须含且只含从一次真 `xcodebuild test`（当前 main，Catalyst destination）里摘出的**真实**行：`** TEST SUCCEEDED **` 那行、`✔ Test run with 1457 tests in 188 suites passed …` 汇总行、活 `catalyst-uikit-baseline.txt` 里 35 个测试各自的 `✔ Test "<名>" passed after …` 结果行、≥1 行含 `macabi`、≥1 行 `Tests/KlineTrainerContractsTests/` 源码路径。**不得手打伪造行**（R9 锚定 ✔ 结果行正是防这个）。orchestrator 已抓取全量真日志，裁剪时用 `grep` 从真日志摘上述行、不改字。

- [ ] **Step 2: 加走活基线的自测用例**

在 `.github/scripts/catalyst-gate.test.sh` 的「catalyst-gate.sh 判据测试」冻结 fixture 断言块之后（`total-baseline-above-delta.log` 那条 `expect` 之后，约 :360），新增：

```bash
# 活基线覆盖（codex plan R1 [high]，2026-07-18）：上面所有 fixture 用例都走冻结基线
# （UIKIT_EXPECTED_TESTS_SCRIPT + CATALYST_TOTAL_BASELINE_FILE 两个 export），因此活
# catalyst-total-baseline.txt / catalyst-uikit-baseline.txt 不被它们覆盖——误设/漂移只会
# 在真 CI 的真构建步暴露、reviewer 无法从仓库状态复现。这条**显式 unset 两个冻结覆盖**、
# 走 catalyst-gate.sh 默认的活基线，对一份代表当前 main 的裁剪真日志（pass-main-current.log：
# 1457 tests / 35 UIKit / macabi）断言 GATE PASS 且回显 1457。活基线一旦被误改（漂出 ±30），
# 这条会在 Gate self-test 步就红，早于真构建步。
out=$(env -u UIKIT_EXPECTED_TESTS_SCRIPT -u CATALYST_TOTAL_BASELINE_FILE bash "$GATE" "$FIX/pass-main-current.log" 2>&1)
got=$?
if [ "$got" -eq 0 ] && grep -qF "GATE PASS" <<<"$out" && grep -qF "1457" <<<"$out"; then
    echo "  ok   — 活基线覆盖：代表当前 main 的真日志经活基线（uikit 35 / total 1457）→ GATE PASS 且回显 1457 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 活基线覆盖本该 GATE PASS 且回显 1457，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
```

- [ ] **Step 3: 跑自测，必须 37/37**

Run: `bash .github/scripts/catalyst-gate.test.sh`
Expected: 末行 `结果：37 通过，0 失败`；新增 `ok — 活基线覆盖：…`。

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/fixtures/pass-main-current.log .github/scripts/catalyst-gate.test.sh
git commit -m "ci: 补 Catalyst 活基线覆盖——代表当前 main 的裁剪真日志 fixture + 走活基线自测（codex plan R1）"
```

---

### Task 4: 补非整数活基线的 fail-closed 回归（加固）

生产门 `catalyst-gate.sh:215-221` 已对活 total 基线做校验（缺失 + 非整数内容均 fail-closed），但现有自测（:421）只覆盖了「基线文件缺失」、没覆盖「文件存在但内容非整数」。补一条回归堵这个空档。纯测试新增，不改生产逻辑。

**Files:**
- Modify: `.github/scripts/catalyst-gate.test.sh`（在 :421 附近「基线缺失 fail-closed」用例之后新增一条）

**Interfaces:**
- Consumes: `catalyst-gate.sh` 的非整数校验分支（`catalyst-gate.sh:219-221`，失败信息含「不是合法整数」）。
- Produces: 无（纯回归）。

- [ ] **Step 1: 先手工确认生产门对非整数基线确实 fail-closed（写测试前验红）**

```bash
printf 'abc\n' > /tmp/.noninteger-baseline-probe.txt
# 必须同时注入冻结 uikit 脚本：否则走活 uikit 基线(35) 比对 pass-new-scheme.log(28 个 UIKit 结果行)，
# G8 逐测试判据会先失败(7 个缺失)、根本到不了 total 基线那步。判据按顺序执行，前置判据先拦。
UIKIT_EXPECTED_TESTS_SCRIPT=.github/scripts/fixtures/uikit-expected-tests-frozen.py \
CATALYST_TOTAL_BASELINE_FILE=/tmp/.noninteger-baseline-probe.txt \
bash .github/scripts/catalyst-gate.sh .github/scripts/fixtures/pass-new-scheme.log; echo "exit=$?"
rm -f /tmp/.noninteger-baseline-probe.txt
```
Expected: 输出含 `总用例数基线文件内容不是合法整数: 'abc'`，`exit=1`。（若不是，停下——生产门行为与假设不符，回 spec。）

- [ ] **Step 2: 在自测里新增该回归用例**

在 `.github/scripts/catalyst-gate.test.sh` 的「总用例数基线文件缺失」用例（`grep -qF "总用例数基线文件不存在"`）那个 `if/fi` 块之后新增（Task 3 已在前面插入代码、行号相应下移，以此语义锚点为准）：

```bash
# F6 fail-closed（2026-07-18）：活 total 基线文件存在但内容非整数（如被误写成空/文字/负号）
# 也必须 fail-closed，不能在算术比较那步崩溃或放行。现有 :421 只测了「文件缺失」，这里补
# 「内容非整数」这条既有 fail-closed 路径（catalyst-gate.sh:219-221）的回归。
NONINT_BASELINE="$FIX/../.noninteger-total-baseline-$$.txt"
printf 'abc\n' > "$NONINT_BASELINE"
out=$(CATALYST_TOTAL_BASELINE_FILE="$NONINT_BASELINE" bash "$GATE" "$FIX/pass-new-scheme.log" 2>&1)
got=$?
if [ "$got" -eq 1 ] && grep -qF "不是合法整数" <<<"$out"; then
    echo "  ok   — 活 total 基线内容非整数 → 必须 fail-closed，不能放行 (exit=$got)"
    PASSED=$((PASSED + 1))
else
    echo "  FAIL — 活 total 基线非整数本该 FAIL 且报'不是合法整数'，实得 exit=$got, out=$out"
    FAILED=$((FAILED + 1))
fi
rm -f "$NONINT_BASELINE"
```

- [ ] **Step 3: 跑自测，必须 38/38**

Run: `bash .github/scripts/catalyst-gate.test.sh`
Expected: 末行 `结果：38 通过，0 失败`，退出码 0。

- [ ] **Step 4: Commit**

```bash
git add .github/scripts/catalyst-gate.test.sh
git commit -m "ci: 补 Catalyst 自测——活 total 基线非整数内容 fail-closed 回归（补齐只测缺失的空档）"
```

---

## Verification（orchestrator 跑，非 subagent；对应 spec §4）

subagent 完成 4 个 task 后，orchestrator 在 verification-before-completion 阶段实跑以下全部，任一不过即回 Phase 1：

1. **自测终态**：`bash .github/scripts/catalyst-gate.test.sh` → `38 通过，0 失败`（含 Task 3 活基线覆盖用例 + Task 4 非整数用例）。
2. **活基线 vs 全量真日志 GATE PASS**：用 main `6068522` 的真 Catalyst 构建日志（本会话已抓取，1457 tests / 35 UIKit / macabi）跑 `bash .github/scripts/catalyst-gate.sh <真日志>` → `GATE PASS`，回显 `1457`。（Task 3 的裁剪 fixture 已在自测里覆盖活基线；此步是全量真日志的端到端再确认。）
3. **红-绿对照（不改 tracked 文件；证明活基线判据承重，codex plan R1 rec#1）**：
   ```bash
   printf '1407\n' > /tmp/tb1407.txt
   CATALYST_TOTAL_BASELINE_FILE=/tmp/tb1407.txt bash .github/scripts/catalyst-gate.sh <真日志>   # 必须 GATE FAIL: … 高于上限
   printf '1457\n' > /tmp/tb1457.txt
   CATALYST_TOTAL_BASELINE_FILE=/tmp/tb1457.txt bash .github/scripts/catalyst-gate.sh <真日志>   # 必须 GATE PASS
   ```
   **只用 `CATALYST_TOTAL_BASELINE_FILE` 临时文件，绝不改动 tracked 的 `catalyst-total-baseline.txt`**（避免忘记还原导致提交错基线）。
4. **真 CI 转绿**：推成 PR 后，`Mac Catalyst build-for-testing on macos-15` 必须 success（这是唯一能证明"必需检查真转绿"的观测，不可用本地绿替代）。

## Self-Review（写完计划的自查）

- **Spec coverage**：spec §3.2 表格 5 行改动 → Task 1（#3+#4 冻结 fixture+export）、Task 2（#1+#2 活基线）、Task 4（#5 非整数加固）全覆盖；spec §4 验收 5 条 → Verification 段 1-4 + 自测覆盖。✓
- **codex plan R1 [high] 覆盖**：①红-绿对照改用 `CATALYST_TOTAL_BASELINE_FILE` 临时文件、不动 tracked 基线（Verification §3）；②活基线不被自测覆盖 → 新增 Task 3（代表 main 的裁剪真日志 fixture + 走活基线自测用例）。两条建议均已并入。✓
- **我方自查 finding 覆盖**：Task 4 Step 1 手工探针补注入冻结 uikit 脚本（否则活基线 35 会让 G8 先失败、到不了 total 判据）。✓
- **Placeholder scan**：无 TBD/TODO；每个改代码的 step 都给了完整命令/代码块（Task 3 Step 1 的 fixture 裁剪以"只摘真实行"约束替代逐行罗列——1MB 真日志不宜内联，但约束足够具体且禁伪造行）。✓
- **Type/命名一致**：`CATALYST_TOTAL_BASELINE_FILE`、`UIKIT_EXPECTED_TESTS_SCRIPT`（env）、`total-baseline-frozen.txt`、`pass-main-current.log`、`$FIX`、`$GATE` 全与现有 `catalyst-gate.test.sh` / `catalyst-gate.sh` 用法一致。✓
- **顺序正确性 + 自测计数**：Task 1 行为保持（冻结=活=1407，36/36 不变）→ Task 2 落真值（靠 Task 1 解耦挡住 fixture 破裂，仍 36/36）→ Task 3 活基线覆盖（37/37）→ Task 4 非整数加固（38/38）。每步自测可独立验证；活基线的实测覆盖在 Task 3 自测 + Verification §2/§3。✓
