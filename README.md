# Useful-Scripts
A collection of useful scripts.

## Categories
### Automation
- [PowerShell Automation Script Example:](/Automation/PowerShell%20Automation%20Script%20Example) A sample PowerShell script that can be used as a template for scheduled tasks or other automation and includes warning/error email support, normal and debug logging, as well an example on how to use external configuration files.

### Deployment
- [BatchFile-Elevate-Prompt:](/Deployment/BatchFile-Elevate-Prompt) A batch file script that will attempt to elevate a .CMD or .BAT batch file using the standard UAC prompt. You can use this to call installers that require administrator privileges or other actions that require elevation on the local machine.

- [PowerShell-Install-BITS:](/Deployment/PowerShell-Install-BITS) A sample PowerShell script that checks if a program or update is installed and, if not, then downloads the installer/updater with [BITS](https://docs.microsoft.com/en-us/windows/win32/bits/background-intelligent-transfer-service-portal) and installs. More info in the [README](/Deployment/PowerShell-Install-BITS).

### Microsoft 365
- [M365 Teams Membership Sync:](/Microsoft%20365/Teams%20Membership%20Sync) A PowerShell script that syncs members of Microsoft 365 and Azure AD groups to M365 Team & Team Channel groups. This script can be used to dynamically update Team and Team Channel members from groups. This is useful if you do not have the licensing necessary for dynamic group updates. It also has the added benefit of logging + email alerts and optionally skipping the removing of members who no longer are in the mapped group(s), allowing them to remain members of Teams and Channels they have perviously been added to.

### Password Tools
- [New-EncryptedPassword:](/Password%20Tools/New-EncryptedPassword) A PowerShell script that accepts credentials and then returns the password as an encrypted standard string. Unlike a secure string, an encrypted standard string can be saved in a file for later use. The encrypted standard string can be converted back to its secure string format by using the ConvertTo-SecureString cmdlet (the password can only be decrypted by the same account on the same computer it was encrypted from).

    Optionally use the "-VerifyADAccount" switch to first check the submitted credentials against your Active Directory domain for verification (requires the Microsoft ActiveDirectory PowerShell Module).
