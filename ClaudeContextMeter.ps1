# ClaudeContextMeter — always-on-top mini widget for Claude/Cowork sessions.
# Rows: one per RUNNING Cowork/Claude Code session with its real chat title and context fill.
# Footer: total token throughput for the rate-limit windows (5 hours / 7 days), all sessions incl. subagents.
# Local files only, no network. Run: powershell -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ClaudeContextMeter.ps1

# ---------- diagnostics ----------
# The log is opened before anything else can fail, and it APPENDS.
#
# It used to start after the single-instance guard and be written with Set-Content, which
# cost both halves of a diagnosis on 15.08.2026: an instance that exited at the guard left
# no trace at all, and a widget that had been running for two hours turned out to have
# written nothing either - Set-Content lost a race against a second copy and failed
# non-terminatingly (the default ErrorActionPreference is Continue, so the script carried
# on, unlogged). Overwriting on top of that meant every restart destroyed the evidence of
# the run that had just died. A widget that can disappear without a line in its own log
# cannot be debugged at all.
# The log path is PROVEN writable at startup, not assumed. A widget started by the
# scheduled task on 16.08.2026 ran perfectly — window up, priority applied, every line of
# code past the logging calls executed — and wrote nothing at all, while an identical probe
# task wrote to the same file without trouble. Rather than keep guessing which host detail
# swallowed it, the log now tries candidates in order and keeps the first that accepts a
# write. Which one won is the first thing it records, so the next mystery starts with a
# known file instead of a suspected one.
$DbgLog = $null
foreach ($cand in @(
    (Join-Path $env:LOCALAPPDATA 'ClaudeContextMeter.log'),
    (Join-Path $env:TEMP 'ClaudeContextMeter.log'),
    (Join-Path (Split-Path -Parent $PSCommandPath) 'ClaudeContextMeter.log')
)) {
    if (-not $cand) { continue }
    try {
        [System.IO.File]::AppendAllText($cand, '', [System.Text.Encoding]::UTF8)
        $DbgLog = $cand
        break
    } catch {}
}

function Write-Log([string]$text) {
    # Raw .NET, not Add-Content. Add-Content goes through the PowerShell file provider, and
    # on 16.08.2026 a widget launched by the scheduled task wrote NOT ONE line through it —
    # window up, priority applied, everything past the logging calls working — while an
    # otherwise identical probe task wrote to the same file without trouble. Whatever the
    # provider objected to in that host, AppendAllText does not care: it is one open, one
    # write, one close, with no provider and no PSDrive involved.
    #
    # Logging must never take the widget down, and must not lose a line to a race with a
    # second copy, so failures are retried briefly and then swallowed.
    if (-not $DbgLog) { return }
    $line = "{0}  [{1}]  {2}{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID, $text, [Environment]::NewLine
    for ($i = 0; $i -lt 5; $i++) {
        try {
            [System.IO.File]::AppendAllText($DbgLog, $line, [System.Text.Encoding]::UTF8)
            return
        } catch { Start-Sleep -Milliseconds 40 }
    }
}

try {
    if ((Test-Path $DbgLog) -and (Get-Item $DbgLog).Length -gt 512000) {
        Move-Item $DbgLog "$DbgLog.1" -Force -ErrorAction SilentlyContinue
    }
} catch {}

Write-Log "---- start | script: $PSCommandPath | log: $DbgLog"
trap { Write-Log ("TRAP: " + ($_ | Out-String).Trim()); break }

# single instance guard.
# AbandonedMutexException is a SUCCESS here, not a failure: it means the previous widget
# was killed instead of closed (task manager, a hard reboot, a crash) and the mutex is now
# ours. Letting it escape kept the widget from ever starting again after such a kill.
# Both outcomes are logged now: "it vanished" and "it refused to start because a copy in
# another folder already held the mutex" look identical on screen and are different bugs.
$script:mutex = New-Object System.Threading.Mutex($false, "Global\ClaudeContextMeter")
try {
    $free = $script:mutex.WaitOne(0, $false)
} catch [System.Threading.AbandonedMutexException] {
    $free = $true
    Write-Log "mutex was abandoned - the previous instance did not exit cleanly"
}
if (-not $free) { Write-Log "already running - watchdog start exits here"; exit }

# Loading WPF costs the better part of a second, so it happens AFTER the guard: the
# autostart task restarts the widget every 15 minutes as a watchdog, and 95 of those 96
# daily starts find a widget already running. They must be as close to free as possible.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
# WinForms comes along only for the notification-area icon — WPF has no tray icon of its
# own. The two frameworks coexist here because the WPF dispatcher already pumps the message
# loop that NotifyIcon needs; nothing else in this widget touches WinForms.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$ProjectsDir = Join-Path $env:USERPROFILE ".claude\projects"
$CoworkVmDir = Join-Path $env:APPDATA "Claude\local-agent-mode-sessions"
$UsageFile   = Join-Path $env:APPDATA "Claude\plan-usage-history.json"
$SessionsDir = Join-Path $env:USERPROFILE ".claude\sessions"
# Chat titles live in two stores: Claude Code chats and Cowork chats. Reading only
# one of them left every chat from the other store nameless.
$TitleDirs   = @(
    (Join-Path $env:APPDATA "Claude\claude-code-sessions"),
    (Join-Path $env:APPDATA "Claude\local-agent-mode-sessions")
)
$PosFile     = Join-Path $env:LOCALAPPDATA "ClaudeContextMeter.pos"
$ModelsFile  = Join-Path $env:LOCALAPPDATA "ClaudeContextMeter.models.json"
$StateFile   = Join-Path $env:LOCALAPPDATA "ClaudeContextMeter.state.json"
# Last-alive marker, rewritten every ~30 s. The heartbeat in the log runs every ten minutes,
# which is fine for spotting a leak but leaves an eleven-minute window around a death — far
# too wide to line up against anything in the Windows event logs. This narrows it to half a
# minute, which is narrow enough to ask "what else happened at that second".
$PulseFile   = Join-Path $env:LOCALAPPDATA "ClaudeContextMeter.alive"
# Nothing on disk states which context window a chat runs on, so the widget decides for
# itself: it remembers the largest prompt it has ever seen per model, and a model caught
# above the small window is filed as large from then on — across restarts. This assumption
# is what it falls back to before any evidence exists.
$DefaultWindow = [long]1000000
$SmallWindow   = [long]200000
$FastMs      = 600      # tick while catching up on history
# Refresh presets. The expensive half is the recursive rescan (~1.3 s over 370 logs), so a
# lighter setting has to stretch BOTH the tick and the rescan — slowing only the tick would
# keep most of the cost and lose the freshness anyway. Picked from the menu, remembered in
# the state file. 'normal' is what the widget has always done.
$RefreshPresets = @(
    @{ Key = 'normal'; Ms = 3000;  Scan = 30  },
    @{ Key = 'easy';   Ms = 10000; Scan = 90  },
    @{ Key = 'low';    Ms = 30000; Scan = 300 }
)
$script:SlowMs       = 3000     # normal tick
$script:ScanEverySec = 30       # full recursive rescan — do it rarely, not per tick
$script:Refresh      = 'normal'
$ActiveMin   = 180      # fallback mode: session is "active" if log written within N minutes
$StaleMin    = 30       # dim the row after N minutes of silence
$MaxRows     = 6
$MinPerSrc   = 2        # seats reserved for each surface (Cowork / Claude Code)
$TickBudget  = 2000000  # max bytes of logs parsed per tick — keeps the UI responsive

$Cache     = @{}   # jsonl path -> state
$PathBySid = @{}   # session id -> jsonl path
$Buckets   = @{}   # 10-min bucket (unixSec/600) -> tokens (input + cache_creation + output)
$TitleCache = @{}  # local_*.json path -> @{MTime; Cid; Title; LastAct; Archived}
$Titles     = @{}  # session id -> chat title
$Meta       = @{}  # session id -> @{Title; LastAct; Archived}
$script:HeavyPending = $false
$script:TickNo = 0
$script:LastScan = $null
$script:RunningIds = @()
$ModelMax = @{}          # model name -> largest prompt ever observed for it
$script:ModelsDirty = $false

function Load-ModelMax {
    if (-not (Test-Path $ModelsFile)) { return }
    try {
        $j = (Get-Content $ModelsFile -Raw) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $ModelMax[$p.Name] = [long]$p.Value }
    } catch {}
}

function Save-ModelMax {
    if (-not $script:ModelsDirty) { return }
    try {
        $o = New-Object PSObject
        foreach ($k in $ModelMax.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $ModelMax[$k] }
        $o | ConvertTo-Json -Compress | Set-Content $ModelsFile -Encoding UTF8
        $script:ModelsDirty = $false
    } catch {}
}

Load-ModelMax
$script:PlanFh = $null
$script:PlanSd = $null

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CcmWin {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
}
"@

# A click used to fire claude://resume?session=<id>. That link is real and the app accepts
# it — but it IMPORTS the CLI transcript as a NEW chat instead of switching to the existing
# one, which is what filled the chat list with untitled duplicates. Verified against the
# app bundle and its log: claude://code/<id> is rejected ("unrecognized code path"), and
# claude://local_sessions/<id> is accepted silently but does not switch chats. Until the app
# exposes a real "focus this session" route, a click only raises the Claude window.
function Open-Chat([string]$sid) {
    Focus-Claude
}

