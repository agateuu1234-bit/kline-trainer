# 重置资金·真正归零（清空记录 + 重置 10 万）— 非-coder 验收清单

> **本交付性质**：功能修正。「重置资金」原实现只重置金额，训练记录不清空，与意图不符。本次在单一数据库事务内原子性地：删除全部训练记录（`training_sessions`）、未完成对局（`pending_sessions`），同时将总资金重置为 10 万元；取消操作则数据库不发生任何变更。SettingsPanel 确认文案同步更新以如实告知用户将清空训练记录。首次开局（冷启动 / 重置后开新局）的 `startingCapital` 始终从 SettingsStore 读取 `defaultTotalCapital`（10 万），消除归零前为 ¥0 的隐患。
>
> 验收判据 = **范围 gate + persistence 新测试（5 条含真事务回滚）+ AppContainer 重置后开局测试 + SettingsStore/SettingsPanelContent 新测试 + host 全量 1091 条 + Catalyst build + iOS app build + §5 模拟器 runbook（三场景，用户实测）+ Opus 4.8 xhigh 对抗性 review APPROVE 落账**。
>
> **如何用**：你（非编码者）逐条把「操作命令」粘进终端回车，把屏幕输出对照「预期输出」，吻合勾 ✅，不吻合勾 ❌。每条二元判定，无需读代码。
>
> **运行前置**（终端先进工作树根，含空格须带引号）：
> ```bash
> cd "/Users/maziming/Coding/Prj_Kline trainer"
> ```

---

## 第 1 条 · 范围 gate（改动文件白名单 fail-closed）

**目的**：确认本交付只动计划白名单文件，没有碰其它模块。

**操作命令**（整段粘贴回车）：
```bash
set -euo pipefail
ALLOW='docs/superpowers/acceptance/2026-06-19-reset-capital-true-restart-acceptance.md
docs/superpowers/plans/2026-06-19-reset-capital-true-restart.md
docs/superpowers/specs/2026-06-19-reset-capital-true-restart-design.md
ios/Contracts/Sources/KlineTrainerContracts/AppState.swift
ios/Contracts/Sources/KlineTrainerContracts/Persistence/TrainingResetPort.swift
ios/Contracts/Sources/KlineTrainerContracts/PreviewFakes/InMemoryFakes.swift
ios/Contracts/Sources/KlineTrainerContracts/Settings/SettingsStore.swift
ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanel.swift
ios/Contracts/Sources/KlineTrainerContracts/UI/SettingsPanelContent.swift
ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift
ios/Contracts/Sources/KlineTrainerPersistence/DebugFixtures/AppContainer+DebugSeed.swift
ios/Contracts/Sources/KlineTrainerPersistence/DefaultAppDB.swift
ios/Contracts/Sources/KlineTrainerPersistence/Internal/RecordRepositoryImpl.swift
ios/Contracts/Sources/KlineTrainerPersistence/Internal/SettingsDAOImpl.swift
ios/Contracts/Tests/KlineTrainerContractsTests/InMemoryDBFakesTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/SettingsStoreProductionTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/TrainingSessionCoordinatorTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/UI/SettingsPanelContentTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerDebugSeedTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/AppContainerTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/DefaultSettingsDAOTests.swift
ios/Contracts/Tests/KlineTrainerPersistenceTests/TrainingResetPortTests.swift
kline_trainer_plan_v1.5.md'
changed=$(git diff --name-only origin/main...HEAD)
extra=$(comm -23 <(echo "$changed" | sort -u) <(echo "$ALLOW" | sort -u))
if [ -z "$extra" ]; then echo "GATE-PASS：仅白名单文件改动"; else echo "GATE-FAIL：越界文件："; echo "$extra"; fi
```

**预期输出**：单行 `GATE-PASS：仅白名单文件改动`。

**判定**：打印 `GATE-PASS` → ✅；出现 `GATE-FAIL` 及任意文件名 → ❌。

---

## 第 2 条 · persistence 新测试（含真事务回滚）

**目的**：确认 5 条 `TrainingResetPortTests` 全部通过，特别是 `test_dbQueue_transaction_rolls_back_deleteAll_on_later_failure`（注入真实 GRDB dbQueue，令事务中途抛错，确认记录未被删除）。

**操作命令**：
```bash
cd ios/Contracts && swift test --filter TrainingResetPortTests 2>&1 | grep -E "Executed|passed|failed"; cd - >/dev/null
```

**预期输出**：含 `Executed 5 tests, with 0 failures` 与 `passed`，无 `failed`。

**判定**：`Executed 5 tests, with 0 failures` 且含 `passed` → ✅；任何 `failure` / `failed` → ❌。

---

## 第 3 条 · AppContainer 重置后开局 startingCapital 测试

**目的**：确认重置后立刻开新局，`startingCapital` 从 SettingsStore 读 10 万，而非读到旧 AppState 的 ¥0。

**操作命令**：
```bash
cd ios/Contracts && swift test --filter "AppContainerDebugSeedTests/test_after_reset_freshStart_startsAtDefault" 2>&1 | grep -E "Test run with|passed|failed"; cd - >/dev/null
```

**预期输出**：含 `Test run with 1 test in 1 suite passed`，无 `failed`。

**判定**：`passed` 且测试数 ≥ 1 → ✅；`failed` 或测试数为 0 → ❌。

---

## 第 4 条 · SettingsStore + SettingsPanelContent 新测试

