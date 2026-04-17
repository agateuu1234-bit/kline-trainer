# CLAUDE.md 重置与 Superpowers/Codex 流程下沉设计

**日期**：2026-04-18（R12+ 补增 R13 用户方向决策后融入）  
**状态**：**收敛终稿 · 6 条方向性决策已融入 · 准备进 writing-plans 阶段**  
**作者**：Claude（起草），Codex（对抗性 review R1/R3/R5/R7/R9/R11 共 6 次）  
**Review 历史**：R1-R12 对抗性 review 已结束；用户在 escalation 后追加 6 条方向性决策（不再通过 Codex 辩论，而是直接写入）：
1. 方向 🅰️.lite-v2（Actions 跑 Codex）
2. CLAUDE.md 语言 = 全英文（R13 修正：去掉中英双语）
3. 对抗性 review 扩展到 brainstorming + writing-plans 阶段
4. 轮次定义：1 轮 = Codex + Claude 一来一回；3 轮内 approve → 自动进下一阶段不打扰；3 轮未收敛 → escalation
5. phase = 每个 plan 粒度
6. Skill gate 首行强制保留；`codex:adversarial-review` 是唯一 review 通道，`codex:rescue` 禁用作 review

---

## 1. 用户需求（保持 · 用户原话精炼）

1. CLAUDE.md 换成 Karpathy 4 条。
2. 按 Superpowers 工作流 + skills 工作，**强制执行到位**。
3. 所有 review 由 Codex 完成，Claude↔Codex 多轮对抗收敛。
4. 全流程 GitHub 管理。
5. 过程中尽量不打扰用户。
6. 仅阶段性人工验收需用户点头，方案**不懂代码者可执行**。
7. 重置既有环境，保留安全网 + 个人画像 + 项目快照。

---

## 2. 核心设计洞察

用现成 Superpowers skills（brainstorming / writing-plans / TDD / verification-before-completion / requesting-code-review / receiving-code-review / finishing-a-development-branch 等）+ 现成 `codex:adversarial-review`；**不新建项目专属 workflow skill**；**核心防线在 GitHub Actions（base-branch 所有权）**；本地 Claude 不经手 review 产出；CODEOWNERS + required checks 守 trust-boundary。

---

## 3. 根本 tradeoff（终态）

| Tradeoff | 状态 |
|---|---|
| 自动化 vs 不可伪造 | **🟢 Codex review 在 Actions runner（base branch）跑**：`workflow_run` 模式 → PR 不能替换 verifier 代码；OPENAI_API_KEY 存 Secrets，Claude 不可读；verdict 由 Actions POST check-run + CODEOWNERS 对 trust-boundary 强制 owner review |
| 不打扰 vs 强制到位 | **🟢 精简到最少必要介入**（见 §4.11）|
| LLM non-det 收敛 vs 绝对审批 | **🟢 `codex-verify-pass` 是 required check，仅 app_id=15368 发的 success 才过**；3 轮 escalation 机制限时 |

---

## 4. 工件清单

### 4.1 `CLAUDE.md`（完全替换 · **全英文**）

```markdown
# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with
project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial
tasks, use judgment.

## 1. Think Before Coding
[Karpathy 原文全文]

## 2. Simplicity First
[Karpathy 原文全文]

## 3. Surgical Changes
[Karpathy 原文全文]

## 4. Goal-Driven Execution
[Karpathy 原文全文]

---

## Repository governance backstop (project-specific · non-overridable)

The four principles above are day-to-day coding guidelines. Even if every hook,
skill, or config is broken or missing, the following project invariants still hold:

1. All PRs that touch the repository go through `codex:adversarial-review`,
   with the review verdict enforceable as a required GitHub status check
   (not self-attested).

2. Every module/phase delivery (default: 1 plan = 1 phase) MUST include a
   non-coder-executable acceptance checklist (action / expected / pass-fail;
   Chinese; forbidden phrases listed in `.claude/workflow-rules.json`).

3. Memory cleanup is destructive and REQUIRES explicit user checkpoint
   confirmation — never automatic.

4. Every work-advancing response from Claude MUST begin with its first line
   as `Skill gate: <skill-name>` or `Skill gate: exempt(<whitelist-reason>)`.
   Exemption reasons are restricted to the whitelist in
   `.claude/workflow-rules.json`.

Governance / tooling / process changes are out of scope for the four principles
above; they go through `superpowers:brainstorming` → `superpowers:writing-plans`
→ `codex:adversarial-review` → PR review. See `.claude/workflow-rules.json` and
the SessionStart hook for the authoritative skill/trust-boundary mapping.

`codex:adversarial-review` is the ONLY Codex review channel. `codex:rescue` is
an assistance tool (diagnosis / Q&A / auxiliary reasoning); it is NOT a review
channel and must not be used as one.
```

