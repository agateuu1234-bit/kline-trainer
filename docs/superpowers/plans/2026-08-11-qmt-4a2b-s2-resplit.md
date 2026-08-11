# S2 再切一刀：授权链 / 破坏性临界区

> **触发**：codex 对 S2 跑了 6 轮从未 approve，**8 条 finding 里 6 条落在同一个函数**
> （`_drop_pilot_database`），其余部分（零对象例外 / `authorize_reset` / 授权登记表 /
> 绑定标量 / 22 档真 PG）**六轮零 finding**。这不是「PR 太大」的笼统判断，是很具体的定位。
> user 2026-08-11 拍板：按此切分。

**参考分支**：`feat/qmt-4a2b-s2-destructive-core` @ `e038bc0`（8 提交，全部证据在其中）
—— **不要删**，它是本次切分的唯一真相来源，直到两片都合并。

---

## 一、切面（按「能不能 DROP」划，不是按行数）

| | S2a `feat/qmt-4a2b-s2a-authorization` | S2b `feat/qmt-4a2b-s2b-drop` |
|---|---|---|
| 生产代码 | `assert_binding_scalars` · `try_empty_remnant_exception` · `_has_qualified_intent_row` · `_identity_triple` · `ResetGateOutcome` · `_RESET_CAPABILITY` / `ResetAuthorization` / `_MINTED_AUTHORIZATIONS` / `_MintedFacts` / `_mint_authorization` · `authorize_reset` | `_drop_pilot_database` 全体 + 9 个 SQL 常量 + `reset_pilot_database` |
| **破坏性能力** | **零** —— 全片没有一条 `DROP DATABASE` | 全部 |
| lifecycle 新增 | ⑥⑦⑧ reset 半 · ⑨(授权半) · ⑨b ⑨c ⑩ ⑪ ⑫ ⑬(授权半) ⑭ ⑰(授权半) ㉒ ㉓ ㉛ ㉝ | ⑨(DROP 半) ⑬(DROP 半) ⑰(DROP 半) ㉘ ㉜ ㉜b ㉞ ㉞b ㉟ |
| concurrency | —— | Ⓓ Ⓓb Ⓔ |
| 4c 错误码 | `forged_reset_authorization` | `target_db_replaced` · `connection_limit_not_restored` |

⭐ **S2a 零破坏性能力**，与 4a-2a 当初能被 override 的第一条理由同形：
最坏情况只是某道闸判得不够严，而**下游没有任何东西能拿它去删库**
（`ResetAuthorization` 在 S2a 里是一张无处可用的凭据 —— 这是有意的）。

---

## 二、三档必须拆成两半（否则 S2a 全是「拒了」）

⚠️ 本仓最常踩的坑：**一族全断言「拒了」时，一条恒抛的守卫在每一档看起来都在正常工作。**
S2a 的 ⑨b ⑨c ㉝ ㉛ 全是「例外不适用 → not_owned」——
`try_empty_remnant_exception` 写成 `return None` 四档全绿。故这三档的**授权半必须留在 S2a**：

| 档 | S2a 留（正向钉，只到授权为止） | S2b 补（真的动手） |
|---|---|---|
| ⑨ | 空残骸 → `authorize_reset` 返回 `via_empty_remnant=True` 的授权 | …并且真的 DROP + 重建成功 |
| ⑬ | 正确令牌 → `authorize_reset` 放行（不抛） | …并且目标库真的被 DROP 掉 |
| ⑰ | `initializing` 的库 → `authorize_reset` 放行 | …并且真的 DROP + 重建成功 |

---

## 三、Steps

- [ ] **1. 从 origin/main 切 S2a worktree** → verify: `git rev-list --count HEAD..origin/main` = 0
- [ ] **2. 全量搬 S2 的最终产物，再删 S2b 那部分**（不按提交切 —— #161 已实测「按提交切不出干净的片」）
      → verify: `grep -c "DROP DATABASE" backend/qmt_pilot_db.py` = **0**
- [ ] **3. host 测试删 drop 族**（`_DropMaint` / `_session` / `_PgError` / `_connlimit_ops` /
      `_drop` / `_drops` / `_mint` 及全部 `test_drop_*` / `test_*remnant_drop*` /
      `test_*reset_pilot_database*` / `test_ambiguous_*` / `test_seal_*` / R15-F1 那批）
      → verify: 全量 pytest 绿，且 `grep -c "_drop_pilot_database" tests/` = 0
- [ ] **4. 机械守卫按 S2a 的现实调整**（⚠️ 不许让它变成空转）：
      · `test_reset_pilot_database_is_the_only_public_destructive_entry` → 整条归 S2b
      · `test_no_production_module_reaches_past_the_public_reset_entry` → S2a 版的私有名单
        只列**S2a 里真实存在**的符号，并**保留双向自检**（扫不到文件红 / 扫不到 scripts 红）
      → verify: 给脚本植一句私有 import，守卫必须变红
- [ ] **5. lifecycle 脚本按 §一 取舍 + §二 拆三档**
      → verify: `_EXPECTED_SCENARIOS` / `_LIFECYCLE_DBS` / 顶层 import **三处同步**
      （漏一处 harness 会在任何连接之前 return 5）；真 PG 跑绿并**连跑三遍末行一致**
- [ ] **6. S2a 全套闸门 + codex** → verify: host 全绿 / two-phase 28 / lifecycle 新档数 /
      concurrency **仍是 7**（S2a 不动它）/ spec 一致性 + self-test
- [ ] **7. S2a 合并后**，从新 main 切 S2b，补回 §一 右列
      → verify: lifecycle 回到 38 档、concurrency 10 档
- [ ] **8. S2b 全套闸门 + codex**

---

## 四、诚实的成本（修正我先前的低估）

我先前对 user 说「大概是这轮工作量的三到四成」。**看过之后这个估计偏低**：
真正的工作量在 host 测试的切分（443 条里约 60 条属 drop 族，且 `_DropMaint` 家族
被非 drop 测试间接依赖）与 lifecycle 三档的拆半上，加两轮完整闸门与两个 codex 周期，
**更接近六到八成**。收益不变：S2b 的评审面缩到约 150 行控制流。

## 五、风险

1. **拆半的三档写歪 → S2a 假绿**。缓解：每拆一档，先在 S2a 上把
   `try_empty_remnant_exception` 改成 `return None`，确认该档**变红**再收工。
2. **守卫在 S2a 上变空转**（私有名单里的符号不存在 → 恒真）。缓解：Step 4 的反向自检。
3. **S2b rebase 冲突**：S2a 合并后 main 前进，S2b 必须 merge 进分支（不是 rebase）——
   记忆里 #160/#161 那次实测过 rebase 会让 attest 账本的 head_sha 对不上。
