# PR 9 — Wave 0 契约冻结 ceremony Implementation Plan

**Revision history：**
- **v1**（2026-05-17）：初稿 → codex plan-stage R1 verdict `needs-attention`（3 findings：2 high + 1 medium）
- **v2**（2026-05-17）：codex R1 3 findings 全修
  - finding 1 (high) → `verify-freeze-tag.sh` python heredoc 抢 stdin；Task 5 Step 5.2 改用 env var
  - finding 2 (high) → spec §15.2 与 README/ledger 矛盾；Task 1 增 Step 1.5 amend §15.2
  - finding 3 (medium) → workflow paths 限 `ios/Contracts/**` 不够；Task 2 增 Step 2.0 加 `ios/KlineTrainer/**`
- **v3**（2026-05-17）：codex R2 2 findings 全修
  - finding 1 (high) → acceptance §E 加 set -euo pipefail + 每步 || exit 1 双保险
  - finding 2 (medium) → E3 改 peeled (`ls-remote refs/tags/...^{}`)
- **v4**（2026-05-17）：codex R3 1 high finding 全修
  - finding 1 (high) → `PR_NUMBER=9` 是项目**内部命名**（"PR 9 governance" anchor），不是实际 GitHub PR number — 该 repo 已有 PR #37-#53，新 freeze PR 会是 #54+；硬编码 9 让 `gh pr view 9 --json mergeCommit` 拉旧/不存在 PR，origin/main vs mergeCommit 断言失败，ceremony 永远跑不过 → 改用 `gh pr list --head pr9-wave0-freeze --state merged --json number --jq '.[0].number'` 在 ceremony 跑时 auto-detect 真 PR number；fail 时显式诊断 + exit 1；spec §5.6 同样 mirror（v7 locked，记录为 plan v4 修复 spec-vs-implementation drift）

---

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task（本项目只用 subagent-driven-development，见 memory `project_executing_plans_excluded`）。每个 Task 派一个 fresh sonnet 4.6 high-effort subagent；Task 与 Task 之间主线 two-stage review。Steps use checkbox (`- [ ]`) syntax for tracking。

**Goal:** 为 spec `docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md`（v7 after 6 rounds codex spec-stage review + user TTY override，commit af7f232）落地 Wave 0 契约冻结 ceremony 7 子项：spec amendments (L1167 + §F1/§M0.3) + Catalyst CI job + §15.4 ledger + README v1.4 + tag verify script + §15.3 Wave 1 plan 模板；PR 9 merge 之后单独动作打 `wave0-frozen-v1.4` tag（三层 blocking gate 验证）。

**Architecture:** 单 governance PR（trust-boundary：CI workflow + spec amendment + git tag）；6 Tasks（不含 merge 后 tag 动作）+ baseline + final verification；零业务代码改动（纯 doc + CI yaml + governance script）；预期 297 tests in 63 suites 不退化。

**Tech Stack:** Markdown spec amendments + GitHub Actions yaml（`.github/workflows/swift-contracts-smoke.yml` 镜像 swift-test job pattern）+ bash governance script（`scripts/governance/verify-freeze-tag.sh`，python 嵌入 fnmatch ruleset 评估）+ `gh` CLI（PR squash SHA 拿取）+ `git tag -a/-s` annotated/signed tag。

**Spec 锚点：**
- **本 PR spec**：`docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md`（v7）
- **目标 spec amendment 1**：`kline_trainer_modules_v1.4.md` L1167（§6 C1b 闸门 #4 F3）
- **目标 spec amendment 2.1**：`kline_trainer_modules_v1.4.md` L811-815（§F1）
- **目标 spec amendment 2.2**：`kline_trainer_modules_v1.4.md` §M0.3 末尾（L470 附近，enum/struct 定义后）追加 inventory 表
- **CI workflow**：`.github/workflows/swift-contracts-smoke.yml` 追加第二 job（镜像 existing `swift-test` job pattern）
- **Spec residuals 引用**：PR #50 L1167 freeze blocker / PR #51 R7 Catalyst CI residual G3 / PR #53 PR F1 H3 M0.3 multi-file split

**Planner packaging hard rule 自查（memory `feedback_planner_packaging_bias`）：**

> 硬规则每 PR ≤3 子项 / ≤500 行 prod

本 PR 子项数：7（spec amendments / CI / ledger / README / verify-freeze-tag.sh / Wave 1 plan 模板 / tag merge 后动作）— **治理类 PR 例外**（与业务 PR packaging 硬规则区分；CLAUDE.md backstop 把 governance/CI workflow 改动单独走 brainstorming → writing-plans → codex review，本身规模就是 multi-item ceremony）。

预估 prod LOC（新增）：
- `kline_trainer_modules_v1.4.md`：~10 行（L1167 修订）+ ~40 行（§F1 wording + §M0.3 inventory 表）= ~50 行
- `.github/workflows/swift-contracts-smoke.yml`：~50 行（新 catalyst-build job）
- `docs/governance/2026-05-17-wave0-signoff-ledger.md`：~80 行（新建）
- `docs/governance/wave1-plan-template.md`：~15 行（新建）
- `README.md`：~30 行（追加 Wave 0 冻结章节）
- `scripts/governance/verify-freeze-tag.sh`：~120 行（新建；含 python ruleset 评估嵌入）

= **~345 行**（≤500 硬规则 OK；governance PR 含 script implementation 是必要的，spec §5.6 第 1 层走外部脚本拆出）

测试 / 验证 LOC：
- `docs/acceptance/2026-05-17-pr9-wave0-freeze.md`：~90 行（中文非-coder 验收清单）
- `docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md`：本计划文件（commit 进 PR scope）

**完成后：** Wave 0 契约层正式冻结进入 RFC 模式；Wave 1 可启动；下一锚 = Wave 1 内部 plan 排序 brainstorming（类似 v6 outline 当初为 Wave 0 做的事）。**注意 tag 动作在 PR 9 merge 之后单独跑**，不在本 PR commits 里。

---

## File Structure

| 文件 | 责任 | 状态 | 增量 LOC budget |
|---|---|---|---|
| `kline_trainer_modules_v1.4.md` | spec §6 C1b 闸门 #4 F3 修订（L1167 移 Wave 1）+ §F1 wording + §M0.3 multi-file inventory 表 | Modify | ~50 |
| `.github/workflows/swift-contracts-smoke.yml` | 追加 `catalyst-build` job（镜像 `swift-test` job pattern：不硬编码 Xcode path / `xcodebuild -version` 断言 / SHA-pinned `actions/checkout`） | Modify | ~50 |
| `docs/governance/2026-05-17-wave0-signoff-ledger.md` | §15.4 三方签字 ledger 单人简化 doc（后端/iOS/数据三角色 self-sign + 7 residuals 表 H1-H7） | Create | ~80 |
| `docs/governance/wave1-plan-template.md` | Wave 1+ plan Task 0 §15.3 评审策略前置模板 | Create | ~15 |
| `README.md` | 追加 "Wave 0 契约冻结 v1.4" 章节 + 依赖版本锁定表（iOS exact pin / backend ranges + H6 residual） | Modify | ~30 |
| `scripts/governance/verify-freeze-tag.sh` | Bash + 嵌入 python ruleset 评估脚本：protected tag namespace 完整谓词检查（include/exclude fnmatch + active + creation+update+deletion + bypass admin-only）；由 tag 创建脚本 layer 1 调用 | Create | ~120 |
| `docs/acceptance/2026-05-17-pr9-wave0-freeze.md` | 中文非-coder 验收清单（A-G 节，含 §6.F mirror spec §5.6 三层 blocking gate） | Create | ≤95 |
| `docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md` | 本计划文件 | Create（本文件） | — |

**File rationale：**

- **不动 `Package.swift`**：iOS deps 已在 `Package.resolved` exact pin；spec amendments 是 doc-only；CI workflow 改动是 trust-boundary 但已在 codeowners 守卫范围内可通过。
- **`scripts/governance/verify-freeze-tag.sh` 单独抽出**：spec §5.6 layer 1 protected ruleset 完整谓词检查需嵌入 python fnmatch 评估；脚本化让 tag 创建脚本简洁 + 单独可测；放 `scripts/governance/` 与 `scripts/acceptance/` 同级（governance scripts 类别）。
- **§15.4 ledger 单独文件不并入 README**：ledger 是 sign-off ceremony 形式 record，长久参考；README 简短引用即可。
- **Wave 1 plan 模板单独文件**：Wave 1 第一个 plan 起草时 cp 模板；放 `docs/governance/` 与 ledger 同级，便于查找。
- **Tag 创建命令不放 Tasks**：PR 9 merge 后单独动作（spec §5.6 明文），plan 末尾 §"PR 9 merge 后 manual tag procedure" 章节列完整命令链。