### 4.2 `.claude/workflow-rules.json`（机读规则源）

```json
{
  "trust_boundary_globs": [
    ".claude/**", ".github/**", "CLAUDE.md",
    "src/**", "ios/**/*.swift", "**/*.py", "**/*.ts", "**/*.tsx",
    "kline_trainer_modules*.md", "kline_trainer_plan*.md",
    "docs/governance/**", "docs/superpowers/specs/**", "docs/superpowers/plans/**",
    "modules/**", "plan/**",
    "fixtures/**", "tools/fixtures/**", "**/fixtures/**", "**/golden/**",
    "**/migrations/**", "**/*.sql", "**/openapi*.yml", "**/openapi*.yaml", "**/schema.graphql",
    "**/*.xcodeproj/**", "**/*.xcworkspace/**", "**/project.pbxproj", "**/*.xcassets/**",
    "backend/**", "**/.env*", ".gitignore", "README.md", "docs/policy/**",
    "scripts/**", "Makefile", "Fastfile", "fastlane/**",
    "**/Package.resolved", "**/Podfile.lock", "**/requirements*.txt",
    "**/package.json", "**/pnpm-lock.yaml", "**/yarn.lock", "**/poetry.lock",
    "**/pyproject.toml", "**/*.podspec",
    "**/Dockerfile", "**/docker-compose*.yml", "**/docker-compose*.yaml",
    "codex.pin.json"
  ],
  "trust_boundary_whitelist": ["ios/**/.gitkeep", "**/.DS_Store", "*.lockb"],
  "trust_boundary_coverage_test": {
    "source": "git ls-files",
    "glob_engine": "python pathlib",
    "symlink_policy": "follow=false",
    "fail_on_uncovered": true
  },

  "skill_entry_map": {
    "session_start_or_cross_session_resume": "superpowers:using-superpowers",
    "new_feature_new_component_behavior_change": "superpowers:brainstorming",
    "multi_step_task_with_approved_spec": "superpowers:writing-plans",
    "no_spec_yet": "superpowers:brainstorming",
    "execute_existing_plan_independent_tasks": "superpowers:subagent-driven-development",
    "execute_existing_plan_single_thread": "superpowers:executing-plans",
    "two_or_more_independent_investigations": "superpowers:dispatching-parallel-agents",
    "write_production_code_for_feature_bugfix_refactor": "superpowers:test-driven-development",
    "behavior_neutral_doc_or_config_exempt_from_tdd": "(exempt: behavior-neutral)",
    "bug_test_failure_unexpected_behavior": "superpowers:systematic-debugging",
    "before_completion_success_pass_commit_pr_claim": "superpowers:verification-before-completion",
    "self_review_before_merge": "superpowers:requesting-code-review",
    "receive_review_feedback": "superpowers:receiving-code-review",
    "mandatory_review_class_change": "codex:adversarial-review",
    "finishing_phase_wrap_up": "superpowers:finishing-a-development-branch",
    "create_or_modify_skill": "superpowers:writing-skills",
    "multi_pr_parallel_or_isolation_needed": "superpowers:using-git-worktrees",
    "ui_frontend_code": "frontend-design:frontend-design"
  },

  "task_class_to_required_stages": {
    "feature_or_bugfix": {
      "ordered_stages": [
        "brainstorming",
        "writing-plans",
        "test-driven-development",
        "verification-before-completion",
        "requesting-code-review",
        "codex:adversarial-review (if trust-boundary touched)"
      ]
    },
    "governance_process_toolchain_change": {
      "ordered_stages": [
        "brainstorming",
        "writing-plans",
        "codex:adversarial-review",
        "verification-before-completion"
      ]
    },
    "pure_query_or_single_step_no_semantic_change": {
      "ordered_stages": [],
      "exempt_valid": true
    }
  },

  "task_state_file": ".claude/state/task-log.jsonl",
  "task_state_policy": {
    "append_only": true,
    "hook_owned_write": true,
    "claude_write_denied": true,
    "evidence_required_per_stage": {
      "brainstorming": "spec file sha",
      "writing-plans": "plan file sha",
      "TDD": "test file sha + test run output sha",
      "verification": "verification output sha",
      "codex-review": "codex JSON digest"
    }
  },

  "skill_gate_policy": {
    "required_on_any_work_advancing_response": true,
    "first_line_format": "Skill gate: <skill-name>",
    "exempt_format": "Skill gate: exempt(<whitelist-reason>)",
    "exempt_reason_whitelist": [
      "behavior-neutral",
      "user-explicit-skip",
      "read-only-query",
      "single-step-no-semantic-change"
    ],
    "degradation_policy": {
      "allowed": "execution downgrade (subagent→manual / parallel→serial)",
      "forbidden": "skipping any skill pipeline stage (TDD → impl → review → verification)"
    },
    "wrong_skill_remediation": "acknowledge + restart from correct skill; user inquiry = trigger"
  },

  "adversarial_review_loop": {
    "round_definition": "1 round = 1 Codex half-round + 1 Claude half-round (来回算 1 轮)",
    "max_rounds": 3,
    "on_converge_within_3": "自动进下一阶段，不打扰用户",
    "on_non_convergence": "escalation 通知用户决策 (payload: verdict 序列 + 未解 findings + Claude rationale + 3 tradeoff 位置 + bypass 选项含 cost)",
    "applies_to_artifacts": [
      "brainstorming 产出的 spec (.md in docs/superpowers/specs/)",
      "writing-plans 产出的 plan (.md in docs/superpowers/plans/)",
      "feature PR 的代码 (via Actions workflow)"
    ],
    "review_channel": "codex:adversarial-review",
    "forbidden_channels": ["codex:rescue"],
    "rescue_purpose": "仅诊断 / 问答 / 辅助思考；禁止当 review 通道",
    "per_round_artifact": {
      "spec_blob_sha": "required (git hash-object)",
      "codex_json_digest": "required (sha256)",
      "review_target_sha": "required (= spec blob sha at review time)"
    },
    "duplicate_same_blob_not_counted": true,
    "only_approve_on_pr_head_sha_merges_code": true,
    "execution_venue_by_stage": {
      "brainstorming_spec": "Claude 本地调 codex-companion (best-effort 第一层)",
      "writing_plans_plan": "Claude 本地调 codex-companion (best-effort 第一层)",
      "pr_feature_code": "GitHub Actions runner (不可伪造第二层兜底;PR 阶段会同时 review 该 PR 里的 spec/plan 文件,等于 spec/plan 被 Actions 再审一次)"
    }
  },

  "phase_delivery": {
    "default_unit": "每个 plan 作为 1 个 phase delivery",
    "exemption_mechanism": "plan 文件 frontmatter 可标 phase_delivery: false + 写 exemption_reason；豁免本身经 Codex review 把关",
    "verification_template": {
      "audience": "用户本人（不懂代码；语音输入；需术语翻译 + 动作化步骤）",
      "language": "中文（用户面向），JSON 键名英文",
      "required_sections": [
        "action: 可复现的 UI/命令/按钮级操作步骤",
        "expected: 可观察的 UI 状态 / 文件变化 / 命令输出",
        "pass_fail: 明确的通过/失败判据（二元可判）"
      ],
      "evidence_requirements": [
        "关键步骤必须包含截图或命令输出实录",
        "通过判据必须是二元可判"
      ],
      "forbidden_phrases": [
        "验证通过即可",
        "看起来正常",
        "应该没问题",
        "should work",
        "looks fine"
      ],
      "delivery_medium": {
        "primary": "PR body (markdown 三段式模板)",
        "acceptance_evidence_upload": "PR comment 贴截图 / 命令输出",
        "alternative_for_ui_heavy": "附带录屏链接"
      }
    },
    "plan_0a_classification": "治理/基础设施 plan → phase_delivery: true，验收内容为机制验证而非业务功能验证",
    "business_plan_examples": "K 线渲染、RSI 指标 等业务模块 plan → phase_delivery: true，验收内容为 UI/功能验证"
  },

  "hat_signoff_verification": {
    "source": "docs/governance/signing-rules.md",
    "author": "non-bot GitHub user (repo owner, not claude-code / any bot)",
    "timing": "comment posted AFTER latest PR commit AND AFTER required checks pass",
    "staleness": "new push → signoff invalidated, must re-sign",
    "format": "exact hat string match (not substring; not PR body text; not template placeholder)"
  },

  "user_escalation_ladder": {
    "admin_bypass_definition": "GitHub audit-log admin action + required check conclusion 保持 failure/neutral (not success)",
    "forbidden_bypass_paths": [
      "Claude-authored PR body 当 bypass 记录",
      "Claude-authored comment 当 bypass 记录",
      "改 check-run conclusion 为 success"
    ]
  },

  "bootstrap_lock": {
    "location": ".github/bootstrap-lock.json",
    "fields": ["pr_number", "pr_head_sha", "expiry_utc", "codex_json_digest", "consumed", "branch_protection_verified_after_merge"],
    "write_permission": "GitHub Actions workflow only (Claude deny)",
    "reuse_prohibited": true,
    "check_workflow": ".github/workflows/check-bootstrap-used-once.yml"
  }
}
```

