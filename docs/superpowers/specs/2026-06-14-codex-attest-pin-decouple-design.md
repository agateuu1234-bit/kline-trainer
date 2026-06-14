# 设计：本地 codex-attest 解耦自动更新插件缓存，改用钉死并校验的 codex（治理 RFC）

**性质**：治理/工具变更（codex 评审通道的本地执行层）。0 业务代码。沿用 governance 走 brainstorming → writing-plans → codex:adversarial-review → PR review。

**触发**：PR #100（Wave 3 顺位 7）merge 时发现本地 `codex-attest.sh` 因 codex 插件缓存 1.0.3→1.0.4 自动更新而硬报错，导致 codex 本地评审通道仓库级失效（当次只能 opus-xhigh + attest-override 兜底）。

---

## 一、背景与根因（grep-first 核实 2026-06-14）

codex 评审有**两条独立执行通道**（对齐 `.claude/workflow-rules.json` `adversarial_review_loop.execution_venue_by_stage`）：

| 通道 | 文件 | 取 codex 的方式 | 现状 |
|---|---|---|---|
| **CI（不可伪造第二层 backstop）** | `.github/workflows/codex-review-verify.yml` | 按 `codex.pin.json` 的 `codex_plugin_cc.tag=v1.0.3` + `commit_sha` 从 GitHub `git clone --depth 1 --branch <tag>`，核 commit，再 `verify-codex-tree.mjs` 校验全文件树 sha256，从该克隆跑 | **未坏**（不依赖本地插件缓存） |
| **本地（best-effort 第一层）** | `.claude/scripts/codex-attest.sh` | **写死** `$HOME/.claude/plugins/cache/openai-codex/codex/1.0.3/scripts/codex-companion.mjs`（第 64 行） | **已坏**：Claude 插件缓存被自动更新为 `1.0.4`，`1.0.3` 目录已删 → 路径检查硬 fail（exit 3） |

**根因**：本地通道依赖**会被 Claude 插件系统自动更新、我们控制不了的缓存目录**，并把单一版本号写死在脚本里。任何缓存自动更新都会再次断（升 1.0.4 只是把问题推到下次 → 1.0.5 又断）。

**关键事实**：
- `codex.pin.json`（仓库根，已 commit）是权威 pin 清单：`codex_cli`（`@openai/codex@0.120.0` + npm integrity）+ `codex_plugin_cc`（repo + `tag=v1.0.3` + `commit_sha=11a720b7…` + 40+ 文件的 `file_tree` sha256，含 `scripts/codex-companion.mjs: sha256:352730455…`）。
- `.claude/scripts/verify-codex-tree.mjs <pin.json> <plugin-root>` 已存在（CI 在用），逐文件核 sha256。
- `.claude/scripts/codex-attest.sh` 另有一段**可选** `PIN_FILE=.claude/scripts/codex-companion.sha256` 检查（69–77 行）；该文件**不存在** → 此检查恒被跳过（弱于 file_tree 校验，且面向已弃用的缓存路径）。
- `.claude/settings.json:41` 写死 `Bash(node …/codex/1.0.3/scripts/codex-companion.mjs:*)` 允许（stale）；第 147 行通配 `Bash(node */codex-companion.mjs*)` 已覆盖任意路径的 codex-companion 调用。

---

## 二、目标与决策

**目标**：本地 `codex-attest.sh` 不再依赖会自动更新的插件缓存，改成像 CI 一样从 `codex.pin.json` 钉死的 `v1.0.3`（tag + commit + 文件树指纹）取一份**已校验**的 codex，根治「缓存更新即断」，并与 CI 通道版本对齐（评审口径一致）。

**已定决策（user 2026-06-14）**：
- **D1 持久修，非快速补丁**：解耦自动更新缓存，本地用钉死并校验的版本。
- **D2 保持 v1.0.3，不升 1.0.4**：不动 `codex.pin.json`、不动 `.github/workflows`（CI 本就用 v1.0.3 跑得通；升级评审器版本是另一项独立的供应链信任决策，不在本 RFC）。
- **D3 按需克隆 + 校验 + 本地缓存**（非 vendor 进仓库）：首次按 pin 的 tag/commit 从 GitHub 克隆到仓库外缓存目录，`verify-codex-tree.mjs` 全树校验后从该目录跑；离线/校验失败 → fail-closed 回退 `attest-override`。

