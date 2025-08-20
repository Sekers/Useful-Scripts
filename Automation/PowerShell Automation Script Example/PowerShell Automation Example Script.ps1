# PowerShell Automation Script Example
# A sample PowerShell script that can be used as a template for scheduled tasks or other automation and includes warning/error email support,
# normal and debug logging, as well an example on how to use external configuration files.

############
# OVERVIEW #
############

# This script does the following:
# 1. Does some Active Directory lookups.

# If supplied, passwords in the configuration file need to be encrypted. Use New-EncryptedPassword (https://github.com/Sekers/Useful-Scripts/tree/main/Password%20Tools/New-EncryptedPassword) to create an encrypted standard string of any desired password.
# If you leave the Active Directory username 'ADCredential_Username' configuration field empty, it will connect to domain controllers using the account that the script is running under.

#################
# PREREQUISITES #
#################

# Microsoft ActiveDirectory PowerShell Module (part of RSAT - https://support.microsoft.com/help/2693643/remote-server-administration-tools-rsat-for-windows-operating-systems)
# PowerShell Framework Module (for better logging - https://psframework.org/)
# Mailozaurr PowerShell Module (https://github.com/EvotecIT/Mailozaurr)

#################################
# DO NOT MODIFY BELOW THIS LINE #
#################################

# Check For Microsoft ActiveDirectory Module
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
if (!(Get-Module -Name "ActiveDirectory"))
{
   # Module is not loaded
   Write-Error "Please First Install the Microsoft ActiveDirectory Module (part of RSAT - see https://docs.microsoft.com/en-US/troubleshoot/windows-server/system-management-components/remote-server-administration-tools)"
   Return
}

# Check For Mailozaurr PowerShell Module (make sure you install the latest version first!)
Import-Module Mailozaurr -ErrorAction SilentlyContinue
if (!(Get-Module -Name "Mailozaurr"))
{
   # Module is not loaded
   Write-Error "Please First Install the Mailozaurr PowerShell Module from https://github.com/EvotecIT/Mailozaurr."
   Return
}

# Check For PowerShell Framework Module (make sure you install the latest version first!)
Import-Module PSFramework -ErrorAction SilentlyContinue
if (!(Get-Module -Name "PSFramework"))
{
   # Module is not loaded
   Write-Error "Please First Install the PowerShell Framework Module from https://psframework.org."
   Return
}

#############
# FUNCTIONS #
#############

function Get-ComputerNameFromParameter {

    [CmdletBinding()]
    param (
        $ComputerName
    )

    # Write log message and return computer name
    Write-PSFMessage -Message "The provided computer name is: $($ComputerName)"
    return $ComputerName
}

##################################
# SET VARIABLES FROM CONFIG FILE #
##################################

# Import General Configuration Settings
$Config = Get-Content -Path "$PSScriptRoot\Config\config_general.json" | ConvertFrom-Json

# Set General Properties
[string]$ScriptName = $Config.General.ScriptName
[bool]$EmailonError = $Config.General.EmailonError
[bool]$EmailonWarning = $Config.General.EmailonWarning

# Configure Logging (See https://psframework.org/documentation/documents/psframework/logging/loggingto/logfile.html)
$paramSetPSFLoggingProvider = @{
    Name             = $Config.Logging.Name
    InstanceName     = $Config.Logging.InstanceName
    FilePath         = $ExecutionContext.InvokeCommand.ExpandString($Config.Logging.FilePath)
    FileType         = $Config.Logging.FileType
    LogRotatePath    = $ExecutionContext.InvokeCommand.ExpandString($Config.Logging.LogRotatePath)
    LogRetentionTime = $Config.Logging.LogRetentionTime
    Enabled          = $Config.Logging.Enabled
}

# Configure Email Alerts (need to decrypt the password if provided)
if (-not [string]::IsNullOrEmpty($Config.Email.EncryptedPassword))
{
    $EmailArguments_Password = [System.Net.NetworkCredential]::new("", $($Config.Email.EncryptedPassword | ConvertTo-SecureString)).Password # Can only be decrypted by the same AD account on the same computer.
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

[string]$VerbosePreference = $Config.Debugging.VerbosePreference # Use 'Continue' to Enable Verbose Messages and Use 'SilentlyContinue' to reset back to default.
[bool]$LogDebugInfo = $Config.Debugging.LogDebugInfo # Writes Extra Information to the log if $true

################
# PERFORM WORK #
################

# Stop on Errors
$ErrorActionPreference = "Stop"

# Set Logging Data
Set-PSFLoggingProvider @paramSetPSFLoggingProvider
Write-PSFMessage -Level Important -Message "---SCRIPT BEGIN---"
Write-PSFMessage -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString()), $($PSVersionTable.PSEdition.ToString())$(if([Environment]::Is64BitProcess){$(", 64Bit")}else{$(", 32Bit")})"

# Log Module Versions
foreach ($moduleInfo in Get-Module)
{
    Write-PSFMessage -Message "$($moduleInfo.Name) Module Version: $($moduleInfo.Version)"
}

