# Offline tests for the message trace review and the session log. No service is called.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\Invoke-MailRemediation.ps1')
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    function Get-TestUtc { param([string]$Value) [datetime]::SpecifyKind([datetime]::Parse($Value, [cultureinfo]::InvariantCulture), [DateTimeKind]::Utc) }
}

Describe 'Message trace dates' {
    BeforeEach { Set-StrictMode -Version Latest; $run = New-TestRun; $now = Get-TestUtc '2026-10-08T12:00:00' }
    It 'covers the search dates when they are within the last 90 days' {
        $window = Get-MRTraceWindow $run -NowUtc $now
        $window.Available | Should -BeTrue; $window.CoversSearchDates | Should -BeTrue
        $window.StartUtc | Should -Be (Get-TestUtc '2026-10-05T00:00:00')
        $window.EndUtc | Should -Be (Get-TestUtc '2026-10-07T00:00:00')
    }
    It 'stops at the current time for a range that includes today' {
        $run.ReceivedThrough = '2026-10-08'
        (Get-MRTraceWindow $run -NowUtc $now).EndUtc | Should -Be $now
    }
    It 'marks an all-dates search as only partly covered' {
        $window = Get-MRTraceWindow (New-TestRun -AllDates) -NowUtc $now
        $window.Available | Should -BeTrue; $window.CoversSearchDates | Should -BeFalse
        $window.Note | Should -BeLike '*90 days*'
    }
    It 'marks dates older than 90 days as unavailable and dates partly older as partial' {
        $run.ReceivedFrom = '2026-01-01'; $run.ReceivedThrough = '2026-01-31'
        (Get-MRTraceWindow $run -NowUtc $now).Available | Should -BeFalse
        $run.ReceivedThrough = '2026-10-01'
        $window = Get-MRTraceWindow $run -NowUtc $now
        $window.Available | Should -BeTrue; $window.CoversSearchDates | Should -BeFalse
        $window.StartUtc | Should -BeGreaterThan (Get-TestUtc '2026-07-10T00:00:00')
    }
}

Describe 'Message trace queries' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $run = New-TestRun; $run.ReceivedFrom = '2026-09-01'; $run.ReceivedThrough = '2026-09-25'
        $window = Get-MRTraceWindow $run -NowUtc (Get-TestUtc '2026-10-08T12:00:00')
        $script:traceCalls = [collections.generic.List[object]]::new()
    }
    It 'splits a long range into queries of at most 10 days and keeps only the exact dates' {
        Mock Get-MRDMessageTraceV2 {
            $script:traceCalls.Add([pscustomobject]@{ Start = $StartDate; End = $EndDate; Subject = $Subject; FilterType = $SubjectFilterType })
            if ($script:traceCalls.Count -eq 1) {
                New-TestTraceMessage alice@contoso.com -Received '2026-08-31T23:00:00Z'
                New-TestTraceMessage alice@contoso.com -Received '2026-09-10T08:00:00Z'
                New-TestTraceMessage alice@contoso.com -Received '2026-09-26T00:00:00Z'
            }
        }
        $rows = @(Invoke-MRMessageTraceQuery -Run $run -Window $window)
        $rows.Count | Should -Be 1
        $rows[0].ReceivedUtc | Should -Be '2026-09-10T08:00:00Z'
        $script:traceCalls.Count | Should -Be 3
        foreach ($call in $script:traceCalls) { ($call.End - $call.Start).TotalDays | Should -BeLessOrEqual 10 }
        $script:traceCalls[0].Start | Should -Be (Get-TestUtc '2026-08-31T00:00:00')
        $script:traceCalls[0].Subject | Should -Be 'Cell phone'; $script:traceCalls[0].FilterType | Should -Be 'Contains'
    }
    It 'continues from the last result when a page is full and does not list a message twice' {
        $run.ReceivedFrom = '2026-09-10'; $run.ReceivedThrough = '2026-09-11'
        $window = Get-MRTraceWindow $run -NowUtc (Get-TestUtc '2026-10-08T12:00:00')
        $first = New-TestTraceMessage alice@contoso.com -Received '2026-09-11T09:00:00Z'
        $second = New-TestTraceMessage bob@contoso.com -Received '2026-09-10T09:00:00Z'
        Mock Get-MRDMessageTraceV2 {
            $script:traceCalls.Add([pscustomobject]@{ From = $StartingRecipientAddress; End = $EndDate })
            if (-not $StartingRecipientAddress) { $first; $second }
            elseif ($StartingRecipientAddress -eq 'bob@contoso.com') { $second; New-TestTraceMessage carol@contoso.com -Received '2026-09-10T08:00:00Z' }
        }
        $rows = @(Invoke-MRMessageTraceQuery -Run $run -Window $window -PageSize 2 -MaxPages 5)
        $rows.RecipientAddress | Should -Be @('carol@contoso.com', 'bob@contoso.com', 'alice@contoso.com')
        $script:traceCalls.Count | Should -Be 3
        $script:traceCalls[1].From | Should -Be 'bob@contoso.com'
        $script:traceCalls[1].End | Should -Be (Get-TestUtc '2026-09-10T09:00:00')
    }
    It 'stops with a clear message instead of listing more messages than anyone can review' {
        Mock Get-MRDMessageTraceV2 { New-TestTraceMessage alice@contoso.com -Received '2026-09-10T08:00:00Z' }
        { Invoke-MRMessageTraceQuery -Run $run -Window $window -PageSize 1 -MaxPages 2 } | Should -Throw '*Narrow the dates*'
    }
}