function Focus-Claude {
    try {
        $p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq 'Claude' } | Select-Object -First 1
        if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            # SW_RESTORE (9) only when the window is actually minimised. Sending it
            # unconditionally was a bug: on a MAXIMISED window, restore means "come back
            # down to the previous size", so every click on a row un-maximised the Claude
            # window and it appeared to jump to a different format. Reported 16.08.2026.
            if ([CcmWin]::IsIconic($p.MainWindowHandle)) {
                [CcmWin]::ShowWindowAsync($p.MainWindowHandle, 9) | Out-Null
            }
            [CcmWin]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        }
    } catch {}
}

# ---------- autostart ----------
# Modelled on WinDictoo's autostart.py, including the mistakes it already paid for:
#
#  * ONE mechanism, never two. WinDictoo's installer used to drop a Startup-folder
#    shortcut next to its own Run-key switch, and whoever ticked both got two entries
#    in the Task Manager startup tab. This widget was in exactly that state on 15.08.2026:
#    a Startup shortcut AND a scheduled task, neither of which it knew about.
#  * The registry is the single source of truth. Enabled state is read back from the
#    Run key every time it is needed, never mirrored into a settings file that can drift.
#  * A stale entry is deleted only when its COMMAND also names this widget. A matching
#    value name alone is a coincidence, not evidence — that rule is what keeps this from
#    deleting an unrelated program's autostart.
#  * Missing APPDATA must not fall back to a cwd-relative path: that would resolve to
#    wherever the process happened to be started from.
#
# Why a scheduled task and not the HKCU Run key, which is what this used to be:
# a Run entry fires at logon and never again. This machine is not rebooted — it sleeps and
# wakes, and modern standby is not a logon. Measured on 16.08.2026: the Run entry had been
# in place for 26 hours and had never once executed, because the last logon predated it.
# Docker Desktop and Yandex Disk, also Run entries, were still the instances started at that
# same old logon. So "autostart is configured" and "the widget comes back" were not the same
# statement at all. One task with a logon trigger AND a 15-minute repetition is still ONE
# mechanism, but it also brings the widget back after a crash or a kill, without waiting for
# a reboot that may be weeks away.
$TaskName     = "ClaudeContextMeter"
$RunKey       = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run"
$RunValueName = "ClaudeContextMeter"

# Derived from where this script actually lies, never hard-coded. On 15.08.2026 the widget
# was moved to its own folder and both autostart entries kept pointing at the old path —
# they had the location baked in. Anything built from $PSCommandPath survives the next move.
# Launched through the .vbs whenever it is there. powershell.exe is a console application
# and Windows gives it a console window even though this script only ever shows a WPF
# window; -WindowStyle Hidden hides that console only AFTER it exists, so a black window
# flashes at every logon. WScript.Shell.Run with show = 0 creates it hidden from the start.
# The direct fallback keeps a bare .ps1 working for anyone who copied only that file.
function Get-AutostartLauncher {
    $vbs = Join-Path (Split-Path -Parent $PSCommandPath) 'Start-ContextMeter.vbs'
    if (Test-Path $vbs) {
        return @{ Exe = (Join-Path $env:WINDIR 'System32\wscript.exe'); Args = ('"' + $vbs + '"') }
    }
    return @{
        Exe  = (Join-Path $PSHOME 'powershell.exe')
        Args = ('-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"')
    }
}

function Get-AutostartEnabled {
    try {
        return $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    } catch { return $false }
}

# Returns $null on success or the error text — never throws, so a locked-down machine
# cannot take the whole widget down with it.
function Set-AutostartEnabled([bool]$enabled) {
    try {
        if ($enabled) {
            $l = Get-AutostartLauncher
            $act = New-ScheduledTaskAction -Execute $l.Exe -Argument $l.Args
            # At logon, once. There was briefly a 15-minute repetition here as a watchdog,
            # and it was the wrong answer twice over: a widget that is restarted every
            # quarter of an hour hides the defect that killed it, and it shoulders its way
            # back onto the screen on days when Claude is not even running. If the widget
            # dies, that is a bug to find, not a thing to paper over.
            $trg = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                        -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
            $prn = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $trg -Settings $set -Principal $prn -Force -ErrorAction Stop | Out-Null
            Write-Log "autostart task registered -> $PSCommandPath"
        } else {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Log "autostart task removed"
        }
        return $null
    } catch { return $_.Exception.Message }
}

# The task carries an absolute path, so it goes stale the moment the folder moves.
# Re-register silently when it no longer matches — but only while autostart is switched on,
# so this never turns it back on behind the user's back.
function Sync-AutostartPath {
    if (-not (Get-AutostartEnabled)) { return }
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $act = $task.Actions | Select-Object -First 1
        $l = Get-AutostartLauncher
        if ($act.Arguments -ne $l.Args -or $act.Execute -ne $l.Exe) {
            $e = Set-AutostartEnabled $true; if ($e) { Write-Log "autostart could not be enabled: $e" }
            Write-Log "autostart path updated"
        }
    } catch {}
}

function Load-State {
    if (-not (Test-Path $StateFile)) { return @{} }
    try {
        $h = @{}
        $j = (Get-Content $StateFile -Raw) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    } catch { return @{} }
}

function Save-State($h) {
    try {
        $o = New-Object PSObject
        foreach ($k in $h.Keys) { $o | Add-Member -NotePropertyName $k -NotePropertyValue $h[$k] }
        $o | ConvertTo-Json -Compress | Set-Content $StateFile -Encoding UTF8
    } catch {}
}

# One-shot migration off the two external mechanisms this widget used to be started by.
# Order matters: take over FIRST, remove SECOND. Removing first would leave the machine
# with no autostart at all if writing the Run key failed. Guarded by a flag rather than
# run forever, because it only ever matters on a machine set up before this existed.
function Invoke-AutostartMigration {
    $state = Load-State
    if ($state['autostartTaskMigrated']) { return }

    $found = $false

    # 1. Startup-folder shortcut - only if its command actually names this widget.
    if ($env:APPDATA) {
        $lnk = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\ClaudeContextMeter.lnk"
        if (Test-Path $lnk) {
            try {
                $sh = New-Object -ComObject WScript.Shell
                $sc = $sh.CreateShortcut($lnk)
                if ($sc.Arguments -like '*ClaudeContextMeter.ps1*') {
                    $found = $true
                    if (-not (Get-AutostartEnabled)) { $e = Set-AutostartEnabled $true; if ($e) { Write-Log "autostart could not be enabled: $e" } }
                    if (Get-AutostartEnabled) {
                        Remove-Item $lnk -Force -ErrorAction SilentlyContinue
                        Write-Log "legacy startup shortcut removed"
                    }
                }
            } catch {}
        }
    }

    # 2. Run-key entry - same evidence rule. This is the mechanism the widget itself used
    #    until 16.08.2026; it is removed only once the task has taken over, so a machine is
    #    never left with no autostart at all because one half of the swap failed.
    try {
        $cur = (Get-ItemProperty -Path $RunKey -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
        if ($cur -and $cur -like '*ClaudeContextMeter.ps1*') {
            $found = $true
            if (-not (Get-AutostartEnabled)) { $e = Set-AutostartEnabled $true; if ($e) { Write-Log "autostart could not be enabled: $e" } }
            if (Get-AutostartEnabled) {
                Remove-ItemProperty -Path $RunKey -Name $RunValueName -ErrorAction SilentlyContinue
                Write-Log "legacy Run-key entry removed"
            }
        }
    } catch {}

    # Only close the migration once nothing legacy is left; otherwise retry next launch.
    if (-not $found -or (Get-AutostartEnabled)) {
        $state['autostartTaskMigrated'] = $true
        Save-State $state
    }
}

# ---------- updates ----------
# Modelled on WinDictoo's update.py and oldversions.py, which between them encode four
# lessons this widget would otherwise have to learn the same way:
#
#  * An update check must NEVER break the start. Offline, rate-limited, no release, no
#    asset, garbage JSON — every one of them ends as "no update", not as an exception.
#  * Compare versions as numbers, not as text: "1.10.0" is newer than "1.9.0" and string
#    comparison says the opposite. Anything unparseable means no update rather than a guess.
#  * A release without an installer asset is not an update. Offering one would send the user
#    to a page with nothing on it.
#  * Old installs do not clean themselves up. Each rename of WinDictoo used a fresh Inno
#    AppId so the previous uninstaller kept working — and nothing ever ran it, so upgraded
#    machines collected two or three Start Menu entries. The list below is the hook for
#    that; it is empty because this project has not been renamed, and the current AppId
#    must never be added to it.
#
# The check also breaks the "no network at all" promise this widget used to make, so it is
# a setting, it is stated in the README, and it talks to exactly one host: api.github.com.
$Version   = '1.2.1'
$Repo      = 'nowoandi/claude-context-meter'
$OldAppIds = @()   # @( @{ Name = 'FormerName'; AppId = '{GUID}' } )

$script:UpdateInfo   = $null
$script:UpdatePS     = $null
$script:UpdateHandle = $null

function Test-NewerVersion([string]$remote, [string]$current) {
    try {
        $r = ($remote  -replace '^[vV]','').Split('.') | ForEach-Object { [int]$_ }
        $c = ($current -replace '^[vV]','').Split('.') | ForEach-Object { [int]$_ }
    } catch { return $false }
    for ($i = 0; $i -lt [Math]::Max($r.Count, $c.Count); $i++) {
        $rv = if ($i -lt $r.Count) { $r[$i] } else { 0 }
        $cv = if ($i -lt $c.Count) { $c[$i] } else { 0 }
        if ($rv -gt $cv) { return $true }
        if ($rv -lt $cv) { return $false }
    }
    return $false
}

# Runs in its own runspace: a six-second wait on a rate-limited API must not freeze a
# widget whose whole job is to redraw every few seconds.
function Start-UpdateCheck {
    if (-not $script:CheckUpdates -or $script:UpdatePS) { return }
    try {
        $script:UpdatePS = [PowerShell]::Create()
        [void]$script:UpdatePS.AddScript({
            param($repo)
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $r = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
                        -Headers @{ 'User-Agent' = 'ClaudeContextMeter' } -TimeoutSec 8
                $asset = @($r.assets | Where-Object { $_.name -like '*.exe' })[0]
                if (-not $asset) { return }
                [PSCustomObject]@{
                    Version = ($r.tag_name -replace '^[vV]','')
                    Url     = $asset.browser_download_url
                    Page    = $r.html_url
                }
            } catch { }
        }).AddArgument($Repo)
        $script:UpdateHandle = $script:UpdatePS.BeginInvoke()
    } catch { $script:UpdatePS = $null }
}

