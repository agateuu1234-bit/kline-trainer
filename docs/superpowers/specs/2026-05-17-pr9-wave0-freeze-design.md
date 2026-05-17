# PR 9 — Wave 0 契约冻结 ceremony 设计

**作者**：@agateuu1234-bit (Claude Opus 4.7 协助)
**日期**：2026-05-17
**Wave**：Wave 0 closing ceremony（在 v6 outline 17 顺位之后）
**类型**：Governance（trust-boundary，含 CI workflow + spec amendment + git tag）

**Revision history：**
- **v1**（2026-05-17）：初稿 → codex spec-stage R1 verdict `needs-attention`（2 findings：1 high + 1 medium）
- **v2**（2026-05-17）：codex R1 2 findings 全修
  - finding 1 (high) → 移除 ledger 内 `(PR 9 squash commit SHA，PR merge 后填)` 占位符；provenance 走 annotated tag (`git show wave0-frozen-v1.4`)；ledger 自身保持 self-contained 不含 SHA；验收清单同步删 "commit SHA 占位" 项
  - finding 2 (medium) → Catalyst CI job 不硬编码 `/Applications/Xcode_16.app`；改用 existing `swift-contracts-smoke.yml` swift-test job 同 pattern（依赖 runner 默认 Xcode，`xcodebuild -version` 断言版本，fail-fast 给诊断 — 镜像 codex Plan 1c R2 已确立的项目 convention）
- **v3**（2026-05-17）：codex R2 3 findings 全修
  - finding 1 (high) → 依赖 freeze 用 ranges 不实；iOS deps 改为 `Package.resolved` 真实 exact 版本 (GRDB.swift **6.29.3** / ZipFoundation **0.9.20**)；backend deps (FastAPI/pandas 等) 实际未实现 — 移到 residual H6 (Wave 1 B1-B4 PR 内 `requirements.txt == 精确锁定` 时同步) + 标识"Wave 0 freeze 仅 iOS deps exact pin；backend ranges Wave 1 内闭环"
  - finding 2 (high) → M0.3 inventory 数学错；改为 16+5=21（v3-time）；v4 R3 再次抓出还漏 2 个 AppState 类型
  - finding 3 (high) → annotated tag 单凭 metadata 不是 cryptographic；删 overclaim；加 protected tag namespace + optional signed tag；v4 R3 再次抓出 `|| echo` 静默吞失败
- **v4**（2026-05-17）：codex R3 3 findings 全修
  - finding 1 (high) → M0.3 inventory v3 还漏 AppState.swift 的 2 个非 Codable struct (TrainingSetFile / AppSettings)；新总数 **16 Codable + 7 非 Codable = 23 M0.3 类型**；inventory 表 + 验收 grep 全部改 16/7/23（v5 R4 抓出 ledger iOS sign-off 还 stale "21"）
  - finding 2 (high) → v3 tag 验证用 `|| echo` 静默吞失败；改为三层 blocking gate（v5 R4 抓出 layer 3 SHA 比较用错 + layer 2 ruleset filter 不精确 + push 在 check 之前）
  - finding 3 (medium) → ledger residual 表加 H6 行（backend deps Wave 1 内 `requirements.txt == 精确锁定`）
- **v5**（2026-05-17）：codex R4 3 high findings 全修
  - finding 1 (high) → tag layer 3 检查用错命令：`git ls-remote --tags` 对 annotated tag 返回 tag object SHA + 可能 peeled `^{}` 行；改为 `git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}"` 提取 peeled target commit SHA；本地用 `git rev-parse wave0-frozen-v1.4^{}` 对齐预期 squash commit
  - finding 2 (high) → protected tag ruleset 检查 (a) 顺序错（push 在检查前），应改为 `git push` 前置 protected check（fail 早于 push remote）；(b) filter 不精确，应过滤 `target == "tag"` AND `ref_name_pattern` 含 `wave0-frozen-*` AND ruleset 处于 `enforcement == "active"` AND `rules` 含 `tag_name_pattern` 类型 OR `update`/`deletion` restriction；任意条件不满足 exit 1
  - finding 3 (high) → ledger iOS sign-off 还 stale "21 个类型 inventory"，改为 "23 个类型"；数据代表第 3 bullet "3-5 个样本训练组数据生成路径在 Wave 1 落地" 是 future scope 不能签 ✅ → 改为 blocking residual H7 (Wave 1 B1/B2 PR 内验证) 移到 residual 表

