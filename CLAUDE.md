# Kline Trainer — Claude 协作规则

1. **全程中文**沟通。

2. **codex review 分级触发**：

   - **强制走 `codex:adversarial-review` + PR + 你手工 merge**：
     - 所有源码文件改动（`.swift` / `.py` / `.ts` 等）
     - M0 契约字段变更（DB schema / OpenAPI / Swift 模型 / AppError / 并发约定）
     - DB migration 文件（SQL / GRDB migrator 等）
     - 新模块、新公共接口、破坏性 API
     - 跨模块依赖图调整
     - `modules` / `plan` 文档新增章节或任何实质性改写
     - `CLAUDE.md` 本身的修改
     - **Trust-boundary / 配置 / 工具链文件**（catch-all，含但不限于）：
       - `.claude/**`（settings / hooks / agents / skills）
       - `.github/**`（workflows / actions / branch protection / CODEOWNERS 等）
       - CI / 自动化脚本（`scripts/**`、`Makefile`、`Fastfile` 等）
       - 依赖 / lockfile（`Package.resolved` / `Podfile.lock` / `requirements.txt` / `package.json` / `pnpm-lock.yaml` 等）
       - 版本 / 发布配置（`pyproject.toml` / `*.podspec` / Docker / `docker-compose.yml` 等）

   - **作者自判（Claude 建议走但不强制）**：
     - `docs/` 目录下非实质性文档新建 / 重写（例如说明文档、操作手册）

   - **免 review，可直接 commit + push 到 main**（commit message 清楚即可，不开 PR）——**仅限纯表面**改动：
     - typo / 标点 / 排版（不改语义）
     - 注释润色（不改对应代码行为）
     - Markdown 格式调整（链接 / 标题层级 / 列表样式）

   - **禁止**以"免 review"名义：
     - 混入任何实质改动（接口 / 字段 / 业务逻辑 / 权限 / 配置）→ 自动回到"强制"类
     - 混入任何上列 trust-boundary / 配置 / 工具链文件改动 → 自动回到"强制"类，不论看起来多像"排版"

   - **adversarial-review 闭环自治**：一旦进入强制类改动的 review 流程（Claude 起草 → 开 PR → 跑闸门 → 修 findings → 再跑闸门），**该循环内的所有 git / gh / codex 操作自动执行，不请示用户**。用户**仅在**以下两个 out 节点介入：
     1. codex 给 `approve` + PR 准备好 → 通知用户 merge
     2. 连续 3 轮仍 `needs-attention` → 停止推进，提交用户决定方向
     中间的 commit / push / gh pr edit / 修 findings / 再跑 codex 等动作无需任何确认。

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
