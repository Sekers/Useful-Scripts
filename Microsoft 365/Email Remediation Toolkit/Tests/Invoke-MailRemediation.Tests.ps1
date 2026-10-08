# Offline tests. All Microsoft 365 calls are replaced with mocks.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-MailRemediation.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
}

Describe 'Query and mailbox scope' {
    It 'includes the entire last UTC day and handles a year boundary' {
        New-MRQuery -SenderAddress PHISH@example.com -Subject 'Update details' -ReceivedFrom 2026-12-31 -ReceivedThrough 2026-12-31 |
            Should -BeExactly 'kind:email AND from:"phish@example.com" AND subject:"Update details" AND received>=2026-12-31 AND received<2027-01-01'
    }
    It 'allows a sender-only search with an explicit AllDates choice' {
        New-MRQuery -SenderAddress phish@example.com -AllDates | Should -BeExactly 'kind:email AND from:"phish@example.com"'
    }
    It 'rejects unsafe or invalid sender input: <Value>' -ForEach @(
        @{ Value = '' }, @{ Value = '*@example.com' }, @{ Value = 'Someone <phish@example.com>' },
        @{ Value = 'phish@example.com OR kind:email' }, @{ Value = 'phish@example.com"' }
    ) { { New-MRQuery -SenderAddress $Value -AllDates } | Should -Throw }
    It 'rejects subject input that could alter phrase matching: <Value>' -ForEach @(
        @{ Value = '" OR kind:email' }, @{ Value = '*' }, @{ Value = "One`nTwo" }, @{ Value = "Smart $([char]0x201C)quote$([char]0x201D)" }
    ) { { New-MRQuery -SenderAddress phish@example.com -Subject $Value -AllDates } | Should -Throw }
    It 'rejects reversed or ambiguous dates and date/AllDates combinations' {
        { New-MRQuery phish@example.com '' 2026-10-06 2026-10-05 } | Should -Throw
        { New-MRQuery phish@example.com '' 10/05/26 2026-10-06 } | Should -Throw
        { New-MRQuery phish@example.com '' 2026-10-05 '' } | Should -Throw
        { New-MRQuery phish@example.com '' 2026-10-05 2026-10-06 -AllDates } | Should -Throw
    }
    It 'rejects All mixed with individual mailboxes and normalizes a pilot scope' {
        { Get-MRScope @('All', 'alice@contoso.com') } | Should -Throw
        @(Get-MRScope @('BOB@contoso.com', 'alice@contoso.com', 'bob@contoso.com')) | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }
}

Describe 'Copying a saved search' {
    BeforeEach {
        $run = New-TestRun
        $options = New-TestOptions
    }
    It 'inherits criteria and case while resetting an original search deep link' {
        $run.PurviewUrl = 'https://purview.microsoft.com/ediscovery/case/original-search'
        $options.SenderAddress = 'unrelated@example.com'; $options.CaseName = 'Unrelated case'
        $clone = Get-MRCloneOption $run $options
        $clone.SenderAddress | Should -Be $run.SenderAddress
        $clone.Subject | Should -Be $run.Subject
        $clone.Mailboxes | Should -Be $run.Mailboxes
        $clone.CaseName | Should -Be $run.CaseName
        $clone.PurviewUrl | Should -Be 'https://purview.microsoft.com/ediscovery/'
        $clone.ReceivedThrough | Should -Be $run.ReceivedThrough
        $clone.ScopeSelection.Mailboxes | Should -Be @('All')
        $options.SenderAddress | Should -Be 'unrelated@example.com'
    }
    It 'keeps the original mailbox list and its group snapshot' {
        $run.Mailboxes = @('alice@contoso.com', 'bob@contoso.com')
        $run | Add-Member ScopeSelection ([pscustomobject]@{ Mode = 'Group'; ResolvedMailboxes = @('alice@contoso.com', 'bob@contoso.com'); Group = [pscustomobject]@{ Address = 'staff@contoso.com' } })
        $clone = Get-MRCloneOption $run $options
        $clone.ScopeSelection.Mailboxes | Should -Be @('alice@contoso.com', 'bob@contoso.com')
        $clone.ScopeSelection.Metadata.Group.Address | Should -Be 'staff@contoso.com'
    }
    It 'preserves explicit narrowing and clears an explicitly empty subject' {
        $options.ExplicitParameters = @('SenderAddress', 'Subject', 'ReceivedThrough', 'Mailboxes', 'Ticket', 'TicketUrl', 'CaseName', 'PurviewUrl')
        $options.SenderAddress = 'other@example.com'; $options.Subject = ''
        $options.ReceivedThrough = '2026-10-05'; $options.Mailboxes = @('pilot@contoso.com')
        $options.Ticket = 'INC-43'; $options.TicketUrl = ''; $options.CaseName = 'Other case'
        $options.PurviewUrl = 'https://purview.microsoft.com/ediscovery/?new'
        $clone = Get-MRCloneOption $run $options
        $clone.SenderAddress | Should -Be 'other@example.com'
        $clone.Subject | Should -Be ''
        $clone.ReceivedFrom | Should -Be '2026-10-05'
        $clone.ReceivedThrough | Should -Be '2026-10-05'
        $clone.Mailboxes | Should -Be @('pilot@contoso.com')
        $clone.ContainsKey('ScopeSelection') | Should -BeFalse
        $clone.Ticket | Should -Be 'INC-43'
        $clone.CaseName | Should -Be 'Other case'
        $clone.PurviewUrl | Should -Be $options.PurviewUrl
    }
    It 'switches between all dates and a bounded range without retaining conflicting dates' {
        $options.AllDates = $true; $options.ExplicitParameters = @('AllDates')
        $clone = Get-MRCloneOption $run $options
        $clone.AllDates | Should -BeTrue
        $clone.ReceivedFrom | Should -Be ''
        $clone.ReceivedThrough | Should -Be ''
        $run.AllDates = $true; $run.ReceivedFrom = ''; $run.ReceivedThrough = ''
        $options.AllDates = $false; $options.ExplicitParameters = @('ReceivedFrom', 'ReceivedThrough')
        $clone = Get-MRCloneOption $run $options
        $clone.AllDates | Should -BeFalse
        $clone.ReceivedFrom | Should -Be '2026-10-05'
        $clone.ReceivedThrough | Should -Be '2026-10-06'
    }
    It 'refuses to change tenants in a copy' {
        $options.ExplicitParameters = @('TenantId')
        $options.TenantId = '22222222-2222-2222-2222-222222222222'
        { Get-MRCloneOption $run $options } | Should -Throw '*original tenant*'
    }
    It 'opens an interactive copy at the review screen and keeps its case when still available' {
        $options.Interactive = $true
        $clone = Get-MRCloneOption $run $options
        $clone.WizardOnly | Should -Be @('Identity', 'SignIn', 'Case', 'Review')
        $clone.PreferredCase | Should -Be 'Incident case'
        $clone.AutoAcceptCase | Should -BeTrue
        $clone.CaseName | Should -Be ''
    }
}

