# Wave 3 顺位 2 设计：app-target CI 守护 + 竖屏/窗口策略

**锚定**：Wave 3 outline（`docs/superpowers/specs/2026-06-09-wave3-outline-design.md`）§二 顺位 2 / Gate 治理轨（与顺位 1 RFC 真并行，文件集不相交：本锚碰 `.github/` + `project.pbxproj` + `scripts/governance/`，顺位 1 碰 `docs/`）。

**类型**：governance + infra。**0 业务代码 / 0 Swift 源改动**（仅 CI workflow + pbxproj build settings + governance 脚本 + 文档）。

**目标（residual close）**：
- **PR11-R3**：`KlineTrainer.xcodeproj` app target 当前无 CI 编译守护（现有 `catalyst-build.yml` 仅构建 `ios/Contracts` SwiftPM 包）。本锚补 app target build-for-running 守护并设为 required check，对顺位 3-12 实施 PR 强制（codex R1-F2）。
- **锁竖屏（codex R2-F3）**：app target pbxproj（Debug `:278-279` + Release `:311-312`）当前启用 Landscape——与 plan v1.5 L1232「v1 锁定竖屏」冲突。本锚改 orientation 为仅 Portrait。
- **iPad 窗口策略（codex R3-F3）**：pbxproj orientation 单独不足以锁 iPad 多任务（Stage Manager / Split View）窗口。本锚加版本无关的全屏锁定机制 + 文档化残留。

---

## 〇、起点核实（grep-first，2026-06-10 worktree 实测）

| 事实 | 证据 | 影响 |
|---|---|---|
| app target 是**单一 iOS application target**（无 test target） | `project.pbxproj` 唯一 `PBXNativeTarget` productType=`com.apple.product-type.application`；scheme `KlineTrainer.xcscheme` `<Testables>` 为空 | CI 用 `xcodebuild build`（**非** `build-for-testing`——无 testable） |
| app target **非 Mac Catalyst**（`SDKROOT=iphoneos`，无 `SUPPORTS_MACCATALYST`） | `project.pbxproj` 无 `SUPPORTS_MACCATALYST`；`TARGETED_DEVICE_FAMILY="1,2"` | CI 目标必须是 **iOS Simulator**（非 Catalyst destination） |
| app 依赖**本地 SwiftPM 包** `Contracts`（`relativePath=../Contracts`，产品 `KlineTrainerContracts`+`KlineTrainerPersistence`）+ **远程** GRDB | `project.pbxproj` `XCLocalSwiftPackageReference "Contracts"` / `XCRemoteSwiftPackageReference "GRDB"`；`Package.resolved` 已 commit | CI 能独立解析（本地包从仓库 + GRDB 从 GitHub，与现有 Catalyst CI 同款远程解析） |
| **本地构建命令已实证通过**（2026-06-10，Xcode 26.5 / iOS Sim SDK 26.5） | `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`（Debug-iphonesimulator）。**注（de-risk 边界，codex M2）**：此次验证的是**构建命令 + 包解析 + 免签名路径**（在**未改 pbxproj** 上跑）；**不**覆盖 Group B 提议的 orientation/`UIRequiresFullScreen` pbxproj 编辑。Group B 键的工具链接受性单独 de-risk（见下一行） | 构建命令 + 包解析 + 免签名 路径已验证可行 |
| **Group B 键工具链接受性已 de-risk**（2026-06-10） | `xcodebuild build ... CODE_SIGNING_ALLOWED=NO INFOPLIST_KEY_UIRequiresFullScreen=YES INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone=UIInterfaceOrientationPortrait INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad=UIInterfaceOrientationPortrait`（以命令行 override 模拟提议键，非 mutate pbxproj）→ 见 §五 R1 注的实测结果 | 确认 `INFOPLIST_KEY_UIRequiresFullScreen` + Portrait-only 是合法 build setting，生成 Info.plist 含对应键；plan 仍须在落 pbxproj 后本地复跑一次 |
| **构建产生良性非编译器 warning** | log 含 `appintentsmetadataprocessor[...] warning: Metadata extraction skipped. No AppIntents.framework dependency found.` | **关键 gate 设计约束**：catalyst-build 的 `! grep -E "(^\|[[:space:]])(error\|warning):"` 闸门会被此行**误判 fail**——app-build gate 不能照搬 no-warning 断言（见 §三.A 闸门设计） |
| 现有 ruleset required checks = **11 条**，全 `integration_id=15368`，`enforcement=active`，`bypass_actors` 仅 admin（`RepositoryRole id=5`） | `docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json` | 加 app-build = **第 12 条 = 真实 mutation**（非 1c 的 no-op 幂等）；须 user-TTY `--apply` post-merge |
| required-check 工具**硬编码单一** Catalyst context，**共 26 处** | grep `"Mac Catalyst build-for-testing\|CATALYST"` scripts/governance/+tests/scripts/governance/ = 26：`build-protection-put-payload.py`(5：含常量+逻辑)、`verify-required-checks.sh`(6：assert :70 + **diff :142 第二独立常量**)、`tests/scripts/governance/test-admin-runbook.sh`(1：`one_catalyst()` 断言「恰含一条 Catalyst」)、`test_build_payload.py`(2：builder 单测)、fixtures(多个含 Catalyst context 的 ruleset JSON) | Group C 须泛化为「必需 context 列表」**且同步全部 26 处 + 测试**（见 §三.C2；非「文案 only」） |
| 项目用 Xcode 26.5 撰写（`LastSwiftUpdateCheck=2640`），project-level `IPHONEOS_DEPLOYMENT_TARGET=26.4`，但 target-level=**17.6** | `project.pbxproj:255`(project Release) vs `:280/:313`(target) | target-level 覆盖 project-level → app 实际部署 17.6；`objectVersion=77`（Xcode 16 格式）→ runner Xcode 16 可解析。见 §五 风险 R1 |

