# U4 Plan-stage 对抗性 Review R1

**评审通道**：opus 4.8 xhigh。**说明（诚实化）**：本会话 Agent 子代理基础设施连续 5 次 socket 掉线（0 返回），无法用独立子代理实例。改由主 opus 4.8 实例 inline 执行最大严格度对抗性 review——独立性降级，但对全部 11 场景逐条 trace + 经验实证（swift 跑 FP/解析）保证严格度。R2 由实施后整体 review 补独立性（用户要求的第二道整体 review）。

**评审对象**：`docs/superpowers/plans/2026-06-07-pr-u4-settings-panel.md`
**契约源**：`docs/superpowers/specs/2026-06-03-wave2-pr1-baseline-h1-rfc-design.md` §四（11 场景）

## 一、11 场景逐条 trace（retryReload + forceResetAndReload 伪代码 vs RFC）

| 场景 | loadScript（init/retry/forceReset 前/post-save） | 代码结果 | RFC 期望 | 判定 |
|---|---|---|---|---|
| 1 transient retry 成功 | [ioError, success(user)] | settings=user, loadError=nil, save=0, 解阻 | 同 | ✅ |
| 3a 健康 retry throws | [success(user)] | throw, settings 不变, save=0 | 同 | ✅ |
| retryFail 更新 loadError | [ioError, dbCorrupted] | throw dbCorrupted, loadError=dbCorrupted(最新), save=0 | FR7 | ✅ |
| 2 persistent malformed | [dbC, dbC, dbC] | save(.default)=1, settings=.default, loadError=nil, fee 非零 | 同 | ✅ |
| 3b 健康 force throws | [success(user)] | throw, settings 不变, save=0 | 同 | ✅ |
| 4 顺序守卫 | [dbC] (未 retry) | throw(guard2), save=0 | R9 | ✅ |
| 5 破坏前自愈 | [dbC, dbC, success(user)] | settings=user, loadError=nil, save=0 | R10 | ✅ |
| 6 transient 未恢复 | [diskFull, diskFull] | throw diskFull(guard3), save=0 | FR2 | ✅ |
| 7 persistent corruption | [dbC, dbC, dbC] | save=1, settings=.default, 解阻 | 同 | ✅ |
| 8 混合错误 | [dbC, dbC, diskFull] | loadError=diskFull, throw, save=0 | FR3 | ✅ |
| 9 破坏写失败 | [dbC, dbC, dbC]+saveError | throw, loadError 保留 dbCorrupted | 同 | ✅ |
| 10 init transient→retry dbC | [ioError, dbC, dbC] | guard3 按最新 dbC 过门, save=1, settings=.default | FR7 | ✅ |
| 11 init dbC→retry transient | [dbC, ioError] | throw ioError(guard3 按最新), save=0 | FR7 | ✅ |

**结论**：状态机 11 场景全部 trace 正确。关键不变量（settings-before-clear-error / FR7 最新错误 / 错误类型门 / FR3 破坏前 reload 分流 / 顺序守卫 / 健康守卫）均落实。loadScript 长度/索引与每场景 loadSettings 调用次数（init=1 + retry?1 + forceReset 前=1 + post-save=1）一致，无 off-by-one。

## 二、经验实证（swift 跑，防 FP/解析臆测）

```
7*0.0001 == 0.0007 ? true        2.5*0.0001 == 0.00025 ? true
1*0.0001 == 0.0001 ? true        0.0001*10000 == 1.0 ? true
fmt 0.0001*10000: 1.000          fmt 0.00125*10000: 12.500
Int("3.5"): nil
```
→ 内容层 helper 逻辑与测试期望全部成立。

## 三、findings

### [MEDIUM] M1：恢复方法非 re-entrancy-safe（并发双触发可 clobber 状态）
- 证据：plan Task 3/4 `retryReload`/`forceResetAndReload` 在 `try await Task.detached{...}.value` 处有 await 挂起点；两方法均**不**走 `pendingMutations` 串行链（区别于 update/resetCapital，SettingsStore.swift L51/L70）。用户双击「重试」→ 两并发 retryReload：retry1 成功清 loadError 后 retry2 失败可能重新置 loadError，把已恢复的 store 错误地打回错误态。
- RFC 立场：§四 11 场景全是**顺序**单次，无并发场景；恢复是手动单发用户动作。
- 处理（决策）：**作显式 non-goal**（不在本锚硬化恢复并发，YAGNI + 不超 RFC scope）+ **UI 壳层缓解**：recovery 按钮在操作期间 `@State isRecovering` 禁用，杜绝双触发（壳代码，D8 不单测，靠 Catalyst 编译）。已应用到 plan Task 6。

### [LOW] L1：内容层 FP 精确等值 → 改容差（防御，per feedback_swift_local_toolchain_blindspot）
- 证据：plan Task 5 `commissionRate(fromUIInputTenThousandth: 7) == 0.0007` 与 `parseCommissionUIInput("  2.5 ") == 0.00025` 用精确 `==`。经验实证当前 toolchain 成立（IEEE 乘法 correctly-rounded 确定性），但项目 FP 纪律要求非平凡乘除用容差。
- 处理：×1 平凡乘（`1→0.0001`/`"1"→0.0001`）保留精确 `==`（乘 1.0 位等价，安全）；×7、×2.5 改 `abs(...) < 1e-12`。已应用到 plan Task 5。

### [LOW] L2：`_ = confirmation` 多余（未用函数参数不告警）
- Swift 未用**函数参数**不产生 warning，`_ = confirmation` 非必需；保留作「故意未用 = deliberate-intent 信号」自文档，无害。不改。

### CRITICAL / HIGH：无真实 finding
- 并发（Sendable）：`@MainActor @Observable` + `Task.detached{dao.loadSettings()}` + await 后 `self.settings=loaded` 与既有 update/resetCapital 同型；AppSettings/SettingsDAO 均 `Sendable` → clean。
- 冻结签名：SettingsPanel init / retryReload / forceResetAndReload(confirmation:) 与 modules L2081-2084 / L2002-2003 字面一致（`any` 为 Swift 6 existential 必需，语义同）。
- SettingsResetConfirmation：public 类型 + internal init 合法（public func 可收 public 类型参数；internal init 阻包外构造、允包内 SettingsPanel 构造）。
- AppSettings.default：fee 0.0001 + capital 100_000 均非零（满足场景 2 非零 default fee）。
- §6.4 五控件齐全；离线缓存薄接线 reserveTrainingSets→runBatch 正确；AcceptanceResult `.confirmed`/`.rejected` 名核实无误。

## 四、R2（fix 应用后复核）

- M1 → plan Task 6 加 `isRecovering` 禁用 + non-goal 注（§五）。
- L1 → plan Task 5 ×7/×2.5 改容差。
- 无新增 finding；无回归（全为 additive 改动，不触 SettingsDAO/既有 13 SettingsStoreProductionTests 行为）。

**Verdict: APPROVE（fix 应用后）** — plan 实施就绪。状态机 11 场景证明正确；唯一 MEDIUM（恢复并发）按 RFC scope 作 non-goal + UI 缓解；2 LOW 已应用。
