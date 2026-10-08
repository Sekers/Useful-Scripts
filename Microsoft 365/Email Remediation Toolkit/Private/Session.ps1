# Sign-in for the two services the toolkit uses. Connections stay open for the
# PowerShell window, so later actions and later runs in the same window reuse them.
# Purview (prefix MR): cases, searches, and removal.
# Exchange Online (prefix MRD): mailbox and group lookups, and message trace.
$script:MRTraceUnavailable = @{}

function Test-MRCompatibility {
    param([version]$ModuleVersion, [version]$PowerShellVersion = $PSVersionTable.PSVersion)
    if ($ModuleVersion -lt [version]'3.9.0') { throw 'ExchangeOnlineManagement 3.9.0 or later is required.' }
    $minimum = if ($ModuleVersion -ge [version]'3.10.0') { [version]'7.6.0' } else { [version]'7.4.0' }
    if ($PowerShellVersion -lt $minimum) { throw "ExchangeOnlineManagement $ModuleVersion requires PowerShell $minimum or later. This session is $PowerShellVersion. Open a compatible PowerShell session." }
}

function Import-MRExchangeModule {
    $loaded = @(Get-Module ExchangeOnlineManagement)
    if ($loaded.Count -gt 1) { throw 'Multiple ExchangeOnlineManagement versions are loaded. Open a fresh PowerShell session.' }
    if ($loaded.Count -and $loaded[0].Version -lt [version]'3.9.0') { throw 'An older ExchangeOnlineManagement module is loaded. Open a fresh PowerShell session with version 3.9.0 or later.' }
    $selected = if ($loaded.Count) { $loaded[0] } else {
        $compatible = @(Get-Module -ListAvailable ExchangeOnlineManagement | Where-Object {
            $_.Version -ge [version]'3.9.0' -and ($_.Version -lt [version]'3.10.0' -or $PSVersionTable.PSVersion -ge [version]'7.6.0')
        } | Sort-Object Version -Descending)
        if (-not $compatible.Count) { throw 'No compatible ExchangeOnlineManagement module is installed. Install version 3.9.x for PowerShell 7.4+, or 3.10+ for PowerShell 7.6+.' }
        $compatible[0]
    }
    Test-MRCompatibility -ModuleVersion $selected.Version
    Import-Module ExchangeOnlineManagement -RequiredVersion $selected.Version -Global -ErrorAction Stop
}

function Get-MRConnection {
    param([ValidateSet('MR', 'MRD')][string]$Prefix)
    return @(Get-ConnectionInformation -ModulePrefix $Prefix -ErrorAction Stop)
}

function Test-MRConnectionIdentity {
    param($Connection, [string]$UserPrincipalName, [string]$TenantId, [bool]$Purview)
    $tenant = [guid]::Empty
    if (-not [guid]::TryParse([string]$Connection.TenantID, [ref]$tenant)) { return $false }
    return ($Connection.State -eq 'Connected' -and [bool]$Connection.IsEopSession -eq $Purview -and
        $tenant -eq [guid]$TenantId -and [string]$Connection.UserPrincipalName -ieq $UserPrincipalName)
}

function Write-MRSignInNotice {
    param([string]$Service)
    Write-MRText Notice "Signing in to $Service. If no sign-in window appears, check behind this window."
}

function Connect-MRPurview {
    param([string]$UserPrincipalName, [string]$TenantId, [switch]$ReadOnly)
    $null = [guid]::Parse($TenantId)
    $upn = Get-MREmail $UserPrincipalName
    Import-MRExchangeModule
    $requiredCommands = if ($ReadOnly) { @('Get-MRComplianceCase', 'Get-MRComplianceSearch') }
        else { @('Get-MRComplianceCase', 'New-MRComplianceSearch', 'Start-MRComplianceSearch', 'Get-MRComplianceSearch') }
    $existing = @(Get-MRConnection MR)
    if ($existing.Count -eq 1 -and (Test-MRConnectionIdentity $existing[0] $upn $TenantId $true)) {
        foreach ($command in $requiredCommands) { $null = Get-Command $command -ErrorAction Stop }
        Write-MRLog 'SignIn' @{ Service = 'Purview'; Account = $upn; TenantId = $TenantId; Reused = $true }
        return $existing[0]
    }
    if ($existing.Count) {
        Write-Host 'Signing out of the earlier Purview connection because it uses a different account or tenant.'
        Disconnect-ExchangeOnline -ModulePrefix MR -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-MRLog 'SignOut' @{ Service = 'Purview'; Reason = 'Different account or tenant' }
    }
    try {
        Write-MRSignInNotice 'Microsoft Purview (searches and removal)'
        Connect-IPPSSession -UserPrincipalName $upn -Prefix MR -EnableSearchOnlySession -ShowBanner:$false -ErrorAction Stop
        $connections = @(Get-MRConnection MR)
        if ($connections.Count -ne 1 -or -not $connections[0].IsEopSession -or $connections[0].State -ne 'Connected') {
            throw 'Could not identify one connected Purview session. Nothing will be changed.'
        }
        $connection = $connections[0]
        if ([guid]$connection.TenantID -ne [guid]$TenantId -or $connection.UserPrincipalName -ine $upn) {
            throw 'The signed-in tenant or administrator differs from the requested identity. Nothing will be changed.'
        }
        foreach ($command in $requiredCommands) { $null = Get-Command $command -ErrorAction Stop }
        Write-MRLog 'SignIn' @{ Service = 'Purview'; Account = $upn; TenantId = $TenantId; Reused = $false }
        return $connection
    }
    catch {
        Write-MRLog 'SignInFailed' @{ Service = 'Purview'; Account = $upn; TenantId = $TenantId; Message = $_.Exception.Message }
        Disconnect-ExchangeOnline -ModulePrefix MR -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        throw
    }
}