**结论**：本锚是把 app target 纳入 CI 编译守护 + 锁竖屏/全屏 + 把守护设为 required check 强制下游。范围三组（≤3 子项），全部 0 业务代码。

---

## 一、范围（3 子项）

### Group A — app-target CI 编译守护（trust-boundary `.github/workflows/`）
新增 always-trigger workflow `.github/workflows/app-build.yml`：
- 触发：`on: pull_request` + `push: branches:[main]`，**无 paths filter**（沿用 catalyst-build H9 决议：paths filter → required check 在无关 PR 永不报告 → merge 死锁）。
- 构建：`xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' -derivedDataPath <tmp> CODE_SIGNING_ALLOWED=NO`。
- runner `macos-15`，runner 默认 Xcode + assert `Xcode >= 16`（镜像 catalyst-build，不硬编码 Xcode 路径）。
- `permissions: contents: read`；`actions/checkout` pin full SHA（镜像 catalyst-build trust-boundary hardening）。
- **job name = 新 required-check context = `iOS app build-for-running on macos-15`**（稳定标识符；required check 以 job name 匹配，命名定后不可改）。

### Group B — 锁竖屏 + iPad 全屏窗口锁（trust-boundary `**/project.pbxproj`）
- `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` + `_iPad` 改为仅 `UIInterfaceOrientationPortrait`（删 Landscape + PortraitUpsideDown），**Debug + Release 双 config**。
- 加 `INFOPLIST_KEY_UIRequiresFullScreen = YES`（Debug + Release）→ 关闭 iPad Split View / Slide Over / Stage Manager 多窗，使 app 恒全屏 + 尊重竖屏锁。
- **不改** `TARGETED_DEVICE_FAMILY`（保持 `1,2`，iPad 留在 scope，仅锁定；横屏 layout 适配是 §六排除项）。

