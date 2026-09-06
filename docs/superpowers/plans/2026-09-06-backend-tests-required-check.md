# 把「后端测试」纳入必需检查 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `backend pytest (full suite)` 加进 canonical 必需检查清单，并钉住那个 job 名不被改动（改名会让全仓 PR 卡死）。

**Architecture:** 往 `build-protection-put-payload.py` 的 `REQUIRED_CONTEXTS` 追加一项，复用既有 builder → apply → verify 三件套；给 `backend/tests/test_backend_tests_workflow_runs_on_every_pr.py`（已在必需门里跑）加两条相等断言钉住 job 名。**PR 本身不改 GitHub 设置** —— 应用是 user 的独立动作。

**Tech Stack:** Python 3.11（stdlib + pytest + pyyaml）、bash、GitHub Rulesets API

**Spec:** `docs/superpowers/specs/2026-09-05-backend-tests-required-check-design.md`

## Global Constraints

- **判绿要跑两条命令，缺一不可**（spec §5.1）：
  - `bash tests/scripts/governance/run-all.sh` → 末行 `ALL GREEN` 且全文无 `FAIL:`
  - `python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py`（**从仓库根跑**）→ 无 failed
  - ⚠️ 第一条**不跑** pin 文件；钉名判据只在第二条里体现。
- **必需检查名逐字** = `backend pytest (full suite)`（spec §3.2）。差一个字符 → 全仓 PR 死锁。
- **钉名判据必须是「相等」不是「成员关系」**（spec §3.2.1）。写成成员关系会被「改成清单里的另一条」绕过。
- **过时表述的权威口径 = `grep -rn "Catalyst" scripts/governance/` 的输出逐条定性**（spec §4.2）。**不要照 spec 里的行号改** —— 行号会被本次改动自己移位。
- **改动面唯一真相 = spec §4 那张表**（spec §4.3）。
- **`.github/workflows/**` 一律不由 Claude 写入**，改动走 ceremony 由 user `cp`（spec §4.4）。
  ⚠️ 实测 `.claude/settings.json` 的 deny 只覆盖 `Edit`/`Write` 工具与 `Bash(* >> …)`，
  **`sed -i` / `cp` 并不被拦** —— 但用它们写这些文件就是「用 Bash 绕 deny rule」，
  本仓明令禁止。**变异验证也不例外**：不改真文件，改用「临时副本 + 把测试模块里的
  `WORKFLOW` 指过去」（PR #180 已验证过的做法，见 Task 4 Step 3）。
- 每次跑 Python 变异前**清 `__pycache__`**（本仓 memory：等长变异 + 同秒复原会命中陈旧字节码）。

---

### Task 1: canonical 清单加入 backend context

**Files:**
- Modify: `scripts/governance/build-protection-put-payload.py`
- Test: `tests/scripts/governance/test_build_payload.py`

**Interfaces:**
- Produces: `BACKEND_TESTS_CONTEXT`（模块级常量，str）；`REQUIRED_CONTEXTS` 变为三元素 list。后续 Task 4 会 import 这两个名字。

- [ ] **Step 1: 先改测试（TDD 红）**

在 `tests/scripts/governance/test_build_payload.py` 顶部常量区（`APP_BUILD = ...` 那行之后）加：

```python
BACKEND = "backend pytest (full suite)"
```

把文件末尾两处期望改成三元组：

```python
def test_list_contexts_cli():
    p = subprocess.run([sys.executable, str(SCRIPT), "--list-contexts"],
                       capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=10)
    assert p.returncode == 0
    assert json.loads(p.stdout) == [CATALYST, APP_BUILD, BACKEND]


def test_required_contexts_constant():
    assert mod.REQUIRED_CONTEXTS == [CATALYST, APP_BUILD, BACKEND]
```

- [ ] **Step 2: 跑测试确认红**

```bash
find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
python -m pytest tests/scripts/governance/test_build_payload.py -q
```

预期：`test_list_contexts_cli` 与 `test_required_contexts_constant` 两条 FAIL，报实得两元素、期望三元素。

- [ ] **Step 3: 改常量**

