#!/bin/bash
# claude-code-java-hooks -- PostToolUse hook, matcher "Edit|Write" (see
# settings.json). Does two independent jobs from one handler, so this repo ships 3 hook
# scripts total instead of 4:
#
#   1. Format: reformats a saved .java file with Spotless, scoped to that one file.
#      Swap FORMAT_CMD below for your own formatter's single-file command. This job never
#      blocks -- a formatter failure is a warning on stderr, not a build error, so a
#      flaky formatter can't stop an edit from landing.
#   2. Build marker: when the edited file is one that can turn a green build red
#      (production code, build config, migrations, runtime config), creates
#      .claude/.build-pending so the Stop hook (require-green-build.sh) knows a build is
#      owed before this session is allowed to stop. This job never runs the build itself.
#
# Both jobs read the same stdin JSON once. See
# https://code.claude.com/docs/en/hooks#posttooluse for the tool_input/tool_response
# shape this hook reads.

set -euo pipefail

# Payload read on Python's own stdin, never as a shell argument -- same reasoning (and
# same fix) as block-secrets.sh: a PostToolUse payload carries tool_input.content plus
# tool_response, which for a large Edit/Write can be well past a few hundred KB, and
# `python3 - "$INPUT"` passing that through argv risks the OS's ARG_MAX ceiling. Piping
# it in on stdin has no such limit.
SCRIPT="$(mktemp)"
trap 'rm -f "$SCRIPT"' EXIT

cat > "$SCRIPT" <<'PYEOF'
import json
import sys

try:
    payload = json.load(sys.stdin)
except ValueError:
    print("")
    sys.exit(0)
print(payload.get("tool_input", {}).get("file_path", ""))
PYEOF

FILE_PATH="$(python3 "$SCRIPT")"

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MARKER="$PROJECT_DIR/.claude/.build-pending"

# --- Job 2: flag a build as owed ----------------------------------------------------------
# Matches *.java, any pom.xml, Flyway *.sql, and application*.{yml,yaml,properties} --
# files that change behavior, not just style: production code, build config, database
# migrations and runtime config, as opposed to docs or comments.
case "$FILE_PATH" in
  *.java|*pom.xml|*.sql|*application*.yml|*application*.yaml|*application*.properties)
    mkdir -p "$(dirname "$MARKER")"
    # Create only if missing -- never overwrite an existing marker. require-green-build.sh
    # stores its consecutive-failure count in this file's content; overwriting it here
    # would reset that count on every edit and defeat the loop guard (see that script).
    [ -f "$MARKER" ] || echo 0 > "$MARKER"
    ;;
esac

# --- Job 1: format the file, .java only ----------------------------------------------------
case "$FILE_PATH" in
  *.java) ;;
  *) exit 0 ;;
esac

FORMAT_CMD="mvn -q spotless:apply"  # swap for your own formatter's single-file command

if ! grep -q "spotless" "$PROJECT_DIR/pom.xml" 2>/dev/null; then
  exit 0  # Spotless isn't configured in this project: stay silent, don't guess at a formatter
fi

LOG="$(mktemp)"
if ! $FORMAT_CMD "-DspotlessFiles=${FILE_PATH}" >"$LOG" 2>&1; then
  echo "format-on-edit.sh: Spotless failed on $FILE_PATH, file left unformatted." >&2
  tail -n 15 "$LOG" >&2
fi
rm -f "$LOG"

exit 0
