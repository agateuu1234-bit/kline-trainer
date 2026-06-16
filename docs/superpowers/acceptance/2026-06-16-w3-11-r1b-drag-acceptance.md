# W3-11-R1b-drag 拖拽期橡皮筋阻尼 — 非-coder 验收清单

> **本交付性质**：手指按住拖过最老边时内容带 iOS 橡皮筋阻尼跟手、松手回弹到最老边；最新边保持硬钳无给。改 2 生产 Swift（`RubberBand.swift` 新增 + `TrainingEngine.swift` 修改）+ 3 测试 Swift + plan/spec/本验收文档。**零渲染层改动、零 EdgeBounceModel 物理改动、零手势契约改动。**
>
> **如何用**：逐条照抄「操作命令」到终端回车，把屏幕输出对照「预期输出」，吻合即「判定」勾 ✅，不吻合勾 ❌。每条二元（是/否），无需读代码。
>
> **运行前置**（终端先进工作树根，含空格须带引号）：
> ```bash
> cd "/Users/maziming/Coding/Prj_Kline trainer/.claude/worktrees/wave3-w3-11-r1b-drag"
> ```

---

## §六.1 · RubberBand 纯函数性质测试

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter RubberBandTests` | 末行输出 `✔ Test run with 5 tests in 1 suite passed` | ✅ 5 tests passed / ❌ 其他 |

---

## §六.2 · 过最老边阻尼跟手（D2 killer）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter dragPastEdgeDamps` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.3 · 反拖解绕（raw 累加器正确）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter reverseDragUnwinds` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.4 · 界内 1:1 回归（[0,maxOffset] 不阻尼）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter inBoundsLinear` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.5 · 最新边硬钳无给（单边 killer）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter newestEdgeHardClamp` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.6 · 无滚动空间硬钳（E6，maxOffset==0）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter noScrollRoomHardClamp` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.7 · endPan 从 overscroll 弹回（D3 killer）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter "endPanFromOverscroll"` | 末行输出 `✔ Test run with 2 tests in 1 suite passed` | ✅ 2 tests passed / ❌ 其他 |

---

## §六.8 · dragRaw 生命周期（beginPan seed / endPan·cancelPan 清 / 双面板独立）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter dragRawLifecycle` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.9 · cancelPan E4 归一 + resize E5 dragRaw 重同步

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter "cancelAtOverscrollNormalizes\|resizeMidDragResyncsDragRaw"` | 末行输出 `✔ Test run with 2 tests in 1 suite passed` | ✅ 2 tests passed / ❌ 其他 |

---

## §六.10 · dragPastEdgeRubberBands（既有 dragFullClamp 语义更新）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test --filter dragPastEdgeRubberBands` | 末行输出 `✔ Test run with 1 test in 1 suite passed` | ✅ passed / ❌ failed |

---

## §六.10B · 全量 host 回归（1085 tests，0 failures）

| 操作 | 预期 | 通过-不通过 |
|---|---|---|
| `cd ios/Contracts && swift test 2>&1 \| tail -3` | 末行含 `1085 tests` 且含 `passed` 不含 `failed` | ✅ 1085 passed / ❌ 任意 failed |

---

## §六.11 · 真机 / 模拟器 Runbook（用户实测回填）

以下 7 项须在真机或 Mac Catalyst 模拟器中手动实测，结果由用户回填 ✅/❌：

1. **拖过最老边带阻力跟手**：手指按住 K 线图，向最老方向推超过数据边界，图表内容随手指移动但明显感受到弹簧阻力（越推越难），不会卡死在边界。判据：内容确实移过边界且有明显阻力感。
2. **松手轻放回弹**：在过界位置缓慢放手（速度接近 0），图表弹回最老边停止，不残留在越界位置。判据：偏移归零至最老边（offset=maxOffset）。
3. **松手带速 overscroll 后回落**：在过界位置带一定速度朝内向松手，图表先继续向外（最多轻微），再回落至最老边停止，不停留在越界位置。判据：最终落 maxOffset，无持续 strand。
4. **拖向最新边无给**：手指从任意位置向最新方向推，到达 offset=0 后内容不再移动，无橡皮筋弹性，立即反方向可正常响应。判据：最新边硬钳，offset 不为负。
5. **满屏不动（无滚动空间）**：数据量小于可视区时，向任意方向拖，内容纹丝不动，offset 恒为 0。判据：offset==0 全程。
6. **过界中途旋转无残留**：拖到过界状态，旋转设备（竖/横切换），图表 resize 后 offset 归入新几何范围内（≤新 maxOffset），dragRaw 重同步，续拖无跳变。判据：rotate 后 offset 在新边界内，继续拖动平滑。
7. **过界中途两指接管或开画线无残留**：单指拖到过界后，立即双指 pinch 缩放或激活画线工具，offset 归入 maxOffset，无残留越界间隙。判据：两指或画线接管后 offset≤maxOffset。

