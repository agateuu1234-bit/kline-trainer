# Catalyst 闸门改读结构化结果（治随机假红）· 设计

- 日期：2026-10-06
- 分支：`fix/catalyst-gate-structured-results`（base = main `67609558`）
- 类别：CI / 闸门（trust-boundary）→ 强制 `codex:adversarial-review`
- 由来：`docs/superpowers/acceptance/2026-09-01-finalize-alert-truthful-exit.md:105` 记的残留「Catalyst 闸门偶发假红，需单独立项」

> **本文档的写法约定**：每个事实只写一次。重复的地方用指针（「见 §N」），⛔ 不复述。
> 这条约定本身是教训：本仓 `feedback_prose_duplication_is_the_defect_engine` 记着
> 「同一事实 N 份副本 ⇒ 每轮修复造下一个回声」—— 上一条治理线三轮评审 7 条 Major 里有一半是它。

---

## 1. 问题与根因（实证，非推断）

`catalyst-gate.sh` 有两条判据靠在 **xcodebuild 的 stdout 文本**里按测试名找字符串：

| 判据 | 位置 | 匹配什么 |
|---|---|---|
| **G8** 逐条 UIKit-gated 测试是否真执行 | `:168` / `:171` / `:174` | `✔ Test "<名>" passed after ` |
| **G7** swift-testing 汇总行 | `:195` | `✔ Test run with N tests[ in M suites] passed` |

**根因：并发写同一 fd 把一个多字节 UTF-8 字符劈开，接收方把残字节转义成八进制。**

证据（2026-10-06 本机实跑一次 Catalyst，日志 `/tmp/spike-catalyst.log`，3 处转义）：

```
◇ Test "…accessibilityLabel 必\351\241\273有语义)" started.                        ← 須
✔ Test "选择态 + 有选中 \342\206\222 面板显示…" passed after 3.775 seconds.          ← →
✔ Test "未命中 → nil；命中\345\256\271差外的线不算命中" passed after 3.792 seconds.   ← 容
```

**关键观察**：同一行里**只有那一个字符**被转义，其余中文完好。⇒ 不是编码/locale 问题
（本机 `LANG=en_US.UTF-8`，照样出现）。`catalyst-gate.sh:158-165` 的注释其实已记录过
同一机制的另一面（`XCTestOutputBarrier` 文本与 ✔ 行粘连，「两个并发进程写同一 fd 时的输出交织」）。

**暴露面**：`catalyst-uikit-baseline.txt` 共 **80 条**，**全部含非 ASCII**。日志里约 2500 条 ✔ 行。

### 1.1 ⚠️ 订正一个被反复引用的数字

残留原文写「实测 5 跑中可中 4 次」，此后被当作「假红率 ≈ 80%」。**这是误读。**

真正的假红要同时满足两件事：① 转义发生；② 它**恰好落在那 80 条之一的 ✔ 行上**。

上述实跑：3 处转义中 **2 处落在 ✔ 行**，但那两条测试不在 80 条里 ⇒ 闸门判 **`GATE PASS`**（已实测）。
旧日志 4 份中 1 份有转义（`/tmp/baseline-catalyst.log`，1 处，落在 `◇ … started.` 行 ⇒ 无害）。

⇒ **「有转义」概率高，「假红」概率低但非零**（≈ 转义落 ✔ 行的次数 × 80/1935）。
排期与严重度按后者判，⛔ 别按 80%。

---

## 2. 目标 / 非目标

**目标**：让 G7 / G8 不再依赖那条 racy 的文本流，从而消除随机假红。

**非目标**（本片一行不改）：

- 其余六条判据（`TEST SUCCEEDED` 标记 / 编译器 error / `Sources/` 零警告 / 测试 target 真被编译 / `macabi` 标记 / 总用例数 ±delta 基线）—— 它们匹配的都是 ASCII，不受劈字影响；
- 转义本身（它是 xcodebuild 与测试进程的并发行为，仓内无法消除）；
- `Tests/` 的 50 条既有警告技术债（闸门当前不拦，保持不拦）。

