# Prompts, lists, menus, and settings screens. Every answer is written to the session log.
# At any question: Enter keeps the value in [brackets], B goes back one step,
# ? shows help, and :cancel returns to the main menu. Typed answers ignore capitals.
function Get-MRBackSignal {
    $signal = [OperationCanceledException]::new('Went back one step.')
    $signal.Data['MRBack'] = $true
    return $signal
}

function Test-MRBackSignal {
    param($ErrorRecord)
    $exception = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    return ($exception -is [OperationCanceledException] -and $exception.Data.Contains('MRBack'))
}

function Read-MRAnswer {
    param([string]$Prompt, [switch]$NoBack)
    $answer = [string](Read-Host $Prompt)
    Write-MRLog 'Answer' @{ Prompt = $Prompt; Answer = $answer }
    $command = $answer.Trim()
    if ($command -ieq ':cancel' -or $command -ieq ':menu') { throw [OperationCanceledException]::new('Canceled. Back at the main menu.') }
    if (-not $NoBack -and ($command -ieq 'B' -or $command -ieq ':back')) { throw (Get-MRBackSignal) }
    return $answer
}

function Read-MRValidated {
    param([string]$Prompt, [string]$Default, [scriptblock]$Validate, [string]$HelpTopic, [string]$Hint)
    if ($Hint) { Write-MRText Hint $Hint }
    while ($true) {
        $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
        $answer = Read-MRAnswer $label
        if ($answer.Trim() -eq '?') {
            if ($HelpTopic) { Write-MRPromptHelp $HelpTopic } else { Write-Host 'Type an answer, press Enter to keep the value in [brackets], or B to go back.' }
            continue
        }
        $value = if ([string]::IsNullOrWhiteSpace($answer)) { $Default } else { $answer.Trim() }
        try { return & $Validate $value }
        catch [OperationCanceledException] { throw }
        catch {
            Write-MRText Retry $_.Exception.Message
            Write-MRLog 'AnswerRejected' @{ Prompt = $Prompt; Reason = $_.Exception.Message }
        }
    }
}

function Read-MRConfirmation {
    param([string]$Phrase, [string]$Prompt)
    $expected = ($Phrase -replace '\s+', ' ').Trim()
    while ($true) {
        $answer = ((Read-MRAnswer $Prompt) -replace '\s+', ' ').Trim()
        if ($answer -ieq $expected) { return }
        Write-MRText Retry "That does not match. Type $expected (capital letters do not matter), or B to go back."
    }
}

function Invoke-MRPromptSequence {
    # Runs related questions in order. B returns to the previous question in the group;
    # B at the first question leaves the group.
    param([scriptblock[]]$Prompts)
    $position = 0
    while ($position -lt $Prompts.Count) {
        try { & $Prompts[$position]; $position++ }
        catch {
            if (-not (Test-MRBackSignal $_) -or $position -eq 0) { throw }
            $position--
        }
    }
}

