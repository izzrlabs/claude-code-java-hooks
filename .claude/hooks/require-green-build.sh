#!/bin/bash
# claude-code-java-hooks -- Stop hook (see settings.json; Stop takes no
# matcher: https://code.claude.com/docs/en/hooks#matcher-patterns, it fires once per turn).
#
# The gotcha this script exists to avoid: a build hook on PostToolUse re-runs the build
# after *every* file edit, which is slow and pointless mid-refactor. This hook runs on
# Stop instead -- once, when Claude is about to hand control back -- and only when
# format-on-edit.sh's PostToolUse job marked a build-relevant file as changed. Editing
# only a .md file never creates that marker, so a doc-only session stops immediately,
# with no build at all.
#
# BUILD_CMD: default is the fast loop (`mvn -q test`). Switch to `mvn -q verify` before a
# PR, or when a failsafe profile runs integration tests `test` skips. In a multi-module
# build, scope it to the module you're actually working in with `-pl`/`-am`, for example:
#   BUILD_CMD="mvn -q test -pl my-service -am"
# `-pl my-service` builds only that module; `-am` ("also make") builds the modules it
# depends on first so the scoped build still has what it needs.
# A Gradle project would use `gradle check` here instead -- cited as the equivalent, not
# shipped as a tested default: this repo's `example/` is Maven, not Gradle.
set -euo pipefail

BUILD_CMD="mvn -q test"
MAX_CONSECUTIVE_FAILURES=3

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
MARKER="$PROJECT_DIR/.claude/.build-pending"

if [ ! -f "$MARKER" ]; then
  exit 0  # nothing build-relevant changed this turn -- nothing to prove, let Claude stop
fi

# Payload read on Python's own stdin, never as a shell argument -- same reasoning (and
# same fix) as format-on-edit.sh and block-secrets.sh. The Stop payload can carry
# last_assistant_message, background_tasks and session_crons, which can be well past the
# OS's per-argument ARG_MAX (~128 KiB on Linux); `python3 - "$INPUT"` dying from that is a
# non-zero, non-2 exit that `set -euo pipefail` treats as a "non-blocking error" here --
# exactly backwards for the one hook whose job is to block a red build. Piping the payload
# in on stdin instead has no such ceiling.
SCRIPT="$(mktemp)"
trap 'rm -f "$SCRIPT"' EXIT

cat > "$SCRIPT" <<'PYEOF'
import json, sys
try:
    payload = json.load(sys.stdin)
except ValueError:
    print("false")
    sys.exit(0)
print(str(payload.get("stop_hook_active", False)).lower())
PYEOF

STOP_HOOK_ACTIVE="$(python3 "$SCRIPT")"

FAILURES="$(cat "$MARKER" 2>/dev/null || echo 0)"
case "$FAILURES" in ''|*[!0-9]*) FAILURES=0 ;; esac

if [ "$FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
  echo "require-green-build.sh: build still red after $FAILURES attempts in a row," \
       "giving up instead of looping forever (stop_hook_active=$STOP_HOOK_ACTIVE)." >&2
  rm -f "$MARKER"
  exit 0  # let Claude stop anyway -- a human needs to look at this, not another retry
fi

cd "$PROJECT_DIR"
BUILD_LOG="$(mktemp)"
if $BUILD_CMD >"$BUILD_LOG" 2>&1; then
  rm -f "$MARKER" "$BUILD_LOG"
  exit 0  # green: the marker is cleared, Claude may stop
fi

FAILURES=$((FAILURES + 1))
echo "$FAILURES" > "$MARKER"

{
  echo "require-green-build.sh: \`$BUILD_CMD\` failed (attempt $FAILURES of $MAX_CONSECUTIVE_FAILURES, stop_hook_active=$STOP_HOOK_ACTIVE). Last 20 lines:"
  tail -n 20 "$BUILD_LOG"
} >&2
rm -f "$BUILD_LOG"
exit 2  # blocks the Stop: Claude sees this stderr and keeps working instead of stopping
