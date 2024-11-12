<#
    .SYNOPSIS
    Backs Up Microsoft Entra Conditional Access

    .DESCRIPTION
    Creates JSON file backups for each Conditional Access Policy, Named Location, Authentication Context, & Authentication Strength.
    Requires: Microsoft.Graph PowerShell Module (https://learn.microsoft.com/en-us/powershell/microsoftgraph/)
    Conditional Access Documentation: https://learn.microsoft.com/en-us/entra/identity/conditional-access/overview
#>

# Set Backup Parent Path
$BackupsParentPath = "$([Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile))\Downloads"

# Stop On Errors
$ErrorActionPreference = 'Stop'

# Set Invalid Filename Characters, Replacement Value, & Max FullName File Path Lenth
[char[]]$InvalidFileNameCharacters = [System.IO.Path]::GetInvalidFileNameChars()
$ReplacementFileNameCharacter = '_'
$MaxPathLength = 260

# Connect To Microsoft Graph & Get Connection Context
$MicrosoftGraphScopes = @(
    'Policy.Read.All'
)
Connect-MgGraph -Scopes $MicrosoftGraphScopes
$MGContext = Get-MgContext

###############################
# Conditional Access Policies #
###############################

# Write-Host Backup Category
Write-Host -ForegroundColor Magenta -Message "`nConditional Access Policies"

# Collect Conditional Access Policies
$CAPolicies = Get-MgIdentityConditionalAccessPolicy -All

# Set & Create Backup Path If Necessary
$BackupPath = "$BackupsParentPath\Entra Backups\$($MGContext.TenantId)\Conditional Access\Policies"
if (-not (Test-Path -Path $BackupPath))
{
    $null = New-Item -Path $BackupPath -ItemType Directory
}

# Get Maximum Filename Length
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

######################################
# Conditional Access Named Locations #
######################################

# Write-Host Backup Category
Write-Host -ForegroundColor Magenta -Message "`nConditional Access Named Locations"

# Collect Conditional Access Named Locations
$CAPolicies = Get-MgIdentityConditionalAccessNamedLocation

# Set & Create Backup Path If Necessary
$BackupPath = "$BackupsParentPath\Entra Backups\$($MGContext.TenantId)\Conditional Access\Named Locations"
if (-not (Test-Path -Path $BackupPath))
{
    $null = New-Item -Path $BackupPath -ItemType Directory
}

# Get Maximum Filename Length
[int32]$MaxFileNameLength = $MaxPathLength - ($BackupPath.Length + 1) # Add 1 for the in-between backslash

# Process Each Conditional Access Named Location
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

##############################################
# Conditional Access Authentication Contexts #
##############################################

# Write-Host Backup Category
Write-Host -ForegroundColor Magenta -Message "`nConditional Access Authentication Contexts"

# Collect Conditional Access Authentication Contexts
$CAPolicies = Get-MgIdentityConditionalAccessAuthenticationContextClassReference

# Set & Create Backup Path If Necessary
$BackupPath = "$BackupsParentPath\Entra Backups\$($MGContext.TenantId)\Conditional Access\Authentication Contexts"
if (-not (Test-Path -Path $BackupPath))
{
    $null = New-Item -Path $BackupPath -ItemType Directory
}

# Get Maximum Filename Length
[int32]$MaxFileNameLength = $MaxPathLength - ($BackupPath.Length + 1) # Add 1 for the in-between backslash

# Process Each Conditional Access Authentication Context
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

###############################################
# Conditional Access Authentication Strengths #
###############################################

# Write-Host Backup Category
Write-Host -ForegroundColor Magenta -Message "`nConditional Access Authentication Strengths"

# Collect Conditional Access Authentication Strengths
$CAPolicies = Get-MgPolicyAuthenticationStrengthPolicy

# Set & Create Backup Path If Necessary
$BackupPath = "$BackupsParentPath\Entra Backups\$($MGContext.TenantId)\Conditional Access\Authentication Strengths"
if (-not (Test-Path -Path $BackupPath))
{
    $null = New-Item -Path $BackupPath -ItemType Directory
}

# Get Maximum Filename Length
[int32]$MaxFileNameLength = $MaxPathLength - ($BackupPath.Length + 1) # Add 1 for the in-between backslash

# Process Each Conditional Access Authentication Strength
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