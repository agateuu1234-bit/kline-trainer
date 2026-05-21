# Wave 0 契约冻结签字 ledger（v1.4）

单人项目简化版：项目所有者 (@agateuu1234-bit) 兼任 iOS / 后端 / 数据三方代表，按 §15.4 ledger 形式记录三角色 review 过的范围。非真三方会议；ledger 形式留痕。

## 后端代表 sign-off（自签）
- [x] M0.1 DDL（PostgreSQL schema + 训练组 sqlite + AppDB）与 PR #23 / #29 一致
- [x] M0.2 OpenAPI 与 PR #24 三接口 schema 一致；lease 状态机 + CRC32 已落地
- [x] B1-B4 实现在 Wave 1 backlog；OpenAPI 与 backend 契约对齐
- **签字时间**：2026-05-17

## iOS 代表 sign-off（自签）
- [x] M0.3 数据模型：**23 个类型** inventory（16 Codable + 7 非 Codable，见 §M0.3 表）全 Equatable / 关键 Codable round-trip 闭环
- [x] M0.4 AppError + Reason 枚举 Error conformance（PR #26 / #27）
- [x] M0.5 并发契约 doc（PR #52）
- [x] F1 Models 薄 wrapper（PR #53）含 BinarySearch utility
- [x] F2 Theme（PR #39）13 默认色
- [x] C1a Geometry / C1b Reducer / C1c Render UIKit shell（PR #38 / #47 / #48 / #49 / #50 / #51）
- [x] §15.1 编译验证 #1-#9 全闭环：本地 swift test + Catalyst build SUCCEEDED + CI 持续守护（PR 9 加 catalyst-build job，顺位 1a 拆至独立 workflow `.github/workflows/catalyst-build.yml`；H8 + H9 + H10 配套闭合 required gate）（**H8/H10 顺位 1c close 2026-05-22**；H9 顺位 1a；见 `docs/governance/2026-05-21-pr1c-required-checks-evidence.md`）
- [x] Preview Fixture 可在 Xcode Canvas 渲染（E6 PR #40 提供）
- **签字时间**：2026-05-17

## 数据代表 sign-off（自签）
- [x] B1 CSV 导入字段覆盖在 OpenAPI 与 spec §B1 一致（**契约层** sign-off — backend 实现 Wave 1）
- [x] B2 训练组生成策略（月线前 30 / 后 8 根月窗口）记录在 spec §B2（**契约层** sign-off）
- ⚠️ **未签**（codex R4 finding 3 修：future scope 不能签 ✅）：3-5 个样本训练组数据落地 → 移入 **residual H7**（Wave 1 B1/B2 PR 内验证 3-5 个样本数据正确性 + ledger 回填）
- **签字时间**：2026-05-17

## 已知 residuals（不阻塞 freeze；10 项 H1-H10）

