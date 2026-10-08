#!/bin/bash
# Stops AgentNotch: removes its hooks from ~/.claude/settings.json and quits the app.
# Claude Code sessions stop reporting and nothing shows in the notch.
APP="$HOME/Applications/AgentNotch.app"

if pgrep -xq AgentNotch; then
    pkill -TERM -x AgentNotch          # the app removes its hooks, then quits
    for _ in $(seq 1 50); do pgrep -xq AgentNotch || break; sleep 0.1; done
    pgrep -xq AgentNotch && pkill -KILL -x AgentNotch
fi
# Also clears hooks left behind if the app ever crashed.
"$APP/Contents/Resources/uninstall-hooks.sh" --quiet
echo "AgentNotch is off. Claude Code sessions no longer report to the notch."
