#!/usr/bin/env python3
"""Strip bash heredoc bodies from a command string read on stdin.

Fail-closed rules:
1. If command contains ANY shell compound construct (pipe |, && / ||,
   command substitution $() or `...`, subshell (), background &, sequence ;),
   do NOT strip — return unchanged. Reason: heredoc body may be piped to
   shell interpreter and execute (e.g. `cat <<EOF | sh ... EOF`).
2. If the token immediately before `<<` is a known shell interpreter
   (bash/sh/zsh/python/etc), do NOT strip — body executes directly.
3. Otherwise (simple `cat > file <<EOF ... EOF` etc.), strip body.

This minimizes false positives on doc-writing patterns while refusing to
hide bodies that any reasonable interpretation would execute."""
import re
import sys

cmd = sys.stdin.read()

# Rule 1: any shell compound construct → leave heredocs intact.
# Check for unquoted occurrences of these tokens.
# Simple check: if ANY of these appear outside a heredoc-like body, fail closed.
COMPOUND_TOKENS = ["|", "&&", "||", ";", "$(", "`", "&"]
# Note: & as background; but & alone mid-string is fine in argv of e.g. URLs.
# Conservative: check anywhere.
has_compound = False
for tok in COMPOUND_TOKENS:
    if tok in cmd:
        has_compound = True
        break

if has_compound:
    print(cmd, end="")
    sys.exit(0)

INTERPRETERS = {
    "bash", "sh", "zsh", "ksh", "dash", "ash",
    "python", "python3", "python2",
    "ruby", "perl", "node", "nodejs",
    "php", "awk", "sed",
    "env",
    "/bin/sh", "/bin/bash", "/usr/bin/env",
}

def is_executing_heredoc(prefix_text):
    tokens = prefix_text.strip().split()
    if not tokens:
        return False
    for tok in reversed(tokens):
        if tok.startswith("-"):
            continue
        if tok in (">", "<", ">>", "2>", "2>&1"):
            continue
        base = tok.split("/")[-1]
        return base in INTERPRETERS or tok in INTERPRETERS
    return False

pattern = re.compile(
    "(?P<prefix>.*?)(?P<here><<-?[\'\"]?(?P<tag>\\w+)[\'\"]?[^\\n]*\\n.*?\\n\\s*(?P=tag)\\s*\\n?)",
    flags=re.DOTALL,
)

result_parts = []
pos = 0
for m in pattern.finditer(cmd):
    result_parts.append(cmd[pos:m.start()])
    prefix = m.group("prefix")
    here = m.group("here")
    if is_executing_heredoc(prefix):
        result_parts.append(prefix)
        result_parts.append(here)
    else:
        result_parts.append(prefix)
        result_parts.append(" ")
    pos = m.end()
result_parts.append(cmd[pos:])
print("".join(result_parts), end="")
