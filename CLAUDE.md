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
   - **开发流程强制按入口 skill 推进**（入口 skill 触发是必需的，不是可选）。常用入口映射：
     - 任何任务开始时 / 跨 session 恢复上下文 → `superpowers:using-superpowers`
     - 新功能 / 新组件 / 加功能 / 修改行为 / "下一步做什么"类提问 → `superpowers:brainstorming`
     - 已有 approved spec 或明确 requirements 的多步任务开工前 → `superpowers:writing-plans`；spec 未明 → 先 brainstorming
     - 执行已有书面 implementation plan 且任务独立 → `superpowers:subagent-driven-development`；单线推进 → `superpowers:executing-plans`
     - 2+ 独立调查 / 故障域可并行 → `superpowers:dispatching-parallel-agents`
     - 实现 feature / bugfix / refactor / 行为变更 写生产代码前 → `superpowers:test-driven-development`（**行为中性**的配置 / 纯文档 / 流程文本除外；feature flag / 运行时配置 / 依赖设置等**改变行为**的 config 仍触发 TDD）
     - 遇到 bug / test 失败 / 意外行为 → 先 `superpowers:systematic-debugging`
     - 任何成功 / 完成 / 通过声明之前、commit / PR / 进入下一任务之前 → `superpowers:verification-before-completion`
     - 合并前自审 → `superpowers:requesting-code-review`（**不替代**规则 2 的 `codex:adversarial-review`）
     - 收到 review 反馈 → `superpowers:receiving-code-review`（只用于处理 findings）
     - 完成阶段收尾 → `superpowers:finishing-a-development-branch`
     - 新建 / 修改 skill 本身 → `superpowers:writing-skills`
     - （`superpowers:using-git-worktrees` 与 `frontend-design:frontend-design` 见下方独立条款）
   - **Skill gate 首行标记**：Claude 每次**会推进工作状态**的响应首行必须写 `Skill gate: <skill-name>`（当前调用的 skill 名）；豁免响应首行写 `Skill gate: exempt(<reason>)`。
   - **豁免条件**（两种之一成立才可跳过入口 skill）：
     1. 用户**明确指向流程**的豁免（"跳过 superpowers" / "跳过 brainstorming" / "不要设计流程" 等明确指令）；**"按我说的做"不等于豁免**。
     2. 任务是**只读查询或不改变语义/行为/配置/策略的单步动作**；源码 / 配置 / 流程 / `CLAUDE.md` / `.claude/**` / `.github/**` 改动**不得**用该豁免。
   - **降级不免流程**：执行方式可降级（subagent → 手工 / 并行 → 串行），但 skill pipeline 各环节（TDD → 实现 → review → verification）不可因降级而省略。
   - **违反补救**：Claude 走错 skill / 漏写 Skill gate / 用错 exempt 理由 → 必须**主动承认并从正确 skill 重新开始**；用户追问等同于触发。
   - **分支隔离**（`superpowers:using-git-worktrees` 场景触发）：下列情况**必须**用 `git worktree` 创建独立工作目录：
     - 并行多个 PR（同时跑 2 个及以上 PR 互不阻塞）
     - 长时 codex 闸门期间想并行做别的事
     - 代码实施阶段多模块并行开发
     其它场景（小单 PR / 纯文档修正）可直接在主目录切分支。
   - **前端设计必须先走 `frontend-design` skill**：未经此 skill 产出设计稿/组件方案前，**禁止直接写 UI 代码**。

5. **Task 完成前强制检查清单**（每个 task 交付前逐条确认，不可跳过）：
   - [ ] 涉及 feature / bugfix / 行为变更？→ 走了 TDD 红-绿循环？
   - [ ] 走了对应的入口 skill？（对照规则 4 映射表）
   - [ ] 降级执行时 skill pipeline 各环节都没省略？
   - [ ] 有新鲜的验证证据？（不是"应该通过"，是刚跑的输出）
   - [ ] 附了无代码经验者可执行的人工验证清单？（规则 3）
   - [ ] 属于规则 2 强制类？→ PR + adversarial-review 闭环
