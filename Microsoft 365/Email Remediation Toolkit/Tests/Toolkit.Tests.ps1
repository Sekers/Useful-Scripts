# Offline fixtures. Every directory, sign-in, search, purge, browser and clipboard call is mocked.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-MailRemediation.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:directoryDataImplementation = (Get-Command Get-MRDirectoryData).ScriptBlock
}

Describe 'Complete immutable JSON evidence' {
    BeforeEach { Set-StrictMode -Version Latest }
    It 'stores recursive CultureInfo as a name while preserving search counts and verification fields' {
        $run = New-TestRun; $path = Save-TestRun $run (Join-Path $TestDrive 'language')
        $search = New-TestSearch $run
        $search | Add-Member Language ([globalization.CultureInfo]::InvariantCulture)
        $search | Add-Member ProviderDiagnostic 'Retain provider details'
        & { $WarningPreference = 'Stop'; Save-MRSearchBaseline $path $run $search }
        $saved = Get-Content -LiteralPath (Join-Path $path 'search.json') -Raw | ConvertFrom-Json
        $saved.Language | Should -BeExactly ''
        $saved.ProviderDiagnostic | Should -Be 'Retain provider details'
        $saved.SuccessResults | Should -BeExactly $search.SuccessResults
        Get-MRResultKey $saved | Should -BeExactly (Get-MRResultKey $search)
        { Test-MRSearch $saved $run -ForRemoval } | Should -Not -Throw
    }
    It 'normalizes deserialized language metadata for search and action snapshots' {
        $path = Join-Path $TestDrive 'service-snapshots'; New-Item -ItemType Directory $path | Out-Null
        $value = [pscustomobject]@{ Status = 'Completed'; Results = 'provider results'; Language = [pscustomobject]@{ Name = 'en-US'; Parent = [globalization.CultureInfo]::InvariantCulture } }
        & { $WarningPreference = 'Stop'; Save-MRSnapshot $path 'purge-result' $value }
        $saved = Get-Content -LiteralPath @(Get-ChildItem $path -Filter '*.json')[0].FullName -Raw | ConvertFrom-Json
        $saved.Language | Should -Be 'en-US'; $saved.Results | Should -Be 'provider results'
        $value.Language.Parent | Should -BeOfType ([globalization.CultureInfo])
    }
    It 'rejects unexpected JSON depth without publishing an empty or truncated record' {
        $path = Join-Path $TestDrive 'deep.json'; $value = @{ Leaf = 'preserve this' }
        foreach ($level in 1..20) { $value = @{ Nested = $value } }
        { Write-MRJson $path $value } | Should -Throw '*depth*'
        Test-Path -LiteralPath $path | Should -BeFalse
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
    It 'does not replace earlier evidence and cleans up its unpublished temporary file' {
        $path = Join-Path $TestDrive 'immutable.json'; Write-MRJson $path @{ Count = 83 }
        $hash = (Get-FileHash -LiteralPath $path).Hash
        { Write-MRJson $path @{ Count = 0 } } | Should -Throw
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $hash
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
    It 'does not replace an existing CSV and writes headings for an empty list' {
        $path = Join-Path $TestDrive 'list.csv'
        Write-MRCsv $path @() @('Mailbox', 'Result')
        (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be '"Mailbox","Result"'
        { Write-MRCsv $path @([pscustomobject]@{ Mailbox = 'a'; Result = 'b' }) @('Mailbox', 'Result') } | Should -Throw
        @(Get-ChildItem $TestDrive -Filter '*.tmp').Count | Should -Be 0
    }
    It 'rejects truncated event details without appending misleading evidence' {
        Write-MREvent $TestDrive 'SearchCreated' @{}
        $path = Join-Path $TestDrive 'events.jsonl'; $original = Get-Content -LiteralPath $path -Raw
        $details = @{ Leaf = 'preserve this' }; foreach ($level in 1..15) { $details = @{ Nested = $details } }
        { Write-MREvent $TestDrive 'PurgeSubmissionAttempt' $details } | Should -Throw '*depth*'
        Get-Content -LiteralPath $path -Raw | Should -BeExactly $original
    }
}

Describe 'Message colors' {
    BeforeEach { Mock Write-Host {} }
    It 'gives each kind of message its one color: <Kind> is <Color>' -ForEach @(
        @{ Kind = 'Heading'; Color = 'Cyan' }, @{ Kind = 'Hint'; Color = 'DarkGray' }, @{ Kind = 'Notice'; Color = 'Yellow' }
        @{ Kind = 'Retry'; Color = 'Yellow' }, @{ Kind = 'Success'; Color = 'Green' }, @{ Kind = 'Failure'; Color = 'Red' }, @{ Kind = 'Danger'; Color = 'Red' }
    ) {
        Write-MRText $Kind 'text'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $ForegroundColor -eq $Color }
    }
    It 'starts a heading on a new line' {
        Write-MRText Heading 'Title'
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -eq "`nTitle" }
    }
    It 'asks again after a typo without a WARNING label' {
        Mock Write-Warning {}
        Set-TestAnswer @('not an address', 'phish@example.com')
        Read-MRValidated 'Sender' '' { param($value) Get-MREmail $value } | Should -Be 'phish@example.com'
        Should -Invoke Write-Warning -Times 0
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $ForegroundColor -eq 'Yellow' -and $Object -like 'Enter one email address*' }
    }
    It 'shows a failed action in red' {
        $options = New-TestOptions; $options.Mode = 'Menu'
        Mock Get-MRSignedInAccount { @() }
        Mock Invoke-MRWorkflow { throw 'Search failed' }
        Set-TestAnswer @('1', 'Q')
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $ForegroundColor -eq 'Red' -and $Object -like 'Search failed*' }
    }
}

