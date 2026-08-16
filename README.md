# Claude Context Meter

A small always-on-top widget for Windows that shows how full the context window of each
running Claude chat is — Claude Code and Cowork side by side — plus how many tokens you
have burned through in the rate-limit windows.

![The widget](docs/widget.png)

One PowerShell script, no install, no dependencies, no network.

## What a row tells you

```
CC  Handover 2026-08-13    ███████░░░   63%   1M
```

| Part | Meaning |
|---|---|
| `CC` / `CW` | which surface the chat belongs to — Claude Code or Cowork |
| title | the real chat title, as the app shows it |
| bar | how full the context window is — green, amber past 60 %, red past 80 % |
| `63 %` | the last prompt measured against that window |
| `1M` | the size of the window itself |

That last column matters more than it looks: 80 % of 200k and 80 % of 1M are very
different situations, and a percentage on its own hides which one you are in.

Rows dim after 30 minutes of silence. Hovering a row shows the project path, the exact
token count, the model, and when the chat was last active. Clicking one brings the Claude
window to the front and leaves its size alone — a maximised window stays maximised.

The footer adds up every session, subagents included, over the two rate-limit windows —
5 hours and 7 days. When the app has recorded plan usage, the percentage it reports is
shown next to each total.

## Running it

```bash
powershell -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ClaudeContextMeter.ps1
```

Better, double-click **`Start-ContextMeter.vbs`**. `powershell.exe` is a console
application, so Windows gives it a console window even though this script only ever shows a
WPF window, and `-WindowStyle Hidden` hides that console only after it exists — which is
what makes a black window flash on every start. The `.vbs` creates it hidden from the
outset, so nothing appears. `Start-ContextMeter.bat` still works and simply forwards to it.

A shortcut with the app icon is easy to make: point it at the `.vbs` and set its icon to
`ClaudeContextMeter.ico`.

Drag the widget anywhere — it remembers where you put it. `✕` hides it; it keeps running
and comes back from the tray icon. Only **Exit** in the tray menu really ends it.

## Settings

![The menu](docs/menu.png)

Click the gear, right-click the widget, or right-click the tray icon — the same settings
either way. Double-clicking the tray icon shows or hides the window.

- **Start at login** — registers a scheduled task with a logon trigger, running as you,
  without admin rights. The tick is read from the Task Scheduler every time a menu opens,
  so a task removed from outside shows as off instead of leaving a stale tick behind.
- **Language** — English or Russian, applied immediately.
- **Refresh rate** — Normal (3 s), Easy (10 s) or Minimal (30 s). Both the tick and the
  recursive rescan are stretched together, because the rescan is the expensive half;
  slowing only the tick would keep the cost and lose the freshness.
- **Check for updates** — on by default. Asks GitHub once at startup whether a newer
  release exists; if there is one, an **Update to x.y.z** line appears in both menus and
  downloads the installer. Every failure — offline, rate-limited, no release, no installer
  attached — is simply "no update": a version check must never be able to break the start.
- **Remember position** — on by default. The position is written the moment you finish
  dragging, not on exit: a widget that is killed rather than closed would otherwise lose
  where you put it every single time. It is validated against the whole desktop, so a spot
  on a second monitor — including one to the left of the primary, where the coordinates go
  negative — survives a restart.

The widget runs at `BelowNormal` priority, so it gets the processor only when nothing else
wants it. Together with the refresh setting that is the honest version of "keep it off my
way" — pinning it to one core would not reduce the work, only confine it.

The task's command is built from the script's own location, and a stale path is repaired on
the next start, so moving the folder does not break it.

A scheduled task rather than a `Run` registry entry, because a `Run` entry fires at logon
and never again — and a machine that sleeps for weeks instead of rebooting may not see a
logon for just as long. There is deliberately no repeating trigger: restarting a widget on
a timer hides whatever killed it, and pushes it onto the screen on days you are not using
Claude at all.

Anything the widget was started by before — a Startup-folder shortcut, a `Run` entry — is
taken over on first run: the task is registered first, and only once that succeeded is the
old mechanism removed. Two autostart entries for one program is a Task Manager annoyance
worth designing out.

## Notification area

The tray icon is the answer to "is it running, and where did it go". Its menu carries the
same settings plus **Show / Hide** and **Exit**, and it is removed on exit rather than left
as a ghost that only disappears when the mouse brushes it.

Windows 11 files new tray icons under the `^` overflow. Drag it onto the taskbar to keep
it in sight — that is the user's call to make, not something a program should force.

## Where the numbers come from

Everything is read from files Claude already writes locally:

| Source | Used for |
|---|---|
| `%USERPROFILE%\.claude\projects\**\*.jsonl` | Claude Code transcripts — token usage |
| `%APPDATA%\Claude\local-agent-mode-sessions` | Cowork transcripts and chat records |
| `%APPDATA%\Claude\claude-code-sessions` | Claude Code chat titles |
| `%USERPROFILE%\.claude\sessions` | which sessions are actually running |
| `%APPDATA%\Claude\plan-usage-history.json` | the plan usage percentages |

Nothing about your chats is sent anywhere. The widget talks to exactly one host, and only
if **Check for updates** is on: `api.github.com`, to ask this repository whether a newer
release exists. That request carries nothing but the request itself. Switch the setting off
and the widget makes no network connection at all.

The only Windows API it calls raises the Claude window when you click a row.

Its own state lives in `%LOCALAPPDATA%`: window position, the learned context windows per
model, the language, and a debug log.

### How the context window is guessed

Nothing on disk states which context window a chat runs on, so the widget works it out.
A prompt larger than 200k can only exist on a large window, so that is treated as proof.
Failing that it looks for the `[1m]` marker on the model name, then for what that model
has been caught doing before — remembered across restarts. Only when there is no evidence
at all does it fall back to an assumption.

## Requirements

Windows with Windows PowerShell 5.1 (shipped with Windows 10 and 11). Nothing else.

## Files

| File | |
|---|---|
| `ClaudeContextMeter.ps1` | the widget — all of it |
| `Start-ContextMeter.bat` | launcher |
| `ClaudeContextMeter.ico` | application icon |

[Русская версия](README.ru.md)
