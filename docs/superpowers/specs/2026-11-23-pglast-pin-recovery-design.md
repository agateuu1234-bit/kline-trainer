# 恢复 CI 的 pglast 测试依赖

## 问题与接续点

2026-11-22，PR #210 的 Backend Tests 与 hardening-6 acceptance 均在安装
`pglast==7.13` 时退出，尚未执行测试。对应运行分别为 44996024598、44996024603。
两份安装清单分别使用 Python 3.11 和 3.12。

既有分支 `fix/pglast-pin-7.24` 已提交 `3e97faa1`：两份测试依赖清单改为
`pglast==7.24`，并同步一处测试文件注释。本次接续该提交，补齐当前验证、验收说明及评审；
不声称已有提交是在本次设计评审之后才写出的。

## 选择与范围

采用既有的精确版本 `7.24`，保持 v7 解析器系列及两份清单一致。
其他可选路线是升级到 v8，或取消精确版本约束；两者都会扩大此次恢复 CI 的兼容性范围，
当前没有必要。生产依赖清单、SQL 语义、版本守卫和 workflow 行为不变。

改动范围仅限：

- `backend/requirements-test.txt` 和 `backend/requirements-dev.txt` 的 `pglast` 精确版本（`7.13 → 7.24`）；
- `backend/tests/test_insert_schema_version_guard.py` 中对应注释；
- `backend/tests/test_requirements_api.py` 新增结构化的共享依赖版本一致守卫与负向单元测试：
  - 校验 `requirements-dev.txt` 与 `requirements-test.txt` 均只使用精确 `==` pin；
  - 校验 `requirements-dev.txt` 非空、其包集合是 `requirements-test.txt` 的子集（并显式包含 `pglast`）；
  - 校验两份清单所有同名包（含 `pglast`）的版本号逐字一致；
  - 补充负向单测证明：共享包版本漂移、交集为空、dev 存在 test 缺失的包、dev 缺少 `pglast`、或出现非精确约束（范围 `>=`、通配符 `==1.*`、复合约束 `,!=...`）时均抛出 `AssertionError` 失败（不在测试中硬编码 `"7.24"` 版本字符串）。

历史 spec、验收记录里的旧版本描述保留其历史含义，不全仓替换；现有 SQL 解析、迁移与版本守卫测试用于验证 `pglast==7.24` 兼容性。

## 完成标准

1. 在独立 Python 3.11 干净虚拟环境中，按 `requirements-dev.txt` 与 `requirements-test.txt` 完成依赖安装，并确认实际导入的 `pglast.__version__` 为 `7.24`（或 `v7.24`）。
2. 在该环境运行完整 `backend/tests/`，退出码 0、0 failed、0 errored、0 skipped；记录实际通过条数。
3. 验证 PyPI 为 `pglast==7.24` 提供 Linux x86_64 的 CPython 3.11、3.12 安装包（`manylinux` wheel）。本机 macOS Python 3.11 验证不能替代 PR 最终 HEAD 在两个 CI Python 版本上的真实安装与执行。
4. `backend/tests/test_requirements_api.py` 新增的 dev/test 共享 pin 守卫与负向单元测试全部通过。
5. 对抗性评审与交付：Spec（Gate 1）、实施计划确认收口（Gate 2，`--review-only`，不写本地账本）与提交前完整分支 Diff（Gate 3，`--scope branch-diff`，覆盖 Spec、实施计划、测试代码与验收清单并写入本地账本）均通过本地 `codex-attest.sh` 正式对抗性评审；交付中文非程序员验收清单（写明实际执行者），并在最终 PR HEAD 通过 GitHub Actions 的 `codex-verify-pass`（由 `codex-review-verify` 工作流上报的 Codex 二层校验）及全部必需检查。

## 边界

不修改共享虚拟环境；不连接 NAS 或改写训练数据；不顺带处理 #210/#179 的代码。
不修改 `.claude/**` 治理脚本与钩子（`main` 上既有 `guard-attest-ledger.sh` 与 `ledger-lib.sh` 的格式不兼容及 `file:` 条目校验属独立治理项，不在本 PR 顺带修复）；Gate 3 凭证签发后的推送、创建 PR 与 PR 评论证据上传由用户终端执行（或在经用户逐条显式授权、不挂载 `.claude/settings.json` 钩子的 Antigravity 会话中执行），不得在 Claude Code 钩子生效环境下尝试绕过守卫。
新环境安装若暴露其他依赖问题，先记录具体失败，再判断是否属于恢复这条 CI 链路所必需。
