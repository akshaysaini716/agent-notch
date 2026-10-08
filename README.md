# AgentNotch

Your Claude Code sessions, live in the MacBook notch.

- A buddy face on the left of the notch wears the most urgent mood across your agents: blue
  glancing eyes while working, amber wide eyes when one needs you, a mint smile when done.
  A light per agent sits on the right.
- Hover the notch to see **every open Claude Code agent**, including ones that were already
  running and idle before the notch started. Each shows its title and status ("Working 2:14",
  "Idle 3h ago", "Needs you"). **Click one** for its details: prompt, last steps, and what it's
  touching right now (the diff it's making, or the command and its output). Once it's idle,
  you see Claude's last reply instead.
- **Your names, your terminal.** Agents are named after their Warp tab when you've named it
  (e.g. "release prep"), else Claude's title. **Open in Warp** (or ↩) jumps to that agent's exact
  tab, using the `WARP_FOCUS_URL` Warp gives every shell. Other terminals get their app brought
  forward.
- **Keyboard.** ⌥Space opens the notch with keyboard focus: ↑/↓ choose an agent, ↩ opens its
  tab, Esc closes and hands focus back. On cards: A allow · S always allow · D deny ·
  T answer in terminal; on questions 1–9 pick, ↩ next/submit, ⌫ back. Key hints show only in
  this mode.
- **Any screen.** The notch follows the screen your cursor is on. On a display without a notch
  (like an external monitor) it's a compact pill at the top centre.
- When an agent finishes, the notch drops open with a chime: its name, "Done in 4:12", **what
  the turn did** (e.g. "2 files +5 −3" and "✓ Tests passed (BUILD SUCCESSFUL in 41s)", from the
  last test/build/lint run), and the start of Claude's final reply, with **Open in Warp** /
  **Details** / **Dismiss**. It folds away after 8s. If you're already browsing the open notch,
  the card doesn't cover it.
- **Reminders.** A permission or question card that has waited 3 minutes chimes again and the
  notch bounces, every 3 minutes; cards and rows show "Waiting 4m".
- **A tidy list.** Agents quiet for over a day fold into "Quiet for over a day". In keyboard mode,
  just type to search names and folders (Esc clears the search, then closes).
- **Settings** (gear in the open notch, or right-click): chimes, when to show finished cards
  (every reply / over 30s / never), how long they stay, reminders, **start at login**, quit.
- When an agent asks for permission, the notch drops a card with **Deny / Always allow / Allow**.
  **Answer in terminal** hands the question back to Claude Code's normal prompt.
- When an agent asks you a question (`AskUserQuestion`), answer it on the notch: click an option
  (multi-choice: tick, then **Next**/**Submit**; several questions step through with **Back**).
  For a free-text answer, use **Answer in terminal**.

Native Swift/SwiftUI, no dependencies, no network beyond `127.0.0.1`.

Inspired by [Coucou](https://github.com/Louis-CFM/coucou); a smaller, Mac-only take with its own
code and design.

## Build and run

Needs only the Xcode Command Line Tools (no Xcode).

```bash
./scripts/build.sh --open      # builds, installs ~/Applications/AgentNotch.app, launches it
swift test                     # unit tests for the event → state logic
```

## Start and stop

Double-click **Start AgentNotch** / **Stop AgentNotch** on the Desktop (copies live in
`scripts/`), or run them from a terminal.

- **Start** launches the app. Once it's listening, it adds its hooks to
  `~/.claude/settings.json`. Running Claude Code sessions pick that up live, and from then on
  every session shows in the notch.
- **Stop** quits the app, which first removes its hooks. Sessions stop reporting and nothing
  shows in the notch. Stop also clears any hooks left behind by a crash.

The hook edits keep your other hooks, preserve the file's formatting, and only write when
something changes. The previous version is kept at `~/.claude/settings.json.agentnotch-backup`.
Start then Stop leaves the file byte-for-byte as it was.

Right-click the open notch → **Quit AgentNotch** does the same as Stop.

**Without touching settings.json:** `AGENTNOTCH_MANAGE_HOOKS=0` before launching the app, then
`claude --settings /path/to/agent-notch/hooks.json` per session.

## How it works

```
Claude Code ──http hooks──▶ HookServer (127.0.0.1:47823)
                               │
                               ▼
                    Board (AgentNotchCore): sessions, step history, live preview, requests
                               │
                               ▼
                    NotchModel ─▶ SwiftUI in a non-activating NSPanel over the notch
```

- Progress events (prompt, tool start/finish, stop, session end, notifications) are answered
  at once with `{}`. Their hook timeout is 2s, so a stuck app can't hold Claude up.
- `AskUserQuestion` has its own held `PreToolUse` hook (`/hook/question`). Your choice goes back as
  `permissionDecision: allow` plus `updatedInput.answers`, which is how Claude Code lets a hook
  answer a question. While a card waits, the terminal shows no prompt. If Claude stops waiting
  (Esc), the card goes away.
- `PermissionRequest` is held open until you click. Allow, Deny, and Always allow become
  Claude Code's `decision` object. If Claude stops waiting (Esc, timeout), the card goes away.
- **Always allow** only sends Claude's suggested *allow rules* (e.g. `Bash(npm test *)`, saved
  to the project's `.claude/settings.local.json`). It never sends the mode switches Claude also
  suggests (such as `setMode: acceptEdits`).
- The app owns its hooks: it adds them once its server is listening and removes them before it
  quits (on SIGTERM too), keeping its server up for 1.5s so no session sees a refused connection.
- The list of open agents comes from the file Claude Code keeps for each running session
  (`~/.claude/sessions/<pid>.json`: session id, folder, busy/idle), read every 2s. A session
  leaves the list when its process exits. Details for quiet sessions come from the last 512 KB of
  their transcript (prompt, tool calls and results, Claude's last reply). These are Claude Code's
  internal files, not a documented API, so a future version could change them.
- Sessions killed without a `SessionEnd` are cleared once no running `claude` process has their
  directory (checked every 10s, after a 90s grace).

`AgentNotch hooks` prints `hooks.json`; a test keeps the two in sync.

## Debugging

```bash
pkill -x AgentNotch
AGENTNOTCH_DEBUG=1 ~/Applications/AgentNotch.app/Contents/MacOS/AgentNotch   # logs requests and clicks
curl -s 127.0.0.1:47823/debug/state                                        # (debug only) clickable area, mode, cursor
curl -s 127.0.0.1:47823/debug/open                                         # (debug only) hold the panel open for 6s
curl -s 127.0.0.1:47823/debug/hotkey                                       # (debug only) same as pressing ⌥Space
curl -s 127.0.0.1:47823/debug/type/tri                                     # (debug only) type into the notch
AGENTNOTCH_NUDGE_AFTER=10 …/AgentNotch                                      # reminders after 10s instead of 3m
.build/debug/AgentNotch snapshot snapshots/                                 # renders every UI state to PNG
```

## Known limits

- Exact-tab jumping is Warp-only; iTerm/Terminal/Ghostty just come to the front.
- Warp tab names come from Warp's state database (read-only), which Warp writes every few
  seconds, so a rename can take a moment to show.
- Questions: options only on the notch; free-text answers go through the terminal.
- Only Claude Code for now (hook-based; other agents would need their own adapters).
- `SessionStart` doesn't reach `http` hooks in our tests, so a session appears with its first
  prompt rather than at launch.
