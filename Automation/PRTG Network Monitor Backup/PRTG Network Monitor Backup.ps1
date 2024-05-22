# PRTG Network Monitor Backup
# Version 1.0.1
# A PowerShell script that will back up your PRTG environment.
# Includes optional normal and debug logging.
# Includes optional warning/error messaging (email, chat, etc.) support.
# Includes optional backup compression.

############
# OVERVIEW #
############

# This script does the following:
# 1. Copies PRTG server items specified in the configuration file to a temporary working folder.
# 2. Optionally, compresses the temporary backup folder.
# 3. Copies the backup to the specified backup destination.
# 4. Optionally, sends warning and/org error notification messages (email, chat, etc.).
# 5. Cleans up temporary files.

# If supplied, the backup destination connection password in the configuration file should be encrypted.
#     For testing, while not recommended, you can use an unencrypted plaintext string.
#     Use New-EncryptedPassword (https://github.com/Sekers/Useful-Scripts/tree/main/Password%20Tools/New-EncryptedPassword) to easily create an encrypted standard string of any desired password.
# If you leave the 'DestinationCredential_Username' configuration field empty, it will connect using the account context that the script is running under.

#################
# PREREQUISITES #
#################

### Required ###

# PowerShell Desktop 5.1 or PowerShell Core 7.0 or later.

### Optional ###

# PowerShell Framework Module (optional; for modern logging - https://psframework.org/).
# ScriptMessage PowerShell Module (optional; for modern alerts - https://github.com/Sekers/ScriptMessage).
#     Depending on the messaging service(s) you want to use to send notification messages, ScriptMessage may require additional modules such as the Microsoft Graph PowerShell SDK.

#############
# FUNCTIONS #
#############

function Get-PRTGPath
{
    param(
        [Parameter(
        Mandatory = $true,
        ValueFromPipeline = $true,
        ValueFromPipelineByPropertyName = $true)]
        [string]$Item,

        [Parameter(
        Mandatory = $true,
        ValueFromPipeline = $true,
        ValueFromPipelineByPropertyName = $true)]
        [string]$Type,

        [Parameter(
        Mandatory = $false,
        ValueFromPipeline = $true,
        ValueFromPipelineByPropertyName = $true)]
        [string]$Subtype
    )

    $TypeDirectory = switch ($Type)
    {
        'Program'   { $ProgramPath }
        'Data'      { $DataPath }
    }

    # Set Subdirectory
    if ([string]::IsNullOrEmpty($Subtype))
    {
        $Subdirectory = $Paths.$($Type).$($Item)
    }
    else
    {
        $Subdirectory = $Paths.$($Type).$($Subtype).$($Item)
    }

    return "$TypeDirectory\$Subdirectory"
}

##############################
# GET & VERIFY CONFIGURATION #
##############################

# Import General Configuration Settings
$Config = Get-Content -Path "$PSScriptRoot\Config\config_general.json" | ConvertFrom-Json

# Import Paths Map
$Paths = Get-Content -Path "$PSScriptRoot\Config\config_paths_map.json" | ConvertFrom-Json

# Set General Properties and Verify Type.
[string]$ScriptName = $Config.General.ScriptName
[string]$ProgramPath = $Config.General.ProgramPath
[string]$DataPath = $Config.General.DataPath

