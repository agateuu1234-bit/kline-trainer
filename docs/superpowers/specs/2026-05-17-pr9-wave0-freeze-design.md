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
  - finding 1 (high) → tag layer 3 检查用错命令；改为 `refs/tags/wave0-frozen-v1.4^{}` peeled target commit SHA（v6 R5 抓出 TAG_COMMIT 自 origin/main 派生不验 PR 9 squash 真相）
  - finding 2 (high) → protected tag ruleset 检查顺序错 + filter 不精确（v6 R5 抓出 exclude/creation/bypass 也要验）
  - finding 3 (high) → ledger iOS sign-off stale "21"→"23"；数据代表样本数据移 H7 residual
- **v6**（2026-05-17）：codex R5 3 fresh findings 全修（user explicit 选项 A，超 5 轮预算）
  - finding 1 (high) → TAG_COMMIT 自 origin/main 派生不验 PR 9 squash 真相；前置 0 `gh pr view 9 --json mergeCommit`（v7 R6 抓出 push 在 verify 前）
  - finding 2 (high) → protected ruleset 完整谓词描述（v7 R6 sanity）
  - finding 3 (medium) → §6.F mirror §5.6 peeled
- **v7**（2026-05-17）：codex R6 3 fresh findings 全修；user TTY override 锁定停 codex spec review
  - finding 1 (high) → tag push 在 verify 前 → 本地 verify → push 顺序
  - finding 2 (medium) → §6.D 5 → 7 residuals
  - finding 3 (medium) → §2 scope 21 → 23 类型
- **v8**（2026-05-17）：plan-stage codex R4 抓到 spec 自身 bug 反向修订（2 处）
  - spec §5.6 前置 0 `PR_NUMBER=9` → 改 auto-detect
  - spec §5.6 layer 1 `--layer protected-namespace` 参数 → 删（script 不接受）
- **v9**（2026-05-17）：plan-stage codex R5 反向抓 spec §6 漏修 + Catalyst CI 非 required gate
  - spec §6.F 还有 `gh pr view 9 --json mergeCommit` 硬码（v8 §5.6 修了 §6 漏修）→ §6.F 改用 §5.6 同 auto-detect flow
  - **新 residual H8**: Catalyst CI 加 workflow 不等于 required merge gate；spec §6 加 "branch protection settings 必须把 `catalyst-build` 加为 required status check" 注解 + ledger 加 H8 residual（admin 在 PR 9 merge 后 GitHub UI 配置）

---

## 1. 目标

把 Wave 0 17 业务模块（PR #37 - #53 全 merged）+ M0 契约层 + 第三方依赖版本**正式签字冻结**。打 `wave0-frozen-v1.4` tag。冻结后契约层进入"修改难"模式（变更走 RFC + 三方 ledger）。Wave 1 才能开工。

## 2. Scope（7 项 / ~225 行 prod / 单 PR）

| # | 子项 | 类型 | LOC 估 | 验证 |
|---|---|---|---|---|
| 1 | Spec §6 C1b 闸门 #4 F3 修订（L1167 移 Wave 1） | spec md | ~10 | grep diff |
| 2 | Spec §F1 wording 改 + §M0.3 multi-file inventory 表 | spec md | ~40 | grep diff + table 检 **23 类型 (16 Codable + 7 non-Codable)**（codex R6 finding 3 修：v1-v6 stale "21"） |
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

**Tag 创建 + blocking 三层验证（codex R3-R5 累积修订；script spec 描述要求，实际 python 评估脚本 impl 阶段落 `scripts/governance/verify-freeze-tag.sh`）：**

**前置 0：从 GitHub auto-detect 真实 PR number + squash commit SHA**（codex R5 finding 1 修：不能自 origin/main 派生；v8 plan R4 修：`PR_NUMBER` 不硬码 9）

```bash
set -euo pipefail
BRANCH="pr9-wave0-freeze"
# v8: PR_NUMBER auto-detect (codex plan R4 修：'PR 9' 是项目内部命名；actual GitHub PR # 由 gh pr create 分配，可能 #54+)
PR_NUMBER=$(gh pr list --repo agateuu1234-bit/kline-trainer --head "$BRANCH" --state merged --json number --jq '.[0].number')
if [ -z "$PR_NUMBER" ] || [ "$PR_NUMBER" = "null" ]; then
  echo "FAIL: 找不到 branch $BRANCH 的已 merge PR"
  exit 1
fi
echo "Detected actual GitHub PR #$PR_NUMBER"

EXPECTED_SHA=$(gh pr view "$PR_NUMBER" --repo agateuu1234-bit/kline-trainer --json mergeCommit --jq '.mergeCommit.oid')
if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" = "null" ]; then
  echo "FAIL: PR #$PR_NUMBER 未 merge，无 mergeCommit SHA"
  exit 1
fi
echo "Expected PR #$PR_NUMBER squash commit: $EXPECTED_SHA"

git fetch origin main
LOCAL_MAIN=$(git rev-parse origin/main)
if [ "$LOCAL_MAIN" != "$EXPECTED_SHA" ]; then
  echo "FAIL: origin/main HEAD ($LOCAL_MAIN) ≠ PR #$PR_NUMBER squash SHA ($EXPECTED_SHA)"
  echo "  可能 PR merge 后又有新 commit 进 main；不能直接 tag，需重新评估"
  exit 1
fi
TAG_COMMIT="$EXPECTED_SHA"
```

**层 1 (前置)：GitHub protected tag namespace 完整谓词检查**（codex R5 finding 2 修；实际脚本 impl 阶段 `scripts/governance/verify-freeze-tag.sh`，本 spec 列必检谓词）

