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

**仅当**存在以下**可证实**阻塞才允许不物化：

| 阻塞类型 | 举证要求 |
|---|---|
| (a) 权限阻塞 | 仓库写权限缺失的具体错误输出（如 `gh` 报 403） |
| (b) 工具故障 | `git` / `gh` / 磁盘不可用的错误输出 |
| (c) 敏感信息不可落盘 | 具体敏感字段类型（如 secrets / 客户 PII），**不得**以"可能敏感"推定 |
| (d) 其他可举证阻塞 | **必须**在 Rescue Decision 提供独立可复核证据；**不得**用于兜住主观理由 |

**主观口径一律不成立**：`成本高` / `麻烦` / `还没建 PR` / `时间紧` / `暂时不想` 等。

## 四、rescue 入口：结构化 Rescue Decision

rescue 调用前必须产出以下字段块（记入 commit message / PR 描述 / 归档 markdown）：

```yaml
rescue_decision:
  job_id: <codex 分配的 jobId>
  object: <评审对象名与范围>
  trigger_reason: <为何需要对抗性 review>
  blockage_type: <a|b|c|d>   # 见 §三
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

## 六、独立 checker（禁自审）

solo dev 场景下，**不得**由 rescue 发起者同时担任 checker。必须**二选一**：

- **(A) 脚本 checker**：对 rescue 输出 JSON 做 `review-output.schema.json` 校验；**同时**对 §四 Rescue Decision 做字段完备性 + 反套话校验（正则拒绝 §四 禁止套话、对 (d) 类要求独立证据字段非空）。若仅走 (A)，对第 (d) 类 "其他阻塞" **必须**并走 (B) 做二次闸门。
- **(B) 二次 `codex:adversarial-review`**：把 rescue 输出（及其 Rescue Decision）物化为 `docs/reviews/YYYY-MM-DD-<slug>.md` 或 Issue 后，再对该 artifact 跑一次 `codex:adversarial-review`。

checker 执行者、时间、结果必须随 rescue 输出一起归档（见 §七）。

## 七、归档

### 常规归档

rescue 的完整输入 prompt + 输出 JSON + Rescue Decision + checker 结果必须归档到以下任一：

- `docs/reviews/YYYY-MM-DD-<slug>.md`（推荐）
- 新建追踪 Issue（plugin 自动化能力到位后可自动创建）

### 敏感/工具阻塞下的脱敏归档（修闸门 #2 F1）

当 rescue 触发原因是 (c) 敏感信息不可落盘 或 (b) 工具故障导致无法正常归档时，按下列替代策略：

| 情形 | 归档策略 |
|---|---|
| (c) 敏感信息 | **脱敏归档**：敏感字段以 hash 或引用锚点代替；保留 Rescue Decision、checker 结果、非敏感 finding 全文；归档体须标注"已脱敏 + 原件保存位置"。 |
| (b) 工具故障（临时） | 先本地落盘到 `docs/reviews/_pending/`（git ignore），工具恢复后补归档，补归档延迟 > 24h 时须发 PR/Issue 记录原因。 |
| (a)(b)(c) 导致**完全无法安全归档** | **停止推进 → 提交用户批准**（CLAUDE.md 规则 2 的 3 轮停止条款自然接管）。 |

**不得**以"归档会泄露"为由同时跳过归档**和**用户提交——这是单点漏洞。

## 八、工具缺陷兜底

当前已知 `codex:adversarial-review` 不支持 empty-tree base / `--no-index`（见 Issue #3）。修复前：

- 首提交文档 / 跨仓库文件对比 等对象暂走 rescue 三闸门
- 工具修复后此类对象**自动**回归 `codex:adversarial-review`，**不改本文件规则**
- 不把"未来回退规则"作为任何 PR 的交付承诺

## 九、本文件演进

- 本文件规则演进走 PR + codex adversarial-review 流程
- CLAUDE.md 规则 2 修改仍优先于本文件；本文件不得与 CLAUDE.md 冲突
