#######################################################################
# Sync From M365 & Azure AD Groups to M365 Team & Team Channel Groups #
#######################################################################

# This script can be used to dynamically update Team and Team Channel members from Microsoft 365 and Azure AD groups. This is useful if you do not have the
# licensing necessary for dynamic group updates. It also has the added benefit of logging + email alerts and optionally skipping the removing of members
# who no longer are in the mapped group(s), allowing them to remain members of Teams and Channels they have previously been added to.

############
# OVERVIEW #
############

# This Script Does the Following:
# 1. Adds and, optionally, removes users to/from Teams, Team Channels, & M365 Groups based on their M365 or Azure AD group membership.
# 2. Updates member ownership role for current Team & Channel members, if necessary.
# 3. Optionally, logs information, errors, warnings, & debug data.
# 4. Optionally, emails alert messages on errors and/or warnings.

#################
# PREREQUISITES #
#################

# Microsoft.Graph Module (https://learn.microsoft.com/en-us/powershell/microsoftgraph/). Sub-modules needed:
# - Microsoft.Graph.Groups
# - Microsoft.Graph.Teams
# - Microsoft.Graph.Users
# - Microsoft.Graph.Authentication (should automatically install along with any of the other Graph sub-modules as a dependency).
# Exchange Online PowerShell Module (optional; for Exchange Online group support - https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell)
# PowerShell Framework Module (optional; for modern logging - https://psframework.org/).
# Mailozaurr PowerShell Module (optional; for modern email alerts - https://github.com/EvotecIT/Mailozaurr).

#############
# FUNCTIONS #
#############

# None at this time.

##################
# Error Handling #
##################

# Stop on Errors.
$ErrorActionPreference = "Stop"

##################################
# SET VARIABLES FROM CONFIG FILE #
##################################

# Import General Configuration Settings.
$config = Get-Content -Path "$PSScriptRoot\Config\config_general.json" | ConvertFrom-Json

# Import Group Mapping.
$GroupTeamMapping = Get-Content -Path "$PSScriptRoot\Config\config_group_team_mapping.json" | ConvertFrom-Json

# Import User Removal Exclusions.
$MemberRemovalExclusions = Get-Content -Path "$PSScriptRoot\Config\config_remove_account_exclusions.json" | ConvertFrom-Json

# Set General Properties and Verify Type.
[string]$ScriptName = $Config.General.ScriptName
[bool]$EmailonError = $Config.General.EmailonError
[bool]$EmailonWarning = $Config.General.EmailonWarning
[bool]$EnableGroupRecursion = $Config.General.EnableGroupRecursion
[bool]$RemoveExtraTeamMembers = $Config.General.RemoveExtraTeamMembers
[bool]$RemoveExtraChannelMembers = $Config.General.RemoveExtraChannelMembers
[bool]$RemoveExtraGroupMembers = $Config.General.RemoveExtraGroupMembers
[string]$MgProfile = $Config.General.MgProfile # 'v1.0'.
[bool]$MgDisconnectWhenDone = $Config.General.MgDisconnectWhenDone # Recommended when using the Application permission type.
[string]$MgPermissionType = $Config.General.MgPermissionType # Delegated or Application. See: https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-permissions-and-consent#permission-types and https://docs.microsoft.com/en-us/graph/auth/auth-concepts#delegated-and-application-permissions.
[string]$MgClientID = $Config.General.MgClientID
[string]$MgTenantID = $Config.General.MgTenantID
[bool]$SupportExchangeGroups = $Config.General.SupportExchangeGroups
[bool]$EXODisconnectWhenDone = $Config.General.EXODisconnectWhenDone # Recommended when using the Application permission type.
[string]$EXOPermissionType = $Config.General.EXOPermissionType

# Configure Logging. See https://psframework.org/documentation/documents/psframework/logging/loggingto/logfile.html.
$LoggingEnabled = $Config.Logging.Enabled
$paramSetPSFLoggingProvider = @{
    Name             = $Config.Logging.Name
    InstanceName     = $Config.Logging.InstanceName
    FilePath         = $ExecutionContext.InvokeCommand.ExpandString($Config.Logging.FilePath)
    FileType         = $Config.Logging.FileType
    LogRotatePath    = $ExecutionContext.InvokeCommand.ExpandString($Config.Logging.LogRotatePath)
    LogRetentionTime = $Config.Logging.LogRetentionTime
    Wait             = $Config.Logging.Wait
    Enabled          = $Config.Logging.Enabled
}

# Configure Email Alerts.
if (-not [string]::IsNullOrEmpty($Config.Email.Password))
{
    # Try to decrypt the password in case it's stored as an encrypted standard string.
    try
    {
        $EmailArguments_Password = [System.Net.NetworkCredential]::new("", $($Config.Email.Password | ConvertTo-SecureString -ErrorAction Stop)).Password # Can only be decrypted by the same AD account on the same computer.
    }
    catch # If it's unable to be decrypted it's probably entered in as plain text.
    {
        $EmailArguments_Password = $Config.Email.Password
    }
}
else
{
    $EmailArguments_Password = $null
}
$EmailArguments = @{
    From = $Config.Email.From
    ReplyTo = $Config.Email.ReplyTo
    To = $Config.Email.To
    Username = $Config.Email.Username
    Password = $EmailArguments_Password
    Priority = $Config.Email.Priority
    Smtpserver = $Config.Email.Smtpserver
    UseSsl = $Config.Email.UseSsl
    Port = $Config.Email.Port
}

#############
# DEBUGGING #
#############

[System.Management.Automation.ActionPreference]$VerbosePreference = $Config.Debugging.VerbosePreference # Use 'Continue' to Enable Verbose Messages and Use 'SilentlyContinue' to reset back to default.
[bool]$LogDebugInfo = $Config.Debugging.LogDebugInfo # Writes Extra Information to the log if $true.

##################
# Import Modules #
##################

