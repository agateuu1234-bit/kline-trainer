---
phase_delivery: true
---

# 恢复 CI 的 pglast 测试依赖与共享 Pin 守卫 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 恢复被 `pglast==7.13` 从 PyPI 下线阻塞的后端 CI，并在 `backend/tests/test_requirements_api.py` 补齐 `requirements-dev.txt ↔ requirements-test.txt` 共享精确版本一致守卫与负向单测。

**Architecture:** 接续既有分支 `fix/pglast-pin-7.24`（提交 `3e97faa1`）已落地的 `pglast==7.13 → 7.24` 升级，先创建隔离 Python 3.11 虚拟环境并实装依赖、确认 PyPI Linux wheel；随后在 `backend/tests/test_requirements_api.py` 收紧 `_EXACT_PIN_RE` 以拒绝通配符（`7.*`）与复合约束（`,!=...`），提取共用助手 `_assert_shared_pins_match` 统一校验 `api ↔ test` 与 `dev ↔ test` 共享包版本一致；最后全量跑通 `backend/tests/`（零跳过）并交付中文验收清单。

**Tech Stack:** Python 3.11 · pip · pytest 8.4.2 · pglast 7.24

**Spec:** `docs/superpowers/specs/2026-11-23-pglast-pin-recovery-design.md`

## Global Constraints

- 工作分支与 PR 分支名统一：本地与远端均统一使用 **`fix/pglast-pin-7.24-recovery`**（基于 `3bc4905c` 创建，因 `fix/pglast-pin-7.24` 已被其他 worktree 检出无法重复检出）；Task 1 Step 0 与 Task 3 提交落在该分支上，Task 4 推送与 PR 均以 `fix/pglast-pin-7.24-recovery` 为源与 `--head`（`git push -u origin fix/pglast-pin-7.24-recovery` 与 `gh pr create --base main --head fix/pglast-pin-7.24-recovery`），避免与旧 worktree 锁定的本地 `fix/pglast-pin-7.24` 发生引用错位。
- 治理边界（不碰 `.claude/**`）：`main` 上 `.claude/hooks/guard-attest-ledger.sh`（Claude Code PreToolUse 钩子）存在既有不兼容（`ledger-lib.sh:164` 返回 `fingerprint|base_sha` 而 `guard-attest-ledger.sh:126-141` 比对裸 `fingerprint`，且其要求 Spec/Plan 的 `file:` 账本条目而 `codex-attest.sh` 已禁止 `--target`；`.claude/settings.json:124` 亦禁止 Claude Code 执行 `gh pr comment`）。修改 `.claude/**` 属独立治理工作，**不在本 PR 范围内**。因此 Gate 3 写入分支凭证后，Step 2（`git push` / `gh pr create`）与 Step 3（`gh pr comment`）由用户终端执行（或在经用户逐条显式授权、不挂载 `.claude/settings.json` 钩子的 Antigravity 会话中执行）；若在挂载 `.claude/hooks/` 的 Claude Code 会话中执行，则在 Gate 3 完成后移交用户终端，不得修改或绕过钩子。
- 仅使用精确 `name==version` 固定版本，禁止 `>=` / `<=` / `~=` / `>` / `<`、通配符（`==7.*`）及复合多约束（`==7.24,!=7.24.1`）。
- 生产依赖 `backend/requirements.txt` 与 `backend/requirements-api.txt` 一字不改；不顺带修改 PR #179 或 PR #210 的代码。
- 测试中禁止硬编码 `"7.24"` 版本字符串来锁定具体版本号；守卫按结构化解析与集合对比校验。
- 不修改宿主共享虚拟环境；全套 `backend/tests/` 必须 `0 skipped / 0 failed / 0 errored`。
- 中文非程序员验收清单严禁出现禁用词（`验证通过即可`、`看起来正常`、`应该没问题`、`should work`、`looks fine`）。

## Review Focus

