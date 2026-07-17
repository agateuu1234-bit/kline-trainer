# Catalyst 必需门修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让必需检查 `Mac Catalyst build-for-testing on macos-15` 真正编译并执行 `KlineTrainerContractsTests`，并让它的闸门判据本身可被测试、不会再静默变绿。

**Architecture:** 把闸门逻辑从 workflow 内联 shell **抽成 `.github/scripts/catalyst-gate.sh`**，用**真实抓取的构建日志**做 fixture 对它做单元测试（含"旧 scheme 的空壳日志必须被拒"这条回归）。workflow 只保留：换 scheme、换动作、调用闸门脚本、调超时。

**Tech Stack:** GitHub Actions、xcodebuild（Xcode 16+ / macos-15）、SwiftPM package scheme、bash + grep。

## Global Constraints

- **job 显示名必须保持 `Mac Catalyst build-for-testing on macos-15` 一字不改** —— 它是 ruleset `15660830` 的必需检查 context，GitHub 按显示名精确匹配。改名 = ruleset 失配 = 所有 PR 死锁。
- `.github/workflows/**` 对 Claude 是 **deny（Edit/Write 均禁）** → 该文件只能在 `/tmp` 起草，由**用户**执行 `!cp` 落盘。`.github/scripts/**` **不在 deny 内**，可直接写。
- `.github/**` 同时属于 `trust_boundary_globs` 与 `codeowners_required_globs` → 新增的 `.github/scripts/` 文件与 workflow 受**同等**治理保护（CODEOWNERS + codex 闸门），抽取脚本**不降低**保护等级。
- 负向断言一律写 `if grep -q ...; then ...; exit 1; fi`，**禁止** `! grep ... || exit 1`（`set -e` 下是死闸门，本仓已复发多次）。
- 不修 `Tests/` 下既有的 48 条警告；不碰 ruleset；不碰其它 workflow。

---

## File Structure

| 文件 | 职责 | 谁能写 |
|---|---|---|
| `.github/scripts/catalyst-gate.sh` | **新建**。唯一的闸门判据实现。入参=构建日志路径；exit 0=通过，非 0=拦截并打印原因。 | Claude 直接写 |
| `.github/scripts/catalyst-gate.test.sh` | **新建**。用 fixture 对闸门脚本做断言（PASS/拒绝各情形）。本地与 CI 都跑。 | Claude 直接写 |
| `.github/scripts/fixtures/*.log` | **新建**。真实抓取的构建日志裁剪件（含旧 scheme 空壳日志）。 | Claude 直接写 |
| `.github/workflows/catalyst-build.yml` | **改**。scheme / 动作 / 超时 / 调用闸门脚本。 | **仅用户 `!cp`** |

---

### Task 1: 闸门脚本 + fixture 单元测试（不碰 workflow）

**Files:**
- Create: `.github/scripts/catalyst-gate.sh`
- Create: `.github/scripts/catalyst-gate.test.sh`
- Create: `.github/scripts/fixtures/pass-new-scheme.log`
- Create: `.github/scripts/fixtures/hollow-old-scheme.log`
- Create: `.github/scripts/fixtures/sources-warning.log`
- Create: `.github/scripts/fixtures/compile-error.log`
- Create: `.github/scripts/fixtures/zero-tests.log`

**Interfaces:**
- Produces: `bash .github/scripts/catalyst-gate.sh <log-path>` → exit 0 = 闸门通过；exit 1 = 拦截（stderr 打印哪条判据不满足）。Task 2 的 workflow 只调这一个入口。

**Fixture 出处（真实日志，非杜撰）**：本会话已在本机抓到两份真日志，落在 scratchpad：
- `catalyst-trial2.log` = 新 scheme（`KlineTrainerContracts-Package` + `test`）→ `** TEST SUCCEEDED **`、`Test run with 1407 tests in 184 suites passed`、`KlineTrainerContractsTests` 命中 652 次、含 8 条 `CoreData: error:` 运行期噪声。
- `catalyst-old-scheme.log` = 旧 scheme（`KlineTrainerContracts` + `build-for-testing`）→ `** TEST BUILD SUCCEEDED **`、`KlineTrainerContractsTests` 命中 **0** 次、无任何测试执行。**这就是"报绿但什么都没验证"的空壳日志本体。**