---

## 1. 目标

把 Wave 0 17 业务模块（PR #37 - #53 全 merged）+ M0 契约层 + 第三方依赖版本**正式签字冻结**。打 `wave0-frozen-v1.4` tag。冻结后契约层进入"修改难"模式（变更走 RFC + 三方 ledger）。Wave 1 才能开工。

## 2. Scope（7 项 / ~225 行 prod / 单 PR）

| # | 子项 | 类型 | LOC 估 | 验证 |
|---|---|---|---|---|
| 1 | Spec §6 C1b 闸门 #4 F3 修订（L1167 移 Wave 1） | spec md | ~10 | grep diff |
| 2 | Spec §F1 wording 改 + §M0.3 multi-file inventory 表 | spec md | ~40 | grep diff + table 检 21 类型 |
| 3 | Catalyst CI job (`.github/workflows/swift-contracts-smoke.yml` 第二 job) | CI yaml | ~50 | yaml parse + 本地 act 试跑 OR 信 CI |
| 4 | §15.4 三方签字 ledger（单人简化 doc） | governance md | ~80 | 文件存在 + 三角色 ✅ |
| 5 | README v1.4 + 签字时间 + 依赖版本表 | README md | ~30 | grep 10 依赖 |
| 6 | `wave0-frozen-v1.4` tag（merge 后动作） | git command | 0 | `git tag -l` + remote |
| 7 | §15.3 评审策略写进 Wave 1 plan 模板 | governance md | ~15 | 文件存在 + ≥3 策略 |

**总 prod 增量 ≈ 225 行**（≤500 packaging 硬规则 OK）。**子项数 7**（超 ≤3 — 治理 PR 例外，但 codex review 必审；先标注 risk）。

## 3. Trust-boundary 触点

| 文件路径 | 守卫 | 处理 |
|---|---|---|
| `.github/workflows/swift-contracts-smoke.yml` | codeowners + codex:adversarial-review CI gate | 子项 3，必走 codex review |
| `kline_trainer_modules_v1.4.md` | governance source-of-truth | 子项 1+2，必走 codex review |
| `CLAUDE.md` 或 `docs/governance/wave1-plan-template.md` | governance | 子项 7，必走 codex review |

## 4. Dep 顺序约束

```
Task 0 worktree + baseline
    ↓
Task 1 spec amendments (子项 1+2 合并 commit)
    ↓
Task 2 Catalyst CI job (子项 3)
    ↓
Task 3 governance docs (子项 4 ledger + 子项 7 plan 模板)
    ↓
Task 4 README v1.4 (子项 5；引用 spec final wording + ledger 路径)
    ↓
Task 5 acceptance + final verification
    ↓
PR 9 merge to main
    ↓
Task 6 git tag wave0-frozen-v1.4 origin/main + push (子项 6)
```

- 1+2 spec amendments **必须先 merge**（README v1.4 引用要 final wording）
- 3 CI job **可并行** 1+2（独立 yaml）
- 4+5 ledger + README **依赖** 1+2+3 全 ready
- 6 tag **最后** + 在 PR 9 **merge 之后**单独动作（不在 PR 9 commits）

## 5. 子项详细设计

### 5.1 Spec §6 C1b 闸门 #4 F3 修订（L1167 移 Wave 1）

**Anchor**：`kline_trainer_modules_v1.4.md` L1167

**修改前**：
> **Deceleration stop 契约测试**（闸门 #4 F3 新增）：`panEnded(velocity:) → .startDeceleration(v)` effect handler 启动 animator；后续 activateDrawing → `.requestDrawingSnapshotAfterStoppingAnimator` effect；验证 handler 必须**先**调用 `animator.stop()` 再计算 range（集成测试：模拟延迟 animator 回调，验证 drawing 退出后无 `offsetApplied` 到达 reducer）

