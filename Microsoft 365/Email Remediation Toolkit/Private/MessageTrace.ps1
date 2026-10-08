# Message trace review. Exchange's delivery log lists each message the sender delivered,
# so the toolkit can show subjects and recipients before removal without the Purview portal.
# Purview still performs the search and the removal. The trace is a cross-check: it covers
# only the last 90 days and shows deliveries, so it is compared with the search per mailbox.

function ConvertTo-MRUtcDate {
    param($Value)
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        # The service reports UTC times.
        return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.UtcDateTime }
    throw "Message trace returned a time that could not be read: '$Value'."
}

function Format-MRUtc {
    param([datetime]$Value)
    return $Value.ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}

function Get-MRTraceWindow {
    param($Run, [datetime]$NowUtc = [datetime]::UtcNow)
    $NowUtc = [datetime]::SpecifyKind($NowUtc, [DateTimeKind]::Utc)
    # Stay an hour inside the 90-day history limit so the oldest query is accepted.
    $earliest = $NowUtc.AddDays(-90).AddHours(1)
    $window = [ordered]@{ Available = $true; StartUtc = $earliest; EndUtc = $NowUtc; EarliestUtc = $earliest; NowUtc = $NowUtc; CoversSearchDates = $true; Note = '' }
    if ($Run.AllDates) {
        $window.CoversSearchDates = $false
        $window.Note = 'The search covers all dates, but message trace only keeps the last 90 days.'
        return [pscustomobject]$window
    }
    $from = [datetime]::SpecifyKind((Get-MRDate $Run.ReceivedFrom), [DateTimeKind]::Utc)
    $to = [datetime]::SpecifyKind((Get-MRDate $Run.ReceivedThrough), [DateTimeKind]::Utc).AddDays(1)
    if ($to -le $earliest) {
        $window.Available = $false; $window.CoversSearchDates = $false
        $window.Note = 'These dates are more than 90 days ago, which is as far back as message trace goes.'
        return [pscustomobject]$window
    }
    if ($from -ge $NowUtc) {
        $window.Available = $false; $window.CoversSearchDates = $false
        $window.Note = 'These dates are in the future, so there is nothing to trace yet.'
        return [pscustomobject]$window
    }
    $window.StartUtc = if ($from -lt $earliest) { $earliest } else { $from }
    $window.EndUtc = if ($to -gt $NowUtc) { $NowUtc } else { $to }
    if ($from -lt $earliest) {
        $window.CoversSearchDates = $false
        $window.Note = "Message trace only reaches back 90 days, so mail received before $($earliest.ToString('yyyy-MM-dd')) is not listed."
    }
    return [pscustomobject]$window
}

function ConvertTo-MRTraceRow {
    param($Result)
    [pscustomobject][ordered]@{
        ReceivedUtc = Format-MRUtc (ConvertTo-MRUtcDate (Get-MRProperty $Result 'Received'))
        RecipientAddress = ([string](Get-MRProperty $Result 'RecipientAddress')).Trim().ToLowerInvariant()
        SenderAddress = ([string](Get-MRProperty $Result 'SenderAddress')).Trim().ToLowerInvariant()
        Subject = [string](Get-MRProperty $Result 'Subject')
        Status = [string](Get-MRProperty $Result 'Status')
        Mailbox = ''
        InReview = $false
        MessageId = [string](Get-MRProperty $Result 'MessageId')
        MessageTraceId = [string](Get-MRProperty $Result 'MessageTraceId')
        Size = Get-MRProperty $Result 'Size'
        FromIP = [string](Get-MRProperty $Result 'FromIP')
    }
}

