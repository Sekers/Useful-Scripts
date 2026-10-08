# Offline fixtures. No live tenant, browser, search creation, or removal calls are made.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-MailRemediation.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    function New-BrowserOption {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        @{ Mode = 'BrowsePurview'; TenantId = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com'
            Ticket = ''; TicketUrl = ''; CaseName = ''; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'
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
    It 'copies supported criteria into a guided search that asks only for the ticket before the review' {
        $draft = Get-MRPurviewDraft $source 'Incident case' $options
        $draft.Mode | Should -Be 'Search'
        $draft.MenuAction | Should -BeTrue
        $draft.CaseName | Should -Be 'Incident case'; $draft.CaseLocked | Should -BeTrue
        $draft.WizardOnly | Should -Be @('Ticket', 'TicketUrl', 'Review')
        $draft.Mailboxes | Should -Be @('alice@contoso.com')
        $draft.ScopeSelection.Mailboxes | Should -Be @('alice@contoso.com')
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
    It 'starts fresh criteria in the chosen case without inheriting a source search or report' {
        $options.SenderAddress = 'old@example.com'; $options.Subject = 'Old subject'
        $options.Ticket = 'OLD-1'; $options.TicketUrl = 'https://helpdesk.example.com/OLD-1'
        $options.AllDates = $true; $options.ReceivedFrom = '2026-10-01'; $options.ReceivedThrough = '2026-10-07'
        $options.Mailboxes = @('alice@contoso.com'); $options.GroupAddress = 'staff@contoso.com'
        $options.ReportPath = 'old-report.csv'; $options.ImportedFrom = $source; $options.LastRunPath = 'old-run'
        $options.ExplicitParameters = @('Subject', 'AllDates', 'Mailboxes', 'GroupAddress', 'Ticket', 'ReportPath', 'DataDirectory')
        $draft = Get-MRPurviewNewDraft 'Incident case' $options
        $draft.Mode | Should -Be 'Search'; $draft.MenuAction | Should -BeTrue
        $draft.CaseName | Should -Be 'Incident case'; $draft.CaseLocked | Should -BeTrue; $draft.TenantId | Should -Be $options.TenantId
        $draft.SelectedCaseTenantId | Should -Be $options.TenantId
        $draft.UserPrincipalName | Should -Be $options.UserPrincipalName
        $draft.SenderAddress | Should -BeNullOrEmpty; $draft.Ticket | Should -BeNullOrEmpty
        $draft.TicketUrl | Should -BeNullOrEmpty; $draft.ReportPath | Should -BeNullOrEmpty
        $draft.ReceivedFrom | Should -BeNullOrEmpty; $draft.ReceivedThrough | Should -BeNullOrEmpty
        $draft.AllDates | Should -BeFalse; $draft.Mailboxes | Should -Be @('All')
        $draft.ContainsKey('Subject') | Should -BeFalse; $draft.ContainsKey('ImportedFrom') | Should -BeFalse
        $draft.ContainsKey('LastRunPath') | Should -BeFalse
        $draft.ExplicitParameters | Should -Contain 'CaseName'; $draft.ExplicitParameters | Should -Contain 'DataDirectory'
        $draft.ExplicitParameters | Should -Not -Contain 'Mailboxes'
        $options.SenderAddress | Should -Be 'old@example.com'; $options.LastRunPath | Should -Be 'old-run'
    }
    It 'refuses to start a search in the built-in Content Search case' {
        { Get-MRPurviewNewDraft 'Content Search' $options } | Should -Throw '*Content Search*'
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
        Set-TestAnswer @('1', '1', '', 'B', 'b')
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
        Mock Get-MRComplianceSearch { @() }; Set-TestAnswer @('1', 'B', 'B')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
    }
    It 'can start a fresh search from an empty Active case without selecting existing criteria' {
        Mock Get-MRComplianceSearch { @() }; Set-TestAnswer @('1', 's')
        $draft = Select-MRPurviewDraft $options
        $draft.CaseName | Should -Be 'Incident case'; $draft.MenuAction | Should -BeTrue
        $draft.SenderAddress | Should -BeNullOrEmpty
        Should -Invoke Get-MRComplianceSearch -Times 0 -ParameterFilter { $Identity }
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'can start a fresh search from unsupported search details without dropping its original conditions' {
        $source.ContentMatchQuery = '(From:phish@example.com) AND (Sent>2026-10-01)'
        Set-TestAnswer @('1', '1', 'N')
        $draft = Select-MRPurviewDraft $options
        $draft.CaseName | Should -Be 'Incident case'; $draft.SenderAddress | Should -BeNullOrEmpty
        $draft.ContainsKey('ImportedFrom') | Should -BeFalse
        $source.ContentMatchQuery | Should -BeExactly '(From:phish@example.com) AND (Sent>2026-10-01)'
        Should -Invoke Set-MRComplianceSearch -Times 0; Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'keeps the fresh-search action available while filtering and paging searches' {
        Mock Get-MRComplianceSearch { foreach ($number in 1..16) { [pscustomobject]@{ Name = ('Search {0:D2}' -f $number); Status = 'NotStarted' } } }
        Set-TestAnswer @('1', 'N', '/no matches', 'S')
        (Select-MRPurviewDraft $options).CaseName | Should -Be 'Incident case'
        Should -Invoke Get-MRComplianceSearch -Times 0 -ParameterFilter { $Identity }
    }
    It 'shows the built-in Content Search case for viewing but offers no new searches there' {
        Mock Get-MRComplianceCase { [pscustomobject]@{ Name = 'Content Search'; Status = 'Active' } }
        $source.CaseName = ''
        Set-TestAnswer @('1', 'S', '1', 'N', 'C', '', 'B', 'B')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'honors an explicit case filter without interpreting saved defaults as a filter' {
        $options.ExplicitParameters = @('CaseName'); $options.CaseName = 'Different case'
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke Get-MRComplianceSearch -Times 0
    }
    It 'rejects a missing identity that unexpectedly returns multiple searches' {
        Mock Get-MRComplianceSearch { @($source, $source) } -ParameterFilter { $Identity }
        Set-TestAnswer @('1', '1')
        { Select-MRPurviewDraft $options } | Should -Throw '*exactly the selected search*'
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'rejects details for another case' {
        $source.CaseName = 'Different case'; Set-TestAnswer @('1', '1')
        { Select-MRPurviewDraft $options } | Should -Throw '*different case*'
    }
    It 'keeps an unsupported query viewable and blocks automatic creation' {
        $source.ContentMatchQuery = 'from:phish@example.com OR subject:"Anything"'
        Set-TestAnswer @('1', '1', 'C', '', 'B', 'B')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'returns copied criteria without modifying the source' {
        Set-TestAnswer @('1', '1', 'c')
        $draft = Select-MRPurviewDraft $options
        $draft.ImportedFrom.Query | Should -Be $source.ContentMatchQuery
        $draft.SenderAddress | Should -Be 'phish@example.com'
        Should -Invoke New-MRComplianceSearch -Times 0; Should -Invoke Set-MRComplianceSearch -Times 0
    }
    It 'stays signed in and starts the new search through the main workflow' {
        $draft = Get-MRPurviewDraft $source 'Incident case' $options
        $script:browserTestDraft = $draft
        Mock Select-MRPurviewDraft { $script:browserTestDraft }
        Mock Invoke-MRWorkflow { $Options.LastRunPath = 'new run' }
        Invoke-MRPurviewBrowser -Options $options -Confirm:$false
        Should -Invoke Connect-MRPurview -Times 1 -Exactly -ParameterFilter { $ReadOnly }
        Should -Invoke Invoke-MRWorkflow -Times 1 -Exactly -ParameterFilter { $Options.Mode -eq 'Search' }
        Should -Invoke Disconnect-ExchangeOnline -Times 0
        $options.LastRunPath | Should -Be 'new run'
    }
    It 'returns to the case list when B is pressed at the first question of the new search' {
        $script:browserDrafts = [collections.generic.Queue[object]]::new()
        $script:browserDrafts.Enqueue((Get-MRPurviewDraft $source 'Incident case' $options)); $script:browserDrafts.Enqueue($null)
        Mock Select-MRPurviewDraft { $script:browserDrafts.Dequeue() }
        Mock Invoke-MRWorkflow { throw (Get-MRBackSignal) }
        Invoke-MRPurviewBrowser -Options $options -Confirm:$false
        Should -Invoke Select-MRPurviewDraft -Times 2 -Exactly
        Should -Invoke Invoke-MRWorkflow -Times 1 -Exactly
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
        Should -Invoke Disconnect-ExchangeOnline -Times 0
    }
    It 'creates a separate tool-owned search with provenance and no inherited approval' {
        $draft = Get-MRPurviewDraft $source 'Incident case' $options; $draft.NoSavedSettings = $true
        Mock Connect-MRExchange {}
        Mock Get-MRTraceResult { New-TestTraceResult $Run -Status Unavailable }
        Mock Show-MRQuickAction {}
        Mock New-MRComplianceSearch {
            $script:importSearch = [pscustomobject]@{ Name = $Name; Description = $Description; ContentMatchQuery = $ContentMatchQuery
                ExchangeLocation = $ExchangeLocation; SharePointLocation = @(); OneDriveLocation = @(); ExchangeLocationExclusion = @(); SharePointLocationExclusion = @(); HoldNames = @()
                Status = 'Completed'; JobRunId = 'new job'; Items = 1; NumBindings = 1; Errors = ''; SuccessResults = '{Location: alice@contoso.com, Item count: 1}' }
        }
        Mock Wait-MRJob { $script:importSearch }
        Set-TestAnswer @('INC-43', '', '')
        Invoke-MRWorkflow -Options $draft -Confirm:$false
        $run = Read-MRRun $draft.LastRunPath
        $run.SearchName | Should -Not -Be $source.Name
        $run.Ticket | Should -Be 'INC-43'
        $run.ImportedFrom.SearchName | Should -Be $source.Name
        $run.ImportedFrom.Query | Should -Be $source.ContentMatchQuery
        $run.Query | Should -BeExactly 'kind:email AND from:"phish@example.com" AND subject:"Cell phone AND details"'
        Should -Invoke Set-MRComplianceSearch -Times 0; Should -Invoke New-MRComplianceSearchAction -Times 0
        @(Get-ChildItem -LiteralPath $draft.LastRunPath -Filter 'reviewed-report-*.csv').Count | Should -Be 0
    }
}

Describe 'Purview case selection and status filters' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $cases = @(
            [pscustomobject]@{ Name = 'A closed incident'; Status = 'Closed' },
            [pscustomobject]@{ Name = 'B active incident'; Status = 'Active' },
            [pscustomobject]@{ Name = 'C other active incident'; Status = 'Active' },
            [pscustomobject]@{ Name = 'D unknown incident' }
        )
        Mock Get-MRComplianceCase { $cases }
    }
    It 'starts with Active cases even when a Closed case sorts first' {
        Set-TestAnswer @('1')
        Select-MRPurviewCaseName -PreferredCase 'A closed incident' | Should -Be 'B active incident'
        $script:testAnswers.Count | Should -Be 0
    }
    It 'never offers the built-in Content Search case as the place for a new search' {
        $cases += [pscustomobject]@{ Name = 'Content Search'; Status = 'Active' }
        Set-TestAnswer @('1')
        Select-MRPurviewCaseName | Should -Be 'B active incident'
        @(Get-MRPurviewCaseEntry -ForNewSearch).Key | Should -Not -Contain 'Content Search'
        @(Get-MRPurviewCaseEntry).Key | Should -Contain 'Content Search'
    }
    It 'combines text and status filters and can restore Active after showing Closed' {
        $entries = @(Get-MRPurviewCaseEntry)
        Set-TestAnswer @('/closed', 'l', '1')
        (Select-MRList -Entries $entries -Title Cases -CaseStatus Active).Key | Should -Be 'A closed incident'
        Set-TestAnswer @('l', 'a', '/other', '1')
        (Select-MRList -Entries $entries -Title Cases -CaseStatus Active).Key | Should -Be 'C other active incident'
    }
    It 'keeps the status choice when clearing only the text filter' {
        $entries = @(Get-MRPurviewCaseEntry)
        Set-TestAnswer @('L', '/missing', '/', '1')
        (Select-MRList -Entries $entries -Title Cases -CaseStatus Active).Status | Should -Be 'Closed'
    }
    It 'keeps an empty Active view navigable and exposes unknown status only under All' {
        $entries = @(Get-MRPurviewCaseEntry) | Where-Object Status -NE Active
        Set-TestAnswer @('T', '/unknown', '1')
        (Select-MRList -Entries $entries -Title Cases -CaseStatus Active).Key | Should -Be 'D unknown incident'
    }
    It 'resets pagination when switching to a smaller status list' {
        $entries = @(1..16 | ForEach-Object { [pscustomobject]@{ Key = "Active $_"; Label = "Active $_"; SearchText = "Active $_"; Status = 'Active' } })
        $entries += [pscustomobject]@{ Key = 'Closed'; Label = 'Closed'; SearchText = 'Closed'; Status = 'Closed' }
        Set-TestAnswer @('N', 'L', '1')
        (Select-MRList -Entries $entries -Title Cases -CaseStatus Active).Key | Should -Be 'Closed'
    }
    It 'does not select a Closed case as the destination of a new search' {
        Set-TestAnswer @('L', '1', '1')
        Select-MRPurviewCaseName | Should -Be 'B active incident'
        $script:testAnswers.Count | Should -Be 0
    }
    It 'rejects ambiguous case names instead of creating a search in an uncertain case' {
        Mock Get-MRComplianceCase { @($cases[1], $cases[1]) }
        Set-TestAnswer @('1')
        { Select-MRPurviewCaseName } | Should -Throw '*ambiguous*'
    }
    It 'provides a route to Purview when no accessible compatible cases exist' {
        Mock Get-MRComplianceCase { @() }; Mock Read-Host { throw 'Unexpected prompt.' }
        { Select-MRPurviewCaseName } | Should -Throw '*Create a case without premium features in Purview*'
        Should -Invoke Read-Host -Times 0
    }
    It 'keeps Closed cases and their search details available for read-only review' {
        $options = New-BrowserOption; $source = New-BrowserSearch; $source.CaseName = 'A closed incident'
        Mock Get-MRComplianceSearch { $source }
        Mock Get-MRPurviewDraft { throw 'Closed searches must stay view-only.' }
        Mock Get-MRPurviewNewDraft { throw 'Closed cases must not start a new draft.' }
        Set-TestAnswer @('L', '1', 'S', '1', 'N', '', 'B', 'B')
        Select-MRPurviewDraft $options | Should -BeNullOrEmpty
        Should -Invoke Get-MRComplianceSearch -Times 2 -Exactly -ParameterFilter { $Case -eq 'A closed incident' }
        Should -Invoke Get-MRPurviewDraft -Times 0
        Should -Invoke Get-MRPurviewNewDraft -Times 0
        $script:testAnswers.Count | Should -Be 0
    }
}

Describe 'Guided search from the menu' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $options = New-BrowserOption; $options.Mode = 'Search'; $options.MenuAction = $true
        $options.NoSavedSettings = $true; $options.ExplicitParameters = @()
        Mock Show-MRQuickAction {}; Mock Disconnect-ExchangeOnline {}
        Mock Connect-MRPurview { [pscustomobject]@{ UserPrincipalName = $options.UserPrincipalName; TenantID = $options.TenantId } }
        Mock Connect-MRExchange {}
        Mock Get-MRTraceResult { New-TestTraceResult $Run -Status Unavailable }
        Mock Get-MRComplianceCase { @([pscustomobject]@{ Name = 'Content Search'; Status = 'Active' }, [pscustomobject]@{ Name = 'Selected active case'; Status = 'Active' }) }
        Mock Start-MRComplianceSearch {}; Mock New-MRComplianceSearchAction {}
        Mock New-MRComplianceSearch {
            $script:pickerSearch = [pscustomobject]@{ Name = $Name; Description = $Description; ContentMatchQuery = $ContentMatchQuery
                ExchangeLocation = $ExchangeLocation; SharePointLocation = @(); OneDriveLocation = @(); ExchangeLocationExclusion = @()
                SharePointLocationExclusion = @(); HoldNames = @(); Status = 'Completed'; JobRunId = 'picker job'; Items = 1; NumBindings = 1; Errors = ''
                SuccessResults = '{Location: alice@contoso.com, Item count: 1}' }
        }
        Mock Wait-MRJob { $script:pickerSearch }
    }
    It 'signs in first, then asks for the case, ticket, link, sender, subject, dates, and mailboxes before the review' {
        Set-TestAnswer @('1', 'INC-55', '', 'phish@example.com', '', '2026-10-05', '2026-10-06', '', '')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $expected = @('Your choice', 'Ticket number', 'Ticket link', 'Sender email address', 'Subject words', 'First day*', 'Last day*', 'Mailboxes', 'Press Enter to create the search*')
        $script:testPrompts.Count | Should -Be $expected.Count
        for ($index = 0; $index -lt $expected.Count; $index++) { $script:testPrompts[$index] | Should -BeLike $expected[$index] }
        (Read-MRRun $options.LastRunPath).CaseName | Should -Be 'Selected active case'
        Should -Invoke Connect-MRExchange -Times 1 -Exactly
        Should -Invoke New-MRComplianceSearch -Times 1 -Exactly -ParameterFilter { $Case -eq 'Selected active case' }
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'uses fresh browser criteria in the selected case and preserves separate evidence' {
        $draft = Get-MRPurviewNewDraft 'Chosen browser case' $options
        Mock Get-MRComplianceCase { throw 'The browser already selected the case.' }
        Set-TestAnswer @('INC-99', '', 'new@example.com', 'New subject', 'ALL', '', '')
        Invoke-MRWorkflow -Options $draft -Confirm:$false
        $run = Read-MRRun $draft.LastRunPath
        $run.CaseName | Should -Be 'Chosen browser case'; $run.Ticket | Should -Be 'INC-99'
        $run.SenderAddress | Should -Be 'new@example.com'; $run.Subject | Should -Be 'New subject'
        $run.PSObject.Properties.Name | Should -Not -Contain 'ImportedFrom'
        Should -Invoke New-MRComplianceSearch -Times 1 -Exactly -ParameterFilter { $Case -eq 'Chosen browser case' -and $ContentMatchQuery -eq 'kind:email AND from:"new@example.com" AND subject:"New subject"' }
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'blocks a fresh browser draft if its tenant is changed after case selection' {
        $draft = Get-MRPurviewNewDraft 'Chosen browser case' $options
        $draft.TenantId = '22222222-2222-2222-2222-222222222222'
        { Invoke-MRWorkflow -Options $draft -Confirm:$false } | Should -Throw '*case belongs to a different tenant*'
        Should -Invoke Connect-MRPurview -Times 0; Should -Invoke New-MRComplianceSearch -Times 0
        Test-Path -LiteralPath $draft.DataDirectory | Should -BeFalse
    }
    It 'goes back to the main menu from the first question without creating anything or signing out' {
        Set-TestAnswer @('B')
        $failure = $null
        try { Invoke-MRWorkflow -Options $options -Confirm:$false } catch { $failure = $_ }
        Test-MRBackSignal $failure | Should -BeTrue
        Should -Invoke New-MRComplianceSearch -Times 0
        Should -Invoke Disconnect-ExchangeOnline -Times 0
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
    }
    It 'keeps previews offline without fetching cases' {
        Set-TestAnswer @('INC-55', '', 'phish@example.com', '', 'ALL', '', '')
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Get-MRComplianceCase -Times 0; Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'respects an explicitly supplied case without showing the case list' {
        $options.CaseName = 'Explicit case'; $options.ExplicitParameters += 'CaseName'
        Set-TestAnswer @('INC-55', '', 'phish@example.com', '', 'ALL', '', '')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke Get-MRComplianceCase -Times 0
        Should -Invoke New-MRComplianceSearch -Times 1 -Exactly -ParameterFilter { $Case -eq 'Explicit case' }
    }
    It 'keeps the case of a copied run when it is still Active, and opens at the review' {
        $source = New-TestRun; $source.CaseName = 'Selected active case'
        $sourcePath = Save-TestRun $source (Join-Path $TestDrive 'copy-source')
        $options.Mode = 'Clone'; $options.RunPath = $sourcePath
        Set-TestAnswer @('')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $copy = Read-MRRun $options.LastRunPath
        $copy.CaseName | Should -Be 'Selected active case'
        $copy.ClonedFrom.SearchName | Should -Be $source.SearchName
        $script:testPrompts.Count | Should -Be 1
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
    BeforeEach { Set-StrictMode -Version Latest; $options = New-BrowserOption; $options.Mode = 'Menu'; Mock Connect-MRPurview {}; Mock Start-Process {}; Mock Get-MRSignedInAccount { @() } }
    It 'offers setup before the first action and persists only the chosen defaults' {
        Set-TestAnswer @('y', '', '', '', '', 'Q')
        Invoke-MRMenu $options -Confirm:$false
        $settings = Read-MRProfile $options.SettingsPath
        $settings.TenantId | Should -Be $options.TenantId
        $settings.UserPrincipalName | Should -Be $options.UserPrincipalName
        $settings.DataDirectory | Should -Be $options.DataDirectory
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'offers setup through the main workflow with no initial tenant or account' {
        $options.TenantId = ''; $options.UserPrincipalName = ''
        Set-TestAnswer @('YES', '11111111-1111-1111-1111-111111111111', 'admin@contoso.com', '', '', 'Q')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $settings = Read-MRProfile $options.SettingsPath
        $settings.TenantId | Should -Be '11111111-1111-1111-1111-111111111111'
        $settings.UserPrincipalName | Should -Be 'admin@contoso.com'
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'allows setup to be skipped without creating a settings file' {
        Set-TestAnswer @('n', 'Q'); Invoke-MRMenu $options -Confirm:$false
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'does not prompt for setup when a settings file already exists' {
        Save-MRPreference $options.SettingsPath @{ SchemaVersion = 2; TenantId = ''; UserPrincipalName = ''; PurviewUrl = $options.PurviewUrl; DataDirectory = $options.DataDirectory } -Confirm:$false
        Set-TestAnswer @('Q'); Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Read-Host -Times 1 -Exactly
    }
    It 'keeps preview and disabled-settings launches free of setup writes' -ForEach @(@{ Preview = $true }, @{ Preview = $false }) {
        $options.NoSavedSettings = -not $Preview
        Set-TestAnswer @('Q'); Invoke-MRMenu $options -WhatIf:$Preview -Confirm:$false
        Should -Invoke Read-Host -Times 1 -Exactly
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'returns to the menu after canceled setup' {
        Set-TestAnswer @('y', ':cancel', 'Q'); Invoke-MRMenu $options -Confirm:$false
        Test-Path -LiteralPath $options.SettingsPath | Should -BeFalse
    }
    It 'routes menu option 5 to Purview browsing' {
        $options.NoSavedSettings = $true; Set-TestAnswer @('5', 'Q'); Mock Invoke-MRWorkflow {}
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Invoke-MRWorkflow -Times 1 -Exactly -ParameterFilter { $Options.Mode -eq 'BrowsePurview' }
    }
}
