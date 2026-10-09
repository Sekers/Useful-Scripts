#Requires -Version 7.4
<#
.SYNOPSIS
    Find harmful email, such as phishing, in Exchange Online mailboxes and delete it after review.
.DESCRIPTION
    Run without parameters for a guided menu. A search never deletes mail. Before deleting,
    the toolkit reruns the search, shows what Exchange message trace says the sender
    delivered (subjects and mailboxes), compares the two per mailbox, and asks for a typed
    confirmation. Uses Microsoft Purview searches without premium eDiscovery features.
    Every answer and action is written to a session log. See README.md.
.EXAMPLE
    .\Invoke-MailRemediation.ps1
.EXAMPLE
    .\Invoke-MailRemediation.ps1 -Mode Search -CaseName 'INC-1234 Phishing' -Ticket INC-1234 `
        -UserPrincipalName admin@contoso.com -TenantId 11111111-1111-1111-1111-111111111111 `
        -SenderAddress suspicious@example.com -Subject 'Update your details' `
        -ReceivedFrom 2026-10-05 -ReceivedThrough 2026-10-06 -WhatIf
.EXAMPLE
    .\Invoke-MailRemediation.ps1 -Mode Remove `
        -RunPath (Join-Path $env:LOCALAPPDATA 'M365-EmailRemediationToolkit\Runs\MR-INC-1234-example')
.NOTES
    No Graph permissions, billing setup, application secrets, or local elevation.
    Requires ExchangeOnlineManagement 3.9.0+ and Purview role assignments.
    HardDelete removes user access; holds and recovery can retain service copies.
    Documentation: https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Menu', 'Search', 'Clone', 'Remove', 'Status', 'BrowsePurview', 'SignOut')][string]$Mode = 'Menu',
    [string]$Ticket,
    [string]$TicketUrl,
    [string]$UserPrincipalName,
    [string]$TenantId,
    [string]$SenderAddress,
    [string]$Subject,
    [string]$ReceivedFrom,
    [string]$ReceivedThrough,
    [switch]$AllDates,
    [string[]]$Mailboxes = @('All'),
    [ValidateSet('All', 'Select', 'Group', 'Paste')][string]$MailboxMode = 'Paste',
    [string]$GroupAddress,
    [string]$CaseName = '',
    [switch]$CreateCase,
    [string]$PurviewUrl = 'https://purview.microsoft.com/ediscovery/',
    [string]$RunPath,
    [string]$ReportPath,
    [ValidateSet('HardDelete', 'SoftDelete')][string]$PurgeType = 'HardDelete',
    [string]$DataDirectory = (Join-Path ([environment]::GetFolderPath('LocalApplicationData')) 'M365-EmailRemediationToolkit\Runs'),
    [string]$SettingsPath = (Join-Path ([environment]::GetFolderPath('LocalApplicationData')) 'M365-EmailRemediationToolkit\settings.json'),
    [string]$LogDirectory = (Join-Path ([environment]::GetFolderPath('LocalApplicationData')) 'M365-EmailRemediationToolkit\Logs'),
    [switch]$NoSavedSettings,
    [ValidateRange(30, 7200)][int]$TimeoutSeconds = 1800,
    [ValidateRange(1, 30)][int]$PollSeconds = 5
)

$script:MRToolkitVersion = '2026.10.08'

function Get-MRProperty {
    param($Object, [string]$Name)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.$Name
    }
    return $null
}

function Get-MREmail {
    param([string]$Value)
    $valueTrimmed = $Value.Trim()
    if ($valueTrimmed -notmatch '^[A-Za-z0-9.!#$%&''+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,63}$') {
        throw "Enter one email address, without a display name or wildcards: '$Value'."
    }
    return $valueTrimmed.ToLowerInvariant()
}

function Get-MRTenantId {
    param([string]$Value)
    $tenant = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$tenant)) {
        throw 'Enter the Tenant ID, a GUID such as 11111111-2222-3333-4444-555555555555. Type ? to see where to find it.'
    }
    return $tenant.ToString()
}

function Get-MRDate {
    param([string]$Value)
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw 'Enter a real date as yyyy-MM-dd, such as 2026-10-05.'
    }
    return $date
}

function Test-MRTicketUrlTemplate {
    param([string]$Template)
    $value = $Template.Trim()
    if (([regex]::Matches($value, '\{ticket\}')).Count -ne 1) { throw 'Put {ticket} once, where the ticket number goes.' }
    $uri = $null
    if (-not [uri]::TryCreate($value.Replace('{ticket}', '1'), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'The pattern must be a full https:// address.' }
    return $value
}

function Get-MRTicketUrlTemplate {
    # Learns a link pattern for any helpdesk whose links contain the ticket number once.
    param([string]$Ticket, [string]$Url)
    if (-not $Ticket -or -not $Url) { return '' }
    foreach ($form in @(@($Ticket, [uri]::EscapeDataString($Ticket)) | Select-Object -Unique)) {
        $found = [regex]::Matches($Url, '(?<![A-Za-z0-9])' + [regex]::Escape($form) + '(?![A-Za-z0-9])', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($found.Count -ne 1) { continue }
        $template = $Url.Substring(0, $found[0].Index) + '{ticket}' + $Url.Substring($found[0].Index + $found[0].Length)
        try { return Test-MRTicketUrlTemplate $template } catch { return '' }
    }
    return ''
}

function Read-MRProfile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $settings = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $allowed = @('SchemaVersion', 'TenantId', 'UserPrincipalName', 'CaseName', 'PurviewUrl', 'DataDirectory', 'TicketUrlTemplate')
    if ($settings -isnot [hashtable] -or $settings.SchemaVersion -notin @(1, 2) -or
        @($settings.Keys | Where-Object { $_ -notin $allowed }).Count) {
        throw 'Unsupported settings format. The existing file will be preserved.'
    }
    if ($settings.TenantId -or $settings.UserPrincipalName -or $settings.SchemaVersion -eq 1) {
        $settings.TenantId = ([guid]::Parse($settings.TenantId)).ToString()
        $settings.UserPrincipalName = Get-MREmail $settings.UserPrincipalName
    }
    if ($settings.ContainsKey('CaseName')) {
        if ([string]$settings.CaseName -match '[\r\n\x00-\x1f]') { throw 'The saved case name is invalid.' }
        # The built-in Content Search case is never a destination for new searches.
        if ([string]::IsNullOrWhiteSpace([string]$settings.CaseName) -or (Test-MRSystemCase $settings.CaseName)) { $settings.Remove('CaseName') }
    }
    if ($settings.ContainsKey('PurviewUrl') -and $settings.PurviewUrl) {
        $portal = [uri]$settings.PurviewUrl
        if (-not $portal.IsAbsoluteUri -or $portal.Scheme -ne 'https' -or $portal.Host -ne 'purview.microsoft.com' -or $portal.UserInfo) {
            throw 'The saved Purview link is invalid.'
        }
    }
    # A run-specific deep link must never become a default for a different search.
    $settings.PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
    if ($settings.ContainsKey('TicketUrlTemplate')) {
        if ([string]::IsNullOrWhiteSpace([string]$settings.TicketUrlTemplate)) { $settings.Remove('TicketUrlTemplate') }
        else { $settings.TicketUrlTemplate = Test-MRTicketUrlTemplate $settings.TicketUrlTemplate }
    }
    if ($settings.ContainsKey('DataDirectory')) {
        if (-not [IO.Path]::IsPathFullyQualified([string]$settings.DataDirectory)) { throw 'The saved evidence location must be an absolute path.' }
        $settings.DataDirectory = [IO.Path]::GetFullPath($settings.DataDirectory)
    }
    return $settings
}

function Save-MRProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, $Run, [string]$UserPrincipalName, [string]$DataDirectory)
    $portal = [uri]$Run.PurviewUrl
    if (-not $portal.IsAbsoluteUri -or $portal.Scheme -ne 'https' -or $portal.Host -ne 'purview.microsoft.com' -or $portal.UserInfo) { throw 'The saved Purview link is invalid.' }
    $previous = @{}
    if (Test-Path -LiteralPath $Path) { try { $previous = Read-MRProfile $Path } catch { $previous = @{} } }
    $settings = [ordered]@{
        SchemaVersion = 1; TenantId = ([guid]::Parse($Run.TenantId)).ToString()
        UserPrincipalName = Get-MREmail $UserPrincipalName; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
    }
    if ($Run.CaseName -and -not (Test-MRSystemCase $Run.CaseName)) { $settings.CaseName = $Run.CaseName }
    $template = Get-MRTicketUrlTemplate -Ticket $Run.Ticket -Url $Run.TicketUrl
    if (-not $template -and $previous['TicketUrlTemplate']) { $template = $previous['TicketUrlTemplate'] }
    if ($template) { $settings.SchemaVersion = 2; $settings.TicketUrlTemplate = $template }
    if ($DataDirectory) { $settings.SchemaVersion = 2; $settings.DataDirectory = [IO.Path]::GetFullPath($DataDirectory) }
    Save-MRPreference -Path $Path -Settings $settings -WhatIf:$WhatIfPreference -Confirm:$false
}

