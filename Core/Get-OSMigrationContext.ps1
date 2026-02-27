<#
========================================================================================================
    Title:          Win11Migrator - OS Migration Context Detector
    Filename:       Get-OSMigrationContext.ps1
    Description:    Detects OS version and feature flags for cross-OS migration (Win10 to Win11).
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
    Detects the current OS version, build number, and Win10/Win11-specific feature flags.
.DESCRIPTION
    Reads OS version information from the registry and environment to determine whether the
    machine is running Windows 10 or Windows 11. Returns a hashtable with boolean feature
    flags for Start Menu style, taskbar alignment, Snap Layouts, edition, and registered owner.
    Used by Convert-CrossOSSettings to decide which transformations are needed.
.OUTPUTS
    [hashtable] with keys: IsWindows10, IsWindows11, BuildNumber, DisplayVersion,
    HasNewStartMenu, HasCenteredTaskbar, HasSnapLayouts, OSEdition, RegisteredOwner
#>

function Get-OSMigrationContext {
    [CmdletBinding()]
    param()

    Write-MigrationLog -Message "Detecting OS migration context" -Level Info

    try {
        # Read core version data from the registry
        $ntCurrentVersion = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $regData = Get-ItemProperty -Path $ntCurrentVersion -ErrorAction Stop

        $buildNumber = [int]$regData.CurrentBuildNumber
        $displayVersion = if ($regData.PSObject.Properties['DisplayVersion']) {
            $regData.DisplayVersion
        } else {
            ''
        }
        $productName = if ($regData.PSObject.Properties['ProductName']) {
            $regData.ProductName
        } else {
            ''
        }
        $editionId = if ($regData.PSObject.Properties['EditionID']) {
            $regData.EditionID
        } else {
            ''
        }
        $registeredOwner = if ($regData.PSObject.Properties['RegisteredOwner']) {
            $regData.RegisteredOwner
        } else {
            ''
        }

        # Win10: builds 10240-19045, Win11: builds 22000+
        $isWindows11 = $buildNumber -ge 22000
        $isWindows10 = ($buildNumber -ge 10240) -and ($buildNumber -lt 22000)

        # Feature flags
        # HasNewStartMenu: Win11 replaced Win10 live tiles with a completely different layout
        $hasNewStartMenu = $isWindows11

        # HasCenteredTaskbar: Win11 defaults to center-aligned taskbar
        # Registry value TaskbarAl: 1 = center (default on Win11), 0 = left
        $hasCenteredTaskbar = $false
        if ($isWindows11) {
            $taskbarRegPath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            try {
                $taskbarProps = Get-ItemProperty -Path $taskbarRegPath -ErrorAction SilentlyContinue
                if ($taskbarProps -and $taskbarProps.PSObject.Properties['TaskbarAl']) {
                    $hasCenteredTaskbar = ($taskbarProps.TaskbarAl -eq 1)
                } else {
                    # Default on Win11 is centered
                    $hasCenteredTaskbar = $true
                }
            }
            catch {
                # Default on Win11 is centered if we cannot read the registry
                $hasCenteredTaskbar = $true
            }
        }

        # HasSnapLayouts: Win11 only (build >= 22000)
        $hasSnapLayouts = $isWindows11

        $context = @{
            IsWindows10       = $isWindows10
            IsWindows11       = $isWindows11
            BuildNumber       = $buildNumber
            DisplayVersion    = $displayVersion
            HasNewStartMenu   = $hasNewStartMenu
            HasCenteredTaskbar = $hasCenteredTaskbar
            HasSnapLayouts    = $hasSnapLayouts
            OSEdition         = $editionId
            RegisteredOwner   = $registeredOwner
        }

        $osLabel = if ($isWindows11) { "Windows 11" } elseif ($isWindows10) { "Windows 10" } else { "Unknown" }
        Write-MigrationLog -Message "OS detected: $osLabel (Build $buildNumber, Edition: $editionId, Version: $displayVersion)" -Level Info

        return $context
    }
    catch {
        Write-MigrationLog -Message "Failed to detect OS migration context: $($_.Exception.Message)" -Level Error
        throw
    }
}
