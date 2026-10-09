# Shared offline fixtures. Tests never sign in: these guards fail loudly if code tries to.
function Connect-ExchangeOnline { [CmdletBinding()] param($UserPrincipalName, $Prefix, [bool]$ShowBanner, $CommandName) throw 'A test attempted a real Exchange Online sign-in.' }
function Connect-IPPSSession { [CmdletBinding()] param($UserPrincipalName, $Prefix, [switch]$EnableSearchOnlySession, [bool]$ShowBanner) throw 'A test attempted a real Purview sign-in.' }
function Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)] param($ModulePrefix) }
function Get-ConnectionInformation { [CmdletBinding()] param($ModulePrefix) }
function Get-MRComplianceCase { [CmdletBinding()] param($CaseType) }
function New-MRComplianceCase { [CmdletBinding()] param($Name, $CaseType, $Description) }
function Get-MRComplianceSearch { [CmdletBinding()] param($Identity, $Case, $ResultSize) }
function New-MRComplianceSearch { [CmdletBinding()] param($Name, $Case, $ExchangeLocation, $ContentMatchQuery, $Description) }
function Start-MRComplianceSearch { [CmdletBinding()] param($Identity) }
function Set-MRComplianceSearch { [CmdletBinding()] param($Identity, $ContentMatchQuery) }
function Get-MRComplianceSearchAction { [CmdletBinding()] param($Identity, [switch]$Details) }
function New-MRComplianceSearchAction { [CmdletBinding(SupportsShouldProcess)] param($SearchName, [switch]$Purge, $PurgeType) }
function Get-MRDMailbox { [CmdletBinding()] param($ResultSize, $RecipientTypeDetails) }
function Get-MRDRecipient { [CmdletBinding()] param($Identity, $ResultSize, $RecipientTypeDetails) }
function Get-MRDDistributionGroupMember { [CmdletBinding()] param($Identity, $ResultSize) }
function Get-MRDUnifiedGroupLinks { [CmdletBinding()] param($Identity, $LinkType, $ResultSize) }
function Get-MRDMessageTraceV2 { [CmdletBinding()] param($SenderAddress, $StartDate, $EndDate, $ResultSize, $Subject, $SubjectFilterType, $StartingRecipientAddress) }

function New-TestRun {
    param([string]$Ticket = 'INC-42', [string]$Created = '2026-10-06T12:00:00Z', [switch]$AllDates)
    $id = [guid]::NewGuid().ToString()
    $run = [pscustomobject][ordered]@{
        SchemaVersion = 1; RunId = $id; Ticket = $Ticket; TicketUrl = ''; TenantId = '11111111-1111-1111-1111-111111111111'
        SearchName = "MR-$Ticket-$($id.Substring(0,8))"; CaseName = 'Incident case'; CreatedUtc = $Created
        PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; Description = "M365-MailRemediation RunId=$id Ticket=$Ticket"
        SenderAddress = 'phish@example.com'; Subject = 'Cell phone'; ReceivedFrom = '2026-10-05'; ReceivedThrough = '2026-10-06'
        AllDates = $false; Mailboxes = @('All'); Query = ''
    }
    if ($AllDates) { $run.ReceivedFrom = ''; $run.ReceivedThrough = ''; $run.AllDates = $true }
    $run.Query = New-MRQuery -SenderAddress $run.SenderAddress -Subject $run.Subject -ReceivedFrom $run.ReceivedFrom -ReceivedThrough $run.ReceivedThrough -AllDates:$run.AllDates
    return $run
}

function New-TestSearch {
    param($Run)
    [pscustomobject]@{
        Name = $Run.SearchName; Description = $Run.Description; ContentMatchQuery = $Run.Query
        ExchangeLocation = @($Run.Mailboxes); SharePointLocation = @(); OneDriveLocation = @()
        ExchangeLocationExclusion = @(); SharePointLocationExclusion = @(); HoldNames = @()
        Status = 'Completed'; JobRunId = 'original-job'; Items = 5; NumBindings = 200; Errors = ''
        SuccessResults = '{Location: alice@contoso.com, Item count: 2, Total size: 22}; {Location: bob@contoso.com, Item count: 3, Total size: 33}'
    }
}