function Write-MRPromptHelp {
    param([ValidateSet('TenantId', 'Administrator', 'Case', 'EvidenceFolder', 'Ticket', 'TicketUrl', 'Sender', 'Subject', 'Dates', 'Mailboxes', 'Report', 'Removal')][string]$Topic)
    Write-Host ''
    switch ($Topic) {
        'TenantId' {
            Write-Host 'The Tenant ID identifies your Microsoft 365 organization. It looks like 11111111-2222-3333-4444-555555555555.'
            Write-Host 'Find it at https://entra.microsoft.com > Entra ID > Overview > Tenant ID. A domain name such as contoso.com will not work.'
        }
        'Administrator' {
            Write-Host 'The email address you use to sign in as an administrator, such as admin@contoso.com.'
            Write-Host 'The account needs the Purview eDiscovery Manager role (or Compliance Search) to search, and Search And Purge to delete.'
            Write-Host 'Role details: https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data#before-you-begin'
        }
        'Case' {
            Write-Host 'A case is a folder in Microsoft Purview that holds the searches for one incident.'
            Write-Host 'Pick the case for this incident. To make a new one, open https://purview.microsoft.com/ediscovery/ > Cases > Create case (leave premium features off), then come back.'
            Write-Host "The built-in Content Search case is not offered: searches the toolkit creates there do not appear in the Purview portal."
        }
        'EvidenceFolder' {
            Write-Host 'Each search gets its own folder here with its records, message trace lists, and ticket summaries.'
            Write-Host 'Press Enter to keep the folder shown, or type a full path such as C:\IncidentEvidence.'
        }
        'Ticket' {
            Write-Host 'Your helpdesk ticket or incident number, such as 5678 or INC-1234. It labels the search and its records.'
            Write-Host 'The toolkit does not change anything in your helpdesk.'
        }
        'TicketUrl' {
            Write-Host 'Optional link to the ticket, so the ticket summary can point back to it. It must start with https://.'
            Write-Host 'Works with any helpdesk. When the link contains the ticket number, the toolkit remembers the pattern'
            Write-Host '(for example https://helpdesk.example.com/view?ticket={ticket}) and fills in the next ticket number for you.'
            Write-Host 'Type NONE to leave it blank.'
        }
        'Sender' {
            Write-Host "The email address the message came from, such as phish@example.com. In Outlook, open the message and look at the address in angle brackets next to the sender's name."
            Write-Host 'A display name such as "Head of School" does not identify the sender.'
        }
        'Subject' {
            Write-Host 'Optional words from the subject line. Only messages whose subject contains these words are found.'
            Write-Host 'Leave it blank to find every message from the sender in the date range. Quotes and * are not allowed. Type NONE to clear it.'
        }
        'Dates' {
            Write-Host 'The first and last day the message arrived, as yyyy-MM-dd, in UTC (the time zone the search uses).'
            Write-Host 'Both days are included. If the message arrived late in the evening in the US, it may already be the next day in UTC; include both days.'
            Write-Host 'Type ALL at the first date to search every date. That is slower, and message trace can only check the last 90 days.'
        }
        'Mailboxes' {
            Write-Host 'Type one or more mailbox email addresses, separated by commas, such as alice@contoso.com, bob@contoso.com.'
            Write-Host 'To search everyone in a group, go back and choose the group option instead.'
        }
        'Report' {
            Write-Host 'In the Purview portal, open the search, choose Export, select "Export items report only", and download it from Process manager.'
            Write-Host 'Extract the download and choose the item list CSV (often named Items.csv). Instructions: https://learn.microsoft.com/en-us/purview/edisc-search-export'
        }
        'Removal' {
            Write-Host 'Permanent (HardDelete): users cannot get the messages back. Use this for phishing and harmful mail.'
            Write-Host 'Recoverable (SoftDelete): messages move to Recoverable Items, and users can restore them for a while (usually 14 days).'
            Write-Host 'Either way, holds and retention policies can keep copies inside Microsoft 365.'
        }
    }
}

function Write-MRText {
    # Each kind of message has one meaning and one color, set only here:
    #   Heading  cyan       screen titles, step headings, list titles
    #   Hint     dark gray  hints and background details
    #   Notice   yellow     needs your attention: a limitation, a sign-in window, a report needed
    #   Retry    yellow     the answer was not accepted; the question is asked again
    #   Success  green      something finished as intended
    #   Failure  red        an action failed
    #   Danger   red        the next step cannot be undone
    # Write-Warning ("WARNING:") is kept for problems found in the search data itself.
    param([ValidateSet('Heading', 'Hint', 'Notice', 'Retry', 'Success', 'Failure', 'Danger')][string]$Kind, [string]$Text)
    $color = switch ($Kind) {
        'Heading' { 'Cyan' }
        'Hint' { 'DarkGray' }
        'Success' { 'Green' }
        { $_ -in @('Failure', 'Danger') } { 'Red' }
        default { 'Yellow' }
    }
    if ($Kind -eq 'Heading') { $Text = "`n$Text" }
    Write-Host $Text -ForegroundColor $color
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
            $status = 'not finished'; $items = '?'
            if ($snapshots.Count) {
                $latest = Get-Content -LiteralPath $snapshots[0].FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                $status = [string](Get-MRProperty $latest 'Status'); $items = [string](Get-MRProperty $latest 'Items')
            }
            $purges = @(Get-ChildItem -LiteralPath $folder.FullName -Filter 'purge*.json' -File | Sort-Object LastWriteTimeUtc -Descending)
            $removal = 'not deleted'
            if ($purges.Count) {
                $latestPurge = Get-Content -LiteralPath $purges[0].FullName -Raw | ConvertFrom-Json -ErrorAction Stop
                $removal = "deletion $([string](Get-MRProperty $latestPurge 'Status'))"
            } elseif (Test-Path -LiteralPath (Join-Path $folder.FullName 'events.jsonl')) {
                $events = @(Get-Content -LiteralPath (Join-Path $folder.FullName 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
                if (@($events | Where-Object Event -EQ 'PurgeSubmissionAttempt').Count) { $removal = 'deletion submitted, outcome unknown' }
            }
            $subject = if ($run.Subject) { "subject '$($run.Subject)'" } else { 'any subject' }
            $label = "Ticket $($run.Ticket) | $($run.SenderAddress) | $subject | search $status, $items found | $removal | $($created.UtcDateTime.ToString('yyyy-MM-dd HH:mm')) UTC"
            [pscustomobject]@{ Key = $folder.FullName; Label = $label; SearchText = "$label $($run.SearchName) $($run.CaseName)"; Created = $created }
        }
        catch { Write-MRText Notice "Skipping unreadable run '$($folder.Name)': $($_.Exception.Message)" }
    })
    return @($entries | Sort-Object Created -Descending)
}