在 `scripts/governance/build-protection-put-payload.py` 的 `APP_BUILD_CONTEXT = ...` 之后加一行，并把清单改成三项：

```python
BACKEND_TESTS_CONTEXT = "backend pytest (full suite)"
# canonical 必需 context 单一真相（codex H-NEW-2）；verifier/admin/测试经 --list-contexts 派生
REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT, BACKEND_TESTS_CONTEXT]
```

- [ ] **Step 4: 跑测试确认绿**

```bash
find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
python -m pytest tests/scripts/governance/test_build_payload.py -q
```

预期：`15 passed`。

- [ ] **Step 5: 变异 M1 / M3 / M4（spec §5.2 要求全部亲跑）**

三条都打常量与清单本身，故都在本 Task 做。**复原一律用 `cp` 备份、不用 `git checkout`**
（本仓 memory `feedback_git_checkout_destroys_uncommitted_work`：那会连同本 Task 尚未提交的
正当改动一起冲掉，而且冲掉后不留任何痕迹）。

```bash
BK=/tmp/builder-m134.py
cp scripts/governance/build-protection-put-payload.py "$BK"
run() { find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null; \
        python -m pytest tests/scripts/governance/test_build_payload.py -q 2>&1 | tail -2; }
mut() { python3 -c "
import pathlib,sys
p=pathlib.Path('scripts/governance/build-protection-put-payload.py')
t=p.read_text(encoding='utf-8'); old,new=sys.argv[1],sys.argv[2]
assert t.count(old)==1, '锚点不唯一，拒绝变异'
p.write_text(t.replace(old,new),encoding='utf-8')" "$1" "$2"; }

echo '── M1 常量拼错一个字符 ──'
mut 'BACKEND_TESTS_CONTEXT = "backend pytest (full suite)"' 'BACKEND_TESTS_CONTEXT = "backend pytest (full suit)"'
run; cp "$BK" scripts/governance/build-protection-put-payload.py

echo '── M3 删掉既有的 APP_BUILD_CONTEXT ──'
mut 'REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT, BACKEND_TESTS_CONTEXT]' 'REQUIRED_CONTEXTS = [CATALYST_CONTEXT, BACKEND_TESTS_CONTEXT]'
run; cp "$BK" scripts/governance/build-protection-put-payload.py

echo '── M4 顺序调换 ──'
mut 'REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT, BACKEND_TESTS_CONTEXT]' 'REQUIRED_CONTEXTS = [BACKEND_TESTS_CONTEXT, CATALYST_CONTEXT, APP_BUILD_CONTEXT]'
run; cp "$BK" scripts/governance/build-protection-put-payload.py

echo '── 复原核对（判据 = 两个 md5 相同；git status 会显示 M，见下方说明）──'
md5 -q "$BK" scripts/governance/build-protection-put-payload.py
git status --porcelain scripts/governance/build-protection-put-payload.py
```

⚠️ **这里的 `git status` 会显示 ` M`，那是 Step 3 的正当改动，不是变异残留** —— 本 Task 的
提交在 Step 6，此刻还没提交。**判据只看 md5 那两行是否相同**。

⛔ **不要为了让 `git status` 变空去跑 `git checkout --`** —— 那会把 Step 3 的改动一起冲掉。
（初版 plan 在这里写了「必须为空」，与自身步骤顺序矛盾，且恰好把执行者推向那条禁令；
Kimi plan-R5 指出。Task 4 Step 4 的同款检查则成立，因为那时 builder 已在 Task 1 提交。）


预期：

- **M1 必须红**（`test_required_contexts_constant` 与 `test_list_contexts_cli` 都报字符串不等）；
- **M3 必须红** —— 这一档证明测试**不是只盯新加的那一项**；
- **M4**：`test_build_payload.py` 的断言是**精确列表相等**，所以顺序变了应当**也红**。
  ⚠️ 若实测为**绿**，说明判据不约束顺序 —— 那就在 spec §5.2 明写「顺序无语义」，
  **不要假装它被测了**（spec §5.2 M4 行已预留这个处置）。

- [ ] **Step 6: 提交**

