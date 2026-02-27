<#
========================================================================================================
    Title:          Win11Migrator - Registry Application Scanner
    Filename:       Get-RegistryApps.ps1
    Description:    Scans Windows registry uninstall keys to discover installed applications.
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
    Scans the Windows registry uninstall keys to discover installed applications.
    Filters out system components and entries listed in ExcludedApps.json.
#>

function Get-RegistryApps {
    <#
    .SYNOPSIS
        Retrieves installed applications from all three registry uninstall locations.
    .OUTPUTS
        [MigrationApp[]] Array of discovered applications with Source='Registry'.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param()

    Write-MigrationLog -Message "Starting registry application scan" -Level Info

    # Load excluded app patterns
    $excludedPatterns = @()
    $excludedPath = Join-Path $script:MigratorRoot "Config\ExcludedApps.json"
    if (Test-Path $excludedPath) {
        try {
            $excludedPatterns = Get-Content $excludedPath -Raw | ConvertFrom-Json
            Write-MigrationLog -Message "Loaded $($excludedPatterns.Count) exclusion patterns" -Level Debug
        }
        catch {
            Write-MigrationLog -Message "Failed to load ExcludedApps.json: $($_.Exception.Message)" -Level Warning
        }
    }
    else {
        Write-MigrationLog -Message "ExcludedApps.json not found at $excludedPath - no exclusions applied" -Level Warning
    }

    # Registry paths to scan
    $registryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $apps = [System.Collections.Generic.List[MigrationApp]]::new()
    $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($regPath in $registryPaths) {
        Write-MigrationLog -Message "Scanning registry path: $regPath" -Level Debug

        try {
            $entries = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        }
        catch {
            Write-MigrationLog -Message "Could not read $regPath : $($_.Exception.Message)" -Level Warning
            continue
        }

        if (-not $entries) { continue }

        foreach ($entry in $entries) {
            # Skip entries without a display name
            $displayName = $entry.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                continue
            }

            # Skip system components flagged in the registry
            if ($entry.SystemComponent -eq 1) {
                continue
            }

            # Skip Windows updates and patches by registry flag
            if ($entry.ReleaseType -in @('Update', 'Hotfix', 'Security Update', 'Service Pack')) {
                continue
            }

            # Check against exclusion patterns
            $excluded = $false
            foreach ($pattern in $excludedPatterns) {
                if ($displayName -like $pattern) {
                    $excluded = $true
                    break
                }
            }
            if ($excluded) {
                Write-MigrationLog -Message "Excluded by pattern: $displayName" -Level Debug
                continue
            }

            # Skip known hardware/driver publishers
            $publisher = if ($entry.Publisher) { $entry.Publisher } else { '' }
            $hardwarePublishers = @(
                'NVIDIA Corporation',
                'Advanced Micro Devices*',
                'Intel Corporation',
                'Intel(R) Corporation',
                'Realtek Semiconductor*',
                'Realtek',
                'Qualcomm*',
                'Broadcom*',
                'Synaptics*',
                'ELAN Microelectronics*',
                'Alps Electric*',
                'Conexant*',
                'IDT*',
                'Marvell*',
                'MediaTek*',
                'Tobii*'
            )
            $excludedByPublisher = $false
            foreach ($hwPub in $hardwarePublishers) {
                if ($publisher -like $hwPub) {
                    $excludedByPublisher = $true
                    break
                }
            }
            if ($excludedByPublisher) {
                Write-MigrationLog -Message "Excluded by publisher ($publisher): $displayName" -Level Debug
                continue
            }

            # Deduplicate within registry scan by display name
            if (-not $seenNames.Add($displayName)) {
                continue
            }

            $normalizedName = Get-NormalizedAppName -Name $displayName

            $app = [MigrationApp]::new()
            $app.Name              = $displayName
            $app.NormalizedName    = $normalizedName
            $app.Version           = if ($entry.DisplayVersion) { $entry.DisplayVersion } else { '' }
            $app.Publisher         = if ($entry.Publisher) { $entry.Publisher } else { '' }
            $app.InstallLocation   = if ($entry.InstallLocation) { $entry.InstallLocation } else { '' }
            $app.UninstallString   = if ($entry.UninstallString) { $entry.UninstallString } else { '' }
            $app.Source            = 'Registry'
            $app.InstallMethod     = ''
            $app.PackageId         = ''
            $app.DownloadUrl       = ''
            $app.MatchConfidence   = 0.0
            $app.Selected          = $true
            $app.InstallStatus     = 'Pending'
            $app.InstallError      = ''

            $apps.Add($app)
        }
    }

    Write-MigrationLog -Message "Registry scan complete: found $($apps.Count) applications" -Level Info
    return [MigrationApp[]]$apps.ToArray()
}