function Save-MRPreference {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [System.Collections.IDictionary]$Settings)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetExtension($fullPath) -ine '.json') { throw 'SettingsPath must name a JSON file.' }
    if (-not $PSCmdlet.ShouldProcess($fullPath, 'Save non-secret tenant defaults')) { return }
    $parent = [IO.Path]::GetDirectoryName($fullPath)
    $null = [IO.Directory]::CreateDirectory($parent)
    $lock = $null
    $temporaryPath = $null
    try {
        $lock = [IO.File]::Open("$fullPath.lock", 'OpenOrCreate', 'ReadWrite', 'None')
        $previous = Read-MRProfile $fullPath
        $temporaryPath = Join-Path $parent ("settings-$([guid]::NewGuid().ToString('N')).tmp.json")
        Write-MRJson $temporaryPath $Settings
        # Compare as read back, so normalized values do not cause a needless rewrite and backup.
        $written = Read-MRProfile $temporaryPath
        if ($written.Count -eq $previous.Count -and -not @($written.Keys | Where-Object { [string]$written[$_] -cne [string]$previous[$_] }).Count) { return }
        if (Test-Path -LiteralPath $fullPath) {
            # Replacement is atomic and keeps the previous file as a new backup.
            [IO.File]::Replace($temporaryPath, $fullPath, "$fullPath.$([guid]::NewGuid().ToString('N')).bak")
        } else { [IO.File]::Move($temporaryPath, $fullPath) }
        Write-Host "Settings saved: $fullPath"
        Write-MRLog 'SettingsSaved' @{ Path = $fullPath; Keys = @($Settings.Keys) }
    }
    finally {
        if ($temporaryPath -and [IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ($lock) { $lock.Dispose() }
    }
}

function New-MRQuery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string without changing state.')]
    [CmdletBinding()]
    param([string]$SenderAddress, [string]$Subject, [string]$ReceivedFrom,
        [string]$ReceivedThrough, [switch]$AllDates)
    $normalizedSender = Get-MREmail $SenderAddress
    # Values are literal phrases. Do not silently rewrite input or accept raw KQL.
    if ($Subject -match '["*\r\n\x00-\x1f\u201c\u201d]') {
        throw 'Subject cannot contain double quotes, wildcards, smart double quotes, or control characters. Use plain words from the subject instead.'
    }
    $clauses = @('kind:email', ('from:"{0}"' -f $normalizedSender))
    if (-not [string]::IsNullOrWhiteSpace($Subject)) {
        $clauses += 'subject:"{0}"' -f $Subject.Trim()
    }
    if ($AllDates) {
        if ($ReceivedFrom -or $ReceivedThrough) { throw 'Use either AllDates or a date range.' }
    }
    else {
        if (-not $ReceivedFrom -or -not $ReceivedThrough) { throw 'Both UTC calendar dates are required unless AllDates is explicitly selected.' }
        $from = Get-MRDate $ReceivedFrom
        $through = Get-MRDate $ReceivedThrough
        if ($through -lt $from) { throw 'The end date must be on or after the start date.' }
        $clauses += 'received>={0}' -f $from.ToString('yyyy-MM-dd')
        $clauses += 'received<{0}' -f $through.AddDays(1).ToString('yyyy-MM-dd')
    }
    return $clauses -join ' AND '
}

function Get-MRScope {
    param([string[]]$Mailboxes)
    $Mailboxes = @($Mailboxes | ForEach-Object { $_ -split ',' | ForEach-Object { $_.Trim() } } | Where-Object { $_ })
    if ($Mailboxes.Count -eq 0) { throw 'A mailbox scope is required.' }
    if ('All' -in $Mailboxes) {
        if ($Mailboxes.Count -ne 1) { throw 'All cannot be combined with individual mailboxes.' }
        return 'All'
    }
    return @($Mailboxes | ForEach-Object { Get-MREmail $_ } | Sort-Object -Unique)
}

function Get-MRCloneOption {
    param($Source, [hashtable]$Options)
    $clone = @{}
    foreach ($key in $Options.Keys) { $clone[$key] = $Options[$key] }
    $explicit = @($Options.ExplicitParameters)
    if ('TenantId' -in $explicit -and [guid]$Options.TenantId -ne [guid]$Source.TenantId) {
        throw 'Copying stays in the original tenant. Use New search for a different tenant.'
    }
    $clone.TenantId = $Source.TenantId
    foreach ($name in @('Ticket', 'TicketUrl', 'SenderAddress', 'Subject', 'Mailboxes', 'CaseName')) {
        if ($name -notin $explicit) { $clone[$name] = $Source.$name }
    }
    # An original search deep link would point to the wrong search after copying.
    if ('PurviewUrl' -notin $explicit) { $clone.PurviewUrl = 'https://purview.microsoft.com/ediscovery/' }
    foreach ($name in @('ReceivedFrom', 'ReceivedThrough')) {
        if ($name -notin $explicit) { $clone[$name] = $Source.$name }
    }
    if ('AllDates' -notin $explicit) {
        $clone.AllDates = if ('ReceivedFrom' -in $explicit -or 'ReceivedThrough' -in $explicit) { $false } else { [bool]$Source.AllDates }
    }
    if ($clone.AllDates) {
        foreach ($name in @('ReceivedFrom', 'ReceivedThrough')) {
            if ($name -notin $explicit) { $clone[$name] = '' }
        }
    }
    # Inherited criteria belong to the selected run, rather than saved defaults.
    $clone.ExplicitParameters = @($explicit + @('TenantId', 'Ticket', 'TicketUrl', 'SenderAddress',
        'Subject', 'Mailboxes', 'CaseName', 'PurviewUrl', 'ReceivedFrom', 'ReceivedThrough', 'AllDates') | Sort-Object -Unique)
    $clone.SourceRun = $Source
    if ('GroupAddress' -in $explicit -and 'MailboxMode' -notin $explicit) { $clone.MailboxMode = 'Group' }
    # Keep the original mailbox list, and its group snapshot, unless a different scope was given.
    if (-not @(@('Mailboxes', 'MailboxMode', 'GroupAddress') | Where-Object { $_ -in $explicit }).Count) {
        $sourceScope = @($Source.Mailboxes)
        $sourceSelection = Get-MRProperty $Source 'ScopeSelection'
        $clone.MailboxMode = if ('All' -in $sourceScope) { 'All' } else { 'Paste' }
        $clone.ScopeSelection = [pscustomobject]@{ Mailboxes = $sourceScope; Metadata = $(if ($sourceSelection) { $sourceSelection } else { [pscustomobject]@{ Mode = $clone.MailboxMode } }) }
    }
    if ($clone.Interactive) {
        # The copy opens at the review screen. Its case is kept if it is still Active.
        $clone.WizardOnly = @('Identity', 'SignIn', 'Case', 'Review', 'CreateCase')
        if ('CaseName' -notin $explicit) { $clone.PreferredCase = $Source.CaseName; $clone.CaseName = ''; $clone.AutoAcceptCase = $true }
        else { $clone.CaseLocked = $true }
        $clone.ExplicitParameters = @($clone.ExplicitParameters | Where-Object { $_ -ne 'CaseName' })
    }
    $clone.Mode = 'Search'
    return $clone
}