```bash
git add scripts/governance/build-protection-put-payload.py tests/scripts/governance/test_build_payload.py
git commit -m "canonical 必需检查清单加入 backend pytest (full suite)；M1/M3/M4 变异已亲跑"
```

---

### Task 2: 让两个 bash 测试套件重新变绿

**Files:**
- Modify: `tests/scripts/governance/fixtures/*.json`（**哪几个由实跑决定**）
- 可能 Modify: `tests/scripts/governance/test-verify-required-checks.sh`、`tests/scripts/governance/test-admin-runbook.sh`

**Interfaces:**
- Consumes: Task 1 的三元素 `REQUIRED_CONTEXTS`（verify 脚本经 `--list-contexts` 动态派生）。

- [ ] **Step 1: 跑完整入口，记录红了哪些**

```bash
bash tests/scripts/governance/run-all.sh 2>&1 | tee /tmp/gov-after-task1.log
grep -n "^FAIL" /tmp/gov-after-task1.log
```

预期：出现若干 `FAIL:` 行。spec §4.1 已预判至少 verify 的 "assert happy → 0"、admin-runbook 的 #2 / #5 / #6a 会破。**以实际输出为准**。

- [ ] **Step 2: 逐个红项定位它读的是哪个 fixture**

对每条 `FAIL:`，在对应 `.sh` 里找到该用例，记下它用的 fixture 文件名。

- [ ] **Step 3: 给「代表已合规」的 fixture 补上 backend context**

对每个需要修的 fixture，在其 `required_status_checks` 数组里追加：

```json
{"context": "backend pytest (full suite)", "integration_id": 15368}
```

**判断规则（Kimi plan-R2 订正，初版写错了）**：

> **每个 fixture 只应在「它要测的那一个维度」上不合规；其它维度必须合规。**

初版写的是「故意不合规的样本一律不要动」—— **错**。按维度分：

| fixture 要测什么 | 补不补 backend context |
|---|---|
| 代表「已合规」（如 `ruleset-with-check.json`、`ruleset-extra-valid.json`） | ✅ **补** |
| 要测的正是「缺某个 context」（如 `ruleset-partial.json`、`ruleset-without-check.json`） | ❌ **不补** —— 补了就把它要测的场景抹掉 |
| 要测的是**别的**维度、且该维度在检查顺序里**排在 checks 之后**（如 `ruleset-extra-bypass.json` 测多出 bypass） | ✅ **必须补**，理由见下 |

⚠️ **`ruleset-extra-bypass.json` 是最容易漏的一个，而且漏了不会变红**：
`admin-configure-required-checks.sh` 的检查顺序里 **checks 子集（`:107`）早于 bypass 精确相等（`:109`）**。
不给它补 backend context，#6d 就会在 `:107` 因「缺 context」先挂 —— 退出码仍是 1、
`run-all.sh` 仍然 `ALL GREEN`（该用例只断言 rc=1），但它**从此永远测不到 bypass 那条分支**。
这是典型的**静默失去覆盖**，「跑一遍红哪个改哪个」发现不了。

- [ ] **Step 4: 重跑直到全绿**

```bash
bash tests/scripts/governance/run-all.sh 2>&1 | tail -3
```

预期：末行 `ALL GREEN`。

- [ ] **Step 5: #6d 归因单独确认 —— 用「拿掉它要测的东西，应当转绿」来证明**

rc 无法区分失败理由（都是 1），所以不能只看 rc。做法是**拿掉它声称要测的那个缺陷，
看它是否转为成功**：

```bash
python3 - <<'ATTR'
import json, pathlib, shutil, subprocess, tempfile, os
FIX = pathlib.Path("tests/scripts/governance/fixtures")
src = FIX / "ruleset-extra-bypass.json"
d = json.loads(src.read_text())
# 拿掉「多出的 bypass actor」——只留 admin 那一条
d["bypass_actors"] = [a for a in d.get("bypass_actors", [])
                      if a.get("actor_type") == "RepositoryRole" and a.get("actor_id") == 5]
tmp = FIX / "_attr_probe.json"
tmp.write_text(json.dumps(d, indent=2), encoding="utf-8")
print("探针 fixture 已生成:", tmp)
ATTR
```

