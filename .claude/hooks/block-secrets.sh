#!/bin/bash
# claude-code-java-hooks -- PreToolUse hook, matcher "Edit|Write" (see
# settings.json). Reads the tool call's JSON from stdin, checks what Write would write
# (tool_input.content) and what Edit would insert (tool_input.new_string) against four
# patterns, and exits 2 to block the write the moment one matches -- see the "How it
# works" section of this repo's README for why exit 2 (not a JSON "deny" decision) is
# enough here: https://code.claude.com/docs/en/hooks#pretooluse-decision-control. This
# hook only blocks; it never edits the file itself.
#
# The JSON payload is read on Python's own stdin, never as a shell argument: a `Write`
# with a large `content` (a generated SQL seed file, a big YAML, anything past a few
# hundred KB) would blow past the OS's ARG_MAX if passed as argv, and `python3 - "$INPUT"`
# dying from that is itself a non-zero, non-2 exit -- which the hooks reference lists as
# "non-blocking error", so the write this hook exists to catch would go through
# unchecked. Piping the payload in instead has no such ceiling.
#
# To add, loosen, or drop a pattern, edit PATTERNS below -- nothing else in this file
# needs to change. Keep a new pattern's placeholder-safe class (the part that lets
# ${VAR}/<placeholder> through) if it follows the "generic secret assignment" shape.

set -euo pipefail

SCRIPT="$(mktemp)"
trap 'rm -f "$SCRIPT"' EXIT

cat > "$SCRIPT" <<'PYEOF'
import json
import re
import sys

PATTERNS = [
    ("AWS access key", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("GitHub token", re.compile(r"ghp_[A-Za-z0-9]{36,}")),
    ("private key header", re.compile(r"-----BEGIN .*PRIVATE KEY-----")),
    (
        # [^'"$<{] lets a placeholder through on purpose: ${AWS_ACCESS_KEY}, <your-key-here>,
        # and a quote that closes the string one character in all fail this class, so a real
        # secret (8+ opaque characters) still matches. See the "How it works" section of this
        # repo's README for the false-positive/false-negative trade-off this makes.
        "generic secret assignment",
        re.compile(r"(api[_-]?key|secret|password|token)\s*[:=]\s*['\"][^'\"$<{]{8,}", re.IGNORECASE),
    ),
]

try:
    payload = json.load(sys.stdin)
except ValueError:
    # Malformed input used to exit 0 here, on purpose -- "let the normal permission flow
    # decide, don't guess". That's the wrong default for a security gate: it means a
    # payload this parser can't read (truncated stdin, a Claude Code version with a
    # different hook-input shape) silently skips the secret check instead of blocking it.
    # Fail closed instead -- a real false positive on this path is one blocked write a
    # human can re-approve; a false negative is a leaked key.
    sys.stderr.write(
        "block-secrets.sh: couldn't parse the hook's own JSON input, blocking rather than"
        " skipping the secret check.\n"
    )
    sys.exit(2)

tool_input = payload.get("tool_input", {})
file_path = tool_input.get("file_path", "")
text = (tool_input.get("content") or "") + "\n" + (tool_input.get("new_string") or "")

for name, pattern in PATTERNS:
    match = pattern.search(text)
    if not match:
        continue
    ships_with_repo = re.search(r"application[^/]*\.(ya?ml|properties)$", file_path)
    hint = (
        " This file ships with your repo (every clone, every fork) -- a secret in it is a"
        " secret in git history forever, even after you edit it out."
        if ships_with_repo
        else ""
    )
    sys.stderr.write(
        f"Blocked: this looks like a {name} ({match.group(0)[:12]}...).{hint}\n"
        "Use an environment variable or a placeholder instead, e.g. ${AWS_ACCESS_KEY} in"
        " application.yml (Spring resolves it from the environment) or <your-key-here> in"
        " docs.\n"
        "False positive, or need a looser rule? Edit PATTERNS in"
        " .claude/hooks/block-secrets.sh -- this hook is the one place that list lives.\n"
    )
    sys.exit(2)

sys.exit(0)
PYEOF

python3 "$SCRIPT"