1. `requirements-dev.txt` 与 `requirements-test.txt` 共享包版本漂移（如仅改其中一份的 `pglast` 版本）→ 守卫必须抛出含漂移包名的 `AssertionError`。
2. `requirements-dev.txt` 出现 `requirements-test.txt` 中缺失的包 → 子集断言必须直接失败并列出缺失包名。
3. `requirements-dev.txt` 引入非精确约束（范围 `>=`、通配符 `==7.*` 或复合约束 `==7.24,!=7.24.1`）→ `_parse` 必须直接抛 `AssertionError`，不能静默放行。
4. 两份清单交集意外为空 → `_assert_shared_pins_match` 必须因空交集失败，防止循环零次执行而假绿。
5. `pglast==7.24` 缺少 Linux `x86_64` 的 `cp311` 或 `cp312` wheel → 核查 PyPI JSON 元数据，并在验收中明确区分「Python 3.12 依赖安装验证」与「Python 3.11 完整 SQL 测试执行」。

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `backend/requirements-dev.txt` | 已由 `3e97faa1` 修改 | `pglast==7.13` → `pglast==7.24` |
| `backend/requirements-test.txt` | 已由 `3e97faa1` 修改 | `pglast==7.13` → `pglast==7.24` |
| `backend/tests/test_insert_schema_version_guard.py` | 已由 `3e97faa1` 修改 | 注释 `pglast==7.13` → `pglast==7.24` |
| `requirements-dev.txt` | 修改（Gate 3 finding 修复） | `pytest>=7.4` → `pytest==8.4.2`，消除根目录 dev 清单非精确 pin 盲区 |
| `docs/superpowers/specs/2026-11-23-pglast-pin-recovery-design.md` | 修改 | 补充 dev/test 共享 pin 守卫范围、根目录 `requirements-dev.txt`、`kimi-attest` Gate 3 授权记录 |
| `docs/superpowers/plans/2026-11-26-pglast-pin-recovery.md` | 新建 | 本实施计划文档 |
| `backend/tests/test_requirements_api.py` | 修改 | 收紧 `_EXACT_PIN_RE`、新增 `ROOT_DEV_REQS`、`DEV_REQS`、`_assert_shared_pins_match`、`_assert_dev_pins_match_test`、`test_dev_and_test_requirements_pins_match`、`test_root_dev_and_test_requirements_pins_match` 及负向单测 |
| `docs/acceptance/2026-11-26-pglast-pin-recovery.md` | 新建 | 中文非程序员可执行验收清单（含实测记录与二元通过判定） |

---

### Task 1: 准备隔离 Python 3.11 测试环境与 PyPI Wheel 核查

**Files:**
- Commit (Step 0): `docs/superpowers/specs/2026-11-23-pglast-pin-recovery-design.md`, `docs/superpowers/plans/2026-11-26-pglast-pin-recovery.md`
- Read-only check: `backend/requirements-dev.txt`, `backend/requirements-test.txt`

**Interfaces:**
- Consumes: `3e97faa1` 已更新的 `backend/requirements-dev.txt` 与 `backend/requirements-test.txt`
- Produces: 已提交 Spec 与 Plan 的干净分支 `fix/pglast-pin-7.24-recovery`、可执行的隔离 Python 3.11 环境 `/tmp/pglast-724-venv`、`pglast.__version__` 实测值、PyPI Linux x86_64 `cp311`/`cp312` wheel 核查结果

- [ ] **Step 0: 核对工作分支并在 Gate 2 通过后提交 Spec 更新与本计划**

Run:
1. `git branch --show-current`（必须输出 `fix/pglast-pin-7.24-recovery`；若尚未创建则执行 `git checkout -b fix/pglast-pin-7.24-recovery 3bc4905c`）
2. `git add docs/superpowers/specs/2026-11-23-pglast-pin-recovery-design.md docs/superpowers/plans/2026-11-26-pglast-pin-recovery.md && git commit -m "docs(plan): 补充 pglast 7.24 恢复实施计划并同步评审通道记录（Plan Review 通过）"`
3. `git status --short`（输出为空，确认进入代码修改前工作树干净）
Expected: Spec 更新与本实施计划已提交至 `fix/pglast-pin-7.24-recovery`，从而确保 Task 3 结束时工作树干净且 Task 4 的 `branch-diff` 完整包含 Spec 与 Plan。

- [ ] **Step 1: 核对工作分支并在全新隔离目录创建 Python 3.11 虚拟环境并安装依赖**

先确认当前处于 `fix/pglast-pin-7.24-recovery` 分支（若尚未创建，执行 `git checkout -b fix/pglast-pin-7.24-recovery 3bc4905c`），并确认 `/tmp/pglast-724-venv` 不存在（若因上次中断残留则显式报错退出，禁止 `venv` 在 `clear=False` 下静默复用旧 `site-packages`）：

Run:
1. `git branch --show-current`（必须输出 `fix/pglast-pin-7.24-recovery`）
2. `test ! -e /tmp/pglast-724-venv`
3. `/opt/homebrew/bin/python3.11 -m venv /tmp/pglast-724-venv`
4. `/tmp/pglast-724-venv/bin/python -m pip install --no-cache-dir -r backend/requirements-dev.txt -r backend/requirements-test.txt`
Expected: 当前分支为 `fix/pglast-pin-7.24-recovery`；若目录已存在则第 2 步直接失败（退出码 1）；全新目录时全部命令退出码 0，无任何依赖冲突或缺失。

