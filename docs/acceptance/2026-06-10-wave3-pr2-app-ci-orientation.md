# Wave 3 顺位 2 验收清单（中文非-coder 可执行）

**PR 范围**：app-target CI 编译守护 + 锁竖屏/全屏 + required-check 治理工具泛化。**0 业务代码 / 0 Swift 源改动**（仅 CI workflow + pbxproj build settings + governance 脚本 + 文档）。

**权威 spec/plan**：`docs/superpowers/specs/2026-06-10-wave3-pr2-app-ci-orientation-design.md`（v3）+ `docs/superpowers/plans/2026-06-10-wave3-pr2-app-ci-orientation.md`。

## 非-coder 可执行验收步骤

| Step | Action | Expected | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR 文件列表 | 含新文件 `.github/workflows/app-build.yml` | □ Pass / □ Fail |
| 2 | 打开 `.github/workflows/app-build.yml`，看 `on:` 段 | 只有 `pull_request:` + `push: branches:[main]`，**无** `paths:` 行（always-trigger） | □ Pass / □ Fail |
| 3 | 看该 workflow 的 `jobs.app-build.name` 一行 | 字面等于 `iOS app build-for-running on macos-15`（= required-check context 名） | □ Pass / □ Fail |
| 4 | 看该 workflow 最后一个 step（Gate） | 三断言：grep `** BUILD SUCCEEDED **` 在位 + 拒 `** BUILD FAILED **` + 拒 `error:`；**无** `warning:` 断言 | □ Pass / □ Fail |
| 5 | 在本 PR 的 Checks 页找 `iOS app build-for-running on macos-15` | 该 check 已运行且结果为**绿（success）** | □ Pass / □ Fail |
| 6 | 打开 `ios/KlineTrainer/KlineTrainer.xcodeproj/project.pbxproj`，搜索 `Landscape` 和 `UpsideDown` | 两词均**搜不到**（0 命中） | □ Pass / □ Fail |
| 7 | 同文件搜索 `INFOPLIST_KEY_UIRequiresFullScreen = YES;` | 命中 **2 处**（Debug + Release 各一） | □ Pass / □ Fail |
| 8 | 同文件搜索 `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` | 值为 `"UIInterfaceOrientationPortrait"`（仅竖屏，无其它方向） | □ Pass / □ Fail |
| 9 | 终端在仓库根跑 `bash tests/scripts/governance/run-all.sh` | 末行 `ALL GREEN`，退出码 0 | □ Pass / □ Fail |
| 10 | 终端跑 `python3 scripts/governance/build-protection-put-payload.py --list-contexts` | 输出 `["Mac Catalyst build-for-testing on macos-15", "iOS app build-for-running on macos-15"]` | □ Pass / □ Fail |
| 11 | 终端跑 `grep -rn "_catalyst_entries\|ensure_catalyst" tests/scripts/governance/test_build_payload.py` | 0 命中（旧名已全部迁移） | □ Pass / □ Fail |
| 12 | merge **后** 由仓库管理员跑 post-merge admin runbook（见下方文档），完成后跑 `verify-required-checks.sh --mode assert` | 输出 `OK: ... required contexts [...] 全在位 ...`，退出码 0（含两 context + 既有 11 check 不回归） | □ Pass / □ Fail |
| 13 | PR 文件列表含三份文档 | 本验收文件 + `docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md` + `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md` | □ Pass / □ Fail |

## 说明

- **Step 5 vs Step 12 的区别**：Step 5 只要求新 check 在本 PR **运行并变绿**（守护本身工作）；Step 12 是 merge 后管理员把该 check 加入 ruleset 成为 required（真实 mutation，加第 12 条），对顺位 3-12 强制——见 `docs/governance/2026-06-10-pr2-app-build-required-check-runbook.md` 的前置时序约束。
- **运行时验收（旋转/窗口锁是否真生效）** 不在本 CI 守护范围（CI 只验证「能编译」），归 `docs/runbooks/2026-06-10-wave3-orientation-runtime-acceptance.md`，由 user 在 device/sim 执行，作顺位 13 收尾阻塞依赖之一。
