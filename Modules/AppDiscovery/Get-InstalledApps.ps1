<#
========================================================================================================
    Title:          Win11Migrator - Installed Application Aggregator
    Filename:       Get-InstalledApps.ps1
    Description:    Aggregates application discovery from all sources (Registry, Winget, Store, ProgramFiles) with deduplication.
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
    Orchestrator that calls all application discovery scanners, deduplicates results,
    and returns a unified list of installed applications.
#>

function Get-InstalledApps {
    <#
    .SYNOPSIS
        Discovers all installed applications by combining Registry, Winget, Store,
        and Program Files scanners. Deduplicates by normalized name, keeping the
        entry with the richest metadata.
    .PARAMETER Config
        The migration configuration hashtable from Initialize-Environment.
    .OUTPUTS
        [MigrationApp[]] Deduplicated array of all discovered applications.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param(
        [Parameter()]
        [hashtable]$Config
    )

    if (-not $Config) {
        $Config = $script:Config
    }

    Write-MigrationLog -Message "=== Beginning full application discovery ===" -Level Info

    # Collect results from all scanners
    $allApps = [System.Collections.Generic.List[MigrationApp]]::new()

    # 1. Registry scan (highest metadata quality)
    Write-MigrationLog -Message "Phase 1/4: Registry scan" -Level Info
    try {
        $registryApps = Get-RegistryApps
        if ($registryApps) {
            $allApps.AddRange([MigrationApp[]]$registryApps)
        }
        Write-MigrationLog -Message "Registry scan returned $($registryApps.Count) apps" -Level Info
    }
    catch {
        Write-MigrationLog -Message "Registry scan failed: $($_.Exception.Message)" -Level Error
    }

    # 2. Winget scan
    if ($Config.EnableWinget -ne $false -and $Config.WingetAvailable) {
        Write-MigrationLog -Message "Phase 2/4: Winget scan" -Level Info
        try {
            $wingetApps = Get-WingetApps
            if ($wingetApps) {
                $allApps.AddRange([MigrationApp[]]$wingetApps)
            }
            Write-MigrationLog -Message "Winget scan returned $($wingetApps.Count) apps" -Level Info
        }
        catch {
            Write-MigrationLog -Message "Winget scan failed: $($_.Exception.Message)" -Level Error
        }
    }
    else {
        Write-MigrationLog -Message "Phase 2/4: Winget scan skipped (disabled or unavailable)" -Level Info
    }

    # 3. Store scan
    if ($Config.EnableStoreApps -ne $false) {
        Write-MigrationLog -Message "Phase 3/4: Store scan" -Level Info
        try {
            $storeApps = Get-StoreApps
            if ($storeApps) {
                $allApps.AddRange([MigrationApp[]]$storeApps)
            }
            Write-MigrationLog -Message "Store scan returned $($storeApps.Count) apps" -Level Info
        }
        catch {
            Write-MigrationLog -Message "Store scan failed: $($_.Exception.Message)" -Level Error
        }
    }
    else {
        Write-MigrationLog -Message "Phase 3/4: Store scan skipped (disabled)" -Level Info
    }

    # 4. Program Files fallback scan
    Write-MigrationLog -Message "Phase 4/4: Program Files fallback scan" -Level Info
    try {
        $pfApps = Get-ProgramFilesApps
        if ($pfApps) {
            $allApps.AddRange([MigrationApp[]]$pfApps)
        }
        Write-MigrationLog -Message "Program Files scan returned $($pfApps.Count) apps" -Level Info
    }
    catch {
        Write-MigrationLog -Message "Program Files scan failed: $($_.Exception.Message)" -Level Error
    }

    Write-MigrationLog -Message "Total raw entries before deduplication: $($allApps.Count)" -Level Info

    # Deduplicate by normalized name, keeping the entry with the richest metadata
    $deduped = Merge-DuplicateApps -Apps $allApps

    Write-MigrationLog -Message "=== Application discovery complete: $($deduped.Count) unique applications ===" -Level Info
    return [MigrationApp[]]$deduped
}

