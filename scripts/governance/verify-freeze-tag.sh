#!/usr/bin/env bash
# verify-freeze-tag.sh — Wave 0 freeze tag protected namespace 完整谓词检查
# Spec: docs/superpowers/specs/2026-05-17-pr9-wave0-freeze-design.md §5.6 layer 1
# Usage: ./scripts/governance/verify-freeze-tag.sh --ref refs/tags/wave0-frozen-v1.4
set -euo pipefail

REPO="${REPO:-agateuu1234-bit/kline-trainer}"
TARGET_REF=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) TARGET_REF="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --ref refs/tags/wave0-frozen-v1.4 [--repo OWNER/NAME]"
      exit 0 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [ -z "$TARGET_REF" ]; then
  echo "FAIL: --ref refs/tags/wave0-frozen-v1.4 required"
  exit 2
fi

# 拉所有 rulesets — 用 env var 传 JSON 给嵌入 python（codex plan R1 finding 1 修：
# 不能用 stdin pipe + heredoc，<<'PY' 抢 stdin 让 json.load(sys.stdin) 拿不到）
RULESETS_JSON=$(gh api "repos/$REPO/rulesets" 2>&1) || {
  echo "FAIL: gh api repos/$REPO/rulesets 失败"
  echo "$RULESETS_JSON"
  exit 1
}

# 过滤 target=tag 的 ruleset ID 列表
TAG_RULESET_IDS=$(RULESETS_JSON="$RULESETS_JSON" python3 <<'PY'
import json, os
data = json.loads(os.environ['RULESETS_JSON'])
ids = [str(r['id']) for r in data if r.get('target') == 'tag']
print(' '.join(ids))
PY
)

if [ -z "$TAG_RULESET_IDS" ]; then
  echo "FAIL: 无任何 target=tag 的 ruleset 在 repo $REPO"
  echo "  required: ref_name include pattern 命中 '$TARGET_REF' / enforcement=active /"
  echo "            rules 含 creation+update+deletion / bypass_actors admin-only"
  echo "  修：GitHub repo Settings → Rules → New tag ruleset"
  exit 1
fi

# 逐个 ID 拉详情 + 评估
PROTECTED_OK=0
FAILED_REASONS=""
for RID in $TAG_RULESET_IDS; do
  DETAIL=$(gh api "repos/$REPO/rulesets/$RID")
  # codex plan R1 finding 1 修：DETAIL 通过 env var 传，不走 stdin（heredoc 抢 stdin）
  set +e
  RESULT=$(DETAIL_JSON="$DETAIL" TARGET_REF="$TARGET_REF" python3 <<'PY'
import json, os, fnmatch, sys
ruleset = json.loads(os.environ['DETAIL_JSON'])
target_ref = os.environ['TARGET_REF']

reasons = []

# 谓词 1: enforcement == active
if ruleset.get('enforcement') != 'active':
    reasons.append(f"enforcement={ruleset.get('enforcement')}, not active")

# 谓词 2: target_ref 命中 include + 不命中 exclude
conds = ruleset.get('conditions') or {}
ref_cond = conds.get('ref_name') or {}
include = ref_cond.get('include') or []
exclude = ref_cond.get('exclude') or []

# GitHub include pattern: 支持 ~ALL 通配 + fnmatch glob
def matches(patterns, ref):
    for p in patterns:
        if p == '~ALL':
            return True
        # 标准化: 如果 pattern 不含 refs/tags 前缀，补一下
        norm = p if p.startswith('refs/') else f'refs/tags/{p}'
        if fnmatch.fnmatchcase(ref, norm) or fnmatch.fnmatchcase(ref, p):
            return True
    return False

if not matches(include, target_ref):
    reasons.append(f"target_ref {target_ref} 不命中 include patterns {include}")
if matches(exclude, target_ref):
    reasons.append(f"target_ref {target_ref} 被 exclude patterns {exclude} 排除")

# 谓词 3: rules 含 creation + update + deletion 三类
rules = ruleset.get('rules') or []
types = {x.get('type') for x in rules}
required = {'creation', 'update', 'deletion'}
missing = required - types
if missing:
    reasons.append(f"rules 缺类型 {sorted(missing)}; 已有 {sorted(types)}")

# 谓词 4: bypass_actors 限 admin-only
bypass = ruleset.get('bypass_actors') or []
# GitHub admin: actor_type='RepositoryRole' + actor_id=5 (admin) OR actor_type='OrganizationAdmin'
def is_admin_bypass(b):
    at = b.get('actor_type', '')
    aid = b.get('actor_id', 0)
    if at == 'OrganizationAdmin':
        return True
    if at == 'RepositoryRole' and aid == 5:  # 5 = admin role per GitHub docs
        return True
    return False

non_admin = [b for b in bypass if not is_admin_bypass(b)]
if non_admin:
    reasons.append(f"bypass_actors 含 non-admin: {non_admin}")

if reasons:
    print("FAIL: " + " | ".join(reasons))
    sys.exit(1)
print("OK")
PY
)
  PY_EXIT=$?
  set -e

  if [ "$PY_EXIT" = "0" ] && [ "$RESULT" = "OK" ]; then
    echo "Ruleset $RID: OK"
    PROTECTED_OK=1
    break
  else
    FAILED_REASONS="$FAILED_REASONS\n  Ruleset $RID: $RESULT"
  fi
done

if [ "$PROTECTED_OK" != "1" ]; then
  echo "FAIL: 无 target=tag ruleset 满足 protected 谓词检查"
  printf '%b\n' "$FAILED_REASONS"
  echo ""
  echo "  required: enforcement=active +"
  echo "            $TARGET_REF 命中 include 且不命中 exclude +"
  echo "            rules 含 creation + update + deletion +"
  echo "            bypass_actors 仅 admin role"
  exit 1
fi

echo "GATE PASS: protected tag namespace 完整谓词检查通过（$TARGET_REF）"
exit 0
