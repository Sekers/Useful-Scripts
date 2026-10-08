# Guided questions for a new search, one step at a time. B goes back one step. The review
# screen can jump to any step and returns to the review afterwards. Answers live in the
# workflow's options hashtable, so going back shows the earlier answer as the default.
function Test-MRSystemCase {
    param([string]$CaseName)
    # Searches the toolkit creates in the built-in Content Search case do not appear in the portal.
    return ([string]$CaseName).Trim() -ieq 'Content Search'
}

function Invoke-MRWizard {
    param([object[]]$Steps, [hashtable]$State, [string[]]$Only = @())
    $names = @($Steps | ForEach-Object { $_.Name })
    $history = [collections.generic.Stack[int]]::new()
    $returnTo = -1; $forced = -1; $index = 0
    while ($true) {
        while ($index -lt $Steps.Count -and $index -ne $forced -and -not (Test-MRStepEligible $Steps[$index] $State $Only)) { $index++ }
        if ($index -ge $Steps.Count) { return }
        $step = $Steps[$index]
        if (-not $step['Auto']) {
            $visible = @(for ($position = 0; $position -lt $Steps.Count; $position++) { if (-not $Steps[$position]['Auto'] -and (Test-MRStepEligible $Steps[$position] $State $Only)) { $position } })
            $number = [array]::IndexOf($visible, $index) + 1
            $heading = if ($forced -eq $index) { "Change: $($step.Title)" } elseif ($number -gt 0) { "Step $number of $($visible.Count): $($step.Title)" } else { $step.Title }
            Write-MRText Heading $heading
        }
        try { $outcome = & $step.Run $State }
        catch {
            if (-not (Test-MRBackSignal $_)) { throw }
            $forced = -1
            if ($returnTo -ge 0) { $index = $returnTo; $returnTo = -1; continue }
            # B at the first question leaves the wizard; the caller decides where that goes.
            if (-not $history.Count) { throw }
            $index = $history.Pop(); continue
        }
        $forced = -1
        if ($outcome -is [string] -and $names -contains $outcome) {
            $returnTo = $index; $index = [array]::IndexOf($names, $outcome); $forced = $index; continue
        }
        if ($returnTo -ge 0) { $index = $returnTo; $returnTo = -1; continue }
        if (-not $step['Auto']) { $history.Push($index) }
        $index++
    }
}

function Test-MRStepEligible {
    param($Step, [hashtable]$State, [string[]]$Only)
    if (@($Only).Count -and $Step.Name -notin $Only) { return $false }
    if ($Step['Skip'] -and (& $Step['Skip'] $State)) { return $false }
    return $true
}

function Get-MRSearchStep {
    # Steps read optional state keys by index: strict mode rejects dot access to missing keys.
    @(
        @{ Name = 'Identity'; Title = 'Organization and admin account'; Skip = { param($s) -not $s['AskIdentity'] }; Run = { param($s) Read-MRIdentityStep $s } }
        @{ Name = 'SignIn'; Title = 'Sign in'; Auto = $true; Skip = { param($s) $s['Offline'] }; Run = { param($s) Connect-MRSearchSession $s } }
        @{ Name = 'Case'; Title = 'Purview case'; Skip = { param($s) $s['CaseLocked'] -or $s['Offline'] }; Run = { param($s) Read-MRCaseStep $s } }
        @{ Name = 'Ticket'; Title = 'Ticket number'; Run = { param($s) Read-MRTicketStep $s } }
        @{ Name = 'TicketUrl'; Title = 'Ticket link (optional)'; Run = { param($s) Read-MRTicketUrlStep $s } }
        @{ Name = 'Sender'; Title = 'Sender'; Run = { param($s) Read-MRSenderStep $s } }
        @{ Name = 'Subject'; Title = 'Subject words (optional)'; Run = { param($s) Read-MRSubjectStep $s } }
        @{ Name = 'Dates'; Title = 'Dates the message arrived'; Run = { param($s) Read-MRDateStep $s } }
        @{ Name = 'Mailboxes'; Title = 'Mailboxes to search'; Run = { param($s) Read-MRMailboxStep $s } }
        @{ Name = 'Review'; Title = 'Review before creating the search'; Run = { param($s) Read-MRSearchReview $s } }
    )
}

