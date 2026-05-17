# PR 9 — Wave 0 契约冻结 ceremony 设计

**作者**：@agateuu1234-bit (Claude Opus 4.7 协助)
**日期**：2026-05-17
**Wave**：Wave 0 closing ceremony（在 v6 outline 17 顺位之后）
**类型**：Governance（trust-boundary，含 CI workflow + spec amendment + git tag）

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
**M0.3 类型 inventory（v1.4 freeze）**：

| 文件 | 类型 | Codable | 用途 |
|---|---|---|---|
| Models.swift | 9 enum: Period / TradeDirection / PositionTier / TrainingMode / DrawingToolType / DisplayMode / PanelId / SwipeDirection / PeriodDirection | 5/9 (Period / TradeDirection / PositionTier / DrawingToolType / DisplayMode 是 Codable) | 核心枚举 |
| Models.swift | 7 struct: KLineCandle / TrainingSetMeta / FeeSnapshot / TradeOperation / DrawingAnchor / DrawingObject / TradeMarker | 6/7 (TradeMarker NOT Codable — UI overlay 运行期专用) | 核心数据 |
| AppState.swift | 3 struct: TrainingRecord / DrawdownAccumulator / PendingTraining | 3/3 | 状态/持仓累计 |
| RESTDTOs.swift | 2 struct: LeaseResponse / TrainingSetMetaItem | 2/2 | REST 边界 DTO |

**合计 14 Codable + 7 非 Codable = 21 M0.3 类型。** F1 模块 scope 仅 `Models.swift` 11 Codable；`AppState.swift` 3 struct 与 `RESTDTOs.swift` 2 struct 分别归 §C1b reducer / §B3 REST API 模块责任。
```

### 5.3 Catalyst CI job

**Anchor**：`.github/workflows/swift-contracts-smoke.yml`

在现有 `swift-test` job 之后追加：

```yaml
  catalyst-build:
    name: Mac Catalyst build-for-testing on macos-15
    runs-on: macos-15
    needs: []  # 与 swift-test 并行
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app
      - name: Mac Catalyst build-for-testing
        run: |
          set -o pipefail
          cd ios/Contracts
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

**理由**：PR #51 R7 finding G3 标记"reviewer 仅信本地 log 不可持续，governance 必须升级"。此 job 在每个 PR 自动跑 Catalyst build-for-testing，确保 KLineView UIKit shell 编译永不退化。

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
- **签字时间**：2026-05-17（PR 9 merge 时确认）
- **commit**：(PR 9 squash commit SHA，PR merge 后填)

## iOS 代表 sign-off（自签）
- [x] M0.3 数据模型：21 个类型 inventory（见 §M0.3 表）全 Equatable / 关键 Codable round-trip 闭环
- [x] M0.4 AppError + Reason 枚举 Error conformance（PR #26 / #27）
- [x] M0.5 并发契约 doc（PR #52）
- [x] F1 Models 薄 wrapper（PR #53）含 BinarySearch utility
- [x] F2 Theme（PR #39）13 默认色
- [x] C1a Geometry / C1b Reducer / C1c Render UIKit shell（PR #38 / #47 / #48 / #49 / #50 / #51）
- [x] §15.1 编译验证 #1-#9 全闭环：本地 swift test + Catalyst build SUCCEEDED + CI 持续守护（PR 9 加 job 子项 3）
- [x] Preview Fixture 可在 Xcode Canvas 渲染（E6 PR #40 提供）
- **签字时间**：2026-05-17

## 数据代表 sign-off（自签）
- [x] B1 CSV 导入字段覆盖在 OpenAPI 与 spec §B1 一致
- [x] B2 训练组生成策略（月线前 30 / 后 8 根月窗口）记录在 spec §B2
- [x] 3-5 个样本训练组数据生成路径在 Wave 1 落地
- **签字时间**：2026-05-17

## 已知 residuals（不阻塞 freeze）

| residual | 来源 | 处理路径 |
|---|---|---|
| L1167 production handler 集成测试 | PR #50 plan-residual | Spec §6 C1b 闸门 #4 F3 v1.4 修订移 Wave 1（PR 9 子项 1） |
| E2 PositionManager 三连 abort | PR #36 closed | Wave 1 启动前 spec §4.2 重审窗口 |
| Wave 1 内部 plan 排序 | v6 outline 仅 Wave 0 | PR 9 merge 后 brainstorming + writing-plans 排细顺位 |
| M0.3 multi-file split 历史 over-claim | PR F1 R7+R8 | Spec §F1 wording + §M0.3 inventory 表（PR 9 子项 2） |
| Catalyst CI 持续守护 | PR #51 R7 G3 | `.github/workflows` Catalyst job（PR 9 子项 3） |