### Group C — required-check 强制泛化（trust-boundary `scripts/governance/`；`codeowners_required_globs` → 须 user Approve）
**泛化是全 26 处 + 测试的真实改动，非「文案 only」（codex H2）**。`REQUIRED_CONTEXTS` 作单一真相来源（builder + verifier 两模式 + 测试共享），全部 26 处同步：
- `build-protection-put-payload.py`：`CATALYST_CONTEXT`（单值）→ `REQUIRED_CONTEXTS`（列表：Catalyst + app-build）。对列表中每个 context 幂等 ensure-present + 强制 `integration_id=15368` + 去重，**保留**现有单 context 的全部语义（修 any-source 漂移 / dedup / fail-closed 无 rsc 规则则拒新建 / 只读字段剥离 / 确定性序列化）。
- `verify-required-checks.sh`：assert（`:70`）+ **diff（`:142` 第二独立常量，易漏）** 两模式从「仅查 Catalyst」→「查 `REQUIRED_CONTEXTS` 全部在位 + 各自 `integration_id=15368`」。diff 打印器（`:146-155`）已泛型迭代 `des.items()`，但须测 add-one-of-two。
- `admin-configure-required-checks.sh`：泛化文案（Catalyst → app-target required checks）+ 成功消息；`preservation_ok` 的 `checks(desired) <= checks(actual)` 子集比已天然支持多 context（但须测 2-context）；no-op-skip `diff -q payload rollback` 对 add-context 正确（实测 DIFFERS → 会 PUT）。
- **测试 + fixtures**：`test-verify-required-checks.sh` + `test-admin-runbook.sh`（`one_catalyst()` → 断言两 context 均在位）+ `test_build_payload.py` + 相关 fixtures。新增用例须含 **partial-state**（Catalyst 在、app-build 缺）的 assert / diff / preservation_ok 路径——这是当前零覆盖的新代码路径，非仅「多 context happy / 缺其一 / 错 integration_id」。
- **实际 ruleset `--apply`（加第 12 条 context）= post-merge user-TTY admin 步骤**（真实 mutation，非 1c no-op）；本 PR 交付 runbook + evidence 模板（镜像 1c）。**cross-PR 时序见 §三.C1**。

### 交付文档
- 验收清单（中文非-coder 可执行）`docs/acceptance/2026-06-10-wave3-pr2-app-ci-orientation.md`。
- 运行时 runbook 条目（**旋转/窗口验证**——orientation 锁是否生效是 runtime 行为，CI build 守护不覆盖；归 user device/sim 验证，作顺位 13 阻塞依赖之一，对齐 outline §三.3）。
- post-merge admin runbook + redacted evidence 模板（user 跑 `--apply` 后回填，镜像 `docs/governance/2026-05-21-pr1c-required-checks-evidence.md`）。

---

## 二、组件 / 数据流 / 边界

- **CI build 守护**（Group A）：GitHub Actions on PR → `app-build` job 在 macos-15 解析包 + 编译 app target（iOS Sim） → gate 断言 → 报 status check（context = job name）。**只验证编译/链接通过**（does it build），**不**执行运行时、**不**验证 orientation 行为。
- **orientation/window 锁**（Group B）：编译期 build setting → 生成 Info.plist 键 → 运行时 iOS 读取限制方向 + 全屏。CI 仅验证「带这些键能编译过」；「真锁住竖屏 / iPad 不分屏」是运行时事实，归 runbook。
- **required-check 强制**（Group C）：纯函数 builder 算 desired payload（不发网络）→ admin runbook（user TTY）PUT ruleset → verifier assert。本 PR 改的是**工具 + 文档**；origin ruleset 状态由 user post-merge 改。

**单向边界**：A（CI）/ B（pbxproj）/ C（scripts）三组文件集互不相交；C 的 origin 副作用延后到 post-merge user TTY。三组无运行时耦合，可独立理解/审查。

---

## 三、关键决策（含备选 + 理由，供对抗 review）

### A. CI 守护设计

**A1. destination = iOS Simulator（generic），非 Mac Catalyst。**
- 理由：app target `SDKROOT=iphoneos` 无 `SUPPORTS_MACCATALYST` → 非 Catalyst app；强行 Catalyst destination 会 build 失败或需启用 Catalyst（= 产品改动，超范围）。
- 备选（拒）：real device（runner 无设备 + 需签名）；Mac Catalyst（同上，且与 Contracts 包的 Catalyst job 语义混淆）。

