# Adversarial Review 模板

用于 codex:adversarial-review 闸门（CLAUDE.md 规则 2 强制类改动）。

## Review 维度

### 1. Spec 覆盖完整性
- 对照 plan/modules spec，逐条检查：有没有漏项？有没有超范围？

### 2. 代码正确性
- 语法、逻辑、边界条件、错误处理

### 3. 无代码经验者可执行性
- CLAUDE.md 规则 3：每模块验收必须无代码经验者可执行
- 操作步骤是否详细？预期现象是否明确？通过/失败判据是否清晰？

### 4. 安全 / 敏感信息
- 密码、token、.env 是否在 .gitignore
- 是否有硬编码的 secret

### 5. 内部一致性
- 文件路径、类型名、方法签名在各 task 间是否一致
- Step 编号是否连续

### 6. 与现有文件的兼容性
- 是否破坏现有 .gitignore / CLAUDE.md / settings.json

## 输出格式

每维度给：**PASS** / **NEEDS-ATTENTION** / **BLOCKER**

总判决：**approve** 或 **needs-attention**

## 闭环规则

- Claude 起草 → 开 PR → 跑 adversarial-review → 修 findings → 再跑
- 连续 3 轮未收敛 → 停止推进，提交用户决定
- 中间操作自动执行，不请示用户
- 用户仅在 approve 后手工 merge，或 3 轮未收敛时介入