| ID | residual | 来源 | 处理路径 |
|---|---|---|---|
| H1 | C1b 闸门 #4 F3 production handler 集成测试（modules §C1b L1180 区块） | PR #50 plan-residual | 顺位 1a spec amendment：modules §C1b 闸门 #4 reclassify Wave 1→Wave 2（C8/E5 属 Wave 2）；真正闭环 = Wave 2 C8 ChartContainerView 集成 PR（C2/C8/E5 orchestration 同 PR） |
| H2 | E2 PositionManager 三连 abort | PR #36 closed | Wave 1 启动前 spec §4.2 重审窗口 |
| H3 | Wave 1 内部 plan 排序 | v6 outline 仅 Wave 0 | PR 9 merge 后 brainstorming + writing-plans 排细顺位 |
| H4 | M0.3 multi-file split 历史 over-claim | PR F1 R7+R8 | Spec §F1 wording + §M0.3 inventory 表（PR 9 子项 2） |
| H5 | Catalyst CI 持续守护 | PR #51 R7 G3 | `.github/workflows` Catalyst job（PR 9 子项 3）+ 配套 H8 + H9 + H10 整体闭合 required gate |
| H6 | backend deps exact pin | spec §15.2 暂用 ranges | Wave 1 B1-B4 PR 各自落 `backend/requirements.txt == X.Y.Z` + `docker-compose.yml` image digest pin |
| H7 | sample 训练组数据 | 数据代表 sign-off 第 3 项 future scope | Wave 1 B1/B2 PR 内真生成 3-5 个样本 + 数据正确性 ledger 回填 |
| H8 | Catalyst CI required merge gate enforcement | spec v9 §6.G | ✅ **顺位 1c close（2026-05-22）**：origin `main` ruleset 已配 required check context `Mac Catalyst build-for-testing on macos-15`（= job name，非 job key `catalyst-build`）且绑 GitHub Actions app（`integration_id=15368`，非 "any source"，防 trust-boundary spoof）。1c 经 1b runbook **dry-run 确认幂等 no-op（gate 已在位，无需 mutation，未跑 `--apply`）** + 独立 `verify-required-checks.sh --mode assert` + live `default_branch==main` 双谓词确认；与 1a 拆出的 always-trigger workflow `.github/workflows/catalyst-build.yml`（H9 已解）配套，每 PR 必跑必报且 merge 受 gate。证据：`docs/governance/2026-05-21-pr1c-required-checks-evidence.md` |
| H9 | workflow `paths` filter 与 required check 架构性矛盾 | plan v6 codex R6 finding 1 | ✅ 顺位 1a 决议（option B）：catalyst-build 拆至独立 always-trigger workflow `.github/workflows/catalyst-build.yml`（无 paths filter，每 PR 必跑必报）；job name 保持 `Mac Catalyst build-for-testing on macos-15` 不变以保留 required check context。required check 配置 + machine-checkable 验证（H8/H10）仍在顺位 1c |
| H10 | acceptance §G 缺 machine-checkable required check 验证 | plan v6 codex R6 finding 2 | ✅ **顺位 1c close（2026-05-22）**：机器可检查谓词权威断言 = `bash scripts/governance/verify-required-checks.sh --mode assert`（源真相 rulesets API；断言 Catalyst check 在位 + `integration_id=15368`（GitHub Actions app，防伪造来源）+ enforcement=active + 绑默认分支 + bypass 仅 admin）**且** live 默认分支断言 `default_branch == main`（读 `repos/<owner>/<repo>` 的 `.default_branch` 字段；codex R2-F2：assert 内部把 `~DEFAULT_BRANCH` 无条件当 main 不 live 核实，故 close 须双谓词同时成立）。**注**：legacy 验证写法（旧 branch-protection endpoint + `.app_id` 字段）已 stale——该 endpoint 对 main 返回 404、rulesets 源真相用 `integration_id` 非旧字段；1c 已修正为上述 rulesets 谓词。证据：`docs/governance/2026-05-21-pr1c-required-checks-evidence.md` |

## 依赖版本锁定（§15.2 v1.4 freeze）

见 README v1.4 章节 + `ios/Contracts/Package.resolved`。

签字完成后：契约层进入 RFC 修改模式；任何 M0.* / F1 / F2 / C1a / C1b / C1c / E1 / E6 / P3 / P4 / P5 / P6 改动需 RFC 走 superpowers:brainstorming + ledger 留痕。

## Provenance

本 ledger **不内嵌 PR 9 squash commit SHA**；provenance 走三件互证：

1. **annotated tag** (`git show wave0-frozen-v1.4`) — 显示 tagger / date / target commit SHA / message
2. **GitHub protected tag namespace（mandatory）** — `wave0-frozen-*` 配 admin-only push + 禁 force-update；tag 创建脚本 protected ruleset 完整谓词检查 (`scripts/governance/verify-freeze-tag.sh`) fail → `exit 1`
3. **本 ledger + README v1.4** — 三处文本签字记录互证；任意一处篡改可 `git diff` 出来

完整 tag 验证脚本见 spec §5.6（含三层 blocking gate）。

**注意**：annotated tag (`-a`) 自身的 tagger 字段是 arbitrary metadata，不是 cryptographic proof。signed tag (`-s`) 才提供加密保证；单人项目实操中 GitHub protected tag namespace + admin-only push = remote ref 不可篡改的等价防线。