逐个 `target=="tag"` ruleset 拉详情后 evaluate：
1. **`enforcement` == `active`**（不是 evaluate / disabled）
2. **target ref `refs/tags/wave0-frozen-v1.4` 命中**：fnmatch 评估 `conditions.ref_name.include` 数组的至少一个 pattern AND 不命中 `conditions.ref_name.exclude` 任何 pattern；含 `~ALL` token 视为命中
3. **`rules` 数组含三类**：`creation` + `update` + `deletion`（缺 creation 就允许新建 retarget；缺 update 就允许 force push；缺 deletion 就允许删除）
4. **`bypass_actors` 限 admin-only**：仅允许 RepositoryRole=admin 或 OrganizationAdmin；任何 non-admin bypass actor → fail

任意条件不满足 exit 1，输出具体 diagnostic。脚本骨架（具体 python 评估 impl 阶段实现）：

```bash
# impl 阶段：scripts/governance/verify-freeze-tag.sh --ref refs/tags/wave0-frozen-v1.4
# 本 spec 仅描述行为契约（v8 plan R4 修：删除不存在的 --layer 参数；script 单一职责 = protected ruleset 检查）
./scripts/governance/verify-freeze-tag.sh --ref "refs/tags/wave0-frozen-v1.4" || exit 1
echo "Layer 1 OK: protected tag namespace 完整谓词检查通过"
```

**Tag 创建（优先 signed，fallback unsigned；codex R6 finding 1 修：顺序 创建 → 本地 verify → 本地 peeled check → push → remote peeled check）：**

```bash
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
```

**层 2 (push 前本地 verify)：signed tag 验证（若 signed）**

```bash
if [ "$TAG_SIGNED" = "1" ]; then
  git verify-tag wave0-frozen-v1.4 || { echo "FAIL: signed tag 验签失败（push 前本地拦截）"; git tag -d wave0-frozen-v1.4; exit 1; }
  echo "Layer 2 OK: signed tag 本地验签通过"
else
  echo "Layer 2 SKIP: unsigned tag；layer 1 protected ruleset 已防 retarget"
fi

# 本地 peeled SHA 预检（push 前确认 tag 指向预期）
LOCAL_PEELED=$(git rev-parse "wave0-frozen-v1.4^{}")
if [ "$LOCAL_PEELED" != "$EXPECTED_SHA" ]; then
  echo "FAIL: 本地 tag peeled $LOCAL_PEELED ≠ PR 9 squash SHA $EXPECTED_SHA（push 前本地拦截）"
  git tag -d wave0-frozen-v1.4
  exit 1
fi
echo "Layer 2 pre-push 本地 peeled SHA OK"

# 本地全部验证通过后才 push
git push origin wave0-frozen-v1.4
```

**层 3：remote peeled target commit SHA == 预期 squash SHA**（codex R4 finding 1 + R5 finding 1 修：用 `^{}` peeled + 与 EXPECTED_SHA 对齐）

```bash
REMOTE_PEELED=$(git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}" | awk '{print $1}')
if [ -z "$REMOTE_PEELED" ]; then
  echo "FAIL: remote tag peeled SHA 拿不到（tag 可能未 push 成功 — 但本地已删可恢复）"
  exit 1
fi
if [ "$REMOTE_PEELED" != "$EXPECTED_SHA" ]; then
  echo "FAIL: remote tag peeled 指向 $REMOTE_PEELED，与 PR #$PR_NUMBER squash SHA $EXPECTED_SHA 不符"
  exit 1
fi
echo "Layer 3 OK: remote peeled SHA == PR #$PR_NUMBER squash（本地 push 前已 pre-check 通过，layer 2 内）"

echo "GATE PASS: tag wave0-frozen-v1.4 三层验证全过（layer 1 protected ruleset 完整谓词 / layer 2 本地 signed=$TAG_SIGNED + peeled SHA pre-check / layer 3 remote peeled SHA 对齐 PR squash）"
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
- **D §15.4 ledger**：三方 ✅ + **7 residuals**（H1 L1167 / H2 E2 / H3 Wave 1 plan / H4 M0.3 multi-file / H5 Catalyst CI / H6 backend deps / H7 sample 训练组数据；codex R6 finding 2 修：v1-v6 stale "5 residuals"）；ledger 内**不含**任何未填占位符（codex R1 finding 1 修：provenance 走 annotated tag，不在 ledger 嵌 SHA）
- **E CI**：6/6 → 7/7 SUCCESS（多 Catalyst job）
- **F tag**：merge 后**完全 mirror §5.6 三层 blocking gate**（v9 plan R5 修：§6.F 不再硬码 `gh pr view 9`）— 前置 0：`gh pr list --head pr9-wave0-freeze --state merged --json number` auto-detect 真实 PR # → `gh pr view "$PR_NUMBER" --json mergeCommit` 拿 squash SHA；层 1：`scripts/governance/verify-freeze-tag.sh --ref refs/tags/wave0-frozen-v1.4`；层 2：`git verify-tag`（若 signed） + 本地 peeled SHA pre-check；层 3：`git ls-remote origin "refs/tags/wave0-frozen-v1.4^{}"` peeled commit SHA == auto-detected PR squash SHA。任意一层 `exit 1`
- **G branch protection enforcement (H8 residual; v9 plan R5 finding 1 修)**：PR 9 merge 后 admin 必须在 GitHub repo Settings → Branches → main 加 `catalyst-build` 为 required status check；否则 Catalyst CI 沦为 advisory，未来 PR 红 Catalyst 仍可 merge，违反 "continuous guard" 承诺。Ledger H5 (Catalyst CI 持续守护) 完全闭合需 H8 配套完成。

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
