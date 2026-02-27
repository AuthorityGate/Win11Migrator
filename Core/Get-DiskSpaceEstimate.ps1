<#
========================================================================================================
    Title:          Win11Migrator - Disk Space Estimator
    Filename:       Get-DiskSpaceEstimate.ps1
    Description:    Calculates estimated disk space requirements for the migration package.
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
    Estimate the disk space required for a migration package and verify target has enough room.
#>

function Get-DiskSpaceEstimate {
    [CmdletBinding()]
    param(
        [MigrationApp[]]$Apps,
        [UserDataItem[]]$UserData,
        [BrowserProfile[]]$BrowserProfiles,
        [int]$BufferMB = 500
    )

    $totalBytes = 0

    # User data sizes
    if ($UserData) {
        $totalBytes += ($UserData | Where-Object { $_.Selected } | Measure-Object -Property SizeBytes -Sum).Sum
    }

    # Estimate browser profile sizes (scan actual paths)
    if ($BrowserProfiles) {
        foreach ($profile in ($BrowserProfiles | Where-Object { $_.Selected })) {
            if (Test-Path $profile.ProfilePath) {
                $size = (Get-ChildItem $profile.ProfilePath -Recurse -ErrorAction SilentlyContinue |
                         Measure-Object -Property Length -Sum).Sum
                $totalBytes += $size
            }
        }
    }

    # Add buffer
    $totalBytes += ($BufferMB * 1MB)

    return [PSCustomObject]@{
        EstimatedBytes = $totalBytes
        EstimatedMB    = [math]::Ceiling($totalBytes / 1MB)
        EstimatedGB    = [math]::Round($totalBytes / 1GB, 2)
        BufferMB       = $BufferMB
    }
}

function Test-DiskSpaceSufficient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [long]$RequiredBytes
    )

    # Walk up parent directories to find an existing path for drive resolution
    $resolvedPath = $TargetPath
    while ($resolvedPath -and -not (Test-Path $resolvedPath)) {
        $resolvedPath = Split-Path $resolvedPath -Parent
    }
    if (-not $resolvedPath) {
        throw "Cannot resolve drive for path: $TargetPath"
    }
    $drive = (Get-Item $resolvedPath).PSDrive
    $freeBytes = (Get-PSDrive $drive.Name).Free

    return [PSCustomObject]@{
        Sufficient = $freeBytes -gt $RequiredBytes
        FreeBytes  = $freeBytes
        FreeMB     = [math]::Round($freeBytes / 1MB, 2)
        FreeGB     = [math]::Round($freeBytes / 1GB, 2)
        RequiredMB = [math]::Round($RequiredBytes / 1MB, 2)
        RequiredGB = [math]::Round($RequiredBytes / 1GB, 2)
    }
}
