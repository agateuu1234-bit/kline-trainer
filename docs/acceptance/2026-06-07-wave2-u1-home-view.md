# 验收清单 — Wave 2 顺位 8：U1 HomeView（view-only shell）

**PR 性质**：业务模块（iOS UI 展示层）。新增 `HomeContent`（纯值格式化）+ `HomeView`（薄 SwiftUI 壳）；coordinator 接线/路由归顺位 11。
**改动文件**：3 个 `.swift`（2 生产 + 1 测试）+ 1 plan + 1 spec + 1 本验收文档。无既有文件改动。
**执行方式**：每项「操作 / 期望 / 判定」。非编码人员逐项照命令执行、对照期望勾选 ☐。`swift`/`xcodebuild` 命令在 `ios/Contracts` 目录下运行。

## 一、总闸门

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift build 2>&1 \| tail -2` | 末行 `Build complete!` | ☐ |
| 2 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | 末行 `Test run with <N> tests in <M> suites passed`，含 `0 failures` | ☐ |
| 3 | `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 \| tail -3` | 出现 `** TEST BUILD SUCCEEDED **` | ☐ |
| 4 | `grep -n -e fatalError -e TODO -e FIXME ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift; echo "exit=$?"` | 无输出，`exit=1`（无占位。用多 `-e` 而非 `\|` alternation：避免 markdown 表格转义与 ERE/BRE 歧义导致空洞守卫） | ☐ |

## 二、view-only 守卫

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 5 | `grep -n -e TrainingSessionCoordinator -e SettingsStore -e DownloadAcceptanceRunner ios/Contracts/Sources/KlineTrainerContracts/UI/HomeView.swift ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift; echo "exit=$?"` | 无输出，`exit=1`（不引用运行时依赖，D1。多 `-e` 而非 `\|`：对真引用文件能 exit=0 抓到，守卫非空洞——已实证） | ☐ |
| 6 | `grep -cE "^import SwiftUI" ios/Contracts/Sources/KlineTrainerContracts/UI/HomeContent.swift` | 输出 `0`（HomeContent 无 `import SwiftUI` 语句，host 全测。锚 `^import` 排除注释行「不 import SwiftUI」的假匹配） | ☐ |

## 三、统计栏 / 按钮逐项（定向测试）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 7 | `cd ios/Contracts && swift test --filter winRateZeroGames 2>&1 \| tail -3` | `passed`（totalCount==0 胜率显示「—」非 0%） | ☐ |
| 8 | `cd ios/Contracts && swift test --filter winRateHalfBoundaryDiscriminates 2>&1 \| tail -3` | `passed`（1/8→13%、5/8→63%，锁 toNearestOrAwayFromZero） | ☐ |
| 9 | `cd ios/Contracts && swift test --filter totalCapitalZeroGameFallback 2>&1 \| tail -3` 与 `swift test --filter totalCapitalClearedSessionNoFallback 2>&1 \| tail -3` | 均 `passed`（零局回退「初始 10 万」；清零局不回退显示 ¥ 0.00） | ☐ |
| 10 | `cd ios/Contracts && swift test --filter buttonResuming 2>&1 \| tail -3` 与 `swift test --filter buttonStart 2>&1 \| tail -3` | 均 `passed`（有 pending→继续训练；无→开始训练） | ☐ |

## 四、历史列表逐项

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 11 | `cd ios/Contracts && swift test --filter historySorted 2>&1 \| tail -3` | `passed`（createdAt 从新到旧 + 同时间 id desc 兜底） | ☐ |
| 12 | `cd ios/Contracts && swift test --filter nilIdRecordSkipped 2>&1 \| tail -3` 与 `swift test --filter totalSessionsSourceIsolation 2>&1 \| tail -3` | 均 `passed`（id==nil 记录跳过不崩；总局次取 statistics 与 rows.count 解耦） | ☐ |
| 13 | `cd ios/Contracts && swift test --filter "profitAndRate" 2>&1 \| tail -4` | 全 `passed`（正/负/双零/混合零/ULP 精确串，红涨绿跌符号正确） | ☐ |
| 14 | `cd ios/Contracts && swift test --filter rowDateTimeCrossTimezone 2>&1 \| tail -3` | `passed`（同 createdAt 在 UTC 与 +8 落不同日期/小时，时区参数真生效） | ☐ |

## 五、视觉自检（可选，需 Xcode）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 15 | 在 Xcode 打开 `HomeView.swift`，运行 Canvas 预览「有历史 + 继续训练」 | 统计栏三字段 + 右上角齿轮 + 「继续训练」按钮 + 两条历史（茅台正红、平安银行负绿） | ☐ |
| 16 | 运行 Canvas 预览「空历史 + 空缓存」 | 「开始训练」按钮 + 居中「暂无训练记录」占位 | ☐ |