**修改后**：
> **Deceleration stop 契约测试**（闸门 #4 F3 修订 v1.4 — **Wave 0 仅 reducer 契约测试；production handler 集成测试移 Wave 1**）：
>
> - **Wave 0 验收**（PR #50 已落）：reducer 派发 `panEnded(velocity:) → .startDeceleration(v)` effect + `activateDrawing → .requestDrawingSnapshotAfterStoppingAnimator` effect 的契约测试（13 个测试覆盖 happy + cross-session）
> - **Wave 1 验收**（C2 DecelerationAnimator + C8 ChartContainerView 落地时同 PR 内）：production handler 集成测试 — 模拟延迟 animator 回调，验证 handler 必须**先**调用 `animator.stop()` 再计算 range；drawing 退出后无 `offsetApplied` 到达 reducer
>
> **理由**：production handler 涉及 C2/C8/E5 三模块 orchestration，非 Wave 0 单模块 scope；reducer 契约测试已覆盖契约面，handler 集成测试在生产代码落地的同 PR 验证更准。

### 5.2 Spec §F1 wording 改 + §M0.3 multi-file inventory 表

#### 5.2.1 §F1 wording 修订

**Anchor**：`kline_trainer_modules_v1.4.md` L811-815

**修改前**：
```
### F1 数据模型模块 `Models/`

- **职责**：承载 M0.3 所有类型（含 `Equatable / Codable / CodingKeys`）
```

**修改后**：
```
### F1 数据模型模块 `Models/`

- **职责**：承载 M0.3 **核心** 数据类型（`Models.swift` 内 9 enum + 7 struct = 11 Codable 实体 + 5 非 Codable 类型）；**不含**跨文件 split 的 `AppState.swift` / `RESTDTOs.swift` 中的 M0.3 类型（见 §M0.3 inventory 表）。
```

#### 5.2.2 §M0.3 加 multi-file inventory 表

**Anchor**：`kline_trainer_modules_v1.4.md` 在 §M0.3 enum/struct 定义末尾（约 L470 附近）追加：

```
**M0.3 类型 inventory（v1.4 freeze；codex R3 finding 1 修：v3 漏 AppState 2 个非 Codable struct）**：

| 文件 | 类型 | Codable | 用途 |
|---|---|---|---|
| Models.swift | 9 enum: Period / TradeDirection / PositionTier / TrainingMode / DrawingToolType / DisplayMode / PanelId / SwipeDirection / PeriodDirection | 5/9 (Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode 是 Codable) | 核心枚举 |
| Models.swift | 7 struct: KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject / TradeMarker | 6/7 (TradeMarker NOT Codable — UI overlay 运行期专用) | 核心数据 |
| AppState.swift | 5 struct: TrainingRecord / DrawdownAccumulator / PendingTraining / TrainingSetFile / AppSettings | 3/5 (TrainingRecord / DrawdownAccumulator / PendingTraining 是 Codable；TrainingSetFile / AppSettings 非 Codable — UI/cache state 运行期专用) | 状态/持仓累计/UI 配置 |
| RESTDTOs.swift | 2 struct: LeaseResponse / TrainingSetMetaItem | 2/2 | REST 边界 DTO |

**合计 16 Codable（5 enum + 11 struct）+ 7 非 Codable（4 enum + 3 struct: TradeMarker / TrainingSetFile / AppSettings）= 23 M0.3 类型。** F1 模块 scope 仅 `Models.swift` 11 Codable；`AppState.swift` 5 struct 与 `RESTDTOs.swift` 2 struct 分别归 §C1b reducer / §B3 REST API 模块责任。
```

### 5.3 Catalyst CI job

**Anchor**：`.github/workflows/swift-contracts-smoke.yml`

在现有 `swift-test` job 之后追加：

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

**理由**：PR #51 R7 finding G3 标记"reviewer 仅信本地 log 不可持续，governance 必须升级"。此 job 在每个 PR 自动跑 Catalyst build-for-testing，确保 KLineView UIKit shell 编译永不退化。**Pattern 镜像现有 `swift-test` job**（codex Plan 1c R2 已确立 convention）：不硬编码 Xcode path / `xcodebuild -version` 断言 / fail-fast 诊断 / `actions/checkout` SHA pinned。

### 5.4 §15.4 三方签字 ledger（单人简化 doc）

**Anchor**：`docs/governance/2026-05-17-wave0-signoff-ledger.md`（新建）