Describe 'Answers, going back, and typed confirmations' {
    BeforeEach { Set-StrictMode -Version Latest }
    It 'goes back one step on B in any capitals and leaves for the menu on :cancel' {
        Set-TestAnswer @('invalid', 'b')
        $failure = $null
        try { Read-MRValidated 'Email' '' { param($value) Get-MREmail $value } } catch { $failure = $_ }
        Test-MRBackSignal $failure | Should -BeTrue
        Set-TestAnswer @(':CANCEL')
        $failure = $null
        try { Read-MRValidated 'Email' '' { param($value) Get-MREmail $value } } catch { $failure = $_ }
        $failure.Exception | Should -BeOfType ([OperationCanceledException])
        Test-MRBackSignal $failure | Should -BeFalse
    }
    It 'accepts a typed confirmation in any capitals and asks again after a mismatch or Enter' {
        Set-TestAnswer @('use 2', '', 'remove  inc-42 5 harddelete')
        Read-MRConfirmation 'REMOVE INC-42 5 HardDelete' 'Type it'
        $script:testAnswers.Count | Should -Be 0
    }
    It 'shows help for ? and asks the same question again' {
        Mock Write-MRPromptHelp {}
        Set-TestAnswer @('?', 'PHISH@example.com')
        Read-MRValidated 'Sender' '' { param($value) Get-MREmail $value } -HelpTopic Sender | Should -Be 'phish@example.com'
        Should -Invoke Write-MRPromptHelp -Times 1 -Exactly -ParameterFilter { $Topic -eq 'Sender' }
    }
    It 'keeps the value in brackets when Enter is pressed' {
        Set-TestAnswer @('')
        Read-MRValidated 'Ticket' 'INC-9' { param($value) $value } | Should -Be 'INC-9'
    }
    It 'goes back to the previous question inside a group and leaves the group from its first question' {
        $state = @{ First = ''; Second = '' }
        Set-TestAnswer @('one', 'b', 'uno', 'two')
        Invoke-MRPromptSequence @(
            { $state.First = Read-MRValidated 'First' $state.First { param($value) $value } }
            { $state.Second = Read-MRValidated 'Second' '' { param($value) $value } }
        )
        $state.First | Should -Be 'uno'; $state.Second | Should -Be 'two'
        Set-TestAnswer @('b')
        $failure = $null
        try { Invoke-MRPromptSequence @({ $state.First = Read-MRValidated 'First' '' { param($value) $value } }) } catch { $failure = $_ }
        Test-MRBackSignal $failure | Should -BeTrue
    }
}