---

## 3. 设计

**让 xcodebuild 额外产出结构化结果包，G7/G8 改读它。**

| | 现在 | 改成 |
|---|---|---|
| `catalyst-build.yml` 的 `xcodebuild test` | `-derivedDataPath /tmp/derived` | 追加 `-resultBundlePath /tmp/catalyst.xcresult` |
| G8 | `grep -qF "✔ Test \"<名>\" passed after "` | 从包里取 `nodeType == "Test Case"` 的 `name` + `result` |
| G7 | `grep -oE '✔ Test run with …'` | 同上（但见 §4.1 的口径约束） |

**取数命令**（已实测可用，Xcode 27 / xcresulttool 25115）：

```
xcrun xcresulttool get test-results tests --path /tmp/catalyst.xcresult --format json
```

**解析用 `python3`**，⛔ 不引入 `jq`：闸门**已经**依赖 `python3`（`:106` 跑 `uikit-expected-tests.py`），
用它解析 JSON 不新增任何依赖；加 `jq` 会。

### 3.1 为什么这同时**加强**了防伪造，而不只是绕开转义

G7/G8 现在的 `✔` 前缀是为修 **F4**（`:150-157` 记载：普通 stdout 里出现 `Test "<名>" passed`
就能骗过裸子串匹配）才加的。它是个**约定**——依赖「普通 stdout 不会带 ✔ 字符」。

结构化结果里，节点类型只有四种（实测 2026-10-06）：

```
Test Plan: 1   Unit test bundle: 1   Test Suite: 234   Test Case: 2054
```

这些节点由测试运行器自己记账产生，**测试代码 print 什么都进不去**。⇒ 防伪造由**结构**保证，
不再依赖那个约定。**但这条必须用变异证伪**（见 §6 的 M5），⛔ 不许当成显然的。

---

## 4. 三个必须处理的坑

### 4.1 两种计数口径不同 —— G7 的基线不能直接搬

实测同一次运行：

| 口径 | 值 |
|---|---|
| 文本汇总行（现 G7 读的）：`✔ Test run with 1935 tests in 227 suites passed` | **1935**（仅 swift-testing） |
| xcresult 的 `Test Case` 节点 | **2054**（235 个 suite） |

差 119 = **XCTest 那部分**（日志里另有 `Executed 4 tests, with 0 failures` 等若干行）。

⇒ **决定（2026-10-06 修订，codex plan-R1 促成）：G7 不迁移，继续读文本汇总行。**

理由三条，前两条是新增的：

1. **G7 本来就不是受害者**。它匹配的是 `✔ Test run with <数字> tests…` —— 除了那个 `✔`，
   全是 ASCII 与数字。劈字只伤非 ASCII 的**测试名**，而汇总行里没有测试名。
   受害者只有 G8。
2. **迁移 G7 的代价是连带搬 5 档既有负向回归**（实核 `catalyst-gate.test.sh`）：
   `missing-summary-line` / `summary-stdout-spoof` / `too-few-tests` /
   `total-baseline-below-delta` / `total-baseline-above-delta` —— 它们的变异都加在**文本**上，
   G7 一改读 JSON，这 5 档的变异就不再喂给判据，**失去失败条件**（= 判别力归零）。
3. 口径差异（1935 vs 2054）在不迁移时**根本不需要处理**。

⛔ 原先写的「从包里只取 swift-testing 那部分」已撤销。**也不采用「改基线为 2054」**
（会悄悄改变 ±delta 覆盖范围，且让基线与日志里人眼可读的数字对不上）。

⚠️ 仍需 CI 探针确认的只剩一件事：**G8 要用的那些字段在 CI 的 Xcode 上是否相同**（见 §4.4）。
「能否区分两种框架」这一问**已不影响设计**（因为不再需要区分），但探针仍应顺带输出它——
万一将来要迁 G7，那是现成的素材。