function Invoke-MRMessageTraceQuery {
    param($Run, $Window, [int]$PageSize = 5000, [int]$MaxPages = 20)
    # Query a day beyond each end, then filter exactly, so time zone handling at the
    # service cannot drop messages at the edges of the range.
    $queryStart = $Window.StartUtc.AddDays(-1)
    if ($queryStart -lt $Window.EarliestUtc) { $queryStart = $Window.EarliestUtc }
    $queryEnd = $Window.EndUtc.AddDays(1)
    if ($queryEnd -gt $Window.NowUtc) { $queryEnd = $Window.NowUtc }
    # The service returns at most 10 days per query.
    $span = [timespan]::FromDays(10) - [timespan]::FromMinutes(1)
    $rows = [collections.generic.List[object]]::new()
    $seen = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $chunkStart = $queryStart
    while ($chunkStart -lt $queryEnd) {
        $chunkEnd = $chunkStart + $span
        if ($chunkEnd -gt $queryEnd) { $chunkEnd = $queryEnd }
        $parameters = @{ SenderAddress = $Run.SenderAddress; StartDate = $chunkStart; EndDate = $chunkEnd; ResultSize = $PageSize; ErrorAction = 'Stop' }
        if ($Run.Subject) { $parameters.Subject = $Run.Subject; $parameters.SubjectFilterType = 'Contains' }
        for ($page = 1; ; $page++) {
            $results = @(Get-MRDMessageTraceV2 @parameters)
            Write-MRLog 'MessageTraceQuery' @{ StartUtc = Format-MRUtc $chunkStart; EndUtc = Format-MRUtc $parameters.EndDate; Page = $page; Results = $results.Count }
            foreach ($result in $results) {
                $row = ConvertTo-MRTraceRow $result
                if ($seen.Add("$($row.MessageTraceId)|$($row.RecipientAddress)|$($row.Status)")) { $rows.Add($row) }
            }
            if ($results.Count -lt $PageSize) { break }
            if ($page -ge $MaxPages) { throw 'Message trace found more messages than this review can list. Narrow the dates or add subject words.' }
            # The service has no paging; continue from the last recipient and time returned.
            $last = $results[-1]
            $parameters.StartingRecipientAddress = [string](Get-MRProperty $last 'RecipientAddress')
            $parameters.EndDate = ConvertTo-MRUtcDate (Get-MRProperty $last 'Received')
        }
        $chunkStart = $chunkEnd
    }
    $first = Format-MRUtc $Window.StartUtc; $last = Format-MRUtc $Window.EndUtc
    return @($rows | Where-Object { $_.ReceivedUtc -ge $first -and $_.ReceivedUtc -lt $last } | Sort-Object ReceivedUtc, RecipientAddress)
}

function Get-MRTraceResult {
    param($Run, [string]$UserPrincipalName, [string]$SkipReason)
    $window = Get-MRTraceWindow $Run
    $result = [ordered]@{ Status = 'Unavailable'; Reason = ''; Window = $window; Rows = @(); MailboxLookup = @{} }
    if ($SkipReason) { $result.Reason = $SkipReason }
    elseif (-not $window.Available) { $result.Reason = $window.Note }
    else {
        try {
            $null = Connect-MRExchange $UserPrincipalName $Run.TenantId
            if (-not (Get-Command Get-MRDMessageTraceV2 -ErrorAction SilentlyContinue)) {
                $result.Reason = 'This admin account cannot run message trace. It needs an Exchange role such as Exchange Administrator.'
            }
            else {
                Write-Host 'Checking message trace (the Exchange delivery log) for the same sender and dates.'
                $result.Rows = @(Invoke-MRMessageTraceQuery -Run $Run -Window $window)
                # Recipients are matched to mailboxes, including by alias, from the mailbox list.
                # Without it a real mailbox could look like an outside address, so fail instead.
                $result.MailboxLookup = Get-MRMailboxLookup (Get-MRDirectory $Run.TenantId $UserPrincipalName) -IncludeGroupMailboxes
                $result.Status = 'Completed'
            }
        }
        catch [OperationCanceledException] { throw }
        catch { $result.Reason = "Message trace did not work: $($_.Exception.Message)"; $result.Rows = @() }
    }
    Write-MRLog 'MessageTrace' @{ Search = $Run.SearchName; Status = $result.Status; Reason = $result.Reason; Rows = @($result.Rows).Count }
    return [pscustomobject]$result
}

