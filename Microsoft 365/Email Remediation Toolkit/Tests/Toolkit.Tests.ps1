# Offline fixtures. Every directory, sign-in, search, purge, browser and clipboard call is mocked.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-MailRemediation.ps1')
    $script:directoryDataImplementation = (Get-Command Get-MRDirectoryData).ScriptBlock
    function Get-MRComplianceSearch { [CmdletBinding()] param($Identity) }
    function Start-MRComplianceSearch { [CmdletBinding()] param($Identity) }
    function New-MRComplianceSearch { [CmdletBinding()] param($Name, $Case, $ExchangeLocation, $ContentMatchQuery, $Description) }
    function Get-MRComplianceSearchAction { [CmdletBinding()] param($Identity, [switch]$Details) }
    function New-MRComplianceSearchAction { [CmdletBinding(SupportsShouldProcess)] param($SearchName, [switch]$Purge, $PurgeType) }
    function Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)] param($ModulePrefix) }
    function Get-ConnectionInformation { [CmdletBinding()] param($ModulePrefix) }
    function Connect-ExchangeOnline { [CmdletBinding()] param($UserPrincipalName, $Prefix, [bool]$ShowBanner, $CommandName) }
    function Get-MRDMailbox { [CmdletBinding()] param($ResultSize, $RecipientTypeDetails) }
    function Get-MRDRecipient { [CmdletBinding()] param($ResultSize, $RecipientTypeDetails) }
    function Get-MRDDistributionGroupMember { [CmdletBinding()] param($Identity, $ResultSize) }
    function Get-MRDUnifiedGroupLinks { [CmdletBinding()] param($Identity, $LinkType, $ResultSize) }
    function New-ToolkitRun {
        param([string]$Ticket = 'INC-42', [string]$Created = '2026-10-06T12:00:00Z')
        $id = [guid]::NewGuid().ToString()
        [pscustomobject]@{ SchemaVersion = 1; RunId = $id; Ticket = $Ticket; TicketUrl = ''; TenantId = '11111111-1111-1111-1111-111111111111'
            SearchName = "MR-$Ticket-$($id.Substring(0,8))"; CaseName = 'Content Search'; CreatedUtc = $Created
            PurviewUrl = 'https://purview.microsoft.com/ediscovery/case/old-search'; Description = "M365-MailRemediation RunId=$id Ticket=$Ticket"
            SenderAddress = 'phish@example.com'; Subject = 'Cell phone'; ReceivedFrom = ''; ReceivedThrough = ''; AllDates = $true
            Mailboxes = @('All'); Query = New-MRQuery phish@example.com 'Cell phone' -AllDates }
    }
    function New-ToolkitSearch {
        param($Run)
        [pscustomobject]@{ Name = $Run.SearchName; Description = $Run.Description; ContentMatchQuery = $Run.Query
            ExchangeLocation = $Run.Mailboxes; SharePointLocation = @(); OneDriveLocation = @(); ExchangeLocationExclusion = @()
            SharePointLocationExclusion = @(); HoldNames = @(); Status = 'Completed'; JobRunId = 'job'; Items = 1; NumBindings = 1; Errors = ''
            SuccessResults = '{Location: alice@contoso.com, Item count: 1}' }
    }
    function New-ToolkitOption {
        @{ Mode = 'Search'; Ticket = 'INC-42'; TicketUrl = ''; TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com'
            SenderAddress = 'phish@example.com'; Subject = 'Cell phone'; ReceivedFrom = ''; ReceivedThrough = ''; AllDates = $true
            Mailboxes = @('All'); MailboxMode = 'Paste'; GroupAddress = ''; CaseName = 'Content Search'; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
            RunPath = ''; ReportPath = ''; PurgeType = 'HardDelete'; SettingsPath = ''; NoSavedSettings = $true; Interactive = $false
            DataDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString()); TimeoutSeconds = 30; PollSeconds = 1; ExplicitParameters = @() }
    }
    function Save-ToolkitRun {
        param($Run, [string]$Root)
        $path = Join-Path $Root $Run.SearchName
        $null = New-Item -ItemType Directory -Path $path -Force
        Write-MRJson (Join-Path $path 'run.json') $Run
        return $path
    }
    function Set-ToolkitAnswer {
        param([string[]]$Values)
        $script:inputQueue = [collections.generic.Queue[string]]::new()
        foreach ($value in $Values) { $script:inputQueue.Enqueue($value) }
    }
    function New-ToolkitDirectory {
        $mailboxes = @(foreach ($name in @('alice', 'bob', 'carol')) {
            [pscustomobject]@{ Key = "$name@contoso.com"; DisplayName = $name; Type = 'UserMailbox'; Aliases = @("$name.alias@contoso.com")
                Label = "$name <$name@contoso.com>"; SearchText = "$name $name@contoso.com" }
        })
        $groups = @(foreach ($name in @('staff', 'nested', 'team')) {
            [pscustomobject]@{ Key = "$name@contoso.com"; DisplayName = $name; Type = $(if ($name -eq 'team') { 'GroupMailbox' } else { 'MailUniversalDistributionGroup' })
                Label = $name; SearchText = "$name $name@contoso.com" }
        })
        [pscustomobject]@{ Mailboxes = $mailboxes; Groups = $groups }
    }
}