- [ ] **Step 2: 验证实际导入版本与 PyPI Linux x86_64 wheels**

Run:
1. `/tmp/pglast-724-venv/bin/python -c "import pglast, pytest; print(pglast.__version__, pytest.__version__)"`
2. 拉取 `https://pypi.org/pypi/pglast/7.24/json` 到 `/tmp/pglast-724.json`，检查 `urls` 中同时存在 `manylinux` `x86_64` 的 `cp311` 与 `cp312` `.whl` 包并记录准确文件名。
Expected: `pglast` 版本为 `v7.24`（或 `7.24`），`cp311` 与 `cp312` Linux x86_64 wheel 均存在。

---

### Task 2: 在 `backend/tests/test_requirements_api.py` 补齐严格 Pin 解析与 dev/test 共享守卫（TDD）

**Files:**
- Modify: `requirements-dev.txt`, `backend/tests/test_requirements_api.py`
- Test: `backend/tests/test_requirements_api.py`

**Interfaces:**
- Consumes: Task 1 创建的 `/tmp/pglast-724-venv/bin/python`；现有 `BACKEND_DIR`, `TEST_REQS`, `_parse(path: Path) -> dict[str, str]`
- Produces: `REPO_ROOT`, `ROOT_DEV_REQS = REPO_ROOT / "requirements-dev.txt"`, `DEV_REQS = BACKEND_DIR / "requirements-dev.txt"`, 严格正则 `_EXACT_PIN_RE`, `_assert_shared_pins_match(...)`, `_assert_dev_pins_match_test(..., dev_name=..., require_pglast=...)`, `test_root_dev_and_test_requirements_pins_match`

- [ ] **Step 1: 写失败测试（TDD）**

在 `backend/tests/test_requirements_api.py` 新增 `import pytest`、`DEV_REQS`，声明 `_assert_shared_pins_match(...)` 与 `_assert_dev_pins_match_test(...)` 签名并先以未实现/占位方式引入以下测试：
- `test_dev_and_test_requirements_pins_match()`：调用 `_assert_dev_pins_match_test(_parse(DEV_REQS), _parse(TEST_REQS))`（内部校验 `dev` 非空、`"pglast" in dev`、`missing = sorted(set(dev) - set(test)); assert not missing, f"requirements-dev.txt 中的包未出现在 requirements-test.txt: {missing}"`，再调用 `_assert_shared_pins_match("requirements-dev.txt", dev, "requirements-test.txt", test)`）。
- `test_dev_requirements_has_no_version_ranges(tmp_path: Path)`：调用 `_parse(DEV_REQS)` 验证当前清单无非精确约束，并分别用临时文件写入 `foo>=1.0\n`、`foo==1.*\n`、`foo==1.0,!=1.1\n`，验证 `_parse` 均抛出 `AssertionError`。
- `test_shared_pins_guard_rejects_version_drift()`：传入同键不同版本合成字典（`{"pkg": "1.0"}` vs `{"pkg": "2.0"}`），断言 `_assert_shared_pins_match` 抛出包含 `"pkg"` 的 `AssertionError`。
- `test_shared_pins_guard_rejects_empty_overlap()`：传入无交集字典，断言 `_assert_shared_pins_match` 抛出 `AssertionError`。
- `test_dev_pins_guard_rejects_missing_package_from_test()`：调用 `_assert_dev_pins_match_test({"pglast": "1.0", "extra-pkg": "2.0"}, {"pglast": "1.0"})`，断言抛出包含 `"extra-pkg"` 的 `AssertionError`。
- `test_dev_pins_guard_requires_pglast()`：调用 `_assert_dev_pins_match_test({"pytest": "1.0"}, {"pytest": "1.0"})`，断言抛出包含 `"pglast"` 的 `AssertionError`。

- [ ] **Step 2: 运行测试确认未实现前失败**

Run: `cd backend && PYTHONDONTWRITEBYTECODE=1 /tmp/pglast-724-venv/bin/python -m pytest tests/test_requirements_api.py -v`
Expected: FAIL（`test_dev_requirements_has_no_version_ranges` 因现有正则放行 `==1.*` 与 `==1.0,!=1.1` 而失败，且 `_assert_shared_pins_match` / `_assert_dev_pins_match_test` 尚未实现）。

- [ ] **Step 3: 收紧 `_EXACT_PIN_RE` 并实现 `_assert_shared_pins_match` 与 `_assert_dev_pins_match_test`**

