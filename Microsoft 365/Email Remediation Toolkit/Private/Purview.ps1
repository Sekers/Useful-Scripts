# Purview cases and searches: choosing or creating the case for a new search, and browsing
# without changing anything. New searches always go through the guided Search questions
# and get their own evidence and review.
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
    # Returns the chosen Active case, or '' when the operator chose to create a new case
    # instead (offered only with -AllowNewCase).
    param([string]$PreferredCase, [object[]]$Entries, [switch]$AllowNewCase)
    if ($null -eq $Entries) {
        $Entries = @(Get-MRPurviewCaseEntry -PreferredCase $PreferredCase -ForNewSearch)
        Write-MRLog 'CasesListed' @{ Count = $Entries.Count }
    }
    if (-not $Entries.Count) { throw 'No cases are available. Create a case without premium features in Purview (https://purview.microsoft.com/ediscovery/ > Cases > Create case), or check your case permissions, then try again.' }
    while ($true) {
        $selected = Select-MRList -Entries $Entries -Title 'Purview cases' -CaseStatus Active -AllowNewCase:$AllowNewCase
        if ([string](Get-MRProperty $selected 'Action') -eq 'NewCase') { return '' }
        $caseMatches = @($Entries | Where-Object Key -EQ ([string]$selected.Key))
        if ($caseMatches.Count -ne 1) { throw 'The selected case is missing or ambiguous. No search was created.' }
        if ($caseMatches[0].Status -ine 'Active') {
            Write-MRText Retry 'Choose an Active case. To use a closed case, reopen it in Purview first.'
            continue
        }
        Write-Host "Case: $($caseMatches[0].Key)"
        return [string]$caseMatches[0].Key
    }
}

function Test-MRCanCreateCase {
    # Purview offers New-ComplianceCase only to accounts with the Case Management role.
    return [bool](Get-Command New-MRComplianceCase -ErrorAction SilentlyContinue)
}

function ConvertTo-MRCaseName {
    # Purview case names are unique in the organization and at most 64 characters.
    param([string]$Value)
    $name = ([string]$Value).Trim()
    if (-not $name) { throw 'Type a name for the new case.' }
    if ($name.Length -gt 64) { throw "Use at most 64 characters. This name has $($name.Length)." }
    if ($name -match '[\x00-\x1f]') { throw 'Use only printable characters in the case name.' }
    if (Test-MRSystemCase $name) { throw 'Content Search is the name of the built-in case. Choose another name.' }
    return $name
}