然后把 `test-admin-runbook.sh` 里 #6d 那行的 `MOCK_FIXTURE_N3` 临时指向 `_attr_probe.json`
跑一次，看退出码。

- **预期：`rc=0`（成功）** —— 说明 #6d 之前的 rc=1 **确实是 bypass 那条判据判出来的**。
- ⚠️ **若仍 `rc=1`**：说明它是在更早的 `:107`「缺 context」挂的 —— **Step 3 漏给这个 fixture
  补 backend context 了**，回去补上再来。

⚠️ **临时改 `test-admin-runbook.sh` 之前先 `cp` 备份，复原也用 `cp`**：

```bash
cp tests/scripts/governance/test-admin-runbook.sh /tmp/runbook-attr-backup.sh
# …（临时把 #6d 那行的 MOCK_FIXTURE_N3 指向 _attr_probe.json，跑，看 rc）…
cp /tmp/runbook-attr-backup.sh tests/scripts/governance/test-admin-runbook.sh
rm -f tests/scripts/governance/fixtures/_attr_probe.json
md5 -q /tmp/runbook-attr-backup.sh tests/scripts/governance/test-admin-runbook.sh   # 两行必须相同
git status --porcelain tests/scripts/governance/                                    # 只剩预期的 fixture 改动
```

⛔ **绝对不要用 `git checkout -- <file>` 复原**：本 Task 头部把
`test-admin-runbook.sh` 列为「可能 Modify」，而提交要到下一步才发生 —— `git checkout`
会把本 Task 里**尚未提交的正当改动**一并冲掉，且**冲掉后不留任何痕迹**，随后那条
`git status` 也看不出少了什么（本仓 memory `feedback_git_checkout_destroys_uncommitted_work`；
初版 plan 就是这么写的，Kimi plan-R3 指出）。

- [ ] **Step 6: 提交**

```bash
git add tests/scripts/governance/
git commit -m "治理测试 fixture 同步三项清单；#6d 归因已单独确认"
```

---

### Task 3: 按命令口径清掉过时表述

**Files:**
- Modify: `scripts/governance/build-protection-put-payload.py`、`verify-required-checks.sh`、`admin-configure-required-checks.sh`、`tests/scripts/governance/test-admin-runbook.sh`

- [ ] **Step 1: 跑权威口径命令，逐条定性**

```bash
grep -rn "Catalyst" scripts/governance/
```

对每条命中判断：是**常量定义本身**（合法，不动）还是**过时表述**（要改）。spec §4.2 记录了在 `0ec2e22` 上的定性结果作参考，但**以你这次跑出来的为准**。

- [ ] **Step 2: 逐条改写**

把「Catalyst + app-build」「仅 Catalyst 谓词」「Catalyst check 在位」这类说法，改成不写死项数的表述，例如「canonical `REQUIRED_CONTEXTS`（见 `build-protection-put-payload.py`）」。

⚠️ `admin-configure-required-checks.sh` 里那条 `GATE PASS` 是**用户可见输出**，不是注释 —— 改它等于改管理员看到的文案，务必让它如实反映「验证了清单里的全部 context」。

- [ ] **Step 3: 标识符与注释的文本扫描**（测试发现不了这些）

```bash
grep -rn "both_contexts\|两条\|两项" tests/scripts/governance/ scripts/governance/
```

`test-admin-runbook.sh` 的 helper 名 `both_contexts` 与其注释在三项清单下已过时。**改名要连同全部调用点一起改**（本仓 memory：大批量机械改名是缺陷源 —— 改完按语义分组复核，不是只扫残留为 0）。

- [ ] **Step 4: 两条判绿命令都跑一遍**

```bash
bash tests/scripts/governance/run-all.sh 2>&1 | tail -2
python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py -q
```

预期：`ALL GREEN`；`3 passed`。

- [ ] **Step 5: 提交**

```bash
git add scripts/governance/ tests/scripts/governance/
git commit -m "清掉「清单=两项」家族的过时表述（按 grep 口径逐条定性）"
```

---

### Task 4: 钉住 job 名（两条相等断言）

