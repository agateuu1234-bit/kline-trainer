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
| **本地构建已实证通过**（2026-06-10，Xcode 26.5 / iOS Sim SDK 26.5） | `xcodebuild build -project ios/KlineTrainer/KlineTrainer.xcodeproj -scheme KlineTrainer -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO` → `** BUILD SUCCEEDED **`（Debug-iphonesimulator） | 构建命令 + 包解析 + 免签名 路径已验证可行 |
| **构建产生良性非编译器 warning** | log 含 `appintentsmetadataprocessor[...] warning: Metadata extraction skipped. No AppIntents.framework dependency found.` | **关键 gate 设计约束**：catalyst-build 的 `! grep -E "(^\|[[:space:]])(error\|warning):"` 闸门会被此行**误判 fail**——app-build gate 不能照搬 no-warning 断言（见 §三.A 闸门设计） |
| 现有 ruleset required checks = **11 条**，全 `integration_id=15368`，`enforcement=active`，`bypass_actors` 仅 admin（`RepositoryRole id=5`） | `docs/governance/2026-05-21-pr1c-ruleset-snapshot.redacted.json` | 加 app-build = **第 12 条 = 真实 mutation**（非 1c 的 no-op 幂等）；须 user-TTY `--apply` post-merge |
| required-check 工具**硬编码单一** `CATALYST_CONTEXT` | `build-protection-put-payload.py:19/49/56/57/60`；`verify-required-checks.sh:70/142`（assert+diff） | Group C 须泛化为「必需 context 列表」 |
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
- `build-protection-put-payload.py`：`CATALYST_CONTEXT`（单值）→ `REQUIRED_CONTEXTS`（列表：Catalyst + app-build）。对每个 context 幂等 ensure-present + 强制 `integration_id=15368` + 去重，**保留**现有单 context 的全部语义（修 any-source 漂移 / dedup / fail-closed 无 rsc 规则则拒新建）。
- `verify-required-checks.sh`：assert + diff 模式从「仅查 Catalyst」→「查 `REQUIRED_CONTEXTS` 全部在位 + 各自 `integration_id=15368`」。
- `admin-configure-required-checks.sh`：仅泛化文案（Catalyst → app-target required checks）；逻辑不变（调 builder/verifier）。
- governance 脚本测试 + fixtures：加多 context happy / 缺其一 / 错 integration_id 用例。
- **实际 ruleset `--apply`（加第 12 条 context）= post-merge user-TTY admin 步骤**（真实 mutation，非 1c no-op）；本 PR 交付 runbook + evidence 模板（镜像 1c）。

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

**A2. `xcodebuild build`，非 `build-for-testing`。**
- 理由：app target 无 test target（scheme Testables 空）。`build` 语义准确；`build-for-testing` 亦可但徒增歧义。

**A3. 新独立 workflow，非给 catalyst-build.yml 加 job。**
- 理由：(1) 独立 required-check context 命名清晰；(2) 失败隔离（app 编译失败不污染 Catalyst gate 语义）；(3) 镜像现有「一 guard 一 workflow」模式。
- 备选（拒）：加 job 到 catalyst-build.yml——会让一个 workflow 报两个 check，复杂化 H9 已解的 always-trigger 语义。

**A4. always-trigger（无 paths filter）。**
- 理由：H9 教训（`docs/governance/2026-05-17-wave0-signoff-ledger.md` H9）——paths-filtered workflow 的 required check 在不匹配 PR 永不报告 → PR 死锁。app-build 设为 required 后必须每 PR 必跑必报。

**A5. gate = `** BUILD SUCCEEDED **` 在位 + 无 `** BUILD FAILED **` + 无编译/链接 `error:`；不做 blanket no-warning 断言。**
- **实测依据**：app target build 必产 `appintentsmetadataprocessor ... warning:`（SwiftUI app 无 AppIntents.framework 的良性工具 warning，确定性出现）。catalyst-build 的 `! grep -E "(^|[[:space:]])(error|warning):"` 会被此行**误 fail**。
- 决策：app-build gate 是**编译/链接守护**（能否 build），不是 warning-policy gate。Swift 源 warning 纪律仍由 Contracts 包侧（catalyst-build + swift-contracts-smoke）覆盖——app shell 仅 `KlineTrainerApp.swift` + `AppLaunchErrorView.swift` 两文件薄壳。
- gate 断言用正向 grep（`grep -F "** BUILD SUCCEEDED **"`）+ 负向 `error:` 检查写成 `if grep ...; then exit 1`（避免 `set -e` 下 `! grep` 死闸门，per 历史 `feedback_acceptance_grep_anchoring`）。
- 备选（拒）：精确排除 appintents 行后仍 blanket no-warning——脆弱（工具噪声签名可变）+ 负向 grep 链易错。若未来要 warning 纪律，应在 pbxproj 设 `SWIFT_TREAT_WARNINGS_AS_ERRORS`（让编译器自报 `error:`），而非 CI grep——超本锚范围。