Describe 'Non-secret AppData defaults' {
    BeforeEach {
        $run = New-TestRun
        $settingsPath = Join-Path $TestDrive "$([guid]::NewGuid())\settings.json"
    }
    It 'saves only the approved identity and portal defaults' {
        $run | Add-Member AccessToken 'must-not-be-saved'
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        $settings = Read-MRProfile $settingsPath
        @($settings.Keys | Sort-Object) | Should -Be @('CaseName', 'PurviewUrl', 'SchemaVersion', 'TenantId', 'UserPrincipalName')
        $settings.UserPrincipalName | Should -Be 'admin@contoso.com'
        $settings.TenantId | Should -Be $run.TenantId
        Get-Content -LiteralPath $settingsPath -Raw | Should -Not -Match 'must-not-be-saved|INC-42|phish@example.com'
    }
    It 'learns a helpdesk link pattern from a saved run and keeps it for later runs without a link' {
        $run.Ticket = '5678'; $run.TicketUrl = 'https://helpdesk.example.org:8443/desk/view?ticket=5678'
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        (Read-MRProfile $settingsPath).TicketUrlTemplate | Should -Be 'https://helpdesk.example.org:8443/desk/view?ticket={ticket}'
        $run.TicketUrl = ''
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        (Read-MRProfile $settingsPath).TicketUrlTemplate | Should -Be 'https://helpdesk.example.org:8443/desk/view?ticket={ticket}'
        Get-Content -LiteralPath $settingsPath -Raw | Should -Not -Match '5678'
    }
    It 'preserves the previous settings when atomically updating them' {
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        $run.CaseName = 'Incident review'
        Save-MRProfile $settingsPath $run other-admin@contoso.com -Confirm:$false
        (Read-MRProfile $settingsPath).CaseName | Should -Be 'Incident review'
        $backups = @(Get-ChildItem -LiteralPath (Split-Path $settingsPath) -Filter '*.bak')
        $backups.Count | Should -Be 1
        (Read-MRProfile $backups[0].FullName).UserPrincipalName | Should -Be 'admin@contoso.com'
        @(Get-ChildItem -LiteralPath (Split-Path $settingsPath) -Filter '*.tmp.json').Count | Should -Be 0
    }
    It 'does not rewrite unchanged defaults or create unnecessary backups' {
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        $first = [IO.File]::GetLastWriteTimeUtc($settingsPath)
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        [IO.File]::GetLastWriteTimeUtc($settingsPath) | Should -Be $first
        @(Get-ChildItem -LiteralPath (Split-Path $settingsPath) -Filter '*.bak').Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Split-Path $settingsPath) -Filter '*.tmp.json').Count | Should -Be 0
    }
    It 'preserves a malformed file and rejects unexpected fields' {
        $null = New-Item -ItemType Directory -Path (Split-Path $settingsPath)
        'malformed existing data' | Set-Content -LiteralPath $settingsPath
        { Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false } | Should -Throw
        Get-Content -LiteralPath $settingsPath -Raw | Should -Match '^malformed existing data'
        $other = Join-Path $TestDrive "$([guid]::NewGuid()).json"
        Write-MRJson $other @{ SchemaVersion = 1; AccessToken = 'unexpected' }
        { Read-MRProfile $other } | Should -Throw '*Unsupported settings*'
    }
    It 'does not create a settings folder during a preview' {
        Save-MRProfile $settingsPath $run admin@contoso.com -WhatIf
        Test-Path -LiteralPath (Split-Path $settingsPath) | Should -BeFalse
    }
    It 'rejects invalid new settings without replacing the previous file' {
        Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false
        $run.PurviewUrl = 'https://example.com/unrelated'
        { Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false } | Should -Throw '*Purview link*'
        $run.PurviewUrl = 'https://user:password@purview.microsoft.com/ediscovery/'
        { Save-MRProfile $settingsPath $run admin@contoso.com -Confirm:$false } | Should -Throw '*Purview link*'
        (Read-MRProfile $settingsPath).PurviewUrl | Should -Be 'https://purview.microsoft.com/ediscovery/'
    }
    It 'loads defaults when omitted and preserves explicit overrides' {
        $run.CaseName = 'Saved case'
        Save-MRProfile $settingsPath $run saved-admin@contoso.com -Confirm:$false
        $options = New-TestOptions
        $options.SettingsPath = $settingsPath; $options.NoSavedSettings = $false
        $options.ExplicitParameters = @('Subject')
        $options.TenantId = ''; $options.UserPrincipalName = ''
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.TenantId | Should -Be $run.TenantId
        $options.UserPrincipalName | Should -Be 'saved-admin@contoso.com'
        $options.CaseName | Should -Be 'Saved case'
        $options.ExplicitParameters = @('TenantId', 'UserPrincipalName', 'CaseName', 'PurviewUrl')
        $options.UserPrincipalName = 'explicit-admin@contoso.com'; $options.CaseName = 'Explicit case'
        $options.PurviewUrl = 'https://purview.microsoft.com/ediscovery/?explicit'
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.UserPrincipalName | Should -Be 'explicit-admin@contoso.com'
        $options.CaseName | Should -Be 'Explicit case'
        $options.PurviewUrl | Should -Be 'https://purview.microsoft.com/ediscovery/?explicit'
    }
    It 'does not use a different tenant profile or profiles when disabled' {
        $run.CaseName = 'Saved case'
        Save-MRProfile $settingsPath $run saved-admin@contoso.com -Confirm:$false
        $options = New-TestOptions
        $options.SettingsPath = $settingsPath; $options.NoSavedSettings = $false
        $options.ExplicitParameters = @('TenantId')
        $options.TenantId = '22222222-2222-2222-2222-222222222222'
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.UserPrincipalName | Should -Be 'admin@contoso.com'
        $options.CaseName | Should -Be 'Incident case'
        $options.TenantId = $run.TenantId; $options.NoSavedSettings = $true
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.UserPrincipalName | Should -Be 'admin@contoso.com'
        $options.CaseName | Should -Be 'Incident case'
    }
}

