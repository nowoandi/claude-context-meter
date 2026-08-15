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
token count, the model, and when the chat was last active.

The footer adds up every session, subagents included, over the two rate-limit windows —
5 hours and 7 days. When the app has recorded plan usage, the percentage it reports is
shown next to each total.

## Running it

```bash
powershell -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ClaudeContextMeter.ps1
```

Or double-click `Start-ContextMeter.bat`. A shortcut with the app icon is easy to make:
point it at the `.bat` and set its icon to `ClaudeContextMeter.ico`.

Drag the widget anywhere — it remembers where you put it. Close it with `✕`.

## Settings

![The menu](docs/menu.png)

Click the gear or right-click the widget:

- **Start at login** — registers the widget under `HKCU\...\CurrentVersion\Run`. No admin
  rights, no scheduled task, no shortcut in the Startup folder. The state is read back
  from the registry every time the menu opens, so an entry removed from outside is
  reflected honestly instead of showing a stale tick.
- **Language** — English or Russian, applied immediately.
- **Refresh rate** — Normal (3 s), Easy (10 s) or Minimal (30 s). Both the tick and the
  recursive rescan are stretched together, because the rescan is the expensive half;
  slowing only the tick would keep the cost and lose the freshness.

The widget runs at `BelowNormal` priority, so it gets the processor only when nothing else
wants it. Together with the refresh setting that is the honest version of "keep it off my
way" — pinning it to one core would not reduce the work, only confine it.

The autostart command is built from the script's own location, and a stale path is
repaired on the next start. Moving the folder does not break it.

If the widget was previously started by a Startup-folder shortcut or a scheduled task, it
takes those over on first run: the registry entry is written first, and only once that
succeeded are the old mechanisms removed. Two autostart entries for one program is a
Task Manager annoyance worth designing out.

## Where the numbers come from

Everything is read from files Claude already writes locally:

| Source | Used for |
|---|---|
| `%USERPROFILE%\.claude\projects\**\*.jsonl` | Claude Code transcripts — token usage |
| `%APPDATA%\Claude\local-agent-mode-sessions` | Cowork transcripts and chat records |
| `%APPDATA%\Claude\claude-code-sessions` | Claude Code chat titles |
| `%USERPROFILE%\.claude\sessions` | which sessions are actually running |
| `%APPDATA%\Claude\plan-usage-history.json` | the plan usage percentages |

Nothing is sent anywhere. There is no network code in the script at all — no HTTP client,
no sockets. The only Windows API it calls raises the Claude window when you click a row.

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