Describe 'Comparing message trace with the search' {
    BeforeEach { Set-StrictMode -Version Latest; $run = New-TestRun; $search = New-TestSearch $run }
    It 'agrees when every mailbox has the same count, counting Junk Email as delivered' {
        $trace = New-TestMatchingTrace $run
        $compared = Compare-MRTraceWithSearch -Rows $trace.Rows -Search $search -Run $run
        @($compared.Comparison | Where-Object Result -NE 'Same').Count | Should -Be 0
        $compared.Counts.Reviewed | Should -Be 5
    }
    It 'resolves an alias from the mailbox list without asking Exchange, and leaves out group expansions and non-mailboxes' {
        Mock Get-MRDRecipient { throw 'Recipients must not be looked up one at a time.' }
        $lookup = Get-MRMailboxLookup (New-TestDirectory) -IncludeGroupMailboxes
        $messages = @(
            New-TestTraceMessage alice.alias@contoso.com; New-TestTraceMessage alice@contoso.com
            New-TestTraceMessage staff@contoso.com -Status Expanded; New-TestTraceMessage contact@partner.example
        )
        $compared = Compare-MRTraceWithSearch -Rows (New-TestTraceResult $run $messages).Rows -Search $search -Run $run -MailboxLookup $lookup
        ($compared.Comparison | Where-Object Mailbox -EQ 'alice@contoso.com').Result | Should -Be 'Same'
        $compared.Counts.GroupExpansion | Should -Be 1
        $compared.Counts.NotMailbox | Should -Be 1
        ($compared.Comparison | Where-Object Mailbox -EQ 'bob@contoso.com').Result | Should -Be 'Search found more'
        Should -Invoke Get-MRDRecipient -Times 0
    }
    It 'treats a Microsoft 365 group mailbox as a mailbox only for message trace' {
        $directory = New-TestDirectory
        (Get-MRMailboxLookup $directory).ContainsKey('team@contoso.com') | Should -BeFalse
        (Get-MRMailboxLookup $directory -IncludeGroupMailboxes)['team@contoso.com'] | Should -Be 'team@contoso.com'
    }
    It 'reports mailboxes where the trace shows more, and counts quarantined mail as not delivered' {
        $messages = @(
            New-TestTraceMessage alice@contoso.com; New-TestTraceMessage alice@contoso.com; New-TestTraceMessage alice@contoso.com
            New-TestTraceMessage bob@contoso.com -Status Quarantined
        )
        $compared = Compare-MRTraceWithSearch -Rows (New-TestTraceResult $run $messages).Rows -Search $search -Run $run
        $alice = $compared.Comparison | Where-Object Mailbox -EQ 'alice@contoso.com'
        $alice.Result | Should -Be 'Trace found more'
        $bob = $compared.Comparison | Where-Object Mailbox -EQ 'bob@contoso.com'
        $bob.TraceNotDelivered | Should -Be 1; $bob.TraceDelivered | Should -Be 0
    }
    It 'leaves out mailboxes that the search does not include' {
        $run.Mailboxes = @('alice@contoso.com'); $search.SuccessResults = '{Location: alice@contoso.com, Item count: 2}'
        $messages = @(New-TestTraceMessage alice@contoso.com; New-TestTraceMessage alice@contoso.com; New-TestTraceMessage bob@contoso.com)
        $compared = Compare-MRTraceWithSearch -Rows (New-TestTraceResult $run $messages).Rows -Search $search -Run $run -MailboxLookup (Get-MRMailboxLookup (New-TestDirectory))
        $compared.Counts.OutsideScope | Should -Be 1
        @($compared.Comparison).Count | Should -Be 1
    }
}