在 `backend/tests/test_requirements_api.py`：
1. 将 `_EXACT_PIN_RE` 收紧为匹配单一 PEP 440 精确 pin（支持可选 epoch `1!`、连字符预发布 `2.0-rc1`、`post`/`dev` 与 `+local`），拒绝无数字伪版本（`latest`）、通配符 `*`、复合约束 `,`、`!=`、`>=`、环境标记 `;` 等；
2. 实现 `_assert_shared_pins_match(left_name: str, left: dict[str, str], right_name: str, right: dict[str, str]) -> None`：若交集为空则抛 `AssertionError`；遍历共享包逐一断言 `left[name] == right[name]`；
3. 实现 `_assert_dev_pins_match_test(dev: dict[str, str], test: dict[str, str]) -> None`：校验 `dev` 非空、`"pglast" in dev`、`missing = sorted(set(dev) - set(test))` 为空（否则报错并列出 `missing`），再调用 `_assert_shared_pins_match("requirements-dev.txt", dev, "requirements-test.txt", test)`；
4. 让 `test_api_and_test_requirements_pins_match` 也复用 `_assert_shared_pins_match`。

- [ ] **Step 4: 验证守卫测试全绿**

Run: `cd backend && PYTHONDONTWRITEBYTECODE=1 /tmp/pglast-724-venv/bin/python -m pytest tests/test_requirements_api.py -v`
Expected: PASS（全部新增与既有测试均为 `PASSED`）。

---

### Task 3: 全量后端回归、清单清理与中文非程序员验收清单

**Files:**
- Create: `docs/acceptance/2026-11-26-pglast-pin-recovery.md`

**Interfaces:**
- Consumes: Task 1 隔离环境、Task 2 测试改动
- Produces: 全套 `backend/tests/` JUnit 实测统计、`docs/acceptance/2026-11-26-pglast-pin-recovery.md`

- [ ] **Step 1: 运行完整 `backend/tests/`（零跳过校验）及全清单格式检查**

Run:
1. `cd backend && PYTHONDONTWRITEBYTECODE=1 /tmp/pglast-724-venv/bin/python -m pytest tests/ -q -rs --junitxml=/tmp/pytest-pglast724.xml`
2. 解析 `/tmp/pytest-pglast724.xml` 断言 `skipped == 0`、`failures == 0`、`errors == 0`，记录准确 `passed` 总数。
3. 用 `test_requirements_api._parse`（仅检查非空、非注释行）解析全部 5 份清单（根目录 `requirements-dev.txt` 及 4 份 `backend/requirements*.txt`）以验证均为严格精确 `==` pin（避免误报 `requirements-api.txt` 注释中的 `*`），并断言 `len(_parse(DEV_REQS)) >= 5`。
4. 清理 `/tmp/pglast-724-venv`、`/tmp/pglast-724.json`、`/tmp/pytest-pglast724.xml`。
Expected: 退出码 0，`0 skipped / 0 failed / 0 errored`，`passed > 0`（并记录准确实测通过条数）。

- [ ] **Step 2: 编写 `docs/acceptance/2026-11-26-pglast-pin-recovery.md`**

按仓内 `CLAUDE.md` 与 `.claude/workflow-rules.json`（`verification_template`）规范编写非程序员可执行验收清单：
- 清单定位为「操作者与 PR 验收者可独立复跑勾选的验收清单」，采用 **动作 / 期望 / 通过判定 / 通过与否** 四列表格（`通过与否` 列保持空白勾选框 `[ ] 通过 / [ ] 不通过`，不向 `main` 写入永久的「待完成」字段），覆盖本机隔离环境复跑以及在 PR 页面核对 `backend pytest (full suite)`、`acceptance`、`codex-verify-pass`（明确指出 Python 3.12 `hardening_6_gate.yml` 仅验证安装、不运行 SQL 解析测试）；
- 另设「本次本机实测记录（macOS Python 3.11）」节，明确写明实际执行者、实测版本号、wheel 文件名与 pytest 通过条数，并注明远端 Linux CI 实测证据（最终 HEAD SHA、CI 运行链接、Python 3.11 全量与 Python 3.12 安装结果）依据 `.claude/workflow-rules.json` `acceptance_evidence_upload` 规范上传至 PR 评论区（不在 Gate 3 签发后再提交文件，以免破坏已 attest 的 HEAD）；
- 全文零禁用词。

- [ ] **Step 3: 提交测试改动与验收清单**

