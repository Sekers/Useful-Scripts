#Requires -Version 7.4
<#
.SYNOPSIS
    Search, review, and remove harmful messages from Exchange Online mailboxes.
.DESCRIPTION
    Uses the non-premium Purview PowerShell workflow. Search never deletes mail.
    Remove requires a saved run, a reviewed Purview CSV report, matching search
    results, and typed confirmation. One purge action is submitted per run.
    Run without parameters for the interactive menu. See README.md for setup.
.EXAMPLE
    .\Invoke-MailRemediation.ps1
.EXAMPLE
    .\Invoke-MailRemediation.ps1 -Mode Search -Ticket INC-1234 `
        -UserPrincipalName admin@contoso.com -TenantId 11111111-1111-1111-1111-111111111111 `
        -SenderAddress suspicious@example.com -Subject 'Update your details' `
        -ReceivedFrom 2026-10-05 -ReceivedThrough 2026-10-06 -WhatIf
.EXAMPLE
    .\Invoke-MailRemediation.ps1 -Mode Remove `
        -RunPath (Join-Path $env:LOCALAPPDATA 'M365-EmailRemediationToolkit\Runs\MR-INC-1234-example') `
        -UserPrincipalName admin@contoso.com -ReportPath C:\Reports\Results.csv
.NOTES
    No Graph permissions, billing setup, application secrets, or local elevation.
    Requires ExchangeOnlineManagement 3.9.0+ and Purview role assignments.
    HardDelete removes user access; holds and recovery can retain service copies.
    Documentation: https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Menu', 'Search', 'Clone', 'Remove', 'Status', 'BrowsePurview')][string]$Mode = 'Menu',
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
    [string]$CaseName = 'Content Search',
    [string]$PurviewUrl = 'https://purview.microsoft.com/ediscovery/',
    [string]$RunPath,
    [string]$ReportPath,
    [ValidateSet('HardDelete', 'SoftDelete')][string]$PurgeType = 'HardDelete',
    [string]$DataDirectory = (Join-Path ([environment]::GetFolderPath('LocalApplicationData')) 'M365-EmailRemediationToolkit\Runs'),
    [string]$SettingsPath = (Join-Path ([environment]::GetFolderPath('LocalApplicationData')) 'M365-EmailRemediationToolkit\settings.json'),
    [switch]$NoSavedSettings,
    [ValidateRange(30, 7200)][int]$TimeoutSeconds = 1800,
    [ValidateRange(1, 30)][int]$PollSeconds = 5
)

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
        throw "Enter a single email address, without a display name or wildcards: '$Value'."
    }
    return $valueTrimmed.ToLowerInvariant()
}

function Get-MRTenantId {
    param([string]$Value)
    $tenant = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$tenant)) {
        throw 'Enter the Tenant ID as a GUID, such as 11111111-1111-1111-1111-111111111111. Copy your own value from Entra ID > Overview > Properties > Tenant ID.'
    }
    return $tenant.ToString()
}

function Get-MRDate {
    param([string]$Value)
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw 'Enter a real UTC calendar date in yyyy-MM-dd format, such as 2026-10-05.'
    }
    return $date
}

function Read-MRProfile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    $settings = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    $allowed = @('SchemaVersion', 'TenantId', 'UserPrincipalName', 'CaseName', 'PurviewUrl', 'DataDirectory')
    if ($settings -isnot [hashtable] -or $settings.SchemaVersion -notin @(1, 2) -or
        @($settings.Keys | Where-Object { $_ -notin $allowed }).Count) {
        throw 'Unsupported settings format. The existing file will be preserved.'
    }
    if ($settings.TenantId -or $settings.UserPrincipalName -or $settings.SchemaVersion -eq 1) {
        $settings.TenantId = ([guid]::Parse($settings.TenantId)).ToString()
        $settings.UserPrincipalName = Get-MREmail $settings.UserPrincipalName
    }
    if ([string]::IsNullOrWhiteSpace($settings.CaseName) -or $settings.CaseName -match '[\r\n\x00-\x1f]') {
        throw 'The saved case name is invalid.'
    }
    $portal = [uri]$settings.PurviewUrl
    if (-not $portal.IsAbsoluteUri -or $portal.Scheme -ne 'https' -or $portal.Host -ne 'purview.microsoft.com' -or $portal.UserInfo) {
        throw 'The saved Purview link is invalid.'
    }
    # A run-specific deep link must never become a default for a different search.
    $settings.PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
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
    $settings = [ordered]@{
        SchemaVersion = 1; TenantId = ([guid]::Parse($Run.TenantId)).ToString()
        UserPrincipalName = Get-MREmail $UserPrincipalName
        CaseName = $Run.CaseName; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
    }
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
        if ($previous.Count -eq $Settings.Count -and -not @($Settings.Keys | Where-Object { [string]$Settings[$_] -cne [string]$previous[$_] }).Count) { return }
        $temporaryPath = Join-Path $parent ("settings-$([guid]::NewGuid().ToString('N')).tmp.json")
        Write-MRJson $temporaryPath $Settings
        $null = Read-MRProfile $temporaryPath
        if (Test-Path -LiteralPath $fullPath) {
            # Replacement is atomic and keeps the previous file as a new backup.
            [IO.File]::Replace($temporaryPath, $fullPath, "$fullPath.$([guid]::NewGuid().ToString('N')).bak")
        } else { [IO.File]::Move($temporaryPath, $fullPath) }
        Write-Host "Tenant defaults saved: $fullPath"
    }
    finally {
        if ($temporaryPath -and [IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
        if ($lock) { $lock.Dispose() }
    }
}

function Read-MRDefault {
    param([string]$Prompt, [string]$Default)
    $label = if ($Default) { "$Prompt [$Default] (Enter to keep)" } else { $Prompt }
    $answer = Read-MRAnswer $label
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

function New-MRQuery {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a string without changing state.')]
    [CmdletBinding()]
    param([string]$SenderAddress, [string]$Subject, [string]$ReceivedFrom,
        [string]$ReceivedThrough, [switch]$AllDates)
    $normalizedSender = Get-MREmail $SenderAddress
    # Values are literal phrases. Do not silently rewrite input or accept raw KQL.
    if ($Subject -match '["*\r\n\x00-\x1f\u201c\u201d]') {
        throw 'Subject cannot contain double quotes, wildcards, smart double quotes, or control characters. Use a distinctive phrase from the subject instead.'
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
    $Mailboxes = @($Mailboxes | ForEach-Object { $_ -split ',' | ForEach-Object { $_.Trim() } })
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
        throw 'Cloning stays in the original tenant. Use Search for a different tenant.'
    }
    $clone.TenantId = $Source.TenantId
    foreach ($name in @('Ticket', 'TicketUrl', 'SenderAddress', 'Subject', 'Mailboxes', 'CaseName')) {
        if ($name -notin $explicit) { $clone[$name] = $Source.$name }
    }
    # An original search deep link would point to the wrong search after cloning.
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
    if ($clone.Interactive) {
        Write-Host 'Enter keeps a value. Type NONE to clear the optional subject or ticket URL.'
        $clone.Ticket = Read-MRValidated 'Ticket or incident number' $clone.Ticket { param($value) if ($value -notmatch '^[A-Za-z0-9#][A-Za-z0-9._#-]{0,63}$' -or $value -notmatch '[A-Za-z0-9]') { throw 'Enter a valid ticket identifier of 1 to 64 characters.' }; $value } -HelpTopic Ticket
        Write-MRPromptHelp TicketUrl
        $clone.TicketUrl = Read-MRDefault 'Ticket URL (optional, NONE to clear)' $clone.TicketUrl
        if ($clone.TicketUrl -ceq 'NONE') { $clone.TicketUrl = '' }
        $clone.SenderAddress = Read-MRValidated 'Sender email address' $clone.SenderAddress { param($value) Get-MREmail $value } -HelpTopic Sender
        $clone.Subject = Read-MRValidated 'Subject phrase (NONE for all subjects)' $clone.Subject { param($value) if ($value -match '["*\r\n\x00-\x1f\u201c\u201d]') { throw 'Use a phrase without quotes, wildcards, or control characters.' }; $value } -HelpTopic Subject
        if ($clone.Subject -ceq 'NONE') { $clone.Subject = '' }
        $firstDate = if ($clone.AllDates) { 'ALL' } else { $clone.ReceivedFrom }
        $clone.ReceivedFrom = Read-MRValidated 'First UTC date (yyyy-MM-dd), or ALL' $firstDate { param($value) if ($value -ieq 'ALL') { 'ALL' } else { (Get-MRDate $value).ToString('yyyy-MM-dd') } } -HelpTopic Dates
        $clone.AllDates = $clone.ReceivedFrom -ceq 'ALL'
        if ($clone.AllDates) { $clone.ReceivedFrom = ''; $clone.ReceivedThrough = '' }
        else { $clone.ReceivedThrough = Read-MRValidated 'Last UTC date (yyyy-MM-dd)' $clone.ReceivedThrough { param($value) $date = Get-MRDate $value; if ($date -lt (Get-MRDate $clone.ReceivedFrom)) { throw 'The last date must be on or after the first date.' }; $date.ToString('yyyy-MM-dd') } }
        $scopeChoice = Read-MRMailboxChoice -CurrentMailboxes $clone.Mailboxes -AllowKeep
        if ($scopeChoice) { foreach ($key in $scopeChoice.Keys) { $clone[$key] = $scopeChoice[$key] } }
        Write-MRPromptHelp CaseName
        if ('CaseName' -in $explicit) { Write-Host "Destination case supplied with -CaseName: $($clone.CaseName)." }
        else { Write-Host "Preferred case from this run: $($clone.CaseName). Choose an active case after Search signs in." }
    }
    # Inherited criteria belong to the selected run, rather than saved defaults.
    $clone.ExplicitParameters = @($explicit + @('TenantId', 'Ticket', 'TicketUrl', 'SenderAddress',
        'Subject', 'Mailboxes', 'CaseName', 'PurviewUrl', 'ReceivedFrom', 'ReceivedThrough', 'AllDates') | Sort-Object -Unique)
    if ($clone.Interactive -and 'CaseName' -notin $explicit) {
        $clone.ExplicitParameters = @($clone.ExplicitParameters | Where-Object { $_ -ne 'CaseName' })
    }
    $clone.SourceRun = $Source
    if ('GroupAddress' -in $explicit -and 'MailboxMode' -notin $explicit) { $clone.MailboxMode = 'Group' }
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
    $line = ($entry | ConvertTo-Json -Depth 10 -Compress -ErrorAction Stop -WarningAction Stop) + [environment]::NewLine
    [IO.File]::AppendAllText((Join-Path $Directory 'events.jsonl'), $line, [text.encoding]::UTF8)
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

function Connect-MRPurview {
    param([string]$UserPrincipalName, [string]$TenantId, [switch]$ReadOnly)
    $null = [guid]::Parse($TenantId)
    $upn = Get-MREmail $UserPrincipalName
    Import-MRExchangeModule
    if (@(Get-ConnectionInformation -ModulePrefix MR -ErrorAction Stop).Count -gt 0) {
        throw 'A connection with prefix MR already exists. Run this tool in a fresh PowerShell session.'
    }
    try {
        Write-Host 'The sign-in window may open behind your current app. Check behind it if you do not see the window.' -ForegroundColor Yellow
        Connect-IPPSSession -UserPrincipalName $upn -Prefix MR -EnableSearchOnlySession -ShowBanner:$false -ErrorAction Stop
        $connections = @(Get-ConnectionInformation -ModulePrefix MR -ErrorAction Stop)
        if ($connections.Count -ne 1 -or -not $connections[0].IsEopSession -or $connections[0].State -ne 'Connected') {
            throw 'Could not identify one connected Purview session. Nothing will be changed.'
        }
        $connection = $connections[0]
        if ([guid]$connection.TenantID -ne [guid]$TenantId -or $connection.UserPrincipalName -ine $upn) {
            throw 'The signed-in tenant or administrator differs from the requested identity. Nothing will be changed.'
        }
        $requiredCommands = if ($ReadOnly) { @('Get-MRComplianceCase', 'Get-MRComplianceSearch') }
            else { @('New-MRComplianceSearch', 'Start-MRComplianceSearch', 'Get-MRComplianceSearch') }
        foreach ($command in $requiredCommands) {
            $null = Get-Command $command -ErrorAction Stop
        }
        return $connection
    }
    catch {
        Disconnect-ExchangeOnline -ModulePrefix MR -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        throw
    }
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
            Write-Progress -Id 36 -Activity "Waiting for Purview $Kind" -Status "$status ($([int]$timer.Elapsed.TotalSeconds) seconds)"
            Start-Sleep -Seconds $PollSeconds
        }
        throw "$Kind did not complete within $TimeoutSeconds seconds. Use Status to check it; do not resubmit a purge."
    }
    finally { Write-Progress -Id 36 -Activity "Waiting for Purview $Kind" -Completed }
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
        if ($Search.Status -ne 'Completed' -or [long]$Search.Items -le 0) { throw 'Removal requires a completed search with matching messages.' }
        if (@(Get-MRProperty $Search 'Errors' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count) { throw 'The search contains errors.' }
        $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
        $total = [long](($locations | Measure-Object Items -Sum).Sum)
        if ($locations.Count -eq 0 -or $total -ne [long]$Search.Items) {
            throw 'Per-location statistics are missing or incomplete. Narrow the search and create a new run; this tool cannot verify the 10-item limit.'
        }
        if (@($locations | Where-Object Items -GT 10).Count) {
            throw 'At least one location has more than 10 matches. Narrow the date/subject/mailbox criteria and create a new run. This tool does not loop purges or claim to remove all historical mail.'
        }
    }
}

function Get-MRResultKey {
    param($Search)
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    return (@([string]$Search.Items, [string]$Search.NumBindings) + @($locations | ForEach-Object { "$($_.Location)=$($_.Items)" })) -join '|'
}

function Show-MRReview {
    param($Run, $Search, [string]$Directory)
    Write-Host "`nTicket: $($Run.Ticket)" -ForegroundColor Cyan
    if ($Run.TicketUrl) { Write-Host "Ticket link: $($Run.TicketUrl)" }
    Write-Host "Search: $($Run.SearchName)"
    Write-Host "Recorded case: $($Run.CaseName)"
    $serviceCaseId = [string](Get-MRProperty $Search 'CaseId')
    if ($serviceCaseId) { Write-Host "Service case ID: $serviceCaseId" }
    Write-Host "Query: $($Run.Query)"
    Write-Host "Mailboxes: $($Run.Mailboxes -join ', ')"
    Write-Host "Status: $($Search.Status); matching items: $($Search.Items); searched locations: $($Search.NumBindings)"
    Write-Host "Purview: $($Run.PurviewUrl)"
    Write-Host "Saved run: $Directory"
    $parent = Get-MRProperty $Run 'ClonedFrom'
    if ($parent) { Write-Host "Cloned from: $($parent.SearchName) ($($parent.RunPath))" }
    Write-Host 'Subject phrases can also match longer subjects. Review the actual matched messages.'
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    if ($locations.Count) {
        Write-Host "Locations with matches: $(@($locations | Where-Object Items -GT 0).Count)"
        if (@($locations | Where-Object Items -GT 10).Count) {
            Write-Warning 'Some locations have more than 10 matches. Narrow the criteria before removal.'
        }
    }
}

