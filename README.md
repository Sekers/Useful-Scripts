# Useful-Scripts
A collection of useful scripts.

## Categories
### Automation
- [PowerShell Automation Script Example:](https://github.com/Sekers/Useful-Scripts/tree/main/Automation/PowerShell%20Automation%20Script%20Example) A sample PowerShell script that can be used as a template for scheduled tasks or other automation and includes warning/error email support, normal and debug logging, as well an example on how to use external configuration files.

### Password Tools
- [New-SecurePassword:](https://github.com/Sekers/Useful-Scripts/blob/main/Password%20Tools/New-SecurePassword.ps1) A PowerShell script that accepts credentials and then returns the password as an encrypted standard string. Unlike a secure string, an encrypted standard string can be saved in a file for later use. The encrypted standard string can be converted back to its secure string format by using the ConvertTo-SecureString cmdlet (the password can only be decrypted by the same account on the same computer it was encrypted from). Optionally use the "-VerifyADAccount" switch to first check the submitted credentials against your Active Directory domain for verification (requires the Microsoft ActiveDirectory PowerShell Module).
