# 验收清单 — Wave 2 顺位 11：生产组合根 + 路由接线 + 启动恢复

**PR 性质**：业务模块（iOS 集成层 / 末位 anchor）。新增 `AppRouter`（导航状态机，纯逻辑 host 全测）+ `AppRootView`（SwiftUI 根壳，Catalyst 编译）+ `AppContainer`/`AppConfig`（Persistence 组合根）+ 替换模板 `KlineTrainerApp.swift` 接生产依赖图 + `AppLaunchErrorView`（DB-fail 屏）+ pbxproj 接本地 SPM 包 + shared scheme + 删模板 `ContentView.swift`。
**改动文件**：6 生产 `.swift`（AppRouter/AppRootView/AppConfig/AppContainer/AppLaunchErrorView/KlineTrainerApp）+ 2 测试 + pbxproj + scheme + Package.resolved + plan + spec + 本验收文档；删 ContentView。
**执行方式**：每项「操作 / 期望 / 判定」。非编码人员逐项照命令执行、对照期望勾选 ☐。`swift`/`xcodebuild` 命令在仓库根的 `ios/Contracts`（或 `ios/KlineTrainer`）下运行。

## 一、总闸门

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 1 | `cd ios/Contracts && swift build 2>&1 \| tail -2` | 末行 `Build complete!` | ☐ |
| 2 | `cd ios/Contracts && swift test 2>&1 \| tail -2` | 末行 `Test run with 799 tests in 120 suites passed`，含 `0 failures` | ☐ |
| 3 | `cd ios/Contracts && xcodebuild build-for-testing -scheme KlineTrainerContracts -destination 'platform=macOS,variant=Mac Catalyst' 2>&1 \| tail -3` | 出现 `** TEST BUILD SUCCEEDED **` | ☐ |
| 4 | `grep -n -e fatalError -e TODO -e FIXME ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift ios/Contracts/Sources/KlineTrainerPersistence/AppContainer.swift; echo "exit=$?"` | 无输出，`exit=1`（生产代码无占位/fatalError；用多 `-e` 而非 `\|` alternation 避守卫空洞） | ☐ |

## 二、依赖图实例化（组合根）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 5 | `cd ios/Contracts && swift test --filter validConfig_buildsGraph 2>&1 \| tail -3` | `passed`（有效 config → `try AppContainer(config:)` 不抛，api/db/cache/settings/acceptance/coordinator/router 七依赖全实例化） | ☐ |
| 6 | `cd ios/Contracts && swift test --filter badDBPath_throws 2>&1 \| tail -3` | `passed`（DB 路径不可写 → `DefaultAppDB` 上抛 → AppContainer.init throws，整图不残留） | ☐ |
| 7 | `cd ios/KlineTrainer && xcodebuild build -scheme KlineTrainer -destination 'id=<本机 My Mac 的 device id>' CODE_SIGNING_ALLOWED=NO 2>&1 \| tail -3` | 出现 `** BUILD SUCCEEDED **`（app 真链接 KlineTrainerContracts/Persistence/GRDB/ZIPFoundation，组合根编译通过；device id 取自 `xcodebuild -showdestinations -scheme KlineTrainer`） | ☐ |

## 三、路由逐项（从启动可达训练/设置）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 8 | `cd ios/Contracts && swift test --filter loadHome_assembles 2>&1 \| tail -3` 与 `swift test --filter loadHome_emptyState 2>&1 \| tail -3` | 均 `passed`（有缓存/有记录 → hasCachedSets/非空；0 记录+无缓存+settings loadError 降级不崩） | ☐ |
| 9 | `cd ios/Contracts && swift test --filter startTraining_success 2>&1 \| tail -3` 与 `swift test --filter startTraining_noCache_error 2>&1 \| tail -3` | 均 `passed`（开始训练成功 → activeTraining 非 nil 且 mode==normal；无缓存集 → errorMessage 且不 push） | ☐ |
| 10 | `cd ios/Contracts && swift test --filter continue_noPending 2>&1 \| tail -3` | `passed`（无 pending → 不 push 训练页） | ☐ |
| 11 | `cd ios/Contracts && swift test --filter selectRecord_setsHistoryModal 2>&1 \| tail -3` | `passed`（点历史行 → activeModal=.history(对应 record)） | ☐ |
| 12 | `cd ios/Contracts && swift test --filter review_pushesReviewMode 2>&1 \| tail -3` | `passed`（复盘 → coordinator.review → push review 模式 engine + 关闭 modal） | ☐ |
| 13 | `cd ios/Contracts && swift test --filter exitTraining_clears 2>&1 \| tail -3` | `passed`（返回 → activeTraining=nil + 重载首页） | ☐ |

