# 破坏性 reset API 塌缩：删掉「可传递的授权凭据」

> **触发**：同一个洞被 codex 提了**六次**（4a-2b R4-F2 → R6-F1 → R7-F1 → R14-F2 →
> S2-R2-F1 → S2a-R1-F1）。前五次的修法依次是「改私有 → 加构造哨兵 → 使用点查类型 →
> 改查登记表 → 加仓库级 AST 守卫」，**每一次都被下一轮拆穿**。
> user 2026-08-12 拍板：接受重构。

## 一、洞到底是什么（实测，不是转述评审）

在完整的 S2（`feat/qmt-4a2b-s2-destructive-core` @ `e038bc0`）上用套件自带的假件实测：

```
场景：目标库绑定的是**别人的设置**（正常必须 --reset-foreign 令牌才能删）
  ① 伪造 authorized_identity = 库当前自称的身份  → ⛔ 直接 DROP
  ② 伪造 via_empty_remnant=True                  → ⛔ 直接 DROP
```

⚠️ **但 codex 的描述不准确，如实修正**：它说绕过了「cluster / ownership / binding /
reset-foreign」四道。实测 **cluster 与 ownership 是在 DROP 点重跑的**
（R4-F1 加了集群闸、R3-F1 加了归属复验）。真正被绕掉的**只有绑定/令牌那一道**。

## 二、为什么偏偏是那一道（这决定了修法）

`_drop_pilot_database` 在 DROP 前重验的每一条，都能**从目标库的活状态重新推导**：
名字、seed 锁、集群闸、占用者、oid、【绝对空】、intent 凭据、`pilot_meta` 归属。
唯独「绑定是否与**调用方递进来的**标量相符 / `--reset-foreign` 令牌对不对」
**推导不出来** —— 它依赖一个库里没有的事实：*这次运行的调用方是谁、他说了什么*。

于是那一条只能靠「授权时记下来的东西」，而那个东西正是伪造者控制的入参。
**加固凭据永远堵不上它**：凭据本身就是那条前提的唯一载体。

## 三、修法：让缝消失，而不是给缝加锁

`ResetAuthorization` / `_RESET_CAPABILITY` / `_MINTED_AUTHORIZATIONS` / `_MintedFacts` /
`_mint_authorization` 这整套机器，**存在的唯一理由是防守「授权」与「销毁」之间那道缝**。
把缝去掉，就没有东西需要防守 —— 「让坏状态不可表达」，而不是「给坏状态加锁」。

**新形状**：`reset_pilot_database(maint_conn, *, connect, db_name, seed,
export_log_sha256, output_dir, reset_foreign_token)` 是**唯一**入口，函数内部
一次走完「集群闸 → 零对象例外判定 → 否则闸 0−/0/0b → 持连接封锁 → 紧贴复验 → DROP →
清凭据」。**没有可传递的对象，没有登记表，没有铸造函数。**
来路（remnant / gates）退化成一个**函数内的局部变量**，伪造不了。
绑定/令牌那一条直接拿**本次调用的入参**在封锁下重验 —— 不再有「记下来的事实」。

**删掉**：`ResetAuthorization` · `_RESET_CAPABILITY` · `_MINTED_AUTHORIZATIONS` ·
`_MintedFacts` · `_mint_authorization` · `_drop_pilot_database`（并入）·
`ResetGateOutcome`（`assert_db_allowed_for_reset` 退回返回 oid）。
**保留**：`try_empty_remnant_exception` / `_has_qualified_intent_row` /
`assert_db_allowed_for_reset` / `assert_binding_scalars` —— 它们是**判定**，不是凭据。

## 三之二、⚠️ `authorize_reset` 本身也要删（设计评审 R1 暴露的缺口）

§三 的删除清单**漏了 `authorize_reset`**。评审那条 finding 让这个问题显形：
它说「keep S2a to non-destructive 判定 helpers」—— 而 `authorize_reset` 不是判定 helper，
它是「集群闸 + 走哪条路的决策 + 铸造」三件事的**封装**。把铸造删掉之后：

· 它还剩「集群闸 + 决定走 remnant 还是闸 0−/0/0b」，**而这正是塌缩后要放进
  `reset_pilot_database` 函数体里的那段次序** —— 留一个公开函数在外面，
  就等于把缝**又留下了一半**：调用方仍可「先问一次走哪条路，再自己去 DROP」。
· 它的返回值若改成「oid + 走了哪条路」的纯数据，那就是 `ResetGateOutcome` 换个名字。
  数据虽不是能力，但只要 DROP 那边**信**它，缝就还在；而只要 DROP 那边**不信**
  （自己重新推导），这个返回值就没有存在意义。**两条路都指向：删掉它。**