**Working directory：** worktree `.worktrees/pr9-wave0-freeze` 已由本 session 创建（commit history 已有 v1-v7 spec 共 7 commits 落地）。SwiftPM root: `<worktree>/ios/Contracts/`。计划文件本身 commit 进 PR scope。

**Baseline：** PR #53 merged 后 origin/main = **297 tests in 63 suites / 0 failures / 0 warnings**（PR F1 final test count；本 PR 0 业务代码改动，期望测试数不变）。

---

## Spec Evidence Section（codex review 必读）

### Spec v7 §5.1 — §6 C1b 闸门 #4 F3 修订（L1167 移 Wave 1）

修订前 `kline_trainer_modules_v1.4.md` L1167：

```
- **Deceleration stop 契约测试**（闸门 #4 F3 新增）：`panEnded(velocity:) → .startDeceleration(v)` effect handler 启动 animator；后续 activateDrawing → `.requestDrawingSnapshotAfterStoppingAnimator` effect；验证 handler 必须**先**调用 `animator.stop()` 再计算 range（集成测试：模拟延迟 animator 回调，验证 drawing 退出后无 `offsetApplied` 到达 reducer）
```

修订后：

```
- **Deceleration stop 契约测试**（闸门 #4 F3 修订 v1.4 — **Wave 0 仅 reducer 契约测试；production handler 集成测试移 Wave 1**）：
  - **Wave 0 验收**（PR #50 已落）：reducer 派发 `panEnded(velocity:) → .startDeceleration(v)` effect + `activateDrawing → .requestDrawingSnapshotAfterStoppingAnimator` effect 的契约测试（13 个测试覆盖 happy + cross-session）
  - **Wave 1 验收**（C2 DecelerationAnimator + C8 ChartContainerView 落地时同 PR 内）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer

  **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试在生产代码落地的同 PR 验证更准。
```

### Spec v7 §5.2.1 — §F1 wording 修订（L811-815）

修订前：

```
### F1 数据模型模块 `Models/`

- **职责**：承载 M0.3 所有类型（含 `Equatable / Codable / CodingKeys`）
```

修订后：

```
### F1 数据模型模块 `Models/`

- **职责**：承载 M0.3 **核心** 数据类型（`Models.swift` 内 9 enum + 7 struct = 11 Codable 实体 + 5 非 Codable 类型）；**不含**跨文件 split 的 `AppState.swift` / `RESTDTOs.swift` 中的 M0.3 类型（见 §M0.3 inventory 表）。
```

### Spec v7 §5.2.2 — §M0.3 inventory 表（在 §M0.3 enum/struct 定义末尾约 L470 附近追加）

```
**M0.3 类型 inventory（v1.4 freeze）**：

| 文件 | 类型 | Codable | 用途 |
|---|---|---|---|
| Models.swift | 9 enum: Period / TradeDirection / PositionTier / TrainingMode / DrawingToolType / DisplayMode / PanelId / SwipeDirection / PeriodDirection | 5/9 (Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode 是 Codable) | 核心枚举 |
| Models.swift | 7 struct: KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject / TradeMarker | 6/7 (TradeMarker NOT Codable — UI overlay 运行期专用) | 核心数据 |
| AppState.swift | 5 struct: TrainingRecord / DrawdownAccumulator / PendingTraining / TrainingSetFile / AppSettings | 3/5 (TrainingRecord / DrawdownAccumulator / PendingTraining 是 Codable；TrainingSetFile / AppSettings 非 Codable — UI/cache state 运行期专用) | 状态/持仓累计/UI 配置 |
| RESTDTOs.swift | 2 struct: LeaseResponse / TrainingSetMetaItem | 2/2 | REST 边界 DTO |

**合计 16 Codable（5 enum + 11 struct）+ 7 非 Codable（4 enum + 3 struct: TradeMarker / TrainingSetFile / AppSettings）= 23 M0.3 类型。** F1 模块 scope 仅 `Models.swift` 11 Codable；`AppState.swift` 5 struct 与 `RESTDTOs.swift` 2 struct 分别归 §C1b reducer / §B3 REST API 模块责任。
```

### Existing swift-test job pattern（镜像 source）

`.github/workflows/swift-contracts-smoke.yml` L18-43（现有 `swift-test` job）已确立 codex Plan 1c R2 convention：

```yaml
jobs:
  swift-test:
    name: swift test on macos-15
    runs-on: macos-15
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      # 依赖 runner 默认 Xcode（macos-15 image 预装 Xcode 16）提供 Swift 6.0+。
      # 不硬编码 /Applications/Xcode_16.0.app 路径（GHA image 刷新时路径可能变；
      # codex Plan 1c round 2 finding）。只断言 swift 版本，不满足则 fail-fast 给清晰诊断。
      - name: Assert Swift >= 6.0
        run: |
          swift --version
          SWIFT_VER=$(swift --version | grep -oE 'Apple Swift version [0-9]+\.[0-9]+' | awk '{print $NF}')
          MAJOR=$(echo "$SWIFT_VER" | cut -d. -f1)
          if [[ -z "$SWIFT_VER" || "$MAJOR" -lt 6 ]]; then
            echo "FAIL: Swift 6.0+ required ..."
            exit 1
          fi
          echo "Swift $SWIFT_VER OK"
      - name: Run swift test
        working-directory: ios/Contracts
        run: swift test
```

新增 `catalyst-build` job 完全镜像此 pattern（`xcodebuild -version` 替 `swift --version`）。

---

## Tasks

### Task 0: Baseline 测试 + plan 文件 commit

**Files:**
- Verify: worktree `.worktrees/pr9-wave0-freeze` 已存在（v1-v7 spec 已 commit）
- Create: `docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md`（本文件）

- [ ] **Step 0.1: Verify worktree state + branch**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
git rev-parse --abbrev-ref HEAD
git log --oneline -5
```

Expected:
- branch = `pr9-wave0-freeze`
- 最近 commit 为 `af7f232 fix(PR 9 spec v7): codex R6 3 fresh findings 全修`
- 包含 v1-v7 spec commits（共 7 个 spec 修订 commits）

- [ ] **Step 0.2: Baseline swift test**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze/ios/Contracts
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr9-baseline.log ); then
  echo "BASELINE FAIL — abort plan execution"
  exit 1
fi
tail -3 /tmp/pr9-baseline.log
```

Expected: 末尾出现 `Test run with 297 tests in 63 suites passed`（与 PR #53 baseline 一致）。

- [ ] **Step 0.3: Commit 本 plan 文件**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
git add docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md
git commit -m "plan(PR 9): Wave 0 freeze ceremony implementation plan (v1)"
```

Expected: 1 file changed（本 plan 文件）。

---

### Task 1: Spec amendments（§6 C1b L1167 + §F1 + §M0.3 inventory）

**Files:**
- Modify: `kline_trainer_modules_v1.4.md`（3 处修订）

- [ ] **Step 1.1: Locate L1167 actual line number**

L 号可能因 spec 前面段落 line 飘移；先 grep 定位：

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
grep -n "Deceleration stop 契约测试" kline_trainer_modules_v1.4.md
```

Expected: 输出形如 `1167:- **Deceleration stop 契约测试**（闸门 #4 F3 新增）...`（如 L 号不同以实际为准）。

- [ ] **Step 1.2: 修订 L1167（§6 C1b 闸门 #4 F3）**

使用 Edit tool：

- **old_string** (L1167 整段)：
  ```
  - **Deceleration stop 契约测试**（闸门 #4 F3 新增）：`panEnded(velocity:) → .startDeceleration(v)` effect handler 启动 animator；后续 activateDrawing → `.requestDrawingSnapshotAfterStoppingAnimator` effect；验证 handler 必须**先**调用 `animator.stop()` 再计算 range（集成测试：模拟延迟 animator 回调，验证 drawing 退出后无 `offsetApplied` 到达 reducer）
  ```
- **new_string**：
  ```
  - **Deceleration stop 契约测试**（闸门 #4 F3 修订 v1.4 — **Wave 0 仅 reducer 契约测试；production handler 集成测试移 Wave 1**）：
    - **Wave 0 验收**（PR #50 已落）：reducer 派发 `panEnded(velocity:) → .startDeceleration(v)` effect + `activateDrawing → .requestDrawingSnapshotAfterStoppingAnimator` effect 的契约测试（13 个测试覆盖 happy + cross-session）
    - **Wave 1 验收**（C2 DecelerationAnimator + C8 ChartContainerView 落地时同 PR 内）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer

    **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试在生产代码落地的同 PR 验证更准。
  ```

- [ ] **Step 1.3: 修订 §F1 wording（L811-815）**

```bash
grep -n "^### F1 数据模型模块" kline_trainer_modules_v1.4.md
```

Expected: 输出 `811:### F1 数据模型模块 \`Models/\``（或实际行号）。

使用 Edit tool：

- **old_string** (L811-815 4 行块)：
  ```
  ### F1 数据模型模块 `Models/`

  - **职责**：承载 M0.3 所有类型（含 `Equatable / Codable / CodingKeys`）
  ```