fixture 用**裁剪**而非全量（全量 1.0 MB / 7618 行）：从真日志里挑出判据相关行 + 少量上下文，保留原始字节形态。

- [ ] **Step 1: 写闸门脚本（先写实现骨架，下一步立刻用测试逼出正确性）**

创建 `.github/scripts/catalyst-gate.sh`：

```bash
#!/usr/bin/env bash
# Catalyst 必需门的判据实现。
#
# 背景（2026-07-13）：本门曾用 library scheme `KlineTrainerContracts` 跑 build-for-testing，
# 而 SwiftPM 的 library scheme 根本不编译 testTarget → 门半年来报绿但从未验证过任何测试代码
# （旧日志里 grep `KlineTrainerContractsTests` 一条都没有）。G4/G5/G6 三条"自证"判据就是为了
# 让这种空壳门**不可能再静默变绿**：门必须证明自己真的编译了测试 target、真的跑了测试、
# 真的编译了 UIKit-gated 代码。
#
# 用法: catalyst-gate.sh <xcodebuild 日志路径>
# 退出: 0 = 通过；1 = 拦截（stderr 说明哪条判据失败）
set -uo pipefail

LOG="${1:?usage: catalyst-gate.sh <log-path>}"
if [ ! -f "$LOG" ]; then
    echo "GATE FAIL: 日志文件不存在: $LOG" >&2
    exit 1
fi

fail() { echo "GATE FAIL: $*" >&2; exit 1; }

# --- G2: 测试真跑完且成功（test 动作的标记是 TEST SUCCEEDED，不是 TEST BUILD SUCCEEDED）
if ! grep -qF '** TEST SUCCEEDED **' "$LOG"; then
    fail "缺少 '** TEST SUCCEEDED **' 标记（旧的 build-for-testing 标记 'TEST BUILD SUCCEEDED' 不算数）"
fi

# --- G3: 编译器错误。锚定 <文件>.swift:<行>:<列>: error: 格式，
#         这样 xctest 运行期噪声（如 'CoreData: error: Failed to create NSXPCConnection'）不会误伤。
if grep -qE '\.swift:[0-9]+:[0-9]+: (fatal )?error:' "$LOG"; then
    echo "GATE FAIL: 检测到编译器错误：" >&2
    grep -E '\.swift:[0-9]+:[0-9]+: (fatal )?error:' "$LOG" | sort -u | head -20 >&2
    exit 1
fi

# --- G4: 生产代码（Sources/）零警告棘轮。今天真为 0，新增一条即拦。
if grep -qE 'ios/Contracts/Sources/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG"; then
    echo "GATE FAIL: 生产代码 Sources/ 出现编译警告（本门要求 Sources/ 零警告）：" >&2
    grep -E 'ios/Contracts/Sources/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG" | sort -u | head -20 >&2
    exit 1
fi

# --- G6: 自证——测试 target 真的被编译了（旧空壳门在这里命中 0 次）
if ! grep -q 'KlineTrainerContractsTests' "$LOG"; then
    fail "日志里找不到 KlineTrainerContractsTests —— 测试 target 根本没被编译（scheme 用错了？）"
fi

# --- G8: 自证——UIKit-gated 测试真的进了编译。
#         金丝雀文件：DrawDrawingsDispatchTests.swift（#if canImport(UIKit) 包裹）。
#         若该文件被改名/删除，本判据会红——这是**有意**的：改名者必须在这里换一个
#         新的 UIKit-gated 金丝雀，而不是让"UIKit 代码已被编译"这条不变量悄悄消失。
if ! grep -q 'DrawDrawingsDispatchTests\.swift' "$LOG"; then
    fail "日志里找不到 DrawDrawingsDispatchTests.swift —— UIKit-gated 测试没进编译（若该文件已改名，请在本脚本里更新金丝雀）"
fi

# --- G7: 自证——测试真的被执行了，且不是 0 个（防 -only-testing 把用例全过滤光）
SUMMARY=$(grep -oE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$LOG" | head -1 || true)
if [ -z "$SUMMARY" ]; then
    fail "找不到 swift-testing 汇总行 'Test run with N tests in M suites passed' —— 测试没被执行"
fi
N_TESTS=$(echo "$SUMMARY" | grep -oE '[0-9]+' | head -1)
if [ "$N_TESTS" -eq 0 ]; then
    fail "swift-testing 执行了 0 个用例（$SUMMARY）—— 门是空的"
fi

# --- G5: 测试代码警告：只统计、不拦（48 条既有技术债，见 spec §4）
TEST_WARN=$(grep -cE 'ios/Contracts/Tests/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$LOG" || true)

echo "GATE PASS"
echo "  执行用例数（swift-testing）: $SUMMARY"
echo "  Tests/ 警告（既有技术债，不拦门）: $TEST_WARN 条"
```

