<#
========================================================================================================
    Title:          Win11Migrator - OneDrive Export Handler
    Filename:       Export-ToOneDrive.ps1
    Description:    Copies the migration package to the OneDrive sync folder for cloud-based transfer.
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
    Copies the migration package to the OneDrive sync folder for cloud transfer.
.DESCRIPTION
    Detects the local OneDrive sync folder (via Find-CloudSyncFolders) and copies
    the migration package into a Win11Migrator subfolder. The user should wait for
    OneDrive to finish syncing before attempting import on the target machine.
.PARAMETER PackagePath
    Full path to the local migration package directory to export.
.PARAMETER OneDrivePath
    Explicit path to the OneDrive sync folder. If not provided, the function uses
    Find-CloudSyncFolders to auto-detect it.
.OUTPUTS
    [PSCustomObject] With TargetPath, FileCount, TotalSizeMB, and Duration properties.
.EXAMPLE
    Export-ToOneDrive -PackagePath "C:\MigrationPackage"
#>

function Export-ToOneDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$PackagePath,

        [Parameter()]
        [string]$OneDrivePath
    )

    Write-MigrationLog -Message "Exporting migration package to OneDrive..." -Level Info

    # Resolve OneDrive path
    if (-not $OneDrivePath) {
        $cloud = Find-CloudSyncFolders
        if (-not $cloud.OneDriveAvailable) {
            throw "OneDrive sync folder not detected on this machine. Please ensure OneDrive is installed and signed in."
        }
        $OneDrivePath = $cloud.OneDrivePath
    }

    if (-not (Test-Path $OneDrivePath)) {
        throw "OneDrive path does not exist: $OneDrivePath"
    }

    # Create Win11Migrator subfolder in OneDrive
    $packageName = Split-Path $PackagePath -Leaf
    $targetPath  = Join-Path $OneDrivePath "Win11Migrator\$packageName"

    if (-not (Test-Path (Join-Path $OneDrivePath 'Win11Migrator'))) {
        New-Item -Path (Join-Path $OneDrivePath 'Win11Migrator') -ItemType Directory -Force | Out-Null
    }

    Write-MigrationLog -Message "Source: $PackagePath" -Level Info
    Write-MigrationLog -Message "Target: $targetPath" -Level Info

    # Check available space (OneDrive local free space)
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

    Write-MigrationLog -Message "Starting Robocopy to OneDrive folder..." -Level Info

    $null = & robocopy @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        throw "Robocopy to OneDrive failed with exit code $exitCode."
    }

    # Bundle Win11Migrator tool alongside the package so it can run directly on the target
    try {
        Copy-MigratorToTarget -TargetBasePath (Split-Path $targetPath -Parent)
    } catch {
        Write-MigrationLog -Message "Warning: Could not bundle Win11Migrator tool: $($_.Exception.Message)" -Level Warning
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

    Write-MigrationLog -Message "OneDrive export complete: $fileCount files, $totalSizeMB MB in $($result.Duration)" -Level Success
    Write-MigrationLog -Message "IMPORTANT: Please allow OneDrive to finish syncing before importing on the target machine. Sync status is visible in the OneDrive system tray icon." -Level Warning

    return $result
}