**Files:**
- Modify: `backend/tests/test_backend_tests_workflow_runs_on_every_pr.py`

**Interfaces:**
- Consumes: Task 1 的 `BACKEND_TESTS_CONTEXT` 与 `REQUIRED_CONTEXTS`。

- [ ] **Step 1: 加载 builder 并写新判据**

三处改动：

1. 在 `import yaml` 之后加一行 `import importlib.util`；
2. 把文件里**已有的** `WORKFLOW` 定义块（当前 32-34 行，形如
   `WORKFLOW = (` / `    Path(__file__)...` / `)`）**整块替换**为下面代码块里
   `_REPO_ROOT` / `WORKFLOW` / `_BUILDER` **那三行**（不是代码块开头的 import 行）；
3. 下面代码块里的 `def _builder():` **整个函数照抄进去**，位置放在那三行常量之后、
   已有的 `def _on_section():` 之前。

> ⚠️ 三段都要落地，别把 `_builder()` 当成「示例上下文」跳过（Kimi plan-R4 指出这处歧义）——
> 跳过它的话，本 Task 末尾新增的两个测试都会 `NameError`。

⚠️ **是替换、不是新增**：该文件已有一份 `WORKFLOW` 定义，再加一份就是制造第二份真相
（本 plan 通篇在防这个；Kimi plan-R1 指出）。



```python
import importlib.util

_REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = _REPO_ROOT / ".github/workflows/backend-tests.yml"
_BUILDER = _REPO_ROOT / "scripts/governance/build-protection-put-payload.py"


def _builder():
    """按路径加载 canonical 清单（文件名带连字符，不能直接 import）。

    只依赖 stdlib（该脚本仅 import argparse/json/sys），所以在 codeowners-config-check
    那道必需门里（只装了 pyyaml+pytest）也能跑。
    """
    assert _BUILDER.is_file(), f"{_BUILDER} 不存在 —— canonical 清单没了，判据无从谈起"
    spec = importlib.util.spec_from_file_location("build_payload", _BUILDER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod
```

在文件末尾追加：

```python
def test_job_name_equals_canonical_backend_context():
    """`backend-tests.yml` 里必须有一个 job 的 name **等于** canonical 常量。

    为什么是「等于」而不是「在清单里」（spec §3.2.1）：清单里有多条 context，
    写成成员关系时，把这个 job 改名成**清单里的另一条**（例如 Catalyst 那个名字）
    判据仍会绿，而必需检查 `backend pytest (full suite)` 永远等不到结果 → 全仓 PR 死锁。
    """
    mod = _builder()
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    jobs = doc.get("jobs")
    assert isinstance(jobs, dict) and jobs, (
        f"{WORKFLOW.name} 里取不到 jobs 段 —— 本判据的解析口径已失效"
    )
    names = {j.get("name") for j in jobs.values() if isinstance(j, dict)}
    assert mod.BACKEND_TESTS_CONTEXT in names, (
        f"没有任何 job 的 name 等于 canonical 必需 context "
        f"{mod.BACKEND_TESTS_CONTEXT!r}（实得 {sorted(n for n in names if n)}）。\n"
        "GitHub 的必需检查按 job 显示名匹配：名字对不上 ⇒ 该检查永远停在\n"
        "「Expected — waiting for status」⇒ **全仓 PR 都合不了**。\n"
        "要改名，必须同时改 scripts/governance/build-protection-put-payload.py 的\n"
        "BACKEND_TESTS_CONTEXT，并重新跑一次 admin 应用脚本把 ruleset 也改掉。"
    )


def test_backend_context_is_in_canonical_required_list():
    """canonical 清单里必须留着这一项，否则应用脚本不会再保证它在位。"""
    mod = _builder()
    assert mod.BACKEND_TESTS_CONTEXT in mod.REQUIRED_CONTEXTS, (
        "BACKEND_TESTS_CONTEXT 不在 REQUIRED_CONTEXTS 里 —— "
        "应用脚本将不再保证该必需检查在位（它只遍历 REQUIRED_CONTEXTS）"
    )
```

- [ ] **Step 2: 跑，确认现在是绿的**

```bash
find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py -q
```