---

## 三、架构（最小触点 + 单一职责）

| 文件 | 动作 | 职责 |
|---|---|---|
| `.claude/scripts/resolve-pinned-codex.sh` | **新增** | 唯一职责：输出一份「已校验的钉死 `codex-companion.mjs` 绝对路径」；失败即非零退出。可被 `codex-attest.sh` 调用、可独立测试。 |
| `.claude/scripts/codex-attest.sh` | **改** | (a) 把 `--dry-run` 短路**移到解析钉死 codex 之前**（避免 dry-run 触发克隆）；(b) 用 `CODEX_PATH=$(bash "$SCRIPT_DIR/resolve-pinned-codex.sh")` 替换写死 1.0.3 路径块（第 64 行）+ 存在性检查 + 可选 `codex-companion.sha256` 块（69–77 行）+ export `CLAUDE_PLUGIN_ROOT`。其余（node 二进制白名单 40–61、verdict 解析、ledger 写入）原样。 |
| `tests/scripts/test-resolve-pinned-codex.sh` | **新增** | resolver 的 host 可跑、不真联网测试（stub git + fixture pin + CODEX_PINNED_CACHE 注入）。 |

**不动**：`codex.pin.json`、`.github/workflows/**`、`verify-codex-tree.mjs`、`.claude/settings.json`、attest 账本/guard/override 机制本身、任何业务代码。

**`.claude/settings.json:41` 不在本 PR 改（settings-scope 校正）**：该行写死 `node …/codex/1.0.3/…codex-companion.mjs` 允许，因缓存升 1.0.4 已成 stale——但它是 **harmless dead config**（该路径已不存在、永不匹配；第 147 行通配 `node */codex-companion.mjs*` 已覆盖任意真实直调），且**非本 PR 引入**（缓存自动更新所致，非「我的 mess」）。改 `settings.json` 会触发 `hardening_6_gate.yml`（其 path filter 含 `settings.json`）这条**与本变更无关**的闸门，徒增 surface。故**不改**，列为 cosmetic residual（§六）。codex-attest.sh 内部的 `node codex-companion.mjs` 是 `bash codex-attest.sh` 的子进程、不经 Claude Bash 权限层，故新解析路径**无需** settings.json 允许。

### 3.1 `resolve-pinned-codex.sh` 契约

**输入**：cwd = 仓库根（`codex.pin.json` + `.claude/scripts/verify-codex-tree.mjs` 可读）。可选 env `CODEX_PINNED_CACHE`（默认 `$HOME/.cache/kline-trainer-codex`）覆盖缓存根（供测试/CI 隔离）。

**输出**：stdout **仅**打印一行——已校验插件的 `…/plugins/codex/scripts/codex-companion.mjs` 绝对路径（diagnostics 全走 stderr，确保 `$(…)` 捕获干净）。**`CLAUDE_PLUGIN_ROOT` 不由本脚本 export**（`$(bash resolve.sh)` 子壳的 export 不传回父进程）——由调用方 `codex-attest.sh` 从打印的路径派生并 export（见 §3.2），对齐 CI 第 142–143 行的 `CLAUDE_PLUGIN_ROOT=$PLUGIN_DIR`。

