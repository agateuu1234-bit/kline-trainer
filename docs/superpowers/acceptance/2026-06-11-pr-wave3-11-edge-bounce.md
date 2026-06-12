# Wave 3 顺位 11 — 边缘 bounce 动画（组件层隔离）验收清单

> **本 PR 性质**：组件层纯物理隔离交付（`EdgeBounceModel` 边缘回弹物理 + `DecelerationModel` boundary-aware 推进 + `DecelerationAnimator` bounce 启动面）。**无实时可见运行时接线**（接线 deferred 为 residual `W3-11-R1`，见第 5/6 条），因此本 PR 的验收判据 = **确定性单元测试 + 范围 gate + 既有行为零回归**，而非 App 屏幕上的肉眼回弹效果。
>
> **如何用本清单**：你（非编码者）逐条照抄「操作命令」到终端回车，把屏幕输出对照「预期输出」，二者吻合即在「判定」勾选 ✅，不吻合勾选 ❌。每条都有二元（是/否）判据，无需读代码。
>
> **运行前置**：终端先进入本仓库工作树根目录（含空格，须带引号）：
> ```bash
> cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave3-pr11-edge-bounce"
> ```

---

## 第 1 条 · 范围 gate（改动文件白名单 fail-closed）

**目的**：确认本 PR 只动了 3 个生产 Swift + 3 个测试 Swift + 3 个文档，**没有**碰渲染/引擎/容器/Reducer 等被锁文件。

**操作命令**（在工作树根目录粘贴整段回车）：
```bash
set -euo pipefail
ALLOW='ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationModel.swift
ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/DecelerationAnimator.swift
ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift
ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelBoundaryTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/EdgeBounceModelTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorBounceTests.swift
docs/superpowers/specs/2026-06-11-pr-wave3-11-edge-bounce-design.md
docs/superpowers/plans/2026-06-11-pr-wave3-11-edge-bounce.md
docs/superpowers/acceptance/2026-06-11-pr-wave3-11-edge-bounce.md'
changed=$(git diff --name-only origin/main...HEAD)
violations=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  grep -Fxq -- "$f" <<<"$ALLOW" || { echo "SCOPE-VIOLATION: $f"; violations=$((violations+1)); }
done <<<"$changed"
[ "$violations" -eq 0 ] && echo "SCOPE-OK" || { echo "SCOPE-FAIL ($violations 个越界文件)"; exit 1; }
```

**预期输出**：最后一行恰好是 `SCOPE-OK`，且**没有任何** `SCOPE-VIOLATION:` 行。

**判定**：
- 看到 `SCOPE-OK` 且无 `SCOPE-VIOLATION:` 行 → 勾 ✅
- 看到 `SCOPE-FAIL` 或任意 `SCOPE-VIOLATION:` 行 → 勾 ❌（说明动了白名单外文件，须排查）

- [ ] 通过

**实测留痕（本次交付）**：脚本输出 `SCOPE-OK`。

---

## 第 2 条 · 既有测试零改动（P7 回归门）

**目的**：确认 Wave 1/Wave 2 已落地的两份既有测试文件（`DecelerationModelTests` / `DecelerationAnimatorTests`）**一字未改**——本 PR 只新增能力、不动既有契约。

**操作命令**：
```bash
git diff origin/main...HEAD -- \
  ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationModelTests.swift \
  ios/Contracts/Tests/KlineTrainerContractsTests/DecelerationAnimatorTests.swift
```

**预期输出**：**完全空白**（命令回车后立即回到命令行提示符，无任何 `+`/`-` 差异行）。

**判定**：
- 输出为空（无差异）→ 勾 ✅
- 输出含任意 `+` 或 `-` 行 → 勾 ❌（既有测试被改动 = P7 破坏，须停下排查）

- [ ] 通过

**实测留痕（本次交付）**：diff 为空（既有两份测试零改动）。

---

## 第 3 条 · 全量测试绿（确定性单测全过）

**目的**：跑完整测试套件，确认 0 失败，且总数 = 基线 799 + 本 PR 新增 = **835**。

**操作命令**：
```bash
set -o pipefail; cd ios/Contracts && swift test 2>&1 | tail -3
```
（`set -o pipefail` 必带：否则管道会吞掉测试失败、把 `tail` 的成功退出码当成全过。）

**预期输出**：最后一行为
```
✔ Test run with 835 tests in 123 suites passed after <耗时> seconds.
```
关键词：`835 tests`、`123 suites`、`passed`，**无** `failed`。

**判定**：
- 末行含 `835 tests in 123 suites passed` 且无 `failed` → 勾 ✅
- 末行测试数 ≠ 835，或出现 `failed`/任意失败 → 勾 ❌

- [ ] 通过

**实测留痕（本次交付）**：
```
✔ Test run with 835 tests in 123 suites passed after 22.372 seconds.
```

---

## 第 4 条 · Mac Catalyst 编译链接（required CI 检查）

**目的**：本仓 Swift Testing 在 macOS host 上跑运行时；Mac Catalyst 侧只验**编译 + 链接通过**（不在 Catalyst 上跑运行时断言）。该检查是 PR 的 required status check，由 GitHub Actions 自动执行。