function Select-MRRun {
    param([string]$DataDirectory)
    $entries = @(Get-MRRunIndex $DataDirectory)
    $selected = Select-MRList -Entries $entries -Title 'Saved runs (newest first, UTC)' -AllowPath
    if ($selected -is [string]) { return $selected }
    return $selected.Key
}

function Save-MRTicketSummary {
    param([string]$Directory, $Run, $Search, $Action)
    $lines = @(
        "Ticket: $($Run.Ticket)", "Ticket URL: $($Run.TicketUrl)", "Tenant ID: $($Run.TenantId)",
        "Search: $($Run.SearchName)", "Recorded case: $($Run.CaseName)", "Purview: $($Run.PurviewUrl)",
        "Sender: $($Run.SenderAddress)", "Query: $($Run.Query)", "Mailboxes: $($Run.Mailboxes -join ', ')",
        "Search status: $($Search.Status)", "Search matches: $($Search.Items)", "Searched locations: $($Search.NumBindings)",
        "Recorded UTC: $([datetimeoffset]::UtcNow.ToString('o'))"
    )
    $serviceCaseId = [string](Get-MRProperty $Search 'CaseId')
    if ($serviceCaseId) { $lines += "Service case ID: $serviceCaseId" }
    $parent = Get-MRProperty $Run 'ClonedFrom'
    if ($parent) { $lines += "Cloned from: $($parent.SearchName)", "Original saved run: $($parent.RunPath)" }
    if ($Action) {
        $lines += "Purge status: $($Action.Status)", "Provider results: $($Action.Results)", "Provider errors: $($Action.Errors)"
        $lines += 'Completion reports the server action status. Verify latest mailbox locations; retention and recovery may preserve service copies.'
    } else { $lines += 'No removal result is included in this summary.' }
    $summaryName = "ticket-summary-$([datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'))-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
    $path = Join-Path $Directory $summaryName
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'Read')
    try {
        $bytes = [text.encoding]::UTF8.GetBytes($lines -join [environment]::NewLine)
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    Write-Host "Ticket summary: $path"
}