## 四、启动孤儿确认恢复 + 结算路由

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 14 | `cd ios/Contracts && swift test --filter launchRecovery_exactlyOnce 2>&1 \| tail -3` | `passed`（连调 `runLaunchRecovery()` 两次，`CountingAPIClient.confirmCount==1` 非 2——router `didRunLaunchRecovery` 门拦第二次重扫；confirm 抛 `.network(.offline)` 使 journal 行留 confirmPending，坏门会得 2 故守卫非空洞） | ☐ |
| 15 | `cd ios/Contracts && swift test --filter sessionEnded_normalShowsSettlement 2>&1 \| tail -3` | `passed`（Normal 结束 recordId → loadRecordBundle 取 record → activeModal=.settlement） | ☐ |
| 16 | `cd ios/Contracts && swift test --filter sessionEnded_normalNilError 2>&1 \| tail -3` | `passed`（Normal finalize 抛(nil) → errorMessage + activeTraining=nil） | ☐ |
| 17 | `cd ios/Contracts && swift test --filter sessionEnded_replayRetreat 2>&1 \| tail -3` | `passed`（Replay 结束(nil,mode==replay) → 直接回首页不弹结算，U2-R4 deferred PR11-R2） | ☐ |
| 18 | `cd ios/Contracts && swift test --filter sessionEnded_replayTearsDownReader 2>&1 \| tail -3` | `passed`（retreat 前调 endAfterSettlement → `coordinator.activeReader==nil`，证 reader 关闭不泄漏） | ☐ |
| 19 | `cd ios/Contracts && swift test --filter confirmSettlement_clears 2>&1 \| tail -3` | `passed`（结算确认 → endAfterSettlement + activeTraining/modal 清 + 重载） | ☐ |

## 五、回归（不破坏冻结模块）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 20 | `cd ios/Contracts && git diff --stat main..HEAD -- 'ios/Contracts/Sources/**' \| grep -vE "App/(AppRouter\|AppRootView)\.swift\|KlineTrainerPersistence/(AppConfig\|AppContainer)\.swift"; echo "exit=$?"` | 无其它 `Sources` 生产文件改动（仅新增 4 文件；冻结视图/E5/E6/P2 零改），`exit=1` | ☐ |
| 21 | `grep -cE "import KlineTrainerPersistence" ios/Contracts/Sources/KlineTrainerContracts/App/AppRouter.swift ios/Contracts/Sources/KlineTrainerContracts/App/AppRootView.swift` | 两文件均输出 `0`（Contracts 层不 import Persistence，模块边界守住） | ☐ |

## 六、从启动可达（手动运行时验收，需 Xcode + 设备/模拟器；运行时部分）

| # | 操作 | 期望 | 判定 |
|---|---|---|---|
| 22 | Xcode 打开 `ios/KlineTrainer/KlineTrainer.xcodeproj`，选 KlineTrainer scheme + My Mac(Designed for iPad)，配开发者账号签名后 Run | app 启动进首页（非模板 Hello World），无 crash | ☐ |
| 23 | 首页点齿轮 | 弹出设置面板（SettingsPanel） | ☐ |
| 24 | 首页点「开始训练」（前提：缓存有训练组；无则显示错误提示且不 crash） | push 进训练页（TrainingView，双 K 线区 + 交易按钮）；返回回首页 | ☐ |

**说明**：第六节运行时项需真实 Xcode 运行环境 + 训练组数据 + 签名，属本机手动验收；CI 不覆盖 app target（PR11-R3）。第 1-21 项（host + Catalyst 编译 + 单元行为）为自动闸门，已本地全绿。

## 七、residuals（本 PR 显式遗留，非缺陷）

| 编号 | 内容 | 处置 |
|---|---|---|
| PR11-R1 | 生产 `backendBaseURL` = placeholder `http://kline-trainer.local` | 后端 NAS 部署后替换；download/reserve 真实网络路径在 NAS 上线前不通（本就 out-of-scope，outline §六 W1-R1/R2） |
| PR11-R2 | Replay 结束结算窗（U2-R4）deferred | retreat 决策：replay 结束直接回首页。忠实实现需触碰冻结 E5/E6/SettlementView（surfacing meta），留后续 anchor |
| PR11-R3 | app target 无 CI 构建守护 | Catalyst CI 仅 build Contracts scheme；app 接线靠本地 `xcodebuild -scheme KlineTrainer` + 第六节手动运行时验收兜底 |
