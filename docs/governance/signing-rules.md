# 三 Hat 签字规则（单人项目降级版）

来源：kline_trainer_modules_v1.4.md §十五.4

## 规则

单人项目下，原"3 方签字（后端 / iOS / 数据）"降级为：
**同一人在同一份 PR 里，按涉及的 hat 分别签字。**

### 签字格式（固定，不要修改）

```text
SIGNOFF (Backend hat): I reviewed B/M0.1/M0.2 changes and the backend acceptance script passed.
SIGNOFF (iOS hat): I reviewed F/C/E/P/U changes and the iOS acceptance script passed.
SIGNOFF (Data hat): I reviewed fixture/schema/migration changes and the data acceptance script passed.
```

### 何时签哪个 hat

| PR 涉及的文件 | 需要签的 hat |
|---|---|
| `backend/**`、`schema.sql`、`openapi.yaml`、migration SQL | Backend hat |
| `ios/**`、`.swift` 文件、Xcode 工程 | iOS hat |
| `fixtures/**`、`tools/fixtures/**`、训练组 SQLite、CSV、JSON schema | Data hat |
| `.github/**`、`CLAUDE.md`、`scripts/**` | 全部涉及的 hat |

### 签字前必须完成

1. GitHub PR 页面所有自动检查绿色（如果有 CI）
2. codex:adversarial-review 的每条 finding 已处理或记录接受风险
3. PR 只包含一个主行为面，无顺手重构
4. 本人运行验收脚本并看到 PASS
5. 本人在 PR 评论里粘贴签字语句
6. 本人点击 GitHub 网页上的 Merge 按钮

### Claude 不能代签

Claude 不能代替用户签字、不能代替用户点 Merge。