Describe 'Search ownership and provider limits' {
    BeforeEach { $run = New-TestRun; $search = New-TestSearch $run }
    It 'accepts a complete owned search with five matches across two locations' {
        { Test-MRSearch $search $run -ForRemoval } | Should -Not -Throw
    }
    It 'does not impose a 100-item tenant-wide limit' {
        $search.Items = 300
        $search.SuccessResults = (1..300 | ForEach-Object { "{Location: user$_@contoso.com, Item count: 1, Total size: 1}" }) -join ';'
        { Test-MRSearch $search $run -ForRemoval } | Should -Not -Throw
    }
    It 'blocks changed ownership, query, scope, exclusions, and non-mailbox locations' {
        $search.Description = 'Some other incident'; { Test-MRSearch $search $run } | Should -Throw
        $search = New-TestSearch $run; $search.ContentMatchQuery = 'kind:email'; { Test-MRSearch $search $run } | Should -Throw
        $search = New-TestSearch $run; $search.ExchangeLocation = @('alice@contoso.com'); { Test-MRSearch $search $run } | Should -Throw
        $search = New-TestSearch $run; $search.ExchangeLocationExclusion = @('alice@contoso.com'); { Test-MRSearch $search $run } | Should -Throw
        $search = New-TestSearch $run; $search.SharePointLocation = @('https://contoso.sharepoint.com'); { Test-MRSearch $search $run } | Should -Throw
    }
    It 'blocks failed, partial, empty, errored, oversized, and incomplete results' {
        $search.Status = 'PartiallySucceeded'; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
        $search = New-TestSearch $run; $search.Items = 0; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
        $search = New-TestSearch $run; $search.Errors = 'A mailbox could not be searched'; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
        $search = New-TestSearch $run; $search.NumBindings = 50001; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
        $search = New-TestSearch $run; $search.SuccessResults = ''; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
        $search = New-TestSearch $run; $search.SuccessResults = '{Location: alice@contoso.com, Item count: 2}'; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
        $search = New-TestSearch $run; $search.Items = 11; $search.SuccessResults = '{Location: alice@contoso.com, Item count: 11}'; { Test-MRSearch $search $run -ForRemoval } | Should -Throw
    }
    It 'compares distributions independently of provider row order' {
        $reordered = New-TestSearch $run
        $reordered.SuccessResults = '{Location: bob@contoso.com, Item count: 3}; {Location: alice@contoso.com, Item count: 2}'
        Get-MRResultKey $search | Should -BeExactly (Get-MRResultKey $reordered)
    }
}

