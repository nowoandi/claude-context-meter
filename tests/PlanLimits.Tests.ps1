# Plan limit and weekly reset: the case of 10.10.2026, replayed against fixed clocks.
# No widget, no tray - the functions are lifted out of the real script by its syntax tree.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'ClaudeContextMeter.ps1'), [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) "Syntax errors: $errors"
$functions = @{}
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$node.Name] = $node.Extent.Text }
foreach ($name in @('T', 'Update-PlanUsage', 'Note-WeekAnchor', 'Get-LastWeekReset', 'Get-PlanFreshness', 'Get-UiCulture', 'Format-Moment', 'Format-Span')) {
    Assert $functions.ContainsKey($name) "Missing function $name"
    Invoke-Expression $functions[$name]
}
foreach ($var in @('$Strings', '$rePlan', '$WeekSec', '$reWeekReset')) {
    $a = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $var }, $true)
    Assert $a "Missing $var"
    Invoke-Expression $a.Extent.Text
}
function At([string]$local) { [DateTimeOffset]::new([datetime]::ParseExact($local, 'dd.MM.yyyy HH:mm', $null)).ToUnixTimeSeconds() }

# --- the weekly grid is learned from a transcript line, as Claude Code writes it ---
$script:State = @{}; $script:WeekAnchor = $null; $script:WeekAnchorDirty = $false
$sat = At '03.10.2026 08:00'
$line = '{"quotaLimits":{"status":"rejected","resetsAt":' + $sat + ',"unifiedRateLimitFallbackAvailable":false,"rateLimitType":"seven_day","overageStatus":"rejected"}}'
$m = $reWeekReset.Match($line); Assert $m.Success 'seven_day resetsAt not recognised'
Note-WeekAnchor ([long]$m.Groups[1].Value)
Assert ($script:WeekAnchor -eq $sat -and $script:State['weekAnchor'] -eq $sat -and $script:WeekAnchorDirty) 'Anchor not stored for the next start'
Assert (-not $reWeekReset.Match('{"resetsAt":1781952600,"rateLimitType":"five_hour"}').Success) 'A five-hour reset must not move the weekly grid'
Note-WeekAnchor ($sat - 7 * 86400)
Assert ($script:WeekAnchor -eq $sat) 'An older anchor must not replace a newer one'

Assert ((Get-LastWeekReset (At '10.10.2026 12:56')) -eq (At '10.10.2026 08:00')) 'After Saturday 08:00 the window starts that morning'
Assert ((Get-LastWeekReset (At '10.10.2026 07:59')) -eq $sat) 'One minute before the reset it is still last week'
Assert ((Get-LastWeekReset (At '01.10.2026 12:00')) -eq (At '26.09.2026 08:00')) 'A moment before the anchor maps onto the same grid'
$script:WeekAnchor = $null
Assert ($null -eq (Get-LastWeekReset (At '10.10.2026 12:56'))) 'Without evidence there is no grid, not a guess'
$script:WeekAnchor = $sat

# --- the snapshot: the real tail of plan-usage-history.json on 10.10.2026 ---
$UsageFile = Join-Path $env:TEMP ('plan-' + [guid]::NewGuid().ToString('N') + '.json')
$tail = '{"v":1,"h":[{"t":1791549435971,"org":"o","u":{"fh":0,"sd":96,"xu":0}},{"t":1791615723344,"org":"o","u":{"fh":7,"sd":2,"xu":0}}]}'
[IO.File]::WriteAllText($UsageFile, $tail)
try {
    $script:PlanAt = $null; $script:PlanFh = $null; $script:PlanSd = $null
    Update-PlanUsage
    Assert ($script:PlanAt -eq 1791615723 -and $script:PlanFh -eq 7 -and $script:PlanSd -eq 2) "Last snapshot not read: $($script:PlanAt) $($script:PlanFh) $($script:PlanSd)"
} finally { Remove-Item -LiteralPath $UsageFile }

# 12:56, snapshot from 09:02: the old two-hour rule hid both figures here. Now both stand.
$now = At '10.10.2026 12:56'
$f = Get-PlanFreshness $now (Get-LastWeekReset $now)
Assert ($f.Fh -and $f.Sd) 'A four-hour-old snapshot inside both windows must be shown'
# 15:00: the five-hour window has turned over, the weekly one has not.
$now = At '10.10.2026 15:00'
$f = Get-PlanFreshness $now (Get-LastWeekReset $now)
Assert ((-not $f.Fh) -and $f.Sd) 'Five-hour figure must expire after five hours, weekly must stay'
# Friday 14:37 with 96 %: shown on Friday, gone after Saturday 08:00.
$script:PlanAt = 1791549435; $script:PlanFh = 0; $script:PlanSd = 96
$now = At '10.10.2026 07:30'
Assert (Get-PlanFreshness $now (Get-LastWeekReset $now)).Sd 'Before the reset last week''s figure is still true'
$now = At '10.10.2026 08:30'
Assert (-not (Get-PlanFreshness $now (Get-LastWeekReset $now)).Sd) 'After the reset the 96 % of last week must not be shown'

# --- what the footer says ---
$script:Lang = 'ru'
$next = (Get-LastWeekReset (At '10.10.2026 12:56')) + $WeekSec
Assert ((Format-Moment $next $true) -eq 'Сб 08:00' -or (Format-Moment $next $true) -eq 'сб 08:00') "Russian day name: $(Format-Moment $next $true)"
Assert ((Format-Span ($next - (At '10.10.2026 12:56'))) -eq '6 д 19 ч') "Countdown: $(Format-Span ($next - (At '10.10.2026 12:56')))"
Assert ((Format-Span 3000) -eq '0 ч 50 мин') 'Short countdown'
$script:Lang = 'de'; Assert ((Format-Moment $next $true) -eq 'Sa 08:00') "German day name: $(Format-Moment $next $true)"
$script:Lang = 'en'; Assert ((Format-Moment $next $true) -eq 'Sat 08:00') "English day name: $(Format-Moment $next $true)"
'PASS: weekly grid learned and kept, snapshot read, each limit expires with its own window, footer text in three languages'