function Write-MRJson {
    param([string]$Path, $Value)
    # Reject truncation before writing. Publish a complete file without replacing evidence.
    $json = ConvertTo-Json -InputObject $Value -Depth 15 -EnumsAsStrings -ErrorAction Stop -WarningAction Stop
    $null = ConvertFrom-Json -InputObject $json -ErrorAction Stop
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $stream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [text.encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporaryPath, $Path)
    }
    finally { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } }
}

function Write-MRCsv {
    param([string]$Path, [object[]]$Rows, [string[]]$Columns)
    # Publish a complete file without replacing evidence.
    $temporaryPath = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        if (@($Rows).Count) { $Rows | Select-Object -Property $Columns | Export-Csv -LiteralPath $temporaryPath -NoTypeInformation -Encoding utf8 -ErrorAction Stop }
        else { [IO.File]::WriteAllText($temporaryPath, ('"' + ($Columns -join '","') + '"' + [environment]::NewLine), [text.UTF8Encoding]::new($false)) }
        [IO.File]::Move($temporaryPath, $Path)
    }
    finally { if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) } }
}

function ConvertTo-MRServiceRecord {
    param($Value)
    $record = [ordered]@{}
    $names = if ($Value -is [collections.IDictionary]) { @($Value.Keys) } else { @($Value.PSObject.Properties.Name) }
    foreach ($name in $names) {
        $propertyValue = if ($Value -is [collections.IDictionary]) { $Value[$name] } else { $Value.$name }
        # CultureInfo has recursive parent/culture metadata. Only its language name is evidence.
        if ($propertyValue -is [globalization.CultureInfo] -or
            ($name -eq 'Language' -and $null -ne $propertyValue -and $null -ne $propertyValue.PSObject.Properties['Name'])) {
            $record[$name] = [string]$propertyValue.Name
        } else { $record[$name] = $propertyValue }
    }
    return [pscustomobject]$record
}

function Write-MREvent {
    param([string]$Directory, [string]$EventName, $Details)
    $entry = [ordered]@{ Utc = [datetimeoffset]::UtcNow.ToString('o'); Event = $EventName; Details = $Details }
    $session = Get-MRLogSessionId
    if ($session) { $entry.Session = $session }
    $line = ($entry | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop -WarningAction Stop) + [environment]::NewLine
    [IO.File]::AppendAllText((Join-Path $Directory 'events.jsonl'), $line, [text.encoding]::UTF8)
    Write-MRLog "Run$EventName" @{ Run = (Split-Path $Directory -Leaf); Details = $Details }
}

function Save-MRSnapshot {
    param([string]$Directory, [string]$Label, $Value)
    $fileName = '{0}-{1}-{2}.json' -f $Label, [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0, 8)
    Write-MRJson -Path (Join-Path $Directory $fileName) -Value (ConvertTo-MRServiceRecord $Value)
}