Describe 'Action identity and asynchronous jobs' {
    It 'does not treat an unrelated action as this runs purge' {
        Mock Get-MRComplianceSearchAction { [pscustomobject]@{ Name = 'SomeoneElse_Purge'; Status = 'Completed' } }
        Get-MRAction MR-INC-42 | Should -BeNullOrEmpty
    }
    It 'does not suppress permission errors as a missing action' {
        Mock Get-MRComplianceSearchAction { throw 'Access denied' }
        { Get-MRAction MR-INC-42 } | Should -Throw '*Access denied*'
    }
    It 'waits past the old completed search before accepting a fresh job' {
        $script:poll = 0
        Mock Start-Sleep {}
        Mock Get-MRComplianceSearch {
            $script:poll++
            [pscustomobject]@{ Status = 'Completed'; JobRunId = $(if ($script:poll -eq 1) { 'old' } else { 'new' }); Errors = '' }
        }
        (Wait-MRJob -Kind Search -SearchName MR-INC-42 -PreviousJobRunId old -TimeoutSeconds 10 -PollSeconds 1).JobRunId | Should -Be 'new'
        Should -Invoke Get-MRComplianceSearch -Times 2 -Exactly
    }
    It 'fails on a partial action rather than calling it complete' {
        Mock Get-MRAction { [pscustomobject]@{ Status = 'PartiallySucceeded'; Errors = 'some failed' } }
        { Wait-MRJob -Kind Purge -SearchName MR-INC-42 -TimeoutSeconds 10 -PollSeconds 1 } | Should -Throw '*PartiallySucceeded*'
    }
    It 'has a bounded timeout' {
        { Wait-MRJob -Kind Search -SearchName MR-INC-42 -TimeoutSeconds 0 -PollSeconds 1 } | Should -Throw '*did not complete*'
    }
}

