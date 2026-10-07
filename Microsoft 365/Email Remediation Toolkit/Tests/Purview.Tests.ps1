# Offline fixtures. No live tenant, browser, search creation, or removal calls are made.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-MailRemediation.ps1')
    function Get-MRComplianceCase { [CmdletBinding()] param($CaseType) }
    function Get-MRComplianceSearch { [CmdletBinding()] param($Identity, $Case, $ResultSize) }
    function New-MRComplianceSearch { [CmdletBinding()] param($Name, $Case, $ExchangeLocation, $ContentMatchQuery, $Description) }
    function Start-MRComplianceSearch { [CmdletBinding()] param($Identity) }
    function New-MRComplianceSearchAction { [CmdletBinding(SupportsShouldProcess)] param($SearchName, [switch]$Purge, $PurgeType) }
    function Set-MRComplianceSearch { [CmdletBinding()] param($Identity, $ContentMatchQuery) }
    function Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)] param($ModulePrefix) }
    function Get-ConnectionInformation { [CmdletBinding()] param($ModulePrefix) }
    function Connect-IPPSSession { [CmdletBinding()] param($UserPrincipalName, $Prefix, [switch]$EnableSearchOnlySession, [bool]$ShowBanner) }
    function New-BrowserOption {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        @{ Mode = 'BrowsePurview'; TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com'
            Ticket = ''; TicketUrl = ''; CaseName = 'Content Search'; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
            SenderAddress = ''; ReceivedFrom = ''; ReceivedThrough = ''; AllDates = $false; Mailboxes = @('All'); MailboxMode = 'Paste'; GroupAddress = ''
            RunPath = ''; ReportPath = ''; PurgeType = 'HardDelete'; SettingsPath = Join-Path $fixtureRoot 'profile\settings.json'
            DataDirectory = Join-Path $fixtureRoot 'evidence'; NoSavedSettings = $false; Interactive = $false; TimeoutSeconds = 30; PollSeconds = 1; ExplicitParameters = @() }
    }
    function New-BrowserSearch {
        [pscustomobject]@{ Name = 'Existing phishing search'; CaseName = 'Incident case'; Status = 'Completed'; Items = 1; Size = 100; NumBindings = 1
            ContentMatchQuery = 'from:"phish@example.com" AND subject:"Cell phone AND details"'
            ExchangeLocation = @('alice@contoso.com'); SharePointLocation = @(); OneDriveLocation = @()
            ExchangeLocationExclusion = @(); SharePointLocationExclusion = @(); HoldNames = @(); Errors = '' }
    }
    function Set-BrowserAnswer {
        param([string[]]$Answers)
        $script:browserAnswers = [collections.generic.queue[string]]::new()
        foreach ($answer in $Answers) { $script:browserAnswers.Enqueue($answer) }
        Mock Read-Host { if (-not $script:browserAnswers.Count) { throw 'Unexpected prompt.' }; $script:browserAnswers.Dequeue() }
    }
}

Describe 'Supported Purview query conversion' {
    BeforeEach { Set-StrictMode -Version Latest }
    It 'keeps AND inside a quoted subject and adds the explicit email condition' {
        $criteria = ConvertFrom-MRPurviewQuery 'from:"PHISH@example.com" AND subject:"Cell phone AND details"'
        $criteria.SenderAddress | Should -Be 'phish@example.com'
        $criteria.Subject | Should -Be 'Cell phone AND details'
        $criteria.AllDates | Should -BeTrue
        $criteria.Query | Should -BeExactly 'kind:email AND from:"phish@example.com" AND subject:"Cell phone AND details"'
    }
    It 'accepts reordered supported terms and individual parentheses without changing the date interval' {
        $criteria = ConvertFrom-MRPurviewQuery '(received<2024-03-01) AND (from:phish@example.com) AND kind:email AND received>=2024-02-28'
        $criteria.ReceivedFrom | Should -Be '2024-02-28'
        $criteria.ReceivedThrough | Should -Be '2024-02-29'
        $criteria.AllDates | Should -BeFalse
    }
    It 'rejects unsupported or ambiguous query syntax: <Query>' -ForEach @(
        @{ Query = 'from:phish@example.com OR from:other@example.com' },
        @{ Query = 'from:phish@example.com AND NOT subject:"safe"' },
        @{ Query = 'from:phish@example.com AND recipients:alice@contoso.com' },
        @{ Query = 'from:phish@example.com AND subject:Cell' },
        @{ Query = 'from:phish@example.com AND subject:"Cell*"' },
        @{ Query = 'from:*@example.com' },
        @{ Query = 'from:phish@example.com AND from:other@example.com' },
        @{ Query = 'kind:email' },
        @{ Query = 'from:phish@example.com AND received>=2026-10-05' },
        @{ Query = 'from:phish@example.com AND received<=2026-10-06' },
        @{ Query = 'from:phish@example.com AND received>=2026-10-06 AND received<2026-10-06' },
        @{ Query = 'from:phish@example.com AND received>=2026-02-30 AND received<2026-03-02' },
        @{ Query = '(from:phish@example.com AND subject:"Cell")' },
        @{ Query = 'from:phish@example.com AND' }
    ) { { ConvertFrom-MRPurviewQuery $Query } | Should -Throw }
}