function Read-MRNewCaseName {
    # A name that matches a case the account can see means that case: an Active one is
    # offered for use, so a duplicate is never made by accident.
    param([string]$Default, [object[]]$Entries)
    while ($true) {
        $name = Read-MRValidated 'Name for the new case' $Default { param($value) ConvertTo-MRCaseName $value } -HelpTopic NewCase `
            -Hint 'Up to 64 characters, such as "Ticket #5678 Phishing". With the ticket number in it, the next question suggests that number. The case is created when you accept the review.'
        $caseMatches = @($Entries | Where-Object Key -EQ $name)
        if (-not $caseMatches.Count) { return @{ CaseName = $name; NewCase = $true } }
        if ($caseMatches.Count -gt 1) { throw "More than one case is named '$name'. Nothing was created." }
        $existing = $caseMatches[0]
        if ($existing.Status -ine 'Active') {
            Write-MRText Retry "A case named '$($existing.Key)' already exists and is $($existing.Status). Reopen it in Purview, or type another name."
            $Default = ''; continue
        }
        try {
            $use = Read-MRValidated "A case named '$($existing.Key)' already exists. Use it? (Y/N)" 'Y' { param($value) if ($value -notin @('y', 'n', 'yes', 'no')) { throw 'Type Y or N.' }; $value.Substring(0, 1).ToUpperInvariant() }
        }
        catch { if (-not (Test-MRBackSignal $_)) { throw }; $Default = $name; continue }
        if ($use -eq 'Y') { return @{ CaseName = [string]$existing.Key; NewCase = $false } }
        $Default = ''
    }
}

function Read-MRCaseChoice {
    # The case for a new search: an Active case from the list, or a new case that is created
    # only when the operator accepts the review. B goes back one screen.
    param([string]$PreferredCase, [string]$CurrentCase, [bool]$CurrentIsNew)
    $canCreate = Test-MRCanCreateCase
    $entries = $null
    $screen = 'Choose'; $nameFrom = 'Choose'
    while ($true) {
        if ($screen -ne 'Choose' -and $null -eq $entries) {
            $entries = @(Get-MRPurviewCaseEntry -PreferredCase $PreferredCase -ForNewSearch)
            Write-MRLog 'CasesListed' @{ Count = $entries.Count }
        }
        if ($screen -eq 'List') {
            if (-not $entries.Count -and $canCreate) {
                Write-MRText Notice 'Your account has no cases to choose from yet, so create one.'
                $screen = 'Name'; $nameFrom = 'Choose'; continue
            }
            try { $name = Select-MRPurviewCaseName -Entries $entries -AllowNewCase:$canCreate }
            catch { if (Test-MRBackSignal $_) { $screen = 'Choose'; continue }; throw }
            if ($name) { return @{ CaseName = $name; NewCase = $false } }
            $screen = 'Name'; $nameFrom = 'List'; continue
        }
        if ($screen -eq 'Name') {
            $default = if ($CurrentIsNew) { $CurrentCase } else { '' }
            try { return Read-MRNewCaseName -Default $default -Entries $entries }
            catch { if (Test-MRBackSignal $_) { $screen = $nameFrom; continue }; throw }
        }
        Write-Host 'Which Purview case should hold this search? A case is a folder in Purview for the searches about one incident.'
        Write-Host '[1] Choose an existing case'
        $unavailable = if ($canCreate) { '' } else { ' (unavailable: your account does not have the Case Management role)' }
        Write-Host "[2] Create a new case$unavailable"
        if ($CurrentCase) { Write-Host "[Enter] Keep $(if ($CurrentIsNew) { "the new case '$CurrentCase'" } else { "'$CurrentCase'" })" }
        else { Write-Host '[Enter] Choose an existing case' }
        $answer = (Read-MRAnswer 'Case').Trim()
        if ($answer -eq '?') { Write-MRPromptHelp Case; continue }
        if (-not $answer -and $CurrentCase) { return @{ CaseName = $CurrentCase; NewCase = $CurrentIsNew } }
        if (-not $answer -or $answer -eq '1') { $screen = 'List'; continue }
        if ($answer -eq '2') {
            if ($canCreate) { $screen = 'Name'; $nameFrom = 'Choose' }
            else { Write-MRText Retry 'Your account cannot create cases. Choose 1, or ask an admin to make the case or to give you the Case Management role.' }
            continue
        }
        Write-MRText Retry 'Type 1 or 2, or press Enter.'
    }
}

function New-MRPurviewCase {
    # Creates the case for a new search, or uses the Active case that already has this name.
    # Runs only once the search is about to be created, so going back or canceling earlier
    # leaves nothing in Purview. Returns $true when it created the case.
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([bool])]
    param([string]$CaseName, [string]$Ticket)
    $CaseName = ConvertTo-MRCaseName $CaseName
    $existing = @(Get-MRPurviewCaseEntry -CaseName $CaseName)
    if ($existing.Count -gt 1) { throw "More than one case is named '$CaseName'. Nothing was created." }
    if ($existing.Count -eq 1) {
        if ($existing[0].Status -ine 'Active') { throw "The case '$CaseName' already exists and is $($existing[0].Status). Reopen it in Purview, or use another name." }
        Write-Host "The case '$CaseName' already exists, so the search goes there."
        Write-MRLog 'CaseReused' @{ Case = $CaseName }
        return $false
    }
    if (-not (Test-MRCanCreateCase)) { throw 'Your account cannot create Purview cases. That needs the Case Management role, which the eDiscovery Manager role group includes.' }
    if (-not $PSCmdlet.ShouldProcess($CaseName, 'Create a Purview eDiscovery case')) { throw [OperationCanceledException]::new('Canceled. No case or search was created.') }
    Write-MRLog 'CaseCreating' @{ Case = $CaseName; Ticket = $Ticket }
    try { $null = New-MRComplianceCase -Name $CaseName -CaseType eDiscovery -Description "Created by the Microsoft 365 Email Remediation Toolkit for ticket $Ticket." -ErrorAction Stop }
    catch {
        Write-MRLog 'CaseCreateFailed' @{ Case = $CaseName; Message = $_.Exception.Message }
        throw "Purview did not create the case '$CaseName': $($_.Exception.Message) Case names are unique across the organization, including cases you cannot see, so another name may work."
    }
    # Put a search only in a case Purview now lists as Active.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $created = @(Get-MRPurviewCaseEntry -CaseName $CaseName)
        if ($created.Count -eq 1 -and $created[0].Status -ieq 'Active') {
            Write-MRLog 'CaseCreated' @{ Case = $CaseName; Ticket = $Ticket }
            Write-MRText Success "Created the case '$CaseName'."
            return $true
        }
        if ($attempt -lt 3) { Start-Sleep -Seconds 2 }
    }
    throw "Purview created the case '$CaseName' but does not list it as Active yet. No search was created. Check the case in the portal, then choose it from the case list."
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
