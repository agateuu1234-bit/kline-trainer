# Wave 3 顺位 2 实施计划：app-target CI 守护 + 竖屏/窗口策略

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `KlineTrainer.xcodeproj` app target 纳入 CI 编译守护（设为 required check 强制顺位 3-12）+ 锁竖屏/全屏 + 把 required-check 治理工具从单 Catalyst context 泛化为多 context 列表。0 业务代码。

**Architecture:** 三组互不相交的改动。A：新增 always-trigger GitHub Actions workflow 构建 app target（iOS Simulator destination）。B：`project.pbxproj` build settings 改为 Portrait-only + `UIRequiresFullScreen=YES`。C：泛化 `scripts/governance/` 的 builder/verifier/admin/测试，把 canonical required-context 列表收为单一真相（builder `--list-contexts` 派生注入），实际 origin ruleset `--apply`（加第 12 条 context）延后 post-merge user-TTY admin。

**Tech Stack:** GitHub Actions（macOS runner + xcodebuild）、Xcode pbxproj build settings、Python 3 + bash（governance 脚本）、GitHub Rulesets API。

**权威 spec：** `docs/superpowers/specs/2026-06-10-wave3-pr2-app-ci-orientation-design.md`（v3，opus 4.8 xhigh 对抗 review R3 APPROVE）。

**关键约束（来自 spec，impl 不得漂移）：**
- gate step 结构：`xcodebuild` 独立 step + `set -o pipefail`，非零 exit 独立 fail job = **首要信号**；grep 三断言为次要（§spec 三.A5 / codex H-NEW-1）。
- gate 三断言：`grep -F "** BUILD SUCCEEDED **"` 在位 + 无 `** BUILD FAILED **` + 无 anchored `(^|[[:space:]])error:`；**不**做 blanket no-warning（appintents 良性 warning 会误 fail，codex M1）。
- job name = required-check context = `iOS app build-for-running on macos-15`（定后不可改）。
- canonical context 单一真相：builder 加 `--list-contexts`，verifier/admin/测试派生（codex H-NEW-2）。
- partial-state fixture 用新建独立 `ruleset-catalyst-only.json`，不复用 `ruleset-partial.json`（codex M-NEW-2）。
- origin ruleset `--apply` = post-merge user TTY，且须在所有 in-flight PR reb' 到含 app-build.yml 的 main 后（codex H1）。

---

## File Structure

| 文件 | 动作 | 责任 |
|---|---|---|
| `.github/workflows/app-build.yml` | Create | app target CI 编译守护（Group A） |
| `ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj` | Modify（Debug+Release 各 3 处 build setting） | 锁 Portrait + UIRequiresFullScreen（Group B） |
| `scripts/governance/build-protection-put-payload.py` | Modify | `CATALYST_CONTEXT`→`REQUIRED_CONTEXTS` 列表 + `--list-contexts`（Group C） |
| `scripts/governance/verify-required-checks.sh` | Modify | assert+diff 两 heredoc 遍历 `REQUIRED_CONTEXTS`（派生注入） |
| `scripts/governance/admin-configure-required-checks.sh` | Modify | 文案泛化（Catalyst→app-target required checks） |
| `tests/scripts/governance/test_build_payload.py` | Modify | builder 多 context 断言 |
| `tests/scripts/governance/test-verify-required-checks.sh` | Modify | verify 多 context + partial-state 用例 |
| `tests/scripts/governance/test-admin-runbook.sh` | Modify | `one_catalyst()`→`both_contexts()` + no-op fixture |
| `tests/scripts/governance/fixtures/ruleset-with-check.json` | Modify | 加 app-build context = 全合规 |
| `tests/scripts/governance/fixtures/ruleset-catalyst-only.json` | Create | partial-state（Catalyst 在、app-build 缺） |
| `docs/acceptance/2026-06-10-wave3-pr2-app-ci-orientation.md` | Create | 中文非-coder 验收清单 |
| `docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md` | Create | 旋转/窗口运行时 runbook 条目 |
| `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md` | Create | post-merge admin `--apply` runbook + evidence 模板 |

**canonical context 值（全计划统一）：**
- `CATALYST_CONTEXT = "Mac Catalyst build-for-testing on macos-15"`（既有，不变）
- `APP_BUILD_CONTEXT = "iOS app build-for-running on macos-15"`（新增；= app-build.yml 的 job name）
- `REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT]`

---

## Task 0: 基线确认（pre-change）

**Files:** 无改动（只读验证）。

- [ ] **Step 1: 确认 governance 测试基线全绿**

