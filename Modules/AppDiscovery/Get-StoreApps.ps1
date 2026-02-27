<#
========================================================================================================
    Title:          Win11Migrator - Microsoft Store Application Scanner
    Filename:       Get-StoreApps.ps1
    Description:    Discovers installed Microsoft Store (UWP/MSIX) applications via PowerShell APIs.
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
    Discovers installed Microsoft Store (AppX) applications.
    Filters out system frameworks, runtime components, and infrastructure packages.
#>

function Get-StoreApps {
    <#
    .SYNOPSIS
        Uses Get-AppxPackage to list installed Store applications, filtering system packages.
    .OUTPUTS
        [MigrationApp[]] Array of discovered applications with Source='Store'.
    #>
    [CmdletBinding()]
    [OutputType([MigrationApp[]])]
    param()

    Write-MigrationLog -Message "Starting Microsoft Store application scan" -Level Info

    # Prefixes that identify system/framework packages to exclude
    $systemPrefixes = @(
        'Microsoft.NET',
        'Microsoft.VCLibs',
        'Microsoft.UI.Xaml',
        'Microsoft.DirectX',
        'Microsoft.Services',
        'Microsoft.Advertising',
        'Microsoft.DesktopAppInstaller',
        'Microsoft.StorePurchaseApp',
        'Microsoft.WindowsStore',
        'Microsoft.Windows.',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.Xbox.TCUI',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.AAD.BrokerPlugin',
        'Microsoft.AccountsControl',
        'Microsoft.AsyncTextService',
        'Microsoft.BioEnrollment',
        'Microsoft.CredDialogHost',
        'Microsoft.ECApp',
        'Microsoft.LockApp',
        'Microsoft.MicrosoftEdge',
        'Microsoft.MicrosoftEdgeDevToolsClient',
        'Microsoft.PPIProjection',
        'Microsoft.Win32WebViewHost',
        'MicrosoftWindows.',
        'windows.',
        'Windows.',
        'InputApp',
        'NcsiUwpApp',
        'ParentalControls',
        'Win32WebViewHost',
        'AppUp.IntelGraphicsExperience',
        'RealtekSemiconductorCorp',
        'NVIDIA',
        'DellInc',
        'Microsoft.549981C3F5F10'  # Cortana
    )

    # Additional package name fragments that indicate non-user apps
    $systemFragments = @(
        '.NET.',
        'VCLibs',
        'RuntimeBroker',
        'ShellExperienceHost',
        'StartMenuExperienceHost',
        'ContentDeliveryManager',
        'CloudExperienceHost'
    )

    try {
        $packages = Get-AppxPackage -ErrorAction SilentlyContinue
    }
    catch {
        Write-MigrationLog -Message "Failed to enumerate AppX packages: $($_.Exception.Message)" -Level Error
        return [MigrationApp[]]@()
    }

    if (-not $packages) {
        Write-MigrationLog -Message "No AppX packages found" -Level Info
        return [MigrationApp[]]@()
    }

    $apps = [System.Collections.Generic.List[MigrationApp]]::new()

    foreach ($pkg in $packages) {
        # Skip non-full packages (frameworks, resources, bundles)
        if ($pkg.IsFramework) { continue }
        if ($pkg.SignatureKind -eq 'System') { continue }
        if ($pkg.IsResourcePackage) { continue }
        if ($pkg.IsBundle) { continue }

        $pkgName = $pkg.Name

        # Check against system prefixes
        $isSystem = $false
        foreach ($prefix in $systemPrefixes) {
            if ($pkgName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $isSystem = $true
                break
            }
        }
        if ($isSystem) { continue }

        # Check against system fragments
        foreach ($fragment in $systemFragments) {
            if ($pkgName.Contains($fragment)) {
                $isSystem = $true
                break
            }
        }
        if ($isSystem) { continue }

        # Build a human-readable display name
        # AppxPackage sometimes has no friendly display name accessible directly,
        # so we derive one from the package name
        $displayName = $pkgName
        # Try to extract a readable name: "Publisher.AppName" -> "AppName"
        $parts = $pkgName -split '\.'
        if ($parts.Count -ge 2) {
            # Take everything after the first segment (publisher)
            $displayName = ($parts[1..($parts.Count - 1)] -join ' ')
        }
        # Remove excess digits that are just part of package IDs
        $displayName = [regex]::Replace($displayName, '[A-F0-9]{8,}', '').Trim()
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            $displayName = $pkgName
        }

        $normalizedName = Get-NormalizedAppName -Name $displayName

        $app = [MigrationApp]::new()
        $app.Name              = $displayName
        $app.NormalizedName    = $normalizedName
        $app.Version           = if ($pkg.Version) { $pkg.Version.ToString() } else { '' }
        $app.Publisher         = if ($pkg.Publisher) { $pkg.Publisher } else { '' }
        $app.InstallLocation   = if ($pkg.InstallLocation) { $pkg.InstallLocation } else { '' }
        $app.UninstallString   = ''
        $app.Source            = 'Store'
        $app.InstallMethod     = 'Store'
        $app.PackageId         = $pkg.PackageFamilyName
        $app.DownloadUrl       = ''
        $app.MatchConfidence   = 1.0
        $app.Selected          = $true
        $app.InstallStatus     = 'Pending'
        $app.InstallError      = ''

        $apps.Add($app)
    }

    Write-MigrationLog -Message "Store scan complete: found $($apps.Count) applications" -Level Info
    return [MigrationApp[]]$apps.ToArray()
}
