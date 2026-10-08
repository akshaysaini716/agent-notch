#!/bin/bash
# Starts AgentNotch. While it runs, your Claude Code sessions show in the notch
# (the app adds its hooks to ~/.claude/settings.json; running sessions pick them up live).
APP="$HOME/Applications/AgentNotch.app"
SETTINGS="$HOME/.claude/settings.json"
URL="http://127.0.0.1:47823/hook"

if pgrep -xq AgentNotch; then
    echo "AgentNotch is already on."
    exit 0
fi
if [ ! -d "$APP" ]; then
    echo "AgentNotch isn't installed: run scripts/build.sh in the agent-notch repo first." >&2
    exit 1
fi

open "$APP"
for _ in $(seq 1 50); do
    if jq -e --arg url "$URL" '[.hooks[]?[]?.hooks[]?.url] | index($url) != null' "$SETTINGS" >/dev/null 2>&1; then
        echo "AgentNotch is on. Claude Code sessions now show in the notch."
        exit 0
    fi
    sleep 0.1
done
echo "AgentNotch started, but its hooks didn't appear in $SETTINGS." >&2
exit 1
