# Accept VerifyADAccount Switch
param([switch]$VerifyADAccount)

Write-Host "`n"
Write-Host "This script accepts credentials and then returns the password as an encrypted standard string."
Write-Host "Unlike a secure string, an encrypted standard string can be saved in a file for later use."
Write-Host "The encrypted standard string can be converted back to its secure string format by using the ConvertTo-SecureString cmdlet."
Write-Host "Note: The password can only be decrypted by the same account on the same computer it was encrypted from."
Write-Host 'Optionally use the "-VerifyADAccount" switch to first check the submitted credentials against your Active Directory domain for verification (requires the Microsoft ActiveDirectory PowerShell Module).' 
Write-Host "`n"
function New-SecurePassword
{
    [CmdletBinding()]
    param (
        [switch]$VerifyADAccount
    )
    
    # Get Domain Credentials
    $Credential = $null
    if ($VerifyADAccount)
    {
        # Check For Microsoft ActiveDirectory Module
        Import-Module ActiveDirectory
        if (!(Get-Module -Name "ActiveDirectory"))
        {
            # Module is not loaded
            Write-Error "Please First Install the Microsoft ActiveDirectory Module (part of RSAT - see https://docs.microsoft.com/en-US/troubleshoot/windows-server/system-management-components/remote-server-administration-tools)" -ErrorAction Stop
        }
        
        $Credential = Get-Credential -Message "Enter domain account for updating Active Directory. Must be in either domain\username or username@domain format."
        
        # $CurrentUserName = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Split("\")[1] # Split removes domain from username
        $DomainUserName = $null
        if ($Credential.UserName -match '\\')
        {
            $DomainUserName = $Credential.UserName.Split("\")[1]
        }

        if ($Credential.UserName -match '@')
        {
            $DomainUserName = $Credential.UserName.Split("@")[0]
        }

        if ($null -eq $DomainUserName)
        {
            Write-Error "Please make sure that your username is in either domain\username or username@domain format." -ErrorAction Stop
        }

        # Get Domain Controller to Use for Active Directory Verification
        $ADServer = Get-ADDomainController -Discover

        # Checks That a DC is Reachable and That the Credentials Work
        try
        {
            $null = Get-ADUser -Identity $DomainUserName -Credential $Credential -Server $ADServer -ErrorAction Stop
        }
        catch
        {
            Write-Host "Active Directory Connection Error: $_"
            throw "Error: $($_.Exception.Message)"
        }
    }
    else
    {
        $Credential = Get-Credential -Message "Enter account password (username can be any text)"
    }

    # Return Secure String as an Encrypted Standard String
    try
    {
        $EncryptedStringPassword = ConvertFrom-SecureString -SecureString $Credential.Password
    }
    catch
    {
        Write-Error "You cannot have an empty password."
    }
    
    Write-Host "The Encrypted Standard String For the Submitted Credentials is as Follows:`n"
    return $EncryptedStringPassword
}

############
# RUN CODE #
############

if ($VerifyADAccount)
{
    New-SecurePassword -VerifyADAccount
}
else
{
    New-SecurePassword
}
