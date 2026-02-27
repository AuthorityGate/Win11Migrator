<#
========================================================================================================
    Title:          Win11Migrator - Google Drive Export Handler
    Filename:       Export-ToGoogleDrive.ps1
    Description:    Copies the migration package to the Google Drive sync folder for cloud-based transfer.
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
    Copies the migration package to the Google Drive sync folder for cloud transfer.
.DESCRIPTION
    Detects the local Google Drive sync folder (via Find-CloudSyncFolders) and copies
    the migration package into a Win11Migrator subfolder. The user should wait for
    Google Drive to finish syncing before attempting import on the target machine.
.PARAMETER PackagePath
    Full path to the local migration package directory to export.
.PARAMETER GoogleDrivePath
    Explicit path to the Google Drive sync folder. If not provided, the function uses
    Find-CloudSyncFolders to auto-detect it.
.OUTPUTS
    [PSCustomObject] With TargetPath, FileCount, TotalSizeMB, and Duration properties.
.EXAMPLE
    Export-ToGoogleDrive -PackagePath "C:\MigrationPackage"
#>

function Export-ToGoogleDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$PackagePath,

        [Parameter()]
        [string]$GoogleDrivePath
    )

    Write-MigrationLog -Message "Exporting migration package to Google Drive..." -Level Info

    # Resolve Google Drive path
    if (-not $GoogleDrivePath) {
        $cloud = Find-CloudSyncFolders
        if (-not $cloud.GoogleDriveAvailable) {
            throw "Google Drive sync folder not detected on this machine. Please ensure Google Drive for Desktop is installed and signed in."
        }
        $GoogleDrivePath = $cloud.GoogleDrivePath
    }

    if (-not (Test-Path $GoogleDrivePath)) {
        throw "Google Drive path does not exist: $GoogleDrivePath"
    }

    # Create Win11Migrator subfolder in Google Drive
    $packageName = Split-Path $PackagePath -Leaf
    $targetPath  = Join-Path $GoogleDrivePath "Win11Migrator\$packageName"

    if (-not (Test-Path (Join-Path $GoogleDrivePath 'Win11Migrator'))) {
        New-Item -Path (Join-Path $GoogleDrivePath 'Win11Migrator') -ItemType Directory -Force | Out-Null
    }

    Write-MigrationLog -Message "Source: $PackagePath" -Level Info
    Write-MigrationLog -Message "Target: $targetPath" -Level Info

    # Measure source size
    $sourceSizeBytes = (Get-ChildItem $PackagePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sourceSizeMB = [math]::Round($sourceSizeBytes / 1MB, 2)

    Write-MigrationLog -Message "Package size: $sourceSizeMB MB" -Level Info

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Use Robocopy for reliable copy
    $threads = if ($script:Config -and $script:Config.RobocopyThreads) {
        $script:Config.RobocopyThreads
    } else { 8 }

    $retries = if ($script:Config -and $script:Config.RobocopyRetries) {
        $script:Config.RobocopyRetries
    } else { 3 }

    $waitSec = if ($script:Config -and $script:Config.RobocopyWaitSeconds) {
        $script:Config.RobocopyWaitSeconds
    } else { 5 }

    $robocopyArgs = @(
        $PackagePath
        $targetPath
        '/E'
        "/MT:$threads"
        "/R:$retries"
        "/W:$waitSec"
        '/NP'
        '/COPY:DAT'
        '/DCOPY:T'
    )

    Write-MigrationLog -Message "Starting Robocopy to Google Drive folder..." -Level Info

    $null = & robocopy @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        throw "Robocopy to Google Drive failed with exit code $exitCode."
    }

    $stopwatch.Stop()

    $targetFiles = Get-ChildItem $targetPath -Recurse -File -ErrorAction SilentlyContinue
    $fileCount = ($targetFiles | Measure-Object).Count
    $totalSize = ($targetFiles | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)

    $result = [PSCustomObject]@{
        TargetPath  = $targetPath
        FileCount   = $fileCount
        TotalSizeMB = $totalSizeMB
        Duration    = $stopwatch.Elapsed.ToString('hh\:mm\:ss')
    }

    Write-MigrationLog -Message "Google Drive export complete: $fileCount files, $totalSizeMB MB in $($result.Duration)" -Level Success
    Write-MigrationLog -Message "IMPORTANT: Please allow Google Drive to finish syncing before importing on the target machine. Sync status is visible in the Google Drive system tray icon." -Level Warning

    return $result
}