### 4.2 `result` 的取值空间没验全

实测那一跑 2054 个节点**全是 `Passed`**。未见过 `Failed` / `Skipped` / `Expected Failure` 等取值。

⇒ 判据必须是**白名单**：只有 `result == "Passed"` 算执行通过。
⛔ 不许写成「不等于 Failed 就算过」—— 那会让未知取值（含将来 Xcode 新增的）静默放行。
本仓 `feedback_check_that_can_never_pass` 与「假绿家族」反复记过这个形状。

### 4.3 判据精度：「有转义」≠「会假红」

⛔ **不许**把新判据写成「日志里不许出现八进制转义」。依据见 §1.1：实测那一跑有 3 处转义而闸门
**应该**放行，写成那样会制造新的假红。

此精度本仓已有先例写对过：`docs/superpowers/specs/2026-09-21-drawing-tools-P1c-2-nodes-design.md:736`
——「要问的不是『有没有转义』，而是『转义有没有落在 `catalyst-uikit-baseline.txt` 要逐条匹配的测试名上』」。
本片沿用它。

---

### 4.4 ⚠️ 第二个未验证假设：CI 的 Xcode 版本（codex spec-R1 指出）

**我的 spike 跑在本机 Xcode 27 / xcresulttool 25115（schema 0.4.0）上。CI 不是这个环境。**

| | 版本 |
|---|---|
| CI（`catalyst-build.yml:25`） | `runs-on: macos-15`，镜像预装 **Xcode 16**，workflow 只断言 `>= 16` |
| 我的 spike | **Xcode 27** |

未知项（⛔ 本机无法验证，因为本机只有 27）：

1. `xcrun xcresulttool get test-results tests` 这个子命令在 Xcode 16 上**是否存在**；
2. 它的 JSON **结构/字段名是否相同**（`nodeType` / `name` / `result` / `testNodes`）；
3. §4.1 那个「能否区分 swift-testing 与 XCTest」的答案在 Xcode 16 上是否一致。

⚠️ **这不是可以带着往下走的假设**：若子命令不存在，整个 §3 设计在 CI 上根本跑不起来
（而本地测试会全绿 —— 正是本仓 `feedback_swift_local_ci_toolchain_strictness`
与 `feedback_swift_local_toolchain_blindspot` 记的「本地绿 ≠ CI 绿」形状）。

⇒ 处置见 §8（plan 的 Task 1 改为**在 CI 里**探测，不在本机）。

## 5. 改动面

| 文件 | 改什么 |
|---|---|
| `.github/workflows/catalyst-build.yml` | `xcodebuild test` 追加 `-resultBundlePath`；⚠️ Claude 对 `.github/workflows/**` 硬 deny ⇒ 走 ceremony 由 user `cp` 落地 |
| `.github/scripts/catalyst-gate.sh` | G7/G8 改读结构化结果；其余判据不动 |
| `.github/scripts/catalyst-gate.test.sh` | 新增转义场景的档位（见 §6） |
| `.github/scripts/fixtures/`（新增） | **真实**带转义的样本 + 结构化结果样本 |
| 本 spec + 后续 plan + `docs/acceptance/<交付日>-…md` | 文档（验收清单按本仓治理条款是必备件） |

**不新增运行时依赖**（理由见 §3）。**不改 baseline 两个文件**（理由见 §4.1）。

---

## 6. 验证策略

⚠️ **现状**：`fixtures/` 下 **23 个文件**（其中 **20 份 `.log`** = 测试台的 20 个档位）对转义**零覆盖**（`grep -rl '\\3[0-7][0-7]' .github/scripts/fixtures/` 命中 0）。
这正是该失效模式能长期存在的原因 —— 它的测试套件压根没测过。**本片必须补上。**

变异矩阵（每档都要**先看它红、且红在预期的那一条判据上**；归因单独核）：