Run: `bash tests/scripts/governance/run-all.sh`
Expected: 全 PASS，退出 0。

- [ ] **Step 2: 确认 app target 本地可构建（未改 pbxproj）**

Run:
```bash
xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived-base CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 记录基线**（无 commit；确认起点干净）

---

## Task 1: Group A — app target CI 编译守护 workflow

**Files:**
- Create: `.github/workflows/app-build.yml`

- [ ] **Step 1: 写 workflow 文件**

Create `.github/workflows/app-build.yml`：
```yaml
name: iOS App Build

# Wave 3 顺位 2（PR11-R3 + codex R1-F2）：app target KlineTrainer.xcodeproj 的 CI 编译守护。
# 现有 catalyst-build.yml 仅构建 ios/Contracts SwiftPM 包；本 workflow 补 app target 外壳
# （KlineTrainerApp / AppRootView / AppContainer 经本地 Contracts 包）的编译守护。
# always-trigger（无 paths filter），镜像 catalyst-build H9 决议（§15.4 ledger H9），
# 使 required check 在每个 PR 必跑必报，消除 paths-filter→required-check-永不报告→死锁。
# 注意：required check 以 job name 匹配；job name "iOS app build-for-running on macos-15" 必须保持不变。
on:
  pull_request:
  push:
    branches: [main]

# Trust-boundary hardening（对齐 catalyst-build.yml）：least-privilege 只读 token + checkout pin full SHA。
permissions:
  contents: read

jobs:
  app-build:
    name: iOS app build-for-running on macos-15
    runs-on: macos-15
    timeout-minutes: 20
    # 依赖 runner 默认 Xcode（macos-15 image）；不硬编码 Xcode 路径（镜像 catalyst-build）。
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - name: Assert Xcode >= 16
        run: |
          xcodebuild -version
          XCODE_VER=$(xcodebuild -version | head -1 | awk '{print $2}')
          MAJOR=$(echo "$XCODE_VER" | cut -d. -f1)
          if [[ -z "$XCODE_VER" || "$MAJOR" -lt 16 ]]; then
            echo "FAIL: Xcode 16+ required；runner provides $XCODE_VER"
            echo "Available Xcode installs:"
            ls -la /Applications | grep -i xcode || true
            exit 1
          fi
          echo "Xcode $XCODE_VER OK"
      - name: Build iOS app target (build-for-running, iOS Simulator)
        run: |
          set -o pipefail
          xcodebuild build \
            -project ios/KlineTrainer/KlineTrainer.xcodeproj \
            -scheme KlineTrainer \
            -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath /tmp/app-derived \
            CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/app-build.log
      - name: Gate — BUILD SUCCEEDED + no error (not blanket no-warning)
        run: |
          grep -F "** BUILD SUCCEEDED **" /tmp/app-build.log || { echo "BUILD SUCCEEDED 缺失"; exit 1; }
          if grep -F "** BUILD FAILED **" /tmp/app-build.log; then echo "BUILD FAILED 触发 gate"; exit 1; fi
          if grep -E "(^|[[:space:]])error:" /tmp/app-build.log; then echo "编译/链接 error: 触发 gate"; exit 1; fi
          echo "GATE PASS: app target 编译守护（PR11-R3 关闭）"
```

说明：build step 在 `set -o pipefail` 下跑（GHA 默认 `bash -eo pipefail`，xcodebuild 非零 exit 即 fail job = 首要信号）；gate step 是次要 belt-and-suspenders。**不**含 `warning:` 断言（appintents 良性 warning）。

- [ ] **Step 2: YAML 语法校验**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/app-build.yml')); print('YAML OK')"`
Expected: `YAML OK`（若无 pyyaml，用 `ruby -ryaml -e 'YAML.load_file(...)'` 或目检缩进）。

- [ ] **Step 3: 本地实证 gate 逻辑（用 Task 0 的真实 build log）**

Run（复用基线 build 的 log，模拟 gate step）：
```bash
LOG=/tmp/app-build-gate-test.log
xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived-gate CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG" >/dev/null
echo "--- gate sim ---"
grep -F "** BUILD SUCCEEDED **" "$LOG" >/dev/null && echo "A:SUCCEEDED present" || echo "A:FAIL"
if grep -F "** BUILD FAILED **" "$LOG"; then echo "B:FAILED present (BAD)"; else echo "B:no BUILD FAILED (good)"; fi
if grep -E "(^|[[:space:]])error:" "$LOG"; then echo "C:error: present (BAD)"; else echo "C:no error: (good)"; fi
echo "--- appintents warning still present (proves blanket no-warning would falsely fail) ---"
grep -E "(^|[[:space:]])warning:" "$LOG" | head -1
```
Expected: `A:SUCCEEDED present` / `B:no BUILD FAILED (good)` / `C:no error: (good)`；且 appintents `warning:` 行存在（证 blanket no-warning 会误 fail，故本 gate 正确地不查 warning）。

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/app-build.yml
git commit -m "feat(ci): app target build-for-running 守护 workflow（Group A / PR11-R3）