内容：

```markdown
# Wave 0 契约冻结签字 ledger（v1.4）

单人项目简化版：项目所有者 (@agateuu1234-bit) 兼任 iOS / 后端 / 数据三方代表，按 §15.4 ledger 形式记录三角色 review 过的范围。非真三方会议；ledger 形式留痕。

## 后端代表 sign-off（自签）
- [x] M0.1 DDL（PostgreSQL schema + 训练组 sqlite + AppDB）与 PR #23 / #29 一致
- [x] M0.2 OpenAPI 与 PR #24 三接口 schema 一致；lease 状态机 + CRC32 已落地
- [x] B1-B4 实现在 Wave 1 backlog；OpenAPI 与 backend 契约对齐
- **签字时间**：2026-05-17

## iOS 代表 sign-off（自签）
- [x] M0.3 数据模型：**23 个类型** inventory（16 Codable + 7 非 Codable，见 §M0.3 表）全 Equatable / 关键 Codable round-trip 闭环（codex R4 finding 3 修：v4 stale "21"）
- [x] M0.4 AppError + Reason 枚举 Error conformance（PR #26 / #27）
- [x] M0.5 并发契约 doc（PR #52）
- [x] F1 Models 薄 wrapper（PR #53）含 BinarySearch utility
- [x] F2 Theme（PR #39）13 默认色
- [x] C1a Geometry / C1b Reducer / C1c Render UIKit shell（PR #38 / #47 / #48 / #49 / #50 / #51）
- [x] §15.1 编译验证 #1-#9 全闭环：本地 swift test + Catalyst build SUCCEEDED + CI 持续守护（PR 9 加 job 子项 3）
- [x] Preview Fixture 可在 Xcode Canvas 渲染（E6 PR #40 提供）
- **签字时间**：2026-05-17

## 数据代表 sign-off（自签）
- [x] B1 CSV 导入字段覆盖在 OpenAPI 与 spec §B1 一致（**契约层** sign-off — backend 实现 Wave 1）
- [x] B2 训练组生成策略（月线前 30 / 后 8 根月窗口）记录在 spec §B2（**契约层** sign-off）
- ⚠️ **未签**（codex R4 finding 3 修：future scope 不能签 ✅）：3-5 个样本训练组数据落地 → 移入 **residual H7**（Wave 1 B1/B2 PR 内验证 3-5 个样本数据正确性 + ledger 回填）
- **签字时间**：2026-05-17

## 已知 residuals（不阻塞 freeze）

| residual | 来源 | 处理路径 |
|---|---|---|
| L1167 production handler 集成测试 | PR #50 plan-residual | Spec §6 C1b 闸门 #4 F3 v1.4 修订移 Wave 1（PR 9 子项 1） |
| E2 PositionManager 三连 abort | PR #36 closed | Wave 1 启动前 spec §4.2 重审窗口 |
| Wave 1 内部 plan 排序 | v6 outline 仅 Wave 0 | PR 9 merge 后 brainstorming + writing-plans 排细顺位 |
| M0.3 multi-file split 历史 over-claim | PR F1 R7+R8 | Spec §F1 wording + §M0.3 inventory 表（PR 9 子项 2） |
| Catalyst CI 持续守护 | PR #51 R7 G3 | `.github/workflows` Catalyst job（PR 9 子项 3） |
| **H6 backend deps exact pin**（codex R3 finding 3 修） | spec §15.2 deps freeze 暂用 ranges (FastAPI/Uvicorn/APScheduler/pandas/pandas-ta/asyncpg/PostgreSQL) | Wave 1 B1-B4 PR 各自落 `backend/requirements.txt == X.Y.Z` 精确版本 + `docker-compose.yml` image digest pin |
| **H7 sample 训练组数据**（codex R4 finding 3 修） | 数据代表 sign-off 第 3 项 future scope，不能签 ✅ | Wave 1 B1/B2 PR 内 backend 实现后真生成 3-5 个样本训练组 + 数据正确性 ledger 回填 |

## 依赖版本锁定（§15.2 v1.4 freeze）

见 README v1.4 + `ios/Contracts/Package.resolved`。

签字完成后：契约层进入 RFC 修改模式；任何 M0.* / F1 / F2 / C1a / C1b / C1c / E1 / E6 / P3 / P4 / P5 / P6 改动需 RFC 走 superpowers:brainstorming + ledger 留痕。

## Provenance（codex R1 finding 1 + R2 finding 3 + R3 finding 2 修订）

本 ledger **不内嵌 PR 9 squash commit SHA**；provenance 走三件互证 + tag 三层 blocking 验证：

1. **annotated tag** (`git show wave0-frozen-v1.4`) — 显示 tagger / date / target commit SHA / message
2. **GitHub protected tag namespace（mandatory）** — `wave0-frozen-*` 配 admin-only push + 禁 force-update；tag 创建脚本 `gh api rulesets` 命中检查 fail → `exit 1`（codex R3 finding 2 修，不用 `|| echo` 静默）
3. **本 ledger + README v1.4** — 三处文本签字记录互证；任意一处篡改可 `git diff` 出来

完整 tag 验证脚本见 §5.6（含三层 blocking gate：signed verify / protected namespace / remote SHA 对齐，任意一层 fail exit 1）。

**注意**：annotated tag (`-a`) 自身的 tagger 字段是 arbitrary metadata，不是 cryptographic proof。signed tag (`-s`，依赖 GPG/SSH key) 才提供加密保证；单人项目实操中 GitHub protected tag namespace + admin-only push = remote ref 不可篡改的等价防线。**Wave 0 freeze 接受 unsigned tag 作为最低门槛**，但 protected tag namespace mandatory；signed tag 是 nice-to-have（user 配 signing key 后 v1 起即默认走）。
```

