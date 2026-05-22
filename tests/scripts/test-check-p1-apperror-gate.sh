#!/usr/bin/env bash
# 单测 check_p1_apperror_gate.sh：clean 文件 PASS；含裸非-AppError throw 文件 FAIL。
set -euo pipefail
cd "$(dirname "$0")/../.."
GATE="scripts/check_p1_apperror_gate.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# case 1: 干净文件（AppError + CancellationError + *ErrorMapping.translate + 注释行 throw）→ PASS
cat > "$TMP/clean.swift" <<'EOF'
func a() throws { throw AppError.network(.timeout) }
func b() throws { throw CancellationError() }
func c() throws { throw APIErrorMapping.translate(err) }
// throw NSError() —— 注释行不算
EOF
if bash "$GATE" "$TMP/clean.swift" >/dev/null; then echo "PASS clean"; else echo "FAIL: clean 应 PASS"; exit 1; fi

# case 2: 含裸 throw URLError → FAIL
cat > "$TMP/dirty.swift" <<'EOF'
func d() throws { throw URLError(.timedOut) }
EOF
if bash "$GATE" "$TMP/dirty.swift" >/dev/null 2>&1; then echo "FAIL: dirty 应 FAIL"; exit 1; else echo "PASS dirty"; fi

# case 3（codex R3）: bare-variable 旁路——appErr 实为 URLError → 必须 FAIL
cat > "$TMP/bypass.swift" <<'EOF'
func e() throws {
    let appErr = URLError(.timedOut)
    throw appErr
}
EOF
if bash "$GATE" "$TMP/bypass.swift" >/dev/null 2>&1; then echo "FAIL: bare-variable 旁路应 FAIL"; exit 1; else echo "PASS bypass"; fi

# case 4（codex R4）: 行内注释旁路——throw error // AppError → 必须 FAIL
cat > "$TMP/inline.swift" <<'EOF'
func f() throws { throw error // AppError
}
EOF
if bash "$GATE" "$TMP/inline.swift" >/dev/null 2>&1; then echo "FAIL: 行内注释旁路应 FAIL"; exit 1; else echo "PASS inline"; fi

# case 5（codex R5）: public 方法体内 raw try 泄漏（无 throw 行也能漏 DecodingError）→ 必须 FAIL（同时覆盖规则2 + 规则3）
cat > "$TMP/rawtry.swift" <<'EOF'
public func g() throws -> Int {
    return try JSONDecoder().decode(Int.self, from: Data())
}
EOF
if bash "$GATE" "$TMP/rawtry.swift" >/dev/null 2>&1; then echo "FAIL: raw-try 泄漏应 FAIL"; exit 1; else echo "PASS rawtry"; fi

# case 6（codex R5 review）: 非 throw 代码行的行内注释含 "throw" 字词 → 不应误报（剥注释后无 throw 语句）→ PASS
cat > "$TMP/inline_comment_word.swift" <<'EOF'
func k() throws { try doSomething() }  // throw NSError here in a comment
func l() throws { throw AppError.network(.timeout) }
EOF
if bash "$GATE" "$TMP/inline_comment_word.swift" >/dev/null; then echo "PASS inline-comment-word"; else echo "FAIL: inline-comment-word 应 PASS"; exit 1; fi

echo "ALL PASS"