Describe 'Guided search questions' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $state = New-TestOptions
        $state.Interactive = $true; $state.Offline = $true; $state.CaseLocked = $true
        $state.Ticket = ''; $state.SenderAddress = ''; $state.Subject = ''; $state.ReceivedFrom = ''; $state.ReceivedThrough = ''
    }
    It 'asks one question at a time and creates nothing until the review is accepted' {
        Set-TestAnswer @('INC-1', '', 'phish@example.com', '', '2026-10-01', '2026-10-02', '', '')
        Read-MRSearchPlan $state
        $state.Ticket | Should -Be 'INC-1'; $state.SenderAddress | Should -Be 'phish@example.com'
        $state.ReceivedFrom | Should -Be '2026-10-01'; $state.ReceivedThrough | Should -Be '2026-10-02'
        $state.ScopeSelection.Mailboxes | Should -Be @('All')
        $script:testPrompts[-1] | Should -BeLike 'Press Enter to create the search*'
    }
    It 'goes back one step and shows the earlier answer as the default' {
        Set-TestAnswer @('INC-1', '', 'phish@example.com', 'Cell', 'b', '', '2026-10-01', '2026-10-02', '', '')
        Read-MRSearchPlan $state
        $state.Subject | Should -Be 'Cell'
        $script:testPrompts | Should -Contain 'Subject words [Cell]'
    }
    It 'changes one item from the review screen and returns to the review' {
        Set-TestAnswer @('INC-1', '', 'phish@example.com', '', '2026-10-01', '2026-10-02', '', '4', 'other@example.com', '')
        Read-MRSearchPlan $state
        $state.SenderAddress | Should -Be 'other@example.com'
        @($script:testPrompts | Where-Object { $_ -like 'Press Enter to create the search*' }).Count | Should -Be 2
    }
    It 'returns from a review edit to the review when B is pressed' {
        Set-TestAnswer @('INC-1', '', 'phish@example.com', '', '2026-10-01', '2026-10-02', '', '4', 'b', '')
        Read-MRSearchPlan $state
        $state.SenderAddress | Should -Be 'phish@example.com'
    }
    It 'leaves the questions when B is pressed at the first one' {
        Set-TestAnswer @('B')
        $failure = $null
        try { Read-MRSearchPlan $state } catch { $failure = $_ }
        Test-MRBackSignal $failure | Should -BeTrue
    }
    It 'suggests the ticket number from the case name' {
        $state.CaseName = 'Ticket #5678'
        Set-TestAnswer @('', '', 'phish@example.com', '', 'ALL', '', '')
        Read-MRSearchPlan $state
        $state.Ticket | Should -Be '5678'
        $state.AllDates | Should -BeTrue
    }
    It 'builds the ticket link from a saved pattern and updates it when the ticket changes' {
        $state.TicketUrlTemplate = 'https://helpdesk.example.com/view?ticket={ticket}'
        Set-TestAnswer @('A-1', '', 'phish@example.com', '', 'ALL', '', '2', 'A-2', '')
        Read-MRSearchPlan $state
        $state.TicketUrl | Should -Be 'https://helpdesk.example.com/view?ticket=A-2'
    }
    It 'keeps a typed ticket link when the ticket changes' {
        $state.TicketUrlTemplate = 'https://helpdesk.example.com/view?ticket={ticket}'
        Set-TestAnswer @('A-1', 'https://other.example.com/case/77', 'phish@example.com', '', 'ALL', '', '2', 'A-2', '')
        Read-MRSearchPlan $state
        $state.TicketUrl | Should -Be 'https://other.example.com/case/77'
    }
    It 'does not mistake a date in the case name for the ticket number' {
        $state.CaseName = 'Phishing 2026-10-05'
        Get-MRSuggestedTicket $state | Should -Be ''
        $state.CaseName = 'INC-1234 Phishing 2026-10-05'
        Get-MRSuggestedTicket $state | Should -Be 'INC-1234'
    }
    It 'accepts the sender as Outlook shows it, with the display name' {
        Set-TestAnswer @('INC-1', '', 'John Reyes <John.Reyes@Example.com>', '', 'ALL', '', '')
        Read-MRSearchPlan $state
        $state.SenderAddress | Should -Be 'john.reyes@example.com'
    }
    It 'offers only all mailboxes when Exchange Online did not sign in' {
        $state.Offline = $false
        Mock Connect-MRSearchSession { $State.ExchangeAvailable = $false }
        Mock Resolve-MRMailboxScope { throw 'Exchange is not available.' }
        Set-TestAnswer @('INC-1', '', 'phish@example.com', '', 'ALL', '4', '', '')
        Read-MRSearchPlan $state
        $state.ScopeSelection.Mailboxes | Should -Be @('All')
        Should -Invoke Resolve-MRMailboxScope -Times 0
    }
    It 'lets an invalid ticket link be corrected immediately' {
        Set-TestAnswer @('A-1', 'http://helpdesk.example.com/1', 'https://helpdesk.example.com/1', 'phish@example.com', '', 'ALL', '', '')
        Read-MRSearchPlan $state
        $state.TicketUrl | Should -Be 'https://helpdesk.example.com/1'
    }
}