- [ ] **Step 2: 写 fixture 测试（会失败，因为 fixture 还不存在）**

创建 `.github/scripts/catalyst-gate.test.sh`：

```bash
#!/usr/bin/env bash
# 闸门脚本的单元测试。fixture 是真实抓取的 xcodebuild 日志裁剪件。
# 本仓的教训：一个没人测过的闸门，可以报绿半年而什么都不验证。所以闸门本身必须有测试。
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$DIR/catalyst-gate.sh"
FIX="$DIR/fixtures"
PASSED=0; FAILED=0

expect() {  # expect <期望退出码> <fixture> <说明>
    local want="$1" fixture="$2" desc="$3"
    bash "$GATE" "$FIX/$fixture" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        echo "  ok   — $desc (exit=$got)"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL — $desc (期望 exit=$want，实得 exit=$got)"
        FAILED=$((FAILED + 1))
    fi
}

echo "catalyst-gate.sh 判据测试："
expect 0 pass-new-scheme.log     "新 scheme 的真实成功日志 → 通过（且不被 CoreData 运行期噪声误伤）"
expect 1 hollow-old-scheme.log   "旧 scheme 的空壳日志（TEST BUILD SUCCEEDED 但零测试）→ 必须拦截【回归】"
expect 1 compile-error.log       "含编译器 error: → 拦截"
expect 1 sources-warning.log     "生产代码 Sources/ 出现警告 → 拦截"
expect 1 zero-tests.log          "swift-testing 执行 0 个用例 → 拦截"

echo "结果：$PASSED 通过，$FAILED 失败"
[ "$FAILED" -eq 0 ]
```

- [ ] **Step 3: 跑测试，确认失败（fixture 尚未创建）**

Run: `bash .github/scripts/catalyst-gate.test.sh`
Expected: 5 条全 FAIL（`日志文件不存在`），脚本以非 0 退出。这一步是为了确认测试**真的在断言**，而不是恒绿。

- [ ] **Step 4: 从真实日志裁剪出 5 个 fixture**

`pass-new-scheme.log` 与 `hollow-old-scheme.log` 从本机 scratchpad 的真日志裁剪（**保留原始字节形态，不要手打**）：

