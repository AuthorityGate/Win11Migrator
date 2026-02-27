<#
========================================================================================================
    Title:          Win11Migrator - Accessibility Settings Exporter
    Filename:       Export-AccessibilitySettings.ps1
    Description:    Exports Windows accessibility settings (StickyKeys, FilterKeys, HighContrast, etc.)
                    for migration to a new machine.
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
    Exports Windows accessibility settings from the current user's registry.
.DESCRIPTION
    Reads accessibility configuration from HKCU:\Control Panel\Accessibility,
    HKCU:\SOFTWARE\Microsoft\Accessibility, and related registry keys.
    Captures StickyKeys, FilterKeys, ToggleKeys, MouseKeys, HighContrast,
    Narrator, and Magnifier settings. Returns [SystemSetting[]] with
    Category='Accessibility'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-AccessibilitySettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting accessibility settings export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $accessibilityDir = Join-Path $ExportPath "AccessibilitySettings"
    if (-not (Test-Path $accessibilityDir)) {
        New-Item -Path $accessibilityDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. StickyKeys
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting StickyKeys settings" -Level Debug

        $stickyKeysPath = 'HKCU:\Control Panel\Accessibility\StickyKeys'
        $stickyData = @{}

        if (Test-Path $stickyKeysPath) {
            $props = Get-ItemProperty -Path $stickyKeysPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $stickyData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'StickyKeys'
        $setting.Data         = @{
            Values       = $stickyData
            RegistryPath = $stickyKeysPath
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported StickyKeys ($($stickyData.Count) values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'StickyKeys'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export StickyKeys: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. FilterKeys
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting FilterKeys settings" -Level Debug

        $filterKeysPath = 'HKCU:\Control Panel\Accessibility\FilterKeys'
        $filterData = @{}

        if (Test-Path $filterKeysPath) {
            $props = Get-ItemProperty -Path $filterKeysPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $filterData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'FilterKeys'
        $setting.Data         = @{
            Values       = $filterData
            RegistryPath = $filterKeysPath
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported FilterKeys ($($filterData.Count) values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'FilterKeys'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export FilterKeys: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 3. ToggleKeys
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting ToggleKeys settings" -Level Debug

        $toggleKeysPath = 'HKCU:\Control Panel\Accessibility\ToggleKeys'
        $toggleData = @{}

        if (Test-Path $toggleKeysPath) {
            $props = Get-ItemProperty -Path $toggleKeysPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $toggleData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'ToggleKeys'
        $setting.Data         = @{
            Values       = $toggleData
            RegistryPath = $toggleKeysPath
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported ToggleKeys ($($toggleData.Count) values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'ToggleKeys'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export ToggleKeys: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 4. MouseKeys
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting MouseKeys settings" -Level Debug

        $mouseKeysPath = 'HKCU:\Control Panel\Accessibility\MouseKeys'
        $mouseData = @{}

        if (Test-Path $mouseKeysPath) {
            $props = Get-ItemProperty -Path $mouseKeysPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $mouseData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'MouseKeys'
        $setting.Data         = @{
            Values       = $mouseData
            RegistryPath = $mouseKeysPath
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported MouseKeys ($($mouseData.Count) values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'MouseKeys'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export MouseKeys: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 5. HighContrast
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting HighContrast settings" -Level Debug

        $highContrastPath = 'HKCU:\Control Panel\Accessibility\HighContrast'
        $highContrastData = @{}

        if (Test-Path $highContrastPath) {
            $props = Get-ItemProperty -Path $highContrastPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $highContrastData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'HighContrast'
        $setting.Data         = @{
            Values       = $highContrastData
            RegistryPath = $highContrastPath
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported HighContrast ($($highContrastData.Count) values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'HighContrast'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export HighContrast: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 6. Narrator
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting Narrator settings" -Level Debug

        $narratorData = @{}

        # Primary Narrator settings
        $narratorPath = 'HKCU:\SOFTWARE\Microsoft\Narrator'
        if (Test-Path $narratorPath) {
            $props = Get-ItemProperty -Path $narratorPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $narratorData[$p.Name] = $p.Value
                    }
                }
            }
        }

        # Additional Narrator settings under NoRoam
        $narratorNoRoamPath = 'HKCU:\SOFTWARE\Microsoft\Narrator\NoRoam'
        $narratorNoRoamData = @{}
        if (Test-Path $narratorNoRoamPath) {
            $props = Get-ItemProperty -Path $narratorNoRoamPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $narratorNoRoamData[$p.Name] = $p.Value
                    }
                }
            }
        }

        # General accessibility features
        $accessibilityPath = 'HKCU:\SOFTWARE\Microsoft\Accessibility'
        $accessibilityData = @{}
        if (Test-Path $accessibilityPath) {
            $props = Get-ItemProperty -Path $accessibilityPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $accessibilityData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'Narrator'
        $setting.Data         = @{
            NarratorSettings       = $narratorData
            NarratorNoRoam         = $narratorNoRoamData
            AccessibilityFeatures  = $accessibilityData
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported Narrator settings ($($narratorData.Count) values, $($narratorNoRoamData.Count) NoRoam values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'Narrator'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export Narrator settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 7. Magnifier
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting Magnifier settings" -Level Debug

        $magnifierPath = 'HKCU:\SOFTWARE\Microsoft\ScreenMagnifier'
        $magnifierData = @{}

        if (Test-Path $magnifierPath) {
            $props = Get-ItemProperty -Path $magnifierPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $magnifierData[$p.Name] = $p.Value
                    }
                }
            }
        }

        # Also check NT CurrentVersion Accessibility
        $ntAccessPath = 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Accessibility'
        $ntAccessData = @{}
        if (Test-Path $ntAccessPath) {
            $props = Get-ItemProperty -Path $ntAccessPath -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS') {
                        $ntAccessData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'Magnifier'
        $setting.Data         = @{
            MagnifierSettings      = $magnifierData
            NTAccessibility        = $ntAccessData
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported Magnifier settings ($($magnifierData.Count) values)" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'Accessibility'
        $setting.Name         = 'Magnifier'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export Magnifier settings: $($_.Exception.Message)" -Level Error
    }

    # Save all accessibility settings to a single JSON file
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $accessibilityDir "AccessibilitySettings.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved accessibility settings to AccessibilitySettings.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save AccessibilitySettings.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Accessibility settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
