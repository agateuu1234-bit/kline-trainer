#!/usr/bin/env python3
"""Strip bash heredoc bodies from a command string read on stdin.
Used by guard-attest-ledger.sh detect_scenario to avoid false-positive matches on
'git push' / 'gh pr create' / 'gh pr merge' text inside heredoc bodies."""
import re
import sys

cmd = sys.stdin.read()
# Pattern captures <<TAG or <<'TAG' or <<"TAG" or <<-TAG variants
# then everything (re.DOTALL) up to \nTAG\n (or \nTAG at EOF).
pattern = re.compile(
    "<<-?[\'\"]?(\\w+)[\'\"]?[^\\n]*\\n.*?\\n\\s*\\1\\s*\\n?",
    flags=re.DOTALL,
)
stripped = pattern.sub(" ", cmd)
print(stripped, end="")