function New-TestOptions {
    @{
        Mode = 'Search'; Ticket = 'INC-42'; TicketUrl = ''; UserPrincipalName = 'admin@contoso.com'
        TenantId = '11111111-1111-1111-1111-111111111111'; SenderAddress = 'phish@example.com'; Subject = 'Cell phone'
        ReceivedFrom = '2026-10-05'; ReceivedThrough = '2026-10-06'; AllDates = $false
        Mailboxes = @('All'); MailboxMode = 'Paste'; GroupAddress = ''; CaseName = 'Incident case'
        PurviewUrl = 'https://purview.microsoft.com/ediscovery/'; RunPath = ''; ReportPath = ''; PurgeType = 'HardDelete'
        SettingsPath = ''; NoSavedSettings = $true; Interactive = $false; ExplicitParameters = @()
        DataDirectory = (Join-Path $TestDrive "Runs-$([guid]::NewGuid().ToString('N'))"); TimeoutSeconds = 30; PollSeconds = 1
    }
}

function Save-TestRun {
    param($Run, [string]$Root)
    $path = Join-Path $Root $Run.SearchName
    $null = New-Item -ItemType Directory -Path $path -Force
    Write-MRJson (Join-Path $path 'run.json') $Run
    return $path
}

function Set-TestAnswer {
    # Queues typed answers. An unexpected extra prompt fails the test with its text.
    param([string[]]$Values)
    $script:testAnswers = [collections.generic.Queue[string]]::new()
    foreach ($value in $Values) { $script:testAnswers.Enqueue($value) }
    $script:testPrompts = [collections.generic.List[string]]::new()
    Mock Read-Host {
        $script:testPrompts.Add([string]$Prompt)
        if (-not $script:testAnswers.Count) { throw "Unexpected prompt: $Prompt" }
        $script:testAnswers.Dequeue()
    }
}

function New-TestDirectory {
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

function New-TestTraceMessage {
    # A message trace result as the service returns it.
    param([string]$Recipient, [string]$Status = 'Delivered', [string]$Received = '2026-10-05T12:00:00Z', [string]$Subject = 'Cell phone update')
    [pscustomobject]@{
        Received = [datetime]::Parse($Received, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]'AdjustToUniversal,AssumeUniversal')
        RecipientAddress = $Recipient; SenderAddress = 'phish@example.com'; Subject = $Subject; Status = $Status
        MessageId = "<$([guid]::NewGuid().ToString('N'))@example.com>"; MessageTraceId = [guid]::NewGuid(); Size = 1000; FromIP = '203.0.113.5'
    }
}

function New-TestTraceResult {
    param($Run, [object[]]$Messages = @(), [string]$Status = 'Completed')
    $now = [datetime]::SpecifyKind([datetime]'2026-10-08T00:00:00', [DateTimeKind]::Utc)
    [pscustomobject]@{
        Status = $Status; Reason = $(if ($Status -eq 'Completed') { '' } else { 'Test: message trace is unavailable.' })
        Window = (Get-MRTraceWindow $Run -NowUtc $now); Rows = @($Messages | ForEach-Object { ConvertTo-MRTraceRow $_ })
    }
}

function New-TestMatchingTrace {
    # Trace rows that agree with New-TestSearch: two messages for alice and three for bob.
    param($Run)
    $messages = @(
        New-TestTraceMessage alice@contoso.com; New-TestTraceMessage alice@contoso.com -Received '2026-10-06T08:00:00Z'
        New-TestTraceMessage bob@contoso.com; New-TestTraceMessage bob@contoso.com -Status FilteredAsSpam; New-TestTraceMessage bob@contoso.com -Received '2026-10-06T09:00:00Z'
    )
    return New-TestTraceResult $Run $messages
}
