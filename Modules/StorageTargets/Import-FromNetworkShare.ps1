<#
========================================================================================================
    Title:          Win11Migrator - Network Share Import Handler
    Filename:       Import-FromNetworkShare.ps1
    Description:    Reads a migration package from a network share for import on the target machine.
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
    Imports a migration package from a network share to a local temp directory.
.DESCRIPTION
    Locates the Win11Migrator migration package on the specified network share,
    copies it to a local temporary directory for processing, and validates that
    the manifest.json file exists within the package.
.PARAMETER NetworkPath
    UNC path to the network share root or the specific migration package folder.
    If a share root is given, the function searches for the Win11Migrator folder.
.PARAMETER LocalDestination
    Local directory to copy the package into. Defaults to a Win11Migrator folder
    in the user's temp directory.
.OUTPUTS
    [PSCustomObject] With LocalPath, ManifestPath, FileCount, TotalSizeMB, and ElapsedSeconds properties.
.EXAMPLE
    $imported = Import-FromNetworkShare -NetworkPath "\\fileserver\migrations"
    Read-MigrationManifest -ManifestPath $imported.ManifestPath
#>

function Import-FromNetworkShare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$NetworkPath,

        [Parameter()]
        [string]$LocalDestination
    )

    Write-MigrationLog -Message "Importing migration package from network share..." -Level Info

    # Validate network path exists
    if (-not (Test-Path $NetworkPath)) {
        throw "Network share path not accessible: $NetworkPath. Please check the path and your network connection."
    }

    # Locate the migration package on the network share
    $packageSource = $null

    # Check if the given path IS the package (contains manifest.json)
    $directManifest = Join-Path $NetworkPath 'manifest.json'
    if (Test-Path $directManifest) {
        $packageSource = $NetworkPath
        Write-MigrationLog -Message "Migration package found directly at: $packageSource" -Level Info
    }

    # Check for Win11Migrator subfolder
    if (-not $packageSource) {
        $migratorFolder = Join-Path $NetworkPath 'Win11Migrator'
        if (Test-Path $migratorFolder) {
            # Find the first subfolder containing manifest.json, or check root
            $manifestInRoot = Join-Path $migratorFolder 'manifest.json'
            if (Test-Path $manifestInRoot) {
                $packageSource = $migratorFolder
            } else {
                $subDirs = Get-ChildItem -Path $migratorFolder -Directory -ErrorAction SilentlyContinue
                foreach ($sub in $subDirs) {
                    $subManifest = Join-Path $sub.FullName 'manifest.json'
                    if (Test-Path $subManifest) {
                        $packageSource = $sub.FullName
                        break
                    }
                }
            }
        }
    }

    # Broad search as last resort (one level deep from share root)
    if (-not $packageSource) {
        $searchDirs = Get-ChildItem -Path $NetworkPath -Directory -ErrorAction SilentlyContinue
        foreach ($dir in $searchDirs) {
            $candidateManifest = Join-Path $dir.FullName 'manifest.json'
            if (Test-Path $candidateManifest) {
                $packageSource = $dir.FullName
                break
            }
        }
    }

    if (-not $packageSource) {
        throw "No migration package found on network share at $NetworkPath. Expected a folder containing manifest.json."
    }

    Write-MigrationLog -Message "Migration package located at: $packageSource" -Level Info

    # Determine local destination
    if (-not $LocalDestination) {
        $LocalDestination = Join-Path $env:TEMP "Win11Migrator\Import_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    }

    if (-not (Test-Path $LocalDestination)) {
        New-Item -Path $LocalDestination -ItemType Directory -Force | Out-Null
    }

    # Copy using Robocopy for reliability
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

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

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
        throw "Robocopy import from network share failed with exit code $exitCode."
    }

    $stopwatch.Stop()

    # Validate manifest exists locally
    $localManifest = Join-Path $LocalDestination 'manifest.json'
    if (-not (Test-Path $localManifest)) {
        throw "Import completed but manifest.json not found at $localManifest. The package may be corrupted."
    }

    $importedFiles = Get-ChildItem $LocalDestination -Recurse -File -ErrorAction SilentlyContinue
    $fileCount = ($importedFiles | Measure-Object).Count
    $totalSize = ($importedFiles | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)

    $result = [PSCustomObject]@{
        LocalPath      = $LocalDestination
        ManifestPath   = $localManifest
        FileCount      = $fileCount
        TotalSizeMB    = $totalSizeMB
        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    }

    Write-MigrationLog -Message "Network share import complete: $fileCount files, $totalSizeMB MB" -Level Success
    return $result
}
