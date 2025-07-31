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

# Indicate Desired Time Zone
# Note: You can either set the time zone to match the mailbox regional timezone or manually specify a time zone.
# To match the mailbox regional tz set it to 'MatchRegionalConfig' >>> $DesiredTimeZone = 'MatchRegionalConfig'
# To Match a specific timezone >>> $DesiredTimeZone = 'Central Standard Time'
# Tip: Get a list of available time zones >>> Get-TimeZone -ListAvailable
[string]$DesiredTimeZone = 'MatchRegionalConfig'

# Indicate Backup Time Zone
# Some mailboxes may not have a regional set (it can come back $null) so it is good to set a backup time zone.
[string]$BackupTimeZone = 'Central Standard Time'

# Enable this setting to record & skip updated/verified mailboxes on subsequent runs. Update path if enabled.
[bool]$SkipProcessedMailboxes = $true
[string]$ProcessedFilePath = "$PSScriptRoot\ProcessedMailboxes.csv"

#############################################
# Make Sure Script Is Set to Stop on Errors #
#############################################

# Stop Script on Errors
$ErrorActionPreference = 'Stop'

#################
# Begin Logging #
#################

# Logging Start (via quick & dirty method Start-Transcript)
$ScriptName = $MyInvocation.MyCommand.Name
Start-Transcript -Path "$PSScriptRoot\Transcripts\$ScriptName - $((Get-Date).ToUniversalTime() | Get-Date -Format "yyyy-MM-dd-HHmmss").txt" -Append

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

# If "SkipProcessedMailboxes" is enabled, try and import the CSV.
if ($SkipProcessedMailboxes)
{
   try
   {
      $CSVContents = Import-Csv -Path $ProcessedFilePath
   }
   catch
   {
      $CSVContents = $null
   }
}

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

   # If "SkipProcessedMailboxes" is enabled, check if the mailbox has already been processed. If so, skip the mailbox.
   if ($SkipProcessedMailboxes)
   {
      if ($CSVContents.Guid -contains $userMailbox.Guid)
      {
         Write-Host "Calendar working hours time zone for '$($userMailbox.UserPrincipalName)' has already been processed."

         # Estimate Time Remaining
         $SecondsElapsed = (Get-Date) - $StartDateTime
         $SecondsRemaining = ($SecondsElapsed.TotalSeconds / $CurrentMailboxIndex) * ($MailboxCount - $CurrentMailboxIndex)

         # Skip to Next Mailbox Record
         continue
      }
   }

   # Get Current Mailbox Calendar Working Hours Time Zone
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
      Write-Host "Attempting to set calendar working hours timezone for '$($userMailbox.UserPrincipalName)' to '$TimeZone' (currently set to '$($CalendarWorkingHoursTimeZone.WorkingHoursTimeZone)')." -ForegroundColor Green -BackgroundColor Black
      Set-MailboxCalendarConfiguration -Identity $userMailbox.Guid -WorkingHoursTimeZone $TimeZone
   }
   else
   {
      Write-Host "Calendar working hours time zone for '$($userMailbox.UserPrincipalName)' is already set to '$TimeZone'."
   }

   # Write to "Mailboxes Processed" File (If "SkipProcessedMailboxes" is Enabled)
   if ($SkipProcessedMailboxes)
   {
      # Collect CSV Data
      $CSV_Data = [PSCustomObject]@{
         UserPrincipalName = $userMailbox.UserPrincipalName
         DisplayName       = $userMailbox.DisplayName
         Guid              = $userMailbox.Guid
         Processed         = Get-Date -Format 'o'
      }

      # Create or Append to CSV File
      if (-not (Test-Path -Path $ProcessedFilePath)) # CSV File Does Not Already Exist
      {
         if ($PSVersionTable.PSEdition.ToString() -eq 'Desktop') # Hack because Windows PowerShell 5.1 adds the Byte order mark (BOM) to the beginning of the export (which we don't want). In Windows PowerShell, any Unicode encoding, except UTF7, always creates a BOM. PowerShell (v6 and higher) defaults to utf8NoBOM for all text output.
         {
            $CSV_Data | ConvertTo-Csv -NoTypeInformation | Out-String | ForEach-Object {[Text.Encoding]::UTF8.GetBytes($_)} | Set-Content -Encoding Byte -Path $ProcessedFilePath
         }
         else # PowerShell Core Exports without the BOM
         {
            $CSV_Data | Export-Csv -Path $ProcessedFilePath -NoTypeInformation -Encoding UTF8
         }
      }
      else # CSV File Already Exists
      {
         if ($PSVersionTable.PSEdition.ToString() -eq 'Desktop') # Hack because Windows PowerShell 5.1 adds the Byte order mark (BOM) to the beginning of the export (which we don't want). In Windows PowerShell, any Unicode encoding, except UTF7, always creates a BOM. PowerShell (v6 and higher) defaults to utf8NoBOM for all text output.
         {
            $CSV_Data | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Out-String | ForEach-Object {[Text.Encoding]::UTF8.GetBytes($_)} | Add-Content -Encoding Byte -Path $ProcessedFilePath
         }
         else # PowerShell Core Exports without the BOM
         {
            $CSV_Data | Export-Csv -Path $ProcessedFilePath -NoTypeInformation -Encoding UTF8 -Append
         }
      }
   }

   # Estimate Time Remaining
   $SecondsElapsed = (Get-Date) - $StartDateTime
   $SecondsRemaining = ($SecondsElapsed.TotalSeconds / $CurrentMailboxIndex) * ($MailboxCount - $CurrentMailboxIndex)
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