function Select-MRList {
    param([object[]]$Entries, [string]$Title, [switch]$Multiple, [switch]$AllowPath,
        [ValidateSet('', 'Active', 'Closed', 'All')][string]$CaseStatus = '', [switch]$AllowNewSearch)
    $Entries = @($Entries); $filter = ''; $page = 0; $size = 15
    $chosen = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($true) {
        $filtered = @($Entries | Where-Object {
            (-not $CaseStatus -or $CaseStatus -eq 'All' -or [string](Get-MRProperty $_ 'Status') -ieq $CaseStatus) -and
            ([string]$_.SearchText).IndexOf($filter, [StringComparison]::OrdinalIgnoreCase) -ge 0
        })
        $pages = [math]::Max(1, [int][math]::Ceiling($filtered.Count / $size))
        $page = [math]::Min($page, $pages - 1)
        $visible = @($filtered | Select-Object -Skip ($page * $size) -First $size)
        $details = @("page $($page + 1) of $pages", "$($filtered.Count) shown")
        if ($CaseStatus) { $details += "showing $($CaseStatus.ToLowerInvariant()) cases" }
        if ($filter) { $details += "filter '$filter'" }
        Write-MRText Heading "$Title ($($details -join ', '))"
        for ($index = 0; $index -lt $visible.Count; $index++) {
            $marker = if ($chosen.Contains([string]$visible[$index].Key)) { '[selected] ' } else { '' }
            Write-Host "[$($index + 1)] $marker$($visible[$index].Label -replace '[\r\n\x00-\x1f]', ' ')"
        }
        if (-not $visible.Count) {
            if ($CaseStatus) { Write-Host 'No cases match. Show other cases (A, L, or T), clear the filter with /, or go back with B.' }
            elseif ($AllowNewSearch) { Write-Host 'No searches match. Start a new search with S, clear the filter with /, or go back with B.' }
            else { Write-Host 'Nothing matches. Clear the filter with /, or go back with B.' }
        }
        if ($Multiple) {
            Write-Host "Selected so far: $($chosen.Count). Type numbers such as 1,3,5 to select or unselect them."
            Write-Host '[D] Done selecting'
            Write-Host '[X] Clear all selections'
        } elseif ($visible.Count) { Write-Host 'Type a number to choose.' }
        Write-Host '[/word] Show only entries containing a word (example: /smith); / alone shows everything'
        if ($AllowNewSearch) { Write-Host '[S] Start a new search in this case' }
        if ($CaseStatus) { Write-Host '[A] Active cases   [L] Closed cases   [T] All cases' }
        if ($pages -gt 1) { Write-Host '[N] Next page   [P] Previous page' }
        if ($AllowPath) { Write-Host '[Folder path] Open a run folder by its full path (example: C:\IncidentEvidence\run-folder)' }
        Write-Host '[B] Back'
        $answer = (Read-MRAnswer 'Your choice').Trim().Trim('"').Trim("'")
        if ($AllowNewSearch -and $answer -ieq 'S') { return [pscustomobject]@{ Action = 'NewSearch' } }
        if ($CaseStatus -and $answer -in @('A', 'L', 'T')) {
            $CaseStatus = switch ($answer) { 'A' { 'Active' } 'L' { 'Closed' } 'T' { 'All' } }
            $page = 0; continue
        }
        if ($answer.StartsWith('/')) { $filter = $answer.Substring(1).Trim(); $page = 0; continue }
        if ($answer -ieq 'N') { $page = [math]::Min($page + 1, $pages - 1); continue }
        if ($answer -ieq 'P') { $page = [math]::Max(0, $page - 1); continue }
        if ($Multiple -and $answer -ieq 'X') { $chosen.Clear(); continue }
        if ($Multiple -and $answer -ieq 'D') {
            if (-not $chosen.Count) { Write-MRText Retry 'Select at least one entry first.'; continue }
            return @($Entries | Where-Object { $chosen.Contains([string]$_.Key) })
        }
        if ($AllowPath -and [IO.Path]::IsPathFullyQualified($answer)) { return $answer }
        $numbers = @($answer -split ','); $valid = $true; $indexes = @()
        foreach ($number in $numbers) {
            $parsed = 0
            if (-not [int]::TryParse($number.Trim(), [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt $visible.Count) { $valid = $false; break }
            $indexes += $parsed - 1
        }
        if (-not $valid -or (-not $Multiple -and $indexes.Count -ne 1)) { Write-MRText Retry 'Type one of the numbers shown, or one of the letters in [brackets].'; continue }
        if (-not $Multiple) { return $visible[$indexes[0]] }
        foreach ($index in @($indexes | Sort-Object -Unique)) {
            $key = [string]$visible[$index].Key
            if (-not $chosen.Remove($key)) { $null = $chosen.Add($key) }
        }
    }
}

function Read-MRMailboxChoice {
    param([string[]]$CurrentMailboxes, [switch]$AllowKeep, [switch]$AllOnly)
    while ($true) {
        Write-Host 'Which mailboxes should the search look in?'
        Write-Host '[1] All mailboxes (best when the message went to many people)'
        $unavailable = if ($AllOnly) { ' (unavailable: Exchange Online did not sign in)' } else { '' }
        Write-Host "[2] Pick mailboxes from a list$unavailable"
        Write-Host "[3] Everyone in a group (distribution list, mail-enabled security group, or Microsoft 365 group)$unavailable"
        Write-Host "[4] Type or paste mailbox email addresses$unavailable"
        if ($AllowKeep) {
            $scope = if ($CurrentMailboxes -contains 'All') { 'all mailboxes' } else { "the same $(@($CurrentMailboxes).Count) mailbox(es)" }
            Write-Host "[Enter] Keep $scope"
        } else { Write-Host '[Enter] All mailboxes' }
        $choice = (Read-MRAnswer 'Mailboxes').Trim()
        if (-not $choice -and $AllowKeep) { return @{ Keep = $true } }
        if ($AllOnly -and $choice -in @('2', '3', '4')) {
            Write-MRText Retry 'Choosing particular mailboxes needs Exchange Online, which did not sign in. Choose 1 for all mailboxes, or press B and try again later.'
            continue
        }
        switch ($choice) {
            { $_ -in @('', '1') -or $_ -ieq 'ALL' } { return @{ MailboxMode = 'All'; Mailboxes = @('All'); GroupAddress = '' } }
            '2' { return @{ MailboxMode = 'Select'; GroupAddress = '' } }
            '3' { return @{ MailboxMode = 'Group'; GroupAddress = '' } }
            '4' {
                try {
                    $addresses = Read-MRValidated 'Mailbox addresses, separated by commas' '' { param($value) if ([string]::IsNullOrWhiteSpace($value)) { throw 'Type at least one address, or B to go back.' }; @(Get-MRScope @($value)) -join ',' } -HelpTopic Mailboxes
                    return @{ MailboxMode = 'Paste'; Mailboxes = @($addresses -split ','); GroupAddress = '' }
                }
                catch { if (-not (Test-MRBackSignal $_)) { throw } }
            }
            default { Write-MRText Retry 'Type 1, 2, 3, or 4, or press Enter.' }
        }
    }
}

function Select-MRReportFile {
    if (-not $IsWindows) { Write-MRText Notice 'The file picker requires Windows. Paste the report path instead.'; return '' }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'; $runspace.ThreadOptions = 'ReuseThread'
    $powershell = [powershell]::Create()
    try {
        $runspace.Open(); $powershell.Runspace = $runspace
        $null = $powershell.AddScript({
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = [Windows.Forms.OpenFileDialog]::new()
            try {
                $dialog.Title = 'Select the report exported from the Purview portal'
                $dialog.Filter = 'CSV reports (*.csv)|*.csv'; $dialog.CheckFileExists = $true; $dialog.Multiselect = $false
                if ($dialog.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { $dialog.FileName }
            } finally { $dialog.Dispose() }
        })
        $result = @($powershell.Invoke())
        if ($powershell.HadErrors) { throw 'The Windows file picker could not open. Paste the report path instead.' }
        if ($result.Count) { return [string]$result[0] }
        return ''
    }
    catch { Write-MRText Notice $_.Exception.Message; return '' }
    finally { $powershell.Dispose(); $runspace.Dispose() }
}

function Read-MRReportPath {
    param([string]$Path)
    $explicitPath = -not [string]::IsNullOrWhiteSpace($Path)
    if (-not $explicitPath) { Write-MRPromptHelp Report }
    while ($true) {
        if (-not $Path) {
            Write-Host '[F] Choose the CSV with a file picker'
            Write-Host '[Full path] Or paste the CSV path (example: C:\IncidentEvidence\Items.csv)'
            Write-Host '[B] Back'
            $Path = (Read-MRAnswer 'Report').Trim()
            if ($Path -ieq 'F') { $Path = Select-MRReportFile; if (-not $Path) { continue } }
        }
        $Path = $Path.Trim().Trim('"').Trim("'")
        try {
            $report = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($report.PSIsContainer -or $report.Extension -ine '.csv' -or -not $report.Length) { throw 'Choose a CSV file that is not empty.' }
            $sample = Import-Csv -LiteralPath $report.FullName -ErrorAction Stop | Select-Object -First 1
            if (-not $sample -or @($sample.PSObject.Properties).Count -lt 2) { throw 'The CSV needs column headings and at least one row.' }
            Write-Host "Report: $($report.FullName) ($($report.Length) bytes)"
            Write-Host "Columns: $($sample.PSObject.Properties.Name -join ', ')"
            return $report.FullName
        }
        catch { if ($explicitPath) { throw }; Write-MRText Retry $_.Exception.Message; $Path = '' }
    }
}

function Show-MRQuickAction {
    param($Run, [string]$Directory)
    while ($true) {
        Write-MRText Heading 'What next?'
        Write-Host '[P] Open the Purview portal'
        Write-Host '[E] Open this run''s evidence folder'
        Write-Host '[T] Open the latest ticket summary'
        Write-Host '[C] Copy the latest ticket summary to the clipboard'
        $review = Get-MRSavedTraceReview $Directory
        if ($review) { Write-Host '[L] List every message in the message trace review' }
        Write-Host '[Enter] Back to the main menu'
        # The action itself is finished; :cancel here only leaves this screen.
        try { $choice = (Read-MRAnswer 'Your choice' -NoBack).Trim() }
        catch [OperationCanceledException] { return }
        if (-not $choice -or $choice -ieq 'B') { return }
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
                    if (-not $summaries.Count) { throw 'No ticket summary is saved yet. Use Check status to create one.' }
                    if ($_ -eq 'T') { Start-Process -FilePath $summaries[0].FullName }
                    else { Set-Clipboard -Value (Get-Content -LiteralPath $summaries[0].FullName -Raw); Write-Host 'Ticket summary copied.' }
                }
                'L' { if ($review) { Show-MRTraceMessage $Directory $review } else { throw 'No message trace list is saved for this run.' } }
                default { Write-MRText Retry 'Type one of the letters shown, or press Enter.' }
            }
        } catch { Write-MRText Notice $_.Exception.Message }
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
        Write-Host "Saved settings cleared. The previous file is kept as $backup"
        Write-MRLog 'SettingsReset' @{ Backup = $backup }
    } finally { $lock.Dispose() }
}

