# 恢复 CI 的 `pglast` 测试依赖与共享版本守卫 · 非程序员验收清单

**这一片做了什么（一句话）**：之前所有 PR 在 GitHub 上跑自动检查都会卡在「找不到 `pglast==7.13` 安装包」这一步；本次把开发与测试两份清单里的 `pglast` 统一升级到同系列的 **`7.24`**，并加了一道自动检查，确保两份清单以后不会各自改版本而出现不一致。

**怎么用这份清单**：按表中「动作」逐项核对，「期望」全部对得上就在最后一栏勾选 `[x] 通过`；只要有一项对不上就勾选 `[ ] 不通过` 并附上实际输出或截图。

---

## 一、可执行验收条目

| # | 动作 | 期望 | 通过判定 | 通过与否 |
|---|---|---|---|---|
| 1 | 在终端执行干净环境安装（不要用已有旧虚拟环境）：`python3.11 -m venv /tmp/verify-pglast && /tmp/verify-pglast/bin/python -m pip install --no-cache-dir -r requirements-dev.txt -r backend/requirements-dev.txt -r backend/requirements-test.txt && /tmp/verify-pglast/bin/python -c "import pglast, pytest; print(pglast.__version__, pytest.__version__)"` | 命令退出码为 `0`，安装过程不报错，最后一行打印 `v7.24 8.4.2` | 退出码为 `0` 且最后一行显示 `v7.24 8.4.2` | `[ ] 通过` / `[ ] 不通过` |
| 2 | 执行新增依赖守卫测试：`cd backend && /tmp/verify-pglast/bin/python -m pytest tests/test_requirements_api.py -v` | 列出 13 条检查项，每一条后面都是 `PASSED`，最后一行显示 `13 passed` | 共 13 条且全部为 `PASSED`，无 `FAILED` 或 `SKIPPED` | `[ ] 通过` / `[ ] 不通过` |
| 3 | 执行完整后端测试套件：`cd backend && /tmp/verify-pglast/bin/python -m pytest tests/ -q -rs`（执行完成后可运行 `rm -rf /tmp/verify-pglast` 清理临时环境） | 最后一行显示 `1736 passed`（若后续又新增用例则不少于 `1736`），整段输出中不出现 `failed`、`error`、`skipped` | 退出码为 `0`，0 失败、0 出错、0 跳过 | `[ ] 通过` / `[ ] 不通过` |
| 4 | 核对生产与测试清单格式：确认 `backend/requirements.txt` 与 `backend/requirements-api.txt` 未被改动且仍不含 `pglast`；根目录 `requirements-dev.txt`、`backend/requirements-dev.txt` 与 `backend/requirements-test.txt` 均只使用 `包名==版本号` 精确写法 | `requirements.txt` 与 `requirements-api.txt` 内容与 `origin/main` 一致；根目录 `requirements-dev.txt` 为 `pytest==8.4.2`，backend dev/test 两份清单中的 `pglast` 均为 `pglast==7.24`，无 `>=`、`*`、`,` 等范围或通配写法 | 两份生产清单无变更，三份 dev/test 清单均为精确 `==` 版本 | `[ ] 通过` / `[ ] 不通过` |
| 5 | 打开本 PR 的 GitHub 页面，查看 Checks 列表中的 **`backend pytest (full suite)`**（Python 3.11） | 检查状态为绿色对勾，点开日志看到依赖安装成功且全部测试通过、0 skipped | 状态为绿色通过且日志显示全部后端用例通过 | `[ ] 通过` / `[ ] 不通过` |
| 6 | 查看 Checks 列表中的 **`acceptance`**（`hardening-6 framework gate`，Python 3.12） | 检查状态为绿色对勾；日志中 `Install Python test dependencies` 一步安装 `backend/requirements-dev.txt` 成功退出 `0`（注：本次未改动治理框架文件，该任务在依赖安装验证后按设计跳过框架脚本执行，不在此任务重跑 SQL 解析测试） | 依赖安装步骤退出 `0` 且该检查为绿色通过 | `[ ] 通过` / `[ ] 不通过` |
| 7 | 查看 Checks 列表中的 **`codex-verify-pass`**（由 `codex-review-verify` 工作流上报的二层 Codex 校验）与 PR 评论区的远端测试证据 | `codex-verify-pass` 状态为绿色通过（`approve`），且 PR 评论区已记录最终 HEAD SHA、CI 运行链接与第 5–6 项结果 | `codex-verify-pass` 为绿色通过且评论区有最终 HEAD 的 CI 链接记录 | `[ ] 通过` / `[ ] 不通过` |

---

## 二、本次本机实测记录（macOS Python 3.11，供对照）

- **实际执行者**：Antigravity（执行模型；因后端 `qmt_fsroot` 测试需在工作区外访问 `/private` 路径，经沙盒确认后按统一命令切出沙盒完成全套实测）。
- **测试环境**：macOS（arm64）新建干净隔离虚拟环境 Python `3.11.15`（`--no-cache-dir` 安装）。
- **导入版本实测**：`pglast: v7.24`、`pytest: 8.4.2`。
- **守卫专项测试**：`tests/test_requirements_api.py` 共 **13 条全部通过**（`13 passed in 0.02s`）。
- **完整后端测试套件**：`tests/` 共 **1736 passed / 0 skipped / 0 failed / 0 errors**（用时 228.59s，JUnit XML 核验确认无任何跳过或报错）。
- **全部清单解析核对**：根目录 `requirements-dev.txt`（1 项）、`backend/requirements.txt`（6 项）、`backend/requirements-api.txt`（3 项）、`backend/requirements-test.txt`（9 项）、`backend/requirements-dev.txt`（5 项）均通过严格精确 pin 解析校验。
- **PyPI Linux x86_64 安装包核查**：已核对 `https://pypi.org/pypi/pglast/7.24/json` 元数据，确认 CI 使用的两个 Python 版本均存在预编译 Linux x86_64 wheel：
  - Python 3.11：`pglast-7.24-cp311-cp311-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl`
  - Python 3.12：`pglast-7.24-cp312-cp312-manylinux2014_x86_64.manylinux_2_17_x86_64.manylinux_2_28_x86_64.whl`
- **评审通道记录**：
  - Gate 1（Spec）：经 `codex-attest.sh` 对抗评审通过（`approve`）；
  - Gate 2（Plan）：经 `codex-attest.sh`（R1–R4）与 Kimi 中间轮次核查并修订后，最终由 `codex-attest.sh` 复审通过（`approve`）；
  - Gate 3（Pre-PR 全分支 Diff）：因本地 Codex ChatGPT Pro 配额于 14:28 耗尽（需 19:04 重置），经用户明确授权由本地 `kimi-attest.sh --scope branch-diff`（`kimi-code/k3` / `high`）执行正式对抗评审与修复复审。
- **远端 CI 证据回填说明**：本机 macOS 测试不能替代 GitHub Actions Linux 环境真实执行；依据 `.claude/workflow-rules.json`（`acceptance_evidence_upload`）规范，PR 创建后最终 HEAD SHA 上的第 5–7 项真实运行链接与结果会上传至 PR 评论区（不在 Gate 3 签发后再新增提交，以免改变已签发的 HEAD 指纹）。
