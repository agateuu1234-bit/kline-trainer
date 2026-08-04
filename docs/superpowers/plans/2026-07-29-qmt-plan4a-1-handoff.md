# QMT Plan 4a-1 交付材料（待 user push / 开 PR）

**分支** `feat/qmt-plan4-pilot` @ `514f909`，工作区干净。
**本文件是给 user 的操作说明 + PR body 草稿**，不是设计文档。

---

## 一、按你定的拆法，开**两个** PR

分支相对 `main`（merge-base `9fb7480`）共 **17,307 行新增**，其中 62% 是文档
（`git diff --numstat 9fb7480...HEAD | awk '{a+=$1} END {print a}'`）。
`codex:adversarial-review` 是必需门，让它一次审 17k 行撞的正是本仓记录在案的
「大 PR codex 不收敛 → 超小切片」。故拆：

| PR | 内容 | 行数 | 风险 |
|---|---|---|---|
| **PR-A** | `docs/` + `tools/check_spec_consistency.py` | 10,802 | 零运行时影响（纯文档 + 一个只在本地跑的检查脚本）|
| **PR-B** | `backend/` | 6,505 | 真正的护栏代码，PR-B 基于 PR-A |

（行数生成命令：`git diff --numstat 9fb7480...HEAD -- docs tools`／`-- backend`，各自 `awk '{a+=$1} END {print a}'`。
**别照抄这里的数字** —— codex 每一轮修复都会改动它们，交 PR 前重跑一次。）

其中 `docs/superpowers/specs/2026-07-26-qmt-plan4-pilot-shipment-design.md`（3,724 行）
是**已作废的旧 spec**，文首已标注「已切分，不再作为实施依据」，保留仅为 R1–R97 历史账本。

### 怎么造这两个分支（在你的真终端执行）

> ⚠️ **踩过的坑（2026-08-04 实发）**：这些命令**不要在 `&&` 后面加 `#` 注释**。
> `git add docs tools && git commit          # message 见…` 里的 `#` 不是 git 的注释，
> shell 会把 `#`、`body`、`见交接单` 当成**路径**传给 `git add` → `git add` 失败 →
> `&&` 短路 → **commit 根本没发生**，而随后的推送照样成功，
> 推上去的是一个**与 main 完全相同的空分支**。命令看着全绿，结果是空的。
> 故本节所有命令改成自带 heredoc、不含行尾注释。
>
> ⚠️ 另：原文这里写着「message 见下方『PR-A body』」，而**下方根本没有那一节**
> （悬空引用）。两段 message 现已内联在命令里。

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git branch --show-current
git rev-parse --short HEAD

# —— PR-A：只带 docs + tools ——
git checkout -b feat/qmt-plan4-docs main
git checkout feat/qmt-plan4-pilot -- docs tools
git add docs tools
git commit -F - <<'MSG'
docs(4a): QMT Plan 4a 四份 spec + 实施计划 + 交接单 + 一致性检查器

纯文档 + 一个只在本地跑的检查脚本，**零运行时影响**；先合它是为了让 PR-B 的
diff 只剩 backend 那 6.5k 行，评审看得动。

内容：
· spec 切分 4a/4b/4c + 切分地图（旧单体 spec 3711 行、97 轮未收敛，按子系统拆开）
· 4a DB 护栏设计（含 R8–R38 全部评审账本与处置、以及收口决定）
· 4a-1 实施计划与交接单
· tools/check_spec_consistency.py：C1–C13 十三项一致性检查 + 11 项 mutation 自测
  （C12 在本轮开发中十次抓到「模块新抛的 error code 没进 4c 枚举」）

⚠️ 交付口径：本 PR 是**文档**。真实数据一个字节都没流过。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
git push -u origin feat/qmt-plan4-docs
gh pr create --base main --head feat/qmt-plan4-docs --title "QMT Plan 4a：spec 切分 + DB 护栏设计 + 一致性检查器（纯文档）" --body "见 docs/superpowers/plans/2026-07-29-qmt-plan4a-1-handoff.md"
```

**等 PR-A 合并之后**再做 PR-B：

```bash
cd "/Users/maziming/Coding/Prj_Kline trainer/.dev/worktree/qmt-plan4"
git fetch origin
git checkout -b feat/qmt-plan4a-1-guardrails origin/main
git checkout feat/qmt-plan4-pilot -- backend
git add backend
git commit -F - <<'MSG'
feat(4a-1): pilot 建库护栏 —— 集群三闸 + 两阶段建库 + 归属/授权凭据绑实例

本 PR 交付 spec §3 的子项① 全部 + 子项② 的建库一半（复用路径属 4a-2）。

护栏：
· 闸 (i) 维护库三张表的结构 + 表级耐久性证明（非 UNLOGGED / 无 RLS / 默认表空间）
· 闸 (ii) 逐库连进去验归属（自证 + 维护库登记双凭据，且都绑 oid 不绑名字）
· 闸 (iii) 维护库除专用表外绝对空（结构性判据，不是枚举几个系统目录）
· 两阶段建库：intent 行（DROP 授权凭据）→ CREATE → 确认 → 登记 → 阶段 1/2
· 凡「这就是我那个库」的断言一律绑实例（oid）不绑名字：登记读 / intent 保留位 /
  目标连接 / 确认位 / 登记写 / 闸 0− 枚举 共六处，并留机械守卫挡第七处