**A2. `xcodebuild build`，非 `build-for-testing`（满足 outline 「build-for-testing」mandate，非 scope drift；codex M3）。**
- 理由：app target 无 test target（`KlineTrainer.xcscheme:30-31` Testables 空）。`build-for-testing` 在无 testable 时退化为普通 build 且徒增歧义；`build` 语义准确。outline §二 顺位 2 行字面写「build-for-testing」，本锚以 `build` 满足其**意图**（app target 进 CI 编译守护）——空 testables 事实使二者等价，故为 mandate-compliant 而非删 scope。job name 用 `build-for-running` 反映 `build` action（对仗 Catalyst job 的 `build-for-testing`）。

**A3. 新独立 workflow，非给 catalyst-build.yml 加 job。**
- 理由：(1) 独立 required-check context 命名清晰；(2) 失败隔离（app 编译失败不污染 Catalyst gate 语义）；(3) 镜像现有「一 guard 一 workflow」模式。
- 备选（拒）：加 job 到 catalyst-build.yml——会让一个 workflow 报两个 check，复杂化 H9 已解的 always-trigger 语义。

**A4. always-trigger（无 paths filter）。**
- 理由：H9 教训（`docs/governance/2026-05-17-wave0-signoff-ledger.md` H9）——paths-filtered workflow 的 required check 在不匹配 PR 永不报告 → PR 死锁。app-build 设为 required 后必须每 PR 必跑必报。

**A5. gate = `** BUILD SUCCEEDED **` 在位 + 无 `** BUILD FAILED **` + 无编译/链接 `error:`；不做 blanket no-warning 断言。**
- **实测依据**：app target build 必产 `appintentsmetadataprocessor ... warning:`（SwiftUI app 无 AppIntents.framework 的良性工具 warning，确定性出现）。catalyst-build 的 `! grep -E "(^|[[:space:]])(error|warning):"` 会被此行**误 fail**。
- 决策：app-build gate 是**编译/链接守护**（能否 build），不是 warning-policy gate。Swift 源 warning 纪律仍由 Contracts 包侧（catalyst-build + swift-contracts-smoke）覆盖——app shell 仅 `KlineTrainerApp.swift` + `AppLaunchErrorView.swift` 两文件薄壳。
- **gate 三断言（精确 pin，codex M1，plan/impl 不得漂移）**：
  1. `grep -F "** BUILD SUCCEEDED **" log`（正向，必须在位；不在位 → exit 1）；
  2. `if grep -F "** BUILD FAILED **" log; then exit 1; fi`（显式拒 BUILD FAILED，防 SUCCEEDED 缺失但 grep#1 漏判的歧义）；
  3. `if grep -E "(^|[[:space:]])error:" log; then exit 1; fi`（**anchored ERE，仅 `error:`，不含 `warning:`**——锚定行首/空白前缀，避开 `AppLaunchErrorView.swift` 文件名等 `error` 子串误判；捕获 `clang: error:`/`ld: error:`/Swift `error:`）。
  - 全部写成 `if grep ...; then exit 1; fi`（避免 `set -e` 下 `! grep` 死闸门，per 历史 `feedback_acceptance_grep_anchoring`）。**不**做 blanket `warning:` 断言（appintents 良性 warning 会误 fail）。
- 备选（拒）：精确排除 appintents 行后仍 blanket no-warning——脆弱（工具噪声签名可变）+ 负向 grep 链易错。若未来要 warning 纪律，应在 pbxproj 设 `SWIFT_TREAT_WARNINGS_AS_ERRORS`（让编译器自报 `error:`），而非 CI grep——超本锚范围。

**A6. runner 默认 Xcode + assert `>=16`（镜像 catalyst-build）。**
- 见 §五 风险 R1（项目 Xcode 26.5 撰写 vs runner Xcode 版本）。