function Compare-MRTraceWithSearch {
    param([object[]]$Rows, $Search, $Run, [hashtable]$MailboxLookup = @{})
    $locations = @(Get-MRLocationCount ([string](Get-MRProperty $Search 'SuccessResults')))
    $searchCounts = @{}
    $known = @{}
    foreach ($key in $MailboxLookup.Keys) { $known[$key] = $MailboxLookup[$key] }
    foreach ($location in $locations) { $searchCounts[$location.Location] = [long]$location.Items; $known[$location.Location] = $location.Location }
    $scoped = 'All' -notin @($Run.Mailboxes)
    $inScope = @{}
    if ($scoped) { foreach ($mailbox in @($Run.Mailboxes)) { $inScope[$mailbox.ToLowerInvariant()] = $true; $known[$mailbox.ToLowerInvariant()] = $mailbox.ToLowerInvariant() } }
    $perMailbox = @{}
    $counts = [ordered]@{ Reviewed = 0; NotMailbox = 0; OutsideScope = 0; GroupExpansion = 0 }
    foreach ($row in $Rows) {
        # An Expanded record means a group was expanded into its members, not a delivery.
        if ($row.Status -eq 'Expanded') { $counts.GroupExpansion++; continue }
        $address = ([string]$row.RecipientAddress).Trim().ToLowerInvariant()
        $row.Mailbox = if ($address -and $known.ContainsKey($address)) { $known[$address] } else { '' }
        if (-not $row.Mailbox) { $counts.NotMailbox++; continue }
        if ($scoped -and -not $inScope.ContainsKey($row.Mailbox)) { $counts.OutsideScope++; continue }
        $row.InReview = $true; $counts.Reviewed++
        if (-not $perMailbox.ContainsKey($row.Mailbox)) { $perMailbox[$row.Mailbox] = [ordered]@{ Delivered = 0; NotDelivered = 0 } }
        if ($row.Status -in @('Delivered', 'FilteredAsSpam')) { $perMailbox[$row.Mailbox].Delivered++ } else { $perMailbox[$row.Mailbox].NotDelivered++ }
    }
    $names = @(@($perMailbox.Keys) + @($searchCounts.Keys | Where-Object { $searchCounts[$_] -gt 0 }) | Sort-Object -Unique)
    $comparison = @(foreach ($name in $names) {
        $found = if ($searchCounts.ContainsKey($name)) { $searchCounts[$name] } else { 0 }
        $delivered = if ($perMailbox.ContainsKey($name)) { $perMailbox[$name].Delivered } else { 0 }
        $notDelivered = if ($perMailbox.ContainsKey($name)) { $perMailbox[$name].NotDelivered } else { 0 }
        $result = if ($found -eq $delivered) { 'Same' } elseif ($found -gt $delivered) { 'Search found more' } else { 'Trace found more' }
        [pscustomobject][ordered]@{ Mailbox = $name; SearchFound = $found; TraceDelivered = $delivered; TraceNotDelivered = $notDelivered; Result = $result }
    })
    return [pscustomobject]@{ Comparison = $comparison; Counts = [pscustomobject]$counts }
}

function ConvertTo-MRSafeCsvText {
    param([string]$Value)
    # Subjects and message IDs come from the sender. Stop spreadsheets running them as formulas.
    if ($Value -match '^[=+\-@\t\r]') { return "'" + $Value }
    return $Value
}

function ConvertTo-MRSafeCsvRow {
    param($Row)
    $copy = $Row.PSObject.Copy()
    foreach ($property in $copy.PSObject.Properties) { if ($property.Value -is [string]) { $property.Value = ConvertTo-MRSafeCsvText $property.Value } }
    return $copy
}

