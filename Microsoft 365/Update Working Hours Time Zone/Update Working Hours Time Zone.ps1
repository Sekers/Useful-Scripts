#############
# Overview #
############

# This script checks all Exchange Online user mailboxes and sets the Outlook calendar working hours time zone to the desired time zone.
# Note: The 'working hours' time zone setting is different than the mailbox regional configuration time zone.

# Requires EXO Module > https://www.powershellgallery.com/packages/ExchangeOnlineManagement/
# More Info: https://docs.microsoft.com/en-us/powershell/module/exchange/?view=exchange-ps

#################
# Set Variables #
#################

# Stop Script on Errors
$ErrorActionPreference = 'Stop'

# Indicate Desired Time Zone
# Note: You can either set the time zone to match the mailbox regional timezone or manually specify a time zone.
# To match the mailbox regional tz set it to 'MatchRegionalConfig' >>> $DesiredTimeZone = 'MatchRegionalConfig'
# To Match a specific timezone >>> $DesiredTimeZone = 'Central Standard Time'
# Tip: Get a list of available time zones >>> Get-TimeZone -ListAvailable
$DesiredTimeZone = 'MatchRegionalConfig'

# Indicate Backup Time Zone
# Some mailboxes may not have a regional set (it can come back $null) so it is good to set a backup time zone.
$BackupTimeZone = 'Central Standard Time'

#################
# Begin Logging #
#################

# Logging Start (via quick & dirty method Start-Transcript)
$ScriptName = $MyInvocation.MyCommand.Name
Start-Transcript -Path "$PSScriptRoot\$ScriptName - $(Get-Date -Format "yyyy-MM-dd").txt" -append

######################
# Validate Variables #
######################

# Validate Time Zone
$TimeZones = Get-TimeZone -ListAvailable
# $TimeZones | Sort-Object DisplayName | Format-Table -Auto Id,DisplayName
if (-not ($DesiredTimeZone -eq 'MatchRegionalConfig' -or $TimeZones.Id -contains $DesiredTimeZone))
{
   Write-Error "The time zone ID value specified for 'DesiredTimeZone' is not valid."
}
if (-not ($BackupTimeZone -eq 'MatchRegionalConfig' -or $TimeZones.Id -contains $BackupTimeZone))
{
   Write-Error "The time zone ID value specified for 'BackupTimeZone' is not valid."
}

##################
# Connect to EXO #
##################

# Check For EXO Module (make sure you update to the latest version >>> Update-Module -Name ExchangeOnlineManagement)
Import-Module ExchangeOnlineManagement -ErrorAction SilentlyContinue
if (!(Get-Module -Name "ExchangeOnlineManagement"))
{
   # Module is not loaded
   Write-Error "Please First Install the EXO Module from https://www.powershellgallery.com/packages/ExchangeOnlineManagement/."
   Return
}

# Connect To EXO If Not Already Connected 
# (More options detailed at: https://docs.microsoft.com/en-us/powershell/exchange/connect-to-exchange-online-powershell?view=exchange-ps)
[array]$ConnectionInfo = Get-ConnectionInformation
if (-not $ConnectionInfo.Count -ge 1)
{
   Connect-ExchangeOnline
}

###########
# Do Work #
###########

# Get All Mailboxes
[array]$UserMailboxes = Get-EXOMailbox -ResultSize unlimited | Where-Object {$_.RecipientTypeDetails -eq "UserMailbox"} | Sort-Object UserPrincipalName

# DEBUG (REDUCE WORKING SET)
# [array]$UserMailboxes = $UserMailboxes[0..5]

# Get Mailboxes Working Hours Time Zones & Set to CST If Needed
$CurrentMailboxIndex = 0
$MailboxCount = $UserMailboxes.Count
$StartDateTime = Get-Date
$SecondsRemaining = -1
foreach ($userMailbox in $UserMailboxes)
{
   $CurrentMailboxIndex++
   Write-Progress -Activity 'Check & Update Calendar Working Hours Time Zone' -Status "Mailbox $CurrentMailboxIndex of $MailboxCount" -PercentComplete $(100*$CurrentMailboxIndex/$MailboxCount) -SecondsRemaining $SecondsRemaining

   $CalendarWorkingHoursTimeZone = $userMailbox | Get-MailboxCalendarConfiguration | Select-Object Identity, WorkingHoursTimeZone

   # Determine Time Zone to Set
   if ($DesiredTimeZone -eq 'MatchRegionalConfig')
   {
      $MailboxRegionalTimeZone = Get-MailboxRegionalConfiguration -Identity $userMailbox.Guid | Select-Object -ExpandProperty TimeZone
      if (-not [string]::IsNullOrEmpty($MailboxRegionalTimeZone))
      {
         $TimeZone = $MailboxRegionalTimeZone
      }
      else
      {
         $TimeZone = $BackupTimeZone
      }
   }
   else
   {
      $TimeZone = $DesiredTimeZone
   }

   if ($CalendarWorkingHoursTimeZone.WorkingHoursTimeZone -ne $TimeZone)
   {
      Write-Host "Attempting to set calendar working hours timezone for $($userMailbox.UserPrincipalName) to '$TimeZone' (currently set to '$($CalendarWorkingHoursTimeZone.WorkingHoursTimeZone)')" -ForegroundColor Green -BackgroundColor Black
      Set-MailboxCalendarConfiguration -Identity $userMailbox.Guid -WorkingHoursTimeZone $TimeZone
   }
   else
   {
      Write-Host "Calendar working hours time zone for $($userMailbox.UserPrincipalName) is already set to '$TimeZone'"
   }

   # Estimate Time Remaining
   $SecondsElapsed = (Get-Date) - $StartDateTime
   $SecondsRemaining = ($SecondsElapsed.TotalSeconds / $CurrentMailboxIndex) * ($UserMailboxes.Count - $CurrentMailboxIndex)
}

# Write Progress Completed
Write-Progress -Completed

##################
# Script Cleanup #
##################

# Disconnect All Active EXO Sessions
Disconnect-ExchangeOnline -Confirm:$false

###############
# End Logging #
###############

# Logging Stop
Stop-Transcript
