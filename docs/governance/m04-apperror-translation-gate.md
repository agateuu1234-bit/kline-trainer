# M0.4 AppError Trust-Boundary Translation Gate（stub，待 Plan 3 P1 闭合）

> **Status**：stub 锚点。具体 Gate 规则在 Plan 3 P1 APIClient 首次消费 AppError 时落地——因为没有真 Swift 模块可迭代，现在抽象化写规则已被 codex 6 轮对抗性 review 验证会持续 shift goalposts（见本 PR 历史）。

## 用途

本文件是 `spec M0.4` "私有错误在本模块边界内转 AppError" 原则的 **repo 锚点**。它的存在解决了 Plan 1d PR #26 codex post-merge finding："promised translation gate artifact not in repo"。

Plan 2/3 消费 AppError 的 Swift 模块 PR 必须引用本文件，**即使规则尚未具体化**——目的是让引用链不丢。

## Plan 3 P1 闭合清单（TODO）

Plan 3 P1（APIClient，第一个 public throws 消费 AppError 的 Swift 模块）PR 必须**闭合以下 5 条**并把本 stub 升级为权威 gate doc：

- [ ] **TODO Plan 3 P1**: Gate 1 coverage 范围——`public func ... throws` only，还是包含 `init / accessor / subscript / protocol requirement`？
- [ ] **TODO Plan 3 P1**: Gate 1 是否强制"失败注入 fixture per 方法 × per 文档化失败模式"？（codex R3 推荐 yes）
- [ ] **TODO Plan 3 P1**: catch-all 兜底形态——per-method 强制，还是允许 shared-adapter 例外？（codex R4 推荐 per-method；R5 反攻 shared-adapter；需真代码验证）
- [ ] **TODO Plan 3 P1**: Gate 1 evidence mapping table（public API → fixtures）是否作为 PR body 强制？
- [ ] **TODO Plan 3 P1**: Gate 2 形态——SwiftSyntax lint / tested shell fixture / 取消并扩展 Gate 1？

**Plan 3 P1 的 acceptance 脚本必须含一条断言**：

```bash
# 确保 Plan 3 P1 闭合了所有 stub TODO
run "gov: m04 gate stub closed" \
    bash -c "! grep -q 'TODO Plan 3 P1' docs/governance/m04-apperror-translation-gate.md"
```

本断言返回 empty grep 结果 = TODO 全部删除 = stub 已升级为权威 gate = acceptance PASS。

## 历史讨论（参考，不权威）

Plan 1d hotfix 期间（2026-04-22）对 5 条 TODO 的 6 轮 codex 迭代见：
- 本 PR（plan-1d-hotfix/translation-gate）commit 历史：`29a3559` → `fbaa432`（R0 入仓、R1-R4 规则打磨）
- codex R5/R6 findings：gov doc §"已知残留"（commit `d1ee2ca`）——均已被本次 E-mode 重写替换，仅历史留痕
- memory `project_m04_translation_gate.md`（session-local 讨论笔记）

**以上历史仅供 Plan 3 P1 决策时参考，不是权威约束。Plan 3 P1 有权**完全重新设计**这 5 条规则，只要最终形态能通过该 PR 自己的 codex review。**

## 应用范围（不变，来自原 memory）

| Plan | 模块 | Gate 必需 | 备注 |
|---|---|---|---|
| Plan 2 | B1 import_csv | 否 | 不抛 error 到外 |
| Plan 2 | B2 generate_training_sets | 否 | 同上 |
| Plan 2 | B3/B4 | N/A | Python |
| Plan 3 | **P1 APIClient** | **✅（首次消费，必闭合本 stub）** | |
| Plan 3 | P2 DownloadAcceptance | ✅（继承 P1 规则）| |
| Plan 3 | P3a/P3b / P4 / P5 / P6 | ✅（继承 P1 规则）| |
| Plan 3 | E3 TradeCalculator | 否 | 返 `Result`，不 throws |
