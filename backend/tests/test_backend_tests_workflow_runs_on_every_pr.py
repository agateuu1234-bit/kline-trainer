# backend/tests/test_backend_tests_workflow_runs_on_every_pr.py
"""钉住一组不变量：`backend-tests.yml` 的触发器**不得被任何形式收窄**。

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
发生，也就不需要那套清单和守卫了。本文件只负责钉住这个决定别被悄悄改回去 —— 五条
判据分别管：触发器还在、`pull_request` 下一个键都没有、`push` 那条兜底退路没被过滤、
job 名等于 canonical 必需 context 且那个 job 真的在跑 pytest、该 context 仍在 canonical 清单里。

（同款配置在本仓有先例：`hardening_6_gate.yml` 也没有 paths 过滤器。另注：
`backend pytest (full suite)` **已被列入 canonical 必需检查清单**——正因为它无过滤器、
每个 PR 都报告状态，才够格当必需检查；反过来说，一旦给它加回过滤器，那些不匹配的 PR
就会卡在「Expected — waiting for status」。这也是下面那几条判据要钉住它的原因。）
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import yaml

_REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = _REPO_ROOT / ".github/workflows/backend-tests.yml"
_BUILDER = _REPO_ROOT / "scripts/governance/build-protection-put-payload.py"


def _builder():
    """按路径加载 canonical 必需检查清单（文件名带连字符，不能直接 import）。

    只依赖 stdlib（该脚本仅 import argparse/json/sys），所以在 codeowners-config-check
    那道**必需门**里（只装了 pyyaml+pytest）也跑得起来。
    """
    assert _BUILDER.is_file(), f"{_BUILDER} 不存在 —— canonical 清单没了，判据无从谈起"
    spec = importlib.util.spec_from_file_location("build_payload", _BUILDER)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _on_section() -> dict:
    """取 workflow 的 `on:` 段。

    ⚠️ YAML 1.1 坑（PyYAML 6.0.3 实测）：裸键 `on:` 被解析成**布尔 True**，不是
    字符串 `"on"`，`doc["on"]` 会 KeyError。两种键都试，都取不到就报错 —— 不返回
    空字典，否则下面几条判据会一起恒真。
    """
    assert WORKFLOW.is_file(), (
        f"{WORKFLOW.name} 不存在 —— 后端测试工作流被删掉了，PR 上一次都不会跑。"
        "（本判据由 codeowners-config-check 那道必需门独立执行，所以删文件也拦得住）"
    )
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


def test_push_trigger_is_not_narrowed_by_paths():
    """`push` 触发器只许有 `branches: [main]`，不许再加路径过滤。

    为什么这条也要钉（codex R4 引出）：本文件的判据**跑在它自己看守的那道工作流里**。
    如果有人提一个只改 workflow 的 PR、加上一条把该文件本身排除在外的
    `pull_request.paths`，那个 PR 上这道 job 压根不会启动，判据也就不会红 ——
    此时该必需检查会永远等不到结果，那个 PR 反而**卡在「Expected — waiting for status」**
    合不进去（管理员可显式绕过）。

    这时候**唯一还能兜住的就是 `push: branches: [main]`**：合并后 main 上会跑一次，
    钉子在那里变红。所以 `push` 一旦也被路径过滤，就真的全静默了。
    这条判据把那条退路焊死。

    ⚠️ 它只保证「**合并后**一定被发现」，不保证合并前。合并前的强制拦截由
    `codeowners-config-check` 那道**必需门**独立执行（它跑本文件），
    外加 `backend pytest (full suite)` 自身已被列为必需检查。
    """
    push = _on_section().get("push")
    assert isinstance(push, dict), (
        f"on.push 不是映射（实得 {type(push).__name__}）—— 合并后在 main 上重跑这条"
        "退路没了，而它是 pull_request 触发被绕过时唯一还能发现问题的地方"
    )
    assert sorted(push) == ["branches"], (
        f"on.push 下面出现了 branches 之外的键：{sorted(push)}\n"
        "尤其不许有 paths / paths-ignore —— 那会让「合并后在 main 上重跑」这条退路\n"
        "也被过滤掉。届时一个只改 workflow、自我排除的 PR 将完全无人发现。"
    )
    assert push["branches"] == ["main"], (
        f"on.push.branches 不再是 ['main']（实得 {push['branches']}）—— "
        "合并后的兜底重跑必须发生在默认分支上"
    )


def test_job_name_equals_canonical_backend_context():
    """`backend-tests.yml` 里必须有**恰好一个** job，其 `name` 等于 canonical 常量，
    且那个 job **真的在跑 pytest**。

    为什么是「等于」而不是「在清单里」（spec §3.2.1）：清单里有多条 context，写成成员关系时，
    把这个 job 改名成**清单里的另一条**（例如 Catalyst 那个名字）判据仍会绿，而必需检查
    `backend pytest (full suite)` 永远等不到结果 → 全仓 PR 死锁。

    为什么还要「真的在跑 pytest」：只断言「有 job 叫这个名字」的话，挂一个同名空壳 job
    就能让必需检查报绿，而真正的后端套件不再门控合并。
    """
    mod = _builder()
    doc = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    jobs = doc.get("jobs")
    assert isinstance(jobs, dict) and jobs, (
        f"{WORKFLOW.name} 里取不到 jobs 段 —— 本判据的解析口径已失效"
    )
    named = [j for j in jobs.values()
             if isinstance(j, dict) and j.get("name") == mod.BACKEND_TESTS_CONTEXT]
    assert len(named) == 1, (
        f"名为 canonical 必需 context {mod.BACKEND_TESTS_CONTEXT!r} 的 job 有 "
        f"{len(named)} 个（应恰好 1 个）。实得全部 job 名："
        f"{sorted(n for n in (j.get('name') for j in jobs.values() if isinstance(j, dict)) if n)}\n"
        "GitHub 的必需检查按 job 显示名匹配：名字对不上 ⇒ 该检查永远停在\n"
        "「Expected — waiting for status」⇒ **全仓 PR 都合不了**。\n"
        "要改名，必须同时改 scripts/governance/build-protection-put-payload.py 的\n"
        "BACKEND_TESTS_CONTEXT，并重新跑一次 admin 应用脚本把 ruleset 也改掉。"
    )
    job = named[0]
    steps = [s for s in (job.get("steps") or []) if isinstance(s, dict)]

    # ① 必须真的跑那条被批准的全套命令。
    #    ⚠️ 只查「run 里有 pytest 字样」是不够的：`run: echo pytest` 就能骗过去
    #    （codex code-R2 指出，复核属实）。所以要求 `-m pytest` + 目标目录 `tests/`，
    #    且该步骤的 working-directory 是 backend（否则跑的是别处的测试）。
    runners = [s for s in steps
               if "-m pytest" in (s.get("run") or "") and "tests/" in (s.get("run") or "")]
    assert runners, (
        f"名为 {mod.BACKEND_TESTS_CONTEXT!r} 的 job 里没有任何一步真的在跑后端全套 "
        "（判据：run 同时含 `-m pytest` 与 `tests/`）—— "
        "必需检查会由一个不跑测试的 job 报绿，等于门控失效。\n"
        f"实得各步骤 run 首行：{[((s.get('run') or '').strip().splitlines() or ['<无 run>'])[0][:60] for s in steps]}"
    )
    assert any(s.get("working-directory") == "backend" for s in runners), (
        "跑 pytest 的那一步没有 `working-directory: backend` —— "
        "跑的可能不是后端那套测试"
    )

    # ② 不许有任何抑制失败的开关：加了 continue-on-error 之后，
    #    测试红了这道 job 照样绿，必需检查就形同虚设（codex code-R2）。
    def _suppresses(node):
        return str(node.get("continue-on-error", "")).lower() == "true"

    assert not _suppresses(job), (
        f"job {mod.BACKEND_TESTS_CONTEXT!r} 设了 continue-on-error: true —— "
        "测试失败不会让这道必需检查变红，门控形同虚设"
    )
    bad = [(s.get("name") or s.get("uses") or "?") for s in steps if _suppresses(s)]
    assert not bad, (
        f"这些步骤设了 continue-on-error: true：{bad} —— "
        "其中任何一步若是跑测试的那步，失败都不会传播到必需检查上"
    )


def test_backend_context_is_in_canonical_required_list():
    """canonical 清单里必须留着这一项，否则应用脚本不再保证该必需检查在位。"""
    mod = _builder()
    assert mod.BACKEND_TESTS_CONTEXT in mod.REQUIRED_CONTEXTS, (
        "BACKEND_TESTS_CONTEXT 不在 REQUIRED_CONTEXTS 里 —— "
        "应用脚本只遍历 REQUIRED_CONTEXTS，将不再保证该必需检查在位"
    )