# Set Backup Properties and Verify Type.
[string]$Backup_DestinationPath = $Config.Backup.DestinationPath
[int]$BackupsToKeep = $Config.Backup.BackupsToKeep
[bool]$Backup_Compression_Enabled = $Config.Backup.Compression.Enabled
[string]$Backup_Compression_Tool = $Config.Backup.Compression.Tool
[string]$Backup_Compression_Level = $Config.Backup.Compression.Level
[bool]$Backup_Compression_StageToTempFolder = $Config.Backup.Compression.StageToTempFolder
[bool]$Backup_Registry = $Config.Backup.Registry
[bool]$Backup_Program_Certificates = $Config.Backup.Program.Certificates
[bool]$Backup_Program_CustomSensors = $Config.Backup.Program.CustomSensors
[bool]$Backup_Program_DeviceTemplates = $Config.Backup.Program.DeviceTemplates
[bool]$Backup_Program_Download = $Config.Backup.Program.Download
[bool]$Backup_Program_Lookups = $Config.Backup.Program.Lookups
[bool]$Backup_Program_MIB = $Config.Backup.Program.MIB
[bool]$Backup_Program_Notifications = $Config.Backup.Program.Notifications
[bool]$Backup_Program_PRTGInstallerArchive = $Config.Backup.Program.PRTGInstallerArchive
[bool]$Backup_Program_Python = $Config.Backup.Program.Python
[bool]$Backup_Program_SensorSystem = $Config.Backup.Program.SensorSystem
[bool]$Backup_Program_SNMPLibraries = $Config.Backup.Program.SNMPLibraries
[bool]$Backup_Program_Themes = $Config.Backup.Program.Themes
[bool]$Backup_Program_WebRoot = $Config.Backup.Program.WebRoot
[bool]$Backup_Data_PRTGConfiguration_Dat = $Config.Backup.Data.'PRTGConfiguration.dat'
[bool]$Backup_Data_PRTGConfiguration_Old = $Config.Backup.Data.'PRTGConfiguration.old'
[bool]$Backup_Data_ConfigurationAutoBackups = $Config.Backup.Data.ConfigurationAutoBackups
[int]$Backup_Data_ConfigurationAutoBackups_ItemsToKeep = $Config.Backup.Data.ConfigurationAutoBackups_ItemsToKeep
[bool]$Backup_Data_LogDatabase = $Config.Backup.Data.LogDatabase
[int]$Backup_Data_LogDatabase_ItemsToKeep = $Config.Backup.Data.LogDatabase_ItemsToKeep
[bool]$Backup_Data_Logs_AppServer = $Config.Backup.Data.Logs.AppServer
[bool]$Backup_Data_Logs_Core = $Config.Backup.Data.Logs.Core
[bool]$Backup_Data_Logs_Debug = $Config.Backup.Data.Logs.Debug
[bool]$Backup_Data_Logs_DesktopClient = $Config.Backup.Data.Logs.DesktopClient
[bool]$Backup_Data_Logs_EnterpriseConsole = $Config.Backup.Data.Logs.EnterpriseConsole
[bool]$Backup_Data_Logs_Probe = $Config.Backup.Data.Logs.Probe
[bool]$Backup_Data_Logs_ProbeAdapter = $Config.Backup.Data.Logs.ProbeAdapter
[bool]$Backup_Data_Logs_SensorDeprecation = $Config.Backup.Data.Logs.SensorDeprecation
[bool]$Backup_Data_Logs_Sensors = $Config.Backup.Data.Logs.Sensors
[bool]$Backup_Data_Logs_ServerAdmin = $Config.Backup.Data.Logs.ServerAdmin
[bool]$Backup_Data_Logs_WebServer = $Config.Backup.Data.Logs.WebServer
[bool]$Backup_Data_LogsDebug = $Config.Backup.Data.LogsDebug
[bool]$Backup_Data_LogsSensors = $Config.Backup.Data.LogsSensors
[bool]$Backup_Data_LogsSystem = $Config.Backup.Data.LogsSystem
[bool]$Backup_Data_LogsWebServer = $Config.Backup.Data.LogsWebServer
[bool]$Backup_Data_MonitoringDatabase = $Config.Backup.Data.MonitoringDatabase
[int]$Backup_Data_MonitoringDatabase_ItemsToKeep = $Config.Backup.Data.MonitoringDatabase_ItemsToKeep
[bool]$Backup_Data_ReportPDFs = $Config.Backup.Data.ReportPDFs
[bool]$Backup_Data_SystemInformationDatabase = $Config.Backup.Data.SystemInformationDatabase
[bool]$Backup_Data_TicketDatabase = $Config.Backup.Data.TicketDatabase