```bash
S="/private/tmp/claude-501/-Users-maziming-Coding-Prj-Kline-trainer/91a5fe88-cfbc-4614-b185-219e46db6e60/scratchpad"
mkdir -p .github/scripts/fixtures

# ① 通过样本：真实的新 scheme 成功日志，挑出判据相关行（含 8 条 CoreData 噪声，用来证明 G3 不会误伤）
{
  grep -F '** TEST SUCCEEDED **' "$S/catalyst-trial2.log" | head -1
  grep -oE 'Test run with [0-9]+ tests in [0-9]+ suites passed after [0-9.]+ seconds\.' "$S/catalyst-trial2.log" | head -1
  grep -m1 -F 'KlineTrainerContractsTests' "$S/catalyst-trial2.log"
  grep -m1 -F 'DrawDrawingsDispatchTests.swift' "$S/catalyst-trial2.log"
  grep -F 'CoreData: error: Failed to create NSXPCConnection' "$S/catalyst-trial2.log" | head -8
  grep -E 'ios/Contracts/Tests/[^ ]*\.swift:[0-9]+:[0-9]+: warning:' "$S/catalyst-trial2.log" | head -3
} > .github/scripts/fixtures/pass-new-scheme.log

# ② 回归样本：真实的旧 scheme 空壳日志（报 TEST BUILD SUCCEEDED，但零测试代码）
{
  grep -F '** TEST BUILD SUCCEEDED **' "$S/catalyst-old-scheme.log" | head -1
  grep -m1 -E 'Build settings|Prepare packages|CompileSwiftSources' "$S/catalyst-old-scheme.log" || true
} > .github/scripts/fixtures/hollow-old-scheme.log

# ③ 编译错误样本：在通过样本上注入一条真实格式的编译器 error
cp .github/scripts/fixtures/pass-new-scheme.log .github/scripts/fixtures/compile-error.log
echo "/Users/x/ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift:42:9: error: argument 'colorToken' must precede argument 'thickness'" \
  >> .github/scripts/fixtures/compile-error.log

# ④ 生产代码警告样本
cp .github/scripts/fixtures/pass-new-scheme.log .github/scripts/fixtures/sources-warning.log
echo "/Users/x/ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift:88:13: warning: variable 'foo' was never mutated; consider changing to 'let' constant" \
  >> .github/scripts/fixtures/sources-warning.log

# ⑤ 零用例样本：把汇总行的数字改成 0
sed 's/Test run with [0-9]* tests in [0-9]* suites passed/Test run with 0 tests in 0 suites passed/' \
  .github/scripts/fixtures/pass-new-scheme.log > .github/scripts/fixtures/zero-tests.log
```

**注入的那条 `error:` 用的正是当初真实漏掉的那个 bug**（`DrawingObject` 的 `colorToken` / `thickness` 关键字参数顺序写反）——即"只有 Catalyst 才编译得到"的那一类。

- [ ] **Step 5: 跑测试，确认 5 条全过**

Run: `bash .github/scripts/catalyst-gate.test.sh`
Expected:
```
  ok   — 新 scheme 的真实成功日志 → 通过（且不被 CoreData 运行期噪声误伤）
  ok   — 旧 scheme 的空壳日志（TEST BUILD SUCCEEDED 但零测试）→ 必须拦截【回归】
  ok   — 含编译器 error: → 拦截
  ok   — 生产代码 Sources/ 出现警告 → 拦截
  ok   — swift-testing 执行 0 个用例 → 拦截
结果：5 通过，0 失败
```

若第 2 条不通过，说明闸门**抓不住当初那个真 bug**，任务失败，不许继续。

- [ ] **Step 6: 提交**

```bash
chmod +x .github/scripts/catalyst-gate.sh .github/scripts/catalyst-gate.test.sh
git add .github/scripts/
git commit -m "ci: Catalyst 闸门判据抽成可测脚本 + 真实日志 fixture（含旧 scheme 空壳日志回归）"
```

---

### Task 2: 改 workflow 接上闸门脚本（须用户 `!cp` ceremony）

**Files:**
- Modify: `.github/workflows/catalyst-build.yml`（第 21 行 job 名**不动**；第 23 行 timeout；第 41-53 行构建+闸门两步）

**Interfaces:**
- Consumes: Task 1 的 `bash .github/scripts/catalyst-gate.sh <log>`（exit 0 = 通过）

- [ ] **Step 1: 在 /tmp 起草新 workflow 全文**

写到 `/tmp/catalyst-build.yml`。相对现状**只改 4 处**，其余（`on:` / `permissions:` / checkout pin / Xcode 断言步骤 / **job 显示名**）逐字保留：

1. `timeout-minutes: 15` → `25`
2. 步骤名 `Mac Catalyst build-for-testing` → `Mac Catalyst test（真编译 + 真执行）`（**步骤**名可改，**job** 名不可改）
3. 构建命令：`build-for-testing` → `test`，`-scheme KlineTrainerContracts` → `-scheme KlineTrainerContracts-Package`，新增 `-only-testing:KlineTrainerContractsTests`
4. 内联 grep 闸门 → `bash .github/scripts/catalyst-gate.sh /tmp/catalyst-build.log`

并在 job 名上方加注释说明"名字为匹配 ruleset 必需 context 而冻结，实际行为是真跑 test"。

