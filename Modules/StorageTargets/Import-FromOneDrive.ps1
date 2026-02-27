<#
========================================================================================================
    Title:          Win11Migrator - OneDrive Import Handler
    Filename:       Import-FromOneDrive.ps1
    Description:    Reads a migration package from the OneDrive sync folder on the target machine.
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
    Imports a migration package from the OneDrive sync folder on the target machine.
.DESCRIPTION
    Locates the Win11Migrator folder within the OneDrive sync path, copies the
    migration package to a local temporary directory for processing, and validates
    that manifest.json exists.
.PARAMETER OneDrivePath
    Explicit OneDrive sync folder path. If not provided, auto-detects via
    Find-CloudSyncFolders.
.PARAMETER LocalDestination
    Local directory to copy the package into. Defaults to a temp directory.
.OUTPUTS
    [PSCustomObject] With PackagePath, ManifestPath, FileCount, and TotalSizeMB properties.
.EXAMPLE
    $imported = Import-FromOneDrive
    Read-MigrationManifest -ManifestPath $imported.ManifestPath
#>

function Import-FromOneDrive {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$OneDrivePath,

        [Parameter()]
        [string]$LocalDestination
    )

    Write-MigrationLog -Message "Importing migration package from OneDrive..." -Level Info

    # Resolve OneDrive path
    if (-not $OneDrivePath) {
        $cloud = Find-CloudSyncFolders
        if (-not $cloud.OneDriveAvailable) {
            throw "OneDrive sync folder not detected. Please ensure OneDrive is installed and signed in."
        }
        $OneDrivePath = $cloud.OneDrivePath
    }

    if (-not (Test-Path $OneDrivePath)) {
        throw "OneDrive path does not exist: $OneDrivePath"
    }

    # Locate Win11Migrator folder
    $migratorFolder = Join-Path $OneDrivePath 'Win11Migrator'
    if (-not (Test-Path $migratorFolder)) {
        throw "Win11Migrator folder not found in OneDrive at $migratorFolder. Ensure the export has been synced."
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
        throw "No migration package found in OneDrive Win11Migrator folder. No subfolder contains manifest.json."
    }

    Write-MigrationLog -Message "Migration package located in OneDrive: $packageSource" -Level Info

    # Determine local destination
    if (-not $LocalDestination) {
        $LocalDestination = Join-Path $env:TEMP "Win11Migrator\OneDriveImport_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
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
        throw "Robocopy import from OneDrive failed with exit code $exitCode."
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

    Write-MigrationLog -Message "OneDrive import complete: $fileCount files, $totalSizeMB MB" -Level Success
    return $result
}
