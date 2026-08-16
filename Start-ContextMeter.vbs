' Starts the widget with no console window at any point.
'
' powershell.exe is a console application, so Windows allocates a console for it even when
' the script only ever puts a WPF window on screen. "-WindowStyle Hidden" hides that console
' AFTER it exists, which is why a black window flashes on every start, and a .bat adds a
' second flash of its own from cmd.exe. WScript.Shell.Run with show = 0 creates the process
' hidden from the outset, so nothing appears at all.
'
' Second argument 0 = hidden, third argument False = do not wait for it to finish.

Dim sh, here
Set sh = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
sh.Run "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File """ & here & "ClaudeContextMeter.ps1""", 0, False