always-trigger（无 paths filter，镜像 catalyst-build H9）；iOS Simulator destination；
job name = required-check context 'iOS app build-for-running on macos-15'；
gate = SUCCEEDED + 无 error（非 blanket no-warning，appintents 良性 warning 实测）。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Group B — 锁竖屏 + iPad 全屏窗口

**Files:**
- Modify: `ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj`（Debug `:277-279` + Release `:310-312` 两个 buildSettings 块；改动文字两块相同）

- [ ] **Step 1: 改 orientation 为 Portrait-only（两 config）**

用 Edit `replace_all`（Debug+Release 两处文字相同）。
iPad 行：`old` →
```
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
```
`new` →
```
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait";
```
iPhone 行：`old` →
```
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
```
`new` →
```
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = "UIInterfaceOrientationPortrait";
```
**注意保留原始缩进 = 4 个 tab**（`od -c` 实证前导 `\t\t\t\t`；codex plan-R1 L1；Edit old_string 须含确切 4 tab，不可用空格）。

- [ ] **Step 2: 加 `UIRequiresFullScreen = YES`（两 config，按字母序插在 UILaunchScreen_Generation 之后、UISupportedInterfaceOrientations 之前）**

用 Edit `replace_all`：
`old` →
```
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait";
```
`new` →
```
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UIRequiresFullScreen = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait";
```
（此 old_string 在 Step 1 之后两 config 各出现一次 → replace_all 命中两处。）

- [ ] **Step 3: 实证：本地构建 + 检查生成 Info.plist**

Run:
```bash
xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived-b CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2
PLIST=/tmp/app-derived-b/Build/Products/Debug-iphonesimulator/KlineTrainer.app/Info.plist
plutil -p "$PLIST" | grep -iA3 "orientation\|RequiresFullScreen"
```
Expected: `** BUILD SUCCEEDED **`；plist 含 `UIRequiresFullScreen => true`、`UISupportedInterfaceOrientations~ipad => [Portrait]`、`UISupportedInterfaceOrientations~iphone => [Portrait]`（无 Landscape / UpsideDown）。

- [ ] **Step 4: 确认 pbxproj 无残留 Landscape / UpsideDown**

Run: `grep -nE "Landscape|UpsideDown" ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj || echo "无 Landscape/UpsideDown 残留"`
Expected: `无 Landscape/UpsideDown 残留`。

- [ ] **Step 5: Commit**

```bash
git add ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj
git commit -m "feat(app): 锁竖屏 + iPad 全屏窗口（Group B / codex R2-F3/R3-F3）

orientation → 仅 Portrait（删 Landscape+UpsideDown，Debug+Release）；
UIRequiresFullScreen=YES 关 iPad Split View/Stage Manager 多窗。
本地实证：BUILD SUCCEEDED + 生成 plist UIRequiresFullScreen=true + Portrait-only。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Group C-1 — 泛化 builder（REQUIRED_CONTEXTS + --list-contexts）

**Files:**
- Modify: `scripts/governance/build-protection-put-payload.py`
- Test: `tests/scripts/governance/test_build_payload.py`

- [ ] **Step 1: 改 test_build_payload.py 期待多 context（先写失败测试；ENUMERATE 每处编辑，codex plan-R1 H1/H2）**

在 `tests/scripts/governance/test_build_payload.py` 做**以下全部**编辑（不可遗漏任一——`_catalyst_entries` 与 `ensure_catalyst` 关键字若有残留会致 `NameError`/`TypeError` → run-all RED）：

(a) 第 15 行 `CATALYST = ...` 后加常量：
```python
APP_BUILD = "iOS app build-for-running on macos-15"
```
(b) **替换**（非新增）helper `_catalyst_entries`（`:21-23`）为泛型 `_entries_for`：
```python
def _entries_for(payload, ctx):
    rsc = next(r for r in payload["rules"] if r["type"] == "required_status_checks")
    return [c for c in rsc["parameters"]["required_status_checks"] if c["context"] == ctx]
