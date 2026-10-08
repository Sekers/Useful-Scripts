# Browse Purview cases and searches without changing them. New searches always go
# through the guided Search questions and get their own evidence and review.
function ConvertFrom-MRPurviewQuery {
    param([string]$Query)
    # Parse only this explicit grammar. Unsupported conditions must never be discarded.
    $atom = '(?:kind\s*:\s*email|from\s*:\s*(?:"[^"\r\n]+"|[^\s()"]+)|subject\s*:\s*"[^"\r\n]+"|received\s*(?:>=|<)\s*\d{4}-\d{2}-\d{2})'
    $term = '(?:' + $atom + '|\(\s*' + $atom + '\s*\))'
    $match = [regex]::Match($Query, '^\s*(?<Term>' + $term + ')(?:\s+AND\s+(?<Term>' + $term + '))*\s*$', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { throw 'This query cannot be copied automatically. Supported conditions are one from address, optional kind:email, a quoted subject, and paired received>= / received< UTC dates joined by AND. Start a new search instead.' }
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
    # Copies supported criteria into a new search. The guided questions ask only for the
    # ticket, then show the review screen, where anything can still be changed.
    param($Search, [string]$CaseName, [hashtable]$Options)
    if ([string]::IsNullOrWhiteSpace([string](Get-MRProperty $Search 'Name')) -or [string]::IsNullOrWhiteSpace($CaseName)) { throw 'The source search and standard case must have names.' }
    foreach ($property in @('SharePointLocation', 'OneDriveLocation', 'ExchangeLocationExclusion', 'SharePointLocationExclusion', 'HoldNames')) {
        if (@(Get-MRProperty $Search $property | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) { throw "This search cannot be copied automatically because $property is set. Start a new email-only search instead." }
    }
    $scope = @(Get-MRProperty $Search 'ExchangeLocation' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if (-not $scope.Count) { throw 'This search has no mailbox list to copy.' }
    $scope = @(Get-MRScope $scope)
    $criteria = ConvertFrom-MRPurviewQuery ([string](Get-MRProperty $Search 'ContentMatchQuery'))
    $draft = Get-MRPurviewNewDraft -CaseName $CaseName -Options $Options -Quiet
    foreach ($key in @('SenderAddress', 'Subject', 'ReceivedFrom', 'ReceivedThrough', 'AllDates')) { $draft[$key] = $criteria[$key] }
    $draft.Mailboxes = $scope
    $draft.MailboxMode = if ('All' -in $scope) { 'All' } else { 'Paste' }
    $draft.ScopeSelection = [pscustomobject]@{ Mailboxes = $scope; Metadata = [pscustomobject]@{ Mode = $(if ('All' -in $scope) { 'All' } else { 'CopiedFromPurview' }) } }
    $draft.WizardOnly = @('Ticket', 'TicketUrl', 'Review')
    $draft.ImportedFrom = [pscustomobject][ordered]@{
        ObservedUtc = [datetimeoffset]::UtcNow.ToString('o'); TenantId = $Options.TenantId
        CaseName = $CaseName; SearchName = $Search.Name; Query = $Search.ContentMatchQuery
        ExchangeLocation = $scope; Status = Get-MRProperty $Search 'Status'; Items = Get-MRProperty $Search 'Items'
    }
    return $draft
}

function Get-MRPurviewNewDraft {
    param([string]$CaseName, [hashtable]$Options, [switch]$Quiet)
    if ([string]::IsNullOrWhiteSpace($CaseName)) { throw 'Select an Active case before starting a new search.' }
    if (Test-MRSystemCase $CaseName) { throw 'The toolkit does not create searches in the built-in Content Search case, because they do not appear in the Purview portal there. Choose an incident case.' }
    $draft = $Options.Clone()
    $criteriaKeys = @('Ticket', 'TicketUrl', 'SenderAddress', 'Subject', 'ReceivedFrom', 'ReceivedThrough',
        'AllDates', 'Mailboxes', 'MailboxMode', 'GroupAddress', 'RunPath', 'ReportPath')
    foreach ($key in @('Subject', 'ImportedFrom', 'SourceRun', 'SourcePath', 'LastRunPath', 'ScopeSelection', 'WizardOnly')) { $draft.Remove($key) }
    foreach ($key in @('Ticket', 'TicketUrl', 'SenderAddress', 'ReceivedFrom', 'ReceivedThrough', 'GroupAddress', 'RunPath', 'ReportPath')) { $draft[$key] = '' }
    $draft.Mode = 'Search'; $draft.MenuAction = $true; $draft.CaseName = $CaseName; $draft.CaseLocked = $true
    $draft.SelectedCaseTenantId = $Options.TenantId
    $draft.AllDates = $false; $draft.Mailboxes = @('All'); $draft.MailboxMode = 'All'
    $draft.PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
    $draft.ExplicitParameters = @(@($Options.ExplicitParameters | Where-Object { $_ -notin $criteriaKeys }) +
        @('TenantId', 'UserPrincipalName', 'CaseName', 'PurviewUrl') | Sort-Object -Unique)
    if (-not $Quiet) { Write-Host "New search in case: $CaseName." }
    return $draft
}

function Get-MRPurviewCaseEntry {
    param([string]$CaseName, [string]$PreferredCase, [switch]$ForNewSearch)
    $cases = @(Get-MRComplianceCase -CaseType eDiscovery -ErrorAction Stop)
    $entries = @(foreach ($case in $cases) {
        $name = [string](Get-MRProperty $case 'Name')
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($CaseName -and $name -ine $CaseName) { continue }
        if ($ForNewSearch -and (Test-MRSystemCase $name)) { continue }
        $status = ([string](Get-MRProperty $case 'Status')).Trim()
        if (-not $status) { $status = 'Unknown' }
        $preferredLabel = if ($PreferredCase -and $name -ieq $PreferredCase) { ' | used last time' } else { '' }
        [pscustomobject]@{ Key = $name; Status = $status; Label = "$name | $status$preferredLabel"; SearchText = "$name $status" }
    })
    return @($entries | Sort-Object Key)
}

function Select-MRPurviewCaseName {
    param([string]$PreferredCase)
    Write-Host 'Choose the Purview case for this incident. A case is a folder that holds the searches for one incident. Type ? for how to make a new one.'
    $entries = @(Get-MRPurviewCaseEntry -PreferredCase $PreferredCase -ForNewSearch)
    Write-MRLog 'CasesListed' @{ Count = $entries.Count }
    if (-not $entries.Count) { throw 'No cases are available. Create a case without premium features in Purview (https://purview.microsoft.com/ediscovery/ > Cases > Create case), or check your case permissions, then try again.' }
    while ($true) {
        $selected = Select-MRList -Entries $entries -Title 'Purview cases' -CaseStatus Active
        $caseMatches = @($entries | Where-Object Key -EQ ([string]$selected.Key))
        if ($caseMatches.Count -ne 1) { throw 'The selected case is missing or ambiguous. No search was created.' }
        if ($caseMatches[0].Status -ine 'Active') {
            Write-MRText Retry 'Choose an Active case. To use a closed case, reopen it in Purview first.'
            continue
        }
        Write-Host "Case: $($caseMatches[0].Key)"
        return [string]$caseMatches[0].Key
    }
}

function Show-MRPurviewSearchDetail {
    param($Search, [string]$CaseName)
    Write-Host "`nCase: $CaseName`nSearch: $($Search.Name)`nStatus in PowerShell: $([string](Get-MRProperty $Search 'Status'))"
    Write-Host 'These counts come from PowerShell. A search made in the portal can show 0 here even when the portal found messages.'
    $labels = [ordered]@{ Items = 'Messages found'; Size = 'Total size (bytes)'; NumBindings = 'Mailboxes searched'; ContentMatchQuery = 'Query'; ExchangeLocation = 'Mailboxes'; SharePointLocation = 'SharePoint sites'; OneDriveLocation = 'OneDrive sites'; ExchangeLocationExclusion = 'Excluded mailboxes'; Errors = 'Errors' }
    foreach ($field in $labels.Keys) {
        $value = Get-MRProperty $Search $field
        $display = if ($null -eq $value) { 'not returned' } elseif (@($value).Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]($value -join ', '))) { 'none' } else { [string]($value -join ', ') }
        Write-Host "$($labels[$field]): $($display -replace '[\r\n\x00-\x1f]', ' ')"
    }
}

function Select-MRPurviewDraft {
    param([hashtable]$Options)
    $caseFilter = if ('CaseName' -in $Options.ExplicitParameters) { $Options.CaseName } else { '' }
    $caseEntries = @(Get-MRPurviewCaseEntry -CaseName $caseFilter)
    if (-not $caseEntries.Count) { Write-Host 'No cases are available. Check your Purview case permissions and any -CaseName filter.'; return }
    while ($true) {
        try { $selectedCase = Select-MRList -Entries $caseEntries -Title 'Purview cases' -CaseStatus Active }
        catch { if (Test-MRBackSignal $_) { return }; throw }
        $caseName = [string]$selectedCase.Key
        if ([string]::IsNullOrWhiteSpace($caseName) -or @($caseEntries | Where-Object Key -EQ $caseName).Count -ne 1) { throw 'The selected case is missing or ambiguous.' }
        $canCreate = $selectedCase.Status -ieq 'Active' -and -not (Test-MRSystemCase $caseName)
        $searches = @(Get-MRComplianceSearch -Case $caseName -ResultSize Unlimited -ErrorAction Stop)
        $entries = @(foreach ($search in $searches) {
            $name = [string](Get-MRProperty $search 'Name')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $status = [string](Get-MRProperty $search 'Status')
            [pscustomobject]@{ Key = $name; Label = "$name | $status"; SearchText = "$name $status" }
        })
        $entries = @($entries | Sort-Object Key)
        if (-not $entries.Count) { Write-Host "No searches were returned for '$caseName'." }
        if (Test-MRSystemCase $caseName) { Write-Host 'This is the built-in Content Search case. You can look at its searches here, but the toolkit creates new searches only in incident cases.' }
        while ($true) {
            try { $selected = Select-MRList -Entries $entries -Title "Searches in $caseName (choose one for details)" -AllowNewSearch:$canCreate }
            catch { if (Test-MRBackSignal $_) { break }; throw }
            if ([string](Get-MRProperty $selected 'Action') -eq 'NewSearch' -and $canCreate) { return Get-MRPurviewNewDraft -CaseName $caseName -Options $Options }
            $name = [string]$selected.Key
            if ([string]::IsNullOrWhiteSpace($name) -or @($entries | Where-Object Key -EQ $name).Count -ne 1) { throw 'The selected search is missing or ambiguous.' }
            $details = @(Get-MRComplianceSearch -Identity $name -Case $caseName -ErrorAction Stop)
            if ($details.Count -ne 1 -or [string](Get-MRProperty $details[0] 'Name') -ine $name) { throw 'Purview did not return exactly the selected search. Nothing was changed.' }
            $search = $details[0]
            $returnedCase = [string](Get-MRProperty $search 'CaseName')
            if ($returnedCase -and $returnedCase -ine $caseName) { throw 'Purview returned a search from a different case. Nothing was changed.' }
            Show-MRPurviewSearchDetail $search $caseName
            $draft = $null
            if ($canCreate) {
                try { $draft = Get-MRPurviewDraft -Search $search -CaseName $caseName -Options $Options }
                catch { Write-Host "Copying is not available for this search: $($_.Exception.Message)" }
            } elseif ($selectedCase.Status -ine 'Active') { Write-Host 'This case is not Active, so you can only look. Reopen it in Purview to add searches.' }
            while ($true) {
                Write-MRText Heading 'What next?'
                Write-Host '[P] Open the Purview portal'
                if ($canCreate) { Write-Host '[N] Start a new search in this case' }
                if ($draft) { Write-Host "[C] Copy this search's sender, subject, dates, and mailboxes into a new search" }
                Write-Host '[Enter] Back to the list of searches'
                $choice = (Read-MRAnswer 'Your choice' -NoBack).Trim()
                if (-not $choice -or $choice -ieq 'B') { break }
                if ($choice -ieq 'P') { Start-Process 'https://purview.microsoft.com/ediscovery/' | Out-Null; continue }
                if ($choice -ieq 'N' -and $canCreate) { return Get-MRPurviewNewDraft -CaseName $caseName -Options $Options }
                if ($choice -ieq 'C' -and $draft) { return $draft }
                Write-MRText Retry 'Type one of the letters shown, or press Enter.'
            }
        }
    }
}

function Invoke-MRPurviewBrowser {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Options, [hashtable]$SavedSettings = @{})
    if ($WhatIfPreference) { Write-Host 'Preview: browse Purview cases and searches and inspect a search. No sign-in, files, or service calls.'; return }
    if ('TenantId' -notin $Options.ExplicitParameters -and $SavedSettings['TenantId']) { $Options.TenantId = $SavedSettings['TenantId'] }
    if ('UserPrincipalName' -notin $Options.ExplicitParameters -and $SavedSettings['TenantId'] -and $SavedSettings['TenantId'] -eq $Options.TenantId) { $Options.UserPrincipalName = $SavedSettings['UserPrincipalName'] }
    if (-not $Options.TenantId -or -not $Options.UserPrincipalName) { Read-MRIdentityStep $Options }
    $Options.TenantId = Get-MRTenantId $Options.TenantId
    $Options.UserPrincipalName = Get-MREmail $Options.UserPrincipalName
    $null = Connect-MRPurview -UserPrincipalName $Options.UserPrincipalName -TenantId $Options.TenantId -ReadOnly
    while ($true) {
        $draft = Select-MRPurviewDraft -Options $Options
        if (-not $draft) { return }
        $workflowParameters = @{ Options = $draft }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $workflowParameters.Confirm = $PSBoundParameters.Confirm }
        try { Invoke-MRWorkflow @workflowParameters; return }
        catch {
            # B at the first question of the new search returns to the case list.
            if (-not (Test-MRBackSignal $_)) { throw }
        }
        finally { if ($draft.ContainsKey('LastRunPath')) { $Options.LastRunPath = $draft.LastRunPath } }
    }
}
