# PR C2 DecelerationAnimator —— 验收清单

> 语言：中文。判定二元可决。证据：命令输出贴 PR comment。

| # | 动作 | 预期 | 判定 |
|---|---|---|---|
| 1 | 运行 `swift test --package-path ios/Contracts --filter DecelerationModel` | 终端输出含 `15 tests`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 2 | 运行 `swift test --package-path ios/Contracts --filter DecelerationAnimator` | 终端输出含 `15 tests`、`0 failures` | failures = 0 → 通过；否则不通过 |
| 3 | 运行 `swift test --package-path ios/Contracts` | 全量测试 0 failures | failures = 0 → 通过；否则不通过 |
| 4 | 运行 `swift build --package-path ios/Contracts` | 输出 `Build complete!` | 出现该串且无 error → 通过；否则不通过 |
| 5 | 在 `ios/Contracts` 运行 `xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath /tmp/c2-catalyst` | 输出含 `** TEST BUILD SUCCEEDED **`，无 `error:`/`warning:` | 出现该串且无 error/warning → 通过（编译 iOS/Catalyst CADisplayLink adapter）；否则不通过 |
| 6 | 运行 `grep -n "AppError" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift` | 无任何匹配行 | 0 匹配（C2 不跨错误信任边界）→ 通过；有匹配 → 不通过 |
| 7 | 运行 `grep -n "PanelViewState" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift` | 无任何匹配行 | 0 匹配（animator 不引用面板状态类型 → 不可能直接写 PanelViewState.offset）→ 通过；有匹配 → 不通过 |
| 8 | 运行 `grep -n "weak self" ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift` | 至少 1 行匹配 | ≥1 匹配（onTick 闭包 weak 持 animator，防 runloop 强持有泄漏）→ 通过；0 匹配 → 不通过 |

---

## 流程合规与偏差（如实记录，2026-05-23）

本 PR 按用户指定的 Superpowers 6 段流程执行（writing-plans → plan-stage codex → subagent-driven-development → verification-before-completion → requesting-code-review → branch-diff codex），每段均调用真实 skill、未用 raw Agent 偷换。以下偏差**如实记录，不粉饰**：

**1. 两个 codex 对抗性 review 阶段均未取得 codex `approve`。** plan-stage 跑 R1–R5、branch-diff 跑 R1–R5，**verdict 始终是 `needs-attention`**，从未收敛到 codex `approve`。最终按项目预算规则（`feedback_codex_plan_budget_overshoot`：超 5 轮必 escalate）停下，靠 **user 接受残留 + attestation override** 收口，**不是字面意义的"codex 通过到收敛"**。每轮 finding 均为真实 bug 且已修（plan-stage：CADisplayLink macOS 不可用 / NaN / 泄漏 / generation / 文件位置等；branch-diff：UIKit 帧预算 vs 真实经过时间 / 首帧基准 / 帧暂停释放 / 细分积分 / 单调钟 / isolated-deinit Swift 6.0 违规）。两条接受残留见上文 "Accepted residual"。

**2. 用普通 git branch，非 git worktree。** subagent-driven-development 推荐 `using-git-worktrees` 做隔离；本 PR 直接在分支上执行（单 PR、工作树干净，影响小，属简化）。

**3. plan 内嵌代码块随 8 轮修复部分陈旧。** 未逐块重同步，以 plan 的 self-review 注记 + 完整 commit 列表标注"以最终源码为准"；本验收清单的测试计数与源码同步准确。

**4. codex CLI 走本地 runtime（非 MCP）；review 期间无配额中断。**

合并方式：因偏差 1（codex 未 approve），走 attestation override（user TTY）+ Catalyst CI 必检真实通过（不绕过）+ admin squash。
