<#
========================================================================================================
    Title:          Win11Migrator - Google Drive Import Handler
    Filename:       Import-FromGoogleDrive.ps1
    Description:    Reads a migration package from the Google Drive sync folder on the target machine.
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
    Imports a migration package from the Google Drive sync folder on the target machine.
.DESCRIPTION
    Locates the Win11Migrator folder within the Google Drive sync path, copies the
    migration package to a local temporary directory for processing, and validates
    that manifest.json exists.
.PARAMETER GoogleDrivePath
    Explicit Google Drive sync folder path. If not provided, auto-detects via
    Find-CloudSyncFolders.
.PARAMETER LocalDestination
    Local directory to copy the package into. Defaults to a temp directory.
.OUTPUTS
    [PSCustomObject] With PackagePath, ManifestPath, FileCount, and TotalSizeMB properties.
.EXAMPLE
    $imported = Import-FromGoogleDrive
    Read-MigrationManifest -ManifestPath $imported.ManifestPath
#>

function Import-FromGoogleDrive {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$GoogleDrivePath,

        [Parameter()]
        [string]$LocalDestination
    )

    Write-MigrationLog -Message "Importing migration package from Google Drive..." -Level Info

    # Resolve Google Drive path
    if (-not $GoogleDrivePath) {
        $cloud = Find-CloudSyncFolders
        if (-not $cloud.GoogleDriveAvailable) {
            throw "Google Drive sync folder not detected. Please ensure Google Drive for Desktop is installed and signed in."
        }
        $GoogleDrivePath = $cloud.GoogleDrivePath
    }

    if (-not (Test-Path $GoogleDrivePath)) {
        throw "Google Drive path does not exist: $GoogleDrivePath"
    }

    # Locate Win11Migrator folder
    $migratorFolder = Join-Path $GoogleDrivePath 'Win11Migrator'
    if (-not (Test-Path $migratorFolder)) {
        throw "Win11Migrator folder not found in Google Drive at $migratorFolder. Ensure the export has been synced."
    }

    # Find the migration package (folder containing manifest.json)
    $packageSource = $null

    # Check if manifest is directly in Win11Migrator folder
    $directManifest = Join-Path $migratorFolder 'manifest.json'
    if (Test-Path $directManifest) {
        $packageSource = $migratorFolder
    } else {
        # Check subfolders
        $subDirs = Get-ChildItem -Path $migratorFolder -Directory -ErrorAction SilentlyContinue
        foreach ($sub in $subDirs) {
            $candidateManifest = Join-Path $sub.FullName 'manifest.json'
            if (Test-Path $candidateManifest) {
                $packageSource = $sub.FullName
                break
            }
        }
    }

    if (-not $packageSource) {
        throw "No migration package found in Google Drive Win11Migrator folder. No subfolder contains manifest.json."
    }

    Write-MigrationLog -Message "Migration package located in Google Drive: $packageSource" -Level Info

    # Determine local destination
    if (-not $LocalDestination) {
        $LocalDestination = Join-Path $env:TEMP "Win11Migrator\GoogleDriveImport_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }

    if (-not (Test-Path $LocalDestination)) {
        New-Item -Path $LocalDestination -ItemType Directory -Force | Out-Null
    }

    # Copy to local using Robocopy
    $threads = if ($script:Config -and $script:Config.RobocopyThreads) {
        $script:Config.RobocopyThreads
    } else { 8 }

    $retries = if ($script:Config -and $script:Config.RobocopyRetries) {
        $script:Config.RobocopyRetries
    } else { 3 }

    $waitSec = if ($script:Config -and $script:Config.RobocopyWaitSeconds) {
        $script:Config.RobocopyWaitSeconds
    } else { 5 }

    Write-MigrationLog -Message "Copying to local directory: $LocalDestination" -Level Info

    $robocopyArgs = @(
        $packageSource
        $LocalDestination
        '/E'
        "/MT:$threads"
        "/R:$retries"
        "/W:$waitSec"
        '/NP'
        '/COPY:DAT'
        '/DCOPY:T'
    )

    $null = & robocopy @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ge 8) {
        throw "Robocopy import from Google Drive failed with exit code $exitCode."
    }

    # Validate manifest
    $localManifest = Join-Path $LocalDestination 'manifest.json'
    if (-not (Test-Path $localManifest)) {
        throw "Import completed but manifest.json not found at $localManifest. The package may be incomplete or still syncing."
    }

    $importedFiles = Get-ChildItem $LocalDestination -Recurse -File -ErrorAction SilentlyContinue
    $fileCount = ($importedFiles | Measure-Object).Count
    $totalSize = ($importedFiles | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)

    $result = [PSCustomObject]@{
        PackagePath  = $LocalDestination
        ManifestPath = $localManifest
        FileCount    = $fileCount
        TotalSizeMB  = $totalSizeMB
    }

    Write-MigrationLog -Message "Google Drive import complete: $fileCount files, $totalSizeMB MB" -Level Success
    return $result
}