Describe 'Saved message trace review' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $run = New-TestRun; $search = New-TestSearch $run
        $directory = Save-TestRun $run (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
    }
    It 'saves the message list, the comparison, and a summary grouped by subject' {
        $review = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult (New-TestMatchingTrace $run)
        $review.Messages | Should -Be 5; $review.Mailboxes | Should -Be 2
        $review.Delivered | Should -Be 4; $review.MarkedAsSpam | Should -Be 1
        $review.Subjects[0].Subject | Should -Be 'Cell phone update'; $review.Subjects[0].Messages | Should -Be 5
        foreach ($file in @($review.Files.Messages, $review.Files.Comparison, $review.Files.Review)) { Test-Path -LiteralPath (Join-Path $directory $file) | Should -BeTrue }
        (Get-FileHash -LiteralPath (Join-Path $directory $review.Files.Messages)).Hash | Should -Be $review.MessagesSha256
        (Get-Content -LiteralPath (Join-Path $directory 'events.jsonl') | ConvertFrom-Json).Event | Should -Contain 'TraceSaved'
        (Get-MRSavedTraceReview $directory).Files.Review | Should -Be $review.Files.Review
    }
    It 'stops a spreadsheet from running sender-controlled text written as a formula' {
        $message = New-TestTraceMessage alice@contoso.com -Subject '=HYPERLINK("https://evil.example","Open")'
        $message.MessageId = '+cmd|calc'
        $review = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult (New-TestTraceResult $run @($message))
        $saved = (Import-Csv -LiteralPath (Join-Path $directory $review.Files.Messages))[0]
        $saved.Subject | Should -BeLike "'=HYPERLINK*"
        $saved.MessageId | Should -Be "'+cmd|calc"
        $review.Subjects[0].Subject | Should -BeLike '=HYPERLINK*'
    }
    It 'counts the messages the search found that the trace does not show' {
        $trace = New-TestTraceResult $run @(New-TestTraceMessage alice@contoso.com; New-TestTraceMessage bob@contoso.com; New-TestTraceMessage bob@contoso.com; New-TestTraceMessage bob@contoso.com; New-TestTraceMessage bob@contoso.com)
        $review = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult $trace
        $review.UnshownMailboxes | Should -Be 1; $review.UnshownItems | Should -Be 1
        Get-MRTraceGap $review '' | Should -BeLike '*1 message(s) in 1 mailbox(es) that message trace does not show*'
        $matching = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult (New-TestMatchingTrace $run)
        Get-MRTraceGap $matching '' | Should -Be ''
    }
    It 'shows agreement, differences, and the full list in plain words' {
        $script:shown = [collections.generic.List[string]]::new()
        Mock Write-Host { $script:shown.Add([string]$Object) }
        Mock Write-Warning { $script:shown.Add([string]$Message) }
        $review = Save-MRTraceReview -Directory $directory -Run $run -Search $search -TraceResult (New-TestMatchingTrace $run)
        Show-MRTraceReview $review
        ($script:shown -join "`n") | Should -Match 'agree for all 2 mailbox'
        Show-MRTraceMessage $directory $review
        ($script:shown -join "`n") | Should -Match 'Every message in the review \(5\)'
        $script:shown.Clear()
        $other = Save-TestRun (New-TestRun) (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        $partial = Save-MRTraceReview -Directory $other -Run $run -Search $search -TraceResult (New-TestTraceResult $run @(New-TestTraceMessage alice@contoso.com))
        Show-MRTraceReview $partial
        ($script:shown -join "`n") | Should -Match 'differ for 2 of 2'
        ($script:shown -join "`n") | Should -Match 'bob@contoso.com: search found 3, trace shows 0 delivered'
    }
}