try
{
    # Initialize Variables
    $CustomWarningMessage = $null
    
    # Get Domain Credentials if it doesn't already exist
    if ($null -eq $DomainCredential)
    {
        # If ADCredential_Username is empty in the config then just use the current processes's credential
        if ([string]::IsNullOrEmpty($Config.General.ADCredential_Username))
        {
            $DomainUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $DomainUserName = $DomainUserName.Split("\")[1]
        }
        else
        {
            $DomainCredential = New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $($Config.General.ADCredential_Username), ($($Config.General.ADCredential_EncryptedPassword) | ConvertTo-SecureString)
            # $CurrentUserName = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Split("\")[1] # Split removes domain from username
            $DomainUserName = $null
            if ($DomainCredential.UserName -match '\\')
            {
                $DomainUserName = $DomainCredential.UserName.Split("\")[1]
            }

            if ($DomainCredential.UserName -match '@')
            {
                $DomainUserName = $DomainCredential.UserName.Split("@")[0]
            }

            if ($null -eq $DomainUserName)
            {
                Write-Error "Please make sure that your username is in either [domain]]\username or username@[domain] format."
                Return
            }
        }
    }

    # Get Domain Controller to Use for Active Directory Updates (to make sure it always sticks with the same server)
    $ADServer = Get-ADDomainController -Discover -Writable

    # Set Global Active Directory Module Cmdlet Parameters
    $ADModuleCmdletParameters = @{
        Server = $ADServer
    }
    if ($null -ne $DomainCredential) {$ADModuleCmdletParameters['Credential'] = $DomainCredential}

    # Checks That a DC is Reachable and That the Credentials Work (doesn't verify permissions)
    try
    {
        $null = Get-ADUser -Identity $DomainUserName @ADModuleCmdletParameters -ErrorAction Stop
    }
    catch
    {
        Write-PSFMessage -Level Error -Message 'Active Directory Authentication Error' -Tag 'Failure' -ErrorRecord $_
        throw "Error: $($_.Exception.Message)"
    }

    
        
    # Get AD group members.
    $GroupName = 'Administrators'
    [array]$CurrentGroupMembers = Get-ADGroupMember -Identity $GroupName @ADModuleCmdletParameters

    # Log debug info, if enabled.
    if ($LogDebugInfo) {Write-PSFMessage -Level Debug -Message "Current Group Members (SamAccountName): $($CurrentGroupMembers.SamAccountName -join ', ')"}

    # Create warning message if group is empty
    if ($CurrentGroupMembers.Count -eq 0)
    {
        Write-PSFMessage -Level Warning -Message "WARNING: No members in group `'$GroupName`'."
        $CustomWarningMessage += "`nWARNING: No members in group `'$GroupName`'."
    }

    # Loop through the users and write to host and log a message for each.
    foreach ($user in $CurrentGroupMembers)
    {
        Write-PSFMessage -Level Important "$($user.name) is a super cool admin!"
    }

    # Return provided computer name
    $ComputerName = "MyComputer"
    $ReturnedComputerName = Get-ComputerNameFromParameter -ComputerName $ComputerName
    Write-PSFMessage -Message "The returned computer name is: $($ReturnedComputerName)"

    # Email Warning Message, if Enabled
    If ($EmailonWarning -and $null -ne $CustomWarningMessage)
    {
        # Get Rid of Extra Line at Beginning
        $CustomWarningMessage = $CustomWarningMessage.Trim()

        # Try to Email Alert Message On Warning
        try
        {
                # Add More Email Attributes
                $EmailArguments.Subject = "$ScriptName Script - Warning"
                $EmailArguments.Text = "The $ScriptName script has detected at least one non-critical issue:`n`n$CustomWarningMessage`n`nThank you,`nThe IT Team"
                $EmailArguments.Attachment = $null # No attachments because we don't want anything to accidentally prevent the alert email from being sent.

                # Send Warning Message Alert
                $SendEmailMessageResult = Send-EmailMessage @EmailArguments
                if ($null -eq $SendEmailMessageResult.Error -or $SendEmailMessageResult.Error -eq "")
                {
                    Write-PSFMessage -Level Important -Message "Email Alert (Script Warning): Sent successfully to $($SendEmailMessageResult.SentTo)"
                }
                else
                {
                    Write-PSFMessage -Level Error -Message "Email Alert (Script Warning): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_
                }
        }
        catch
        {
            Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_
        }
    }

    # End Logging Message
    Write-PSFMessage -Level Important -Message "---SCRIPT END---"
    Wait-PSFMessage # Make Sure Logging Is Flushed Before Terminating
}
catch
{
    Write-PSFMessage -Level Error -Message "Error Running Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber))" -Tag 'Failure' -ErrorRecord $_

    # Try to Email Alert Message On Error
    try
    {
        if ($EmailonError)
        {
            # Add More Email Attributes
            $EmailArguments.Subject = "$ScriptName Script - Error"
            $EmailArguments.Text = "There has been an error running the $ScriptName Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber)):`n`n$_`n`nThank you,`nThe IT Team"
            $EmailArguments.Attachment = $null # No attachments because we don't want anything to accidentally prevent the alert email from being sent.

            # Send Error Message Alert
            $SendEmailMessageResult = Send-EmailMessage @EmailArguments
            if ($null -eq $SendEmailMessageResult.Error -or $SendEmailMessageResult.Error -eq "")
            {
                Write-PSFMessage -Level Important -Message "Email Alert (Script Error): Sent successfully to $($SendEmailMessageResult.SentTo)"
            }
            else
            {
                Write-PSFMessage -Level Error -Message "Email Alert (Script Error): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_
            }
        }
    }
    catch
    {
        Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_
    }

    # End Logging Message
    Write-PSFMessage -Level Important -Message "---SCRIPT END---"
    Wait-PSFMessage # Make Sure Logging Is Flushed Before Terminating
}
