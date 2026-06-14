# 本地 codex-attest 解耦自动更新缓存（钉死校验 v1.0.3）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让本地 `codex-attest.sh` 不再依赖会自动更新的 Claude 插件缓存，改为按 `codex.pin.json` 钉死的 `v1.0.3`（tag+commit+文件树指纹）clone+校验后运行，根治「缓存更新即断」。

**Architecture:** 新增 `.claude/scripts/resolve-pinned-codex.sh`（唯一职责=输出一份已校验的钉死 `codex-companion.mjs` 路径，fail-closed）；`codex-attest.sh` 把写死 1.0.3 路径块换成调它，并把 `--dry-run` 短路移到解析之前（避免 dry-run 触发克隆）。镜像 CI（`codex-review-verify.yml`）的 clone-pinned-tag + `verify-codex-tree.mjs` 机制，两通道版本对齐 v1.0.3。

**Tech Stack:** bash（`set -euo pipefail`）/ git clone --depth 1 / 既有 `node .claude/scripts/verify-codex-tree.mjs` / python3（读 pin JSON）。spec：`docs/superpowers/specs/2026-06-14-codex-attest-pin-decouple-design.md`。

---

## 背景（实施前必读）

- codex 评审两通道：**CI**（`.github/workflows/codex-review-verify.yml`，按 `codex.pin.json` 从 GitHub clone v1.0.3 + verify，**未坏**）；**本地** `.claude/scripts/codex-attest.sh`（写死 `…/codex/1.0.3/…codex-companion.mjs`，缓存升 1.0.4 后**硬 fail**）。本 PR 只修本地通道。
- 权威 pin：`codex.pin.json` → `codex_plugin_cc.{repo,tag,commit_sha,file_tree(41 文件 sha256)}`。
- 既有校验器：`node .claude/scripts/verify-codex-tree.mjs <pin.json> <plugin-root>` → 核 `pin.codex_plugin_cc.file_tree` 各文件 sha256；PASS 打印到 **stdout**（resolver 须把它重定向到 stderr，保 stdout 干净）；mismatch/missing exit 1。
- **机制已实测可行**（2026-06-14）：手动 clone v1.0.3（commit `11a720b7…`）+ `verify-codex-tree.mjs` → `PASS: 41 file(s) match pin`。
- 不改：`codex.pin.json` / `.github/workflows/**` / `.claude/settings.json`（见 spec §三/§七）/ attest 账本 / guard / override。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `.claude/scripts/resolve-pinned-codex.sh` | 输出一份已校验的钉死 `codex-companion.mjs` 绝对路径；clone+commit 核对+全树 verify+缓存；fail-closed。stdout 仅路径，诊断走 stderr。测试 seam：`CODEX_PIN_FILE`/`CODEX_PINNED_CACHE`/`CODEX_PINNED_GIT`。 | **Create** |
| `tests/scripts/test-resolve-pinned-codex.sh` | resolver host 可跑、不真联网测试（动态 fixture pin + stub git + 注入缓存）。6 case：cache-hit / clone-ok / verify-fail / 缺 pin 字段 / clone-fail / commit-mismatch。 | **Create** |
| `.claude/scripts/codex-attest.sh` | dry-run 短路前移 + 写死路径块（63–77）换成调 resolver + export `CLAUDE_PLUGIN_ROOT`。其余原样。 | **Modify** |
| `docs/acceptance/2026-06-14-codex-attest-pin-decouple.md` | 非-coder 可执行验收清单。 | **Create** |

---

## Task 1：`resolve-pinned-codex.sh` + 测试

**Files:**
- Create: `.claude/scripts/resolve-pinned-codex.sh`
- Test: `tests/scripts/test-resolve-pinned-codex.sh`

- [ ] **Step 1: 写测试（test-first）**

`tests/scripts/test-resolve-pinned-codex.sh`：

