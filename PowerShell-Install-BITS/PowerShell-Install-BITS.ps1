# Install SP7 Firmware

# Copyright © 2020 The Grim Admin (https://www.grimadmin.com)
# This code is licensed under the MIT license
# This software is provided 'as-is', without any express or implied warranties whatsoever.
# In no event will the authors, partners or contributors be held liable for any damages,
# claims or other liabilities direct or indirect, arising from the use of this software.

# DEBUGGING - Transcript Start
# Start-Transcript -Path "C:\TempPath\$(get-date -f "yyyy.MM.dd-HH.mm.ss")-HelpMe.txt" -Force

# Source File Information
$FileName = '2020-09-26 - SurfacePro7_Win10_18362_20.082.25905.0.msi'
$SourceFile = 'http://server.domain.com/customupdates/' + $FileName
$SourceFileHashSHA256 = 'F9602F61E57B9EB11939B2B7C23F380C4EFCD0906C544ED02C93C4AD8F6ADF9E'
$SourceProductName = 'Surface Pro 7 Update' # Partial Name is Fine as Long as it is Unique enough for a match
$SourceProductVersion = '20.082.25905.0'

# Destination File Information
$DestinationFolder = 'C:\SurfaceUpdate\'
$DestinationFile = $DestinationFolder + $FileName

# Set BITS Job Name
$BITSJobName = $SourceProductName

# Installed Log File Central Repository
# MAKE SURE THIS ALREADY EXISTS AND CAN BE WRITTEN TO BY THE PRINCIPLE (ACCOUNT)
# USED TO RUN THE SCRIPT (e.g., DOMAIN COMPUTERS)
$InstalledLogFileCentralRepository = $PSScriptRoot + '\Install Logs'

# FUNCTIONS
function Remove-BITSJobs
{
    param (
        [Parameter(Mandatory=$true)]
        [string]$DisplayName
    )

    $BITSJobs = Get-BITSTransfer | Where-Object 'DisplayName' -like $DisplayName
    $BITSJobs | Remove-BitsTransfer 
}

# DEBUGGING - Clear All BITS Jobs
# Remove-BITSJobs -DisplayName $BITSJobName

# Get a Listing of Installed Applications From the Registry
$InstalledApplicationsFromRegistry = @()
$InstalledApplicationsFromRegistry += Get-ItemProperty "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" # x86 Apps
$InstalledApplicationsFromRegistry += Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" # x64 Apps

# Is the Update Already Installed? If So, Copy the Log File Over,
## Commented out the alternative 'Win32_Product' way of looking for installed applications. Please see the following article for more information:
## https://www.grimadmin.com/article.php/powershell-check-program-update-installed-download-bits-install
## if (Get-CimInstance -Class Win32_Product | Where-Object {$_.Name -match $SourceProductName -and $_.Version -eq $SourceProductVersion}) # Win32_Product
if ($InstalledApplicationsFromRegistry | Where-Object {$_.DisplayName -match $SourceProductName -and $_.DisplayVersion -eq $SourceProductVersion})
{
    Write-Host "$SourceProductName ($SourceProductVersion) is already installed."

    # Try Creating Central Repository Log File if it Doesn't Already Exist and there is a file to copy over
    $CentralRepositoryLogFilePath = "$InstalledLogFileCentralRepository\$env:COMPUTERNAME.log"

    # Get Latest Log File But Only if the Destinatio Folder Exists
    $LatestLogFile = $null
    if (Test-Path -Path $DestinationFolder)
    {
        $LatestLogFile = Get-ChildItem $DestinationFolder | Where-Object Extension -eq '.log' | Sort-Object -Descending -Property 'LastWriteTime' | Select-Object -First 1
    }

    # Copy the log file if it exists
    if ((-Not (Test-Path -Path $CentralRepositoryLogFilePath)) -and ($null -ne $LatestLogFile))
    {
        Write-Host "Writing Log File to: $CentralRepositoryLogFilePath"
        Copy-Item -Path $LatestLogFile.VersionInfo.FileName -Destination $CentralRepositoryLogFilePath
    }

    # Exit the Script
    exit
}

# Is the Update File Already Downloaded?
if (Test-Path -Path $DestinationFile)
{
    # Check File Hash
    $DownloadedFileHash = Get-FileHash -Algorithm SHA256 -Path $DestinationFile | Select-Object -ExpandProperty 'Hash' 
    if ($DownloadedFileHash -eq $SourceFileHashSHA256)
    {
        # Install It Then Exit
        $DataStamp = get-date -Format yyyy-MM-dd-THHmmss
        $InstallLogFile = $DestinationFolder + '{0} - {1}.log' -f $DataStamp,$SourceProductName
        Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$DestinationFile`" /qn /norestart /l*v `"$InstallLogFile`"" -Wait -NoNewWindow
        exit
    }
    else
    {
        # Something is unfortunately wrong with the file. Delete it.
        Remove-Item -Path $DestinationFile -Force
    }
}

# Import BITSTransfer Module
Import-Module BITSTransfer
if (!(Get-Module -Name "BITSTransfer"))
{
   # module is not loaded
   Write-Error "Error loading the BITSTransfer Module"
   exit
}

