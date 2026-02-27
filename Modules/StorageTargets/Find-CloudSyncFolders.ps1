<#
========================================================================================================
    Title:          Win11Migrator - Cloud Sync Folder Locator
    Filename:       Find-CloudSyncFolders.ps1
    Description:    Locates OneDrive and Google Drive sync folder paths on the local machine.
    Author:         Kevin Komlosy
    Company:        AuthorityGate Inc.
    Version:        1.0.0
    Date:           February 26, 2026

    License:        MIT License (GitHub Freeware)
========================================================================================================
#>

#Requires -Version 5.1
<#
.SYNOPSIS
    Detects OneDrive and Google Drive sync folder paths on the local machine.
.DESCRIPTION
    Checks environment variables and registry keys to locate the active OneDrive
    sync folder. Checks common filesystem paths for Google Drive (DriveFS and the
    legacy "Google Drive" folder). Returns a hashtable indicating which services are
    available and their folder paths.
.OUTPUTS
    [hashtable] With keys:
        OneDriveAvailable  [bool]
        OneDrivePath       [string]
        GoogleDriveAvailable [bool]
        GoogleDrivePath      [string]
.EXAMPLE
    $cloud = Find-CloudSyncFolders
    if ($cloud.OneDriveAvailable) { Write-Host "OneDrive at $($cloud.OneDrivePath)" }
#>