预期：`5 passed`。

> ⚠️ 这条判据钉的是**已经成立的不变量**，所以它一写出来就是绿的 —— 没有「功能缺失导致的红」可看。
> 它的判别力只能靠**变异**来证明，见下一步。**不做下一步就等于没验证过**。

- [ ] **Step 3: 变异验证 —— 必须亲眼看到红（全程不碰真文件）**

把下面这段写成 `/tmp/mut-pin.py` 再跑。它把**临时副本**喂给测试模块，真文件全程不动：

```python
import pathlib, sys, tempfile
sys.path.insert(0, "backend/tests")
import test_backend_tests_workflow_runs_on_every_pr as g

REAL = pathlib.Path(".github/workflows/backend-tests.yml")
BASE = REAL.read_text(encoding="utf-8")
NAME = "name: backend pytest (full suite)"
# 锚点唯一性（与 Task 1 的 mut() 保持同样的防护；Kimi plan-R4 指出这里原先缺这道）：
# 若该字符串在文件里不止一处，replace 会改到别处，M6/M7 的红/绿归因就失真了。
assert BASE.count(NAME) == 1, f"锚点出现 {BASE.count(NAME)} 次，拒绝变异（预期恰 1 次）"

CASES = {
    "M5 反向对照（不变异）":   BASE,
    "M6 改掉一个字符":         BASE.replace(NAME, "name: backend pytest (full suit)"),
    "M7 改成清单里的另一条":   BASE.replace(NAME, "name: Mac Catalyst build-for-testing on macos-15"),
}
for label, text in CASES.items():
    with tempfile.NamedTemporaryFile("w", suffix=".yml", delete=False, encoding="utf-8") as f:
        f.write(text); tmp = pathlib.Path(f.name)
    g.WORKFLOW = tmp
    try:
        g.test_job_name_equals_canonical_backend_context()
        print("  绿  " + label)
    except AssertionError as e:
        print("  红  " + label + " -> " + str(e).splitlines()[0][:70])
    finally:
        tmp.unlink()
```

```bash
find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
python3 /tmp/mut-pin.py
git status --porcelain .github/workflows/backend-tests.yml    # 必须输出为空
```

预期：M5 绿；**M6、M7 都红**。

- ⚠️ **M7 若绿，说明判据被写成了成员关系** —— 回 Step 1 改成相等。
- ⚠️ 最后那条 `git status` **必须为空**，证明变异全程没碰真文件。

- [ ] **Step 4: M8 变异（清单里删掉该项）**

builder 不在 `.github/workflows/` 下，可直接改真文件，但仍走「备份 → 变异 → md5 复原」：

```bash
cp scripts/governance/build-protection-put-payload.py /tmp/builder-backup.py
python3 -c "
import pathlib
p = pathlib.Path('scripts/governance/build-protection-put-payload.py')
t = p.read_text(encoding='utf-8')
old = 'REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT, BACKEND_TESTS_CONTEXT]'
assert t.count(old) == 1, '锚点不唯一，拒绝变异'
p.write_text(t.replace(old, 'REQUIRED_CONTEXTS = [CATALYST_CONTEXT, APP_BUILD_CONTEXT]'), encoding='utf-8')
"
find . -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py -q 2>&1 | tail -3
cp /tmp/builder-backup.py scripts/governance/build-protection-put-payload.py
md5 -q /tmp/builder-backup.py scripts/governance/build-protection-put-payload.py
git status --porcelain scripts/governance/build-protection-put-payload.py   # 必须为空
```

预期：变异时 `test_backend_context_is_in_canonical_required_list` FAIL；复原后两个 md5 相同、`git status` 为空。

- [ ] **Step 5: 订正该文件里已过时的表述**

**权威口径是命令的输出，不是下面这张清单**（同 §4.2 的道理 —— 我在 spec 阶段因为手抄
封闭清单连抄漏三次）：

```bash
grep -n "必需检查\|三条\|判据" backend/tests/test_backend_tests_workflow_runs_on_every_pr.py
```