# Create Destination Folder if Necessary
New-Item -ItemType Directory -Path $DestinationFolder -Force | Out-Null
if (-Not (Test-Path -Path $DestinationFolder))
{
    Write-Error "Cannot Create Destination Folder"
    exit
}

# See if there is already a job
$CurrentJob = Get-BITSTransfer | Where-Object 'DisplayName' -like $BitsJobName

# Reset if for some reason there is more than one job
if ($CurrentJob.Count -gt 1)
{
    Write-Host "Clearing out old $BITSJobName jobs"
    Remove-BITSJobs -DisplayName $BITSJobName

    # Null out $CurrentJob to reset the count to 0
    $CurrentJob = $null
}

# Start New Job If None Exist, otherwise attempt to resume 
if ($CurrentJob.Count -eq 0)
{
    Start-BITSTransfer -Source $SourceFile -Destination $DestinationFile -DisplayName $BITSJobName -Priority Low -Asynchronous
    $NextStep = 'WaitThenCheck'
}
else
{
    # Do Something Based on Job Status
    $CurrentJob = Get-BITSTransfer | Where-Object 'DisplayName' -like $BitsJobName
    switch ($CurrentJob.JobState)
    {
        'Transferred' {Complete-BitsTransfer -BitsJob $CurrentJob; $NextStep = 'Install'} # Renames the temporary download file to its final destination name and removes the job from the queue.
        'TransientError' {$NextStep = 'WaitThenCheck'} # No action needed. It will try again in a bit or eventually time out and goes to fatal error state.
        'Transferring' {$NextStep = 'WaitThenCheck'} # No action needed. It's currently downloading.
        'Connecting' {$NextStep = 'WaitThenCheck'} # No action needed. It's currently connecting.
        'Queued' {$NextStep = 'WaitThenCheck'} # No action needed. Specifies that the job is in the queue, and waiting to run. If a user logs off while their job is transferring, the job transitions to the queued state.
        'Suspended' {Resume-BitsTransfer -BitsJob $CurrentJob -Asynchronous; $NextStep = 'WaitThenCheck'}
        'Error' {Resume-BitsTransfer -BitsJob $CurrentJob -Asynchronous; $NextStep = 'WaitThenCheck'}
        Default {Write-Host "Current BITS job state is: $CurrentJob.JobState"; Write-Error "Unexpected job state."; exit} # The only two other options are Acknowledged & Cancelled and neither of these should appear. If they do exit.
    }
}

# Wait For Download to Complete or Error Out
$ErrorCheckCount = 0
$MaxAllowedErrorChecks = 10
while ($NextStep -eq 'WaitThenCheck')
{
    # Exit If Job Not Leaving Error State
    if ($ErrorCheckCount -ge $MaxAllowedErrorChecks)
    {
        Write-Error "Job remains in error state after $ErrorCheckCount attempts. Exiting."
        exit
    }
    
    # Wait for 60 seconds
    Start-Sleep -Seconds 60

    # Do Something Based on Job Status
    $CurrentJob = Get-BITSTransfer | Where-Object 'DisplayName' -like $BitsJobName
    switch ($CurrentJob.JobState)
    {
        'Transferred' {Complete-BitsTransfer -BitsJob $CurrentJob; $NextStep = 'Install'} # Renames the temporary download file to its final destination name and removes the job from the queue.
        'TransientError' {} # No action needed. It will try again in a bit or eventually time out and goes to fatal error state.
        'Transferring' {} # No action needed. It's currently downloading.
        'Connecting' {} # No action needed. It's currently connecting.
        'Queued' {} # No action needed. Specifies that the job is in the queue, and waiting to run. If a user logs off while their job is transferring, the job transitions to the queued state.
        'Suspended' {Resume-BitsTransfer -BitsJob $CurrentJob -Asynchronous}
        'Error' {Resume-BitsTransfer -BitsJob $CurrentJob -Asynchronous; $ErrorCheckCount += 1}
        Default {Write-Host "Current BITS job state is: $CurrentJob.JobState"; Write-Error "Unexpected job state."; exit} # The only two other options are Acknowledged & Cancelled and neither of these should appear. If they do, exit with error.
    }
}

# Install the Update
if ($NextStep -eq 'Install')
{
    # Sleep 10 Seconds Just in Case the File Rename Isn't Complete Yet.
    Start-Sleep -Seconds 10

    # Install It
    if (Test-Path -Path $DestinationFile)
    {
        # Check File Hash
        $DownloadedFileHash = Get-FileHash -Algorithm SHA256 -Path $DestinationFile | Select-Object -ExpandProperty 'Hash' 
        if ($DownloadedFileHash -eq $SourceFileHashSHA256)
        {
            # Install It Then Exit
            $DataStamp = get-date -Format yyyy-MM-dd-THHmmss
            $InstallLogFile = $DestinationFolder + '{0} - {1}.log' -f $DataStamp,$SourceProductName
            Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i `"$DestinationFile`" /qn /norestart /l*v `"$InstallLogFile`"" -Wait -NoNewWindow
            exit
        }
        else
        {
            # Something is unfortunately wrong with the file. Delete it.
            Remove-Item -Path $DestinationFile -Force
        }
    }
}

# DEBUGGING - Transcript Stop
# Stop-Transcript