function Find-CloudSyncFolders {
    [CmdletBinding()]
    param()

    Write-MigrationLog -Message "Detecting cloud sync folder locations..." -Level Info

    $result = @{
        OneDriveAvailable    = $false
        OneDrivePath         = $null
        GoogleDriveAvailable = $false
        GoogleDrivePath      = $null
    }

    # -------------------------------------------------------------------
    # OneDrive detection
    # -------------------------------------------------------------------
    try {
        $oneDrivePath = $null

        # Method 1: Environment variable (most reliable when set)
        if ($env:OneDrive -and (Test-Path $env:OneDrive -ErrorAction SilentlyContinue)) {
            $oneDrivePath = $env:OneDrive
            Write-MigrationLog -Message "OneDrive found via environment variable: $oneDrivePath" -Level Debug
        }

        # Method 2: OneDriveConsumer / OneDriveCommercial environment variables
        if (-not $oneDrivePath) {
            foreach ($varName in @('OneDriveConsumer', 'OneDriveCommercial')) {
                $candidate = [System.Environment]::GetEnvironmentVariable($varName, 'User')
                if ($candidate -and (Test-Path $candidate -ErrorAction SilentlyContinue)) {
                    $oneDrivePath = $candidate
                    Write-MigrationLog -Message "OneDrive found via $varName environment variable: $oneDrivePath" -Level Debug
                    break
                }
            }
        }

        # Method 3: Registry - HKCU:\SOFTWARE\Microsoft\OneDrive
        if (-not $oneDrivePath) {
            $regKey = 'HKCU:\SOFTWARE\Microsoft\OneDrive'
            if (Test-Path $regKey) {
                $regProps = Get-ItemProperty -Path $regKey -ErrorAction SilentlyContinue
                if ($regProps.UserFolder -and (Test-Path $regProps.UserFolder -ErrorAction SilentlyContinue)) {
                    $oneDrivePath = $regProps.UserFolder
                    Write-MigrationLog -Message "OneDrive found via registry UserFolder: $oneDrivePath" -Level Debug
                }
            }
        }

        # Method 4: Registry - per-account keys under OneDrive\Accounts
        if (-not $oneDrivePath) {
            $accountsKey = 'HKCU:\SOFTWARE\Microsoft\OneDrive\Accounts'
            if (Test-Path $accountsKey) {
                $accounts = Get-ChildItem -Path $accountsKey -ErrorAction SilentlyContinue
                foreach ($account in $accounts) {
                    $acctProps = Get-ItemProperty -Path $account.PSPath -ErrorAction SilentlyContinue
                    if ($acctProps.UserFolder -and (Test-Path $acctProps.UserFolder -ErrorAction SilentlyContinue)) {
                        $oneDrivePath = $acctProps.UserFolder
                        Write-MigrationLog -Message "OneDrive found via registry account key: $oneDrivePath" -Level Debug
                        break
                    }
                }
            }
        }

        # Method 5: Common default path fallback
        if (-not $oneDrivePath) {
            $defaultPath = Join-Path $env:USERPROFILE 'OneDrive'
            if (Test-Path $defaultPath -ErrorAction SilentlyContinue) {
                $oneDrivePath = $defaultPath
                Write-MigrationLog -Message "OneDrive found at default path: $oneDrivePath" -Level Debug
            }
        }

        if ($oneDrivePath) {
            $result.OneDriveAvailable = $true
            $result.OneDrivePath      = $oneDrivePath
            Write-MigrationLog -Message "OneDrive sync folder detected: $oneDrivePath" -Level Info
        } else {
            Write-MigrationLog -Message "OneDrive sync folder not found" -Level Info
        }
    }
    catch {
        Write-MigrationLog -Message "Error detecting OneDrive: $($_.Exception.Message)" -Level Warning
    }

    # -------------------------------------------------------------------
    # Google Drive detection
    # -------------------------------------------------------------------
    try {
        $googleDrivePath = $null

        # Method 1: Google DriveFS (modern Google Drive for Desktop)
        $driveFsRoot = Join-Path $env:LOCALAPPDATA 'Google\DriveFS'
        if (Test-Path $driveFsRoot -ErrorAction SilentlyContinue) {
            # DriveFS creates a virtual drive; find the mounted drive letter
            # Check for the content_cache which holds the root path reference
            $driveFsMountPoints = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Description -match 'Google' -or $_.Root -match 'Google'
                }

            if ($driveFsMountPoints) {
                $googleDrivePath = $driveFsMountPoints[0].Root
                Write-MigrationLog -Message "Google Drive (DriveFS mounted) found: $googleDrivePath" -Level Debug
            }

            # If no mounted drive found, check for "My Drive" folder in common locations
            if (-not $googleDrivePath) {
                # Google Drive for Desktop may use a lettered drive like G:\
                $possibleDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.Root 'My Drive') -ErrorAction SilentlyContinue }
                if ($possibleDrives) {
                    $googleDrivePath = Join-Path $possibleDrives[0].Root 'My Drive'
                    Write-MigrationLog -Message "Google Drive (My Drive) found: $googleDrivePath" -Level Debug
                }
            }
        }

        # Method 2: Legacy Google Drive sync folder in user profile
        if (-not $googleDrivePath) {
            $legacyPaths = @(
                (Join-Path $env:USERPROFILE 'Google Drive')
                (Join-Path $env:USERPROFILE 'My Drive')
                (Join-Path $env:USERPROFILE 'GoogleDrive')
            )
            foreach ($candidate in $legacyPaths) {
                if (Test-Path $candidate -ErrorAction SilentlyContinue) {
                    $googleDrivePath = $candidate
                    Write-MigrationLog -Message "Google Drive found at legacy path: $googleDrivePath" -Level Debug
                    break
                }
            }
        }

        # Method 3: Registry check for Google Drive
        if (-not $googleDrivePath) {
            $gdriveRegKey = 'HKCU:\SOFTWARE\Google\DriveFS'
            if (Test-Path $gdriveRegKey) {
                $gdriveProps = Get-ItemProperty -Path $gdriveRegKey -ErrorAction SilentlyContinue
                if ($gdriveProps.Path -and (Test-Path $gdriveProps.Path -ErrorAction SilentlyContinue)) {
                    $googleDrivePath = $gdriveProps.Path
                    Write-MigrationLog -Message "Google Drive found via registry: $googleDrivePath" -Level Debug
                }
            }
        }

        if ($googleDrivePath) {
            $result.GoogleDriveAvailable = $true
            $result.GoogleDrivePath      = $googleDrivePath
            Write-MigrationLog -Message "Google Drive sync folder detected: $googleDrivePath" -Level Info
        } else {
            Write-MigrationLog -Message "Google Drive sync folder not found" -Level Info
        }
    }
    catch {
        Write-MigrationLog -Message "Error detecting Google Drive: $($_.Exception.Message)" -Level Warning
    }

    Write-MigrationLog -Message "Cloud sync folder detection complete (OneDrive=$($result.OneDriveAvailable), GoogleDrive=$($result.GoogleDriveAvailable))" -Level Success
    return $result
}
