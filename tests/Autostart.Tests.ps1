# Autostart since 1.3.2: the Run entry, Task Manager's switch, and the path repair.
# Runs against a throwaway registry key, never the real Run key of the machine.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ClaudeContextMeter.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) "Syntax errors: $errors"
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in @('Get-AutostartCommand', 'Get-AutostartEnabled', 'Set-AutostartEnabled', 'Sync-AutostartPath')) {
        # $PSCommandPath is automatic and empty inside code run by Invoke-Expression; point it
        # at the fixture folder instead.
        Invoke-Expression ($node.Extent.Text -replace '\$PSCommandPath', '$script:FixtureScript')
    }
}
function Write-Log($m) { }

$base = 'Registry::HKEY_CURRENT_USER\Software\ClaudeContextMeterTest-' + [guid]::NewGuid().ToString('N')
$RunKey = "$base\Run"; $ApprovedKey = "$base\Approved"; $RunValueName = 'ClaudeContextMeter'
$dir = Join-Path $env:TEMP ('ccm-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
$script:FixtureScript = Join-Path $dir 'ClaudeContextMeter.ps1'
try {
    New-Item -Path $ApprovedKey -Force | Out-Null

    # Without the launcher the .vbs is used; with it, the exe - that is what Task Manager shows.
    Set-Content (Join-Path $dir 'Start-ContextMeter.vbs') 'x'
    Assert ((Get-AutostartCommand) -like '*wscript.exe" "*Start-ContextMeter.vbs"') 'vbs fallback'
    Set-Content (Join-Path $dir 'ClaudeContextMeter.exe') 'x'
    Assert ((Get-AutostartCommand) -eq ('"' + (Join-Path $dir 'ClaudeContextMeter.exe') + '"')) 'launcher preferred'

    Assert (-not (Get-AutostartEnabled)) 'Nothing written yet must read as off'
    Assert ($null -eq (Set-AutostartEnabled $true)) 'enable failed'
    Assert (Get-AutostartEnabled) 'Run entry must read as on'

    # Switched off in Task Manager: odd first byte in StartupApproved.
    Set-ItemProperty -Path $ApprovedKey -Name $RunValueName -Value ([byte[]](3,0,0,0,0,0,0,0,0,0,0,0)) -Type Binary
    Assert (-not (Get-AutostartEnabled)) 'Task Manager switch-off must read as off'
    # Path repair must not undo that switch.
    Set-ItemProperty -Path $RunKey -Name $RunValueName -Value '"C:\old\place\ClaudeContextMeter.exe"'
    Sync-AutostartPath
    Assert ((Get-ItemProperty -Path $RunKey -Name $RunValueName).$RunValueName -eq (Get-AutostartCommand)) 'stale path not repaired'
    Assert (-not (Get-AutostartEnabled)) 'Path repair must leave the Task Manager switch alone'
    # Turning it on from the widget menu means on, also in Task Manager.
    Assert ($null -eq (Set-AutostartEnabled $true)) 're-enable failed'
    Assert (Get-AutostartEnabled) 'Enabling from the menu must clear the Task Manager switch-off'

    Assert ($null -eq (Set-AutostartEnabled $false)) 'disable failed'
    Assert (-not (Get-AutostartEnabled)) 'disabled must read as off'
    Assert ($null -eq (Get-ItemProperty -Path $ApprovedKey -Name $RunValueName -ErrorAction SilentlyContinue)) 'switch value left behind'
    # Repair never turns autostart back on behind the user's back.
    Sync-AutostartPath
    Assert ($null -eq (Get-ItemProperty -Path $RunKey -Name $RunValueName -ErrorAction SilentlyContinue)) 'Sync re-created a removed entry'
} finally {
    Remove-Item -Path $base -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
'PASS: launcher command, Run entry, Task Manager switch read and cleared, path repair without re-enabling'