**A6. runner 默认 Xcode + assert `>=16`（镜像 catalyst-build）。**
- 见 §五 风险 R1（项目 Xcode 26.5 撰写 vs runner Xcode 版本）。

### B. orientation / iPad 窗口

**B1. Portrait only（删 Landscape + PortraitUpsideDown）。**
- 理由：plan v1.5「v1 锁定竖屏」；「锁竖屏」惯例 = 仅正立 Portrait。
- 备选（拒）：保留 PortraitUpsideDown——iPhone 无此方向；iPad 保留它会让设备倒置仍旋转，违「锁定」直觉。

**B2. iPad 窗口锁 = `UIRequiresFullScreen=YES`（机制），承认运行时残留。**
- 机制：`UIRequiresFullScreen=YES` 关闭 iPad Split View / Slide Over / Stage Manager 缩放 → app 恒全屏 → orientation 锁可靠生效。这是**版本无关的 build-setting 机制**（对齐 outline「机制归 plan」+ R3-F3）。
- **承认残留**：最新 iPadOS + 最新 SDK 下 Stage Manager 对部分 app 行为可能仍非完全受 `UIRequiresFullScreen` 约束（codex R3-F3 原意）。本锚交付 build-setting 锁 + runbook 运行时验证条目；若 runbook 实测显示 iPad 窗口/方向泄漏，更深的运行时锁（scene/orientation delegate override）作下游 follow-up（非本锚）。诚实标注，不 claim「绝对锁死所有 iPadOS 版本」。
- 备选（拒）：降 `TARGETED_DEVICE_FAMILY` 为 iPhone-only（`1`）——outline 明确 iPad 留 scope（顺位 2 owns iPad 窗口策略），不在本锚改设备族。

**B3. 验证 = runtime runbook，非 CI。**
- 理由：CI build 守护只证「带键能编译」，不证「运行时真锁竖屏」。orientation/窗口是运行时行为 → runbook 条目（user device/sim 验证），作顺位 13 阻塞依赖。

### C. required-check 强制

**C1. 工具泛化在本 PR；origin ruleset `--apply` 延后 post-merge user TTY。**
- 理由：镜像 1b（工具）+ 1c（admin execute），本锚压缩为一锚（工具已存在，仅泛化）。加第 12 条 context = 真实 mutation，须 user admin scope；Claude 不碰 origin ruleset。
- chicken-egg 处理：app-build.yml 在本 PR 加入 → 因 always-trigger，job 在本 PR 自身就运行报 status（但**尚未** required，因 ruleset 未 apply）→ 本 PR 不被自己的新 check 阻塞 merge。merge 后 user 跑 `--apply` → 对顺位 3-12 生效。

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

**R2（低）：`UIRequiresFullScreen` 在最新 iPadOS Stage Manager 的有效性。** 见 B2——已作残留标注 + runbook 验证 + 下游 follow-up，非本锚阻塞。

**R3（低）：Group C 触 `codeowners_required_globs`（`scripts/**` + `.github/**`）→ merge 须 user Approve（CODEOWNERS）。** 非设计阻塞，merge ceremony 处理（user TTY，对齐历史 anchor）。

---

## 六、不在本锚

- **iPad 横屏 layout 适配功能**（真正支持横屏 UI）——§outline §六排除项；本锚仅 owns**锁定**（Portrait + 全屏）。
- **运行时验收执行**——user device/sim 职责；本锚交付 runbook 条目，执行作顺位 13 阻塞。
- **任何业务/Swift 源改动**——本锚 0 业务代码。
- **更深运行时 orientation 锁**（scene/orientation delegate override）——仅当 runbook 实测显示泄漏才作下游 follow-up。
- **将其他现有 informational workflow（如 `branch-protection-config-self-check`）转 required**——非本锚 scope。

---

## 七、验收判据（outline）

1. `.github/workflows/app-build.yml` 存在，always-trigger（无 paths filter），job name = `iOS app build-for-running on macos-15`，build iOS Simulator destination，gate = BUILD SUCCEEDED + 无 error（非 blanket no-warning）。
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