**算法**：
1. 从 `codex.pin.json` 读 `codex_plugin_cc.tag`、`commit_sha`、`repo`（python3 解析，与 CI 同源字段）。任一缺失 → stderr 报错 + 非零退出。
2. 缓存目录按 commit 取键：`CACHE_ROOT="${CODEX_PINNED_CACHE:-$HOME/.cache/kline-trainer-codex}"`；`SRC="$CACHE_ROOT/<commit_sha>/src"`；`PLUGIN="$SRC/plugins/codex"`（commit 入路径 → re-pin 换 commit 自动用新目录，旧缓存不复用）。
3. **取得**（缺 `$PLUGIN/scripts/codex-companion.mjs` 时）：`git clone --depth 1 --branch <tag> <repo> "$SRC"` → `ACTUAL=$(git -C "$SRC" rev-parse HEAD)`；`ACTUAL != commit_sha` → 删 `$SRC` 重试一次；再不符 → fail-closed。（镜像 CI 第 113–117 行。）
4. **校验**（每次都跑，含缓存命中）：`node .claude/scripts/verify-codex-tree.mjs codex.pin.json "$PLUGIN"`；非零 → 删 `$SRC` 重克隆一次 → 再非零 → fail-closed。（防本地缓存被篡改/残缺。）
5. 打印 `$PLUGIN/scripts/codex-companion.mjs`，退出 0。

**fail-closed 不变量**：任一步失败 → 非零退出，**绝不**回落到未校验/未钉死的缓存或任何其它路径。

### 3.2 `codex-attest.sh` 集成点

原结构（第 63–85 行）：locate 写死路径（63–77）→ HEAD echo（79–80）→ `--dry-run` 短路（82–85，消息引用 `$CODEX_PATH`）。**问题**：dry-run 在解析路径之后，改用 resolver 后会让 `--dry-run` 也触发克隆（破坏既有 `test-codex-attest.sh` Test 2 + CI 无网）。**故须 reorder**：先 HEAD echo → 再 `--dry-run` 短路（消息改为不依赖已解析路径、但仍含字面 `codex-companion`）→ 最后才 resolver。替换 63–85 为：

```sh
HEAD_SHA_GIT=$(git rev-parse HEAD 2>/dev/null || echo "untracked")
echo "[codex-attest] auto HEAD=$HEAD_SHA_GIT  scope=$SCOPE"

# Dry-run short-circuits BEFORE resolving the pinned codex (no clone on dry-run).
if $DRY_RUN; then
    echo "[codex-attest] DRY RUN - would execute: node <pinned codex-companion.mjs via resolve-pinned-codex.sh> adversarial-review --wait --scope $SCOPE $FOCUS"
    exit 0
fi

# Resolve pinned + verified codex-companion.mjs (decoupled from auto-updating plugin cache).
CODEX_PATH="$(bash "$SCRIPT_DIR/resolve-pinned-codex.sh")" || {
    echo "[codex-attest] ERROR: cannot resolve pinned codex (offline / verify failed); use attest-override.sh on a tty." >&2
    exit 3
}
export CLAUDE_PLUGIN_ROOT="$(dirname "$(dirname "$CODEX_PATH")")"   # …/plugins/codex
```

（`SCRIPT_DIR` 已在脚本顶部定义。dry-run 消息保留字面 `codex-companion` 子串 → `test-codex-attest.sh` Test 2 仍过、且不再克隆。node 二进制白名单检查 40–61 行保留——它校验调用 `codex-companion.mjs` 的 `node` 解释器可信，与本变更正交。）

---

## 四、错误处理 / 离线回退

- **离线 / 克隆失败 / commit 不符 / 文件树校验不符** → `resolve-pinned-codex.sh` 非零 → `codex-attest.sh` 带清晰提示退出 → 用户走既有 **`attest-override`（user TTY）** 兜底。**永不**运行未校验/未钉死的评审器（fail-closed 红线）。
- 与现状对比：现状是「缓存版本漂移 → 硬 fail（exit 3）」；新设计是「钉死版本可取且校验通过 → 跑；否则 fail-closed → override」。后者把失败面从「缓存版本是否恰好等于写死值」收窄到「能否取到并校验那个钉死版本」。

---

## 五、测试策略

沿用现有 hook/脚本测试风格（`tests/scripts/`、`tests/hooks/`，`CODEX_*_TEST_MODE` / env 注入），**host 可跑、不真联网**：