```bash
#!/usr/bin/env bash
# Host-isolated tests for resolve-pinned-codex.sh (no real network/clone).
set -uo pipefail
RESOLVER=".claude/scripts/resolve-pinned-codex.sh"
fail() { echo "FAIL: $1"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixture plugin tree (the "cloned" content) ---
TREE="$TMP/tree"; mkdir -p "$TREE/scripts"
printf '// fake codex companion\n' > "$TREE/scripts/codex-companion.mjs"
HASH="$(shasum -a 256 "$TREE/scripts/codex-companion.mjs" | awk '{print $1}')"
COMMIT="1111111111111111111111111111111111111111"

# --- fixture pin (matches the fixture tree) ---
PIN="$TMP/pin.json"
cat > "$PIN" <<EOF
{"codex_plugin_cc":{"tag":"vtest","commit_sha":"$COMMIT","repo":"file:///unused",
"file_tree":{"scripts/codex-companion.mjs":"sha256:$HASH"}}}
EOF

# --- stub git (env-driven): clone copies TREE; rev-parse echoes commit ---
STUBGIT="$TMP/stubgit"
cat > "$STUBGIT" <<'EOS'
#!/usr/bin/env bash
set -e
case "$1" in
  clone)
    [ "${STUB_GIT_MODE:-ok}" = "clonefail" ] && { echo "stub clone fail" >&2; exit 1; }
    dest="${@: -1}"; mkdir -p "$dest/plugins/codex"
    cp -R "$STUB_GIT_TREE/." "$dest/plugins/codex/"
    printf '%s' "$STUB_GIT_COMMIT" > "$dest/.stub_head" ;;
  -C)
    [ "${STUB_GIT_MODE:-ok}" = "commitmismatch" ] && { echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"; exit 0; }
    cat "$2/.stub_head" ;;
  *) exit 0 ;;
esac
EOS
chmod +x "$STUBGIT"

run() { CODEX_PIN_FILE="$PIN" CODEX_PINNED_CACHE="$1" CODEX_PINNED_GIT="$STUBGIT" \
        STUB_GIT_TREE="$TREE" STUB_GIT_COMMIT="$COMMIT" STUB_GIT_MODE="${2:-ok}" \
        bash "$RESOLVER"; }

# Case 1: clone-ok → prints path, exit 0
C1="$TMP/c1"
out="$(run "$C1" ok)" || fail "clone-ok should exit 0"
[ "$out" = "$C1/$COMMIT/src/plugins/codex/scripts/codex-companion.mjs" ] || fail "clone-ok path wrong: $out"

# Case 2: cache-hit → does NOT clone (stub set to clonefail, but cache pre-seeded) → still ok
# (reuse C1 which is now populated; clonefail would error if a clone were attempted)
out="$(run "$C1" clonefail)" || fail "cache-hit should skip clone and exit 0"
[ "$out" = "$C1/$COMMIT/src/plugins/codex/scripts/codex-companion.mjs" ] || fail "cache-hit path wrong"

# Case 3: clone-fail (offline) → exit 1
if run "$TMP/c3" clonefail >/dev/null 2>&1; then fail "clone-fail should exit nonzero"; fi

# Case 4: commit-mismatch → exit 1
if run "$TMP/c4" commitmismatch >/dev/null 2>&1; then fail "commit-mismatch should exit nonzero"; fi

# Case 5: verify-fail (tamper pin hash) → exit 1
BADPIN="$TMP/badpin.json"
cat > "$BADPIN" <<EOF
{"codex_plugin_cc":{"tag":"vtest","commit_sha":"$COMMIT","repo":"file:///unused",
"file_tree":{"scripts/codex-companion.mjs":"sha256:0000000000000000000000000000000000000000000000000000000000000000"}}}
EOF
if CODEX_PIN_FILE="$BADPIN" CODEX_PINNED_CACHE="$TMP/c5" CODEX_PINNED_GIT="$STUBGIT" \
   STUB_GIT_TREE="$TREE" STUB_GIT_COMMIT="$COMMIT" STUB_GIT_MODE=ok bash "$RESOLVER" >/dev/null 2>&1; then
  fail "verify-fail should exit nonzero"
fi

# Case 6: missing pin field (no commit_sha) → exit 2
NOPIN="$TMP/nopin.json"
printf '%s' '{"codex_plugin_cc":{"tag":"vtest","repo":"file:///x","file_tree":{}}}' > "$NOPIN"
CODEX_PIN_FILE="$NOPIN" CODEX_PINNED_CACHE="$TMP/c6" CODEX_PINNED_GIT="$STUBGIT" bash "$RESOLVER" >/dev/null 2>&1
rc=$?
[ "$rc" = "2" ] || fail "missing pin field should exit 2 (got $rc)"

echo "PASS"
```

