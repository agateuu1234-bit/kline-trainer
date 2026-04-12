# Reviews Workflow — codex 对抗性 review 执行细则

本文件承接 `CLAUDE.md` 规则 2 对 codex 对抗性 review 通道选择的细节要求，**CLAUDE.md 规则优先，本文件为其操作化展开**。

## 一、通道判定（复述 CLAUDE.md）

- **可物化为 diff-able artifact 的对象** → 必须走 `codex:adversarial-review`
- **确不可物化的对象** → 允许走 `codex:rescue`，但必须满足本文件全部闸门

## 二、"可物化"的 8 条路径

任一路径可行 → 必须先物化再走 `codex:adversarial-review`；一概**禁用** rescue 绕行。

### 4 种 diff 形态

1. PR diff（`--base <target-branch>`）
2. 首提交 empty-tree diff（工具支持到位前由 rescue 兜底，见 §六）
3. `git diff --no-index` 两份独立文件/目录对比
4. stash diff（`git stash show -p`）

### 4 种物化目标

5. 建 PR
6. 建 commit
7. 建 Issue
8. 写入 `docs/` 目录下 markdown

## 三、默认强制物化 + 可证实阻塞例外

**默认规则**：任何 Claude 文本输出（方案 / 文档 / 设计稿 / 草稿）**必须**物化为 §二 的某一路径后走 `codex:adversarial-review`。

**仅当**存在以下**可证实**阻塞才允许走 rescue：

| 阻塞类型 | 举证要求 | 处置 |
|---|---|---|
| (a) 权限阻塞 | 仓库写权限缺失的具体错误输出（如 `gh` 报 403） | 走 rescue + §四/五/六 闸门 |
| (b) 工具故障 | `git` / `gh` / 磁盘不可用的具体错误输出 | **停止推进 → 提交用户批准**（工具故障下无法保证归档与 checker 独立性，不绕行） |
| (c) 敏感信息不可落盘 | 具体敏感字段类型（如 secrets / 客户 PII） | **停止推进 → 提交用户批准**（敏感对象既禁落盘又要对抗性 review 本质冲突；不能让规则成为信息泄露通道） |
| (d) 其他可举证阻塞 | 必须独立可复核证据 | 走 rescue + §四/五/六 闸门；禁兜主观理由 |

**主观口径一律不成立**：`成本高` / `麻烦` / `还没建 PR` / `时间紧` / `暂时不想` 等。

## 四、rescue 入口：结构化 Rescue Decision

rescue 调用前必须产出以下字段块（记入 commit message / PR 描述 / 归档 markdown）：

```yaml
rescue_decision:
  job_id: <codex 分配的 jobId>
  object: <评审对象名与范围>
  trigger_reason: <为何需要对抗性 review>
  blockage_type: <a|d>   # 仅允许 (a) 或 (d)；(b)(c) 见 §三 处置
  blockage_evidence: <可复核证据；d 类必须独立可验证>
  path_rejection:              # 8 条路径逐条举证为何不适用
    pr_diff: <具体失败原因或阻塞证据>
    empty_tree_diff: <...>
    diff_no_index: <...>
    stash_diff: <...>
    materialize_pr: <...>
    materialize_commit: <...>
    materialize_issue: <...>
    materialize_docs_md: <...>
```

**禁止**以下套话占位：`N/A` / `不适用` / `纯概念讨论` / `暂无` / `见上`。每条必须给具体失败原因（如"路径 5：本对象为纯口头方案，尚未有任何文本稿可 commit"）。

## 五、rescue 出口：对齐 codex 官方 review schema

rescue 输出必须通过 codex 官方 `review-output.schema.json`（路径：`<plugin>/codex/<version>/schemas/review-output.schema.json`）校验。当前 schema 字段：

- `verdict`：枚举，仅 `approve` / `needs-attention`
- `summary`：string，非空（ship/no-ship 等自然语言判断放这里）
- `findings`：数组，每项必须含 `severity`（critical/high/medium/low）/ `title` / `body` / `file` / `line_start` / `line_end` / `confidence`（0-1）/ `recommendation`，`additionalProperties=false`
- `next_steps`：字符串数组

**残余风险**、**失败场景**、**artifact anchor** 等额外信息**只能**放入 `summary`、finding 的 `body` 或 `next_steps`，**不得**新增 top-level 字段——否则 schema 校验失败。

**无 finding 时**：`findings: []`，但 `summary` 必须显式说明"无 finding 的残余风险"。

## 六、独立 checker：强制二次 adversarial-review

solo dev 场景下"自编脚本 checker"本质仍是作者自证，因此**不采用**。唯一允许的独立 checker 是：

**强制走二次 `codex:adversarial-review`**——把 rescue 输出（及其 Rescue Decision）先物化到 `docs/reviews/YYYY-MM-DD-<slug>.md` 或 Issue，再对该 artifact 跑一次 `codex:adversarial-review` 做二次闸门。

**独立性硬约束**：
- 二次 adversarial-review **必须**在**独立 codex job/session** 中运行，**必须**分配新的 `jobId`，且 `checker_job_id != rescue_job_id`。
- 二次 adversarial-review **只能**接收已物化 artifact 与必要元数据（Rescue Decision、对象标识、对抗焦点）作为输入；**禁止**复用 rescue 会话上下文、禁止向其透露 rescue 内部推理过程。
- 无法创建独立 codex job/session 时（工具故障等），**停止推进 → 提交用户批准**，不绕行。
- `rescue_job_id` 与 `checker_job_id` 均须随归档落盘（见 §七）供事后核对。

二次 adversarial-review 结果必须随 rescue 一起归档（见 §七）。二次 adversarial-review 给 `needs-attention` 时：
- 若 findings 有可修复路径 → 按其 findings 修正 rescue 输入/输出后**再跑一次**独立二次 adversarial-review（仍适用上述独立性硬约束）；
- 若无可修复路径或反复不收敛（参 CLAUDE.md 规则 2 的 3 轮上限精神）→ **停止推进 → 提交用户批准**。

## 七、归档

### 常规归档

rescue 的完整输入 prompt + 输出 JSON + Rescue Decision + 二次 adversarial-review 结果必须归档到以下任一：

- `docs/reviews/YYYY-MM-DD-<slug>.md`（推荐）
- 新建追踪 Issue（plugin 自动化能力到位后可自动创建）

### 无法归档场景

若任何情形使完整归档不可达成（敏感信息、工具故障、磁盘不可用等），按 §三 已归入 (b) / (c)：**停止推进 → 提交用户批准**。不采用"本地临时目录 / 脱敏 hash / 延迟补归档"等绕行方案——这些方案在 solo dev 下都存在被绕开的漏洞。

## 八、工具缺陷兜底

当前已知 `codex:adversarial-review` 不支持 empty-tree base / `--no-index`（见 Issue #3）。修复前：

- 首提交文档 / 跨仓库文件对比 等对象暂走 rescue 三闸门
- 工具修复后此类对象**自动**回归 `codex:adversarial-review`，**不改本文件规则**
- 不把"未来回退规则"作为任何 PR 的交付承诺

## 九、本文件演进

- 本文件规则演进走 PR + codex adversarial-review 流程
- CLAUDE.md 规则 2 修改仍优先于本文件；本文件不得与 CLAUDE.md 冲突