function Edit-MRPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options, [hashtable]$Settings = @{})
    Write-Host 'Press Enter to keep a value. Leave the tenant and admin both blank to set only the evidence folder.'
    $state = @{
        TenantId = [string]$Settings['TenantId']; UserPrincipalName = [string]$Settings['UserPrincipalName']
        DataDirectory = $(if ($Settings['DataDirectory']) { $Settings['DataDirectory'] } else { [IO.Path]::GetFullPath($Options.DataDirectory) })
        TicketUrlTemplate = [string]$Settings['TicketUrlTemplate']
    }
    Invoke-MRPromptSequence @(
        { $state.TenantId = Read-MRValidated 'Tenant ID (optional)' $state.TenantId { param($value) if ($value -and $value -ine 'NONE') { Get-MRTenantId $value } else { '' } } -HelpTopic TenantId }
        {
            $state.UserPrincipalName = Read-MRValidated 'Admin sign-in email (optional)' $state.UserPrincipalName { param($value)
                $email = if ($value -and $value -ine 'NONE') { Get-MREmail $value } else { '' }
                if ([bool]$state.TenantId -ne [bool]$email) { throw 'Enter both the tenant and the admin email, or leave both blank.' }
                $email
            } -HelpTopic Administrator
        }
        { $state.DataDirectory = Read-MRValidated 'Evidence folder (full path)' $state.DataDirectory { param($value) $value = $value.Trim('"'); if (-not [IO.Path]::IsPathFullyQualified($value)) { throw 'Enter a full folder path, such as C:\IncidentEvidence.' }; [IO.Path]::GetFullPath($value) } -HelpTopic EvidenceFolder }
        {
            $state.TicketUrlTemplate = Read-MRValidated 'Ticket link pattern (optional)' $state.TicketUrlTemplate { param($value)
                if (-not $value -or $value -ieq 'NONE') { return '' }
                Test-MRTicketUrlTemplate $value
            } -HelpTopic TicketUrl -Hint 'Your helpdesk link with {ticket} where the ticket number goes, such as https://helpdesk.example.com/tickets/{ticket}. The toolkit also learns this from the first link you enter. NONE clears it.'
        }
    )
    $updated = [ordered]@{ SchemaVersion = 2; TenantId = $state.TenantId; UserPrincipalName = $state.UserPrincipalName; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; DataDirectory = $state.DataDirectory }
    if ($state.TicketUrlTemplate) { $updated.TicketUrlTemplate = $state.TicketUrlTemplate }
    # Keep the remembered case only while the tenant is unchanged.
    if ($Settings['TenantId'] -and $Settings['TenantId'] -eq $state.TenantId -and $Settings['CaseName']) { $updated.CaseName = $Settings['CaseName'] }
    if ($PSCmdlet.ShouldProcess($Options.SettingsPath, 'Save edited defaults')) {
        Save-MRPreference -Path $Options.SettingsPath -Settings $updated -Confirm:$false
    }
}

