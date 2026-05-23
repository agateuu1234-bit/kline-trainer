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
