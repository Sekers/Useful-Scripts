# Useful-Scripts
A collection of useful scripts

## Categories

### Password Tools
- New-SecurePassword: A PowerShell script that accepts credentials and then returns the password as an encrypted standard string. Unlike a secure string, an encrypted standard string can be saved in a file for later use. The encrypted standard string can be converted back to its secure string format by using the ConvertTo-SecureString cmdlet (the password can only be decrypted by the same account on the same computer it was encrypted from). Use the "-VerifyADAccount" switch to first check the submitted credentials against your Active Directory domain for verification (requires the Microsoft ActiveDirectory PowerShell Module).