Describe 'Ticket link patterns for any helpdesk' {
    It 'learns a pattern when the link contains the ticket number once: <Url>' -ForEach @(
        @{ Ticket = '5678'; Url = 'https://helpdesk.example.org:8443/desk/tickets/view?ticket=5678'; Expected = 'https://helpdesk.example.org:8443/desk/tickets/view?ticket={ticket}' }
        @{ Ticket = 'INC-1234'; Url = 'https://example.atlassian.net/browse/INC-1234'; Expected = 'https://example.atlassian.net/browse/{ticket}' }
    ) { Get-MRTicketUrlTemplate $Ticket $Url | Should -BeExactly $Expected }
    It 'learns nothing when the number is missing, repeated, or part of another value: <Url>' -ForEach @(
        @{ Ticket = '123'; Url = 'https://desk.example.com/record/9f1c2a7e' }
        @{ Ticket = '5'; Url = 'https://desk.example.com/5/5' }
        @{ Ticket = '123'; Url = 'https://desk.example.com/t/1234' }
    ) { Get-MRTicketUrlTemplate $Ticket $Url | Should -BeExactly '' }
    It 'rejects a pattern that is not https or does not mark the ticket once' {
        { Test-MRTicketUrlTemplate 'http://desk.example.com/{ticket}' } | Should -Throw '*https*'
        { Test-MRTicketUrlTemplate 'https://desk.example.com/ticket' } | Should -Throw '*{ticket}*'
    }
}