**结论**：`authorize_reset` 一并删除。spec §4 的次序（集群闸 → 零对象例外 →
否则闸 0−/0/0b）从「焊进一个公开函数」改为「焊进 `reset_pilot_database` 的函数体」——
R4-F2 当初要的性质不变，只是落点从 S2a 移到 S2b。

⚠️ **连带影响，别漏**：
· S2a 的 lifecycle ⑨ ⑬ ⑰ 三档目前断言的是 `auth.via_empty_remnant`，
  必须改成直接对判定函数断言（⑨ → `try_empty_remnant_exception` 返回非 None；
  ⑬⑰ → `assert_db_allowed_for_reset` 不抛且返回 oid）。
· host 里 `test_authorize_reset_*` 整族要么删、要么改挂判定函数。
· **S2a 因此会更小**：只剩四个判定 helper + 它们的档位。这是对的 ——
  「零破坏性能力」现在是**结构上的**，不再是「有凭据但没人消费」这种偶然。

## 四、对切分的影响（必须重划）

塌缩之后 S2a/S2b 按「授权链 / DROP 执行」切**不再成立** —— 它们是同一个函数了。
新切面建议按**判定 vs 执行**：

| | 内容 | 破坏性 |
|---|---|---|
| **S2a′** | `assert_binding_scalars` · `try_empty_remnant_exception` · `_has_qualified_intent_row` · 22 档只到判定为止的真 PG | **零** |
| **S2b′** | `reset_pilot_database` 单函数（含封锁临界区 + DROP + 清凭据）+ 9 个 SQL 常量 + 9 档破坏性真 PG + concurrency 3 档 | 全部 |

⭐ S2a′ **仍然零破坏性能力**，且现在**连一张可用的凭据都不存在** ——
比当前 S2a 更干净：当前 S2a 会铸出一张「无处可用但可被伪造」的凭据，是纯负债。

## 五、Steps

- [x] 1. S2a 上删掉整套凭据机器**外加 `authorize_reset`**（见 §三之二）
      → verify: `ResetAuthorization` / `_RESET_CAPABILITY` / `_MINTED_AUTHORIZATIONS` /
      `_MintedFacts` / `_mint_authorization` / `ResetGateOutcome` / `authorize_reset`
      七个符号在 `backend/` 下 grep 为 0（注释里的历史叙述除外，但不许有悬空引用）
- [x] 2. `assert_db_allowed_for_reset` 退回返回 `str`（撤销 R3-F1 的 `ResetGateOutcome`）
      → verify: 该函数的 `_REGISTRY_HAS_SQL` AST 反向守卫仍在且非空转
- [x] 3. 相关 host 测试重写（凭据族整批删除，改为对判定函数直接断言）
- [x] 4. lifecycle 的 ⑨⑬⑰ 授权半改成断言判定函数的返回值（不再有 `auth.via_empty_remnant`）
- [ ] 5. 全套闸门 + codex
- [ ] 6. S2b′：`reset_pilot_database` 单函数落地 + 9 档 + concurrency 3 档

## 五之二、Step 1–4 的执行记录（2026-08-12，提交 `6bde10f`）

### 与计划的三处偏离（都是执行中才显形的，逐条交代）

1. **多删了 `_identity_triple`**。它是 `ResetGateOutcome.bound_identity` 的唯一生产者，
   `ResetGateOutcome` 一删它就是孤儿。连带删掉 `import weakref` 与
   `from typing import NamedTuple`（模块里再无其他使用点）。
2. **多加了一处生产行为：`assert_cluster_allowed` 下沉进 `try_empty_remnant_exception`。**
   ⚠️ 这不是纯删除，单列出来。零对象例外的第 4 条（集群闸已全过）此前由
   `authorize_reset` 代跑 —— 那正是 codex 4a-2b R1-F1 修掉的东西。删掉那个入口而不下沉，
   第 4 条就退回成「写在 docstring 里、由调用方保证」，而这条路径的下一步是不可逆的
   `DROP DATABASE`。排在「库名全等」判据**之后**：名字不是本次 seed 的库恒答「不适用」，
   不授权任何东西，没有理由为它去连一遍同侪库。
3. **lifecycle ⑨ 多加了一个对照半**（`⑨-对照`）：同一份残骸走闸 0−/0/0b 必须判
   `not_owned`。没有它，「例外返回了 oid」证明不了例外**有存在的必要** ——
   而它存在的全部理由就是「闸 0− 对残骸只会判 not_owned」。host 层同理
   （`test_the_empty_remnant_escape_hatch_is_the_only_thing_that_can_clear_a_remnant`）。

### 变异验证账本（**每一条都由控制者本人跑**，`cp` 还原，从不用 `git checkout`）

