<#
    .SYNOPSIS
    Backs Up Microsoft Entra Conditional Access Policies

    .DESCRIPTION
    Creates JSON file backups for each Conditional Access policy.
    Conditional Access Documentation: https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview
#>

# Set Backup Parent Path
$BackupsParentPath = "$([Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile))\Downloads"

# Stop On Errors
$ErrorActionPreference = 'Stop'

# Connect To Microsoft Graph & Collect Conditional Access Policies
$MicrosoftGraphScopes = @(
    'Policy.Read.All'
)
Connect-MgGraph -Scopes $MicrosoftGraphScopes
$CAPolicies = Get-MgIdentityConditionalAccessPolicy -All
$MGContext = Get-MgContext

# Set & Create Backup Path If Necessary
$BackupPath = "$BackupsParentPath\Entra Backups\$($MGContext.TenantId)\Conditional Access Policies"
if (-not (Test-Path -Path $BackupPath))
{
    $null = New-Item -Path $BackupPath -ItemType Directory
}

# Set Invalid Filename Characters & Replacement Value
[char[]]$InvalidFileNameCharacters = [System.IO.Path]::GetInvalidFileNameChars()
$ReplacementFileNameCharacter = '_'

# Get Maximum Filename Length
$MaxPathLength = 260
[int32]$MaxFileNameLength = $MaxPathLength - ($BackupPath.Length + 1) # Add 1 for the in-between backslash

# Process Each Conditional Access Policy
foreach ($cAPolicy in $CAPolicies)
{
    # Remove Invalid Filename Characters
    $BackupFileName = "$($cAPolicy.DisplayName).json"
    $BackupFileName = $BackupFileName.Split($InvalidFileNameCharacters) -join $ReplacementFileNameCharacter

    # Adjust Filename If Path is Too Long
    $BackupFileNameLength = $BackupFileName.Length
    if ($BackupFileNameLength -gt $MaxFileNameLength)
    {
        $BackupFileNameLeafBase = $(Split-Path -Path $BackupFileName -LeafBase)
        $BackupFileNameExtension = $(Split-Path -Path $BackupFileName -Extension)
        $BackupFileNameExtensionLength = $BackupFileNameExtension.Length
        $BackupFileName = $($BackupFileNameLeafBase).Substring(0,($MaxFileNameLength - $BackupFileNameExtensionLength)) + $($BackupFileNameExtension)
    }
    
    # Create JSON File (Do Not Overwrite Existing Files)
    $cAPolicy | ConvertTo-Json -Depth 100 | Out-File -FilePath "$BackupPath\$BackupFileName" -NoClobber

    # Write-Host Each Backup File FullName Path 
    Write-Host -ForegroundColor Blue -Message ("$BackupPath\$BackupFileName")
}