function Read-MRSearchPlan {
    param([hashtable]$Options)
    Write-MRText Heading 'New search'
    Write-Host 'The toolkit asks a few questions, shows them for review, then creates the search. Nothing is deleted.'
    Write-MRText Hint 'Enter keeps the value in [brackets]. B goes back one step. ? shows help. :cancel returns to the main menu.'
    $only = [string[]]@()
    if ($Options.ContainsKey('WizardOnly')) { $only = [string[]]@($Options.WizardOnly) }
    # Decide once, so the step count does not change after the account is entered.
    $Options.AskIdentity = -not ($Options['TenantId'] -and $Options['UserPrincipalName'])
    Invoke-MRWizard -Steps (Get-MRSearchStep) -State $Options -Only $only
}

function Read-MRIdentityStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'State', Justification = 'The prompt scriptblocks fill in the state.')]
    param([hashtable]$State)
    Write-Host 'Which Microsoft 365 organization and admin account should the toolkit use? They are remembered after the search.'
    Invoke-MRPromptSequence @(
        { $State.TenantId = Read-MRValidated 'Tenant ID' $State.TenantId { param($value) Get-MRTenantId $value } -HelpTopic TenantId -Hint 'A GUID such as 11111111-2222-3333-4444-555555555555. Type ? to see where to find it.' }
        { $State.UserPrincipalName = Read-MRValidated 'Admin sign-in email' $State.UserPrincipalName { param($value) Get-MREmail $value } -HelpTopic Administrator }
    )
}

function Connect-MRSearchSession {
    param([hashtable]$State)
    if ($State.ContainsKey('SelectedCaseTenantId') -and $State.TenantId -ne $State.SelectedCaseTenantId) {
        throw 'The selected case belongs to a different tenant. Return to Purview cases and select the case in the intended tenant.'
    }
    $null = Connect-MRPurview $State.UserPrincipalName $State.TenantId
    # Exchange Online is needed for picking mailboxes and for message trace. A failure here
    # still allows an all-mailbox search (the mailbox step enforces that, and message trace is
    # skipped); deleting then needs a portal report instead.
    try { $null = Connect-MRExchange $State.UserPrincipalName $State.TenantId; $State.ExchangeAvailable = $true }
    catch [OperationCanceledException] { throw }
    catch {
        $State.ExchangeAvailable = $false
        Write-MRText Notice "Exchange Online sign-in did not work: $($_.Exception.Message) You can still search all mailboxes."
    }
}

function Read-MRCaseStep {
    param([hashtable]$State)
    $preferred = [string]$State['PreferredCase']
    if ($State['AutoAcceptCase']) {
        # A copied run keeps its case when that case is still available and Active.
        $State.AutoAcceptCase = $false
        $match = @(Get-MRPurviewCaseEntry -CaseName $preferred | Where-Object Status -EQ 'Active')
        if ($preferred -and $match.Count -eq 1 -and -not (Test-MRSystemCase $match[0].Key)) {
            $State.CaseName = $match[0].Key
            Write-Host "Using the same case as the original search: $($State.CaseName)"
            return
        }
        Write-Host "The original case '$preferred' is not available or not Active. Choose a case."
    }
    $State.CaseName = Select-MRPurviewCaseName -PreferredCase $preferred
}

function Get-MRSuggestedTicket {
    param([hashtable]$State)
    if ($State.Ticket) { return $State.Ticket }
    # Leave out dates such as 2026-10-05, then take a number like 5678, #5678, or INC-1234.
    $name = [string]$State.CaseName -replace '\d{4}-\d{1,2}-\d{1,2}', ' '
    $match = [regex]::Match($name, '(?<![A-Za-z0-9])(?:[A-Za-z]+-)?\d{3,}(?![A-Za-z0-9])')
    if ($match.Success) { return $match.Value }
    return ''
}

