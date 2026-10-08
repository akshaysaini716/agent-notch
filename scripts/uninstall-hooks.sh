#!/bin/bash
# Removes the AgentNotch hooks from ~/.claude/settings.json, leaving every other hook alone.
# Only writes when something changes. The app runs this itself when it quits; --quiet skips
# the diff. CLAUDE_SETTINGS overrides the file.
set -euo pipefail
BASE="http://127.0.0.1:47823/"   # every AgentNotch hook URL starts with this

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
[ -f "$SETTINGS" ] || exit 0
SETTINGS="$(readlink -f "$SETTINGS")"
TMP="$SETTINGS.agentnotch-tmp"

jq --arg base "$BASE" '
  def without_ours: map(select([.hooks[]?.url // "" | startswith($base)] | any | not));
  if .hooks then
    .hooks |= (with_entries(.value |= without_ours) | with_entries(select(.value | length > 0)))
    | if .hooks == {} then del(.hooks) else . end
  else . end
' "$SETTINGS" > "$TMP"

if cmp -s "$TMP" "$SETTINGS"; then rm -f "$TMP"; exit 0; fi
cp "$SETTINGS" "$SETTINGS.agentnotch-backup"
[ "${1:-}" = "--quiet" ] || diff -u "$SETTINGS" "$TMP" || true
mv "$TMP" "$SETTINGS"
[ "${1:-}" = "--quiet" ] || echo "updated $SETTINGS (previous version: $SETTINGS.agentnotch-backup)"
