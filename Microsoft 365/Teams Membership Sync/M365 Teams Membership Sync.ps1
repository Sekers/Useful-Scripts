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
# 1. Adds and, optionally, removes users to/from Teams & Team Channels based on their M365 or Azure AD group.
# 2. Optionally, logs information, errors, warnings, & debug data.
# 3. Optionally, emails alert messages on errors and/or warnings.

#################
# PREREQUISITES #
#################

# Microsoft.Graph Module (https://www.powershellgallery.com/packages/Microsoft.Graph/).
# PowerShell Framework Module (for better logging - https://psframework.org/).
# Mailozaurr PowerShell Module (https://github.com/EvotecIT/Mailozaurr).

#############
# FUNCTIONS #
#############

# None at this time.

##################################
# SET VARIABLES FROM CONFIG FILE #
##################################

# Import General Configuration Settings.
$config = Get-Content -Path "$PSScriptRoot\Config\config_general.json" | ConvertFrom-Json

# Import Group Mapping.
$GroupTeamMapping = Get-Content -Path "$PSScriptRoot\Config\config_group_team_mapping.json" | ConvertFrom-Json

# Import User Removal Exclusions.
$MemberRemmovalExclusions = Get-Content -Path "$PSScriptRoot\Config\config_remove_account_exclusions.json" | ConvertFrom-Json

# Set General Properties and Verify Type.
[string]$ScriptName = $config.General.ScriptName
[bool]$EmailonError = $config.General.EmailonError
[bool]$EmailonWarning = $config.General.EmailonWarning
[bool]$EnableGroupRecursion = $config.General.EnableGroupRecursion
[bool]$RemoveExtraTeamMembers = $config.General.RemoveExtraTeamMembers
[bool]$RemoveExtraChannelMembers = $config.General.RemoveExtraChannelMembers
[string]$MgProfile = $config.General.MgProfile # 'beta' or 'v1.0'.
[bool]$MgDisconnectWhenDone = $config.General.MgDisconnectWhenDone # Recommended when using the Application permisison type.
[string]$MgPermissionType = $config.General.MgPermissionType # Delegated or Application. See: https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-permissions-and-consent#permission-types and https://docs.microsoft.com/en-us/graph/auth/auth-concepts#delegated-and-application-permissions.

# Configure Logging. See https://psframework.org/documentation/documents/psframework/logging/loggingto/logfile.html.
$paramSetPSFLoggingProvider = @{
    Name             = $config.Logging.Name
    InstanceName     = $config.Logging.InstanceName
    FilePath         = $ExecutionContext.InvokeCommand.ExpandString($config.Logging.FilePath)
    FileType         = $config.Logging.FileType
    LogRotatePath    = $ExecutionContext.InvokeCommand.ExpandString($config.Logging.LogRotatePath)
    LogRetentionTime = $config.Logging.LogRetentionTime
    Enabled          = $config.Logging.Enabled
}

# Configure Email Alerts.
if (-not [string]::IsNullOrEmpty($config.Email.Password))
{
    # Try to decrypt the password in case it's stored as an encrypted standard string.
    try
    {
        $EmailArguments_Password = [System.Net.NetworkCredential]::new("", $($config.Email.Password | ConvertTo-SecureString)).Password # Can only be decrypted by the same AD account on the same computer.
    }
    catch # If it's unable to be decrypted it's probably entered in as plain text.
    {
        $EmailArguments_Password = $config.Email.Password
    }
}
else
{
    $EmailArguments_Password = $null
}
$EmailArguments = @{
    From = $config.Email.From
    ReplyTo = $config.Email.ReplyTo
    To = $config.Email.To
    Username = $config.Email.Username
    Password = $EmailArguments_Password
    Priority = $config.Email.Priority
    Smtpserver = $config.Email.Smtpserver
    UseSsl = $config.Email.UseSsl
    Port = $config.Email.Port
}

#############
# DEBUGGING #
#############