Describe 'Purview source eligibility and provenance' {
    BeforeEach { Set-StrictMode -Version Latest; $options = New-BrowserOption; $source = New-BrowserSearch }
    It 'creates a fresh Search draft with fixed criteria and records the original query' {
        $draft = Get-MRPurviewDraft $source 'Incident case' $options
        $draft.Mode | Should -Be 'Search'
        $draft.MenuAction | Should -BeFalse
        $draft.CaseName | Should -Be 'Incident case'
        $draft.Mailboxes | Should -Be @('alice@contoso.com')
        $draft.SenderAddress | Should -Be 'phish@example.com'
        $draft.ImportedFrom.SearchName | Should -Be $source.Name
        $draft.ImportedFrom.Query | Should -Be $source.ContentMatchQuery
        $draft.ExplicitParameters | Should -Contain 'TenantId'
        $options.Mode | Should -Be 'BrowsePurview'
    }
    It 'preserves the All-mailbox scope' {
        $source.ExchangeLocation = @('All')
        (Get-MRPurviewDraft $source 'Incident case' $options).MailboxMode | Should -Be 'All'
    }
    It 'refuses to drop non-email locations or exclusions: <Property>' -ForEach @(
        @{ Property = 'SharePointLocation' }, @{ Property = 'OneDriveLocation' }, @{ Property = 'ExchangeLocationExclusion' },
        @{ Property = 'SharePointLocationExclusion' }, @{ Property = 'HoldNames' }
    ) { $source.$Property = @('restricted location'); { Get-MRPurviewDraft $source 'Incident case' $options } | Should -Throw }
    It 'rejects missing or unresolvable Exchange locations rather than assuming All' {
        $source.ExchangeLocation = @(); { Get-MRPurviewDraft $source 'Incident case' $options } | Should -Throw
        $source.ExchangeLocation = @('11111111-1111-1111-1111-111111111111'); { Get-MRPurviewDraft $source 'Incident case' $options } | Should -Throw
    }
}