function Initialize-MRPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    if ($Options.NoSavedSettings -or $WhatIfPreference -or -not $Options.SettingsPath -or (Test-Path -LiteralPath $Options.SettingsPath)) { return }
    Write-Host "`nWelcome. The toolkit can remember your Tenant ID, admin account, and evidence folder so you do not retype them."
    Write-Host 'This only saves those settings on this computer. It does not sign in.'
    $answer = Read-MRValidated 'Set them up now? (Y/N)' 'Y' { param($value) if ($value -notin @('y', 'n', 'yes', 'no')) { throw 'Type Y or N.' }; $value.Substring(0, 1).ToUpperInvariant() }
    if ($answer -eq 'N') { Write-Host 'Skipped. The toolkit will ask for the tenant and admin when it needs them.'; return }
    $seed = @{}
    if ($Options.TenantId -and $Options.UserPrincipalName) { $seed.TenantId = $Options.TenantId; $seed.UserPrincipalName = $Options.UserPrincipalName }
    if ($PSCmdlet.ShouldProcess($Options.SettingsPath, 'Configure first-run defaults')) {
        Edit-MRPreference -Options $Options -Settings $seed -Confirm:$false
    }
}

function Show-MRSetting {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    if ($Options.NoSavedSettings) { Write-Host 'Saved settings are turned off for this session (-NoSavedSettings).'; return }
    while ($true) {
        $settings = @{}; $valid = $true
        try { $settings = Read-MRProfile $Options.SettingsPath }
        catch { $valid = $false; Write-MRText Notice $_.Exception.Message }
        Write-MRText Heading 'Settings'
        Write-Host "Saved in: $($Options.SettingsPath)"
        $labels = [ordered]@{ TenantId = 'Tenant ID'; UserPrincipalName = 'Admin sign-in email'; CaseName = 'Last case used'; TicketUrlTemplate = 'Ticket link pattern'; DataDirectory = 'Evidence folder' }
        foreach ($key in $labels.Keys) {
            $value = if ($settings[$key]) { $settings[$key] } else { 'not set' }
            Write-Host "$($labels[$key]): $value"
        }
        $logDirectory = [string]$Options['LogDirectory']
        if ($logDirectory) { Write-Host "Session logs: $logDirectory" }
        Write-Host '[E] Edit the tenant, admin account, evidence folder, and ticket link pattern'
        Write-Host '[R] Clear saved settings (a backup is kept)'
        if ($logDirectory) { Write-Host '[L] Open the session logs folder' }
        Write-Host '[Enter] Back to the main menu'
        try { $choice = (Read-MRAnswer 'Your choice' -NoBack).Trim() }
        catch [OperationCanceledException] { return }
        if (-not $choice -or $choice -ieq 'B') { return }
        if ($choice -ieq 'R') {
            try {
                Read-MRConfirmation 'RESET' 'Type RESET to clear saved settings, or B to go back'
                Reset-MRPreference $Options.SettingsPath -WhatIf:$WhatIfPreference -Confirm:$false
            } catch { if (-not (Test-MRBackSignal $_)) { throw } }
            continue
        }
        if ($choice -ieq 'L' -and $logDirectory) {
            if (Test-Path -LiteralPath $logDirectory) { Start-Process -FilePath $logDirectory } else { Write-Host 'No session logs have been written yet.' }
            continue
        }
        if ($choice -ine 'E') { Write-MRText Retry 'Type E, R, or L, or press Enter.'; continue }
        if (-not $valid) { Write-MRText Retry 'Clear the unreadable settings first with R. The old file is kept as a backup.'; continue }
        try { Edit-MRPreference -Options $Options -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false }
        catch { if (-not (Test-MRBackSignal $_)) { throw } }
        if ($WhatIfPreference) { return }
    }
}