function Merge-DuplicateApps {
    <#
    .SYNOPSIS
        Merges duplicate application entries by normalized name.
        When duplicates are found, the entry with the most populated fields wins,
        and missing fields are filled from the other entries.
    .PARAMETER Apps
        The raw list of MigrationApp objects from all scanners.
    .OUTPUTS
        [MigrationApp[]] Deduplicated list.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Generic.List[MigrationApp]]$Apps
    )

    # Source priority: Winget > Registry > Store > ProgramFiles
    $sourcePriority = @{
        'Winget'       = 4
        'Registry'     = 3
        'Store'        = 2
        'ProgramFiles' = 1
    }

    # Group by normalized name
    $groups = [ordered]@{}
    foreach ($app in $Apps) {
        $key = $app.NormalizedName
        if ([string]::IsNullOrWhiteSpace($key)) { continue }

        if (-not $groups.Contains($key)) {
            $groups[$key] = [System.Collections.Generic.List[MigrationApp]]::new()
        }
        $groups[$key].Add($app)
    }

    $result = [System.Collections.Generic.List[MigrationApp]]::new()

    foreach ($key in $groups.Keys) {
        $group = $groups[$key]

        if ($group.Count -eq 1) {
            $result.Add($group[0])
            continue
        }

        # Pick the primary entry based on metadata richness and source priority
        $best = $null
        $bestScore = -1

        foreach ($entry in $group) {
            $score = 0
            if (-not [string]::IsNullOrWhiteSpace($entry.Version))          { $score += 2 }
            if (-not [string]::IsNullOrWhiteSpace($entry.Publisher))        { $score += 2 }
            if (-not [string]::IsNullOrWhiteSpace($entry.InstallLocation))  { $score += 1 }
            if (-not [string]::IsNullOrWhiteSpace($entry.UninstallString))  { $score += 1 }
            if (-not [string]::IsNullOrWhiteSpace($entry.PackageId))        { $score += 3 }
            if (-not [string]::IsNullOrWhiteSpace($entry.InstallMethod))    { $score += 2 }

            $priority = 0
            if ($sourcePriority.ContainsKey($entry.Source)) {
                $priority = $sourcePriority[$entry.Source]
            }
            $score += $priority

            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = $entry
            }
        }

        # Fill in missing fields from other entries in the group
        foreach ($entry in $group) {
            if ([object]::ReferenceEquals($entry, $best)) { continue }

            if ([string]::IsNullOrWhiteSpace($best.Version) -and
                -not [string]::IsNullOrWhiteSpace($entry.Version)) {
                $best.Version = $entry.Version
            }
            if ([string]::IsNullOrWhiteSpace($best.Publisher) -and
                -not [string]::IsNullOrWhiteSpace($entry.Publisher)) {
                $best.Publisher = $entry.Publisher
            }
            if ([string]::IsNullOrWhiteSpace($best.InstallLocation) -and
                -not [string]::IsNullOrWhiteSpace($entry.InstallLocation)) {
                $best.InstallLocation = $entry.InstallLocation
            }
            if ([string]::IsNullOrWhiteSpace($best.UninstallString) -and
                -not [string]::IsNullOrWhiteSpace($entry.UninstallString)) {
                $best.UninstallString = $entry.UninstallString
            }
            if ([string]::IsNullOrWhiteSpace($best.PackageId) -and
                -not [string]::IsNullOrWhiteSpace($entry.PackageId)) {
                $best.PackageId = $entry.PackageId
                if (-not [string]::IsNullOrWhiteSpace($entry.InstallMethod)) {
                    $best.InstallMethod = $entry.InstallMethod
                }
            }
        }

        $result.Add($best)
    }

    return [MigrationApp[]]$result.ToArray()
}