# Configure Logging. See https://psframework.org/documentation/documents/psframework/logging/loggingto/logfile.html.
[bool]$LoggingEnabled = $Config.Logging.Enabled
$paramSetPSFLoggingProvider = @{
    Name             = $Config.Logging.Name
    InstanceName     = $Config.Logging.InstanceName
    FilePath         = $ExecutionContext.InvokeCommand.ExpandString($Config.Logging.FilePath)
    FileType         = $Config.Logging.FileType
    LogRotatePath    = $ExecutionContext.InvokeCommand.ExpandString($Config.Logging.LogRotatePath)
    LogRetentionTime = $Config.Logging.LogRetentionTime
    Wait             = $Config.Logging.Wait
    Enabled          = $LoggingEnabled
}

# Check For PowerShell Framework Module.
if ($LoggingEnabled)
{
    Import-Module PSFramework -ErrorAction SilentlyContinue
    if (!(Get-Module -Name "PSFramework"))
    {
    # Module is not loaded.
    Write-Error "Please First Install the PowerShell Framework Module from https://www.powershellgallery.com/packages/PSFramework/ "
    Return
    }
}

# Configure Email
[bool]$MessageOnError = $Config.General.MessageOnError
[bool]$MessageOnWarning = $Config.General.MessageOnWarning
[array]$MessageServices = $Config.Messaging.Services
[array]$MessageTypes = $Config.Messaging.Types
[array]$MessageFrom = $Config.Messaging.From
[array]$MessageReplyTo = $Config.Messaging.ReplyTo
[array]$MessageTo = $Config.Messaging.To
[array]$MessageCC = $Config.Messaging.CC
[array]$MessageBCC = $Config.Messaging.BCC
[bool]$MessageSaveToSentItems = $Config.Messaging.SaveToSentItems
[string]$MessageSender = $Config.Messaging.Sender


if ($MessageOnError -or $MessageOnWarning)
{
    Import-Module ScriptMessage -ErrorAction SilentlyContinue
    if (!(Get-Module -Name "ScriptMessage"))
    {
        # Module is not loaded.
        Write-Error "Please first install the ScriptMessage module from https://github.com/Sekers/ScriptMessage"
        Return
    }

    # Set ScriptMessage Messaging/Email Configuration Path
    Set-ScriptMessageConfigFilePath -Path "$PSScriptRoot\Config\config_scriptmessage.json"
}

#############
# DEBUGGING #
#############

[string]$VerbosePreference = $Config.Debugging.VerbosePreference # Use 'Continue' to Enable Verbose Messages and Use 'SilentlyContinue' to reset back to default.
[bool]$LogDebugInfo = $Config.Debugging.LogDebugInfo # Writes Extra Information to the log if $true. #TODO set up

################
# PERFORM WORK #
################

# Stop on Errors
$ErrorActionPreference = "Stop"

# If Logging is Enabled, Set Logging Data & Log PowerShell & Module Version Information.
if ($LoggingEnabled)
{
    Set-PSFLoggingProvider @paramSetPSFLoggingProvider
    Write-PSFMessage -Level Important -Message "---SCRIPT BEGIN---"
    Write-PSFMessage -Level Verbose -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString()), $($PSVersionTable.PSEdition.ToString())$(if([Environment]::Is64BitProcess){$(", 64Bit")}else{$(", 32Bit")})"
    foreach ($moduleInfo in Get-Module)
    {
        Write-PSFMessage -Level Verbose -Message "$($moduleInfo.Name) Module Version: $($moduleInfo.Version)"
    }
}