### 4.3 `.claude/hooks/` 套件

| Hook | 脚本 | 作用 |
|---|---|---|
| SessionStart | `session-start.sh` | 注入 workflow-rules.json 摘要 + skill_gate_policy + 当前分支 + 最近 PR 状态 |
| PreToolUse Edit/Write | `pre-edit-trust-boundary-hint.sh` | 命中 trust-boundary 提示"需 Codex review + required check pass" |
| PreToolUse Bash(git commit) | `pre-commit-diff-scan.sh` | 扫 staged diff；若碰 trust-boundary 且当前分支=main → block |
| PreToolUse Bash(git push) | `guard-git-push.sh`（现有，保留） | 禁 push main/master 任意形式 |
| PreToolUse Bash(gh pr merge) | `pre-merge-warn.sh` | 本地 warn only |
| Stop | `stop-response-check.sh` | **关键加固**：<br>1) 首行 `Skill gate:` 语法 + 白名单 exempt reason<br>2) 完成关键词整句检测（中英）+ 验证输出对比<br>3) Skill gate 缺失 → block 要求重写 |

### 4.4 `.claude/settings.json` deny 扩展

保留现有 allow/ask/deny。deny 扩充为 allowlist 思路（禁所有写 GitHub 的 gh 命令 + HTTP 工具 + 嵌套 shell + `.claude/**` `.github/**` shell 写 + sudo）。完整清单见 R10-R12 版本（此处略，约 60 条 deny 规则）。