Describe 'Existing Purview browser' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $options = New-BrowserOption; $source = New-BrowserSearch
        Mock Get-MRComplianceCase { [pscustomobject]@{ Name = 'Incident case'; Status = 'Active' } }
        Mock Get-MRComplianceSearch { if ($Identity) { $source } else { [pscustomobject]@{ Name = $source.Name; Status = $source.Status } } }
        Mock New-MRComplianceSearch {}; Mock Start-MRComplianceSearch {}; Mock New-MRComplianceSearchAction {}; Mock Set-MRComplianceSearch {}; Mock Start-Process {}
        Mock Connect-MRPurview { [pscustomobject]@{ TenantID = $options.TenantId; UserPrincipalName = $options.UserPrincipalName } }
        Mock Disconnect-ExchangeOnline {}
    }
    It 'lists standard cases and all searches, then retrieves full details only for the selected name' {
        Set-BrowserAnswer @('1', '1', '', 'C', 'C')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke Get-MRComplianceCase -Times 1 -Exactly -ParameterFilter { $CaseType -eq 'eDiscovery' }
        Should -Invoke Get-MRComplianceSearch -Times 1 -Exactly -ParameterFilter { -not $Identity -and $Case -eq 'Incident case' -and $ResultSize -eq 'Unlimited' }
        Should -Invoke Get-MRComplianceSearch -Times 1 -Exactly -ParameterFilter { $Identity -eq $source.Name -and $Case -eq 'Incident case' }
        Should -Invoke New-MRComplianceSearch -Times 0; Should -Invoke Start-MRComplianceSearch -Times 0
        Should -Invoke New-MRComplianceSearchAction -Times 0; Should -Invoke Set-MRComplianceSearch -Times 0
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
    }
    It 'handles no accessible cases without prompting' {
        Mock Get-MRComplianceCase { @() }; Mock Read-Host { throw 'Unexpected prompt.' }
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke Read-Host -Times 0; Should -Invoke Get-MRComplianceSearch -Times 0
    }
    It 'handles an empty case and lets the operator leave' {
        Mock Get-MRComplianceSearch { @() }; Set-BrowserAnswer @('1', 'C')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
    }
    It 'honors an explicit case filter without interpreting saved defaults as a filter' {
        $options.ExplicitParameters = @('CaseName'); $options.CaseName = 'Different case'
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke Get-MRComplianceSearch -Times 0
    }
    It 'rejects a missing identity that unexpectedly returns multiple searches' {
        Mock Get-MRComplianceSearch { @($source, $source) } -ParameterFilter { $Identity }
        Set-BrowserAnswer @('1', '1')
        { Select-MRPurviewDraft $options } | Should -Throw '*exactly the selected search*'
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'rejects details for another case' {
        $source.CaseName = 'Different case'; Set-BrowserAnswer @('1', '1')
        { Select-MRPurviewDraft $options } | Should -Throw '*different case*'
    }
    It 'keeps an unsupported query viewable and blocks automatic creation' {
        $source.ContentMatchQuery = 'from:phish@example.com OR subject:"Anything"'
        Set-BrowserAnswer @('1', '1', 'C', '', 'C', 'C')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'requires typed creation confirmation and returns reviewed criteria without modifying the source' {
        Set-BrowserAnswer @('1', '1', 'C', 'INC-43', '', 'CREATE INC-43')
        $draft = Select-MRPurviewDraft $options
        $draft.Ticket | Should -Be 'INC-43'
        $draft.ImportedFrom.Query | Should -Be $source.ContentMatchQuery
        Should -Invoke New-MRComplianceSearch -Times 0; Should -Invoke Set-MRComplianceSearch -Times 0
    }
    It 'closes its read-only session before starting a reviewed new workflow' {
        $draft = Get-MRPurviewDraft $source 'Incident case' $options; $draft.Ticket = 'INC-43'
        $script:browserTestDraft = $draft
        Mock Select-MRPurviewDraft { $script:browserTestDraft }
        $script:browserClosed = $false
        Mock Disconnect-ExchangeOnline { $script:browserClosed = $true }
        Mock Invoke-MRWorkflow { if (-not $script:browserClosed) { throw 'Browser session was not closed.' }; $Options.LastRunPath = 'new run' }
        Invoke-MRPurviewBrowser -Options $options -Confirm:$false
        Should -Invoke Connect-MRPurview -Times 1 -Exactly -ParameterFilter { $ReadOnly }
        Should -Invoke Invoke-MRWorkflow -Times 1 -Exactly -ParameterFilter { $Options.Mode -eq 'Search' -and $Options.Ticket -eq 'INC-43' }
        $options.LastRunPath | Should -Be 'new run'
    }
    It 'closes only its session after a retrieval failure' {
        Mock Select-MRPurviewDraft { throw 'Permission failure.' }
        { Invoke-MRPurviewBrowser -Options $options } | Should -Throw '*Permission failure*'
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MR' }
    }
    It 'previews browsing without sign-in, prompts or writes' {
        Mock Read-Host { throw 'Unexpected prompt.' }
        Invoke-MRPurviewBrowser -Options $options -WhatIf
        Should -Invoke Read-Host -Times 0; Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke Get-MRComplianceCase -Times 0; Should -Invoke New-MRComplianceSearch -Times 0
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'opens through the main workflow with an empty saved profile' {
        Mock Select-MRPurviewDraft { $null }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke Connect-MRPurview -Times 1 -Exactly -ParameterFilter { $ReadOnly }
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly
    }
    It 'creates a separate tool-owned search with provenance and no inherited approval' {
        $draft = Get-MRPurviewDraft $source 'Incident case' $options; $draft.Ticket = 'INC-43'; $draft.NoSavedSettings = $true
        Mock Resolve-MRMailboxScope { [pscustomobject]@{ Mailboxes = $draft.Mailboxes; Metadata = $null } }
        Mock New-MRComplianceSearch {
            $script:importSearch = [pscustomobject]@{ Name = $Name; Description = $Description; ContentMatchQuery = $ContentMatchQuery
                ExchangeLocation = $ExchangeLocation; SharePointLocation = @(); OneDriveLocation = @(); ExchangeLocationExclusion = @(); SharePointLocationExclusion = @(); HoldNames = @()
                Status = 'Completed'; JobRunId = 'new job'; Items = 1; NumBindings = 1; Errors = ''; SuccessResults = '{Location: alice@contoso.com, Item count: 1}' }
        }
        Mock Wait-MRJob { $script:importSearch }; Mock Read-Host { throw 'Unexpected prompt.' }
        Invoke-MRWorkflow -Options $draft -Confirm:$false
        $run = Read-MRRun $draft.LastRunPath
        $run.SearchName | Should -Not -Be $source.Name
        $run.ImportedFrom.SearchName | Should -Be $source.Name
        $run.ImportedFrom.Query | Should -Be $source.ContentMatchQuery
        $run.Query | Should -BeExactly 'kind:email AND from:"phish@example.com" AND subject:"Cell phone AND details"'
        Should -Invoke Set-MRComplianceSearch -Times 0; Should -Invoke New-MRComplianceSearchAction -Times 0
        @(Get-ChildItem -LiteralPath $draft.LastRunPath -Filter 'reviewed-report-*.csv').Count | Should -Be 0
    }
}

Describe 'Read-only Purview connection commands' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $options = New-BrowserOption
        $script:readOnlyConnected = $false
        $readConnection = [pscustomobject]@{ IsEopSession = $true; State = 'Connected'; TenantID = $options.TenantId; UserPrincipalName = $options.UserPrincipalName }
        Mock Import-MRExchangeModule {}
        Mock Connect-IPPSSession { $script:readOnlyConnected = $true }
        Mock Get-ConnectionInformation { if ($script:readOnlyConnected) { $readConnection } }
        Mock Disconnect-ExchangeOnline {}
        Mock Get-Command { if ($Name -notin @('Get-MRComplianceCase', 'Get-MRComplianceSearch')) { throw 'Write commands are unavailable.' }; [pscustomobject]@{ Name = $Name } }
    }
    It 'requires only case and search read commands for browsing' {
        $connection = Connect-MRPurview $options.UserPrincipalName $options.TenantId -ReadOnly
        $connection.TenantID | Should -Be $options.TenantId
        Should -Invoke Get-Command -Times 2 -Exactly
        Should -Invoke Get-Command -Times 0 -ParameterFilter { $Name -like 'New-*' -or $Name -like 'Start-*' }
    }
    It 'preserves the normal Search write-command check' {
        { Connect-MRPurview $options.UserPrincipalName $options.TenantId } | Should -Throw '*Write commands are unavailable*'
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly
    }
}