function Read-MRRun {
    param([string]$Directory)
    $run = Get-Content -LiteralPath (Join-Path $Directory 'run.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($run.SchemaVersion -ne 1 -or $run.SearchName -notmatch '^MR-[A-Za-z0-9._-]+$') {
        throw 'This is not a supported Mail Remediation run.'
    }
    if ($run.Description -ne "M365-MailRemediation RunId=$($run.RunId) Ticket=$($run.Ticket)") {
        throw 'The saved run metadata is inconsistent.'
    }
    $rebuiltQuery = New-MRQuery -SenderAddress $run.SenderAddress -Subject $run.Subject `
        -ReceivedFrom $run.ReceivedFrom -ReceivedThrough $run.ReceivedThrough -AllDates:$run.AllDates
    if ($rebuiltQuery -cne $run.Query) { throw 'The saved query differs from its original criteria.' }
    $null = [guid]::Parse($run.TenantId)
    $null = Get-MRScope @($run.Mailboxes)
    $selection = Get-MRProperty $run 'ScopeSelection'
    $resolved = @(Get-MRProperty $selection 'ResolvedMailboxes' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($resolved.Count -and ((@(Get-MRScope $resolved) -join '|') -cne (@(Get-MRScope $run.Mailboxes) -join '|'))) { throw 'The saved scope differs from its resolved mailbox snapshot.' }
    return $run
}

function Get-MRAction {
    param([string]$SearchName)
    $name = "${SearchName}_Purge"
    try { $actions = @(Get-MRComplianceSearchAction -Identity $name -Details -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -match 'ManagementObjectNotFound|ObjectNotFound' -or
            $_.Exception.Message -match "couldn't be found|cannot be found|wasn't found|does not exist") { return $null }
        throw
    }
    # A missing Identity can return all objects. Never accept an unrelated action.
    $matchesForName = @($actions | Where-Object { $_.Name -eq $name })
    if ($matchesForName.Count -gt 1) { throw 'More than one purge action matched this search.' }
    if ($matchesForName.Count -eq 1) { return $matchesForName[0] }
    return $null
}

function Wait-MRJob {
    param([ValidateSet('Search', 'Purge')][string]$Kind, [string]$SearchName,
        [string]$PreviousJobRunId, [int]$TimeoutSeconds, [int]$PollSeconds)
    $activity = if ($Kind -eq 'Search') { 'Purview is searching the mailboxes' } else { 'Purview is deleting the messages' }
    $timer = [diagnostics.stopwatch]::StartNew()
    try {
        while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $job = if ($Kind -eq 'Search') { Get-MRComplianceSearch -Identity $SearchName -ErrorAction Stop }
                else { Get-MRAction $SearchName }
            $status = [string](Get-MRProperty $job 'Status')
            $runId = [string](Get-MRProperty $job 'JobRunId')
            $isFresh = -not $PreviousJobRunId -or ($runId -and $runId -ne $PreviousJobRunId)
            if ($status -eq 'Completed' -and $isFresh) {
                if (@(Get-MRProperty $job 'Errors' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) {
                    throw "$Kind completed with errors. Inspect the saved results before proceeding."
                }
                return $job
            }
            if ($status -in @('Failed', 'PartiallySucceeded', 'PartiallyCompleted', 'CompletedWithErrors', 'Stopped', 'Canceled', 'Cancelled')) {
                throw "$Kind ended with status '$status'. Nothing further will be submitted."
            }
            Write-Progress -Id 36 -Activity $activity -Status "$status ($([int]$timer.Elapsed.TotalSeconds) seconds so far)"
            Start-Sleep -Seconds $PollSeconds
        }
        throw "$Kind did not complete within $TimeoutSeconds seconds. Use Check status later; do not delete again."
    }
    finally { Write-Progress -Id 36 -Activity $activity -Completed }
}

function Get-MRLocationCount {
    param([string]$SuccessResults)
    $pattern = '(?is)\bLocation:\s*(?<location>[^,;\r\n}]+),(?:(?!\bLocation:).)*?\bItem count:\s*(?<count>[0-9]+)\b'
    $rows = @([regex]::Matches($SuccessResults, $pattern) | ForEach-Object {
        [pscustomobject]@{ Location = $_.Groups['location'].Value.Trim().ToLowerInvariant(); Items = [long]$_.Groups['count'].Value }
    })
    return @($rows | Group-Object Location | ForEach-Object {
        [pscustomobject]@{ Location = $_.Name; Items = [long](($_.Group | Measure-Object Items -Sum).Sum) }
    } | Sort-Object Location)
}

function Test-MRSearch {
    param($Search, $Run, [switch]$ForRemoval)
    if ($Search.Name -cne $Run.SearchName -or $Search.Description -cne $Run.Description -or
        $Search.ContentMatchQuery -cne $Run.Query) { throw 'The tenant search was changed or does not belong to this saved run.' }
    $actualScope = @((Get-MRProperty $Search 'ExchangeLocation') | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    $expectedScope = @($Run.Mailboxes | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
    if (($actualScope -join '|') -cne ($expectedScope -join '|')) { throw 'The search mailbox scope differs from the saved run.' }
    foreach ($property in @('SharePointLocation', 'OneDriveLocation', 'ExchangeLocationExclusion', 'SharePointLocationExclusion', 'HoldNames')) {
        if (@(Get-MRProperty $Search $property | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) {
            throw "The search contains an unexpected $property setting. Removal is blocked."
        }
    }
    if ([string](Get-MRProperty $Search 'NumBindings') -notmatch '^\d+$' -or [long]$Search.NumBindings -gt 50000) {
        throw 'Could not verify that the search is within the 50,000-location purge limit.'
    }
    if ([string](Get-MRProperty $Search 'Items') -notmatch '^\d+$') { throw 'Purview did not return a valid item count.' }
    if ($ForRemoval) {
        if ($Search.Status -ne 'Completed') { throw "The search has not finished (status: $($Search.Status)). Use Check status, then try again." }
        if ([long]$Search.Items -le 0) { throw 'There is nothing to delete: this search found no messages.' }
        if (@(Get-MRProperty $Search 'Errors' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) { throw 'The search contains errors.' }
        $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
        $total = [long](($locations | Measure-Object Items -Sum).Sum)
        if ($locations.Count -eq 0 -or $total -ne [long]$Search.Items) {
            throw 'Per-mailbox counts are missing or incomplete. Narrow the search and create a new one; this tool cannot check the 10-per-mailbox limit.'
        }
        if (@($locations | Where-Object Items -GT 10).Count) {
            throw 'At least one mailbox has more than 10 matches, and Purview deletes at most 10 per mailbox at a time. Narrow the dates or subject words and create a new search.'
        }
    }
}

function Get-MRResultKey {
    param($Search)
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    return (@([string]$Search.Items, [string]$Search.NumBindings) + @($locations | ForEach-Object { "$($_.Location)=$($_.Items)" })) -join '|'
}

function Format-MRSearchDescription {
    param($Run)
    $subject = if ($Run.Subject) { "subject contains '$($Run.Subject)'" } else { 'any subject' }
    $dates = if ($Run.AllDates) { 'any date' } else { "received $($Run.ReceivedFrom) to $($Run.ReceivedThrough) (UTC)" }
    return "email from $($Run.SenderAddress), $subject, $dates"
}

function Show-MRReview {
    param($Run, $Search, [string]$Directory)
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    $withMatches = @($locations | Where-Object Items -GT 0).Count
    Write-MRText Heading 'What the Purview search found'
    Write-Host "Ticket:     $($Run.Ticket)"
    if ($Run.TicketUrl) { Write-Host "Ticket link: $($Run.TicketUrl)" }
    Write-Host "Case:       $($Run.CaseName)"
    Write-Host "Search:     $($Run.SearchName)"
    Write-Host "Looks for:  $(Format-MRSearchDescription $Run)"
    $scope = if ('All' -in @($Run.Mailboxes)) { 'All mailboxes' } else { "$(@($Run.Mailboxes).Count) mailbox(es): $(@($Run.Mailboxes | Select-Object -First 3) -join ', ')$(if (@($Run.Mailboxes).Count -gt 3) { ', ...' })" }
    Write-Host "Mailboxes:  $scope"
    Write-Host "Result:     $($Search.Status). Found $($Search.Items) message(s) in $withMatches mailbox(es); $($Search.NumBindings) searched."
    Write-Host "Saved in:   $Directory"
    $serviceCaseId = [string](Get-MRProperty $Search 'CaseId')
    if ($serviceCaseId) { Write-MRText Hint "Purview case ID: $serviceCaseId" }
    $parent = Get-MRProperty $Run 'ClonedFrom'
    if ($parent) { Write-MRText Hint "Copied from: $($parent.SearchName)" }
    if (@($locations | Where-Object Items -GT 10).Count) {
        Write-Warning 'Some mailboxes have more than 10 matches. Purview deletes at most 10 per mailbox at a time, so narrow the dates or subject words before deleting.'
    }
}

function Select-MRRun {
    param([string]$DataDirectory)
    $entries = @(Get-MRRunIndex $DataDirectory)
    if (-not $entries.Count) { Write-Host 'No saved runs yet. Saved runs appear here after a search.' }
    $selected = Select-MRList -Entries $entries -Title 'Saved runs, newest first' -AllowPath
    if ($selected -is [string]) { return $selected }
    return $selected.Key
}

function Save-MRTicketSummary {
    param([string]$Directory, $Run, $Search, $Action, $Review)
    $caseCreated = [string](Get-MRProperty $Run 'CaseCreatedUtc')
    $case = if ($caseCreated) { "$($Run.CaseName) (created by the toolkit for this search at $caseCreated)" } else { $Run.CaseName }
    $lines = @(
        "Ticket: $($Run.Ticket)", "Ticket URL: $($Run.TicketUrl)", "Tenant ID: $($Run.TenantId)",
        "Search: $($Run.SearchName)", "Case: $case", "Purview: $($Run.PurviewUrl)",
        "Sender: $($Run.SenderAddress)", "Looks for: $(Format-MRSearchDescription $Run)", "Query: $($Run.Query)", "Mailboxes: $($Run.Mailboxes -join ', ')",
        "Search status: $($Search.Status)", "Messages found: $($Search.Items)", "Mailboxes searched: $($Search.NumBindings)",
        "Recorded UTC: $([datetimeoffset]::UtcNow.ToString('o'))"
    )
    $serviceCaseId = [string](Get-MRProperty $Search 'CaseId')
    if ($serviceCaseId) { $lines += "Purview case ID: $serviceCaseId" }
    $parent = Get-MRProperty $Run 'ClonedFrom'
    if ($parent) { $lines += "Copied from: $($parent.SearchName)", "Original saved run: $($parent.RunPath)" }
    if ($Review) {
        $lines += "Message trace ($($Review.WindowStartUtc) to $($Review.WindowEndUtc) UTC): $($Review.Messages) message(s) delivered to $($Review.Mailboxes) mailbox(es)"
        foreach ($subject in @($Review.Subjects | Select-Object -First 3)) { $lines += "  $($subject.Messages) x $($subject.Subject -replace '[\r\n\x00-\x1f]', ' ')" }
        $lines += "Search and message trace differ for $($Review.MailboxesDifferent) of $($Review.MailboxesCompared) mailbox(es)"
    }
    if ($Action) {
        $lines += "Deletion status: $($Action.Status)", "Purview results: $($Action.Results)", "Purview errors: $($Action.Errors)"
        $lines += 'Completed means Purview finished the deletion job. Holds and retention can keep copies inside Microsoft 365.'
    } else { $lines += 'No deletion is included in this summary.' }
    $summaryName = "ticket-summary-$([datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $path = Join-Path $Directory $summaryName
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'Read')
    try {
        $bytes = [text.encoding]::UTF8.GetBytes($lines -join [environment]::NewLine)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Write-Host "Ticket summary: $path"
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
    Write-MRJson $path (ConvertTo-MRServiceRecord $Search)
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    if ($locations.Count -and -not (Test-Path -LiteralPath (Join-Path $Directory 'location-counts.csv'))) { $locations | Export-Csv -LiteralPath (Join-Path $Directory 'location-counts.csv') -NoTypeInformation -NoClobber }
    if ($Recovered) {
        Write-MREvent $Directory 'SearchRecovered' @{ Items = $Search.Items; ResultKey = (Get-MRResultKey $Search) }
        Write-Host 'The finished search was saved. Review it with Delete before removing anything.'
    }
}

function Initialize-MROption {
    # Gives every optional key a value in one place, because strict mode rejects dot access
    # to a missing key. Keys whose absence means something (SelectedCaseTenantId, LastRunPath,
    # SourcePath) are left out on purpose.
    param([hashtable]$Options)
    if (-not $Options.ContainsKey('ExplicitParameters')) { $Options.ExplicitParameters = @($Options.Keys) }
    $defaults = [ordered]@{
        Interactive = $false; Offline = $false; SourceRun = $null; SettingsPath = ''; LogDirectory = ''; NoSavedSettings = $false
        TenantId = ''; UserPrincipalName = ''; Ticket = ''; TicketUrl = ''; TicketUrlTemplate = ''
        SenderAddress = ''; Subject = ''; ReceivedFrom = ''; ReceivedThrough = ''; AllDates = $false
        Mailboxes = @('All'); MailboxMode = 'Paste'; GroupAddress = ''; ScopeSelection = $null
        CaseName = ''; CaseLocked = $false; PreferredCase = ''; AutoAcceptCase = $false; AskIdentity = $false; WizardOnly = @()
        NewCase = $false; CreateCase = $false; CaseCreatedUtc = ''
        ImportedFrom = $null; PickedRun = $false; ExchangeAvailable = $true
        RunPath = ''; ReportPath = ''; PurgeType = 'HardDelete'; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
        TimeoutSeconds = 1800; PollSeconds = 5
    }
    foreach ($key in $defaults.Keys) { if (-not $Options.ContainsKey($key)) { $Options[$key] = $defaults[$key] } }
}

function Resolve-MRSearchDefault {
    param([hashtable]$Options, [hashtable]$SavedSettings)
    $fromSource = [bool]$Options.SourceRun -or $Options.ContainsKey('SelectedCaseTenantId')
    if ('TenantId' -notin $Options.ExplicitParameters -and -not $fromSource -and $SavedSettings['TenantId']) { $Options.TenantId = $SavedSettings['TenantId'] }
    $sameTenant = $SavedSettings['TenantId'] -and $Options.TenantId -and ([string]$SavedSettings['TenantId'] -ieq [string]$Options.TenantId)
    if ($sameTenant) {
        if ('UserPrincipalName' -notin $Options.ExplicitParameters) { $Options.UserPrincipalName = $SavedSettings['UserPrincipalName'] }
        if ('CaseName' -notin $Options.ExplicitParameters -and -not $Options.SourceRun -and -not $Options.CaseLocked -and $SavedSettings['CaseName']) {
            if ($Options.Interactive) { $Options.PreferredCase = $SavedSettings['CaseName'] } else { $Options.CaseName = $SavedSettings['CaseName'] }
        }
        if (-not $Options.Interactive) { Write-Host "Using saved settings from $($Options.SettingsPath). Parameters you typed take precedence." }
    }
    if ($SavedSettings['TicketUrlTemplate'] -and -not $Options.TicketUrlTemplate) { $Options.TicketUrlTemplate = $SavedSettings['TicketUrlTemplate'] }
    # A case named on the command line is used as given; the guided questions skip the case list.
    if ('CaseName' -in $Options.ExplicitParameters -and $Options.CaseName) { $Options.CaseLocked = $true }
}

function Read-MRRemovalEvidence {
    # Before deletion the operator must have seen every message: message trace when it
    # accounts for everything the search found, otherwise a report from the Purview portal.
    param($Review, $Run, [string]$Directory, [string]$ReportPath, [bool]$Interactive, [string]$TraceProblem)
    if ($ReportPath) { return Read-MRReportPath $ReportPath }
    $gaps = @(Get-MRTraceGap -Review $Review -Run $Run -TraceProblem $TraceProblem)
    if ($gaps.Count) {
        Show-MRTraceGap $gaps
        return Read-MRReportPath -Run $Run
    }
    if (-not $Interactive) { return '' }
    while ($true) {
        Write-MRText Heading 'Check the messages above before deleting.'
        Write-Host '[Enter] Continue to deletion'
        Write-Host '[L] List every message'
        Write-Host '[R] Also attach a report exported from the Purview portal (optional)'
        Write-Host '[B] Back'
        $choice = (Read-MRAnswer 'Your choice').Trim()
        if (-not $choice) { return '' }
        if ($choice -ieq 'L') { Show-MRTraceMessage $Directory $Review; continue }
        if ($choice -ieq 'R') {
            try { return Read-MRReportPath -Run $Run }
            catch { if (-not (Test-MRBackSignal $_)) { throw } }
            continue
        }
        Write-MRText Retry 'Press Enter, or type L, R, or B.'
    }
}

function Read-MRPurgeType {
    param([string]$Default)
    Write-MRText Heading 'How should the messages be deleted?'
    Write-Host '[1] Permanently (HardDelete): users cannot get them back. Recommended for phishing.'
    Write-Host '[2] Recoverably (SoftDelete): users can restore them from Recoverable Items for a while.'
    $defaultKey = if ($Default -eq 'SoftDelete') { '2' } else { '1' }
    return Read-MRValidated 'Deletion type' $defaultKey { param($value)
        switch -regex ($value) { '^(1|hard|harddelete)$' { 'HardDelete'; break } '^(2|soft|softdelete)$' { 'SoftDelete'; break } default { throw 'Type 1 or 2.' } }
    } -HelpTopic Removal
}

function Invoke-MRWorkflow {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([hashtable]$Options)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $directory = $null
    $connection = $null
    $runLock = $null
    $run = $null
    # A copy works on a new options table; the caller still needs to learn the new run folder.
    $callerOptions = $Options
    if ($Options.Mode -eq 'Menu') {
        $menuParameters = @{ Options = $Options; WhatIf = $WhatIfPreference }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $menuParameters.Confirm = $PSBoundParameters.Confirm }
        Invoke-MRMenu @menuParameters
        return
    }
    if ($Options.Mode -eq 'SignOut') { Disconnect-MRSession; return }
    Initialize-MROption $Options
    $Options.Interactive = $Options.ContainsKey('MenuAction') -and $Options.MenuAction
    $Options.Offline = [bool]$WhatIfPreference
    $savedSettings = @{}
    $settingsUsable = $true
    try {
        if ($Options.SettingsPath -and -not $Options.NoSavedSettings) {
            try { $savedSettings = Read-MRProfile $Options.SettingsPath }
            catch { $settingsUsable = $false; Write-MRText Notice "Saved settings were ignored and will not be overwritten: $($_.Exception.Message)" }
        }
        if ('DataDirectory' -notin $Options.ExplicitParameters -and $savedSettings.ContainsKey('DataDirectory')) { $Options.DataDirectory = $savedSettings.DataDirectory }
        if ($Options.Mode -eq 'BrowsePurview') {
            $browserParameters = @{ Options = $Options; SavedSettings = $savedSettings; WhatIf = $WhatIfPreference }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $browserParameters.Confirm = $PSBoundParameters.Confirm }
            Invoke-MRPurviewBrowser @browserParameters
            return
        }
        if ($Options.CreateCase -and $Options.Mode -in @('Search', 'Clone') -and 'CaseName' -notin $Options.ExplicitParameters) {
            throw 'Use -CreateCase together with -CaseName, the name of the case to create.'
        }
        if ($Options.Mode -eq 'Clone') {
            if (-not $Options.RunPath) { $Options.RunPath = Select-MRRun $Options.DataDirectory; $Options.PickedRun = $true }
            $sourcePath = (Resolve-Path -LiteralPath $Options.RunPath).Path
            $source = Read-MRRun $sourcePath
            Write-Host "Copying: $($source.SearchName)`nIt looks for: $(Format-MRSearchDescription $source)"
            $Options = Get-MRCloneOption $source $Options
            $Options.SourcePath = $sourcePath
        }
        if ($Options.Mode -eq 'Search') {
            Resolve-MRSearchDefault -Options $Options -SavedSettings $savedSettings
            if ($Options.Interactive) { Read-MRSearchPlan $Options } else { Resolve-MRSearchPlan $Options }
            $Options.TenantId = Get-MRTenantId $Options.TenantId
            $Options.UserPrincipalName = Get-MREmail $Options.UserPrincipalName
            $query = New-MRQuery -SenderAddress $Options.SenderAddress -Subject $Options.Subject `
                -ReceivedFrom $Options.ReceivedFrom -ReceivedThrough $Options.ReceivedThrough -AllDates:$Options.AllDates
            if (-not ($Options.ContainsKey('ScopeSelection') -and $Options.ScopeSelection)) {
                $Options.ScopeSelection = if ($Options.Offline) { [pscustomobject]@{ Mailboxes = @(Get-MRScope $Options.Mailboxes); Metadata = $null } } else { Resolve-MRMailboxScope -Options $Options }
            }
            $scope = @($Options.ScopeSelection.Mailboxes)
            if ($WhatIfPreference) {
                $scopeText = if ($scope.Count) { $scope -join ', ' } else { "$($Options.MailboxMode) (chosen after signing in)" }
                $caseText = if ($Options.CaseName -and $Options.CreateCase) { "$($Options.CaseName) (created if it does not exist yet)" }
                    elseif ($Options.CaseName) { $Options.CaseName } elseif ($Options.PreferredCase) { "$($Options.PreferredCase) (confirmed after signing in)" } else { '(chosen after signing in)' }
                Write-Host "`nPreview only. Nothing is created, and the toolkit does not sign in."
                Write-Host "Tenant: $($Options.TenantId)`nCase: $caseText`nQuery: $query`nMailboxes: $scopeText"
                $null = $PSCmdlet.ShouldProcess("Tenant $($Options.TenantId)", "Create and run a search for $query")
                return
            }
            if ([string]::IsNullOrWhiteSpace($Options.CaseName)) { throw 'Name a Purview case. In the menu, pick or create one; on the command line, use -CaseName, and add -CreateCase to create it.' }
            if (Test-MRSystemCase $Options.CaseName) { throw 'The toolkit does not create searches in the built-in Content Search case, because they do not appear in the Purview portal there. Choose an incident case.' }
            if (-not $scope.Count) { throw 'No mailboxes were chosen.' }
            $portal = [uri]$Options.PurviewUrl
            if ($portal.Scheme -ne 'https' -or $portal.Host -ne 'purview.microsoft.com' -or $portal.UserInfo) { throw 'The Purview link must be an HTTPS URL on purview.microsoft.com without embedded credentials.' }
            if ($Options.TicketUrl -and ([uri]$Options.TicketUrl).Scheme -ne 'https') { throw 'TicketUrl must be an HTTPS URL.' }
            $runId = [guid]::NewGuid().ToString()
            $ticketName = $Options.Ticket -replace '[^A-Za-z0-9._-]', ''
            $searchName = 'MR-{0}-{1}-{2}' -f $ticketName, [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ'), $runId.Substring(0, 8)
            $run = [pscustomobject][ordered]@{
                SchemaVersion = 1; RunId = $runId; Ticket = $Options.Ticket; TicketUrl = $Options.TicketUrl
                CreatedUtc = [datetimeoffset]::UtcNow.ToString('o'); TenantId = $Options.TenantId
                SearchName = $searchName; CaseName = $Options.CaseName; PurviewUrl = $portal.AbsoluteUri
                Description = "M365-MailRemediation RunId=$runId Ticket=$($Options.Ticket)"
                SenderAddress = $Options.SenderAddress; Subject = $Options.Subject; ReceivedFrom = $Options.ReceivedFrom
                ReceivedThrough = $Options.ReceivedThrough; AllDates = [bool]$Options.AllDates; Mailboxes = $scope; Query = $query
            }
            $selectionMetadata = Get-MRProperty $Options.ScopeSelection 'Metadata'
            if ($selectionMetadata) { $run | Add-Member ScopeSelection $selectionMetadata }
            if ($Options.ContainsKey('ImportedFrom') -and $Options.ImportedFrom) { $run | Add-Member ImportedFrom $Options.ImportedFrom }
            if ($Options.SourceRun) {
                $run | Add-Member -NotePropertyName ClonedFrom -NotePropertyValue ([pscustomobject]@{
                    RunId = $Options.SourceRun.RunId; SearchName = $Options.SourceRun.SearchName
                    RunPath = $Options.SourcePath; Query = $Options.SourceRun.Query; PurviewUrl = $Options.SourceRun.PurviewUrl
                    ScopeSelection = Get-MRProperty $Options.SourceRun 'ScopeSelection'
                })
            }
            if (-not $PSCmdlet.ShouldProcess("Tenant $($run.TenantId)", "Create and run search $searchName")) { return }
            $connection = Connect-MRPurview $Options.UserPrincipalName $run.TenantId
            # The guided questions create a new case when the review is accepted; -CreateCase does it here.
            if ($Options.CreateCase -and (New-MRPurviewCase -CaseName $run.CaseName -Ticket $run.Ticket)) { $Options.CaseCreatedUtc = [datetimeoffset]::UtcNow.ToString('o') }
            if ($Options.CaseCreatedUtc) { $run | Add-Member CaseCreatedUtc $Options.CaseCreatedUtc }
            $directory = Join-Path ([IO.Path]::GetFullPath($Options.DataDirectory)) $searchName
            $Options.LastRunPath = $directory
            $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
            $runLock = [IO.File]::Open((Join-Path $directory 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            Write-MRJson (Join-Path $directory 'run.json') $run
            if ($Options.CaseCreatedUtc) { Write-MREvent $directory 'CaseCreated' @{ Case = $run.CaseName; CreatedUtc = $Options.CaseCreatedUtc; Administrator = $connection.UserPrincipalName } }
            Write-MREvent $directory 'SearchCreating' @{ Administrator = $connection.UserPrincipalName; TenantId = $connection.TenantID; Case = $run.CaseName; Query = $query }
            $null = New-MRComplianceSearch -Name $searchName -Case $run.CaseName -ExchangeLocation $scope `
                -ContentMatchQuery $query -Description $run.Description -ErrorAction Stop
            Write-MREvent $directory 'SearchCreated' @{ SearchName = $searchName }
            $null = Start-MRComplianceSearch -Identity $searchName -ErrorAction Stop
            Write-MREvent $directory 'SearchStarted' @{ SearchName = $searchName }
            Write-Host "`nPurview is searching. Meanwhile the toolkit checks message trace."
            $traceSkip = if ($Options.ExchangeAvailable) { '' } else { 'Exchange Online did not sign in, so message trace was skipped.' }
            $traceResult = Get-MRTraceResult -Run $run -UserPrincipalName $Options.UserPrincipalName -SkipReason $traceSkip
            Write-Host 'Waiting for Purview to finish. Searching all mailboxes usually takes a few minutes.'
            $search = Wait-MRJob -Kind Search -SearchName $searchName -TimeoutSeconds $Options.TimeoutSeconds -PollSeconds $Options.PollSeconds
            Test-MRSearch $search $run
            Save-MRSearchBaseline -Directory $directory -Run $run -Search $search
            Write-MREvent $directory 'SearchCompleted' @{ Items = $search.Items; ResultKey = (Get-MRResultKey $search) }
            Show-MRReview $run $search $directory
            $review = $null
            if ($traceResult.Status -eq 'Completed') {
                $review = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult $traceResult
                Show-MRTraceReview $review
            } else { Write-MREvent $directory 'TraceUnavailable' @{ Reason = $traceResult.Reason } }
            # Say now, while there is time to export it, when deleting will need a portal report.
            $gaps = @(Get-MRTraceGap -Review $review -Run $run -TraceProblem $traceResult.Reason)
            if ($gaps.Count -and [long]$search.Items -gt 0) { Show-MRTraceGap $gaps; Write-MRReportStep $run }
            Save-MRTicketSummary $directory $run $search $null $review
            if ($Options.SettingsPath -and -not $Options.NoSavedSettings -and $settingsUsable) {
                try { Save-MRProfile $Options.SettingsPath $run $connection.UserPrincipalName -DataDirectory $Options.DataDirectory -Confirm:$false }
                catch { Write-MRText Notice "The search finished, but settings could not be saved: $($_.Exception.Message)" }
            }
            Write-MRText Success "`nThe search is ready. Nothing has been deleted. To delete these messages, choose 2 (Delete) in the main menu and pick this run."
            if ($Options.Interactive) { Show-MRQuickAction -Run $run -Directory $directory }
            return
        }
        if (-not $Options.RunPath) { $Options.RunPath = Select-MRRun $Options.DataDirectory; $Options.PickedRun = $true }
        $directory = (Resolve-Path -LiteralPath $Options.RunPath).Path
        $Options.LastRunPath = $directory
        $run = Read-MRRun $directory
        if ($WhatIfPreference) {
            $previewAction = if ($Options.Mode -eq 'Remove') {
                "Review the messages and submit one $($Options.PurgeType) deletion"
            } else { 'Read the current search and deletion status and save it' }
            $null = $PSCmdlet.ShouldProcess("Saved search $($run.SearchName)", $previewAction)
            Write-Host "Saved query: $($run.Query)`nPurview: $($run.PurviewUrl)"
            Write-Host 'This preview does not sign in, check current results, or submit anything.'
            return
        }
        if ($savedSettings.Count -and $savedSettings['TenantId'] -eq $run.TenantId -and
            'UserPrincipalName' -notin $Options.ExplicitParameters) { $Options.UserPrincipalName = $savedSettings['UserPrincipalName'] }
        if (-not $Options.UserPrincipalName) {
            $Options.UserPrincipalName = Read-MRValidated 'Admin sign-in email' '' { param($value) Get-MREmail $value } -HelpTopic Administrator
        }
        $Options.UserPrincipalName = Get-MREmail $Options.UserPrincipalName
        $runLock = [IO.File]::Open((Join-Path $directory 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        $connection = Connect-MRPurview $Options.UserPrincipalName $run.TenantId
        Write-MREvent $directory 'Connected' @{ Administrator = $connection.UserPrincipalName; TenantId = $connection.TenantID; Mode = $Options.Mode }
        $search = Get-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop
        Test-MRSearch $search $run
        Save-MRSnapshot $directory 'search-status' $search
        $action = Get-MRAction $run.SearchName
        if ($Options.Mode -eq 'Status') {
            if ($search.Status -eq 'Completed' -and -not $action -and -not (Test-Path -LiteralPath (Join-Path $directory 'search.json'))) {
                try { Save-MRSearchBaseline -Directory $directory -Run $run -Search $search -Recovered }
                catch { Write-MRText Notice "The search could not be finalized: $($_.Exception.Message)" }
            }
            Show-MRReview $run $search $directory
            $review = Get-MRSavedTraceReview $directory
            if ($review) {
                Show-MRTraceReview $review
                $gaps = @(Get-MRTraceGap -Review $review -Run $run)
                if ($gaps.Count -and -not $action -and [string]$search.Items -match '^\d+$' -and [long]$search.Items -gt 0) { Show-MRTraceGap $gaps; Write-MRReportStep $run }
            }
            if ($action) {
                Save-MRSnapshot $directory 'purge-status' $action
                Write-MRText Heading 'Deletion'
                Write-Host "Status: $($action.Status)`nPurview results: $($action.Results)`nPurview errors: $(if ($action.Errors) { $action.Errors } else { 'none' })"
                Write-Host 'Completed means Purview finished the deletion job. To confirm, run the same search again; it should find nothing in normal folders. Holds can keep copies inside Microsoft 365.'
            }
            elseif (@(Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') -ErrorAction SilentlyContinue | Where-Object { $_ -match '"PurgeSubmissionAttempt"' }).Count) {
                Write-Warning 'A deletion was submitted for this run, but Purview did not return it. Check again later; do not delete again.'
            }
            else { Write-Host "`nNothing has been deleted for this run." }
            Save-MRTicketSummary $directory $run $search $action $review
            if ($Options.Interactive) { Show-MRQuickAction -Run $run -Directory $directory }
            return
        }
        if (-not (Test-Path -LiteralPath (Join-Path $directory 'search.json'))) {
            throw 'This search has not finished, so there is nothing to review yet. Use Check status first; it saves the results once the search completes.'
        }
        $baseline = Get-Content -LiteralPath (Join-Path $directory 'search.json') -Raw | ConvertFrom-Json
        Test-MRSearch $baseline $run -ForRemoval
        $events = @(Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        if ($action -or @($events | Where-Object Event -EQ 'PurgeSubmissionAttempt').Count) {
            throw 'A deletion was already submitted for this run. Use Check status. The tool will not retry, remove records, or submit another deletion.'
        }
        $purgeCommand = Get-Command New-MRComplianceSearchAction -ErrorAction Stop
        if (-not $purgeCommand.Parameters.ContainsKey('Purge')) { throw 'Your account lacks the Purview Search And Purge role, which deleting requires.' }
        $previousRunId = [string](Get-MRProperty $search 'JobRunId')
        if (-not $previousRunId) { throw 'Purview did not return a search JobRunId. A fresh completed rerun cannot be verified.' }
        Write-MREvent $directory 'SearchRerunStarting' @{ PreviousJobRunId = $previousRunId }
        Write-Host 'Running the search again to make sure nothing changed. This usually takes a few minutes.'
        $null = Start-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop
        $search = Wait-MRJob -Kind Search -SearchName $run.SearchName -PreviousJobRunId $previousRunId `
            -TimeoutSeconds $Options.TimeoutSeconds -PollSeconds $Options.PollSeconds
        Save-MRSnapshot $directory 'search-before-purge' $search
        Test-MRSearch $search $run -ForRemoval
        if ((Get-MRResultKey $search) -cne (Get-MRResultKey $baseline)) {
            throw 'The search now finds different messages than when it was created. Create a new search and review it before deleting.'
        }
        Show-MRReview $run $search $directory
        $review = Get-MRSavedTraceReview $directory
        $traceProblem = ''
        if (-not $review) {
            $traceResult = Get-MRTraceResult -Run $run -UserPrincipalName $Options.UserPrincipalName
            if ($traceResult.Status -eq 'Completed') { $review = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult $traceResult }
            else { $traceProblem = $traceResult.Reason; Write-MREvent $directory 'TraceUnavailable' @{ Reason = $traceProblem } }
        }
        if ($review) { Show-MRTraceReview $review }
        $reportPath = Read-MRRemovalEvidence -Review $review -Run $run -Directory $directory -ReportPath $Options.ReportPath -Interactive $Options.Interactive -TraceProblem $traceProblem
        $evidence = [ordered]@{ Administrator = $connection.UserPrincipalName; MessageTrace = $null; Report = $null }
        if ($review) { $evidence.MessageTrace = [ordered]@{ Review = $review.Files.Review; MessagesSha256 = $review.MessagesSha256; Covers = $review.CoversSearchDates; Different = $review.MailboxesDifferent } }
        if ($reportPath) {
            $report = Get-Item -LiteralPath $reportPath
            $reportHash = (Get-FileHash -LiteralPath $report.FullName -Algorithm SHA256).Hash
            $copyPath = Join-Path $directory ("reviewed-report-$([guid]::NewGuid().ToString('N')).csv")
            Copy-Item -LiteralPath $report.FullName -Destination $copyPath -ErrorAction Stop
            if ((Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash -ne $reportHash) { throw 'The report changed while it was copied. Deletion is blocked.' }
            Write-MREvent $directory 'ReportReviewed' @{ Path = $copyPath; SHA256 = $reportHash; Administrator = $connection.UserPrincipalName }
            $evidence.Report = [ordered]@{ Path = $copyPath; SHA256 = $reportHash }
        }
        Write-MREvent $directory 'ReviewCompleted' $evidence
        $askType = $Options.Interactive -and 'PurgeType' -notin $Options.ExplicitParameters
        while ($true) {
            if ($askType) { $Options.PurgeType = Read-MRPurgeType $Options.PurgeType }
            if ($Options.PurgeType -eq 'HardDelete') { Write-MRText Danger "`nPermanent deletion: users cannot get these messages back. Holds and retention can keep copies inside Microsoft 365." }
            else { Write-MRText Notice "`nRecoverable deletion: messages leave normal folders, and users can restore them for a while." }
            $phrase = "REMOVE $($run.Ticket) $($search.Items) $($Options.PurgeType)"
            $mailboxCount = @(Get-MRLocationCount ([string](Get-MRProperty $search 'SuccessResults')) | Where-Object Items -GT 0).Count
            try { Read-MRConfirmation $phrase "Type $phrase to delete $($search.Items) message(s) from $mailboxCount mailbox(es), or B to go back"; break }
            catch { if ($askType -and (Test-MRBackSignal $_)) { continue }; throw }
        }
        if (-not $PSCmdlet.ShouldProcess("$($run.SearchName), $($search.Items) matches", "Submit one $($Options.PurgeType) purge")) { return }
        $current = Get-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop
        Test-MRSearch $current $run -ForRemoval
        if ((Get-MRResultKey $current) -cne (Get-MRResultKey $search) -or
            [string](Get-MRProperty $current 'JobRunId') -cne [string](Get-MRProperty $search 'JobRunId')) {
            throw 'The search changed during review. Removal is blocked.'
        }
        if (Get-MRAction $run.SearchName) { throw 'A deletion appeared during review. Use Check status instead.' }
        # Persist before submitting. An interrupted or failed response must never
        # trigger automatic resubmission of a potentially completed server action.
        Write-MREvent $directory 'PurgeSubmissionAttempt' @{ Type = $Options.PurgeType; Administrator = $connection.UserPrincipalName; Items = $current.Items }
        $submitted = New-MRComplianceSearchAction -SearchName $run.SearchName -Purge -PurgeType $Options.PurgeType -Confirm:$false -ErrorAction Stop
        Save-MRSnapshot $directory 'purge-submitted' $submitted
        $result = Wait-MRJob -Kind Purge -SearchName $run.SearchName -TimeoutSeconds $Options.TimeoutSeconds -PollSeconds $Options.PollSeconds
        Save-MRSnapshot $directory 'purge-result' $result
        Write-MREvent $directory 'PurgeCompleted' @{ Status = $result.Status; Results = $result.Results; Errors = $result.Errors }
        Save-MRTicketSummary $directory $run $current $result $review
        Write-MRText Success "`nDeletion status: $($result.Status)`nPurview results: $($result.Results)"
        Write-Host "Records saved in: $directory"
        Write-Host 'To confirm, run the same search again later; it should find nothing in normal folders. Copies kept by holds can still appear.'
        if ($Options.Interactive) { Show-MRQuickAction -Run $run -Directory $directory }
    }
    catch {
        $failure = $_
        if ($runLock -and $directory -and (Test-Path -LiteralPath (Join-Path $directory 'run.json'))) {
            if ($failure.Exception -is [OperationCanceledException]) {
                try { Write-MREvent $directory 'Canceled' @{ Message = $failure.Exception.Message } } catch { Write-MRText Notice 'Could not record the cancellation in the run log.' }
            }
            else {
                try { Write-MREvent $directory 'Error' @{ Message = $failure.Exception.Message } }
                catch { Write-MRText Notice 'Could not record the error in the run log.' }
                if ($connection) {
                    try {
                        $lastSearch = @(Get-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop | Where-Object Name -EQ $run.SearchName)
                        if ($lastSearch.Count -eq 1) { Save-MRSnapshot $directory 'search-after-error' $lastSearch[0] }
                        $lastAction = Get-MRAction $run.SearchName
                        if ($lastAction) { Save-MRSnapshot $directory 'purge-after-error' $lastAction }
                    }
                    catch { Write-MRText Notice 'Could not collect additional provider diagnostics. The original error is preserved.' }
                }
            }
        }
        throw $failure
    }
    finally {
        # Sign-ins stay open for this window; only the run's file lock is released here.
        if ($runLock) { $runLock.Dispose() }
        if (-not [object]::ReferenceEquals($Options, $callerOptions) -and $Options.ContainsKey('LastRunPath')) { $callerOptions.LastRunPath = $Options.LastRunPath }
    }
}

. (Join-Path $PSScriptRoot 'Private\Log.ps1')
. (Join-Path $PSScriptRoot 'Private\Session.ps1')
. (Join-Path $PSScriptRoot 'Private\Interface.ps1')
. (Join-Path $PSScriptRoot 'Private\Wizard.ps1')
. (Join-Path $PSScriptRoot 'Private\Directory.ps1')
. (Join-Path $PSScriptRoot 'Private\MessageTrace.ps1')
. (Join-Path $PSScriptRoot 'Private\Purview.ps1')

# Dot-sourcing loads functions for offline tests without connecting, prompting, or logging.
if ($MyInvocation.InvocationName -ne '.') {
    $options = @{}
    foreach ($parameterName in @('Mode', 'Ticket', 'TicketUrl', 'UserPrincipalName', 'TenantId',
        'SenderAddress', 'ReceivedFrom', 'ReceivedThrough', 'AllDates', 'Mailboxes', 'MailboxMode', 'GroupAddress', 'CaseName', 'CreateCase',
        'PurviewUrl', 'RunPath', 'ReportPath', 'PurgeType', 'DataDirectory', 'SettingsPath', 'LogDirectory', 'NoSavedSettings', 'TimeoutSeconds', 'PollSeconds')) {
        $options[$parameterName] = Get-Variable -Name $parameterName -ValueOnly
    }
    if ($PSBoundParameters.ContainsKey('Subject')) { $options.Subject = $Subject }
    $options.ExplicitParameters = @($PSBoundParameters.Keys)
    $workflowParameters = @{ Options = $options; WhatIf = $WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $workflowParameters.Confirm = $PSBoundParameters.Confirm }
    if (-not $WhatIfPreference) {
        $loggedParameters = [ordered]@{}
        foreach ($key in $PSBoundParameters.Keys) { $loggedParameters[$key] = [string]($PSBoundParameters[$key] -join ',') }
        Open-MRLog -Directory $LogDirectory -Context ([ordered]@{
            Toolkit = $script:MRToolkitVersion; PowerShell = $PSVersionTable.PSVersion.ToString()
            WindowsUser = [Environment]::UserName; Computer = [Environment]::MachineName; Parameters = $loggedParameters
        })
    }
    try { Invoke-MRWorkflow @workflowParameters }
    finally { Close-MRLog }
}