[string]$VerbosePreference = $config.Debugging.VerbosePreference # Use 'Continue' to Enable Verbose Messages and Use 'SilentlyContinue' to reset back to default.
[bool]$LogDebugInfo = $config.Debugging.LogDebugInfo # Writes Extra Information to the log if $true.

##################
# Import Modules #
##################

# Check For Microsoft.Graph Module.
# Don't import the regular 'Microsoft.Graph' module because of some issues with doing it that way.
Import-Module 'Microsoft.Graph.Authentication'
Import-Module 'Microsoft.Graph.Groups'
Import-Module 'Microsoft.Graph.Teams'
Import-Module 'Microsoft.Graph.Users'
if (!(Get-Module -Name "Microsoft.Graph.Groups"))
{
   # Module is not available.
   Write-Error "Please First Install the Microsoft.Graph Module from https://www.powershellgallery.com/packages/Microsoft.Graph/ "
   Return
}

# Check For Mailozaurr PowerShell Module.
if ($EmailonError -or $EmailonWarning)
{
    Import-Module Mailozaurr
    if (!(Get-Module -Name "Mailozaurr"))
    {
       # Module is not loaded.
       Write-Error "Please First Install the Mailozaurr PowerShell Module from https://www.powershellgallery.com/packages/Mailozaurr/ "
       Return
    }
}

# Check For PowerShell Framework Module.
if ($config.Logging.Enabled)
{
    Import-Module PSFramework
    if (!(Get-Module -Name "PSFramework"))
    {
    # Module is not loaded.
    Write-Error "Please First Install the PowerShell Framework Module from https://www.powershellgallery.com/packages/PSFramework/ "
    Return
    }
}

################
# PERFORM WORK #
################

# Stop on Errors.
$ErrorActionPreference = "Stop"

# If Logging is Enabled, Set Logging Data & Log PowerShell & Module Version Information.
if ($config.Logging.Enabled)
{
    Set-PSFLoggingProvider @paramSetPSFLoggingProvider
    Write-PSFMessage -Level Important -Message "---SCRIPT BEGIN---"
    Write-PSFMessage -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString()), $($PSVersionTable.PSEdition.ToString())$(if([Environment]::Is64BitProcess){$(", 64Bit")}else{$(", 32Bit")})"
    foreach ($moduleInfo in Get-Module)
    {
        Write-PSFMessage -Message "$($moduleInfo.Name) Module Version: $($moduleInfo.Version)"
    }
}