1. **缓存命中**：预置一个「已校验」的假 `$CODEX_PINNED_CACHE/<commit>/src/plugins/codex` 树（含与测试用 `codex.pin.json` 匹配的文件 + sha256）→ resolver 不克隆、直接打印路径、exit 0。
2. **校验失败 fail-closed**：缓存目录里某文件被改 → `verify-codex-tree.mjs` 失败 → resolver 非零退出。
3. **pin 缺字段**：测试 `codex.pin.json` 缺 `commit_sha` → 报错非零退出。
4. **克隆失败（离线）**：注入一个会失败的 `git`（PATH 前置 stub 或 `CODEX_PINNED_GIT` 注入）→ resolver 非零退出（不静默成功）。
5. **commit 不符**：stub git 克隆出错误 commit → resolver fail-closed。
6. `codex-attest.sh` 集成：`--dry-run` 路径下 resolver 被调用且失败时 attest 非零退出（不写账本）。

测试用的 `codex.pin.json` + 假插件树为 fixture，不触真实 GitHub / 真实缓存。

---

## 六、本 PR 的 review 策略

- 本 PR **不碰** `.github/workflows`、**不碰** `codex.pin.json` → trust-boundary glob `.github/workflows` 未触发；CI 的 codex 评审通道（未坏）会照常在本 PR 上跑。故**走正经 codex:adversarial-review**（同时 dogfood 我们在修的通道）。
- 分支上的 `resolve-pinned-codex.sh` 一落地，本地 `codex-attest.sh` 即可用修好的版本自举 attest（self-host 验证）。
- **真正变量 = OpenAI 配额**：配额可用 → 真 codex verdict 到收敛；配额耗尽 → 按 `feedback_review_tool_switch_must_ask` escalate（user 已显式选 codex，不擅自换），经确认后 opus 4.8 xhigh + `attest-override` 兜底。
- 其它 CI 须真绿：本 PR 无 Swift 代码，Catalyst/swift-test 不受影响（应 skip 或 trivially pass）。
- 撞 ≥3 轮 codex needs-attention / permanent-bias → 按 `feedback_big_pr_codex_noncovergence` + `feedback_codex_round6_self_contradiction` escalate + accept residual + override，不绕 required checks。

---

## 七、明确 OUT of scope

- 不升级到 1.0.4、不改 `codex.pin.json`（保持 v1.0.3）。
- 不改 `.github/workflows/**`（CI 通道未坏）。
- **不改 `.claude/settings.json`**（§三：stale 1.0.3 allow 是 harmless dead config + 非本 PR 引入 + 改它触发无关的 hardening_6_gate；列 cosmetic residual）。
- 不碰 attest 账本 / `guard-attest-ledger.sh` / `attest-override.sh` 机制本身。
- 不 vendor 插件文件进仓库。
- 不重构 `codex-attest.sh` 的其它部分（node 白名单 / verdict 解析 / ledger 写入原样）。
- 不改业务代码 / Swift / schema。

---

## 八、威胁模型对齐

`codex.pin.json` 的存在意义 = 评审跑的是**精确、已校验、未被篡改**的源（CI 不可伪造第二层即据此）。本设计让本地通道也建立在同一钉死源上（clone 钉死 commit + 全树 sha256 校验 + fail-closed），**强于**现状（现状依赖可变缓存 + 一个恒被跳过的可选 sha256 检查）。本地仍是「best-effort 第一层」（OpenAI 配额/网络可用性不保证），真正强制仍由 CI required-check 兜底——本设计不改变该分层，只是让第一层不再因缓存漂移而脆断、且口径与第二层一致。

---

## 九、停止规则（永久偏见护栏）

沿用 `feedback_codex_round6_self_contradiction`：§三/§四的契约一旦写入即权威答案。判 permanent-bias 须同时满足：①要求的补救 = 已被 §二决策显式否决的同一补救（如要求升 1.0.4 已 D2 否决 / 要求 vendor 进仓库已 D3 否决 / 要求本地放弃 fail-closed 已 §四红线否决）；②未引入任何新事实/新失败路径。命中 → user TTY override + admin merge，不实施。「指出某断言事实上错」永不算复述。