function Connect-MRExchange {
    param([string]$UserPrincipalName, [string]$TenantId)
    $upn = Get-MREmail $UserPrincipalName; $null = [guid]::Parse($TenantId)
    Import-MRExchangeModule
    $traceKey = "$TenantId|$upn".ToLowerInvariant()
    $existing = @(Get-MRConnection MRD)
    if ($existing.Count -eq 1 -and (Test-MRConnectionIdentity $existing[0] $upn $TenantId $false)) {
        $hasTrace = [bool](Get-Command Get-MRDMessageTraceV2 -ErrorAction SilentlyContinue)
        # An older toolkit connection may lack message trace. Reconnect once to add it.
        if ($hasTrace -or $script:MRTraceUnavailable.ContainsKey($traceKey)) {
            foreach ($command in @('Get-MRDMailbox', 'Get-MRDRecipient')) { $null = Get-Command $command -ErrorAction Stop }
            Write-MRLog 'SignIn' @{ Service = 'Exchange Online'; Account = $upn; TenantId = $TenantId; Reused = $true }
            return $existing[0]
        }
    }
    if ($existing.Count) {
        Disconnect-ExchangeOnline -ModulePrefix MRD -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-MRLog 'SignOut' @{ Service = 'Exchange Online'; Reason = 'Different account, tenant, or command set' }
    }
    try {
        Write-MRSignInNotice 'Exchange Online (mailbox list and message trace)'
        Connect-ExchangeOnline -UserPrincipalName $upn -Prefix MRD -ShowBanner:$false `
            -CommandName @('Get-Mailbox', 'Get-Recipient', 'Get-DistributionGroupMember', 'Get-UnifiedGroupLinks', 'Get-MessageTraceV2') -ErrorAction Stop
        $connections = @(Get-MRConnection MRD)
        if ($connections.Count -ne 1 -or -not (Test-MRConnectionIdentity $connections[0] $upn $TenantId $false)) {
            throw 'The Exchange Online connection does not match the expected tenant and administrator.'
        }
        foreach ($command in @('Get-MRDMailbox', 'Get-MRDRecipient')) { $null = Get-Command $command -ErrorAction Stop }
        if (-not (Get-Command Get-MRDMessageTraceV2 -ErrorAction SilentlyContinue)) { $script:MRTraceUnavailable[$traceKey] = $true }
        # A new sign-in may see a different set of mailboxes; reload the list when next needed.
        $script:MRDirectoryCache = $null
        Write-MRLog 'SignIn' @{ Service = 'Exchange Online'; Account = $upn; TenantId = $TenantId; Reused = $false }
        return $connections[0]
    }
    catch {
        Write-MRLog 'SignInFailed' @{ Service = 'Exchange Online'; Account = $upn; TenantId = $TenantId; Message = $_.Exception.Message }
        Disconnect-ExchangeOnline -ModulePrefix MRD -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        throw
    }
}

function Get-MRSignedInAccount {
    # Describes current toolkit connections for the menu without signing in or loading the module.
    if (-not (Get-Module ExchangeOnlineManagement)) { return @() }
    try {
        $accounts = @(foreach ($prefix in @('MR', 'MRD')) {
            foreach ($connection in @(Get-MRConnection $prefix)) { if ($connection.State -eq 'Connected') { [string]$connection.UserPrincipalName } }
        }) | Sort-Object -Unique
        return @($accounts)
    }
    catch { return @() }
}

function Disconnect-MRSession {
    $closed = @(if (Get-Module ExchangeOnlineManagement) { foreach ($prefix in @('MR', 'MRD')) {
        if (@(Get-MRConnection $prefix).Count) {
            Disconnect-ExchangeOnline -ModulePrefix $prefix -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            $prefix
        }
    } })
    $script:MRTraceUnavailable = @{}
    $script:MRDirectoryCache = $null
    Write-MRLog 'SignOut' @{ Connections = $closed; Reason = 'Requested' }
    if ($closed.Count) { Write-Host 'Signed out of Microsoft 365 in this window.' }
    else { Write-Host 'The toolkit was not signed in.' }
}
