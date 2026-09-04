---
description: Diagnose the Claude Context Meter widget on Windows — it disappeared, will not start, shows no rows, shows the wrong context percentage or window size, or its rate-limit totals look wrong. Also explains where its numbers come from.
---

# Diagnosing the widget

## Where the numbers come from

Everything is read from files Claude already writes locally. When a number looks wrong, the
question is which of these is missing or stale, not what the widget computed.

| Source | Used for |
|---|---|
| `%USERPROFILE%\.claude\projects\**\*.jsonl` | Claude Code transcripts — token usage |
| `%APPDATA%\Claude\local-agent-mode-sessions` | Cowork transcripts and chat records |
| `%APPDATA%\Claude\claude-code-sessions` | Claude Code chat titles |
| `%USERPROFILE%\.claude\sessions` | which sessions are actually running |
| `%APPDATA%\Claude\plan-usage-history.json` | the plan usage percentages |

Its own state lives in `%LOCALAPPDATA%`: `ClaudeContextMeter.pos` (window position),
`.models.json` (the learned context window per model), `.state.json`, `.alive` (heartbeat)
and `.log`.

## The log first

`%LOCALAPPDATA%\ClaudeContextMeter.log`. If it is not there, the script fell back to
`%TEMP%\ClaudeContextMeter.log` or to a log beside the `.ps1`; the first thing it records is
which file won, so start from whichever exists. Read the tail before theorising.

## Common causes

**Nothing on screen.** Usually hidden rather than gone — `✕` hides, only tray **Exit**
ends it. Check the tray (Windows 11 files new icons under the `^` overflow), then the
process; `/claude-context-meter:status` covers both. A window dragged to a monitor that has
since been unplugged is validated against the current desktop on the next start, so a
restart recovers it.

**It will not start at all.** Windows PowerShell 5.1 and `-STA` are both required — the
widget is WPF, and WPF needs a single-threaded apartment. Launch through
`Start-ContextMeter.vbs`, which passes `-STA -NoProfile -ExecutionPolicy Bypass` already.
A start that exits in silence normally means the single-instance mutex is held: something
is already running, possibly from another folder.

**No rows, or a chat missing.** The chat has to exist on disk in one of the sources above.
Titles and usage come from different stores, so a nameless row means the title store has no
record of that session yet, not that the usage is wrong. Rows dim after 30 minutes of
silence — dim is idle, not broken.

**The percentage looks wrong.** Read the last column before doubting the bar: nothing on
disk states which context window a chat runs on, so the widget works it out. A prompt above
200k is treated as proof of a large window; failing that it looks for the `[1m]` marker on
the model name, then for what that model has been caught doing before, remembered in
`.models.json`; only with no evidence at all does it assume. A model whose window was
guessed small will correct itself the first time it is seen above 200k. Deleting
`.models.json` resets that memory.

**The rate-limit totals look wrong.** The footer adds up every session over the 5-hour and
7-day windows, subagents included — a total larger than the visible chats suggest is
usually subagents, not a bug. The plan percentage next to it only appears once Claude has
recorded plan usage in `plan-usage-history.json`.

**Update check.** It asks `api.github.com` once at startup, and only when **Check for
updates** is on. Every failure — offline, rate-limited, no release — is deliberately
reported as "no update", so a missing update line is not evidence of a problem. With the
setting off, the widget makes no network connection at all.