Describe 'Purview sign-in checks and reuse' {
    BeforeEach {
        $script:purview = $null
        $admin = [pscustomobject]@{ State = 'Connected'; IsEopSession = $true; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com' }
        Mock Get-Module { [pscustomobject]@{ Version = [version]'3.10.1' } }
        Mock Import-Module {}
        Mock Disconnect-ExchangeOnline { $script:purview = $null }
        Mock Connect-IPPSSession { $script:purview = $admin }
        Mock Get-ConnectionInformation { if ($ModulePrefix -eq 'MR' -and $script:purview) { $script:purview } }
    }
    It 'requests the current search-only session with a dedicated command prefix' {
        (Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111).UserPrincipalName | Should -Be 'admin@contoso.com'
        Should -Invoke Connect-IPPSSession -Times 1 -Exactly -ParameterFilter { $EnableSearchOnlySession -and $Prefix -eq 'MR' }
        Should -Invoke Import-Module -Times 1 -ParameterFilter { $RequiredVersion -eq '3.10.1' -and $Global }
    }
    It 'reuses a matching connection instead of signing in again' {
        $null = Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111
        $null = Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111
        Should -Invoke Connect-IPPSSession -Times 1 -Exactly
        Should -Invoke Disconnect-ExchangeOnline -Times 0
    }
    It 'signs out an earlier connection for a different account before signing in' {
        $script:purview = [pscustomobject]@{ State = 'Connected'; IsEopSession = $true; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'other@contoso.com' }
        $null = Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MR' }
        Should -Invoke Connect-IPPSSession -Times 1 -Exactly
    }
    It 'rejects a different tenant and closes only the tool connection' {
        { Connect-MRPurview admin@contoso.com 22222222-2222-2222-2222-222222222222 } | Should -Throw '*tenant or administrator differs*'
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -ParameterFilter { $ModulePrefix -eq 'MR' }
    }
    It 'rejects an older already-loaded module before sign-in' {
        Mock Get-Module { [pscustomobject]@{ Version = [version]'3.2.0' } }
        { Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111 } | Should -Throw '*older*'
        Should -Invoke Connect-IPPSSession -Times 0
    }
    It 'rejects a non-Purview session and a different signed-in administrator' {
        Mock Connect-IPPSSession { $script:purview = [pscustomobject]@{ State = 'Connected'; IsEopSession = $false; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com' } }
        { Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111 } | Should -Throw '*one connected Purview session*'
        Mock Connect-IPPSSession { $script:purview = [pscustomobject]@{ State = 'Connected'; IsEopSession = $true; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'someoneelse@contoso.com' } }
        { Connect-MRPurview admin@contoso.com 11111111-1111-1111-1111-111111111111 } | Should -Throw '*tenant or administrator differs*'
    }
}

Describe 'Search and removal with Microsoft 365 mocked' {
    BeforeEach {
        $run = New-TestRun
        $baseline = New-TestSearch $run
        $fresh = New-TestSearch $run
        $fresh.JobRunId = 'fresh-job'
        $directory = Join-Path $TestDrive $run.SearchName
        $null = New-Item -ItemType Directory -Path $directory
        Write-MRJson (Join-Path $directory 'run.json') $run
        Write-MRJson (Join-Path $directory 'search.json') $baseline
        Write-MREvent $directory 'SearchCompleted' @{ Items = 5 }
        $report = Join-Path $TestDrive "$($run.SearchName)-report.csv"
        'Sender,Subject', 'phish@example.com,Cell phone' | Set-Content -LiteralPath $report
        $options = New-TestOptions
        $options.Mode = 'Remove'; $options.RunPath = $directory; $options.ReportPath = $report
        $script:trace = New-TestTraceResult $run -Status Unavailable
        Mock Connect-MRPurview { [pscustomobject]@{ UserPrincipalName = 'admin@contoso.com'; TenantID = '11111111-1111-1111-1111-111111111111' } }
        Mock Connect-MRExchange { throw 'Unexpected Exchange sign-in' }
        Mock Get-MRTraceResult { $script:trace }
        Mock Get-MRComplianceSearch { $fresh }
        Mock Start-MRComplianceSearch {}
        Mock Get-MRAction { $null }
        Mock Wait-MRJob {
            if ($Kind -eq 'Search') { $fresh }
            else { [pscustomobject]@{ Name = "$($run.SearchName)_Purge"; Status = 'Completed'; Results = 'Item count: 5'; Errors = '' } }
        }
        Mock New-MRComplianceSearchAction { [pscustomobject]@{ Name = "$($run.SearchName)_Purge"; Status = 'Starting' } }
        Mock New-MRComplianceSearch {}
        Mock Resolve-MRMailboxScope { [pscustomobject]@{ Mailboxes = @(Get-MRScope $Options.Mailboxes); Metadata = $null } }
        Mock Show-MRQuickAction {}
        Set-TestAnswer @('REMOVE INC-42 5 HardDelete')
    }
    It 'submits exactly one purge after review and keeps the search and report' {
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly -ParameterFilter { $Purge -and $PurgeType -eq 'HardDelete' }
        $events = @(Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ConvertFrom-Json)
        $events.Event | Should -Contain 'PurgeCompleted'
        ($events | Where-Object Event -EQ 'ReviewCompleted').Details.Report.SHA256 | Should -Not -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $directory -Filter 'reviewed-report-*.csv').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $directory -Filter 'ticket-summary-*.txt').Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $directory 'search.json') | Should -BeTrue
    }
    It 'asks again after a mistyped confirmation and accepts any capitals' {
        Set-TestAnswer @('REMOVE INC-42 4 HardDelete', '', 'remove inc-42 5 harddelete')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly
    }
    It 'cancels without deleting at :cancel and records the cancellation' {
        Set-TestAnswer @(':cancel')
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*Canceled*'
        Should -Invoke New-MRComplianceSearchAction -Times 0
        (Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ConvertFrom-Json).Event | Should -Contain 'Canceled'
    }
    It 'deletes after the message trace review without a portal report' {
        $script:trace = New-TestMatchingTrace $run
        $options.ReportPath = ''; $options.MenuAction = $true
        Set-TestAnswer @('', '', 'REMOVE INC-42 5 HardDelete')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly -ParameterFilter { $PurgeType -eq 'HardDelete' }
        $review = Get-MRSavedTraceReview $directory
        $review.Messages | Should -Be 5; $review.MailboxesDifferent | Should -Be 0
        $evidence = (@(Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ConvertFrom-Json) | Where-Object Event -EQ 'ReviewCompleted').Details
        $evidence.MessageTrace.MessagesSha256 | Should -Be $review.MessagesSha256
        $evidence.Report | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $directory -Filter 'reviewed-report-*.csv').Count | Should -Be 0
    }
    It 'uses a saved message trace review instead of tracing again' {
        $null = Save-MRTraceReview -Directory $directory -Run $run -Search $baseline -TraceResult (New-TestMatchingTrace $run)
        $options.ReportPath = ''
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke Get-MRTraceResult -Times 0
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly
    }
    It 'requires a portal report when message trace cannot cover the dates' {
        $options.ReportPath = ''
        Set-TestAnswer @($report, 'REMOVE INC-42 5 HardDelete')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        @(Get-ChildItem -LiteralPath $directory -Filter 'reviewed-report-*.csv').Count | Should -Be 1
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly
    }
    It 'requires a portal report when message trace does not show every message the search found' {
        $script:trace = New-TestTraceResult $run @(New-TestTraceMessage alice@contoso.com; New-TestTraceMessage alice@contoso.com)
        $options.ReportPath = ''
        Set-TestAnswer @($report, 'REMOVE INC-42 5 HardDelete')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        @(Get-ChildItem -LiteralPath $directory -Filter 'reviewed-report-*.csv').Count | Should -Be 1
        (Get-MRSavedTraceReview $directory).UnshownItems | Should -Be 3
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly
    }
    It 'explains that a search has not finished instead of failing on a missing file' {
        Remove-Item -LiteralPath (Join-Path $directory 'search.json')
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*has not finished*'
        Should -Invoke Start-MRComplianceSearch -Times 0
    }
    It 'goes back from the confirmation to the deletion type' {
        $script:trace = New-TestMatchingTrace $run
        $options.ReportPath = ''; $options.MenuAction = $true
        Set-TestAnswer @('', '2', 'b', '1', 'REMOVE INC-42 5 HardDelete')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly -ParameterFilter { $PurgeType -eq 'HardDelete' }
    }
    It 'offers recoverable deletion by its number' {
        $script:trace = New-TestMatchingTrace $run
        $options.ReportPath = ''; $options.MenuAction = $true
        Set-TestAnswer @('', '2', 'REMOVE INC-42 5 SoftDelete')
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly -ParameterFilter { $PurgeType -eq 'SoftDelete' }
    }
    It 'blocks a changed distribution even when the total stays the same' {
        $fresh.SuccessResults = '{Location: alice@contoso.com, Item count: 1}; {Location: bob@contoso.com, Item count: 4}'
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*different messages*'
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'blocks a job that changes while the administrator reviews' {
        $script:reads = 0
        Mock Get-MRComplianceSearch {
            $script:reads++
            if ($script:reads -gt 1) { $fresh.JobRunId = 'unexpected-job' }
            $fresh
        }
        # Use a separate object so changing the current job cannot change the reviewed snapshot.
        Mock Wait-MRJob { New-TestSearch $run | ForEach-Object { $_.JobRunId = 'fresh-job'; $_ } }
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*changed during review*'
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'does not repeat a purge after a lost or failed submission response' {
        Mock New-MRComplianceSearchAction { throw 'Connection lost after submission' }
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*Connection lost*'
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*already submitted*'
        Should -Invoke New-MRComplianceSearchAction -Times 1 -Exactly
        Should -Invoke Start-MRComplianceSearch -Times 1 -Exactly
    }
    It 'blocks an existing action before starting another job' {
        Mock Get-MRAction { [pscustomobject]@{ Name = "$($run.SearchName)_Purge"; Status = 'Failed' } }
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*already submitted*'
        Should -Invoke New-MRComplianceSearchAction -Times 0
        Should -Invoke Start-MRComplianceSearch -Times 0
    }
    It 'does not connect or write anything in Remove WhatIf' {
        $before = @(Get-ChildItem -LiteralPath $directory).Count
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke New-MRComplianceSearchAction -Times 0
        @(Get-ChildItem -LiteralPath $directory).Count | Should -Be $before
    }
    It 'does not connect or create a search in Search WhatIf' {
        $options.Mode = 'Search'
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke New-MRComplianceSearch -Times 0
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
    }
    It 'does not connect or save evidence in Status WhatIf' {
        $options.Mode = 'Status'
        $before = @(Get-ChildItem -LiteralPath $directory).Count
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke Get-MRComplianceSearch -Times 0
        @(Get-ChildItem -LiteralPath $directory).Count | Should -Be $before
    }
    It 'uses the remembered administrator only for a saved run in that tenant' {
        $options.Mode = 'Status'
        $options.SettingsPath = Join-Path $TestDrive 'status-defaults.json'; $options.NoSavedSettings = $false
        $options.ExplicitParameters = @('Mode', 'RunPath')
        $options.UserPrincipalName = ''
        Save-MRProfile $options.SettingsPath $run saved-admin@contoso.com -Confirm:$false
        Mock Read-Host { throw 'An unnecessary identity prompt occurred' }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke Connect-MRPurview -Times 1 -Exactly -ParameterFilter { $UserPrincipalName -eq 'saved-admin@contoso.com' -and $TenantId -eq $run.TenantId }
        $tenantDefaults = New-TestRun
        $tenantDefaults.TenantId = '22222222-2222-2222-2222-222222222222'
        Save-MRProfile $options.SettingsPath $tenantDefaults different-tenant-admin@contoso.com -Confirm:$false
        $options.UserPrincipalName = ''
        Mock Read-Host { 'run-tenant-admin@contoso.com' }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke Read-Host -Times 1 -Exactly
        $options.UserPrincipalName | Should -Be 'run-tenant-admin@contoso.com'
    }
    It 'runs a guided search from the menu with saved tenant and admin, without asking for them' {
        $options.Mode = 'Menu'
        $options.SettingsPath = Join-Path $TestDrive 'menu-defaults.json'; $options.NoSavedSettings = $false
        $options.ExplicitParameters = @(); $options.TenantId = ''; $options.UserPrincipalName = ''; $options.CaseName = ''
        Save-MRProfile $options.SettingsPath $run saved-admin@contoso.com -Confirm:$false
        $script:messages = [collections.generic.List[string]]::new()
        Mock Write-Host { $script:messages.Add([string]$Object) }
        Mock Get-MRSignedInAccount { @() }
        Set-TestAnswer @('1', 'INC-7', '', 'phish@example.com', '', '2026-10-05', '2026-10-06', '', '', 'Q')
        Invoke-MRWorkflow -Options $options -WhatIf
        ($script:messages -join "`n") | Should -Match "Tenant: $($run.TenantId)"
        ($script:messages -join "`n") | Should -Match 'Case: Incident case \(confirmed after signing in\)'
        $script:testPrompts | Should -Not -Contain 'Tenant ID'
        $script:testAnswers.Count | Should -Be 0
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'creates and saves a new search with its message trace review, without submitting removal' {
        $options.Mode = 'Search'; $options.ReportPath = ''
        $options.SettingsPath = Join-Path $TestDrive 'defaults\settings.json'; $options.NoSavedSettings = $false
        $options.TicketUrl = 'https://desk.example.com/view?id=INC-42'
        $script:trace = New-TestMatchingTrace $run
        Mock New-MRComplianceSearch {
            $script:createdSearch = New-TestSearch $run
            $script:createdSearch.Name = $Name
            $script:createdSearch.Description = $Description
            $script:createdSearch.ContentMatchQuery = $ContentMatchQuery
            $script:createdSearch.ExchangeLocation = $ExchangeLocation
        }
        Mock Wait-MRJob { $script:createdSearch }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Should -Invoke New-MRComplianceSearch -Times 1 -Exactly -ParameterFilter {
            $Case -eq 'Incident case' -and $ExchangeLocation -contains 'All'
        }
        Should -Invoke Start-MRComplianceSearch -Times 1 -Exactly
        Should -Invoke New-MRComplianceSearchAction -Times 0
        $savedDirectory = Join-Path $options.DataDirectory $script:createdSearch.Name
        (Read-MRRun $savedDirectory).Ticket | Should -Be 'INC-42'
        Test-Path -LiteralPath (Join-Path $savedDirectory 'search.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $savedDirectory 'location-counts.csv') | Should -BeTrue
        (Get-MRSavedTraceReview $savedDirectory).Messages | Should -Be 5
        Get-Content -LiteralPath @(Get-ChildItem $savedDirectory -Filter 'ticket-summary-*.txt')[0].FullName -Raw | Should -Match 'Message trace'
        $settings = Read-MRProfile $options.SettingsPath
        $settings.TenantId | Should -Be $options.TenantId
        $settings.UserPrincipalName | Should -Be 'admin@contoso.com'
        $settings.TicketUrlTemplate | Should -Be 'https://desk.example.com/view?id={ticket}'
    }
    It 'still creates the search when message trace is unavailable, and records why' {
        $options.Mode = 'Search'; $options.ReportPath = ''
        Mock New-MRComplianceSearch { $script:createdSearch = New-TestSearch $run; $script:createdSearch.Name = $Name; $script:createdSearch.Description = $Description; $script:createdSearch.ContentMatchQuery = $ContentMatchQuery }
        Mock Wait-MRJob { $script:createdSearch }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $savedDirectory = Join-Path $options.DataDirectory $script:createdSearch.Name
        (Get-Content -LiteralPath (Join-Path $savedDirectory 'events.jsonl') | ConvertFrom-Json).Event | Should -Contain 'TraceUnavailable'
    }
    It 'refuses the built-in Content Search case and a missing case name' {
        $options.Mode = 'Search'; $options.CaseName = 'Content Search'
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*Content Search*'
        $options.CaseName = ''
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*-CaseName*'
        Should -Invoke New-MRComplianceSearch -Times 0
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'creates a changed copy with fresh evidence and leaves the original untouched' {
        Copy-Item -LiteralPath $report -Destination (Join-Path $directory 'reviewed-report-parent.csv')
        Write-MREvent $directory 'PurgeSubmissionAttempt' @{ Type = 'HardDelete' }
        $originalHashes = @(Get-ChildItem -LiteralPath $directory -File | Get-FileHash | Select-Object Path,Hash | ConvertTo-Json -Compress)
        $options.Mode = 'Clone'; $options.ExplicitParameters = @('Mode', 'RunPath', 'Subject', 'Mailboxes')
        $options.Subject = 'Narrower phrase'; $options.Mailboxes = @('pilot@contoso.com')
        Mock New-MRComplianceSearch {
            $script:createdSearch = New-TestSearch $run
            $script:createdSearch.Name = $Name; $script:createdSearch.Description = $Description
            $script:createdSearch.ContentMatchQuery = $ContentMatchQuery; $script:createdSearch.ExchangeLocation = $ExchangeLocation
            $script:createdSearch.Items = 1; $script:createdSearch.NumBindings = 1
            $script:createdSearch.SuccessResults = '{Location: pilot@contoso.com, Item count: 1}'
        }
        Mock Wait-MRJob { $script:createdSearch }
        Invoke-MRWorkflow -Options $options -Confirm:$false
        $newDirectory = Join-Path $options.DataDirectory $script:createdSearch.Name
        $newRun = Read-MRRun $newDirectory
        $newRun.SearchName | Should -Not -Be $run.SearchName
        $newRun.RunId | Should -Not -Be $run.RunId
        $newRun.TenantId | Should -Be $run.TenantId
        $newRun.Subject | Should -Be 'Narrower phrase'
        $newRun.Mailboxes | Should -Be @('pilot@contoso.com')
        $newRun.CaseName | Should -Be 'Incident case'
        $newRun.ClonedFrom.SearchName | Should -Be $run.SearchName
        $newRun.ClonedFrom.RunPath | Should -Be $directory
        $newRun.ClonedFrom.Query | Should -Be $run.Query
        Should -Invoke New-MRComplianceSearch -Times 1 -Exactly
        Should -Invoke New-MRComplianceSearchAction -Times 0
        @(Get-ChildItem -LiteralPath $newDirectory -Filter 'reviewed-report-*.csv').Count | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $newDirectory 'events.jsonl') | ConvertFrom-Json).Event | Should -Not -Contain 'PurgeSubmissionAttempt'
        @(Get-ChildItem -LiteralPath $directory -File | Get-FileHash | Select-Object Path,Hash | ConvertTo-Json -Compress) | Should -Be $originalHashes
    }
    It 'asks for -CaseName before signing in when copying a run made in the built-in Content Search case' {
        $legacy = New-TestRun; $legacy.CaseName = 'Content Search'
        $legacyPath = Save-TestRun $legacy (Join-Path $TestDrive 'legacy')
        $options.Mode = 'Clone'; $options.RunPath = $legacyPath; $options.ExplicitParameters = @('Mode', 'RunPath')
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*-CaseName*'
        Should -Invoke Connect-MRPurview -Times 0; Should -Invoke Resolve-MRMailboxScope -Times 0
    }
    It 'previews a copy without connecting or altering the source or creating a run' {
        $options.Mode = 'Clone'; $options.ExplicitParameters = @('Mode', 'RunPath', 'Subject')
        $options.Subject = 'New phrase'
        $before = @(Get-ChildItem -LiteralPath $directory).Count
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke New-MRComplianceSearch -Times 0
        @(Get-ChildItem -LiteralPath $directory).Count | Should -Be $before
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
    }
    It 'rejects changed source metadata before creating a copy' {
        $run.Query = 'kind:email'
        $changedDirectory = Join-Path $TestDrive 'invalid-clone-source'
        $null = New-Item -ItemType Directory -Path $changedDirectory
        Write-MRJson (Join-Path $changedDirectory 'run.json') $run
        $options.Mode = 'Clone'; $options.RunPath = $changedDirectory
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*saved query differs*'
        Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'rejects an unsafe changed copy filter before connecting' {
        $options.Mode = 'Clone'; $options.ExplicitParameters = @('Mode', 'RunPath', 'Subject')
        $options.Subject = '*'
        { Invoke-MRWorkflow -Options $options -Confirm:$false } | Should -Throw '*Subject cannot*'
        Should -Invoke Connect-MRPurview -Times 0
        Should -Invoke New-MRComplianceSearch -Times 0
    }
    It 'rejects a changed saved query' {
        $run.Query = 'kind:email'
        $other = Join-Path $TestDrive 'changed'
        $null = New-Item -ItemType Directory -Path $other
        Write-MRJson (Join-Path $other 'run.json') $run
        { Read-MRRun $other } | Should -Throw '*saved query differs*'
    }
    It 'does not overwrite an existing evidence file' {
        { Write-MRJson (Join-Path $directory 'run.json') @{ Changed = $true } } | Should -Throw
        (Read-MRRun $directory).Ticket | Should -Be 'INC-42'
    }
}