function Write-MRMenu {
    Write-MRText Heading 'Microsoft 365 Email Remediation Toolkit'
    Write-Host 'Find harmful email, such as phishing, in your mailboxes and delete it after you review it.'
    $accounts = @(Get-MRSignedInAccount)
    if ($accounts.Count) { Write-MRText Hint "Signed in as $($accounts -join ', ')" }
    Write-Host '[1] New search: find messages from a sender (nothing is deleted)'
    Write-Host '[2] Delete: review a saved search and delete what it found'
    Write-Host '[3] Check status: see how a search or deletion is going'
    Write-Host '[4] Copy a search: start a new search from a saved one and change it'
    Write-Host '[5] Purview cases: browse cases and searches already in Microsoft Purview'
    Write-Host '[R] Saved runs: open evidence folders and ticket summaries'
    Write-Host '[S] Settings: tenant, admin account, evidence folder, and logs'
    if ($accounts.Count) { Write-Host '[O] Sign out of Microsoft 365 in this window' }
    Write-Host '[Q] Quit'
    Write-MRText Hint 'At any question: Enter keeps the value in [brackets], B goes back, ? shows help, :cancel returns here.'
}

function Invoke-MRMenu {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options)
    $lastPath = ''; $base = $Options.Clone()
    if (-not $base.ContainsKey('ExplicitParameters')) { $base.ExplicitParameters = @($Options.Keys) }
    if (-not $base.ContainsKey('NoSavedSettings')) { $base.NoSavedSettings = $false }
    try { Initialize-MRPreference -Options $base -WhatIf:$WhatIfPreference -Confirm:$false }
    catch [OperationCanceledException] { Write-Host 'Setup skipped. Use Settings later, or enter the tenant and admin when asked.' }
    catch { Write-MRText Notice "Settings were not saved: $($_.Exception.Message) Use Settings to try again." }
    $modes = @{ '1' = 'Search'; '2' = 'Remove'; '3' = 'Status'; '4' = 'Clone'; '5' = 'BrowsePurview' }
    while ($true) {
        Write-MRMenu
        # :cancel already means "back to this menu", so here it just shows the menu again.
        try { $choice = (Read-MRAnswer 'Choose an option' -NoBack).Trim() }
        catch [OperationCanceledException] { continue }
        if ($choice -ieq 'Q') {
            if (@(Get-MRSignedInAccount).Count) { Write-Host 'You are still signed in in this PowerShell window, so the next run will not ask again. Close the window or choose O first to sign out.' }
            return
        }
        $forward = @{ WhatIf = $WhatIfPreference }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $forward.Confirm = $PSBoundParameters.Confirm }
        if ($choice -ieq 'O') { Disconnect-MRSession; continue }
        if ($choice -ieq 'S') {
            try { Show-MRSetting -Options $base.Clone() @forward } catch { Write-MRText Failure $_.Exception.Message }
            continue
        }
        if ($choice -ieq 'R') {
            try {
                $root = $base.DataDirectory
                if (-not $base.NoSavedSettings -and 'DataDirectory' -notin $base.ExplicitParameters) {
                    # Unreadable settings must not hide the saved runs; use the default folder instead.
                    try {
                        $savedProfile = Read-MRProfile $base.SettingsPath
                        if ($savedProfile.ContainsKey('DataDirectory')) { $root = $savedProfile.DataDirectory }
                    }
                    catch { Write-MRText Notice "Saved settings could not be read, so the default evidence folder is shown: $($_.Exception.Message)" }
                }
                $path = Select-MRRun $root
                if (-not $WhatIfPreference) { Show-MRQuickAction -Run (Read-MRRun $path) -Directory $path }
            }
            catch [OperationCanceledException] { Write-Verbose 'Left the saved runs list.' }
            catch { Write-MRText Failure $_.Exception.Message }
            continue
        }
        if (-not $modes.ContainsKey($choice)) { Write-MRText Retry 'Type one of the numbers or letters shown.'; continue }
        $useLast = $false
        if ($lastPath -and $modes[$choice] -in @('Remove', 'Status', 'Clone') -and -not $base.RunPath) {
            try { $useLast = (Read-MRValidated 'Use the run you just worked on? (Y/N)' 'Y' { param($value) if ($value -notin @('y', 'n', 'yes', 'no')) { throw 'Type Y or N.' }; $value.Substring(0, 1).ToUpperInvariant() }) -eq 'Y' }
            catch [OperationCanceledException] { continue }
        }
        do {
            $retry = $false
            $actionOptions = $base.Clone(); $actionOptions.MenuAction = $true; $actionOptions.Mode = $modes[$choice]
            if ($useLast) { $actionOptions.RunPath = $lastPath; $useLast = $false }
            Write-MRLog 'ActionStarted' @{ Mode = $actionOptions.Mode }
            try {
                Invoke-MRWorkflow -Options $actionOptions @forward
                Write-MRLog 'ActionFinished' @{ Mode = $actionOptions.Mode; Outcome = 'Completed' }
            }
            catch [OperationCanceledException] {
                $back = Test-MRBackSignal $_
                Write-MRLog 'ActionFinished' @{ Mode = $actionOptions.Mode; Outcome = $(if ($back) { 'Back' } else { 'Canceled' }) }
                # B after choosing a saved run shows the run list again rather than the menu.
                if ($back -and $actionOptions.ContainsKey('PickedRun') -and $actionOptions.PickedRun) { $retry = $true }
                elseif (-not $back) { Write-Host $_.Exception.Message }
            }
            catch {
                Write-MRLog 'ActionFinished' @{ Mode = $actionOptions.Mode; Outcome = 'Failed'; Message = $_.Exception.Message }
                Write-MRText Failure "$($_.Exception.Message) Back at the main menu. For an interrupted search or deletion, use Check status."
            }
            finally { if ($actionOptions.ContainsKey('LastRunPath') -and (Test-Path -LiteralPath (Join-Path $actionOptions.LastRunPath 'run.json'))) { $lastPath = $actionOptions.LastRunPath } }
        } while ($retry)
    }
}