function Complete-UpdateCheck {
    if (-not $script:UpdateHandle -or -not $script:UpdateHandle.IsCompleted) { return }
    try {
        $res = @($script:UpdatePS.EndInvoke($script:UpdateHandle))[0]
        if ($res -and (Test-NewerVersion $res.Version $Version)) {
            $script:UpdateInfo = $res
            Write-Log ("update available: {0} (running {1})" -f $res.Version, $Version)
            # An update buried in a menu nobody opens is the same as no update at all, so
            # it gets a visible mark on the widget itself and in the tray tooltip. One
            # arrow, in the accent colour, that installs when clicked.
            try {
                $UpdBtn.ToolTip = ((T 'menu.update') -f $res.Version)
                $UpdBtn.Visibility = 'Visible'
                $tray.Text = ((T 'menu.update') -f $res.Version)
            } catch { }
        }
    } catch { }
    try { $script:UpdatePS.Dispose() } catch { }
    $script:UpdatePS = $null
    $script:UpdateHandle = $null
}

# Download, then hand over to the installer and step aside. The installer knows this widget
# is running because it shares the single-instance mutex, so it asks for it to be closed
# rather than writing over a file in use.
function Install-Update {
    if (-not $script:UpdateInfo) { return }
    $info = $script:UpdateInfo
    try {
        $dest = Join-Path $env:TEMP ("ClaudeContextMeter-{0}-setup.exe" -f $info.Version)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $info.Url -OutFile $dest -UseBasicParsing -TimeoutSec 180
        Write-Log "update downloaded to $dest - starting installer"
        Start-Process -FilePath $dest
        # Step aside. Left running, the widget forces the installer to close it through the
        # Restart Manager, and that is where the extra prompts and "file in use" failures
        # come from - reported on 19.08.2026 as "it said it could not install". Closing
        # ourselves means the installer finds nothing to close. It offers to start the
        # widget again when it finishes, and autostart brings it back at the next logon
        # either way.
        Write-Log "closing so the installer can replace the files"
        Exit-Widget
    } catch {
        Write-Log ("update download failed: " + $_.Exception.Message)
        try { Start-Process $info.Page } catch { }
    }
}

# The counterpart to WinDictoo's oldversions.py. A no-op today, and deliberately so: the
# mechanism has to exist before the rename that needs it, because after the rename the new
# build is the only thing that could clean up — and it would have to know what to look for.
function Remove-OldInstalls {
    foreach ($old in $OldAppIds) {
        try {
            $key = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\$($old.AppId)_is1"
            $u = (Get-ItemProperty -Path $key -Name UninstallString -ErrorAction Stop).UninstallString
            if ($u) {
                $exe = $u.Trim('"')
                Start-Process -FilePath $exe -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -ErrorAction Stop
                Write-Log "removing leftover install of $($old.Name)"
            }
        } catch { }
    }
}

# ---------- interface language ----------
# Same shape as WinDictoo's i18n.py: one table keyed by "namespace.key", one entry per
# language, a single current-language variable, and a fallback to the default whenever a
# key or a language is missing — a missing translation must degrade to readable text,
# never to an empty label. Picker entries carry their own native names, so the list stays
# readable no matter which language is active.
$UiLangs   = @( @{ Code = 'en'; Name = 'English' }, @{ Code = 'de'; Name = 'Deutsch' }, @{ Code = 'ru'; Name = 'Русский' } )
$DefaultLang = 'en'
$script:Lang = $DefaultLang

$Strings = @{
    'hdr.chats'       = @{ ru = 'Чаты Claude';        de = 'Claude-Chats'; en = 'Claude chats' }
    'sum.5h'          = @{ ru = 'токены за 5 часов';  de = 'Tokens · letzte 5 Stunden'; en = 'tokens · last 5 hours' }
    'sum.7d'          = @{ ru = 'токены за 7 дней';   de = 'Tokens · letzte 7 Tage'; en = 'tokens · last 7 days' }
    'sum.limit'       = @{ ru = 'лимит';              de = 'Limit'; en = 'limit' }
    'note.loading'    = @{ ru = 'догружаю историю…';  de = 'Verlauf wird geladen…'; en = 'loading history…' }
    'row.scanning'    = @{ ru = 'сканирую сессии…';   de = 'Sitzungen werden gesucht…'; en = 'scanning sessions…' }
    'row.none'        = @{ ru = 'нет активных сессий'; de = 'keine aktiven Sitzungen'; en = 'no active sessions' }
    'tip.noctx'       = @{ ru = 'контекст неизвестен (лог недоступен)'; de = 'Kontext unbekannt (Protokoll nicht lesbar)'; en = 'context unknown (log unavailable)' }
    'tip.tokens'      = @{ ru = 'токенов';            de = 'Tokens'; en = 'tokens' }
    'tip.model'       = @{ ru = 'модель';             de = 'Modell'; en = 'model' }
    'tip.activity'    = @{ ru = 'активность {0} мин назад'; de = 'aktiv vor {0} Min.'; en = 'active {0} min ago' }
    'tip.click'       = @{ ru = 'клик — показать окно Claude'; de = 'Klick — Claude in den Vordergrund'; en = 'click — bring Claude to front' }
    'menu.autostart'  = @{ ru = 'Запускать при входе в систему'; de = 'Bei der Anmeldung starten'; en = 'Start at login' }
    'menu.language'   = @{ ru = 'Язык';               de = 'Sprache'; en = 'Language' }
    'menu.refresh'    = @{ ru = 'Частота обновления'; de = 'Aktualisierungsrate'; en = 'Refresh rate' }
    'menu.rememberpos'= @{ ru = 'Запоминать положение'; de = 'Position merken'; en = 'Remember position' }
    'menu.updates'    = @{ ru = 'Проверять обновления'; de = 'Nach Updates suchen'; en = 'Check for updates' }
    'menu.update'     = @{ ru = 'Обновить до {0}';      de = 'Auf {0} aktualisieren'; en = 'Update to {0}' }
    'refresh.normal'  = @{ ru = 'Обычная';            de = 'Normal'; en = 'Normal' }
    'refresh.easy'    = @{ ru = 'Экономная';          de = 'Sparsam'; en = 'Easy' }
    'refresh.low'     = @{ ru = 'Минимальная';        de = 'Minimal'; en = 'Minimal' }
    'menu.close'      = @{ ru = 'Скрыть';             de = 'Ausblenden'; en = 'Hide' }
    'menu.show'       = @{ ru = 'Показать';           de = 'Anzeigen'; en = 'Show' }
    'menu.exit'       = @{ ru = 'Выйти';              de = 'Beenden'; en = 'Exit' }
}

function T([string]$key) {
    $e = $Strings[$key]
    if (-not $e) { return $key }
    if ($e.ContainsKey($script:Lang) -and $e[$script:Lang]) { return $e[$script:Lang] }
    return $e[$DefaultLang]
}

function Update-PlanUsage {
    try {
        $fs = [System.IO.File]::Open($UsageFile, 'Open', 'Read', 'ReadWrite')
        try {
            $take = [Math]::Min(4096, $fs.Length)
            $fs.Seek(-$take, 'End') | Out-Null
            $b = New-Object byte[] ([int]$take)
            $n = $fs.Read($b, 0, [int]$take)
            $txt = [System.Text.Encoding]::UTF8.GetString($b, 0, $n)
        } finally { $fs.Close() }
        $ms = [regex]::Matches($txt, '"u":\{"fh":(\d+),"sd":(\d+)')
        if ($ms.Count -gt 0) {
            $m = $ms[$ms.Count - 1]
            $script:PlanFh = [int]$m.Groups[1].Value
            $script:PlanSd = [int]$m.Groups[2].Value
        }
    } catch {}
}

$reTs    = [regex]'"timestamp":"([^"]+)"'
$reUse   = [regex]'"usage":\{"input_tokens":(\d+),"cache_creation_input_tokens":(\d+),"cache_read_input_tokens":(\d+),"output_tokens":(\d+)'
$reCwd   = [regex]'"cwd":"([^"]+)"'
$reModel = [regex]'"model":"([^"]+)"'
# The two stores are written differently: Claude Code records are compact JSON,
# Cowork records are pretty-printed with spaces after the colon. Matching only the
# compact form silently skipped every Cowork chat, so none of them ever appeared.
$reCid   = [regex]'"cliSessionId"\s*:\s*"([0-9a-fA-F-]{36})"'
$reRecMod = [regex]'"model"\s*:\s*"([^"]+)"'   # model as written in the chat record — carries the [1m] marker
$reTitle = [regex]'"title"\s*:\s*"((?:\\.|[^"\\])*)"'
$rePid   = [regex]'"pid"\s*:\s*(\d+)'
$reSid   = [regex]'"sessionId"\s*:\s*"([0-9a-fA-F-]{36})"'
$reAct   = [regex]'"lastActivityAt"\s*:\s*(\d+)'
$reArch  = [regex]'"isArchived"\s*:\s*(true|false)'
$reProc  = [regex]'"processName"\s*:\s*"([^"]+)"'
$reGuid  = [regex]'([0-9a-fA-F-]{36})\.jsonl$'

