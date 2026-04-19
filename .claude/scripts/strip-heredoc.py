#!/usr/bin/env python3
"""Strip bash heredoc bodies from a command string read on stdin,
EXCEPT when the heredoc is attached to a shell interpreter (which would
actually execute the body). Used by guard-attest-ledger.sh detect_scenario
to avoid false-positive matches while not hiding real executions."""
import re
import sys

cmd = sys.stdin.read()

# Shell / interpreter commands that EXECUTE their heredoc body.
# If heredoc appears right after one of these (possibly with flags), keep body visible.
INTERPRETERS = {
    "bash", "sh", "zsh", "ksh", "dash", "ash",
    "python", "python3", "python2",
    "ruby", "perl", "node", "nodejs",
    "php", "awk", "sed",
    "env",  # env may pass to interpreter
    "/bin/sh", "/bin/bash", "/usr/bin/env",
}

def is_executing_heredoc(prefix_text):
    """Check if the text preceding << invokes a shell interpreter."""
    # Get last token chain before <<
    tokens = prefix_text.strip().split()
    if not tokens:
        return False
    # Take last non-flag, non-redirect token
    for tok in reversed(tokens):
        if tok.startswith("-"):
            continue
        if tok in (">", "<", ">>", "2>", "2>&1", "|", "&&", "||", ";", "&"):
            continue
        # strip any trailing redirect characters attached
        base = tok.split("/")[-1]  # handle /usr/bin/env
        return base in INTERPRETERS or tok in INTERPRETERS
    return False

# Find each heredoc; keep or strip based on context
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
        # Keep heredoc intact — interpreter will execute body
        result_parts.append(prefix)
        result_parts.append(here)
    else:
        # Passive heredoc (cat/tee/documentation) — strip body
        result_parts.append(prefix)
        result_parts.append(" ")
    pos = m.end()
result_parts.append(cmd[pos:])
print("".join(result_parts), end="")
