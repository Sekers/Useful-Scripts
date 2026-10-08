# Mailbox and group lookups through the shared Exchange Online connection (prefix MRD).
# All-mailbox searches do not need the directory.
$script:MRDirectoryCache = $null

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

function Get-MRDirectory {
    # The list is kept for 15 minutes per tenant and account; a new sign-in clears it.
    param([string]$TenantId, [string]$UserPrincipalName)
    $key = "$TenantId|$UserPrincipalName".ToLowerInvariant()
    $cache = $script:MRDirectoryCache
    if ($cache -and $cache.Key -eq $key -and ([datetime]::UtcNow - $cache.LoadedUtc).TotalMinutes -lt 15) { return $cache.Data }
    Write-Host 'Loading the list of mailboxes and groups. This can take a moment.'
    $data = Get-MRDirectoryData
    $script:MRDirectoryCache = [pscustomobject]@{ Key = $key; LoadedUtc = [datetime]::UtcNow; Data = $data }
    Write-MRLog 'DirectoryLoaded' @{ Mailboxes = @($data.Mailboxes).Count; Groups = @($data.Groups).Count }
    return $data
}

function Get-MRMailboxLookup {
    # Maps every primary address and alias to the mailbox's primary address. Microsoft 365
    # group mailboxes are added only when asked, for matching message trace recipients.
    param($Directory, [switch]$IncludeGroupMailboxes)
    $lookup = @{}
    foreach ($mailbox in @($Directory.Mailboxes)) {
        $lookup[$mailbox.Key] = $mailbox.Key
        foreach ($alias in @($mailbox.Aliases)) { if (-not $lookup.ContainsKey($alias)) { $lookup[$alias] = $mailbox.Key } }
    }
    if ($IncludeGroupMailboxes) {
        foreach ($group in @($Directory.Groups | Where-Object Type -EQ 'GroupMailbox')) { if (-not $lookup.ContainsKey($group.Key)) { $lookup[$group.Key] = $group.Key } }
    }
    return $lookup
}

function Resolve-MRGroupMember {
    param($Group, $Directory)
    $queue = [collections.generic.Queue[object]]::new(); $queue.Enqueue($Group)
    $visited = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $addresses = [collections.generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $excluded = [collections.generic.List[object]]::new()
    $lookup = Get-MRMailboxLookup $Directory; $groupLookup = @{}
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

function Confirm-MRMailboxList {
    param([string[]]$Mailboxes, $Metadata)
    Write-Host "`nThe search will look in these $($Mailboxes.Count) mailbox(es):"
    $Mailboxes | Select-Object -First 25 | ForEach-Object { Write-Host "  $_" }
    if ($Mailboxes.Count -gt 25) { Write-Host "  ...and $($Mailboxes.Count - 25) more. The full list is saved with the run." }
    if (@($Metadata.ExcludedMembers).Count) {
        Write-Warning "$(@($Metadata.ExcludedMembers).Count) group member(s) are not mailboxes here and are left out:"
        $Metadata.ExcludedMembers | ForEach-Object { Write-Host "  $($_.Address) ($($_.Type))" }
    }
    while ($true) {
        $answer = Read-MRAnswer "Press Enter to use these $($Mailboxes.Count) mailbox(es), or B to choose again"
        if (-not $answer.Trim()) { return }
        Write-MRText Retry 'Press Enter to use these mailboxes, or type B to choose different ones.'
    }
}

function Resolve-MRMailboxScope {
    param([hashtable]$Options)
    if ($Options.MailboxMode -eq 'All' -or ($Options.MailboxMode -eq 'Paste' -and @($Options.Mailboxes).Count -eq 1 -and $Options.Mailboxes[0] -ieq 'All')) {
        return [pscustomobject]@{ Mailboxes = @('All'); Metadata = [pscustomobject]@{ Mode = 'All' } }
    }
    $null = Connect-MRExchange $Options.UserPrincipalName $Options.TenantId
    $directory = Get-MRDirectory $Options.TenantId $Options.UserPrincipalName
    $metadata = [ordered]@{ Mode = $Options.MailboxMode; ResolvedUtc = [datetimeoffset]::UtcNow.ToString('o'); ExpandedGroups = @(); ExcludedMembers = @() }
    switch ($Options.MailboxMode) {
        'Select' {
            $selected = @(Select-MRList -Entries $directory.Mailboxes -Title 'Pick the mailboxes to search' -Multiple)
            $scope = @($selected.Key | Sort-Object -Unique)
        }
        'Group' {
            if ($Options.GroupAddress) {
                $address = Get-MREmail $Options.GroupAddress
                $groups = @($directory.Groups | Where-Object Key -EQ $address)
                if ($groups.Count -ne 1) { throw 'The group address did not match one supported group. Use its main email address or pick it from the list.' }
                $group = $groups[0]
            } else { $group = Select-MRList -Entries $directory.Groups -Title 'Pick the group (distribution list, mail-enabled security group, or Microsoft 365 group)' }
            $resolved = Resolve-MRGroupMember $group $directory
            $scope = @($resolved.Mailboxes)
            $metadata.Group = [pscustomobject]@{ Address = $group.Key; DisplayName = $group.DisplayName; Type = $group.Type }
            $metadata.ExpandedGroups = $resolved.ExpandedGroups; $metadata.ExcludedMembers = $resolved.ExcludedMembers
        }
        'Paste' {
            $addresses = @(Get-MRScope $Options.Mailboxes); $lookup = Get-MRMailboxLookup $directory
            $scope = @(foreach ($address in $addresses) {
                if (-not $lookup.ContainsKey($address)) { throw "'$address' is not a mailbox the toolkit can search. For a group address, choose the group option instead." }
                $lookup[$address]
            })
            $scope = @($scope | Sort-Object -Unique)
        }
    }
    if (-not $scope.Count) { throw 'Select at least one mailbox.' }
    $metadata.ResolvedMailboxes = $scope
    Write-MRLog 'MailboxesResolved' @{ Mode = $Options.MailboxMode; Count = $scope.Count; Group = $(if ($metadata.Contains('Group')) { $metadata.Group.Address } else { '' }) }
    if ($Options.Interactive -or $Options.MailboxMode -in @('Select', 'Group')) { Confirm-MRMailboxList $scope ([pscustomobject]$metadata) }
    return [pscustomobject]@{ Mailboxes = $scope; Metadata = [pscustomobject]$metadata }
}