- [ ] **Step 2: 跑测试看它失败**

Run: `bash tests/scripts/test-resolve-pinned-codex.sh`
Expected: 失败（`.claude/scripts/resolve-pinned-codex.sh` 不存在 → 各 run 非预期）。

- [ ] **Step 3: 写 resolver**

`.claude/scripts/resolve-pinned-codex.sh`：

```bash
#!/usr/bin/env bash
# resolve-pinned-codex.sh
# 输出一份已校验的、钉死版本的 codex-companion.mjs 绝对路径，解耦自会自动更新的
# Claude 插件缓存。读 codex.pin.json 的 codex_plugin_cc.{repo,tag,commit_sha,file_tree}，
# 按 commit 入键 clone 到本地缓存，verify-codex-tree.mjs 全树校验后打印路径。
# Fail-closed：任一步失败即非零退出，绝不回落到未校验副本。
# stdout：仅一行（路径）；所有诊断走 stderr。
# 测试 seam（默认即生产值）：CODEX_PIN_FILE / CODEX_PINNED_CACHE / CODEX_PINNED_GIT。
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PIN="${CODEX_PIN_FILE:-$REPO_ROOT/codex.pin.json}"
VERIFY="$REPO_ROOT/.claude/scripts/verify-codex-tree.mjs"
GIT_BIN="${CODEX_PINNED_GIT:-git}"

err() { printf '[resolve-pinned-codex] %s\n' "$*" >&2; }

[ -r "$PIN" ]    || { err "pin not readable: $PIN"; exit 2; }
[ -r "$VERIFY" ] || { err "verifier not readable: $VERIFY"; exit 2; }

read_pin() { python3 -c "import json; print(json.load(open('$PIN'))['codex_plugin_cc']['$1'])" 2>/dev/null; }
TAG="$(read_pin tag)"           || { err "pin missing codex_plugin_cc.tag"; exit 2; }
COMMIT="$(read_pin commit_sha)" || { err "pin missing codex_plugin_cc.commit_sha"; exit 2; }
REPO_URL="$(read_pin repo)"     || { err "pin missing codex_plugin_cc.repo"; exit 2; }
[ -n "$TAG" ] && [ -n "$COMMIT" ] && [ -n "$REPO_URL" ] || { err "pin fields empty"; exit 2; }

CACHE_ROOT="${CODEX_PINNED_CACHE:-$HOME/.cache/kline-trainer-codex}"
SRC="$CACHE_ROOT/$COMMIT/src"
PLUGIN="$SRC/plugins/codex"
COMPANION="$PLUGIN/scripts/codex-companion.mjs"

# 冷缓存：全程在唯一 staging 目录 clone+核 commit+校验，再原子 rename 发布到 $SRC。
# 绝不直接写/删已发布的 $SRC → 并发安全（codex R1 §medium）。
if [ ! -f "$COMPANION" ]; then
    mkdir -p "$CACHE_ROOT/$COMMIT"
    stage="$(mktemp -d "$CACHE_ROOT/.staging.XXXXXX")" || { err "mktemp failed under $CACHE_ROOT; fail-closed"; exit 1; }
    trap 'rm -rf "$stage"' EXIT
    "$GIT_BIN" clone --depth 1 --branch "$TAG" "$REPO_URL" "$stage/src" >&2 \
        || { err "git clone failed (offline?); fail-closed"; exit 1; }
    actual="$("$GIT_BIN" -C "$stage/src" rev-parse HEAD 2>/dev/null)" \
        || { err "rev-parse failed; fail-closed"; exit 1; }
    [ "$actual" = "$COMMIT" ] \
        || { err "commit mismatch: expected $COMMIT got $actual; fail-closed"; exit 1; }
    node "$VERIFY" "$PIN" "$stage/src/plugins/codex" >&2 \
        || { err "staged tree verify failed; fail-closed"; exit 1; }
    # 原子发布：rename 仅在 $SRC 不存在时成功（本进程胜出）；否则并发进程已发布
    # 一份已校验树 → 丢弃本 stage、复用对方。
    if ! mv "$stage/src" "$SRC" 2>/dev/null; then
        [ -f "$COMPANION" ] || { err "publish race lost but no valid cache present; fail-closed"; exit 1; }
    fi
    rm -rf "$stage"; trap - EXIT
fi

# 发布后校验（每次都跑，防 post-publish 篡改/损坏）。绝不在此 rm/替换已发布树
# （并发只读者可能正持有其文件句柄）→ 失败即 fail-closed 并指引人工清缓存。
node "$VERIFY" "$PIN" "$PLUGIN" >&2 || {
    err "published codex tree failed integrity check at $SRC."
    err "clear it and retry:  rm -rf \"$CACHE_ROOT/$COMMIT\""
    exit 1
}

printf '%s\n' "$COMPANION"
```