# Decides the window without asking anyone. Order matters: hard evidence first, then what
# the widget has learned about this model, then the standing assumption.
function Get-ContextWindow([string]$model, [long]$observed) {
    # 1. Proof from this very chat — a prompt above the small window can only exist on a large one.
    if ($observed -gt $SmallWindow) { return [long]1000000 }
    # 2. The explicit marker, when the record happens to carry it.
    if ($model -match '\[1m\]') { return [long]1000000 }
    # 3. What this model has been caught doing before, remembered across restarts.
    $bare = ($model -replace '\[1m\]', '')
    foreach ($k in @($model, $bare)) {
        if ($k -and $ModelMax.ContainsKey($k) -and $ModelMax[$k] -gt $SmallWindow) { return [long]1000000 }
    }
    # 4. No evidence either way — fall back to the assumption.
    return $DefaultWindow
}

function Note-ModelMax([string]$model, [long]$ctx) {
    if (-not $model -or $ctx -le 0) { return }
    $k = ($model -replace '\[1m\]', '')
    $prev = [long]0
    if ($ModelMax.ContainsKey($k)) { $prev = $ModelMax[$k] }
    if ($ctx -gt $prev) { $ModelMax[$k] = $ctx; $script:ModelsDirty = $true }
}

# The context window as a badge, not a sentence: "1M", "0.2M". The row already shows how
# full the window is; without this the percentage said nothing about what it is a percentage
# OF — 80% of 200k and 80% of 1M are different situations.
function Format-Window([long]$w) {
    if ($w -le 0) { return "" }
    $m = $w / 1000000.0
    if ($m -ge 1) { return ("{0:N0}M" -f $m) }
    return ("{0:N1}M" -f $m)
}

function Format-Tokens([long]$n) {
    if ($n -ge 1000000) { return ("{0:N1}M" -f ($n / 1000000.0)) }
    if ($n -ge 1000)    { return ("{0:N1}k" -f ($n / 1000.0)) }
    return "$n"
}

# Parse up to $maxBytes of new log data; returns bytes consumed.
function Parse-File([string]$path, [long]$maxBytes) {
    $st = $Cache[$path]
    $consumed = [long]0
    try {
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -lt $st.Offset) { $st.Offset = $fs.Length; return 0 }
            $backlog = $fs.Length - $st.Offset
            if ($backlog -le 0) { return 0 }
            $take = [long][Math]::Min($backlog, [Math]::Max($maxBytes, 65536))
            $text = $null
            while ($true) {
                $fs.Seek($st.Offset, 'Begin') | Out-Null
                $buf = New-Object byte[] ([int]$take)
                $n = $fs.Read($buf, 0, [int]$take)
                $lastNl = -1
                for ($i = $n - 1; $i -ge 0; $i--) { if ($buf[$i] -eq 10) { $lastNl = $i; break } }
                if ($lastNl -ge 0) {
                    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $lastNl + 1)
                    $consumed = $lastNl + 1
                    break
                }
                if ($take -ge $backlog -or $take -ge 16000000) { return 0 }   # incomplete line, wait for more
                $take = [Math]::Min($backlog, $take * 4)
            }
        } finally { $fs.Close() }
    } catch { return 0 }

    $st.Offset = $st.Offset + $consumed

    foreach ($line in $text.Split("`n")) {
        if ($line.Length -lt 20) { continue }
        if (-not $st.Cwd) {
            $mc = $reCwd.Match($line)
            if ($mc.Success) { $st.Cwd = $mc.Groups[1].Value.Replace('\\', '\') }
        }
        if ($line.IndexOf('"usage":{') -lt 0) { continue }
        if ($line.IndexOf('"role":"assistant"') -lt 0) { continue }
        $mu = $reUse.Match($line)
        if (-not $mu.Success) { continue }
        $inTok = [long]$mu.Groups[1].Value
        $cc    = [long]$mu.Groups[2].Value
        $cr    = [long]$mu.Groups[3].Value
        $out   = [long]$mu.Groups[4].Value

        $mt = $reTs.Match($line)
        if (-not $mt.Success) { continue }
        try { $dto = [DateTimeOffset]::Parse($mt.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture) } catch { continue }

        $key = [long][Math]::Floor($dto.ToUnixTimeSeconds() / 600)
        $fresh = $inTok + $cc + $out
        if ($Buckets.ContainsKey($key)) { $Buckets[$key] = $Buckets[$key] + $fresh } else { $Buckets[$key] = $fresh }

        if (-not $st.IsAgent -and $line.IndexOf('"isSidechain":true') -lt 0) {
            # Prompt size only. output_tokens is the reply — it lands in the NEXT request,
            # so counting it here overstated every row against the figure the app shows.
            $ctx = $inTok + $cc + $cr
            if ($ctx -gt 0) {
                $st.LastCtx = $ctx
                $mm = $reModel.Match($line)
                if ($mm.Success) { $st.Model = $mm.Groups[1].Value }
                # Every prompt is a data point about what this model is allowed to hold.
                Note-ModelMax $st.Model $ctx
            }
        }
    }
    return $consumed
}

function Scan-Files {
    # The recursive enumeration below costs ~1.3 s on this machine (370 logs, 133 MB).
    # Running it every tick meant the widget spent more time listing files than the tick
    # interval itself — that was the lag. Enumerate rarely; between times just re-stat the
    # handful of logs that can actually have grown.
    $now = Get-Date
    if ($script:LastScan -and ($now - $script:LastScan).TotalSeconds -lt $script:ScanEverySec) {
        $warm = $now.AddHours(-24)
        foreach ($st in $Cache.Values) {
            if ($st.File.LastWriteTime -lt $warm -and $st.File.Length -le $st.Offset) { continue }
            try { $st.File.Refresh() } catch {}
        }
        return
    }
    $script:LastScan = $now

    $cut = (Get-Date).AddDays(-7)
    $files = @()
    foreach ($root in @($ProjectsDir, $CoworkVmDir)) {
        if (Test-Path $root) {
            $files += Get-ChildItem $root -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $cut -and $_.Name -ne 'audit.jsonl' }
        }
    }
    foreach ($f in $files) {
        if (-not $Cache.ContainsKey($f.FullName)) {
            $Cache[$f.FullName] = @{
                Offset  = [long]0
                IsAgent = ($f.FullName -match '\\subagents\\')
                LastCtx = [long]0
                Model   = ''
                Cwd     = $null
                File    = $f
            }
            if ($f.FullName -notmatch '\\subagents\\') {
                $mg = $reGuid.Match($f.Name)
                if ($mg.Success) { $PathBySid[$mg.Groups[1].Value] = $f.FullName }
            }
        } else {
            $Cache[$f.FullName].File = $f
        }
    }
}