```
(c) **迁移 `_catalyst_entries` 的全部 4 个调用点**（`:28`→已随 (b) 删；`:34`、`:39`、`:91`）：
- `test_adds_missing_check`（`:26-29`）→ 改名 `test_adds_missing_checks` + 遍历两 context：
```python
def test_adds_missing_checks():
    out = mod.build_payload(_ruleset("ruleset-without-check.json"))
    for ctx in (CATALYST, APP_BUILD):
        es = _entries_for(out, ctx)
        assert len(es) == 1 and es[0]["integration_id"] == APP_ID
```
- `test_idempotent_when_present`（`:32-34`）→ `assert len(_entries_for(out, CATALYST)) == 1`（用 `_entries_for(out, CATALYST)` 替 `_catalyst_entries(out)`）。
- `test_fixes_anysource_drift`（`:37-40`）→ 同 (c) 第一条样式，遍历两 context 断言 `len==1 and integration_id==APP_ID`。
- `test_normalize_only_preserves_without_adding`（`:89-93`）→ **整体改为**：
```python
def test_normalize_only_preserves_without_adding():
    out = mod.build_payload(_ruleset("ruleset-without-check.json"), ensure_required=False)
    assert _entries_for(out, CATALYST) == [] and _entries_for(out, APP_BUILD) == []   # 不添加任一
    for ro in ("id", "node_id", "_links", "source", "source_type", "created_at", "updated_at"):
        assert ro not in out
```
（注意：此处同时把 `_catalyst_entries(out)` 替为 `_entries_for(out, ...)` **且** 把关键字 `ensure_catalyst=False` 改为 `ensure_required=False`——见 (d)。）
(d) **重命名关键字 `ensure_catalyst=False`→`ensure_required=False`** 的**全部** test 调用点：`:90`（已在 (c) 覆盖）+ `test_normalize_only_no_rsc_ok`（`:96-98`）：
```python
def test_normalize_only_no_rsc_ok():
    out = mod.build_payload(_ruleset("ruleset-no-rsc.json"), ensure_required=False)
    assert "rules" in out and "id" not in out
```
(e) 新增 `test_list_contexts_cli`：
```python
def test_list_contexts_cli():
    p = subprocess.run([sys.executable, str(SCRIPT), "--list-contexts"], capture_output=True, text=True)
    assert p.returncode == 0
    assert json.loads(p.stdout) == [CATALYST, APP_BUILD]
```
(f) 新增 `test_required_contexts_constant`：`assert mod.REQUIRED_CONTEXTS == [CATALYST, APP_BUILD]`。

**收尾自检（必跑）**：`grep -n "_catalyst_entries\|ensure_catalyst" tests/scripts/governance/test_build_payload.py` 须**零命中**（证全部迁移完）。

- [ ] **Step 2: 运行测试确认失败**

Run: `python3 -m pytest tests/scripts/governance/test_build_payload.py -q`
Expected: FAIL（`REQUIRED_CONTEXTS` 不存在 / `--list-contexts` 未知 / app-build 未补）。

- [ ] **Step 3: 泛化 build-protection-put-payload.py**

改动：
- 第 19 行 `CATALYST_CONTEXT = ...` 替换为：
```python
CATALYST_CONTEXT = "Mac Catalyst build-for-testing on macos-15"
APP_BUILD_CONTEXT = "iOS app build-for-running on macos-15"
# canonical 必需 context 单一真相（codex H-NEW-2）；verifier/admin/测试经 --list-contexts 派生
REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT]
```
- `build_payload(ruleset, ensure_catalyst=True)` 改名形参 `ensure_required=True`（语义=确保 REQUIRED_CONTEXTS 全在位）：
```python
def build_payload(ruleset, ensure_required=True):
    if "rules" not in ruleset:
        raise ValueError("ruleset 缺 'rules' 字段；不是合法 ruleset GET 响应")
    payload = {k: ruleset[k] for k in PUT_FIELDS if k in ruleset}
    if not ensure_required:
        return payload
    rsc_rule = next((r for r in payload.get("rules", [])
                     if r.get("type") == "required_status_checks"), None)
    if rsc_rule is None:
        raise ValueError("ruleset 无 required_status_checks 规则；拒绝自动新建（请 admin 先在 UI 建该规则）")
    params = rsc_rule.setdefault("parameters", {})
    checks = params.setdefault("required_status_checks", [])
    for ctx in REQUIRED_CONTEXTS:
        present = [c for c in checks if c.get("context") == ctx]
        if present:
            for c in present:
                c["integration_id"] = GITHUB_ACTIONS_INTEGRATION_ID
            if len(present) > 1:
                others = [c for c in checks if c.get("context") != ctx]
                others.append({"context": ctx, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID})
                checks[:] = others
        else:
            checks.append({"context": ctx, "integration_id": GITHUB_ACTIONS_INTEGRATION_ID})
    return payload
