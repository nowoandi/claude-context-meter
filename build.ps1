# Builds the release: the launcher executable first, then the installer around it.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1
#
# The launcher is compiled here rather than committed as a binary, so what ships is always
# what launcher\ClaudeContextMeter.cs says. Both tools are already on a Windows machine with
# Inno Setup: csc.exe comes with .NET Framework 4, System.Management.Automation with
# Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$sma = Get-ChildItem (Join-Path $env:WINDIR 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter 'System.Management.Automation.dll' |
       Select-Object -First 1 -ExpandProperty FullName
$out = Join-Path $root 'build'
[void](New-Item -ItemType Directory -Path $out -Force)

# The launcher's file version has to match the widget's, or Task Manager and the installer
# would name two different versions for the same program.
$ver = [regex]::Match((Get-Content (Join-Path $root 'ClaudeContextMeter.ps1') -Raw), "\`$Version\s*=\s*'([\d.]+)'").Groups[1].Value
$cs = Get-Content (Join-Path $root 'launcher\ClaudeContextMeter.cs') -Raw
if ($cs -notmatch "Version = `"$([regex]::Escape($ver)).0`"") { throw "launcher version does not match widget version $ver" }

& $csc -nologo -target:winexe -platform:anycpu -optimize+ `
    "-win32icon:$(Join-Path $root 'ClaudeContextMeter.ico')" `
    "-reference:$sma" `
    "-out:$(Join-Path $out 'ClaudeContextMeter.exe')" `
    (Join-Path $root 'launcher\ClaudeContextMeter.cs')
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }

$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found' }
& $iscc (Join-Path $root 'ClaudeContextMeter.iss')
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