**目的**：确认 SettingsStore 的 `resetAllProgress` 编排端口调用（含端口错误回滚本地资金）及 SettingsPanelContent 确认文案已披露清空记录。

**操作命令**（两步，逐条回车）：
```bash
cd ios/Contracts && swift test --filter SettingsStoreProductionTests 2>&1 | grep -E "Test run with|passed|failed"; cd - >/dev/null
cd ios/Contracts && swift test --filter SettingsPanelContentResetCopyTests 2>&1 | grep -E "Test run with|passed|failed"; cd - >/dev/null
```

**预期输出**：
- 第一行：`Test run with 14 tests in 1 suite passed`（含 `resetAllProgress` 四条新测试），无 `failed`。
- 第二行：`Test run with 2 tests in 1 suite passed`（文案披露 + 破坏性如实告知），无 `failed`。

**判定**：两行均含 `passed`，无 `failed` → ✅；任何 `failed` → ❌。

---

## 第 5 条 · host 全量 + Mac Catalyst build + iOS app build 零回归

**目的**：确认全包 host 单测全绿（平台无关逻辑无回归）+ Mac Catalyst 测试 build 成功 + iOS app target 编译成功。

**操作命令**（三步，逐条回车；每步约 30–60 秒）：
```bash
cd ios/Contracts && swift test 2>&1 | grep -E "Test run with|failed"; cd - >/dev/null
```
```bash
cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 | tail -1; cd - >/dev/null
```
```bash
xcodebuild build \
  -project ios/KlineTrainer/KlineTrainer.xcodeproj \
  -scheme KlineTrainer \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/app-derived \
  CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "\*\* BUILD (SUCCEEDED|FAILED) \*\*"
```

**预期输出**（运行时实测，2026-06-19 本地已验证）：
- 步骤一：`Test run with 1091 tests in 150 suites passed`（数字 ≥ 1091，0 failures）
- 步骤二：`** TEST BUILD SUCCEEDED **`
- 步骤三：`** BUILD SUCCEEDED **`

**判定**：三行分别含 `passed` / `TEST BUILD SUCCEEDED` / `BUILD SUCCEEDED`，且均无 `failed`/`FAILED`/`error:` → ✅；任一含失败字样 → ❌。

---

## 第 6 条 · 模拟器 runbook（三场景，用户实测回填）

> 本节为运行时观感验收（host 不可复现）。用户在已 seed（`KLINE_SEED_FIXTURE=1`）的模拟器逐项操作并打勾。每项 action/expected/pass-fail。

| # | 操作（action） | 预期（expected） | 判定 |
|---|---|---|---|
| 6.1 | 模拟器跑 app，正常训练几局（至少完成 1 局产生历史记录）→ 切到「设置」页 → 点「重置资金并清空训练记录」→ 弹出确认弹框 | 弹框标题/文案中明确包含「清空训练记录」或同义措辞；有「确认」与「取消」两个按钮 | ☐ |
| 6.2 | 接上步 → 点「确认」 | 返回首页：历史记录列表**完全清空**（无任何训练记录条目）；顶栏显示总资金 **¥100,000**（非旧余额亦非 ¥0） | ☐ |
| 6.3 | 接上步（已重置状态）→ 点「继续训练」或「开始新局」进入训练页 | 训练页顶栏/资金区显示 **¥100,000**（10 万元，非 ¥0） | ☐ |
| 6.4 | 删除 app → 重新安装（模拟全新安装，无任何历史数据）→ 直接点「继续训练」开局 | 训练页顶栏/资金区显示 **¥100,000**（10 万元，非 ¥0） | ☐ |
| 6.5 | 训练几局产生记录，切到「设置」→ 点「重置资金并清空训练记录」→ 弹框出现后点**取消** | 返回设置页（或原界面）：历史记录**不变**（原记录保留）；总资金**不变**（原余额不被重置） | ☐ |

---

## 第 7 条 · Opus 4.8 xhigh 对抗性 review APPROVE 落账（ledger）

**目的**：确认本分支 head 的 `codex:adversarial-review`（由 Opus 4.8 xhigh 对抗性 review 代行）已 `approve` 并写入 ledger（治理强制 review channel）。

**操作命令**：
```bash
grep -F "fix/w3-reset-capital@$(git rev-parse HEAD)" .claude/state/codex-attest-ledger.jsonl 2>/dev/null | grep -o '"verdict":"[a-z-]*"' | tail -1
```

**预期输出**：`"verdict":"approve"`。

**判定**：打印 `"verdict":"approve"` → ✅；空输出或非 approve → ❌。
（注：ledger key 形式为 `branch:fix/w3-reset-capital@<完整 HEAD SHA>`；本 review 在本 Task 6 commit 后单独运行，故 `$(git rev-parse HEAD)` 与 ledger approve 条目一致；若 ledger 路径有差异，以 `codex-attest` 运行时打印的 `ledger updated` + 同一 head SHA 为准。）

---

## 残留（移交，非本交付义务）

- **模拟器 runbook §6（第 6 条）**：用户实测后在本 doc 回填 ☐ → ✅/❌。
- **Opus 4.8 xhigh APPROVE（第 7 条）**：branch-diff 闸门 review 在本 commit 之后单独跑并落账。
- **后端 B3/B4 pending_sessions 清理**：`pending_sessions` 表在 iOS 本地清空（已覆盖），后端 lease 状态机（FastAPI B3）若有对应租约记录，清理属后端 scope，不在本计划范围内。