function Read-MRTicketStep {
    param([hashtable]$State)
    $suggested = Get-MRSuggestedTicket $State
    $hint = if (-not $State.Ticket -and $suggested) { "Suggested from the case name. Press Enter to use $suggested, or type the right number." } else { 'Your helpdesk ticket or incident number, such as 5678 or INC-1234.' }
    $previous = $State.Ticket
    $State.Ticket = Read-MRValidated 'Ticket number' $suggested { param($value)
        if ($value -notmatch '^[A-Za-z0-9#][A-Za-z0-9._#-]{0,63}$' -or $value -notmatch '[A-Za-z0-9]') { throw 'Use 1 to 64 letters, numbers, dots, hyphens, underscores, or #.' }
        $value
    } -HelpTopic Ticket -Hint $hint
    # A link built from the saved pattern must follow a changed ticket number.
    if ($previous -ne $State.Ticket -and $State.ContainsKey('TicketUrlFromTemplate') -and $State.TicketUrlFromTemplate) {
        $State.TicketUrl = Get-MRTicketUrlFromTemplate $State
    }
}

function Get-MRTicketUrlFromTemplate {
    param([hashtable]$State)
    $template = if ($State.ContainsKey('TicketUrlTemplate')) { [string]$State.TicketUrlTemplate } else { '' }
    if ($template -and $template.Contains('{ticket}') -and $State.Ticket) { return $template.Replace('{ticket}', [uri]::EscapeDataString($State.Ticket)) }
    return ''
}

function Read-MRTicketUrlStep {
    param([hashtable]$State)
    $fromTemplate = Get-MRTicketUrlFromTemplate $State
    $suggested = if ($State.TicketUrl) { $State.TicketUrl } else { $fromTemplate }
    $hint = if ($fromTemplate -and $suggested -eq $fromTemplate) { 'Built from the link pattern you used last time. Press Enter to use it, type another link, or NONE for no link.' } else { 'Optional https:// link to the ticket. Press Enter to skip, or NONE to clear.' }
    $State.TicketUrl = Read-MRValidated 'Ticket link' $suggested { param($value)
        if (-not $value -or $value -ieq 'NONE') { return '' }
        $uri = $null
        if (-not [uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https') { throw 'The link must be a full address starting with https://.' }
        $value
    } -HelpTopic TicketUrl -Hint $hint
    $State.TicketUrlFromTemplate = [bool]($fromTemplate -and $State.TicketUrl -eq $fromTemplate)
}

function Read-MRSenderStep {
    param([hashtable]$State)
    $State.SenderAddress = Read-MRValidated 'Sender email address' $State.SenderAddress { param($value)
        # Accept the sender as Outlook shows it, such as: John Reyes <john@example.com>
        $inside = [regex]::Match($value, '<\s*([^<>\s]+@[^<>\s]+)\s*>\s*$')
        if ($inside.Success) { $value = $inside.Groups[1].Value }
        Get-MREmail $value
    } -HelpTopic Sender -Hint 'The address the message came from, such as phish@example.com. You can paste "Name <address>" as Outlook shows it.'
}

function Read-MRSubjectStep {
    param([hashtable]$State)
    $current = if ($State.ContainsKey('Subject')) { [string]$State.Subject } else { '' }
    $State.Subject = Read-MRValidated 'Subject words' $current { param($value)
        if (-not $value -or $value -ieq 'NONE') { return '' }
        if ($value -match '["*\r\n\x00-\x1f\u201c\u201d]') { throw 'Leave out quotes and *. Use plain words from the subject.' }
        $value
    } -HelpTopic Subject -Hint 'Press Enter to find every message from this sender, or type words from the subject to narrow it. NONE clears it.'
}

function Read-MRDateStep {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'State', Justification = 'The prompt scriptblocks fill in the state.')]
    param([hashtable]$State)
    $today = [datetime]::UtcNow.Date
    Write-MRText Hint "Dates are in UTC. Today in UTC is $($today.ToString('yyyy-MM-dd')). Both days are included."
    Invoke-MRPromptSequence @(
        {
            $default = if ($State.AllDates) { 'ALL' } elseif ($State.ReceivedFrom) { $State.ReceivedFrom } else { $today.AddDays(-7).ToString('yyyy-MM-dd') }
            $first = Read-MRValidated 'First day (yyyy-MM-dd), or ALL' $default { param($value) if ($value -ieq 'ALL') { 'ALL' } else { (Get-MRDate $value).ToString('yyyy-MM-dd') } } -HelpTopic Dates
            if ($first -eq 'ALL') { $State.AllDates = $true; $State.ReceivedFrom = ''; $State.ReceivedThrough = '' }
            else { $State.AllDates = $false; $State.ReceivedFrom = $first }
        }
        {
            if (-not $State.AllDates) {
                $default = if ($State.ReceivedThrough) { $State.ReceivedThrough } else { $today.ToString('yyyy-MM-dd') }
                $State.ReceivedThrough = Read-MRValidated 'Last day (yyyy-MM-dd)' $default { param($value)
                    $date = Get-MRDate $value
                    if ($date -lt (Get-MRDate $State.ReceivedFrom)) { throw 'The last day must be on or after the first day.' }
                    $date.ToString('yyyy-MM-dd')
                } -HelpTopic Dates
            }
        }
    )
}