### 5.5 README v1.4 + 依赖版本表

**Anchor**：`README.md`（追加章节）

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

Wave 0 freeze **仅 iOS deps exact pin**；backend ranges 待 Wave 1 B1-B4 PR 各自落 `requirements.txt == X.Y.Z` 时同步锁定（residual H6 in `docs/governance/...-wave0-signoff-ledger.md`）。

### Wave 0 交付清单

17 业务模块（PR #37 - #53）+ M0 契约 + F1/F2 基础 + C1a/C1b/C1c 图表核心 → 见 sign-off ledger。
```

### 5.6 git tag wave0-frozen-v1.4（merge 后动作）

PR 9 **merge 之后**单独动作（不在 PR 9 commits 里，避免 tag 指向未 merge commit）。

**前置（codex R2 finding 3 修）**：在 GitHub repo settings 配置 `wave0-frozen-*` **protected tag namespace**（admin-only push + 禁止 force-update），否则 unsigned annotated tag 的 ref 可被任意 retarget。

**Tag 创建 + blocking 三层验证（codex R3 finding 2 + R4 3 findings 修订；顺序：protected check → push → verify）：**

```bash
set -euo pipefail
git fetch origin main
TAG_COMMIT=$(git rev-parse origin/main)
echo "Expected target squash commit: $TAG_COMMIT"

