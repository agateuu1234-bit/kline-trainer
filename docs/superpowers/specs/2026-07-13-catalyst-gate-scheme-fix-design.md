# Catalyst 必需门修复：scheme 用错 + 闸门 grep 逻辑坏

- 日期：2026-07-13
- 类别：治理 / CI（trust-boundary：`.github/workflows/**`）
- 影响文件：`.github/workflows/catalyst-build.yml`（单文件）
- 相关：`project_ci_required_checks_broken`（memory）、`docs/superpowers/specs/2026-07-12-ruleset-required-checks-cleanup-design.md`（PR #143）

## 1. 问题陈述

`catalyst-build.yml` 的 job **`Mac Catalyst build-for-testing on macos-15`** 是 ruleset `15660830` 六个必需状态检查之一。它半年来一直报绿，但**从未验证过任何测试代码**。

### 根因 A：scheme 用错（本次的主因）

workflow 第 46 行：

```
xcodebuild build-for-testing -scheme KlineTrainerContracts ...
```

`KlineTrainerContracts` 是 `ios/Contracts/Package.swift` 第 8 行 `.library(...)` 产品对应的 **library scheme**。SwiftPM 生成的 library scheme 的 test / build-for-testing 动作**不包含任何 testTarget**，因此 `KlineTrainerContractsTests` 从未被编译。

**实证**（划线 P1b-1a-i，2026-07-12）：implementer 在 CI 构建日志里 grep `KlineTrainerContractsTests`，**结果全空**。同一批代码里有一处 `DrawingObject(...)` 关键字参数顺序写反（`colorToken` 排在 `thickness` 前，与 init 声明相反 → Swift 编译失败），而：

- host 上的 `swift test`：该文件被 `#if canImport(UIKit)` 跳过 → **不报**
- Catalyst 门：根本没编译测试 target → **不报**

→ UIKit-gated 的测试**两头落空**，一个真实的编译错误可以一路绿灯进 main。

正确 scheme 是 SwiftPM 自动生成的 package scheme **`KlineTrainerContracts-Package`**（`xcodebuild -list` 实测存在，与 `KlineTrainerContracts` / `KlineTrainerPersistence` / `GRDB-Package` 并列）。

### 根因 B：闸门 grep 逻辑坏（实测新发现，必须同时修）

workflow 第 49-53 行的闸门：

```
grep -F "** TEST BUILD SUCCEEDED **" ... || exit 1
! grep -E "(^|[[:space:]])(error|warning):" ... || exit 1
```

这是对**整份日志**做裸文本扫描。今天不出事，只是因为日志里从来没有测试的**运行期**输出。一旦测试真跑起来，xctest 进程会打印：

```
2026-07-13 23:12:41.728 xctest[4556] [error] CoreData: error: Failed to create NSXPCConnection
```

本地实测在一次 **`** TEST SUCCEEDED **`、exit 0** 的成功运行里出现 **8 条**这样的行（headless 环境的无害噪声）。裸扫 `error:` 会把它们当成编译错误 → **必需门在一次成功构建上误判为红 → PR 死锁**。

→ 结论：**只换 scheme 会立刻把必需门打红**。scheme 与闸门判据必须在同一个 PR 里一起改。

## 2. 本地实证（设计依据，非推演）

命令：

```
cd ios/Contracts
xcodebuild test -scheme KlineTrainerContracts-Package \
  -destination 'platform=macOS,variant=Mac Catalyst' \
  -only-testing:KlineTrainerContractsTests
```

结果：

| 观测项 | 结果 |
|---|---|
| 退出码 | `0` |
| 成功标记 | `** TEST SUCCEEDED **` |
| swift-testing | `Test run with 1407 tests in 184 suites passed after 1.396 seconds.` |
| XCTest | `Executed 90 tests, with 0 failures` |
| UIKit-gated 套件是否真执行 | 是：`UIChartPalette` / `KLineView 编译反射` / `ChartContainerView 布局重算` / `drawDrawings` 均出现 started+passed |
| `KlineTrainerContractsTests` 是否编译 | 是（日志 652 次命中；对比旧 scheme = 0 次） |
| `KlineTrainerPersistenceTests` | 被**编译**（206 次命中），但因 `-only-testing` 不**执行** |
| 冷构建墙钟 | 约 3 分 40 秒（含 GRDB / ZIPFoundation 包解析） |

