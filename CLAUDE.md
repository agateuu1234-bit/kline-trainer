# Kline Trainer — Claude 协作规则

1. **全程中文**沟通。

2. **codex review 分级触发**：

   - **强制走 `codex:adversarial-review` + PR + 你手工 merge**：
     - 所有源码文件改动（`.swift` / `.py` 等）
     - M0 契约字段变更（DB schema / OpenAPI / Swift 模型 / AppError / 并发约定）
     - 新模块、新公共接口、破坏性 API
     - 跨模块依赖图调整
     - `modules` / `plan` 文档新增章节或任何实质性改写
     - `CLAUDE.md` 本身的修改

   - **作者自判（Claude 建议走但不强制）**：
     - `docs/` 目录下非实质性文档新建 / 重写（例如说明文档、操作手册）

   - **免 review，可直接 commit + push 到 main**（commit message 清楚即可，不开 PR）：
     - typo / 标点 / 格式 / 排版
     - 注释润色
     - 不改语义的措辞调整

   - **禁止**以"免 review"名义混入实质改动；一旦涉及接口 / 字段 / 业务逻辑 → 自动回到"强制"类。

   - **3 轮停止条款**：连续 3 轮 `codex:adversarial-review` 未收敛 → 停止推进，提交用户批准（3 轮是**上限**，不是下限；跑到 `approve` 即止）。

   - **`codex:rescue` 仅作辅助工具**（诊断 / 问答 / 辅助思考），**不作 review 通道**；prompt 自由，输出不必物化、不必归档。

3. **每个模块代码验收必须给人工验证方案**：交付时附一份**无代码经验者也能按步骤执行**的验证清单（操作步骤 + 预期现象 + 通过/失败判据），并**走完人工验证**再算完成。

4. **工具 / 流程规范**：
   - 项目**全程用 GitHub 管理**（分支、PR、Issue、Review）。
   - 开发流程按 `superpowers` skills 推进，不跳步。
   - **分支隔离**（`superpowers:using-git-worktrees` 场景触发）：下列情况**必须**用 `git worktree` 创建独立工作目录：
     - 并行多个 PR（同时跑 2 个及以上 PR 互不阻塞）
     - 长时 codex 闸门期间想并行做别的事
     - 代码实施阶段多模块并行开发
     其它场景（小单 PR / 纯文档修正）可直接在主目录切分支。
   - **前端设计必须先走 `frontend-design` skill**：未经此 skill 产出设计稿/组件方案前，**禁止直接写 UI 代码**。