function Save-MRTraceReview {
    param([string]$Directory, $Run, $Search, $TraceResult)
    $rows = @($TraceResult.Rows)
    $lookup = if (Get-MRProperty $TraceResult 'MailboxLookup') { $TraceResult.MailboxLookup } else { @{} }
    $compared = Compare-MRTraceWithSearch -Rows $rows -Search $Search -Run $Run -MailboxLookup $lookup
    $reviewed = @($rows | Where-Object InReview)
    $stamp = '{0}-{1}' -f [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0, 6)
    $files = [ordered]@{ Messages = "message-trace-messages-$stamp.csv"; Comparison = "message-trace-comparison-$stamp.csv"; Review = "message-trace-review-$stamp.json" }
    $messageColumns = @('ReceivedUtc', 'RecipientAddress', 'Mailbox', 'InReview', 'Status', 'Subject', 'SenderAddress', 'MessageId', 'MessageTraceId', 'Size', 'FromIP')
    Write-MRCsv (Join-Path $Directory $files.Messages) @($rows | ForEach-Object { ConvertTo-MRSafeCsvRow $_ }) $messageColumns
    Write-MRCsv (Join-Path $Directory $files.Comparison) @($compared.Comparison | ForEach-Object { ConvertTo-MRSafeCsvRow $_ }) @('Mailbox', 'SearchFound', 'TraceDelivered', 'TraceNotDelivered', 'Result')
    # Messages the search found that the trace did not show have not been seen by anyone.
    $unshown = @($compared.Comparison | Where-Object { $_.SearchFound -gt $_.TraceDelivered })
    $unshownItems = [long](($unshown | ForEach-Object { $_.SearchFound - $_.TraceDelivered } | Measure-Object -Sum).Sum)
    $subjects = @($reviewed | Group-Object Subject | Sort-Object Count -Descending | ForEach-Object {
        $times = @($_.Group.ReceivedUtc | Sort-Object)
        [ordered]@{ Subject = $_.Name; Messages = $_.Count; Mailboxes = @($_.Group.Mailbox | Sort-Object -Unique).Count; FirstUtc = $times[0]; LastUtc = $times[-1] }
    })
    $differences = @($compared.Comparison | Where-Object Result -NE 'Same')
    $review = [ordered]@{
        Status = 'Completed'; RecordedUtc = [datetimeoffset]::UtcNow.ToString('o'); Sender = $Run.SenderAddress; SubjectFilter = $Run.Subject
        WindowStartUtc = Format-MRUtc $TraceResult.Window.StartUtc; WindowEndUtc = Format-MRUtc $TraceResult.Window.EndUtc
        CoversSearchDates = [bool]$TraceResult.Window.CoversSearchDates; Note = [string]$TraceResult.Window.Note
        Messages = $reviewed.Count; Mailboxes = @($reviewed.Mailbox | Sort-Object -Unique).Count
        Delivered = @($reviewed | Where-Object Status -EQ 'Delivered').Count
        MarkedAsSpam = @($reviewed | Where-Object Status -EQ 'FilteredAsSpam').Count
        NotDelivered = @($reviewed | Where-Object { $_.Status -notin @('Delivered', 'FilteredAsSpam') }).Count
        OutsideScope = $compared.Counts.OutsideScope; NotMailbox = $compared.Counts.NotMailbox; GroupExpansion = $compared.Counts.GroupExpansion
        Subjects = $subjects
        MailboxesCompared = @($compared.Comparison).Count; MailboxesDifferent = $differences.Count
        UnshownMailboxes = $unshown.Count; UnshownItems = $unshownItems
        Differences = @($differences | Select-Object -First 50)
        Files = $files
        MessagesSha256 = (Get-FileHash -LiteralPath (Join-Path $Directory $files.Messages) -Algorithm SHA256).Hash
    }
    Write-MRJson (Join-Path $Directory $files.Review) $review
    Write-MREvent $Directory 'TraceSaved' @{ Messages = $review.Messages; Mailboxes = $review.Mailboxes; Different = $review.MailboxesDifferent; Covers = $review.CoversSearchDates; Files = $files; MessagesSha256 = $review.MessagesSha256 }
    return Get-Content -LiteralPath (Join-Path $Directory $files.Review) -Raw | ConvertFrom-Json
}