诊断清单（59 条唯一的 `error:`/`warning:` 命中行）：

| 归属 | 条数 | 说明 |
|---|---|---|
| `ios/Contracts/Sources/` | **0** | 生产代码今天真的零警告 |
| GRDB / ZIPFoundation（SourcePackages） | **0** | 第三方依赖不产生命中 |
| `ios/Contracts/Tests/` | 48 | 38 条=调用我们自己已废弃的 `saveWorking`/`commitSaved`；5 条=ZIPFoundation 废弃初始化器；2 条=non-Sendable 捕获；3 条=琐碎 |
| 运行期噪声 / 构建系统 | 11 | 8 条 CoreData NSXPCConnection + AppIntents metadata 等 |

## 3. 设计

单文件改动：`.github/workflows/catalyst-build.yml`。

### 3.1 构建命令

- scheme：`KlineTrainerContracts` → **`KlineTrainerContracts-Package`**
- 动作：`build-for-testing` → **`test`**（真编译 + 真执行）
- 执行范围：**`-only-testing:KlineTrainerContractsTests`**

**为何只跑 Contracts 测试**：`-only-testing` 只限制**执行**，`KlineTrainerPersistenceTests` 仍会被**编译**（实证 206 次命中）→ 持久层测试的"能否编译"覆盖是白送的。而**不执行**它，就不把 GRDB/SQLite 的运行时行为引入这个必需门（这个门的职责是守 Catalyst 编译+UI 层测试；持久层的运行时覆盖由 host `swift test`（`swift-contracts-smoke.yml`）承担）。

### 3.2 闸门判据（逐条给出判据与理由）

| # | 判据 | 失败即红？ | 理由 |
|---|---|---|---|
| G1 | `xcodebuild` 退出码 == 0（`set -o pipefail` + 管道到 tee） | 是 | 权威的成败信号；今天已有，保留 |
| G2 | 日志含 `** TEST SUCCEEDED **` | 是 | 旧标记 `** TEST BUILD SUCCEEDED **` 在 `test` 动作下不再出现，必须换 |
| G3 | **编译器错误**：命中 `<文件>.swift:<行>:<列>: error:` | 是 | 锚定编译器诊断格式，**运行期噪声（CoreData 那 8 条）进不来** |
| G4 | **生产代码警告**：`ios/Contracts/Sources/**` 下命中 `.swift:行:列: warning:` | 是 | 今天真为 0 → 门一上来就是绿的**真棘轮**：新增任何一条生产代码警告即拦 |
| G5 | **测试代码警告**：`ios/Contracts/Tests/**` 下的警告 | **否**（只打印计数 + 明细） | 48 条为既有技术债，本 PR 不制造、也不修（见 §4） |
| G6 | **自证：测试 target 真被编译** — 日志含 `KlineTrainerContractsTests` | 是 | 见下 |
| G7 | **自证：测试真被执行** — swift-testing 汇总行 `Test run with <N> tests in <M> suites passed`，且 N > 0 | 是 | 见下 |
| G8 | **自证：UIKit-gated 测试真被编译** — 日志含 `DrawDrawingsDispatchTests.swift` | 是 | 见下 |

**G6/G7/G8 是本设计的核心，不是装饰。** 这次事故的本质是**一个报绿但什么都不验证的门**。如果只改 scheme 而不加自证断言，将来任何人（或任何工具升级）把 scheme 改回 library scheme、或让 `-only-testing` 过滤掉全部用例，**门会再次静默变绿**，而没有任何信号。G6 正是当年 implementer 用来发现空门的那个 grep；G8 直接编码"UIKit-gated 代码确实进了编译"这条不变量。

**G8 的已知脆弱性（明确接受）**：它硬编码文件名 `DrawDrawingsDispatchTests.swift`。若该文件被改名/删除，闸门会红。这是**有意的**——它会强制改名者当场重新指定一个 UIKit-gated 金丝雀文件，而不是让不变量悄悄消失。workflow 里写注释说明。

**`set -e` 陷阱**：所有负向断言一律写成 `if grep -q ...; then echo ...; exit 1; fi`，**不用** `! grep ... || exit 1`（该写法在 `set -e` 下是死闸门，本仓已踩过多次）。

### 3.3 超时