function Update-Titles {
    $files = @()
    foreach ($d in $TitleDirs) {
        if (Test-Path $d) {
            $files += Get-ChildItem $d -Recurse -Filter "local_*.json" -ErrorAction SilentlyContinue
        }
    }
    foreach ($f in $files) {
        $tc = $TitleCache[$f.FullName]
        if ($tc -and $tc.MTime -eq $f.LastWriteTimeUtc) { continue }
        try { $txt = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        $mc = $reCid.Match($txt); $mt = $reTitle.Match($txt)
        $src = if ($f.FullName -like "*local-agent-mode-sessions*") { "Cowork" } else { "Code" }
        $entry = @{ MTime = $f.LastWriteTimeUtc; Cid = $null; Title = $null; LastAct = [datetime]::MinValue; Archived = $false; Src = $src }
        # Cowork chats without a title still have a readable process name — better than a hex stub.
        $mpn = $reProc.Match($txt)
        if ($mpn.Success) { $entry.Proc = $mpn.Groups[1].Value }
        $mrm = $reRecMod.Match($txt)
        if ($mrm.Success) { $entry.Model = $mrm.Groups[1].Value }
        # A chat with no title yet is still a chat — keep it, just without a name.
        # Requiring a title here used to drop those rows entirely.
        if ($mc.Success) {
            $entry.Cid = $mc.Groups[1].Value
            if ($mt.Success) {
                $t = $mt.Groups[1].Value
                if ($t.IndexOf('\') -ge 0) { try { $t = [regex]::Unescape($t) } catch {} }
                if ($t) { $entry.Title = $t }
            }
            $ma = $reAct.Match($txt)
            if ($ma.Success) { try { $entry.LastAct = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ma.Groups[1].Value).LocalDateTime } catch {} }
            $mr = $reArch.Match($txt)
            if ($mr.Success -and $mr.Groups[1].Value -eq 'true') { $entry.Archived = $true }
        }
        $TitleCache[$f.FullName] = $entry
    }
    $Titles.Clear(); $Meta.Clear()
    foreach ($v in $TitleCache.Values) {
        if (-not $v.Cid) { continue }
        if ($v.Title) { $Titles[$v.Cid] = $v.Title }
        elseif ($v.Proc) { $Titles[$v.Cid] = $v.Proc }
        # Keep the newest record when a chat appears in both stores.
        $prev = $Meta[$v.Cid]
        if ($prev -and $prev.LastAct -gt $v.LastAct) { continue }
        $Meta[$v.Cid] = @{ Title = $v.Title; LastAct = $v.LastAct; Archived = $v.Archived; Src = $v.Src; Model = $v.Model }
    }
}

function Get-RunningSessionIds {
    $ids = @()
    if (-not (Test-Path $SessionsDir)) { return $ids }
    foreach ($f in Get-ChildItem $SessionsDir -Filter *.json -ErrorAction SilentlyContinue) {
        try { $txt = [System.IO.File]::ReadAllText($f.FullName) } catch { continue }
        $mp = $rePid.Match($txt); $ms = $reSid.Match($txt)
        if (-not ($mp.Success -and $ms.Success)) { continue }
        $procId = [int]$mp.Groups[1].Value
        $alive = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($alive) { $ids += $ms.Groups[1].Value }
    }
    return @($ids | Select-Object -Unique)
}

# ---------- UI ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Context" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize">
  <Border CornerRadius="10" Background="#EE14181F" BorderBrush="#2B3340" BorderThickness="1" Padding="12,8,10,9">
    <StackPanel Width="288">
      <Grid>
        <TextBlock x:Name="HdrLbl" Text="Чаты Claude" Foreground="#B4BECD" FontSize="11" FontFamily="Segoe UI" HorizontalAlignment="Left"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <TextBlock x:Name="UpdBtn" Text="↓" Foreground="#7DDE72" FontSize="13" FontWeight="Bold" FontFamily="Segoe UI" Cursor="Hand" Margin="0,0,9,0" Visibility="Collapsed"/>
          <TextBlock x:Name="MenuBtn" Text="⚙" Foreground="#8792A3" FontSize="12" FontFamily="Segoe UI Symbol" Cursor="Hand" Margin="0,0,9,0"/>
          <TextBlock x:Name="CloseBtn" Text="✕" Foreground="#8792A3" FontSize="12" Cursor="Hand"/>
        </StackPanel>
      </Grid>
      <StackPanel x:Name="RowsPanel" Margin="0,7,0,0"/>
      <Border Height="1" Background="#2B3340" Margin="0,7,0,7"/>
      <Grid>
        <TextBlock x:Name="Lbl5" Text="токены за 5 часов" Foreground="#B4BECD" FontSize="11" FontFamily="Segoe UI" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Sum5" Text="—" Foreground="#F5F2EA" FontSize="12" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Right"/>
      </Grid>
      <Grid Margin="0,3,0,0">
        <TextBlock x:Name="Lbl7" Text="токены за 7 дней" Foreground="#B4BECD" FontSize="11" FontFamily="Segoe UI" HorizontalAlignment="Left"/>
        <TextBlock x:Name="Sum7" Text="—" Foreground="#F5F2EA" FontSize="12" FontWeight="Bold" FontFamily="Segoe UI" HorizontalAlignment="Right"/>
      </Grid>
      <TextBlock x:Name="LoadNote" Text="догружаю историю…" Foreground="#8792A3" FontSize="10" FontStyle="Italic"
                 FontFamily="Segoe UI" Margin="0,5,0,0" Visibility="Collapsed"/>
    </StackPanel>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

# An exception thrown inside a WPF event handler tears the whole application down, and the
# PowerShell trap above never sees it — the process is simply gone. That is the shape of a
# widget that "disappears now and then": a click or a menu action lands on a bad state once
# an hour and takes everything with it. Logged and swallowed instead: one broken click is
# not a reason to lose the widget. The AppDomain handler below catches what is left, so
# even a genuinely fatal end leaves a line behind.
$window.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-Log ("DISPATCHER: " + $e.Exception.ToString())
    $e.Handled = $true
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    Write-Log ("FATAL: " + $e.ExceptionObject.ToString())
})

# Windows tells applications when the session is ending, when it is locked or switched, and
# when the machine suspends or resumes. Two disappearances left no exception, no crash
# record and flat memory, which points away from the widget failing and towards something
# ending it. If any of these fire just before the log goes quiet, that is the answer;
# if the log stops without one, the cause is outside Windows' own notifications and the
# search moves on. Recording them costs nothing and rules out a whole family of theories.
try {
    [Microsoft.Win32.SystemEvents]::add_SessionEnding({ param($s, $e) Write-Log ("SYSTEM: session ending, reason " + $e.Reason) })
    [Microsoft.Win32.SystemEvents]::add_SessionEnded({  param($s, $e) Write-Log ("SYSTEM: session ended, reason " + $e.Reason) })
    [Microsoft.Win32.SystemEvents]::add_SessionSwitch({ param($s, $e) Write-Log ("SYSTEM: session switch, " + $e.Reason) })
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged({ param($s, $e) Write-Log ("SYSTEM: power mode " + $e.Mode) })
    [Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged({ Write-Log "SYSTEM: display settings changed" })
} catch { Write-Log ("could not subscribe to system events: " + $_.Exception.Message) }

# Fires when something asks WPF to shut down, which separates "an orderly shutdown was
# requested" from "the process was terminated under it".
$window.Dispatcher.Add_ShutdownStarted({ Write-Log "dispatcher shutdown started" })

$RowsPanel = $window.FindName("RowsPanel")
$Sum5      = $window.FindName("Sum5")
$Sum7      = $window.FindName("Sum7")
$LoadNote  = $window.FindName("LoadNote")
$CloseBtn  = $window.FindName("CloseBtn")
$MenuBtn   = $window.FindName("MenuBtn")
$UpdBtn    = $window.FindName("UpdBtn")
$HdrLbl    = $window.FindName("HdrLbl")
$Lbl5      = $window.FindName("Lbl5")
$Lbl7      = $window.FindName("Lbl7")

# Remembered across restarts, like the window position. An unknown code falls back to the
# default rather than leaving every label empty.
$script:State = Load-State
if ($script:State['lang'] -and ($UiLangs.Code -contains $script:State['lang'])) {
    $script:Lang = $script:State['lang']
}
# On by default: putting the widget where you want it and finding it there is the expected
# behaviour, not a feature to opt into.
$script:RememberPos = $true
if ($script:State.ContainsKey('rememberPos')) { $script:RememberPos = [bool]$script:State['rememberPos'] }
# On by default, but switchable and stated in the README: this is the one thing the widget
# does that leaves the machine at all.
$script:CheckUpdates = $true
if ($script:State.ContainsKey('checkUpdates')) { $script:CheckUpdates = [bool]$script:State['checkUpdates'] }

# Written whenever the window is moved, not only when it is closed. Saving on exit alone
# meant a widget that was killed rather than closed — which is exactly how this one kept
# disappearing — lost its position every time and came back in the default corner.
function Save-Position {
    if (-not $script:RememberPos) { return }
    try { "$($window.Left),$($window.Top)" | Set-Content $PosFile } catch {}
}

# Settings live behind the gear and on right-click — 258 px has no room for a settings
# window, and there are only two settings. Every label the widget draws once at startup is
# re-applied here, so switching the language repaints without a restart; the rows and the
# footer carry their own T() calls and refresh on the next tick anyway.
$menu = New-Object Windows.Controls.ContextMenu
$miAuto = New-Object Windows.Controls.MenuItem
$miAuto.IsCheckable = $true
$miLang = New-Object Windows.Controls.MenuItem
$miRefresh = New-Object Windows.Controls.MenuItem
$miPos = New-Object Windows.Controls.MenuItem
$miPos.IsCheckable = $true
$miUpd = New-Object Windows.Controls.MenuItem
$miUpd.IsCheckable = $true
# Only appears once there is something to install — a permanently greyed "no updates" line
# is noise in a menu this small.
$miDoUpd = New-Object Windows.Controls.MenuItem
$miDoUpd.Visibility = 'Collapsed'
$miClose = New-Object Windows.Controls.MenuItem

function Apply-Refresh([string]$key) {
    $p = $RefreshPresets | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if (-not $p) { $p = $RefreshPresets[0] }
    $script:Refresh      = $p.Key
    $script:SlowMs       = $p.Ms
    $script:ScanEverySec = $p.Scan
    # Only touch the timer when it is idling at the slow rate; while catching up on history
    # it runs at $FastMs and the next tick sets the interval itself anyway.
    if ($timer -and $timer.Interval.TotalMilliseconds -gt $FastMs) {
        $timer.Interval = [TimeSpan]::FromMilliseconds($script:SlowMs)
    }
    foreach ($it in $miRefresh.Items) { $it.IsChecked = ($it.Tag -eq $script:Refresh) }
    Write-Log ("refresh set to {0} (tick {1} ms, rescan {2} s)" -f $p.Key, $p.Ms, $p.Scan)
}

function Apply-Language {
    $HdrLbl.Text   = T 'hdr.chats'
    $Lbl5.Text     = T 'sum.5h'
    $Lbl7.Text     = T 'sum.7d'
    $LoadNote.Text = T 'note.loading'
    $miAuto.Header    = T 'menu.autostart'
    $miLang.Header    = T 'menu.language'
    $miRefresh.Header = T 'menu.refresh'
    $miPos.Header     = T 'menu.rememberpos'
    $miUpd.Header     = T 'menu.updates'
    $miClose.Header   = T 'menu.close'
    foreach ($it in $miLang.Items) { $it.IsChecked = ($it.Tag -eq $script:Lang) }
    foreach ($it in $miRefresh.Items) { $it.Header = T ('refresh.' + $it.Tag) }
    # The tray menu carries the same settings and must follow the same language.
    if ($tiAuto) {
        $tiAuto.Text    = T 'menu.autostart'
        $tiLang.Text    = T 'menu.language'
        $tiRefresh.Text = T 'menu.refresh'
        $tiPos.Text     = T 'menu.rememberpos'
        $tiUpd.Text     = T 'menu.updates'
        $tiExit.Text    = T 'menu.exit'
        $tiShow.Text    = T 'menu.show'
        foreach ($it in $tiRefresh.DropDownItems) { $it.Text = T ('refresh.' + $it.Tag) }
    }
}

# Which version is running has to be readable without hunting for a file, so it heads the
# menu, greyed out, and repeats in the tray tooltip.
$miVer = New-Object Windows.Controls.MenuItem
$miVer.Header = "Claude Context Meter $Version"
$miVer.IsEnabled = $false
$menu.Items.Add($miVer) | Out-Null
$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null

$miAuto.Add_Click({
    $err = Set-AutostartEnabled ([bool]$miAuto.IsChecked)
    # Put the tick back where reality is, not where the click left it.
    $miAuto.IsChecked = Get-AutostartEnabled
    if ($err) { Write-Log "autostart change failed: $err" }
}.GetNewClosure())
$menu.Items.Add($miAuto) | Out-Null

foreach ($l in $UiLangs) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $l.Name          # native name, readable whichever language is active
    $mi.Tag = $l.Code
    $mi.IsCheckable = $true
    $mi.Add_Click({
        param($s, $e)
        $script:Lang = $s.Tag
        $script:State['lang'] = $s.Tag
        Save-State $script:State
        Apply-Language
    })
    $miLang.Items.Add($mi) | Out-Null
}
$menu.Items.Add($miLang) | Out-Null

