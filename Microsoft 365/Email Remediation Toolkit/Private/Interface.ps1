# Interactive helpers. Directory reads and removal remain in the workflow.
function Read-MRAnswer {
    param([string]$Prompt)
    $answer = Read-Host $Prompt
    if ($answer.Trim() -in @(':cancel', ':back')) { throw [OperationCanceledException]::new('Action canceled. Returning to the menu.') }
    return $answer
}

function Read-MRValidated {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [string]$HelpTopic)
    if ($HelpTopic) { Write-MRPromptHelp $HelpTopic }
    while ($true) {
        $value = Read-MRDefault $Prompt $Default
        try { return & $Validate $value }
        catch [OperationCanceledException] { throw }
        catch { Write-Warning $_.Exception.Message }
    }
}

function Write-MRPromptHelp {
    param([ValidateSet('TenantId', 'Administrator', 'CaseName', 'EvidenceFolder', 'Ticket', 'TicketUrl', 'Sender', 'Subject', 'Dates', 'Mailboxes', 'Report')][string]$Topic)
    Write-Host ''
    switch ($Topic) {
        'TenantId' {
            Write-Host 'Tenant ID: the GUID for your Microsoft 365 organization. A tenant name or domain will not work.'
            Write-Host 'Example format: 11111111-1111-1111-1111-111111111111 (replace with your own Tenant ID).'
            Write-Host 'Find it: https://entra.microsoft.com > Entra ID > Overview > Properties > Tenant ID.'
            Write-Host 'Microsoft instructions: https://learn.microsoft.com/en-us/entra/fundamentals/how-to-find-tenant'
        }
        'Administrator' {
            Write-Host 'Use the sign-in email (user principal name) for your administrator account in this tenant.'
            Write-Host 'Example: admin@contoso.com. Use your sign-in address if it differs from your mailbox address.'
            Write-Host 'Check the account in Microsoft Entra: https://entra.microsoft.com'
            Write-Host 'Required Purview roles: https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data#before-you-begin'
        }
        'CaseName' {
            Write-Host 'Use the exact name of an existing Purview case without premium features. Example: Content Search.'
            Write-Host 'Find your case: https://purview.microsoft.com/ediscovery/'
            Write-Host 'If unsure, use [5] Browse Purview from the main menu to list the cases you can access.'
        }
        'EvidenceFolder' {
            Write-Host 'This folder stores run records, reports, and ticket summaries. Enter keeps the displayed AppData or saved location.'
            Write-Host 'To change it, enter a full folder path. Example: C:\IncidentEvidence'
        }
        'Ticket' {
            Write-Host 'Use your helpdesk ticket or incident identifier. Example: INC-1234.'
            Write-Host 'It labels the run and its evidence; it does not create or update a helpdesk ticket.'
        }
        'TicketUrl' {
            Write-Host 'Optional HTTPS link to the ticket. Example: https://helpdesk.example.com/tickets/1234'
            Write-Host 'Enter keeps the displayed link, or leaves it blank if none is shown.'
        }
        'Sender' {
            Write-Host 'Enter the actual sender email address from the message. Example: phish@example.com.'
            Write-Host 'A display name such as Head of School will not identify the sender address.'
        }
        'Subject' {
            Write-Host 'Enter a subject phrase without quotes or wildcards. Example: Updated cellphone #'
            Write-Host 'A phrase can also match longer subjects. Review the matched messages in Purview.'
        }
        'Dates' {
            Write-Host 'Use UTC calendar dates in yyyy-MM-dd format. Example: 2026-10-05.'
            Write-Host 'The whole last date is included. Convert the message time to UTC if it is shown in local time.'
            Write-Host 'To search one UTC day, enter the same first and last date. Type ALL at the first date for all dates.'
        }
        'Mailboxes' {
            Write-Host 'Paste individual mailbox email addresses separated by commas.'
            Write-Host 'Example: alice@contoso.com, bob@contoso.com'
            Write-Host 'Use [3] Members of a group to expand a group into individual mailboxes instead.'
        }
        'Report' {
            Write-Host 'In Purview, export the selected search using Export items report only, then download and extract the report.'
            Write-Host 'Review the item-level CSV for this exact search. Select that CSV, such as Items.csv.'
            Write-Host 'Export instructions: https://learn.microsoft.com/en-us/purview/edisc-search-export'
        }
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
        if (-not $visible.Count) { Write-Host 'No matching entries. Change or clear the filter, or cancel.' }
        if ($Multiple) {
            Write-Host "Selected: $($chosen.Count). Enter numbers such as 1,3,5 to select or deselect entries on this page."
            Write-Host '[D] Finish with the selected entries'
            Write-Host '[X] Clear all selections'
        } else { Write-Host 'Enter one displayed number to select an entry.' }
        Write-Host '[/text] Filter the list (example: /smith)'
        Write-Host '[/] Clear the filter'
        if ($pages -gt 1) {
            Write-Host '[N] Next page'
            Write-Host '[P] Previous page'
        }
        Write-Host '[C] Cancel this selection'
        if ($AllowPath) { Write-Host '[Full path] Open a saved run folder (example: C:\IncidentEvidence\run-folder)' }
        $answer = (Read-MRAnswer 'Selection or command').Trim().Trim('"').Trim("'")
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
        Write-Host "`nChoose which mailboxes to search" -ForegroundColor Cyan
        Write-Host '[1] All mailboxes in the tenant'
        Write-Host '[2] Select mailboxes from a searchable directory list'
        Write-Host '[3] Members of a group, with a resolved mailbox preview'
        Write-Host '[4] Paste individual mailbox addresses separated by commas'
        if ($AllowKeep) {
            $scope = if ($CurrentMailboxes -contains 'All') { 'all mailboxes' } else { "$($CurrentMailboxes.Count) individual mailboxes" }
            Write-Host "[Enter] Keep the saved scope: $scope"
        } else { Write-Host '[Enter] Use all mailboxes (default)' }
        $choice = (Read-MRAnswer 'Choose a mailbox scope').Trim()
        if (-not $choice -and $AllowKeep) { return $null }
        switch ($choice) {
            { $_ -in @('', '1', 'ALL') } { return @{ MailboxMode = 'All'; Mailboxes = @('All'); GroupAddress = '' } }
            '2' { return @{ MailboxMode = 'Select'; GroupAddress = '' } }
            '3' { return @{ MailboxMode = 'Group'; GroupAddress = '' } }
            '4' {
                $addresses = Read-MRValidated 'Comma-separated individual mailbox addresses' '' { param($value) @(Get-MRScope @($value)) -join ',' } -HelpTopic Mailboxes
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
    if (-not $explicitPath) { Write-MRPromptHelp Report }
    while ($true) {
        if (-not $Path) {
            Write-Host '[F] Choose the reviewed CSV with the Windows file picker'
            Write-Host '[Full path] Paste the reviewed CSV path (example: C:\IncidentEvidence\Items.csv)'
            Write-Host '[:cancel] Return to the main menu'
            $Path = (Read-MRAnswer 'Reviewed report selection').Trim()
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
        Write-Host "`nRun shortcuts" -ForegroundColor Cyan
        Write-Host '[P] Open Microsoft Purview'
        Write-Host "[E] Open this run's evidence folder"
        Write-Host '[T] Open the latest ticket summary'
        Write-Host '[C] Copy the latest ticket summary to the clipboard'
        Write-Host '[Enter] Return to the main menu'
        $choice = (Read-Host 'Choose a shortcut').Trim()
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

function Edit-MRPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options, [hashtable]$Settings = @{})
    Write-Host 'Enter keeps any displayed value. If no tenant/account values are shown, leave both blank to configure only the folder and case.'
    do {
        $tenant = Read-MRValidated 'Tenant ID (optional)' ([string]$Settings['TenantId']) { param($value) if ($value) { Get-MRTenantId $value } else { '' } } -HelpTopic TenantId
        $upn = Read-MRValidated 'Administrator sign-in email (optional)' ([string]$Settings['UserPrincipalName']) { param($value) if ($value) { Get-MREmail $value } else { '' } } -HelpTopic Administrator
        if ([bool]$tenant -ne [bool]$upn) { Write-Warning 'Supply both tenant and administrator, or leave both blank.' }
    } while ([bool]$tenant -ne [bool]$upn)
    $case = Read-MRValidated 'Existing Purview case name' $(if ($Settings['CaseName']) { $Settings['CaseName'] } else { $Options.CaseName }) { param($value) if ([string]::IsNullOrWhiteSpace($value) -or $value -match '[\r\n\x00-\x1f]') { throw 'Enter an existing case name.' }; $value } -HelpTopic CaseName
    $location = Read-MRValidated 'Evidence folder (full path)' $(if ($Settings['DataDirectory']) { $Settings['DataDirectory'] } else { [IO.Path]::GetFullPath($Options.DataDirectory) }) { param($value) $value = $value.Trim('"'); if (-not [IO.Path]::IsPathFullyQualified($value)) { throw 'Enter an absolute folder path.' }; [IO.Path]::GetFullPath($value) } -HelpTopic EvidenceFolder
    $updated = [ordered]@{ SchemaVersion = 2; TenantId = $tenant; UserPrincipalName = $upn; CaseName = $case; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; DataDirectory = $location }
    if ($PSCmdlet.ShouldProcess($Options.SettingsPath, 'Save edited defaults')) {
        Save-MRPreference -Path $Options.SettingsPath -Settings $updated -Confirm:$false
    }
}

function Initialize-MRPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    if ($Options.NoSavedSettings -or $WhatIfPreference -or -not $Options.SettingsPath -or (Test-Path -LiteralPath $Options.SettingsPath)) { return }
    Write-Host "`nNo saved settings were found at $($Options.SettingsPath)."
    Write-Host 'Setup saves tenant/account identifiers and the evidence folder. It does not sign in.'
    $answer = Read-MRValidated 'Set up saved defaults now? (Y/n)' 'y' { param($value) if ($value -notin @('y', 'n', 'yes', 'no')) { throw 'Enter Y or N.' }; $value }
    if ($answer -in @('n', 'no')) { Write-Host 'Setup skipped. Search and Purview browsing will ask for missing tenant/account details.'; return }
    $seed = @{}
    if ($Options.TenantId -and $Options.UserPrincipalName) { $seed.TenantId = $Options.TenantId; $seed.UserPrincipalName = $Options.UserPrincipalName }
    if ($PSCmdlet.ShouldProcess($Options.SettingsPath, 'Configure first-run defaults')) {
        Edit-MRPreference -Options $Options -Settings $seed -Confirm:$false
    }
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
        if ($settings.Count) {
            $labels = [ordered]@{ TenantId = 'Tenant ID'; UserPrincipalName = 'Administrator sign-in email'; CaseName = 'Purview case name'; PurviewUrl = 'Purview link'; DataDirectory = 'Evidence folder' }
            foreach ($key in $labels.Keys) {
                $value = if ($settings[$key]) { $settings[$key] } else { 'not configured' }
                Write-Host "$($labels[$key]): $value"
            }
        }
        else { Write-Host 'No usable saved defaults.' }
        Write-Host '[E] Edit saved defaults and evidence folder'
        Write-Host '[R] Reset saved defaults, preserving a backup'
        Write-Host '[Enter] Return to the main menu'
        $choice = (Read-MRAnswer 'Choose a settings action').Trim()
        if (-not $choice) { return }
        if ($choice -ieq 'R') {
            if ((Read-MRAnswer 'Type RESET to clear defaults while preserving a backup') -ceq 'RESET') { Reset-MRPreference $Options.SettingsPath -WhatIf:$WhatIfPreference -Confirm:$false }
            continue
        }
        if ($choice -ine 'E') { Write-Warning 'Choose E, R, or Enter.'; continue }
        if (-not $valid) { Write-Warning 'Reset the invalid settings first. The existing file will be preserved as a backup.'; continue }
        Edit-MRPreference -Options $Options -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false
        if ($WhatIfPreference) { return }
    }
}

function Invoke-MRMenu {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    $lastPath = ''; $base = $Options.Clone()
    if (-not $base.ContainsKey('ExplicitParameters')) { $base.ExplicitParameters = @($Options.Keys) }
    if (-not $base.ContainsKey('NoSavedSettings')) { $base.NoSavedSettings = $false }
    try { Initialize-MRPreference -Options $base -WhatIf:$WhatIfPreference -Confirm:$false }
    catch [OperationCanceledException] { Write-Host 'Setup canceled. Use Settings later, or supply tenant/account details when searching.' }
    catch { Write-Warning "Settings were not saved: $($_.Exception.Message) Use Settings to try again." }
    while ($true) {
        Write-Host "`nMicrosoft 365 Email Remediation Toolkit" -ForegroundColor Cyan
        Write-Host '[1] Search: create a new email search'
        Write-Host '[2] Remove: review a saved run and confirm message removal'
        Write-Host '[3] Status: refresh a saved run and its ticket summary'
        Write-Host '[4] Clone: adjust a saved run and create a separate search'
        Write-Host '[5] Browse Purview: view existing cases and searches'
        Write-Host '[B] Browse local runs: open saved evidence and summaries'
        Write-Host '[S] Settings: edit tenant, account, case, and evidence folder'
        Write-Host '[Q] Quit'
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
            $actionOptions.Mode = switch ($choice) { '1' { 'Search' }; '2' { 'Remove' }; '3' { 'Status' }; '4' { 'Clone' }; '5' { 'BrowsePurview' }; default { '' } }
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
