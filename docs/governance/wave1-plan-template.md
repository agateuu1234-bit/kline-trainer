# Wave 1+ plan 模板

每个 Wave 1+ plan 在 Task 0 前置声明本 plan 使用哪些评审形式（spec §15.3 L2495-2505）：

## Task 0 — §15.3 评审策略前置

- [ ] **局部对抗性评审**（必）：本 plan 子模块 scope 内 codex:adversarial-review；4-5 轮内收敛或 escalate（按 memory `feedback_codex_plan_budget_overshoot`）
- [ ] **集成层评审**（C8 桥接 + E5 编排所在 PR 必）：codex 对比"契约声明 vs 实际实现"
- [ ] **性能评审**（Phase 5 磨光 PR 必）：Instruments 数据对照 plan v1.5 §一"单帧 <4ms" 目标，codex 审视性能热点

完成 Task 0 才进 Task 1 实施。

---

memory `project_review_strategy_deferred` PR 9 后 archived。