foreach ($r in $RefreshPresets) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Tag = $r.Key
    $mi.IsCheckable = $true
    $mi.Add_Click({
        param($s, $e)
        Apply-Refresh $s.Tag
        $script:State['refresh'] = $s.Tag
        Save-State $script:State
    })
    $miRefresh.Items.Add($mi) | Out-Null
}
$menu.Items.Add($miRefresh) | Out-Null

$miUpd.Add_Click({
    $script:CheckUpdates = [bool]$miUpd.IsChecked
    $script:State['checkUpdates'] = $script:CheckUpdates
    Save-State $script:State
    if ($script:CheckUpdates) { Start-UpdateCheck }
}.GetNewClosure())
$menu.Items.Add($miUpd) | Out-Null

$miDoUpd.Add_Click({ Install-Update }.GetNewClosure())
$menu.Items.Add($miDoUpd) | Out-Null

$miPos.Add_Click({
    $script:RememberPos = [bool]$miPos.IsChecked
    $script:State['rememberPos'] = $script:RememberPos
    Save-State $script:State
    # Switching it back on should keep where the widget is standing right now, not whatever
    # stale position happened to be left in the file.
    if ($script:RememberPos) { Save-Position }
}.GetNewClosure())
$menu.Items.Add($miPos) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
$miClose.Add_Click({ Hide-Widget }.GetNewClosure())
$menu.Items.Add($miClose) | Out-Null

# Read the tick from the registry every time the menu opens, never from a remembered
# variable: an entry removed from outside would otherwise still show as ticked.
$menu.Add_Opened({
    $miAuto.IsChecked = Get-AutostartEnabled
    $miPos.IsChecked = $script:RememberPos
    $miUpd.IsChecked = $script:CheckUpdates
    if ($script:UpdateInfo) {
        $miDoUpd.Header = (T 'menu.update') -f $script:UpdateInfo.Version
        $miDoUpd.Visibility = 'Visible'
    } else {
        $miDoUpd.Visibility = 'Collapsed'
    }
}.GetNewClosure())
$window.ContextMenu = $menu

# ---------- notification area ----------
# Until now there was nothing anywhere saying the widget was running or set to start at
# login, and the close button ended the process — so "closed" and "gone until I launch it
# again" were the same thing. The tray icon is both the missing indicator and the way back:
# the cross now hides the window, and only Exit here really ends it.
function Show-Widget {
    $window.Show()
    $window.Topmost = $true
    $window.Activate()
}
function Hide-Widget {
    Save-Position
    $window.Hide()
}
function Exit-Widget {
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    $window.Close()
    # Closing no longer ends the process on its own now that the message loop is explicit.
    try { $window.Dispatcher.InvokeShutdown() } catch {}
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
# Which version is running has to be readable somewhere without hunting for a file. It sits
# at the top of the menu, greyed out, and in the tray tooltip.
$tiVer     = $trayMenu.Items.Add("Claude Context Meter $Version")
$tiVer.Enabled = $false
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$tiShow    = $trayMenu.Items.Add("Show")
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$tiAuto    = $trayMenu.Items.Add("Start at login")
$tiLang    = New-Object System.Windows.Forms.ToolStripMenuItem
$tiRefresh = New-Object System.Windows.Forms.ToolStripMenuItem
$trayMenu.Items.Add($tiLang) | Out-Null
$trayMenu.Items.Add($tiRefresh) | Out-Null
$tiPos     = $trayMenu.Items.Add("Remember position")
$tiUpd     = $trayMenu.Items.Add("Check for updates")
$tiDoUpd   = $trayMenu.Items.Add("Update")
$tiDoUpd.Visible = $false
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$tiExit    = $trayMenu.Items.Add("Exit")

$tiUpd.Add_Click({
    $script:CheckUpdates = -not $script:CheckUpdates
    $script:State['checkUpdates'] = $script:CheckUpdates
    Save-State $script:State
    if ($script:CheckUpdates) { Start-UpdateCheck }
})
$tiDoUpd.Add_Click({ Install-Update })

$tiPos.Add_Click({
    $script:RememberPos = -not $script:RememberPos
    $script:State['rememberPos'] = $script:RememberPos
    Save-State $script:State
    if ($script:RememberPos) { Save-Position }
})

$tiShow.Add_Click({ Show-Widget })
$tiExit.Add_Click({ Exit-Widget })
$tiAuto.Add_Click({
    param($s, $e)
    $err = Set-AutostartEnabled (-not (Get-AutostartEnabled))
    if ($err) { Write-Log "autostart change failed: $err" }
})

foreach ($l in $UiLangs) {
    $it = $tiLang.DropDownItems.Add($l.Name)
    $it.Tag = $l.Code
    $it.Add_Click({
        param($s, $e)
        $script:Lang = $s.Tag
        $script:State['lang'] = $s.Tag
        Save-State $script:State
        Apply-Language
    })
}
foreach ($r in $RefreshPresets) {
    $it = $tiRefresh.DropDownItems.Add($r.Key)
    $it.Tag = $r.Key
    $it.Add_Click({
        param($s, $e)
        Apply-Refresh $s.Tag
        $script:State['refresh'] = $s.Tag
        Save-State $script:State
    })
}

# Both menus read the truth when they open, never a remembered flag.
$trayMenu.Add_Opening({
    $tiAuto.Checked = Get-AutostartEnabled
    $tiPos.Checked = $script:RememberPos
    $tiUpd.Checked = $script:CheckUpdates
    if ($script:UpdateInfo) {
        $tiDoUpd.Text = (T 'menu.update') -f $script:UpdateInfo.Version
        $tiDoUpd.Visible = $true
    } else {
        $tiDoUpd.Visible = $false
    }
    $tiShow.Text = if ($window.IsVisible) { T 'menu.close' } else { T 'menu.show' }
    foreach ($it in $tiLang.DropDownItems)    { $it.Checked = ($it.Tag -eq $script:Lang) }
    foreach ($it in $tiRefresh.DropDownItems) { $it.Checked = ($it.Tag -eq $script:Refresh) }
}.GetNewClosure())

$tray = New-Object System.Windows.Forms.NotifyIcon
try {
    $icoPath = Join-Path (Split-Path -Parent $PSCommandPath) 'ClaudeContextMeter.ico'
    if (Test-Path $icoPath) { $tray.Icon = New-Object System.Drawing.Icon($icoPath, 16, 16) }
} catch { Write-Log ("tray icon could not be loaded: " + $_.Exception.Message) }
if (-not $tray.Icon) { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Text = "Claude Context Meter $Version"
$tray.ContextMenuStrip = $trayMenu
$tray.Visible = $true
$tray.Add_MouseDoubleClick({ if ($window.IsVisible) { Hide-Widget } else { Show-Widget } })

Apply-Refresh $(if ($script:State['refresh']) { $script:State['refresh'] } else { 'normal' })
Apply-Language

# Mouse-DOWN with Handled, not mouse-up. The window turns every unhandled mouse-down into
# DragMove(), which enters a modal move loop and eats the matching mouse-up — that is why
# the gear did nothing on 15.08.2026 while it hung on MouseLeftButtonUp. The row click in
# New-SessionRow already solved this the same way; the close button is switched over too,
# so both header buttons behave alike instead of one of them being subtly unreliable.
$transparentHit = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString("#0114181F"))
$MenuBtn.Background = $transparentHit
$UpdBtn.Background = $transparentHit
$UpdBtn.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Install-Update }.GetNewClosure())
$MenuBtn.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $miAuto.IsChecked = Get-AutostartEnabled
    $menu.PlacementTarget = $MenuBtn
    $menu.Placement = 'Bottom'
    $menu.IsOpen = $true
}.GetNewClosure())

