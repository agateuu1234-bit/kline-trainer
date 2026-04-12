# Kline Trainer — Claude 协作规则

1. **全程中文**沟通。
2. **所有 Claude 输出必须过 codex**：代码、方案、文档、设计决定，都要让 codex 做 review 或对抗性 review，通过后才交付。若**连续 3 轮**（每轮 = Claude 回应 + codex review）仍未完全达成一致，**停止推进，提交给用户批准**。
   - **codex 对抗性 review 通道分流**（按对象是否可物化为 diff-able artifact，非作者主观声称）：
     - **可物化对象** → **必须**用 `codex:adversarial-review`。
     - **确不可物化对象** → 用 `codex:rescue` 兜底，且必须同时满足：
       - 出口 JSON 通过 codex 官方 `review-output.schema.json` 校验；
       - 入口（Rescue Decision）+ 出口 + checker 结果一并归档；
       - checker 与 rescue 发起者必须独立：solo dev 场景**强制走二次 `codex:adversarial-review`** 作为独立 gate（脚本 checker 在 solo dev 下仍是自证，不采用）。
     - 两种通道均**不得**降级为普通 review 或其他非对抗性通道。
     - **细则见** `docs/reviews-workflow.md`（8 种物化路径、Rescue Decision 字段、敏感/工具阻塞下的脱敏归档、工具缺陷兜底等）；该文件演进与 CLAUDE.md 一致走 adversarial-review。
3. **每个模块代码验收必须给人工验证方案**：交付时附一份**无代码经验者也能按步骤执行**的验证清单（操作步骤 + 预期现象 + 通过/失败判据），并**走完人工验证**再算完成。
4. **工具 / 流程规范**：
   - 项目**全程用 GitHub 管理**（分支、PR、Issue、Review）。
   - 开发流程**必须严格按 superpowers 的全部 skills 流程推进**，不得跳步、不得合并阶段：
     - 需求/设计阶段：`brainstorming` → `writing-plans`
     - 实施阶段：`executing-plans` + `TDD`（`test-driven-development`）
     - 交付阶段：`verification-before-completion` → `requesting-code-review` → `finishing-a-development-branch`
     - 遇到 bug：先 `systematic-debugging` 再动手
     - 任一阶段跳过 → 停止推进并提交用户批准。
   - **前端设计必须先走 `frontend-design` skill**：未经此 skill 产出设计稿/组件方案前，**禁止直接写 UI 代码**。
