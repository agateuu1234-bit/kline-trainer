# backend/tests/test_backend_tests_workflow_runs_on_every_pr.py
"""钉住一条不变量：`backend-tests.yml` **不得**有 `pull_request.paths` 过滤器。

为什么这条不变量值得钉（2026-08-30 决策，详见
`docs/superpowers/plans/2026-08-30-ci-paths-suite-external-inputs.md`）：

本套件读 `backend/` 之外的东西 —— `scripts/**` 下 30 个 `.sh`（`test_env_example_coverage`
递归扫）、iOS 那份 Swift 契约常量（`test_qmt_pilot_db` 的跨语言漂移钉）、
`tests/contract-fixtures/`（`test_openapi` 与 `test_routes` 两处都读）。paths 过滤器
一旦漏掉其中任何一条，只改那些文件的 PR 就**静默跳过整套后端测试**：守卫还在，
但多了一条旁路，红要等合进 main 之后由 push 触发才暴露。

试过用「让每个测试模块自报读了哪些外部文件」来维护那张清单，**两轮评审两次被打回**：
清单靠人自觉，而人（我）当场就漏了 `test_routes.py`。要做到不靠自觉，得写一套静态
分析去解析各种路径表达式 —— 而本 job 实测只跑 1.5–2 分钟。为省这 2 分钟维护一张
必须与套件实际读取面永远同步的清单，不划算。

所以决定：**取消过滤器，每个 PR 都跑**。这样「漏了某个外部输入」这件事从根上不可能
发生，也就不需要那套清单和守卫了。本文件只负责钉住这个决定别被悄悄改回去。

（同款配置在本仓有先例：`hardening_6_gate.yml` 也没有 paths 过滤器。另注：
`backend pytest (full suite)` 不是分支保护的必需检查，所以无过滤器不会造成
必需检查等不到状态的死锁。）
"""
from __future__ import annotations

from pathlib import Path

import yaml

WORKFLOW = (
    Path(__file__).resolve().parents[2] / ".github/workflows/backend-tests.yml"
)


def _on_section() -> dict:
    """取 workflow 的 `on:` 段。

    ⚠️ YAML 1.1 坑（PyYAML 6.0.3 实测）：裸键 `on:` 被解析成**布尔 True**，不是
    字符串 `"on"`，`doc["on"]` 会 KeyError。两种键都试，都取不到就报错 —— 不返回
    空字典，否则下面两条判据会一起恒真。
    """
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    section = doc.get("on", doc.get(True))
    assert isinstance(section, dict), (
        "backend-tests.yml 里取不到 on: 段（PyYAML 把裸 on 解析成 True）—— "
        f"本文件的解析口径已失效，实得 {type(section).__name__}"
    )
    return section


def test_workflow_still_triggers_on_pull_request():
    """防空转：`pull_request` 触发器本身得在。

    没有这条，下面那条「不许有 paths」在**整个触发器被删掉**时也会绿 ——
    而那种情况下后端测试一次都不跑，比有过滤器还糟。
    """
    assert "pull_request" in _on_section(), (
        "backend-tests.yml 不再有 pull_request 触发器 —— PR 上根本不跑后端测试"
    )


def test_pull_request_trigger_is_completely_unfiltered():
    """本文件的正题：`pull_request:` 下面**一个键都不许有**。

    ⚠️ 这里刻意用**白名单**（什么都不许有）而不是黑名单（只拒 `paths`）。初版写成
    「`paths` 必须为空」，codex R3 当场给出四种等效绕过，本地全部复现为**绿**：
      - `paths-ignore: ['scripts/**']` —— 重建一模一样的外部输入盲区；
      - `branches: [main]` / `branches-ignore: ['feat/**']` —— 按分支排掉一批 PR；
      - `types: [closed]` —— 只在 PR 关闭时触发，等于合并前完全不验。
    判据本身有多种正交的绕过方式时，逐个去禁是禁不完的（本仓 memory
    `feedback_same_predicate_multiple_bypasses`）。GitHub 在 `on.pull_request` 下
    支持的键就是 `types` / `branches` / `branches-ignore` / `paths` / `paths-ignore`，
    每一个都会让「哪些 PR 会跑」变窄，所以正解是**一个都不接受**。
    将来真需要其中某个（例如用 `types` 去**放宽**），就改本判据并写清理由。

    另外两道 fail-closed 写在前面，是为了别靠**偶然异常**兜底（变异实测过：不写它们时，
    触发器被删会抛 `KeyError`、`pull_request` 被写成数字会抛 `AttributeError` ——
    一样是红的，但那是撞出来的、不是判据判出来的，报错文字对读者也毫无帮助）。
    """
    section = _on_section()
    assert "pull_request" in section, (
        "on: 段里没有 pull_request —— 见 test_workflow_still_triggers_on_pull_request"
    )
    pull_request = section["pull_request"]
    # `pull_request:` 后面什么都不写 → PyYAML 给 None，那正是我们要的「无任何过滤」。
    # 除此之外只接受映射；是别的类型说明写法超出本判据的理解范围。
    assert pull_request is None or isinstance(pull_request, dict), (
        f"on.pull_request 既不是空、也不是映射（实得 {type(pull_request).__name__}）—— "
        "本文件的解析口径够不着这种写法，请先扩本判据再判"
    )
    keys = sorted(pull_request or {})
    assert keys == [], (
        f"backend-tests.yml 的 on.pull_request 下面出现了过滤键：{keys}\n"
        "这些键每一个都会让「哪些 PR 会跑后端测试」变窄，而本套件读 backend/ 之外的\n"
        "文件（scripts/** 下的 .sh、iOS 那份 Swift 契约常量、tests/contract-fixtures/），\n"
        "一旦某类 PR 不跑，就等于给守卫开一条静默旁路 —— 红要等合进 main 才暴露。\n"
        "本 job 只跑 1.5–2 分钟，不值得为省这点时间承担这个风险；历史上那张\n"
        "「哪些文件才触发」的清单已经漏过两次。\n"
        "详见 docs/superpowers/plans/2026-08-30-ci-paths-suite-external-inputs.md。\n"
        "确实要加其中某个键，就连同本文件一起改，并写清为什么这样不会漏掉某类 PR。"
    )