Describe 'Run picker regression and browsing' {
    It 'accepts a pasted path with no saved runs under StrictMode' {
        Set-TestAnswer @('C:\example\run')
        & { Set-StrictMode -Version Latest; Select-MRRun (Join-Path $TestDrive 'missing') } | Should -Be 'C:\example\run'
    }
    It 'selects the only saved run under StrictMode' {
        $path = Save-TestRun (New-TestRun) (Join-Path $TestDrive 'one')
        Set-TestAnswer @('1')
        & { Set-StrictMode -Version Latest; Select-MRRun (Split-Path $path) } | Should -Be $path
    }
    It 'orders by creation time rather than ticket and exposes older pages' {
        $root = Join-Path $TestDrive 'many'
        $oldest = ''
        foreach ($number in 1..15) {
            $path = Save-TestRun (New-TestRun "ZZZ-$number" ('2020-01-{0:D2}T00:00:00Z' -f $number)) $root
            if ($number -eq 1) { $oldest = $path }
        }
        $latest = Save-TestRun (New-TestRun AAA) $root
        Set-TestAnswer @('1'); Select-MRRun $root | Should -Be $latest
        Set-TestAnswer @('N', '1'); Select-MRRun $root | Should -Be $oldest
        Set-TestAnswer @('/ZZZ-1 ', '/', '/ZZZ-15', '1'); Select-MRRun $root | Should -BeLike '*MR-ZZZ-15-*'
    }
    It 'retries an invalid selection without losing the list' {
        $path = Save-TestRun (New-TestRun) (Join-Path $TestDrive 'retry')
        Set-TestAnswer @('999999999999999999999', '1')
        Select-MRRun (Split-Path $path) | Should -Be $path
    }
    It 'distinguishes an uncertain submission from a completed removal in saved history' {
        $run = New-TestRun; $root = Join-Path $TestDrive 'removal-history'; $path = Save-TestRun $run $root
        Write-MREvent $path 'PurgeSubmissionAttempt' @{}
        @(Get-MRRunIndex $root)[0].Label | Should -Match 'outcome unknown'
        Save-MRSnapshot $path 'purge-result' @{ Status = 'Completed' }
        @(Get-MRRunIndex $root)[0].Label | Should -Match 'deletion Completed'
    }
    It 'supports multiple directory selections across filters without duplicate addresses' {
        $directory = New-TestDirectory
        Set-TestAnswer @('1', '/bob', '1', '/', 'D')
        @(Select-MRList $directory.Mailboxes 'mailboxes' -Multiple).Key | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }
    It 'goes back from a list with B' {
        $directory = New-TestDirectory
        Set-TestAnswer @('b')
        $failure = $null
        try { Select-MRList $directory.Mailboxes 'mailboxes' } catch { $failure = $_ }
        Test-MRBackSignal $failure | Should -BeTrue
    }
    It 'offers all mailboxes and normalizes pasted comma-separated addresses' {
        Set-TestAnswer @('1'); (Read-MRMailboxChoice).MailboxMode | Should -Be 'All'
        Set-TestAnswer @('4', 'BOB@contoso.com, alice@contoso.com, bob@contoso.com')
        (Read-MRMailboxChoice).Mailboxes | Should -Be @('alice@contoso.com', 'bob@contoso.com')
    }
    It 'returns to the mailbox choices when B is pressed while typing addresses' {
        Set-TestAnswer @('4', 'b', '')
        (Read-MRMailboxChoice).MailboxMode | Should -Be 'All'
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

Describe 'Exchange Online connection reuse' {
    BeforeEach {
        $script:exchange = $null
        $script:MRTraceUnavailable = @{}
        Mock Import-MRExchangeModule {}
        Mock Connect-ExchangeOnline { $script:exchange = [pscustomobject]@{ State = 'Connected'; IsEopSession = $false; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'admin@contoso.com' } }
        Mock Disconnect-ExchangeOnline { $script:exchange = $null }
        Mock Get-ConnectionInformation { if ($ModulePrefix -eq 'MRD' -and $script:exchange) { $script:exchange } }
    }
    It 'imports the mailbox and message trace commands with its own prefix' {
        Connect-MRExchange admin@contoso.com 11111111-1111-1111-1111-111111111111 | Should -Not -BeNullOrEmpty
        Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $Prefix -eq 'MRD' -and 'Get-Mailbox' -in $CommandName -and 'Get-MessageTraceV2' -in $CommandName }
    }
    It 'reuses a matching connection without signing in again' {
        $null = Connect-MRExchange admin@contoso.com 11111111-1111-1111-1111-111111111111
        $null = Connect-MRExchange ADMIN@contoso.com 11111111-1111-1111-1111-111111111111
        Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly
        Should -Invoke Disconnect-ExchangeOnline -Times 0
    }
    It 'replaces a connection that belongs to a different account' {
        $script:exchange = [pscustomobject]@{ State = 'Connected'; IsEopSession = $false; TenantID = '11111111-1111-1111-1111-111111111111'; UserPrincipalName = 'other@contoso.com' }
        $null = Connect-MRExchange admin@contoso.com 11111111-1111-1111-1111-111111111111
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MRD' }
        Should -Invoke Connect-ExchangeOnline -Times 1 -Exactly
    }
    It 'rejects the wrong tenant and closes only its own connection' {
        { Connect-MRExchange admin@contoso.com 22222222-2222-2222-2222-222222222222 } | Should -Throw '*expected tenant*'
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MRD' }
    }
    It 'signs out of both connections on request' {
        Mock Get-Module { [pscustomobject]@{ Version = [version]'3.10.1' } } -ParameterFilter { $Name -eq 'ExchangeOnlineManagement' }
        Mock Get-ConnectionInformation { [pscustomobject]@{ State = 'Connected' } }
        Disconnect-MRSession
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MR' }
        Should -Invoke Disconnect-ExchangeOnline -Times 1 -Exactly -ParameterFilter { $ModulePrefix -eq 'MRD' }
    }
}

Describe 'Directory scope resolution and membership snapshot' {
    BeforeEach {
        $directory = New-TestDirectory; $options = New-TestOptions
        $script:MRDirectoryCache = $null
        Mock Connect-MRExchange { [pscustomobject]@{ TenantID = $options.TenantId } }
        Mock Disconnect-ExchangeOnline {}
        Mock Get-MRDirectoryData { $directory }
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
    It 'expands nested groups, handles cycles and aliases, records excluded contacts, and accepts the list with Enter' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'staff@contoso.com'
        Set-TestAnswer @('')
        $resolved = Resolve-MRMailboxScope $options
        $resolved.Mailboxes | Should -Be @('alice@contoso.com', 'bob@contoso.com')
        $resolved.Metadata.ResolvedMailboxes | Should -Be $resolved.Mailboxes
        $resolved.Metadata.ExpandedGroups.Count | Should -Be 2
        $resolved.Metadata.ExcludedMembers[0].Address | Should -Be 'external@example.com'
        Should -Invoke Get-MRDDistributionGroupMember -Times 2 -Exactly -ParameterFilter { $ResultSize -eq 'Unlimited' }
        Should -Invoke Disconnect-ExchangeOnline -Times 0
    }
    It 'selects Microsoft 365 group members rather than the group mailbox' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'team@contoso.com'; Set-TestAnswer @('')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('carol@contoso.com')
        Should -Invoke Get-MRDUnifiedGroupLinks -Times 1 -Exactly -ParameterFilter { $LinkType -eq 'Members' -and $ResultSize -eq 'Unlimited' }
    }
    It 'goes back instead of canceling when B is pressed at the list preview' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'staff@contoso.com'; Set-TestAnswer @('B')
        $failure = $null
        try { Resolve-MRMailboxScope $options } catch { $failure = $_ }
        Test-MRBackSignal $failure | Should -BeTrue
    }
    It 'asks again rather than canceling when something other than Enter or B is typed at the preview' {
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'team@contoso.com'; Set-TestAnswer @('use 1', '')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('carol@contoso.com')
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
        { Resolve-MRMailboxScope $options } | Should -Throw '*group option*'
    }
    It 'selects individual mailboxes and previews the final list' {
        $options.MailboxMode = 'Select'; Set-TestAnswer @('/bob', '1', 'D', '')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('bob@contoso.com')
    }
    It 'uses All without an Exchange connection' {
        $options.Mailboxes = @('All')
        (Resolve-MRMailboxScope $options).Mailboxes | Should -Be @('All')
        Should -Invoke Connect-MRExchange -Times 0
    }
    It 'reuses the loaded directory for the same account, and reloads it for another account' {
        $null = Get-MRDirectory $options.TenantId admin@contoso.com; $null = Get-MRDirectory $options.TenantId ADMIN@contoso.com
        Should -Invoke Get-MRDirectoryData -Times 1 -Exactly
        $null = Get-MRDirectory $options.TenantId other-admin@contoso.com
        Should -Invoke Get-MRDirectoryData -Times 2 -Exactly
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
        $run = New-TestRun; $options = New-TestOptions
        $settingsPath = Join-Path $TestDrive "settings-$([guid]::NewGuid()).json"
        Mock Connect-MRPurview { [pscustomobject]@{ TenantID = $run.TenantId; UserPrincipalName = 'admin@contoso.com' } }
        Mock Connect-MRExchange { throw 'Unexpected Exchange connection' }
        Mock Get-MRTraceResult { New-TestTraceResult $Run -Status Unavailable }
        Mock Get-MRAction { $null }
        Mock New-MRComplianceSearchAction { throw 'Unexpected purge' }
    }
    It 'does not reuse an old search deep link or the built-in Content Search case from legacy settings' {
        Write-MRJson $settingsPath @{ SchemaVersion = 1; TenantId = $run.TenantId; UserPrincipalName = 'admin@contoso.com'; CaseName = 'Content Search'; PurviewUrl = 'https://purview.microsoft.com/ediscovery/case/old-search' }
        $settings = Read-MRProfile $settingsPath
        $settings.ContainsKey('CaseName') | Should -BeFalse
        $options.SettingsPath = $settingsPath; $options.NoSavedSettings = $false
        Invoke-MRWorkflow -Options $options -WhatIf
        $options.PurviewUrl | Should -Be 'https://purview.microsoft.com/ediscovery/'
        $options.CaseName | Should -Be 'Incident case'
        Should -Invoke Connect-MRPurview -Times 0
    }
    It 'stores the resolved group mailbox list in both Purview and the saved run, and never re-expands it for Status' {
        $directoryData = New-TestDirectory
        $script:MRDirectoryCache = $null
        # Mock bodies see the caller's variables, so avoid names the workflow uses, such as $run.
        Mock Connect-MRExchange { [pscustomobject]@{ TenantID = '11111111-1111-1111-1111-111111111111' } }
        Mock Get-MRDirectoryData { $directoryData }
        Mock Get-MRDDistributionGroupMember { [pscustomobject]@{ PrimarySmtpAddress = 'alice@contoso.com'; RecipientType = 'UserMailbox' } }
        Set-TestAnswer @('')
        $options.MailboxMode = 'Group'; $options.GroupAddress = 'staff@contoso.com'
        Mock New-MRComplianceSearch {
            $script:groupSearch = New-TestSearch $run
            $script:groupSearch.Name = $Name; $script:groupSearch.Description = $Description
            $script:groupSearch.ContentMatchQuery = $ContentMatchQuery; $script:groupSearch.ExchangeLocation = $ExchangeLocation
            $script:groupSearch.Items = 1; $script:groupSearch.SuccessResults = '{Location: alice@contoso.com, Item count: 1}'
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
        Save-MRPreference $settingsPath @{ SchemaVersion = 2; TenantId = ''; UserPrincipalName = ''; PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; DataDirectory = $TestDrive } -Confirm:$false
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
        $path = Save-TestRun $run (Join-Path $TestDrive 'recovery')
        Write-MREvent $path 'SearchCreated' @{}; Write-MREvent $path 'Error' @{ Message = 'timeout' }
        $completed = New-TestSearch $run; Mock Get-MRComplianceSearch { $completed }
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
        $path = Save-TestRun $run (Join-Path $TestDrive 'attempt')
        Write-MREvent $path 'SearchCreated' @{}; Write-MREvent $path 'PurgeSubmissionAttempt' @{}
        $completed = New-TestSearch $run; Mock Get-MRComplianceSearch { $completed }
        $options.Mode = 'Status'; $options.RunPath = $path
        Invoke-MRWorkflow -Options $options -Confirm:$false
        Test-Path -LiteralPath (Join-Path $path 'search.json') | Should -BeFalse
        Should -Invoke New-MRComplianceSearchAction -Times 0
    }
    It 'blocks recovery of an incomplete search or a search whose criteria changed' {
        $path = Save-TestRun $run (Join-Path $TestDrive 'invalid')
        $search = New-TestSearch $run; $search.Status = 'InProgress'
        { Save-MRSearchBaseline $path $run $search } | Should -Throw '*completed*'
        $search.Status = 'Completed'; $search.ContentMatchQuery = 'changed'
        { Save-MRSearchBaseline $path $run $search } | Should -Throw '*changed*'
    }
    It 'keeps directory selection previews offline: <MailboxMode>' -ForEach @(@{ MailboxMode = 'Group' }, @{ MailboxMode = 'Select' }) {
        $options.MailboxMode = $MailboxMode; $options.GroupAddress = 'staff@contoso.com'
        Invoke-MRWorkflow -Options $options -WhatIf
        Should -Invoke Connect-MRExchange -Times 0; Should -Invoke Connect-MRPurview -Times 0
        Test-Path -LiteralPath $options.DataDirectory | Should -BeFalse
    }
    It 'rejects saved runs whose resolved membership differs from the search scope' {
        $run.Mailboxes = @('alice@contoso.com')
        $run | Add-Member ScopeSelection ([pscustomobject]@{ ResolvedMailboxes = @('bob@contoso.com') })
        $path = Save-TestRun $run (Join-Path $TestDrive 'tampered')
        { Read-MRRun $path } | Should -Throw '*snapshot*'
    }
}

