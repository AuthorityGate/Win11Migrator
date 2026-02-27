<#
========================================================================================================
    Title:          Win11Migrator - Input Settings Exporter
    Filename:       Export-InputSettings.ps1
    Description:    Exports keyboard and mouse input settings for migration.
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
    Exports keyboard and mouse input configuration settings.
.DESCRIPTION
    Reads keyboard settings from HKCU:\Control Panel\Keyboard (KeyboardDelay,
    KeyboardSpeed) and mouse settings from HKCU:\Control Panel\Mouse
    (MouseSpeed, DoubleClickSpeed, MouseSensitivity, SwapMouseButtons, etc.).
    Returns [SystemSetting[]] with Category='InputSetting'.
.OUTPUTS
    [SystemSetting[]]
#>

function Export-InputSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExportPath
    )

    Write-MigrationLog -Message "Starting input settings export" -Level Info

    [SystemSetting[]]$results = @()

    # Ensure the output directory exists
    $inputDir = Join-Path $ExportPath "InputSettings"
    if (-not (Test-Path $inputDir)) {
        New-Item -Path $inputDir -ItemType Directory -Force | Out-Null
    }

    # ----------------------------------------------------------------
    # 1. Keyboard settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting keyboard settings" -Level Debug

        $keyboardPath = 'HKCU:\Control Panel\Keyboard'
        $keyboardData = @{}

        if (Test-Path $keyboardPath) {
            $props = Get-ItemProperty -Path $keyboardPath -ErrorAction SilentlyContinue

            $knownValues = @(
                'KeyboardDelay',       # 0-3 (delay before repeat)
                'KeyboardSpeed',       # 0-31 (repeat rate)
                'InitialKeyboardIndicators'  # Num Lock on/off at login
            )

            if ($props) {
                foreach ($valueName in $knownValues) {
                    if ($props.PSObject.Properties[$valueName]) {
                        $keyboardData[$valueName] = $props.$valueName
                    }
                }

                # Capture any additional values
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS' -and -not $keyboardData.ContainsKey($p.Name)) {
                        $keyboardData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'InputSetting'
        $setting.Name         = 'KeyboardSettings'
        $setting.Data         = @{
            Values       = $keyboardData
            RegistryPath = $keyboardPath
            ValueCount   = $keyboardData.Count
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($keyboardData.Count) keyboard values" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'InputSetting'
        $setting.Name         = 'KeyboardSettings'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export keyboard settings: $($_.Exception.Message)" -Level Error
    }

    # ----------------------------------------------------------------
    # 2. Mouse settings
    # ----------------------------------------------------------------
    try {
        Write-MigrationLog -Message "Exporting mouse settings" -Level Debug

        $mousePath = 'HKCU:\Control Panel\Mouse'
        $mouseData = @{}

        if (Test-Path $mousePath) {
            $props = Get-ItemProperty -Path $mousePath -ErrorAction SilentlyContinue

            $knownValues = @(
                'MouseSpeed',          # 0-2 (pointer acceleration)
                'MouseThreshold1',     # Acceleration threshold 1
                'MouseThreshold2',     # Acceleration threshold 2
                'DoubleClickSpeed',    # Milliseconds
                'MouseSensitivity',    # 1-20 (pointer speed)
                'SwapMouseButtons',    # 0=No, 1=Yes (left-handed)
                'DoubleClickHeight',   # Double-click area height
                'DoubleClickWidth',    # Double-click area width
                'MouseTrails',         # 0=Off, >0=trail length
                'SnapToDefaultButton', # 0=No, 1=Yes
                'ActiveWindowTracking' # 0=No, 1=Yes (focus follows mouse)
            )

            if ($props) {
                foreach ($valueName in $knownValues) {
                    if ($props.PSObject.Properties[$valueName]) {
                        $mouseData[$valueName] = $props.$valueName
                    }
                }

                # Capture any additional values
                foreach ($p in $props.PSObject.Properties) {
                    if ($p.Name -notmatch '^PS' -and -not $mouseData.ContainsKey($p.Name)) {
                        $mouseData[$p.Name] = $p.Value
                    }
                }
            }
        }

        $setting = [SystemSetting]::new()
        $setting.Category     = 'InputSetting'
        $setting.Name         = 'MouseSettings'
        $setting.Data         = @{
            Values       = $mouseData
            RegistryPath = $mousePath
            ValueCount   = $mouseData.Count
        }
        $setting.ExportStatus = 'Success'
        $results += $setting

        Write-MigrationLog -Message "Exported $($mouseData.Count) mouse values" -Level Debug
    }
    catch {
        $setting = [SystemSetting]::new()
        $setting.Category     = 'InputSetting'
        $setting.Name         = 'MouseSettings'
        $setting.Data         = @{ Error = $_.Exception.Message }
        $setting.ExportStatus = 'Failed'
        $results += $setting
        Write-MigrationLog -Message "Failed to export mouse settings: $($_.Exception.Message)" -Level Error
    }

    # Save all input settings to JSON
    try {
        $allData = @{}
        foreach ($r in $results) {
            $allData[$r.Name] = $r.Data
        }
        $jsonFile = Join-Path $inputDir "InputSettings.json"
        $allData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8
        Write-MigrationLog -Message "Saved input settings to InputSettings.json" -Level Debug
    }
    catch {
        Write-MigrationLog -Message "Failed to save InputSettings.json: $($_.Exception.Message)" -Level Warning
    }

    $successCount = ($results | Where-Object { $_.ExportStatus -eq 'Success' }).Count
    Write-MigrationLog -Message "Input settings export complete: $successCount/$($results.Count) succeeded" -Level Success

    return $results
}