| # | 变异 | 期望 |
|---|---|---|
| M0 | 不变异（反向对照） | **绿** |
| M1 | 结构化结果里删掉某条 baseline 测试的节点 | 红，且红在 G8、点名那条 |
| M2 | 把某条 baseline 测试的 `result` 改成 `Failed` | 红（白名单，§4.2） |
| M3 | 改成一个**未知取值**（如 `Flaky`） | **红**（这一档专打 §4.2 那个「不等于 Failed 就放行」的错写法） |
| M4 | 把 swift-testing 用例数改到 ±delta 之外 | 红在 G7 |
| **M5a** | **先删掉**某条 baseline 测试的结构化节点，**再**在 stdout 里伪造它的 `✔ Test "<名>" passed after ` 行 | **红**，且 G8 **点名那条** —— 这才是「stdout 冒充不了未执行的测试」 |
| **M5b**（对照） | **保留**该节点（`Passed`），同样插入那条伪造 stdout | **绿** —— 证明游离的 stdout 不会造成假红 |
| M6 | 文本日志里把某条 baseline 的 ✔ 行**转义**（真实样本） | **绿** —— 证明假红被治好了 |
| M7 | 转义落在 `◇ … started.` 行上 | **绿** —— 证明没制造新假红（§4.3） |
| M8 | 结果包**不存在** / 为空 / JSON 解析失败 | 红（fail-closed，三档分别验） |
| M9 | 结果包里一个 `Test Case` 节点都没有 | 红（门是空的） |

M6/M7 的样本来源要说清楚，⛔ 别含糊成「用真实日志」：

- **手里真有的**：2026-10-06 那份真日志（见 §1），含 **2 处落在 ✔ 行**的真实转义 —— 它提供了
  **转义的真实形态**（哪个字节怎么变成 `\NNN`、上下文长什么样）。**M7 可直接用它**
  （它那处 `◇ … started.` 行的转义正是 M7 要的）。
- **手里没有的**：⚠️ 那 2 处转义落在的测试**不在 80 条 baseline 里**（这正是 §1.1 说的「假红概率低」）。
  ⇒ **M6 所需的「baseline 某条的 ✔ 行被转义」这一档，样本不存在。**
- **因此 M6 的造法**：取那份真日志，把其中**某条 baseline 测试的 ✔ 行**里一个非 ASCII 字符
  按**同一真实形态**替换成对应的 `\NNN`。这是对真实样本的**定点改写**，不是凭空手造 ——
  形态来自生产、位置由判据决定。plan 里必须写明这一点并保留原始日志作对照，
  ⛔ 不许把它描述成「捕获到的真实假红样本」。
  （另一条路：等隔壁会话 TS1-R1 那个会真重编的 PR 出现真假红 —— 已请它别重跑、先给 run id。
  但这是**机会样本、不可调度**，⛔ 不能当作本片的交付前提。）

依据：本仓 `feedback_fixtures_must_match_production_format`（样本须照生产真实格式造）与
`feedback_absolute_claims_are_causal_overreach`（别把构造样本说成捕获样本）。

### 6.1 ⚠️ M5 原先写错了（codex spec-R2 指出，复核属实）

初版 M5 是「在 stdout 里伪造一条 ✔ 行 ⇒ 要求判红」，**没有先删掉结构化节点**。

这与 §3 的设计**自相矛盾**：闸门读的是结果包；节点还在且是 `Passed`，就**本该放行**。
照初版去实现，只有两种出路 —— 要么把正确实现判成错的，要么**逼实现者退回去读 stdout**，
那正好把本片要消除的依赖又装回来。

既有 F4 场景本来就做对了：`catalyst-gate.test.sh:320-323` 注释写明 `stdout-spoof.log`
是从真实日志裁出来的，**先删掉那条测试的真 ✔ 行**，再插一条没有 ✔ 前缀的裸文本
（实核：该 fixture 仍有 28 条真 ✔ 行，被删的只是目标那一条）。新场景必须保留同等前提。

