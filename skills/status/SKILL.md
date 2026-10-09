---
description: Report whether the Claude Context Meter widget is running, which version, and whether it starts at login.
disable-model-invocation: true
---

# Is it running?

Answer from evidence, not from one signal. Gather these, then summarise in a few lines.

**The process.** The widget is a `powershell.exe` hosting `ClaudeContextMeter.ps1`:

```
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*ClaudeContextMeter.ps1*' } | Select-Object ProcessId, ExecutablePath, CommandLine | Format-List"
```

The command line also tells you which copy is running — the installed one under
`%LOCALAPPDATA%\Programs\ClaudeContextMeter`, or this plugin's.

**The heartbeat.** `%LOCALAPPDATA%\ClaudeContextMeter.alive` holds a timestamp and a pid,
rewritten roughly every 30 seconds. Fresh means alive; a stamp minutes old with no matching
process means it died, and its time is the useful part — it narrows the death to half a
minute, which is close enough to line up against the Windows event log.

**Autostart.** `Get-ScheduledTask -TaskName ClaudeContextMeter` — present means the widget
starts at logon. Read the task's action to see which path it will run; a task pointing at a
folder that no longer exists is repaired on the widget's next start, not by the task itself.

**Version.** The `$Version` line in `ClaudeContextMeter.ps1` of whichever copy is running.
Compare it against the installed copy when both exist: two versions on one machine is worth
mentioning.

If nothing is running, do not start it as part of answering — say it is not running and
offer `/claude-context-meter:start`.