Describe 'First-run menu setup' {
    BeforeEach { Set-StrictMode -Version Latest; $options = New-BrowserOption; $options.Mode = 'Menu'; Mock Connect-MRPurview {}; Mock Start-Process {} }
    It 'offers setup before the first action and persists only the chosen defaults' {
        Set-BrowserAnswer @('y', '', '', '', '', 'Q')
        Invoke-MRMenu $options -Confirm:$false
        $settings = Read-MRProfile $options.SettingsPath
        $settings.TenantId | Should -Be $options.TenantId
        $settings.UserPrincipalName | Should -Be $options.UserPrincipalName
        $settings.DataDirectory | Should -Be $options.DataDirectory
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'offers setup through the main workflow with no initial tenant or account' {
        $options.TenantId = ''; $options.UserPrincipalName = ''
        Set-BrowserAnswer @('y', '11111111-1111-1111-1111-111111111111', 'admin@contoso.com', '', '', 'Q')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $settings = Read-MRProfile $options.SettingsPath
        $settings.TenantId | Should -Be '11111111-1111-1111-1111-111111111111'
        $settings.UserPrincipalName | Should -Be 'admin@contoso.com'
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'allows setup to be skipped without creating a settings file' {
        Set-BrowserAnswer @('n', 'Q'); Invoke-MRMenu $options -Confirm:$false
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'does not prompt for setup when a settings file already exists' {
        Save-MRPreference $options.SettingsPath @{ SchemaVersion = 2; TenantId = ''; UserPrincipalName = ''; CaseName = 'Content Search'; PurviewUrl = $options.PurviewUrl; DataDirectory = $options.DataDirectory } -Confirm:$false
        Set-BrowserAnswer @('Q'); Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Read-Host -Times 1 -Exactly
    }
    It 'keeps preview and disabled-settings launches free of setup writes' -ForEach @(@{ Preview = $true }, @{ Preview = $false }) {
        $options.NoSavedSettings = -not $Preview
        Set-BrowserAnswer @('Q'); Invoke-MRMenu $options -WhatIf:$Preview -Confirm:$false
        Should -Invoke Read-Host -Times 1 -Exactly
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'returns to the menu after canceled setup' {
        Set-BrowserAnswer @('y', ':cancel', 'Q'); Invoke-MRMenu $options -Confirm:$false
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'routes menu option 5 to Purview browsing' {
        $options.NoSavedSettings = $true; Set-BrowserAnswer @('5', 'Q'); Mock Invoke-MRWorkflow {}
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Invoke-MRWorkflow -Times 1 -Exactly -ParameterFilter { $Options.Mode -eq 'BrowsePurview' }
    }
}