- **new_string**：
  ```
  ### F1 数据模型模块 `Models/`

  - **职责**：承载 M0.3 **核心** 数据类型（`Models.swift` 内 9 enum + 7 struct = 11 Codable 实体 + 5 非 Codable 类型）；**不含**跨文件 split 的 `AppState.swift` / `RESTDTOs.swift` 中的 M0.3 类型（见 §M0.3 inventory 表）。
  ```

- [ ] **Step 1.4: 追加 §M0.3 multi-file inventory 表**

定位 §M0.3 末尾（enum/struct 定义后、§M0.4 章节前）：

```bash
grep -n "^### M0\." kline_trainer_modules_v1.4.md | head -10
```

Expected: 看到 `### M0.3 Swift 数据模型契约` (~L395) + `### M0.4 ...` (~L500 附近)。在 §M0.3 末尾、§M0.4 之前插入 inventory 表。

使用 Edit tool 定位 §M0.3 的最后一个 code block 的 `\`\`\`` 结尾（或 §M0.4 前的空行），在其后插入：

```
**M0.3 类型 inventory（v1.4 freeze）**：

| 文件 | 类型 | Codable | 用途 |
|---|---|---|---|
| Models.swift | 9 enum: Period / TradeDirection / PositionTier / TrainingMode / DrawingToolType / DisplayMode / PanelId / SwipeDirection / PeriodDirection | 5/9 (Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode 是 Codable) | 核心枚举 |
| Models.swift | 7 struct: KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject / TradeMarker | 6/7 (TradeMarker NOT Codable — UI overlay 运行期专用) | 核心数据 |
| AppState.swift | 5 struct: TrainingRecord / DrawdownAccumulator / PendingTraining / TrainingSetFile / AppSettings | 3/5 (TrainingRecord / DrawdownAccumulator / PendingTraining 是 Codable；TrainingSetFile / AppSettings 非 Codable — UI/cache state 运行期专用) | 状态/持仓累计/UI 配置 |
| RESTDTOs.swift | 2 struct: LeaseResponse / TrainingSetMetaItem | 2/2 | REST 边界 DTO |

**合计 16 Codable（5 enum + 11 struct）+ 7 非 Codable（4 enum + 3 struct: TradeMarker / TrainingSetFile / AppSettings）= 23 M0.3 类型。** F1 模块 scope 仅 `Models.swift` 11 Codable；`AppState.swift` 5 struct 与 `RESTDTOs.swift` 2 struct 分别归 §C1b reducer / §B3 REST API 模块责任。

```

- [ ] **Step 1.5: 修订 §15.2 加 v1.4 freeze qualifier note（codex plan R1 finding 2 修）**

定位 §15.2：

```bash
grep -n "^### 15\.2 三方依赖" kline_trainer_modules_v1.4.md
```

Expected: 输出 `2467:### 15.2 三方依赖版本锁定`（或实际行号）。

使用 Edit tool 在 §15.2 标题下方第 1 行（"Wave 0 签字同步锁定..."）之前**追加** v1.4 freeze qualifier note：

**old_string** (§15.2 标题 + 第一行原文)：
```
### 15.2 三方依赖版本锁定

Wave 0 签字同步锁定以下版本，**Wave 1 起不得修改**（除非安全补丁 + 三方同意）：
```

**new_string** (插入 v1.4 freeze qualifier note 段落)：
```
### 15.2 三方依赖版本锁定

**v1.4 freeze 修订（PR 9 ceremony，2026-05-17）**：本节列出的是 Wave 0 spec 推荐版本范围（`6.x 最新稳定 (≥ 6.29)` 等）。**v1.4 实际冻结状态**：

- **iOS 依赖 exact pin（已在 `Package.resolved` 锁定）**：GRDB.swift `6.29.3` / ZipFoundation `0.9.20`。 Wave 1 起 `Package.resolved` 视为锁定 source-of-truth，变更走 RFC + ledger。
- **Backend 依赖 ranges（v1.4 暂不 exact pin）**：FastAPI / Uvicorn / APScheduler / pandas / pandas-ta / asyncpg / PostgreSQL 暂用本节 ranges；Wave 1 B1-B4 PR 各自落 `backend/requirements.txt == X.Y.Z` 精确版本 + `docker-compose.yml` image digest pin 时同步锁定（见 `docs/governance/2026-05-17-wave0-signoff-ledger.md` residual H6）。
- **README v1.4 + ledger** 互为补充：README 列实际锁定状态；本节列 spec 推荐范围 + v1.4 freeze 真锁定状态摘要。

Wave 0 签字同步锁定以下版本，**Wave 1 起不得修改**（除非安全补丁 + 三方同意）：
```

- [ ] **Step 1.6: 验证修订**

```bash
grep -c "Wave 1 验收（C2 DecelerationAnimator" kline_trainer_modules_v1.4.md
grep -c "M0.3 \*\*核心\*\* 数据类型" kline_trainer_modules_v1.4.md
grep -c "23 M0.3 类型" kline_trainer_modules_v1.4.md
grep -c "16 Codable" kline_trainer_modules_v1.4.md
grep -c "7 非 Codable" kline_trainer_modules_v1.4.md
grep -c "v1.4 freeze 修订（PR 9 ceremony" kline_trainer_modules_v1.4.md
grep -c "residual H6" kline_trainer_modules_v1.4.md
```

Expected: 每个 grep ≥ 1（7 项全命中）。

跑 swift test 确认 spec md 不影响代码：

```bash
cd ios/Contracts && swift test 2>&1 | tail -3
```

Expected: 297 tests in 63 suites passed。

- [ ] **Step 1.7: Commit Task 1**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
git add kline_trainer_modules_v1.4.md
git commit -m "spec(PR 9): §6 C1b 闸门 #4 F3 L1167 移 Wave 1 + §F1 wording + §M0.3 inventory 表 23 类型 + §15.2 v1.4 freeze qualifier

- L1167 Deceleration stop 集成测试：Wave 0 仅 reducer 契约测试；production
  handler 集成测试移 Wave 1（C2 + C8 落地时同 PR 内验收）
- §F1 wording：'承载 M0.3 所有类型' → '承载 M0.3 核心数据类型 (Models.swift
  11 Codable + 5 非 Codable)，不含 AppState.swift / RESTDTOs.swift'
- §M0.3 加 inventory 表：4 行（Models.swift 9 enum + 7 struct / AppState.swift
  5 struct / RESTDTOs.swift 2 struct）= 16 Codable + 7 非 Codable = 23 类型
- §15.2 加 v1.4 freeze qualifier note（codex plan R1 finding 2 修）：iOS deps
  exact pin（GRDB 6.29.3 / ZipFoundation 0.9.20，Package.resolved）/ backend
  ranges Wave 1 B1-B4 PR 内 == 锁定 + 引用 ledger residual H6"
