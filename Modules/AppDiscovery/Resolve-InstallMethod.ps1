<#
========================================================================================================
    Title:          Win11Migrator - Install Method Resolver
    Filename:       Resolve-InstallMethod.ps1
    Description:    Determines the best installation method for each application via cascade resolution.
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
    Cascade resolver that determines the best installation method for each discovered application.
    Priority order: Winget > Chocolatey > Ninite > Store > VendorDownload > Manual.
#>

function Resolve-InstallMethod {
    <#
    .SYNOPSIS
        For each application in the input list, tries each install source in priority order
        and assigns the best method with its confidence score and package identifier.
    .PARAMETER Apps
        Array of MigrationApp objects to resolve install methods for.
    .PARAMETER Config
        The migration configuration hashtable from Initialize-Environment.
    .OUTPUTS
        [MigrationApp[]] The same apps with InstallMethod, PackageId, DownloadUrl, and MatchConfidence populated.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param(
        [Parameter(Mandatory)]
        [MigrationApp[]]$Apps,

        [Parameter()]
        [hashtable]$Config
    )

    if (-not $Config) {
        $Config = $script:Config
    }

    $totalApps = $Apps.Count
    Write-MigrationLog -Message "=== Resolving install methods for $totalApps applications ===" -Level Info

    $resolvedCount = 0
    $manualCount   = 0

    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $app = $Apps[$i]

        # Skip apps that already have a resolved install method with high confidence
        # (e.g. apps discovered by Winget already have their PackageId)
        if (-not [string]::IsNullOrWhiteSpace($app.InstallMethod) -and
            -not [string]::IsNullOrWhiteSpace($app.PackageId) -and
            $app.MatchConfidence -ge 0.9) {
            $resolvedCount++
            Write-MigrationLog -Message "[$($i+1)/$totalApps] '$($app.Name)' already resolved: $($app.InstallMethod) ($($app.PackageId))" -Level Debug
            continue
        }

        $normalizedName = $app.NormalizedName
        if ([string]::IsNullOrWhiteSpace($normalizedName)) {
            $normalizedName = Get-NormalizedAppName -Name $app.Name
            $app.NormalizedName = $normalizedName
        }

        Write-MigrationLog -Message "[$($i+1)/$totalApps] Resolving: '$($app.Name)' (normalized: '$normalizedName')" -Level Debug

        $resolved = $false

        # --- Priority 1: Winget ---
        if (-not $resolved -and $Config.EnableWinget -ne $false -and $Config.WingetAvailable) {
            $result = Search-WingetPackage -AppName $app.Name -NormalizedName $normalizedName
            if ($result.Found) {
                $app.InstallMethod   = 'Winget'
                $app.PackageId       = $result.PackageId
                $app.MatchConfidence = $result.Confidence
                $resolved = $true
                Write-MigrationLog -Message "  -> Winget: $($result.PackageId) (confidence: $([Math]::Round($result.Confidence, 2)))" -Level Debug
            }
        }

        # --- Priority 2: Chocolatey ---
        if (-not $resolved -and $Config.EnableChocolatey -ne $false) {
            $result = Search-ChocolateyPackage -AppName $app.Name -NormalizedName $normalizedName
            if ($result.Found) {
                $app.InstallMethod   = 'Chocolatey'
                $app.PackageId       = $result.PackageId
                $app.MatchConfidence = $result.Confidence
                $resolved = $true
                Write-MigrationLog -Message "  -> Chocolatey: $($result.PackageId) (confidence: $([Math]::Round($result.Confidence, 2)))" -Level Debug
            }
        }

        # --- Priority 3: Ninite ---
        if (-not $resolved -and $Config.EnableNinite -ne $false) {
            $result = Search-NinitePackage -AppName $app.Name -NormalizedName $normalizedName
            if ($result.Found) {
                $app.InstallMethod   = 'Ninite'
                $app.PackageId       = $result.PackageId
                $app.MatchConfidence = $result.Confidence
                $resolved = $true
                Write-MigrationLog -Message "  -> Ninite: $($result.PackageId) (confidence: $([Math]::Round($result.Confidence, 2)))" -Level Debug
            }
        }

        # --- Priority 4: Microsoft Store ---
        if (-not $resolved -and $Config.EnableStoreApps -ne $false) {
            $result = Search-StorePackage -AppName $app.Name -NormalizedName $normalizedName
            if ($result.Found) {
                $app.InstallMethod   = 'Store'
                $app.PackageId       = $result.PackageId
                $app.MatchConfidence = $result.Confidence
                $resolved = $true
                Write-MigrationLog -Message "  -> Store: $($result.StoreId) (confidence: $([Math]::Round($result.Confidence, 2)))" -Level Debug
            }
        }

        # --- Priority 5: Vendor Download ---
        if (-not $resolved -and $Config.EnableVendorDownload -ne $false) {
            $result = Search-VendorDownload -AppName $app.Name -NormalizedName $normalizedName
            if ($result.Found) {
                $app.InstallMethod   = 'VendorDownload'
                $app.DownloadUrl     = $result.DownloadUrl
                $app.MatchConfidence = $result.Confidence
                $resolved = $true
                Write-MigrationLog -Message "  -> VendorDownload: $($result.DownloadUrl) (confidence: $([Math]::Round($result.Confidence, 2)))" -Level Debug
            }
        }

        # --- Fallback: Manual ---
        if (-not $resolved) {
            $app.InstallMethod   = 'Manual'
            $app.MatchConfidence = 0.0
            $manualCount++
            Write-MigrationLog -Message "  -> Manual (no automated install source found)" -Level Debug
        }
        else {
            $resolvedCount++
        }
    }

    $autoPercent = if ($totalApps -gt 0) { [Math]::Round(($resolvedCount / $totalApps) * 100, 1) } else { 0 }
    Write-MigrationLog -Message "=== Install method resolution complete ===" -Level Info
    Write-MigrationLog -Message "  Automated: $resolvedCount/$totalApps ($autoPercent%)" -Level Info
    Write-MigrationLog -Message "  Manual:    $manualCount/$totalApps" -Level Info

    # Log a summary by method
    $methodGroups = $Apps | Group-Object -Property InstallMethod
    foreach ($group in $methodGroups) {
        Write-MigrationLog -Message "  $($group.Name): $($group.Count) apps" -Level Info
    }

    return $Apps
}
