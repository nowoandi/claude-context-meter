$dst="D:\Projects\10 - Installationen\ClaudeContextMeter\_diag"
Copy-Item (Join-Path $env:LOCALAPPDATA 'ClaudeContextMeter.log') "$dst\REAL.log" -Force -EA SilentlyContinue
$o=@()
$o += "LOCALAPPDATA=$env:LOCALAPPDATA"
$o += "TEMP=$env:TEMP"
$o += "--- Setup-Dateien in TEMP ---"
Get-ChildItem $env:TEMP -Filter "ClaudeContextMeter*setup*.exe" -EA SilentlyContinue | ForEach-Object { $o += ("  " + $_.Name + "  " + $_.Length + " B  " + $_.LastWriteTime) }
$o += "--- installierte Version ---"
$p="$env:LOCALAPPDATA\Programs\ClaudeContextMeter\ClaudeContextMeter.ps1"
if(Test-Path $p){ $o += ((Select-String -Path $p -Pattern '^\$Version').Line) ; $o += ("  Datei geaendert: " + (Get-Item $p).LastWriteTime) } else { $o += "  nicht installiert" }
$o += "--- Uninstall-Eintrag ---"
$k="HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7C1F4E92-3A6D-4B58-9E0C-2D5A8F14B7C3}_is1"
try { $v=Get-ItemProperty $k -EA Stop; $o += ("  DisplayVersion=" + $v.DisplayVersion) } catch { $o += "  kein Eintrag" }
$o | Set-Content "$dst\INFO.txt"