Describe 'Run picker regression and browsing' {
    BeforeEach { Mock Read-Host { $script:inputQueue.Dequeue() } }
    It 'accepts a pasted path with no saved runs under StrictMode' {
        Set-ToolkitAnswer @('C:\example\run')
        & { Set-StrictMode -Version Latest; Select-MRRun (Join-Path $TestDrive 'missing') } | Should -Be 'C:\example\run'
    }
    It 'selects the only saved run under StrictMode' {
        $path = Save-ToolkitRun (New-ToolkitRun) (Join-Path $TestDrive 'one')
        Set-ToolkitAnswer @('1')
        & { Set-StrictMode -Version Latest; Select-MRRun (Split-Path $path) } | Should -Be $path
    }
    It 'orders by creation time rather than ticket and exposes older pages' {
        $root = Join-Path $TestDrive 'many'
        $oldest = ''
        foreach ($number in 1..15) {
            $path = Save-ToolkitRun (New-ToolkitRun "ZZZ-$number" ('2020-01-{0:D2}T00:00:00Z' -f $number)) $root
            if ($number -eq 1) { $oldest = $path }
        }
        $latest = Save-ToolkitRun (New-ToolkitRun AAA) $root
        Set-ToolkitAnswer @('1'); Select-MRRun $root | Should -Be $latest
        Set-ToolkitAnswer @('N', '1'); Select-MRRun $root | Should -Be $oldest
        Set-ToolkitAnswer @('/ZZZ-1 ', '/', '/ZZZ-15', '1'); Select-MRRun $root | Should -BeLike '*MR-ZZZ-15-*'
    }
    It 'retries an invalid selection without losing the list' {
        $path = Save-ToolkitRun (New-ToolkitRun) (Join-Path $TestDrive 'retry')
        Set-ToolkitAnswer @('999999999999999999999', '1')
        Select-MRRun (Split-Path $path) | Should -Be $path
    }
    It 'distinguishes an uncertain submission from a completed removal in saved history' {
        $run = New-ToolkitRun; $root = Join-Path $TestDrive 'removal-history'; $path = Save-ToolkitRun $run $root
        Write-MREvent $path 'PurgeSubmissionAttempt' @{}
        @(Get-MRRunIndex $root)[0].Label | Should -Match 'submission outcome unknown'
        Save-MRSnapshot $path 'purge-result' @{ Status = 'Completed' }
        @(Get-MRRunIndex $root)[0].Label | Should -Match 'removal: Completed'
    }
    It 'supports multiple directory selections across filters without duplicate addresses' {
        $directory = New-ToolkitDirectory
        Set-ToolkitAnswer @('1', '/bob', '1', '/', 'D')
        @(Select-MRList $directory.Mailboxes 'mailboxes' -Multiple).Key | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }
    It 'cancels cleanly from any validated input prompt' {
        Set-ToolkitAnswer @('invalid', ':back')
        { Read-MRValidated 'Email' '' { param($value) Get-MREmail $value } } | Should -Throw '*canceled*'
    }
    It 'offers all mailboxes and normalizes pasted comma-separated addresses' {
        Set-ToolkitAnswer @('1'); (Read-MRMailboxChoice).MailboxMode | Should -Be 'All'
        Set-ToolkitAnswer @('4', 'BOB@contoso.com, alice@contoso.com, bob@contoso.com')
        (Read-MRMailboxChoice).Mailboxes | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }
}