```
（注意：去重用 `checks[:] = others` 原地改 `params["required_status_checks"]` 引用；循环每个 ctx 后 `checks` 仍指向同一 list。）
- `main()`：`ensure_catalyst=not args.normalize_only` → `ensure_required=not args.normalize_only`；加 `--list-contexts`：
```python
ap.add_argument("--list-contexts", action="store_true",
                help="打印 canonical REQUIRED_CONTEXTS JSON 列表（供 verifier/测试派生单一真相）")
...
args = ap.parse_args(argv)
if args.list_contexts:
    print(json.dumps(REQUIRED_CONTEXTS))
    return 0
```
- 模块/函数 docstring 中 "Catalyst check" 措辞泛化为 "required checks（Catalyst + app-build）"。

- [ ] **Step 4: 运行测试确认通过**

Run: `python3 -m pytest tests/scripts/governance/test_build_payload.py -q`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add scripts/governance/build-protection-put-payload.py tests/scripts/governance/test_build_payload.py
git commit -m "feat(gov): builder 泛化为 REQUIRED_CONTEXTS 列表 + --list-contexts（Group C / codex H2/H-NEW-2）

CATALYST_CONTEXT 单值 → REQUIRED_CONTEXTS=[Catalyst, app-build] 单一真相；
build_payload 对每个 context 幂等 ensure+15368+dedup；--list-contexts 供下游派生。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Group C-2 — 泛化 verifier（assert + diff 派生注入）+ fixtures

**Files:**
- Modify: `scripts/governance/verify-required-checks.sh`
- Modify: `tests/scripts/governance/fixtures/ruleset-with-check.json`（加 app-build context）
- Create: `tests/scripts/governance/fixtures/ruleset-catalyst-only.json`（partial-state）
- Test: `tests/scripts/governance/test-verify-required-checks.sh`

- [ ] **Step 1: 更新 fixture ruleset-with-check.json = 全合规（加 app-build context）**

在 `ruleset-with-check.json` 的 `required_status_checks` 数组里，Catalyst 条目旁加：
```json
{"context": "iOS app build-for-running on macos-15", "integration_id": 15368}
```
（保持其它字段不变；该 fixture 现表示「两 required context 均在位 = 全合规」。）

- [ ] **Step 2: 新建 partial-state fixture ruleset-catalyst-only.json（codex M-NEW-2）**

`cp ruleset-with-check.json ruleset-catalyst-only.json` 后，**删掉** app-build 条目（即只剩 Catalyst + 其它原有 check，无 app-build）。语义：Catalyst 在、app-build 缺。**勿**复用 `ruleset-partial.json`（其语义是 Catalyst 缺席，被 admin 测 6b 占用）。

- [ ] **Step 3: 改 verify 测试加 partial-state 用例（先写失败测试）**

在 `tests/scripts/governance/test-verify-required-checks.sh`：
- 既有 `assert happy → 0`（ruleset-with-check.json，现含两 context）保持 0。
- 加：
```bash
# partial-state：Catalyst 在但 app-build 缺 → assert 1（required 不全）
set +e; "$V" --mode assert --ruleset-json "$FIX/ruleset-catalyst-only.json" >/dev/null 2>&1; rc=$?; set -e
check "assert catalyst-only(缺 app-build) → 1" 1 "$rc"
# diff：catalyst-only → 0 且输出含 app-build context（显示将新增）
set +e; out=$("$V" --mode diff --ruleset-json "$FIX/ruleset-catalyst-only.json" 2>&1); rc=$?; set -e
check "diff catalyst-only → 0" 0 "$rc"
echo "$out" | grep -q "iOS app build-for-running on macos-15" && echo "PASS: diff 显示新增 app-build" || { echo "FAIL: diff 未显示 app-build"; fail=1; }
```

- [ ] **Step 4: 运行确认新用例失败**

Run: `bash tests/scripts/governance/test-verify-required-checks.sh`
Expected: 新 `assert catalyst-only → 1` 实际得 0（旧 verifier 只查 Catalyst）→ FAIL。

- [ ] **Step 5: 泛化 verify-required-checks.sh（两 heredoc 派生注入）**

- 文件顶部（`BUILDER=` 定义后）一次性派生 canonical 列表：
```bash
REQUIRED_CONTEXTS_JSON="$("$BUILDER" --list-contexts)" || { echo "FAIL: 取 REQUIRED_CONTEXTS 失败（观测失败）" >&2; exit 3; }
```
- assert/preflight 的 heredoc（`:67`）：env 加 `REQUIRED_CONTEXTS_JSON="$REQUIRED_CONTEXTS_JSON"`，heredoc 内删 `CATALYST = "..."`，改：
```python
required = json.loads(os.environ['REQUIRED_CONTEXTS_JSON'])
```
assert 段（原只查 CATALYST）改为遍历 `required`：
```python
reasons = []
by_ctx = {}
for c in checks:
    by_ctx.setdefault(c.get('context'), []).append(c)