### 4.5 `.github/workflows/codex-review-collect.yml`

PR 触发 · 无凭据 · 收集 PR metadata 作 artifact。

### 4.6 `.github/workflows/codex-review-verify.yml`（核心防线）

`workflow_run` 触发（跑 base branch 代码；PR 不能替换 verifier）+ `environment: codex-review`（protected environment 限制 secret 暴露）+ `npm ci --ignore-scripts` 装 pinned codex + 全树 integrity 校验 + `OPENAI_API_KEY` 跑 review + `GITHUB_TOKEN` POST `codex-verify-pass` check-run。

### 4.7 `.github/workflows/codex-review-rerun.yml`

`issue_comment` 触发 `/codex-review` + `getCollaboratorPermissionLevel` 验 actor write/admin 权限 + 用 `event.issue.number` fetch PR。

### 4.8 `.github/workflows/codeowners-config-check.yml` / `branch-protection-config-self-check.yml`

自跑校验：CODEOWNERS 完整覆盖 + 分支保护配置没被放宽。

### 4.9 `.github/CODEOWNERS`

```
/.github/**                 @<github-username>
/.claude/**                 @<github-username>
/CLAUDE.md                  @<github-username>
/codex.pin.json             @<github-username>
/docs/governance/**         @<github-username>
/kline_trainer_modules*.md  @<github-username>
/kline_trainer_plan*.md     @<github-username>
/fixtures/**                @<github-username>
/tools/fixtures/**          @<github-username>
```

