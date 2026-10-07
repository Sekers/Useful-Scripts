# Exchange directory access is optional for All and required for explicit scopes.
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

function Connect-MRDirectory {
    param([string]$UserPrincipalName, [string]$TenantId)
    $upn = Get-MREmail $UserPrincipalName; $expected = [guid]::Parse($TenantId)
    Import-MRExchangeModule
    if (@(Get-ConnectionInformation -ModulePrefix MRD -ErrorAction Stop).Count) { throw 'An MRD directory connection already exists. Use a fresh PowerShell session.' }
    try {
        Write-Host 'The sign-in window may open behind your current app. Check behind it if you do not see the window.' -ForegroundColor Yellow
        Connect-ExchangeOnline -UserPrincipalName $upn -Prefix MRD -ShowBanner:$false `
            -CommandName @('Get-Mailbox', 'Get-Recipient', 'Get-DistributionGroupMember', 'Get-UnifiedGroupLinks') -ErrorAction Stop
        $connections = @(Get-ConnectionInformation -ModulePrefix MRD -ErrorAction Stop)
        if ($connections.Count -ne 1 -or $connections[0].IsEopSession -or $connections[0].State -ne 'Connected' -or
            [guid]$connections[0].TenantID -ne $expected -or $connections[0].UserPrincipalName -ine $upn) {
            throw 'The directory connection does not match the expected tenant and administrator.'
        }
        foreach ($command in @('Get-MRDMailbox', 'Get-MRDRecipient')) { $null = Get-Command $command -ErrorAction Stop }
        return $connections[0]
    }
    catch { Disconnect-ExchangeOnline -ModulePrefix MRD -Confirm:$false -ErrorAction SilentlyContinue | Out-Null; throw }
}

function Get-MRDirectoryData {
    $mailboxes = @(Get-MRDMailbox -ResultSize Unlimited -RecipientTypeDetails @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox') -ErrorAction Stop)
    $groups = @(Get-MRDRecipient -ResultSize Unlimited -RecipientTypeDetails @('MailUniversalDistributionGroup', 'MailUniversalSecurityGroup', 'GroupMailbox') -ErrorAction Stop)
    $mailboxEntries = @(foreach ($mailbox in $mailboxes) {
        $address = Get-MREmail ([string]$mailbox.PrimarySmtpAddress)
        $aliases = @((Get-MRProperty $mailbox 'EmailAddresses') | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^smtp:' } | ForEach-Object { $_.Substring(5).ToLowerInvariant() })
        [pscustomobject]@{ Key = $address; DisplayName = [string]$mailbox.DisplayName; Type = [string]$mailbox.RecipientTypeDetails
            Aliases = $aliases; Label = "$($mailbox.DisplayName) <$address> ($($mailbox.RecipientTypeDetails))"; SearchText = "$($mailbox.DisplayName) $address $($aliases -join ' ')" }
    })
    $mailboxEntries = @($mailboxEntries | Sort-Object DisplayName, Key)
    $groupEntries = @(foreach ($group in $groups) {
        $address = Get-MREmail ([string]$group.PrimarySmtpAddress)
        [pscustomobject]@{ Key = $address; DisplayName = [string]$group.DisplayName; Type = [string]$group.RecipientTypeDetails
            Label = "$($group.DisplayName) <$address> ($($group.RecipientTypeDetails))"; SearchText = "$($group.DisplayName) $address" }
    })
    $groupEntries = @($groupEntries | Sort-Object DisplayName, Key)
    return [pscustomobject]@{ Mailboxes = $mailboxEntries; Groups = $groupEntries }
}

function Resolve-MRGroupMember {
    param($Group, $Directory)
    $queue = [collections.generic.Queue[object]]::new(); $queue.Enqueue($Group)
    $visited = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $addresses = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $excluded = [collections.generic.List[object]]::new()
    $lookup = @{}; $groupLookup = @{}
    foreach ($mailbox in $Directory.Mailboxes) {
        $lookup[$mailbox.Key] = $mailbox.Key
        foreach ($alias in $mailbox.Aliases) { $lookup[$alias] = $mailbox.Key }
    }
    foreach ($entry in $Directory.Groups) { $groupLookup[$entry.Key] = $entry }
    while ($queue.Count) {
        $current = $queue.Dequeue()
        if (-not $visited.Add([string]$current.Key)) { continue }
        if ($current.Type -eq 'GroupMailbox') {
            $members = @(Get-MRDUnifiedGroupLinks -Identity $current.Key -LinkType Members -ResultSize Unlimited -ErrorAction Stop)
        } else {
            $members = @(Get-MRDDistributionGroupMember -Identity $current.Key -ResultSize Unlimited -ErrorAction Stop)
        }
        foreach ($member in $members) {
            $address = Get-MREmail ([string]$member.PrimarySmtpAddress)
            if ($lookup.ContainsKey($address)) { $null = $addresses.Add($lookup[$address]); continue }
            if ($groupLookup.ContainsKey($address)) { $queue.Enqueue($groupLookup[$address]); continue }
            $memberType = [string](Get-MRProperty $member 'RecipientTypeDetails')
            if (-not $memberType) { $memberType = [string](Get-MRProperty $member 'RecipientType') }
            if (-not $memberType) { throw "Group expansion cannot identify the recipient type for '$address'. The scope is incomplete." }
            # An unresolved mailbox or group is not a harmless external contact.
            if ($memberType -match 'Mailbox|Group') { throw "Group expansion cannot resolve '$address' ($memberType). The scope is incomplete. No search was created." }
            $excluded.Add([pscustomobject]@{ Address = $address; Type = $memberType; Reason = 'No supported Exchange Online mailbox in the accessible directory' })
        }
    }
    if (-not $addresses.Count) { throw 'The selected group has no supported Exchange Online member mailboxes.' }
    return [pscustomobject]@{ Mailboxes = @($addresses | Sort-Object); ExpandedGroups = @($visited | Sort-Object); ExcludedMembers = @($excluded.ToArray()) }
}

function Resolve-MRMailboxScope {
    param([hashtable]$Options)
    if ($Options.MailboxMode -eq 'All' -or ($Options.MailboxMode -eq 'Paste' -and $Options.Mailboxes.Count -eq 1 -and $Options.Mailboxes[0] -ieq 'All')) {
        return [pscustomobject]@{ Mailboxes = @('All'); Metadata = [pscustomobject]@{ Mode = 'All' } }
    }
    $connection = $null
    try {
        $connection = Connect-MRDirectory $Options.UserPrincipalName $Options.TenantId
        Write-Host 'Loading mailbox and group directory. This can take a moment.'
        $directory = Get-MRDirectoryData
        $metadata = [ordered]@{ Mode = $Options.MailboxMode; ResolvedUtc = [datetimeoffset]::UtcNow.ToString('o'); ExpandedGroups = @(); ExcludedMembers = @() }
        switch ($Options.MailboxMode) {
            'Select' {
                $selected = @(Select-MRList -Entries $directory.Mailboxes -Title 'Select individual mailboxes' -Multiple)
                $scope = @($selected.Key | Sort-Object -Unique)
            }
            'Group' {
                if ($Options.GroupAddress) {
                    $address = Get-MREmail $Options.GroupAddress
                    $groups = @($directory.Groups | Where-Object Key -EQ $address)
                    if ($groups.Count -ne 1) { throw 'The group address did not resolve to one supported group. Use its primary email address or the group picker.' }
                    $group = $groups[0]
                } else { $group = Select-MRList -Entries $directory.Groups -Title 'Select a distribution, mail-enabled security, or Microsoft 365 group' }
                $resolved = Resolve-MRGroupMember $group $directory
                $scope = @($resolved.Mailboxes)
                $metadata.Group = [pscustomobject]@{ Address = $group.Key; DisplayName = $group.DisplayName; Type = $group.Type }
                $metadata.ExpandedGroups = $resolved.ExpandedGroups; $metadata.ExcludedMembers = $resolved.ExcludedMembers
            }
            'Paste' {
                $addresses = @(Get-MRScope $Options.Mailboxes); $lookup = @{}
                foreach ($mailbox in $directory.Mailboxes) { $lookup[$mailbox.Key] = $mailbox.Key; foreach ($alias in $mailbox.Aliases) { $lookup[$alias] = $mailbox.Key } }
                $scope = @(foreach ($address in $addresses) {
                    if (-not $lookup.ContainsKey($address)) { throw "'$address' is not an accessible individual mailbox. Use Members of a group for group addresses." }
                    $lookup[$address]
                })
                $scope = @($scope | Sort-Object -Unique)
            }
        }
        if (-not $scope.Count) { throw 'Select at least one mailbox.' }
        $metadata.ResolvedMailboxes = $scope
        Write-Host "`nResolved scope: $($scope.Count) individual mailboxes."
        $scope | ForEach-Object { Write-Host "  $_" }
        if ($metadata.ExcludedMembers.Count) {
            Write-Warning "$($metadata.ExcludedMembers.Count) non-mailbox members were excluded."
            $metadata.ExcludedMembers | ForEach-Object { Write-Host "  $($_.Address): $($_.Reason)" }
        }
        if ($Options.Interactive -or $Options.MailboxMode -in @('Select', 'Group')) {
            if ((Read-MRAnswer "Type USE $($scope.Count) to accept this exact mailbox list, or Enter to cancel") -cne "USE $($scope.Count)") { throw [OperationCanceledException]::new('Mailbox selection canceled.') }
        }
        return [pscustomobject]@{ Mailboxes = $scope; Metadata = [pscustomobject]$metadata }
    }
    finally { if ($connection) { Disconnect-ExchangeOnline -ModulePrefix MRD -Confirm:$false -ErrorAction SilentlyContinue | Out-Null } }
}