Run:
1. `git branch --show-current`（确认仍在 `fix/pglast-pin-7.24-recovery`）
2. `git add backend/tests/test_requirements_api.py docs/acceptance/2026-11-26-pglast-pin-recovery.md && git commit -m "test(ci): 补充 requirements-dev 与 requirements-test 共享 pin 守卫及验收清单"`
Expected: 工作树干净，提交落在 `fix/pglast-pin-7.24-recovery` 上，准备进入 Task 4 Pre-PR 对抗性评审。

---

### Task 4: Pre-PR 完整分支对抗性评审、提交 PR 与最终 HEAD 远端 CI 核验

**Files:**
- Read-only / Remote: branch `fix/pglast-pin-7.24-recovery` → `origin/fix/pglast-pin-7.24-recovery` → PR targeting `main`

**Interfaces:**
- Consumes: Task 3 提交后的干净分支（与 `origin/main` 的完整 diff）
- Produces: Gate 3 `kimi-attest`（用户授权替代配额耗尽的本地 Codex）approve 账本条目、已推送的 `origin/fix/pglast-pin-7.24-recovery` 分支、Open PR、以及最终 PR HEAD 上的远端 GitHub Actions CI 实测结果记录

- [ ] **Step 1: 运行 Pre-PR 完整分支对抗性评审（Gate 3）**

Run: `bash .claude/scripts/kimi-attest.sh --scope branch-diff --head fix/pglast-pin-7.24-recovery --base origin/main`（不传 `--focus` 或任何窄化参数；该分支相对 `origin/main` 的 diff 同时涵盖 Spec、实施计划、测试代码、根目录/后端依赖清单与验收清单。因本地 Codex ChatGPT Pro 配额于 14:28 耗尽且需至 19:04 重置，经用户明确授权 Gate 3 改用本地 `kimi-attest.sh` 收口；远端 PR 仍由 `codex-review-verify` 工作流上报 `codex-verify-pass` 做二层 Codex 校验）。
若返回 `needs-attention`，修复所有有效 finding 并重新跑通受影响验证后提交，再重跑本命令直至 `approve`。**拿到 `approve` 后禁止再产生任何新提交**（否则 HEAD SHA 变更会使账本失效）。

- [ ] **Step 2: 推送分支并创建 Pull Request**

执行环境边界（见 Global Constraints）：因 `main` 上 `.claude/hooks/guard-attest-ledger.sh` 存在既有协议不兼容（`fp|base_sha` vs 裸 `fp` 与 `file:` 条目校验）且本 PR 不改 `.claude/**`，若当前运行在挂载 `.claude/hooks/` 的 Claude Code 会话中，Gate 3 通过后**移交用户终端**执行以下两步；若运行在不挂载 `.claude/settings.json` 钩子的 Antigravity 会话（且经用户显式授权）或用户终端，直接执行：
1. `git push -u origin fix/pglast-pin-7.24-recovery`
2. `gh pr create --base main --head fix/pglast-pin-7.24-recovery --title "fix(ci): 升级 pglast 测试依赖 7.13 → 7.24 并补充 dev/test 共享 pin 守卫" ...`
Expected: 成功推送统一分支 `fix/pglast-pin-7.24-recovery` 并创建 PR，记录 PR 链接与最终 HEAD SHA。

- [ ] **Step 3: 在最终 PR HEAD 上核验远端 GitHub Actions 必需检查**

Run: `gh pr checks <pr-number>` / `gh pr view <pr-number> --json statusCheckRollup,headRefOid,url` 及对应 `gh run view <run-id>`：
- 确认 `backend pytest (full suite)`（Linux Python 3.11）实际完成依赖安装并全套通过（0 failed / 0 skipped）；
- 确认 `acceptance`（Linux Python 3.12）实际完成 `requirements-dev.txt` 依赖安装并退出 0；
- 确认 `codex-verify-pass`（由 `codex-review-verify` 工作流上报的 check-run，即 `gh pr checks` 中显示的检查名）及其他必需检查全部通过；
- 依据 `.claude/workflow-rules.json` `acceptance_evidence_upload` 规范，将最终 PR HEAD SHA、CI 运行链接、Python 3.11 全量结果与 Python 3.12 安装结果以 PR 评论（`gh pr comment`，由用户终端或在经用户显式授权的非 `.claude`-hooked Antigravity 会话中执行，不产生新提交以免破坏已 attest 的 HEAD）和最终答复形式完整回填；在 `backend pytest (full suite)`、`acceptance`、`codex-verify-pass` 全部于最终 PR HEAD 变绿并上传 PR 评论前，明确保持远端 CI 验收未完成。