### B. orientation / iPad 窗口

**B1. Portrait only（删 Landscape + PortraitUpsideDown）。**
- 理由：plan v1.5「v1 锁定竖屏」；「锁竖屏」惯例 = 仅正立 Portrait。
- 备选（拒）：保留 PortraitUpsideDown——iPhone 无此方向；iPad 保留它会让设备倒置仍旋转，违「锁定」直觉。

**B2. iPad 窗口锁 = `UIRequiresFullScreen=YES`（机制），承认运行时残留。**
- 机制：`UIRequiresFullScreen=YES` 关闭 iPad Split View / Slide Over / Stage Manager 缩放 → app 恒全屏 → orientation 锁可靠生效。这是**版本无关的 build-setting 机制**。
- **与 outline「版本感知」措辞调和（codex L1）**：outline §三.2 写「版本感知 iPad 窗口/旋转策略」。本锚交付的锁本身**无需 per-version 代码**（`UIRequiresFullScreen` 一个 build setting 跨 iPadOS 版本一致生效）——即「版本感知」需求被「版本无关机制」满足：不必为不同 iPadOS 写分支。唯一**随版本变**的是「Stage Manager 是否仍泄漏窗口行为」这一**检测**，归 runtime runbook（见下）。
- **承认残留**：最新 iPadOS + 最新 SDK 下 Stage Manager 对部分 app 行为可能仍非完全受 `UIRequiresFullScreen` 约束（codex R3-F3 原意）。本锚交付 build-setting 锁 + runbook 运行时验证条目；若 runbook 实测显示 iPad 窗口/方向泄漏，更深的运行时锁（scene/orientation delegate override）作下游 follow-up（非本锚）。诚实标注，不 claim「绝对锁死所有 iPadOS 版本」。
- 备选（拒）：降 `TARGETED_DEVICE_FAMILY` 为 iPhone-only（`1`）——outline 明确 iPad 留 scope（顺位 2 owns iPad 窗口策略），不在本锚改设备族。

**B3. 验证 = runtime runbook，非 CI。**
- 理由：CI build 守护只证「带键能编译」，不证「运行时真锁竖屏」。orientation/窗口是运行时行为 → runbook 条目（user device/sim 验证），作顺位 13 阻塞依赖。

### C. required-check 强制

**C1. 工具泛化在本 PR；origin ruleset `--apply` 延后 post-merge user TTY。**
- 理由：镜像 1b（工具）+ 1c（admin execute），本锚压缩为一锚（工具已存在，仅泛化）。加第 12 条 context = 真实 mutation，须 user admin scope；Claude 不碰 origin ruleset。
- chicken-egg（同-PR）：app-build.yml 在本 PR 加入 → 因 always-trigger，job 在本 PR 自身就运行报 status（但**尚未** required，因 ruleset 未 apply）→ 本 PR 不被自己的新 check 阻塞 merge。merge 后 user 跑 `--apply` → 对顺位 3-12 生效。
- **cross-PR 死锁防护（codex H1，关键）**：把第 12 条 required context 加入 ruleset 后，**任何 head 推送早于 main 含 app-build.yml 的 open PR**（典型：与本锚真并行的**顺位 1 RFC**，其 `docs/`-only 分支无 app-build.yml → 新 job 永不在其上运行 → 该 check 永久「Expected — waiting for status」→ 非 admin 无法 merge）会被卡死——正是 §三.A4 引用的 H9 失效模式在 cross-PR 维度的重演。**runbook 硬约束**：`--apply` 只能在「所有其它 in-flight PR 已 rebase 到含 app-build.yml 的 main」**或**「顺位 1 已先 merge」之后执行。对齐 outline §二「一锚 merge，其余 worktree rebase onto main」纪律——本锚新增的仅是 `--apply` 必须落在该 rebase 之后这一时序点。admin bypass 可临时解卡但不作正常路径。