## 依赖版本锁定（§15.2 v1.4 freeze）

见 README v1.4 + `ios/Contracts/Package.resolved`。

签字完成后：契约层进入 RFC 修改模式；任何 M0.* / F1 / F2 / C1a / C1b / C1c / E1 / E6 / P3 / P4 / P5 / P6 改动需 RFC 走 superpowers:brainstorming + ledger 留痕。
```

### 5.5 README v1.4 + 依赖版本表

**Anchor**：`README.md`（追加章节）

```markdown
## Wave 0 契约冻结 v1.4（2026-05-17）

Wave 0 已签字冻结。tag：`wave0-frozen-v1.4`。Sign-off ledger：[docs/governance/2026-05-17-wave0-signoff-ledger.md](docs/governance/2026-05-17-wave0-signoff-ledger.md)。

### 依赖版本锁定（spec §15.2）

| 依赖 | 用途 | 版本 |
|---|---|---|
| GRDB.swift | iOS SQLite ORM | 6.29+（Package.resolved） |
| ZipFoundation | iOS zip 解压 | 0.9.20 |
| SQLite | iOS + 后端 | 3.45+（iOS 17 自带） |
| FastAPI | 后端 API | 0.110+ |
| Uvicorn | ASGI server | 0.27+ |
| APScheduler | 后端定时 | 3.10+ |
| pandas | 后端数据 | 2.x |
| pandas-ta | 指标计算 | 0.3.14b0+ |
| asyncpg | PG 驱动 | 0.29+ |
| PostgreSQL | 数据仓库 | 15+ |

**Wave 1 起不得修改**（除安全补丁 + ledger 留痕）。

### Wave 0 交付清单

17 业务模块（PR #37 - #53）+ M0 契约 + F1/F2 基础 + C1a/C1b/C1c 图表核心 → 见 sign-off ledger。
```

### 5.6 git tag wave0-frozen-v1.4（merge 后动作）

PR 9 **merge 之后**单独动作（不在 PR 9 commits 里，避免 tag 指向未 merge commit）：

```bash
git fetch origin main
TAG_COMMIT=$(git rev-parse origin/main)
git tag -a wave0-frozen-v1.4 \
  -m "Wave 0 契约冻结 v1.4：17 业务模块 + M0 契约 + §15.4 三方签字 ledger / docs/governance/2026-05-17-wave0-signoff-ledger.md" \
  "$TAG_COMMIT"
git push origin wave0-frozen-v1.4

# 验证
git tag -l "wave0-frozen-*"
git show wave0-frozen-v1.4 --stat | head -5
```

`-a` 注释 tag（携带 message + commit + tagger info，不是 lightweight tag）。tag 指向 PR 9 squash merge commit。

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
- **C Spec 一致性**：grep 子项 1+2 修订后 §6 C1b L1167 含 "Wave 1 验收" + §F1 含 "11 Codable 实体" + §M0.3 含 "14 Codable + 7 非 Codable = 21"
- **D §15.4 ledger**：三方 ✅ + 5 residuals + commit SHA 占位
- **E CI**：6/6 → 7/7 SUCCESS（多 Catalyst job）
- **F tag**：merge 后 `git tag -l wave0-frozen-v1.4` 存在 + remote push 成功

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
| Catalyst CI job 在 CI 首次跑可能失败（toolchain / Xcode 版本） | 子项 3 单独 commit；CI fail → debug 单独 commit 修；若 quota fail 走 memory `feedback_openai_quota_ci_pattern` admin bypass |
| spec §F1 wording 修订与历史 PR #53 plan v9 H3 residual 表面冲突 | PR #53 H3 residual 显式说"留 PR 9 governance 阶段澄清"，此 PR 9 子项 2 = 兑现承诺，不矛盾 |
| §15.4 ledger 单人三角色 self-sign 看起来薄 | spec §15.4 原文支持 ledger 形式留痕；单人项目 doc-化即等价三方会议 |
| tag 指向 squash commit 不指向 author commit | git tag -a 是标准做法；后续 `git diff wave0-frozen-v1.4..HEAD` 能正确 diff |

## 9. 完成后状态

- Wave 0 正式冻结，契约层进入 RFC 模式
- Wave 1 可启动（B1-B4 + C2/C7/C3-C6 真实现 + E2-E4 + P1 + U3-U6）
- 下个 brainstorming 会话题：Wave 1 内部 plan 顺位排序（类比 v6 outline）

---

**End of design.**
