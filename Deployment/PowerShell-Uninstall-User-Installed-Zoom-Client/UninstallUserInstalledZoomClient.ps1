# Check if Zoom is installed by IT Department.
# 32-Bit.
$DeployedBinaryPath32 = [Environment]::GetFolderPath("ProgramFilesX86") + '\Zoom\bin\Zoom.exe'
# 64-bit.
$DeployedBinaryPath64 = [Environment]::GetFolderPath("ProgramFiles") + '\Zoom\bin\Zoom.exe'

if ((Test-Path -LiteralPath $DeployedBinaryPath32) -or (Test-Path -LiteralPath $DeployedBinaryPath64))
{
    Write-Verbose "Deployed Version Installed. Will attempt to remove user-installed version of Zoom."
}
else
{
    Write-Verbose "Deployed Version Not Installed. Exiting..."
    Exit 
}

# Set Variables for User-Installed Zoom.
$UserInstalledInstallerPath = [Environment]::GetFolderPath("ApplicationData") + '\Zoom\uninstall\Installer.exe'
$UserInstalledBinaryPath = [Environment]::GetFolderPath("ApplicationData") + '\Zoom\bin\Zoom.exe'
# $UserInstalledStartMenuPath = [Environment]::GetFolderPath("StartMenu") + '\Programs\Zoom'

# Check if Zoom is installed by User.
if (Test-Path -LiteralPath $UserInstalledInstallerPath)
{
    # End User-Installed Zoom Process If Running (in case it starts at boot).
    if (Get-Process -Name "Zoom" -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $UserInstalledBinaryPath})
    {
        Write-Verbose "User-Installed Zoom Process is Running. Will attempt to end process."
        (Get-Process -Name "Zoom" -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq $UserInstalledBinaryPath}) | Stop-Process
        Start-Sleep -Seconds 5 # Give time to end before moving on.
    }

    # Uninstall User-Installed Zoom.
    Start-Process -FilePath $UserInstalledInstallerPath -ArgumentList "/uninstall" -WindowStyle Hidden
}

# Fix Handlers.
Remove-Item -Path "HKCU:\Software\Classes\ZoomLauncher" -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Classes\zoommtg" -Force -Recurse -ErrorAction SilentlyContinue