for ctx in required:
    entries = by_ctx.get(ctx, [])
    if not entries:
        reasons.append(f"缺 required check '{ctx}'")
    else:
        for c in entries:
            if c.get('integration_id') != APP_ID:
                reasons.append(f"'{ctx}' integration_id={c.get('integration_id')} != {APP_ID}（any-source 伪造风险）")
if reasons:
    print("FAIL: " + " | ".join(reasons)); sys.exit(1)
print(f"OK: main branch ruleset + 绑默认分支 + active + required contexts {required} 全在位 + integration_id={APP_ID} + bypass 仅 admin"); sys.exit(0)
```
（preflight 段不依赖具体 context，不变。）
- diff 的 heredoc（`:140`）：env 加 `REQUIRED_CONTEXTS_JSON`；删第二个 `CATALYST = "..."`（`:142`）。diff 打印器已泛型迭代 `des.items()`，无需改逻辑；仅删未用常量。grep 校验改为通用（见测试 Step 3）。

- [ ] **Step 6: 运行确认全绿**

Run: `bash tests/scripts/governance/test-verify-required-checks.sh`
Expected: 全 PASS（含新 partial-state 用例 + 既有全部）。

- [ ] **Step 7: Commit**

```bash
git add scripts/governance/verify-required-checks.sh tests/scripts/governance/test-verify-required-checks.sh \
  tests/scripts/governance/fixtures/ruleset-with-check.json tests/scripts/governance/fixtures/ruleset-catalyst-only.json
git commit -m "feat(gov): verifier assert+diff 遍历 REQUIRED_CONTEXTS（派生注入）+ partial-state fixture

assert/diff 两 heredoc 经 --list-contexts 派生单一真相，删第二独立 CATALYST 常量；
ruleset-with-check.json 升为两 context 全合规；新 ruleset-catalyst-only.json 测 partial-state。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Group C-3 — admin-runbook 文案 + 测试泛化

**Files:**
- Modify: `scripts/governance/admin-configure-required-checks.sh`（文案）
- Test: `tests/scripts/governance/test-admin-runbook.sh`

- [ ] **Step 1: admin-configure 文案泛化**

把 Catalyst-specific 散文/消息泛化（逻辑不变；它调 builder/verifier）：
- 顶部注释与 `:71` 的 "Catalyst required check 已绑 app + active" → "app-target required checks（Catalyst + app-build）已绑 app + active"。
- 其它提及 "Catalyst" 的 echo 文案同步泛化。**不**改控制流（preservation_ok / post_put_classify / no-op-skip 逻辑不动）。

- [ ] **Step 2: 改 test-admin-runbook.sh：one_catalyst → both_contexts（先期望失败）**

- 把 `one_catalyst()`（`:18-27`）改为 `both_contexts()`，派生 canonical 列表后断言**每个** required context 恰 1 条 + 15368：
```bash
both_contexts() { # file desc：断言 PUT body 对每个 REQUIRED_CONTEXTS 恰一条 + 15368
  local builder="$ROOT/scripts/governance/build-protection-put-payload.py"
  REQ_JSON="$("$builder" --list-contexts)" python3 - "$1" <<'PY' && echo "PASS: $2 每 required context 恰一条+15368" || { echo "FAIL: $2 context 校验未过"; fail=1; }
import json, os, sys
d = json.load(open(sys.argv[1]))
req = json.loads(os.environ['REQ_JSON'])
rsc = next((r for r in d.get('rules', []) if r.get('type') == 'required_status_checks'), {})
checks = rsc.get('parameters', {}).get('required_status_checks') or []
for ctx in req:
    e = [c for c in checks if c.get('context') == ctx]
    if not (len(e) == 1 and e[0].get('integration_id') == 15368):
        sys.exit(1)
sys.exit(0)
PY
}
```
- `:61` 调用 `one_catalyst "$d/payload.json" "PUT body"` → `both_contexts "$d/payload.json" "PUT body"`。
- 测 2（apply no-op）用的 `WITH="$FIX/ruleset-with-check.json"` 现含两 context = 全合规 → 仍是 no-op（builder 不再新增）→ 保持「no-op → skip PUT → 0」。**确认此点**（Step 4 验证）。