function Read-MRMailboxStep {
    param([hashtable]$State)
    while ($true) {
        $hasCurrent = $State.ContainsKey('ScopeSelection') -and $State.ScopeSelection
        # Picking or checking mailboxes needs Exchange Online; a kept list goes to Purview as is.
        $allOnly = $State.ContainsKey('ExchangeAvailable') -and -not $State.ExchangeAvailable -and -not $State['Offline']
        $choice = Read-MRMailboxChoice -CurrentMailboxes @($State.Mailboxes) -AllowKeep:$hasCurrent -AllOnly:$allOnly
        if ($choice.ContainsKey('Keep')) { return }
        foreach ($key in $choice.Keys) { $State[$key] = $choice[$key] }
        if ($State.MailboxMode -eq 'All') { $State.ScopeSelection = [pscustomobject]@{ Mailboxes = @('All'); Metadata = [pscustomobject]@{ Mode = 'All' } }; return }
        if ($State['Offline']) {
            Write-Host 'Preview only: the mailbox list is checked after signing in during a real search.'
            $pending = [string[]]@()
            if ($State.MailboxMode -eq 'Paste') { $pending = [string[]]@(Get-MRScope $State.Mailboxes) }
            $State.ScopeSelection = [pscustomobject]@{ Mailboxes = $pending; Metadata = [pscustomobject]@{ Mode = $State.MailboxMode; Pending = $true } }
            return
        }
        try { $State.ScopeSelection = Resolve-MRMailboxScope -Options $State; $State.Mailboxes = @($State.ScopeSelection.Mailboxes); return }
        catch {
            if ($_.Exception -is [OperationCanceledException] -and -not (Test-MRBackSignal $_)) { throw }
            if (-not (Test-MRBackSignal $_)) { Write-MRText Retry "$($_.Exception.Message) Choose the mailboxes again." }
        }
    }
}

function Format-MRMailboxSummary {
    param([hashtable]$State)
    $selection = $State['ScopeSelection']
    $mailboxes = @(if ($selection) { $selection.Mailboxes } else { $State.Mailboxes })
    if ('All' -in $mailboxes) { return 'All mailboxes' }
    $group = Get-MRProperty (Get-MRProperty $selection 'Metadata') 'Group'
    $prefix = if ($group) { "Members of $($group.Address): " } else { '' }
    if (-not $mailboxes.Count) { return "$($State.MailboxMode) (chosen after signing in)" }
    $shown = @($mailboxes | Select-Object -First 3) -join ', '
    $more = if ($mailboxes.Count -gt 3) { ", and $($mailboxes.Count - 3) more" } else { '' }
    return "$prefix$($mailboxes.Count) mailbox(es): $shown$more"
}

