<#
========================================================================================================
    Title:          Win11Migrator - USB Drive Export Handler
    Filename:       Export-ToUSBDrive.ps1
    Description:    Copies the migration package to a selected USB drive with progress reporting.
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
    Copies the migration package to a USB drive using Robocopy with integrity verification.
.DESCRIPTION
    Takes the path to the local migration package directory and a target USB drive
    letter. Uses Robocopy for reliable, multi-threaded copying with automatic retries.
    After the copy completes, verifies integrity by comparing file counts and total sizes.
.PARAMETER PackagePath
    Full path to the local migration package directory to export.
.PARAMETER TargetDriveLetter
    Drive letter of the USB target (e.g. "E:" or "E").
.PARAMETER RobocopyThreads
    Number of Robocopy multi-threaded copy threads. Defaults to config value or 8.
.PARAMETER RobocopyRetries
    Number of retries per file on failure. Defaults to config value or 3.
.OUTPUTS
    [PSCustomObject] With TargetPath, FileCount, TotalSizeMB, Verified, and Duration properties.
.EXAMPLE
    Export-ToUSBDrive -PackagePath "C:\MigrationPackage" -TargetDriveLetter "E:"
#>

function Export-ToUSBDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Container })]
        [string]$PackagePath,

        [Parameter(Mandatory)]
        [string]$TargetDriveLetter
    )

    # Normalize drive letter
    $TargetDriveLetter = $TargetDriveLetter.TrimEnd(':\') + ':'
    $targetRoot = "$TargetDriveLetter\"

    if (-not (Test-Path $targetRoot)) {
        throw "USB drive $TargetDriveLetter is not accessible. Please check the drive is connected."
    }

    $packageName = Split-Path $PackagePath -Leaf
    $targetPath  = Join-Path $targetRoot "Win11Migrator\$packageName"

    Write-MigrationLog -Message "Exporting migration package to USB drive $TargetDriveLetter" -Level Info
    Write-MigrationLog -Message "Source: $PackagePath" -Level Info
    Write-MigrationLog -Message "Target: $targetPath" -Level Info

    # Determine Robocopy parameters from config or defaults
    # USB drives have poor random write performance; limit to 2 threads to avoid
    # overwhelming the USB controller (which can freeze the entire system)
    $threads = if ($script:Config -and $script:Config.RobocopyThreads) {
        [Math]::Min($script:Config.RobocopyThreads, 2)
    } else { 2 }

    $retries = if ($script:Config -and $script:Config.RobocopyRetries) {
        $script:Config.RobocopyRetries
    } else { 3 }

    $waitSec = if ($script:Config -and $script:Config.RobocopyWaitSeconds) {
        $script:Config.RobocopyWaitSeconds
    } else { 5 }

    # Check free space on target
    $sourceSizeBytes = (Get-ChildItem $PackagePath -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    $sourceSizeMB = [math]::Round($sourceSizeBytes / 1MB, 2)

    $targetDrive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$TargetDriveLetter'" -ErrorAction SilentlyContinue
    if ($targetDrive) {
        $freeSpaceBytes = [long]$targetDrive.FreeSpace
        if ($sourceSizeBytes -gt $freeSpaceBytes) {
            $freeMB = [math]::Round($freeSpaceBytes / 1MB, 2)
            throw "Insufficient space on $TargetDriveLetter. Need $sourceSizeMB MB but only $freeMB MB free."
        }
    }

    Write-MigrationLog -Message "Package size: $sourceSizeMB MB" -Level Info

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # Run Robocopy
    # /E = include subdirectories including empty ones
    # /MT = multi-threaded
    # /R = retries, /W = wait between retries
    # /NP = no percentage display (cleaner log output)
    # /NFL /NDL = suppress file/directory logging (we log summary)
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
        TargetPath  = $targetPath
        FileCount   = $targetCount
        TotalSizeMB = [math]::Round($targetSize / 1MB, 2)
        Verified    = $verified
        Duration    = $stopwatch.Elapsed.ToString('hh\:mm\:ss')
    }

    Write-MigrationLog -Message "USB export complete in $($result.Duration)" -Level Success
    return $result
}
