# Standalone regression checks; no Pester installation or running widget required.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tempRoot = Join-Path $PSScriptRoot ('fixtures-' + [guid]::NewGuid().ToString('N'))
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Add-Record($path, $record) {
    [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Depth 12 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
}
try {
    foreach ($file in @('ClaudeContextMeter.ps1', 'CodexContext.ps1')) {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
        Assert ($errors.Count -eq 0) "Syntax errors in $file : $errors"
        if ($file -eq 'ClaudeContextMeter.ps1') { $widgetAst = $ast }
    }
    . (Join-Path $root 'CodexContext.ps1')
    $script:CodexHome = $tempRoot
    # An old creation directory with a recent write must still be discovered.
    $folder = Join-Path $tempRoot 'sessions\2020\01\01'
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $path = Join-Path $folder 'rollout-test.jsonl'
    $sid = '11111111-1111-1111-1111-111111111111'
    Add-Record $path @{ type = 'session_meta'; payload = @{ id = $sid; cwd = 'C:\Project'; source = 'vscode' } }
    Add-Record $path @{ type = 'turn_context'; payload = @{ model = 'test-model' } }
    $usage = @{ type = 'event_msg'; timestamp = [DateTimeOffset]::UtcNow.ToString('o'); payload = @{
        type = 'token_count'; info = @{ last_token_usage = @{ input_tokens = 50000; cached_input_tokens = 40000; output_tokens = 200 }; model_context_window = 200000 }
        rate_limits = @{ limit_id = 'codex'; primary = @{ used_percent = 0; window_minutes = 300; resets_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 1000 }; secondary = @{ used_percent = 37; window_minutes = 10080 } }
    } }
    Add-Record $path $usage
    Add-Record (Join-Path $tempRoot 'session_index.jsonl') @{ id = $sid; thread_name = 'Fixture title' }
    Update-CodexData 2000000 30
    $state = $script:CodexCache[$path]
    Assert ($state.Context -eq 50000 -and $state.Window -eq 200000) 'Cached input was double-counted or window lost'
    Assert ($state.Model -eq 'test-model' -and -not $state.IsAgent) 'Session metadata not parsed'
    Assert ($script:CodexTitles[$sid] -eq 'Fixture title') 'Session title not read'
    Assert ((Get-CodexLimit primary 300) -eq 0) 'Zero usage must be shown'
    Assert ($null -eq (Get-CodexLimit primary 60)) 'Different rate-limit windows must not be mislabeled'
    $script:CodexLimitsTime = (Get-Date).AddHours(-3)
    Assert ($null -eq (Get-CodexLimit primary 300)) 'Stale plan usage must be hidden'
    $script:CodexLimitsTime = Get-Date
    $script:CodexLimits.primary.resets_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - 1
    Assert ($null -eq (Get-CodexLimit primary 300)) 'Expired plan usage must be hidden'
    $usage.payload.info.last_token_usage.input_tokens = 20000
    $text = $usage | ConvertTo-Json -Depth 12 -Compress
    [IO.File]::AppendAllText($path, $text.Substring(0, 40))
    $offset = $state.Offset
    Update-CodexData 2000000 30
    Assert ($state.Offset -eq $offset -and $state.Context -eq 50000) 'Partial JSON line consumed'
    [IO.File]::AppendAllText($path, $text.Substring(40) + "`n")
    Update-CodexData 2000000 30
    Assert ($state.Context -eq 20000) 'Compacted context must be allowed to decrease'
    $offset = $state.Offset
    Update-CodexData 2000000 30
    Assert ($state.Offset -eq $offset -and -not $script:CodexPending) 'Unchanged files must not be reparsed'
    [IO.File]::WriteAllText($path, '')
    Update-CodexData 2000000 30
    Assert ($state.Offset -eq 0 -and $state.Context -eq 0) 'Truncated rollout keeps stale context'
    Add-Record $path @{ type = 'session_meta'; payload = @{ id = $sid; source = @{ subagent = @{ thread_spawn = @{} } } } }
    Update-CodexData 2000000 30
    Assert $state.IsAgent 'Subagent must not be displayed as a main chat'

    # Extract functions without startup, network checks, tray, or scheduled-task migration.
    $functions = @{}
    foreach ($node in $widgetAst.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $functions[$node.Name] = $node.Extent.Text }
    foreach ($name in @('Invoke-Tick', 'Set-ActiveAgent')) { Invoke-Expression $functions[$name] }
    $script:ClaudeReads = 0; $script:CodexReads = 0
    function Scan-Files { $script:ClaudeReads++ }
    function Update-Titles { $script:ClaudeReads++ }
    function Update-PlanUsage { $script:ClaudeReads++ }
    function Get-RunningSessionIds { $script:ClaudeReads++; return @() }
    function Update-CodexData { $script:CodexReads++ }
    function Save-ModelMax {}
    function Update-UI {}
    function Update-AgentLabels {}
    function Save-State($value) { $script:SavedAgent = $value.agent }
    function Write-Log {}
    function Complete-UpdateCheck {}
    $Cache = @{}; $Buckets = @{}; $PathBySid = @{}
    $script:State = @{}; $script:TickNo = 0; $script:SlowMs = 3000; $FastMs = 600
    $script:ActiveAgent = 'claude'; $script:ShowEvent = $null
    $timer = [pscustomobject]@{ Interval = [TimeSpan]::Zero }
    Invoke-Tick
    Assert ($script:ClaudeReads -gt 0 -and $script:CodexReads -eq 0) 'Passive Codex source polled'
    $claudeReads = $script:ClaudeReads
    $codexOffset = $state.Offset
    Set-ActiveAgent codex
    Invoke-Tick
    Assert ($script:ClaudeReads -eq $claudeReads -and $script:CodexReads -eq 1) 'Passive Claude source polled'
    Assert ($script:SavedAgent -eq 'codex') 'Selected agent not persisted'
    Set-ActiveAgent claude
    Invoke-Tick
    Assert ($script:CodexReads -eq 1 -and $state.Offset -eq $codexOffset) 'Switching resets or polls passive Codex cache'
    'PASS: syntax, usage, titles, compaction, partial lines, truncation, limits, subagents, and passive-source isolation'
} finally {
    # Delete only the unique fixture directory created by this test, inside tests/.
    $resolved = [IO.Path]::GetFullPath($tempRoot)
    Assert ($resolved.StartsWith([IO.Path]::GetFullPath($PSScriptRoot) + [IO.Path]::DirectorySeparatorChar)) 'Fixture cleanup escaped tests directory'
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