### 4.10 `codex.pin.json`

Codex 版本 + 全树 sha256 integrity。Bootstrap 时用户手填 upstream npm registry digest。

### 4.11 用户介入点汇总（最终）

**一次性 Bootstrap**：
1. Pre-bootstrap admin setup：`gh secret set OPENAI_API_KEY` / 填 codex.pin.json / 安装 branch protection
2. Bootstrap PR：手动审 workflow 源代码 + 本地最后一次 Codex review + merge
3. Memory 清理 checkpoint：看 gitleaks 中文报告 + 同意

**日常每个大任务**：
1. brainstorming 开始：跟 Claude 对齐需求（本来就要）
2. brainstorming 结束：**不打扰**（Codex 3 轮 approve 情况下）
3. writing-plans 结束：**不打扰**（Codex 3 轮 approve 情况下）
4. PR 实施 review：**不打扰**（Codex 3 轮 approve 情况下）
5. CODEOWNERS（触 trust-boundary 时）：点 Approve
6. PR merge：点 Merge 按钮
7. Phase delivery：按验收清单执行 + 留 comment + Approve + Merge

**异常**：
- 任一 Codex review 点 3 轮未收敛 → escalation 通知

### 4.12 Memory 清理策略

清：`project_workflow_rules.md` / `feedback_superpowers_pipeline_strict.md` / `feedback_adversarial_review_alternating.md` / `feedback_debate_intermediate_no_materialize.md` / `feedback_approval_at_decision_points.md`（被 workflow-rules.json 替代）

留：沟通偏好 4 条（`user_communication_style` / `feedback_claude_md_length` / `feedback_xcode_cli_first` / `feedback_claude_md_compliance_gap`）+ 项目事实 3 条（`project_modules_v1.4_frozen` / `project_review_strategy_deferred` / `feedback_branch_protection_single_dev`）

流程：inventory 摘要（非内容）commit + 本地加密归档（`~/.kline-memory-archive/2026-04-18-pre-reset/`）+ gitleaks 中文报告 + 用户 checkpoint 勾选同意才实际删。

---

## 5. Bootstrap 序列

**Pre-bootstrap（用户一次性手动）**：
1. `gh secret set OPENAI_API_KEY`
2. 手动查 npm registry 填 `codex.pin.json`
3. 用户手动 `gh api PUT /repos/.../branches/main/protection` 安装分支保护（admin 操作）
4. 验证分支保护生效

**Bootstrap PR**：
1. Claude 开 PR 含本 spec 衍生的所有工件（CLAUDE.md / workflow YAMLs / .claude/** / CODEOWNERS / codex.pin.json / 其他）
2. 用户本地跑一次 `codex:adversarial-review`（**最后一次本地 review**）
3. 用户审 workflow 源代码
4. 用户 web merge PR（此时 branch protection 已启用）

**Post-merge**：
- 验证 verify workflow 生效：开一个小测试 PR 看 `codex-verify-pass` check 跑起来

**`git push origin main` 本地 deny 全程有效**。

---

## 6. 未决项（技术实现 · writing-plans 阶段细化）

1. 每个 workflow YAML 的具体代码
2. `.claude/scripts/verify-codex-tree.mjs` 代码
3. hook 脚本代码
4. state task-log.jsonl schema
5. `codex.pin.json` 首填流程
6. gitleaks 配置

---

## 7. 非目标

- Karpathy 原文修改
- superpowers / codex 插件本体改动
- Kline trainer 业务模块改动（本 spec 仅治理基础设施）

---

## 8. Review 历史（归档）

R1-R12 详细 findings 和响应见 git 历史（本 spec 前版本 blob sha 记录）。R13 以后的方向性决策由用户直接注入，不再通过 Codex 辩论。

终态 spec 走 writing-plans 阶段时**将再跑一次 Codex 3 轮对抗性 review**（新规则下的首次实践）。