- [ ] **Step 3: 运行确认（先看是否如期）**

Run: `bash tests/scripts/governance/test-admin-runbook.sh`
Expected：泛化前若已改测试 helper，应在 `both_contexts` 处反映 builder 行为。实施 Step 1+2 后应全 PASS。

- [ ] **Step 4: 关键回归确认 — no-op 仍 no-op**

Run（确认全合规 fixture 不触发 PUT）：
```bash
d=$(mktemp -d)
GH_CMD="tests/scripts/governance/mockgh.sh" MOCK_FIXTURE="tests/scripts/governance/fixtures/ruleset-with-check.json" \
  MOCK_LOG="$d/calls.log" scripts/governance/admin-configure-required-checks.sh --apply --artifact-dir "$d" >/dev/null 2>&1; echo "rc=$?"
grep -q PUT "$d/calls.log" && echo "BAD: 全合规却 PUT" || echo "GOOD: 全合规 no-op 无 PUT"
```
Expected: `rc=0` + `GOOD: 全合规 no-op 无 PUT`（ruleset-with-check.json 现含两 context）。

- [ ] **Step 5: 运行全 governance 套件**

Run: `bash tests/scripts/governance/run-all.sh`
Expected: 全 PASS，退出 0。

- [ ] **Step 6: Commit**

```bash
git add scripts/governance/admin-configure-required-checks.sh tests/scripts/governance/test-admin-runbook.sh
git commit -m "feat(gov): admin-runbook 文案泛化 + 测试 both_contexts（Group C / codex M-NEW-1）

one_catalyst()→both_contexts()（派生 REQUIRED_CONTEXTS 断言每个 context 在位）；
admin 文案泛化；no-op 回归确认（ruleset-with-check 两 context 全合规仍 skip PUT）。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 文档交付（验收 + runbook + admin evidence 模板）

**Files:**
- Create: `docs/acceptance/2026-06-10-wave3-pr2-app-ci-orientation.md`
- Create: `docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md`
- Create: `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md`

- [ ] **Step 1: 写中文非-coder 验收清单**

`docs/acceptance/2026-06-10-wave3-pr2-app-ci-orientation.md`：Step/Action/Expected/Pass-Fail 表，**禁** `.claude/workflow-rules.json` forbidden phrases。覆盖：
1. PR 文件列表含 `.github/workflows/app-build.yml`；
2. workflow always-trigger（无 `paths:`）+ job name `iOS app build-for-running on macos-15`；
3. PR 的 `iOS app build-for-running on macos-15` check 报告且**绿**；
4. pbxproj 无 `Landscape`/`UpsideDown`，含 `UIRequiresFullScreen = YES`（Debug+Release 各一）；
5. `bash tests/scripts/governance/run-all.sh` 全 PASS；
6. `build-protection-put-payload.py --list-contexts` 输出两 context；
7. 既有 11 required check 无回归（merge 后 verifier assert）；
8. 三 doc（本验收 + runtime runbook + admin runbook）在文件列表。

- [ ] **Step 2: 写运行时 runbook 条目（旋转/窗口验证）**

`docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md`（对齐既有 `docs/runbooks/2026-06-07-*` 格式）：device/sim 步骤——iPhone 旋转设备应保持竖屏不旋转；iPad 旋转保持竖屏 + 无 Split View/Stage Manager 多窗缩放（`UIRequiresFullScreen` 生效）；记录最新 iPadOS Stage Manager 是否仍有窗口泄漏（残留观测点，spec §三.B2）。标注：执行是 user device 职责，作顺位 13 阻塞依赖之一。

- [ ] **Step 3: 写 post-merge admin runbook + evidence 模板**

`docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md`（镜像 `docs/governance/2026-05-21-pr1c-required-checks-evidence.md` 结构）：
- **前置时序（codex H1）**：`--apply` 只能在「所有 in-flight PR 已 rebase 到含 app-build.yml 的 main」或「顺位 1 已 merge」后执行；否则并行 PR 会被新 required context 卡死。
- canonical safe invocation（env -u 清理 + `--repo` pin + host=github.com + gh 绝对路径，沿用 1c）。
- dry-run 预期：diff 显示**新增** `iOS app build-for-running on macos-15`（非 no-op——这是真实 mutation，加第 12 条）。
- `--apply` 后 `verify-required-checks.sh --mode assert` 应 OK（两 context 在位）。
- evidence 回填占位（user 执行后补 redacted snapshot + sha256）。

- [ ] **Step 4: Commit**

```bash
git add docs/acceptance/2026-06-10-wave3-pr2-app-ci-orientation.md \
  docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md \
  docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md