**操作（在 GitHub PR 页面，无需终端）**：
1. 打开本 PR 页面，下拉到底部 checks 区。
2. 找到名为 `Mac Catalyst build-for-testing on macos-15` 的 required check。

**预期输出**：该 check 显示绿色对勾（成功 / build-for-testing 通过）。

**判定**：
- `Mac Catalyst build-for-testing on macos-15` 为绿色通过 → 勾 ✅
- 该 check 为红色失败 / 黄色进行中未完成 → 勾 ❌（失败须排查；进行中须等待跑完再判）

- [ ] 通过

**说明**：此 check 验证 Catalyst 目标可编译可链接，**不**代表在真机/模拟器上肉眼看到回弹动画——肉眼回弹属 residual `W3-11-R1`（见第 5/6 条），本 PR 不交付。

---

## 第 5 条 · residual `W3-11-R1` 已显式登记

**目的**：确认本 PR **故意不做**的部分（实时可见接线及其设备/模拟器实测）已被明确记成 residual，不是被遗忘。

**residual `W3-11-R1` 范围（本 PR deferred、折入顺位 3 或顺位 3 之后的 fast-follow 交付）**：
1. **实时可见接线**：把 `EdgeBounceModel` / `DecelerationAnimator.start(initialVelocity:fromOffset:minOffset:maxOffset:)` 接到真实手势 / 渲染 offset 上，让回弹在屏幕上可见。
2. **`stop()` 的 caller-intent 语义**：界定调用方主动 `stop()` 时是否需要归位到 edge（当前组件层只提供 `resetOnSceneActive()` 归位面，主动 stop 的归位策略待接线方定）。
3. **`cancelPan` 路径**：手势取消时以零速度触发越界回弹（组件已支持零速越界回弹，接线侧 cancelPan → start 的调用待补）。
4. **全几何 bounds 失效兜底**：接线层在分离 offset 边界全量退化（如数据极少 / 视口几何边界塌缩）时的上层行为。
5. **bounce 设备 / 模拟器 runbook 实测**：在真机或模拟器上肉眼核验回弹观感的可复现操作手册。

**操作（阅读核对，无需终端）**：确认本条上述 5 项与计划 `docs/superpowers/plans/2026-06-11-pr-wave3-11-edge-bounce.md` Task 4 Step 1 第 5 条描述一致，且本 PR 代码确实未实现接线（第 1 条范围 gate 已证未碰 `RenderStateBuilder/TrainingEngine/ChartContainerView/Reducer`）。

**预期**：5 项 residual 文字齐备；范围 gate（第 1 条）= `SCOPE-OK` 反证接线确实未做。

**判定**：
- 5 项 residual 齐备 且 第 1 条 = `SCOPE-OK` → 勾 ✅
- residual 缺项 或 第 1 条出现接线文件越界 → 勾 ❌

- [ ] 通过

---

## 第 6 条 · runbook deferral 诚实条款

**目的**：诚实声明本 PR 的验证边界，避免把「单测全绿」误读成「屏幕回弹已验证」。

**条款全文**：

> 本 PR 交付的是**组件层纯物理**，组件**无任何实时可见运行时**（未接手势 / 未接渲染 offset）。因此：
> - **bounce 的设备 / 模拟器 runbook（肉眼回弹观感实测）随 residual `W3-11-R1` 一并交付**，不在本 PR 范围内。
> - **本 PR 的验证完全由确定性单元测试承担**：边界推进帧率无关性、解析弹簧分区不变、首次过边 clamp、峰值穿透单调性、原子终止 + finalDelta 一致性、re-entrancy 安全、既有行为零回归（P1–P9 全覆盖，见 `EdgeBounceModelTests` / `DecelerationModelBoundaryTests` / `DecelerationAnimatorBounceTests`）。
> - 第 3 条全量测试绿 = 本 PR 的主验收证据；第 4 条 Catalyst = 编译链接证据。屏幕肉眼回弹的可复现核验，须等 `W3-11-R1` 接线落地后按其 runbook 执行。

**操作（阅读核对，无需终端）**：确认上述条款与计划 Task 4 Step 1 第 6 条一致，且第 3 条（单测全绿）+ 第 4 条（Catalyst）的实测留痕均已具备。

**判定**：
- 条款齐备 且 第 3、4 条均通过 → 勾 ✅
- 条款缺失 或 第 3/4 条未通过 → 勾 ❌

- [ ] 通过

---

## 验收汇总

| 条 | 判据 | 状态 |
|---|---|---|
| 1 | 范围 gate = `SCOPE-OK`，无越界文件 | [ ] |
| 2 | 既有两份测试 diff 为空（P7） | [ ] |
| 3 | 全量测试 `835 tests in 123 suites passed`，0 失败 | [ ] |
| 4 | Catalyst required check 绿（编译 + 链接） | [ ] |
| 5 | residual `W3-11-R1` 5 项齐备 | [ ] |
| 6 | runbook deferral 诚实条款齐备 | [ ] |

**全部 6 条勾 ✅ → 本 PR 验收通过。** 任一条 ❌ → 须按对应条排查后重验，不得跳过。