**C2. builder 泛化保留全部既有不变量。**
- `REQUIRED_CONTEXTS` 列表中每个 context：ensure-present + `integration_id=15368` + 去重；无 rsc 规则仍 fail-closed 拒新建；只读字段仍剥离；确定性序列化（sort_keys）保幂等可 diff。verifier 的 bypass-仅-admin / 绑默认分支 / active fail-closed 等不变量**不动**。

---

## 四、Residual 映射（本锚 owns）

| Residual | 来源 | 本锚处理 |
|---|---|---|
| PR11-R3 app target 无 CI 构建守护 | wave2-completion §三 / outline §四 | Group A app-build.yml + Group C 设 required |
| 锁竖屏（pbxproj 启用 Landscape vs plan「锁竖屏」） | codex R2-F3 | Group B Portrait only |
| iPad 多任务/窗口竖屏（orientation 单独不足以锁 Stage Manager/Split View） | codex R3-F3 | Group B `UIRequiresFullScreen=YES` + runbook 残留标注 |
| 旋转/窗口运行时验证 | outline §三.3 | runtime runbook 条目（顺位 13 阻塞依赖之一） |

---

## 五、风险

**R1（中）：runner Xcode 版本 vs 项目 Xcode 26.5 撰写。** 项目 `LastSwiftUpdateCheck=2640`（Xcode 26.4）、project-level 部署 26.4。**缓解证据**：(a) target-level 部署=17.6（覆盖 project-level，app 实际按 17.6 编译）；(b) `objectVersion=77` 是 Xcode 16 格式，runner Xcode 16 可解析；(c) Contracts 包（app 的真实逻辑依赖）已在 macos-15 现有 Catalyst CI 用 Xcode≥16 编译通过；(d) app shell 仅两薄文件无 iOS 26 专属 API。**残留**：本地只能用 Xcode 26.5 验证命令正确性，runner Xcode 版本的最终裁决在**首次 CI 运行**。若首跑因 SDK/部署目标失败，escalate 选项：(i) workflow 内 `xcode-select` 切换到镜像上更高 Xcode（若 macos-15 镜像已预装）；(ii) runner 升 `macos-26`（若 GitHub 已提供）。plan 须在首次 CI 绿前不 claim 守护就绪。

**Group B 键 de-risk 实测结果（2026-06-10，闭合 codex M2）**：以命令行 override 模拟提议键构建（未 mutate pbxproj）→ `** BUILD SUCCEEDED **`；inspect 生成的 `KlineTrainer.app/Info.plist`：`UIRequiresFullScreen => true`、`UISupportedInterfaceOrientations~ipad => [UIInterfaceOrientationPortrait]`、`UISupportedInterfaceOrientations~iphone => [UIInterfaceOrientationPortrait]`。证 `INFOPLIST_KEY_UIRequiresFullScreen` + Portrait-only 是合法 build setting 且生成预期 plist 键。**残留**：override 模拟 ≠ 真实 pbxproj 编辑（键拼写/config 归属可能不同）→ plan 落 pbxproj 后须本地复跑一次 build + 复查 plist。

**R2（低）：`UIRequiresFullScreen` 在最新 iPadOS Stage Manager 的有效性。** 见 B2——已作残留标注 + runbook 验证 + 下游 follow-up，非本锚阻塞。

**R3（低，codex H3 已校正）：Group C 改动落在 `codeowners_required_globs`（`scripts/**` + `.github/**` + pbxproj 亦在 `trust_boundary_globs`）覆盖路径。** 校正：本仓 ruleset 的 `pull_request` 规则 `require_code_owner_review=false` + `required_approving_review_count=0`（核实 `2026-05-21-pr1c-ruleset-snapshot.redacted.json`）——故 GitHub **不**机械强制 code-owner approval；CODEOWNERS 在本仓是 advisory。真实 trust-boundary 强制 = required status check `codex-review-verify`（+ 同类 codex check）+ admin merge 纪律（满足 CLAUDE.md backstop #1「review verdict 为 required status check，非 self-attested」）。**「user Approve」是 PROJECT 治理规则**（`workflow-rules.json` codeowners_required_globs，由 process + 上述 codex required check + admin 纪律执行），**非 GitHub code-owner-review 机制**。merge ceremony 按此 process 规则处理（user TTY），非依赖一个本仓已关闭的 GitHub gate。