---

## 范围 Gate（白名单 + 三 0 改动）

**白名单文件**（仅允许以下文件出现在 `git diff origin/main...HEAD`）：
```
ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/RubberBand.swift
ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
ios/Contracts/Tests/KlineTrainerContractsTests/RubberBandTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDragDampingTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineBounceWiringTests.swift
docs/superpowers/acceptance/2026-06-16-w3-11-r1b-drag-acceptance.md
docs/superpowers/plans/2026-06-16-w3-11-r1b-drag.md
docs/superpowers/specs/2026-06-16-w3-11-r1b-drag-design.md
```

**范围 gate 命令**（整段粘贴回车）：
```bash
set -euo pipefail
ALLOW='docs/superpowers/acceptance/2026-06-16-w3-11-r1b-drag-acceptance.md
docs/superpowers/plans/2026-06-16-w3-11-r1b-drag.md
docs/superpowers/specs/2026-06-16-w3-11-r1b-drag-design.md
ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/RubberBand.swift
ios/Contracts/Sources/KlineTrainerContracts/TrainingEngine/TrainingEngine.swift
ios/Contracts/Tests/KlineTrainerContractsTests/RubberBandTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineDragDampingTests.swift
ios/Contracts/Tests/KlineTrainerContractsTests/TrainingEngineBounceWiringTests.swift'
changed=$(git diff --name-only origin/main...HEAD)
extra=$(comm -23 <(echo "$changed" | sort -u) <(echo "$ALLOW" | sort -u))
if [ -z "$extra" ]; then echo "GATE-PASS：仅白名单文件改动"; else echo "GATE-FAIL：越界文件："; echo "$extra"; fi
```
**预期输出**：单行 `GATE-PASS：仅白名单文件改动`

**三 0 改动不变量**（以下三条命令预期均无输出）：

```bash
# 0 渲染层改动
git diff origin/main...HEAD -- ios/Contracts/Sources/KlineTrainerContracts/Render/RenderStateBuilder.swift
git diff origin/main...HEAD -- "ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView.swift"
```
```bash
# 0 EdgeBounceModel 物理改动
git diff origin/main...HEAD -- ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/EdgeBounceModel.swift
```
```bash
# 0 手势契约改动
git diff origin/main...HEAD -- ios/Contracts/Sources/KlineTrainerContracts/ChartEngine/ChartGestureArbiter.swift
```

**判定**：三条命令均无输出 → ✅；出现任意 diff 行 → ❌。

---

## 评审 APPROVE 落账（opus 4.8 xhigh 对抗性 review 代 codex，per user 指示）

- **Spec review R1 = APPROVE**：reviewer 实编验证橡皮筋公式性质 / dragRaw 反拖解绕 / D3 strand 真实 + 弹回路径 / 单边不变量 / 零渲染。0C/0H，2 Low 折入 plan。
- **Plan review R1（NEEDS-ATTENTION）→ R2（APPROVE）**：R1 识别 1 High（asymptote 阈值 790 数学错→修 785，实 788.53）+ 1 Medium（Step-2 fail-first 分类混淆）+ 2 Low；R2 独立复验三修复正确 + 承重事实全复确认（mainW=800/maxOffset=710/弹簧 frame 37 settle）+ 0 新缺陷。plan 收敛。
- **Subagent-driven 两阶段 review**：spec-compliance = **YES**（9/9 合规，1 Minor 注释恢复已修）；code-quality = **APPROVE**（0C/0I，2 Minor robustness/perf 留记）。
- **Verification**：host **1085 tests / 149 suites / 0 failures**；Mac Catalyst build-for-testing **TEST BUILD SUCCEEDED + 0 error/warning（GATE PASS）**；行为中性（render/physics/arbiter 空 diff）。
- **Final overall review = READY TO MERGE: YES**：独立重跑 1085/0 + 全面 correctness hunt（offset<0 不可达 / 无 min==max 误弹 / dragRaw 生命周期闭合）+ 行为中性 + governance/honesty，0C/0I/2 Minor（ship-acceptable）。
- **评审通道**：本 PR trust-boundary 改 `ios/**/*.swift`，codex 配额耗尽 → opus 4.8 xhigh 代 `codex:adversarial-review`；merge 经 user TTY `attest-override` + `--admin` bypass 缺失 `codex-verify-pass`（Catalyst CI 真绿不绕）。