git commit -m "docs: 顺位 2 验收清单 + 运行时 runbook + post-merge admin runbook/evidence 模板

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 最终验证（verification-before-completion）

**Files:** 无改动（全量验证）。

- [ ] **Step 1: 全 governance 套件**

Run: `bash tests/scripts/governance/run-all.sh`
Expected: 全 PASS，退出 0。

- [ ] **Step 2: app target 本地构建（pbxproj 改动已在位）+ plist 复查**

Run:
```bash
xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/app-derived-final CODE_SIGNING_ALLOWED=NO 2>&1 | tee /tmp/final.log | tail -2
grep -F "** BUILD SUCCEEDED **" /tmp/final.log && echo "BUILD OK"
plutil -p /tmp/app-derived-final/Build/Products/Debug-iphonesimulator/KlineTrainer.app/Info.plist | grep -iA2 "orientation\|RequiresFullScreen"
```
Expected: BUILD SUCCEEDED + plist Portrait-only + UIRequiresFullScreen=true。

- [ ] **Step 3: 模拟 CI gate 三断言（用 final.log）**

Run:
```bash
grep -F "** BUILD SUCCEEDED **" /tmp/final.log >/dev/null && echo "g1 ok"
if grep -F "** BUILD FAILED **" /tmp/final.log; then echo "g2 BAD"; else echo "g2 ok"; fi
if grep -E "(^|[[:space:]])error:" /tmp/final.log; then echo "g3 BAD"; else echo "g3 ok"; fi
```
Expected: `g1 ok` / `g2 ok` / `g3 ok`。

- [ ] **Step 4: grep gate — 无遗漏单-Catalyst 硬编码逻辑（carve-out outline+changelog，codex L-NEW-1）**

Run:
```bash
grep -rn "Mac Catalyst build-for-testing\|CATALYST" scripts/governance/ tests/scripts/governance/ \
  | grep -v "REQUIRED_CONTEXTS\|CATALYST_CONTEXT =\|both_contexts\|ruleset-.*\.json\|# \|comment" || true
echo "--- 人工核对：上面剩余均为 canonical 常量定义/注释/fixture，无遗漏的单-Catalyst-only 控制逻辑 ---"
```
Expected: 剩余命中均为常量定义/fixture/注释，无 verifier/builder 中遗漏的「仅查 Catalyst」控制流。

- [ ] **Step 5: 确认 0 业务代码 / 0 Swift 源改动**

Run: `git diff --stat fe0a23a..HEAD -- '*.swift' && echo "--- 上面应为空（0 Swift 源改动）---"`
Expected: 无 `.swift` 文件改动（pbxproj 不是 .swift）。

- [ ] **Step 6: 全 diff 自检**

Run: `git diff --stat fe0a23a..HEAD`
Expected: 仅 `.github/workflows/app-build.yml` + `project.pbxproj` + 3 governance 脚本 + 3 测试/fixture + 3 doc + spec/plan。

---

## Self-Review（writing-plans）

**Spec coverage：** Group A（Task 1）/ Group B（Task 2）/ Group C builder+verifier+admin+tests+fixtures（Task 3-5）/ 三 doc（Task 6）/ 验证（Task 7）。spec §七 验收 1-6 全有对应 task。H1 cross-PR 时序 → Task 6 Step 3 admin runbook。H-NEW-1 gate step 结构 → Task 1 workflow。H-NEW-2 单一真相 → Task 3 `--list-contexts` + Task 4/5 派生。M-NEW-1 → Task 5 both_contexts。M-NEW-2 → Task 4 新 fixture。

**Placeholder scan：** 无 TBD/TODO；workflow + pbxproj + Python + 测试均给完整内容。

**Type/命名一致性：** `REQUIRED_CONTEXTS` / `APP_BUILD_CONTEXT` / `--list-contexts` / `both_contexts()` / job name `iOS app build-for-running on macos-15` 全计划统一；`ensure_catalyst`→`ensure_required` 改名同步 main() + 测试。