try
{
    # Initialize Variables
    $CustomWarningMessage = $null
    
    # Get the backup destinations credentials if they don't already exist.
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Obtaining backup destination credentials."}
    if ($null -eq $BackupDestinationCredential)
    {
        # If DestinationCredential_Username is empty in the config then just use the current processes' credential.
        if ([string]::IsNullOrEmpty($Config.Backup.DestinationCredential_Username))
        {
            $BackupDestinationUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $BackupDestinationUserName = $BackupDestinationUserName.Split("\")[1]
        }
        else
        {
            try # Try to decrypt the password in case it's stored as an encrypted standard string.
            {
                $BackupDestinationCredential = New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $($Config.Backup.DestinationCredential_Username), ($($Config.Backup.DestinationCredential_EncryptedPassword) | ConvertTo-SecureString)
            }
            catch # If it's unable to be decrypted it's probably entered in as plain text.
            {
                $BackupDestinationCredential = New-Object -TypeName 'System.Management.Automation.PSCredential' -ArgumentList $($Config.Backup.DestinationCredential_Username), ($($Config.Backup.DestinationCredential_EncryptedPassword) | ConvertTo-SecureString -AsPlainText -Force)
            }
            
            # $CurrentUserName = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Split("\")[1] # Split removes domain from username
            $BackupDestinationUserName = $null
            if ($BackupDestinationCredential.UserName -match '\\')
            {
                $BackupDestinationUserName = $BackupDestinationCredential.UserName.Split("\")[1]
            }

            if ($BackupDestinationCredential.UserName -match '@')
            {
                $BackupDestinationUserName = $BackupDestinationCredential.UserName.Split("@")[0]
            }

            if ($null -eq $BackupDestinationUserName)
            {
                Write-Error "Please make sure that your username is in either [domain]]\username or username@[domain] format."
                Return
            }
        }
    }

    # Set Backup Destination Connection Parameters (credentials only for now)
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Setting backup destination connection parameters."}
    $CmdletParameters = @{}
    if ($null -ne $BackupDestinationCredential) {$CmdletParameters['Credential'] = $BackupDestinationCredential}

    # Delete & Recreate Temporary Working Folder
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Setting up the temporary working folder."}
    $TempPath = $Env:TEMP
    $TempEnvirionmentPath = "$TempPath\_PRTG Backups"
    if (Test-Path $TempEnvirionmentPath)
    {
        Remove-Item -Path $TempEnvirionmentPath -Recurse -Force -Confirm:$false
    }
    New-Item -Path $TempEnvirionmentPath -ItemType Directory -Force | Out-Null

    # Create Copies of Files to Backup
    # Registry
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning registry export."}
    if ($Backup_Registry)
    {
        try
        {
            $RegistryPath = $(if([Environment]::Is64BitOperatingSystem){$('HKLM:\SOFTWARE\Wow6432Node\Paessler\PRTG Network Monitor')}else{$('HKLM:\SOFTWARE\Paessler\PRTG Network Monitor')})
            $RegistryPath_Regedit = Get-Item -Path $RegistryPath | Select-Object -ExpandProperty Name
            $StartProcessParams = @{
                FilePath = "$env:windir\regedit.exe"
                ArgumentList = '/e ' + "`"$TempEnvirionmentPath\PRTG Server Registry.reg`" " + "`"$RegistryPath_Regedit`""
                PassThru = $true
                Wait = $true
            }
            $RegistryBackupResponse = Start-Process @StartProcessParams
        }
        catch
        {
            # Log problem, if logging enabled.
            if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up PRTG Network Monitor registry. Error Message: $_"}
            # Set Email Warning Message.
            $CustomWarningMessage += "`nWARNING: Cannot back up PRTG Network Monitor registry. Error Message: $_"
        }
    }

    # Program
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning program files copy to working folder."}
    $Type = 'Program'
    [array]$ProgramBackupItems = $Config.Backup.$Type
    foreach ($programBackupItem in ($ProgramBackupItems | Get-Member -MemberType NoteProperty))
    {
        if (($ProgramBackupItems.($programBackupItem.Name).GetType().Name -eq 'Boolean') -and ($true -eq $ProgramBackupItems.($programBackupItem.Name))) # Only return 'true' boolean items
        {
            $PathtoBackup = Get-PRTGPath -Item $programBackupItem.Name -Type $Type
            
            # Copy the item to the temporary working folder.
            if ($LoggingEnabled) {Write-PSFMessage -Level Verbose "Copying to temporary working folder: $PathtoBackup"}
            try
            {
                $Subdirectory = $Paths.$($Type).$($programBackupItem.Name)
                Copy-Item -Path $PathtoBackup -Destination $("$TempEnvirionmentPath\$Type\$Subdirectory") -Recurse -Force
                
            }
            catch
            {
                # Log problem, if logging enabled.
                if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"}
                # Set Email Warning Message.
                $CustomWarningMessage += "`nWARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"
            }
        }
    }

    # Data
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning data files copy to working folder."}
    $Type = 'Data'
    [array]$DataBackupItems = $Config.Backup.$Type
    foreach ($dataBackupItem in ($DataBackupItems | Get-Member -MemberType NoteProperty))
    {

        if (($DataBackupItems.($dataBackupItem.Name).GetType().Name -eq 'Boolean') -and ($true -eq $DataBackupItems.($dataBackupItem.Name))) # Only return 'true' boolean items
        {
            # Identify items with special handling (items where we restrict how far back we back them up).
            [string]$ItemType = switch ($dataBackupItem.Name)
            {
                'ConfigurationAutoBackups'  { 'ConfigurationAutoBackups' }
                'LogDatabase'               { 'LogDatabase' }
                'MonitoringDatabase'        { 'MonitoringDatabase' }
                Default                     { 'Standard' }
            }

            if ($ItemType -eq 'Standard')
            {
                $PathtoBackup = Get-PRTGPath -Item $dataBackupItem.Name -Type $Type
                if ($LoggingEnabled) {Write-PSFMessage -Level Verbose "Copying to temporary working folder: $PathtoBackup"}
            
                # Copy the item to the temporary working folder.
                try
                {
                    $Subdirectory = $Paths.$($Type).$($dataBackupItem.Name)
                    Copy-Item -Path $PathtoBackup -Destination $("$TempEnvirionmentPath\$Type\$Subdirectory") -Recurse -Force
                    
                }
                catch
                {
                    # Log problem, if logging enabled.
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"
                }
            }

            if ($ItemType -eq 'ConfigurationAutoBackups')
            {
                $PathtoBackup = Get-PRTGPath -Item $dataBackupItem.Name -Type $Type
                if ($LoggingEnabled) {Write-PSFMessage -Level Verbose "Copying to temporary working folder (latest $Backup_Data_ConfigurationAutoBackups_ItemsToKeep): $PathtoBackup"}
                
                # Copy the item to the temporary working folder.
                try
                {
                    $FilesToCopy = Get-ChildItem -Path $PathtoBackup | Sort-Object -Property LastWriteTime -Descending | Select-Object -First $Backup_Data_ConfigurationAutoBackups_ItemsToKeep
                    $Subdirectory = $Paths.$($Type).$($dataBackupItem.Name)
                    $DestinationFolder = $("$TempEnvirionmentPath\$Type\$Subdirectory")
                    New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null
                    Copy-Item -Path $FilesToCopy.FullName -Destination $DestinationFolder -Force
                    
                }
                catch
                {
                    # Log problem, if logging enabled.
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"
                }
            }

            if ($ItemType -eq 'LogDatabase')
            {
                $PathtoBackup = Get-PRTGPath -Item $dataBackupItem.Name -Type $Type
                if ($LoggingEnabled) {Write-PSFMessage -Level Verbose "Copying to temporary working folder (latest $Backup_Data_LogDatabase_ItemsToKeep): $PathtoBackup"}
                
                # Copy the item to the temporary working folder.
                try
                {
                    $FilesToCopy = Get-ChildItem -Path $PathtoBackup | Sort-Object -Property LastWriteTime -Descending | Select-Object -First $Backup_Data_LogDatabase_ItemsToKeep
                    $Subdirectory = $Paths.$($Type).$($dataBackupItem.Name)
                    $DestinationFolder = $("$TempEnvirionmentPath\$Type\$Subdirectory")
                    New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null
                    Copy-Item -Path $FilesToCopy.FullName -Destination $DestinationFolder -Force
                    
                }
                catch
                {
                    # Log problem, if logging enabled.
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"
                }
            }

            if ($ItemType -eq 'MonitoringDatabase')
            {
                $PathtoBackup = Get-PRTGPath -Item $dataBackupItem.Name -Type $Type
                if ($LoggingEnabled) {Write-PSFMessage -Level Verbose "Copying to temporary working folder (latest $Backup_Data_MonitoringDatabase_ItemsToKeep): $PathtoBackup"}
                
                # Copy the item to the temporary working folder.
                try
                {
                    $FoldersToCopy = Get-ChildItem -Path $PathtoBackup | Sort-Object -Property LastWriteTime -Descending | Select-Object -First $Backup_Data_MonitoringDatabase_ItemsToKeep
                    $Subdirectory = $Paths.$($Type).$($dataBackupItem.Name)
                    $DestinationFolder = $("$TempEnvirionmentPath\$Type\$Subdirectory")
                    New-Item -Path $DestinationFolder -ItemType Directory -Force | Out-Null
                    Copy-Item -Path $FoldersToCopy.FullName -Destination $DestinationFolder -Recurse -Force
                    
                }
                catch
                {
                    # Log problem, if logging enabled.
                    if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"}
                    # Set Email Warning Message.
                    $CustomWarningMessage += "`nWARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"
                }
            }
        }

        # Handle the 'Logs' Data Subfolder
        if ($dataBackupItem.Name -eq 'Logs')
        {
            $LogBackupItems = $($DataBackupItems.Logs)
            foreach ($logBackupItem in $LogBackupItems | Get-Member -MemberType NoteProperty)
            {
                if (($LogBackupItems.($logBackupItem.Name).GetType().Name -eq 'Boolean') -and ($true -eq $LogBackupItems.($logBackupItem.Name))) # Only return 'true' boolean items
                {
                    $PathtoBackup = Get-PRTGPath -Item $logBackupItem.Name -Type $Type -Subtype "Logs"
                    if ($LoggingEnabled) {Write-PSFMessage -Level Verbose "Copying to temporary working folder: $PathtoBackup"}
                
                    # Copy the item to the temporary working folder.
                    try
                    {
                        $Subdirectory = $Paths.$($Type).'Logs'.$($logBackupItem.Name)
                        Copy-Item -Path $PathtoBackup -Destination $("$TempEnvirionmentPath\$Type\$Subdirectory") -Recurse -Force
                        
                    }
                    catch
                    {
                        # Log problem, if logging enabled.
                        if ($LoggingEnabled) {Write-PSFMessage -Level Warning "WARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"}
                        # Set Email Warning Message.
                        $CustomWarningMessage += "`nWARNING: Cannot back up `'$PathtoBackup`'. Error Message: $_"
                    }
                }
            }
        }
    }

    # Copy the backup files from the temporary working Folder to the Backup Destination
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Verifying connection to the backup destination: $Backup_DestinationPath"}
    
    $PSDrive_PRTG = New-PSDrive -Name "PRTG Backup" -PSProvider "FileSystem" -Root $Backup_DestinationPath @CmdletParameters
    # Compress the copied files first, if compression is enabled.
    if ($Backup_Compression_Enabled)
    {
        switch ($Backup_Compression_Tool) {
            'Compress-Archive' {
                $BackupFilename = -join($([System.Environment]::MachineName), ' - ', (Get-Date -Format yyyy-MM-dd" "HHmmss), '.zip')
                $Backup_DestinationPath_Filename = -join($Backup_DestinationPath, '\', $BackupFilename)
                if ($Backup_Compression_StageToTempFolder)
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning backup compression using $Backup_Compression_Tool ($Backup_Compression_Level)."}
                    $Temp_DestinationPath_Filename = -join($TempPath, '\', $BackupFilename)
                    Compress-Archive -Path "$TempEnvirionmentPath\*" -DestinationPath $Temp_DestinationPath_Filename -CompressionLevel $Backup_Compression_Level
                    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Moving the backup file to the backup destination."}
                    Copy-Item -Path "$Temp_DestinationPath_Filename" -Destination $Backup_DestinationPath_Filename -Force
                    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Removing the temporary backup file from the staging directory."}
                    Remove-Item -Path $Temp_DestinationPath_Filename -Force -Confirm:$false
                }
                else
                {
                    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Moving the backup file to the backup destination using $Backup_Compression_Tool ($Backup_Compression_Level)."}
                    Compress-Archive -Path "$TempEnvirionmentPath\*" -DestinationPath $Backup_DestinationPath_Filename -CompressionLevel $Backup_Compression_Level
                }
            }

            '7-Zip' {
                # TODO
            }

            Default { throw "Invalid compression tool configuration value specified." }
        }
    }
    else
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Moving the backup files to the backup destination."}
        $Backup_DestinationPath_Subfolder = -join($Backup_DestinationPath, '\', $([System.Environment]::MachineName), ' - ', (Get-Date -Format yyyy-MM-dd" "HHmmss))
        New-Item -Path $Backup_DestinationPath_Subfolder -ItemType Directory -Force | Out-Null
        Copy-Item -Path "$TempEnvirionmentPath\*" -Destination $Backup_DestinationPath_Subfolder -Recurse -Force 
    }

    # Remove Outdated Backups
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Removing outdated backups."}
    $AllBackups = Get-ChildItem -Path $Backup_DestinationPath | Sort-Object -Property LastWriteTime -Descending
    $NumberOfBackupsToDelete = ($AllBackups.Count - $BackupsToKeep)
    if ($NumberOfBackupsToDelete -lt 0) {$NumberOfBackupsToDelete = 0}
    $BackupsToDelete = $AllBackups | Select-Object -Last $NumberOfBackupsToDelete
    if ([string]::IsNullOrEmpty($BackupsToDelete))
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Verbose -Message "No outdated backups to delete."}
    }
    else
    {
        Remove-Item -Path $BackupsToDelete.FullName -Recurse -Force -Confirm:$false
    }
            
    # Cleanup
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning script cleanup."}

    # Remove all temporary files, if they exist.
    try
    {
        Remove-Item -Path $TempEnvirionmentPath -Recurse -Force -Confirm:$false
    }
    catch
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Warning -Message "Unable to delete temporary files: $_"}
    }
    
    # Disconnect PSDrive, if Connected
    try 
    {
        if (-not ([string]::IsNullOrEmpty($PSDrive_PRTG)))
        {
            if ((Get-PSDrive -Name "$PSDrive_PRTG" -ErrorAction SilentlyContinue).Count -gt 0)
            {
                Remove-PSDrive -Name $PSDrive_PRTG -Force -Confirm:$false
            }
        }
    }
    catch
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Warning -Message "Unable to disconnect PSDrive connection: $_"}
    }

    # Email Warning Message, if Enabled
    If ($MessageOnWarning -and $null -ne $CustomWarningMessage)
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning warning email creation."}
        # Get Rid of Extra Line at Beginning
        $CustomWarningMessage = $CustomWarningMessage.Trim()

        # Try to Email Alert Message On Warning
        try
        {
            $MessageArguments = @{
                Service = $MessageServices
                Type = $MessageTypes
                From = $MessageFrom
                ReplyTo = $MessageReplyTo
                To = $MessageTo
                CC = $MessageCC
                BCC = $MessageBCC
                SaveToSentItems = $MessageSaveToSentItems
                Sender = $MessageSender
                Subject = "$ScriptName Script - Warning"
                Body = "The '$ScriptName' script has detected at least one non-critical issue:`n`n$CustomWarningMessage`n`nThank you,`nThe IT Team"
                Attachment = $null # No attachments because we don't want anything to accidentally prevent the alert email from being sent.
            }
           
            # Send Warning Message Alert
            $SendEmailMessageResult = Send-ScriptMessage @MessageArguments

            # Check Results
            if ($SendEmailMessageResult.Status -eq $true)
            {
                if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Email alert (Script Warning) sent successfully to: $($SendEmailMessageResult.Recipients.All -join '; ')"}
            }
            else
            {
                Write-PSFMessage -Level Error -Message "Email Alert (Script Warning): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_
            }
        }
        catch
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "There has been an error emailing the warning alert message: $_" -Tag 'Failure' -ErrorRecord $_}
        }
    }

    # End Logging Message
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "---SCRIPT END---"}
    if ($LoggingEnabled) {Wait-PSFMessage} # Make Sure Logging Is Flushed Before Terminating
}
catch
{
    if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "Error Running Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber))" -Tag 'Failure' -ErrorRecord $_}

    # Email Error Message, if Enabled
    if ($MessageOnError)
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Beginning error email creation."}

        # Try to Email Alert Message On Error
        try
        {
            $MessageArguments = @{
                Service = $MessageServices
                Type = $MessageTypes
                From = $MessageFrom
                ReplyTo = $MessageReplyTo
                To = $MessageTo
                CC = $MessageCC
                BCC = $MessageBCC
                SaveToSentItems = $MessageSaveToSentItems
                Sender = $MessageSender
                Subject = "$ScriptName Script - Error"
                Body = "There has been an error running the '$ScriptName' Script (Name: `"$($_.InvocationInfo.ScriptName)`" | Line: $($_.InvocationInfo.ScriptLineNumber)):`n`n$_`n`nThank you,`nThe IT Team"
                Attachment = $null # No attachments because we don't want anything to accidentally prevent the alert email from being sent.
            }
            
            # Send Error Message Alert
            $SendEmailMessageResult = Send-ScriptMessage @MessageArguments

            # Check Results
            if ($SendEmailMessageResult.Status -eq $true)
            {
                if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "Email alert (Script Error) sent successfully to: $($SendEmailMessageResult.Recipients.All -join '; ')"}
            }
            else
            {
                Write-PSFMessage -Level Error -Message "Email Alert (Script Error): Unable to send: $($SendEmailMessageResult.Error)" -Tag 'Failure' -ErrorRecord $_
            }
        }
        catch
        {
            if ($LoggingEnabled) {Write-PSFMessage -Level Error -Message "There has been an error emailing the error alert message: $_" -Tag 'Failure' -ErrorRecord $_}
        }
    }

    # Cleanup
    if ($LoggingEnabled){Write-PSFMessage -Level Important -Message "Beginning script cleanup."}
    
    # Remove all temporary files, if they exist.
    try
    {
        Remove-Item -Path $TempEnvirionmentPath -Recurse -Force -Confirm:$false
    }
    catch
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Warning -Message "Unable to delete temporary files: $_"}
    }
    
    # Disconnect PSDrive, if Connected
    try 
    {
        if (-not ([string]::IsNullOrEmpty($PSDrive_PRTG)))
        {
            if ((Get-PSDrive -Name "$PSDrive_PRTG" -ErrorAction SilentlyContinue).Count -gt 0)
            {
                Remove-PSDrive -Name $PSDrive_PRTG -Force -Confirm:$false
            }
        }
    }
    catch
    {
        if ($LoggingEnabled) {Write-PSFMessage -Level Warning -Message "Unable to disconnect PSDrive connection: $_"}
    }
    
    # End Logging Message
    if ($LoggingEnabled) {Write-PSFMessage -Level Important -Message "---SCRIPT END---"}
    if ($LoggingEnabled) {Wait-PSFMessage} # Make Sure Logging Is Flushed Before Terminating
}