function Get-MRSavedTraceReview {
    param([string]$Directory)
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter 'message-trace-review-*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    foreach ($file in $files) {
        try {
            $review = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            if ($review.Status -eq 'Completed') { return $review }
        }
        catch { Write-MRText Notice "Skipping an unreadable message trace review: $($file.Name)" }
    }
    return $null
}

function Show-MRTraceReview {
    param($Review)
    $clean = { param($text) ([string]$text -replace '[\r\n\x00-\x1f]', ' ') }
    Write-MRText Heading 'What Exchange delivered (message trace)'
    Write-MRText Hint "Message trace is Exchange's delivery log. It shows each message the sender delivered, so you can check the search found the right email."
    Write-Host "Dates checked: $($Review.WindowStartUtc) to $($Review.WindowEndUtc) (UTC)"
    if ($Review.Note) { Write-MRText Notice $Review.Note }
    if (-not $Review.Messages) { Write-Host "No messages from $($Review.Sender) were delivered to the searched mailboxes in those dates." }
    else {
        Write-Host "$($Review.Messages) message(s) from $($Review.Sender) reached $($Review.Mailboxes) mailbox(es): $($Review.Delivered) delivered, $($Review.MarkedAsSpam) to Junk Email, $($Review.NotDelivered) not delivered (quarantined, failed, or pending)."
        Write-Host 'Subjects:'
        foreach ($subject in @($Review.Subjects | Select-Object -First 10)) {
            $text = if ($subject.Subject) { & $clean $subject.Subject } else { '(no subject)' }
            Write-Host ('  {0,5} x  {1}' -f $subject.Messages, $text)
        }
        if (@($Review.Subjects).Count -gt 10) { Write-Host "  ...and $(@($Review.Subjects).Count - 10) more subjects. Choose L to list every message." }
    }
    if ($Review.OutsideScope) { Write-Host "$($Review.OutsideScope) other message(s) went to mailboxes this search does not include." }
    if ($Review.NotMailbox) { Write-Host "$($Review.NotMailbox) message(s) went to addresses that are not mailboxes here, such as outside addresses or contacts." }
    if (-not $Review.MailboxesCompared) { return }
    if (-not $Review.MailboxesDifferent) {
        Write-MRText Success "The search and message trace agree for all $($Review.MailboxesCompared) mailbox(es)."
        return
    }
    Write-Warning "The search and message trace differ for $($Review.MailboxesDifferent) of $($Review.MailboxesCompared) mailbox(es):"
    foreach ($difference in @($Review.Differences | Select-Object -First 15)) {
        Write-Host "  $($difference.Mailbox): search found $($difference.SearchFound), trace shows $($difference.TraceDelivered) delivered"
    }
    if ($Review.MailboxesDifferent -gt 15) { Write-Host "  ...see $($Review.Files.Comparison) in the run folder for the rest." }
    Write-Host 'Usual reasons: the user already deleted the message (trace shows more), or the search also found older or archived copies (search shows more). Check these mailboxes before deleting.'
    if ([long]$Review.UnshownItems -gt 0) {
        Write-MRText Notice "The search found $($Review.UnshownItems) message(s) that the trace does not show, so deleting will need a report from the Purview portal to review them first."
    }
}

function Show-MRTraceMessage {
    param([string]$Directory, $Review)
    $path = Join-Path $Directory $Review.Files.Messages
    $rows = @(Import-Csv -LiteralPath $path | Where-Object InReview -EQ 'True')
    Write-MRText Heading "Every message in the review ($($rows.Count)), oldest first. Times are UTC."
    foreach ($row in @($rows | Select-Object -First 500)) {
        $subject = ($row.Subject -replace '^''', '' -replace '[\r\n\x00-\x1f]', ' ')
        Write-Host ('{0}  {1,-40}  {2,-14}  {3}' -f $row.ReceivedUtc, $row.Mailbox, $row.Status, $subject)
    }
    if ($rows.Count -gt 500) { Write-Host "Showing the first 500. The full list is in $path" }
}
