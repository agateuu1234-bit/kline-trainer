# Adversarial Review 模板

用于 codex:adversarial-review 闸门（CLAUDE.md "Repository governance backstop" 治理项 1；参见 `.claude/workflow-rules.json` → `adversarial_review_loop`）。

## Review 维度

### 1. Spec 覆盖完整性
- 对照 plan/modules spec，逐条检查：有没有漏项？有没有超范围？

### 2. 代码正确性
- 语法、逻辑、边界条件、错误处理

### 3. 无代码经验者可执行性
- CLAUDE.md "Repository governance backstop" 治理项 2：每模块验收必须无代码经验者可执行（参见 `.claude/workflow-rules.json` → `verification_template`）
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

## 按阶段评审策略（来自 modules v1.4 §15.3）

v1.0 → v1.4 已经过 4 轮 codex 对抗性评审，累计 56 项修订收敛。后续评审按下列三段触发，不再做 spec 全量评审。

### 阶段 1：Wave 0 局部定向评审

| | 内容 |
|---|---|
| 触发时机 | Wave 0 编码中，某个子模块契约落地时发现硬伤（编译不过 / 字段缺失 / 类型不闭合 / 与 spec 不一致） |
| Review 维度 | 仅聚焦**该子模块**的契约实现 vs spec 声明 |
| 对照基线 | `kline_trainer_modules_v1.4.md` + `kline_trainer_plan_v1.5.md` 相关 section |
| 产出 | per-module verdict：approve / needs-attention / blocker |
| 收敛预算 | 按 `.claude/workflow-rules.json` `adversarial_review_loop.max_rounds` = 3 |

### 阶段 2：Wave 2 集成层评审

| | 内容 |
|---|---|
| 触发时机 | Wave 2 完成（C8 桥接 + E5/E6 编排跨模块协议落地）之后、进入 Wave 3 之前 |
| Review 维度 | 跨模块"契约声明 vs 实际实现"一致性：U → E6 → E5 → P* → B3、C8 → C1b/c、reducer action 矩阵覆盖率 |
| 对照基线 | M0.3 / M0.4 / 各模块 spec 声明 vs Wave 2 交付代码 |
| 产出 | 跨模块一致性 verdict + 未覆盖 action 清单 |
| 收敛预算 | max 3 轮 |

### 阶段 3：Phase 5 性能评审

| | 内容 |
|---|---|
| 触发时机 | Phase 5 磨光开始前，Instruments 采集过至少一轮真机数据之后 |
| Review 维度 | 性能目标（`kline_trainer_plan_v1.5.md` §一"单帧 <4ms"）对照；Core Graphics 调用次数 / bitmap cache 引入时机 / CADisplayLink 回调重载 |
| 对照基线 | Instruments Time Profiler + Core Animation 数据 |
| 产出 | 性能热点清单 + 优化建议；若 >4ms 热点无法消除 → 触发 Bitmap Cache 引入决策 |
| 收敛预算 | max 3 轮 |

**不在本策略覆盖范围内**：spec 全量评审（v1.4 之后不再做）；governance / hook / workflow-rules 变更（走 CLAUDE.md "Repository governance backstop" §1 codex:adversarial-review）。