然后 `chmod +x .claude/scripts/resolve-pinned-codex.sh`。

- [ ] **Step 4: 跑测试看它通过**

Run: `chmod +x .claude/scripts/resolve-pinned-codex.sh && bash tests/scripts/test-resolve-pinned-codex.sh`
Expected: 末行 `PASS`（6 case 全过）。

- [ ] **Step 5: 真实 dogfood 烟测（验证 v1.0.3 真能取到）**

Run（联网；与背景实测同）：
```bash
TAG=$(python3 -c "import json;print(json.load(open('codex.pin.json'))['codex_plugin_cc']['tag'])")
COMMIT=$(python3 -c "import json;print(json.load(open('codex.pin.json'))['codex_plugin_cc']['commit_sha'])")
out=$(bash .claude/scripts/resolve-pinned-codex.sh) && echo "RESOLVED: $out"
test -f "$out" && echo "EXISTS"
```
Expected: 打印真实缓存路径 `…/$COMMIT/src/plugins/codex/scripts/codex-companion.mjs` + `EXISTS`，exit 0。（离线则跳过本 step，依赖 host 测 + CI dogfood。）

- [ ] **Step 6: Commit**

```bash
git add .claude/scripts/resolve-pinned-codex.sh tests/scripts/test-resolve-pinned-codex.sh
git commit -m "feat(codex-pin): resolve-pinned-codex.sh — clone+verify 钉死 v1.0.3，fail-closed（解耦自动更新缓存）"
```

---

## Task 2：`codex-attest.sh` 接入 resolver + dry-run 前移

**Files:**
- Modify: `.claude/scripts/codex-attest.sh`（替换第 63–85 行区块）

- [ ] **Step 1: 替换写死路径块**

把 `codex-attest.sh` 第 63–85 行（从 `# Locate codex-companion.mjs at pinned path` 到 dry-run 的 `fi`）整体替换为：

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

> 核对：替换后，原 64 行 `CODEX_PATH=…1.0.3…`、65–77 的存在检查与 `PIN_FILE` sha256 块、79–80 的 HEAD echo、82–85 的旧 dry-run 块**全部消失**（HEAD echo + dry-run 已并入上方新块）。后续 `if $DRY_RUN`（旧块）不得有残留。`$SCRIPT_DIR`/`$SCOPE`/`$FOCUS`/`$DRY_RUN` 均在脚本前文已定义。

- [ ] **Step 2: 既有 codex-attest 测试回归（dry-run 不再克隆）**

Run: `bash tests/scripts/test-codex-attest.sh`
Expected: `PASS`。（Test 2 跑 `--dry-run`：新 dry-run 消息含字面 `codex-companion` → grep 命中；且**不**触发 clone。）

- [ ] **Step 3: dry-run 不克隆的显式断言**

Run:
```bash
out=$(CODEX_PINNED_GIT=/bin/false bash .claude/scripts/codex-attest.sh --scope working-tree --dry-run --focus x 2>&1); echo "$out"
```
Expected: 含 `DRY RUN - would execute` 且**无** `[resolve-pinned-codex]` / `git clone` 字样（证 dry-run 在 resolver 之前短路，`/bin/false` 没被调用），exit 0。

- [ ] **Step 4: Commit**

```bash
git add .claude/scripts/codex-attest.sh
git commit -m "feat(codex-pin): codex-attest 接 resolve-pinned-codex + dry-run 前移（避免 dry-run 克隆）"
```