```

Expected: 1 file changed, +~70 行 spec 修订（多 §15.2 ~20 行）。

---

### Task 2: Catalyst CI job 加 swift-contracts-smoke.yml + 扩 paths trigger

**Files:**
- Modify: `.github/workflows/swift-contracts-smoke.yml`

- [ ] **Step 2.0: 扩 workflow paths trigger 加 `ios/KlineTrainer/**`（codex plan R1 finding 3 修）**

定位 `paths:` 块：

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
grep -n "paths:" .github/workflows/swift-contracts-smoke.yml
```

Expected: 输出 `5:    paths:`（或实际行号）。

使用 Edit tool：

**old_string** (paths 块):
```
    paths:
      - 'ios/Contracts/**'
      - '.github/workflows/swift-contracts-smoke.yml'
```

**new_string** (加 ios/KlineTrainer/**)：
```
    paths:
      - 'ios/Contracts/**'
      - 'ios/KlineTrainer/**'
      - '.github/workflows/swift-contracts-smoke.yml'
```

理由（codex plan R1 finding 3 修）：spec §5.3 + plan v1 文本说 "每个 PR" 但 v1 workflow trigger 限 `ios/Contracts/**`；touching `ios/KlineTrainer/` 的 PR 不触发 Catalyst gate；不实。加 `ios/KlineTrainer/**` 让 iOS-touching 全覆盖；spec §5.3 wording 同步软化为 "iOS-touching PR"（不在本 plan 改 spec，spec v7 locked；plan v2 revision history 记录此差异作为 known doc/spec text drift）。

- [ ] **Step 2.1: 读现有 workflow 找插入点**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
wc -l .github/workflows/swift-contracts-smoke.yml
tail -10 .github/workflows/swift-contracts-smoke.yml
```

Expected: 现有 workflow 末尾是 `swift-test` job 的最后一行（`run: swift test` 或类似）。

- [ ] **Step 2.2: 在文件末尾追加 catalyst-build job**

使用 Edit tool。**old_string** = 现有最后一个 step 的最后一行加换行（确保插入位置准确）；**new_string** = 同样的最后一行 + 下面的新 job 全文：

```yaml

  catalyst-build:
    name: Mac Catalyst build-for-testing on macos-15
    runs-on: macos-15
    timeout-minutes: 15
    # 依赖 runner 默认 Xcode（macos-15 image 预装 Xcode 16）提供 xcodebuild。
    # 不硬编码 /Applications/Xcode_16.app 路径（镜像 swift-test job 已有的 codex Plan 1c R2
    # finding 修订 pattern；GHA image 刷新时路径可能变 → fail-fast 给清晰诊断）。
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
      - name: Assert Xcode >= 16
        run: |
          xcodebuild -version
          XCODE_VER=$(xcodebuild -version | head -1 | awk '{print $2}')
          MAJOR=$(echo "$XCODE_VER" | cut -d. -f1)
          if [[ -z "$XCODE_VER" || "$MAJOR" -lt 16 ]]; then
            echo "FAIL: Xcode 16+ required (Swift 6.0 + Catalyst destination)；runner provides $XCODE_VER"
            echo "Available Xcode installs:"
            ls -la /Applications | grep -i xcode || true
            exit 1
          fi
          echo "Xcode $XCODE_VER OK"
      - name: Mac Catalyst build-for-testing
        working-directory: ios/Contracts
        run: |
          set -o pipefail
          xcodebuild build-for-testing \
            -scheme KlineTrainerContracts \
            -destination 'platform=macOS,variant=Mac Catalyst' \
            -derivedDataPath /tmp/derived 2>&1 | tee /tmp/catalyst-build.log
      - name: Gate — TEST BUILD SUCCEEDED + no error/warning
        run: |
          grep -F "** TEST BUILD SUCCEEDED **" /tmp/catalyst-build.log || { echo "BUILD SUCCEEDED 缺失"; exit 1; }
          ! grep -E "(^|[[:space:]])(error|warning):" /tmp/catalyst-build.log || { echo "error/warning 触发 gate"; exit 1; }
          echo "GATE PASS: §15.1 #3 闸门关闭（Catalyst CI 持续守护）"
```

- [ ] **Step 2.3: YAML 合法性验证**

```bash
python3 -c "import yaml; data = yaml.safe_load(open('.github/workflows/swift-contracts-smoke.yml')); print(list(data.get('jobs', {}).keys()))"
```

Expected: 输出 `['swift-test', 'catalyst-build']`（两个 job）。

- [ ] **Step 2.4: actionlint / 静态检查（如可用）**

可选 — 如本地装 `actionlint`：
```bash
actionlint .github/workflows/swift-contracts-smoke.yml 2>&1 || echo "actionlint 未装，跳过"
```

Expected: 0 errors（如装）或 "未装" 提示。

- [ ] **Step 2.5: Commit Task 2**

```bash
git add .github/workflows/swift-contracts-smoke.yml
git commit -m "ci(PR 9): 加 catalyst-build job 持续守 §15.1 #3 闸门 + 扩 paths 含 ios/KlineTrainer

- 镜像 swift-test job pattern（codex Plan 1c R2 修订 convention）：
  不硬编码 /Applications/Xcode_16.app；xcodebuild -version 断言版本
  + fail-fast 给清晰诊断；actions/checkout SHA pinned
- destination platform=macOS,variant=Mac Catalyst build-for-testing
- 3-gate 检查：TEST BUILD SUCCEEDED + 无 error: + 无 warning:
- 兑现 PR #51 R7 finding G3 residual: Catalyst CI 持续守护
- codex plan R1 finding 3 修：paths trigger 加 'ios/KlineTrainer/**'
  让 iOS-touching PR 全覆盖（不只 ios/Contracts/**）"
```

Expected: 1 file changed, +~52 行 yaml（50 新 job + 2 paths 行）。

---

### Task 3: Governance docs — §15.4 ledger + Wave 1 plan 模板

**Files:**
- Create: `docs/governance/2026-05-17-wave0-signoff-ledger.md`
- Create: `docs/governance/wave1-plan-template.md`

- [ ] **Step 3.1: 创建 §15.4 ledger**

Create `docs/governance/2026-05-17-wave0-signoff-ledger.md` 内容：

```markdown
# Wave 0 契约冻结签字 ledger（v1.4）

单人项目简化版：项目所有者 (@agateuu1234-bit) 兼任 iOS / 后端 / 数据三方代表，按 §15.4 ledger 形式记录三角色 review 过的范围。非真三方会议；ledger 形式留痕。

## 后端代表 sign-off（自签）
- [x] M0.1 DDL（PostgreSQL schema + 训练组 sqlite + AppDB）与 PR #23 / #29 一致
- [x] M0.2 OpenAPI 与 PR #24 三接口 schema 一致；lease 状态机 + CRC32 已落地
- [x] B1-B4 实现在 Wave 1 backlog；OpenAPI 与 backend 契约对齐
- **签字时间**：2026-05-17

## iOS 代表 sign-off（自签）
- [x] M0.3 数据模型：**23 个类型** inventory（16 Codable + 7 非 Codable，见 §M0.3 表）全 Equatable / 关键 Codable round-trip 闭环
- [x] M0.4 AppError + Reason 枚举 Error conformance（PR #26 / #27）
- [x] M0.5 并发契约 doc（PR #52）
- [x] F1 Models 薄 wrapper（PR #53）含 BinarySearch utility
- [x] F2 Theme（PR #39）13 默认色
- [x] C1a Geometry / C1b Reducer / C1c Render UIKit shell（PR #38 / #47 / #48 / #49 / #50 / #51）
- [x] §15.1 编译验证 #1-#9 全闭环：本地 swift test + Catalyst build SUCCEEDED + CI 持续守护（PR 9 加 catalyst-build job）
- [x] Preview Fixture 可在 Xcode Canvas 渲染（E6 PR #40 提供）
- **签字时间**：2026-05-17

## 数据代表 sign-off（自签）
- [x] B1 CSV 导入字段覆盖在 OpenAPI 与 spec §B1 一致（**契约层** sign-off — backend 实现 Wave 1）
- [x] B2 训练组生成策略（月线前 30 / 后 8 根月窗口）记录在 spec §B2（**契约层** sign-off）
- ⚠️ **未签**（codex R4 finding 3 修：future scope 不能签 ✅）：3-5 个样本训练组数据落地 → 移入 **residual H7**（Wave 1 B1/B2 PR 内验证 3-5 个样本数据正确性 + ledger 回填）
- **签字时间**：2026-05-17

## 已知 residuals（不阻塞 freeze；7 项 H1-H7）

| ID | residual | 来源 | 处理路径 |
|---|---|---|---|
| H1 | L1167 production handler 集成测试 | PR #50 plan-residual | Spec §6 C1b 闸门 #4 F3 v1.4 修订移 Wave 1（PR 9 子项 1） |
| H2 | E2 PositionManager 三连 abort | PR #36 closed | Wave 1 启动前 spec §4.2 重审窗口 |
| H3 | Wave 1 内部 plan 排序 | v6 outline 仅 Wave 0 | PR 9 merge 后 brainstorming + writing-plans 排细顺位 |
| H4 | M0.3 multi-file split 历史 over-claim | PR F1 R7+R8 | Spec §F1 wording + §M0.3 inventory 表（PR 9 子项 2） |
| H5 | Catalyst CI 持续守护 | PR #51 R7 G3 | `.github/workflows` Catalyst job（PR 9 子项 3） |
| H6 | backend deps exact pin | spec §15.2 暂用 ranges | Wave 1 B1-B4 PR 各自落 `backend/requirements.txt == X.Y.Z` + `docker-compose.yml` image digest pin |
| H7 | sample 训练组数据 | 数据代表 sign-off 第 3 项 future scope | Wave 1 B1/B2 PR 内真生成 3-5 个样本 + 数据正确性 ledger 回填 |

## 依赖版本锁定（§15.2 v1.4 freeze）

见 README v1.4 章节 + `ios/Contracts/Package.resolved`。

签字完成后：契约层进入 RFC 修改模式；任何 M0.* / F1 / F2 / C1a / C1b / C1c / E1 / E6 / P3 / P4 / P5 / P6 改动需 RFC 走 superpowers:brainstorming + ledger 留痕。

## Provenance

本 ledger **不内嵌 PR 9 squash commit SHA**；provenance 走三件互证：

1. **annotated tag** (`git show wave0-frozen-v1.4`) — 显示 tagger / date / target commit SHA / message
2. **GitHub protected tag namespace（mandatory）** — `wave0-frozen-*` 配 admin-only push + 禁 force-update；tag 创建脚本 protected ruleset 完整谓词检查 (`scripts/governance/verify-freeze-tag.sh`) fail → `exit 1`
3. **本 ledger + README v1.4** — 三处文本签字记录互证；任意一处篡改可 `git diff` 出来

完整 tag 验证脚本见 spec §5.6（含三层 blocking gate）。

**注意**：annotated tag (`-a`) 自身的 tagger 字段是 arbitrary metadata，不是 cryptographic proof。signed tag (`-s`) 才提供加密保证；单人项目实操中 GitHub protected tag namespace + admin-only push = remote ref 不可篡改的等价防线。
```

- [ ] **Step 3.2: 创建 Wave 1 plan 模板**

Create `docs/governance/wave1-plan-template.md` 内容：

```markdown
# Wave 1+ plan 模板

每个 Wave 1+ plan 在 Task 0 前置声明本 plan 使用哪些评审形式（spec §15.3 L2495-2505）：

## Task 0 — §15.3 评审策略前置

- [ ] **局部对抗性评审**（必）：本 plan 子模块 scope 内 codex:adversarial-review；4-5 轮内收敛或 escalate（按 memory `feedback_codex_plan_budget_overshoot`）
- [ ] **集成层评审**（C8 桥接 + E5 编排所在 PR 必）：codex 对比"契约声明 vs 实际实现"
- [ ] **性能评审**（Phase 5 磨光 PR 必）：Instruments 数据对照 plan v1.5 §一"单帧 <4ms" 目标，codex 审视性能热点

完成 Task 0 才进 Task 1 实施。

---

memory `project_review_strategy_deferred` PR 9 后 archived。
```

- [ ] **Step 3.3: 创建 docs/governance/ 目录（如需要）**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
ls docs/governance/ 2>/dev/null || mkdir -p docs/governance/
ls docs/governance/
```

Expected: 看到 `m01-schema-versioning-contract.md` / `m04-apperror-translation-gate.md` / `signing-rules.md` / `adversarial-review-template.md` 等现有 governance docs（目录已存在）。

- [ ] **Step 3.4: 验证文件落地**

```bash
wc -l docs/governance/2026-05-17-wave0-signoff-ledger.md docs/governance/wave1-plan-template.md
grep -c "^## " docs/governance/2026-05-17-wave0-signoff-ledger.md
grep -c "H[1-7]" docs/governance/2026-05-17-wave0-signoff-ledger.md
```

Expected:
- ledger ≈ 80 行 / template ≈ 15 行
- ledger 含 ≥ 5 个 `## ` 一级 section
- H1-H7 各出现 ≥ 1 次

- [ ] **Step 3.5: Commit Task 3**

```bash
git add docs/governance/2026-05-17-wave0-signoff-ledger.md
git add docs/governance/wave1-plan-template.md
git commit -m "gov(PR 9): §15.4 三方签字 ledger + Wave 1 plan 模板

- ledger: 单人项目简化 self-sign（iOS/后端/数据三角色）+ 7 residuals
  H1-H7 (L1167/E2/Wave 1 plan/M0.3 multi-file/Catalyst CI/backend deps/sample 数据)
  + Provenance 三件互证（annotated tag + protected namespace + ledger/README）
- wave1-plan-template.md: §15.3 评审策略 3 形式（局部对抗 / 集成层 / 性能）
  Wave 1+ 每 plan Task 0 前置；memory project_review_strategy_deferred archived"
```

Expected: 2 files changed, +~95 行。

---

### Task 4: README v1.4 + 依赖版本表

**Files:**
- Modify: `README.md`

- [ ] **Step 4.1: 读现有 README 找插入点**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
cat README.md
```

Expected: 看到现有 README 内容（可能是项目介绍 + 几个章节）。

- [ ] **Step 4.2: 在 README 末尾追加 Wave 0 章节**

使用 Edit tool。**old_string** = README 最末一行非空内容；**new_string** = 同样的最末行 + 下面新章节。如 README 末尾是空文件或 1 行，使用 Write tool 完全写。

新章节内容（追加在 README 末尾）：

```markdown

## Wave 0 契约冻结 v1.4（2026-05-17）

Wave 0 已签字冻结。tag：`wave0-frozen-v1.4`。Sign-off ledger：[docs/governance/2026-05-17-wave0-signoff-ledger.md](docs/governance/2026-05-17-wave0-signoff-ledger.md)。

### 依赖版本锁定（spec §15.2；codex R2 finding 1 修：iOS exact pin / backend 移 residual）

**iOS 依赖（Wave 0 freeze，exact 版本，来自 `ios/Contracts/Package.resolved`）：**

| 依赖 | 用途 | 版本 | Lock 源 |
|---|---|---|---|
| GRDB.swift | iOS SQLite ORM | **6.29.3** | `Package.resolved` |
| ZipFoundation | iOS zip 解压 | **0.9.20** | `Package.resolved` |
| SQLite | iOS 内嵌 | iOS 17+ 系统自带 | iOS minimum deployment target |

**Wave 0 起 `Package.resolved` 视为锁定 source-of-truth**。变更走 RFC + ledger。

**后端依赖（Wave 1 B1-B4 PR 内 exact pin；Wave 0 暂用 ranges + residual H6）：**

| 依赖 | 用途 | spec §15.2 range | 真锁定时点 |
|---|---|---|---|
| FastAPI | 后端 API 框架 | 0.110+ | B3 PR 落 `backend/requirements.txt == 0.110.x` |
| Uvicorn | ASGI server | 0.27+ | B3 PR |
| APScheduler | 后端定时 | 3.10+ | B4 PR |
| pandas | 后端数据 | 2.x | B1 PR |
| pandas-ta | 指标计算 | 0.3.14b0+ | B2 PR |
| asyncpg | PG 驱动 | 0.29+ | B3 PR |
| PostgreSQL | 数据仓库 | 15+ | `docker-compose.yml` image digest pin B3 PR |

Wave 0 freeze **仅 iOS deps exact pin**；backend ranges 待 Wave 1 B1-B4 PR 各自落 `requirements.txt == X.Y.Z` 时同步锁定（residual H6 in `docs/governance/2026-05-17-wave0-signoff-ledger.md`）。

### Wave 0 交付清单

17 业务模块（PR #37 - #53）+ M0 契约 + F1/F2 基础 + C1a/C1b/C1c 图表核心 → 见 sign-off ledger。
```

- [ ] **Step 4.3: 验证 README**

```bash
grep -c "Wave 0 契约冻结 v1.4" README.md
grep -c "GRDB.swift" README.md
grep -c "6.29.3" README.md
grep -c "ZipFoundation" README.md
grep -c "0.9.20" README.md
grep -c "residual H6" README.md
```

Expected: 每个 grep ≥ 1（6 项全命中）。

- [ ] **Step 4.4: Commit Task 4**

```bash
git add README.md
git commit -m "docs(PR 9): README v1.4 章节 + 依赖版本表

- iOS exact pin: GRDB.swift 6.29.3 / ZipFoundation 0.9.20（Package.resolved）
- backend ranges + residual H6（Wave 1 B1-B4 PR 内 exact pin）
- 引用 sign-off ledger 路径
- 17 业务模块（PR #37-#53）+ M0 契约 + F1/F2 + C1a/C1b/C1c 交付清单"
```

Expected: 1 file changed, +~30 行 README。

---

### Task 5: verify-freeze-tag.sh — protected tag ruleset 完整谓词检查脚本

**Files:**
- Create: `scripts/governance/verify-freeze-tag.sh`

- [ ] **Step 5.1: 创建 scripts/governance/ 目录**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
ls scripts/governance/ 2>/dev/null || mkdir -p scripts/governance/
ls scripts/
```

Expected: 看到现有 `scripts/acceptance/` + 新创建的 `scripts/governance/`。

- [ ] **Step 5.2: 创建脚本（codex plan R1 finding 1 修：python heredoc stdin 改 env var）**

Create `scripts/governance/verify-freeze-tag.sh`（chmod +x 之后）：

```bash
#!/usr/bin/env bash
# verify-freeze-tag.sh — Wave 0 freeze tag protected namespace 完整谓词检查
# Spec: docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md §5.6 layer 1
# Usage: ./scripts/governance/verify-freeze-tag.sh --ref refs/tags/wave0-frozen-v1.4
set -euo pipefail

REPO="${REPO:-agateuu1234-bit/kline-trainer}"
TARGET_REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) TARGET_REF="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --ref refs/tags/wave0-frozen-v1.4 [--repo OWNER/NAME]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$TARGET_REF" ]; then
  echo "FAIL: --ref refs/tags/wave0-frozen-v1.4 required"
  exit 2
fi

# 拉所有 rulesets — 用 env var 传 JSON 给嵌入 python（codex plan R1 finding 1 修：
# 不能用 stdin pipe + heredoc，<<'PY' 抢 stdin 让 json.load(sys.stdin) 拿不到）
RULESETS_JSON=$(gh api "repos/$REPO/rulesets" 2>&1) || {
  echo "FAIL: gh api repos/$REPO/rulesets 失败"
  echo "$RULESETS_JSON"
  exit 1
}

# 过滤 target=tag 的 ruleset ID 列表
TAG_RULESET_IDS=$(RULESETS_JSON="$RULESETS_JSON" python3 <<'PY'
import json, os
data = json.loads(os.environ['RULESETS_JSON'])
ids = [str(r['id']) for r in data if r.get('target') == 'tag']
print(' '.join(ids))
PY
)

if [ -z "$TAG_RULESET_IDS" ]; then
  echo "FAIL: 无任何 target=tag 的 ruleset 在 repo $REPO"
  echo "  required: ref_name include pattern 命中 '$TARGET_REF' / enforcement=active /"
  echo "            rules 含 creation+update+deletion / bypass_actors admin-only"
  echo "  修：GitHub repo Settings → Rules → New tag ruleset"
  exit 1
fi

# 逐个 ID 拉详情 + 评估
PROTECTED_OK=0
FAILED_REASONS=""
for RID in $TAG_RULESET_IDS; do
  DETAIL=$(gh api "repos/$REPO/rulesets/$RID")
  # codex plan R1 finding 1 修：DETAIL 通过 env var 传，不走 stdin（heredoc 抢 stdin）
  set +e
  RESULT=$(DETAIL_JSON="$DETAIL" TARGET_REF="$TARGET_REF" python3 <<'PY'
import json, os, fnmatch, sys
ruleset = json.loads(os.environ['DETAIL_JSON'])
target_ref = os.environ['TARGET_REF']

reasons = []

# 谓词 1: enforcement == active
if ruleset.get('enforcement') != 'active':
    reasons.append(f"enforcement={ruleset.get('enforcement')}, not active")

# 谓词 2: target_ref 命中 include + 不命中 exclude
conds = ruleset.get('conditions') or {}
ref_cond = conds.get('ref_name') or {}
include = ref_cond.get('include') or []
exclude = ref_cond.get('exclude') or []

# GitHub include pattern: 支持 ~ALL 通配 + fnmatch glob
def matches(patterns, ref):
    for p in patterns:
        if p == '~ALL':
            return True
        # 标准化: 如果 pattern 不含 refs/tags 前缀，补一下
        norm = p if p.startswith('refs/') else f'refs/tags/{p}'
        if fnmatch.fnmatchcase(ref, norm) or fnmatch.fnmatchcase(ref, p):
            return True
    return False

if not matches(include, target_ref):
    reasons.append(f"target_ref {target_ref} 不命中 include patterns {include}")
if matches(exclude, target_ref):
    reasons.append(f"target_ref {target_ref} 被 exclude patterns {exclude} 排除")

# 谓词 3: rules 含 creation + update + deletion 三类
rules = ruleset.get('rules') or []
types = {x.get('type') for x in rules}
required = {'creation', 'update', 'deletion'}
missing = required - types
if missing:
    reasons.append(f"rules 缺类型 {sorted(missing)}; 已有 {sorted(types)}")

# 谓词 4: bypass_actors 限 admin-only
bypass = ruleset.get('bypass_actors') or []
# GitHub admin: actor_type='RepositoryRole' + actor_id=5 (admin) OR actor_type='OrganizationAdmin'
def is_admin_bypass(b):
    at = b.get('actor_type', '')
    aid = b.get('actor_id', 0)
    if at == 'OrganizationAdmin':
        return True
    if at == 'RepositoryRole' and aid == 5:  # 5 = admin role per GitHub docs
        return True
    return False

non_admin = [b for b in bypass if not is_admin_bypass(b)]
if non_admin:
    reasons.append(f"bypass_actors 含 non-admin: {non_admin}")

if reasons:
    print("FAIL: " + " | ".join(reasons))
    sys.exit(1)
print("OK")
PY
)
  PY_EXIT=$?
  set -e

  if [ "$PY_EXIT" = "0" ] && [ "$RESULT" = "OK" ]; then
    echo "Ruleset $RID: OK"
    PROTECTED_OK=1
    break
  else
    FAILED_REASONS="$FAILED_REASONS\n  Ruleset $RID: $RESULT"
  fi
done

if [ "$PROTECTED_OK" != "1" ]; then
  echo "FAIL: 无 target=tag ruleset 满足 protected 谓词检查"
  printf '%b\n' "$FAILED_REASONS"
  echo ""
  echo "  required: enforcement=active +"
  echo "            $TARGET_REF 命中 include 且不命中 exclude +"
  echo "            rules 含 creation + update + deletion +"
  echo "            bypass_actors 仅 admin role"
  exit 1
fi

echo "GATE PASS: protected tag namespace 完整谓词检查通过（$TARGET_REF）"
exit 0
```

- [ ] **Step 5.3: chmod + 静态语法检查**

```bash
chmod +x scripts/governance/verify-freeze-tag.sh
bash -n scripts/governance/verify-freeze-tag.sh  # bash syntax check
python3 -c "exec(open('scripts/governance/verify-freeze-tag.sh').read().split('<<\"PY\"')[1].split('PY\\n)')[0])" 2>&1 | head -3 || echo "(脚本嵌入 python 不能直接 exec，需在 gh 上下文运行)"
```

Expected: bash syntax 0 errors（python 嵌入部分需 gh 上下文跑）。

- [ ] **Step 5.4: Dry-run（不实际 push tag）**

如本地有 `gh` + 认证：

```bash
./scripts/governance/verify-freeze-tag.sh --ref "refs/tags/wave0-frozen-v1.4" 2>&1 | head -20 || echo "Expected fail if ruleset 未配 / repo 不存在"
```

Expected: FAIL 或 "ruleset 未配"诊断（PR 9 merge 前 protected namespace 尚未配置，预期 fail；脚本逻辑工作正常）。

- [ ] **Step 5.5: Commit Task 5**

```bash
git add scripts/governance/verify-freeze-tag.sh
git commit -m "gov(PR 9): verify-freeze-tag.sh — protected ruleset 完整谓词检查

由 tag 创建 wrapper 脚本（spec §5.6 layer 1）调用：
- 谓词 1: enforcement=active
- 谓词 2: target_ref 命中 conditions.ref_name.include AND 不命中 exclude (fnmatch + ~ALL)
- 谓词 3: rules 含 creation + update + deletion 三类
- 谓词 4: bypass_actors 仅 RepositoryRole=admin (id=5) / OrganizationAdmin

任一谓词 fail exit 1 + 完整诊断输出。
覆盖 codex R5 finding 2 + R6 完整规约（不光 include substring）。"
```

Expected: 1 file changed, +~120 行 bash + 嵌入 python。

---

### Task 6: 验收文档 + final verification

**Files:**
- Create: `docs/acceptance/2026-05-17-pr9-wave0-freeze.md`

- [ ] **Step 6.1: 写验收清单**

Create `docs/acceptance/2026-05-17-pr9-wave0-freeze.md`：

```markdown
# PR 9 验收清单 — Wave 0 契约冻结 ceremony

> 这份清单给非-coder 用户用：复制每一行"action"到 Claude Code 或 Terminal，对照"expected"判断 pass / fail。

## A. 文件落地

| # | action | expected | pass_fail |
|---|---|---|---|
| A1 | `grep -c "Wave 1 验收（C2 DecelerationAnimator" kline_trainer_modules_v1.4.md` | ≥ 1（spec §6 C1b L1167 修订落地） | ☐ |
| A2 | `grep -c "23 M0.3 类型" kline_trainer_modules_v1.4.md` | ≥ 1（§M0.3 inventory 表落地） | ☐ |
| A3 | `ls .github/workflows/swift-contracts-smoke.yml` + `python3 -c "import yaml; print(list(yaml.safe_load(open('.github/workflows/swift-contracts-smoke.yml'))['jobs'].keys()))"` | 输出 `['swift-test', 'catalyst-build']`（catalyst job 落地） | ☐ |
| A4 | `ls docs/governance/2026-05-17-wave0-signoff-ledger.md` | 文件存在 | ☐ |
| A5 | `ls docs/governance/wave1-plan-template.md` | 文件存在 | ☐ |
| A6 | `grep -c "Wave 0 契约冻结 v1.4" README.md` | ≥ 1 | ☐ |
| A7 | `test -x scripts/governance/verify-freeze-tag.sh && echo OK` | 输出 `OK`（脚本可执行） | ☐ |

## B. 编译验证（spec amendments 不影响代码）

| # | action | expected | pass_fail |
|---|---|---|---|
| B1 | `cd ios/Contracts && swift build` | 输出 `Build complete!`，无 error 无 warning | ☐ |
| B2 | `cd ios/Contracts && swift test 2>&1 \| tail -3` | 末尾出现 `Test run with 297 tests in 63 suites passed`（与 PR #53 baseline 一致；本 PR 0 业务代码改动） | ☐ |

## C. Ledger 完整性（codex R6 finding 2 修：明列 H1-H7）

| # | action | expected | pass_fail |
|---|---|---|---|
| C1 | `grep -c "H[1-7]" docs/governance/2026-05-17-wave0-signoff-ledger.md` | 至少 14（H1-H7 表头 + 7 行） | ☐ |
| C2 | `grep "## .*sign-off" docs/governance/2026-05-17-wave0-signoff-ledger.md` | 输出 3 行：后端代表 / iOS 代表 / 数据代表 | ☐ |
| C3 | `grep "Provenance" docs/governance/2026-05-17-wave0-signoff-ledger.md` | ≥ 1（codex R1 finding 1 修订标记） | ☐ |
| C4 | `grep -F "(PR 9 squash commit SHA" docs/governance/2026-05-17-wave0-signoff-ledger.md` | 空输出（ledger 不含 SHA 占位符；codex R1 finding 1 修） | ☐ |

## D. CI（GitHub Actions）

| # | action | expected | pass_fail |
|---|---|---|---|
| D1 | `gh pr checks <pr_number>` | 7/7 checks SUCCESS（含新 catalyst-build job） — 或 OpenAI quota fail 走 admin bypass per memory `feedback_openai_quota_ci_pattern` | ☐ |

## E. Tag 三层 blocking gate（PR 9 merge 之后跑，mirror spec §5.6）

> ⚠️ 本节在 **PR 9 merge 之后**单独跑，不在 PR 9 commits 内。**整段保持 `set -euo pipefail`**（codex plan R2 finding 1 修：v1/v2 缺 strict mode 让 nonzero exit 不阻断后续 tag 创建/push，fail-open）；任一 `exit 1` 失败 = freeze ceremony fail，回查诊断。

```bash
set -euo pipefail   # codex plan R2 finding 1 修：必须 strict mode，否则上面任何 exit 1 不阻断后续

# 前置 0：auto-detect 真实 GitHub PR number（codex plan R3 finding 1 修：
# "PR 9" 是项目内部命名，actual GitHub PR # 由 gh pr create 分配，可能 #54+）
BRANCH="pr9-wave0-freeze"
PR_NUMBER=$(gh pr list --repo agateuu1234-bit/kline-trainer --head "$BRANCH" --state merged --json number --jq '.[0].number')
[ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ] || {
  echo "FAIL: 找不到 branch $BRANCH 的已 merge PR"
  echo "  如刚 merge，确认 origin 已 fetch 最新；如 PR 还在 open，等 merge 完再跑本 ceremony"
  exit 1
}
echo "Detected actual GitHub PR #$PR_NUMBER for branch $BRANCH"

# 拿 PR squash commit SHA
EXPECTED_SHA=$(gh pr view "$PR_NUMBER" --repo agateuu1234-bit/kline-trainer --json mergeCommit --jq '.mergeCommit.oid')
[ -n "$EXPECTED_SHA" ] && [ "$EXPECTED_SHA" != "null" ] || { echo "FAIL: PR #$PR_NUMBER mergeCommit 拿不到"; exit 1; }
echo "Expected PR #$PR_NUMBER squash commit: $EXPECTED_SHA"
git fetch origin main
LOCAL_MAIN=$(git rev-parse origin/main)
[ "$LOCAL_MAIN" = "$EXPECTED_SHA" ] || { echo "FAIL: origin/main HEAD ($LOCAL_MAIN) != PR #$PR_NUMBER squash SHA ($EXPECTED_SHA)"; exit 1; }
TAG_COMMIT="$EXPECTED_SHA"

# 层 1 (前置)：protected tag namespace 完整谓词检查 — 显式 || exit 1（set -e 已防呆，双保险）
./scripts/governance/verify-freeze-tag.sh --ref "refs/tags/wave0-frozen-v1.4" || { echo "FAIL: 层 1 protected ruleset check"; exit 1; }

# Tag 创建（优先 signed，fallback unsigned）
if git tag -s wave0-frozen-v1.4 \
    -m "Wave 0 契约冻结 v1.4：17 业务模块 + M0 契约 + §15.4 三方签字 ledger" \
    "$TAG_COMMIT" 2>/dev/null; then
  TAG_SIGNED=1
else
  echo "WARN: GPG/SSH signing 未配，fallback annotated"
  git tag -a wave0-frozen-v1.4 -m "Wave 0 契约冻结 v1.4" "$TAG_COMMIT" || { echo "FAIL: annotated tag 创建"; exit 1; }
  TAG_SIGNED=0
fi

# 层 2：本地 signed verify + peeled SHA pre-check
if [ "$TAG_SIGNED" = "1" ]; then
  git verify-tag wave0-frozen-v1.4 || { echo "FAIL signed verify (push 前本地拦截)"; git tag -d wave0-frozen-v1.4; exit 1; }
fi
LOCAL_PEELED=$(git rev-parse "wave0-frozen-v1.4^{}")
[ "$LOCAL_PEELED" = "$EXPECTED_SHA" ] || { echo "FAIL local peeled $LOCAL_PEELED != $EXPECTED_SHA"; git tag -d wave0-frozen-v1.4; exit 1; }

# Push 到 remote (set -e + 显式 || exit 双保险)
git push origin wave0-frozen-v1.4 || { echo "FAIL: git push origin wave0-frozen-v1.4"; exit 1; }

# 层 3：remote peeled SHA 反查
REMOTE_PEELED=$(git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}" | awk '{print $1}')
[ -n "$REMOTE_PEELED" ] || { echo "FAIL: remote peeled SHA 拿不到"; exit 1; }
[ "$REMOTE_PEELED" = "$EXPECTED_SHA" ] || { echo "FAIL remote peeled $REMOTE_PEELED != $EXPECTED_SHA"; exit 1; }

echo "GATE PASS: tag wave0-frozen-v1.4 三层验证全过"
```

| # | action | expected | pass_fail |
|---|---|---|---|
| E1 | 跑完上面命令链 | 末尾 `GATE PASS: tag wave0-frozen-v1.4 三层验证全过`；无 FAIL | ☐ |
| E2 | `git tag -l 'wave0-frozen-*'` | 输出 `wave0-frozen-v1.4` | ☐ |
| E3 | `git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}" \| awk '{print $1}'`（codex plan R2 finding 2 修：annotated tag 用 peeled，不是 `.object.sha` 拿 tag object） | 输出 = `$EXPECTED_SHA`（PR 9 squash commit） | ☐ |

## F. Scope 边界（不应做的事）

| # | action | expected | pass_fail |
|---|---|---|---|
| F1 | `git diff main -- ios/Contracts/Sources/` | 输出为空（不动业务代码） | ☐ |
| F2 | `git diff main -- ios/Contracts/Tests/` | 输出为空（不动测试） | ☐ |
| F3 | `git diff main -- ios/Contracts/Package.swift` | 输出为空（不动 SwiftPM manifest） | ☐ |

## G. 文档

| # | action | expected | pass_fail |
|---|---|---|---|
| G1 | `ls docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md` | 文件存在 | ☐ |
| G2 | `ls docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md` | 文件存在 | ☐ |
| G3 | `ls docs/acceptance/2026-05-17-pr9-wave0-freeze.md` | 文件存在（本文件） | ☐ |
```

- [ ] **Step 6.2: 自检 acceptance 长度**

```bash
wc -l docs/acceptance/2026-05-17-pr9-wave0-freeze.md
grep -c "^| " docs/acceptance/2026-05-17-pr9-wave0-freeze.md
grep -c "pass_fail" docs/acceptance/2026-05-17-pr9-wave0-freeze.md
```

Expected:
- `wc -l` ≤ 95（CLAUDE.md backstop acceptance 长度约定；超 95 行考虑拆 section 或精简）
- table rows ≥ 18（A1-A7 + B1-B2 + C1-C4 + D1 + E1-E3 + F1-F3 + G1-G3）
- pass_fail 标记 ≥ 18

注：本验收清单含 §E tag merge 后命令链（包含 bash code block），可能略超 95 行；按项目惯例 governance PR 允许 ≤120 行 acceptance。

- [ ] **Step 6.3: 跑 acceptance §A + §B + §C + §F + §G（PR 9 merge 前可跑）**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
# 跑 A1-A7
grep -c "Wave 1 验收（C2 DecelerationAnimator" kline_trainer_modules_v1.4.md
grep -c "23 M0.3 类型" kline_trainer_modules_v1.4.md
python3 -c "import yaml; print(list(yaml.safe_load(open('.github/workflows/swift-contracts-smoke.yml'))['jobs'].keys()))"
ls docs/governance/2026-05-17-wave0-signoff-ledger.md
ls docs/governance/wave1-plan-template.md
grep -c "Wave 0 契约冻结 v1.4" README.md
test -x scripts/governance/verify-freeze-tag.sh && echo OK
# 跑 B1-B2
cd ios/Contracts && swift build 2>&1 | tail -3
swift test 2>&1 | tail -3
cd ../..
# 跑 C1-C4
grep -c "H[1-7]" docs/governance/2026-05-17-wave0-signoff-ledger.md
grep "## .*sign-off" docs/governance/2026-05-17-wave0-signoff-ledger.md
grep -c "Provenance" docs/governance/2026-05-17-wave0-signoff-ledger.md
grep -F "(PR 9 squash commit SHA" docs/governance/2026-05-17-wave0-signoff-ledger.md || echo "EMPTY (good)"
# 跑 F1-F3
git diff main -- ios/Contracts/Sources/
git diff main -- ios/Contracts/Tests/
git diff main -- ios/Contracts/Package.swift
# 跑 G1-G3
ls docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md
ls docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md
ls docs/acceptance/2026-05-17-pr9-wave0-freeze.md
```

Expected:
- A1-A7: 每项命中
- B1: Build complete!
- B2: 297 tests in 63 suites passed
- C1: ≥ 14；C2: 3 行 sign-off；C3: ≥ 1 Provenance；C4: EMPTY（good）
- F1-F3: 全空
- G1-G3: 文件存在

§D + §E 留 PR 9 push + merge 后跑（CI checks + tag ceremony）。

- [ ] **Step 6.4: Commit Task 6**

```bash
git add docs/acceptance/2026-05-17-pr9-wave0-freeze.md
git commit -m "docs(PR 9): 中文非-coder 验收清单（A-G 节 + tag 三层 blocking gate）

- A 文件落地 (A1-A7) / B 编译 (B1-B2) / C ledger 完整性 (C1-C4) /
  D CI / E tag merge 后 3 层 gate (E1-E3) / F scope 边界 (F1-F3) / G 文档 (G1-G3)
- 含 spec §5.6 三层 blocking gate 完整命令链（前置 0 + 层 1 ruleset / 层 2
  本地 verify + peeled / 层 3 remote peeled）"
```

Expected: 1 file changed, +~95 行 acceptance。

---

### Task 7: Final verification + acceptance ☑

**Files:** （无 code 改动，验证 + 签字）

- [ ] **Step 7.1: 整体回归测试 (再次)**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze/ios/Contracts
if ! ( set -o pipefail; swift test 2>&1 | tee /tmp/pr9-final.log ); then echo "FINAL TEST FAIL"; exit 1; fi
tail -5 /tmp/pr9-final.log
```

Expected: `Test run with 297 tests in 63 suites passed`（与 baseline 一致；本 PR 0 业务代码改动）。

- [ ] **Step 7.2: branch-diff 自审 — surgical 边界**

```bash
cd /Users/maziming/Coding/Prj_Kline\ trainer/.worktrees/pr9-wave0-freeze
git diff main --stat
git log main..HEAD --oneline
```

Expected:
- 改动文件：~10 个（spec md / CI yml / 2 governance md / README md / verify-freeze-tag.sh / acceptance md / plan md + 已 commit 的 v1-v7 spec amendments file）
- Commits：~15 个（v1-v7 spec brainstorming 7 commits + Task 0 plan + Task 1-6 各一个）

Confirm 0 业务代码改动：

```bash
git diff main -- ios/Contracts/Sources/ ios/Contracts/Tests/ ios/Contracts/Package.swift ios/KlineTrainer/
```

Expected: 全空（0 业务/测试/manifest 改动）。

- [ ] **Step 7.3: 把 acceptance ☐ → ☑（merge 前可勾的项）**

人工核对 Task 6 acceptance 跑过的 §A + §B + §C + §F + §G 全勾 ☑；§D（CI）+ §E（tag merge 后）保持 ☐ 注明"待 PR push + merge"。

```bash
git add docs/acceptance/2026-05-17-pr9-wave0-freeze.md
git commit -m "docs(PR 9): 验收清单 §A+§B+§C+§F+§G ☑（local 验证完成；§D CI + §E tag 待 push/merge 后跑）"
```

Expected: 1 file changed。

- [ ] **Step 7.4: requesting-code-review skill 自审**

调用 `superpowers:requesting-code-review` 走一遍 final diff（branch vs main）。

预期输出：
- 0 critical / 0 high finding
- ≤ 3 medium/low（如 doc wording / commit message tweaks）

如果有 high+ finding → 回 Task 1-6 修。

- [ ] **Step 7.5: codex 对抗性 review（impl 阶段）**

走 `codex:adversarial-review --scope branch-diff --base origin/main --head pr9-wave0-freeze`。

收敛规则（memory `feedback_codex_round6_self_contradiction` + `feedback_codex_plan_budget_overshoot`）：
- 5 轮内必收敛 / 全修真 finding
- 第 6+ 轮自相矛盾或复述已 accept residual → user TTY override
- 第 ≥ 4 轮命中"复述同条 finding"模式 → 升 user 决议

---

## PR 9 push + merge + tag procedure

PR 9 commits 准备好后：

```bash
git push -u origin pr9-wave0-freeze
gh pr create --repo agateuu1234-bit/kline-trainer --base main --head pr9-wave0-freeze \
  --title "PR 9: Wave 0 契约冻结 ceremony（spec amendments + Catalyst CI + ledger + README v1.4 + verify-freeze-tag.sh）" \
  --body-file /tmp/pr9-body.md  # 中文 body per feedback_pr_language_chinese
```

CI 全绿 + codex impl review APPROVE 后：

```bash
# Admin squash merge --match-head-commit per project convention
SHA=$(gh pr view <pr_number> --repo agateuu1234-bit/kline-trainer --json headRefOid --jq '.headRefOid')
gh pr merge <pr_number> --repo agateuu1234-bit/kline-trainer --squash --admin --delete-branch --match-head-commit "$SHA"
```

**Merge 之后**，按 acceptance §E 跑 tag 三层 blocking gate：

```bash
# 步骤见 acceptance §E（前置 0 + 层 1 ruleset + tag 创建 + 层 2 本地 verify + 层 3 remote peeled）
```

**前置准备**（在 tag 创建前完成）：

GitHub repo Settings → Rules → New tag ruleset：
- Name: `wave0-frozen-protected`
- Enforcement: `Active`
- Target ref name pattern (include): `wave0-frozen-*`
- Rules: ✅ Restrict creations / ✅ Restrict updates / ✅ Restrict deletions
- Bypass actors: Repository admin only（actor_type=RepositoryRole, actor_id=5）

无此 ruleset → `verify-freeze-tag.sh` layer 1 fail → tag 不会创建。

---

## Self-Review（writing-plans skill 内置 checklist）

**1. Spec coverage**：

- ✅ Spec v7 §5.1 (L1167 移 Wave 1) → Task 1 Step 1.2
- ✅ Spec v7 §5.2.1 (§F1 wording) → Task 1 Step 1.3
- ✅ Spec v7 §5.2.2 (§M0.3 inventory 表) → Task 1 Step 1.4
- ✅ Spec v7 §5.3 (Catalyst CI job) → Task 2
- ✅ Spec v7 §5.4 (§15.4 ledger) → Task 3 Step 3.1
- ✅ Spec v7 §5.5 (README v1.4) → Task 4
- ✅ Spec v7 §5.6 (tag 三层 blocking gate) → Task 5 (script) + acceptance §E (manual procedure post-merge)
- ✅ Spec v7 §5.7 (§15.3 Wave 1 plan 模板) → Task 3 Step 3.2
- ✅ Spec v7 §6 验证清单 → acceptance md 整个文件
- ✅ Spec v7 §7 流水线 → Task 7 Step 7.4 + Step 7.5

**2. Placeholder scan**：

- 全文 grep "TBD\|TODO\|implement later\|fill in details\|Add appropriate\|Similar to Task" → 0 命中
- 每个 Step 含具体 bash / yaml / markdown 代码 ✓
- verify-freeze-tag.sh 完整代码在 Step 5.2 字面给出 ✓
- §15.4 ledger / Wave 1 plan 模板 / README v1.4 章节 / acceptance 全文都字面给出 ✓

**3. Type consistency**：

- file paths `kline_trainer_modules_v1.4.md` / `.github/workflows/swift-contracts-smoke.yml` / `docs/governance/...` / `scripts/governance/verify-freeze-tag.sh` / `docs/acceptance/...` 全文一致 ✓
- residual ID H1-H7 在 ledger + acceptance + README 引用一致 ✓
- 数字一致：23 M0.3 类型（16 + 7）/ 297 tests / 63 suites ✓

✅ Self-review 通过。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md`.**

按 user 指定 + memory `project_executing_plans_excluded`，下一步 = **superpowers:subagent-driven-development**（每 Task fresh sonnet 4.6 high-effort subagent + per-task spec + quality 双轮 review）。

完整流水线后续步骤：
1. codex:adversarial-review plan-stage（本 plan v1 → 收敛）
2. superpowers:subagent-driven-development Task 0-7
3. superpowers:verification-before-completion
4. superpowers:requesting-code-review
5. codex:adversarial-review impl-stage（branch-diff）→ 收敛
6. push + gh pr create + admin squash merge
7. PR 9 merge **之后** manual tag procedure（acceptance §E）