$wa = [System.Windows.SystemParameters]::WorkArea
$window.Left = $wa.Right - 330; $window.Top = $wa.Top + 12
if ($script:RememberPos -and (Test-Path $PosFile)) {
    try {
        $p = (Get-Content $PosFile -Raw) -split ','
        $l = [double]$p[0]; $t = [double]$p[1]
        # Checked against the WHOLE desktop, not the primary monitor. WorkArea covers the
        # primary screen only, so a widget parked on a second monitor failed the test and was
        # silently dropped back into the default corner — the position had been saved
        # correctly all along, and then thrown away on the way back in.
        $vL = [System.Windows.SystemParameters]::VirtualScreenLeft
        $vT = [System.Windows.SystemParameters]::VirtualScreenTop
        $vR = $vL + [System.Windows.SystemParameters]::VirtualScreenWidth
        $vB = $vT + [System.Windows.SystemParameters]::VirtualScreenHeight
        # A little tolerance at the edges: a window nudged slightly off-screen is still a
        # position the user chose. Far outside it is a monitor that no longer exists.
        if ($l -gt ($vL - 50) -and $l -lt ($vR - 40) -and $t -gt ($vT - 20) -and $t -lt ($vB - 40)) {
            $window.Left = $l; $window.Top = $t
        } else {
            Write-Log "saved position $l,$t is outside the current desktop - using the default corner"
        }
    } catch {}
}
# DragMove blocks until the drag ends, so this is the moment the position is final.
$window.Add_MouseLeftButtonDown({ try { $window.DragMove(); Save-Position } catch {} })
$window.Add_Closed({
    Save-Position
    Save-ModelMax
    # Whichever way the window ends, the tray icon must go with it — an orphaned icon sits
    # in the notification area until the mouse happens to brush it.
    try { if ($tray) { $tray.Visible = $false; $tray.Dispose() } } catch {}
    Write-Log "window closed - exiting"
    # However the window ends - the system closing it, a crash in the shell - the loop has
    # to end with it, or the process would linger with no window and no way to reach it.
    try { $window.Dispatcher.InvokeShutdown() } catch {}
})
# The cross hides now instead of ending the process; Exit in the tray menu is the real end.
$CloseBtn.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Hide-Widget })

function New-Brush([string]$hex) {
    return New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex))
}

function New-SessionRow($name, $pct, $tooltip, $dim, $pending, $sid, $src, $winLbl) {
    $barW = 60.0
    $color = "#7DDE72"
    if ($pct -ge 80) { $color = "#FF6B5A" } elseif ($pct -ge 60) { $color = "#FFC85A" }
    if ($pending) { $color = "#8792A3" }

    $grid = New-Object Windows.Controls.Grid
    $grid.Margin = New-Object Windows.Thickness 0, 2, 0, 2
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::new(1, 'Star')
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::Auto
    $c3 = New-Object Windows.Controls.ColumnDefinition; $c3.Width = [Windows.GridLength]::Auto
    $c4 = New-Object Windows.Controls.ColumnDefinition; $c4.Width = [Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2); $grid.ColumnDefinitions.Add($c3)
    $grid.ColumnDefinitions.Add($c4)

    # Which surface the chat belongs to, so Cowork and Claude Code rows are told apart.
    $namePanel = New-Object Windows.Controls.DockPanel
    $namePanel.LastChildFill = $true
    $namePanel.VerticalAlignment = 'Center'
    $namePanel.Cursor = 'Hand'
    $namePanel.Background = New-Brush "#0114181F"   # transparent, but still hit-testable
    $namePanel.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Open-Chat $sid }.GetNewClosure())

    $tag = New-Object Windows.Controls.TextBlock
    if ($src -eq 'Cowork') { $tag.Text = "CW"; $tag.Foreground = New-Brush "#7FB3FF" }
    else                   { $tag.Text = "CC"; $tag.Foreground = New-Brush "#A98BE8" }
    $tag.FontSize = 9; $tag.FontFamily = "Segoe UI"; $tag.FontWeight = 'Bold'
    $tag.VerticalAlignment = 'Center'
    $tag.Margin = New-Object Windows.Thickness 0, 0, 5, 0
    [Windows.Controls.DockPanel]::SetDock($tag, 'Left')
    $namePanel.Children.Add($tag) | Out-Null

    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $name; $tb.FontSize = 11; $tb.FontFamily = "Segoe UI"
    $tb.Foreground = New-Brush "#D8DEE7"
    $tb.TextTrimming = 'CharacterEllipsis'; $tb.VerticalAlignment = 'Center'
    $namePanel.Children.Add($tb) | Out-Null
    [Windows.Controls.Grid]::SetColumn($namePanel, 0); $grid.Children.Add($namePanel) | Out-Null

    $barBg = New-Object Windows.Controls.Border
    $barBg.Width = $barW; $barBg.Height = 7; $barBg.CornerRadius = New-Object Windows.CornerRadius 3.5
    $barBg.Background = New-Brush "#2B3340"; $barBg.Margin = New-Object Windows.Thickness 8, 0, 8, 0
    $barBg.VerticalAlignment = 'Center'
    $fill = New-Object Windows.Controls.Border
    $fill.Height = 7; $fill.CornerRadius = New-Object Windows.CornerRadius 3.5
    $fill.HorizontalAlignment = 'Left'
    $fill.Width = [Math]::Max(3.0, $barW * [Math]::Min(100.0, $pct) / 100.0)
    $fill.Background = New-Brush $color
    $barBg.Child = $fill
    [Windows.Controls.Grid]::SetColumn($barBg, 1); $grid.Children.Add($barBg) | Out-Null

    $pt = New-Object Windows.Controls.TextBlock
    if ($pending) { $pt.Text = "…" } else { $pt.Text = ("{0:N0}%" -f $pct) }
    $pt.FontSize = 11; $pt.FontWeight = 'Bold'; $pt.FontFamily = "Segoe UI"
    $pt.Foreground = New-Brush $color; $pt.Width = 34; $pt.TextAlignment = 'Right'; $pt.VerticalAlignment = 'Center'
    [Windows.Controls.Grid]::SetColumn($pt, 2); $grid.Children.Add($pt) | Out-Null

    # Grey and small on purpose: it is a unit label for the number next to it, not a value
    # of its own. Empty while the context is still unknown - a badge there would claim
    # knowledge the row does not have yet.
    $wt = New-Object Windows.Controls.TextBlock
    $wt.Text = $winLbl; $wt.FontSize = 9; $wt.FontFamily = "Segoe UI"
    $wt.Foreground = New-Brush "#8792A3"
    $wt.Width = 26; $wt.TextAlignment = 'Right'; $wt.VerticalAlignment = 'Center'
    $wt.Margin = New-Object Windows.Thickness 5, 0, 0, 0
    [Windows.Controls.Grid]::SetColumn($wt, 3); $grid.Children.Add($wt) | Out-Null

    $grid.ToolTip = $tooltip
    if ($dim) { $grid.Opacity = 0.5 }
    return $grid
}

function New-InfoRow($text) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $text; $tb.FontSize = 11; $tb.FontFamily = "Segoe UI"; $tb.FontStyle = 'Italic'
    $tb.Foreground = New-Brush "#8792A3"; $tb.Margin = New-Object Windows.Thickness 0, 2, 0, 2
    return $tb
}

function Add-Row($sid, $path, $now, $actTime) {
    $st = $null
    if ($path) { $st = $Cache[$path] }

    $name = $null
    if ($sid -and $Titles.ContainsKey($sid)) { $name = $Titles[$sid] }
    if (-not $name -and $st -and $st.Cwd) { $name = Split-Path $st.Cwd -Leaf }
    if (-not $name -and $sid) { $name = $sid.Substring(0, 8) }
    if (-not $name) { $name = "?" }

    $src = "Code"
    if ($sid -and $Meta.ContainsKey($sid) -and $Meta[$sid].Src) { $src = $Meta[$sid].Src }

    $ageMin = 9999
    if ($actTime -and $actTime -gt [datetime]::MinValue) { $ageMin = [Math]::Round(($now - $actTime).TotalMinutes) }
    $dim = ($ageMin -gt $StaleMin)

    if (-not $st -or $st.LastCtx -le 0) {
        $act = (T 'tip.activity') -f $ageMin
        $RowsPanel.Children.Add((New-SessionRow $name 0 "$name`n$src`n$(T 'tip.noctx')`n$act" $dim $true $sid $src "")) | Out-Null
        return
    }
    # Prefer the model from the chat record — the log line drops the [1m] suffix.
    $model = $st.Model
    if ($sid -and $Meta.ContainsKey($sid) -and $Meta[$sid].Model) { $model = $Meta[$sid].Model }
    $win = Get-ContextWindow $model $st.LastCtx
    $pct = [Math]::Min(100.0, 100.0 * $st.LastCtx / $win)
    $proj = ""
    if ($st.Cwd) { $proj = $st.Cwd }
    $act = (T 'tip.activity') -f $ageMin
    $tip = "$name`n$src · $proj`n$(Format-Tokens $st.LastCtx) / $(Format-Tokens $win) $(T 'tip.tokens')`n$(T 'tip.model') $model`n$act`n$(T 'tip.click')"
    $RowsPanel.Children.Add((New-SessionRow $name $pct $tip $dim $false $sid $src (Format-Window $win))) | Out-Null
}