function Invoke-MRWorkflow {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([hashtable]$Options)
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $directory = $null
    $connection = $null
    $runLock = $null
    if ($Options.Mode -eq 'Menu') {
        $menuParameters = @{ Options = $Options; WhatIf = $WhatIfPreference }
        if ($PSBoundParameters.ContainsKey('Confirm')) { $menuParameters.Confirm = $PSBoundParameters.Confirm }
        Invoke-MRMenu @menuParameters
        return
    }
    $Options.Interactive = $Options.ContainsKey('MenuAction') -and $Options.MenuAction
    $Options.SourceRun = $null
    if (-not $Options.ContainsKey('SettingsPath')) { $Options.SettingsPath = '' }
    if (-not $Options.ContainsKey('NoSavedSettings')) { $Options.NoSavedSettings = $false }
    if (-not $Options.ContainsKey('ExplicitParameters')) { $Options.ExplicitParameters = @($Options.Keys) }
    if (-not $Options.ContainsKey('MailboxMode')) { $Options.MailboxMode = 'Paste' }
    if (-not $Options.ContainsKey('GroupAddress')) { $Options.GroupAddress = '' }
    $savedSettings = @{}
    $settingsUsable = $true
    try {
        if ($Options.SettingsPath -and -not $Options.NoSavedSettings) {
            try { $savedSettings = Read-MRProfile $Options.SettingsPath }
            catch { $settingsUsable = $false; Write-Warning "Saved defaults were ignored and will not be overwritten: $($_.Exception.Message)" }
        }
        if ('DataDirectory' -notin $Options.ExplicitParameters -and $savedSettings.ContainsKey('DataDirectory')) { $Options.DataDirectory = $savedSettings.DataDirectory }
        if ($Options.Mode -eq 'BrowsePurview') {
            $browserParameters = @{ Options = $Options; SavedSettings = $savedSettings; WhatIf = $WhatIfPreference }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $browserParameters.Confirm = $PSBoundParameters.Confirm }
            Invoke-MRPurviewBrowser @browserParameters
            return
        }
        if ($Options.Mode -eq 'Clone') {
            if (-not $Options.RunPath) { $Options.RunPath = Select-MRRun $Options.DataDirectory }
            $sourcePath = (Resolve-Path -LiteralPath $Options.RunPath).Path
            $source = Read-MRRun $sourcePath
            Write-Host "Cloning: $($source.SearchName)`nOriginal query: $($source.Query)`nOriginal scope: $($source.Mailboxes -join ', ')"
            $Options = Get-MRCloneOption $source $Options
            $Options.SourcePath = $sourcePath
        }
        if ($Options.Mode -eq 'Search') {
            if (($Options.Interactive -and -not $Options.SourceRun) -or -not $Options.Ticket) {
                $Options.Ticket = Read-MRValidated 'Ticket or incident number' $Options.Ticket { param($value) if ($value -notmatch '^[A-Za-z0-9#][A-Za-z0-9._#-]{0,63}$' -or $value -notmatch '[A-Za-z0-9]') { throw 'Enter a ticket identifier of 1 to 64 characters.' }; $value } -HelpTopic Ticket
            }
            if ($Options.Ticket -notmatch '^[A-Za-z0-9#][A-Za-z0-9._#-]{0,63}$' -or $Options.Ticket -notmatch '[A-Za-z0-9]') { throw 'Use a ticket identifier of 1 to 64 characters, including at least one letter or number. Dots, underscores, hashes, and hyphens are allowed.' }
            if ($Options.Interactive -and -not $Options.SourceRun) {
                $Options.TicketUrl = Read-MRValidated 'Ticket URL (optional, NONE to clear)' $Options.TicketUrl { param($value)
                    if ($value -ceq 'NONE') { return '' }
                    if ($value -and (-not ([uri]$value).IsAbsoluteUri -or ([uri]$value).Scheme -ne 'https')) { throw 'TicketUrl must be an absolute HTTPS URL.' }
                    $value
                } -HelpTopic TicketUrl
            }
            if ('TenantId' -notin $Options.ExplicitParameters -and $savedSettings.Count) { $Options.TenantId = $savedSettings.TenantId }
            if (($Options.Interactive -and -not $Options.SourceRun -and -not $Options.ContainsKey('SelectedCaseTenantId')) -or -not $Options.TenantId) {
                $Options.TenantId = Read-MRValidated 'Expected tenant ID' $Options.TenantId { param($value) Get-MRTenantId $value } -HelpTopic TenantId
            }
            $Options.TenantId = Get-MRTenantId $Options.TenantId
            if ($Options.ContainsKey('SelectedCaseTenantId') -and $Options.TenantId -ne $Options.SelectedCaseTenantId) {
                throw 'The selected case belongs to a different tenant. Return to Browse Purview and select the case in the intended tenant.'
            }
            if ($savedSettings.Count -and $savedSettings.TenantId -eq $Options.TenantId) {
                foreach ($name in @('UserPrincipalName', 'CaseName')) {
                    if ($name -eq 'CaseName' -and $Options.SourceRun) { continue }
                    if ($name -notin $Options.ExplicitParameters) { $Options[$name] = $savedSettings[$name] }
                }
                Write-Host "Using saved defaults from $($Options.SettingsPath). Explicit parameters take precedence."
            }
            if (($Options.Interactive -and -not $Options.ContainsKey('SelectedCaseTenantId')) -or -not $Options.UserPrincipalName) {
                $Options.UserPrincipalName = Read-MRValidated 'Administrator sign-in email' $Options.UserPrincipalName { param($value) Get-MREmail $value } -HelpTopic Administrator
            }
            $Options.UserPrincipalName = Get-MREmail $Options.UserPrincipalName
            if (($Options.Interactive -and -not $Options.SourceRun) -or -not $Options.SenderAddress) { $Options.SenderAddress = Read-MRValidated 'Sender email address to search for' $Options.SenderAddress { param($value) Get-MREmail $value } -HelpTopic Sender }
            $Options.SenderAddress = Get-MREmail $Options.SenderAddress
            if ($Options.Interactive -and -not $Options.SourceRun) {
                if (-not @(@('Mailboxes', 'MailboxMode', 'GroupAddress') | Where-Object { $_ -in $Options.ExplicitParameters }).Count) {
                    $scopeChoice = Read-MRMailboxChoice -CurrentMailboxes $Options.Mailboxes
                    foreach ($key in $scopeChoice.Keys) { $Options[$key] = $scopeChoice[$key] }
                }
            }
            if (-not $Options.ContainsKey('Subject')) { $Options.Subject = Read-MRValidated 'Subject phrase (Enter to search all subjects from this sender)' '' { param($value) if ($value -match '["*\r\n\x00-\x1f\u201c\u201d]') { throw 'Use a phrase without quotes, wildcards, or control characters.' }; $value } -HelpTopic Subject }
            if (-not $Options.AllDates -and (-not $Options.ReceivedFrom -or -not $Options.ReceivedThrough)) {
                Write-MRPromptHelp Dates
                if (-not $Options.ReceivedFrom) { $Options.ReceivedFrom = Read-MRValidated 'First date (yyyy-MM-dd), or ALL for all dates' '' { param($value) if ($value -ieq 'ALL') { 'ALL' } else { (Get-MRDate $value).ToString('yyyy-MM-dd') } } }
                if ($Options.ReceivedFrom -ieq 'ALL') { $Options.AllDates = $true; $Options.ReceivedFrom = ''; $Options.ReceivedThrough = '' }
                elseif (-not $Options.ReceivedThrough) { $Options.ReceivedThrough = Read-MRValidated 'Last date (yyyy-MM-dd)' '' { param($value) $date = Get-MRDate $value; if ($date -lt (Get-MRDate $Options.ReceivedFrom)) { throw 'The last date must be on or after the first date.' }; $date.ToString('yyyy-MM-dd') } }
            }
            $query = New-MRQuery -SenderAddress $Options.SenderAddress -Subject $Options.Subject `
                -ReceivedFrom $Options.ReceivedFrom -ReceivedThrough $Options.ReceivedThrough -AllDates:$Options.AllDates
            if ($Options.GroupAddress -and 'MailboxMode' -notin $Options.ExplicitParameters) { $Options.MailboxMode = 'Group' }
            if ($WhatIfPreference -and $Options.MailboxMode -in @('Select', 'Group')) {
                Write-Host "Offline preview: $($Options.MailboxMode) mailbox selection requires directory resolution during a real Search."
                Write-Host "Tenant: $($Options.TenantId)`nGroup: $($Options.GroupAddress)`nQuery: $query"
                return
            }
            $selection = if ($WhatIfPreference) { [pscustomobject]@{ Mailboxes = $(if ($Options.MailboxMode -eq 'All') { @('All') } else { @(Get-MRScope $Options.Mailboxes) }); Metadata = $null } }
                else { Resolve-MRMailboxScope -Options $Options }
            $scope = @($selection.Mailboxes)
            if ([string]::IsNullOrWhiteSpace($Options.CaseName)) { throw 'An existing non-premium case name is required.' }
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
            if ($selection.Metadata) { $run | Add-Member ScopeSelection $selection.Metadata }
            if ($Options.ContainsKey('ImportedFrom')) { $run | Add-Member ImportedFrom $Options.ImportedFrom }
            if ($Options.SourceRun) {
                $run | Add-Member -NotePropertyName ClonedFrom -NotePropertyValue ([pscustomobject]@{
                    RunId = $Options.SourceRun.RunId; SearchName = $Options.SourceRun.SearchName
                    RunPath = $Options.SourcePath; Query = $Options.SourceRun.Query; PurviewUrl = $Options.SourceRun.PurviewUrl
                    ScopeSelection = Get-MRProperty $Options.SourceRun 'ScopeSelection'
                })
            }
            Write-Host "Tenant: $($run.TenantId)`nMailboxes: $($scope -join ', ')`nQuery: $query"
            if (-not $PSCmdlet.ShouldProcess("Tenant $($run.TenantId)", "Create and run search $searchName")) { return }
            $connection = Connect-MRPurview $Options.UserPrincipalName $run.TenantId
            if ($Options.Interactive -and 'CaseName' -notin $Options.ExplicitParameters) {
                $Options.CaseName = Select-MRPurviewCaseName -PreferredCase $Options.CaseName
                $run.CaseName = $Options.CaseName
            }
            $directory = Join-Path ([IO.Path]::GetFullPath($Options.DataDirectory)) $searchName
            $Options.LastRunPath = $directory
            $null = New-Item -ItemType Directory -Path $directory -ErrorAction Stop
            $runLock = [IO.File]::Open((Join-Path $directory 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
            Write-MRJson (Join-Path $directory 'run.json') $run
            Write-MREvent $directory 'SearchCreating' @{ Administrator = $connection.UserPrincipalName; TenantId = $connection.TenantID }
            $null = New-MRComplianceSearch -Name $searchName -Case $run.CaseName -ExchangeLocation $scope `
                -ContentMatchQuery $query -Description $run.Description -ErrorAction Stop
            Write-MREvent $directory 'SearchCreated' @{ SearchName = $searchName }
            $null = Start-MRComplianceSearch -Identity $searchName -ErrorAction Stop
            $search = Wait-MRJob -Kind Search -SearchName $searchName -TimeoutSeconds $Options.TimeoutSeconds -PollSeconds $Options.PollSeconds
            Test-MRSearch $search $run
            Save-MRSearchBaseline -Directory $directory -Run $run -Search $search
            Write-MREvent $directory 'SearchCompleted' @{ Items = $search.Items; ResultKey = (Get-MRResultKey $search) }
            Show-MRReview $run $search $directory
            Save-MRTicketSummary $directory $run $search $null
            if ($Options.SettingsPath -and -not $Options.NoSavedSettings -and $settingsUsable) {
                try { Save-MRProfile $Options.SettingsPath $run $connection.UserPrincipalName -DataDirectory $Options.DataDirectory -Confirm:$false }
                catch { Write-Warning "Search completed, but defaults could not be saved: $($_.Exception.Message)" }
            }
            Write-Host "`nNothing has been removed. In Purview, find this search, review its results, and export a report-only CSV."
            if ($Options.Interactive) { Show-MRQuickAction -Run $run -Directory $directory }
            else { Write-Host 'Select Remove when you have reviewed the report.' }
            return
        }
        if (-not $Options.RunPath) { $Options.RunPath = Select-MRRun $Options.DataDirectory }
        $directory = (Resolve-Path -LiteralPath $Options.RunPath).Path
        $Options.LastRunPath = $directory
        $run = Read-MRRun $directory
        if ($WhatIfPreference) {
            $previewAction = if ($Options.Mode -eq 'Remove') {
                "Validate a reviewed report and submit one $($Options.PurgeType) purge"
            } else { 'Read current search/action status and save evidence' }
            $null = $PSCmdlet.ShouldProcess("Saved search $($run.SearchName)", $previewAction)
            Write-Host "Saved query: $($run.Query)`nPurview: $($run.PurviewUrl)"
            Write-Host 'This preview does not connect, validate current results, or submit any action.'
            return
        }
        if ($savedSettings.Count -and $savedSettings.TenantId -eq $run.TenantId -and
            'UserPrincipalName' -notin $Options.ExplicitParameters) { $Options.UserPrincipalName = $savedSettings.UserPrincipalName }
        if ($Options.Interactive -or -not $Options.UserPrincipalName) {
            $Options.UserPrincipalName = Read-MRValidated 'Administrator sign-in email' $Options.UserPrincipalName { param($value) Get-MREmail $value } -HelpTopic Administrator
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
                catch { Write-Warning "The search could not be finalized: $($_.Exception.Message)" }
            }
            Show-MRReview $run $search $directory
            if ($action) {
                Save-MRSnapshot $directory 'purge-status' $action
                Write-Host "Purge status: $($action.Status)`nProvider results: $($action.Results)`nProvider errors: $($action.Errors)"
                Write-Host 'A completed action is not proof that every matching service copy was permanently destroyed. Verify mailbox locations in a fresh Purview report.'
            }
            else { Write-Host 'No matching purge action was returned. Check events.jsonl for a submission attempt before considering any further action.' }
            Save-MRTicketSummary $directory $run $search $action
            if ($Options.Interactive) { Show-MRQuickAction -Run $run -Directory $directory }
            return
        }
        $baseline = Get-Content -LiteralPath (Join-Path $directory 'search.json') -Raw | ConvertFrom-Json
        Test-MRSearch $baseline $run -ForRemoval
        $events = @(Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        if ($action -or @($events | Where-Object Event -EQ 'PurgeSubmissionAttempt').Count) {
            throw 'A purge action or submission attempt already exists for this run. Use Status. The tool will not automatically retry, delete action records, or submit another purge.'
        }
        $purgeCommand = Get-Command New-MRComplianceSearchAction -ErrorAction Stop
        if (-not $purgeCommand.Parameters.ContainsKey('Purge')) { throw 'Your Purview session lacks the Search And Purge role.' }
        $previousRunId = [string](Get-MRProperty $search 'JobRunId')
        if (-not $previousRunId) { throw 'Purview did not return a search JobRunId. A fresh completed rerun cannot be verified.' }
        Write-MREvent $directory 'SearchRerunStarting' @{ PreviousJobRunId = $previousRunId }
        $null = Start-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop
        $search = Wait-MRJob -Kind Search -SearchName $run.SearchName -PreviousJobRunId $previousRunId `
            -TimeoutSeconds $Options.TimeoutSeconds -PollSeconds $Options.PollSeconds
        Save-MRSnapshot $directory 'search-before-purge' $search
        Test-MRSearch $search $run -ForRemoval
        if ((Get-MRResultKey $search) -cne (Get-MRResultKey $baseline)) {
            throw 'The matching counts or location distribution changed since the original search. Create and review a new Search run before removal.'
        }
        Show-MRReview $run $search $directory
        Write-Host "`nReview the Purview report for this search, including sender, subject, dates, and mailbox locations."
        Write-Host 'If any messages or locations differ from what you intended, cancel and create a narrower search.'
        $Options.ReportPath = Read-MRReportPath -Path $Options.ReportPath
        $report = Get-Item -LiteralPath $Options.ReportPath
        if ($report.PSIsContainer -or $report.Extension -ine '.csv' -or $report.Length -eq 0) { throw 'Choose a non-empty CSV report exported from Purview.' }
        $sample = Import-Csv -LiteralPath $report.FullName | Select-Object -First 1
        if (-not $sample -or @($sample.PSObject.Properties).Count -lt 2) { throw 'The report must contain a header and at least one metadata row with multiple columns.' }
        $reviewedCount = Read-MRValidated 'Total matching item count you reviewed in Purview (not just a sample)' '' { param($value) if ($value -notmatch '^\d+$' -or [long]$value -ne [long]$search.Items) { throw 'The reviewed count must match the completed search.' }; $value }
        if ($reviewedCount -notmatch '^\d+$' -or [long]$reviewedCount -ne [long]$search.Items) { throw 'The reviewed count does not match the completed PowerShell search.' }
        if ((Read-MRAnswer 'Type REVIEWED to attest you reviewed the report for this exact search and mailbox scope') -cne 'REVIEWED') {
            Write-MREvent $directory 'ReviewCancelled' @{}
            return
        }
        $reportHash = (Get-FileHash -LiteralPath $report.FullName -Algorithm SHA256).Hash
        $copyPath = Join-Path $directory ("reviewed-report-$([guid]::NewGuid().ToString('N')).csv")
        Copy-Item -LiteralPath $report.FullName -Destination $copyPath -ErrorAction Stop
        if ((Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash -ne $reportHash) { throw 'The report changed while it was copied. Removal is blocked.' }
        Write-MREvent $directory 'ReportReviewed' @{ Path = $copyPath; SHA256 = $reportHash; Items = [long]$reviewedCount; Administrator = $connection.UserPrincipalName }
        if ($Options.Interactive -and 'PurgeType' -notin $Options.ExplicitParameters) {
            Write-Host "`nChoose a removal type" -ForegroundColor Cyan
            Write-Host '[HardDelete] Remove messages so users cannot recover them; retained service copies may remain'
            Write-Host '[SoftDelete] Remove messages from normal folders; users can recover them during retention'
            $Options.PurgeType = Read-MRValidated 'Removal type' $Options.PurgeType { param($value) if ($value -notin @('HardDelete', 'SoftDelete')) { throw 'Choose HardDelete or SoftDelete.' }; if ($value -ieq 'HardDelete') { 'HardDelete' } else { 'SoftDelete' } }
        }
        Write-Host "`nRemoval type: $($Options.PurgeType)" -ForegroundColor Yellow
        if ($Options.PurgeType -eq 'HardDelete') { Write-Host 'Users cannot recover these messages. Holds and single item recovery may retain copies in Microsoft 365.' }
        else { Write-Host 'Messages leave normal folders but users can recover them during their configured retention period.' }
        $phrase = "REMOVE $($run.Ticket) $($search.Items) $($Options.PurgeType)"
        if ((Read-MRAnswer "Type exactly '$phrase' to submit removal, or Enter to cancel") -cne $phrase) {
            Write-MREvent $directory 'RemovalCancelled' @{}
            return
        }
        if (-not $PSCmdlet.ShouldProcess("$($run.SearchName), $($search.Items) matches", "Submit one $($Options.PurgeType) purge")) { return }
        $current = Get-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop
        Test-MRSearch $current $run -ForRemoval
        if ((Get-MRResultKey $current) -cne (Get-MRResultKey $search) -or
            [string](Get-MRProperty $current 'JobRunId') -cne [string](Get-MRProperty $search 'JobRunId')) {
            throw 'The search changed during review. Removal is blocked.'
        }
        if (Get-MRAction $run.SearchName) { throw 'A purge action appeared during review. Use Status instead.' }
        # Persist before submitting. An interrupted or failed response must never
        # trigger automatic resubmission of a potentially completed server action.
        Write-MREvent $directory 'PurgeSubmissionAttempt' @{ Type = $Options.PurgeType; Administrator = $connection.UserPrincipalName; Items = $current.Items }
        $submitted = New-MRComplianceSearchAction -SearchName $run.SearchName -Purge -PurgeType $Options.PurgeType -Confirm:$false -ErrorAction Stop
        Save-MRSnapshot $directory 'purge-submitted' $submitted
        $result = Wait-MRJob -Kind Purge -SearchName $run.SearchName -TimeoutSeconds $Options.TimeoutSeconds -PollSeconds $Options.PollSeconds
        Save-MRSnapshot $directory 'purge-result' $result
        Write-MREvent $directory 'PurgeCompleted' @{ Status = $result.Status; Results = $result.Results; Errors = $result.Errors }
        Save-MRTicketSummary $directory $run $current $result
        Write-Host "`nPurge action status: $($result.Status)`nProvider results: $($result.Results)" -ForegroundColor Green
        Write-Host "Evidence and report: $directory`nSearch preserved in Purview: $($run.PurviewUrl)"
        Write-Host 'Verify the latest message locations with a fresh Purview report. Search counts can still include retained Recoverable Items copies.'
        if ($Options.Interactive) { Show-MRQuickAction -Run $run -Directory $directory }
    }
    catch {
        $failure = $_
        if ($runLock -and $directory -and (Test-Path -LiteralPath (Join-Path $directory 'run.json'))) {
            try { Write-MREvent $directory 'Error' @{ Message = $failure.Exception.Message } }
            catch { Write-Warning 'Could not record the error in the run log.' }
            if ($connection) {
                try {
                    $lastSearch = @(Get-MRComplianceSearch -Identity $run.SearchName -ErrorAction Stop | Where-Object Name -EQ $run.SearchName)
                    if ($lastSearch.Count -eq 1) { Save-MRSnapshot $directory 'search-after-error' $lastSearch[0] }
                    $lastAction = Get-MRAction $run.SearchName
                    if ($lastAction) { Save-MRSnapshot $directory 'purge-after-error' $lastAction }
                }
                catch { Write-Warning 'Could not collect additional provider diagnostics. The original error is preserved.' }
            }
        }
        throw $failure
    }
    finally {
        if ($connection) {
            Disconnect-ExchangeOnline -ModulePrefix MR -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        if ($runLock) { $runLock.Dispose() }
    }
}

. (Join-Path $PSScriptRoot 'Private\Interface.ps1')
. (Join-Path $PSScriptRoot 'Private\Directory.ps1')
. (Join-Path $PSScriptRoot 'Private\Purview.ps1')

# Dot-sourcing loads functions for offline tests without connecting or prompting.
if ($MyInvocation.InvocationName -ne '.') {
    $options = @{}
    foreach ($parameterName in @('Mode', 'Ticket', 'TicketUrl', 'UserPrincipalName', 'TenantId',
        'SenderAddress', 'ReceivedFrom', 'ReceivedThrough', 'AllDates', 'Mailboxes', 'MailboxMode', 'GroupAddress', 'CaseName',
        'PurviewUrl', 'RunPath', 'ReportPath', 'PurgeType', 'DataDirectory', 'SettingsPath', 'NoSavedSettings', 'TimeoutSeconds', 'PollSeconds')) {
        $options[$parameterName] = Get-Variable -Name $parameterName -ValueOnly
    }
    if ($PSBoundParameters.ContainsKey('Subject')) { $options.Subject = $Subject }
    $options.ExplicitParameters = @($PSBoundParameters.Keys)
    $workflowParameters = @{ Options = $options; WhatIf = $WhatIfPreference }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $workflowParameters.Confirm = $PSBoundParameters.Confirm }
    Invoke-MRWorkflow @workflowParameters
}