# ===== 层 1 (前置)：GitHub protected tag namespace 必须配 + pattern 命中 + active =====
# 在 git push 之前 fail，避免 unsigned + unprotected tag 已 remote 才发现 misconfig
RULESET_JSON=$(gh api "repos/agateuu1234-bit/kline-trainer/rulesets" 2>&1)
MATCH=$(printf '%s' "$RULESET_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
ok = False
for r in data:
    if r.get('target') != 'tag':
        continue
    # 取详细 ruleset
    pass
# rulesets list 不带条件，需要逐个 fetch 详情；先 dump ID 列表
print(','.join(str(r['id']) for r in data if r.get('target') == 'tag'))
")
if [ -z "$MATCH" ]; then
  echo "FAIL: 无任何 target=tag 的 ruleset；GitHub repo Settings → Rules → New tag ruleset 必配"
  echo "  required: ref_name_pattern 含 'wave0-frozen-*' / enforcement=active / rules 含 update + deletion restriction / 限 admin bypass"
  exit 1
fi
# 逐个 ID 拉详情，验证 (active 状态 + wave0-frozen-* pattern + update/deletion 限制)
PROTECTED_OK=0
for RID in $(echo "$MATCH" | tr ',' ' '); do
  DETAIL=$(gh api "repos/agateuu1234-bit/kline-trainer/rulesets/$RID")
  HIT=$(printf '%s' "$DETAIL" | python3 -c "
import json, sys
r = json.load(sys.stdin)
if r.get('enforcement') != 'active':
    sys.exit(1)
conds = r.get('conditions', {}) or {}
ref = conds.get('ref_name', {}) or {}
patterns = (ref.get('include') or []) + (ref.get('exclude') and [] or [])
if not any('wave0-frozen' in p for p in patterns):
    sys.exit(1)
rules = r.get('rules', []) or []
types = [x.get('type') for x in rules]
need = {'update', 'deletion'}
if not need.issubset(set(types)):
    sys.exit(1)
print('OK')
" 2>/dev/null || true)
  if [ "$HIT" = "OK" ]; then PROTECTED_OK=1; break; fi
done
if [ "$PROTECTED_OK" != "1" ]; then
  echo "FAIL: protected tag ruleset 检查不命中；要求 active + ref_name include 'wave0-frozen-*' + rules 含 update + deletion"
  exit 1
fi
echo "Layer 1 OK: protected tag namespace 已配置且 active"

# ===== 创建 tag（优先 signed，fallback unsigned） =====
if git tag -s wave0-frozen-v1.4 \
    -m "Wave 0 契约冻结 v1.4：17 业务模块 + M0 契约 + §15.4 三方签字 ledger / docs/governance/2026-05-17-wave0-signoff-ledger.md" \
    "$TAG_COMMIT" 2>/dev/null; then
  TAG_SIGNED=1
else
  echo "WARN: GPG/SSH signing 未配，fallback 到 unsigned annotated tag"
  git tag -a wave0-frozen-v1.4 \
    -m "Wave 0 契约冻结 v1.4：17 业务模块 + M0 契约 + §15.4 三方签字 ledger / docs/governance/2026-05-17-wave0-signoff-ledger.md" \
    "$TAG_COMMIT"
  TAG_SIGNED=0
fi

# ===== Push 到 remote（protected ruleset 已确认配） =====
git push origin wave0-frozen-v1.4

# ===== 层 2：signed tag 验证（若 signed） =====
if [ "$TAG_SIGNED" = "1" ]; then
  git verify-tag wave0-frozen-v1.4 || { echo "FAIL: signed tag 验签失败"; exit 1; }
  echo "Layer 2 OK: signed tag 验签通过"
else
  echo "Layer 2 SKIP: unsigned tag；layer 1 protected ruleset 已防 retarget"
fi

# ===== 层 3：remote peeled target commit SHA == 本地预期 squash commit =====
# annotated tag 在 ls-remote 输出 2 行：tag object SHA + peeled commit SHA (^{} 行)
# 用 refs/tags/<name>^{} 显式取 peeled commit
REMOTE_PEELED=$(git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}" | awk '{print $1}')
if [ -z "$REMOTE_PEELED" ]; then
  echo "FAIL: remote tag peeled SHA 拿不到（tag 可能未 push 成功）"
  exit 1
fi
if [ "$REMOTE_PEELED" != "$TAG_COMMIT" ]; then
  echo "FAIL: remote tag peeled 指向 $REMOTE_PEELED，与预期 squash commit $TAG_COMMIT 不符"
  exit 1
fi
# 本地反查双 check
LOCAL_PEELED=$(git rev-parse "wave0-frozen-v1.4^{}")
if [ "$LOCAL_PEELED" != "$TAG_COMMIT" ]; then
  echo "FAIL: 本地 tag peeled $LOCAL_PEELED ≠ 预期 $TAG_COMMIT"
  exit 1
fi
echo "Layer 3 OK: remote+local peeled SHA == 预期 squash commit"

echo "GATE PASS: tag wave0-frozen-v1.4 三层验证全过（layer 1 protected ruleset / layer 2 signed=$TAG_SIGNED / layer 3 peeled SHA 对齐）"
```

**注意**（codex R2 finding 3 wording 修订）：
- annotated tag (`-a`) 自身**不是 cryptographic provenance**（tagger 字段 arbitrary）；签名 tag (`-s`) 才提供加密保证
- 单人项目 threat model：账号 / 仓库主控权 = 终极信任根；GitHub protected tag namespace（admin-only push + force-update 禁止）= remote ref 不可篡改的实操等价物
- README v1.4 + ledger 文本 + tag 三件互证：任意一处被改动都能 `git diff` 出来

### 5.7 §15.3 评审策略写进 Wave 1 plan 模板

**Anchor**：`docs/governance/wave1-plan-template.md`（新建）

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

## 6. 验证 / 验收清单

按 spec §15.4 + project memory 规则，PR 9 acceptance doc 含中文非-coder 验收清单。**示意（细节由 writing-plans 落地）**：

- **A 文件落地**：spec md / CI yaml / governance md / README md 全到位
- **B 编译验证**：现有 swift test 297/63 不退化 + Catalyst build SUCCEEDED
- **C Spec 一致性**：grep 子项 1+2 修订后 §6 C1b L1167 含 "Wave 1 验收" + §F1 含 "11 Codable 实体" + §M0.3 含 "16 Codable" + "7 非 Codable" + "23 M0.3 类型"（codex R3 finding 1 修：v3 漏 AppState TrainingSetFile/AppSettings；v1/v2 误写 14+7）
- **D §15.4 ledger**：三方 ✅ + 5 residuals；ledger 内**不含**任何未填占位符（codex R1 finding 1 修：provenance 走 annotated tag，不在 ledger 嵌 SHA）
- **E CI**：6/6 → 7/7 SUCCESS（多 Catalyst job）
- **F tag**：merge 后跑 tag 三层 blocking 验证（codex R3 finding 2 修：不用 `|| echo`）— 层 1 signed tag verify（若 signed）+ 层 2 GitHub protected tag ruleset 命中 `wave0-frozen-*`（mandatory） + 层 3 `git ls-remote --tags origin wave0-frozen-v1.4` 指向 commit SHA == 本地预期 squash commit；任意一层失败 `exit 1`

## 7. 流水线（按 user 指定）

```
1. ✅ superpowers:brainstorming (本文)
2. superpowers:writing-plans → docs/superpowers/plans/2026-05-17-pr9-wave0-freeze.md
3. codex:adversarial-review plan-stage → 5 轮预算内收敛（按 memory feedback_codex_plan_budget_overshoot）
4. superpowers:subagent-driven-development 5 Task × sonnet 4.6 + per-task spec + quality review
5. superpowers:verification-before-completion
6. superpowers:requesting-code-review (final branch)
7. codex:adversarial-review impl-stage → 收敛
8. git push + gh pr create (中文 body) + 7/7 CI + admin squash merge
9. PR 9 merge 后单独跑 git tag wave0-frozen-v1.4 + push origin tag
```

## 8. 风险 / 已知 residuals（PR 9 自身）

| risk | 缓解 |
|---|---|
| 7 子项 > ≤3 packaging 硬规则 | 治理类 PR 例外；codex review 必审 — 接受 risk |
| Catalyst CI job 在 CI 首次跑可能失败（toolchain / Xcode 版本） | 镜像 swift-test job 已有 codex Plan 1c R2 修订 pattern：`xcodebuild -version` 断言 + fail-fast 诊断（含 `ls /Applications` 列出可用 Xcode）；不硬编码路径。若 quota fail 走 memory `feedback_openai_quota_ci_pattern` admin bypass |
| spec §F1 wording 修订与历史 PR #53 plan v9 H3 residual 表面冲突 | PR #53 H3 residual 显式说"留 PR 9 governance 阶段澄清"，此 PR 9 子项 2 = 兑现承诺，不矛盾 |
| §15.4 ledger 单人三角色 self-sign 看起来薄 | spec §15.4 原文支持 ledger 形式留痕；单人项目 doc-化即等价三方会议 |
| tag 指向 squash commit 不指向 author commit | git tag -a 是标准做法；annotated tag 承担 immutable provenance；ledger 内不含 SHA 占位符（codex R1 finding 1 修订） |

## 9. 完成后状态

- Wave 0 正式冻结，契约层进入 RFC 模式
- Wave 1 可启动（B1-B4 + C2/C7/C3-C6 真实现 + E2-E4 + P1 + U3-U6）
- 下个 brainstorming 会话题：Wave 1 内部 plan 顺位排序（类比 v6 outline）

---

**End of design.**
