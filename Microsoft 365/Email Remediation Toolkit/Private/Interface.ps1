# Interactive helpers. Directory reads and removal remain in the workflow.
function Read-MRAnswer {
    param([string]$Prompt)
    $answer = Read-Host $Prompt
    if ($answer.Trim() -in @(':cancel', ':back')) { throw [OperationCanceledException]::new('Action canceled. Returning to the menu.') }
    return $answer
}

function Read-MRValidated {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate)
    while ($true) {
        $value = Read-MRDefault $Prompt $Default
        try { return & $Validate $value }
        catch [OperationCanceledException] { throw }
        catch { Write-Warning $_.Exception.Message }
    }
}

function Get-MRRunIndex {
    param([string]$DataDirectory)
    $folders = @(if (Test-Path -LiteralPath $DataDirectory) { Get-ChildItem -LiteralPath $DataDirectory -Directory -ErrorAction Stop })
    $entries = @(foreach ($folder in $folders) {
        if (-not (Test-Path -LiteralPath (Join-Path $folder.FullName 'run.json'))) { continue }
        try {
            $run = Read-MRRun $folder.FullName
            $created = [datetimeoffset]::Parse($run.CreatedUtc, [cultureinfo]::InvariantCulture)
            $snapshots = @(Get-ChildItem -LiteralPath $folder.FullName -Filter 'search*.json' -File | Sort-Object LastWriteTimeUtc -Descending)
            $status = 'Created'; $items = 'unknown'
            if ($snapshots.Count) {
                $latest = Get-Content -LiteralPath $snapshots[0].FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                $status = [string](Get-MRProperty $latest 'Status'); $items = [string](Get-MRProperty $latest 'Items')
            }
            $purges = @(Get-ChildItem -LiteralPath $folder.FullName -Filter 'purge*.json' -File | Sort-Object LastWriteTimeUtc -Descending)
            $removal = 'not submitted'
            if ($purges.Count) {
                $latestPurge = Get-Content -LiteralPath $purges[0].FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                $removal = [string](Get-MRProperty $latestPurge 'Status')
            } elseif (Test-Path -LiteralPath (Join-Path $folder.FullName 'events.jsonl')) {
                $events = @(Get-Content -LiteralPath (Join-Path $folder.FullName 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
                if (@($events | Where-Object Event -EQ 'PurgeSubmissionAttempt').Count) { $removal = 'submission outcome unknown' }
            }
            $subject = if ($run.Subject) { $run.Subject } else { 'all subjects' }
            $label = "$($run.Ticket) | $subject | $($run.SenderAddress) | search: $status, $items matches | removal: $removal | $($created.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
            [pscustomobject]@{ Key = $folder.FullName; Label = $label; SearchText = "$label $($run.SearchName)"; Created = $created }
        }
        catch { Write-Warning "Skipping unreadable run '$($folder.Name)': $($_.Exception.Message)" }
    })
    return @($entries | Sort-Object Created -Descending)
}

function Select-MRList {
    param([object[]]$Entries, [string]$Title, [switch]$Multiple, [switch]$AllowPath)
    $Entries = @($Entries); $filter = ''; $page = 0; $size = 15
    $chosen = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($true) {
        $filtered = @($Entries | Where-Object { ([string]$_.SearchText).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        $pages = [math]::Max(1, [int][math]::Ceiling($filtered.Count / $size))
        $page = [math]::Min($page, $pages - 1)
        $visible = @($filtered | Select-Object -Skip ($page * $size) -First $size)
        Write-Host "`n$Title. Page $($page + 1)/$pages; $($filtered.Count) results; filter: '$filter'" -ForegroundColor Cyan
        for ($index = 0; $index -lt $visible.Count; $index++) {
            $marker = if ($chosen.Contains([string]$visible[$index].Key)) { '[selected] ' } else { '' }
            Write-Host "[$($index + 1)] $marker$($visible[$index].Label -replace '[\r\n\x00-\x1f]', ' ')"
        }
        Write-Host '/text filters; / clears; N/P changes page; C cancels.'
        if ($Multiple) { Write-Host "Comma-separated numbers toggle selections; D finishes; X clears. Selected: $($chosen.Count)." }
        if ($AllowPath) { Write-Host 'You may also paste a full saved run folder path.' }
        $answer = (Read-MRAnswer 'Choose').Trim().Trim('"').Trim("'")
        if ($answer -ieq 'C') { throw [OperationCanceledException]::new('Selection canceled.') }
        if ($answer.StartsWith('/')) { $filter = $answer.Substring(1); $page = 0; continue }
        if ($answer -ieq 'N') { $page = [math]::Min($page + 1, $pages - 1); continue }
        if ($answer -ieq 'P') { $page = [math]::Max(0, $page - 1); continue }
        if ($Multiple -and $answer -ieq 'X') { $chosen.Clear(); continue }
        if ($Multiple -and $answer -ieq 'D') {
            if (-not $chosen.Count) { Write-Warning 'Select at least one mailbox.'; continue }
            return @($Entries | Where-Object { $chosen.Contains([string]$_.Key) })
        }
        if ($AllowPath -and [IO.Path]::IsPathFullyQualified($answer)) { return $answer }
        $numbers = @($answer -split ','); $valid = $true; $indexes = @()
        foreach ($number in $numbers) {
            $parsed = 0
            if (-not [int]::TryParse($number.Trim(), [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $visible.Count) { $valid = $false; break }
            $indexes += $parsed - 1
        }
        if (-not $valid -or (-not $Multiple -and $indexes.Count -ne 1)) { Write-Warning 'Choose a displayed number or use one of the listed commands.'; continue }
        if (-not $Multiple) { return $visible[$indexes[0]] }
        foreach ($index in @($indexes | Sort-Object -Unique)) {
            $key = [string]$visible[$index].Key
            if (-not $chosen.Remove($key)) { $null = $chosen.Add($key) }
        }
    }
}

function Read-MRMailboxChoice {
    param([string[]]$CurrentMailboxes, [switch]$AllowKeep)
    while ($true) {
        Write-Host "`nMailbox scope: 1. All mailboxes; 2. Select mailboxes; 3. Members of a group; 4. Paste addresses."
        if ($AllowKeep) { Write-Host "Enter keeps the saved mailbox list ($($CurrentMailboxes.Count) entries)." }
        $choice = (Read-MRAnswer 'Choose a mailbox scope').Trim()
        if (-not $choice -and $AllowKeep) { return $null }
        switch ($choice) {
            { $_ -in @('', '1', 'ALL') } { return @{ MailboxMode = 'All'; Mailboxes = @('All'); GroupAddress = '' } }
            '2' { return @{ MailboxMode = 'Select'; GroupAddress = '' } }
            '3' { return @{ MailboxMode = 'Group'; GroupAddress = '' } }
            '4' {
                $addresses = Read-MRValidated 'Comma-separated individual mailbox addresses' '' { param($value) @(Get-MRScope @($value)) -join ',' }
                return @{ MailboxMode = 'Paste'; Mailboxes = @($addresses -split ','); GroupAddress = '' }
            }
            default { Write-Warning 'Choose 1, 2, 3, or 4.' }
        }
    }
}

function Select-MRReportFile {
    if (-not $IsWindows) { Write-Warning 'The file picker requires Windows. Paste the report path instead.'; return '' }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'; $runspace.ThreadOptions = 'ReuseThread'
    $powershell = [powershell]::Create()
    try {
        $runspace.Open(); $powershell.Runspace = $runspace
        $null = $powershell.AddScript({
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = [Windows.Forms.OpenFileDialog]::new()
            try {
                $dialog.Title = 'Select the reviewed Purview metadata report'
                $dialog.Filter = 'CSV reports (*.csv)|*.csv'; $dialog.CheckFileExists = $true; $dialog.Multiselect = $false
                if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $dialog.FileName }
            } finally { $dialog.Dispose() }
        })
        $result = @($powershell.Invoke())
        if ($powershell.HadErrors) { throw 'The Windows file picker could not open. Paste the report path instead.' }
        if ($result.Count) { return [string]$result[0] }
        return ''
    }
    catch { Write-Warning $_.Exception.Message; return '' }
    finally { $powershell.Dispose(); $runspace.Dispose() }
}

function Read-MRReportPath {
    param([string]$Path)
    $explicitPath = -not [string]::IsNullOrWhiteSpace($Path)
    while ($true) {
        if (-not $Path) {
            $Path = (Read-MRAnswer 'Paste reviewed CSV path, or F for file picker (:cancel returns to menu)').Trim()
            if ($Path -ieq 'F') { $Path = Select-MRReportFile; if (-not $Path) { continue } }
        }
        $Path = $Path.Trim().Trim('"').Trim("'")
        try {
            $report = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($report.PSIsContainer -or $report.Extension -ine '.csv' -or -not $report.Length) { throw 'Choose a non-empty CSV metadata report.' }
            $sample = Import-Csv -LiteralPath $report.FullName -ErrorAction Stop | Select-Object -First 1
            if (-not $sample -or @($sample.PSObject.Properties).Count -lt 2) { throw 'The CSV needs headers and at least one metadata row.' }
            Write-Host "Report: $($report.FullName) ($($report.Length) bytes)"
            Write-Host "Columns: $($sample.PSObject.Properties.Name -join ', ')"
            return $report.FullName
        }
        catch { if ($explicitPath) { throw }; Write-Warning $_.Exception.Message; $Path = '' }
    }
}

function Show-MRQuickAction {
    param($Run, [string]$Directory)
    while ($true) {
        $choice = (Read-Host 'P: open Purview; E: evidence folder; T: ticket summary; C: copy summary; Enter: back').Trim()
        if (-not $choice -or $choice -in @(':cancel', ':back')) { return }
        try {
            switch ($choice.ToUpperInvariant()) {
                'P' {
                    $portal = [uri]$Run.PurviewUrl
                    if (-not $portal.IsAbsoluteUri -or $portal.Scheme -ne 'https' -or $portal.Host -ne 'purview.microsoft.com' -or $portal.UserInfo) { throw 'The saved portal link is invalid.' }
                    Start-Process -FilePath $portal.AbsoluteUri
                }
                'E' { Start-Process -FilePath $Directory }
                { $_ -in @('T', 'C') } {
                    $summaries = @(Get-ChildItem -LiteralPath $Directory -Filter 'ticket-summary-*.txt' -File | Sort-Object LastWriteTimeUtc -Descending)
                    if (-not $summaries.Count) { throw 'No ticket summary is saved yet. Use Status to generate one.' }
                    if ($_ -eq 'T') { Start-Process -FilePath $summaries[0].FullName }
                    else { Set-Clipboard -Value (Get-Content -LiteralPath $summaries[0].FullName -Raw); Write-Host 'Ticket summary copied.' }
                }
                default { Write-Warning 'Choose P, E, T, C, or Enter.' }
            }
        } catch { Write-Warning $_.Exception.Message }
    }
}

function Reset-MRPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not [IO.File]::Exists($fullPath) -or -not $PSCmdlet.ShouldProcess($fullPath, 'Reset defaults, preserving a backup')) { return }
    $lock = [IO.File]::Open("$fullPath.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $backup = "$fullPath.$([guid]::NewGuid().ToString('N')).reset.bak"
        [IO.File]::Move($fullPath, $backup)
        Write-Host "Defaults reset. Previous file preserved: $backup"
    } finally { $lock.Dispose() }
}

function Show-MRSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    if ($Options.NoSavedSettings) { Write-Host 'Saved settings are disabled by -NoSavedSettings for this session.'; return }
    while ($true) {
        $settings = @{}; $valid = $true
        try { $settings = Read-MRProfile $Options.SettingsPath }
        catch { $valid = $false; Write-Warning $_.Exception.Message }
        Write-Host "`nSettings: $($Options.SettingsPath)"
        if ($settings.Count) { foreach ($key in @('TenantId', 'UserPrincipalName', 'CaseName', 'PurviewUrl', 'DataDirectory')) { Write-Host "$key`: $($settings[$key])" } }
        else { Write-Host 'No usable saved defaults.' }
        $choice = (Read-MRAnswer 'E: edit defaults/evidence location; R: reset; Enter: back').Trim()
        if (-not $choice) { return }
        if ($choice -ieq 'R') {
            if ((Read-MRAnswer 'Type RESET to clear defaults while preserving a backup') -ceq 'RESET') { Reset-MRPreference $Options.SettingsPath -WhatIf:$WhatIfPreference -Confirm:$false }
            continue
        }
        if ($choice -ine 'E') { Write-Warning 'Choose E, R, or Enter.'; continue }
        if (-not $valid) { Write-Warning 'Reset the invalid settings first. The existing file will be preserved as a backup.'; continue }
        $tenant = Read-MRValidated 'Tenant ID (optional until first Search)' ([string]$settings.TenantId) { param($value) if ($value) { ([guid]::Parse($value)).ToString() } else { '' } }
        $upn = Read-MRValidated 'Administrator email (optional until first Search)' ([string]$settings.UserPrincipalName) { param($value) if ($value) { Get-MREmail $value } else { '' } }
        if ([bool]$tenant -ne [bool]$upn) { Write-Warning 'Supply both tenant and administrator, or leave both blank.'; continue }
        $case = Read-MRValidated 'Existing case' $(if ($settings.CaseName) { $settings.CaseName } else { $Options.CaseName }) { param($value) if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n\x00-\x1f]') { throw 'Enter an existing case name.' }; $value }
        $location = Read-MRValidated 'Approved evidence folder (absolute path)' $(if ($settings.DataDirectory) { $settings.DataDirectory } else { [IO.Path]::GetFullPath($Options.DataDirectory) }) { param($value) $value = $value.Trim('"'); if (-not [IO.Path]::IsPathFullyQualified($value)) { throw 'Enter an absolute folder path.' }; [IO.Path]::GetFullPath($value) }
        $updated = [ordered]@{ SchemaVersion = 2; TenantId = $tenant; UserPrincipalName = $upn; CaseName = $case; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; DataDirectory = $location }
        Save-MRPreference -Path $Options.SettingsPath -Settings $updated -WhatIf:$WhatIfPreference -Confirm:$false
        if ($WhatIfPreference) { return }
    }
}

function Invoke-MRMenu {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    $lastPath = ''; $base = $Options.Clone()
    if (-not $base.ContainsKey('ExplicitParameters')) { $base.ExplicitParameters = @($Options.Keys) }
    if (-not $base.ContainsKey('NoSavedSettings')) { $base.NoSavedSettings = $false }
    while ($true) {
        Write-Host "`nMicrosoft 365 Email Remediation Toolkit" -ForegroundColor Cyan
        Write-Host '1. Search; 2. Remove; 3. Status; 4. Clone; B. Browse runs/evidence; S. Settings; Q. Quit'
        Write-Host 'Type :cancel or :back at an action prompt to return here.'
        $choice = (Read-Host 'Choose an action').Trim()
        if ($choice -ieq 'Q' -or $choice -in @(':cancel', ':back')) { return }
        $actionOptions = $base.Clone(); $actionOptions.MenuAction = $true
        $forward = @{ WhatIf = $WhatIfPreference }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $forward.Confirm = $PSBoundParameters.Confirm }
        try {
            if ($choice -ieq 'S') { Show-MRSetting -Options $actionOptions @forward; continue }
            if ($choice -ieq 'B') {
                $root = $base.DataDirectory
                if (-not $base.NoSavedSettings -and 'DataDirectory' -notin $base.ExplicitParameters) {
                    $savedProfile = Read-MRProfile $base.SettingsPath
                    if ($savedProfile.ContainsKey('DataDirectory')) { $root = $savedProfile.DataDirectory }
                }
                $path = Select-MRRun $root
                if (-not $WhatIfPreference) { Show-MRQuickAction -Run (Read-MRRun $path) -Directory $path }
                continue
            }
            $actionOptions.Mode = switch ($choice) { '1' { 'Search' }; '2' { 'Remove' }; '3' { 'Status' }; '4' { 'Clone' }; default { '' } }
            if (-not $actionOptions.Mode) { Write-Warning 'Choose a listed action.'; continue }
            if ($lastPath -and $actionOptions.Mode -in @('Remove', 'Status', 'Clone') -and -not $actionOptions.RunPath) {
                if ((Read-MRAnswer 'Use the last run from this session? (y/N)') -ieq 'y') { $actionOptions.RunPath = $lastPath }
            }
            Invoke-MRWorkflow -Options $actionOptions @forward
        }
        catch [OperationCanceledException] { Write-Host 'Canceled. Returning to the menu.' }
        catch { Write-Warning "$($_.Exception.Message) Returning to the menu. Use Status for an interrupted search or removal." }
        finally { if ($actionOptions.ContainsKey('LastRunPath') -and (Test-Path -LiteralPath (Join-Path $actionOptions.LastRunPath 'run.json'))) { $lastPath = $actionOptions.LastRunPath } }
    }
}

function Save-MRSearchBaseline {
    param([string]$Directory, $Run, $Search, [switch]$Recovered)
    $path = Join-Path $Directory 'search.json'
    if (Test-Path -LiteralPath $path) { return }
    Test-MRSearch $Search $Run
    if ($Search.Status -ne 'Completed' -or @(Get-MRProperty $Search 'Errors' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) { throw 'Only a completed, error-free search can be finalized.' }
    if ($Recovered) {
        $events = @(Get-Content -LiteralPath (Join-Path $Directory 'events.jsonl') -ErrorAction Stop | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
        if (-not @($events | Where-Object Event -EQ 'SearchCreated').Count -or @($events | Where-Object Event -EQ 'PurgeSubmissionAttempt').Count) { throw 'Cannot recover the original baseline without a creation record, or after a removal submission attempt. Use the saved diagnostics.' }
    }
    Write-MRJson $path $Search
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    if ($locations.Count -and -not (Test-Path -LiteralPath (Join-Path $Directory 'location-counts.csv'))) { $locations | Export-Csv -LiteralPath (Join-Path $Directory 'location-counts.csv') -NoTypeInformation -NoClobber }
    if ($Recovered) {
        Write-MREvent $Directory 'SearchRecovered' @{ Items = $Search.Items; ResultKey = (Get-MRResultKey $Search) }
        Write-Host 'Completed search recovered. Review a fresh Purview report before using Remove.'
    }
}
