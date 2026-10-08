#!/bin/bash
# Adds the AgentNotch hooks to ~/.claude/settings.json so Claude Code sessions report to the
# notch. Keeps your other hooks, is safe to re-run, and only writes when something changes.
# The app runs this itself on launch; --quiet skips the diff. CLAUDE_SETTINGS overrides the file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$HERE/hooks.json"; [ -f "$HOOKS" ] || HOOKS="$HERE/../hooks.json"
BASE="http://127.0.0.1:47823/"   # every AgentNotch hook URL starts with this

SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
SETTINGS="$(readlink -f "$SETTINGS")"   # write through a symlinked settings file, not over it
TMP="$SETTINGS.agentnotch-tmp"

jq --slurpfile ours "$HOOKS" --arg base "$BASE" '
  def without_ours: map(select([.hooks[]?.url // "" | startswith($base)] | any | not));
  .hooks = (.hooks // {})
  | reduce ($ours[0].hooks | to_entries[]) as $e (.;
      .hooks[$e.key] = (((.hooks[$e.key] // []) | without_ours) + $e.value))
' "$SETTINGS" > "$TMP"

if cmp -s "$TMP" "$SETTINGS"; then rm -f "$TMP"; exit 0; fi
cp "$SETTINGS" "$SETTINGS.agentnotch-backup"
[ "${1:-}" = "--quiet" ] || diff -u "$SETTINGS" "$TMP" || true
mv "$TMP" "$SETTINGS"
[ "${1:-}" = "--quiet" ] || echo "updated $SETTINGS (previous version: $SETTINGS.agentnotch-backup)"