· 活目录指纹：业务表整行 pg_class + 列 / 约束 / 默认值 / 序列整行 / 索引

验证：
· host 233 passed（假件只验形状与控制流，各自 docstring 里写明了它证明不了什么）
· 真 PG 28 档 178 条断言全 PASS / 0 FAIL / exit 0，连跑多遍可重入（postgres:15.12 ×2）
· 每条新钉子都经控制者亲验的 mutation（关掉判据看它变红），不接受实施者自证

⚠️ **交付口径**：本 PR 是**建库护栏**。SMB 真拉取（4b）与 100 股出货（4c）都不在内。
**真实数据一个字节都没流过。**

⚠️ codex 对抗性评审 R8–R38 共 32 轮**从未 approve**，每轮 needs-attention + 至少一条 high；
findings 全部为真、全部已修并留钉子。第 32 轮后由 user 拍板，就
「活目录指纹完备性」登记为已接受残留、override 收口（理由与边界见 4a spec「收口决定」节）。
该残留**不适用于授权正确性**：4a-2 起凭据 / DROP 授权 / 归属判定类 finding 仍须修到底。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
git push -u origin feat/qmt-plan4a-1-guardrails
```

⚠️ **PR-B 必须等 PR-A 合并后再开**，否则 GitHub 会把 PR-A 的内容算进 PR-B 的 diff。
⚠️ 每次推送之后**去看 CI 是不是真绿**——推送成功不代表闸门过了。

## 二、本次交付的**准确**范围（禁止扩大表述）

spec §3 把 4a 切成三个子项。**本 PR 交付的是 ① 与 ②的一半**：

| spec §3 子项 | 本 PR | 说明 |
|---|---|---|
| ① `assert_pilot_db_allowed` 护栏 + 集群闸 (i)(ii)(iii) | ✅ **完整** | |
| ② pilot 建库 / **复用** | ⚠️ **只有建库** | 复用路径依赖子项③ 的库级五闸，属 4a-2 |
| ③ 库级五闸 + `--reset-foreign` 令牌 | ❌ 不在本 PR | 4a-2 |

**为 4a-2 预置、本 PR 零生产调用点**（只被常量测试钉住，如实声明而非假装它们在工作）：
`derive_confirm_token` / `INTENT_TTL_SECONDS` / `PILOT_META_AUTHORIZATION_KEYS` /
`PilotDbBoundaryError` 的 `identity` 与 `confirm_token` 两个属性。

**交付口径（沿用禁述清单）**：本 PR 的正确表述是
「**4a 护栏建好、用假件与真-PG 脚本验过**」。
**禁述**：「pilot 已完成」「100 股已出货」「真实数据接入完成」——
**真 QMT 数据一个字节都还没流过**。

---

## 三、验证证据（全部为宣称前新鲜跑出，非历史结论）

| 项 | 命令 | 结果 |
|---|---|---|
| host 全量套件 | `cd backend && .venv/bin/python -m pytest tests/ -q -p no:randomly` | **563 passed / 170s**（本 PR 新增的那份：`pytest tests/test_qmt_pilot_db.py -q` → **233 passed**） |
| 真 PG 两阶段建库 | `DSN=… DSN2=… .venv/bin/python backend/scripts/verify_pilot_two_phase_create.py`<br>两个 postgres:15.12 容器；**DSN2 必填**（缺它直接判失败——验收闸不接受「跳过」）| **28 档 178 条断言全 PASS / 0 FAIL，退出码 0**（连跑多遍，可重入）；脚本自带**场景完整性闸**：少跑任何一档都会失败并点名 |
| 上一条**不是空跑的** | `bash backend/scripts/selfcheck_c1_mutation.sh` | 中和 C1 后第 ④ 档打出具名 FAIL，判「9c 通过」，复原后 git 干净 |
| spec 一致性 | `python3 tools/check_spec_consistency.py --self-test && … ` | **11 项检查各自被反例触发**（项数生成命令：`--self-test` 的输出行）；主检查全过 |
| 工作区 | `git status --porcelain` | 0 个变更 |
| mutation | 控制者亲验（不接受 subagent 自证） | 每颗新钉子逐条中和被测代码、确认**具名测试**变红。⚠️ 此处**不再写累计次数** —— 这个数在本 PR 里已随 codex 每一轮修复腐烂过五次；逐轮明细见各 commit message 的「验证」段 |

---

## 四、whole-branch 对抗性评审（codex，**R8–R38 共 32 轮真评审**）

**codex 从未 approve。**每一轮都给出 `needs-attention` 并附至少一条 high；
每一条都经复现 → 修 → host 钉子 + 真 PG 场景 → 逐条 mutation 亲验 → spec/plan 同步。
**如实说明：这不是「收敛到 approve」，而是「每一轮的 finding 都被证实、修掉并钉住」。**

轮次与主题（完整明细见各 commit message）：

| 轮 | 主题 | 性质 |
|---|---|---|
| R8 | 维护表结构无证明；清理失败盖掉原始错误 | 注释声称的保证 > 代码提供的 |
| R9→R10 | 同 run 重试自毁凭据 → **修复引入回归**：成功建库删不掉自己的行 | 修 symptom 挪失败面 |
| R11–R12 | 词法器漏引号标识符 / dollar-quote 不看 token 边界 | 两次 fail-open |
| R13–R15 | 归属证明形同虚设；登记行写太早铸出假凭据 | 凭据时序 |
| R16–R17 | 凭据只绑名字不绑实例；系统目录可被 search_path 遮蔽 | 信任边界 |
| R18–R20 | pg_temp 遮蔽；报告枚举漏 10 个 code；验证脚本注入面 | 覆盖面 |
| R21–R24 | 一次性证明管不住后续 DDL；唯一性判据**六处只改了五处** | 同族未穷尽 |
| R25–R28 | 实施指引没跟上模块；连接身份未验 | 跨文件同步 |
| R29–R32 | 只绑库名不绑集群；验收标准自证；「跳过」被当成「通过」 | 验收诚实性 |

**过程中被自己抓住的假绿**（不是 codex 提的，如实记）：C11 正则被新枚举值静默禁用两轮、
多处有序轨迹漏记导致次序断言恒假、⑲(b) 首版不建影子表因而验收是空的、
钉桩判据写成次数被内部合法调用顶成假红。

## 五、已知残留（**逐条实测过**，不声称已消除；已解决的不再列为残留）

> ⚠️ 上一版这张表里的 R1（单引号字符串）/ R2（两处 `$tag$` 吞掉真 `BEGIN`）/
> R3（`COMMIT AND CHAIN`）/ R5（无 advisory lock）**都已在 R4/R11/R12/R5-C2 修掉**，
> 继续列成「残留」就是假陈述，故删除。本轮逐条复验过才改的。

| # | 残留 | 方向 | 去向 |
|---|---|---|---|
| A1 | `schema.sql` **执行途中**崩溃这一档，host 与真 PG 两层都没测 | — | 4a-2 的 `verify_pilot_db_lifecycle.py` |
| A2 | 假件 `fetchval` 用子串 `or` 分发；未来新增查询若命中这些子串会**静默弹出错位的值** | — | 4a-2 backlog（本轮已多次因它返工） |
| A3 | 两阶段之间的窗口：`schema.sql` 已提交、指纹两键与 `ready` 未提交时崩 → 「schema 齐全 + `state=initializing`」 | — | **不可消除**（`schema.sql` 自带事务所致），spec §4 已登记，O4-F8 兜底 |
| A4 | 连接**恰好死在 `CREATE DATABASE` 这一瞬**：库可能已建出而确认没跑成 → 该行停在 `create_confirmed=false` → 零对象例外认不出这个残骸，需人工删 | **fail-closed**（宁可自己清不掉，也不授权去删别人的库）| 登记，spec §4 已写明 |
| A5 | `CANONICAL_BUSINESS_CATALOG_SHA256` 对 **PostgreSQL 大版本敏感**（`pg_get_constraintdef`/`indexdef` 渲染会变）| 升级后**验收当场变红**并打印实际值，不会静默漂到生产 | 登记；重新生成方式写在常量旁与运行时报错里 |
| A6 | 持有**维护库写权限**的对手可以自己往 `pilot_database_registry` 插行 —— 任何集群本地的凭据都防不住这一档 | 登记，非本切片可解 | spec §4 已诚实写明它挡的是「偶然撞形」与「能建库但写不了维护库的对手」|
| A7 | 位置参数 `$N` 后接 `$tag$` 时 PG 会开 dollar-quote 块而本实现不开 | **fail-closed**（更容易判「没被包住」）| 只影响含位置参数的 SQL，schema 文件里不会出现；已写进 docstring |

## 六、非 coder 验收清单

完整清单在 `docs/superpowers/plans/2026-07-29-qmt-plan4a-db-guardrails.md` 末尾。
**本 PR 只需执行标 `[4a-1]` 的项**；第 3、4 项已标 `[4a-2，本 PR 跳过]`。

两项需要 Docker 的（第 9b / 9c）都**在仓库根目录**执行，且 9c 前要先 `docker rm -f pg4a`
放掉 9b 的容器——否则会撞端口。

---

## 七、合并的硬约束

**`codex:adversarial-review` 是本仓 PR 的必需门。**本分支已跑过 **R8–R38 共 32 轮**
whole-branch 对抗性评审（见第四节），**codex 从未给出 approve**；
每一轮的 finding 都已复现、修掉并钉住，但按本仓纪律，
**「没 approve」必须如实报，不得写成「已收敛」**。
是否以 override 方式收口由 user 决定 —— 这不是 reviewer 的 verdict 能替代的授权。