---

## 六、不在本锚

- **iPad 横屏 layout 适配功能**（真正支持横屏 UI）——§outline §六排除项；本锚仅 owns**锁定**（Portrait + 全屏）。
- **运行时验收执行**——user device/sim 职责；本锚交付 runbook 条目，执行作顺位 13 阻塞。
- **任何业务/Swift 源改动**——本锚 0 业务代码。
- **更深运行时 orientation 锁**（scene/orientation delegate override）——仅当 runbook 实测显示泄漏才作下游 follow-up。
- **将其他现有 informational workflow（如 `branch-protection-config-self-check`）转 required**——非本锚 scope。

---

## 七、验收判据（outline）

1. `.github/workflows/app-build.yml` 存在，always-trigger（无 paths filter），job name = `iOS app build-for-running on macos-15`，build iOS Simulator destination，gate = 三断言（§三.A5 pin：`grep -F "** BUILD SUCCEEDED **"` 在位 + 无 `** BUILD FAILED **` + 无 anchored `error:`；**非** blanket no-warning）。
2. `project.pbxproj` Debug + Release 双 config：orientation 仅 Portrait（无 Landscape / UpsideDown）+ `UIRequiresFullScreen=YES`。
3. `build-protection-put-payload.py` + `verify-required-checks.sh` 泛化为多 context（Catalyst + app-build），governance 脚本测试全绿（含新增多-context 用例）。
4. 首次 CI：`iOS app build-for-running on macos-15` job 报告且**绿**（编译守护实证）+ 既有 11 check 不回归。
5. 中文非-coder 验收清单 + 运行时 runbook 条目 + post-merge admin runbook/evidence 模板交付。
6. grep gate：本锚不残留未决措辞；required-check 工具无遗漏的硬编码单-Catalyst 路径。

---

## 八、变更日志

| 日期 | 版本 | 变更 |
|---|---|---|
| 2026-06-10 | v1 (draft) | 起草；3 子项（A app-build CI / B orientation+全屏 / C required-check 泛化）；含 worktree 实测 de-risk（本地 build SUCCEEDED + appintents warning gate 发现 + 现有 11 check snapshot）；待 opus 4.8 xhigh 对抗 review |
| 2026-06-10 | v2 (opus 4.8 xhigh 对抗 review R1 修，3H+2M+1L 全收) | **H1**：cross-PR required-check 死锁（加第 12 条 context 后，并行顺位 1 RFC 的 `docs/`-only 分支无 app-build.yml → 永久 Expected）→ §三.C1 加 runbook 硬约束（`--apply` 须在其它 in-flight PR rebase 后 / 顺位 1 先 merge 后）；**H2**：Group C 泛化被低估为「文案 only」→ grep 实证 26 处（含 verify `:142` 第二 diff-mode 常量 + `test-admin-runbook.sh one_catalyst()` + `test_build_payload.py` + fixtures）→ §〇/§一/§三.C2 改为全 26 处 + 单一真相 `REQUIRED_CONTEXTS` + partial-state 测试覆盖；**H3**：R3「CODEOWNERS 机械强制 user Approve」事实错误（ruleset `require_code_owner_review=false`/`count=0`）→ 校正为 advisory + 真实强制 = `codex-review-verify` required check + admin 纪律（PROJECT 规则 vs GitHub 机制）；**M1**：gate 三断言精确 pin（SUCCEEDED 在位 + 无 FAILED + anchored `error:`，非 blanket no-warning）；**M2**：补 Group B 键 de-risk 实测（override 构建 SUCCEEDED + 生成 plist `UIRequiresFullScreen=true`+Portrait-only ~ipad/~iphone），§〇 de-risk 边界改诚实；**M3**：`build` 满足 outline「build-for-testing」mandate（空 testables 等价）；**L1**：版本感知措辞调和 |