# Check For Microsoft.Graph Module.
# Don't import the entire 'Microsoft.Graph' module because of some issues with doing it that way. Only import the needed modules.
Import-Module 'Microsoft.Graph.Authentication'
Import-Module 'Microsoft.Graph.Groups'
Import-Module 'Microsoft.Graph.Teams'
Import-Module 'Microsoft.Graph.Users'
if (!(Get-Module -Name 'Microsoft.Graph.Groups') -or !(Get-Module -Name 'Microsoft.Graph.Teams') -or !(Get-Module -Name 'Microsoft.Graph.Users'))
{
    # Module is not available.
    Write-Error "Please first install the Microsoft.Graph Groups, Teams & Users sub-modules from https://www.powershellgallery.com/packages/Microsoft.Graph/ "
    Return
}

# Check For Exchange Online PowerShell Module.
if ($SupportExchangeGroups)
{
    Import-Module ExchangeOnlineManagement
    if (!(Get-Module -Name "ExchangeOnlineManagement"))
    {
        # Module is not loaded.
        Write-Error "Please first install the Exchange Online PowerShell module from https://www.powershellgallery.com/packages/ExchangeOnlineManagement/ "
        Return
    }
}

# Check For Mailozaurr PowerShell Module.
if ($EmailonError -or $EmailonWarning)
{
    Import-Module Mailozaurr
    if (!(Get-Module -Name "Mailozaurr"))
    {
       # Module is not loaded.
       Write-Error "Please first install the Mailozaurr PowerShell module from https://www.powershellgallery.com/packages/Mailozaurr/ "
       Return
    }
}

# Check For PowerShell Framework Module.
if ($LoggingEnabled)
{
    Import-Module PSFramework
    if (!(Get-Module -Name "PSFramework"))
    {
    # Module is not loaded.
    Write-Error "Please first install the PowerShell Framework module from https://www.powershellgallery.com/packages/PSFramework/ "
    Return
    }
}

################
# PERFORM WORK #
################

# If Logging is Enabled, Set Logging Data & Log PowerShell & Module Version Information.
if ($LoggingEnabled)
{
    Set-PSFLoggingProvider @paramSetPSFLoggingProvider
    Write-PSFMessage -Level Important -Message "---SCRIPT BEGIN---"
    Write-PSFMessage -Level Verbose -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString()), $($PSVersionTable.PSEdition.ToString())$(if([Environment]::Is64BitProcess){$(", 64Bit")}else{$(", 32Bit")})"
    foreach ($moduleInfo in Get-Module)
    {
        Write-PSFMessage -Level Verbose -Message "$($moduleInfo.Name) Module Version: $($moduleInfo.Version)"
    }
}

