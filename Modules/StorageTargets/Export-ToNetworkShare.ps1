<#
========================================================================================================
    Title:          Win11Migrator - Network Share Export Handler
    Filename:       Export-ToNetworkShare.ps1
    Description:    Copies the migration package to a network share (UNC path) with progress reporting.
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
    Copies the migration package to a network share using Robocopy with integrity verification.
.DESCRIPTION
    Takes the path to the local migration package directory and a target UNC network path.
    Uses Robocopy for reliable, multi-threaded copying with automatic retries.
    After the copy completes, verifies integrity by comparing file counts and total sizes.
.PARAMETER PackagePath
    Full path to the local migration package directory to export.
.PARAMETER NetworkPath
    UNC path to the network share (e.g. "\\server\share" or "\\server\share\subfolder").
.OUTPUTS
    [PSCustomObject] With TargetPath, FileCount, TotalSizeMB, Verified, and Duration properties.
.EXAMPLE
    Export-ToNetworkShare -PackagePath "C:\MigrationPackage" -NetworkPath "\\fileserver\migrations"
#>

function Export-ToNetworkShare {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$NetworkPath
    )

    # Validate the UNC path is accessible
    if (-not (Test-Path $NetworkPath)) {
        throw "Network share is not accessible: $NetworkPath. Please check the path and your network connection."
    }

    # Create a timestamped subdirectory under the network path
    $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $packageName = Split-Path $PackagePath -Leaf
    $targetPath  = Join-Path $NetworkPath "Win11Migrator\${packageName}_$timestamp"

    Write-MigrationLog -Message "Exporting migration package to network share" -Level Info
    Write-MigrationLog -Message "Source: $PackagePath" -Level Info
    Write-MigrationLog -Message "Target: $targetPath" -Level Info

    # Determine Robocopy parameters from config or defaults
    $threads = if ($script:Config -and $script:Config.RobocopyThreads) {
        $script:Config.RobocopyThreads
    } else { 8 }

    $retries = if ($script:Config -and $script:Config.RobocopyRetries) {
        $script:Config.RobocopyRetries
    } else { 3 }

    $waitSec = if ($script:Config -and $script:Config.RobocopyWaitSeconds) {
        $script:Config.RobocopyWaitSeconds
    } else { 5 }

    # Check source size for logging
    $sourceSizeBytes = (Get-ChildItem $PackagePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sourceSizeMB = [math]::Round($sourceSizeBytes / 1MB, 2)

    Write-MigrationLog -Message "Package size: $sourceSizeMB MB" -Level Info

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Run Robocopy
    # /E = include subdirectories including empty ones
    # /MT = multi-threaded
    # /R = retries, /W = wait between retries
    # /NP = no percentage display (cleaner log output)
    # /COPY:DAT = copy Data, Attributes, Timestamps
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

    Write-MigrationLog -Message "Starting Robocopy with $threads threads..." -Level Info

    $robocopyResult = & robocopy @robocopyArgs 2>&1
    $robocopyExitCode = $LASTEXITCODE

    # Robocopy exit codes: 0=no change, 1=files copied, 2=extra files, 3=1+2
    # Codes 0-7 are success; 8+ indicate errors
    if ($robocopyExitCode -ge 8) {
        $robocopyOutput = ($robocopyResult | Out-String).Trim()
        Write-MigrationLog -Message "Robocopy failed with exit code $robocopyExitCode" -Level Error
        Write-MigrationLog -Message $robocopyOutput -Level Error
        throw "Robocopy failed with exit code $robocopyExitCode. Check logs for details."
    }

    Write-MigrationLog -Message "Robocopy completed with exit code $robocopyExitCode" -Level Info

    # Bundle Win11Migrator tool alongside the package so it can run directly on the target
    try {
        Copy-MigratorToTarget -TargetBasePath (Split-Path $targetPath -Parent)
    } catch {
        Write-MigrationLog -Message "Warning: Could not bundle Win11Migrator tool: $($_.Exception.Message)" -Level Warning
    }

    # Verify integrity: compare file count and total size
    Write-MigrationLog -Message "Verifying copy integrity..." -Level Info

    $sourceFiles = Get-ChildItem $PackagePath -Recurse -File -ErrorAction SilentlyContinue
    $targetFiles = Get-ChildItem $targetPath  -Recurse -File -ErrorAction SilentlyContinue

    $sourceCount = ($sourceFiles | Measure-Object).Count
    $targetCount = ($targetFiles | Measure-Object).Count

    $sourceSize = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
    $targetSize = ($targetFiles | Measure-Object -Property Length -Sum).Sum

    $verified = ($sourceCount -eq $targetCount) -and ($sourceSize -eq $targetSize)

    $stopwatch.Stop()

    if ($verified) {
        Write-MigrationLog -Message "Integrity verified: $targetCount files, $([math]::Round($targetSize / 1MB, 2)) MB" -Level Success
    } else {
        Write-MigrationLog -Message "Integrity check WARNING: Source has $sourceCount files ($([math]::Round($sourceSize / 1MB, 2)) MB), target has $targetCount files ($([math]::Round($targetSize / 1MB, 2)) MB)" -Level Warning
    }

    $result = [PSCustomObject]@{
        TargetPath     = $targetPath
        FileCount      = $targetCount
        TotalSizeMB    = [math]::Round($targetSize / 1MB, 2)
        Verified       = $verified
        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
        Duration       = $stopwatch.Elapsed.ToString('hh\:mm\:ss')
    }

    Write-MigrationLog -Message "Network share export complete in $($result.Duration)" -Level Success
    return $result
}
