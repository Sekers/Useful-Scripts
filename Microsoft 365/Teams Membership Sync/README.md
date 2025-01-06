# M365 Teams Membership Sync

## Overview

A PowerShell script that syncs members of Microsoft 365 and Azure AD groups to M365 Team & Team Channel groups. This script can be used to dynamically update Team and Team Channel members from groups. This is useful if you do not have the licensing necessary for [dynamic membership rules for Azure AD groups](https://learn.microsoft.com/en-us/azure/active-directory/enterprise-users/groups-dynamic-membership). It also has the added benefit of logging + email alerts and optionally skipping the removing of members who no longer are in the mapped group(s), allowing them to remain members of Teams and Channels they have previously been added to.

---

## Features

- Adds mapped group members to Teams and Channels (Private Channels only).
- Optionally removes members who no longer are mapped to a Team or Channel (allows for user exceptions if enabled).
- Optionally allows for group recursion/nesting.
- Written to take advantage of the latest Microsoft Microsoft Graph API PowerShell module.
- Easily update settings using JSON config files.
- Authentication options:
    - Delegated Permissions (run using a signed-in user).
    - Application Permissions (application consented by an administrator and authenticated by certificate or secret).
- Optional non-blocking logging & email alerting (see prerequisite modules).
- Debugging options.

---

## PREREQUISITES 

- [Microsoft.Graph Module:](https://github.com/microsoftgraph/msgraph-sdk-powershell) Microsoft's Graph API PowerShell module. Required by the script.
- [PowerShell Framework Module:](https://psframework.org/) For modern logging. Optional and only needed if using the logging functionality.
- [Mailozaurr PowerShell Module:](https://github.com/EvotecIT/Mailozaurr) For modern email alerts. Optional and only needed if using the email alerting functionality.

---

## JSON Configuration Files Information

Make copies of the sample configuration files in the 'Config Templates' folder and place them into the 'Config' folder. Update these configuration settings using the documentation below.

---

### **config_general.json**

JSON file that contains the primary configuration settings for the script.

General
- **ScriptName (String):** Name of script for email alerts and logging.
- **EmailonError (Boolean):** Whether to use the email functionality to email an alert on script-stopping errors.
- **EmailonWarning (Boolean):** Whether to use the email functionality to email an alert on non-critical warnings.
- **EnableGroupRecursion (Boolean):** Enable group recursion to allow user lookups within nested groups. Otherwise, the script will use direct group members only.
- **RemoveExtraTeamMembers (Boolean):** Removes Team members who are no longer in any mapped groups for that Team.
- **RemoveExtraChannelMembers (Boolean):** Removes Channel members who are no longer in any mapped groups for that Channel.
- **MgProfile (String):** Specifies the Microsoft Graph API profile version. Use 'v1.0', etc.
- **MgPermissionType (String):** Set the [type of permission](https://learn.microsoft.com/en-us/graph/auth/auth-concepts#delegated-and-application-permissions) you want to use to access the Microsoft Graph API.
    - **Delegated:** The delegated option will cause the script to prompt for a user to sign in. In this case, either the user or an administrator would consent to the permissions needed for the script to access the necessary permission scopes. If you disconnect from the Graph API or if the [tokens expire](https://learn.microsoft.com/nb-no/azure/active-directory/develop/active-directory-configurable-token-lifetimes), you will need to reauthenticate. Scopes needed by this script for delegated permissions are:

        | Delegated Permission | Display String | Admin Consent Required |
        | ---------- | -------------- | ---------------------- |
        | [User.Read.All](https://learn.microsoft.com/en-us/graph/permissions-reference#delegated-permissions-82) | Read all users' full profiles. | Yes |
        | [Group.Read.All](https://learn.microsoft.com/en-us/graph/permissions-reference#delegated-permissions-32) | Read all groups. | Yes |
        | [TeamMember.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#delegated-permissions-74) | Add and remove members from teams. | Yes |
        | [ChannelMember.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#delegated-permissions-12) | Add and remove members from all channels. | Yes |
    
    - **Application:** This is the preferred option when you want the script to run or be automated without a signed-in user present. For example, apps that run as background services or daemons. Application permissions can only be [consented by an administrator](https://learn.microsoft.com/en-us/azure/active-directory/develop/active-directory-v2-scopes#requesting-consent-for-an-entire-tenant). You will need to [register the script as an app](https://learn.microsoft.com/en-us/graph/auth-v2-service#1-register-your-app) and then [grant admin consent for the necessary scopes](https://learn.microsoft.com/en-us/graph/auth-v2-service#2-configure-permissions-for-microsoft-graph):

        | Application Permission | Display String | Admin Consent Required |
        | ---------- | -------------- | ---------------------- |
        | [User.Read.All](https://learn.microsoft.com/en-us/graph/permissions-reference#application-permissions-78) | Read all users' full profiles. | Yes |
        | [Group.Read.All](https://learn.microsoft.com/en-us/graph/permissions-reference#application-permissions-31) | Read all groups. | Yes |
        | [TeamMember.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#application-permissions-70) | Add and remove members from teams. | Yes |
        | [ChannelMember.ReadWrite.All](https://learn.microsoft.com/en-us/graph/permissions-reference#application-permissions-12) | Add and remove members from all channels. | Yes |
    
- **MgDisconnectWhenDone (Boolean):** Specifies whether to disconnect from the Graph API when the script finishes.
- **MgClientID (String):** This is where you would enter the [registered application ID value](https://learn.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal#get-tenant-and-app-id-values-for-signing-in). If 'MgPermissionType' is set to 'Delegated', make sure to add a redirect URI of 'http://localhost'.
- **MgTenantID (String):** This is where you would enter the [registered tenant ID value](https://learn.microsoft.com/en-us/azure/active-directory/develop/howto-create-service-principal-portal#get-tenant-and-app-id-values-for-signing-in). If 'MgPermissionType' is set to 'Delegated', make sure to add a redirect URI of 'http://localhost'.
- **MgApp_AuthenticationType (String):** Only used when 'MgPermissionType' is set to 'Application'. Authentication options include:
    - **CertificateFile:** Tells the script that you will specify a path to a certificate with a private key. The paired public certificate (without a private key) should be [added to the registered Azure app registration](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app#add-a-certificate). For testing, you can [create a self-signed public certificate](https://learn.microsoft.com/en-us/azure/active-directory/develop/howto-create-self-signed-certificate) instead of using a Certificate Authority (CA)-signed certificate.
    - **CertificateName:** Tells the script that you will specify the Common Name (e.g. 'CN=My Test Certificate Name') of a certificate with a private key. This certificate should be in the current user certificate store of the account that the script runs under. The paired public certificate (without a private key) should be [added to the registered Azure app registration](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app#add-a-certificate). For testing, you can [create a self-signed public certificate](https://learn.microsoft.com/en-us/azure/active-directory/develop/howto-create-self-signed-certificate) instead of using a Certificate Authority (CA)-signed certificate.
    - **CertificateThumbprint:** Tells the script that you will specify the thumbprint of a certificate with a private key.  This certificate should be in the current user certificate store of the account that the script runs under. The paired public certificate (without a private key) should be [added to the registered Azure app registration](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app#add-a-certificate). For testing, you can [create a self-signed public certificate](https://learn.microsoft.com/en-us/azure/active-directory/develop/howto-create-self-signed-certificate) instead of using a Certificate Authority (CA)-signed certificate.
    - **ClientSecret:** Tells the script that you will specify a client secret, sometimes called an *application password*. Client secrets are considered less secure than certificate credentials. Application developers sometimes use client secrets during local app development because of their ease of use. However, you should use certificate credentials for any of your applications that are running in production. You can [add a client secret for the registered application](https://learn.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app#add-a-client-secret) from the Azure portal. Client secret expiration is now limited to a maximum of [two years](https://devblogs.microsoft.com/microsoft365dev/client-secret-expiration-now-limited-to-a-maximum-of-two-years/).
- **MgApp_CertificatePath (String):** Only used when 'MgPermissionType' is set to 'Application' and 'MgApp_AuthenticationType' is set to 'CertificateFile'. Enter the path where the private key certificate file is located. You can include PowerShell code and variables (e.g., "PSScriptRoot\\\\Config\\\\PrivateKeyCertificate.pfx"). Don't forget to [double up on the backslash in paths](https://www.freeformatter.com/json-escape.html) to escape it.
- **MgApp_CertificateName (String):** Only used when 'MgPermissionType' is set to 'Application' and 'MgApp_AuthenticationType' is set to 'CertificateName'. Enter the Common Name of the private key certificate. E.g., "CN=My Test Certificate Name".
- **MgApp_CertificateThumbprint (String):** Only used when 'MgPermissionType' is set to 'Application' and 'MgApp_AuthenticationType' is set to 'CertificateThumbprint'. Enter the private key certificate's thumbprint.
- **MgApp_EncryptedCertificatePassword (Encrypted Standard String):** Optionally used when 'MgPermissionType' is set to 'Application' and 'MgApp_AuthenticationType' is set to 'CertificateFile'. If the account the process runs under cannot decrypt the private key certificate file, the script will attempt to do so using this password. Enter the encrypted standard string of the password into this field. An encrypted standard string can be converted back to its secure string format but **only by the same account on the same computer it was encrypted from**. You can use the [New-EncryptedPassword script](https://github.com/Sekers/Useful-Scripts/tree/main/Password%20Tools/New-EncryptedPassword) to easily convert a password to an encrypted standard string.
- **MgApp_EncryptedSecret (Encrypted Standard String):** Only used when 'MgPermissionType' is set to 'Application' and 'MgApp_AuthenticationType' is set to 'ClientSecret'. Enter the encrypted standard string of the password into this field. An encrypted standard string can be converted back to its secure string format but **only by the same account on the same computer it was encrypted from**. You can use the [New-EncryptedPassword script](https://github.com/Sekers/Useful-Scripts/tree/main/Password%20Tools/New-EncryptedPassword) to easily convert a password to an encrypted standard string.

Logging
- Optionally, enter the logging information based on the [documentation](https://psframework.org/documentation/documents/psframework/logging.html) for the PowerShell Framework module. If you do not want to use the logging system, set the logging 'Enabled' field to false.

Email
- Optionally, enter the email provider information based on the [documentation](https://github.com/EvotecIT/Mailozaurr) for the Mailozaurr module. If you do not want to use the email alert system, set both the 'EmailonError' and 'EmailonWarning' fields to false.
- We recommend sending email using the more secure OAuth 2.0 or Graph API options, but the module also supports SMTP with a standard password (for example, if you use App Passwords to send email). This script allows for the email 'Password' field to be entered either as plain text or as an encrypted standard string. An encrypted standard string can be converted back to its secure string format but **only by the same account on the same computer it was encrypted from**. You can use the [New-EncryptedPassword script](https://github.com/Sekers/Useful-Scripts/tree/main/Password%20Tools/New-EncryptedPassword) to easily convert a password to an encrypted standard string.

Debugging
- **VerbosePreference (String):** Determines how PowerShell responds to verbose messages generated by a script, cmdlet, or provider, such as the messages generated by the Write-Verbose cmdlet. Verbose messages describe the actions performed to execute a command. Valid values are listed below and you can find more information in Microsoft's [preference variables documentation](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_preference_variables?view=powershell-7.2#verbosepreference).
    - **Stop:** Displays the verbose message and an error message and then stops executing.
    - **Inquire:** Displays the verbose message and then displays a prompt that asks you whether you want to continue.
    - **Continue:** Displays the verbose message and then continues with execution.
    - **SilentlyContinue:** (Default) Doesn't display the verbose message. Continues executing.
- **LogDebugInfo (Boolean):** Specifies whether to log information the script normally considers unnecessary except when troubleshooting. The logging provider needs to be enabled for this feature to work.

---

### **config_group_team_mapping.json**

JSON file that contains an array of Teams and/or Team Channels (Private Channels only) that you want to add group members to. You should only have one entry for each Team or Channel. When mapping Private Channel memberships, you need to specify which Team the Channel belongs to.

- **MapType (String):** Specify whether the included groups are being given access to a Team or a Channel. Use 'Team' or 'Channel'.
- **M365_Team_DisplayName (String):** Optionally, enter a name for the Team. This field is only used to more easily identify the Team when looking at the config file.
- **M365_Team_ID (String):** Enter the Team ID. You can find it using [Get-MgTeam](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.teams/get-mgteam) or in the [Teams Admin Center](https://admin.teams.microsoft.com/teams/manage) (there it's called the 'Group ID').
- **M365_Channel_DisplayName (String):** Only used when 'MapType' is set to 'Channel'. Optionally, enter a name for the Channel. This field is only used to more easily identify the Channel when looking at the config file.
- **M365_Channel_ID (String):** Enter the Channel ID. You can find it using [Get-MgTeamChannel](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.teams/get-mgteamchannel) or in the [Teams Admin Center](https://admin.teams.microsoft.com/teams/manage) (you can find it when inside the channel by looking at the URL in your web browser and copying everything after '/channels/'). E.g., "19:aac3e13cd5f99827b60cdb0b6df37a3e@thread.tacv2".
- **Groups (Array):** Array containing the following fields for *each* group. You can map zero (if you want a placeholder for a Team/Channel) or more groups to a Team or Channel.
    - **M365_Group_DisplayName (String):** Optionally, enter a name for the group. This field is only used to more easily identify the group when looking at the config file.
    - **M365_Group_ID (String):** Enter the group ID. You can find it using [Get-MgGroup](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.groups/get-mggroup) or, for Azure AD groups only, in the [Azure AD Admin Center](https://aad.portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Groups).

---

### **config_remove_account_exclusions.json**

JSON file that contains an array of users who should not be removed from Teams or Private Channels, even if they no longer are a member of a mapped group. This only applies when 'RemoveExtraTeamMembers' or 'RemoveExtraChannelMembers' is set to true. Create an array entry for *each* user you want to exclude.

- **UserPrincipalName (String):** Optionally, enter the UPN for the user you want a removal exception for. This field is only used to more easily identify the user when looking at the config file.
- **Id (String):"** Enter the user ID. You can find it using [Get-MgUser](https://learn.microsoft.com/en-us/powershell/module/microsoft.graph.users/get-mguser) or, for Azure AD users only, in the [Azure AD Admin Center](https://aad.portal.azure.com/#view/Microsoft_AAD_IAM/ActiveDirectoryMenuBlade/~/Users).