Describe 'Module and host compatibility' {
    It 'rejects incompatible host/module combinations: <Module> on <HostVersion>' -ForEach @(
        @{ Module = '3.9.0'; HostVersion = '7.2.0' }, @{ Module = '3.10.1'; HostVersion = '7.4.0' }
    ) { { Test-MRCompatibility ([version]$Module) ([version]$HostVersion) } | Should -Throw '*requires PowerShell*' }
    It 'accepts supported combinations: <Module> on <HostVersion>' -ForEach @(
        @{ Module = '3.9.2'; HostVersion = '7.4.0' }, @{ Module = '3.10.1'; HostVersion = '7.6.0' }
    ) { { Test-MRCompatibility ([version]$Module) ([version]$HostVersion) } | Should -Not -Throw }
    It 'rejects a module older than the search-only minimum' { { Test-MRCompatibility ([version]'3.8.0') } | Should -Throw '*3.9.0*' }
}

Describe 'Separate directory connection' {
    BeforeEach {
        $script:directoryConnected = $false
        Mock Import-MRExchangeModule {}
        Mock Connect-ExchangeOnline { $script:directoryConnected = $true }
        Mock Disconnect-ExchangeOnline {}
        Mock Get-ConnectionInformation {
            if ($script:directoryConnected) { [pscustomobject]@{ State = 'Connected'; IsEopSession = $false; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com' } }
        }
    }
    It 'imports only the directory commands with its own prefix' {
        Connect-MRDirectory admin@contoso.com 11111111-1111-1111-1111-111111111111 | Should -Not -BeNullOrEmpty
        Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'MRD' -and 'Get-Mailbox' -in $CommandName -and 'Get-Recipient' -in $CommandName }
    }
    It 'rejects the wrong tenant and closes only the directory connection' {
        { Connect-MRDirectory admin@contoso.com 22222222-2222-2222-2222-222222222222 } | Should -Throw '*expected tenant*'
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MRD' }
    }
    It 'does not close or reuse a pre-existing directory connection' {
        $script:directoryConnected = $true
        { Connect-MRDirectory admin@contoso.com 11111111-1111-1111-1111-111111111111 } | Should -Throw '*already exists*'
        Should -Invoke Connect-ExchangeOnline -Times 0; Should -Invoke Disconnect-ExchangeOnline -Times 0
    }
}

Describe 'Directory scope resolution and membership snapshot' {
    BeforeEach {
        $directory = New-ToolkitDirectory; $options = New-ToolkitOption
        Mock Connect-MRDirectory { [pscustomobject]@{ TenantID = $options.TenantId } }
        Mock Disconnect-ExchangeOnline {}
        Mock Get-MRDirectoryData { $directory }
        Mock Read-Host { $script:inputQueue.Dequeue() }
        Mock Get-MRDDistributionGroupMember {
            if ($Identity -eq 'staff@contoso.com') {
                [pscustomobject]@{ PrimarySmtpAddress = 'alice@contoso.com'; RecipientType = 'UserMailbox' }
                [pscustomobject]@{ PrimarySmtpAddress = 'nested@contoso.com'; RecipientType = 'MailUniversalDistributionGroup' }
                [pscustomobject]@{ PrimarySmtpAddress = 'external@example.com'; RecipientType = 'MailContact' }
            } else {
                [pscustomobject]@{ PrimarySmtpAddress = 'alice.alias@contoso.com'; RecipientType = 'UserMailbox' }
                [pscustomobject]@{ PrimarySmtpAddress = 'bob@contoso.com'; RecipientType = 'UserMailbox' }
                [pscustomobject]@{ PrimarySmtpAddress = 'staff@contoso.com'; RecipientType = 'MailUniversalDistributionGroup' }
            }
        }
        Mock Get-MRDUnifiedGroupLinks { [pscustomobject]@{ PrimarySmtpAddress = 'carol@contoso.com'; RecipientTypeDetails = 'UserMailbox' } }
    }
    It 'expands nested groups, handles cycles and aliases, and records excluded contacts' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'staff@contoso.com'
        Set-ToolkitAnswer @('USE 2')
        $resolved = Resolve-MRMailboxScope $options
        $resolved.Mailboxes | Should -Be @('alice@contoso.com', 'bob@contoso.com')
        $resolved.Metadata.ResolvedMailboxes | Should -Be $resolved.Mailboxes
        $resolved.Metadata.ExpandedGroups.Count | Should -Be 2
        $resolved.Metadata.ExcludedMembers[0].Address | Should -Be 'external@example.com'
        Should -Invoke Get-MRDDistributionGroupMember -Times 2 -Exactly -ParameterFilter { $ResultSize -eq 'Unlimited' }
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MRD' }
    }
    It 'selects Microsoft 365 group members rather than the group mailbox' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'team@contoso.com'; Set-ToolkitAnswer @('USE 1')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('carol@contoso.com')
        Should -Invoke Get-MRDUnifiedGroupLinks -Times 1 -Exactly -ParameterFilter { $LinkType -eq 'Members' -and $ResultSize -eq 'Unlimited' }
    }
    It 'closes the directory connection if the administrator cancels the preview' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'staff@contoso.com'; Set-ToolkitAnswer @('')
        { Resolve-MRMailboxScope $options } | Should -Throw '*canceled*'
        Should -Invoke Disconnect-ExchangeOnline -Times 1
    }
    It 'blocks a hidden or unresolved mailbox member rather than silently narrowing the group' {
        Mock Get-MRDDistributionGroupMember { [pscustomobject]@{ PrimarySmtpAddress = 'hidden@contoso.com'; RecipientType = 'UserMailbox' } }
        { Resolve-MRGroupMember $directory.Groups[0] $directory } | Should -Throw '*incomplete*'
    }
    It 'blocks an unknown recipient type instead of treating it as an external contact' {
        Mock Get-MRDDistributionGroupMember { [pscustomobject]@{ PrimarySmtpAddress = 'unknown@contoso.com' } }
        { Resolve-MRGroupMember $directory.Groups[0] $directory } | Should -Throw '*recipient type*'
    }
    It 'resolves pasted aliases to individual primary mailbox addresses' {
        $options.Mailboxes = @('alice.alias@contoso.com', 'ALICE@contoso.com')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('alice@contoso.com')
        Should -Invoke Get-MRDDistributionGroupMember -Times 0
    }
    It 'rejects a group address pasted as an individual mailbox' {
        $options.Mailboxes = @('staff@contoso.com')
        { Resolve-MRMailboxScope $options } | Should -Throw '*Members of a group*'
    }
    It 'selects individual mailboxes and previews the final list' {
        $options.MailboxMode = 'Select'; Set-ToolkitAnswer @('/bob', '1', 'D', 'USE 1')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('bob@contoso.com')
    }
    It 'uses All without a directory connection' {
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('All')
        Should -Invoke Connect-MRDirectory -Times 0
    }
    It 'requests the complete accessible directory instead of the default first thousand results' {
        Mock Get-MRDMailbox { [pscustomobject]@{ DisplayName = 'Alice'; PrimarySmtpAddress = 'alice@contoso.com'; RecipientTypeDetails = 'UserMailbox'; EmailAddresses = @('SMTP:alice@contoso.com', 'smtp:alias@contoso.com') } }
        Mock Get-MRDRecipient { [pscustomobject]@{ DisplayName = 'Staff'; PrimarySmtpAddress = 'staff@contoso.com'; RecipientTypeDetails = 'MailUniversalDistributionGroup' } }
        Mock Get-MRDirectoryData { & $script:directoryDataImplementation }
        $loadedDirectory = Get-MRDirectoryData
        $loadedDirectory.Mailboxes.Key | Should -Be 'alice@contoso.com'
        $loadedDirectory.Mailboxes.Aliases | Should -Contain 'alias@contoso.com'
        $loadedDirectory.Groups.Key | Should -Be 'staff@contoso.com'
        Should -Invoke Get-MRDMailbox -Times 1 -Exactly -ParameterFilter { $ResultSize -eq 'Unlimited' }
        Should -Invoke Get-MRDRecipient -Times 1 -Exactly -ParameterFilter { $ResultSize -eq 'Unlimited' }
    }
}