对**每一条**命中定性：仍然成立，还是被本次改动翻转了。已知至少这几处要改
（spec §4.2 家族②③，**不是全部**）：
- docstring 里「三条判据」→ 现在是**五条**；
- 「`backend pytest (full suite)` 不是分支保护的必需检查，所以无过滤器不会造成死锁」——
  前提已翻转，改成「它**是**必需检查；无过滤器保证它每个 PR 都报告，正是它能当必需检查的前提」；
- 「又不是必需检查，于是能合进去」→ 改成「该必需检查会因此永远等不到结果，PR 反而会卡死」；
- **`:123` 附近**「合并前的强制拦截需要独立的必需检查，属本次范围之外的已知残留」——
  前提同样翻转（backend 成为必需检查后，自我排除型 PR 会卡在
  「Expected — waiting for status」，**合并前拦截事实上已存在**）。
  ⚠️ 这一处 plan 初版**漏了**（Kimi plan-R1 指出）：spec §4.2 明写家族③有 3 处，我只抄了
  2 处 —— 又一次「修复弄丢上一轮的修复」。这正是本步骤改用命令口径的原因。

- [ ] **Step 6: 两条判绿命令都跑，然后提交**

```bash
bash tests/scripts/governance/run-all.sh 2>&1 | tail -2
python -m pytest backend/tests/test_backend_tests_workflow_runs_on_every_pr.py -q
git add backend/tests/test_backend_tests_workflow_runs_on_every_pr.py
git commit -m "钉住 backend job 名（两条相等断言）+ 订正已翻转前提的注释"
```

---

### Task 5: 订正必需门 workflow 里那段变假的安全论证（ceremony）

**Files:**
- Modify: `.github/workflows/codeowners-config-check.yml`（**只改注释**）

- [ ] **Step 1: 生成待落地文件**

从当前分支的版本生成，只替换注释里那句已翻转的前提：

```bash
python3 - <<'PY'
import pathlib
p = pathlib.Path(".github/workflows/codeowners-config-check.yml")
t = p.read_text(encoding="utf-8")
old = ("      # 工作流一次都不启动 —— 判据永远执行不到，而它又不是必需检查，于是能合进去，\n"
       "      # 把「只改 scripts/** 或 iOS 契约文件的 PR 不跑后端测试」这个盲区原样放回来\n")
new = ("      # 工作流一次都不启动 —— 判据永远执行不到。canonical 清单已把 backend pytest 列为\n"
       "      # 必需检查，于是分两种情形：**管理员应用该清单之后**，那种 PR 会卡在\n"
       "      # 「Expected — waiting for status」而合不进去；**在应用之前**，它仍能合进去，\n"
       "      # 把「只改 scripts/** 或 iOS 契约文件的 PR 不跑后端测试」这个盲区原样放回来。\n"
       "      # 两种情形下判据都仍须放在本 workflow：「卡住」不等于「被判定为违规」，\n"
       "      # 也给不出可读的失败原因。\n")
assert t.count(old) == 1, "锚点不唯一/找不到，拒绝生成"
pathlib.Path("/tmp/co2.yml").write_text(t.replace(old, new), encoding="utf-8")
print("已生成 /tmp/co2.yml")
PY
diff -u .github/workflows/codeowners-config-check.yml /tmp/co2.yml
```

预期：diff 只有注释行，**没有任何 `on:` / `jobs:` / `run:` 的变化**。

- [ ] **Step 2: 让 user 落地**

写 `/tmp/put3.sh`（内含绝对路径 + md5 校验 + 打印目标分支），让 user 在真实终端跑 `bash /tmp/put3.sh`。

- [ ] **Step 3: 落地后核对只改了注释**

```bash
git diff --stat .github/workflows/codeowners-config-check.yml
python3 -c "
import yaml,json
d=yaml.safe_load(open('.github/workflows/codeowners-config-check.yml'))
print('on 段:', json.dumps(d.get('on', d.get(True)), ensure_ascii=False))
print('job id:', list(d['jobs']))
print('步骤数:', len(d['jobs']['codeowners-config-check']['steps']))
"
```

预期：`on` 仍是 `{"pull_request": null}`；job id 仍是 `codeowners-config-check`；步骤数与改动前一致（**先记下改动前的数字再比**）。

