# 验收清单 — Wave 2 顺位 10：U4 SettingsPanel + SettingsStore 两层恢复

**对象**：你本人（非程序员）。每条给出「操作 / 预期 / 通过判定」。关键步骤附真实命令输出。
**前置**：终端进入工作目录 `ios/Contracts`（即 `cd "ios/Contracts"`）。术语：「测试」= 自动检查程序；「绿/通过」= 0 失败。

---

## 一、自动测试（恢复 API + 内容层 + 默认值）

> **注（rebase 后重验）**：本分支已 rebase 到含 E6a(#83)+C8a(#84) 的最新 `origin/main`（codereview I1），下方数字均为**集成后整棵树**实跑。

### 1.1 全量测试绿

- **操作**：终端运行 `swift test`
- **预期**：最后一行显示「Test run with 696 tests in 111 suites passed」（数字 ≥696，0 失败）
- **真实输出（集成后实跑）**：
  ```
  ✔ Test run with 696 tests in 111 suites passed after 22.323 seconds.
  ```
- **通过判定**：出现 `passed` 且无 `✘`/`failed` → 通过；任何 `failed` → 不通过

### 1.2 恢复状态机 11 场景全覆盖

- **操作**：运行 `swift test --filter SettingsStoreRecoveryTests`
- **预期**：14 个测试通过（11 RFC 场景 + retryReload 健康态/失败更新错误 2 单元 + 9b post-save reload 失败 codereview M1）
- **真实输出**：
  ```
  ✔ Test run with 14 tests in 1 suite passed after 0.002 seconds.
  ```
- **覆盖对照（RFC §四 场景号 ↔ 测试名）**：
  | RFC 场景 | 测试 | 含义（中文） |
  |---|---|---|
  | 1 | s1_transientRetrySucceeds | 临时故障：重试救回原设置，不破坏 |
  | 2 | s2_persistentForceReset | 数据真损坏：重置为默认值，费率非零 |
  | 3 | s3a/s3b_healthy*Throws | 正常态：重试/重置都拒绝、不改设置 |
  | 4 | s4_orderGuard | 没先重试就重置 → 拒绝、不写库 |
  | 5 | s5_selfHealBeforeDestroy | 重置前最后一读自愈 → 保留真实值、不破坏 |
  | 6 | s6_transientGate | 临时故障没好 → 拒绝破坏（防误删好设置） |
  | 7 | s7_persistentCorruption | 持续损坏 → 写默认值恢复成功 |
  | 8 | s8_mixedError | 入口损坏但破坏时刻变临时 → 不破坏 |
  | 9 | s9_destroyWriteFails | 重置写库失败 → 保留错误状态 |
  | 10 | s10_initTransientRetryCorrupted | 启动临时→重试暴露损坏 → 按最新允许重置 |
  | 11 | s11_initCorruptedRetryTransient | 启动损坏→重试变临时 → 按最新拒绝破坏 |
- **通过判定**：13 passed，0 failed → 通过

### 1.3 破坏守卫非空洞（mutation 实证）

- **操作**：见 plan Task 4 Step 5 记录（已实跑）：临时把「错误类型门」改成永远放行，重跑测试
- **预期**：场景 6、11 立即失败（证明守卫是真挡板，不是摆设）；恢复守卫后重新全绿
- **真实输出（mutation 时）**：
  ```
  ✘ 场景6 ... failed   ✘ 场景11 ... failed
  ```
  恢复后：`✔ Test run with 13 tests ... passed`
- **通过判定**：mutation 时有失败、恢复后全绿 → 通过

### 1.4 内容层纯函数（佣金换算 / 下载数量校验 / 显示模式）

- **操作**：运行 `swift test --filter SettingsPanelContentTests`
- **预期**：6 个测试通过
- **真实输出**：`✔ Test run with 6 tests in 1 suite passed`
- **通过判定**：6 passed → 通过

### 1.5 默认值

- **操作**：运行 `swift test --filter AppSettingsDefaultTests`
- **预期**：2 个测试通过；默认值 = 佣金万分之一 0.0001、本金 10 万、跟随系统、免5 关闭；费率/本金均非零
- **真实输出**：`✔ Test run with 2 tests in 1 suite passed`
- **通过判定**：2 passed → 通过

---

## 二、Catalyst 编译闸门（CI 必过项）

### 2.1 Mac Catalyst build-for-testing 本地实跑

- **操作**：运行
  ```
  xcodebuild build-for-testing -scheme KlineTrainerContracts \
    -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/derived_u4
  ```
- **预期**：结尾出现 `** TEST BUILD SUCCEEDED **`，且全程无 `error:`/`warning:`（CI 闸门对警告零容忍）
- **真实输出**：
  ```
  ** TEST BUILD SUCCEEDED **
  === GATE CHECK ===  BUILD SUCCEEDED present  /  no error/warning (gate PASS)
  ```
- **通过判定**：BUILD SUCCEEDED 出现 + 无 error/warning → 通过（= CI required check「Mac Catalyst build-for-testing on macos-15」预期绿）

---

## 三、源码级契约核对（grep 锚定）

### 3.1 五控件齐全（§6.4：佣金费率/免5/重置资金/离线缓存/显示模式）

- **操作**：运行
  ```
  grep -c -E "佣金费率|免5|重置资金|离线缓存|显示模式" Sources/KlineTrainerContracts/UI/SettingsPanel.swift
  ```
- **预期**：计数 ≥5（五控件文案都在）
- **通过判定**：≥5 → 通过

### 3.2 离线缓存薄接线（reserveTrainingSets → runBatch）

- **操作**：`grep -n "reserveTrainingSets\|runBatch" Sources/KlineTrainerContracts/UI/SettingsPanel.swift`
- **预期**：两者都命中（数量校验 1~20 → 预占 → 批量验收）
- **通过判定**：两行都出现 → 通过

### 3.3 SettingsResetConfirmation 仅本模块可构造（internal init，防包外误调）

- **操作**：`grep -n "init" Sources/KlineTrainerContracts/Settings/SettingsResetConfirmation.swift`
- **预期**：只有 `internal init() {}`，**没有** `public init`
- **通过判定**：无 `public init` → 通过

### 3.4 未改 Wave 0 冻结的 SettingsDAO 协议

- **操作**：`git diff origin/main -- ios/Contracts/Sources/KlineTrainerContracts/Persistence/SettingsDAO.swift`
- **预期**：无任何输出（该文件零改动）
- **通过判定**：空输出 → 通过

---

## 四、手动 UI（可选，需 Xcode）

> SwiftUI 壳按项目惯例（D8/D10）不做自动单测，靠 Catalyst 编译闸门 + Xcode 预览。本节为可选人工确认。

- **操作**：Xcode 打开 `ios/Contracts`，定位 `SettingsPanel.swift`，点右侧 Canvas 预览（#Preview）
- **预期**：面板从上到下显示 5 个控件：佣金费率按钮、免5 开关、重置资金按钮、离线缓存下载按钮、显示模式分段选择
- **通过判定**：5 控件渲染出现 → 通过；预览编译报错 → 不通过

---

## 汇总

| 项 | 结果 |
|---|---|
| 1.1 全量 696 测试（集成 E6a+C8a 后） | 通过 |
| 1.2 恢复 11 场景（14 测试，含 9b） | 通过 |
| 1.3 守卫 mutation 实证 | 通过 |
| 1.4 内容层 6 测试 | 通过 |
| 1.5 默认值 2 测试 | 通过 |
| 2.1 Catalyst 编译闸门 | 通过 |
| 3.1–3.4 源码契约核对 | 通过 |
| 4 手动 UI | 可选 |
