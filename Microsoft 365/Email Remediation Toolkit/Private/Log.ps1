# Session log: one JSON line for each answer typed and each action the toolkit takes.
# Run evidence (events.jsonl) records the session ID so the two logs can be matched.
$script:MRLog = $null

function Open-MRLog {
    param([string]$Directory, $Context)
    if ($script:MRLog -or [string]::IsNullOrWhiteSpace($Directory)) { return }
    try {
        $null = [IO.Directory]::CreateDirectory($Directory)
        $sessionId = [guid]::NewGuid().ToString('N').Substring(0, 12)
        $name = 'session-{0}-{1}.jsonl' -f [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), $sessionId
        $script:MRLog = [pscustomobject]@{ Path = Join-Path $Directory $name; SessionId = $sessionId; Stopped = $false }
        Write-MRLog 'SessionStarted' $Context
    }
    catch {
        $script:MRLog = $null
        Write-MRText Notice "The session log could not be started, so this session is not logged: $($_.Exception.Message)"
    }
}

function Write-MRLog {
    param([string]$EventName, $Details = @{})
    if (-not $script:MRLog -or $script:MRLog.Stopped) { return }
    try {
        $entry = [ordered]@{ Utc = [datetimeoffset]::UtcNow.ToString('o'); Session = $script:MRLog.SessionId; Event = $EventName; Details = $Details }
        $line = ($entry | ConvertTo-Json -Depth 8 -Compress -WarningAction SilentlyContinue) + [environment]::NewLine
        [IO.File]::AppendAllText($script:MRLog.Path, $line, [text.UTF8Encoding]::new($false))
    }
    catch {
        # Logging must never interrupt a search or removal; report the gap once.
        $script:MRLog.Stopped = $true
        Write-MRText Notice "The session log stopped recording: $($_.Exception.Message)"
    }
}

function Get-MRLogSessionId {
    if ($script:MRLog) { return $script:MRLog.SessionId }
    return ''
}

function Close-MRLog {
    if (-not $script:MRLog) { return }
    Write-MRLog 'SessionEnded' @{}
    $script:MRLog = $null
}
