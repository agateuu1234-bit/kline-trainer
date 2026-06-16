# Wave 3 residual-D 闭合 验收清单（中文非-coder 可执行）

**PR 范围**：把 `residual-D-e2e-smoke` 从 PARTIAL 闭合为 CLOSED。新增正/反向 E2E 测试用**真** `DefaultTrainingSetDataVerifier` 跑真 `DownloadAcceptanceRunner` 全管线（此前 smoke 用 fake verifier，runner↔真 verifier 接线未覆盖）。0 生产代码改动；改测试 + 治理 doc + grep gate。

**source-of-truth**：spec `docs/superpowers/specs/2026-06-16-wave3-residual-d-e2e-design.md`；plan `docs/superpowers/plans/2026-06-16-wave3-residual-d-e2e.md`。

**评审通道（trust-boundary）**：改 `ios/**/*.swift` + `docs/governance/**` + `scripts/**` → 须 codex:adversarial-review（配额耗尽 fallback opus 4.8 xhigh）+ Catalyst + swift-test + app-build；`docs/governance/**`、`scripts/**`、`docs/superpowers/**` 在 codeowners_required_globs → 须 CODEOWNERS approve。

## 验收步骤

| Step | Action（操作） | Expected（预期可观察结果） | Pass / Fail |
|---|---|---|---|
| 1 | 浏览器打开本 PR，看 `DownloadAcceptanceRunnerIntegrationTests.swift` diff | 新增 1 个 `verifierValidCandles` helper + 2 个 `@Test`：`run_realPipeline_withRealVerifier_confirmsAndDownstreamConsumable`（正向）/ `…_rejectsWhenPeriodUnderThirtyBefore`（反向），二者注入 `DefaultTrainingSetDataVerifier()`（非 fake） | □ Pass / □ Fail |
| 2 | 看正向测试断言 | 期望 `.confirmed` + `file.schemaVersion == TRAINING_SET_SCHEMA_VERSION` + 6 周期每个 before≥30/after 足 + `m3.first.globalIndex==0` | □ Pass / □ Fail |
| 3 | 看反向测试断言 | 期望 `.rejected` 且错误**精确**为 `.trainingSet(.emptyData)` + cache 无该组 + 无 confirmed journal | □ Pass / □ Fail |
| 4 | 看 CI「swift test on macos-15」 | 绿；含 2 新测试 + 既有测试不回归 | □ Pass / □ Fail |
| 5 | 看 CI「Mac Catalyst build-for-testing」+「app-build」 | 均绿 | □ Pass / □ Fail |
| 6 | 看 `docs/governance/2026-06-14-wave3-completion.md` diff | WAVE3-STATUS 块 `residual-D-e2e-smoke: CLOSED residual-D 2026-06-16`；§三 行 D 标 CLOSED 且**已删除「…fixture 不现实」原断言半句**（仅余「证伪并解决」措辞）；§六 `D CLOSED` | □ Pass / □ Fail |
| 7 | 看 `scripts/governance/verify-wave3-completion.sh` diff | 谓词 + L5/L43 注释 + L73 echo 全部 `D=CLOSED`；无残留 residual-D 的 PARTIAL/fake-verifier/不现实 措辞（runtime-matrix=PARTIAL 与 residual-D 无关，正当保留） | □ Pass / □ Fail |
| 8 | 看 codex 对抗 review verdict（或配额耗尽 opus 4.8 xhigh fallback） | APPROVE | □ Pass / □ Fail |
| 9 | 看 CODEOWNERS approve | 仓库 owner 已 approve（governance/scripts 触发） | □ Pass / □ Fail |

## 范围注 / 已知边界

- **不动 device 运行时矩阵**：residual-D（host E2E 接线覆盖）与 `runtime-matrix: PARTIAL`（device 实测）正交；本 PR 不触 runtime-matrix / formal-closure / feature-completeness / freeze-tag / W3-11-R1 / ship 门。
- **不回写 13b 历史快照**：`docs/acceptance/2026-06-14-wave3-pr13b-fixture-smoke.md` 与完成 doc L92 13b 脚注是历史记录，保持不变。
- **0 生产代码改动**：runner/verifier/reader/fixture writer 均未改；仅新增测试覆盖。