⇒ 已拆成 **M5a（删节点 + 伪造 stdout ⇒ 红且点名）** 与 **M5b（留节点 + 同样伪造 ⇒ 绿）**。
M5b 这个对照不可省：它是「没制造新假红」的那一半证据。

本仓 `feedback_mutation_direction_must_match_test_direction`（变异方向必须与用例方向对上，
用反会得出「没判别力」的假结论）记的就是这个形状。

判绿命令（本片新增判据必须进这条，否则等于没守）：

```
bash .github/scripts/catalyst-gate.test.sh
```

它已被 `catalyst-build.yml:51` 在闸门上岗**之前**执行 —— 即「闸门判据本身先过测试再上岗」。

---

## 7. 残留（本片明确不做）

- **R1 · §4.1 的未决点**：若实测发现结果包**无法区分** swift-testing 与 XCTest，则 G7 只能二选一：
  (a) 继续读文本汇总行（它是 ASCII + 数字，**不受劈字影响** —— 转义只伤非 ASCII 的测试名），
  (b) 或改基线为 2054 并在 spec 写清语义变更。**(a) 是默认退路**，因为 G7 本来就不是受害者；
  真正的受害者只有 G8。plan 第一步跑出结论后据此定稿。
- **R2 · 转义本身不消除**：它是并发行为。日志对人眼仍会偶尔出现 `\NNN`，只是不再影响判定。
- **R3 · 总数 ±delta 基线仍是人工同步的**（`catalyst-total-baseline.txt`）—— 既有机制，本片不碰。
- **R4 · 本片不改 `app-build.yml`**：实核（2026-10-06）它跑的是 `xcodebuild build`（`:41`）+
  「BUILD SUCCEEDED + 无 error」门（`:47`），**根本不执行测试** ⇒ 没有逐条测试名匹配，
  不受本缺陷影响。全文唯一含 `GATE PASS` 的是 `:52`，与 UIKit-gated 判据无关。

---

## 8. 两处未验证假设的处置：Task 1 是一个**在 CI 里跑的探针**

本设计有且只有两处没有实测结论：**§4.1**（包里能否区分 swift-testing 与 XCTest）
与 **§4.4**（CI 的 Xcode 16 上子命令与 JSON 结构是否相同）。

按本仓 `feedback_cannot_verify_is_not_a_reason_to_defer`（「『无法核实』不是延后的理由，
是去核实的理由」）与 `feedback_verify_foundational_infra_assumption_real_not_fake`
（「地基假设要真环境验」）：

⇒ **plan 的 Task 1 不写任何判据代码，只做一件事：开一个丢弃型探针 PR，让 CI 自己回答这两问。**

探针只往 `catalyst-build.yml` 加**一个纯打印步骤**（不改任何判据），输出：

1. `xcodebuild -version` 与 `xcrun xcresulttool version`（CI 实际版本，⛔ 别再假设）；
2. `xcrun xcresulttool get test-results tests --path … --format json` 的**退出码**
   （子命令是否存在）；
3. 取到的 JSON 里 `nodeType` 的取值分布与**一条含中文显示名的节点原文**
   （验字段名与中文是否完好）；
4. 能否把 swift-testing 与 XCTest 分开计数（§4.1）。

**看完即关，不合。** 两问有了 CI 的实测答案之后再写判据代码。
若 §4.4 的答案是「子命令不存在」⇒ 整个 §3 作废，回头改本 spec（退路：只治 G8，
用「解转义后再匹配」并额外设计防伪造，即原先被否的方案 B）；
若 §4.1 的答案是「无法区分」⇒ 按 §7 R1 的 (a) 收口。**⛔ 两种情况都不许硬凑。**

> ⭐ 这一条是 codex spec-R1 的功劳：它指出「要用 **CI 支持的那个 Xcode 版本**去验抽取与
> 名字匹配」。我原 spec 只把 §4.1 列为未决点，**漏了版本这一层** —— 而它比 §4.1 更致命
> （§4.1 最坏是退回读文本，§4.4 最坏是整个设计在 CI 上跑不起来、而本地全绿）。