- [ ] **Step 2: 展示 diff 给用户，请用户执行 `!cp`**

```bash
diff -u .github/workflows/catalyst-build.yml /tmp/catalyst-build.yml
```

然后请用户在真终端执行：

```
! cp /tmp/catalyst-build.yml ".github/workflows/catalyst-build.yml"
```

- [ ] **Step 3: 落盘后验证 4 处改动 + job 名未变**

```bash
grep -n 'name: Mac Catalyst build-for-testing on macos-15' .github/workflows/catalyst-build.yml   # 必须命中（job 名冻结）
grep -n 'KlineTrainerContracts-Package' .github/workflows/catalyst-build.yml                      # 必须命中
grep -n 'timeout-minutes: 25' .github/workflows/catalyst-build.yml                                # 必须命中
grep -n 'catalyst-gate.sh' .github/workflows/catalyst-build.yml                                   # 必须命中
if grep -qE '^\s+xcodebuild build-for-testing' .github/workflows/catalyst-build.yml; then echo "FAIL: 仍在用 build-for-testing"; exit 1; fi
```

- [ ] **Step 4: 提交**

```bash
git add .github/workflows/catalyst-build.yml
git commit -m "ci: Catalyst 门改用 -Package scheme + 真跑 test + 调用可测闸门脚本"
```

---

### Task 3: 让闸门在 CI 里自测（把 Task 1 的测试接进 workflow）

**Files:**
- Modify: `.github/workflows/catalyst-build.yml`（在 xcodebuild 步骤**之前**插入一步）

- [ ] **Step 1: 在 /tmp 草稿里插入自测步骤**

在 "Assert Xcode >= 16" 之后、xcodebuild 之前插入：

```yaml
      - name: Gate self-test（闸门判据本身必须先过测试）
        run: bash .github/scripts/catalyst-gate.test.sh
```

理由：闸门脚本若被改坏（比如有人把 G6 删了），**在真构建之前就红**，而不是等到某个 PR 悄悄溜过去。成本 < 1 秒。

- [ ] **Step 2: 走同样的 `!cp` ceremony 落盘，验证**

```bash
grep -n 'catalyst-gate.test.sh' .github/workflows/catalyst-build.yml   # 必须命中
```

- [ ] **Step 3: 提交**

```bash
git add .github/workflows/catalyst-build.yml
git commit -m "ci: Catalyst 门在真构建前先自测闸门判据"
```

---

### Task 4: 真 CI 验证 + 变异验证（证明门真的能抓到 bug）

**Files:** 无（只推分支、看 CI）

- [ ] **Step 1: 推分支、开 PR，等 CI**

- [ ] **Step 2: 正向验证——必需检查绿，且日志能搜到四样东西**

在 `Mac Catalyst build-for-testing on macos-15` 的日志里确认：
- `** TEST SUCCEEDED **`
- `Test run with <N> tests in <M> suites passed`，N 不是 0
- `KlineTrainerContractsTests`（**修复前这里一条都没有**）
- `GATE PASS`

- [ ] **Step 3: 变异验证（关键，不可省）**

临时把 `ios/Contracts/Tests/KlineTrainerContractsTests/Drawing/DrawDrawingsDispatchTests.swift` 里某个 `DrawingObject(...)` 的关键字参数顺序**故意写反**（复现当初那个真 bug），推到分支：

Expected: 该必需检查**变红**，日志里出现 `GATE FAIL: 检测到编译器错误` + 那一行 `.swift:行:列: error:`。

**若它仍然是绿的，说明门还是空的，整个 PR 作废重做。**

- [ ] **Step 4: 还原变异，确认恢复绿**

```bash
git revert --no-edit HEAD   # 或 git checkout -- <该测试文件>
```

Expected: 必需检查回到绿。变异验证的证据（红/绿两张截图或 CI 链接）写进 PR 描述。

---

## 验收标准（非 coder 可执行）

见 spec §5。要点：PR 上那个 Catalyst 检查是绿的；日志里搜得到 `TEST SUCCEEDED` / `Test run with …`（数字非 0）/ `KlineTrainerContractsTests`（**修复前搜它是 0 条**）/ `GATE PASS`；且变异验证证明它**能变红**。