Describe 'Report selection, quick actions and persistent menu' {
    BeforeEach { Mock Start-Process {}; Mock Set-Clipboard {}; Mock Get-MRSignedInAccount { @() } }
    It 'accepts quoted report paths and offers a file picker' {
        $path = Join-Path $TestDrive 'review report.csv'; 'Sender,Subject', 'phish@example.com,Cell phone' | Set-Content -LiteralPath $path
        Read-MRReportPath "`"$path`"" | Should -Be $path
        $selectedReportFile = $path
        Set-TestAnswer @('F'); Mock Select-MRReportFile { $selectedReportFile }
        Read-MRReportPath | Should -Be $path
        Should -Invoke Select-MRReportFile -Times 1
    }
    It 'retries a mistyped report path and handles a canceled file picker' {
        $path = Join-Path $TestDrive 'report.csv'; 'Sender,Subject', 'phish@example.com,Cell phone' | Set-Content -LiteralPath $path
        Set-TestAnswer @('F', 'does-not-exist.csv', $path); Mock Select-MRReportFile { '' }
        Read-MRReportPath | Should -Be $path
    }
    It 'opens the portal, folder and summary and copies the latest ticket summary' {
        $run = New-TestRun; $path = Save-TestRun $run (Join-Path $TestDrive 'quick')
        Save-MRTicketSummary $path $run (New-TestSearch $run) $null
        Set-TestAnswer @('p', 'E', 'T', 'c', '')
        Show-MRQuickAction $run $path
        Should -Invoke Start-Process -Times 3 -Exactly
        Should -Invoke Set-Clipboard -Times 1 -ParameterFilter { $Value -match 'Ticket: INC-42' }
    }
    It 'returns to the menu after an error, permits another action and then quits' {
        $options = New-TestOptions; $options.Mode = 'Menu'
        Set-TestAnswer @('bad choice', '1', '3', 'q')
        Mock Invoke-MRWorkflow { if ($Options.Mode -eq 'Search') { throw 'Search failed' } }
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Invoke-MRWorkflow -Times 1 -ParameterFilter { $Options.Mode -eq 'Search' }
        Should -Invoke Invoke-MRWorkflow -Times 1 -ParameterFilter { $Options.Mode -eq 'Status' }
    }
    It 'shows the menu again on :cancel at the menu, instead of stopping the toolkit' {
        $options = New-TestOptions; $options.Mode = 'Menu'
        Set-TestAnswer @(':cancel', 'Q')
        { Invoke-MRMenu $options -Confirm:$false } | Should -Not -Throw
        $script:testAnswers.Count | Should -Be 0
    }
    It 'leaves the finished-action screen on :cancel without reporting a cancellation' {
        $run = New-TestRun; $path = Save-TestRun $run (Join-Path $TestDrive 'quick-cancel')
        Set-TestAnswer @(':cancel')
        { Show-MRQuickAction $run $path } | Should -Not -Throw
    }
    It 'opens saved runs from the default folder when the settings file cannot be read' {
        $options = New-TestOptions; $options.Mode = 'Menu'; $options.NoSavedSettings = $false
        $options.SettingsPath = Join-Path $TestDrive 'broken-settings.json'
        Write-MRJson $options.SettingsPath @{ SchemaVersion = 2; Unexpected = 'value' }
        Mock Select-MRRun { throw (Get-MRBackSignal) }
        Set-TestAnswer @('R', 'Q')
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Select-MRRun -Times 1 -Exactly -ParameterFilter { $DataDirectory -eq $options.DataDirectory }
    }
    It 'shows the saved runs again when B is pressed after choosing a run' {
        $options = New-TestOptions; $options.Mode = 'Menu'
        Set-TestAnswer @('2', 'Q')
        $script:attempts = 0
        Mock Invoke-MRWorkflow { $script:attempts++; if ($script:attempts -eq 1) { $Options.PickedRun = $true; throw (Get-MRBackSignal) } }
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Invoke-MRWorkflow -Times 2 -Exactly -ParameterFilter { $Options.Mode -eq 'Remove' }
    }
    It 'returns to the menu when B is pressed before a run is chosen' {
        $options = New-TestOptions; $options.Mode = 'Menu'
        Set-TestAnswer @('2', 'Q')
        Mock Invoke-MRWorkflow { throw (Get-MRBackSignal) }
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Invoke-MRWorkflow -Times 1 -Exactly
    }
    It 'signs out from the menu' {
        $options = New-TestOptions; $options.Mode = 'Menu'
        Mock Get-MRSignedInAccount { @('admin@contoso.com') }; Mock Disconnect-MRSession {}
        Set-TestAnswer @('o', 'Q')
        Invoke-MRMenu $options -Confirm:$false
        Should -Invoke Disconnect-MRSession -Times 1 -Exactly
    }
    It 'edits and persists the evidence location and a ticket link pattern through the settings screen' {
        $options = New-TestOptions; $options.SettingsPath = Join-Path $TestDrive 'ui-settings.json'; $options.NoSavedSettings = $false
        $approved = Join-Path $TestDrive 'approved'
        Set-TestAnswer @('E', '', '', $approved, 'https://desk.example.com/t/{ticket}', '')
        Show-MRSetting $options -Confirm:$false
        $settings = Read-MRProfile $options.SettingsPath
        $settings.DataDirectory | Should -Be $approved
        $settings.TicketUrlTemplate | Should -Be 'https://desk.example.com/t/{ticket}'
    }
    It 'ignores the settings screen when defaults are disabled' {
        $options = New-TestOptions
        Mock Read-Host { throw 'Unexpected prompt' }
        Show-MRSetting $options -Confirm:$false
        Should -Invoke Read-Host -Times 0
    }
}
