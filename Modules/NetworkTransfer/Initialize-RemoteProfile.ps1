<#
========================================================================================================
    Title:          Win11Migrator - Remote Profile Initializer
    Filename:       Initialize-RemoteProfile.ps1
    Description:    Creates or resolves a user profile on the target machine for direct network migration.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.1.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Creates or resolves a user profile on the target machine.
.DESCRIPTION
    Checks whether the specified user already has a profile on the target by probing
    the UNC admin share (\\ComputerName\C$\Users\TargetUser). This approach works
    with just admin share access and does NOT require WinRM/PSRemoting.
    If the profile directory exists, it is used as-is (overwrite mode).
    If not, the function creates the directory structure via UNC.
.PARAMETER ComputerName
    Hostname or IP address of the target computer.
.PARAMETER Credential
    PSCredential for authenticating to the target machine.
.PARAMETER TargetUserName
    The username whose profile should be resolved or created on the target.
.OUTPUTS
    [hashtable] With ProfilePath, ProfileExists, Created, ErrorMessage keys.
.EXAMPLE
    $cred = Get-Credential
    $profile = Initialize-RemoteProfile -ComputerName 'TARGET-PC' -Credential $cred -TargetUserName 'john'
#>

function Initialize-RemoteProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [Parameter(Mandatory)]
        [string]$TargetUserName
    )

    Write-MigrationLog -Message "Initializing remote profile for '$TargetUserName' on '$ComputerName'" -Level Info

    $result = @{
        ProfilePath   = ''
        ProfileExists = $false
        Created       = $false
        ErrorMessage  = ''
    }

    # Map a temporary PSDrive with credentials for UNC access
    $driveName = "MigratorProf_$(Get-Random)"
    $uncRoot = "\\$ComputerName\C`$"

    try {
        $null = New-PSDrive -Name $driveName -PSProvider FileSystem -Root $uncRoot -Credential $Credential -ErrorAction Stop
        Write-MigrationLog -Message "Mapped drive to $uncRoot for profile check" -Level Debug
    } catch {
        $result.ErrorMessage = "Cannot access admin share on '$ComputerName': $($_.Exception.Message)"
        Write-MigrationLog -Message $result.ErrorMessage -Level Error
        return $result
    }

    try {
        # -----------------------------------------------------------------
        # 1. Check if user profile directory exists via UNC
        # -----------------------------------------------------------------
        $uncUsersDir = "${driveName}:\Users"
        $uncProfilePath = Join-Path $uncUsersDir $TargetUserName

        if (Test-Path $uncProfilePath) {
            # Profile exists — use it as-is (overwrite mode)
            $result.ProfilePath   = "C:\Users\$TargetUserName"
            $result.ProfileExists = $true
            Write-MigrationLog -Message "Existing profile found for '$TargetUserName' at '$($result.ProfilePath)'" -Level Info
        } else {
            # -----------------------------------------------------------------
            # 2. Profile doesn't exist — scan Users directory for case variations
            # -----------------------------------------------------------------
            Write-MigrationLog -Message "No exact match for '$TargetUserName', scanning Users directory" -Level Debug
            $existingUsers = Get-ChildItem -Path $uncUsersDir -Directory -ErrorAction SilentlyContinue
            $matched = $existingUsers | Where-Object { $_.Name -ieq $TargetUserName } | Select-Object -First 1

            if ($matched) {
                $result.ProfilePath   = "C:\Users\$($matched.Name)"
                $result.ProfileExists = $true
                Write-MigrationLog -Message "Profile found (case-insensitive) for '$TargetUserName' as '$($matched.Name)'" -Level Info
            }
        }

        # -----------------------------------------------------------------
        # 3. Verify standard subdirectories exist, create any that are missing
        # -----------------------------------------------------------------
        if ($result.ProfileExists) {
            # Profile exists — ensure standard subdirectories are present
            $subDirs = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos',
                         'AppData', 'AppData\Local', 'AppData\Roaming', 'AppData\LocalLow')
            foreach ($sub in $subDirs) {
                $subPath = Join-Path $uncProfilePath $sub
                if (-not (Test-Path $subPath)) {
                    New-Item -Path $subPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }
            }
            Write-MigrationLog -Message "Profile directory verified with standard subdirectories" -Level Debug
        } else {
            # -----------------------------------------------------------------
            # 4. Create new profile directory structure
            # -----------------------------------------------------------------
            Write-MigrationLog -Message "Creating new profile directory for '$TargetUserName'" -Level Info
            try {
                New-Item -Path $uncProfilePath -ItemType Directory -Force -ErrorAction Stop | Out-Null

                $subDirs = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos',
                             'AppData', 'AppData\Local', 'AppData\Roaming', 'AppData\LocalLow')
                foreach ($sub in $subDirs) {
                    $subPath = Join-Path $uncProfilePath $sub
                    New-Item -Path $subPath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                }

                $result.ProfilePath = "C:\Users\$TargetUserName"
                $result.Created = $true
                Write-MigrationLog -Message "Created profile directory at '$($result.ProfilePath)'" -Level Info
            } catch {
                $result.ErrorMessage = "Failed to create profile directory: $($_.Exception.Message)"
                Write-MigrationLog -Message $result.ErrorMessage -Level Error
            }
        }
    } catch {
        $result.ErrorMessage = "Failed to check/create remote profile: $($_.Exception.Message)"
        Write-MigrationLog -Message $result.ErrorMessage -Level Error
    } finally {
        Remove-PSDrive -Name $driveName -Force -ErrorAction SilentlyContinue
    }

    return $result
}