---

## Task 3：非-coder 验收清单

**Files:**
- Create: `docs/acceptance/2026-06-14-codex-attest-pin-decouple.md`

- [ ] **Step 1: 写验收清单**

```markdown
# 验收清单 — 本地 codex-attest 解耦自动更新缓存（钉死校验 v1.0.3）

**交付物：** `.claude/scripts/resolve-pinned-codex.sh`（新）+ `codex-attest.sh`（接入 + dry-run 前移）+ resolver host 测。0 业务代码；不改 codex.pin.json / CI / settings.json。

**前置：** 在仓库根执行；装 node + python3 + git。

| # | 操作（action） | 预期（expected） | 通过/不通过 |
|---|---|---|---|
| 1 | `bash tests/scripts/test-resolve-pinned-codex.sh` | 末行 `PASS`（6 case：clone-ok / cache-hit / clone-fail / commit-mismatch / verify-fail / 缺字段）| PASS = 通过 |
| 2 | `bash tests/scripts/test-codex-attest.sh` | 末行 `PASS`（既有；dry-run 不再克隆）| PASS = 通过 |
| 3 | `CODEX_PINNED_GIT=/bin/false bash .claude/scripts/codex-attest.sh --scope working-tree --dry-run --focus x` | 含 `DRY RUN - would execute`，**无** `git clone`/`[resolve-pinned-codex]`，exit 0 | 通过 |
| 4 | （联网）`bash .claude/scripts/resolve-pinned-codex.sh` | 打印 `…/<commit>/src/plugins/codex/scripts/codex-companion.mjs` 真实路径且文件存在，exit 0 | 通过（离线则记「跳过-离线」） |
| 5 | 阅读 `git diff origin/main --name-only` | 仅 `.claude/scripts/resolve-pinned-codex.sh`、`.claude/scripts/codex-attest.sh`、`tests/scripts/test-resolve-pinned-codex.sh`、`docs/**`；**无** `codex.pin.json`/`.github/**`/`.claude/settings.json`/业务代码 | 通过 |

**残留（cosmetic）：** `.claude/settings.json:41` 写死 1.0.3 的 allow 仍在（harmless dead path，第 147 行通配已覆盖；改它会触发无关 hardening_6_gate，故不在本 PR）。
```

- [ ] **Step 2: Commit**

```bash
git add docs/acceptance/2026-06-14-codex-attest-pin-decouple.md
git commit -m "docs(codex-pin): 非-coder 验收清单"
```

---

## Self-Review（spec 覆盖核对）

| spec 需求 | 实现任务 |
|---|---|
| §三 resolve-pinned-codex.sh（clone+verify+cache+fail-closed，三 env seam）| Task 1 Step 3 |
| §3.1 算法（读 pin / commit-keyed cache / staged clone+核 commit+verify / 原子 rename 发布 / 发布后每次 verify / fail-closed / 并发安全）| Task 1 Step 3（staging + atomic publish 块）|
| §3.2 codex-attest 接入 + dry-run 前移（消息保留 `codex-companion`）| Task 2 Step 1 |
| §四 离线/校验失败 fail-closed → override | Task 1（exit 1/2）+ Task 2 Step 1（exit 3 提示 override）|
| §五 测试（cache-hit/verify-fail/缺字段/clone-fail/commit-mismatch/集成）| Task 1 Step 1（6 case）+ Task 2 Step 2/3 |
| §七 不改 codex.pin.json/CI/settings.json | Task 3 验收 #5 守 |

**Placeholder 扫描：** 无 TBD/TODO；每 code step 给完整代码。
**类型/命名一致性：** env seam `CODEX_PIN_FILE`/`CODEX_PINNED_CACHE`/`CODEX_PINNED_GIT` 在 resolver 定义、测试使用一致；`SRC`/`PLUGIN`/`COMPANION`/`stage` 自洽；codex-attest 用 `$SCRIPT_DIR/resolve-pinned-codex.sh` 与 Task 1 创建路径一致。

---

## Execution Handoff

执行用 **subagent-driven-development**（每 task 独立 subagent + 两道评审）。Task 1→2→3 串行（Task 2 依赖 Task 1 的 resolver；Task 3 doc）。
