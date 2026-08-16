@echo off
rem Kept for anyone who already has a shortcut to this file. It hands straight over to the
rem .vbs, which starts PowerShell with no console window at all - see the comments there.
start "" wscript.exe "%~dp0Start-ContextMeter.vbs"