try
{
    # Initialize Variables.
    $CustomWarningMessage = $null

    # Connect to the Microsoft Graph API.
    # E.g. Connect-MgGraph -Scopes "User.Read.All","Group.ReadWrite.All"
    # You can add additional permissions by repeating the Connect-MgGraph command with the new permission scopes.
    # View the current scopes under which the PowerShell SDK is (trying to) execute cmdlets: Get-MgContext | select -ExpandProperty Scopes
    # List all the scopes granted on the service principal object (you cn also do it via the Azure AD UI): Get-MgServicePrincipal -Filter "appId eq '14d82eec-204b-4c2f-b7e8-296a70dab67e'" | % { Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $_.Id } | fl
    # Find Graph permission needed. More info on permissions: https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-permissions-and-consent)
    #    E.g., Find-MgGraphPermission -SearchString "Teams" -PermissionType Delegated
    #    E.g., Find-MgGraphPermission -SearchString "Teams" -PermissionType Application
    $MicrosoftGraphScopes = @(
        'User.Read.All'
        'Group.Read.All'
        'TeamMember.ReadWrite.All'
        'ChannelMember.ReadWrite.All'
        'GroupMember.ReadWrite.All'
    )
    
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Connecting to Microsoft Graph With Permission Type: $MgPermissionType"}
    switch ($MgPermissionType)
    {
        Delegated {
            $null = Connect-MgGraph -Scopes $MicrosoftGraphScopes -TenantId $MgTenantID -ClientId $MgClientID
        }
        Application {
            [string]$MgApp_AuthenticationType = $Config.General.MgApp_AuthenticationType
            if ($LoggingEnabled) {Write-PSFMessage -Level Verbose -Message "Microsoft Graph App Authentication Type: $MgApp_AuthenticationType"}

            switch ($MgApp_AuthenticationType)
            {
                CertificateFile {
                    $MgApp_CertificatePath = $ExecutionContext.InvokeCommand.ExpandString($Config.General.MgApp_CertificatePath)

                    # Try accessing private key certificate without password using current process credentials.
                    [X509Certificate]$MgApp_Certificate = $null
                    try
                    {
                        [X509Certificate]$MgApp_Certificate = Get-PfxCertificate -FilePath $MgApp_CertificatePath -NoPromptForPassword
                    }
                    catch # If that doesn't work try the included credentials.
                    {
                        if ([string]::IsNullOrEmpty($Config.General.MgApp_EncryptedCertificatePassword))
                        {
                            if ($LoggingEnabled) {Write-PSFMessage -Level Error "Cannot access .pfx private key certificate file and no password has been provided."}
                            throw $_
                        }
                        else
                        {
                            [SecureString]$MgApp_EncryptedCertificateSecureString = $Config.General.MgApp_EncryptedCertificatePassword | ConvertTo-SecureString # Can only be decrypted by the same AD account on the same computer.
                            [X509Certificate]$MgApp_Certificate = Get-PfxCertificate -FilePath $MgApp_CertificatePath -NoPromptForPassword -Password $MgApp_EncryptedCertificateSecureString
                        }
                    }

                    $null = Connect-MgGraph -TenantId $MgTenantID -ClientId $MgClientID -Certificate $MgApp_Certificate
                }
                CertificateName {
                    $MgApp_CertificateName = $Config.General.MgApp_CertificateName
                    $null = Connect-MgGraph -TenantId $MgTenantID -ClientId $MgClientID -CertificateName $MgApp_CertificateName
                }
                CertificateThumbprint {
                    $MgApp_CertificateThumbprint = $Config.General.MgApp_CertificateThumbprint
                    $null = Connect-MgGraph -TenantId $MgTenantID -ClientId $MgClientID -CertificateThumbprint $MgApp_CertificateThumbprint
                }
                ClientSecret {
                    [System.Version]$GraphAuthVersion = Get-Module -Name 'Microsoft.Graph.Authentication' | Select-Object -ExpandProperty Version
                    if ($GraphAuthVersion -lt [System.Version]'2.0.0')
                    {
                        $MgApp_Secret = [System.Net.NetworkCredential]::new("", $($Config.General.MgApp_EncryptedSecret | ConvertTo-SecureString)).Password # Can only be decrypted by the same AD account on the same computer.
                        $Body =  @{
                            Grant_Type    = "client_credentials"
                            Scope         = "https://graph.microsoft.com/.default"
                            Client_Id     = $MgClientID
                            Client_Secret = $MgApp_Secret
                        }
                        $Connection = Invoke-RestMethod `
                            -Uri https://login.microsoftonline.com/$MgTenantID/oauth2/v2.0/token `
                            -Method POST `
                            -Body $Body
                        $AccessToken = $Connection.access_token | ConvertTo-SecureString -AsPlainText
                        $null = Connect-MgGraph -AccessToken $AccessToken
                    }
                    else # If Graph PowerShell SDK is version 2.0.0 or higher.
                    {
                        $ClientSecretCredential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $MgClientID, $($Config.General.MgApp_EncryptedSecret | ConvertTo-SecureString)
                        $null = Connect-MgGraph -TenantId $MgTenantID -ClientSecretCredential $ClientSecretCredential
                    }
                }
                Default {throw "Invalid `'MgApp_AuthenticationType`' value in the configuration file."}
            }
        }
        Default {throw "Invalid `'MgPermissionType`' value in the configuration file."}
    }

    # Connect to the Exchange Online API, if 'SupportExchangeGroups' is set to true.
    if ($SupportExchangeGroups)
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Connecting to Microsoft Exchange Online With Permission Type: $EXOPermissionType"}
        switch ($EXOPermissionType)
        {
            Delegated { #TODO
                $null = Connect-MgGraph -Scopes $MicrosoftGraphScopes
            }
            Application {
                [string]$EXOApp_Organization = $Config.General.EXOApp_Organization
                [string]$EXOApp_AppID = $Config.General.EXOApp_AppID
                [string]$EXOApp_AuthenticationType = $Config.General.EXOApp_AuthenticationType
                if ($LoggingEnabled) {Write-PSFMessage -Level Verbose -Message "Microsoft Exchange Online App Authentication Type: $EXOApp_AuthenticationType"}

                switch ($EXOApp_AuthenticationType)
                {
                    CertificateFile {#TODO
                        $MgApp_CertificatePath = $ExecutionContext.InvokeCommand.ExpandString($Config.General.MgApp_CertificatePath)

                        # Try accessing private key certificate without password using current process credentials.
                        [X509Certificate]$MgApp_Certificate = $null
                        try
                        {
                            [X509Certificate]$MgApp_Certificate = Get-PfxCertificate -FilePath $MgApp_CertificatePath -NoPromptForPassword
                        }
                        catch # If that doesn't work try the included credentials.
                        {
                            if ([string]::IsNullOrEmpty($Config.General.MgApp_EncryptedCertificatePassword))
                            {
                                if ($LoggingEnabled) {Write-PSFMessage -Level Error "Cannot access .pfx private key certificate file and no password has been provided."}
                                throw $_
                            }
                            else
                            {
                                [SecureString]$MgApp_EncryptedCertificateSecureString = $Config.General.MgApp_EncryptedCertificatePassword | ConvertTo-SecureString # Can only be decrypted by the same AD account on the same computer.
                                [X509Certificate]$MgApp_Certificate = Get-PfxCertificate -FilePath $MgApp_CertificatePath -NoPromptForPassword -Password $MgApp_EncryptedCertificateSecureString
                            }
                        }

                        $null = Connect-MgGraph -TenantId $MgTenantID -ClientId $MgClientID -Certificate $MgApp_Certificate
                    }
                    CertificateName {#TODO
                        $MgApp_CertificateName = $Config.General.MgApp_CertificateName
                        $null = Connect-MgGraph -TenantId $MgTenantID -ClientId $MgClientID -CertificateName $MgApp_CertificateName
                    }
                    CertificateThumbprint {
                        $EXOApp_CertificateThumbprint = $Config.General.EXOApp_CertificateThumbprint
                        $null = Connect-ExchangeOnline -CertificateThumbPrint $EXOApp_CertificateThumbprint -AppID $EXOApp_AppID -Organization $EXOApp_Organization -ShowBanner:$false
                    }
                    ClientSecret {#TODO
                        $MgApp_Secret = [System.Net.NetworkCredential]::new("", $($Config.General.MgApp_EncryptedSecret | ConvertTo-SecureString)).Password # Can only be decrypted by the same AD account on the same computer.
                        $Body =  @{
                            Grant_Type    = "client_credentials"
                            Scope         = "https://graph.microsoft.com/.default"
                            Client_Id     = $MgClientID
                            Client_Secret = $MgApp_Secret
                        }
                        $Connection = Invoke-RestMethod `
                            -Uri https://login.microsoftonline.com/$MgTenantID/oauth2/v2.0/token `
                            -Method POST `
                            -Body $Body
                        $AccessToken = $Connection.access_token
                        $null = Connect-MgGraph -AccessToken $AccessToken
                    }
                    Default {throw "Invalid `'EXOApp_AuthenticationType`' value in the configuration file."}
                }
            }
            Default {throw "Invalid `'EXOPermissionType`' value in the configuration file."}
        }
    }

    ##################
    # PROCESS GROUPS # TODO: For M365 unified groups, code the ability to set ownership role for group members.
    ##################

    # Note: Only Unified (M365) groups and non-mail-enabled security groups can be updated by the Graph API.
    # Mail-enabled security groups and distribution lists are not supported.
    # More information: https://learn.microsoft.com/en-us/graph/api/resources/groups-overview?view=graph-rest-1.0&tabs=http#group-types-in-azure-ad-and-microsoft-graph
    # To allow for mail-enabled security groups and distribution groups, we need to use the Exchange Online Powershell module.

    # Loop through the Groups mapping array and process M365 GROUPS.
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning Processing Groups"}
    foreach ($mapping in ($GroupTeamMapping | Where-Object -Property MapType -eq "Group"))
    {
        # Log group info, if enabled.
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Processing Group Members for Group: $($mapping.M365_Group_DisplayName)"}
        
        # Get group membership.
        # Get recursive/transitive user membership, if enabled. Otherwise, get direct user membership only.
        $Members = [System.Collections.Generic.List[Object]]::new()
        foreach ($mapGroup in $mapping.Groups)
        {        
            if ($EnableGroupRecursion)
            {
                [array]$ListItemsToAdd = Get-MgGroupTransitiveMember -GroupId $mapGroup.M365_Group_ID -All| Select-Object *
            }
            else
            {
                [array]$ListItemsToAdd = Get-MgGroupMember -GroupId $mapGroup.M365_Group_ID -All | Select-Object *
            }

            foreach ($listItemToAdd in $ListItemsToAdd)
            {
                # Add if not already in the list.
                if ($Members.Id -notcontains $listItemToAdd.Id)
                {
                    $Members.Add($ListItemToAdd)
                }
            }
        }

        [array]$Users = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.user'}
        [array]$Groups = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.group'}
        
        # Get current Group members.
        [array]$CurrentGroupMembers = Get-MgGroupMember -GroupId $mapping.M365_Group_ID -All

        # Log debug info, if enabled.
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Users: $($Users.AdditionalProperties.userPrincipalName -join ', ')"}
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Groups: $($Groups.AdditionalProperties.displayName -join ', ')"}
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Current Group Members (Email): $($CurrentGroupMembers.AdditionalProperties.mail -join ', ')"}

        # Get the type of group.
        $GroupInfo = Get-MgGroup -GroupId $mapping.M365_Group_ID

        # Add/Update users if there is at least one user in the mapped groups.
        if ($Users.Count -ge 1)
        {
            if (($GroupInfo.GroupTypes -contains 'Unified') -or ($GroupInfo.SecurityEnabled -eq $true -and $GroupInfo.ProxyAddresses.count -eq 0)) # If M365 group or non-mail-enabled security group. 
            {
                # Add Group members by creating values array for the $Parameters hashtable.
                # More info: https://learn.microsoft.com/en-us/graph/api/group-post-members?view=graph-rest-1.0&tabs=powershell
                
                [array]$NewMembers = foreach ($user in $Users)
                {
                    # Only add users if they aren't already members.
                    if ($CurrentGroupMembers.Id -notcontains $user.Id)
                    {
                        $NewMember = [PSCustomObject]@{
                            DisplayName = $user.AdditionalProperties.displayName
                            UserID      = $user.Id
                            Value       = "https://graph.microsoft.com/$MgProfile/directoryObjects/$($user.Id)"
                        }

                        $NewMember
                    } 
                }

                # Only try to add if at least one NEW member.
                [array]$values = $NewMembers.Value
                if ($values.count -ge 1)
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Adding members for Group: $($mapping.M365_Group_DisplayName)"}

                    try
                    {
                        # Can only batch add a max of 20 users at a time
                        $MaxChunkSize = 20
                        $ChunksOfValues = @()
                        for ($i = 0; $i -lt $values.Count; $i+= $MaxChunkSize)
                        {
                            $ChunksOfValues += ,$values[$i..($i+$MaxChunkSize-1)]
                        }

                        foreach ($chunkOfValues in $ChunksOfValues)
                        {
                            $Parameters = @{ }
                            $Parameters.Add('members@odata.bind',$chunkOfValues)
                            Update-MgGroup -GroupId $mapping.M365_Group_ID -BodyParameter $Parameters
                        }
                    }
                    catch
                    {
                        if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because at least one user in the request is unable to be added. Error Message: $_"}
                        # Set Email Warning Message.
                        $CustomWarningMessage += "`nWARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because at least one user in the request is unable to be added. Error Message: $_"
    
                        # Skip to the next Group:group mapping.
                        continue
                    }
                    
                    foreach ($newMember in $NewMembers)
                    {
                        if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Added member: $($newMember.DisplayName) {$($NewMember.UserID)}"}
                    }
                }
            }
            elseif((-not ($GroupInfo.GroupTypes -contains 'Unified')) -and ($GroupInfo.ProxyAddresses.count -ge 1)) # If mail-enabled security group or distribution group.
            {
                if ($SupportExchangeGroups)
                {
                    # Add the group members.
                    # Note: We can't use the bulk 'Update-DistributionGroupMember' cmdlet because it that will replace the current group members with the collection provided.
                    #       This means we can't prevent removal if 'RemoveExtraGroupMembers' is set, nor have removal exclusions respected.
                    #       Theoretically, we could use that cmdlet if both these were false/empty.
                    #       But since there is a 15 minute REST API timeout, it can cause issues if you have thousands of members so we are doing it one at a time for now, even though it's slower.
                    #       More Info: https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps#:~:text=Cmdlets%20backed%20by%20the%20REST%20API%20have%20a%2015%20minute%20timeout

                    [array]$NewMembers = foreach ($user in $Users)
                    {
                        if ($CurrentGroupMembers.Id -notcontains $user.Id)
                        {
                            $user
                        }
                    }
                    
                    # Only try to add if at least one NEW member.
                    if ($NewMembers.count -ge 1)
                    {
                        # Log the group info, if enabled.
                        if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Adding members for Group: $($mapping.M365_Group_DisplayName)"}
                    
                        foreach ($newMember in $NewMembers)
                        {
                            if ($CurrentGroupMembers.Id -notcontains $newMember.Id)
                            {
                                try
                                {
                                    Add-DistributionGroupMember -Identity $mapping.M365_Group_ID -Member $newMember.Id -BypassSecurityGroupManagerCheck -Confirm:$false
                                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Added member: $($newMember.AdditionalProperties.displayName) {$($newMember.Id)}"}
                                }
                                catch
                                {
                                    if ($_.Exception.ErrorId -eq 'NamedParameterNotFound')
                                    {
                                        throw "App role permissions are not sufficient to manage Exchange distribution groups. Instead of 'Exchange Recipient Administrator' use 'Exchange Administrator' or another role with the necessary privileges."
                                    }
                                    else # Rethrow the original error
                                    {
                                        throw $_
                                    }   
                                }
                            }
                        }
                    }
                }
                else
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because the 'SupportExchangeGroups' configuration setting is not enabled."}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because the 'SupportExchangeGroups' configuration setting is not enabled."

                    # Skip to the next Group:group mapping.
                    continue
                }
            }
            else
            {
                if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because the group type is unknown."}
                # Set Email Warning Message.
                $CustomWarningMessage += "`nWARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because the group type is unknown."

                # Skip to the next Group:group mapping.
                continue
            }
        }
        else
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "No users in group mapping for Group `'$($mapping.M365_Group_DisplayName)`' & group(s): $($mapping.Groups.M365_Group_DisplayName -join ", ")"}
        }

        # Remove Group members, if enabled in config.
        if ($RemoveExtraGroupMembers)
        {
            foreach ($CurrentGroupMember in $CurrentGroupMembers)
            {
                # Skip excluded accounts indicated by config and skip to the next Group member.
                if ($MemberRemovalExclusions.Id -contains $CurrentGroupMember.Id)
                {
                    continue
                }

                if ($Users.Id -notcontains $CurrentGroupMember.Id)
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Removing member from Group `'$($mapping.M365_Group_DisplayName)`': $($CurrentGroupMember.AdditionalProperties.displayName)"}
                    
                    if (($GroupInfo.GroupTypes -contains 'Unified') -or ($GroupInfo.SecurityEnabled -eq $true -and $GroupInfo.ProxyAddresses.count -eq 0)) # If M365 group or non-mail-enabled security group. 
                    {
                        Remove-MgGroupMemberByRef -GroupId $mapping.M365_Group_ID -DirectoryObjectId $CurrentGroupMember.Id
                    }
                    elseif((-not ($GroupInfo.GroupTypes -contains 'Unified')) -and ($GroupInfo.ProxyAddresses.count -ge 1)) # If mail-enabled security group or distribution group.
                    {
                        if ($SupportExchangeGroups)
                        {
                            try
                            {
                                Remove-DistributionGroupMember -Identity $mapping.M365_Group_ID -Member $CurrentGroupMember.Id -BypassSecurityGroupManagerCheck -Confirm:$false
                            }
                            catch
                            {
                                if ($_.Exception.ErrorId -eq 'NamedParameterNotFound')
                                {
                                    throw "App role permissions are not sufficient to manage Exchange distribution groups. Instead of 'Exchange Recipient Administrator' use 'Exchange Administrator' or another role with the necessary privileges."
                                }
                                else # Rethrow the original error
                                {
                                    throw $_
                                }   
                            }
                        }
                        else
                        {
                            if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add members to Group `'$($mapping.M365_Group_DisplayName)`' because the 'SupportExchangeGroups' configuration setting is not enabled."}
                            # Set Email Warning Message.
                            $CustomWarningMessage += "`nWARNING: Cannot remove additional members from Group `'$($mapping.M365_Group_DisplayName)`' because the 'SupportExchangeGroups' configuration setting is not enabled."
        
                            # Skip to the next Group:group mapping.
                            continue
                        }
                    }
                    else
                    {
                        if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot remove additional members from Group `'$($mapping.M365_Group_DisplayName)`' because the group type is unknown."}
                        # Set Email Warning Message.
                        $CustomWarningMessage += "`nWARNING: Cannot remove additional members from Group `'$($mapping.M365_Group_DisplayName)`' because the group type is unknown."
        
                        # Skip to the next member.
                        continue
                    }
                }
            }
        }
    }

    #################
    # PROCESS TEAMS #
    #################

    # Loop through the Groups mapping array and process TEAMS.
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning Processing Teams"}
    foreach ($mapping in ($GroupTeamMapping | Where-Object -Property MapType -eq "Team"))
    {
        # Log debug info, if enabled.
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Processing Team Members for Team: $($mapping.M365_Team_DisplayName)"}
        
        # Get group membership.
        # Get recursive/transitive user membership, if enabled. Otherwise, get direct user membership only.
        $Members = [System.Collections.Generic.List[Object]]::new()
        $MemberRoles = [System.Collections.Generic.List[Object]]::new()
        foreach ($mapGroup in $mapping.Groups)
        {        
            if ($EnableGroupRecursion)
            {
                $ListItemsToAdd = Get-MgGroupTransitiveMember -GroupId $mapGroup.M365_Group_ID -All| Select-Object *
            }
            else
            {
                $ListItemsToAdd = Get-MgGroupMember -GroupId $mapGroup.M365_Group_ID -All | Select-Object *
            }

            foreach ($listItemToAdd in $ListItemsToAdd)
            {
                # Add if not already in the list.
                if ($Members.Id -notcontains $listItemToAdd.Id)
                {
                    $Members.Add($ListItemToAdd)

                    $MemberRole = New-Object System.Object
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "TeamDisplayName" -Value $mapping.M365_Team_DisplayName
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "TeamID" -Value $mapping.M365_Team_ID
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "MemberID" -Value $ListItemToAdd.Id
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "MemberDisplayName" -Value $ListItemToAdd.AdditionalProperties.displayName
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "Role" -Value $mapGroup.Role
                    $MemberRoles.Add($MemberRole)
                }
            }
        }

        [array]$Users = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.user'}
        [array]$Groups = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.group'}
        
        # Get current Team members.
        [array]$CurrentTeamMembers = Get-MgTeamMember -TeamId $mapping.M365_Team_ID -All

        # Log debug info, if enabled.
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Users: $($Users.AdditionalProperties.userPrincipalName -join ', ')"}
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Groups: $($Groups.AdditionalProperties.displayName -join ', ')"}
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Current Team Members (Email): $($CurrentTeamMembers.AdditionalProperties.email -join ', ')"}

        # Add users if there is at least one user in the mapped groups.
        if ($Users.Count -ge 1)
        {
            # Add Team members by first creating values array for the $Parameters hashtable.
            # More info: https://docs.microsoft.com/en-us/graph/api/conversationmembers-add?view=graph-rest-1.0&tabs=powershell
            [array]$values = foreach ($userId in $Users.Id)
            {
                # Only add users if they aren't already members.
                if ($CurrentTeamMembers.AdditionalProperties.userId -notcontains $userId)
                {
                    # Check if member is to be an Owner of the Team. If an Owner, they will be in BOTH the Owners & Members list.
                    $MemberMappedRoles = $MemberRoles | Where-Object -Property MemberID -EQ $userId
                    $MemberShouldBeOwner = if ($($MemberMappedRoles).Role -eq 'Owner') {$true} else {$false}
                    if ($MemberShouldBeOwner)
                    {
                        @{
                            "@odata.type"     = "microsoft.graph.aadUserConversationMember"
                            Roles             = @('owner')
                            "User@odata.bind" = "https://graph.microsoft.com/$MgProfile/users('$userId')"
                        }
                    }
                    else
                    {
                        @{
                            "@odata.type"     = "microsoft.graph.aadUserConversationMember"
                            Roles             = @()
                            "User@odata.bind" = "https://graph.microsoft.com/$MgProfile/users('$userId')"
                        }
                    }
                }
            }

            # Only try to add if at least one NEW member.
            if ($values.count -ge 1)
            {
                if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Adding members for Team: $($mapping.M365_Team_DisplayName)"}
                $Parameters = @{ }
                $Parameters.Add('Values',$values)

                try
                {
                    [array]$AddTeamMemberResult = Add-MgTeamMember -TeamId $mapping.M365_Team_ID -BodyParameter $Parameters
                }
                catch
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add members to Team `'$($mapping.M365_Team_DisplayName)`' because at least one user in the request is unable to be added (disabled account, etc.). Error Message: $_"}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot add members to Team `'$($mapping.M365_Team_DisplayName)`' because at least one user in the request is unable to be added (disabled account, etc.). Error Message: $_"

                    # Skip to the next Team group mapping.
                    continue
                }
                
                foreach ($result in $AddTeamMemberResult)
                {
                    $Member = $Users | Where-Object {$_.Id -EQ $result.AdditionalProperties.userId} | Select-Object -ExpandProperty AdditionalProperties
                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Added member: $($Member.displayName) {$($result.AdditionalProperties.userId)}"} # Note that it returns a non-terminating "error" message of 'Microsoft.Graph.PowerShell.Models.MicrosoftGraphPublicError' even when it works. Fortunately, it usually does send a terminating error if there really is a problem.
                }
            }               
        }
        else
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "No users in group mapping for Team `'$($mapping.M365_Team_DisplayName)`' & group(s): $($mapping.Groups.M365_Group_DisplayName -join ", ")"}
        }

        # Update Existing Team Members
        # Remove Team members, if enabled in config.
        # Also Add/Remove Team member Owner role, if needed.
        # Note: This property contains additional qualifiers only when relevant - for example, if the member has owner privileges, the roles property contains owner as one of the values.
        #       Similarly, if the member is an in-tenant guest, the roles property contains guest as one of the values.
        #       A basic member should not have any values specified in the roles property. An Out-of-tenant external member is assigned the owner role.
        #       More info > https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.teams/update-mgteammember

        foreach ($currentTeamMember in $CurrentTeamMembers)
        {
            # Skip excluded accounts indicated by config.
            if ($MemberRemovalExclusions.Id -contains $currentTeamMember.AdditionalProperties.userId)
            {
                continue
            }
            
            # Remove Extra Team Members.
            if ($RemoveExtraTeamMembers)
            {
                if (($Users.Id -notcontains $currentTeamMember.AdditionalProperties.userId))
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Removing member from Team `'$($mapping.M365_Team_DisplayName)`': $($currentTeamMember.DisplayName)"}
                    Remove-MgTeamMember -TeamId $mapping.M365_Team_ID -ConversationMemberId $currentTeamMember.Id

                    # Go to next member because no need to update ownership.
                    continue
                }
            }

            $MemberIsCurrentOwner = if ($($currentTeamMember).Roles -contains 'owner') {$true} else {$false}
            $MemberMappedRoles = $MemberRoles | Where-Object -Property MemberID -EQ $($currentTeamMember.AdditionalProperties.userId)
            $MemberShouldBeOwner = if ($($MemberMappedRoles).Role -eq 'Owner') {$true} else {$false}

            # Remove Owner role, if necessary
            if (($MemberIsCurrentOwner) -and (-not $MemberShouldBeOwner))
            {
                [array]$NewRolesValue = foreach ($currentMemberRole in $currentTeamMember.Roles)
                {
                    if ($currentMemberRole -ne 'owner')
                    {
                        $currentMemberRole
                    }
                }

                $Parameters = @{
                    "@odata.type" = "#microsoft.graph.aadUserConversationMember"
                    roles         = @(
                        $NewRolesValue
                    )
                }

                if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Removing ownership role for Team '$($mapping.M365_Team_DisplayName)' member: $($currentTeamMember.AdditionalProperties.email)"}
                $UpdateTeamMemberResult = Update-MgTeamMember -ConversationMemberId $currentTeamMember.Id -TeamId $mapping.M365_Team_ID -BodyParameter $Parameters
            }

            # Add Owner role, if necessary
            if ((-not $MemberIsCurrentOwner) -and ($MemberShouldBeOwner))
            {
                [array]$NewRolesValue = $currentTeamMember.Roles + 'owner'

                $Parameters = @{
                    "@odata.type" = "#microsoft.graph.aadUserConversationMember"
                    roles         = @(
                        $NewRolesValue
                    )
                }
                
                if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Adding ownership role for Team '$($mapping.M365_Team_DisplayName)' member: $($currentTeamMember.AdditionalProperties.email)"}
                $UpdateTeamMemberResult = Update-MgTeamMember -ConversationMemberId $currentTeamMember.Id -TeamId $mapping.M365_Team_ID -BodyParameter $Parameters
            }

        }
    }

    ####################
    # PROCESS CHANNELS #
    ####################

    # Loop through the Groups mapping array and process CHANNELS.
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning Processing Channels"}
    foreach ($mapping in ($GroupTeamMapping | Where-Object -Property MapType -eq "Channel"))
    {
        # Log debug info, if enabled.
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Processing Channel Members for Channel: $($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)"}
        
        # Get group membership.
        # Get recursive/transitive user membership, if enabled. Otherwise, get direct user membership only.
        $Members = [System.Collections.Generic.List[Object]]::new()
        $MemberRoles = [System.Collections.Generic.List[Object]]::new()
        foreach ($mapGroup in $mapping.Groups)
        {
            if ($EnableGroupRecursion)
            {
                $ListItemsToAdd = Get-MgGroupTransitiveMember -GroupId $mapGroup.M365_Group_ID -All | Select-Object *
            }
            else
            {
                $ListItemsToAdd = Get-MgGroupMember -GroupId $mapGroup.M365_Group_ID -All | Select-Object *
            }

            foreach ($listItemToAdd in $ListItemsToAdd)
            {
                # Add if not already in the list.
                if ($Members.Id -notcontains $listItemToAdd.Id)
                {
                    $Members.Add($ListItemToAdd)

                    $MemberRole = New-Object System.Object
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "TeamDisplayName" -Value $mapping.M365_Team_DisplayName
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "TeamID" -Value $mapping.M365_Team_ID
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "ChannelDisplayName" -Value $mapping.M365_Channel_DisplayName
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "ChannelID" -Value $mapping.M365_Channel_ID
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "MemberID" -Value $ListItemToAdd.Id
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "MemberDisplayName" -Value $ListItemToAdd.AdditionalProperties.displayName
                    $MemberRole | Add-Member -MemberType NoteProperty -Name "Role" -Value $mapGroup.Role
                    $MemberRoles.Add($MemberRole)
                }
            }
        }

        [array]$Users = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.user'}
        [array]$Groups = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.group'}
        
        # Get current Team & Channel members.
        [array]$CurrentTeamMembers = Get-MgTeamMember -TeamId $mapping.M365_Team_ID -All
        [array]$CurrentChannelMembers = Get-MgTeamChannelMember -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -All

        # Log debug info, if enabled.
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Users: $($Users.AdditionalProperties.userPrincipalName -join ', ')"}
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Groups: $($Groups.AdditionalProperties.displayName -join ', ')"}
        if ($LoggingEnabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Current Channel Members (Email): $($CurrentChannelMembers.AdditionalProperties.email -join ', ')"}

        # Add users if there is at least one user in the mapped groups.
        if ($Users.Count -ge 1)
        {
            # Add Channel members by creating values array for the $Parameters hashtable.
            # More info: https://docs.microsoft.com/en-us/graph/api/conversationmembers-add?view=graph-rest-1.0&tabs=powershell
            [array]$values = foreach ($userId in $Users.Id)
            {
                # Check if the user is a member of the TEAM the CHANNEL belongs to.
                if ($CurrentTeamMembers.AdditionalProperties.userId -notcontains $userId)
                {
                    $UserInfo = $Users | Where-Object -Property Id -EQ $userId #| Select-Object -ExpandProperty AdditionalProperties.userPrincipalName
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add member `'$($UserInfo.AdditionalProperties.userPrincipalName)`' {$userId} to Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`' because they are not a member of the parent Team."}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot add member `'$($UserInfo.AdditionalProperties.userPrincipalName)`' {$userId} to Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`' because they are not a member of the parent Team."

                    # Skip to the next member.
                    continue
                }

                # Only add users if they aren't already members.
                if ($CurrentChannelMembers.AdditionalProperties.userId -notcontains $userId)
                {
                    # Check if member is to be an Owner of the Channel. If an Owner, they will be in BOTH the Owners & Members list.
                    $MemberMappedRoles = $MemberRoles | Where-Object -Property MemberID -EQ $userId
                    $MemberShouldBeOwner = if ($($MemberMappedRoles).Role -eq 'Owner') {$true} else {$false}


                    if ($MemberShouldBeOwner)
                    {
                        @{
                            "@odata.type"     = "microsoft.graph.aadUserConversationMember"
                            Roles             = @('owner')
                            "User@odata.bind" = "https://graph.microsoft.com/$MgProfile/users('$userId')"
                        }
                    }
                    else
                    {
                        @{
                            "@odata.type"     = "microsoft.graph.aadUserConversationMember"
                            Roles             = @()
                            "User@odata.bind" = "https://graph.microsoft.com/$MgProfile/users('$userId')"
                        }
                    }
                }
            }

            # Only try to add if at least one NEW member.
            if ($values.count -ge 1)
            {
                    # Microsoft has not added in batch adding for channels. It was in the Graph PowerShell module as 'Add-MgTeamChannelMember'
                    # but the API doesn't have the ability so they are updating the PS Graph module to remove it for now.
                    # Issue on GitHub: https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/1494

                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Adding members for Channel: $($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)"}
                    foreach ($value in $values)
                    {
                        $AddChannelMemberResult = New-MgTeamChannelMember -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -BodyParameter $value
                        if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Added member: $($AddChannelMemberResult.DisplayName) {$($AddChannelMemberResult.AdditionalProperties.userId)}"}
                    }
            }
        }
        else
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "No users in group mapping for Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`' & group(s): $($mapping.Groups.M365_Group_DisplayName -join ", ")"}
        }

        # Update Existing Channel Members
        # Remove Channel members, if enabled in config.
        # Also Add/Remove Channel member Owner role, if needed.
        # Note: This property contains additional qualifiers only when relevant - for example, if the member has owner privileges, the roles property contains owner as one of the values.
        #       Similarly, if the member is an in-tenant guest, the roles property contains guest as one of the values.
        #       A basic member should not have any values specified in the roles property. An Out-of-tenant external member is assigned the owner role.
        #       More info > https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.teams/update-mgteamchannelmember
        foreach ($currentChannelMember in $CurrentChannelMembers)
        {
            # Skip excluded accounts indicated by config.
            if ($MemberRemovalExclusions.Id -contains $currentChannelMember.AdditionalProperties.userId)
            {
                continue
            }
                            
            if ($RemoveExtraChannelMembers)
            {
                if ($Users.Id -notcontains $currentChannelMember.AdditionalProperties.userId)
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Removing member from Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`': $($currentChannelMember.DisplayName)"}
                    Remove-MgTeamChannelMember -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -ConversationMemberId $currentChannelMember.Id

                    # Go to next member because no need to update ownership.
                    continue
                }
            }

            $MemberIsCurrentOwner = if ($($currentChannelMember).Roles -contains 'owner') {$true} else {$false}
            $MemberMappedRoles = $MemberRoles | Where-Object -Property MemberID -EQ $($currentChannelMember.AdditionalProperties.userId)
            $MemberShouldBeOwner = if ($($MemberMappedRoles).Role -eq 'Owner') {$true} else {$false}

            # Remove Owner role, if necessary
            if (($MemberIsCurrentOwner) -and (-not $MemberShouldBeOwner))
            {
                [array]$NewRolesValue = foreach ($currentMemberRole in $currentChannelMember.Roles)
                {
                    if ($currentMemberRole -ne 'owner')
                    {
                        $currentMemberRole
                    }
                }

                $Parameters = @{
                    "@odata.type" = "#microsoft.graph.aadUserConversationMember"
                    roles         = @(
                        $NewRolesValue
                    )
                }

                if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Removing ownership role for Channel '$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)' member: $($currentChannelMember.AdditionalProperties.email)"}
                $UpdateChannelMemberResult = Update-MgTeamChannelMember -ConversationMemberId $currentChannelMember.Id -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -BodyParameter $Parameters
            }

            # Add Owner role, if necessary
            if ((-not $MemberIsCurrentOwner) -and ($MemberShouldBeOwner))
            {
                [array]$NewRolesValue = $currentChannelMember.Roles + 'owner'

                $Parameters = @{
                    "@odata.type" = "#microsoft.graph.aadUserConversationMember"
                    roles         = @(
                        $NewRolesValue
                    )
                }
                
                if ($LoggingEnabled) {Write-PSFMessage -Level Significant -Message "Adding ownership role for Channel '$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)' member: $($currentChannelMember.AdditionalProperties.email)"}
                $UpdateChannelMemberResult = Update-MgTeamChannelMember -ConversationMemberId $currentChannelMember.Id -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -BodyParameter $Parameters
            }
        }
    }

    # Disconnect from Microsoft Graph API, if enabled in config.
    if ($MgDisconnectWhenDone)
    {
        $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
    }

    # Disconnect from Exchange Online API, if enabled in config.
    if ($SupportExchangeGroups -and $EXODisconnectWhenDone)
    {
        $null = Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Email Warning Message, if Enabled.
    If ($EmailonWarning -and $null -ne $CustomWarningMessage)
    {
        # Get Rid of Extra Line at Beginning.
        $CustomWarningMessage = $CustomWarningMessage.Trim()

        # Try to Email Alert Message On Warning.
        try
        {
                # Add More Email Attributes.
                $EmailArguments.Subject = "$ScriptName Script - Warning"
                $EmailArguments.Text = "The $ScriptName script has detected at least one non-critical issue:`n`n$CustomWarningMessage`n`nThank you,`nThe IT Team"
                $EmailArguments.Attachment = $null # No attachments because we don't want anything to accidentally prevent the alert email from being sent.

                # Send Warning Message Alert.
                $SendEmailMessageResult = Send-EmailMessage @EmailArguments
                if ($null -eq $SendEmailMessageResult.Error -or $SendEmailMessageResult.Error -eq "")
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Email Alert (Script Warning): Sent successfully to $($SendEmailMessageResult.SentTo)"}
                }
                else
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "Email Alert (Script Warning): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_}
                }
        }
        catch
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_}
        }
    } 

    # End Logging Message.
    if ($LoggingEnabled)
    {
        Write-PSFMessage -Level Important -Message "---SCRIPT END---"
        Wait-PSFMessage # Make Sure Logging Is Flushed Before Terminating
    }
}
catch
{
    # Log Error Message.
    if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "Error Running Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber))" -Tag 'Failure' -ErrorRecord $_}

    # Disconnect from Microsoft Graph API, if enabled in config.
    if ($MgDisconnectWhenDone)
    {
        $null = Disconnect-MgGraph -ErrorAction SilentlyContinue
    }

    # Disconnect from Exchange Online API, if enabled in config.
    if ($SupportExchangeGroups -and $EXODisconnectWhenDone)
    {
        $null = Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }

    # Try to Email Alert Message On Error.
    if ($EmailonError)
    {
        try
        {
            # Add More Email Attributes.
            $EmailArguments.Subject = "$ScriptName Script - Error"
            $EmailArguments.Text = "There has been an error running the $ScriptName Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber)):`n`n$_`n`nThank you,`nThe IT Team"
            $EmailArguments.Attachment = $null # No attachments because we don't want anything to accidentally prevent the alert email from being sent.

            # Send Error Message Alert.
            $SendEmailMessageResult = Send-EmailMessage @EmailArguments
            if ($null -eq $SendEmailMessageResult.Error -or $SendEmailMessageResult.Error -eq "")
            {
                if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Email Alert (Script Error): Sent successfully to $($SendEmailMessageResult.SentTo)"}
            }
            else
            {
                if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "Email Alert (Script Error): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_}
            }   
        }
        catch
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_}
        }
    }

    # End Logging Message.
    if ($LoggingEnabled)
    {
        Write-PSFMessage -Level Important -Message "---SCRIPT END---"
        Wait-PSFMessage # Make Sure Logging Is Flushed Before Terminating
    }
}