- [ ] **Step 4: 提交**

```bash
git add .github/workflows/codeowners-config-check.yml
git commit -m "订正必需门里那段已翻转的安全论证（只改注释）"
```

---

### Task 6: 真环境干跑 + 验收文档

**Files:**
- Create: `docs/acceptance/2026-09-06-backend-tests-required-check.md`

- [ ] **Step 1: 拿真实 ruleset 跑 builder（纯函数，不发网络请求）**

```bash
gh api "repos/{owner}/{repo}/rulesets/15660830" > /tmp/ruleset-live.json
python3 scripts/governance/build-protection-put-payload.py --ruleset-json /tmp/ruleset-live.json --out /tmp/payload-new.json
python3 scripts/governance/build-protection-put-payload.py --normalize-only --ruleset-json /tmp/ruleset-live.json --out /tmp/payload-cur.json

# ⚠️ 必须先格式化再 diff：builder 的 serialize() 用 separators=(",",":") 且无缩进，
# 产出是**单行紧凑 JSON** —— 直接 diff 会得到两条数 KB 的长行，人眼无法逐字段核，
# 而 spec §5.3 说这是应用前唯一能看清后果的手段、验收 A5 还交给非程序员判定。
# （初版 plan 漏了这一步，Kimi plan-R5 指出。）
python3 -m json.tool --sort-keys /tmp/payload-cur.json > /tmp/payload-cur.pretty.json
python3 -m json.tool --sort-keys /tmp/payload-new.json > /tmp/payload-new.pretty.json
diff -u /tmp/payload-cur.pretty.json /tmp/payload-new.pretty.json
```

预期：diff 是**逐行可读**的，且**只有新增行**（两条 context 各自的 `context` /
`integration_id`），没有任何删除行或修改行。

- [ ] **Step 2: 逐字段核 diff（spec §5.3）**

确认：**只多出 2 条 context**（backend + app-build）；且以下**一个字都没变** ——
`enforcement`、`conditions`、`bypass_actors`、其余 4 条 context 及其 `integration_id`、
**`rules` 数组里那条 `pull_request` 规则**（它装着批准数；单人仓库一旦被改成 ≥1 就再也合不了任何 PR）。

- [ ] **Step 3: 写验收文档**

把 spec §8 的 A0–A8 抄进 `docs/acceptance/2026-09-06-backend-tests-required-check.md`，并附上 Step 1 的 diff 原文（作为 A5 的凭据）。

- [ ] **Step 4: 提交**

```bash
git add docs/acceptance/
git commit -m "验收清单 A0-A8 + 真实 ruleset 干跑 diff 凭据"
```

---

## Self-Review

**Spec 覆盖**：§3.1 连带效应 → Task 6 Step 2 核 diff；§3.2.1 钉名 → Task 4；§4 改动面 6 个文件 → Task 1/2/3/4/5 全覆盖；§4.2 三个家族 → Task 3（①）、Task 4 Step 5（②③）；§5.1 双命令口径 → Global Constraints + 每个 Task 的验证步；§5.2 变异 M1–M8 → **M1/M3/M4 在 Task 1 Step 5；M2≡M8 与 M8 在 Task 4 Step 4；M5/M6/M7 在 Task 4 Step 3**（Task 2 Step 5 是 #6d 归因探针，**不属于**变异表，初版 Self-Review 把它算进覆盖是虚报，Kimi plan-R3 指出）；§5.3 干跑 → Task 6；§7 交付次序与第 0 步（在途 PR）→ 验收 A0（Task 6 Step 3）；§9 回滚凭据 → 验收 A7b。

**占位符扫描**：无 TBD/TODO；每个代码步骤都有可直接执行的代码块；「哪几个 fixture」刻意留给实跑决定，但给了判断规则（只改「语义上应已合规」的）与不要动的反例。

**类型一致**：`BACKEND_TESTS_CONTEXT` / `REQUIRED_CONTEXTS` 在 Task 1 定义，Task 4 通过 `_builder()` 消费，名字一致；测试常量 `BACKEND` 仅在 `test_build_payload.py` 内部使用，不跨文件。