Describe 'Saved defaults and interrupted search recovery' {
    BeforeEach {
        $run = New-ToolkitRun; $options = New-ToolkitOption
        $settingsPath = Join-Path $TestDrive "settings-$([guid]::NewGuid()).json"
        Mock Connect-MRPurview { [pscustomobject]@{ TenantID = $run.TenantId; UserPrincipalName = 'admin@contoso.com' } }
        Mock Connect-MRDirectory { throw 'Unexpected directory connection' }
        Mock Get-MRAction { $null }; Mock Disconnect-ExchangeOnline {}
        Mock New-MRComplianceSearchAction { throw 'Unexpected purge' }
    }
    It 'does not reuse an old search deep link, including legacy settings files' {
        Write-MRJson $settingsPath @{ SchemaVersion = 1; TenantId = $run.TenantId; UserPrincipalName = 'admin@contoso.com'; CaseName = 'Content Search'; PurviewUrl = $run.PurviewUrl }
        $options.SettingsPath = $settingsPath; $options.NoSavedSettings = $false
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.PurviewUrl | Should -Be 'https://purview.microsoft.com/ediscovery/'
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'stores the resolved group mailbox list in both Purview and the saved run, and never re-expands it for Status' {
        $directoryData = New-ToolkitDirectory
        Mock Connect-MRDirectory { [pscustomobject]@{ TenantID = $run.TenantId } }
        Mock Get-MRDirectoryData { $directoryData }
        Mock Get-MRDDistributionGroupMember { [pscustomobject]@{ PrimarySmtpAddress = 'alice@contoso.com'; RecipientType = 'UserMailbox' } }
        Set-ToolkitAnswer @('USE 1'); Mock Read-Host { $script:inputQueue.Dequeue() }
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'staff@contoso.com'
        Mock New-MRComplianceSearch {
            $script:groupSearch = New-ToolkitSearch $run
            $script:groupSearch.Name = $Name; $script:groupSearch.Description = $Description
            $script:groupSearch.ContentMatchQuery = $ContentMatchQuery; $script:groupSearch.ExchangeLocation = $ExchangeLocation
        }
        Mock Start-MRComplianceSearch {}; Mock Wait-MRJob { $script:groupSearch }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $savedPath = Join-Path $options.DataDirectory $script:groupSearch.Name
        $savedRun = Read-MRRun $savedPath
        $savedRun.Mailboxes | Should -Be @('alice@contoso.com')
        $savedRun.ScopeSelection.ResolvedMailboxes | Should -Be @('alice@contoso.com')
        $savedRun.ScopeSelection.Group.Address | Should -Be 'staff@contoso.com'
        Should -Invoke New-MRComplianceSearch -Times 1 -Exactly -ParameterFilter { $ExchangeLocation.Count -eq 1 -and $ExchangeLocation[0] -eq 'alice@contoso.com' }
        Mock Get-MRComplianceSearch { $script:groupSearch }
        $options.Mode = 'Status'; $options.RunPath = $savedPath
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke Get-MRDDistributionGroupMember -Times 1 -Exactly
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'remembers an approved evidence location and honors an explicit override' {
        Save-MRProfile $settingsPath $run admin@contoso.com -DataDirectory (Join-Path $TestDrive 'approved') -Confirm:$false
        $options.SettingsPath = $settingsPath; $options.NoSavedSettings = $false
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.DataDirectory | Should -Be (Join-Path $TestDrive 'approved')
        $options.DataDirectory = Join-Path $TestDrive 'override'; $options.ExplicitParameters = @('DataDirectory')
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.DataDirectory | Should -Be (Join-Path $TestDrive 'override')
    }
    It 'supports evidence preferences before tenant defaults have been entered' {
        Save-MRPreference $settingsPath @{ SchemaVersion = 2; TenantId = ''; UserPrincipalName = ''; CaseName = 'Content Search'; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; DataDirectory = $TestDrive } -Confirm:$false
        (Read-MRProfile $settingsPath).DataDirectory | Should -Be $TestDrive
    }
    It 'resets even malformed settings while preserving the exact previous contents' {
        Write-MRJson $settingsPath @{ Unsupported = 'keep this' }
        $original = Get-Content -LiteralPath $settingsPath -Raw
        Reset-MRPreference $settingsPath -Confirm:$false
        Test-Path -LiteralPath $settingsPath | Should -BeFalse
        $backup = @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.reset.bak')
        $backup.Count | Should -Be 1
        Get-Content -LiteralPath $backup[0].FullName -Raw | Should -BeExactly $original
    }
    It 'does not reset defaults during WhatIf' {
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        Reset-MRPreference $settingsPath -WhatIf
        Test-Path -LiteralPath $settingsPath | Should -BeTrue
    }
    It 'finalizes a completed search through Status after the original wait was interrupted' {
        $path = Save-ToolkitRun $run (Join-Path $TestDrive 'recovery')
        Write-MREvent $path 'SearchCreated' @{}; Write-MREvent $path 'Error' @{ Message = 'timeout' }
        $completed = New-ToolkitSearch $run; Mock Get-MRComplianceSearch { $completed }
        $options.Mode = 'Status'; $options.RunPath = $path
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Test-Path -LiteralPath (Join-Path $path 'search.json') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $path 'events.jsonl') | ConvertFrom-Json).Event | Should -Contain 'SearchRecovered'
        $hash = (Get-FileHash -LiteralPath (Join-Path $path 'search.json')).Hash
        Invoke-MRWorkflow -Options $options -Confirm:$false
        (Get-FileHash -LiteralPath (Join-Path $path 'search.json')).Hash | Should -Be $hash
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'does not recover a baseline after an ambiguous purge attempt' {
        $path = Save-ToolkitRun $run (Join-Path $TestDrive 'attempt')
        Write-MREvent $path 'SearchCreated' @{}; Write-MREvent $path 'PurgeSubmissionAttempt' @{}
        $completed = New-ToolkitSearch $run; Mock Get-MRComplianceSearch { $completed }
        $options.Mode = 'Status'; $options.RunPath = $path
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Test-Path -LiteralPath (Join-Path $path 'search.json') | Should -BeFalse
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'blocks recovery of an incomplete search or a search whose criteria changed' {
        $path = Save-ToolkitRun $run (Join-Path $TestDrive 'invalid')
        $search = New-ToolkitSearch $run; $search.Status = 'InProgress'
        { Save-MRSearchBaseline $path $run $search } | Should -Throw '*completed*'
        $search.Status = 'Completed'; $search.ContentMatchQuery = 'changed'
        { Save-MRSearchBaseline $path $run $search } | Should -Throw '*changed*'
    }
    It 'keeps directory selection previews offline: <MailboxMode>' -ForEach @(@{ MailboxMode = 'Group' }, @{ MailboxMode = 'Select' }) {
        $options.MailboxMode = $MailboxMode; $options.GroupAddress = 'staff@contoso.com'
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Connect-MRDirectory -Times 0; Should -Invoke Connect-MRPurview -Times 0
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
    }
    It 'rejects saved runs whose resolved membership differs from the search scope' {
        $run.Mailboxes = @('alice@contoso.com')
        $run | Add-Member ScopeSelection ([pscustomobject]@{ ResolvedMailboxes = @('bob@contoso.com') })
        $path = Save-ToolkitRun $run (Join-Path $TestDrive 'tampered')
        { Read-MRRun $path } | Should -Throw '*snapshot*'
    }
}

Describe 'Report selection, quick actions and persistent menu' {
    BeforeEach {
        Mock Read-Host { $script:inputQueue.Dequeue() }
        Mock Start-Process {}; Mock Set-Clipboard {}
    }
    It 'accepts quoted report paths and offers a file picker' {
        $path = Join-Path $TestDrive 'review report.csv'; 'Sender,Subject', 'phish@example.com,Cell phone' | Set-Content -LiteralPath $path
        Read-MRReportPath "`"$path`"" | Should -Be $path
        $selectedReportFile = $path
        Set-ToolkitAnswer @('F'); Mock Select-MRReportFile { $selectedReportFile }
        Read-MRReportPath | Should -Be $path
        Should -Invoke Select-MRReportFile -Times 1
    }
    It 'retries a mistyped report path and handles a canceled file picker' {
        $path = Join-Path $TestDrive 'report.csv'; 'Sender,Subject', 'phish@example.com,Cell phone' | Set-Content -LiteralPath $path
        Set-ToolkitAnswer @('F', 'does-not-exist.csv', $path); Mock Select-MRReportFile { '' }
        Read-MRReportPath | Should -Be $path
    }
    It 'opens the portal, folder and summary and copies the latest ticket summary' {
        $run = New-ToolkitRun; $path = Save-ToolkitRun $run (Join-Path $TestDrive 'quick')
        Save-MRTicketSummary $path $run (New-ToolkitSearch $run) $null
        Set-ToolkitAnswer @('P', 'E', 'T', 'C', '')
        Show-MRQuickAction $run $path
        Should -Invoke Start-Process -Times 3 -Exactly
        Should -Invoke Set-Clipboard -Times 1 -ParameterFilter { $Value -match 'Ticket: INC-42' }
    }
    It 'returns to the menu after an error, permits another action and then quits' {
        $options = New-ToolkitOption; $options.Mode = 'Menu'
        Set-ToolkitAnswer @('bad choice', '1', '3', 'Q')
        Mock Invoke-MRWorkflow { if ($Options.Mode -eq 'Search') { throw 'Search failed' } }
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Invoke-MRWorkflow -Times 1 -ParameterFilter { $Options.Mode -eq 'Search' }
        Should -Invoke Invoke-MRWorkflow -Times 1 -ParameterFilter { $Options.Mode -eq 'Status' }
    }
    It 'edits and persists the evidence location through the settings screen' {
        $options = New-ToolkitOption; $options.SettingsPath = Join-Path $TestDrive 'ui-settings.json'; $options.NoSavedSettings = $false
        $approved = Join-Path $TestDrive 'approved'
        Set-ToolkitAnswer @('E', '', '', '', $approved, '')
        Show-MRSetting $options -Confirm:$false
        (Read-MRProfile $options.SettingsPath).DataDirectory | Should -Be $approved
    }
    It 'ignores the settings screen when defaults are disabled' {
        $options = New-ToolkitOption
        Show-MRSetting $options -Confirm:$false
        Should -Invoke Read-Host -Times 0
    }
}
