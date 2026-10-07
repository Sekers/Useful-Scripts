# Browse service searches without changing them. New remediation runs use reviewed criteria.
function ConvertFrom-MRPurviewQuery {
    param([string]$Query)
    # Parse only this explicit grammar. Unsupported conditions must never be discarded.
    $atom = '(?:kind\s*:\s*email|from\s*:\s*(?:"[^"\r\n]+"|[^\s()"]+)|subject\s*:\s*"[^"\r\n]+"|received\s*(?:>=|<)\s*\d{4}-\d{2}-\d{2})'
    $term = '(?:' + $atom + '|\(\s*' + $atom + '\s*\))'
    $match = [regex]::Match($Query, '^\s*(?<Term>' + $term + ')(?:\s+AND\s+(?<Term>' + $term + '))*\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { throw 'This query cannot be copied automatically. Supported conditions are one from address, optional kind:email, a quoted subject, and paired received>= / received< UTC dates joined by AND. Use Search to build a new query manually.' }
    $values = @{}
    foreach ($capture in $match.Groups['Term'].Captures) {
        $value = $capture.Value.Trim()
        if ($value.StartsWith('(')) { $value = $value.Substring(1, $value.Length - 2).Trim() }
        $part = [regex]::Match($value, '^(?<Key>kind|from|subject|received)\s*(?<Operator>:|>=|<)\s*(?<Value>.+)$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $key = $part.Groups['Key'].Value.ToLowerInvariant() + $part.Groups['Operator'].Value
        if ($values.ContainsKey($key)) { throw 'Repeated query conditions cannot be copied automatically.' }
        $values[$key] = $part.Groups['Value'].Value.Trim('"')
    }
    if (-not $values.ContainsKey('from:')) { throw 'Automatic copying requires one sender email address.' }
    $hasFrom = $values.ContainsKey('received>='); $hasUntil = $values.ContainsKey('received<')
    if ($hasFrom -ne $hasUntil) { throw 'Automatic copying requires both received>= and received< dates, or no date restriction.' }
    $criteria = @{ SenderAddress = Get-MREmail $values['from:']; Subject = ''; ReceivedFrom = ''; ReceivedThrough = ''; AllDates = -not $hasFrom }
    if ($values.ContainsKey('subject:')) { $criteria.Subject = $values['subject:'] }
    if ($hasFrom) {
        $criteria.ReceivedFrom = (Get-MRDate $values['received>=']).ToString('yyyy-MM-dd')
        $criteria.ReceivedThrough = (Get-MRDate $values['received<']).AddDays(-1).ToString('yyyy-MM-dd')
    }
    $criteria.Query = New-MRQuery @criteria
    return $criteria
}

function Get-MRPurviewDraft {
    param($Search, [string]$CaseName, [hashtable]$Options)
    if ([string]::IsNullOrWhiteSpace([string](Get-MRProperty $Search 'Name')) -or [string]::IsNullOrWhiteSpace($CaseName)) { throw 'The source search and standard case must have names.' }
    foreach ($property in @('SharePointLocation', 'OneDriveLocation', 'ExchangeLocationExclusion', 'SharePointLocationExclusion', 'HoldNames')) {
        if (@(Get-MRProperty $Search $property | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) { throw "Cannot copy this search automatically because $property is configured. Build a new email-only Search manually." }
    }
    $scope = @(Get-MRProperty $Search 'ExchangeLocation' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (-not $scope.Count) { throw 'This search has no explicit Exchange mailbox scope to copy.' }
    $scope = @(Get-MRScope $scope)
    $criteria = ConvertFrom-MRPurviewQuery ([string](Get-MRProperty $Search 'ContentMatchQuery'))
    $draft = $Options.Clone()
    foreach ($key in @('SenderAddress', 'Subject', 'ReceivedFrom', 'ReceivedThrough', 'AllDates')) { $draft[$key] = $criteria[$key] }
    $draft.Mode = 'Search'; $draft.MenuAction = $false; $draft.RunPath = ''; $draft.CaseName = $CaseName
    $draft.PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; $draft.Mailboxes = $scope
    $draft.MailboxMode = if ('All' -in $scope) { 'All' } else { 'Paste' }; $draft.GroupAddress = ''
    $draft.ImportedFrom = [pscustomobject][ordered]@{
        ObservedUtc = [datetimeoffset]::UtcNow.ToString('o'); TenantId = $Options.TenantId
        CaseName = $CaseName; SearchName = $Search.Name; Query = $Search.ContentMatchQuery
        ExchangeLocation = $scope; Status = Get-MRProperty $Search 'Status'; Items = Get-MRProperty $Search 'Items'
    }
    $draft.ExplicitParameters = @($Options.ExplicitParameters + @('TenantId', 'UserPrincipalName', 'Ticket', 'TicketUrl', 'SenderAddress', 'Subject', 'ReceivedFrom', 'ReceivedThrough', 'AllDates', 'Mailboxes', 'MailboxMode', 'GroupAddress', 'CaseName', 'PurviewUrl') | Sort-Object -Unique)
    return $draft
}

function Get-MRPurviewNewDraft {
    param([string]$CaseName, [hashtable]$Options)
    if ([string]::IsNullOrWhiteSpace($CaseName)) { throw 'Select an Active case before starting a new search.' }
    $draft = $Options.Clone()
    $criteriaKeys = @('Ticket', 'TicketUrl', 'SenderAddress', 'Subject', 'ReceivedFrom', 'ReceivedThrough',
        'AllDates', 'Mailboxes', 'MailboxMode', 'GroupAddress', 'RunPath', 'ReportPath')
    foreach ($key in @('Subject', 'ImportedFrom', 'SourceRun', 'SourcePath', 'LastRunPath')) { $draft.Remove($key) }
    foreach ($key in @('Ticket', 'TicketUrl', 'SenderAddress', 'ReceivedFrom', 'ReceivedThrough', 'GroupAddress', 'RunPath', 'ReportPath')) { $draft[$key] = '' }
    $draft.Mode = 'Search'; $draft.MenuAction = $true; $draft.CaseName = $CaseName
    $draft.SelectedCaseTenantId = $Options.TenantId
    $draft.AllDates = $false; $draft.Mailboxes = @('All'); $draft.MailboxMode = 'All'
    $draft.PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
    $draft.ExplicitParameters = @(@($Options.ExplicitParameters | Where-Object { $_ -notin $criteriaKeys }) +
        @('TenantId', 'UserPrincipalName', 'CaseName', 'PurviewUrl') | Sort-Object -Unique)
    Write-Host "New search in case: $CaseName. Enter fresh criteria; the selected case will be kept."
    return $draft
}

function Get-MRPurviewCaseEntry {
    param([string]$CaseName, [string]$PreferredCase)
    $cases = @(Get-MRComplianceCase -CaseType eDiscovery -ErrorAction Stop)
    $entries = @(foreach ($case in $cases) {
        $name = [string](Get-MRProperty $case 'Name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($CaseName -and $name -ine $CaseName) { continue }
        $status = ([string](Get-MRProperty $case 'Status')).Trim()
        if (-not $status) { $status = 'Unknown' }
        $preferredLabel = if ($PreferredCase -and $name -ieq $PreferredCase) { ' | preferred case' } else { '' }
        [pscustomobject]@{ Key = $name; Status = $status; Label = "$name | $status$preferredLabel"; SearchText = "$name $status" }
    })
    return @($entries | Sort-Object Key)
}

function Select-MRPurviewCaseName {
    param([string]$PreferredCase)
    Write-MRPromptHelp CaseName
    $entries = @(Get-MRPurviewCaseEntry -PreferredCase $PreferredCase)
    if (-not $entries.Count) { throw 'No accessible standard cases were returned. Create a case without premium features in Purview or check case permissions, then retry Search.' }
    while ($true) {
        $selected = Select-MRList -Entries $entries -Title 'Choose the case for the new search' -CaseStatus Active
        $caseMatches = @($entries | Where-Object Key -EQ ([string]$selected.Key))
        if ($caseMatches.Count -ne 1) { throw 'The selected case is missing or ambiguous. No search was created.' }
        if ($caseMatches[0].Status -ine 'Active') {
            Write-Warning 'Choose an Active case for a new search. Closed cases can be reviewed in Browse Purview; reopen one in Purview if more work belongs there.'
            continue
        }
        Write-Host "New search will be created in case: $($caseMatches[0].Key)"
        return [string]$caseMatches[0].Key
    }
}

function Select-MRPurviewDraft {
    param([hashtable]$Options)
    $caseFilter = if ('CaseName' -in $Options.ExplicitParameters) { $Options.CaseName } else { '' }
    $caseEntries = @(Get-MRPurviewCaseEntry -CaseName $caseFilter)
    if (-not $caseEntries.Count) { Write-Host 'No accessible standard cases were returned. Check your Purview case permissions and any explicit -CaseName filter.'; return }
    while ($true) {
        try { $selectedCase = Select-MRList -Entries $caseEntries -Title 'Purview standard cases' -CaseStatus Active }
        catch [OperationCanceledException] { return }
        $caseName = [string]$selectedCase.Key
        if ([string]::IsNullOrWhiteSpace($caseName) -or @($caseEntries | Where-Object Key -EQ $caseName).Count -ne 1) { throw 'The selected case is missing or ambiguous.' }
        $caseIsActive = $selectedCase.Status -ieq 'Active'
        $searches = @(Get-MRComplianceSearch -Case $caseName -ResultSize Unlimited -ErrorAction Stop)
        $entries = @(foreach ($search in $searches) {
            $name = [string](Get-MRProperty $search 'Name')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $status = [string](Get-MRProperty $search 'Status')
            [pscustomobject]@{ Key = $name; Label = "$name | $status"; SearchText = "$name $status" }
        })
        $entries = @($entries | Sort-Object Key)
        if (-not $entries.Count) { Write-Host "No accessible searches were returned for '$caseName'." }
        while ($true) {
            try { $selected = Select-MRList -Entries $entries -Title "Searches in $caseName (select one for PowerShell counts and full details)" -AllowNewSearch:$caseIsActive }
            catch [OperationCanceledException] { break }
            if ([string](Get-MRProperty $selected 'Action') -eq 'NewSearch' -and $caseIsActive) { return Get-MRPurviewNewDraft -CaseName $caseName -Options $Options }
            $name = [string]$selected.Key
            if ([string]::IsNullOrWhiteSpace($name) -or @($entries | Where-Object Key -EQ $name).Count -ne 1) { throw 'The selected search is missing or ambiguous.' }
            $details = @(Get-MRComplianceSearch -Identity $name -Case $caseName -ErrorAction Stop)
            if ($details.Count -ne 1 -or [string](Get-MRProperty $details[0] 'Name') -ine $name) { throw 'Purview did not return exactly the selected search. Nothing was changed.' }
            $search = $details[0]
            $returnedCase = [string](Get-MRProperty $search 'CaseName')
            if ($returnedCase -and $returnedCase -ine $caseName) { throw 'Purview returned a search from a different case. Nothing was changed.' }
            Write-Host "`nCase: $caseName`nSearch: $name`nPowerShell status: $([string](Get-MRProperty $search 'Status'))"
            Write-Host 'These are PowerShell search estimates. Portal statistics and processes can differ; zero here does not establish that no messages match.'
            $labels = [ordered]@{ Items = 'Matching items'; Size = 'Matching size'; NumBindings = 'Searched locations'; ContentMatchQuery = 'Search query'; ExchangeLocation = 'Mailboxes'; SharePointLocation = 'SharePoint sites'; OneDriveLocation = 'OneDrive sites'; ExchangeLocationExclusion = 'Excluded mailboxes'; Errors = 'Search errors' }
            foreach ($field in $labels.Keys) {
                $value = Get-MRProperty $search $field
                $display = if ($null -eq $value) { 'not returned' } elseif (@($value).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]($value -join ', '))) { 'none' } else { [string]($value -join ', ') }
                Write-Host "$($labels[$field]): $($display -replace '[\r\n\x00-\x1f]', ' ')"
            }
            $draft = $null
            if ($caseIsActive) {
                try { $draft = Get-MRPurviewDraft -Search $search -CaseName $caseName -Options $Options }
                catch { Write-Host "Automatic remediation copy unavailable: $($_.Exception.Message)" }
            } else { Write-Host 'This case is not Active. Review its searches here; reopen the case in Purview before creating a new search in it.' }
            while ($true) {
                Write-Host "`nSearch actions" -ForegroundColor Cyan
                Write-Host '[P] Open Microsoft Purview'
                if ($caseIsActive) { Write-Host '[N] New search in this case, with fresh criteria' }
                if ($draft) { Write-Host '[C] Copy these criteria into a new remediation run' }
                else { Write-Host 'This existing search is view-only here. Copying requires supported criteria; a new search uses criteria you enter.' }
                Write-Host '[Enter] Return to the search list'
                try { $choice = (Read-MRAnswer 'Choose a search action').Trim() }
                catch [OperationCanceledException] { return }
                if (-not $choice) { break }
                if ($choice -ieq 'P') { Start-Process 'https://purview.microsoft.com/ediscovery/' | Out-Null; continue }
                if ($choice -ieq 'N' -and $caseIsActive) { return Get-MRPurviewNewDraft -CaseName $caseName -Options $Options }
                if ($choice -ine 'C') { Write-Warning 'Choose a listed action, or press Enter to return to searches.'; continue }
                if (-not $draft) { Write-Warning 'This search can be viewed, but its conditions cannot be copied automatically. Use Search to build reviewed criteria manually.'; continue }
                $draft.Ticket = Read-MRValidated 'Ticket or incident number for the new run' $Options.Ticket { param($value) if ($value -notmatch '^[A-Za-z0-9#][A-Za-z0-9._#-]{0,63}$' -or $value -notmatch '[A-Za-z0-9]') { throw 'Enter a valid ticket identifier of 1 to 64 characters.' }; $value } -HelpTopic Ticket
                $draft.TicketUrl = Read-MRValidated 'Ticket URL (optional)' $Options.TicketUrl { param($value) if ($value -and (-not ([uri]$value).IsAbsoluteUri -or ([uri]$value).Scheme -ne 'https')) { throw 'TicketUrl must be an absolute HTTPS URL.' }; $value } -HelpTopic TicketUrl
                $newQuery = New-MRQuery -SenderAddress $draft.SenderAddress -Subject $draft.Subject -ReceivedFrom $draft.ReceivedFrom -ReceivedThrough $draft.ReceivedThrough -AllDates:$draft.AllDates
                Write-Host "Original query: $($search.ContentMatchQuery)`nNew query (email only): $newQuery`nMailboxes: $($draft.Mailboxes -join ', ')`nEvidence folder: $($draft.DataDirectory)"
                Write-Host 'This creates a separate search. Review its fresh results and export a new report before Remove.'
                if ((Read-MRAnswer "Type CREATE $($draft.Ticket) to create the new search, or Enter to cancel").Trim() -cne "CREATE $($draft.Ticket)") { Write-Host 'Creation canceled.'; continue }
                return $draft
            }
        }
    }
}

function Invoke-MRPurviewBrowser {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options, [hashtable]$SavedSettings = @{})
    if ($WhatIfPreference) { Write-Host 'Offline preview: browse accessible standard Purview cases/searches and inspect a selected search. No sign-in, files, or service calls.'; return }
    if ('TenantId' -notin $Options.ExplicitParameters -and $SavedSettings['TenantId']) { $Options.TenantId = $SavedSettings['TenantId'] }
    if ($Options.Interactive -or -not $Options.TenantId) { $Options.TenantId = Read-MRValidated 'Expected tenant ID' $Options.TenantId { param($value) Get-MRTenantId $value } -HelpTopic TenantId }
    $Options.TenantId = Get-MRTenantId $Options.TenantId
    if ('UserPrincipalName' -notin $Options.ExplicitParameters -and $SavedSettings['TenantId'] -eq $Options.TenantId) { $Options.UserPrincipalName = $SavedSettings['UserPrincipalName'] }
    if ($Options.Interactive -or -not $Options.UserPrincipalName) { $Options.UserPrincipalName = Read-MRValidated 'Administrator sign-in email' $Options.UserPrincipalName { param($value) Get-MREmail $value } -HelpTopic Administrator }
    $Options.UserPrincipalName = Get-MREmail $Options.UserPrincipalName
    $connection = $null; $draft = $null
    try {
        $connection = Connect-MRPurview -UserPrincipalName $Options.UserPrincipalName -TenantId $Options.TenantId -ReadOnly
        $draft = Select-MRPurviewDraft -Options $Options
    }
    finally { if ($connection) { Disconnect-ExchangeOnline -ModulePrefix MR -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } }
    if ($draft) {
        $workflowParameters = @{ Options = $draft }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $workflowParameters.Confirm = $PSBoundParameters.Confirm }
        try { Invoke-MRWorkflow @workflowParameters }
        finally { if ($draft.ContainsKey('LastRunPath')) { $Options.LastRunPath = $draft.LastRunPath } }
    }
}