| # | 中和的判据 | 预期变红的**具名**测试 | 实测 |
|---|---|---|---|
| M1 | 删掉 `try_empty_remnant_exception` 里的 `assert_cluster_allowed` | 集群闸两档 | **恰好 2 红**：`test_remnant_exception_enforces_the_cluster_gate_itself` / `..._runs_the_cluster_gate_before_anything_touches_the_target`（其余 375 绿）|
| M2 | `assert_db_allowed_for_reset` 的 `return oid` → `return "0"` | 三个「交回本实例 oid」档 | **恰好 3 红**：`test_reset_correct_token_allowed…` / `test_reset_binding_match…` / `test_reset_does_not_require_the_registry_proof` |
| M2-L2 | 同上，跑真 PG lifecycle | ⑬ ⑰ ㉒ ㉓ 四档 | **恰好 4 条 FAIL**，报文逐条打印「实得 '0'，该库当前 oid='4709…'」 |
| M3a | 在模块里把 `class ResetAuthorization` 造回来 | 两颗塌缩守卫 | **恰好 2 红**：`…machinery_is_gone_from_the_module` + `…no_production_file_reintroduces…` |
| M3b | 在 `scripts/verify_pilot_db_lifecycle.py` 里引 `_m._mint_authorization` | **只有**仓库级那一颗 | **恰好 1 红**（模块级那颗仍绿）→ 证明两颗守卫**各自可分辨**，不是一颗的复制品 |
| M4 | 把扫描器 `_collapsed_symbol_hits` 中和成 `return []` | 扫描器的正向自检 | **恰好 1 红**：`test_collapsed_symbol_scanner_actually_discriminates`；⚠️ 而两颗**使用**它的守卫**照样全绿** —— 这正是自检存在的全部理由（本仓记录在案的「机械检查器被它该抓的损坏禁用了自身解析器 → 静默全绿」）|
| M5a | `try_empty_remnant_exception` 开头直接 `return None` | 例外族 + 逃生口对照 | 13 红（整个函数被打死，含 `…escape_hatch…` 的第一句断言）|
| M5a-L2 | 同上，跑真 PG lifecycle | **只有 ⑨** | **恰好 1 条 FAIL（⑨）**；⑨b / ⑨c / ㉝ / ㉛ 那四条「例外不适用」**全部照样 PASS** —— 这就是本仓「一族全是『拒了』时，一条恒 None 的实现在每一档看起来都在正常工作」的当场复现，⑨ 是唯一钉得住它的正向档 |
| M5c | 让闸 0− 把「没有 `pilot_meta` 表」的残骸当成合规归属放行 | 逃生口对照的**第二句** | **恰好 2 红**：`test_gate_0minus_missing_pilot_meta_table_is_not_owned` + `…escape_hatch…`（后者死在 `DID NOT RAISE`，正是第二句）|

⚠️ **一条没能证明的**：M1（集群闸下沉）在**真 PG 上没有任何档变红** ——
lifecycle 每个 remnant 档的维护库都写了合法 marker，没有「标记缺失 + 走例外」这种档。
故「集群闸下沉」这一条**只有 host 层证据**，L2 层零覆盖，如实登记。

### 闸门（本机实测，判绿读输出内容）

| 闸 | 结果 |
|---|---|
| host 全量 `pytest backend/tests` | **717 passed**（基线 727；净 −10 = 删 9 个 test 函数 −7 个 parametrize 档 +6 个新 test）|
| L2 真 PG `verify_pilot_db_lifecycle.py` | **32 档 / 68 条断言 / 0 FAIL**，**连跑三遍末行完全一致** |
| L2 真 PG `verify_pilot_two_phase_create.py` | **28 档全绿** |
| L2 真 PG `verify_pilot_concurrency.py` | **7 档全绿**（本片不动它）|

## 六、⚠️ 必须在 S2b′ 复验的一条

塌缩之后 R3-F1 那条洞（「靠绑定相符过的授权被别的身份的令牌接管」）**换了形态**：
不再有「授权时记下的身份」，而是**同一次调用内**先判定后 DROP。
中间仍有窗口（`pilot_meta` 可被改）。故封锁下的复验**仍然必须做**，判据是
「拿**本次入参**重跑一遍闸 0/0b/令牌」——而不是「和记下来的身份比对」。
⚠️ 那条真 PG 档（㉟）必须跟着改判据，别照搬。

## 七、诚实的代价

当前 S2a 的 6 个提交里，**凭据机器相关的部分要撤销**（R14-F2 / R3-F1 / R4-F1 的一部分）。
这是**六轮评审换来的教训的代价** —— 那五次加固不是白做的：它们逐步证明了
「这条缝防不住」，最终逼出「不要缝」。但代价是真的，不粉饰成「早就该这样」。