function Update-UI {
    $now = Get-Date
    $RowsPanel.Children.Clear()

    # candidates: Cowork chats (by lastActivityAt) + live CLI processes + session logs
    $rows = @(); $seen = @{}
    foreach ($cid in @($Meta.Keys)) {
        $m = $Meta[$cid]
        if ($m.Archived) { continue }
        $p = $PathBySid[$cid]
        $t = $m.LastAct
        if ($p -and $Cache.ContainsKey($p)) {
            $ft = $Cache[$p].File.LastWriteTime
            if ($ft -gt $t) { $t = $ft }
        }
        $keyId = $cid; if ($p) { $keyId = $p }
        $s = $m.Src; if (-not $s) { $s = "Code" }
        if (-not $seen.ContainsKey($keyId)) { $seen[$keyId] = 1; $rows += , @($cid, $p, $t, $s) }
    }
    foreach ($sid in $script:RunningIds) {
        $p = $PathBySid[$sid]
        $t = [datetime]::MinValue
        if ($p -and $Cache.ContainsKey($p)) { $t = $Cache[$p].File.LastWriteTime }
        $keyId = $sid; if ($p) { $keyId = $p }
        $s = "Code"; if ($Meta.ContainsKey($sid) -and $Meta[$sid].Src) { $s = $Meta[$sid].Src }
        if (-not $seen.ContainsKey($keyId)) { $seen[$keyId] = 1; $rows += , @($sid, $p, $t, $s) }
    }
    foreach ($kv in $Cache.GetEnumerator()) {
        $st = $kv.Value
        if ($st.IsAgent -or $st.LastCtx -le 0) { continue }
        if ($seen.ContainsKey($kv.Key)) { continue }
        $sid = $null
        $mg = $reGuid.Match($kv.Key)
        if ($mg.Success) { $sid = $mg.Groups[1].Value }
        $seen[$kv.Key] = 1
        $s = "Code"
        if ($kv.Key -like "*local-agent-mode-sessions*") { $s = "Cowork" }
        elseif ($sid -and $Meta.ContainsKey($sid) -and $Meta[$sid].Src) { $s = $Meta[$sid].Src }
        $rows += , @($sid, $kv.Key, $st.File.LastWriteTime, $s)
    }

    # Newest first, but keep guaranteed seats for each surface — otherwise a busy day in
    # Claude Code pushes every Cowork chat out of the list and Cowork looks like it is gone.
    $sorted = @($rows | Sort-Object { $_[2] } -Descending)
    $chosen = @{}
    $pick = @()
    $rowKey = { param($r) "$($r[0])|$($r[1])" }
    foreach ($s in @('Cowork', 'Code')) {
        $n = 0
        foreach ($r in $sorted) {
            if ($n -ge $MinPerSrc) { break }
            if ($r[3] -ne $s) { continue }
            $k = & $rowKey $r
            if ($chosen.ContainsKey($k)) { continue }
            $chosen[$k] = 1; $pick += , $r; $n++
        }
    }
    foreach ($r in $sorted) {
        if ($pick.Count -ge $MaxRows) { break }
        $k = & $rowKey $r
        if ($chosen.ContainsKey($k)) { continue }
        $chosen[$k] = 1; $pick += , $r
    }
    $rows = @($pick | Sort-Object { $_[2] } -Descending | Select-Object -First $MaxRows)
    if ($rows.Count -eq 0) {
        if ($script:HeavyPending) { $RowsPanel.Children.Add((New-InfoRow (T 'row.scanning'))) | Out-Null }
        else { $RowsPanel.Children.Add((New-InfoRow (T 'row.none'))) | Out-Null }
    } else {
        foreach ($r in $rows) { Add-Row $r[0] $r[1] $now $r[2] }
    }

    # totals over rate-limit windows
    $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $cut5 = $nowSec - 5 * 3600
    $cut7 = $nowSec - 7 * 86400
    $s5 = [long]0; $s7 = [long]0
    foreach ($kv in $Buckets.GetEnumerator()) {
        $t = $kv.Key * 600
        if ($t -ge $cut7) {
            $s7 = $s7 + $kv.Value
            if ($t -ge $cut5) { $s5 = $s5 + $kv.Value }
        }
    }
    if ($null -ne $script:PlanFh) { $Sum5.Text = "$(Format-Tokens $s5) · $(T 'sum.limit') $($script:PlanFh)%" } else { $Sum5.Text = Format-Tokens $s5 }
    if ($null -ne $script:PlanSd) { $Sum7.Text = "$(Format-Tokens $s7) · $(T 'sum.limit') $($script:PlanSd)%" } else { $Sum7.Text = Format-Tokens $s7 }
    if ($script:HeavyPending) { $LoadNote.Visibility = 'Visible' } else { $LoadNote.Visibility = 'Collapsed' }
}

function Invoke-Tick {
    $script:TickNo = $script:TickNo + 1
    Scan-Files
    if ($script:TickNo -eq 1 -or ($script:TickNo % 5) -eq 0) { Update-Titles; Update-PlanUsage }

    # One process sweep per tick, shared with Update-UI — it used to run twice.
    $script:RunningIds = Get-RunningSessionIds

    # priority: running-session logs first, then everything else by recency
    $runningPaths = @{}
    foreach ($sid in $script:RunningIds) {
        $p = $PathBySid[$sid]
        if ($p) { $runningPaths[$p] = $true }
    }
    $work = @()
    foreach ($kv in $Cache.GetEnumerator()) {
        $st = $kv.Value
        if ($st.File.Length -le $st.Offset) { continue }
        $prio = 1
        if ($runningPaths.ContainsKey($kv.Key)) { $prio = 0 }
        $work += , @($kv.Key, $st, $prio)
    }
    $work = @($work | Sort-Object @{e={$_[2]}}, @{e={$_[1].File.LastWriteTime};Descending=$true})

    $budget = [long]$TickBudget
    $script:HeavyPending = $false
    foreach ($w in $work) {
        if ($budget -le 0) { $script:HeavyPending = $true; break }
        $consumed = Parse-File $w[0] $budget
        $budget = $budget - [Math]::Max($consumed, [long]1)
    }
    if (-not $script:HeavyPending) {
        foreach ($kv in $Cache.GetEnumerator()) {
            if ($kv.Value.File.Length -gt $kv.Value.Offset) { $script:HeavyPending = $true; break }
        }
    }

    # persist what was learned about model windows (no-op unless something changed)
    if (($script:TickNo % 20) -eq 0) { Save-ModelMax }

    # Last-alive marker. One tiny write every ten ticks - cheap, and it is what pins the
    # moment of a disappearance to half a minute instead of eleven.
    if (($script:TickNo % 10) -eq 0) {
        try { [System.IO.File]::WriteAllText($PulseFile, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " pid=$PID") } catch { }
    }

    # Collect the update check when its runspace is done. Polled rather than awaited, so a
    # slow or hanging request costs nothing here.
    Complete-UpdateCheck

    # A heartbeat with the numbers that would explain a slow death — memory, handles, how
    # many logs are being tracked. Every ~10 minutes, so the log stays readable while still
    # showing whether the widget grows over a long session.
    if (($script:TickNo % 200) -eq 0) {
        try {
            $me = [System.Diagnostics.Process]::GetCurrentProcess()
            Write-Log ("heartbeat tick={0} privateMB={1} handles={2} logs={3} rows={4}" -f `
                $script:TickNo, [math]::Round($me.PrivateMemorySize64 / 1MB), $me.HandleCount, $Cache.Count, $RowsPanel.Children.Count)
        } catch {}
    }

    # prune old buckets occasionally
    if (($script:TickNo % 200) -eq 0) {
        $cut = [long][Math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 7 * 86400) / 600)
        $old = @($Buckets.Keys | Where-Object { $_ -lt $cut })
        foreach ($k in $old) { $Buckets.Remove($k) }
    }

    Update-UI
    if ($script:HeavyPending) { $timer.Interval = [TimeSpan]::FromMilliseconds($FastMs) }
    else { $timer.Interval = [TimeSpan]::FromMilliseconds($script:SlowMs) }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({ try { Invoke-Tick } catch {} })
$timer.Start()

# Take over autostart from the shortcut/task setup before the window appears, and repair a
# path left behind by a move. Both are no-ops once done, and neither may block the start:
# a widget that refuses to appear because of a registry hiccup is worse than one without
# autostart.
try { Invoke-AutostartMigration } catch { Write-Log ("migration failed: " + ($_ | Out-String).Trim()) }
try { Sync-AutostartPath } catch { Write-Log ("path sync failed: " + ($_ | Out-String).Trim()) }
try { Remove-OldInstalls } catch { Write-Log ("old install cleanup failed: " + ($_ | Out-String).Trim()) }
try { Start-UpdateCheck } catch { Write-Log ("update check could not start: " + ($_ | Out-String).Trim()) }

# The widget spends its life idling and re-reading logs. BelowNormal means it gets the
# processor only when nothing else wants it — the honest version of "put it on a spare
# core", and it works whatever the core count. Pinning to one core would not reduce the
# work, only confine it, and on a weak machine that hurts rather than helps.
try {
    [System.Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal'
} catch { Write-Log ("could not lower priority: " + $_.Exception.Message) }

Write-Log "showing window"
# Show(), not ShowDialog(). ShowDialog runs a modal loop that ends the moment the window
# stops being shown - so Hide() ended it too, ShowDialog returned, the script ran off the
# end and the process exited. That is exactly why the cross and the tray "Hide" made the
# widget vanish for good instead of tucking it away: reported on 19.08.2026 as "I clicked
# the icon and it went out", and the real log confirms it with "window closed" one second
# after the click. With Show() plus an explicit dispatcher loop, hiding is just hiding, and
# only Exit-Widget ends the loop.
$window.Show()
[System.Windows.Threading.Dispatcher]::Run()
Write-Log "dispatcher loop ended - exiting"
