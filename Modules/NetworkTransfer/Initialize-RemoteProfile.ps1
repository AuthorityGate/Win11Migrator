<#
========================================================================================================
    Title:          Win11Migrator - Remote Profile Initializer
    Filename:       Initialize-RemoteProfile.ps1
    Description:    Creates or resolves a user profile on the target machine for direct network migration.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 27, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Creates or resolves a user profile on the target machine.
.DESCRIPTION
    Establishes a PSSession to the target computer and checks whether the specified
    user already has a profile. If the profile exists, its path and SID are resolved.
    If not, the function attempts to create the profile directory structure on the
    target machine so that migration data can be pushed to it.
.PARAMETER ComputerName
    Hostname or IP address of the target computer.
.PARAMETER Credential
    PSCredential for authenticating to the target machine.
.PARAMETER TargetUserName
    The username whose profile should be resolved or created on the target.
.OUTPUTS
    [hashtable] With ProfilePath, UserSID, ProfileExists, Created, ErrorMessage keys.
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
        UserSID       = ''
        ProfileExists = $false
        Created       = $false
        ErrorMessage  = ''
    }

    $session = $null
    try {
        # -----------------------------------------------------------------
        # 1. Establish PSSession to target
        # -----------------------------------------------------------------
        Write-MigrationLog -Message "Establishing PSSession to '$ComputerName'" -Level Debug
        $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
        Write-MigrationLog -Message "PSSession established to '$ComputerName'" -Level Info

        # -----------------------------------------------------------------
        # 2. Check if user profile exists via remote registry
        # -----------------------------------------------------------------
        Write-MigrationLog -Message "Checking for existing profile for '$TargetUserName'" -Level Debug
        $remoteResult = Invoke-Command -Session $session -ScriptBlock {
            param($userName)

            $profileInfo = @{
                ProfilePath   = ''
                UserSID       = ''
                ProfileExists = $false
            }

            # Enumerate profile list from registry
            $profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
            $profileKeys = Get-ChildItem -Path $profileListPath -ErrorAction SilentlyContinue

            foreach ($key in $profileKeys) {
                $sid = Split-Path $key.PSPath -Leaf
                $profileImagePath = (Get-ItemProperty -Path $key.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath

                if ($profileImagePath) {
                    $profileName = Split-Path $profileImagePath -Leaf
                    if ($profileName -eq $userName) {
                        $profileInfo.ProfilePath   = $profileImagePath
                        $profileInfo.UserSID       = $sid
                        $profileInfo.ProfileExists = $true
                        break
                    }
                }
            }

            # Also check by matching against local/domain accounts
            if (-not $profileInfo.ProfileExists) {
                try {
                    $account = New-Object System.Security.Principal.NTAccount($userName)
                    $sidObj  = $account.Translate([System.Security.Principal.SecurityIdentifier])
                    $sidStr  = $sidObj.Value

                    foreach ($key in $profileKeys) {
                        $keySid = Split-Path $key.PSPath -Leaf
                        if ($keySid -eq $sidStr) {
                            $profileInfo.ProfilePath   = (Get-ItemProperty -Path $key.PSPath -Name 'ProfileImagePath' -ErrorAction SilentlyContinue).ProfileImagePath
                            $profileInfo.UserSID       = $sidStr
                            $profileInfo.ProfileExists = $true
                            break
                        }
                    }
                } catch {
                    # Account SID resolution failed
                }
            }

            return $profileInfo
        } -ArgumentList $TargetUserName -ErrorAction Stop

        $result.ProfilePath   = $remoteResult.ProfilePath
        $result.UserSID       = $remoteResult.UserSID
        $result.ProfileExists = $remoteResult.ProfileExists

        # -----------------------------------------------------------------
        # 3. If profile exists, confirm path is valid
        # -----------------------------------------------------------------
        if ($result.ProfileExists) {
            Write-MigrationLog -Message "Profile found for '$TargetUserName' at '$($result.ProfilePath)' (SID: $($result.UserSID))" -Level Info

            # Verify path exists on remote
            $pathExists = Invoke-Command -Session $session -ScriptBlock {
                param($path)
                Test-Path $path
            } -ArgumentList $result.ProfilePath -ErrorAction Stop

            if (-not $pathExists) {
                Write-MigrationLog -Message "Profile registry entry exists but path '$($result.ProfilePath)' is missing, will recreate" -Level Warning
                $result.ProfileExists = $false
            }
        }

        # -----------------------------------------------------------------
        # 4. If profile doesn't exist, create the directory structure
        # -----------------------------------------------------------------
        if (-not $result.ProfileExists) {
            Write-MigrationLog -Message "No existing profile for '$TargetUserName', creating directory structure" -Level Info

            $createResult = Invoke-Command -Session $session -ScriptBlock {
                param($userName)

                $profileBase = "$env:SystemDrive\Users\$userName"
                $created     = $false
                $errorMsg    = ''

                try {
                    if (-not (Test-Path $profileBase)) {
                        New-Item -Path $profileBase -ItemType Directory -Force | Out-Null
                    }

                    # Create standard profile subdirectories
                    $subDirs = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Music', 'Videos',
                                 'AppData', 'AppData\Local', 'AppData\Roaming', 'AppData\LocalLow')
                    foreach ($sub in $subDirs) {
                        $subPath = Join-Path $profileBase $sub
                        if (-not (Test-Path $subPath)) {
                            New-Item -Path $subPath -ItemType Directory -Force | Out-Null
                        }
                    }

                    $created = $true
                } catch {
                    $errorMsg = $_.Exception.Message
                }

                return @{
                    ProfilePath = $profileBase
                    Created     = $created
                    ErrorMessage = $errorMsg
                }
            } -ArgumentList $TargetUserName -ErrorAction Stop

            $result.ProfilePath  = $createResult.ProfilePath
            $result.Created      = $createResult.Created
            $result.ErrorMessage = $createResult.ErrorMessage

            if ($result.Created) {
                Write-MigrationLog -Message "Created profile directory structure at '$($result.ProfilePath)'" -Level Info
            } else {
                Write-MigrationLog -Message "Failed to create profile: $($result.ErrorMessage)" -Level Error
            }
        }

    } catch {
        $result.ErrorMessage = "Failed to initialize remote profile: $($_.Exception.Message)"
        Write-MigrationLog -Message $result.ErrorMessage -Level Error
    } finally {
        # -----------------------------------------------------------------
        # 5. Clean up PSSession
        # -----------------------------------------------------------------
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            Write-MigrationLog -Message "PSSession to '$ComputerName' closed" -Level Debug
        }
    }

    return $result
}
