---
description: Start the Claude Context Meter widget, or bring it back when it is hidden.
disable-model-invocation: true
---

# Start the widget

Windows only — the widget is a WPF window driven by Windows PowerShell 5.1.

## Which copy to launch

Take the first of these that exists:

1. `%LOCALAPPDATA%\Programs\ClaudeContextMeter\Start-ContextMeter.vbs` — what the
   installer writes, and what the "Start at login" task points at. Prefer it: launching the
   installed copy keeps one version on the machine instead of two.
2. `${CLAUDE_PLUGIN_ROOT}\Start-ContextMeter.vbs` — this plugin's own copy, which is the
   whole widget, so the plugin works on a machine that never ran the installer.

If neither exists, say so rather than guessing at a path.

## How to launch it

Always through `wscript.exe`, never by calling the `.ps1` directly. `powershell.exe` is a
console application, so a direct start flashes a black console window; the `.vbs` creates
the process hidden from the outset. Start it detached as well — the widget runs until the
user exits it, and a foreground start would hold the session open for exactly that long.

```
powershell.exe -NoProfile -Command "Start-Process wscript.exe -ArgumentList '\"<path>\Start-ContextMeter.vbs\"'"
```

## What to expect

A second launch never produces a second widget. The process holds one global mutex, and an
instance that is merely hidden is shown again instead of duplicated — so there is nothing
to check beforehand. Afterwards, confirm which copy you started, and say plainly if it was
already running and you only brought it back.

The window appears where it was last dragged to, on whichever monitor that was. If it is
nowhere to be seen, the tray icon's **Show** brings it back; `/claude-context-meter:status`
will tell you whether it is running at all.
