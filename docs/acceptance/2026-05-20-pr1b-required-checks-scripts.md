# Wave 1 顺位 1b — Required-checks 治理脚本 验收清单

> 面向项目所有者（无代码经验）。每行：**动作** / **预期** / **通过判据（二选一）**。
> 全部命令在仓库根目录终端执行（路径含空格，命令已处理）。

**交付物**：3 个治理脚本（`scripts/governance/` 下的 builder / 三模式 verifier / admin runbook）+ 测试套件 + 16 个 ruleset fixture + mock gh。**1b 只交付脚本，不动 GitHub origin**（真正配置 required check 在顺位 1c 由管理员执行）。

---

## 一、机器可检查验收（命令 + 退出码）

| # | 动作（在终端粘贴运行） | 预期 | 通过判据 |
|---|---|---|---|
| 1 | `bash tests/scripts/governance/run-all.sh` | 末行打印 `ALL GREEN`，命令退出码 `0` | 见 `ALL GREEN` 且退出码 0 = 通过 |
| 2 | `python3 -m pytest tests/scripts/governance/test_build_payload.py -q` | 打印 `13 passed` | 见 13 passed = 通过 |
| 3 | `bash scripts/governance/verify-required-checks.sh --mode assert --ruleset-json tests/scripts/governance/fixtures/ruleset-with-check.json; echo "退出码=$?"` | 打印 `OK: main branch ruleset + 绑默认分支 + active + 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin`，`退出码=0` | 见 OK 且退出码 0 = 通过 |
| 4 | `bash scripts/governance/verify-required-checks.sh --mode assert --ruleset-json tests/scripts/governance/fixtures/ruleset-anysource.json; echo "退出码=$?"` | 打印含 `integration_id=None != 15368（any-source 伪造风险）`，`退出码=1` | 见 FAIL 且退出码 1 = 通过 |
| 5 | `git grep -nE 'api[^#]*branches/[^ "'"'"']*/protection' -- scripts/governance/; echo "退出码=$?"` | 无任何输出行，`退出码=1`（注：脚本注释里提到 `branches/main/protection` 是说明「为何改用 rulesets」，不是 API 调用） | 无输出 + 退出码 1 = 通过 |
| 6 | `git diff --name-only origin/main...HEAD \| grep -E '^\.github/workflows/\|^docs/governance/'; echo "退出码=$?"` | 无任何输出行，`退出码=1`（1b 不动 CI workflow / governance 目录） | 无输出 + 退出码 1 = 通过 |

## 二、安全契约覆盖（在 run-all 输出里逐条确认 PASS）

跑 `bash tests/scripts/governance/run-all.sh` 后，下列行都应是 `PASS`：

| 契约 | 应见的 PASS 行 |
|---|---|
| rollback 用规范化原状态（非 raw snapshot） | `rollback-payload 无只读字段` |
| 并发漂移检测 | `并发漂移 → 1 abort` / `漂移检测后无 PUT` |
| 已合规免改 | `apply no-op → 0` |
| PUT 失败状态判定 | `PUT 干净失败 → 1` / `PUT 报错但已 apply → 0` |
| token 样内容不被误删 | `payload 保留 token 样 context` |
| 非 active ruleset 不动 | `inactive → 1（fail-closed）` |
| 绑定默认分支校验 | verifier `assert wildcard-exclude → 1` |
| 并发合法追加算成功、保护流失不算 | `并发合法追加 → 0` / `保护流失(Catalyst在但少规则) → 1` |
| 新增 bypass actor 拦截 | `多 bypass actor → 1（人工介入）` |
| 规则参数削弱拦截 | `param 削弱 → 1（人工介入）` |
| 证据写盘失败兜底 | `PUT-failure artifact 无 token` |

## 三、本次执行采集到的真实证据（2026-05-21）

- `bash tests/scripts/governance/run-all.sh` → 末行 `ALL GREEN`，退出码 `0`，统计 **PASS=60 / FAIL=0**。
- `python3 -m pytest .../test_build_payload.py -q` → `13 passed`。
- 验收 #3 实际输出：`OK: main branch ruleset + 绑默认分支 + active + 'Mac Catalyst build-for-testing on macos-15' 在位 + integration_id=15368 + bypass 仅 admin`，退出码 0。
- 验收 #4 实际输出：`FAIL: 'Mac Catalyst build-for-testing on macos-15' integration_id=None != 15368（any-source 伪造风险）`，退出码 1。
- 验收 #5 功能调用 grep：零命中（退出码 1）。
- 验收 #6 改动文件范围：无 `.github/workflows/` 与 `docs/governance/` 命中（退出码 1）。

## 四、已知 residual（不阻塞本交付）

- **`~DEFAULT_BRANCH` 未核实 default 分支真是 main**（branch-diff codex R4）：对本交付是**理论问题**——本仓默认分支确为 `main`，脚本仓库硬编码本仓，1b/1c 用途即护本仓 main。完整修（live 查 default_branch + offline 加 `--default-branch` 参数）推到将来跨仓复用 / 默认分支改名场景。详见 plan grounding #14。

## 五、评审记录

- plan-stage codex 对抗性 review 7 轮（R1–R7：rollback 形状 / 乐观并发 / no-op skip / PUT 失败分类 / redaction 源分离 / TOCTOU 文档化 / 观测失败分层 / 有状态 mock / offline name·target·conditions·enforcement 守卫 / bypass 精确）。
- subagent-driven 实施 + spec-compliance 评审（SPEC COMPLIANT）+ code-quality 评审（Approved-with-minor，已修 I1/I2 + diff exit-code + 消息粒度 + tokenish 测试）。
- branch-diff codex 对抗性 review 4 轮（bypass actors 校验 / 证据写盘 fail-closed / R7-F3 param 保留实施 / default-branch residual）。
- 收敛决策：codex 仅剩 default-branch 理论边界不收敛，per `feedback_codex_round6_self_contradiction` + `feedback_openai_quota_ci_pattern` 走 user TTY override + admin merge；required checks 真绿。

> 禁忌词自查：本清单不含「验证通过即可 / 看起来正常 / 应该没问题 / should work / looks fine」。
