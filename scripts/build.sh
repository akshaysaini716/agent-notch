#!/bin/bash
# Builds AgentNotch.app with the Command Line Tools (no Xcode needed), ad-hoc signs it,
# and installs it to ~/Applications. Pass --open to (re)launch it afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=build/AgentNotch.app
INSTALL="$HOME/Applications/AgentNotch.app"

swift build -c release --product AgentNotch
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/AgentNotch" "$BUNDLE/Contents/MacOS/AgentNotch"
cp Info.plist "$BUNDLE/Contents/Info.plist"
# The app adds/removes its Claude Code hooks with these while it runs.
mkdir -p "$BUNDLE/Contents/Resources"
cp hooks.json scripts/install-hooks.sh scripts/uninstall-hooks.sh "$BUNDLE/Contents/Resources/"
codesign --force --sign - "$BUNDLE"

# Quit a running copy gracefully (it removes its hooks on the way out).
if pgrep -xq AgentNotch; then
    pkill -TERM -x AgentNotch
    for _ in $(seq 1 50); do pgrep -xq AgentNotch || break; sleep 0.1; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$INSTALL"
cp -R "$BUNDLE" "$INSTALL"
echo "installed $INSTALL"

if [[ "${1:-}" == "--open" ]]; then
    open "$INSTALL"
fi
