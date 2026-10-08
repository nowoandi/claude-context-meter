# Local Codex rollout reader. Dot-sourcing has no IO; only the selected tab calls Update.
$script:CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$script:CodexCache = @{}
$script:CodexTitles = @{}
$script:CodexIndexState = @{ Offset = [long]0 }
$script:CodexLastScan = $null
$script:CodexLimits = $null
$script:CodexLimitsTime = [datetime]::MinValue
$script:CodexPending = $false

function Read-CodexChunk([string]$path, $state, [long]$budget) {
    # Commit only complete lines, so a writer interrupted mid-record is harmless.
    $stream = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($stream.Length -lt $state.Offset) { $state.Offset = [long]0 }
        $remaining = $stream.Length - $state.Offset
        if ($remaining -le 0) { return @{ Text = ''; Bytes = 0 } }
        $take = [long][Math]::Min($remaining, [Math]::Max(65536, $budget))
        while ($true) {
            [void]$stream.Seek($state.Offset, 'Begin')
            $buffer = New-Object byte[] ([int]$take)
            $count = $stream.Read($buffer, 0, $buffer.Length)
            $end = $count - 1
            while ($end -ge 0 -and $buffer[$end] -ne 10) { $end-- }
            if ($end -ge 0) {
                $state.Offset += $end + 1
                return @{ Text = [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1); Bytes = $end + 1 }
            }
            if ($take -ge $remaining -or $take -ge 16000000) { return @{ Text = ''; Bytes = 0 } }
            $take = [Math]::Min($remaining, $take * 4)
        }
    } finally { $stream.Dispose() }
}

function Update-CodexTitles([long]$budget) {
    $path = Join-Path $script:CodexHome 'session_index.jsonl'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    try {
        $chunk = Read-CodexChunk $path $script:CodexIndexState $budget
        foreach ($line in $chunk.Text.Split("`n")) {
            if (-not $line.Trim()) { continue }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                if ($record.id -and $record.thread_name) { $script:CodexTitles[$record.id] = $record.thread_name }
            } catch {}
        }
        $script:CodexIndexState.Pending = ((Get-Item -LiteralPath $path).Length -gt $script:CodexIndexState.Offset -and $chunk.Bytes -gt 0)
        return $chunk.Bytes
    } catch { return 0 }
}

function Read-CodexRollout([string]$path, $state, [long]$budget) {
    try {
        if ((Get-Item -LiteralPath $path).Length -lt $state.Offset) {
            $state.Offset = [long]0; $state.Context = [long]0; $state.Window = [long]0
        }
        $chunk = Read-CodexChunk $path $state $budget
        foreach ($line in $chunk.Text.Split("`n")) {
            # Skip conversation bodies before JSON parsing; no text is needed for usage.
            if ($line -notmatch '"type"\s*:\s*"(session_meta|turn_context|event_msg)"') { continue }
            if ($line -match '"type"\s*:\s*"event_msg"' -and $line -notmatch '"type"\s*:\s*"token_count"') { continue }
            try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            $payload = $record.payload
            switch ($record.type) {
                'session_meta' {
                    $state.Id = $payload.id; $state.Cwd = $payload.cwd
                    $state.IsAgent = ($null -ne $payload.source.subagent)
                }
                'turn_context' { if ($payload.model) { $state.Model = $payload.model } }
                'event_msg' {
                    if ($payload.type -ne 'token_count') { continue }
                    if ($payload.info.last_token_usage) {
                        # Cached input is already part of input_tokens, never add it again.
                        $state.Context = [long]$payload.info.last_token_usage.input_tokens
                        $state.Window = [long]$payload.info.model_context_window
                    }
                    $stamp = [datetime]::MinValue
                    try { $stamp = [DateTimeOffset]::Parse($record.timestamp).LocalDateTime } catch {}
                    if ($payload.rate_limits -and $stamp -gt $script:CodexLimitsTime -and
                        (-not $payload.rate_limits.limit_id -or $payload.rate_limits.limit_id -eq 'codex')) {
                        $script:CodexLimits = $payload.rate_limits
                        $script:CodexLimitsTime = $stamp
                    }
                }
            }
        }
        return $chunk.Bytes
    } catch { return 0 }
}

function Update-CodexData([long]$budget, [int]$scanSeconds) {
    $now = Get-Date
    $script:CodexPending = $false
    if (-not $script:CodexLastScan -or ($now - $script:CodexLastScan).TotalSeconds -ge $scanSeconds) {
        $script:CodexLastScan = $now
        # Old chats can still be active, so filter by modification time, not creation date.
        $root = Join-Path $script:CodexHome 'sessions'
        if (Test-Path -LiteralPath $root) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -gt $now.AddDays(-7) }) {
                if (-not $script:CodexCache.ContainsKey($file.FullName)) {
                    $script:CodexCache[$file.FullName] = @{
                        File = $file; Offset = [long]0; Id = ''; Cwd = ''; Model = ''
                        Context = [long]0; Window = [long]0; IsAgent = $false
                    }
                } else { $script:CodexCache[$file.FullName].File = $file }
            }
        }
        foreach ($path in @($script:CodexCache.Keys)) {
            if ($script:CodexCache[$path].File.LastWriteTime -lt $now.AddDays(-7)) { $script:CodexCache.Remove($path) }
        }
    }
    $budget -= Update-CodexTitles ([Math]::Min($budget, 262144))
    $script:CodexPending = [bool]$script:CodexIndexState.Pending
    foreach ($state in @($script:CodexCache.Values | Sort-Object { $_.File.LastWriteTime } -Descending)) {
        $state.File.Refresh()
        if (-not $state.File.Exists -or $state.File.Length -eq $state.Offset) { continue }
        if ($budget -le 0) { $script:CodexPending = $true; break }
        $bytes = Read-CodexRollout $state.File.FullName $state $budget
        $budget -= $bytes
        if ($bytes -gt 0 -and $state.File.Length -gt $state.Offset) { $script:CodexPending = $true }
    }
}

function Get-CodexLimit([string]$key, [int]$minutes) {
    if (-not $script:CodexLimits -or ((Get-Date) - $script:CodexLimitsTime).TotalMinutes -gt 120) { return $null }
    $limit = $script:CodexLimits.$key
    if (-not $limit -or $limit.window_minutes -ne $minutes -or $null -eq $limit.used_percent) { return $null }
    if ($limit.resets_at -and $limit.resets_at -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { return $null }
    return [double]$limit.used_percent
}
