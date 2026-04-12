# Kline Trainer — Claude 协作规则

1. **全程中文**沟通。
2. **所有 Claude 输出必须过 codex**：代码、方案、文档、设计决定，都要让 codex 做 review 或对抗性 review，通过后才交付。若**连续 3 轮**（每轮 = Claude 回应 + codex review）仍未完全达成一致，**停止推进，提交给用户批准**。
   - **codex 对抗性 review 通道选择**（按对象能否物化为 **diff-able artifact** 判定，非凭作者主观声称）：
     - **可物化为 diff-able artifact 的对象**：**必须**用 `codex:adversarial-review`。以下 4 种 diff 形态全部视为"可 diff"：
       1. PR diff（`--base <target-branch>`）
       2. 首提交 empty-tree diff（工具支持后启用，当前用 rescue 兜底，见下）
       3. `git diff --no-index` 两份独立文件/目录的对比
       4. stash diff（`git stash show -p`）
       额外：**任何 Claude 文本输出**（方案 / 文档 / 设计稿 / 草稿）默认**必须**物化为 PR / commit / Issue / `docs/` 目录下的 markdown 后走 `codex:adversarial-review`。**仅当**存在以下**可证实阻塞**之一时才允许不物化：(a) 权限阻塞（无仓库写权限）、(b) 工具故障（git / gh / 磁盘不可用）、(c) 敏感信息不可落盘、(d) 其他可在 Rescue Decision 中举证的阻塞。"成本高""麻烦""还没建 PR"等**主观口径一律不成立**。
     - **确不可物化为 diff-able artifact 的对象**（纯口头概念讨论、纯脑内方案等）：允许用 `codex:rescue` 承担对抗性 review，但必须同时满足**入口 / 出口 / 归档**三道闸门：
       1. **入口：结构化 Rescue Decision**（记入 commit message / PR 描述 / 归档 markdown 的固定字段块）必须包含：`jobId`、`对象`、`调用理由`，以及**逐项列出** PR diff / 首提交 empty-tree diff / `git diff --no-index` / stash diff / 物化为 PR / 物化为 commit / 物化为 Issue / 物化为 `docs/` markdown 这 **8 种物化路径**为何不适用的具体理由；**禁止** "N/A"、"纯概念讨论"、"不适用" 等无对象、无失败原因的套话；任一路径可行 → **禁用** rescue，必须先物化后走 `codex:adversarial-review`。
       2. **出口：契约等价 adversarial-review schema**。rescue 输出必须给出：`verdict`（枚举值**仅限** `approve` 或 `needs-attention`，与 adversarial-review 一致；ship/no-ship 等自然语言判断只能放 `summary` / body，**不得**作为 verdict 取值）、`artifact anchor`（具体对象 / 章节 / 行号引用）、`失败场景`、`修复建议`、`置信度`（0-1）、`残余风险`。无 finding 时也必须显式声明残余风险。交付前必须过**独立**的人工 checklist 或脚本 checker 对照本契约——solo dev 场景下**不得**由 rescue 发起者同时担任 checker，必须**二选一**：(a) 脚本 checker（对 rescue 输出 JSON 做字段完备性 + enum 合规检查）、(b) 再次交给 `codex:adversarial-review`（物化 rescue 输出后）做二次闸门；检查执行者与结果必须随 rescue 输出一起归档。不满足即视为未通过 review。
       3. **归档**：rescue 的完整输入 prompt + 输出必须**自身物化**为 Issue 或 `docs/reviews/YYYY-MM-DD-<slug>.md`，成为后续可审计对象；这条在自动化工具创建追踪 Issue 能力到位前即日生效。
     - **两种通道**下，均**不得**用普通 review 或其他非对抗性通道替代对抗性立场。
     - **工具缺陷兜底**：当前 `codex:adversarial-review` 未实现 empty-tree base / `--no-index` 支持，该缺口由独立 Issue 跟踪。工具修复前，该类对象暂走 rescue 三闸门；工具修复后相应对象**自动**回归 `codex:adversarial-review`，无需改本规则。
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
