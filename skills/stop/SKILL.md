---
description: Stop the running Claude Context Meter widget.
disable-model-invocation: true
---

# Stop the widget

The widget's own way out is **Exit** in the tray menu; `✕` on the window only hides it and
leaves it running. From outside, ending the PowerShell process that hosts it is the
equivalent:

```
powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*ClaudeContextMeter.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
```

Report how many processes you ended, and say so plainly when there were none.

Two things worth knowing before you do it:

- **The position is safe.** It is written the moment a drag finishes, not on exit, so a
  killed widget still comes back where the user left it.
- **The next start logs it.** The mutex is released as abandoned rather than closed, and
  the next launch records `mutex was abandoned - the previous instance did not exit
  cleanly` before carrying on normally. That line is expected here, not a fault.

This does not touch the "Start at login" task, so the widget returns at the next logon. To
stop that too, untick **Start at login** in the widget's own menu, or unregister the task:

```
powershell.exe -NoProfile -Command "Unregister-ScheduledTask -TaskName ClaudeContextMeter -Confirm:$false"
```

Only do that when the user asked to disable autostart — stopping the widget once and
removing it from every future logon are different requests.