function Read-MRSearchReview {
    param([hashtable]$State)
    $dates = if ($State.AllDates) { 'All dates' } else { "$($State.ReceivedFrom) to $($State.ReceivedThrough) (UTC, both days included)" }
    $items = @(
        @{ Step = 'Case'; Label = 'Case'; Value = $(if ($State.CaseName) { $State.CaseName } else { '(chosen after signing in)' }); Editable = -not ($State['CaseLocked'] -or $State['Offline']) }
        @{ Step = 'Ticket'; Label = 'Ticket'; Value = $State.Ticket; Editable = $true }
        @{ Step = 'TicketUrl'; Label = 'Ticket link'; Value = $(if ($State.TicketUrl) { $State.TicketUrl } else { '(none)' }); Editable = $true }
        @{ Step = 'Sender'; Label = 'Sender'; Value = $State.SenderAddress; Editable = $true }
        @{ Step = 'Subject'; Label = 'Subject words'; Value = $(if ($State['Subject']) { $State['Subject'] } else { '(any subject)' }); Editable = $true }
        @{ Step = 'Dates'; Label = 'Dates'; Value = $dates; Editable = $true }
        @{ Step = 'Mailboxes'; Label = 'Mailboxes'; Value = (Format-MRMailboxSummary $State); Editable = $true }
    )
    Write-Host "Account: $($State.UserPrincipalName) in tenant $($State.TenantId)"
    for ($position = 0; $position -lt $items.Count; $position++) {
        $marker = if ($items[$position].Editable) { "[$($position + 1)]" } else { '   ' }
        Write-Host ("{0} {1,-15} {2}" -f $marker, "$($items[$position].Label):", $items[$position].Value)
    }
    Write-Host 'The search finds email from this sender in these mailboxes and dates. Nothing is deleted.'
    $missing = @($items | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object { $_.Label })
    while ($true) {
        $answer = (Read-MRAnswer 'Press Enter to create the search, type a number to change an item, or B to go back').Trim()
        if (-not $answer) {
            if ($missing.Count) { Write-MRText Retry "Fill in: $($missing -join ', ')."; continue }
            return $null
        }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $items.Count -and $items[$number - 1].Editable) { return $items[$number - 1].Step }
        Write-MRText Retry 'Press Enter, type one of the numbers shown, or B.'
    }
}

function Resolve-MRSearchPlan {
    # Command-line searches ask only for required values that were not supplied.
    param([hashtable]$Options)
    # Check the case before anything signs in, so a bad case name fails fast.
    if ([string]::IsNullOrWhiteSpace($Options.CaseName)) { throw 'Name an existing Purview case with -CaseName.' }
    if (Test-MRSystemCase $Options.CaseName) {
        if ($Options.SourceRun) { throw 'The original search used the built-in Content Search case, where new toolkit searches do not appear in the Purview portal. Add -CaseName with an incident case.' }
        throw 'The toolkit does not create searches in the built-in Content Search case, because they do not appear in the Purview portal there. Use -CaseName with an incident case.'
    }
    if (-not $Options.Ticket) { Read-MRTicketStep $Options }
    if ($Options.Ticket -notmatch '^[A-Za-z0-9#][A-Za-z0-9._#-]{0,63}$' -or $Options.Ticket -notmatch '[A-Za-z0-9]') { throw 'Use a ticket identifier of 1 to 64 characters, including at least one letter or number. Dots, underscores, hashes, and hyphens are allowed.' }
    if (-not $Options.TenantId -or -not $Options.UserPrincipalName) { Read-MRIdentityStep $Options }
    $Options.TenantId = Get-MRTenantId $Options.TenantId
    $Options.UserPrincipalName = Get-MREmail $Options.UserPrincipalName
    if ($Options.ContainsKey('SelectedCaseTenantId') -and $Options.TenantId -ne $Options.SelectedCaseTenantId) {
        throw 'The selected case belongs to a different tenant. Return to Purview cases and select the case in the intended tenant.'
    }
    if (-not $Options.SenderAddress) { Read-MRSenderStep $Options }
    $Options.SenderAddress = Get-MREmail $Options.SenderAddress
    if (-not $Options.ContainsKey('Subject')) { $Options.Subject = '' }
    if (-not $Options.AllDates -and (-not $Options.ReceivedFrom -or -not $Options.ReceivedThrough)) { Read-MRDateStep $Options }
    if ($Options.GroupAddress -and 'MailboxMode' -notin $Options.ExplicitParameters) { $Options.MailboxMode = 'Group' }
    if (-not ($Options.ContainsKey('ScopeSelection') -and $Options.ScopeSelection)) {
        if ($Options.Offline -and $Options.MailboxMode -in @('Select', 'Group')) {
            $Options.ScopeSelection = [pscustomobject]@{ Mailboxes = @(); Metadata = [pscustomobject]@{ Mode = $Options.MailboxMode; Pending = $true } }
        }
        elseif ($Options.Offline) {
            $Options.ScopeSelection = [pscustomobject]@{ Mailboxes = $(if ($Options.MailboxMode -eq 'All') { @('All') } else { @(Get-MRScope $Options.Mailboxes) }); Metadata = $null }
        }
        else { $Options.ScopeSelection = Resolve-MRMailboxScope -Options $Options }
    }
}
