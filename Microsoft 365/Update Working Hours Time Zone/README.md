# Update Outlook Calendar Working Hours Time Zone

## Overview

A PowerShell script that updates the working hours time zone for Exchange Online Outlook calendars. This affects the availability (free/busy) time zone when scheduling meetings and events.

This time zone setting defaults to Pacific Standard Time. It should automatically update on first use based on the Outlook or Teams application or browser location, but this is not always the case. It can also sometimes get set to an incorrect time zone when using web traffic proxies. Since it is a different setting than the mailbox regional configuration time zone, it can cause confusion if these two time zone configurations are different.

This script is meant to be run in attended mode by a Microsoft 365 admin who can manage Exchange Online mailboxes in the desired tenant.

## Prerequisites
- Requires the Exchange Online (EXO) PowerShell Module > https://www.powershellgallery.com/packages/ExchangeOnlineManagement/
- More Info: https://docs.microsoft.com/en-us/powershell/module/exchange/?view=exchange-ps

## Configuration

- **DesiredTimeZone (String):** ID of the desired time zone to set the working hours time zone to.
  - Note: You can either set the time zone to match the mailbox regional timezone or manually specify a time zone.
  - To match the mailbox regional tz set it to 'MatchRegionalConfig' >>> $DesiredTimeZone = 'MatchRegionalConfig'
  - To Match a specific timezone >>> $DesiredTimeZone = 'Central Standard Time'
  - Tip: Get a list of available time zones >>> Get-TimeZone -ListAvailable
- **BackupTimeZone (String):** ID of the backup time zone to set the working hours time zone to.
  - Some mailboxes may not have a regional set (it can come back $null) so it is good to set a backup time zone.
  - Tip: Get a list of available time zones >>> Get-TimeZone -ListAvailable
- **SkipProcessedMailboxes (Boolean):** Enable this setting to record & skip updated/verified mailboxes on subsequent runs.
  - Since each mailbox has to be checked against Graph individually, this will greatly speed up subsequent runs.
  - If you enable this setting, make sure to configure the related **ProcessedFilePath (String)** setting.