`timeout-minutes: 15` → **25**。本地冷构建约 3 分 40 秒，CI macos-15 更慢，且现在要多编译两个 test target + GRDB + ZIPFoundation。**必需门超时 = PR 死锁**，这个余量是廉价保险。

### 3.4 显式不改的东西

- **job 显示名保持 `Mac Catalyst build-for-testing on macos-15` 不变** → ruleset **零改动**，无 PR 死锁窗口。代价：名字里的 "build-for-testing" 与实际行为（真跑 test）名实不符 → 用 workflow 注释说明"名字为匹配 ruleset 必需 context 而冻结，实际行为见下"。（GitHub 按 job 显示名精确匹配必需 context，改名必须同步改 ruleset —— 本仓 PR #143 已被这点咬过。）
- 不修 §2 表中那 48 条测试代码警告（见 §4）
- 不碰 ruleset、不碰其它任何 workflow

## 4. 显式排除（scope）与后续待办

**不修 48 条测试警告的理由**：其中 38 条是调用我们**自己标记为废弃**的 `saveWorking`/`commitSaved`（废弃原因："默认写空 hiddenOriginalIds/unknownTopLevel"）。这些调用很可能是**故意**保留、用来覆盖老接口的向后兼容行为——本项目有明确的"App 可能公开上架 → 按公开发布标准对待前向/向后兼容"的约束。在一个 CI 修复 PR 里顺手改掉它们，等于**静悄悄删除兼容性覆盖**，且违反 CLAUDE.md §3（外科手术式改动）。

**后续待办（不在本 PR）**：
1. 清理 `Tests/` 48 条警告，之后把 G5 从"只统计"升级为"失败即红"（届时 G4/G5 合并为全局零警告棘轮）。其中 2 条 non-Sendable 捕获（`InMemoryCacheManagerTests.swift:250/:267`）值得优先看——本仓有"本地绿 ≠ CI 严格绿"的历史。
2. 本轮不动的其它 CI 债（见 `project_ci_required_checks_broken`）：3 个 paths-filtered smoke 改 always-post、修 `codex-review-verify`、`branch-protection-config-self-check` 升级为真校验 ruleset。

## 5. 验收标准（非 coder 可执行）

| # | 动作 | 期望 | 通过/失败 |
|---|---|---|---|
| 1 | 打开 PR，等 CI 跑完，点开 `Mac Catalyst build-for-testing on macos-15` 这个检查 | 是**绿的** | |
| 2 | 在该检查的日志里搜 `TEST SUCCEEDED` | 搜得到 `** TEST SUCCEEDED **` | |
| 3 | 在日志里搜 `Test run with` | 搜得到一行形如 `Test run with 1407 tests in 184 suites passed`，且数字**不是 0** | |
| 4 | 在日志里搜 `KlineTrainerContractsTests` | 搜得到（**修复前搜这个是一条都没有的** —— 这就是"门是空的"的直接证据） | |
| 5 | 在日志里搜 `GATE PASS` | 搜得到闸门通过行 | |
| 6 | 在日志里搜 `Tests/ 警告` | 看到测试代码警告的计数（一个数字，非 0），且检查**依然是绿的**（旧债不拦门） | |
| 7 | 故意验证（可选，由 Claude 执行并贴证据）：临时把某个 UIKit-gated 测试文件改坏一行，推到分支 | 该检查**变红**，日志里能看到那行的 `error:` | |

第 7 项是**变异验证**：它证明这个门现在真的能抓到"只有 Catalyst 才编译得到"的错误——也就是当初漏掉 `DrawingObject` 参数顺序错的那一类。没有这一项，我们只是把绿门换成了另一个绿门。

## 6. 风险

| 风险 | 缓解 |
|---|---|
| CI 上 `test` 比 `build-for-testing` 慢，可能超时 | timeout 15 → 25 分钟；本地冷构建 3 分 40 秒作为基线 |
| Catalyst 上 headless 跑 UI 相关测试可能挂/闪退 | 本地已实测全绿（1407 + 90 全过）；CI 若表现不同，会在本 PR 的 CI 上立刻暴露，而不是事后 |
| GRDB 的 git submodule（SQLiteCustom/src）解析失败 | 今天的 CI 已经在解析同一张包图并通过（旧 scheme 也解析全图）→ 非新增风险 |
| G8 金丝雀文件被改名导致误红 | 有意为之（见 §3.2）；workflow 注释写明改名时应如何更新 |
