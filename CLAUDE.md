# Kline Trainer — Claude 协作规则

1. **全程中文**沟通。
2. **所有 Claude 输出必须过 codex**：代码、方案、文档、设计决定，都要让 codex 做 review 或对抗性 review，通过后才交付。若**连续 3 轮**（每轮 = Claude 回应 + codex review）仍未完全达成一致，**停止推进，提交给用户批准**。
   - **codex 进行对抗性 review 时必须使用 `codex:adversarial-review` skill**，不得用普通 rescue 或其他通道替代。
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