Describe 'Message trace availability' {
    BeforeEach { Set-StrictMode -Version Latest; $run = New-TestRun }
    It 'explains dates older than 90 days without signing in' {
        $run.ReceivedFrom = '2020-01-01'; $run.ReceivedThrough = '2020-01-02'
        Mock Connect-MRExchange { throw 'Unexpected sign-in' }
        $result = Get-MRTraceResult -Run $run -UserPrincipalName admin@contoso.com
        $result.Status | Should -Be 'Unavailable'; $result.Reason | Should -BeLike '*90 days*'
        Should -Invoke Connect-MRExchange -Times 0
    }
    It 'explains a missing message trace role' {
        $run.ReceivedFrom = [datetime]::UtcNow.AddDays(-2).ToString('yyyy-MM-dd'); $run.ReceivedThrough = [datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-dd')
        Mock Connect-MRExchange {}
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Get-MRDMessageTraceV2' }
        $result = Get-MRTraceResult -Run $run -UserPrincipalName admin@contoso.com
        $result.Status | Should -Be 'Unavailable'; $result.Reason | Should -BeLike '*Exchange Administrator*'
    }
    It 'skips message trace without signing in when told why' {
        Mock Connect-MRExchange { throw 'Unexpected sign-in' }
        $result = Get-MRTraceResult -Run $run -UserPrincipalName admin@contoso.com -SkipReason 'Exchange Online did not sign in.'
        $result.Status | Should -Be 'Unavailable'; $result.Reason | Should -Be 'Exchange Online did not sign in.'
        Should -Invoke Connect-MRExchange -Times 0
    }
    It 'fails the review instead of guessing when the mailbox list cannot load' {
        $run.ReceivedFrom = [datetime]::UtcNow.AddDays(-2).ToString('yyyy-MM-dd'); $run.ReceivedThrough = [datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-dd')
        Mock Connect-MRExchange {}
        Mock Invoke-MRMessageTraceQuery { @(ConvertTo-MRTraceRow (New-TestTraceMessage alice@contoso.com -Received ([datetime]::UtcNow.AddDays(-1).ToString('o')))) }
        Mock Get-MRDirectory { throw 'Too many requests.' }
        $result = Get-MRTraceResult -Run $run -UserPrincipalName admin@contoso.com
        $result.Status | Should -Be 'Unavailable'; $result.Reason | Should -BeLike '*Too many requests*'
        @($result.Rows).Count | Should -Be 0
    }
    It 'turns a trace failure into an explanation instead of stopping the search' {
        $run.ReceivedFrom = [datetime]::UtcNow.AddDays(-2).ToString('yyyy-MM-dd'); $run.ReceivedThrough = [datetime]::UtcNow.AddDays(-1).ToString('yyyy-MM-dd')
        Mock Connect-MRExchange {}
        Mock Invoke-MRMessageTraceQuery { throw 'The service is busy.' }
        $result = Get-MRTraceResult -Run $run -UserPrincipalName admin@contoso.com
        $result.Status | Should -Be 'Unavailable'; $result.Reason | Should -BeLike '*service is busy*'
    }
}

Describe 'Session log' {
    BeforeEach { Set-StrictMode -Version Latest; Close-MRLog; $logDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')) }
    AfterEach { Close-MRLog }
    It 'records typed answers and toolkit actions, and links run events to the session' {
        Open-MRLog -Directory $logDirectory -Context @{ Toolkit = 'test' }
        $sessionId = Get-MRLogSessionId
        Set-TestAnswer @('phish@example.com')
        $null = Read-MRAnswer 'Sender email address'
        $runDirectory = Save-TestRun (New-TestRun) $logDirectory
        Write-MREvent $runDirectory 'SearchCreated' @{ SearchName = 'MR-test' }
        Close-MRLog
        $entries = @(Get-ChildItem -LiteralPath $logDirectory -Filter 'session-*.jsonl' | Get-Content | ConvertFrom-Json)
        $entries.Event | Should -Be @('SessionStarted', 'Answer', 'RunSearchCreated', 'SessionEnded')
        ($entries | Where-Object Event -EQ 'Answer').Details.Answer | Should -Be 'phish@example.com'
        ($entries | Where-Object Event -EQ 'Answer').Details.Prompt | Should -Be 'Sender email address'
        (Get-Content -LiteralPath (Join-Path $runDirectory 'events.jsonl') | ConvertFrom-Json).Session | Should -Be $sessionId
        Get-MRLogSessionId | Should -Be ''
    }
    It 'keeps the toolkit working when the log cannot be written' {
        Open-MRLog -Directory $logDirectory -Context @{}
        $script:MRLog.Path = $logDirectory
        Mock Write-MRText {}
        Set-TestAnswer @('first', 'second')
        Read-MRAnswer 'One' | Should -Be 'first'
        Read-MRAnswer 'Two' | Should -Be 'second'
        Should -Invoke Write-MRText -Times 1 -Exactly -ParameterFilter { $Kind -eq 'Notice' -and $Text -like '*session log stopped*' }
    }
    It 'does not start a log without a folder' {
        Open-MRLog -Directory '' -Context @{}
        Get-MRLogSessionId | Should -Be ''
    }
}