try
{
    # Initialize Variables.
    $CustomWarningMessage = $null

    # Connect to Microsoft Graph API.
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
    )
    
    if ($config.Logging.Enabled) {Write-PSFMessage -Message "Microsoft Graph Permission Type: $MgPermissionType"}
    switch ($MgPermissionType)
    {
        Delegated {
            $null = Connect-MgGraph -Scopes $MicrosoftGraphScopes
        }
        Application {
            [string]$MgApp_ClientID = $config.General.MgApp_ClientID
            [string]$MgApp_TenantID = $config.General.MgApp_TenantID
            [string]$MgApp_AuthenticationType = $config.General.MgApp_AuthenticationType
            if ($config.Logging.Enabled) {Write-PSFMessage -Message "Microsoft Graph App Authentication Type: $MgApp_AuthenticationType"}

            switch ($MgApp_AuthenticationType)
            {
                CertificateFile {
                    $MgApp_CertificatePath = $ExecutionContext.InvokeCommand.ExpandString($config.General.MgApp_CertificatePath)

                    # Try accessing private key certificate without password using current process credentials.
                    [X509Certificate]$MgApp_Certificate = $null
                    try
                    {
                        [X509Certificate]$MgApp_Certificate = Get-PfxCertificate -FilePath $MgApp_CertificatePath -NoPromptForPassword
                    }
                    catch # If that doesn't work try the included credentials.
                    {
                        if ([string]::IsNullOrEmpty($config.General.MgApp_EncryptedCertificatePassword))
                        {
                            if ($config.Logging.Enabled) {Write-PSFMessage -Level Error "Cannot access .pfx private key certificate file and no password has been provided."}
                            throw $_
                        }
                        else
                        {
                            [SecureString]$MgApp_EncryptedCertificateSecureString = $config.General.MgApp_EncryptedCertificatePassword | ConvertTo-SecureString # Can only be decrypted by the same AD account on the same computer.
                            [X509Certificate]$MgApp_Certificate = Get-PfxCertificate -FilePath $MgApp_CertificatePath -NoPromptForPassword -Password $MgApp_EncryptedCertificateSecureString
                        }
                    }

                    $null = Connect-MgGraph -TenantId $MgApp_TenantID -ClientId $MgApp_ClientID -Certificate $MgApp_Certificate
                }
                CertificateName {
                    $MgApp_CertificateName = $config.General.MgApp_CertificateName
                    $null = Connect-MgGraph -TenantId $MgApp_TenantID -ClientId $MgApp_ClientID -CertificateName $MgApp_CertificateName
                }
                CertificateThumbprint {
                    $MgApp_CertificateThumbprint = $config.General.MgApp_CertificateThumbprint
                    $null = Connect-MgGraph -TenantId $MgApp_TenantID -ClientId $MgApp_ClientID -CertificateThumbprint $MgApp_CertificateThumbprint
                }
                ClientSecret {
                    $MgApp_Secret = [System.Net.NetworkCredential]::new("", $($config.General.MgApp_EncryptedSecret | ConvertTo-SecureString)).Password # Can only be decrypted by the same AD account on the same computer.
                    $Body =  @{
                        Grant_Type    = "client_credentials"
                        Scope         = "https://graph.microsoft.com/.default"
                        Client_Id     = $MgApp_ClientID
                        Client_Secret = $MgApp_Secret
                    }
                    $Connection = Invoke-RestMethod `
                        -Uri https://login.microsoftonline.com/$MgApp_TenantID/oauth2/v2.0/token `
                        -Method POST `
                        -Body $Body
                    $AccessToken = $Connection.access_token
                    $null = Connect-MgGraph -AccessToken $AccessToken
                }
                Default {throw "Invalid `'MgApp_AuthenticationType`' value in the configuration file."}
            }
        }
        Default {throw "Invalid `'MgPermissionType`' value in the configuration file."}
    }  

    # Set Microsoft.Graph profile to use.
    Select-MgProfile -Name $MgProfile

    # Loop through the Groups mapping array and process TEAMS.
    foreach ($mapping in ($GroupTeamMapping | Where-Object -Property MapType -eq "Team"))
    {
        # Log debug info, if enabled.
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Processing Team Members for Team: $($mapping.M365_Team_DisplayName)"}
        
        # Get group membership.
        # Get recursive/transitive user membership, if enabled. Otherwise, get direct user membership only.
        $Members = [System.Collections.ArrayList]::new()
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
                    [void]$Members.Add($ListItemToAdd)
                }
            }
        }

        [array]$Users = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.user'}
        [array]$Groups = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.group'}
        
        # Get current Team members.
        [array]$CurrentTeamMembers = Get-MgTeamMember -TeamId $mapping.M365_Team_ID -All

        # Log debug info, if enabled.
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Users: $($Users.AdditionalProperties.userPrincipalName -join ', ')"}
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Groups: $($Groups.AdditionalProperties.displayName -join ', ')"}
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Current Team Members (Email): $($CurrentTeamMembers.AdditionalProperties.email -join ', ')"}

        # Add users if there is at least one user from in the groups.
        if ($Users.Count -ge 1)
        {
            # Add Team members by creating values array for the $Parameters hashtable.
            # More info: https://docs.microsoft.com/en-us/graph/api/conversationmembers-add?view=graph-rest-1.0&tabs=powershell
            [array]$values = foreach ($userId in $Users.Id)
            {
                # Only add users if they aren't already members.
                if ($CurrentTeamMembers.AdditionalProperties.userId -notcontains $userId)
                {
                    @{
                        "@odata.type" = "microsoft.graph.aadUserConversationMember"
                        Roles = @(
                        )
                        "User@odata.bind" = "https://graph.microsoft.com/$MgProfile/users('$userId')"
                    }
                }
            }

            # Only try to add if at least one NEW member.
            if ($values.count -ge 1)
            {
                if ($config.Logging.Enabled) {Write-PSFMessage -Message "Adding members for Team: $($mapping.M365_Team_DisplayName)"}
                    $Parameters = @{ }
                    $Parameters.Add('Values',$values)

                    [array]$AddTeamMemberResult = Add-MgTeamMember -TeamId $mapping.M365_Team_ID -BodyParameter $Parameters
                    
                    foreach ($result in $AddTeamMemberResult)
                    {
                        $Member = $Users | Where-Object {$_.Id -EQ $result.AdditionalProperties.userId} | Select-Object -ExpandProperty AdditionalProperties
                        if ($config.Logging.Enabled) {Write-PSFMessage -Message "Added member: $($Member.displayName) {$($result.AdditionalProperties.userId)}"} # Note that it returns a non-terminating "error" message of 'Microsoft.Graph.PowerShell.Models.MicrosoftGraphPublicError' even when it works. Fortunately, it usually does send a terminating error if there really is a problem.
                    }
            }
        }
        else
        {
            if ($config.Logging.Enabled) {Write-PSFMessage -Level Important -Message "No users in group mapping for Team `'$($mapping.M365_Team_DisplayName)`' & group(s): $($mapping.Groups.M365_Group_DisplayName -join ", ")"}
        }

        # Remove Team members, if enabled in config.
        if ($RemoveExtraTeamMembers)
        {
            foreach ($teamMember in $CurrentTeamMembers)
            {
                # Skip excluded accounts indicated by config and skip to the next Team member.
                if ($MemberRemmovalExclusions.Id -contains $teamMember.AdditionalProperties.userId)
                {
                    continue
                }

                if ($Users.Id -notcontains $teamMember.AdditionalProperties.userId)
                {
                    if ($config.Logging.Enabled) {Write-PSFMessage -Message "Removing member from Team `'$($mapping.M365_Team_DisplayName)`': $($teamMember.DisplayName)"}
                    Remove-MgTeamMember -TeamId $mapping.M365_Team_ID -ConversationMemberId $teamMember.Id
                }
            }
        }
    }

    # Loop through the Groups mapping array and process CHANNELS.
    foreach ($mapping in ($GroupTeamMapping | Where-Object -Property MapType -eq "Channel"))
    {
        # Log debug info, if enabled.
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Processing Channel Members for Channel: $($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)"}
        
        # Get group membership.
        # Get recursive/transitive user membership, if enabled. Otherwise, get direct user membership only.
        $Members = [System.Collections.ArrayList]::new()
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
                    [void]$Members.Add($ListItemToAdd)
                }
            }
        }

        [array]$Users = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.user'}
        [array]$Groups = $Members | Where-Object -FilterScript {$_.'AdditionalProperties'.'@odata.type' -EQ '#microsoft.graph.group'}
        
        # Get current Team & Channel members.
        [array]$CurrentTeamMembers = Get-MgTeamMember -TeamId $mapping.M365_Team_ID -All
        [array]$CurrentChannelMembers = Get-MgTeamChannelMember -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -All

        # Log debug info, if enabled.
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Users: $($Users.AdditionalProperties.userPrincipalName -join ', ')"}
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Desired Groups: $($Groups.AdditionalProperties.displayName -join ', ')"}
        if ($config.Logging.Enabled -and $LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Current Channel Members (Email): $($CurrentChannelMembers.AdditionalProperties.email -join ', ')"}

        # Add users if there is at least one user from in the groups.
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
                    if ($config.Logging.Enabled) {Write-PSFMessage -Level Warning "WARNING: Cannot add member `'$($UserInfo.AdditionalProperties.userPrincipalName)`' {$userId} to Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`' because they are not a member of the parent Team."}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot add member `'$($UserInfo.AdditionalProperties.userPrincipalName)`' {$userId} to Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`' because they are not a member of the parent Team."

                    # Skip to the next member.
                    continue
                }

                # Only add users if they aren't already members.
                if ($CurrentChannelMembers.AdditionalProperties.userId -notcontains $userId)
                {
                    @{
                        "@odata.type" = "microsoft.graph.aadUserConversationMember"
                        Roles = @(
                        )
                        "User@odata.bind" = "https://graph.microsoft.com/$MgProfile/users('$userId')"
                    }
                }
            }

            # Only try to add if at least one NEW member.
            if ($values.count -ge 1)
            {
                    # Microsoft has not added in batch adding for channels. It was in the Graph PowerShell module as 'Add-MgTeamChannelMember'
                    # but the API doesn't have the ability so they are updating the PS Graph module to remove it for now.
                    # Issue on GitHub: https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/1494

                    if ($config.Logging.Enabled) {Write-PSFMessage -Message "Adding members for Channel: $($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)"}
                    foreach ($value in $values)
                    {
                        $AddChannelMemberResult = New-MgTeamChannelMember -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -BodyParameter $value
                        if ($config.Logging.Enabled) {Write-PSFMessage -Message "Added member: $($AddChannelMemberResult.DisplayName) {$($AddChannelMemberResult.AdditionalProperties.userId)}"}
                    }
            }
        }
        else
        {
            if ($config.Logging.Enabled) {Write-PSFMessage -Level Important -Message "No users in group mapping for Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`' & group(s): $($mapping.Groups.M365_Group_DisplayName -join ", ")"}
        }

        # Remove Channel members, if enabled in config.
        if ($RemoveExtraChannelMembers)
        {
            foreach ($channelMember in $CurrentChannelMembers)
            {
                # Skip excluded accounts indicated by config and skip to the next Channel member.
                if ($MemberRemmovalExclusions.Id -contains $channelMember.AdditionalProperties.userId)
                {
                    continue
                }

                if ($Users.Id -notcontains $channelMember.AdditionalProperties.userId)
                {
                    if ($config.Logging.Enabled) {Write-PSFMessage -Message "Removing member from Channel `'$($mapping.M365_Team_DisplayName)\$($mapping.M365_Channel_DisplayName)`': $($channelMember.DisplayName)"}
                    Remove-MgTeamChannelMember -TeamId $mapping.M365_Team_ID -ChannelId $mapping.M365_Channel_ID -ConversationMemberId $channelMember.Id
                }
            }
        }
    }

    # Disconnect from Microsoft Graph, if enabled in config.
    if ($MgDisconnectWhenDone)
    {
        $null = Disconnect-MgGraph
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
                    if ($config.Logging.Enabled) {Write-PSFMessage -Level Important -Message "Email Alert (Script Warning): Sent successfully to $($SendEmailMessageResult.SentTo)"}
                }
                else
                {
                    if ($config.Logging.Enabled) {Write-PSFMessage -Level Error -Message "Email Alert (Script Warning): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_}
                }
        }
        catch
        {
            if ($config.Logging.Enabled) {Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_}
        }
    } 

    # End Logging Message.
    if ($config.Logging.Enabled) {Write-PSFMessage -Level Important -Message "---SCRIPT END---"}
}
catch
{
    if ($config.Logging.Enabled) {Write-PSFMessage -Level Error -Message "Error Running Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber))" -Tag 'Failure' -ErrorRecord $_}

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
                if ($config.Logging.Enabled) {Write-PSFMessage -Level Important -Message "Email Alert (Script Error): Sent successfully to $($SendEmailMessageResult.SentTo)"}
            }
            else
            {
                if ($config.Logging.Enabled) {Write-PSFMessage -Level Error -Message "Email Alert (Script Error): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_}
            }   
        }
        catch
        {
            if ($config.Logging.Enabled) {Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_}
        }
    }

    # End Logging Message.
    if ($config.Logging.Enabled) {Write-PSFMessage -Level Important -Message "---SCRIPT END---"}
}