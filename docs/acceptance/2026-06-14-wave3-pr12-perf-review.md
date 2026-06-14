# 验收清单 — Wave 3 顺位 12：性能评审 + 帧预算判据（静态评审，0 生产代码）

**交付物**：静态渲染热路径评审 artifact + 帧预算验收 runbook + host CI 回归绊线测试（完整 `make()` smoke）。**0 生产代码改动**（modules v1.4 L1471 / plan v1.5 L1264 判据已 own；数值回填归顺位 13 阻塞依赖）。

**前置**：在仓库根目录执行命令；macOS 装 Swift 6 工具链。

| # | 操作（action） | 预期（expected） | 通过/不通过（pass/fail） |
|---|---|---|---|
| 1 | `test -f docs/governance/2026-06-14-wave3-pr12-performance-review.md && echo EXISTS` | 输出 `EXISTS`（文件存在） | EXISTS = 通过；无输出或 exit 非 0 = 不通过 |
| 2 | 人工阅读 `docs/governance/2026-06-14-wave3-pr12-performance-review.md` §二「每帧 CG 调用量级账」，对照 `ios/Contracts/Sources/KlineTrainerContracts/Render/KLineView+Candles.swift:13-67` 实代码：确认 per-candle stroke+fill 描述正确（`:13-27`）、defaultVisibleCount=80 分母正确（非 93）、3 轨 BOLL 虚线描述正确（`:47-67`） | §二 行号引用与 `KLineView+Candles.swift` 实代码一致；80 分母非 93；3 轨 BOLL = 通过 | 三处均一致 = 通过；任一不符 = 不通过 |
| 3 | `cd ios/Contracts && swift test --filter makePerfSmoke` | 测试 PASS 且 stdout 含字符串 `make() avg`（host smoke 输出装配耗时） | PASS 且含 `make() avg` = 通过 |
| 4 | `test -f docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md && grep -c "4ms" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` | 文件存在（exit 0）且 `grep -c "4ms"` ≥ 4（含 4 个录制场景 + 4ms 判据 + 决议门）；`grep -q "L1471" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` exit 0（含权威行号 L1471 而非 L1467）；`grep -q "回填" docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md` exit 0（含回填栏） | 三项均满足 = 通过；任一失败 = 不通过 |
| 5 | `grep -c "no-op" docs/governance/2026-06-14-wave3-pr12-performance-review.md` | 输出 ≥ 1（Bitmap Cache 决议门双分支——< 4ms no-op / ≥ 4ms 独立引入——均在 doc 中表述） | 计数 ≥ 1 = 通过；0 = 不通过 |
| 6 | `git diff --stat main..HEAD -- ios/Contracts/Sources` | 输出为空（0 生产代码改动；`ios/Contracts/Sources` 目录下无变更） | 空输出 = 通过；任何行输出 = 不通过 |
| 7 | 对三个交付文件执行 forbidden phrases 自检（短语从 `.claude/workflow-rules.json` 的 `verification_template.forbidden_phrases` 字段动态读取，本清单不逐字列出以免自命中）：`python3 -c "import json; print('\n'.join(json.load(open('.claude/workflow-rules.json'))['verification_template']['forbidden_phrases']))" \| grep -rnF -f - docs/governance/2026-06-14-wave3-pr12-performance-review.md docs/runbooks/2026-06-14-wave3-pr12-frame-budget.md docs/acceptance/2026-06-14-wave3-pr12-perf-review.md` | 无任何输出（CLEAN，命令 exit 1）；有输出则含禁用短语需修复后重提交 | 无输出 = 通过；有输出 = 不通过 |

**说明（非破坏性核实）**：本顺位为静态评审，0 生产代码改动；帧预算数值为 user device 职责（顺位 13 阻塞依赖）。step 3 的 host smoke 仅验证 `make()` 装配无病态退化，不等同于 spec 帧预算 gate（draw 侧 4ms 判据唯一权威 = device Instruments 实测）。
